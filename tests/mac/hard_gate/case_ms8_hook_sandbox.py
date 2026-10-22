"""zb-hook-run's Darwin branch on a Mac (design 7929; RoseCat 7938/7951/7958), under the STAGED pinned runtime: the
real setup.provision (route off) builds a home under the real path of the scratch (runtime/hook.sb,
runtime/bin/zb-hook-run), and the REAL zb-hook-run runs a stand-in hook under sandbox-exec with that profile:
- a tiny launcher puts a 0400 run.marker on fd 5 and leaves one unrelated descriptor open (not close-on-exec), then
  execs zb-hook-run with ZB_AGENT_RUN_MARKER_FD=5 and planted token / proxy / API names in its environment;
- the stand-in hook (the staged python, writing only into the scratchpad) dumps its environment, connects to both
  bridge ports of runtime/net.json (listeners this case holds), to an "API" listener on a port the profile does not
  name, and to a public address; it reports fd 5 and the unrelated descriptor, then double-forks + setsid; the
  detached grandchild re-checks fd 5, writes its own report and exits by itself.
Checks: the staged host and interpreter; setup provisions the home with runtime/hook.sb; both bridge listeners are
free and both bridges are reached (each listener received this run's nonce); the API listener and the public address
are not (no accept, the hook saw a failure); the hook's environment is exactly the hook-env.json allowlist's values
(no planted name or value, no ZB_AGENT_RUN_MARKER_FD); fd 5 is the marker (a regular file) in the hook and in the
detached grandchild, and the unrelated descriptor is closed; zb-hook-run exits 0; and a fail-closed ps census finds
no process naming this run's nonce within the horizon (never signalled: every process here ends by itself).
Kill safety: this case makes no direct signal call; its runs go through the guarded h.spawn_group. It reads no
other case file. Linux proof with fakes: tests/e2e/ms8_hook_sandbox_case_test.py. PENDING its kill-safety review
(tests/mac/hard_gate_pending/): on approval it moves into tests/mac/hard_gate/ with its MANIFEST.json entry."""
import contextlib
import io
import json
import os
import secrets
import socket
import sys
import threading
import time

NAME = "ms8-hook-sandbox"
PLANTED = {"CLAUDE_CODE_OAUTH_TOKEN": "zb-ms8-planted-token", "ANTHROPIC_API_KEY": "zb-ms8-planted-key",
           "HTTPS_PROXY": "http://127.0.0.1:9", "ZB_TOKEN_FIFO": "/nonexistent/fifo"}
PUBLIC = ("1.1.1.1", 443)
HORIZON_S = 20.0

LAUNCH = r"""
import os, sys
marker, stray_path = sys.argv[1], sys.argv[2]
fd = os.open(marker, os.O_RDONLY)
if fd != 5:
    os.dup2(fd, 5)
    os.close(fd)
os.set_inheritable(5, True)  # also when the open itself returned 5 (PEP 446: not inheritable; RoseCat 7969 #2)
stray = os.open(stray_path, os.O_RDONLY)
os.set_inheritable(stray, True)
argv = [str(stray) if a == "{STRAY}" else a for a in sys.argv[3:]]
os.execv(argv[0], argv)
"""

HOOK = r"""
import json, os, socket, stat, sys, time
out, nonce = sys.argv[1], sys.argv[5]
b1, b2, api, stray = int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[6])
def reach(host, port):
    try:
        s = socket.create_connection((host, port), timeout=5)
    except OSError as e:
        return "err:%s" % e.errno
    try:
        s.sendall(nonce.encode())
    finally:
        s.close()
    return "ok"
def kind(fd):
    try:
        return "reg" if stat.S_ISREG(os.fstat(fd).st_mode) else "other"
    except OSError:
        return "closed"
report = {"env": dict(os.environ), "bridge1": reach("127.0.0.1", b1), "bridge2": reach("127.0.0.1", b2),
          "api": reach("127.0.0.1", api), "public": reach(PUBLIC_HOST, PUBLIC_PORT), "fd5": kind(5),
          "stray": kind(stray), "sid": os.getsid(0)}
pid = os.fork()
if pid == 0:
    os.setsid()
    if os.fork() == 0:
        time.sleep(1.0)
        with open(os.path.join(out, "grandchild-" + nonce + ".json"), "w") as f:
            json.dump({"fd5": kind(5), "sid": os.getsid(0), "pgid": os.getpgid(0)}, f)
        os._exit(0)
    os._exit(0)
os.waitpid(pid, 0)
with open(os.path.join(out, "hook-" + nonce + ".json"), "w") as f:
    json.dump(report, f)
""".replace("PUBLIC_HOST", repr(PUBLIC[0])).replace("PUBLIC_PORT", str(PUBLIC[1]))


class _Listener:
    """A 127.0.0.1 listener that records every byte string an accepted connection sends."""

    def __init__(self, port):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("127.0.0.1", port))
        self.sock.listen(8)
        self.sock.settimeout(0.2)
        self.port = self.sock.getsockname()[1]
        self.got, self._stop = [], threading.Event()
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()

    def _serve(self):
        while not self._stop.is_set():
            try:
                conn, _ = self.sock.accept()
            except OSError:
                continue
            with conn:
                conn.settimeout(2)
                try:
                    self.got.append(conn.recv(64))
                except OSError:
                    self.got.append(b"")

    def close(self):
        self._stop.set()
        self._thread.join(2)
        self.sock.close()


def _read_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def _census(h, nonce):
    """(inspected, pids naming `nonce`) from one guarded ps run; a failed or unparsable ps is not inspected."""
    code, out, _err = h.spawn_group(["/bin/ps", "-axo", "pid=,command="], env={"PATH": "/usr/bin:/bin"}, timeout=10)
    if code != 0:
        return False, []
    pids = []
    for line in out.decode("utf-8", "replace").splitlines():
        fields = line.strip().split(None, 1)
        if not fields or not fields[0].isdigit():
            return False, []
        if len(fields) == 2 and nonce in fields[1] and "/bin/ps" not in fields[1]:
            pids.append(int(fields[0]))
    return True, pids


def run(h):
    prefix = h.prefix
    if not h.check(bool(prefix) and os.path.isdir(os.path.join(prefix or "", "zb_agent_host")),
                   f"the staged agent-host is present (ZB_HG_PREFIX={prefix!r})"):
        return
    if not h.check(bool(h.python) and os.path.realpath(sys.executable) == os.path.realpath(h.python),
                   f"this case runs under the staged interpreter ({sys.executable} vs {h.python})"):
        return
    sys.path.insert(0, prefix)
    from zb_agent_host import options, setup  # the staged tree's own modules

    scratch = os.path.realpath(h.scratch)
    source_home = os.path.join(scratch, "user")
    source = os.path.join(source_home, ".claude")
    os.makedirs(source, 0o700)
    with open(os.path.join(source, "settings.json"), "w") as f:
        f.write("{}\n")
    home = options.AgentHome(os.path.join(scratch, "data", "zigbrowser", "agent-home"))
    err = io.StringIO()
    try:
        with contextlib.redirect_stderr(err):
            setup.provision(home=home, source=source, source_home=source_home, source_path="/usr/bin:/bin",
                            python=h.python, select_token_route=False, cli=h.cli)
        made = None
    except Exception as exc:  # noqa: BLE001 - the check's evidence
        made = repr(exc)
    root = str(home.root)
    runtime = os.path.join(root, "runtime")
    if not h.check(made is None and os.path.isfile(os.path.join(runtime, "hook.sb")),
                   f"setup provisions the home with runtime/hook.sb ({made or 'ok'}; {err.getvalue()[-200:]!r})"):
        return
    with open(os.path.join(runtime, "net.json")) as f:
        b1, b2 = json.load(f)["ports"]
    with open(os.path.join(runtime, "hook-env.json")) as f:
        allowed = json.load(f)

    listeners = []
    try:
        try:
            for port in (b1, b2, 0):
                listeners.append(_Listener(port))  # each one owned by the finally as soon as it exists (7969 #5)
        except OSError as exc:
            h.check(False, f"the bridge ports {b1} and {b2} are free for this case's listeners ({exc!r})")
            return
        bridge1, bridge2, api = listeners
        nonce = secrets.token_hex(8)
        scratchpad = os.path.join(root, "scratchpad")
        marker = os.path.join(scratch, "run.marker")
        with open(marker, "w"):
            pass
        os.chmod(marker, 0o400)
        stray_path = os.path.join(scratch, "stray")
        with open(stray_path, "w") as f:
            f.write("stray\n")
        hook = os.path.join(scratch, "hook.py")
        with open(hook, "w") as f:
            f.write(HOOK)
        env = {"PATH": "/usr/bin:/bin", "HOME": root, "TMPDIR": os.path.join(scratchpad, "tmp"), "LANG": "C.UTF-8",
               "ZB_AGENT_RUN_MARKER_FD": "5", **PLANTED}
        expected_env = {k: v for k, v in env.items() if k in allowed}
        argv = [h.python, "-I", "-S", "-c", LAUNCH, marker, stray_path,
                h.python, "-I", os.path.join(runtime, "bin", "zb-hook-run"), "--",
                h.python, "-I", "-S", hook, scratchpad, str(b1), str(b2), str(api.port), nonce, "{STRAY}"]
        code, out, errb = h.spawn_group(argv, env=env, timeout=60)
        h.check(code == 0, f"zb-hook-run runs the hook under sandbox-exec and exits 0 (rc={code}; "
                           f"stderr tail {errb[-300:]!r})")
        report = _read_json(os.path.join(scratchpad, f"hook-{nonce}.json")) or {}
        h.check(report.get("bridge1") == "ok" and report.get("bridge2") == "ok"
                and nonce.encode() in bridge1.got and nonce.encode() in bridge2.got,
                f"both bridges are reached ({report.get('bridge1')}, {report.get('bridge2')})")
        # Seatbelt denies an outbound connect the profile does not name with EPERM (MS6.4); a timeout or an
        # unreachable network is not that proof (RoseCat 7969 #3).
        h.check(report.get("api") == "err:1" and api.got == [],
                f"Seatbelt denies the API port the profile does not name ({report.get('api')}, {len(api.got)} accepts)")
        h.check(report.get("public") == "err:1", f"Seatbelt denies a public address ({report.get('public')})")
        seen = report.get("env")
        h.check(isinstance(seen, dict) and not set(seen) & {*PLANTED, "ZB_AGENT_RUN_MARKER_FD"}
                and not any(v in json.dumps(seen) for v in PLANTED.values()),
                "no planted name or value and no ZB_AGENT_RUN_MARKER_FD reaches the hook's environment")
        h.check(seen == expected_env, f"the hook's environment is exactly the allowlisted values "
                                      f"(extra {sorted(set(seen or {}) - set(expected_env))})")
        h.check(report.get("fd5") == "reg" and report.get("stray") == "closed",
                f"the hook holds the run marker on fd 5 and not the unrelated descriptor "
                f"({report.get('fd5')}, {report.get('stray')})")
        deadline = time.monotonic() + HORIZON_S
        grandchild = None
        while grandchild is None and time.monotonic() < deadline:
            grandchild = _read_json(os.path.join(scratchpad, f"grandchild-{nonce}.json"))
            if grandchild is None:
                time.sleep(0.2)
        gc = grandchild or {}
        h.check(gc.get("fd5") == "reg" and isinstance(gc.get("sid"), int) and gc.get("sid") != report.get("sid")
                and gc.get("sid") == gc.get("pgid"),
                f"the detached grandchild, in a session other than the hook's, still holds the run marker on fd 5 "
                f"({grandchild}; hook sid {report.get('sid')})")
        faults, last, deadline = 0, None, time.monotonic() + HORIZON_S  # its own horizon, at least one scan
        while True:
            inspected, pids = _census(h, nonce)
            faults += 0 if inspected else 1
            last = (inspected, pids)
            if (inspected and not pids) or time.monotonic() >= deadline:
                break
            time.sleep(0.5)
        h.check(faults == 0 and last == (True, []),
                f"no process of this run is left (faults={faults}, last={last})")
    finally:
        for listener in listeners:
            listener.close()
