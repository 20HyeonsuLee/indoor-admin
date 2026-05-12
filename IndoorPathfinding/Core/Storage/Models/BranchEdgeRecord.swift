import GRDB
import Foundation

/// branch_edge 테이블 row 모델 (Sprint 89 cycle 1, schema v9).
/// MarkingState.edges 를 finalize 시점에 영속화한다.
/// cornerPolygon kind 는 mark_session_id / polygon_closed 추가 필드를 가진다.
struct BranchEdgeRecord: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "branch_edge"

    var id: Int64?
    var scanId: String
    var fromNodeId: String          // BranchMarkNodeId(Int64).description
    var toNodeId: String
    var kind: String                // EdgeKind.rawValue: sequential|proximity|transition|cornerPolygon
    var lengthM: Double
    var markSessionId: String?      // cornerPolygon 한정 (UUID.uuidString)
    var polygonClosed: Int?         // 0 or 1, cornerPolygon 한정. 다른 kind 는 NULL
    var createdAt: Int64            // epoch milliseconds

    enum CodingKeys: String, CodingKey {
        case id
        case scanId = "scan_id"
        case fromNodeId = "from_node_id"
        case toNodeId = "to_node_id"
        case kind
        case lengthM = "length_m"
        case markSessionId = "mark_session_id"
        case polygonClosed = "polygon_closed"
        case createdAt = "created_at"
    }

    enum Columns: String, ColumnExpression {
        case id
        case scanId = "scan_id"
        case fromNodeId = "from_node_id"
        case toNodeId = "to_node_id"
        case kind
        case lengthM = "length_m"
        case markSessionId = "mark_session_id"
        case polygonClosed = "polygon_closed"
        case createdAt = "created_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
