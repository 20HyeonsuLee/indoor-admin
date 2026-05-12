import ARKit
import SceneKit
import os.log

// MARK: - MarkARSceneOverlay

/// ARSCNViewDelegate adapter: mark anchor ↔ SCNNode lifecycle 관리.
///
/// ## 설계 (cycle_5 plan §5.2)
/// - `session.add(anchor:)` → ARKit이 다음 프레임에 `renderer(_:nodeFor:)` 호출 → SCNNode 부착.
/// - ARKit이 매 프레임 anchor.transform을 SCNNode.simdTransform에 자동 반영 → jitter 흡수 + 3D 공간 고정.
/// - SwiftUI 2D projection(`ARFrame.camera.projectPoint`) 완전 대체 — 정식 노드/엣지 그리기는 이 클래스 담당.
///
/// ## Thread safety (R-A1 대응)
/// ARSCNViewDelegate.renderer(_:nodeFor:)는 SceneKit render loop에서 호출되며
/// Main thread와 다를 수 있다. 이 클래스는 `@MainActor`로 격리하되,
/// `nonisolated` delegate 메서드에서는 lock-protected 별도 구조체로 state를 공유한다.
///
/// ## cycle_5 plan §6 디버그 정책
/// magenta R / yellow P 디버그 레이어는 ARNodeOverlayView(SwiftUI)에 그대로 유지한다.
/// MarkARSceneOverlay는 정식 노드(sphere + label + edge)만 담당한다.
@MainActor
final class MarkARSceneOverlay: NSObject {

    // MARK: - Constants

    private enum Const {
        static let corridorSphereRadius: CGFloat = 0.05     // 5cm
        static let cornerSphereRadius: CGFloat = 0.05       // 5cm
        static let sphereSegmentCount: Int = 16
        static let labelFontSize: CGFloat = 0.06            // 6cm scene unit
        static let labelOffsetY: Float = 0.10               // 노드 위 10cm
        static let edgeCylinderRadius: CGFloat = 0.012      // 1.2cm
        static let edgeRadialSegmentCount: Int = 8
        static let anchorNamePrefix = "branch_"
        static let standaloneAnchorNamePrefix = "standalone_"
        static let standaloneSphereRadius: CGFloat = 0.06   // 6cm — branch보다 약간 크게
    }

    /// Sprint 88 cycle_5+: 엣지 자동 연결 없는 단순 visible marker 종류.
    /// Sprint 88 cycle_7: interfloor 단일 케이스 → 3가지 (elevator/stairs/escalator) + poi로 4-case 분기.
    /// rawValue에 underscore 포함 (interfloor_elevator 등) — anchor name 파싱 시 lastIndex(of:"_") 사용.
    enum StandaloneMarkerKind: String {
        case interfloorElevator  = "interfloor_elevator"
        case interfloorStairs    = "interfloor_stairs"
        case interfloorEscalator = "interfloor_escalator"
        case poi                 = "poi"
    }

    // MARK: - Thread-safe node registry (nonisolated delegate에서 접근)

    /// nodeId → (order, nodeType) 매핑. stateLock으로 보호.
    /// nonisolated(unsafe): stateLock으로 모든 접근을 보호하므로 data race safe.
    private struct NodeMeta: @unchecked Sendable {
        let order: Int
        let nodeType: NodeType
    }

    nonisolated(unsafe) private var nodeMetas: [BranchMarkNodeId: NodeMeta] = [:]
    private let stateLock = NSLock()

    /// Standalone marker meta (interfloor/POI). branch와 분리된 anchor name space.
    private struct StandaloneMeta: @unchecked Sendable {
        let kind: StandaloneMarkerKind
        let label: String
    }
    nonisolated(unsafe) private var standaloneMetas: [UUID: StandaloneMeta] = [:]

    // MARK: - MainActor state

    private var anchorByNodeId: [BranchMarkNodeId: ARAnchor] = [:]
    private var scnNodeByNodeId: [BranchMarkNodeId: SCNNode] = [:]
    private var edgeNodes: [UUID: SCNNode] = [:]
    private var standaloneAnchorById: [UUID: ARAnchor] = [:]
    private var standaloneNodeById: [UUID: SCNNode] = [:]

    // MARK: - Weak references

    private weak var sceneView: ARSCNView?
    private weak var arSession: ARSession?

    // MARK: - Logger

    private let logger = Logger(subsystem: "com.indoorpathfinding", category: "MarkARSceneOverlay")

    // MARK: - Attach

    func attach(sceneView: ARSCNView, session: ARSession) {
        self.sceneView = sceneView
        self.arSession = session
        sceneView.delegate = self
        logger.debug("MarkARSceneOverlay attached to ARSCNView")
    }

    // MARK: - Mark Anchor Lifecycle

    func addMark(
        nodeId: BranchMarkNodeId,
        nodeType: NodeType,
        order: Int,
        transform: simd_float4x4
    ) {
        guard let session = arSession else {
            logger.warning("addMark: arSession nil, nodeId=\(nodeId)")
            return
        }

        let anchorName = "\(Const.anchorNamePrefix)\(nodeId)"
        let anchor = ARAnchor(name: anchorName, transform: transform)
        session.add(anchor: anchor)
        anchorByNodeId[nodeId] = anchor

        stateLock.lock()
        nodeMetas[nodeId] = NodeMeta(order: order, nodeType: nodeType)
        stateLock.unlock()

        let wx = String(format: "%.3f", transform.columns.3.x)
        let wy = String(format: "%.3f", transform.columns.3.y)
        let wz = String(format: "%.3f", transform.columns.3.z)
        logger.debug("addMark nodeId=\(nodeId) type=\(nodeType.rawValue) order=\(order) world=(\(wx),\(wy),\(wz))")
    }

    /// Sprint 88 cycle_5+: 단순 visible marker (interfloor/POI). 엣지 자동 연결 없음.
    /// "찍히는지만 보이게" 요건 — anchor 추가 + sphere + label.
    func addStandaloneMark(
        id: UUID,
        kind: StandaloneMarkerKind,
        label: String,
        transform: simd_float4x4
    ) {
        guard let session = arSession else {
            logger.warning("addStandaloneMark: arSession nil, id=\(id)")
            return
        }
        let anchorName = "\(Const.standaloneAnchorNamePrefix)\(kind.rawValue)_\(id)"
        let anchor = ARAnchor(name: anchorName, transform: transform)
        session.add(anchor: anchor)
        standaloneAnchorById[id] = anchor

        stateLock.lock()
        standaloneMetas[id] = StandaloneMeta(kind: kind, label: label)
        stateLock.unlock()

        let wx = String(format: "%.3f", transform.columns.3.x)
        let wy = String(format: "%.3f", transform.columns.3.y)
        let wz = String(format: "%.3f", transform.columns.3.z)
        logger.debug("addStandaloneMark id=\(id) kind=\(kind.rawValue) label=\(label) world=(\(wx),\(wy),\(wz))")
    }

    func removeStandaloneMark(id: UUID) {
        if let anchor = standaloneAnchorById.removeValue(forKey: id) {
            arSession?.remove(anchor: anchor)
        }
        standaloneNodeById.removeValue(forKey: id)?.removeFromParentNode()

        stateLock.lock()
        standaloneMetas.removeValue(forKey: id)
        stateLock.unlock()

        logger.debug("removeStandaloneMark id=\(id)")
    }

    func removeMark(nodeId: BranchMarkNodeId) {
        if let anchor = anchorByNodeId.removeValue(forKey: nodeId) {
            arSession?.remove(anchor: anchor)
        }
        scnNodeByNodeId.removeValue(forKey: nodeId)?.removeFromParentNode()

        stateLock.lock()
        nodeMetas.removeValue(forKey: nodeId)
        stateLock.unlock()

        logger.debug("removeMark nodeId=\(nodeId)")
    }

    // MARK: - Edge Sync

    func syncEdges(_ edges: [BranchMarkEdge], nodes: [BranchMarkNode]) {
        guard let scene = sceneView?.scene else { return }

        let currentIds = Set(edges.map(\.id))

        for (id, node) in edgeNodes where !currentIds.contains(id) {
            node.removeFromParentNode()
            edgeNodes.removeValue(forKey: id)
        }

        for edge in edges where edgeNodes[edge.id] == nil {
            guard
                let fromNode = nodes.first(where: { $0.id == edge.from }),
                let toNode = nodes.first(where: { $0.id == edge.to })
            else { continue }

            let cylinder = makeEdgeCylinder(
                from: fromNode.position,
                to: toNode.position,
                kind: edge.kind
            )
            scene.rootNode.addChildNode(cylinder)
            edgeNodes[edge.id] = cylinder
        }
    }

    // MARK: - Reset

    func reset() {
        scnNodeByNodeId.values.forEach { $0.removeFromParentNode() }
        scnNodeByNodeId.removeAll()
        anchorByNodeId.removeAll()
        edgeNodes.values.forEach { $0.removeFromParentNode() }
        edgeNodes.removeAll()
        standaloneNodeById.values.forEach { $0.removeFromParentNode() }
        standaloneNodeById.removeAll()
        standaloneAnchorById.removeAll()

        stateLock.lock()
        nodeMetas.removeAll()
        standaloneMetas.removeAll()
        stateLock.unlock()

        logger.debug("MarkARSceneOverlay reset")
    }

    // MARK: - SCNNode Factory: Marker

    private func makeMarkerNode(order: Int, nodeType: NodeType) -> SCNNode {
        let parent = SCNNode()

        let radius: CGFloat = nodeType == .corner
            ? Const.cornerSphereRadius
            : Const.corridorSphereRadius
        let sphereGeom = SCNSphere(radius: radius)
        sphereGeom.segmentCount = Const.sphereSegmentCount
        let sphereMaterial = SCNMaterial()
        sphereMaterial.diffuse.contents = sphereColor(for: nodeType)
        sphereMaterial.emission.contents = UIColor(white: 0.25, alpha: 1.0)
        sphereMaterial.lightingModel = .phong
        sphereGeom.firstMaterial = sphereMaterial
        let sphereNode = SCNNode(geometry: sphereGeom)

        // Pulse animation: scale 1.5 → 1.0 (0.3s) — plan §5.7
        let pulse = SCNAction.sequence([
            SCNAction.scale(to: 1.5, duration: 0.0),
            SCNAction.scale(to: 1.0, duration: 0.3)
        ])
        sphereNode.runAction(pulse)
        parent.addChildNode(sphereNode)

        // Order label
        let labelNode = makeOrderLabel(text: "\(order)")
        labelNode.position = SCNVector3(0, Const.labelOffsetY, 0)
        parent.addChildNode(labelNode)

        return parent
    }

    // MARK: - SCNNode Factory: Order Label

    private func makeOrderLabel(text: String) -> SCNNode {
        let textGeom = SCNText(string: text, extrusionDepth: 0)
        textGeom.font = UIFont.boldSystemFont(ofSize: Const.labelFontSize)
        let textMaterial = SCNMaterial()
        textMaterial.diffuse.contents = UIColor.white
        textMaterial.isDoubleSided = true
        textGeom.firstMaterial = textMaterial

        let node = SCNNode(geometry: textGeom)

        let (minBound, maxBound) = textGeom.boundingBox
        node.pivot = SCNMatrix4MakeTranslation(
            (maxBound.x - minBound.x) / 2,
            (maxBound.y - minBound.y) / 2,
            0
        )

        let billboard = SCNBillboardConstraint()
        billboard.freeAxes = .Y
        node.constraints = [billboard]

        return node
    }

    // MARK: - SCNNode Factory: Edge Cylinder

    private func makeEdgeCylinder(
        from a: SIMD3<Float>,
        to b: SIMD3<Float>,
        kind: EdgeKind
    ) -> SCNNode {
        let diff = b - a
        let length = simd_length(diff)
        guard length > 0.001 else { return SCNNode() }

        let cyl = SCNCylinder(radius: Const.edgeCylinderRadius, height: CGFloat(length))
        cyl.radialSegmentCount = Const.edgeRadialSegmentCount
        let cylMaterial = SCNMaterial()
        cylMaterial.diffuse.contents = edgeColor(for: kind)
        cylMaterial.lightingModel = .phong
        cyl.firstMaterial = cylMaterial

        let node = SCNNode(geometry: cyl)
        node.position = SCNVector3(
            (a.x + b.x) / 2,
            (a.y + b.y) / 2,
            (a.z + b.z) / 2
        )
        node.look(
            at: SCNVector3(b.x, b.y, b.z),
            up: SCNVector3(0, 1, 0),
            localFront: node.worldUp
        )
        return node
    }

    // MARK: - Color Helpers

    private func sphereColor(for nodeType: NodeType) -> UIColor {
        switch nodeType {
        case .corridor: return UIColor.white
        case .corner:   return UIColor.yellow
        }
    }

    private func edgeColor(for kind: EdgeKind) -> UIColor {
        switch kind {
        case .sequential:    return UIColor.white
        case .proximity:     return UIColor.cyan
        case .transition:    return UIColor.yellow
        case .cornerPolygon: return UIColor.yellow.withAlphaComponent(0.6)
        }
    }
}

// MARK: - ARSCNViewDelegate

extension MarkARSceneOverlay: ARSCNViewDelegate {

    /// ARKit이 anchor 추가 후 다음 frame에 호출 — SCNNode를 반환하면 anchor.transform에 자동 부착.
    /// nonisolated context: stateLock으로 보호된 nodeMetas만 읽고, SCNNode 생성은 render thread에서 수행.
    nonisolated func renderer(
        _ renderer: SCNSceneRenderer,
        nodeFor anchor: ARAnchor
    ) -> SCNNode? {
        guard let name = anchor.name else { return nil }

        // 1) branch (corridor/corner) anchor
        if name.hasPrefix(MarkARSceneOverlay.Const.anchorNamePrefix) {
            let suffix = name.dropFirst(MarkARSceneOverlay.Const.anchorNamePrefix.count)
            guard let nodeId = BranchMarkNodeId(suffix) else { return nil }

            stateLock.lock()
            let meta = nodeMetas[nodeId]
            stateLock.unlock()

            guard let meta else { return nil }

            let parent = makePlainMarkerNode(order: meta.order, nodeType: meta.nodeType)
            let capturedId = nodeId
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scnNodeByNodeId[capturedId] = parent
                let wx = String(format: "%.3f", anchor.transform.columns.3.x)
                let wy = String(format: "%.3f", anchor.transform.columns.3.y)
                let wz = String(format: "%.3f", anchor.transform.columns.3.z)
                self.logger.debug(
                    "SCN_DEBUG nodeAttached nodeId=\(capturedId) order=\(meta.order) type=\(meta.nodeType.rawValue) world=(\(wx),\(wy),\(wz))"
                )
            }
            return parent
        }

        // 2) standalone (interfloor / poi) anchor
        if name.hasPrefix(MarkARSceneOverlay.Const.standaloneAnchorNamePrefix) {
            // 형식: "standalone_<kindRaw>_<UUID>"
            // kindRaw에 underscore 포함 가능 (interfloor_elevator 등) → lastIndex(of:"_")로 UUID 분리
            let suffix = name.dropFirst(MarkARSceneOverlay.Const.standaloneAnchorNamePrefix.count)
            guard let lastUnderscoreIdx = suffix.lastIndex(of: "_") else { return nil }
            let kindRaw = String(suffix[..<lastUnderscoreIdx])
            let idStr = String(suffix[suffix.index(after: lastUnderscoreIdx)...])
            guard let kind = StandaloneMarkerKind(rawValue: kindRaw),
                  let id = UUID(uuidString: idStr) else { return nil }

            stateLock.lock()
            let meta = standaloneMetas[id]
            stateLock.unlock()
            guard let meta else { return nil }

            let parent = makeStandaloneMarkerNode(kind: kind, label: meta.label)
            let capturedId = id
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.standaloneNodeById[capturedId] = parent
                let wx = String(format: "%.3f", anchor.transform.columns.3.x)
                let wy = String(format: "%.3f", anchor.transform.columns.3.y)
                let wz = String(format: "%.3f", anchor.transform.columns.3.z)
                self.logger.debug(
                    "SCN_DEBUG standaloneAttached id=\(capturedId) kind=\(kind.rawValue) label=\(meta.label) world=(\(wx),\(wy),\(wz))"
                )
            }
            return parent
        }

        return nil
    }

    // MARK: - nonisolated 전용 factory (render thread에서 호출)

    /// Standalone marker (interfloor / POI) — sphere + label. 엣지 자동 연결 없음.
    /// render thread 호출 가능, `self` 접근 없음.
    nonisolated private func makeStandaloneMarkerNode(
        kind: StandaloneMarkerKind,
        label: String
    ) -> SCNNode {
        let parent = SCNNode()

        let sphereGeom = SCNSphere(radius: 0.06)
        sphereGeom.segmentCount = 16
        let mat = SCNMaterial()
        // Sprint 88 cycle_7: 4-case 색 분기
        switch kind {
        case .interfloorElevator:   mat.diffuse.contents = UIColor.systemTeal
        case .interfloorStairs:     mat.diffuse.contents = UIColor.systemOrange
        case .interfloorEscalator:  mat.diffuse.contents = UIColor.systemPurple
        case .poi:                  mat.diffuse.contents = UIColor.systemBlue
        }
        mat.emission.contents = UIColor(white: 0.3, alpha: 1.0)
        mat.lightingModel = .phong
        sphereGeom.firstMaterial = mat
        let sphereNode = SCNNode(geometry: sphereGeom)
        let pulse = SCNAction.sequence([
            SCNAction.scale(to: 1.5, duration: 0.0),
            SCNAction.scale(to: 1.0, duration: 0.3)
        ])
        sphereNode.runAction(pulse)
        parent.addChildNode(sphereNode)

        let textGeom = SCNText(string: label, extrusionDepth: 0)
        textGeom.font = UIFont.boldSystemFont(ofSize: 0.06)
        let textMat = SCNMaterial()
        textMat.diffuse.contents = UIColor.white
        textMat.isDoubleSided = true
        textGeom.firstMaterial = textMat
        let labelNode = SCNNode(geometry: textGeom)
        let (minB, maxB) = textGeom.boundingBox
        labelNode.pivot = SCNMatrix4MakeTranslation(
            (maxB.x - minB.x) / 2,
            (maxB.y - minB.y) / 2,
            0
        )
        labelNode.position = SCNVector3(0, 0.10, 0)
        let billboard = SCNBillboardConstraint()
        billboard.freeAxes = .Y
        labelNode.constraints = [billboard]
        parent.addChildNode(labelNode)

        return parent
    }

    /// render thread에서 호출 가능한 SCNNode 생성. `self` 접근 없음.
    nonisolated private func makePlainMarkerNode(order: Int, nodeType: NodeType) -> SCNNode {
        let parent = SCNNode()

        let radius: CGFloat = nodeType == .corner ? 0.05 : 0.05
        let sphereGeom = SCNSphere(radius: radius)
        sphereGeom.segmentCount = 16
        let sphereMaterial = SCNMaterial()
        sphereMaterial.diffuse.contents = nodeType == .corner ? UIColor.yellow : UIColor.white
        sphereMaterial.emission.contents = UIColor(white: 0.25, alpha: 1.0)
        sphereMaterial.lightingModel = .phong
        sphereGeom.firstMaterial = sphereMaterial
        let sphereNode = SCNNode(geometry: sphereGeom)

        let pulse = SCNAction.sequence([
            SCNAction.scale(to: 1.5, duration: 0.0),
            SCNAction.scale(to: 1.0, duration: 0.3)
        ])
        sphereNode.runAction(pulse)
        parent.addChildNode(sphereNode)

        // Order label
        let textGeom = SCNText(string: "\(order)", extrusionDepth: 0)
        textGeom.font = UIFont.boldSystemFont(ofSize: 0.06)
        let textMaterial = SCNMaterial()
        textMaterial.diffuse.contents = UIColor.white
        textMaterial.isDoubleSided = true
        textGeom.firstMaterial = textMaterial

        let labelNode = SCNNode(geometry: textGeom)
        let (minBound, maxBound) = textGeom.boundingBox
        labelNode.pivot = SCNMatrix4MakeTranslation(
            (maxBound.x - minBound.x) / 2,
            (maxBound.y - minBound.y) / 2,
            0
        )
        labelNode.position = SCNVector3(0, 0.10, 0)

        let billboard = SCNBillboardConstraint()
        billboard.freeAxes = .Y
        labelNode.constraints = [billboard]
        parent.addChildNode(labelNode)

        return parent
    }
}
