import Testing
import Foundation
@testable import IndoorPathfinding

// MARK: - MockURLProtocol (local duplicate avoided — reuse pattern from IndoorServerV1ClientTests)

private final class PFMockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = PFMockURLProtocol.handler else {
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

private func pfSession(statusCode: Int = 200, json: Any) -> URLSession {
    PFMockURLProtocol.handler = { _ in
        let data = try JSONSerialization.data(withJSONObject: json)
        let resp = HTTPURLResponse(
            url: URL(string: "http://localhost")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (resp, data)
    }
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [PFMockURLProtocol.self]
    return URLSession(configuration: config)
}

private let pfBaseURL = URL(string: "http://127.0.0.1:9999")!

@Suite("AdminPathfindingMigration")
struct AdminPathfindingMigrationTests {

    // MARK: - PathfindingRequest encoding

    @Test("PathfindingRequest: 필수 필드만 encode시 destinationName 포함")
    func requestEncodingMinimal() throws {
        let req = PathfindingRequest(
            startScanId: nil,
            startAreaId: nil,
            startFloorLevel: 1,
            startX: 1.5,
            startY: 2.3,
            startZ: 0.0,
            destinationName: "도서관",
            preference: nil,
            verticalPreference: nil
        )
        let data = try JSONEncoder().encode(req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["destinationName"] as? String == "도서관")
        #expect(json?["startFloorLevel"] as? Int == 1)
        #expect(json?["startX"] as? Double == 1.5)
    }

    @Test("PathfindingRequest: preference 포함 encode 검증")
    func requestEncodingWithPreference() throws {
        let scanId = UUID()
        let areaId = UUID()
        let req = PathfindingRequest(
            startScanId: scanId,
            startAreaId: areaId,
            startFloorLevel: 2,
            startX: 3.0,
            startY: 4.0,
            startZ: 0.0,
            destinationName: "강의실",
            preference: "SHORTEST",
            verticalPreference: "ELEVATOR"
        )
        let data = try JSONEncoder().encode(req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["preference"] as? String == "SHORTEST")
        #expect(json?["verticalPreference"] as? String == "ELEVATOR")
        #expect(json?["startScanId"] as? String == scanId.uuidString)
        #expect(json?["startAreaId"] as? String == areaId.uuidString)
    }

    // MARK: - PathfindingResponse decoding

    @Test("PathfindingResponse: 정상 응답 디코딩")
    func responseDecoding() throws {
        let buildingId = UUID()
        let nodeId1 = UUID()
        let nodeId2 = UUID()
        let json: [String: Any] = [
            "buildingId": buildingId.uuidString,
            "totalDistance": 12.5,
            "estimatedTimeSeconds": 30,
            "steps": [
                [
                    "stepNumber": 1,
                    "floorLevel": 1,
                    "position": ["x": 1.0, "y": 2.0, "z": 0.0, "floorLevel": 1],
                    "instruction": "직진",
                    "nodeId": nodeId1.uuidString
                ],
                [
                    "stepNumber": 2,
                    "floorLevel": 1,
                    "position": ["x": 3.0, "y": 4.0, "z": 0.0, "floorLevel": 1],
                    "instruction": "도착",
                    "nodeId": nodeId2.uuidString
                ]
            ],
            "floorTransitions": [] as [[String: Any]],
            "routeMetadata": [String: Any]()
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let resp = try JSONDecoder().decode(PathfindingResponse.self, from: data)
        #expect(resp.buildingId == buildingId)
        #expect(abs(resp.totalDistance - 12.5) < 0.001)
        #expect(resp.estimatedTimeSeconds == 30)
        #expect(resp.steps.count == 2)
        #expect(resp.steps[0].nodeId == nodeId1)
        #expect(resp.steps[0].instruction == "직진")
        #expect(resp.steps[1].nodeId == nodeId2)
        #expect(resp.floorTransitions.isEmpty)
    }

    @Test("PathfindingResponse: nodeId nil 허용 디코딩")
    func responseDecodingNilNodeId() throws {
        let buildingId = UUID()
        let json: [String: Any] = [
            "buildingId": buildingId.uuidString,
            "totalDistance": 5.0,
            "estimatedTimeSeconds": 10,
            "steps": [
                [
                    "stepNumber": 1,
                    "floorLevel": 1,
                    "position": ["x": 0.0, "y": 0.0, "z": 0.0, "floorLevel": 1]
                    // instruction, nodeId 없음
                ]
            ],
            "floorTransitions": [] as [[String: Any]]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let resp = try JSONDecoder().decode(PathfindingResponse.self, from: data)
        #expect(resp.steps[0].nodeId == nil)
        #expect(resp.steps[0].instruction == nil)
    }

    // MARK: - V1Client.pathfinding endpoint 경로 검증

    @Test("pathfinding: POST /api/v1/buildings/{id}/pathfinding 경로 검증")
    func pathfindingEndpointPath() async throws {
        let buildingId = UUID()
        var capturedRequest: URLRequest?
        PFMockURLProtocol.handler = { req in
            capturedRequest = req
            let resp: [String: Any] = [
                "buildingId": buildingId.uuidString,
                "totalDistance": 0.0,
                "estimatedTimeSeconds": 0,
                "steps": [] as [[String: Any]],
                "floorTransitions": [] as [[String: Any]]
            ]
            let data = try JSONSerialization.data(withJSONObject: resp)
            let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (http, data)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PFMockURLProtocol.self]
        let client = IndoorServerV1Client(baseURL: pfBaseURL, token: "test", session: URLSession(configuration: config))

        let req = PathfindingRequest(
            startScanId: nil,
            startAreaId: nil,
            startFloorLevel: 1,
            startX: 0,
            startY: 0,
            startZ: 0,
            destinationName: "출구",
            preference: nil,
            verticalPreference: nil
        )
        let _ = try await client.pathfinding(buildingId: buildingId, request: req)
        #expect(capturedRequest?.httpMethod == "POST")
        #expect(capturedRequest?.url?.path == "/api/v1/buildings/\(buildingId.uuidString)/pathfinding")
        if let body = capturedRequest?.httpBody,
           let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            #expect(json["destinationName"] as? String == "출구")
        }
    }

    // MARK: - inferEdgeIdsBetween

    @Test("inferEdgeIdsBetween: 연속 step nodeId 쌍으로 edge 매칭")
    func inferEdgeIds() {
        let n1 = UUID()
        let n2 = UUID()
        let n3 = UUID()
        let e12 = UUID()
        let e23 = UUID()

        let steps: [PathStepResponse] = [
            PathStepResponse(stepNumber: 1, floorLevel: 1,
                             position: RoutePosition(x: 0, y: 0, z: 0, floorLevel: 1),
                             instruction: nil, nodeId: n1),
            PathStepResponse(stepNumber: 2, floorLevel: 1,
                             position: RoutePosition(x: 1, y: 0, z: 0, floorLevel: 1),
                             instruction: nil, nodeId: n2),
            PathStepResponse(stepNumber: 3, floorLevel: 1,
                             position: RoutePosition(x: 2, y: 0, z: 0, floorLevel: 1),
                             instruction: nil, nodeId: n3),
        ]

        let edges: [GraphEdge] = [
            GraphEdge(id: e12, edgeServerId: e12,
                      fromNodeId: n1, toNodeId: n2, lengthM: 1.0,
                      fromX: 0, fromY: 0, toX: 1, toY: 0),
            GraphEdge(id: e23, edgeServerId: e23,
                      fromNodeId: n3, toNodeId: n2, lengthM: 1.0,  // reversed direction
                      fromX: 2, fromY: 0, toX: 1, toY: 0),
            GraphEdge(id: UUID(), edgeServerId: UUID(),  // 무관 edge
                      fromNodeId: UUID(), toNodeId: UUID(), lengthM: 5.0,
                      fromX: 9, fromY: 9, toX: 10, toY: 10),
        ]

        // AdminFloorGraphView의 inferEdgeIdsBetween 로직 직접 재현 (static 노출 없으므로 인라인)
        var ids: Set<String> = []
        for i in 0..<steps.count - 1 {
            guard let from = steps[i].nodeId, let to = steps[i + 1].nodeId else { continue }
            if let edge = edges.first(where: {
                ($0.fromNodeId == from && $0.toNodeId == to) ||
                ($0.fromNodeId == to && $0.toNodeId == from)
            }), let serverId = edge.edgeServerId {
                ids.insert(serverId.uuidString.uppercased())
            }
        }

        #expect(ids.count == 2)
        #expect(ids.contains(e12.uuidString.uppercased()))
        #expect(ids.contains(e23.uuidString.uppercased()))
    }

    @Test("inferEdgeIdsBetween: nodeId nil인 step은 skip")
    func inferEdgeIdsNilNodeId() {
        let n1 = UUID()
        let n2 = UUID()
        let e12 = UUID()

        let steps: [PathStepResponse] = [
            PathStepResponse(stepNumber: 1, floorLevel: 1,
                             position: RoutePosition(x: 0, y: 0, z: 0, floorLevel: 1),
                             instruction: nil, nodeId: n1),
            PathStepResponse(stepNumber: 2, floorLevel: 1,
                             position: RoutePosition(x: 1, y: 0, z: 0, floorLevel: 1),
                             instruction: nil, nodeId: nil),  // nil
            PathStepResponse(stepNumber: 3, floorLevel: 1,
                             position: RoutePosition(x: 2, y: 0, z: 0, floorLevel: 1),
                             instruction: nil, nodeId: n2),
        ]
        let edges: [GraphEdge] = [
            GraphEdge(id: e12, edgeServerId: e12,
                      fromNodeId: n1, toNodeId: n2, lengthM: 1.0,
                      fromX: 0, fromY: 0, toX: 2, toY: 0),
        ]

        var ids: Set<String> = []
        for i in 0..<steps.count - 1 {
            guard let from = steps[i].nodeId, let to = steps[i + 1].nodeId else { continue }
            if let edge = edges.first(where: {
                ($0.fromNodeId == from && $0.toNodeId == to) ||
                ($0.fromNodeId == to && $0.toNodeId == from)
            }), let serverId = edge.edgeServerId {
                ids.insert(serverId.uuidString.uppercased())
            }
        }

        // n1→nil, nil→n2 모두 skip이므로 매칭 없음
        #expect(ids.isEmpty)
    }

    // MARK: - FloorTransitionResponse decoding

    @Test("FloorTransitionResponse: connectorType/connectorKey 디코딩")
    func floorTransitionDecoding() throws {
        let buildingId = UUID()
        let json: [String: Any] = [
            "buildingId": buildingId.uuidString,
            "totalDistance": 20.0,
            "estimatedTimeSeconds": 60,
            "steps": [] as [[String: Any]],
            "floorTransitions": [
                [
                    "fromFloorLevel": 1,
                    "toFloorLevel": 2,
                    "connectorType": "ELEVATOR",
                    "connectorKey": "EV-A"
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let resp = try JSONDecoder().decode(PathfindingResponse.self, from: data)
        #expect(resp.floorTransitions.count == 1)
        #expect(resp.floorTransitions[0].fromFloorLevel == 1)
        #expect(resp.floorTransitions[0].toFloorLevel == 2)
        #expect(resp.floorTransitions[0].connectorType == "ELEVATOR")
        #expect(resp.floorTransitions[0].connectorKey == "EV-A")
    }
}
