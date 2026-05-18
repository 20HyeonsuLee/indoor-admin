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

// MARK: - AdminWorkspaceStore selectedAreaId 동작 테스트

struct SelectedAreaGraphTests {

    @Test("loadsOnlySelectedAreaGraph: selectedAreaId 변경 후 effectiveAreaId가 변경된 값 반환")
    @MainActor
    func loadsOnlySelectedAreaGraph() {
        let store = AdminWorkspaceStore()
        let floorId = UUID()
        let areaId1 = UUID()
        let areaId2 = UUID()

        store.areas[floorId] = [
            V1FloorArea(areaId: areaId1, floorId: floorId, areaIndex: 0, label: "A", isDefault: true, createdAt: "2024-01-01T00:00:00Z"),
            V1FloorArea(areaId: areaId2, floorId: floorId, areaIndex: 1, label: "B", isDefault: false, createdAt: "2024-01-01T00:00:00Z"),
        ]
        store.selectedAreaId[floorId] = areaId1
        #expect(store.effectiveAreaId(floorId: floorId) == areaId1)

        // area 변경
        store.selectArea(floorId: floorId, areaId: areaId2)
        #expect(store.effectiveAreaId(floorId: floorId) == areaId2)
    }

    @Test("defaultAreaId fallback: selectedAreaId 없으면 isDefault area 반환")
    @MainActor
    func defaultAreaId_fallback() {
        let store = AdminWorkspaceStore()
        let floorId = UUID()
        let defaultId = UUID()

        store.areas[floorId] = [
            V1FloorArea(areaId: defaultId, floorId: floorId, areaIndex: 0, label: "default", isDefault: true, createdAt: "2024-01-01T00:00:00Z"),
        ]
        // selectedAreaId 미설정
        #expect(store.effectiveAreaId(floorId: floorId) == defaultId)
    }

    @Test("colorForAreaIndex: index 0~7이 서로 다른 색상 (하위 호환 보존)")
    func colorForAreaIndex_returnsDistinctColorsForFirst8() {
        let colors = (0..<8).map { AdminFloorGraphView.colorForAreaIndex($0) }
        let descriptions = colors.map { "\($0)" }
        let unique = Set(descriptions)
        #expect(unique.count == 8)
    }
}
