"""MS7.4 (macOS plan line 2158; RoseCat 8058 / bdc8202 on 0281321): the AppKit drawer's conversation bubbles are INERT
text, as the GTK and Win32 drawers' are, and their text is the portable seam's (tests/agent_drawer_appkit_text_test.zig):
the shown form from zb_drawer_appkit_shown (break points, NUL and invalid UTF-8 shown as U+FFFD, always valid UTF-8), a
label up to label_text_max bytes and a read-only, non-rich text view past it (zb_drawer_bubble_is_label: a 200 KiB
reply stays responsive), and Copy giving the ORIGINAL bytes through zb_drawer_appkit_original_offset (originalOffset's
map over UTF-16 selection offsets).
Offline (no macOS SDK here), a source-bound oracle over src/agent_drawer_mac.m, read LEXICALLY: comments removed and
the contents of string and character literals blanked before any brace matching or call counting, so a brace or a
call name inside a string never counts.
- B1 one factory: every bubble view is made in `- (NSView *)bubbleWithText:(const char *)text length:(size_t)len`:
  +[NSTextField wrappingLabelWithString:] and [[NSTextView alloc] appear there and nowhere else, chosen by
  zb_drawer_bubble_is_label(len); no other text view or label constructor exists in the file.
- B2 one text path, bound to every production message path: every call that puts text into a view
  (wrappingLabelWithString:, setStringValue:, setString:, replaceCharactersInRange:, insertText:) is inside the
  factory or `- (void)setBubble:(NSView *)bubble text:(const char *)text length:(size_t)len` (the streaming update),
  and each of those two calls zb_drawer_appkit_shown exactly once, makes exactly one NSString, by
  -[NSString initWithBytes:<shown> length:<shown_len> encoding:NSUTF8StringEncoding] (exact length, never a
  NUL-terminated read), frees the shown buffer, and passes only that NSString (or it ?: @"") to its text setters. stringWithUTF8String / initWithUTF8String never appear.
- B3 inert controls: the label gets setSelectable:YES and setAllowsEditingTextAttributes:NO; the text view
  setEditable:NO, setRichText:NO, setImportsGraphics:NO and setAutomaticLinkDetectionEnabled:NO; the file never sets
  any of them to the other value.
- B4 no markup, data or links: no initWithHTML, initWithRTF, initWithRTFD, initWithData:, HTML/RTF document types,
  NSLinkAttributeName, (set)attributedStringValue, labelWithAttributedString: or NSTextAttachment.
- B5 copy gives the original bytes: exactly one `- (void)copy:(id)sender`; it maps the selection's two ends through
  zb_drawer_appkit_original_offset (twice) and puts the original's bytes on the pasteboard with setData: (never
  setString:, never the shown text).
Self-checking: an honest fixture passes; braces and call names inside strings and comments do not count; and each
dishonest fixture fails its rule.
RED until src/agent_drawer_mac.m exists with that shape. No process, no signal.
Run: cd tests/e2e && python3 -X dev -m unittest -v mac_drawer_bubble_inert_test
Unregistered until the green."""
import re
import unittest
from pathlib import Path

DRAWER = Path(__file__).resolve().parents[2] / "src" / "agent_drawer_mac.m"
FACTORY = r"-\s*\(\s*NSView\s*\*\s*\)\s*bubbleWithText:\s*\(\s*const\s+char\s*\*\s*\)\s*\w+\s+length:\s*\(\s*size_t\s*\)\s*\w+\s*\{"
UPDATE = (r"-\s*\(\s*void\s*\)\s*setBubble:\s*\(\s*NSView\s*\*\s*\)\s*\w+\s+text:\s*\(\s*const\s+char\s*\*\s*\)\s*\w+"
          r"\s+length:\s*\(\s*size_t\s*\)\s*\w+\s*\{")
COPY = r"-\s*\(\s*void\s*\)\s*copy:\s*\(\s*id\s*\)\s*\w+\s*\{"
TEXT_SETTERS = ("wrappingLabelWithString:", "setStringValue:", "setString:", "replaceCharactersInRange:", "insertText:")
OTHER_VIEWS = ("labelWithString:", "textFieldWithString:", "labelWithAttributedString:")
NEVER = ("stringWithUTF8String", "initWithUTF8String", "setSelectable:NO", "setAllowsEditingTextAttributes:YES",
         "setEditable:YES", "setRichText:YES", "setImportsGraphics:YES", "setAutomaticLinkDetectionEnabled:YES",
         "initWithHTML", "initWithRTF", "initWithRTFD", "initWithData:", "NSHTMLTextDocumentType",
         "NSRTFTextDocumentType", "NSLinkAttributeName", "setAttributedStringValue", "attributedStringValue",
         "NSTextAttachment")
PROTOTYPES = re.compile(r"^[ \t]*(?:extern[ \t]+)?[\w \t\*]+\bzb_drawer_\w+[ \t]*\([^)]*\)[ \t]*;", re.M)


def lexical(text):
    """`text` with comments removed and every string/character literal's contents blanked (its quotes kept, an
    Objective-C @"..." stays @""), so structure and calls are read from code alone."""
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
            out.append(q + q)
            i = j + 1
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


def spans(code, pattern):
    """(start, end) of each brace-matched body of `pattern` (which ends at its `{`) in lexical `code`."""
    found = []
    for m in re.finditer(pattern, code):
        depth, i = 1, m.end()
        while i < len(code) and depth:
            depth += {"{": 1, "}": -1}.get(code[i], 0)
            i += 1
        found.append((m.end(), i - 1))
    return found


def inside(pos, regions):
    return any(a <= pos < b for a, b in regions)


def text_path_problems(body, name):
    found = []
    if body.count("zb_drawer_appkit_shown(") != 1:
        found.append(f"B2: {name} must call zb_drawer_appkit_shown exactly once")
        return found
    shown = re.search(r"(\w+)\s*=\s*zb_drawer_appkit_shown\s*\(\s*\w+\s*,\s*\w+\s*,\s*&\s*(\w+)\s*\)", body)
    if shown is None:
        return found + [f"B2: {name} must keep zb_drawer_appkit_shown's result and length"]
    buf, length = shown.groups()
    exact = re.search(r"initWithBytes:\s*" + re.escape(buf) + r"\s+length:\s*" + re.escape(length)
                      + r"\s+encoding:\s*NSUTF8StringEncoding", body)
    if exact is None:
        found.append(f"B2: {name} must make its NSString with initWithBytes:{buf} length:{length} (exact length)")
    if not re.search(r"\bfree\s*\(\s*" + re.escape(buf) + r"\s*\)", body):
        found.append(f"B2: {name} must free the shown buffer")
    if body.count("initWithBytes:") != 1:
        found.append(f"B2: {name} must make exactly one NSString, the shown text's")
    plain = re.search(r"(\w+)\s*=\s*\[\s*\[\s*NSString\s+alloc\s*\]\s*initWithBytes:\s*" + re.escape(buf) + r"\b", body)
    for m in re.finditer(r"(?:" + "|".join(map(re.escape, TEXT_SETTERS[:3])) + r")\s*([^\]]+)\]", body):
        arg = re.fullmatch(r'(\w+)(?:\s*\?:\s*@"")?', m.group(1).strip())
        if plain is None or arg is None or arg.group(1) != plain.group(1):
            found.append(f"B2: {name} must put only the shown text's NSString into a view ({m.group(0).strip()[:60]})")
    return found


def problems(source):
    """agent_drawer_mac.m's source (None: missing) -> the contract's violations (empty: holds)."""
    if source is None:
        return ["src/agent_drawer_mac.m is missing"]
    code = PROTOTYPES.sub("", lexical(source))
    factory, update, copy = spans(code, FACTORY), spans(code, UPDATE), spans(code, COPY)
    found = []
    if len(factory) != 1:
        return found + [f"B1: want exactly one bubbleWithText:length: factory ({len(factory)})"]
    if len(update) != 1:
        return found + [f"B2: want exactly one setBubble:text:length: update ({len(update)})"]
    f_body, u_body = code[slice(*factory[0])], code[slice(*update[0])]
    for needle in ("wrappingLabelWithString:", "[[NSTextView alloc]"):
        sites = [m.start() for m in re.finditer(re.escape(needle), code)]
        if len(sites) != 1 or not inside(sites[0], factory):
            found.append(f"B1: {needle} must appear once, in the factory ({len(sites)} sites)")
    if "zb_drawer_bubble_is_label(" not in f_body:
        found.append("B1: the factory must choose label or text view by zb_drawer_bubble_is_label")
    for other in OTHER_VIEWS:
        if other in code:
            found.append(f"B1: another text view constructor ({other})")
    for setter in TEXT_SETTERS:
        for m in re.finditer(re.escape(setter), code):
            if not inside(m.start(), factory + update):
                found.append(f"B2: {setter} outside the factory and the update")
    found += text_path_problems(f_body, "the factory") + text_path_problems(u_body, "the update")
    if code.count("zb_drawer_appkit_shown(") != 2:
        found.append("B2: zb_drawer_appkit_shown is called outside the factory and the update")
    for need in ("setSelectable:YES", "setAllowsEditingTextAttributes:NO", "setEditable:NO", "setRichText:NO",
                 "setImportsGraphics:NO", "setAutomaticLinkDetectionEnabled:NO"):
        if need not in f_body:
            found.append(f"B3: the factory must call {need}")
    for word in NEVER:
        if word in code:
            found.append(f"B3/B4: {word}")
    if len(copy) != 1:
        found.append(f"B5: want exactly one copy: ({len(copy)})")
    else:
        c_body = code[slice(*copy[0])]
        if c_body.count("zb_drawer_appkit_original_offset(") != 2:
            found.append("B5: copy: must map both selection ends through zb_drawer_appkit_original_offset")
        if "setData:" not in c_body or "setString:" in c_body or "zb_drawer_appkit_shown(" in c_body:
            found.append("B5: copy: must put the original bytes with setData:, never a string or the shown text")
    return found


HONEST = r'''
#import <AppKit/AppKit.h>
char *zb_drawer_appkit_shown(const char *text, size_t len, size_t *out_len);
size_t zb_drawer_appkit_original_offset(const char *text, size_t len, size_t shown);
int zb_drawer_bubble_is_label(size_t len);
@implementation ZbDrawerView
/* a bubble: the seam's shown text, plain, selectable, never editable or rich ("{" in comments is fine) */
- (NSView *)bubbleWithText:(const char *)text length:(size_t)len {
  size_t shown_len = 0;
  char *shown = zb_drawer_appkit_shown(text, len, &shown_len);
  if (shown == NULL) {
    return nil;
  }
  NSString *plain = [[NSString alloc] initWithBytes:shown length:shown_len encoding:NSUTF8StringEncoding];
  free(shown);
  if (zb_drawer_bubble_is_label(len)) {
    NSTextField *label = [NSTextField wrappingLabelWithString:plain ?: @"{"];
    [label setSelectable:YES];
    [label setAllowsEditingTextAttributes:NO];
    return label;
  }
  NSTextView *view = [[NSTextView alloc] initWithFrame:NSZeroRect];
  [view setEditable:NO];
  [view setRichText:NO];
  [view setImportsGraphics:NO];
  [view setAutomaticLinkDetectionEnabled:NO];
  [view setSelectable:YES];
  [view setAllowsEditingTextAttributes:NO];
  [view setString:plain ?: @""];
  return view;
}
- (void)setBubble:(NSView *)bubble text:(const char *)text length:(size_t)len {
  size_t shown_len = 0;
  char *shown = zb_drawer_appkit_shown(text, len, &shown_len);
  if (shown == NULL) {
    return;
  }
  NSString *plain = [[NSString alloc] initWithBytes:shown length:shown_len encoding:NSUTF8StringEncoding];
  free(shown);
  if ([bubble isKindOfClass:[NSTextView class]]) {
    [(NSTextView *)bubble setString:plain ?: @""];
  } else {
    [(NSTextField *)bubble setStringValue:plain ?: @""];
  }
}
- (void)copy:(id)sender {
  NSRange r = [self selectedRange];
  size_t from = zb_drawer_appkit_original_offset(_text, _len, r.location);
  size_t to = zb_drawer_appkit_original_offset(_text, _len, r.location + r.length);
  NSPasteboard *pb = [NSPasteboard generalPasteboard];
  [pb clearContents];
  [pb setData:[NSData dataWithBytes:_text + from length:to - from] forType:NSPasteboardTypeString];
}
@end
'''


def mutate(old, new, count=1):
    assert HONEST.count(old) == count, old
    return HONEST.replace(old, new)


MUTANTS = {
    "a NUL-terminated read": mutate("[[NSString alloc] initWithBytes:shown length:shown_len encoding:NSUTF8StringEncoding];\n  free(shown);\n  if (zb",
                                    "[NSString stringWithUTF8String:shown];\n  free(shown);\n  if (zb"),
    "the length is not the shown length": mutate("initWithBytes:shown length:shown_len encoding:NSUTF8StringEncoding];\n  free(shown);\n  if (zb",
                                                 "initWithBytes:shown length:len encoding:NSUTF8StringEncoding];\n  free(shown);\n  if (zb"),
    "raw text bypasses the seam": mutate("    [(NSTextView *)bubble setString:plain ?: @\"\"];",
                                         "    [(NSTextView *)bubble setString:[[NSString alloc] initWithBytes:text length:len encoding:NSUTF8StringEncoding]];"),
    "a second text path": HONEST.replace("@end", "- (void)note:(NSTextField *)f { [f setStringValue:@\"x\"]; }\n@end"),
    "HTML text": mutate("    [label setSelectable:YES];", "    [label setSelectable:YES];\n    (void)[[NSAttributedString alloc] initWithHTML:nil documentAttributes:nil];"),
    "a link attribute": mutate("    [label setSelectable:YES];", "    [label setSelectable:YES];\n    (void)@{NSLinkAttributeName: plain};"),
    "an editable text view": mutate("  [view setEditable:NO];", "  [view setEditable:YES];"),
    "link detection on": mutate("  [view setAutomaticLinkDetectionEnabled:NO];", "  [view setAutomaticLinkDetectionEnabled:YES];"),
    "always a label": mutate("  if (zb_drawer_bubble_is_label(len)) {", "  if (1) {"),
    "the buffer leaks": HONEST.replace("  free(shown);\n  if (zb", "  if (zb", 1),
    "copy puts the shown string": mutate("  [pb setData:[NSData dataWithBytes:_text + from length:to - from] forType:NSPasteboardTypeString];",
                                         "  [pb setString:[[self textStorage] string] forType:NSPasteboardTypeString];"),
    "copy skips the map": mutate("  size_t to = zb_drawer_appkit_original_offset(_text, _len, r.location + r.length);",
                                 "  size_t to = r.location + r.length;"),
    "a second label constructor": HONEST.replace("@end", "- (NSView *)raw { return [NSTextField labelWithString:@\"\"]; }\n@end"),
    "an attachment": mutate("  [view setString:plain ?: @\"\"];", "  [view setString:plain ?: @\"\"];\n  (void)[NSTextAttachment new];"),
}


class BubbleInert(unittest.TestCase):
    def test_the_real_drawer_keeps_bubbles_inert(self):
        self.assertEqual(problems(DRAWER.read_text() if DRAWER.exists() else None), [])

    def test_the_honest_fixture_passes(self):
        self.assertEqual(problems(HONEST), [])

    def test_strings_and_comments_do_not_count(self):
        extra = ('// initWithHTML setEditable:YES zb_drawer_appkit_shown( setString:\n'
                 'static const char *k = "setStringValue: } { initWithHTML";\n')
        self.assertEqual(problems(HONEST + extra), [])

    def test_each_dishonest_fixture_fails(self):
        for name, text in MUTANTS.items():
            with self.subTest(mutant=name):
                self.assertNotEqual(text, HONEST, "the mutation's anchor moved")
                self.assertNotEqual(problems(text), [], name)


if __name__ == "__main__":
    unittest.main()
