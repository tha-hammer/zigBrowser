#!/usr/bin/env bash
# Hostless selftest of the disable-by-default guard of tests/mac/ms6_5_reaper_gate.sh (plan R29-SAFETY, R30-MS6,
# bd zigBrowser-4pa.70). That script SIGKILLs real processes on the Macs, so it must refuse to start unless BOTH
#   ZB_REAPER_DESTRUCTIVE_APPROVED equals the exact commit it stages, AND
#   the orchestrator's release-token file $HOME/.ntm/zb-release/reaper-gate-<sha> exists and holds that sha.
# No Mac, no network, no signal: the REAL script runs in a scratch git repo, with HOME and TMPDIR inside this test's
# temporary tree, and a stub `ssh` and `scp` first on PATH that only record their calls (and the tar on stdin) and
# fail. Each refusal row requires exit 1, the line "DISABLED: destructive reaper gate", and zero ssh/scp calls. The
# positive control (both conditions met) must get past the guard and reach the stub ssh, and the tar it hands over
# must hold the committed bytes, not a dirty working copy. A guard that always refuses fails that control.
# Run: bash tests/mac/ms6_5_reaper_gate_guard_selftest.sh [script path]   (step: zig build test-mac-reaper-gate-guard)
set -uo pipefail
SCRIPT=$(realpath "${1:-tests/mac/ms6_5_reaper_gate.sh}")
BASE=$(mktemp -d "${TMPDIR:-/tmp}/zb-reaper-guard-XXXXXX")
T=$(realpath "$BASE")
printf 'not a real key\n' > "$T/fake_mac_key"   # tests/mac/mac_config.sh needs a readable regular key file (bd 3ui.13)
cleanup() {
  case "$T" in "$(realpath "${TMPDIR:-/tmp}")"/zb-reaper-guard-??????) rm -rf "${T:?}" ;; esac
}
trap cleanup EXIT
fails=0
ok() { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }

mkdir -p "$T/bin" "$T/ctl" "$T/home" "$T/tmp" "$T/repo/src" "$T/repo/tests/mac"
for tool in ssh scp; do
  cat > "$T/bin/$tool" <<EOF
#!/bin/bash
n=0; [ -f "$T/ctl/calls" ] && n=\$(wc -l < "$T/ctl/calls")
printf '%s %s\n' "$tool" "\$*" >> "$T/ctl/calls"
cat > "$T/ctl/stdin.\$n"
exit 1
EOF
  chmod +x "$T/bin/$tool"
done

# A scratch repo holding the real script and stand-ins for the three files it stages.
cp "$SCRIPT" "$T/repo/tests/mac/ms6_5_reaper_gate.sh"
cp "$(dirname "$SCRIPT")/mac_config.sh" "$T/repo/tests/mac/mac_config.sh"   # its hosts and key (bd 3ui.13)
echo 'committed reaper' > "$T/repo/src/agent_run_reaper.c"
echo 'committed header' > "$T/repo/src/agent_run_reaper.h"
echo 'committed driver' > "$T/repo/tests/mac/ms6_5_reaper_test.c"
G=(env -i PATH=/usr/bin:/bin HOME="$T/home" GIT_CONFIG_NOSYSTEM=1 git -C "$T/repo")
"${G[@]}" init -q && "${G[@]}" add -A \
  && "${G[@]}" -c user.name=selftest -c user.email=selftest@invalid commit -q -m staged \
  || { bad "could not build the scratch repo"; exit 1; }
SHA=$("${G[@]}" rev-parse HEAD)
echo 'DIRTY working copy' > "$T/repo/src/agent_run_reaper.c"   # tracked and modified: must never be staged

run() { # run <label> [VAR=value ...]: runs the real script; sets rc, out, calls
  local label=$1; shift
  rm -f "$T/ctl/calls" "$T/ctl"/stdin.*
  out=$(cd "$T/repo" && env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" TMPDIR="$T/tmp" \
          ZB_MAC_ARM_HOST=arm@stub.invalid ZB_MAC_HOST=intel@stub.invalid ZB_MAC_KEY="$T/fake_mac_key" \
          ZB_MAC_LEG_TIMEOUT=5 "$@" \
          timeout 60 bash tests/mac/ms6_5_reaper_gate.sh 2>&1 </dev/null)
  rc=$?
  calls=0; [ -f "$T/ctl/calls" ] && calls=$(wc -l < "$T/ctl/calls")
  printf -- '--- %s: rc=%s calls=%s\n%s\n' "$label" "$rc" "$calls" "$out" | sed 's/^/     /'
}
refused() { # refused <label>: exit 1, the DISABLED line, zero ssh/scp calls
  if [ "$rc" -eq 1 ]; then ok "$1: exit 1"; else bad "$1: exit $rc, want 1"; fi
  case "$out" in *"DISABLED: destructive reaper gate"*) ok "$1: says DISABLED" ;;
    *) bad "$1: no \"DISABLED: destructive reaper gate\" line" ;; esac
  if [ "$calls" -eq 0 ]; then ok "$1: ssh_calls == 0"; else bad "$1: ssh_calls == $calls, want 0"; fi
}
token() { # token <sha> <content>
  mkdir -p "$T/home/.ntm/zb-release"
  printf '%s\n' "$2" > "$T/home/.ntm/zb-release/reaper-gate-$1"
}

# Row 1: only ZB_MAC_ARM_HOST set (the whole guard at HEAD 5ccf442).
run "row 1, only ZB_MAC_ARM_HOST"
refused "row 1"

# Row 2: the approved sha equals the staged commit, but no release token exists.
run "row 2, approved == HEAD, no token" ZB_REAPER_DESTRUCTIVE_APPROVED="$SHA"
refused "row 2"

# Row 3: a release token exists, but nothing is approved.
token "$SHA" "$SHA"
run "row 3, token, no approval"
refused "row 3"

# Row 4: approved and token name a commit other than the staged one.
OTHER=0123456789abcdef0123456789abcdef01234567
token "$OTHER" "$OTHER"
run "row 4, approved == token != staged commit" ZB_REAPER_DESTRUCTIVE_APPROVED="$OTHER"
refused "row 4"

# Row 5: approved == HEAD and the token file is named for HEAD but holds another sha.
token "$SHA" "$OTHER"
run "row 5, token content != sha" ZB_REAPER_DESTRUCTIVE_APPROVED="$SHA"
refused "row 5"

# Row 6 (positive control): both conditions met. The guard must let it reach ssh (the stub fails the leg, so no
# remote command runs anywhere), and the tar handed to ssh must hold the committed bytes.
token "$SHA" "$SHA"
printf '# no target of this run is shared\n' > "$T/home/.ntm/zb-release/shared-mac-hosts"   # the shared-host contract
run "row 6, approved == HEAD and token" ZB_REAPER_DESTRUCTIVE_APPROVED="$SHA"
case "$out" in *DISABLED*) bad "row 6: refused although approved and released" ;; *) ok "row 6: not DISABLED" ;; esac
if [ "$calls" -ge 1 ]; then ok "row 6: reached ssh ($calls calls)"; else bad "row 6: never reached ssh"; fi
if [ -s "$T/ctl/stdin.0" ]; then
  staged=$(tar -xOf "$T/ctl/stdin.0" ./agent_run_reaper.c 2>/dev/null)
  if [ "$staged" = 'committed reaper' ]; then ok "row 6: staged the committed bytes"
  else bad "row 6: staged \"$staged\", want the committed bytes"; fi
else
  bad "row 6: the first ssh call got no tar"
fi
if [ "$rc" -ne 0 ]; then ok "row 6: exit $rc (stub ssh fails the legs)"; else bad "row 6: exit 0 with failing ssh"; fi

if [ "$fails" -eq 0 ]; then printf 'PASS\tmac-reaper-gate-guard-selftest\n'; exit 0; fi
printf 'FAIL\tmac-reaper-gate-guard-selftest\t%s failure(s)\n' "$fails"
exit 1
