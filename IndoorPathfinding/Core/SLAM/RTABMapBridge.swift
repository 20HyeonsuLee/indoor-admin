#if !targetEnvironment(simulator)
import ARKit
import Darwin
import GLKit
import OSLog

private struct RTABMapNativeHandle: @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer
}

private struct RTABMapLifecycleResult: @unchecked Sendable {
    let dbURL: URL
    let nodeStamps: [(nodeId: Int, stamp: Double)]
    let newNative: RTABMapNativeHandle?
    let callbackOpaque: RTABMapNativeHandle?
}

/// RTAB-Map native 백엔드 Swift 래퍼.
/// RTABMapApp의 RTABMap.swift에서 odometry/save/stats 경로만 발췌.
///
/// - 책임: NativeWrapper의 C API를 Swift 값 타입으로 감싼다.
/// - 제외: rendering(`renderNative`/`setupGraphic`), mesh export, measurement.
/// - 스레드: public API는 @MainActor에서 호출. native C++는 내부 worker thread를 가진다.
@MainActor
final class RTABMapBridge: RTABMapSLAMSink, RTABMapBridgeEnqueueProtocol {

    // MARK: - Stored

    private var native: UnsafeMutableRawPointer?
    private(set) var stats: RTABMapStats = RTABMapStats()

    /// 가장 최근에 RTAB-Map이 통보한 node count. pushFrame 반환값 매핑에 사용.
    private var lastKnownNodeCount: Int = 0

    /// ScanStore.statsModel과 연결 — weak으로 순환 참조 방지.
    weak var statsListener: RTABMapStatsModel?

    /// Sprint 8: pose sync 수신자. weak으로 순환 참조 방지.
    weak var poseConsumer: PoseConsumerProtocol?

    /// Sprint 8: loop closure 감지 후 pose pull을 위한 flag.
    /// R-7: statsUpdatedCallback 내에서 직접 fetchOptimizedPoses를 호출하면
    ///       RTAB-Map 내부 락 재진입 위험이 있으므로, flag만 세우고 MainActor Task에서 pull한다.
    private var pendingPosePull: Bool = false

    /// Sprint 8: 500ms rate-limit용 마지막 pose pull 시각.
    private var lastPosePullTime: Date = .distantPast

    // MARK: - Sprint 35 Task 1 v4: timestamp 기반 nodeID 비동기 매칭 (완화된 ε)

    /// pendingKeyframes: throttle 통과 keyframe의 (seq, capturedAt) FIFO 큐.
    /// statsUpdated 콜백에서 새 node가 확정되면 timestamp로 매칭 후 nodeIDListener에 통지한다.
    /// 최대 50건 유지, 30초 이상 묵은 항목은 GC로 제거.
    private struct PendingKeyframe {
        let seq: Int
        let capturedAt: TimeInterval  // ARKit timestamp (초, Unix epoch 기준)
    }
    private var pendingKeyframes: [PendingKeyframe] = []
    private static let pendingKeyframesMaxCount = 50
    /// v4: ε=500ms (v3: 50ms). iOS throttle 1Hz + RTAB-Map DetectionRate 1Hz 동기화 불일치 대응.
    private static let pendingKeyframesStampEpsilon: TimeInterval = 0.5   // ±500ms
    /// v4 fallback: ε를 벗어나도 closest diff < 1.0s 이면 매칭.
    private static let pendingKeyframesClosestFallbackThreshold: TimeInterval = 1.0
    private static let pendingKeyframesGCThreshold: TimeInterval = 30.0   // 30초 이상 묵은 항목 제거

    /// nodeID 비동기 매칭 결과 수신자. ScanStore.handleNodeIDAssigned에 연결한다.
    /// weak으로 순환 참조 방지.
    weak var nodeIDListener: NodeIDListenerProtocol?

    // M-7: 구조화 로깅 — subsystem/category 지정으로 Console.app/log stream 필터링 가능
    private static let logger = Logger(subsystem: "ac.koreatech.indoorpathfinding", category: "rtabmap")
    nonisolated private static let lifecycleQueue = DispatchQueue(label: "ac.koreatech.indoorpathfinding.rtabmap.lifecycle", qos: .userInitiated)

    /// M-6: 콜백에 전달한 opaque 포인터의 retain을 보관.
    /// deinit 전까지 self가 살아있도록 강한 참조를 직접 유지한다.
    private var callbackRetain: Unmanaged<RTABMapBridge>?

    // MARK: - Init

    nonisolated init(statsListener: RTABMapStatsModel? = nil) {
        self.statsListener = statsListener
    }

    deinit {
        if let native {
            destroyNativeApplication(native)
        }
        // retain 해제 — native 소멸 후에 release하여 콜백 도달 가능성 소거
        callbackRetain?.release()
    }

    // MARK: - RTABMapSLAMSink

    // MARK: - Step A: stderr → NSLog redirect (Cycle 2)

    /// native stderr(RTABMap ULogger kTypeConsole 출력)를 NSLog로 리다이렉트한다.
    /// createNativeApplication() 호출 전에 1회만 실행. Thread는 앱 생애 동안 유지.
    private static var stderrRedirectStarted = false
    private static func startStderrToNSLogRedirect() {
        guard !stderrRedirectStarted else { return }
        stderrRedirectStarted = true

        // Sprint 49 hotfix: standalone 환경(Xcode 미연결)에서 NSLog 자체가 stderr에
        // 쓰는 경로 때문에 무한 루프가 발생한다.
        //   stderr → pipe(writeFd) → reader thread → NSLog → stderr → pipe → ...
        // Xcode 연결 시에는 lldb가 system console을 가로채서 안 터지지만 standalone
        // 에서는 pipe buffer가 빠르게 차고 reader thread CPU spin → watchdog/SIGPIPE.
        // RTAB-Map ULogger는 native NativeWrapper.cpp에서 setvbuf(stderr, _IOLBF)로
        // 라인 버퍼링 + Console.app 채널로 그대로 흘러간다. redirect 없이도 디버깅 가능.
        // debugger 연결된 경우(주로 Xcode 사용 중)에만 redirect 활성화한다.
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let ok = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0
        let isDebuggerAttached = ok && (info.kp_proc.p_flag & P_TRACED) != 0
        guard isDebuggerAttached else {
            NSLog("[RTABMap-DIAG] Step A: standalone run — stderr redirect skipped (NSLog loop guard)")
            return
        }

        var pipeFds: [Int32] = [0, 0]
        guard pipe(&pipeFds) == 0 else {
            NSLog("[RTABMap-DIAG] Step A: pipe() failed — stderr redirect aborted")
            return
        }
        let readFd = pipeFds[0]
        let writeFd = pipeFds[1]

        // 원본 stderr fd를 백업해두고 reader thread는 NSLog 대신 그 백업으로 직접
        // write한다. NSLog → stderr 경로를 끊어 무한 loop를 방어한다.
        let originalStderr = dup(STDERR_FILENO)
        dup2(writeFd, STDERR_FILENO)
        close(writeFd)

        let readFdBox = readFd
        let originalStderrBox = originalStderr
        Thread.detachNewThread {
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(readFdBox, &buf, buf.count - 1)
                guard n > 0 else { break }
                _ = buf.withUnsafeBytes { ptr in
                    write(originalStderrBox, ptr.baseAddress, Int(n))
                }
            }
        }
        NSLog("[RTABMap-DIAG] Step A: stderr → original stderr redirect started (debugger only)")
    }

    func start(scanURL: URL) throws {
        // Step A: native log redirect 시작 (createNativeApplication 전)
        RTABMapBridge.startStderrToNSLogRedirect()

        // [DIAG-1] native 생성 + DB 경로
        let workingPathForLog = scanURL.appendingPathComponent("rtabmap_working.db").path
        NSLog("[RTABMap-DIAG] start() called. scanURL=%@ workingPath=%@",
              scanURL.path, workingPathForLog)

        let rawPtr = createNativeApplication()
        let native = UnsafeMutableRawPointer(mutating: rawPtr)
        let nativeAddr = native.map { Int(bitPattern: $0) } ?? 0
        NSLog("[RTABMap-DIAG] createNativeApplication() returned ptr=0x%lx", nativeAddr)
        self.native = native

        // 콜백 바인딩 — native worker thread에서 호출되므로 MainActor hop 필요.
        // M-6: passRetained로 콜백 수명 동안 self를 강하게 보유한다.
        //      callbackRetain을 보관하여 deinit에서 명시적으로 release한다.
        let retained = Unmanaged.passRetained(self)
        self.callbackRetain = retained
        let opaqueSelf = retained.toOpaque()
        NSLog("[RTABMap-DIAG] setupCallbacksNative: opaqueSelf=0x%lx",
              Int(bitPattern: opaqueSelf))
        setupCallbacksNative(
            native,
            opaqueSelf,
            // progressCallback: 미사용
            { _, _, _ in },
            // initCallback: 미사용
            { _, _, _ in },
            // statsUpdatedCallback: nodes, words, points, polygons, updateTime,
            //   loopClosureId, highestHypId, databaseMemoryUsed, inliers, matches,
            //   featuresExtracted, hypothesis, nodesDrawn, fps, rejected,
            //   rehearsalValue, optimizationMaxError, optimizationMaxErrorRatio,
            //   distanceTravelled, fastMovement, landmarkDetected, x, y, z, roll, pitch, yaw
            // statsUpdatedCallback: 28 params total (observer + 27 stats values)
            // nodes, words, points, polygons, updateTime,
            // loopClosureId, highestHypId, databaseMemoryUsed, inliers, matches, featuresExtracted,
            // hypothesis, nodesDrawn, fps, rejected,
            // rehearsalValue, optimizationMaxError, optimizationMaxErrorRatio, distanceTravelled,
            // fastMovement, landmarkDetected,
            // x, y, z, roll, pitch, yaw
            { opaque, nodes, _, _, _, _, loopClosureId, _, databaseMemoryUsed, _, _, _, _, nodesDrawn, _, _, _, _, _, _, _, _, _, _, _, _, _, _ in
                // [DIAG-6] statsUpdatedCallback 도달 여부 — 이 로그가 없으면 가설 6 확정
                NSLog("[RTABMap-DIAG] statsUpdatedCallback reached: nodes=%d loopClosureId=%d nodesDrawn=%d dbMem=%lld",
                      Int32(nodes), Int32(loopClosureId), Int32(nodesDrawn), Int64(databaseMemoryUsed))
                guard let opaque else {
                    NSLog("[RTABMap-DIAG] statsUpdatedCallback: opaque is nil — self lost!")
                    return
                }
                // M-6: passRetained로 전달했으므로 takeUnretainedValue()로 참조만 가져온다.
                //      retain/release 균형은 callbackRetain이 deinit에서 release로 보장한다.
                let me = Unmanaged<RTABMapBridge>.fromOpaque(opaque).takeUnretainedValue()
                let nodeCount = Int(nodes)
                let newLoopCount = Int(loopClosureId) > 0
                    ? me.stats.loopClosureCount + 1
                    : me.stats.loopClosureCount
                let snapshot = RTABMapStats(
                    nodeCount: nodeCount,
                    loopClosureCount: newLoopCount,
                    dbBytes: Int64(databaseMemoryUsed)
                )
                // M-7: Logger(subsystem:category:) 구조화 로깅으로 교체
                RTABMapBridge.logger.debug("RTABMap stats: nodes=\(nodeCount) loops=\(newLoopCount)")
                if newLoopCount > me.stats.loopClosureCount {
                    RTABMapBridge.logger.info("RTABMap loop closure detected: loops=\(newLoopCount)")
                }
                let loopDetected = newLoopCount > me.stats.loopClosureCount
                let prevNodeCount = me.stats.nodeCount
                Task { @MainActor in
                    me.stats = snapshot
                    me.lastKnownNodeCount = snapshot.nodeCount
                    me.statsListener?.update(snapshot)
                    // Sprint 8 R-7: 콜백에서 직접 C API 호출 금지 → flag + rate-limit 후 pull
                    if loopDetected {
                        me.pendingPosePull = true
                        me.schedulePosePullIfNeeded()
                    }
                    // Sprint 35 Task 1 v3: node count 증가 시 timestamp 기반 nodeID 매칭
                    if nodeCount > prevNodeCount {
                        me.matchPendingKeyframeForNewNode()
                    }
                }
            },
            // cameraInfoEventCallback: 미사용
            { _, _, _, _ in }
        )

        // Sprint 65 hotfix: Raw ARKit data recording 모드.
        // RTABMapApp::getRtabmapParameters() 의 dataRecorderMode_ 분기가 raw mode 표준 파라미터
        // (Kp/MaxFeatures=-1, Mem/RehearsalSimilarity=1.0, Rtabmap/MaxRetrieved=0,
        //  RGBD/MaxLocalRetrieved=0, Mem/STMSize=1, Mem/NotLinkedNodesKept=true) 를 적용하려면
        // openDatabase 호출 시점에 dataRecorderMode_ 가 이미 true 여야 한다.
        // 첫 시도 (Sprint 65 Phase 2) 에서 openDatabase 이후에 toggle 했더니 정상 mode 로 init
        // 되어 feature 추출 활성 + STM=10 + loop closure 활성 회귀 발생 (75CCFB3A scan 검증).
        // 현재 fix: paused 상태에서 mode flag 먼저 set → openDatabase → unpause → startCamera.
        // 근거: rtabmap_ros data_recorder.launch + RTABMapApp.cpp:199-213 dataRecorderMode_ 분기.
        setPausedMappingNative(native, true)
        setDataRecorderModeNative(native, true)
        setLocalizationModeNative(native, false)
        // Sprint 95: ARKit 4:3 1920×1440 RGB → ImagePreDecimation=2 로 db 내부 960×720 저장.
        // RTABMapApp::getRtabmapParameters() 의 cameraColor_(true) && fullResolution_(true)
        // 분기가 ImagePreDecimation="2" 를 emit. openDatabase 호출 전에 set 해야 반영.
        setFullResolutionNative(native, true)

        // working DB를 scan 디렉터리 아래에 생성. inMemory=false로 디스크 기반.
        // 이 시점에 RTABMapApp::getRtabmapParameters() 가 호출되며 dataRecorderMode_=true 로 raw
        // 분기가 적용된다.
        let workingPath = scanURL.appendingPathComponent("rtabmap_working.db").path
        var openResultRaw: Int32 = 0
        workingPath.withCString { cStr in
            openResultRaw = openDatabaseNative(native, cStr, false, true, true)
        }
        NSLog("[RTABMap-DIAG] openDatabaseNative returned=%d path=%@",
              Int32(openResultRaw), workingPath)
        if openResultRaw == 0 {
            NSLog("[RTABMap-DIAG] CRITICAL: openDatabaseNative FAILED — hypothesis 3 likely")
        }

        // 이제 unpause — 이후 postOdometryEvent 가 raw 파라미터 적용된 상태에서 동작한다.
        setPausedMappingNative(native, false)

        // 메모리/품질 제한 (비-LiDAR 기기 최적화)
        setMaxCloudDepthNative(native, 5.0)
        setCloudDensityLevelNative(native, 1)

        // Step B (Cycle 2): startCameraNative — RTABMapApp 원본 init 순서에 필수.
        // postOdometryEvent 진입부: `cameraDriver_ == 3 && camera_` 조건.
        let cameraStarted = startCameraNative(native)
        NSLog("[RTABMap-DIAG] startCameraNative() returned=%d (1=success, 0=failure)", cameraStarted ? 1 : 0)
        if !cameraStarted {
            NSLog("[RTABMap-DIAG] CRITICAL: startCameraNative FAILED — postOdometryEvent will be silently ignored")
        }

        NSLog("[RTABMap-DIAG] start() complete. Mode=raw_arkit_recording (DataRecorder=ON) maxCloudDepth=5.0")
    }

    /// pushFrame 호출 카운터 — 60Hz 전량이므로 N=60마다 로그 1회.
    private var pushFrameCallCount: Int = 0

    @discardableResult
    func pushFrame(_ sample: KeyframeSample) -> RTABMapNodeID? {
        // [DIAG-1] native nil guard — nil이면 가설 1 확정
        guard let native else {
            NSLog("[RTABMap-DIAG] pushFrame: native is nil — HYPOTHESIS 1 CONFIRMED")
            return nil
        }

        pushFrameCallCount += 1
        let pose = sample.transform

        // [DIAG-7] pose/quat finite 검사 — NaN/inf면 가설 7 확정
        let tx = pose.columns.3.x
        let ty = pose.columns.3.y
        let tz = pose.columns.3.z
        let poseIsFinite = tx.isFinite && ty.isFinite && tz.isFinite

        // [DIAG-2] N=60마다 1회 카운터 로그 (60Hz라 raw 출력은 과함)
        if pushFrameCallCount % 60 == 1 {
            NSLog("[RTABMap-DIAG] pushFrame #%d: t=(%.3f, %.3f, %.3f) finite=%d nodesBefore=%d",
                  pushFrameCallCount,
                  Double(tx), Double(ty), Double(tz),
                  poseIsFinite ? 1 : 0,
                  lastKnownNodeCount)
            if !poseIsFinite {
                NSLog("[RTABMap-DIAG] CRITICAL: pose contains NaN/Inf — HYPOTHESIS 7 CONFIRMED")
            }

            // Step C: pixelBuffer format / size / depth nil — 포맷 불일치 시 RTAB-Map 내부 처리 거부
            // postOdometryEvent 조건: rgbFormat == 875704422 (kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
            let pixFmt = CVPixelBufferGetPixelFormatType(sample.pixelBuffer)
            let pixW = CVPixelBufferGetWidth(sample.pixelBuffer)
            let pixH = CVPixelBufferGetHeight(sample.pixelBuffer)
            let depthNil = sample.depthMap == nil
            let featureCount = sample.featurePoints.count
            NSLog("[RTABMap-DIAG] Step C pixelBuffer: fmt=0x%08X(%u) size=%dx%d depthNil=%d featureCount=%d",
                  UInt32(pixFmt), UInt32(pixFmt),
                  pixW, pixH,
                  depthNil ? 1 : 0,
                  featureCount)
            // 875704422 = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            // 875704438 = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            if pixFmt != 875704422 {
                NSLog("[RTABMap-DIAG] CRITICAL: pixelBuffer format mismatch! expected 875704422 got %u — RTAB-Map will silently skip frame", UInt32(pixFmt))
            }
            // intrinsics 값 검증
            NSLog("[RTABMap-DIAG] Step C intrinsics: fx=%.2f fy=%.2f cx=%.2f cy=%.2f",
                  Double(sample.intrinsicsFx), Double(sample.intrinsicsFy),
                  Double(sample.intrinsicsCx), Double(sample.intrinsicsCy))
            if sample.intrinsicsFx <= 0 || sample.intrinsicsFy <= 0 || sample.intrinsicsCx <= 0 || sample.intrinsicsCy <= 0 {
                NSLog("[RTABMap-DIAG] CRITICAL: intrinsics contain zero/negative — RTAB-Map will skip frame")
            }
        }

        // [DIAG-7] ARKit simd_float4x4 column-major 주의:
        // pose[row, col]은 Swift simd에서 columns[col][row]와 동일.
        // 아래 GLKMatrix3 생성 시 row-major vs column-major 혼용 여부를 로그로 표시.
        // ARKit transform: columns.0=right, columns.1=up, columns.2=-forward, columns.3=position
        // m(0,0..8) → row-major 순서로 넣으면 전치(transpose)됨. 실제 전달 값 검증.
        let rotationM = GLKMatrix3(
            m: (pose[0, 0], pose[0, 1], pose[0, 2],
                pose[1, 0], pose[1, 1], pose[1, 2],
                pose[2, 0], pose[2, 1], pose[2, 2])
        )
        let quat = GLKQuaternionMakeWithMatrix3(rotationM)

        if pushFrameCallCount % 60 == 1 {
            NSLog("[RTABMap-DIAG] quat=(%.4f, %.4f, %.4f, %.4f) norm=%.4f",
                  Double(quat.x), Double(quat.y), Double(quat.z), Double(quat.w),
                  Double(sqrt(quat.x*quat.x + quat.y*quat.y + quat.z*quat.z + quat.w*quat.w)))
            // ARKit simd_float4x4 인덱스 주의: [row, col] → columns[col][row]
            // 아래가 실제로 column 0,1,2의 x,y,z를 제대로 가져오는지 비교
            let col0 = pose.columns.0  // right vector
            let col1 = pose.columns.1  // up vector
            let col2 = pose.columns.2  // -forward vector
            NSLog("[RTABMap-DIAG] pose col0=(%.3f,%.3f,%.3f) col1=(%.3f,%.3f,%.3f) col2=(%.3f,%.3f,%.3f)",
                  Double(col0.x), Double(col0.y), Double(col0.z),
                  Double(col1.x), Double(col1.y), Double(col1.z),
                  Double(col2.x), Double(col2.y), Double(col2.z))
            // GLKMatrix3 m 파라미터가 row-major이므로 위의 [0,0],[0,1],[0,2]는
            // 실제로는 columns[0][0], columns[1][0], columns[2][0] — 즉 row 0을 뽑음.
            // 이게 의도한 동작인지 확인용.
            NSLog("[RTABMap-DIAG] pose[0,0]=%.3f pose[0,1]=%.3f pose[0,2]=%.3f (Swift: columns[col][row])",
                  Double(pose[0, 0]), Double(pose[0, 1]), Double(pose[0, 2]))
        }

        let nodesBefore = lastKnownNodeCount

        CVPixelBufferLockBaseAddress(sample.pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(sample.pixelBuffer, .readOnly) }

        sample.depthMap.map { CVPixelBufferLockBaseAddress($0, .readOnly) }
        defer { sample.depthMap.map { CVPixelBufferUnlockBaseAddress($0, .readOnly) } }
        sample.confidenceMap.map { CVPixelBufferLockBaseAddress($0, .readOnly) }
        defer { sample.confidenceMap.map { CVPixelBufferUnlockBaseAddress($0, .readOnly) } }

        let v = sample.viewMatrix
        let p = sample.projectionMatrix

        let rotView = GLKMatrix3(
            m: (v[0, 0], v[0, 1], v[0, 2],
                v[1, 0], v[1, 1], v[1, 2],
                v[2, 0], v[2, 1], v[2, 2])
        )
        let quatv = GLKQuaternionMakeWithMatrix3(rotView)

        // portrait 고정 texCoord (RTABMapApp portrait 케이스 그대로)
        let imgW = Float(CVPixelBufferGetWidth(sample.pixelBuffer))
        let imgH = Float(CVPixelBufferGetHeight(sample.pixelBuffer))
        let texX2 = (1 - (2 * sample.intrinsicsFx / imgW) / p[1, 1]) / 2
        let texY2 = (1 - (2 * sample.intrinsicsFy / imgH) / p[0, 0]) / 2
        let texCoord: [Float] = [
            1 - texX2, 1 - texY2,
            1 - texX2, texY2,
            texX2, 1 - texY2,
            texX2, texY2
        ]

        // depth 파라미터 추출
        let depthPtr = sample.depthMap.flatMap { CVPixelBufferGetBaseAddress($0) }
        let depthLen = Int32(sample.depthMap.map { CVPixelBufferGetDataSize($0) } ?? 0)
        let depthW = Int32(sample.depthMap.map { CVPixelBufferGetWidth($0) } ?? 0)
        let depthH = Int32(sample.depthMap.map { CVPixelBufferGetHeight($0) } ?? 0)
        let depthFmt = Int32(sample.depthMap.map { CVPixelBufferGetPixelFormatType($0) } ?? 0)

        let confPtr = sample.confidenceMap.flatMap { CVPixelBufferGetBaseAddress($0) }
        let confLen = Int32(sample.confidenceMap.map { CVPixelBufferGetDataSize($0) } ?? 0)
        let confW = Int32(sample.confidenceMap.map { CVPixelBufferGetWidth($0) } ?? 0)
        let confH = Int32(sample.confidenceMap.map { CVPixelBufferGetHeight($0) } ?? 0)
        let confFmt = Int32(sample.confidenceMap.map { CVPixelBufferGetPixelFormatType($0) } ?? 0)

        // [DIAG-2] postOdometryEventNative 호출 직전 로그
        // [DIAG-7] 버그 검증: pose[3,0], pose[3,1], pose[3,2]가 실제로 0인지 확인
        // Swift simd_float4x4에서 [row, col] → columns[col][row]
        // pose[3,0] = columns[0][3] = col0.w = 0 (homogeneous)
        // pose[3,1] = columns[1][3] = col1.w = 0
        // pose[3,2] = columns[2][3] = col2.w = 0
        // 올바른 translation = columns[3].xyz = (tx, ty, tz)
        let bugTransX = pose[3, 0]  // 항상 0이어야 함 — 버그
        let bugTransY = pose[3, 1]  // 항상 0이어야 함 — 버그
        let bugTransZ = pose[3, 2]  // 항상 0이어야 함 — 버그
        if pushFrameCallCount % 60 == 1 {
            NSLog("[RTABMap-DIAG] postOdometryEventNative calling: ts=%.3f",
                  sample.capturedAt.timeIntervalSince1970)
            NSLog("[RTABMap-DIAG] DIAG-7 BUG CHECK: pose[3,0]=%.4f pose[3,1]=%.4f pose[3,2]=%.4f (should be 0,0,0 if bug exists)",
                  Double(bugTransX), Double(bugTransY), Double(bugTransZ))
            NSLog("[RTABMap-DIAG] DIAG-7 CORRECT translation: columns.3=(%.3f, %.3f, %.3f)",
                  Double(tx), Double(ty), Double(tz))
            if abs(bugTransX) < 0.0001 && abs(bugTransY) < 0.0001 && abs(bugTransZ) < 0.0001 {
                NSLog("[RTABMap-DIAG] HYPOTHESIS 7 CONFIRMED: translation passed as (0,0,0) to RTAB-Map — all frames at origin!")
            }
        }
        sample.featurePoints.withUnsafeBufferPointer { pointsBuf in
            postOdometryEventNative(
                native,
                // FIX (Sprint 35 Phase 2): Swift simd_float4x4 column-major.
                // pose[3, n]은 columns[n].w = 0 (homogeneous) — 모든 프레임 원점 고정 버그였음.
                // 올바른 translation은 columns.3.xyz.
                pose.columns.3.x, pose.columns.3.y, pose.columns.3.z,
                quat.x, quat.y, quat.z, quat.w,
                sample.intrinsicsFx,
                sample.intrinsicsFy,
                sample.intrinsicsCx,
                sample.intrinsicsCy,
                sample.capturedAt.timeIntervalSince1970,
                CVPixelBufferGetBaseAddressOfPlane(sample.pixelBuffer, 0),  // Y plane
                nil,                                                         // U plane (420f는 UV interleaved)
                CVPixelBufferGetBaseAddressOfPlane(sample.pixelBuffer, 1),  // UV plane
                Int32(CVPixelBufferGetBytesPerRowOfPlane(sample.pixelBuffer, 0))
                    * Int32(CVPixelBufferGetHeightOfPlane(sample.pixelBuffer, 0)),
                Int32(CVPixelBufferGetWidth(sample.pixelBuffer)),
                Int32(CVPixelBufferGetHeight(sample.pixelBuffer)),
                Int32(CVPixelBufferGetPixelFormatType(sample.pixelBuffer)),
                depthPtr, depthLen, depthW, depthH, depthFmt,
                confPtr, confLen, confW, confH, confFmt,
                pointsBuf.baseAddress, Int32(pointsBuf.count), 3,
                // FIX (Sprint 35 Phase 2): viewMatrix translation도 동일 패턴 버그.
                v.columns.3.x, v.columns.3.y, v.columns.3.z,
                quatv.x, quatv.y, quatv.z, quatv.w,
                p[0, 0], p[1, 1], p[2, 0], p[2, 1], p[2, 2], p[2, 3], p[3, 2],
                texCoord[0], texCoord[1], texCoord[2], texCoord[3],
                texCoord[4], texCoord[5], texCoord[6], texCoord[7]
            )
        }

        // Sprint 35 Task 1 v3: pushFrame은 더 이상 동기 nodeID를 반환하지 않는다.
        // RtabmapThread가 별도 스레드에서 비동기로 process()를 수행하므로
        // postOdometryEventNative 직후 getLastLocationIdNative()는 항상 0을 반환한다.
        // (race condition: 큐에 쌓인 상태일 뿐 process() 완료 전)
        //
        // 대신 pendingKeyframes 큐에 enqueue → statsUpdated 콜백에서 timestamp 매칭.

        // [DIAG-2] postOdometryEventNative 호출 직후
        let nodesAfter = lastKnownNodeCount
        if pushFrameCallCount % 60 == 1 {
            NSLog("[RTABMap-DIAG] postOdometryEventNative returned. nodesBefore=%d nodesAfter=%d(async, HUD only)",
                  nodesBefore, nodesAfter)
        }

        // pushFrame은 nil 반환 — nodeID 할당은 statsUpdated 비동기 path로만 이루어진다.
        // SLAMConsumer.lastNodeIDForMostRecentFrame = nil 유지 (deprecated, HUD/기존 코드 호환).
        return nil
    }

    func pause() {
        guard let native else { return }
        setPausedMappingNative(native, true)
    }

    /// Sprint 35 v4: nodeStamps 반환 추가.
    /// saveNative 직후 + destroyNativeApplication 직전에 getAllNodeIdsAndStampsNative를 호출해
    /// 그래프 전체 (nodeId, stamp) 쌍을 꺼낸다. ScanStore가 이를 받아 backfillFromGraph를 수행한다.
    func finalize(scanURL: URL) throws -> (dbURL: URL, nodeStamps: [(nodeId: Int, stamp: Double)]) {
        guard let native else { throw RTABMapBridgeError.notStarted }
        let dbURL = scanURL.appendingPathComponent("rtabmap.db")

        // [DIAG-4] save 호출 직전 — finalize가 실제로 호출되는지 확인
        NSLog("[RTABMap-DIAG] finalize() called. totalPushFrameCalls=%d lastKnownNodeCount=%d savePath=%@",
              pushFrameCallCount, lastKnownNodeCount, dbURL.path)

        // Sprint 92 fix: saveNative가 RTAB-Map 내부 Memory::clear()를 호출 → save 후 extract 시 빈 list.
        // 따라서 saveNative **전**에 nodeStamps 추출해야 함.
        let nodeStamps = extractAllNodeStamps(native: native)
        NSLog("[NodeIDBackfill] finalize extracted nodeStamps count=%d", nodeStamps.count)

        NSLog("[RTABMap-DIAG] saveNative calling...")
        dbURL.path.withCString { cStr in
            saveNative(native, cStr)
        }

        // [DIAG-4] save 직후 — 파일 크기 확인
        let savedSize = (try? FileManager.default.attributesOfItem(atPath: dbURL.path)[.size] as? Int64) ?? -1
        NSLog("[RTABMap-DIAG] saveNative completed. rtabmap.db size=%lld bytes", savedSize)

        destroyNativeApplication(native)
        self.native = nil
        NSLog("[RTABMap-DIAG] finalize() done. destroyNativeApplication called.")
        return (dbURL: dbURL, nodeStamps: nodeStamps)
    }

    func closeCurrentChunkAsync(
        currentScanURL: URL
    ) async throws -> (closedDBURL: URL, nodeStamps: [(nodeId: Int, stamp: Double)]) {
        guard let native else { throw RTABMapBridgeError.notStarted }

        let nativeHandle = RTABMapNativeHandle(pointer: native)
        let nodeCount = lastKnownNodeCount
        let pushCount = pushFrameCallCount

        NSLog("[RTABMap-DIAG] closeCurrentChunkAsync scheduled. totalPushFrameCalls=%d lastKnownNodeCount=%d", pushCount, nodeCount)

        callbackRetain?.release()
        callbackRetain = nil
        self.native = nil
        pendingKeyframes = []
        lastKnownNodeCount = 0
        pushFrameCallCount = 0
        stats = RTABMapStats()

        let result = try await Self.performCloseCurrentChunk(
            native: nativeHandle,
            currentScanURL: currentScanURL,
            lastKnownNodeCount: nodeCount,
            pushFrameCallCount: pushCount
        )
        return (closedDBURL: result.dbURL, nodeStamps: result.nodeStamps)
    }

    // MARK: - Chunked rollover (ADR D2)

    func rolloverChunkAsync(
        currentScanURL: URL,
        nextScanURL: URL
    ) async throws -> (closedDBURL: URL, nodeStamps: [(nodeId: Int, stamp: Double)]) {
        guard let native else { throw RTABMapBridgeError.notStarted }

        let nativeHandle = RTABMapNativeHandle(pointer: native)
        let nodeCount = lastKnownNodeCount
        let newCallbackRetain = Unmanaged.passRetained(self)
        let newCallbackOpaque = RTABMapNativeHandle(pointer: newCallbackRetain.toOpaque())

        NSLog("[RTABMap-DIAG] rolloverChunkAsync scheduled. lastKnownNodeCount=%d", nodeCount)

        callbackRetain?.release()
        callbackRetain = nil
        self.native = nil
        pendingKeyframes = []
        lastKnownNodeCount = 0
        pushFrameCallCount = 0
        stats = RTABMapStats()

        do {
            let result = try await Self.performRolloverChunk(
                native: nativeHandle,
                currentScanURL: currentScanURL,
                nextScanURL: nextScanURL,
                lastKnownNodeCount: nodeCount,
                callbackOpaque: newCallbackOpaque
            )
            guard let newNative = result.newNative,
                  let callbackOpaque = result.callbackOpaque else {
                Unmanaged<RTABMapBridge>.fromOpaque(newCallbackOpaque.pointer).release()
                throw RTABMapBridgeError.notStarted
            }
            self.native = newNative.pointer
            self.callbackRetain = Unmanaged<RTABMapBridge>.fromOpaque(callbackOpaque.pointer)
            return (closedDBURL: result.dbURL, nodeStamps: result.nodeStamps)
        } catch {
            Unmanaged<RTABMapBridge>.fromOpaque(newCallbackOpaque.pointer).release()
            throw error
        }
    }

    /// 현재 chunk DB를 저장·종료하고 새 chunk DB를 즉시 초기화한다.
    /// ARKit world tracking은 끊지 않는다 — ARSession은 계속 유지.
    ///
    /// 호출 전제: `KeyframeCaptureThrottle`이 이미 pause된 상태 (SLAMConsumer가 pushFrame을 보내지 않음).
    ///
    /// - Parameters:
    ///   - currentScanURL: 현재 활성 chunk 디렉터리. working db를 rtabmap.db로 저장하는 대상.
    ///   - nextScanURL: 새 chunk DB를 둘 디렉터리 (호출 전에 생성돼야 함).
    /// - Returns: 저장된 rtabmap.db URL + 이전 chunk의 nodeStamps.
    func rolloverChunk(
        currentScanURL: URL,
        nextScanURL: URL
    ) throws -> (closedDBURL: URL, nodeStamps: [(nodeId: Int, stamp: Double)]) {
        guard let native else { throw RTABMapBridgeError.notStarted }

        NSLog("[RTABMap-DIAG] rolloverChunk() begin. lastKnownNodeCount=%d", lastKnownNodeCount)

        // 1. nodeStamps 추출 (saveNative 전 — Memory::clear() 이후 빈 리스트 방지)
        let stamps = extractAllNodeStamps(native: native)
        NSLog("[RTABMap-DIAG] rolloverChunk nodeStamps count=%d", stamps.count)

        // 2. 현재 chunk DB를 rtabmap.db로 저장.
        let closedDBURL = currentScanURL.appendingPathComponent("rtabmap.db")
        NSLog("[RTABMap-DIAG] rolloverChunk saveNative path=%@", closedDBURL.path)
        closedDBURL.path.withCString { cStr in
            saveNative(native, cStr)
        }
        let savedSize = (try? FileManager.default.attributesOfItem(atPath: closedDBURL.path)[.size] as? Int64) ?? -1
        NSLog("[RTABMap-DIAG] rolloverChunk saveNative done. rtabmap.db size=%lld", savedSize)

        // 4. native 소멸 + callbackRetain release
        destroyNativeApplication(native)
        self.native = nil
        callbackRetain?.release()
        callbackRetain = nil

        // pendingKeyframes reset — 새 chunk에서는 새 매칭 슬레이트
        pendingKeyframes = []
        lastKnownNodeCount = 0
        pushFrameCallCount = 0

        NSLog("[RTABMap-DIAG] rolloverChunk: old session destroyed. Initializing new session...")

        // 5. 새 native 인스턴스 생성 + 콜백 바인딩
        let rawPtr = createNativeApplication()
        let newNative = UnsafeMutableRawPointer(mutating: rawPtr)
        self.native = newNative

        let retained = Unmanaged.passRetained(self)
        self.callbackRetain = retained
        let opaqueSelf = retained.toOpaque()

        setupCallbacksNative(
            newNative,
            opaqueSelf,
            { _, _, _ in },
            { _, _, _ in },
            { opaque, nodes, _, _, _, _, loopClosureId, _, databaseMemoryUsed, _, _, _, _, nodesDrawn, _, _, _, _, _, _, _, _, _, _, _, _, _, _ in
                guard let opaque else { return }
                let me = Unmanaged<RTABMapBridge>.fromOpaque(opaque).takeUnretainedValue()
                let nodeCount = Int(nodes)
                let hasLoopClosure = Int(loopClosureId) > 0
                let dbBytes = Int64(databaseMemoryUsed)
                Task { @MainActor in
                    let newLoopCount = hasLoopClosure
                        ? me.stats.loopClosureCount + 1
                        : me.stats.loopClosureCount
                    let snapshot = RTABMapStats(
                        nodeCount: nodeCount,
                        loopClosureCount: newLoopCount,
                        dbBytes: dbBytes
                    )
                    let loopDetected = newLoopCount > me.stats.loopClosureCount
                    let prevNodeCount = me.stats.nodeCount
                    me.stats = snapshot
                    me.lastKnownNodeCount = snapshot.nodeCount
                    me.statsListener?.update(snapshot)
                    if loopDetected {
                        me.pendingPosePull = true
                        me.schedulePosePullIfNeeded()
                    }
                    if nodeCount > prevNodeCount {
                        me.matchPendingKeyframeForNewNode()
                    }
                }
            },
            { _, _, _, _ in }
        )

        // 6. 새 DB init (start()와 동일한 설정 순서)
        setPausedMappingNative(newNative, true)
        setDataRecorderModeNative(newNative, true)
        setLocalizationModeNative(newNative, false)
        setFullResolutionNative(newNative, true)

        let newWorkingPath = nextScanURL.appendingPathComponent("rtabmap_working.db").path
        var openResult: Int32 = 0
        newWorkingPath.withCString { cStr in
            openResult = openDatabaseNative(newNative, cStr, false, true, true)
        }
        NSLog("[RTABMap-DIAG] rolloverChunk openDatabaseNative result=%d path=%@", openResult, newWorkingPath)

        setPausedMappingNative(newNative, false)
        setMaxCloudDepthNative(newNative, 5.0)
        setCloudDensityLevelNative(newNative, 1)
        let started = startCameraNative(newNative)
        NSLog("[RTABMap-DIAG] rolloverChunk startCameraNative=%d", started ? 1 : 0)

        NSLog("[RTABMap-DIAG] rolloverChunk() complete. new session ready.")
        return (closedDBURL: closedDBURL, nodeStamps: stamps)
    }

    /// getAllNodeIdsAndStampsNative를 호출해 (nodeId, stamp) 배열을 반환한다.
    /// native가 유효한 상태(destroyNativeApplication 전)에서만 호출해야 한다.
    private func extractAllNodeStamps(native: UnsafeMutableRawPointer) -> [(nodeId: Int, stamp: Double)] {
        Self.extractAllNodeStamps(native: native, lastKnownNodeCount: lastKnownNodeCount)
    }

    nonisolated private static func extractAllNodeStamps(
        native: UnsafeMutableRawPointer,
        lastKnownNodeCount: Int
    ) -> [(nodeId: Int, stamp: Double)] {
        // 버퍼 크기: lastKnownNodeCount + 여유 10. 최소 128.
        let bufferSize = max(128, lastKnownNodeCount + 10)
        var ids = [Int32](repeating: 0, count: bufferSize)
        var stamps = [Double](repeating: 0.0, count: bufferSize)

        let filled = Int(getAllNodeIdsAndStampsNative(native, &ids, &stamps, Int32(bufferSize)))
        NSLog("[NodeIDBackfill] getAllNodeIdsAndStampsNative filled=%d bufferSize=%d", filled, bufferSize)

        guard filled > 0 else { return [] }

        return (0..<filled).compactMap { i in
            let nodeId = Int(ids[i])
            let stamp = stamps[i]
            guard nodeId > 0, stamp > 0.0 else { return nil }
            return (nodeId: nodeId, stamp: stamp)
        }
    }

    nonisolated private static func performCloseCurrentChunk(
        native: RTABMapNativeHandle,
        currentScanURL: URL,
        lastKnownNodeCount: Int,
        pushFrameCallCount: Int
    ) async throws -> RTABMapLifecycleResult {
        try await withCheckedThrowingContinuation { continuation in
            lifecycleQueue.async {
                let raw = native.pointer
                let dbURL = currentScanURL.appendingPathComponent("rtabmap.db")
                NSLog("[RTABMap-DIAG] closeCurrentChunk background begin. totalPushFrameCalls=%d lastKnownNodeCount=%d savePath=%@",
                      pushFrameCallCount, lastKnownNodeCount, dbURL.path)
                let nodeStamps = extractAllNodeStamps(native: raw, lastKnownNodeCount: lastKnownNodeCount)
                NSLog("[NodeIDBackfill] closeCurrentChunk extracted nodeStamps count=%d", nodeStamps.count)
                dbURL.path.withCString { cStr in
                    saveNative(raw, cStr)
                }
                let savedSize = (try? FileManager.default.attributesOfItem(atPath: dbURL.path)[.size] as? Int64) ?? -1
                NSLog("[RTABMap-DIAG] closeCurrentChunk saveNative completed. rtabmap.db size=%lld bytes", savedSize)
                destroyNativeApplication(raw)
                continuation.resume(returning: RTABMapLifecycleResult(
                    dbURL: dbURL,
                    nodeStamps: nodeStamps,
                    newNative: nil,
                    callbackOpaque: nil
                ))
            }
        }
    }

    nonisolated private static func performRolloverChunk(
        native: RTABMapNativeHandle,
        currentScanURL: URL,
        nextScanURL: URL,
        lastKnownNodeCount: Int,
        callbackOpaque: RTABMapNativeHandle
    ) async throws -> RTABMapLifecycleResult {
        try await withCheckedThrowingContinuation { continuation in
            lifecycleQueue.async {
                let oldNative = native.pointer
                NSLog("[RTABMap-DIAG] rolloverChunk background begin. lastKnownNodeCount=%d", lastKnownNodeCount)

                let stamps = extractAllNodeStamps(native: oldNative, lastKnownNodeCount: lastKnownNodeCount)
                NSLog("[RTABMap-DIAG] rolloverChunk nodeStamps count=%d", stamps.count)

                let closedDBURL = currentScanURL.appendingPathComponent("rtabmap.db")
                NSLog("[RTABMap-DIAG] rolloverChunk saveNative path=%@", closedDBURL.path)
                closedDBURL.path.withCString { cStr in
                    saveNative(oldNative, cStr)
                }
                let savedSize = (try? FileManager.default.attributesOfItem(atPath: closedDBURL.path)[.size] as? Int64) ?? -1
                NSLog("[RTABMap-DIAG] rolloverChunk saveNative done. rtabmap.db size=%lld", savedSize)

                destroyNativeApplication(oldNative)

                NSLog("[RTABMap-DIAG] rolloverChunk: old session destroyed. Initializing new session...")
                let rawPtr = createNativeApplication()
                guard let newNative = UnsafeMutableRawPointer(mutating: rawPtr) else {
                    continuation.resume(throwing: RTABMapBridgeError.notStarted)
                    return
                }
                setupLifecycleCallbacks(native: newNative, opaqueSelf: callbackOpaque.pointer)

                setPausedMappingNative(newNative, true)
                setDataRecorderModeNative(newNative, true)
                setLocalizationModeNative(newNative, false)
                setFullResolutionNative(newNative, true)

                let newWorkingPath = nextScanURL.appendingPathComponent("rtabmap_working.db").path
                var openResult: Int32 = 0
                newWorkingPath.withCString { cStr in
                    openResult = openDatabaseNative(newNative, cStr, false, true, true)
                }
                NSLog("[RTABMap-DIAG] rolloverChunk openDatabaseNative result=%d path=%@", openResult, newWorkingPath)

                setPausedMappingNative(newNative, false)
                setMaxCloudDepthNative(newNative, 5.0)
                setCloudDensityLevelNative(newNative, 1)
                let started = startCameraNative(newNative)
                NSLog("[RTABMap-DIAG] rolloverChunk startCameraNative=%d", started ? 1 : 0)
                NSLog("[RTABMap-DIAG] rolloverChunk background complete. new session ready.")

                continuation.resume(returning: RTABMapLifecycleResult(
                    dbURL: closedDBURL,
                    nodeStamps: stamps,
                    newNative: RTABMapNativeHandle(pointer: newNative),
                    callbackOpaque: callbackOpaque
                ))
            }
        }
    }

    nonisolated private static func setupLifecycleCallbacks(
        native: UnsafeMutableRawPointer,
        opaqueSelf: UnsafeMutableRawPointer
    ) {
        setupCallbacksNative(
            native,
            opaqueSelf,
            { _, _, _ in },
            { _, _, _ in },
            { opaque, nodes, _, _, _, _, loopClosureId, _, databaseMemoryUsed, _, _, _, _, nodesDrawn, _, _, _, _, _, _, _, _, _, _, _, _, _, _ in
                guard let opaque else { return }
                let me = Unmanaged<RTABMapBridge>.fromOpaque(opaque).takeUnretainedValue()
                let nodeCount = Int(nodes)
                let hasLoopClosure = Int(loopClosureId) > 0
                let dbBytes = Int64(databaseMemoryUsed)
                Task { @MainActor in
                    let newLoopCount = hasLoopClosure
                        ? me.stats.loopClosureCount + 1
                        : me.stats.loopClosureCount
                    let snapshot = RTABMapStats(
                        nodeCount: nodeCount,
                        loopClosureCount: newLoopCount,
                        dbBytes: dbBytes
                    )
                    let loopDetected = newLoopCount > me.stats.loopClosureCount
                    let prevNodeCount = me.stats.nodeCount
                    me.stats = snapshot
                    me.lastKnownNodeCount = snapshot.nodeCount
                    me.statsListener?.update(snapshot)
                    if loopDetected {
                        me.pendingPosePull = true
                        me.schedulePosePullIfNeeded()
                    }
                    if nodeCount > prevNodeCount {
                        me.matchPendingKeyframeForNewNode()
                    }
                }
            },
            { _, _, _, _ in }
        )
    }

    // MARK: - RTABMapPoseProvider

    /// 현재 최적화된 pose graph를 [nodeID: simd_float4x4] 맵으로 반환한다.
    /// native가 nil(시작 전 또는 종료 후)이면 빈 맵 반환.
    func fetchOptimizedPoses() -> [Int: simd_float4x4] {
        guard let native else { return [:] }

        let count = Int(getOptimizedPoseCountNative(native))
        guard count > 0 else { return [:] }

        var ids = [Int32](repeating: 0, count: count)
        // column-major float[16] per pose
        var matrices = [Float](repeating: 0, count: count * 16)

        let filled = Int(getOptimizedPosesNative(native, &ids, &matrices, Int32(count)))

        var result: [Int: simd_float4x4] = [:]
        result.reserveCapacity(filled)

        for i in 0..<filled {
            let nodeID = Int(ids[i])
            let base = i * 16
            // column-major float[16] → simd_float4x4 (column-major이므로 그대로 사용)
            let col0 = SIMD4<Float>(matrices[base+0],  matrices[base+1],  matrices[base+2],  matrices[base+3])
            let col1 = SIMD4<Float>(matrices[base+4],  matrices[base+5],  matrices[base+6],  matrices[base+7])
            let col2 = SIMD4<Float>(matrices[base+8],  matrices[base+9],  matrices[base+10], matrices[base+11])
            let col3 = SIMD4<Float>(matrices[base+12], matrices[base+13], matrices[base+14], matrices[base+15])
            result[nodeID] = simd_float4x4(columns: (col0, col1, col2, col3))
        }
        return result
    }

    // MARK: - Sprint 35 Task 1 v3: pendingKeyframes 관리

    /// throttle 통과 keyframe을 pendingKeyframes 큐에 enqueue한다.
    /// KeyframeConsumer가 throttle 통과를 결정한 직후, ScanStore.sessionManager(_:didCapture:) 직전에 호출.
    func enqueuePendingKeyframe(seq: Int, capturedAt: TimeInterval) {
        // 최대 50건 초과 시 가장 오래된 항목 제거 (FIFO)
        if pendingKeyframes.count >= RTABMapBridge.pendingKeyframesMaxCount {
            let dropped = pendingKeyframes.removeFirst()
            NSLog("[NodeIDMatch] overflow drop seq=%d stamp=%.3f", dropped.seq, dropped.capturedAt)
        }
        pendingKeyframes.append(PendingKeyframe(seq: seq, capturedAt: capturedAt))
        NSLog("[NodeIDMatch] enq seq=%d stamp=%.3f pendingCount=%d", seq, capturedAt, pendingKeyframes.count)
    }

    /// statsUpdated 콜백에서 새 node가 생성됐을 때 호출된다.
    /// 1) getLastLocationIdNative로 nodeID 조회
    /// 2) getNodeStampNative로 해당 node의 stamp 조회
    /// 3) pendingKeyframes에서 abs(stamp - capturedAt) < 50ms 인 항목 매칭
    /// 4) 매칭 성공 시 nodeIDListener에 (seq, nodeID) 통지
    /// 5) 30초 이상 묵은 항목 GC
    private func matchPendingKeyframeForNewNode() {
        guard let native else { return }
        guard !pendingKeyframes.isEmpty else { return }

        let nodeId = Int32(getLastLocationIdNative(native))
        guard nodeId > 0 else {
            NSLog("[NodeIDMatch] matchPending: getLastLocationIdNative=0, skip")
            return
        }

        let stamp = getNodeStampNative(native, nodeId)
        guard stamp > 0.0 else {
            NSLog("[NodeIDMatch] matchPending: nodeId=%d stamp=0.0 (node not found yet)", nodeId)
            return
        }

        NSLog("[NodeIDMatch] matchPending: nodeId=%d stamp=%.3f pendingCount=%d", nodeId, stamp, pendingKeyframes.count)

        // v4: timestamp 매칭 — 1순위 ε 이내, 2순위 closest fallback < 1.0s
        let epsilon = RTABMapBridge.pendingKeyframesStampEpsilon
        let fallbackThreshold = RTABMapBridge.pendingKeyframesClosestFallbackThreshold

        // 1순위: ε=500ms 이내 첫 번째 항목
        var matchedIdx: Int? = pendingKeyframes.firstIndex(where: { abs($0.capturedAt - stamp) < epsilon })
        var matchLabel = "epsilon"

        // 2순위: ε 초과이지만 closest diff < fallbackThreshold(1.0s)
        if matchedIdx == nil {
            let closestEntry = pendingKeyframes.enumerated().min(by: {
                abs($0.element.capturedAt - stamp) < abs($1.element.capturedAt - stamp)
            })
            if let entry = closestEntry {
                let diff = abs(entry.element.capturedAt - stamp)
                if diff < fallbackThreshold {
                    matchedIdx = entry.offset
                    matchLabel = "closest_fallback"
                    NSLog("[NodeIDMatch] epsilon miss — using closest fallback seq=%d diff=%.1fms (< %.0fms)",
                          entry.element.seq, diff * 1000, fallbackThreshold * 1000)
                } else {
                    NSLog("[NodeIDMatch] no match for nodeId=%d stamp=%.3f closest seq=%d diff=%.1fms (> fallback %.0fms)",
                          nodeId, stamp, entry.element.seq, diff * 1000, fallbackThreshold * 1000)
                }
            }
        }

        if let idx = matchedIdx {
            let matched = pendingKeyframes[idx]
            let diff = abs(matched.capturedAt - stamp) * 1000.0  // ms
            NSLog("[NodeIDMatch] match[%@] seq=%d node=%d stamp_diff=%.1fms", matchLabel, matched.seq, nodeId, diff)
            pendingKeyframes.remove(at: idx)
            nodeIDListener?.nodeIDAssigned(seq: matched.seq, nodeID: Int(nodeId))
        }

        // GC: 30초 이상 묵은 항목 제거
        let now = Date().timeIntervalSince1970
        let gcThreshold = RTABMapBridge.pendingKeyframesGCThreshold
        let before = pendingKeyframes.count
        pendingKeyframes.removeAll { now - $0.capturedAt > gcThreshold }
        let removed = before - pendingKeyframes.count
        if removed > 0 {
            NSLog("[NodeIDMatch] gc removed=%d items (>%.0fs old)", removed, gcThreshold)
        }
    }

    // MARK: - Private pose pull scheduling

    /// loop closure 감지 후 500ms rate-limit을 지켜 pose pull을 예약한다.
    private func schedulePosePullIfNeeded() {
        let minInterval: TimeInterval = 0.5
        let now = Date()
        let elapsed = now.timeIntervalSince(lastPosePullTime)

        if elapsed >= minInterval {
            executePosePull()
        } else {
            let delay = minInterval - elapsed
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, self.pendingPosePull else { return }
                self.executePosePull()
            }
        }
    }

    private func executePosePull() {
        pendingPosePull = false
        lastPosePullTime = Date()
        let poses = fetchOptimizedPoses()
        guard !poses.isEmpty else { return }
        poseConsumer?.applyOptimizedPoses(poses)
    }
}

// MARK: - Errors

enum RTABMapBridgeError: Error {
    case notStarted
}

#endif // !targetEnvironment(simulator)
