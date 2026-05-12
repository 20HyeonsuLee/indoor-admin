//
// PoseExport.cpp — Sprint 8 pose export C API 구현
//

#include "PoseExport.hpp"
#include "RTABMapApp.h"

#include <rtabmap/core/Rtabmap.h>
#include <rtabmap/core/Memory.h>
#include <rtabmap/core/Signature.h>
#include <rtabmap/core/Link.h>
#include <map>

extern "C" {

int32_t getOptimizedPoseCountNative(const void *object) {
    if (!object) return 0;
    const RTABMapApp *app = reinterpret_cast<const RTABMapApp *>(object);
    rtabmap::Rtabmap *rtabmap = app->getRtabmap();
    if (!rtabmap) return 0;

    std::map<int, rtabmap::Transform> poses;
    std::multimap<int, rtabmap::Link> links;
    rtabmap->getGraph(poses, links, true, true);
    return static_cast<int32_t>(poses.size());
}

int32_t getOptimizedPosesNative(const void *object,
                                int32_t *ids,
                                float *matrices,
                                int32_t capacity) {
    if (!object || !ids || !matrices || capacity <= 0) return 0;

    const RTABMapApp *app = reinterpret_cast<const RTABMapApp *>(object);
    rtabmap::Rtabmap *rtabmap = app->getRtabmap();
    if (!rtabmap) return 0;

    std::map<int, rtabmap::Transform> poses;
    std::multimap<int, rtabmap::Link> links;
    rtabmap->getGraph(poses, links, true, true);

    int32_t count = 0;
    for (const auto &kv : poses) {
        if (count >= capacity) break;

        ids[count] = static_cast<int32_t>(kv.first);

        // rtabmap::Transform::data() 는 row-major 3×4 배열 (data[row*4+col]).
        // simd_float4x4 (column-major) 형태로 변환하기 위해 transpose한다.
        // column-major 출력: matrices[col*4 + row]
        //
        // rtabmap Transform은 3행 4열 (rotation 3x3 + translation 3x1).
        // 마지막 행은 [0, 0, 0, 1] (동차 좌표계).
        const float *src = kv.second.data(); // row-major [row*4+col], 12 floats
        float *dst = matrices + count * 16;  // column-major 4x4, 16 floats

        // column 0: src col 0 (rows 0,1,2) + 0 (row 3)
        dst[0]  = src[0];  // row0,col0
        dst[1]  = src[4];  // row1,col0
        dst[2]  = src[8];  // row2,col0
        dst[3]  = 0.0f;    // row3,col0

        // column 1: src col 1
        dst[4]  = src[1];  // row0,col1
        dst[5]  = src[5];  // row1,col1
        dst[6]  = src[9];  // row2,col1
        dst[7]  = 0.0f;    // row3,col1

        // column 2: src col 2
        dst[8]  = src[2];  // row0,col2
        dst[9]  = src[6];  // row1,col2
        dst[10] = src[10]; // row2,col2
        dst[11] = 0.0f;    // row3,col2

        // column 3: translation (src col 3) + w=1
        dst[12] = src[3];  // row0,col3 = tx
        dst[13] = src[7];  // row1,col3 = ty
        dst[14] = src[11]; // row2,col3 = tz
        dst[15] = 1.0f;    // row3,col3

        ++count;
    }
    return count;
}

int32_t getLastLocationIdNative(const void *object) {
    if (!object) return 0;
    const RTABMapApp *app = reinterpret_cast<const RTABMapApp *>(object);
    rtabmap::Rtabmap *rtabmap = app->getRtabmap();
    if (!rtabmap) return 0;
    // rtabmap::Rtabmap::getLastLocationId() 는 마지막으로 처리된 node ID를 반환한다.
    // postOdometryEventNative 직후 호출하면 동기적으로 현재 node ID를 가져올 수 있다.
    return static_cast<int32_t>(rtabmap->getLastLocationId());
}

double getNodeStampNative(const void *object, int32_t nodeId) {
    if (!object || nodeId <= 0) return 0.0;
    const RTABMapApp *app = reinterpret_cast<const RTABMapApp *>(object);
    rtabmap::Rtabmap *rtabmap = app->getRtabmap();
    if (!rtabmap) return 0.0;

    const rtabmap::Memory *memory = rtabmap->getMemory();
    if (!memory) return 0.0;

    // Signature가 STM/WM에 존재하면 직접 조회 (빠름).
    const rtabmap::Signature *sig = memory->getSignature(static_cast<int>(nodeId));
    if (sig) {
        return sig->getStamp();
    }

    // STM/WM에 없으면(LTM으로 이동된 경우) getNodeInfo로 DB 조회.
    rtabmap::Transform odomPose, groundTruth;
    int mapId = 0, weight = 0;
    std::string label;
    double stamp = 0.0;
    std::vector<float> velocity;
    rtabmap::GPS gps;
    rtabmap::EnvSensors sensors;
    bool found = memory->getNodeInfo(
        static_cast<int>(nodeId),
        odomPose, mapId, weight, label, stamp,
        groundTruth, velocity, gps, sensors,
        /*lookInDatabase=*/true
    );
    return found ? stamp : 0.0;
}

// Sprint 35 v4: finalize backfill — 모든 node (id, stamp) 배열 반환.
// getGraph(global poses) + Memory::getSignature 조합으로 stamp를 채운다.
// LTM으로 이동된 signature는 getNodeInfo DB 조회 fallback으로 처리한다.
int32_t getAllNodeIdsAndStampsNative(const void *object,
                                     int32_t *outIds,
                                     double  *outStamps,
                                     int32_t  maxCount) {
    if (!object || !outIds || !outStamps || maxCount <= 0) return 0;

    const RTABMapApp *app = reinterpret_cast<const RTABMapApp *>(object);
    rtabmap::Rtabmap *rtabmap = app->getRtabmap();
    if (!rtabmap) return 0;

    const rtabmap::Memory *memory = rtabmap->getMemory();

    // getGraph: 최적화된 pose가 있는 모든 node ID를 얻는다.
    std::map<int, rtabmap::Transform> poses;
    std::multimap<int, rtabmap::Link> links;
    rtabmap->getGraph(poses, links, true, true);

    int32_t count = 0;
    for (const auto &kv : poses) {
        if (count >= maxCount) break;

        const int nodeId = kv.first;
        double stamp = 0.0;

        if (memory) {
            // 1순위: STM/WM에서 직접 조회 (빠름)
            const rtabmap::Signature *sig = memory->getSignature(nodeId);
            if (sig) {
                stamp = sig->getStamp();
            } else {
                // 2순위: LTM / DB 조회 (느리지만 finalize 시점이므로 허용)
                rtabmap::Transform odomPose, groundTruth;
                int mapId = 0, weight = 0;
                std::string label;
                std::vector<float> velocity;
                rtabmap::GPS gps;
                rtabmap::EnvSensors sensors;
                bool found = memory->getNodeInfo(
                    nodeId,
                    odomPose, mapId, weight, label, stamp,
                    groundTruth, velocity, gps, sensors,
                    /*lookInDatabase=*/true
                );
                if (!found) stamp = 0.0;
            }
        }

        outIds[count]    = static_cast<int32_t>(nodeId);
        outStamps[count] = stamp;
        ++count;
    }
    return count;
}

} // extern "C"
