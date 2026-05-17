import Foundation

/// ARKit 프레임을 RTABMapSLAMSink에 push하는 Consumer.
/// Sprint 92: 30fps 카메라 → SLAM throttle.
/// Sprint 96: 발열 완화를 위해 live scan 기본 입력을 5Hz로 낮춘다.
/// lastNodeIDForMostRecentFrame: 직전 consume 결과. KeyframeConsumer가 조회.
/// ADR D2: rollover pause/resume 신호는 KeyframeCaptureThrottle이 제어한다.
///   SLAMConsumer는 자체 minInterval throttle과 별도로,
///   KeyframeCaptureThrottle.isPaused 시 pushFrame을 skip한다.
@MainActor
final class SLAMConsumer: FrameConsumer {

    private let sink: RTABMapSLAMSink
    private let minInterval: TimeInterval

    /// ADR D2: rollover overlap 추적을 위한 외부 throttle 참조.
    /// nil이면 rollover pause 기능 비활성.
    weak var captureThrottle: KeyframeCaptureThrottle?

    /// 직전 pushFrame 반환값. KeyframeConsumer가 attach 순서상 SLAM 이후에 consume하므로
    /// 이 값은 항상 "방금 push된 프레임"의 nodeID다.
    private(set) var lastNodeIDForMostRecentFrame: RTABMapNodeID?

    /// 직전 push 시각 (throttle 비교용)
    private var lastPushAt: Date?

    /// [DIAG] ARFrame 도달 카운터 — FrameFanout → SLAMConsumer 경로 검증
    private var consumeCallCount: Int = 0
    private var pushedCallCount: Int = 0
    private var blurRejectedCount: Int = 0

    /// Sprint 95: 블러 frame reject. nil 이면 비활성 (테스트/회귀 대비).
    private let blurDetector: BlurDetector?

    init(sink: RTABMapSLAMSink, minInterval: TimeInterval = 0.2, blurDetector: BlurDetector? = BlurDetector()) {  // 0.2s = 5Hz
        self.sink = sink
        self.minInterval = minInterval
        self.blurDetector = blurDetector
    }

    func consume(manager: ARSessionManager, sample: KeyframeSample) {
        consumeCallCount += 1

        // ADR D2: rollover pause 중이면 pushFrame skip.
        if captureThrottle?.isPaused == true { return }

        // throttle은 sample.capturedAt 기반 — ARFrame timestamp 동등. wall-clock 의존 X.
        let now = sample.capturedAt
        if let last = lastPushAt, now.timeIntervalSince(last) < minInterval {
            return
        }

        // Sprint 95: throttle 통과 후 blur gate. RTAB-Map 에 망가진 frame 안 보냄.
        if let detector = blurDetector, detector.isBlurred(sample.pixelBuffer) {
            blurRejectedCount += 1
            if blurRejectedCount % 10 == 1 {
                NSLog("[RTABMap-DIAG] SLAMConsumer blur reject #%d variance=%.1f",
                      blurRejectedCount, detector.lastVariance)
            }
            // throttle window 는 갱신 안 함 — 다음 frame 즉시 시도해서 sharp frame 잡는다.
            return
        }

        lastPushAt = now
        pushedCallCount += 1
        if pushedCallCount % 30 == 1 {
            NSLog("[RTABMap-DIAG] SLAMConsumer pushed #%d (received #%d, throttled %.0f%%, blur reject %d)",
                  pushedCallCount, consumeCallCount,
                  100.0 * Double(consumeCallCount - pushedCallCount) / Double(consumeCallCount),
                  blurRejectedCount)
        }
        lastNodeIDForMostRecentFrame = sink.pushFrame(sample)
    }
}
