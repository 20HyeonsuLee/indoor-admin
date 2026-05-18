import Foundation

// MARK: - V1 DTOs

struct V1Building: Decodable, Identifiable {
    let buildingId: UUID
    let name: String
    let description: String?
    let latitude: Double?
    let longitude: Double?
    let status: String
    let createdAt: String?
    let updatedAt: String?

    var id: UUID { buildingId }
}

struct V1Floor: Decodable, Identifiable {
    let floorId: UUID
    let buildingId: UUID
    let name: String
    let level: Int
    let height: Double?
    let hasPath: Bool
    let hasPly: Bool
    let activeScanId: UUID?
    let createdAt: String?
    let updatedAt: String?

    var id: UUID { floorId }
}

struct V1ScanChunk: Decodable, Identifiable {
    let chunkId: UUID
    let floorId: UUID
    let scanId: UUID
    let fileName: String?
    let fileSize: Int?
    let status: String
    let active: Bool
    let uploadOrder: Int
    let createdAt: String?

    var id: UUID { chunkId }
}

struct V1MergedScan: Decodable {
    let floorId: UUID
    let activeScanId: UUID?
    let status: String
}

struct V1ProcessingStatus: Decodable {
    let floorId: UUID
    let scanId: UUID?
    let buildJobId: UUID?
    let status: String
    let progress: Double?
    let error: String?
}

struct V1FloorPath: Decodable {
    let floorId: UUID
    let scanId: UUID?
    let buildJobId: UUID?
    let nodes: [[String: V1AnyValue]]
    let edges: [[String: V1AnyValue]]
    let bounds: [String: Double]?
}

/// /floors/{id}/map 단일 엔드포인트 응답 (FloorMapResponse)
struct V1FloorMap: Decodable {
    let floorId: UUID
    let buildingId: UUID
    let scanId: UUID?
    let floorLevel: Int
    let floorName: String?
    let buildJobId: UUID?
    let coordinateSystem: [String: V1AnyValue]?
    let bounds: [String: Double]?
    /// GeoJSON FeatureCollection (free-form). nil 또는 features:[] 빈 배열도 안전 처리.
    let polygon: [String: V1AnyValue]?
    /// flat node 배열 (admin parse용)
    let nodes: [[String: V1AnyValue]]
    let edges: [[String: V1AnyValue]]
    /// 별도 분리된 destination(POI) 목록. 서버가 nodes에서 분리해 반환.
    let destinations: [V1MapDestination]?
    /// 별도 분리된 connector(passage) 목록. 서버가 nodes에서 분리해 반환.
    let connectors: [V1MapConnector]?
    let etag: String?
}

struct V1MapDestination: Decodable {
    let id: UUID
    let routeNodeId: UUID?
    let name: String?
    let label: String?
    let category: String?
    let x: Double
    let y: Double
    let z: Double
}

struct V1MapConnector: Decodable {
    let connectorId: UUID
    let type: String
    let key: String
    let name: String?
    let routeNodeId: UUID?
    let x: Double
    let y: Double
    let z: Double
    let stops: [V1MapConnectorStop]?
}

struct V1MapConnectorStop: Decodable {
    let floorId: UUID
    let floorLevel: Int
    let areaId: UUID
    let areaLabel: String?
    let routeNodeId: UUID?
    let x: Double
    let y: Double
    let z: Double
}

// Sprint 78 B-1: floor route response DTO
struct FloorRouteResponse: Decodable {
    let floorId: String
    let from: String
    let to: String
    let nodes: [String]
    let edges: [String]
    let totalLengthM: Double
    let nodeCount: Int
}

// MARK: - Pathfinding DTOs (POST /buildings/{id}/pathfinding)

struct PathfindingRequest: Encodable {
    let startScanId: UUID?
    let startAreaId: UUID?
    let startFloorLevel: Int?
    let startX: Double?
    let startY: Double?
    let startZ: Double?
    let destinationName: String
    let preference: String?
    let verticalPreference: String?
}

struct RoutePosition: Decodable {
    let x: Double
    let y: Double
    let z: Double
    let floorLevel: Int
}

struct PathStepResponse: Decodable {
    let stepNumber: Int
    let floorLevel: Int
    let position: RoutePosition
    let instruction: String?
    let nodeId: UUID?
}

struct FloorTransitionResponse: Decodable {
    let fromFloorLevel: Int
    let toFloorLevel: Int
    let connectorType: String
    let connectorKey: String
}

struct PathfindingResponse: Decodable {
    let buildingId: UUID
    let totalDistance: Double
    let estimatedTimeSeconds: Int
    let steps: [PathStepResponse]
    let floorTransitions: [FloorTransitionResponse]
    let routeMetadata: [String: V1AnyValue]?
}

struct V1POI: Decodable, Identifiable {
    let poiId: UUID
    let buildingId: UUID?
    let floorId: UUID?
    let name: String?
    let label: String?
    let category: String
    let routeNodeId: UUID?
    let displayPoint: [String: Double]?
    let needsReview: Bool
    // M4: OpenAPI POIResponse에 추가된 필드
    let llmConfidence: Double?

    var id: UUID { poiId }
}

// M5: PassageSegment strongly-typed 정의 (서버 schema 기준)
// F2: stopId/levelId/routeNodeId/floorId를 String?으로 변경 (OpenAPI schema: string?, UUID format 미지정)
//     UUID가 필요한 호출부에서 UUID(uuidString:) lazy 변환 사용
struct V1PassageSegment: Decodable {
    let stopId: String?
    let levelId: String?
    let routeNodeId: String?
    let x: Double?
    let y: Double?
    let floorId: String?
    let kind: String?
    // F2: mock은 VerticalPassageResponse(V1Passage) 최상위 필드 → segment에서 제거
}

struct V1Passage: Decodable, Identifiable {
    let passageId: UUID
    let buildingId: UUID?
    let connectorType: String
    let connectorKey: String
    let name: String?
    // F1: mock은 VerticalPassageResponse 최상위 필드 (서버 확인: passages[0].mock=true)
    let mock: Bool?
    // M5: strongly-typed segments (raw [String: V1AnyValue] 대체)
    let segments: [V1PassageSegment]

    var id: UUID { passageId }
}

// V1AnyValue: JSON 값의 타입 소거 (node/edge property를 위한 용도)
enum V1AnyValue: Decodable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case dict([String: V1AnyValue])
    case array([V1AnyValue])
    case null

    init(from decoder: Decoder) throws {
        // dict 우선 시도
        if let keyed = try? decoder.container(keyedBy: AnyCodingKey.self) {
            var result: [String: V1AnyValue] = [:]
            for key in keyed.allKeys {
                result[key.stringValue] = try keyed.decode(V1AnyValue.self, forKey: key)
            }
            self = .dict(result)
            return
        }
        // array 시도
        if var unkeyed = try? decoder.unkeyedContainer() {
            var result: [V1AnyValue] = []
            while !unkeyed.isAtEnd {
                result.append(try unkeyed.decode(V1AnyValue.self))
            }
            self = .array(result)
            return
        }
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        self = .null
    }

    var asString: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    var asDouble: Double? {
        switch self {
        case .double(let v): return v
        case .int(let v): return Double(v)
        default: return nil
        }
    }

    var asInt: Int? {
        switch self {
        case .int(let v): return v
        case .double(let v): return Int(exactly: v)
        default: return nil
        }
    }

    var asBool: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }

    var asDict: [String: V1AnyValue]? {
        if case .dict(let v) = self { return v }
        return nil
    }

    var asArray: [V1AnyValue]? {
        if case .array(let v) = self { return v }
        return nil
    }
}

// JSON 키 디코딩용 helper
private struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?
    init?(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
    init?(intValue: Int) { self.stringValue = "\(intValue)"; self.intValue = intValue }
}

// MARK: - Request Bodies

struct V1CreateBuildingRequest: Encodable {
    let name: String
    let description: String?
    // F4: 서버 schema latitude/longitude 필드
    let latitude: Double?
    let longitude: Double?
}

struct V1UpdateBuildingRequest: Encodable {
    let name: String?
    let description: String?
    // F4: 서버 schema latitude/longitude 필드
    let latitude: Double?
    let longitude: Double?
}

struct V1CreateFloorRequest: Encodable {
    let name: String
    let level: Int
}

struct V1UpdateFloorRequest: Encodable {
    let name: String?
    // height: Sprint 85 범위 밖. 추후 sprint에서 추가.
}

struct V1MergeRequest: Encodable {
    let chunkIds: [UUID]

    enum CodingKeys: String, CodingKey {
        case chunkIds
    }
}

// MARK: - Area DTOs

struct V1FloorArea: Decodable, Identifiable {
    let areaId: UUID
    let floorId: UUID
    let areaIndex: Int
    let label: String
    let isDefault: Bool
    let createdAt: String

    var id: UUID { areaId }
}

// MARK: - Client

// M11: 서버 v1 에러 envelope {"code": "...", "message": "..."}
private struct V1ErrorEnvelope: Decodable {
    let code: String?
    let message: String?
}

enum V1ClientError: Error, LocalizedError {
    case invalidBaseURL
    case httpError(Int, serverCode: String?, serverMessage: String?, raw: String)
    case decodingError(String)
    case noData

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "서버 URL이 올바르지 않습니다."
        case .httpError(let status, let serverCode, let serverMessage, let raw):
            if let msg = serverMessage, !msg.isEmpty {
                return msg
            } else if let code = serverCode {
                return "\(code) (HTTP \(status))"
            } else {
                return "HTTP \(status): \(raw)"
            }
        case .decodingError(let msg):
            return "응답 파싱 실패: \(msg)"
        case .noData:
            return "서버 응답 없음"
        }
    }
}

struct IndoorServerV1Client {
    var baseURL: URL
    var token: String
    var session: URLSession = .shared

    private var v1: URL { baseURL.appendingPathComponent("api/v1") }

    // MARK: - Buildings

    func listBuildings() async throws -> [V1Building] {
        try await get(url: v1.appendingPathComponent("buildings"))
    }

    // F4: latitude/longitude 파라미터 추가
    func createBuilding(name: String, description: String? = nil, latitude: Double? = nil, longitude: Double? = nil) async throws -> V1Building {
        try await post(
            url: v1.appendingPathComponent("buildings"),
            body: V1CreateBuildingRequest(name: name, description: description, latitude: latitude, longitude: longitude)
        )
    }

    // F4: latitude/longitude 파라미터 추가
    func updateBuilding(id: UUID, name: String, description: String? = nil, latitude: Double? = nil, longitude: Double? = nil) async throws -> V1Building {
        try await put(
            url: v1.appendingPathComponent("buildings/\(id.uuidString)"),
            body: V1UpdateBuildingRequest(name: name, description: description, latitude: latitude, longitude: longitude)
        )
    }

    func deleteBuilding(id: UUID) async throws {
        try await delete(url: v1.appendingPathComponent("buildings/\(id.uuidString)"))
    }

    // MARK: - Floors

    func listFloors(buildingId: UUID) async throws -> [V1Floor] {
        try await get(url: v1.appendingPathComponent("buildings/\(buildingId.uuidString)/floors"))
    }

    func createFloor(buildingId: UUID, name: String, level: Int) async throws -> V1Floor {
        try await post(
            url: v1.appendingPathComponent("buildings/\(buildingId.uuidString)/floors"),
            body: V1CreateFloorRequest(name: name, level: level)
        )
    }

    func updateFloor(id: UUID, name: String) async throws -> V1Floor {
        try await put(
            url: v1.appendingPathComponent("floors/\(id.uuidString)"),
            body: V1UpdateFloorRequest(name: name)
        )
    }

    func deleteFloor(id: UUID) async throws {
        try await delete(url: v1.appendingPathComponent("floors/\(id.uuidString)"))
    }

    // MARK: - Scan Chunks

    func listChunks(floorId: UUID, areaId: UUID? = nil) async throws -> [V1ScanChunk] {
        var components = URLComponents(url: v1.appendingPathComponent("floors/\(floorId.uuidString)/scans/chunks"), resolvingAgainstBaseURL: false)!
        if let areaId = areaId {
            components.queryItems = [URLQueryItem(name: "areaId", value: areaId.uuidString)]
        }
        return try await get(url: components.url!)
    }

    func uploadChunk(floorId: UUID, fileURL: URL, scanId: String? = nil, areaId: UUID? = nil) async throws -> V1ScanChunk {
        let boundary = "Boundary-\(UUID().uuidString)"
        let url: URL = {
            var c = URLComponents(url: v1.appendingPathComponent("floors/\(floorId.uuidString)/scans/chunks"), resolvingAgainstBaseURL: false)!
            if let areaId = areaId { c.queryItems = [URLQueryItem(name: "areaId", value: areaId.uuidString)] }
            return c.url!
        }()

        let bodyData = try buildChunkMultipart(fileURL: fileURL, scanId: scanId, boundary: boundary)

        var request = authorizedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(String(bodyData.count), forHTTPHeaderField: "Content-Length")

        let (data, response) = try await upload(for: request, from: bodyData)
        try checkHTTP(data: data, response: response)
        return try decode(V1ScanChunk.self, from: data)
    }

    func deleteChunk(floorId: UUID, chunkId: UUID) async throws {
        try await delete(
            url: v1.appendingPathComponent("floors/\(floorId.uuidString)/scans/chunks/\(chunkId.uuidString)")
        )
    }

    // MARK: - Merge & Process

    func mergeChunks(floorId: UUID, chunkIds: [UUID], areaId: UUID? = nil) async throws -> V1MergedScan {
        var components = URLComponents(url: v1.appendingPathComponent("floors/\(floorId.uuidString)/scans/merge"), resolvingAgainstBaseURL: false)!
        if let areaId = areaId {
            components.queryItems = [URLQueryItem(name: "areaId", value: areaId.uuidString)]
        }
        return try await post(url: components.url!, body: V1MergeRequest(chunkIds: chunkIds))
    }

    func mergeStatus(floorId: UUID, areaId: UUID? = nil) async throws -> V1MergedScan {
        var components = URLComponents(url: v1.appendingPathComponent("floors/\(floorId.uuidString)/scans/merge/status"), resolvingAgainstBaseURL: false)!
        if let areaId = areaId {
            components.queryItems = [URLQueryItem(name: "areaId", value: areaId.uuidString)]
        }
        return try await get(url: components.url!)
    }

    func processFloor(floorId: UUID, areaId: UUID? = nil) async throws -> V1ProcessingStatus {
        var components = URLComponents(url: v1.appendingPathComponent("floors/\(floorId.uuidString)/process"), resolvingAgainstBaseURL: false)!
        if let areaId = areaId {
            components.queryItems = [URLQueryItem(name: "areaId", value: areaId.uuidString)]
        }
        return try await postEmpty(url: components.url!)
    }

    func processStatus(floorId: UUID, areaId: UUID? = nil) async throws -> V1ProcessingStatus {
        var components = URLComponents(url: v1.appendingPathComponent("floors/\(floorId.uuidString)/process/status"), resolvingAgainstBaseURL: false)!
        if let areaId = areaId {
            components.queryItems = [URLQueryItem(name: "areaId", value: areaId.uuidString)]
        }
        return try await get(url: components.url!)
    }

    // MARK: - Graph

    func floorPath(floorId: UUID, areaId: UUID? = nil) async throws -> V1FloorPath {
        var components = URLComponents(url: v1.appendingPathComponent("floors/\(floorId.uuidString)/path"), resolvingAgainstBaseURL: false)!
        if let areaId = areaId {
            components.queryItems = [URLQueryItem(name: "areaId", value: areaId.uuidString)]
        }
        return try await get(url: components.url!)
    }

    func listPOIs(buildingId: UUID) async throws -> [V1POI] {
        try await get(url: v1.appendingPathComponent("buildings/\(buildingId.uuidString)/pois"))
    }

    func listPassages(buildingId: UUID) async throws -> [V1Passage] {
        try await get(url: v1.appendingPathComponent("buildings/\(buildingId.uuidString)/passages"))
    }

    /// /floors/{id}/map 단일 호출. nodes/edges/bounds/polygon을 한 번에 반환.
    func floorMap(floorId: UUID, areaId: UUID? = nil) async throws -> V1FloorMap {
        var c = URLComponents(url: v1.appendingPathComponent("floors/\(floorId.uuidString)/map"), resolvingAgainstBaseURL: false)!
        if let areaId {
            c.queryItems = [URLQueryItem(name: "areaId", value: areaId.uuidString)]
        }
        return try await get(url: c.url!)
    }

    // POST /api/v1/buildings/{id}/pathfinding
    func pathfinding(buildingId: UUID, request: PathfindingRequest) async throws -> PathfindingResponse {
        try await post(
            url: v1.appendingPathComponent("buildings/\(buildingId.uuidString)/pathfinding"),
            body: request
        )
    }

    // Sprint 78 B-1: floor route (deprecated — use pathfinding(buildingId:request:) instead)
    func fetchFloorRoute(floorId: UUID, fromNodeId: UUID, toNodeId: UUID) async throws -> FloorRouteResponse {
        var components = URLComponents(url: v1.appendingPathComponent("floors/\(floorId.uuidString)/route"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "from", value: fromNodeId.uuidString),
            URLQueryItem(name: "to", value: toNodeId.uuidString),
        ]
        guard let url = components?.url else {
            throw V1ClientError.invalidBaseURL
        }
        return try await get(url: url)
    }

    // MARK: - Private HTTP helpers

    private func get<T: Decodable>(url: URL) async throws -> T {
        let (data, response) = try await data(for: authorizedRequest(url: url))
        try checkHTTP(data: data, response: response)
        return try decode(T.self, from: data)
    }

    private func post<Body: Encodable, Response: Decodable>(url: URL, body: Body) async throws -> Response {
        var request = authorizedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await data(for: request)
        try checkHTTP(data: data, response: response)
        return try decode(Response.self, from: data)
    }

    private func postEmpty<Response: Decodable>(url: URL) async throws -> Response {
        var request = authorizedRequest(url: url)
        request.httpMethod = "POST"
        let (data, response) = try await data(for: request)
        try checkHTTP(data: data, response: response)
        return try decode(Response.self, from: data)
    }

    private func put<Body: Encodable, Response: Decodable>(url: URL, body: Body) async throws -> Response {
        var request = authorizedRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await data(for: request)
        try checkHTTP(data: data, response: response)
        return try decode(Response.self, from: data)
    }

    private func delete(url: URL) async throws {
        var request = authorizedRequest(url: url)
        request.httpMethod = "DELETE"
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw makeHTTPError(status: http.statusCode, data: data)
        }
    }

    private func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        logRequest(request, bodyBytes: request.httpBody?.count)
        do {
            let (data, response) = try await session.data(for: request)
            logResponse(request: request, response: response, dataBytes: data.count)
            return (data, response)
        } catch {
            logTransportError(request: request, error: error)
            throw error
        }
    }

    private func upload(for request: URLRequest, from bodyData: Data) async throws -> (Data, URLResponse) {
        logRequest(request, bodyBytes: bodyData.count)
        do {
            let (data, response) = try await session.upload(for: request, from: bodyData)
            logResponse(request: request, response: response, dataBytes: data.count)
            return (data, response)
        } catch {
            logTransportError(request: request, error: error)
            throw error
        }
    }

    private func logRequest(_ request: URLRequest, bodyBytes: Int?) {
        let method = request.httpMethod ?? "GET"
        let urlText = request.url?.absoluteString ?? "<nil>"
        let bodyText = bodyBytes.map { " bodyBytes=\($0)" } ?? ""
        log("[IndoorServerV1Client] request method=\(method) url=\(urlText)\(bodyText)")
    }

    private func logResponse(request: URLRequest, response: URLResponse, dataBytes: Int) {
        let method = request.httpMethod ?? "GET"
        let urlText = request.url?.absoluteString ?? "<nil>"
        guard let http = response as? HTTPURLResponse else {
            log("[IndoorServerV1Client] response method=\(method) nonHTTP url=\(urlText) bytes=\(dataBytes)")
            return
        }
        log("[IndoorServerV1Client] response method=\(method) status=\(http.statusCode) url=\(urlText) bytes=\(dataBytes)")
    }

    private func logTransportError(request: URLRequest, error: Error) {
        let method = request.httpMethod ?? "GET"
        let urlText = request.url?.absoluteString ?? "<nil>"
        if let urlError = error as? URLError {
            log("[IndoorServerV1Client] transportError method=\(method) url=\(urlText) code=\(urlError.code.rawValue) description=\(urlError.localizedDescription)")
            return
        }
        log("[IndoorServerV1Client] transportError method=\(method) url=\(urlText) error=\(error.localizedDescription)")
    }

    private func log(_ message: String) {
        NSLog("%@", message)
    }

    private func checkHTTP(data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw makeHTTPError(status: http.statusCode, data: data)
        }
    }

    // M11: 4xx/5xx 응답에서 V1ErrorEnvelope 파싱 시도, 실패 시 raw body fallback
    private func makeHTTPError(status: Int, data: Data) -> V1ClientError {
        let raw = String(data: data, encoding: .utf8) ?? ""
        if let envelope = try? JSONDecoder().decode(V1ErrorEnvelope.self, from: data) {
            return .httpError(status, serverCode: envelope.code, serverMessage: envelope.message, raw: raw)
        }
        return .httpError(status, serverCode: nil, serverMessage: nil, raw: raw)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        // M1: v1 응답은 이미 camelCase이므로 convertFromSnakeCase 제거 (strategy = .useDefaultKeys)
        // snake_case 필드가 필요한 DTO는 해당 struct에서 CodingKeys로 명시 처리
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw V1ClientError.decodingError(error.localizedDescription)
        }
    }

    private func authorizedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    // MARK: - Background upload helpers (ADR D4)

    /// chunk upload URL. ChunkUploadQueue가 URLSession background task를 구성할 때 사용.
    func chunkUploadURL(floorId: UUID, areaId: UUID? = nil) -> URL {
        var components = URLComponents(url: v1.appendingPathComponent("floors/\(floorId.uuidString)/scans/chunks"), resolvingAgainstBaseURL: false)!
        if let areaId = areaId {
            components.queryItems = [URLQueryItem(name: "areaId", value: areaId.uuidString)]
        }
        return components.url!
    }

    /// background URLSession upload task용 authorized request.
    /// httpBody는 URLSession.uploadTask(with:fromFile:)이 처리하므로 포함하지 않는다.
    func authorizedChunkRequest(url: URL, boundary: String) -> URLRequest {
        var request = authorizedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        return request
    }

    // MARK: - Areas

    func listAreas(floorId: UUID) async throws -> [V1FloorArea] {
        try await get(url: v1.appendingPathComponent("floors/\(floorId.uuidString)/areas"))
    }

    func createArea(floorId: UUID, label: String) async throws -> V1FloorArea {
        struct V1CreateAreaRequest: Encodable {
            let label: String
        }
        return try await post(
            url: v1.appendingPathComponent("floors/\(floorId.uuidString)/areas"),
            body: V1CreateAreaRequest(label: label)
        )
    }

    private func buildChunkMultipart(fileURL: URL, scanId: String?, boundary: String) throws -> Data {
        var body = Data()

        if let scanId {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"scan_id\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(scanId)\r\n".data(using: .utf8)!)
        }

        let filename = fileURL.lastPathComponent
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/zip\r\n\r\n".data(using: .utf8)!)
        body.append(try Data(contentsOf: fileURL))
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        return body
    }
}
