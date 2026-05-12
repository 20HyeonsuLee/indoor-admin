import GRDB
import Foundation

/// `keyframe_meta` 테이블 레코드.
struct KeyframeMeta: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "keyframe_meta"

    var scanId: String           // scan_session.id 외래키
    var seq: Int                 // 세션 스코프 단조 증가 (1-based)
    var capturedAt: Int64        // Unix ms
    var imagePath: String        // scan_id 폴더 기준 상대경로 ("keyframes/000001.jpg")
    var poseMatrix: Data         // 4x4 column-major float32, 64 bytes
    var tx: Double
    var ty: Double
    var tz: Double
    var trackingState: String
    var rtabmapNodeId: Int?      // Sprint 3 채움 예정

    enum CodingKeys: String, CodingKey {
        case scanId          = "scan_id"
        case seq
        case capturedAt      = "captured_at"
        case imagePath       = "image_path"
        case poseMatrix      = "pose_matrix"
        case tx, ty, tz
        case trackingState   = "tracking_state"
        case rtabmapNodeId   = "rtabmap_node_id"
    }

    enum Columns: String, ColumnExpression {
        case scanId = "scan_id", seq, capturedAt = "captured_at"
        case imagePath = "image_path", poseMatrix = "pose_matrix"
        case tx, ty, tz, trackingState = "tracking_state"
        case rtabmapNodeId = "rtabmap_node_id"
    }
}
