import ARKit
import simd
import os.log

/// ARSession.raycastQuery 래퍼.
///
/// ## Sprint 88 Cycle 4 — H6 fix:
///   Cycle 3에서 도입한 alignment: .vertical 강제를 제거하고
///   alignment: .horizontal 우선으로 재정의한다.
///   corner = 공간 외곽 바닥 polygon 정점 → floor plane 위 점이 목표.
///
///   우선순위:
///     1. existingPlaneGeometry + horizontal  (LiDAR floor mesh)
///     2. estimatedPlane + horizontal          (LiDAR 없는 단말 floor 추정)
///     3. ray-plane intersection fallback      (FloorProjection.rayFloorIntersection)
///
///   result.y와 floorY 차이 > 0.5m → reject + nil 반환 (호출자가 toast 처리).
///
/// ## Sprint 88 Cycle 3 — H1 fix 보존:
///   `ARFrame.raycastQuery(from:allowing:alignment:)` 표준 API 유지.
///   portrait CGPoint를 ARKit이 자동 보정 — 추가 portrait 변환 코드 없음.
enum ARRaycastHelper {

    private static let logger = Logger(subsystem: "com.indoorpathfinding", category: "ARPlacement")

    // MARK: - Public API

    /// Sprint 88 cycle_4 H10 fix: ARSCNView 사용 viewport-aware raycast.
    /// ARFrame.raycastQuery는 image-space coord 기대 → portrait UIKit point를 그대로 넣으면 잘못된 ray.
    /// ARSCNView.raycastQuery는 view bounds 좌표 받고 viewport 보정 자동.
    static func raycast(
        from screenPoint: CGPoint,
        in sceneView: ARSCNView,
        floorY: Float?,
        completion: @escaping @MainActor (simd_float4x4?) -> Void
    ) {
        guard let currentFrame = sceneView.session.currentFrame else {
            Task { @MainActor in completion(nil) }
            return
        }

        logger.debug(
            "CORNER_DEBUG (sceneView) tap=(\(screenPoint.x, format: .fixed(precision: 1)),\(screenPoint.y, format: .fixed(precision: 1))) bounds=(\(sceneView.bounds.width, format: .fixed(precision: 1))x\(sceneView.bounds.height, format: .fixed(precision: 1))) floorReferenceY=\(floorY ?? Float.nan, format: .fixed(precision: 3))"
        )

        let arSession = sceneView.session

        // 1순위: existingPlaneGeometry + horizontal — view-aware raycastQuery
        if let q1 = sceneView.raycastQuery(from: screenPoint, allowing: .existingPlaneGeometry, alignment: .horizontal) {
            let r1 = arSession.raycast(q1)
            if let result = r1.first {
                let col3 = result.worldTransform.columns.3
                logger.debug("RAYCAST_DEBUG (view) result(existingPlane+H).col3=(\(col3.x, format: .fixed(precision: 3)),\(col3.y, format: .fixed(precision: 3)),\(col3.z, format: .fixed(precision: 3)))")
                if let fy = floorY, !FloorProjection.isFloorCompatible(resultY: col3.y, floorY: fy) {
                    logger.debug("CORNER_DEBUG existingPlane+H rejected: deltaY=\(abs(col3.y - fy), format: .fixed(precision: 3)) > 0.5m")
                } else {
                    let clamped = applyFloorClamp(result.worldTransform, floorY: floorY)
                    logCornerResult(chosen: "existingPlane+H(view)", transform: clamped, floorY: floorY)
                    Task { @MainActor in completion(clamped) }
                    return
                }
            }
        }

        // 2순위: estimatedPlane + horizontal — view-aware
        if let q2 = sceneView.raycastQuery(from: screenPoint, allowing: .estimatedPlane, alignment: .horizontal) {
            let r2 = arSession.raycast(q2)
            if let result = r2.first {
                let col3 = result.worldTransform.columns.3
                logger.debug("RAYCAST_DEBUG (view) result(estimatedPlane+H).col3=(\(col3.x, format: .fixed(precision: 3)),\(col3.y, format: .fixed(precision: 3)),\(col3.z, format: .fixed(precision: 3)))")
                if let fy = floorY, !FloorProjection.isFloorCompatible(resultY: col3.y, floorY: fy) {
                    logger.debug("CORNER_DEBUG estimatedPlane+H rejected: deltaY=\(abs(col3.y - fy), format: .fixed(precision: 3)) > 0.5m")
                } else {
                    let clamped = applyFloorClamp(result.worldTransform, floorY: floorY)
                    logCornerResult(chosen: "estimatedPlane+H(view)", transform: clamped, floorY: floorY)
                    Task { @MainActor in completion(clamped) }
                    return
                }
            }
        }

        // 3순위: ray-plane intersection fallback (estimatedPlane+any로 ray 방향 얻기)
        if let fy = floorY {
            let camPos = currentFrame.camera.transform.columns.3.xyz
            if let q3 = sceneView.raycastQuery(from: screenPoint, allowing: .estimatedPlane, alignment: .any) {
                let r3 = arSession.raycast(q3)
                if let r = r3.first {
                    let hitPos = r.worldTransform.columns.3.xyz
                    let rayDir = simd_normalize(hitPos - camPos)
                    if let intersection = FloorProjection.rayFloorIntersection(
                        cameraOrigin: camPos,
                        rayDirection: rayDir,
                        floorY: fy
                    ) {
                        var t = matrix_identity_float4x4
                        t.columns.3 = SIMD4<Float>(intersection.x, intersection.y, intersection.z, 1)
                        logCornerResult(chosen: "rayPlaneIntersection(view)", transform: t, floorY: floorY)
                        Task { @MainActor in completion(t) }
                        return
                    }
                }
            }
            // estimatedPlane+any 실패 시 camera forward — view-independent
            let forward = -currentFrame.camera.transform.columns.2.xyz
            if let intersection = FloorProjection.rayFloorIntersection(
                cameraOrigin: camPos,
                rayDirection: simd_normalize(forward),
                floorY: fy
            ) {
                var t = matrix_identity_float4x4
                t.columns.3 = SIMD4<Float>(intersection.x, intersection.y, intersection.z, 1)
                logCornerResult(chosen: "cameraForwardIntersection(view)", transform: t, floorY: floorY)
                Task { @MainActor in completion(t) }
                return
            }
        }

        logger.debug("RAYCAST_DEBUG (view) all horizontal targets failed for screenPt=(\(screenPoint.x, format: .fixed(precision: 1)),\(screenPoint.y, format: .fixed(precision: 1)))")
        Task { @MainActor in completion(nil) }
    }

    /// Sprint 88 cycle_4 H10: 레거시 ARSession 경로 (frame.raycastQuery image-space 좌표).
    /// ARSCNView reference가 없을 때만 호출. portrait UIKit point는 정확하지 않을 수 있음 — 가능하면 view 버전 사용.
    static func raycast(
        from screenPoint: CGPoint,
        in arSession: ARSession,
        floorY: Float?,
        completion: @escaping @MainActor (simd_float4x4?) -> Void
    ) {
        guard let currentFrame = arSession.currentFrame else {
            Task { @MainActor in completion(nil) }
            return
        }

        logger.debug(
            "CORNER_DEBUG tap=(\(screenPoint.x, format: .fixed(precision: 1)),\(screenPoint.y, format: .fixed(precision: 1))) floorReferenceY=\(floorY ?? Float.nan, format: .fixed(precision: 3))"
        )

        // --- 1순위: existingPlaneGeometry + horizontal ---
        let query1 = currentFrame.raycastQuery(
            from: screenPoint,
            allowing: .existingPlaneGeometry,
            alignment: .horizontal
        )
        let results1 = arSession.raycast(query1)
        if let result = results1.first {
            let col3 = result.worldTransform.columns.3
            logger.debug(
                "RAYCAST_DEBUG result(existingPlane+H).col3=(\(col3.x, format: .fixed(precision: 3)),\(col3.y, format: .fixed(precision: 3)),\(col3.z, format: .fixed(precision: 3)))"
            )
            if let fy = floorY, !FloorProjection.isFloorCompatible(resultY: col3.y, floorY: fy) {
                logger.debug("CORNER_DEBUG existingPlane+H rejected: deltaY=\(abs(col3.y - fy), format: .fixed(precision: 3)) > 0.5m")
            } else {
                let clamped = applyFloorClamp(result.worldTransform, floorY: floorY)
                logCornerResult(chosen: "existingPlane+H", transform: clamped, floorY: floorY)
                Task { @MainActor in completion(clamped) }
                return
            }
        }

        // --- 2순위: estimatedPlane + horizontal ---
        let query2 = currentFrame.raycastQuery(
            from: screenPoint,
            allowing: .estimatedPlane,
            alignment: .horizontal
        )
        let results2 = arSession.raycast(query2)
        if let result = results2.first {
            let col3 = result.worldTransform.columns.3
            logger.debug(
                "RAYCAST_DEBUG result(estimatedPlane+H).col3=(\(col3.x, format: .fixed(precision: 3)),\(col3.y, format: .fixed(precision: 3)),\(col3.z, format: .fixed(precision: 3)))"
            )
            if let fy = floorY, !FloorProjection.isFloorCompatible(resultY: col3.y, floorY: fy) {
                logger.debug("CORNER_DEBUG estimatedPlane+H rejected: deltaY=\(abs(col3.y - fy), format: .fixed(precision: 3)) > 0.5m")
            } else {
                let clamped = applyFloorClamp(result.worldTransform, floorY: floorY)
                logCornerResult(chosen: "estimatedPlane+H", transform: clamped, floorY: floorY)
                Task { @MainActor in completion(clamped) }
                return
            }
        }

        // --- 3순위: ray-plane intersection fallback ---
        if let fy = floorY {
            let camPos = currentFrame.camera.transform.columns.3.xyz
            // 화면 중심 방향이 아닌 tap 방향 ray 계산: unproject via intrinsics
            // ARKit 표준: estimatedPlane+any로 tap 방향 ray 얻기
            let query3 = currentFrame.raycastQuery(
                from: screenPoint,
                allowing: .estimatedPlane,
                alignment: .any
            )
            let results3 = arSession.raycast(query3)
            if let r = results3.first {
                let hitPos = r.worldTransform.columns.3.xyz
                let rayDir = simd_normalize(hitPos - camPos)
                if let intersection = FloorProjection.rayFloorIntersection(
                    cameraOrigin: camPos,
                    rayDirection: rayDir,
                    floorY: fy
                ) {
                    var t = matrix_identity_float4x4
                    t.columns.3 = SIMD4<Float>(intersection.x, intersection.y, intersection.z, 1)
                    logCornerResult(chosen: "rayPlaneIntersection", transform: t, floorY: floorY)
                    Task { @MainActor in completion(t) }
                    return
                }
            } else {
                // estimatedPlane+any 실패 시 camera forward ray로 직접 계산
                let forward = -currentFrame.camera.transform.columns.2.xyz
                if let intersection = FloorProjection.rayFloorIntersection(
                    cameraOrigin: camPos,
                    rayDirection: simd_normalize(forward),
                    floorY: fy
                ) {
                    var t = matrix_identity_float4x4
                    t.columns.3 = SIMD4<Float>(intersection.x, intersection.y, intersection.z, 1)
                    logCornerResult(chosen: "cameraForwardIntersection", transform: t, floorY: floorY)
                    Task { @MainActor in completion(t) }
                    return
                }
            }
        }

        // 모두 실패
        logger.debug(
            "RAYCAST_DEBUG all horizontal targets failed for screenPt=(\(screenPoint.x, format: .fixed(precision: 1)),\(screenPoint.y, format: .fixed(precision: 1)))"
        )
        Task { @MainActor in completion(nil) }
    }

    // MARK: - Legacy API (no floorY, backward compat)

    /// floorY 없이 호출하는 레거시 경로. 내부에서 floorY=nil 로 위임.
    static func raycast(
        from screenPoint: CGPoint,
        in arSession: ARSession,
        completion: @escaping @MainActor (simd_float4x4?) -> Void
    ) {
        raycast(from: screenPoint, in: arSession, floorY: nil, completion: completion)
    }

    // MARK: - Private Helpers

    private static func applyFloorClamp(_ transform: simd_float4x4, floorY: Float?) -> simd_float4x4 {
        guard let fy = floorY else { return transform }
        return FloorProjection.clampToFloor(raycastTransform: transform, floorY: fy)
    }

    private static func logCornerResult(
        chosen: String,
        transform: simd_float4x4,
        floorY: Float?
    ) {
        let col3 = transform.columns.3
        let fy = floorY ?? Float.nan
        let deltaY = abs(col3.y - fy)
        logger.debug(
            "CORNER_DEBUG chosen=\(chosen, privacy: .public) raycastHit=(\(col3.x, format: .fixed(precision: 3)),\(col3.y, format: .fixed(precision: 3)),\(col3.z, format: .fixed(precision: 3))) floorReferenceY=\(fy, format: .fixed(precision: 3)) projectedWorld=(\(col3.x, format: .fixed(precision: 3)),\(fy, format: .fixed(precision: 3)),\(col3.z, format: .fixed(precision: 3))) deltaY=\(deltaY, format: .fixed(precision: 3))"
        )
    }
}
