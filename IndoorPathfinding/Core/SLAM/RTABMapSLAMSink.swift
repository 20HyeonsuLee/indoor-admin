import Foundation
import simd

// MARK: - NodeIDListenerProtocol

/// Sprint 35 Task 1 v3: RTABMapBridge가 timestamp 매칭으로 nodeID를 확정했을 때 호출하는 수신자.
/// ScanStore가 채택해 handleNodeIDAssigned 경로로 DB UPDATE를 수행한다.
@MainActor
protocol NodeIDListenerProtocol: AnyObject {
    /// 비동기로 확정된 (seq, nodeID) 쌍을 수신한다.
    func nodeIDAssigned(seq: Int, nodeID: Int)

    /// Sprint 35 v4: finalize 시점 일괄 backfill.
    /// RTAB-Map 전체 그래프의 (nodeId, stamp) 쌍을 받아 keyframe_meta의 NULL 행을 채운다.
    /// - Parameter nodeStamps: [(nodeId: Int, stamp: Double)] 배열. stamp는 초 단위 Unix epoch.
    func backfillFromGraph(nodeStamps: [(nodeId: Int, stamp: Double)])
}

// MARK: - RTABMapPoseProvider

/// Sprint 8: 최적화된 pose graph를 꺼내는 프로토콜.
/// 실 구현체는 RTABMapBridge (device only), 테스트용 mock은 FakeRTABMapPoseProvider.
@MainActor
protocol RTABMapPoseProvider: AnyObject {
    /// nodeID → simd_float4x4 (column-major) 맵을 반환한다.
    func fetchOptimizedPoses() -> [Int: simd_float4x4]
}

// MARK: - PoseConsumerProtocol

/// Sprint 8: 최적화된 pose를 받아 DB에 반영하는 수신자 프로토콜.
@MainActor
protocol PoseConsumerProtocol: AnyObject {
    func applyOptimizedPoses(_ poses: [Int: simd_float4x4])
}

// MARK: - Type Alias

/// RTAB-Map 내부 node ID. Sprint 3.5에서 실 구현 시 Int로 연결됨.
typealias RTABMapNodeID = Int

// MARK: - Protocol

/// ARKit keyframe을 RTAB-Map 백엔드로 전달하는 sink.
/// Sprint 3.5에서 실 구현체(`RTABMapBridge`)로 교체될 때 앱 코드가 변경되지 않도록
/// 인터페이스를 안정적으로 정의한다.
///
/// - `start(scanURL:)`: 스캔 디렉터리를 지정하여 SLAM 세션을 시작한다.
/// - `pushFrame(_:)`: throttle을 통과한 keyframe을 SLAM 백엔드로 전달한다.
///   반환값은 해당 프레임에 대응하는 RTAB-Map Node ID. 처리 실패나 no-op이면 nil.
/// - `pause()`: 세션을 일시 중단한다 (프레임 처리 중단, DB 유지).
/// - `finalize(scanURL:)`: 세션을 종료하고 rtabmap.db를 지정 위치에 기록한다.
///   반환값은 기록된 rtabmap.db의 URL.
/// - `stats`: 현재 SLAM 통계 스냅샷. ScanStore가 폴링하거나 `pushFrame` 직후에 읽는다.
/// RTABMapSLAMSink 호출은 모두 Main thread에서 이루어진다.
/// (ScanStore와 FrameFanout이 @MainActor이므로 호출 지점이 Main 보장)
@MainActor
protocol RTABMapSLAMSink: AnyObject {
    /// 스캔 세션을 시작한다. scanURL 아래에 working DB를 생성한다.
    func start(scanURL: URL) throws

    /// throttle을 통과한 keyframe을 push한다.
    /// - Returns: RTAB-Map Node ID. no-op 또는 rejected 시 nil.
    @discardableResult
    func pushFrame(_ sample: KeyframeSample) -> RTABMapNodeID?

    /// ARSession을 pause할 때 함께 호출해 SLAM 처리를 중단한다.
    func pause()

    /// 세션을 종료하고 rtabmap.db를 scanURL 아래에 기록한다.
    /// Sprint 35 v4: nodeStamps 반환 추가 — finalize 직후 ScanStore가 backfill에 사용한다.
    /// - Returns: (dbURL: 기록된 rtabmap.db URL, nodeStamps: 그래프의 모든 (nodeId, stamp) 쌍)
    func finalize(scanURL: URL) throws -> (dbURL: URL, nodeStamps: [(nodeId: Int, stamp: Double)])

    /// 현재 SLAM 통계. Main thread에서 읽는다.
    var stats: RTABMapStats { get }
}

// MARK: - Stub (no-op)

/// Sprint 3 stub 구현체. 모든 메서드가 no-op 또는 최솟값을 반환한다.
/// Sprint 3.5에서 실 RTABMapBridge로 교체된다.
@MainActor
final class StubRTABMapSLAMSink: RTABMapSLAMSink {

    private(set) var stats: RTABMapStats = RTABMapStats()

    nonisolated init() {}

    /// start: no-op. 실 구현체에서는 working DB를 열고 SLAM 엔진을 초기화한다.
    func start(scanURL: URL) throws {
        // no-op: Sprint 3.5에서 RTABMapBridge.openDatabase() 호출로 교체.
    }

    /// pushFrame: nil 반환 (node ID 미발급). 실 구현체에서는 postOdometryEvent 호출.
    func pushFrame(_ sample: KeyframeSample) -> RTABMapNodeID? {
        // no-op: Sprint 3.5에서 RTABMapBridge.postOdometryEvent(frame:) 호출로 교체.
        return nil
    }

    /// pause: no-op.
    func pause() {
        // no-op
    }

    /// finalize: scanURL 아래에 빈 rtabmap.db 마커 파일을 생성한다.
    /// 실 구현체에서는 RTABMapBridge.save(to:) 호출로 실제 SLAM DB를 기록한다.
    func finalize(scanURL: URL) throws -> (dbURL: URL, nodeStamps: [(nodeId: Int, stamp: Double)]) {
        let dbURL = scanURL.appendingPathComponent("rtabmap.db")
        // 빈 stub 마커: 실 SLAM DB가 아님을 명시하는 SQLite header placeholder.
        let stubMarker = "RTABMap stub — replace with real DB in Sprint 3.5\n"
        try stubMarker.write(to: dbURL, atomically: true, encoding: .utf8)
        // stub은 노드 없음 → 빈 배열 반환
        return (dbURL: dbURL, nodeStamps: [])
    }
}
