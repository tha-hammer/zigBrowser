#!/usr/bin/env python3
"""Shared pieces for the Claude Agent drawer E2E tests.

`parse_row` checks every `DRAWER` row against the plan's D7b table
(thoughts/searchable/shared/plans/2026-10-13-claude-agent-chat-drawer-tdd-plan.md):
a row that does not match its kind's exact field shape raises `RowError`,
so a test can never pass on a malformed row. `<rect>` is `x,y,w,h` in root
coordinates."""

from __future__ import annotations

import argparse
import ctypes.util
import json
import math
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import dataclass
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(REPO / "sdk/python/src"))

from slice2_common import isolate_profile_env, stop_browser  # noqa: E402
from xinput import XInput  # noqa: E402
from zigbrowser import ZigBrowser  # noqa: E402

ENV = "ZIGBROWSER_AGENT_DRAWER"
CLICK_GRID = (REPO / "tests/fixtures/agent/click-grid.html").resolve().as_uri()
ICON = 56
MARGIN = 24
WIN_W, WIN_H = 1024, 768

RECT = r"-?\d+,-?\d+,\d+,\d+"
TEXT = r"[^\t]{0,4100}"  # 4 KiB cap plus the "…" marker
REASON = r"-|runtime-missing|sandbox|hook-isolation|config-changed|cli-changed|no-token|home-locked|network|exit-\d+|signal-\d+"

# kind -> one regex per field after <win> and <kind>.
DRAWER_KINDS: dict[str, list[str]] = {
    "icon": [RECT],
    "open": [RECT],
    "minus": [RECT],
    "anim": [r"\d+", RECT, RECT],
    "minimized": [RECT],
    "fold": [r"\d+", RECT],
    "focus": [r"icon|input|send|stop|minus|list|approve|deny"],
    "scroll": [r"bottom|\d+(\.\d+)?"],
    "msg": [r"user|assistant|system|approval|error", TEXT],
    "delta": [r"[^\t]+", TEXT],
    "status": [r"stopped|starting|ready|busy|crashed|unavailable", REASON],
    "approval": [r"[^\t]+", r"[^\t]+", r"[^\t]+", r"[^\t]+", r"[0-9a-f]+"],
    "idles": [r"\d+"],
    "unread": [r"shown|hidden"],
    "tree": [r"[A-Za-z0-9_]+(,[A-Za-z0-9_]+)*"],
    "windows": [r"-|{w}(,{w})*".format(w=r"(-|[A-Za-z0-9_]+):(output|input):(viewable|hidden):[1-9]\d*:-?\d+:-?\d+:\d+:\d+")],
}


class RowError(AssertionError):
    pass


@dataclass(frozen=True)
class Row:
    win: int
    kind: str
    fields: tuple[str, ...]

    def rect(self, index: int = 0) -> tuple[int, int, int, int]:
        x, y, w, h = (int(v) for v in self.fields[index].split(","))
        return x, y, w, h


def parse_row(line: str) -> Row:
    """One `DRAWER\\t<win>\\t<kind>\\t...` stdout line -> Row, or RowError."""
    parts = line.split("\t")
    if len(parts) < 3 or parts[0] != "DRAWER":
        raise RowError(f"not a DRAWER row: {line!r}")
    if not re.fullmatch(r"[1-9]\d*", parts[1]):
        raise RowError(f"bad window id in {line!r}")
    kind = parts[2]
    shape = DRAWER_KINDS.get(kind)
    if shape is None:
        raise RowError(f"unknown DRAWER kind {kind!r} in {line!r}")
    fields = parts[3:]
    if len(fields) != len(shape) or not all(re.fullmatch(p, f) for p, f in zip(shape, fields)):
        raise RowError(f"DRAWER {kind} row does not match D7b: {line!r}")
    return Row(int(parts[1]), kind, tuple(fields))


def drawer_rows(lines: list[str]) -> list[Row]:
    """Every DRAWER row in `lines`, each validated (RowError on the first bad one)."""
    return [parse_row(line) for line in lines if line.startswith("DRAWER\t") or line == "DRAWER"]


# --- the expected geometry (mirrors src/agent_drawer.zig) -----------------
def clamp_rect(x: int, y: int, w: int, h: int) -> tuple[int, int, int, int]:
    return max(0, min(x, w - ICON)), max(0, min(y, h - ICON)), ICON, ICON


def default_rect(w: int, h: int) -> tuple[int, int, int, int]:
    return clamp_rect(w - MARGIN - ICON, h - MARGIN - ICON, w, h)


def rect_from_ratios(rx: float, ry: float, w: int, h: int) -> tuple[int, int, int, int]:
    return clamp_rect(math.floor(rx * w - ICON / 2 + 0.5), math.floor(ry * h - ICON / 2 + 0.5), w, h)


def drawer_rect(w: int, h: int) -> tuple[int, int, int, int]:
    tall = min(max(math.floor(h * 0.4 + 0.5), 220), math.floor(h * 0.7))
    return 0, h - tall, w, tall


def centre(r: tuple[int, int, int, int]) -> tuple[int, int]:
    return r[0] + r[2] // 2, r[1] + r[3] // 2


def close_rect(a, b, tol: int = 1) -> bool:
    return a[2:] == b[2:] and abs(a[0] - b[0]) <= tol and abs(a[1] - b[1]) <= tol


def near(rgb: tuple[int, int, int], want: tuple[int, int, int], tol: int = 24) -> bool:
    return all(abs(a - b) <= tol for a, b in zip(rgb, want))


# --- one browser on its own display -----------------------------------------
class Browser:
    """One zigBrowser on its own Xvfb, with its stdout/stderr collected."""

    def __init__(self, binary: Path, tmp: Path, label: str, args: list[str], env_extra: dict[str, str] | None = None,
                 profile: Path | None = None, automation: bool = True, env: dict[str, str] | None = None,
                 url: str = CLICK_GRID, e2e: bool = True) -> None:
        self.label = label
        self.url = url
        self.dir = Path(tempfile.mkdtemp(prefix="run-", dir=tmp))
        self.display_file = self.dir / "display"
        self.socket = self.dir / "automation.sock"
        self.env = env if env is not None else isolate_profile_env(dict(os.environ))
        for name in ("DISPLAY", "WAYLAND_DISPLAY", "XAUTHORITY", "ZIGBROWSER_SOCKET", ENV):
            self.env.pop(name, None)
        self.env.update(env_extra or {})
        self.env["ZIGBROWSER_SOCKET"] = str(self.socket)
        cmd = [sys.executable, str(HERE / "xsession.py"), "--xvfb", "--display-file", str(self.display_file), "--",
               str(binary.resolve()), url] + (["--e2e-protocol"] if e2e else [])
        if automation:
            cmd.append("--automation-api")
        if profile is not None:
            cmd += ["--profile-dir", str(profile)]
        self.out: list[str] = []
        self.err: list[str] = []
        self.proc = subprocess.Popen(cmd + args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                     env=self.env, cwd=self.dir)
        threading.Thread(target=self._drain, args=(self.proc.stdout, self.out), daemon=True).start()
        threading.Thread(target=self._drain, args=(self.proc.stderr, self.err), daemon=True).start()
        self._x: XInput | None = None
        self._zb: ZigBrowser | None = None

    @staticmethod
    def _drain(stream, sink: list[str]) -> None:
        for line in stream:
            sink.append(line.rstrip("\n"))

    def rows(self, kind: str | None = None, win: int | None = None) -> list[Row]:
        return [r for r in drawer_rows(list(self.out)) if (kind is None or r.kind == kind) and (win is None or r.win == win)]

    def wait(self, predicate, timeout: float = 20.0) -> bool:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return True
            if self.proc.poll() is not None:
                return bool(predicate())
            time.sleep(0.05)
        return bool(predicate())

    def wait_row(self, kind: str, win: int = 1, count: int = 1, timeout: float = 20.0) -> Row | None:
        if self.wait(lambda: len(self.rows(kind, win)) >= count, timeout):
            return self.rows(kind, win)[count - 1]
        return None

    @property
    def x(self) -> XInput:
        if self._x is None:
            if not self.wait(self.display_file.exists, 20):
                raise RuntimeError(f"{self.label}: no display file (browser exit {self.proc.poll()})")
            self._x = XInput.from_display_file(self.display_file)
        return self._x

    @property
    def zb(self) -> ZigBrowser:
        if self._zb is None:
            if not self.wait(self.socket.exists, 20):
                raise RuntimeError(f"{self.label}: no automation socket (browser exit {self.proc.poll()})")
            self._zb = ZigBrowser(socket_path=str(self.socket))
            self._zb.__enter__()
        return self._zb

    def ev(self, expression: str, window: str = "window-1"):
        return self.zb.call("page.evaluate", {"expression": expression, "window_id": window})["result"]

    def wait_page(self, window: str = "window-1") -> bool:
        def ready() -> bool:
            try:
                return self.ev("window.__ready === true", window) is True
            except Exception:  # noqa: BLE001 - still loading
                return False
        return self.wait(ready, 20)

    def clicks(self) -> list[list[int]]:
        return json.loads(self.ev("JSON.stringify(window.__clicks)"))

    def open_popup(self) -> bool:
        self.ev(f"(window.open({json.dumps(self.url + '#popup')}), 1)")
        return self.wait(lambda: len(self.zb.page.list()["pages"]) == 2, 15)

    def stop(self) -> int | None:
        if self._zb is not None:
            try:
                self._zb.__exit__(None, None, None)
            except Exception:  # noqa: BLE001 - the browser may be gone
                pass
            self._zb = None
        if self._x is not None:
            self._x.close()
            self._x = None
        code = stop_browser(self.proc)
        time.sleep(0.2)
        return code

    def gtk_complaints(self) -> list[str]:
        """GTK/GLib warnings and criticals the browser printed (stderr)."""
        return [line for line in self.err if re.search(r"(Gtk|Gdk|GLib|GLib-GObject|Pango)-(WARNING|CRITICAL)", line)]

    def tail(self) -> str:
        return "stdout:\n" + "\n".join(self.out[-25:]) + "\nstderr:\n" + "\n".join(self.err[-25:])


class Checks:
    def __init__(self) -> None:
        self.failures: list[str] = []
        self.count = 0

    def __call__(self, ok: bool, label: str, browser: Browser | None = None) -> bool:
        self.count += 1
        print(f"{'ok  ' if ok else 'FAIL'} {label}", flush=True)
        if not ok:
            self.failures.append(label)
            if browser is not None:
                print(browser.tail(), file=sys.stderr, flush=True)
        return ok


# --- the shared test runner ---------------------------------------------------
def missing_requirements(binary: Path) -> list[str]:
    """What a drawer E2E cannot run without (each a failure, never a skip)."""
    return [name for name, ok in (("binary", binary.is_file()), ("Xvfb", shutil.which("Xvfb")),
                                  ("xauth", shutil.which("xauth")), ("xwd", shutil.which("xwd")),
                                  ("libXtst", ctypes.util.find_library("Xtst"))) if not ok]


def run_main(doc: str, cases: dict) -> int:
    """`--binary B [--only a,b]`: runs each case(binary, tmp, check) in turn.
    Exit 1 on a missing requirement, a failed check, or no check at all."""
    parser = argparse.ArgumentParser(description=doc)
    parser.add_argument("--binary", default="zig-out/bin/zigBrowser")
    parser.add_argument("--only", default="", help="comma-separated case names: " + ",".join(cases))
    args = parser.parse_args()
    binary = Path(args.binary)
    missing = missing_requirements(binary)
    if missing:
        print(f"FAIL: missing hard requirements: {', '.join(missing)}", file=sys.stderr)
        return 1
    chosen = [c for c in args.only.split(",") if c] or list(cases)
    check = Checks()
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(1))
    with tempfile.TemporaryDirectory(prefix="zb-agent-e2e-") as tmp:
        for name in chosen:
            try:
                cases[name](binary, Path(tmp), check)
            except Exception as exc:  # noqa: BLE001 - every failure is reported the same way
                check(False, f"{name}: error {exc!r}")
    print(f"{check.count} checks, {len(check.failures)} failed", flush=True)
    return 1 if check.failures or check.count == 0 else 0


# --- the helper runtime and the inotify oracle (S3) -------------------------
def host_python() -> str:
    """The helper venv's python (tools/agent_host_env.sh --check); a missing
    venv fails the test (never a skip)."""
    done = subprocess.run([str(REPO / "tools" / "agent_host_env.sh"), "--check"], capture_output=True, text=True)
    path = done.stdout.strip()
    if done.returncode != 0 or not path:
        raise SystemExit(f"FAIL: helper venv missing: {done.stderr.strip()} (run tools/agent_host_env.sh)")
    return path


class Inotify:
    """Every inotify event under the watched trees (recursive, all events),
    for "nothing touched this" assertions. Opens are kernel events, so
    relatime and noatime cannot hide them."""

    IN_ALL_EVENTS = 0x00000FFF
    IN_NONBLOCK, IN_CLOEXEC = 0o4000, 0o2000000

    def __init__(self, *roots: Path) -> None:
        import ctypes
        import ctypes.util
        self._libc = ctypes.CDLL(ctypes.util.find_library("c") or "libc.so.6", use_errno=True)
        self._fd = self._libc.inotify_init1(self.IN_NONBLOCK | self.IN_CLOEXEC)
        if self._fd < 0:
            raise OSError(ctypes.get_errno(), "inotify_init1")
        self._paths: dict[int, str] = {}
        for root in roots:
            for directory in [Path(root)] + [p for p in Path(root).rglob("*") if p.is_dir() and not p.is_symlink()]:
                wd = self._libc.inotify_add_watch(self._fd, os.fsencode(str(directory)), self.IN_ALL_EVENTS)
                if wd < 0:
                    raise OSError(ctypes.get_errno(), f"inotify_add_watch {directory}")
                self._paths[wd] = str(directory)

    def events(self) -> list[tuple[str, int]]:
        """(path, mask) of every event so far."""
        import struct
        out = []
        while True:
            try:
                data = os.read(self._fd, 65536)
            except BlockingIOError:
                return out
            offset = 0
            while offset < len(data):
                wd, mask, _cookie, length = struct.unpack_from("iIII", data, offset)
                name = data[offset + 16: offset + 16 + length].rstrip(b"\0").decode(errors="replace")
                out.append((os.path.join(self._paths.get(wd, "?"), name), mask))
                offset += 16 + length

    def close(self) -> None:
        os.close(self._fd)
