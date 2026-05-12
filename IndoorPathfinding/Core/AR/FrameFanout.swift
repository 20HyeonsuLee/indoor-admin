import Foundation

// MARK: - FrameFanout

/// ARSessionManagerDelegate를 가로채어 모든 프레임을 등록된 Consumer들에 순서대로 전달.
///
/// 설계 근거 (Sprint 4 architect_design.md §3.2 + Sprint 65 단순화):
/// - Consumer 목록을 attach 순서대로 전량 전달. 주기 제한은 각 Consumer 내부 책임.
/// - attach 순서 규약: SLAM → Keyframe (Sprint 65에서 YOLO 제거).
///   SLAMConsumer가 먼저 pushFrame해야 KeyframeConsumer가 lastNodeID를 읽을 수 있다.
/// - 기존 onNodeIDAssigned 콜백은 KeyframeConsumer를 통해 전달된다.
@MainActor
final class FrameFanout: ARSessionManagerDelegate {

    // MARK: - Consumers

    /// 순서 규약: SLAM → Keyframe. attach 순서 변경 금지.
    private var consumers: [FrameConsumer] = []

    // MARK: - Init

    /// downstream: 하위호환용. KeyframeConsumer가 내부적으로 downstream을 참조한다.
    /// 단순히 consumer list가 빈 상태에서도 tracking 이벤트는 _trackingDelegate로 전달.
    private weak var trackingDelegate: ARSessionManagerDelegate?

    init(trackingDelegate: ARSessionManagerDelegate? = nil) {
        self.trackingDelegate = trackingDelegate
    }

    // MARK: - Consumer 관리

    func attach(_ consumer: FrameConsumer) {
        consumers.append(consumer)
    }

    func detach(_ consumer: FrameConsumer) {
        consumers.removeAll { $0 === consumer }
    }

    // MARK: - ARSessionManagerDelegate

    func sessionManager(_ manager: ARSessionManager, didCapture sample: KeyframeSample) {
        // 순서대로 모든 Consumer에 전파. 주기 판정은 각 Consumer 내부.
        for consumer in consumers {
            consumer.consume(manager: manager, sample: sample)
        }
    }

    func sessionManager(_ manager: ARSessionManager, trackingStateDidChange label: String) {
        trackingDelegate?.sessionManager(manager, trackingStateDidChange: label)
    }

    func sessionManagerDidFail(_ manager: ARSessionManager, error: Error) {
        trackingDelegate?.sessionManagerDidFail(manager, error: error)
    }

    // MARK: - Reset

    func reset() {
        consumers.removeAll()
    }
}
