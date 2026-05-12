import Foundation

/// Sprint 70/71: coverage projection 을 KeyframeConsumer (5Hz throttle) 와 분리해 60Hz 로
/// AR camera preview 와 동일 frame rate 로 갱신한다. Coverage stamp (어디 갔다) 는 5Hz 에서
/// 충분하지만, "covered cell 들이 현재 카메라에서 화면 어디 있는지" 의 projection 은 60Hz 가
/// 필요하다. 그렇지 않으면 mask 의 hole 이 실제 floor 위치를 벗어나 잔상처럼 따라온다.
///
/// FrameFanout 에 attach 만 하면 자동으로 60Hz consume. 내부 작업은 매우 가벼움
/// (covered cell 수 * 행렬곱 4회). KeyframeConsumer 처럼 throttle 을 거치지 않는다.
@MainActor
protocol CoverageProjectionRefresher: AnyObject {
    func refreshCoverageProjection(sample: KeyframeSample)
}

@MainActor
final class CoverageProjectionConsumer: FrameConsumer {
    weak var refresher: CoverageProjectionRefresher?

    init(refresher: CoverageProjectionRefresher? = nil) {
        self.refresher = refresher
    }

    func consume(manager: ARSessionManager, sample: KeyframeSample) {
        refresher?.refreshCoverageProjection(sample: sample)
    }
}
