#!/usr/bin/env bash
# MS6.5 product test: the real Darwin Seatbelt launch must reap a setsid + double-fork orphan when its browser
# parent quits. The browser must exit normally and an unrelated test-owned process must remain alive. Cleanup
# signals only identities recorded by this run; every PID is paired with Darwin's p_uniqueid before any signal.
# Per-run ~/zb-ms65-orphan-<nonce>, guarded find-delete on exit. No pkill or process-name matching.
# usage: tests/mac/ms6_5_orphan_gate.sh [commit]   (default: HEAD)
set -euo pipefail

LEG_TIMEOUT="${ZB_MAC_LEG_TIMEOUT:-240}"
export SSH_ASKPASS_REQUIRE=never

cd "$(git rev-parse --show-toplevel)"
. tests/mac/mac_gate_output.sh
. tests/mac/mac_config.sh
mac_config two
KNOWN_HOSTS="$PWD/tests/mac/known_hosts"
stage=$(mktemp -d "${TMPDIR:-/tmp}/zb-ms65-orphan-XXXXXX")
trap 'case "$stage" in "${TMPDIR:-/tmp}"/zb-ms65-orphan-??????) find "${stage:?}" -delete;; esac' EXIT
SHA=$(git rev-parse --verify "${1:-HEAD}^{commit}")
echo "== commit $SHA" >&2
FILES=(tests/mac/ms6_5_orphan_gate.sh tests/mac/mac_gate_output.sh tests/mac/mac_config.sh
       agent/host/zb_agent_host/__init__.py agent/host/zb_agent_host/files.py
       agent/host/zb_agent_host/launch.py agent/host/zb_agent_host/options.py
       agent/host/zb_agent_host/parent_watch.py agent/host/zb_agent_host/platforms.py
       agent/host/zb_agent_host/relay.py agent/host/zb_agent_host/sandbox.py
       agent/host/zb_agent_host/sandbox_macos.py agent/host/zb_agent_host/seatbelt_rules.py
       agent/host/zb_agent_host/seccomp.py)
git archive "$SHA" -- "${FILES[@]}" | tar -x -C "$stage"

leg() { # $1=host $2=expected uname -m $3=key
  local host="$1" arch="$2" key="$3"
  local SSH=(env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY -u SSH_ASKPASS ssh -F none -i "$key"
             -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes
             -o UserKnownHostsFile="$KNOWN_HOSTS" -o ConnectTimeout=15 -o ServerAliveInterval=10)
  local rdir="zb-ms65-orphan-$(date +%s)-$$-$RANDOM"
  tar -C "${stage:?}" -cf - . | "${SSH[@]}" "$host" \
    "mkdir \"\$HOME/${rdir:?}\" && tar -xf - -C \"\$HOME/${rdir}\"" \
    || { "${SSH[@]}" "$host" "d=\"\$HOME/${rdir:?}\"; [ -d \"\$d\" ] && find \"\$d\" -delete" || true
         echo "FAIL: staging on $host" >&2; return 1; }

  local out rc=0
  out=$(timeout "$LEG_TIMEOUT" "${SSH[@]}" "$host" "ZB_RDIR='${rdir}' ZB_ARCH='${arch}' /bin/bash -s" <<'REMOTE'
set -euo pipefail
d="$HOME/${ZB_RDIR:?}"
case "$ZB_RDIR" in zb-ms65-orphan-*) ;; *) echo "FAIL: bad run dir $ZB_RDIR" >&2; exit 1;; esac
browser_pid=""
launch_pid=""
launch_unique=""
orphan_pid=""
orphan_unique=""
unrelated_pid=""
unrelated_unique=""

unique_id() { # $1=pid; prints p_uniqueid only when the same live process can be identified
  /usr/bin/python3 -I - "$1" <<'PY'
import ctypes
import sys

class UniqueInfo(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_ubyte * 16), ("uniqueid", ctypes.c_uint64),
                ("parent_uniqueid", ctypes.c_uint64), ("idversion", ctypes.c_int32),
                ("reserved2", ctypes.c_uint32), ("reserved3", ctypes.c_uint64),
                ("reserved4", ctypes.c_uint64)]

pid = int(sys.argv[1])
if pid <= 1:
    raise SystemExit(1)
lib = ctypes.CDLL(None)
lib.proc_pidinfo.argtypes = (ctypes.c_int, ctypes.c_int, ctypes.c_uint64,
                             ctypes.c_void_p, ctypes.c_int)
lib.proc_pidinfo.restype = ctypes.c_int
info = UniqueInfo()
if lib.proc_pidinfo(pid, 17, 0, ctypes.byref(info), ctypes.sizeof(info)) != ctypes.sizeof(info):
    raise SystemExit(1)
print(info.uniqueid)
PY
}

same_identity() { # $1=pid $2=p_uniqueid
  local current
  current=$(unique_id "$1" 2>/dev/null) || return 1
  [ "$current" = "$2" ]
}

kill_pid_if_owned() { # $1=pid $2=p_uniqueid
  local pid="$1" unique="$2"
  [[ "$pid" =~ ^[2-9][0-9]*$ ]] || return 0
  [ -n "$unique" ] || return 0
  same_identity "$pid" "$unique" || return 0
  kill -KILL "$pid" 2>/dev/null || true
}

cleanup() {
  set +e
  if [[ "$browser_pid" =~ ^[2-9][0-9]*$ ]]; then
    kill -KILL "$browser_pid" 2>/dev/null || true
    wait "$browser_pid" 2>/dev/null || true
  fi
  if [[ "$launch_pid" =~ ^[2-9][0-9]*$ ]] && [ -n "$launch_unique" ] \
      && same_identity "$launch_pid" "$launch_unique"; then
    pgid=$(/bin/ps -o pgid= -p "$launch_pid" 2>/dev/null | tr -d ' ') || pgid=""
    if [ "$pgid" = "$launch_pid" ]; then
      /usr/bin/python3 -I - "$launch_pid" <<'PY' 2>/dev/null || true
import os
import signal
import sys
os.killpg(int(sys.argv[1]), signal.SIGKILL)
PY
    fi
  fi
  kill_pid_if_owned "$orphan_pid" "$orphan_unique"
  kill_pid_if_owned "$unrelated_pid" "$unrelated_unique"
  if [[ "$unrelated_pid" =~ ^[2-9][0-9]*$ ]]; then wait "$unrelated_pid" 2>/dev/null || true; fi
  cd /
  case "$ZB_RDIR" in zb-ms65-orphan-*) find "$HOME/${ZB_RDIR:?}" -delete;; esac
}
trap cleanup EXIT

[ "$(uname -m)" = "$ZB_ARCH" ] || { echo "FAIL: this leg is $(uname -m), expected $ZB_ARCH" >&2; exit 1; }
cd "$d"
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
import ctypes
import os
import time

class UniqueInfo(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_ubyte * 16), ("uniqueid", ctypes.c_uint64),
                ("parent_uniqueid", ctypes.c_uint64), ("idversion", ctypes.c_int32),
                ("reserved2", ctypes.c_uint32), ("reserved3", ctypes.c_uint64),
                ("reserved4", ctypes.c_uint64)]

def unique_id():
    lib = ctypes.CDLL(None)
    info = UniqueInfo()
    size = ctypes.sizeof(info)
    if lib.proc_pidinfo(os.getpid(), 17, 0, ctypes.byref(info), size) != size:
        raise SystemExit("proc_pidinfo unique-id lookup failed")
    return info.uniqueid

ready = os.path.join(os.environ["HOME"], "scratchpad", "orphan-identity")
intermediate = os.fork()
if intermediate == 0:
    os.setsid()
    if os.fork() == 0:
        tmp = ready + ".tmp"
        with open(tmp, "w", encoding="ascii") as stream:
            stream.write(f"{os.getpid()} {unique_id()} {os.getpgid(0)}\n")
        os.replace(tmp, ready)
        time.sleep(30)
        os._exit(0)
    os._exit(0)
os.waitpid(intermediate, 0)
time.sleep(30)
PY
chmod 700 "$fake_python"

cat > "$d/launch_driver.py" <<'PY'
import sys
import types

host, home, python = sys.argv[1:]
sys.path.insert(0, host)
from zb_agent_host import launch, sandbox_macos

session = launch.Session(home=home, python=python, net_dir=None, command="chat", egress_port=54321)
args = types.SimpleNamespace(e2e_claude_cli=None, test_ca=None)
raise SystemExit(launch._launch_darwin(session, args, sandbox_macos.MacSeatbeltBackend(54321)))
PY

cat > "$d/browser_parent.py" <<'PY'
import ctypes
import os
import subprocess
import sys
import time

class UniqueInfo(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_ubyte * 16), ("uniqueid", ctypes.c_uint64),
                ("parent_uniqueid", ctypes.c_uint64), ("idversion", ctypes.c_int32),
                ("reserved2", ctypes.c_uint32), ("reserved3", ctypes.c_uint64),
                ("reserved4", ctypes.c_uint64)]

def unique_id(pid):
    lib = ctypes.CDLL(None)
    info = UniqueInfo()
    size = ctypes.sizeof(info)
    if lib.proc_pidinfo(pid, 17, 0, ctypes.byref(info), size) != size:
        raise SystemExit("launch unique-id lookup failed")
    return info.uniqueid

driver, host, home, python, launch_file = sys.argv[1:]
proc = subprocess.Popen([sys.executable, "-I", driver, host, home, python],
                        stdin=subprocess.DEVNULL, start_new_session=True)
with open(launch_file + ".tmp", "w", encoding="ascii") as stream:
    stream.write(f"{proc.pid} {unique_id(proc.pid)}\n")
os.replace(launch_file + ".tmp", launch_file)
ready = os.path.join(home, "scratchpad", "orphan-identity")
deadline = time.monotonic() + 15
while time.monotonic() < deadline:
    if os.path.isfile(ready) and os.path.getsize(ready) > 0:
        raise SystemExit(0)  # the browser quits normally; it is never a cleanup target
    if proc.poll() is not None:
        raise SystemExit(f"launch exited before the orphan detached: {proc.returncode}")
    time.sleep(0.05)
os.killpg(proc.pid, 9)
proc.wait()
raise SystemExit("timed out waiting for the sandboxed orphan")
PY

/bin/sleep 30 &
unrelated_pid=$!
unrelated_unique=$(unique_id "$unrelated_pid")

/usr/bin/python3 -I "$d/browser_parent.py" "$d/launch_driver.py" "$host" "$home" "$fake_python" \
  "$d/launch-identity" >"$d/browser.out" 2>"$d/browser.err" &
browser_pid=$!
if ! wait "$browser_pid"; then
  cat "$d/browser.err" >&2
  echo "FAIL ms6-5-orphan $ZB_ARCH browser did not quit normally"
  exit 1
fi
browser_pid=""
read launch_pid launch_unique < "$d/launch-identity"
read orphan_pid orphan_unique orphan_pgid < "$home/scratchpad/orphan-identity"
for pid in "$launch_pid" "$orphan_pid" "$orphan_pgid"; do
  [[ "$pid" =~ ^[2-9][0-9]*$ ]] || { echo "FAIL ms6-5-orphan $ZB_ARCH invalid recorded pid: $pid"; exit 1; }
done
[ "$orphan_pgid" != "$launch_pid" ] || { echo "FAIL ms6-5-orphan $ZB_ARCH orphan did not escape launch group"; exit 1; }

for _ in {1..100}; do
  same_identity "$orphan_pid" "$orphan_unique" || break
  sleep 0.05
done
if same_identity "$orphan_pid" "$orphan_unique"; then
  echo "FAIL ms6-5-orphan $ZB_ARCH setsid-double-fork survived browser quit"
  exit 1
fi
if ! same_identity "$unrelated_pid" "$unrelated_unique"; then
  echo "FAIL ms6-5-orphan $ZB_ARCH unrelated process was killed"
  exit 1
fi

echo "PASS ms6-5-orphan $ZB_ARCH detached agent gone; browser-normal; unrelated-alive"
REMOTE
  ) || rc=$?
  printf '%s\n' "$out" >&2
  [ "$rc" -eq 0 ] || { echo "FAIL: ms6-5-orphan $arch leg on $host timed out/failed" >&2; return 1; }
  mac_require_lines ms6_5_orphan_gate "$host" "$arch" "$out" \
    "PASS ms6-5-orphan $arch detached agent gone; browser-normal; unrelated-alive" || return 1
}

overall=0
leg "$INTEL_HOST" x86_64 "$KEY" || { echo "FAIL: x86_64 leg" >&2; overall=1; }
leg "$ARM_HOST" arm64 "$ARM_KEY" || { echo "FAIL: arm64 leg" >&2; overall=1; }
[ "$overall" -eq 0 ] && printf 'PASS\tms6-5-orphan-gate\tboth-arches\n'
exit "$overall"
