import Testing
import Foundation
@testable import IndoorPathfinding

@Suite("RouteRequestPayload")
struct RouteRequestPayloadTests {

    @Test("encodes server route contract")
    func encodesCoordinateAndPoiGoal() throws {
        let payload = RouteRequestPayload(
            scanId: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            start: RouteEndpointPayload(coordinate: [1.0, 2.0, 0.0], poiMarkId: nil),
            goal: RouteEndpointPayload(coordinate: nil, poiMarkId: 42)
        )

        let data = try JSONEncoder().encode(payload)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let start = object?["start"] as? [String: Any]
        let goal = object?["goal"] as? [String: Any]

        #expect(object?["scan_id"] as? String == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
        #expect(start?["coordinate"] as? [Double] == [1.0, 2.0, 0.0])
        #expect(goal?["poi_mark_id"] as? Int == 42)
    }

    @Test("encodes multi-scan merge route contract")
    func encodesMultiScanMergeOptions() throws {
        let payload = RouteRequestPayload(
            scanId: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            scanIds: [
                "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
                "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
            ],
            mergeOverlaps: true,
            start: RouteEndpointPayload(coordinate: [0.0, 0.0, 0.0], poiMarkId: nil),
            goal: RouteEndpointPayload(coordinate: nil, poiMarkId: 7)
        )

        let data = try JSONEncoder().encode(payload)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(object?["scan_ids"] as? [String] == [
            "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        ])
        #expect(object?["merge_overlaps"] as? Bool == true)
    }
}
