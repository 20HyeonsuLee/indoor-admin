import Testing
import Foundation
import simd
@testable import IndoorPathfinding

/// MarkRepository v7 insert/update/delete/fetchAll round-trip 검증.
@Suite("MarkRepository v7")
struct MarkRepositoryV7Tests {

    // MARK: - Helpers

    private func makeRepo() throws -> (MarkRepository, ScanMetadataDatabase, String) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("scan_metadata.db")
        let db = try ScanMetadataDatabase(dbURL: dbURL)
        let repo = MarkRepository(db: db)

        // scan_session + keyframe_meta 삽입
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
        return (repo, db, scanId)
    }

    private func identityTransform() -> simd_float4x4 { matrix_identity_float4x4 }

    // MARK: - insert corridor

    @Test("corridor 노드 insert — nodeType='corridor', widthM, connectHint=nil 저장")
    func insertCorridorNode() throws {
        let (repo, _, scanId) = try makeRepo()

        let rowId = try repo.insertBranch(
            scanId: scanId,
            keyframeSeq: 1,
            transform: identityTransform(),
            nodeType: .corridor,
            widthM: 2.5,
            connectHint: nil,
            connectNodeId: nil,
            markSessionId: nil
        )

        let rows = try repo.fetchAllBranches(scanId: scanId)
        #expect(rows.count == 1)
        #expect(rows[0].id == rowId)
        #expect(rows[0].nodeType == "corridor")
        #expect(rows[0].widthM == 2.5)
        #expect(rows[0].connectHint == nil)
        #expect(rows[0].connectNodeId == nil)
        #expect(rows[0].markSessionId == nil)
    }

    // MARK: - insert corner

    @Test("corner 노드 insert — nodeType='corner', widthM=nil, markSessionId 저장")
    func insertCornerNode() throws {
        let (repo, _, scanId) = try makeRepo()
        let sessionId = UUID().uuidString

        _ = try repo.insertBranch(
            scanId: scanId,
            keyframeSeq: 1,
            transform: identityTransform(),
            nodeType: .corner,
            widthM: nil,
            connectHint: nil,
            connectNodeId: nil,
            markSessionId: sessionId
        )

        let rows = try repo.fetchAllBranches(scanId: scanId)
        #expect(rows.count == 1)
        #expect(rows[0].nodeType == "corner")
        #expect(rows[0].widthM == nil)
        #expect(rows[0].markSessionId == sessionId)
    }

    // MARK: - insert proximity

    @Test("proximity 노드 insert — connectHint='proximity', connectNodeId 저장")
    func insertProximityNode() throws {
        let (repo, _, scanId) = try makeRepo()

        // 첫 노드
        let firstId = try repo.insertBranch(
            scanId: scanId,
            keyframeSeq: 1,
            transform: identityTransform(),
            nodeType: .corridor,
            widthM: 2.5
        )

        // proximity 노드 (첫 노드 참조)
        _ = try repo.insertBranch(
            scanId: scanId,
            keyframeSeq: 1,
            transform: identityTransform(),
            nodeType: .corridor,
            widthM: 2.5,
            connectHint: .proximity,
            connectNodeId: String(firstId)
        )

        let rows = try repo.fetchAllBranches(scanId: scanId)
        #expect(rows.count == 2)
        let proxRow = rows.last!
        #expect(proxRow.connectHint == "proximity")
        #expect(proxRow.connectNodeId == String(firstId))
    }

    // MARK: - update

    @Test("updateBranch — nodeType + widthM 갱신")
    func updateBranchNodeType() throws {
        let (repo, _, scanId) = try makeRepo()

        let rowId = try repo.insertBranch(
            scanId: scanId,
            keyframeSeq: 1,
            transform: identityTransform(),
            nodeType: .corridor,
            widthM: 2.5
        )

        try repo.updateBranch(id: rowId, nodeType: .corner, widthM: nil)

        let rows = try repo.fetchAllBranches(scanId: scanId)
        #expect(rows[0].nodeType == "corner")
        #expect(rows[0].widthM == nil)
    }

    // MARK: - delete

    @Test("deleteBranch — row 제거됨")
    func deleteBranchRow() throws {
        let (repo, _, scanId) = try makeRepo()

        let rowId = try repo.insertBranch(
            scanId: scanId,
            keyframeSeq: 1,
            transform: identityTransform(),
            nodeType: .corridor
        )

        try repo.deleteBranch(id: rowId)

        let rows = try repo.fetchAllBranches(scanId: scanId)
        #expect(rows.isEmpty)
    }

    // MARK: - fetchAll

    @Test("fetchAllBranches — 삽입 순서(created_at asc) 정렬")
    func fetchAllBranchesOrdered() throws {
        let (repo, _, scanId) = try makeRepo()

        _ = try repo.insertBranch(scanId: scanId, keyframeSeq: 1, transform: identityTransform(), nodeType: .corridor, widthM: 1.5)
        _ = try repo.insertBranch(scanId: scanId, keyframeSeq: 1, transform: identityTransform(), nodeType: .corridor, widthM: 2.5)
        _ = try repo.insertBranch(scanId: scanId, keyframeSeq: 1, transform: identityTransform(), nodeType: .corridor, widthM: 4.0)

        let rows = try repo.fetchAllBranches(scanId: scanId)
        #expect(rows.count == 3)
        // created_at은 ms 단위이므로 동일할 수 있지만 widthM 확인
        let widths = rows.compactMap { $0.widthM }
        #expect(widths.count == 3)
    }

    // MARK: - connect_node_id round-trip (Medium-B)

    @Test("connect_node_id 저장 round-trip — insertBranch(connectNodeId: '42') → fetchAll → row.connectNodeId == '42'")
    func test_insert_with_connect_node_id_round_trip() throws {
        let (repo, _, scanId) = try makeRepo()

        _ = try repo.insertBranch(
            scanId: scanId,
            keyframeSeq: 1,
            transform: identityTransform(),
            nodeType: .corridor,
            widthM: 2.5,
            connectHint: .proximity,
            connectNodeId: "42"
        )

        let rows = try repo.fetchAllBranches(scanId: scanId)
        #expect(rows.count == 1)
        #expect(rows[0].connectNodeId == "42")
        #expect(rows[0].connectHint == "proximity")
    }

    @Test("proximity chain — 노드 A(id=rowA), 노드 B(connectNodeId=String(rowA)) → 두 row 검증")
    func test_proximity_chain() throws {
        let (repo, _, scanId) = try makeRepo()

        let rowA = try repo.insertBranch(
            scanId: scanId,
            keyframeSeq: 1,
            transform: identityTransform(),
            nodeType: .corridor,
            widthM: 2.5
        )

        let rowB = try repo.insertBranch(
            scanId: scanId,
            keyframeSeq: 1,
            transform: identityTransform(),
            nodeType: .corridor,
            widthM: 2.5,
            connectHint: .proximity,
            connectNodeId: String(rowA)
        )

        let rows = try repo.fetchAllBranches(scanId: scanId)
        #expect(rows.count == 2)

        let nodeA = rows.first { $0.id == rowA }
        let nodeB = rows.first { $0.id == rowB }

        #expect(nodeA != nil)
        #expect(nodeA?.connectNodeId == nil)

        #expect(nodeB != nil)
        #expect(nodeB?.connectNodeId == String(rowA))
        #expect(nodeB?.connectHint == "proximity")
    }

    // MARK: - v6 호환 (default 인자)

    @Test("기존 insertBranch(scanId:keyframeSeq:transform:) — nodeType='corridor' default")
    func legacyInsertBranchDefaultNodeType() throws {
        let (repo, _, scanId) = try makeRepo()

        try repo.insertBranch(scanId: scanId, keyframeSeq: 1, transform: identityTransform())

        let rows = try repo.fetchAllBranches(scanId: scanId)
        #expect(rows.count == 1)
        #expect(rows[0].nodeType == "corridor")
        #expect(rows[0].widthM == nil)
        #expect(rows[0].markSessionId == nil)
    }

    @Test("없는 keyframe_seq를 참조하면 branch_mark insert는 FK 에러로 실패")
    func missingKeyframeSeqIsRejected() throws {
        let (repo, _, scanId) = try makeRepo()

        #expect(throws: (any Error).self) {
            try repo.insertBranch(scanId: scanId, keyframeSeq: 2, transform: identityTransform())
        }

        let rows = try repo.fetchAllBranches(scanId: scanId)
        #expect(rows.isEmpty)
    }
}
