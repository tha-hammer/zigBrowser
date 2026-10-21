#!/usr/bin/env python3
"""S8a (chat-drawer plan, "S8 in detail" decision 15): a guarded dom.type runs in chunks of 16
code points, each its own automation.js evaluation, on the real binary.

- Long text, ASCII or with non-BMP and multi-byte characters across the chunk boundaries, arrives
  byte for byte in an input and in a contenteditable.
- The page's own event loop runs between chunks: a timer the first input event sets swaps the
  recipient, and the next chunk's first check stops the type after exactly 16 characters
  (-32015 mark_changed, data.sent.chars 16). A single evaluation would never let that timer run
  and would type all 40.

The fixture is tests/fixtures/automation/guard.html. Exit 1 when Xvfb, xauth or the binary is
missing."""

from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from automation_guard_test import FIXTURE, guard, page, refused  # noqa: E402

LONG = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMN"
WIDE = "aaaaaaaaaaaaaaa\U0001F600ébbbbbbbbbbbbbb中z!"


def case_chunks(binary: Path, tmp: Path, check) -> None:
    from agent_common import Browser
    b = Browser(binary, tmp, "guard-chunks", [], url=FIXTURE.as_uri(), e2e=False)
    try:
        if not check(b.wait_page(), "the fixture loaded", b):
            return
        for target, read in (("css=#msg", "document.getElementById('msg').value"), ("css=#editor", "document.getElementById('editor').textContent")):
            for text in (LONG, WIDE):
                page(b, "none")
                result = b.zb.call("dom.type", {"selector": target, "text": text, "options": {"guard": guard()}})
                check(result == {"ok": True}, f"{target}: a guarded type of {len(text)} code points is done ({result})")
                got = b.ev(read)
                check(got == text, f"{target}: every character arrived, in order ({got!r})")

        for target, read in (("css=#msg", "document.getElementById('msg').value"), ("css=#editor", "document.getElementById('editor').textContent")):
            page(b, "timer-recipient")
            code, data = refused(b, "dom.type", {"selector": target, "text": LONG, "options": {"guard": guard()}})
            check((code, data.get("reason"), (data.get("sent") or {}).get("chars")) == (-32015, "mark_changed", 16),
                  f"{target}: a timer between chunks swaps the recipient: stopped at 16 ({code}, {data})")
            check(b.ev(read) == LONG[:16], f"{target}: exactly the first chunk arrived ({b.ev(read)!r})")
    finally:
        b.stop()


CASES = {"chunks": case_chunks}


def main() -> int:
    from agent_common import run_main
    return run_main(__doc__, CASES)


if __name__ == "__main__":
    raise SystemExit(main())
