#!/usr/bin/env python3
"""bd zigBrowser-4pa.57 (plan R30-MS2, MS2b.2): dialog.get and page.list must name a window with the
same stable id, and dialog.respond must resolve that id through the same stable-id lookup.

RED, UNREGISTERED. The green registers this oracle beside the 4pa.55/4pa.58/4pa.56 shim-binding
oracles. The real runtime red is tests/e2e/mac_ms2b_dialog_popup_id_test.py: it opens windows 1, 2 and
3, closes 2, opens a confirm in 3, and requires dialog.get/list/respond to keep naming window 3.

No Objective-C runtime exists on the Linux gate, so this hostless oracle reads the real
src/wkwebview_shim.m with the 4pa.55 lexer for function boundaries. Its key/value lexer removes comments
but preserves Objective-C string literals, so it can bind the actual @"window" and @"id" dictionary
members rather than accepting a name in a comment, another string, or another dictionary member. This
is a tripwire; only a released two-Mac run can provide the runtime proof.

Rows (each failure names its row):
- D1 dialog listing: zb_automation_list_dialogs has exactly one @"window" member, whose complete value
  is @(h.windowId). The extracted expression is also evaluated for the runtime red's post-close state
  (registry positions [window 1, window 3], dialog on the second remaining host): it must emit 3, not 2.
- D2 stable lookup: zb_auto_window_for_id resolves a nonzero id only with
  `if (h.windowId == win) return h;` while iterating app.windows; it does not use array indexing.
- D3 page.list identity: zb_publish_window_snapshot has exactly one @"id" member and its complete value
  is @(h.windowId), so page.list and dialog.get expose the same identity.
- D4 response identity: zb_automation_respond_dialog resolves its `win` parameter exactly once through
  zb_auto_window_for_id(win), then responds on that returned host.

Run: python3 tests/e2e/mac_dialog_window_id_binding_test.py [shim path]
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from mac_load_exit_timer_binding_test import match_brace, strip, tokens  # noqa: E402 (the 4pa.55 lexer)

ROOT = Path(__file__).resolve().parents[2]
SHIM = ROOT / "src" / "wkwebview_shim.m"

SIGNATURES = {
    "zb_automation_list_dialogs": r"^int\s+zb_automation_list_dialogs\s*\([^)]*\)\s*\{",
    "zb_auto_window_for_id": r"^static\s+ZBWindowHost\s*\*\s*zb_auto_window_for_id\s*\([^)]*\)\s*\{",
    "zb_publish_window_snapshot": r"^static\s+void\s+zb_publish_window_snapshot\s*\([^)]*\)\s*\{",
    "zb_automation_respond_dialog": r"^int\s+zb_automation_respond_dialog\s*\([^)]*\)\s*\{",
}

REVIEWED_LOOKUP = """
  ZBAppHost *app = g_active_app;
  if (app == nil) return nil;
  if (win == 0) return app.mainWindow;
  for (ZBWindowHost *h in app.windows) {
    if (h.windowId == win) return h;
  }
  return nil;
"""


def function_body(text: str, name: str) -> str | None:
    """Return one real C function body; comments/literals cannot create a false signature or brace."""
    code = strip(text)
    hits = list(re.finditer(SIGNATURES[name], code, re.M))
    if len(hits) != 1:
        return None
    open_at = hits[0].end() - 1
    return text[open_at + 1:match_brace(code, open_at)]


def comments_blank(text: str) -> str:
    """Blank comments while preserving offsets and literal bytes (including comment markers in literals)."""
    out = list(text)
    i = 0
    while i < len(text):
        if text.startswith("//", i):
            end = text.find("\n", i)
            end = len(text) if end < 0 else end
            for pos in range(i, end):
                out[pos] = " "
            i = end
        elif text.startswith("/*", i):
            end = text.find("*/", i + 2)
            end = len(text) if end < 0 else end + 2
            for pos in range(i, end):
                if out[pos] != "\n":
                    out[pos] = " "
            i = end
        elif text[i] in "\"'":
            quote = text[i]
            i += 1
            while i < len(text):
                if text[i] == "\\":
                    i += 2
                elif text[i] == quote:
                    i += 1
                    break
                else:
                    i += 1
        else:
            i += 1
    return "".join(out)


def objc_tokens(text: str) -> list[str]:
    """Small Objective-C lexer: strings are atomic; comments and whitespace are absent."""
    code = comments_blank(text)
    pattern = r'@"(?:\\.|[^"\\])*"|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|[A-Za-z_]\w*|\d+|==|!=|\+\+|--|->|\S'
    return re.findall(pattern, code)


def member_values(body: str, key: str) -> list[list[str]]:
    """Return each complete top-level value expression following an Objective-C string-literal key."""
    toks = objc_tokens(body)
    values: list[list[str]] = []
    for pos, tok in enumerate(toks):
        if tok != f'@"{key}"' or pos + 1 >= len(toks) or toks[pos + 1] != ":":
            continue
        value: list[str] = []
        stack: list[str] = []
        pairs = {"(": ")", "[": "]", "{": "}"}
        for item in toks[pos + 2:]:
            if item == "," and not stack:
                break
            if item in pairs:
                stack.append(pairs[item])
            elif stack and item == stack[-1]:
                stack.pop()
            value.append(item)
        values.append(value)
    return values


def simulated_listed_id(expr: list[str]) -> int | None:
    """Evaluate only the two concrete identities relevant to the causal post-close scenario."""
    if expr == ["@", "(", "h", ".", "windowId", ")"]:
        return 3  # remaining host at registry index 1 is stable window 3
    if expr == ["@", "(", "idx", "+", "1", ")"]:
        return 2  # the defect: registry position is not the stable id after window 2 closes
    return None


def check(text: str) -> list[str]:
    problems: list[str] = []
    bodies = {name: function_body(text, name) for name in SIGNATURES}
    for name, value in bodies.items():
        if value is None:
            problems.append(f"census: {name} is missing or defined more than once")
    if problems:
        return problems

    listed_values = member_values(bodies["zb_automation_list_dialogs"], "window")
    stable_value = ["@", "(", "h", ".", "windowId", ")"]
    if len(listed_values) != 1:
        problems.append(f'D1 dialog listing: want exactly one @"window" member, found {len(listed_values)}')
    else:
        observed = simulated_listed_id(listed_values[0])
        if observed != 3 or listed_values[0] != stable_value:
            problems.append("D1 dialog listing: after windows 1,2,3 open and window 2 closes, the dialog on the "
                            f"second remaining host emits {observed!r}, want its stable id 3 "
                            f"(value tokens {listed_values[0]!r}, want {stable_value!r})")

    lookup = tokens(strip(bodies["zb_auto_window_for_id"]))
    if lookup != tokens(strip(REVIEWED_LOOKUP)):
        problems.append("D2 stable lookup: zb_auto_window_for_id differs from the reviewed stable-id lookup "
                        "(0 aliases the primary; otherwise iterate app.windows and match h.windowId == win)")

    page_values = member_values(bodies["zb_publish_window_snapshot"], "id")
    if len(page_values) != 1 or page_values[0] != stable_value:
        problems.append(f'D3 page.list identity: want one @"id": @(h.windowId), found {page_values!r}')

    respond = objc_tokens(bodies["zb_automation_respond_dialog"])
    resolve = ["ZBWindowHost", "*", "host", "=", "zb_auto_window_for_id", "(", "win", ")", ";"]
    answer = ["[", "host", "zbRespondDialogAccept", ":"]
    resolve_at = next((i for i in range(len(respond)) if respond[i:i + len(resolve)] == resolve), None)
    answer_at = next((i for i in range(len(respond)) if respond[i:i + len(answer)] == answer), None)
    host_assignments = sum(respond[i:i + 2] == ["host", "="] for i in range(len(respond) - 1))
    if (respond.count("zb_auto_window_for_id") != 1 or respond.count("zbRespondDialogAccept") != 1 or
            host_assignments != 1 or resolve_at is None or answer_at is None or resolve_at > answer_at):
        problems.append("D4 response identity: zb_automation_respond_dialog must resolve win exactly once through "
                        "zb_auto_window_for_id(win), then answer that returned host")
    return problems


def main(argv: list[str]) -> int:
    shim = Path(argv[1]) if len(argv) > 1 else SHIM
    problems = check(shim.read_text())
    for problem in problems:
        print(f"FAIL {problem}")
    if problems:
        print(f"FAIL mac-dialog-window-id-binding {len(problems)} problem(s) in {shim}")
        return 1
    print("PASS mac-dialog-window-id-binding D1 dialog listing, D2 stable lookup, D3 page.list identity, D4 response identity")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
