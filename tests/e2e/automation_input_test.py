#!/usr/bin/env python3
"""E2E: input verbs against the live WebKitGTK page over the automation socket.

N1: dom.type / dom.fill on contenteditable elements, both a plain one and a
Draft.js-like editor that cancels beforeinput and applies text to its own
model (the shape of X's post box)."""

from __future__ import annotations

import argparse
import json
import socket
import struct
import time
import subprocess
import tempfile
import threading
from pathlib import Path

from automation_api_lifecycle_test import _read_lines, call_rpc, expect_equal, recv_exact, terminate
from slice2_common import SKIP_EXIT, automation_auth, detect_runner, eprint, require_file


def evaluate(socket_path: Path, expression: str, req_id: int, timeout: float):
    return call_rpc(socket_path, "page.evaluate", {"expression": expression}, req_id, timeout)["result"]


def text_of(socket_path: Path, selector: str, req_id: int, timeout: float) -> str:
    return call_rpc(socket_path, "dom.getText", {"selector": selector}, req_id, timeout)["text"]


def run_contenteditable(socket_path: Path, t: float) -> None:
    ok = {"ok": True}
    ids = iter(range(10, 100))

    def rpc(method: str, params: dict):
        return call_rpc(socket_path, method, params, next(ids), t)

    def plain_inputs() -> int:
        return evaluate(socket_path, "window.plainInputs", next(ids), t)

    # Plain editor: exactly one input event per typed character and one per
    # fill, so a duplicated native + synthetic input fails the test.
    expect_equal("type into plain", rpc("dom.type", {"selector": "css=#plain", "text": "Hello"}), ok)
    expect_equal("plain text after type", text_of(socket_path, "css=#plain", next(ids), t), "Hello")
    expect_equal("input events after type", plain_inputs(), 5)
    expect_equal("type appends to plain", rpc("dom.type", {"selector": "css=#plain", "text": " there"}), ok)
    expect_equal("plain text after second type", text_of(socket_path, "css=#plain", next(ids), t), "Hello there")
    expect_equal("input events after second type", plain_inputs(), 11)
    expect_equal("fill plain", rpc("dom.fill", {"selector": "css=#plain", "value": "Replaced"}), ok)
    expect_equal("plain text after fill", text_of(socket_path, "css=#plain", next(ids), t), "Replaced")
    expect_equal("input events after fill", plain_inputs(), 12)
    expect_equal("empty fill plain", rpc("dom.fill", {"selector": "css=#plain", "value": ""}), ok)
    expect_equal("plain text after empty fill", evaluate(socket_path, "document.getElementById('plain').textContent", next(ids), t), "")
    expect_equal("input events after empty fill", plain_inputs(), 13)
    # The text goes through the browser's own editing (execCommand), not a
    # DOM splice: the browser can undo it, which a Range insert never allows.
    expect_equal("type for undo", rpc("dom.type", {"selector": "css=#plain", "text": "ab"}), ok)
    undone = evaluate(socket_path, "(function () { var p = document.getElementById('plain'); p.focus();"
                      " document.execCommand('undo'); return p.textContent; })()", next(ids), t)
    if undone == "ab" or not "ab".startswith(undone):
        raise AssertionError(f"typing left no browser undo step (not native editing): after undo {undone!r}")

    # Draft.js-like editor: it cancels beforeinput and owns the edit.
    expect_equal("type into draft", rpc("dom.type", {"selector": "css=#draft", "text": "Hi X"}), ok)
    expect_equal("draft model after type", evaluate(socket_path, "window.draftModel", next(ids), t), "Hi X")
    expect_equal("draft text after type", text_of(socket_path, "css=#draft", next(ids), t), "Hi X")
    expect_equal("draft beforeinputs after type", evaluate(socket_path, "window.draftBeforeInputs", next(ids), t), 4)
    expect_equal("fill draft", rpc("dom.fill", {"selector": "css=#draft", "value": "New post"}), ok)
    expect_equal("draft model after fill", evaluate(socket_path, "window.draftModel", next(ids), t), "New post")
    expect_equal("draft text after fill", text_of(socket_path, "css=#draft", next(ids), t), "New post")
    expect_equal("empty fill draft", rpc("dom.fill", {"selector": "css=#draft", "value": ""}), ok)
    expect_equal("draft model after empty fill", evaluate(socket_path, "window.draftModel", next(ids), t), "")
    expect_equal("draft DOM after empty fill", evaluate(socket_path, "document.getElementById('draft').textContent", next(ids), t), "")
    # Cancelled beforeinput means no input event ever reaches the editor.
    expect_equal("draft input events", evaluate(socket_path, "window.draftInputs", next(ids), t), 0)


def run_press(socket_path: Path, t: float) -> None:
    ok = {"ok": True}
    ids = iter(range(200, 400))

    def rpc(method: str, params: dict):
        return call_rpc(socket_path, method, params, next(ids), t)

    def js(expression: str):
        return evaluate(socket_path, expression, next(ids), t)

    def press(params: dict) -> list[dict]:
        """Run one dom.press and return exactly the key events it produced."""
        js("(window.keylog = [], 0)")
        expect_equal(f"press {params}", rpc("dom.press", params), ok)
        return js("window.keylog")

    def shape(events: list[dict], *fields: str) -> list[tuple]:
        return [tuple(e[f] for f in fields) for e in events]

    # Enter in a form input: keydown, keypress, keyup, then the form submits.
    events = press({"selector": "css=#q", "key": "Enter"})
    expect_equal("Enter event sequence", shape(events, "type", "key", "code", "keyCode", "target"),
                 [("keydown", "Enter", "Enter", 13, "q"), ("keypress", "Enter", "Enter", 13, "q"),
                  ("keyup", "Enter", "Enter", 13, "q")])
    expect_equal("Enter submitted the form", js("window.submits"), 1)

    # Tab moves focus to the next tabbable element; Shift+Tab moves it back.
    events = press({"selector": "css=#q", "key": "Tab"})
    expect_equal("Tab event sequence", shape(events, "type", "target"), [("keydown", "q"), ("keyup", "q2")])
    expect_equal("focus after Tab", js("document.activeElement.id"), "q2")
    events = press({"key": "Tab", "modifiers": ["Shift"]})
    expect_equal("Shift+Tab event sequence", shape(events, "type", "key", "shift"),
                 [("keydown", "Shift", True), ("keydown", "Tab", True), ("keyup", "Tab", True), ("keyup", "Shift", False)])
    expect_equal("focus after Shift+Tab", js("document.activeElement.id"), "q")

    # Without a selector the key goes to the focused element.
    events = press({"key": "Escape"})
    expect_equal("Escape event sequence", shape(events, "type", "key", "code", "keyCode", "target"),
                 [("keydown", "Escape", "Escape", 27, "q"), ("keyup", "Escape", "Escape", 27, "q")])

    # Several text fields and no submit button: Enter does not submit
    # (HTML implicit submission), synthetic and native alike.
    press({"selector": "css=#ns1", "key": "Enter"})
    expect_equal("Enter without a default button does not submit", js("window.nosubmits"), 0)
    press({"selector": "css=#bf1", "key": "Enter"})
    expect_equal("an invalid button type is still the default button", js("window.bogusSubmits"), 1)

    # Modifiers: the target is focused before the first key event.
    events = press({"selector": "css=#q2", "key": "a", "modifiers": ["Control"]})
    expect_equal("Control+a event sequence", shape(events, "type", "key", "code", "keyCode", "ctrl", "target", "active"),
                 [("keydown", "Control", "ControlLeft", 17, True, "q2", "q2"),
                  ("keydown", "a", "KeyA", 65, True, "q2", "q2"),
                  ("keyup", "a", "KeyA", 65, True, "q2", "q2"),
                  ("keyup", "Control", "ControlLeft", 17, False, "q2", "q2")])
    expect_equal("Control+a inserted nothing", js("document.getElementById('q2').value"), "")

    # A printable key: keydown, keypress, keyup, and the character is typed.
    events = press({"selector": "css=#q2", "key": "x"})
    expect_equal("x event sequence", shape(events, "type", "key", "code", "keyCode", "target"),
                 [("keydown", "x", "KeyX", 88, "q2"), ("keypress", "x", "KeyX", 88, "q2"), ("keyup", "x", "KeyX", 88, "q2")])
    expect_equal("x typed into q2", js("document.getElementById('q2').value"), "x")

    # The character replaces the selection at the caret.
    js("(function(){var e=document.getElementById('q2'); e.value='abcd'; e.focus(); e.setSelectionRange(1,3); return 0;})()")
    press({"selector": "css=#q2", "key": "X"})
    expect_equal("selection replaced", js("document.getElementById('q2').value"), "aXd")
    expect_equal("caret after inserted char", js("document.getElementById('q2').selectionStart"), 2)

    # A cancelled keydown suppresses every default action; keyup still fires.
    submits = js("window.submits")
    events = press({"selector": "css=#nokey", "key": "z"})
    expect_equal("cancelled keydown sequence", shape(events, "type", "key"), [("keydown", "z"), ("keyup", "z")])
    expect_equal("cancelled keydown typed nothing", js("document.getElementById('nokey').value"), "")
    press({"selector": "css=#nokey", "key": "Enter"})
    expect_equal("cancelled Enter did not submit", js("window.submits"), submits)
    press({"selector": "css=#nokey", "key": "Tab"})
    expect_equal("cancelled Tab kept focus", js("document.activeElement.id"), "nokey")

    # Printable keys never type into non-text inputs.
    press({"selector": "css=#cb", "key": "x"})
    expect_equal("checkbox value unchanged", js("document.getElementById('cb').value"), "on")
    expect_equal("checkbox not toggled", js("document.getElementById('cb').checked"), False)


def raw_rpc(socket_path: Path, method: str, params: dict, req_id: int, timeout: float) -> dict:
    """One framed JSON-RPC request; returns the whole response object."""
    request = {"jsonrpc": "2.0", "method": method, "params": params, "id": req_id}
    token = automation_auth(socket_path)
    if token is not None:
        request["auth"] = token
    payload = json.dumps(request).encode("utf-8")
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(timeout)
        sock.connect(str(socket_path))
        sock.sendall(struct.pack(">I", len(payload)) + payload)
        length = struct.unpack(">I", recv_exact(sock, 4))[0]
        response = json.loads(recv_exact(sock, length).decode("utf-8"))
    if response.get("id") != req_id:
        raise AssertionError(f"bad JSON-RPC envelope for {method}: {response}")
    return response


def rpc_error(socket_path: Path, method: str, params: dict, req_id: int, timeout: float) -> dict:
    response = raw_rpc(socket_path, method, params, req_id, timeout)
    if "error" not in response:
        raise AssertionError(f"{method} unexpectedly succeeded: {response}")
    return response["error"]


def run_select(socket_path: Path, t: float) -> None:
    ids = iter(range(400, 500))

    def rpc(method: str, params: dict):
        return call_rpc(socket_path, method, params, next(ids), t)

    def js(expression: str):
        return evaluate(socket_path, expression, next(ids), t)

    def expect_no_option(label: str, params: dict) -> None:
        error = rpc_error(socket_path, "dom.selectOption", dict(params, timeout_ms=300), next(ids), t)
        if error["code"] != -32001 or error.get("data", {}).get("reason") != "no_option":
            # Full evidence: code, reason, last_error, attempts.
            raise AssertionError(f"{label}: expected -32001/no_option, got {error}")

    # Native <select>: by value, label and index; input + change each time.
    expect_equal("select by value", rpc("dom.selectOption", {"selector": "css=#sel", "value": "b"}), {"value": "b"})
    expect_equal("select value after value", js("document.getElementById('sel').value"), "b")
    expect_equal("input/change after value", js("[window.selInputs, window.selChanges]"), [1, 1])
    expect_equal("select by label", rpc("dom.selectOption", {"selector": "css=#sel", "label": "Gamma"}), {"value": "c"})
    expect_equal("select by index", rpc("dom.selectOption", {"selector": "css=#sel", "index": 0}), {"value": "a"})
    expect_equal("input/change after three selections", js("[window.selInputs, window.selChanges]"), [3, 3])

    def expect_option_disabled(label: str, params: dict) -> None:
        error = rpc_error(socket_path, "dom.selectOption", dict(params, timeout_ms=300), next(ids), t)
        expect_equal(f"{label} code", error["code"], -32005)
        expect_equal(f"{label} reason", error["data"]["reason"], "option_disabled")

    # Missing options fail as element_not_found / no_option; an option that
    # exists but is disabled fails as element_disabled / option_disabled.
    expect_no_option("missing value", {"selector": "css=#sel", "value": "zzz"})
    expect_no_option("index out of range", {"selector": "css=#sel", "index": 9})
    expect_option_disabled("disabled option by value", {"selector": "css=#sel", "value": "d"})
    expect_option_disabled("disabled option by label", {"selector": "css=#sel", "label": "Delta"})
    expect_option_disabled("option in a disabled optgroup", {"selector": "css=#sel", "value": "e"})
    expect_equal("failed selections left the value alone", js("document.getElementById('sel').value"), "a")
    expect_equal("failed selections fired nothing", js("[window.selInputs, window.selChanges]"), [3, 3])

    # Duplicate values: the option chosen by label or index is the selected one.
    expect_equal("duplicate value by label", rpc("dom.selectOption", {"selector": "css=#dup", "label": "Second"}), {"value": "same"})
    expect_equal("second duplicate selected", js("document.getElementById('dup').selectedIndex"), 1)
    expect_equal("duplicate value by index", rpc("dom.selectOption", {"selector": "css=#dup", "index": 0}), {"value": "same"})
    expect_equal("first duplicate selected", js("document.getElementById('dup').selectedIndex"), 0)
    expect_equal("duplicate value by index 1", rpc("dom.selectOption", {"selector": "css=#dup", "index": 1}), {"value": "same"})
    expect_equal("second duplicate selected again", js("document.getElementById('dup').selectedIndex"), 1)

    # An ARIA option under an overlay fails like click does (obscured), unclicked.
    error = rpc_error(socket_path, "dom.selectOption", {"selector": "css=#covered", "value": "under", "timeout_ms": 300}, next(ids), t)
    if error["code"] not in (-32004, -32009):
        raise AssertionError(f"covered option: expected element_obscured/action_timeout, got {error}")
    expect_equal("covered option never clicked", js("window.coveredClicks"), 0)

    # A disabled <select> fails actionability and never changes.
    error = rpc_error(socket_path, "dom.selectOption", {"selector": "css=#sel-disabled", "value": "y", "timeout_ms": 300}, next(ids), t)
    if error["code"] not in (-32005, -32009):
        raise AssertionError(f"disabled select: expected element_disabled/action_timeout, got {error}")
    expect_equal("disabled select unchanged", js("[document.getElementById('sel-disabled').value, window.disabledSelChanges]"), ["x", 0])

    # ARIA combobox: opened with exactly one click, searched only in its own
    # popup (a decoy listbox with the same names is never clicked).
    expect_equal("combobox by label", rpc("dom.selectOption", {"selector": "css=#combo", "label": "Banana"}), {"value": "banana"})
    expect_equal("combobox handler saw the choice", js("window.comboValue"), "banana")
    expect_equal("combobox closed", js("document.getElementById('combo').getAttribute('aria-expanded')"), "false")
    expect_equal("combobox opened with one click", js("window.comboClicks"), 1)
    expect_equal("combobox by value", rpc("dom.selectOption", {"selector": "css=#combo", "value": "cherry"}), {"value": "cherry"})
    expect_equal("combobox by index", rpc("dom.selectOption", {"selector": "css=#combo", "index": 0}), {"value": "apple"})
    expect_equal("combobox third choice", js("window.comboValue"), "apple")
    expect_equal("decoy never clicked", js("window.decoyClicks"), 0)

    # Options slower than one script attempt: the engine retries and the
    # already-open combobox is not clicked shut.
    expect_equal("slow combobox", rpc("dom.selectOption", {"selector": "css=#slowcombo", "value": "late", "timeout_ms": 4000}), {"value": "late"})
    expect_equal("slow combobox choice", js("window.slowValue"), "late")
    expect_equal("slow combobox opened once", js("window.slowOpenClicks"), 1)
    expect_equal("decoy still never clicked", js("window.decoyClicks"), 0)

    # No ghost clicks: options that appear after the command timed out are
    # never clicked, because no script work outlives an attempt.
    # Deterministic precondition: the combobox starts outside the viewport
    # (selectOption must scroll it into view, as click-style checks need).
    js("(function(){var g=document.getElementById('ghostcombo'); window.scrollTo(0, g.getBoundingClientRect().top + window.scrollY + window.innerHeight + 100); return 0;})()")
    if js("(function(){var r=document.getElementById('ghostcombo').getBoundingClientRect(); return r.bottom > 0 && r.top < window.innerHeight;})()"):
        raise AssertionError("precondition: ghost combobox should start outside the viewport")
    expect_no_option("ghost combobox before its options render", {"selector": "css=#ghostcombo", "value": "boo"})
    time.sleep(1.5)
    expect_equal("ghost option never clicked", js("window.ghostValue"), None)
    expect_equal("ghost option rendered meanwhile", js("document.querySelectorAll('#ghost-list [role=option]').length"), 1)

    # ARIA listbox: by value and by index; aria-disabled options are refused.
    expect_equal("listbox by value", rpc("dom.selectOption", {"selector": "css=#lb", "value": "two"}), {"value": "two"})
    expect_equal("listbox selection", js("Array.from(document.querySelectorAll('#lb [role=option]')).map(o => o.getAttribute('aria-selected'))"), ["false", "true", "false"])
    expect_equal("listbox by index", rpc("dom.selectOption", {"selector": "css=#lb", "index": 0}), {"value": "one"})
    expect_option_disabled("aria-disabled option", {"selector": "css=#lb", "value": "three"})
    expect_equal("aria-disabled option not selected", js("document.querySelector('#lb [data-value=three]').getAttribute('aria-selected')"), "false")


def run_below_fold(socket_path: Path, t: float) -> None:
    ids = iter(range(600, 650))

    def js(expression: str):
        return evaluate(socket_path, expression, next(ids), t)

    def scrolled_away(element_id: str) -> None:
        js("window.scrollTo(0, 0)")
        if js(f"(function(){{var r=document.getElementById('{element_id}').getBoundingClientRect(); return r.top < window.innerHeight;}})()"):
            raise AssertionError(f"precondition: #{element_id} should start below the viewport")

    scrolled_away("below")
    expect_equal("click below the fold", call_rpc(socket_path, "dom.click", {"selector": "css=#below", "options": {"timeout_ms": 2000}}, next(ids), t), {"ok": True})
    expect_equal("below-the-fold click landed", js("window.belowClicks"), 1)
    scrolled_away("belowinput")
    expect_equal("fill below the fold", call_rpc(socket_path, "dom.fill", {"selector": "css=#belowinput", "value": "deep", "options": {"timeout_ms": 2000}}, next(ids), t), {"ok": True})
    expect_equal("below-the-fold fill landed", js("document.getElementById('belowinput').value"), "deep")
    scrolled_away("belowinput")
    expect_equal("type below the fold", call_rpc(socket_path, "dom.type", {"selector": "css=#belowinput", "text": "er", "options": {"timeout_ms": 2000}}, next(ids), t), {"ok": True})
    expect_equal("below-the-fold type landed", js("document.getElementById('belowinput').value"), "deeper")


def run_native(socket_path: Path, t: float) -> None:
    ids = iter(range(700, 800))
    native = {"input": "native"}

    def rpc(method: str, params: dict):
        return call_rpc(socket_path, method, params, next(ids), t)

    def js(expression: str):
        return evaluate(socket_path, expression, next(ids), t)

    def trusted(kind: str, target: str) -> list[bool]:
        return [entry.endswith(":true") for entry in js("window.trustLog") if entry.startswith(f"{kind}:{target}:")]

    # dom.click with real input: the page sees a trusted click.
    js("(window.trustLog = [], 0)")
    expect_equal("native click", rpc("dom.click", {"selector": "css=#nativebtn", "options": native}), {"ok": True})
    expect_equal("native click is trusted", trusted("click", "nativebtn"), [True])

    # N8: a humanized click moves the real pointer to the target first. The
    # page sees trusted mousemoves before the one trusted click, and the
    # moves end on the button.
    js("(window.trustLog = [], window.moveLog = [], 0)")
    expect_equal("humanized native click", rpc("dom.click", {"selector": "css=#nativebtn",
                 "options": dict(native, humanize=True)}), {"ok": True})
    log = js("window.trustLog")
    clicks = [i for i, entry in enumerate(log) if entry.startswith("click:")]
    moves = [i for i, entry in enumerate(log) if entry.startswith("mousemove:")]
    expect_equal("humanized click landed once, trusted, on the button", [log[i] for i in clicks], ["click:nativebtn:true"])
    if not moves or moves[0] > clicks[0]:
        raise AssertionError(f"humanized click: expected trusted mousemoves before the click, got {log}")
    if not all(log[i].endswith(":true") for i in moves):
        raise AssertionError(f"humanized click: untrusted mousemove in {log}")
    expect_equal("the last move before the click is on the button", log[clicks[0] - 1], "mousemove:nativebtn:true")
    # Rule 1 on the real chain: the earlier native click left the pointer on
    # this button, yet the path starts off the target and ends on it.
    cx, cy = js("(function(){var r=document.getElementById('nativebtn').getBoundingClientRect();"
                " return [r.left + r.width / 2, r.top + r.height / 2];})()")
    path = js("window.moveLog")
    if len(path) < 2 or not all(trusted for _, _, trusted in path):
        raise AssertionError(f"humanized click: expected a trusted path, got {path}")
    first, last = path[0], path[-1]
    if abs(first[0] - cx) <= 1 and abs(first[1] - cy) <= 1:
        raise AssertionError(f"humanized click: path started on the target {cx},{cy}: {path}")
    if abs(last[0] - cx) > 1 or abs(last[1] - cy) > 1:
        raise AssertionError(f"humanized click: path did not end on the target {cx},{cy}: {path}")

    # dom.type with real keys: trusted keydowns, text appended at the end.
    js("(function(){var i=document.getElementById('nativein'); i.value='pre'; i.setSelectionRange(0,0); window.trustLog=[]; return 0;})()")
    expect_equal("native type", rpc("dom.type", {"selector": "css=#nativein", "text": "Hi!", "options": native}), {"ok": True})
    expect_equal("native type appended", js("document.getElementById('nativein').value"), "preHi!")
    # Real typing presses Shift for 'H' and '!': Shift, H, i, Shift, !
    expect_equal("native keydowns are trusted", trusted("keydown", "nativein"), [True] * 5)

    # dom.press with a real key (Enter on a form input submits the form).
    submits = js("window.submits")
    expect_equal("native press", rpc("dom.press", {"selector": "css=#q", "key": "Enter", "options": native}), {"ok": True})
    expect_equal("native Enter submitted the form", js("window.submits"), submits + 1)
    expect_equal("native press without a default button", rpc("dom.press", {"selector": "css=#ns1", "key": "Enter", "options": native}), {"ok": True})
    expect_equal("native Enter without a default button does not submit", js("window.nosubmits"), 0)
    expect_equal("native press on the invalid-type form", rpc("dom.press", {"selector": "css=#bf1", "key": "Enter", "options": native}), {"ok": True})
    expect_equal("native Enter uses the normalized default button", js("window.bogusSubmits"), 2)

    # A Draft.js-style editor (cancels beforeinput, owns its model) receives
    # real typing: the browser's own trusted beforeinput reaches it.
    js("(window.draftModel = '', document.getElementById('draft').textContent = '', window.draftBeforeInputs = 0, window.draftTrustedBeforeInputs = 0, window.draftInputs = 0, 0)")
    expect_equal("native type into draft", rpc("dom.type", {"selector": "css=#draft", "text": "Real", "options": native}), {"ok": True})
    expect_equal("draft model after native type", js("window.draftModel"), "Real")
    expect_equal("draft got one trusted beforeinput per character",
                 js("[window.draftBeforeInputs, window.draftTrustedBeforeInputs]"), [4, 4])
    expect_equal("cancelled beforeinput means no input events", js("window.draftInputs"), 0)

    # Non-ASCII text through the real keymap path.
    js("(document.getElementById('nativein').value = '', 0)")
    expect_equal("native unicode type", rpc("dom.type", {"selector": "css=#nativein", "text": "café ✓", "options": native}), {"ok": True})
    expect_equal("native unicode text", js("document.getElementById('nativein').value"), "café ✓")

    # Invalid native key names are rejected before anything is sent.
    error = rpc_error(socket_path, "dom.press", {"selector": "css=#q", "key": "F1x", "options": native}, next(ids), t)
    expect_equal("invalid native key", error["code"], -32602)

    # A native type that runs out of time reports partial input, never retypes.
    js("(document.getElementById('nativein').value = '', 0)")
    error = rpc_error(socket_path, "dom.type", {"selector": "css=#nativein", "text": "y" * 3000,
                      "options": dict(native, timeout_ms=300)}, next(ids), t)
    if error.get("data", {}).get("reason") != "partial_input" or not error["data"].get("sent_chars"):
        raise AssertionError(f"partial native type: expected partial_input with sent_chars, got {error}")
    sent = error["data"]["sent_chars"]
    # The next native command drains the timed-out prefix before it acts.
    expect_equal("native type after a partial one", rpc("dom.type", {"selector": "css=#nativein", "text": "Z", "options": native}), {"ok": True})
    value = js("document.getElementById('nativein').value")
    if value != "y" * sent + "Z":
        raise AssertionError(f"prefix duplicated or lost: sent {sent}, value length {len(value)}, ends {value[-3:]!r}")


def run_shadow(socket_path: Path, t: float) -> None:
    """pierce=<css|role|text|testid selector> also searches open shadow roots
    (live: LinkedIn's invite dialog); every other engine is unchanged."""
    ids = iter(range(800, 900))

    def rpc(method: str, params: dict):
        return call_rpc(socket_path, method, params, next(ids), t)

    def js(expression: str):
        return evaluate(socket_path, expression, next(ids), t)

    def count(selector: str) -> int:
        return len(rpc("dom.query", {"selector": selector})["elements"])

    def log() -> list[str]:
        return js("window.shadowLog.splice(0)")

    # Only pierce= enters shadow roots, open ones only (nested ones too).
    expect_equal("css= stays out of shadow roots", count("css=#sbtn"), 0)
    expect_equal("role= stays out of shadow roots", count('role=button[name="Send without a note"]'), 0)
    expect_equal("pierce=css=", count("pierce=css=#sbtn"), 1)
    expect_equal("pierce=role= by text", rpc("dom.query", {"selector": 'pierce=role=button[name="Send without a note"]'})["elements"][0]["text"], "Send without a note")
    expect_equal("pierce=text= in a nested root", count("pierce=text=Nested"), 1)
    expect_equal("pierce= never enters a closed root", count("pierce=text=Closed"), 0)
    expect_equal("pierce= sees the light DOM too", count("pierce=css=#nativebtn"), 1)
    # A slotted light button is one element: found once, not again through
    # the slot.
    expect_equal("a slotted button counts once (css)", count("pierce=css=.slotted"), 1)
    expect_equal("a slotted button counts once (role)", count('pierce=role=button[name="Slotted"]'), 1)
    expect_equal("pierce=xpath= is malformed", rpc_error(socket_path, "dom.query", {"selector": "pierce=xpath=//button"}, next(ids), t)["data"]["reason"], "malformed_selector")

    # waitFor sees a button added to a shadow root later.
    js("(window.armShadow(300), 0)")
    expect_equal("waitFor in a shadow root", rpc("dom.waitFor", {"selector": "pierce=css=#slate", "state": "visible", "timeout_ms": 5000}), {"ok": True})

    # A synthetic click is composed (as a real one is): the host's listener,
    # outside the shadow tree, sees it.
    log()
    expect_equal("click in a shadow root", rpc("dom.click", {"selector": 'pierce=role=button[name="Send without a note"]'}), {"ok": True})
    expect_equal("the click reached the host", log(), ["click:sbtn:false"])
    expect_equal("native click in a shadow root", rpc("dom.click", {"selector": "pierce=css=#sbtn", "options": {"input": "native"}}), {"ok": True})
    expect_equal("the native click landed on the button", log(), ["click:sbtn:true"])
    expect_equal("fill in a shadow root", rpc("dom.fill", {"selector": "pierce=css=#snote", "value": "Hi"}), {"ok": True})
    expect_equal("type in a shadow root", rpc("dom.type", {"selector": "pierce=css=#snote", "text": "!"}), {"ok": True})
    expect_equal("textarea value", js("document.getElementById('shadowhost').shadowRoot.getElementById('snote').value"), "Hi!")
    expect_equal("fill and type events reached the host", log(), ["input:snote:false", "keydown:snote:false", "input:snote:false", "keyup:snote:false"])
    # Focus inside a shadow root: the document's activeElement is the host,
    # so the key goes to the focused element inside it, keyup included.
    expect_equal("press in a shadow root", rpc("dom.press", {"selector": "pierce=css=#snote", "key": "a"}), {"ok": True})
    expect_equal("press without a selector goes to the focused element inside the root", rpc("dom.press", {"key": "b"}), {"ok": True})
    expect_equal("pressed keys typed", js("document.getElementById('shadowhost').shadowRoot.getElementById('snote').value"), "Hi!ab")
    expect_equal("press events on the textarea", log(), ["keydown:snote:false", "input:snote:false", "keyup:snote:false"] * 2)
    # A button at the bottom of a scrolled box inside the root is scrolled
    # into view first, for a synthetic and a native click.
    hidden = "(function(){var r=document.getElementById('shadowhost').shadowRoot; var b=r.getElementById('sbox'); b.scrollTop=0;" \
        " return r.getElementById('sdeep').getBoundingClientRect().top > b.getBoundingClientRect().bottom;})()"
    expect_equal("precondition: the deep button starts out of its box's view", js(hidden), True)
    expect_equal("click on a scrolled-away shadow button", rpc("dom.click", {"selector": "pierce=css=#sdeep"}), {"ok": True})
    expect_equal("precondition again", js(hidden), True)
    expect_equal("native click on a scrolled-away shadow button", rpc("dom.click", {"selector": "pierce=css=#sdeep", "options": {"input": "native"}}), {"ok": True})
    expect_equal("both deep clicks landed", log(), ["click:sdeep:false", "click:sdeep:true"])

    # The checks still hold inside a shadow root.
    # (A check that never passes ends as action_timeout with data.last_error.)
    def last_error(error: dict):
        data = error.get("data") or {}
        return data.get("last_error") or data.get("reason") or error.get("message")

    error = rpc_error(socket_path, "dom.click", {"selector": "pierce=css=#scovered", "options": {"timeout_ms": 500}}, next(ids), t)
    expect_equal("covered in a shadow root", last_error(error), "element_obscured")
    error = rpc_error(socket_path, "dom.click", {"selector": 'pierce=role=button[name="Twin"]', "options": {"timeout_ms": 500}}, next(ids), t)
    expect_equal("two matches in a shadow root (strict)", last_error(error), "strict_multiple")
    expect_equal("nothing clicked by the failed clicks", log(), [])

    # A light button whose icon has its own shadow root still receives the
    # click (the hit test lands inside the icon's root).
    expect_equal("light button with a shadow icon", rpc("dom.click", {"selector": "css=#iconbtn"}), {"ok": True})
    expect_equal("icon button clicked", js("window.iconClicks"), 1)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default="zig-out/bin/zigBrowser")
    parser.add_argument("--fixture", default="tests/fixtures/automation/input.html")
    parser.add_argument("--timeout-sec", type=float, default=20.0)
    parser.add_argument("--prefer-xvfb", action="store_true")
    args = parser.parse_args()

    browser = Path(args.binary)
    fixture = Path(args.fixture)
    if not require_file(browser, "binary") or not require_file(fixture, "input fixture"):
        return SKIP_EXIT

    runner = detect_runner(args.prefer_xvfb)
    if runner is None:
        return SKIP_EXIT
    prefix, env, runner_note = runner
    eprint(f"runner={runner_note}")

    with tempfile.TemporaryDirectory(prefix="zb-automation-input-") as tmp:
        socket_path = Path(tmp) / "automation.sock"
        env = dict(env)
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        proc = subprocess.Popen(
            prefix + [str(browser), fixture.resolve().as_uri(), "--automation-api"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
        )
        assert proc.stdout is not None and proc.stderr is not None
        stdout_lines: list[str] = []
        stderr_lines: list[str] = []
        for stream, sink in ((proc.stdout, stdout_lines), (proc.stderr, stderr_lines)):
            threading.Thread(target=_read_lines, args=(stream, sink), daemon=True).start()

        scenario = "contenteditable"
        try:
            run_contenteditable(socket_path, args.timeout_sec)
            print("PASS\tcontenteditable type/fill")
            scenario = "press"
            run_press(socket_path, args.timeout_sec)
            print("PASS\tdom.press")
            scenario = "selectOption"
            run_select(socket_path, args.timeout_sec)
            print("PASS\tdom.selectOption")
            scenario = "below-the-fold"
            run_below_fold(socket_path, args.timeout_sec)
            print("PASS\tactions scroll targets into view")
            scenario = "native input"
            run_native(socket_path, args.timeout_sec)
            print("PASS\tnative (trusted) input over the socket")
            scenario = "shadow roots"
            run_shadow(socket_path, args.timeout_sec)
            print("PASS\tpierce= reaches open shadow roots")
        except Exception as exc:
            print(f"FAIL\t{scenario}")
            eprint(f"error={exc}")
            eprint(f"stderr={stderr_lines[-20:]}")
            terminate(proc)
            return 1

        terminate(proc)

    print("PASS\tautomation-input")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
