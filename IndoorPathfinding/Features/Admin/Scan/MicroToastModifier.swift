import SwiftUI

/// 1.5초 top-center micro-toast. tap 시 즉시 undo 콜백.
struct MicroToastView: View {
    let message: String
    let onTapUndo: (() -> Void)?

    var body: some View {
        Button {
            onTapUndo?()
        } label: {
            HStack(spacing: 8) {
                Text(message)
                    .font(.caption.weight(.semibold))
                if onTapUndo != nil {
                    Text("실행취소")
                        .font(.caption2.weight(.bold))
                        .underline()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.black.opacity(0.72))
            .foregroundStyle(.white)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// F9: MicroToastModifier / .microToast() 제거 — ScanSessionView는 직접 VStack 경로를 사용
// MicroToastView만 유지.
