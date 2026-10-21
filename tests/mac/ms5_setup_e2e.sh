#!/usr/bin/env bash
# MS5 item 5's real-browser e2e (macOS plan rev 14; RoseCat 6771, 6773), BOTH Macs: the real zigBrowser
# `--agent-setup` (posix_spawn group + setup.py's kqueue parent watch) must take setup's whole process group with it
# when the browser is SIGKILLed, (a) mid-setup (the e2e pause seam swap:before) and (b) at the check-to-register
# barrier, then a ps census of the group: no member alive after 2 s.
#
# NOT ARMED until both prerequisites hold, and then it says so instead of passing (exit 3, never PASS):
#   1. MS6: the built binary still refuses with "the macOS sandbox is not ready" (agent_setup.seatbelt_ready);
#   2. the staged runtime: Frameworks/agent-host must hold the relocated framework AND the locked dependencies
#      (the user's decisions, research 9319ef2) — today packaging/macos/stage_agent_runtime.sh stages MS5.1c-a only.
# Usage: bash tests/mac/ms5_setup_e2e.sh [commit]   (default HEAD). BatchMode, strict host keys, no askpass.
set -euo pipefail

KEY="${ZB_MAC_KEY:-/home/maceo/vms/mac-m9/zb_mac_key}"
INTEL_HOST="${ZB_MAC_HOST:-maceojourdan@100.92.212.47}"
ARM_HOST="${ZB_MAC_ARM_HOST:-jj@100.119.156.28}"
LEG_TIMEOUT="${ZB_MAC_LEG_TIMEOUT:-1800}"
export SSH_ASKPASS_REQUIRE=never

cd "$(git rev-parse --show-toplevel)"
SHA=$(git rev-parse --verify "${1:-HEAD}^{commit}")
SSH=(env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY ssh -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes
     -o StrictHostKeyChecking=yes -o ConnectTimeout=15 -o ServerAliveInterval=10)
SCP=(env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY scp -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes
     -o StrictHostKeyChecking=yes -o ConnectTimeout=15)
TAR=$(mktemp "${TMPDIR:-/tmp}/zb-ms5e2e-XXXXXX.tar"); trap 'rm -f -- "$TAR"' EXIT
git archive --format=tar -o "$TAR" "$SHA" src build.zig build.zig.zon zigbrowser.json tests packaging agent tools

leg() { # $1=host $2=expected uname -m
  local host="$1" arch="$2" rdir="zb-ms5e2e-$(date +%s)-$$-$RANDOM"
  "${SSH[@]}" "$host" "mkdir \"\$HOME/${rdir:?}\"" || { echo "FAIL: mkdir on $host" >&2; return 1; }
  "${SCP[@]}" "$TAR" "$host:${rdir}/src.tar" >/dev/null || { "${SSH[@]}" "$host" "rm -rf \"\$HOME/${rdir:?}\""; return 1; }
  timeout "$LEG_TIMEOUT" "${SSH[@]}" "$host" "ZB_RDIR='${rdir}' ZB_ARCH='${arch}' /bin/bash -s" <<'REMOTE'
set -euo pipefail
d="$HOME/${ZB_RDIR:?}"; trap 'pkill -KILL -g "$(cat "$d/pgid" 2>/dev/null || echo 0)" 2>/dev/null || true; rm -rf "$HOME/${ZB_RDIR:?}"' EXIT
[ "$(uname -m)" = "$ZB_ARCH" ] || { echo "FAIL: leg is $(uname -m), expected $ZB_ARCH" >&2; exit 1; }
cd "$d" && tar -xf src.tar
"$HOME/.local/bin/zig" build install > build.log 2>&1 || { tail -20 build.log; echo "FAIL: build" >&2; exit 1; }
home="$d/home"; mkdir "$home"
set +e
env -i PATH=/usr/bin:/bin HOME="$home" LANG=C ./zig-out/bin/zigBrowser --agent-setup > out.txt 2> err.txt
set -e
if grep -q "the macOS sandbox is not ready" err.txt; then
  printf 'NOT ARMED\tms5-setup-e2e\t%s\tMS6 not landed (agent_setup.seatbelt_ready is false)\n' "$ZB_ARCH"; exit 3
fi
if [ ! -x zig-out/Frameworks/agent-host/Python.framework/Versions/3.12/bin/python3.12 ] || [ ! -d zig-out/Frameworks/agent-host/site-packages ]; then
  printf 'NOT ARMED\tms5-setup-e2e\t%s\tno staged runtime with dependencies (the user decisions, research 9319ef2)\n' "$ZB_ARCH"; exit 3
fi
# Armed. (a) SIGKILL the browser while setup is paused at swap:before, then census setup's process group.
mkdir -p "$d/sai" && printf '{}\n' > "$d/sai/settings.json"
env -i PATH=/usr/bin:/bin HOME="$home" LANG=C ZIGBROWSER_AGENT_SETUP_PAUSE=swap:before \
  ./zig-out/bin/zigBrowser --agent-setup --e2e-protocol --sai-source "$d/sai" > out2.txt 2> err2.txt &
B=$!
for _ in $(seq 1 600); do grep -q "SETUP	paused	swap:before" out2.txt 2>/dev/null && break; sleep 0.5; done
grep -q "SETUP	paused	swap:before" out2.txt || { kill -KILL "$B" 2>/dev/null; tail -5 err2.txt; echo "FAIL: setup never paused" >&2; exit 1; }
S=$(pgrep -P "$B" | head -1)
[ -n "$S" ] || { kill -KILL "$B"; echo "FAIL: no setup child" >&2; exit 1; }
PG=$(ps -o pgid= -p "$S" | tr -d ' '); echo "$PG" > "$d/pgid"
fails=0
[ "$PG" = "$S" ] || { echo "  FAIL setup ($S) does not lead its own group ($PG)"; fails=$((fails+1)); }
[ "$(ps -o pgid= -p "$B" | tr -d ' ')" != "$PG" ] || { echo "  FAIL the browser is in setup's group"; fails=$((fails+1)); }
kill -KILL "$B"; wait "$B" 2>/dev/null || true
live=1
for _ in $(seq 1 20); do live=$(ps -o stat= -g "$PG" | grep -vc '^Z' || true); [ "$live" = 0 ] && break; sleep 0.1; done
[ "$live" = 0 ] || { echo "  FAIL $live member(s) of setup's group alive 2 s after the browser's SIGKILL: $(ps -o pid=,stat=,command= -g "$PG" | head -5)"; fails=$((fails+1)); }
# (b) the check-to-register barrier needs setup.py's e2e watch barrier (the follow-up slice); until it exists an
# armed run fails here rather than passing on (a) alone.
echo "  FAIL case (b), the check-to-register barrier: setup.py's --e2e-watch-barrier seam is not built yet"; fails=$((fails+1))
if [ "$fails" -eq 0 ]; then printf 'PASS\tms5-setup-e2e\t%s\n' "$ZB_ARCH"; else printf 'FAIL\tms5-setup-e2e\t%s\t%d\n' "$ZB_ARCH" "$fails"; exit 1; fi
REMOTE
}

overall=0; armed=1
for pair in "$INTEL_HOST x86_64" "$ARM_HOST arm64"; do
  set +e; leg $pair; rc=$?; set -e
  case "$rc" in 0) ;; 3) armed=0 ;; *) overall=1; echo "FAIL: ${pair#* } leg" >&2 ;; esac
done
[ "$overall" -eq 0 ] || exit 1
[ "$armed" -eq 1 ] || { echo "NOT ARMED: ms5-setup-e2e (not a pass)" >&2; exit 3; }
printf 'PASS\tms5-setup-e2e\tboth-arches\t%s\n' "$SHA"
