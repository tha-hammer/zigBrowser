#!/usr/bin/env bash
# Hostless driven selftest of every caller of tests/mac/build-on-mac.sh (plan R30-MS1, bd zigBrowser-4pa.59 +
# zigBrowser-4pa.77; orchestrator ruling: migrate all callers in the same green; SilverRidge 3665306 + de1751c). The
# callers are the seven Mac gates tests/mac/{gate,ms1b_signed_gate,ms2a_gate,ms2b_gate,ms2c_gate,ms3_gate,ms4_gate}.sh
# and packaging/macos/build-dmg.sh. A caller that builds into the fresh run dir but works anywhere else (the old shared
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
# Run: bash tests/mac/mac_gate_callers_selftest.sh [repo root]   (step: zig build test-mac-build-script)
set -uo pipefail
if [ "${ZB_CALLERS_SELFTEST_INNER:-}" != 1 ]; then
  ZB_CALLERS_SELFTEST_INNER=1 exec unshare --user --map-current-user --net bash "$(realpath "$0")" "$@"
fi
ROOT=$(realpath "${1:-.}")
BASE=$(mktemp -d "${TMPDIR:-/tmp}/zb-callers-selftest-XXXXXX")
T=$(realpath "$BASE")
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
          ZB_MAC_HOST="$INTEL" ZB_MAC_ARM_HOST="$ARM" ZB_MAC_KEY="$T/home/no_such_key" \
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
check_caller build-dmg   packaging/macos/build-dmg.sh  '^==> Done: '                             "$INTEL"

if [ "$fails" -eq 0 ]; then printf 'PASS\tmac-gate-callers-selftest\n'; exit 0; fi
printf 'FAIL\tmac-gate-callers-selftest\t%s failure(s)\n' "$fails"
exit 1
