import Testing
import Foundation
import SwiftUI
@testable import IndoorPathfinding

// MARK: - ScanLaunchContext areaId/areaLabel 테스트

struct ScanLaunchContextAreaTests {

    @Test("areaId 있을 때 notesJSON에 areaId/areaLabel 포함")
    func notesJSON_includesAreaIdAndLabel_whenAreaIdProvided() throws {
        let buildingId = UUID()
        let floorId = UUID()
        let areaId = UUID()

        let ctx = ScanLaunchContext(
            buildingId: buildingId,
            floorId: floorId,
            floorName: "1F",
            floorLevel: 1,
            areaId: areaId,
            areaLabel: "Main Area"
        )

        let jsonStr = try #require(ctx.uploadNotesJSON)
        let data = try #require(jsonStr.data(using: .utf8))
        let dict = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])

        #expect(dict["areaId"] == areaId.uuidString)
        #expect(dict["areaLabel"] == "Main Area")
        #expect(dict["buildingId"] == buildingId.uuidString)
        #expect(dict["floorId"] == floorId.uuidString)
        #expect(dict["floorName"] == "1F")
        #expect(dict["floorLevel"] == "1")
    }

    @Test("areaId nil일 때 notesJSON에 areaId 키 없음, areaLabel 있음")
    func notesJSON_noAreaIdKey_whenAreaIdIsNil() throws {
        let ctx = ScanLaunchContext(
            buildingId: UUID(),
            floorId: UUID(),
            floorName: "2F",
            floorLevel: 2,
            areaId: nil,
            areaLabel: "default"
        )

        let jsonStr = try #require(ctx.uploadNotesJSON)
        let data = try #require(jsonStr.data(using: .utf8))
        let dict = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])

        #expect(dict["areaId"] == nil)
        #expect(dict["areaLabel"] == "default")
    }
}

// MARK: - AdminFloorGraphView 색상 매핑 테스트

struct AreaColorTests {

    @Test("colorForAreaIndex: index 0~7이 서로 다른 색상")
    func colorForAreaIndex_returnsDistinctColorsForFirst8() {
        let colors = (0..<8).map { AdminFloorGraphView.colorForAreaIndex($0) }
        // 색상 문자열로 비교 (Color는 Equatable 미채택 → description 사용)
        let descriptions = colors.map { "\($0)" }
        let unique = Set(descriptions)
        #expect(unique.count == 8)
    }

    @Test("colorForAreaIndex: index 8은 index 0과 동일 (wrap)")
    func colorForAreaIndex_wrapsAt8() {
        let color0 = "\(AdminFloorGraphView.colorForAreaIndex(0))"
        let color8 = "\(AdminFloorGraphView.colorForAreaIndex(8))"
        #expect(color0 == color8)
    }
}
