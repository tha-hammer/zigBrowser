#!/usr/bin/env bash
# More hostless rows for the 4pa.80 spike's write containment (SilverRidge 0d0656f4 fix-forward of c39c0a15). It runs
# the scaffolding of tests/mac/bundle_layout_spike_containment_selftest.sh (everything from its ROOT= line up to its
# "# ===== K1-K4: clean =====" marker: the private user+mount+network namespace, the /usr/bin overlay with the
# enforcing fake sandbox-exec, the executing stub ssh/scp, the fake Mac homes and tools, the scratch repo and the
# helpers), so the same real runner and leg driver are driven. Then, on top:
#   - a recording fake `sort` on the Mac PATH (it logs whether it ran inside the sandbox and where its temporary files
#     may go: -T <dir>, else TMPDIR);
#   - the stub ssh wrapped so a `remove` can fail at the transport (exit 255, nothing run) and every remove attempt
#     is counted.
# Rows:
#   F1 a verify that reports "code object is not signed at all": on the normal run LAYOUT-FINDING on that leg
#      (LAYOUT-OK on the other), exit 0; under data_in_frameworks EXPECTED-FAIL on both legs, exit 0;
#   F2 every `sort` on the Mac runs inside the sandbox with its temporary storage below the physical run root, at
#      least three per leg (both audit snapshots and the signing order), and the snapshots are still complete;
#   F3 a remove that keeps failing at the transport: the leg is INCONCLUSIVE naming the host and the root, the run
#      exits 2, the root is still there, the evidence was copied before, remove was retried (2-5 attempts, so bounded)
#      and a RETAINED<TAB><host><TAB><run dir> line names it; a remove that fails once then succeeds: the leg keeps
#      its verdict, exit 0, the root is gone, exactly 2 attempts; Intel's remove keeps failing while the later arm64
#      remove succeeds (SilverRidge 50160137): exit 2, x86_64=INCONCLUSIVE arm64=LAYOUT-OK, exactly one Intel root kept
#      and named by exactly one RETAINED line, no arm64 root, exactly 4 Intel attempts (3 retries + the EXIT attempt)
#      and 1 arm64 attempt, the Intel evidence copied (the arm success must not drop Intel's live entry).
# No Mac, no signal, no network. Run: bash tests/mac/bundle_layout_spike_containment_ff_selftest.sh [repo root]
set -uo pipefail
if [ "${ZB_CONTAIN_SELFTEST_INNER:-}" != 1 ]; then
  ZB_CONTAIN_SELFTEST_INNER=1 exec unshare --user --map-root-user --mount --net bash "$(realpath "$0")" "$@"
fi
SCAFFOLD="$(realpath "${1:-.}")/tests/mac/bundle_layout_spike_containment_selftest.sh"
grep -q '^# ===== K1-K4: clean =====$' "$SCAFFOLD" || { echo "FAIL no scaffolding marker in $SCAFFOLD"; exit 1; }
# shellcheck source=/dev/null
source <(sed -n '/^ROOT=\$(realpath/,/^# ===== K1-K4: clean =====$/p' "$SCAFFOLD")

fake "$X/hostbin/sort" <<'EOF'
tmp=${TMPDIR:-} prev=
for a in "$@"; do [ "$prev" = -T ] && tmp=$a; case "$a" in -T?*) tmp=${a#-T} ;; esac; prev=$a; done
[ -z "${ZB_ROLE:-}" ] || printf '%s\t%s\t%s\t%s\n' "${ZB_FAKE_SANDBOXED:-0}" "$ZB_ROLE" "$tmp" "$*" >> "$C/sort.log"
exec /usr/bin/sort "$@"
EOF
mv "$X/bin/ssh" "$X/bin/ssh.inner"
fake "$X/bin/ssh" <<'EOF'
case " $* " in
  *" /bin/bash -s remove "*)
    case " $* " in *" intel@"*) role=intel ;; *) role=arm ;; esac
    n=$(cat "$C/remove.$role" 2>/dev/null || echo 0); echo $((n + 1)) > "$C/remove.$role"
    case "$(cat "$C/scenario")" in
      remove_fail_always) echo "ssh: connect to host port 22: Connection reset by peer" >&2; exit 255 ;;
      remove_fail_once) [ "$n" -gt 0 ] || { echo "ssh: connect to host port 22: Connection reset by peer" >&2; exit 255; } ;;
      remove_fail_intel) [ "$role" = arm ] || { echo "ssh: connect to host port 22: Connection reset by peer" >&2; exit 255; } ;;
    esac ;;
esac
exec "$X/bin/ssh.inner" "$@"
EOF

# ===== F1: "code object is not signed at all" =====
run_spike notsigned none notsigned arm
{ [ "$rc" -eq 0 ] && [ "$(leg_class x86_64)" = LAYOUT-OK ] && [ "$(leg_class arm64)" = LAYOUT-FINDING ] \
  && [ "$(spike_result)" = "x86_64=LAYOUT-OK arm64=LAYOUT-FINDING" ]; } \
  && ok "notsigned F1: a not-signed verify on arm64 is LAYOUT-FINDING, Intel LAYOUT-OK, exit 0" \
  || bad "notsigned F1: exit $rc, '$(leg_class x86_64): $(leg_detail x86_64)' '$(leg_class arm64): $(leg_detail arm64)'"
run_spike notsigned_mutant none notsigned both ZB_SPIKE_MUTANT=data_in_frameworks
{ [ "$rc" -eq 0 ] && [ "$(spike_result)" = "x86_64=EXPECTED-FAIL arm64=EXPECTED-FAIL" ] \
  && grep -qx ./Contents/Frameworks/stray-data.txt "$C/tree.intel" && grep -qx ./Contents/Frameworks/stray-data.txt "$C/tree.arm"; } \
  && ok "notsigned_mutant F1: data_in_frameworks with a not-signed verify is EXPECTED-FAIL on both legs, exit 0" \
  || bad "notsigned_mutant F1: exit $rc, '$(leg_class x86_64): $(leg_detail x86_64)' '$(leg_class arm64): $(leg_detail arm64)'"

# ===== F2: every sort on the Mac is sandboxed, its temporary storage in the root =====
run_spike sort none clean both
for role in intel arm; do
  arch=x86_64; [ "$role" = arm ] && arch=arm64
  rt=$(root_of "$role")
  n=$(awk -F'\t' -v r="$role" '$2 == r' "$C/sort.log" 2>/dev/null | wc -l)
  outside=$(awk -F'\t' -v r="$role" -v rt="$rt/" '$2 == r && ($1 != 1 || index($3 "/", rt) != 1) { print "sandboxed=" $1 " tmp=" $3 " args=" $4 }' "$C/sort.log" 2>/dev/null)
  if [ "$rc" -eq 0 ] && [ -n "$rt" ] && [ "$n" -ge 3 ] && [ -z "$outside" ] && [ "$(leg_class "$arch")" = LAYOUT-OK ] \
     && grep -q "^$X/hosts/$role/.profile|" "$IN"/evidence/"$arch"-*/evidence/audit.before 2>/dev/null; then
    ok "sort F2 $role: all $n sorts ran inside the sandbox with temporary storage below $rt; the snapshots are complete"
  else bad "sort F2 $role: exit $rc, $n sorts, root '$rt', outside the sandbox or the root: $(tr '\n' ';' <<<"$outside")"; fi
done

# ===== F3: a failed ordinary remove fails closed =====
run_spike remove_always remove_fail_always clean both ZB_SPIKE_REMOVE_SLEEP=0
for role in intel arm; do
  arch=x86_64 host=$INTEL; [ "$role" = arm ] && arch=arm64 host=$ARM
  left=$(find "$X/hosts/$role" -maxdepth 1 -name "zb-gate-$SHA-*" -type d)
  rd=${left##*/}
  tries=$(cat "$C/remove.$role" 2>/dev/null || echo 0)
  if [ "$rc" -eq 2 ] && [ "$(leg_class "$arch")" = INCONCLUSIVE ] && [ -n "$rd" ] && [ "$(wc -l <<<"$left")" -eq 1 ] \
     && [[ "$(leg_detail "$arch")" == *"$rd"*"$host"* ]] && grep -qxF "$(printf 'RETAINED\t%s\t%s' "$host" "$rd")" <<<"$out" \
     && [ "$tries" -ge 2 ] && [ "$tries" -le 5 ] && grep -qx LEGDONE "$IN/evidence/$arch-$rd/driver.out" 2>/dev/null \
     && [ -s "$IN/evidence/$arch-$rd/evidence/audit.after" ]; then
    ok "remove_always F3 $role: INCONCLUSIVE naming $host and the root, RETAINED line, root kept, $tries bounded attempts, evidence copied first"
  else bad "remove_always F3 $role: exit $rc, '$(leg_class "$arch"): $(leg_detail "$arch")', roots '$left', attempts $tries, RETAINED lines: $(grep -c '^RETAINED' <<<"$out")"; fi
done
[ "$(spike_result)" = "x86_64=INCONCLUSIVE arm64=INCONCLUSIVE" ] && ok "remove_always F3: SPIKE-RESULT is INCONCLUSIVE on both legs" \
  || bad "remove_always F3: SPIKE-RESULT '$(spike_result)'"
find "${X:?}/hosts" -maxdepth 2 -name 'zb-gate-*' -type d -exec rm -rf {} +
run_spike remove_mixed remove_fail_intel clean both ZB_SPIKE_REMOVE_SLEEP=0
left_i=$(find "$X/hosts/intel" -maxdepth 1 -name "zb-gate-$SHA-*" -type d); rd_i=${left_i##*/}
left_a=$(find "$X/hosts/arm" -maxdepth 1 -name 'zb-gate-*')
ret=$(grep '^RETAINED' <<<"$out")
if [ "$rc" -eq 2 ] && [ "$(spike_result)" = "x86_64=INCONCLUSIVE arm64=LAYOUT-OK" ] && [ -n "$rd_i" ] && [ "$(wc -l <<<"$left_i")" -eq 1 ] \
   && [ -z "$left_a" ] && [ "$ret" = "$(printf 'RETAINED\t%s\t%s' "$INTEL" "$rd_i")" ] \
   && [ "$(cat "$C/remove.intel" 2>/dev/null)" = 4 ] && [ "$(cat "$C/remove.arm" 2>/dev/null)" = 1 ] \
   && [[ "$(leg_detail x86_64)" == *"$rd_i"*"$INTEL"* ]] && grep -qx LEGDONE "$IN/evidence/x86_64-$rd_i/driver.out" 2>/dev/null \
   && [ -s "$IN/evidence/x86_64-$rd_i/evidence/audit.after" ]; then
  ok "remove_mixed F3: Intel kept failing, arm64 removed: exit 2, x86_64=INCONCLUSIVE arm64=LAYOUT-OK, one RETAINED line for the one Intel root, no arm64 root, 4+1 attempts, Intel evidence copied"
else bad "remove_mixed F3: exit $rc, result '$(spike_result)', intel roots '$left_i', arm roots '$left_a', RETAINED '$(tr '\n' ';' <<<"$ret")', attempts $(cat "$C/remove.intel" 2>/dev/null)/$(cat "$C/remove.arm" 2>/dev/null)"; fi
find "${X:?}/hosts" -maxdepth 2 -name 'zb-gate-*' -type d -exec rm -rf {} +
run_spike remove_once remove_fail_once clean both ZB_SPIKE_REMOVE_SLEEP=0
{ [ "$rc" -eq 0 ] && [ "$(spike_result)" = "x86_64=LAYOUT-OK arm64=LAYOUT-OK" ] && [ -z "$(roots_left)" ] \
  && [ "$(cat "$C/remove.intel" 2>/dev/null)" = 2 ] && [ "$(cat "$C/remove.arm" 2>/dev/null)" = 2 ] && ! grep -q '^RETAINED' <<<"$out"; } \
  && ok "remove_once F3: one failed remove is retried and succeeds; verdicts kept, exit 0, roots gone, 2 attempts per host" \
  || bad "remove_once F3: exit $rc, result '$(spike_result)', roots '$(roots_left)', attempts $(cat "$C/remove.intel" 2>/dev/null)/$(cat "$C/remove.arm" 2>/dev/null)"
find "${X:?}/hosts" -maxdepth 2 -name 'zb-gate-*' -type d -exec rm -rf {} +

if [ "$fails" -eq 0 ]; then printf 'PASS\tmac-bundle-layout-spike-containment-ff-selftest\n'; exit 0; fi
printf 'FAIL\tmac-bundle-layout-spike-containment-ff-selftest\t%s failure(s)\n' "$fails"
exit 1
