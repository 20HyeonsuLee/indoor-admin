import Testing
import Foundation
@testable import IndoorPathfinding

@Suite("IndoorServerClient")
struct IndoorServerClientTests {

    @Test("uploadScanArchive sends authenticated multipart request and decodes response")
    func uploadScanArchiveContract() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let archiveURL = tmp.appendingPathComponent("scan.zip")
        try Data([1, 2, 3, 4]).write(to: archiveURL)

        let recorder = RequestRecorder()
        let client = IndoorServerClient(
            baseURL: URL(string: "http://127.0.0.1:8000")!,
            token: "dev-token",
            session: recorder.session(response: [
                "scan_id": "56a8698c-5497-4390-aed3-0e302b3ad7c8",
                "state": "ingested",
                "counts": [
                    "keyframes": 26,
                    "poi_marks_track_lock": 3,
                    "poi_marks_manual": 2,
                    "poi_photos": 5,
                    "branch_marks": 0,
                    "yolo_detections": 0
                ],
                "build_job_id": "job-1",
                "storage_path": "server/var/storage/scan.zip",
                "payload_sha256": "abc"
            ])
        )

        let response = try await client.uploadScanArchive(
            scanId: "56a8698c-5497-4390-aed3-0e302b3ad7c8",
            archiveURL: archiveURL,
            deviceInfo: "{\"floor\":\"1F\"}",
            force: true
        )

        #expect(response.buildJobId == "job-1")
        #expect(response.counts.keyframes == 26)
        #expect(recorder.lastRequest?.httpMethod == "POST")
        #expect(recorder.lastRequest?.url?.path == "/scan/upload")
        #expect(recorder.lastRequest?.url?.query?.contains("force=true") == true)
        #expect(recorder.lastRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer dev-token")
        #expect(recorder.lastRequest?.value(forHTTPHeaderField: "Content-Type")?.contains("multipart/form-data") == true)
    }

    @Test("fetchBuildStatus decodes server build state")
    func fetchBuildStatusContract() async throws {
        let recorder = RequestRecorder()
        let client = IndoorServerClient(
            baseURL: URL(string: "http://127.0.0.1:8000")!,
            token: "dev-token",
            session: recorder.session(response: [
                "scan_id": "56a8698c-5497-4390-aed3-0e302b3ad7c8",
                "build_job_id": "job-1",
                "state": "succeeded",
                "current_step": "done",
                "progress": 1.0,
                "counts": [
                    "keyframes_processed": 26,
                    "walkable_cells": 7776,
                    "skeleton_pixels": 100,
                    "map_nodes": 48,
                    "map_edges": 120,
                    "pois_projected": 5,
                    "walkable_coverage": 0.8,
                    "connected_components": 1,
                    "floor_z0": 0.0
                ]
            ])
        )

        let status = try await client.fetchBuildStatus(scanId: "56a8698c-5497-4390-aed3-0e302b3ad7c8")

        #expect(status.state == "succeeded")
        #expect(status.counts?.mapNodes == 48)
        #expect(recorder.lastRequest?.httpMethod == "GET")
        #expect(recorder.lastRequest?.url?.path == "/scan/56a8698c-5497-4390-aed3-0e302b3ad7c8/build")
    }

    @Test("route sends multi-scan options and decodes route metadata")
    func routeMultiScanContract() async throws {
        let recorder = RequestRecorder()
        let client = IndoorServerClient(
            baseURL: URL(string: "http://127.0.0.1:8000")!,
            token: "dev-token",
            session: recorder.session(response: [
                "scan_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
                "scan_ids": [
                    "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
                    "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
                ],
                "build_job_id": "11111111-1111-1111-1111-111111111111",
                "build_job_ids": [
                    "11111111-1111-1111-1111-111111111111",
                    "22222222-2222-2222-2222-222222222222"
                ],
                "path_nodes": [],
                "path_geometry": [
                    "type": "LineString",
                    "coordinates": [[0.0, 0.0, 0.0], [1.0, 1.0, 0.0]]
                ],
                "length_m": 1.4,
                "node_count": 2,
                "snap_info": [
                    "start_snap_distance_m": 0.0,
                    "goal_snap_distance_m": 0.0
                ],
                "route_metadata": ["merge_overlaps": true]
            ])
        )

        let route = try await client.route(
            scanId: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            start: SIMD3<Double>(0.0, 0.0, 0.0),
            poiMarkId: 7,
            scanIds: [
                "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
                "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
            ],
            mergeOverlaps: true
        )
        let body = try #require(recorder.lastRequest.flatMap(requestBodyData(_:)))
        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]

        #expect(recorder.lastRequest?.httpMethod == "POST")
        #expect(recorder.lastRequest?.url?.path == "/route")
        #expect(object?["merge_overlaps"] as? Bool == true)
        #expect(object?["scan_ids"] as? [String] == [
            "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        ])
        #expect(route.scanIds?.count == 2)
        #expect(route.buildJobIds?.count == 2)
        // M2: 새 필드 디코딩 검증
        #expect(route.pathNodes.count == 0)
        #expect(route.snapInfo.startSnapDistanceM == 0.0)
    }

    // M3: RouteEndpointPayload XOR 인코딩 검증
    @Test("RouteEndpointPayload: coordinate-only 인코딩 시 poi_mark_id 키 없음")
    func routeEndpointCoordinateXOR() throws {
        let payload = RouteEndpointPayload(coordinate: [1.0, 2.0, 3.0], poiMarkId: nil)
        let data = try JSONEncoder().encode(payload)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["coordinate"] as? [Double] == [1.0, 2.0, 3.0])
        #expect(json?["poi_mark_id"] == nil, "미사용 키가 JSON에 포함되면 서버 XOR 제약 위반")
    }

    @Test("RouteEndpointPayload: poi_mark_id-only 인코딩 시 coordinate 키 없음")
    func routeEndpointPoiMarkIdXOR() throws {
        let payload = RouteEndpointPayload(coordinate: nil, poiMarkId: 42)
        let data = try JSONEncoder().encode(payload)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["poi_mark_id"] as? Int == 42)
        #expect(json?["coordinate"] == nil, "미사용 키가 JSON에 포함되면 서버 XOR 제약 위반")
    }
}

private func requestBodyData(_ request: URLRequest) -> Data? {
    if let body = request.httpBody {
        return body
    }
    guard let stream = request.httpBodyStream else {
        return nil
    }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let bufferSize = 4096
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }
    while stream.hasBytesAvailable {
        let read = stream.read(buffer, maxLength: bufferSize)
        if read <= 0 {
            break
        }
        data.append(buffer, count: read)
    }
    return data.isEmpty ? nil : data
}

private final class RequestRecorder {
    var lastRequest: URLRequest?

    func session(response object: [String: Any], statusCode: Int = 200) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        StubURLProtocol.handler = { [weak self] request in
            self?.lastRequest = request
            let data = try JSONSerialization.data(withJSONObject: object)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }
        return URLSession(configuration: configuration)
    }
}

private final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else {
                throw URLError(.badServerResponse)
            }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
