import Testing
import Foundation
@testable import IndoorPathfinding

@Suite("IMDFParser")
struct IMDFParserTests {

    @Test("IMDF-lite files parse into map, units, POIs, metadata")
    func parseFeatureCollections() throws {
        let files: [String: Data] = [
            "manifest.json": data([
                "format": "indoor-pathfinding-imdf-lite",
                "scan_id": "scan-1",
                "build_job_id": "job-1",
                "coordinate_system": "local_metric",
                "unit_split": ["unit_count": 2],
                "rectification": ["accepted": true]
            ]),
            "footprint.geojson": featureCollection([polygonFeature(id: "footprint-0", category: "ground")]),
            "unit.geojson": featureCollection([
                polygonFeature(id: "unit-walkway-0", category: "walkway"),
                polygonFeature(id: "place-poi-7", category: "room", semantic: true)
            ]),
            "amenity.geojson": featureCollection([
                [
                    "type": "Feature",
                    "id": "amenity-7",
                    "geometry": ["type": "Point", "coordinates": [3.0, 2.0, 0.0]],
                    "properties": [
                        "poi_mark_id": 7,
                        "name": ["ko": "출입구"],
                        "category": "entrance",
                        "display_point": [3.5, 2.5, 0.0],
                        "display_area_id": "place-poi-7",
                        "connector_type": "stairs",
                        "connector_key": "STAIR_A"
                    ]
                ]
            ]),
            "anchor.geojson": featureCollection([
                [
                    "type": "Feature",
                    "id": "anchor-origin",
                    "geometry": ["type": "Point", "coordinates": [0.0, 0.0, 0.0]],
                    "properties": [:]
                ]
            ])
        ]

        let map = try IMDFParser().parse(files: files)

        #expect(map.manifest.scanId == "scan-1")
        #expect(map.manifest.unitCount == 2)
        #expect(map.manifest.rectified == true)
        #expect(map.units.count == 2)
        #expect(map.units[1].semantic == true)
        #expect(map.units[1].sourcePoiMarkId == 7)
        #expect(map.amenities.first?.poiMarkId == 7)
        #expect(map.amenities.first?.name == "출입구")
        #expect(map.amenities.first?.category == "entrance")
        #expect(map.amenities.first?.displayAreaId == "place-poi-7")
        #expect(map.amenities.first?.connectorKey == "STAIR_A")
        #expect(map.bounds.isValid)
    }

    @Test("missing manifest throws")
    func missingManifestThrows() throws {
        #expect(throws: IMDFParserError.missingManifest) {
            _ = try IMDFParser().parse(files: [:])
        }
    }

    private func data(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func featureCollection(_ features: [[String: Any]]) -> Data {
        data(["type": "FeatureCollection", "features": features])
    }

    private func polygonFeature(
        id: String,
        category: String,
        semantic: Bool = false
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "category": category,
            "name": ["ko": "테스트"],
            "semantic": semantic
        ]
        if semantic {
            properties["source_poi_mark_id"] = 7
        }
        return [
            "type": "Feature",
            "id": id,
            "geometry": [
                "type": "Polygon",
                "coordinates": [[[0.0, 0.0], [4.0, 0.0], [4.0, 2.0], [0.0, 2.0], [0.0, 0.0]]]
            ],
            "properties": properties
        ]
    }
}
