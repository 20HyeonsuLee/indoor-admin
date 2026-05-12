import Observation
import ARKit
import CoreImage
import SceneKit
import simd
import Foundation
import GRDB
import UIKit
import os.log

/// 스캔 세션의 모든 상태를 보유하는 Observable Store.
/// ScanSessionView가 @State로 소유. 모든 상태 변경은 Main thread.
@Observable
@MainActor
final class ScanStore {

    // MARK: - POI Mark Mode (Sprint 13 + Sprint 14)

    /// POI 마킹 상태 머신.
    /// - idle: 기본 상태. bbox 탭 대기.
    /// - tracking(trackId, photos): track 잠금 + 사진 수집 중. photos.isEmpty → 사진 0장.
    /// - manualPhotoTaken(photo): Sprint 14 수동 모드. 사진 1장 찍고 이동 중.
    /// - confirming(origin): DB write in-flight. origin으로 실패 시 복구 경로 추적.
    enum POIMarkMode: Equatable {
        case idle
        case manualPhotoTaken(photo: PendingPhoto)                  // Sprint 14: 사진 찍고 이동 중
        case confirming(origin: ConfirmOrigin)                      // DB write in-flight

        /// confirming 실패 시 복구 경로.
        enum ConfirmOrigin: Equatable {
            case manual(photo: PendingPhoto)
        }
    }

    /// confirmPOI 전까지 메모리에만 보관하는 pending 사진 버퍼.
    /// Sprint 14: bbox 필드를 Optional로 변경 (수동 모드는 bbox 없음).
    /// Sprint 49: imageBlob — POI 마킹 시점 jpeg bytes (poi_photo.image_blob 저장).
    struct PendingPhoto: Equatable, Sendable {
        let keyframeSeq: Int
        let capturedAt: Int64
        let bboxX: Double?
        let bboxY: Double?
        let bboxW: Double?
        let bboxH: Double?
        let className: String
        let confidence: Double
        let imageBlob: Data?

        /// imageBlob 의 default = nil 로 두어 기존 호출자 (테스트 등) 가 깨지지 않도록 한다.
        init(
            keyframeSeq: Int,
            capturedAt: Int64,
            bboxX: Double?,
            bboxY: Double?,
            bboxW: Double?,
            bboxH: Double?,
            className: String,
            confidence: Double,
            imageBlob: Data? = nil
        ) {
            self.keyframeSeq = keyframeSeq
            self.capturedAt = capturedAt
            self.bboxX = bboxX
            self.bboxY = bboxY
            self.bboxW = bboxW
            self.bboxH = bboxH
            self.className = className
            self.confidence = confidence
            self.imageBlob = imageBlob
        }
    }

    enum InterfloorConnectorType: String, CaseIterable, Identifiable {
        case elevator
        case escalator
        case stairs

        var id: String { rawValue }

        var title: String {
            switch self {
            case .elevator: return "엘리베이터"
            case .escalator: return "에스컬레이터"
            case .stairs: return "계단"
            }
        }

        var icon: String {
            switch self {
            case .elevator: return "arrow.up.arrow.down.square"
            case .escalator: return "arrow.up.forward.square"
            case .stairs: return "figure.stairs"
            }
        }

        var prefixSeed: String {
            switch self {
            case .elevator: return "EV"
            case .escalator: return "ES"
            case .stairs: return "ST"
            }
        }
    }

    struct InterfloorMark: Identifiable, Equatable {
        let id = UUID()
        let type: InterfloorConnectorType
        let prefix: String
        let keyframeSeq: Int
        let tx: Double
        let ty: Double
        let tz: Double
    }

    // MARK: - InterfloorConnectorType → MarkARSceneOverlay.StandaloneMarkerKind 매핑 (cycle_7)

    // MARK: - Phase

    enum Phase: Equatable {
        case idle
        case recording
        case paused
        case finalizing
        case saved
        case discarded
        case failed(String)

        static func == (lhs: Phase, rhs: Phase) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.recording, .recording),
                 (.paused, .paused), (.finalizing, .finalizing),
                 (.saved, .saved), (.discarded, .discarded):
                return true
            case (.failed(let a), .failed(let b)):
                return a == b
            default:
                return false
            }
        }
    }

    // MARK: - Published State

    private(set) var phase: Phase = .idle
    private(set) var keyframeCount: Int = 0
    private(set) var poiMarkCount: Int = 0
    private(set) var branchMarkCount: Int = 0
    private(set) var trackingStateLabel: String = "notAvailable"
    /// Sprint 95: 빠른걸음 감지 — angular velocity 0.6 rad/s 0.3s sustained.
    /// ARKit `excessiveMotion` 도달 *전*에 미리 사용자 경고. UI 적색 보더 + haptic 트리거.
    private(set) var fastMotion: Bool = false
    /// 5-frame moving average angular velocity (rad/s). UI/디버그 노출.
    private(set) var angularVelocityRadPerSec: Float = 0
    private(set) var currentTranslation: SIMD3<Float>?
    private(set) var coveragePoints: [CGPoint] = []
    private(set) var interfloorMarks: [InterfloorMark] = []
    private(set) var lastError: String?
    private(set) var pendingQueueCount: Int = 0

    /// Debug: raw corner tap mode. ON일 때 코너 모드 탭은
    /// (1) raw 화면 좌표(magenta) 즉시 buffer 저장 +
    /// (2) raycast → world point(yellow) — DB/MarkingState 등록 X, ARNodeOverlayView가 매 프레임 projectPoint로 yellow dot 갱신.
    /// 첫 프레임 둘 일치 / 카메라 이동 시 yellow 따라오는지로 어디서 어긋나는지 진단.
    var rawCornerTapDebugMode: Bool = false
    private(set) var debugRawCornerTaps: [CGPoint] = []
    /// (CGPoint, world SIMD3<Float>) 쌍. raycast 결과만 들어감 (raycast 실패 시 추가 X).
    /// raw tap 인덱스와 매칭되도록 같은 순서로 append. 길이는 다를 수 있음 (raycast fail).
    private(set) var debugRaycastWorldPoints: [SIMD3<Float>] = []
    /// Sprint 88 cycle_4 H10 stabilize: raycast 성공 시 ARAnchor 추가하고 id 저장.
    /// ARNodeOverlayView가 frame.anchors에서 lookup → ARKit이 매 프레임 transform을 자체 stabilize.
    /// fallback으로 worldPoint도 같이 보관 (anchor 미발견 시 SIMD3 사용).
    private(set) var debugRaycastAnchorIds: [UUID] = []

    /// Sprint 88 cycle_4 H10 fix: viewport-aware raycastQuery용 ARSCNView weak ref.
    /// ScanSessionView가 ARPreviewView 생성 시 콜백으로 set.
    weak var sceneViewRef: ARSCNView?

    /// Sprint 88 cycle_5: ARSCNViewDelegate + SCNNode mark overlay 관리자.
    /// ScanStore가 소유. setSceneView(_:) 에서 delegate 부착.
    let markARSceneOverlay: MarkARSceneOverlay = MarkARSceneOverlay()
    /// Sprint 13: POI 마킹 상태 머신.
    private(set) var markMode: POIMarkMode = .idle
    let context: ScanLaunchContext

    // MARK: - MarkingState (Sprint 88 Cycle 2)

    /// in-memory 노드/에지 그래프 + 전이 룰 단일 SoT.
    private(set) var markingState: MarkingState = MarkingState()

    // MARK: - Floor Reference (Sprint 88 Cycle 4)

    /// 바닥 평면 y 좌표 추적기. ScanStore 소유, ARSessionManager에서 anchor 이벤트를 받는다.
    let floorTracker: FloorReferenceTracker = FloorReferenceTracker()

    /// 도구 모드. ScanSessionView에서 segmented picker와 바인딩.
    private(set) var activeTool: ScanToolMode = .scan

    /// micro-toast 메시지. 1.5초 후 nil로 리셋.
    private(set) var microToastMessage: String?

    /// 마지막으로 편집 요청한 노드 ID (NodeEditSheet 트리거).
    private(set) var editingNodeId: BranchMarkNodeId?

    /// 최신 AR 프레임. overlay projection에 사용. ARSession.currentFrame을 직접 읽음.
    var latestARFrame: ARFrame? { sessionManager.arSession?.currentFrame }

    /// 현재 hint banner. markingState.hintBannerCase 또는 backtracking 감지.
    private(set) var hintBannerCase: HintBannerCase?

    /// proximity 후보 선택 sheet 표시 여부 (Medium-B).
    var showProximitySheet: Bool = false

    // 백트래킹 감지용 heading 추적
    private var lastCameraHeading: SIMD3<Float> = SIMD3<Float>(0, 0, -1)

    // MARK: - SLAM Stats (HUD)

    let statsModel: RTABMapStatsModel = RTABMapStatsModel()
    var loopClosureCount: Int { statsModel.stats.loopClosureCount }
    private(set) var dbSizeBytes: Int64 = 0
    var interfloorMarkCount: Int { interfloorMarks.count }

    // MARK: - Chunked scan state (ADR D1/D5)

    /// 현재 활성 chunk 인덱스 (0-based).
    private(set) var currentChunkIndex: Int = 0
    /// 현재 chunk 시작 시각.
    private(set) var currentChunkStartedAt: Date = .now
    /// scan session 전체를 묶는 client-side UUID.
    private(set) var scanSessionId: UUID = UUID()
    /// chunk upload 상태 구독용 Observable. ScanSessionView badge/ChunkQueueSheet가 구독.
    /// ADR D7: AdminFloorDetailView가 소유하는 observer를 외부에서 주입 가능.
    let chunkUploadObserver: ChunkUploadObserver

    /// ChunkRolloverScheduler. nil이면 chunk 기능 비활성 (serverClient 없음).
    private var chunkRolloverScheduler: ChunkRolloverScheduler?
    /// ChunkUploadQueue. nil이면 chunk 기능 비활성.
    /// ADR D5: ChunkQueueSheet가 retry/delete swipe action을 위해 접근한다.
    private(set) var chunkUploadQueue: ChunkUploadQueue?

    // MARK: - Internals

    let scanId: String
    let fileStore: ScanFileStore
    /// production 코드에서 직접 접근 금지. 테스트는 testDB extension을 사용.
    private(set) var db: ScanMetadataDatabase?
    private var keyframeRepo: KeyframeRepository?
    private var markRepo: MarkRepository?
    /// Sprint 88 Cycle 6: v8 — interfloor_mark dx_local/dy_local/dz_local 저장 담당.
    private var interfloorMarkRepo: InterfloorMarkRepository?
    var sessionManager: ARSessionManager

    var arSession: ARSession? { sessionManager.arSession }

    /// FrameFanout: 다중 Consumer fan-out 담당.
    private var fanout: FrameFanout?
    /// SLAM sink. 사용자 결정으로 raw frame 미공급 — 호환을 위해 보관만 유지.
    private let slamSink: RTABMapSLAMSink

    // Sprint 93: VideoRecorder/PoseFileWriter dead 인스턴스 제거 (sprint90 live_rtabmap 전환 후 미사용).
    // 클래스/파일 자체는 ManifestWriter.makeV7 (deprecated 호환 + 테스트)에서 fileName 상수만 참조하므로 보존.

    private let storageQueue = DispatchQueue(label: "scan.storage", qos: .utility)
    private let jpegQueue = DispatchQueue(label: "scan.jpeg", qos: .utility)
    private let corridorLogger = Logger(subsystem: "com.indoorpathfinding", category: "ARPlacement")

    private var lastCapturedSeq: Int = 0
    private var lastCapturedTransform: simd_float4x4 = matrix_identity_float4x4
    private var lastPersistedKeyframeSeq: Int = 0
    private var lastPersistedKeyframeTransform: simd_float4x4 = matrix_identity_float4x4
    private var visibleBranchNodeIds: Set<BranchMarkNodeId> = []
    /// Sprint 95: 직전 frame transform/timestamp — angular velocity 측정용.
    private var prevTransformForVelocity: simd_float4x4?
    private var prevTimestampForVelocity: TimeInterval = 0
    private var angularVelocityWindow: [Float] = []
    private static let angularVelocityWindowSize = 5
    private var fastMotionAboveSince: TimeInterval = 0
    private var fastMotionBelowSince: TimeInterval = 0
    /// 빠른걸음 enter threshold (rad/s) — 0.6 sustain 0.3s.
    private static let fastMotionEnterThreshold: Float = 0.6
    private static let fastMotionEnterSustainSec: TimeInterval = 0.3
    /// exit hysteresis — 0.4 미만 0.5s.
    private static let fastMotionExitThreshold: Float = 0.4
    private static let fastMotionExitSustainSec: TimeInterval = 0.5
    /// manifest v7 intrinsics (세션 첫 frame 에서 캡처).
    private var lastIntrinsicsFx: Float = 0
    private var lastIntrinsicsFy: Float = 0
    private var lastIntrinsicsCx: Float = 0
    private var lastIntrinsicsCy: Float = 0
    /// Sprint 49 (사용자 결정 BLOCKER 7): POI 마킹 시점에 jpeg encode 한 결과를
    /// poi_photo.image_blob 으로 저장. didCapture 시점에 background queue 에서 갱신.
    private var lastJpegBlob: Data?
    private var isJpegEncoding: Bool = false
    private let jpegContext = CIContext()

    // MARK: - Init

    init(
        context: ScanLaunchContext,
        sessionManager: ARSessionManager = ARKitSessionManager(),
        slamSink: RTABMapSLAMSink = {
            #if targetEnvironment(simulator)
            return StubRTABMapSLAMSink()
            #else
            return RTABMapBridge()
            #endif
        }(),
        serverClient: IndoorServerV1Client? = nil,
        /// ADR D7: caller가 소유하는 observer를 주입. nil이면 내부 생성.
        /// AdminFloorDetailView가 소유한 observer를 주입하면 ScanSessionView dismiss 후에도
        /// observer 상태가 유지되어 merge 버튼 disable 조건에 사용할 수 있다.
        externalChunkUploadObserver: ChunkUploadObserver? = nil,
        externalChunkUploadQueue: ChunkUploadQueue? = nil
    ) {
        let id = UUID().uuidString
        self.scanId = id
        self.context = context
        self.fileStore = ScanFileStore(scanId: id)
        self.sessionManager = sessionManager
        self.slamSink = slamSink
        // ADR D7: externalChunkUploadObserver가 주입되면 그것을 사용, 아니면 내부 생성.
        self.chunkUploadObserver = externalChunkUploadObserver ?? ChunkUploadObserver()
        // 모든 저장 프로퍼티 초기화 완료 후 self 사용 가능
        self.sessionManager.delegate = nil
        // RTABMapBridge에 statsModel 연결.
        #if !targetEnvironment(simulator)
        (slamSink as? RTABMapBridge)?.statsListener = statsModel
        #endif
        // ChunkUploadQueue 초기화. floor 화면이 queue를 소유하면 dismiss 후에도 상태가 유지된다.
        if let externalChunkUploadQueue {
            self.chunkUploadQueue = externalChunkUploadQueue
            externalChunkUploadQueue.observer = chunkUploadObserver
        } else if let serverClient {
            let queue = ChunkUploadQueue(serverClient: serverClient)
            self.chunkUploadQueue = queue
            queue.observer = chunkUploadObserver
        }
    }

    // MARK: - Session Control

    func start() throws {
        guard phase == .idle else { return }

        if let capacity = ScanFileStore.availableCapacityForImportantUsage(), capacity < 500 * 1024 * 1024 {
            throw ScanStoreError.insufficientStorage
        }

        try fileStore.createDirectories()
        visibleBranchNodeIds.removeAll()

        let database = try ScanMetadataDatabase(dbURL: fileStore.databaseURL)
        db = database
        keyframeRepo = KeyframeRepository(fileStore: fileStore, db: database)
        markRepo = MarkRepository(db: database)
        interfloorMarkRepo = InterfloorMarkRepository(db: database)

        var session = ScanSession(
            id: scanId,
            startedAt: nowMs(),
            endedAt: nil,
            deviceModel: UIDevice.current.modelIdentifier,
            appVersion: Bundle.main.shortVersion,
            state: .recording,
            keyframeCount: 0,
            notes: context.uploadNotesJSON
        )
        try database.dbQueue.write { db in try session.save(db) }

        // FrameFanout 구성 — Sprint 90 live_rtabmap 모드:
        //   - SLAMConsumer 활성 → RTABMapBridge에 raw frame 전량 push → 라이브 rtabmap.db 생성.
        //   - KeyframeConsumer가 RTABMapBridge.enqueuePendingKeyframe로 nodeID 매칭.
        //   - VideoRecorder/PoseFileWriter 제거 (서버는 rtabmap.db만 입력으로 사용 + reprocess).
        // attach 순서: SLAM → Keyframe (KeyframeConsumer는 SLAMConsumer 이후 lastNodeID 읽음)
        let fanoutInstance = FrameFanout(trackingDelegate: self)

        let slamThrottle = KeyframeCaptureThrottle()
        let keyframeThrottle = KeyframeCaptureThrottle()
        let slamConsumer = SLAMConsumer(sink: slamSink)
        slamConsumer.captureThrottle = slamThrottle  // ADR D2: rollover pause/resume 연결

        let bridgeProto: RTABMapBridgeEnqueueProtocol? = (slamSink as? RTABMapBridgeEnqueueProtocol)
        let keyframeConsumer = KeyframeConsumer(
            throttle: keyframeThrottle,
            downstream: self,
            rtabmapBridge: bridgeProto
        )

        fanoutInstance.attach(slamConsumer)
        fanoutInstance.attach(keyframeConsumer)

        fanout = fanoutInstance

        // RTABMapBridge 라이브 시작 — scanDirectory 안에 rtabmap.db 직접 생성.
        // nodeIDListener를 self로 연결 → keyframe_meta.rtabmap_node_id UPDATE 활성.
        #if !targetEnvironment(simulator)
        if let bridge = slamSink as? RTABMapBridge {
            bridge.nodeIDListener = self
            // chunked scan: chunk_0 디렉터리에 rtabmap.db를 생성한다.
            let chunk0Dir = fileStore.chunkDirectory(chunkIndex: 0)
            try FileManager.default.createDirectory(at: chunk0Dir, withIntermediateDirectories: true)
            try bridge.start(scanURL: chunk0Dir)
        }
        #else
        // Simulator: RTABMapBridge 없음 — 기존 scanDirectory 사용.
        _ = fileStore.scanDirectory
        #endif

        // ChunkRolloverScheduler 시작 (uploadQueue가 있을 때만)
        if let uploadQueue = chunkUploadQueue {
            let bridge: any ChunkRolloverScheduler.BridgeProtocol
            #if targetEnvironment(simulator)
            bridge = StubChunkRolloverBridge()
            #else
            bridge = (slamSink as? RTABMapBridge) ?? StubChunkRolloverBridge()
            #endif

            let scheduler = ChunkRolloverScheduler(
                scanSessionId: scanSessionId,
                floorId: context.floorId,
                fileStore: fileStore,
                bridge: bridge,
                throttle: CompositeChunkRolloverThrottle([slamThrottle, keyframeThrottle]),
                uploadQueue: uploadQueue,
                metadataSnapshotter: { [database, fileStore, storageQueue] chunkIndex in
                    storageQueue.sync {}
                    let snapshotURL = fileStore.scanMetadataSnapshotURL(chunkIndex: chunkIndex)
                    try database.backup(to: snapshotURL)
                },
                onChunkClosed: { [weak self] chunkIndex in
                    self?.pruneClosedChunkOverlay(chunkIndex: chunkIndex)
                }
            )
            chunkRolloverScheduler = scheduler
            try scheduler.start()
        }

        // ARSession은 ARPreviewView.makeUIView에서 attach(session:)으로 연결.

        sessionManager.delegate = fanoutInstance

        // Sprint 88 Cycle 4: anchor 이벤트 → FloorReferenceTracker 라우팅
        if let kitManager = sessionManager as? ARKitSessionManager {
            kitManager.anchorListener = self
        }

        floorTracker.sessionStarted()
        sessionManager.start()
        phase = .recording
    }

    func stop() {
        guard phase == .recording else { return }
        // Sprint 90 live_rtabmap: raw frame 공급 ON 상태였으므로 RTABMap도 일시 정지.
        #if !targetEnvironment(simulator)
        if let bridge = slamSink as? RTABMapBridge {
            bridge.pause()
        }
        #endif
        sessionManager.pause()
        sessionManager.delegate = nil
        // Sprint 88 cycle_5: session 종료 시 overlay anchor 전부 flush
        visibleBranchNodeIds.removeAll()
        markARSceneOverlay.reset()

        // ADR D1: scan stop 시 ChunkRolloverScheduler가 마지막 chunk를 flush한다.
        if let scheduler = chunkRolloverScheduler {
            phase = .finalizing
            Task { [weak self, scheduler] in
                await scheduler.stop()
                await MainActor.run {
                    guard let self, self.phase == .finalizing else { return }
                    self.chunkRolloverScheduler = nil
                    self.phase = .paused
                }
            }
            return
        }

        phase = .paused
    }

    // MARK: - Mark Actions (Sprint 13)

    /// Sprint 13: 탭으로 선택한 track을 잠근다.

    /// Sprint 13+14: 수집 중 사진 버리고 track 해제. DB write 없음.
    /// .confirming 상태에서도 즉시 .idle로 전환한다.
    /// performPOIWrite / performManualPOIWrite 완료 핸들러는 W-1 재검증으로 무시된다.
    func cancelPOI() {
        switch markMode {
        case .manualPhotoTaken, .confirming(.manual):
            // 수동 모드: photo 폐기 후 .idle.
            markMode = .idle
        case .idle:
            break
        }
    }

    // MARK: - Manual POI API (Sprint 14)

    private func latestPersistedKeyframeForMark() -> (seq: Int, transform: simd_float4x4)? {
        guard lastPersistedKeyframeSeq > 0 else {
            lastError = pendingQueueCount > 0
                ? "keyframe 저장 중입니다. 잠시 후 다시 시도하세요."
                : "아직 keyframe이 캡처되지 않았습니다."
            return nil
        }
        return (lastPersistedKeyframeSeq, lastPersistedKeyframeTransform)
    }

    private func syncVisibleMarkEdges() {
        let visibleNodes = markingState.nodes.filter { visibleBranchNodeIds.contains($0.id) }
        let visibleEdges = markingState.edges.filter {
            visibleBranchNodeIds.contains($0.from) && visibleBranchNodeIds.contains($0.to)
        }
        markARSceneOverlay.syncEdges(visibleEdges, nodes: visibleNodes)
    }

    private func pruneClosedChunkOverlay(chunkIndex: Int) {
        visibleBranchNodeIds.removeAll()
        markARSceneOverlay.reset()
        NSLog("[ScanStore] pruned AR overlay for closed/uploading chunk %d", chunkIndex)
    }

    /// Sprint 14: 수동 POI 등록 시작. 현 frame을 즉시 캡처(셔터 역할).
    /// 전제: markMode == .idle, phase == .recording, persisted keyframe 존재.
    func startManualPOI() {
        guard case .idle = markMode, phase == .recording else { return }
        guard let keyframeRef = latestPersistedKeyframeForMark() else { return }

        // 수동 POI는 bbox 없이 manual photo만. (YOLO 폐기로 bbox 추출 경로 제거)
        let photo = PendingPhoto(
            keyframeSeq: keyframeRef.seq,
            capturedAt: nowMs(),
            bboxX: nil,
            bboxY: nil,
            bboxW: nil,
            bboxH: nil,
            className: "manual",
            confidence: 0,
            imageBlob: lastJpegBlob
        )
        markMode = .manualPhotoTaken(photo: photo)
    }

    /// Sprint 14: 수동 POI 확정. 확정 시점 pose를 poi_mark에 기록.
    /// 전제: markMode == .manualPhotoTaken
    /// Sprint 88 v8: confirmTransform == keyframe → delta=(0,0,0) 명시 저장.
    /// Sprint 88 cycle_7+: floor projection 적용 (corridor/interfloor와 동일 패턴) — POI도 바닥에 깔림.
    ///   `dy_local = floorY − cameraY` 로 cycle_6 server backfill 정합 향상.
    func confirmManualPOI(label: String?) {
        guard case .manualPhotoTaken(let photo) = markMode else { return }
        markMode = .confirming(origin: .manual(photo: photo))

        let id = scanId
        let rawTransform = lastCapturedTransform
        guard let keyframeRef = latestPersistedKeyframeForMark() else {
            markMode = .manualPhotoTaken(photo: photo)
            return
        }
        let confirmSeq = keyframeRef.seq
        let dbRef = db
        let floorY: Float = floorTracker.floorY
            ?? floorTracker.handleFirstCorridorMark(cameraY: rawTransform.columns.3.y)
        let confirmTransform = FloorProjection.makeFloorProjectedTransform(
            cameraTransform: rawTransform, floorY: floorY
        )
        let keyframeTransform = keyframeRef.transform

        storageQueue.async { [weak self] in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard case .confirming = self.markMode else { return }
                self.performManualPOIWrite(
                    id: id, seq: confirmSeq,
                    transform: confirmTransform,
                    keyframeTransform: keyframeTransform,
                    label: label,
                    photo: photo, dbRef: dbRef
                )
            }
        }
    }

    /// confirmManualPOI DB write 실제 수행. MainActor에서 호출, storageQueue로 dispatch.
    @MainActor
    private func performManualPOIWrite(
        id: String, seq: Int,
        transform: simd_float4x4,
        keyframeTransform: simd_float4x4,
        label: String?,
        photo: PendingPhoto, dbRef: ScanMetadataDatabase?
    ) {
        storageQueue.async { [weak self] in
            do {
                try dbRef?.dbQueue.write { d in
                    var cols: [SIMD4<Float>] = [
                        transform.columns.0, transform.columns.1,
                        transform.columns.2, transform.columns.3
                    ]
                    let blob = Data(bytes: &cols, count: 64)
                    let tx = Double(transform.columns.3.x)
                    let ty = Double(transform.columns.3.y)
                    let tz = Double(transform.columns.3.z)
                    let nowMillis = Int64(Date().timeIntervalSince1970 * 1000)
                    // Sprint 88 cycle_7+: POI floor projection 적용 후 keyframe 대비 delta.
                    //   dy = floorY - cameraY ≈ -1.5  (server backfill 정합)
                    let dx = Double(transform.columns.3.x - keyframeTransform.columns.3.x)
                    let dy = Double(transform.columns.3.y - keyframeTransform.columns.3.y)
                    let dz = Double(transform.columns.3.z - keyframeTransform.columns.3.z)

                    // 1. poi_mark INSERT (source='manual'). Sprint 65: track_id 컬럼 제거됨.
                    var mark = PoiMark(
                        id: nil,
                        scanId: id,
                        keyframeSeq: seq,
                        createdAt: nowMillis,
                        poseMatrix: blob,
                        tx: tx,
                        ty: ty,
                        tz: tz,
                        label: label,
                        source: PoiMark.Source.manual.rawValue,
                        dxLocal: dx,
                        dyLocal: dy,
                        dzLocal: dz
                    )
                    try mark.save(d)
                    let poiMarkId = d.lastInsertedRowID

                    // 2. poi_photo INSERT 1장 (Sprint 65 v6: bbox_* 컬럼 폐기).
                    let photoArgs: StatementArguments = [
                        poiMarkId, id, photo.keyframeSeq, photo.capturedAt,
                        photo.className, photo.confidence, photo.imageBlob
                    ]
                    try d.execute(
                        sql: """
                        INSERT INTO poi_photo
                            (poi_mark_id, scan_id, keyframe_seq, captured_at,
                             class_name, confidence, image_blob)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                        arguments: photoArgs
                    )
                }

                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard case .confirming = self.markMode else { return }
                    self.poiMarkCount += 1
                    // Sprint 88 cycle_5+: POI도 SCN sphere로 visible (엣지 자동 연결 없음)
                    let poiVisualId = UUID()
                    let poiLabel = (label?.isEmpty == false ? label! : "POI \(self.poiMarkCount)")
                    self.markARSceneOverlay.addStandaloneMark(
                        id: poiVisualId,
                        kind: .poi,
                        label: poiLabel,
                        transform: transform
                    )
                    self.markMode = .idle
                }
            } catch {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard case .confirming = self.markMode else { return }
                    self.lastError = "수동 POI 저장 실패: \(error.localizedDescription)"
                    // 실패 시 manualPhotoTaken 상태로 복원 (재시도 가능)
                    self.markMode = .manualPhotoTaken(photo: photo)
                }
            }
        }
    }

    // MARK: - Legacy Mark Actions

    /// - Warning: Sprint 13에서 deprecated. ADR 0002로 Track Lock 폐기 후 manual POI 흐름만 사용.
    /// 호환을 위해 legacy entry는 유지하되 trackId 없이 단순 POI 1건 생성으로 단순화.
    @available(*, deprecated, message: "Use startManualPOI() + confirmManualPOI(label:) instead")
    func markPOI() {
        guard phase == .recording else { return }
        guard let keyframeRef = latestPersistedKeyframeForMark() else { return }
        let seq = keyframeRef.seq
        let transform = lastCapturedTransform
        let id = scanId
        let repo = markRepo

        storageQueue.async { [weak self] in
            guard let self else { return }
            do {
                try repo?.insertPOI(
                    scanId: id,
                    keyframeSeq: seq,
                    transform: transform,
                    keyframeTransform: keyframeRef.transform
                )
                Task { @MainActor in
                    guard self.phase == .recording else { return }
                    self.poiMarkCount += 1
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.lastError = "POI 저장 실패: \(error.localizedDescription)"
                }
            }
        }
    }

    func markBranch() {
        guard phase == .recording else {
            lastError = "스캔 중에만 노드를 저장할 수 있습니다."
            return
        }
        guard let keyframeRef = latestPersistedKeyframeForMark() else { return }
        let seq = keyframeRef.seq
        let transform = lastCapturedTransform
        let id = scanId
        let repo = markRepo
        storageQueue.async { [weak self] in
            guard let self else { return }
            do {
                try repo?.insertBranch(
                    scanId: id, keyframeSeq: seq,
                    transform: transform, keyframeTransform: keyframeRef.transform
                )
                Task { @MainActor in
                    guard self.phase == .recording else { return }
                    self.branchMarkCount += 1
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.lastError = "노드 저장 실패: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Sprint 88 Cycle 2: Corridor / Corner Marking

    /// corridor 노드 마킹. 현재 pose를 floor에 projection하여 등록하고 MarkingState 전이 룰 실행.
    ///
    /// ## Sprint 88 Cycle 4 — H5 fix:
    ///   카메라 transform의 y(= 사람 키 높이 ~1.5m)를 그대로 쓰던 기존 로직을 제거.
    ///   floorReferenceY로 수직 projection한 위치를 DB와 MarkingState에 모두 저장.
    func markCorridor(widthM: Double? = nil, connectNodeId: BranchMarkNodeId? = nil) {
        guard phase == .recording else {
            lastError = "스캔 중에만 노드를 저장할 수 있습니다."
            return
        }
        guard trackingStateLabel == "normal" else {
            lastError = "트래킹 상태가 정상일 때만 노드를 저장할 수 있습니다."
            return
        }
        guard let keyframeRef = latestPersistedKeyframeForMark() else { return }

        let seq = keyframeRef.seq
        let rawTransform = lastCapturedTransform

        // H5 fix: floor reference y 결정 (없으면 heuristic으로 즉시 lock)
        let floorY: Float = floorTracker.floorY
            ?? floorTracker.handleFirstCorridorMark(cameraY: rawTransform.columns.3.y)

        // camera xz → floor y projection
        let projectedTransform = FloorProjection.makeFloorProjectedTransform(
            cameraTransform: rawTransform,
            floorY: floorY
        )

        corridorLogger.debug(
            "CORRIDOR_DEBUG cameraY=\(rawTransform.columns.3.y, format: .fixed(precision: 3)) projectedY=\(floorY, format: .fixed(precision: 3)) delta=\(rawTransform.columns.3.y - floorY, format: .fixed(precision: 3)) world=(\(projectedTransform.columns.3.x, format: .fixed(precision: 3)),\(floorY, format: .fixed(precision: 3)),\(projectedTransform.columns.3.z, format: .fixed(precision: 3)))"
        )

        let id = scanId
        let repo = markRepo
        let effectiveWidth = widthM ?? markingState.lastCorridorWidthM

        // connect hint 결정
        let hint: BranchMark.ConnectHintValue? = markingState.connectMode == .proximityArmed ? .proximity : nil
        let connectTargetId: String? = connectNodeId.map { String($0) }

        storageQueue.async { [weak self] in
            guard let self else { return }
            do {
                let rowId = try repo?.insertBranch(
                    scanId: id,
                    keyframeSeq: seq,
                    transform: projectedTransform,      // floor-projected transform
                    keyframeTransform: keyframeRef.transform, // v8: persisted keyframe 기준 delta 계산
                    nodeType: .corridor,
                    widthM: effectiveWidth,
                    connectHint: hint,
                    connectNodeId: connectTargetId,
                    markSessionId: nil
                ) ?? 0

                // position.y = floorY (floor-projected)
                let position = SIMD3<Float>(
                    projectedTransform.columns.3.x,
                    projectedTransform.columns.3.y,
                    projectedTransform.columns.3.z
                )

                Task { @MainActor [weak self] in
                    guard let self, self.phase == .recording else { return }
                    self.markingState.addCorridor(
                        nodeId: rowId,
                        at: position,
                        widthM: effectiveWidth,
                        connectHint: hint != nil ? .proximity : nil,
                        connectNodeId: connectNodeId
                    )
                    self.branchMarkCount += 1
                    self.showMicroToast("노드 #\(self.markingState.nodes.count) 등록됨")
                    self.visibleBranchNodeIds.insert(rowId)

                    // Sprint 88 cycle_5: SCNNode anchor 등록
                    let order = self.markingState.nodes.count
                    self.markARSceneOverlay.addMark(
                        nodeId: rowId,
                        nodeType: .corridor,
                        order: order,
                        transform: projectedTransform
                    )
                    self.syncVisibleMarkEdges()
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.lastError = "노드 저장 실패: \(error.localizedDescription)"
                }
            }
        }
    }

    /// 화면 좌표 → ARRaycastHelper(horizontal 우선) → world transform → corner 마킹.
    ///
    /// ## Sprint 88 Cycle 4 — H6 fix:
    ///   floorY를 ARRaycastHelper에 전달해 horizontal raycast + floor clamp를 수행한다.
    ///   raycast가 모두 실패하면 "코너 인식 실패 — floor 보정 안 됨" toast.
    func markCornerAtScreenPoint(_ screenPoint: CGPoint) {
        let floorY = floorTracker.floorY

        // Sprint 88 cycle_4 H10: viewport-aware ARSCNView raycast 우선.
        // sceneViewRef가 nil이면 (테스트 등) 레거시 ARSession 경로로 fallback.
        let raycastInvocation: (@escaping @MainActor (simd_float4x4?) -> Void) -> Void
        if let view = sceneViewRef {
            raycastInvocation = { completion in
                ARRaycastHelper.raycast(from: screenPoint, in: view, floorY: floorY, completion: completion)
            }
        } else if let arSession = sessionManager.arSession {
            raycastInvocation = { completion in
                ARRaycastHelper.raycast(from: screenPoint, in: arSession, floorY: floorY, completion: completion)
            }
        } else {
            if !rawCornerTapDebugMode {
                lastError = "ARSession이 없습니다."
            }
            return
        }

        if rawCornerTapDebugMode {
            debugRawCornerTaps.append(screenPoint)
            if debugRawCornerTaps.count > 32 {
                debugRawCornerTaps.removeFirst(debugRawCornerTaps.count - 32)
            }
            // raycast도 동시에 — DB/MarkingState 등록 X.
            // raycast 성공 시 ARAnchor 추가 → ARKit 자체 stabilize.
            // SIMD3 fallback도 같이 저장 (anchor 미발견 시 사용).
            raycastInvocation { [weak self] transform in
                guard let self, let t = transform else { return }
                let world = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
                self.debugRaycastWorldPoints.append(world)
                if self.debugRaycastWorldPoints.count > 32 {
                    self.debugRaycastWorldPoints.removeFirst(self.debugRaycastWorldPoints.count - 32)
                }
                if let session = self.sceneViewRef?.session ?? self.sessionManager.arSession {
                    let anchor = ARAnchor(transform: t)
                    session.add(anchor: anchor)
                    self.debugRaycastAnchorIds.append(anchor.identifier)
                    if self.debugRaycastAnchorIds.count > 32 {
                        self.debugRaycastAnchorIds.removeFirst(self.debugRaycastAnchorIds.count - 32)
                    }
                }
            }
            return
        }

        // Sprint 88 v8: raycast 시작 시점의 persisted keyframe을 closure에 capture.
        // branch_mark FK가 keyframe_meta에 없는 seq를 참조하지 않게 한다.
        guard let keyframeRefAtRaycastStart = latestPersistedKeyframeForMark() else { return }

        raycastInvocation { [weak self] transform in
            guard let self else { return }
            if let t = transform {
                // Sprint 88 cycle_7: close 우선 시도
                let hitPos = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
                let closeResult = self.markingState.tryCloseCornerPolygon(
                    at: hitPos, thresholdM: 0.30
                )
                switch closeResult {
                case .closed(let nodeCount, _):
                    // closing edge가 markingState.edges에 추가됨 → SCN overlay sync.
                    // tryCloseCornerPolygon 내부에서 closedCornerSessionIds.insert(sessionId) 완료 후
                    // activeCornerSessionId = nil 로 설정된다.
                    // 즉시 cornerSessionDidStart() 로 새 session 발급 — activeCornerSessionId 가
                    // nil 인 구간이 raycast completion handler 내부에서만 발생하므로 UI race 없음.
                    // (Sprint 89 v9: closedCornerSessionIds 는 finalize() 까지 MarkingState 에 보존됨)
                    self.syncVisibleMarkEdges()
                    self.showMicroToast("코너 폴리곤 닫힘 (\(nodeCount)개)")
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    // 다음 polygon을 위해 새 session id 발급 (toolMode .corner 유지)
                    self.cornerSessionDidStart()
                case .notInCornerMode, .noCornerYet, .needAtLeastTwoCorners, .tooFar:
                    // 일반 corner 마킹 경로 (기존)
                    self.markCorner(at: t,
                                    keyframeSeq: keyframeRefAtRaycastStart.seq,
                                    keyframeAtRaycast: keyframeRefAtRaycastStart.transform)
                }
            } else {
                self.lastError = "코너 인식 실패 — floor 보정 안 됨"
            }
        }
    }

    /// Sprint 88 cycle_5: ScanSessionView의 onMakeView 콜백에서 호출.
    /// MarkARSceneOverlay에 sceneView + session을 연결하고 sceneViewRef도 동시에 저장.
    func setSceneView(_ view: ARSCNView) {
        sceneViewRef = view
        if let session = sessionManager.arSession {
            markARSceneOverlay.attach(sceneView: view, session: session)
        }
    }

    func clearDebugRawCornerTaps() {
        // 디버그 anchor도 session에서 제거
        if let session = sceneViewRef?.session ?? sessionManager.arSession {
            for id in debugRaycastAnchorIds {
                if let anchor = session.currentFrame?.anchors.first(where: { $0.identifier == id }) {
                    session.remove(anchor: anchor)
                }
            }
        }
        debugRawCornerTaps.removeAll()
        debugRaycastWorldPoints.removeAll()
        debugRaycastAnchorIds.removeAll()
    }

    /// corner 노드 마킹. ARRaycast 결과 world transform으로 등록.
    /// Sprint 88 v8: keyframeSeq/keyframeAtRaycast 추가 — raycast 시작 시점 keyframe 기준으로
    /// delta를 계산해 reprocess 후 정확한 raycast hit을 복원한다. (§9.5 race 처리)
    func markCorner(at worldTransform: simd_float4x4,
                    keyframeSeq overrideSeq: Int? = nil,
                    keyframeAtRaycast: simd_float4x4? = nil) {
        guard phase == .recording else {
            lastError = "스캔 중에만 코너를 저장할 수 있습니다."
            return
        }
        guard markingState.activeCornerSessionId != nil else {
            lastError = "코너 세션이 시작되지 않았습니다. 코너 모드로 전환해주세요."
            return
        }

        // race 처리: overrideSeq/keyframeAtRaycast가 없으면 현재 값으로 폴백
        let fallbackKeyframeRef = latestPersistedKeyframeForMark()
        let seq = overrideSeq ?? fallbackKeyframeRef?.seq
        let keyframeT = keyframeAtRaycast ?? fallbackKeyframeRef?.transform
        guard let seq, let keyframeT else { return }
        let id = scanId
        let repo = markRepo
        let sessionId = markingState.activeCornerSessionId

        storageQueue.async { [weak self] in
            guard let self else { return }
            do {
                let rowId = try repo?.insertBranch(
                    scanId: id,
                    keyframeSeq: seq,
                    transform: worldTransform,
                    keyframeTransform: keyframeT,       // v8: raycast 시작 시점 keyframe
                    nodeType: .corner,
                    widthM: nil,
                    connectHint: nil,
                    connectNodeId: nil,
                    markSessionId: sessionId?.uuidString
                ) ?? 0

                let position = SIMD3<Float>(
                    worldTransform.columns.3.x,
                    worldTransform.columns.3.y,
                    worldTransform.columns.3.z
                )

                Task { @MainActor [weak self] in
                    guard let self, self.phase == .recording else { return }
                    self.markingState.addCorner(nodeId: rowId, at: position)
                    self.branchMarkCount += 1
                    self.showMicroToast("코너 #\(self.markingState.nodes.count) 등록됨")
                    self.visibleBranchNodeIds.insert(rowId)

                    // Sprint 88 cycle_5: SCNNode anchor 등록
                    let order = self.markingState.nodes.count
                    self.markARSceneOverlay.addMark(
                        nodeId: rowId,
                        nodeType: .corner,
                        order: order,
                        transform: worldTransform
                    )
                    self.syncVisibleMarkEdges()
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.lastError = "코너 저장 실패: \(error.localizedDescription)"
                }
            }
        }
    }

    /// 끊기 버튼 — 다음 corridor 마킹 시 proximity 모드로 연결.
    func enableProximityOnce() {
        markingState.armProximity()
    }

    /// proximity 대상 노드 선택 완료.
    func selectProximityTarget(_ nodeId: BranchMarkNodeId) {
        markingState.selectProximityTarget(nodeId)
    }

    /// proximity 모드 취소 — sequential로 복귀 (Medium-B sheet 닫기).
    func clearProximityMode() {
        markingState.resetToSequential()
    }

    /// 코너 세션 시작 (코너 모드 진입).
    func cornerSessionDidStart() {
        markingState.startCornerSession()
    }

    /// 코너 세션 종료 (모드 전환).
    func cornerSessionDidEnd() {
        markingState.closeCornerSession()
    }

    /// 다중 undo. count개 노드 + 연결 edge cascade 제거.
    func undo(count: Int = 1) {
        guard count > 0 else { return }
        // undo할 노드 ID들 수집
        var toDelete: [BranchMarkNodeId] = []
        var tempStack = markingState.undoStack
        for _ in 0..<min(count, tempStack.count) {
            if let action = tempStack.popLast(), case .addNode(let nid) = action {
                toDelete.append(nid)
            }
        }

        markingState.undoLast(count: count)
        branchMarkCount = max(0, branchMarkCount - toDelete.count)

        // Sprint 88 cycle_5: SCNNode anchor 제거
        for nid in toDelete {
            visibleBranchNodeIds.remove(nid)
            markARSceneOverlay.removeMark(nodeId: nid)
        }
        syncVisibleMarkEdges()

        // DB에서도 삭제
        let repo = markRepo
        let ids = toDelete
        storageQueue.async {
            ids.forEach { nid in
                try? repo?.deleteBranch(id: nid)
            }
        }

        showMicroToast("실행 취소됨 (\(toDelete.count)개)")
    }

    /// overlay tap 삭제.
    func deleteBranchNode(_ nodeId: BranchMarkNodeId) {
        markingState.deleteNode(nodeId)
        branchMarkCount = max(0, branchMarkCount - 1)

        // Sprint 88 cycle_5: SCNNode anchor 제거
        visibleBranchNodeIds.remove(nodeId)
        markARSceneOverlay.removeMark(nodeId: nodeId)
        syncVisibleMarkEdges()

        let repo = markRepo
        storageQueue.async {
            try? repo?.deleteBranch(id: nodeId)
        }
    }

    /// 수정 sheet 열기 요청.
    func beginEdit(nodeId: BranchMarkNodeId) {
        editingNodeId = nodeId
    }

    /// 수정 sheet 닫기.
    func endEdit() {
        editingNodeId = nil
    }

    /// 노드 수정 저장.
    func commitEdit(nodeId: BranchMarkNodeId, nodeType: NodeType, widthM: Double?) {
        markingState.updateNode(nodeId, nodeType: nodeType, widthM: widthM)
        editingNodeId = nil

        let repo = markRepo
        storageQueue.async {
            try? repo?.updateBranch(
                id: nodeId,
                nodeType: nodeType == .corridor ? .corridor : .corner,
                widthM: widthM
            )
        }
    }

    /// proximity 후보 반환.
    func proximityCandidates(radiusM: Float = 3.0) -> [BranchMarkNode] {
        let pos = SIMD3<Float>(
            lastCapturedTransform.columns.3.x,
            lastCapturedTransform.columns.3.y,
            lastCapturedTransform.columns.3.z
        )
        return markingState.proximityCandidates(for: pos, radiusM: radiusM)
    }

    /// 종료 점검 sheet 용 checklist.
    var finalizeChecklistResult: FinalizeChecklistResult {
        markingState.finalizeChecklist()
    }

    /// hint banner 닫기.
    func clearHintBanner() {
        hintBannerCase = nil
    }

    /// 도구 모드 전환.
    func setTool(_ mode: ScanToolMode) {
        if activeTool == .corner, mode != .corner {
            cornerSessionDidEnd()
        }
        if mode == .corner {
            cornerSessionDidStart()
        }
        activeTool = mode
    }

    /// corridor 폭 선택기 변경 시 MarkingState 동기화.
    func setCorridorWidth(_ widthM: Double) {
        markingState.setLastCorridorWidth(widthM)
    }

    // MARK: - Micro Toast

    private func showMicroToast(_ text: String) {
        microToastMessage = text
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if self?.microToastMessage == text {
                self?.microToastMessage = nil
            }
        }
    }

    /// Sprint 88 cycle_7: ZIP 저장 완료 toast.
    /// ScanSessionView의 handlePhaseChange(.paused) 내부에서 호출.
    func showZipExportToast(path: String) {
        showMicroToast("ZIP 저장: \(path)")
    }

    func markInterfloorConnector(type: InterfloorConnectorType, prefix: String) {
        guard phase == .recording else {
            lastError = "스캔 중에만 층간 연결 노드를 저장할 수 있습니다."
            return
        }
        guard let keyframeRef = latestPersistedKeyframeForMark() else { return }
        let normalized = prefix.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let connectorPrefix = normalized.isEmpty ? "\(type.prefixSeed)-A" : normalized

        // Sprint 88 cycle_7: floor projection 적용 (corridor와 동일 패턴)
        let rawTransform = lastCapturedTransform
        let capturedSeq = keyframeRef.seq
        let floorY: Float = floorTracker.floorY
            ?? floorTracker.handleFirstCorridorMark(cameraY: rawTransform.columns.3.y)
        let projectedTransform = FloorProjection.makeFloorProjectedTransform(
            cameraTransform: rawTransform, floorY: floorY
        )

        let mark = InterfloorMark(
            type: type,
            prefix: connectorPrefix,
            keyframeSeq: capturedSeq,
            tx: Double(projectedTransform.columns.3.x),
            ty: Double(projectedTransform.columns.3.y),
            tz: Double(projectedTransform.columns.3.z)
        )
        // Sprint 88 v8: InterfloorMarkRepository로 dx_local/dy_local/dz_local 포함 저장.
        // cycle_7: projectedTransform(floor) + keyframeTransform=rawTransform(camera)
        //          → dyLocal = floorY − cameraY ≈ −1.5 로 자동 채워짐 (v8 server backfill 정합 ↑)
        let id = scanId
        let iRepo = interfloorMarkRepo
        let bRepo = markRepo
        let seq = capturedSeq
        let connType = type.rawValue
        storageQueue.async { [weak self] in
            guard let self else { return }
            do {
                try iRepo?.insert(
                    scanId: id,
                    keyframeSeq: seq,
                    connectorType: connType,
                    prefix: connectorPrefix,
                    transform: projectedTransform,
                    keyframeTransform: keyframeRef.transform
                )
                // branch_mark에도 같은 위치로 기록 (기존 동작 유지 — markBranch() 대체)
                try bRepo?.insertBranch(
                    scanId: id, keyframeSeq: seq,
                    transform: projectedTransform, keyframeTransform: keyframeRef.transform
                )
                Task { @MainActor in
                    guard self.phase == .recording else { return }
                    self.interfloorMarks.append(mark)
                    // Sprint 88 cycle_7: 색 분기 — overlayMarkerKind로 4-case 전달
                    self.markARSceneOverlay.addStandaloneMark(
                        id: mark.id,
                        kind: type.overlayMarkerKind,
                        label: connectorPrefix,
                        transform: projectedTransform
                    )
                    self.branchMarkCount += 1
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.lastError = "층간 연결 노드 저장 실패: \(error.localizedDescription)"
                }
            }
        }
    }

    func clearLastError() {
        lastError = nil
    }

    // MARK: - Finalize

    func finalize() throws {
        guard phase == .paused else { return }
        phase = .finalizing

        // Sprint 90 live_rtabmap: RTABMapBridge.finalize → 실제 rtabmap.db 저장.
        // 서버는 이 db를 입력으로 받아 reprocess (mp4/poses 없음).
        // Sprint 92 fix: nodeStamps를 받아 backfillFromGraph 호출 — keyframe_meta.rtabmap_node_id 채움.
        // (streaming nodeIDListener path가 라이브 모드에서 timestamp/타이밍 이슈로 0건 매칭됨)
        #if !targetEnvironment(simulator)
        if let bridge = slamSink as? RTABMapBridge {
            do {
                let (dbURL, nodeStamps) = try bridge.finalize(scanURL: fileStore.scanDirectory)
                NSLog("[ScanStore] live rtabmap.db saved: %@ nodeStamps=%d",
                      dbURL.lastPathComponent, nodeStamps.count)
                backfillFromGraph(nodeStamps: nodeStamps)
            } catch {
                NSLog("[ScanStore] RTABMap finalize failed: %@", error.localizedDescription)
                // fail-open: rtabmap.db 없어도 manifest는 작성. 서버가 reject하면 사용자가 인지
            }
        }
        #endif

        // MARK: branch_edge persist (Sprint 89 v9)
        // markingState.edges 전체를 branch_edge 테이블에 INSERT.
        // fail-open: 실패해도 finalize 계속 진행 (server 가 기존 keyframe sequence 룰로 fallback).
        if let db {
            do {
                let edgeRepo = BranchEdgeRepository(db: db)
                try edgeRepo.insertAll(
                    scanId: scanId,
                    edges: markingState.edges,
                    nodes: markingState.nodes,
                    closedSessions: markingState.closedCornerSessionIds
                )
                NSLog("[ScanStore] branch_edge persisted: %d rows", markingState.edges.count)
            } catch {
                NSLog("[ScanStore] branch_edge persist failed: %@", error.localizedDescription)
            }
        }

        // Sprint 90 live_rtabmap: VideoRecorder/PoseFileWriter 제거됨 — 마감 작업 없음.

        let endedAt = nowMs()
        let finalCount = keyframeCount

        try db?.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE scan_session SET state = 'saved', ended_at = ?, keyframe_count = ? WHERE id = ?",
                arguments: [endedAt, finalCount, scanId]
            )
        }

        // Sprint 90: manifest mode=live_rtabmap. videoPath/posesPath null.
        // 서버는 rtabmap.db를 입력으로 reprocess.
        let manifest = ManifestWriter.makeLiveRtabmap(
            scanId: scanId,
            sidecarKeyframeMetaCount: finalCount,
            intrinsicsFx: lastIntrinsicsFx,
            intrinsicsFy: lastIntrinsicsFy,
            intrinsicsCx: lastIntrinsicsCx,
            intrinsicsCy: lastIntrinsicsCy,
            clientAppVersion: Bundle.main.shortVersion
        )
        do {
            _ = try ManifestWriter.write(scanDirectory: fileStore.scanDirectory, manifest: manifest)
        } catch {
            NSLog("[ScanStore] manifest.json write failed: %@", error.localizedDescription)
        }

        let capturedSelf = self
        Task.detached(priority: .utility) {
            let size = capturedSelf.computeDbSize()
            await MainActor.run { capturedSelf.dbSizeBytes = size }
        }

        phase = .saved
    }

    func discard() {
        phase = .discarded
        storageQueue.async { [fileStore] in
            try? fileStore.deleteAll()
        }
    }

    // MARK: - Sprint 8: Optimized Pose 동기화

    /// loop closure 발생 후 RTABMap이 최적화한 pose를 keyframe_meta에 일괄 UPDATE.
    func applyOptimizedPoses(_ poses: [Int: simd_float4x4]) {
        let id = scanId
        let db = db
        storageQueue.async {
            try? db?.dbQueue.write { db in
                for (nodeID, matrix) in poses {
                    // column-major simd_float4x4 → 64바이트 blob
                    var cols = [matrix.columns.0, matrix.columns.1,
                                matrix.columns.2, matrix.columns.3]
                    let blob = Data(bytes: &cols, count: 64)
                    let tx = Double(matrix.columns.3.x)
                    let ty = Double(matrix.columns.3.y)
                    let tz = Double(matrix.columns.3.z)
                    try db.execute(
                        sql: """
                        UPDATE keyframe_meta
                        SET pose_matrix = ?, tx = ?, ty = ?, tz = ?
                        WHERE scan_id = ? AND rtabmap_node_id = ?
                        """,
                        arguments: [blob, tx, ty, tz, id, nodeID]
                    )
                }
            }
        }
    }

    // MARK: - SLAM Node ID 기록

    private func handleNodeIDAssigned(seq: Int, nodeID: RTABMapNodeID?) {
        guard let nodeID else { return }
        let id = scanId
        let db = db
        storageQueue.async {
            try? db?.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE keyframe_meta SET rtabmap_node_id = ? WHERE scan_id = ? AND seq = ?",
                    arguments: [nodeID, id, seq]
                )
            }
        }
    }

    // MARK: - Sprint 35 v4: finalize 시점 backfill

    /// RTAB-Map 전체 그래프의 (nodeId, stamp) 배열을 받아
    /// keyframe_meta에서 rtabmap_node_id가 NULL인 행을 greedy 1:1 매칭으로 채운다.
    /// - streaming path(nodeIDAssigned)로 이미 set된 행은 건드리지 않는다.
    /// - abs(capturedAt - stamp) 가장 작은 keyframe을 nodeId 하나당 1개만 매칭.
    /// - threshold: 1.0초 이내만 매칭 허용.
    func backfillNodeIDsFromGraph(_ nodeStamps: [(nodeId: Int, stamp: Double)]) {
        let id = scanId
        let db = db
        // Sprint 92: storageQueue.sync — finalize → zip 생성 전에 UPDATE 완료 보장.
        // backfill은 read 1 + write 1 light op이라 main thread block 허용.
        storageQueue.sync {
            do {
                // 1. NULL 행 전체 읽기
                let unset: [(seq: Int, capturedAt: Double)] = try db?.dbQueue.read { d in
                    // captured_at은 밀리초(Int64) → 초로 변환
                    try Row.fetchAll(
                        d,
                        sql: """
                        SELECT seq, captured_at FROM keyframe_meta
                        WHERE scan_id = ? AND rtabmap_node_id IS NULL
                        ORDER BY seq
                        """,
                        arguments: [id]
                    ).map { row in
                        let seq: Int = row["seq"]
                        let capturedAtMs: Int64 = row["captured_at"]
                        return (seq: seq, capturedAt: Double(capturedAtMs) / 1000.0)
                    }
                } ?? []

                guard !unset.isEmpty else {
                    NSLog("[NodeIDBackfill] no NULL rows — backfill skipped")
                    return
                }
                NSLog("[NodeIDBackfill] NULL rows=%d nodeStamps=%d", unset.count, nodeStamps.count)

                // 2. greedy 1:1 매칭 (nodeId 하나 → keyframe seq 하나)
                //    threshold: 1.0초
                let threshold: Double = 1.0
                var usedSeqs = Set<Int>()
                var matched = 0
                var skipped = 0

                // nodeStamps를 stamp 오름차순으로 정렬해 순서대로 매칭
                let sorted = nodeStamps.sorted { $0.stamp < $1.stamp }

                var updates: [(nodeId: Int, seq: Int)] = []
                for ns in sorted {
                    // 아직 매칭되지 않은 행 중 stamp에 가장 가까운 것
                    guard let best = unset.filter({ !usedSeqs.contains($0.seq) })
                                         .min(by: { abs($0.capturedAt - ns.stamp) < abs($1.capturedAt - ns.stamp) })
                    else { continue }

                    let diff = abs(best.capturedAt - ns.stamp)
                    if diff < threshold {
                        usedSeqs.insert(best.seq)
                        updates.append((nodeId: ns.nodeId, seq: best.seq))
                        matched += 1
                        NSLog("[NodeIDBackfill] match nodeId=%d seq=%d diff=%.1fms",
                              ns.nodeId, best.seq, diff * 1000)
                    } else {
                        skipped += 1
                        NSLog("[NodeIDBackfill] skip nodeId=%d stamp=%.3f closest_seq=%d diff=%.1fms (> %.0fms)",
                              ns.nodeId, ns.stamp, best.seq, diff * 1000, threshold * 1000)
                    }
                }

                // 3. 일괄 UPDATE
                if !updates.isEmpty {
                    try db?.dbQueue.write { d in
                        for u in updates {
                            try d.execute(
                                sql: "UPDATE keyframe_meta SET rtabmap_node_id = ? WHERE scan_id = ? AND seq = ?",
                                arguments: [u.nodeId, id, u.seq]
                            )
                        }
                    }
                }

                let unsetAfter = (unset.count) - matched
                NSLog("[NodeIDBackfill] matched=%d skipped=%d unset=%d", matched, skipped, unsetAfter)
            } catch {
                NSLog("[NodeIDBackfill] error: %@", error.localizedDescription)
            }
        }
    }

    // MARK: - dbSize 계산

    nonisolated func computeDbSize() -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0

        if let attrs = try? fm.attributesOfItem(atPath: fileStore.databaseURL.path),
           let size = attrs[.size] as? Int64 {
            total += size
        }

        let keyframesDir = fileStore.keyframesDirectory
        guard let enumerator = fm.enumerator(
            at: keyframesDir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return total }

        for case let fileURL as URL in enumerator {
            guard let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }

    // MARK: - Private

    private func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}

// MARK: - PoseConsumerProtocol

extension ScanStore: PoseConsumerProtocol {}

// MARK: - ARSessionAnchorListener (Sprint 88 Cycle 4)

extension ScanStore: ARSessionAnchorListener {
    func sessionManager(_ manager: ARSessionManager, didAddAnchor anchor: ARAnchor, cameraY: Float) {
        floorTracker.handleAnchorAdded(anchor, cameraY: cameraY)
    }
}

// MARK: - NodeIDListenerProtocol (Sprint 35 Task 1 v4)

extension ScanStore: NodeIDListenerProtocol {
    /// RTABMapBridge streaming timestamp 매칭 완료 후 비동기로 호출된다.
    /// handleNodeIDAssigned를 통해 keyframe_meta.rtabmap_node_id를 UPDATE한다.
    func nodeIDAssigned(seq: Int, nodeID: Int) {
        handleNodeIDAssigned(seq: seq, nodeID: nodeID)
    }

    /// Sprint 35 v4: finalize 시점 RTABMapBridge가 전체 그래프를 꺼내 ScanStore로 전달.
    /// backfillNodeIDsFromGraph를 위임한다.
    func backfillFromGraph(nodeStamps: [(nodeId: Int, stamp: Double)]) {
        backfillNodeIDsFromGraph(nodeStamps)
    }
}

// MARK: - ARSessionManagerDelegate (downstream of KeyframeConsumer)

extension ScanStore: ARSessionManagerDelegate {
    func sessionManager(_ manager: ARSessionManager, didCapture sample: KeyframeSample) {
        guard phase == .recording else { return }

        // Sprint 95: angular velocity 측정 (빠른걸음 경고).
        // 이전 transform/timestamp 가 있고 dt>0 이면 quaternion delta 로 rad/s 계산.
        if let prev = prevTransformForVelocity {
            let dt = sample.arFrameTimestamp - prevTimestampForVelocity
            if dt > 0.001 {  // 너무 작은 dt 노이즈 방지
                let q1 = simd_quatf(prev)
                let q2 = simd_quatf(sample.transform)
                // q2 = qDelta * q1  →  qDelta = q2 * q1.inverse
                let qDelta = q2 * q1.inverse
                // simd_quatf.angle 은 [0, 2π]. π 넘으면 wrap-around → min(angle, 2π-angle).
                var angle = abs(qDelta.angle)
                if angle > .pi { angle = 2 * .pi - angle }
                let omega = Float(angle) / Float(dt)
                angularVelocityWindow.append(omega)
                if angularVelocityWindow.count > Self.angularVelocityWindowSize {
                    angularVelocityWindow.removeFirst()
                }
                let smoothed = angularVelocityWindow.reduce(0, +) / Float(angularVelocityWindow.count)
                angularVelocityRadPerSec = smoothed
                updateFastMotionState(omega: smoothed, now: sample.arFrameTimestamp)
            }
        }
        prevTransformForVelocity = sample.transform
        prevTimestampForVelocity = sample.arFrameTimestamp

        lastCapturedSeq += 1
        lastCapturedTransform = sample.transform

        // Sprint 88 Cycle 2: 카메라 heading 업데이트 (XZ 평면 forward vector)
        let forward = -sample.transform.columns.2  // -Z = forward in ARKit
        lastCameraHeading = SIMD3<Float>(forward.x, 0, forward.z)

        // 백트래킹 감지 (hintBanner용, 마킹 없을 때만)
        let currentPos = SIMD3<Float>(
            sample.transform.columns.3.x,
            sample.transform.columns.3.y,
            sample.transform.columns.3.z
        )
        if markingState.detectBacktracking(currentPosition: currentPos, heading: lastCameraHeading) {
            // backtracking 힌트 발행 — markingState에 직접 변이 없이 외부 노출만
            if hintBannerCase == nil {
                hintBannerCase = .backtracking
            }
        }
        // 첫 frame 에서 intrinsics 고정.
        if lastIntrinsicsFx == 0 {
            lastIntrinsicsFx = sample.intrinsicsFx
            lastIntrinsicsFy = sample.intrinsicsFy
            lastIntrinsicsCx = sample.intrinsicsCx
            lastIntrinsicsCy = sample.intrinsicsCy
        }
        currentTranslation = sample.translation
        coveragePoints.append(CGPoint(x: CGFloat(sample.translation.x), y: CGFloat(sample.translation.z)))
        if coveragePoints.count > 500 {
            coveragePoints.removeFirst(coveragePoints.count - 500)
        }
        let seq = lastCapturedSeq
        pendingQueueCount += 1

        // Sprint 65: 3D overlay 폐기. featurePoints는 coveragePoints만 갱신.
        _ = seq // (no overlay store anymore)

        // Sprint 49 (BLOCKER 7): jpeg encode 후 lastJpegBlob 업데이트.
        // POI 마킹 시 poi_photo.image_blob 에 저장. 비동기로 background 처리.
        if !isJpegEncoding {
            isJpegEncoding = true
            let pixelBuffer = sample.pixelBuffer
            let context = jpegContext
            jpegQueue.async { [weak self] in
                let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
                let jpeg = context.jpegRepresentation(
                    of: ciImage,
                    colorSpace: CGColorSpaceCreateDeviceRGB(),
                    options: [
                        kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.7
                    ]
                )
                Task { @MainActor in
                    if let jpeg {
                        self?.lastJpegBlob = jpeg
                    }
                    self?.isJpegEncoding = false
                }
            }
        }

        guard let repo = keyframeRepo else {
            lastError = "keyframe 저장소가 준비되지 않았습니다."
            pendingQueueCount = max(0, pendingQueueCount - 1)
            return
        }
        let id = scanId
        let keyframeTransform = sample.transform
        let keyframeCapturedAt = sample.capturedAt
        let keyframeTrackingState = sample.trackingStateLabel
        storageQueue.async { [weak self] in
            var didSave = false
            do {
                try repo.save(
                    transform: keyframeTransform,
                    capturedAt: keyframeCapturedAt,
                    trackingStateLabel: keyframeTrackingState,
                    seq: seq,
                    scanId: id
                )
                didSave = true
            } catch {
                NSLog("[ScanStore] keyframe_meta save failed seq=%d error=%@", seq, error.localizedDescription)
            }
            let newSize = self?.computeDbSize() ?? 0
            Task { @MainActor in
                guard let self else { return }
                if didSave {
                    self.lastPersistedKeyframeSeq = seq
                    self.lastPersistedKeyframeTransform = keyframeTransform
                    self.keyframeCount += 1
                } else {
                    self.lastError = "keyframe 저장 실패: 노드 저장을 잠시 후 다시 시도하세요."
                }
                self.pendingQueueCount -= 1
                self.dbSizeBytes = newSize
            }
        }
    }

    func sessionManager(_ manager: ARSessionManager, trackingStateDidChange label: String) {
        trackingStateLabel = label
    }

    /// Sprint 95: angular velocity sustain 으로 fastMotion enter/exit 판정.
    private func updateFastMotionState(omega: Float, now: TimeInterval) {
        if !fastMotion {
            // enter 후보: threshold 이상 sustain
            if omega >= Self.fastMotionEnterThreshold {
                if fastMotionAboveSince == 0 {
                    fastMotionAboveSince = now
                } else if now - fastMotionAboveSince >= Self.fastMotionEnterSustainSec {
                    fastMotion = true
                    fastMotionBelowSince = 0
                }
            } else {
                fastMotionAboveSince = 0
            }
        } else {
            // exit 후보: threshold 미만 sustain
            if omega < Self.fastMotionExitThreshold {
                if fastMotionBelowSince == 0 {
                    fastMotionBelowSince = now
                } else if now - fastMotionBelowSince >= Self.fastMotionExitSustainSec {
                    fastMotion = false
                    fastMotionAboveSince = 0
                }
            } else {
                fastMotionBelowSince = 0
            }
        }
    }

    func sessionManagerDidFail(_ manager: ARSessionManager, error: Error) {
        lastError = error.localizedDescription
        phase = .failed(error.localizedDescription)
    }
}

// MARK: - Errors

enum ScanStoreError: LocalizedError {
    case insufficientStorage

    var errorDescription: String? {
        switch self {
        case .insufficientStorage:
            return "남은 저장 공간이 부족합니다 (최소 500 MB 필요)."
        }
    }
}

// MARK: - UIDevice 헬퍼

private extension UIDevice {
    var modelIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { ptr in
            String(cString: ptr.bindMemory(to: CChar.self).baseAddress!)
        }
    }
}

private extension Bundle {
    var shortVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }
}

// MARK: - InterfloorConnectorType → StandaloneMarkerKind (Sprint 88 cycle_7)

extension ScanStore.InterfloorConnectorType {
    /// cycle_7: InterfloorConnectorType → MarkARSceneOverlay.StandaloneMarkerKind 매핑.
    var overlayMarkerKind: MarkARSceneOverlay.StandaloneMarkerKind {
        switch self {
        case .elevator:   return .interfloorElevator
        case .escalator:  return .interfloorEscalator
        case .stairs:     return .interfloorStairs
        }
    }
}
