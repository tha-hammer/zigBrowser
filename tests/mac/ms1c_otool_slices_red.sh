#!/usr/bin/env bash
# RED, UNREGISTERED (zigBrowser-4pa.73): otool -L may print one dependency block per Mach-O slice.
# The MS1c gate must accept the aggregate form with one shim reference, and for the per-slice form require exactly
# one shim reference in each of the x86_64 and arm64 blocks. This file stays absent from build.zig until the green.
#
# This reuses the registered MS1c executing fake-Mac fixture only through its setup boundary, replaces that fixture's
# otool with the four output shapes below, and drives the real tests/mac/ms1c_app_gate.sh for every row.
set -uo pipefail

ROOT=$(realpath "${1:-.}")
SOURCE="$ROOT/tests/mac/ms1c_app_gate_selftest.sh"
BASE=$(mktemp -d "${TMPDIR:-/tmp}/zb-ms1c-otool-red-XXXXXX") || exit 1
case "$BASE" in "${TMPDIR:-/tmp}"/zb-ms1c-otool-red-??????) ;; *) echo "FAIL: unsafe temp path: $BASE" >&2; exit 1 ;; esac
cleanup() { rm -rf -- "${BASE:?}"; }
trap cleanup EXIT

marker=$(grep -nFx '# ── Base run ──' "$SOURCE" | cut -d: -f1)
[ -n "$marker" ] && [ "$(grep -cFx '# ── Base run ──' "$SOURCE")" -eq 1 ] || {
  echo "FAIL: could not find the unique MS1c fixture boundary" >&2; exit 1;
}
DRIVER="$BASE/driver.sh"
head -n "$marker" "$SOURCE" > "$DRIVER" || exit 1
cat >> "$DRIVER" <<'DRIVER'

# Replace only the fake otool. All transports, packaging, app-gate control flow, evidence and cleanup remain the real
# executing MS1c fixture. The mode files are per-role so the Intel control can retain the older aggregate output while
# arm64 drives the newer slice-expanded output observed in the released run.
cat > "$X/hostbin/otool" <<EOF
#!/bin/bash
$rec
$on
[ "\$1" = -L ] || exit 0
shim='@executable_path/../Frameworks/libwkwebview_shim.dylib'
ref() { printf '\t%s (compatibility version 0.0.0, current version 0.0.0)\n' "\$shim"; }
sys() { printf '\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1356.0.0)\n'; }
if on otool_multislice_ok; then
  printf '%s (architecture x86_64):\n' "\$2"; ref; sys
  printf '%s (architecture arm64):\n' "\$2"; ref; sys
elif on otool_multislice_missing; then
  printf '%s (architecture x86_64):\n' "\$2"; ref; sys
  printf '%s (architecture arm64):\n' "\$2"; sys
elif on otool_multislice_duplicate; then
  printf '%s (architecture x86_64):\n' "\$2"; ref; ref; sys
  printf '%s (architecture arm64):\n' "\$2"; ref; sys
else
  printf '%s:\n' "\$2"; ref; sys
fi
EOF
chmod 755 "$X/hostbin/otool"

SHIM='@executable_path/../Frameworks/libwkwebview_shim.dylib'
slice_refs() { # slice_refs <arch> <otool.out>
  awk -v arch="$1" -v shim="$SHIM" '
    /^.* \(architecture [^)]+\):$/ { active = index($0, "(architecture " arch "):") > 0; next }
    active && index($0, "\t" shim " (") == 1 { count++ }
    END { print count + 0 }
  ' "$2"
}
expect_pass() { [ "$rc" -eq 0 ] && leg_is x86_64 PASS && leg_is arm64 PASS && ! no_pass; }
expect_arm_fail() { [ "$rc" -eq 1 ] && leg_is x86_64 PASS && leg_is arm64 FAIL && no_pass; }

# Compatibility control: the older aggregate otool output names the shim once and remains accepted.
run_gate aggregate
if expect_pass && grep -qxF "  arm64: OTOOL${TB}rc=0${TB}refs=1" "$OUT"; then
  ok "O1: aggregate otool output with one shim reference is accepted"
else
  bad "O1: aggregate control exit $rc: $(tailout)"
fi

# Released arm64 shape: each architecture block names the shim exactly once. The current global count reports refs=2
# and rejects this valid app; the green must count within each slice rather than demand one line in the whole output.
run_gate multislice-ok otool_multislice_ok.arm
OT="$EV/arm64/evidence/otool.out"
shape="$(slice_refs x86_64 "$OT")/$(slice_refs arm64 "$OT")"
if [ "$shape" = 1/1 ] && expect_pass; then
  ok "O2: x86_64 and arm64 blocks with one shim reference each are accepted"
else
  bad "O2: valid per-slice shape $shape exited $rc: $(grep 'arm64: OTOOL\|arm64: REASON' "$OUT" | tr '\n' '|')"
fi

# A global count of one is not sufficient: one slice may name the shim while the other omits it.
run_gate multislice-missing otool_multislice_missing.arm
OT="$EV/arm64/evidence/otool.out"
shape="$(slice_refs x86_64 "$OT")/$(slice_refs arm64 "$OT")"
if [ "$shape" = 1/0 ] && expect_arm_fail; then
  ok "O3: a missing arm64 shim reference is rejected"
else
  bad "O3: missing-slice shape $shape exited $rc: $(grep 'arm64: OTOOL\|arm64: REASON' "$OUT" | tr '\n' '|')"
fi

# Exact-once negative control: a duplicate in either slice is rejected.
run_gate multislice-duplicate otool_multislice_duplicate.arm
OT="$EV/arm64/evidence/otool.out"
shape="$(slice_refs x86_64 "$OT")/$(slice_refs arm64 "$OT")"
if [ "$shape" = 2/1 ] && expect_arm_fail; then
  ok "O4: a duplicate x86_64 shim reference is rejected"
else
  bad "O4: duplicate-slice shape $shape exited $rc: $(grep 'arm64: OTOOL\|arm64: REASON' "$OUT" | tr '\n' '|')"
fi

if [ "$fails" -eq 0 ]; then
  printf 'PASS\tms1c-otool-slices-red\t4/4\n'
  exit 0
fi
printf 'FAIL\tms1c-otool-slices-red\t%s/4 failed\n' "$fails"
exit 1
DRIVER
chmod 700 "$DRIVER"

bash "$DRIVER" "$ROOT"
