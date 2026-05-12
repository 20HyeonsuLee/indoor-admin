import Foundation
import simd

/// Sprint 91: Depth Anything V2 Small 출력(relative inverse depth)을 metric meter로 변환할
/// scalar `s`를 ARKit `rawFeaturePoints` 분포로 추정.
///
/// ## 알고리즘 (plan §5)
/// 1. featurePoints (world) → camera frame: `pCam = viewMatrix · pWorld`. depth = `-pCam.z`
///    (ARKit camera convention: +z back, -z forward).
/// 2. (u, v) image projection = `intrinsics · (pCam.x, pCam.y, pCam.z)`.
/// 3. mono 출력은 518×518. RGB image 기준 (u,v)를 518 좌표로 normalize.
/// 4. metric_z_i / disparity_i 비율의 robust median = scale s.
///    (assume `metric = s · 1/disparity` 형식, 즉 `s = metric · disparity` median).
/// 5. inlier feature point < 8 → nil 반환 (caller가 fail-open).
///
/// ## 단순화 원칙
/// - 1-param multiplicative scale only. shift / 2-param affine 추정 X.
/// - RANSAC X. median + IQR 기반 robust.
/// - EMA smoothing은 caller (Estimator) 책임.
struct DepthScaleCalibrator {

    static let minInliers: Int = 8

    /// - Parameters:
    ///   - disparity518: 518×518 Float32 inverse depth (Depth Anything V2 출력)
    ///   - featurePoints: ARKit world frame 점들
    ///   - viewMatrix: world → camera (ARKit `frame.camera.viewMatrix(for:)`)
    ///   - intrinsics: (fx, fy, cx, cy) RGB image 기준
    ///   - rgbWidth/rgbHeight: 원본 RGB 해상도 (intrinsics 기준)
    /// - Returns: scale s. inlier 부족 시 nil.
    static func estimateScale(
        disparity518: UnsafePointer<Float>,
        featurePoints: [SIMD3<Float>],
        viewMatrix: simd_float4x4,
        intrinsics: (fx: Float, fy: Float, cx: Float, cy: Float),
        rgbWidth: Int,
        rgbHeight: Int
    ) -> Float? {
        guard !featurePoints.isEmpty, rgbWidth > 0, rgbHeight > 0 else { return nil }

        let monoSize: Int = 518
        var ratios: [Float] = []
        ratios.reserveCapacity(featurePoints.count)

        let scaleU = Float(monoSize) / Float(rgbWidth)
        let scaleV = Float(monoSize) / Float(rgbHeight)

        for pWorld in featurePoints {
            let pHom = SIMD4<Float>(pWorld, 1)
            let pCam = viewMatrix * pHom
            // ARKit: -z forward. metric depth = -pCam.z.
            let depth = -pCam.z
            guard depth > 0.1, depth < 30.0 else { continue }
            // image projection
            guard pCam.z != 0 else { continue }
            let u = (intrinsics.fx * (pCam.x / -pCam.z)) + intrinsics.cx
            let v = (intrinsics.fy * (-pCam.y / -pCam.z)) + intrinsics.cy
            guard u >= 0, u < Float(rgbWidth), v >= 0, v < Float(rgbHeight) else { continue }

            // mono 좌표
            let uM = Int(u * scaleU)
            let vM = Int(v * scaleV)
            guard uM >= 0, uM < monoSize, vM >= 0, vM < monoSize else { continue }
            let disparity = disparity518[vM * monoSize + uM]
            guard disparity.isFinite, disparity > 1e-4 else { continue }

            // metric = s · (1/disparity)  →  s = metric · disparity
            ratios.append(depth * disparity)
        }

        guard ratios.count >= minInliers else { return nil }

        // robust median
        ratios.sort()
        let median = ratios[ratios.count / 2]
        guard median.isFinite, median > 0 else { return nil }
        return median
    }
}
