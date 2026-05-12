import SwiftUI

/// 앱 최상위 라우터.
/// 사용자(end-user) 모드 제거 — 관리자 모드가 유일.
struct RootView: View {
    var body: some View {
        AdminShellView()
    }
}

#Preview {
    RootView()
}
