#!/usr/bin/env bash
# MS1b RED (unregistered) — "the signed x86_64 binary runs."
#
# This is the signed-bundle mirror of tests/mac/gate.sh. Where the MS1 gate installs the
# UNSIGNED universal binary and runs it (and signs only an out-of-bundle copy for the static
# MS1.3 codesign -d check), THIS script installs the SIGNED universal binary as the runnable
# bundle binary and actually RUNS the M9 workload + the exec-arch probe against it, on BOTH Macs.
#
# TODAY this FAILS on the Intel/x86_64 leg: the ad-hoc-signed x86_64 slice segfaults in
# -[ZBAppHost init] [super init] (classic LC_DYLD_INFO_ONLY rebases into signed __DATA_CONST
# leave the ObjC class/superclass pointers as on-disk garbage ~0xf0000001). The arm64 leg runs.
# Gate(MS1b) turns green only once option (d) (the ObjC shim built as an Apple-toolchain
# chained-fixups dylib) lands. This file is NOT registered in build.zig while it is red
# (red-commits-outside-the-gate discipline); the green registers the signed-bundle assertion.
#
# Fail-closed like gate.sh: verify_host runs under `if !`, which disables `set -e` inside the
# function, so every step is checked with an explicit `|| return 1`. A swallowed failure here
# would false-green MS1b — the one thing this red must never do.
set -euo pipefail

KEY="${ZB_MAC_KEY:-/home/maceo/vms/mac-m9/zb_mac_key}"
INTEL_HOST="${ZB_MAC_HOST:-maceojourdan@100.92.212.47}"
ARM_HOST="${ZB_MAC_ARM_HOST:-}"
ARM_KEY="${ZB_MAC_ARM_KEY:-$KEY}"
ENTITLEMENTS="packaging/macos/entitlements.plist"

cd "$(git rev-parse --show-toplevel)"

ssh_opts() { printf '%s\0' ssh -i "$1" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=10; }
scp_opts() { printf '%s\0' scp -i "$1" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=15; }

STAGING="$(mktemp -d)"; trap 'rm -rf "$STAGING"' EXIT

if [ -z "$ARM_HOST" ]; then
  echo "NOT RUN: arm64 host not configured (set ZB_MAC_ARM_HOST=user@host)" >&2
  echo "        the MS1b signed two-arch gate is INCOMPLETE and cannot pass until it runs" >&2
  exit 1
fi

# --- Phase 1: build each arch natively on its host (no -Dtarget) and fetch the slice. ---
build_and_fetch() {
  local host="$1" key="$2" arch="$3"
  local -a SCP; mapfile -d '' SCP < <(scp_opts "$key")
  echo "== build $arch on $host ==" >&2
  ZB_MAC_HOST="$host" ZB_MAC_KEY="$key" bash tests/mac/build-on-mac.sh
  "${SCP[@]}" "$host:zigBrowser/zig-out/bin/zigBrowser" "$STAGING/zigBrowser-$arch" >/dev/null
  test -s "$STAGING/zigBrowser-$arch"
}
build_and_fetch "$INTEL_HOST" "$KEY" "x86_64"
build_and_fetch "$ARM_HOST" "$ARM_KEY" "arm64"

# --- Phase 2: lipo the universal and SIGN it (the binary we will RUN). ad-hoc + entitlements,
#     the same signature MS1 applies to its out-of-bundle copy; this is what today crashes. ---
echo "== assemble + SIGN universal on $INTEL_HOST (the RUNNABLE binary) ==" >&2
intel_ssh=(); mapfile -d '' intel_ssh < <(ssh_opts "$KEY")
intel_scp=(); mapfile -d '' intel_scp < <(scp_opts "$KEY")
"${intel_scp[@]}" "$STAGING/zigBrowser-x86_64" "$STAGING/zigBrowser-arm64" "$INTEL_HOST:" >/dev/null
"${intel_ssh[@]}" "$INTEL_HOST" /bin/bash -s <<'REMOTE'
set -euo pipefail
cd "$HOME/zigBrowser"
lipo -create "$HOME/zigBrowser-x86_64" "$HOME/zigBrowser-arm64" -output "$HOME/zigBrowser-universal-signed"
archs="$(lipo -archs "$HOME/zigBrowser-universal-signed")"
echo "universal archs: $archs"
case "$archs" in *x86_64*arm64*|*arm64*x86_64*) ;; *) echo "universal binary is not fat with both slices" >&2; exit 1;; esac
codesign -s - --entitlements packaging/macos/entitlements.plist --force "$HOME/zigBrowser-universal-signed"
codesign --verify --verbose "$HOME/zigBrowser-universal-signed"
REMOTE
"${intel_scp[@]}" "$INTEL_HOST:zigBrowser-universal-signed" "$STAGING/zigBrowser-universal-signed" >/dev/null
test -s "$STAGING/zigBrowser-universal-signed"

# --- Phase 3: install the SIGNED universal as the RUNNABLE bundle binary on each host and RUN it. ---
verify_host() {
  local host="$1" key="$2" expect="$3"
  local -a SSH SCP
  mapfile -d '' SSH < <(ssh_opts "$key")
  mapfile -d '' SCP < <(scp_opts "$key")
  echo "== verify $expect on $host (SIGNED universal binary RUNS) ==" >&2
  # The SIGNED binary becomes the bundle binary (MS1b runs THIS, unlike MS1 which runs unsigned).
  "${SCP[@]}" "$STAGING/zigBrowser-universal-signed" "$host:zigBrowser/zig-out/bin/zigBrowser" >/dev/null || return 1

  # M9 visible e2es + the exec-arch readback, against the SIGNED binary. On x86_64 today the
  # first launch SIGSEGVs in [ZBAppHost init] [super init], so m9_render_test fails -> red.
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
test -s zig-out/exec-arch.txt
REMOTE
  printf 'PASS\tms1b-signed-leg\t%s\t%s\n' "$host" "$expect"
}

overall=0
if ! verify_host "$INTEL_HOST" "$KEY" "x86_64"; then echo "FAIL: intel/x86_64 signed leg (expected RED today)" >&2; overall=1; fi
if ! verify_host "$ARM_HOST" "$ARM_KEY" "arm64"; then echo "FAIL: arm64 signed leg" >&2; overall=1; fi

if [ "$overall" -eq 0 ]; then
  printf 'PASS\tms1b-signed-gate\tboth-arches\n'
else
  echo "MS1b signed gate: INCOMPLETE or FAILED (see legs above)" >&2
fi
exit "$overall"
