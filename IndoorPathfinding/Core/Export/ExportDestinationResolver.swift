import Foundation

/// exports/ 디렉터리 및 파일명 계산. 중복 시 timestamp suffix.
struct ExportDestinationResolver {
    let exportsDirectory: URL

    func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: exportsDirectory,
            withIntermediateDirectories: true
        )
    }

    /// Documents/exports/{scan_id}.zip — 중복 시 {scan_id}_{YYYYMMDDHHmmss}.zip.
    func makeFileURL(scanId: String, now: Date = Date()) -> URL {
        let primary = exportsDirectory.appendingPathComponent("\(scanId).zip")
        guard FileManager.default.fileExists(atPath: primary.path) else {
            return primary
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMddHHmmss"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        let suffix = fmt.string(from: now)
        return exportsDirectory.appendingPathComponent("\(scanId)_\(suffix).zip")
    }
}
