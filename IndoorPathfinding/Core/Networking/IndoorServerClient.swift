import Foundation
import ZIPFoundation

enum IndoorServerClientError: Error, Equatable {
    case invalidBaseURL
    case httpStatus(Int, String)
    case missingZipEntry(String)
    case fileNotFound(String)
}

struct IndoorServerClient {
    var baseURL: URL
    var token: String
    var session: URLSession = .shared

    func fetchIMDF(scanId: String) async throws -> IMDFMap {
        let url = baseURL.appending(path: "scan").appending(path: scanId).appending(path: "imdf")
        let data = try await data(for: URLRequest.authorized(url: url, token: token))
        let files = try unzip(data: data, required: [
            "manifest.json",
            "unit.geojson",
            "footprint.geojson",
            "amenity.geojson",
            "anchor.geojson"
        ])
        return try IMDFParser().parse(files: files)
    }

    func uploadScanArchive(
        scanId: String,
        archiveURL: URL,
        deviceInfo: String?,
        force: Bool = false
    ) async throws -> ServerScanUploadResponse {
        guard FileManager.default.fileExists(atPath: archiveURL.path) else {
            throw IndoorServerClientError.fileNotFound(archiveURL.path)
        }
        let boundary = "Boundary-\(UUID().uuidString)"
        let multipart = try MultipartFormFile.make(
            scanId: scanId,
            archiveURL: archiveURL,
            deviceInfo: deviceInfo,
            boundary: boundary
        )
        defer { try? FileManager.default.removeItem(at: multipart.url) }

        var url = baseURL.appending(path: "scan").appending(path: "upload")
        if force {
            url = url.appending(queryItems: [URLQueryItem(name: "force", value: "true")])
        }

        var request = URLRequest.authorized(url: url, token: token)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(String(multipart.byteCount), forHTTPHeaderField: "Content-Length")

        let data = try await upload(for: request, fromFile: multipart.url)
        return try JSONDecoder().decode(ServerScanUploadResponse.self, from: data)
    }

    func triggerBuild(scanId: String, force: Bool = false) async throws -> ServerBuildEnqueueResponse {
        var url = baseURL.appending(path: "scan").appending(path: scanId).appending(path: "build")
        if force {
            url = url.appending(queryItems: [URLQueryItem(name: "force", value: "true")])
        }
        var request = URLRequest.authorized(url: url, token: token)
        request.httpMethod = "POST"
        let data = try await data(for: request)
        return try JSONDecoder().decode(ServerBuildEnqueueResponse.self, from: data)
    }

    func fetchBuildStatus(scanId: String) async throws -> ServerBuildStatusResponse {
        let url = baseURL.appending(path: "scan").appending(path: scanId).appending(path: "build")
        let data = try await data(for: URLRequest.authorized(url: url, token: token))
        return try JSONDecoder().decode(ServerBuildStatusResponse.self, from: data)
    }

    func route(
        scanId: String,
        start: SIMD3<Double>,
        poiMarkId: Int,
        scanIds: [String]? = nil,
        mergeOverlaps: Bool = false
    ) async throws -> RouteResponse {
        let url = baseURL.appending(path: "route")
        let payload = RouteRequestPayload(
            scanId: scanId,
            scanIds: scanIds,
            mergeOverlaps: mergeOverlaps,
            start: .init(coordinate: [start.x, start.y, start.z], poiMarkId: nil),
            goal: .init(coordinate: nil, poiMarkId: poiMarkId)
        )
        var request = URLRequest.authorized(url: url, token: token)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)
        let data = try await data(for: request)
        return try JSONDecoder().decode(RouteResponse.self, from: data)
    }

    private func data(for request: URLRequest) async throws -> Data {
        logRequest(request, bodyBytes: request.httpBody?.count)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            logTransportError(request: request, error: error)
            throw error
        }
        logResponse(request: request, response: response, dataBytes: data.count)
        guard let http = response as? HTTPURLResponse else { return data }
        guard (200..<300).contains(http.statusCode) else {
            throw makeHTTPError(status: http.statusCode, data: data)
        }
        return data
    }

    private func upload(for request: URLRequest, fromFile fileURL: URL) async throws -> Data {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileBytes = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        logRequest(request, bodyBytes: fileBytes)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.upload(for: request, fromFile: fileURL)
        } catch {
            logTransportError(request: request, error: error)
            throw error
        }
        logResponse(request: request, response: response, dataBytes: data.count)
        guard let http = response as? HTTPURLResponse else { return data }
        guard (200..<300).contains(http.statusCode) else {
            throw makeHTTPError(status: http.statusCode, data: data)
        }
        return data
    }

    private func logRequest(_ request: URLRequest, bodyBytes: Int?) {
        let method = request.httpMethod ?? "GET"
        let urlText = request.url?.absoluteString ?? "<nil>"
        let bodyText = bodyBytes.map { " bodyBytes=\($0)" } ?? ""
        log("[IndoorServerClient] request method=\(method) url=\(urlText)\(bodyText)")
    }

    private func logResponse(request: URLRequest, response: URLResponse, dataBytes: Int) {
        let method = request.httpMethod ?? "GET"
        let urlText = request.url?.absoluteString ?? "<nil>"
        guard let http = response as? HTTPURLResponse else {
            log("[IndoorServerClient] response method=\(method) nonHTTP url=\(urlText) bytes=\(dataBytes)")
            return
        }
        log("[IndoorServerClient] response method=\(method) status=\(http.statusCode) url=\(urlText) bytes=\(dataBytes)")
    }

    private func logTransportError(request: URLRequest, error: Error) {
        let method = request.httpMethod ?? "GET"
        let urlText = request.url?.absoluteString ?? "<nil>"
        if let urlError = error as? URLError {
            log("[IndoorServerClient] transportError method=\(method) url=\(urlText) code=\(urlError.code.rawValue) description=\(urlError.localizedDescription)")
            return
        }
        log("[IndoorServerClient] transportError method=\(method) url=\(urlText) error=\(error.localizedDescription)")
    }

    private func log(_ message: String) {
        NSLog("%@", message)
    }

    // F3: legacy /route 에러 envelope 파싱
    // 운영 서버 확인: 4xx 응답이 {"detail": {"code": "...", "message": "..."}} 래핑 구조
    // detail.message 추출 성공 시 그 메시지로 throw, 실패 시 raw body fallback
    private func makeHTTPError(status: Int, data: Data) -> IndoorServerClientError {
        let raw = String(data: data, encoding: .utf8) ?? ""
        // {"detail": {"code": "...", "message": "..."}} 래핑 구조 시도
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let detail = json["detail"] as? [String: Any],
           let message = detail["message"] as? String, !message.isEmpty {
            return .httpStatus(status, message)
        }
        // {"code": "...", "message": "..."} 단순 구조 시도 (v1 endpoint 호환)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = json["message"] as? String, !message.isEmpty {
            return .httpStatus(status, message)
        }
        return .httpStatus(status, raw)
    }

    private func unzip(data: Data, required: [String]) throws -> [String: Data] {
        guard let archive = try? Archive(data: data, accessMode: .read, pathEncoding: nil) else {
            throw IndoorServerClientError.missingZipEntry("archive")
        }
        var files: [String: Data] = [:]
        for entry in archive {
            var out = Data()
            _ = try archive.extract(entry) { chunk in
                out.append(chunk)
            }
            files[entry.path] = out
        }
        for name in required where files[name] == nil {
            throw IndoorServerClientError.missingZipEntry(name)
        }
        return files
    }
}

private struct MultipartFormFile {
    let url: URL
    let byteCount: Int64

    static func make(
        scanId: String,
        archiveURL: URL,
        deviceInfo: String?,
        boundary: String
    ) throws -> MultipartFormFile {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("scan-upload-\(UUID().uuidString).multipart")
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }

        try out.writeAll(formField(name: "scan_id", value: scanId, boundary: boundary))
        if let deviceInfo, !deviceInfo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try out.writeAll(formField(name: "device_info", value: deviceInfo, boundary: boundary))
        }
        try out.writeAll(fileHeader(
            name: "payload",
            filename: archiveURL.lastPathComponent,
            boundary: boundary,
            contentType: "application/zip"
        ))
        try copyFile(archiveURL, to: out)
        try out.writeAll("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        let size = (try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
        return MultipartFormFile(url: destination, byteCount: size)
    }

    private static func formField(name: String, value: String, boundary: String) -> Data {
        """
        --\(boundary)
        Content-Disposition: form-data; name="\(name)"

        \(value)
        """.normalizedCRLFData
    }

    private static func fileHeader(
        name: String,
        filename: String,
        boundary: String,
        contentType: String
    ) -> Data {
        """
        --\(boundary)
        Content-Disposition: form-data; name="\(name)"; filename="\(filename)"
        Content-Type: \(contentType)

        """.normalizedCRLFData
    }

    private static func copyFile(_ source: URL, to destination: FileHandle) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        while true {
            let chunk = try input.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            try destination.write(contentsOf: chunk)
        }
    }
}

private extension FileHandle {
    func writeAll(_ data: Data) throws {
        try write(contentsOf: data)
    }
}

private extension String {
    var normalizedCRLFData: Data {
        replacingOccurrences(of: "\n", with: "\r\n").data(using: .utf8)!
    }
}

private extension URLRequest {
    static func authorized(url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
}

struct RouteRequestPayload: Encodable, Equatable {
    let scanId: String
    let scanIds: [String]?
    let mergeOverlaps: Bool
    let start: RouteEndpointPayload
    let goal: RouteEndpointPayload

    enum CodingKeys: String, CodingKey {
        case scanId = "scan_id"
        case scanIds = "scan_ids"
        case mergeOverlaps = "merge_overlaps"
        case start
        case goal
    }

    init(
        scanId: String,
        scanIds: [String]? = nil,
        mergeOverlaps: Bool = false,
        start: RouteEndpointPayload,
        goal: RouteEndpointPayload
    ) {
        self.scanId = scanId
        self.scanIds = scanIds
        self.mergeOverlaps = mergeOverlaps
        self.start = start
        self.goal = goal
    }
}

// M3: XOR 보장 — 사용되는 키만 JSON에 포함, null 키 미직렬화
struct RouteEndpointPayload: Encodable, Equatable {
    let coordinate: [Double]?
    let poiMarkId: Int?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let coord = coordinate {
            try container.encode(coord, forKey: .coordinate)
        }
        if let poi = poiMarkId {
            try container.encode(poi, forKey: .poiMarkId)
        }
        // 미사용 키는 인코딩하지 않음 (XOR 조건 충족)
    }

    enum CodingKeys: String, CodingKey {
        case coordinate
        case poiMarkId = "poi_mark_id"
    }
}

struct ServerScanUploadResponse: Decodable, Equatable {
    let scanId: String
    let state: String
    let counts: ServerScanUploadCounts
    let buildJobId: String?
    let storagePath: String
    let payloadSHA256: String

    enum CodingKeys: String, CodingKey {
        case scanId = "scan_id"
        case state
        case counts
        case buildJobId = "build_job_id"
        case storagePath = "storage_path"
        case payloadSHA256 = "payload_sha256"
    }
}

struct ServerScanUploadCounts: Decodable, Equatable {
    let keyframes: Int
    let poiMarksTrackLock: Int
    let poiMarksManual: Int
    let poiPhotos: Int
    let branchMarks: Int
    let yoloDetections: Int

    enum CodingKeys: String, CodingKey {
        case keyframes
        case poiMarksTrackLock = "poi_marks_track_lock"
        case poiMarksManual = "poi_marks_manual"
        case poiPhotos = "poi_photos"
        case branchMarks = "branch_marks"
        case yoloDetections = "yolo_detections"
    }
}

struct ServerBuildEnqueueResponse: Decodable, Equatable {
    let scanId: String
    let buildJobId: String
    let state: String
    let enqueuedAt: String

    enum CodingKeys: String, CodingKey {
        case scanId = "scan_id"
        case buildJobId = "build_job_id"
        case state
        case enqueuedAt = "enqueued_at"
    }
}

struct ServerBuildStatusResponse: Decodable, Equatable {
    let scanId: String
    let buildJobId: String?
    let state: String
    let currentStep: String?
    let progress: Double?
    let startedAt: String?
    let finishedAt: String?
    let failureReason: String?
    let counts: ServerBuildCounts?

    enum CodingKeys: String, CodingKey {
        case scanId = "scan_id"
        case buildJobId = "build_job_id"
        case state
        case currentStep = "current_step"
        case progress
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case failureReason = "failure_reason"
        case counts
    }
}

struct ServerBuildCounts: Decodable, Equatable {
    let keyframesProcessed: Int
    let walkableCells: Int
    let skeletonPixels: Int
    let mapNodes: Int
    let mapEdges: Int
    let poisProjected: Int
    let walkableCoverage: Double
    let connectedComponents: Int
    let floorZ0: Double?

    enum CodingKeys: String, CodingKey {
        case keyframesProcessed = "keyframes_processed"
        case walkableCells = "walkable_cells"
        case skeletonPixels = "skeleton_pixels"
        case mapNodes = "map_nodes"
        case mapEdges = "map_edges"
        case poisProjected = "pois_projected"
        case walkableCoverage = "walkable_coverage"
        case connectedComponents = "connected_components"
        case floorZ0 = "floor_z0"
    }
}
