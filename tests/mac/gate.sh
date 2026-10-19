#!/usr/bin/env bash
# macOS gate — MS1 two-host UNIVERSAL build + arch matrix + the M9 WKWebView visible gate.
#
# MS1 (plan rev 6-9): a two-host, two-arch gate that CANNOT false-green.
#   - Intel (x86_64): ZB_MAC_HOST (the stable channel); also the universal-assembly host.
#   - Apple Silicon (arm64): ZB_MAC_ARM_HOST (a config value). When it is unset the gate
#     prints a loud "NOT RUN: arm64 host not configured" and exits nonzero (fail closed,
#     MS1.4) — a universal gate needs BOTH arches, and there is no silent-pass knob.
#
# Flow: build each arch NATIVELY on its host (no -Dtarget); `lipo -create` the two browser slices
# into one fat Mach-O on the Intel host. MS1 RUNS the UNSIGNED universal: push it to BOTH hosts and
# on each verify MS1.1 (the component census sees a fat Mach-O), MS1.2 (the running app reports its
# EXECUTING slice's arch over the socket — the loader picks the host's slice, so this rules out
# Rosetta), plus the M9 visible render/reply/load-fail. Separately, ad-hoc codesign a COPY with
# packaging/macos/entitlements.plist and inspect it STATICALLY for MS1.3 (the signed entitlements
# equal the manifest, via `codesign -d` — never run; running a signed binary is MS1b).
# The MS1 resource phase gate (mac_resource_compat.py --milestone MS1) runs on the driver.
#
# WKWebView needs the logged-in WindowServer session. The Mac channel logs in as the active
# console user, so run directly as that user (no `launchctl asuser`). The render oracle uses
# `zigBrowser --screenshot` (the WKWebView takeSnapshot path), never full-screen `screencapture`.
set -euo pipefail

KEY="${ZB_MAC_KEY:-/home/maceo/vms/mac-m9/zb_mac_key}"
INTEL_HOST="${ZB_MAC_HOST:-maceojourdan@100.92.212.47}"
ARM_HOST="${ZB_MAC_ARM_HOST:-}"
ARM_KEY="${ZB_MAC_ARM_KEY:-$KEY}"
ENTITLEMENTS="packaging/macos/entitlements.plist"
MANIFEST="packaging/macos/universal_components.json"

cd "$(git rev-parse --show-toplevel)"

ssh_opts() { # $1=key -> NUL-delimited ssh argv
  printf '%s\0' ssh -i "$1" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=10
}
scp_opts() { # $1=key -> NUL-delimited scp argv
  printf '%s\0' scp -i "$1" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=15
}

STAGING="$(mktemp -d)"
# Reclaim the throwaway staging tree depth-first on exit (standing cleanup rule, RoseCat 6101).
trap 'find "$STAGING" -depth -delete 2>/dev/null || true' EXIT

# --- MS1.4: the arm64 host is mandatory for a universal gate. Fail closed before building. ---
if [ -z "$ARM_HOST" ]; then
  echo "NOT RUN: arm64 host not configured (set ZB_MAC_ARM_HOST=user@host to enable)" >&2
  echo "        the universal two-arch gate is INCOMPLETE and cannot pass until it runs" >&2
  exit 1
fi

# --- Phase 1: build each arch natively on its host and fetch the per-arch browser slice. ---
build_and_fetch() { # $1=host  $2=key  $3=arch
  local host="$1" key="$2" arch="$3"
  local -a SCP; mapfile -d '' SCP < <(scp_opts "$key")
  echo "== build $arch on $host ==" >&2
  ZB_MAC_HOST="$host" ZB_MAC_KEY="$key" bash tests/mac/build-on-mac.sh
  "${SCP[@]}" "$host:zigBrowser/zig-out/bin/zigBrowser" "$STAGING/zigBrowser-$arch" >/dev/null
  test -s "$STAGING/zigBrowser-$arch"
}
build_and_fetch "$INTEL_HOST" "$KEY" "x86_64"
build_and_fetch "$ARM_HOST" "$ARM_KEY" "arm64"

# --- Phase 2: assemble the universal binary on the Intel host. We lipo an UNSIGNED universal
#     (this is what MS1 RUNS for MS1.1/MS1.2), and ad-hoc sign a COPY for the STATIC MS1.3
#     `codesign -d` check only. MS1 does NOT prove a signed binary RUNS — an ad-hoc-signed
#     x86_64 binary segfaults in ObjC init (zig-linker/codesign interaction); that is MS1b's job.
echo "== assemble universal (lipo unsigned + sign a copy) on $INTEL_HOST ==" >&2
intel_ssh=(); mapfile -d '' intel_ssh < <(ssh_opts "$KEY")
intel_scp=(); mapfile -d '' intel_scp < <(scp_opts "$KEY")
"${intel_scp[@]}" "$STAGING/zigBrowser-x86_64" "$STAGING/zigBrowser-arm64" "$INTEL_HOST:" >/dev/null
"${intel_ssh[@]}" "$INTEL_HOST" /bin/bash -s <<'REMOTE'
set -euo pipefail
cd "$HOME/zigBrowser"
lipo -create "$HOME/zigBrowser-x86_64" "$HOME/zigBrowser-arm64" -output "$HOME/zigBrowser-universal"
archs="$(lipo -archs "$HOME/zigBrowser-universal")"
echo "universal archs: $archs"
case "$archs" in *x86_64*arm64*|*arm64*x86_64*) ;; *) echo "universal binary is not fat with both slices" >&2; exit 1;; esac
# Sign a COPY for the static MS1.3 entitlements check (never run — running it is MS1b).
cp "$HOME/zigBrowser-universal" "$HOME/zigBrowser-universal-signed"
codesign -s - --entitlements packaging/macos/entitlements.plist --force "$HOME/zigBrowser-universal-signed"
codesign --verify --verbose "$HOME/zigBrowser-universal-signed"
REMOTE
"${intel_scp[@]}" "$INTEL_HOST:zigBrowser-universal" "$STAGING/zigBrowser-universal" >/dev/null
"${intel_scp[@]}" "$INTEL_HOST:zigBrowser-universal-signed" "$STAGING/zigBrowser-universal-signed" >/dev/null
test -s "$STAGING/zigBrowser-universal" && test -s "$STAGING/zigBrowser-universal-signed"

# --- MS1 resource phase gate (driver, pure python): the browser-only inventory is the only
#     empty-resource shape the gate accepts for MS1 (RoseCat 6002). Called, not skipped. ---
echo "== resource phase gate (--milestone MS1) ==" >&2
python3 tests/e2e/mac_resource_compat.py --manifest "$MANIFEST" --milestone MS1 zig-out zig-out

# --- Phase 3: push the ONE universal signed binary to each host and verify there. ---
verify_host() { # $1=host  $2=key  $3=expect_arch
  local host="$1" key="$2" expect="$3"
  local -a SSH SCP
  mapfile -d '' SSH < <(ssh_opts "$key")
  mapfile -d '' SCP < <(scp_opts "$key")
  echo "== verify $expect on $host (universal binary) ==" >&2
  # NOTE: this function is invoked under `if ! verify_host`, which DISABLES `set -e` inside it
  # (bash gotcha). So every step below is checked EXPLICITLY with `|| return 1` — a swallowed
  # failure here would false-green the universal gate, the one thing MS1 must never do.

  # Install the UNSIGNED universal binary over this host's per-arch build (MS1 RUNS this one).
  "${SCP[@]}" "$STAGING/zigBrowser-universal" "$host:zigBrowser/zig-out/bin/zigBrowser" >/dev/null || return 1
  # The ad-hoc-signed COPY goes OUTSIDE the bundle (~/zigBrowser-universal-signed), so the component
  # census doesn't scan it; it is only read statically by `codesign -d` for MS1.3 (never run).
  "${SCP[@]}" "$STAGING/zigBrowser-universal-signed" "$host:zigBrowser-universal-signed" >/dev/null || return 1

  local local_png="zig-out/m9-render-${expect}.png"
  # M9 visible e2es on the universal binary (the loader runs this host's slice), then the MS1.2
  # exec-arch readback. The probe writes nothing on failure, so MS1.2 fails closed.
  "${SSH[@]}" "$host" /bin/bash -s <<'REMOTE' || return 1
set -euo pipefail
cd "$HOME/zigBrowser"
test -f tests/fixtures/app/index.html && test -f tests/fixtures/app/zbhost.js
export ZB_ENABLE_M9_E2E=1
unset ZB_M9_GUI_RUNNER
python3 tests/e2e/m9_render_test.py --browser zig-out/bin/zigBrowser --capture-path zig-out/m9-render.png --no-uniform-check
python3 tests/e2e/m9_reply_channel_test.py --browser zig-out/bin/zigBrowser
python3 tests/e2e/m9_load_fail_test.py --browser zig-out/bin/zigBrowser
rm -f zig-out/exec-arch.txt
python3 tests/mac/exec_arch_probe.py --browser zig-out/bin/zigBrowser --out zig-out/exec-arch.txt
REMOTE

  # The render-nonuniform oracle needs Pillow, which is only on the Intel host (not the arm Mac,
  # not the Linux driver). Route this leg's PNG to the Intel host's PIL (pixel analysis is
  # arch-independent; the render still happened on $host). Fail closed if it cannot run or is blank.
  "${SCP[@]}" "$host:zigBrowser/zig-out/m9-render.png" "$STAGING/m9-render-$expect.png" >/dev/null || return 1
  "${intel_scp[@]}" "$STAGING/m9-render-$expect.png" "$INTEL_HOST:m9-render-check.png" >/dev/null || return 1
  "${intel_ssh[@]}" "$INTEL_HOST" 'cd "$HOME/zigBrowser" && python3 tests/snapshots/pillow_tools.py nonuniform "$HOME/m9-render-check.png"' || return 1

  # The runtime readback is MANDATORY (MS1.2): absent -> mac_universal_test fails closed.
  local reported_arg=()
  if "${SSH[@]}" "$host" 'test -s "$HOME/zigBrowser/zig-out/exec-arch.txt"'; then
    local reported
    reported="$("${SSH[@]}" "$host" 'cat "$HOME/zigBrowser/zig-out/exec-arch.txt"' | tr -d '[:space:]')"
    reported_arg=(--reported-arch "$reported")
  fi
  # MS1.1 (census, unsigned --binary), MS1.2 (executing-arch readback) and MS1.3 (the SIGNED
  # copy's entitlements via static `codesign -d`, --signed-binary) run ON the Mac
  # (lipo/codesign/sysctl/uname live there).
  "${SSH[@]}" "$host" /bin/bash -s "$expect" <<REMOTE || return 1
set -euo pipefail
cd "\$HOME/zigBrowser"
python3 tests/e2e/mac_universal_test.py \
  --binary zig-out/bin/zigBrowser \
  --bundle-root zig-out \
  --components-manifest $MANIFEST \
  --expect-arch "$expect" \
  --entitlements $ENTITLEMENTS \
  --signed-binary "\$HOME/zigBrowser-universal-signed" \
  ${reported_arg[*]+${reported_arg[*]}}
REMOTE
  printf 'PASS\tmac-leg\t%s\t%s\n' "$host" "$expect"
}

overall=0
if ! verify_host "$INTEL_HOST" "$KEY" "x86_64"; then echo "FAIL: intel/x86_64 leg" >&2; overall=1; fi
if ! verify_host "$ARM_HOST" "$ARM_KEY" "arm64"; then echo "FAIL: arm64 leg" >&2; overall=1; fi

if [ "$overall" -eq 0 ]; then
  printf 'PASS\tmac-universal-gate\tboth-arches\n'
else
  echo "mac gate: INCOMPLETE or FAILED (see legs above)" >&2
fi
exit "$overall"
