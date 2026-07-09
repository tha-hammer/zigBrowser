#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)

VERSION=0.2.0
ARCH=amd64
PACKAGE=zigbrowser
DEB_NAME=zigBrowser_${VERSION}_${ARCH}.deb
STAGE_DIR=$SCRIPT_DIR/.stage/$PACKAGE
OUT_DEB=$REPO_ROOT/$DEB_NAME
ASSET_ICON=$REPO_ROOT/packaging/assets/zigBrowser.png

command -v zig >/dev/null 2>&1 || { echo "missing zig" >&2; exit 1; }
command -v dpkg-deb >/dev/null 2>&1 || { echo "missing dpkg-deb" >&2; exit 1; }
command -v fakeroot >/dev/null 2>&1 || { echo "missing fakeroot" >&2; exit 1; }

cd "$REPO_ROOT"
zig build -Doptimize=ReleaseSafe

rm -rf "$STAGE_DIR"
mkdir -p \
  "$STAGE_DIR/DEBIAN" \
  "$STAGE_DIR/usr/bin" \
  "$STAGE_DIR/usr/share/applications" \
  "$STAGE_DIR/usr/share/icons/hicolor/256x256/apps"

sed "s/@VERSION@/$VERSION/g" "$SCRIPT_DIR/control.in" > "$STAGE_DIR/DEBIAN/control"
chmod 0644 "$STAGE_DIR/DEBIAN/control"
install -m 0755 "$REPO_ROOT/zig-out/bin/zigBrowser" "$STAGE_DIR/usr/bin/zigBrowser"
install -m 0644 "$SCRIPT_DIR/zigBrowser.desktop" "$STAGE_DIR/usr/share/applications/zigBrowser.desktop"

if [ -f "$ASSET_ICON" ]; then
  install -m 0644 "$ASSET_ICON" "$STAGE_DIR/usr/share/icons/hicolor/256x256/apps/zigBrowser.png"
else
  python3 - "$STAGE_DIR/usr/share/icons/hicolor/256x256/apps/zigBrowser.png" <<'PY'
import struct
import sys
import zlib

path = sys.argv[1]
width = height = 256
rows = []
for y in range(height):
    row = bytearray([0])
    for x in range(width):
        if (x // 32 + y // 32) % 2:
            row.extend((34, 94, 168, 255))
        else:
            row.extend((238, 242, 247, 255))
    rows.append(bytes(row))

def chunk(kind, data):
    body = kind + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

png = (
    b"\x89PNG\r\n\x1a\n"
    + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
    + chunk(b"IDAT", zlib.compress(b"".join(rows), 9))
    + chunk(b"IEND", b"")
)
with open(path, "wb") as f:
    f.write(png)
PY
fi

rm -f "$OUT_DEB"
fakeroot dpkg-deb --build "$STAGE_DIR" "$OUT_DEB"
printf '%s\n' "$OUT_DEB"
