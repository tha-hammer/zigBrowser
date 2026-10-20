#!/usr/bin/env python3
"""S5c-1, the reply cap is signalled, not counted (chat-drawer plan S5.6, rev 16.20.11 and
16.20.12; RoseCat ae39e2a on f9cb26a, e2cb1b0 on 0fa4fdc). A bubble's text is at most
256 KiB with its "\\n[output truncated]" marker, so a reply's content is capped at
CONTENT_MAX (262,125 bytes). The helper forwards exactly a reply's longest UTF-8 prefix
that fits it, which can stop 1 to 3 bytes short, and then sends `reply_capped`; the app
arms its overflow timer at that frame:
- capped-multibyte: the scripted helper sends 262,122 bytes of 3-byte characters as
  deltas, then `reply_capped`, then nothing more while the reply runs. Within 30 s the
  app sends `interrupt` and the reply ends with "Agent output overflow"; Ctrl+A and Ctrl+C
  on the bubble copy exactly the forwarded text and the marker; the next prompt is
  answered.
- capped-duplicate: the same with a second `reply_capped` 6 s after the first. The
  overflow still comes 10 s after the first (within 14 s; a restarted timer would take
  16 s), and the copy has one marker.
- capped-finite (rev 16.20.13, RoseCat 5aea621): the capped reply then ends with a shorter
  `assistant_message` and its `result`. The completed bubble does not shrink: Ctrl+A and
  Ctrl+C copy exactly the streamed prefix and one marker; no overflow follows, and the
  next reply has a bubble of its own.
- drawer-cap-finite (RoseCat 6d812b4): the drawer's own byte cap. The scripted helper
  sends 278,511 bytes of deltas, past CONTENT_MAX, and no `reply_capped`, then a shorter
  `assistant_message` and its `result`. The completed bubble copies exactly the deltas'
  longest prefix that fits CONTENT_MAX and one marker.
- capped-stale: a `reply_capped` with the first prompt's `prompt_id`, after the first
  reply's `result` and again after the second reply's first delta, does not cap the
  second reply: while it runs for 13 s, its bubble copies exactly its text, no overflow
  and no interrupt follow, and it ends whole.
- real-chain-multibyte: capped-multibyte through the real helper and CLI, against the
  fake API's endless turn of a 1,022-byte multibyte piece (its longest prefix that fits
  is 262,124 bytes): the overflow bubble, the CLI's request abandoned, the bubble's copy,
  and the next prompt answered by the API.
- real-chain-finite: through the real helper and CLI, a 300,000-byte multibyte reply
  completes: its bubble copies exactly its longest prefix that fits CONTENT_MAX and one
  marker; then 200,000 quote and backslash characters (escaped to 400 KB, under the cap) copy whole;
  then the next prompt is answered.

Same world as agent_flood_test.py: the real binary on its own Xvfb in a network namespace
of its own (re-exec'd as --sealed-child). Exit 1 when Xvfb, xauth, bwrap, the venv or the
binary is missing."""

from __future__ import annotations

import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import agent_flood_test as flood  # noqa: E402 - its scripted helper, copy check and fold
import agent_host_lifecycle_test as life  # noqa: E402

CAP = 256 * 1024
TRUNCATED = "\n[output truncated]"
CONTENT_MAX = CAP - len(TRUNCATED.encode())  # rev 16.20.12: the marker counts inside 256 KiB
CHAR = "界"  # 3 bytes of UTF-8
PIECES = [CHAR * 5461] * 15 + [CHAR * 5459]  # 15 x 16,383 + 16,377 = 262,122 bytes
CAPPED = {"frame": {"type": "reply_capped", "session": "$SESSION", "prompt_id": "$PROMPT_ID"}}
STALE = {"frame": {"type": "reply_capped", "session": "$SESSION", "prompt_id": 1}}  # the first prompt's


def utf8_prefix(text: str, limit: int) -> str:
    return text.encode()[:limit].decode("utf-8", "ignore")


def deltas(pieces: list[str]) -> list[dict]:
    return [{"frame": {"type": "assistant_delta", "session": "$SESSION", "text": p}} for p in pieces]


def interrupts(w) -> int:
    return len([f for f in flood.app_frames(w) if f.get("type") == "interrupt"])


def overflowed_then_answered(b, check, label: str, shown: str, after: str, started: float, within: float,
                             stopped) -> None:
    """`stopped`: (what it checks, a check that the running reply was stopped)."""
    ok = b.wait(lambda: ("error", flood.OVERFLOW) in life.bubbles(b), 60)
    took = time.monotonic() - started
    check(ok and took <= within, f"{label}: the reply is interrupted with {flood.OVERFLOW!r} within {within:.0f} s "
                                 f"({took:.1f} s; {life.bubbles(b)[-2:]}; {len(b.rows('delta', 1))} delta rows)", b)
    check(stopped[1](), f"{label}: {stopped[0]}")
    if not ok:
        return
    flood.triple_copy(b, check, f"{label}: the capped bubble, Ctrl+A", shown + TRUNCATED, select_all=True)
    flood.fold(b, check, f"{label}: before the next prompt")  # reopening focuses the input
    life.send(b, "again")
    check(b.wait(lambda: ("assistant", after) in life.bubbles(b), 90),
          f"{label}: the next prompt is answered ({life.bubbles(b)[-2:]})", b)


def scripted_capped(binary: Path, tmp: Path, check, label: str, after_capped: list[dict], within: float) -> None:
    shown = "".join(PIECES)
    assert len(shown.encode()) == CONTENT_MAX - 3
    script = {"on_prompts": [deltas(PIECES) + [CAPPED] + after_capped,
                             [flood.frame("assistant_message", text="zb-after-capped"), flood.RESULT]],
              "on_interrupt": [flood.STOPPED]}
    w, b = flood.scripted(binary, tmp, label, script)
    try:
        if not check(b.wait_page(), "the page loaded", b):
            return
        life.send(b, "capped")
        if not check(b.wait(lambda: len(b.rows("delta", 1)) >= len(PIECES), 60), f"{label}: the reply streams", b):
            return
        started = time.monotonic()  # the first reply_capped follows the last delta at once
        overflowed_then_answered(b, check, label, shown, "zb-after-capped", started, within,
                                 ("the app sent the helper one interrupt", lambda: interrupts(w) == 1))
    finally:
        life.release_x(b)
        b.stop()


def case_capped_multibyte(binary: Path, tmp: Path, check) -> None:
    scripted_capped(binary, tmp, check, "capped-multibyte", [], 30)


def case_capped_duplicate(binary: Path, tmp: Path, check) -> None:
    scripted_capped(binary, tmp, check, "capped-duplicate", [{"sleep": 6}, CAPPED], 14)


def statuses_ready(b) -> int:
    return life.statuses(b).count(("ready", "-"))


def rejected(b) -> list[str]:
    return [line for line in b.err if "rejected frame" in line]


# A frame-cut message as the app would get it: fake_host escapes non-ASCII (6 bytes per
# 3-byte character), so 40,000 characters keep its line under the 256 KiB frame cap.
SHORTER = 120_000


def case_capped_finite(binary: Path, tmp: Path, check) -> None:
    shown = "".join(PIECES)
    shorter = utf8_prefix(shown, SHORTER) + TRUNCATED  # what a frame-cut message would carry
    script = {"on_prompts": [deltas(PIECES) + [CAPPED, flood.frame("assistant_message", text=shorter), flood.RESULT],
                             [flood.frame("assistant_message", text="zb-after-finite"), flood.RESULT]],
              "on_interrupt": [flood.STOPPED]}
    w, b = flood.scripted(binary, tmp, "capped-finite", script)
    try:
        if not check(b.wait_page(), "the page loaded", b):
            return
        ready = statuses_ready(b)
        life.send(b, "finite")
        if not check(b.wait(lambda: statuses_ready(b) > ready, 60), "the capped reply completes (status ready)", b):
            return
        time.sleep(1.0)
        check(rejected(b) == [], f"capped-finite: the app took every frame, the shorter message too ({rejected(b)[:2]})")
        flood.triple_copy(b, check, "capped-finite: the completed bubble, Ctrl+A", shown + TRUNCATED, select_all=True)
        time.sleep(11.0)  # past the overflow deadline
        check(("error", flood.OVERFLOW) not in life.bubbles(b), f"no overflow ({life.bubbles(b)[-2:]})")
        check(interrupts(w) == 0, f"the app sent no interrupt ({interrupts(w)})")
        flood.fold(b, check, "capped-finite: before the next prompt")
        life.send(b, "again")
        check(b.wait(lambda: ("assistant", "zb-after-finite") in life.bubbles(b), 30),
              f"the next prompt is answered ({life.bubbles(b)[-2:]})", b)
        assistants = [t for role, t in life.bubbles(b) if role == "assistant"]
        check(len(assistants) == 2 and assistants[-1] == "zb-after-finite",
              f"the next reply has a bubble of its own ({len(assistants)} assistant bubbles)")
    finally:
        life.release_x(b)
        b.stop()


def case_drawer_cap_finite(binary: Path, tmp: Path, check) -> None:
    pieces = [CHAR * 5461] * 17  # 278,511 bytes: the drawer must cap them itself
    shown = utf8_prefix("".join(pieces), CONTENT_MAX)
    shorter = utf8_prefix(shown, SHORTER) + TRUNCATED
    script = {"on_prompts": [deltas(pieces) + [flood.frame("assistant_message", text=shorter), flood.RESULT],
                             [flood.frame("assistant_message", text="zb-after-drawer-cap"), flood.RESULT]],
              "on_interrupt": [flood.STOPPED]}
    w, b = flood.scripted(binary, tmp, "drawer-cap", script)
    try:
        if not check(b.wait_page(), "the page loaded", b):
            return
        ready = statuses_ready(b)
        life.send(b, "over")
        if not check(b.wait(lambda: statuses_ready(b) > ready, 60), "the over-cap reply completes (status ready)", b):
            return
        time.sleep(1.0)
        check(rejected(b) == [], f"drawer-cap-finite: the app took every frame, the shorter message too ({rejected(b)[:2]})")
        flood.triple_copy(b, check, "drawer-cap-finite: the completed bubble, Ctrl+A", shown + TRUNCATED, select_all=True)
        flood.fold(b, check, "drawer-cap-finite: before the next prompt")
        life.send(b, "again")
        check(b.wait(lambda: ("assistant", "zb-after-drawer-cap") in life.bubbles(b), 30),
              f"the next prompt is answered ({life.bubbles(b)[-2:]})", b)
        check(("error", flood.OVERFLOW) not in life.bubbles(b), f"no overflow ({life.bubbles(b)[-3:]})")
    finally:
        life.release_x(b)
        b.stop()


def case_capped_stale(binary: Path, tmp: Path, check) -> None:
    second = ["zb-second ", "reply, whole"]
    script = {"on_prompts": [deltas(["zb-first reply"]) + [flood.frame("assistant_message", text="zb-first reply"),
                                                         flood.RESULT, CAPPED],
                             deltas(second[:1]) + [STALE] + deltas(second[1:])
                             + [{"sleep": 13}, flood.frame("assistant_message", text="".join(second)), flood.RESULT]],
              "on_interrupt": [flood.STOPPED]}
    w, b = flood.scripted(binary, tmp, "capped-stale", script)
    try:
        if not check(b.wait_page(), "the page loaded", b):
            return
        life.send(b, "first")
        if not check(b.wait(lambda: ("assistant", "zb-first reply") in life.bubbles(b), 30), "the first reply ends", b):
            return
        time.sleep(1.0)  # the first stray frame is read
        life.send(b, "second")
        if not check(b.wait(lambda: len(b.rows("delta", 1)) >= 3, 30), "the second reply streams", b):
            return
        started = time.monotonic()
        time.sleep(1.0)
        flood.triple_copy(b, check, "capped-stale: the running second reply, Ctrl+A", "".join(second), select_all=True)
        ended = b.wait(lambda: ("assistant", "".join(second)) in life.bubbles(b), 30)
        check(ended and time.monotonic() - started >= 10,
              f"the second reply ran past the overflow deadline and ended whole ({life.bubbles(b)[-2:]})", b)
        check(("error", flood.OVERFLOW) not in life.bubbles(b), f"no overflow ({life.bubbles(b)[-3:]})")
        check(interrupts(w) == 0, f"the app sent no interrupt ({interrupts(w)})")
    finally:
        life.release_x(b)
        b.stop()


def case_real_chain_multibyte(binary: Path, tmp: Path, check) -> None:
    piece = CHAR * 340 + "  "  # 1,022 bytes: whole pieces never sum to the bound
    shown = utf8_prefix(piece * (CONTENT_MAX // len(piece.encode()) + 2), CONTENT_MAX)
    assert len(shown.encode()) == CONTENT_MAX - 1
    w = life.world(binary, tmp, "cap-real")
    fake = life.Fake(tmp, turns=[{"endless": piece}, {"text": "zb-after-capped-real"}])
    b = life.launch(binary, tmp, "real-chain-multibyte", life.env_for(w, life.runtime_dir(), fake.seams()))
    try:
        if not check(b.wait_page(), "the page loaded", b):
            return
        started = time.monotonic()
        life.send(b, "forever")
        overflowed_then_answered(b, check, "real-chain-multibyte", shown, "zb-after-capped-real", started, 30,
                                 ("the CLI abandoned the endless request",
                                  lambda: b.wait(lambda: fake.api.endless_ended >= 1, 30)))
    finally:
        life.release_x(b)
        b.stop()
        fake.close()


def case_real_chain_finite(binary: Path, tmp: Path, check) -> None:
    wide = CHAR * 100_000  # 300,000 bytes, no spaces
    escaped = '"\\' * 100_000  # 200,000 bytes, 400 KB once escaped
    w = life.world(binary, tmp, "cap-finite")
    fake = life.Fake(tmp, turns=[{"text": wide}, {"text": escaped}, {"text": "zb-after-finite-real"}])
    b = life.launch(binary, tmp, "real-chain-finite", life.env_for(w, life.runtime_dir(), fake.seams()))
    try:
        if not check(b.wait_page(), "the page loaded", b):
            return
        for n, (prompt, want) in enumerate([("wide", utf8_prefix(wide, CONTENT_MAX) + TRUNCATED), ("escaped", escaped)]):
            if n > 0:
                flood.fold(b, check, f"real-chain-finite: before {prompt}")
            ready = statuses_ready(b)
            life.send(b, prompt)
            if not check(b.wait(lambda: statuses_ready(b) > ready, 120), f"real-chain-finite: the {prompt} reply completes", b):
                return
            time.sleep(1.0)
            flood.triple_copy(b, check, f"real-chain-finite: the completed {prompt} bubble, Ctrl+A", want, select_all=True)
        check(("error", flood.OVERFLOW) not in life.bubbles(b), f"no overflow ({life.bubbles(b)[-2:]})")
        flood.fold(b, check, "real-chain-finite: before the next prompt")
        life.send(b, "again")
        check(b.wait(lambda: ("assistant", "zb-after-finite-real") in life.bubbles(b), 90),
              f"real-chain-finite: the next prompt is answered by the API ({life.bubbles(b)[-2:]})", b)
    finally:
        life.release_x(b)
        b.stop()
        fake.close()


CASES = {"capped-multibyte": case_capped_multibyte, "capped-duplicate": case_capped_duplicate,
         "capped-finite": case_capped_finite, "drawer-cap-finite": case_drawer_cap_finite,
         "capped-stale": case_capped_stale,
         "real-chain-multibyte": case_real_chain_multibyte, "real-chain-finite": case_real_chain_finite}


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
