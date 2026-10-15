#!/usr/bin/env python3
"""
Synthetic cornhole dataset generator.

Renders regulation boards (24x48 in, 6 in hole centred 9 in from the top)
seen from random phone positions, with 0-8 bags in two team colours, bags
hanging in the hole, stacked bags, off-board bags, occluders, lighting and
camera noise. Writes YOLO labels + a Create ML annotations.json.

Classes:
  0 bag          any bag that is NOT in the hole (on board, on ground, in flight)
  1 bag_in_hole  a bag hanging on the lip / partially through the hole
  2 board        the whole board quadrilateral
  3 hole         the 6 in hole

Usage:
  python3 synth_gen.py --out dataset --train 1200 --val 200 --seed 1
"""
import argparse
import json
import math
import os
import random

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageEnhance

CLASSES = ["bag", "bag_in_hole", "board", "hole"]

BOARD_W_IN, BOARD_L_IN = 24.0, 48.0
HOLE_CX_IN, HOLE_CY_IN, HOLE_R_IN = 12.0, 9.0, 3.0
BAG_IN = 6.0
PPI = 10  # board render resolution, px per inch

BAG_COLORS = {
    "red": (200, 30, 35), "blue": (30, 70, 190), "black": (25, 25, 28),
    "white": (235, 235, 230), "green": (30, 140, 60), "yellow": (240, 210, 40),
    "orange": (240, 120, 30), "purple": (110, 45, 160), "gray": (130, 130, 135),
    "teal": (20, 150, 150), "navy": (20, 35, 90), "maroon": (120, 25, 40),
    "pink": (235, 90, 160), "lime": (150, 220, 50), "royal": (40, 110, 230),
}

# ----------------------------------------------------------------------------
# helpers
# ----------------------------------------------------------------------------

def find_coeffs(dst, src):
    """PIL perspective coefficients mapping output(dst) px -> input(src) px."""
    m = []
    for (x, y), (u, v) in zip(dst, src):
        m.append([x, y, 1, 0, 0, 0, -u * x, -u * y])
        m.append([0, 0, 0, x, y, 1, -v * x, -v * y])
    A = np.array(m, dtype=np.float64)
    B = np.array(src, dtype=np.float64).reshape(8)
    return np.linalg.solve(A, B)


def homography(src, dst):
    """3x3 H with dst ~ H @ src (src/dst: 4 point pairs)."""
    c = find_coeffs(src, dst)  # maps src -> dst when called this way
    return np.array([[c[0], c[1], c[2]], [c[3], c[4], c[5]], [c[6], c[7], 1.0]])


def apply_h(H, pts):
    out = []
    for x, y in pts:
        v = H @ np.array([x, y, 1.0])
        out.append((v[0] / v[2], v[1] / v[2]))
    return out


def noise_img(w, h, scale, lo, hi, rng):
    """Low-frequency noise image in [lo,hi] as float array (h,w)."""
    sw, sh = max(2, int(w / scale)), max(2, int(h / scale))
    small = rng.random((sh, sw)).astype(np.float32)
    im = Image.fromarray((small * 255).astype(np.uint8)).resize((w, h), Image.BILINEAR)
    a = np.asarray(im).astype(np.float32) / 255.0
    return lo + a * (hi - lo)


def jitter_color(c, amt, rng):
    return tuple(int(np.clip(v + rng.integers(-amt, amt + 1), 0, 255)) for v in c)


def rounded_rect_mask(w, h, r):
    m = Image.new("L", (w, h), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, w - 1, h - 1], radius=r, fill=255)
    return m


# ----------------------------------------------------------------------------
# backgrounds
# ----------------------------------------------------------------------------

def make_background(w, h, rng):
    kind = rng.choice(["grass", "concrete", "deck", "dirt", "gym", "carpet", "gravel"])
    if kind == "grass":
        base = np.array([rng.integers(40, 90), rng.integers(110, 170), rng.integers(30, 70)])
    elif kind == "concrete":
        g = rng.integers(120, 200)
        base = np.array([g, g, g + rng.integers(-5, 10)])
    elif kind == "deck":
        base = np.array([rng.integers(120, 170), rng.integers(80, 120), rng.integers(50, 80)])
    elif kind == "dirt":
        base = np.array([rng.integers(110, 150), rng.integers(85, 120), rng.integers(50, 80)])
    elif kind == "gym":
        base = np.array([rng.integers(180, 220), rng.integers(140, 180), rng.integers(80, 120)])
    elif kind == "carpet":
        base = np.array([rng.integers(60, 140), rng.integers(60, 140), rng.integers(60, 140)])
    else:
        g = rng.integers(140, 190)
        base = np.array([g, g - 5, g - 15])
    fine = noise_img(w, h, 2, 0.75, 1.25, rng)
    coarse = noise_img(w, h, 60, 0.8, 1.2, rng)
    arr = np.zeros((h, w, 3), np.float32)
    for i in range(3):
        arr[:, :, i] = base[i] * fine * coarse
    img = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8))
    d = ImageDraw.Draw(img)
    if kind in ("deck", "gym"):
        pitch = rng.integers(25, 60)
        off = rng.integers(0, pitch)
        ang = rng.uniform(-0.4, 0.4)
        for x in range(-h, w + h, pitch):
            x0, x1 = x + off, x + off + int(ang * h)
            d.line([(x0, 0), (x1, h)], fill=tuple(int(v * 0.75) for v in base), width=2)
    # random clutter: cups, shoes, shadows, other bags off in the distance
    for _ in range(rng.integers(0, 6)):
        cx, cy = rng.integers(0, w), rng.integers(0, h)
        rw, rh = rng.integers(8, 60), rng.integers(8, 60)
        col = tuple(int(v) for v in rng.integers(0, 255, 3))
        if rng.random() < 0.5:
            d.ellipse([cx, cy, cx + rw, cy + rh], fill=col)
        else:
            d.rectangle([cx, cy, cx + rw, cy + rh], fill=col)
    return img


# ----------------------------------------------------------------------------
# board + bags rendered in board space (top-down), then warped
# ----------------------------------------------------------------------------

def make_board_surface(rng):
    w, h = int(BOARD_W_IN * PPI), int(BOARD_L_IN * PPI)
    style = rng.choice(["wood", "wood", "paint", "print", "stained"])
    if style in ("wood", "stained"):
        base = np.array([rng.integers(170, 225), rng.integers(130, 185), rng.integers(80, 130)])
        if style == "stained":
            base = (base * rng.uniform(0.45, 0.8)).astype(int)
        grain = noise_img(w, h, 3, 0.9, 1.1, rng) * noise_img(w, h, 40, 0.92, 1.08, rng)
        arr = np.zeros((h, w, 3), np.float32)
        for i in range(3):
            arr[:, :, i] = base[i] * grain
        # grain lines along the length
        for x in range(0, w, rng.integers(6, 14)):
            arr[:, x:x + 1, :] *= rng.uniform(0.9, 1.0)
        img = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8))
    elif style == "paint":
        col = tuple(int(v) for v in rng.integers(20, 240, 3))
        img = Image.new("RGB", (w, h), col)
        arr = np.asarray(img).astype(np.float32) * noise_img(w, h, 2, 0.93, 1.07, rng)[..., None]
        img = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8))
    else:  # printed graphics: stripes, blocks, pseudo-logo
        col = tuple(int(v) for v in rng.integers(20, 240, 3))
        img = Image.new("RGB", (w, h), col)
        d = ImageDraw.Draw(img)
        for _ in range(rng.integers(2, 8)):
            c2 = tuple(int(v) for v in rng.integers(0, 255, 3))
            x0, y0 = rng.integers(0, w), rng.integers(0, h)
            x1, y1 = rng.integers(0, w), rng.integers(0, h)
            if rng.random() < 0.5:
                d.rectangle([min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1)], fill=c2)
            else:
                d.ellipse([min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1)], fill=c2)
        # make sure the hole area is not a wild colour: no-op, hole drawn later
    d = ImageDraw.Draw(img)
    # subtle edge darkening (board edges / bevel)
    d.rectangle([0, 0, w - 1, h - 1], outline=(40, 30, 20), width=3)
    return img


def draw_hole(board, rng):
    d = ImageDraw.Draw(board, "RGBA")
    cx, cy, r = HOLE_CX_IN * PPI, HOLE_CY_IN * PPI, HOLE_R_IN * PPI
    dark = rng.integers(5, 45)
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(dark, dark, dark, 255))
    # inner rim highlight on one side
    d.arc([cx - r, cy - r, cx + r, cy + r], start=rng.integers(0, 360), end=rng.integers(0, 360),
          fill=(dark + 40, dark + 35, dark + 30, 255), width=2)


def make_bag_sprite(color, rng):
    """RGBA bag sprite ~6x6 in with fabric texture, slight deformation."""
    sx, sy = rng.uniform(0.85, 1.15), rng.uniform(0.85, 1.15)
    w, h = int(BAG_IN * PPI * sx), int(BAG_IN * PPI * sy)
    tex = noise_img(w, h, 1.5, 0.85, 1.15, rng) * noise_img(w, h, 12, 0.9, 1.1, rng)
    arr = np.zeros((h, w, 3), np.float32)
    col = jitter_color(color, 25, rng)
    for i in range(3):
        arr[:, :, i] = col[i] * tex
    # soft shading across the bag (it bulges)
    yy, xx = np.mgrid[0:h, 0:w]
    bulge = 1.0 - 0.35 * (((xx - w / 2) / (w / 2)) ** 2 + ((yy - h / 2) / (h / 2)) ** 2)
    arr *= bulge[..., None]
    rgb = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8))
    mask = rounded_rect_mask(w, h, int(min(w, h) * rng.uniform(0.12, 0.3)))
    # occasional logo
    if rng.random() < 0.4:
        d = ImageDraw.Draw(rgb)
        lc = tuple(int(v) for v in rng.integers(0, 255, 3))
        lw, lh = rng.integers(w // 5, w // 2), rng.integers(h // 6, h // 2)
        lx, ly = rng.integers(0, w - lw), rng.integers(0, h - lh)
        if rng.random() < 0.5:
            d.ellipse([lx, ly, lx + lw, ly + lh], fill=lc)
        else:
            d.rectangle([lx, ly, lx + lw, ly + lh], fill=lc)
    # stitched edge
    d = ImageDraw.Draw(rgb)
    d.rounded_rectangle([1, 1, w - 2, h - 2], radius=int(min(w, h) * 0.2),
                        outline=tuple(int(c * 0.7) for c in col), width=1)
    sprite = rgb.convert("RGBA")
    sprite.putalpha(mask)
    ang = rng.uniform(0, 360)
    sprite = sprite.rotate(ang, resample=Image.BICUBIC, expand=True)
    return sprite


def paste_with_shadow(layer, sprite, cx, cy, rng, shadow=True):
    w, h = sprite.size
    x0, y0 = int(cx - w / 2), int(cy - h / 2)
    if shadow:
        sh = Image.new("RGBA", layer.size, (0, 0, 0, 0))
        shadow_sprite = Image.new("RGBA", sprite.size, (0, 0, 0, 0))
        a = sprite.split()[3].point(lambda v: int(v * 0.55))
        shadow_sprite.putalpha(a)
        off = (rng.integers(-5, 6), rng.integers(2, 8))
        sh.paste(shadow_sprite, (x0 + off[0], y0 + off[1]), shadow_sprite)
        sh = sh.filter(ImageFilter.GaussianBlur(3))
        layer.alpha_composite(sh)
    _safe_composite(layer, sprite, x0, y0)
    return (x0, y0, x0 + w, y0 + h)


def _safe_composite(layer, sprite, x0, y0):
    """alpha_composite with out-of-bounds handling."""
    tmp = Image.new("RGBA", layer.size, (0, 0, 0, 0))
    tmp.paste(sprite, (x0, y0), sprite)
    layer.alpha_composite(tmp)


# ----------------------------------------------------------------------------
# scene generation
# ----------------------------------------------------------------------------

def random_board_quad(W, H, rng):
    """A plausible image-space quad for the board (TL, TR, BR, BL in board order:
    board x along width (0..24), board y along length (0..48, hole end at y=0))."""
    # Camera: off to the side, slightly elevated => trapezoid-ish quad with rotation.
    long_px = rng.uniform(0.45, 1.05) * max(W, H)
    aspect = rng.uniform(0.25, 0.6)  # width/length as seen (foreshortened)
    wpx = long_px * aspect
    # perspective: far short edge shrinks
    k = rng.uniform(0.55, 1.0)
    # local coords (centred): x = width axis, y = length axis
    tl = (-wpx / 2 * k, -long_px / 2)
    tr = (wpx / 2 * k, -long_px / 2)
    br = (wpx / 2, long_px / 2)
    bl = (-wpx / 2, long_px / 2)
    pts = [tl, tr, br, bl]
    # keystone along the length too (camera at one end-ish)
    shear = rng.uniform(-0.25, 0.25)
    pts = [(x + shear * y, y) for x, y in pts]
    ang = rng.uniform(0, 2 * math.pi)
    ca, sa = math.cos(ang), math.sin(ang)
    pts = [(x * ca - y * sa, x * sa + y * ca) for x, y in pts]
    # random jitter so edges are not perfectly straight-paired
    pts = [(x + rng.uniform(-4, 4), y + rng.uniform(-4, 4)) for x, y in pts]
    xs, ys = [p[0] for p in pts], [p[1] for p in pts]
    bw, bh = max(xs) - min(xs), max(ys) - min(ys)
    scale = min(1.0, (W * 0.95) / bw, (H * 0.95) / bh)
    pts = [(x * scale, y * scale) for x, y in pts]
    xs, ys = [p[0] for p in pts], [p[1] for p in pts]
    cx = rng.uniform(-min(xs), W - max(xs))
    cy = rng.uniform(-min(ys), H - max(ys))
    return [(x + cx, y + cy) for x, y in pts]


def generate_scene(W, H, rng):
    bg = make_background(W, H, rng).convert("RGBA")
    board = make_board_surface(rng).convert("RGBA")
    draw_hole(board, rng)
    bw, bh = board.size

    team_names = rng.choice(list(BAG_COLORS.keys()), size=2, replace=False)
    team_cols = [BAG_COLORS[n] for n in team_names]

    layer = Image.new("RGBA", board.size, (0, 0, 0, 0))
    labels = []  # (cls, quad in board px)

    n_bags = int(rng.choice([0, 1, 2, 3, 4, 4, 5, 6, 7, 8]))
    placed = []
    for i in range(n_bags):
        col = team_cols[i % 2] if rng.random() < 0.8 else team_cols[rng.integers(0, 2)]
        sprite = make_bag_sprite(col, rng)
        state_roll = rng.random()
        if state_roll < 0.18:
            # hanging in the hole
            ang = rng.uniform(0, 2 * math.pi)
            r = rng.uniform(1.0, 3.2) * PPI
            cx = HOLE_CX_IN * PPI + math.cos(ang) * r
            cy = HOLE_CY_IN * PPI + math.sin(ang) * r
            box = paste_with_shadow(layer, sprite, cx, cy, rng, shadow=False)
            placed.append((1, box))
        elif state_roll < 0.28 and placed:
            # stacked on another bag
            prev = placed[rng.integers(0, len(placed))][1]
            cx = (prev[0] + prev[2]) / 2 + rng.uniform(-2, 2) * PPI
            cy = (prev[1] + prev[3]) / 2 + rng.uniform(-2, 2) * PPI
            box = paste_with_shadow(layer, sprite, cx, cy, rng)
            placed.append((0, box))
        else:
            # anywhere on the board, can hang over the edge a little
            cx = rng.uniform(-1.5, BOARD_W_IN + 1.5) * PPI
            cy = rng.uniform(-1.5, BOARD_L_IN + 1.5) * PPI
            box = paste_with_shadow(layer, sprite, cx, cy, rng)
            placed.append((0, box))

    # the hole occludes whatever fell into it: re-draw a dark disc on top at ~85%
    d = ImageDraw.Draw(layer, "RGBA")
    cx, cy, r = HOLE_CX_IN * PPI, HOLE_CY_IN * PPI, HOLE_R_IN * PPI * 0.92
    dark = rng.integers(5, 40)
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(dark, dark, dark, 215))

    board.alpha_composite(layer)

    # warp board into the scene
    quad = random_board_quad(W, H, rng)
    src = [(0, 0), (bw, 0), (bw, bh), (0, bh)]
    coeffs = find_coeffs(quad, src)
    Hb = homography(src, quad)
    warped = board.transform((W, H), Image.PERSPECTIVE, coeffs, Image.BICUBIC)
    # soft shadow under the board
    sh = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(sh).polygon([(x + 6, y + 10) for x, y in quad], fill=(0, 0, 0, 120))
    sh = sh.filter(ImageFilter.GaussianBlur(8))
    bg.alpha_composite(sh)
    # board thickness / legs: extrude the two lowest edges downward in image space
    side = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    sd = ImageDraw.Draw(side)
    depth = rng.integers(5, 22)
    edge_col = tuple(int(v) for v in rng.integers(40, 120, 3)) + (255,)
    order = sorted(range(4), key=lambda i: quad[i][1], reverse=True)  # lowest y first
    for a, b in ((order[0], order[1]), (order[0], order[2])):
        p, q = quad[a], quad[b]
        sd.polygon([p, q, (q[0], q[1] + depth), (p[0], p[1] + depth)], fill=edge_col)
    bg.alpha_composite(side)
    bg.alpha_composite(warped)

    boxes = []  # (cls, x0,y0,x1,y1) in image px

    def quad_to_box(pts):
        xs, ys = [p[0] for p in pts], [p[1] for p in pts]
        return (max(0, min(xs)), max(0, min(ys)), min(W, max(xs)), min(H, max(ys)))

    boxes.append((2,) + quad_to_box(quad))
    hole_pts = [(HOLE_CX_IN * PPI + HOLE_R_IN * PPI * math.cos(t),
                 HOLE_CY_IN * PPI + HOLE_R_IN * PPI * math.sin(t)) for t in np.linspace(0, 2 * math.pi, 16)]
    boxes.append((3,) + quad_to_box(apply_h(Hb, hole_pts)))
    for cls, (x0, y0, x1, y1) in placed:
        pts = apply_h(Hb, [(x0, y0), (x1, y0), (x1, y1), (x0, y1)])
        bx = quad_to_box(pts)
        if bx[2] - bx[0] > 4 and bx[3] - bx[1] > 4:
            boxes.append((cls,) + bx)

    # off-board bags on the ground (label: bag)
    for _ in range(rng.integers(0, 3)):
        sprite = make_bag_sprite(team_cols[rng.integers(0, 2)], rng)
        s = rng.uniform(0.5, 1.3)
        sprite = sprite.resize((max(6, int(sprite.width * s)), max(6, int(sprite.height * s))))
        cx, cy = rng.integers(0, W), rng.integers(0, H)
        x0, y0 = int(cx - sprite.width / 2), int(cy - sprite.height / 2)
        tmp = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        tmp.paste(sprite, (x0, y0), sprite)
        bg.alpha_composite(tmp)
        bx = (max(0, x0), max(0, y0), min(W, x0 + sprite.width), min(H, y0 + sprite.height))
        if bx[2] - bx[0] > 4 and bx[3] - bx[1] > 4:
            boxes.append((0,) + bx)

    # a bag in flight (motion blurred, larger because it's closer to the camera)
    if rng.random() < 0.25:
        sprite = make_bag_sprite(team_cols[rng.integers(0, 2)], rng)
        s = rng.uniform(0.8, 1.8)
        sprite = sprite.resize((int(sprite.width * s), int(sprite.height * s)))
        sprite = sprite.filter(ImageFilter.GaussianBlur(rng.uniform(0.5, 3)))
        cx, cy = rng.integers(0, W), rng.integers(0, H)
        x0, y0 = int(cx - sprite.width / 2), int(cy - sprite.height / 2)
        tmp = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        tmp.paste(sprite, (x0, y0), sprite)
        bg.alpha_composite(tmp)
        bx = (max(0, x0), max(0, y0), min(W, x0 + sprite.width), min(H, y0 + sprite.height))
        if bx[2] - bx[0] > 4 and bx[3] - bx[1] > 4:
            boxes.append((0,) + bx)

    # occluder: a leg / cooler / chair partially in frame
    if rng.random() < 0.2:
        d = ImageDraw.Draw(bg, "RGBA")
        col = tuple(int(v) for v in rng.integers(20, 200, 3)) + (255,)
        x = rng.integers(0, W)
        wdt = rng.integers(20, 90)
        d.rectangle([x, rng.integers(0, H // 2), x + wdt, H], fill=col)

    img = bg.convert("RGB")

    # lighting: directional gradient + colour temperature + exposure
    grad = noise_img(W, H, 200, 0.65, 1.25, rng)
    arr = np.asarray(img).astype(np.float32) * grad[..., None]
    temp = rng.uniform(-18, 18)
    arr[:, :, 0] += temp
    arr[:, :, 2] -= temp
    arr *= rng.uniform(0.75, 1.25)
    arr += rng.normal(0, rng.uniform(1, 7), arr.shape)
    img = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8))
    if rng.random() < 0.6:
        img = img.filter(ImageFilter.GaussianBlur(rng.uniform(0.2, 1.6)))
    if rng.random() < 0.3:
        img = ImageEnhance.Contrast(img).enhance(rng.uniform(0.7, 1.3))

    return img, boxes


# ----------------------------------------------------------------------------
# writer
# ----------------------------------------------------------------------------

def write_split(out, split, n, rng, start_idx, createml):
    img_dir = os.path.join(out, "images", split)
    lbl_dir = os.path.join(out, "labels", split)
    os.makedirs(img_dir, exist_ok=True)
    os.makedirs(lbl_dir, exist_ok=True)
    for i in range(n):
        if rng.random() < 0.8:
            W, H = int(rng.choice([640, 640, 704, 768])), int(rng.choice([480, 480, 528, 576]))
        else:
            W, H = int(rng.choice([480, 528])), int(rng.choice([640, 704]))
        img, boxes = generate_scene(W, H, rng)
        name = f"synth_{start_idx + i:05d}"
        q = int(rng.integers(55, 96))
        img.save(os.path.join(img_dir, name + ".jpg"), quality=q)
        lines = []
        anns = []
        for cls, x0, y0, x1, y1 in boxes:
            bw, bh = x1 - x0, y1 - y0
            cx, cy = x0 + bw / 2, y0 + bh / 2
            lines.append(f"{cls} {cx / W:.6f} {cy / H:.6f} {bw / W:.6f} {bh / H:.6f}")
            anns.append({"label": CLASSES[cls],
                         "coordinates": {"x": round(cx, 1), "y": round(cy, 1),
                                         "width": round(bw, 1), "height": round(bh, 1)}})
        with open(os.path.join(lbl_dir, name + ".txt"), "w") as f:
            f.write("\n".join(lines) + ("\n" if lines else ""))
        createml.append({"image": name + ".jpg", "annotations": anns})
        if (i + 1) % 100 == 0:
            print(f"  {split}: {i + 1}/{n}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="dataset")
    ap.add_argument("--train", type=int, default=1200)
    ap.add_argument("--val", type=int, default=200)
    ap.add_argument("--seed", type=int, default=1)
    args = ap.parse_args()
    rng = np.random.default_rng(args.seed)
    random.seed(args.seed)
    os.makedirs(args.out, exist_ok=True)
    for split, n, start in (("train", args.train, 0), ("val", args.val, 100000)):
        cm = []
        print(f"generating {split} ({n})")
        write_split(args.out, split, n, rng, start, cm)
        with open(os.path.join(args.out, "images", split, "annotations.json"), "w") as f:
            json.dump(cm, f)
    with open(os.path.join(args.out, "data.yaml"), "w") as f:
        f.write(f"path: {os.path.abspath(args.out)}\n"
                f"train: images/train\nval: images/val\n"
                f"names:\n" + "".join(f"  {i}: {c}\n" for i, c in enumerate(CLASSES)))
    print("done:", args.out)


if __name__ == "__main__":
    main()
