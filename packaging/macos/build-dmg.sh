#!/usr/bin/env bash
# Build a signed .dmg for macOS on the M9 build host over Tailscale SSH.
# Usage:
#   bash packaging/macos/build-dmg.sh            # build ${ZB_GATE_COMMIT:-HEAD} + sign + package
# It builds one exact commit into a fresh per-run dir on the Mac and works only there, with pinned host keys (bd 4pa.59,
# 4pa.77). The old --skip-build (repackage a binary left in a shared dir) is refused: there is no shared dir any more.
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)

VERSION=0.2.0
APP_NAME="zigBrowser"
BUNDLE_ID="com.cosmichq.zigBrowser"
DMG_NAME="${APP_NAME}_${VERSION}_macos.dmg"

KEY="${ZB_MAC_KEY:-/home/maceo/vms/mac-m9/zb_mac_key}"
HOST="${ZB_MAC_HOST:-maceojourdan@100.92.212.47}"

if [ "${1:-}" = "--skip-build" ]; then
  echo "REFUSED: --skip-build is gone; every dmg builds one exact commit in a fresh per-run dir" >&2
  exit 1
fi

cd "$REPO_ROOT"
. tests/mac/mac_gate_lib.sh
trap mac_remove_run_dirs EXIT
mapfile -d '' SSH < <(mac_ssh_opts "$KEY")
mapfile -d '' SCP < <(mac_scp_opts "$KEY")

# ── Step 1: Build on the Mac, into a fresh run dir ──
echo "==> Building on macOS host..."
mac_build "$HOST" "$KEY"
RUN_DIR=$MAC_RDIR

# ── Step 2: Sync assets to the Mac ──
echo "==> Syncing packaging assets..."
"${SCP[@]}" \
  packaging/assets/zigBrowser.png \
  packaging/macos/Info.plist \
  "$HOST:$RUN_DIR/" >/dev/null

# ── Step 3: Assemble .app bundle, sign, and create .dmg on the Mac ──
echo "==> Assembling .app bundle, signing, and creating .dmg..."
"${SSH[@]}" "$HOST" /bin/bash -s "$VERSION" "$APP_NAME" "$DMG_NAME" "$RUN_DIR" <<'REMOTE'
set -euo pipefail
VERSION="$1"
APP_NAME="$2"
DMG_NAME="$3"

cd "$HOME/${4:?}"
BINARY="zig-out/bin/zigBrowser"
if [ ! -f "$BINARY" ]; then
  echo "ERROR: binary not found: $BINARY" >&2
  exit 1
fi

APP_BUNDLE="${APP_NAME}.app"
CONTENTS="$APP_BUNDLE/Contents"

# Clean previous bundle
rm -rf "$APP_BUNDLE" "$DMG_NAME" dmg_staging

# Create .app structure
mkdir -p "$CONTENTS/MacOS"
mkdir -p "$CONTENTS/Resources"

# Copy binary
cp "$BINARY" "$CONTENTS/MacOS/$APP_NAME"
chmod 755 "$CONTENTS/MacOS/$APP_NAME"

# Stamp version into Info.plist
sed "s/__VERSION__/$VERSION/g" Info.plist > "$CONTENTS/Info.plist"

# Generate .icns from PNG
ICONSET="${APP_NAME}.iconset"
rm -rf "$ICONSET"
mkdir "$ICONSET"
sips -z 16 16     zigBrowser.png --out "$ICONSET/icon_16x16.png"      >/dev/null
sips -z 32 32     zigBrowser.png --out "$ICONSET/icon_16x16@2x.png"   >/dev/null
sips -z 32 32     zigBrowser.png --out "$ICONSET/icon_32x32.png"      >/dev/null
sips -z 64 64     zigBrowser.png --out "$ICONSET/icon_32x32@2x.png"   >/dev/null
sips -z 128 128   zigBrowser.png --out "$ICONSET/icon_128x128.png"    >/dev/null
sips -z 256 256   zigBrowser.png --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256   zigBrowser.png --out "$ICONSET/icon_256x256.png"    >/dev/null
iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/${APP_NAME}.icns"
rm -rf "$ICONSET"

# Ad-hoc code sign
codesign --force --sign - --deep "$APP_BUNDLE"

# Verify signature
codesign --verify --verbose "$APP_BUNDLE"

# Create DMG with drag-to-Applications layout
mkdir dmg_staging
cp -R "$APP_BUNDLE" dmg_staging/
ln -s /Applications dmg_staging/Applications

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder dmg_staging \
  -ov \
  -format UDZO \
  "$DMG_NAME"

rm -rf dmg_staging "$APP_BUNDLE"

ls -lh "$DMG_NAME"
echo "DMG_READY=$DMG_NAME"
REMOTE

# ── Step 4: Copy .dmg back to the Linux host ──
echo "==> Downloading .dmg..."
"${SCP[@]}" "$HOST:$RUN_DIR/$DMG_NAME" "$REPO_ROOT/$DMG_NAME" >/dev/null

ls -lh "$REPO_ROOT/$DMG_NAME"
printf '==> Done: %s\n' "$REPO_ROOT/$DMG_NAME"
