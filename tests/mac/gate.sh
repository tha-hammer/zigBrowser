#!/usr/bin/env bash
# M9 macOS WKWebView visible gate.
#
# WKWebView needs the logged-in WindowServer session. The Mac channel logs in
# as the active console user, so run directly as that user. Do not use
# `launchctl asuser` here; this SSH user is already the console user and the
# bootstrap switch needs root on this host.
#
# The render oracle intentionally uses `zigBrowser --screenshot`, which calls
# the backend's WKWebView takeSnapshot path. Do not replace it with full-screen
# `screencapture`; that can capture wallpaper or another stacked window.
set -euo pipefail

KEY="${ZB_MAC_KEY:-/home/maceo/vms/mac-m9/zb_mac_key}"
HOST="${ZB_MAC_HOST:-maceojourdan@100.92.212.47}"
SSH=(ssh -i "$KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no \
     -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=15 \
     -o ServerAliveInterval=10)
SCP=(scp -i "$KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no \
     -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=15)

cd "$(git rev-parse --show-toplevel)"

bash tests/mac/build-on-mac.sh

mkdir -p zig-out
local_png="zig-out/m9-render.png"
remote_png="zigBrowser/zig-out/m9-render.png"

"${SSH[@]}" "$HOST" /bin/bash -s <<'REMOTE'
set -euo pipefail
cd "$HOME/zigBrowser"
test -f tests/fixtures/app/index.html
test -f tests/fixtures/app/zbhost.js
export ZB_ENABLE_M9_E2E=1
unset ZB_M9_GUI_RUNNER
python3 tests/e2e/m9_render_test.py \
  --browser zig-out/bin/zigBrowser \
  --capture-path zig-out/m9-render.png
python3 tests/e2e/m9_reply_channel_test.py \
  --browser zig-out/bin/zigBrowser
python3 tests/e2e/m9_load_fail_test.py \
  --browser zig-out/bin/zigBrowser
REMOTE

"${SCP[@]}" "$HOST:$remote_png" "$local_png" >/dev/null
python3 tests/snapshots/pillow_tools.py nonuniform "$local_png"
printf 'PASS\tm9-mac-gate\t%s\n' "$local_png"
