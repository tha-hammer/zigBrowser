#!/usr/bin/env python3
"""WS1.3 red (UNREGISTERED) + png_census oracle teeth.

`zigBrowser.exe <url> --screenshot out.png` must write a real, NON-UNIFORM PNG (today it returns
ZB_EXIT_SNAPSHOT_FAILED). The gate fetches the PNG to Linux and runs png_census.py --require-nonuniform.

This file:
  * proves the png_census oracle has teeth — a solid-color fixture is uniform (rejected), a varied
    fixture is non-uniform (accepted) — these run green now (no exe needed);
  * the WS1.3 slice red: censuses the fetched screenshot (ZB_WIN_SHOT), RED today because WS1 is not
    built, so there is no screenshot to census.

Unregistered (red outside gate-registered steps); registers as the WS1 screenshot phase in the green.
Run alone:  python3 -I tests/windows/png_census_test.py -v
"""
import importlib.util
import os
import pathlib
import struct
import tempfile
import unittest
import zlib

REPO = pathlib.Path(__file__).resolve().parents[2]
_spec = importlib.util.spec_from_file_location("png_census", REPO / "tests" / "windows" / "png_census.py")
png_census = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(png_census)

SHOT = os.environ.get("ZB_WIN_SHOT", str(REPO / "zig-out" / "shot.png"))
_SIG = b"\x89PNG\r\n\x1a\n"


def _write_png(path, w, h, pixel):
    """Minimal 8-bit RGB PNG (filter 0). `pixel(x, y)` -> (r, g, b)."""
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        for x in range(w):
            raw += bytes(pixel(x, y))

    def chunk(typ, body):
        return struct.pack(">I", len(body)) + typ + body + struct.pack(">I", zlib.crc32(typ + body) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)
    path.write_bytes(_SIG + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(bytes(raw))) + chunk(b"IEND", b""))


class PngCensusOracle(unittest.TestCase):
    def test_uniform_image_is_rejected_varied_is_accepted(self):
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            uni = td / "uniform.png"; var = td / "varied.png"
            _write_png(uni, 32, 32, lambda x, y: (10, 20, 30))
            _write_png(var, 32, 32, lambda x, y: ((x * 7) % 256, (y * 5) % 256, 0))
            self.assertFalse(png_census.census(str(uni))["non_uniform"], "a solid image must be uniform")
            self.assertTrue(png_census.census(str(var))["non_uniform"], "a varied image must be non-uniform")

    def test_non_png_raises(self):
        with tempfile.TemporaryDirectory() as t:
            bad = pathlib.Path(t) / "x.png"; bad.write_bytes(b"not a png")
            with self.assertRaises(ValueError):
                png_census.census(str(bad))


class WS13Screenshot(unittest.TestCase):
    def test_release_screenshot_is_a_real_nonuniform_png(self):
        self.assertTrue(pathlib.Path(SHOT).exists(),
                        f"WS1.3 screenshot not produced yet: {SHOT} (needs the built exe + --screenshot; set ZB_WIN_SHOT)")
        c = png_census.census(SHOT)
        self.assertTrue(c["valid"], f"not a valid PNG: {c}")
        self.assertTrue(c["non_uniform"], f"the screenshot must be non-uniform (not blank): {c}")


if __name__ == "__main__":
    unittest.main()
