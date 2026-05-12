import Testing
import Foundation
import GRDB
@testable import IndoorPathfinding

/// ScanMetadataDatabase v3 → v4 마이그레이션 검증.
@Suite("ScanMetadataDatabase Migration v4")
struct ScanMetadataDatabaseMigrationV4Tests {

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
                arguments: [scanId, seq, Int64(seq * 1000), "keyframes/\(seq).jpg", blob]
            )
        }
    }

    // MARK: - 기본 스키마 검증

    @Test("v4 마이그레이션 후 user_version == 9 (v5/v6/v7/v8/v9/v9 연속 적용)")
    func userVersionIsFour() throws {
        let db = try makeDatabase()
        let version = try db.dbQueue.read { d in
            try Int.fetchOne(d, sql: "PRAGMA user_version")
        }
        // Sprint 88 Cycle 6: v5/v6/v7/v8/v9/v9 자동 적용
        #expect(version == 9)
    }

    @Test("poi_mark에 source 컬럼 존재")
    func poiMarkHasSourceColumn() throws {
        let db = try makeDatabase()
        let columns = try db.dbQueue.read { d in
            try d.columns(in: "poi_mark").map { $0.name }
        }
        #expect(columns.contains("source"))
    }

    @Test("poi_mark.source DEFAULT 값이 'track_lock'")
    func poiMarkSourceDefaultIsTrackLock() throws {
        let db = try makeDatabase()
        let scanId = try insertScanSession(db: db)
        try insertKeyframe(db: db, scanId: scanId, seq: 1)
        let blob = Data(repeating: 0, count: 64)

        try db.dbQueue.write { d in
            try d.execute(
                sql: """
                INSERT INTO poi_mark (scan_id, keyframe_seq, created_at, pose_matrix, tx, ty, tz)
                VALUES (?, 1, 0, ?, 0, 0, 0)
                """,
                arguments: [scanId, blob]
            )
        }

        let source = try db.dbQueue.read { d in
            try String.fetchOne(d, sql: "SELECT source FROM poi_mark WHERE scan_id = ?", arguments: [scanId])
        }
        #expect(source == "track_lock")
    }

    // MARK: - CHECK 제약

    @Test("poi_mark.source 유효하지 않은 값 → CHECK 제약 위반")
    func poiMarkSourceInvalidValueThrows() throws {
        let db = try makeDatabase()
        let scanId = try insertScanSession(db: db)
        try insertKeyframe(db: db, scanId: scanId, seq: 1)
        let blob = Data(repeating: 0, count: 64)

        #expect(throws: (any Error).self) {
            try db.dbQueue.write { d in
                try d.execute(
                    sql: """
                    INSERT INTO poi_mark (scan_id, keyframe_seq, created_at, pose_matrix, tx, ty, tz, source)
                    VALUES (?, 1, 0, ?, 0, 0, 0, 'invalid')
                    """,
                    arguments: [scanId, blob]
                )
            }
        }
    }

    @Test("poi_mark.source 'manual' 허용")
    func poiMarkSourceManualAllowed() throws {
        let db = try makeDatabase()
        let scanId = try insertScanSession(db: db)
        try insertKeyframe(db: db, scanId: scanId, seq: 1)
        let blob = Data(repeating: 0, count: 64)

        try db.dbQueue.write { d in
            try d.execute(
                sql: """
                INSERT INTO poi_mark (scan_id, keyframe_seq, created_at, pose_matrix, tx, ty, tz, source)
                VALUES (?, 1, 0, ?, 0, 0, 0, 'manual')
                """,
                arguments: [scanId, blob]
            )
        }

        let source = try db.dbQueue.read { d in
            try String.fetchOne(d, sql: "SELECT source FROM poi_mark WHERE scan_id = ?", arguments: [scanId])
        }
        #expect(source == "manual")
    }

    // MARK: - v3 → v4 업그레이드 (기존 행 백필 확인)

    @Test("v3 DB → v4 migrate 후 기존 poi_mark row source = 'track_lock' 백필")
    func v3ToV4MigrationBackfillsTrackLockSource() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("scan_metadata.db")

        // v3 DB fixture 생성
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
                    track_id INTEGER,
                    label TEXT,
                    FOREIGN KEY (scan_id, keyframe_seq) REFERENCES keyframe_meta(scan_id, seq) ON DELETE CASCADE
                )
            """)
            try d.execute(sql: """
                CREATE TABLE poi_photo (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    poi_mark_id INTEGER NOT NULL REFERENCES poi_mark(id) ON DELETE CASCADE,
                    scan_id TEXT NOT NULL REFERENCES scan_session(id) ON DELETE CASCADE,
                    keyframe_seq INTEGER NOT NULL,
                    captured_at INTEGER NOT NULL,
                    bbox_x REAL, bbox_y REAL, bbox_w REAL, bbox_h REAL,
                    class_name TEXT NOT NULL,
                    confidence REAL NOT NULL,
                    FOREIGN KEY (scan_id, keyframe_seq) REFERENCES keyframe_meta(scan_id, seq) ON DELETE CASCADE
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
                    FOREIGN KEY (scan_id, keyframe_seq) REFERENCES keyframe_meta(scan_id, seq) ON DELETE CASCADE
                )
            """)
            try d.execute(sql: """
                CREATE TABLE yolo_detection (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    scan_id TEXT NOT NULL,
                    keyframe_seq INTEGER NOT NULL,
                    class_name TEXT NOT NULL, confidence REAL NOT NULL,
                    bbox_x REAL NOT NULL, bbox_y REAL NOT NULL, bbox_w REAL NOT NULL, bbox_h REAL NOT NULL,
                    mask_rle BLOB,
                    source TEXT NOT NULL DEFAULT 'on_device' CHECK(source IN ('on_device','server')),
                    track_id INTEGER,
                    FOREIGN KEY (scan_id, keyframe_seq) REFERENCES keyframe_meta(scan_id, seq) ON DELETE CASCADE
                )
            """)
            try d.execute(sql: """
                CREATE UNIQUE INDEX idx_poi_mark_unique_track
                    ON poi_mark(scan_id, track_id) WHERE track_id IS NOT NULL
            """)
            try d.execute(sql: "CREATE TABLE IF NOT EXISTS grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            try d.execute(sql: "INSERT INTO grdb_migrations VALUES ('v1')")
            try d.execute(sql: "INSERT INTO grdb_migrations VALUES ('v2')")
            try d.execute(sql: "INSERT INTO grdb_migrations VALUES ('v3')")
            try d.execute(sql: "PRAGMA user_version = 3")

            let scanId = "v3-scan-001"
            let blob = Data(repeating: 0, count: 64)
            try d.execute(
                sql: "INSERT INTO scan_session (id, started_at, device_model, app_version, state, keyframe_count) VALUES (?, 0, 'iPhone', '1.0', 'saved', 1)",
                arguments: [scanId]
            )
            try d.execute(
                sql: "INSERT INTO keyframe_meta (scan_id, seq, captured_at, image_path, pose_matrix, tx, ty, tz, tracking_state) VALUES (?, 1, 0, 'k/1.jpg', ?, 0, 0, 0, 'normal')",
                arguments: [scanId, blob]
            )
            try d.execute(
                sql: "INSERT INTO poi_mark (scan_id, keyframe_seq, created_at, pose_matrix, tx, ty, tz, track_id) VALUES (?, 1, 0, ?, 0, 0, 0, 10)",
                arguments: [scanId, blob]
            )
        }

        // v4 migrate
        let db = try ScanMetadataDatabase(dbURL: dbURL)

        let version = try db.dbQueue.read { d in try Int.fetchOne(d, sql: "PRAGMA user_version") }
        // Sprint 88 Cycle 6: v5/v6/v7/v8/v9/v9 자동 적용
        #expect(version == 9)

        // 기존 행은 source='track_lock' 백필
        let source = try db.dbQueue.read { d in
            try String.fetchOne(d, sql: "SELECT source FROM poi_mark WHERE scan_id = 'v3-scan-001'")
        }
        #expect(source == "track_lock")
    }

    // MARK: - poi_photo bbox NULL 허용 (회귀 방지)

}
