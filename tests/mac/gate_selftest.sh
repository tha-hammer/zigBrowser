#!/usr/bin/env bash
# Hostless selftest of the MS1 two-host gate's fail-closed runner, tests/mac/gate.sh (plan MS1.4 and R30-MS1: "with
# stub ssh reporting each of {no GUI session, wrong arch, missing runtime/SDK, zero recorded assertions}, gate.sh exits
# non-zero, and it never prints a SKIP-to-green line"; rule 7: a skip or zero real assertions under a gate is failure).
# The REAL gate.sh (with the real build-on-mac.sh and mac_gate_lib.sh, and the real local resource-phase check) runs in
# a scratch git repo against a scenario-driven stub `ssh`/`scp`: each remote command gets the answer a real Mac gives
# in that scenario (the remote tests' own contract: PASS line + exit 0, SKIP exit 77, FAIL exit 1/2/3), on one named
# host only, so every row is per host and per arch:
#   ok             both legs healthy: exit 0, both PASS mac-leg lines, then PASS mac-universal-gate (the control);
#   nogui          the M9 e2e on that host skips (no logged-in GUI session): exit 77 from the remote script;
#   wrongarch      that host executes the other slice (Rosetta): exec-arch reads the wrong arch, mac_universal fails;
#   nosdk          the native build on that host cannot find the SDK frameworks: the build fails;
#   zero_m9        the M9 remote script exits 0 but no test printed its PASS line (zero recorded assertions);
#   zero_universal mac_universal_test exits 0 silently (zero recorded assertions);
#   zero_count     mac_universal_test prints "PASS mac-universal 0 assertions" and exits 0;
#   late_m9        the M9 remote script prints every PASS line, then exits 1 (the exit code is checked too);
#   late_universal mac_universal_test prints its PASS line, then exits 1.
# Every failure row requires: exit 1 with no shell error (not a crash), no "PASS<TAB>mac-universal-gate" line, no stdout line starting with SKIP,
# and no PASS mac-leg line for the failing host. Plus: no arm64 host configured -> NOT RUN, exit 1, zero ssh calls.
# No Mac, no signal: it re-runs itself in a private user+network namespace; HOME/TMPDIR live in its temp tree.
# Run: bash tests/mac/gate_selftest.sh [repo root]   (step: zig build test-mac-gate-selftest)
set -uo pipefail
if [ "${ZB_GATE_SELFTEST_INNER:-}" != 1 ]; then
  ZB_GATE_SELFTEST_INNER=1 exec unshare --user --map-current-user --net bash "$(realpath "$0")" "$@"
fi
ROOT=$(realpath "${1:-.}")
BASE=$(mktemp -d "${TMPDIR:-/tmp}/zb-gate-selftest-XXXXXX")
T=$(realpath "$BASE")
cleanup() {
  case "$T" in "$(realpath "${TMPDIR:-/tmp}")"/zb-gate-selftest-??????) rm -rf "${T:?}" ;; esac
}
trap cleanup EXIT
fails=0
ok() { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }
INTEL=intel@10.0.0.1 ARM=arm@10.0.0.2

mkdir -p "$T/bin" "$T/ctl" "$T/home" "$T/tmp"
cat > "$T/bin/ssh" <<EOF
#!/bin/bash
# Scenario stub: \$(cat ctl/mode) applies only on the host named by \$(cat ctl/where) (intel|arm).
i=\$(cat "$T/ctl/n" 2>/dev/null || echo 0); echo \$((i + 1)) > "$T/ctl/n"
cat > "$T/ctl/stdin.\$i"
mode=\$(cat "$T/ctl/mode") where=\$(cat "$T/ctl/where")
host= skip= k=0
for a in "\$@"; do
  k=\$((k + 1))
  if [ -n "\$skip" ]; then skip=; continue; fi
  case "\$a" in -i|-o|-F|-p|-l) skip=1; continue ;; -*) continue ;; esac
  host=\$a; break
done
cmd=("\${@:k+1}") c="\${*:k+1}"
case "\$host" in $INTEL) role=intel arch=x86_64 other=arm64 ;; $ARM) role=arm arch=arm64 other=x86_64 ;;
  *) echo "stub ssh: unexpected host \$host" >&2; exit 99 ;; esac
hit=; [ "\$role" = "\$where" ] && hit=\$mode
case "\$c" in
  mkdir\ \"\\\$HOME/zb-gate-*\"\ \&\&\ tar\ -xf\ -*) exit 0 ;;
  cd\ \"\\\$HOME/zb-gate-*\"\ \&\&\ *zig\ build*)
    if [ "\$hit" = nosdk ]; then echo "error: unable to find framework 'WebKit'; searched paths: none" >&2; exit 1; fi
    echo "build ok"; exit 0 ;;
  cd\ /\ \&\&\ *-delete*) exit 0 ;;
  mkdir\ -p\ *) exit 0 ;;
  test\ -s\ *exec-arch.txt*) exit 0 ;;
  cat\ *exec-arch.txt*) if [ "\$hit" = wrongarch ]; then echo "\$other"; else echo "\$arch"; fi; exit 0 ;;
  *pillow_tools.py\ nonuniform*) echo '{"stddev": 41.5, "distinct": 913, "width": 800, "height": 600}'; exit 0 ;;
esac
if [ "\${cmd[0]:-}" = /bin/bash ] && [ "\${cmd[1]:-}" = -s ]; then
  s="$T/ctl/stdin.\$i"
  if grep -q 'lipo -create' "\$s"; then
    echo "universal archs: x86_64 arm64"; echo "shim dylib archs: x86_64 arm64"; exit 0
  elif grep -q m9_render_test.py "\$s"; then
    case "\$hit" in
      nogui) echo "SKIP: M9 needs the logged-in console GUI session" >&2; exit 77 ;;
      zero_m9) exit 0 ;;
    esac
    printf 'PASS\tm9-render-webview-screenshot\tzig-out/m9-render.png\tuniformity deferred to the caller'"'"'s PIL host\n'
    printf 'PASS\tm9-reply-channel-contract\n'
    printf 'PASS\tm9-load-fail-contract\n'
    echo "exec_arch_probe: build.exec_arch=\$arch"
    if [ "\$hit" = late_m9 ]; then echo "Traceback: teardown failed after the PASS lines" >&2; exit 1; fi
    exit 0
  elif grep -q mac_universal_test.py "\$s"; then
    case "\$hit" in
      wrongarch) echo "FAIL: executing arch \$other != expected \$arch" >&2
                 echo "mac_universal_test: 1/12 assertions failed" >&2; exit 1 ;;
      zero_universal) exit 0 ;;
      zero_count) printf 'PASS\tmac-universal\t0 assertions\n'; exit 0 ;;
    esac
    printf 'PASS\tmac-universal\t12 assertions\n'
    if [ "\$hit" = late_universal ]; then echo "Traceback: teardown failed after the PASS line" >&2; exit 1; fi
    exit 0
  fi
fi
echo "stub ssh: unknown remote command: \$c" >&2
exit 99
EOF
cat > "$T/bin/scp" <<EOF
#!/bin/bash
i=\$(cat "$T/ctl/n" 2>/dev/null || echo 0); echo \$((i + 1)) > "$T/ctl/n"
: > "$T/ctl/stdin.\$i"
dst="\${@: -1}" src="\${@: -2:1}"
case "\$dst" in *:*) ;; *)   # a fetch: leave a stub file where the remote file lands
  if [ -d "\$dst" ]; then echo stub > "\$dst/\$(basename "\${src#*:}")"; else echo stub > "\$dst"; fi ;;
esac
exit 0
EOF
chmod +x "$T/bin/ssh" "$T/bin/scp"

# The scratch repo: the real gate, its build step and library, the pinned host keys, the real local resource-phase
# check with its manifest, and stand-ins for every other path build-on-mac.sh archives.
R="$T/repo"
mkdir -p "$R/tests/mac" "$R/tests/e2e" "$R/src" "$R/packaging/macos"
for f in gate.sh build-on-mac.sh mac_gate_lib.sh known_hosts; do
  [ -f "$ROOT/tests/mac/$f" ] && cp "$ROOT/tests/mac/$f" "$R/tests/mac/"
done
cp "$ROOT/tests/e2e/mac_resource_compat.py" "$ROOT/tests/e2e/mac_universal_test.py" "$R/tests/e2e/"
cp "$ROOT/packaging/macos/universal_components.json" "$ROOT/packaging/macos/entitlements.plist" "$R/packaging/macos/"
echo src > "$R/src/main.zig"
echo build > "$R/build.zig"; echo zon > "$R/build.zig.zon"; echo '{}' > "$R/zigbrowser.json"
G=(env -i PATH=/usr/bin:/bin HOME="$T/home" GIT_CONFIG_NOSYSTEM=1 git -C "$R")
"${G[@]}" init -q && "${G[@]}" add -A \
  && "${G[@]}" -c user.name=selftest -c user.email=selftest@invalid commit -q -m staged \
  || { bad "could not build the scratch repo"; exit 1; }

run_gate() { # run_gate <mode> <where> [arm host]: sets rc, out (stdout), err (stderr), calls
  rm -f "$T/ctl"/*
  echo "$1" > "$T/ctl/mode"; echo "$2" > "$T/ctl/where"
  out=$(cd "$R" && env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" TMPDIR="$T/tmp" \
          ZB_MAC_HOST="$INTEL" ZB_MAC_ARM_HOST="${3-$ARM}" ZB_MAC_KEY="$T/home/no_such_key" \
          timeout 120 bash tests/mac/gate.sh 2>"$T/ctl/err" </dev/null)
  rc=$?
  err=$(cat "$T/ctl/err")
  calls=$(cat "$T/ctl/n" 2>/dev/null || echo 0)
  printf -- '--- %s on %s: rc=%s calls=%s\n%s\n' "$1" "$2" "$rc" "$calls" "$out" | sed 's/^/     /'
  grep -E 'FAIL|NOT RUN|SKIP' <<<"$err" | head -n 4 | sed 's/^/     stderr: /'
}
fails_closed() { # fails_closed <label> <failing host>
  local label=$1 host=$2
  # It must fail the way the gate fails (exit 1), not crash: a missing function or a typo exits 127 or 2 and would
  # otherwise pass every row here while the gate is broken.
  if [ "$rc" -eq 1 ]; then ok "$label: exit 1"; else bad "$label: exit $rc, want 1 (the gate's own failure)"; fi
  if grep -qE 'command not found|syntax error|unbound variable|bad substitution' <<<"$err"; then
    bad "$label: the gate hit a shell error: $(grep -m1 -E 'command not found|syntax error|unbound variable|bad substitution' <<<"$err")"
  fi
  if grep -qP '^PASS\tmac-universal-gate' <<<"$out"; then bad "$label: printed PASS mac-universal-gate"
  else ok "$label: no PASS mac-universal-gate line"; fi
  if grep -q '^SKIP' <<<"$out"; then bad "$label: printed a SKIP line"; else ok "$label: no SKIP line"; fi
  if grep -qP "^PASS\tmac-leg\t$host\t" <<<"$out"; then bad "$label: the failing $host leg printed PASS"
  else ok "$label: no PASS for the $host leg"; fi
}

# Control: both legs healthy.
run_gate ok intel
if [ "$rc" -eq 0 ] && [ "$(tail -n 1 <<<"$out")" = "$(printf 'PASS\tmac-universal-gate\tboth-arches')" ] \
   && [ "$(grep -cP '^PASS\tmac-leg\t' <<<"$out")" -eq 2 ]; then ok "ok: exit 0, two leg PASS lines, then the gate PASS"
else bad "ok: the healthy control did not pass (rc=$rc)"; fi

for host_role in intel arm; do
  h=$INTEL; [ "$host_role" = arm ] && h=$ARM
  run_gate nogui "$host_role";          fails_closed "no GUI session on $host_role" "$h"
  run_gate nosdk "$host_role";          fails_closed "missing SDK on $host_role" "$h"
  run_gate zero_m9 "$host_role";        fails_closed "zero M9 assertions on $host_role" "$h"
  run_gate zero_universal "$host_role"; fails_closed "zero mac_universal assertions on $host_role" "$h"
  run_gate zero_count "$host_role";     fails_closed "mac_universal 0 assertions on $host_role" "$h"
  run_gate late_m9 "$host_role";        fails_closed "M9 PASS lines then exit 1 on $host_role" "$h"
  run_gate late_universal "$host_role"; fails_closed "mac_universal PASS line then exit 1 on $host_role" "$h"
done
run_gate wrongarch arm; fails_closed "wrong arch (Rosetta) on arm" "$ARM"

# No arm64 host: NOT RUN before any ssh.
run_gate ok intel ""
if [ "$rc" -ne 0 ] && grep -q 'NOT RUN: arm64 host not configured' <<<"$err" && [ "$calls" -eq 0 ]; then
  ok "no arm64 host: NOT RUN, exit $rc, zero ssh/scp calls"
else bad "no arm64 host: rc=$rc calls=$calls"; fi

if [ "$fails" -eq 0 ]; then printf 'PASS\tmac-gate-selftest\n'; exit 0; fi
printf 'FAIL\tmac-gate-selftest\t%s failure(s)\n' "$fails"
exit 1
