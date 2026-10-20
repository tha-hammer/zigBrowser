#!/usr/bin/env python3
"""WS1.3 PNG census (Linux-side, no external deps) — validate a screenshot PNG and check it is
NON-UNIFORM (not a blank/solid capture).

`zigBrowser.exe <url> --screenshot out.png` must write a real PNG via ICoreWebView2::CapturePreview.
This decodes IHDR + IDAT (zlib), un-filters scanlines (filter types 0-4), and reports whether every
pixel is identical. To stay fast on large captures it scans at most the first 256 rows and stops at the
first differing pixel — a real page differs early; a blank/solid capture is uniform in any sample.

CLI:
    png_census.py <png>                      -> census JSON, exit 0
    png_census.py --require-nonuniform <png> -> exit 1 if the image is uniform (or undecodable)
Supports 8-bit grayscale/RGB/palette/RGBA (color types 0/2/3/6); other depths report non_uniform=null.
"""
import json
import struct
import sys
import zlib

_SIG = b"\x89PNG\r\n\x1a\n"
_CHANNELS = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}  # bytes per pixel at 8-bit
_ROW_CAP = 256


def _paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    return a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)


def census(path):
    data = open(path, "rb").read()
    if data[:8] != _SIG:
        raise ValueError("not a PNG (bad signature)")
    off = 8
    width = height = bit_depth = color_type = None
    idat = bytearray()
    while off + 12 <= len(data):
        (ln,) = struct.unpack_from(">I", data, off)
        typ = data[off + 4:off + 8]
        body = data[off + 8:off + 8 + ln]
        off += 12 + ln
        if typ == b"IHDR":
            width, height, bit_depth, color_type = struct.unpack(">IIBB", body[:10])
        elif typ == b"IDAT":
            idat += body
        elif typ == b"IEND":
            break
    info = {"valid": True, "width": width, "height": height,
            "bit_depth": bit_depth, "color_type": color_type}
    if bit_depth != 8 or color_type not in _CHANNELS:
        info["non_uniform"] = None  # not decoded here
        return info
    bpp = _CHANNELS[color_type]
    raw = zlib.decompress(bytes(idat))
    stride = width * bpp
    prev = bytearray(stride)
    first = None
    uniform = True
    o = 0
    rows = min(height, _ROW_CAP)
    for _y in range(rows):
        ft = raw[o]; o += 1
        line = bytearray(raw[o:o + stride]); o += stride
        if ft:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                if ft == 1:
                    line[i] = (line[i] + a) & 0xFF
                elif ft == 2:
                    line[i] = (line[i] + b) & 0xFF
                elif ft == 3:
                    line[i] = (line[i] + ((a + b) >> 1)) & 0xFF
                elif ft == 4:
                    line[i] = (line[i] + _paeth(a, b, c)) & 0xFF
        prev = line
        for px in range(0, stride, bpp):
            pel = bytes(line[px:px + bpp])
            if first is None:
                first = pel
            elif pel != first:
                uniform = False
                break
        if not uniform:
            break
    info["non_uniform"] = (not uniform)
    return info


def main(argv):
    enforce = False
    args = list(argv)
    if args and args[0] == "--require-nonuniform":
        enforce = True
        args = args[1:]
    if not args:
        print("usage: png_census.py [--require-nonuniform] <png>", file=sys.stderr)
        return 2
    c = census(args[0])
    print(json.dumps(c, indent=2))
    if enforce and not c.get("non_uniform"):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
