#!/usr/bin/env python3
"""
YOLOv8 Core ML export 스크립트.
산출: yolov8{variant}.mlpackage        (--task detect, 기본)
     yolov8{variant}-seg.mlpackage    (--task segment)

요구:
  pip install ultralytics coremltools

사용:
  python3 export_yolo_coreml.py --variant s                  # yolov8s (detect, 기본)
  python3 export_yolo_coreml.py --variant n                  # yolov8n (detect, fallback용)
  python3 export_yolo_coreml.py --variant s --task segment   # yolov8s-seg (레거시)
  python3 export_yolo_coreml.py --variant n --task segment   # yolov8n-seg (레거시)

변경 이력:
  Sprint 10: --task detect|segment 추가. 기본값 detect.
             detect 모델은 nms=True 내장 → VNRecognizedObjectObservation 자동 파싱.
             segment 모델은 raw tensor — Vision 파서와 비호환.
"""

import argparse
import sys
import subprocess
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(
        description="YOLOv8 Core ML export (detect 또는 segment)"
    )
    parser.add_argument(
        "--variant",
        choices=["n", "s"],
        default="s",
        help="yolov8 variant: n (~6 MB) | s (~23 MB). 기본값 s.",
    )
    parser.add_argument(
        "--task",
        choices=["detect", "segment"],
        default="detect",
        help="detect: VNRecognizedObjectObservation 호환, nms 내장 (기본). "
             "segment: raw tensor, 수동 디코딩 필요.",
    )
    parser.add_argument(
        "--imgsz",
        type=int,
        default=640,
        help="입력 이미지 크기 (정사각형). 기본값 640.",
    )
    args = parser.parse_args()

    # 모델 파일명 결정
    if args.task == "detect":
        model_name = f"yolov8{args.variant}"          # yolov8s.pt
        output_suffix = ""                             # yolov8s.mlpackage
    else:
        model_name = f"yolov8{args.variant}-seg"      # yolov8s-seg.pt
        output_suffix = "-seg"                         # yolov8s-seg.mlpackage

    try:
        from ultralytics import YOLO
    except ImportError:
        print("[export] ultralytics 미설치. 설치 시도 중...")
        subprocess.check_call([sys.executable, "-m", "pip", "install", "ultralytics", "coremltools"])
        from ultralytics import YOLO  # type: ignore[import]

    print(f"[export] task={args.task}  모델: {model_name}.pt  imgsz={args.imgsz}")
    if args.task == "segment":
        print("[export] 주의: segment 모델은 Vision VNRecognizedObjectObservation과 비호환. "
              "iOS 앱에서 수동 디코딩 필요.")

    model = YOLO(f"{model_name}.pt")  # 자동 다운로드 (첫 실행 시 수 분 소요)

    # detect: nms=True 유효 (NMS 내장 → Vision 자동 파싱)
    # segment: nms=True는 무시되거나 경고 발생 (raw tensor)
    nms_flag = (args.task == "detect")
    print(f"[export] Core ML export 시작 (imgsz={args.imgsz}, nms={nms_flag})...")
    export_path = model.export(format="coreml", imgsz=args.imgsz, nms=nms_flag)

    result = Path(str(export_path))
    if result.exists():
        size_mb = sum(f.stat().st_size for f in result.rglob("*") if f.is_file()) / 1_048_576
        print(f"[export] 완료: {result} ({size_mb:.1f} MB)")
        expected_name = f"yolov8{args.variant}{output_suffix}.mlpackage"
        if result.name != expected_name:
            print(f"[export] 참고: 산출 파일명={result.name}, 예상={expected_name}")
        print(f"[export] 다음 단계: {result} → ios/IndoorPathfinding/Resources/Models/ 로 이동")
    else:
        print(f"[export] 경고: 예상 경로에 파일 없음 → {result}")
        sys.exit(1)


if __name__ == "__main__":
    main()
