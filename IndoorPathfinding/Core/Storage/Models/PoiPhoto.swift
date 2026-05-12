import GRDB
import Foundation

/// `poi_photo` 테이블 레코드.
/// Sprint 65: bbox 컬럼 제거 — 수동 POI는 bbox 없음. image_blob + class_name + confidence만 유지.
struct PoiPhoto: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "poi_photo"

    var id: Int64?
    var poiMarkId: Int64
    var scanId: String
    var keyframeSeq: Int
    var capturedAt: Int64
    var className: String
    var confidence: Double
    /// jpeg image bytes (POI 마킹 시점 latestHolder pixelBuffer encode).
    /// nil 이면 사진 미보관 (legacy v4 row 또는 encode 실패).
    var imageBlob: Data?

    enum CodingKeys: String, CodingKey {
        case id
        case poiMarkId   = "poi_mark_id"
        case scanId      = "scan_id"
        case keyframeSeq = "keyframe_seq"
        case capturedAt  = "captured_at"
        case className   = "class_name"
        case confidence
        case imageBlob   = "image_blob"
    }

    enum Columns: String, ColumnExpression {
        case id
        case poiMarkId   = "poi_mark_id"
        case scanId      = "scan_id"
        case keyframeSeq = "keyframe_seq"
        case capturedAt  = "captured_at"
        case className   = "class_name"
        case confidence
        case imageBlob   = "image_blob"
    }
}
