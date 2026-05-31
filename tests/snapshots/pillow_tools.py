#!/usr/bin/env python3
"""Small PNG helper utilities for snapshot gates."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Sequence

from PIL import Image, ImageChops, ImageStat


def cmd_check(path: Path) -> int:
    try:
        with Image.open(path) as img:
            img.verify()
    except Exception as exc:  # pragma: no cover - tool-level diagnostics
        print(f"invalid_png\t{path}\t{exc}")
        return 1
    print(f"ok\t{path}")
    return 0


def cmd_diff(a: Path, b: Path, out: Path | None) -> int:
    with Image.open(a) as img_a, Image.open(b) as img_b:
        if img_a.size != img_b.size:
            print(f"size_mismatch\t{img_a.size}\t{img_b.size}")
            return 1
        diff = ImageChops.difference(img_a.convert("RGBA"), img_b.convert("RGBA"))
        bbox = diff.getbbox()
        if out is not None:
            diff.save(out)
        print("equal" if bbox is None else "different")
        return 0 if bbox is None else 1


def cmd_nonuniform(path: Path) -> int:
    with Image.open(path) as img:
        pixels = img.convert("RGBA")
        stat = ImageStat.Stat(pixels)
        stddev = sum(stat.stddev) / len(stat.stddev)

        # Distinct color count over a bounded sample for large images.
        sample = pixels.resize((min(256, pixels.width), min(256, pixels.height)))
        colors = sample.getcolors(maxcolors=256 * 256)
        distinct = len(colors) if colors is not None else 256 * 256

        result = {
            "stddev": stddev,
            "distinct": distinct,
            "width": pixels.width,
            "height": pixels.height,
        }
        print(json.dumps(result))

        # Conservative threshold: catches pure/near-pure blank frames.
        return 0 if (stddev >= 1.0 and distinct >= 8) else 1


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_check = sub.add_parser("check")
    p_check.add_argument("path", type=Path)

    p_diff = sub.add_parser("diff")
    p_diff.add_argument("a", type=Path)
    p_diff.add_argument("b", type=Path)
    p_diff.add_argument("--out", type=Path)

    p_nonuniform = sub.add_parser("nonuniform")
    p_nonuniform.add_argument("path", type=Path)

    return parser.parse_args(argv)


def main(argv: Sequence[str]) -> int:
    ns = parse_args(argv)
    if ns.cmd == "check":
        return cmd_check(ns.path)
    if ns.cmd == "diff":
        return cmd_diff(ns.a, ns.b, ns.out)
    if ns.cmd == "nonuniform":
        return cmd_nonuniform(ns.path)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(__import__("sys").argv[1:]))
