#!/usr/bin/env python3
"""S5c-1, a flood of output stays bounded (chat-drawer plan S5.6, rev 16.20 and the
user's decision 1, 2026-10-19):
- app-flood: the helper sends 50,000 one-character deltas as fast as the pipe takes
  them. While they arrive, '-' folds the drawer within 1 s, a click reaches the page,
  page.health answers, and the browser's RSS grows by less than 64 MiB; the reply then
  ends as usual.
- unbroken: replies of 48 KiB and 200 KB with no break opportunity (one run of 'y') are
  shown whole. '-' still folds within 1 s and the drawer reopens, and the browser grows
  by less than 200 MiB.
- copy-exact: the break points the drawer adds are never copied. A triple-click and
  Ctrl+C copy the 200,000 characters exactly; Ctrl+Home, Shift+Right x70 (across the
  first break) and Ctrl+C copy exactly 69 of them; the same on 200 multibyte characters
  copies 69 of them; a source text with its own U+200B copies whole, that U+200B kept.
- endless: a helper that never stops streaming. While it streams '-' folds within 1 s.
  Once the reply passes 256 KiB, 10 s later the app interrupts it with "Agent output
  overflow"; the browser grows by less than 200 MiB, and the next prompt is answered.
- real-chain: the same through the real CLI and helper, against the fake API's
  `endless` turn: the overflow bubble, the CLI's request abandoned, then the next prompt
  answered by the API.

The real binary runs on its own Xvfb (xsession.py) in a network namespace of its own
(re-exec'd as --sealed-child). app-flood, unbroken and endless use the scripted
fake_host.py in the helper's place; real-chain uses the lifecycle test's seams.
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

import agent_drawer_copy_test as copy  # noqa: E402 - the CLIPBOARD oracle
import agent_host_lifecycle_test as life  # noqa: E402 - its world, seams and process table

FOLD_MAX_S = 1.0
FLOOD = 50_000
OVERFLOW = "Agent output overflow"
CAP = 256 * 1024
MIB = 1024


class Rss:
    """Samples the browser's VmRSS every 0.2 s; `growth()` is in MiB over the first
    sample. Over `limit_mib` the sampler kills the browser, so a red run cannot take
    the machine with it."""

    def __init__(self, b, limit_mib: int = 1024):
        from agent_common import rss_kb
        self.pid = b.browser_pid()
        self.base = rss_kb(self.pid)
        self.peak = self.base or 0
        self.killed = False
        self.done = threading.Event()

        def run():
            while not self.done.wait(0.2):
                now = rss_kb(self.pid)
                if now is None:
                    return
                self.peak = max(self.peak, now)
                if self.base is not None and now - self.base > limit_mib * MIB:
                    self.killed = True
                    b.proc.kill()
                    return
        threading.Thread(target=run, daemon=True).start()

    def growth(self) -> float:
        self.done.set()
        return (self.peak - (self.base or 0)) / MIB


def scripted(binary: Path, tmp: Path, name: str, script: dict):
    w = life.world(binary, tmp, name)
    scratch = w.agent / "scratchpad"
    for leftover in ("fake-host-runs", "fake-host-frames.jsonl"):
        (scratch / leftover).unlink(missing_ok=True)
    (scratch / "fake-host-script.json").write_text(json.dumps({"runs": [script]}))
    b = life.launch(binary, tmp, name, life.env_for(w, life.runtime_dir(), {"ZIGBROWSER_AGENT_HOST_CMD": str(life.FAKE_HOST_SCRIPT)}))
    return w, b


def app_frames(w) -> list[dict]:
    path = w.agent / "scratchpad" / "fake-host-frames.jsonl"
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def frame(kind: str, **fields) -> dict:
    return {"frame": {"type": kind, "session": "$SESSION", **fields}}


RESULT = frame("result", sdk_session_id="fake-sdk-session", subtype="success", is_error=False, num_turns=1, cost_usd=None)
STOPPED = frame("result", sdk_session_id="fake-sdk-session", subtype="error_during_execution", is_error=True,
                num_turns=1, cost_usd=None)


def fold(b, check, label: str) -> bool:
    """Clicks '-' and requires the `minimized` row within FOLD_MAX_S, then reopens."""
    from agent_common import centre
    minus = b.rows("minus", 1)
    if not check(minus != [], f"{label}: the '-' button is on screen", b):
        return False
    before, opened = len(b.rows("minimized", 1)), len(b.rows("open", 1))
    started = time.monotonic()
    b.x.click(*centre(minus[-1].rect()))
    folded = b.wait(lambda: len(b.rows("minimized", 1)) > before, 30)
    took = time.monotonic() - started
    ok = check(folded and took <= FOLD_MAX_S, f"{label}: '-' folds the drawer within {FOLD_MAX_S} s (took {took:.2f} s)", b)
    if folded:
        icon = b.rows("icon", 1)[-1]
        b.x.click(*centre(tuple(int(v) for v in icon.fields[0].split(","))))
        check(b.wait(lambda: len(b.rows("open", 1)) > opened, 10), f"{label}: the drawer reopens", b)
    return ok


def case_app_flood(binary: Path, tmp: Path, check) -> None:
    script = {"on_prompt": [{"flood": [{"type": "assistant_delta", "session": "$SESSION", "text": "x"}, FLOOD]},
                            frame("assistant_message", text="zb-flood-done"), RESULT]}
    _w, b = scripted(binary, tmp, "app-flood", script)
    try:
        if not check(b.wait_page(), "the page loaded", b):
            return
        rss = Rss(b)
        life.send(b, "flood")
        if not check(b.wait(lambda: len(b.rows("delta", 1)) >= 100, 60), "the deltas arrive", b):
            return
        fold(b, check, "during the flood")
        clicks = len(b.clicks())
        b.x.click(200, 200)
        check(b.wait(lambda: len(b.clicks()) > clicks, 5), "during the flood a click reaches the page", b)
        started = time.monotonic()
        try:
            health = b.zb.call("page.health", {})["pages"]
        except Exception as exc:  # noqa: BLE001 - the check reports it
            health = repr(exc)
        took = time.monotonic() - started
        check(isinstance(health, list) and took <= 2.0, f"during the flood page.health answers within 2 s ({took:.2f} s)", b)
        check(b.wait(lambda: ("assistant", "zb-flood-done") in life.bubbles(b), 180), "the reply ends as usual", b)
        check(b.wait(lambda: life.statuses(b)[-1:] == [("ready", "-")], 30), f"and the drawer is ready ({life.statuses(b)[-3:]})", b)
        growth = rss.growth()
        check(not rss.killed and growth < 64, f"the browser grew by less than 64 MiB ({growth:.1f} MiB)")
    finally:
        life.release_x(b)
        b.stop()


def case_unbroken(binary: Path, tmp: Path, check) -> None:
    sizes = (48 * 1024, 200_000)
    script = {"on_prompts": [[frame("assistant_message", text="y" * n), RESULT] for n in sizes]}
    _w, b = scripted(binary, tmp, "unbroken", script)
    try:
        if not check(b.wait_page(), "the page loaded", b):
            return
        rss = Rss(b)
        for n in sizes:
            replies = len([1 for role, _ in life.bubbles(b) if role == "assistant"])
            life.send(b, f"run{n}")
            if not check(b.wait(lambda: len([1 for role, _ in life.bubbles(b) if role == "assistant"]) > replies, 60),
                         f"{n}: the reply is shown", b):
                return
            time.sleep(0.5)
            if not fold(b, check, f"{n} characters with no break opportunity"):
                return
        growth = rss.growth()
        check(not rss.killed and growth < 200, f"the browser grew by less than 200 MiB ({growth:.1f} MiB)")
    finally:
        life.release_x(b)
        b.stop()


ZWSP = "\u200b"
COPY_REPLIES = ["y" * 200_000, "\u754c" * 200, "x" * 130 + ZWSP + "z" * 130]


def keyboard_copy(b, check, label: str, expect: str, steps: int) -> None:
    """A click in the newest assistant bubble, Ctrl+Home, Shift+Right `steps` times and
    Ctrl+C, from a decoy CLIPBOARD: exactly `expect` must be copied."""
    rect = copy.text_rect(b, "assistant")
    if not check(rect is not None, f"{label}: the bubble's text is on screen (textrect row)", b):
        return
    owner = copy.seed_decoy(b)
    try:
        check(copy.clipboard(b) == copy.DECOY, f"{label}: the decoy owns the clipboard first")
        b.x.click(rect[0] + 4, rect[1] + 4)
        time.sleep(0.3)
        b.x.key("Home", modifiers=("Control_L",))
        for _ in range(steps):
            b.x.key("Right", modifiers=("Shift_L",), settle=0.005)
        time.sleep(0.3)
        b.x.key("c", modifiers=("Control_L",))
        time.sleep(0.5)
        got = copy.clipboard(b)
        check(got == expect, f"{label}: Shift+Right x{steps} and Ctrl+C copy exactly {len(expect)} characters "
                             f"({expect[:3]!r}...; got {None if got is None else (len(got), got[:3], got[-3:])})")
    finally:
        owner.kill()
        owner.wait()


def case_copy_exact(binary: Path, tmp: Path, check) -> None:
    script = {"on_prompts": [[frame("assistant_message", text=t), RESULT] for t in COPY_REPLIES]}
    _w, b = scripted(binary, tmp, "copy-exact", script)
    try:
        if not check(b.wait_page(), "the page loaded", b):
            return
        for n, text in enumerate(COPY_REPLIES):
            life.send(b, f"copy{n}")
            if not check(b.wait(lambda: len([1 for role, _ in life.bubbles(b) if role == "assistant"]) > n, 60),
                         f"reply {n} is shown", b):
                return
            time.sleep(1.0)
            if n == 0:
                copy.copy_and_check(b, check, "assistant", text, clicks=3)  # (a) the whole 200 KB run
                keyboard_copy(b, check, "(b) across the first break", "y" * 69, 70)
            elif n == 1:
                keyboard_copy(b, check, "(c) multibyte", "\u754c" * 69, 70)
            else:
                copy.copy_and_check(b, check, "assistant", text, clicks=3)  # (d) its own U+200B kept
    finally:
        life.release_x(b)
        b.stop()


def case_endless(binary: Path, tmp: Path, check) -> None:
    piece = "z" * (16 * 1024 - 64) + " "
    script = {"on_prompts": [[{"forever": {"type": "assistant_delta", "session": "$SESSION", "text": piece}}],
                             [frame("assistant_message", text="zb-after-overflow"), RESULT]],
              "on_interrupt": [STOPPED]}
    w, b = scripted(binary, tmp, "endless", script)
    try:
        if not check(b.wait_page(), "the page loaded", b):
            return
        rss = Rss(b)
        started = time.monotonic()
        life.send(b, "forever")
        if not check(b.wait(lambda: len(b.rows("delta", 1)) >= 4, 60), "the endless reply streams", b):
            return
        fold(b, check, "while it streams")
        overflowed = b.wait(lambda: ("error", OVERFLOW) in life.bubbles(b), 60)
        took = time.monotonic() - started
        check(overflowed and took <= 40, f"the reply is interrupted with {OVERFLOW!r} ({took:.1f} s; {life.bubbles(b)[-2:]})", b)
        check([f for f in app_frames(w) if f.get("type") == "interrupt"] != [], "the app sent the helper an interrupt")
        growth = rss.growth()
        check(not rss.killed and growth < 200, f"the browser grew by less than 200 MiB ({growth:.1f} MiB)")
        if overflowed:
            life.send(b, "again")
            check(b.wait(lambda: ("assistant", "zb-after-overflow") in life.bubbles(b), 30),
                  f"the next prompt is answered ({life.bubbles(b)[-2:]})", b)
    finally:
        life.release_x(b)
        b.stop()


def case_real_chain(binary: Path, tmp: Path, check) -> None:
    w = life.world(binary, tmp, "flood-real")
    fake = life.Fake(tmp, turns=[{"endless": "x" * 1023 + " "}, {"text": "zb-after-overflow-real"}])
    b = life.launch(binary, tmp, "real-chain", life.env_for(w, life.runtime_dir(), fake.seams()))
    try:
        if not check(b.wait_page(), "the page loaded", b):
            return
        rss = Rss(b)
        life.send(b, "forever")
        overflowed = b.wait(lambda: ("error", OVERFLOW) in life.bubbles(b), 90)
        check(overflowed, f"the real chain's endless reply is interrupted with {OVERFLOW!r} ({life.bubbles(b)[-2:]})", b)
        check(b.wait(lambda: fake.api.endless_ended >= 1, 30), "the CLI abandoned the endless request", b)
        growth = rss.growth()
        check(not rss.killed and growth < 200, f"the browser grew by less than 200 MiB ({growth:.1f} MiB)")
        if overflowed:
            life.send(b, "again")
            check(b.wait(lambda: ("assistant", "zb-after-overflow-real") in life.bubbles(b), 90),
                  f"the next prompt is answered by the API ({life.bubbles(b)[-2:]})", b)
    finally:
        life.release_x(b)
        b.stop()
        fake.close()


CASES = {"app-flood": case_app_flood, "unbroken": case_unbroken, "copy-exact": case_copy_exact,
         "endless": case_endless, "real-chain": case_real_chain}


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
