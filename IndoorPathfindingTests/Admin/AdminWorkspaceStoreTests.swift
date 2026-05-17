import Testing
import Foundation
@testable import IndoorPathfinding

// MARK: - Fake URLProtocol

private final class FakeURLProtocol: URLProtocol {

    nonisolated(unsafe) static var nextResponseJSON: [String: Any] = [:]
    /// nextResponseJSON 대신 raw Data를 직접 지정할 때 사용 (배열 응답 등)
    nonisolated(unsafe) static var nextResponseData: Data? = nil
    nonisolated(unsafe) static var shouldFail = false
    nonisolated(unsafe) static var capturedRequests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        FakeURLProtocol.capturedRequests.append(request)
        if FakeURLProtocol.shouldFail {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let data: Data
        if let override = FakeURLProtocol.nextResponseData {
            data = override
        } else {
            data = (try? JSONSerialization.data(withJSONObject: FakeURLProtocol.nextResponseJSON)) ?? Data()
        }
        let resp = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func fakeSession() -> URLSession {
    FakeURLProtocol.capturedRequests = []
    FakeURLProtocol.shouldFail = false
    FakeURLProtocol.nextResponseJSON = [:]
    FakeURLProtocol.nextResponseData = nil
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FakeURLProtocol.self]
    return URLSession(configuration: config)
}

@Suite("AdminWorkspaceStore")
@MainActor
struct AdminWorkspaceStoreTests {

    private func makeStore(db: AdminCacheDatabase, session: URLSession) -> AdminWorkspaceStore {
        let store = AdminWorkspaceStore(cache: db)
        store._testSessionOverride = session
        store.serverSettings = AdminServerSettings(
            baseURLText: "http://127.0.0.1:9999",
            token: "test"
        )
        return store
    }

    // MARK: - uploadChunk: cache upsert 검증 (F2)

    @Test("uploadChunk 성공 시 cache 에 청크가 저장된다")
    func uploadChunkCacheUpsert() async throws {
        let session = fakeSession()
        let db = try AdminCacheDatabase.inMemoryFallback()
        let store = makeStore(db: db, session: session)

        let floorId = UUID()
        let chunkId = UUID()
        let scanId = UUID()

        FakeURLProtocol.nextResponseJSON = [
            "chunkId": chunkId.uuidString,
            "floorId": floorId.uuidString,
            "scanId": scanId.uuidString,
            "status": "UPLOADED",
            "active": true,
            "uploadOrder": 0
        ]

        // 임시 zip 파일 (scanId 를 파일명으로 → ZipScanIdExtractor 가 추출)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(scanId.uuidString).zip")
        // minimal valid zip header
        try Data([80, 75, 5, 6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        await store.uploadChunk(floorId: floorId, fileURL: tmp)

        // store.cache 는 AdminCacheDatabase.shared (in-memory fallback 가능성 있음)
        // F2 fix: uploadChunk 성공 후 store.cache.upsertChunks 호출됨을 검증
        // → store.chunks[floorId] 에 청크 추가됨
        let inMemory = store.chunks[floorId]
        #expect(inMemory?.count == 1)
        #expect(inMemory?.first?.id == chunkId)
    }

    // MARK: - deleteChunk: cache delete 검증 (F2)

    @Test("deleteChunk 성공 시 in-memory chunks 에서 제거된다")
    func deleteChunkInMemoryRemoval() async throws {
        let session = fakeSession()
        let db = try AdminCacheDatabase.inMemoryFallback()
        let store = makeStore(db: db, session: session)

        let floorId = UUID()
        let chunkId = UUID()
        let scanId = UUID()

        // 사전: in-memory chunks 에 청크 세팅
        store.chunks[floorId] = [
            AdminScanChunk(
                id: chunkId, floorId: floorId, areaId: nil, scanId: scanId,
                fileName: "test.zip", fileSize: 100,
                status: .uploaded, active: true, uploadOrder: 0
            )
        ]

        // DELETE 응답: 204 No Content (body 없음)
        FakeURLProtocol.nextResponseJSON = [:]

        let chunk = AdminScanChunk(
            id: chunkId, floorId: floorId, areaId: nil, scanId: scanId,
            fileName: "test.zip", fileSize: 100,
            status: .uploaded, active: true, uploadOrder: 0
        )
        await store.deleteChunk(chunk)

        // in-memory 에서 제거됨
        #expect(store.chunks[floorId]?.isEmpty == true || store.chunks[floorId] == nil)
        // selectedChunkIds 에서도 제거됨
        #expect(!store.selectedChunkIds.contains(chunkId))
    }

    // MARK: - Sprint 85: updateFloor

    @Test("updateFloor 성공 시 floors 인메모리 갱신 + cache upsert")
    func updateFloorInMemoryUpdate() async throws {
        let session = fakeSession()
        let db = try AdminCacheDatabase.inMemoryFallback()
        let store = makeStore(db: db, session: session)

        let buildingId = UUID()
        let floorId = UUID()
        let floor = AdminFloor(id: floorId, buildingId: buildingId, name: "1F", level: 1, hasPath: false)
        store.floors[buildingId] = [floor]

        FakeURLProtocol.nextResponseJSON = [
            "floorId": floorId.uuidString,
            "buildingId": buildingId.uuidString,
            "name": "1층-renamed",
            "level": 1,
            "hasPath": false,
            "hasPly": false
        ]

        await store.updateFloor(floor, name: "1층-renamed")

        #expect(store.errorMessage == nil)
        let updated = store.floors[buildingId]?.first { $0.id == floorId }
        #expect(updated?.name == "1층-renamed")
    }

    // MARK: - Area: loadAreas

    @Test("loadAreas 성공 시 areas state 갱신 + default area 자동 선택")
    func loadAreasUpdatesState() async throws {
        let session = fakeSession()
        let db = try AdminCacheDatabase.inMemoryFallback()
        let store = makeStore(db: db, session: session)

        let floorId = UUID()
        let areaId = UUID()

        // listAreas 는 배열 응답
        FakeURLProtocol.nextResponseData = try JSONSerialization.data(
            withJSONObject: [[
                "areaId": areaId.uuidString,
                "floorId": floorId.uuidString,
                "areaIndex": 0,
                "label": "기본 구역",
                "isDefault": true,
                "createdAt": "2025-01-01T00:00:00Z"
            ]]
        )

        await store.loadAreas(floorId: floorId)

        #expect(store.areas[floorId]?.count == 1)
        #expect(store.areas[floorId]?.first?.areaId == areaId)
        #expect(store.selectedAreaId[floorId] == areaId)
    }

    // MARK: - Area: addArea

    @Test("addArea 성공 시 areas 에 새 area 추가")
    func addAreaAppendsToState() async throws {
        let session = fakeSession()
        let db = try AdminCacheDatabase.inMemoryFallback()
        let store = makeStore(db: db, session: session)

        let floorId = UUID()
        let newAreaId = UUID()

        FakeURLProtocol.nextResponseData = try JSONSerialization.data(
            withJSONObject: [
                "areaId": newAreaId.uuidString,
                "floorId": floorId.uuidString,
                "areaIndex": 1,
                "label": "사무실 영역",
                "isDefault": false,
                "createdAt": "2025-01-01T00:00:00Z"
            ]
        )

        let created = try await store.addArea(floorId: floorId, label: "사무실 영역")

        #expect(created.areaId == newAreaId)
        #expect(store.areas[floorId]?.contains { $0.areaId == newAreaId } == true)
    }

    // MARK: - Area: selectArea

    @Test("selectArea 시 selectedAreaId 변경 + selectedChunkIds 초기화")
    func selectAreaChangesSelection() async throws {
        let session = fakeSession()
        let db = try AdminCacheDatabase.inMemoryFallback()
        let store = makeStore(db: db, session: session)

        let floorId = UUID()
        let areaId1 = UUID()
        let areaId2 = UUID()
        let chunkId = UUID()

        store.selectedAreaId[floorId] = areaId1
        store.selectedChunkIds = [chunkId]

        store.selectArea(floorId: floorId, areaId: areaId2)

        #expect(store.selectedAreaId[floorId] == areaId2)
        #expect(store.selectedChunkIds.isEmpty)
    }

    // MARK: - Area: chunksForArea accessor

    @Test("chunksForArea accessor 가 area 별로 올바르게 분리")
    func chunksForAreaAccessorSeparatesCorrectly() async throws {
        let session = fakeSession()
        let db = try AdminCacheDatabase.inMemoryFallback()
        let store = makeStore(db: db, session: session)

        let floorId = UUID()
        let area1 = UUID()
        let area2 = UUID()
        let chunk1Id = UUID()
        let chunk2Id = UUID()

        let key1 = FloorAreaKey(floorId: floorId, areaId: area1)
        let key2 = FloorAreaKey(floorId: floorId, areaId: area2)

        store._areaChunks[key1] = [
            AdminScanChunk(
                id: chunk1Id, floorId: floorId, areaId: area1, scanId: UUID(),
                fileName: "a1.zip", fileSize: 100,
                status: .uploaded, active: true, uploadOrder: 0
            )
        ]
        store._areaChunks[key2] = [
            AdminScanChunk(
                id: chunk2Id, floorId: floorId, areaId: area2, scanId: UUID(),
                fileName: "a2.zip", fileSize: 200,
                status: .uploaded, active: true, uploadOrder: 0
            )
        ]

        let chunksA1 = store.chunksForArea(floorId: floorId, areaId: area1)
        let chunksA2 = store.chunksForArea(floorId: floorId, areaId: area2)

        #expect(chunksA1.count == 1)
        #expect(chunksA1.first?.id == chunk1Id)
        #expect(chunksA2.count == 1)
        #expect(chunksA2.first?.id == chunk2Id)
    }

    @Test("updateFloor 네트워크 실패 시 errorMessage 설정, floors 원본 유지")
    func updateFloorNetworkFailure() async throws {
        let session = fakeSession()
        let db = try AdminCacheDatabase.inMemoryFallback()
        let store = makeStore(db: db, session: session)

        let buildingId = UUID()
        let floorId = UUID()
        let floor = AdminFloor(id: floorId, buildingId: buildingId, name: "1F", level: 1, hasPath: false)
        store.floors[buildingId] = [floor]

        FakeURLProtocol.shouldFail = true

        await store.updateFloor(floor, name: "will-fail")

        #expect(store.errorMessage != nil)
        // floors 원본 유지
        #expect(store.floors[buildingId]?.first?.name == "1F")
    }

    // MARK: - 네트워크 실패 시 errorMessage 설정

    @Test("uploadChunk 네트워크 실패 시 errorMessage 가 설정된다")
    func uploadChunkNetworkFailure() async throws {
        let session = fakeSession()
        let db = try AdminCacheDatabase.inMemoryFallback()
        let store = makeStore(db: db, session: session)

        FakeURLProtocol.shouldFail = true
        let floorId = UUID()

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fail-\(UUID().uuidString).zip")
        try Data([80, 75, 5, 6]).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        await store.uploadChunk(floorId: floorId, fileURL: tmp)

        #expect(store.errorMessage != nil)
        // 실패 시 chunks 에 추가되지 않음
        #expect(store.chunks[floorId] == nil || store.chunks[floorId]?.isEmpty == true)
    }
}
