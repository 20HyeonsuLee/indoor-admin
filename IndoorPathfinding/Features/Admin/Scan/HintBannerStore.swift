import SwiftUI

/// hint banner 메시지/색 매핑.
/// ScanSessionView에서 store.hintBannerCase / markingState.hintBannerCase를 소비.
struct HintBannerView: View {
    let hint: HintBannerCase
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.caption.weight(.semibold))
            Text(message)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
            Spacer(minLength: 0)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(backgroundColor.opacity(0.9))
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var message: String {
        switch hint {
        case .trackingLimited:
            return "트래킹 불안정 — 마크 불가"
        case .transitionDistanceExceeded:
            return "폭 전환 거리 1m 초과 — 연결 끊김"
        case .backtracking:
            return "되돌아가는 중 — [끊기]를 눌러 분기하세요"
        case .missingBranch:
            return "분기 누락 가능성 — 경로를 확인하세요"
        case .proximityAmbiguous:
            return "후보 노드가 모호합니다 — 선택하세요"
        }
    }

    private var iconName: String {
        switch hint {
        case .trackingLimited:            return "exclamationmark.triangle.fill"
        case .transitionDistanceExceeded: return "arrow.triangle.2.circlepath"
        case .backtracking:               return "arrow.uturn.backward.circle"
        case .missingBranch:              return "questionmark.circle"
        case .proximityAmbiguous:         return "arrow.triangle.branch"
        }
    }

    private var backgroundColor: Color {
        switch hint {
        case .trackingLimited:            return .red
        case .transitionDistanceExceeded: return .red
        case .backtracking:               return .orange
        case .missingBranch:              return .orange
        case .proximityAmbiguous:         return .yellow
        }
    }
}
