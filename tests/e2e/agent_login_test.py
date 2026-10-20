"""S6b1 (chat-drawer plan rev 16.18.3 and 16.18.4, S6.1 inertness and S6.4): "Sign in with
Claude.ai" in the Secrets window, through the paste path, end to end.

The browser runs the real login helper (`launch --command login`) in its sandbox, with
its own login netd (runtime/net-login.json, `<chat sockdir>-login`, egress only). Under
--e2e-protocol, ZIGBROWSER_AGENT_CLAUDE_CLI names tests/e2e/fake_claude_setup_token.py,
which replays the real CLI's capture and writes its state under the agent home's
scratchpad. A test puts `<code>#<state>` on the private Xvfb's CLIPBOARD and pastes it
into the window's code entry with a real Ctrl+V, as a user pastes the code page's text
(rev 16.18.4, RoseCat 5994).

Rows (D7b, rev 16.18.3 and 16.18.4):
- `SECRETS rect <signin|code|send-code|cancel|copy-link> <x,y,w,h>`;
- `SECRETS login <starting|need-code|done|error-<code>|cancelled>`;
- `SECRETS status` and `SECRETS text`, as in S4 (the sign-in's fixed sentences).
stderr: under --e2e-protocol the login netd runs with `--census` and writes
`netd census <host>:<port> <allowed|refused>` once per distinct CONNECT target.

Cases (run alone or with --only):
- paste-sign-in: the token printed by the fake reaches the private keyring through
  fd 4; `SECRETS login done` and `connected-secret-service` appear; the sign-in's
  fixed sentences appear in order; the fake received exactly that code; no login
  netd or `-login` directory remains; the canary is nowhere else.
- malformed: a pasted text that is not `<code>#<state>` shows "That doesn't look
  like a sign-in code.", reaches no code at the fake, stores nothing, and the
  sign-in still waits for a code.
- foreign-state: a code with another state is refused by the CLI and asked for
  again (a second `need-code`); the right one then signs in.
- link: the sign-in link is shown, and Copy link puts exactly the authorize URL
  the fake printed on the CLIPBOARD.
- during-sign-in: while the sign-in waits for a code, the login netd's directory has
  egress/ only, one login netd serves, chat's netd still refuses CONNECT
  platform.claude.com:443, and a CONNECT the test dials through the login netd to a
  host it does not allow appears as one census line.
- cancel: Cancel ends the sign-in (`SECRETS login cancelled`), nothing is stored, and
  no login helper, login netd or `-login` directory remains.
- close: closing the Secrets window does the same.
- error-network: a net-login.json that netd refuses gives exactly one ending,
  `error-network`, and nothing is stored or left running.
- error-store: with no keyring (and no file store chosen), the signed-in token cannot
  be stored: `error-store` is the one ending, the window says no keyring is
  available, and the token is nowhere.
- inert: without --e2e-protocol, ZIGBROWSER_AGENT_CLAUDE_CLI is ignored, with one
  stderr line; the login helper's cmdline has no --e2e-claude-cli, its environment
  has no such variable, and the marker script never runs. The browser runs in a
  network namespace with no network, and Sign in is reached by its mnemonic (Alt+I),
  since there are no rows to aim at. The private Xvfb has no window manager, so the
  test gives the Secrets window the input focus first, as one would."""

import json
import os
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import agent_secrets_test as sec  # noqa: E402 - its keyring, launch, X input and scanner
from agent_common import run_main  # noqa: E402

FAKE = HERE / "fake_claude_setup_token.py"
LOGIN_STATES = ("starting", "need-code", "done", "cancelled")
LOGIN_ERRORS = ("cli", "timeout", "cancelled", "shape", "protocol", "exchange", "network", "store")
TEXT_SIGNING = "Signing in..."
TEXT_NEED_CODE = "Paste the code from the sign-in page."
TEXT_SIGNED_SERVICE = "Signed in. The token is stored in the system keyring."
TEXT_BAD_CODE = "That doesn't look like a sign-in code."
TEXT_FAILED = "Sign-in failed."
TEXT_CANCELLED = "Sign-in cancelled."
TEXT_NO_KEYRING = "No system keyring is available. Nothing was stored."


# --- rows --------------------------------------------------------------------------------
def rows(b, kind: str) -> list[tuple[str, ...]]:
    out = []
    for line in list(b.out):
        parts = line.split("\t")
        if parts[:2] == ["SECRETS", kind]:
            out.append(tuple(parts[2:]))
    return out


def login_states(b) -> list[str]:
    states = [f[0] for f in rows(b, "login")]
    for s in states:
        if s not in LOGIN_STATES and not (s.startswith("error-") and s[6:] in LOGIN_ERRORS):
            raise AssertionError(f"malformed SECRETS login row: {s!r}")
    return states


def endings(b) -> list[str]:
    return [s for s in login_states(b) if s in ("done", "cancelled") or s.startswith("error-")]


def rect(b, name: str):
    found = [f[1] for f in rows(b, "rect") if len(f) == 2 and f[0] == name]
    if not found:
        return None
    r = tuple(int(v) for v in found[-1].split(","))
    return r if r[2] > 0 and r[3] > 0 else None


def statuses(b) -> list[str]:
    return [f[0] for f in rows(b, "status")]


def texts(b) -> list[str]:
    return [f[0] for f in rows(b, "text")]


def in_order(seen: list[str], want: list[str]) -> bool:
    i = 0
    for item in seen:
        if i < len(want) and item == want[i]:
            i += 1
    return i == len(want)


# --- the world ---------------------------------------------------------------------------
class SignIn:
    """A provisioned agent home whose scratchpad holds the fake's token, a private keyring
    (or, with `keyring=False`, a dead session bus), and the browser launched with the fake
    setup-token CLI. `net_login`: replaces runtime/net-login.json before the launch;
    `bus_extra`: more environment for the browser (e.g. the store's test delay)."""

    def __init__(self, binary: Path, tmp: Path, name: str, keyring: bool = True, net_login: dict | None = None,
                 bus_extra: dict | None = None) -> None:
        self.token = sec.canary()
        self.world = sec.provisioned(binary, tmp, name)
        self.fake_dir = self.world.agent / "scratchpad" / ".zb-fake-setup-token"
        self.fake_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        (self.fake_dir / "token").write_text(self.token + "\n", encoding="ascii")
        if net_login is not None:
            path = Path(os.path.realpath(self.world.agent / "runtime" / "net-login.json"))
            os.chmod(path.parent, 0o700)
            path.write_text(json.dumps(net_login), encoding="utf-8")
            os.chmod(path, 0o600)
        base_env = self.world.env
        self.world.env = lambda extra=None: dict(base_env(extra), ZIGBROWSER_AGENT_CLAUDE_CLI=str(FAKE))
        self.kr = sec.PrivateKeyring(tmp) if keyring else None
        bus_env = self.kr.bus_env if keyring else {
            "DBUS_SESSION_BUS_ADDRESS": sec.DEAD_BUS, "XDG_RUNTIME_DIR": str(sec.short_runtime_dir())}
        self.api = sec.fake_api(tmp).__enter__()
        self.b = sec.launch(binary, tmp, self.world, dict(bus_env, **(bus_extra or {})), self.api, name)
        self.runtime = Path(bus_env["XDG_RUNTIME_DIR"])

    def close(self) -> None:
        try:
            self.b.stop()
        finally:
            self.api.__exit__(None, None, None)
            if self.kr is not None:
                self.kr.close()

    def state(self) -> str | None:
        try:
            return (self.fake_dir / "state").read_text(encoding="ascii").strip() or None
        except OSError:
            return None

    def codes(self) -> list[str]:
        try:
            return (self.fake_dir / "codes.log").read_text(encoding="utf-8").splitlines()
        except OSError:
            return []

    def open_window(self, check) -> bool:
        """Send with no token opens the Secrets window."""
        b = self.b
        sec.send_prompt(b, "hello")
        if not check(b.wait(lambda: statuses(b) != [], 20), "Send with no token opens the Secrets window", b):
            return False
        return check(b.wait(lambda: rect(b, "signin") is not None, 15), "SECRETS rect signin", b)

    def sign_in(self, check, need_code: bool = True) -> bool:
        b = self.b
        sec.click_rect(b, rect(b, "signin"))
        check(b.wait(lambda: login_states(b)[:1] == ["starting"], 15), "SECRETS login starting", b)
        if not need_code:
            return True
        return check(b.wait(lambda: "need-code" in login_states(b) and self.state() is not None
                            and rect(b, "code") is not None, 60),
                     "SECRETS login need-code, the code entry is shown and the fake wrote its state", b)

    def open_and_sign_in(self, check) -> bool:
        return self.open_window(check) and self.sign_in(check)

    def paste(self, text: str) -> None:
        """`text` on the private Xvfb's CLIPBOARD, a real Ctrl+V into the code entry, then
        Send code. A sign-in code is not a secret (the token never travels this way)."""
        b = self.b
        owner = sec.ClipboardOwner(b, text)
        try:
            sec.click_rect(b, rect(b, "code"))
            b.x.key("v", ("Control_L",))
            time.sleep(0.3)
            sec.click_rect(b, rect(b, "send-code"))
            time.sleep(0.3)
        finally:
            owner.close()


def login_dirs(runtime: Path) -> list[Path]:
    return sorted(p for p in runtime.glob("zigbrowser-agent-*-login"))


def chat_dirs(runtime: Path) -> list[Path]:
    return sorted(p for p in runtime.glob("zigbrowser-agent-*") if not p.name.endswith("-login"))


def argv_of(pid: int) -> list[str]:
    try:
        return [a.decode(errors="replace") for a in Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0") if a]
    except OSError:
        return []


def procs(root: int, *needles: str) -> list[int]:
    """Live descendants of `root` (this test's own browser session) whose cmdline holds
    every needle. Only descendants: other gate steps and other agents run their own login
    helpers and netds at the same time (BlueBeaver 5631's rule)."""
    from agent_setup_test import descendants
    found = []
    for pid in sorted(descendants(root)):
        text = argv_of(pid)
        if text and all(any(n in a for a in text) for n in needles):
            found.append(pid)
    return found


def login_netds(b, runtime: Path) -> list[int]:
    """Live login netd launchers under this browser: not bwrap, and not the sandboxed
    --serve side (as agent_netd_spawn_test.netd_launchers counts them), so one netd is
    one process."""
    found = []
    for p in procs(b.proc.pid, "netd.py", "--sockdir"):
        argv = argv_of(p)
        if "--serve" in argv or argv[0].endswith("bwrap"):
            continue
        if any(f"{runtime}/" in a and a.endswith("-login") for a in argv):
            found.append(p)
    return found


def login_helpers(b) -> list[int]:
    return [p for p in procs(b.proc.pid, "zb_agent_host", "login") if "login" in argv_of(p)]


def connect_status(sock_path: Path, host: str) -> int | None:
    import socket
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(5)
    try:
        s.connect(str(sock_path))
        s.sendall(b"CONNECT %s:443 HTTP/1.1\r\n\r\n" % host.encode())
        head = s.recv(256).split(b"\r\n", 1)[0].split()
        return int(head[1]) if len(head) >= 2 else None
    except OSError:
        return None
    finally:
        s.close()


def focus_window(b, title: str) -> bool:
    """What a window manager does for a newly presented window: give it the input focus
    (the private Xvfb has none, and the keyboard would stay on the browser window)."""
    import ctypes
    wins = b.x.toplevels(title)
    if not wins:
        return False
    x = b.x._x
    x.XSetInputFocus.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_ulong]
    x.XSetInputFocus(b.x._dpy, wins[-1][0], 2, 0)  # RevertToParent, CurrentTime
    x.XFlush(b.x._dpy)
    time.sleep(0.3)
    return True


def nothing_left(si: SignIn, check, label: str) -> None:
    b = si.b
    check(b.wait(lambda: login_helpers(b) == [], 15), f"{label}: no login helper remains", b)
    check(b.wait(lambda: login_netds(b, si.runtime) == [], 15), f"{label}: no login netd remains", b)
    check(b.wait(lambda: login_dirs(si.runtime) == [], 15), f"{label}: no -login directory remains", b)


# --- the cases ---------------------------------------------------------------------------
def case_paste_sign_in(binary: Path, tmp: Path, check) -> None:
    si = SignIn(binary, tmp, "paste")
    b = si.b
    try:
        if not si.open_and_sign_in(check):
            return
        code = f"fakecode-0123#{si.state()}"
        si.paste(code)
        check(b.wait(lambda: login_states(b)[-1:] == ["done"], 30), "SECRETS login done", b)
        check(b.wait(lambda: statuses(b)[-1:] == ["connected-secret-service"], 20),
              "SECRETS status connected-secret-service", b)
        check(si.kr.lookup() == si.token, "the private keyring holds the token the CLI printed")
        check(si.codes() == [code], f"the fake received exactly the pasted code ({si.codes()})")
        check(endings(b) == ["done"], f"exactly one ending: {login_states(b)}", b)
        check(in_order(texts(b), [TEXT_SIGNING, TEXT_NEED_CODE, TEXT_SIGNING, TEXT_SIGNED_SERVICE]),
              f"the sign-in's fixed sentences, in order: {texts(b)}", b)
        check(all(t in sec.SECRETS_TEXTS for t in texts(b)), f"only the window's fixed sentences: {texts(b)}", b)
        nothing_left(si, check, "after done")
        (si.fake_dir / "token").unlink()  # the test's own input: the CLI's copy, not the browser's
        found = sec.scan_for(si.token, b, si.world, si.api)
        check(found == [], f"the token is nowhere but the keyring: {found}", b)
    finally:
        si.close()


def case_malformed(binary: Path, tmp: Path, check) -> None:
    si = SignIn(binary, tmp, "malformed")
    b = si.b
    try:
        if not si.open_and_sign_in(check):
            return
        for bad in ("not a code", "nohash", "a#b#c"):
            si.paste(bad)
            check(b.wait(lambda: texts(b)[-1:] == [TEXT_BAD_CODE], 10), f"{bad!r}: \"{TEXT_BAD_CODE}\"", b)
        time.sleep(1)
        check(si.codes() == [], f"no malformed code reached the fake ({si.codes()})")
        check(endings(b) == [] and statuses(b)[-1:] == ["empty"], "nothing was stored, and the sign-in still waits", b)
        check(si.kr.lookup() is None, "the keyring holds nothing")
        si.paste(f"c0de#{si.state()}")
        check(b.wait(lambda: statuses(b)[-1:] == ["connected-secret-service"], 30), "a right code still signs in", b)
    finally:
        si.close()


def case_foreign_state(binary: Path, tmp: Path, check) -> None:
    si = SignIn(binary, tmp, "foreign")
    b = si.b
    try:
        if not si.open_and_sign_in(check):
            return
        si.paste("fakecode#" + "A" * 43)
        check(b.wait(lambda: login_states(b).count("need-code") >= 2, 30),
              "the CLI refused another sign-in's state and asked again (a second need-code)", b)
        check(statuses(b)[-1:] == ["empty"] and endings(b) == [], "nothing was stored", b)
        code = f"fakecode#{si.state()}"
        si.paste(code)
        check(b.wait(lambda: statuses(b)[-1:] == ["connected-secret-service"], 30), "the right code then signs in", b)
        check(si.codes() == ["fakecode#" + "A" * 43, code], f"the fake received both, in order ({si.codes()})")
    finally:
        si.close()


def case_link(binary: Path, tmp: Path, check) -> None:
    from agent_drawer_copy_test import clipboard
    si = SignIn(binary, tmp, "link")
    b = si.b
    try:
        if not si.open_and_sign_in(check):
            return
        check(b.wait(lambda: rect(b, "copy-link") is not None, 10), "SECRETS rect copy-link: the link is shown", b)
        sec.click_rect(b, rect(b, "copy-link"))
        time.sleep(0.5)
        got = clipboard(b)
        want_head = "https://claude.com/cai/oauth/authorize?code=true&client_id="
        check(got is not None and got.startswith(want_head) and got.endswith(f"&state={si.state()}")
              and "\n" not in got, f"Copy link put exactly the authorize URL on the CLIPBOARD ({got!r})", b)
    finally:
        si.close()


def case_during_sign_in(binary: Path, tmp: Path, check) -> None:
    si = SignIn(binary, tmp, "during")
    b = si.b
    try:
        if not si.open_and_sign_in(check):
            return
        dirs = login_dirs(si.runtime)
        check(len(dirs) == 1, f"one -login directory while signing in ({dirs})", b)
        if dirs:
            check(sorted(p.name for p in dirs[0].iterdir()) == ["egress"], "the login netd serves egress/ only", b)
            check(connect_status(dirs[0] / "egress" / "proxy.sock", "example.invalid") == 403,
                  "the login netd refuses a host it does not allow", b)
            line = "netd census example.invalid:443 refused"
            check(b.wait(lambda: any(line in l for l in b.err), 10), f"one census line: {line}", b)
        check(len(login_netds(b, si.runtime)) == 1, f"one login netd serves ({login_netds(b, si.runtime)})", b)
        chats = chat_dirs(si.runtime)
        if check(chats != [], "chat's netd runs", b):
            check(connect_status(chats[0] / "egress" / "proxy.sock", "platform.claude.com") == 403,
                  "chat's netd still refuses CONNECT platform.claude.com:443", b)
        sec.click_rect(b, rect(b, "cancel"))
        nothing_left(si, check, "after cancel")
    finally:
        si.close()


def case_cancel(binary: Path, tmp: Path, check) -> None:
    si = SignIn(binary, tmp, "cancel")
    b = si.b
    try:
        if not si.open_and_sign_in(check):
            return
        check(rect(b, "cancel") is not None, "SECRETS rect cancel", b)
        sec.click_rect(b, rect(b, "cancel"))
        check(b.wait(lambda: login_states(b)[-1:] == ["cancelled"], 15), "SECRETS login cancelled", b)
        check(endings(b) == ["cancelled"], f"exactly one ending: {login_states(b)}", b)
        check(texts(b)[-1:] == [TEXT_CANCELLED], f"\"{TEXT_CANCELLED}\"", b)
        check(statuses(b)[-1:] == ["empty"] and si.kr.lookup() is None, "nothing was stored", b)
        check(si.codes() == [], "the fake received no code")
        nothing_left(si, check, "after cancel")
    finally:
        si.close()


def case_close(binary: Path, tmp: Path, check) -> None:
    si = SignIn(binary, tmp, "close")
    b = si.b
    try:
        if not si.open_and_sign_in(check):
            return
        wins = b.x.toplevels("Claude Agent account")
        check(len(wins) == 1, f"the Secrets window is one toplevel ({wins})", b)
        if wins:
            sec.close_secrets_window(b)
        check(b.wait(lambda: login_states(b)[-1:] == ["cancelled"], 15), "closing the window cancels the sign-in", b)
        check(endings(b) == ["cancelled"], f"exactly one ending: {login_states(b)}", b)
        check(si.kr.lookup() is None, "nothing was stored")
        nothing_left(si, check, "after close")
    finally:
        si.close()


def case_error_network(binary: Path, tmp: Path, check) -> None:
    # One of the two network keys without the other: netd refuses it and exits 2 (rev 16.18.2).
    si = SignIn(binary, tmp, "network", net_login={"egress": {"endpoint": "127.0.0.1:3128",
                                                              "allow": ["api.anthropic.com"]}})
    b = si.b
    try:
        if not (si.open_window(check) and si.sign_in(check, need_code=False)):
            return
        check(b.wait(lambda: endings(b) != [], 20) and endings(b) == ["error-network"],
              f"exactly one ending, error-network: {login_states(b)}", b)
        check(texts(b)[-1:] == [TEXT_FAILED], f"\"{TEXT_FAILED}\"", b)
        check(si.codes() == [] and si.kr.lookup() is None, "nothing was stored and no code was asked for", b)
        nothing_left(si, check, "after error-network")
    finally:
        si.close()


def case_error_store(binary: Path, tmp: Path, check) -> None:
    si = SignIn(binary, tmp, "store", keyring=False)
    b = si.b
    try:
        if not si.open_and_sign_in(check):
            return
        si.paste(f"fakecode#{si.state()}")
        check(b.wait(lambda: endings(b) != [], 30) and endings(b) == ["error-store"],
              f"exactly one ending, error-store: {login_states(b)}", b)
        check(b.wait(lambda: statuses(b)[-1:] == ["no-keyring"], 10) and texts(b)[-1:] == [TEXT_NO_KEYRING],
              "the window says no keyring is available", b)
        check(not (si.world.agent / "secrets" / "claude-token").exists(), "no token file (the file store was not chosen)")
        nothing_left(si, check, "after error-store")
        (si.fake_dir / "token").unlink()
        found = sec.scan_for(si.token, b, si.world, si.api)
        check(found == [], f"the token is nowhere: {found}", b)
    finally:
        si.close()


def case_inert(binary: Path, tmp: Path, check) -> None:
    """S6.1 inertness: no --e2e-protocol, no network at all (a fresh user+net namespace)."""
    from agent_common import Browser
    from agent_host_lifecycle_test import icon_centre
    from slice2_common import isolate_profile_env
    world = sec.provisioned(binary, tmp, "inert")
    markers = Path(tempfile.mkdtemp(prefix="markers-", dir=tmp))
    marker_cli = markers / "cli.sh"
    marker_cli.write_text(f"#!/bin/sh\ntouch {markers}/cli.ran\nexit 0\n")
    marker_cli.chmod(0o755)
    with sec.PrivateKeyring(tmp) as kr:
        env = isolate_profile_env(dict(os.environ))
        env.update(world.env({"ZIGBROWSER_AGENT_CLAUDE_CLI": str(marker_cli)}))
        env.update(kr.bus_env)
        sec.assert_not_user_bus(env)
        b = Browser(binary, tmp, "inert", ["--agent-drawer", "on"], env=env, e2e=False,
                    prefix=["unshare", "--user", "--map-current-user", "--net"])
        try:
            b.wait(lambda: b.display_file.exists(), 20)
            # No rows without --e2e-protocol: the icon is found by its pixels, as S3.6 does.
            icon = None
            deadline = time.monotonic() + 30
            while icon is None and time.monotonic() < deadline:
                time.sleep(0.5)
                icon = icon_centre(b)
            if not check(icon is not None, "the icon is on the screen", b):
                return
            b.x.click(*icon)
            time.sleep(1.0)
            for ch in "hi":
                b.x.key(ch, settle=0.005)
            b.x.key("Return")
            check(b.wait(lambda: b.x.toplevels("Claude Agent account") != [], 20), "the Secrets window opened", b)
            check(focus_window(b, "Claude Agent account"), "the Secrets window has the input focus", b)
            b.x.key("i", ("Alt_L",))
            check(b.wait(lambda: login_helpers(b) != [], 30), "Alt+I (Sign in) started the login helper", b)
            line = "zigBrowser: ZIGBROWSER_AGENT_CLAUDE_CLI ignored without --e2e-protocol"
            check(b.wait(lambda: line in b.err, 5) and [l for l in b.err if l == line] == [line], f"one line: {line}", b)
            for pid in login_helpers(b):
                check("--e2e-claude-cli" not in argv_of(pid), f"no --e2e-claude-cli in pid {pid}'s cmdline")
                try:
                    environ = Path(f"/proc/{pid}/environ").read_bytes()
                except OSError:
                    environ = b""
                check(b"ZIGBROWSER_AGENT_CLAUDE_CLI" not in environ, f"pid {pid}'s environment has no such variable")
            time.sleep(5)
            check(not (markers / "cli.ran").exists(), "the marker CLI never ran")
        finally:
            b.stop()


CASES = {
    "paste-sign-in": case_paste_sign_in,
    "malformed": case_malformed,
    "foreign-state": case_foreign_state,
    "link": case_link,
    "during-sign-in": case_during_sign_in,
    "cancel": case_cancel,
    "close": case_close,
    "error-network": case_error_network,
    "error-store": case_error_store,
    "inert": case_inert,
}


def main() -> int:
    return run_main(__doc__, CASES)


if __name__ == "__main__":
    sys.exit(main())
