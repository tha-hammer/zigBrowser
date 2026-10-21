#!/usr/bin/env python3
"""WS1.3 png_census selftest (GREEN, registered) — exercises the PNG non-uniform oracle on independent,
Linux-built PNG fixtures, so decoder/uniformity defects are caught even while the real screenshot is not
yet produced (the exe red in png_census_test.py stays unregistered until WS1 builds + captures).

Covers: a solid image is uniform (rejected by --require-nonuniform), a varied image is non-uniform
(accepted), each PNG filter type (0-4) un-filters correctly, a non-PNG and a truncated IDAT raise, and an
ABSENT file raises FileNotFoundError cleanly (no leaked handle). Run each module alone with -X dev to
confirm zero ResourceWarnings.

Run alone:  python3 -I -X dev tests/windows/png_census_selftest.py -v
"""
import pathlib
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib

REPO = pathlib.Path(__file__).resolve().parents[2]
HERE = REPO / "tests" / "windows"
CENSUS = HERE / "png_census.py"
sys.path.insert(0, str(HERE))
import png_census  # noqa: E402


def write_png(path, w, h, pixel, filt=0):
    """Minimal 8-bit RGB PNG with a chosen filter byte per scanline. `pixel(x,y)` -> (r,g,b).
    For filt 0 the raw bytes are the pixels; for filt 1-4 we emit the ENCODED bytes so the census must
    correctly reverse the filter to recover the pixels."""
    rows = []
    prev = [0] * (w * 3)
    for y in range(h):
        cur = []
        for x in range(w):
            cur += list(pixel(x, y))
        enc = []
        for i in range(len(cur)):
            a = cur[i - 3] if i >= 3 else 0
            b = prev[i]
            c = prev[i - 3] if i >= 3 else 0
            if filt == 0:
                enc.append(cur[i])
            elif filt == 1:
                enc.append((cur[i] - a) & 0xFF)
            elif filt == 2:
                enc.append((cur[i] - b) & 0xFF)
            elif filt == 3:
                enc.append((cur[i] - ((a + b) >> 1)) & 0xFF)
            elif filt == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                enc.append((cur[i] - pr) & 0xFF)
        rows.append(bytes([filt]) + bytes(enc))
        prev = cur
    raw = b"".join(rows)

    def chunk(typ, body):
        return struct.pack(">I", len(body)) + typ + body + struct.pack(">I", zlib.crc32(typ + body) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)
    path.write_bytes(png_census._SIG + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


class PngCensusOracle(unittest.TestCase):
    def _mk(self, name):
        d = tempfile.mkdtemp(prefix="zbpng_")
        p = pathlib.Path(d) / name
        self.addCleanup(lambda: (p.unlink(missing_ok=True), p.parent.rmdir()))
        return p

    def _cli(self, path):
        p = subprocess.run([sys.executable, "-I", str(CENSUS), "--require-nonuniform", str(path)],
                           capture_output=True, text=True, timeout=30)
        return p.returncode

    def test_uniform_rejected_varied_accepted(self):
        uni = self._mk("uniform.png"); var = self._mk("varied.png")
        write_png(uni, 32, 32, lambda x, y: (10, 20, 30))
        write_png(var, 32, 32, lambda x, y: ((x * 7) % 256, (y * 5) % 256, 0))
        self.assertFalse(png_census.census(str(uni))["non_uniform"], "a solid image must be uniform")
        self.assertTrue(png_census.census(str(var))["non_uniform"], "a varied image must be non-uniform")
        self.assertEqual(self._cli(uni), 1, "--require-nonuniform must reject a uniform image")
        self.assertEqual(self._cli(var), 0, "--require-nonuniform must accept a varied image")

    def test_each_filter_type_unfilters(self):
        # A varied image encoded with each filter 0-4 must still decode to non-uniform (the un-filter works).
        for filt in range(5):
            var = self._mk("f%d.png" % filt)
            write_png(var, 24, 24, lambda x, y: ((x * 11 + y) % 256, (y * 3) % 256, (x + y) % 256), filt=filt)
            self.assertTrue(png_census.census(str(var))["non_uniform"], "filter %d must decode to non-uniform" % filt)
        # A uniform image under a non-trivial filter stays uniform.
        uni = self._mk("fu.png")
        write_png(uni, 24, 24, lambda x, y: (7, 7, 7), filt=2)
        self.assertFalse(png_census.census(str(uni))["non_uniform"], "a solid image stays uniform under filtering")

    def test_non_png_raises(self):
        bad = self._mk("x.png"); bad.write_bytes(b"not a png at all")
        with self.assertRaises(ValueError):
            png_census.census(str(bad))

    def test_truncated_idat_raises(self):
        # A PNG whose IDAT is corrupt must raise (zlib error), never silently report uniform.
        p = self._mk("trunc.png")
        def chunk(typ, body):
            return struct.pack(">I", len(body)) + typ + body + struct.pack(">I", zlib.crc32(typ + body) & 0xFFFFFFFF)
        ihdr = struct.pack(">IIBBBBB", 8, 8, 8, 2, 0, 0, 0)
        p.write_bytes(png_census._SIG + chunk(b"IHDR", ihdr) + chunk(b"IDAT", b"\x00\x01\x02truncated") + chunk(b"IEND", b""))
        with self.assertRaises(Exception):
            png_census.census(str(p))

    def test_absent_file_raises_cleanly(self):
        # The absent-artifact case: census of a missing path raises FileNotFoundError (no leaked handle).
        missing = self._mk("gone.png")  # created dir, file never written
        with self.assertRaises(FileNotFoundError):
            png_census.census(str(missing))


if __name__ == "__main__":
    unittest.main()
