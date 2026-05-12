import GRDB
import Foundation

/// `poi_mark` 테이블 레코드.
/// Sprint 65: track_id 컬럼 제거 — Track Lock 경로 폐기, 수동 POI 단일 경로.
/// Sprint 88 Cycle 6: v8 schema 확장 — dxLocal/dyLocal/dzLocal Optional 3컬럼 추가.
struct PoiMark: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "poi_mark"

    var id: Int64?
    var scanId: String
    var keyframeSeq: Int
    var createdAt: Int64
    var poseMatrix: Data
    var tx: Double
    var ty: Double
    var tz: Double
    /// 관리자가 입력한 POI 라벨. nil = 미입력.
    var label: String?
    /// POI 등록 방식. Sprint 65 이후 항상 "manual" (Track Lock 폐기).
    var source: String

    // MARK: v8 컬럼 — keyframe-local translation delta (m)
    /// nil = 레거시 v7 이하 row. server backfill 시 legacy 경로(keyframe pose 덮어쓰기).
    /// POI는 markWorldTransform == lastCapturedTransform → 신규 mark는 0.0 명시 저장.
    var dxLocal: Double?
    var dyLocal: Double?
    var dzLocal: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case scanId      = "scan_id"
        case keyframeSeq = "keyframe_seq"
        case createdAt   = "created_at"
        case poseMatrix  = "pose_matrix"
        case tx, ty, tz
        case label
        case source
        case dxLocal     = "dx_local"
        case dyLocal     = "dy_local"
        case dzLocal     = "dz_local"
    }

    enum Columns: String, ColumnExpression {
        case id, scanId = "scan_id", keyframeSeq = "keyframe_seq"
        case createdAt = "created_at", poseMatrix = "pose_matrix"
        case tx, ty, tz, label, source
        case dxLocal = "dx_local", dyLocal = "dy_local", dzLocal = "dz_local"
    }

    /// source 값 타입 안전 접근용 열거형.
    /// - manual: 수동 등록 (Sprint 14 도입, Sprint 65 이후 단일 경로).
    /// - trackLock: 폐기. v5 이전 row 호환 유지용.
    enum Source: String {
        case manual
        case trackLock = "track_lock"
    }

    // MARK: - 편의 생성자 (v7 호환 — v8 새 컬럼 default nil)
    init(
        id: Int64? = nil,
        scanId: String,
        keyframeSeq: Int,
        createdAt: Int64,
        poseMatrix: Data,
        tx: Double,
        ty: Double,
        tz: Double,
        label: String? = nil,
        source: String,
        dxLocal: Double? = nil,
        dyLocal: Double? = nil,
        dzLocal: Double? = nil
    ) {
        self.id = id
        self.scanId = scanId
        self.keyframeSeq = keyframeSeq
        self.createdAt = createdAt
        self.poseMatrix = poseMatrix
        self.tx = tx
        self.ty = ty
        self.tz = tz
        self.label = label
        self.source = source
        self.dxLocal = dxLocal
        self.dyLocal = dyLocal
        self.dzLocal = dzLocal
    }
}

/// `branch_mark` 테이블 레코드.
/// Sprint 88 Cycle 2: v7 schema 확장 — node_type/width_m/connect_hint/connect_node_id/mark_session_id 5개 컬럼 추가.
/// Sprint 88 Cycle 6: v8 schema 확장 — dxLocal/dyLocal/dzLocal Optional 3컬럼 추가.
struct BranchMark: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "branch_mark"

    var id: Int64?
    var scanId: String
    var keyframeSeq: Int
    var createdAt: Int64
    var poseMatrix: Data
    var tx: Double
    var ty: Double
    var tz: Double

    // MARK: v7 컬럼
    /// 노드 종류. 'corridor'(기본) 또는 'corner'.
    var nodeType: String
    /// 복도 폭(미터). corner 노드는 NULL.
    var widthM: Double?
    /// 연결 힌트. NULL = sequential, 'proximity' = 사용자가 끊기 후 proximity 선택.
    var connectHint: String?
    /// proximity 모드에서 연결 대상 branch_mark.id 를 String화한 값. NULL = sequential.
    var connectNodeId: String?
    /// corner cluster UUID. corner 노드만 가짐. corridor = NULL.
    var markSessionId: String?

    // MARK: v8 컬럼 — keyframe-local translation delta (m)
    /// nil = 레거시 v7 이하 row. server backfill 시 legacy 경로(keyframe pose 덮어쓰기).
    /// corridor: dy ≈ floorY − cameraY, dx=dz=0.
    /// corner: (hitX−camX, floorY−camY, hitZ−camZ).
    /// markBranch legacy: 0.0 명시 (keyframe 동일 위치 의미).
    var dxLocal: Double?
    var dyLocal: Double?
    var dzLocal: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case scanId        = "scan_id"
        case keyframeSeq   = "keyframe_seq"
        case createdAt     = "created_at"
        case poseMatrix    = "pose_matrix"
        case tx, ty, tz
        case nodeType      = "node_type"
        case widthM        = "width_m"
        case connectHint   = "connect_hint"
        case connectNodeId = "connect_node_id"
        case markSessionId = "mark_session_id"
        case dxLocal       = "dx_local"
        case dyLocal       = "dy_local"
        case dzLocal       = "dz_local"
    }

    enum Columns: String, ColumnExpression {
        case id, scanId = "scan_id", keyframeSeq = "keyframe_seq"
        case createdAt = "created_at", poseMatrix = "pose_matrix"
        case tx, ty, tz
        case nodeType = "node_type", widthM = "width_m"
        case connectHint = "connect_hint", connectNodeId = "connect_node_id"
        case markSessionId = "mark_session_id"
        case dxLocal = "dx_local", dyLocal = "dy_local", dzLocal = "dz_local"
    }

    // MARK: - 편의 생성자 (v7 호환 — v8 새 컬럼 default nil)
    init(
        id: Int64? = nil,
        scanId: String,
        keyframeSeq: Int,
        createdAt: Int64,
        poseMatrix: Data,
        tx: Double,
        ty: Double,
        tz: Double,
        nodeType: String = "corridor",
        widthM: Double? = nil,
        connectHint: String? = nil,
        connectNodeId: String? = nil,
        markSessionId: String? = nil,
        dxLocal: Double? = nil,
        dyLocal: Double? = nil,
        dzLocal: Double? = nil
    ) {
        self.id = id
        self.scanId = scanId
        self.keyframeSeq = keyframeSeq
        self.createdAt = createdAt
        self.poseMatrix = poseMatrix
        self.tx = tx
        self.ty = ty
        self.tz = tz
        self.nodeType = nodeType
        self.widthM = widthM
        self.connectHint = connectHint
        self.connectNodeId = connectNodeId
        self.markSessionId = markSessionId
        self.dxLocal = dxLocal
        self.dyLocal = dyLocal
        self.dzLocal = dzLocal
    }
}
