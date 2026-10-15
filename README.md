# Cornhole Vision

An iPhone app that scores a cornhole game by watching the board. Prop the phone
up, throw. It finds the board on its own, learns the two bag colours from the
first throws, tracks every bag to where it ends up (on the board, in the hole,
off), applies cancellation scoring, and streams the game to a web page with a
live 3D board.

```
ios/        SwiftUI + AVFoundation + Vision + Core ML app (XcodeGen project)
worker/     Cloudflare Worker + Durable Object: realtime game rooms
web/        Follow page: scoreboard + Three.js 3D board, demo mode built in
training/   Synthetic data generator, YOLO training, Core ML export, real-data downloader
```

## 1. Run the app (10 minutes)

```bash
brew install xcodegen
cd ios
xcodegen generate
open CornholeVision.xcodeproj
```

In Xcode: select the CornholeVision target → Signing & Capabilities → pick your
team. Plug in an iPhone (iOS 17+), run. It only runs on a real device (camera).

**How to set up a game**

1. Prop the phone in landscape 5–8 ft to the side of the board, a little above
   board height, with the whole board in frame. A cooler, a chair seat, or a
   cheap tripod all work.
2. Tap *Start a game*. The app finds the board (yellow dashed outline), locks it
   (green), and says "Board locked — throw!". Keep the board empty until then.
3. Throw. The first bag's colour becomes team 1, the first different colour
   becomes team 2. Long-press a team card to rename it.
4. The round ends on its own when 8 bags have settled, or after 12 s of
   nothing moving (a countdown shows). Tap *End round* to end it sooner.
5. Solo phone: carry it to the other board; the app notices the motion and
   re-locks (or tap *Phone is in place*). Two phones: the second one joins
   with the 4-letter code and takes rounds at board 2.
6. Tap a bag marker to correct it: on board → off → in hole.

Everything works offline. Sync and the web page need steps 2–3 below.

## 2. Deploy the realtime backend (5 minutes)

```bash
cd worker
npm install
npx wrangler login
npx wrangler deploy        # prints https://cornhole-live.<you>.workers.dev
```

Paste that URL into `ios/CornholeVision/App/AppConfig.swift` → `syncBaseURL`
and into `web/index.html` → `WORKER_URL`. Free plan: if deploy refuses the
Durable Object, change `new_classes` to `new_sqlite_classes` in `wrangler.toml`.

## 3. Host the follow page

`web/index.html` is a single file. Put it on Cloudflare Pages, GitHub Pages, or
anywhere static (it needs the Worker URL from step 2 for live games). Then set
`followBaseURL` in AppConfig so the app's *Share live link* button produces
`https://your-site/?game=CODE`. Open it with `?demo=1` to watch a simulated game.

## 4. Train / improve the detector

The app ships with a model-free colour detector (background subtraction on a
top-down "board map"), which is what scores games out of the box. A learned
YOLO detector is layered on top when `BagDetector.mlpackage` is present in
`ios/CornholeVision/Models/`. It helps with bags that match the board colour,
bags hanging in the hole, and bags partly covered by a hand or a shadow.

```bash
cd training
pip install ultralytics pillow numpy          # torch comes with ultralytics
python3 synth_gen.py --out dataset --train 1500 --val 250     # ~3 min, no GPU needed
python3 train.py --data dataset/data.yaml --epochs 40 --imgsz 480 --device mps   # Apple Silicon
# -> ios/CornholeVision/Models/BagDetector.mlpackage (then re-run xcodegen or drag it into Xcode)
```

`BagDetector.mlpackage` in this repo was trained here on 1,600 synthetic
images (see `training/RESULTS.md`). To make it good on *real* boards:

1. Get a free Roboflow key and run `python3 download_real.py` — it pulls the
   public **Cornhole Referee** dataset (394 photos: board, hole, red/blue bags,
   bags in hole) and Ryan McLean's **CornholeTrackerv4** (261 photos), and maps
   them to this project's classes.
2. `python3 merge_datasets.py dataset dataset_real/* --out dataset_merged`
3. Re-run `train.py` on `dataset_merged/data.yaml`.
4. Best of all: play a few games with the app, then photograph the board from
   the phone's position every round. 200 labelled frames of *your* boards and
   bags beat 10,000 synthetic ones. Label in Roboflow (free) using the same
   four classes: `bag`, `bag_in_hole`, `board`, `hole`.

## How it works

```
camera frame (1280x720, 30 fps, sensor orientation)
   │
   ├─ Board lock (once): VNDetectRectanglesRequest → stable for 8 frames →
   │     try the 4 corner orderings, warp each, pick the one where a dark
   │     6" disc sits 9" from the back edge (the hole) → homography locked.
   │
   ├─ Every frame: CIPerspectiveCorrection → 192x384 top-down board map (8 px/in)
   │     ├─ colour detector: |chroma − reference| or intensity ratio → mask → erode →
   │     │     connected components → k-means split for touching bags → blobs in inches
   │     └─ Core ML detector (optional, every 2nd frame): YOLO on the full frame →
   │           box centres mapped through the homography → merged with blobs
   │
   ├─ Team colours: first blob = team 0, first clearly different colour = team 1
   │     (chromaticity distance, so shadows don't split a team in two)
   │
   ├─ Tracker: nearest-neighbour matching, velocity, "resting" after 10 still frames.
   │     A track that vanishes near the hole → in hole (3). Vanishes at an edge → off (0).
   │     Still on the board → woody (1). Established bags that vanish mid-board are
   │     treated as occluded for 3 s before being dropped.
   │
   └─ Game: cancellation scoring per round, first to 21 (no bust), solo or two-phone.
         Live state (bag positions in board inches) → WebSocket → Durable Object → viewers.
```

Board coordinates everywhere: x 0–24 in across, y 0–48 in along, y = 0 at the
hole end, hole centre (12, 9), radius 3.

## Known limits (v0.1)

- A bag resting on the board *and* touching the ground counts as on-board;
  the app can't see the ground contact. Tap the marker to set it to off.
- Bags that miss the board entirely are never seen, which is fine for scoring
  (they're 0) but means the 8-bag auto-end waits for the 12 s quiet timer.
- Black bags on a very dark board, or tan bags on bare plywood, are the hard
  case for the colour detector; the trained model is there for exactly this.
- Night games under one floodlight work; a board half in hard sunlight and
  half in shadow confuses the background model until it re-captures between
  rounds (it re-captures automatically whenever the board is empty for 1 s).
- Two-phone mode trusts the host's team colours; if the second phone sees them
  very differently (different light), rename/verify on the first round.

## Prior art and data sources

- Roboflow Universe "Cornhole Referee" (394 images, 6 classes) and Ryan
  McLean "cornhole" / "CornholeTrackerv4" datasets — `training/download_real.py`.
- Roboflow blog, *Automate Game Scorekeeping with Vision AI* — overhead-camera
  cornhole scorer with a workflow for zone mapping.
- Eshimkanov & Derbinsky 2017, *Automatic Score Keeper (ASK) for Cornhole via
  Computer Vision* (AAAS), part of the AAAI 2017 paper *Cornhole: A
  Widely-Accessible AI Robotics Task*, which released a 198-image annotated set.
- University of Akron honors project *Automatic Scoring Cornhole Board System*
  (cameras above/below the board).
- ACL board spec: 2 x 4 ft ±1/4 in, 6 in hole ±1/8 in centred 9 in from the back
  edge, front edge 3–4 in high, back 12 in.
