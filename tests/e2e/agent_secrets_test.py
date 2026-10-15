#!/usr/bin/env python3
"""Chat drawer S4: the Secrets window, the token store and the handoff
(thoughts/searchable/shared/plans/2026-10-13-claude-agent-chat-drawer-tdd-plan.md,
S4.1-S4.4; threat tests A1, A3, T6 part 1).

Closure test S4, "a token saved in the Secrets window reaches only the
Claude process": the canary is typed with real X keyboard events into the
Secrets window's entry (never the clipboard), saved with a real X click,
and observed at the boundaries only: the fake Messages API's recorded
`authorization` header, the private keyring read through the Secret Service
API, the 0600 file, and the canary scanner (process environs and cmdlines,
stdout/stderr, rows, files under the agent home and the profile).

The test never calls the store, never writes the store file or the keyring,
and never writes the helper's fd 3 (FORBIDDEN in the plan).

Network (plan rev 16.2, §3c): the agent has no route but netd. The fake
Messages API serves TLS as fake.zb.invalid on a private port; the browser's
e2e-only seams (with --e2e-protocol) give netd `--test-allow
fake.zb.invalid=<port>` and both bridges' private decoy ports
(ZIGBROWSER_AGENT_NET_TEST), and the CLI the fake's test CA
(ZIGBROWSER_AGENT_NET_TEST_CA). So every recorded request came through relay
-> netd -> CONNECT, as in production. The token reaches the CLI only on fd 3
(R1; the env route is gone, rev 16): the scanner allows it in no process
environment at all. S4.4's hooks each run in their own sealed network and
must reach both bridges and nothing else (agent_hook_net, §3c.8b).

The keyring is always private: its own dbus-daemon and gnome-keyring-daemon,
with HOME, XDG_DATA_HOME and XDG_RUNTIME_DIR in the test's temp directory.
The browser never reaches the user's session bus: it gets either the private
address or, in the no-keyring cases, an explicitly dead address together with
a private, empty XDG_RUNTIME_DIR (merely unsetting DBUS_SESSION_BUS_ADDRESS
is not enough: libsecret then falls back to $XDG_RUNTIME_DIR/bus, the user's
real session). `assert_not_user_bus` checks every environment before launch.
Canary tokens only.

Exit 1 (never 77) when Xvfb, xauth, libXtst, dbus-daemon,
gnome-keyring-daemon or the binary is missing."""

from __future__ import annotations

import json
import os
import re
import secrets
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

SECRETS_STATES = ("empty", "connected-secret-service", "connected-file", "no-keyring", "rejected")
SECRETS_CONTROLS = ("entry", "save", "remove", "file")
# Every sentence the status line may show (src/agent_secrets_window.c): never the token.
SECRETS_TEXTS = ("No token is stored.", "Connected. The token is stored in the system keyring.",
                 "Connected. The token is stored in a private file.", "That doesn't look like a token.",
                 "No system keyring is available. Nothing was stored.", "Saving...",
                 "The token could not be saved.", "The token could not be removed.")


def canary() -> str:
    """A canary the X keyboard can type without Shift (lowercase, digits, '-')."""
    return "sk-ant-oat01-zbcanary-" + secrets.token_hex(20)


def leaks(text: str, token: str, run: int = 4) -> list[str]:
    """Every run of `run` or more consecutive characters of `token` found in `text`."""
    found = []
    for i in range(len(token) - run + 1):
        piece = token[i:i + run]
        if piece in text:
            found.append(piece)
    return found


# --- SECRETS rows ----------------------------------------------------------------
class SecretsRowError(AssertionError):
    pass


def parse_secrets_row(line: str) -> tuple[str, tuple[str, ...]]:
    """`SECRETS status <state>`, `SECRETS text <sentence>`, `SECRETS tree <types>` or
    `SECRETS rect <control> <x,y,w,h>`; anything else raises SecretsRowError."""
    parts = line.split("\t")
    if parts[0] != "SECRETS" or len(parts) < 3:
        raise SecretsRowError(f"not a SECRETS row: {line!r}")
    kind, fields = parts[1], tuple(parts[2:])
    ok = (kind == "status" and len(fields) == 1 and fields[0] in SECRETS_STATES) or \
         (kind == "text" and len(fields) == 1 and fields[0] in SECRETS_TEXTS) or \
         (kind == "tree" and len(fields) == 1 and re.fullmatch(r"[A-Za-z0-9_]+(,[A-Za-z0-9_]+)*", fields[0])) or \
         (kind == "rect" and len(fields) == 2 and fields[0] in SECRETS_CONTROLS
          and re.fullmatch(r"-?\d+,-?\d+,\d+,\d+", fields[1]))
    if not ok:
        raise SecretsRowError(f"malformed SECRETS row: {line!r}")
    return kind, fields


def secrets_rows(lines: list[str]) -> list[tuple[str, tuple[str, ...]]]:
    return [parse_secrets_row(line) for line in lines if line.startswith("SECRETS\t")]


# --- the session bus the browser may use ------------------------------------------------
DEAD_BUS = "unix:path=/nonexistent/zigbrowser-test-no-session-bus"


def no_session_bus_env(env: dict[str, str], tmp: Path) -> dict[str, str]:
    """`env` with no usable session bus: a dead address and a private, empty runtime dir."""
    run = Path(tempfile.mkdtemp(prefix="run-", dir=tmp))
    run.chmod(0o700)
    return dict(env, DBUS_SESSION_BUS_ADDRESS=DEAD_BUS, XDG_RUNTIME_DIR=str(run))


def assert_not_user_bus(env: dict[str, str]) -> None:
    """Refuses an environment through which libsecret could reach the user's session bus."""
    user_runtime = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
    address = env.get("DBUS_SESSION_BUS_ADDRESS")
    if address is None or address == os.environ.get("DBUS_SESSION_BUS_ADDRESS") or user_runtime in address:
        raise AssertionError(f"refusing to launch: the session bus address {address!r} may be the user's own")
    runtime = env.get("XDG_RUNTIME_DIR")
    if runtime is None or os.path.realpath(runtime) == os.path.realpath(user_runtime):
        raise AssertionError(f"refusing to launch: XDG_RUNTIME_DIR {runtime!r} is the user's own")


# --- a private keyring --------------------------------------------------------------
class PrivateKeyring:
    """A private session bus with an unlocked gnome-keyring on it. `env` is what a
    process needs to use it; `lookup()` reads the token item through libsecret's own
    API (gi Secret), in a separate process on that bus."""

    SCHEMA = "dev.zigbrowser.ClaudeAgentToken"

    def __init__(self, tmp: Path) -> None:
        # Short paths: the keyring's control socket lives in XDG_RUNTIME_DIR.
        self.root = Path(tempfile.mkdtemp(prefix="zbkr-", dir="/tmp"))
        (self.root / "home").mkdir()
        (self.root / "run").mkdir(mode=0o700)
        self.base = {"PATH": "/usr/bin:/bin", "HOME": str(self.root / "home"),
                     "XDG_DATA_HOME": str(self.root / "home/.local/share"), "XDG_RUNTIME_DIR": str(self.root / "run")}
        out = subprocess.run(["dbus-daemon", "--session", "--fork", "--print-address=1", "--print-pid=1"],
                             env=self.base, capture_output=True, text=True, timeout=20, check=True).stdout.split()
        self.address, self.dbus_pid = out[0], int(out[1])
        self.env = dict(self.base, DBUS_SESSION_BUS_ADDRESS=self.address)
        # What the browser takes from it: only the bus and the runtime dir (its HOME and
        # XDG_DATA_HOME stay the world's, where the provisioned agent home is).
        self.bus_env = {"DBUS_SESSION_BUS_ADDRESS": self.address, "XDG_RUNTIME_DIR": self.base["XDG_RUNTIME_DIR"]}
        subprocess.run(["gnome-keyring-daemon", "--unlock", "--components=secrets"], input="zb-test-keyring",
                       env=self.env, capture_output=True, text=True, timeout=20)
        deadline = time.monotonic() + 10
        while not self._name_owned():
            if time.monotonic() > deadline:
                self.close()
                raise RuntimeError("the private keyring did not start")
            time.sleep(0.1)

    def _gdbus(self, method: str, *args: str) -> str:
        return subprocess.run(["gdbus", "call", "--session", "--dest", "org.freedesktop.DBus", "--object-path",
                               "/org/freedesktop/DBus", "--method", f"org.freedesktop.DBus.{method}", *args],
                              env=self.env, capture_output=True, text=True, timeout=10).stdout

    def _name_owned(self) -> bool:
        return "true" in self._gdbus("NameHasOwner", "org.freedesktop.secrets")

    def lookup(self) -> str | None:
        code = ("import gi, sys; gi.require_version('Secret', '1'); from gi.repository import Secret\n"
                f"s = Secret.Schema.new({self.SCHEMA!r}, Secret.SchemaFlags.NONE,"
                " {'account': Secret.SchemaAttributeType.STRING})\n"
                "v = Secret.password_lookup_sync(s, {'account': 'default'}, None)\n"
                "sys.stdout.write('' if v is None else v)")
        done = subprocess.run(["/usr/bin/python3", "-I", "-c", code], env=self.env, capture_output=True, text=True,
                              timeout=20)
        if done.returncode != 0:
            raise RuntimeError(f"keyring lookup failed: {done.stderr.strip()[-300:]}")
        return done.stdout or None

    def close(self) -> None:
        owner = re.search(r"uint32 (\d+)", self._gdbus("GetConnectionUnixProcessID", "org.freedesktop.secrets"))
        for pid in ([int(owner.group(1))] if owner else []) + [self.dbus_pid]:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        time.sleep(0.2)
        shutil.rmtree(self.root, ignore_errors=True)

    def __enter__(self) -> "PrivateKeyring":
        return self

    def __exit__(self, *_exc) -> None:
        self.close()


# --- the browser under test -----------------------------------------------------------
def fake_api(tmp: Path, turns=None):
    """The fake Messages API over TLS as fake.zb.invalid (§3c.4), with a throwaway cert."""
    from fake_anthropic_api import FakeAnthropicApi, make_test_cert
    return FakeAnthropicApi(turns, tls=make_test_cert(Path(tempfile.mkdtemp(prefix="tls-", dir=tmp))))


def net_test_env(api, decoys) -> dict[str, str]:
    """The app-owned e2e seams (honoured only with --e2e-protocol): netd's test options
    (fake.zb.invalid -> the fake API's private port; both bridges -> private decoys), the
    fake's CA for the CLI, and the CLI's base URL, which it then dials through the proxy."""
    from fake_anthropic_api import FAKE_HOST
    args = ["--test-allow", f"{FAKE_HOST}={api.port}",
            "--test-bridge", f"51091={decoys.bridges[51091].port}",
            "--test-bridge", f"31337={decoys.bridges[31337].port}"]
    return {"ZIGBROWSER_AGENT_NET_TEST": " ".join(args), "ZIGBROWSER_AGENT_NET_TEST_CA": str(api.tls[0]),
            "ZIGBROWSER_AGENT_TEST_BASE_URL": f"https://{FAKE_HOST}"}


def launch(binary: Path, tmp: Path, world, bus_env: dict[str, str], api, label: str, args: list[str] = ()):
    """zigBrowser with the drawer on, the provisioned agent home of `world` (S3a), the TLS
    fake Messages API reached only through netd, private bridge decoys (b.decoys), and exactly
    the session bus `bus_env` gives it (a private keyring's, or a dead one)."""
    from agent_common import Browser
    from agent_hook_net import HookNetDecoys
    from slice2_common import isolate_profile_env

    decoys = HookNetDecoys()
    env = isolate_profile_env(dict(os.environ))
    env.update(world.env())
    env.update(bus_env)
    env.update(net_test_env(api, decoys))
    assert_not_user_bus(env)
    b = Browser(binary, tmp, label, ["--agent-drawer", "on", *args], env=env)
    b.decoys = decoys
    stop = b.stop

    def stop_all(*a, **k):
        try:
            return stop(*a, **k)
        finally:
            decoys.close()
    b.stop = stop_all
    return b


def secrets_lines(b) -> list[tuple[str, tuple[str, ...]]]:
    return secrets_rows(list(b.out))


def secrets_status(b) -> list[str]:
    return [f[0] for k, f in secrets_lines(b) if k == "status"]


def secrets_rect(b, name: str) -> tuple[int, int, int, int] | None:
    rects = [f[1] for k, f in secrets_lines(b) if k == "rect" and f[0] == name]
    return tuple(int(v) for v in rects[-1].split(",")) if rects else None  # type: ignore[return-value]


def click_rect(b, r: tuple[int, int, int, int]) -> None:
    b.x.click(r[0] + r[2] // 2, r[1] + r[3] // 2)


def type_text(b, text: str) -> None:
    for ch in text:
        b.x.key({" ": "space", "\n": "Return", "\t": "Tab"}.get(ch, ch), settle=0.005)


def send_prompt(b, text: str) -> None:
    """Opens the drawer with an X click on the icon (if closed), or else clicks back into its
    input (the Secrets window may hold the focus), then types `text` and presses Enter."""
    from agent_common import centre
    if not b.rows("open", 1):
        icon = b.wait_row("icon", 1)
        b.x.click(*centre(tuple(int(v) for v in icon.fields[0].split(","))))
        b.wait_row("open", 1, timeout=10)
    else:
        focused = len(b.rows("focus", 1))
        x, y, w, h = b.rows("open", 1)[-1].rect()
        b.x.click(x + w // 3, y + h - 24)  # the input row runs along the panel's bottom edge
        b.wait(lambda: any(r.fields[:1] == ("input",) for r in b.rows("focus", 1)[focused:]), 5)
    type_text(b, text)
    b.x.key("Return")


def entry_pixels(b) -> list[tuple[int, int, int]]:
    """The Secrets entry's pixels, from a capture of the Secrets window itself (`xwd -id`):
    on the private Xvfb a root capture shows that window's area black, while the window's
    own contents are drawn (found on the S4a green run)."""
    from xinput import Capture
    wins = b.x.toplevels("Claude Agent account")
    if not wins:
        raise AssertionError("no Secrets window to capture")
    window, wx, wy, _w, _h = wins[-1]
    env = dict(os.environ, XAUTHORITY=b.x.xauth)
    done = subprocess.run(["xwd", "-id", str(window), "-silent", "-display", b.x.display_name],
                          capture_output=True, env=env, timeout=30, check=True)
    shot = Capture(done.stdout)
    x0, y0, w, h = secrets_rect(b, "entry")
    x0, y0 = x0 - wx, y0 - wy
    return [shot.pixel(x, y) for y in range(y0 + 4, y0 + h - 4, 3) for x in range(x0 + 4, x0 + w - 4, 3)]


def dark(pixels: list[tuple[int, int, int]]) -> int:
    """How many sampled pixels are dark: a stored token's 16 or more bullets give about a
    hundred; a text cursor (which may blink in or out between captures) only a few."""
    return sum(1 for r, g, b in pixels if r + g + b < 384)


class ClipboardOwner:
    """Owns the private Xvfb's CLIPBOARD with `text` (a GTK process on that display), so a
    real Ctrl+V pastes it. Only for strings that are not secrets: a canary is always typed."""

    CODE = ("import sys, gi; gi.require_version('Gtk', '3.0'); from gi.repository import Gtk, Gdk, GLib\n"
            "c = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD); c.set_text(sys.argv[1], -1); c.store()\n"
            "GLib.io_add_watch(sys.stdin, GLib.IO_IN | GLib.IO_HUP, lambda *a: Gtk.main_quit())\n"
            "print('ready', flush=True); Gtk.main()")

    def __init__(self, b, text: str) -> None:
        env = {"PATH": "/usr/bin:/bin", "DISPLAY": b.x.display_name, "XAUTHORITY": b.x.xauth,
               "HOME": str(b.dir), "NO_AT_BRIDGE": "1"}
        self.proc = subprocess.Popen(["/usr/bin/python3", "-I", "-c", self.CODE, text], env=env, text=True,
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        if self.proc.stdout.readline().strip() != "ready":
            self.close()
            raise RuntimeError("the clipboard owner did not start")

    def close(self) -> None:
        self.proc.stdin.close()
        try:
            self.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()
        self.proc.stdout.close()


def paste_and_save_bad(b, text: str) -> None:
    """Pastes the non-secret `text` (newlines kept: a real multi-line paste) into the Secrets
    entry with a real Ctrl+V from the private display's clipboard, then clicks Save."""
    b.wait(lambda: secrets_rect(b, "save") is not None and secrets_rect(b, "save")[2] > 0, 15)
    owner = ClipboardOwner(b, text)
    try:
        click_rect(b, secrets_rect(b, "entry"))
        b.x.key("v", ("Control_L",))
        time.sleep(0.3)
    finally:
        owner.close()
    click_rect(b, secrets_rect(b, "save"))


def paste_and_save(b, token: str) -> None:
    """Types `token` into the Secrets entry and clicks Save, all with real X input."""
    b.wait(lambda: secrets_rect(b, "save") is not None and secrets_rect(b, "save")[2] > 0, 15)
    click_rect(b, secrets_rect(b, "entry"))
    type_text(b, token)
    click_rect(b, secrets_rect(b, "save"))


def scan_for(token: str, b, world, api) -> list[str]:
    """Every place the canary turned up that the plan forbids (S4.2, T6): any process environ
    or cmdline (R1 only: the CLI gets it on fd 3, never in an environment; rev 16), stdout,
    stderr and rows, files under the agent home other than the store and under the profile,
    recorded request bodies, and the page's DOM and localStorage. The fake API's
    `authorization` header is the one allowed place."""
    found = []
    needle = token.encode()
    for pid in filter(str.isdigit, os.listdir("/proc")):
        for part in ("environ", "cmdline"):
            try:
                data = Path(f"/proc/{pid}/{part}").read_bytes()
            except OSError:
                continue
            if needle in data:
                found.append(f"/proc/{pid}/{part}")
    text = "\n".join(b.out + b.err)
    if leaks(text, token):
        found.append(f"stdout/stderr ({leaks(text, token)[:2]})")
    store = world.agent / "secrets" / "claude-token"
    for root in (world.agent, b.dir):
        for path in root.rglob("*"):
            try:
                if path.is_file() and not path.is_symlink() and path != store and needle in path.read_bytes():
                    found.append(str(path))
            except OSError:
                continue
    for request in api.requests:
        if token in str(request.get("body")):
            found.append(f"request body {request['path']}")
    try:
        page = b.ev("document.documentElement.outerHTML + JSON.stringify(Object.entries(localStorage))")
    except Exception as exc:  # noqa: BLE001 - an unreadable page is itself a finding
        page = f"<page unreadable: {exc}>"
        found.append(page)
    if token in str(page):
        found.append("the page's DOM or localStorage")
    return found


# --- the cases ------------------------------------------------------------------------------
def provisioned(binary: Path, tmp: Path, name: str):
    import agent_setup_test
    from agent_common import host_python
    from agent_setup_test import World, run_setup
    agent_setup_test.PYTHON = host_python()  # World.env reads it (set only by that file's main)
    world = World(tmp, name)
    rc, _out, err, _events, _seen = run_setup(binary, world)
    if rc != 0:
        raise AssertionError(f"--agent-setup failed: {err.strip()[-300:]}")
    return world


def case_secret_service(binary: Path, tmp: Path, check) -> None:
    """S4.1: with no stored token, Send opens the Secrets window; a canary typed there and
    saved lands in the private keyring, the entry is emptied, and no run of it is shown."""
    token = canary()
    world = provisioned(binary, tmp, "service")
    with PrivateKeyring(tmp) as kr, fake_api(tmp) as api:
        b = launch(binary, tmp, world, kr.bus_env, api, "service")
        try:
            send_prompt(b, "hello")
            check(b.wait(lambda: secrets_status(b)[:1] == ["empty"], 20), "Send with no token opens the Secrets window", b)
            empty = entry_pixels(b)
            paste_and_save(b, token)
            check(b.wait(lambda: secrets_status(b)[-1:] == ["connected-secret-service"], 20),
                  "SECRETS status connected-secret-service", b)
            after = entry_pixels(b)
            check(dark(after) <= dark(empty) + 12, f"the entry is empty again after Save (dark {dark(empty)} -> {dark(after)})", b)
            check(kr.lookup() == token, "the private keyring holds the item (read through the Secret Service API)")
            check(not (world.agent / "secrets" / "claude-token").exists(), "no token file (the keyring was chosen)")
            check(not leaks("\n".join(b.out + b.err), token), "no run of the canary in rows, stdout or stderr", b)
            texts = [f[0] for k, f in secrets_lines(b) if k == "text"]
            check(texts != [] and all(t in SECRETS_TEXTS for t in texts),
                  f"the window's status line showed only its fixed sentences: {texts}", b)
        finally:
            b.stop()


def case_handoff(binary: Path, tmp: Path, check) -> None:
    """S4.2 (A1, T6; S4b, after S3b's helper): the stored canary reaches only the CLI, as its
    bearer at the fake API, and nowhere else."""
    token = canary()
    world = provisioned(binary, tmp, "handoff")
    with PrivateKeyring(tmp) as kr, fake_api(tmp, [{"text": "Scripted reply."}] * 4) as api:
        b = launch(binary, tmp, world, kr.bus_env, api, "handoff")
        try:
            send_prompt(b, "hello")
            b.wait(lambda: secrets_status(b)[:1] == ["empty"], 20)
            paste_and_save(b, token)
            check(b.wait(lambda: secrets_status(b)[-1:] == ["connected-secret-service"], 20),
                  "SECRETS status connected-secret-service", b)
            send_prompt(b, "hello again")
            check(b.wait(lambda: any(r["headers"].get("authorization") == f"Bearer {token}" for r in api.messages_requests()), 60),
                  "the fake API received Bearer <canary>", b)
            check(scan_for(token, b, world, api) == [], f"the canary is nowhere else: {scan_for(token, b, world, api)}", b)
        finally:
            b.stop()


def case_file_flag(binary: Path, tmp: Path, check) -> None:
    """S4.1 with --agent-secret-store file: a 0600 file in a 0700 directory."""
    token = canary()
    world = provisioned(binary, tmp, "file")
    with fake_api(tmp) as api:
        b = launch(binary, tmp, world, no_session_bus_env({}, tmp), api, "file", ["--agent-secret-store", "file"])
        try:
            send_prompt(b, "hello")
            check(b.wait(lambda: secrets_status(b)[:1] == ["empty"], 20), "the Secrets window opens", b)
            paste_and_save(b, token)
            check(b.wait(lambda: secrets_status(b)[-1:] == ["connected-file"], 20), "SECRETS status connected-file", b)
            store = world.agent / "secrets" / "claude-token"
            check(store.is_file() and stat.S_IMODE(store.stat().st_mode) == 0o600, "the file is 0600")
            check(stat.S_IMODE(store.parent.stat().st_mode) == 0o700, "its directory is 0700")
            check(store.is_file() and store.read_text().rstrip("\n") == token, "it holds the canary")
            check(not leaks("\n".join(b.out + b.err), token), "no run of the canary in stdout/stderr", b)
        finally:
            b.stop()


def case_rejected(binary: Path, tmp: Path, check) -> None:
    """S4.1 edge: whitespace or a multi-line paste is rejected and nothing is stored."""
    world = provisioned(binary, tmp, "reject")
    with PrivateKeyring(tmp) as kr, fake_api(tmp) as api:
        b = launch(binary, tmp, world, kr.bus_env, api, "reject")
        try:
            send_prompt(b, "hello")
            b.wait(lambda: secrets_status(b)[:1] == ["empty"], 20)
            for i, bad in enumerate(("sk-ant-oat01 zbcanary-with-a-space", "sk-ant-oat01-zbcanary-two\nlines-0123")):
                (paste_and_save_bad if "\n" in bad else paste_and_save)(b, bad)
                check(b.wait(lambda n=i: secrets_status(b).count("rejected") >= n + 1, 15), f"rejected: {bad!r}", b)
            check(kr.lookup() is None, "nothing in the keyring")
            check(not (world.agent / "secrets" / "claude-token").exists(), "no token file")
        finally:
            b.stop()


def case_no_keyring(binary: Path, tmp: Path, check) -> None:
    """S4.1 edge: no Secret Service and no flag: Save stores nothing; only an X click on
    "Save to a private file instead" writes the 0600 file."""
    token = canary()
    world = provisioned(binary, tmp, "nokeyring")
    with fake_api(tmp) as api:
        b = launch(binary, tmp, world, no_session_bus_env({}, tmp), api, "nokeyring")
        try:
            send_prompt(b, "hello")
            check(b.wait(lambda: secrets_status(b)[:1] == ["no-keyring"], 20), "the window says no keyring", b)
            check(secrets_rect(b, "file") in (None, (0, 0, 0, 0)), "no file choice before a Save", b)
            paste_and_save(b, token)
            store = world.agent / "secrets" / "claude-token"
            check(b.wait(lambda: secrets_status(b).count("no-keyring") >= 2, 15) and not store.exists(),
                  "Save stores nothing", b)
            check(b.wait(lambda: (secrets_rect(b, "file") or (0, 0, 0, 0))[2] > 0, 10), "the file choice is offered", b)
            click_rect(b, secrets_rect(b, "file"))
            check(b.wait(lambda: secrets_status(b)[-1:] == ["connected-file"], 15), "the X click stores to the file", b)
            check(store.is_file() and stat.S_IMODE(store.stat().st_mode) == 0o600 and store.read_text() == token,
                  "a 0600 file with the canary")
            click_rect(b, secrets_rect(b, "remove"))
            check(b.wait(lambda: secrets_status(b)[-1:] == ["empty"], 15) and not store.exists(),
                  "Remove with the file active and no keyring reachable: the file goes, and that is success", b)
        finally:
            b.stop()


def case_remove(binary: Path, tmp: Path, check) -> None:
    """S4.1 edge: Remove deletes the keyring item and the file, and the next Send reopens the
    Secrets window."""
    token = canary()
    world = provisioned(binary, tmp, "remove")
    with PrivateKeyring(tmp) as kr, fake_api(tmp) as api:
        b = launch(binary, tmp, world, kr.bus_env, api, "remove")
        try:
            send_prompt(b, "hello")
            b.wait(lambda: secrets_status(b)[:1] == ["empty"], 20)
            paste_and_save(b, token)
            check(b.wait(lambda: secrets_status(b)[-1:] == ["connected-secret-service"], 20), "stored", b)
            check(b.wait(lambda: (secrets_rect(b, "remove") or (0, 0, 0, 0))[2] > 0, 10), "Remove is shown", b)
            click_rect(b, secrets_rect(b, "remove"))
            check(b.wait(lambda: secrets_status(b)[-1:] == ["empty"], 15), "Remove: SECRETS status empty", b)
            check(kr.lookup() is None, "the keyring item is gone")
            check(not (world.agent / "secrets" / "claude-token").exists(), "no token file")
            before = len(secrets_lines(b))
            send_prompt(b, "and again")
            check(b.wait(lambda: any(k == "status" for k, _f in secrets_lines(b)[before:]), 15),
                  "the next Send reopens the Secrets window", b)
        finally:
            b.stop()


def case_remove_session(binary: Path, tmp: Path, check) -> None:
    """S4.2 edge (S4b, after S3b's helper): removing the token while a session runs ends the
    session, so the Claude CLI exits, and the next Send reopens the Secrets window."""
    token = canary()
    world = provisioned(binary, tmp, "remove-session")
    with PrivateKeyring(tmp) as kr, fake_api(tmp, [{"text": "Scripted reply."}] * 4) as api:
        b = launch(binary, tmp, world, kr.bus_env, api, "remove-session")
        try:
            send_prompt(b, "hello")
            b.wait(lambda: secrets_status(b)[:1] == ["empty"], 20)
            paste_and_save(b, token)
            b.wait(lambda: secrets_status(b)[-1:] == ["connected-secret-service"], 20)
            send_prompt(b, "start a session")
            check(b.wait(lambda: api.messages_requests(), 60), "a session ran", b)
            click_rect(b, secrets_rect(b, "remove"))
            check(b.wait(lambda: secrets_status(b)[-1:] == ["empty"], 15), "Remove: SECRETS status empty", b)
            check(kr.lookup() is None, "the keyring item is gone")
            check(b.wait(lambda: not any(needle_in_proc(token)), 15), "the Claude CLI holding the session has exited", b)
            before = len(secrets_lines(b))
            send_prompt(b, "and again")
            check(b.wait(lambda: any(k == "status" for k, _f in secrets_lines(b)[before:]), 15),
                  "the next Send reopens the Secrets window", b)
        finally:
            b.stop()


# --- RoseCat 5648: the active store, stale completions, the opening lookup, Remove ------------
DELAY_ENV = "ZIGBROWSER_AGENT_SECRETS_TEST_DELAY"


def close_secrets_window(b) -> None:
    """Closes the Secrets window the way a window manager's close button does: a
    WM_PROTOCOLS/WM_DELETE_WINDOW client message (there is no window manager on the private
    Xvfb). GTK answers it with delete-event, then destroys the window."""
    import ctypes

    class ClientMessage(ctypes.Structure):
        _fields_ = [("type", ctypes.c_int), ("serial", ctypes.c_ulong), ("send_event", ctypes.c_int),
                    ("display", ctypes.c_void_p), ("window", ctypes.c_ulong), ("message_type", ctypes.c_ulong),
                    ("format", ctypes.c_int), ("data", ctypes.c_long * 5)]

    class Event(ctypes.Union):
        _fields_ = [("xclient", ClientMessage), ("pad", ctypes.c_long * 24)]

    x, dpy = b.x._x, b.x._dpy
    x.XInternAtom.restype = ctypes.c_ulong
    x.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
    x.XSendEvent.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_long, ctypes.c_void_p]
    window = b.x.toplevels("Claude Agent account")[-1][0]
    event = Event()
    event.xclient.type = 33  # ClientMessage
    event.xclient.window = window
    event.xclient.message_type = x.XInternAtom(dpy, b"WM_PROTOCOLS", 0)
    event.xclient.format = 32
    event.xclient.data[0] = x.XInternAtom(dpy, b"WM_DELETE_WINDOW", 0)
    x.XSendEvent(dpy, window, 0, 0, ctypes.byref(event))
    x.XFlush(dpy)


def bubbles_after(b, start: int) -> list[tuple[str, ...]]:
    return [r.fields for r in b.rows("msg", 1)[start:]]


NO_TOKEN_BUBBLE = ("system", "Add a Claude token in the window that opened")


def token_was_found(b, start: int, statuses: int) -> tuple[bool, str]:
    """After a Send: the drawer answered (any bubble besides the user's: "Agent not available
    yet" before S3b's helper, the helper's reply after it), none of its bubbles asks for a
    token, and the Secrets window did not open again."""
    answered = b.wait(lambda: any(f[0] != "user" for f in bubbles_after(b, start)), 20)
    time.sleep(1.0)
    found = answered and NO_TOKEN_BUBBLE not in bubbles_after(b, start) and secrets_status(b)[statuses:] == []
    return found, f"bubbles {bubbles_after(b, start)}, new statuses {secrets_status(b)[statuses:]}"


def case_fallback_persists(binary: Path, tmp: Path, check) -> None:
    """RoseCat 5648 B1 (D11): the explicit "Save to a private file instead" click makes the file
    the active store, even in a run started with --agent-secret-store secret-service: a second
    Send finds that token (no Secrets window), and so does a Send after a restart without the
    flag (the file persists the choice)."""
    token = canary()
    world = provisioned(binary, tmp, "fallback")
    with fake_api(tmp) as api:
        # The first run names the Secret Service explicitly, so only the click can select the file.
        b = launch(binary, tmp, world, no_session_bus_env({}, tmp), api, "fallback", ["--agent-secret-store", "secret-service"])
        try:
            send_prompt(b, "hello")
            check(b.wait(lambda: secrets_status(b)[:1] == ["no-keyring"], 20), "no keyring: the window opens", b)
            paste_and_save(b, token)
            check(b.wait(lambda: (secrets_rect(b, "file") or (0, 0, 0, 0))[2] > 0, 15), "the file choice is offered", b)
            click_rect(b, secrets_rect(b, "file"))
            check(b.wait(lambda: secrets_status(b)[-1:] == ["connected-file"], 15), "the click stores to the file", b)
            statuses, start = len(secrets_status(b)), len(b.rows("msg", 1))
            send_prompt(b, "again")
            found, seen = token_was_found(b, start, statuses)
            check(found, f"a second Send finds the file token and asks no store again ({seen})", b)
        finally:
            b.stop()
        b = launch(binary, tmp, world, no_session_bus_env({}, tmp), api, "fallback-restart")
        try:
            send_prompt(b, "after a restart")
            found, seen = token_was_found(b, 0, 0)
            check(found, f"after a restart without the flag the file token is still the one used ({seen})", b)
            check(secrets_lines(b) == [], f"and no Secrets window opens ({secrets_lines(b)[:3]})", b)
        finally:
            b.stop()


def case_stale_store(binary: Path, tmp: Path, check) -> None:
    """RoseCat 5648 B2: a store completion from a closed window changes nothing. Save A (its
    answer held back 10 s), close the window, reopen it with Send, Save B: A's late answer lands
    while B is pending; B still gets the file choice, and the file then holds B."""
    token_a, token_b = canary(), canary()
    world = provisioned(binary, tmp, "stale")
    with fake_api(tmp) as api:
        bus = dict(no_session_bus_env({}, tmp), **{DELAY_ENV: "store=10000"})
        b = launch(binary, tmp, world, bus, api, "stale")
        try:
            send_prompt(b, "hello")
            b.wait(lambda: secrets_status(b)[:1] == ["no-keyring"], 20)
            paste_and_save(b, token_a)
            saved_a = time.monotonic()
            close_secrets_window(b)
            check(b.wait(lambda: not b.x.toplevels("Claude Agent account"), 5), "the window closed", b)
            seen = len(secrets_status(b))
            send_prompt(b, "again")
            check(b.wait(lambda: "no-keyring" in secrets_status(b)[seen:], 10), "Send reopens it", b)
            paste_and_save(b, token_b)
            check(time.monotonic() - saved_a < 8.5, "B was saved before A's held-back answer (timing precondition)")
            check(b.wait(lambda: (secrets_rect(b, "file") or (0, 0, 0, 0))[2] > 0, 15),
                  "after A's stale answer, B still gets the file choice (B's own answer lands last)", b)
            if (secrets_rect(b, "file") or (0, 0, 0, 0))[2] > 0:
                click_rect(b, secrets_rect(b, "file"))
                b.wait(lambda: secrets_status(b)[-1:] == ["connected-file"], 15)
            store = world.agent / "secrets" / "claude-token"
            check(store.is_file() and store.read_text() == token_b, "the file holds B, not A and not nothing")
        finally:
            b.stop()


def case_lookup_race(binary: Path, tmp: Path, check) -> None:
    """RoseCat 5648 B3: the opening lookup (its answer held back 3 s) cannot overwrite a later
    Save: what the window finally says matches the keyring. Then a Save after it works."""
    token = canary()
    world = provisioned(binary, tmp, "lookup")
    with PrivateKeyring(tmp) as kr, fake_api(tmp) as api:
        b = launch(binary, tmp, world, dict(kr.bus_env, **{DELAY_ENV: "lookup=3000"}), api, "lookup")
        try:
            send_prompt(b, "hello")
            check(b.wait(lambda: (secrets_rect(b, "save") or (0, 0, 0, 0))[2] > 0, 10), "the window is up", b)
            up = time.monotonic()
            check(secrets_status(b) == [], "before the held-back lookup answered (timing precondition)", b)
            paste_and_save(b, token)
            b.wait(lambda: secrets_status(b) != [], 10)
            # The lookup's answer is held back 3 s from when the window asked: wait past it.
            b.wait(lambda: time.monotonic() - up > 4.5, 10)
            time.sleep(0.5)
            stored = kr.lookup()
            final = secrets_status(b)[-1:]
            want = ["connected-secret-service"] if stored == token else ["empty"]
            check(final == want, f"the window's last word matches the keyring (keyring {'has' if stored else 'lacks'} "
                                 f"the token; statuses {secrets_status(b)})", b)
            paste_and_save(b, token)
            check(b.wait(lambda: secrets_status(b)[-1:] == ["connected-secret-service"], 15) and kr.lookup() == token,
                  "a Save after the lookup answered stores the token", b)
        finally:
            b.stop()


def case_remove_both(binary: Path, tmp: Path, check) -> None:
    """RoseCat 5648 B4: Remove clears both stores. A keyring item saved in one run and a file
    token saved in a run with --agent-secret-store file are both gone after Remove there."""
    token_k, token_f = canary(), canary()
    world = provisioned(binary, tmp, "both")
    store = world.agent / "secrets" / "claude-token"
    with PrivateKeyring(tmp) as kr, fake_api(tmp) as api:
        b = launch(binary, tmp, world, kr.bus_env, api, "both-keyring")
        try:
            send_prompt(b, "hello")
            b.wait(lambda: secrets_status(b)[:1] == ["empty"], 20)
            paste_and_save(b, token_k)
            check(b.wait(lambda: secrets_status(b)[-1:] == ["connected-secret-service"], 20) and kr.lookup() == token_k,
                  "the keyring holds the first token", b)
        finally:
            b.stop()
        b = launch(binary, tmp, world, kr.bus_env, api, "both-file", ["--agent-secret-store", "file"])
        try:
            send_prompt(b, "hello")
            b.wait(lambda: secrets_status(b)[:1] == ["empty"], 20)
            paste_and_save(b, token_f)
            check(b.wait(lambda: secrets_status(b)[-1:] == ["connected-file"], 20) and store.is_file(),
                  "the file holds the second token", b)
            check(b.wait(lambda: (secrets_rect(b, "remove") or (0, 0, 0, 0))[2] > 0, 10), "Remove is shown", b)
            click_rect(b, secrets_rect(b, "remove"))
            check(b.wait(lambda: secrets_status(b)[-1:] == ["empty"], 15), "Remove: SECRETS status empty", b)
            check(not store.exists(), "the file is gone")
            check(kr.lookup() is None, "and so is the keyring item")
        finally:
            b.stop()


def case_remove_close(binary: Path, tmp: Path, check) -> None:
    """RoseCat 5663: closing the window while Remove's keyring clear is in flight still
    finishes Remove: both stores are gone, and the late answer changes no window or row."""
    token_k, token_f = canary(), canary()
    world = provisioned(binary, tmp, "remove-close")
    store = world.agent / "secrets" / "claude-token"
    with PrivateKeyring(tmp) as kr, fake_api(tmp) as api:
        b = launch(binary, tmp, world, kr.bus_env, api, "remove-close-keyring")
        try:
            send_prompt(b, "hello")
            b.wait(lambda: secrets_status(b)[:1] == ["empty"], 20)
            paste_and_save(b, token_k)
            b.wait(lambda: secrets_status(b)[-1:] == ["connected-secret-service"], 20)
        finally:
            b.stop()
        b = launch(binary, tmp, world, dict(kr.bus_env, **{DELAY_ENV: "clear=4000"}), api, "remove-close-file",
                   ["--agent-secret-store", "file"])
        try:
            send_prompt(b, "hello")
            b.wait(lambda: secrets_status(b)[:1] == ["empty"], 20)
            paste_and_save(b, token_f)
            check(b.wait(lambda: secrets_status(b)[-1:] == ["connected-file"], 20) and kr.lookup() == token_k,
                  "both stores hold a token", b)
            b.wait(lambda: (secrets_rect(b, "remove") or (0, 0, 0, 0))[2] > 0, 10)
            click_rect(b, secrets_rect(b, "remove"))
            clicked = time.monotonic()
            close_secrets_window(b)
            check(b.wait(lambda: not b.x.toplevels("Claude Agent account"), 5), "the window closed during Remove", b)
            rows = len(secrets_lines(b))
            b.wait(lambda: time.monotonic() - clicked > 6.0, 10)  # past the held-back clear answer
            check(not store.exists(), "the file is gone although the window closed first")
            check(kr.lookup() is None, "and so is the keyring item")
            check(secrets_lines(b)[rows:] == [], f"the late answer changed no row ({secrets_lines(b)[rows:]})", b)
        finally:
            b.stop()


def open_drawer(b) -> None:
    from agent_common import centre
    if not b.rows("open", 1):
        icon = b.wait_row("icon", 1)
        b.x.click(*centre(tuple(int(v) for v in icon.fields[0].split(","))))
        b.wait_row("open", 1, timeout=10)


def case_account_button(binary: Path, tmp: Path, check) -> None:
    """RoseCat 5695 (D1, D11): the drawer header's Account button opens the Secrets window
    without any Send, here with the agent runtime missing; closed, it opens again on the next
    click. The window stays unreachable from pages and the socket."""
    from agent_common import centre
    world = provisioned(binary, tmp, "account")
    with fake_api(tmp) as api:
        bus = dict(no_session_bus_env({}, tmp), ZB_AGENT_HOST_PYTHON="/nonexistent/zb-no-runtime/python")
        b = launch(binary, tmp, world, bus, api, "account")
        try:
            open_drawer(b)
            row = b.wait_row("account", 1, timeout=10)
            check(row is not None, "the open drawer reports its Account button (DRAWER account <rect>)", b)
            if row is None:
                return
            b.x.click(*centre(row.rect()))
            check(b.wait(lambda: secrets_status(b)[:1] == ["no-keyring"], 15),
                  f"one click opens the Secrets window, no Send needed ({secrets_status(b)})", b)
            check([r for r in b.rows("msg", 1)] == [], "no message was sent", b)
            tree = [f[0] for k, f in secrets_lines(b) if k == "tree"]
            check(tree != [] and "WebKitWebView" not in tree[0], f"its tree has no WebKitWebView: {tree[:1]}", b)
            check(len(b.zb.page.list()["pages"]) == 1, "page.list does not list it", b)
            close_secrets_window(b)
            check(b.wait(lambda: not b.x.toplevels("Claude Agent account"), 5), "the window closed", b)
            seen = len(secrets_status(b))
            b.x.click(*centre(b.rows("account", 1)[-1].rect()))
            check(b.wait(lambda: secrets_status(b)[seen:][:1] == ["no-keyring"], 15), "the next click opens it again", b)
        finally:
            b.stop()


def case_canary_self_test(binary: Path, tmp: Path, check) -> None:
    """The leak scan (any 4 consecutive canary characters, S4.1) can only be trusted if the
    canary's random part cannot occur by chance in what the browser prints: random hex
    (netd's socket directory, nonces), numbers (pids, rects), lowercase words and the row
    tags (BlackRobin 5709: a hex tail matched 4 characters of a hex socket name). No browser
    runs here."""
    import random
    rng = random.Random(5709)
    corpus = "\n".join([
        "".join(rng.choice("0123456789abcdef") for _ in range(200_000)),
        " ".join(str(rng.randrange(0, 1 << 32)) for _ in range(20_000)),
        "DRAWER\t1\topen\t0,461,1024,307\nSECRETS\tstatus\tempty\nAGENTNET\tready\nWINCOUNT\t1\nNAV\tTITLE\tLOAD_FAIL",
        "zigBrowser: agent: network unavailable (XDG_RUNTIME_DIR) Gtk-WARNING GLib-GObject-CRITICAL",
    ])
    hits = {}
    for _ in range(50):
        token = canary()
        found = [w for w in leaks(corpus, token) if w not in "sk-ant-oat01-zbcanary-"]  # the fixed prefix is no secret
        if found:
            hits[token[-12:]] = found[:3]
    check(hits == {}, f"no canary's random part shares a 4-character run with random output ({len(hits)} of 50: "
                      f"{list(hits.items())[:2]})")


def needle_in_proc(token: str) -> list[str]:
    hits = []
    for pid in filter(str.isdigit, os.listdir("/proc")):
        try:
            if token.encode() in Path(f"/proc/{pid}/environ").read_bytes() + Path(f"/proc/{pid}/cmdline").read_bytes():
                hits.append(pid)
        except OSError:
            continue
    return hits


def case_unreachable(binary: Path, tmp: Path, check) -> None:
    """S4.3 (A3): the Secrets window is not a browsing window and no page or socket reaches it."""
    world = provisioned(binary, tmp, "unreachable")
    with fake_api(tmp) as api:
        b = launch(binary, tmp, world, no_session_bus_env({}, tmp), api, "unreachable")
        try:
            send_prompt(b, "hello")
            check(b.wait(lambda: secrets_status(b) != [], 20), "the Secrets window is open", b)
            tree = [f[0] for k, f in secrets_lines(b) if k == "tree"]
            check(tree != [] and "WebKitWebView" not in tree[0], f"its tree has no WebKitWebView: {tree[:1]}", b)
            check(len(b.zb.page.list()["pages"]) == 1, "page.list does not list it", b)
            check({r.win for r in b.rows()} == {1}, "it gets no DRAWER window id", b)
            probes = b.ev("JSON.stringify(Object.keys(window).filter(k => /^zbSecrets/i.test(k)))")
            check(probes == "[]", f"no zbSecrets* name in the page: {probes}", b)
            try:
                b.zb.call("secrets.get", {})
                code = None
            except Exception as exc:  # noqa: BLE001 - the error code is what is checked
                code = getattr(exc, "code", None)
            check(code == -32601, f"the socket's secrets.* gives -32601 (got {code})", b)
        finally:
            b.stop()


HOOK_EVENTS = ("SessionStart", "UserPromptSubmit", "Stop", "SessionEnd")
TOKEN_NAMES = ("CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY",
               "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN")


def case_hooks(binary: Path, tmp: Path, check) -> None:
    """S4.4 (A4) with rev 16.2's network rows: the canary is stored through the Secrets window
    (file store), a prompt runs end to end, and each of SessionStart, UserPromptSubmit, Stop
    and SessionEnd runs the shared hook network probe in its own sealed network. Every hook
    must reach both bridge decoys and nothing else (no 3128, no egress/proxy.sock, no fake API,
    no DNS), see no token or messaging name, and its record must hold no canary.

    Red until S3b runs a session from the browser and S3n2's app side starts netd; the env
    dumps and notify POSTs of S3c's hook fixture join this case when it lands."""
    from agent_hook_net import hook_network_failures, install_probe, probe_command
    from agent_setup_test import World, run_setup
    token = canary()
    world = World(tmp, "hooks")
    probe = install_probe(world.source / "hooks")
    results = {}
    settings = world.settings()
    settings["hooks"] = {}
    for event in HOOK_EVENTS:
        out = world.agent / "scratchpad" / f"hook-net-{event}.json"
        command, nonce = probe_command(Path("~/.claude/hooks") / probe.name, out)
        settings["hooks"][event] = [{"hooks": [{"type": "command", "command": command}]}]
        results[event] = (out, nonce)
    world.write_settings(settings)
    rc, _out, err, _events, _seen = run_setup(binary, world)
    check(rc == 0, f"--agent-setup provisions the probe hooks (rc={rc}: {err.strip()[-200:]})")
    if rc != 0:
        return
    with fake_api(tmp, [{"text": "Scripted reply."}] * 4) as api:
        b = launch(binary, tmp, world, no_session_bus_env({}, tmp), api, "hooks", ["--agent-secret-store", "file"])
        try:
            send_prompt(b, "hello")
            check(b.wait(lambda: secrets_status(b)[:1] == ["empty"], 20), "the Secrets window opens", b)
            paste_and_save(b, token)
            check(b.wait(lambda: secrets_status(b)[-1:] == ["connected-file"], 20), "SECRETS status connected-file", b)
            before = b.decoys.fake_api.connections  # a property
            send_prompt(b, "hello again")
            check(b.wait(lambda: any(r["headers"].get("authorization") == f"Bearer {token}"
                                     for r in api.messages_requests()), 60),
                  "the CLI's request reached the fake API through netd with Bearer <canary>", b)
            check(b.wait(lambda: all(out.exists() for out, _ in list(results.values())[:3]), 30),
                  "SessionStart, UserPromptSubmit and Stop each ran the probe", b)
        finally:
            b.stop()  # ends the session: SessionEnd runs
    for event, (out, nonce) in results.items():
        if not out.exists():
            check(False, f"{event}: the hook never ran (no {out.name})")
            continue
        raw = out.read_text()
        result = json.loads(raw)
        check(result.get("nonce") == nonce, f"{event}: the probe record is this run's")
        bad = hook_network_failures(result, b.decoys, before)
        check(bad == [], f"{event}: the hook reached both bridges and nothing else {bad}")
        names = set(result.get("env_names", []))
        check(not names & set(TOKEN_NAMES), f"{event}: no token or messaging name in the hook's environment "
                                            f"({sorted(names & set(TOKEN_NAMES))})")
        check(token not in raw and not leaks(raw, token), f"{event}: the hook's record holds no run of the canary")
    # netd's fake.zb.invalid is the real TLS fake here, not the shared decoy: every connection
    # it accepted must have carried the CLI's Bearer <canary> request. A hook's CONNECT plus
    # ClientHello would be a connection with none (BlackRobin 5570).
    strangers = api.connections_without_bearer(token)
    check(strangers == 0, f"every connection at the fake API was the CLI's, none a hook's ({strangers} without Bearer)")


CASES = {
    # S4a: the store, the window and the Send that opens it.
    "secret-service": case_secret_service,
    "file-flag": case_file_flag,
    "rejected": case_rejected,
    "no-keyring": case_no_keyring,
    "remove": case_remove,
    "unreachable": case_unreachable,
    "fallback-persists": case_fallback_persists,
    "stale-store": case_stale_store,
    "lookup-race": case_lookup_race,
    "remove-both": case_remove_both,
    "remove-close": case_remove_close,
    "account-button": case_account_button,
    "canary-self-test": case_canary_self_test,
    # S4b: the hand-off through S3b's helper (its build step runs these with --only).
    "handoff": case_handoff,
    "remove-session": case_remove_session,
    "hooks": case_hooks,
}
S4A_CASES = ("secret-service", "file-flag", "rejected", "no-keyring", "remove", "unreachable",
             "fallback-persists", "stale-store", "lookup-race", "remove-both")


def main() -> int:
    from agent_common import run_main
    for tool in ("dbus-daemon", "gnome-keyring-daemon", "gdbus"):
        if shutil.which(tool) is None:
            print(f"FAIL: missing hard requirement: {tool}", file=sys.stderr)
            return 1
    return run_main(__doc__, CASES)


if __name__ == "__main__":
    raise SystemExit(main())
