#!/usr/bin/env python3
"""Chat drawer S3b (plan S3.2, S3.3, S3.4, S3.6, S3.12 and Closure Test S3; rev 16 §3c):
the first Send starts a confined helper, its frames are validated natively, and every
exit path cleans it up.

Each case drives the real browser on its own Xvfb, with an agent home made by the real
`--agent-setup` and a canary token in the explicit file store. With --e2e-protocol the
CLI reaches the TLS fake Messages API only through the outer relay and netd
(ZIGBROWSER_AGENT_NET_TEST allows fake.zb.invalid, ZIGBROWSER_AGENT_NET_TEST_CA names its
CA, ZIGBROWSER_AGENT_TEST_BASE_URL=https://fake.zb.invalid).

The whole run happens inside a disposable network namespace of its own (`bwrap
--unshare-net`, re-exec'd as --sealed-child): there is no route out, so no case, with or
without --e2e-protocol, can reach the real api.anthropic.com, the real voice server or
the LAN. Exit 1 when Xvfb, xauth, bwrap, the venv or the binary is missing."""

from __future__ import annotations

import ctypes
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(HERE))

CANARY = "sk-ant-oat01-ZBCANARY-lifecycle-0123456789abcdef"
REPLY = "Hello from the agent"
# The helper's environment, written out independently of options.HELPER_ENV_NAMES. The
# browser is always started with LANG and LC_ALL (env_for), so both are expected
# (RoseCat 5686: an inherited LC_ALL made the old set environment-dependent).
HELPER_ENV = {"PATH", "LANG", "LC_ALL", "HOME", "CLAUDE_CONFIG_DIR", "TMPDIR",
              "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "CLAUDE_AGENT_SDK_SKIP_VERSION_CHECK"}
FAKE_HOST_SCRIPT = REPO / "tests" / "fixtures" / "agent" / "fake_host.py"

# The fixture SAI's Stop hook, replaced: with <agent home>/scratchpad/sleepy-stop present it
# marks that it runs and sleeps 60 s (S3.4: a hook is running at the moment of the kill).
SLEEPY_STOP = """#!/usr/bin/python3
import os, sys, time
flag = os.path.join(os.environ.get("HOME", ""), "scratchpad", "sleepy-stop")
if sys.argv[1:2] == ["stop"] and os.path.exists(flag):
    open(flag + ".running", "w").close()
    time.sleep(60)
print("notify", sys.argv[1:])
"""

RUNTIME_DIRS: list[Path] = []
WORLDS: dict[str, object] = {}


# --- fixtures ----------------------------------------------------------------------------
def runtime_dir() -> Path:
    d = Path(tempfile.mkdtemp(prefix="zbl-", dir="/tmp"))
    os.chmod(d, 0o700)
    RUNTIME_DIRS.append(d)
    return d


def world(binary: Path, tmp: Path, name: str = "life", token: bool = True):
    """An agent home from the real --agent-setup, with the canary in the file store."""
    key = f"{name}:{token}"
    if key not in WORLDS:
        import agent_setup_test
        from agent_common import host_python
        agent_setup_test.PYTHON = host_python()
        w = agent_setup_test.World(tmp, name)
        (w.source / "hooks" / "notify.py").write_text(SLEEPY_STOP)
        rc, _out, err, _events, _seen = agent_setup_test.run_setup(binary, w)
        if rc != 0:
            raise AssertionError(f"--agent-setup failed: {err.strip()[-300:]}")
        if token:
            secrets = w.agent / "secrets"
            secrets.mkdir(mode=0o700, exist_ok=True)
            fd = os.open(secrets / "claude-token", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            os.write(fd, CANARY.encode())
            os.close(fd)
        WORLDS[key] = w
    return WORLDS[key]


class Fake:
    """The TLS fake Messages API at fake.zb.invalid, and the seams that reach it."""

    def __init__(self, tmp: Path, turns=None):
        from agent_hook_net import HookNetDecoys
        from fake_anthropic_api import FakeAnthropicApi, make_test_cert
        cert_dir = Path(tempfile.mkdtemp(prefix="cert-", dir=tmp))
        self.cert, key = make_test_cert(cert_dir)
        self.api = FakeAnthropicApi(turns=turns or [{"text": REPLY}] * 8, tls=(self.cert, key))
        self.api.start()
        self.decoys = HookNetDecoys()

    def seams(self) -> dict[str, str]:
        pairs = [f"--test-allow fake.zb.invalid={self.api.port}",
                 f"--test-bridge 51091={self.decoys.bridges[51091].port}",
                 f"--test-bridge 31337={self.decoys.bridges[31337].port}"]
        return {"ZIGBROWSER_AGENT_NET_TEST": " ".join(pairs), "ZIGBROWSER_AGENT_NET_TEST_CA": str(self.cert),
                "ZIGBROWSER_AGENT_TEST_BASE_URL": "https://fake.zb.invalid"}

    def close(self) -> None:
        self.api.stop()
        self.decoys.close()


def env_for(w, rt: Path | None, extra: dict[str, str] | None = None, hostile: bool = True) -> dict[str, str]:
    import agent_setup_test
    from agent_common import host_python
    from slice2_common import isolate_profile_env
    agent_setup_test.PYTHON = host_python()
    env = isolate_profile_env(dict(os.environ))
    env.pop("XDG_RUNTIME_DIR", None)
    for name in [n for n in env if n.startswith("ZIGBROWSER_AGENT_")]:
        env.pop(name)
    env.update(w.env())
    env.update({"LANG": "C.UTF-8", "LC_ALL": "C.UTF-8"})  # fixed, so the helper's environment is too
    if rt is not None:
        env["XDG_RUNTIME_DIR"] = str(rt)
    if hostile:  # S3.2: none of these may reach the helper
        env.update({"DBUS_SESSION_BUS_ADDRESS": "unix:path=/nonexistent/zb-bus", "SSH_AUTH_SOCK": "/nonexistent/zb-ssh",
                    "WEBKIT_DMABUF_RENDERER_FORCE_SHM": "1", "ZB_CANARY_ENV": "zb-canary-env"})
    env.update(extra or {})
    return env


def launch(binary: Path, tmp: Path, label: str, env: dict[str, str], e2e: bool = True):
    from agent_common import Browser
    return Browser(binary, tmp, label, ["--agent-drawer", "on", "--agent-secret-store", "file"], env=env, e2e=e2e)


def send(b, text: str, win: int = 1) -> None:
    from agent_common import centre
    if not b.rows("open", win):
        icon = b.wait_row("icon", win)
        b.x.click(*centre(tuple(int(v) for v in icon.fields[0].split(","))))
        b.wait_row("open", win, timeout=10)
    for ch in text:
        b.x.key({" ": "space"}.get(ch, ch), settle=0.005)
    b.x.key("Return")


# --- the process table ---------------------------------------------------------------------
def stat_fields(pid: int) -> list[str]:
    return Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()


def alive(pid: int) -> bool:
    try:
        return stat_fields(pid)[0] != "Z"
    except (OSError, IndexError):
        return False


def children_map() -> dict[int, list[int]]:
    out: dict[int, list[int]] = {}
    for entry in filter(str.isdigit, os.listdir("/proc")):
        try:
            out.setdefault(int(stat_fields(int(entry))[1]), []).append(int(entry))
        except (OSError, IndexError, ValueError):
            continue
    return out


def descendants(root: int) -> list[int]:
    kids, out, todo = children_map(), [], [root]
    while todo:
        for child in kids.get(todo.pop(), []):
            out.append(child)
            todo.append(child)
    return out


def argv_of(pid: int) -> list[str]:
    try:
        return [a.decode(errors="replace") for a in Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0") if a]
    except OSError:
        return []


def environ_of(pid: int) -> dict[str, str]:
    try:
        raw = Path(f"/proc/{pid}/environ").read_bytes().split(b"\0")
    except OSError:
        return {}
    return dict(e.decode(errors="replace").split("=", 1) for e in raw if b"=" in e)


def helper_bwrap(browser: int) -> int | None:
    """The browser's child that is the helper's bwrap (launch exec'd it in place)."""
    for pid in children_map().get(browser, []):
        argv = argv_of(pid)
        if argv[:1] == ["/usr/bin/bwrap"] and any(a.endswith("/zb-net-relay") for a in argv):
            return pid
    return None


def chat_pid(browser: int) -> int | None:
    """`<python> -I -c CHAT_BOOT <package> chat ...` itself (argv[5] is chat) (bwrap's and the relay's
    argv also name chat, after their own options)."""
    for pid in descendants(browser):
        argv = argv_of(pid)
        if argv[1:3] == ["-I", "-c"] and argv[5:6] == ["chat"]:
            return pid
    return None


def cli_pids(browser: int) -> list[int]:
    """The Claude CLIs themselves (the bundled `claude`, exec'd by zb-claude), not the
    hooks and other children that inherit their environment."""
    return [p for p in descendants(browser)
            if argv_of(p)[:1] and os.path.basename(argv_of(p)[0]) == "claude" and "MCP_TOOL_TIMEOUT" in environ_of(p)]


def in_namespace(ns: str) -> list[int]:
    found = []
    for entry in filter(str.isdigit, os.listdir("/proc")):
        try:
            if os.readlink(f"/proc/{entry}/ns/pid") == ns and alive(int(entry)):
                found.append(int(entry))
        except OSError:
            continue
    return found


class _ClientMessage(ctypes.Structure):
    _fields_ = [("type", ctypes.c_int), ("serial", ctypes.c_ulong), ("send_event", ctypes.c_int),
                ("display", ctypes.c_void_p), ("window", ctypes.c_ulong), ("message_type", ctypes.c_ulong),
                ("format", ctypes.c_int), ("l", ctypes.c_long * 5)]


class _XEvent(ctypes.Union):
    _fields_ = [("xclient", _ClientMessage), ("pad", ctypes.c_long * 24)]


def close_window(b) -> bool:
    """What a window manager's close button does: WM_DELETE_WINDOW to the browser's
    toplevel (S3.4 (a), a normal quit by closing the last window)."""
    x = b.x
    tops = x.toplevels()
    if not tops:
        return False
    lib = x._x
    lib.XInternAtom.restype = ctypes.c_ulong
    lib.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
    lib.XSendEvent.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_long, ctypes.c_void_p]
    event = _XEvent()
    event.xclient.type = 33  # ClientMessage
    event.xclient.window = tops[0][0]
    event.xclient.message_type = lib.XInternAtom(x._dpy, b"WM_PROTOCOLS", 0)
    event.xclient.format = 32
    event.xclient.l[0] = lib.XInternAtom(x._dpy, b"WM_DELETE_WINDOW", 0)
    lib.XSendEvent(x._dpy, tops[0][0], 0, 0, ctypes.byref(event))
    lib.XFlush(x._dpy)
    return True


def icon_centre(b) -> tuple[int, int] | None:
    """The floating icon (#d97757) found on the screen: without --e2e-protocol no row says where it is."""
    shot = b.x.screen()
    xs, ys = [], []
    for y in range(0, shot.height, 2):
        for x in range(0, shot.width, 2):
            r, g, bl = shot.pixel(x, y)
            if abs(r - 0xd9) < 12 and abs(g - 0x77) < 12 and abs(bl - 0x57) < 12:
                xs.append(x)
                ys.append(y)
    if len(xs) < 20:
        return None
    return (min(xs) + max(xs)) // 2, (min(ys) + max(ys)) // 2


def new_children(b, before: set[int]) -> list[list[str]]:
    """Descendants of the browser that were not there at `before` (WebKit's own are)."""
    return [argv_of(p)[:3] for p in descendants(b.proc.pid) if p not in before and alive(p)]


def sleepy_stop(w):
    """Arms the sleeping Stop hook; returns a function giving its live pids once it runs."""
    flag = w.agent / "scratchpad" / "sleepy-stop"
    flag.touch()

    def running() -> list[int]:
        if not Path(str(flag) + ".running").exists():
            return []
        return [int(p) for p in filter(str.isdigit, os.listdir("/proc"))
                if "notify.py" in " ".join(argv_of(int(p))) and "stop" in argv_of(int(p)) and alive(int(p))]
    return running


def disarm(w) -> None:
    for name in ("sleepy-stop", "sleepy-stop.running"):
        (w.agent / "scratchpad" / name).unlink(missing_ok=True)


def release_x(b) -> None:
    """Closes the test's own X connection before the browser (and with it its Xvfb)
    goes: Xlib's default handler would otherwise exit this process on the dead display."""
    if b._x is not None:
        b._x.close()
        b._x = None


def statuses(b, win: int = 1) -> list[tuple[str, str]]:
    return [(r.fields[0], r.fields[1] if len(r.fields) > 1 else "") for r in b.rows("status", win)]


def bubbles(b, win: int = 1) -> list[tuple[str, str]]:
    return [(r.fields[0], r.fields[1]) for r in b.rows("msg", win)]


def wait_ready(b, check, label: str, count: int = 1) -> bool:
    ok = b.wait(lambda: statuses(b).count(("ready", "-")) >= count, 60)
    check(ok, f"{label}: DRAWER status ready ({statuses(b)})", b)
    return ok


# --- the cases ------------------------------------------------------------------------------
def case_closure(binary: Path, tmp: Path, check) -> None:
    """S3.2 and the closure: lazy start, the allowlisted environment, the death chain, and a
    reply from the fake API through relay -> netd."""
    rt, fake = runtime_dir(), Fake(tmp)
    w = world(binary, tmp)
    hook = sleepy_stop(w)
    b = launch(binary, tmp, "closure", env_for(w, rt, fake.seams()))
    try:
        check(b.wait(lambda: b.rows("icon", 1) != [], 20), "the icon is up", b)
        time.sleep(1.0)
        check(helper_bwrap(b.proc.pid) is None and chat_pid(b.proc.pid) is None, "no helper before the first Send")
        send(b, "hi")
        check(b.wait(lambda: ("starting", "-") in statuses(b), 20), f"DRAWER status starting ({statuses(b)})", b)
        if not wait_ready(b, check, "first Send"):
            return
        helper = helper_bwrap(b.proc.pid)
        check(helper is not None, "the helper (bwrap, exec'd in place by launch) is the browser's child")
        if helper is not None:
            fields = stat_fields(helper)
            check(int(fields[1]) == b.proc.pid, "the helper's parent is the browser")
            check(int(fields[2]) == helper, f"the helper's process group is its own ({fields[2]} vs {helper})")
        chat = chat_pid(b.proc.pid)
        check(chat is not None, "chat runs")
        if chat is not None:
            env = environ_of(chat)
            check(set(env) == HELPER_ENV | {"PWD"} and env.get("PWD") == str(w.agent / "workspace"),
                  f"the helper's environment keys are exactly the allowlist, plus bwrap's PWD (the workspace) ({sorted(env)})")
            check(env.get("HOME", "").startswith(str(w.agent)) and env.get("CLAUDE_CONFIG_DIR", "").startswith(str(w.agent)),
                  "HOME and CLAUDE_CONFIG_DIR are inside the agent home")
            check(os.readlink(f"/proc/{chat}/ns/net") != os.readlink(f"/proc/{b.proc.pid}/ns/net"),
                  "chat has a network namespace of its own")
        check(b.wait(lambda: ("assistant", REPLY) in bubbles(b), 90), f"the fake's reply is shown ({bubbles(b)})", b)
        clis = cli_pids(b.proc.pid)
        check(any(environ_of(p).get("MCP_TOOL_TIMEOUT") == "130000" for p in clis),
              f"the session's CLI has MCP_TOOL_TIMEOUT=130000 ({len(clis)} CLI)")
        check(any(r["headers"].get("authorization") == f"Bearer {CANARY}" for r in fake.api.messages_requests()),
              "the token reached the fake as a bearer, through relay and netd")
        hello = json.loads((w.agent / "scratchpad" / "helper-hello.json").read_text())
        check(hello.get("e2e") == {"test_base_url": "https://fake.zb.invalid"} and hello.get("route") == "R1",
              f"hello carries the test base URL and R1 ({hello.get('e2e')}, {hello.get('route')})")
        # The death chain (RED-AT-SEAM: a helper spawned without bwrap's PID namespace leaves the CLI behind).
        ns = os.readlink(f"/proc/{chat}/ns/pid") if chat is not None else ""
        check(ns != os.readlink(f"/proc/{b.proc.pid}/ns/pid"), "the helper has a PID namespace of its own")
        check(b.wait(lambda: hook() != [], 30), "the sleeping Stop hook is running")
        agent = [p for p in [chat, *clis, *hook()] if p is not None]
        release_x(b)
        os.kill(b.proc.pid, signal.SIGKILL)
        deadline = time.monotonic() + 2.0
        while time.monotonic() < deadline and (in_namespace(ns) or any(alive(p) for p in agent)):
            time.sleep(0.05)
        check(agent != [] and not any(alive(p) for p in agent),
              f"browser SIGKILL: chat, its CLI and the sleeping hook are gone within 2 s ({[p for p in agent if alive(p)]})")
        check(ns != "" and in_namespace(ns) == [], f"browser SIGKILL: the helper's PID namespace is empty within 2 s ({in_namespace(ns)[:5]})")
    finally:
        b.stop()
        fake.close()
        disarm(w)


def case_frames(binary: Path, tmp: Path, check) -> None:
    """S3.3: bad frames are rejected natively with no content; three restart the helper; a
    valid frame after the restart is shown once."""
    rt = runtime_dir()
    w = world(binary, tmp)
    scratch = w.agent / "scratchpad"
    for name in ("fake-host-runs", "fake-host-frames.jsonl"):
        (scratch / name).unlink(missing_ok=True)
    secret = "zb-frame-secret-text"
    bad = [{"stderr": f"stderr says {CANARY} and {secret}"},
           {"raw": "{not json " + secret}, {"raw": json.dumps({"v": 1, "seq": 1, "type": "frobnicate", "x": secret})},
           {"frame": {"type": "assistant_message", "session": "s-9-9", "text": secret}},
           # Left in the pipe as the helper is condemned (RoseCat 5682): never parsed, never counted.
           {"repeat": ["{still junk " + secret, 400]}, {"stderr": "after the third"}]
    script = {"runs": [{"on_prompt": bad},
                       {"on_prompt": [{"frame": {"type": "assistant_message", "session": "$SESSION", "text": "valid after restart"}},
                                      {"frame": {"type": "result", "session": "$SESSION", "sdk_session_id": "fake-sdk-session", "subtype": "success",
                                                 "is_error": False, "num_turns": 1, "cost_usd": None}}]}]}
    (scratch / "fake-host-script.json").write_text(json.dumps(script))
    b = launch(binary, tmp, "frames", env_for(w, rt, {"ZIGBROWSER_AGENT_HOST_CMD": str(FAKE_HOST_SCRIPT)}))
    try:
        send(b, "one")
        rejected = lambda: [l for l in b.err if "zigBrowser: agent: rejected frame (" in l]  # noqa: E731
        check(b.wait(lambda: len(rejected()) >= 3, 30), f"three rejection lines ({rejected()})", b)
        check(not any(secret in l for l in b.err + b.out), "no frame content is logged or shown")
        check(b.wait(lambda: statuses(b).count(("ready", "-")) >= 2, 30), f"the helper restarted ({statuses(b)})", b)
        send(b, "two")
        check(b.wait(lambda: ("assistant", "valid after restart") in bubbles(b), 30), "the valid frame is shown", b)
        time.sleep(1.0)
        check(bubbles(b).count(("assistant", "valid after restart")) == 1, "shown once")
        check(len(rejected()) == 3, f"exactly three rejections: nothing the old helper left behind counts ({len(rejected())})")
        starts = [s for s in statuses(b) if s[0] == "starting"]
        check(len(starts) == 2, f"exactly one restart ({statuses(b)})")
        check(not any(CANARY in l or "stderr says" in l for l in b.err + b.out),
              "the helper's stderr reaches no log or row (D7 rev 16.7)")
        check((scratch / "fake-host-token-0").read_text() == str(len(CANARY)), "the fake got the token on fd 3")
    finally:
        b.stop()


def case_crash(binary: Path, tmp: Path, check) -> None:
    """S3.4 (d): SIGKILL the helper: the namespace is torn down, crashed signal-9 and the
    bubble; the next Send restarts after the backoff."""
    rt, fake = runtime_dir(), Fake(tmp)
    b = launch(binary, tmp, "crash", env_for(world(binary, tmp), rt, fake.seams()))
    try:
        send(b, "hi")
        if not wait_ready(b, check, "crash"):
            return
        b.wait(lambda: ("assistant", REPLY) in bubbles(b), 90)
        helper, chat = helper_bwrap(b.proc.pid), chat_pid(b.proc.pid)
        ns = os.readlink(f"/proc/{chat}/ns/pid") if chat else ""
        starts = len([r for r in b.rows("status", 1) if list(r.fields[:1]) == ["starting"]])
        os.kill(helper, signal.SIGKILL)
        killed = time.monotonic()
        check(b.wait(lambda: ("crashed", "signal-9") in statuses(b), 10), f"DRAWER status crashed signal-9 ({statuses(b)})", b)
        check(("system", "Agent stopped (signal 9). Send to restart.") in bubbles(b), "the crash bubble", b)
        deadline = time.monotonic() + 2.0
        while time.monotonic() < deadline and in_namespace(ns):
            time.sleep(0.05)
        check(ns != "" and in_namespace(ns) == [], "the CLI and everything in the helper's namespace are gone within 2 s")
        send(b, "again")  # well within the 1 s backoff of the crash
        restarted = lambda: len([r for r in b.rows("status", 1) if list(r.fields[:1]) == ["starting"]])  # noqa: E731
        check(b.wait(lambda: restarted() > starts, 20), f"the next Send restarts the helper ({statuses(b)})", b)
        waited = time.monotonic() - killed
        check(waited >= 1.0, f"the restart waited for the 1 s backoff ({waited:.2f} s after the kill)")
        check(b.wait(lambda: bubbles(b).count(("assistant", REPLY)) >= 2, 90), "the restarted helper answers", b)
    finally:
        b.stop()
        fake.close()


def case_quit(binary: Path, tmp: Path, check) -> None:
    """S3.4 (a) and (b): a normal quit and SIGINT leave nothing in the helper's namespace."""
    for how in ("close", "sigint"):
        rt, fake = runtime_dir(), Fake(tmp)
        w = world(binary, tmp)
        hook = sleepy_stop(w)
        b = launch(binary, tmp, f"quit-{how}", env_for(w, rt, fake.seams()))
        try:
            send(b, "hi")
            if not wait_ready(b, check, how):
                continue
            check(b.wait(lambda: hook() != [], 60), f"{how}: the sleeping Stop hook is running")
            chat = chat_pid(b.proc.pid)
            ns = os.readlink(f"/proc/{chat}/ns/pid") if chat else ""
            agent = [p for p in [chat, *cli_pids(b.proc.pid), *hook()] if p is not None]
            if how == "close":
                check(close_window(b), "close: the window got WM_DELETE_WINDOW")
                release_x(b)
            else:
                release_x(b)
                os.kill(b.proc.pid, signal.SIGINT)
            check(b.wait(lambda: b.proc.poll() is not None, 15), f"{how}: the browser exits")
            deadline = time.monotonic() + 2.0
            while time.monotonic() < deadline and (in_namespace(ns) or any(alive(p) for p in agent)):
                time.sleep(0.05)
            check(ns != "" and in_namespace(ns) == [], f"{how}: the helper's namespace is empty within 2 s")
            check(not any(alive(p) for p in agent), f"{how}: chat, its CLI and the sleeping hook are gone ({[p for p in agent if alive(p)]})")
        finally:
            b.stop()
            fake.close()
            disarm(w)


def case_window_close(binary: Path, tmp: Path, check) -> None:
    """S3.4 (e): closing the window that owns a session ends that session's CLI only;
    the helper and the other window's session stay."""
    rt, fake = runtime_dir(), Fake(tmp)
    b = launch(binary, tmp, "winclose", env_for(world(binary, tmp), rt, fake.seams()))
    try:
        send(b, "one")
        if not wait_ready(b, check, "window 1"):
            return
        check(b.wait(lambda: ("assistant", REPLY) in bubbles(b, 1), 90), "window 1 got its reply", b)
        first = set(cli_pids(b.proc.pid))
        b.wait_page()
        b.ev("(window.open('frame.html'), 1)")
        check(b.wait(lambda: b.rows("icon", 2) != [], 20), "the popup has its own drawer icon", b)
        send(b, "two", win=2)
        check(b.wait(lambda: ("assistant", REPLY) in bubbles(b, 2), 90), "window 2 got its reply", b)
        second = set(cli_pids(b.proc.pid)) - first
        check(len(first) == 1 and len(second) == 1, f"one CLI per window's session ({first}, {second})")
        chat = chat_pid(b.proc.pid)
        rejected = lambda: [l for l in b.err if "rejected frame" in l]  # noqa: E731
        b.zb.call("page.close", {"window_id": "window-2"})
        deadline = time.monotonic() + 15.0  # the SDK gives a CLI 5 s after stdin EOF, then terminates it
        while time.monotonic() < deadline and any(alive(p) for p in second):
            time.sleep(0.1)
        check(not any(alive(p) for p in second), "window 2's CLI exits")
        check(all(alive(p) for p in first) and chat is not None and alive(chat),
              "window 1's CLI and the helper stay")
        time.sleep(1.0)
        check(rejected() == [], f"closing the window rejects no frame: its session_ended is valid ({rejected()})")
        # RoseCat 5681: repeated closes never add up to a restart, including a close
        # before the session was even opened (session_opened and session_ended arrive later).
        for n, wait_reply in ((3, True), (4, True), (5, True), (6, False)):
            b.ev("(window.open('frame.html'), 1)")
            if not check(b.wait(lambda: b.rows("icon", n) != [], 20), f"popup {n} has its drawer", b):
                break
            send(b, f"popup {n}", win=n)
            if wait_reply:
                b.wait(lambda: ("assistant", REPLY) in bubbles(b, n), 90)
            b.zb.call("page.close", {"window_id": f"window-{n}"})
        time.sleep(3.0)
        check(rejected() == [], f"four more closes, one before session_opened: no rejected frame ({rejected()})")
        starts = [s for s in statuses(b, 1) if s[0] == "starting"]
        check(len(starts) == 1 and alive(chat), f"the helper was never restarted ({statuses(b, 1)})")
        send(b, "again")
        check(b.wait(lambda: bubbles(b, 1).count(("assistant", REPLY)) >= 2, 90), "window 1's session still answers", b)
    finally:
        b.stop()
        fake.close()


def case_late_error(binary: Path, tmp: Path, check) -> None:
    """RoseCat 5699: a valid session-scoped frame can arrive after its window closed.
    A late error of the closed popup's session is accepted (no strike), shown in no
    surviving drawer, followed by a valid session_ended, and the opener still answers."""
    rt = runtime_dir()
    w = world(binary, tmp)
    scratch = w.agent / "scratchpad"
    for name in ("fake-host-runs", "fake-host-frames.jsonl"):
        (scratch / name).unlink(missing_ok=True)
    late = "late error of a closed popup"
    reply = [{"frame": {"type": "assistant_message", "session": "$SESSION", "text": "fake reply"}},
             {"frame": {"type": "result", "session": "$SESSION", "sdk_session_id": "fake-sdk-session",
                        "subtype": "success", "is_error": False, "num_turns": 1, "cost_usd": None}}]
    on_end = [{"frame": {"type": "error", "session": "$SESSION", "code": "sdk", "message": late}},
              {"frame": {"type": "session_ended", "session": "$SESSION", "reason": "end"}}]
    (scratch / "fake-host-script.json").write_text(json.dumps({"runs": [{"on_prompt": reply, "on_end": on_end}]}))
    b = launch(binary, tmp, "late-error", env_for(w, rt, {"ZIGBROWSER_AGENT_HOST_CMD": str(FAKE_HOST_SCRIPT)}))
    try:
        send(b, "one")
        check(b.wait(lambda: ("assistant", "fake reply") in bubbles(b, 1), 30), "window 1 got its reply", b)
        b.wait_page()
        b.ev("(window.open('frame.html'), 1)")
        check(b.wait(lambda: b.rows("icon", 2) != [], 20), "the popup has its own drawer", b)
        send(b, "two", win=2)
        check(b.wait(lambda: ("assistant", "fake reply") in bubbles(b, 2), 30), "the popup got its reply", b)
        b.zb.call("page.close", {"window_id": "window-2"})
        frames_log = scratch / "fake-host-frames.jsonl"
        check(b.wait(lambda: frames_log.exists() and '"end_session"' in frames_log.read_text(), 20),
              "the helper got the popup's end_session")
        time.sleep(2.0)
        shown = [(win, role, text) for win in (1, 3) for role, text in bubbles(b, win) if late in text]
        check(shown == [], f"the closed popup's late error is shown in no surviving drawer ({shown})")
        check([l for l in b.err if "rejected frame" in l] == [], "the late error and session_ended strike nothing")
        send(b, "again")
        check(b.wait(lambda: bubbles(b, 1).count(("assistant", "fake reply")) >= 2, 30), "the opener still answers", b)
    finally:
        b.stop()


def case_sandbox_missing(binary: Path, tmp: Path, check) -> None:
    """S3.4 (f): no bwrap: "Agent sandbox unavailable", and no helper runs."""
    rt, fake = runtime_dir(), Fake(tmp)
    b = launch(binary, tmp, "nobwrap", env_for(world(binary, tmp), rt, {**fake.seams(), "ZIGBROWSER_AGENT_BWRAP": "/nonexistent/bwrap"}))
    try:
        send(b, "hi")
        check(b.wait(lambda: ("unavailable", "sandbox") in statuses(b), 30), f"DRAWER status unavailable sandbox ({statuses(b)})", b)
        check(("system", "Agent sandbox unavailable") in bubbles(b), "the bubble says so", b)
        check(chat_pid(b.proc.pid) is None, "no helper runs")
    finally:
        b.stop()
        fake.close()


def case_inert(binary: Path, tmp: Path, check) -> None:
    """S3.6: without --e2e-protocol the seams are inert: one line for each app-owned seam,
    the real bwrap and helper run, the hostile base URL gets no connection, hello has no e2e."""
    from agent_escape import TcpDecoy
    rt = runtime_dir()
    w = world(binary, tmp, "inert")
    markers = Path(tempfile.mkdtemp(prefix="markers-", dir=tmp))
    seams = {}
    for name in ("BWRAP", "HOST_CMD"):
        script = markers / f"{name.lower()}.sh"
        script.write_text(f"#!/bin/sh\ntouch {markers}/{name}.ran\nexit 0\n")
        script.chmod(0o755)
        seams[f"ZIGBROWSER_AGENT_{name}"] = str(script)
    hostile = TcpDecoy()
    seams["ZIGBROWSER_AGENT_TEST_BASE_URL"] = f"http://{hostile.address[0]}:{hostile.address[1]}"
    b = launch(binary, tmp, "inert", env_for(w, rt, seams), e2e=False)
    try:
        b.wait(lambda: b.display_file.exists(), 20)
        icon = None
        deadline = time.monotonic() + 30
        while icon is None and time.monotonic() < deadline:
            time.sleep(0.5)
            icon = icon_centre(b)
        check(icon is not None, "the icon is on the screen")
        if icon is None:
            return
        b.x.click(*icon)
        time.sleep(1.0)
        for ch in "hi":
            b.x.key(ch, settle=0.005)
        b.x.key("Return")
        check(b.wait(lambda: chat_pid(b.proc.pid) is not None, 60), "the real helper runs")
        for name in ("BWRAP", "HOST_CMD"):
            line = f"zigBrowser: ZIGBROWSER_AGENT_{name} ignored without --e2e-protocol"
            check([l for l in b.err if l == line] == [line], f"one line: {line}", b)
            check(not (markers / f"{name}.ran").exists(), f"the {name} marker never ran")
        hello_path = w.agent / "scratchpad" / "helper-hello.json"
        check(b.wait(hello_path.exists, 30), "the helper logged its hello")
        if hello_path.exists():
            check(json.loads(hello_path.read_text()).get("e2e") is None, "hello carries no e2e seam")
        time.sleep(2.0)
        check(hostile.accepted == 0, f"the hostile base URL got no connection ({hostile.accepted})")
    finally:
        b.stop()
        hostile.close()


def case_home_locked(binary: Path, tmp: Path, check) -> None:
    """S3.12 phases 1 and 3: B is refused while A owns the agent home, starts nothing and
    touches nothing; after A quits, B's next Send takes over."""
    from agent_common import Inotify
    fake = Fake(tmp)
    w = world(binary, tmp)
    # A's helper is the scripted fake (no Claude CLI, no hooks): once its reply is in, A
    # truly does nothing, so any event on the agent home is B's. A real CLI (and its hooks)
    # may read its working directory on its own, which would blur the oracle.
    scratch = w.agent / "scratchpad"
    for name in ("fake-host-runs", "fake-host-frames.jsonl"):
        (scratch / name).unlink(missing_ok=True)
    reply = [{"frame": {"type": "assistant_message", "session": "$SESSION", "text": REPLY}},
             {"frame": {"type": "result", "session": "$SESSION", "sdk_session_id": "fake-sdk-session",
                        "subtype": "success", "is_error": False, "num_turns": 1, "cost_usd": None}}]
    (scratch / "fake-host-script.json").write_text(json.dumps({"runs": [{"on_prompt": reply}]}))
    host = {**fake.seams(), "ZIGBROWSER_AGENT_HOST_CMD": str(FAKE_HOST_SCRIPT)}
    a = launch(binary, tmp, "owner-a", env_for(w, runtime_dir(), host))
    bb = None
    try:
        send(a, "hi")
        if not wait_ready(a, check, "A"):
            return
        a.wait(lambda: ("assistant", REPLY) in bubbles(a), 30)
        time.sleep(1.0)
        oracle = Inotify(w.agent / "workspace", w.agent / ".claude")  # A is idle from here
        bb = launch(binary, tmp, "owner-b", env_for(w, runtime_dir(), host))
        bb.wait(lambda: bb.rows("icon", 1) != [], 20)
        time.sleep(2.0)
        before = set(descendants(bb.proc.pid))
        send(bb, "hi")
        check(bb.wait(lambda: ("unavailable", "home-locked") in statuses(bb), 30), f"B: unavailable home-locked ({statuses(bb)})", bb)
        time.sleep(1.0)
        check(new_children(bb, before) == [], f"B started nothing ({new_children(bb, before)})")
        events = oracle.events()
        check(events == [], f"no inotify event on workspace/ and .claude/ while A is idle ({events[:3]})")
        release_x(a)
        a.stop()
        send(bb, "again")
        check(wait_ready(bb, check, "B takes over"), "B's next Send takes the lock and starts the agent")
    finally:
        a.stop()
        if bb is not None:
            bb.stop()
        fake.close()


def case_runtime_missing(binary: Path, tmp: Path, check) -> None:
    """S3.2 edge: no runtime: unavailable runtime-missing and the bubble; nothing starts."""
    rt = runtime_dir()
    b = launch(binary, tmp, "noruntime", env_for(world(binary, tmp), rt, {"ZB_AGENT_HOST_PYTHON": "/nonexistent/python"}))
    try:
        b.wait(lambda: b.rows("icon", 1) != [], 20)
        time.sleep(2.0)
        before = set(descendants(b.proc.pid))
        send(b, "hi")
        check(b.wait(lambda: ("unavailable", "runtime-missing") in statuses(b), 20), f"unavailable runtime-missing ({statuses(b)})", b)
        check(("system", "Agent runtime not set up: run zigBrowser --agent-setup") in bubbles(b), "the bubble says so", b)
        check(new_children(b, before) == [], f"nothing starts ({new_children(b, before)})")
    finally:
        b.stop()


CASES = {
    "closure": case_closure,
    "frames": case_frames,
    "crash": case_crash,
    "quit": case_quit,
    "window-close": case_window_close,
    "late-error": case_late_error,
    "sandbox-missing": case_sandbox_missing,
    "inert": case_inert,
    "home-locked": case_home_locked,
    "runtime-missing": case_runtime_missing,
}


def main() -> int:
    if "--sealed-child" not in sys.argv:
        # Re-run inside a network namespace of its own: no route to anything real.
        done = subprocess.run(["/usr/bin/bwrap", "--unshare-net", "--die-with-parent", "--dev-bind", "/", "/",
                               "--proc", "/proc", "--", sys.executable, str(Path(__file__).resolve()),
                               "--sealed-child", *sys.argv[1:]])
        return done.returncode
    sys.argv.remove("--sealed-child")
    from agent_common import run_main
    try:
        return run_main(__doc__, CASES)
    finally:
        for d in RUNTIME_DIRS:
            subprocess.run(["find", str(d), "-delete"], check=False)


if __name__ == "__main__":
    raise SystemExit(main())
