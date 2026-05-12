import SwiftUI

struct AdminFloorListView: View {
    @State var workspace: AdminWorkspaceStore
    let building: AdminBuilding

    @State private var showAddSheet = false
    @State private var deleteTarget: AdminFloor?
    @State private var showDeleteConfirm = false
    @State private var editTarget: AdminFloor?

    var floors: [AdminFloor] {
        (workspace.floors[building.id] ?? []).sorted { $0.level < $1.level }
    }

    var body: some View {
        Group {
            if workspace.isLoading && floors.isEmpty {
                ProgressView("불러오는 중...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if floors.isEmpty {
                ContentUnavailableView {
                    Label("층 없음", systemImage: "square.3.layers.3d")
                } description: {
                    Text("+ 버튼으로 층을 추가하세요.")
                } actions: {
                    Button("층 추가") { showAddSheet = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    ForEach(floors) { floor in
                        NavigationLink(value: floor) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(floor.displayName)
                                        .font(.headline)
                                    Text("Level \(floor.level)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if floor.hasPath {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                        .font(.caption)
                                }
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                deleteTarget = floor
                                showDeleteConfirm = true
                            } label: {
                                Label("삭제", systemImage: "trash")
                            }

                            Button {
                                editTarget = floor
                            } label: {
                                Label("수정", systemImage: "pencil")
                            }
                            .tint(.orange)
                        }
                    }
                }
            }
        }
        .navigationTitle(building.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task { await workspace.loadFloors(buildingId: building.id) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .navigationDestination(for: AdminFloor.self) { floor in
            AdminFloorDetailView(workspace: workspace, building: building, floor: floor)
        }
        .alert("층 삭제", isPresented: $showDeleteConfirm, presenting: deleteTarget) { target in
            Button("삭제", role: .destructive) {
                Task { await workspace.deleteFloor(target) }
            }
            Button("취소", role: .cancel) {}
        } message: { target in
            Text("'\(target.displayName)'을(를) 삭제합니다. 이 층의 모든 스캔과 빌드 결과가 함께 삭제됩니다.")
        }
        .sheet(isPresented: $showAddSheet) {
            FloorEditorSheet(workspace: workspace, buildingId: building.id)
        }
        .sheet(item: $editTarget) { target in
            FloorEditorSheet(workspace: workspace, buildingId: building.id, editTarget: target)
        }
        .task {
            await workspace.loadFloors(buildingId: building.id)
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
}

// MARK: - Floor Editor Sheet

struct FloorEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    var workspace: AdminWorkspaceStore
    let buildingId: UUID
    let editTarget: AdminFloor?  // nil이면 create, 값이 있으면 edit

    init(workspace: AdminWorkspaceStore, buildingId: UUID, editTarget: AdminFloor? = nil) {
        self.workspace = workspace
        self.buildingId = buildingId
        self.editTarget = editTarget
    }

    @State private var name: String = ""
    @State private var level: Int = 1
    @State private var isSaving = false

    var isEdit: Bool { editTarget != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("층 정보") {
                    TextField("층 이름 (예: 1층)", text: $name)
                    if isEdit {
                        // FloorUpdateRequest는 name만 허용 (level 변경 불가)
                        Text("레벨: \(level)")
                            .foregroundStyle(.secondary)
                    } else {
                        Stepper("레벨: \(level)", value: $level, in: -10...50)
                    }
                }
                if !isEdit {
                    Section {
                        Text("지하는 음수 레벨을 사용합니다. (예: B1 = -1)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(isEdit ? "층 수정" : "층 추가")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "저장 중..." : "저장") {
                        Task {
                            isSaving = true
                            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                            if let target = editTarget {
                                guard !trimmed.isEmpty else {
                                    isSaving = false
                                    return
                                }
                                await workspace.updateFloor(target, name: trimmed)
                            } else {
                                let finalName = trimmed.isEmpty ? defaultName(level: level) : trimmed
                                await workspace.createFloor(buildingId: buildingId, name: finalName, level: level)
                            }
                            isSaving = false
                            dismiss()
                        }
                    }
                    .disabled(isSaving || (isEdit && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            }
            .onAppear {
                if let target = editTarget {
                    name = target.name
                    level = target.level
                }
            }
        }
    }

    private func defaultName(level: Int) -> String {
        if level < 0 { return "B\(abs(level))" }
        if level == 0 { return "GF" }
        return "\(level)F"
    }
}
