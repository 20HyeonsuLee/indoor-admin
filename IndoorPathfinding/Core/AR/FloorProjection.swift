import simd

// MARK: - FloorProjection

/// Floor plane projection 순수 함수 모음.
/// ARKit / ARSession에 의존하지 않아 시뮬레이터에서 단위 테스트 가능.
enum FloorProjection {

    // MARK: - Corridor: camera position → floor projection

    /// 카메라 transform의 xz 위치를 floorY로 수직 투영한다.
    /// - Parameters:
    ///   - cameraTransform: ARCamera.transform (world 좌표계)
    ///   - floorY: 바닥 평면 y 좌표 (world 단위: m)
    /// - Returns: (floorX, floorY, floorZ) — xz는 카메라와 동일, y는 floor로 강제
    static func projectCameraToFloor(
        cameraTransform: simd_float4x4,
        floorY: Float
    ) -> SIMD3<Float> {
        let camPos = cameraTransform.columns.3
        return SIMD3<Float>(camPos.x, floorY, camPos.z)
    }

    /// 카메라 transform에서 rotation을 보존하되 translation.y만 floorY로 교체한 새 transform 반환.
    /// - Parameters:
    ///   - cameraTransform: 원본 카메라 transform
    ///   - floorY: 바닥 y 좌표
    /// - Returns: translation.y = floorY인 simd_float4x4
    static func makeFloorProjectedTransform(
        cameraTransform: simd_float4x4,
        floorY: Float
    ) -> simd_float4x4 {
        var result = cameraTransform
        result.columns.3.y = floorY
        return result
    }

    // MARK: - Corner: raycast hit y → floor clamping

    /// raycast worldTransform의 y를 floorY로 강제 교체한 transform 반환.
    /// xz는 raycast 결과 그대로 유지한다.
    /// - Parameters:
    ///   - raycastTransform: ARRaycastResult.worldTransform
    ///   - floorY: 바닥 y 좌표
    /// - Returns: y = floorY로 교체된 transform
    static func clampToFloor(
        raycastTransform: simd_float4x4,
        floorY: Float
    ) -> simd_float4x4 {
        var result = raycastTransform
        result.columns.3.y = floorY
        return result
    }

    // MARK: - Ray-Plane Intersection (manual fallback)

    /// 카메라 원점 + 방향 ray와 수평 평면 y=floorY의 교차점 계산.
    /// - Parameters:
    ///   - cameraOrigin: 카메라 위치 (world)
    ///   - rayDirection: normalized 방향 벡터 (world)
    ///   - floorY: 수평 평면 y
    /// - Returns: 교차점 SIMD3<Float>, 교차 없으면 nil (ray가 수평 평면과 평행)
    static func rayFloorIntersection(
        cameraOrigin: SIMD3<Float>,
        rayDirection: SIMD3<Float>,
        floorY: Float
    ) -> SIMD3<Float>? {
        // 평면 방정식: y = floorY
        // ray: P = origin + t * direction
        // t = (floorY - origin.y) / direction.y
        let denom = rayDirection.y
        guard abs(denom) > 1e-6 else { return nil }   // 수평 ray — 교차 없음
        let t = (floorY - cameraOrigin.y) / denom
        guard t > 0 else { return nil }                // 카메라 뒤에 있는 경우
        let hit = cameraOrigin + t * rayDirection
        return hit
    }

    // MARK: - Floor Reject Filter

    /// raycast 결과 y와 floorY의 차이가 threshold 이내인지 확인.
    /// - Parameters:
    ///   - resultY: raycast worldTransform.columns.3.y
    ///   - floorY: 기준 floor y
    ///   - threshold: 허용 오차 (m, 기본 0.5)
    /// - Returns: true면 사용 가능한 결과
    static func isFloorCompatible(resultY: Float, floorY: Float, threshold: Float = 0.5) -> Bool {
        abs(resultY - floorY) <= threshold
    }
}

// MARK: - SIMD4 xyz helper (package-internal)

extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3<Float>(x, y, z) }
}
