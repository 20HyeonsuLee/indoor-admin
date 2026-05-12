import SwiftUI

/// 종료 전 품질 점검 sheet.
/// isolated 노드 / outlier edge / transition 거리 초과 요약.
struct FinalizeChecklistSheet: View {
    let result: FinalizeChecklistResult
    let onFix: () -> Void
    let onIgnore: () -> Void

    var body: some View {
        NavigationView {
            List {
                if !result.isolatedNodeOrders.isEmpty {
                    Section {
                        ForEach(result.isolatedNodeOrders, id: \.self) { order in
                            Label("노드 #\(order) — 연결된 경로 없음", systemImage: "circle.dashed")
                        }
                    } header: {
                        Label("고립 노드 \(result.isolatedNodeOrders.count)개", systemImage: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                    }
                }

                if !result.outlierEdgeNodeOrderPairs.isEmpty {
                    Section {
                        ForEach(Array(result.outlierEdgeNodeOrderPairs.enumerated()), id: \.offset) { _, pair in
                            Label("노드 #\(pair.0) — #\(pair.1) 비정상 거리", systemImage: "arrow.left.and.right.square")
                        }
                    } header: {
                        Label("이상 경로 \(result.outlierEdgeNodeOrderPairs.count)개", systemImage: "ruler")
                            .foregroundStyle(.orange)
                    }
                }

                if !result.transitionDistanceExceededPairs.isEmpty {
                    Section {
                        ForEach(Array(result.transitionDistanceExceededPairs.enumerated()), id: \.offset) { _, pair in
                            Label("노드 #\(pair.0) → #\(pair.1) 폭 전환 거리 초과", systemImage: "arrow.triangle.2.circlepath")
                        }
                    } header: {
                        Label("전환 거리 초과 \(result.transitionDistanceExceededPairs.count)개", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }

                if !result.hasIssues {
                    Section {
                        Label("점검 완료. 이상 없음.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            }
            .navigationTitle("종료 전 점검")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    Button {
                        onFix()
                    } label: {
                        Label("수정하기", systemImage: "pencil")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)

                    Button(role: .destructive) {
                        onIgnore()
                    } label: {
                        Label("무시하고 종료", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
                .padding()
                .background(.regularMaterial)
            }
        }
    }
}
