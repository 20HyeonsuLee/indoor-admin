import Foundation
import OSLog

// MARK: - Request / Response DTOs

struct ScanStartRequest: Encodable {
    let scanId: String?
    let deviceInfo: String?
}

struct ScanStartResponse: Decodable {
    let scanId: String
    let floorId: String
    let storagePath: String
    let state: String
}

struct FramePayload: Encodable {
    let nodeId: Int
    let stamp: Double
    let pose: String          // base64 of 48B 3x4 float32 row-major
    let image: String         // base64 of JPEG
    let calibration: String   // base64 of 164B blob
    let mapId: Int?
    let weight: Int?
    let depth: String?
    let scan: String?
    let scanInfo: String?
    let label: String?
    let userData: String?
}

struct FrameLinkPayload: Encodable {
    let fromId: Int
    let toId: Int
    let transform: String     // base64 of 48B
    let type: Int?
    let informationMatrix: String?
    let userData: String?
}

struct ScanFramesRequest: Encodable {
    let frames: [FramePayload]
    let links: [FrameLinkPayload]
}

struct ScanFramesResponse: Decodable {
    let scanId: String
    let framesApplied: Int
    let framesSkipped: Int
    let linksApplied: Int
    let linksSkipped: Int
    let lastNodeId: Int
    let nodeCount: Int
}

struct ScanFinalizeResponse: Decodable {
    let scanId: String
    let floorId: String
    let state: String
    let nodeCount: Int
    let keyframeCount: Int
    let poiMarkCount: Int
    let payloadSha256: String
}

// MARK: - Client

/// streaming scan push API 4개 호출 담당.
/// 단순 HTTP wrapper — 재시도/오케스트레이션은 StreamingPushService가 담당한다.
struct StreamingScanClient {

    var baseURL: URL
    var token: String
    var session: URLSession = .shared

    private static let logger = Logger(
        subsystem: "ac.koreatech.indoorpathfinding",
        category: "streaming"
    )

    private var apiV1: URL { baseURL.appendingPathComponent("api/v1") }

    // MARK: - 1. Start

    func startScan(floorId: UUID, scanId: UUID? = nil, deviceInfo: String? = nil) async throws -> ScanStartResponse {
        let url = apiV1
            .appendingPathComponent("floors")
            .appendingPathComponent(floorId.uuidString)
            .appendingPathComponent("scans")
            .appendingPathComponent("start")

        let body = ScanStartRequest(
            scanId: scanId?.uuidString,
            deviceInfo: deviceInfo
        )
        return try await post(url: url, body: body, expectedStatus: 201)
    }

    // MARK: - 2. Push frames

    func pushFrames(scanId: String, request: ScanFramesRequest) async throws -> ScanFramesResponse {
        let url = apiV1
            .appendingPathComponent("scans")
            .appendingPathComponent(scanId)
            .appendingPathComponent("frames")

        return try await post(url: url, body: request, expectedStatus: 200)
    }

    // MARK: - 3. Finalize (multipart — manifest + metadata 둘 다 필수)

    func finalizeScan(
        scanId: String,
        manifestFileURL: URL,
        metadataFileURL: URL
    ) async throws -> ScanFinalizeResponse {
        let url = apiV1
            .appendingPathComponent("scans")
            .appendingPathComponent(scanId)
            .appendingPathComponent("finalize")

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = authorizedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )

        let manifestData = try Data(contentsOf: manifestFileURL)
        let metadataData = try Data(contentsOf: metadataFileURL)
        var body = Data()
        let crlf = "\r\n"

        // manifest (JSON)
        body.append("--\(boundary)\(crlf)".utf8Data)
        body.append("Content-Disposition: form-data; name=\"manifest\"; filename=\"manifest.json\"\(crlf)".utf8Data)
        body.append("Content-Type: application/json\(crlf)\(crlf)".utf8Data)
        body.append(manifestData)
        body.append(crlf.utf8Data)

        // metadata (sqlite)
        body.append("--\(boundary)\(crlf)".utf8Data)
        body.append("Content-Disposition: form-data; name=\"metadata\"; filename=\"scan_metadata.db\"\(crlf)".utf8Data)
        body.append("Content-Type: application/octet-stream\(crlf)\(crlf)".utf8Data)
        body.append(metadataData)
        body.append(crlf.utf8Data)

        body.append("--\(boundary)--\(crlf)".utf8Data)

        request.httpBody = body

        let (data, response) = try await data(for: request)
        try checkHTTP(data: data, response: response, expected: 200)
        return try decodeJSON(ScanFinalizeResponse.self, from: data)
    }

    // MARK: - 4. Build

    func triggerBuild(floorId: UUID) async throws {
        let url = apiV1
            .appendingPathComponent("floors")
            .appendingPathComponent(floorId.uuidString)
            .appendingPathComponent("build")

        var request = authorizedRequest(url: url)
        request.httpMethod = "POST"
        let (data, response) = try await data(for: request)
        try checkHTTP(data: data, response: response, expected: 200)
        Self.logger.info("triggerBuild: floorId=\(floorId.uuidString) -> 200 OK")
        _ = data
    }

    // MARK: - Private HTTP helpers

    private func post<Body: Encodable, Response: Decodable>(
        url: URL,
        body: Body,
        expectedStatus: Int
    ) async throws -> Response {
        var request = authorizedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await data(for: request)
        try checkHTTP(data: data, response: response, expected: expectedStatus)
        return try decodeJSON(Response.self, from: data)
    }

    private func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        logRequest(request)
        do {
            let (data, response) = try await session.data(for: request)
            logResponse(request: request, response: response, dataBytes: data.count)
            return (data, response)
        } catch {
            logTransportError(request: request, error: error)
            throw error
        }
    }

    private func logRequest(_ request: URLRequest) {
        let method = request.httpMethod ?? "GET"
        let urlText = request.url?.absoluteString ?? "<nil>"
        let bodyBytes = request.httpBody?.count ?? 0
        log("[StreamingScanClient] request method=\(method) url=\(urlText) bodyBytes=\(bodyBytes)")
    }

    private func logResponse(request: URLRequest, response: URLResponse, dataBytes: Int) {
        let method = request.httpMethod ?? "GET"
        let urlText = request.url?.absoluteString ?? "<nil>"
        guard let http = response as? HTTPURLResponse else {
            log("[StreamingScanClient] response method=\(method) nonHTTP url=\(urlText) bytes=\(dataBytes)")
            return
        }
        log("[StreamingScanClient] response method=\(method) status=\(http.statusCode) url=\(urlText) bytes=\(dataBytes)")
    }

    private func logTransportError(request: URLRequest, error: Error) {
        let method = request.httpMethod ?? "GET"
        let urlText = request.url?.absoluteString ?? "<nil>"
        if let urlError = error as? URLError {
            log("[StreamingScanClient] transportError method=\(method) url=\(urlText) code=\(urlError.code.rawValue) description=\(urlError.localizedDescription)")
            return
        }
        log("[StreamingScanClient] transportError method=\(method) url=\(urlText) error=\(error.localizedDescription)")
    }

    private func log(_ message: String) {
        NSLog("%@", message)
    }

    private func checkHTTP(data: Data, response: URLResponse, expected: Int) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard http.statusCode == expected else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw StreamingClientError.httpError(http.statusCode, raw)
        }
    }

    private func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw StreamingClientError.decodingError(error.localizedDescription)
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
}

// MARK: - Error

enum StreamingClientError: LocalizedError {
    case httpError(Int, String)
    case decodingError(String)

    var errorDescription: String? {
        switch self {
        case .httpError(let status, let raw):
            return "HTTP \(status): \(raw)"
        case .decodingError(let msg):
            return "응답 파싱 실패: \(msg)"
        }
    }
}

// MARK: - Data helpers

private extension String {
    var utf8Data: Data { Data(utf8) }
}
