import ARKit
import UIKit
import simd

// MARK: - Protocol

/// ARKit 세션 lifecycle 추상화. 테스트용 Fake와 실기기용 ARKitSessionManager로 분리된다.
protocol ARSessionManager: AnyObject {
    /// delegate는 @MainActor 격리 프로토콜 — Main thread에서만 읽기/쓰기.
    @MainActor var delegate: ARSessionManagerDelegate? { get set }
    /// UI 레이어에 카메라 프리뷰를 그리기 위한 session 참조. Fake는 nil.
    var arSession: ARSession? { get }
    func start()
    func pause()
}

// MARK: - Anchor Listener Protocol

/// Sprint 88 Cycle 4: ARPlaneAnchor 이벤트를 FloorReferenceTracker로 라우팅하기 위한 프로토콜.
@MainActor
protocol ARSessionAnchorListener: AnyObject {
    /// ARSession anchor 추가/업데이트 이벤트.
    /// - Parameters:
    ///   - anchor: 추가된 ARAnchor
    ///   - cameraY: 이벤트 시점의 카메라 y (world)
    func sessionManager(_ manager: ARSessionManager, didAddAnchor anchor: ARAnchor, cameraY: Float)
}

extension ARSessionManager {
    var arSession: ARSession? { nil }
}

/// ARSessionManager가 Store에 전달하는 이벤트.
/// @MainActor: ARKit delegate는 Main thread에서 호출되므로 직접 @MainActor 격리 가능.
@MainActor
protocol ARSessionManagerDelegate: AnyObject {
    /// ARKit delegate 콜백에서 호출됨 (Main thread).
    /// pixelBuffer는 이미 복사된 상태 — 보관해도 안전.
    func sessionManager(_ manager: ARSessionManager, didCapture sample: KeyframeSample)
    func sessionManager(_ manager: ARSessionManager, trackingStateDidChange label: String)
    func sessionManagerDidFail(_ manager: ARSessionManager, error: Error)

    /// FrameFanout이 backpressure 판단에 사용하는 대기 큐 크기.
    /// 기본 구현 0 — ScanStore만 실제 값을 override한다.
    var pendingQueueCount: Int { get }
}

extension ARSessionManagerDelegate {
    var pendingQueueCount: Int { 0 }
}

// MARK: - ARKit 구체 구현

/// 실기기 전용. ARKit이 없는 시뮬레이터에서는 `start()`가 조용히 아무것도 하지 않는다.
final class ARKitSessionManager: NSObject, ARSessionManager {
    @MainActor weak var delegate: ARSessionManagerDelegate?
    /// Sprint 88 Cycle 4: ARPlaneAnchor 이벤트를 FloorReferenceTracker로 라우팅.
    @MainActor weak var anchorListener: ARSessionAnchorListener?
    /// Sprint 91: 비-LiDAR 기기 monocular depth fallback. 모델 파일 없으면 nil → RGB-only path.
    let monocularDepthEstimator: MonocularDepthEstimator?

    let session = ARSession()
    var arSession: ARSession? { session }

    /// Sprint 95: 빠른걸음 스캔용 셔터 pin. iOS 16 미만에서는 nil.
    private var exposureController: Any?

    override init() {
        // 모델 파일은 Resources/Models/DepthAnythingV2SmallF16.mlpackage 경로 (사용자 hand-off).
        // 없으면 estimator nil → 비-LiDAR 기기 RGB-only fallback (회귀 0).
        if let modelURL = Bundle.main.url(
            forResource: "DepthAnythingV2SmallF16",
            withExtension: "mlpackage"
        ) ?? Bundle.main.url(
            forResource: "DepthAnythingV2SmallF16",
            withExtension: "mlmodelc"
        ) {
            self.monocularDepthEstimator = MonocularDepthEstimator(modelURL: modelURL)
        } else {
            self.monocularDepthEstimator = nil
        }
        super.init()
        session.delegate = self
    }

    func start() {
        #if !targetEnvironment(simulator)
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        // Sprint 90 live_rtabmap: LiDAR sceneDepth 활성 (지원 기기 한정).
        // RTAB-Map dense reconstruction / floor accuracy 정확도 향상. RGB만으로도 visual SLAM은 동작.
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        // Sprint 95: ARKit videoFormat 을 4:3 (depth aspect 일치) 우선으로 선택.
        // depth 256×192(4:3) 와 RGB aspect 가 같아야 RTAB-Map 의 DepthAsMask interpolate 가
        // 추가 crop 없이 동작. 1280×720(16:9) 는 4:3 미지원 기기에서만 fallback.
        config.videoFormat = Self.preferredVideoFormat()
        session.run(config, options: [.resetTracking, .removeExistingAnchors])

        // Sprint 95: 빠른걸음 스캔 셔터 pin (iOS 16+).
        // session.run 직후에 device 가 안정화되도록 0.3초 지연 후 적용.
        if #available(iOS 16.0, *) {
            let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera
            let controller = ExposureController(device: device)
            self.exposureController = controller
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                controller.applyInitialPolicy()
            }
        }
        #endif
    }

    /// 4:3 1920×1440 우선 supportedVideoFormat 선택.
    /// Sprint 95: 16:9 HD(1280×720) → 4:3 1920×1440으로 변경.
    ///   ARKit LiDAR sceneDepth는 항상 256×192 (4:3) 고정. 16:9 RGB와 aspect mismatch가
    ///   있으면 RTAB-Map이 depth를 RGB 영역에 맞추기 위해 crop/interpolate 비용을 추가로
    ///   치른다. 4:3 RGB로 통일하면 aspect 일치 → Mem/DepthAsMask=true에서 depth가
    ///   바로 RGB 해상도로 interpolate된다.
    ///   1920/256 = 7.5, 1440/192 = 7.5 — 정수배는 아니지만 introlab 공식 iOS 앱과 동일.
    ///   `Mem/ImagePreDecimation=2`(setFullResolutionNative=true)와 함께 쓰면 db에는
    ///   960×720으로 저장되고 SIFT는 그 위에서 추출.
    private static func preferredVideoFormat() -> ARConfiguration.VideoFormat {
        let supported = ARWorldTrackingConfiguration.supportedVideoFormats

        func matches(_ f: ARConfiguration.VideoFormat, _ w: Int, _ h: Int) -> Bool {
            let fw = Int(f.imageResolution.width)
            let fh = Int(f.imageResolution.height)
            return (fw == w && fh == h) || (fw == h && fh == w)
        }

        func pick(_ candidates: [(Int, Int)]) -> ARConfiguration.VideoFormat? {
            for (w, h) in candidates {
                let formats = supported.filter { matches($0, w, h) }
                if let f60 = formats.first(where: { $0.framesPerSecond == 60 }) {
                    return f60
                }
                if let f30 = formats.first(where: { $0.framesPerSecond == 30 }) {
                    return f30
                }
                if let any = formats.first {
                    return any
                }
            }
            return nil
        }

        // 1차: 4:3 (depth 256×192와 aspect 일치, introlab 공식 iOS 앱 default)
        if let f = pick([(1920, 1440), (1440, 1080), (1280, 960)]) {
            return f
        }

        // 2차: 16:9 fallback (4:3 미지원 기기) — depth와 aspect mismatch는 RTAB-Map이 처리
        if let f = pick([(1920, 1080), (1280, 720)]) {
            return f
        }

        // 3차: ARKit default
        return ARWorldTrackingConfiguration().videoFormat
    }

    func pause() {
        session.pause()
    }
}

// MARK: - ARSessionDelegate

extension ARKitSessionManager: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // ARKit은 Main thread에서 이 메서드를 호출한다(공식 문서 보장).
        // assume(on:) 없이 MainActor.assumeIsolated로 컴파일러에 알림.
        MainActor.assumeIsolated {
            // pixelBuffer를 즉시 복사 — ARKit이 pool을 재활용하기 전에.
            guard let copied = frame.capturedImage.deepCopy() else { return }

            let label = trackingLabel(for: frame.camera.trackingState)
            guard label == "normal" else {
                delegate?.sessionManager(self, trackingStateDidChange: label)
                return
            }

            // Sprint 95: ambientIntensity 기반 셔터 정책 갱신 (iOS 16+).
            if #available(iOS 16.0, *), let ambient = frame.lightEstimate?.ambientIntensity,
               let controller = exposureController as? ExposureController {
                controller.update(ambientIntensity: Double(ambient), now: frame.timestamp)
            }

            // Sprint 3.5: RTAB-Map에 필요한 추가 필드 추출.
            let intrinsics = frame.camera.intrinsics
            let bounds = UIScreen.main.bounds
            let viewport = CGSize(width: bounds.width, height: bounds.height)

            let depthMap: CVPixelBuffer? = frame.sceneDepth.flatMap { depth in
                depth.depthMap.deepCopy()
            }
            let confidenceMap: CVPixelBuffer? = frame.sceneDepth.flatMap { depth in
                depth.confidenceMap?.deepCopy()
            }
            let featurePoints = frame.rawFeaturePoints?.points.map {
                simd_float3($0.x, $0.y, $0.z)
            } ?? []

            let sample = KeyframeSample(
                pixelBuffer: copied,
                transform: frame.camera.transform,
                capturedAt: Date(),
                trackingStateLabel: label,
                arFrameTimestamp: frame.timestamp,
                intrinsicsFx: intrinsics[0, 0],
                intrinsicsFy: intrinsics[1, 1],
                intrinsicsCx: intrinsics[2, 0],
                intrinsicsCy: intrinsics[2, 1],
                viewMatrix: frame.camera.viewMatrix(for: .portrait),
                projectionMatrix: frame.camera.projectionMatrix(
                    for: .portrait,
                    viewportSize: viewport,
                    zNear: 0.5,
                    zFar: 50.0
                ),
                depthMap: depthMap,
                confidenceMap: confidenceMap,
                featurePoints: featurePoints
            )
            delegate?.sessionManager(self, didCapture: sample)
        }
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        MainActor.assumeIsolated {
            delegate?.sessionManager(self, trackingStateDidChange: trackingLabel(for: camera.trackingState))
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            delegate?.sessionManagerDidFail(self, error: error)
        }
    }

    /// Sprint 88 Cycle 4: plane anchor 추가 이벤트 → FloorReferenceTracker 라우팅.
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        MainActor.assumeIsolated {
            guard let cameraY = session.currentFrame?.camera.transform.columns.3.y else { return }
            for anchor in anchors {
                anchorListener?.sessionManager(self, didAddAnchor: anchor, cameraY: cameraY)
            }
        }
    }

    /// Sprint 88 Cycle 4: plane anchor 업데이트 이벤트 → FloorReferenceTracker 라우팅.
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        MainActor.assumeIsolated {
            guard let cameraY = session.currentFrame?.camera.transform.columns.3.y else { return }
            for anchor in anchors {
                anchorListener?.sessionManager(self, didAddAnchor: anchor, cameraY: cameraY)
            }
        }
    }

    // MARK: Private

    private func trackingLabel(for state: ARCamera.TrackingState) -> String {
        switch state {
        case .normal:
            return "normal"
        case .notAvailable:
            return "notAvailable"
        case .limited(.initializing):
            return "limited.initializing"
        case .limited(.excessiveMotion):
            return "limited.excessiveMotion"
        case .limited(.insufficientFeatures):
            return "limited.insufficientFeatures"
        case .limited(.relocalizing):
            return "limited.relocalizing"
        case .limited:
            return "limited.unknown"
        @unknown default:
            return "unknown"
        }
    }
}

// MARK: - CVPixelBuffer 복사 헬퍼

private extension CVPixelBuffer {
    /// 픽셀 버퍼를 깊은 복사하여 반환. 실패 시 nil.
    func deepCopy() -> CVPixelBuffer? {
        CVPixelBufferLockBaseAddress(self, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(self, .readOnly) }

        var copy: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            CVPixelBufferGetWidth(self),
            CVPixelBufferGetHeight(self),
            CVPixelBufferGetPixelFormatType(self),
            nil,
            &copy
        )
        guard status == kCVReturnSuccess, let copy else { return nil }

        CVPixelBufferLockBaseAddress(copy, [])
        defer { CVPixelBufferUnlockBaseAddress(copy, []) }

        let planeCount = CVPixelBufferGetPlaneCount(self)
        if planeCount == 0 {
            guard let src = CVPixelBufferGetBaseAddress(self),
                  let dst = CVPixelBufferGetBaseAddress(copy) else { return nil }
            let size = CVPixelBufferGetDataSize(self)
            dst.copyMemory(from: src, byteCount: size)
        } else {
            for plane in 0..<planeCount {
                guard let src = CVPixelBufferGetBaseAddressOfPlane(self, plane),
                      let dst = CVPixelBufferGetBaseAddressOfPlane(copy, plane) else { continue }
                let height = CVPixelBufferGetHeightOfPlane(self, plane)
                let srcStride = CVPixelBufferGetBytesPerRowOfPlane(self, plane)
                let dstStride = CVPixelBufferGetBytesPerRowOfPlane(copy, plane)
                for row in 0..<height {
                    memcpy(dst.advanced(by: row * dstStride), src.advanced(by: row * srcStride), min(srcStride, dstStride))
                }
            }
        }
        return copy
    }
}
