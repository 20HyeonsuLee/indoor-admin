import Testing
import Foundation
@testable import IndoorPathfinding

@Suite("ChunkManifest")
struct ChunkManifestTests {

    // MARK: - JSON round-trip

    @Test("Codable round-trip preserves all fields")
    func jsonRoundTrip() throws {
        let sessionId = UUID()
        let floorId = UUID()
        let started = Date(timeIntervalSince1970: 1_700_000_000)

        var manifest = ChunkManifest(
            scanSessionId: sessionId,
            floorId: floorId,
            chunkIndex: 2,
            startedAt: started,
            rtabmapDBPath: "rtabmap.db"
        )
        manifest.overlapKeyframes = 7
        manifest.endedAt = started.addingTimeInterval(90)
        manifest.uploadState = .done
        manifest.retryCount = 1
        manifest.serverChunkId = UUID()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ChunkManifest.self, from: data)

        #expect(decoded.scanSessionId == sessionId)
        #expect(decoded.floorId == floorId)
        #expect(decoded.chunkIndex == 2)
        #expect(decoded.overlapKeyframes == 7)
        #expect(decoded.uploadState == .done)
        #expect(decoded.retryCount == 1)
        #expect(decoded.serverChunkId == manifest.serverChunkId)
    }

    // MARK: - overlapWarning 계산

    @Test("overlapWarning is false when chunkIndex == 0")
    func overlapWarningFirstChunk() {
        var manifest = ChunkManifest(
            scanSessionId: UUID(),
            floorId: UUID(),
            chunkIndex: 0,
            startedAt: .now,
            rtabmapDBPath: "rtabmap.db"
        )
        manifest.overlapKeyframes = 0
        #expect(manifest.overlapWarning == false)
    }

    @Test("overlapWarning is true when keyframes < 5 for non-first chunk")
    func overlapWarningLowKeyframes() {
        var manifest = ChunkManifest(
            scanSessionId: UUID(),
            floorId: UUID(),
            chunkIndex: 1,
            startedAt: .now,
            rtabmapDBPath: "rtabmap.db"
        )
        manifest.overlapKeyframes = 3
        #expect(manifest.overlapWarning == true)
    }

    @Test("overlapWarning is false when keyframes >= 5")
    func overlapWarningEnoughKeyframes() {
        var manifest = ChunkManifest(
            scanSessionId: UUID(),
            floorId: UUID(),
            chunkIndex: 1,
            startedAt: .now,
            rtabmapDBPath: "rtabmap.db"
        )
        manifest.overlapKeyframes = 5
        #expect(manifest.overlapWarning == false)
    }

    // MARK: - expiresAt

    @Test("expiresAt is startedAt + 7 days")
    func expiresAt7Days() {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let manifest = ChunkManifest(
            scanSessionId: UUID(),
            floorId: UUID(),
            chunkIndex: 0,
            startedAt: started,
            rtabmapDBPath: "rtabmap.db"
        )
        let expected = started.addingTimeInterval(7 * 24 * 3600)
        #expect(abs(manifest.expiresAt.timeIntervalSince(expected)) < 1)
    }

    // MARK: - initial state

    @Test("initial uploadState is archiving")
    func initialState() {
        let manifest = ChunkManifest(
            scanSessionId: UUID(),
            floorId: UUID(),
            chunkIndex: 0,
            startedAt: .now,
            rtabmapDBPath: "rtabmap.db"
        )
        #expect(manifest.uploadState == .archiving)
        #expect(manifest.retryCount == 0)
        #expect(manifest.zipPath == nil)
        #expect(manifest.serverChunkId == nil)
    }
}
