import SwiftUI
import ARKit
import SceneKit

/// ARSession의 카메라 프리뷰를 그리는 SwiftUI 래퍼.
/// ARSession은 ARKitSessionManager가 소유·run — 이 뷰는 표시 + SCNNode overlay 담당.
///
/// Sprint 65: 빨간 점/궤적 시각화(ARSceneOverlayStore) 폐기. rendersContinuously=false 유지.
///   → 공식 문서 근거: ARSession이 attach된 ARSCNView는 카메라 frame 기반으로 자동 redraw.
///     rendersContinuously=false는 순수 SceneKit(비-AR) 부담 경감용이며 SCNNode 추가에 영향 없음.
///
/// Sprint 88 cycle_5: MarkARSceneOverlay(ARSCNViewDelegate)를 연결해 mark SCNNode를 그린다.
///   SCNNode는 anchor.transform 자동 추적으로 3D 공간에 고정된다 (projectPoint 제거).
///   `onMakeView` 콜백을 통해 ScanStore가 delegate 설정 + sceneViewRef 저장.
struct ARPreviewView: UIViewRepresentable {
    let session: ARSession
    /// Sprint 88 cycle_4 H10 fix: viewport-aware raycastQuery를 위해
    /// 외부(ScanSessionView)가 ARSCNView reference를 잡을 수 있게 콜백 노출.
    /// Sprint 88 cycle_5: ScanStore.setSceneView(_:) 연결에도 사용.
    var onMakeView: ((ARSCNView) -> Void)? = nil

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = session
        view.automaticallyUpdatesLighting = false
        // Sprint 65: SceneKit 매 frame 렌더링 비활성화 — GPU 부담 최소화.
        // Sprint 88 cycle_5 주석: ARSession attach 시 ARSCNView는 카메라 frame마다 자동 redraw.
        // false 유지해도 SCNNode child 추가·표시에 영향 없음 (Apple 공식 문서 근거).
        // 실 디바이스에서 node 갱신 미흡 시 true로 즉시 전환 가능 (OQ-A4 fallback).
        view.rendersContinuously = false
        view.showsStatistics = false
        view.scene = SCNScene()
        view.backgroundColor = .black
        view.debugOptions = []
        onMakeView?(view)
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        if uiView.session !== session {
            uiView.session = session
        }
    }
}
