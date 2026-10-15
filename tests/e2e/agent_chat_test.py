#!/usr/bin/env python3
"""S5a, the conversation (chat-drawer plan S5.1-S5.3, the S5 closure; rev 16.14):
- stream: a reply streams into one assistant bubble that grows while the API is still
  sending (the bubble's text is read back through a real X selection and Ctrl+C), then
  ends as `DRAWER msg assistant <whole text>`; the fake API saw the typed prompt;
- stop: a real X click on Stop interrupts the running reply; the bubble ends with
  "(stopped)", and the next prompt runs in the same session (its API request carries the
  first prompt too);
- errors: a 401 shows "Claude rejected the saved token. Open Account to replace it.", a
  529 shows "Claude is busy; try again shortly.", and no row, bubble or log holds the
  API's own error text;
- agent-error: a helper error (protocol or sdk) shows "Agent error", never its message.

The real binary runs on its own Xvfb (xsession.py) in a network namespace of its own
(re-exec'd as --sealed-child). stream, stop and errors run the real helper and the real
Claude CLI against the TLS fake Messages API through relay -> netd (the lifecycle
test's seams); agent-error uses the scripted fake_host.py in the helper's place.
Exit 1 when Xvfb, xauth, bwrap, the venv or the binary is missing."""

from __future__ import annotations

import json
import subprocess
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import agent_drawer_copy_test as copy  # noqa: E402 - the decoy clipboard and its reader
import agent_host_lifecycle_test as life  # noqa: E402 - its world, seams and process table

AUTH_TEXT = "Claude rejected the saved token. Open Account to replace it."
BUSY_TEXT = "Claude is busy; try again shortly."
AGENT_ERROR_TEXT = "Agent error"
STOPPED = "(stopped)"
SERVER_CANARY = "zb-server-error-canary-5a"


def start(binary: Path, tmp: Path, label: str, fake):
    return life.launch(binary, tmp, label, life.env_for(life.world(binary, tmp), life.runtime_dir(), fake.seams()))


def request_text(entry) -> str:
    return json.dumps(entry.get("body"))


def stop_rect(b, win: int = 1):
    rows = b.rows("stop", win)
    return rows[-1].rect() if rows else None


def bubble_text(b, check, role: str, label: str) -> str | None:
    """The newest `role` bubble's whole text, as the user gets it: a real triple-click
    (the line) and Ctrl+C, read back from the display's CLIPBOARD after a decoy."""
    rect = copy.text_rect(b, role)
    if not check(rect is not None, f"{label}: a {role} bubble is on screen (textrect row)", b):
        return None
    owner = copy.seed_decoy(b)
    try:
        x, y = rect[0] + min(rect[2] // 2, 20), rect[1] + rect[3] // 2
        for _ in range(3):
            b.x.click(x, y, settle=0.02)
        time.sleep(0.3)
        b.x.key("c", modifiers=("Control_L",))
        time.sleep(0.5)
        got = copy.clipboard(b)
        return None if got == copy.DECOY else got
    finally:
        owner.kill()
        owner.wait()


def case_stream(binary: Path, tmp: Path, check) -> None:
    """S5.1 and the S5 closure: typed prompt -> the streamed reply grows in one bubble."""
    stall = threading.Event()
    fake = life.Fake(tmp, turns=[{"deltas": ["Hello ", "from ", "the agent"], "stall": stall}])
    b = start(binary, tmp, "stream", fake)
    try:
        life.send(b, "hi")
        check(b.wait(lambda: any(r.fields[1] == "Hello " for r in b.rows("delta", 1)), 90),
              f"the first delta arrives while the API holds the rest ({[r.fields for r in b.rows('delta', 1)]})", b)
        time.sleep(0.5)
        shown = bubble_text(b, check, "assistant", "while streaming")
        check(shown is not None and shown.strip() == "Hello" and not stall.is_set(),
              f"while the API still holds the rest, the assistant bubble already shows 'Hello' (got {shown!r})")
        stall.set()
        check(b.wait(lambda: ("assistant", life.REPLY) in life.bubbles(b), 60), f"the whole reply ({life.bubbles(b)})", b)
        time.sleep(1.0)
        check(life.bubbles(b) == [("user", "hi"), ("assistant", life.REPLY)],
              f"one user and one assistant bubble: the deltas grew the same bubble ({life.bubbles(b)})")
        final = bubble_text(b, check, "assistant", "after the result")
        check(final == life.REPLY, f"the bubble ends with the whole reply (got {final!r})")
        requests = fake.api.messages_requests()
        check(len(requests) == 1 and '"hi"' in request_text(requests[0]), "the fake API got the prompt 'hi' as the user turn")
        check(life.statuses(b)[-1:] == [("ready", "-")], f"the status is Ready again ({life.statuses(b)})")
    finally:
        stall.set()
        life.release_x(b)
        b.stop()
        fake.close()


def case_stop(binary: Path, tmp: Path, check) -> None:
    """S5.2: Stop interrupts; the bubble ends "(stopped)"; the session goes on."""
    stall = threading.Event()
    fake = life.Fake(tmp, turns=[{"deltas": ["Hello ", "never shown"], "stall": stall}, {"text": "after stop"}])
    b = start(binary, tmp, "stop", fake)
    try:
        life.send(b, "first")
        if not check(b.wait(lambda: any(r.fields[1] == "Hello " for r in b.rows("delta", 1)), 90),
                     "the first delta arrives while the API holds the rest", b):
            return
        rect = stop_rect(b)
        if not check(rect is not None, "the open drawer reports its Stop button (DRAWER stop <rect>)", b):
            return
        b.x.click(rect[0] + rect[2] // 2, rect[1] + rect[3] // 2)
        check(b.wait(lambda: any(role == "assistant" and text.endswith(STOPPED) for role, text in life.bubbles(b)), 30),
              f"the bubble ends with '(stopped)' ({life.bubbles(b)})", b)
        stopped = [text for role, text in life.bubbles(b) if role == "assistant"]
        check(stopped[-1:] == [f"Hello {STOPPED}"], f"it keeps what was shown, then '(stopped)' ({stopped})")
        check(b.wait(lambda: life.statuses(b)[-1:] == [("ready", "-")], 30), f"Ready again ({life.statuses(b)})", b)
        deltas_at_stop = len(b.rows("delta", 1))
        stall.set()
        time.sleep(2.0)
        check(len(b.rows("delta", 1)) == deltas_at_stop and not any("never shown" in t for _, t in life.bubbles(b)),
              "nothing of the stopped reply arrives after the stop")
        life.send(b, "second")
        check(b.wait(lambda: ("assistant", "after stop") in life.bubbles(b), 60), f"the next prompt is answered ({life.bubbles(b)})", b)
        requests = fake.api.messages_requests()
        later = request_text(requests[-1]) if requests else ""
        check(len(requests) == 2 and '"first"' in later and '"second"' in later,
              f"the second prompt ran in the same session: its request carries the first ({len(requests)} requests)")
        idle = stop_rect(b)
        if idle is not None:  # Stop does nothing while no reply runs
            b.x.click(idle[0] + idle[2] // 2, idle[1] + idle[3] // 2)
            time.sleep(1.0)
            check(not any(text.endswith(STOPPED) and "after stop" in text for _, text in life.bubbles(b)),
                  "Stop while idle stops nothing")
    finally:
        stall.set()
        life.release_x(b)
        b.stop()
        fake.close()


def case_errors(binary: Path, tmp: Path, check) -> None:
    """S5.3: 401 and 529 are shown plainly; the API's own error text goes nowhere."""
    def respond(entry, index):
        text = request_text(entry)
        if "auth-case" in text:
            return {"status": 401, "body": {"type": "error", "error": {"type": "authentication_error", "message": SERVER_CANARY}}}
        if "busy-case" in text:
            return {"status": 529, "body": {"type": "error", "error": {"type": "overloaded_error", "message": SERVER_CANARY}}}
        return None

    fake = life.Fake(tmp)
    fake.api.responder = respond
    b = start(binary, tmp, "errors", fake)
    try:
        life.send(b, "auth-case")
        check(b.wait(lambda: ("error", AUTH_TEXT) in life.bubbles(b), 90), f"401: the plain token message ({life.bubbles(b)})", b)
        check(b.wait(lambda: life.statuses(b)[-1:] == [("ready", "-")], 30), "Ready again after the 401", b)
        before = len(fake.api.messages_requests())
        life.send(b, "busy-case")
        check(b.wait(lambda: ("error", BUSY_TEXT) in life.bubbles(b), 60), f"529: the plain busy message ({life.bubbles(b)})", b)
        check(len(fake.api.messages_requests()) - before == 1,
              f"under --e2e-protocol the CLI does not retry (requests {len(fake.api.messages_requests()) - before})")
        time.sleep(1.0)
        roles = [role for role, _ in life.bubbles(b)]
        check("assistant" not in roles, f"an API error is never an assistant bubble ({life.bubbles(b)})")
        leaked = [line for line in b.out + b.err if SERVER_CANARY in line or "API Error" in line]
        check(leaked == [], f"the API's own error text is in no row, bubble or log ({leaked[:2]})")
    finally:
        life.release_x(b)
        b.stop()
        fake.close()


def agent_error_run(binary: Path, tmp: Path, check, label: str, on_prompt: list) -> None:
    """One browser whose scripted helper answers the prompt with `on_prompt`: exactly one
    "Agent error" bubble, and none of the frames' messages anywhere."""
    w = life.world(binary, tmp)
    scratch = w.agent / "scratchpad"
    for name in ("fake-host-runs", "fake-host-frames.jsonl"):
        (scratch / name).unlink(missing_ok=True)
    (scratch / "fake-host-script.json").write_text(json.dumps({"runs": [{"on_prompt": on_prompt}]}))
    b = life.launch(binary, tmp, f"agent-error-{label}",
                    life.env_for(w, life.runtime_dir(), {"ZIGBROWSER_AGENT_HOST_CMD": str(life.FAKE_HOST_SCRIPT)}))
    try:
        life.send(b, "hi")
        check(b.wait(lambda: ("error", AGENT_ERROR_TEXT) in life.bubbles(b), 30),
              f"{label}: the error shows 'Agent error' ({life.bubbles(b)})", b)
        time.sleep(2.0)  # anything more the helper sent has arrived
        errors = [text for role, text in life.bubbles(b) if role == "error"]
        check(errors == [AGENT_ERROR_TEXT], f"{label}: exactly one error bubble for the one prompt ({errors})")
        leaked = [line for line in b.out + b.err if SERVER_CANARY in line]
        check(leaked == [], f"{label}: no frame's message is in a row, bubble or log ({leaked[:2]})")
    finally:
        life.release_x(b)
        b.stop()


def error_frame(code: str) -> dict:
    return {"frame": {"type": "error", "session": "$SESSION", "code": code, "message": f"{SERVER_CANARY}-{code}"}}


def case_agent_error(binary: Path, tmp: Path, check) -> None:
    """S5.3: a helper's protocol error and its sdk error (each its own prompt's one ending
    frame) show "Agent error", never the message. RoseCat 5834: an error ends the prompt in
    place of its result, so a second ending frame for the same prompt shows nothing more."""
    agent_error_run(binary, tmp, check, "protocol", [error_frame("protocol")])
    agent_error_run(binary, tmp, check, "sdk", [error_frame("sdk")])
    agent_error_run(binary, tmp, check, "second-ending-frame", [error_frame("sdk"), error_frame("protocol")])


CASES = {"stream": case_stream, "stop": case_stop, "errors": case_errors, "agent-error": case_agent_error}


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
