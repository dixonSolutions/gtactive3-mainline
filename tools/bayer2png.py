#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""
Turn a raw Bayer frame captured on the tablet (v4l2-ctl --stream-to, cam
--file) into PNGs that can be looked at.

usage: bayer2png.py FRAME WIDTH HEIGHT OUT.png [options]

  --format u16|p10|le12|u8
                        u16: 10 bits LSB-aligned in 16-bit little endian
                        words (V4L2 RG10/BA10/GB10/BG10, what
                        exynos9810-csis delivers); p10: MIPI RAW10 packed,
                        4 pixels in 5 bytes (pRAA/pgAA/...); le12: 12-bit
                        little endian containers, 2 pixels in 3 bytes (the
                        CSIS VC DMA with PACK12 set); u8: 8 bits per pixel.
                        Default u16.
  --order RGGB|GRBG|GBRG|BGGR
                        Bayer order of the first two lines (S5K3L6: GRBG,
                        GC5035: RGGB). Default GRBG.
  --stride BYTES        bytes per line; default: the file size divided by
                        the height (exynos9810-csis pads lines to 16 bytes).
  --black N             black level in 10-bit units (default 64).
  --frame N             which frame of a multi-frame file (default 0).

Writes OUT.png (half-resolution debayer: one RGB pixel per 2x2 quad,
gray-world white balance, gamma 2.2) and OUT.raw.png (the raw values as
8-bit gray, full resolution: shows the Bayer pattern and the stride).
Prints min/mean/max per colour channel, which tells a dark frame (all
near the black level), a saturated one (1023) and a dead DMA (zeros or
an untouched fill pattern) apart.
"""
import argparse
import os
import sys

import numpy as np
from PIL import Image


def unpack(buf, w, h, fmt, stride):
    rows = np.frombuffer(buf, np.uint8, stride * h).reshape(h, stride)
    if fmt == "p10":
        if w % 4:
            sys.exit("p10 needs a width that is a multiple of 4")
        q = rows[:, :w * 5 // 4].reshape(h, w // 4, 5).astype(np.uint16)
        px = np.empty((h, w // 4, 4), np.uint16)
        for i in range(4):
            px[:, :, i] = (q[:, :, i] << 2) | ((q[:, :, 4] >> (2 * i)) & 3)
        return px.reshape(h, w)
    if fmt == "le12":
        if w % 2:
            sys.exit("le12 needs an even width")
        q = rows[:, :w * 3 // 2].reshape(h, w // 2, 3).astype(np.uint16)
        px = np.empty((h, w // 2, 2), np.uint16)
        px[:, :, 0] = q[:, :, 0] | ((q[:, :, 1] & 0xf) << 8)
        px[:, :, 1] = (q[:, :, 1] >> 4) | (q[:, :, 2] << 4)
        return px.reshape(h, w) & 0x3ff
    if fmt == "u16":
        return rows[:, :w * 2].copy().view("<u2").reshape(h, w) & 0x3ff
    return rows[:, :w].astype(np.uint16) << 2


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[1],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("frame")
    ap.add_argument("width", type=int)
    ap.add_argument("height", type=int)
    ap.add_argument("out")
    ap.add_argument("--format", choices=("u16", "p10", "le12", "u8"), default="u16")
    ap.add_argument("--order", default="GRBG")
    ap.add_argument("--stride", type=int, default=0)
    ap.add_argument("--black", type=float, default=64.0)
    ap.add_argument("--frame", type=int, default=0, dest="index")
    a = ap.parse_args()

    order = a.order.upper()
    if sorted(order) != sorted("RGGB"):
        sys.exit(f"bad Bayer order {a.order}")
    w, h = a.width, a.height
    minline = {"p10": w * 5 // 4, "le12": w * 3 // 2, "u16": w * 2, "u8": w}[a.format]

    size = os.path.getsize(a.frame)
    stride = a.stride
    if not stride:
        # one frame, or several back to back: assume the smallest padding
        # (to 16 bytes) that divides the file
        for cand in (minline, (minline + 15) & ~15, (minline + 63) & ~63):
            if size % (cand * h) == 0:
                stride = cand
                break
        else:
            stride = size // h
    frames = size // (stride * h)
    if stride < minline or size < stride * 2:
        sys.exit(f"{size} bytes is too small for {w}x{h} {a.format} (stride {stride})")
    if frames < 1:
        # a truncated capture: show the complete lines it has
        h = (size // stride) & ~1
        frames = 1
        print(f"warning: only {h} complete lines, decoding those")
    if a.index >= frames:
        sys.exit(f"frame {a.index} requested, the file holds {frames}")
    print(f"{size} bytes: {frames} frame(s), stride {stride} (minimum {minline})")

    with open(a.frame, "rb") as f:
        f.seek(a.index * stride * h)
        img = unpack(f.read(stride * h), w, h, a.format, stride)

    base = a.out[:-4] if a.out.endswith(".png") else a.out
    Image.fromarray((img >> 2).astype(np.uint8)).save(base + ".raw.png")

    planes = {}
    for i, c in enumerate(order):
        planes.setdefault(c, []).append(img[i // 2::2, i % 2::2].astype(np.float32))
    for c in "RGB":
        p = np.concatenate([x.ravel() for x in planes[c]])
        print(f"{c}: min {p.min():.0f} mean {p.mean():.1f} max {p.max():.0f}")
    if img.max() == img.min():
        print("warning: every pixel has the same value (no data written?)")

    rgb = np.stack([np.mean(planes[c], axis=0) for c in "RGB"], axis=-1)
    rgb = (rgb - a.black).clip(0, None)
    mean = rgb.reshape(-1, 3).mean(axis=0) + 1e-3
    rgb *= mean[1] / mean
    rgb /= max(np.percentile(rgb, 99.5), 1e-3)
    rgb = np.power(rgb.clip(0, 1), 1 / 2.2)
    Image.fromarray((rgb * 255 + 0.5).astype(np.uint8)).save(base + ".png")
    print(f"wrote {base}.png and {base}.raw.png")


if __name__ == "__main__":
    main()
