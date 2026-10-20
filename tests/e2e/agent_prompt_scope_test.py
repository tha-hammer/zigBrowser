#!/usr/bin/env python3
"""S5d, prompt correlation (chat-drawer plan section 10, S5d, rev 16.20.16 and 16.20.17;
RoseCat 6136). Every prompt-scoped frame carries its prompt's `prompt_id`; a frame with a
stale or future id is rejected (reason `prompt`) and changes nothing in the app. Each case
runs prompt 1, presses Stop (its reply ends with its own id), then sends prompt 2 and,
while it runs, a third prompt that must wait in the app's queue:
- stale-delta: a delta with prompt 1's id after prompt 2's first delta joins nothing;
- stale-message: a message with prompt 1's id neither replaces nor ends prompt 2's bubble;
- stale-result: a result with prompt 1's id ends nothing: prompt 2 stays "Working…" and
  the third prompt stays queued; prompt 2's capped reply still overflows on time;
- stale-error: an error with prompt 1's id adds no error bubble and ends nothing;
- duplicate-ending: a second result for prompt 2 adds nothing;
- future-id: a delta with an id never written is rejected.
In each, prompt 2's bubble copies exactly its own text, the third prompt then runs, and the
browser's stderr has one `rejected frame (prompt)` line per stale frame.

Same world as agent_flood_test.py: the real binary on its own Xvfb, the scripted helper
(fake_host.py) in a network namespace of its own (re-exec'd as --sealed-child). Exit 1
when Xvfb, xauth, bwrap, the venv or the binary is missing."""

from __future__ import annotations

import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import agent_cap_test as cap  # noqa: E402 - its capped pieces
import agent_chat_test as chat  # noqa: E402 - the Stop button
import agent_flood_test as flood  # noqa: E402 - its scripted helper, copy check and fold
import agent_host_lifecycle_test as life  # noqa: E402

ID = "$PROMPT_ID"  # fake_host fills in the id of the prompt it answers
TWO = ["zb-two-a ", "zb-two-b"]
RESULT_REST = {"sdk_session_id": "fake-sdk-session", "subtype": "success", "is_error": False, "num_turns": 1,
               "cost_usd": None}


def frame(kind: str, prompt_id, **fields) -> dict:
    return {"frame": {"type": kind, "session": "$SESSION", "prompt_id": prompt_id, **fields}}


def delta(text: str, prompt_id=ID) -> dict:
    return frame("assistant_delta", prompt_id, text=text)


def result(prompt_id=ID, **over) -> dict:
    return frame("result", prompt_id, **{**RESULT_REST, **over})


STOPPED = result(subtype="error_during_execution", is_error=True)


def rejected(b) -> int:
    return len([line for line in b.err if "rejected frame (prompt)" in line])


def prompts_sent(w) -> int:
    return len([f for f in flood.app_frames(w) if f.get("type") == "prompt"])


def run(binary: Path, tmp: Path, check, label: str, second: list[dict], stale: int, hold: float = 4.0,
        shown: str = "".join(TWO), capped: bool = False, after_end: list[dict] = ()) -> None:
    """Prompt 1, Stop, prompt 2 (`second`, then `hold` s, then its end unless `capped`, then
    `after_end`), a queued prompt 3; `stale` frames must be rejected."""
    tail = [] if capped else [{"sleep": hold}, frame("assistant_message", ID, text=shown), result(), *after_end]
    script = {"on_prompts": [[delta("zb-one")], second + tail,
                             [frame("assistant_message", ID, text="zb-three"), result()]],
              "on_interrupt": [STOPPED]}
    w, b = flood.scripted(binary, tmp, label, script)
    try:
        if not check(b.wait_page(), "the page loaded", b):
            return
        life.send(b, "one")
        if not check(b.wait(lambda: len(b.rows("delta", 1)) >= 1, 30), f"{label}: prompt 1 streams", b):
            return
        rect = chat.stop_rect(b)
        if not check(rect is not None, f"{label}: Stop is on screen", b):
            return
        from agent_common import centre
        b.x.click(*centre(rect))
        if not check(b.wait(lambda: any(t.endswith("(stopped)") for r, t in life.bubbles(b) if r == "assistant"), 20),
                     f"{label}: Stop ends prompt 1 ({life.bubbles(b)[-2:]})", b):
            return
        flood.fold(b, check, f"{label}: before prompt 2")  # reopening focuses the input
        deltas_before = len(b.rows("delta", 1))
        life.send(b, "two")
        if not check(b.wait(lambda: len(b.rows("delta", 1)) >= deltas_before + 2, 30), f"{label}: prompt 2 streams", b):
            return
        life.send(b, "three")  # queued: prompt 2 still runs
        time.sleep(1.0)
        busy = [s for s in life.statuses(b)][-1:] == [("busy", "-")]
        check(busy and prompts_sent(w) == 2,
              f"{label}: prompt 2 still runs and prompt 3 waits in the queue ({life.statuses(b)[-2:]}, "
              f"{prompts_sent(w)} prompts sent)")
        flood.triple_copy(b, check, f"{label}: prompt 2's bubble, Ctrl+A", shown + (cap.TRUNCATED if capped else ""),
                          select_all=True)
        if capped:
            ok = b.wait(lambda: ("error", flood.OVERFLOW) in life.bubbles(b), 30)
            check(ok, f"{label}: prompt 2's capped reply still overflows on time ({life.bubbles(b)[-2:]})", b)
        check(b.wait(lambda: ("assistant", "zb-three") in life.bubbles(b), 60),
              f"{label}: prompt 3 runs after prompt 2 ends ({life.bubbles(b)[-2:]})", b)
        check(prompts_sent(w) == 3, f"{label}: exactly 3 prompts reached the helper ({prompts_sent(w)})")
        check(("error", "Agent error") not in life.bubbles(b), f"{label}: no error bubble ({life.bubbles(b)[-4:]})")
        check(rejected(b) == stale, f"{label}: {stale} rejected frame (prompt) line(s) ({rejected(b)})")
    finally:
        life.release_x(b)
        b.stop()


def case_stale_delta(binary: Path, tmp: Path, check) -> None:
    run(binary, tmp, check, "stale-delta", [delta(TWO[0]), delta("zb-STALE", 1), delta(TWO[1])], 1)


def case_stale_message(binary: Path, tmp: Path, check) -> None:
    run(binary, tmp, check, "stale-message",
        [delta(TWO[0]), frame("assistant_message", 1, text="zb-STALE"), delta(TWO[1])], 1)


def case_stale_result(binary: Path, tmp: Path, check) -> None:
    shown = "".join(cap.PIECES)
    second = [delta(p) for p in cap.PIECES] + [frame("reply_capped", ID), result(1)]
    run(binary, tmp, check, "stale-result", second, 1, shown=shown, capped=True)


def case_stale_error(binary: Path, tmp: Path, check) -> None:
    run(binary, tmp, check, "stale-error",
        [delta(TWO[0]), frame("error", 1, code="sdk", message="x"), delta(TWO[1])], 1)


def case_duplicate_ending(binary: Path, tmp: Path, check) -> None:
    run(binary, tmp, check, "duplicate-ending", [delta(TWO[0]), delta(TWO[1])], 1, hold=2.0, after_end=[result()])


def case_future_id(binary: Path, tmp: Path, check) -> None:
    run(binary, tmp, check, "future-id", [delta(TWO[0]), delta("zb-FUTURE", 9), delta(TWO[1])], 1)


CASES = {"stale-delta": case_stale_delta, "stale-message": case_stale_message, "stale-result": case_stale_result,
         "stale-error": case_stale_error, "duplicate-ending": case_duplicate_ending, "future-id": case_future_id}


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
