import SwiftUI

// MARK: - Graph Data Models

/// node.connector 메타 (passage 정보를 node에서 derive)
struct NodeConnector {
    let type: String
    let key: String
}

struct GraphNode: Identifiable {
    let id: UUID
    let x: Double
    let y: Double
    let label: String?
    /// area별 색상 분리에 사용. single-area 모드에서는 nil.
    let areaId: UUID?
    /// node.type 필드 (poi / corridor / connector 등)
    let category: String?
    /// connector 메타. type == "connector" 이거나 connector 객체가 있는 노드.
    let connector: NodeConnector?

    init(id: UUID, x: Double, y: Double, label: String?, areaId: UUID? = nil, category: String? = nil, connector: NodeConnector? = nil) {
        self.id = id
        self.x = x
        self.y = y
        self.label = label
        self.areaId = areaId
        self.category = category
        self.connector = connector
    }
}

struct GraphEdge: Identifiable {
    let id: UUID
    /// 서버 edge id (route 결과 매칭용)
    let edgeServerId: UUID?
    /// route 계산용 fromNode/toNode id
    let fromNodeId: UUID?
    let toNodeId: UUID?
    /// 미터 단위 길이 (route 비용)
    let lengthM: Double?
    let fromX: Double
    let fromY: Double
    let toX: Double
    let toY: Double
}

struct GraphPOI: Identifiable {
    let id: UUID            // domain poi_id (탭/선택 식별자)
    let routeNodeId: UUID?  // graph node_id (라우팅용). nil이면 destination 불가.
    let name: String
    let x: Double
    let y: Double
    let category: String
}

struct GraphPassage: Identifiable {
    let id: UUID            // domain passage_id (탭/선택 식별자)
    let routeNodeId: UUID?  // 해당 floor segment의 graph node_id (라우팅용)
    let connectorType: String
    let connectorKey: String
    let name: String?
    let x: Double
    let y: Double
}

struct GraphBounds {
    let minX: Double
    let minY: Double
    let maxX: Double
    let maxY: Double

    var width: Double { max(maxX - minX, 1) }
    var height: Double { max(maxY - minY, 1) }

    static let empty = GraphBounds(minX: -10, minY: -10, maxX: 10, maxY: 10)
}

struct FloorGraphPayload {
    var nodes: [GraphNode]
    var edges: [GraphEdge]
    var pois: [GraphPOI]
    var passages: [GraphPassage]
    var bounds: GraphBounds
    /// area별 색상 매핑 (multi-area일 때만 채워짐). key = areaId.
    var areaColors: [UUID: Color]
    /// legend용: (areaId, label) 순서 배열.
    var areaLegend: [(id: UUID, label: String)]
    /// GeoJSON polygon 파싱 결과. 각 요소 = 하나의 Polygon feature 외곽 ring. world meter 좌표.
    var polygons: [[CGPoint]]

    init(
        nodes: [GraphNode],
        edges: [GraphEdge],
        pois: [GraphPOI],
        passages: [GraphPassage],
        bounds: GraphBounds,
        areaColors: [UUID: Color] = [:],
        areaLegend: [(id: UUID, label: String)] = [],
        polygons: [[CGPoint]] = []
    ) {
        self.nodes = nodes
        self.edges = edges
        self.pois = pois
        self.passages = passages
        self.bounds = bounds
        self.areaColors = areaColors
        self.areaLegend = areaLegend
        self.polygons = polygons
    }
}

// MARK: - View

struct AdminFloorGraphView: View {
    @State var workspace: AdminWorkspaceStore
    let building: AdminBuilding
    let floor: AdminFloor

    @State private var payload: FloorGraphPayload?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedNodeId: UUID?
    @State private var selectedPOI: GraphPOI?
    @State private var selectedPassage: GraphPassage?

    // Sprint 78 B-2: 길찾기 상태
    @State private var startNodeId: UUID?           // 출발지 (corridor 탭 선택)
    @State private var destinationSearch: String = ""
    @State private var destinationNodeId: UUID?     // 목적지 POI routeNodeId
    @State private var destinationLabel: String?    // 목적지 표시 레이블
    @State private var routeResult: PathfindingResponse?
    @State private var routeNodeIds: Set<String> = []
    @State private var routeEdgeIds: Set<String> = []
    @State private var isRouteLoading = false
    @State private var routeError: String?

    // Sprint 95: pinch-to-zoom + drag pan
    @State private var zoom: CGFloat = 1.0
    @State private var lastZoom: CGFloat = 1.0
    @State private var pan: CGSize = .zero
    @State private var lastPan: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if isLoading {
                    ProgressView("그래프 로딩 중...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let msg = errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.orange)
                        Text(msg)
                            .multilineTextAlignment(.center)
                        Button("다시 시도") { Task { await loadGraph() } }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let p = payload, p.nodes.isEmpty {
                    ContentUnavailableView(
                        "그래프가 아직 빌드되지 않았습니다",
                        systemImage: "map",
                        description: Text("병합 및 빌드를 완료한 후 다시 시도하세요.")
                    )
                } else if let p = payload {
                    VStack(spacing: 0) {
                        // Sprint 78 B-3: 길찾기 toolbar
                        routeToolbar(p)
                        graphCanvas(p, size: CGSize(width: geo.size.width, height: geo.size.height - routeToolbarHeight(p)))
                    }
                }

                // Tap info overlay
                VStack {
                    Spacer()
                    if let poi = selectedPOI {
                        POIInfoCard(poi: poi) { selectedPOI = nil }
                            .padding()
                    } else if let passage = selectedPassage {
                        PassageInfoCard(passage: passage) { selectedPassage = nil }
                            .padding()
                    } else if selectedNodeId != nil {
                        HStack {
                            Text("노드 ID: \(selectedNodeId?.uuidString.prefix(8) ?? "")")
                                .font(.caption)
                            Spacer()
                            Button("닫기") { selectedNodeId = nil }
                                .font(.caption)
                        }
                        .padding()
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .padding()
                    }
                }
            }
        }
        .navigationTitle("그래프 보기")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task { await loadGraph() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .task {
            await loadGraph()
        }
        .onChange(of: workspace.selectedAreaId[floor.id]) { _, _ in
            Task { await loadGraph() }
        }
    }

    // MARK: - Route Toolbar

    private func routeToolbarHeight(_ p: FloorGraphPayload) -> CGFloat {
        let destinations = routeDestinations(p)
        if destinations.isEmpty { return 0 }
        // 결과 라인은 result/error 있을 때만. 기본 1줄 + 가변 1줄
        let hasSecondary = routeResult != nil || routeError != nil || isRouteLoading
        return hasSecondary ? 80 : 50
    }

    @ViewBuilder
    private func routeToolbar(_ p: FloorGraphPayload) -> some View {
        let destinations = routeDestinations(p)
        if !destinations.isEmpty {
            VStack(spacing: 4) {
                // 단일 행: [출발 chip] [화살표] [목적지 chip] [찾기] [reset]
                HStack(spacing: 8) {
                    sourceChip
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    destinationChip(destinations)
                    Spacer(minLength: 4)
                    Button {
                        Task { await findRoute(p) }
                    } label: {
                        if isRouteLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                        }
                    }
                    .disabled(startNodeId == nil || destinationNodeId == nil || isRouteLoading)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button {
                        resetRoute()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(startNodeId == nil && destinationNodeId == nil && routeResult == nil)
                }

                // 결과/에러 라인 (있을 때만)
                if let r = routeResult {
                    HStack(spacing: 6) {
                        Image(systemName: "ruler").font(.caption2).foregroundStyle(.secondary)
                        Text(String(format: "%.1fm · 약 %d초 · %d스텝",
                                    r.totalDistance,
                                    r.estimatedTimeSeconds,
                                    r.steps.count))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let first = r.steps.first, let inst = first.instruction {
                            Text(inst)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                } else if let err = routeError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.red)
                        Text(err).font(.caption2).foregroundStyle(.red).lineLimit(1)
                        Spacer()
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
        }
    }

    private var sourceChip: some View {
        let isSet = startNodeId != nil
        let label = isSet
            ? "출발 \(startNodeId!.uuidString.prefix(6))"
            : "출발 선택"
        return HStack(spacing: 4) {
            Image(systemName: isSet ? "circle.fill" : "circle.dotted")
                .font(.caption2)
                .foregroundStyle(isSet ? .yellow : .secondary)
            Text(label)
                .font(.caption)
                .foregroundStyle(isSet ? .primary : .secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary, in: Capsule())
    }

    @ViewBuilder
    private func destinationChip(_ destinations: [RouteDestination]) -> some View {
        let isSet = destinationNodeId != nil
        Menu {
            ForEach(destinations, id: \.id) { dest in
                Button(dest.label) {
                    destinationNodeId = dest.id
                    destinationLabel = dest.label
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isSet ? "mappin.circle.fill" : "mappin.circle")
                    .font(.caption2)
                    .foregroundStyle(isSet ? .red : .secondary)
                Text(destinationLabel ?? "목적지 선택")
                    .font(.caption)
                    .foregroundStyle(isSet ? .primary : .secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary, in: Capsule())
        }
    }

    private struct RouteDestination: Identifiable {
        let id: UUID
        let label: String
    }

    private func routeDestinations(_ p: FloorGraphPayload) -> [RouteDestination] {
        // pathfinding endpoint는 destinationName(POI 이름)을 받는다.
        // Passage는 지원하지 않으므로 POI만 후보로 노출.
        p.pois.compactMap { poi -> RouteDestination? in
            guard poi.routeNodeId != nil else { return nil }
            return RouteDestination(id: poi.id, label: poi.name)
        }
    }

    private func findRoute(_ p: FloorGraphPayload) async {
        guard let from = startNodeId,
              let destPoiId = destinationNodeId,
              let client = workspace.v1Client else { return }

        guard let startNode = p.nodes.first(where: { $0.id == from }) else {
            routeError = "출발 노드를 찾을 수 없음"
            return
        }
        guard let destPoi = p.pois.first(where: { $0.id == destPoiId }) else {
            routeError = "목적지 POI를 찾을 수 없음"
            return
        }

        isRouteLoading = true
        routeError = nil
        defer { isRouteLoading = false }

        let areaId = workspace.effectiveAreaId(floorId: floor.id)
        let req = PathfindingRequest(
            startScanId: nil,
            startAreaId: areaId,
            startFloorLevel: floor.level,
            startX: startNode.x,
            startY: startNode.y,
            startZ: 0,
            destinationName: destPoi.name,
            preference: nil,
            verticalPreference: nil
        )

        do {
            let result = try await client.pathfinding(buildingId: building.id, request: req)
            routeResult = result
            routeNodeIds = Set(result.steps.compactMap { $0.nodeId?.uuidString.uppercased() })
            routeEdgeIds = inferEdgeIdsBetween(steps: result.steps, allEdges: p.edges)
        } catch {
            routeError = error.localizedDescription
        }
    }

    private func inferEdgeIdsBetween(steps: [PathStepResponse], allEdges: [GraphEdge]) -> Set<String> {
        var ids: Set<String> = []
        for i in 0..<steps.count - 1 {
            guard let from = steps[i].nodeId, let to = steps[i + 1].nodeId else { continue }
            if let edge = allEdges.first(where: {
                ($0.fromNodeId == from && $0.toNodeId == to) ||
                ($0.fromNodeId == to && $0.toNodeId == from)
            }), let serverId = edge.edgeServerId {
                ids.insert(serverId.uuidString.uppercased())
            }
        }
        return ids
    }

    private func resetRoute() {
        startNodeId = nil
        destinationNodeId = nil
        destinationLabel = nil
        routeResult = nil
        routeNodeIds = []
        routeEdgeIds = []
        routeError = nil
    }

    // MARK: - Hit Test

    private func hitTestNode(at location: CGPoint, in p: FloorGraphPayload, viewScale: Double, padding: Double) {
        let tolerance: Double = 16
        var bestDist = tolerance
        var bestNodeId: UUID?
        for node in p.nodes {
            let pt = toDisplay(x: node.x, y: node.y, bounds: p.bounds, viewScale: viewScale, padding: padding)
            let dx = Double(location.x) - pt.x
            let dy = Double(location.y) - pt.y
            let dist = (dx * dx + dy * dy).squareRoot()
            if dist < bestDist {
                bestDist = dist
                bestNodeId = node.id
            }
        }
        if let nid = bestNodeId {
            startNodeId = nid
            selectedNodeId = nid
            selectedPOI = nil
            selectedPassage = nil
        }
    }

    // MARK: - Canvas

    private func toDisplay(x: Double, y: Double, bounds: GraphBounds, viewScale: Double, padding: Double) -> CGPoint {
        let dx = (x - bounds.minX) * viewScale + padding
        let dy = (bounds.maxY - y) * viewScale + padding  // y 축 반전
        return CGPoint(x: dx, y: dy)
    }

    @ViewBuilder
    private func graphCanvas(_ p: FloorGraphPayload, size: CGSize) -> some View {
        let bounds = p.bounds
        let padding: Double = 40

        // 좌표 변환: server(y-up) → SwiftUI(y-down)
        let scaleX = (Double(size.width) - padding * 2) / bounds.width
        let scaleY = (Double(size.height) - padding * 2) / bounds.height
        let viewScale = min(scaleX, scaleY)

        ZStack(alignment: .topTrailing) {
            graphContent(p, size: size, bounds: bounds, viewScale: viewScale, padding: padding)
                .scaleEffect(zoom, anchor: .center)
                .offset(pan)
                .clipped()
                .contentShape(Rectangle())
                // pinch zoom
                .simultaneousGesture(
                    MagnificationGesture()
                        .onChanged { value in
                            zoom = max(0.5, min(8.0, lastZoom * value))
                        }
                        .onEnded { _ in lastZoom = zoom }
                )
                // drag pan (minimumDistance 로 tap 과 분기)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { value in
                            pan = CGSize(
                                width: lastPan.width + value.translation.width,
                                height: lastPan.height + value.translation.height
                            )
                        }
                        .onEnded { _ in lastPan = pan }
                )
                // double-tap reset
                .onTapGesture(count: 2) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        zoom = 1.0
                        lastZoom = 1.0
                        pan = .zero
                        lastPan = .zero
                    }
                }

            // Area legend (areas > 1일 때만 우상단 chip)
            if workspace.areasForFloor(floor.id).count > 1 {
                areaLegendView(p)
                    .padding(8)
            }
        }
    }

    @ViewBuilder
    private func graphContent(_ p: FloorGraphPayload, size: CGSize, bounds: GraphBounds, viewScale: Double, padding: Double) -> some View {
        ZStack {
            // Polygon layer (BG — 노드/엣지 아래)
            Canvas { ctx, _ in
                for ring in p.polygons {
                    guard ring.count >= 3 else { continue }
                    var path = Path()
                    let first = toDisplay(x: Double(ring[0].x), y: Double(ring[0].y), bounds: bounds, viewScale: viewScale, padding: padding)
                    path.move(to: first)
                    for pt in ring.dropFirst() {
                        let dp = toDisplay(x: Double(pt.x), y: Double(pt.y), bounds: bounds, viewScale: viewScale, padding: padding)
                        path.addLine(to: dp)
                    }
                    path.closeSubpath()
                    ctx.fill(path, with: .color(.blue.opacity(0.08)))
                    ctx.stroke(path, with: .color(.blue.opacity(0.35)), lineWidth: 1.5)
                }
            }

            Canvas { ctx, _ in
                // Sprint 78 B-4: route highlight
                let hasRoute = !routeEdgeIds.isEmpty

                // Edges
                for edge in p.edges {
                    let from = toDisplay(x: edge.fromX, y: edge.fromY, bounds: bounds, viewScale: viewScale, padding: padding)
                    let to = toDisplay(x: edge.toX, y: edge.toY, bounds: bounds, viewScale: viewScale, padding: padding)
                    var path = Path()
                    path.move(to: from)
                    path.addLine(to: to)
                    let isRouteEdge = routeEdgeIds.contains(edge.id.uuidString)
                    if isRouteEdge {
                        ctx.stroke(path, with: .color(.red), lineWidth: 4)
                    } else if hasRoute {
                        ctx.stroke(path, with: .color(.gray.opacity(0.2)), lineWidth: 1)
                    } else {
                        ctx.stroke(path, with: .color(.gray.opacity(0.5)), lineWidth: 1)
                    }
                }

                // Nodes (corridor only — POI/passage별도 overlay)
                for node in p.nodes {
                    let pt = toDisplay(x: node.x, y: node.y, bounds: bounds, viewScale: viewScale, padding: padding)
                    let rect = CGRect(x: pt.x - 4, y: pt.y - 4, width: 8, height: 8)
                    let isRoute = routeNodeIds.contains(node.id.uuidString)
                    let isStart = node.id == startNodeId

                    // area별 색상 (multi-area) 또는 기본 gray
                    let baseColor: Color = node.areaId.flatMap { p.areaColors[$0] } ?? .gray

                    if isStart {
                        ctx.fill(Path(ellipseIn: rect), with: .color(.yellow))
                        let ring = CGRect(x: pt.x - 7, y: pt.y - 7, width: 14, height: 14)
                        ctx.stroke(Path(ellipseIn: ring), with: .color(.yellow.opacity(0.6)), lineWidth: 2)
                    } else if isRoute {
                        ctx.fill(Path(ellipseIn: rect), with: .color(.red))
                    } else if hasRoute {
                        ctx.fill(Path(ellipseIn: rect), with: .color(baseColor.opacity(0.3)))
                    } else {
                        ctx.fill(Path(ellipseIn: rect), with: .color(baseColor))
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { location in
                if let p = payload {
                    hitTestNode(at: location, in: p, viewScale: viewScale, padding: padding)
                }
            }

            // POI pins (interactive). 외부 wrapper의 scaleEffect/offset이 일괄 적용되므로
            // raw pt(미변환)에 .position 으로 둔다.
            ForEach(p.pois) { poi in
                let pt = toDisplay(x: poi.x, y: poi.y, bounds: bounds, viewScale: viewScale, padding: padding)
                Button {
                    selectedPOI = poi
                    selectedPassage = nil
                    selectedNodeId = nil
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "mappin.circle.fill")
                            .foregroundStyle(.blue)
                            .font(.title3)
                        Text(poi.name)
                            .font(.system(size: 9))
                            .foregroundStyle(.blue)
                            .lineLimit(1)
                    }
                }
                .position(x: pt.x, y: pt.y)
            }

            // Passage symbols (interactive)
            ForEach(p.passages) { passage in
                let pt = toDisplay(x: passage.x, y: passage.y, bounds: bounds, viewScale: viewScale, padding: padding)
                Button {
                    selectedPassage = passage
                    selectedPOI = nil
                    selectedNodeId = nil
                } label: {
                    VStack(spacing: 2) {
                        Text(passageSymbol(passage.connectorType))
                            .font(.title3)
                            .foregroundStyle(.orange)
                        Text(passage.connectorType.prefix(4))
                            .font(.system(size: 8))
                            .foregroundStyle(.orange)
                    }
                }
                .position(x: pt.x, y: pt.y)
            }
        }
    }

    // MARK: - Area Legend

    /// areas.count > 1일 때만 호출. 선택된 area label 단일 chip.
    @ViewBuilder
    private func areaLegendView(_ p: FloorGraphPayload) -> some View {
        let areaId = workspace.effectiveAreaId(floorId: floor.id)
        let label = workspace.areasForFloor(floor.id)
            .first { $0.areaId == areaId }?.label ?? "area"
        HStack(spacing: 6) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func passageSymbol(_ type: String) -> String {
        switch type.uppercased() {
        case "STAIRS", "STAIRCASE": return "◇"
        case "ELEVATOR": return "○"
        case "ESCALATOR": return "▷"
        default: return "◇"
        }
    }

    // MARK: - Data Loading

    private func loadGraph() async {
        guard let client = workspace.v1Client else {
            errorMessage = "서버 URL을 설정해주세요."
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            // 단일 호출로 nodes/edges/bounds/polygon 일괄 수신
            let areaId = workspace.effectiveAreaId(floorId: floor.id)
            let mapResp = try await client.floorMap(floorId: floor.id, areaId: areaId)

            let allNodes: [GraphNode] = mapResp.nodes.compactMap { parseGraphNode(from: $0) }
            let allEdges: [GraphEdge] = mapResp.edges.compactMap { parseGraphEdge(from: $0, nodes: allNodes) }

            // destinations 별 필드 우선. 없으면 node.category=="poi" fallback.
            let filteredPOIs: [GraphPOI]
            if let destinations = mapResp.destinations, !destinations.isEmpty {
                filteredPOIs = destinations.map { d in
                    GraphPOI(
                        id: d.id,
                        routeNodeId: d.routeNodeId,
                        name: d.name ?? d.label ?? "POI",
                        x: d.x, y: d.y,
                        category: d.category ?? "poi"
                    )
                }
            } else {
                filteredPOIs = allNodes.compactMap { node in
                    guard node.category?.lowercased() == "poi" else { return nil }
                    return GraphPOI(
                        id: node.id,
                        routeNodeId: node.id,
                        name: node.label ?? "POI",
                        x: node.x, y: node.y,
                        category: "poi"
                    )
                }
            }

            // connectors 별 필드 우선. 없으면 node.connector fallback.
            let filteredPassages: [GraphPassage]
            if let connectors = mapResp.connectors, !connectors.isEmpty {
                filteredPassages = connectors.map { c in
                    GraphPassage(
                        id: c.connectorId,
                        routeNodeId: c.routeNodeId,
                        connectorType: c.type,
                        connectorKey: c.key,
                        name: c.name,
                        x: c.x, y: c.y
                    )
                }
            } else {
                filteredPassages = allNodes.compactMap { node in
                    guard let conn = node.connector else { return nil }
                    return GraphPassage(
                        id: node.id,
                        routeNodeId: node.id,
                        connectorType: conn.type,
                        connectorKey: conn.key,
                        name: node.label,
                        x: node.x, y: node.y
                    )
                }
            }

            // Bounds
            var bounds = allNodes.isEmpty ? GraphBounds.empty : boundsFromNodes(allNodes, pois: filteredPOIs)
            if let sb = mapResp.bounds {
                bounds = GraphBounds(
                    minX: sb["minX"] ?? bounds.minX,
                    minY: sb["minY"] ?? bounds.minY,
                    maxX: sb["maxX"] ?? bounds.maxX,
                    maxY: sb["maxY"] ?? bounds.maxY
                )
            }

            // Polygon GeoJSON 파싱
            let polygons = parsePolygonFeatures(mapResp.polygon)

            payload = FloorGraphPayload(
                nodes: allNodes,
                edges: allEdges,
                pois: filteredPOIs,
                passages: filteredPassages,
                bounds: bounds,
                polygons: polygons
            )

        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Polygon Parsing

    /// GeoJSON FeatureCollection dict → 각 Polygon feature의 외곽 ring을 CGPoint 배열로 반환.
    /// world meter 좌표. 빈 collection / nil 입력은 [] 반환.
    func parsePolygonFeatures(_ dict: [String: V1AnyValue]?) -> [[CGPoint]] {
        AdminFloorGraphView.parsePolygonFeaturesStatic(dict)
    }

    /// 테스트 가능 static 구현. 인스턴스 없이 직접 호출 가능.
    static func parsePolygonFeaturesStatic(_ dict: [String: V1AnyValue]?) -> [[CGPoint]] {
        guard let features = dict?["features"]?.asArray else { return [] }
        var result: [[CGPoint]] = []
        for feature in features {
            guard let feat = feature.asDict,
                  let geom = feat["geometry"]?.asDict,
                  geom["type"]?.asString == "Polygon",
                  let rings = geom["coordinates"]?.asArray,
                  let outerRing = rings.first?.asArray else { continue }
            let points: [CGPoint] = outerRing.compactMap { coord in
                guard let arr = coord.asArray, arr.count >= 2,
                      let x = arr[0].asDouble, let y = arr[1].asDouble else { return nil }
                return CGPoint(x: x, y: y)
            }
            if points.count >= 3 { result.append(points) }
        }
        return result
    }

    // MARK: - Area Color (unused — single-area 모드로 전환. 하위 호환을 위해 보존.)

    /// Deprecated: single-area 모드 전환 후 미사용. 이전 multi-area 색상 생성용.
    static func colorForAreaIndex(_ index: Int) -> Color {
        let hues: [Color] = [.blue, .green, .purple, .orange, .pink, .cyan, .mint, .indigo]
        return hues[index % hues.count]
    }

    private func parseGraphNode(from dict: [String: V1AnyValue], areaId: UUID? = nil) -> GraphNode? {
        // /map flat format: { id, type, x, y, z, label, connector: {type, key} | null }
        if let x = dict["x"]?.asDouble, let y = dict["y"]?.asDouble {
            let idStr = dict["id"]?.asString ?? dict["node_id"]?.asString ?? UUID().uuidString
            let category = dict["type"]?.asString
            let connector: NodeConnector? = {
                guard let connDict = dict["connector"]?.asDict,
                      let t = connDict["type"]?.asString,
                      let k = connDict["key"]?.asString else { return nil }
                return NodeConnector(type: t, key: k)
            }()
            return GraphNode(
                id: UUID(uuidString: idStr) ?? UUID(),
                x: x, y: y,
                label: dict["label"]?.asString,
                areaId: areaId,
                category: category,
                connector: connector
            )
        }

        // GeoJSON Feature format (하위 호환: /path 응답)
        if let geom = dict["geometry"]?.asDict,
           let coords = geom["coordinates"]?.asArray,
           coords.count >= 2,
           let x = coords[0].asDouble,
           let y = coords[1].asDouble {
            let props = dict["properties"]?.asDict
            let idStr = props?["node_id"]?.asString
                ?? props?["nodeId"]?.asString
                ?? dict["id"]?.asString
                ?? UUID().uuidString
            let label = props?["label"]?.asString ?? dict["label"]?.asString
            let category = props?["node_type"]?.asString ?? props?["type"]?.asString
            return GraphNode(
                id: UUID(uuidString: idStr) ?? UUID(),
                x: x, y: y,
                label: label,
                areaId: areaId,
                category: category,
                connector: nil
            )
        }

        return nil
    }

    private func parseGraphEdge(from dict: [String: V1AnyValue], nodes: [GraphNode]) -> GraphEdge? {
        // /map flat format: { id, fromNodeId, toNodeId, lengthM, type }
        // GeoJSON format (하위 호환): properties.from_node_id / to_node_id
        let props = dict["properties"]?.asDict
        let fromIdStr = dict["fromNodeId"]?.asString
            ?? props?["from_node_id"]?.asString
            ?? props?["fromNodeId"]?.asString
            ?? dict["from_node_id"]?.asString
            ?? dict["from"]?.asString
            ?? ""
        let toIdStr = dict["toNodeId"]?.asString
            ?? props?["to_node_id"]?.asString
            ?? props?["toNodeId"]?.asString
            ?? dict["to_node_id"]?.asString
            ?? dict["to"]?.asString
            ?? ""

        let edgeIdStr = dict["id"]?.asString ?? props?["edge_id"]?.asString
        let edgeUUID = edgeIdStr.flatMap { UUID(uuidString: $0) }
        let fromUUID = UUID(uuidString: fromIdStr)
        let toUUID = UUID(uuidString: toIdStr)

        if let fromUUID, let toUUID,
           let fromNode = nodes.first(where: { $0.id == fromUUID }),
           let toNode = nodes.first(where: { $0.id == toUUID }) {
            return GraphEdge(
                id: edgeUUID ?? UUID(),
                edgeServerId: edgeUUID,
                fromNodeId: fromUUID,
                toNodeId: toUUID,
                lengthM: dict["lengthM"]?.asDouble ?? props?["length_m"]?.asDouble,
                fromX: fromNode.x, fromY: fromNode.y,
                toX: toNode.x, toY: toNode.y
            )
        }

        // GeoJSON LineString coords 직접 파싱 (노드 lookup 실패 fallback)
        if let geom = dict["geometry"]?.asDict,
           let coordsArr = geom["coordinates"]?.asArray,
           coordsArr.count >= 2,
           let firstCoord = coordsArr.first?.asArray,
           let lastCoord = coordsArr.last?.asArray,
           firstCoord.count >= 2, lastCoord.count >= 2,
           let fx = firstCoord[0].asDouble, let fy = firstCoord[1].asDouble,
           let tx = lastCoord[0].asDouble, let ty = lastCoord[1].asDouble {
            return GraphEdge(
                id: edgeUUID ?? UUID(),
                edgeServerId: edgeUUID,
                fromNodeId: fromUUID,
                toNodeId: toUUID,
                lengthM: nil,
                fromX: fx, fromY: fy,
                toX: tx, toY: ty
            )
        }

        return nil
    }

    private func boundsFromNodes(_ nodes: [GraphNode], pois: [GraphPOI]) -> GraphBounds {
        var minX = nodes.map(\.x).min() ?? -10
        var minY = nodes.map(\.y).min() ?? -10
        var maxX = nodes.map(\.x).max() ?? 10
        var maxY = nodes.map(\.y).max() ?? 10
        for poi in pois {
            minX = min(minX, poi.x)
            minY = min(minY, poi.y)
            maxX = max(maxX, poi.x)
            maxY = max(maxY, poi.y)
        }
        let padX = (maxX - minX) * 0.1
        let padY = (maxY - minY) * 0.1
        return GraphBounds(minX: minX - padX, minY: minY - padY, maxX: maxX + padX, maxY: maxY + padY)
    }
}

// MARK: - Info Cards

struct POIInfoCard: View {
    let poi: GraphPOI
    let onClose: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Label(poi.name, systemImage: "mappin.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.blue)
                Text("카테고리: \(poi.category)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(String(format: "x: %.2f, y: %.2f", poi.x, poi.y))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("닫기", action: onClose)
                .font(.caption)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct PassageInfoCard: View {
    let passage: GraphPassage
    let onClose: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Label(passage.name ?? passage.connectorType, systemImage: "arrow.up.and.down")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text("유형: \(passage.connectorType)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("키: \(passage.connectorKey)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("닫기", action: onClose)
                .font(.caption)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

