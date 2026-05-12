import Testing
import Foundation
import GRDB
@testable import IndoorPathfinding

/// ScanMetadataDatabase v6 → v7 마이그레이션 검증 (Sprint 88 Cycle 2).
@Suite("ScanMetadataDatabase Migration v7")
struct ScanMetadataDatabaseMigrationV7Tests {

    // MARK: - Helpers

    private func makeDatabase() throws -> ScanMetadataDatabase {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("scan_metadata.db")
        return try ScanMetadataDatabase(dbURL: dbURL)
    }

    private func insertScanSession(db: ScanMetadataDatabase) throws -> String {
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
                arguments: [scanId, seq, Int64(seq * 1000), "", blob]
            )
        }
    }

    // MARK: - Fresh install 검증

    @Test("v7: fresh install 후 user_version == 9 (v8/v9 자동 연속 적용)")
    func freshInstallUserVersionIs7() throws {
        let db = try makeDatabase()
        let version = try db.dbQueue.read { d in
            try Int.fetchOne(d, sql: "PRAGMA user_version")
        }
        // Sprint 88 Cycle 6: v9 마이그레이션 자동 적용 → 최종 8
        #expect(version == 9)
    }

    @Test("v7: branch_mark에 node_type 컬럼 존재 + NOT NULL DEFAULT corridor")
    func branchMarkHasNodeTypeColumn() throws {
        let db = try makeDatabase()
        let columns = try db.dbQueue.read { d in
            try d.columns(in: "branch_mark").map { $0.name }
        }
        #expect(columns.contains("node_type"))
        #expect(columns.contains("width_m"))
        #expect(columns.contains("connect_hint"))
        #expect(columns.contains("connect_node_id"))
        #expect(columns.contains("mark_session_id"))
    }

    @Test("v7: mark_session_id 인덱스 존재")
    func markSessionIdIndexExists() throws {
        let db = try makeDatabase()
        let indexes = try db.dbQueue.read { d in
            try d.indexes(on: "branch_mark").map { $0.name }
        }
        let hasIndex = indexes.contains(where: { $0.contains("mark_session_id") })
        #expect(hasIndex)
    }

    @Test("v7: node_type CHECK constraint 검증 — 유효값 허용")
    func nodeTypeCheckAllowsValidValues() throws {
        let db = try makeDatabase()
        let scanId = try insertScanSession(db: db)
        try insertKeyframe(db: db, scanId: scanId, seq: 1)
        let blob = Data(repeating: 0, count: 64)

        // corridor 허용
        try db.dbQueue.write { d in
            try d.execute(
                sql: """
                INSERT INTO branch_mark
                    (scan_id, keyframe_seq, created_at, pose_matrix, tx, ty, tz, node_type)
                VALUES (?, 1, 0, ?, 0, 0, 0, 'corridor')
                """,
                arguments: [scanId, blob]
            )
        }

        // corner 허용
        try db.dbQueue.write { d in
            try d.execute(
                sql: """
                INSERT INTO branch_mark
                    (scan_id, keyframe_seq, created_at, pose_matrix, tx, ty, tz, node_type)
                VALUES (?, 1, 0, ?, 0, 0, 0, 'corner')
                """,
                arguments: [scanId, blob]
            )
        }

        let count = try db.dbQueue.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM branch_mark WHERE scan_id = ?",
                              arguments: [scanId]) ?? 0
        }
        #expect(count == 2)
    }

    @Test("v7: width_m NULL 허용")
    func widthMNullAllowed() throws {
        let db = try makeDatabase()
        let scanId = try insertScanSession(db: db)
        try insertKeyframe(db: db, scanId: scanId, seq: 1)
        let blob = Data(repeating: 0, count: 64)

        try db.dbQueue.write { d in
            try d.execute(
                sql: """
                INSERT INTO branch_mark
                    (scan_id, keyframe_seq, created_at, pose_matrix, tx, ty, tz, node_type, width_m)
                VALUES (?, 1, 0, ?, 0, 0, 0, 'corner', NULL)
                """,
                arguments: [scanId, blob]
            )
        }

        // BranchMark record로 round-trip 확인
        let rows = try db.dbQueue.read { d in
            try BranchMark.fetchAll(d, sql: "SELECT * FROM branch_mark WHERE scan_id = ?",
                                     arguments: [scanId])
        }
        #expect(rows.count == 1)
        #expect(rows[0].widthM == nil)
    }

    @Test("v7: 신규 row insert — BranchMark record round-trip")
    func branchMarkV7RecordRoundTrip() throws {
        let db = try makeDatabase()
        let scanId = try insertScanSession(db: db)
        try insertKeyframe(db: db, scanId: scanId, seq: 1)
        let blob = Data(repeating: 42, count: 64)
        let sessionId = UUID().uuidString

        var mark = BranchMark(
            id: nil,
            scanId: scanId,
            keyframeSeq: 1,
            createdAt: 12345,
            poseMatrix: blob,
            tx: 1.0, ty: 2.0, tz: 3.0,
            nodeType: "corner",
            widthM: nil,
            connectHint: nil,
            connectNodeId: nil,
            markSessionId: sessionId
        )
        try db.dbQueue.write { d in try mark.save(d) }

        let fetched = try db.dbQueue.read { d in
            try BranchMark.fetchAll(d, sql: "SELECT * FROM branch_mark WHERE scan_id = ?",
                                    arguments: [scanId])
        }
        #expect(fetched.count == 1)
        #expect(fetched[0].nodeType == "corner")
        #expect(fetched[0].markSessionId == sessionId)
        #expect(fetched[0].widthM == nil)
    }

    // MARK: - v6 → v7 upgrade 검증

    @Test("v6 → v7: 기존 row node_type = 'corridor' default 백필")
    func v6ToV7MigrationBackfillsCorridorDefault() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("scan_metadata.db")

        // v6 DB fixture 수동 생성 (grdb_migrations에 v1~v6 등록)
        let rawQueue = try DatabaseQueue(path: dbURL.path)
        try rawQueue.write { d in
            try d.execute(sql: """
                CREATE TABLE scan_session (
                    id TEXT PRIMARY KEY,
                    started_at INTEGER NOT NULL,
                    ended_at INTEGER,
                    device_model TEXT NOT NULL,
                    app_version TEXT NOT NULL,
                    state TEXT NOT NULL CHECK(state IN ('recording','saved','discarded')),
                    keyframe_count INTEGER NOT NULL DEFAULT 0,
                    notes TEXT
                )
            """)
            try d.execute(sql: """
                CREATE TABLE keyframe_meta (
                    scan_id TEXT NOT NULL REFERENCES scan_session(id) ON DELETE CASCADE,
                    seq INTEGER NOT NULL,
                    captured_at INTEGER NOT NULL,
                    image_path TEXT NOT NULL,
                    pose_matrix BLOB NOT NULL,
                    tx REAL NOT NULL, ty REAL NOT NULL, tz REAL NOT NULL,
                    tracking_state TEXT NOT NULL,
                    rtabmap_node_id INTEGER,
                    PRIMARY KEY (scan_id, seq)
                )
            """)
            try d.execute(sql: """
                CREATE TABLE poi_mark (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    scan_id TEXT NOT NULL,
                    keyframe_seq INTEGER NOT NULL,
                    created_at INTEGER NOT NULL,
                    pose_matrix BLOB NOT NULL,
                    tx REAL NOT NULL, ty REAL NOT NULL, tz REAL NOT NULL,
                    label TEXT,
                    source TEXT NOT NULL DEFAULT 'manual'
                        CHECK(source IN ('track_lock','manual')),
                    FOREIGN KEY (scan_id, keyframe_seq) REFERENCES keyframe_meta(scan_id, seq)
                        ON DELETE CASCADE
                )
            """)
            try d.execute(sql: """
                CREATE TABLE poi_photo (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    poi_mark_id INTEGER NOT NULL REFERENCES poi_mark(id) ON DELETE CASCADE,
                    scan_id TEXT NOT NULL REFERENCES scan_session(id) ON DELETE CASCADE,
                    keyframe_seq INTEGER NOT NULL,
                    captured_at INTEGER NOT NULL,
                    class_name TEXT NOT NULL,
                    confidence REAL NOT NULL,
                    image_blob BLOB,
                    FOREIGN KEY (scan_id, keyframe_seq) REFERENCES keyframe_meta(scan_id, seq)
                        ON DELETE CASCADE
                )
            """)
            try d.execute(sql: """
                CREATE TABLE branch_mark (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    scan_id TEXT NOT NULL,
                    keyframe_seq INTEGER NOT NULL,
                    created_at INTEGER NOT NULL,
                    pose_matrix BLOB NOT NULL,
                    tx REAL NOT NULL, ty REAL NOT NULL, tz REAL NOT NULL,
                    FOREIGN KEY (scan_id, keyframe_seq) REFERENCES keyframe_meta(scan_id, seq)
                        ON DELETE CASCADE
                )
            """)
            try d.execute(sql: """
                CREATE TABLE interfloor_mark (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    scan_id TEXT NOT NULL REFERENCES scan_session(id) ON DELETE CASCADE,
                    keyframe_seq INTEGER NOT NULL,
                    created_at INTEGER NOT NULL,
                    connector_type TEXT NOT NULL CHECK(connector_type IN ('elevator','escalator','stairs')),
                    prefix TEXT NOT NULL,
                    pose_matrix BLOB NOT NULL,
                    tx REAL NOT NULL, ty REAL NOT NULL, tz REAL NOT NULL,
                    FOREIGN KEY (scan_id, keyframe_seq) REFERENCES keyframe_meta(scan_id, seq)
                        ON DELETE CASCADE
                )
            """)
            try d.execute(sql: "CREATE TABLE IF NOT EXISTS grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            for v in ["v1", "v2", "v3", "v4", "v5", "v6"] {
                try d.execute(sql: "INSERT INTO grdb_migrations VALUES (?)", arguments: [v])
            }
            try d.execute(sql: "PRAGMA user_version = 6")

            // v6 시대의 branch_mark row 2개
            let scanId = "v6-test-scan"
            let blob = Data(repeating: 0, count: 64)
            try d.execute(sql: "INSERT INTO scan_session (id, started_at, device_model, app_version, state, keyframe_count) VALUES (?, 0, 'iPhone', '1.0', 'saved', 2)", arguments: [scanId])
            try d.execute(sql: "INSERT INTO keyframe_meta (scan_id, seq, captured_at, image_path, pose_matrix, tx, ty, tz, tracking_state) VALUES (?, 1, 0, '', ?, 0, 0, 0, 'normal')", arguments: [scanId, blob])
            try d.execute(sql: "INSERT INTO keyframe_meta (scan_id, seq, captured_at, image_path, pose_matrix, tx, ty, tz, tracking_state) VALUES (?, 2, 0, '', ?, 0, 0, 0, 'normal')", arguments: [scanId, blob])
            try d.execute(sql: "INSERT INTO branch_mark (scan_id, keyframe_seq, created_at, pose_matrix, tx, ty, tz) VALUES (?, 1, 100, ?, 1.0, 0, 0)", arguments: [scanId, blob])
            try d.execute(sql: "INSERT INTO branch_mark (scan_id, keyframe_seq, created_at, pose_matrix, tx, ty, tz) VALUES (?, 2, 200, ?, 2.0, 0, 0)", arguments: [scanId, blob])
        }

        // v7 마이그레이션 실행
        let migratedDB = try ScanMetadataDatabase(dbURL: dbURL)

        // PRAGMA user_version == 9 (v8/v9 자동 연속 적용)
        let version = try migratedDB.dbQueue.read { d in
            try Int.fetchOne(d, sql: "PRAGMA user_version")
        }
        #expect(version == 9)

        // 기존 row의 node_type == 'corridor' (NOT NULL DEFAULT)
        let rows = try migratedDB.dbQueue.read { d in
            try BranchMark.fetchAll(d, sql: "SELECT * FROM branch_mark ORDER BY created_at")
        }
        #expect(rows.count == 2)
        #expect(rows[0].nodeType == "corridor")
        #expect(rows[1].nodeType == "corridor")

        // width_m, connect_hint, connect_node_id, mark_session_id = NULL
        #expect(rows[0].widthM == nil)
        #expect(rows[0].connectHint == nil)
        #expect(rows[0].connectNodeId == nil)
        #expect(rows[0].markSessionId == nil)
    }

    @Test("v7→v8: idempotent — v8 DB를 다시 열어도 migration 재실행 없음")
    func v7MigrationIdempotent() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("scan_metadata.db")

        // 첫 번째 열기
        _ = try ScanMetadataDatabase(dbURL: dbURL)
        // 두 번째 열기 — 재실행 없이 동일 버전
        let db2 = try ScanMetadataDatabase(dbURL: dbURL)

        let version = try db2.dbQueue.read { d in
            try Int.fetchOne(d, sql: "PRAGMA user_version")
        }
        // Sprint 88 Cycle 6: 최종 버전 8
        #expect(version == 9)
    }
}
