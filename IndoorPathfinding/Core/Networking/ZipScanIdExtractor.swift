import Foundation
import ZIPFoundation

/// zip 파일에서 scan_id 를 추출하는 유틸리티.
///
/// 우선순위:
/// 1. zip 내부 `manifest.json` → `scan_id` 키
/// 2. zip 파일명이 UUID 형식이면 채택
/// 3. 둘 다 실패 → nil (서버가 새 UUID 생성)
enum ZipScanIdExtractor {

    /// zip URL 에서 scan_id 를 추출한다.
    static func extractScanId(from zipURL: URL) -> UUID? {
        // (a) manifest.json 우선
        if let idFromManifest = extractFromManifest(zipURL) {
            return idFromManifest
        }
        // (b) 파일명 UUID 판정
        let stem = zipURL.deletingPathExtension().lastPathComponent
        if let uuid = UUID(uuidString: stem) {
            return uuid
        }
        return nil
    }

    // MARK: - Private

    private static func extractFromManifest(_ zipURL: URL) -> UUID? {
        guard let archive = try? Archive(url: zipURL, accessMode: .read, pathEncoding: nil) else { return nil }

        // zip 내부에서 manifest.json 찾기 (최상위 또는 1단계 하위 폴더)
        let candidates = ["manifest.json"]
            + archive.compactMap { entry -> String? in
                let path = entry.path
                // e.g. "7B018DCA-.../manifest.json"
                guard path.hasSuffix("/manifest.json") || path == "manifest.json" else { return nil }
                return path
            }

        for path in candidates {
            guard let entry = archive[path] else { continue }
            var data = Data()
            do {
                _ = try archive.extract(entry) { chunk in
                    data.append(chunk)
                }
            } catch {
                continue
            }
            if let idStr = parseManifestScanId(from: data) {
                return UUID(uuidString: idStr)
            }
        }
        return nil
    }

    private static func parseManifestScanId(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scanId = json["scan_id"] as? String else {
            return nil
        }
        return scanId
    }
}
