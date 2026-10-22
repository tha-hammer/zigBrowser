#!/usr/bin/env python3
"""S7b follow-ups (RoseCat 6843 on 83c9d96; BlackRobin 6902): the tool deadline seam
ZIGBROWSER_AGENT_TEST_TOOL_DEADLINE_S on the real binary, helper and CLI against the TLS fake
Messages API, sealed in a network namespace of its own (as agent_tools_acceptance2_test.py,
whose deadline-seam case shows the value reaching hello).

- deadline-broker: H = 12 gives the broker B = 12 - min(5, 12/4) = 9 s. A wait_for of 10 s on an
  element that never hides comes back as "The browser did not answer in time." before the
  helper's own 12 s. A broker still on the 120 s constant lets the engine's own 10 s timeout
  answer first, a different text (so no timing margin decides it).
- deadline-refused: "abc" with --e2e-protocol: after a Send, stderr holds the fixed refusal
  line exactly once, the drawer says "Agent unavailable: a test seam was refused", and no
  helper runs.
- deadline-inert: "abc" without --e2e-protocol is ignored: no refusal line, the real helper
  runs, and its hello carries no e2e seam.
Exit 1 when Xvfb, xauth, bwrap, the venv or the binary is missing."""

from __future__ import annotations

import json
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import agent_host_lifecycle_test as life  # noqa: E402
import agent_tools_acceptance_test as acc  # noqa: E402 - steps, answers
import agent_tools_test as tools  # noqa: E402

ENV = "ZIGBROWSER_AGENT_TEST_TOOL_DEADLINE_S"
REFUSAL = "zigBrowser: agent: test tool deadline must be an integer from 1 to 120"
REFUSED_BUBBLE = "Agent unavailable: a test seam was refused"
NO_ANSWER = "The browser did not answer in time."


def case_deadline_broker(binary: Path, tmp: Path, check) -> None:
    from agent_common import Browser
    fake = life.Fake(tmp)
    script = [{"name": "mcp__zigbrowser__wait_for", "input": {"selector": "css=#greeting", "state": "hidden", "timeout_ms": 10000}}]
    fake.api.responder = acc.steps("deadline", script)
    w = life.world(binary, tmp, "deadline-broker")
    env = life.env_for(w, life.runtime_dir(), {**fake.seams(), ENV: "12"})
    b = Browser(binary, tmp, "deadline-broker", ["--agent-drawer", "on", "--agent-secret-store", "file"], env=env,
                url=tools.page_url(tmp))
    try:
        if not check(b.wait_page(), "the page loaded", b):
            return
        life.send(b, "deadline")
        asked = time.monotonic()
        if not check(b.wait(lambda: len(fake.api.messages_requests()) >= 1, 60), "the prompt reached the API", b):
            return
        got = acc.answers(fake, 1, timeout=60)
        took = time.monotonic() - asked
        text = tools.result_text(got[0]) if got else ""
        check(got != [] and got[0].get("is_error") is True and text == NO_ANSWER,
              f"the broker's 9 s deadline answers first ({text!r} after {took:.1f} s)")
        hello = json.loads((w.agent / "scratchpad" / "helper-hello.json").read_text())
        check((hello.get("e2e") or {}).get("tool_deadline_s") == 12, f"hello carried tool_deadline_s 12 ({hello.get('e2e')})")
    finally:
        tools.finish(b, fake)


def case_deadline_refused(binary: Path, tmp: Path, check) -> None:
    rt, fake = life.runtime_dir(), life.Fake(tmp)
    w = life.world(binary, tmp, "deadline-refused")
    b = life.launch(binary, tmp, "deadline-refused", life.env_for(w, rt, {**fake.seams(), ENV: "abc"}))
    try:
        life.send(b, "hi")
        check(b.wait(lambda: ("system", REFUSED_BUBBLE) in life.bubbles(b), 30), f"the drawer says {REFUSED_BUBBLE!r} ({life.bubbles(b)})", b)
        check([line for line in b.err if line == REFUSAL] == [REFUSAL], f"stderr holds the refusal line exactly once ({[l for l in b.err if 'tool deadline' in l]})", b)
        time.sleep(2.0)
        check(life.chat_pid(b.proc.pid) is None, "no helper runs")
        check(not (w.agent / "scratchpad" / "helper-hello.json").exists(), "no hello was written")
        check(len(fake.api.messages_requests()) == 0, "nothing reached the API")
    finally:
        b.stop()
        fake.close()


def case_deadline_inert(binary: Path, tmp: Path, check) -> None:
    rt = life.runtime_dir()
    w = life.world(binary, tmp, "deadline-inert")
    b = life.launch(binary, tmp, "deadline-inert", life.env_for(w, rt, {ENV: "abc"}), e2e=False)
    try:
        b.wait(lambda: b.display_file.exists(), 20)
        icon = None
        deadline = time.monotonic() + 30
        while icon is None and time.monotonic() < deadline:
            time.sleep(0.5)
            icon = life.icon_centre(b)
        check(icon is not None, "the icon is on the screen")
        if icon is None:
            return
        b.x.click(*icon)
        time.sleep(1.0)
        for ch in "hi":
            b.x.key(ch, settle=0.005)
        b.x.key("Return")
        check(b.wait(lambda: life.chat_pid(b.proc.pid) is not None, 60), "the real helper runs")
        hello_path = w.agent / "scratchpad" / "helper-hello.json"
        check(b.wait(hello_path.exists, 30), "the helper logged its hello")
        if hello_path.exists():
            check(json.loads(hello_path.read_text()).get("e2e") is None, "hello carries no e2e seam")
        check(not [line for line in b.err if "tool deadline" in line], f"no refusal line ({[l for l in b.err if 'tool deadline' in l]})", b)
    finally:
        b.stop()


CASES = {
    "deadline-broker": case_deadline_broker,
    "deadline-refused": case_deadline_refused,
    "deadline-inert": case_deadline_inert,
}


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
            if str(d).startswith("/tmp/zbl-"):
                subprocess.run(["find", str(d), "-delete"], check=False)


if __name__ == "__main__":
    raise SystemExit(main())
