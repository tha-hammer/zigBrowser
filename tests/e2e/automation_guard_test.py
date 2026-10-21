#!/usr/bin/env python3
"""S8a (chat-drawer plan, "S8 in detail" decision 14): the in-task guard, on the real binary.

`options.guard = {marks: [{selector, attribute?, value}], target: true}` on an acting DOM verb is
checked by automation.js in the isolated world before every event it dispatches, every focus(),
every value write and every insert, so a page handler that changes a marker or the target in
the middle of the action stops it before its next page-visible step. A stopped action is -32015
expectation_mismatch with `data.reason` (`mark_changed`, `target_changed`) and `data.sent` =
{events, chars}: the events automation.js dispatched (a cancelled beforeinput included) and the
characters it wrote itself.

The fixture (tests/fixtures/automation/guard.html, ?mode=) records every event the page saw.
Exit 1 when Xvfb, xauth or the binary is missing."""

from __future__ import annotations

import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

FIXTURE = (HERE.parent / "fixtures/automation/guard.html").resolve()

MARKS = [{"selector": "css=#account", "value": "alice"}, {"selector": "css=#recipient", "value": "carol"}]


def guard(marks=MARKS, target=True) -> dict:
    return {"marks": marks, "target": target}


def page(b, mode: str) -> None:
    b.zb.call("page.navigate", {"url": f"{FIXTURE.as_uri()}?mode={mode}"})
    b.wait_page()


def events(b, prefix: str) -> list[str]:
    seen = json.loads(b.ev("JSON.stringify(window.__events)"))
    return [e for e in seen if e.endswith(":" + prefix) and not e.startswith("focus:")]


def refused(b, method: str, params: dict):
    from zigbrowser.errors import ZigBrowserError
    try:
        b.zb.call(method, params)
    except ZigBrowserError as err:
        data = getattr(err, "diagnostics", None) or getattr(err, "data", None) or {}
        return getattr(err, "code", None), data
    return None, {}


def case_guard(binary: Path, tmp: Path, check) -> None:
    from agent_common import Browser
    b = Browser(binary, tmp, "guard", [], url=FIXTURE.as_uri(), e2e=False)
    try:
        if not check(b.wait_page(), "the fixture loaded", b):
            return

        # A guard that holds lets the click through, all five events.
        page(b, "none")
        result = b.zb.call("dom.click", {"selector": "css=#buy", "options": {"guard": guard()}})
        check(result == {"ok": True}, f"a holding guard: the click is done ({result})")
        check(events(b, "buy") == ["pointerdown:buy", "mousedown:buy", "pointerup:buy", "mouseup:buy", "click:buy"],
              f"a holding guard: the page saw the whole click ({events(b, 'buy')})")

        # A marker already wrong: nothing at all reaches the page.
        page(b, "none")
        code, data = refused(b, "dom.click", {"selector": "css=#buy", "options": {"guard": guard([{"selector": "css=#account", "value": "zed"}])}})
        check((code, data.get("reason"), data.get("sent")) == (-32015, "mark_changed", {"events": 0, "chars": 0}),
              f"a wrong marker: -32015 mark_changed, nothing sent ({code}, {data})")
        check(events(b, "buy") == [], f"a wrong marker: the page saw nothing ({events(b, 'buy')})")

        # pointerdown switches the account: only pointerdown was dispatched.
        page(b, "pointerdown-account")
        code, data = refused(b, "dom.click", {"selector": "css=#buy", "options": {"guard": guard()}})
        check((code, data.get("reason"), data.get("sent")) == (-32015, "mark_changed", {"events": 1, "chars": 0}),
              f"pointerdown switches the account: stopped after it ({code}, {data})")
        check(events(b, "buy") == ["pointerdown:buy"], f"pointerdown switches the account: no mousedown or click ({events(b, 'buy')})")

        # keydown on the first character swaps the recipient: no character is written.
        page(b, "keydown-recipient")
        code, data = refused(b, "dom.type", {"selector": "css=#msg", "text": "hi", "options": {"guard": guard()}})
        check((code, data.get("reason"), data.get("sent")) == (-32015, "mark_changed", {"events": 1, "chars": 0}),
              f"keydown swaps the recipient: stopped before the write ({code}, {data})")
        check(b.ev("document.getElementById('msg').value") == "", "keydown swaps the recipient: nothing written")
        check(events(b, "msg") == ["keydown:msg"], f"keydown swaps the recipient: no input or keyup ({events(b, 'msg')})")

        # The first input event swaps the target for a same-fields clone: one character, nothing more.
        page(b, "input-clone")
        code, data = refused(b, "dom.type", {"selector": "css=#msg", "text": "hi", "options": {"guard": guard()}})
        check((code, data.get("reason"), data.get("sent")) == (-32015, "target_changed", {"events": 2, "chars": 1}),
              f"the target is cloned: stopped after the first character ({code}, {data})")
        check(b.ev("window.__clone.value") == "", "the target is cloned: the clone got nothing")
        check(events(b, "msg") == ["keydown:msg", "input:msg"], f"the target is cloned: no keyup, no second key ({events(b, 'msg')})")

        # A contenteditable beforeinput swaps the recipient: no insert, no input event.
        page(b, "beforeinput-recipient")
        code, data = refused(b, "dom.type", {"selector": "css=#editor", "text": "hi", "options": {"guard": guard()}})
        check((code, data.get("reason"), data.get("sent")) == (-32015, "mark_changed", {"events": 2, "chars": 0}),
              f"beforeinput swaps the recipient: stopped before the insert ({code}, {data})")
        check(b.ev("document.getElementById('editor').textContent") == "", "beforeinput swaps the recipient: nothing inserted")
        check(events(b, "editor") == ["keydown:editor", "beforeinput:editor"], f"beforeinput swaps the recipient: no input ({events(b, 'editor')})")

        # A Draft.js-style editor cancels beforeinput and inserts itself: automation wrote nothing,
        # but two events reached the page, which acted on them.
        page(b, "draft")
        code, data = refused(b, "dom.type", {"selector": "css=#editor", "text": "hi", "options": {"guard": guard()}})
        check((code, data.get("reason"), data.get("sent")) == (-32015, "mark_changed", {"events": 2, "chars": 0}),
              f"a Draft.js-style editor: two events, no character of ours ({code}, {data})")
        check(b.ev("document.getElementById('editor').textContent") == "h", "a Draft.js-style editor: the page's own edit holds one character")

        # The guard is synthetic-only and acting-verbs-only.
        page(b, "none")
        code, _ = refused(b, "dom.click", {"selector": "css=#buy", "options": {"input": "native", "guard": guard()}})
        check(code == -32602, f"a guard with native input is -32602 ({code})")
        code, _ = refused(b, "dom.getText", {"selector": "css=#buy", "options": {"guard": guard()}})
        check(code == -32602, f"a guard on getText is -32602 ({code})")
        check(events(b, "buy") == [], f"refused at parse: the page saw nothing ({events(b, 'buy')})")
    finally:
        b.stop()


CASES = {"guard": case_guard}


def main() -> int:
    from agent_common import run_main
    return run_main(__doc__, CASES)


if __name__ == "__main__":
    raise SystemExit(main())
