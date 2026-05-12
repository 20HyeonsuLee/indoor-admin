import Testing
import Foundation
import GRDB
@testable import IndoorPathfinding

@Suite("AdminCacheDatabase")
struct AdminCacheDatabaseTests {

    // MARK: - Helpers

    /// in-memory DB 인스턴스 생성 (각 테스트 격리)
    private func makeDB() throws -> AdminCacheDatabase {
        return try AdminCacheDatabase.inMemoryFallback()
    }

    // MARK: - Migration

    @Test("v1 migration: expected tables exist")
    func migrationTablesExist() throws {
        let db = try makeDB()
        let tables = try db.dbQueue.read { grdb -> [String] in
            let rows = try Row.fetchAll(
                grdb,
                sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
            )
            return rows.map { $0["name"] as String }
        }
        #expect(tables.contains("cached_buildings"))
        #expect(tables.contains("cached_floors"))
        #expect(tables.contains("cached_scan_chunks"))
        #expect(tables.contains("cached_floor_graphs"))
    }

    // MARK: - Buildings round-trip

    @Test("upsertBuildings / fetchBuildings round-trip")
    func buildingRoundTrip() throws {
        let db = try makeDB()
        let b = CachedBuilding(
            id: UUID().uuidString,
            name: "테스트 빌딩",
            description: "desc",
            latitude: 36.7,
            longitude: 127.0,
            status: "DRAFT",
            updatedAt: Date()
        )
        try db.upsertBuildings([b])
        let fetched = try db.fetchBuildings()
        #expect(fetched.count == 1)
        #expect(fetched[0].name == "테스트 빌딩")
    }

    // MARK: - Chunks filter

    @Test("upsertChunks / fetchChunks filter by floorId")
    func chunkFilterByFloor() throws {
        let db = try makeDB()
        let floorA = UUID().uuidString
        let floorB = UUID().uuidString

        let chunkA = CachedScanChunk(
            id: UUID().uuidString, floorId: floorA, scanId: UUID().uuidString,
            fileName: "a.zip", fileSize: 1000,
            status: "UPLOADED", active: true, uploadOrder: 0, uploadedAt: Date()
        )
        let chunkB = CachedScanChunk(
            id: UUID().uuidString, floorId: floorB, scanId: UUID().uuidString,
            fileName: "b.zip", fileSize: 2000,
            status: "UPLOADED", active: true, uploadOrder: 0, uploadedAt: Date()
        )
        try db.upsertChunks([chunkA, chunkB])

        let resultA = try db.fetchChunks(floorId: floorA)
        let resultB = try db.fetchChunks(floorId: floorB)
        #expect(resultA.count == 1)
        #expect(resultB.count == 1)
        #expect(resultA[0].fileName == "a.zip")
        #expect(resultB[0].fileName == "b.zip")
    }

    // MARK: - deleteChunks(ids:) partial delete

    @Test("deleteChunks(ids:) 부분 삭제")
    func chunkPartialDelete() throws {
        let db = try makeDB()
        let floorId = UUID().uuidString
        let id1 = UUID().uuidString
        let id2 = UUID().uuidString

        let c1 = CachedScanChunk(
            id: id1, floorId: floorId, scanId: UUID().uuidString,
            fileName: "c1.zip", fileSize: 100,
            status: "UPLOADED", active: true, uploadOrder: 0, uploadedAt: Date()
        )
        let c2 = CachedScanChunk(
            id: id2, floorId: floorId, scanId: UUID().uuidString,
            fileName: "c2.zip", fileSize: 200,
            status: "UPLOADED", active: true, uploadOrder: 1, uploadedAt: Date()
        )
        try db.upsertChunks([c1, c2])
        try db.deleteChunks(ids: [id1])

        let remaining = try db.fetchChunks(floorId: floorId)
        #expect(remaining.count == 1)
        #expect(remaining[0].id == id2)
    }

    // MARK: - in-memory fallback

    @Test("inMemoryFallback: 초기화 성공 + 데이터 읽기 가능")
    func inMemoryFallbackWorks() throws {
        let db = try AdminCacheDatabase.inMemoryFallback()
        // 빈 DB 에서 fetch 는 빈 배열 반환
        let buildings = try db.fetchBuildings()
        #expect(buildings.isEmpty)
    }
}
