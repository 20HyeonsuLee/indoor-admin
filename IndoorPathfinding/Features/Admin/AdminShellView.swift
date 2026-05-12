import SwiftUI

/// Admin 영역의 단일 NavigationStack 루트.
/// building list → floor list → floor detail → graph 흐름.
struct AdminShellView: View {
    @State private var workspace = AdminWorkspaceStore()

    var body: some View {
        AdminBuildingListView(workspace: workspace)
    }
}

#Preview {
    AdminShellView()
}
