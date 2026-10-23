#!/usr/bin/env python3
"""Every build step that runs on the Windows VM is left out of build.zig's display guard (a SOURCE TRIPWIRE).

guardDisplay (build.zig) makes every top-level step wait for `python3 tools/display_guard.py`, except the
names in its `unguarded` list. The Win11 VM has no python3, so a VM-run step missing from that list fails
("Python was not found", exit 49) before its executable runs: the WS2b.1 red at 516b5b1 failed that way
beside its link errors, and ws2b1-input-spike-win could never reach the matrix (FoggyReef preflight of
75aa04c, orchestrator scope after cd155c4).

A VM-run step here is either a `b.step("<name>-win", ...)` declared inside a Windows-target-only block of
build.zig (`if (backend == .webview2_backend) {` or `if (target.result.os.tag == .windows) {`), or a step a
live driver builds on the VM (`STEP = "<name>-win"` in tests/e2e or tests/windows). Each one must be in
`unguarded`. This reads source text only; the real proof is an approved Win11 run reaching the step's
executable.

Run:  python3 -I tests/windows/vm_steps_unguarded_test.py -v
"""
import pathlib
import re
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]
BUILD = REPO / "build.zig"
WINDOWS_ONLY_BLOCKS = ("if (backend == .webview2_backend) {", "if (target.result.os.tag == .windows) {")
# Steps known to run on the VM today: the scan must find at least these, so it cannot pass by finding nothing.
KNOWN_VM_STEPS = {"ws3-shim-test-win", "owner-only-test-win", "ws2a0-world-spike-win", "ws2a3-async-ownership-win",
                  "ws2b1-input-spike-win"}


def code_only(text):
    """`text` with Zig comments, string and char literals and multiline-string lines blanked (lengths kept)."""
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if text.startswith("//", i) or text.startswith("\\\\", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i))
            i = j
        elif c in "\"'":
            j = i + 1
            while j < n and text[j] != c and text[j] != "\n":
                j += 2 if text[j] == "\\" else 1
            j = min(j + 1, n)
            out.append(c + " " * (j - i - 2) + c if j - i >= 2 else " " * (j - i))
            i = j
        else:
            out.append(c)
            i += 1
    return "".join(out)


def block_spans(text, code, opener):
    """(start, end) of every block that `opener` begins, by brace matching on the code-only text."""
    spans, at = [], 0
    while True:
        i = text.find(opener, at)
        if i < 0:
            return spans
        if code[i:i + len(opener)] != opener:  # inside a comment or string
            at = i + 1
            continue
        depth, j = 0, i + len(opener) - 1
        while j < len(code):
            if code[j] == "{":
                depth += 1
            elif code[j] == "}":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        spans.append((i, j))
        at = i + 1


def vm_steps(text):
    code = code_only(text)
    spans = [s for opener in WINDOWS_ONLY_BLOCKS for s in block_spans(text, code, opener)]
    found = set()
    for m in re.finditer(r'b\.step\(\s*"([A-Za-z0-9_-]+-win)"', text):
        if code[m.start():m.start() + 6] == "b.step" and any(a <= m.start() <= b for a, b in spans):
            found.add(m.group(1))
    for path in sorted((REPO / "tests").glob("*/*.py")):
        for m in re.finditer(r'^STEP\s*=\s*"([A-Za-z0-9_-]+-win)"', path.read_text(encoding="utf-8"), re.M):
            found.add(m.group(1))
    return found


def unguarded(text):
    m = re.search(r"fn guardDisplay\(.*?const unguarded = \[_\]\[\]const u8\{(.*?)\};", text, re.S)
    if m is None:
        raise AssertionError("build.zig: guardDisplay's `const unguarded = [_][]const u8{...};` not found")
    return set(re.findall(r'"([^"]+)"', m.group(1)))


class VmStepsUnguarded(unittest.TestCase):
    def setUp(self):
        self.text = BUILD.read_text(encoding="utf-8")

    def test_the_scan_finds_every_known_vm_step(self):
        missing = KNOWN_VM_STEPS - vm_steps(self.text)
        self.assertFalse(missing, f"the VM-step scan lost {sorted(missing)}: it would pass vacuously")

    def test_linux_cross_checks_are_not_vm_steps(self):
        # cross-check-*-win compile on Linux and keep the guard; the scan must not sweep them in.
        cross = {s for s in vm_steps(self.text) if s.startswith("cross-check-")}
        self.assertFalse(cross, f"Linux cross-check steps counted as VM steps: {sorted(cross)}")

    def test_every_vm_step_is_left_out_of_the_display_guard(self):
        guarded = sorted(vm_steps(self.text) - unguarded(self.text))
        self.assertFalse(guarded, f"VM-run steps still wait for python3 tools/display_guard.py (no python3 on the VM): "
                                  f"{guarded}; add each to guardDisplay's `unguarded` list")


if __name__ == "__main__":
    unittest.main()
