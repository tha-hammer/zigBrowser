#!/usr/bin/env bash
# Hostless selftest of the shared-host refusal of tests/mac/ms6_5_reaper_gate.sh (plan rev 32 R29-SAFETY: "it also
# refuses to run when $HOME's Mac host list matches a shared host"; bd zigBrowser-4pa.70, SilverRidge cd515ce).
# The contract: the orchestrator-owned list $HOME/.ntm/zb-release/shared-mac-hosts names the Mac hosts other people
# are using, one per line as user@host or host ('#' starts a comment). Even when the commit is approved and released,
# the script exits 1 with "DISABLED: destructive reaper gate" before any ssh/scp when
#   - either target host (ZB_MAC_HOST, ZB_MAC_ARM_HOST) is on that list, compared on the host part (user@ dropped); or
#   - the list is missing (fail closed: an undeclared list is never read as "nothing is shared").
# No Mac, no network, no signal: the REAL script runs in a scratch git repo, with HOME and TMPDIR inside this test's
# temporary tree and a stub `ssh` and `scp` first on PATH that only record calls and fail. Every row is approved
# and released, so only the shared-host contract decides it. The positive control (a list that names neither
# target) must reach the stub ssh, so a refusal that always fires fails it.
# Run: bash tests/mac/ms6_5_reaper_gate_shared_host_selftest.sh [script path]   (step: zig build test-mac-reaper-gate-guard)
set -uo pipefail
SCRIPT=$(realpath "${1:-tests/mac/ms6_5_reaper_gate.sh}")
BASE=$(mktemp -d "${TMPDIR:-/tmp}/zb-reaper-shared-XXXXXX")
T=$(realpath "$BASE")
cleanup() {
  case "$T" in "$(realpath "${TMPDIR:-/tmp}")"/zb-reaper-shared-??????) rm -rf "${T:?}" ;; esac
}
trap cleanup EXIT
fails=0
ok() { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }

mkdir -p "$T/bin" "$T/ctl" "$T/home/.ntm/zb-release" "$T/tmp" "$T/repo/src" "$T/repo/tests/mac"
for tool in ssh scp; do
  cat > "$T/bin/$tool" <<EOF
#!/bin/bash
printf '%s %s\n' "$tool" "\$*" >> "$T/ctl/calls"
cat > /dev/null
exit 1
EOF
  chmod +x "$T/bin/$tool"
done

cp "$SCRIPT" "$T/repo/tests/mac/ms6_5_reaper_gate.sh"
echo 'committed reaper' > "$T/repo/src/agent_run_reaper.c"
echo 'committed header' > "$T/repo/src/agent_run_reaper.h"
echo 'committed driver' > "$T/repo/tests/mac/ms6_5_reaper_test.c"
G=(env -i PATH=/usr/bin:/bin HOME="$T/home" GIT_CONFIG_NOSYSTEM=1 git -C "$T/repo")
"${G[@]}" init -q && "${G[@]}" add -A \
  && "${G[@]}" -c user.name=selftest -c user.email=selftest@invalid commit -q -m staged \
  || { bad "could not build the scratch repo"; exit 1; }
SHA=$("${G[@]}" rev-parse HEAD)
printf '%s\n' "$SHA" > "$T/home/.ntm/zb-release/reaper-gate-$SHA"   # approved AND released in every row
LIST="$T/home/.ntm/zb-release/shared-mac-hosts"
INTEL=intel@10.0.0.1 ARM=arm@10.0.0.2

run() { # run <label>: runs the real script, approved and released; sets rc, out, calls
  rm -f "$T/ctl/calls"
  out=$(cd "$T/repo" && env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" TMPDIR="$T/tmp" \
          ZB_MAC_HOST="$INTEL" ZB_MAC_ARM_HOST="$ARM" ZB_MAC_LEG_TIMEOUT=5 ZB_REAPER_DESTRUCTIVE_APPROVED="$SHA" \
          timeout 60 bash tests/mac/ms6_5_reaper_gate.sh 2>&1 </dev/null)
  rc=$?
  calls=0; [ -f "$T/ctl/calls" ] && calls=$(wc -l < "$T/ctl/calls")
  printf -- '--- %s: rc=%s calls=%s\n%s\n' "$1" "$rc" "$calls" "$out" | sed 's/^/     /'
}
refused() { # refused <label>: exit 1, the DISABLED line, zero ssh/scp calls
  if [ "$rc" -eq 1 ]; then ok "$1: exit 1"; else bad "$1: exit $rc, want 1"; fi
  case "$out" in *"DISABLED: destructive reaper gate"*) ok "$1: says DISABLED" ;;
    *) bad "$1: no \"DISABLED: destructive reaper gate\" line" ;; esac
  if [ "$calls" -eq 0 ]; then ok "$1: ssh_calls == 0"; else bad "$1: ssh_calls == $calls, want 0"; fi
}

# S1: the list names the arm64 target as user@host.
printf '# hosts in use by others\n%s\n' "$ARM" > "$LIST"
run "S1, arm64 target listed as user@host"
refused "S1"

# S2: the list names the Intel target by its bare host; the target is given as user@host.
printf 'other@10.9.9.9\n  %s  \n' "${INTEL#*@}" > "$LIST"
run "S2, Intel target listed as bare host"
refused "S2"

# S3: no list at all (fail closed).
rm -f "$LIST"
run "S3, no shared-host list"
refused "S3"

# S4 (positive control): the list exists and names neither target, only a comment, a blank line and other hosts.
printf '# nothing of ours\n\nother@10.9.9.9\n10.0.0.10\n' > "$LIST"
run "S4, list names neither target"
case "$out" in *DISABLED*) bad "S4: refused although no target is shared" ;; *) ok "S4: not DISABLED" ;; esac
if [ "$calls" -ge 1 ]; then ok "S4: reached ssh ($calls calls)"; else bad "S4: never reached ssh"; fi

if [ "$fails" -eq 0 ]; then printf 'PASS\tmac-reaper-gate-shared-host-selftest\n'; exit 0; fi
printf 'FAIL\tmac-reaper-gate-shared-host-selftest\t%s failure(s)\n' "$fails"
exit 1
