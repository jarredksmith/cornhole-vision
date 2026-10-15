#!/usr/bin/env python3
"""
Pull real cornhole photos from public Roboflow Universe datasets and merge
them into the synthetic dataset's class scheme (bag, bag_in_hole, board, hole).

Needs a free Roboflow account + API key:  export ROBOFLOW_API_KEY=xxxx
  pip install roboflow
  python3 download_real.py --out dataset_real
  python3 merge_datasets.py dataset dataset_real --out dataset_merged

Datasets (found Oct 2026 on universe.roboflow.com — check licences before
shipping a model trained on them):

  cornhole-referee / cornhole-referee   394 imgs  board, hole, red/blue bag, red/blue bag in hole
  ryan-mclean / cornhole               ~1100 imgs instance segmentation of bags
  ryan-mclean / cornholetrackerv4       261 imgs  object detection

If a workspace/project slug has changed, open the dataset page on Universe,
click "Download Dataset" -> "show download code" and paste the slugs below.
"""
import argparse
import os
import sys

SOURCES = [
    # (workspace, project, version, class-name mapping -> ours)
    ("cornhole-referee", "cornhole-referee", None, {
        "board": "board", "hole": "hole",
        "blue-bean-bag": "bag", "red-bean-bag": "bag",
        "blue-bean-bag-in-hole": "bag_in_hole", "red-bean-bag-in-hole": "bag_in_hole",
    }),
    ("ryan-mclean", "cornholetrackerv4", None, {"bag": "bag", "bags": "bag", "board": "board", "hole": "hole"}),
]
OURS = ["bag", "bag_in_hole", "board", "hole"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="dataset_real")
    args = ap.parse_args()
    key = os.environ.get("ROBOFLOW_API_KEY")
    if not key:
        sys.exit("set ROBOFLOW_API_KEY (free at roboflow.com -> settings -> API)")
    try:
        from roboflow import Roboflow
    except ImportError:
        sys.exit("pip install roboflow")
    rf = Roboflow(api_key=key)
    os.makedirs(args.out, exist_ok=True)
    for ws, proj, ver, mapping in SOURCES:
        try:
            project = rf.workspace(ws).project(proj)
            version = project.version(ver) if ver else project.versions()[0]
            ds = version.download("yolov8", location=os.path.join(args.out, proj))
            print("downloaded", ds.location)
            remap(ds.location, mapping)
        except Exception as e:  # noqa: BLE001
            print(f"!! could not download {ws}/{proj}: {e}")
    print("done. merge with: python3 merge_datasets.py dataset", args.out + "/*", "--out dataset_merged")


def remap(root, mapping):
    """Rewrite YOLO label class ids from the source dataset's names to ours."""
    import yaml
    with open(os.path.join(root, "data.yaml")) as f:
        names = yaml.safe_load(f)["names"]
    if isinstance(names, dict):
        names = [names[k] for k in sorted(names)]
    idmap = {}
    for i, n in enumerate(names):
        if n in mapping:
            idmap[i] = OURS.index(mapping[n])
    for split in ("train", "valid", "test"):
        ldir = os.path.join(root, split, "labels")
        if not os.path.isdir(ldir):
            continue
        for fn in os.listdir(ldir):
            p = os.path.join(ldir, fn)
            out = []
            for line in open(p):
                parts = line.split()
                if not parts:
                    continue
                cid = int(parts[0])
                if cid in idmap:
                    out.append(" ".join([str(idmap[cid])] + parts[1:5]))
            with open(p, "w") as f:
                f.write("\n".join(out) + ("\n" if out else ""))
    with open(os.path.join(root, "data.yaml"), "w") as f:
        f.write("path: %s\ntrain: train/images\nval: valid/images\nnames:\n" % os.path.abspath(root)
                + "".join(f"  {i}: {c}\n" for i, c in enumerate(OURS)))
    print("remapped", root, idmap)


if __name__ == "__main__":
    main()
