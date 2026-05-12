import SwiftUI

/// overlay dot 탭 시 표시되는 노드 수정 sheet.
/// F7: edgeCount 인자 추가 → Section 헤더에 연결 수 표시.
struct NodeEditSheet: View {
    let node: BranchMarkNode
    let edgeCount: Int
    let onSave: (NodeType, Double?) -> Void
    let onDelete: () -> Void
    let onDismiss: () -> Void

    @State private var nodeType: NodeType
    @State private var selectedWidthM: Double
    @State private var showDeleteConfirm: Bool = false

    init(
        node: BranchMarkNode,
        edgeCount: Int = 0,
        onSave: @escaping (NodeType, Double?) -> Void,
        onDelete: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.node = node
        self.edgeCount = edgeCount
        self.onSave = onSave
        self.onDelete = onDelete
        self.onDismiss = onDismiss
        _nodeType = State(initialValue: node.nodeType)
        _selectedWidthM = State(initialValue: node.widthM ?? 2.5)
    }

    var body: some View {
        NavigationView {
            Form {
                Section("노드 #\(node.order) 정보 · 연결 \(edgeCount)개") {
                    Picker("노드 종류", selection: $nodeType) {
                        Text("통로").tag(NodeType.corridor)
                        Text("코너").tag(NodeType.corner)
                    }
                    .pickerStyle(.segmented)
                }

                if nodeType == .corridor {
                    Section("복도 폭") {
                        HStack(spacing: 8) {
                            ForEach([1.5, 2.5, 4.0], id: \.self) { preset in
                                Button {
                                    selectedWidthM = preset
                                } label: {
                                    Text("\(String(format: "%.1f", preset))m")
                                        .font(.caption.bold())
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                        .foregroundStyle(selectedWidthM == preset ? .white : .primary)
                                        .background(
                                            selectedWidthM == preset ? Color.accentColor : Color.secondary.opacity(0.15),
                                            in: RoundedRectangle(cornerRadius: 8)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        Stepper("폭: \(String(format: "%.1f", selectedWidthM))m",
                                value: $selectedWidthM,
                                in: 1.0...15.0,
                                step: 0.1)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("노드 삭제", systemImage: "trash")
                    }
                }
            }
            .navigationTitle("노드 수정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { onDismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") {
                        let width = nodeType == .corridor ? selectedWidthM : nil
                        onSave(nodeType, width)
                    }
                }
            }
            .confirmationDialog("노드를 삭제하면 연결된 경로도 제거됩니다.", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("삭제", role: .destructive) { onDelete() }
                Button("취소", role: .cancel) {}
            }
        }
    }
}
