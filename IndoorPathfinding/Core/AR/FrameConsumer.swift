import Foundation

/// ARKit frame의 단일 수신 경로.
/// FrameFanout이 여러 Consumer를 동시에 보유.
/// consume은 Main thread(FrameFanout의 @MainActor)에서 호출됨.
/// 내부 비동기 처리는 Consumer의 책임.
///
/// attach 순서 규약(FrameFanout): SLAM → Keyframe (Sprint 65에서 YOLO 제거).
/// SLAMConsumer가 먼저 pushFrame을 완료해야 KeyframeConsumer가 lastNodeID를 읽을 수 있다.
@MainActor
protocol FrameConsumer: AnyObject {
    /// 모든 프레임에 대해 호출. Consumer 내부 throttle이 판정.
    func consume(manager: ARSessionManager, sample: KeyframeSample)
}
