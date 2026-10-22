"""MS7.4 (macOS plan line 2158; RoseCat 8058 / bdc8202 / e48e262 on 0281321 and 7ba5549): the AppKit drawer's
conversation bubbles are INERT text whose content and copy come from the portable seam
(tests/agent_drawer_appkit_text_test.zig: zb_drawer_appkit_shown, zb_drawer_appkit_original_offset,
zb_drawer_bubble_is_label).
The responder path (e48e262 #1): a selectable NSTextField copies through the window's shared field editor, so a copy:
on any other object is never what Ctrl+C reaches. Every bubble is therefore one control class,
`@interface ZbBubbleView : NSTextView`: an NSTextView is itself the first responder of its selection, so ZbBubbleView's
own `- (void)copy:(id)sender` IS the Ctrl+C / Edit > Copy path, and each view keeps its own original bytes
(`_original`, `_originalLen`). The label_text_max boundary stays the responsiveness boundary: a bubble past it lays out
non-contiguously (`setAllowsNonContiguousLayout:`), so a 200 KiB reply stays responsive. The real-Mac clipboard check
on both sides of label_text_max stays an owner-run real-screen case.
Offline (no macOS SDK here), a source-bound oracle over src/agent_drawer_mac.m, read LEXICALLY (comments removed, the
contents of string and character literals blanked), binding each value structurally by exact statement (whitespace
ignored):
- V1 the control: `@interface ZbBubbleView : NSTextView` declares ivars `char *_original;` and `size_t _originalLen;`;
  the drawer has no NSTextField, no field-editor route (windowWillReturnFieldEditor / fieldEditor:) and no other
  NSTextView subclass or allocation: `[[ZbBubbleView alloc] initWithFrame:NSZeroRect]` is the one view constructor.
- V2 the factory `- (ZbBubbleView *)bubbleWithText:(const char *)text length:(size_t)len` makes `view` that way, sets
  setEditable:NO, setRichText:NO, setImportsGraphics:NO, setAutomaticLinkDetectionEnabled:NO, setSelectable:YES and
  setAllowsEditingTextAttributes:NO on `view`, binds the kind's result as exactly
  `[[view layoutManager] setAllowsNonContiguousLayout:!zb_drawer_bubble_is_label(len)]` (the only mention of
  zb_drawer_bubble_is_label), fills it with exactly `[self setBubble:view text:text length:len]`, and returns `view`.
- V3 the one text path `- (void)setBubble:(ZbBubbleView *)bubble text:(const char *)text length:(size_t)len` (every
  message path: the factory and each streaming update go through it; it is the file's only text setter):
  `char *shown = zb_drawer_appkit_shown(text, len, &shown_len)`, exactly one NSString
  `NSString *plain = [[NSString alloc] initWithBytes:shown length:shown_len encoding:NSUTF8StringEncoding]`,
  `free(shown)`, then exactly `[bubble keepOriginal:text length:len]` and `[bubble setString:plain ?: @""]`; no other
  setString:, setStringValue:, replaceCharactersInRange:, insertText: or initWithBytes: in the file, and
  zb_drawer_appkit_shown nowhere else.
- V4 the stored original: inside @implementation ZbBubbleView,
  `- (void)keepOriginal:(const char *)text length:(size_t)len` frees the old `_original`, allocates `len` bytes into
  `_original` (exactly `_original = malloc(len ? len : 1)`), copies exactly `memcpy(_original, text, len)` and sets
  exactly `_originalLen = len`.
- V5 the copy, inside @implementation ZbBubbleView: exactly one `- (void)copy:(id)sender` in the file; its selection
  is `NSRange r = [self selectedRange]`; its endpoints are exactly
  `size_t from = zb_drawer_appkit_original_offset(_original, _originalLen, r.location)` and
  `size_t to = zb_drawer_appkit_original_offset(_original, _originalLen, NSMaxRange(r))`; it writes exactly
  `[pb setData:[NSData dataWithBytes:_original + from length:to - from] forType:NSPasteboardTypeString]` to
  `NSPasteboard *pb = [NSPasteboard generalPasteboard]`, and never setString:.
- V6 inert, no markup: none of stringWithUTF8String, initWithUTF8String, setEditable:YES, setRichText:YES,
  setImportsGraphics:YES, setAutomaticLinkDetectionEnabled:YES, setAllowsEditingTextAttributes:YES, initWithHTML,
  initWithRTF, initWithRTFD, initWithData:, NSHTMLTextDocumentType, NSRTFTextDocumentType, NSLinkAttributeName,
  (set)attributedStringValue, labelWithAttributedString: or NSTextAttachment.
Self-checking: an honest fixture passes; names in strings and comments do not count; and each dishonest fixture fails,
including RoseCat's five (an inverted kind, a kind called and ignored before a constant, an update sent to _other, both
offsets mapping _other/_other_len, a payload from _other + from).
RED until src/agent_drawer_mac.m exists with that shape. No process, no signal.
Run: cd tests/e2e && python3 -X dev -m unittest -v mac_drawer_bubble_inert_test
Unregistered until the green."""
import re
import unittest
from pathlib import Path

DRAWER = Path(__file__).resolve().parents[2] / "src" / "agent_drawer_mac.m"
SIG_FACTORY = r"-\s*\(\s*ZbBubbleView\s*\*\s*\)\s*bubbleWithText:\s*\(\s*const\s+char\s*\*\s*\)\s*text\s+length:\s*\(\s*size_t\s*\)\s*len\s*\{"
SIG_UPDATE = (r"-\s*\(\s*void\s*\)\s*setBubble:\s*\(\s*ZbBubbleView\s*\*\s*\)\s*bubble\s+text:\s*\(\s*const\s+char\s*\*\s*\)"
              r"\s*text\s+length:\s*\(\s*size_t\s*\)\s*len\s*\{")
SIG_KEEP = r"-\s*\(\s*void\s*\)\s*keepOriginal:\s*\(\s*const\s+char\s*\*\s*\)\s*text\s+length:\s*\(\s*size_t\s*\)\s*len\s*\{"
SIG_COPY = r"-\s*\(\s*void\s*\)\s*copy:\s*\(\s*id\s*\)\s*\w+\s*\{"
NEVER = ("stringWithUTF8String", "initWithUTF8String", "setEditable:YES", "setRichText:YES", "setImportsGraphics:YES",
         "setAutomaticLinkDetectionEnabled:YES", "setAllowsEditingTextAttributes:YES", "initWithHTML", "initWithRTF",
         "initWithRTFD", "initWithData:", "NSHTMLTextDocumentType", "NSRTFTextDocumentType", "NSLinkAttributeName",
         "setAttributedStringValue", "attributedStringValue", "labelWithAttributedString:", "NSTextAttachment",
         "NSTextField", "windowWillReturnFieldEditor", "fieldEditor:")
PROTOTYPES = re.compile(r"^[ \t]*(?:extern[ \t]+)?[\w \t\*]+\bzb_drawer_\w+[ \t]*\([^)]*\)[ \t]*;", re.M)
FACTORY_NEEDS = ["ZbBubbleView*view=[[ZbBubbleViewalloc]initWithFrame:NSZeroRect]", "[viewsetEditable:NO]",
                 "[viewsetRichText:NO]", "[viewsetImportsGraphics:NO]", "[viewsetAutomaticLinkDetectionEnabled:NO]",
                 "[viewsetSelectable:YES]", "[viewsetAllowsEditingTextAttributes:NO]",
                 "[[viewlayoutManager]setAllowsNonContiguousLayout:!zb_drawer_bubble_is_label(len)]",
                 "[selfsetBubble:viewtext:textlength:len]", "returnview"]
UPDATE_NEEDS = ["char*shown=zb_drawer_appkit_shown(text,len,&shown_len)",
                "NSString*plain=[[NSStringalloc]initWithBytes:shownlength:shown_lenencoding:NSUTF8StringEncoding]",
                "free(shown)", "[bubblekeepOriginal:textlength:len]", '[bubblesetString:plain?:@""]']
KEEP_NEEDS = ["free(_original)", "_original=malloc(len?len:1)", "memcpy(_original,text,len)", "_originalLen=len"]
COPY_NEEDS = ["NSRanger=[selfselectedRange]", "size_tfrom=zb_drawer_appkit_original_offset(_original,_originalLen,r.location)",
              "size_tto=zb_drawer_appkit_original_offset(_original,_originalLen,NSMaxRange(r))",
              "NSPasteboard*pb=[NSPasteboardgeneralPasteboard]",
              "[pbsetData:[NSDatadataWithBytes:_original+fromlength:to-from]forType:NSPasteboardTypeString]"]


def lexical(text):
    """`text` with comments removed and every string/character literal's contents blanked (quotes kept)."""
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


def bodies(code, pattern):
    found = []
    for m in re.finditer(pattern, code):
        depth, i = 1, m.end()
        while i < len(code) and depth:
            depth += {"{": 1, "}": -1}.get(code[i], 0)
            i += 1
        found.append((m.start(), m.end(), i - 1))
    return found


def statements(body):
    """The squashed (whitespace-free) `;`-statements of a method body, block braces dropped."""
    return [re.sub(r"\s+", "", s).strip("{}") for s in re.split(r"[;{}]", body) if s.strip()]


def needs(body, wanted, where):
    have = statements(body)
    return [f"{where}: want exactly `{w}`" for w in wanted if w not in have]


def implementation(code, cls):
    m = re.search(r"@implementation\s+" + cls + r"\b(.*?)@end", code, re.S)
    return (m.start(1), m.end(1)) if m else None


def problems(source):
    """agent_drawer_mac.m's source (None: missing) -> the contract's violations (empty: holds)."""
    if source is None:
        return ["src/agent_drawer_mac.m is missing"]
    code = PROTOTYPES.sub("", lexical(source))
    found = []
    iface = re.search(r"@interface\s+ZbBubbleView\s*:\s*NSTextView\s*\{([^}]*)\}", code)
    if iface is None or "char*_original" not in re.sub(r"\s+", "", iface.group(1)) \
            or "size_t_originalLen" not in re.sub(r"\s+", "", iface.group(1)):
        found.append("V1: want `@interface ZbBubbleView : NSTextView { char *_original; size_t _originalLen; }`")
    if len(re.findall(r"@interface\s+\w+\s*:\s*NSTextView\b", code)) != 1 or code.count("[NSTextView alloc]") \
            or code.count("[[ZbBubbleView alloc]") != 1 and len(re.findall(r"\[\s*\[\s*ZbBubbleView\s+alloc\s*\]", code)) != 1:
        found.append("V1: ZbBubbleView must be the one NSTextView class and its one allocation")
    impl = implementation(code, "ZbBubbleView")
    for name, sig, wanted in (("V2 factory", SIG_FACTORY, FACTORY_NEEDS), ("V3 update", SIG_UPDATE, UPDATE_NEEDS)):
        got = bodies(code, sig)
        if len(got) != 1:
            found.append(f"{name}: want exactly one ({len(got)})")
        else:
            found += needs(code[got[0][1]:got[0][2]], wanted, name)
    if len(re.findall(r"\bzb_drawer_bubble_is_label\b", code)) != 1:
        found.append("V2: zb_drawer_bubble_is_label must be named once, in the bound layout statement")
    for name, sig, wanted in (("V4 keepOriginal", SIG_KEEP, KEEP_NEEDS), ("V5 copy", SIG_COPY, COPY_NEEDS)):
        got = bodies(code, sig)
        if len(got) != 1:
            found.append(f"{name}: want exactly one ({len(got)})")
        elif impl is None or not (impl[0] <= got[0][0] < impl[1]):
            found.append(f"{name}: must be ZbBubbleView's own method (the responder Ctrl+C reaches)")
        else:
            found += needs(code[got[0][1]:got[0][2]], wanted, name)
            if name.startswith("V5") and "setString:" in code[got[0][1]:got[0][2]]:
                found.append("V5 copy: never setString:")
    update = bodies(code, SIG_UPDATE)
    inside = (lambda pos: bool(update) and update[0][1] <= pos < update[0][2])
    for setter in ("setString:", "setStringValue:", "replaceCharactersInRange:", "insertText:", "initWithBytes:",
                   "zb_drawer_appkit_shown("):
        for m in re.finditer(re.escape(setter), code):
            if not inside(m.start()):
                found.append(f"V3: {setter} outside setBubble:text:length:")
    for word in NEVER:
        if word in code:
            found.append(f"V6: {word}")
    return found


HONEST = r'''
#import <AppKit/AppKit.h>
char *zb_drawer_appkit_shown(const char *text, size_t len, size_t *out_len);
size_t zb_drawer_appkit_original_offset(const char *text, size_t len, size_t shown);
int zb_drawer_bubble_is_label(size_t len);

/* one bubble control: an NSTextView is its own first responder, so its copy: is the one Ctrl+C reaches */
@interface ZbBubbleView : NSTextView {
  char *_original;
  size_t _originalLen;
}
- (void)keepOriginal:(const char *)text length:(size_t)len;
@end

@implementation ZbBubbleView
- (void)keepOriginal:(const char *)text length:(size_t)len {
  free(_original);
  _original = malloc(len ? len : 1);
  memcpy(_original, text, len);
  _originalLen = len;
}
- (void)copy:(id)sender {
  NSRange r = [self selectedRange];
  size_t from = zb_drawer_appkit_original_offset(_original, _originalLen, r.location);
  size_t to = zb_drawer_appkit_original_offset(_original, _originalLen, NSMaxRange(r));
  NSPasteboard *pb = [NSPasteboard generalPasteboard];
  [pb clearContents];
  [pb setData:[NSData dataWithBytes:_original + from length:to - from] forType:NSPasteboardTypeString];
}
- (void)dealloc {
  free(_original);
}
@end

@implementation ZbDrawerView
- (ZbBubbleView *)bubbleWithText:(const char *)text length:(size_t)len {
  ZbBubbleView *view = [[ZbBubbleView alloc] initWithFrame:NSZeroRect];
  [view setEditable:NO];
  [view setRichText:NO];
  [view setImportsGraphics:NO];
  [view setAutomaticLinkDetectionEnabled:NO];
  [view setSelectable:YES];
  [view setAllowsEditingTextAttributes:NO];
  [[view layoutManager] setAllowsNonContiguousLayout:!zb_drawer_bubble_is_label(len)];
  [self setBubble:view text:text length:len];
  return view;
}
- (void)setBubble:(ZbBubbleView *)bubble text:(const char *)text length:(size_t)len {
  size_t shown_len = 0;
  char *shown = zb_drawer_appkit_shown(text, len, &shown_len);
  if (shown == NULL) {
    return;
  }
  NSString *plain = [[NSString alloc] initWithBytes:shown length:shown_len encoding:NSUTF8StringEncoding];
  free(shown);
  [bubble keepOriginal:text length:len];
  [bubble setString:plain ?: @"{"];
}
@end
'''


def mutate(old, new):
    assert HONEST.count(old) == 1, old
    return HONEST.replace(old, new)


MUTANTS = {
    # RoseCat e48e262's five
    "an inverted kind": mutate("setAllowsNonContiguousLayout:!zb_drawer_bubble_is_label(len)]",
                               "setAllowsNonContiguousLayout:zb_drawer_bubble_is_label(len)]"),
    "a kind called and ignored": mutate("  [[view layoutManager] setAllowsNonContiguousLayout:!zb_drawer_bubble_is_label(len)];",
                                        "  (void)zb_drawer_bubble_is_label(len);\n  if (1) {\n    [[view layoutManager] setAllowsNonContiguousLayout:YES];\n  }"),
    "an update sent to _other": mutate("  [bubble setString:plain ?: @\"{\"];", "  [_other setString:plain ?: @\"{\"];"),
    "offsets over _other": mutate("  size_t from = zb_drawer_appkit_original_offset(_original, _originalLen, r.location);\n"
                                  "  size_t to = zb_drawer_appkit_original_offset(_original, _originalLen, NSMaxRange(r));",
                                  "  size_t from = zb_drawer_appkit_original_offset(_other, _other_len, r.location);\n"
                                  "  size_t to = zb_drawer_appkit_original_offset(_other, _other_len, NSMaxRange(r));"),
    "a payload from _other": mutate("dataWithBytes:_original + from length:to - from]", "dataWithBytes:_other + from length:to - from]"),
    # the responder path and the binding
    "copy: on the drawer view": mutate("@end\n\n@implementation ZbDrawerView\n", "@end\n\n@implementation ZbDrawerView\n- (void)copy:(id)sender {}\n").replace(
        "- (void)copy:(id)sender {\n  NSRange", "- (void)copyBytes:(id)sender {\n  NSRange"),
    "a field editor route": mutate("@end\n\n@implementation ZbDrawerView\n",
                                   "@end\n\n@implementation ZbDrawerView\n- (id)windowWillReturnFieldEditor:(NSWindow *)w toObject:(id)o { return nil; }\n"),
    "an NSTextField label": mutate("  ZbBubbleView *view = [[ZbBubbleView alloc] initWithFrame:NSZeroRect];",
                                   "  ZbBubbleView *view = [[ZbBubbleView alloc] initWithFrame:NSZeroRect];\n  (void)[NSTextField wrappingLabelWithString:@\"\"];"),
    "the original is never kept": mutate("  [bubble keepOriginal:text length:len];\n", ""),
    "the shown text is kept": mutate("  [bubble keepOriginal:text length:len];", "  [bubble keepOriginal:shown length:shown_len];"),
    "a short memcpy": mutate("  memcpy(_original, text, len);", "  memcpy(_original, text, len - 1);"),
    "another view's selection": mutate("  NSRange r = [self selectedRange];", "  NSRange r = [_other selectedRange];"),
    "a one-sided endpoint": mutate("_originalLen, NSMaxRange(r));", "_originalLen, r.length);"),
    "a payload of the wrong length": mutate("length:to - from]", "length:to]"),
    "copy puts a string": mutate("  [pb clearContents];", "  [pb clearContents];\n  [pb setString:[self string] forType:NSPasteboardTypeString];"),
    "a NUL-terminated read": mutate("[[NSString alloc] initWithBytes:shown length:shown_len encoding:NSUTF8StringEncoding]",
                                    "[NSString stringWithUTF8String:shown]"),
    "a second text setter": mutate("  return view;\n", "  [view insertText:@\"x\"];\n  return view;\n"),
    "the factory fills another view": mutate("  [self setBubble:view text:text length:len];", "  [self setBubble:_other text:text length:len];"),
    "a plain NSTextView": mutate("  ZbBubbleView *view = [[ZbBubbleView alloc] initWithFrame:NSZeroRect];",
                                 "  ZbBubbleView *view = (ZbBubbleView *)[[NSTextView alloc] initWithFrame:NSZeroRect];"),
    "link detection on": mutate("  [view setAutomaticLinkDetectionEnabled:NO];", "  [view setAutomaticLinkDetectionEnabled:YES];"),
    "HTML": mutate("  free(shown);\n", "  free(shown);\n  (void)[[NSAttributedString alloc] initWithHTML:nil documentAttributes:nil];\n"),
}


class BubbleInert(unittest.TestCase):
    def test_the_real_drawer_keeps_bubbles_inert(self):
        self.assertEqual(problems(DRAWER.read_text() if DRAWER.exists() else None), [])

    def test_the_honest_fixture_passes(self):
        self.assertEqual(problems(HONEST), [])

    def test_strings_and_comments_do_not_count(self):
        extra = ('// NSTextField setString: initWithHTML zb_drawer_bubble_is_label\n'
                 'static const char *k = "setStringValue: } { fieldEditor: zb_drawer_appkit_shown(";\n')
        self.assertEqual(problems(HONEST + extra), [])

    def test_each_dishonest_fixture_fails(self):
        for name, text in MUTANTS.items():
            with self.subTest(mutant=name):
                self.assertNotEqual(text, HONEST, "the mutation's anchor moved")
                self.assertNotEqual(problems(text), [], name)


if __name__ == "__main__":
    unittest.main()
