"""Scripted fake browsers for the hostless proof of the Mac runtime red rows (tests/e2e/mac_red_shape_selftest.py;
SilverRidge c78a1f6). A row's REAL main runs with its LAUNCH replaced by fake_launch(...) and its `time` by a
FakeClock, so every value main observes comes from the scripted process, RPC and output source: today's Mac
behavior must give RED_SHAPE, a fixed browser PASS, and a wrong observation of the same polarity a mismatch.
No process is started and nothing is signalled (FakeProc has no pid, and stop() is a no-op).
"""
import contextlib
import io
import os
import socket
import subprocess
from urllib.parse import urlsplit


class FakeClock:
    """monotonic() and sleep(): sleep advances the clock at once, so the rows' waits cost no real time."""

    def __init__(self):
        self.now = 1000.0

    def monotonic(self) -> float:
        return self.now

    def sleep(self, s: float) -> None:
        self.now += max(0.0, s)

    def time(self) -> float:
        return self.now


class FakeProc:
    pid = None  # never a pid: nothing can signal it

    def __init__(self):
        self.returncode = None
        self.exit_at = None  # (clock, at, rc): exits with rc once clock.now >= at

    def poll(self):
        if self.returncode is None and self.exit_at is not None:
            clock, at, rc = self.exit_at
            if clock.now >= at:
                self.returncode = rc
        return self.returncode

    def wait(self, timeout=None):
        if self.poll() is None and self.exit_at is not None:
            clock, at, rc = self.exit_at
            clock.now = max(clock.now, at)  # the fake clock jumps to the scripted exit
            return self.poll()
        if self.returncode is None:
            raise subprocess.TimeoutExpired("fake-browser", timeout)
        return self.returncode

    def exit(self, clock, rc: int, after: float = 0.0) -> None:
        self.exit_at = (clock, clock.now + after, rc)


class FakeRpc:
    """The RpcClient surface the rows use: raw -> the reply dict, call -> result or AssertionError, evaluate."""

    def __init__(self, browser):
        self.browser = browser

    def raw(self, method: str, params=None) -> dict:
        reply = self.browser.rpc(method, params or {})
        if "error" not in reply and "result" not in reply:
            reply = {"result": reply}
        return {"jsonrpc": "2.0", "id": 1, **reply}

    def call(self, method: str, params=None):
        reply = self.raw(method, params)
        if "error" in reply:
            raise AssertionError(f"{method} returned an error: {reply}")
        return reply["result"]

    def evaluate(self, expression: str):
        return self.call("page.evaluate", {"expression": expression})["result"]

    def close(self) -> None:
        pass


class FakeSession:
    def __init__(self, browser):
        self.browser = browser
        self.proc, self.out, self.err = browser.proc, browser.out, browser.err

    def connect(self):
        return FakeRpc(self.browser)

    def stop(self) -> None:
        self.browser.stopped += 1


class FakeBrowser:
    """Base: subclasses implement rpc(method, params) -> {"result": ...} or {"error": {...}} and may write out/err."""

    def __init__(self, clock: FakeClock, **knobs):
        self.clock, self.knobs = clock, knobs
        self.proc, self.out, self.err = FakeProc(), [], []
        self.stopped = 0
        self.launches = []

    def launch(self, argv, env, socket_path, timeout_sec):
        self.proc, self.out, self.err = FakeProc(), [], []  # each launch is a new process with its own output
        self.launches.append((list(argv), dict(env)))
        self.on_launch(argv, env)
        return FakeSession(self)

    def alive(self) -> bool:
        return self.proc.poll() is None

    def on_launch(self, argv, env) -> None:
        pass


def run_main(mod, browser_cls, browser_path: str, **knobs):
    """Run mod.main() with LAUNCH and time faked; returns (rc, stdout lines, the fake browser)."""
    clock = FakeClock()
    fake = browser_cls(clock, **knobs)
    saved = (mod.LAUNCH, mod.time)
    mod.LAUNCH, mod.time = fake.launch, clock
    out = io.StringIO()
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            rc = mod.main(["--browser", browser_path])
    finally:
        mod.LAUNCH, mod.time = saved
    return rc, out.getvalue().splitlines(), fake


def error(reason: str, message: str = "x") -> dict:
    return {"error": {"code": -32011, "message": message, "data": {"reason": reason}}}


class CloseButtonBrowser(FakeBrowser):
    """mac_ms2c_close_button_test. Knobs: fixed (the green: the popup really closes), routed (the routed reply
    to the closed popup), wincount (the last WINCOUNT row)."""

    def on_launch(self, argv, env):
        self.url = argv[1]
        self.popup = False
        self.closed = False
        self.out.append("WINCOUNT\t1")
        self.err.append("zb-live-jobs=0")

    def pages(self):
        p = [{"window_id": "window-1", "title": "OPENER"}]
        if self.popup and not (self.closed and self.knobs.get("fixed")):
            p.append({"window_id": "window-2", "title": "POPUP"})
        return p

    def rpc(self, method, params):
        fixed = self.knobs.get("fixed")
        if method == "page.url":
            return {"result": {"url": self.url}}
        if method == "page.list":
            return {"result": {"pages": self.pages()}}
        if method == "page.evaluate":
            expr = params.get("expression", "")
            if "window.open" in expr:
                self.popup = True
                self.out.append("WINCOUNT\t2")
                return {"result": {"result": True}}
            if "document.title" in expr and params.get("window_id") == "window-2":
                self.closed = True
                self.out.append("NATIVE_CLOSE\t2")
                if fixed:
                    self.out.append("WINCOUNT\t1")
                elif self.knobs.get("wincount"):
                    self.out.append(self.knobs["wincount"])
                return {"result": {"result": True}}
            if "getElementById('t')" in expr:
                return {"result": {"result": "opener-dom"}}
        if method == "page.title" and params.get("window_id") == "window-2":
            if fixed:
                return error("no_window")
            return self.knobs.get("routed") or {"result": {"title": "zb-native-close"}}
        return error("unscripted", f"unscripted {method} {params}")


def fetch(url: str, timeout: float = 0.5) -> None:
    """A real GET to the row's fixture (so its hit/held counters see the page's request); the reply is ignored and
    a server that holds the request open is left after `timeout`."""
    u = urlsplit(url)
    try:
        with socket.create_connection((u.hostname, u.port), timeout=timeout) as c:
            c.sendall(f"GET {u.path or '/'} HTTP/1.0\r\nHost: {u.hostname}\r\n\r\n".encode())
            try:
                c.recv(1)
            except OSError:
                pass
    except OSError:
        pass


def base_of(url: str) -> str:
    u = urlsplit(url)
    return f"{u.scheme}://{u.netloc}"


class DialogBrowser(FakeBrowser):
    """mac_ms2b_dialog_popup_id_test. Knobs: fixed, listed (the window_id dialog.get {} reports), by_id (the reply of
    dialog.get on window-3), respond (the reply of dialog.respond on the listed window)."""

    def on_launch(self, argv, env):
        self.url, self.wins, self.dialog = argv[1], [("window-1", "OPENER")], False
        self.answered = None

    def rpc(self, method, params):
        fixed, k = self.knobs.get("fixed"), self.knobs
        if method == "page.url":
            return {"result": {"url": self.url}}
        if method == "page.list":
            return {"result": {"pages": [{"window_id": w, "title": t} for w, t in self.wins]}}
        if method == "page.close":
            self.wins = [x for x in self.wins if x[0] != params.get("window_id")]
            return {"result": {"ok": True}}
        if method == "page.evaluate":
            expr = params.get("expression", "")
            if "window.open('/p1')" in expr:
                self.wins += [("window-2", "P1"), ("window-3", "P2")]
                return {"result": {"result": True}}
            if "confirm(" in expr and params.get("window_id") == "window-3":
                self.dialog = True
                return {"result": {"result": True}}
            if "__zbR === true" in expr:
                return {"result": {"result": self.answered is True}}
        if method == "dialog.get":
            if not self.dialog:
                return {"result": {"open": False}}
            if not params.get("window_id"):
                return {"result": {"open": True, "type": "confirm",
                                   "window_id": "window-3" if fixed else k.get("listed", "window-2")}}
            if params["window_id"] == "window-3":
                return {"result": {"open": True, "type": "confirm"} if fixed else k.get("by_id", {"open": False})}
        if method == "dialog.respond":
            if params.get("window_id") == "window-3":  # the dialog's real window
                if self.answered is None:
                    self.answered = bool(params.get("accept"))
                return {"result": {"ok": True}}
            return k.get("respond") or error("no_window")
        return error("unscripted", f"unscripted {method} {params}")


class CookieBrowser(FakeBrowser):
    """mac_cookie_timeout_test. Knobs: fixed (the deadline holds: action_timeout at 10 s), reply (each op's reply
    today), takes (seconds each op takes)."""

    def on_launch(self, argv, env):
        self.url = argv[1]
        self.err.append("zb-live-jobs=0")

    def rpc(self, method, params):
        if method == "page.url":
            return {"result": {"url": self.url}}
        if method.startswith("cookies."):
            self.err.append("zb-cookie-delay-hit=12500")
            if self.knobs.get("fixed"):
                self.clock.now += 10.0
                return {"error": {"code": -32000, "message": "action_timeout"}}
            self.clock.now += self.knobs.get("takes", 12.5)
            return self.knobs.get("reply") or {"result": {"cookies": []} if method == "cookies.getAll" else {"ok": True}}
        return error("unscripted", f"unscripted {method} {params}")


class RecoverBrowser(FakeBrowser):
    """mac_ms2c_recover_slow_server_test. Knobs: fixed (the browser survives the down server), rc and after (today:
    exit 8, 15 s after phase 2)."""

    def on_launch(self, argv, env):
        self.url, self.frozen = argv[1], False

    def rpc(self, method, params):
        if method == "page.url":
            return {"result": {"url": self.url}}
        if method == "page.evaluate" and "freeze()" in params.get("expression", ""):
            self.frozen = True
            return {"result": {"result": None}}
        if method == "page.health":
            return {"result": {"pages": [{"window_id": "window-1", "responsive": not self.frozen}]}}
        if method == "page.recover" and "incident" not in params:
            return {"result": {"incident": "inc-1"}}
        if method == "page.recover":
            self.frozen = False
            fetch(self.url)  # the recovery reload reaches the (now hanging) fixture
            if not self.knobs.get("fixed"):
                self.proc.exit(self.clock, self.knobs.get("rc", 8), self.knobs.get("after", 15.0))
            return {"result": {"recovered": [{"window_id": "window-1", "reloaded": True}]}}
        return error("unscripted", f"unscripted {method} {params}")


class PacingBrowser(FakeBrowser):
    """mac_profile_pacing_persist_test. Knobs: fixed (the profile dir is created: the state saves and restores),
    save_error (the error name of today's failed save), cap2 (run 2's cap today: the default)."""

    DEFAULT = 100

    def on_launch(self, argv, env):
        self.url, self.profile = argv[1], argv[argv.index("--profile-dir") + 1]
        self.run = len(self.launches)

    def rpc(self, method, params):
        pacing = os.path.join(self.profile, "automation-pacing.json")
        if method == "page.url":
            return {"result": {"url": self.url}}
        if method == "social.rate_status":
            if self.run == 1:
                return {"result": {"daily_cap": self.DEFAULT}}
            return {"result": {"daily_cap": 7 if self.knobs.get("fixed") else self.knobs.get("cap2", self.DEFAULT)}}
        if method == "social.set_pacing":
            if self.knobs.get("fixed"):
                os.makedirs(self.profile, exist_ok=True)
                with open(pacing, "w") as f:
                    f.write('{"daily_cap":7}')
            else:
                name = self.knobs.get("save_error", "FileNotFound")
                self.err.append(f"warning: automation pacing: could not save {pacing}: {name}")
            return {"result": {"ok": True}}
        return error("unscripted", f"unscripted {method} {params}")


class LoadFailBrowser(FakeBrowser):
    """mac_ms2a_load_fail_no_quit_test. Knobs: fixed (a post-first-finish load failure is recorded and the browser
    keeps running), rc (today's exit code after the failure: 5), load_fails (LOAD_FAIL rows per failure: 1)."""

    DEAD = "http://nonexistent.invalid/"

    def on_launch(self, argv, env):
        self.url = argv[1]
        if self.url == self.DEAD:  # row 5: the primary window's initial load fails and the app exits 5
            self.out.append(f"LOAD_FAIL\t{self.DEAD}\t-1003")
            self.proc.exit(self.clock, 5)
        else:
            self.out.append(f"NAV\t{self.url}")

    def fail(self, uri: str):
        for _ in range(self.knobs.get("load_fails", 1)):
            self.out.append(f"LOAD_FAIL\t{uri}\t-1003")
        if not self.knobs.get("fixed"):
            self.proc.exit(self.clock, self.knobs.get("rc", 5))
        return {"result": {"result": True}}

    def rpc(self, method, params):
        if not self.alive():
            return error("closed", "socket closed")
        if method == "page.list":
            return {"result": {"pages": [{"window_id": "window-1"}]}}
        if method == "page.navigate":
            self.url = params["url"]
            self.out.append(f"NAV\t{self.url}")
            return {"result": {"ok": True}}
        if method == "page.evaluate":
            expr = params.get("expression", "")
            if "getElementById('dead')" in expr or "location.href" in expr:
                return self.fail(self.DEAD)
            if "getElementById('attach')" in expr:
                fetch(base_of(self.url) + "/attach")
                return self.fail(base_of(self.url) + "/attach")
        return error("unscripted", f"unscripted {method} {params}")
