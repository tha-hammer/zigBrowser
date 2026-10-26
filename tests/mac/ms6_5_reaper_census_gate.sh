#!/usr/bin/env bash
# MS6.5 Mac process-lifecycle product test on BOTH Macs. The reaper half remains census-only. The launch half
# starts the real Darwin Seatbelt launch beneath a disposable browser process, records the exact launch/CLI/child
# pids, and lets the browser quit normally. The launch group must then be empty within five seconds. The test's
# failure cleanup may signal only that recorded, test-started group; it never uses a name match or pkill.
# Per-run ~/zb-reaper-census-<nonce>, deleted on exit; nothing installed. BatchMode, strict host keys, no askpass;
# the arm64 host is required (no default).
# usage: tests/mac/ms6_5_reaper_census_gate.sh [commit]   (default: HEAD)
set -euo pipefail

LEG_TIMEOUT="${ZB_MAC_LEG_TIMEOUT:-240}"
export SSH_ASKPASS_REQUIRE=never

cd "$(git rev-parse --show-toplevel)"
. tests/mac/mac_gate_output.sh
# The Macs and the key come only from the explicit environment, never a default (bd 3ui.13): NOT RUN otherwise.
. tests/mac/mac_config.sh
mac_config two
# The Macs' host keys are pinned (bd 4pa.77): every ssh/scp below uses this file, never ~/.ssh/known_hosts.
KNOWN_HOSTS="$PWD/tests/mac/known_hosts"
stage=$(mktemp -d "${TMPDIR:-/tmp}/zb-reaper-census-XXXXXX")
trap 'case "$stage" in "${TMPDIR:-/tmp}"/zb-reaper-census-??????) find "${stage:?}" -delete;; esac' EXIT
SHA=$(git rev-parse --verify "${1:-HEAD}^{commit}")
echo "== commit $SHA" >&2
FILES=(src/agent_run_reaper.c src/agent_run_reaper.h tests/mac/ms6_5_reaper_census_probe.c
       agent/host/zb_agent_host/__init__.py agent/host/zb_agent_host/files.py
       agent/host/zb_agent_host/launch.py agent/host/zb_agent_host/options.py
       agent/host/zb_agent_host/parent_watch.py agent/host/zb_agent_host/platforms.py
       agent/host/zb_agent_host/relay.py agent/host/zb_agent_host/sandbox.py
       agent/host/zb_agent_host/sandbox_macos.py agent/host/zb_agent_host/seatbelt_rules.py
       agent/host/zb_agent_host/seccomp.py)
git archive "$SHA" -- "${FILES[@]}" | tar -x -C "$stage"

leg() { # $1=host $2=expected uname -m $3=key
  local host="$1" arch="$2" key="$3"
  local SSH=(env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY -u SSH_ASKPASS ssh -F none -i "$key" -o IdentitiesOnly=yes -o BatchMode=yes
             -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" -o ConnectTimeout=15 -o ServerAliveInterval=10)
  local rdir="zb-reaper-census-$(date +%s)-$$-$RANDOM"
  tar -C "${stage:?}" -cf - . | "${SSH[@]}" "$host" "mkdir \"\$HOME/${rdir:?}\" && tar -xf - -C \"\$HOME/${rdir}\"" \
    || { "${SSH[@]}" "$host" "d=\"\$HOME/${rdir:?}\"; [ -d \"\$d\" ] && find \"\$d\" -delete" || true
         echo "FAIL: staging on $host" >&2; return 1; }
  local out rc=0
  out=$(timeout "$LEG_TIMEOUT" "${SSH[@]}" "$host" "ZB_RDIR='${rdir}' ZB_ARCH='${arch}' /bin/bash -s" <<'REMOTE'
set -euo pipefail
d="$HOME/${ZB_RDIR:?}"
case "$ZB_RDIR" in zb-reaper-census-*) ;; *) echo "FAIL: bad run dir $ZB_RDIR" >&2; exit 1;; esac
browser_pid=""
launch_pid=""
cleanup() {
  if [[ "$browser_pid" =~ ^[2-9][0-9]*$ ]] && kill -0 "$browser_pid" 2>/dev/null; then
    kill -KILL "$browser_pid" 2>/dev/null || true
    wait "$browser_pid" 2>/dev/null || true
  fi
  if [[ "$launch_pid" =~ ^[2-9][0-9]*$ ]]; then
    pgid=$(/bin/ps -o pgid= -p "$launch_pid" 2>/dev/null | tr -d ' ') || pgid=""
    if [ "$pgid" = "$launch_pid" ]; then
      /usr/bin/python3 -I - "$launch_pid" <<'PY' 2>/dev/null || true
import os, signal, sys
os.killpg(int(sys.argv[1]), signal.SIGKILL)
PY
    fi
  fi
  cd /
  case "$ZB_RDIR" in zb-reaper-census-*) find "$HOME/${ZB_RDIR:?}" -delete;; esac
}
trap cleanup EXIT
[ "$(uname -m)" = "$ZB_ARCH" ] || { echo "FAIL: this leg is $(uname -m), expected $ZB_ARCH" >&2; exit 1; }
cd "$d"
xcrun clang -std=gnu11 -Wall -Wextra -Werror -Isrc src/agent_run_reaper.c \
  tests/mac/ms6_5_reaper_census_probe.c -o census_probe
./census_probe </dev/null

# The real Darwin launch path. A small browser parent starts it as the leader of a fresh process group, just as
# zb_agent_spawn_group_io_fd3 does. The sandboxed stand-in CLI forks one ordinary child; both record their own pids
# inside the allowed scratchpad. The browser then exits normally without signalling either process.
host="$d/agent-home/runtime/host"
home="$d/agent-home"
fake_python="$d/venv/bin/python"
mkdir -p "$host/zb_agent_host" "$home/.claude" "$home/workspace" "$home/scratchpad/tmp" "$d/venv/bin"
cp -f agent/host/zb_agent_host/*.py "$host/zb_agent_host/"
cat > "$host/claude_agent_sdk.py" <<'PY'
class ClaudeAgentOptions:
    pass
PY
printf '[]\n' > "$home/runtime/path.json"
cat > "$fake_python" <<'PY'
#!/usr/bin/python3
import os, time

pid_file = os.path.join(os.environ["HOME"], "scratchpad", "agent-pids")
child = os.fork()
if child == 0:
    while True:
        time.sleep(3600)
tmp = pid_file + ".tmp"
with open(tmp, "w", encoding="ascii") as stream:
    stream.write(f"{os.getpid()} {child}\n")
os.replace(tmp, pid_file)
while True:
    time.sleep(3600)
PY
chmod 700 "$fake_python"
cat > "$d/launch_driver.py" <<'PY'
import sys, types

host, home, python = sys.argv[1:]
sys.path.insert(0, host)
from zb_agent_host import launch, sandbox_macos

session = launch.Session(home=home, python=python, net_dir=None, command="chat", egress_port=54321)
args = types.SimpleNamespace(e2e_claude_cli=None, test_ca=None)
raise SystemExit(launch._launch_darwin(session, args, sandbox_macos.MacSeatbeltBackend(54321)))
PY
cat > "$d/browser_parent.py" <<'PY'
import os, subprocess, sys, time

driver, host, home, python, launch_file = sys.argv[1:]
proc = subprocess.Popen([sys.executable, "-I", driver, host, home, python],
                        stdin=subprocess.DEVNULL, start_new_session=True)
with open(launch_file + ".tmp", "w", encoding="ascii") as stream:
    stream.write(f"{proc.pid}\n")
os.replace(launch_file + ".tmp", launch_file)
pid_file = os.path.join(home, "scratchpad", "agent-pids")
deadline = time.monotonic() + 15
while time.monotonic() < deadline:
    if os.path.isfile(pid_file) and os.path.getsize(pid_file) > 0:
        raise SystemExit(0)
    if proc.poll() is not None:
        raise SystemExit(f"launch exited before the CLI started: {proc.returncode}")
    time.sleep(0.05)
os.killpg(proc.pid, 9)
proc.wait()
raise SystemExit("timed out waiting for the sandboxed CLI")
PY

/usr/bin/python3 -I "$d/browser_parent.py" "$d/launch_driver.py" "$host" "$home" "$fake_python" \
  "$d/launch-pid" >"$d/browser.out" 2>"$d/browser.err" &
browser_pid=$!
wait "$browser_pid" || {
  cat "$d/browser.err" >&2
  echo "FAIL ms6-5-agent-cleanup browser did not start the drawer agent"
  exit 1
}
browser_pid=""
launch_pid=$(tr -d '[:space:]' < "$d/launch-pid")
read cli_pid child_pid < "$home/scratchpad/agent-pids"
for pid in "$launch_pid" "$cli_pid" "$child_pid"; do
  [[ "$pid" =~ ^[2-9][0-9]*$ ]] || { echo "FAIL ms6-5-agent-cleanup invalid recorded pid: $pid"; exit 1; }
done

survivors=""
for _ in {1..100}; do
  survivors=""
  for pid in "$launch_pid" "$cli_pid" "$child_pid"; do
    state=$(/bin/ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ') || state=""
    case "$state" in ""|Z*) ;; *) survivors="$survivors $pid:$state";; esac
  done
  [ -z "$survivors" ] && break
  sleep 0.05
done
if [ -n "$survivors" ]; then
  echo "FAIL ms6-5-agent-cleanup browser-exit survivors$survivors"
  exit 1
fi
launch_pid=""
echo "PASS ms6-5-agent-cleanup browser-exit no-survivors"
REMOTE
  ) || rc=$?
  printf '%s\n' "$out" >&2
  [ "$rc" -eq 0 ] || { echo "FAIL: ms6-5-reaper-census $arch leg on $host timed out/failed" >&2; return 1; }
  mac_require_lines ms6_5_reaper_census_gate "$host" "$arch" "$out" \
    'PASS ms6-5-reaper-census 18 checks' \
    'PASS ms6-5-agent-cleanup browser-exit no-survivors' || return 1
}

overall=0
leg "$INTEL_HOST" x86_64 "$KEY" || { echo "FAIL: x86_64 leg" >&2; overall=1; }
leg "$ARM_HOST" arm64 "$ARM_KEY" || { echo "FAIL: arm64 leg" >&2; overall=1; }
[ "$overall" -eq 0 ] && printf 'PASS\tms6-5-reaper-census-gate\tboth-arches\n'
exit "$overall"
