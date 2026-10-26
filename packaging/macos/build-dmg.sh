#!/usr/bin/env bash
# Build an ad-hoc dev dmg, not a distributable artifact, on the M9 build host over Tailscale SSH.
# Usage:
#   bash packaging/macos/build-dmg.sh            # build ${ZB_GATE_COMMIT:-HEAD} + sign + package
# The .app ships the WKWebView shim in Contents/Frameworks (the exe loads @executable_path/../Frameworks/
# libwkwebview_shim.dylib; otool -L proves the reference resolves inside the bundle) and is signed inside out: the
# dylib, then the exe, then the .app, never --deep (bd 4pa.73). Ad hoc (identity "-") by default; with
# ZB_DMG_SIGN_IDENTITY set, each signature adds the hardened runtime and the exe and .app get the committed
# packaging/macos/entitlements.plist. Not notarized (MS9).
# The .app is UNIVERSAL (MS1c, bd 4pa.73): each Mac builds the commit natively (arm64 on ZB_MAC_ARM_HOST, x86_64 on
# ZB_MAC_HOST), the arm64 exe and shim go to the Intel run dir, and lipo joins each pair; both bundled Mach-O files must
# then hold exactly x86_64 and arm64 (lipo -archs) before anything is signed. Info.plist and the icon come from the
# commit's own tree in that run dir, never from this working tree.
# Hostless selftests: tests/mac/dmg_universal_selftest.sh and tests/mac/dmg_script_selftest.sh (zig build
# test-mac-dmg-script).
# It builds one exact commit into a fresh per-run dir on the Mac and works only there, with pinned host keys (bd 4pa.59,
# 4pa.77). The old --skip-build (repackage a binary left in a shared dir) is refused: there is no shared dir any more.
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)

VERSION=0.2.0
APP_NAME="zigBrowser"
BUNDLE_ID="com.cosmichq.zigBrowser"
DMG_NAME="${APP_NAME}_${VERSION}_macos.dmg"

SIGN_IDENTITY="${ZB_DMG_SIGN_IDENTITY:--}"

if [ "${1:-}" = "--skip-build" ]; then
  echo "REFUSED: --skip-build is gone; every dmg builds one exact commit in a fresh per-run dir" >&2
  exit 1
fi

cd "$REPO_ROOT"
# The Macs and the key come only from the explicit environment, never a default (bd 3ui.13): NOT RUN otherwise.
. tests/mac/mac_config.sh
mac_config two
. tests/mac/mac_gate_lib.sh
SLICES=$(mktemp -d "${TMPDIR:-/tmp}/zb-dmg-slices-XXXXXX")
trap 'mac_remove_run_dirs; rm -rf -- "${SLICES:?}"' EXIT
mapfile -d '' SSH < <(mac_ssh_opts "$KEY")
mapfile -d '' SCP < <(mac_scp_opts "$KEY")
mapfile -d '' ARM_SCP < <(mac_scp_opts "$ARM_KEY")

# Prepare the runtime from the same commit the Macs build. The python.org installer is pinned by SHA-256 here and is
# checked again for its PSF signature and Apple notarization by stage_agent_runtime.sh on the packaging Mac. The two
# target site-packages trees come only from that commit's frozen uv.lock; the Mac stager merges their native code.
COMMIT=$(git rev-parse --verify "${ZB_GATE_COMMIT:-HEAD}^{commit}")
RUNTIME_REPO="$SLICES/runtime-repo"
mkdir "$RUNTIME_REPO"
git archive --format=tar "$COMMIT" packaging/macos agent/host | tar -xf - -C "$RUNTIME_REPO"
read -r PYTHON_PKG_URL PYTHON_PKG_SHA < <(python3 -I - "$RUNTIME_REPO/packaging/macos/agent_runtime_pins.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    package = json.load(stream)["python_pkg"]
print(package["url"], package["sha256"])
PY
)
[[ "$PYTHON_PKG_URL" = https://www.python.org/* ]] && [[ "$PYTHON_PKG_SHA" =~ ^[0-9a-f]{64}$ ]] \
  || { echo "ERROR: the selected commit has invalid agent runtime pins" >&2; exit 1; }
echo "==> Preparing the universal agent runtime from $COMMIT..."
curl --fail --show-error --silent --location --max-redirs 0 --proto '=https' --proto-redir '=https' \
  --output "$SLICES/python.pkg" "$PYTHON_PKG_URL"
[ "$(sha256sum "$SLICES/python.pkg" | cut -c1-64)" = "$PYTHON_PKG_SHA" ] \
  || { echo "ERROR: the Python package does not match the selected commit's SHA-256" >&2; exit 1; }
bash "$RUNTIME_REPO/packaging/macos/build_site_packages.sh" "$RUNTIME_REPO/agent/host" "$SLICES/sites"
(cd "$SLICES/sites" && tar -cf "$SLICES/sites.tar" site-x86_64 site-aarch64)
(cd "$RUNTIME_REPO" && tar -cf "$SLICES/agent-host-source.tar" agent/host)

# ── Step 1: Build on each Mac, each into a fresh run dir ──
echo "==> Building on macOS host..."
mac_build "$ARM_HOST" "$ARM_KEY"
ARM_DIR=$MAC_RDIR
mac_build "$HOST" "$KEY"
RUN_DIR=$MAC_RDIR

# ── Step 2: The arm64 exe and shim go to the Intel run dir ──
echo "==> Fetching the arm64 slices..."
"${ARM_SCP[@]}" "$ARM_HOST:$ARM_DIR/zig-out/bin/zigBrowser" "$SLICES/zigBrowser-arm64" >/dev/null
"${ARM_SCP[@]}" "$ARM_HOST:$ARM_DIR/zig-out/Frameworks/libwkwebview_shim.dylib" "$SLICES/libwkwebview_shim-arm64.dylib" >/dev/null
[ -s "$SLICES/zigBrowser-arm64" ] && [ -s "$SLICES/libwkwebview_shim-arm64.dylib" ] \
  || { echo "ERROR: the arm64 build output did not arrive" >&2; exit 1; }
"${SCP[@]}" "$SLICES/zigBrowser-arm64" "$SLICES/libwkwebview_shim-arm64.dylib" "$HOST:$RUN_DIR/" >/dev/null
"${SCP[@]}" "$SLICES/python.pkg" "$SLICES/sites.tar" "$SLICES/agent-host-source.tar" "$HOST:$RUN_DIR/" >/dev/null

# ── Step 3: Assemble .app bundle, sign, and create .dmg on the Mac ──
echo "==> Assembling .app bundle, signing, and creating .dmg..."
# ssh joins its arguments into one remote command line, so the identity (a Developer ID name has spaces and
# parentheses) travels single-quoted.
SIGN_IDENTITY_Q="'${SIGN_IDENTITY//\'/\'\\\'\'}'"
"${SSH[@]}" "$HOST" /bin/bash -s "$VERSION" "$APP_NAME" "$DMG_NAME" "$RUN_DIR" "$SIGN_IDENTITY_Q" \
  "$PYTHON_PKG_SHA" <<'REMOTE'
set -euo pipefail
VERSION="$1"
APP_NAME="$2"
DMG_NAME="$3"
SIGN_IDENTITY="${5:?}"
PYTHON_PKG_SHA="${6:?}"

cd "$HOME/${4:?}"
BINARY="zig-out/bin/zigBrowser"
SHIM_NAME="libwkwebview_shim.dylib"
SHIM="zig-out/Frameworks/$SHIM_NAME"
ARM_BINARY="zigBrowser-arm64"
ARM_SHIM="libwkwebview_shim-arm64.dylib"
for f in "$BINARY" "$SHIM" "$ARM_BINARY" "$ARM_SHIM"; do
  [ -f "$f" ] || { echo "ERROR: build output not found: $f" >&2; exit 1; }
done

APP_BUNDLE="${APP_NAME}.app"
CONTENTS="$APP_BUNDLE/Contents"

# Clean previous bundle
rm -rf "$APP_BUNDLE" "$DMG_NAME" dmg_staging

# Create .app structure
mkdir -p "$CONTENTS/MacOS"
mkdir -p "$CONTENTS/Resources"
mkdir -p "$CONTENTS/Frameworks"

# Join each native pair into the universal exe and the universal shim it loads
lipo -create "$BINARY" "$ARM_BINARY" -output "$CONTENTS/MacOS/$APP_NAME"
chmod 755 "$CONTENTS/MacOS/$APP_NAME"
lipo -create "$SHIM" "$ARM_SHIM" -output "$CONTENTS/Frameworks/$SHIM_NAME"
for f in "$CONTENTS/MacOS/$APP_NAME" "$CONTENTS/Frameworks/$SHIM_NAME"; do
  archs=$(lipo -archs "$f" | tr ' ' '\n' | LC_ALL=C sort | tr '\n' ' ')
  [ "$archs" = "arm64 x86_64 " ] || { echo "ERROR: $f holds '${archs% }', not exactly x86_64 and arm64" >&2; exit 1; }
done

# Stage the relocatable CPython framework, the agent-host package, and the two locked dependency trees before any
# signature is made. Non-code files are physically moved to Resources while relative links preserve their reviewed
# Frameworks/agent-host paths, so the signed Frameworks tree contains code only.
mkdir runtime-sites
tar -xf sites.tar -C runtime-sites
tar -xf agent-host-source.tar
bash packaging/macos/stage_agent_runtime.sh python.pkg "$PYTHON_PKG_SHA" "$CONTENTS" \
  runtime-sites/site-x86_64 runtime-sites/site-aarch64
/usr/bin/python3 -I packaging/macos/relocate_agent_data.py relocate "$CONTENTS"

# The exe's shim reference must resolve inside the bundle, or the app cannot start. otool's whole output is collected
# and its own status checked first, then searched: a pipe into grep -q would close at the first match, and an otool
# still writing would die of SIGPIPE under pipefail, failing a valid package (SilverRidge 2e8e0190).
SHIM_REF="@executable_path/../Frameworks/$SHIM_NAME"
OTOOL_OUT=$(otool -L "$CONTENTS/MacOS/$APP_NAME") \
  || { echo "ERROR: otool -L $CONTENTS/MacOS/$APP_NAME failed" >&2; exit 1; }
case "$OTOOL_OUT" in
  *"$SHIM_REF "*) ;;
  *) echo "ERROR: $CONTENTS/MacOS/$APP_NAME does not load $SHIM_REF" >&2; exit 1 ;;
esac
[ -f "$CONTENTS/MacOS/${SHIM_REF#@executable_path/}" ] \
  || { echo "ERROR: $SHIM_REF does not resolve inside $APP_BUNDLE" >&2; exit 1; }

# Stamp version into Info.plist (the commit's own, from this run dir's tree)
sed "s/__VERSION__/$VERSION/g" packaging/macos/Info.plist > "$CONTENTS/Info.plist"

# Generate .icns from PNG
ICONSET="${APP_NAME}.iconset"
rm -rf "$ICONSET"
mkdir "$ICONSET"
sips -z 16 16     packaging/assets/zigBrowser.png --out "$ICONSET/icon_16x16.png"      >/dev/null
sips -z 32 32     packaging/assets/zigBrowser.png --out "$ICONSET/icon_16x16@2x.png"   >/dev/null
sips -z 32 32     packaging/assets/zigBrowser.png --out "$ICONSET/icon_32x32.png"      >/dev/null
sips -z 64 64     packaging/assets/zigBrowser.png --out "$ICONSET/icon_32x32@2x.png"   >/dev/null
sips -z 128 128   packaging/assets/zigBrowser.png --out "$ICONSET/icon_128x128.png"    >/dev/null
sips -z 256 256   packaging/assets/zigBrowser.png --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256   packaging/assets/zigBrowser.png --out "$ICONSET/icon_256x256.png"    >/dev/null
iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/${APP_NAME}.icns"
rm -rf "$ICONSET"

# Sign inside out, never --deep. This includes every Mach-O in the staged Python framework and site-packages, then
# each real framework version, then the app. A release identity adds the hardened runtime; only the browser executable
# and app receive the committed entitlements manifest.
RUNTIME=() ENTITLEMENTS=()
if [ "$SIGN_IDENTITY" != - ]; then
  RUNTIME=(--options runtime)
  ENTITLEMENTS=(--entitlements packaging/macos/entitlements.plist)
fi
is_macho() { file -b "$1" | grep -q Mach-O; }
while IFS= read -r target; do
  if [ "$target" = "$CONTENTS/MacOS/$APP_NAME" ]; then
    codesign --force --sign "$SIGN_IDENTITY" ${RUNTIME[@]+"${RUNTIME[@]}"} \
      ${ENTITLEMENTS[@]+"${ENTITLEMENTS[@]}"} "$target"
  else
    codesign --force --sign "$SIGN_IDENTITY" ${RUNTIME[@]+"${RUNTIME[@]}"} "$target"
  fi
done < <(while IFS= read -r file; do is_macho "$file" && printf '%s\n' "$file"; done \
  < <(find "$CONTENTS" -type f) | awk -F/ '{ print NF "\t" $0 }' | sort -t $'\t' -k1,1nr -k2 | cut -f2-)
while IFS= read -r framework; do
  for version in "$framework"/Versions/*; do
    [ -d "$version" ] && [ ! -L "$version" ] \
      && codesign --force --sign "$SIGN_IDENTITY" ${RUNTIME[@]+"${RUNTIME[@]}"} "$version"
  done
done < <(find "$CONTENTS" -type d -name '*.framework')
codesign --force --sign "$SIGN_IDENTITY" ${RUNTIME[@]+"${RUNTIME[@]}"} ${ENTITLEMENTS[@]+"${ENTITLEMENTS[@]}"} "$APP_BUNDLE"

# Verify signature
codesign --verify --strict --deep --verbose "$APP_BUNDLE"

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
