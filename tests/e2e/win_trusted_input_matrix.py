#!/usr/bin/env python3
r"""WS2b.1 spike driver (Windows plan rev 2.21; UNREGISTERED until the WS2b.1 green, then step
windows-trusted-input-matrix-live): does native input through WebView2's DevTools protocol reach the page as
TRUSTED events?

Builds and runs tests/windows/ws2b1_input_spike.c on the Win11 VM through
`tests/windows/build-on-windows.sh ws2b1-input-spike-win` (tests/windows/spike_driver.py: host identity marker,
clean build of ZB_BUILD_COMMIT, an `ok` line required for every row below, `ASSERTS <n>`). The spike links the
real shim and calls only the production ABI (zb_native_*, zb_automation_eval_json, zb_automation_set_script with
the real automation.js, zb_app_run).

Plan assertion: ack["isTrusted"] is True per row. If CDP input is not trusted, WS2b stops at this spike and the
orchestrator brings the result to the user (no silent SendInput fallback).
Mutant: dispatch through a page-side synthetic dispatchEvent -> isTrusted is false and the trusted rows are red.

Under ZB_WIN_GATE=1 a missing host or marker exits 1 ("no Windows host configured"); standalone it exits 77.
A host run needs NavyCanyon's exact-commit approval and the orchestrator's release.

Run:  ZB_WIN_GATE=1 ZB_WIN11_HOST=127.0.0.1 ZB_WIN11_MARKER=<nonce> ZB_BUILD_COMMIT=<sha> \
      python3 -I tests/e2e/win_trusted_input_matrix.py
"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "windows"))  # `python3 -I` drops it

from spike_driver import run_spike  # noqa: E402

STEP = "ws2b1-input-spike-win"
REQUIRED = (
    "the input fixture loads",
    "click: zb_native_click returns OK",
    "click: one trusted click on the button",
    "click: the move before it is trusted, on the button",
    "pointer: zb_native_pointer reports the click point",
    "focus: a trusted click focuses the input",
    "focus: the focus event is trusted",
    "key: zb_native_key returns OK with one release",
    "key: the key types into the focused input",
    "key: its keydown is trusted",
    "text: zb_native_text returns OK with all 3 characters",
    "text: the input holds exactly the text",
    "text: every keydown is trusted",
    "contenteditable: zb_native_text returns OK",
    "contenteditable: the editor's model got the text",
    "contenteditable: one trusted beforeinput per character",
    "contenteditable: the cancelled beforeinput is honored (no browser insert, no input event)",
    "partial typing: a deadline mid-text times out after some characters",
    "partial typing: the page holds exactly the characters reported, none after the return",
    "deadline: a held native click times out at its deadline",
    "deadline: an abandoned native click is never dispatched",
    "guard: a stale document token is refused (DOC_CHANGED)",
    "guard: nothing was sent to the page",
    "guard: the document has an automation token",
    "navigation during input: guarded typing stops with DOC_CHANGED",
    "navigation during input: the new document loads",
    "navigation during input: the new document gets no keystroke",
    "the scroll fixture loads",
    "scroll: zb_native_scroll returns OK",
    "scroll: the wheel events are trusted",
    "scroll: the page scrolled",
    "move: zb_native_move returns OK",
    "move: a trusted mousemove reaches the hover target",
    "move: every hover event is trusted",
    "move: zb_native_pointer reports the move point",
    "closing the window ends zb_app_run",
    "zb_app_run returns success",
)

if __name__ == "__main__":
    raise SystemExit(run_spike(STEP, REQUIRED, "ws2b1-trusted-input-matrix"))
