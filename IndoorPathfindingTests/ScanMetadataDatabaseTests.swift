import Testing
import Foundation
import GRDB
@testable import IndoorPathfinding

@Suite("ScanMetadataDatabase")
struct ScanMetadataDatabaseTests {

    func makeDatabase() throws -> ScanMetadataDatabase {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("scan_metadata.db")
        return try ScanMetadataDatabase(dbURL: dbURL)
    }

    @Test("migration 후 scan_session 테이블 존재")
    func tableExistsAfterMigration() throws {
        let db = try makeDatabase()
        let exists = try db.dbQueue.read { db in
            try db.tableExists("scan_session")
        }
        #expect(exists)
    }

    @Test("scan_session insert/select 왕복")
    func sessionInsertSelect() throws {
        let db = try makeDatabase()
        let scanId = UUID().uuidString
        var session = ScanSession(
            id: scanId,
            startedAt: 1_000_000,
            endedAt: nil,
            deviceModel: "iPhone15,2",
            appVersion: "1.0",
            state: .recording,
            keyframeCount: 0,
            notes: nil
        )
        try db.dbQueue.write { db in try session.save(db) }

        let fetched = try db.dbQueue.read { db in
            try ScanSession.fetchOne(db, key: scanId)
        }
        #expect(fetched?.id == scanId)
        #expect(fetched?.state == .recording)
        #expect(fetched?.keyframeCount == 0)
    }

    @Test("keyframe_count UPDATE")
    func keyframeCountUpdate() throws {
        let db = try makeDatabase()
        let scanId = UUID().uuidString
        var session = ScanSession(
            id: scanId, startedAt: 0, endedAt: nil,
            deviceModel: "test", appVersion: "1.0",
            state: .recording, keyframeCount: 0, notes: nil
        )
        try db.dbQueue.write { db in
            try session.save(db)
            try db.execute(
                sql: "UPDATE scan_session SET keyframe_count = keyframe_count + 1 WHERE id = ?",
                arguments: [scanId]
            )
        }
        let count = try db.dbQueue.read { db in
            try ScanSession.fetchOne(db, key: scanId)?.keyframeCount
        }
        #expect(count == 1)
    }

    @Test("state를 saved로 업데이트")
    func stateUpdateToSaved() throws {
        let db = try makeDatabase()
        let scanId = UUID().uuidString
        var session = ScanSession(
            id: scanId, startedAt: 0, endedAt: nil,
            deviceModel: "test", appVersion: "1.0",
            state: .recording, keyframeCount: 0, notes: nil
        )
        try db.dbQueue.write { db in
            try session.save(db)
            try db.execute(
                sql: "UPDATE scan_session SET state = 'saved', ended_at = ? WHERE id = ?",
                arguments: [Int64(1_000_000), scanId]
            )
        }
        let fetched = try db.dbQueue.read { db in
            try ScanSession.fetchOne(db, key: scanId)
        }
        #expect(fetched?.state == .saved)
        #expect(fetched?.endedAt != nil)
    }

    @Test("Sprint 65 v6: yolo_detection 테이블 DROP 됨")
    func yoloTableDropped() throws {
        let db = try makeDatabase()
        let exists = try db.dbQueue.read { db in
            try db.tableExists("yolo_detection")
        }
        #expect(!exists)
    }
}
