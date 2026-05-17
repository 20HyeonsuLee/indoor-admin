import Observation
import Foundation

/// ChunkUploadQueue 상태를 SwiftUI에 binding하는 Observable wrapper.
/// ADR D5 — badge/sheet가 구독하는 단일 상태 소스.
@Observable
@MainActor
final class ChunkUploadObserver {

    // MARK: - Published state

    private(set) var manifests: [UUID: ChunkManifest] = [:]

    /// 업로드 완료 수 / 전체 수 (done / total).
    var doneCount: Int {
        manifests.values.filter { $0.uploadState == .done }.count
    }

    var totalCount: Int {
        manifests.count
    }

    var archivingCount: Int {
        manifests.values.filter { $0.uploadState == .archiving }.count
    }

    var queuedCount: Int {
        manifests.values.filter { $0.uploadState == .queued }.count
    }

    var uploadingCount: Int {
        manifests.values.filter { $0.uploadState == .uploading }.count
    }

    var failedCount: Int {
        manifests.values.filter { $0.uploadState == .failed }.count
    }

    var expiredCount: Int {
        manifests.values.filter { $0.uploadState == .expired }.count
    }

    var archivedKeyframeTotal: Int {
        manifests.values.reduce(0) { $0 + ($1.archivedKeyframeCount ?? 0) }
    }

    var telemetryText: String {
        let bad = failedCount + expiredCount
        return "done \(doneCount)/\(totalCount) · zip \(archivingCount) · queue \(queuedCount) · up \(uploadingCount) · fail \(bad)"
    }

    /// badge 텍스트 "N/M" 형식.
    /// ADR D7: totalCount == 0 이어도 "0/0"을 반환한다 — observer wiring 검증 수단.
    var badgeText: String {
        let bad = failedCount + expiredCount
        return bad > 0 ? "\(doneCount)/\(totalCount) !\(bad)" : "\(doneCount)/\(totalCount)"
    }

    /// 모든 chunk가 done 상태일 때 true — "머지 실행" 버튼 enable 조건. ADR D7.
    var canMerge: Bool {
        guard !manifests.isEmpty else { return false }
        return manifests.values.allSatisfy { $0.uploadState == .done }
    }

    /// 업로드 진행 중인 chunk 개수 (queued + archiving + uploading).
    var pendingCount: Int {
        manifests.values.filter {
            $0.uploadState == .queued || $0.uploadState == .archiving || $0.uploadState == .uploading
        }.count
    }

    /// done이 아닌 chunk가 있어 새 scan을 차단해야 하면 reason 반환.
    var scanBlockedReason: String? {
        guard manifests.count >= ChunkUploadQueue.chunkCountCap else { return nil }
        if !canMerge {
            return "대기 중인 업로드가 \(ChunkUploadQueue.chunkCountCap)개에 달했습니다. 업로드 완료 후 새 스캔을 시작할 수 있습니다."
        }
        return nil
    }

    /// 현재 floor의 done chunk id 목록. mergeChunks 호출 인자용.
    func doneServerChunkIds() -> [UUID] {
        manifests.values
            .filter { $0.uploadState == .done }
            .compactMap { $0.serverChunkId }
            .sorted { $0.uuidString < $1.uuidString }
    }

    // MARK: - ChunkUploadQueue callback

    /// ChunkUploadQueue에서 state 변경 시 호출한다.
    func didUpdate(queue: [UUID: ChunkManifest]) {
        manifests = queue
    }
}
