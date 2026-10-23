#!/usr/bin/env python3
"""bd zigBrowser-4pa.58 (plan R30-MS2, sub-slice MS2c.6): a popup's native close control must reach the automation
registry through the same destroy path as a page's window.close().

RED, UNREGISTERED. The green registers it beside test-load-failure-policy's binding oracle.

No Objective-C runtime exists on the Linux gate, so the binding is read from the real src/wkwebview_shim.m,
lexically, with the 4pa.55 oracle's lexer: comments are removed and string/character literals blanked, so a name in a
string or a comment never counts. It is the hostless tripwire. The runtime proof is the Mac e2e red 7f8b217
(tests/e2e/mac_ms2c_close_button_test.py, hook 14), held for a released two-Mac run.

Rows (each one bounded assertion; a failure names its row):
- N1 delegate: ZBWindowHost adopts NSWindowDelegate, and the method that allocates its NSWindow sets
  `_window.delegate = self;` exactly once. No other window delegate is assigned in the shim.
- N2 handler: -[ZBWindowHost windowWillClose:] exists, and its body is exactly `[self zbCloseFromWindowEvent];`.
- N3 one destroy path:
  - -webViewDidClose:'s body is exactly `(void)webView; [self zbCloseFromWindowEvent];`;
  - -zbCloseFromWindowEvent's body is REVIEWED_DESTROY, token for token: never the primary; deferred to the main
    queue; the registry check drops a double close; then -close and -[ZBAppHost removeWindow:];
  - only those two methods call it.
- N4 teardown: -[ZBWindowHost close] sets `self.window.delegate = nil;` exactly once, before it orders the window out,
  so a later AppKit close of the NSWindow can never message a torn-down host.

Run: python3 tests/e2e/mac_native_close_binding_test.py [shim path]
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from mac_load_exit_timer_binding_test import body, regions, strip, tokens, where  # noqa: E402  (the 4pa.55 lexer)

ROOT = Path(__file__).resolve().parents[2]
SHIM = ROOT / "src" / "wkwebview_shim.m"
HOST = "ZBWindowHost"
DESTROY = "zbCloseFromWindowEvent"

REVIEWED_DESTROY = """
  ZBAppHost *app = self.app;
  if (app == nil || self == app.mainWindow) return;
  ZBWindowHost *host = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (![app.windows containsObject:host]) return;
    [host close];
    [app removeWindow:host];
  });
"""


def check(text: str) -> list[str]:
    code = strip(text)
    regs = regions(code)
    problems: list[str] = []

    # N1: the protocol list, and the one delegate assignment in the method that allocates the NSWindow.
    iface = re.search(r"@interface\s+" + HOST + r"\s*:\s*NSObject\s*<([^>]*)>", code)
    if iface is None or "NSWindowDelegate" not in [p.strip() for p in iface.group(1).split(",")]:
        problems.append(f"N1 delegate: {HOST} does not adopt NSWindowDelegate")
    assigns = [m.start() for m in re.finditer(r"\b\w*[wW]indow\.delegate\s*=\s*self\s*;", code)]
    allocs = [m.start() for m in re.finditer(r"\[\[NSWindow\s+alloc\]", code)]
    alloc_methods = {where(regs, a) for a in allocs if where(regs, a)[0] == HOST}
    if len(assigns) != 1:
        problems.append(f"N1 delegate: want exactly one `window.delegate = self;`, found {len(assigns)}")
    elif where(regs, assigns[0]) not in alloc_methods or not code[assigns[0]:].startswith("_window.delegate"):
        problems.append(f"N1 delegate: the assignment is not `_window.delegate = self;` in the {HOST} method that "
                        f"allocates its NSWindow (it is in {where(regs, assigns[0])})")

    # N2: the native close handler.
    handler = body(code, regs, HOST, "windowWillClose:")
    if handler is None:
        problems.append(f"N2 handler: -[{HOST} windowWillClose:] is missing (or defined more than once)")
    elif tokens(handler) != tokens(f"(void)notification; [self {DESTROY}];") and \
            tokens(handler) != tokens(f"[self {DESTROY}];"):
        problems.append(f"N2 handler: -windowWillClose: must only call [self {DESTROY}]")

    # N3: one destroy path, shared with window.close().
    did_close = body(code, regs, HOST, "webViewDidClose:")
    if did_close is None or tokens(did_close) != tokens(f"(void)webView; [self {DESTROY}];"):
        problems.append(f"N3 one path: -webViewDidClose: must be `(void)webView; [self {DESTROY}];`")
    destroy = body(code, regs, HOST, DESTROY)
    if destroy is None or tokens(destroy) != tokens(REVIEWED_DESTROY):
        problems.append(f"N3 one path: -{DESTROY} is missing or is not the reviewed destroy path")
    callers = sorted({where(regs, m.start()) for m in re.finditer(r"\[\s*\w+\s+" + DESTROY + r"\s*\]", code)})
    if callers != sorted({(HOST, "webViewDidClose:"), (HOST, "windowWillClose:")}):
        problems.append(f"N3 one path: -{DESTROY} must be called from exactly webViewDidClose: and windowWillClose:, "
                        f"found {callers}")

    # N4: the teardown detaches the delegate before ordering the window out.
    close = body(code, regs, HOST, "close")
    if close is None:
        problems.append(f"N4 teardown: -[{HOST} close] is missing")
    else:
        detach = [m.start() for m in re.finditer(r"\bself\.window\.delegate\s*=\s*nil\s*;", close)]
        order_out = close.find("[self.window orderOut:nil]")
        if len(detach) != 1 or order_out < 0 or detach[0] > order_out:
            problems.append("N4 teardown: -close must set self.window.delegate = nil exactly once, before orderOut:")
    return problems


def main(argv: list[str]) -> int:
    shim = Path(argv[1]) if len(argv) > 1 else SHIM
    problems = check(shim.read_text())
    for p in problems:
        print(f"FAIL {p}")
    if problems:
        print(f"FAIL mac-native-close-binding {len(problems)} problem(s) in {shim}")
        return 1
    print("PASS mac-native-close-binding N1 delegate, N2 handler, N3 one destroy path, N4 teardown")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
