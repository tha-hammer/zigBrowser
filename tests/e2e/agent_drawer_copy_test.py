#!/usr/bin/env python3
"""The drawer's text is selectable and copyable (the user's requirement, 2026-10-15;
RoseCat 4e49a13): every bubble role (user, assistant, system, error) and the header's
status text can be selected with the mouse and copied with Ctrl+C.

The real binary runs on its own Xvfb (xsession.py). The text comes from production
paths: the user's typed Send; the assistant and error bubbles from the helper process
(the scripted fake_host.py through ZIGBROWSER_AGENT_HOST_CMD, which needs
--e2e-protocol); the system bubble from a real helper crash; the status label from
the agent's state. The pointer is aimed with the `DRAWER <win> textrect <role> <rect>`
rows (where a bubble or the status label is on screen). Those rows only locate; they
are never the oracle. The oracle: the private display's CLIPBOARD is first owned by a
decoy text, then a real X selection (a double-click on a one-word text, a triple-click
on a whole line) and a real Ctrl+C must leave exactly the expected text in it, read by
a separate GTK process on that display.

The whole run sits in a network namespace of its own (re-exec'd as --sealed-child).
Exit 1 when Xvfb, xauth, bwrap, the venv or the binary is missing."""

from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import agent_host_lifecycle_test as life  # noqa: E402 - its world, seams and process table

DECOY = "zb-decoy-clipboard-text"
WORDS = {"user": "zbcopyuser7f3a", "assistant": "zbcopyassist91c", "error": "zbcopyerror5d2"}
CRASH = "Agent stopped (signal 9). Send to restart."

CLIPBOARD_OWNER = (
    "import gi, sys\n"
    "gi.require_version('Gtk', '3.0')\n"
    "from gi.repository import Gtk, Gdk\n"
    "c = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD); c.set_text(sys.argv[1], -1)\n"
    "print('owned', flush=True)\n"
    "Gtk.main()\n")
CLIPBOARD_READ = (
    "import gi\n"
    "gi.require_version('Gtk', '3.0')\n"
    "from gi.repository import Gtk, Gdk\n"
    "text = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD).wait_for_text()\n"
    "print(repr(text))\n")


def display_env(b) -> dict[str, str]:
    """The browser's private display, for the clipboard's own GTK processes."""
    return {"PATH": "/usr/bin:/bin", "DISPLAY": b.x.display_name, "XAUTHORITY": b.x.xauth,
            "HOME": str(b.dir), "LANG": "C.UTF-8", "NO_AT_BRIDGE": "1"}


def seed_decoy(b) -> subprocess.Popen:
    """A GTK process that owns CLIPBOARD with the decoy until it is killed."""
    owner = subprocess.Popen(["/usr/bin/python3", "-c", CLIPBOARD_OWNER, DECOY], env=display_env(b),
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    owner.stdout.readline()
    return owner


def clipboard(b) -> str | None:
    done = subprocess.run(["/usr/bin/python3", "-c", CLIPBOARD_READ], env=display_env(b),
                          capture_output=True, text=True, timeout=20)
    try:
        return eval(done.stdout.strip(), {})  # noqa: S307 - our own repr() of a str or None
    except SyntaxError:
        return None


def text_rect(b, role: str, win: int = 1, nth: int = -1):
    rows = [r for r in b.rows("textrect", win) if r.fields[0] == role]
    if not rows:
        return None
    return tuple(int(v) for v in rows[nth].fields[1].split(","))


def copy_and_check(b, check, role: str, expect: str, clicks: int, nth: int = -1) -> None:
    """Seeds the decoy, selects with `clicks` real clicks on the role's text, presses a
    real Ctrl+C, and requires exactly `expect` on the clipboard."""
    rect = text_rect(b, role, nth=nth)
    if not check(rect is not None, f"{role}: its text is on screen (textrect row)", b):
        return
    owner = seed_decoy(b)
    try:
        check(clipboard(b) == DECOY, f"{role}: the decoy owns the clipboard first")
        x, y = rect[0] + rect[2] // 2, rect[1] + rect[3] // 2
        for _ in range(clicks):  # within GTK's double-click time: a word, or (three) the whole line
            b.x.click(x, y, settle=0.02)
        time.sleep(0.3)
        b.x.key("c", modifiers=("Control_L",))
        time.sleep(0.5)
        got = clipboard(b)
        check(got == expect, f"{role}: mouse selection + Ctrl+C copies exactly {expect!r} (got {got!r})")
    finally:
        owner.kill()
        owner.wait()


def case_copy(binary: Path, tmp: Path, check) -> None:
    """Every bubble role and the status text: select with the mouse, copy with Ctrl+C."""
    rt = life.runtime_dir()
    w = life.world(binary, tmp, "copy")
    scratch = w.agent / "scratchpad"
    for name in ("fake-host-runs", "fake-host-frames.jsonl"):
        (scratch / name).unlink(missing_ok=True)
    on_prompt = [{"frame": {"type": "assistant_message", "session": "$SESSION", "text": WORDS["assistant"]}},
                 {"frame": {"type": "error", "session": "$SESSION", "code": "sdk", "message": WORDS["error"]}}]
    (scratch / "fake-host-script.json").write_text(json.dumps({"runs": [{"on_prompt": on_prompt}]}))
    b = life.launch(binary, tmp, "copy", life.env_for(w, rt, {"ZIGBROWSER_AGENT_HOST_CMD": str(life.FAKE_HOST_SCRIPT)}))
    try:
        life.send(b, WORDS["user"])
        check(b.wait(lambda: ("error", WORDS["error"]) in life.bubbles(b), 30), "the assistant and error bubbles are shown", b)
        check(b.wait(lambda: ("ready", "-") in life.statuses(b), 30), "the status says Ready", b)
        time.sleep(0.5)
        copy_and_check(b, check, "user", WORDS["user"], clicks=2)
        copy_and_check(b, check, "assistant", WORDS["assistant"], clicks=2)
        copy_and_check(b, check, "error", WORDS["error"], clicks=2)
        copy_and_check(b, check, "status", "Ready", clicks=2)
        helper = next((p for p in life.children_map().get(b.proc.pid, [])
                       if any(a.endswith("fake_host.py") for a in life.argv_of(p))), None)
        if check(helper is not None, "the helper (fake_host.py) runs, for the crash bubble"):
            os.kill(helper, signal.SIGKILL)
            check(b.wait(lambda: ("system", CRASH) in life.bubbles(b), 15), "the crash bubble is shown", b)
            time.sleep(0.5)
            copy_and_check(b, check, "system", CRASH, clicks=3)
    finally:
        life.release_x(b)
        b.stop()


CASES = {"copy": case_copy}


def main() -> int:
    if "--sealed-child" not in sys.argv:
        done = subprocess.run(["/usr/bin/bwrap", "--unshare-net", "--die-with-parent", "--dev-bind", "/", "/",
                               "--proc", "/proc", "--", sys.executable, str(Path(__file__).resolve()),
                               "--sealed-child", *sys.argv[1:]])
        return done.returncode
    sys.argv.remove("--sealed-child")
    from agent_common import run_main
    try:
        return run_main(__doc__, CASES)
    finally:
        for d in life.RUNTIME_DIRS:
            subprocess.run(["find", str(d), "-delete"], check=False)


if __name__ == "__main__":
    raise SystemExit(main())
