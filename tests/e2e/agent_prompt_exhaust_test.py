#!/usr/bin/env python3
"""S5d fix-forward (RoseCat 6307, 6314, 6351): a session whose prompt ids are spent, through
the app's real chain (agent_helper.c and the drawer). The e2e-only seam
ZIGBROWSER_AGENT_TEST_PROMPT_BASE starts each new session's prompt ids at 2^53 - 2, so:
- spent: window 1's first prompt goes out as prompt 2^53 - 1 and is answered; its second
  Send writes no prompt frame and shows exactly one "Agent error" bubble (never "Message
  too long"); the app's next frame (the popup's open_session) has the next seq, so none
  was skipped.

The decision that the seam is inert without --e2e-protocol is unit-tested in
tests/agent_prompt_base_test.zig. Same world as agent_flood_test.py: the real binary on
its own Xvfb in a network namespace of its own (re-exec'd as --sealed-child). Exit 1 when
Xvfb, xauth, bwrap, the venv or the binary is missing."""

from __future__ import annotations

import json
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import agent_flood_test as flood  # noqa: E402 - its frames and app_frames
import agent_host_lifecycle_test as life  # noqa: E402

MAX_ID = (1 << 53) - 1
BASE = MAX_ID - 1
TOO_LONG = "Message too long (64 KiB at most)"


def case_spent(binary: Path, tmp: Path, check) -> None:
    w = life.world(binary, tmp, "prompt-exhaust")
    scratch = w.agent / "scratchpad"
    for leftover in ("fake-host-runs", "fake-host-frames.jsonl"):
        (scratch / leftover).unlink(missing_ok=True)
    script = {"on_prompts": [[flood.frame("assistant_message", text="zb-the-last"), flood.RESULT]]}
    (scratch / "fake-host-script.json").write_text(json.dumps({"runs": [script]}))
    env = life.env_for(w, life.runtime_dir(), {"ZIGBROWSER_AGENT_HOST_CMD": str(life.FAKE_HOST_SCRIPT),
                                               "ZIGBROWSER_AGENT_TEST_PROMPT_BASE": str(BASE)})
    b = life.launch(binary, tmp, "prompt-exhaust", env)
    try:
        if not check(b.wait_page(), "the page loaded", b):
            return
        life.send(b, "one")
        if not check(b.wait(lambda: ("assistant", "zb-the-last") in life.bubbles(b), 30), "the last prompt is answered", b):
            return
        prompts = [f for f in flood.app_frames(w) if f.get("type") == "prompt"]
        check([p.get("prompt_id") for p in prompts] == [MAX_ID], f"it went out as prompt 2^53-1 ({prompts})")
        last_seq = max(f["seq"] for f in flood.app_frames(w))
        life.send(b, "two")
        check(b.wait(lambda: ("error", "Agent error") in life.bubbles(b), 15),
              f"the spent session's Send shows Agent error ({life.bubbles(b)[-2:]})", b)
        time.sleep(1.0)
        bubbles = life.bubbles(b)
        check(bubbles.count(("error", "Agent error")) == 1 and ("error", TOO_LONG) not in bubbles,
              f"exactly one Agent error, never too-long ({bubbles[-3:]})")
        after = [f for f in flood.app_frames(w) if f.get("type") == "prompt"]
        check(len(after) == 1, f"no prompt frame for the spent Send ({after})")
        if not check(b.open_popup() and b.wait(lambda: b.rows("icon", 2) != [], 20), "the popup has its drawer", b):
            return
        life.send(b, "popup", win=2)
        check(b.wait(lambda: any(f.get("type") == "open_session" and f.get("session", "").startswith("s-2-")
                                 for f in flood.app_frames(w)), 15), "the popup's session opens", b)
        opened = [f for f in flood.app_frames(w) if f.get("type") == "open_session" and f["session"].startswith("s-2-")]
        check(bool(opened) and opened[0]["seq"] == last_seq + 1,
              f"the next frame has the next seq, none skipped (last {last_seq}, next {opened[:1]})")
        check([l for l in b.err if "rejected frame" in l] == [], "nothing rejected")
    finally:
        life.release_x(b)
        b.stop()


CASES = {"spent": case_spent}


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
