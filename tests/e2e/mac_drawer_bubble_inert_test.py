"""MS7.4 (macOS plan line 2158): the AppKit drawer's conversation bubbles are INERT text, as the GTK and Win32 drawers'
are: plain characters that can be selected and copied, never markup, links, attachments or editable rich text, and
always the portable break-run form (zb_drawer_break_runs: long unbroken runs get break points; Copy maps back through
zb_drawer_original_offset). Offline (no macOS SDK here), a source-bound oracle over src/agent_drawer_mac.m, comments
removed:
- B1: a bubble's text view is made only by +[NSTextField wrappingLabelWithString:] (a plain NSString), inside
  `- (NSTextField *)bubbleWithText:(const char *)text length:(size_t)len`, and nowhere else in the file;
- B2: that method shows only zb_drawer_break_runs's output: it calls zb_drawer_break_runs once, builds the label's
  NSString from that result alone, and frees it with free();
- B3: the label is selectable and never editable or rich: setSelectable:YES and setAllowsEditingTextAttributes:NO in
  that method, and the file never sets setEditable:YES, setRichText:YES, setAllowsEditingTextAttributes:YES or
  setImportsGraphics:YES;
- B4: the file never builds attributed text from markup or data, nor a link: no initWithHTML, initWithRTF,
  initWithRTFD, initWithData:, NSHTMLTextDocumentType, NSRTFTextDocumentType, NSLinkAttributeName,
  setAutomaticLinkDetectionEnabled:YES, setAttributedStringValue, attributedStringValue or NSTextAttachment.
Self-checking: an honest fixture passes; each dishonest fixture (HTML text, RTF data, a link attribute, an editable
label, raw text bypassing break runs, a second label path, a leaked break-run buffer, an attachment) fails.
RED until src/agent_drawer_mac.m exists with that shape. No process, no signal.
Run: cd tests/e2e && python3 -X dev -m unittest -v mac_drawer_bubble_inert_test
Unregistered until the green."""
import re
import unittest
from pathlib import Path

DRAWER = Path(__file__).resolve().parents[2] / "src" / "agent_drawer_mac.m"
METHOD = r"-\s*\(\s*NSTextField\s*\*\s*\)\s*bubbleWithText:\s*\(\s*const\s+char\s*\*\s*\)\s*\w+\s+length:\s*\(\s*size_t\s*\)\s*\w+\s*\{"
# A declaration is not a call: `[extern] char *zb_drawer_break_runs(<params>);` is removed before counting.
PROTOTYPE = re.compile(r"^[ \t]*(?:extern[ \t]+)?char[ \t]*\*[ \t]*zb_drawer_break_runs[ \t]*\([^)]*\)[ \t]*;", re.M)
NEVER = ("setEditable:YES", "setRichText:YES", "setAllowsEditingTextAttributes:YES", "setImportsGraphics:YES",
         "initWithHTML", "initWithRTF", "initWithRTFD", "initWithData:", "NSHTMLTextDocumentType",
         "NSRTFTextDocumentType", "NSLinkAttributeName", "setAutomaticLinkDetectionEnabled:YES",
         "setAttributedStringValue", "attributedStringValue", "NSTextAttachment")


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


def body_of(text, pattern):
    m = re.search(pattern, text)
    if m is None:
        return None
    depth, i = 1, m.end()
    while i < len(text) and depth:
        depth += {"{": 1, "}": -1}.get(text[i], 0)
        i += 1
    return text[m.end():i - 1]


def problems(source):
    """agent_drawer_mac.m's source (None: missing) -> the contract's violations (empty: holds)."""
    if source is None:
        return ["src/agent_drawer_mac.m is missing"]
    code = PROTOTYPE.sub("", strip_comments(source))
    found = []
    body = body_of(code, METHOD)
    if body is None:
        return ["no `- (NSTextField *)bubbleWithText:(const char *)text length:(size_t)len`"]
    if code.count("wrappingLabelWithString:") != 1 or body.count("wrappingLabelWithString:") != 1:
        found.append("B1: a bubble label must be made once, by wrappingLabelWithString: in bubbleWithText:length:")
    for other in ("labelWithString:", "textFieldWithString:", "NSTextView", "labelWithAttributedString:"):
        if other in code:
            found.append(f"B1: another text path ({other})")
    calls = re.findall(r"(\w+)\s*=\s*zb_drawer_break_runs\s*\(", body)
    if len(calls) != 1 or code.count("zb_drawer_break_runs(") != 1:
        found.append("B2: zb_drawer_break_runs must be called exactly once, in bubbleWithText:length:")
    else:
        shown = calls[0]
        made = re.search(r"wrappingLabelWithString:\s*([^\]]*)\]", body)
        source_of = re.search(r"(\w+)\s*=\s*\[\s*NSString\s+stringWithUTF8String:\s*(\w+)\s*\]", body)
        arg = re.fullmatch(r'(\w+)(?:\s*\?:\s*@"")?', made.group(1).strip()) if made else None  # or the empty literal
        if arg is None or source_of is None or arg.group(1) != source_of.group(1) or source_of.group(2) != shown:
            found.append("B2: the label's string must come from zb_drawer_break_runs's result alone")
        if not re.search(r"\bfree\s*\(\s*" + re.escape(shown) + r"\s*\)", body):
            found.append("B2: the break-run buffer must be freed")
    for need in ("setSelectable:YES", "setAllowsEditingTextAttributes:NO"):
        if need not in body:
            found.append(f"B3: bubbleWithText:length: must call {need}")
    for word in NEVER:
        if word in code:
            found.append(f"B3/B4: {word}")
    return found


HONEST = r'''
#import <AppKit/AppKit.h>
char *zb_drawer_break_runs(const char *text, size_t len, size_t *out_len);
@implementation ZbDrawerView
/* a bubble: the break-run form of the text, plain, selectable, never editable or rich */
- (NSTextField *)bubbleWithText:(const char *)text length:(size_t)len {
  size_t shown_len = 0;
  char *shown = zb_drawer_break_runs(text, len, &shown_len);
  if (shown == NULL) {
    return nil;
  }
  NSString *plain = [NSString stringWithUTF8String:shown];
  free(shown);
  NSTextField *label = [NSTextField wrappingLabelWithString:plain ?: @""];
  [label setSelectable:YES];
  [label setAllowsEditingTextAttributes:NO];
  return label;
}
@end
'''

MUTANTS = {
    "HTML text": HONEST.replace("  return label;", "  NSAttributedString *h = [[NSAttributedString alloc] initWithHTML:"
                                "[plain dataUsingEncoding:NSUTF8StringEncoding] documentAttributes:nil];\n"
                                "  [label setAttributedStringValue:h];\n  return label;"),
    "RTF data": HONEST.replace("  return label;", "  (void)[[NSAttributedString alloc] initWithRTF:nil "
                               "documentAttributes:nil];\n  return label;"),
    "a link attribute": HONEST.replace("  return label;", "  (void)@{NSLinkAttributeName: plain};\n  return label;"),
    "an editable label": HONEST.replace("[label setSelectable:YES];", "[label setSelectable:YES];\n  [label setEditable:YES];"),
    "raw text bypasses break runs": HONEST.replace("[NSString stringWithUTF8String:shown]",
                                                   "[NSString stringWithUTF8String:text]"),
    "a second label path": HONEST.replace("@end", "- (NSTextField *)rawLabel:(NSString *)s { return [NSTextField "
                                          "labelWithString:s]; }\n@end"),
    "the break-run buffer leaks": HONEST.replace("  free(shown);\n", ""),
    "an attachment": HONEST.replace("  return label;", "  (void)[NSTextAttachment new];\n  return label;"),
    "a rich-editable label": HONEST.replace("setAllowsEditingTextAttributes:NO", "setAllowsEditingTextAttributes:YES"),
}


class BubbleInert(unittest.TestCase):
    def test_the_real_drawer_keeps_bubbles_inert(self):
        self.assertEqual(problems(DRAWER.read_text() if DRAWER.exists() else None), [])

    def test_the_honest_fixture_passes(self):
        self.assertEqual(problems(HONEST), [])

    def test_comments_do_not_count(self):
        self.assertEqual(problems(HONEST + "// initWithHTML NSLinkAttributeName setEditable:YES\n"), [])

    def test_each_dishonest_fixture_fails(self):
        for name, text in MUTANTS.items():
            with self.subTest(mutant=name):
                self.assertNotEqual(text, HONEST, "the mutation's anchor moved")
                self.assertNotEqual(problems(text), [], name)


if __name__ == "__main__":
    unittest.main()
