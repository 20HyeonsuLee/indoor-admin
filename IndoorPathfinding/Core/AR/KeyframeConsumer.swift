import Foundation

/// KeyframeCaptureThrottle 통과분만 downstream(ScanStore)으로 위임하는 Consumer.
/// throttle 통과 시 frameSeq 증가 + RTABMapBridge pendingKeyframes enqueue + downstream 전달.
///
/// Sprint 35 Task 1 v3:
/// - slamConsumer.lastNodeIDForMostRecentFrame는 deprecated(항상 nil).
/// - nodeID 할당은 RTABMapBridge의 timestamp 기반 비동기 path로 이루어진다.
/// - onNodeIDAssigned는 더 이상 유효한 nodeID를 전달하지 않으므로 호출하지 않는다.
/// - RTABMapBridge.nodeIDListener를 ScanStore에 연결하는 방식으로 대체된다.
@MainActor
final class KeyframeConsumer: FrameConsumer {

    private let throttle: KeyframeCaptureThrottle
    private weak var downstream: ARSessionManagerDelegate?
    /// Sprint 35: pendingKeyframes enqueue 대상. weak으로 순환 참조 방지.
    private weak var rtabmapBridge: RTABMapBridgeEnqueueProtocol?

    /// throttle 통과 프레임의 누적 seq (ScanStore.lastCapturedSeq와 동기).
    private var frameSeq: Int = 0

    /// Deprecated (Sprint 35 Task 1 v3): nodeID 비동기 path 전환으로 더 이상 유효한 값 전달 안 함.
    /// 하위 호환성을 위해 시그니처는 유지하되 호출하지 않는다.
    var onNodeIDAssigned: ((Int, RTABMapNodeID?) -> Void)?

    init(
        throttle: KeyframeCaptureThrottle = KeyframeCaptureThrottle(),
        downstream: ARSessionManagerDelegate,
        rtabmapBridge: RTABMapBridgeEnqueueProtocol? = nil
    ) {
        self.throttle = throttle
        self.downstream = downstream
        self.rtabmapBridge = rtabmapBridge
    }

    func consume(manager: ARSessionManager, sample: KeyframeSample) {
        guard let downstream else { return }

        let pendingCount = downstream.pendingQueueCount
        let decision = throttle.decide(sample: sample, pendingCount: pendingCount)
        guard decision == .capture else { return }

        frameSeq += 1
        let seq = frameSeq

        // Sprint 35 Task 1 v3: throttle 통과 직후 RTABMapBridge에 enqueue
        // capturedAt은 RTAB-Map에 넘기는 timestamp와 동일 (timeIntervalSince1970)
        rtabmapBridge?.enqueuePendingKeyframe(seq: seq, capturedAt: sample.capturedAt.timeIntervalSince1970)

        downstream.sessionManager(manager, didCapture: sample)
    }

    func reset() {
        throttle.reset()
        frameSeq = 0
    }
}

// MARK: - RTABMapBridgeEnqueueProtocol

/// KeyframeConsumer가 throttle 통과 시 pendingKeyframes에 enqueue할 수 있도록 하는 프로토콜.
/// RTABMapBridge가 채택한다. 테스트에서 mock으로 대체 가능.
@MainActor
protocol RTABMapBridgeEnqueueProtocol: AnyObject {
    func enqueuePendingKeyframe(seq: Int, capturedAt: TimeInterval)
}
