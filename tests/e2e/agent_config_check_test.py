#!/usr/bin/env python3
"""The per-session configuration check (chat-drawer plan S3.10, the outside-change
variant; §2 "Per-session integrity"): before each session, the app re-hashes the agent
home's read-only `.claude` tree against `runtime/config-manifest.json`, which
`--agent-setup` wrote. A change made outside the sandbox, by any same-user process,
refuses the session: `DRAWER status unavailable config-changed`, the system bubble
CONFIG_BUBBLE, and nothing reaches the helper. The writable state directories
(`runtime/writable.json`) are not configuration, and changing them refuses nothing.

The real binary runs on its own Xvfb (xsession.py) with the scripted fake_host.py in
the helper's place (ZIGBROWSER_AGENT_HOST_CMD, which needs --e2e-protocol). The oracle
is what the helper receives: every app frame fake_host.py reads is appended to
<home>/scratchpad/fake-host-frames.jsonl, and every start counts in fake-host-runs.
The whole run sits in a network namespace of its own (re-exec'd as --sealed-child).
Exit 1 when Xvfb, xauth, bwrap, the venv or the binary is missing."""

from __future__ import annotations

import json
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import agent_host_lifecycle_test as life  # noqa: E402 - its world, seams and process table

CONFIG_BUBBLE = "Agent configuration changed: run zigBrowser --agent-setup again"
REPLY = "zb-config-check-reply"


RESULT = {"type": "result", "session": "$SESSION", "sdk_session_id": "fake-sdk-session",
          "subtype": "success", "is_error": False, "num_turns": 1, "cost_usd": None}


def prepared(binary: Path, tmp: Path, name: str, end: bool = False):
    """A fresh agent home of its own (each case changes its tree), scripted fake host.
    With `end`, every prompt's session also ends (result, then a real session_ended)."""
    w = life.world(binary, tmp, f"cfg-{name}")
    scratch = w.agent / "scratchpad"
    for leftover in ("fake-host-runs", "fake-host-frames.jsonl"):
        (scratch / leftover).unlink(missing_ok=True)
    reply = [{"frame": {"type": "assistant_message", "session": "$SESSION", "text": REPLY}}]
    if end:
        reply += [{"frame": RESULT}, {"frame": {"type": "session_ended", "session": "$SESSION", "reason": "end"}}]
    (scratch / "fake-host-script.json").write_text(json.dumps({"runs": [{"on_prompt": reply}]}))
    return w


def start(binary: Path, tmp: Path, w, label: str):
    env = life.env_for(w, life.runtime_dir(), {"ZIGBROWSER_AGENT_HOST_CMD": str(life.FAKE_HOST_SCRIPT)})
    b = life.launch(binary, tmp, label, env)
    b.wait(lambda: b.rows("icon", 1) != [], 20)
    return b


def prompt_frames(w) -> list[tuple[str, str]]:
    """(session, text) of every prompt frame the helper received."""
    path = w.agent / "scratchpad" / "fake-host-frames.jsonl"
    if not path.exists():
        return []
    frames = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    return [(f.get("session", ""), f.get("text", "")) for f in frames if f.get("type") == "prompt"]


def prompts(w) -> list[str]:
    """The text of every prompt frame the helper received."""
    return [text for _session, text in prompt_frames(w)]


def helper_runs(w) -> int:
    path = w.agent / "scratchpad" / "fake-host-runs"
    return int(path.read_text() or 0) if path.exists() else 0


def second_window(b, check) -> bool:
    b.wait_page()
    b.ev("(window.open('frame.html'), 1)")
    return check(b.wait(lambda: b.rows("icon", 2) != [], 20), "the popup has its own drawer icon", b)


def answered(b, check, text: str, win: int) -> bool:
    life.send(b, text, win=win)
    return check(b.wait(lambda: ("assistant", REPLY) in life.bubbles(b, win), 30),
                 f"window {win}'s session runs and answers ({life.statuses(b, win)})", b)


def refused(b, check, w, text: str, win: int, what: str) -> None:
    """Sending `text` in window `win` is refused before anything reaches the helper."""
    before = set(life.descendants(b.proc.pid))
    runs = helper_runs(w)
    replies = life.bubbles(b, win).count(("assistant", REPLY))
    life.send(b, text, win=win)
    check(b.wait(lambda: ("unavailable", "config-changed") in life.statuses(b, win), 20),
          f"{what}: window {win} is unavailable config-changed ({life.statuses(b, win)})", b)
    check(("system", CONFIG_BUBBLE) in life.bubbles(b, win),
          f"{what}: window {win} shows the bubble ({life.bubbles(b, win)})", b)
    time.sleep(2.0)
    check(text not in prompts(w), f"{what}: the prompt never reaches the helper ({prompts(w)})")
    check(helper_runs(w) == runs, f"{what}: no helper is started for it ({helper_runs(w)} runs, was {runs})")
    check(life.new_children(b, before) == [], f"{what}: nothing starts ({life.new_children(b, before)})")
    check(life.bubbles(b, win).count(("assistant", REPLY)) == replies, f"{what}: window {win} gets no new reply")


# Each change, made from outside the sandbox before the session.
def edit_settings(claude: Path) -> None:
    path = claude / "settings.json"
    path.write_text(path.read_text() + "\n")


def add_hook(claude: Path) -> None:
    (claude / "hooks" / "zb-planted.py").write_text("print('planted')\n")


def remove_command(claude: Path) -> None:
    (claude / "commands" / "hello.md").unlink()


CHANGES = {"settings.json edited": edit_settings, "a hook file added": add_hook,
           "a command file removed": remove_command}


def case_unchanged(binary: Path, tmp: Path, check) -> None:
    """Control: nothing changed, so both windows' sessions run; a write into a writable
    state directory (not configuration) between them refuses nothing."""
    w = prepared(binary, tmp, "unchanged")
    b = start(binary, tmp, w, "cfg-unchanged")
    try:
        if not answered(b, check, "one", 1):
            return
        state = json.loads((w.agent / "runtime" / "writable.json").read_text())[0]
        (w.agent / ".claude" / state).mkdir(exist_ok=True)
        (w.agent / ".claude" / state / "zb-state-write.json").write_text("{}")
        if not second_window(b, check):
            return
        answered(b, check, "two", 2)
        check(prompts(w) == ["one", "two"], f"the helper got both prompts ({prompts(w)})")
        check(all(s[1] != "config-changed" for win in (1, 2) for s in life.statuses(b, win)),
              "no window was ever config-changed")
    finally:
        life.release_x(b)
        b.stop()


def case_changed_between(binary: Path, tmp: Path, check) -> None:
    """Session 1 runs; then settings.json changes from outside; window 2's session 2 is
    refused and never reaches the helper."""
    w = prepared(binary, tmp, "between")
    b = start(binary, tmp, w, "cfg-between")
    try:
        if not answered(b, check, "one", 1):
            return
        edit_settings(w.agent / ".claude")
        if not second_window(b, check):
            return
        refused(b, check, w, "two", 2, "changed between sessions")
        check(prompts(w) == ["one"], f"only session 1's prompt reached the helper ({prompts(w)})")
    finally:
        life.release_x(b)
        b.stop()


def case_changed_before(binary: Path, tmp: Path, check) -> None:
    """Each change, made before the first session: the first Send is refused, and the
    helper never starts."""
    for n, (what, change) in enumerate(CHANGES.items()):
        w = prepared(binary, tmp, f"before{n}")
        change(w.agent / ".claude")
        b = start(binary, tmp, w, f"cfg-before{n}")
        try:
            refused(b, check, w, "hi", 1, what)
            check(helper_runs(w) == 0, f"{what}: the helper never started ({helper_runs(w)} runs)")
        finally:
            life.release_x(b)
            b.stop()


def case_manifest_bad(binary: Path, tmp: Path, check) -> None:
    """Fail closed: a missing or unreadable manifest refuses the session too."""
    for n, (what, damage) in enumerate((("the manifest is missing", lambda p: p.unlink()),
                                        ("the manifest is not JSON", lambda p: p.write_text("not json")))):
        w = prepared(binary, tmp, f"manifest{n}")
        damage(w.agent / "runtime" / "config-manifest.json")
        b = start(binary, tmp, w, f"cfg-manifest{n}")
        try:
            refused(b, check, w, "hi", 1, what)
        finally:
            life.release_x(b)
            b.stop()


def case_same_window(binary: Path, tmp: Path, check) -> None:
    """RoseCat 5761: the check runs again for the same window's next session, the first
    after a real session_ended. Unchanged, that session runs as a new one (s-1-2);
    with settings.json edited after session 1 ended, it is refused."""
    for changed in (False, True):
        what = "changed after session 1 ended" if changed else "unchanged after session 1 ended"
        w = prepared(binary, tmp, f"same{int(changed)}", end=True)
        b = start(binary, tmp, w, f"cfg-same{int(changed)}")
        try:
            if not answered(b, check, "one", 1):
                continue
            check(b.wait(lambda: ("ready", "-") in life.statuses(b, 1)[-1:], 10), f"{what}: session 1's result arrived", b)
            time.sleep(1.5)  # its session_ended follows the result in the same write
            if changed:
                edit_settings(w.agent / ".claude")
                refused(b, check, w, "two", 1, what)
                check(prompt_frames(w) == [("s-1-1", "one")], f"{what}: only session 1's prompt reached the helper ({prompt_frames(w)})")
            else:
                life.send(b, "two", win=1)
                check(b.wait(lambda: life.bubbles(b, 1).count(("assistant", REPLY)) >= 2, 30),
                      f"{what}: the next session answers ({life.bubbles(b, 1)})", b)
                check(prompt_frames(w) == [("s-1-1", "one"), ("s-1-2", "two")],
                      f"{what}: the second prompt opened a new session ({prompt_frames(w)})")
            rejected = [line for line in b.err if "rejected frame" in line]
            check(rejected == [], f"{what}: the result and session_ended were valid frames ({rejected})")
        finally:
            life.release_x(b)
            b.stop()


CASES = {"unchanged": case_unchanged, "changed-between": case_changed_between,
         "changed-before": case_changed_before, "manifest-bad": case_manifest_bad,
         "same-window": case_same_window}


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
