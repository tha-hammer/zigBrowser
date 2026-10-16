#!/usr/bin/env python3
"""S5b, one session per window (chat-drawer plan S5.4; rev 16.19):
- two-windows: a prompt in the primary window and one in its popup run in two different
  sessions of the real Claude CLI. Each drawer shows only its own conversation, each API
  request carries only its own window's prompt, and the agent's own config
  (`agent-home/state/projects/<one workspace dir>/`, which the sandbox binds at
  `.claude/projects`; plan rev 15.4) holds exactly two transcripts,
  named by two different session ids, each with only its own prompt. The user's real
  `~/.claude` (here the decoy HOME's) is byte-for-byte unchanged, and no transcript holds
  the stored token.

The real binary runs on its own Xvfb (xsession.py) in a network namespace of its own
(re-exec'd as --sealed-child), with the real helper and the real CLI against the TLS fake
Messages API through relay -> netd (the lifecycle test's seams).
Exit 1 when Xvfb, xauth, bwrap, the venv or the binary is missing."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import agent_chat_test as chat  # noqa: E402 - last_user_text
import agent_host_lifecycle_test as life  # noqa: E402 - its world, seams and process table

PROMPTS = {1: "zb-window-one-prompt", 2: "zb-window-two-prompt"}
REPLIES = {1: "zb-reply-for-window-one", 2: "zb-reply-for-window-two"}


def snapshot(root: Path) -> dict[str, bytes]:
    """Every file under `root` (relative path -> bytes): the decoy user's ~/.claude."""
    return {str(p.relative_to(root)): p.read_bytes() for p in sorted(root.rglob("*")) if p.is_file()}


def transcripts(w) -> list[Path]:
    """The agent's transcripts: its writable state, outside the published `.claude`."""
    return sorted((w.agent / "state" / "projects").glob("*/*.jsonl"))


def case_two_windows(binary: Path, tmp: Path, check) -> None:
    w = life.world(binary, tmp, "sessions")
    user_claude = w.home / ".claude"
    before = snapshot(user_claude)

    def respond(entry, index):
        said = chat.last_user_text(entry)
        for win, prompt in PROMPTS.items():
            if prompt in said:
                return {"text": REPLIES[win]}
        return None

    fake = life.Fake(tmp)
    fake.api.responder = respond
    b = life.launch(binary, tmp, "two-windows", life.env_for(w, life.runtime_dir(), fake.seams()))
    try:
        if not check(b.wait_page(), "the primary window's page loaded", b):
            return
        life.send(b, PROMPTS[1], win=1)
        if not check(b.wait(lambda: ("assistant", REPLIES[1]) in life.bubbles(b, 1), 90),
                     f"window 1 is answered ({life.bubbles(b, 1)})", b):
            return
        if not check(b.open_popup() and b.wait(lambda: b.rows("icon", 2) != [], 20), "the popup has its own drawer icon", b):
            return
        life.send(b, PROMPTS[2], win=2)
        check(b.wait(lambda: ("assistant", REPLIES[2]) in life.bubbles(b, 2), 90),
              f"window 2 is answered ({life.bubbles(b, 2)})", b)
        for win in (1, 2):
            want = [("user", PROMPTS[win]), ("assistant", REPLIES[win])]
            check(life.bubbles(b, win) == want, f"window {win}'s drawer shows only its own conversation ({life.bubbles(b, win)})")
        requests = fake.api.messages_requests()
        bodies = [chat.request_text(r) for r in requests]
        check(len(requests) == 2 and PROMPTS[1] not in bodies[1] and PROMPTS[2] in bodies[1],
              f"window 2's request carries only its own prompt: a new session ({len(requests)} requests)")
        b.wait(lambda: len(transcripts(w)) >= 2, 15)  # each CLI writes its transcript as it goes
        found = transcripts(w)
        check(len({p.parent for p in found}) == 1, f"the transcripts sit in one workspace directory ({[str(p) for p in found]})")
        check(len(found) == 2 and len({p.stem for p in found}) == 2,
              f"two transcripts, named by two different session ids ({[p.name for p in found]})")
        texts = [p.read_text(errors="replace") for p in found]
        for win in (1, 2):
            own = [t for t in texts if PROMPTS[win] in t]
            check(len(own) == 1 and PROMPTS[3 - win] not in own[0],
                  f"window {win}'s prompt is in exactly one transcript, without the other window's")
        check(not any(life.CANARY in t for t in texts), "no transcript holds the stored token")
        published = sorted((w.agent / ".claude").rglob("*.jsonl"))
        check(published == [], f"nothing is written into the published .claude ({[str(p) for p in published]})")
        check(snapshot(user_claude) == before, "the user's real ~/.claude is unchanged")
        rejected = [line for line in b.err if "rejected frame" in line]
        check(rejected == [], f"every helper frame was valid ({rejected[:2]})")
    finally:
        life.release_x(b)
        b.stop()
        fake.close()


CASES = {"two-windows": case_two_windows}


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
