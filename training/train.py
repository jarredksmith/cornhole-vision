#!/usr/bin/env python3
"""
Train the bag/board/hole detector and export it to Core ML.

  python3 train.py --data dataset/data.yaml --epochs 40 --imgsz 480
  python3 train.py --data dataset/data.yaml --export-only --weights runs/detect/cornhole/weights/best.pt

The exported .mlpackage goes next to the weights and is copied to
../ios/CornholeVision/Models/BagDetector.mlpackage so Xcode picks it up.
The iOS app loads it by name at runtime and falls back to the colour-blob
detector if the file is missing, so a missing/bad model never breaks scoring.
"""
import argparse
import os
import shutil
import sys

from ultralytics import YOLO

HERE = os.path.dirname(os.path.abspath(__file__))
IOS_MODEL_DIR = os.path.join(HERE, "..", "ios", "CornholeVision", "Models")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default=os.path.join(HERE, "dataset", "data.yaml"))
    ap.add_argument("--model", default="yolo11n.pt", help="base weights (yolo11n.pt / yolov8n.pt)")
    ap.add_argument("--epochs", type=int, default=40)
    ap.add_argument("--imgsz", type=int, default=480)
    ap.add_argument("--batch", type=int, default=16)
    ap.add_argument("--device", default="cpu", help="cpu, 0 (CUDA), or mps (Apple Silicon)")
    ap.add_argument("--name", default="cornhole")
    ap.add_argument("--weights", default=None, help="skip training, export these weights")
    ap.add_argument("--export-only", action="store_true")
    ap.add_argument("--no-export", action="store_true")
    args = ap.parse_args()

    weights = args.weights
    if not args.export_only:
        model = YOLO(args.model)
        results = model.train(
            data=args.data, epochs=args.epochs, imgsz=args.imgsz, batch=args.batch,
            device=args.device, name=args.name, exist_ok=True, workers=2,
            # augmentation tuned for "phone on the ground next to a board"
            degrees=15, scale=0.4, perspective=0.0005, fliplr=0.5, flipud=0.2,
            hsv_h=0.03, hsv_s=0.6, hsv_v=0.5, mosaic=1.0, close_mosaic=5,
            patience=15, verbose=True,
        )
        weights = os.path.join(results.save_dir, "weights", "best.pt")
        print("best weights:", weights)

    if args.no_export:
        return
    if not weights or not os.path.exists(weights):
        sys.exit(f"weights not found: {weights}")

    model = YOLO(weights)
    # nms=True bakes non-max suppression into the Core ML pipeline so Vision
    # returns VNRecognizedObjectObservation with labels + confidences directly.
    try:
        out = model.export(format="coreml", imgsz=args.imgsz, nms=True, half=False)
    except Exception as e:  # noqa: BLE001
        sys.exit(
            f"Core ML export failed: {e}\n\n"
            "coremltools only supports torch versions it has been tested with. In a fresh venv:\n"
            "  pip install torch==2.7.0 torchvision==0.22.0 ultralytics 'coremltools>=9' 'numpy<=2.3.5'\n"
            f"  python3 train.py --export-only --weights {weights}\n"
        )
    print("exported:", out)
    os.makedirs(IOS_MODEL_DIR, exist_ok=True)
    dst = os.path.join(IOS_MODEL_DIR, "BagDetector.mlpackage")
    if os.path.isdir(dst):
        shutil.rmtree(dst)
    if os.path.isdir(out):
        shutil.copytree(out, dst)
    else:
        shutil.copy(out, dst)
    print("copied to", dst)


if __name__ == "__main__":
    main()
