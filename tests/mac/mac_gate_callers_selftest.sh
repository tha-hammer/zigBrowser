#!/usr/bin/env bash
# Hostless driven selftest of every caller of tests/mac/build-on-mac.sh (plan R30-MS1, bd zigBrowser-4pa.59 +
# zigBrowser-4pa.77; orchestrator ruling: migrate all callers in the same green). The callers are the seven Mac gates
# tests/mac/{gate,ms1b_signed_gate,ms2a_gate,ms2b_gate,ms2c_gate,ms3_gate,ms4_gate}.sh and packaging/macos/build-dmg.sh.
# A caller that builds into the fresh zb-gate-<sha>-<nonce> run dir but then works in the old shared $HOME/zigBrowser
# tests a stale tree: a proof that cannot fail. For each caller, run end to end, this requires:
#   C1 exit 0 and the caller's final PASS/Done line (every remote step was reached);
#   C2 exactly one fresh run dir per target host, created by build-on-mac.sh;
#   C3 no ssh/scp argv or remote script names the old $HOME/zigBrowser (or ~/zigBrowser, host:zigBrowser/);
#   C4 every later ssh call to a host names that host's run dir;
#   C5 every scp remote path lies inside that host's run dir (nothing in the shared home);
#   C6 the last call to each host removes its run dir;
#   C7 every ssh/scp pins host keys (StrictHostKeyChecking=yes, BatchMode=yes, IdentitiesOnly=yes,
#      UserKnownHostsFile=<repo>/tests/mac/known_hosts), never StrictHostKeyChecking=no or /dev/null.
# No Mac, no network, no signal: the REAL callers (and the real build-on-mac.sh they call) run in a scratch git repo
# with HOME and TMPDIR inside this test's temporary tree, and a stub ssh, scp and python3 first on PATH that record
# their argv and stdin, succeed, and (scp) write a stub file where a remote file is fetched to.
# Run: bash tests/mac/mac_gate_callers_selftest.sh [repo root]   (step: zig build test-mac-build-script)
set -uo pipefail
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

# The scratch repo: the real callers, build-on-mac.sh, the pinned host keys and any shared gate library, plus
# stand-ins for every path build-on-mac.sh archives.
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

argv() { tr '\0' ' ' < "$T/ctl/call.$1"; }
call_host() { # the target host of call $1 (empty if none)
  case "$(argv "$1")" in *"$INTEL"*) echo "$INTEL" ;; *"$ARM"*) echo "$ARM" ;; esac
}

check_caller() { # check_caller <name> <script> <final line regex> <host...>
  local name=$1 script=$2 final=$3; shift 3
  local hosts=("$@") i h a n rd last
  rm -f "$T/ctl"/*
  local out rc
  out=$(cd "$R" && env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" TMPDIR="$T/tmp" \
          ZB_MAC_HOST="$INTEL" ZB_MAC_ARM_HOST="$ARM" ZB_MAC_KEY="$T/home/no_such_key" \
          timeout 120 bash "$script" 2>&1 </dev/null)
  rc=$?
  n=$(cat "$T/ctl/n" 2>/dev/null || echo 0)
  printf -- '--- %s: rc=%s calls=%s\n%s\n' "$name" "$rc" "$n" "$out" | tail -n 8 | sed 's/^/     /'
  local before=$fails

  # C1
  if [ "$rc" -eq 0 ] && grep -qE "$final" <<<"$out"; then ok "$name C1: exit 0 and its final line"
  else bad "$name C1: exit $rc, final line /$final/ $(grep -qE "$final" <<<"$out" && echo present || echo absent)"; fi

  # C2: one run dir per host, from build-on-mac.sh's extraction call (mkdir + tar on stdin)
  declare -A RD=()
  for h in "${hosts[@]}"; do
    local dirs=""
    for ((i = 0; i < n; i++)); do
      [ "$(call_host "$i")" = "$h" ] || continue
      a=$(argv "$i")
      case "$a" in *mkdir*zb-gate-*tar\ -xf*) dirs+="$(grep -oE 'zb-gate-[0-9a-f]{40}-[0-9a-f]+' <<<"$a" | head -1)"$'\n' ;; esac
    done
    if [ "$(grep -c . <<<"$dirs")" -eq 1 ]; then RD[$h]=$(grep . <<<"$dirs"); ok "$name C2: $h built in ${RD[$h]}"
    else bad "$name C2: $h has $(grep -c . <<<"$dirs") run dirs, want 1"; fi
  done

  for ((i = 0; i < n; i++)); do
    a=$(argv "$i"); h=$(call_host "$i")
    # C3: the old shared dir, in argv or in the remote script (a source tar on stdin is data, not a script)
    local script_in=""
    tar -tf "$T/ctl/stdin.$i" >/dev/null 2>&1 || script_in=$(cat "$T/ctl/stdin.$i")
    if printf '%s\n%s\n' "$a" "$script_in" | grep -qE '(\$HOME|~)/zigBrowser([^-[:alnum:]_.]|$)|:zigBrowser(/|$)'; then
      bad "$name C3: call $i names the old \$HOME/zigBrowser: $(cut -c1-160 <<<"$a")"
    fi
    [ -n "$h" ] && [ -n "${RD[$h]:-}" ] || continue
    rd=${RD[$h]}
    # C4: every ssh call to the host names its run dir
    case "$a" in ssh\ *) case "$a" in *"$rd"*) ;; *) bad "$name C4: ssh call $i to $h does not name $rd: $(cut -c1-160 <<<"$a")" ;; esac ;; esac
    # C5: every scp remote path is inside the run dir
    case "$a" in scp\ *)
      for tok in $a; do
        case "$tok" in "$h":*) case "${tok#"$h":}" in "$rd"/*|"$rd") ;; *) bad "$name C5: scp call $i uses $tok outside $rd" ;; esac ;; esac
      done ;;
    esac
    # C7: pinned host keys
    for want in StrictHostKeyChecking=yes BatchMode=yes IdentitiesOnly=yes "UserKnownHostsFile=$R/tests/mac/known_hosts"; do
      case "$a" in *"$want"*) ;; *) bad "$name C7: call $i lacks $want" ;; esac
    done
    case "$a" in *StrictHostKeyChecking=no*|*UserKnownHostsFile=/dev/null*) bad "$name C7: call $i turns host-key checking off" ;; esac
  done

  # C6: the last call to each host removes its run dir
  for h in "${hosts[@]}"; do
    [ -n "${RD[$h]:-}" ] || continue
    last=""
    for ((i = 0; i < n; i++)); do [ "$(call_host "$i")" = "$h" ] && last=$i; done
    a=$(argv "$last")
    case "$a" in *"${RD[$h]}"*-delete*) ok "$name C6: the last call to $h removes ${RD[$h]}" ;;
      *) bad "$name C6: the last call to $h does not remove ${RD[$h]}: $(cut -c1-160 <<<"$a")" ;; esac
  done
  [ "$fails" -eq "$before" ] && ok "$name: C3 C4 C5 C7 hold on all $n calls"
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
