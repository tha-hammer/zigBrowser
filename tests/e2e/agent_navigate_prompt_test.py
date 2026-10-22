#!/usr/bin/env python3
"""S8 decision 16, part 4 red (RoseCat 7802 on 3405ad5, finding 1): a navigate card belongs to
the prompt whose validated tool_call asked for it, through the app's own boundary.

The real binary on its own Xvfb with the scripted helper (fake_host.py) in a network
namespace of its own, like agent_prompt_scope_test.py. The store says `yes`, so window 1's
own call (window 1 is the main window and its drawer is open) gets a card there. The
scripted helper sends a `tool_call` of mcp__zigbrowser__navigate for the running prompt, then:

- result: that prompt's `result` while its card waits: `approvalend <card> revoked`; a click
  where Approve was approves nothing; the page is not navigated;
- error: that prompt's error (sdk, its prompt_id): the same;
- stop: the drawer's Stop while the card waits: revoked at once, before the helper's own
  ending frame (the scripted helper answers the interrupt only 3 s later);
- stale-end: prompt 1's card is revoked by its result; prompt 2 asks again, and its run sends
  two more results for prompt 1 (a late and a duplicate end, each a rejected frame): prompt
  2's card waits on, its Approve navigates once; prompt 1's card never approves.

Stopping each browser signals its own process group, so the whole test runs in a PID
namespace of its own (RoseCat 7814), then sealed with bwrap, like agent_navigate_stale_test.py.
Exit 1 when Xvfb, xauth, bwrap, the venv or the binary is missing. Unregistered until its
green."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import agent_host_lifecycle_test as life  # noqa: E402
from agent_common import CLICK_GRID, centre  # noqa: E402

NAVIGATE = "mcp__zigbrowser__navigate"
TARGET = CLICK_GRID + "?navigated"
RESULT = {"frame": {"type": "result", "session": "$SESSION", "sdk_session_id": "fake-sdk-session", "subtype": "success",
                    "is_error": False, "num_turns": 1, "cost_usd": None}}
STOPPED = {"frame": {"type": "result", "session": "$SESSION", "sdk_session_id": "fake-sdk-session",
                     "subtype": "error_during_execution", "is_error": True, "num_turns": 1, "cost_usd": None}}
ERROR = {"frame": {"type": "error", "session": "$SESSION", "code": "sdk", "message": "the model's call failed"}}


def tool_call(n: int) -> dict:
    return {"frame": {"type": "tool_call", "session": "$SESSION", "id": f"00000000-0000-4000-8000-00000000000{n}",
                      "tool": NAVIGATE, "args": {"url": TARGET}}}


def stale(item: dict, prompt_id: int) -> dict:
    return {"frame": {**item["frame"], "prompt_id": prompt_id}}


class Run:
    def __init__(self, binary: Path, tmp: Path, label: str, script: dict) -> None:
        self.w = life.world(binary, tmp, "navprompt")
        scratch = self.w.agent / "scratchpad"
        for leftover in ("fake-host-runs", "fake-host-frames.jsonl"):
            (scratch / leftover).unlink(missing_ok=True)
        (scratch / "fake-host-script.json").write_text(json.dumps({"runs": [script]}))
        settings = self.w.agent / "settings"
        settings.mkdir(mode=0o700, exist_ok=True)
        store = settings / "navigate_approval"
        store.unlink(missing_ok=True)
        fd = os.open(store, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.write(fd, b"yes\n")
        os.close(fd)
        env = life.env_for(self.w, life.runtime_dir(), {"ZIGBROWSER_AGENT_HOST_CMD": str(life.FAKE_HOST_SCRIPT)})
        self.b = life.launch(binary, tmp, label, env)

    def close(self) -> None:
        life.release_x(self.b)
        self.b.stop()

    def ends(self, card: str) -> list[str]:
        return [r.fields[1] for r in self.b.rows("approvalend", 1) if r.fields[0] == card]

    def approved(self, card: str) -> bool:
        return any(r.fields[0] == card for r in self.b.rows("approvalstate", 1))

    def rect(self, card: str, button: str = "approve"):
        rects = [r for r in self.b.rows("approvalrect", 1) if r.fields[0] == card and r.fields[1] == button]
        return rects[-1].rect(2) if rects else None

    def card(self, n: int, timeout: float = 30.0) -> str | None:
        if not self.b.wait(lambda: len(self.b.rows("approval", 1)) >= n and self.rect(self.b.rows("approval", 1)[n - 1].fields[0]), timeout):
            return None
        return self.b.rows("approval", 1)[n - 1].fields[0]

    def search(self) -> str:
        return self.b.ev("location.search")

    def rejected(self) -> int:
        return len([line for line in self.b.err if "rejected frame (prompt)" in line])


def revoked_by(binary: Path, tmp: Path, check, label: str, after: list[dict]) -> None:
    """A tool_call, 2 s, then `after`: the card waits until `after`, which revokes it."""
    run = Run(binary, tmp, label, {"on_prompt": [tool_call(1), {"sleep": 2}, *after]})
    try:
        life.send(run.b, label)
        card = run.card(1)
        if not check(card is not None, f"{label}: the card is shown with its buttons", run.b):
            return
        spot = run.rect(card)
        check(run.ends(card) == [], f"{label}: it waits while its prompt runs")
        check(run.b.wait(lambda: run.ends(card) == ["revoked"], 15), f"{label}: the prompt's ending revokes it", run.b)
        run.b.x.click(*centre(spot))
        time.sleep(1.5)
        check(not run.approved(card), f"{label}: a click where Approve was approves nothing")
        check(run.search() == "", f"{label}: the page is not navigated ({run.search()!r})")
    finally:
        run.close()


def case_result(binary: Path, tmp: Path, check) -> None:
    revoked_by(binary, tmp, check, "result", [RESULT])


def case_error(binary: Path, tmp: Path, check) -> None:
    revoked_by(binary, tmp, check, "error", [ERROR])


def case_stop(binary: Path, tmp: Path, check) -> None:
    run = Run(binary, tmp, "stop", {"on_prompt": [tool_call(1)], "on_interrupt": [{"sleep": 3}, STOPPED]})
    try:
        life.send(run.b, "stop")
        card = run.card(1)
        if not check(card is not None, "stop: the card is shown with its buttons", run.b):
            return
        spot = run.rect(card)
        stop = run.b.rows("stop", 1)[-1]
        clicked = time.monotonic()
        run.b.x.click(*centre(stop.rect()))
        check(run.b.wait(lambda: run.ends(card) == ["revoked"], 2.5),
              f"stop: Stop revokes the card at once, before the helper's ending ({time.monotonic() - clicked:.1f} s)", run.b)
        run.b.x.click(*centre(spot))
        time.sleep(1.5)
        check(not run.approved(card), "stop: a click where Approve was approves nothing")
        check(run.search() == "", f"stop: the page is not navigated ({run.search()!r})")
    finally:
        run.close()


def case_stale_end(binary: Path, tmp: Path, check) -> None:
    script = {"on_prompts": [
        [tool_call(1), {"sleep": 2}, RESULT],
        [tool_call(2), {"sleep": 2}, stale(RESULT, 1), {"sleep": 0.5}, stale(RESULT, 1), {"sleep": 0.5}],
    ]}
    run = Run(binary, tmp, "stale-end", script)
    try:
        life.send(run.b, "one")
        first = run.card(1)
        if not check(first is not None, "stale-end: prompt 1's card is shown", run.b):
            return
        spot = run.rect(first)
        check(run.b.wait(lambda: run.ends(first) == ["revoked"], 15), "stale-end: prompt 1's result revokes its card", run.b)
        life.send(run.b, "two")
        second = run.card(2)
        if not check(second is not None and second != first, f"stale-end: prompt 2's own card ({second})", run.b):
            return
        check(run.b.wait(lambda: run.rejected() >= 2, 15), f"stale-end: the late and duplicate ends for prompt 1 are rejected ({run.rejected()})", run.b)
        time.sleep(1.0)
        check(run.ends(second) == [], f"stale-end: prompt 2's card waits on ({run.ends(second)})")
        run.b.x.click(*centre(spot))
        time.sleep(1.0)
        check(not run.approved(first), "stale-end: prompt 1's card never approves")
        run.b.x.click(*centre(run.rect(second)))
        check(run.b.wait(lambda: run.ends(second) == ["done"], 30), "stale-end: prompt 2's Approve runs it once", run.b)
        check(run.b.wait(lambda: run.search() == "?navigated", 10), f"stale-end: the page navigated ({run.search()!r})")
    finally:
        run.close()


CASES = {"result": case_result, "error": case_error, "stop": case_stop, "stale-end": case_stale_end}


def main() -> int:
    if "--pid-ns" not in sys.argv and "--sealed-child" not in sys.argv:
        # The signals this test sends (each browser's stop) stay inside a PID namespace of its own.
        done = subprocess.run(["unshare", "--user", "--map-current-user", "--pid", "--fork", "--kill-child", "--mount-proc",
                               sys.executable, str(Path(__file__).resolve()), "--pid-ns", *sys.argv[1:]])
        return done.returncode
    if "--sealed-child" not in sys.argv:
        args = [a for a in sys.argv[1:] if a != "--pid-ns"]
        done = subprocess.run(["/usr/bin/bwrap", "--unshare-net", "--die-with-parent", "--dev-bind", "/", "/",
                               "--proc", "/proc", "--", sys.executable, str(Path(__file__).resolve()),
                               "--sealed-child", *args])
        return done.returncode
    sys.argv.remove("--sealed-child")
    from agent_common import run_main
    try:
        return run_main(__doc__, CASES)
    finally:
        for d in life.RUNTIME_DIRS:
            if str(d).startswith("/tmp/zbl-"):
                subprocess.run(["find", str(d), "-delete"], check=False)


if __name__ == "__main__":
    raise SystemExit(main())
