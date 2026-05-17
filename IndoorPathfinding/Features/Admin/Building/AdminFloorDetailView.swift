import SwiftUI

struct AdminFloorDetailView: View {
    @State var workspace: AdminWorkspaceStore
    let building: AdminBuilding
    let floor: AdminFloor

    @State private var scanLaunchContext: ScanLaunchContext?
    @State private var isMerging = false
    @State private var isBuilding = false
    @State private var actionMessage: String?
    @State private var showAddArea = false

    // MARK: - Derived

    private var floorAreas: [V1FloorArea] {
        workspace.areasForFloor(floor.id)
    }

    private var currentAreaId: UUID? {
        workspace.effectiveAreaId(floorId: floor.id)
    }

    private var chunks: [AdminScanChunk] {
        workspace.chunksForArea(floorId: floor.id, areaId: currentAreaId)
            .sorted { $0.uploadOrder < $1.uploadOrder }
    }

    private var canMerge: Bool {
        !workspace.selectedChunkIds.isEmpty && !isMerging
    }

    private var currentAreaKey: FloorAreaKey? {
        currentAreaId.map { FloorAreaKey(floorId: floor.id, areaId: $0) }
    }

    private var currentMergeStatus: String? {
        currentAreaKey.flatMap { workspace.mergeStatus[$0] }
    }

    private var currentProcessStatus: String? {
        currentAreaKey.flatMap { workspace.processStatus[$0] }
    }

    var body: some View {
        List {
            // Area picker (areas > 1일 때만 표시)
            if floorAreas.count > 1 {
                areaPickerSection
            }

            // 스캔 캡처
            Section("스캔 캡처") {
                Button {
                    let effectiveAreaId = workspace.effectiveAreaId(floorId: floor.id)
                    let areaLabel = floorAreas.first { $0.areaId == effectiveAreaId }?.label ?? "default"
                    scanLaunchContext = ScanLaunchContext(
                        buildingId: building.id,
                        floorId: floor.id,
                        floorName: floor.displayName,
                        floorLevel: floor.level,
                        areaId: effectiveAreaId,
                        areaLabel: areaLabel
                    )
                } label: {
                    Label("스캔 시작", systemImage: "video.badge.plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            // 스캔 목록 (서버에 올라간 것)
            Section {
                if chunks.isEmpty {
                    Text("업로드된 스캔이 없습니다.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    ForEach(chunks) { chunk in
                        ScanRow(
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

            // 병합
            Section {
                Button {
                    Task { await runMerge() }
                } label: {
                    Label(
                        isMerging ? "병합 중..." : "선택 스캔 병합",
                        systemImage: isMerging ? "arrow.triangle.2.circlepath" : "arrow.triangle.merge"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(!canMerge)
            } header: {
                Text("병합")
            } footer: {
                if workspace.selectedChunkIds.isEmpty {
                    Text("병합할 스캔을 선택하세요.")
                        .font(.caption)
                }
            }

            // 빌드
            Section {
                Button {
                    Task { await runBuild() }
                } label: {
                    Label(
                        isBuilding ? "빌드 요청 중..." : "스캔 빌드",
                        systemImage: isBuilding ? "arrow.triangle.2.circlepath" : "hammer"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(isBuilding)

                if let actionMessage {
                    Text(actionMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("빌드")
            }

            // 그래프
            Section {
                NavigationLink {
                    AdminFloorGraphView(workspace: workspace, building: building, floor: floor)
                } label: {
                    Label("그래프 보기", systemImage: "map")
                }
                .disabled(!floor.hasPath && currentProcessStatus != "COMPLETED")
            } header: {
                Text("그래프")
            }
        }
        .navigationTitle(floor.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    showAddArea = true
                } label: {
                    Image(systemName: "plus.rectangle.on.folder")
                }
                Button {
                    Task {
                        await workspace.loadChunks(floorId: floor.id, areaId: currentAreaId)
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .sheet(isPresented: $showAddArea) {
            AddAreaSheet(
                defaultLabel: "Area \((floorAreas.count + 1))",
                onSave: { label in
                    Task {
                        do {
                            let created = try await workspace.addArea(floorId: floor.id, label: label)
                            workspace.selectArea(floorId: floor.id, areaId: created.areaId)
                            await workspace.loadChunks(floorId: floor.id, areaId: created.areaId)
                        } catch {
                            workspace.errorMessage = error.localizedDescription
                        }
                    }
                }
            )
        }
        .fullScreenCover(item: $scanLaunchContext) { context in
            ScanSessionView(
                launchContext: context,
                serverClient: workspace.v1Client,
                onFinished: { _ in
                    Task { await workspace.loadChunks(floorId: floor.id, areaId: currentAreaId) }
                },
                onDiscarded: { /* no-op */ }
            )
        }
        .task {
            workspace.selectFloor(floor.id)
            await workspace.loadAreas(floorId: floor.id)
            await workspace.loadChunks(floorId: floor.id, areaId: workspace.effectiveAreaId(floorId: floor.id))
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

    // MARK: - Area Picker Section

    @ViewBuilder
    private var areaPickerSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(floorAreas) { area in
                        AreaChip(
                            area: area,
                            isSelected: currentAreaId == area.areaId,
                            onTap: {
                                workspace.selectArea(floorId: floor.id, areaId: area.areaId)
                                Task {
                                    await workspace.loadChunks(floorId: floor.id, areaId: area.areaId)
                                }
                            }
                        )
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            if let areaLabel = floorAreas.first(where: { $0.areaId == currentAreaId })?.label {
                Text("area: \(areaLabel)")
            } else {
                Text("area")
            }
        }
    }

    // MARK: - Actions

    @MainActor
    private func runMerge() async {
        isMerging = true
        defer { isMerging = false }
        actionMessage = nil
        await workspace.mergeSelectedChunks(floorId: floor.id, areaId: currentAreaId)
        await workspace.loadChunks(floorId: floor.id, areaId: currentAreaId)
        actionMessage = "병합 완료"
    }

    @MainActor
    private func runBuild() async {
        guard let baseURL = workspace.serverSettings.baseURL else {
            actionMessage = "서버 URL이 설정되지 않았습니다."
            return
        }
        isBuilding = true
        defer { isBuilding = false }
        do {
            let streamingClient = StreamingScanClient(
                baseURL: baseURL,
                token: workspace.serverSettings.token
            )
            try await streamingClient.triggerBuild(floorId: floor.id)
            actionMessage = "빌드 시작됨"
        } catch {
            actionMessage = "빌드 요청 실패: \(error.localizedDescription)"
        }
    }
}

// MARK: - Area Chip

private struct AreaChip: View {
    let area: V1FloorArea
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                if area.isDefault {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                }
                Text(area.label)
                    .font(.subheadline)
                    .fontWeight(isSelected ? .semibold : .regular)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                isSelected ? Color.accentColor : Color.secondary.opacity(0.15),
                in: Capsule()
            )
            .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Add Area Sheet

struct AddAreaSheet: View {
    let defaultLabel: String
    let onSave: (String) -> Void

    @State private var label: String = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("area 이름") {
                    TextField("이름", text: $label)
                }
            }
            .navigationTitle("area 추가")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") {
                        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(trimmed.isEmpty ? defaultLabel : trimmed)
                        dismiss()
                    }
                }
            }
        }
        .onAppear { label = defaultLabel }
    }
}

// MARK: - Scan Row

private struct ScanRow: View {
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
                Text(chunk.fileName ?? String(chunk.scanId.uuidString.prefix(8)) + "...")
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
        case .ready, .uploaded, .merged: return .blue.opacity(0.15)
        default: return .gray.opacity(0.15)
        }
    }

    private func statusForeground(_ status: AdminScanChunk.ChunkStatus) -> Color {
        switch status {
        case .completed: return .green
        case .failed: return .red
        case .processing: return .orange
        case .ready, .uploaded, .merged: return .blue
        default: return .secondary
        }
    }
}
