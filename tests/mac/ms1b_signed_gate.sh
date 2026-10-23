#!/usr/bin/env bash
# MS1b GATE — "the signed x86_64 binary runs."
#
# This is the signed-bundle mirror of tests/mac/gate.sh. Where the MS1 gate installs the UNSIGNED
# universal exe + shim dylib and runs them (signing only an out-of-bundle exe copy for the static
# MS1.3 codesign -d check), THIS script SIGNS both the universal exe and the universal shim dylib
# (ad-hoc + entitlements), installs them as the runnable bundle (exe in bin/, dylib in Frameworks/),
# and RUNS the M9 workload + exec-arch probe against the signed pair, on BOTH Macs.
#
# Before MS1b's option-d fix the ad-hoc-signed x86_64 slice SIGSEGV'd in -[ZBAppHost init] [super
# init] (zig 0.16's classic LC_DYLD_INFO_ONLY rebases into the signed ObjC __DATA_CONST left the
# class/superclass pointers as on-disk garbage). The fix builds the ObjC shim as an Apple-toolchain
# chained-fixups dylib (build.zig configureMacosBackend), so the signed binary now runs. m9_render
# drives a navigation decision (zb_policy_decide) and m9_reply_channel an IPC call (zb_ipc_dispatch),
# so both of the dylib's exe back-references are exercised through the signed build.
#
# Fail-closed like gate.sh: verify_host runs under `if !`, which disables `set -e` inside the
# function, so every step is checked with an explicit `|| return 1`. A swallowed failure here
# would false-green MS1b — the one thing this gate must never do.
set -euo pipefail

ENTITLEMENTS="packaging/macos/entitlements.plist"

cd "$(git rev-parse --show-toplevel)"
# The Macs and the key come only from the explicit environment, never a default (bd 3ui.13): NOT RUN otherwise.
. tests/mac/mac_config.sh
mac_config two
# Each host builds one exact commit into its own fresh run dir; every remote file of this gate lives there (never in
# the shared home), and every ssh pins host keys (bd 4pa.59, 4pa.77).
. tests/mac/mac_gate_lib.sh
declare -A RUN_DIR=()   # host -> its run dir

# Local driver staging. Cleaned on exit with `find -delete` (RoseCat 6072) so the tmpfs-backed
# /tmp is reclaimed depth-first including the dir itself, even if a subpath is odd; the run dirs too.
STAGING="$(mktemp -d)"; trap 'mac_remove_run_dirs; find "$STAGING" -depth -delete 2>/dev/null || true' EXIT


# --- Phase 1: build each arch natively on its host (no -Dtarget) and fetch the slice. ---
build_and_fetch() {
  local host="$1" key="$2" arch="$3"
  local -a SCP; mapfile -d '' SCP < <(mac_scp_opts "$key")
  echo "== build $arch on $host ==" >&2
  mac_build "$host" "$key"
  RUN_DIR[$host]=$MAC_RDIR
  "${SCP[@]}" "$host:$MAC_RDIR/zig-out/bin/zigBrowser" "$STAGING/zigBrowser-$arch" >/dev/null
  test -s "$STAGING/zigBrowser-$arch"
  # The exe links the WKWebView ObjC shim dylib (MS1b option d); fetch the per-arch dylib too.
  "${SCP[@]}" "$host:$MAC_RDIR/zig-out/Frameworks/libwkwebview_shim.dylib" "$STAGING/shim-$arch.dylib" >/dev/null
  test -s "$STAGING/shim-$arch.dylib"
}
build_and_fetch "$INTEL_HOST" "$KEY" "x86_64"
build_and_fetch "$ARM_HOST" "$ARM_KEY" "arm64"

# --- Phase 2: lipo the universal exe AND the universal shim dylib, then SIGN BOTH (ad-hoc +
#     entitlements). Sign the dylib first, then the exe. Since MS1b's dylib fix (option d) the shim's
#     ObjC metadata lives in a chained-fixups dylib, so the signed binary RUNS. ---
echo "== assemble + SIGN universal exe + dylib on $INTEL_HOST (the RUNNABLE bundle) ==" >&2
intel_ssh=(); mapfile -d '' intel_ssh < <(mac_ssh_opts "$KEY")
intel_scp=(); mapfile -d '' intel_scp < <(mac_scp_opts "$KEY")
INTEL_DIR=${RUN_DIR[$INTEL_HOST]}
"${intel_scp[@]}" "$STAGING/zigBrowser-x86_64" "$STAGING/zigBrowser-arm64" "$INTEL_HOST:$INTEL_DIR/" >/dev/null
"${intel_scp[@]}" "$STAGING/shim-x86_64.dylib" "$STAGING/shim-arm64.dylib" "$INTEL_HOST:$INTEL_DIR/" >/dev/null
"${intel_ssh[@]}" "$INTEL_HOST" /bin/bash -s "$INTEL_DIR" <<'REMOTE'
set -euo pipefail
cd "$HOME/${1:?}"
lipo -create zigBrowser-x86_64 zigBrowser-arm64 -output zigBrowser-universal-signed
archs="$(lipo -archs zigBrowser-universal-signed)"
echo "universal archs: $archs"
case "$archs" in *x86_64*arm64*|*arm64*x86_64*) ;; *) echo "universal binary is not fat with both slices" >&2; exit 1;; esac
lipo -create shim-x86_64.dylib shim-arm64.dylib -output libwkwebview_shim-signed.dylib
darchs="$(lipo -archs libwkwebview_shim-signed.dylib)"
echo "shim dylib archs: $darchs"
case "$darchs" in *x86_64*arm64*|*arm64*x86_64*) ;; *) echo "shim dylib is not fat with both slices" >&2; exit 1;; esac
# Sign the dylib first, then the exe (both ad-hoc + entitlements).
codesign -s - --force libwkwebview_shim-signed.dylib
codesign -s - --entitlements packaging/macos/entitlements.plist --force zigBrowser-universal-signed
codesign --verify --verbose libwkwebview_shim-signed.dylib
codesign --verify --verbose zigBrowser-universal-signed
REMOTE
"${intel_scp[@]}" "$INTEL_HOST:$INTEL_DIR/zigBrowser-universal-signed" "$STAGING/zigBrowser-universal-signed" >/dev/null
"${intel_scp[@]}" "$INTEL_HOST:$INTEL_DIR/libwkwebview_shim-signed.dylib" "$STAGING/libwkwebview_shim-signed.dylib" >/dev/null
test -s "$STAGING/zigBrowser-universal-signed" && test -s "$STAGING/libwkwebview_shim-signed.dylib"

# --- Phase 3: install the SIGNED universal as the RUNNABLE bundle binary on each host and RUN it. ---
verify_host() {
  local host="$1" key="$2" expect="$3"
  local -a SSH SCP
  mapfile -d '' SSH < <(mac_ssh_opts "$key")
  mapfile -d '' SCP < <(mac_scp_opts "$key")
  local rd=${RUN_DIR[$host]}
  echo "== verify $expect on $host (SIGNED universal bundle RUNS, in $rd) ==" >&2
  # The SIGNED exe + SIGNED shim dylib become the bundle (MS1b runs THIS signed pair, unlike MS1
  # which runs the unsigned pair). The exe loads the dylib from @executable_path/../Frameworks.
  "${SCP[@]}" "$STAGING/zigBrowser-universal-signed" "$host:$rd/zig-out/bin/zigBrowser" >/dev/null || return 1
  "${SSH[@]}" "$host" "mkdir -p \"\$HOME/$rd/zig-out/Frameworks\"" || return 1
  "${SCP[@]}" "$STAGING/libwkwebview_shim-signed.dylib" "$host:$rd/zig-out/Frameworks/libwkwebview_shim.dylib" >/dev/null || return 1

  # M9 visible e2es + the exec-arch readback, against the SIGNED bundle. m9_render drives a
  # navigation decision (zb_policy_decide) and m9_reply_channel an IPC call (zb_ipc_dispatch) through
  # the dylib's two exe back-references (BlackRobin 6125). Before the option-d fix the signed x86_64
  # launch SIGSEGV'd in [ZBAppHost init]; it now runs (the shim's ObjC metadata is chained-fixups).
  # The expected arch "$expect" is passed as $1 so the (quoted) remote block can VERIFY the
  # signed binary runs AS this host's arch, not merely that it produced some output (RoseCat 6059).
  "${SSH[@]}" "$host" /bin/bash -s "$expect" "$rd" <<'REMOTE' || return 1
set -euo pipefail
EXPECT="$1"
cd "$HOME/${2:?}"
test -f tests/fixtures/app/index.html && test -f tests/fixtures/app/zbhost.js
export ZB_ENABLE_M9_E2E=1
unset ZB_M9_GUI_RUNNER
# --no-uniform-check (RoseCat 6072): Pillow is not installed on the Macs, so the local pixel
# uniformity oracle cannot run here. This red only needs the render to HAPPEN (title/nav observed)
# vs. the signed binary crashing; the full gate.sh routes the PNG to the Intel host's PIL for the
# non-uniform pixel check, and the MS1b green will do the same. The flag skips only that pixel step.
python3 tests/e2e/m9_render_test.py --browser zig-out/bin/zigBrowser --capture-path zig-out/m9-render.png --no-uniform-check
python3 tests/e2e/m9_reply_channel_test.py --browser zig-out/bin/zigBrowser
python3 tests/e2e/m9_load_fail_test.py --browser zig-out/bin/zigBrowser
rm -f zig-out/exec-arch.txt
python3 tests/mac/exec_arch_probe.py --browser zig-out/bin/zigBrowser --out zig-out/exec-arch.txt
test -s zig-out/exec-arch.txt
# Anti-false-pass (RoseCat 6059): "ran" means "ran AS $EXPECT natively", the same proof gate.sh
# makes. Normalize aarch64->arm64 (uname -m and zig's cpu tag), require BOTH the host's uname and
# the socket-read-back build.exec_arch to equal $EXPECT, and on arm require proc_translated=0.
# This rejects the same host configured twice (uname != the other leg's EXPECT) and an arm host
# running the x86_64 slice under Rosetta (proc_translated=1).
norm() { case "$1" in aarch64|arm64) echo arm64;; *) echo "$1";; esac; }
uname_m="$(uname -m)"
[ "$(norm "$uname_m")" = "$EXPECT" ] || { echo "uname -m $uname_m (norm $(norm "$uname_m")) != expected $EXPECT" >&2; exit 1; }
reported="$(tr -d '[:space:]' < zig-out/exec-arch.txt)"
[ "$(norm "$reported")" = "$EXPECT" ] || { echo "app reported exec_arch $reported (norm $(norm "$reported")) != expected $EXPECT" >&2; exit 1; }
if [ "$EXPECT" = arm64 ]; then
  # Fail-closed (RoseCat 6072): the probe itself must SUCCEED and report exactly 0, the same as
  # mac_universal_test.py's _run(...). A failed sysctl must NOT be read as "native" (0); on arm64
  # sysctl.proc_translated always exists, so a nonzero exit is a real problem, not Rosetta-absence.
  translated="$(sysctl -n sysctl.proc_translated)" || { echo "sysctl.proc_translated probe FAILED (not read as native)" >&2; exit 1; }
  [ "$translated" = 0 ] || { echo "process is translated (Rosetta): proc_translated=$translated" >&2; exit 1; }
fi
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
