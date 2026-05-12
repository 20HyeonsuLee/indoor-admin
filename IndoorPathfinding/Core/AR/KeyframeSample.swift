import simd
import CoreVideo

/// ARKit delegate에서 복사·추출한 값 타입 keyframe 스냅샷.
/// 원본 ARFrame 참조를 절대 보유하지 않는다 (ARKit pool 재활용 방지).
struct KeyframeSample: @unchecked Sendable {
    // MARK: - 기존 필드 (Sprint 3 그대로)

    /// 복사된 YUV 2-plane 픽셀 버퍼 (ARKit 420f 포맷).
    let pixelBuffer: CVPixelBuffer
    /// ARCamera.transform (column-major, ARKit 월드 좌표).
    let transform: simd_float4x4
    let capturedAt: Date
    /// "normal" | "limited.initializing" | "limited.excessiveMotion" | ...
    let trackingStateLabel: String

    /// Sprint 67 — ARFrame.timestamp (CACurrentMediaTime monotonic, seconds).
    /// AVAssetWriter PTS와 poses.bin의 single source of truth.
    /// `capturedAt`은 wall-clock Date()라 frame index/PTS 매칭에 절대 사용 금지.
    let arFrameTimestamp: TimeInterval

    // MARK: - 추가 필드 (Sprint 3.5 — RTAB-Map 통합용)

    /// ARCamera.intrinsics에서 추출한 초점 거리/주점.
    let intrinsicsFx: Float
    let intrinsicsFy: Float
    let intrinsicsCx: Float
    let intrinsicsCy: Float

    /// portrait 고정 orientation에 대해 계산한 뷰 행렬.
    let viewMatrix: simd_float4x4
    /// portrait 고정 orientation에 대해 계산한 투영 행렬 (zNear: 0.5, zFar: 50).
    let projectionMatrix: simd_float4x4

    /// LiDAR 기기 전용 depth/confidence 맵. 비-LiDAR 기기에서는 nil.
    let depthMap: CVPixelBuffer?
    let confidenceMap: CVPixelBuffer?

    /// ARKit raw feature points. 값 타입 배열로 복사 보관.
    let featurePoints: [simd_float3]

    // MARK: - 계산 프로퍼티

    var translation: SIMD3<Float> {
        SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
    }

    var isLiDAR: Bool { depthMap != nil }
}

// MARK: - 테스트 전용 Factory

extension KeyframeSample {
    /// 유닛 테스트 전용. 신규 필드에 기본값을 채워 Sprint 3 테스트 코드와의 호환성을 유지한다.
    static func forTest(
        pixelBuffer: CVPixelBuffer,
        transform: simd_float4x4 = matrix_identity_float4x4,
        capturedAt: Date = Date(),
        trackingStateLabel: String = "normal",
        arFrameTimestamp: TimeInterval = 0,
        featurePoints: [simd_float3] = []
    ) -> KeyframeSample {
        KeyframeSample(
            pixelBuffer: pixelBuffer,
            transform: transform,
            capturedAt: capturedAt,
            trackingStateLabel: trackingStateLabel,
            arFrameTimestamp: arFrameTimestamp,
            intrinsicsFx: 0,
            intrinsicsFy: 0,
            intrinsicsCx: 0,
            intrinsicsCy: 0,
            viewMatrix: matrix_identity_float4x4,
            projectionMatrix: matrix_identity_float4x4,
            depthMap: nil,
            confidenceMap: nil,
            featurePoints: featurePoints
        )
    }
}
