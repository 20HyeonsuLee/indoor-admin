import Foundation
import OSLog

private final class ChunkUploadResponseBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var dataByTaskId: [Int: Data] = [:]

    func append(_ data: Data, taskId: Int) {
        lock.lock()
        dataByTaskId[taskId, default: Data()].append(data)
        lock.unlock()
    }

    func take(taskId: Int) -> Data {
        lock.lock()
        defer { lock.unlock() }
        return dataByTaskId.removeValue(forKey: taskId) ?? Data()
    }
}

private struct PreparedChunkUpload: Sendable {
    let summary: ScanMetadataDatabase.ChunkSnapshotSummary
    let zipByteCount: Int64?
    let multipartURL: URL
}

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
    private var multipartURLByChunkId: [UUID: URL] = [:]
    private nonisolated let responseBuffer = ChunkUploadResponseBuffer()

    weak var observer: ChunkUploadObserver?
    var onChunkUploaded: ((UUID) -> Void)?

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
        let chunkScanId = chunkSessionId.uuidString
        let zipURL = ScanFileStore.chunkZipURL(chunkSessionId: chunkSessionId)
        let manifestURL = ScanFileStore.chunkManifestURL(chunkSessionId: chunkSessionId)

        try ScanFileStore.createUploadStagingDirectory()

        var updatedManifest = manifest
        updatedManifest.uploadState = .archiving
        updatedManifest.zipPath = zipURL.path
        updatedManifest.uploadScanId = chunkScanId
        manifests[chunkSessionId] = updatedManifest
        zipURLByChunkId[chunkSessionId] = zipURL
        observer?.didUpdate(queue: manifests)

        Self.logger.info("enqueue chunk \(manifest.chunkIndex) archiving... dir=\(chunkDirectory.lastPathComponent)")

        let uploadURL = buildUploadURL(floorId: manifest.floorId)
        let boundary = "Boundary-\(UUID().uuidString)"
        let prepared: PreparedChunkUpload
        do {
            prepared = try await prepareChunkUploadFiles(
                chunkDirectory: chunkDirectory,
                chunkScanId: chunkScanId,
                manifest: updatedManifest,
                zipURL: zipURL,
                boundary: boundary,
                chunkSessionId: chunkSessionId
            )
        } catch {
            updatedManifest.uploadState = .failed
            updatedManifest.lastError = error.localizedDescription
            manifests[chunkSessionId] = updatedManifest
            observer?.didUpdate(queue: manifests)
            Self.logger.error("enqueue: archive preparation failed: \(error)")
            throw error
        }

        Self.logger.info("enqueue: chunk sidecar normalized scanId=\(prepared.summary.scanId) keyframes=\(prepared.summary.keyframeCount) branches=\(prepared.summary.branchMarkCount) edges=\(prepared.summary.branchEdgeCount)")
        updatedManifest.archivedKeyframeCount = prepared.summary.keyframeCount
        updatedManifest.archivedBranchMarkCount = prepared.summary.branchMarkCount
        updatedManifest.archivedBranchEdgeCount = prepared.summary.branchEdgeCount
        updatedManifest.zipByteCount = prepared.zipByteCount

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

        let multipartURL = prepared.multipartURL
        multipartURLByChunkId[chunkSessionId] = multipartURL
        let request = buildUploadRequest(url: uploadURL, bodyURL: multipartURL, boundary: boundary)
        let task = session.uploadTask(with: request, fromFile: multipartURL)
        chunkIdByTaskId[task.taskIdentifier] = chunkSessionId

        updatedManifest.uploadState = .uploading
        updatedManifest.uploadStartedAt = .now
        updatedManifest.lastHTTPStatus = nil
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
              FileManager.default.fileExists(atPath: zipURL.path) else { return }

        manifest.retryCount += 1
        manifest.uploadState = .uploading
        manifest.lastError = nil
        manifest.uploadStartedAt = .now
        manifest.uploadCompletedAt = nil
        manifest.lastHTTPStatus = nil
        manifests[chunkSessionId] = manifest
        observer?.didUpdate(queue: manifests)

        Task { @MainActor in
            let uploadURL = self.buildUploadURL(floorId: manifest.floorId)
            let boundary = "Boundary-\(UUID().uuidString)"
            let scanId = manifest.uploadScanId ?? chunkSessionId.uuidString

            let multipartURL: URL
            do {
                multipartURL = try await self.makeMultipartBodyFile(
                    zipURL: zipURL,
                    scanId: scanId,
                    boundary: boundary,
                    chunkSessionId: chunkSessionId
                )
            } catch {
                guard var failedManifest = self.manifests[chunkSessionId] else { return }
                failedManifest.uploadState = .failed
                failedManifest.lastError = "multipart body 생성 실패: \(error.localizedDescription)"
                self.manifests[chunkSessionId] = failedManifest
                self.observer?.didUpdate(queue: self.manifests)
                return
            }

            guard let session = self.backgroundSession else {
                guard var failedManifest = self.manifests[chunkSessionId] else { return }
                failedManifest.uploadState = .failed
                failedManifest.lastError = ChunkUploadError.sessionUnavailable.localizedDescription
                self.manifests[chunkSessionId] = failedManifest
                self.observer?.didUpdate(queue: self.manifests)
                return
            }

            self.multipartURLByChunkId[chunkSessionId] = multipartURL
            let request = self.buildUploadRequest(url: uploadURL, bodyURL: multipartURL, boundary: boundary)
            let task = session.uploadTask(with: request, fromFile: multipartURL)
            self.chunkIdByTaskId[task.taskIdentifier] = chunkSessionId
            task.resume()

            Self.logger.info("retryChunk: chunkIndex=\(manifest.chunkIndex) retryCount=\(manifest.retryCount)")
        }
    }

    func deleteChunk(chunkSessionId: UUID) {
        guard let manifest = manifests[chunkSessionId] else { return }
        guard manifest.uploadState == .done || manifest.uploadState == .failed || manifest.uploadState == .expired else { return }

        if let zipURL = zipURLByChunkId[chunkSessionId] {
            try? FileManager.default.removeItem(at: zipURL)
        }
        if let multipartURL = multipartURLByChunkId[chunkSessionId] {
            try? FileManager.default.removeItem(at: multipartURL)
        }
        try? FileManager.default.removeItem(at: ScanFileStore.chunkManifestURL(chunkSessionId: chunkSessionId))
        manifests.removeValue(forKey: chunkSessionId)
        zipURLByChunkId.removeValue(forKey: chunkSessionId)
        multipartURLByChunkId.removeValue(forKey: chunkSessionId)
        observer?.didUpdate(queue: manifests)
    }

    func deleteFailedAndExpiredChunks() {
        let ids = manifests.compactMap { id, manifest in
            manifest.uploadState == .failed || manifest.uploadState == .expired ? id : nil
        }
        ids.forEach { deleteChunk(chunkSessionId: $0) }
    }

    // MARK: - Background session completion handler

    func setBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
        backgroundCompletionHandler = handler
    }

    // MARK: - Private helpers

    private func buildUploadURL(floorId: UUID) -> URL {
        serverClient.chunkUploadURL(floorId: floorId)
    }

    private func buildUploadRequest(url: URL, bodyURL: URL, boundary: String) -> URLRequest {
        var request = serverClient.authorizedChunkRequest(url: url, boundary: boundary)
        request.httpMethod = "POST"
        if let size = try? FileManager.default.attributesOfItem(atPath: bodyURL.path)[.size] as? NSNumber {
            request.setValue("\(size.int64Value)", forHTTPHeaderField: "Content-Length")
        }
        return request
    }

    private func prepareChunkUploadFiles(
        chunkDirectory: URL,
        chunkScanId: String,
        manifest: ChunkManifest,
        zipURL: URL,
        boundary: String,
        chunkSessionId: UUID
    ) async throws -> PreparedChunkUpload {
        let archiver = self.archiver
        let queue = archiveQueue
        let appShortVersion = Self.appShortVersion
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let summary = try Self.prepareChunkArchiveMetadata(
                        chunkDirectory: chunkDirectory,
                        chunkScanId: chunkScanId,
                        manifest: manifest,
                        appShortVersion: appShortVersion
                    )
                    try archiver.archiveBlocking(
                        scanDirectory: chunkDirectory,
                        destination: zipURL,
                        scanId: chunkScanId,
                        progress: { _ in }
                    )
                    let multipartURL = try Self.buildMultipartBodyFile(
                        zipURL: zipURL,
                        scanId: chunkScanId,
                        boundary: boundary,
                        chunkSessionId: chunkSessionId
                    )
                    continuation.resume(returning: PreparedChunkUpload(
                        summary: summary,
                        zipByteCount: Self.zipByteCount(at: zipURL),
                        multipartURL: multipartURL
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    nonisolated private static func prepareChunkArchiveMetadata(
        chunkDirectory: URL,
        chunkScanId: String,
        manifest: ChunkManifest,
        appShortVersion: String
    ) throws -> ScanMetadataDatabase.ChunkSnapshotSummary {
        let endedAt = manifest.endedAt ?? .now
        let snapshotURL = chunkDirectory.appendingPathComponent("scan_metadata.db")
        let summary = try ScanMetadataDatabase.prepareChunkSnapshot(
            at: snapshotURL,
            chunkScanId: chunkScanId,
            startedAt: manifest.startedAt,
            endedAt: endedAt
        )
        let chunkManifest = ManifestWriter.makeChunkLiveRtabmap(
            scanId: chunkScanId,
            sidecarKeyframeMetaCount: summary.keyframeCount,
            clientAppVersion: appShortVersion
        )
        _ = try ManifestWriter.write(scanDirectory: chunkDirectory, manifest: chunkManifest)
        return summary
    }

    nonisolated private static var appShortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
    }

    nonisolated private static func zipByteCount(at url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    private func makeMultipartBodyFile(
        zipURL: URL,
        scanId: String,
        boundary: String,
        chunkSessionId: UUID
    ) async throws -> URL {
        let queue = archiveQueue
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let url = try Self.buildMultipartBodyFile(
                        zipURL: zipURL,
                        scanId: scanId,
                        boundary: boundary,
                        chunkSessionId: chunkSessionId
                    )
                    continuation.resume(returning: url)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    nonisolated private static func buildMultipartBodyFile(
        zipURL: URL,
        scanId: String,
        boundary: String,
        chunkSessionId: UUID
    ) throws -> URL {
        let bodyURL = ScanFileStore.chunkMultipartURL(chunkSessionId: chunkSessionId)
        let fm = FileManager.default
        if fm.fileExists(atPath: bodyURL.path) {
            try fm.removeItem(at: bodyURL)
        }
        _ = fm.createFile(atPath: bodyURL.path, contents: nil)

        let out = try FileHandle(forWritingTo: bodyURL)
        defer { try? out.close() }

        func writeString(_ value: String) {
            out.write(Data(value.utf8))
        }

        writeString("--\(boundary)\r\n")
        writeString("Content-Disposition: form-data; name=\"scan_id\"\r\n\r\n")
        writeString("\(scanId)\r\n")

        writeString("--\(boundary)\r\n")
        writeString("Content-Disposition: form-data; name=\"file\"; filename=\"\(zipURL.lastPathComponent)\"\r\n")
        writeString("Content-Type: application/zip\r\n\r\n")

        let input = try FileHandle(forReadingFrom: zipURL)
        defer { try? input.close() }
        while true {
            let chunk = try input.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            out.write(chunk)
        }

        writeString("\r\n--\(boundary)--\r\n")
        return bodyURL
    }
}

// MARK: - URLSessionDelegate

extension ChunkUploadQueue: URLSessionDelegate, URLSessionTaskDelegate, URLSessionDataDelegate {

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            let handler = self.backgroundCompletionHandler
            self.backgroundCompletionHandler = nil
            handler?()
            Self.logger.info("urlSessionDidFinishEvents: background session events complete.")
        }
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        responseBuffer.append(data, taskId: dataTask.taskIdentifier)
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let taskId = task.taskIdentifier
        let statusCode = (task.response as? HTTPURLResponse)?.statusCode ?? -1
        let responseData = responseBuffer.take(taskId: taskId)

        Task { @MainActor in
            guard let chunkSessionId = self.chunkIdByTaskId[taskId] else { return }
            self.chunkIdByTaskId.removeValue(forKey: taskId)

            guard var manifest = self.manifests[chunkSessionId] else { return }
            manifest.lastHTTPStatus = statusCode > 0 ? statusCode : nil
            manifest.uploadCompletedAt = .now

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
                do {
                    let uploaded = try JSONDecoder().decode(V1ScanChunk.self, from: responseData)
                    manifest.serverChunkId = uploaded.chunkId
                    manifest.uploadState = .done
                    manifest.lastError = nil
                    // 업로드 성공 시 로컬 zip/body 삭제
                    if let zipURL = self.zipURLByChunkId[chunkSessionId] {
                        try? FileManager.default.removeItem(at: zipURL)
                    }
                    if let multipartURL = self.multipartURLByChunkId[chunkSessionId] {
                        try? FileManager.default.removeItem(at: multipartURL)
                    }
                    try? FileManager.default.removeItem(at: ScanFileStore.chunkManifestURL(chunkSessionId: chunkSessionId))
                    self.onChunkUploaded?(manifest.floorId)
                    Self.logger.info("chunk \(manifest.chunkIndex) upload done. statusCode=\(statusCode) serverChunkId=\(uploaded.chunkId.uuidString)")
                } catch {
                    manifest.uploadState = .failed
                    manifest.lastError = "서버 응답 파싱 실패: \(error.localizedDescription)"
                    Self.logger.error("chunk \(manifest.chunkIndex) response decode failed: \(error)")
                }
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
