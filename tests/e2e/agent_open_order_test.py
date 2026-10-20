#!/usr/bin/env python3
"""S5d fix-forward (RoseCat 6296): a session's first prompt is written only after its
`session_opened`. A helper that cannot open a session says so with a session `error`
whose `prompt_id` is null; while the app has written no prompt to that session, that is
the only id it can give, and the validator accepts it. Each case uses the scripted helper
(fake_host.py, its "on_opens"):
- open-fails: the first open fails. The app wrote no prompt to that session; one
  "Agent error" bubble; no frame is rejected; the next prompt opens a new session and is
  answered.
- open-fails-two-queued: two prompts wait for an open that fails. The failure ends exactly
  the first; the second opens a new session and runs: exactly one prompt reaches the
  helper.
- close-before-open: a popup's prompt waits for a slow open, and the popup closes first.
  No prompt is written to its session; the browser runs on with no GTK warning, and the
  opener still answers.

Same world as agent_flood_test.py: the real binary on its own Xvfb in a network namespace
of its own (re-exec'd as --sealed-child). Exit 1 when Xvfb, xauth, bwrap, the venv or the
binary is missing."""

from __future__ import annotations

import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import agent_flood_test as flood  # noqa: E402 - its scripted helper
import agent_host_lifecycle_test as life  # noqa: E402

AGENT_ERROR = "Agent error"
OPENED = {"frame": {"type": "session_opened", "session": "$SESSION"}}
OPEN_FAILS = {"frame": {"type": "error", "session": "$SESSION", "prompt_id": None, "code": "sdk",
                        "message": "session could not open"}}


def prompts(w) -> list[dict]:
    return [f for f in flood.app_frames(w) if f.get("type") == "prompt"]


def rejected(b) -> list[str]:
    return [line for line in b.err if "rejected frame" in line]


def errors(b, win: int = 1) -> int:
    return [r for r, t in life.bubbles(b, win)].count("error")


def case_open_fails(binary: Path, tmp: Path, check) -> None:
    script = {"on_opens": [[OPEN_FAILS], [OPENED]],
              "on_prompts": [[flood.frame("assistant_message", text="zb-second"), flood.RESULT]]}
    w, b = flood.scripted(binary, tmp, "open-fails", script)
    try:
        if not check(b.wait_page(), "the page loaded", b):
            return
        life.send(b, "first")
        if not check(b.wait(lambda: errors(b) >= 1, 30), f"open-fails: an error bubble ({life.bubbles(b)})", b):
            return
        time.sleep(1.0)
        check(errors(b) == 1 and ("error", AGENT_ERROR) in life.bubbles(b), f"open-fails: one Agent error ({life.bubbles(b)})")
        check(prompts(w) == [], f"open-fails: no prompt was written to the session that never opened ({prompts(w)})")
        check(rejected(b) == [], f"open-fails: no frame was rejected ({rejected(b)[:3]})")
        life.send(b, "second")
        check(b.wait(lambda: ("assistant", "zb-second") in life.bubbles(b), 30),
              f"open-fails: the next prompt opens a new session and is answered ({life.bubbles(b)[-2:]})", b)
        sent = prompts(w)
        check([(p.get("text"), p.get("session"), p.get("prompt_id")) for p in sent] == [("second", "s-1-2", 1)],
              f"open-fails: exactly the second prompt, on the new session, as its prompt 1 ({sent})")
        check(rejected(b) == [], f"open-fails: still no frame rejected ({rejected(b)[:3]})")
    finally:
        life.release_x(b)
        b.stop()


def case_open_fails_two_queued(binary: Path, tmp: Path, check) -> None:
    script = {"on_opens": [[{"sleep": 2}, OPEN_FAILS], [OPENED]],
              "on_prompts": [[flood.frame("assistant_message", text="zb-the-second"), flood.RESULT]]}
    w, b = flood.scripted(binary, tmp, "open-fails-two", script)
    try:
        if not check(b.wait_page(), "the page loaded", b):
            return
        life.send(b, "first")
        life.send(b, "second")  # both wait for the slow open
        check(b.wait(lambda: ("assistant", "zb-the-second") in life.bubbles(b), 40),
              f"open-fails-two-queued: the second prompt runs on a new session ({life.bubbles(b)[-3:]})", b)
        sent = prompts(w)
        check([(p.get("text"), p.get("session")) for p in sent] == [("second", "s-1-2")],
              f"open-fails-two-queued: the failure ended exactly the first; one prompt reached the helper ({sent})")
        check(errors(b) == 1, f"open-fails-two-queued: one error bubble ({life.bubbles(b)})")
        check(rejected(b) == [], f"open-fails-two-queued: no frame rejected ({rejected(b)[:3]})")
    finally:
        life.release_x(b)
        b.stop()


def case_close_before_open(binary: Path, tmp: Path, check) -> None:
    script = {"on_opens": [[OPENED], [{"sleep": 3}, OPENED], [OPENED]],
              "on_prompts": [[flood.frame("assistant_message", text="zb-opener"), flood.RESULT]],
              "on_end": [{"frame": {"type": "session_ended", "session": "$SESSION", "reason": "end"}}]}
    w, b = flood.scripted(binary, tmp, "close-before-open", script)
    try:
        if not check(b.wait_page(), "the page loaded", b):
            return
        life.send(b, "opener")
        if not check(b.wait(lambda: ("assistant", "zb-opener") in life.bubbles(b), 30), "the opener answers", b):
            return
        if not check(b.open_popup() and b.wait(lambda: b.rows("icon", 2) != [], 20), "the popup has its drawer", b):
            return
        life.send(b, "popup", win=2)
        time.sleep(0.5)  # its open_session is out; session_opened is 3 s away
        b.zb.call("page.close", {"window_id": "window-2"})
        check(b.wait(lambda: len(b.zb.page.list()["pages"]) == 1, 15), "the popup closed before its session opened", b)
        time.sleep(4.0)  # the late session_opened arrives
        popup = [p for p in prompts(w) if p.get("session", "").startswith("s-2-")]
        check(popup == [], f"close-before-open: no prompt was written to the closed popup's session ({popup})")
        check(b.proc.poll() is None, "the browser still runs", b)
        check(b.gtk_complaints() == [], f"no GTK warning or critical ({b.gtk_complaints()[:3]})")
        life.send(b, "again", win=1)
        check(b.wait(lambda: life.bubbles(b, 1).count(("assistant", "zb-opener")) >= 2, 30),
              f"the opener still answers ({life.bubbles(b, 1)[-2:]})", b)
        check(rejected(b) == [], f"close-before-open: no frame rejected ({rejected(b)[:3]})")
    finally:
        life.release_x(b)
        b.stop()


CASES = {"open-fails": case_open_fails, "open-fails-two-queued": case_open_fails_two_queued,
         "close-before-open": case_close_before_open}


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
