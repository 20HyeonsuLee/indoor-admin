import GRDB
import Foundation

/// `scan_session` 테이블 레코드.
struct ScanSession: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "scan_session"

    var id: String               // UUID string
    var startedAt: Int64         // Unix ms
    var endedAt: Int64?
    var deviceModel: String
    var appVersion: String
    var state: State
    var keyframeCount: Int
    var notes: String?

    enum State: String, Codable, DatabaseValueConvertible {
        case recording
        case saved
        case discarded
    }

    enum CodingKeys: String, CodingKey {
        case id
        case startedAt    = "started_at"
        case endedAt      = "ended_at"
        case deviceModel  = "device_model"
        case appVersion   = "app_version"
        case state
        case keyframeCount = "keyframe_count"
        case notes
    }

    enum Columns: String, ColumnExpression {
        case id, startedAt = "started_at", endedAt = "ended_at"
        case deviceModel = "device_model", appVersion = "app_version"
        case state, keyframeCount = "keyframe_count", notes
    }
}
