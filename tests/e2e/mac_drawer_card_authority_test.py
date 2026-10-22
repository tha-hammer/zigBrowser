"""MS7.6 / MS7.8 (macOS plan line 2158): on macOS the approval card's native Approve control is the ONLY production
grant minter, and Deny mints nothing. The GTK card's single authority is zb_agent_tools_approve / zb_agent_tools_deny
(src/agent_tools.zig: "the main drawer's Approve button, the only caller"); the AppKit card in src/agent_drawer_mac.m
must keep that shape. Offline (no macOS SDK here), this is a source-bound oracle over every Objective-C source the Mac
app builds (src/*.m), comments removed:
- R1: zb_agent_tools_approve( is called exactly once in src/*.m, inside agent_drawer_mac.m's
  `- (void)approveClicked:(id)sender` body; R2: zb_agent_tools_deny( exactly once, inside `denyClicked:`;
- R3: @selector(approveClicked:) appears exactly once, in the statement that makes the button titled @"Approve" (and
  not @"Deny"); @selector(denyClicked:) exactly once, with @"Deny" (and not @"Approve");
- R4: the action is reachable only through that button's target/action: `approveClicked` / `denyClicked` appear
  nowhere else (no performSelector, sendAction, timer or keyboard path to them), and agent_drawer_mac.m never calls
  performClick (no programmatic press);
- R5: the drawer is native and isolated from page worlds: agent_drawer_mac.m has no WKScriptMessageHandler,
  WKUserContentController, addScriptMessageHandler or evaluateJavaScript.
The real-screen native click (MS7.8's -[NSWindow sendEvent:]) is orchestrator-run; this pins the source shape the click
lands in. Self-checking: an honest fixture passes, and each dishonest fixture (a keyboard mint, swapped selectors, a
script-message mint, a programmatic press, a second file minting, Deny minting, a timer path) fails.
RED until src/agent_drawer_mac.m exists with that shape. No process, no signal.
Run: cd tests/e2e && python3 -X dev -m unittest -v mac_drawer_card_authority_test
Unregistered until the green."""
import re
import unittest
from pathlib import Path

SRC = Path(__file__).resolve().parents[2] / "src"
DRAWER = "agent_drawer_mac.m"
# A declaration is not a call: `[extern] int zb_agent_tools_approve(<params>);` is removed before counting.
PROTOTYPE = re.compile(r"^[ \t]*(?:extern[ \t]+)?int[ \t]+zb_agent_tools_(?:approve|deny)[ \t]*\([^)]*\)[ \t]*;", re.M)
FORBIDDEN_IN_DRAWER = ("WKScriptMessageHandler", "WKUserContentController", "addScriptMessageHandler",
                       "evaluateJavaScript", "performClick")


def strip_comments(text):
    """`text` without // and /* */ comments; string and character literals kept as they are."""
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            i = n if j < 0 else j + 2
        elif c in "\"'":
            j = i + 1
            while j < n and text[j] != c:
                j += 2 if text[j] == "\\" else 1
            out.append(text[i:j + 1])
            i = j + 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


def method_body(text, selector):
    """The brace-matched body of `- (void)<selector>(id)sender`, or None."""
    m = re.search(r"-\s*\(\s*void\s*\)\s*" + re.escape(selector) + r"\s*\(\s*id\s*\)\s*\w+\s*\{", text)
    if m is None:
        return None
    depth, i = 1, m.end()
    while i < len(text) and depth:
        depth += {"{": 1, "}": -1}.get(text[i], 0)
        i += 1
    return text[m.end():i - 1]


def statements_with(text, needle):
    """Each `;`-terminated statement of `text` that contains `needle`."""
    return [s for s in text.split(";") if needle in s]


def problems(files):
    """{name: source} of every src/*.m -> the contract's violations (empty: holds)."""
    if DRAWER not in files:
        return [f"src/{DRAWER} is missing"]
    code = {name: PROTOTYPE.sub("", strip_comments(text)) for name, text in files.items()}
    drawer = code[DRAWER]
    found = []
    for call, selector, title, other in (("zb_agent_tools_approve(", "approveClicked:", '@"Approve"', '@"Deny"'),
                                         ("zb_agent_tools_deny(", "denyClicked:", '@"Deny"', '@"Approve"')):
        sites = {name: text.count(call) for name, text in code.items() if call in text}
        body = method_body(drawer, selector)
        if body is None:
            found.append(f"no `- (void){selector}(id)sender` in {DRAWER}")
        elif sites != {DRAWER: 1} or body.count(call) != 1:
            found.append(f"{call} must be called exactly once, inside {selector} (call sites {sites})")
        wired = [s for text in code.values() for s in statements_with(text, f"@selector({selector})")]
        if len(wired) != 1 or title not in wired[0] or other in wired[0]:
            found.append(f"@selector({selector}) must appear once, wiring the {title} button ({len(wired)} sites)")
        name = selector[:-1]
        uses = sum(len(re.findall(r"\b" + name + r"\b", text)) for text in code.values())
        if uses != 2:  # its definition and its one @selector
            found.append(f"{name} is reachable another way ({uses} mentions; want its definition and one @selector)")
    for word in FORBIDDEN_IN_DRAWER:
        if word in drawer:
            found.append(f"{DRAWER} uses {word}")
    return found


HONEST = r'''
#import <AppKit/AppKit.h>
int zb_agent_tools_approve(unsigned long long card);
int zb_agent_tools_deny(unsigned long long card);
@implementation ZbCardView
- (instancetype)initWithCard:(unsigned long long)card {
  self = [super init];
  _card = card;
  _approve = [NSButton buttonWithTitle:@"Approve" target:self action:@selector(approveClicked:)];
  _deny = [NSButton buttonWithTitle:@"Deny" target:self action:@selector(denyClicked:)];
  return self;
}
/* the only minter: zb_agent_tools_approve() is called from here alone */
- (void)approveClicked:(id)sender {
  if (sender != _approve || !zb_agent_tools_approve(_card)) {  // a press on this card's own button only
    return;
  }
  [self settle:@"approved"];
}
- (void)denyClicked:(id)sender {
  if (sender == _deny && zb_agent_tools_deny(_card)) {
    [self settle:nil];
  }
}
@end
'''

MUTANTS = {
    "a keyboard shortcut mints": HONEST.replace("@end", "- (void)keyDown:(NSEvent *)e { zb_agent_tools_approve(_card); }\n@end"),
    "the selectors are swapped": HONEST.replace('@"Approve" target:self action:@selector(approveClicked:)',
                                                '@"Approve" target:self action:@selector(denyClicked:)')
                                       .replace('@"Deny" target:self action:@selector(denyClicked:)',
                                                '@"Deny" target:self action:@selector(approveClicked:)'),
    "a script message mints": HONEST.replace("@end", "- (void)userContentController:(WKUserContentController *)u "
                                                     "didReceiveScriptMessage:(id)m { [self approveClicked:nil]; }\n@end"),
    "a programmatic press": HONEST.replace("  return self;\n", "  [_approve performClick:nil];\n  return self;\n", 1),
    "a timer reaches the action": HONEST.replace("  return self;\n", "  [self performSelector:@selector(approveClicked:) "
                                                 "withObject:_approve afterDelay:1];\n  return self;\n", 1),
    "Deny mints": HONEST.replace("if (sender == _deny && zb_agent_tools_deny(_card))",
                                 "if (sender == _deny && zb_agent_tools_approve(_card) && zb_agent_tools_deny(_card))"),
}
SHIM_MINTS = "void zb_shim_auto(unsigned long long c) { zb_agent_tools_approve(c); }\n"


class CardAuthority(unittest.TestCase):
    def test_the_real_mac_sources_keep_the_one_minter(self):
        files = {p.name: p.read_text() for p in sorted(SRC.glob("*.m"))}
        self.assertEqual(problems(files), [])

    def test_the_honest_fixture_passes(self):
        self.assertEqual(problems({DRAWER: HONEST, "wkwebview_shim.m": "int x;\n"}), [])

    def test_comments_do_not_count(self):
        self.assertEqual(problems({DRAWER: HONEST + "// zb_agent_tools_approve(1); approveClicked\n",
                                   "wkwebview_shim.m": "/* zb_agent_tools_approve(2) */\n"}), [])

    def test_each_dishonest_fixture_fails(self):
        cases = dict(MUTANTS)
        for name, text in cases.items():
            with self.subTest(mutant=name):
                self.assertNotEqual(text, HONEST, "the mutation's anchor moved")
                self.assertNotEqual(problems({DRAWER: text, "wkwebview_shim.m": "int x;\n"}), [], name)
        with self.subTest(mutant="another file mints"):
            self.assertNotEqual(problems({DRAWER: HONEST, "wkwebview_shim.m": SHIM_MINTS}), [])


if __name__ == "__main__":
    unittest.main()
