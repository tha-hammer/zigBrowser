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
SECRETS_CONTROLS = ("entry", "save", "remove", "file", "signin", "code", "send-code", "cancel", "copy-link")
# `SECRETS login <state>` (S6b1, rev 16.18.3): the sign-in's state; agent_login_test.py drives it.
LOGIN_STATES = ("starting", "need-code", "done", "cancelled") + tuple(
    f"error-{w}" for w in ("cli", "timeout", "cancelled", "shape", "protocol", "exchange", "network", "store"))
# `SECRETS reason <sentence>|-` (rev 16.18.9): the fixed reason line under "Sign-in failed.".
LOGIN_REASONS = ("Claude.ai could not be reached, or it did not accept the code. Try again.",
                 "The sign-in took too long. Try again.",
                 "The Claude CLI stopped before it gave a token. Try again.",
                 "The sign-in's network could not start. Try again.",
                 "Something unexpected happened during sign-in. Try again.", "-")
# `SECRETS fetch <word>` (a token fetch began, or answered) and `SECRETS remove click`: e2e-only
# rows that make the order of a Remove and a fetch observable (RoseCat 5821).
FETCH_WORDS = ("begin", "ok", "absent", "unavailable", "refused")
# Every sentence the status line may show (src/agent_secrets_window.c): never the token.
SECRETS_TEXTS = ("No token is stored.", "Connected. The token is stored in the system keyring.",
                 "Connected. The token is stored in a private file.", "That doesn't look like a token.",
                 "No system keyring is available. Nothing was stored.", "Saving...",
                 "The token could not be saved.", "The token could not be removed.",
                 # Sign in with Claude.ai (S6b1)
                 "Signing in...", "Paste the code from the sign-in page.",
                 "Signed in. The token is stored in the system keyring.",
                 "Signed in. The token is stored in a private file.", "That doesn't look like a sign-in code.",
                 "Sign-in failed.", "Sign-in cancelled.")


# The canary's random part: uppercase letters that are not hex, not in any row tag (DRAWER,
# SECRETS, AGENTNET, TITLE, NAV, WINCOUNT, LOAD_FAIL) and not lowercase, so a run of 4 of
# them cannot occur by chance in what the browser prints (canary-self-test; BlackRobin 5709).
CANARY_TAIL = "BHJKQXYZ"


def canary() -> str:
    """A canary of 16-512 printable characters: a fixed prefix and 40 random letters of
    CANARY_TAIL (120 bits), typed with Shift."""
    return "sk-ant-oat01-zbcanary-" + "".join(secrets.choice(CANARY_TAIL) for _ in range(40))


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
    """`SECRETS status <state>`, `SECRETS text <sentence>`, `SECRETS tree <types>`,
    `SECRETS rect <control> <x,y,w,h>`, the e2e-only `fetch` and `remove` rows, or
    `SECRETS login <state>`, `SECRETS reason <sentence>|-`; anything else raises SecretsRowError."""
    parts = line.split("\t")
    if parts[0] != "SECRETS" or len(parts) < 3:
        raise SecretsRowError(f"not a SECRETS row: {line!r}")
    kind, fields = parts[1], tuple(parts[2:])
    ok = (kind == "status" and len(fields) == 1 and fields[0] in SECRETS_STATES) or \
         (kind == "text" and len(fields) == 1 and fields[0] in SECRETS_TEXTS) or \
         (kind == "tree" and len(fields) == 1 and re.fullmatch(r"[A-Za-z0-9_]+(,[A-Za-z0-9_]+)*", fields[0])) or \
         (kind == "fetch" and fields in tuple((w,) for w in FETCH_WORDS)) or \
         (kind == "remove" and fields == ("click",)) or \
         (kind == "login" and len(fields) == 1 and fields[0] in LOGIN_STATES) or \
         (kind == "reason" and len(fields) == 1 and fields[0] in LOGIN_REASONS) or \
         (kind == "sensitive" and len(fields) == 2 and fields[0] in ("entry", "save", "remove", "file", "signin")
          and fields[1] in ("0", "1")) or \
         (kind == "rect" and len(fields) == 2 and fields[0] in SECRETS_CONTROLS
          and re.fullmatch(r"-?\d+,-?\d+,\d+,\d+", fields[1]))
    if not ok:
        raise SecretsRowError(f"malformed SECRETS row: {line!r}")
    return kind, fields


def secrets_rows(lines: list[str]) -> list[tuple[str, tuple[str, ...]]]:
    return [parse_secrets_row(line) for line in lines if line.startswith("SECRETS\t")]


# --- the session bus the browser may use ------------------------------------------------
DEAD_BUS = "unix:path=/nonexistent/zigbrowser-test-no-session-bus"


RUNTIME_DIRS: list[Path] = []


def short_runtime_dir() -> Path:
    """A private, empty runtime dir short enough for netd's sockets (sun_path is 107 bytes);
    removed at exit."""
    run = Path(tempfile.mkdtemp(prefix="zbs-", dir="/tmp"))
    run.chmod(0o700)
    if not RUNTIME_DIRS:
        import atexit
        atexit.register(lambda: [shutil.rmtree(d, ignore_errors=True) for d in RUNTIME_DIRS])
    RUNTIME_DIRS.append(run)
    return run


def no_session_bus_env(env: dict[str, str], tmp: Path) -> dict[str, str]:
    """`env` with no usable session bus: a dead address and a private, empty runtime dir."""
    return dict(env, DBUS_SESSION_BUS_ADDRESS=DEAD_BUS, XDG_RUNTIME_DIR=str(short_runtime_dir()))


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

    def plant(self, value: str) -> None:
        """Stores `value` as the token item through libsecret, the way another same-user
        program could (RoseCat 5763 advisory): the browser never wrote it."""
        code = ("import gi, sys; gi.require_version('Secret', '1'); from gi.repository import Secret\n"
                f"s = Secret.Schema.new({self.SCHEMA!r}, Secret.SchemaFlags.NONE,"
                " {'account': Secret.SchemaAttributeType.STRING})\n"
                "ok = Secret.password_store_sync(s, {'account': 'default'}, Secret.COLLECTION_DEFAULT,"
                " 'planted', sys.argv[1], None)\n"
                "sys.exit(0 if ok else 1)")
        done = subprocess.run(["/usr/bin/python3", "-I", "-c", code, value], env=self.env, capture_output=True,
                              text=True, timeout=20)
        if done.returncode != 0:
            raise RuntimeError(f"keyring store failed: {done.stderr.strip()[-300:]}")

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


def launch(binary: Path, tmp: Path, world, bus_env: dict[str, str], api, label: str, args: list[str] = (),
           net_extra: str = ""):
    """zigBrowser with the drawer on, the provisioned agent home of `world` (S3a), the TLS
    fake Messages API reached only through netd, private bridge decoys (b.decoys), and exactly
    the session bus `bus_env` gives it (a private keyring's, or a dead one). `net_extra`: more
    netd seam pairs (e.g. `--test-ready-delay ms=2500`)."""
    from agent_common import Browser
    from agent_hook_net import HookNetDecoys
    from slice2_common import isolate_profile_env

    decoys = HookNetDecoys()
    env = isolate_profile_env(dict(os.environ))
    env.update(world.env())
    env.update(bus_env)
    env.update(net_test_env(api, decoys))
    if net_extra:
        env["ZIGBROWSER_AGENT_NET_TEST"] += " " + net_extra
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


def window_lines(b) -> list[tuple[str, tuple[str, ...]]]:
    """The Secrets window's own rows (status, text, tree, rect): not the e2e-only fetch
    observer's or the Remove click's, which say nothing about the window being open."""
    return [(k, f) for k, f in secrets_lines(b) if k in ("status", "text", "tree", "rect")]


def secrets_status(b) -> list[str]:
    return [f[0] for k, f in secrets_lines(b) if k == "status"]


def secrets_rect(b, name: str) -> tuple[int, int, int, int] | None:
    rects = [f[1] for k, f in secrets_lines(b) if k == "rect" and f[0] == name]
    return tuple(int(v) for v in rects[-1].split(",")) if rects else None  # type: ignore[return-value]


def click_rect(b, r: tuple[int, int, int, int]) -> None:
    b.x.click(r[0] + r[2] // 2, r[1] + r[3] // 2)


def type_text(b, text: str) -> None:
    for ch in text:
        if "A" <= ch <= "Z":
            b.x.key(ch.lower(), ("Shift_L",), settle=0.005)
        else:
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
    for root in (world.data, b.dir):  # the agent home and the profile are both under the data dir
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
            check(b.wait(lambda: any(r["headers"].get("authorization") == f"Bearer {token}" for r in api.messages_requests()), 90),
                  "the fake API received Bearer <canary>, through relay and netd", b)
            check(b.wait(lambda: ("assistant", "Scripted reply.") in [r.fields for r in b.rows("msg", 1)], 60),
                  "the fake's reply is shown in the drawer", b)
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


# Near misses of the setup-token shape ^sk-ant-oat01-[A-Za-z0-9_-]{22,499}$ (src/agent_secrets.zig
# validToken; RoseCat 5731). None is a secret; the old printable-run rule passed all but the
# last three.
SHAPE_NEAR_MISSES = (
    "sk-ant-api03-" + "ZBQXJKHY" * 5,             # an API key
    "SK-ANT-OAT01-" + "ZBQXJKHY" * 5,             # wrong case
    "sk-ant-oat02-" + "ZBQXJKHY" * 5,             # wrong prefix
    "sk-ant-oat01-" + "ZBQXJKHY" * 2 + "ZBQXJ",   # too short: 21 after the prefix
    "sk-ant-oat01-ZBQX.JKHY+ZBQX/JKHY=ZBQXJKHY",  # bad characters
    "zbqx-not-a-token-but-long-enough",           # no prefix
    "sk-ant-oat01-ZBQXJKHY ZBQXJKHYZBQXJKHYZB",   # inner space
    "sk-ant-oat01-ZBQXJKHYZBQX\tJKHYZBQXJKHY",    # inner tab
    "",                                           # empty
)


def shape_case(binary: Path, tmp: Path, check, store: str) -> None:
    """The user's requirement (S4a real-screen check): Save accepts only the setup-token shape.
    Each near miss, pasted with a real Ctrl+V and saved with a real click, gives "rejected" and
    stores nothing in the keyring or the file; then the canary pasted between spaces, tabs and
    newlines is trimmed and stored (`store`: the private keyring, or the file flag) without the
    padding. No row and no log line holds any of it."""
    token = canary()
    world = provisioned(binary, tmp, f"shape-{store}")
    with PrivateKeyring(tmp) as kr, fake_api(tmp) as api:
        args = ["--agent-secret-store", "file"] if store == "file" else []
        b = launch(binary, tmp, world, kr.bus_env, api, f"shape-{store}", args)
        try:
            send_prompt(b, "hello")
            check(b.wait(lambda: secrets_status(b)[:1] == ["empty"], 20), "the Secrets window opens", b)
            file = world.agent / "secrets" / "claude-token"
            for i, bad in enumerate(SHAPE_NEAR_MISSES):
                paste_and_save_bad(b, bad)
                check(b.wait(lambda n=i: secrets_status(b).count("rejected") >= n + 1, 15), f"rejected: {bad!r}", b)
                check(kr.lookup() is None and not file.exists(), f"nothing stored after {bad!r}", b)
            texts = [f[0] for k, f in secrets_lines(b) if k == "text"]
            check(texts.count("That doesn't look like a token.") >= len(SHAPE_NEAR_MISSES),
                  "each near miss showed the fixed sentence", b)
            check(not any(s.startswith("connected") for s in secrets_status(b)), "no near miss was stored", b)
            paste_and_save_bad(b, "\n  \t" + token + " \t\n")
            want = "connected-file" if store == "file" else "connected-secret-service"
            check(b.wait(lambda: secrets_status(b)[-1:] == [want], 20), f"the padded canary is stored: {want}", b)
            if store == "file":
                check(kr.lookup() is None, "nothing in the keyring")
                check(file.is_file() and file.read_bytes() in (token.encode(), token.encode() + b"\n"),
                      "the file holds the canary without the padding", b)
            else:
                check(kr.lookup() == token, "the keyring holds the canary without the padding", b)
                check(not file.exists(), "no token file (the keyring was chosen)")
            printed = "\n".join(b.out + b.err)
            check("sk-ant" not in printed.lower() and "zbqx" not in printed.lower(), "no near miss in any row or log", b)
            check(not leaks(printed, token), "no run of the canary in rows, stdout or stderr", b)
        finally:
            b.stop()


def case_shape(binary: Path, tmp: Path, check) -> None:
    shape_case(binary, tmp, check, "keyring")


def case_shape_file(binary: Path, tmp: Path, check) -> None:
    shape_case(binary, tmp, check, "file")


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


# --- RoseCat 5813: a credential chosen before Remove never starts a helper afterwards -------
def agentnet_ready(b) -> bool:
    return any(line.startswith("AGENTNET\tready") for line in list(b.out))


def secrets_events(b) -> list[str]:
    """The fetch and remove rows, in order: "fetch begin", "fetch ok", ..., "remove click"."""
    return [f"{k} {f[0]}" for k, f in secrets_lines(b) if k in ("fetch", "remove")]


def ordered(b) -> list[str]:
    """In stdout order: "fetch <word>", "remove click", "status <state>" (the Secrets
    window's), "agentnet ready" and "drawer starting" (window 1's agent status)."""
    out = []
    for line in list(b.out):
        line = line.rstrip("\n")
        if line.startswith("AGENTNET\tready"):
            out.append("agentnet ready")
        elif line.startswith("DRAWER\t1\tstatus\tstarting"):
            out.append("drawer starting")
        elif line.startswith(("SECRETS\tfetch\t", "SECRETS\tremove\t", "SECRETS\tstatus\t")):
            kind, fields = parse_secrets_row(line)
            out.append(f"{kind} {fields[0]}")
    return out


def answered(event: str) -> bool:
    return event.startswith("fetch ") and event != "fetch begin"


def remove_before_answer(b, since: int, fetch_begun: bool) -> bool:
    """Observable precondition (RoseCat 5821): among the events after `since`, the Remove
    click came before any fetch answered, so no helper could have started yet (a helper
    starts only after its fetch answers). With `fetch_begun`, a fetch had also begun first:
    the helper was waiting for that token at the click."""
    ev = secrets_events(b)[since:]
    if "remove click" not in ev:
        return False
    before = ev[:ev.index("remove click")]
    return not any(answered(e) for e in before) and (not fetch_begun or "fetch begin" in before)

REMOVED_BUBBLE = ("system", "The token was removed: the agent stopped")


def rows_after_remove(b) -> list:
    """Window 1's DRAWER rows printed after the (last) `SECRETS remove click` line."""
    from agent_common import drawer_rows
    out = list(b.out)
    cut = max((i for i, line in enumerate(out) if line.startswith("SECRETS\tremove\tclick")), default=len(out))
    return [r for r in drawer_rows(out[cut + 1:]) if r.win == 1]


def marks(b) -> tuple[int, int]:
    """Where window 1's DRAWER status and msg rows stand now."""
    return len(b.rows("status", 1)), len(b.rows("msg", 1))


def removed_token_unused(b, api, token: str, check, label: str, mark=None) -> None:
    """After a Remove that raced the helper's start: no request ever carries the removed
    token, no process holds it, and the next Send (the removal done) opens the Secrets
    window again. With `mark` (rows before the Remove click), the prompt that was waiting
    is decided exactly once (BlackRobin 5815): one "token was removed" bubble, and no
    fresh start before the next Send."""
    time.sleep(6.0)  # past every held-back answer (4 s)
    if mark is not None:
        after = rows_after_remove(b)  # in stdout order, so the Send's own rows are never counted
        bubbles = [tuple(r.fields[:2]) for r in after if r.kind == "msg"]
        check(bubbles.count(REMOVED_BUBBLE) == 1, f"{label}: the waiting prompt is decided once ({bubbles})", b)
        states = [r.fields[0] for r in after if r.kind == "status"]
        check("starting" not in states, f"{label}: no fresh start before the next Send ({states})", b)
    bearers = [r for r in api.messages_requests() if r["headers"].get("authorization") == f"Bearer {token}"]
    check(bearers == [], f"{label}: no request carries the removed token ({len(bearers)})", b)
    check(not needle_in_proc(token), f"{label}: no process holds the removed token", b)
    before = len(secrets_lines(b))
    send_prompt(b, "and again")
    check(b.wait(lambda: any(k == "status" and f[0] == "empty" for k, f in secrets_lines(b)[before:]), 20),
          f"{label}: the next Send opens the Secrets window (no token)", b)
    check([r for r in api.messages_requests() if r["headers"].get("authorization") == f"Bearer {token}"] == [],
          f"{label}: still no request with the removed token", b)


def case_remove_during_fetch(binary: Path, tmp: Path, check) -> None:
    """RoseCat 5813, interleaving 1: Send starts the helper's token fetch, which copies the
    stored token but answers 4 s late (the lookup seam); Remove is clicked meanwhile. The late
    answer must not start a helper with the removed token."""
    token = canary()
    world = provisioned(binary, tmp, "remove-fetch")
    with PrivateKeyring(tmp) as kr, fake_api(tmp, [{"text": "Scripted reply."}] * 4) as api:
        b = launch(binary, tmp, world, dict(kr.bus_env, **{DELAY_ENV: "lookup=4000"}), api, "remove-fetch")
        try:
            send_prompt(b, "hello")
            check(b.wait(lambda: secrets_status(b)[:1] == ["empty"], 20), "no token: the Secrets window opens", b)
            check(b.wait(lambda: agentnet_ready(b), 15), "netd is ready (the next fetch starts at once)", b)
            paste_and_save(b, token)
            check(b.wait(lambda: secrets_status(b)[-1:] == ["connected-secret-service"], 20), "the token is stored", b)
            since = len(secrets_events(b))
            send_prompt(b, "go")  # the fetch starts now; its answer is held back 4 s
            check(b.wait(lambda: "fetch begin" in secrets_events(b)[since:], 10), "the Send's token fetch began", b)
            mark = marks(b)
            click_rect(b, secrets_rect(b, "remove"))
            check(b.wait(lambda: "remove click" in secrets_events(b)[since:], 10), "the Remove click is seen", b)
            check(remove_before_answer(b, since, fetch_begun=True),
                  f"precondition: Remove came while the fetch was held ({secrets_events(b)[since:]})", b)
            check(b.wait(lambda: secrets_status(b)[-1:] == ["empty"], 10), "Remove: SECRETS status empty", b)
            check(kr.lookup() is None, "the keyring item is gone")
            removed_token_unused(b, api, token, check, "remove-during-fetch", mark)
        finally:
            b.stop()


def case_remove_during_net(binary: Path, tmp: Path, check) -> None:
    """RoseCat 5813, interleaving 2: the token is saved through the Account button, so the
    first Send starts netd (H_WAIT_NET); Remove is clicked at once, and its keyring clear waits
    4 s before it deletes (the preclear seam, RoseCat 5821), so a fetch after netd's ready can
    still read the old item. netd holds its ready line 2.5 s (RoseCat 5830), and the rows show
    the click came before netd was ready and before any fetch began: the helper was in
    H_WAIT_NET. That credential must not start a helper either."""
    token = canary()
    world = provisioned(binary, tmp, "remove-net")
    with PrivateKeyring(tmp) as kr, fake_api(tmp, [{"text": "Scripted reply."}] * 4) as api:
        b = launch(binary, tmp, world, dict(kr.bus_env, **{DELAY_ENV: "preclear=4000"}), api, "remove-net",
                   net_extra="--test-ready-delay ms=2500")
        try:
            open_drawer(b)
            b.wait(lambda: b.rows("account", 1) != [], 10)
            click_account(b)
            check(b.wait(lambda: secrets_status(b)[:1] == ["empty"], 20), "Account opens the Secrets window", b)
            paste_and_save(b, token)
            check(b.wait(lambda: secrets_status(b)[-1:] == ["connected-secret-service"], 20), "the token is stored", b)
            check(not agentnet_ready(b), "no netd before the first Send (timing precondition)", b)
            since = len(ordered(b))
            send_prompt(b, "go")  # the first Send: the config check, then netd starts (H_WAIT_NET)
            check(b.wait(lambda: "drawer starting" in ordered(b)[since:], 10), "the helper is starting", b)
            mark = marks(b)
            click_rect(b, secrets_rect(b, "remove"))
            check(b.wait(lambda: "remove click" in ordered(b)[since:], 10), "the Remove click is seen", b)
            order = ordered(b)[since:]
            at = order.index("remove click") if "remove click" in order else -1
            check(at >= 0 and "drawer starting" in order[:at] and "agentnet ready" not in order[:at]
                  and "fetch begin" not in order[:at],
                  f"precondition: Remove came after the start and before netd was ready or any fetch began "
                  f"(H_WAIT_NET; {order})", b)
            check(b.wait(lambda: secrets_status(b)[-1:] == ["empty"], 15), "Remove: SECRETS status empty", b)
            removed_token_unused(b, api, token, check, "remove-during-net", mark)
            check(kr.lookup() is None, "the keyring item is gone")
        finally:
            b.stop()


def case_send_during_clear(binary: Path, tmp: Path, check) -> None:
    """BlackRobin 5815, the store side: Remove with no helper yet, its keyring clear waiting 6 s
    before it deletes (the preclear seam, RoseCat 5821), then a Send at once. That Send starts after the Remove, so the
    helper's own generation cannot reject it; the store must not hand out the item it is
    deleting. The Send finds no token: the drawer says so, and the old token is never used."""
    token = canary()
    world = provisioned(binary, tmp, "send-clear")
    with PrivateKeyring(tmp) as kr, fake_api(tmp, [{"text": "Scripted reply."}] * 4) as api:
        b = launch(binary, tmp, world, dict(kr.bus_env, **{DELAY_ENV: "preclear=6000"}), api, "send-clear")
        try:
            open_drawer(b)
            b.wait(lambda: b.rows("account", 1) != [], 10)
            click_account(b)
            check(b.wait(lambda: secrets_status(b)[:1] == ["empty"], 20), "Account opens the Secrets window", b)
            paste_and_save(b, token)
            check(b.wait(lambda: secrets_status(b)[-1:] == ["connected-secret-service"], 20), "the token is stored", b)
            mark = marks(b)
            since = len(ordered(b))
            click_rect(b, secrets_rect(b, "remove"))
            send_prompt(b, "go")  # while the clear is still running
            check(b.wait(lambda: "fetch begin" in ordered(b)[since:], 15), "the Send's fetch began", b)
            order = ordered(b)[since:]
            check("remove click" in order and order.index("remove click") < order.index("fetch begin")
                  and "status empty" not in order[:order.index("fetch begin")],
                  f"precondition: the fetch began after Remove and before its clear answered ({order})", b)
            check(b.wait(lambda: any(r.fields[1:2] == ("no-token",) for r in b.rows("status", 1)[mark[0]:]), 20),
                  "the Send finds no token (status no-token)", b)
            check(b.wait(lambda: secrets_status(b)[-1:] == ["empty"], 20), "Remove: SECRETS status empty", b)
            time.sleep(2.0)
            bearers = [r for r in api.messages_requests() if r["headers"].get("authorization") == f"Bearer {token}"]
            check(bearers == [], f"no request carries the removed token ({len(bearers)})", b)
            check(not needle_in_proc(token), "no process holds the removed token", b)
            check(kr.lookup() is None, "the keyring item is gone")
        finally:
            b.stop()


def case_replace_during_fetch(binary: Path, tmp: Path, check) -> None:
    """RoseCat 5822, why the generation exists: a fetch begun before Remove (its answer held
    6 s) must lose even when, by the time it answers, a replacement token is saved and a new
    Send's fetch is pending (the helper is waiting for a token again, so its state alone
    cannot tell the answers apart). Only the replacement is ever used, and the new prompt is
    answered."""
    old, new = canary(), canary()
    world = provisioned(binary, tmp, "replace-fetch")
    with PrivateKeyring(tmp) as kr, fake_api(tmp, [{"text": "Scripted reply."}] * 4) as api:
        b = launch(binary, tmp, world, dict(kr.bus_env, **{DELAY_ENV: "lookup=6000"}), api, "replace-fetch")
        try:
            send_prompt(b, "hello")
            check(b.wait(lambda: secrets_status(b)[:1] == ["empty"], 25), "no token: the Secrets window opens", b)
            paste_and_save(b, old)
            check(b.wait(lambda: secrets_status(b)[-1:] == ["connected-secret-service"], 20), "the first token is stored", b)
            since = len(secrets_events(b))
            send_prompt(b, "go")
            check(b.wait(lambda: "fetch begin" in secrets_events(b)[since:], 10), "the Send's fetch began (old token)", b)
            click_rect(b, secrets_rect(b, "remove"))
            check(b.wait(lambda: "remove click" in secrets_events(b)[since:], 10), "the Remove click is seen", b)
            check(remove_before_answer(b, since, fetch_begun=True),
                  f"precondition: Remove came while the fetch was held ({secrets_events(b)[since:]})", b)
            check(b.wait(lambda: secrets_status(b)[-1:] == ["empty"], 10), "Remove: SECRETS status empty", b)
            paste_and_save_bad(b, new)  # the replacement, pasted: quick
            check(b.wait(lambda: secrets_status(b)[-1:] == ["connected-secret-service"], 10) and kr.lookup() == new,
                  "the replacement token is stored", b)
            status_mark = len(b.rows("status", 1))
            send_prompt(b, "go again")
            check(b.wait(lambda: secrets_events(b)[since:].count("fetch begin") >= 2, 10), "the second fetch began", b)
            ev = secrets_events(b)[since:]
            begins = [i for i, e in enumerate(ev) if e == "fetch begin"]
            first_answer = next((i for i, e in enumerate(ev) if answered(e)), len(ev))
            check(len(begins) >= 2 and begins[1] < first_answer,
                  f"precondition: the second fetch began before the first answered ({ev})", b)
            check(b.wait(lambda: any(r["headers"].get("authorization") == f"Bearer {new}" for r in api.messages_requests()), 90),
                  "the replacement token reached the fake API", b)
            check(b.wait(lambda: ("assistant", "Scripted reply.") in [tuple(r.fields[:2]) for r in b.rows("msg", 1)], 60),
                  "the new prompt is answered", b)
            reasons = [r.fields[1] for r in b.rows("status", 1)[status_mark:] if len(r.fields) > 1]
            check("no-token" not in reasons, f"the stale answer never made the helper think no token is stored ({reasons})", b)
            bearers = [r for r in api.messages_requests() if r["headers"].get("authorization") == f"Bearer {old}"]
            check(bearers == [], f"no request carries the removed token ({len(bearers)})", b)
            check(not needle_in_proc(old), "no process holds the removed token", b)
        finally:
            b.stop()


def case_planted_keyring(binary: Path, tmp: Path, check) -> None:
    """RoseCat 5763/5794 advisory: an item planted in the Secret Service by another same-user
    program, not of the setup-token shape, is refused on fetch like a bad token file: no helper
    starts with it, no request or process carries it, the window does not call it connected,
    and the only trace is a fixed refusal line (never its bytes)."""
    planted = "sk-ant-api03-" + "".join(secrets.choice(CANARY_TAIL) for _ in range(40))  # an API key's shape
    world = provisioned(binary, tmp, "planted")
    with PrivateKeyring(tmp) as kr, fake_api(tmp, [{"text": "Scripted reply."}] * 4) as api:
        kr.plant(planted)
        check(kr.lookup() == planted, "precondition: the planted item is in the keyring")
        b = launch(binary, tmp, world, kr.bus_env, api, "planted")
        try:
            send_prompt(b, "hello")
            check(b.wait(lambda: any(r.fields[1:2] == ("no-token",) for r in b.rows("status", 1)), 20),
                  "the Send finds no usable token (status no-token)", b)
            check(b.wait(lambda: secrets_status(b) != [], 20), "the Secrets window opens", b)
            check("connected-secret-service" not in secrets_status(b),
                  f"the window does not call the planted item connected ({secrets_status(b)})", b)
            time.sleep(3.0)
            check(api.messages_requests() == [], f"no request reached the fake API ({len(api.messages_requests())})", b)
            check(not needle_in_proc(planted), "no process holds the planted item", b)
            printed = "\n".join(b.out + b.err)
            check(not leaks(printed, planted), "no run of the planted item in rows, stdout or stderr", b)
            check("zigBrowser: agent secrets: keyring token refused (bad-shape)" in printed,
                  "one fixed refusal line names the reason", b)
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
            check(window_lines(b) == [], f"and no Secrets window opens ({window_lines(b)[:3]})", b)
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
            rows = len(window_lines(b))
            b.wait(lambda: time.monotonic() - clicked > 6.0, 10)  # past the held-back clear answer
            check(not store.exists(), "the file is gone although the window closed first")
            check(kr.lookup() is None, "and so is the keyring item")
            check(window_lines(b)[rows:] == [], f"the late answer changed no row ({window_lines(b)[rows:]})", b)
        finally:
            b.stop()


def open_drawer(b) -> None:
    from agent_common import centre
    if not b.rows("open", 1):
        icon = b.wait_row("icon", 1)
        b.x.click(*centre(tuple(int(v) for v in icon.fields[0].split(","))))
        b.wait_row("open", 1, timeout=10)


def click_account(b) -> None:
    from agent_common import centre
    b.x.click(*centre(b.rows("account", 1)[-1].rect()))


def opens_now(b, seen: int, timeout: float = 15) -> bool:
    """A Secrets status row after the first `seen` ones, with the window on screen."""
    return b.wait(lambda: secrets_status(b)[seen:] != [] and bool(b.x.toplevels("Claude Agent account")), timeout)


def closed(b) -> bool:
    close_secrets_window(b)
    return b.wait(lambda: not b.x.toplevels("Claude Agent account"), 5)


def keyboard_account(b) -> bool:
    """Focus the drawer's input, then Ctrl+Shift+Tab (a text view keeps plain Tab for itself)
    until the Account button reports focus (at most 12 presses), then Space."""
    x, y, w, h = b.rows("open", 1)[-1].rect()
    b.x.click(x + w // 3, y + h - 24)  # the input row runs along the panel's bottom edge
    for _ in range(12):
        before = len(b.rows("focus", 1))
        b.x.key("Tab", ("Control_L", "Shift_L"))
        b.wait(lambda: len(b.rows("focus", 1)) > before, 2)
        if b.rows("focus", 1)[-1].fields[:1] == ("account",):
            b.x.key("space")
            return True
    return False


def case_account_button(binary: Path, tmp: Path, check) -> None:
    """RoseCat 5695, 5714 (D1, D11): the drawer header's Account button opens the Secrets
    window without any Send, here with the agent runtime missing: by an X click, again after
    the window was closed, and by the keyboard (Ctrl+Shift+Tab to `focus account`, then Space).
    Before each, no Secrets window is open. The window stays unreachable from the page."""
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
            check(secrets_status(b) == [] and not b.x.toplevels("Claude Agent account"),
                  "no Secrets window before the click", b)
            click_account(b)
            check(opens_now(b, 0), f"one click opens the Secrets window, no Send needed ({secrets_status(b)})", b)
            check([r for r in b.rows("msg", 1)] == [], "no message was sent", b)
            tree = [f[0] for k, f in secrets_lines(b) if k == "tree"]
            check(tree != [] and "WebKitWebView" not in tree[0], f"its tree has no WebKitWebView: {tree[:1]}", b)
            check(len(b.zb.page.list()["pages"]) == 1, "page.list does not list it", b)
            check(closed(b), "the window closed", b)
            seen = len(secrets_status(b))
            click_account(b)
            check(opens_now(b, seen), "the next click opens it again", b)
            check(closed(b), "closed again", b)
            seen = len(secrets_status(b))
            check(keyboard_account(b), f"Ctrl+Shift+Tab reaches the Account button ({[r.fields for r in b.rows('focus', 1)][-6:]})", b)
            check(opens_now(b, seen), "Space on the focused Account button opens the Secrets window", b)
        finally:
            b.stop()


def case_account_after_no_token(binary: Path, tmp: Path, check) -> None:
    """RoseCat 5714: the Account button also opens the Secrets window in another agent state:
    after a Send found no token (`DRAWER status unavailable no-token`, the window opened and
    was closed), with a working runtime."""
    world = provisioned(binary, tmp, "account-no-token")
    with fake_api(tmp) as api:
        b = launch(binary, tmp, world, no_session_bus_env({}, tmp), api, "account-no-token",
                   ["--agent-secret-store", "file"])
        try:
            send_prompt(b, "hello")
            check(b.wait(lambda: ("unavailable", "no-token") in [r.fields for r in b.rows("status", 1)], 30),
                  f"the agent is unavailable for want of a token ({[r.fields for r in b.rows('status', 1)]})", b)
            check(opens_now(b, 0), "the Send opened the Secrets window", b)
            check(closed(b), "the window closed", b)
            seen = len(secrets_status(b))
            time.sleep(1.0)
            check(secrets_status(b)[seen:] == [] and not b.x.toplevels("Claude Agent account"),
                  "no Secrets window before the click", b)
            row = b.rows("account", 1)
            check(row != [], "the Account button is reported", b)
            if row:
                click_account(b)
                check(opens_now(b, seen), "a click on Account opens it in this state too", b)
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
    import agent_setup_test
    from agent_common import host_python
    from agent_hook_net import hook_network_failures, install_probe, probe_command
    from agent_setup_test import World, run_setup
    agent_setup_test.PYTHON = host_python()  # World.env reads it (set only by that file's main)
    token = canary()
    world = World(tmp, "hooks")
    probe = install_probe(world.source / "hooks")
    results = {}
    settings = world.settings()
    settings["hooks"] = {}
    for event in HOOK_EVENTS:
        # The probe in the copied SAI (~ is the agent home when the hook runs); it writes its
        # record to the agent home's scratchpad itself: setup refuses any other path token.
        command, nonce = probe_command(Path("~/.claude/hooks") / probe.name, None)
        settings["hooks"][event] = [{"hooks": [{"type": "command", "command": command}]}]
        results[event] = (world.agent / "scratchpad" / f"hook-net-{nonce}.json", nonce)
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
    "account-after-no-token": case_account_after_no_token,
    "canary-self-test": case_canary_self_test,
    # The setup-token shape (the user's requirement after the S4a real-screen check).
    "shape": case_shape,
    "shape-file": case_shape_file,
    # S4b: the hand-off through S3b's helper (its build step runs these with --only).
    "handoff": case_handoff,
    "remove-session": case_remove_session,
    "hooks": case_hooks,
    # RoseCat 5813: Remove racing the helper's start (S4b).
    "remove-during-fetch": case_remove_during_fetch,
    "remove-during-net": case_remove_during_net,
    "send-during-clear": case_send_during_clear,
    "replace-during-fetch": case_replace_during_fetch,
    # RoseCat 5763/5794 advisory: a planted keyring item is shape-checked on fetch.
    "planted-keyring": case_planted_keyring,
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
