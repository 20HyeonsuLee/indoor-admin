import SwiftUI

// MARK: - Status UI Mapping

enum BuildingStatusUI {
    static func symbol(_ raw: String) -> String {
        switch raw.uppercased() {
        case "ACTIVE":   return "checkmark.circle.fill"
        case "DRAFT":    return "circle.dotted"
        case "ARCHIVED": return "archivebox.fill"
        default:         return "questionmark.circle"
        }
    }

    static func color(_ raw: String) -> Color {
        switch raw.uppercased() {
        case "ACTIVE":   return .green
        case "DRAFT":    return .orange
        case "ARCHIVED": return .gray
        default:         return .secondary
        }
    }

    static func label(_ raw: String) -> String {
        switch raw.uppercased() {
        case "ACTIVE":   return "활성"
        case "DRAFT":    return "초안"
        case "ARCHIVED": return "보관됨"
        default:         return raw
        }
    }
}

struct AdminBuildingListView: View {
    @State var workspace: AdminWorkspaceStore

    @State private var showAddSheet = false
    @State private var editTarget: AdminBuilding?
    @State private var deleteTarget: AdminBuilding?
    @State private var showDeleteConfirm = false

    var body: some View {
        NavigationStack {
            Group {
                if workspace.isLoading && workspace.buildings.isEmpty {
                    ProgressView("불러오는 중...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if workspace.buildings.isEmpty {
                    ContentUnavailableView {
                        Label("건물 없음", systemImage: "building.2")
                    } description: {
                        Text("+ 버튼으로 건물을 추가하세요.")
                    } actions: {
                        Button("건물 추가") { showAddSheet = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(workspace.buildings) { building in
                            NavigationLink(value: building) {
                                HStack(spacing: 6) {
                                    Image(systemName: BuildingStatusUI.symbol(building.status))
                                        .foregroundStyle(BuildingStatusUI.color(building.status))
                                        .font(.subheadline)
                                        .accessibilityLabel(BuildingStatusUI.label(building.status))
                                    Text(building.name)
                                        .font(.headline)
                                        .lineLimit(1)
                                    if let desc = building.description, !desc.isEmpty {
                                        Text("·")
                                            .foregroundStyle(.secondary)
                                        Text(desc)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                    }
                                    Spacer(minLength: 0)
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    deleteTarget = building
                                    showDeleteConfirm = true
                                } label: {
                                    Label("삭제", systemImage: "trash")
                                }
                                Button {
                                    editTarget = building
                                } label: {
                                    Label("수정", systemImage: "pencil")
                                }
                                .tint(.orange)
                            }
                        }
                    }
                }
            }
            .navigationTitle("건물 관리")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await workspace.loadBuildings() }
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
            .navigationDestination(for: AdminBuilding.self) { building in
                AdminFloorListView(workspace: workspace, building: building)
            }
            .alert("건물 삭제", isPresented: $showDeleteConfirm, presenting: deleteTarget) { target in
                Button("삭제", role: .destructive) {
                    Task { await workspace.deleteBuilding(target) }
                }
                Button("취소", role: .cancel) {}
            } message: { target in
                Text("'\(target.name)'을(를) 삭제합니다. 이 건물의 모든 층과 스캔이 함께 삭제됩니다.")
            }
            .sheet(isPresented: $showAddSheet) {
                BuildingEditorSheet(workspace: workspace, editTarget: nil)
            }
            .sheet(item: $editTarget) { target in
                BuildingEditorSheet(workspace: workspace, editTarget: target)
            }
            .task {
                await workspace.loadBuildings()
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
}

// MARK: - Editor Sheet

struct BuildingEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    var workspace: AdminWorkspaceStore
    let editTarget: AdminBuilding?

    @State private var name: String = ""
    @State private var description: String = ""
    // F4: 위도/경도 입력 — 빈 문자열은 nil 전송
    @State private var latitudeText: String = ""
    @State private var longitudeText: String = ""
    @State private var isSaving = false

    var isEdit: Bool { editTarget != nil }

    // F4: 입력 검증 — 비어있으면 nil, 범위 밖이면 invalid
    private var parsedLatitude: Double? {
        guard !latitudeText.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard let v = Double(latitudeText), (-90...90).contains(v) else { return nil }
        return v
    }
    private var parsedLongitude: Double? {
        guard !longitudeText.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard let v = Double(longitudeText), (-180...180).contains(v) else { return nil }
        return v
    }
    private var latInvalid: Bool {
        !latitudeText.trimmingCharacters(in: .whitespaces).isEmpty && parsedLatitude == nil
    }
    private var lngInvalid: Bool {
        !longitudeText.trimmingCharacters(in: .whitespaces).isEmpty && parsedLongitude == nil
    }
    private var hasValidationError: Bool { latInvalid || lngInvalid }

    var body: some View {
        NavigationStack {
            Form {
                Section("건물 정보") {
                    TextField("건물 이름 (필수)", text: $name)
                    TextField("설명 또는 주소", text: $description)
                }
                // F4: 위도/경도 입력 섹션
                Section {
                    HStack {
                        Text("위도")
                            .frame(width: 44, alignment: .leading)
                        TextField("-90 ~ 90 (선택)", text: $latitudeText)
                            .keyboardType(.decimalPad)
                            .foregroundStyle(latInvalid ? .red : .primary)
                    }
                    HStack {
                        Text("경도")
                            .frame(width: 44, alignment: .leading)
                        TextField("-180 ~ 180 (선택)", text: $longitudeText)
                            .keyboardType(.decimalPad)
                            .foregroundStyle(lngInvalid ? .red : .primary)
                    }
                    if hasValidationError {
                        Text("유효하지 않은 좌표값입니다.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("위치 (선택)")
                } footer: {
                    Text("비워두면 위치 정보 없이 저장됩니다.")
                }
            }
            .navigationTitle(isEdit ? "건물 수정" : "건물 추가")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "저장 중..." : "저장") {
                        Task {
                            isSaving = true
                            let desc = description.trimmingCharacters(in: .whitespacesAndNewlines)
                            if let target = editTarget {
                                await workspace.updateBuilding(
                                    target,
                                    name: name,
                                    description: desc.isEmpty ? nil : desc,
                                    latitude: parsedLatitude,
                                    longitude: parsedLongitude
                                )
                            } else {
                                await workspace.createBuilding(
                                    name: name,
                                    description: desc.isEmpty ? nil : desc,
                                    latitude: parsedLatitude,
                                    longitude: parsedLongitude
                                )
                            }
                            isSaving = false
                            dismiss()
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving || hasValidationError)
                }
            }
            .onAppear {
                if let target = editTarget {
                    name = target.name
                    description = target.description ?? ""
                    latitudeText = target.latitude.map { String($0) } ?? ""
                    longitudeText = target.longitude.map { String($0) } ?? ""
                }
            }
        }
    }
}
