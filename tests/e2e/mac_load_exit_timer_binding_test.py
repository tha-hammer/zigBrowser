#!/usr/bin/env python3
"""bd zigBrowser-4pa.55 (SilverRidge 58c6543 items 1-2): every macOS browser-host 15 s exit timer goes through the
portable decision, and its expiry quits only when that decision says so.

src/load_failure_policy.zig decides (tests/load_failure_policy_test.zig drives it); this oracle binds the AppKit side
of src/wkwebview_shim.m to it. No Objective-C runtime exists on the Linux gate, so the binding is read from the real
shim, lexically: comments removed and the contents of string and character literals blanked, so a name inside a
string or a comment never counts. It is the hostless tripwire; the runtime proof is a released two-Mac run.

Scope: every class and C function of the shim except ZBSnapshotRunner, the separate --screenshot runner, whose own
timer ends a one-shot capture and is not a browser window's.

Rows (each one bounded assertion; a failure names its row):
- B1 census: outside ZBSnapshotRunner, ZB_NAVIGATION_TIMEOUT_SECONDS appears only in its one file-scope definition
  and once in -[ZBWindowHost armLoadExitTimer]; @selector(onNavigationTimeout:) appears only there, once; and the
  only non-nil assignment to a timeoutTimer is there, once. So no other path schedules the exit timer.
- B2 guard: -armLoadExitTimer's body is REVIEWED_ARM token for token: it clears the old timer and schedules a new
  one only when zb_load_exit_timer_armed([self isPrimaryWindow], self.app.primaryFinished, self.recoveryLoad).
- B3 initiators: -loadURI: and -reloadBypassingCache: (the two browser-host load initiators) each call
  [self armLoadExitTimer] exactly once, before they start the load, and nothing else calls it.
- B4 expiry: -onNavigationTimeout:'s body is REVIEWED_TIMEOUT token for token: it records the timed-out load
  (LOAD_FAIL) and calls requestExit:ZB_EXIT_TIMEOUT only when zb_load_failure_action(...) is ZB_LOADFAIL_EXIT;
  outside ZBSnapshotRunner, ZB_EXIT_TIMEOUT appears nowhere else.

tests/e2e/load_failure_policy_mutant_selftest.py makes each row red with a production mutant of the shim.
Run: python3 tests/e2e/mac_load_exit_timer_binding_test.py [shim path]   (registered: zig build test-load-failure-policy)
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SHIM = ROOT / "src" / "wkwebview_shim.m"
EXCLUDED_CLASS = "ZBSnapshotRunner"
HOST_CLASS = "ZBWindowHost"
HELPER = "armLoadExitTimer"
INITIATORS = ("loadURI:", "reloadBypassingCache:")

REVIEWED_ARM = """
  [self.timeoutTimer invalidate];
  self.timeoutTimer = nil;
  if (zb_load_exit_timer_armed([self isPrimaryWindow], self.app.primaryFinished, self.recoveryLoad)) {
    self.timeoutTimer = [NSTimer scheduledTimerWithTimeInterval:ZB_NAVIGATION_TIMEOUT_SECONDS
                                                         target:self
                                                       selector:@selector(onNavigationTimeout:)
                                                       userInfo:nil
                                                        repeats:NO];
  }
"""

REVIEWED_TIMEOUT = """
  (void)timer;
  if (self.finishedOrFailed) {
    return;
  }
  self.finishedOrFailed = YES;
  NSString *uri = self.webView.URL.absoluteString ?: self.requestedURI ?: @"";
  [self.webView stopLoading:nil];
  [self.app emitLoadFailForURI:uri code:NSURLErrorTimedOut];
  int action = zb_load_failure_action(0, [self isPrimaryWindow], self.app.primaryFinished, self.recoveryLoad);
  self.recoveryLoad = NO;
  if (action == ZB_LOADFAIL_EXIT) [self.app requestExit:ZB_EXIT_TIMEOUT];
"""


def strip(text: str) -> str:
    """Comments become spaces and literal contents are blanked; every offset and newline is kept."""
    out = list(text)
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            for k in range(i, j):
                out[k] = " "
            i = j
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            for k in range(i, j):
                if out[k] != "\n":
                    out[k] = " "
            i = j
        elif c in "\"'":
            j = i + 1
            while j < n and text[j] != c and text[j] != "\n":
                j += 2 if text[j] == "\\" else 1
            for k in range(i + 1, min(j, n)):
                out[k] = " "
            i = j + 1
        else:
            i += 1
    return "".join(out)


def tokens(code: str) -> list[str]:
    return re.findall(r"[A-Za-z_]\w*|\d+(?:\.\d+)?|\?:|==|->|\S", code)


def match_brace(code: str, open_at: int) -> int:
    depth = 0
    for k in range(open_at, len(code)):
        if code[k] == "{":
            depth += 1
        elif code[k] == "}":
            depth -= 1
            if depth == 0:
                return k
    raise ValueError(f"unbalanced brace from offset {open_at}")


def selector(header: str) -> str:
    """`- (void)foo:(T)a bar:(U)b` -> `foo:bar:`; `- (void)foo` -> `foo`."""
    rest = re.sub(r"^[-+]\s*\([^)]*\)\s*", "", header.strip())
    parts = re.findall(r"(\w+)\s*:", rest)
    return "".join(p + ":" for p in parts) if parts else re.match(r"\w+", rest).group(0)


def regions(code: str):
    """[(start, end, class, method)] for every method body of every @implementation; class/method '-' elsewhere."""
    found = []
    for impl in re.finditer(r"@implementation\s+(\w+)", code):
        end = code.find("@end", impl.end())
        k = impl.end()
        while True:
            m = re.compile(r"^[-+]\s*\(", re.M).search(code, k, end)
            if m is None:
                break
            brace = code.find("{", m.start(), end)
            close = match_brace(code, brace)
            found.append((brace + 1, close, impl.group(1), selector(code[m.start():brace])))
            k = close + 1
    return found


def where(regs, offset):
    for start, end, cls, meth in regs:
        if start <= offset < end:
            return cls, meth
    return "-", "-"


def body(code, regs, cls, meth):
    hits = [code[s:e] for s, e, c, m in regs if c == cls and m == meth]
    return hits[0] if len(hits) == 1 else None


def check(text: str) -> list[str]:
    code = strip(text)
    regs = regions(code)
    problems: list[str] = []

    definition = re.compile(r"^static const NSTimeInterval (ZB_NAVIGATION_TIMEOUT_SECONDS) = 15\.0;", re.M)
    def_at = [m.start(1) for m in definition.finditer(code)]
    if len(def_at) != 1:
        problems.append(f"B1 census: want one file-scope ZB_NAVIGATION_TIMEOUT_SECONDS definition, found {len(def_at)}")

    def census(pattern, label):
        """Occurrences outside ZBSnapshotRunner and the definition: (inside the helper, [locations elsewhere])."""
        inside, elsewhere = 0, []
        for m in re.finditer(pattern, code):
            cls, meth = where(regs, m.start())
            if cls == EXCLUDED_CLASS or m.start() in def_at:
                continue
            if (cls, meth) == (HOST_CLASS, HELPER):
                inside += 1
            else:
                line = code.count("\n", 0, m.start()) + 1
                elsewhere.append(f"{label} at line {line} ({cls} {meth})")
        return inside, elsewhere

    inside, elsewhere = census(r"\bZB_NAVIGATION_TIMEOUT_SECONDS\b", "ZB_NAVIGATION_TIMEOUT_SECONDS")
    for e in elsewhere:
        problems.append(f"B1 census: {e}: the exit timer is scheduled outside -[{HOST_CLASS} {HELPER}]")
    if inside != 1:
        problems.append(f"B1 census: -[{HOST_CLASS} {HELPER}] names ZB_NAVIGATION_TIMEOUT_SECONDS {inside} times, want 1")
    inside, elsewhere = census(r"@selector\s*\(\s*onNavigationTimeout\s*:\s*\)", "@selector(onNavigationTimeout:)")
    for e in elsewhere:
        problems.append(f"B1 census: {e}: the exit-timer handler is targeted outside -[{HOST_CLASS} {HELPER}]")
    if inside != 1:
        problems.append(f"B1 census: -[{HOST_CLASS} {HELPER}] targets onNavigationTimeout: {inside} times, want 1")
    inside, elsewhere = 0, []
    for m in re.finditer(r"\btimeoutTimer\s*=(?!=)\s*([^;]*);", code):
        if m.group(1).strip() == "nil":
            continue
        cls, meth = where(regs, m.start())
        if cls == EXCLUDED_CLASS:
            continue
        if (cls, meth) == (HOST_CLASS, HELPER):
            inside += 1
        else:
            elsewhere.append(f"a non-nil timeoutTimer assignment at line {code.count(chr(10), 0, m.start()) + 1} ({cls} {meth})")
    for e in elsewhere:
        problems.append(f"B1 census: {e}: a timer is stored outside -[{HOST_CLASS} {HELPER}]")
    if inside != 1:
        problems.append(f"B1 census: -[{HOST_CLASS} {HELPER}] stores a timer {inside} times, want 1")

    arm = body(code, regs, HOST_CLASS, HELPER)
    if arm is None:
        problems.append(f"B2 guard: -[{HOST_CLASS} {HELPER}] is not defined exactly once")
    elif tokens(arm) != tokens(strip(REVIEWED_ARM)):
        problems.append(f"B2 guard: -[{HOST_CLASS} {HELPER}] differs from the reviewed guarded shape "
                        "(the timer must be scheduled only when zb_load_exit_timer_armed says so)")

    calls = [m.start() for m in re.finditer(r"\[\s*self\s+" + HELPER + r"\s*\]", code)]
    by_method: dict[tuple[str, str], int] = {}
    for off in calls:
        key = where(regs, off)
        by_method[key] = by_method.get(key, 0) + 1
    for meth in INITIATORS:
        n = by_method.pop((HOST_CLASS, meth), 0)
        if n != 1:
            problems.append(f"B3 initiators: -[{HOST_CLASS} {meth}] calls {HELPER} {n} times, want 1")
            continue
        b = body(code, regs, HOST_CLASS, meth)
        arm_at = b.find(HELPER) if b is not None else -1
        load_at = min((b.find(w) for w in ("loadRequest", "reloadFromOrigin", "reload]") if b.find(w) >= 0), default=-1)
        if arm_at < 0 or load_at < 0 or arm_at > load_at:
            problems.append(f"B3 initiators: -[{HOST_CLASS} {meth}] does not arm before it starts the load")
    for (cls, meth), n in sorted(by_method.items()):
        problems.append(f"B3 initiators: {cls} {meth} also calls {HELPER} ({n}x): not a reviewed load initiator")
    if arm is not None and len(re.findall(r"\b" + HELPER + r"\b", code)) != 1 + len(calls):
        problems.append(f"B3 initiators: {HELPER} is named other than by its definition and its calls")

    timeout = body(code, regs, HOST_CLASS, "onNavigationTimeout:")
    if timeout is None:
        problems.append(f"B4 expiry: -[{HOST_CLASS} onNavigationTimeout:] is not defined exactly once")
    elif tokens(timeout) != tokens(strip(REVIEWED_TIMEOUT)):
        problems.append(f"B4 expiry: -[{HOST_CLASS} onNavigationTimeout:] differs from the reviewed shape "
                        "(it must quit only when zb_load_failure_action is ZB_LOADFAIL_EXIT)")
    exits = []
    for m in re.finditer(r"\bZB_EXIT_TIMEOUT\b", code):
        cls, meth = where(regs, m.start())
        if cls != EXCLUDED_CLASS:
            exits.append((cls, meth))
    if exits != [(HOST_CLASS, "onNavigationTimeout:")]:
        problems.append(f"B4 expiry: ZB_EXIT_TIMEOUT outside {EXCLUDED_CLASS} is used at {exits}, "
                        f"want only -[{HOST_CLASS} onNavigationTimeout:]")
    return problems


def main(argv: list[str]) -> int:
    shim = Path(argv[1]) if len(argv) > 1 else SHIM
    problems = check(shim.read_text())
    for p in problems:
        print(f"FAIL {p}")
    if problems:
        print(f"FAIL mac-load-exit-timer-binding {len(problems)} problem(s) in {shim}")
        return 1
    print("PASS mac-load-exit-timer-binding B1 census, B2 guard, B3 initiators, B4 expiry")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
