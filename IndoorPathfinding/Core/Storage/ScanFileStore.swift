import Foundation

/// Documents/scans/{scan_id}/ 파일 I/O 담당.
struct ScanFileStore {
    let scanId: String
    /// 문서 루트. 기본값은 `FileManager.default.urls(for:in:)[0]`.
    /// 테스트에서 임시 디렉터리를 주입할 때 사용한다.
    private let documentsRoot: URL

    init(scanId: String) {
        self.scanId = scanId
        self.documentsRoot = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// 테스트 전용 initializer — documentsRoot를 주입해 파일시스템을 격리한다.
    init(scanId: String, documentsRoot: URL) {
        self.scanId = scanId
        self.documentsRoot = documentsRoot
    }

    var scanDirectory: URL {
        documentsRoot.appendingPathComponent("scans/\(scanId)")
    }

    var keyframesDirectory: URL {
        scanDirectory.appendingPathComponent("keyframes")
    }

    var databaseURL: URL {
        scanDirectory.appendingPathComponent("scan_metadata.db")
    }

    /// 디렉터리 생성. 세션 시작 시 1회 호출.
    func createDirectories() throws {
        try FileManager.default.createDirectory(
            at: keyframesDirectory,
            withIntermediateDirectories: true
        )
    }

    /// JPEG 데이터를 keyframes/{seq:06d}.jpg에 저장.
    func writeKeyframe(seq: Int, jpeg: Data) throws {
        let name = String(format: "%06d.jpg", seq)
        let url = keyframesDirectory.appendingPathComponent(name)
        try jpeg.write(to: url, options: .atomic)
    }

    /// scan_id 폴더 전체 삭제 (폐기).
    func deleteAll() throws {
        guard FileManager.default.fileExists(atPath: scanDirectory.path) else { return }
        try FileManager.default.removeItem(at: scanDirectory)
    }

    /// rtabmap.db 위치.
    var rtabmapDatabaseURL: URL {
        scanDirectory.appendingPathComponent("rtabmap.db")
    }

    /// Sprint 67 — HEVC video 위치 (60fps 전체 frame).
    var videoURL: URL {
        scanDirectory.appendingPathComponent(VideoRecorder.videoFileName)
    }

    /// Sprint 67 — pose binary file 위치 (pts_ns + 4x4 transform 72B/record).
    var posesURL: URL {
        scanDirectory.appendingPathComponent(PoseFileWriter.posesFileName)
    }

    /// Documents/exports/ — 아카이브 ZIP 파일 저장 위치.
    static var exportsDirectory: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("exports")
    }

    // MARK: - Chunked scan directories (ADR D4)

    /// Documents/live/<scanSessionId>/ — chunked scan의 live chunk 디렉터리 루트.
    var liveSessionDirectory: URL {
        documentsRoot.appendingPathComponent("live/\(scanId)")
    }

    /// Documents/live/<scanSessionId>/chunk_<chunkIndex formatted 04d>/
    func chunkDirectory(chunkIndex: Int) -> URL {
        liveSessionDirectory.appendingPathComponent(String(format: "chunk_%04d", chunkIndex))
    }

    // MARK: - ADR D1: scan_metadata.db chunk snapshot

    /// session-level scan_metadata.db를 chunk dir 안에 snapshot copy로 노출한다.
    /// ZipScanArchiver.requiredFiles = ["scan_metadata.db", "rtabmap.db"] 계약 만족.
    ///
    /// live DB와 chunk archive reader가 같은 inode를 동시에 건드리지 않게 hardlink 대신 copy를 쓴다.
    /// 호출자는 가능하면 `ScanMetadataDatabase.backup(to:)`를 우선 사용하고, 이 메서드는 테스트/폴백용
    /// 파일 snapshot으로 둔다.
    ///
    /// - Parameter chunkIndex: snapshot을 생성할 chunk 인덱스.
    func scanMetadataSnapshotURL(chunkIndex: Int) -> URL {
        chunkDirectory(chunkIndex: chunkIndex)
            .appendingPathComponent("scan_metadata.db")
    }

    func refreshChunkScanMetadataSnapshot(chunkIndex: Int) throws {
        let fm = FileManager.default
        let snapshotURL = scanMetadataSnapshotURL(chunkIndex: chunkIndex)
        try fm.createDirectory(
            at: snapshotURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fm.fileExists(atPath: snapshotURL.path) {
            try fm.removeItem(at: snapshotURL)
        }
        try fm.copyItem(at: databaseURL, to: snapshotURL)
    }

    /// Documents/upload_staging/ — ChunkUploadQueue가 URLSession background에 넘길 zip 저장 위치.
    static var uploadStagingDirectory: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("upload_staging")
    }

    /// chunk zip 파일 URL. chunk_<UUID>.zip 형식으로 충돌을 방지한다.
    static func chunkZipURL(chunkSessionId: UUID) -> URL {
        uploadStagingDirectory.appendingPathComponent("chunk_\(chunkSessionId.uuidString).zip")
    }

    /// background URLSession 에 넘길 multipart body 파일 URL.
    static func chunkMultipartURL(chunkSessionId: UUID) -> URL {
        uploadStagingDirectory.appendingPathComponent("chunk_\(chunkSessionId.uuidString).multipart")
    }

    /// chunk manifest JSON URL.
    static func chunkManifestURL(chunkSessionId: UUID) -> URL {
        uploadStagingDirectory.appendingPathComponent("chunk_\(chunkSessionId.uuidString).manifest.json")
    }

    /// upload_staging 디렉터리 생성.
    static func createUploadStagingDirectory() throws {
        try FileManager.default.createDirectory(
            at: uploadStagingDirectory,
            withIntermediateDirectories: true
        )
    }

    /// 가용 디스크 공간 확인 — 중요 데이터 기준 (Sprint 2 WARN 반영).
    /// `volumeAvailableCapacityForImportantUsageKey`는 퍼지 메모리를 제외한
    /// 실질적 여유 공간을 반환하므로 `systemFreeSize`보다 정확하다.
    static func availableCapacityForImportantUsage() -> Int64? {
        let docURL = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let values = try? docURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ) else { return nil }
        guard let capacity = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return Int64(capacity)
    }
}
