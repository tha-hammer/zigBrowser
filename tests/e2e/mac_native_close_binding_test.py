#!/usr/bin/env python3
"""bd zigBrowser-4pa.58 (plan R30-MS2, sub-slice MS2c.6): a popup's native close control must reach the automation
registry through the same destroy path as a page's window.close().

RED, UNREGISTERED, fix-forward for SilverRidge c6125315: N1 is order-exact, and the primary's native close matches
Linux (owner default R30.3 #3): the shared destroy path removes a primary too, while a page's window.close() and
automation page.close still ignore or refuse it (N3, N5). The green registers it beside test-load-failure-policy's
binding oracle.

No Objective-C runtime exists on the Linux gate, so the binding is read from the real src/wkwebview_shim.m,
lexically, with the 4pa.55 oracle's lexer: comments are removed and string/character literals blanked, so a name in a
string or a comment never counts. It is the hostless tripwire. The runtime proof is the Mac e2e red 7f8b217
(tests/e2e/mac_ms2c_close_button_test.py, hook 14), held for a released two-Mac run.

Rows (each one bounded assertion; a failure names its row):
- N1 delegate:
  - ZBWindowHost adopts NSWindowDelegate;
  - in the method that allocates its NSWindow, `_window.delegate = self;` comes AFTER the allocating
    `_window = [[NSWindow alloc] ...];` statement and before that method's final `return self;`, with no other
    assignment to `_window` or to a window delegate in between (an assignment before the allocation is sent to nil);
  - census: the shim's only window-delegate bindings are that one and N4's `self.window.delegate = nil;` in -close.
- N2 handler: -[ZBWindowHost windowWillClose:] exists, and its body only calls [self zbCloseFromWindowEvent].
- N3 one destroy path:
  - -webViewDidClose:'s body is REVIEWED_SCRIPT_CLOSE: a page's window.close() is ignored for the primary, else the
    shared path;
  - -zbCloseFromWindowEvent's body is REVIEWED_DESTROY, token for token: deferred to the main queue; the registry
    check drops a double close; then -close and -[ZBAppHost removeWindow:]. It removes a primary too, and
    removeWindow: exits after the last window;
  - only those two methods call it.
- N4 teardown: -[ZBWindowHost close] sets `self.window.delegate = nil;` exactly once, before it orders the window out,
  so a later AppKit close of the NSWindow can never message a torn-down host.
- N5 the automation contract: zb_automation_close_window still refuses the primary (NO_WINDOW) before it closes.

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

REVIEWED_SCRIPT_CLOSE = """
  (void)webView;
  if (self.app == nil || self == self.app.mainWindow) return;
  [self zbCloseFromWindowEvent];
"""

REVIEWED_DESTROY = """
  ZBAppHost *app = self.app;
  if (app == nil) return;
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
    bindings = [(m.start(), m.group(0)) for m in
                re.finditer(r"\b(?:_window|self\.window|\w+\.window)\.delegate\s*=\s*\w+\s*;|\bsetDelegate\s*:", code)]
    allocs = [m for m in re.finditer(r"\b_window\s*=\s*\[\[NSWindow\s+alloc\]", code) if where(regs, m.start())[0] == HOST]
    if len(allocs) != 1:
        problems.append(f"N1 delegate: want one {HOST} `_window = [[NSWindow alloc] ...]`, found {len(allocs)}")
    else:
        method = where(regs, allocs[0].start())
        start, end = next((s, e) for s, e, c, m in regs if (c, m) == method)
        alloc_end = code.index(";", allocs[0].end())
        final_return = code.rfind("return self;", start, end)
        binds = [b for b in bindings if b[1].replace(" ", "") == "_window.delegate=self;"]
        if len(binds) != 1 or not (alloc_end < binds[0][0] < final_return):
            problems.append("N1 delegate: want exactly one `_window.delegate = self;` after the allocating statement "
                            "and before the initializer's final `return self;`")
        else:
            between = code[alloc_end + 1:binds[0][0]] + code[binds[0][0] + len(binds[0][1]):final_return]
            if re.search(r"\b_window\s*=|\.delegate\s*=|setDelegate\s*:", between):
                problems.append("N1 delegate: another assignment to _window or a window delegate sits between the "
                                "allocation and `return self;`")
    allowed = {"_window.delegate=self;", "self.window.delegate=nil;"}
    extra = [b for _, b in bindings if b.replace(" ", "") not in allowed]
    if extra or len(bindings) != 2:
        problems.append(f"N1 census: the only window-delegate bindings may be `_window.delegate = self;` and "
                        f"`self.window.delegate = nil;`, found {[b for _, b in bindings]}")

    # N2: the native close handler.
    handler = body(code, regs, HOST, "windowWillClose:")
    if handler is None:
        problems.append(f"N2 handler: -[{HOST} windowWillClose:] is missing (or defined more than once)")
    elif tokens(handler) != tokens(f"(void)notification; [self {DESTROY}];") and \
            tokens(handler) != tokens(f"[self {DESTROY}];"):
        problems.append(f"N2 handler: -windowWillClose: must only call [self {DESTROY}]")

    # N3: one destroy path, shared with window.close().
    did_close = body(code, regs, HOST, "webViewDidClose:")
    if did_close is None or tokens(did_close) != tokens(REVIEWED_SCRIPT_CLOSE):
        problems.append("N3 one path: -webViewDidClose: is not the reviewed script close (ignore the primary, else the "
                        "shared path)")
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

    # N5: automation page.close still refuses the primary before it closes anything.
    fn = re.search(r"^int\s+zb_automation_close_window\s*\([^)]*\)\s*\{", code, re.M)
    if fn is None:
        problems.append("N5 automation: zb_automation_close_window is missing")
    else:
        from mac_load_exit_timer_binding_test import match_brace
        text = code[fn.end():match_brace(code, fn.end() - 1)]
        toks = tokens(text)
        refuse = tokens("else if (host == app.mainWindow) { code = ZB_AUTO_ERR_NO_WINDOW;")
        at = next((i for i in range(len(toks)) if toks[i:i + len(refuse)] == refuse), None)
        close_at = next((i for i in range(len(toks)) if toks[i:i + 5] == tokens("[host close];")), None)
        if at is None or close_at is None or at > close_at:
            problems.append("N5 automation: page.close must refuse the primary (NO_WINDOW) before [host close]")
    return problems


def main(argv: list[str]) -> int:
    shim = Path(argv[1]) if len(argv) > 1 else SHIM
    problems = check(shim.read_text())
    for p in problems:
        print(f"FAIL {p}")
    if problems:
        print(f"FAIL mac-native-close-binding {len(problems)} problem(s) in {shim}")
        return 1
    print("PASS mac-native-close-binding N1 delegate, N2 handler, N3 one destroy path, N4 teardown, N5 automation")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
