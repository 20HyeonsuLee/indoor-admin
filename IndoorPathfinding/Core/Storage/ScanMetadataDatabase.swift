import GRDB
import Foundation

/// scan_metadata.db 래퍼. Migration v1 포함.
/// `Documents/scans/{scan_id}/scan_metadata.db` 위치에 생성한다.
final class ScanMetadataDatabase {
    let dbQueue: DatabaseQueue

    init(dbURL: URL) throws {
        var config = Configuration()
        // SQLite는 기본적으로 FK enforcement가 OFF이므로 명시적으로 활성화한다.
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        dbQueue = try DatabaseQueue(path: dbURL.path, configuration: config)
        try migrate()
    }

    func backup(to destinationURL: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fm.fileExists(atPath: destinationURL.path) {
            try fm.removeItem(at: destinationURL)
        }

        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let destination = try DatabaseQueue(path: destinationURL.path, configuration: config)
        try dbQueue.backup(to: destination)
    }

    // MARK: - Migration

    private func migrate() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            // scan_session
            try db.create(table: "scan_session") { t in
                t.primaryKey("id", .text)
                t.column("started_at", .integer).notNull()
                t.column("ended_at", .integer)
                t.column("device_model", .text).notNull()
                t.column("app_version", .text).notNull()
                t.column("state", .text).notNull()
                    .check(sql: "state IN ('recording','saved','discarded')")
                t.column("keyframe_count", .integer).notNull().defaults(to: 0)
                t.column("notes", .text)
            }

            // keyframe_meta
            try db.create(table: "keyframe_meta") { t in
                t.column("scan_id", .text).notNull()
                    .references("scan_session", onDelete: .cascade)
                t.column("seq", .integer).notNull()
                t.column("captured_at", .integer).notNull()
                t.column("image_path", .text).notNull()
                t.column("pose_matrix", .blob).notNull()
                t.column("tx", .real).notNull()
                t.column("ty", .real).notNull()
                t.column("tz", .real).notNull()
                t.column("tracking_state", .text).notNull()
                t.column("rtabmap_node_id", .integer)
                t.primaryKey(["scan_id", "seq"])
            }
            try db.create(
                indexOn: "keyframe_meta",
                columns: ["scan_id", "captured_at"]
            )

            // poi_mark
            try db.create(table: "poi_mark") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("scan_id", .text).notNull()
                    .references("scan_session", onDelete: .cascade)
                t.column("keyframe_seq", .integer).notNull()
                t.column("created_at", .integer).notNull()
                t.column("pose_matrix", .blob).notNull()
                t.column("tx", .real).notNull()
                t.column("ty", .real).notNull()
                t.column("tz", .real).notNull()
            }

            // branch_mark
            try db.create(table: "branch_mark") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("scan_id", .text).notNull()
                    .references("scan_session", onDelete: .cascade)
                t.column("keyframe_seq", .integer).notNull()
                t.column("created_at", .integer).notNull()
                t.column("pose_matrix", .blob).notNull()
                t.column("tx", .real).notNull()
                t.column("ty", .real).notNull()
                t.column("tz", .real).notNull()
            }

            // yolo_detection: Sprint 2에서는 DDL만. row 미기록.
            try db.create(table: "yolo_detection") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("scan_id", .text).notNull()
                    .references("scan_session", onDelete: .cascade)
                t.column("keyframe_seq", .integer).notNull()
                t.column("class_name", .text).notNull()
                t.column("confidence", .real).notNull()
                t.column("bbox_x", .real).notNull()
                t.column("bbox_y", .real).notNull()
                t.column("bbox_w", .real).notNull()
                t.column("bbox_h", .real).notNull()
                t.column("mask_rle", .blob)
                t.column("source", .text).notNull().defaults(to: "on_device")
                    .check(sql: "source IN ('on_device','server')")
            }

            try db.execute(sql: "PRAGMA user_version = 1")
        }

        // MARK: Migration v2 — Sprint 8
        // 변경 내용:
        //   1. keyframe_meta_new: 기존과 동일 + (scan_id, captured_at) 인덱스 유지
        //   2. yolo_detection_new: 기존 필드 + 복합 FK(scan_id, keyframe_seq) → keyframe_meta + track_id
        //   3. poi_mark_new:       기존 필드 + 복합 FK + track_id
        //   4. branch_mark_new:    기존 필드 + 복합 FK
        //   5. 기존 row INSERT INTO _new SELECT * FROM _old (track_id는 NULL)
        //   6. DROP old, RENAME new → old
        //   7. PRAGMA user_version = 2
        migrator.registerMigration("v2") { db in

            // ── 1. keyframe_meta_new ──────────────────────────────────
            try db.create(table: "keyframe_meta_new") { t in
                t.column("scan_id", .text).notNull()
                    .references("scan_session", onDelete: .cascade)
                t.column("seq", .integer).notNull()
                t.column("captured_at", .integer).notNull()
                t.column("image_path", .text).notNull()
                t.column("pose_matrix", .blob).notNull()
                t.column("tx", .real).notNull()
                t.column("ty", .real).notNull()
                t.column("tz", .real).notNull()
                t.column("tracking_state", .text).notNull()
                t.column("rtabmap_node_id", .integer)
                t.primaryKey(["scan_id", "seq"])
            }
            try db.create(
                indexOn: "keyframe_meta_new",
                columns: ["scan_id", "captured_at"]
            )
            try db.execute(sql: """
                INSERT INTO keyframe_meta_new
                SELECT scan_id, seq, captured_at, image_path, pose_matrix,
                       tx, ty, tz, tracking_state, rtabmap_node_id
                FROM keyframe_meta
            """)
            try db.drop(table: "keyframe_meta")
            try db.rename(table: "keyframe_meta_new", to: "keyframe_meta")

            // ── 2. yolo_detection_new ─────────────────────────────────
            try db.create(table: "yolo_detection_new") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("scan_id", .text).notNull()
                t.column("keyframe_seq", .integer).notNull()
                t.column("class_name", .text).notNull()
                t.column("confidence", .real).notNull()
                t.column("bbox_x", .real).notNull()
                t.column("bbox_y", .real).notNull()
                t.column("bbox_w", .real).notNull()
                t.column("bbox_h", .real).notNull()
                t.column("mask_rle", .blob)
                t.column("source", .text).notNull().defaults(to: "on_device")
                    .check(sql: "source IN ('on_device','server')")
                t.column("track_id", .integer)
                t.foreignKey(["scan_id", "keyframe_seq"],
                             references: "keyframe_meta",
                             columns: ["scan_id", "seq"],
                             onDelete: .cascade)
            }
            try db.execute(sql: """
                INSERT INTO yolo_detection_new
                    (id, scan_id, keyframe_seq, class_name, confidence,
                     bbox_x, bbox_y, bbox_w, bbox_h, mask_rle, source, track_id)
                SELECT id, scan_id, keyframe_seq, class_name, confidence,
                       bbox_x, bbox_y, bbox_w, bbox_h, mask_rle, source, NULL
                FROM yolo_detection
            """)
            try db.drop(table: "yolo_detection")
            try db.rename(table: "yolo_detection_new", to: "yolo_detection")

            // ── 3. poi_mark_new ───────────────────────────────────────
            try db.create(table: "poi_mark_new") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("scan_id", .text).notNull()
                t.column("keyframe_seq", .integer).notNull()
                t.column("created_at", .integer).notNull()
                t.column("pose_matrix", .blob).notNull()
                t.column("tx", .real).notNull()
                t.column("ty", .real).notNull()
                t.column("tz", .real).notNull()
                t.column("track_id", .integer)
                t.foreignKey(["scan_id", "keyframe_seq"],
                             references: "keyframe_meta",
                             columns: ["scan_id", "seq"],
                             onDelete: .cascade)
            }
            try db.execute(sql: """
                INSERT INTO poi_mark_new
                    (id, scan_id, keyframe_seq, created_at, pose_matrix,
                     tx, ty, tz, track_id)
                SELECT id, scan_id, keyframe_seq, created_at, pose_matrix,
                       tx, ty, tz, NULL
                FROM poi_mark
            """)
            try db.drop(table: "poi_mark")
            try db.rename(table: "poi_mark_new", to: "poi_mark")

            // ── 4. branch_mark_new ────────────────────────────────────
            try db.create(table: "branch_mark_new") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("scan_id", .text).notNull()
                t.column("keyframe_seq", .integer).notNull()
                t.column("created_at", .integer).notNull()
                t.column("pose_matrix", .blob).notNull()
                t.column("tx", .real).notNull()
                t.column("ty", .real).notNull()
                t.column("tz", .real).notNull()
                t.foreignKey(["scan_id", "keyframe_seq"],
                             references: "keyframe_meta",
                             columns: ["scan_id", "seq"],
                             onDelete: .cascade)
            }
            try db.execute(sql: """
                INSERT INTO branch_mark_new
                    (id, scan_id, keyframe_seq, created_at, pose_matrix, tx, ty, tz)
                SELECT id, scan_id, keyframe_seq, created_at, pose_matrix, tx, ty, tz
                FROM branch_mark
            """)
            try db.drop(table: "branch_mark")
            try db.rename(table: "branch_mark_new", to: "branch_mark")

            try db.execute(sql: "PRAGMA user_version = 2")
        }

        // MARK: Migration v3 — Sprint 13
        // 변경 내용:
        //   1. poi_mark에 label TEXT NULL 컬럼 추가
        //   2. 부분 UNIQUE 인덱스: (scan_id, track_id) WHERE track_id IS NOT NULL
        //   3. poi_photo 테이블 신규 생성 + 인덱스 2개
        //   4. PRAGMA user_version = 3
        migrator.registerMigration("v3") { db in
            // 1. poi_mark에 label 컬럼 추가 (ALTER TABLE ADD COLUMN 허용)
            try db.execute(sql: "ALTER TABLE poi_mark ADD COLUMN label TEXT")

            // 2. 중복 (scan_id, track_id) 행 정리 — 같은 track_id가 있으면 최신만 유지
            let dupes = try Int64.fetchAll(db, sql: """
                SELECT id FROM poi_mark p1
                WHERE track_id IS NOT NULL
                  AND EXISTS (
                    SELECT 1 FROM poi_mark p2
                    WHERE p2.scan_id = p1.scan_id
                      AND p2.track_id = p1.track_id
                      AND p2.created_at > p1.created_at
                  )
            """)
            if !dupes.isEmpty {
                let ids = dupes.map { String($0) }.joined(separator: ",")
                try db.execute(sql: "DELETE FROM poi_mark WHERE id IN (\(ids))")
            }

            // 3. 부분 UNIQUE 인덱스 (track_id NOT NULL 행만)
            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_poi_mark_unique_track
                    ON poi_mark(scan_id, track_id)
                    WHERE track_id IS NOT NULL
            """)

            // 4. poi_photo 테이블 생성
            try db.create(table: "poi_photo") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("poi_mark_id", .integer).notNull()
                    .references("poi_mark", onDelete: .cascade)
                t.column("scan_id", .text).notNull()
                    .references("scan_session", onDelete: .cascade)
                t.column("keyframe_seq", .integer).notNull()
                t.column("captured_at", .integer).notNull()
                t.column("bbox_x", .real)
                t.column("bbox_y", .real)
                t.column("bbox_w", .real)
                t.column("bbox_h", .real)
                t.column("class_name", .text).notNull()
                t.column("confidence", .real).notNull()
                t.foreignKey(
                    ["scan_id", "keyframe_seq"],
                    references: "keyframe_meta",
                    columns: ["scan_id", "seq"],
                    onDelete: .cascade
                )
            }
            try db.create(indexOn: "poi_photo", columns: ["poi_mark_id"])
            try db.create(indexOn: "poi_photo", columns: ["scan_id", "keyframe_seq"])

            try db.execute(sql: "PRAGMA user_version = 3")
        }

        // MARK: Migration v4 — Sprint 14
        // 변경 내용:
        //   1. poi_mark에 source TEXT NOT NULL DEFAULT 'track_lock' CHECK(source IN ('track_lock','manual')) 추가
        //   2. 기존 row는 DEFAULT 'track_lock' 자동 백필
        //   3. PRAGMA user_version = 4
        migrator.registerMigration("v4") { db in
            try db.execute(sql: """
                ALTER TABLE poi_mark
                ADD COLUMN source TEXT NOT NULL DEFAULT 'track_lock'
                    CHECK(source IN ('track_lock','manual'))
            """)
            try db.execute(sql: "PRAGMA user_version = 4")
        }

        // MARK: Migration v5 — Sprint 49
        // 변경 내용 (사용자 결정 BLOCKER 7 + Codex BLOCKER 5):
        //   1. poi_photo에 image_blob BLOB NULL 컬럼 추가 — POI 마킹 시점에 jpeg encode → blob 저장.
        //   2. keyframes/ 폴더 자체를 export 에서 제거하지만 keyframe_meta.image_path 컬럼은
        //      그대로 유지(빈 문자열 허용). RTABMap.db Data 테이블이 keyframe image source-of-truth.
        //   3. PRAGMA user_version = 5
        migrator.registerMigration("v5") { db in
            try db.execute(sql: "ALTER TABLE poi_photo ADD COLUMN image_blob BLOB")
            try db.execute(sql: "PRAGMA user_version = 5")
        }

        // MARK: Migration v6 — Sprint 65
        // 변경 내용:
        //   1. yolo_detection 테이블 통째 DROP — YOLO + DetectionTracker 제거.
        //   2. poi_mark에서 track_id 컬럼 + 관련 UNIQUE 인덱스 제거 — Track Lock 폐기.
        //   3. poi_photo에서 bbox_x/y/w/h 컬럼 제거 — 수동 POI는 bbox 없음.
        //   4. interfloor_mark 테이블 신규 — Sprint 64 in-memory InterfloorMark 정식 영속화.
        //   5. PRAGMA user_version = 6
        // 의존: SQLite 3.35.0+ (iOS 16+) ALTER TABLE DROP COLUMN.
        migrator.registerMigration("v6") { db in
            // 1. yolo_detection 통째 DROP
            try db.execute(sql: "DROP TABLE IF EXISTS yolo_detection")

            // 2. poi_mark.track_id 제거 — 인덱스 먼저 DROP
            try db.execute(sql: "DROP INDEX IF EXISTS idx_poi_mark_unique_track")
            try db.execute(sql: "ALTER TABLE poi_mark DROP COLUMN track_id")

            // 3. poi_photo bbox 컬럼 4개 제거
            try db.execute(sql: "ALTER TABLE poi_photo DROP COLUMN bbox_x")
            try db.execute(sql: "ALTER TABLE poi_photo DROP COLUMN bbox_y")
            try db.execute(sql: "ALTER TABLE poi_photo DROP COLUMN bbox_w")
            try db.execute(sql: "ALTER TABLE poi_photo DROP COLUMN bbox_h")

            // 4. interfloor_mark 신규 (계단/엘리베이터/에스컬레이터 등 층간 연결 노드).
            //    keyframe_seq 시점의 ARKit pose를 그대로 저장. 서버 ingest 시
            //    Sprint 62 VerticalConnectorResolver의 connector_key 매칭에 prefix 사용.
            try db.create(table: "interfloor_mark") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("scan_id", .text).notNull()
                    .references("scan_session", onDelete: .cascade)
                t.column("keyframe_seq", .integer).notNull()
                t.column("created_at", .integer).notNull()
                t.column("connector_type", .text).notNull()
                    .check(sql: "connector_type IN ('elevator','escalator','stairs')")
                t.column("prefix", .text).notNull()
                t.column("pose_matrix", .blob).notNull()
                t.column("tx", .real).notNull()
                t.column("ty", .real).notNull()
                t.column("tz", .real).notNull()
                t.foreignKey(["scan_id", "keyframe_seq"],
                             references: "keyframe_meta",
                             columns: ["scan_id", "seq"],
                             onDelete: .cascade)
            }
            try db.create(indexOn: "interfloor_mark", columns: ["scan_id"])

            try db.execute(sql: "PRAGMA user_version = 6")
        }

        // MARK: Migration v7 — Sprint 88 Cycle 2
        // 변경 내용:
        //   1. branch_mark에 node_type TEXT NOT NULL DEFAULT 'corridor' 컬럼 추가
        //   2. branch_mark에 width_m REAL NULL 컬럼 추가 (corridor 폭, m 단위)
        //   3. branch_mark에 connect_hint TEXT NULL 컬럼 추가 ('proximity' or NULL)
        //   4. branch_mark에 connect_node_id TEXT NULL 컬럼 추가 (proximity 타겟 row id)
        //   5. branch_mark에 mark_session_id TEXT NULL 컬럼 추가 (corner cluster UUID)
        //   6. mark_session_id 인덱스 생성
        //   7. PRAGMA user_version = 7
        migrator.registerMigration("v7") { db in
            try db.execute(sql: """
                ALTER TABLE branch_mark ADD COLUMN node_type TEXT NOT NULL DEFAULT 'corridor'
                CHECK (node_type IN ('corridor','corner'))
            """)
            try db.execute(sql: "ALTER TABLE branch_mark ADD COLUMN width_m REAL")
            try db.execute(sql: "ALTER TABLE branch_mark ADD COLUMN connect_hint TEXT")
            try db.execute(sql: "ALTER TABLE branch_mark ADD COLUMN connect_node_id TEXT")
            try db.execute(sql: "ALTER TABLE branch_mark ADD COLUMN mark_session_id TEXT")
            try db.create(indexOn: "branch_mark", columns: ["mark_session_id"],
                          options: [.ifNotExists])
            try db.execute(sql: "PRAGMA user_version = 7")
        }

        // MARK: Migration v8 — Sprint 88 Cycle 6
        // 변경 내용:
        //   1. branch_mark / poi_mark / interfloor_mark 각각에 dx_local/dy_local/dz_local
        //      REAL NULL 컬럼 3개씩 추가 (총 9개 ALTER).
        //   2. 기존 v7 row 는 모두 NULL → server backfill 시 legacy 경로 (keyframe pose
        //      그대로 덮어쓰기) 로 회귀 안전.
        //   3. 신규 mark 는 dx_local = mark.world.x − keyframe_at_mark.world.x (y/z 동일)
        //      를 기록. cycle_4 floor projection / raycast 결과를 reprocess 후에도 보존.
        //   4. 회전은 별도 컬럼 추가하지 않는다 (cycle_4 단순화 원칙). server backfill 은
        //      keyframe optimized pose_matrix 의 회전을 그대로 사용하고 translation 만 보정.
        //   5. PRAGMA user_version = 8
        migrator.registerMigration("v8") { db in
            try db.execute(sql: "ALTER TABLE branch_mark      ADD COLUMN dx_local REAL")
            try db.execute(sql: "ALTER TABLE branch_mark      ADD COLUMN dy_local REAL")
            try db.execute(sql: "ALTER TABLE branch_mark      ADD COLUMN dz_local REAL")
            try db.execute(sql: "ALTER TABLE poi_mark         ADD COLUMN dx_local REAL")
            try db.execute(sql: "ALTER TABLE poi_mark         ADD COLUMN dy_local REAL")
            try db.execute(sql: "ALTER TABLE poi_mark         ADD COLUMN dz_local REAL")
            try db.execute(sql: "ALTER TABLE interfloor_mark  ADD COLUMN dx_local REAL")
            try db.execute(sql: "ALTER TABLE interfloor_mark  ADD COLUMN dy_local REAL")
            try db.execute(sql: "ALTER TABLE interfloor_mark  ADD COLUMN dz_local REAL")
            try db.execute(sql: "PRAGMA user_version = 8")
        }

        // MARK: Migration v9 — Sprint 89 Cycle 1
        // 변경 내용:
        //   1. branch_edge 테이블 신규 — MarkingState.edges 영속화.
        //   2. markingState.edges 의 모든 EdgeKind (sequential / proximity / transition /
        //      cornerPolygon) 를 finalize 직전에 INSERT. corner polygon close 시 last↔first
        //      edge 도 polygon_closed=1 로 표시.
        //   3. server 는 v9 edge 가 있으면 재계산 대신 그대로 사용. cornerPolygon kind 는
        //      routing map_edge 에서 제외하되 polygon 시각화 layer 로만 사용.
        //   4. PRAGMA user_version = 9
        migrator.registerMigration("v9") { db in
            try db.create(table: "branch_edge") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("scan_id", .text).notNull()
                    .references("scan_session", onDelete: .cascade)
                t.column("from_node_id", .text).notNull()
                t.column("to_node_id", .text).notNull()
                t.column("kind", .text).notNull()
                    .check(sql: "kind IN ('sequential','proximity','transition','cornerPolygon')")
                t.column("length_m", .double).notNull()
                t.column("mark_session_id", .text)         // cornerPolygon 한정
                t.column("polygon_closed", .integer)       // 0/1, 다른 kind 는 NULL
                t.column("created_at", .integer).notNull()
            }
            try db.create(indexOn: "branch_edge", columns: ["scan_id"], options: [.ifNotExists])
            try db.create(indexOn: "branch_edge", columns: ["mark_session_id"], options: [.ifNotExists])
            try db.execute(sql: "PRAGMA user_version = 9")
        }

        try migrator.migrate(dbQueue)
    }
}
