#!/usr/bin/env python3
"""S8a red (RoseCat on 76cb14a): the chunks of a guarded dom.type are one action, on the real
binary. Chunk 1 binds its target element and its document by the isolated world's own tokens;
every later chunk must find that same element in that same document.

- A timer between chunks replaces the input (and the contenteditable) with a same-selector,
  same-marks clone: the type stops with -32015 target_changed; the original holds exactly the
  first 16 characters and the clone none.
- A timer between chunks loads the page again (a new document, the same selector and marks): the
  type stops with -32015 document_changed, and the new document's field holds nothing. The text
  is 30 chunks long, so the new document is in place before the last chunk.

The fixture is tests/fixtures/automation/guard.html. Exit 1 when Xvfb, xauth or the binary is
missing."""

from __future__ import annotations

import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from automation_guard_test import FIXTURE, guard, page, refused  # noqa: E402

LONG = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMN"
LONGER = "abcdefghijklmnop" * 30


def case_identity(binary: Path, tmp: Path, check) -> None:
    from agent_common import Browser
    b = Browser(binary, tmp, "guard-chunks2", [], url=FIXTURE.as_uri(), e2e=False)
    try:
        if not check(b.wait_page(), "the fixture loaded", b):
            return
        for target, field in (("css=#msg", "value"), ("css=#editor", "textContent")):
            page(b, "timer-clone")
            code, data = refused(b, "dom.type", {"selector": target, "text": LONG, "options": {"guard": guard()}})
            check((code, data.get("reason"), (data.get("sent") or {}).get("chars")) == (-32015, "target_changed", 16),
                  f"{target}: a same-selector clone between chunks: stopped after chunk 1 ({code}, {data})")
            check(b.ev(f"window.__orig.{field}") == LONG[:16], f"{target}: the original holds exactly chunk 1 ({b.ev(f'window.__orig.{field}')!r})")
            check(b.ev(f"window.__clone.{field}") == "", f"{target}: the clone holds nothing ({b.ev(f'window.__clone.{field}')!r})")

        for target, read in (("css=#msg", "document.getElementById('msg').value"), ("css=#editor", "document.getElementById('editor').textContent")):
            page(b, "timer-reload")
            code, data = refused(b, "dom.type", {"selector": target, "text": LONGER, "options": {"guard": guard()}})
            check((code, data.get("reason")) == (-32015, "document_changed"), f"{target}: a new document between chunks stops the type ({code}, {data})")
            b.wait_page()
            time.sleep(0.2)
            check("reloaded=1" in b.ev("location.href"), f"{target}: the page is the new document ({b.ev('location.href')!r})")
            check(b.ev(read) == "", f"{target}: the new document's field holds nothing ({b.ev(read)!r})")
    finally:
        b.stop()


CASES = {"identity": case_identity}


def main() -> int:
    from agent_common import run_main
    return run_main(__doc__, CASES)


if __name__ == "__main__":
    raise SystemExit(main())
