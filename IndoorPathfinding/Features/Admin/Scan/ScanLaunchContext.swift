import Foundation

/// floor-centric 스캔 진입 컨텍스트.
/// fullScreenCover(item:)이 Identifiable을 요구하므로 채택.
/// 옛 AdminScanContext의 section/mergeGroup/assignedAdmin 필드는 새 모델에 없다.
struct ScanLaunchContext: Identifiable, Hashable {
    let id = UUID()
    let buildingId: UUID
    let floorId: UUID
    let floorName: String
    let floorLevel: Int
    let areaId: UUID?
    let areaLabel: String

    /// HUD에 보여줄 한 줄 컨텍스트.
    var uploadSummary: String {
        "\(floorName) (Level \(floorLevel))"
    }

    /// scan_session.notes 컬럼에 저장될 JSON 문자열.
    var uploadNotesJSON: String? {
        var payload: [String: String] = [
            "buildingId": buildingId.uuidString,
            "floorId": floorId.uuidString,
            "floorName": floorName,
            "floorLevel": String(floorLevel),
            "areaLabel": areaLabel
        ]
        if let areaId {
            payload["areaId"] = areaId.uuidString
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }
}
