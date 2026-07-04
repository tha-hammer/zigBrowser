#!/usr/bin/env bash
# Build a signed .dmg for macOS on the M9 build host over Tailscale SSH.
# Usage:
#   bash packaging/macos/build-dmg.sh            # build + sign + package
#   bash packaging/macos/build-dmg.sh --skip-build  # repackage existing binary
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)

VERSION=0.1.3
APP_NAME="zigBrowser"
BUNDLE_ID="com.cosmichq.zigBrowser"
DMG_NAME="${APP_NAME}_${VERSION}_macos.dmg"

KEY="${ZB_MAC_KEY:-/home/maceo/vms/mac-m9/zb_mac_key}"
HOST="${ZB_MAC_HOST:-maceojourdan@100.92.212.47}"
SSH=(ssh -i "$KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no \
     -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -o ServerAliveInterval=10)
SCP=(scp -i "$KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no \
     -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15)

SKIP_BUILD=0
if [ "${1:-}" = "--skip-build" ]; then
  SKIP_BUILD=1
fi

cd "$REPO_ROOT"

# ── Step 1: Build on the Mac (unless --skip-build) ──
if [ "$SKIP_BUILD" -eq 0 ]; then
  echo "==> Building on macOS host..."
  bash tests/mac/build-on-mac.sh
fi

# ── Step 2: Sync assets to the Mac ──
echo "==> Syncing packaging assets..."
"${SCP[@]}" \
  packaging/assets/zigBrowser.png \
  packaging/macos/Info.plist \
  "$HOST":zigBrowser/ >/dev/null

# ── Step 3: Assemble .app bundle, sign, and create .dmg on the Mac ──
echo "==> Assembling .app bundle, signing, and creating .dmg..."
"${SSH[@]}" "$HOST" /bin/bash -s "$VERSION" "$APP_NAME" "$DMG_NAME" <<'REMOTE'
set -euo pipefail
VERSION="$1"
APP_NAME="$2"
DMG_NAME="$3"

cd "$HOME/zigBrowser"
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
"${SCP[@]}" "$HOST:zigBrowser/$DMG_NAME" "$REPO_ROOT/$DMG_NAME" >/dev/null

ls -lh "$REPO_ROOT/$DMG_NAME"
printf '==> Done: %s\n' "$REPO_ROOT/$DMG_NAME"
