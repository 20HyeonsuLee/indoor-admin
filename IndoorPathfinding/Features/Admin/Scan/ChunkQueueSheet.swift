import SwiftUI

/// chunk upload 대기열을 보여주는 sheet.
/// ADR D5 — 상태 목록 + 재시도/삭제 swipe action.
struct ChunkQueueSheet: View {
    let observer: ChunkUploadObserver
    /// ADR D5: retry/delete swipe action을 위해 queue를 주입받는다.
    /// nil이면 swipe action을 표시하지 않는다 (read-only 모드).
    let queue: ChunkUploadQueue?
    @Environment(\.dismiss) private var dismiss

    init(observer: ChunkUploadObserver, queue: ChunkUploadQueue? = nil) {
        self.observer = observer
        self.queue = queue
    }

    var sortedManifests: [(UUID, ChunkManifest)] {
        observer.manifests
            .sorted { $0.value.chunkIndex < $1.value.chunkIndex }
    }

    var body: some View {
        NavigationStack {
            Group {
                if observer.manifests.isEmpty {
                    ContentUnavailableView(
                        "업로드 대기열 없음",
                        systemImage: "tray",
                        description: Text("스캔 중 chunk가 생성되면 여기에 표시됩니다.")
                    )
                } else {
                    List {
                        ForEach(sortedManifests, id: \.0) { chunkId, manifest in
                            ChunkQueueRow(chunkId: chunkId, manifest: manifest)
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    retryButton(chunkId: chunkId, manifest: manifest)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    deleteButton(chunkId: chunkId, manifest: manifest)
                                }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("업로드 대기열")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Swipe Actions (ADR D5)

    /// retry: failed 또는 expired 상태인 row에만 표시.
    @ViewBuilder
    private func retryButton(chunkId: UUID, manifest: ChunkManifest) -> some View {
        let isRetryable = manifest.uploadState == .failed || manifest.uploadState == .expired
        if isRetryable, let queue {
            Button {
                queue.retryChunk(chunkSessionId: chunkId)
            } label: {
                Label("재시도", systemImage: "arrow.counterclockwise")
            }
            .tint(.orange)
        }
    }

    /// delete: done, failed, expired 상태인 row에만 표시.
    @ViewBuilder
    private func deleteButton(chunkId: UUID, manifest: ChunkManifest) -> some View {
        let isDeletable = manifest.uploadState == .done
            || manifest.uploadState == .failed
            || manifest.uploadState == .expired
        if isDeletable, let queue {
            Button(role: .destructive) {
                queue.deleteChunk(chunkSessionId: chunkId)
            } label: {
                Label("삭제", systemImage: "trash")
            }
        }
    }
}

// MARK: - Row

private struct ChunkQueueRow: View {
    let chunkId: UUID
    let manifest: ChunkManifest

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Chunk \(manifest.chunkIndex)")
                    .font(.headline)
                Spacer()
                stateLabel
            }
            if let error = manifest.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            if manifest.overlapWarning {
                Label("overlap keyframe 부족 (merge 품질 위험)", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            HStack {
                Text(manifest.startedAt, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if manifest.retryCount > 0 {
                    Text("재시도 \(manifest.retryCount)회")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var stateLabel: some View {
        switch manifest.uploadState {
        case .archiving:
            Label("압축 중", systemImage: "archivebox")
                .font(.caption)
                .foregroundStyle(.orange)
        case .queued:
            Label("대기", systemImage: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .uploading:
            HStack(spacing: 4) {
                ProgressView().scaleEffect(0.6)
                Text("업로드 중")
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
        case .done:
            Label("완료", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed:
            Label("실패", systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        case .expired:
            Label("만료", systemImage: "clock.badge.xmark")
                .font(.caption)
                .foregroundStyle(.gray)
        }
    }
}
