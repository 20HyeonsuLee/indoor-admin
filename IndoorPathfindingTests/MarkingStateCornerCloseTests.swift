import Testing
import simd
@testable import IndoorPathfinding

/// Sprint 88 cycle_7: tryCloseCornerPolygon 단위 테스트.
/// AC3 검증: corner close 룰 (xz 거리 < 0.30m, ≥2 corner, session 존재).
@Suite("MarkingState Corner Close")
struct MarkingStateCornerCloseTests {

    // MARK: - Helpers

    private func makeState() -> MarkingState { MarkingState() }

    /// xz 좌표만 지정. y=0 (floor projection 시뮬레이션)
    private func pos(_ x: Float, _ z: Float, y: Float = 0) -> SIMD3<Float> {
        SIMD3<Float>(x, y, z)
    }

    // MARK: - AC3-a: close 성공 (≥2 corner + xz 거리 < 0.30m)

    @Test("corner 2개 이상 + 첫 corner xz 거리 < 0.30m → .closed + closing edge 추가")
    func test_close_succeeds_with_two_corners_and_near_hit() {
        var state = makeState()
        state.startCornerSession()

        // corner 노드 3개 등록
        state.addCorner(nodeId: 10, at: pos(0, 0))    // 첫 corner
        state.addCorner(nodeId: 11, at: pos(1, 0))
        state.addCorner(nodeId: 12, at: pos(1, 1))

        // 첫 corner 위치에 가까운 hit (xz 거리 ≈ 0.15m < 0.30m)
        let hitPos = pos(0.1, 0.1)
        let result = state.tryCloseCornerPolygon(at: hitPos, thresholdM: 0.30)

        // .closed 반환
        guard case .closed(let nodeCount, let firstNodeId) = result else {
            Issue.record("Expected .closed, got \(result)")
            return
        }
        #expect(nodeCount == 3)
        #expect(firstNodeId == 10)

        // activeCornerSessionId = nil (자동 종료)
        #expect(state.activeCornerSessionId == nil)

        // closing edge (12 → 10, .cornerPolygon) 추가됐는지 확인
        let closingEdge = state.edges.first { $0.from == 12 && $0.to == 10 }
        #expect(closingEdge != nil)
        #expect(closingEdge?.kind == .cornerPolygon)

        // 전체 edge: sequential 2개 (10→11, 11→12) + closing 1개 = 3개
        #expect(state.edges.count == 3)
    }

    // MARK: - AC3-b: corner 1개 → .needAtLeastTwoCorners

    @Test("corner 1개 → .needAtLeastTwoCorners 반환")
    func test_close_fails_with_only_one_corner() {
        var state = makeState()
        state.startCornerSession()
        state.addCorner(nodeId: 10, at: pos(0, 0))

        let result = state.tryCloseCornerPolygon(at: pos(0.05, 0.05), thresholdM: 0.30)
        #expect(result == .needAtLeastTwoCorners)
        // activeCornerSessionId는 유지
        #expect(state.activeCornerSessionId != nil)
    }

    // MARK: - AC3-c: 거리 ≥ 0.30m → .tooFar

    @Test("hit 위치가 첫 corner에서 0.30m 이상 → .tooFar(distance:) 반환")
    func test_close_fails_when_too_far() {
        var state = makeState()
        state.startCornerSession()
        state.addCorner(nodeId: 10, at: pos(0, 0))
        state.addCorner(nodeId: 11, at: pos(1, 0))

        // xz 거리 ≈ sqrtf(0.5^2 + 0.5^2) ≈ 0.707m > 0.30m
        let hitPos = pos(0.5, 0.5)
        let result = state.tryCloseCornerPolygon(at: hitPos, thresholdM: 0.30)

        guard case .tooFar(let dist) = result else {
            Issue.record("Expected .tooFar, got \(result)")
            return
        }
        #expect(dist > 0.30)
        // closing edge 없음
        #expect(!state.edges.contains { $0.from == 11 && $0.to == 10 })
        // session 유지
        #expect(state.activeCornerSessionId != nil)
    }

    // MARK: - AC3-d: sessionId nil → .notInCornerMode

    @Test("corner session 없음(sessionId nil) → .notInCornerMode 반환")
    func test_close_fails_when_not_in_corner_mode() {
        var state = makeState()
        // startCornerSession 호출 X → activeCornerSessionId == nil

        let result = state.tryCloseCornerPolygon(at: pos(0, 0), thresholdM: 0.30)
        #expect(result == .notInCornerMode)
    }

    // MARK: - AC3-e: close 후 activeCornerSessionId == nil

    @Test("close 후 activeCornerSessionId == nil")
    func test_close_resets_session_id() {
        var state = makeState()
        state.startCornerSession()
        #expect(state.activeCornerSessionId != nil)

        state.addCorner(nodeId: 10, at: pos(0, 0))
        state.addCorner(nodeId: 11, at: pos(1, 0))

        let result = state.tryCloseCornerPolygon(at: pos(0.05, 0.0), thresholdM: 0.30)
        #expect(result == .closed(nodeCount: 2, firstNodeId: 10))
        #expect(state.activeCornerSessionId == nil)
    }

    // MARK: - AC3-f: noCornerYet (session 있음 + 노드 없음)

    @Test("session 있음 + 노드 없음 → .noCornerYet 반환")
    func test_close_fails_when_no_corner_yet() {
        var state = makeState()
        state.startCornerSession()
        // addCorner 없이 close 시도

        let result = state.tryCloseCornerPolygon(at: pos(0, 0), thresholdM: 0.30)
        #expect(result == .noCornerYet)
    }

    // MARK: - AC3-g: 다른 session corner가 있어도 자기 session 기준 검사

    @Test("같은 session ≥2 + hit 근방 → close. 다른 session corner 영향 없음")
    func test_close_isolates_by_session() {
        var state = makeState()

        // session A — 닫을 대상
        state.startCornerSession()
        state.addCorner(nodeId: 1, at: pos(0, 0))
        state.addCorner(nodeId: 2, at: pos(1, 0))
        // session A close
        let r = state.tryCloseCornerPolygon(at: pos(0.05, 0.0), thresholdM: 0.30)
        guard case .closed = r else {
            Issue.record("Expected .closed")
            return
        }

        // session B 시작 — 이전 session과 무관
        state.startCornerSession()
        state.addCorner(nodeId: 3, at: pos(5, 5))
        state.addCorner(nodeId: 4, at: pos(6, 5))

        // session B 닫기 — hit: (5.1, 5.0)
        let r2 = state.tryCloseCornerPolygon(at: pos(5.1, 5.0), thresholdM: 0.30)
        guard case .closed(let count, let firstId) = r2 else {
            Issue.record("Expected .closed for session B, got \(r2)")
            return
        }
        #expect(count == 2)
        #expect(firstId == 3)
    }

    // MARK: - AC3-h: close 후 새 session에서도 정상 동작

    @Test("close 후 startCornerSession() 재호출 시 새 session id 발급")
    func test_new_session_after_close() {
        var state = makeState()
        state.startCornerSession()
        let firstSessionId = state.activeCornerSessionId

        state.addCorner(nodeId: 10, at: pos(0, 0))
        state.addCorner(nodeId: 11, at: pos(1, 0))
        _ = state.tryCloseCornerPolygon(at: pos(0.05, 0.0), thresholdM: 0.30)

        // 자동 종료 후 새 session 시작
        state.startCornerSession()
        let secondSessionId = state.activeCornerSessionId

        #expect(secondSessionId != nil)
        #expect(secondSessionId != firstSessionId)
    }
}
