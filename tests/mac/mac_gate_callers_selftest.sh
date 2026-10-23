#!/usr/bin/env bash
# Hostless driven selftest of every caller of tests/mac/build-on-mac.sh (plan R30-MS1, bd zigBrowser-4pa.59 +
# zigBrowser-4pa.77; orchestrator ruling: migrate all callers in the same green; SilverRidge 3665306 + de1751c). The
# callers are the seven Mac gates tests/mac/{gate,ms1b_signed_gate,ms2a_gate,ms2b_gate,ms2c_gate,ms3_gate,ms4_gate}.sh,
# the runtime-fix rows gate tests/mac/ms_runtime_rows_gate.sh, and packaging/macos/build-dmg.sh. A caller that builds into the fresh run dir but works anywhere else (the old shared
# $HOME/zigBrowser, /tmp, the shared home) tests a stale tree: a proof that cannot fail. For each caller, run end to
# end, every recorded ssh/scp call is classified STRUCTURALLY against its host's exact run dir
# RD = zb-gate-<sha>-<nonce> (remote path "$HOME/RD"), and anything unrecognised fails:
#   C1 exit 0 and the caller's final PASS/Done line (every remote step was reached);
#   C2 every call targets one of the caller's own hosts (an unexpected or missing host fails, never skips);
#   C3 per host, exactly one extraction call  mkdir "$HOME/RD" && tar -xf - -C "$HOME/RD"  comes first, and exactly
#      one build call  cd "$HOME/RD" && <no ; | &>zig build ...  follows it;
#   C4 every other ssh call is caller work bound to RD: either `/bin/bash -s ARGS` whose script's only `cd` is
#      cd "$HOME/${N:?}" with positional N == RD, or an inline command; in both, every "$HOME/..." path is
#      "$HOME/RD[/...]" (or "$HOME/${N...}"/"$HOME/$N" with positional N == RD) and there is at least one;
#   C5 every scp remote path is RD or RD/... (nothing in the shared home or anywhere else);
#   C6 no call deletes anything except one final cleanup per host, which is exactly the shared library's
#      cd / && d="$HOME/RD"; [ -d "$d" ] && find "$d" -delete; true   as that host's LAST call (an early delete, e.g.
#      build-on-mac.sh removing RD before the caller's work, or a fake cleanup, fails);
#   C7 every call pins host keys (StrictHostKeyChecking=yes, BatchMode=yes, IdentitiesOnly=yes,
#      UserKnownHostsFile=<repo>/tests/mac/known_hosts), never StrictHostKeyChecking=no or /dev/null.
# No Mac, no signal: the REAL callers (and the real build-on-mac.sh and tests/mac/mac_gate_lib.sh they use) run in a
# scratch git repo, HOME/TMPDIR inside this test's temp tree, with stub ssh, scp and python3 first on PATH that record
# argv and stdin and succeed (scp leaves a stub file where a fetch lands). The test re-runs itself in a private
# user+network namespace, so no network is reachable.
# The rows gate's Mac leg is also run here (verdicts and environment, V1-V6; see that section).
# Run: bash tests/mac/mac_gate_callers_selftest.sh [repo root]   (step: zig build test-mac-build-script)
set -uo pipefail
if [ "${ZB_CALLERS_SELFTEST_INNER:-}" != 1 ]; then
  ZB_CALLERS_SELFTEST_INNER=1 exec unshare --user --map-current-user --net bash "$(realpath "$0")" "$@"
fi
ROOT=$(realpath "${1:-.}")
BASE=$(mktemp -d "${TMPDIR:-/tmp}/zb-callers-selftest-XXXXXX")
T=$(realpath "$BASE")
printf 'not a real key\n' > "$T/fake_mac_key"   # tests/mac/mac_config.sh needs a readable regular key file (bd 3ui.13)
cleanup() {
  case "$T" in "$(realpath "${TMPDIR:-/tmp}")"/zb-callers-selftest-??????) rm -rf "${T:?}" ;; esac
}
trap cleanup EXIT
fails=0
ok() { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }
INTEL=intel@10.0.0.1 ARM=arm@10.0.0.2

mkdir -p "$T/bin" "$T/ctl" "$T/home" "$T/tmp"
cat > "$T/bin/ssh" <<EOF
#!/bin/bash
i=\$(cat "$T/ctl/n" 2>/dev/null || echo 0); echo \$((i + 1)) > "$T/ctl/n"
printf '%s\0' ssh "\$@" > "$T/ctl/call.\$i"
cat > "$T/ctl/stdin.\$i"
# Answer like a passing Mac where gate.sh requires each remote test's PASS line (MS1.4).
if grep -q m9_render_test.py "$T/ctl/stdin.\$i"; then
  printf 'PASS\tm9-render-webview-screenshot\tzig-out/m9-render.png\tstub\nPASS\tm9-reply-channel-contract\n'
  printf 'PASS\tm9-load-fail-contract\nexec_arch_probe: build.exec_arch=stub\n'
elif grep -q mac_universal_test.py "$T/ctl/stdin.\$i"; then
  printf 'PASS\tmac-universal\t12 assertions\n'
fi
# the rows gate's leak path (rows L): the leg on STUB_LEG_RC_HOST exits STUB_LEG_RC
if [ -n "\${STUB_LEG_RC_HOST:-}" ] && [[ " \$* " == *" \$STUB_LEG_RC_HOST /bin/bash -s "* ]]; then exit "\${STUB_LEG_RC:-0}"; fi
exit 0
EOF
cat > "$T/bin/scp" <<EOF
#!/bin/bash
i=\$(cat "$T/ctl/n" 2>/dev/null || echo 0); echo \$((i + 1)) > "$T/ctl/n"
printf '%s\0' scp "\$@" > "$T/ctl/call.\$i"
: > "$T/ctl/stdin.\$i"
dst="\${@: -1}" src="\${@: -2:1}"
case "\$dst" in *:*) ;; *)   # a fetch: leave a stub file where the remote file lands
  if [ -d "\$dst" ]; then echo stub > "\$dst/\$(basename "\${src#*:}")"; else echo stub > "\$dst"; fi ;;
esac
exit 0
EOF
cat > "$T/bin/python3" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/ctl/python3"
exit 0
EOF
chmod +x "$T/bin/ssh" "$T/bin/scp" "$T/bin/python3"

# The scratch repo: the real callers, build-on-mac.sh, the shared gate library, the pinned host keys, plus stand-ins
# for every path build-on-mac.sh archives.
R="$T/repo"
mkdir -p "$R/tests/mac" "$R/tests/e2e" "$R/src" "$R/packaging/macos" "$R/packaging/assets"
for f in "$ROOT"/tests/mac/*.sh "$ROOT"/tests/mac/known_hosts; do
  [ -f "$f" ] && cp "$f" "$R/tests/mac/"
done
cp "$ROOT/packaging/macos/build-dmg.sh" "$R/packaging/macos/build-dmg.sh"
echo plist > "$R/packaging/macos/Info.plist"
echo png > "$R/packaging/assets/zigBrowser.png"
echo src > "$R/src/main.zig"
echo e2e > "$R/tests/e2e/placeholder.py"
echo build > "$R/build.zig"; echo zon > "$R/build.zig.zon"; echo '{}' > "$R/zigbrowser.json"
G=(env -i PATH=/usr/bin:/bin HOME="$T/home" GIT_CONFIG_NOSYSTEM=1 git -C "$R")
"${G[@]}" init -q && "${G[@]}" add -A \
  && "${G[@]}" -c user.name=selftest -c user.email=selftest@invalid commit -q -m staged \
  || { bad "could not build the scratch repo"; exit 1; }

GATE='zb-gate-[0-9a-f]{40}-[0-9a-f]+'
EXTRACT_RE="^mkdir \"\\\$HOME/($GATE)\" && tar -xf - -C \"\\\$HOME/($GATE)\"\$"
RM_RE='(^|[[:space:];&|])rm([[:space:]]|$)'   # an rm command word, not "nonuniform"
CD_RE='^[[:space:]]*cd "\$HOME/\$\{([0-9]):\?\}"[[:space:]]*$'   # cd "$HOME/${N:?}"

parse() { # parse <i>: TOOL, HOST, CMD (the remote command words after the host, ssh), REMOTES (scp host:path words)
  local -a a
  local j skip=
  mapfile -d '' a < "$T/ctl/call.$1"
  TOOL=${a[0]} HOST= CMD=() REMOTES=()
  for ((j = 1; j < ${#a[@]}; j++)); do
    if [ -n "$skip" ]; then skip=; continue; fi
    case "${a[j]}" in
      -i|-o|-F|-p|-P|-l|-c|-J) skip=1; continue ;;
      -*) continue ;;
    esac
    if [ "$TOOL" = ssh ]; then HOST=${a[j]}; CMD=("${a[@]:j+1}"); break; fi
    case "${a[j]}" in *:*) REMOTES+=("${a[j]}"); HOST=${a[j]%%:*} ;; esac
  done
}
home_paths_ok() { # home_paths_ok <text> <rd> [positionals...]: every "$HOME/..." is in RD; prints how many there are
  local text=$1 rd=$2; shift 2
  local -a pos=("$@")
  local tok rest n=0 k
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    rest=${tok#\$HOME/}
    if [ "$rest" = "$rd" ] || [[ "$rest" == "$rd"/* ]]; then n=$((n + 1)); continue; fi
    if [[ "$rest" =~ ^\$\{?([0-9])(:\?)?\}?(/.*)?$ ]]; then
      k=${BASH_REMATCH[1]}
      if [ "$k" -ge 1 ] && [ "${pos[k-1]:-}" = "$rd" ]; then n=$((n + 1)); continue; fi
    fi
    echo "bad:$tok"; return 1
  done < <(grep -oE '\$HOME/[^"'"'"' ;&|)]*' <<<"$text")
  echo "$n"
}

check_caller() { # check_caller <name> <script> <final line regex> <host...>
  local name=$1 script=$2 final=$3; shift 3
  local -a hosts=("$@")
  local i h n rc out c script_in rd res k last before=$fails
  declare -A RD=() XN=() BN=() DELS=() LASTDEL=() LASTCALL=()
  rm -f "$T/ctl"/*
  out=$(cd "$R" && env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" TMPDIR="$T/tmp" \
          ZB_MAC_HOST="$INTEL" ZB_MAC_ARM_HOST="$ARM" ZB_MAC_KEY="$T/fake_mac_key" \
          timeout 120 bash "$script" 2>&1 </dev/null)
  rc=$?
  n=$(cat "$T/ctl/n" 2>/dev/null || echo 0)
  printf -- '--- %s: rc=%s calls=%s\n%s\n' "$name" "$rc" "$n" "$out" | tail -n 6 | sed 's/^/     /'

  # C1
  if [ "$rc" -eq 0 ] && grep -qE "$final" <<<"$out"; then ok "$name C1: exit 0 and its final line"
  else bad "$name C1: exit $rc, final line /$final/ $(grep -qE "$final" <<<"$out" && echo present || echo absent)"; fi
  [ "$n" -gt 0 ] || bad "$name: no ssh/scp call at all"

  for ((i = 0; i < n; i++)); do
    parse "$i"
    h=$HOST
    # C2: one of this caller's hosts
    case " ${hosts[*]} " in *" $h "*) ;; *) bad "$name C2: call $i targets unexpected host \"$h\""; continue ;; esac
    LASTCALL[$h]=$i
    # C7: pinned host keys
    c=$(tr '\0' ' ' < "$T/ctl/call.$i")
    for want in StrictHostKeyChecking=yes BatchMode=yes IdentitiesOnly=yes "UserKnownHostsFile=$R/tests/mac/known_hosts"; do
      case "$c" in *"$want"*) ;; *) bad "$name C7: call $i lacks $want" ;; esac
    done
    case "$c" in *StrictHostKeyChecking=no*|*UserKnownHostsFile=/dev/null*) bad "$name C7: call $i turns host-key checking off" ;; esac
    rd=${RD[$h]:-}

    if [ "$TOOL" = scp ]; then   # C5
      [ -n "$rd" ] || { bad "$name C3: scp call $i to $h before its run dir exists"; continue; }
      for k in "${REMOTES[@]}"; do
        case "${k#*:}" in "$rd"|"$rd"/*) ;; *) bad "$name C5: scp call $i uses $k outside $rd" ;; esac
      done
      continue
    fi

    c="${CMD[*]}"
    # C3: the extraction call comes first and names one exact run dir; then exactly one build call
    if [[ "$c" =~ $EXTRACT_RE ]] && [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[2]}" ]; then
      if [ -n "$rd" ]; then bad "$name C3: a second extraction call ($i) on $h"; else RD[$h]=${BASH_REMATCH[1]}; fi
      XN[$h]=$(( ${XN[$h]:-0} + 1 )); continue
    fi
    [ -n "$rd" ] || { bad "$name C3: ssh call $i to $h before its run dir exists: $(cut -c1-120 <<<"$c")"; continue; }
    build_re='^cd "\$HOME/'"$rd"'" && [^;|&]*zig build( |$)'
    if [[ "$c" =~ $build_re ]]; then BN[$h]=$(( ${BN[$h]:-0} + 1 )); continue; fi
    # C6: deletes
    if [[ "$c" == *-delete* || "$c" =~ $RM_RE ]]; then
      DELS[$h]=$(( ${DELS[$h]:-0} + 1 )); LASTDEL[$h]=$i
      if [ "$c" != "cd / && d=\"\$HOME/$rd\"; [ -d \"\$d\" ] && find \"\$d\" -delete; true" ]; then
        bad "$name C6: call $i deletes but is not the exact final cleanup of $rd: $(cut -c1-140 <<<"$c")"
      fi
      continue
    fi
    # C4: caller work bound to RD
    if [ "${CMD[0]:-}" = /bin/bash ] && [ "${CMD[1]:-}" = -s ]; then
      script_in=$(cat "$T/ctl/stdin.$i")
      local -a pos=("${CMD[@]:2}")
      local cds goodcd=0 line
      cds=$(grep -E '^[[:space:]]*cd[[:space:]]' <<<"$script_in")
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        if [[ "$line" =~ $CD_RE ]] && [ "${pos[${BASH_REMATCH[1]}-1]:-}" = "$rd" ]; then
          goodcd=$((goodcd + 1))
        else
          bad "$name C4: script call $i on $h has cd outside $rd: $line"
        fi
      done <<<"$cds"
      [ "$goodcd" -eq 1 ] || bad "$name C4: script call $i on $h has $goodcd cd into $rd, want exactly 1"
      res=$(home_paths_ok "$script_in" "$rd" "${pos[@]}") || bad "$name C4: script call $i on $h uses ${res#bad:} outside $rd"
    else
      res=$(home_paths_ok "$c" "$rd") || { bad "$name C4: ssh call $i on $h uses ${res#bad:} outside $rd"; continue; }
      [ "$res" -ge 1 ] || bad "$name C4: ssh call $i on $h names no path in $rd: $(cut -c1-120 <<<"$c")"
      case "$c" in *cd\ *) [[ "$c" == "cd \"\$HOME/$rd\" && "* ]] || bad "$name C4: ssh call $i on $h has a cd outside $rd: $(cut -c1-120 <<<"$c")" ;; esac
    fi
  done

  for h in "${hosts[@]}"; do
    rd=${RD[$h]:-}
    if [ -z "$rd" ]; then bad "$name C3: $h has no extraction call"; continue; fi
    [ "${XN[$h]:-0}" -eq 1 ] && [ "${BN[$h]:-0}" -eq 1 ] && ok "$name C3: $h extracted into and built in \$HOME/$rd" \
      || bad "$name C3: $h has ${XN[$h]:-0} extraction and ${BN[$h]:-0} build calls, want 1 and 1"
    if [ "${DELS[$h]:-0}" -eq 1 ] && [ "${LASTDEL[$h]}" = "${LASTCALL[$h]}" ]; then ok "$name C6: one cleanup of $rd, the last call to $h"
    else bad "$name C6: $h has ${DELS[$h]:-0} deleting calls (want exactly 1, as its last call)"; fi
  done
  [ "$fails" -eq "$before" ] && ok "$name: C2 C4 C5 C7 hold on all $n calls"
}

check_caller gate        tests/mac/gate.sh             $'^PASS\tmac-universal-gate\tboth-arches$' "$INTEL" "$ARM"
check_caller ms1b        tests/mac/ms1b_signed_gate.sh $'^PASS\tms1b-signed-gate\tboth-arches$'   "$INTEL" "$ARM"
check_caller ms2a        tests/mac/ms2a_gate.sh        $'^PASS\tms2a-gate\tboth-arches$'          "$INTEL" "$ARM"
check_caller ms2b        tests/mac/ms2b_gate.sh        $'^PASS\tms2b-gate\tboth-arches$'          "$INTEL" "$ARM"
check_caller ms2c        tests/mac/ms2c_gate.sh        $'^PASS\tms2c-gate\tboth-arches$'          "$INTEL" "$ARM"
check_caller ms3         tests/mac/ms3_gate.sh         $'^PASS\tms3-gate\tboth-arches$'           "$INTEL" "$ARM"
check_caller ms4         tests/mac/ms4_gate.sh         $'^PASS\tms4-gate\tboth-arches$'           "$INTEL" "$ARM"
check_caller rows        tests/mac/ms_runtime_rows_gate.sh $'^PASS\tms-runtime-rows-gate\tboth-arches$' "$INTEL" "$ARM"
check_caller build-dmg   packaging/macos/build-dmg.sh  '^==> Done: '                             "$INTEL" "$ARM"

# The rows gate's Mac leg (tests/mac/ms_runtime_rows_gate.sh, SilverRidge fe4542e): the structural checks above
# never run the leg script, so run it here, extracted from the real caller, in a fake run root with a stub python3.
#   V1 a red printing exactly its own RED_SHAPE<TAB><id> (tests/e2e/red_shape.py) matches; each of these is a
#   MISMATCH (SilverRidge cf7a783): V2 a red of the wrong shape (RED_SHAPE_MISMATCH), V2a row 3 with ZERO matching
#   LOAD_FAIL rows (as the real red prints it), V2b an extra unexpected assertion failure next to a RED_SHAPE line,
#   V2c another test's RED_SHAPE, V2d no RED_SHAPE at all, V3 a red with a PRECONDITION, V4 a "red" that passes, V5 a
#   green whose PASS line names another test; every row runs and the leg exits 1 on any mismatch, 0 when all match;
#   V6 the leg exports HOME, CFFIXED_USER_HOME, TMPDIR, the XDG dirs and ZB_E2E_SOCKET_DIR beneath the run root and
#   ZB_DEBUG_EPHEMERAL_DATA_STORE=1, and writes nothing in the original HOME outside the run root.
# The leg sources the real tests/mac/mac_varfolders_audit.sh, copied into each fake run root, against a getconf stub
# whose per-user roots are directories under $T/vf (rows VF below).
rows_leg() { # rows_leg <out var> <rows...>: run the extracted leg in $T/rows-home/$RRD; sets LEG_RC
  local -n _o=$1; shift
  _o=$(cd / && env -i PATH="$T/rows-bin:/usr/bin:/bin" HOME="$T/rows-home" bash "$T/rows-leg.sh" "$RRD" "$@" 2>&1)
  LEG_RC=$?
}
rows_root() { # rows_root <run dir name>: a fake run root holding the exact helper the leg sources
  mkdir -p "$T/rows-home/$1/tests/mac" && cp "$R/tests/mac/mac_varfolders_audit.sh" "$T/rows-home/$1/tests/mac/"
}
RRD=zb-gate-0000000000000000000000000000000000000000-1
mkdir -p "$T/rows-bin" "$T/vf/T" "$T/vf/C"
rows_root "$RRD"
: > "$T/vf/C/keep"   # a file that was there before every leg: no leg may delete it
cat > "$T/rows-bin/getconf" <<EOF
#!/bin/bash
[ -e "$T/vf/fail" ] && exit 1   # VF2: the per-user roots cannot be resolved
[ -e "$T/vf/empty" ] && exit 0  # VF4: getconf answers nothing
case "\$1" in DARWIN_USER_TEMP_DIR) echo "$T/vf/T/" ;; DARWIN_USER_CACHE_DIR) echo "$T/vf/C/" ;; *) exit 1 ;; esac
EOF
chmod +x "$T/rows-bin/getconf"
awk "/<<'REMOTE'/{f=1;next} /^REMOTE\$/{f=0} f" "$R/tests/mac/ms_runtime_rows_gate.sh" > "$T/rows-leg.sh"
cat > "$T/rows-bin/python3" <<'EOF'
#!/bin/bash
case "$1" in
  *v_red_ok*)    printf 'ASSERT\tv-red\ta\tfail\nFAIL\tv-red\nRED_SHAPE\tv-red\n'; exit 1 ;;
  *v_red_shape*) printf 'ASSERT\tv-red\ta\tpass\nFAIL\tv-red\nRED_SHAPE_MISMATCH\tv-red\ta passed, the accepted red vector says fail\n'; exit 1 ;;
  *v_red_row3*)  printf 'ASSERT\tv-red\trow3-undisplayable-response.load-fail-once\tfail\nASSERT\tv-red\trow3-undisplayable-response.alive\tfail\nFAIL\tv-red\n'
                 printf 'RED_SHAPE_MISMATCH\tv-red\trow3-undisplayable-response.load-fail-once failed, the accepted red vector says pass\n'; exit 1 ;;
  *v_red_extra*) printf 'ASSERT\tv-red\ta\tfail\nASSERT\tv-red\tz\tfail\nFAIL\tv-red\nRED_SHAPE\tv-red\nRED_SHAPE_MISMATCH\tv-red\tunexpected assertion z\n'; exit 1 ;;
  *v_red_other*) printf 'FAIL\tv-red\nRED_SHAPE\tv-other\n'; exit 1 ;;
  *v_red_none*)  printf 'FAIL\tv-red\n'; exit 1 ;;
  *v_red_pre*)   printf 'FAIL\tv-red\nRED_SHAPE\tv-red\n  PRECONDITION seam never fired\n'; exit 1 ;;
  *v_red_pass*)  printf 'PASS\tv-red\nRED_SHAPE\tv-red\n'; exit 0 ;;
  *v_leak*)      printf 'FAIL\tv-red\nLEAK\t4242\t4242\tThu Oct 22 21:00:00 2026\t/x/zigBrowser --e2e-protocol\n'; exit 1 ;;
  *v_hang*)      exec sleep 30 ;;   # a row that never returns (V9: the leg times out)
  *v_green*)     printf 'PASS\tv-other\n'; exit 0 ;;
  *v_vf*)        : > "$(getconf DARWIN_USER_TEMP_DIR)zb-row-wrote"; printf 'PASS\tv-vf\n'; exit 0 ;;   # WebKit-like temp
  *v_env*)       printf 'ENV\t%s\n' "$HOME" "$CFFIXED_USER_HOME" "$TMPDIR" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" \
                   "$XDG_CONFIG_HOME" "$XDG_RUNTIME_DIR" "$ZB_E2E_SOCKET_DIR"
                 printf 'EPH\t%s\n' "${ZB_DEBUG_EPHEMERAL_DATA_STORE:-}"
                 # probe files only inside the leg's run root (its cwd): a bad HOME/TMPDIR must fail V6 by its
                 # path, never make this stub write in the real /tmp or home
                 for d in "$HOME" "$TMPDIR"; do case "$d" in "$PWD"/*) : > "${d%/}/probe" ;; esac; done
                 printf 'PASS\tx\n'; exit 0 ;;
esac
exit 2
EOF
chmod +x "$T/rows-bin/python3"
mv "$T/rows-bin/python3" "$T/rows-bin/python3.rows"   # every row invocation (each would launch a browser) is logged
cat > "$T/rows-bin/python3" <<EOF
#!/bin/bash
printf '%s\n' "\$1" >> "$T/rows-calls"
exec "$T/rows-bin/python3.rows" "\$@"
EOF
chmod +x "$T/rows-bin/python3"
rows_verdict() { # rows_verdict <leg output> <file stem>: the ROW verdict word for that file
  awk -F'\t' -v f="tests/e2e/mac_$2_test.py" '$1 == "ROW" && $2 == f { print $5 }' <<<"$1"
}
rows_leg out "tests/e2e/mac_v_red_ok_test.py|red|v-red"
[ "$(rows_verdict "$out" v_red_ok)" = MATCH ] && [ "$LEG_RC" -eq 0 ] && ok "rows V1: a red printing its own RED_SHAPE matches, leg exit 0" \
  || bad "rows V1: $(rows_verdict "$out" v_red_ok) rc=$LEG_RC"
for v in v_red_shape v_red_row3 v_red_extra v_red_other v_red_none v_red_pre v_red_pass; do
  rows_leg out "tests/e2e/mac_${v}_test.py|red|v-red"
  [ "$(rows_verdict "$out" "$v")" = MISMATCH ] && [ "$LEG_RC" -eq 1 ] && ok "rows: $v is a MISMATCH, leg exit 1" \
    || bad "rows: $v gave $(rows_verdict "$out" "$v") rc=$LEG_RC"
done
rows_leg out "tests/e2e/mac_v_green_test.py|green|v-green"
[ "$(rows_verdict "$out" v_green)" = MISMATCH ] && [ "$LEG_RC" -eq 1 ] && ok "rows V5: a green whose PASS names another test is a MISMATCH" \
  || bad "rows V5: $(rows_verdict "$out" v_green) rc=$LEG_RC"
rows_leg out "tests/e2e/mac_v_red_ok_test.py|red|v-red" "tests/e2e/mac_v_red_shape_test.py|red|v-red" "tests/e2e/mac_v_green_test.py|green|v-other"
n=$(grep -c $'^ROW\t' <<<"$out")
[ "$n" -eq 3 ] && [ "$LEG_RC" -eq 1 ] && ok "rows: all 3 rows ran around a mismatch, leg exit 1" || bad "rows: $n ROW lines, rc=$LEG_RC"
before=$(cd "$T/rows-home" && find . -mindepth 1 -maxdepth 1 | sort)
rows_leg out "tests/e2e/mac_v_env_test.py|green|x"
root="$T/rows-home/$RRD"
envbad=0
out=$(sed -n 's|^    tests/e2e/mac_v_env_test.py: ||p' <<<"$out")   # the leg prefixes each output line with its file
while IFS=$'\t' read -r tag val; do
  case "$tag" in
    ENV) case "$val" in "$root"/run-env/*|"$root"/s) ;; *) envbad=1; bad "rows V6: $val is outside the run root" ;; esac ;;
  esac
done <<<"$out"
[ "$(grep -c $'^ENV\t' <<<"$out")" -eq 8 ] || { envbad=1; bad "rows V6: want 8 ENV lines"; }
grep -qx $'EPH\t1' <<<"$out" || { envbad=1; bad "rows V6: ZB_DEBUG_EPHEMERAL_DATA_STORE is not 1"; }
[ -f "$root/run-env/home/probe" ] && [ -f "$root/run-env/tmp/probe" ] || { envbad=1; bad "rows V6: the probe files are not in the run root"; }
after=$(cd "$T/rows-home" && find . -mindepth 1 -maxdepth 1 | sort)
[ "$before" = "$after" ] || { envbad=1; bad "rows V6: the leg wrote outside the run root: $(comm -13 <(echo "$before") <(echo "$after") | tr '\n' ' ')"; }
[ "$envbad" -eq 0 ] && [ "$LEG_RC" -eq 0 ] && ok "rows V6: private HOME/TMPDIR/XDG beneath the run root, ephemeral store on, nothing written outside it"

# A LEAK stops the host (SilverRidge cf16730). V7: after a row prints a LEAK line the leg runs no further row, prints
# HOST_STOPPED, writes the exact identity to <run root>/LEAKED, keeps the root and exits 3. V8: a later leg on that host
# (any ~/zb-gate-*/LEAKED) runs nothing and exits 4.
rows_leg out "tests/e2e/mac_v_leak_test.py|red|v-red" "tests/e2e/mac_v_red_ok_test.py|red|v-red"
if [ "$LEG_RC" -eq 3 ] && [ "$(grep -c $'^ROW\t' <<<"$out")" -eq 1 ] && grep -q $'^HOST_STOPPED\ttests/e2e/mac_v_leak_test.py\t' <<<"$out" \
   && grep -qx $'LEAKED\t4242\t4242\tThu Oct 22 21:00:00 2026\t/x/zigBrowser --e2e-protocol' "$T/rows-home/$RRD/LEAKED" 2>/dev/null; then
  ok "rows V7: a LEAK stops the leg after that row (exit 3), names the exact process, keeps it in <root>/LEAKED"
else
  bad "rows V7: rc=$LEG_RC ROW lines $(grep -c $'^ROW\t' <<<"$out"): $(tail -4 <<<"$out")"
fi
RRD_FIRST=$RRD RRD=zb-gate-0000000000000000000000000000000000000000-2
rows_root "$RRD"
rows_leg out "tests/e2e/mac_v_red_ok_test.py|red|v-red"
if [ "$LEG_RC" -eq 4 ] && [ "$(grep -c $'^ROW\t' <<<"$out")" -eq 0 ] && grep -q $'^HOST_HELD\t../'"$RRD_FIRST"'/LEAKED' <<<"$out"; then
  ok "rows V8: a later leg on a host with a leaked run root runs nothing (exit 4, HOST_HELD)"
else
  bad "rows V8: rc=$LEG_RC: $(tail -3 <<<"$out")"
fi
RRD=$RRD_FIRST

# V9 (SilverRidge c78a1f6): the marker is durable. A first leg whose row hangs is killed by `timeout` (exit 124) in a
# nested private PID namespace (it signals its own children only); it must leave <root>/LEAKED as RUNNING, and a
# second leg on that host must then run zero rows (HOST_HELD naming that root). V7's marker is removed first, so only
# the timed-out leg can hold the second one.
rm -f -- "${T:?}/rows-home/${RRD_FIRST:?}/LEAKED"
RRD_T1=zb-gate-0000000000000000000000000000000000000000-3 RRD_T2=zb-gate-0000000000000000000000000000000000000000-4
rows_root "$RRD_T1" && rows_root "$RRD_T2"
t1=$(cd / && env -i PATH="$T/rows-bin:/usr/bin:/bin" HOME="$T/rows-home" \
       unshare --user --map-root-user --pid --fork --mount-proc bash -c \
       'timeout 3 bash "$1" "$2" "tests/e2e/mac_v_hang_test.py|red|v-red"; echo "LEG1_RC=$?"' _ "$T/rows-leg.sh" "$RRD_T1" 2>&1)
RRD_SAVED=$RRD RRD=$RRD_T2
rows_leg out "tests/e2e/mac_v_red_ok_test.py|red|v-red"
RRD=$RRD_SAVED
if grep -qx 'LEG1_RC=124' <<<"$t1" && head -n 1 "$T/rows-home/$RRD_T1/LEAKED" 2>/dev/null | grep -q $'^RUNNING\t' \
   && [ "$LEG_RC" -eq 4 ] && [ "$(grep -c $'^ROW\t' <<<"$out")" -eq 0 ] && grep -q $'^HOST_HELD\t../'"$RRD_T1"'/LEAKED' <<<"$out"; then
  ok "rows V9: a timed-out leg (124) leaves RUNNING in its root; the next leg on that host runs zero rows (HOST_HELD)"
else
  bad "rows V9: first leg $(grep LEG1_RC <<<"$t1"), marker $(head -c 60 "$T/rows-home/$RRD_T1/LEAKED" 2>/dev/null || echo none), second leg rc=$LEG_RC ROW lines $(grep -c $'^ROW\t' <<<"$out")"
fi
for d in "$RRD_T1" "$RRD_T2" "$RRD_FIRST"; do   # a clean leg removes its own marker
  [ -e "$T/rows-home/$d/LEAKED" ] && rm -f -- "${T:?}/rows-home/${d:?}/LEAKED"
done
rows_leg out "tests/e2e/mac_v_red_ok_test.py|red|v-red"
[ "$LEG_RC" -eq 0 ] && [ ! -e "$T/rows-home/$RRD/LEAKED" ] && ok "rows V10: a leg that finishes cleanly removes its RUNNING marker" \
  || bad "rows V10: rc=$LEG_RC, marker $( [ -e "$T/rows-home/$RRD/LEAKED" ] && echo left || echo gone)"

# VF (the owner's /var/folders rule, SilverRidge 94ebe76b): VF1 the leg prints the physical roots, the path a row wrote
# there and the temp root's own changed record (unfiltered) and COMPLETE, exits 0 and deletes nothing there; VF3 a leak
# stop still reports the audit, and exits 3. Fail closed (SilverRidge 3661c9b8): VF2 a failing getconf, VF4 an empty
# getconf answer and VF5 an unreadable initial tree each make varfolders_begin refuse, and the leg exits 5 at once: its
# refusal line, zero ROW lines, zero row (browser) invocations and no RUNNING marker.
rows_leg out "tests/e2e/mac_v_vf_test.py|green|v-vf"
if [ "$LEG_RC" -eq 0 ] && [ "$(rows_verdict "$out" v_vf)" = MATCH ] \
   && [ "$(grep -c $'^VARFOLDERS_ROOTS\t' <<<"$out")" -eq 1 ] && grep -qx $'VARFOLDERS_ROOTS\tT\t'"$T/vf/T"$'\tC\t'"$T/vf/C" <<<"$out" \
   && [ "$(grep $'^VARFOLDERS-DELTA\t' <<<"$out" | cut -f2-4)" = $'changed\tT\t.\nadded\tT\tzb-row-wrote' ] \
   && grep -qx $'VARFOLDERS\tCOMPLETE\t2' <<<"$out" && [ -e "$T/vf/C/keep" ] && [ -e "$T/vf/T/zb-row-wrote" ]; then
  ok "rows VF1: the leg reports the roots and the row's /var/folders write (the temp root and its new file), exit 0, nothing deleted there"
else
  bad "rows VF1: rc=$LEG_RC: $(grep -E $'^(VARFOLDERS|ROW)' <<<"$out" | tr '\n' ' ')"
fi
: > "$T/rows-calls"; : > "$T/vf/fail"
rows_leg out "tests/e2e/mac_v_red_ok_test.py|red|v-red"
rm -f -- "${T:?}/vf/fail"
refused_leg() { # refused_leg <row name> <why>: the leg after a refused begin
  if [ "$LEG_RC" -eq 5 ] && grep -q $'^VARFOLDERS\tINCONCLUSIVE\tbegin refused' <<<"$out" \
     && [ "$(grep -c $'^ROW\t' <<<"$out")" -eq 0 ] && [ ! -s "$T/rows-calls" ] && [ ! -e "$T/rows-home/$RRD/LEAKED" ] \
     && ! grep -q $'^VARFOLDERS\tCOMPLETE' <<<"$out"; then
    ok "rows $1: $2: begin refuses, the leg exits 5 with zero rows, zero browser launches and no RUNNING marker"
  else
    bad "rows $1: rc=$LEG_RC rows=$(grep -c $'^ROW\t' <<<"$out") calls=$(wc -l < "$T/rows-calls" 2>/dev/null) marker=$([ -e "$T/rows-home/$RRD/LEAKED" ] && echo yes || echo no): $(grep -E '^VARFOLDERS' <<<"$out" | tr '\n' ' ')"
  fi
  rm -f -- "${T:?}/rows-home/${RRD:?}/LEAKED"
}
refused_leg VF2 "a failing getconf"
: > "$T/rows-calls"; : > "$T/vf/empty"
rows_leg out "tests/e2e/mac_v_red_ok_test.py|red|v-red"
rm -f -- "${T:?}/vf/empty"
refused_leg VF4 "an empty getconf answer"
: > "$T/rows-calls"; mkdir -p "$T/vf/C/locked" && : > "$T/vf/C/locked/x" && chmod 0 "$T/vf/C/locked"
rows_leg out "tests/e2e/mac_v_red_ok_test.py|red|v-red"
chmod 700 "$T/vf/C/locked" && rm -f -- "$T/vf/C/locked/x" && rmdir -- "$T/vf/C/locked"
refused_leg VF5 "an unreadable initial tree"
rows_leg out "tests/e2e/mac_v_leak_test.py|red|v-red"
if [ "$LEG_RC" -eq 3 ] && grep -q $'^HOST_STOPPED\t' <<<"$out" && grep -q $'^VARFOLDERS\tCOMPLETE\t' <<<"$out"; then
  ok "rows VF3: a leak stop still prints the /var/folders audit, and the leg exits 3"
else
  bad "rows VF3: rc=$LEG_RC: $(grep -E $'^(VARFOLDERS|HOST_STOPPED)' <<<"$out" | tr '\n' ' ')"
fi
rm -f -- "${T:?}/rows-home/${RRD:?}/LEAKED"

# L: this side of the leak path, the real rows caller with stub ssh. A leaked leg (exit 3) or a timed-out leg (124) on
# intel keeps intel's run dir (no delete call to intel) while arm is still cleaned; a held leg (exit 4) or an
# INCONCLUSIVE /var/folders audit (exit 5) keeps nothing.
for case in "3 0 STOPPED" "124 0 STOPPED" "4 1 HELD" "5 1 INCONCLUSIVE"; do
  read -r leg_rc want_del word <<<"$case"
  rm -f "$T/ctl"/*
  out=$(cd "$R" && env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" TMPDIR="$T/tmp" ZB_MAC_HOST="$INTEL" \
          ZB_MAC_ARM_HOST="$ARM" ZB_MAC_KEY="$T/fake_mac_key" STUB_LEG_RC_HOST="$INTEL" STUB_LEG_RC="$leg_rc" \
          timeout 120 bash tests/mac/ms_runtime_rows_gate.sh 2>&1 </dev/null)
  rc=$?
  n=$(cat "$T/ctl/n" 2>/dev/null || echo 0)
  di=0 da=0
  for ((i = 0; i < n; i++)); do
    parse "$i"
    [ "$TOOL" = ssh ] && [[ "${CMD[*]}" == *-delete* ]] || continue
    [ "$HOST" = "$INTEL" ] && di=$((di + 1))
    [ "$HOST" = "$ARM" ] && da=$((da + 1))
  done
  if [ "$rc" -eq 1 ] && [ "$di" -eq "$want_del" ] && [ "$da" -eq 1 ] && grep -q "^$word: $INTEL" <<<"$out"; then
    ok "rows L: intel leg exit $leg_rc -> $word, $di delete call(s) to intel, arm cleaned, gate exit 1"
  else
    bad "rows L: intel leg exit $leg_rc: rc=$rc intel deletes $di (want $want_del), arm deletes $da: $(grep -E '^(STOPPED|HELD|FAIL)' <<<"$out" | head -2)"
  fi
done

# The red vectors themselves (tests/e2e/mac_red_shape_selftest.py, hostless): each red test's exact vector gives
# RED_SHAPE, and a flipped, missing, extra, duplicated or precondition-broken outcome, or the real row-3 check driven
# with zero or two matching LOAD_FAIL rows, gives none.
# Its M section runs each row's real main against a fake browser and the row's own local HTTP fixture, so it needs a
# loopback interface: a nested private network namespace with only lo up (still no outside network).
if shape=$(cd "$ROOT/tests/e2e" && env -i PATH=/usr/bin:/bin HOME="$T/home" \
    unshare --user --map-root-user --net bash -c 'ip link set lo up && python3 -B mac_red_shape_selftest.py' 2>&1) \
  && grep -q $'^PASS\tmac-red-shape-selftest\t' <<<"$shape"; then
  ok "rows: $(grep $'^PASS\t' <<<"$shape" | tr '\t' ' ')"
else
  bad "rows: the red-shape selftest failed: $shape"
fi

# The SIGTERM-only teardown itself (tests/e2e/mac_term_teardown_selftest.py, bd zigBrowser-3ui.7): it signals real
# children, so it runs in a nested private PID namespace under a reaping shell, and refuses to run anywhere else.
if td=$(cd "$ROOT/tests/e2e" && env -i PATH=/usr/bin:/bin HOME="$T/home" \
    unshare --user --map-root-user --pid --fork --mount-proc bash -c 'python3 -B mac_term_teardown_selftest.py; exit $?' 2>&1) \
  && grep -q $'^PASS\tmac-term-teardown-selftest\t' <<<"$td"; then
  ok "teardown: $(grep $'^PASS\t' <<<"$td" | tr '\t' ' ')"
else
  bad "teardown: the SIGTERM-only teardown selftest failed: $td"
fi
# No ms2a/ms2b/ms2c gate test may send SIGKILL on a Mac (session brief; 3ui.7): the shared stop_browser_macos
# delegates to the SIGTERM-only teardown, and no gate test names SIGKILL or a subprocess timeout (which SIGKILLs).
grep -q '^    stop_browser_term_only(proc)$' "$ROOT/tests/e2e/mac_ms2a_routed_test.py" \
  && ok "teardown: stop_browser_macos delegates to the SIGTERM-only teardown" \
  || bad "teardown: stop_browser_macos does not delegate to stop_browser_term_only"
sk=0 nk=0
for g in ms2a ms2b ms2c; do
  for f in $(grep -oE 'tests/e2e/[a-z0-9_]+\.py' "$R/tests/mac/${g}_gate.sh" | sort -u); do
    nk=$((nk + 1))
    if grep -qE 'signal\.SIGKILL|\.kill\(\)|subprocess\.(run|call|check_call|check_output)\(.*timeout=' "$ROOT/$f"; then
      bad "teardown: $f ($g gate) can send SIGKILL"; sk=1
    fi
  done
done
[ "$sk" -eq 0 ] && [ "$nk" -gt 40 ] && ok "teardown: none of the $nk ms2a/ms2b/ms2c gate tests names SIGKILL, .kill() or a subprocess timeout" \
  || { [ "$sk" -eq 1 ] || bad "teardown: only $nk ms2a/ms2b/ms2c gate tests found"; }

# No row may send SIGKILL on a Mac (session brief): every row file stops its browser through mac_term_teardown
# (SIGTERM only). Tripwire only; the teardown's behavior is the selftest above.
for f in $(awk -F'|' '/^  "tests\/e2e\/mac_[a-z0-9_]+_test\.py[|]/ { sub(/^  "/, "", $1); print $1 }' "$R/tests/mac/ms_runtime_rows_gate.sh"); do
  if grep -q 'from mac_term_teardown import' "$ROOT/$f" && ! grep -qE 'stop_browser_macos|signal\.SIGKILL|\.kill\(\)' "$ROOT/$f"; then
    ok "rows: $f stops its browser with SIGTERM only"
  else
    bad "rows: $f does not use the SIGTERM-only teardown (or names SIGKILL)"
  fi
done
grep -q 'signal\.SIGKILL' "$ROOT/tests/e2e/mac_term_teardown.py" && bad "rows: mac_term_teardown.py names SIGKILL"

if [ "$fails" -eq 0 ]; then printf 'PASS\tmac-gate-callers-selftest\n'; exit 0; fi
printf 'FAIL\tmac-gate-callers-selftest\t%s failure(s)\n' "$fails"
exit 1
