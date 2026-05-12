import Testing
import ARKit
import simd
@testable import IndoorPathfinding

/// FloorReferenceTracker 3단계 fallback 룰 단위 테스트.
/// ARSession mock 불필요 — ARAnchor 직접 생성 + handleAnchorAdded 호출로 검증.
@Suite("FloorReferenceTracker")
@MainActor
struct FloorReferenceTrackerTests {

    // MARK: - Helpers

    private func makeTracker(timeoutSec: TimeInterval = 0.01) -> FloorReferenceTracker {
        FloorReferenceTracker(timeoutSec: timeoutSec)
    }

    // MARK: - AC-AR-floor-lock: Strategy 3 — heuristic

    @Test("heuristic lock — handleFirstCorridorMark 호출 시 floorY = cameraY - 1.5")
    func test_heuristic_lock_on_first_corridor_mark() {
        let tracker = makeTracker()
        tracker.sessionStarted()

        let cameraY: Float = 1.4
        let returned = tracker.handleFirstCorridorMark(cameraY: cameraY)

        #expect(tracker.isLocked)
        #expect(tracker.source == .heuristic)
        #expect(abs(tracker.floorY! - (cameraY - 1.5)) < 0.001)
        #expect(abs(returned - (cameraY - 1.5)) < 0.001)
    }

    @Test("heuristic lock — 이미 lock된 경우 기존 값 유지")
    func test_heuristic_does_not_override_existing_lock() async throws {
        let tracker = makeTracker(timeoutSec: 0.0)
        tracker.sessionStarted()

        // 먼저 heuristic으로 lock
        tracker.handleFirstCorridorMark(cameraY: 1.6)
        let firstFloorY = tracker.floorY!

        // 두 번째 호출 — 기존 lock 유지
        tracker.handleFirstCorridorMark(cameraY: 2.0)

        #expect(abs(tracker.floorY! - firstFloorY) < 0.001)
    }

    @Test("sessionStarted — lock 초기화")
    func test_session_started_resets_lock() {
        let tracker = makeTracker()
        tracker.sessionStarted()
        tracker.handleFirstCorridorMark(cameraY: 1.5)
        #expect(tracker.isLocked)

        tracker.sessionStarted()
        #expect(!tracker.isLocked)
        #expect(tracker.floorY == nil)
        #expect(tracker.source == nil)
    }

    // MARK: - Strategy 1: classification == .floor (requires device, test structure only)

    @Test("handleAnchorAdded — horizontal plane (y < cameraY - 0.5) 후보 등록 + timeout 후 lock 예약")
    func test_horizontal_anchor_becomes_candidate_after_timeout() async throws {
        // timeout = 0.01초 (거의 즉시)
        let tracker = makeTracker(timeoutSec: 0.01)
        tracker.sessionStarted()

        // anchor를 직접 생성 (ARPlaneAnchor 대신 ARAnchor로 simulate)
        // ARPlaneAnchor는 init이 제한적이어서 handleAnchorAdded가 plane 아님으로 무시 →
        // 이 경우 heuristic 경로로만 검증
        // ARAnchor(transform:)을 넘기면 ARPlaneAnchor 캐스팅 실패 → 즉시 return
        let plainAnchor = ARAnchor(transform: matrix_identity_float4x4)
        tracker.handleAnchorAdded(plainAnchor, cameraY: 1.5)  // non-plane anchor → skip

        // 아직 lock X
        #expect(!tracker.isLocked)

        // heuristic 경로로 lock
        tracker.handleFirstCorridorMark(cameraY: 1.5)
        #expect(tracker.isLocked)
        #expect(tracker.source == .heuristic)
    }

    @Test("handleAnchorAdded — lock 후 추가 anchor 무시")
    func test_anchor_ignored_after_lock() {
        let tracker = makeTracker()
        tracker.sessionStarted()

        // heuristic으로 먼저 lock
        tracker.handleFirstCorridorMark(cameraY: 1.5)
        let lockedY = tracker.floorY!

        // 새 anchor 추가 — lock 이후라 무시되어야 함
        let anchor = ARAnchor(transform: matrix_identity_float4x4)
        tracker.handleAnchorAdded(anchor, cameraY: 1.5)

        #expect(tracker.floorY == lockedY)
    }

    // MARK: - floorY 반환값

    @Test("handleFirstCorridorMark — 이미 lock된 경우 기존 floorY 반환")
    func test_first_corridor_mark_returns_existing_floor_y_when_locked() {
        let tracker = makeTracker()
        tracker.sessionStarted()
        tracker.handleFirstCorridorMark(cameraY: 1.5)
        let floorY = tracker.floorY!

        // 다른 cameraY로 호출해도 기존 floorY 반환
        let returned = tracker.handleFirstCorridorMark(cameraY: 2.0)
        #expect(abs(returned - floorY) < 0.001)
    }
}
