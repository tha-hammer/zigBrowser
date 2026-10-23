#!/usr/bin/env python3
"""bd zigBrowser-4pa.56 (plan R30-MS3, MS3.3): every macOS cookie call releases its waiter into the deadline-bound
INFLIGHT state as soon as its WKHTTPCookieStore call is issued, so the caller's timeout_ms bounds the round trip.

Registered (step test-cookie-inflight-binding, beside test-load-failure-policy's binding oracle; red debfc606,
fix-forward 0907b353 for SilverRidge 72424397): K3 is bound to the dispatched block and to the exact guard shape, not
to text order.

In the shim's job state machine, zb_job_wait has no deadline while a job is DISPATCHING. zb_job_inflight moves the job
to INFLIGHT, where timeout_ms applies. The other async ops call it right after their submit; the three cookie ops
never do, so a WebKit store that never answers hangs the server thread.

No Objective-C runtime exists on the Linux gate, so the binding is read from the real src/wkwebview_shim.m,
lexically, with the 4pa.55 oracle's lexer (comments removed, literals blanked). It is the hostless tripwire. The
runtime proof is the Mac e2e red tests/e2e/mac_cookie_timeout_test.py (hook 15), held for a released two-Mac run.

Rows, one per operation (zb_cookies_get_all, zb_cookies_add, zb_cookies_delete):
- K1 one release: zb_job_inflight(job) appears exactly once in the function;
- K2 right after the submit: it is the statement that immediately follows the WKHTTPCookieStore submit (getAllCookies:
  or setCookie:completionHandler:), not inside the store's completion handler;
- K3 inside the guarded main-queue block:
  - the function has exactly one `dispatch_async(dispatch_get_main_queue(), ^{ ... });` block;
  - the submit and the release are inside it;
  - inside it is exactly one guard of the shape `if (!zb_job_claim_dispatch(job)) { ... return; }`, before the
    submit;
  - zb_job_claim_dispatch appears nowhere else in the function.
  So an inverted guard, a bare claim, a claim outside the block, or a plain local block in place of the dispatch is
  red.

Run: python3 tests/e2e/mac_cookie_inflight_binding_test.py [shim path]   (registered: zig build test-cookie-inflight-binding)
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from mac_load_exit_timer_binding_test import match_brace, strip, tokens  # noqa: E402  (the 4pa.55 lexer)

ROOT = Path(__file__).resolve().parents[2]
SHIM = ROOT / "src" / "wkwebview_shim.m"
OPS = {"zb_cookies_get_all": "getAllCookies", "zb_cookies_add": "setCookie", "zb_cookies_delete": "getAllCookies"}
RELEASE = tokens("zb_job_inflight(job);")


def function_body(code: str, name: str) -> str | None:
    hits = [m for m in re.finditer(r"^int\s+" + name + r"\s*\([^)]*\)\s*\{", code, re.M)]
    if len(hits) != 1:
        return None
    open_at = hits[0].end() - 1
    return code[open_at + 1:match_brace(code, open_at)]


def match_bracket(code: str, open_at: int) -> int:
    depth = 0
    for k in range(open_at, len(code)):
        if code[k] == "[":
            depth += 1
        elif code[k] == "]":
            depth -= 1
            if depth == 0:
                return k
    raise ValueError(f"unbalanced bracket from offset {open_at}")


def check_op(code: str, name: str, submit: str) -> list[str]:
    fn = function_body(code, name)
    if fn is None:
        return [f"{name}: the function is missing or defined more than once"]
    problems = []
    releases = [m.start() for m in re.finditer(r"\bzb_job_inflight\s*\(", fn)]
    if len(releases) != 1:
        problems.append(f"K1 {name}: want exactly one zb_job_inflight(job), found {len(releases)}")
    send = re.search(r"\[\s*store\s+" + submit + r"\b", fn)
    if send is None:
        return problems + [f"K2 {name}: no [store {submit}...] submit found"]
    end = match_bracket(fn, send.start())
    after = tokens(fn[end + 1:])
    if after[:1] != [";"] or after[1:1 + len(RELEASE)] != RELEASE:
        problems.append(f"K2 {name}: the statement right after [store {submit}...] must be zb_job_inflight(job);")
    blocks = list(re.finditer(r"\bdispatch_async\s*\(\s*dispatch_get_main_queue\s*\(\s*\)\s*,\s*\^\s*\{", fn))
    if len(blocks) != 1:
        return problems + [f"K3 {name}: want exactly one dispatch_async(dispatch_get_main_queue(), ^{{...}}) block, "
                           f"found {len(blocks)}"]
    b_open = blocks[0].end() - 1
    b_close = match_brace(fn, b_open)
    block = fn[b_open + 1:b_close]
    guards = list(re.finditer(r"\bif\s*\(\s*!\s*zb_job_claim_dispatch\s*\(\s*job\s*\)\s*\)\s*\{[^{}]*\breturn\s*;\s*\}", block))
    claims = len(re.findall(r"\bzb_job_claim_dispatch\s*\(", fn))
    inside = b_open < send.start() < b_close and all(b_open < r < b_close for r in releases)
    if not inside:
        problems.append(f"K3 {name}: the submit and the release must be inside the main-queue block")
    if len(guards) != 1 or claims != 1:
        problems.append(f"K3 {name}: want exactly one `if (!zb_job_claim_dispatch(job)) {{ ... return; }}` in the block "
                        f"and no other claim (guards {len(guards)}, claims {claims})")
    elif b_open + 1 + guards[0].end() > send.start():
        problems.append(f"K3 {name}: the claim guard must come before the submit")
    return problems


def check(text: str) -> list[str]:
    code = strip(text)
    problems: list[str] = []
    for name, submit in OPS.items():
        problems += check_op(code, name, submit)
    return problems


def main(argv: list[str]) -> int:
    shim = Path(argv[1]) if len(argv) > 1 else SHIM
    problems = check(shim.read_text())
    for p in problems:
        print(f"FAIL {p}")
    if problems:
        print(f"FAIL mac-cookie-inflight-binding {len(problems)} problem(s) in {shim}")
        return 1
    print("PASS mac-cookie-inflight-binding K1-K3 for zb_cookies_get_all, zb_cookies_add, zb_cookies_delete")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
