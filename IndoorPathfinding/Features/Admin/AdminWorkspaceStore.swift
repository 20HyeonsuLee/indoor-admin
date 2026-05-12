import Foundation
import Observation

// MARK: - Domain Models

struct AdminBuilding: Identifiable, Hashable {
    var id: UUID
    var name: String
    var description: String?
    // F4: 서버 schema latitude/longitude 필드 (Optional<Double>)
    var latitude: Double?
    var longitude: Double?
    var status: String

    var displayName: String { name }
}

struct AdminFloor: Identifiable, Hashable {
    var id: UUID
    var buildingId: UUID
    var name: String
    var level: Int
    var hasPath: Bool

    var displayName: String {
        if level < 0 { return "B\(abs(level))F" }
        if level == 0 { return name.isEmpty ? "GF" : name }
        return name.isEmpty ? "\(level)F" : name
    }
}

struct AdminScanChunk: Identifiable, Hashable {
    enum ChunkStatus: String {
        case uploaded = "UPLOADED"
        case merged = "MERGED"
        case processing = "PROCESSING"
        case completed = "COMPLETED"
        case failed = "FAILED"
        case unknown = "UNKNOWN"

        init(raw: String) {
            self = ChunkStatus(rawValue: raw) ?? .unknown
        }

        var label: String {
            switch self {
            case .uploaded: return "업로드 완료"
            case .merged: return "병합됨"
            case .processing: return "처리 중"
            case .completed: return "빌드 완료"
            case .failed: return "실패"
            case .unknown: return "알 수 없음"
            }
        }

        var isSelectable: Bool {
            switch self {
            case .uploaded, .merged, .completed: return true
            default: return false
            }
        }
    }

    var id: UUID
    var floorId: UUID
    var scanId: UUID
    var fileName: String?
    var fileSize: Int?
    var status: ChunkStatus
    var active: Bool
    var uploadOrder: Int
}

struct AdminServerSettings: Hashable {
    var baseURLText: String
    var token: String

    static var `default`: AdminServerSettings {
        AdminServerSettings(baseURLText: "http://218.150.183.198:8080", token: "dev-token")
    }

    var baseURL: URL? {
        URL(string: baseURLText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func makeV1Client(session: URLSession = .shared) -> IndoorServerV1Client? {
        guard let baseURL else { return nil }
        return IndoorServerV1Client(baseURL: baseURL, token: token, session: session)
    }

    // 기존 코드와의 호환성 유지
    func makeClient() -> IndoorServerClient? {
        guard let baseURL else { return nil }
        return IndoorServerClient(baseURL: baseURL, token: token)
    }
}

// MARK: - Store

@Observable
@MainActor
final class AdminWorkspaceStore {
    // State
    var buildings: [AdminBuilding] = []
    var floors: [UUID: [AdminFloor]] = [UUID: [AdminFloor]]()   // buildingId → floors
    var chunks: [UUID: [AdminScanChunk]] = [UUID: [AdminScanChunk]]() // floorId → chunks
    var selectedBuildingId: UUID?
    var selectedFloorId: UUID?
    var selectedChunkIds: Set<UUID> = []
    var serverSettings: AdminServerSettings

    // UI state
    var isLoading: Bool = false
    var errorMessage: String?

    /// Sprint 88 cycle_7: 가장 최근 스캔 종료 후 로컬 저장된 ZIP URL.
    /// 자동 upload 차단 후 사용자가 Files 앱 또는 explicit upload에서 참조.
    /// @Observable 매크로로 자동 관찰 가능 — UI에서 변경 즉시 반영.
    var lastExportedZipURL: URL?  // @Published equivalent via @Observable

    // Merge/process state
    var mergeStatus: String?
    var processStatus: String?
    var processProgress: Double?

    private(set) var cache: AdminCacheDatabase

    init(
        cache: AdminCacheDatabase = AdminCacheDatabase.shared,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.cache = cache
        var settings = AdminServerSettings.default
        if let baseURLText = environment["INDOOR_SERVER_BASE_URL"], !baseURLText.isEmpty {
            settings.baseURLText = baseURLText
        }
        if let token = environment["INDOOR_SERVER_TOKEN"], !token.isEmpty {
            settings.token = token
        }
        serverSettings = settings

        // cache에서 buildings 로드 (cold start)
        if let cached = try? cache.fetchBuildings() {
            buildings = cached.map { c in
                AdminBuilding(
                    id: UUID(uuidString: c.id) ?? UUID(),
                    name: c.name,
                    description: c.description,
                    latitude: c.latitude,
                    longitude: c.longitude,
                    status: c.status
                )
            }
        }
    }

    /// URLSession override (테스트 전용). nil 이면 .shared 사용.
    var _testSessionOverride: URLSession?

    var v1Client: IndoorServerV1Client? {
        serverSettings.makeV1Client(session: _testSessionOverride ?? .shared)
    }

    var selectedBuilding: AdminBuilding? {
        guard let selectedBuildingId else { return nil }
        return buildings.first { $0.id == selectedBuildingId }
    }

    var selectedFloor: AdminFloor? {
        guard let selectedBuildingId, let selectedFloorId else { return nil }
        return floors[selectedBuildingId]?.first { $0.id == selectedFloorId }
    }

    var floorsForSelectedBuilding: [AdminFloor] {
        guard let id = selectedBuildingId else { return [] }
        return (floors[id] ?? []).sorted { $0.level < $1.level }
    }

    var chunksForSelectedFloor: [AdminScanChunk] {
        guard let id = selectedFloorId else { return [] }
        return (chunks[id] ?? []).sorted { $0.uploadOrder < $1.uploadOrder }
    }

    var selectedChunks: [AdminScanChunk] {
        guard let id = selectedFloorId else { return [] }
        return (chunks[id] ?? []).filter { selectedChunkIds.contains($0.id) }
    }

    var canMerge: Bool {
        !selectedChunkIds.isEmpty
    }

    // MARK: - Buildings

    func loadBuildings() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        guard let client = v1Client else {
            errorMessage = "서버 URL을 설정해주세요."
            return
        }
        do {
            let v1Buildings = try await client.listBuildings()
            let mapped = v1Buildings.map { b in
                AdminBuilding(
                    id: b.buildingId, name: b.name, description: b.description,
                    latitude: b.latitude, longitude: b.longitude, status: b.status
                )
            }
            buildings = mapped
            // cache upsert
            let cached = v1Buildings.map { b in
                CachedBuilding(
                    id: b.buildingId.uuidString,
                    name: b.name,
                    description: b.description,
                    latitude: b.latitude,
                    longitude: b.longitude,
                    status: b.status,
                    updatedAt: Date()
                )
            }
            try? cache.upsertBuildings(cached)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // F4: latitude/longitude 파라미터 추가
    func createBuilding(name: String, description: String?, latitude: Double? = nil, longitude: Double? = nil) async {
        guard let client = v1Client else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let b = try await client.createBuilding(name: name, description: description, latitude: latitude, longitude: longitude)
            let building = AdminBuilding(
                id: b.buildingId, name: b.name, description: b.description,
                latitude: b.latitude, longitude: b.longitude, status: b.status
            )
            buildings.append(building)
            try? cache.upsertBuilding(CachedBuilding(
                id: b.buildingId.uuidString, name: b.name, description: b.description,
                latitude: b.latitude, longitude: b.longitude, status: b.status, updatedAt: Date()
            ))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // F4: latitude/longitude 파라미터 추가
    func updateBuilding(_ building: AdminBuilding, name: String, description: String?, latitude: Double? = nil, longitude: Double? = nil) async {
        guard let client = v1Client else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let b = try await client.updateBuilding(id: building.id, name: name, description: description, latitude: latitude, longitude: longitude)
            if let index = buildings.firstIndex(where: { $0.id == building.id }) {
                buildings[index] = AdminBuilding(
                    id: b.buildingId, name: b.name, description: b.description,
                    latitude: b.latitude, longitude: b.longitude, status: b.status
                )
            }
            try? cache.upsertBuilding(CachedBuilding(
                id: b.buildingId.uuidString, name: b.name, description: b.description,
                latitude: b.latitude, longitude: b.longitude, status: b.status, updatedAt: Date()
            ))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteBuilding(_ building: AdminBuilding) async {
        guard let client = v1Client else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            try await client.deleteBuilding(id: building.id)
            buildings.removeAll { $0.id == building.id }
            floors.removeValue(forKey: building.id)
            try? cache.deleteBuilding(id: building.id.uuidString)
            if selectedBuildingId == building.id {
                selectedBuildingId = buildings.first?.id
                selectedFloorId = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Floors

    func loadFloors(buildingId: UUID) async {
        guard let client = v1Client else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let v1Floors = try await client.listFloors(buildingId: buildingId)
            let mapped = v1Floors.map { f in
                AdminFloor(id: f.floorId, buildingId: f.buildingId, name: f.name, level: f.level, hasPath: f.hasPath)
            }
            floors[buildingId] = mapped
            // cache upsert
            try? cache.upsertFloors(v1Floors.map { f in
                CachedFloor(id: f.floorId.uuidString, buildingId: f.buildingId.uuidString,
                            name: f.name, level: f.level, hasPath: f.hasPath, updatedAt: Date())
            })
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createFloor(buildingId: UUID, name: String, level: Int) async {
        guard let client = v1Client else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let f = try await client.createFloor(buildingId: buildingId, name: name, level: level)
            let floor = AdminFloor(id: f.floorId, buildingId: f.buildingId, name: f.name, level: f.level, hasPath: f.hasPath)
            floors[buildingId, default: []].append(floor)
            floors[buildingId]?.sort { $0.level < $1.level }
            try? cache.upsertFloor(CachedFloor(
                id: f.floorId.uuidString, buildingId: f.buildingId.uuidString,
                name: f.name, level: f.level, hasPath: f.hasPath, updatedAt: Date()
            ))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateFloor(_ floor: AdminFloor, name: String) async {
        guard let client = v1Client else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let f = try await client.updateFloor(id: floor.id, name: name)
            if var list = floors[floor.buildingId],
               let idx = list.firstIndex(where: { $0.id == floor.id }) {
                list[idx] = AdminFloor(
                    id: f.floorId, buildingId: f.buildingId,
                    name: f.name, level: f.level, hasPath: f.hasPath
                )
                floors[floor.buildingId] = list.sorted { $0.level < $1.level }
            }
            try? cache.upsertFloor(CachedFloor(
                id: f.floorId.uuidString, buildingId: f.buildingId.uuidString,
                name: f.name, level: f.level, hasPath: f.hasPath, updatedAt: Date()
            ))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteFloor(_ floor: AdminFloor) async {
        guard let client = v1Client else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            try await client.deleteFloor(id: floor.id)
            floors[floor.buildingId]?.removeAll { $0.id == floor.id }
            chunks.removeValue(forKey: floor.id)
            try? cache.deleteFloor(id: floor.id.uuidString)
            if selectedFloorId == floor.id {
                selectedFloorId = floors[floor.buildingId]?.first?.id
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Chunks

    func loadChunks(floorId: UUID) async {
        guard let client = v1Client else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let v1Chunks = try await client.listChunks(floorId: floorId)
            let mapped = v1Chunks.map { c in
                AdminScanChunk(
                    id: c.chunkId, floorId: c.floorId, scanId: c.scanId,
                    fileName: c.fileName, fileSize: c.fileSize,
                    status: .init(raw: c.status), active: c.active, uploadOrder: c.uploadOrder
                )
            }
            chunks[floorId] = mapped
            try? cache.upsertChunks(v1Chunks.map { c in
                CachedScanChunk(
                    id: c.chunkId.uuidString, floorId: c.floorId.uuidString, scanId: c.scanId.uuidString,
                    fileName: c.fileName, fileSize: c.fileSize,
                    status: c.status, active: c.active, uploadOrder: c.uploadOrder, uploadedAt: Date()
                )
            })
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func uploadChunk(floorId: UUID, fileURL: URL) async {
        guard let client = v1Client else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            // F5: zip 파일명 또는 manifest.json 에서 scan_id 자동 추출
            let extractedScanId = ZipScanIdExtractor.extractScanId(from: fileURL)
            let scanIdString = extractedScanId?.uuidString

            let c = try await client.uploadChunk(floorId: floorId, fileURL: fileURL, scanId: scanIdString)
            let chunk = AdminScanChunk(
                id: c.chunkId, floorId: c.floorId, scanId: c.scanId,
                fileName: c.fileName, fileSize: c.fileSize,
                status: .init(raw: c.status), active: c.active, uploadOrder: c.uploadOrder
            )
            chunks[floorId, default: []].removeAll { $0.scanId == chunk.scanId }
            chunks[floorId, default: []].append(chunk)
            chunks[floorId]?.sort { $0.uploadOrder < $1.uploadOrder }
            // F2: cache 동기화
            try? cache.upsertChunks([
                CachedScanChunk(
                    id: c.chunkId.uuidString, floorId: c.floorId.uuidString, scanId: c.scanId.uuidString,
                    fileName: c.fileName, fileSize: c.fileSize,
                    status: c.status, active: c.active, uploadOrder: c.uploadOrder, uploadedAt: Date()
                )
            ])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteChunk(_ chunk: AdminScanChunk) async {
        guard let client = v1Client else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            try await client.deleteChunk(floorId: chunk.floorId, chunkId: chunk.id)
            chunks[chunk.floorId]?.removeAll { $0.id == chunk.id }
            selectedChunkIds.remove(chunk.id)
            // F2: cache 동기화
            try? cache.deleteChunks(ids: [chunk.id.uuidString])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleChunkSelection(_ chunk: AdminScanChunk) {
        guard chunk.status.isSelectable else { return }
        if selectedChunkIds.contains(chunk.id) {
            selectedChunkIds.remove(chunk.id)
        } else {
            selectedChunkIds.insert(chunk.id)
        }
    }

    // MARK: - Merge & Process

    func mergeSelectedChunks(floorId: UUID) async {
        guard let client = v1Client, !selectedChunkIds.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        mergeStatus = nil
        defer { isLoading = false }
        do {
            let chunkIds = Array(selectedChunkIds)
            let result = try await client.mergeChunks(floorId: floorId, chunkIds: chunkIds)
            mergeStatus = result.status
            selectedChunkIds.removeAll()
            // merge 후 process 자동 트리거
            let processResult = try await client.processFloor(floorId: floorId)
            processStatus = processResult.status
            processProgress = processResult.progress
            // chunk list 갱신
            await loadChunks(floorId: floorId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func pollProcessStatus(floorId: UUID) async {
        guard let client = v1Client else { return }
        do {
            let result = try await client.processStatus(floorId: floorId)
            processStatus = result.status
            processProgress = result.progress
            if result.status == "COMPLETED" {
                // floor hasPath 갱신
                if let buildingId = selectedBuilding?.id {
                    if let idx = floors[buildingId]?.firstIndex(where: { $0.id == floorId }) {
                        floors[buildingId]?[idx].hasPath = true
                    }
                }
            }
        } catch {
            // polling 실패는 무시
        }
    }

    // MARK: - Helpers

    func selectBuilding(_ id: UUID) {
        selectedBuildingId = id
        selectedFloorId = nil
        selectedChunkIds = []
    }

    func selectFloor(_ id: UUID) {
        selectedFloorId = id
        selectedChunkIds = []
        mergeStatus = nil
        processStatus = nil
    }
}
