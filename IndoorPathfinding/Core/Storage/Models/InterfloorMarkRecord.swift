import GRDB
import Foundation

/// `interfloor_mark` 테이블 레코드.
/// Sprint 65: ScanStore.InterfloorMark(in-memory, UUID id) 와 분리된 영속 레코드.
/// connector_type 은 'elevator' / 'escalator' / 'stairs' 중 하나.
/// prefix 는 사용자 입력 (예: "EV-A", "ST-B"). 서버 ingest 시 Sprint 62 VerticalConnectorResolver 의
/// connector_key 매칭에 사용된다.
/// Sprint 88 Cycle 6: v8 schema 확장 — dxLocal/dyLocal/dzLocal Optional 3컬럼 추가.
struct InterfloorMarkRecord: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "interfloor_mark"

    var id: Int64?
    var scanId: String
    var keyframeSeq: Int
    var createdAt: Int64
    var connectorType: String
    var prefix: String
    var poseMatrix: Data
    var tx: Double
    var ty: Double
    var tz: Double

    // MARK: v8 컬럼 — keyframe-local translation delta (m)
    /// nil = 레거시 v7 이하 row. server backfill 시 legacy 경로(keyframe pose 덮어쓰기).
    /// interfloor: markWorldTransform == lastCapturedTransform → 신규 mark는 0.0 명시 저장.
    var dxLocal: Double?
    var dyLocal: Double?
    var dzLocal: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case scanId        = "scan_id"
        case keyframeSeq   = "keyframe_seq"
        case createdAt     = "created_at"
        case connectorType = "connector_type"
        case prefix
        case poseMatrix    = "pose_matrix"
        case tx, ty, tz
        case dxLocal       = "dx_local"
        case dyLocal       = "dy_local"
        case dzLocal       = "dz_local"
    }

    enum Columns: String, ColumnExpression {
        case id
        case scanId        = "scan_id"
        case keyframeSeq   = "keyframe_seq"
        case createdAt     = "created_at"
        case connectorType = "connector_type"
        case prefix
        case poseMatrix    = "pose_matrix"
        case tx, ty, tz
        case dxLocal       = "dx_local"
        case dyLocal       = "dy_local"
        case dzLocal       = "dz_local"
    }

    // MARK: - 편의 생성자 (v7 호환 — v8 새 컬럼 default nil)
    init(
        id: Int64? = nil,
        scanId: String,
        keyframeSeq: Int,
        createdAt: Int64,
        connectorType: String,
        prefix: String,
        poseMatrix: Data,
        tx: Double,
        ty: Double,
        tz: Double,
        dxLocal: Double? = nil,
        dyLocal: Double? = nil,
        dzLocal: Double? = nil
    ) {
        self.id = id
        self.scanId = scanId
        self.keyframeSeq = keyframeSeq
        self.createdAt = createdAt
        self.connectorType = connectorType
        self.prefix = prefix
        self.poseMatrix = poseMatrix
        self.tx = tx
        self.ty = ty
        self.tz = tz
        self.dxLocal = dxLocal
        self.dyLocal = dyLocal
        self.dzLocal = dzLocal
    }
}
