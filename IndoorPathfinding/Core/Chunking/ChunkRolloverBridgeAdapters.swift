import Foundation

// MARK: - RTABMapBridge → ChunkRolloverScheduler.BridgeProtocol

#if !targetEnvironment(simulator)
extension RTABMapBridge: ChunkRolloverScheduler.BridgeProtocol {
    /// RTAB-Map native save/destroy/open lifecycle을 background queue에서 실행한다.
    func rolloverChunk(
        currentScanURL: URL,
        nextScanURL: URL
    ) async throws -> (closedDBURL: URL, nodeStamps: [(nodeId: Int, stamp: Double)]) {
        try await rolloverChunkAsync(currentScanURL: currentScanURL, nextScanURL: nextScanURL)
    }

    func closeCurrentChunk(
        currentScanURL: URL
    ) async throws -> (closedDBURL: URL, nodeStamps: [(nodeId: Int, stamp: Double)]) {
        try await closeCurrentChunkAsync(currentScanURL: currentScanURL)
    }

    /// ADR D3: aggressive window 종료 시점의 새 DB node 수. stats.nodeCount를 그대로 노출.
    var currentNodeCount: Int { stats.nodeCount }
}
#endif

// MARK: - StubRTABMapSLAMSink stub for ChunkRolloverScheduler (simulator)

/// simulator에서 ChunkRolloverScheduler가 동작할 수 있도록 no-op bridge를 제공한다.
@MainActor
final class StubChunkRolloverBridge: ChunkRolloverScheduler.BridgeProtocol {
    /// 테스트/simulator 용 stub node count. 기본값 0.
    var stubbedNodeCount: Int = 0

    func rolloverChunk(
        currentScanURL: URL,
        nextScanURL: URL
    ) async throws -> (closedDBURL: URL, nodeStamps: [(nodeId: Int, stamp: Double)]) {
        // Stub: rtabmap.db가 없어도 동작하도록 빈 파일 생성.
        let dbURL = currentScanURL.appendingPathComponent("rtabmap.db")
        if !FileManager.default.fileExists(atPath: dbURL.path) {
            FileManager.default.createFile(atPath: dbURL.path, contents: Data())
        }
        return (closedDBURL: dbURL, nodeStamps: [])
    }

    func closeCurrentChunk(
        currentScanURL: URL
    ) async throws -> (closedDBURL: URL, nodeStamps: [(nodeId: Int, stamp: Double)]) {
        let dbURL = currentScanURL.appendingPathComponent("rtabmap.db")
        if !FileManager.default.fileExists(atPath: dbURL.path) {
            FileManager.default.createFile(atPath: dbURL.path, contents: Data())
        }
        return (closedDBURL: dbURL, nodeStamps: [])
    }

    /// ADR D3: stub이므로 stubbedNodeCount를 반환한다.
    var currentNodeCount: Int { stubbedNodeCount }
}
