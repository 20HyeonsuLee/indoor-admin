#!/usr/bin/env bash
# sync_from_rtabmap_src.sh
# rtabmap-src 빌드 산출물 → Vendor/RTABMap/{lib,include,Bridge} 동기화 스크립트
# install_deps.sh 재실행 후 1회 실행하면 됨.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(dirname "$SCRIPT_DIR")"
SRC_LIB="$IOS_DIR/Vendor/RTABMap/rtabmap-src/app/ios/RTABMapApp/Libraries/lib"
SRC_INC="$IOS_DIR/Vendor/RTABMap/rtabmap-src/app/ios/RTABMapApp/Libraries/include"
SRC_WRAP="$IOS_DIR/Vendor/RTABMap/rtabmap-src/app/ios/RTABMapApp"
DEST_LIB="$IOS_DIR/Vendor/RTABMap/lib"
DEST_INC="$IOS_DIR/Vendor/RTABMap/include"
DEST_BRIDGE="$IOS_DIR/Vendor/RTABMap/Bridge"

echo "=== RTABMap Vendor 동기화 시작 ==="

# --- 1. lib 복사 ---
echo "[1/3] .a 파일 복사: $SRC_LIB → $DEST_LIB"
mkdir -p "$DEST_LIB"

# 필수 .a 선별 복사
REQUIRED_LIBS=(
  librtabmap_core.a
  librtabmap_utilite.a
  # OpenCV
  libopencv_xfeatures2d.a libopencv_video.a libopencv_tracking.a libopencv_optflow.a
  libopencv_ximgproc.a libopencv_stitching.a libopencv_photo.a libopencv_objdetect.a
  libopencv_aruco.a libopencv_calib3d.a libopencv_features2d.a libopencv_imgcodecs.a
  libopencv_imgproc.a libopencv_flann.a libopencv_core.a
  # SuiteSparse
  libamd.a libcamd.a libccolamd.a libcholmod.a libcolamd.a libcxsparse.a libspqr.a libsuitesparseconfig.a
  # g2o
  libg2o_core.a libg2o_csparse_extension.a libg2o_solver_cholmod.a libg2o_solver_csparse.a
  libg2o_solver_dense.a libg2o_solver_eigen.a libg2o_solver_pcg.a libg2o_solver_slam2d_linear.a
  libg2o_solver_structure_only.a libg2o_stuff.a libg2o_types_data.a libg2o_types_icp.a
  libg2o_types_sba.a libg2o_types_sclam2d.a libg2o_types_sim3.a libg2o_types_slam2d.a
  libg2o_types_slam2d_addons.a libg2o_types_slam3d.a libg2o_types_slam3d_addons.a
  # PCL
  libpcl_common.a libpcl_features.a libpcl_filters.a libpcl_io.a libpcl_io_ply.a
  libpcl_kdtree.a libpcl_keypoints.a libpcl_ml.a libpcl_octree.a libpcl_registration.a
  libpcl_sample_consensus.a libpcl_search.a libpcl_segmentation.a libpcl_stereo.a libpcl_surface.a
  # GTSAM
  libgtsam.a libgtsam_unstable.a libmetis-gtsam.a
  # Boost
  libboost_serialization.a libboost_timer.a libboost_thread.a
  # LAS
  liblas.a liblas_c.a liblaszip.a
  # Misc
  libflann_cpp_s.a liblz4.a
)

for lib in "${REQUIRED_LIBS[@]}"; do
  if [ -f "$SRC_LIB/$lib" ]; then
    cp -f "$SRC_LIB/$lib" "$DEST_LIB/$lib"
    echo "  copied: $lib"
  else
    echo "  WARN: $lib not found in source"
  fi
done

# vtk.framework 복사
if [ -d "$SRC_LIB/vtk.framework" ]; then
  cp -Rf "$SRC_LIB/vtk.framework" "$DEST_LIB/vtk.framework"
  echo "  copied: vtk.framework"
fi

# opencv4/3rdparty 복사 (opencv 3rdparty 정적 libs)
if [ -d "$SRC_LIB/opencv4" ]; then
  cp -Rf "$SRC_LIB/opencv4" "$DEST_LIB/opencv4"
  echo "  copied: opencv4/"
fi

echo "[1/3] lib 복사 완료"

# --- 2. include 복사 ---
echo "[2/3] include 복사: $SRC_INC → $DEST_INC"
mkdir -p "$DEST_INC"
cp -Rf "$SRC_INC/." "$DEST_INC/"
echo "[2/3] include 복사 완료"

# --- 3. Bridge 파일 복사 ---
echo "[3/3] Bridge 파일 복사: $SRC_WRAP + android/jni → $DEST_BRIDGE"
mkdir -p "$DEST_BRIDGE"
cp -f "$SRC_WRAP/NativeWrapper.cpp" "$DEST_BRIDGE/NativeWrapper.cpp"
cp -f "$SRC_WRAP/NativeWrapper.hpp" "$DEST_BRIDGE/NativeWrapper.hpp"
cp -f "$SRC_WRAP/text_atlas_png.h" "$DEST_BRIDGE/text_atlas_png.h"

# RTABMapApp 클래스 + 의존 소스 (android/jni 공유)
SRC_JNI="$(dirname "$SRC_WRAP")/android/jni"
if [ -d "$SRC_JNI" ]; then
  cp -Rf "$SRC_JNI/." "$DEST_BRIDGE/"
  echo "  copied: android/jni (RTABMapApp + scene + tango-gl 등)"
else
  echo "  WARN: android/jni not found at $SRC_JNI"
fi

# Bridging header 생성 (원본 개명 + 경로 조정)
cat > "$DEST_BRIDGE/IndoorPathfinding-Bridging-Header.h" << 'HEADER'
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

#endif /* IndoorPathfinding_Bridging_Header_h */
HEADER

echo "[3/3] Bridge 파일 복사 완료"

echo ""
echo "=== 동기화 완료 ==="
echo "lib 파일 수: $(ls "$DEST_LIB"/*.a 2>/dev/null | wc -l | tr -d ' ') 개"
echo "총 크기: $(du -sh "$IOS_DIR/Vendor/RTABMap/lib" "$IOS_DIR/Vendor/RTABMap/include" 2>/dev/null | awk '{sum+=$1} END{print sum}') (approximate)"
