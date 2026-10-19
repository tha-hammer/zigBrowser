"""S6b1 (chat-drawer plan rev 16.18.3, S6.1 inertness and S6.4): "Sign in with Claude.ai"
in the Secrets window, through the paste path, end to end.

The browser runs the real login helper (`launch --command login`) in its sandbox, with
its own login netd (runtime/net-login.json, `<chat sockdir>-login`, egress only). Under
--e2e-protocol, ZIGBROWSER_AGENT_CLAUDE_CLI names tests/e2e/fake_claude_setup_token.py,
which replays the real CLI's capture and writes its state under the agent home's
scratchpad. A test types `<code>#<state>` into the window's code entry with real X input,
as a user pastes the code page's text.

Rows (D7b, rev 16.18.3):
- `SECRETS rect <signin|code|send-code|cancel> <x,y,w,h>`;
- `SECRETS login <starting|need-code|done|error-<code>|cancelled>`;
- `SECRETS status`, as in S4.

Cases (run alone or with --only):
- paste-sign-in: the token printed by the fake reaches the private keyring through
  fd 4, `SECRETS login done` and `SECRETS status connected-secret-service` appear, the
  fake received exactly that code, no login netd or `-login` directory remains, and
  the canary is nowhere else;
- foreign-state: a code with another state is refused by the CLI and asked for
  again (a second `need-code`); the right one then signs in;
- during-sign-in: while the sign-in waits for a code, the login netd's directory has
  egress/ only, and chat's netd still refuses CONNECT platform.claude.com:443;
- cancel: Cancel ends the sign-in (`SECRETS login cancelled`), nothing is stored, and
  no login helper, login netd or `-login` directory remains;
- close: closing the Secrets window does the same;
- inert: without --e2e-protocol, ZIGBROWSER_AGENT_CLAUDE_CLI is ignored, with one
  stderr line; the login helper's cmdline has no --e2e-claude-cli, its environment
  has no such variable, and the marker script never runs. The browser runs in a
  network namespace with no network, and Sign in is reached by its mnemonic (Alt+I),
  since there are no rows to aim at."""

import os
import shutil
import subprocess
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
LOGIN_ERRORS = ("cli", "timeout", "cancelled", "shape", "protocol", "network", "store")


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


def rect(b, name: str):
    found = [f[1] for f in rows(b, "rect") if len(f) == 2 and f[0] == name]
    if not found:
        return None
    r = tuple(int(v) for v in found[-1].split(","))
    return r if r[2] > 0 and r[3] > 0 else None


def statuses(b) -> list[str]:
    return [f[0] for f in rows(b, "status")]


# --- X input -----------------------------------------------------------------------------
def type_code(b, text: str) -> None:
    """Real key presses on the US layout: '#' and '_' are Shift with their own keys."""
    for ch in text:
        if ch in "#_":
            b.x.key(ch, ("Shift_L",), settle=0.005)
        elif "A" <= ch <= "Z":
            b.x.key(ch.lower(), ("Shift_L",), settle=0.005)
        else:
            b.x.key(ch, settle=0.005)


# --- the world ---------------------------------------------------------------------------
class SignIn:
    """A provisioned agent home whose scratchpad holds the fake's token, a private keyring,
    and the browser launched with the fake setup-token CLI."""

    def __init__(self, binary: Path, tmp: Path, name: str, e2e_cli: bool = True) -> None:
        self.token = sec.canary()
        self.world = sec.provisioned(binary, tmp, name)
        self.fake_dir = self.world.agent / "scratchpad" / ".zb-fake-setup-token"
        self.fake_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        (self.fake_dir / "token").write_text(self.token + "\n", encoding="ascii")
        base_env = self.world.env
        self.world.env = lambda extra=None: dict(base_env(extra), ZIGBROWSER_AGENT_CLAUDE_CLI=str(FAKE))
        self.kr = sec.PrivateKeyring(tmp)
        self.api = sec.fake_api(tmp).__enter__()
        self.b = sec.launch(binary, tmp, self.world, self.kr.bus_env, self.api, name)
        self.runtime = Path(self.kr.bus_env["XDG_RUNTIME_DIR"])

    def close(self) -> None:
        try:
            self.b.stop()
        finally:
            self.api.__exit__(None, None, None)
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

    def open_and_sign_in(self, check) -> bool:
        """Send with no token opens the Secrets window; a click on Sign in starts it."""
        b = self.b
        sec.send_prompt(b, "hello")
        if not check(b.wait(lambda: statuses(b)[:1] == ["empty"], 20), "Send with no token opens the Secrets window", b):
            return False
        if not check(b.wait(lambda: rect(b, "signin") is not None, 15), "SECRETS rect signin", b):
            return False
        sec.click_rect(b, rect(b, "signin"))
        check(b.wait(lambda: login_states(b)[:1] == ["starting"], 15), "SECRETS login starting", b)
        return check(b.wait(lambda: "need-code" in login_states(b) and self.state() is not None
                            and rect(b, "code") is not None, 60),
                     "SECRETS login need-code, the code entry is shown and the fake wrote its state", b)

    def paste(self, code: str) -> None:
        b = self.b
        sec.click_rect(b, rect(b, "code"))
        type_code(b, code)
        sec.click_rect(b, rect(b, "send-code"))


def login_dirs(runtime: Path) -> list[Path]:
    return sorted(p for p in runtime.glob("zigbrowser-agent-*-login"))


def chat_dirs(runtime: Path) -> list[Path]:
    return sorted(p for p in runtime.glob("zigbrowser-agent-*") if not p.name.endswith("-login"))


def procs(*needles: str) -> list[int]:
    """Live processes whose cmdline holds every needle."""
    found = []
    for pid in filter(str.isdigit, os.listdir("/proc")):
        try:
            argv = Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0")
        except OSError:
            continue
        text = [a.decode(errors="replace") for a in argv]
        if all(any(n in a for a in text) for n in needles):
            found.append(int(pid))
    return found


def login_netds(runtime: Path) -> list[int]:
    return [p for p in procs("netd.py", "--sockdir") if any(f"{runtime}/" in a and a.endswith("-login")
                                                             for a in argv_of(p))]


def login_helpers() -> list[int]:
    return [p for p in procs("zb_agent_host", "login") if "--command" in argv_of(p) or "login" in argv_of(p)[-3:]]


def argv_of(pid: int) -> list[str]:
    try:
        return [a.decode(errors="replace") for a in Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0") if a]
    except OSError:
        return []


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


def nothing_left(si: SignIn, check, label: str) -> None:
    b = si.b
    check(b.wait(lambda: login_netds(si.runtime) == [], 15), f"{label}: no login netd remains", b)
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
        check(login_states(b).count("done") == 1 and not any(s.startswith("error-") for s in login_states(b)),
              f"exactly one ending: {login_states(b)}", b)
        nothing_left(si, check, "after done")
        (si.fake_dir / "token").unlink()  # the test's own input: the CLI's copy, not the browser's
        found = sec.scan_for(si.token, b, si.world, si.api)
        check(found == [], f"the token is nowhere but the keyring: {found}", b)
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
        check(statuses(b)[-1:] == ["empty"], "nothing was stored", b)
        code = f"fakecode#{si.state()}"
        si.paste(code)
        check(b.wait(lambda: statuses(b)[-1:] == ["connected-secret-service"], 30),
              "the right code then signs in", b)
        check(si.codes() == ["fakecode#" + "A" * 43, code], f"the fake received both, in order ({si.codes()})")
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
        check(len(login_netds(si.runtime)) == 1, "one login netd runs", b)
        chats = chat_dirs(si.runtime)
        if chats:
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
        check(statuses(b)[-1:] == ["empty"] and si.kr.lookup() is None, "nothing was stored", b)
        check(si.codes() == [], "the fake received no code")
        check(b.wait(lambda: login_helpers() == [], 15), "no login helper remains", b)
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
        check(si.kr.lookup() is None, "nothing was stored")
        nothing_left(si, check, "after close")
    finally:
        si.close()


def case_inert(binary: Path, tmp: Path, check) -> None:
    """S6.1 inertness: no --e2e-protocol, no network at all (a fresh user+net namespace)."""
    from agent_common import Browser
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
            from agent_host_lifecycle_test import icon_centre
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
            b.x.key("i", ("Alt_L",))
            check(b.wait(lambda: login_helpers() != [], 30), "Alt+I (Sign in) started the login helper", b)
            line = "zigBrowser: ZIGBROWSER_AGENT_CLAUDE_CLI ignored without --e2e-protocol"
            check(b.wait(lambda: line in b.err, 5) and [l for l in b.err if l == line] == [line], f"one line: {line}", b)
            for pid in login_helpers():
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
    "foreign-state": case_foreign_state,
    "during-sign-in": case_during_sign_in,
    "cancel": case_cancel,
    "close": case_close,
    "inert": case_inert,
}


def main() -> int:
    return run_main(__doc__, CASES)


if __name__ == "__main__":
    sys.exit(main())
