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
- {"frame": {...}}: the frame with "v": 1 and the next seq added, and the value
  "$SESSION" replaced by the prompt's session;
- {"repeat": ["TEXT", N]}: TEXT as N stdout lines in one write (left in the pipe);
- {"stderr": "TEXT"}: TEXT as one stderr line.
It answers every `end_session` with its "on_end" ITEMs, "$SESSION" being the ended
session (without "on_end", nothing), and every `interrupt` with its "on_interrupt" ITEMs
(S5a; without them, nothing).
Every app frame it reads is appended to <home>/scratchpad/fake-host-frames.jsonl.
`shutdown` or EOF ends it with exit 0. Standard library only."""

import json
import os
import sys

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


def emit(frame):
    global seq
    seq += 1
    sys.stdout.write(json.dumps({"v": 1, "seq": seq, **frame}) + "\n")
    sys.stdout.flush()


def fill(value, session):
    if value == "$SESSION":
        return session
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
    if frame.get("type") == "shutdown":
        break
    kind = {"prompt": "on_prompt", "end_session": "on_end", "interrupt": "on_interrupt"}.get(frame.get("type"))
    if kind is not None:
        for item in script.get(kind, []):
            if "raw" in item:
                seq += 1
                sys.stdout.write(item["raw"] + "\n")
                sys.stdout.flush()
            elif "repeat" in item:
                text, count = item["repeat"]
                sys.stdout.write((text + "\n") * count)
                sys.stdout.flush()
            elif "stderr" in item:
                sys.stderr.write(item["stderr"] + "\n")
                sys.stderr.flush()
            else:
                emit(fill(item["frame"], frame["session"]))
sys.exit(0)
