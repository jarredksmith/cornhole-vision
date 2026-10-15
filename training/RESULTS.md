# First model — trained 2026-10-14 on synthetic data only

`ios/CornholeVision/Models/BagDetector.mlpackage` (5.2 MB, YOLO11n, 416 px,
NMS baked in) was trained on **1,400 synthetic training / 200 validation
images** from `synth_gen.py --seed 42`, CPU only, 20 epochs planned (the
bundled export is from the best epoch available at packaging time). No real
photos were used, so expect it to be a *bootstrap*: it knows what a board,
a hole and a 6-inch cloth square look like from a phone, and it will get
noticeably better the first time you merge in 150–300 real labelled frames
(see README.md step 4).

Validation on held-out synthetic images (all 4 classes):

| epoch | precision | recall | mAP50 | mAP50-95 |
|---|---|---|---|---|
| 1 | 0.584 | 0.800 | 0.725 | 0.412 |
| 2 | 0.675 | 0.780 | 0.822 | 0.486 |
| 3 | 0.769 | 0.826 | 0.860 | 0.480 |
| 4 | 0.834 | 0.819 | 0.847 | 0.483 |
| 5 | 0.864 | 0.838 | 0.885 | 0.499 |
| 6 | 0.852 | 0.869 | 0.892 | 0.563 |
| 7 | 0.908 | 0.867 | 0.921 | 0.587 |
| 8 | 0.850 | 0.867 | 0.912 | 0.662 |
| 9 | 0.898 | 0.878 | 0.913 | 0.647 |
| 10 | 0.890 | 0.848 | 0.906 | 0.600 |
| 11 | 0.914 | 0.904 | 0.933 | 0.624 |
| 12 | 0.910 | 0.901 | 0.926 | 0.660 |

`synthetic_samples.jpg` shows what the generator produces (labels drawn:
green = bag, magenta = bag in hole, yellow = board, cyan = hole).
`val_predictions.jpg` shows the model's own detections on validation images.
The visible weakness is the one you'd expect: a black bag on a very dark or
saturated board. That's the case the real-photo pass is for.

Training settings are in `last_run_args.yaml`.
