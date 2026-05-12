import Foundation

/// chunk 업로드 상태 머신.
/// ADR D4 — URLSession background config 기반 큐 상태.
enum ChunkUploadState: String, Codable, Sendable, CaseIterable {
    /// zip 빌드 중.
    case archiving
    /// zip 빌드 완료, URLSession upload task 대기.
    case queued
    /// URLSession task 진행 중.
    case uploading
    /// 서버 200 OK + serverChunkId 확보.
    case done
    /// 재시도 가능 상태.
    case failed
    /// startedAt + 7일 초과, merge 불가.
    case expired
}
