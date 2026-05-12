//
//  IndoorPathfinding-Bridging-Header.h
//  IndoorPathfinding
//
//  RTAB-Map NativeWrapper C API 노출.
//  NativeWrapper.hpp는 extern "C" 선언만 담고 있으므로
//  시뮬레이터 빌드에서도 헤더 파싱은 성공 (링크 없음).
//

#ifndef IndoorPathfinding_Bridging_Header_h
#define IndoorPathfinding_Bridging_Header_h

#import "NativeWrapper.hpp"
// Sprint 8: optimized pose graph export C API
#import "PoseExport.hpp"

#endif /* IndoorPathfinding_Bridging_Header_h */
