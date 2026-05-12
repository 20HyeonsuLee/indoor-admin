import Testing
import simd
@testable import IndoorPathfinding

/// FloorProjection 순수 함수 단위 테스트.
/// ARSession/ARKit 불필요 — 시뮬레이터에서 실행 가능.
@Suite("FloorProjection")
struct FloorProjectionTests {

    // MARK: - Helpers

    private func makeCameraTransform(x: Float, y: Float, z: Float) -> simd_float4x4 {
        var t = matrix_identity_float4x4
        t.columns.3 = SIMD4<Float>(x, y, z, 1)
        return t
    }

    // MARK: - AC-AR-pose: corridor xz preserved after floor projection

    @Test("corridor mark — xz는 카메라와 동일, y는 floorY로 강제")
    func test_corridor_xz_preserved() {
        let cameraT = makeCameraTransform(x: 1.2, y: 1.5, z: -0.3)
        let floorY: Float = -0.2

        let result = FloorProjection.projectCameraToFloor(
            cameraTransform: cameraT,
            floorY: floorY
        )

        #expect(result.x == 1.2)
        #expect(result.y == floorY)
        #expect(result.z == -0.3)
    }

    @Test("makeFloorProjectedTransform — rotation 보존, translation.y == floorY")
    func test_make_floor_projected_transform_rotation_preserved() {
        // 45도 회전된 카메라 transform
        var cameraT = matrix_identity_float4x4
        cameraT.columns.0 = SIMD4<Float>( 0.707, 0, 0.707, 0)
        cameraT.columns.2 = SIMD4<Float>(-0.707, 0, 0.707, 0)
        cameraT.columns.3 = SIMD4<Float>(2.0, 1.6, -1.0, 1)
        let floorY: Float = 0.0

        let projected = FloorProjection.makeFloorProjectedTransform(
            cameraTransform: cameraT,
            floorY: floorY
        )

        // xz 위치 보존
        #expect(projected.columns.3.x == 2.0)
        #expect(projected.columns.3.y == floorY)
        #expect(projected.columns.3.z == -1.0)

        // rotation columns 보존
        #expect(projected.columns.0 == cameraT.columns.0)
        #expect(projected.columns.1 == cameraT.columns.1)
        #expect(projected.columns.2 == cameraT.columns.2)
    }

    // MARK: - AC-AR-bottom: corner y == floorY after clamp

    @Test("corner mark — raycast y를 floorY로 강제 교체")
    func test_corner_y_clamped_to_floor() {
        // raycast가 벽에 hit했을 때 y = 1.2 (카메라 높이 근처)
        var raycastT = matrix_identity_float4x4
        raycastT.columns.3 = SIMD4<Float>(3.5, 1.2, -2.0, 1)
        let floorY: Float = -0.15

        let clamped = FloorProjection.clampToFloor(
            raycastTransform: raycastT,
            floorY: floorY
        )

        // xz는 raycast 결과 그대로
        #expect(clamped.columns.3.x == 3.5)
        #expect(clamped.columns.3.y == floorY)
        #expect(clamped.columns.3.z == -2.0)
    }

    // MARK: - rayFloorIntersection

    @Test("ray-plane intersection — 수직 아래 ray, 교차점 계산")
    func test_ray_floor_intersection_downward() {
        let origin = SIMD3<Float>(1.0, 1.5, 0.0)
        let direction = SIMD3<Float>(0, -1, 0)  // 수직 아래
        let floorY: Float = 0.0

        let hit = FloorProjection.rayFloorIntersection(
            cameraOrigin: origin,
            rayDirection: direction,
            floorY: floorY
        )

        #expect(hit != nil)
        #expect(abs(hit!.x - 1.0) < 0.001)
        #expect(abs(hit!.y - 0.0) < 0.001)
        #expect(abs(hit!.z - 0.0) < 0.001)
    }

    @Test("ray-plane intersection — 대각선 ray")
    func test_ray_floor_intersection_diagonal() {
        let origin = SIMD3<Float>(0.0, 1.0, 0.0)
        // 45도 아래 전방
        let dir = simd_normalize(SIMD3<Float>(1.0, -1.0, 0.0))
        let floorY: Float = 0.0

        let hit = FloorProjection.rayFloorIntersection(
            cameraOrigin: origin,
            rayDirection: dir,
            floorY: floorY
        )

        #expect(hit != nil)
        // t = 1.0/dir.y * (-1) = sqrt(2)
        // x = 0 + sqrt(2) * (1/sqrt(2)) = 1
        #expect(abs(hit!.x - 1.0) < 0.01)
        #expect(abs(hit!.y - 0.0) < 0.001)
    }

    @Test("ray-plane intersection — 수평 ray, nil 반환")
    func test_ray_floor_intersection_horizontal_returns_nil() {
        let origin = SIMD3<Float>(0.0, 1.0, 0.0)
        let direction = SIMD3<Float>(1, 0, 0)  // 수평 — 교차 없음

        let hit = FloorProjection.rayFloorIntersection(
            cameraOrigin: origin,
            rayDirection: direction,
            floorY: 0.0
        )

        #expect(hit == nil)
    }

    @Test("ray-plane intersection — 위 방향 ray, nil 반환 (카메라 뒤)")
    func test_ray_floor_intersection_upward_returns_nil() {
        let origin = SIMD3<Float>(0.0, 1.0, 0.0)
        let direction = SIMD3<Float>(0, 1, 0)  // 위 방향 — floor(y=0)는 뒤에 있음

        let hit = FloorProjection.rayFloorIntersection(
            cameraOrigin: origin,
            rayDirection: direction,
            floorY: 0.0
        )

        #expect(hit == nil)
    }

    // MARK: - isFloorCompatible

    @Test("isFloorCompatible — 0.3m 오차는 허용")
    func test_floor_compatible_within_threshold() {
        #expect(FloorProjection.isFloorCompatible(resultY: 0.3, floorY: 0.0, threshold: 0.5))
    }

    @Test("isFloorCompatible — 0.6m 오차는 reject")
    func test_floor_compatible_exceeds_threshold() {
        #expect(!FloorProjection.isFloorCompatible(resultY: 0.6, floorY: 0.0, threshold: 0.5))
    }

    @Test("isFloorCompatible — 정확히 0.5m는 허용")
    func test_floor_compatible_exact_threshold() {
        #expect(FloorProjection.isFloorCompatible(resultY: 0.5, floorY: 0.0, threshold: 0.5))
    }
}
