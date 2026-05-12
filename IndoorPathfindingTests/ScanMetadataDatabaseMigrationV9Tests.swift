import Testing
import Foundation
import GRDB
@testable import IndoorPathfinding

/// ScanMetadataDatabase v8 → v9 마이그레이션 검증 (Sprint 89 Cycle 1).
/// AC1: branch_edge 테이블 + INDEX × 2 + PRAGMA user_version = 9 검증.
@Suite("ScanMetadataDatabase Migration v9")
struct ScanMetadataDatabaseMigrationV9Tests {

    // MARK: - Helpers

    private func makeDatabase() throws -> ScanMetadataDatabase {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("scan_metadata.db")
        return try ScanMetadataDatabase(dbURL: dbURL)
    }

    // MARK: - Fresh install 검증

    @Test("v9: fresh install 후 user_version == 9")
    func freshInstallUserVersionIs9() throws {
        let db = try makeDatabase()
        let version = try db.dbQueue.read { d in
            try Int.fetchOne(d, sql: "PRAGMA user_version")
        }
        #expect(version == 9)
    }

    @Test("v9: branch_edge 테이블 존재")
    func branchEdgeTableExists() throws {
        let db = try makeDatabase()
        let tableExists = try db.dbQueue.read { d in
            try String.fetchOne(
                d,
                sql: "SELECT name FROM sqlite_master WHERE type='table' AND name='branch_edge'"
            ) != nil
        }
        #expect(tableExists)
    }

    @Test("v9: branch_edge 필수 컬럼 존재")
    func branchEdgeColumnsExist() throws {
        let db = try makeDatabase()
        let columns = try db.dbQueue.read { d in
            try d.columns(in: "branch_edge").map { $0.name }
        }
        let required = [
            "id", "scan_id", "from_node_id", "to_node_id",
            "kind", "length_m", "mark_session_id", "polygon_closed", "created_at"
        ]
        for col in required {
            #expect(columns.contains(col), "branch_edge 에 컬럼 없음: \(col)")
        }
    }

    @Test("v9: scan_id 인덱스 존재")
    func scanIdIndexExists() throws {
        let db = try makeDatabase()
        let indexes = try db.dbQueue.read { d in
            try d.indexes(on: "branch_edge").map { $0.name }
        }
        let hasIndex = indexes.contains(where: { $0.contains("scan_id") })
        #expect(hasIndex, "branch_edge.scan_id 인덱스 없음")
    }

    @Test("v9: mark_session_id 인덱스 존재")
    func markSessionIdIndexExists() throws {
        let db = try makeDatabase()
        let indexes = try db.dbQueue.read { d in
            try d.indexes(on: "branch_edge").map { $0.name }
        }
        let hasIndex = indexes.contains(where: { $0.contains("mark_session_id") })
        #expect(hasIndex, "branch_edge.mark_session_id 인덱스 없음")
    }

    @Test("v9: kind CHECK constraint — 유효값 허용")
    func kindCheckAllowsValidValues() throws {
        let db = try makeDatabase()

        // scan_session row 생성
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

        let validKinds = ["sequential", "proximity", "transition", "cornerPolygon"]
        for kind in validKinds {
            try db.dbQueue.write { d in
                try d.execute(
                    sql: """
                    INSERT INTO branch_edge
                        (scan_id, from_node_id, to_node_id, kind, length_m, created_at)
                    VALUES (?, '1', '2', ?, 1.0, 0)
                    """,
                    arguments: [scanId, kind]
                )
            }
        }

        let count = try db.dbQueue.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM branch_edge WHERE scan_id = ?",
                              arguments: [scanId]) ?? 0
        }
        #expect(count == 4)
    }

    @Test("v9: kind CHECK constraint — 무효값 거부")
    func kindCheckRejectsInvalidValue() throws {
        let db = try makeDatabase()
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

        #expect(throws: (any Error).self) {
            try db.dbQueue.write { d in
                try d.execute(
                    sql: """
                    INSERT INTO branch_edge
                        (scan_id, from_node_id, to_node_id, kind, length_m, created_at)
                    VALUES (?, '1', '2', 'INVALID', 1.0, 0)
                    """,
                    arguments: [scanId]
                )
            }
        }
    }

    // MARK: - v8 → v9 upgrade 검증

    @Test("v8 → v9: 기존 branch_mark row 보존")
    func v8ToV9MigratePreservesBranchMarks() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("scan_metadata.db")

        // v8 DB fixture 수동 생성
        let rawQueue = try DatabaseQueue(path: dbURL.path)
        try rawQueue.write { d in
            // 최소 테이블만 생성
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
                CREATE TABLE branch_mark (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    scan_id TEXT NOT NULL REFERENCES scan_session(id) ON DELETE CASCADE,
                    keyframe_seq INTEGER NOT NULL,
                    created_at INTEGER NOT NULL,
                    pose_matrix BLOB NOT NULL,
                    tx REAL NOT NULL, ty REAL NOT NULL, tz REAL NOT NULL,
                    node_type TEXT NOT NULL DEFAULT 'corridor'
                        CHECK(node_type IN ('corridor','corner')),
                    width_m REAL,
                    connect_hint TEXT,
                    connect_node_id INTEGER,
                    mark_session_id TEXT,
                    dx_local REAL,
                    dy_local REAL,
                    dz_local REAL,
                    FOREIGN KEY (scan_id, keyframe_seq) REFERENCES keyframe_meta(scan_id, seq)
                        ON DELETE CASCADE
                )
            """)
            try d.execute(sql: """
                CREATE TABLE poi_mark (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    scan_id TEXT NOT NULL REFERENCES scan_session(id) ON DELETE CASCADE,
                    keyframe_seq INTEGER NOT NULL,
                    created_at INTEGER NOT NULL,
                    pose_matrix BLOB NOT NULL,
                    tx REAL NOT NULL, ty REAL NOT NULL, tz REAL NOT NULL,
                    label TEXT,
                    source TEXT NOT NULL DEFAULT 'manual'
                        CHECK(source IN ('track_lock','manual')),
                    dx_local REAL, dy_local REAL, dz_local REAL,
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
                CREATE TABLE interfloor_mark (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    scan_id TEXT NOT NULL REFERENCES scan_session(id) ON DELETE CASCADE,
                    keyframe_seq INTEGER NOT NULL,
                    created_at INTEGER NOT NULL,
                    connector_type TEXT NOT NULL CHECK(connector_type IN ('elevator','escalator','stairs')),
                    prefix TEXT NOT NULL,
                    pose_matrix BLOB NOT NULL,
                    tx REAL NOT NULL, ty REAL NOT NULL, tz REAL NOT NULL,
                    dx_local REAL, dy_local REAL, dz_local REAL,
                    FOREIGN KEY (scan_id, keyframe_seq) REFERENCES keyframe_meta(scan_id, seq)
                        ON DELETE CASCADE
                )
            """)
            try d.execute(sql: "CREATE TABLE IF NOT EXISTS grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            for v in ["v1","v2","v3","v4","v5","v6","v7","v8"] {
                try d.execute(sql: "INSERT INTO grdb_migrations VALUES (?)", arguments: [v])
            }
            try d.execute(sql: "PRAGMA user_version = 8")

            // v8 시대 branch_mark row 2개
            let scanId = "v8-test-scan"
            let blob = Data(repeating: 0, count: 64)
            try d.execute(sql: "INSERT INTO scan_session (id, started_at, device_model, app_version, state, keyframe_count) VALUES (?, 0, 'iPhone', '1.0', 'saved', 2)", arguments: [scanId])
            try d.execute(sql: "INSERT INTO keyframe_meta (scan_id, seq, captured_at, image_path, pose_matrix, tx, ty, tz, tracking_state) VALUES (?, 1, 0, '', ?, 0, 0, 0, 'normal')", arguments: [scanId, blob])
            try d.execute(sql: "INSERT INTO branch_mark (scan_id, keyframe_seq, created_at, pose_matrix, tx, ty, tz, node_type) VALUES (?, 1, 100, ?, 1.0, 0, 0, 'corridor')", arguments: [scanId, blob])
        }

        // v9 마이그레이션 실행
        let migratedDB = try ScanMetadataDatabase(dbURL: dbURL)

        // PRAGMA user_version == 9
        let version = try migratedDB.dbQueue.read { d in
            try Int.fetchOne(d, sql: "PRAGMA user_version")
        }
        #expect(version == 9)

        // 기존 branch_mark row 보존
        let markCount = try migratedDB.dbQueue.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM branch_mark") ?? 0
        }
        #expect(markCount == 1)

        // branch_edge 테이블 존재 + 비어있음
        let edgeCount = try migratedDB.dbQueue.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM branch_edge") ?? 0
        }
        #expect(edgeCount == 0)
    }

    @Test("v9: idempotent — v9 DB 를 다시 열어도 migration 재실행 없음")
    func v9MigrationIdempotent() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("scan_metadata.db")

        _ = try ScanMetadataDatabase(dbURL: dbURL)
        let db2 = try ScanMetadataDatabase(dbURL: dbURL)

        let version = try db2.dbQueue.read { d in
            try Int.fetchOne(d, sql: "PRAGMA user_version")
        }
        #expect(version == 9)
    }
}
