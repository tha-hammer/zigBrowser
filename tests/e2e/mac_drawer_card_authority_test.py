"""MS7.6 / MS7.8 (macOS plan line 2158; RoseCat 8055 / bdc8202 on 698ba02): on macOS the approval card's native
Approve control is the ONLY production minter, and Deny mints nothing. What a press may do is decided and tested in the
portable logic (tests/agent_drawer_card_press_test.zig: zb_drawer_card_press over the real MS4 cards: own control, own
card, single use, the 120 s expiry). This oracle binds the AppKit side to it, over EXACTLY the sources of the macOS
link: build.zig's configureMacosBackend, the Objective-C files it hands `xcrun clang` (shim.addFileArg) and the C files
it compiles into the exe (module.addCSourceFile). Each source is read lexically: comments removed and the contents of
string and character literals blanked, so a name inside a string or a comment never counts (button titles are read
from the comment-free text with strings kept).
- L0: src/agent_drawer_mac.m is one of those link sources.
- L1: no link source names zb_agent_tools_approve or zb_agent_tools_deny at all (no call, no address, no alias): the
  AppKit side reaches the cards only through zb_drawer_card_press.
- L2: zb_drawer_card_press is named only in agent_drawer_mac.m: one prototype and exactly two calls,
  `zb_drawer_card_press(_card, ZB_CARD_APPROVE, sender == _approve)` inside `- (void)approveClicked:(id)sender` and
  `zb_drawer_card_press(_card, ZB_CARD_DENY, sender == _deny)` inside `- (void)denyClicked:(id)sender` (the card's own
  id, the control, and whether the sender is the card's own control); ZB_CARD_APPROVE is #defined 1 and ZB_CARD_DENY 2,
  the portable values.
- L3: each action is wired once, when its button is made: `_approve = [NSButton buttonWithTitle:@"Approve" target:self
  action:@selector(approveClicked:)]` and the same for _deny / @"Deny" / denyClicked:; approveClicked and denyClicked
  are each named exactly twice (the definition and that selector).
- L4: no alternate ingress in any link source: no dlsym, dlopen, NSSelectorFromString, NSClassFromString,
  objc_msgSend, method_getImplementation, class_replaceMethod, method_exchangeImplementations, sendAction:,
  performSelector, performClick, setAction: or setTarget:; and the drawer has no WKScriptMessageHandler,
  WKUserContentController, addScriptMessageHandler or evaluateJavaScript.
The real native click (MS7.8's -[NSWindow sendEvent:] Approve/Deny) stays the owner-run real-screen closure.
Self-checking: an honest fixture passes; names in strings and comments do not count; and each dishonest fixture fails.
RED until build.zig's macOS link has src/agent_drawer_mac.m with that shape. No process, no signal.
Run: cd tests/e2e && python3 -X dev -m unittest -v mac_drawer_card_authority_test
Unregistered until the green."""
import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
DRAWER = "src/agent_drawer_mac.m"
INGRESS = ("dlsym", "dlopen", "NSSelectorFromString", "NSClassFromString", "objc_msgSend", "method_getImplementation",
           "class_replaceMethod", "method_exchangeImplementations", "sendAction:", "performSelector", "performClick",
           "setAction:", "setTarget:")
DRAWER_ONLY = ("WKScriptMessageHandler", "WKUserContentController", "addScriptMessageHandler", "evaluateJavaScript")
CALLS = {"approveClicked:": "zb_drawer_card_press(_card,ZB_CARD_APPROVE,sender==_approve)",
         "denyClicked:": "zb_drawer_card_press(_card,ZB_CARD_DENY,sender==_deny)"}
BUTTONS = {"approveClicked:": ("_approve", '@"Approve"'), "denyClicked:": ("_deny", '@"Deny"')}


def mac_link_sources(build_zig):
    """The sources of the macOS link: configureMacosBackend's shim.addFileArg and module.addCSourceFile paths."""
    m = re.search(r"fn configureMacosBackend\(.*?\n}\n", build_zig, re.S)
    if m is None:
        return []
    body = m.group(0)
    return re.findall(r'(?:shim\.addFileArg|module\.addCSourceFile)\(\s*(?:\.\{\s*\.file\s*=\s*)?b\.path\("([^"]+)"\)',
                      body)


def strip(text, blank_strings):
    """Comments removed; with `blank_strings`, each string/char literal's contents emptied (quotes kept)."""
    out, i, n = [], 0, len(text)
    while i < n:
        if text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            i = n if j < 0 else j + 2
        elif text[i] in "\"'":
            q, j = text[i], i + 1
            while j < n and text[j] != q:
                j += 2 if text[j] == "\\" else 1
            out.append(q + q if blank_strings else text[i:j + 1])
            i = j + 1
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


def body(code, selector):
    m = re.search(r"-\s*\(\s*void\s*\)\s*" + re.escape(selector) + r"\s*\(\s*id\s*\)\s*sender\s*\{", code)
    if m is None:
        return None
    depth, i = 1, m.end()
    while i < len(code) and depth:
        depth += {"{": 1, "}": -1}.get(code[i], 0)
        i += 1
    return code[m.end():i - 1]


def squash(s):
    return re.sub(r"\s+", "", s)


def problems(sources, files):
    """`sources`: the macOS link's source paths; `files`: {path: text}. -> the contract's violations (empty: holds)."""
    if DRAWER not in sources:
        return [f"L0: {DRAWER} is not in the macOS link ({sources})"]
    code = {p: strip(files.get(p, ""), True) for p in sources}
    titled = {p: strip(files.get(p, ""), False) for p in sources}
    found = []
    for p, c in code.items():
        for name in ("zb_agent_tools_approve", "zb_agent_tools_deny"):
            if re.search(r"\b" + name + r"\b", c):
                found.append(f"L1: {p} names {name}")
        for word in INGRESS:
            if word in c:
                found.append(f"L4: {p} uses {word}")
        if p != DRAWER and re.search(r"\bzb_drawer_card_press\b", c):
            found.append(f"L2: {p} names zb_drawer_card_press")
    drawer = code[DRAWER]
    for word in DRAWER_ONLY:
        if word in drawer:
            found.append(f"L4: the drawer uses {word}")
    without_proto = re.sub(r"^[ \t]*(?:extern[ \t]+)?int[ \t]+zb_drawer_card_press[ \t]*\([^)]*\)[ \t]*;", "", drawer,
                           flags=re.M)
    if len(re.findall(r"\bzb_drawer_card_press\b", drawer)) - len(re.findall(r"\bzb_drawer_card_press\b", without_proto)) != 1:
        found.append("L2: want exactly one zb_drawer_card_press prototype")
    calls = re.findall(r"\bzb_drawer_card_press\s*\([^;]*?\)(?=\s*[;)\]=!<>&|]|\s*$)", without_proto, re.M)
    names = len(re.findall(r"\bzb_drawer_card_press\b", without_proto))
    if names != 2 or len(calls) != 2:
        found.append(f"L2: zb_drawer_card_press must be called exactly twice and named nowhere else ({names} names)")
    for selector, call in CALLS.items():
        b = body(drawer, selector)
        if b is None:
            found.append(f"L2: no `- (void){selector}(id)sender`")
            continue
        got = [squash(c) for c in re.findall(r"\bzb_drawer_card_press\s*\([^;]*?\)", b)]
        if got != [call]:
            found.append(f"L2: {selector} must call exactly {call} (got {got})")
        name = selector[:-1]
        if len(re.findall(r"\b" + name + r"\b", drawer)) != 2:
            found.append(f"L3: {name} must be named exactly twice (definition and its one selector)")
        ivar, title = BUTTONS[selector]
        wired = [s for s in titled[DRAWER].split(";") if f"@selector({selector})" in s]
        if len(wired) != 1 or not re.search(r"\b" + ivar + r"\s*=\s*\[\s*NSButton\s+buttonWithTitle:\s*" + re.escape(title)
                                            + r"\s+target:\s*self\s+action:\s*@selector\(" + re.escape(selector) + r"\)\s*\]",
                                            wired[0]):
            found.append(f"L3: {selector} must be wired once, as {ivar} = [NSButton buttonWithTitle:{title} target:self "
                         f"action:@selector({selector})]")
    for define, value in (("ZB_CARD_APPROVE", "1"), ("ZB_CARD_DENY", "2")):
        if not re.search(r"^[ \t]*#[ \t]*define[ \t]+" + define + r"[ \t]+" + value + r"[ \t]*$", drawer, re.M):
            found.append(f"L2: want #define {define} {value} (the portable value)")
    return found


HONEST = r'''
#import <AppKit/AppKit.h>
#define ZB_CARD_APPROVE 1
#define ZB_CARD_DENY 2
int zb_drawer_card_press(unsigned long long card, int control, int own);
@implementation ZbCardView
- (instancetype)initWithCard:(unsigned long long)card {
  self = [super init];
  _card = card;
  _approve = [NSButton buttonWithTitle:@"Approve" target:self action:@selector(approveClicked:)];
  _deny = [NSButton buttonWithTitle:@"Deny" target:self action:@selector(denyClicked:)];
  return self;
}
/* the press is decided by the portable logic: zb_agent_tools_approve() is never named here */
- (void)approveClicked:(id)sender {
  if (zb_drawer_card_press(_card, ZB_CARD_APPROVE, sender == _approve) == 1) {
    [self settle:@"approved"];
  }
}
- (void)denyClicked:(id)sender {
  if (zb_drawer_card_press(_card, ZB_CARD_DENY, sender == _deny) == 2) {
    [self settle:nil];
  }
}
@end
'''
LINK = ["src/agent_home_lock.c", "src/agent_spawn_posix.c", "src/wkwebview_shim.m", DRAWER]
PLAIN = {"src/agent_home_lock.c": "int zb_agent_home_lock(void) { return 0; }\n",
         "src/agent_spawn_posix.c": "int zb_agent_spawn_group(void) { return 0; }\n",
         "src/wkwebview_shim.m": "static const char *k = \"dlsym zb_agent_tools_approve\"; // performClick\n"}


def honest():
    return dict(PLAIN, **{DRAWER: HONEST})


def drawer_mutant(old, new):
    assert HONEST.count(old) == 1, old
    return dict(PLAIN, **{DRAWER: HONEST.replace(old, new)})


MUTANTS = {
    "a function-pointer alias": drawer_mutant("@end", "static int (*alias)(unsigned long long, int, int) = zb_drawer_card_press;\n@end"),
    "dlsym reaches the minter": drawer_mutant("@end", "- (void)k { void *f = dlsym(RTLD_DEFAULT, \"zb_agent_tools_approve\"); }\n@end"),
    "sendAction reaches Approve": drawer_mutant("@end", "- (void)k { [NSApp sendAction:@selector(approveClicked:) to:self from:_approve]; }\n@end"),
    "the target/action is rewired": drawer_mutant("  return self;\n", "  [_deny setAction:@selector(approveClicked:)];\n  return self;\n"),
    "the shim mints directly": dict(honest(), **{"src/wkwebview_shim.m": "int zb_agent_tools_approve(unsigned long long);\nvoid f(void) { zb_agent_tools_approve(1); }\n"}),
    "the sender is not checked": drawer_mutant("zb_drawer_card_press(_card, ZB_CARD_APPROVE, sender == _approve)",
                                               "zb_drawer_card_press(_card, ZB_CARD_APPROVE, 1)"),
    "another card is pressed": drawer_mutant("zb_drawer_card_press(_card, ZB_CARD_APPROVE, sender == _approve)",
                                             "zb_drawer_card_press(_card + 1, ZB_CARD_APPROVE, sender == _approve)"),
    "Deny presses Approve": drawer_mutant("zb_drawer_card_press(_card, ZB_CARD_DENY, sender == _deny)",
                                          "zb_drawer_card_press(_card, ZB_CARD_APPROVE, sender == _deny)"),
    "a keyboard path": drawer_mutant("@end", "- (void)keyDown:(NSEvent *)e { zb_drawer_card_press(_card, ZB_CARD_APPROVE, 1); }\n@end"),
    "a timer path": drawer_mutant("  return self;\n", "  [self performSelector:@selector(approveClicked:) withObject:_approve afterDelay:1];\n  return self;\n"),
    "swapped selectors": drawer_mutant('@"Approve" target:self action:@selector(approveClicked:)]', '@"Approve" target:self action:@selector(denyClicked:)]'),
    "a programmatic press": drawer_mutant("  return self;\n", "  [_approve performClick:nil];\n  return self;\n"),
    "a script message": drawer_mutant("@end", "- (void)userContentController:(WKUserContentController *)u didReceiveScriptMessage:(id)m {}\n@end"),
    "the shim names the seam": dict(honest(), **{"src/wkwebview_shim.m": "int zb_drawer_card_press(unsigned long long, int, int);\n"}),
    "the wrong control value": drawer_mutant("#define ZB_CARD_DENY 2", "#define ZB_CARD_DENY 1"),
}


class CardAuthority(unittest.TestCase):
    def test_the_real_macos_link_keeps_the_one_minter(self):
        sources = mac_link_sources((REPO / "build.zig").read_text())
        self.assertIn("src/wkwebview_shim.m", sources, "the link parser found no macOS sources")
        files = {p: (REPO / p).read_text() for p in sources if (REPO / p).exists()}
        self.assertEqual(problems(sources, files), [])

    def test_the_honest_fixture_passes(self):
        self.assertEqual(problems(LINK, honest()), [])

    def test_a_drawer_outside_the_link_fails(self):
        self.assertNotEqual(problems(LINK[:-1], honest()), [])

    def test_each_dishonest_fixture_fails(self):
        for name, files in MUTANTS.items():
            with self.subTest(mutant=name):
                self.assertNotEqual(files, honest(), "the mutation's anchor moved")
                self.assertNotEqual(problems(LINK, files), [], name)


if __name__ == "__main__":
    unittest.main()
