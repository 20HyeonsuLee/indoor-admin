import Foundation
import OSLog

/// 30초 wall-clock timer 기반 chunk rollover 오케스트레이터.
/// ADR D1/D2 — 시간 기반 chunk, 독립 DB + 시간 overlap window.
///
/// 책임:
/// - 30s timer 가동/정지.
/// - rollover 시퀀스: throttle pause → 0.5s drain → bridge.rolloverChunk → upload enqueue → aggressive resume.
/// - 1s overlap window 후 normal mode 복귀.
///
/// MainActor에서만 사용한다.
@MainActor
final class ChunkRolloverScheduler {

    // MARK: - Dependencies (protocol 기반 — 테스트에서 mock 주입)

    /// RTABMapBridge rolloverChunk 책임.
    @MainActor
    protocol BridgeProtocol: AnyObject {
        func rolloverChunk(
            currentScanURL: URL,
            nextScanURL: URL
        ) async throws -> (closedDBURL: URL, nodeStamps: [(nodeId: Int, stamp: Double)])
        func closeCurrentChunk(
            currentScanURL: URL
        ) async throws -> (closedDBURL: URL, nodeStamps: [(nodeId: Int, stamp: Double)])
        /// rollover 직후 새 DB가 현재까지 받은 node 수. overlap keyframe 계수에 사용.
        var currentNodeCount: Int { get }
    }

    /// KeyframeCaptureThrottle 책임.
    /// @MainActor에서만 호출되므로 모든 멤버에 @MainActor를 부여.
    @MainActor
    protocol ThrottleProtocol: AnyObject {
        func pause()
        func resume(aggressive: Bool)
        func endAggressiveMode()
        var isPaused: Bool { get }
    }

    /// ChunkUploadQueue enqueue 책임.
    @MainActor
    protocol UploadQueueProtocol: AnyObject {
        func enqueue(manifest: ChunkManifest, chunkDirectory: URL) async throws
    }

    typealias MetadataSnapshotter = @MainActor (Int) async throws -> Void
    typealias ChunkClosedHandler = @MainActor (Int) -> Void

    // MARK: - Configuration

    static let chunkDuration: TimeInterval = 30.0
    static let drainWaitSeconds: TimeInterval = 0.5
    static let defaultOverlapWindowSeconds: TimeInterval = 1.0

    // MARK: - State

    private let scanSessionId: UUID
    private let floorId: UUID
    private let fileStore: ScanFileStore
    /// 테스트에서 주입 가능. 기본값은 defaultOverlapWindowSeconds.
    let overlapWindowSeconds: TimeInterval

    private let bridge: any BridgeProtocol
    private let throttle: any ThrottleProtocol
    private let uploadQueue: any UploadQueueProtocol
    private let metadataSnapshotter: MetadataSnapshotter?
    private let onChunkClosed: ChunkClosedHandler?

    private var timer: Timer?
    private(set) var currentChunkIndex: Int = 0
    private var chunkStartedAt: Date = .now
    private var isRollingOver: Bool = false

    private static let logger = Logger(subsystem: "ac.koreatech.indoorpathfinding", category: "chunk")

    // MARK: - Init

    init(
        scanSessionId: UUID,
        floorId: UUID,
        fileStore: ScanFileStore,
        bridge: any BridgeProtocol,
        throttle: any ThrottleProtocol,
        uploadQueue: any UploadQueueProtocol,
        overlapWindowSeconds: TimeInterval = 1.0,
        metadataSnapshotter: MetadataSnapshotter? = nil,
        onChunkClosed: ChunkClosedHandler? = nil
    ) {
        self.scanSessionId = scanSessionId
        self.floorId = floorId
        self.fileStore = fileStore
        self.bridge = bridge
        self.throttle = throttle
        self.uploadQueue = uploadQueue
        self.overlapWindowSeconds = overlapWindowSeconds
        self.metadataSnapshotter = metadataSnapshotter
        self.onChunkClosed = onChunkClosed
    }

    // MARK: - Lifecycle

    /// scan 시작 시 호출. chunk_0 디렉터리를 생성하고 30s timer를 가동한다.
    func start() throws {
        guard timer == nil else { return }
        currentChunkIndex = 0
        chunkStartedAt = .now

        let firstDir = fileStore.chunkDirectory(chunkIndex: 0)
        try FileManager.default.createDirectory(at: firstDir, withIntermediateDirectories: true)

        // ADR D1: chunk_0에 scan_metadata.db snapshot 노출.
        // Production은 rollover/stop 직전 SQLite online backup으로 갱신한다.
        // 여기서는 테스트/폴백 경로에서만 파일 snapshot을 만든다.
        if metadataSnapshotter == nil {
            try fileStore.refreshChunkScanMetadataSnapshot(chunkIndex: 0)
        }

        Self.logger.info("ChunkRolloverScheduler start. sessionId=\(self.scanSessionId) chunk_0 dir=\(firstDir.lastPathComponent)")

        scheduleTimer()
    }

    /// scan 종료 시 호출. timer를 멈추고 현재 chunk를 즉시 flush한다.
    /// - Returns: 최종 chunk manifest (업로드 큐로 넘겨진 상태).
    func stop() async {
        timer?.invalidate()
        timer = nil
        Self.logger.info("ChunkRolloverScheduler stop. flushing last chunk \(self.currentChunkIndex)")
        await flushCurrentChunk()
    }

    // MARK: - Timer

    private func scheduleTimer() {
        let t = Timer(timeInterval: Self.chunkDuration, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.performRollover()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - Rollover sequence (ADR D2)

    /// timer fire 시 호출. 테스트에서 @testable import 후 직접 호출 가능.
    func performRollover() async {
        guard !isRollingOver else {
            Self.logger.warning("ChunkRolloverScheduler: rollover already in progress, skipping.")
            return
        }
        isRollingOver = true
        defer { isRollingOver = false }

        let closingIndex = currentChunkIndex
        let nextIndex = closingIndex + 1
        let currentChunkDir = fileStore.chunkDirectory(chunkIndex: closingIndex)
        let nextChunkDir = fileStore.chunkDirectory(chunkIndex: nextIndex)

        Self.logger.info("rollover begin: chunk \(closingIndex) → \(nextIndex)")

        // 1. SLAM throttle pause
        throttle.pause()

        // 2. 0.5s drain — in-flight keyframe 처리 보장
        try? await Task.sleep(nanoseconds: UInt64(Self.drainWaitSeconds * 1_000_000_000))

        // 3. 다음 chunk 디렉터리 준비. metadata snapshot은 close 직전에 갱신한다.
        do {
            try FileManager.default.createDirectory(at: nextChunkDir, withIntermediateDirectories: true)
        } catch {
            Self.logger.error("rollover: failed to create next chunk dir: \(error)")
            throttle.resume(aggressive: false)
            return
        }

        // 4. Bridge rollover (closedDBURL/nodeStamps는 enqueue 로직에서 직접 사용하지 않음)
        do {
            _ = try await bridge.rolloverChunk(
                currentScanURL: currentChunkDir,
                nextScanURL: nextChunkDir
            )
        } catch {
            Self.logger.error("rollover: bridge.rolloverChunk failed: \(error)")
            throttle.resume(aggressive: false)
            return
        }

        do {
            try await refreshMetadataSnapshot(chunkIndex: closingIndex)
        } catch {
            Self.logger.error("rollover: scan_metadata.db snapshot failed: \(error)")
            throttle.resume(aggressive: false)
            return
        }

        // 5. manifest 구성
        var manifest = ChunkManifest(
            scanSessionId: scanSessionId,
            floorId: floorId,
            chunkIndex: closingIndex,
            startedAt: chunkStartedAt,
            rtabmapDBPath: "rtabmap.db"
        )
        manifest.endedAt = .now

        // 6. upload queue enqueue (background — zip 빌드 + URLSession upload)
        // ADR D3: overlap keyframe 계수는 1s aggressive window 종료 후 bridge.currentNodeCount로 측정.
        // 먼저 enqueue Task를 보관해 overlap 계수 후 실제 enqueue를 수행한다.
        let manifestToEnqueue = manifest
        let dirToEnqueue = currentChunkDir

        // 7. 다음 chunk 상태 업데이트
        currentChunkIndex = nextIndex
        chunkStartedAt = .now
        onChunkClosed?(closingIndex)

        // 8. Throttle resume — aggressive mode (1s overlap window)
        throttle.resume(aggressive: true)

        // 9. 1s 후 normal mode 복귀 + overlap keyframe 계수 → enqueue
        let capturedThrottle = throttle
        let capturedBridge = bridge
        let capturedUploadQueue = uploadQueue
        let capturedClosingIndex = closingIndex
        Task {
            try? await Task.sleep(nanoseconds: UInt64(self.overlapWindowSeconds * 1_000_000_000))
            await MainActor.run {
                capturedThrottle.endAggressiveMode()
                // ADR D3: aggressive window 종료 시점에 새 DB nodeCount를 overlap 계수로 사용.
                let overlapCount = capturedBridge.currentNodeCount
                var enqueuingManifest = manifestToEnqueue
                enqueuingManifest.overlapKeyframes = overlapCount
                Self.logger.info("rollover: chunk \(capturedClosingIndex) overlap keyframes=\(overlapCount) overlapWarning=\(enqueuingManifest.overlapWarning)")
                Task {
                    do {
                        try await capturedUploadQueue.enqueue(manifest: enqueuingManifest, chunkDirectory: dirToEnqueue)
                    } catch {
                        Self.logger.error("rollover: enqueue chunk \(capturedClosingIndex) failed: \(error)")
                    }
                }
            }
        }

        // 10. 다음 30s timer 예약
        scheduleTimer()

        Self.logger.info("rollover complete: chunk \(closingIndex) closed, chunk \(nextIndex) started.")
    }

    /// scan stop 시 현재 마지막 chunk flush.
    private func flushCurrentChunk() async {
        let currentDir = fileStore.chunkDirectory(chunkIndex: currentChunkIndex)

        do {
            _ = try await bridge.closeCurrentChunk(currentScanURL: currentDir)
            try await refreshMetadataSnapshot(chunkIndex: currentChunkIndex)
        } catch {
            Self.logger.error("flushCurrentChunk: close/snapshot failed: \(error)")
            return
        }

        var manifest = ChunkManifest(
            scanSessionId: scanSessionId,
            floorId: floorId,
            chunkIndex: currentChunkIndex,
            startedAt: chunkStartedAt,
            rtabmapDBPath: "rtabmap.db"
        )
        manifest.endedAt = .now

        do {
            try await uploadQueue.enqueue(manifest: manifest, chunkDirectory: currentDir)
        } catch {
            Self.logger.error("flushCurrentChunk: enqueue failed: \(error)")
        }
    }

    private func refreshMetadataSnapshot(chunkIndex: Int) async throws {
        if let metadataSnapshotter {
            try await metadataSnapshotter(chunkIndex)
        } else {
            try fileStore.refreshChunkScanMetadataSnapshot(chunkIndex: chunkIndex)
        }
    }
}

// MARK: - KeyframeCaptureThrottle conformance

extension KeyframeCaptureThrottle: ChunkRolloverScheduler.ThrottleProtocol {}

@MainActor
final class CompositeChunkRolloverThrottle: ChunkRolloverScheduler.ThrottleProtocol {
    private let throttles: [KeyframeCaptureThrottle]

    init(_ throttles: [KeyframeCaptureThrottle]) {
        self.throttles = throttles
    }

    func pause() {
        throttles.forEach { $0.pause() }
    }

    func resume(aggressive: Bool) {
        throttles.forEach { $0.resume(aggressive: aggressive) }
    }

    func endAggressiveMode() {
        throttles.forEach { $0.endAggressiveMode() }
    }

    var isPaused: Bool {
        throttles.contains { $0.isPaused }
    }
}
