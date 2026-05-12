import Foundation
import OSLog

/// URLSession background config 기반 chunk upload 큐.
/// ADR D4 — background URLSession + 디스크 cap + 재시도 정책.
///
/// 이 클래스는 URLSessionDelegate를 소유한다.
/// AppDelegate `handleEventsForBackgroundURLSession`에서 completion handler를 연결한다.
@MainActor
final class ChunkUploadQueue: NSObject {

    // MARK: - Constants

    static let backgroundSessionIdentifier = "ac.koreatech.indoorpathfinding.chunkUpload"

    /// 디스크 누적 cap: 2 GB. ADR D4.
    static let diskCapBytes: Int64 = 2 * 1024 * 1024 * 1024
    /// chunk 수 cap: 20개. ADR D4.
    static let chunkCountCap: Int = 20
    /// 최대 재시도 횟수. ADR D4.
    static let maxRetryCount: Int = 5

    // MARK: - State

    private(set) var manifests: [UUID: ChunkManifest] = [:]   // key: scanSessionId+chunkIndex 대리 = chunkSessionId (사용 단순화를 위해 zipURL UUID 사용)
    private var chunkIdByTaskId: [Int: UUID] = [:]             // URLSession taskIdentifier → chunk zip UUID
    private var zipURLByChunkId: [UUID: URL] = [:]

    weak var observer: ChunkUploadObserver?

    private var backgroundSession: URLSession?
    private var backgroundCompletionHandler: (() -> Void)?

    private let archiver: ZipScanArchiver
    private let serverClient: IndoorServerV1Client
    private let archiveQueue = DispatchQueue(label: "chunk.archive", qos: .utility)

    private static let logger = Logger(subsystem: "ac.koreatech.indoorpathfinding", category: "upload")

    // MARK: - Init

    init(archiver: ZipScanArchiver = ZipScanArchiver(), serverClient: IndoorServerV1Client) {
        self.archiver = archiver
        self.serverClient = serverClient
        super.init()
        setupBackgroundSession()
    }

    private func setupBackgroundSession() {
        let config = URLSessionConfiguration.background(
            withIdentifier: Self.backgroundSessionIdentifier
        )
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        // background session의 delegate는 non-MainActor queue에서 호출되므로
        // delegate 메서드 안에서 MainActor.run으로 hop한다.
        backgroundSession = URLSession(
            configuration: config,
            delegate: self,
            delegateQueue: nil
        )

        // AppDelegate → NotificationCenter → ChunkUploadQueue completion handler 연결.
        NotificationCenter.default.addObserver(
            forName: .chunkUploadBackgroundSessionEvent,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let handler = note.object as? () -> Void else { return }
            Task { @MainActor in
                self?.backgroundCompletionHandler = handler
            }
        }
    }

    // MARK: - Disk cap check

    var isAtCapacity: Bool {
        let chunkCount = manifests.count
        if chunkCount >= Self.chunkCountCap { return true }
        let totalBytes = zipURLByChunkId.values.reduce(Int64(0)) { acc, url in
            acc + ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0)
        }
        return totalBytes >= Self.diskCapBytes
    }

    // MARK: - ChunkRolloverScheduler.UploadQueueProtocol

    /// chunk 디렉터리를 zip으로 archive하고 background upload task를 등록한다.
    func enqueue(manifest: ChunkManifest, chunkDirectory: URL) async throws {
        guard !isAtCapacity else {
            throw ChunkUploadError.diskCapReached
        }

        let chunkSessionId = UUID()
        let zipURL = ScanFileStore.chunkZipURL(chunkSessionId: chunkSessionId)
        let manifestURL = ScanFileStore.chunkManifestURL(chunkSessionId: chunkSessionId)

        try ScanFileStore.createUploadStagingDirectory()

        var updatedManifest = manifest
        updatedManifest.uploadState = .archiving
        updatedManifest.zipPath = zipURL.path
        manifests[chunkSessionId] = updatedManifest
        zipURLByChunkId[chunkSessionId] = zipURL
        observer?.didUpdate(queue: manifests)

        Self.logger.info("enqueue chunk \(manifest.chunkIndex) archiving... dir=\(chunkDirectory.lastPathComponent)")

        // background archive
        do {
            try await archiver.archive(
                scanDirectory: chunkDirectory,
                destination: zipURL,
                scanId: "chunk_\(chunkSessionId.uuidString)",
                progress: { _ in }
            )
        } catch {
            updatedManifest.uploadState = .failed
            updatedManifest.lastError = error.localizedDescription
            manifests[chunkSessionId] = updatedManifest
            observer?.didUpdate(queue: manifests)
            Self.logger.error("enqueue: archive failed: \(error)")
            throw error
        }

        // manifest 저장
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        updatedManifest.uploadState = .queued
        manifests[chunkSessionId] = updatedManifest
        let manifestData = try encoder.encode(updatedManifest)
        try manifestData.write(to: manifestURL, options: .atomic)
        observer?.didUpdate(queue: manifests)

        // URLSession background upload task 시작
        guard let session = backgroundSession else {
            throw ChunkUploadError.sessionUnavailable
        }

        let uploadURL = buildUploadURL(floorId: manifest.floorId)
        let request = buildUploadRequest(url: uploadURL, zipURL: zipURL, manifest: updatedManifest)
        let task = session.uploadTask(with: request, fromFile: zipURL)
        chunkIdByTaskId[task.taskIdentifier] = chunkSessionId

        updatedManifest.uploadState = .uploading
        manifests[chunkSessionId] = updatedManifest
        observer?.didUpdate(queue: manifests)

        task.resume()
        Self.logger.info("enqueue: upload task started taskId=\(task.taskIdentifier) chunk=\(manifest.chunkIndex)")
    }

    // MARK: - Restore from staging (앱 재시작 시 미완료 chunk 복원)

    /// upload_staging 디렉터리를 스캔해 pending manifest를 복원한다.
    func restoreFromStaging() throws {
        let stagingDir = ScanFileStore.uploadStagingDirectory
        guard FileManager.default.fileExists(atPath: stagingDir.path) else { return }

        let items = try FileManager.default.contentsOfDirectory(
            at: stagingDir,
            includingPropertiesForKeys: nil
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for item in items where item.pathExtension == "json" && item.lastPathComponent.hasSuffix(".manifest.json") {
            guard let data = try? Data(contentsOf: item),
                  var manifest = try? decoder.decode(ChunkManifest.self, from: data) else { continue }

            // expired 체크
            if manifest.expiresAt < .now {
                manifest.uploadState = .expired
            }

            // zip이 있고 done이 아닌 경우 재시도 가능 상태로 복원
            if manifest.uploadState != .done && manifest.uploadState != .expired {
                manifest.uploadState = .failed
                manifest.lastError = "앱이 재시작됐습니다. 재시도를 눌러주세요."
            }

            let chunkSessionId = extractChunkSessionId(from: item)
            if let id = chunkSessionId {
                manifests[id] = manifest
                if let zipPath = manifest.zipPath {
                    zipURLByChunkId[id] = URL(fileURLWithPath: zipPath)
                }
            }
        }
        observer?.didUpdate(queue: manifests)
        Self.logger.info("restoreFromStaging: restored \(self.manifests.count) chunk(s).")
    }

    /// manifest json URL에서 UUID 파싱.
    private func extractChunkSessionId(from url: URL) -> UUID? {
        let name = url.deletingPathExtension().deletingPathExtension().lastPathComponent
        guard name.hasPrefix("chunk_") else { return nil }
        let idStr = String(name.dropFirst("chunk_".count))
        return UUID(uuidString: idStr)
    }

    // MARK: - Retry

    func retryChunk(chunkSessionId: UUID) {
        guard var manifest = manifests[chunkSessionId],
              manifest.uploadState == .failed || manifest.uploadState == .expired,
              manifest.retryCount < Self.maxRetryCount,
              let zipURL = zipURLByChunkId[chunkSessionId],
              FileManager.default.fileExists(atPath: zipURL.path),
              let session = backgroundSession else { return }

        manifest.retryCount += 1
        manifest.uploadState = .uploading
        manifest.lastError = nil
        manifests[chunkSessionId] = manifest
        observer?.didUpdate(queue: manifests)

        let uploadURL = buildUploadURL(floorId: manifest.floorId)
        let request = buildUploadRequest(url: uploadURL, zipURL: zipURL, manifest: manifest)
        let task = session.uploadTask(with: request, fromFile: zipURL)
        chunkIdByTaskId[task.taskIdentifier] = chunkSessionId
        task.resume()

        Self.logger.info("retryChunk: chunkIndex=\(manifest.chunkIndex) retryCount=\(manifest.retryCount)")
    }

    func deleteChunk(chunkSessionId: UUID) {
        guard let manifest = manifests[chunkSessionId] else { return }
        guard manifest.uploadState == .done || manifest.uploadState == .failed || manifest.uploadState == .expired else { return }

        if let zipURL = zipURLByChunkId[chunkSessionId] {
            try? FileManager.default.removeItem(at: zipURL)
        }
        manifests.removeValue(forKey: chunkSessionId)
        zipURLByChunkId.removeValue(forKey: chunkSessionId)
        observer?.didUpdate(queue: manifests)
    }

    // MARK: - Background session completion handler

    func setBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
        backgroundCompletionHandler = handler
    }

    // MARK: - Private helpers

    private func buildUploadURL(floorId: UUID) -> URL {
        serverClient.chunkUploadURL(floorId: floorId)
    }

    private func buildUploadRequest(url: URL, zipURL: URL, manifest: ChunkManifest) -> URLRequest {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = serverClient.authorizedChunkRequest(url: url, boundary: boundary)
        request.httpMethod = "POST"
        return request
    }
}

// MARK: - URLSessionDelegate

extension ChunkUploadQueue: URLSessionDelegate, URLSessionTaskDelegate {

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            let handler = self.backgroundCompletionHandler
            self.backgroundCompletionHandler = nil
            handler?()
            Self.logger.info("urlSessionDidFinishEvents: background session events complete.")
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let taskId = task.taskIdentifier
        let statusCode = (task.response as? HTTPURLResponse)?.statusCode ?? -1

        Task { @MainActor in
            guard let chunkSessionId = self.chunkIdByTaskId[taskId] else { return }
            self.chunkIdByTaskId.removeValue(forKey: taskId)

            guard var manifest = self.manifests[chunkSessionId] else { return }

            if let error {
                // 네트워크 오류
                manifest.retryCount += 1
                if manifest.retryCount >= Self.maxRetryCount {
                    manifest.uploadState = .failed
                    manifest.lastError = "최대 재시도 초과: \(error.localizedDescription)"
                    Self.logger.error("chunk \(manifest.chunkIndex) upload failed permanently: \(error)")
                } else {
                    manifest.uploadState = .failed
                    manifest.lastError = error.localizedDescription
                    Self.logger.warning("chunk \(manifest.chunkIndex) upload error (retry \(manifest.retryCount)): \(error)")
                }
            } else if statusCode == 200 || statusCode == 201 {
                manifest.uploadState = .done
                manifest.lastError = nil
                // 업로드 성공 시 로컬 zip 삭제
                if let zipURL = self.zipURLByChunkId[chunkSessionId] {
                    try? FileManager.default.removeItem(at: zipURL)
                }
                Self.logger.info("chunk \(manifest.chunkIndex) upload done. statusCode=\(statusCode)")
            } else {
                manifest.uploadState = .failed
                manifest.lastError = "서버 오류: HTTP \(statusCode)"
                Self.logger.error("chunk \(manifest.chunkIndex) upload HTTP error: \(statusCode)")
            }

            self.manifests[chunkSessionId] = manifest
            self.observer?.didUpdate(queue: self.manifests)
        }
    }
}

// MARK: - ChunkRolloverScheduler.UploadQueueProtocol conformance

extension ChunkUploadQueue: ChunkRolloverScheduler.UploadQueueProtocol {}

// MARK: - Error

enum ChunkUploadError: LocalizedError {
    case diskCapReached
    case sessionUnavailable

    var errorDescription: String? {
        switch self {
        case .diskCapReached: return "디스크 cap(2GB / 20chunk)에 도달했습니다. 업로드가 완료될 때까지 새 스캔을 시작할 수 없습니다."
        case .sessionUnavailable: return "URLSession이 초기화되지 않았습니다."
        }
    }
}
