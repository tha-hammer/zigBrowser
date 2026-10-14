"""Shared pieces for the helper's unit and contract tests (P0).

The helper is always started the way the app will start it: from an explicit,
allowlisted environment (never this process's own), with the token written to
its fd 3 and closed. HOME points at a decoy user home, so a helper that failed
to replace HOME would load the decoy's CLAUDE.md, settings and hooks.
"""

import json
import os
import secrets
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

HOST_DIR = Path(__file__).resolve().parents[1]
REPO = HOST_DIR.parents[1]
sys.path.insert(0, str(REPO / "tests" / "e2e"))
sys.path.insert(0, str(HOST_DIR))

from fake_anthropic_api import FakeAnthropicApi  # noqa: E402

DECOY_MARKER = "ZB-DECOY-USER-MARKER"
# Not under /tmp or /run: hooks and the sandbox get private mounts there.
TEST_TMP = Path(os.environ.get("ZB_AGENT_TEST_TMP") or REPO / "tests" / "e2e" / ".tmp" / "agent-host")


def host_python():
    """The helper venv's python; fails closed (never skips) when it is missing."""
    path = os.environ.get("ZB_AGENT_HOST_PYTHON")
    if not path:
        raise SystemExit("ZB_AGENT_HOST_PYTHON is not set: run tools/agent_host_env.sh")
    if not os.access(path, os.X_OK):
        raise SystemExit(f"helper python missing at {path}: run tools/agent_host_env.sh")
    return path


def canary():
    return "sk-ant-oat01-ZBCANARY-" + secrets.token_hex(24)


class Homes:
    """A temp agent home (with its own SAI marker) and a decoy user home."""

    def __init__(self):
        TEST_TMP.mkdir(parents=True, exist_ok=True)
        self.root = Path(tempfile.mkdtemp(prefix="zb-p0-", dir=TEST_TMP))
        self.agent = self.root / "agent-home"
        self.decoy = self.root / "decoy-home"
        self.marker = "ZB-AGENT-SAI-MARKER-" + secrets.token_hex(8)
        for d in ("workspace", "scratchpad/tmp", "runtime/bin", ".claude"):
            (self.agent / d).mkdir(parents=True, exist_ok=True)
        os.chmod(self.agent, 0o700)
        (self.agent / ".claude" / "CLAUDE.md").write_text(f"{self.marker}\n")
        (self.decoy / ".claude" / "hooks").mkdir(parents=True)
        (self.decoy / ".claude" / "CLAUDE.md").write_text(f"{DECOY_MARKER}\n")
        (self.decoy / ".claude" / "settings.json").write_text(json.dumps({
            "hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": f"touch {self.decoy}/decoy-hook-ran"}]}]}
        }))

    @property
    def scratchpad(self):
        return self.agent / "scratchpad"

    @property
    def workspace(self):
        return self.agent / "workspace"

    def write_settings(self, settings):
        (self.agent / ".claude" / "settings.json").write_text(json.dumps(settings, indent=2))

    def read_settings(self):
        return json.loads((self.agent / ".claude" / "settings.json").read_text())

    def cleanup(self):
        for dirpath, dirs, _files in os.walk(self.root):
            for name in dirs:
                try:
                    os.chmod(os.path.join(dirpath, name), 0o700)
                except OSError:
                    pass
        shutil.rmtree(self.root, ignore_errors=True)


def launch_env(homes, extra=None):
    """The explicit environment the app gives the helper (D7), with HOME at the decoy."""
    env = {
        "PATH": "/usr/bin:/bin",
        "HOME": str(homes.decoy),
        "LANG": "C.UTF-8",
        "PYTHONPATH": str(HOST_DIR),
        "PYTHONDONTWRITEBYTECODE": "1",
    }
    env.update(extra or {})
    return env


class Helper:
    """One `python -m zb_agent_host <command>` run: token on fd 3, NDJSON on stdout."""

    def __init__(self, homes, command, args, token, env_extra=None, argv_prefix=None, pass_token=True, pass_fds=()):
        self.frames = []
        self.stderr_lines = []
        self._stdout_done = False
        self._cond = threading.Condition()
        rfd, wfd = os.pipe()
        os.set_inheritable(rfd, True)
        argv = list(argv_prefix or []) + [host_python(), "-m", "zb_agent_host", command, *args]

        def to_fd3():
            # Runs before close_fds, so fd 3 is listed in pass_fds below.
            if rfd != 3:
                os.dup2(rfd, 3)
                os.close(rfd)

        self.proc = subprocess.Popen(
            argv, env=launch_env(homes, env_extra), cwd=str(homes.root),
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            pass_fds=(3, *pass_fds), preexec_fn=to_fd3, text=True, start_new_session=True)
        os.close(rfd)
        if pass_token:
            os.write(wfd, token.encode())
        os.close(wfd)
        threading.Thread(target=self._read_stdout, daemon=True).start()
        threading.Thread(target=self._read_stderr, daemon=True).start()

    def _read_stdout(self):
        for line in self.proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                frame = json.loads(line)
            except ValueError:
                frame = {"type": "unparsed", "line": line}
            with self._cond:
                self.frames.append(frame)
                self._cond.notify_all()
        with self._cond:
            self._stdout_done = True
            self._cond.notify_all()

    def _read_stderr(self):
        for line in self.proc.stderr:
            self.stderr_lines.append(line.rstrip("\n"))

    def send(self, frame):
        self.proc.stdin.write(json.dumps(frame) + "\n")
        self.proc.stdin.flush()

    def wait_frame(self, predicate, timeout):
        deadline = time.monotonic() + timeout
        with self._cond:
            while True:
                for frame in self.frames:
                    if predicate(frame):
                        return frame
                left = deadline - time.monotonic()
                if left <= 0 or self._stdout_done:
                    return None
                self._cond.wait(min(left, 0.2))

    def finish(self, timeout=60):
        try:
            self.proc.stdin.close()
        except OSError:
            pass
        try:
            self.proc.wait(timeout)
        except subprocess.TimeoutExpired:
            os.killpg(self.proc.pid, 9)
            self.proc.wait()
        time.sleep(0.1)
        self._close_pipes()
        return self.proc.returncode

    def _close_pipes(self):
        for stream in (self.proc.stdout, self.proc.stderr):
            try:
                stream.close()
            except (OSError, ValueError):
                pass

    def kill(self):
        if self.proc.poll() is None:
            os.killpg(self.proc.pid, 9)
            self.proc.wait()
        self._close_pipes()

    def describe(self):
        return f"rc={self.proc.returncode} frames={self.frames[-6:]} stderr={self.stderr_lines[-12:]}"


HOOK_EVENTS = ("SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd")
TOOL_EVENTS = ("PreToolUse", "PostToolUse")

# A fixture SAI hook: dumps its own environment, the PIDs it can see, and the
# environment of every visible process that is PID 1, itself, or a process of
# this agent home (so the CLI and the helper are caught when visible, and
# nothing else on the host is copied), then POSTs its event to the notify server.
DUMP_HOOK = r"""#!/bin/sh
ev=$1
port=$2
probe=$3
out="$HOME/scratchpad"
cat >/dev/null
cat /proc/self/environ > "$out/hook-env-$ev-$$"
ls /proc | grep -E '^[0-9]+$' | tr '\n' ' ' > "$out/hook-pids-$ev-$$"
for f in /proc/[0-9]*/environ; do
  n=${f#/proc/}; n=${n%/environ}
  if [ "$n" = 1 ] || [ "$n" = "$$" ] || grep -q -a -F "$HOME" "$f" 2>/dev/null; then
    cat "$f" > "$out/hook-procenv-$ev-$$-$n" 2>/dev/null || rm -f "$out/hook-procenv-$ev-$$-$n"
  fi
done
ls -l /proc/self/fd/ > "$out/hook-fds-$ev-$$" 2>&1
for f in /proc/[0-9]*/cmdline; do tr '\0' ' ' < "$f" 2>/dev/null; echo; done > "$out/hook-cmdlines-$ev-$$"
touch "$HOME/workspace/hook-wrote-$ev" > "$out/hook-ws-$ev-$$" 2>&1
/usr/bin/python3 -I "$probe" > "$out/hook-sys-$ev-$$" 2>&1
curl -s -m 5 -X POST -H 'content-type: application/json' -d "{\"event\":\"$ev\"}" "http://127.0.0.1:$port/notify" >/dev/null
exit 0
"""


class NotifyServer:
    """The stand-in for the localhost voice notify server (:51091): records each POST body."""

    def __init__(self):
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
        events = self.events = []

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                body = self.rfile.read(int(self.headers.get("content-length") or 0))
                try:
                    events.append(json.loads(body).get("event"))
                except ValueError:
                    events.append(None)
                self.send_response(200)
                self.send_header("content-length", "0")
                self.end_headers()

        self._server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self._server.serve_forever, daemon=True).start()
        self.port = self._server.server_address[1]

    def close(self):
        self._server.shutdown()
        self._server.server_close()


def install_dump_hooks(homes, port):
    """Registers the dump hook for all six events, as raw commands (provisioning wraps them)."""
    hook = homes.agent / ".claude" / "hooks" / "dump.sh"
    hook.parent.mkdir(parents=True, exist_ok=True)
    hook.write_text(DUMP_HOOK)
    os.chmod(hook, 0o755)
    # The probe ships beside the hook, inside the agent home: a hook sees the agent
    # home, but not a checkout under /tmp (its /tmp is private).
    probe = hook.parent / "probe.py"
    shutil.copyfile(HOST_DIR / "zb_agent_host" / "probe.py", probe)
    hooks = {}
    for ev in HOOK_EVENTS:
        entry = {"hooks": [{"type": "command", "command": f"{hook} {ev} {port} {probe}"}]}
        if ev in TOOL_EVENTS:
            entry["matcher"] = "*"
        hooks[ev] = [entry]
    homes.write_settings({"hooks": hooks})


class Inotify:
    """Records every write-like event under a tree (the write census oracle), recursively."""

    IN_MODIFY, IN_ATTRIB, IN_CLOSE_WRITE, IN_MOVED_FROM, IN_MOVED_TO = 0x2, 0x4, 0x8, 0x40, 0x80
    IN_CREATE, IN_DELETE, IN_ISDIR = 0x100, 0x200, 0x40000000
    MASK = IN_MODIFY | IN_ATTRIB | IN_CLOSE_WRITE | IN_MOVED_FROM | IN_MOVED_TO | IN_CREATE | IN_DELETE

    IN_ACCESS, IN_OPEN = 0x1, 0x20

    def __init__(self, root, extra_mask=0):
        import ctypes
        import struct
        self._struct = struct
        self._libc = ctypes.CDLL("libc.so.6", use_errno=True)
        self.root = str(root)
        self.mask = self.MASK | extra_mask
        self.fd = self._libc.inotify_init1(0o2000000 | 0o4000)  # IN_CLOEXEC | IN_NONBLOCK
        if self.fd < 0:
            raise OSError(ctypes.get_errno(), "inotify_init1")
        self.watches = {}
        self.paths = set()
        self._stop = False
        for dirpath, _dirs, _files in os.walk(self.root):
            self._watch(dirpath)
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def _watch(self, path):
        wd = self._libc.inotify_add_watch(self.fd, path.encode(), self.mask)
        if wd >= 0:
            self.watches[wd] = path

    def _run(self):
        import select
        while not self._stop:
            ready, _w, _x = select.select([self.fd], [], [], 0.1)
            if not ready:
                continue
            try:
                data = os.read(self.fd, 65536)
            except BlockingIOError:
                continue
            offset = 0
            while offset < len(data):
                wd, mask, _cookie, length = self._struct.unpack_from("iIII", data, offset)
                name = data[offset + 16:offset + 16 + length].split(b"\0", 1)[0].decode()
                offset += 16 + length
                base = self.watches.get(wd)
                if base is None:
                    continue
                path = os.path.join(base, name) if name else base
                self.paths.add(os.path.relpath(path, self.root))
                if mask & self.IN_CREATE and mask & self.IN_ISDIR:
                    for dirpath, _dirs, _files in os.walk(path):
                        self._watch(dirpath)

    def close(self):
        time.sleep(0.3)
        self._stop = True
        self._thread.join()
        os.close(self.fd)
        return self.paths


def provision(homes):
    """Runs the helper's runtime provisioning (wrappers, hook rewrite) on the agent home."""
    proc = subprocess.run([host_python(), "-m", "zb_agent_host", "provision-runtime", "--home", str(homes.agent)],
                          env=launch_env(homes), capture_output=True, text=True, timeout=60)
    return proc.returncode, proc.stdout + proc.stderr


def processes_holding(needle):
    """PIDs whose environment contains `needle`, with their argv[0]."""
    hits = []
    data = needle.encode()
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            with open(f"/proc/{entry}/environ", "rb") as f:
                env = f.read()
            if data not in env:
                continue
            with open(f"/proc/{entry}/cmdline", "rb") as f:
                cmd = f.read().split(b"\0")
        except OSError:
            continue
        hits.append((int(entry), [c.decode("utf-8", "replace") for c in cmd if c]))
    return hits


def files_containing(root, needle):
    data = needle.encode()
    hits = []
    for dirpath, _dirs, files in os.walk(root):
        for name in files:
            path = os.path.join(dirpath, name)
            try:
                if os.path.islink(path) or not os.path.isfile(path):
                    continue
                with open(path, "rb") as f:
                    if data in f.read():
                        hits.append(path)
            except OSError:
                continue
    return hits
