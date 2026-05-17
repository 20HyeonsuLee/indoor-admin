import Foundation
import simd

// MARK: - Supporting Types

typealias BranchMarkNodeId = Int64

enum NodeType: String, Equatable {
    case corridor
    case corner
}

enum ConnectHint: String, Equatable {
    case proximity
}

enum EdgeKind: String, Equatable {
    case sequential
    case proximity
    case transition        // width 차이가 있는 인접 corridor 노드 간
    case cornerPolygon     // 같은 corner session 내 노드 연결 (preview용)
}

enum ConnectMode: Equatable {
    case sequential
    case proximityArmed
}

// MARK: - Node / Edge

struct BranchMarkNode: Identifiable, Equatable {
    let id: BranchMarkNodeId
    let nodeType: NodeType
    let widthM: Double?
    let connectHint: ConnectHint?
    let connectNodeId: BranchMarkNodeId?
    let markSessionId: UUID?
    let position: SIMD3<Float>
    let order: Int            // 마크 순서 번호 (1-based)
}

struct BranchMarkEdge: Identifiable, Equatable {
    let id: UUID
    let from: BranchMarkNodeId
    let to: BranchMarkNodeId
    let kind: EdgeKind
    var lengthM: Double        // 룰 검증용

    init(from: BranchMarkNodeId, to: BranchMarkNodeId, kind: EdgeKind, lengthM: Double) {
        self.id = UUID()
        self.from = from
        self.to = to
        self.kind = kind
        self.lengthM = lengthM
    }
}

// MARK: - Undo Action

enum UndoAction: Equatable {
    case addNode(nodeId: BranchMarkNodeId)
    /// POI 마크 추가. id = poi_mark.id. cascade로 poi_photo도 함께 제거.
    case addPoi(id: Int64)
    /// interfloor_mark 추가. id = interfloor_mark.id.
    case addInterfloor(id: Int64)
}

// MARK: - Hint Banner Case

enum HintBannerCase: Equatable {
    case trackingLimited
    case transitionDistanceExceeded(from: BranchMarkNodeId, to: BranchMarkNodeId)
    case backtracking
    case missingBranch(fromNodeId: BranchMarkNodeId)
    case proximityAmbiguous

    var priority: Int {
        switch self {
        case .trackingLimited:            return 0
        case .transitionDistanceExceeded: return 1
        case .backtracking:               return 2
        case .missingBranch:              return 3
        case .proximityAmbiguous:         return 4
        }
    }
}

// MARK: - Finalize Checklist Result

struct FinalizeChecklistResult: Equatable {
    var isolatedNodeOrders: [Int]
    var outlierEdgeNodeOrderPairs: [(Int, Int)]  // (fromOrder, toOrder)
    var transitionDistanceExceededPairs: [(Int, Int)]

    var hasIssues: Bool {
        !isolatedNodeOrders.isEmpty ||
        !outlierEdgeNodeOrderPairs.isEmpty ||
        !transitionDistanceExceededPairs.isEmpty
    }

    // Equatable 수동 구현 (tuple array)
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.isolatedNodeOrders == rhs.isolatedNodeOrders &&
        lhs.outlierEdgeNodeOrderPairs.map { "\($0.0),\($0.1)" } ==
        rhs.outlierEdgeNodeOrderPairs.map { "\($0.0),\($0.1)" } &&
        lhs.transitionDistanceExceededPairs.map { "\($0.0),\($0.1)" } ==
        rhs.transitionDistanceExceededPairs.map { "\($0.0),\($0.1)" }
    }
}

// MARK: - MarkingState

/// 노드 마킹 in-memory 상태 단일 source of truth.
/// ScanStore가 보유하고, mutating method로 전이 룰을 실행한다.
struct MarkingState {

    // MARK: State

    private(set) var nodes: [BranchMarkNode] = []
    private(set) var edges: [BranchMarkEdge] = []
    private(set) var connectMode: ConnectMode = .sequential
    private(set) var lastCorridorWidthM: Double = 2.5
    private(set) var activeCornerSessionId: UUID?
    private(set) var lastNonCornerNodeId: BranchMarkNodeId?
    private(set) var undoStack: [UndoAction] = []
    private(set) var hintBannerCase: HintBannerCase?
    private(set) var pendingHintBanners: [HintBannerCase] = []

    /// Sprint 89 v9: tryCloseCornerPolygon 에서 실제로 닫힌 session ID set.
    /// closeCornerSession() (mode 전환 시 강제 종료) 은 이 set 에 추가하지 않는다.
    /// finalize 시 BranchEdgeRepository.insertAll(closedSessions:) 에 전달한다.
    private(set) var closedCornerSessionIds: Set<UUID> = []

    // MARK: - Width Transition Thresholds

    /// 폭 차이 임계값: 이보다 작으면 같은 레인.
    private static let widthSameThresholdRatio: Double = 0.1
    private static let widthSameThresholdAbs: Double = 0.3

    /// transition edge 허용 거리(m). 초과 시 edge 없음 + flag.
    private static let transitionMaxDistanceM: Double = 1.0

    /// outlier 감지: 평균 edge 길이 × 이 배수 초과 시 outlier.
    private static let outlierEdgeLengthFactor: Double = 2.0

    // MARK: - Width Setting

    mutating func setLastCorridorWidth(_ widthM: Double) {
        lastCorridorWidthM = widthM
    }

    // MARK: - addCorridor

    /// corridor 노드 추가. sequential 또는 proximity_armed에 따라 edge 생성.
    /// - Returns: 생성한 edge의 kind (검증/테스트용)
    @discardableResult
    mutating func addCorridor(
        nodeId: BranchMarkNodeId,
        at position: SIMD3<Float>,
        widthM: Double?,
        connectHint: ConnectHint?,
        connectNodeId: BranchMarkNodeId?
    ) -> EdgeKind? {
        let resolvedWidth = widthM ?? lastCorridorWidthM
        let node = BranchMarkNode(
            id: nodeId,
            nodeType: .corridor,
            widthM: resolvedWidth,
            connectHint: connectHint,
            connectNodeId: connectNodeId,
            markSessionId: nil,
            position: position,
            order: nodes.count + 1
        )
        nodes.append(node)
        undoStack.append(.addNode(nodeId: nodeId))
        lastCorridorWidthM = resolvedWidth

        var edgeKind: EdgeKind? = nil

        if connectMode == .proximityArmed, let targetId = connectNodeId {
            // proximity 모드: 사용자가 선택한 노드로 edge
            if let targetNode = nodes.first(where: { $0.id == targetId }) {
                let dist = distance(position, targetNode.position)
                if let kind = resolveEdgeKind(fromWidth: targetNode.widthM, toWidth: resolvedWidth, distance: Double(dist)) {
                    edges.append(BranchMarkEdge(from: targetId, to: nodeId, kind: kind, lengthM: Double(dist)))
                    edgeKind = kind
                } else {
                    // PRD §5.4: 폭 차이 + 거리 > 1m → edge 없음 + reviewer flag
                    pendingHintBanners.append(.transitionDistanceExceeded(from: targetId, to: nodeId))
                }
                checkTransitionFlag(from: targetNode, to: node, dist: Double(dist))
            }
            connectMode = .sequential   // proximity 후 sequential 복귀
        } else if connectMode == .sequential, let lastId = lastNonCornerNodeId {
            // sequential 모드: 직전 노드와 edge
            if let lastNode = nodes.first(where: { $0.id == lastId }) {
                let dist = distance(position, lastNode.position)
                if let kind = resolveEdgeKind(fromWidth: lastNode.widthM, toWidth: resolvedWidth, distance: Double(dist)) {
                    edges.append(BranchMarkEdge(from: lastId, to: nodeId, kind: kind, lengthM: Double(dist)))
                    edgeKind = kind
                } else {
                    // PRD §5.4: 폭 차이 + 거리 > 1m → edge 없음 + reviewer flag
                    pendingHintBanners.append(.transitionDistanceExceeded(from: lastId, to: nodeId))
                }
                checkTransitionFlag(from: lastNode, to: node, dist: Double(dist))
                checkBranchMissing(lastNode: lastNode, dist: Double(dist))
            }
        }

        lastNonCornerNodeId = nodeId
        refreshHintBanner()
        return edgeKind
    }

    // MARK: - addCorner

    /// corner 노드 추가. activeCornerSessionId가 설정되어 있어야 한다.
    mutating func addCorner(
        nodeId: BranchMarkNodeId,
        at position: SIMD3<Float>
    ) {
        guard let sessionId = activeCornerSessionId else { return }

        let node = BranchMarkNode(
            id: nodeId,
            nodeType: .corner,
            widthM: nil,
            connectHint: nil,
            connectNodeId: nil,
            markSessionId: sessionId,
            position: position,
            order: nodes.count + 1
        )
        nodes.append(node)
        undoStack.append(.addNode(nodeId: nodeId))

        // 같은 session 내 이전 corner 노드와 corner_polygon edge 생성
        let sameSession = nodes.dropLast().filter { $0.markSessionId == sessionId }
        if let prev = sameSession.last {
            let dist = distance(position, prev.position)
            edges.append(BranchMarkEdge(from: prev.id, to: nodeId, kind: .cornerPolygon, lengthM: Double(dist)))
        }

        refreshHintBanner()
    }

    // MARK: - Connect Mode

    mutating func armProximity() {
        connectMode = .proximityArmed
        refreshHintBanner()
    }

    /// proximity 모드에서 사용자가 대상 노드를 선택했을 때 호출.
    /// 선택 후 sequential로 복귀.
    mutating func selectProximityTarget(_ targetId: BranchMarkNodeId) {
        connectMode = .sequential
        refreshHintBanner()
    }

    /// proximity 모드 취소 — sequential로 복귀 (sheet 닫기 시).
    mutating func resetToSequential() {
        connectMode = .sequential
        refreshHintBanner()
    }

    // MARK: - Corner Session

    mutating func startCornerSession() {
        activeCornerSessionId = UUID()
    }

    mutating func closeCornerSession() {
        activeCornerSessionId = nil
    }

    // MARK: - Corner Polygon Auto-Close (Sprint 88 cycle_7)

    /// corner polygon 자동 close 결과.
    enum CornerCloseResult: Equatable {
        case notInCornerMode
        case noCornerYet
        case needAtLeastTwoCorners
        case tooFar(distance: Float)
        case closed(nodeCount: Int, firstNodeId: BranchMarkNodeId)
    }

    /// raycast hit 위치가 같은 session의 첫 corner 노드에 가까우면 polygon을 닫는다.
    ///
    /// close 조건:
    /// - activeCornerSessionId != nil (corner 모드)
    /// - 같은 session corner 노드 ≥ 2개
    /// - xz 평면 거리 < thresholdM (y는 floor projection으로 두 점 모두 floorY)
    ///
    /// close 시:
    /// - last ↔ first cornerPolygon closing edge 추가
    /// - activeCornerSessionId = nil (자동 종료)
    mutating func tryCloseCornerPolygon(
        at hitPosition: SIMD3<Float>,
        thresholdM: Float = 0.30
    ) -> CornerCloseResult {
        guard let sessionId = activeCornerSessionId else { return .notInCornerMode }
        let sameSession = nodes.filter { $0.markSessionId == sessionId }
        guard let first = sameSession.first else { return .noCornerYet }
        guard sameSession.count >= 2 else { return .needAtLeastTwoCorners }

        // xz 평면 거리만 사용 — y는 floor projection으로 두 점 모두 floorY 근방
        let dx = first.position.x - hitPosition.x
        let dz = first.position.z - hitPosition.z
        let xzDist = sqrtf(dx * dx + dz * dz)
        guard xzDist < thresholdM else { return .tooFar(distance: xzDist) }

        // close: last → first closing edge 추가
        if let last = sameSession.last {
            let lengthM = simd_length(last.position - first.position)
            edges.append(BranchMarkEdge(
                from: last.id, to: first.id,
                kind: .cornerPolygon, lengthM: Double(lengthM)
            ))
        }
        // Sprint 89 v9: 닫힌 session ID 기록 — BranchEdgeRepository.insertAll 에서 polygon_closed=1 판정에 사용.
        closedCornerSessionIds.insert(sessionId)
        activeCornerSessionId = nil   // 자동 종료
        refreshHintBanner()
        return .closed(nodeCount: sameSession.count, firstNodeId: first.id)
    }

    // MARK: - Undo

    /// 외부 (POI/interfloor) 추가 시 undo stack 에 등록.
    /// branch_mark 는 addCorridor/addCorner 가 직접 append 하므로 호출 불필요.
    mutating func recordExternalAdd(_ action: UndoAction) {
        undoStack.append(action)
    }

    /// 최근 count 개 action 을 pop 하고 in-memory 상태에서 제거 (branch_mark 만 nodes 배열 영향).
    /// 반환된 action 리스트는 호출자가 DB delete 분기 처리.
    @discardableResult
    mutating func undoLast(count: Int = 1) -> [UndoAction] {
        var popped: [UndoAction] = []
        var remaining = count
        while remaining > 0, !undoStack.isEmpty {
            let action = undoStack.removeLast()
            switch action {
            case .addNode(let nodeId):
                deleteNodeInternal(nodeId)
            case .addPoi, .addInterfloor:
                // POI / interfloor 는 MarkingState.nodes 에 없음. DB 제거만 필요.
                break
            }
            popped.append(action)
            remaining -= 1
        }
        // lastNonCornerNodeId 갱신
        lastNonCornerNodeId = nodes.last(where: { $0.nodeType == .corridor })?.id
        refreshHintBanner()
        return popped
    }

    // MARK: - Delete

    /// overlay tap → confirm 삭제. 연결 edge 자동 정리.
    mutating func deleteNode(_ nodeId: BranchMarkNodeId) {
        deleteNodeInternal(nodeId)
        undoStack.removeAll(where: { if case .addNode(let id) = $0 { return id == nodeId }; return false })
        lastNonCornerNodeId = nodes.last(where: { $0.nodeType == .corridor })?.id
        refreshHintBanner()
    }

    private mutating func deleteNodeInternal(_ nodeId: BranchMarkNodeId) {
        nodes.removeAll(where: { $0.id == nodeId })
        edges.removeAll(where: { $0.from == nodeId || $0.to == nodeId })
    }

    // MARK: - Update

    /// overlay tap → 수정 sheet. widthM과 nodeType을 갱신.
    mutating func updateNode(
        _ nodeId: BranchMarkNodeId,
        nodeType: NodeType,
        widthM: Double?
    ) {
        guard let index = nodes.firstIndex(where: { $0.id == nodeId }) else { return }
        let old = nodes[index]
        nodes[index] = BranchMarkNode(
            id: old.id,
            nodeType: nodeType,
            widthM: widthM,
            connectHint: old.connectHint,
            connectNodeId: old.connectNodeId,
            markSessionId: old.markSessionId,
            position: old.position,
            order: old.order
        )
        refreshHintBanner()
    }

    // MARK: - Edge Count Helper (F7)

    /// 특정 nodeId에 연결된 edge 수 반환 (NodeEditSheet 표시용).
    func edgeCount(for nodeId: BranchMarkNodeId) -> Int {
        edges.filter { $0.from == nodeId || $0.to == nodeId }.count
    }

    // MARK: - Proximity Candidates

    /// 현재 pose에서 radiusM 이내의 corridor 노드 top-3 반환 (거리 오름차순).
    func proximityCandidates(for position: SIMD3<Float>, radiusM: Float = 3.0) -> [BranchMarkNode] {
        nodes
            .filter { $0.nodeType == .corridor }
            .map { node in (node: node, dist: distance(position, node.position)) }
            .filter { $0.dist <= radiusM }
            .sorted { $0.dist < $1.dist }
            .prefix(3)
            .map { $0.node }
    }

    // MARK: - Backtracking Detection

    /// 직전 노드 1m 이내 + 방향 reversal(≥ 90°) 감지.
    /// - Parameters:
    ///   - currentPosition: 현재 카메라 위치
    ///   - heading: 현재 카메라 heading vector (XZ 평면)
    /// - Returns: 백트래킹 감지 시 true
    func detectBacktracking(currentPosition: SIMD3<Float>, heading: SIMD3<Float>) -> Bool {
        guard let lastId = lastNonCornerNodeId,
              let lastNode = nodes.first(where: { $0.id == lastId })
        else { return false }

        let toLastNode = lastNode.position - currentPosition
        let dist = simd_length(toLastNode)
        guard dist < 1.0, dist > 0.01 else { return false }

        // heading 방향과 lastNode 방향의 각도가 90° 이상이면 reversal
        let normalizedHeading = simd_normalize(SIMD3<Float>(heading.x, 0, heading.z))
        let normalizedToNode = simd_normalize(SIMD3<Float>(toLastNode.x, 0, toLastNode.z))
        let dot = simd_dot(normalizedHeading, normalizedToNode)
        // dot > 0 이면 같은 방향, dot < 0 이면 반대 방향으로 이동 중
        return dot > 0  // 왔던 방향으로 돌아가는 중
    }

    // MARK: - Finalize Checklist

    /// isolated 노드 / outlier edge / transition 거리 초과 목록 반환.
    func finalizeChecklist() -> FinalizeChecklistResult {
        // isolated: edge가 전혀 없는 노드
        let connectedIds = Set(edges.flatMap { [$0.from, $0.to] })
        let isolatedOrders = nodes
            .filter { !connectedIds.contains($0.id) }
            .map { $0.order }

        // outlier edge: 길이가 평균 × outlierEdgeLengthFactor 초과
        let sequentialEdges = edges.filter { $0.kind == .sequential || $0.kind == .proximity }
        let avgLen = sequentialEdges.isEmpty ? 0.0 : sequentialEdges.map { $0.lengthM }.reduce(0, +) / Double(sequentialEdges.count)
        let threshold = avgLen * Self.outlierEdgeLengthFactor
        let outlierPairs: [(Int, Int)] = threshold > 0 ? sequentialEdges
            .filter { $0.lengthM > threshold }
            .compactMap { edge -> (Int, Int)? in
                guard let fromOrder = nodes.first(where: { $0.id == edge.from })?.order,
                      let toOrder = nodes.first(where: { $0.id == edge.to })?.order
                else { return nil }
                return (fromOrder, toOrder)
            } : []

        // transition 거리 초과: transition edge 중 lengthM > 1m
        let transitionPairs: [(Int, Int)] = edges
            .filter { $0.kind == .transition && $0.lengthM > Self.transitionMaxDistanceM }
            .compactMap { edge -> (Int, Int)? in
                guard let fromOrder = nodes.first(where: { $0.id == edge.from })?.order,
                      let toOrder = nodes.first(where: { $0.id == edge.to })?.order
                else { return nil }
                return (fromOrder, toOrder)
            }

        return FinalizeChecklistResult(
            isolatedNodeOrders: isolatedOrders,
            outlierEdgeNodeOrderPairs: outlierPairs,
            transitionDistanceExceededPairs: transitionPairs
        )
    }

    // MARK: - Hit-test (재연결 흐름 — edge split / node anchor)

    /// world hit point에 가까운 노드 반환. maxDistance(world meters) 안에서 가장 가까운 것.
    func hitTestNode(at worldPoint: SIMD3<Float>, maxDistance: Float) -> BranchMarkNodeId? {
        var best: (BranchMarkNodeId, Float)?
        for node in nodes {
            let d = distance(worldPoint, node.position)
            guard d <= maxDistance else { continue }
            if best == nil || d < best!.1 { best = (node.id, d) }
        }
        return best?.0
    }

    /// world hit point가 어떤 edge 위에 있는지 hit-test.
    /// 선분 내부(t ∈ [0,1])이고 foot까지 거리가 maxDistance 이내면 match.
    /// corner_polygon edge는 split 차단을 위해 제외한다.
    func hitTestEdge(at worldPoint: SIMD3<Float>, maxDistance: Float) -> (edgeId: UUID, foot: SIMD3<Float>)? {
        var best: (UUID, SIMD3<Float>, Float)?
        for edge in edges where edge.kind != .cornerPolygon {
            guard let a = nodes.first(where: { $0.id == edge.from })?.position,
                  let b = nodes.first(where: { $0.id == edge.to })?.position else { continue }
            let ab = b - a
            let lenSq = simd_dot(ab, ab)
            guard lenSq > 1e-6 else { continue }
            let t = simd_dot(worldPoint - a, ab) / lenSq
            guard t >= 0, t <= 1 else { continue }
            let foot = a + t * ab
            let d = simd_distance(worldPoint, foot)
            guard d <= maxDistance else { continue }
            if best == nil || d < best!.2 { best = (edge.id, foot, d) }
        }
        return best.map { (edgeId: $0.0, foot: $0.1) }
    }

    /// 이미 존재하는 노드 위에 클릭한 경우 — 그 노드를 sequential 시작점으로 anchor.
    /// 새 노드 생성/edge 추가 없음. 다음 corridor tap이 이 노드에서 시작하는 sequential edge를 만듦.
    mutating func anchorAtNode(nodeId: BranchMarkNodeId) {
        guard nodes.contains(where: { $0.id == nodeId }) else { return }
        lastNonCornerNodeId = nodeId
        connectMode = .sequential
    }

    /// edge 위 클릭 → 해당 edge를 두 segment로 split. 새 corridor 노드는 sequential 시작점.
    /// 새 노드 widthM = A·B width 평균 (둘 다 있을 때). markSessionId = 새 UUID.
    /// - Returns: 생성된 새 노드. corner_polygon edge거나 매칭 실패면 nil.
    @discardableResult
    mutating func splitEdge(
        edgeId: UUID,
        newNodeId: BranchMarkNodeId,
        at position: SIMD3<Float>
    ) -> BranchMarkNode? {
        guard let edgeIndex = edges.firstIndex(where: { $0.id == edgeId }) else { return nil }
        let edge = edges[edgeIndex]
        guard edge.kind != .cornerPolygon else { return nil }
        guard let aIdx = nodes.firstIndex(where: { $0.id == edge.from }),
              let bIdx = nodes.firstIndex(where: { $0.id == edge.to }) else { return nil }
        let nodeA = nodes[aIdx]
        let nodeB = nodes[bIdx]
        let avgWidth: Double? = {
            switch (nodeA.widthM, nodeB.widthM) {
            case let (wa?, wb?): return (wa + wb) / 2.0
            case let (wa?, nil): return wa
            case let (nil, wb?): return wb
            default: return nil
            }
        }()
        let resolvedWidth = avgWidth ?? lastCorridorWidthM
        let newNode = BranchMarkNode(
            id: newNodeId,
            nodeType: .corridor,
            widthM: resolvedWidth,
            connectHint: nil,
            connectNodeId: nil,
            markSessionId: UUID(),
            position: position,
            order: nodes.count + 1
        )
        nodes.append(newNode)
        undoStack.append(.addNode(nodeId: newNodeId))

        // 기존 edge 제거 + 두 새 edge 추가
        edges.remove(at: edgeIndex)
        let distA = Double(distance(position, nodeA.position))
        let distB = Double(distance(position, nodeB.position))
        let kindA = resolveEdgeKind(fromWidth: nodeA.widthM, toWidth: resolvedWidth, distance: distA) ?? .sequential
        let kindB = resolveEdgeKind(fromWidth: resolvedWidth, toWidth: nodeB.widthM, distance: distB) ?? .sequential
        edges.append(BranchMarkEdge(from: nodeA.id, to: newNodeId, kind: kindA, lengthM: distA))
        edges.append(BranchMarkEdge(from: newNodeId, to: nodeB.id, kind: kindB, lengthM: distB))

        lastNonCornerNodeId = newNodeId
        lastCorridorWidthM = resolvedWidth
        connectMode = .sequential
        return newNode
    }

    // MARK: - Private Helpers

    private func resolveEdgeKind(fromWidth: Double?, toWidth: Double?, distance: Double) -> EdgeKind? {
        guard let fw = fromWidth, let tw = toWidth else { return .sequential }
        let diff = abs(fw - tw)
        let ratio = diff / max(fw, tw)
        let isSame = diff <= Self.widthSameThresholdAbs || ratio <= Self.widthSameThresholdRatio

        if isSame { return .sequential }

        // 폭 차이 있음
        if distance <= Self.transitionMaxDistanceM {
            return .transition
        } else {
            // PRD §5.4: 거리 > 1m + 폭 차이 → edge 없음 + reviewer flag
            // 호출자(addCorridor)에서 nil 처리 → edge skip + pendingHintBanners append
            return nil
        }
    }

    // checkTransitionFlag: 이전에 >1m 거리 시 flag를 추가했으나,
    // addCorridor에서 resolveEdgeKind nil 분기로 이미 처리됨. 빈 stub 유지 (호출 코드 제거 X).
    private mutating func checkTransitionFlag(from: BranchMarkNode, to: BranchMarkNode, dist: Double) {
        // no-op: addCorridor의 resolveEdgeKind nil 분기에서 pendingHintBanners 처리
    }

    private mutating func checkBranchMissing(lastNode: BranchMarkNode, dist: Double) {
        let avgLen: Double = {
            let seqEdges = edges.filter { $0.kind == .sequential || $0.kind == .proximity }
            guard !seqEdges.isEmpty else { return 0 }
            return seqEdges.map { $0.lengthM }.reduce(0, +) / Double(seqEdges.count)
        }()
        if avgLen > 0, dist > avgLen * Self.outlierEdgeLengthFactor {
            pendingHintBanners.append(.missingBranch(fromNodeId: lastNode.id))
        }
    }

    private mutating func refreshHintBanner() {
        // 우선순위 최고인 banner 하나만 노출
        hintBannerCase = pendingHintBanners.min(by: { $0.priority < $1.priority })
        pendingHintBanners.removeAll()
    }
}

// MARK: - simd_length helper (SIMD3<Float>)

private func distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
    simd_length(b - a)
}
