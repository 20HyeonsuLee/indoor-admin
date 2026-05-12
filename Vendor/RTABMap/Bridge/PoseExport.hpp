//
// PoseExport.hpp — Sprint 8 pose export C API
// RTABMap의 최적화된 pose graph를 Swift로 꺼내기 위한 extern "C" 래퍼.
// Vendor 원본 소스(NativeWrapper.hpp 등)는 수정하지 않는다.
//

#ifndef PoseExport_hpp
#define PoseExport_hpp

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 현재 최적화된 pose 개수를 반환한다.
/// object: createNativeApplication()이 반환한 포인터.
int32_t getOptimizedPoseCountNative(const void *object);

/// 최적화된 pose를 ids/matrices 버퍼에 채운다.
/// ids:      node ID 배열 (capacity 크기). int32_t.
/// matrices: 4x4 행렬 배열 (capacity * 16 크기). float, column-major.
///           (rtabmap::Transform는 row-major이므로 함수 내부에서 transpose 처리)
/// capacity: 버퍼 크기 (getOptimizedPoseCountNative 반환값 이상이어야 함).
/// returns:  실제로 채운 pose 수.
int32_t getOptimizedPosesNative(const void *object,
                                int32_t *ids,
                                float *matrices,
                                int32_t capacity);

/// RTAB-Map이 마지막으로 처리한 location(node)의 ID를 동기적으로 반환한다.
/// RTABMapApp.cpp의 postOdometryEvent 직후 즉시 호출해 nodeID를 가져온다.
/// rtabmap_->getLastLocationId() 를 래핑한다.
/// object: createNativeApplication()이 반환한 포인터.
/// returns: 마지막 nodeID (0 이하이면 아직 node 없음).
int32_t getLastLocationIdNative(const void *object);

/// 지정한 nodeId의 캡처 timestamp(초, Unix epoch)를 반환한다.
/// RTABMap Memory에서 Signature를 조회해 stamp를 꺼낸다.
/// statsUpdated 콜백에서 nodeId가 확정된 후 호출해 ARKit capturedAt과 매칭하는 데 쓰인다.
/// object: createNativeApplication()이 반환한 포인터.
/// nodeId: getLastLocationIdNative() 등으로 얻은 node ID.
/// returns: stamp (초 단위, double). 노드 미발견이면 0.0 반환.
double getNodeStampNative(const void *object, int32_t nodeId);

/// Sprint 35 v4: finalize 시점 backfill용.
/// RTAB-Map 메모리/DB에 있는 모든 node의 (ID, stamp) 쌍을 outIds/outStamps 버퍼에 채운다.
/// 호출 측에서 버퍼를 pre-allocate해야 한다.
/// object:     createNativeApplication()이 반환한 포인터.
/// outIds:     node ID 배열 (maxCount 크기). int32_t.
/// outStamps:  stamp 배열 (maxCount 크기). double, 초 단위.
/// maxCount:   버퍼 크기. 이보다 많은 노드가 있어도 maxCount만큼만 채운다.
/// returns:    실제로 채운 쌍의 수.
int32_t getAllNodeIdsAndStampsNative(const void *object,
                                     int32_t *outIds,
                                     double  *outStamps,
                                     int32_t  maxCount);

#ifdef __cplusplus
}
#endif

#endif /* PoseExport_hpp */
