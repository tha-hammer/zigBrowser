"""MS7 compiled two-Mac hard gate (RoseCat c6b2b32 items 2-4; orchestrator 2026-10-22): the OFFLINE self-check of
tests/mac/ms7_appkit_check.py (the checker), tests/mac/ms7_appkit_case.py (one Mac leg), tests/mac/ms7_appkit_probe.m
(the in-process probe) and tests/mac/ms7_appkit_gate.sh (the launcher). The gate itself runs only on the Macs, with
RoseCat's exact-commit and digest approval plus the orchestrator's release; nothing here contacts a Mac, spawns or
signals.
- The checker: an honest evidence set (the reviewed argv, the reviewed shapes in the preprocessed drawer and shim, a
  clean link census, a live report: ZbBubbleView under NSTextView with exactly the reviewed six methods in the shim,
  no category, no foreign IMP, one Edit > Copy item with target nil, the exact original bytes for each bubble and
  selection through a real Cmd+C, the page fallback, a chain-presented card minting exactly one grant) passes; each
  dishonest evidence set fails for its own rule.
- RED: head_problems(the repo) names what this commit still lacks for the gate to pass (the drawer, its link line,
  the Edit menu, the card bridge); the probe reports no card source until MS8 wires one on macOS.
- The launcher and the leg, read as text: the launcher runs only from the commit's bytes, needs both hosts, uses
  BatchMode, strict host keys and no DISPLAY, and deletes only a validated per-run directory. Every child of the leg
  runs through the reviewed Harness.spawn_group (no other spawn, kill or killpg). The probe restores the pasteboard
  before it terminates the app, and a watchdog bounds it.
Run: cd tests/e2e && python3 -X dev -m unittest -v ms7_appkit_gate_test
Unregistered until the green."""
import copy
import re
import sys
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "tests/mac"))
import ms7_appkit_check as check  # noqa: E402
from mac_drawer_bubble_inert_test import HONEST, REVIEWED_EDIT_MENU  # noqa: E402

SHIM, EXE = "/Users/u/zb-ms7gate-1/repo/zig-out/Frameworks/libwkwebview_shim.dylib", "/Users/u/zb-ms7gate-1/repo/zig-out/bin/zigBrowser"


def honest():
    want = check.originals()
    bubbles = []
    for label in check.BUBBLES:
        for selection, expect in (("whole", want[label]), ("prefix", want[label][:check.PREFIX])):
            bubbles.append({"label": label, "selection": selection, "first_responder": "ZbBubbleView",
                            "via": "NSApplication sendEvent: Cmd+C", "pasteboard_hex": expect.hex(),
                            "contiguous": label == "small"})
    report = {
        "arch": "arm64", "errors": [], "shim_image": SHIM, "exe_image": EXE,
        "classes": {"ZbBubbleView": {"super": "NSTextView", "image": SHIM,
                                     "methods": [{"sel": s, "image": SHIM} for s in check.BUBBLE_METHODS]}},
        "catlists": {SHIM: {"catlist": 0, "nlcatlist": 0}, EXE: {"catlist": 0, "nlcatlist": 0}},
        "watched": list(check.WATCHED), "watched_counts": {w: 40 for w in check.WATCHED}, "foreign_imps": [],
        "copy_items": [{"path": ["Edit", "Copy"], "key": "c", "modifiers": ["command"], "target_nil": True}],
        "bubbles": bubbles,
        "page": {"selected": True, "first_responder": "WKWebView", "via": "NSApplication sendEvent: Cmd+C",
                 "pasteboard": check.PAGE_TEXT},
        "page_handlers": 0,
        "card": {"source": "chain", "approve_action": "approveClicked:", "approve_target": "ZbCardView",
                 "deny_action": "denyClicked:", "deny_target": "ZbCardView", "via": "NSWindow sendEvent: mouse",
                 "grants": [0, 1, 1, 1]},
    }
    return {"argv": [["xcrun", "--show-sdk-path"], list(check.REVIEWED_ARGV)],
            "pre_drawer": "# 1 \"src/agent_drawer_mac.m\"\n" + HONEST,
            "pre_shim": "# 1 \"src/wkwebview_shim.m\"\n" + REVIEWED_EDIT_MENU + "\nint zb_app_run(void) { return 0; }\n",
            "nm": {"exe_undefined": ["_zb_app_run"], "exe_defined": list(check.EXE_DEFINES) + ["_main"],
                   "dylib_undefined": ["_zb_drawer_card_press", "_zb_drawer_appkit_shown"]},
            "report": report}


def mutant(path, value):
    ev = copy.deepcopy(honest())
    node = ev
    for key in path[:-1]:
        node = node[key]
    if callable(value):
        node[path[-1]] = value(node[path[-1]])
    else:
        node[path[-1]] = value
    return ev


def bubble_row(label, selection, **changes):
    def change(rows):
        for row in rows:
            if row["label"] == label and row["selection"] == selection:
                row.update(changes)
        return rows
    return change


MUTANTS = {  # name -> (evidence, the rule its finding starts with)
    "a forwarded preprocessor flag in the argv": (mutant(["argv"], [check.REVIEWED_ARGV[:4] + ["-Wp,-DNO=YES"] + check.REVIEWED_ARGV[4:]]), "A:"),
    "two shim compiles": (mutant(["argv"], [list(check.REVIEWED_ARGV), list(check.REVIEWED_ARGV)]), "A:"),
    "no shim compile recorded": (mutant(["argv"], [["xcrun", "--show-sdk-path"]]), "A:"),
    "a preprocessed category on ZbBubbleView": (mutant(["pre_shim"], lambda t: t + "@implementation ZbBubbleView (Steal)\n@end\n"), "P:"),
    "a macro-rewritten bubble (NO became YES)": (mutant(["pre_drawer"], lambda t: t.replace("return NO;", "return YES;")), "P:"),
    "the preprocessed menu changed": (mutant(["pre_shim"], lambda t: t.replace('keyEquivalent:@"c"', 'keyEquivalent:@"x"')), "P:"),
    "nothing preprocessed": (mutant(["pre_drawer"], ""), "P:"),
    "a GTK-only card call in the executable": (mutant(["nm", "exe_undefined"], lambda s: s + ["_zb_drawer_card_show"]), "L:"),
    "a GTK-only helper call in the dylib": (mutant(["nm", "dylib_undefined"], lambda s: s + ["_zb_agent_helper_post_tool_result"]), "L:"),
    "no minter in the executable": (mutant(["nm", "exe_defined"], ["_main", "_zb_drawer_card_press"]), "L:"),
    "another superclass": (mutant(["report", "classes", "ZbBubbleView", "super"], "NSTextField"), "O:"),
    "an extra method (a category's copy:)": (mutant(["report", "classes", "ZbBubbleView", "methods"],
                                                     lambda m: m + [{"sel": "paste:", "image": SHIM}]), "O:"),
    "a method running from another image": (mutant(["report", "classes", "ZbBubbleView", "methods"],
                                                   lambda m: [dict(x, image="/tmp/evil.dylib") if x["sel"] == "copy:" else x for x in m]), "O:"),
    "a category registered in the shim": (mutant(["report", "catlists", SHIM, "catlist"], 1), "O:"),
    "the census misses the executable": (mutant(["report", "catlists"], lambda c: {SHIM: c[SHIM]}), "O:"),
    "a swizzled NSTextView method": (mutant(["report", "foreign_imps"], [{"class": "NSTextView", "sel": "copy:", "image": SHIM}]), "O:"),
    "a watched class not examined": (mutant(["report", "watched_counts", "NSMenuItem"], 0), "O:"),
    "ZbBubbleView not loaded": (mutant(["report", "classes"], {}), "O:"),
    "the Copy item has a target": (mutant(["report", "copy_items", 0, "target_nil"], False), "M:"),
    "two copy: items": (mutant(["report", "copy_items"], lambda i: i + i), "M:"),
    "no copy: item": (mutant(["report", "copy_items"], []), "M:"),
    "Copy on another key": (mutant(["report", "copy_items", 0, "modifiers"], ["command", "shift"]), "M:"),
    "the shown text copied": (mutant(["report", "bubbles"], bubble_row("small", "whole", pasteboard_hex=b"plain ?? bytes".hex())), "B:"),
    "the pasteboard untouched (sentinel)": (mutant(["report", "bubbles"], bubble_row("large", "prefix", pasteboard_hex=b"ms7-probe-sentinel".hex())), "B:"),
    "another first responder": (mutant(["report", "bubbles"], bubble_row("boundary", "whole", first_responder="NSTextView")), "B:"),
    "copy: sent directly, not through the menu": (mutant(["report", "bubbles"], bubble_row("small", "prefix", via="performSelector copy:")), "B:"),
    "a bubble row missing": (mutant(["report", "bubbles"], lambda rows: [r for r in rows if r["label"] != "boundary"]), "B:"),
    "the large bubble laid out contiguously": (mutant(["report", "bubbles"], bubble_row("large", "whole", contiguous=True)), "B:"),
    "the page fallback copied nothing": (mutant(["report", "page", "pasteboard"], "ms7-probe-sentinel"), "W:"),
    "no card on macOS (MS8 not wired)": (mutant(["report", "card"], {"source": "absent"}), "C:"),
    "Approve wired to another target": (mutant(["report", "card", "approve_target"], "ZbDrawerView"), "C:"),
    "a second Approve minted again": (mutant(["report", "card", "grants"], [0, 1, 2, 2]), "C:"),
    "Deny on another card minted": (mutant(["report", "card", "grants"], [0, 1, 1, 2]), "C:"),
    "the click bypassed the window": (mutant(["report", "card", "via"], "performClick:"), "C:"),
    "the page reaches a message handler": (mutant(["report", "page_handlers"], 1), "C:"),
    "the report of the other Mac": (mutant(["report", "arch"], "x86_64"), "R:"),
    "the probe timed out": (mutant(["report", "errors"], ["probe watchdog: no result within 120 s"]), "R:"),
    "no report at all": (mutant(["report"], None), "R:"),
}


def code_of(text):
    return "\n".join(line.split("#", 1)[0] for line in text.splitlines())


class Ms7AppkitGate(unittest.TestCase):
    def test_honest_evidence_passes(self):
        self.assertEqual(check.problems(honest(), "arm64"), [])

    def test_each_dishonest_evidence_fails_for_its_rule(self):
        for name, (ev, rule) in MUTANTS.items():
            with self.subTest(mutant=name):
                self.assertNotEqual(ev, honest(), "the mutation did not apply")
                found = check.problems(ev, "arm64")
                self.assertTrue(any(f.startswith(rule) for f in found), (name, found))

    def test_this_commit_is_red(self):
        self.assertEqual(check.head_problems(REPO), [])

    def test_the_argv_log_parses(self):
        sys.path.insert(0, str(REPO / "tests/mac/hard_gate"))
        import ms7_appkit_case as case
        raw = b"clang\0-E\0a b\0\x01\0--show-sdk-path\0\x01\0"
        self.assertEqual(case.argv_records(raw), [["clang", "-E", "a b"], ["--show-sdk-path"]])
        self.assertEqual(check.normalize(["-I", "/r/src", "/x/o/libwkwebview_shim.dylib", "@executable_path/../Frameworks/libwkwebview_shim.dylib"],
                                         "/r", ""),
                         ["-I", "<repo>/src", "<out>", "@executable_path/../Frameworks/libwkwebview_shim.dylib"])

    def test_the_launcher_is_bounded_and_fail_closed(self):
        text = (REPO / "tests/mac/ms7_appkit_gate.sh").read_text()
        for need in ('[ -z "${BASH_EXECUTION_STRING:-}" ]', 'git show "$SHA:tests/mac/ms7_appkit_gate.sh")" = "$LAUNCHER"',
                     '[ -n "$ARM_HOST" ] || fail', "-o BatchMode=yes", "-o StrictHostKeyChecking=yes",
                     "env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY", "export SSH_ASKPASS_REQUIRE=never",
                     'case "$ZB_RDIR" in zb-ms7gate-*) ;;', 'find "$HOME/${ZB_RDIR:?}" -delete', 'timeout "$LEG_TIMEOUT"',
                     'git archive "$SHA"', '== ship $(sha256sum'):
            with self.subTest(need=need):
                self.assertIn(need, text)
        self.assertNotIn("StrictHostKeyChecking=no", text)
        self.assertNotRegex(code_of(text), r"\brm\s+-rf?\b")

    def test_the_leg_spawns_and_signals_only_through_the_harness(self):
        text = code_of((REPO / "tests/mac/ms7_appkit_case.py").read_text())
        self.assertIn("from harness import Harness", text)
        for banned in (r"\bsubprocess\b", r"\bos\.system\b", r"\bos\.kill\b", r"\bos\.killpg\b", r"\bPopen\b", r"\bsignal\."):
            with self.subTest(banned=banned):
                self.assertNotRegex(text, banned)
        self.assertGreaterEqual(len(re.findall(r"h2?\.spawn_group\(", text)), 6)
        self.assertRegex(text, r"finally:\s*\n\s*h\.close\(\)")

    def test_the_probe_restores_and_is_bounded(self):
        text = (REPO / "tests/mac/ms7_appkit_probe.m").read_text()
        body = text[text.index("ms7_probe_start"):]
        self.assertLess(body.index("save_pasteboard()"), body.index("restore_pasteboard(saved)"))
        self.assertLess(body.index("restore_pasteboard(saved)"), body.index("[NSApp terminate:nil]"))
        self.assertIn("probe watchdog", text)
        for banned in ("kill(", "killpg(", "system(", "posix_spawn", "NSTask"):
            with self.subTest(banned=banned):
                self.assertNotIn(banned, text)


if __name__ == "__main__":
    unittest.main()
