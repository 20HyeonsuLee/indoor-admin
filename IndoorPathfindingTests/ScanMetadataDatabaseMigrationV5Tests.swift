import Testing
import Foundation
import GRDB
@testable import IndoorPathfinding

/// ScanMetadataDatabase v4 → v5 마이그레이션 검증 (Sprint 49).
@Suite("ScanMetadataDatabase Migration v5")
struct ScanMetadataDatabaseMigrationV5Tests {

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

    // MARK: - 기본 스키마 검증

    @Test("v5 마이그레이션 후 user_version == 9 (Sprint 88 v6/v7/v8/v9 연속 적용)")
    func userVersionIsFive() throws {
        let db = try makeDatabase()
        let version = try db.dbQueue.read { d in
            try Int.fetchOne(d, sql: "PRAGMA user_version")
        }
        #expect(version == 9)
    }

    @Test("poi_photo 에 image_blob 컬럼 존재")
    func poiPhotoHasImageBlobColumn() throws {
        let db = try makeDatabase()
        let columns = try db.dbQueue.read { d in
            try d.columns(in: "poi_photo").map { $0.name }
        }
        #expect(columns.contains("image_blob"))
    }

    @Test("poi_photo image_blob NULL insert 허용")
    func poiPhotoImageBlobNullAllowed() throws {
        let db = try makeDatabase()
        let scanId = try insertScanSession(db: db)
        try insertKeyframe(db: db, scanId: scanId, seq: 1)
        let blob = Data(repeating: 0, count: 64)

        let poiMarkId = try db.dbQueue.write { d -> Int64 in
            try d.execute(
                sql: """
                INSERT INTO poi_mark (scan_id, keyframe_seq, created_at, pose_matrix, tx, ty, tz)
                VALUES (?, 1, 0, ?, 0, 0, 0)
                """,
                arguments: [scanId, blob]
            )
            return d.lastInsertedRowID
        }

        try db.dbQueue.write { d in
            try d.execute(
                sql: """
                INSERT INTO poi_photo (poi_mark_id, scan_id, keyframe_seq, captured_at,
                                       class_name, confidence, image_blob)
                VALUES (?, ?, 1, 0, 'manual', 0, NULL)
                """,
                arguments: [poiMarkId, scanId]
            )
        }

        let count = try db.dbQueue.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM poi_photo WHERE image_blob IS NULL") ?? 0
        }
        #expect(count == 1)
    }

    @Test("poi_photo image_blob BLOB insert 허용")
    func poiPhotoImageBlobInsertAllowed() throws {
        let db = try makeDatabase()
        let scanId = try insertScanSession(db: db)
        try insertKeyframe(db: db, scanId: scanId, seq: 1)
        let pose = Data(repeating: 0, count: 64)
        let imageBytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46]) // jpeg-like prefix

        let poiMarkId = try db.dbQueue.write { d -> Int64 in
            try d.execute(
                sql: """
                INSERT INTO poi_mark (scan_id, keyframe_seq, created_at, pose_matrix, tx, ty, tz)
                VALUES (?, 1, 0, ?, 0, 0, 0)
                """,
                arguments: [scanId, pose]
            )
            return d.lastInsertedRowID
        }

        try db.dbQueue.write { d in
            try d.execute(
                sql: """
                INSERT INTO poi_photo (poi_mark_id, scan_id, keyframe_seq, captured_at,
                                       class_name, confidence, image_blob)
                VALUES (?, ?, 1, 0, 'door', 0.9, ?)
                """,
                arguments: [poiMarkId, scanId, imageBytes]
            )
        }

        let stored = try db.dbQueue.read { d in
            try Data.fetchOne(d, sql: "SELECT image_blob FROM poi_photo WHERE poi_mark_id = ?",
                              arguments: [poiMarkId])
        }
        #expect(stored == imageBytes)
    }

    // MARK: - v4 → v5 업그레이드

    @Test("v4 DB → v5 migrate 시 기존 poi_photo 행은 image_blob = NULL")
    func v4ToV5MigrationBackfillsNullImageBlob() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("scan_metadata.db")

        // v4 DB fixture 생성
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
                    source TEXT NOT NULL DEFAULT 'track_lock'
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
                    bbox_x REAL, bbox_y REAL, bbox_w REAL, bbox_h REAL,
                    class_name TEXT NOT NULL,
                    confidence REAL NOT NULL,
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
                CREATE TABLE yolo_detection (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    scan_id TEXT NOT NULL,
                    keyframe_seq INTEGER NOT NULL,
                    class_name TEXT NOT NULL, confidence REAL NOT NULL,
                    bbox_x REAL NOT NULL, bbox_y REAL NOT NULL, bbox_w REAL NOT NULL, bbox_h REAL NOT NULL,
                    mask_rle BLOB,
                    source TEXT NOT NULL DEFAULT 'on_device' CHECK(source IN ('on_device','server')),
                    track_id INTEGER,
                    FOREIGN KEY (scan_id, keyframe_seq) REFERENCES keyframe_meta(scan_id, seq)
                        ON DELETE CASCADE
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
            try d.execute(sql: "INSERT INTO grdb_migrations VALUES ('v4')")
            try d.execute(sql: "PRAGMA user_version = 4")

            let scanId = "v4-scan-001"
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
            try d.execute(
                sql: """
                INSERT INTO poi_photo (poi_mark_id, scan_id, keyframe_seq, captured_at,
                                       class_name, confidence)
                VALUES (1, ?, 1, 0, 'door', 0.9)
                """,
                arguments: [scanId]
            )
        }

        // v5 migrate
        let db = try ScanMetadataDatabase(dbURL: dbURL)

        let version = try db.dbQueue.read { d in try Int.fetchOne(d, sql: "PRAGMA user_version") }
        #expect(version == 9)

        // 기존 행은 image_blob NULL
        let imageBlob = try db.dbQueue.read { d in
            try Data.fetchOne(d, sql: "SELECT image_blob FROM poi_photo WHERE scan_id = 'v4-scan-001'")
        }
        #expect(imageBlob == nil)
    }

    // MARK: - ManifestWriter deterministic 검증 (BLOCKER 3)

    @Test("ManifestWriter: 동일 입력 → byte-level 동일 출력")
    func manifestWriterDeterministic() throws {
        let tempDir1 = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir1, withIntermediateDirectories: true)
        let tempDir2 = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir2, withIntermediateDirectories: true)

        let manifest = ManifestWriter.make(
            scanId: "abc-123",
            rtabmapAcceptedFrameCount: 128,
            sidecarKeyframeMetaCount: 284,
            clientAppVersion: "1.2.0"
        )
        let url1 = try ManifestWriter.write(scanDirectory: tempDir1, manifest: manifest)
        let url2 = try ManifestWriter.write(scanDirectory: tempDir2, manifest: manifest)

        let bytes1 = try Data(contentsOf: url1)
        let bytes2 = try Data(contentsOf: url2)
        #expect(bytes1 == bytes2)
    }

    @Test("ManifestWriter: dropped_reject_frame_image_count = sidecar - accepted")
    func manifestWriterDroppedFrameCount() throws {
        let manifest = ManifestWriter.make(
            scanId: "abc",
            rtabmapAcceptedFrameCount: 128,
            sidecarKeyframeMetaCount: 284,
            clientAppVersion: "1.0"
        )
        #expect(manifest.droppedRejectFrameImageCount == 156)
        #expect(manifest.keyframesIncluded == false)
        #expect(manifest.keyframeImageSource == "rtabmap_db_data_table")
        #expect(manifest.poiImageSource == "poi_photo_image_blob")
        #expect(manifest.metadataVersion == 6)
    }

    // MARK: - Sprint 67 v7 — raw_video_recording manifest

    @Test("ManifestWriter v7: video_path/poses_path + intrinsics + 60fps hevc")
    func manifestWriterV7Fields() throws {
        let manifest = ManifestWriter.makeV7(
            scanId: "scan-v7-001",
            sidecarKeyframeMetaCount: 3000,
            poseRecordCount: 36000,
            intrinsicsFx: 1500.0,
            intrinsicsFy: 1500.0,
            intrinsicsCx: 960.0,
            intrinsicsCy: 540.0,
            clientAppVersion: "2.0.0"
        )
        #expect(manifest.metadataVersion == 9)
        #expect(manifest.mode == "raw_video_recording")
        #expect(manifest.videoPath == "scan.mp4")
        #expect(manifest.posesPath == "poses.bin")
        #expect(manifest.videoCodec == "hevc")
        #expect(manifest.videoFpsNominal == 60)
        #expect(manifest.poseRecordCount == 36000)
        #expect(manifest.intrinsicsFx == 1500.0)
        #expect(manifest.intrinsicsCx == 960.0)
        #expect(manifest.keyframeImageSource == "video_frames")
        #expect(manifest.poiImageSource == "poi_photo_image_blob")
        #expect(manifest.keyframesIncluded == false)
        #expect(manifest.rtabmapReprocessed == false)
    }

    @Test("ManifestWriter v7: 동일 입력 → byte-level 동일 출력 (deterministic)")
    func manifestWriterV7Deterministic() throws {
        let tempDir1 = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir1, withIntermediateDirectories: true)
        let tempDir2 = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir2, withIntermediateDirectories: true)

        let manifest = ManifestWriter.makeV7(
            scanId: "scan-v7-002",
            sidecarKeyframeMetaCount: 3000,
            poseRecordCount: 36000,
            intrinsicsFx: 1500, intrinsicsFy: 1500,
            intrinsicsCx: 960, intrinsicsCy: 540,
            clientAppVersion: "2.0.0"
        )
        let url1 = try ManifestWriter.write(scanDirectory: tempDir1, manifest: manifest)
        let url2 = try ManifestWriter.write(scanDirectory: tempDir2, manifest: manifest)
        #expect(try Data(contentsOf: url1) == Data(contentsOf: url2))
    }
}
