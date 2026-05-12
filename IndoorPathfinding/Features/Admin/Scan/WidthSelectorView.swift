import SwiftUI

/// corridor 폭 preset chip group + 직접입력.
/// F5: 한글 라벨 + 설명 1줄 추가.
struct WidthSelectorView: View {
    @Binding var selectedWidthM: Double
    var onCustomTap: (() -> Void)?

    struct Preset {
        let label: String
        let value: Double
        let desc: String
    }

    private static let presets: [Preset] = [
        Preset(label: "좁음", value: 1.5, desc: "1인 통행"),
        Preset(label: "보통", value: 2.5, desc: "2인 교차 가능"),
        Preset(label: "넓음", value: 4.0, desc: "4인 병렬 통행")
    ]

    private var selectedPreset: Preset? {
        Self.presets.first { $0.value == selectedWidthM }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                ForEach(Self.presets, id: \.value) { preset in
                    Button {
                        selectedWidthM = preset.value
                    } label: {
                        VStack(spacing: 1) {
                            Text(preset.label)
                                .font(.caption2.bold())
                            Text("\(String(format: "%.1f", preset.value))m")
                                .font(.system(size: 9).monospacedDigit())
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .foregroundStyle(selectedWidthM == preset.value ? .black : .white)
                        .background(
                            selectedWidthM == preset.value ? .white : .white.opacity(0.16),
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 0)

                Button {
                    onCustomTap?()
                } label: {
                    Text("직접")
                        .font(.caption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .foregroundStyle(.white)
                        .background(.white.opacity(0.16), in: Capsule())
                }
                .buttonStyle(.plain)
            }

            // 선택된 preset 설명 또는 custom 폭 표시
            if let desc = selectedPreset?.desc {
                Text(desc)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
            } else {
                Text("직접 입력: \(String(format: "%.1f", selectedWidthM))m")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }
}
