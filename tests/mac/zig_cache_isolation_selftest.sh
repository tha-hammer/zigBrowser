#!/usr/bin/env bash
# Hostless selftest: every remote zig invocation of the Mac build path keeps BOTH zig caches inside its run dir
# (bd zigBrowser-3ui.5; the brief: write only under a fresh per-run dir). The first released build-only run at
# cbf5865 showed `zig build` with no cache flags, so zig used the owner's ~/.cache/zig on both Macs.
# It runs tests/mac/build-on-mac.sh alone and then each of its eight callers (tests/mac/{gate,ms1b_signed_gate,
# ms2a_gate,ms2b_gate,ms2c_gate,ms3_gate,ms4_gate}.sh, packaging/macos/build-dmg.sh, through tests/mac/mac_gate_lib.sh)
# against a stub ssh/scp that records every remote command and script. For every ssh call whose remote command or
# script invokes zig, it requires:
#   Z1 the command runs in the host's run dir: it starts  cd "$HOME/RD" &&  (RD = the dir the extraction call made);
#   Z2 it passes  --cache-dir "$HOME/RD/<sub>"  and  --global-cache-dir "$HOME/RD/<sub>", and every cache-dir flag it
#      passes is inside "$HOME/RD/";
#   Z3 each host built by the run has at least one such zig invocation (so the check cannot pass vacuously).
# No Mac, no signal: the REAL scripts run in a scratch git repo, HOME/TMPDIR in this test's temp tree; it re-runs
# itself in a private user+network namespace.
# Run: bash tests/mac/zig_cache_isolation_selftest.sh [repo root]   (step: zig build test-mac-build-script)
set -uo pipefail
if [ "${ZB_ZIGCACHE_SELFTEST_INNER:-}" != 1 ]; then
  ZB_ZIGCACHE_SELFTEST_INNER=1 exec unshare --user --map-current-user --net bash "$(realpath "$0")" "$@"
fi
ROOT=$(realpath "${1:-.}")
BASE=$(mktemp -d "${TMPDIR:-/tmp}/zb-zigcache-selftest-XXXXXX")
T=$(realpath "$BASE")
cleanup() {
  case "$T" in "$(realpath "${TMPDIR:-/tmp}")"/zb-zigcache-selftest-??????) rm -rf "${T:?}" ;; esac
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
if grep -q m9_render_test.py "$T/ctl/stdin.\$i"; then   # answer like a passing Mac where a gate needs PASS lines
  printf 'PASS\tm9-render-webview-screenshot\tzig-out/m9-render.png\tstub\nPASS\tm9-reply-channel-contract\n'
  printf 'PASS\tm9-load-fail-contract\nexec_arch_probe: build.exec_arch=stub\n'
elif grep -q mac_universal_test.py "$T/ctl/stdin.\$i"; then
  printf 'PASS\tmac-universal\t12 assertions\n'
fi
exit 0
EOF
cat > "$T/bin/scp" <<EOF
#!/bin/bash
i=\$(cat "$T/ctl/n" 2>/dev/null || echo 0); echo \$((i + 1)) > "$T/ctl/n"
printf '%s\0' scp "\$@" > "$T/ctl/call.\$i"
: > "$T/ctl/stdin.\$i"
dst="\${@: -1}" src="\${@: -2:1}"
case "\$dst" in *:*) ;; *)
  if [ -d "\$dst" ]; then echo stub > "\$dst/\$(basename "\${src#*:}")"; else echo stub > "\$dst"; fi ;;
esac
exit 0
EOF
chmod +x "$T/bin/ssh" "$T/bin/scp"

R="$T/repo"
mkdir -p "$R/tests/mac" "$R/tests/e2e" "$R/src" "$R/packaging/macos" "$R/packaging/assets"
for f in "$ROOT"/tests/mac/*.sh "$ROOT"/tests/mac/known_hosts; do [ -f "$f" ] && cp "$f" "$R/tests/mac/"; done
cp "$ROOT/packaging/macos/build-dmg.sh" "$R/packaging/macos/"
cp "$ROOT/tests/e2e/mac_resource_compat.py" "$ROOT/tests/e2e/mac_universal_test.py" "$R/tests/e2e/"
cp "$ROOT/packaging/macos/universal_components.json" "$ROOT/packaging/macos/entitlements.plist" "$R/packaging/macos/"
echo plist > "$R/packaging/macos/Info.plist"; echo png > "$R/packaging/assets/zigBrowser.png"
echo src > "$R/src/main.zig"; echo build > "$R/build.zig"; echo zon > "$R/build.zig.zon"; echo '{}' > "$R/zigbrowser.json"
G=(env -i PATH=/usr/bin:/bin HOME="$T/home" GIT_CONFIG_NOSYSTEM=1 git -C "$R")
"${G[@]}" init -q && "${G[@]}" add -A \
  && "${G[@]}" -c user.name=selftest -c user.email=selftest@invalid commit -q -m staged \
  || { bad "could not build the scratch repo"; exit 1; }

GATE='zb-gate-[0-9a-f]{40}-[0-9a-f]+'
EXTRACT_RE="^mkdir \"\\\$HOME/($GATE)\" && tar -xf - -C \"\\\$HOME/($GATE)\"\$"
ZIG_RE='(^|[^[:alnum:]_.-])zig[[:space:]]+[a-z]'   # a zig command (zig build, .../bin/zig test ...), not zig-out/

check() { # check <label> <script> <host...>
  local label=$1 script=$2; shift 2
  local -a hosts=("$@") a cmd
  local i j n h rc text rd sk host skip zn=0
  declare -A RD=() ZN=()
  rm -f "$T/ctl"/*
  (cd "$R" && env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" TMPDIR="$T/tmp" ZB_MAC_HOST="$INTEL" \
     ZB_MAC_ARM_HOST="$ARM" ZB_MAC_KEY="$T/home/no_such_key" timeout 120 bash "$script" >"$T/out" 2>&1 </dev/null)
  rc=$?
  n=$(cat "$T/ctl/n" 2>/dev/null || echo 0)
  [ "$rc" -eq 0 ] || { bad "$label: exit $rc (the run must reach its end): $(tail -n 2 "$T/out" | tr '\n' ' ')"; }
  for ((i = 0; i < n; i++)); do
    mapfile -d '' a < "$T/ctl/call.$i"
    [ "${a[0]}" = ssh ] || continue
    host= skip=
    for ((j = 1; j < ${#a[@]}; j++)); do
      if [ -n "$skip" ]; then skip=; continue; fi
      case "${a[j]}" in -i|-o|-F|-p|-l) skip=1; continue ;; -*) continue ;; esac
      host=${a[j]}; cmd=("${a[@]:j+1}"); break
    done
    text="${cmd[*]}"
    if [[ "$text" =~ $EXTRACT_RE ]]; then RD[$host]=${BASH_REMATCH[1]}; continue; fi
    tar -tf "$T/ctl/stdin.$i" >/dev/null 2>&1 || text+=$'\n'"$(cat "$T/ctl/stdin.$i")"
    [[ "$text" =~ $ZIG_RE ]] || continue
    rd=${RD[$host]:-}
    ZN[$host]=$(( ${ZN[$host]:-0} + 1 )); zn=$((zn + 1))
    if [ -z "$rd" ]; then bad "$label Z1: call $i runs zig on $host before any run dir exists"; continue; fi
    [[ "${cmd[*]}" == "cd \"\$HOME/$rd\" && "* ]] || bad "$label Z1: call $i runs zig outside cd \"\$HOME/$rd\": $(head -c 160 <<<"$text")"
    for flag in --cache-dir --global-cache-dir; do
      local fre="(^|[[:space:]])$flag[[:space:]]+\"\\\$HOME/$rd/[^\"/][^\"]*\""
      [[ "$text" =~ $fre ]] || bad "$label Z2: call $i on $host runs zig without $flag \"\$HOME/$rd/...\""
      while IFS= read -r sk; do
        [ -n "$sk" ] || continue
        local inre="^$flag[[:space:]]+\"\\\$HOME/$rd/"
        [[ "$sk" =~ $inre ]] || bad "$label Z2: call $i passes $sk outside \$HOME/$rd"
      done < <(grep -oE -- "$flag[[:space:]]+[^[:space:]]+" <<<"$text")
    done
  done
  for h in "${hosts[@]}"; do
    [ "${ZN[$h]:-0}" -ge 1 ] || bad "$label Z3: no zig invocation on $h was seen"
  done
  ok "$label: $zn remote zig invocation(s) checked over $n calls"
}

check build-on-mac  tests/mac/build-on-mac.sh      "$INTEL"
check gate          tests/mac/gate.sh              "$INTEL" "$ARM"
check ms1b          tests/mac/ms1b_signed_gate.sh  "$INTEL" "$ARM"
check ms2a          tests/mac/ms2a_gate.sh         "$INTEL" "$ARM"
check ms2b          tests/mac/ms2b_gate.sh         "$INTEL" "$ARM"
check ms2c          tests/mac/ms2c_gate.sh         "$INTEL" "$ARM"
check ms3           tests/mac/ms3_gate.sh          "$INTEL" "$ARM"
check ms4           tests/mac/ms4_gate.sh          "$INTEL" "$ARM"
check build-dmg     packaging/macos/build-dmg.sh   "$INTEL"

if [ "$fails" -eq 0 ]; then printf 'PASS\tmac-zig-cache-isolation-selftest\n'; exit 0; fi
printf 'FAIL\tmac-zig-cache-isolation-selftest\t%s failure(s)\n' "$fails"
exit 1
