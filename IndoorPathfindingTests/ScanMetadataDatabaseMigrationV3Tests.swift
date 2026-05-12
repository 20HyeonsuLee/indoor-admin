import Testing
import Foundation
import GRDB
@testable import IndoorPathfinding

/// ScanMetadataDatabase v2 → v3 마이그레이션 검증.
@Suite("ScanMetadataDatabase Migration v3")
struct ScanMetadataDatabaseMigrationV3Tests {

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

    /// Sprint 65 v6: poi_mark.track_id 컬럼 제거. 매 호출 새 row insert.
    /// trackId 인자는 시그니처 호환만 유지 — DB 에는 기록 안 함.
    private func insertPoiMark(db: ScanMetadataDatabase, scanId: String, seq: Int, trackId: Int?) throws -> Int64 {
        _ = trackId
        let blob = Data(repeating: 0, count: 64)
        return try db.dbQueue.write { d in
            try d.execute(
                sql: """
                INSERT INTO poi_mark (scan_id, keyframe_seq, created_at, pose_matrix, tx, ty, tz, source)
                VALUES (?, ?, 0, ?, 0, 0, 0, 'manual')
                """,
                arguments: [scanId, seq, blob]
            )
            return d.lastInsertedRowID
        }
    }

    // MARK: - 기본 스키마 검증

    @Test("v3 마이그레이션 후 최신 user_version == 9 (v4/v5/v6/v7/v8/v9/v9/v9 연속 적용)")
    func userVersionIsLatest() throws {
        let db = try makeDatabase()
        let version = try db.dbQueue.read { d in
            try Int.fetchOne(d, sql: "PRAGMA user_version")
        }
        // Sprint 88 Cycle 6: v9 마이그레이션이 v4/v5/v6/v7 에 이어 자동 적용되므로 최종 버전은 8
        #expect(version == 9)
    }

    @Test("poi_mark에 label 컬럼 존재")
    func poiMarkHasLabelColumn() throws {
        let db = try makeDatabase()
        let columns = try db.dbQueue.read { d in
            try d.columns(in: "poi_mark").map { $0.name }
        }
        #expect(columns.contains("label"))
    }

    @Test("poi_photo 테이블 존재")
    func poiPhotoTableExists() throws {
        let db = try makeDatabase()
        let exists = try db.dbQueue.read { d in
            try d.tableExists("poi_photo")
        }
        #expect(exists)
    }

    // MARK: - v2 → v3 업그레이드

    @Test("v2 DB → v3 migrate 후 poi_mark row 보존")
    func v2ToV3MigrationPreservesPoiMarkRows() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("scan_metadata.db")

        // v2 DB fixture 직접 생성
        let rawQueue = try DatabaseQueue(path: dbURL.path)
        try rawQueue.write { d in
            // scan_session
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
            // keyframe_meta
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
            // poi_mark (v2: track_id 있음, label 없음)
            try d.execute(sql: """
                CREATE TABLE poi_mark (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    scan_id TEXT NOT NULL,
                    keyframe_seq INTEGER NOT NULL,
                    created_at INTEGER NOT NULL,
                    pose_matrix BLOB NOT NULL,
                    tx REAL NOT NULL, ty REAL NOT NULL, tz REAL NOT NULL,
                    track_id INTEGER,
                    FOREIGN KEY (scan_id, keyframe_seq) REFERENCES keyframe_meta(scan_id, seq) ON DELETE CASCADE
                )
            """)
            // branch_mark
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
            // yolo_detection
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
            // grdb_migrations
            try d.execute(sql: "CREATE TABLE IF NOT EXISTS grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            try d.execute(sql: "INSERT INTO grdb_migrations VALUES ('v1')")
            try d.execute(sql: "INSERT INTO grdb_migrations VALUES ('v2')")
            try d.execute(sql: "PRAGMA user_version = 2")

            // 데이터 삽입
            let scanId = "v2-scan-001"
            try d.execute(
                sql: "INSERT INTO scan_session (id, started_at, device_model, app_version, state, keyframe_count) VALUES (?, 0, 'iPhone', '1.0', 'saved', 1)",
                arguments: [scanId]
            )
            let blob = Data(repeating: 0, count: 64)
            try d.execute(
                sql: "INSERT INTO keyframe_meta (scan_id, seq, captured_at, image_path, pose_matrix, tx, ty, tz, tracking_state) VALUES (?, 1, 0, 'k/1.jpg', ?, 0, 0, 0, 'normal')",
                arguments: [scanId, blob]
            )
            try d.execute(
                sql: "INSERT INTO poi_mark (scan_id, keyframe_seq, created_at, pose_matrix, tx, ty, tz, track_id) VALUES (?, 1, 0, ?, 0, 0, 0, 10)",
                arguments: [scanId, blob]
            )
        }

        // v3 → v4 연속 migrate
        let db = try ScanMetadataDatabase(dbURL: dbURL)

        let version = try db.dbQueue.read { d in try Int.fetchOne(d, sql: "PRAGMA user_version") }
        // Sprint 88 Cycle 6: v4/v5/v6/v7/v8/v9/v9/v9 마이그레이션 자동 적용 → 최종 8
        #expect(version == 9)

        let poiCount = try db.dbQueue.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM poi_mark WHERE scan_id = 'v2-scan-001'") ?? 0
        }
        #expect(poiCount == 1)

        // label 컬럼이 NULL로 존재해야 함
        let label = try db.dbQueue.read { d in
            try String.fetchOne(d, sql: "SELECT label FROM poi_mark LIMIT 1")
        }
        #expect(label == nil)
    }

    // MARK: - UNIQUE 인덱스 동작

    // MARK: - poi_photo FK 동작

    @Test("poi_photo: 유효한 FK → insert 성공")
    func poiPhotoValidFKInsertSucceeds() throws {
        let db = try makeDatabase()
        let scanId = try insertScanSession(db: db)
        try insertKeyframe(db: db, scanId: scanId, seq: 1)
        let poiMarkId = try insertPoiMark(db: db, scanId: scanId, seq: 1, trackId: 1)

        try db.dbQueue.write { d in
            try d.execute(
                sql: """
                INSERT INTO poi_photo
                    (poi_mark_id, scan_id, keyframe_seq, captured_at, class_name, confidence)
                VALUES (?, ?, 1, 0, 'door', 0.9)
                """,
                arguments: [poiMarkId, scanId]
            )
        }

        let count = try db.dbQueue.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM poi_photo") ?? 0
        }
        #expect(count == 1)
    }

    @Test("poi_photo: 유효하지 않은 poi_mark_id → FK 위반 throw")
    func poiPhotoInvalidPoiMarkIdThrows() throws {
        let db = try makeDatabase()
        let scanId = try insertScanSession(db: db)
        try insertKeyframe(db: db, scanId: scanId, seq: 1)

        #expect(throws: (any Error).self) {
            try db.dbQueue.write { d in
                try d.execute(
                    sql: """
                    INSERT INTO poi_photo
                        (poi_mark_id, scan_id, keyframe_seq, captured_at, class_name, confidence)
                    VALUES (9999, ?, 1, 0, 'door', 0.9)
                    """,
                    arguments: [scanId]
                )
            }
        }
    }

    @Test("poi_photo: 유효하지 않은 (scan_id, keyframe_seq) → FK 위반 throw")
    func poiPhotoInvalidKeyframeSeqThrows() throws {
        let db = try makeDatabase()
        let scanId = try insertScanSession(db: db)
        try insertKeyframe(db: db, scanId: scanId, seq: 1)
        let poiMarkId = try insertPoiMark(db: db, scanId: scanId, seq: 1, trackId: 5)

        #expect(throws: (any Error).self) {
            try db.dbQueue.write { d in
                try d.execute(
                    sql: """
                    INSERT INTO poi_photo
                        (poi_mark_id, scan_id, keyframe_seq, captured_at, class_name, confidence)
                    VALUES (?, ?, 999, 0, 'door', 0.9)
                    """,
                    arguments: [poiMarkId, scanId]
                )
            }
        }
    }
}
