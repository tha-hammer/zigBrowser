#!/usr/bin/python3 -I
"""A scripted stand-in for the chat helper (chat-drawer plan S3.3; S3b), started by the
browser in the helper's place only through ZIGBROWSER_AGENT_HOST_CMD under
--e2e-protocol. It gets the helper's environment and token pipe, and no arguments.

The agent home is PYTHONPATH minus /runtime/host. The test writes the script to
<home>/scratchpad/fake-host-script.json:

    {"runs": [{"on_prompt": [ITEM, ...], "on_end": [ITEM, ...], "on_interrupt": [ITEM, ...]}, ...]}

Run n (counted in <home>/scratchpad/fake-host-runs) uses runs[n], or the last one. It
reads the token from fd 3 to EOF (it records only its length), prints `ready`, then
answers every `prompt` with its ITEMs in order:
- {"raw": "TEXT"}: TEXT as one stdout line, as it is (a bad frame);
- {"frame": {...}}: the frame with "v": 1 and the next seq added, the value
  "$SESSION" replaced by the prompt's session and "$PROMPT_ID" by that session's active
  prompt id (S5c-1, rev 16.20.13). S5d: a prompt-scoped frame (delta, message, tool call,
  result, reply_capped, or an error naming a session) with no "prompt_id" gets the same
  id, as the real helper's does: the session's last prompt until its `result` or `error`
  goes out, then null. A script sets one itself for a stale or future id;
- {"repeat": ["TEXT", N]}: TEXT as N stdout lines in one write (left in the pipe);
- {"stderr": "TEXT"}: TEXT as one stderr line;
- {"sleep": S}: wait S seconds before the next ITEM; app frames wait meanwhile (S5c-1);
- {"flood": [FRAME, N]}: FRAME (as for "frame") N times, 1000 frames per write (S5c-1);
- {"forever": FRAME}: FRAME (as for "frame") over and over from a thread, as fast as
  the pipe takes it, until the next `interrupt`, `end_session` or `shutdown` (S5c-1).
It answers every `open_session` with "on_open" ITEMs, "$SESSION" being the new session;
without them, with `session_opened` for it, as the real helper does once its CLI is up (S5d,
RoseCat 6296: the app writes a session's first prompt only after it). With "on_opens":
[[ITEM, ...], ...], the n-th open gets the n-th list, or the last one.
With "on_prompts": [[ITEM, ...], ...] in place of "on_prompt", the n-th prompt of the
run gets the n-th list, or the last one (S5c-1).
It answers every `end_session` with its "on_end" ITEMs, "$SESSION" being the ended
session (without "on_end", nothing), and every `interrupt` with its "on_interrupt" ITEMs
(S5a; without them, nothing).
Every app frame it reads is appended to <home>/scratchpad/fake-host-frames.jsonl.
`shutdown` or EOF ends it with exit 0. Standard library only."""

import json
import os
import sys
import threading
import time

home = os.environ["PYTHONPATH"].rsplit("/runtime/host", 1)[0]
scratch = os.path.join(home, "scratchpad")
runs_path = os.path.join(scratch, "fake-host-runs")
try:
    with open(runs_path) as f:
        run = int(f.read() or 0)
except OSError:
    run = 0
with open(runs_path, "w") as f:
    f.write(str(run + 1))
with open(os.path.join(scratch, "fake-host-script.json")) as f:
    runs = json.load(f)["runs"]
script = runs[min(run, len(runs) - 1)]

token = b""
while True:
    chunk = os.read(3, 1024)
    if not chunk:
        break
    token += chunk
os.close(3)
with open(os.path.join(scratch, f"fake-host-token-{run}"), "w") as f:
    f.write(str(len(token)))

seq = 0
out_lock = threading.Lock()


PROMPT_SCOPED = ("assistant_delta", "assistant_message", "tool_call", "result", "reply_capped", "error")


def encode(frame):
    global seq
    seq += 1
    session = frame.get("session")
    if frame.get("type") in PROMPT_SCOPED and session is not None:
        if "prompt_id" not in frame:
            frame = {**frame, "prompt_id": active.get(session)}
        if frame.get("type") in ("result", "error") and frame["prompt_id"] == active.get(session):
            active.pop(session, None)  # the prompt's own ending frame: none is active now
    return json.dumps({"v": 1, "seq": seq, **frame})


def emit(frame):
    with out_lock:
        sys.stdout.write(encode(frame) + "\n")
        sys.stdout.flush()


class Forever:
    """One {"forever": FRAME} stream; stop() ends it before the next answer."""

    def __init__(self, frame):
        self.frame, self.done = frame, threading.Event()
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def run(self):
        while not self.done.is_set():
            try:
                emit(self.frame)
            except (BrokenPipeError, ValueError):
                return

    def stop(self):
        self.done.set()
        self.thread.join(30)


streams = []
prompts = 0
opens = 0
OPENED = [{"frame": {"type": "session_opened", "session": "$SESSION"}}]


active = {}  # session -> the prompt_id of its prompt still running (S5d)


def fill(value, session):
    if value == "$SESSION":
        return session
    if value == "$PROMPT_ID":
        return active.get(session)
    if isinstance(value, dict):
        return {k: fill(v, session) for k, v in value.items()}
    return value


emit({"type": "ready", "version": "fake", "route": "R1", "selfcheck": {"ok": True, "failures": []},
      "tool_deadline_s": 120})
log = open(os.path.join(scratch, "fake-host-frames.jsonl"), "a")
for line in sys.stdin:
    log.write(line)
    log.flush()
    frame = json.loads(line)
    if frame.get("type") in ("interrupt", "end_session", "shutdown"):
        for stream in streams:
            stream.stop()
        streams = []
    if frame.get("type") == "shutdown":
        break
    if frame.get("type") == "prompt":
        active[frame.get("session")] = frame.get("prompt_id")
    kind = {"prompt": "on_prompt", "end_session": "on_end", "interrupt": "on_interrupt",
            "open_session": "on_open"}.get(frame.get("type"))
    if kind is not None:
        items = script.get(kind, OPENED if kind == "on_open" else [])
        if kind == "on_open" and "on_opens" in script:
            items = script["on_opens"][min(opens, len(script["on_opens"]) - 1)]
        if kind == "on_open":
            opens += 1
        if kind == "on_prompt" and "on_prompts" in script:
            items = script["on_prompts"][min(prompts, len(script["on_prompts"]) - 1)]
            prompts += 1
        for item in items:
            if "raw" in item:
                seq += 1
                sys.stdout.write(item["raw"] + "\n")
                sys.stdout.flush()
            elif "repeat" in item:
                text, count = item["repeat"]
                sys.stdout.write((text + "\n") * count)
                sys.stdout.flush()
            elif "flood" in item:
                body, count = item["flood"]
                body = fill(body, frame["session"])
                for start in range(0, count, 1000):
                    with out_lock:
                        sys.stdout.write("".join(encode(body) + "\n" for _ in range(min(1000, count - start))))
                with out_lock:
                    sys.stdout.flush()
            elif "forever" in item:
                streams.append(Forever(fill(item["forever"], frame["session"])))
            elif "stderr" in item:
                sys.stderr.write(item["stderr"] + "\n")
                sys.stderr.flush()
            elif "sleep" in item:
                time.sleep(item["sleep"])
            else:
                emit(fill(item["frame"], frame["session"]))
sys.exit(0)
