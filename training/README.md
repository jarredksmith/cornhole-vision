# Training the bag detector

Four classes: `bag`, `bag_in_hole`, `board`, `hole`. The app only needs
`bag` / `bag_in_hole` (board and hole are found geometrically), but training
the extra two makes the detector much better at ignoring everything else.

| script               | what it does                                                       |
|----------------------|--------------------------------------------------------------------|
| `synth_gen.py`       | Procedural boards, bags, lighting, perspective → YOLO + Create ML labels |
| `download_real.py`   | Pulls public cornhole photo sets from Roboflow Universe (needs free API key) |
| `merge_datasets.py`  | Combines any number of YOLO datasets in this class scheme           |
| `train.py`           | YOLO11n training + Core ML export (`BagDetector.mlpackage`)        |

## Quick start (Apple Silicon Mac, ~25 min)

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install ultralytics pillow numpy "coremltools>=9" "numpy<=2.3.5"
python3 synth_gen.py --out dataset --train 1500 --val 250
python3 train.py --data dataset/data.yaml --epochs 40 --imgsz 480 --device mps
```

`train.py` copies the exported model into `../ios/CornholeVision/Models/`.
Re-run `xcodegen generate` (or drag the .mlpackage into the Xcode project).

## Core ML export notes

- Export needs a torch version coremltools has been tested with (2.7.x at
  the time of writing). If `export` fails deep inside `coremltools ... ops.py`,
  pin `pip install torch==2.7.0 torchvision==0.22.0` in a separate venv and run
  `python3 train.py --export-only --weights runs/detect/cornhole/weights/best.pt`.
- `nms=True` bakes non-max suppression into the model so Vision hands the app
  `VNRecognizedObjectObservation`s with labels and confidences — no decoding code.
- Input size 416 or 480. Bigger is sharper on far boards but slower; the app
  runs the model every other frame on the Neural Engine.

## Create ML instead of YOLO

`synth_gen.py` also writes `images/{train,val}/annotations.json` in Create ML's
object-detection format. Open Create ML → Object Detection → drag the `images/train`
folder in. Export the result as `BagDetector.mlmodel` into
`../ios/CornholeVision/Models/`. Create ML's output also works with the app's
Vision request as-is.

## Getting real photos (the thing that will matter most)

The synthetic set teaches the shape of the problem; real photos teach the
lighting, fabric, worn boards and phone lens. Best plan:

1. Run the app. Every round, take one still from the phone's position
   (the app's point of view) — before bags are picked up.
2. Upload to Roboflow (free), label with the four classes, export as
   "YOLOv8" format, and merge: `python3 merge_datasets.py dataset my_photos --out dataset_merged`.
3. 150–300 real frames, mixed with the synthetic set, is usually enough.
