#!/usr/bin/env python3
import sys
from pathlib import Path


def _load_pillow():
    try:
        from PIL import Image
    except Exception as exc:  # pragma: no cover - runtime dependency check
        print(f"missing_pillow:{exc}", file=sys.stderr)
        return None
    return Image


def cmd_check() -> int:
    image_mod = _load_pillow()
    if image_mod is None:
        return 2
    print("ok")
    return 0


def cmd_write(raw_path: str, out_path: str, width: str, height: str) -> int:
    image_mod = _load_pillow()
    if image_mod is None:
        return 2

    w = int(width)
    h = int(height)
    raw_bytes = Path(raw_path).read_bytes()
    expected = w * h * 4
    if len(raw_bytes) != expected:
        print(f"invalid_raw_size expected={expected} got={len(raw_bytes)}", file=sys.stderr)
        return 3

    img = image_mod.frombytes("RGBA", (w, h), raw_bytes)
    Path(out_path).parent.mkdir(parents=True, exist_ok=True)
    img.save(out_path, "PNG")
    return 0


def cmd_diff(actual_path: str, expected_path: str) -> int:
    image_mod = _load_pillow()
    if image_mod is None:
        return 2

    actual = image_mod.open(actual_path).convert("RGBA")
    expected = image_mod.open(expected_path).convert("RGBA")
    if actual.size != expected.size:
        print("1.0")
        return 0

    a_pixels = list(actual.getdata())
    e_pixels = list(expected.getdata())
    total_channels = len(a_pixels) * 4
    diff_sum = 0
    for a_px, e_px in zip(a_pixels, e_pixels):
        diff_sum += abs(a_px[0] - e_px[0])
        diff_sum += abs(a_px[1] - e_px[1])
        diff_sum += abs(a_px[2] - e_px[2])
        diff_sum += abs(a_px[3] - e_px[3])

    ratio = diff_sum / (255.0 * total_channels) if total_channels else 0.0
    print(f"{ratio:.12f}")
    return 0


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: pillow_tools.py <check|write|diff> ...", file=sys.stderr)
        return 1

    subcmd = sys.argv[1]
    if subcmd == "check":
        return cmd_check()
    if subcmd == "write" and len(sys.argv) == 6:
        return cmd_write(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])
    if subcmd == "diff" and len(sys.argv) == 4:
        return cmd_diff(sys.argv[2], sys.argv[3])

    print("invalid_args", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
