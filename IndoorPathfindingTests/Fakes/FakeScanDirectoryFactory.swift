import Foundation

/// 테스트용 가짜 스캔 디렉터리 생성 팩토리.
enum FakeScanDirectoryFactory {

    struct Result {
        let scanDirectory: URL
        let scanId: String
        let totalBytes: Int
    }

    static func make(
        in parent: URL,
        scanId: String = UUID().uuidString,
        rtabmapSize: Int = 4096,
        metadataSize: Int = 1024,
        keyframeSizes: [Int] = [1024, 2048, 3072]
    ) throws -> Result {
        let fm = FileManager.default
        let scanDir = parent.appendingPathComponent("scans/\(scanId)")
        try fm.createDirectory(
            at: scanDir.appendingPathComponent("keyframes"),
            withIntermediateDirectories: true
        )

        let rtab = Data(repeating: 0xAA, count: rtabmapSize)
        try rtab.write(to: scanDir.appendingPathComponent("rtabmap.db"))

        let meta = Data(repeating: 0xBB, count: metadataSize)
        try meta.write(to: scanDir.appendingPathComponent("scan_metadata.db"))

        var total = rtabmapSize + metadataSize
        for (index, size) in keyframeSizes.enumerated() {
            let data = Data(repeating: UInt8(index & 0xFF), count: size)
            let name = String(format: "%06d.jpg", index + 1)
            try data.write(to: scanDir.appendingPathComponent("keyframes/\(name)"))
            total += size
        }

        return Result(scanDirectory: scanDir, scanId: scanId, totalBytes: total)
    }

    /// rtabmap.db를 생성하지 않는 디렉터리 (sourceFileMissing 에러 재현용).
    static func makeWithoutRtabmapDb(
        in parent: URL,
        scanId: String = UUID().uuidString
    ) throws -> Result {
        let fm = FileManager.default
        let scanDir = parent.appendingPathComponent("scans/\(scanId)")
        try fm.createDirectory(
            at: scanDir.appendingPathComponent("keyframes"),
            withIntermediateDirectories: true
        )

        let meta = Data(repeating: 0xBB, count: 512)
        try meta.write(to: scanDir.appendingPathComponent("scan_metadata.db"))

        return Result(scanDirectory: scanDir, scanId: scanId, totalBytes: 512)
    }
}
