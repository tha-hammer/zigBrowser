#!/usr/bin/env python3
"""S8a red (RoseCat on 9295b0b): a guarded contenteditable insert counts only what was inserted.

WebKit's execCommand('insertText') fires its own (native) beforeinput after automation's. A
character counts only when the browser's edit really put it in the editor: its own input event
fired, the editor is still in the page, and its content changed.
- The page cancels that native beforeinput and changes a mark: nothing inserted, `sent.chars` 0
  (events 2: keydown and automation's beforeinput), the editor empty, no input event faked.
- The page makes the editor non-editable inside it: WebKit still fires input but inserts
  nothing; `sent.chars` 0.
- The page removes the editor inside it: nothing inserted, `sent.chars` 0.
- A native insert that did happen still counts (tests/e2e/automation_guard_test.py,
  editor-input-recipient: chars 1).
(The fallback range insert after a refused execCommand is not reachable from a page in WebKit:
cancel, unselect, non-editable, attribute removal and detachment were probed; RoseCat 9295b0b.)

The fixture is tests/fixtures/automation/guard.html. Exit 1 when Xvfb, xauth or the binary is
missing."""

from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from automation_guard_test import FIXTURE, events, guard, page, refused  # noqa: E402


def case_insert(binary: Path, tmp: Path, check) -> None:
    from agent_common import Browser
    b = Browser(binary, tmp, "guard-insert", [], url=FIXTURE.as_uri(), e2e=False)
    try:
        if not check(b.wait_page(), "the fixture loaded", b):
            return
        for mode, read, no_input in (("native-beforeinput-cancel", "document.getElementById('editor').textContent", True),
                                     ("native-beforeinput-noneditable", "document.getElementById('editor').textContent", False),
                                     ("native-beforeinput-detach", "(document.getElementById('editor') || {textContent: ''}).textContent", True)):
            page(b, mode)
            code, data = refused(b, "dom.type", {"selector": "css=#editor", "text": "hi", "options": {"guard": guard()}})
            check((code, data.get("reason"), data.get("sent")) == (-32015, "mark_changed", {"events": 2, "chars": 0}),
                  f"{mode}: nothing inserted, nothing counted ({code}, {data})")
            text = b.ev(read)
            check(text == "", f"{mode}: the editor holds nothing ({text!r})")
            if no_input:
                seen = events(b, "editor")
                check("input:editor" not in seen, f"{mode}: no input event for an edit that did not happen ({seen})")
    finally:
        b.stop()


CASES = {"insert": case_insert}


def main() -> int:
    from agent_common import run_main
    return run_main(__doc__, CASES)


if __name__ == "__main__":
    raise SystemExit(main())
