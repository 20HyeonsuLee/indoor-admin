import Foundation
import ZIPFoundation

/// ZIPFoundation 기반 archiver. compression method는 `.none`(store) 고정.
/// 대용량 파일은 ZIPFoundation 내부 스트리밍 → 메모리 상주 최소.
struct ZipScanArchiver: ScanArchiver {

    /// 패키지에 반드시 포함되어야 하는 파일 (상대경로).
    /// Sprint 49: keyframes/ 디렉터리 제거. manifest.json 추가 (있으면).
    /// Sprint 67: rtabmap.db 는 main build 의 SSOT 이므로 v7 raw_video_recording 에서도 필수.
    ///   scan.mp4 + poses.bin 은 dense evidence / quality report 보조 입력.
    static let requiredFiles: [String] = [
        "scan_metadata.db",
        "rtabmap.db",
    ]
    /// 옵션 파일 — 존재할 때만 zip 에 포함.
    /// Sprint 90 live_rtabmap: mp4/poses.bin 제거 (iOS 라이브 RTAB-Map만 사용).
    static let optionalFiles: [String] = [
        "manifest.json",
    ]

    /// 용량 확인용 provider. 테스트에서 override 가능.
    let availableCapacityProvider: (@Sendable () -> Int64?)?

    init(availableCapacityProvider: (@Sendable () -> Int64?)? = nil) {
        self.availableCapacityProvider = availableCapacityProvider
    }

    func archive(
        scanDirectory: URL,
        destination: URL,
        scanId: String,
        progress: @Sendable @escaping (ArchiveProgress) -> Void
    ) async throws {
        try archiveBlocking(
            scanDirectory: scanDirectory,
            destination: destination,
            scanId: scanId,
            progress: progress
        )
    }

    /// Synchronous implementation for callers that already moved file I/O off the main actor.
    func archiveBlocking(
        scanDirectory: URL,
        destination: URL,
        scanId: String,
        progress: @Sendable @escaping (ArchiveProgress) -> Void
    ) throws {
        let fm = FileManager.default

        guard fm.fileExists(atPath: scanDirectory.path) else {
            throw ScanArchiveError.sourceDirectoryMissing
        }

        // 1. 대상 파일 수집 + 총 바이트 계산
        let plan = try makePlan(scanDirectory: scanDirectory, scanId: scanId)

        // 2. 용량 확인
        let requiredBytes = plan.totalBytes + (Int64(plan.entries.count) * 128)
        let capacityCheck = availableCapacityProvider ?? ScanFileStore.availableCapacityForImportantUsage
        if let available = capacityCheck(), requiredBytes > available {
            throw ScanArchiveError.insufficientStorage(
                requiredBytes: requiredBytes,
                availableBytes: available
            )
        }

        // 3. 기존 파일 삭제 (덮어쓰기)
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // 4. ZIP 생성 (create 모드)
        let archive: Archive
        do {
            archive = try Archive(url: destination, accessMode: .create)
        } catch {
            throw ScanArchiveError.archiveFailed(
                underlying: "Archive(url:accessMode:.create) failed: \(error.localizedDescription)"
            )
        }

        // 5. entry 하나씩 addEntry — Foundation.Progress로 바이트 추적
        var processed: Int64 = 0
        let totalBytes = plan.totalBytes

        for entry in plan.entries {
            let entryProgress = Foundation.Progress(totalUnitCount: entry.byteCount)
            let processedBeforeEntry = processed

            // KVO 관찰: completedUnitCount 변화마다 콜백 호출
            let observation = entryProgress.observe(\.completedUnitCount, options: [.new]) { p, _ in
                let snap = processedBeforeEntry + p.completedUnitCount
                progress(ArchiveProgress(processedBytes: snap, totalBytes: totalBytes))
            }
            defer { observation.invalidate() }

            try archive.addEntry(
                with: entry.zipRelativePath,
                fileURL: entry.sourceURL,
                compressionMethod: .none,
                bufferSize: 1 << 18,   // 256 KB 스트림 청크
                progress: entryProgress
            )

            processed += entry.byteCount
        }

        // 6. 완료 콜백
        progress(ArchiveProgress(processedBytes: totalBytes, totalBytes: totalBytes))
    }

    // MARK: - Plan

    private struct Plan {
        let entries: [PlannedEntry]
        let totalBytes: Int64
    }

    private struct PlannedEntry {
        let sourceURL: URL
        /// ZIP 내부 경로. "scan_id/..." 접두 필수.
        let zipRelativePath: String
        let byteCount: Int64
    }

    private func makePlan(scanDirectory: URL, scanId: String) throws -> Plan {
        let fm = FileManager.default
        var entries: [PlannedEntry] = []
        var total: Int64 = 0

        // 필수 루트 파일
        for name in Self.requiredFiles {
            let url = scanDirectory.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else {
                throw ScanArchiveError.sourceFileMissing(name)
            }
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            entries.append(PlannedEntry(
                sourceURL: url,
                zipRelativePath: "\(scanId)/\(name)",
                byteCount: size
            ))
            total += size
        }

        // Sprint 49: keyframes/ 폴더 자체를 zip 에 포함하지 않는다.
        // RTABMap.db Data 테이블이 keyframe image source-of-truth. R-1 trade-off
        // (reject frame image 영구 손실) 는 manifest.json 에 명시.

        // 옵션 파일 (manifest.json 등)
        for name in Self.optionalFiles {
            let url = scanDirectory.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else { continue }
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            entries.append(PlannedEntry(
                sourceURL: url,
                zipRelativePath: "\(scanId)/\(name)",
                byteCount: size
            ))
            total += size
        }

        return Plan(entries: entries, totalBytes: total)
    }
}
