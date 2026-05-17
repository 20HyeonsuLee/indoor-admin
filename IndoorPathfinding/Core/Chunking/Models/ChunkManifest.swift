import Foundation

/// chunk 단위 메타데이터. 디스크에 JSON으로 직렬화한다.
/// ADR Data model — ChunkManifest.
struct ChunkManifest: Codable, Sendable {
    /// ScanStore가 생성. 같은 scan session의 chunk를 묶는 client-side 식별자.
    let scanSessionId: UUID
    /// ScanLaunchContext.floorId (lock). ADR D6.
    let floorId: UUID
    /// 0-based chunk 순번.
    let chunkIndex: Int
    let startedAt: Date
    var endedAt: Date?
    /// rollover 후 첫 1s window 안에 새 DB가 받은 keyframe 수. 첫 chunk는 0. ADR D3.
    var overlapKeyframes: Int
    /// overlapKeyframes < 5. 서버 merge reject 가능성 진단 신호.
    var overlapWarning: Bool { overlapKeyframes < 5 && chunkIndex > 0 }
    /// chunk staging directory 기준 상대경로.
    let rtabmapDBPath: String
    /// archive 완료 후 set.
    var zipPath: String?
    /// 서버 ingest 에 넘길 scan_id. ZIP root / manifest.json / scan_session.id 와 같아야 한다.
    var uploadScanId: String?
    /// chunk archive 안 scan_metadata.db 기준 keyframe_meta row 수.
    var archivedKeyframeCount: Int?
    var archivedBranchMarkCount: Int?
    var archivedBranchEdgeCount: Int?
    /// background upload에 넘긴 ZIP 파일 크기.
    var zipByteCount: Int64?
    /// URLSession upload task 시작/종료 시각.
    var uploadStartedAt: Date?
    var uploadCompletedAt: Date?
    /// 마지막 HTTP status. 네트워크 오류면 nil.
    var lastHTTPStatus: Int?
    /// upload 성공 후 V1ScanChunk.id.
    var serverChunkId: UUID?
    var uploadState: ChunkUploadState
    var lastError: String?
    var retryCount: Int
    /// startedAt + 7일 (OS retain 한도). ADR D4.
    let expiresAt: Date

    init(
        scanSessionId: UUID,
        floorId: UUID,
        chunkIndex: Int,
        startedAt: Date,
        rtabmapDBPath: String
    ) {
        self.scanSessionId = scanSessionId
        self.floorId = floorId
        self.chunkIndex = chunkIndex
        self.startedAt = startedAt
        self.rtabmapDBPath = rtabmapDBPath
        self.overlapKeyframes = 0
        self.uploadState = .archiving
        self.retryCount = 0
        self.expiresAt = startedAt.addingTimeInterval(7 * 24 * 3600)
    }
}
