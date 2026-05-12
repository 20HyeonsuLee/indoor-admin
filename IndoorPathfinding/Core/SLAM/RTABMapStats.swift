import Observation
import Foundation

/// RTAB-Map 실행 통계 값 객체.
/// Stub에서는 모든 값이 0/nil. 실 구현체 교체 시 statsUpdated 콜백으로 갱신된다.
struct RTABMapStats: Equatable {
    /// 현재까지 생성된 RTAB-Map 노드 수.
    var nodeCount: Int = 0
    /// 누적 루프 클로저 수.
    var loopClosureCount: Int = 0
    /// RTAB-Map 내부 working DB 메모리 사용량 (bytes).
    var dbBytes: Int64 = 0

    var dbSizeMB: Double { Double(dbBytes) / 1_048_576.0 }
}

/// ScanStore가 @Observable로 소유하는 RTAB-Map 상태 뷰 모델.
/// Sprint 3.5에서 실 구현체 콜백이 이 값을 갱신한다.
@Observable
@MainActor
final class RTABMapStatsModel {
    private(set) var stats: RTABMapStats = RTABMapStats()

    /// Sprint 7: 직접 접근 편의 프로퍼티.
    var nodeCount: Int { stats.nodeCount }

    func update(_ new: RTABMapStats) {
        stats = new
    }

    func reset() {
        stats = RTABMapStats()
    }
}
