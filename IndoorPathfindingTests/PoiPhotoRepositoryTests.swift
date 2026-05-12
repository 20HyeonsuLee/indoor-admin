import Testing
import Foundation
import GRDB
@testable import IndoorPathfinding

/// PoiPhotoRepository 단위 테스트.
/// Sprint 65: bbox 인자 + poi_mark.track_id 제거 반영.
@Suite("PoiPhotoRepository")
struct PoiPhotoRepositoryTests {

    // MARK: - Helpers

    private func makeDB() throws -> ScanMetadataDatabase {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return try ScanMetadataDatabase(dbURL: tempDir.appendingPathComponent("test.db"))
    }

    private func seedScanAndKeyframe(db: ScanMetadataDatabase) throws -> (scanId: String, seq: Int) {
        let scanId = UUID().uuidString
        let seq = 1
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
                VALUES (?, ?, 1000, 'k/1.jpg', ?, 0, 0, 0, 'normal')
                """,
                arguments: [scanId, seq, blob]
            )
        }
        return (scanId, seq)
    }

    /// Sprint 65: poi_mark.track_id 컬럼 제거 — 매 호출 새 row.
    private func seedPoiMark(db: ScanMetadataDatabase, scanId: String, seq: Int) throws -> Int64 {
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

    // MARK: - Tests

    @Test("유효한 FK로 poi_photo insert 성공")
    func insertSucceedsWithValidFK() throws {
        let db = try makeDB()
        let repo = PoiPhotoRepository(db: db)
        let (scanId, seq) = try seedScanAndKeyframe(db: db)
        let poiMarkId = try seedPoiMark(db: db, scanId: scanId, seq: seq)

        let insertedId = try repo.insert(
            poiMarkId: poiMarkId,
            scanId: scanId,
            keyframeSeq: seq,
            capturedAt: 1000,
            className: "manual",
            confidence: 0.0
        )
        #expect(insertedId > 0)
    }

    @Test("유효하지 않은 poi_mark_id → FK 위반 throw")
    func insertFailsWithInvalidPoiMarkId() throws {
        let db = try makeDB()
        let repo = PoiPhotoRepository(db: db)
        let (scanId, seq) = try seedScanAndKeyframe(db: db)

        #expect(throws: (any Error).self) {
            try repo.insert(
                poiMarkId: 9999,
                scanId: scanId,
                keyframeSeq: seq,
                capturedAt: 1000,
                className: "manual",
                confidence: 0.0
            )
        }
    }

    @Test("유효하지 않은 (scan_id, keyframe_seq) → FK 위반 throw")
    func insertFailsWithInvalidKeyframeSeq() throws {
        let db = try makeDB()
        let repo = PoiPhotoRepository(db: db)
        let (scanId, seq) = try seedScanAndKeyframe(db: db)
        let poiMarkId = try seedPoiMark(db: db, scanId: scanId, seq: seq)

        #expect(throws: (any Error).self) {
            try repo.insert(
                poiMarkId: poiMarkId,
                scanId: scanId,
                keyframeSeq: 9999,
                capturedAt: 1000,
                className: "manual",
                confidence: 0.0
            )
        }
    }

    @Test("fetchAll: poi_mark_id로 조회 + id DESC 정렬")
    func fetchAllReturnsDescendingOrder() throws {
        let db = try makeDB()
        let repo = PoiPhotoRepository(db: db)
        let (scanId, seq) = try seedScanAndKeyframe(db: db)
        let poiMarkId = try seedPoiMark(db: db, scanId: scanId, seq: seq)

        _ = try repo.insert(
            poiMarkId: poiMarkId, scanId: scanId, keyframeSeq: seq,
            capturedAt: 1000, className: "manual", confidence: 0.0
        )
        _ = try repo.insert(
            poiMarkId: poiMarkId, scanId: scanId, keyframeSeq: seq,
            capturedAt: 2000, className: "manual", confidence: 0.0
        )

        let photos = try repo.fetchAll(poiMarkId: poiMarkId)
        #expect(photos.count == 2)
        // id DESC → 두 번째 insert가 먼저
        #expect(photos[0].capturedAt == 2000)
        #expect(photos[1].capturedAt == 1000)
    }

    @Test("다른 poi_mark_id는 조회되지 않음")
    func fetchAllFiltersOtherPoiMarkId() throws {
        let db = try makeDB()
        let repo = PoiPhotoRepository(db: db)
        let (scanId, seq) = try seedScanAndKeyframe(db: db)
        let id1 = try seedPoiMark(db: db, scanId: scanId, seq: seq)
        let id2 = try seedPoiMark(db: db, scanId: scanId, seq: seq)

        _ = try repo.insert(
            poiMarkId: id1, scanId: scanId, keyframeSeq: seq,
            capturedAt: 1000, className: "manual", confidence: 0.0
        )
        _ = try repo.insert(
            poiMarkId: id2, scanId: scanId, keyframeSeq: seq,
            capturedAt: 2000, className: "manual", confidence: 0.0
        )

        let photos = try repo.fetchAll(poiMarkId: id1)
        #expect(photos.count == 1)
        #expect(photos[0].className == "manual")
    }
}
