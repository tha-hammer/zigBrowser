#!/usr/bin/env bash
# Registered in zig build test-mac-build-script (bd zigBrowser-3ui.14; red 11894873, fix-forwards 0a3fd03e and df2c183b;
# SilverRidge 917b7c7e, e5eb7d37, 3add0d33, d9f0970d): the runtime rows gate judges
# each Mac by its exact remote success lines, never by the ssh exit status and the evidence copy alone.
#
# A leg passes only when its completed output (kept in <evidence>/<arch>/leg.out) has, for that host:
#   - exactly one ROW<TAB><file><TAB><want><TAB>rc=<0 for green, 1 for red><TAB>MATCH per selected row, and no other
#     ROW line;
#   - SELFAUDIT_STATUS<TAB><step><TAB>0 for outer-begin, inner-varfolders, inner-crashreports, inner-evidence and
#     outer-end;
#   - one VARFOLDERS<TAB>COMPLETE<TAB><n>, CRASHREPORTS<TAB>COMPLETE<TAB>0 and EVIDENCE_ARMED.
# Otherwise that host is refused with FAIL<TAB>remote-success<TAB>ms_runtime_rows_gate<TAB><host><TAB><arch><TAB>missing
# (tests/mac/mac_gate_output.sh's grammar). There is then no PASS for that leg and no gate PASS, while the other host is
# judged on its own.
# Driven end to end on two fake Macs (the same emulator as ms_runtime_rows_evidence_selftest.sh). Its ssh can return
# no bytes with exit 0, or run the real leg and alter its completed output, keeping status 0 and the real evidence:
#   O1 empty output, on intel and on arm: that host refused.
#   O2 no ROW lines, on each host: refused.
#   O3 one selected row's ROW line missing; O4 a ROW line twice; O5 MATCH turned to MISMATCH: refused (intel).
#   O6 the VARFOLDERS COMPLETE line, O7 the CRASHREPORTS COMPLETE 0 line, O8 the outer-end self-audit status, O9
#      EVIDENCE_ARMED missing: refused (intel).
#   SilverRidge e5eb7d37, each on intel:
#   O10 each of the five SELFAUDIT_STATUS <step> 0 records missing, and O11 each one twice.
#   O12 VARFOLDERS COMPLETE, O13 CRASHREPORTS COMPLETE 0 and O14 EVIDENCE_ARMED each twice: every singular record is
#      bound by count, not by presence.
#   O15-O18 the full ROW tuple, one field at a time in the first ROW record: O15 another row's file, O16 the other
#      verdict wanted, O17 a green row with rc=1, O18 a red row (ms2c-close-button) with rc=0.
#   O19 an extra, otherwise well-formed ROW record for a row that was not selected.
#   Every refusal: exit status exactly 1 (not 124 or any signal-shaped status), exactly one remote-success refusal for
#   that host and none for the other.
#   Order (SilverRidge 3add0d33): that refusal comes before any EVIDENCE<TAB><host> record and before every evidence
#   scp to that host (each fake scp records how many refusals for its host the gate had printed by then). Both may be
#   absent when the gate returns before retrieval.
#   P1 positive control: the real legs: PASS for both legs and the gate, and no remote-success FAIL.
#   P2 positive control, one selected row: PASS. The required ROW lines follow the selection.
#   P3 positive control, a red row (ms2c-close-button, rc=1 and its RED_SHAPE): PASS. A red row's line is rc=1.
# Run: bash tests/mac/ms_runtime_rows_output_selftest.sh [repo root]
set -uo pipefail
if [ "${ZB_OUTPUT_SELFTEST_INNER:-}" != 1 ]; then
  ZB_OUTPUT_SELFTEST_INNER=1 exec unshare --user --map-current-user --net bash "$(realpath "$0")" "$@"
fi
ROOT=$(realpath "${1:-.}")
BASE=$(mktemp -d "${TMPDIR:-/tmp}/zb-output-selftest-XXXXXX")
T=$(realpath "$BASE")
cleanup() {
  case "$T" in "$(realpath "${TMPDIR:-/tmp}")"/zb-output-selftest-??????) chmod -R u+rwx "${T:?}" 2>/dev/null; rm -rf "${T:?}" ;; esac
}
trap cleanup EXIT
fails=0
ok() { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }
INTEL=intel@10.0.0.1 ARM=arm@10.0.0.2
GATE=tests/mac/ms_runtime_rows_gate.sh

# The fake Macs: $T/mac/<host> is that host's home. ssh runs the remote command as sshd does (one string, to a shell
# with -c) in that home, except the zig build, which it skips; scp fetches host:<path> from that home.
mkdir -p "$T/bin" "$T/macbin" "$T/ctl" "$T/home" "$T/tmp"
printf 'not a real key\n' > "$T/fake_mac_key"
cat > "$T/bin/ssh" <<EOF
#!/bin/bash
i=\$(cat "$T/ctl/n" 2>/dev/null || echo 0); echo \$((i + 1)) > "$T/ctl/n"
printf '%s\0' ssh "\$@" > "$T/ctl/call.\$i"
while [ \$# -gt 0 ]; do case "\$1" in -i|-o|-F|-p|-l) shift 2 ;; -*) shift ;; *) break ;; esac; done
host=\$1; shift; cmd="\$*"; h="$T/mac/\$host"
[ -e "$T/ctl/ssh-fail" ] && exit 255
if [ -e "$T/ctl/ssh-silent" ]; then cat > /dev/null; exit 0; fi
case "\$cmd" in *"zig build"*) exit 0 ;; esac
mode=\$(cat "$T/ctl/leg-\$host" 2>/dev/null)
case "\$cmd" in "/bin/bash -s "*) leg=1 ;; *) leg=0; mode= ;; esac
if [ "\$mode" = empty ]; then cat > /dev/null; exit 0; fi   # an ssh that succeeds and returns no bytes
mkdir -p "\$h" && cd "\$h" || exit 1
if [ -n "\$mode" ]; then   # the real leg runs; its completed output is altered on the way back, its status kept 0
  env -i PATH="$T/macbin:/usr/bin:/bin" HOME="\$h" ZB_FAKE_MAC="\$h" LANG=C.UTF-8 /bin/bash -c "\$cmd" > "$T/ctl/raw.\$host" 2>&1
  awk -v m="\$mode" '
    m == "norows"   && /^ROW\t/ { next }
    m == "onerow"   && /^ROW\t/ && !d { d = 1; next }
    m == "duprow"   && /^ROW\t/ { print }
    m == "mismatch" && /^ROW\t/ { sub(/\tMATCH\$/, "\tMISMATCH") }
    m == "novf"     && /^VARFOLDERS\tCOMPLETE\t/ { next }
    m == "nocr"     && /^CRASHREPORTS\tCOMPLETE\t0\$/ { next }
    m == "noself"   && /^SELFAUDIT_STATUS\touter-end\t0\$/ { next }
    m == "noarm"    && /^EVIDENCE_ARMED\$/ { next }
    m ~ /^noself-/  && \$0 == "SELFAUDIT_STATUS\t" substr(m, 8) "\t0" { next }
    m ~ /^dupself-/ && \$0 == "SELFAUDIT_STATUS\t" substr(m, 9) "\t0" { print }
    m == "dupvf"    && /^VARFOLDERS\tCOMPLETE\t/ { print }
    m == "dupcr"    && /^CRASHREPORTS\tCOMPLETE\t0\$/ { print }
    m == "duparm"   && /^EVIDENCE_ARMED\$/ { print }
    m ~ /^row(file|want|rc)\$/ && /^ROW\t/ && !r {   # one field of the first ROW record changed, the rest kept
      r = 1; n = split(\$0, f, "\t")
      if (m == "rowfile") f[2] = "tests/e2e/mac_ms2c_close_primary_test.py"
      if (m == "rowwant") f[3] = (f[3] == "green" ? "red" : "green")
      if (m == "rowrc")   f[4] = (f[4] == "rc=0" ? "rc=1" : "rc=0")
      \$0 = f[1]; for (k = 2; k <= n; k++) \$0 = \$0 "\t" f[k]
    }
    m == "extrarow" && /^ROW\t/ && !x {   # an extra ROW record, for a row that was not selected, after the first
      x = 1; print; n = split(\$0, f, "\t"); f[2] = "tests/e2e/mac_ms2c_close_primary_test.py"
      \$0 = f[1]; for (k = 2; k <= n; k++) \$0 = \$0 "\t" f[k]
    }
    { print }' "$T/ctl/raw.\$host"
  exit 0
fi
env -i PATH="$T/macbin:/usr/bin:/bin" HOME="\$h" ZB_FAKE_MAC="\$h" LANG=C.UTF-8 /bin/bash -c "\$cmd"; rc=\$?
[ -e "$T/ctl/ssh-fail-after" ] && exit 255
exit \$rc
EOF
cat > "$T/bin/scp" <<EOF
#!/bin/bash
i=\$(cat "$T/ctl/n" 2>/dev/null || echo 0); echo \$((i + 1)) > "$T/ctl/n"
printf '%s\0' scp "\$@" > "$T/ctl/call.\$i"
while [ \$# -gt 2 ]; do shift; done
src=\$1 dst=\$2
case "\$src" in *:*) ;; *) exit 1 ;; esac
host=\${src%%:*} path=\${src#*:}
printf 'SCP\t%s\t%s\n' "\$host" "\$(grep -c "^FAIL\$(printf '\t')remote-success\$(printf '\t')ms_runtime_rows_gate\$(printf '\t')\$host\$(printf '\t')" "$T/gate.out" 2>/dev/null)" >> "$T/ctl/scp-order"
[ -e "$T/ctl/scp-fail-\$host" ] && exit 1
cp -- "$T/mac/\$host/\$path" "\$dst" || exit 1
case "\$path" in *.tar) [ -e "$T/ctl/scp-corrupt-\$host" ] && printf 'x' >> "\$dst" ;; esac
exit 0
EOF
cat > "$T/macbin/find" <<EOF
#!/bin/bash
[ -e "$T/ctl/find-noop" ] && exit 0   # a delete that reports success and removes nothing
exec /usr/bin/find "\$@"
EOF
cat > "$T/macbin/getconf" <<'EOF'
#!/bin/bash
[ -e "$ZB_FAKE_MAC/ctl-getconf-fail" ] && exit 1
case "$1" in DARWIN_USER_TEMP_DIR) echo "$ZB_FAKE_MAC/vf/0/T/" ;; DARWIN_USER_CACHE_DIR) echo "$ZB_FAKE_MAC/vf/0/C/" ;; *) exit 1 ;; esac
EOF
cat > "$T/macbin/python3" <<'EOF'
#!/bin/bash
# A row (each would launch a browser): its whole output is longer than the leg's 40-line console tail.
printf '%s\n' "$1" >> "$ZB_FAKE_MAC/row-calls"
case "$1" in
  tests/e2e/mac_signal_runtime_test.py) id=mac-signal-runtime ;;
  tests/e2e/mac_ms2a_load_fail_no_quit_test.py) id=ms2a-load-fail-no-quit ;;
  tests/e2e/mac_ms2c_recover_slow_server_test.py) id=ms2c-recover-slow-server ;;
  tests/e2e/mac_ms2c_close_button_test.py)   # a red row: its accepted red vector, exit 1
    printf 'ASSERT\tms2c-close-button\tstub\tfail\nFAIL\tms2c-close-button\nRED_SHAPE\tms2c-close-button\n'; exit 1 ;;
  *) printf 'unexpected row %s\n' "$1"; exit 2 ;;
esac
# The executing package/signal fake-host path for mac-signal-runtime is tests/mac/ms_signal_runtime_gate_red.sh.
printf 'FIRST\t%s\n' "$id"; for n in $(seq 1 60); do printf 'line %d of %s\n' "$n" "$id"; done
if [ -e "$ZB_FAKE_MAC/ctl-leak" ]; then printf 'FAIL\t%s\nLEAK\t4242\t4242\tThu Oct 22 21:00:00 2026\t/x/zigBrowser --e2e-protocol\n' "$id"; exit 1; fi
if [ -e "$ZB_FAKE_MAC/ctl-lock" ]; then mkdir -p locked/x && : > locked/x/f && chmod 500 locked/x; fi
printf 'ASSERT\t%s\tstub\tpass\nPASS\t%s\n' "$id" "$id"
exit 0
EOF
chmod +x "$T/bin/ssh" "$T/bin/scp" "$T/macbin/find" "$T/macbin/getconf" "$T/macbin/python3"
row_text() { # the exact output the stub row prints for <id> on success
  printf 'FIRST\t%s\n' "$1"; for n in $(seq 1 60); do printf 'line %d of %s\n' "$n" "$1"; done
  printf 'ASSERT\t%s\tstub\tpass\nPASS\t%s\n' "$1" "$1"
}
fresh_macs() { # fresh fake homes, each with its /var/folders roots and an existing crash report
  chmod -R u+rwx "$T/mac" 2>/dev/null; rm -rf -- "${T:?}/mac"
  local h
  for h in "$INTEL" "$ARM"; do
    mkdir -p "$T/mac/$h/vf/0/T" "$T/mac/$h/vf/0/C" "$T/mac/$h/Library/Logs/DiagnosticReports"
    echo "an older report" > "$T/mac/$h/Library/Logs/DiagnosticReports/old.ips"
  done
  rm -f "$T/ctl"/*
}
calls() { cat "$T/ctl/n" 2>/dev/null || echo 0; }

R="$T/repo"
mkdir -p "$R/tests/mac" "$R/tests/e2e" "$R/src" "$R/packaging/macos"
for f in "$ROOT"/tests/mac/*.sh "$ROOT"/tests/mac/known_hosts; do [ -f "$f" ] && cp "$f" "$R/tests/mac/"; done
echo src > "$R/src/main.zig"; echo e2e > "$R/tests/e2e/placeholder.py"; echo plist > "$R/packaging/macos/Info.plist"
echo build > "$R/build.zig"; echo zon > "$R/build.zig.zon"; echo '{}' > "$R/zigbrowser.json"
G=(env -i PATH=/usr/bin:/bin HOME="$T/home" GIT_CONFIG_NOSYSTEM=1 git -C "$R")
"${G[@]}" init -q && "${G[@]}" add -A && "${G[@]}" -c user.name=selftest -c user.email=selftest@invalid commit -q -m s \
  || { bad "could not build the scratch repo"; exit 1; }
SHA=$("${G[@]}" rev-parse HEAD)

EVD="$T/evidence"
run_gate() { # run_gate <selection>: a fresh evidence dir; sets OUT RC
  chmod -R u+rwx "$EVD" 2>/dev/null; rm -rf -- "${EVD:?}"; mkdir -m 700 "$EVD"
  (cd "$R" && env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" TMPDIR="$T/tmp" ZB_MAC_HOST="$INTEL" ZB_MAC_ARM_HOST="$ARM" \
     ZB_MAC_KEY="$T/fake_mac_key" ZB_RUNTIME_ROWS="$1" ZB_MAC_EVIDENCE_DIR="$EVD" timeout 300 bash "$GATE" > "$T/gate.out" 2>&1 </dev/null)
  RC=$?
  OUT=$(cat "$T/gate.out")
}
BOTH="ms2a-load-fail-no-quit ms2c-recover-slow-server"
refusal_first() { # refusal_first <host>: its one refusal precedes any EVIDENCE<TAB><host> record and every scp to it
  local h=$1 fl el
  fl=$(grep -n -m1 $'^FAIL\tremote-success\tms_runtime_rows_gate\t'"$h"$'\t' <<<"$OUT" | cut -d: -f1)
  el=$(grep -n -m1 $'^EVIDENCE\t'"$h"$'\t' <<<"$OUT" | cut -d: -f1)
  [ -n "$fl" ] || return 1
  [ -z "$el" ] || [ "$fl" -lt "$el" ] || return 1
  ! grep $'^SCP\t'"$h"$'\t' "$T/ctl/scp-order" 2>/dev/null | grep -qv $'\t1$'   # none, or every one after the refusal
}
refused() { # refused <name> <host> <arch> <other host> <other arch>: only that host refused, by its exact line
  local name=$1 h=$2 a=$3 oh=$4 oa=$5
  if [ "$RC" -eq 1 ] && [ "$(grep -c $'^FAIL\tremote-success\tms_runtime_rows_gate\t'"$h"$'\t' <<<"$OUT")" -eq 1 ] \
     && grep -qxF "FAIL"$'\t'"remote-success"$'\t'"ms_runtime_rows_gate"$'\t'"$h"$'\t'"$a"$'\t'"missing" <<<"$OUT" \
     && ! grep -q $'^PASS\tms-runtime-rows-leg\t'"$h"$'\t' <<<"$OUT" && ! grep -q $'^PASS\tms-runtime-rows-gate' <<<"$OUT" \
     && grep -qx $'PASS\tms-runtime-rows-leg\t'"$oh"$'\t'"$oa" <<<"$OUT" \
     && ! grep -q $'^FAIL\tremote-success\tms_runtime_rows_gate\t'"$oh"$'\t' <<<"$OUT" && refusal_first "$h"; then
    ok "$name: $h refused once (remote-success missing), exit 1, no leg or gate PASS; $oh judged on its own and passed"
  else bad "$name: rc=$RC $(grep -E $'^(FAIL\tremote-success|PASS\tms-runtime-rows)' <<<"$OUT" | tr '\n' ' ')"; fi
}

for hl in "O1 empty output|empty" "O2 no ROW lines|norows"; do
  name=${hl%|*} mode=${hl#*|}
  fresh_macs; echo "$mode" > "$T/ctl/leg-$INTEL"; run_gate "$BOTH"; refused "$name (intel)" "$INTEL" x86_64 "$ARM" arm64
  fresh_macs; echo "$mode" > "$T/ctl/leg-$ARM"; run_gate "$BOTH"; refused "$name (arm)" "$ARM" arm64 "$INTEL" x86_64
done
for hl in "O3 one selected row's ROW line missing|onerow" "O4 a ROW line twice|duprow" "O5 MATCH turned to MISMATCH|mismatch" \
          "O6 no VARFOLDERS COMPLETE line|novf" "O7 no CRASHREPORTS COMPLETE 0 line|nocr" \
          "O8 no outer-end self-audit status|noself" "O9 no EVIDENCE_ARMED line|noarm"; do
  name=${hl%|*} mode=${hl#*|}
  fresh_macs; echo "$mode" > "$T/ctl/leg-$INTEL"; run_gate "$BOTH"; refused "$name" "$INTEL" x86_64 "$ARM" arm64
done

for step in outer-begin inner-varfolders inner-crashreports inner-evidence outer-end; do   # O10, O11
  fresh_macs; echo "noself-$step" > "$T/ctl/leg-$INTEL"; run_gate "$BOTH"
  refused "O10 no SELFAUDIT_STATUS $step 0" "$INTEL" x86_64 "$ARM" arm64
  fresh_macs; echo "dupself-$step" > "$T/ctl/leg-$INTEL"; run_gate "$BOTH"
  refused "O11 SELFAUDIT_STATUS $step 0 twice" "$INTEL" x86_64 "$ARM" arm64
done
for hl in "O12 VARFOLDERS COMPLETE twice|dupvf" "O13 CRASHREPORTS COMPLETE 0 twice|dupcr" "O14 EVIDENCE_ARMED twice|duparm" \
          "O15 a ROW record naming another row's file|rowfile" "O16 a ROW record with the other verdict wanted|rowwant" \
          "O17 a green ROW record with rc=1|rowrc" "O19 an extra ROW record for a row not selected|extrarow"; do
  name=${hl%|*} mode=${hl#*|}
  fresh_macs; echo "$mode" > "$T/ctl/leg-$INTEL"; run_gate "$BOTH"; refused "$name" "$INTEL" x86_64 "$ARM" arm64
done
fresh_macs; echo rowrc > "$T/ctl/leg-$INTEL"; run_gate ms2c-close-button   # O18
refused "O18 a red ROW record with rc=0" "$INTEL" x86_64 "$ARM" arm64

for pc in "P1 both rows|$BOTH" "P2 one selected row|ms2c-recover-slow-server" "P3 a red row|ms2c-close-button"; do
  name=${pc%|*} sel=${pc#*|}
  fresh_macs; run_gate "$sel"
  if [ "$RC" -eq 0 ] && grep -qx $'PASS\tms-runtime-rows-gate\tboth-arches' <<<"$OUT" \
     && grep -qx $'PASS\tms-runtime-rows-leg\t'"$INTEL"$'\tx86_64' <<<"$OUT" && grep -qx $'PASS\tms-runtime-rows-leg\t'"$ARM"$'\tarm64' <<<"$OUT" \
     && ! grep -q $'^FAIL\tremote-success' <<<"$OUT"; then
    ok "$name: positive control: the exact lines pass both legs and the gate"
  else bad "$name: positive control did not pass: rc=$RC $(grep -E $'^(FAIL|PASS\tms-runtime)' <<<"$OUT" | head -4 | tr '\n' ' ')"; fi
done

if [ "$fails" -eq 0 ]; then printf 'PASS\tms-runtime-rows-output-selftest\n'; exit 0; fi
printf 'FAIL\tms-runtime-rows-output-selftest\t%s failure(s)\n' "$fails"
exit 1
