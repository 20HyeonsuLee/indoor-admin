"""
YOLO-World open-vocabulary detection 모델을 CoreML로 export.

Sprint 12: 기획서 4 클래스 (door/stairs/sign/floor) + 일상 객체를 open-vocab
prompt로 지정해서 export. COCO 기본 80개와 달리 door/stairs 직접 감지 가능.

사용:
    python3 export_yolo_world_coreml.py [--variant s|m]

산출:
    yolov8{variant}-world.mlpackage → ios/IndoorPathfinding/Resources/Models/ 수동 이동
"""
import argparse
from ultralytics import YOLO

# Sprint 12 프롬프트 — 기획서 필수 4 + 일상 객체 16
CLASSES = [
    # Sprint 12 hotfix: refrigerator 제거(유리문 오분류 주범) + door variation 추가
    # Sprint 14: elevator, escalator 추가 (건물 이동 수단)
    # 기획서 명세 + 이동 수단
    "door", "glass door", "doorway", "entrance",
    "stairs", "escalator", "elevator",
    "sign", "floor",
    # 일상 실내 객체 (refrigerator 제외)
    "person", "chair", "table", "cup", "bottle",
    "laptop", "tv", "monitor", "keyboard", "mouse",
    "book", "bag", "window", "plant", "couch",
]


def main():
    parser = argparse.ArgumentParser(description="YOLO-World → CoreML export")
    parser.add_argument("--variant", choices=["s", "m"], default="s",
                        help="s: yolov8s-worldv2 (23MB). m: yolov8m-worldv2 (52MB).")
    parser.add_argument("--imgsz", type=int, default=640, help="입력 크기")
    args = parser.parse_args()

    model_name = f"yolov8{args.variant}-worldv2.pt"
    print(f"[export] 모델 로드: {model_name}")
    model = YOLO(model_name)  # 자동 다운로드

    print(f"[export] set_classes({len(CLASSES)}) 개 프롬프트 지정")
    for c in CLASSES:
        print(f"  - {c}")
    model.set_classes(CLASSES)

    print(f"[export] CoreML export 시작 (imgsz={args.imgsz})")
    out = model.export(format="coreml", imgsz=args.imgsz, nms=True)
    print(f"[export] 완료: {out}")
    print(f"[export] 다음 단계: {out} → ios/IndoorPathfinding/Resources/Models/ 로 이동")


if __name__ == "__main__":
    main()
