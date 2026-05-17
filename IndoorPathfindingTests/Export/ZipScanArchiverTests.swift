import Testing
import Foundation
import ZIPFoundation
@testable import IndoorPathfinding

@Suite("ZipScanArchiver")
struct ZipScanArchiverTests {

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    // MARK: - Tests

    @Test("archive — 필수 파일 포함, keyframes/ 미포함 (Sprint 49)")
    func archiveIncludesAllRequiredFiles() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let fake = try FakeScanDirectoryFactory.make(in: tmp, keyframeSizes: [1024, 2048])
        let destination = tmp.appendingPathComponent("output.zip")
        let archiver = ZipScanArchiver()

        try await archiver.archive(
            scanDirectory: fake.scanDirectory,
            destination: destination,
            scanId: fake.scanId
        ) { _ in }

        #expect(FileManager.default.fileExists(atPath: destination.path))

        guard let archive = (try? Archive(url: destination, accessMode: .read, pathEncoding: nil)) else {
            Issue.record("ZIP 파일을 열 수 없음")
            return
        }

        let entryPaths = archive.map { $0.path }
        #expect(entryPaths.contains("\(fake.scanId)/rtabmap.db"))
        #expect(entryPaths.contains("\(fake.scanId)/scan_metadata.db"))
        #expect(entryPaths.filter { $0 == "\(fake.scanId)/rtabmap.db" }.count == 1)
        // Sprint 49 (Codex BLOCKER 5): keyframes/ 폴더는 zip 에 포함되지 않는다.
        // RTABMap.db Data 테이블이 keyframe image source-of-truth.
        #expect(!entryPaths.contains("\(fake.scanId)/keyframes/000001.jpg"))
        #expect(!entryPaths.contains("\(fake.scanId)/keyframes/000002.jpg"))
    }

    @Test("archive — entry 경로가 scanId/ 접두로 시작")
    func archiveZipEntryPathsPrefixedWithScanId() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let fake = try FakeScanDirectoryFactory.make(in: tmp, keyframeSizes: [512])
        let destination = tmp.appendingPathComponent("output.zip")
        let archiver = ZipScanArchiver()

        try await archiver.archive(
            scanDirectory: fake.scanDirectory,
            destination: destination,
            scanId: fake.scanId
        ) { _ in }

        guard let archive = (try? Archive(url: destination, accessMode: .read, pathEncoding: nil)) else {
            Issue.record("ZIP 파일을 열 수 없음")
            return
        }

        for entry in archive {
            #expect(entry.path.hasPrefix(fake.scanId + "/"), "경로 '\(entry.path)'가 '\(fake.scanId)/'로 시작해야 함")
        }
    }

    @Test("archive — progress가 단조 증가")
    func archiveProgressMonotonicallyIncreasing() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let fake = try FakeScanDirectoryFactory.make(
            in: tmp,
            rtabmapSize: 8192,
            keyframeSizes: [2048, 4096, 3072]
        )
        let destination = tmp.appendingPathComponent("output.zip")
        let archiver = ZipScanArchiver()

        var progressValues: [Int64] = []
        try await archiver.archive(
            scanDirectory: fake.scanDirectory,
            destination: destination,
            scanId: fake.scanId
        ) { progress in
            progressValues.append(progress.processedBytes)
        }

        #expect(!progressValues.isEmpty, "progress 콜백이 최소 1회 이상 호출되어야 함")

        // 단조 증가 검증
        for index in 1..<progressValues.count {
            #expect(
                progressValues[index] >= progressValues[index - 1],
                "progress[\(index)]=\(progressValues[index])가 progress[\(index-1)]=\(progressValues[index-1])보다 작음"
            )
        }
    }

    @Test("archive — Sprint 74: raw_video_recording 도 rtabmap.db 없으면 실패")
    func archiveWithoutRtabmapDbThrows() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let fake = try FakeScanDirectoryFactory.makeWithoutRtabmapDb(in: tmp)
        let destination = tmp.appendingPathComponent("output.zip")
        let archiver = ZipScanArchiver()

        await #expect(throws: ScanArchiveError.sourceFileMissing("rtabmap.db")) {
            try await archiver.archive(
                scanDirectory: fake.scanDirectory,
                destination: destination,
                scanId: fake.scanId
            ) { _ in }
        }
    }

    @Test("archive — 용량 부족 시 insufficientStorage 에러")
    func archiveInsufficientStorageThrows() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let fake = try FakeScanDirectoryFactory.make(in: tmp)
        let destination = tmp.appendingPathComponent("output.zip")

        // 용량을 1 byte로 stub
        let archiver = ZipScanArchiver(availableCapacityProvider: { 1 })

        await #expect(throws: ScanArchiveError.self) {
            try await archiver.archive(
                scanDirectory: fake.scanDirectory,
                destination: destination,
                scanId: fake.scanId
            ) { _ in }
        }
    }

    @Test("archive — 기존 파일이 있으면 덮어씀")
    func archiveOverwritesExistingDestination() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let fake = try FakeScanDirectoryFactory.make(in: tmp, keyframeSizes: [512])
        let destination = tmp.appendingPathComponent("output.zip")
        let archiver = ZipScanArchiver()

        // 첫 번째 아카이브
        try await archiver.archive(
            scanDirectory: fake.scanDirectory,
            destination: destination,
            scanId: fake.scanId
        ) { _ in }

        let firstSize = try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64

        // 두 번째 아카이브 (같은 경로) — 에러 없이 성공해야 함
        try await archiver.archive(
            scanDirectory: fake.scanDirectory,
            destination: destination,
            scanId: fake.scanId
        ) { _ in }

        let secondSize = try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64

        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(firstSize == secondSize, "동일 소스이므로 파일 크기가 같아야 함")
    }

    @Test("archive — ZIP entry 바이트 수가 원본 파일과 일치")
    func archiveEntryBytesMatchSourceFiles() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let rtabmapSize = 8192
        let metadataSize = 2048
        let keyframeSizes = [1024, 3072]
        let fake = try FakeScanDirectoryFactory.make(
            in: tmp,
            rtabmapSize: rtabmapSize,
            metadataSize: metadataSize,
            keyframeSizes: keyframeSizes
        )
        let destination = tmp.appendingPathComponent("output.zip")
        let archiver = ZipScanArchiver()

        try await archiver.archive(
            scanDirectory: fake.scanDirectory,
            destination: destination,
            scanId: fake.scanId
        ) { _ in }

        guard let archive = (try? Archive(url: destination, accessMode: .read, pathEncoding: nil)) else {
            Issue.record("ZIP 파일을 열 수 없음")
            return
        }

        let expectedSizes: [String: Int] = [
            "\(fake.scanId)/rtabmap.db": rtabmapSize,
            "\(fake.scanId)/scan_metadata.db": metadataSize,
            "\(fake.scanId)/keyframes/000001.jpg": keyframeSizes[0],
            "\(fake.scanId)/keyframes/000002.jpg": keyframeSizes[1],
        ]

        for entry in archive {
            guard let expected = expectedSizes[entry.path] else { continue }
            #expect(
                entry.uncompressedSize == UInt64(expected),
                "entry '\(entry.path)': uncompressedSize=\(entry.uncompressedSize), expected=\(expected)"
            )
        }
    }

    @Test("archive — 소스 디렉터리 없으면 sourceDirectoryMissing 에러")
    func archiveMissingScanDirectoryThrows() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let nonExistent = tmp.appendingPathComponent("nonexistent/\(UUID().uuidString)")
        let destination = tmp.appendingPathComponent("output.zip")
        let archiver = ZipScanArchiver()

        await #expect(throws: ScanArchiveError.sourceDirectoryMissing) {
            try await archiver.archive(
                scanDirectory: nonExistent,
                destination: destination,
                scanId: "test-scan-id"
            ) { _ in }
        }
    }
}
