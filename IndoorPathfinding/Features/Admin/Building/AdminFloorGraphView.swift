import SwiftUI

// MARK: - Graph Data Models

struct GraphNode: Identifiable {
    let id: UUID
    let x: Double
    let y: Double
    let label: String?
}

struct GraphEdge: Identifiable {
    let id: UUID
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
    @State private var destinationNodeId: UUID?     // 목적지 (POI/passage UUID)
    @State private var destinationLabel: String?    // 목적지 표시 레이블
    @State private var routeResult: FloorRouteResponse?
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
    }

    // MARK: - Route Toolbar

    private func routeToolbarHeight(_ p: FloorGraphPayload) -> CGFloat {
        let destinations = routeDestinations(p)
        if destinations.isEmpty { return 0 }
        // 결과 라인은 result/error 있을 때만. 기본 1줄 + 가변 1줄
        let hasSecondary = routeResult != nil || routeError != nil || isRouteLoading
        return hasSecondary ? 70 : 50
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
                        Text(String(format: "%.1fm · %d노드", r.totalLengthM, r.nodeCount))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
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
        // 라우팅 endpoint는 graph node_id(=routeNodeId)를 기대.
        // poi_id/passage_id를 보내면 NODE_NOT_FOUND 404가 난다.
        var list: [RouteDestination] = []
        for poi in p.pois {
            guard let rid = poi.routeNodeId else { continue }
            list.append(RouteDestination(id: rid, label: poi.name))
        }
        for passage in p.passages {
            guard let rid = passage.routeNodeId else { continue }
            let lbl = passage.name ?? "\(passage.connectorType) \(passage.connectorKey)"
            list.append(RouteDestination(id: rid, label: lbl))
        }
        return list
    }

    private func findRoute(_ p: FloorGraphPayload) async {
        guard let from = startNodeId, let to = destinationNodeId,
              let client = workspace.v1Client else { return }
        isRouteLoading = true
        routeError = nil
        defer { isRouteLoading = false }
        do {
            let result = try await client.fetchFloorRoute(
                floorId: floor.id, fromNodeId: from, toNodeId: to
            )
            routeResult = result
            // 서버는 lowercase UUID, Swift UUID.uuidString 은 uppercase.
            // 비교 안 어긋나게 양쪽 uppercase 로 통일.
            routeNodeIds = Set(result.nodes.map { $0.uppercased() })
            routeEdgeIds = Set(result.edges.map { $0.uppercased() })
        } catch {
            routeError = error.localizedDescription
        }
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
    }

    @ViewBuilder
    private func graphContent(_ p: FloorGraphPayload, size: CGSize, bounds: GraphBounds, viewScale: Double, padding: Double) -> some View {
        ZStack {
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

                    if isStart {
                        // 출발지: 노란 ring
                        ctx.fill(Path(ellipseIn: rect), with: .color(.yellow))
                        let ring = CGRect(x: pt.x - 7, y: pt.y - 7, width: 14, height: 14)
                        ctx.stroke(Path(ellipseIn: ring), with: .color(.yellow.opacity(0.6)), lineWidth: 2)
                    } else if isRoute {
                        ctx.fill(Path(ellipseIn: rect), with: .color(.red))
                    } else if hasRoute {
                        ctx.fill(Path(ellipseIn: rect), with: .color(.gray.opacity(0.3)))
                    } else {
                        ctx.fill(Path(ellipseIn: rect), with: .color(.gray))
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
            // 3-way fan-out
            async let pathTask = client.floorPath(floorId: floor.id)
            async let poisTask = client.listPOIs(buildingId: building.id)
            async let passagesTask = client.listPassages(buildingId: building.id)

            let (pathResp, allPOIs, allPassages) = try await (pathTask, poisTask, passagesTask)

            // GeoJSON Point 파싱 (dead code 블록 제거)
            let parsedNodes: [GraphNode] = pathResp.nodes.compactMap { nd in
                parseGraphNode(from: nd)
            }

            // Edges
            let parsedEdges: [GraphEdge] = pathResp.edges.compactMap { ed in
                parseGraphEdge(from: ed, nodes: parsedNodes)
            }

            // POIs filtered by floor
            let filteredPOIs: [GraphPOI] = allPOIs
                .filter { $0.floorId == floor.id }
                .compactMap { p in
                    guard let dp = p.displayPoint,
                          let x = dp["x"], let y = dp["y"] else { return nil }
                    return GraphPOI(
                        id: p.poiId,
                        routeNodeId: p.routeNodeId,
                        name: p.name ?? p.label ?? "POI",
                        x: x, y: y,
                        category: p.category
                    )
                }

            // Passages filtered by floor involvement (M5: strongly-typed V1PassageSegment 사용)
            let filteredPassages: [GraphPassage] = allPassages.compactMap { p in
                // 서버 schema (vertical_connector_catalog_service.py:70):
                //   level_id = "floor:{UUID}" 형식, floor_id 는 None.
                // → "floor:" prefix 를 떼고 UUID 부분만 비교한다.
                let floorIdStr = floor.id.uuidString.uppercased()
                func levelMatchesFloor(_ levelId: String?) -> Bool {
                    guard let raw = levelId?.uppercased() else { return false }
                    let stripped = raw.hasPrefix("FLOOR:") ? String(raw.dropFirst("FLOOR:".count)) : raw
                    return stripped == floorIdStr
                }
                let matchingSegment: V1PassageSegment? = p.segments.first { seg in
                    seg.floorId?.uppercased() == floorIdStr
                    || levelMatchesFloor(seg.levelId)
                }
                guard let seg = matchingSegment,
                      let sx = seg.x,
                      let sy = seg.y else { return nil }

                // F2: routeNodeId는 String? → UUID? lazy 변환 (변환 실패 시 nil)
                let routeNodeId: UUID? = seg.routeNodeId.flatMap { UUID(uuidString: $0) }

                return GraphPassage(
                    id: p.passageId,
                    routeNodeId: routeNodeId,
                    connectorType: p.connectorType,
                    connectorKey: p.connectorKey,
                    name: p.name,
                    x: sx, y: sy
                )
            }

            // Bounds
            var bounds = parsedNodes.isEmpty ? GraphBounds.empty : boundsFromNodes(parsedNodes, pois: filteredPOIs)
            if let serverBounds = pathResp.bounds {
                bounds = GraphBounds(
                    minX: serverBounds["minX"] ?? bounds.minX,
                    minY: serverBounds["minY"] ?? bounds.minY,
                    maxX: serverBounds["maxX"] ?? bounds.maxX,
                    maxY: serverBounds["maxY"] ?? bounds.maxY
                )
            }

            payload = FloorGraphPayload(
                nodes: parsedNodes,
                edges: parsedEdges,
                pois: filteredPOIs,
                passages: filteredPassages,
                bounds: bounds
            )

        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func parseGraphNode(from dict: [String: V1AnyValue]) -> GraphNode? {
        // GeoJSON Feature format: geometry.coordinates[0,1]
        // M1: convertFromSnakeCase 제거 후 서버가 보내는 원본 키 그대로 사용
        //     서버 GeoJSON properties 키: "node_id", "node_type" (snake_case)
        if let geom = dict["geometry"]?.asDict,
           let coords = geom["coordinates"]?.asArray,
           coords.count >= 2,
           let x = coords[0].asDouble,
           let y = coords[1].asDouble {
            let props = dict["properties"]?.asDict
            let idStr = props?["node_id"]?.asString       // 서버 원본 키
                ?? props?["nodeId"]?.asString             // camelCase 호환 (미래 대비)
                ?? dict["id"]?.asString
                ?? UUID().uuidString
            let label = props?["label"]?.asString ?? dict["label"]?.asString
            return GraphNode(
                id: UUID(uuidString: idStr) ?? UUID(),
                x: x, y: y,
                label: label
            )
        }

        // Flat format (하위 호환)
        if let x = dict["x"]?.asDouble, let y = dict["y"]?.asDouble {
            let idStr = dict["node_id"]?.asString ?? dict["id"]?.asString ?? UUID().uuidString
            return GraphNode(
                id: UUID(uuidString: idStr) ?? UUID(),
                x: x, y: y,
                label: dict["label"]?.asString
            )
        }

        return nil
    }

    private func parseGraphEdge(from dict: [String: V1AnyValue], nodes: [GraphNode]) -> GraphEdge? {
        // GeoJSON Feature format: from_node_id / to_node_id はproperties 안에 있음
        // M1: convertFromSnakeCase 제거 후 서버 원본 snake_case 키 우선
        let props = dict["properties"]?.asDict
        let fromIdStr = props?["from_node_id"]?.asString  // 서버 원본 키
            ?? props?["fromNodeId"]?.asString             // camelCase 호환
            ?? dict["from_node_id"]?.asString
            ?? dict["fromNodeId"]?.asString
            ?? dict["from"]?.asString
            ?? ""
        let toIdStr = props?["to_node_id"]?.asString      // 서버 원본 키
            ?? props?["toNodeId"]?.asString               // camelCase 호환
            ?? dict["to_node_id"]?.asString
            ?? dict["toNodeId"]?.asString
            ?? dict["to"]?.asString
            ?? ""

        if let fromNode = nodes.first(where: { $0.id.uuidString == fromIdStr }),
           let toNode = nodes.first(where: { $0.id.uuidString == toIdStr }) {
            return GraphEdge(
                id: UUID(),
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
                id: UUID(),
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

