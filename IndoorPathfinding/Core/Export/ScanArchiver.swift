import Foundation

/// 스캔 디렉터리 → 단일 업로드 패키지 변환 계약.
/// - 구현체는 파일 I/O를 모두 background queue에서 수행하고,
///   progress 콜백을 @MainActor로 dispatch해야 한다.
protocol ScanArchiver: Sendable {
    /// scanDirectory 전체를 destination(단일 파일 URL)로 아카이브한다.
    /// progress 콜백은 여러 번 호출될 수 있으며 processed/total 모두 단조 증가 보장.
    func archive(
        scanDirectory: URL,
        destination: URL,
        scanId: String,
        progress: @Sendable @escaping (ArchiveProgress) -> Void
    ) async throws
}

struct ArchiveProgress: Sendable, Equatable {
    let processedBytes: Int64
    let totalBytes: Int64

    var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(processedBytes) / Double(totalBytes)
    }
}

enum ScanArchiveError: LocalizedError, Equatable {
    case sourceDirectoryMissing
    case sourceFileMissing(String)
    case insufficientStorage(requiredBytes: Int64, availableBytes: Int64)
    case archiveFailed(underlying: String)

    var errorDescription: String? {
        switch self {
        case .sourceDirectoryMissing:
            return "스캔 폴더를 찾을 수 없습니다."
        case .sourceFileMissing(let name):
            return "필수 파일이 없습니다: \(name)"
        case .insufficientStorage(let req, let avail):
            return "저장 공간 부족 — 필요 \(req) bytes, 가용 \(avail) bytes"
        case .archiveFailed(let underlying):
            return "아카이브 생성 실패: \(underlying)"
        }
    }
}
