#!/usr/bin/env bash
# macOS gate — MS1 two-host universal/arch matrix + the M9 WKWebView visible gate.
#
# MS1 (plan rev 6, ed13e5e): a two-host, two-arch gate that CANNOT false-green.
#   - Intel (x86_64) host: ZB_MAC_HOST (configured; the existing stable channel).
#   - Apple Silicon (arm64) host: ZB_MAC_ARM_HOST (a CONFIG VALUE). When it is unset the
#     arm64 leg is SKIPPED with a loud "NOT RUN: arm64 host not configured" line and is
#     NEVER counted as a pass; the overall universal gate then exits nonzero (fail closed,
#     MS1.4) because a universal gate's job is both arches. No silent-pass knob exists.
#
# WKWebView needs the logged-in WindowServer session. The Mac channel logs in as the active
# console user, so run directly as that user. Do not use `launchctl asuser`. The render oracle
# uses `zigBrowser --screenshot` (the WKWebView takeSnapshot path), never full-screen
# `screencapture`, which can capture wallpaper or another stacked window.
set -euo pipefail

KEY="${ZB_MAC_KEY:-/home/maceo/vms/mac-m9/zb_mac_key}"
INTEL_HOST="${ZB_MAC_HOST:-maceojourdan@100.92.212.47}"
# arm64 target: unset by default until the user supplies the Apple Silicon host+SSH user.
ARM_HOST="${ZB_MAC_ARM_HOST:-}"
ARM_KEY="${ZB_MAC_ARM_KEY:-$KEY}"

cd "$(git rev-parse --show-toplevel)"

ssh_opts() { # $1=key
  printf '%s\0' ssh -i "$1" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=10
}

# Run one host leg: native build (no -Dtarget), the M9 visible e2es, then the MS1 universal
# assertions. Returns 0 on PASS, nonzero on any failure (fail closed).
run_leg() { # $1=host  $2=key  $3=expect_arch (x86_64|arm64)
  local host="$1" key="$2" expect="$3"
  local -a SSH SCP
  mapfile -d '' SSH < <(ssh_opts "$key")
  SCP=(scp -i "$key" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=15)

  echo "== leg: $host (expect $expect) =="
  # Native per-arch build on this host (build-on-mac.sh honours ZB_MAC_HOST/ZB_MAC_KEY).
  ZB_MAC_HOST="$host" ZB_MAC_KEY="$key" bash tests/mac/build-on-mac.sh

  mkdir -p zig-out
  local local_png="zig-out/m9-render-${expect}.png"
  local remote_png="zigBrowser/zig-out/m9-render.png"

  # M9 visible render + reply + load-fail (retained verbatim), plus report the EXECUTING arch
  # the running app sees over the socket into /tmp for the MS1.2 readback.
  "${SSH[@]}" "$host" /bin/bash -s <<'REMOTE'
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
# MS1.2 executing-arch readback over the automation socket.
# FINALIZE-ON-MAC: launch the browser, open its automation socket, and write the app's
# reported build_info.exec_arch to zig-out/exec-arch.txt. This is wired once BuildInfo.exec_arch
# (src/automation/telemetry.zig) is exposed in a socket reply and confirmed on the Mac. Until
# then the file stays absent and mac_universal_test fails closed on the missing --reported-arch
# (that is the intended RED for MS1.2 — a skip must never turn the gate green).
rm -f zig-out/exec-arch.txt
REMOTE

  "${SCP[@]}" "$host:$remote_png" "$local_png" >/dev/null
  python3 tests/snapshots/pillow_tools.py nonuniform "$local_png"

  # Pull the reported arch (if the probe produced it) and run the MS1 universal assertions
  # ON the Mac (lipo/codesign/sysctl/uname live there).
  local reported_arg=()
  if "${SSH[@]}" "$host" 'test -s "$HOME/zigBrowser/zig-out/exec-arch.txt"'; then
    local reported
    reported="$("${SSH[@]}" "$host" 'cat "$HOME/zigBrowser/zig-out/exec-arch.txt"' | tr -d '[:space:]')"
    reported_arg=(--reported-arch "$reported")
  fi
  "${SSH[@]}" "$host" /bin/bash -s "$expect" <<REMOTE
set -euo pipefail
cd "\$HOME/zigBrowser"
python3 tests/e2e/mac_universal_test.py \
  --binary zig-out/bin/zigBrowser \
  --expect-arch "$expect" \
  --entitlements packaging/macos/entitlements.plist \
  ${reported_arg[*]+${reported_arg[*]}}
REMOTE

  printf 'PASS\tmac-leg\t%s\t%s\n' "$host" "$expect"
}

overall=0

# --- Intel (x86_64) leg: always runs ---
if ! run_leg "$INTEL_HOST" "$KEY" "x86_64"; then
  echo "FAIL: intel/x86_64 leg" >&2
  overall=1
fi

# --- Apple Silicon (arm64) leg: config-gated, loud NOT-RUN, never a silent pass ---
if [ -n "$ARM_HOST" ]; then
  if ! run_leg "$ARM_HOST" "$ARM_KEY" "arm64"; then
    echo "FAIL: arm64 leg" >&2
    overall=1
  fi
else
  echo "NOT RUN: arm64 host not configured (set ZB_MAC_ARM_HOST=user@host to enable)" >&2
  echo "        the universal two-arch gate is INCOMPLETE and cannot pass until it runs" >&2
  overall=1   # fail closed: a universal gate requires both arches (MS1.2/MS1.4)
fi

if [ "$overall" -eq 0 ]; then
  printf 'PASS\tmac-universal-gate\tboth-arches\n'
else
  echo "mac gate: INCOMPLETE or FAILED (see legs above)" >&2
fi
exit "$overall"
