import Foundation
import CoreML
import Vision
import CoreVideo
import os.log
import simd

/// Sprint 91: 비-LiDAR 기기 monocular depth fallback (Depth Anything V2 Small Core ML).
///
/// ## 동작 (plan §6)
/// - 입력: ARKit RGB pixelBuffer + featurePoints + viewMatrix + intrinsics.
/// - 출력: LiDAR sceneDepth 호환 256×192 Float32 metric m `CVPixelBuffer`.
/// - throttle: 1Hz (마지막 결과 캐시 → 같은 1초 안에는 그대로 반환).
/// - 추론은 utility queue에서 비동기 → main thread 차단 없음.
/// - 모델 파일 없으면 init? nil → caller가 nil 받아 RGB-only fallback.
final class MonocularDepthEstimator {

    private let logger = Logger(subsystem: "com.indoorpathfinding", category: "MonocularDepth")
    private let visionModel: VNCoreMLModel
    private let queue = DispatchQueue(label: "depth.estimator.queue", qos: .utility)
    private let lock = NSLock()
    private var lastResult: CVPixelBuffer?
    private var lastTimestamp: TimeInterval = 0
    private var lastScale: Float = 1.0
    private var hasLastScale: Bool = false
    private var inflight: Bool = false

    private static let throttleInterval: TimeInterval = 1.0
    private static let outputWidth: Int = 256
    private static let outputHeight: Int = 192

    /// - Parameter modelURL: `DepthAnythingV2SmallF16.mlpackage` 또는 컴파일된 `.mlmodelc` URL.
    init?(modelURL: URL) {
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all  // Neural Engine 우선
            let mlModel = try MLModel(contentsOf: modelURL, configuration: config)
            self.visionModel = try VNCoreMLModel(for: mlModel)
        } catch {
            Logger(subsystem: "com.indoorpathfinding", category: "MonocularDepth")
                .error("model load failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// throttle 적용된 비동기 추정. 호출 시점은 캐시 또는 nil 즉시 반환.
    /// 새 추론은 queue에 enqueue → 완료 시 lastResult 갱신 (다음 호출에 반영).
    func estimateThrottled(
        rgbPixelBuffer: CVPixelBuffer,
        intrinsics: (fx: Float, fy: Float, cx: Float, cy: Float),
        featurePoints: [SIMD3<Float>],
        viewMatrix: simd_float4x4,
        timestamp: TimeInterval
    ) -> CVPixelBuffer? {
        lock.lock()
        let cached = lastResult
        let last = lastTimestamp
        let busy = inflight
        lock.unlock()

        // 마지막 추론 후 throttleInterval 미만 → 캐시 그대로 (또는 nil)
        if timestamp - last < Self.throttleInterval || busy {
            return cached
        }

        // 새 추론 enqueue. main에는 즉시 캐시 반환 (첫 호출은 nil).
        let rgb = rgbPixelBuffer  // CVPixelBuffer는 ref-counted, deepCopy 이미 된 상태로 받음
        let fp = featurePoints
        let vm = viewMatrix
        let intr = intrinsics
        let ts = timestamp

        lock.lock()
        inflight = true
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            let result = self.runInference(
                rgb: rgb, intrinsics: intr,
                featurePoints: fp, viewMatrix: vm
            )
            self.lock.lock()
            self.lastResult = result
            self.lastTimestamp = ts
            self.inflight = false
            self.lock.unlock()
        }

        return cached
    }

    // MARK: - Private

    private func runInference(
        rgb: CVPixelBuffer,
        intrinsics: (fx: Float, fy: Float, cx: Float, cy: Float),
        featurePoints: [SIMD3<Float>],
        viewMatrix: simd_float4x4
    ) -> CVPixelBuffer? {
        let request = VNCoreMLRequest(model: visionModel)
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cvPixelBuffer: rgb, options: [:])
        do {
            try handler.perform([request])
        } catch {
            logger.error("VNCoreMLRequest perform failed: \(error.localizedDescription)")
            return nil
        }
        guard let results = request.results as? [VNCoreMLFeatureValueObservation],
              let first = results.first,
              let arr = first.featureValue.multiArrayValue else {
            logger.error("unexpected Vision results")
            return nil
        }
        // Depth Anything V2 출력은 (1, 518, 518) 또는 (518, 518) Float32 inverse depth.
        // shape 가정: 마지막 두 dim = 518×518.
        let shape = arr.shape.map { $0.intValue }
        guard shape.count >= 2,
              shape[shape.count - 1] == 518,
              shape[shape.count - 2] == 518 else {
            logger.error("unexpected output shape: \(shape)")
            return nil
        }
        let dataType = arr.dataType
        guard dataType == .float32 else {
            logger.error("unexpected dataType: \(dataType.rawValue) (expected float32)")
            return nil
        }
        let disparityPtr = arr.dataPointer.assumingMemoryBound(to: Float.self)

        // Scale calibration (rawFeaturePoints 기반)
        let rgbW = CVPixelBufferGetWidth(rgb)
        let rgbH = CVPixelBufferGetHeight(rgb)
        let estimatedScale = DepthScaleCalibrator.estimateScale(
            disparity518: disparityPtr,
            featurePoints: featurePoints,
            viewMatrix: viewMatrix,
            intrinsics: intrinsics,
            rgbWidth: rgbW,
            rgbHeight: rgbH
        )
        let scale: Float
        if let s = estimatedScale {
            // EMA smoothing
            scale = hasLastScale ? (0.7 * lastScale + 0.3 * s) : s
            lastScale = scale
            hasLastScale = true
        } else if hasLastScale {
            scale = lastScale  // 직전 scale 재사용
        } else {
            // 첫 frame부터 calibration 실패 → fail-open
            return nil
        }

        // 518×518 disparity → 256×192 metric depth로 nearest-neighbor downsample
        return makeMetricDepthPixelBuffer(
            disparity518: disparityPtr,
            scale: scale
        )
    }

    private func makeMetricDepthPixelBuffer(
        disparity518: UnsafePointer<Float>,
        scale: Float
    ) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Self.outputWidth, Self.outputHeight,
            kCVPixelFormatType_DepthFloat32,
            attrs as CFDictionary,
            &pb
        )
        guard status == kCVReturnSuccess, let buffer = pb else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let dst = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let dstStride = CVPixelBufferGetBytesPerRow(buffer)
        let outW = Self.outputWidth
        let outH = Self.outputHeight
        let srcSize = 518

        let xRatio = Float(srcSize) / Float(outW)
        let yRatio = Float(srcSize) / Float(outH)

        for y in 0..<outH {
            let srcY = min(srcSize - 1, Int(Float(y) * yRatio))
            let dstRow = dst.advanced(by: y * dstStride).assumingMemoryBound(to: Float.self)
            for x in 0..<outW {
                let srcX = min(srcSize - 1, Int(Float(x) * xRatio))
                let disp = disparity518[srcY * srcSize + srcX]
                let depth: Float
                if disp.isFinite, disp > 1e-4 {
                    depth = scale / disp
                } else {
                    depth = 0  // invalid
                }
                dstRow[x] = depth
            }
        }
        return buffer
    }
}
