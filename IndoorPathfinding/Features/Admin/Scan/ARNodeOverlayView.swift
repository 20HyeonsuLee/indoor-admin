import SwiftUI
import ARKit
import os.log

/// AR 카메라 위 SwiftUI 2D overlay.
///
/// ## Sprint 88 cycle_5 변경 (plan §5.1 / §6)
/// 정식 노드/엣지 그리기는 MarkARSceneOverlay(SCNNode)로 이관됨. 이 뷰는 다음만 담당:
///   1. **Debug R/P dots**: rawCornerTapDebugMode ON 시 magenta R (raw tap) + yellow P (raycast projection).
///      PROJECT_DEBUG OSLog 출력 포함 (AC-AR3D-project-debug).
///   2. **Corner tap 수신 layer**: corner 모드일 때 `Color.clear.contentShape` + `onTapGesture`.
///
/// 제거된 것: ForEach(markingState.nodes) dot, drawEdges Canvas, preview 점선, nodeView, edgeStyle.
struct ARNodeOverlayView: View {
    // markingState는 더 이상 정식 그리기에 사용하지 않음. corner tap layer 표시 조건만.
    let markingState: MarkingState
    let arFrame: ARFrame?
    let viewportSize: CGSize
    var onNodeTap: ((BranchMarkNodeId) -> Void)?
    var onCornerTap: ((CGPoint) -> Void)?
    /// Debug: raw corner tap mode일 때 화면 탭 좌표 그대로 magenta dot.
    /// raycast → world → projection 경로 우회. 입력 좌표 자체의 SwiftUI 정합성 검증.
    var debugRawCornerTaps: [CGPoint] = []
    /// Debug: raycast 결과 world point. 매 프레임 projectPoint로 yellow dot 갱신.
    /// magenta(raw)와 첫 프레임 일치 / 카메라 이동 시 추적 비교.
    var debugRaycastWorldPoints: [SIMD3<Float>] = []
    /// Debug: raycast 결과 ARAnchor id. frame.anchors에서 lookup 우선 (ARKit stabilize).
    /// 미발견 시 같은 인덱스의 debugRaycastWorldPoints fallback.
    var debugRaycastAnchorIds: [UUID] = []

    private let dotRadius: CGFloat = 7
    private let projectDebugLogger = Logger(subsystem: "com.indoorpathfinding", category: "PROJECT_DEBUG")

    var body: some View {
        ZStack {
            rawTapDebugLayer
            if let frame = arFrame {
                raycastDebugLayer(frame: frame)
            }
            cornerTapLayer
        }
    }

    // MARK: - Debug Layers (분리: 컴파일러 타입 추론 부담 경감)

    /// Debug R dots: magenta, 화면 좌표 그대로 (cycle_4 보존)
    @ViewBuilder
    private var rawTapDebugLayer: some View {
        ForEach(Array(debugRawCornerTaps.enumerated()), id: \.offset) { idx, pt in
            ZStack {
                Circle()
                    .fill(Color.pink)
                    .frame(width: dotRadius * 2, height: dotRadius * 2)
                Circle()
                    .stroke(Color.white, lineWidth: 1.5)
                    .frame(width: dotRadius * 2, height: dotRadius * 2)
                Text("R\(idx + 1)")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .offset(y: -16)
            }
            .position(pt)
            .allowsHitTesting(false)
        }
    }

    /// Debug P dots: yellow, raycast 결과 projection (anchor 우선, world point fallback, cycle_4 보존)
    /// PROJECT_DEBUG OSLog 포함 (AC-AR3D-project-debug)
    @ViewBuilder
    private func raycastDebugLayer(frame: ARFrame) -> some View {
        ForEach(Array(debugRaycastWorldPoints.enumerated()), id: \.offset) { idx, fallbackWorld in
            let resolvedWorld = resolveDebugRaycastWorld(idx: idx, fallback: fallbackWorld, frame: frame)
            let projectedPt = projectPoint(resolvedWorld, frame: frame)
            let isAnchor = idx < debugRaycastAnchorIds.count
                && frame.anchors.contains(where: { $0.identifier == debugRaycastAnchorIds[idx] })
            if let pt = projectedPt {
                debugPDot(idx: idx, pt: pt, isAnchor: isAnchor, frame: frame)
            }
        }
    }

    @ViewBuilder
    private func debugPDot(idx: Int, pt: CGPoint, isAnchor: Bool, frame: ARFrame) -> some View {
        ZStack {
            Circle()
                .fill(Color.yellow.opacity(0.85))
                .frame(width: dotRadius * 2, height: dotRadius * 2)
            Circle()
                .stroke(isAnchor ? Color.green : Color.black, lineWidth: 1.5)
                .frame(width: dotRadius * 2, height: dotRadius * 2)
            Text("P\(idx + 1)")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.black)
                .offset(y: 16)
        }
        .position(pt)
        .allowsHitTesting(false)
        .onAppear {
            // PROJECT_DEBUG OSLog (cycle_4 M1 close): viewportSize vs projected
            let px = String(format: "%.1f", pt.x)
            let py = String(format: "%.1f", pt.y)
            let vw = String(format: "%.1f", viewportSize.width)
            let vh = String(format: "%.1f", viewportSize.height)
            projectDebugLogger.debug(
                "PROJECT_DEBUG idx=\(idx) isAnchor=\(isAnchor) projected=(\(px),\(py)) viewport=(\(vw),\(vh))"
            )
        }
    }

    /// 코너 탭 수신 layer (corner 모드일 때만, cycle_4 보존)
    @ViewBuilder
    private var cornerTapLayer: some View {
        if onCornerTap != nil {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { location in
                    onCornerTap?(location)
                }
        }
    }

    // MARK: - Debug Raycast Resolution (cycle_4 보존)

    /// debug raycast의 world 좌표 해결: anchor id가 있고 frame.anchors에서 발견되면
    /// anchor.transform.columns.3.xyz 사용 (ARKit stabilize 효과). 없으면 fallback world point.
    private func resolveDebugRaycastWorld(idx: Int, fallback: SIMD3<Float>, frame: ARFrame) -> SIMD3<Float> {
        guard idx < debugRaycastAnchorIds.count else { return fallback }
        let id = debugRaycastAnchorIds[idx]
        if let anchor = frame.anchors.first(where: { $0.identifier == id }) {
            let c = anchor.transform.columns.3
            return SIMD3<Float>(c.x, c.y, c.z)
        }
        return fallback
    }

    // MARK: - Projection (debug용 — 정식 노드는 SCNNode perspective로 처리)

    /// world point → viewport screen point. frustum 밖이면 nil.
    /// debug raycast P dot 표시 전용. 정식 노드/엣지 projection은 ARKit/SceneKit이 처리.
    private func projectPoint(_ worldPoint: SIMD3<Float>, frame: ARFrame) -> CGPoint? {
        let projected = frame.camera.projectPoint(
            worldPoint,
            orientation: .portrait,
            viewportSize: viewportSize
        )

        // frustum 컬링: camera forward와 벡터 내적으로 앞/뒤 판단
        let cameraTransform = frame.camera.transform
        let forward = -SIMD3<Float>(
            cameraTransform.columns.2.x,
            cameraTransform.columns.2.y,
            cameraTransform.columns.2.z
        )
        let camPos = SIMD3<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )
        let toPoint = worldPoint - camPos
        let dot = simd_dot(simd_normalize(forward), simd_normalize(toPoint))
        guard dot > 0 else { return nil }  // 카메라 뒤

        let margin: CGFloat = 20
        guard projected.x >= -margin, projected.x <= viewportSize.width + margin,
              projected.y >= -margin, projected.y <= viewportSize.height + margin
        else { return nil }

        return projected
    }
}
