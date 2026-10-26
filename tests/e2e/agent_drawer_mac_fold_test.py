#!/usr/bin/env python3
"""Product e2e: the Mac drawer folds into its last S-icon position.

The e2e-only action clicks the real minus button after opening the native
drawer.  Product rows describe the views actually used for the animation, so
the test can require that the icon remains hidden through intermediate frames
and becomes visible only after the panel has disappeared at the saved spot.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

from automation_core_test import _read_lines
from mac_ms2a_routed_test import stop_browser_macos


RECT = re.compile(r"^-?\d+,-?\d+,\d+,\d+$")
PREFIX = "DRAWER\t1\t"


def rect(text: str) -> tuple[int, int, int, int]:
    if RECT.fullmatch(text) is None:
        raise ValueError(text)
    return tuple(int(value) for value in text.split(","))  # type: ignore[return-value]


def main() -> int:
    browser = Path(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/zigBrowser").resolve()
    if not browser.is_file():
        print(f"FAIL agent-drawer-mac-fold: missing browser {browser}", file=sys.stderr)
        return 1

    failures: list[str] = []
    with tempfile.TemporaryDirectory(prefix="zb-mac-agent-fold-") as raw:
        root = Path(raw)
        home, profile, temp = (root / name for name in ("home", "profile", "tmp"))
        for directory in (home, profile, temp):
            directory.mkdir(mode=0o700)
        env = dict(os.environ)
        env.update(
            {
                "HOME": str(home),
                "TMPDIR": str(temp),
                "ZB_DEBUG_DRAWER_FOLD": "1",
                "ZIGBROWSER_AGENT_ANIM_MS": "600",
            }
        )
        proc = subprocess.Popen(
            [
                str(browser),
                "about:blank",
                "--agent-drawer",
                "on",
                "--e2e-protocol",
                "--profile-dir",
                str(profile),
            ],
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        out: list[str] = []
        err: list[str] = []
        assert proc.stdout is not None and proc.stderr is not None
        threading.Thread(target=_read_lines, args=(proc.stdout, out), daemon=True).start()
        threading.Thread(target=_read_lines, args=(proc.stderr, err), daemon=True).start()
        try:
            deadline = time.monotonic() + 20.0
            while time.monotonic() < deadline:
                if any(line.startswith(PREFIX + "minimized\t") for line in out):
                    break
                if proc.poll() is not None:
                    break
                time.sleep(0.02)
        finally:
            stop_browser_macos(proc)

        rows = [line.split("\t") for line in out if line.startswith(PREFIX)]
        starts = [row for row in rows if len(row) == 8 and row[2] == "fold-start"]
        folds = [row for row in rows if len(row) == 7 and row[2] == "fold"]
        anims = [row for row in rows if len(row) == 7 and row[2] == "anim"]
        ends = [row for row in rows if len(row) == 6 and row[2] == "minimized"]
        if len(starts) != 1:
            failures.append(f"minus did not start one fold: {starts!r}")
        if len(anims) != 1:
            failures.append(f"fold did not finish one animation: {anims!r}")
        if len(ends) != 1:
            failures.append(f"fold did not finish minimized: {ends!r}")

        try:
            if starts:
                start, target = rect(starts[0][3]), rect(starts[0][4])
                if starts[0][5:] != ["panel=visible", "icon=hidden", "minus=clicked"]:
                    failures.append(f"wrong fold-start visibility/action: {starts[0][5:]!r}")
                parsed = [(int(row[3]), rect(row[4])) for row in folds]
                between = [item for item in parsed if item[1] not in {start, target}]
                if len(between) < 2:
                    failures.append(f"need two drawn intermediate frames, got {between!r}")
                if [item[0] for item in parsed] != sorted({item[0] for item in parsed}):
                    failures.append(f"fold frame ordinals are not strictly increasing: {parsed!r}")
                if any(row[5:] != ["icon=hidden", "panel=hidden"] for row in folds):
                    failures.append("icon or panel visibility changed during the fold")
                distances = [sum(abs(a - b) for a, b in zip(item[1], target)) for item in parsed]
                if distances and any(right >= left for left, right in zip(distances, distances[1:])):
                    failures.append(f"fold frames did not approach the last icon spot: {distances!r}")
                if anims:
                    if rect(anims[0][5]) != start or rect(anims[0][6]) != target:
                        failures.append(f"animation endpoints changed: {anims[0]!r}")
                    if int(anims[0][3]) < 3 or not 500 <= int(anims[0][4]) <= 1500:
                        failures.append(f"animation was not the stretched multi-frame fold: {anims[0]!r}")
                if ends and (rect(ends[0][3]) != target or ends[0][4:] != ["panel=hidden", "icon=visible"]):
                    failures.append(f"minimized state is not the last icon spot: {ends[0]!r}")
        except (ValueError, IndexError) as exc:
            failures.append(f"malformed fold evidence: {exc}")

    if failures:
        print(f"FAIL agent-drawer-mac-fold: {failures[0]}", file=sys.stderr)
        for failure in failures[1:]:
            print(f"  {failure}", file=sys.stderr)
        return 1
    print("PASS agent-drawer-mac-fold minus-animates-to-last-icon-spot")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
