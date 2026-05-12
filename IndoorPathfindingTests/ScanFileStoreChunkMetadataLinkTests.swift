import Testing
import Foundation
@testable import IndoorPathfinding

/// ADR 0002 D1 — scan_metadata.db chunk snapshot 검증.
///
/// - chunk snapshot이 session DB와 다른 inode인지 POSIX stat로 확인.
/// - 멱등성: 중복 호출 시 throw 없음.
/// - metadata 갱신은 refresh 호출 후 chunk 측에 반영되는지 확인.
@Suite("ScanFileStore — chunk scan_metadata.db snapshot (ADR D1)")
struct ScanFileStoreChunkMetadataLinkTests {

    // MARK: - Helpers

    private func makeTempFileStore() throws -> (store: ScanFileStore, tempRoot: URL) {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScanFileStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let store = ScanFileStore(scanId: UUID().uuidString, documentsRoot: tempRoot)
        return (store, tempRoot)
    }

    private func inode(of url: URL) throws -> UInt64 {
        var statBuffer = stat()
        guard stat(url.path, &statBuffer) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno)!)
        }
        return statBuffer.st_ino
    }

    // MARK: - Tests

    @Test("snapshot 생성 후 chunk 경로와 session 경로가 다른 inode를 사용한다")
    func snapshotDoesNotShareInode() throws {
        let (store, tempRoot) = try makeTempFileStore()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        // session-level scan_metadata.db 생성
        try FileManager.default.createDirectory(at: store.scanDirectory, withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: 256).write(to: store.databaseURL)

        // chunk_0 dir 생성 후 snapshot 노출
        let chunkDir = store.chunkDirectory(chunkIndex: 0)
        try FileManager.default.createDirectory(at: chunkDir, withIntermediateDirectories: true)
        try store.refreshChunkScanMetadataSnapshot(chunkIndex: 0)

        let snapshotURL = chunkDir.appendingPathComponent("scan_metadata.db")
        #expect(FileManager.default.fileExists(atPath: snapshotURL.path))
        #expect(try inode(of: store.databaseURL) != inode(of: snapshotURL))
        #expect(try Data(contentsOf: snapshotURL) == Data(repeating: 0xAB, count: 256))
    }

    @Test("refreshChunkScanMetadataSnapshot 중복 호출 시 throw 없음 (멱등성)")
    func idempotent() throws {
        let (store, tempRoot) = try makeTempFileStore()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try FileManager.default.createDirectory(at: store.scanDirectory, withIntermediateDirectories: true)
        try Data(repeating: 0xCD, count: 128).write(to: store.databaseURL)

        let chunkDir = store.chunkDirectory(chunkIndex: 1)
        try FileManager.default.createDirectory(at: chunkDir, withIntermediateDirectories: true)

        // 두 번 호출해도 throw 없어야 한다
        try store.refreshChunkScanMetadataSnapshot(chunkIndex: 1)
        try store.refreshChunkScanMetadataSnapshot(chunkIndex: 1)

        let snapshotURL = chunkDir.appendingPathComponent("scan_metadata.db")
        #expect(FileManager.default.fileExists(atPath: snapshotURL.path))
    }

    @Test("refresh 호출 후 session-level metadata 갱신이 chunk snapshot에 반영된다")
    func metadataWriteReflectsAfterSnapshotRefresh() throws {
        let (store, tempRoot) = try makeTempFileStore()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try FileManager.default.createDirectory(at: store.scanDirectory, withIntermediateDirectories: true)
        let original = Data(repeating: 0x11, count: 64)
        try original.write(to: store.databaseURL)

        let chunkDir = store.chunkDirectory(chunkIndex: 0)
        try FileManager.default.createDirectory(at: chunkDir, withIntermediateDirectories: true)
        try store.refreshChunkScanMetadataSnapshot(chunkIndex: 0)

        // session-level DB에 새 내용 write
        let updated = Data(repeating: 0x22, count: 128)
        try updated.write(to: store.databaseURL)

        // snapshot은 refresh 전까지 이전 내용을 유지한다
        let snapshotURL = chunkDir.appendingPathComponent("scan_metadata.db")
        #expect(try Data(contentsOf: snapshotURL) == original)

        try store.refreshChunkScanMetadataSnapshot(chunkIndex: 0)
        let readBack = try Data(contentsOf: snapshotURL)
        #expect(readBack == updated)
    }
}
