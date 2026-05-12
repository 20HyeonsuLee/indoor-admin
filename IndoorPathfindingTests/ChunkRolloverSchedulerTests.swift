import Testing
import Foundation
@testable import IndoorPathfinding

// MARK: - Mocks

@MainActor
final class MockChunkBridge: ChunkRolloverScheduler.BridgeProtocol {
    var rolloverCallCount: Int = 0
    var closeCallCount: Int = 0
    var lastCurrentScanURL: URL?
    var lastNextScanURL: URL?
    /// ADR D3 테스트용: rollover 후 새 DB에 있는 node 수 stub.
    var stubbedNodeCount: Int = 0

    func rolloverChunk(
        currentScanURL: URL,
        nextScanURL: URL
    ) async throws -> (closedDBURL: URL, nodeStamps: [(nodeId: Int, stamp: Double)]) {
        rolloverCallCount += 1
        lastCurrentScanURL = currentScanURL
        lastNextScanURL = nextScanURL
        // stub: rtabmap.db 생성
        let dbURL = currentScanURL.appendingPathComponent("rtabmap.db")
        FileManager.default.createFile(atPath: dbURL.path, contents: Data())
        return (closedDBURL: dbURL, nodeStamps: [])
    }

    func closeCurrentChunk(
        currentScanURL: URL
    ) async throws -> (closedDBURL: URL, nodeStamps: [(nodeId: Int, stamp: Double)]) {
        closeCallCount += 1
        lastCurrentScanURL = currentScanURL
        let dbURL = currentScanURL.appendingPathComponent("rtabmap.db")
        FileManager.default.createFile(atPath: dbURL.path, contents: Data())
        return (closedDBURL: dbURL, nodeStamps: [])
    }

    /// ADR D3: stubbedNodeCount를 currentNodeCount로 노출.
    var currentNodeCount: Int { stubbedNodeCount }
}

@MainActor
final class MockThrottle: ChunkRolloverScheduler.ThrottleProtocol {
    var pauseCallCount: Int = 0
    var resumeCallCount: Int = 0
    var lastAggressiveFlag: Bool = false
    var endAggressiveModeCallCount: Int = 0
    private(set) var isPaused: Bool = false

    func pause() {
        pauseCallCount += 1
        isPaused = true
    }

    func resume(aggressive: Bool) {
        resumeCallCount += 1
        lastAggressiveFlag = aggressive
        isPaused = false
    }

    func endAggressiveMode() {
        endAggressiveModeCallCount += 1
    }
}

@MainActor
final class MockUploadQueue: ChunkRolloverScheduler.UploadQueueProtocol {
    var enqueuedManifests: [ChunkManifest] = []
    var enqueuedDirectories: [URL] = []

    func enqueue(manifest: ChunkManifest, chunkDirectory: URL) async throws {
        enqueuedManifests.append(manifest)
        enqueuedDirectories.append(chunkDirectory)
    }
}

// MARK: - Tests

@MainActor
@Suite("ChunkRolloverScheduler")
struct ChunkRolloverSchedulerTests {

    /// 임시 디렉터리 + session-level scan_metadata.db를 사전 생성하고 ScanFileStore를 반환한다.
    /// ADR D1 도입 후 start()/performRollover()가 scan_metadata.db의 존재를 전제한다.
    private func makeFileStoreWithMetadata() throws -> (fileStore: ScanFileStore, tempRoot: URL) {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChunkRolloverTests-\(UUID().uuidString)")
        let scanId = UUID().uuidString
        let fileStore = ScanFileStore(scanId: scanId, documentsRoot: tempRoot)
        try FileManager.default.createDirectory(at: fileStore.scanDirectory, withIntermediateDirectories: true)
        try Data(repeating: 0xAA, count: 64).write(to: fileStore.databaseURL)
        return (fileStore, tempRoot)
    }

    func makeScheduler(
        bridge: MockChunkBridge,
        throttle: MockThrottle,
        uploadQueue: MockUploadQueue,
        overlapWindowSeconds: TimeInterval = 0.05   // 테스트에서는 짧은 window 사용
    ) throws -> (scheduler: ChunkRolloverScheduler, tempRoot: URL) {
        let (fileStore, tempRoot) = try makeFileStoreWithMetadata()
        let scheduler = ChunkRolloverScheduler(
            scanSessionId: UUID(),
            floorId: UUID(),
            fileStore: fileStore,
            bridge: bridge,
            throttle: throttle,
            uploadQueue: uploadQueue,
            overlapWindowSeconds: overlapWindowSeconds
        )
        return (scheduler, tempRoot)
    }

    @Test("start() sets currentChunkIndex to 0")
    func startSetsChunk0() async throws {
        let bridge = MockChunkBridge()
        let throttle = MockThrottle()
        let uploadQueue = MockUploadQueue()
        let (scheduler, tempRoot) = try makeScheduler(bridge: bridge, throttle: throttle, uploadQueue: uploadQueue)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try scheduler.start()
        #expect(scheduler.currentChunkIndex == 0)
        await scheduler.stop()
    }

    @Test("stop() enqueues last chunk to upload queue")
    func stopEnqueuesLastChunk() async throws {
        let bridge = MockChunkBridge()
        let throttle = MockThrottle()
        let uploadQueue = MockUploadQueue()
        let (scheduler, tempRoot) = try makeScheduler(bridge: bridge, throttle: throttle, uploadQueue: uploadQueue)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try scheduler.start()
        await scheduler.stop()
        #expect(uploadQueue.enqueuedManifests.count >= 1)
        #expect(bridge.closeCallCount == 1)
        let lastManifest = uploadQueue.enqueuedManifests.last
        #expect(lastManifest?.chunkIndex == 0)
    }

    @Test("stop() enqueues manifest with correct floorId and sessionId")
    func stopManifestFields() async throws {
        let sessionId = UUID()
        let floorId = UUID()
        let bridge = MockChunkBridge()
        let throttle = MockThrottle()
        let uploadQueue = MockUploadQueue()
        let (fileStore, tempRoot) = try makeFileStoreWithMetadata()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let scheduler = ChunkRolloverScheduler(
            scanSessionId: sessionId,
            floorId: floorId,
            fileStore: fileStore,
            bridge: bridge,
            throttle: throttle,
            uploadQueue: uploadQueue
        )
        try scheduler.start()
        await scheduler.stop()
        let manifest = uploadQueue.enqueuedManifests.last
        #expect(manifest?.scanSessionId == sessionId)
        #expect(manifest?.floorId == floorId)
    }

    // MARK: - ADR D3: overlapKeyframes 계수 검증

    @Test("performRollover() records overlapKeyframes from bridge.currentNodeCount")
    func rolloverRecordsOverlapKeyframes() async throws {
        let bridge = MockChunkBridge()
        let throttle = MockThrottle()
        let uploadQueue = MockUploadQueue()
        // overlapWindowSeconds=0.05 — 50ms로 단축해 테스트 속도 유지
        let (scheduler, tempRoot) = try makeScheduler(bridge: bridge, throttle: throttle, uploadQueue: uploadQueue, overlapWindowSeconds: 0.05)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try scheduler.start()

        // aggressive window 종료 시점에 bridge.currentNodeCount = 7을 반환하도록 설정
        bridge.stubbedNodeCount = 7

        // performRollover는 internal이므로 @testable import로 직접 호출
        await scheduler.performRollover()

        // overlap window(50ms) + enqueue Task 전파 대기
        try await Task.sleep(nanoseconds: 200_000_000)  // 200ms

        // chunk_0 manifest(closingIndex=0)가 enqueue됐는지 확인
        let rolloverManifest = uploadQueue.enqueuedManifests.first { $0.chunkIndex == 0 }
        #expect(rolloverManifest != nil, "rollover 후 chunk_0 manifest가 enqueue되어야 한다")
        #expect(rolloverManifest?.overlapKeyframes == 7,
                "overlapKeyframes는 bridge.currentNodeCount(7)와 같아야 한다")
        #expect(rolloverManifest?.overlapWarning == false,
                "overlapKeyframes >= 5이면 overlapWarning은 false여야 한다")

        await scheduler.stop()
    }

    @Test("performRollover() sets overlapWarning=true when overlapKeyframes < 5 on chunkIndex > 0")
    func rolloverSetsOverlapWarningWhenLow() async throws {
        let bridge = MockChunkBridge()
        let throttle = MockThrottle()
        let uploadQueue = MockUploadQueue()
        let (scheduler, tempRoot) = try makeScheduler(bridge: bridge, throttle: throttle, uploadQueue: uploadQueue, overlapWindowSeconds: 0.05)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try scheduler.start()

        // 1차 rollover: chunk_0 → chunk_1 (chunk_0은 chunkIndex==0이라 overlapWarning 미적용)
        bridge.stubbedNodeCount = 4
        await scheduler.performRollover()
        try await Task.sleep(nanoseconds: 200_000_000)

        // 2차 rollover: chunk_1 → chunk_2 (chunk_1은 chunkIndex==1, overlapKeyframes < 5 → overlapWarning true)
        bridge.stubbedNodeCount = 4
        await scheduler.performRollover()
        try await Task.sleep(nanoseconds: 200_000_000)

        let chunk1Manifest = uploadQueue.enqueuedManifests.first { $0.chunkIndex == 1 }
        #expect(chunk1Manifest != nil, "2차 rollover 후 chunk_1 manifest가 enqueue되어야 한다")
        #expect(chunk1Manifest?.overlapKeyframes == 4)
        #expect(chunk1Manifest?.overlapWarning == true,
                "overlapKeyframes < 5이고 chunkIndex > 0이면 overlapWarning은 true여야 한다")

        await scheduler.stop()
    }

    // MARK: - ADR D1: scan_metadata.db snapshot 통합 시나리오

    @Test("start() 후 chunk_0 dir에 scan_metadata.db가 존재한다")
    func startCreatesMetadataSnapshotInChunk0() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChunkRolloverD1-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let scanId = UUID().uuidString
        let fileStore = ScanFileStore(scanId: scanId, documentsRoot: tempRoot)

        // session-level scan_metadata.db를 미리 생성한다
        try FileManager.default.createDirectory(at: fileStore.scanDirectory, withIntermediateDirectories: true)
        try Data(repeating: 0xAA, count: 128).write(to: fileStore.databaseURL)

        let bridge = MockChunkBridge()
        let throttle = MockThrottle()
        let uploadQueue = MockUploadQueue()

        let scheduler = ChunkRolloverScheduler(
            scanSessionId: UUID(),
            floorId: UUID(),
            fileStore: fileStore,
            bridge: bridge,
            throttle: throttle,
            uploadQueue: uploadQueue
        )

        try scheduler.start()
        await scheduler.stop()

        let linkURL = fileStore.chunkDirectory(chunkIndex: 0)
            .appendingPathComponent("scan_metadata.db")
        #expect(FileManager.default.fileExists(atPath: linkURL.path),
                "chunk_0 dir에 scan_metadata.db snapshot이 있어야 한다")
    }

    @Test("performRollover() 후 닫힌 chunk dir에 scan_metadata.db snapshot이 갱신된다")
    func rolloverRefreshesMetadataSnapshotInClosedChunk() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChunkRolloverD1Rollover-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let scanId = UUID().uuidString
        let fileStore = ScanFileStore(scanId: scanId, documentsRoot: tempRoot)

        // session-level scan_metadata.db를 미리 생성한다
        try FileManager.default.createDirectory(at: fileStore.scanDirectory, withIntermediateDirectories: true)
        try Data(repeating: 0xBB, count: 128).write(to: fileStore.databaseURL)

        let bridge = MockChunkBridge()
        let throttle = MockThrottle()
        let uploadQueue = MockUploadQueue()

        let scheduler = ChunkRolloverScheduler(
            scanSessionId: UUID(),
            floorId: UUID(),
            fileStore: fileStore,
            bridge: bridge,
            throttle: throttle,
            uploadQueue: uploadQueue,
            overlapWindowSeconds: 0.05
        )

        try scheduler.start()
        await scheduler.performRollover()
        await scheduler.stop()

        let linkURLChunk0 = fileStore.chunkDirectory(chunkIndex: 0)
            .appendingPathComponent("scan_metadata.db")
        #expect(FileManager.default.fileExists(atPath: linkURLChunk0.path),
                "rollover 후 닫힌 chunk_0 dir에 scan_metadata.db snapshot이 있어야 한다")

        let linkURLChunk1 = fileStore.chunkDirectory(chunkIndex: 1)
            .appendingPathComponent("scan_metadata.db")
        #expect(FileManager.default.fileExists(atPath: linkURLChunk1.path),
                "stop 후 마지막 chunk_1 dir에 scan_metadata.db snapshot이 있어야 한다")
    }
}
