#!/usr/bin/env bash
# Registered in zig build test-mac-build-script (red 1453f59e, fix-forward 2aaa808f, approved c7c5a483; orchestrator
# 2026-10-23, the 4pa.55 run request): the runtime rows gate,
# tests/mac/ms_runtime_rows_gate.sh, runs only the rows a request names, runs the 4pa.55 rows as greens, and makes a
# new crash report in the Mac user's real ~/Library/Logs/DiagnosticReports INCONCLUSIVE, never a pass.
#   S1 ZB_RUNTIME_ROWS unset: the leg on each Mac gets every ROWS entry, in ROWS order.
#   S2 ZB_RUNTIME_ROWS="<id> <id>" (any order): the leg on each Mac gets exactly those ROWS entries, in ROWS order, and
#      the gate prints ROWS_SELECTED<TAB><id>... before any host is contacted. The want stays in the committed ROWS.
#   S3-S5 an unknown id, a duplicate id, or an empty or blank selection: NOT RUN, exit 1, and no ssh/scp call at all.
#   F1 the two 4pa.55 rows are green rows: mac_ms2a_load_fail_no_quit_test.py|green|ms2a-load-fail-no-quit and
#      mac_ms2c_recover_slow_server_test.py|green|ms2c-recover-slow-server.
#   L1 the Mac leg (extracted from the real gate, run hostlessly in a fake run root with the real shared helpers, a
#      getconf stub and a stub python3) lists the ORIGINAL home's Library/Logs/DiagnosticReports, read-only: with no new
#      report it prints CRASHREPORTS<TAB>COMPLETE<TAB>0 and exits 0, and a report already there is untouched.
#   L2 a row that leaves a crash report there: the leg prints CRASHREPORT<TAB>added<TAB><name><TAB><sha256> and
#      CRASHREPORTS<TAB>INCONCLUSIVE, and exits 5 although the row matched.
#   L3 a leak stop still prints the crash-report listing, and exits 3.
#   L4 a crash-report begin that cannot list the reports dir completely (an unreadable entry) refuses: the leg exits 5
#      with zero ROW lines, zero row (browser) invocations and no RUNNING marker.
#   L5 the helper self-audit (SilverRidge 5f1ce9a5): before the first row, the leg prints SELFAUDIT<TAB>... lines whose
#      outer /var/folders end is exactly SELFAUDIT<TAB>VARFOLDERS<TAB>COMPLETE<TAB>0.
#   L6 a /var/folders helper that itself writes under the temp root during its cycle: the self-audit shows that delta,
#      and the leg exits 5 with zero rows, zero row invocations and no RUNNING marker.
#   L5 is exact (SilverRidge 90151365): SELFAUDIT_STATUS<TAB><step><TAB>0 for outer-begin, inner-varfolders,
#      inner-crashreports, inner-evidence (the evidence packer, SilverRidge 0632602f) and outer-end, in that order;
#      outer-begin and inner-evidence silent; each other step's last line COMPLETE 0; all
#      before the first ROW line. L7 an inner refusal or a non-COMPLETE inner result (each injected into the fake run
#      root's helper, for the self-audit's evidence dir only): exit 5, zero rows, zero row invocations, no marker.
#   L8 a crash-report evidence dir that cannot be made: exactly one begin refusal, and the leg starts nothing.
#   S1/S2 also bind order: one transcript records, at each fake ssh/scp contact, how many ROWS_SELECTED lines the gate
#      had printed by then; every contact must see exactly one. S3-S5 leave the transcript empty.
# The leg's own HOME is its private run-env/home, so L1/L2 also prove the listing is of the real home, not that one.
# Run: bash tests/mac/ms_runtime_rows_gate_select_selftest.sh [repo root]
set -uo pipefail
if [ "${ZB_SELECT_SELFTEST_INNER:-}" != 1 ]; then
  ZB_SELECT_SELFTEST_INNER=1 exec unshare --user --map-current-user --net bash "$(realpath "$0")" "$@"
fi
ROOT=$(realpath "${1:-.}")
BASE=$(mktemp -d "${TMPDIR:-/tmp}/zb-select-selftest-XXXXXX")
T=$(realpath "$BASE")
cleanup() {
  case "$T" in "$(realpath "${TMPDIR:-/tmp}")"/zb-select-selftest-??????) chmod -R u+rwx "${T:?}" 2>/dev/null; rm -rf "${T:?}" ;; esac
}
trap cleanup EXIT
fails=0
ok() { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }
INTEL=intel@10.0.0.1 ARM=arm@10.0.0.2
GATE=tests/mac/ms_runtime_rows_gate.sh

# Stub ssh/scp that record every call and succeed; the scratch repo holds the real gate, its library and helpers.
mkdir -p "$T/bin" "$T/ctl" "$T/home" "$T/tmp"
printf 'not a real key\n' > "$T/fake_mac_key"
cat > "$T/bin/zb-leg-success" <<'EOF'
#!/bin/bash
# The exact success lines of a passing rows-gate leg (bd 3ui.14), for the rows after `/bin/bash -s <run dir>`, as the
# remote shell unquotes them.
seen=0 prev=
for a in "$@"; do
  if [ "$seen" = 2 ]; then
    w=${a//\\|/|}; IFS='|' read -r f want id <<<"$w"; rc=1; [ "$want" = green ] && rc=0
    printf 'ROW\t%s\t%s\trc=%s\tMATCH\n' "$f" "$want" "$rc"; continue
  fi
  if [ "$seen" = 1 ]; then seen=2; continue; fi   # the run dir
  [ "$a" = -s ] && [ "$prev" = /bin/bash ] && seen=1
  prev=$a
done
printf 'SELFAUDIT_STATUS\t%s\t0\n' outer-begin inner-varfolders inner-crashreports inner-evidence outer-end
printf 'VARFOLDERS\tCOMPLETE\t0\nCRASHREPORTS\tCOMPLETE\t0\nEVIDENCE_ARMED\n'
EOF
chmod +x "$T/bin/zb-leg-success"
cat > "$T/bin/ssh" <<EOF
#!/bin/bash
printf 'CONTACT\tssh\t%s\n' "\$(grep -c '^ROWS_SELECTED' "$T/gate.out" 2>/dev/null)" >> "$T/ctl/transcript"
i=\$(cat "$T/ctl/n" 2>/dev/null || echo 0); echo \$((i + 1)) > "$T/ctl/n"
printf '%s\0' ssh "\$@" > "$T/ctl/call.\$i"
cat > "$T/ctl/stdin.\$i"
case "\$*" in *ZB_ROOT_ABSENT*) last="\${@: -1}"; printf 'ZB_ROOT_ABSENT\t%s\n' "\${last##* }" ;; esac   # the verified cleanup
[[ " \$* " == *" /bin/bash -s "* ]] && "$T/bin/zb-leg-success" "\$@"   # a passing leg's exact lines (3ui.14)
exit 0
EOF
cat > "$T/bin/scp" <<EOF
#!/bin/bash
printf 'CONTACT\tscp\t%s\n' "\$(grep -c '^ROWS_SELECTED' "$T/gate.out" 2>/dev/null)" >> "$T/ctl/transcript"
i=\$(cat "$T/ctl/n" 2>/dev/null || echo 0); echo \$((i + 1)) > "$T/ctl/n"
printf '%s\0' scp "\$@" > "$T/ctl/call.\$i"
args=()
while [ \$# -gt 0 ]; do case "\$1" in -i|-o|-F|-P|-S|-c|-l) shift 2 ;; -*) shift ;; *) args+=("\$1"); shift ;; esac; done
[ "\${#args[@]}" -ge 2 ] || exit 1
dst="\${args[\${#args[@]}-1]}"; src="\${args[0]}"
case "\$dst" in *:*) exit 0 ;; esac   # controller/package uploads are accepted by this selection-only transport
case "\$src" in   # a fetch of the leg's evidence: the archive and its matching sha256
  *.sha256) printf '%s  evidence.tar\n' "\$(printf 'stub\n' | sha256sum | cut -d' ' -f1)" > "\$dst" ;;
  *:*) echo stub > "\$dst" ;;
  *) exit 1 ;;
esac
exit 0
EOF
chmod +x "$T/bin/ssh" "$T/bin/scp"
R="$T/repo"
mkdir -p "$R/tests/mac" "$R/tests/e2e" "$R/src" "$R/packaging/macos" "$R/packaging/assets"
for f in "$ROOT"/tests/mac/*.sh "$ROOT"/tests/mac/known_hosts; do [ -f "$f" ] && cp "$f" "$R/tests/mac/"; done
cp "$ROOT/packaging/macos/build-dmg.sh" "$R/packaging/macos/build-dmg.sh"
echo plist > "$R/packaging/macos/Info.plist"; echo png > "$R/packaging/assets/zigBrowser.png"
echo src > "$R/src/main.zig"; echo e2e > "$R/tests/e2e/placeholder.py"
echo build > "$R/build.zig"; echo zon > "$R/build.zig.zon"; echo '{}' > "$R/zigbrowser.json"
G=(env -i PATH=/usr/bin:/bin HOME="$T/home" GIT_CONFIG_NOSYSTEM=1 git -C "$R")
"${G[@]}" init -q && "${G[@]}" add -A && "${G[@]}" -c user.name=selftest -c user.email=selftest@invalid commit -q -m s \
  || { bad "could not build the scratch repo"; exit 1; }

mapfile -t ROWS < <(awk -F'"' '/^ROWS=\(/{f=1;next} f&&/^\)/{f=0} f&&NF>1{print $2}' "$ROOT/$GATE")
[ "${#ROWS[@]}" -ge 2 ] || bad "could not read the gate's ROWS (${#ROWS[@]} entries)"

run_gate() { # run_gate <selection or __UNSET__>: sets OUT RC N; $T/ctl/transcript holds the ordered contacts
  rm -f "$T/ctl"/* "$T/gate.out"
  local -a sel=()
  [ "$1" = __UNSET__ ] || sel=(ZB_RUNTIME_ROWS="$1")
  local ev
  ev=$(mktemp -d "$T/evidence-XXXXXX")   # ZB_MAC_EVIDENCE_DIR: a fresh empty dir per run
  (cd "$R" && env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" TMPDIR="$T/tmp" ZB_MAC_HOST="$INTEL" \
     ZB_MAC_ARM_HOST="$ARM" ZB_MAC_KEY="$T/fake_mac_key" ZB_MAC_EVIDENCE_DIR="$ev" "${sel[@]}" \
     timeout 120 bash "$GATE" > "$T/gate.out" 2>&1 </dev/null)
  RC=$?
  OUT=$(cat "$T/gate.out")
  N=$(cat "$T/ctl/n" 2>/dev/null || echo 0)
}
leg_rows() { # leg_rows <host>: the row arguments that host's leg gets (after the run dir), one per line, as the
  # remote login shell parses the one command string ssh sends it (so a row must arrive quoted)
  local i
  local -a a w
  for ((i = 0; i < N; i++)); do
    mapfile -d '' a < "$T/ctl/call.$i"
    local j
    for ((j = 1; j < ${#a[@]}; j++)); do
      if [ "${a[j]}" = "$1" ] && [ "${a[j+1]:-}" = /bin/bash ] && [ "${a[j+2]:-}" = -s ] \
         && [[ "${a[j+3]:-}" =~ ^zb-gate-[0-9a-f]{40}-[0-9a-f]+$ ]]; then
        mapfile -t w < <(bash -c "printf '%s\\n' ${a[*]:j+4}" 2>/dev/null)
        printf '%s\n' "${w[@]}"
      fi
    done
  done
}
selected_first() { # every fake ssh/scp contact came after exactly one ROWS_SELECTED line, which the gate printed once
  [ "$(grep -c '^ROWS_SELECTED' <<<"$OUT")" -eq 1 ] && [ -s "$T/ctl/transcript" ] \
    && ! grep -qv $'^CONTACT\t\(ssh\|scp\)\t1$' "$T/ctl/transcript"
}
row_of() { local r; for r in "${ROWS[@]}"; do [ "${r##*|}" = "$1" ] && printf '%s\n' "$r"; done; }

run_gate __UNSET__   # S1
if [ "$(leg_rows "$INTEL")" = "$(printf '%s\n' "${ROWS[@]}")" ] && [ "$(leg_rows "$ARM")" = "$(printf '%s\n' "${ROWS[@]}")" ] \
   && selected_first; then
  ok "S1 unset: each leg gets all ${#ROWS[@]} rows in ROWS order; ROWS_SELECTED once, before every contact"
else bad "S1 unset: rc=$RC intel legs got $(leg_rows "$INTEL" | wc -l) rows, arm $(leg_rows "$ARM" | wc -l): $(tail -n 12 <<<"$OUT" | tr '\n' ' ')"; fi

run_gate "ms2c-recover-slow-server ms2a-load-fail-no-quit"   # S2, named out of order
want=$(row_of ms2a-load-fail-no-quit; row_of ms2c-recover-slow-server)
if [ "$RC" -eq 0 ] && [ "$(leg_rows "$INTEL")" = "$want" ] && [ "$(leg_rows "$ARM")" = "$want" ] \
   && grep -qx $'ROWS_SELECTED\tms2a-load-fail-no-quit\tms2c-recover-slow-server' <<<"$OUT" && selected_first; then
  ok "S2 a selection: each leg gets exactly those rows in ROWS order; ROWS_SELECTED names them, once, before every contact"
else bad "S2 selection: rc=$RC intel=[$(leg_rows "$INTEL" | tr '\n' ' ')] $(grep ROWS_SELECTED <<<"$OUT")"; fi

for case in "S3 unknown id|ms2a-load-fail-no-quit no-such-row" "S4 duplicate id|ms2a-load-fail-no-quit ms2a-load-fail-no-quit" \
            "S5 empty selection|" "S5 blank selection|   "; do
  name=${case%%|*} sel=${case#*|}
  run_gate "$sel"
  if [ "$RC" -eq 1 ] && [ "$N" -eq 0 ] && [ ! -s "$T/ctl/transcript" ] && grep -q '^NOT RUN' <<<"$OUT"; then ok "$name: NOT RUN, exit 1, no ssh/scp call"
  else bad "$name: rc=$RC calls=$N $(head -2 <<<"$OUT" | tr '\n' ' ')"; fi
done

for id in ms2a-load-fail-no-quit ms2c-recover-slow-server; do   # F1
  r=$(row_of "$id")
  if [ "$(cut -d'|' -f2 <<<"$r")" = green ]; then ok "F1 $id is a green row"; else bad "F1 $id is not a green row: $r"; fi
done

# L: the leg itself, hostlessly.
RRD=zb-gate-0000000000000000000000000000000000000000-1
LH="$T/rows-home" CR="$T/rows-home/Library/Logs/DiagnosticReports"
mkdir -p "$T/rows-bin" "$T/vf/T" "$T/vf/C" "$CR" "$LH/$RRD/tests/mac"
for h in mac_varfolders_audit.sh mac_crashreports_audit.sh; do
  [ -f "$ROOT/tests/mac/$h" ] && cp "$ROOT/tests/mac/$h" "$LH/$RRD/tests/mac/"
done
echo "an older report" > "$CR/old.ips"
cat > "$T/rows-bin/getconf" <<EOF
#!/bin/bash
case "\$1" in DARWIN_USER_TEMP_DIR) echo "$T/vf/T/" ;; DARWIN_USER_CACHE_DIR) echo "$T/vf/C/" ;; *) exit 1 ;; esac
EOF
cat > "$T/rows-bin/python3" <<EOF
#!/bin/bash
printf '%s\n' "\$1" >> "$T/rows-calls"   # every row invocation (each would launch a browser)
case "\$1" in
  *v_red_ok*) printf 'ASSERT\tv-red\ta\tfail\nFAIL\tv-red\nRED_SHAPE\tv-red\n'; exit 1 ;;
  *v_crash*)  printf '{"crash": "zigBrowser"}\n' > "$CR/zigBrowser-2026-10-23.ips"
              printf 'ASSERT\tv-red\ta\tfail\nFAIL\tv-red\nRED_SHAPE\tv-red\n'; exit 1 ;;
  *v_leak*)   printf 'FAIL\tv-red\nLEAK\t4242\t4242\tThu Oct 22 21:00:00 2026\t/x/zigBrowser --e2e-protocol\n'; exit 1 ;;
esac
exit 2
EOF
chmod +x "$T/rows-bin/getconf" "$T/rows-bin/python3"
awk "/<<'REMOTE'/{f=1;next} /^REMOTE\$/{f=0} f" "$ROOT/$GATE" > "$T/rows-leg.sh"
leg() { # leg <rows...>: sets LOUT LRC
  LOUT=$(cd / && env -i PATH="$T/rows-bin:/usr/bin:/bin" HOME="$LH" bash "$T/rows-leg.sh" "$RRD" "$@" 2>&1)
  LRC=$?
  rm -f -- "${LH:?}/${RRD:?}/LEAKED"
}
old_sha=$(sha256sum "$CR/old.ips" | cut -d' ' -f1)

leg "tests/e2e/mac_v_red_ok_test.py|red|v-red"   # L1
if [ "$LRC" -eq 0 ] && grep -qx $'CRASHREPORTS\tCOMPLETE\t0' <<<"$LOUT" && [ "$(sha256sum "$CR/old.ips" | cut -d' ' -f1)" = "$old_sha" ]; then
  ok "L1 no new crash report: CRASHREPORTS COMPLETE 0, leg exit 0, the existing report untouched"
else bad "L1: rc=$LRC $(grep -E '^CRASHREPORT' <<<"$LOUT" | tr '\n' ' ')"; fi

leg "tests/e2e/mac_v_crash_test.py|red|v-red"   # L2
sha=$(sha256sum "$CR/zigBrowser-2026-10-23.ips" 2>/dev/null | cut -d' ' -f1)
if [ "$LRC" -eq 5 ] && grep -qx $'ROW\ttests/e2e/mac_v_crash_test.py\tred\trc=1\tMATCH' <<<"$LOUT" \
   && grep -qx $'CRASHREPORT\tadded\tzigBrowser-2026-10-23.ips\t'"$sha" <<<"$LOUT" \
   && grep -q $'^CRASHREPORTS\tINCONCLUSIVE\t.' <<<"$LOUT" && [ -e "$CR/zigBrowser-2026-10-23.ips" ]; then
  ok "L2 a new crash report in the real home: reported with its sha256, INCONCLUSIVE, leg exit 5 though the row matched"
else bad "L2: rc=$LRC $(grep -E '^(ROW|CRASHREPORT)' <<<"$LOUT" | tr '\n' ' ')"; fi
rm -f -- "$CR/zigBrowser-2026-10-23.ips"

leg "tests/e2e/mac_v_leak_test.py|red|v-red"   # L3
if [ "$LRC" -eq 3 ] && grep -q $'^HOST_STOPPED\t' <<<"$LOUT" && grep -q $'^CRASHREPORTS\t' <<<"$LOUT"; then
  ok "L3 a leak stop still prints the crash-report listing, and exits 3"
else bad "L3: rc=$LRC $(grep -E '^(HOST_STOPPED|CRASHREPORTS)' <<<"$LOUT" | tr '\n' ' ')"; fi

no_start() { # no_start <row> <why>: the leg refused before its RUNNING marker
  if [ "$LRC" -eq 5 ] && [ "$(grep -c $'^ROW\t' <<<"$LOUT")" -eq 0 ] && [ ! -s "$T/rows-calls" ] && [ "$MARK" = no ]; then
    ok "$1: $2: the leg exits 5 with zero rows, zero browser launches and no RUNNING marker"
  else bad "$1: $2: rc=$LRC rows=$(grep -c $'^ROW\t' <<<"$LOUT") calls=$(wc -l < "$T/rows-calls" 2>/dev/null) marker=$MARK"; fi
}
leg_marked() { # leg_marked <rows...>: as leg, and records whether a RUNNING marker was written (MARK)
  : > "$T/rows-calls"
  if [ "${LEG_UNPRIVILEGED:-0}" = 1 ]; then
    # The required outer namespace maps the test process to root. Remap that same underlying user to uid 1000 so
    # mode-000 remains genuinely unreadable without granting any external access.
    LOUT=$(cd / && unshare --user --map-user=1000 --map-group=1000 \
      env -i PATH="$T/rows-bin:/usr/bin:/bin" HOME="$LH" bash "$T/rows-leg.sh" "$RRD" "$@" 2>&1)
  else
    LOUT=$(cd / && env -i PATH="$T/rows-bin:/usr/bin:/bin" HOME="$LH" bash "$T/rows-leg.sh" "$RRD" "$@" 2>&1)
  fi
  LRC=$?
  MARK=no; [ -e "$LH/$RRD/LEAKED" ] && MARK=yes
  rm -f -- "${LH:?}/${RRD:?}/LEAKED"
}

mkdir -p "$CR/Locked" && chmod 0 "$CR/Locked"   # L4
LEG_UNPRIVILEGED=1 leg_marked "tests/e2e/mac_v_red_ok_test.py|red|v-red"
chmod 700 "$CR/Locked" && rmdir -- "$CR/Locked"
if grep -q $'CRASHREPORTS\tINCONCLUSIVE\tbegin refused' <<<"$LOUT"; then no_start L4 "a refused crash-report begin"
else bad "L4: no crash-report begin refusal line: rc=$LRC $(grep -E '^CRASHREPORTS' <<<"$LOUT" | tr '\n' ' ')"; fi

leg_marked "tests/e2e/mac_v_red_ok_test.py|red|v-red"   # L5
first_row=$(grep -n $'^ROW\t' <<<"$LOUT" | head -1 | cut -d: -f1)
last_self=$(grep -n '^SELFAUDIT' <<<"$LOUT" | tail -1 | cut -d: -f1)
statuses=$(grep '^SELFAUDIT_STATUS' <<<"$LOUT")
want_status=$(printf 'SELFAUDIT_STATUS\t%s\t0\n' outer-begin inner-varfolders inner-crashreports inner-evidence outer-end)
step_last() { grep $'^SELFAUDIT\t'"$1"$'\t' <<<"$LOUT" | tail -1 | cut -f3-; }
if [ "$LRC" -eq 0 ] && [ "$statuses" = "$want_status" ] && [ -z "$(grep $'^SELFAUDIT\touter-begin\t' <<<"$LOUT")" ] \
   && [ -z "$(grep $'^SELFAUDIT\tinner-evidence\t' <<<"$LOUT")" ] \
   && [ "$(step_last inner-varfolders)" = $'VARFOLDERS\tCOMPLETE\t0' ] \
   && [ "$(step_last inner-crashreports)" = $'CRASHREPORTS\tCOMPLETE\t0' ] \
   && [ "$(step_last outer-end)" = $'VARFOLDERS\tCOMPLETE\t0' ] \
   && [ -n "$first_row" ] && [ -n "$last_self" ] && [ "$last_self" -lt "$first_row" ]; then
  ok "L5 the self-audit ran first: a silent outer begin, a full inner /var/folders and crash-report cycle each COMPLETE 0, then an outer COMPLETE 0"
else bad "L5: rc=$LRC statuses=[$(tr '\n' ' ' <<<"$statuses")] inner-vf=[$(step_last inner-varfolders)] inner-cr=[$(step_last inner-crashreports)] outer=[$(step_last outer-end)]"; fi

inject() { # inject <helper file> <function line> <code>: a fake run root helper that misbehaves only in the self-audit
  cp "$LH/$RRD/tests/mac/$1" "$T/$1.real"
  awk -v fn="$2" -v code="$3" '{print} index($0, fn) == 1 {print code}' "$T/$1.real" > "$LH/$RRD/tests/mac/$1"
  grep -q 'selftest' "$LH/$RRD/tests/mac/$1" || bad "could not inject into $1"
}
restore() { cp "$T/$1.real" "$LH/$RRD/tests/mac/$1"; }
for case in "inner /var/folders begin refused|mac_varfolders_audit.sh|varfolders_begin() {|  case \"\$1\" in */selfaudit/inner) __vf_refuse \"selftest\"; return ;; esac" \
            "inner /var/folders end not COMPLETE|mac_varfolders_audit.sh|varfolders_end() {|  case \"\$1\" in */selfaudit/inner) printf 'VARFOLDERS\\tINCONCLUSIVE\\tselftest\\n'; return 0 ;; esac" \
            "inner crash-report begin refused|mac_crashreports_audit.sh|crashreports_begin() {|  case \"\$1\" in */selfaudit/crash) __cr_refuse \"selftest\"; return ;; esac"; do
  IFS='|' read -r name file fn code <<<"$case"
  inject "$file" "$fn" "$code"
  leg_marked "tests/e2e/mac_v_red_ok_test.py|red|v-red"   # L7
  restore "$file"
  no_start L7 "an $name in the self-audit"
done

rm -rf -- "${LH:?}/${RRD:?}/evidence/crashreports"   # L8: the crash-report evidence path is a file
mkdir -p "$LH/$RRD/evidence" && : > "$LH/$RRD/evidence/crashreports"
leg_marked "tests/e2e/mac_v_red_ok_test.py|red|v-red"
rm -f -- "$LH/$RRD/evidence/crashreports"
if [ "$(grep -c $'^CRASHREPORTS\tINCONCLUSIVE\tbegin refused' <<<"$LOUT")" -eq 1 ]; then no_start L8 "a crash-report evidence dir that cannot be made"
else bad "L8: want exactly one crash-report begin refusal: rc=$LRC $(grep -E '^CRASHREPORTS' <<<"$LOUT" | tr '\n' ' ')"; fi

cp "$LH/$RRD/tests/mac/mac_varfolders_audit.sh" "$T/vf-helper.real"   # L6: a helper that writes under T itself
awk '{print} /^  \[ "\$pt" != "\$pc" \]/{print "  : > \"$pt/zb-helper-wrote\""}' "$T/vf-helper.real" \
  > "$LH/$RRD/tests/mac/mac_varfolders_audit.sh"
grep -q zb-helper-wrote "$LH/$RRD/tests/mac/mac_varfolders_audit.sh" || bad "L6: could not build the writing helper"
leg_marked "tests/e2e/mac_v_red_ok_test.py|red|v-red"
cp "$T/vf-helper.real" "$LH/$RRD/tests/mac/mac_varfolders_audit.sh"; rm -f -- "$T/vf/T/zb-helper-wrote"
if grep -q $'^SELFAUDIT\t[a-z-]*\tVARFOLDERS-DELTA\t[a-z]*\tT\tzb-helper-wrote\t' <<<"$LOUT"; then no_start L6 "a helper that writes under T"
else bad "L6: the self-audit did not show the helper's own write: rc=$LRC $(grep -E '^SELFAUDIT' <<<"$LOUT" | tail -3 | tr '\n' ' ')"; fi

if [ "$fails" -eq 0 ]; then printf 'PASS\tms-runtime-rows-select-selftest\n'; exit 0; fi
printf 'FAIL\tms-runtime-rows-select-selftest\t%s failure(s)\n' "$fails"
exit 1
