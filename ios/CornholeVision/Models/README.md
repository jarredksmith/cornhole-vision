Drop `BagDetector.mlpackage` here (training/train.py copies it automatically).
Xcode compiles it into the app bundle; the app finds it by name at runtime and
falls back to the colour detector if it is absent.
