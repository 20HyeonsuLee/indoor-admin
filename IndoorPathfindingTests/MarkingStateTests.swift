import Testing
import simd
@testable import IndoorPathfinding

/// MarkingState 전이 룰 unit test.
@Suite("MarkingState")
struct MarkingStateTests {

    // MARK: - Helpers

    private func makeState() -> MarkingState { MarkingState() }

    private func pos(_ x: Float, _ z: Float) -> SIMD3<Float> {
        SIMD3<Float>(x, 0, z)
    }

    // MARK: - AC2: 대각선 edge 방지 (끊기 → proximity)

    @Test("끊기 → proximity 선택 시 대각선 edge 없음 (A-J-B → J-C, no B-C)")
    func test_branch_then_disconnect_then_proximity_no_diagonal() {
        var state = makeState()

        // A: id=1
        state.addCorridor(nodeId: 1, at: pos(0, 0), widthM: 2.5, connectHint: nil, connectNodeId: nil)
        // J: id=2 (A → J sequential)
        state.addCorridor(nodeId: 2, at: pos(1, 0), widthM: 2.5, connectHint: nil, connectNodeId: nil)
        // B: id=3 (J → B sequential)
        state.addCorridor(nodeId: 3, at: pos(2, 0), widthM: 2.5, connectHint: nil, connectNodeId: nil)

        // 끊기
        state.armProximity()

        // C: id=4 (proximity → J (id=2))
        state.addCorridor(nodeId: 4, at: pos(1, 1), widthM: 2.5, connectHint: .proximity, connectNodeId: 2)

        // edge 검증: (1,2), (2,3), (2,4) 존재. (3,4) 없음.
        let edgePairs = state.edges.map { ($0.from, $0.to) }
        #expect(edgePairs.contains(where: { $0 == (1, 2) }))
        #expect(edgePairs.contains(where: { $0 == (2, 3) }))
        #expect(edgePairs.contains(where: { $0 == (2, 4) || $0 == (4, 2) }))
        #expect(!edgePairs.contains(where: { ($0 == (3, 4)) || ($0 == (4, 3)) }))
    }

    // MARK: - AC3: corner session cluster

    @Test("corner 4개 마킹 → mark_session_id 동일 + cornerPolygon edge 3개")
    func test_corner_session_clusters_four_corners() {
        var state = makeState()
        state.startCornerSession()
        let sessionId = state.activeCornerSessionId

        // 4개 corner 추가
        state.addCorner(nodeId: 10, at: pos(0, 0))
        state.addCorner(nodeId: 11, at: pos(1, 0))
        state.addCorner(nodeId: 12, at: pos(1, 1))
        state.addCorner(nodeId: 13, at: pos(0, 1))

        // 모두 같은 session id
        let sessionIds = state.nodes.map { $0.markSessionId }
        #expect(sessionIds.allSatisfy { $0 == sessionId })

        // cornerPolygon edge: 첫 노드 이후부터 생성 → 3개 (10-11, 11-12, 12-13)
        let polygonEdges = state.edges.filter { $0.kind == .cornerPolygon }
        #expect(polygonEdges.count == 3)
    }

    // MARK: - AC4: 노드 삭제 시 edge 자동 정리

    @Test("노드 삭제 후 연결 edge 사라짐")
    func test_delete_node_cleans_edges() {
        var state = makeState()
        state.addCorridor(nodeId: 1, at: pos(0, 0), widthM: 2.5, connectHint: nil, connectNodeId: nil)
        state.addCorridor(nodeId: 2, at: pos(1, 0), widthM: 2.5, connectHint: nil, connectNodeId: nil)
        state.addCorridor(nodeId: 3, at: pos(2, 0), widthM: 2.5, connectHint: nil, connectNodeId: nil)

        // edge: (1,2), (2,3)
        #expect(state.edges.count == 2)

        // 가운데 노드(2) 삭제
        state.deleteNode(2)

        #expect(state.nodes.count == 2)
        #expect(state.edges.isEmpty)
    }

    @Test("고립 노드 감지")
    func test_isolated_node_detection() {
        var state = makeState()
        state.addCorridor(nodeId: 1, at: pos(0, 0), widthM: 2.5, connectHint: nil, connectNodeId: nil)
        state.addCorridor(nodeId: 2, at: pos(1, 0), widthM: 2.5, connectHint: nil, connectNodeId: nil)

        // 연결 끊기 후 고립 노드 3 추가
        state.armProximity()
        // proximity 대상 없이 추가 (connectNodeId=nil → edge 없음)
        state.addCorridor(nodeId: 3, at: pos(5, 0), widthM: 2.5, connectHint: .proximity, connectNodeId: nil)

        let result = state.finalizeChecklist()
        #expect(result.isolatedNodeOrders.contains(3))
    }

    // MARK: - AC7: width transition

    @Test("width 차이 1m 이내 → transition edge 생성")
    func test_width_transition_within_1m_creates_transition_edge() {
        var state = makeState()
        // width 2.5m 노드
        state.addCorridor(nodeId: 1, at: pos(0, 0), widthM: 2.5, connectHint: nil, connectNodeId: nil)
        // width 4.0m 노드 (거리 0.5m 이내)
        state.addCorridor(nodeId: 2, at: pos(0.4, 0), widthM: 4.0, connectHint: nil, connectNodeId: nil)

        let transitionEdges = state.edges.filter { $0.kind == .transition }
        #expect(!transitionEdges.isEmpty)
    }

    /// AC7 정정 (Sprint 88 Cycle 3, Medium-A):
    /// PRD §5.4 — 폭 차이 + 거리 >1m → edge 없음 + hintBannerCase flag.
    @Test("width 차이 있고 거리 >1m → edge 없음 + transitionDistanceExceeded flag")
    func test_width_transition_over_1m_no_edge_flag() {
        var state = makeState()
        state.addCorridor(nodeId: 1, at: pos(0, 0), widthM: 2.5, connectHint: nil, connectNodeId: nil)
        // 거리 1.5m — 폭 차이 + 거리 초과 → edge X
        state.addCorridor(nodeId: 2, at: pos(1.5, 0), widthM: 4.0, connectHint: nil, connectNodeId: nil)

        // edge 없음 (PRD §5.4)
        #expect(state.edges.isEmpty)

        // hintBannerCase가 .transitionDistanceExceeded 로 설정됨
        if case .transitionDistanceExceeded(let from, let to) = state.hintBannerCase {
            #expect(from == 1)
            #expect(to == 2)
        } else {
            Issue.record("hintBannerCase가 .transitionDistanceExceeded 이어야 함, 실제: \(String(describing: state.hintBannerCase))")
        }

        // finalize: transition edge 없으므로 transitionDistanceExceededPairs 는 비어있음
        // (edge 자체가 없으므로 finalizeChecklist의 transition pair 검출 대상 없음)
        let result = state.finalizeChecklist()
        #expect(result.transitionDistanceExceededPairs.isEmpty)
    }

    // MARK: - AC10: transition edge kind 기록

    @Test("transition edge kind 정확히 기록됨")
    func test_transition_edge_kind_recorded() {
        var state = makeState()
        state.addCorridor(nodeId: 1, at: pos(0, 0), widthM: 2.5, connectHint: nil, connectNodeId: nil)
        state.addCorridor(nodeId: 2, at: pos(0.5, 0), widthM: 4.0, connectHint: nil, connectNodeId: nil)

        let transitionEdge = state.edges.first(where: { $0.kind == .transition })
        #expect(transitionEdge != nil)
        #expect(transitionEdge?.from == 1)
        #expect(transitionEdge?.to == 2)
    }

    // MARK: - AC6: 백트래킹 감지

    @Test("백트래킹 감지 — 직전 노드 방향으로 heading 시 감지")
    func test_backtracking_detection() {
        var state = makeState()
        state.addCorridor(nodeId: 1, at: pos(0, 0), widthM: 2.5, connectHint: nil, connectNodeId: nil)
        state.addCorridor(nodeId: 2, at: pos(1, 0), widthM: 2.5, connectHint: nil, connectNodeId: nil)

        // 현재 위치: 노드 2(X=1)에서 0.5m 뒤 (X=0.5)
        let currentPos = SIMD3<Float>(0.5, 0, 0)

        // Case 1: heading +X (노드 2 방향으로 이동 중) → 직전 노드 1m 이내 + dot > 0 → 백트래킹
        let resultTowardsNode2 = state.detectBacktracking(
            currentPosition: currentPos,
            heading: SIMD3<Float>(1, 0, 0)
        )
        #expect(resultTowardsNode2 == true)

        // Case 2: heading -X (노드 2 반대방향, 노드 1 방향) → dot < 0 → 백트래킹 아님
        let resultAwayFromNode2 = state.detectBacktracking(
            currentPosition: currentPos,
            heading: SIMD3<Float>(-1, 0, 0)
        )
        #expect(resultAwayFromNode2 == false)

        // Case 3: 직전 노드에서 1m 초과 거리 → 조건 불충족 → 백트래킹 아님
        let farPos = SIMD3<Float>(3.0, 0, 0)  // 노드 2(X=1)에서 2m
        let resultFar = state.detectBacktracking(
            currentPosition: farPos,
            heading: SIMD3<Float>(1, 0, 0)
        )
        #expect(resultFar == false)
    }

    // MARK: - Undo

    @Test("undoLast(1) — 마지막 노드 + edge 제거")
    func test_undo_last_removes_node_and_edges() {
        var state = makeState()
        state.addCorridor(nodeId: 1, at: pos(0, 0), widthM: 2.5, connectHint: nil, connectNodeId: nil)
        state.addCorridor(nodeId: 2, at: pos(1, 0), widthM: 2.5, connectHint: nil, connectNodeId: nil)

        state.undoLast(count: 1)

        #expect(state.nodes.count == 1)
        #expect(state.edges.isEmpty)
        #expect(state.nodes[0].id == 1)
    }

    // MARK: - Finalize Checklist

    @Test("finalizeChecklist — 이상 없는 경우 hasIssues = false")
    func test_finalize_checklist_clean() {
        var state = makeState()
        state.addCorridor(nodeId: 1, at: pos(0, 0), widthM: 2.5, connectHint: nil, connectNodeId: nil)
        state.addCorridor(nodeId: 2, at: pos(0.5, 0), widthM: 2.5, connectHint: nil, connectNodeId: nil)
        state.addCorridor(nodeId: 3, at: pos(1.0, 0), widthM: 2.5, connectHint: nil, connectNodeId: nil)

        let result = state.finalizeChecklist()
        #expect(!result.hasIssues)
    }
}
