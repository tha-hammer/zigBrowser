#!/usr/bin/env python3
"""S5c-2, a credential echoed into an API error never stays in the saved transcript
(chat-drawer plan S5.7, rev 16.20.2 to 16.20.8, approved 9868a65). The real chain: the
browser, the helper, the CLI, and a fake Messages API whose errors echo the request's
credential, as the real server's do. The CLI saves that text in its transcript
(`agent-home/state/projects/<ws>/<id>.jsonl`); the helper's scrub must mask it before the
prompt's ending frame:
- echo-401: a 401 whose body echoes the request headers (the token among them);
- echo-500: a 500 whose message carries the token;
- echo-sse: a stream that ends with an SSE `error` event carrying the token.
After each reply, no transcript holds the token, and no bubble, row, stdout or stderr line
does. (telemetry.query takes a trace id; an agent prompt makes no automation trace.)
- control: a server that does not echo leaves every transcript without the token.

The real binary runs on its own Xvfb in a network namespace of its own (re-exec'd as
--sealed-child). Exit 1 when Xvfb, xauth, bwrap, the venv or the binary is missing."""

from __future__ import annotations

import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import agent_chat_test as chat  # noqa: E402 - last_user_text
import agent_host_lifecycle_test as life  # noqa: E402 - the world, its CANARY token, the fake


def echoing(entry, index):
    text = chat.last_user_text(entry)
    headers = " ".join(f"{k}: {v}" for k, v in sorted((entry.get("headers") or {}).items()))
    if "echo-401" in text:
        return {"status": 401, "body": {"type": "error", "error": {"type": "authentication_error",
                                                                   "message": "invalid x-api-key " + headers}}}
    if "echo-500" in text:
        return {"status": 500, "body": {"type": "error", "error": {"type": "api_error",
                                                                   "message": "internal: " + life.CANARY}}}
    if "echo-sse" in text:
        return {"sse_error": {"type": "overloaded_error", "message": "overloaded for " + life.CANARY}}
    return {"text": "a plain reply"}


def transcripts(w) -> list[Path]:
    projects = w.agent / "state" / "projects"
    return sorted(projects.glob("*/*.jsonl")) if projects.is_dir() else []


def holding(w, needle: str) -> list[str]:
    return [p.name for p in transcripts(w) if needle.encode() in p.read_bytes()]


def run(binary: Path, tmp: Path, check, label: str, respond, prompts: list[str], expect_echo: bool) -> None:
    w = life.world(binary, tmp, f"redact-{label}")
    fake = life.Fake(tmp)
    fake.api.responder = respond
    b = life.launch(binary, tmp, label, life.env_for(w, life.runtime_dir(), fake.seams()))
    try:
        if not check(b.wait_page(), "the page loaded", b):
            return
        for prompt in prompts:
            # A reply's end shows "ready"; so does the helper's start, which the first Send makes.
            ready = life.statuses(b).count(("ready", "-"))
            want = ready + 1 if ready else 2
            life.send(b, prompt)
            ended = b.wait(lambda: life.statuses(b).count(("ready", "-")) >= want, 120)
            if not check(ended, f"{label}/{prompt}: the reply ended ({life.bubbles(b)[-2:]})", b):
                return
            if expect_echo:
                saw = [r for r in fake.api.messages_requests() if life.CANARY in str(r.get("headers"))]
                check(saw != [], f"{label}/{prompt}: the token reached the fake, so its echo is real")
            check(transcripts(w) != [], f"{label}/{prompt}: the CLI saved a transcript")
            check(holding(w, life.CANARY) == [], f"{label}/{prompt}: no transcript holds the token "
                                                 f"({holding(w, life.CANARY)})")
            time.sleep(0.5)
            leaked = [line[:80] for line in b.out + b.err if life.CANARY in line]
            check(leaked == [], f"{label}/{prompt}: the token is in no row, bubble, stdout or stderr ({leaked[:2]})")
            shown = [text[:60] for _role, text in life.bubbles(b) if life.CANARY in text]
            check(shown == [], f"{label}/{prompt}: no bubble shows it ({shown})")
    finally:
        life.release_x(b)
        b.stop()
        fake.close()


def case_echoes(binary: Path, tmp: Path, check) -> None:
    run(binary, tmp, check, "echoes", echoing, ["echo-401", "echo-500", "echo-sse"], expect_echo=True)


def case_control(binary: Path, tmp: Path, check) -> None:
    run(binary, tmp, check, "control", lambda entry, index: {"text": "a plain reply"}, ["plain one", "plain two"],
        expect_echo=False)


CASES = {"echoes": case_echoes, "control": case_control}


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
