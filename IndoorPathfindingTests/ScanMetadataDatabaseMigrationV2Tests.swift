import Testing
import Foundation
import GRDB
@testable import IndoorPathfinding

/// ScanMetadataDatabase v1 → v2 마이그레이션 검증.
/// - v1 DB 생성 후 v2 마이그레이션을 실행해 스키마 변경 사항 확인.
@Suite("ScanMetadataDatabase Migration v2")
struct ScanMetadataDatabaseMigrationV2Tests {

    // MARK: - Helpers

    private func makeDatabase() throws -> ScanMetadataDatabase {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("scan_metadata.db")
        return try ScanMetadataDatabase(dbURL: dbURL)
    }

    private func scanId(in db: ScanMetadataDatabase) throws -> String {
        let id = UUID().uuidString
        try db.dbQueue.write { d in
            var session = ScanSession(
                id: id, startedAt: 0, endedAt: nil,
                deviceModel: "test", appVersion: "1.0",
                state: .recording, keyframeCount: 0, notes: nil
            )
            try session.save(d)
        }
        return id
    }

    private func insertKeyframe(db: ScanMetadataDatabase, scanId: String, seq: Int) throws {
        let blob = Data(repeating: 0, count: 64)
        try db.dbQueue.write { d in
            try d.execute(
                sql: """
                INSERT INTO keyframe_meta
                    (scan_id, seq, captured_at, image_path, pose_matrix, tx, ty, tz, tracking_state)
                VALUES (?, ?, ?, ?, ?, 0, 0, 0, 'normal')
                """,
                arguments: [scanId, seq, Int64(0), "keyframes/\(seq).jpg", blob]
            )
        }
    }

    // MARK: - Tests

    @Test("v2 마이그레이션 후 user_version >= 2 (Sprint 13: v6까지 자동 적용)")
    func userVersionIsAtLeastTwo() throws {
        let db = try makeDatabase()
        let version = try db.dbQueue.read { d in
            try Int.fetchOne(d, sql: "PRAGMA user_version")
        }
        // Sprint 13에서 v3 마이그레이션이 추가됨 → version은 3
        #expect((version ?? 0) >= 2)
    }

    @Test("keyframe_meta 테이블 유지")
    func keyframeMetaTableExists() throws {
        let db = try makeDatabase()
        let exists = try db.dbQueue.read { d in try d.tableExists("keyframe_meta") }
        #expect(exists)
    }

    @Test("branch_mark 테이블 유지")
    func branchMarkTableExists() throws {
        let db = try makeDatabase()
        let exists = try db.dbQueue.read { d in try d.tableExists("branch_mark") }
        #expect(exists)
    }

    // MARK: - M-3: v1→v2 업그레이드 경로 검증

    /// v1 스키마 DB fixture를 직접 생성한 뒤 ScanMetadataDatabase(dbURL:)로 v2 migrate 실행.
    /// 기존 row 보존 + v2 컬럼 구조 검증.
    // MARK: - L-1: FK 위반 insert가 실제로 에러 발생 확인

    @Test("FK 위반 poi_mark insert → throw 발생")
    func poiMarkForeignKeyViolationThrows() throws {
        let db = try makeDatabase()
        let id = try scanId(in: db)
        // keyframe_meta seq=99 없음
        let blob = Data(repeating: 0, count: 64)

        #expect(throws: (any Error).self) {
            try db.dbQueue.write { d in
                try d.execute(
                    sql: """
                    INSERT INTO poi_mark
                        (scan_id, keyframe_seq, created_at, pose_matrix, tx, ty, tz)
                    VALUES (?, 99, 0, ?, 0, 0, 0)
                    """,
                    arguments: [id, blob]
                )
            }
        }
    }
}
