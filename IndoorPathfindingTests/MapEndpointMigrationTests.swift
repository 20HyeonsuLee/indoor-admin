import Testing
import Foundation
@testable import IndoorPathfinding

@Suite("MapEndpointMigration")
struct MapEndpointMigrationTests {

    // MARK: - V1FloorMap Decoding

    @Test("V1FloorMap decodes all required fields")
    func floorMapDecoding() throws {
        let json = """
        {
          "floorId": "11111111-1111-1111-1111-111111111111",
          "buildingId": "22222222-2222-2222-2222-222222222222",
          "scanId": null,
          "floorLevel": 1,
          "floorName": "1층",
          "buildJobId": null,
          "coordinateSystem": null,
          "bounds": {"minX": 0.0, "minY": 0.0, "maxX": 10.0, "maxY": 10.0},
          "polygon": {"type": "FeatureCollection", "features": []},
          "nodes": [],
          "edges": [],
          "etag": "abc123"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(V1FloorMap.self, from: json)
        #expect(decoded.floorId == UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
        #expect(decoded.buildingId == UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)
        #expect(decoded.floorLevel == 1)
        #expect(decoded.floorName == "1층")
        #expect(decoded.etag == "abc123")
        #expect(decoded.nodes.isEmpty)
        #expect(decoded.edges.isEmpty)
    }

    @Test("V1FloorMap decodes with null polygon safely")
    func floorMapNullPolygon() throws {
        let json = """
        {
          "floorId": "11111111-1111-1111-1111-111111111111",
          "buildingId": "22222222-2222-2222-2222-222222222222",
          "floorLevel": 0,
          "nodes": [],
          "edges": []
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(V1FloorMap.self, from: json)
        #expect(decoded.polygon == nil)
    }

    @Test("V1FloorMap decodes node with connector field")
    func floorMapNodeConnector() throws {
        let json = """
        {
          "floorId": "11111111-1111-1111-1111-111111111111",
          "buildingId": "22222222-2222-2222-2222-222222222222",
          "floorLevel": 1,
          "nodes": [
            {
              "id": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
              "type": "connector",
              "x": 3.0,
              "y": 4.0,
              "label": "Elevator A",
              "connector": {"type": "ELEVATOR", "key": "ELV-01"}
            }
          ],
          "edges": []
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(V1FloorMap.self, from: json)
        #expect(decoded.nodes.count == 1)
        let node = decoded.nodes[0]
        #expect(node["type"]?.asString == "connector")
        let connDict = node["connector"]?.asDict
        #expect(connDict?["type"]?.asString == "ELEVATOR")
        #expect(connDict?["key"]?.asString == "ELV-01")
    }

    // MARK: - parsePolygonFeaturesStatic

    @Test("parsePolygonFeatures returns empty for nil input")
    func polygonNilInput() {
        let result = AdminFloorGraphView.parsePolygonFeaturesStatic(nil)
        #expect(result.isEmpty)
    }

    @Test("parsePolygonFeatures returns empty for empty features array")
    func polygonEmptyFeatures() {
        let dict: [String: V1AnyValue] = [
            "type": .string("FeatureCollection"),
            "features": .array([])
        ]
        let result = AdminFloorGraphView.parsePolygonFeaturesStatic(dict)
        #expect(result.isEmpty)
    }

    @Test("parsePolygonFeatures parses single polygon feature correctly")
    func polygonSingleFeature() {
        let ring: V1AnyValue = .array([
            .array([.double(0), .double(0)]),
            .array([.double(10), .double(0)]),
            .array([.double(10), .double(10)]),
            .array([.double(0), .double(10)]),
            .array([.double(0), .double(0)])
        ])
        let geometry: V1AnyValue = .dict([
            "type": .string("Polygon"),
            "coordinates": .array([ring])
        ])
        let feature: V1AnyValue = .dict([
            "type": .string("Feature"),
            "geometry": geometry,
            "properties": .dict([:])
        ])
        let dict: [String: V1AnyValue] = [
            "type": .string("FeatureCollection"),
            "features": .array([feature])
        ]

        let result = AdminFloorGraphView.parsePolygonFeaturesStatic(dict)
        #expect(result.count == 1)
        #expect(result[0].count == 5)
        #expect(abs(Double(result[0][0].x) - 0.0) < 0.001)
        #expect(abs(Double(result[0][2].x) - 10.0) < 0.001)
        #expect(abs(Double(result[0][2].y) - 10.0) < 0.001)
    }

    @Test("parsePolygonFeatures ignores non-Polygon geometry types")
    func polygonIgnoresNonPolygon() {
        let feature: V1AnyValue = .dict([
            "type": .string("Feature"),
            "geometry": .dict([
                "type": .string("LineString"),
                "coordinates": .array([
                    .array([.double(0), .double(0)]),
                    .array([.double(1), .double(1)])
                ])
            ]),
            "properties": .dict([:])
        ])
        let dict: [String: V1AnyValue] = [
            "type": .string("FeatureCollection"),
            "features": .array([feature])
        ]
        let result = AdminFloorGraphView.parsePolygonFeaturesStatic(dict)
        #expect(result.isEmpty)
    }

    @Test("parsePolygonFeatures skips ring with fewer than 3 points")
    func polygonTooFewPoints() {
        let ring: V1AnyValue = .array([
            .array([.double(0), .double(0)]),
            .array([.double(1), .double(1)])
        ])
        let feature: V1AnyValue = .dict([
            "type": .string("Feature"),
            "geometry": .dict([
                "type": .string("Polygon"),
                "coordinates": .array([ring])
            ]),
            "properties": .dict([:])
        ])
        let dict: [String: V1AnyValue] = [
            "type": .string("FeatureCollection"),
            "features": .array([feature])
        ]
        let result = AdminFloorGraphView.parsePolygonFeaturesStatic(dict)
        #expect(result.isEmpty)
    }

    // MARK: - destinations/connectors 별 필드 디코딩

    @Test("V1FloorMap decodes destinations and connectors fields")
    func floorMapDestinationsConnectors() throws {
        let json = """
        {
          "floorId": "11111111-1111-1111-1111-111111111111",
          "buildingId": "22222222-2222-2222-2222-222222222222",
          "floorLevel": 1,
          "nodes": [],
          "edges": [],
          "destinations": [
            {
              "id": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
              "routeNodeId": "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
              "name": "편의점",
              "label": "CVS",
              "category": "store",
              "x": 1.0,
              "y": 2.0,
              "z": 0.0
            }
          ],
          "connectors": [
            {
              "connectorId": "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC",
              "type": "elevator",
              "key": "EV-A",
              "name": "EV-A",
              "routeNodeId": "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD",
              "x": 3.0,
              "y": 4.0,
              "z": 0.0,
              "stops": [
                {
                  "floorId": "11111111-1111-1111-1111-111111111111",
                  "floorLevel": 1,
                  "areaId": "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE",
                  "areaLabel": "Area 1",
                  "routeNodeId": "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD",
                  "x": 3.0,
                  "y": 4.0,
                  "z": 0.0
                }
              ]
            }
          ]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(V1FloorMap.self, from: json)

        let dest = try #require(decoded.destinations?.first)
        #expect(dest.id == UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)
        #expect(dest.routeNodeId == UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!)
        #expect(dest.name == "편의점")
        #expect(dest.category == "store")
        #expect(dest.x == 1.0)
        #expect(dest.y == 2.0)

        let conn = try #require(decoded.connectors?.first)
        #expect(conn.connectorId == UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!)
        #expect(conn.type == "elevator")
        #expect(conn.key == "EV-A")
        #expect(conn.routeNodeId == UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!)
        #expect(conn.x == 3.0)
        #expect(conn.stops?.count == 1)

        let stop = try #require(conn.stops?.first)
        #expect(stop.floorLevel == 1)
        #expect(stop.areaLabel == "Area 1")
    }

    @Test("V1FloorMap destinations nil when field absent")
    func floorMapDestinationsNilWhenAbsent() throws {
        let json = """
        {
          "floorId": "11111111-1111-1111-1111-111111111111",
          "buildingId": "22222222-2222-2222-2222-222222222222",
          "floorLevel": 1,
          "nodes": [],
          "edges": []
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(V1FloorMap.self, from: json)
        #expect(decoded.destinations == nil)
        #expect(decoded.connectors == nil)
    }

    @Test("destinations map to GraphPOI with name priority over label")
    func destinationToGraphPOI() {
        let dest = V1MapDestination(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            routeNodeId: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            name: "카페", label: "CAFE", category: "food",
            x: 5.0, y: 6.0, z: 0.0
        )
        let poi = GraphPOI(
            id: dest.id,
            routeNodeId: dest.routeNodeId,
            name: dest.name ?? dest.label ?? "POI",
            x: dest.x, y: dest.y,
            category: dest.category ?? "poi"
        )
        #expect(poi.name == "카페")
        #expect(poi.routeNodeId == UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!)
        #expect(poi.category == "food")
        #expect(poi.x == 5.0)
    }

    @Test("destination uses label when name is nil")
    func destinationUsesLabel() {
        let dest = V1MapDestination(
            id: UUID(), routeNodeId: nil,
            name: nil, label: "화장실", category: nil,
            x: 1.0, y: 1.0, z: 0.0
        )
        let name = dest.name ?? dest.label ?? "POI"
        #expect(name == "화장실")
    }

    @Test("connectors map to GraphPassage")
    func connectorToGraphPassage() {
        let conn = V1MapConnector(
            connectorId: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
            type: "elevator",
            key: "EV-A",
            name: "EV-A",
            routeNodeId: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!,
            x: 3.0, y: 4.0, z: 0.0,
            stops: nil
        )
        let passage = GraphPassage(
            id: conn.connectorId,
            routeNodeId: conn.routeNodeId,
            connectorType: conn.type,
            connectorKey: conn.key,
            name: conn.name,
            x: conn.x, y: conn.y
        )
        #expect(passage.id == UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!)
        #expect(passage.routeNodeId == UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!)
        #expect(passage.connectorType == "elevator")
        #expect(passage.connectorKey == "EV-A")
        #expect(passage.name == "EV-A")
        #expect(passage.x == 3.0)
    }

    // MARK: - node.connector derive (unit)

    @Test("NodeConnector is extracted from connector dict")
    func nodeConnectorExtraction() {
        let connDict: [String: V1AnyValue] = [
            "type": .string("ELEVATOR"),
            "key": .string("ELV-01")
        ]
        let connector: NodeConnector? = {
            guard let t = connDict["type"]?.asString,
                  let k = connDict["key"]?.asString else { return nil }
            return NodeConnector(type: t, key: k)
        }()
        #expect(connector?.type == "ELEVATOR")
        #expect(connector?.key == "ELV-01")
    }

    @Test("null connector value produces nil NodeConnector")
    func nullConnectorProducesNil() {
        let nodeDict: [String: V1AnyValue] = [
            "id": .string("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"),
            "type": .string("corridor"),
            "x": .double(1.0),
            "y": .double(2.0),
            "connector": .null
        ]
        let connector: NodeConnector? = {
            guard let connDict = nodeDict["connector"]?.asDict,
                  let t = connDict["type"]?.asString,
                  let k = connDict["key"]?.asString else { return nil }
            return NodeConnector(type: t, key: k)
        }()
        #expect(connector == nil)
    }
}
