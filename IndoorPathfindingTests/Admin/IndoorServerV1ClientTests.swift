import Testing
import Foundation
@testable import IndoorPathfinding

// MARK: - Mock URLProtocol

private final class MockURLProtocol: URLProtocol {

    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
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

// MARK: - Helpers

private func mockSession(
    statusCode: Int = 200,
    json: Any
) -> URLSession {
    MockURLProtocol.handler = { _ in
        let data = try JSONSerialization.data(withJSONObject: json)
        let response = HTTPURLResponse(
            url: URL(string: "http://localhost")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (response, data)
    }
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

private let baseURL = URL(string: "http://127.0.0.1:9999")!

@Suite("IndoorServerV1Client")
struct IndoorServerV1ClientTests {

    // MARK: - listBuildings

    @Test("listBuildings: GET /api/v1/buildings 경로 검증")
    func listBuildingsPath() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.handler = { req in
            capturedRequest = req
            let data = try JSONSerialization.data(withJSONObject: [])
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, data)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let client = IndoorServerV1Client(baseURL: baseURL, token: "test", session: session)

        let _ = try await client.listBuildings()
        #expect(capturedRequest?.url?.path == "/api/v1/buildings")
        #expect(capturedRequest?.httpMethod == "GET")
    }

    // MARK: - createBuilding

    @Test("createBuilding: POST /api/v1/buildings + body JSON 검증")
    func createBuildingBody() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.handler = { req in
            capturedRequest = req
            let building: [String: Any] = [
                "buildingId": UUID().uuidString,
                "name": "테스트",
                "status": "DRAFT"
            ]
            let data = try JSONSerialization.data(withJSONObject: building)
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, data)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = IndoorServerV1Client(baseURL: baseURL, token: "test", session: URLSession(configuration: config))

        let _ = try await client.createBuilding(name: "테스트")
        #expect(capturedRequest?.httpMethod == "POST")
        #expect(capturedRequest?.url?.path == "/api/v1/buildings")

        if let body = capturedRequest?.httpBody,
           let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            #expect(json["name"] as? String == "테스트")
        }
    }

    // MARK: - uploadChunk multipart scan_id form field

    @Test("uploadChunk: scan_id form field 포함 검증")
    func uploadChunkScanId() async throws {
        var capturedBody: Data?
        MockURLProtocol.handler = { req in
            capturedBody = req.httpBody
            // collect body from stream
            if capturedBody == nil, let stream = req.httpBodyStream {
                stream.open()
                var d = Data()
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
                defer { buffer.deallocate() }
                while stream.hasBytesAvailable {
                    let n = stream.read(buffer, maxLength: 4096)
                    if n > 0 { d.append(buffer, count: n) }
                }
                stream.close()
                capturedBody = d
            }
            let chunk: [String: Any] = [
                "chunkId": UUID().uuidString,
                "floorId": UUID().uuidString,
                "scanId": "7B018DCA-50C2-4F1B-BB79-DB3B6F081611",
                "status": "UPLOADED",
                "active": true,
                "uploadOrder": 0
            ]
            let data = try JSONSerialization.data(withJSONObject: chunk)
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, data)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = IndoorServerV1Client(baseURL: baseURL, token: "test", session: URLSession(configuration: config))

        // 임시 zip 파일 생성
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("7B018DCA-50C2-4F1B-BB79-DB3B6F081611.zip")
        try Data([80, 75, 5, 6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let floorId = UUID()
        let scanId = "7B018DCA-50C2-4F1B-BB79-DB3B6F081611"
        let _ = try await client.uploadChunk(floorId: floorId, fileURL: tmp, scanId: scanId)

        if let body = capturedBody, let bodyStr = String(data: body, encoding: .utf8) {
            #expect(bodyStr.contains("scan_id"))
            #expect(bodyStr.contains(scanId))
        }
    }

    // MARK: - processFloor

    @Test("processFloor: POST /api/v1/floors/{id}/process 경로 검증")
    func processFloorPath() async throws {
        let floorId = UUID()
        var capturedURL: URL?
        MockURLProtocol.handler = { req in
            capturedURL = req.url
            let status: [String: Any] = [
                "floorId": floorId.uuidString,
                "status": "PENDING",
                "progress": 0.0
            ]
            let data = try JSONSerialization.data(withJSONObject: status)
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, data)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = IndoorServerV1Client(baseURL: baseURL, token: "test", session: URLSession(configuration: config))

        let _ = try await client.processFloor(floorId: floorId)
        #expect(capturedURL?.path.contains("/floors/") == true)
        #expect(capturedURL?.path.contains("/process") == true)
    }

    // MARK: - V1AnyValue nested dict/array decoding

    @Test("V1AnyValue: nested dict 디코딩")
    func v1AnyValueNestedDict() throws {
        let json = """
        {"type":"Feature","geometry":{"type":"Point","coordinates":[1.5,2.3,0]},"properties":{"node_id":"abc","label":null}}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        let value = try decoder.decode(V1AnyValue.self, from: json)
        guard let dict = value.asDict else {
            Issue.record("최상위가 dict여야 함")
            return
        }
        #expect(dict["type"]?.asString == "Feature")
        let geom = dict["geometry"]?.asDict
        #expect(geom != nil)
        let coords = geom?["coordinates"]?.asArray
        #expect(coords?.count == 3)
        #expect(coords?[0].asDouble == 1.5)
        #expect(coords?[1].asDouble == 2.3)
    }

    @Test("V1AnyValue: array of doubles 디코딩")
    func v1AnyValueArray() throws {
        let json = "[10.0, 20.5, 0.0]".data(using: .utf8)!
        let decoder = JSONDecoder()
        let value = try decoder.decode(V1AnyValue.self, from: json)
        guard let arr = value.asArray else {
            Issue.record("array여야 함")
            return
        }
        #expect(arr.count == 3)
        #expect(arr[0].asDouble == 10.0)
        #expect(arr[1].asDouble == 20.5)
    }

    @Test("V1FloorPath: GeoJSON Feature 노드 디코딩 후 좌표 추출")
    func v1FloorPathGeoJSONNodeCoords() throws {
        let nodeId = "3783edb0-c95f-45d8-8eb3-c8b16a2cf354"
        let floorId = UUID()
        let json = """
        {
          "floorId": "\(floorId.uuidString)",
          "nodes": [
            {
              "type": "Feature",
              "geometry": {"type": "Point", "coordinates": [0.015, 0.049, 0]},
              "properties": {"node_id": "\(nodeId)", "node_type": "corridor", "label": null}
            }
          ],
          "edges": [],
          "bounds": {"minX": 0.0, "minY": 0.0, "maxX": 1.0, "maxY": 1.0}
        }
        """.data(using: .utf8)!
        // M1: convertFromSnakeCase 제거 후 기본 decoder 사용 (v1 응답은 camelCase)
        let decoder = JSONDecoder()
        let path = try decoder.decode(V1FloorPath.self, from: json)
        #expect(path.nodes.count == 1)
        // geometry.coordinates 접근
        let nd = path.nodes[0]
        let geom = nd["geometry"]?.asDict
        #expect(geom != nil)
        let coords = geom?["coordinates"]?.asArray
        #expect(coords?.count == 3)
        #expect(coords?[0].asDouble == 0.015)
        #expect(coords?[1].asDouble == 0.049)
        // M1: 서버가 보내는 원본 키(node_id)를 그대로 참조
        let props = nd["properties"]?.asDict
        #expect(props != nil)
        #expect(props?["node_id"]?.asString == nodeId)
    }

    // MARK: - response decode

    @Test("listFloors: floorId / hasPath 디코딩")
    func listFloorsDecoding() async throws {
        let buildingId = UUID()
        let session = mockSession(json: [
            [
                "floorId": UUID().uuidString,
                "buildingId": buildingId.uuidString,
                "name": "1F",
                "level": 1,
                "hasPath": true,
                "hasPly": false,
                "active": true,
                "uploadOrder": 0
            ]
        ])
        let client = IndoorServerV1Client(baseURL: baseURL, token: "test", session: session)
        let floors = try await client.listFloors(buildingId: buildingId)
        #expect(floors.count == 1)
        #expect(floors[0].hasPath == true)
        #expect(floors[0].level == 1)
    }

    // MARK: - Sprint 85: updateFloor

    @Test("updateFloor: PUT /api/v1/floors/{id} 경로 + body 검증")
    func updateFloorPathAndBody() async throws {
        let floorId = UUID()
        let buildingId = UUID()
        var capturedRequest: URLRequest?
        MockURLProtocol.handler = { req in
            capturedRequest = req
            let floor: [String: Any] = [
                "floorId": floorId.uuidString,
                "buildingId": buildingId.uuidString,
                "name": "2F-renamed",
                "level": 2,
                "hasPath": false,
                "hasPly": false
            ]
            let data = try JSONSerialization.data(withJSONObject: floor)
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, data)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = IndoorServerV1Client(baseURL: baseURL, token: "test", session: URLSession(configuration: config))

        let result = try await client.updateFloor(id: floorId, name: "2F-renamed")
        #expect(capturedRequest?.httpMethod == "PUT")
        #expect(capturedRequest?.url?.path == "/api/v1/floors/\(floorId.uuidString)")
        if let body = capturedRequest?.httpBody,
           let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            #expect(json["name"] as? String == "2F-renamed")
        }
        #expect(result.name == "2F-renamed")
        #expect(result.level == 2)
    }

    // MARK: - Sprint 78 B-5: fetchFloorRoute

    @Test("fetchFloorRoute: decodesResponse — nodes/edges/totalLengthM 파싱")
    func testFetchFloorRoute_decodesResponse() async throws {
        let floorId = UUID()
        let fromId = UUID()
        let toId = UUID()
        let n1 = UUID().uuidString
        let n2 = UUID().uuidString
        let n3 = UUID().uuidString
        let e1 = UUID().uuidString

        let responseJSON: [String: Any] = [
            "floorId": floorId.uuidString,
            "from": fromId.uuidString,
            "to": toId.uuidString,
            "nodes": [n1, n2, n3],
            "edges": [e1],
            "totalLengthM": 5.5,
            "nodeCount": 3
        ]

        var capturedURL: URL?
        MockURLProtocol.handler = { req in
            capturedURL = req.url
            let data = try JSONSerialization.data(withJSONObject: responseJSON)
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, data)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = IndoorServerV1Client(baseURL: baseURL, token: "test", session: URLSession(configuration: config))

        let result = try await client.fetchFloorRoute(floorId: floorId, fromNodeId: fromId, toNodeId: toId)

        // 경로 검증
        #expect(capturedURL?.path.contains("route") == true)
        #expect(capturedURL?.query?.contains("from=") == true)
        #expect(capturedURL?.query?.contains("to=") == true)

        // 응답 파싱 검증
        #expect(result.nodeCount == 3)
        #expect(result.nodes.count == 3)
        #expect(result.edges.count == 1)
        #expect(abs(result.totalLengthM - 5.5) < 0.001)
        #expect(result.nodes[0] == n1)
        #expect(result.nodes[2] == n3)
    }
}
