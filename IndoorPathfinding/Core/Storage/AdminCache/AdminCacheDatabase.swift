import GRDB
import Foundation
import OSLog

// MARK: - Models

struct CachedBuilding: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "cached_buildings"

    var id: String
    var name: String
    var description: String?
    var latitude: Double?
    var longitude: Double?
    var status: String
    var updatedAt: Date

    var uuid: UUID? { UUID(uuidString: id) }
}

struct CachedFloor: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "cached_floors"

    var id: String
    var buildingId: String
    var name: String
    var level: Int
    var hasPath: Bool
    var updatedAt: Date

    var uuid: UUID? { UUID(uuidString: id) }
    var buildingUUID: UUID? { UUID(uuidString: buildingId) }
}

struct CachedScanChunk: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "cached_scan_chunks"

    var id: String
    var floorId: String
    var scanId: String
    var fileName: String?
    var fileSize: Int?
    var status: String
    var active: Bool
    var uploadOrder: Int
    var uploadedAt: Date

    var uuid: UUID? { UUID(uuidString: id) }
    var floorUUID: UUID? { UUID(uuidString: floorId) }
}

struct CachedFloorGraph: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "cached_floor_graphs"
    static let persistenceConflictPolicy = PersistenceConflictPolicy(
        insert: .replace,
        update: .replace
    )

    var floorId: String
    var jsonBlob: String
    var updatedAt: Date
}

// MARK: - Database

/// AdminCacheDatabase — 서버 fetch 결과를 로컬 캐시.
/// 서버가 SSOT. 앱 재실행 시 마지막 화면 즉시 복원용.
final class AdminCacheDatabase {

    private static let log = Logger(subsystem: "ac.koreatech.indoorpathfinding", category: "AdminCacheDatabase")

    /// F3: try! 제거 — 디스크 초기화 실패 시 in-memory fallback 으로 앱 crash 방지.
    static let shared: AdminCacheDatabase = makeShared()

    private static func makeShared() -> AdminCacheDatabase {
        do {
            let url = try FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("admin_cache.db")
            return try AdminCacheDatabase(dbURL: url)
        } catch {
            log.error("AdminCacheDatabase 디스크 초기화 실패, in-memory fallback 사용: \(error)")
            return (try? AdminCacheDatabase.inMemoryFallback()) ?? AdminCacheDatabase.crashSafe()
        }
    }

    /// in-memory DB fallback — 앱 재실행 시 데이터가 사라지지만 crash 는 없음.
    static func inMemoryFallback() throws -> AdminCacheDatabase {
        let db = AdminCacheDatabase()
        return db
    }

    private static func crashSafe() -> AdminCacheDatabase {
        // inMemoryFallback 도 실패하는 극단적 상황 — 빈 shell 반환
        log.error("AdminCacheDatabase in-memory fallback 도 실패. 캐시 비활성 상태로 진행.")
        return AdminCacheDatabase()
    }

    let dbQueue: DatabaseQueue

    init(dbURL: URL) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        dbQueue = try DatabaseQueue(path: dbURL.path, configuration: config)
        try migrate()
    }

    /// in-memory DB 초기화 (fallback 용).
    init() {
        // 실패 불가 경로이므로 try! 허용 (in-memory는 파일 I/O 없음)
        dbQueue = try! DatabaseQueue()  // swiftlint:disable:this force_try
        try? migrate()
    }

    // MARK: - Migration

    private func migrate() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "cached_buildings", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("description", .text)
                t.column("latitude", .double)
                t.column("longitude", .double)
                t.column("status", .text).notNull().defaults(to: "DRAFT")
                t.column("updatedAt", .datetime).notNull()
            }

            try db.create(table: "cached_floors", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("buildingId", .text).notNull()
                    .references("cached_buildings", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("level", .integer).notNull()
                t.column("hasPath", .boolean).notNull().defaults(to: false)
                t.column("updatedAt", .datetime).notNull()
            }

            try db.create(table: "cached_scan_chunks", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("floorId", .text).notNull()
                t.column("scanId", .text).notNull()
                t.column("fileName", .text)
                t.column("fileSize", .integer)
                t.column("status", .text).notNull()
                t.column("active", .boolean).notNull().defaults(to: false)
                t.column("uploadOrder", .integer).notNull().defaults(to: 0)
                t.column("uploadedAt", .datetime).notNull()
            }

            try db.create(table: "cached_floor_graphs", ifNotExists: true) { t in
                t.column("floorId", .text).primaryKey()
                t.column("jsonBlob", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
        }

        try migrator.migrate(dbQueue)
    }

    // MARK: - Buildings

    func upsertBuilding(_ building: CachedBuilding) throws {
        try dbQueue.write { db in
            try building.save(db)
        }
    }

    func upsertBuildings(_ buildings: [CachedBuilding]) throws {
        try dbQueue.write { db in
            for b in buildings {
                try b.save(db)
            }
        }
    }

    func fetchBuildings() throws -> [CachedBuilding] {
        try dbQueue.read { db in
            try CachedBuilding.order(Column("name")).fetchAll(db)
        }
    }

    func deleteBuilding(id: String) throws {
        try dbQueue.write { db in
            _ = try CachedBuilding.deleteOne(db, key: id)
        }
    }

    // MARK: - Floors

    func upsertFloor(_ floor: CachedFloor) throws {
        try dbQueue.write { db in
            try floor.save(db)
        }
    }

    func upsertFloors(_ floors: [CachedFloor]) throws {
        try dbQueue.write { db in
            for f in floors {
                try f.save(db)
            }
        }
    }

    func fetchFloors(buildingId: String) throws -> [CachedFloor] {
        try dbQueue.read { db in
            try CachedFloor
                .filter(Column("buildingId") == buildingId)
                .order(Column("level"))
                .fetchAll(db)
        }
    }

    func deleteFloor(id: String) throws {
        try dbQueue.write { db in
            _ = try CachedFloor.deleteOne(db, key: id)
        }
    }

    func deleteFloors(buildingId: String) throws {
        try dbQueue.write { db in
            _ = try CachedFloor
                .filter(Column("buildingId") == buildingId)
                .deleteAll(db)
        }
    }

    // MARK: - Scan Chunks

    func upsertChunks(_ chunks: [CachedScanChunk]) throws {
        try dbQueue.write { db in
            for c in chunks {
                try c.save(db)
            }
        }
    }

    func fetchChunks(floorId: String) throws -> [CachedScanChunk] {
        try dbQueue.read { db in
            try CachedScanChunk
                .filter(Column("floorId") == floorId)
                .order(Column("uploadOrder"))
                .fetchAll(db)
        }
    }

    func deleteChunks(floorId: String) throws {
        try dbQueue.write { db in
            _ = try CachedScanChunk
                .filter(Column("floorId") == floorId)
                .deleteAll(db)
        }
    }

    /// 특정 id 목록에 해당하는 청크만 삭제한다 (F2).
    func deleteChunks(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try dbQueue.write { db in
            _ = try CachedScanChunk
                .filter(ids.contains(Column("id")))
                .deleteAll(db)
        }
    }

    // MARK: - Floor Graph

    func upsertFloorGraph(_ graph: CachedFloorGraph) throws {
        try dbQueue.write { db in
            try graph.save(db)
        }
    }

    func fetchFloorGraph(floorId: String) throws -> CachedFloorGraph? {
        try dbQueue.read { db in
            try CachedFloorGraph.fetchOne(db, key: floorId)
        }
    }
}
