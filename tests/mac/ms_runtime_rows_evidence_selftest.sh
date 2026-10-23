#!/usr/bin/env bash
# Registered in zig build test-mac-build-script (red 5a75586a; SilverRidge 0632602f, the blocked 4pa.55 request): the
# runtime rows gate copies a deterministic evidence archive of each leg back to Linux before any remote cleanup, and
# the shared run-dir removal in tests/mac/mac_gate_lib.sh is verified and fails closed.
#
# Shared removal (mac_remove_run_dirs, mac_keep_run_dir), driven with a fake Mac whose ssh runs each remote command
# with bash -c in a private per-host home, as sshd hands it to the login shell:
#   K1 two recorded run dirs: each removed and confirmed absent, REMOVED<TAB><host><TAB><dir>, status 0.
#   K2 a dir the remover cannot delete completely: RETAINED<TAB><host><TAB><dir><TAB><why>, status non-zero, the dir
#      still there, and the other host still REMOVED.
#   K3 ssh fails (exit 255), K3b ssh runs the removal but then exits 255, and K4 ssh exits 0 but runs nothing and
#      confirms nothing: RETAINED, non-zero.
#   K5 a recorded name that is not a run dir (../escape): RETAINED, non-zero, no ssh call, nothing touched.
#   K6 mac_keep_run_dir <host> <dir> <why> prints RETAINED<TAB><host><TAB><dir><TAB><why>; removal then skips it.
#   K7 the remote delete exits 0 but leaves the dir (a find that deletes nothing): RETAINED, non-zero.
# The gate, end to end on two fake Macs (the real gate, build-on-mac.sh, library and helpers; stub getconf and row
# python3 only; ZB_RUNTIME_ROWS = the two 4pa.55 rows; ZB_MAC_EVIDENCE_DIR a fresh empty local dir):
#   E1 success: each leg gets exactly the two rows intact (a row word holds `|`, which the remote shell must not
#      parse); per host one EVIDENCE<TAB><host><TAB><arch><TAB><sha256><TAB><bytes><TAB><local path> line whose sha256
#      and size are the local copy's; the copy holds each row's COMPLETE output (evidence/rows/<id>.out, more than
#      the console's 40-line tail) and the /var/folders and crash-report records; the leg output is kept beside it;
#      then REMOVED for that host after its EVIDENCE line and before the gate's PASS line, both run dirs gone; exit 0
#      and PASS both-arches.
#   E2 the archive is deterministic: the same evidence packed twice gives the same bytes; members in C byte order
#      (not the directory's own order); every member mtime the fixed 2000-01-01 00:00 UTC.
#   E2b a pack that cannot read an entry fails: non-zero, and neither the archive nor its sha256 is left.
#   E3 the self-audit also proves the packer: SELFAUDIT_STATUS 0 for outer-begin, inner-varfolders,
#      inner-crashreports, inner-evidence (silent), outer-end, in that order.
#   E4 a run dir that cannot be removed (arm): RETAINED for it, the dir kept, no gate PASS, exit non-zero.
#   E5 the evidence copy fails (intel; FAILED<TAB>could not copy evidence.tar) and E6 the copy differs from the Mac's
#      sha256 (arm; FAILED<TAB>the copy (...) is not the Mac archive (...)): that run dir RETAINED and present, exit
#      non-zero.
#   E7 a leak stop (intel): the evidence is still copied and verified; the run dir is RETAINED (kept and held), never
#      REMOVED; exit non-zero.
#   E8 ZB_MAC_EVIDENCE_DIR unset, relative, not empty, or a symlink: NOT RUN, exit 1, zero ssh/scp calls.
#   E9 a self-audit failure (the leg never arms its evidence archive): EVIDENCE ... NONE, the run dir RETAINED,
#      exit non-zero.
# Run: bash tests/mac/ms_runtime_rows_evidence_selftest.sh [repo root]
set -uo pipefail
if [ "${ZB_EVIDENCE_SELFTEST_INNER:-}" != 1 ]; then
  ZB_EVIDENCE_SELFTEST_INNER=1 exec unshare --user --map-current-user --net bash "$(realpath "$0")" "$@"
fi
ROOT=$(realpath "${1:-.}")
BASE=$(mktemp -d "${TMPDIR:-/tmp}/zb-evidence-selftest-XXXXXX")
T=$(realpath "$BASE")
cleanup() {
  case "$T" in "$(realpath "${TMPDIR:-/tmp}")"/zb-evidence-selftest-??????) chmod -R u+rwx "${T:?}" 2>/dev/null; rm -rf "${T:?}" ;; esac
}
trap cleanup EXIT
fails=0
ok() { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }
INTEL=intel@10.0.0.1 ARM=arm@10.0.0.2
GATE=tests/mac/ms_runtime_rows_gate.sh
RD_RE='zb-gate-[0-9a-f]{40}-[0-9a-f]+'

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
mkdir -p "\$h" && cd "\$h" || exit 1
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
  tests/e2e/mac_ms2a_load_fail_no_quit_test.py) id=ms2a-load-fail-no-quit ;;
  tests/e2e/mac_ms2c_recover_slow_server_test.py) id=ms2c-recover-slow-server ;;
  *) printf 'unexpected row %s\n' "$1"; exit 2 ;;
esac
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

# K: the shared removal, sourced from the scratch repo top.
RDA="zb-gate-$SHA-a1" RDB="zb-gate-$SHA-b2"
lib() { # lib <bash code>: run with the library sourced; sets KOUT KRC
  KOUT=$(cd "$R" && env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" bash -c '. tests/mac/mac_gate_lib.sh; '"$1" 2>&1)
  KRC=$?
}
two_roots() { mkdir -p "$T/mac/$INTEL/$RDA/evidence" "$T/mac/$ARM/$RDB/sub"; echo e > "$T/mac/$INTEL/$RDA/evidence/x"; }
REC="MAC_RUN_DIRS=('$INTEL'\$'\\t''$T/fake_mac_key'\$'\\t''$RDA' '$ARM'\$'\\t''$T/fake_mac_key'\$'\\t''$RDB')"

fresh_macs; two_roots
lib "$REC; mac_remove_run_dirs"
if [ "$KRC" -eq 0 ] && grep -qx $'REMOVED\t'"$INTEL"$'\t'"$RDA" <<<"$KOUT" && grep -qx $'REMOVED\t'"$ARM"$'\t'"$RDB" <<<"$KOUT" \
   && ! grep -q '^RETAINED' <<<"$KOUT" && [ ! -e "$T/mac/$INTEL/$RDA" ] && [ ! -e "$T/mac/$ARM/$RDB" ]; then
  ok "K1 both run dirs removed and confirmed absent: REMOVED per host, status 0"
else bad "K1: rc=$KRC $(tr '\n' ' ' <<<"$KOUT")"; fi

fresh_macs; two_roots
mkdir -p "$T/mac/$ARM/$RDB/locked/x" && : > "$T/mac/$ARM/$RDB/locked/x/f" && chmod 500 "$T/mac/$ARM/$RDB/locked/x"
lib "$REC; mac_remove_run_dirs"
chmod -R u+rwx "$T/mac/$ARM" 2>/dev/null
if [ "$KRC" -ne 0 ] && grep -q $'^RETAINED\t'"$ARM"$'\t'"$RDB"$'\t.' <<<"$KOUT" && ! grep -q $'^REMOVED\t'"$ARM" <<<"$KOUT" \
   && [ -d "$T/mac/$ARM/$RDB" ] && grep -qx $'REMOVED\t'"$INTEL"$'\t'"$RDA" <<<"$KOUT"; then
  ok "K2 a run dir that cannot be removed completely: RETAINED with a reason, status non-zero, the other host REMOVED"
else bad "K2: rc=$KRC $(tr '\n' ' ' <<<"$KOUT")"; fi

for k in "K3 ssh fails|ssh-fail" "K3b ssh runs the removal, then exits 255|ssh-fail-after" \
         "K4 ssh runs nothing and confirms nothing|ssh-silent" "K7 the remote delete exits 0 and removes nothing|find-noop"; do
  fresh_macs; two_roots; : > "$T/ctl/${k#*|}"
  lib "$REC; mac_remove_run_dirs"
  if [ "$KRC" -ne 0 ] && grep -q $'^RETAINED\t'"$INTEL"$'\t'"$RDA"$'\t.' <<<"$KOUT" && grep -q $'^RETAINED\t'"$ARM"$'\t'"$RDB"$'\t.' <<<"$KOUT" \
     && ! grep -q '^REMOVED' <<<"$KOUT"; then ok "${k%%|*}: both RETAINED, status non-zero"
  else bad "${k%%|*}: rc=$KRC $(tr '\n' ' ' <<<"$KOUT")"; fi
done

fresh_macs; mkdir -p "$T/mac/escape" && echo keep > "$T/mac/escape/f"
lib "MAC_RUN_DIRS=('$INTEL'\$'\\t''$T/fake_mac_key'\$'\\t''../escape'); mac_remove_run_dirs"
if [ "$KRC" -ne 0 ] && grep -q $'^RETAINED\t'"$INTEL"$'\t../escape\t.' <<<"$KOUT" && [ "$(calls)" -eq 0 ] && [ -e "$T/mac/escape/f" ]; then
  ok "K5 a recorded name that is not a run dir: RETAINED, status non-zero, no ssh call, nothing touched"
else bad "K5: rc=$KRC calls=$(calls) $(tr '\n' ' ' <<<"$KOUT")"; fi

fresh_macs; two_roots
lib "$REC; mac_keep_run_dir '$INTEL' '$RDA' 'kept for a person'; mac_remove_run_dirs"
if grep -qx $'RETAINED\t'"$INTEL"$'\t'"$RDA"$'\tkept for a person' <<<"$KOUT" && [ -d "$T/mac/$INTEL/$RDA" ] \
   && grep -qx $'REMOVED\t'"$ARM"$'\t'"$RDB" <<<"$KOUT" && ! grep -q $'^REMOVED\t'"$INTEL" <<<"$KOUT"; then
  ok "K6 mac_keep_run_dir reports RETAINED with its reason, and removal skips that dir"
else bad "K6: rc=$KRC $(tr '\n' ' ' <<<"$KOUT")"; fi

# E: the gate end to end.
EVD="$T/evidence"
run_gate() { # run_gate [VAR=value...]: a fresh EVD unless the caller made one; sets OUT RC
  [ -e "$EVD" ] || mkdir -m 700 "$EVD"
  (cd "$R" && env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" TMPDIR="$T/tmp" ZB_MAC_HOST="$INTEL" ZB_MAC_ARM_HOST="$ARM" \
     ZB_MAC_KEY="$T/fake_mac_key" ZB_RUNTIME_ROWS="ms2a-load-fail-no-quit ms2c-recover-slow-server" \
     ZB_MAC_EVIDENCE_DIR="$EVD" "$@" timeout 300 bash "$GATE" > "$T/gate.out" 2>&1 </dev/null)
  RC=$?
  OUT=$(cat "$T/gate.out")
}
reset_evd() { chmod -R u+rwx "$EVD" 2>/dev/null; rm -rf -- "${EVD:?}"; }
rd_of() { grep -oE "$RD_RE" <<<"$(cat "$T/mac/$1"/row-calls 2>/dev/null; ls "$T/mac/$1" 2>/dev/null)" | head -1; }
ev_line() { grep $'^EVIDENCE\t'"$1"$'\t'"$2"$'\t' <<<"$OUT"; }
ev_ok() { # ev_ok <host> <arch>: its EVIDENCE line names the local copy, with that copy's sha256 and size
  local l f
  l=$(ev_line "$1" "$2"); f="$EVD/$2/evidence.tar"
  [ "$(grep -c . <<<"$l")" -eq 1 ] && [ -f "$f" ] \
    && [ "$l" = "EVIDENCE"$'\t'"$1"$'\t'"$2"$'\t'"$(sha256sum "$f" | cut -d' ' -f1)"$'\t'"$(wc -c < "$f")"$'\t'"$f" ]
}
member() { tar -xOf "$EVD/$1/evidence.tar" "$2" 2>/dev/null; }
line_no() { grep -n -m1 -- "$1" <<<"$OUT" | cut -d: -f1; }

fresh_macs; reset_evd; run_gate   # E1
e1=1 why=
for hl in "$INTEL|x86_64" "$ARM|arm64"; do
  h=${hl%|*} a=${hl#*|}
  [ "$(cat "$T/mac/$h/row-calls" 2>/dev/null)" = $'tests/e2e/mac_ms2a_load_fail_no_quit_test.py\ntests/e2e/mac_ms2c_recover_slow_server_test.py' ] \
    || { e1=0 why+=" $a: rows=[$(tr '\n' ' ' < "$T/mac/$h/row-calls" 2>/dev/null)]"; }
  ev_ok "$h" "$a" || { e1=0 why+=" $a: evidence=[$(ev_line "$h" "$a")]"; continue; }
  for id in ms2a-load-fail-no-quit ms2c-recover-slow-server; do
    [ "$(member "$a" "evidence/rows/$id.out")" = "$(row_text "$id")" ] || { e1=0 why+=" $a: rows/$id.out not complete"; }
  done
  tar -tf "$EVD/$a/evidence.tar" | grep -q '^evidence/varfolders/.' && tar -tf "$EVD/$a/evidence.tar" | grep -q '^evidence/crashreports/.' \
    || { e1=0 why+=" $a: no audit records"; }
  grep -q '^EVIDENCE_ARMED$' "$EVD/$a/leg.out" 2>/dev/null && grep -q $'^ROW\t' "$EVD/$a/leg.out" || { e1=0 why+=" $a: no kept leg output"; }
  rm_l=$(grep -n -m1 $'^REMOVED\t'"$h"$'\t' <<<"$OUT" | cut -d: -f1); ev_l=$(line_no $'^EVIDENCE\t'"$h")
  pass_l=$(line_no $'^PASS\tms-runtime-rows-gate\t')
  { [ -n "$rm_l" ] && [ -n "$ev_l" ] && [ -n "$pass_l" ] && [ "$ev_l" -lt "$rm_l" ] && [ "$rm_l" -lt "$pass_l" ]; } \
    || { e1=0 why+=" $a: REMOVED not after EVIDENCE and before PASS"; }
  [ -z "$(ls "$T/mac/$h" | grep -E "^$RD_RE$")" ] || { e1=0 why+=" $a: run dir left"; }
done
if [ "$e1" -eq 1 ] && [ "$RC" -eq 0 ] && grep -qx $'PASS\tms-runtime-rows-gate\tboth-arches' <<<"$OUT"; then
  ok "E1 success: both rows intact on each leg; evidence copied and verified, complete row outputs and audit records; REMOVED after EVIDENCE; PASS"
else bad "E1: rc=$RC$why"; fi

# E2: the leg's packer, alone, twice over the same evidence.
awk '/^pack_evidence\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$ROOT/$GATE" > "$T/pack.sh"
# Made in an order whose directory listing is not C order (a, c, B, then b).
mkdir -p "$T/p1/evidence/a"; printf 'two\n' > "$T/p1/evidence/a/y"; printf 'four\n' > "$T/p1/evidence/c"
printf 'three\n' > "$T/p1/evidence/B"; mkdir -p "$T/p1/evidence/b"; printf 'one\n' > "$T/p1/evidence/b/z"
cp -a "$T/p1" "$T/p2"; touch -d '2026-10-23 12:00' "$T/p2/evidence/a/y" "$T/p2/evidence/b"
p1=$(bash -c '. "$1"; pack_evidence "$2/evidence"' _ "$T/pack.sh" "$T/p1" 2>&1; echo "rc=$?")
p2=$(bash -c '. "$1"; pack_evidence "$2/evidence"' _ "$T/pack.sh" "$T/p2" 2>&1; echo "rc=$?")
names=$(tar -tf "$T/p1/evidence.tar" 2>/dev/null)
sorted=$(LC_ALL=C sort <<<"$names")
times=$(TZ=UTC tar -tvf "$T/p1/evidence.tar" 2>/dev/null | awk '{print $4, $5}' | sort -u)
if [ -s "$T/pack.sh" ] && [ "$p1" = rc=0 ] && [ "$p2" = rc=0 ] && cmp -s "$T/p1/evidence.tar" "$T/p2/evidence.tar" \
   && [ "$names" = "$sorted" ] && [ "$(grep -c . <<<"$names")" -eq 7 ] && [ "$times" = "2000-01-01 00:00" ] \
   && [ "$(cut -d' ' -f1 "$T/p1/evidence.tar.sha256")" = "$(sha256sum "$T/p1/evidence.tar" | cut -d' ' -f1)" ]; then
  ok "E2 the archive is deterministic: equal bytes for equal evidence, C-ordered members, fixed mtimes, its sha256 beside it"
else bad "E2: pack=[$p1|$p2] names=[$(tr '\n' ' ' <<<"$names")] times=[$times]"; fi
mkdir -p "$T/p3/evidence" && printf 'x\n' > "$T/p3/evidence/a" && printf 'y\n' > "$T/p3/evidence/locked" && chmod 000 "$T/p3/evidence/locked"
p3=$(bash -c '. "$1"; pack_evidence "$2/evidence"' _ "$T/pack.sh" "$T/p3" 2>/dev/null; echo "rc=$?")
chmod 600 "$T/p3/evidence/locked"
if [ -s "$T/pack.sh" ] && [ "$p3" != rc=0 ] && [ ! -e "$T/p3/evidence.tar" ] && [ ! -e "$T/p3/evidence.tar.sha256" ]; then
  ok "E2b a pack that cannot read an entry: non-zero, no archive and no sha256 left"
else bad "E2b: pack=[$p3] tar=$([ -e "$T/p3/evidence.tar" ] && echo left) sha=$([ -e "$T/p3/evidence.tar.sha256" ] && echo left)"; fi

statuses=$(grep '^SELFAUDIT_STATUS' "$EVD/x86_64/leg.out" 2>/dev/null)   # E3, from E1's kept intel leg output
want_status=$(printf 'SELFAUDIT_STATUS\t%s\t0\n' outer-begin inner-varfolders inner-crashreports inner-evidence outer-end)
if [ "$statuses" = "$want_status" ] && ! grep -q $'^SELFAUDIT\tinner-evidence\t' "$EVD/x86_64/leg.out"; then
  ok "E3 the self-audit also runs the evidence packer (silent, status 0) inside the outer /var/folders audit"
else bad "E3: statuses=[$(tr '\n' ' ' <<<"$statuses")]"; fi
reset_evd

fresh_macs; : > "$T/mac/$ARM/ctl-lock"; run_gate   # E4
rd=$(ls "$T/mac/$ARM" | grep -E "^$RD_RE$" | head -1)
if [ "$RC" -ne 0 ] && [ -n "$rd" ] && grep -q $'^RETAINED\t'"$ARM"$'\t'"$rd"$'\t.' <<<"$OUT" && ! grep -q $'^REMOVED\t'"$ARM" <<<"$OUT" \
   && ! grep -q $'^PASS\tms-runtime-rows-gate' <<<"$OUT" && grep -q $'^REMOVED\t'"$INTEL" <<<"$OUT"; then
  ok "E4 a run dir that cannot be removed: RETAINED and kept, no gate PASS, exit non-zero"
else bad "E4: rc=$RC rd=$rd $(grep -E '^(REMOVED|RETAINED|PASS)' <<<"$OUT" | tr '\n' ' ')"; fi
reset_evd

for e in "E5 the evidence copy fails|$INTEL|x86_64|scp-fail|could not copy evidence.tar" \
         "E6 the copy differs from the Mac's sha256|$ARM|arm64|scp-corrupt|the copy ("; do
  IFS='|' read -r name h a flag reason <<<"$e"
  fresh_macs; : > "$T/ctl/$flag-$h"; run_gate
  rd=$(ls "$T/mac/$h" | grep -E "^$RD_RE$" | head -1)
  if [ "$RC" -ne 0 ] && grep -qF "EVIDENCE"$'\t'"$h"$'\t'"$a"$'\tFAILED\t'"$reason" <<<"$OUT" && [ -n "$rd" ] \
     && grep -q $'^RETAINED\t'"$h"$'\t'"$rd"$'\t.' <<<"$OUT" && ! grep -q $'^REMOVED\t'"$h" <<<"$OUT" \
     && ! grep -q $'^PASS\tms-runtime-rows-gate' <<<"$OUT"; then
    ok "$name: EVIDENCE FAILED, the run dir RETAINED and kept, exit non-zero"
  else bad "$name: rc=$RC rd=$rd $(grep -E '^(EVIDENCE|REMOVED|RETAINED)' <<<"$OUT" | tr '\n' ' ')"; fi
  reset_evd
done

fresh_macs; : > "$T/mac/$INTEL/ctl-leak"; run_gate   # E7
rd=$(ls "$T/mac/$INTEL" | grep -E "^$RD_RE$" | head -1)
if [ "$RC" -ne 0 ] && ev_ok "$INTEL" x86_64 && [ -n "$rd" ] && [ -e "$T/mac/$INTEL/$rd/LEAKED" ] \
   && grep -q $'^RETAINED\t'"$INTEL"$'\t'"$rd"$'\t.' <<<"$OUT" && ! grep -q $'^REMOVED\t'"$INTEL" <<<"$OUT"; then
  ok "E7 a leak stop: the evidence is still copied and verified; the run dir is RETAINED with its marker, never removed"
else bad "E7: rc=$RC rd=$rd $(grep -E '^(EVIDENCE|REMOVED|RETAINED|HOST_STOPPED)' <<<"$OUT" | tr '\n' ' ')"; fi
reset_evd

mkdir -p "$T/full" && echo x > "$T/full/old"; ln -s "$T/full" "$T/link"; mkdir -p "$T/emptydir"
for e in "unset|ZB_MAC_EVIDENCE_DIR=" "relative|ZB_MAC_EVIDENCE_DIR=evidence" "not empty|ZB_MAC_EVIDENCE_DIR=$T/full" \
         "a symlink|ZB_MAC_EVIDENCE_DIR=$T/link"; do   # E8
  fresh_macs; run_gate "${e#*|}"
  if [ "$RC" -eq 1 ] && [ "$(calls)" -eq 0 ] && grep -q '^NOT RUN' <<<"$OUT"; then ok "E8 ZB_MAC_EVIDENCE_DIR ${e%%|*}: NOT RUN, no ssh/scp call"
  else bad "E8 ZB_MAC_EVIDENCE_DIR ${e%%|*}: rc=$RC calls=$(calls) $(head -2 <<<"$OUT" | tr '\n' ' ')"; fi
done
reset_evd

fresh_macs; : > "$T/mac/$ARM/ctl-getconf-fail"; run_gate   # E9
rd=$(ls "$T/mac/$ARM" | grep -E "^$RD_RE$" | head -1)
if [ "$RC" -ne 0 ] && grep -q $'^EVIDENCE\t'"$ARM"$'\tarm64\tNONE\t.' <<<"$OUT" && [ -n "$rd" ] \
   && grep -q $'^RETAINED\t'"$ARM"$'\t'"$rd"$'\t.' <<<"$OUT" && ! grep -q $'^REMOVED\t'"$ARM" <<<"$OUT"; then
  ok "E9 a self-audit failure: no evidence archive armed, EVIDENCE NONE, the run dir RETAINED, exit non-zero"
else bad "E9: rc=$RC rd=$rd $(grep -E '^(EVIDENCE|REMOVED|RETAINED|SELFAUDIT_STATUS)' <<<"$OUT" | tr '\n' ' ')"; fi

if [ "$fails" -eq 0 ]; then printf 'PASS\tms-runtime-rows-evidence-selftest\n'; exit 0; fi
printf 'FAIL\tms-runtime-rows-evidence-selftest\t%s failure(s)\n' "$fails"
exit 1
