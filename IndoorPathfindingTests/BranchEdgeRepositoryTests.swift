import Testing
import Foundation
import simd
@testable import IndoorPathfinding

/// BranchEdgeRepository insertAll / fetchAll round-trip 검증 (Sprint 89 Cycle 1).
/// AC2: 4종 EdgeKind 모두 INSERT + row count 일치.
/// AC3: corner polygon close flag 정확성.
@Suite("BranchEdgeRepository")
struct BranchEdgeRepositoryTests {

    // MARK: - Helpers

    private func makeRepo() throws -> (BranchEdgeRepository, ScanMetadataDatabase, String) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("scan_metadata.db")
        let db = try ScanMetadataDatabase(dbURL: dbURL)
        let repo = BranchEdgeRepository(db: db)

        let scanId = UUID().uuidString
        try db.dbQueue.write { d in
            try d.execute(
                sql: """
                INSERT INTO scan_session (id, started_at, device_model, app_version, state, keyframe_count)
                VALUES (?, 0, 'iPhone', '1.0', 'saved', 0)
                """,
                arguments: [scanId]
            )
        }
        return (repo, db, scanId)
    }

    /// BranchMarkNode 생성 헬퍼
    private func makeNode(
        id: BranchMarkNodeId,
        nodeType: NodeType = .corridor,
        markSessionId: UUID? = nil
    ) -> BranchMarkNode {
        BranchMarkNode(
            id: id,
            nodeType: nodeType,
            widthM: 2.5,
            connectHint: nil,
            connectNodeId: nil,
            markSessionId: markSessionId,
            position: SIMD3<Float>(Float(id), 0, 0),
            order: Int(id)
        )
    }

    // MARK: - AC2: 4종 EdgeKind INSERT

    @Test("insertAll: sequential edge 저장")
    func insertSequentialEdge() throws {
        let (repo, _, scanId) = try makeRepo()
        let nodes = [makeNode(id: 1), makeNode(id: 2)]
        let edges = [BranchMarkEdge(from: 1, to: 2, kind: .sequential, lengthM: 1.0)]

        try repo.insertAll(scanId: scanId, edges: edges, nodes: nodes, closedSessions: [])

        let fetched = try repo.fetchAll(scanId: scanId)
        #expect(fetched.count == 1)
        #expect(fetched[0].kind == EdgeKind.sequential.rawValue)
        #expect(fetched[0].fromNodeId == "1")
        #expect(fetched[0].toNodeId == "2")
        #expect(fetched[0].lengthM == 1.0)
        #expect(fetched[0].markSessionId == nil)
        #expect(fetched[0].polygonClosed == nil)
    }

    @Test("insertAll: proximity edge 저장")
    func insertProximityEdge() throws {
        let (repo, _, scanId) = try makeRepo()
        let nodes = [makeNode(id: 1), makeNode(id: 3)]
        let edges = [BranchMarkEdge(from: 1, to: 3, kind: .proximity, lengthM: 2.5)]

        try repo.insertAll(scanId: scanId, edges: edges, nodes: nodes, closedSessions: [])

        let fetched = try repo.fetchAll(scanId: scanId)
        #expect(fetched.count == 1)
        #expect(fetched[0].kind == EdgeKind.proximity.rawValue)
        #expect(fetched[0].polygonClosed == nil)
    }

    @Test("insertAll: transition edge 저장")
    func insertTransitionEdge() throws {
        let (repo, _, scanId) = try makeRepo()
        let nodes = [makeNode(id: 10), makeNode(id: 11)]
        let edges = [BranchMarkEdge(from: 10, to: 11, kind: .transition, lengthM: 0.8)]

        try repo.insertAll(scanId: scanId, edges: edges, nodes: nodes, closedSessions: [])

        let fetched = try repo.fetchAll(scanId: scanId)
        #expect(fetched.count == 1)
        #expect(fetched[0].kind == EdgeKind.transition.rawValue)
        #expect(fetched[0].polygonClosed == nil)
    }

    @Test("insertAll: 4종 모두 한 번에 저장 — row count 일치")
    func insertAllKindsRowCountMatches() throws {
        let (repo, _, scanId) = try makeRepo()
        let sessionId = UUID()
        let nodes = [
            makeNode(id: 1), makeNode(id: 2),
            makeNode(id: 3, nodeType: .corner, markSessionId: sessionId),
            makeNode(id: 4, nodeType: .corner, markSessionId: sessionId),
        ]
        let edges = [
            BranchMarkEdge(from: 1, to: 2, kind: .sequential, lengthM: 1.0),
            BranchMarkEdge(from: 1, to: 3, kind: .proximity, lengthM: 2.0),
            BranchMarkEdge(from: 2, to: 3, kind: .transition, lengthM: 0.5),
            BranchMarkEdge(from: 3, to: 4, kind: .cornerPolygon, lengthM: 1.5),
        ]

        try repo.insertAll(scanId: scanId, edges: edges, nodes: nodes, closedSessions: [])

        let fetched = try repo.fetchAll(scanId: scanId)
        #expect(fetched.count == edges.count)
    }

    // MARK: - AC3: corner polygon close flag

    @Test("cornerPolygon: closed session → polygon_closed = 1")
    func cornerPolygonClosedFlagIsOne() throws {
        let (repo, _, scanId) = try makeRepo()
        let sessionId = UUID()
        let nodes = [
            makeNode(id: 1, nodeType: .corner, markSessionId: sessionId),
            makeNode(id: 2, nodeType: .corner, markSessionId: sessionId),
            makeNode(id: 3, nodeType: .corner, markSessionId: sessionId),
        ]
        // n=3 corners → 3 edges (2 sequential + 1 close)
        let edges = [
            BranchMarkEdge(from: 1, to: 2, kind: .cornerPolygon, lengthM: 1.0),
            BranchMarkEdge(from: 2, to: 3, kind: .cornerPolygon, lengthM: 1.0),
            BranchMarkEdge(from: 3, to: 1, kind: .cornerPolygon, lengthM: 1.5), // close
        ]
        // sessionId 가 closedSessions 에 포함 → polygon_closed = 1
        try repo.insertAll(scanId: scanId, edges: edges, nodes: nodes, closedSessions: [sessionId])

        let fetched = try repo.fetchAll(scanId: scanId)
        #expect(fetched.count == 3)
        for rec in fetched {
            #expect(rec.polygonClosed == 1, "closed session 의 모든 edge 는 polygon_closed=1 이어야 함")
            #expect(rec.markSessionId == sessionId.uuidString)
        }
    }

    @Test("cornerPolygon: unclosed session → polygon_closed = 0")
    func cornerPolygonUnclosedFlagIsZero() throws {
        let (repo, _, scanId) = try makeRepo()
        let sessionId = UUID()
        let nodes = [
            makeNode(id: 10, nodeType: .corner, markSessionId: sessionId),
            makeNode(id: 11, nodeType: .corner, markSessionId: sessionId),
        ]
        let edges = [
            BranchMarkEdge(from: 10, to: 11, kind: .cornerPolygon, lengthM: 1.0),
        ]
        // closedSessions 에 포함 안 함 → polygon_closed = 0
        try repo.insertAll(scanId: scanId, edges: edges, nodes: nodes, closedSessions: [])

        let fetched = try repo.fetchAll(scanId: scanId)
        #expect(fetched.count == 1)
        #expect(fetched[0].polygonClosed == 0)
    }

    @Test("cornerPolygon: 닫힌 session 과 미닫힌 session 혼재")
    func mixedClosedAndUnclosedSessions() throws {
        let (repo, _, scanId) = try makeRepo()
        let closedSession = UUID()
        let openSession = UUID()
        let nodes = [
            makeNode(id: 1, nodeType: .corner, markSessionId: closedSession),
            makeNode(id: 2, nodeType: .corner, markSessionId: closedSession),
            makeNode(id: 3, nodeType: .corner, markSessionId: openSession),
            makeNode(id: 4, nodeType: .corner, markSessionId: openSession),
        ]
        let edges = [
            BranchMarkEdge(from: 1, to: 2, kind: .cornerPolygon, lengthM: 1.0),   // closed
            BranchMarkEdge(from: 3, to: 4, kind: .cornerPolygon, lengthM: 1.0),   // open
        ]
        try repo.insertAll(scanId: scanId, edges: edges, nodes: nodes, closedSessions: [closedSession])

        let fetched = try repo.fetchAll(scanId: scanId)
        #expect(fetched.count == 2)
        let closedEdge = fetched.first { $0.markSessionId == closedSession.uuidString }
        let openEdge = fetched.first { $0.markSessionId == openSession.uuidString }
        #expect(closedEdge?.polygonClosed == 1)
        #expect(openEdge?.polygonClosed == 0)
    }

    // MARK: - fetchAll isolation

    @Test("fetchAll: scanId 별 격리 — 다른 scan edge 미포함")
    func fetchAllIsolatedByScanId() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("scan_metadata.db")
        let db = try ScanMetadataDatabase(dbURL: dbURL)
        let repo = BranchEdgeRepository(db: db)

        // 두 개의 scan_session 등록
        let scanA = UUID().uuidString
        let scanB = UUID().uuidString
        for id in [scanA, scanB] {
            try db.dbQueue.write { d in
                try d.execute(
                    sql: """
                    INSERT INTO scan_session (id, started_at, device_model, app_version, state, keyframe_count)
                    VALUES (?, 0, 'iPhone', '1.0', 'saved', 0)
                    """,
                    arguments: [id]
                )
            }
        }

        let nodesA = [makeNode(id: 1), makeNode(id: 2)]
        let edgesA = [BranchMarkEdge(from: 1, to: 2, kind: .sequential, lengthM: 1.0)]
        try repo.insertAll(scanId: scanA, edges: edgesA, nodes: nodesA, closedSessions: [])

        let nodesB = [makeNode(id: 3), makeNode(id: 4), makeNode(id: 5)]
        let edgesB = [
            BranchMarkEdge(from: 3, to: 4, kind: .sequential, lengthM: 1.0),
            BranchMarkEdge(from: 4, to: 5, kind: .sequential, lengthM: 1.0),
        ]
        try repo.insertAll(scanId: scanB, edges: edgesB, nodes: nodesB, closedSessions: [])

        let fetchedA = try repo.fetchAll(scanId: scanA)
        let fetchedB = try repo.fetchAll(scanId: scanB)

        #expect(fetchedA.count == 1)
        #expect(fetchedB.count == 2)
    }
}
