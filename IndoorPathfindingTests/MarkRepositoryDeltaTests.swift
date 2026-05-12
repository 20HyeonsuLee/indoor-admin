import Testing
import Foundation
import simd
@testable import IndoorPathfinding

/// MarkRepository v8 delta (dx/dy/dz_local) 계산 검증 + v9 BranchEdgeRepository 연동 round-trip.
/// sprint 88 cycle_6 carry-over (H2).
/// AC: dx/dy/dz_local 이 keyframe → mark position delta 로 정확히 계산됨.
@Suite("MarkRepository Delta v8 + BranchEdge v9")
struct MarkRepositoryDeltaTests {

    // MARK: - Helpers

    private func makeComponents() throws -> (MarkRepository, BranchEdgeRepository, ScanMetadataDatabase, String) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("scan_metadata.db")
        let db = try ScanMetadataDatabase(dbURL: dbURL)
        let markRepo = MarkRepository(db: db)
        let edgeRepo = BranchEdgeRepository(db: db)

        let scanId = UUID().uuidString
        try db.dbQueue.write { d in
            var session = ScanSession(
                id: scanId, startedAt: 0, endedAt: nil,
                deviceModel: "test", appVersion: "1.0",
                state: .recording, keyframeCount: 0, notes: nil
            )
            try session.save(d)
            let blob = Data(repeating: 0, count: 64)
            try d.execute(
                sql: """
                INSERT INTO keyframe_meta
                    (scan_id, seq, captured_at, image_path, pose_matrix, tx, ty, tz, tracking_state)
                VALUES (?, 1, 0, '', ?, 0, 0, 0, 'normal')
                """,
                arguments: [scanId, blob]
            )
        }
        return (markRepo, edgeRepo, db, scanId)
    }

    private func makeTransform(x: Float, y: Float, z: Float) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(x, y, z, 1)
        return m
    }

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

    // MARK: - v8 delta 검증

    @Test("corridor delta: dy = mark.y − keyframe.y, dx = dz = 0")
    func corridorDeltaIsYOnly() throws {
        let (markRepo, _, _, scanId) = try makeComponents()

        let keyframeTx = makeTransform(x: 1.0, y: 2.0, z: 3.0)
        let markTx = makeTransform(x: 1.0, y: 0.5, z: 3.0)  // corridor: floorY 이동

        let markId = try markRepo.insertBranch(
            scanId: scanId,
            keyframeSeq: 1,
            transform: markTx,
            keyframeTransform: keyframeTx,
            nodeType: .corridor
        )

        let rows = try markRepo.fetchAllBranches(scanId: scanId)
        let row = rows.first { $0.id == markId }
        #expect(row != nil)
        #expect(abs((row?.dxLocal ?? 999) - 0.0) < 0.001, "dx_local should be 0 for corridor")
        #expect(abs((row?.dyLocal ?? 999) - (0.5 - 2.0)) < 0.001, "dy_local = markY - keyY")
        #expect(abs((row?.dzLocal ?? 999) - 0.0) < 0.001, "dz_local should be 0 for corridor")
    }

    @Test("corner delta: dx/dy/dz 모두 계산됨")
    func cornerDeltaAllAxes() throws {
        let (markRepo, _, _, scanId) = try makeComponents()

        let keyframeTx = makeTransform(x: 0.0, y: 2.0, z: 0.0)
        let markTx = makeTransform(x: 1.5, y: 0.3, z: -0.5)  // corner: 3D hit position

        let markId = try markRepo.insertBranch(
            scanId: scanId,
            keyframeSeq: 1,
            transform: markTx,
            keyframeTransform: keyframeTx,
            nodeType: .corner
        )

        let rows = try markRepo.fetchAllBranches(scanId: scanId)
        let row = rows.first { $0.id == markId }
        #expect(row != nil)
        #expect(abs((row?.dxLocal ?? 999) - 1.5) < 0.001, "dx = 1.5 - 0.0")
        #expect(abs((row?.dyLocal ?? 999) - (-1.7)) < 0.001, "dy = 0.3 - 2.0")
        #expect(abs((row?.dzLocal ?? 999) - (-0.5)) < 0.001, "dz = -0.5 - 0.0")
    }

    @Test("v7 호환 호출: delta = (0, 0, 0)")
    func v7CompatCallHasZeroDelta() throws {
        let (markRepo, _, _, scanId) = try makeComponents()

        let tx = makeTransform(x: 5.0, y: 1.0, z: 2.0)
        try markRepo.insertBranch(
            scanId: scanId,
            keyframeSeq: 1,
            transform: tx  // v7 호환: keyframeTransform 없음 → delta=0
        )

        let rows = try markRepo.fetchAllBranches(scanId: scanId)
        let row = rows.first
        #expect(row != nil)
        // v7 호환 경로: transform == keyframeTransform → delta = 0
        #expect(abs((row?.dxLocal ?? 999) - 0.0) < 0.001)
        #expect(abs((row?.dyLocal ?? 999) - 0.0) < 0.001)
        #expect(abs((row?.dzLocal ?? 999) - 0.0) < 0.001)
    }

    // MARK: - v9 BranchEdgeRepository round-trip

    @Test("v9 edge round-trip: insertAll + fetchAll 일치")
    func v9EdgeRoundTrip() throws {
        let (_, edgeRepo, _, scanId) = try makeComponents()

        let sessionId = UUID()
        let nodes = [
            makeNode(id: 1),
            makeNode(id: 2),
            makeNode(id: 3, nodeType: .corner, markSessionId: sessionId),
            makeNode(id: 4, nodeType: .corner, markSessionId: sessionId),
        ]
        let edges = [
            BranchMarkEdge(from: 1, to: 2, kind: .sequential, lengthM: 1.23),
            BranchMarkEdge(from: 3, to: 4, kind: .cornerPolygon, lengthM: 0.77),
        ]

        try edgeRepo.insertAll(scanId: scanId, edges: edges, nodes: nodes, closedSessions: [sessionId])

        let fetched = try edgeRepo.fetchAll(scanId: scanId)
        #expect(fetched.count == 2)

        let seq = fetched.first { $0.kind == "sequential" }
        #expect(seq != nil)
        #expect(abs((seq?.lengthM ?? 0) - 1.23) < 0.001)
        #expect(seq?.polygonClosed == nil)

        let corner = fetched.first { $0.kind == "cornerPolygon" }
        #expect(corner != nil)
        #expect(corner?.polygonClosed == 1)  // closed session
        #expect(corner?.markSessionId == sessionId.uuidString)
    }
}
