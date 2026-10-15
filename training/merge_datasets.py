#!/usr/bin/env python3
"""Merge several YOLO datasets (already using our 4-class scheme) into one.

  python3 merge_datasets.py dataset dataset_real/cornhole-referee --out dataset_merged
"""
import argparse
import glob
import os
import shutil

OURS = ["bag", "bag_in_hole", "board", "hole"]


def copy_split(src_imgs, src_lbls, dst_imgs, dst_lbls, prefix):
    os.makedirs(dst_imgs, exist_ok=True)
    os.makedirs(dst_lbls, exist_ok=True)
    n = 0
    for img in glob.glob(os.path.join(src_imgs, "*")):
        if not img.lower().endswith((".jpg", ".jpeg", ".png")):
            continue
        base = os.path.splitext(os.path.basename(img))[0]
        lbl = os.path.join(src_lbls, base + ".txt")
        shutil.copy(img, os.path.join(dst_imgs, f"{prefix}_{os.path.basename(img)}"))
        if os.path.exists(lbl):
            shutil.copy(lbl, os.path.join(dst_lbls, f"{prefix}_{base}.txt"))
        n += 1
    return n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sources", nargs="+")
    ap.add_argument("--out", default="dataset_merged")
    args = ap.parse_args()
    for i, src in enumerate(args.sources):
        for split_in, split_out in (("train", "train"), ("val", "val"), ("valid", "val")):
            for imgs, lbls in ((os.path.join(src, "images", split_in), os.path.join(src, "labels", split_in)),
                               (os.path.join(src, split_in, "images"), os.path.join(src, split_in, "labels"))):
                if os.path.isdir(imgs):
                    n = copy_split(imgs, lbls, os.path.join(args.out, "images", split_out),
                                   os.path.join(args.out, "labels", split_out), f"s{i}")
                    print(f"{src} {split_in}: {n} images")
    with open(os.path.join(args.out, "data.yaml"), "w") as f:
        f.write(f"path: {os.path.abspath(args.out)}\ntrain: images/train\nval: images/val\nnames:\n"
                + "".join(f"  {i}: {c}\n" for i, c in enumerate(OURS)))
    print("wrote", os.path.join(args.out, "data.yaml"))


if __name__ == "__main__":
    main()
