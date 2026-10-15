"""The display guard (orchestrator HARD RULE, 2026-10-15). build.zig runs it before
every step of a top-level step (all but `run`, the install steps, `agent-runtime`
and `mac-gate`), so no build or test step can open a browser or a GTK window on
the user's real screen.

It refuses (exit 1, one stderr line) unless DISPLAY is unset or names a local X
server (`:N` or `:N.S`) whose X lock (/tmp/.XN-lock) belongs to a live Xvfb, and
WAYLAND_DISPLAY is unset. ZB_ALLOW_REAL_DISPLAY=1 overrides it. Standard library only."""

import os
import re
import sys
from pathlib import Path

LOCAL_DISPLAY = re.compile(r":(\d+)(?:\.\d+)?")
HOW = "run it under a private Xvfb (env -u WAYLAND_DISPLAY xvfb-run -a ...) or set ZB_ALLOW_REAL_DISPLAY=1"


def xvfb_owns(number, tmp_dir, proc_dir):
    """True when display :number's X lock names a live process called Xvfb."""
    try:
        pid = int((Path(tmp_dir) / f".X{number}-lock").read_text(encoding="ascii").strip())
        return (Path(proc_dir) / str(pid) / "comm").read_text().strip() == "Xvfb"
    except (OSError, ValueError):
        return False


def refusal(env, tmp_dir="/tmp", proc_dir="/proc"):
    """The refusal line for `env`, or None when its steps may run."""
    if env.get("ZB_ALLOW_REAL_DISPLAY") == "1":
        return None
    if env.get("WAYLAND_DISPLAY"):
        return f"zigBrowser build: refusing: WAYLAND_DISPLAY is set (GTK would use it); {HOW}"
    display = env.get("DISPLAY", "")
    if not display:
        return None
    match = LOCAL_DISPLAY.fullmatch(display)
    if match is None or not xvfb_owns(int(match.group(1)), tmp_dir, proc_dir):
        return f"zigBrowser build: refusing: DISPLAY={display} is not a private Xvfb; {HOW}"
    return None


if __name__ == "__main__":
    line = refusal(os.environ)
    if line is not None:
        print(line, file=sys.stderr)
        sys.exit(1)
