#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
DEB_PATH=${1:-"$REPO_ROOT/zigBrowser_0.2.0_amd64.deb"}
OUT_DIR=${ZB_DEB_GATE_OUT_DIR:-/tmp/zigbrowser-deb-gate}
PNG_PATH=$OUT_DIR/page.png
PILLOW_TOOL=$REPO_ROOT/tests/snapshots/pillow_tools.py

if [ ! -f "$DEB_PATH" ]; then
  "$SCRIPT_DIR/build-deb.sh" >/dev/null
fi

if command -v docker >/dev/null 2>&1; then
  RUNNER=docker
elif command -v podman >/dev/null 2>&1; then
  RUNNER=podman
else
  echo "missing docker or podman" >&2
  exit 77
fi

mkdir -p "$OUT_DIR"
rm -f "$PNG_PATH"

"$RUNNER" run --rm \
  -v "$(realpath "$DEB_PATH"):/tmp/zigBrowser.deb:ro" \
  -v "$OUT_DIR:/out" \
  debian:stable sh -eu -c '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y /tmp/zigBrowser.deb
    apt-get install -y xvfb
    cat > /tmp/zigbrowser-gate.html <<EOF
<!doctype html>
<html>
  <head>
    <meta charset="utf-8">
    <title>zigBrowser Debian Gate</title>
    <style>
      body { margin: 48px; font: 32px sans-serif; color: #1f2937; background: #f8fafc; }
      h1 { color: #155e75; }
    </style>
  </head>
  <body>
    <h1>zigBrowser Debian Gate</h1>
    <p>Rendered inside a clean Debian container.</p>
  </body>
</html>
EOF
    xvfb-run -a /usr/bin/zigBrowser --screenshot /out/page.png file:///tmp/zigbrowser-gate.html
    test -s /out/page.png
    chmod 0644 /out/page.png
    dpkg -r zigbrowser
    test ! -e /usr/bin/zigBrowser
    test ! -e /usr/share/applications/zigBrowser.desktop
    test ! -e /usr/share/icons/hicolor/256x256/apps/zigBrowser.png
  '

python3 "$PILLOW_TOOL" nonuniform "$PNG_PATH"
printf '%s\n' "$PNG_PATH"
