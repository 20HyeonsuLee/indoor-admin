import SwiftUI
import UniformTypeIdentifiers

struct AdminFloorDetailView: View {
    @State var workspace: AdminWorkspaceStore
    let building: AdminBuilding
    let floor: AdminFloor

    @State private var isPickerPresented = false
    @State private var isUploading = false
    @State private var uploadQueue: [URL] = []
    @State private var isMerging = false
    @State private var pollingTask: Task<Void, Never>?
    @State private var showGraphView = false
    @State private var showChunkQueue = false

    // Sprint 86 cycle 1: 스캔 캡처 진입점
    @State private var scanLaunchContext: ScanLaunchContext?

    /// ADR D7: ScanSessionView가 dismiss된 후에도 upload 상태를 유지하기 위해
    /// AdminFloorDetailView가 observer를 소유한다.
    @State private var chunkUploadObserver = ChunkUploadObserver()
    @State private var chunkUploadQueue: ChunkUploadQueue?

    var chunks: [AdminScanChunk] {
        (workspace.chunks[floor.id] ?? []).sorted { $0.uploadOrder < $1.uploadOrder }
    }

    var hasCompletedBuild: Bool {
        chunks.contains { $0.status == AdminScanChunk.ChunkStatus.completed }
    }

    /// ADR D7: merge 버튼 disable 조건.
    /// true이면 merge 불가 — 다음 중 하나라도 해당되면 disabled:
    ///   1. scan session 활성 중
    ///   2. chunked upload 진행 중 / failed / expired chunk 존재 (ChunkUploadObserver.canMerge == false)
    ///   3. 서버에서 선택된 chunk 없음 (workspace.canMerge == false)
    var isMergeDisabled: Bool {
        if scanLaunchContext != nil { return true }
        if !chunkUploadObserver.manifests.isEmpty && !chunkUploadObserver.canMerge { return true }
        return !workspace.canMerge
    }

    /// ADR D7: merge 버튼 추가 disable 이유 (사용자에게 표시 가능).
    var mergeBlockedReason: String? {
        if scanLaunchContext != nil { return "스캔 진행 중에는 병합할 수 없습니다." }
        if !chunkUploadObserver.manifests.isEmpty && !chunkUploadObserver.canMerge {
            return "업로드가 완료되지 않은 chunk가 있습니다."
        }
        return nil
    }

    var body: some View {
        List {
            // Sprint 86 cycle 1: 스캔 캡처
            Section("스캔 캡처") {
                Button {
                    ensureChunkUploadQueue()
                    scanLaunchContext = ScanLaunchContext(
                        buildingId: building.id,
                        floorId: floor.id,
                        floorName: floor.displayName,
                        floorLevel: floor.level
                    )
                } label: {
                    Label("스캔 시작", systemImage: "video.badge.plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Section("청크 업로드") {
                Button {
                    showChunkQueue = true
                } label: {
                    HStack {
                        Label("업로드 대기열", systemImage: "arrow.up.circle.fill")
                        Spacer()
                        Text(chunkUploadObserver.badgeText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                if chunkUploadObserver.totalCount == 0 {
                    Text("생성된 청크가 없습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if chunkUploadObserver.pendingCount > 0 {
                    HStack {
                        ProgressView()
                        Text("\(chunkUploadObserver.pendingCount)개 업로드 진행 중")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if chunkUploadObserver.canMerge {
                    Label("업로드 완료", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            // Upload
            Section {
                Button {
                    isPickerPresented = true
                } label: {
                    Label("Zip 파일 업로드", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(isUploading)

                if isUploading {
                    HStack {
                        ProgressView()
                        Text("업로드 중... (\(uploadQueue.count)개 남음)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("스캔 업로드")
            }

            // Chunk list
            Section {
                if chunks.isEmpty {
                    Text("업로드된 스캔이 없습니다.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    ForEach(chunks) { chunk in
                        ChunkRow(
                            chunk: chunk,
                            isSelected: workspace.selectedChunkIds.contains(chunk.id),
                            onToggle: { workspace.toggleChunkSelection(chunk) }
                        )
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await workspace.deleteChunk(chunk) }
                            } label: {
                                Label("삭제", systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("스캔 목록")
                    Spacer()
                    if !workspace.selectedChunkIds.isEmpty {
                        Text("\(workspace.selectedChunkIds.count)개 선택됨")
                            .font(.caption)
                            .foregroundStyle(.tint)
                    }
                }
            }

            // Merge
            // ADR D7: "머지 실행" 버튼은 명시 트리거 방식.
            // 비활성 조건:
            //   1. workspace.canMerge (서버 chunk 선택 여부) — 기존 조건 유지
            //   2. chunkUploadObserver.manifests가 비어있지 않고 canMerge가 false
            //      (진행 중인 upload 혹은 failed/expired chunk가 있으면 머지 불가)
            //   3. scan session이 활성인 동안 (scanLaunchContext != nil)
            Section {
                Button {
                    Task { await startMerge() }
                } label: {
                    Label(
                        isMerging ? "병합 중..." : "선택한 스캔 병합",
                        systemImage: isMerging ? "arrow.triangle.2.circlepath" : "arrow.triangle.merge"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(isMergeDisabled || isMerging)

                if let mergeStatus = workspace.mergeStatus {
                    HStack {
                        Image(systemName: statusIcon(mergeStatus))
                            .foregroundStyle(statusColor(mergeStatus))
                        Text("병합: \(mergeStatus)")
                            .font(.caption)
                    }
                }

                if let processStatus = workspace.processStatus {
                    HStack {
                        if processStatus == "PROCESSING" {
                            ProgressView()
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: statusIcon(processStatus))
                                .foregroundStyle(statusColor(processStatus))
                        }
                        Text("빌드: \(processStatus)")
                            .font(.caption)
                        if let progress = workspace.processProgress {
                            Text("\(Int(progress * 100))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("병합 및 빌드")
            } footer: {
                if let reason = mergeBlockedReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            // Graph
            Section {
                NavigationLink {
                    AdminFloorGraphView(workspace: workspace, building: building, floor: floor)
                } label: {
                    Label("그래프 보기", systemImage: "map")
                }
                // F4: floor.hasPath (서버 로드 결과) 또는 이번 세션 빌드 완료 시 활성
                .disabled(!floor.hasPath && !hasCompletedBuild && workspace.processStatus != "COMPLETED")
            } header: {
                Text("그래프")
            } footer: {
                if !floor.hasPath && !hasCompletedBuild && workspace.processStatus != "COMPLETED" {
                    Text("병합 및 빌드 완료 후 활성화됩니다.")
                        .font(.caption)
                }
            }
        }
        .navigationTitle(floor.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task { await workspace.loadChunks(floorId: floor.id) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .fileImporter(
            isPresented: $isPickerPresented,
            allowedContentTypes: [UTType.zip],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task { await uploadFiles(urls) }
            case .failure(let error):
                workspace.errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $showChunkQueue) {
            ChunkQueueSheet(observer: chunkUploadObserver, queue: chunkUploadQueue)
        }
        .fullScreenCover(item: $scanLaunchContext) { context in
            ScanSessionView(
                launchContext: context,
                // ADR D4/D6: serverClient를 넘겨 chunked background upload 활성.
                serverClient: workspace.v1Client,
                // ADR D7: AdminFloorDetailView가 소유한 observer를 주입.
                // ScanSessionView dismiss 후에도 upload 상태가 유지되어 merge 버튼 disable에 사용.
                chunkUploadObserver: chunkUploadObserver,
                chunkUploadQueue: chunkUploadQueue,
                onFinished: { zipURL in
                    // Sprint 89 cycle_2: 자동 업로드 복원. ZIP은 Documents/exports/ 보존 +
                    // 서버로 즉시 업로드 (사용자 데이터 검증 완료, server alembic 0008 deploy됨).
                    workspace.lastExportedZipURL = zipURL
                    await workspace.uploadChunk(floorId: floor.id, fileURL: zipURL)
                },
                onDiscarded: {
                    // 폐기: 별도 처리 불필요
                }
            )
        }
        .onAppear {
            ensureChunkUploadQueue()
        }
        .task {
            await workspace.loadChunks(floorId: floor.id)
            workspace.selectFloor(floor.id)
        }
        .onDisappear {
            pollingTask?.cancel()
            pollingTask = nil
        }
        .overlay(alignment: .bottom) {
            if let msg = workspace.errorMessage {
                Text(msg)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
                    .padding()
                    .onTapGesture { workspace.errorMessage = nil }
            }
        }
    }

    @MainActor
    private func ensureChunkUploadQueue() {
        guard chunkUploadQueue == nil, let client = workspace.v1Client else { return }
        let queue = ChunkUploadQueue(serverClient: client)
        queue.observer = chunkUploadObserver
        try? queue.restoreFromStaging()
        chunkUploadQueue = queue
    }

    private func uploadFiles(_ urls: [URL]) async {
        isUploading = true
        uploadQueue = urls
        defer { isUploading = false; uploadQueue = [] }

        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            await workspace.uploadChunk(floorId: floor.id, fileURL: url)
            uploadQueue = Array(uploadQueue.dropFirst())
        }
    }

    private func startMerge() async {
        isMerging = true
        defer { isMerging = false }
        await workspace.mergeSelectedChunks(floorId: floor.id)
        startPolling()
    }

    private func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task {
            var attempts = 0
            while !Task.isCancelled && attempts < 60 {
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5초
                await workspace.pollProcessStatus(floorId: floor.id)
                attempts += 1
                if workspace.processStatus == "COMPLETED" || workspace.processStatus == "FAILED" {
                    break
                }
            }
        }
    }

    private func statusIcon(_ status: String) -> String {
        switch status {
        case "COMPLETED": return "checkmark.circle.fill"
        case "FAILED": return "xmark.circle.fill"
        case "PROCESSING": return "arrow.triangle.2.circlepath"
        default: return "circle"
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "COMPLETED": return .green
        case "FAILED": return .red
        case "PROCESSING": return .orange
        default: return .secondary
        }
    }
}

// MARK: - Chunk Row

struct ChunkRow: View {
    let chunk: AdminScanChunk
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack {
            Button(action: onToggle) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!chunk.status.isSelectable)

            VStack(alignment: .leading, spacing: 2) {
                Text(chunk.fileName ?? chunk.scanId.uuidString.prefix(8) + "...")
                    .font(.subheadline)
                    .lineLimit(1)
                HStack {
                    Text(chunk.status.label)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(statusBackground(chunk.status), in: Capsule())
                        .foregroundStyle(statusForeground(chunk.status))

                    if let size = chunk.fileSize {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if chunk.active {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .contentShape(Rectangle())
    }

    private func statusBackground(_ status: AdminScanChunk.ChunkStatus) -> Color {
        switch status {
        case .completed: return .green.opacity(0.15)
        case .failed: return .red.opacity(0.15)
        case .processing: return .orange.opacity(0.15)
        case .uploaded, .merged: return .blue.opacity(0.15)
        default: return .gray.opacity(0.15)
        }
    }

    private func statusForeground(_ status: AdminScanChunk.ChunkStatus) -> Color {
        switch status {
        case .completed: return .green
        case .failed: return .red
        case .processing: return .orange
        case .uploaded, .merged: return .blue
        default: return .secondary
        }
    }
}
