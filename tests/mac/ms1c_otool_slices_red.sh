#!/usr/bin/env bash
# REGISTERED GREEN ORACLE (zigBrowser-4pa.73): query each universal executable slice independently. The MS1c gate must run
# exactly one `otool -arch <slice> -L <exe>` for x86_64 and arm64, retain separate output/status/ref evidence, and
# require status zero plus exactly one exact shim dependency from each call. Registered by the green approved from
# eb214b4e. Fix-forward minimum: SilverRidge 9bb0737e (the first red allowed a combined-output parser to survive).
#
# This reuses the registered MS1c executing fake-Mac fixture only through its setup boundary, replaces that fixture's
# otool with the executing slice/status/output shapes below, and drives the real gate for every row.
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
# executing MS1c fixture. Every invocation is recorded with its fake-host role. A required per-slice invocation gets
# output and status unique to that requested slice; the legacy -L branch models a surviving combined-output parser.
cat > "$X/hostbin/otool" <<EOF
#!/bin/bash
$rec
$on
shim='@executable_path/../Frameworks/libwkwebview_shim.dylib'
ref() { printf '\t%s (compatibility version 0.0.0, current version 0.0.0)\n' "\$shim"; }
wrong() { printf '\t@executable_path/../Frameworks/libwrong-%s.dylib (compatibility version 0.0.0, current version 0.0.0)\n' "\$1"; }
later() { printf '\t/usr/lib/libSlice-%s.dylib (compatibility version 1.0.0, current version 1.0.0)\n' "\$1"; }
sys() { printf '\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1356.0.0)\n'; }
emit_one() { # emit_one <slice> <exe>: output and status are controlled independently for this slice
  a=\$1 exe=\$2
  if on otool_aggregate; then printf '%s:\n' "\$exe"; else printf '%s (architecture %s):\n' "\$exe" "\$a"; fi
  if on otool_missing_\$a; then :
  elif on otool_duplicate_\$a; then ref; ref
  elif on otool_wrong_\$a; then wrong "\$a"
  else ref
  fi
  # The shim is deliberately early. An otool-to-grep-q reader closes before this delayed dependency and makes the
  # producer fail under pipefail; capture-to-file must wait for it and preserve it.
  if on otool_delayed_\$a; then /bin/sleep 0.15; fi
  later "\$a"; sys
  if on otool_nonzero_\$a; then return 7; fi
  return 0
}
case "\${1:-}" in
  -arch)
    [ "\$#" -eq 4 ] && [ "\$3" = -L ] && { [ "\$2" = x86_64 ] || [ "\$2" = arm64 ]; } || exit 64
    printf '%s\t-arch\t%s\t-L\t%s\n' "\${ZB_ROLE:-?}" "\$2" "\$4" >> "$C/otool-slice-calls"
    emit_one "\$2" "\$4"; exit \$? ;;
  -L)
    [ "\$#" -eq 2 ] || exit 64
    printf '%s\t-L\t%s\n' "\${ZB_ROLE:-?}" "\$2" >> "$C/otool-slice-calls"
    if on otool_aggregate; then printf '%s:\n' "\$2"; ref; later combined; sys
    else emit_one x86_64 "\$2" || :; emit_one arm64 "\$2" || :
    fi
    exit 0 ;;
  *) exit 64 ;;
esac
EOF
chmod 755 "$X/hostbin/otool"

SHIM='@executable_path/../Frameworks/libwkwebview_shim.dylib'
evidence_arch() { [ "$1" = intel ] && printf x86_64 || printf arm64; }
slice_contract() { # slice_contract <role> <slice> <status> <refs>: separate call, evidence, record and marker
  local role=$1 slice=$2 status=$3 refs=$4 rd exe ea f log
  rd=$(rd_of "$role")
  exe="$rd/$APPEXE"
  ea=$(evidence_arch "$role")
  f="$EV/$ea/evidence/otool.$slice.out"
  log="$EV/$ea/evidence/leg.log"
  [ "$(grep -cF "${role}${TB}-arch${TB}${slice}${TB}-L${TB}${exe}" "$C/otool-slice-calls" 2>/dev/null)" -eq 1 ] \
    && [ -f "$f" ] \
    && grep -qxF "${TB}/usr/lib/libSlice-$slice.dylib (compatibility version 1.0.0, current version 1.0.0)" "$f" \
    && ! grep -qF "/usr/lib/libSlice-$([ "$slice" = x86_64 ] && echo arm64 || echo x86_64).dylib" "$f" \
    && [ "$(grep -cF "${TB}$SHIM (" "$f")" -eq "$refs" ] \
    && [ "$(grep -cF "OTOOL${TB}${slice}${TB}rc=${status}${TB}refs=${refs}" "$log" 2>/dev/null)" -eq 1 ]
}
calls_contract() { # exactly two calls to the unpacked app exe on each host; packaging checks another target
  local role rd exe
  for role in intel arm; do
    rd=$(rd_of "$role")
    exe="$rd/$APPEXE"
    [ "$(awk -F '\t' -v r="$role" -v e="$exe" '$1 == r && $NF == e { n++ } END { print n + 0 }' \
        "$C/otool-slice-calls" 2>/dev/null)" -eq 2 ] \
      || return 1
  done
}
contract() { # contract <arm-x86-status> <arm-x86-refs> <arm-arm-status> <arm-arm-refs>
  calls_contract \
    && slice_contract intel x86_64 0 1 && slice_contract intel arm64 0 1 \
    && slice_contract arm x86_64 "$1" "$2" && slice_contract arm arm64 "$3" "$4"
}
expect_pass() { [ "$rc" -eq 0 ] && leg_is x86_64 PASS && leg_is arm64 PASS && ! no_pass; }
expect_arm_fail() { [ "$rc" -eq 1 ] && leg_is x86_64 PASS && leg_is arm64 FAIL && no_pass; }
diag() { grep 'arm64: OTOOL\|arm64: REASON' "$OUT" 2>/dev/null | tr '\n' '|'; }

# Preserve the older aggregate-header compatibility, but only inside each requested slice's own captured output.
run_gate aggregate otool_aggregate.arm
if expect_pass && contract 0 1 0 1; then
  ok "O1: aggregate-style output from each explicit slice call is accepted"
else
  bad "O1: aggregate per-call control exit $rc: $(diag)"
fi

# Released shape: the two requested-slice outputs each name the shim once.
run_gate multislice-ok
if expect_pass && contract 0 1 0 1; then
  ok "O2: x86_64 and arm64 calls with one shim reference each are accepted"
else
  bad "O2: valid independent slice calls exited $rc: $(diag)"
fi

# A global count of one is insufficient: either requested slice may omit the shim.
run_gate missing-arm otool_missing_arm64.arm
if expect_arm_fail && contract 0 1 0 0; then
  ok "O3: a missing arm64 shim reference is rejected"
else
  bad "O3: missing arm64 reference exited $rc: $(diag)"
fi

# Preserve the original duplicate-x86_64 control.
run_gate duplicate-x86 otool_duplicate_x86_64.arm
if expect_arm_fail && contract 0 2 0 1; then
  ok "O4: a duplicate x86_64 shim reference is rejected"
else
  bad "O4: duplicate x86_64 reference exited $rc: $(diag)"
fi

run_gate missing-x86 otool_missing_x86_64.arm
if expect_arm_fail && contract 0 0 0 1; then
  ok "O5: a missing x86_64 shim reference is rejected"
else bad "O5: missing x86_64 reference exited $rc: $(diag)"; fi

run_gate duplicate-arm otool_duplicate_arm64.arm
if expect_arm_fail && contract 0 1 0 2; then
  ok "O6: a duplicate arm64 shim reference is rejected"
else bad "O6: duplicate arm64 reference exited $rc: $(diag)"; fi

run_gate wrong-x86 otool_wrong_x86_64.arm
if expect_arm_fail && contract 0 0 0 1 \
   && grep -qF '@executable_path/../Frameworks/libwrong-x86_64.dylib' "$EV/arm64/evidence/otool.x86_64.out" 2>/dev/null; then
  ok "O7: a wrong x86_64 dependency is rejected"
else bad "O7: wrong x86_64 dependency exited $rc: $(diag)"; fi

run_gate wrong-arm otool_wrong_arm64.arm
if expect_arm_fail && contract 0 1 0 0 \
   && grep -qF '@executable_path/../Frameworks/libwrong-arm64.dylib' "$EV/arm64/evidence/otool.arm64.out" 2>/dev/null; then
  ok "O8: a wrong arm64 dependency is rejected"
else bad "O8: wrong arm64 dependency exited $rc: $(diag)"; fi

# Matching text cannot hide a failing producer; status and refs are both retained per slice.
run_gate nonzero-x86 otool_nonzero_x86_64.arm
if expect_arm_fail && contract 7 1 0 1; then
  ok "O9: valid x86_64 dependency text with nonzero otool status is rejected"
else bad "O9: nonzero x86_64 status exited $rc: $(diag)"; fi

run_gate nonzero-arm otool_nonzero_arm64.arm
if expect_arm_fail && contract 0 1 7 1; then
  ok "O10: valid arm64 dependency text with nonzero otool status is rejected"
else bad "O10: nonzero arm64 status exited $rc: $(diag)"; fi

# The later unique dependency proves the producer completed. These pass only when output is captured before search;
# an early-closing `otool | grep -q` under pipefail makes the delayed producer fail.
run_gate delayed-x86 otool_delayed_x86_64.arm
if expect_pass && contract 0 1 0 1; then
  ok "O11: an early x86_64 shim line followed by delayed output is captured and accepted"
else bad "O11: delayed x86_64 output exited $rc: $(diag)"; fi

run_gate delayed-arm otool_delayed_arm64.arm
if expect_pass && contract 0 1 0 1; then
  ok "O12: an early arm64 shim line followed by delayed output is captured and accepted"
else bad "O12: delayed arm64 output exited $rc: $(diag)"; fi

if [ "$fails" -eq 0 ]; then
  printf 'PASS\tms1c-otool-slices-red\t12/12\n'
  exit 0
fi
printf 'FAIL\tms1c-otool-slices-red\t%s/12 failed\n' "$fails"
exit 1
DRIVER
chmod 700 "$DRIVER"

bash "$DRIVER" "$ROOT"
