"""MS7.4 (macOS plan line 2158; RoseCat 8058 / bdc8202 / e48e262 / 44ca58e): the AppKit drawer's conversation bubbles
are INERT text whose content and copy come from the portable seam (tests/agent_drawer_appkit_text_test.zig:
zb_drawer_appkit_shown, zb_drawer_appkit_original_offset, zb_drawer_bubble_layout_contiguous).
CONTRACT AMENDMENT (RoseCat 44ca58e #1; macOS plan MS7.4): on AppKit every bubble is ONE read-only control,
`@interface ZbBubbleView : NSTextView`, instead of the GTK split (a label up to label_text_max, a text view past it).
A selectable NSTextField copies through the window's shared field editor, so a label kind would need a second copy
route through the window delegate (windowWillReturnFieldEditor:toObject:), shared with every other field in the
window. An NSTextView is itself the first responder of its selection, so ZbBubbleView's own copy: is the one route.
label_text_max stays the responsiveness boundary as the bubble's LAYOUT: up to it contiguous, past it
non-contiguous (a 200 KiB reply). The portable seam says so (bubbleLayoutContiguous /
zb_drawer_bubble_layout_contiguous replace bubbleIsLabel / zb_drawer_bubble_is_label). Because setBubble:text:length:
applies it on every update, a streaming bubble that crosses the boundary changes layout in place (GTK swaps the widget).
The real-Mac clipboard checks on both sides of label_text_max stay owner-run real-screen cases. So does Edit > Copy
(Cmd+C), which reaches copy: only through a menu item whose target is the first responder.
Offline (no macOS SDK here), a source-bound oracle over src/agent_drawer_mac.m. The file is read LEXICALLY (comments
removed, string and character literal contents blanked) and cut into a token SHAPE: each `;`-statement, `{` and `}`
in order, with whitespace removed. So a bound body fixes its statements, their order, their count and their control
flow; a dead branch, an extra effect, a reorder or a removal changes the shape.
- V1 the control: `@interface ZbBubbleView : NSTextView` holds exactly the ivars `char *_original; size_t _originalLen;`
  and declares exactly `- (void)keepOriginal:(const char *)text length:(size_t)len;`. There is no category on it or on
  NSTextView / NSResponder, and no runtime method replacement.
- V2 its whole @implementation is exactly BUBBLE_IMPL, in order:
  - keepOriginal frees the old original and copies `len` bytes into a fresh one (malloc failure leaves it empty).
  - copy: writes the ORIGINAL bytes between the mapped endpoints of [self selectedRange] to a cleared general
    pasteboard.
  - Drag-out (dragSelectionWithEvent:offset:slideBack: -> NO), Services (validRequestorForSendType:returnType: ->
    nil) and the context menu (menuForEvent: -> nil) are closed, since they would carry the shown text.
  - dealloc frees the final original.
- V3 the factory `- (ZbBubbleView *)bubbleWithText:(const char *)text length:(size_t)len` is exactly FACTORY: one
  ZbBubbleView, read-only, plain, no link detection, selectable, filled through setBubble.
- V4 the one text path `- (void)setBubble:(ZbBubbleView *)bubble text:(const char *)text length:(size_t)len` is
  exactly UPDATE:
  1. shown = zb_drawer_appkit_shown, returning on NULL;
  2. one NSString from the shown bytes;
  3. free(shown);
  4. keepOriginal of the original;
  5. the layout `setAllowsNonContiguousLayout:!zb_drawer_bubble_layout_contiguous(len)`;
  6. setString.
- V5 the input: exactly one plain NSTextView, `_input`, set up by the contiguous block INPUT (rich text, graphics,
  link detection and attribute editing off). Its only text setter is `[_input setString:@""]`. It is never a bubble.
- V6 exclusivity: outside V1-V5's bound text (and the zb_drawer_* prototypes) the file names none of GUARDED: no
  other text setter, pasteboard write, copy:, layout or editability setter, original buffer, seam call, NSTextView,
  ZbBubbleView allocation or closed route. An NSTextField may only be a static `[NSTextField labelWithString:@"..."]`,
  optionally assigned to a local (never selectable or editable: those setters are guarded). The NEVER list (markup, NUL-terminated reads, field
  editor routes, swizzling, other pasteboard writers) appears nowhere.
Self-checking: an honest fixture passes; names in strings and comments do not count; and each dishonest fixture fails
for its own stated rule, including RoseCat 44ca58e's five:
- a correct layout under if (0), followed by a live constant one;
- a correct update, followed by a live _other update;
- a correct pasteboard write, followed by a live _other write;
- free(shown) moved before initWithBytes;
- a removed [pb clearContents].
RED until src/agent_drawer_mac.m exists with that shape. No process, no signal.
Run: cd tests/e2e && python3 -X dev -m unittest -v mac_drawer_bubble_inert_test
Unregistered until the green."""
import re
import unittest
from pathlib import Path

DRAWER = Path(__file__).resolve().parents[2] / "src" / "agent_drawer_mac.m"

BUBBLE_IFACE_IVARS = "char *_original; size_t _originalLen;"
BUBBLE_IFACE_DECLS = "- (void)keepOriginal:(const char *)text length:(size_t)len;"
BUBBLE_IMPL = r"""
- (void)keepOriginal:(const char *)text length:(size_t)len {
  free(_original);
  _original = malloc(len ? len : 1);
  if (_original == NULL) {
    _originalLen = 0;
    return;
  }
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
- (BOOL)dragSelectionWithEvent:(NSEvent *)event offset:(NSSize)mouseOffset slideBack:(BOOL)slideBack {
  return NO;
}
- (id)validRequestorForSendType:(NSPasteboardType)sendType returnType:(NSPasteboardType)returnType {
  return nil;
}
- (NSMenu *)menuForEvent:(NSEvent *)event {
  return nil;
}
- (void)dealloc {
  free(_original);
}
"""
FACTORY = r"""
- (ZbBubbleView *)bubbleWithText:(const char *)text length:(size_t)len {
  ZbBubbleView *view = [[ZbBubbleView alloc] initWithFrame:NSZeroRect];
  [view setEditable:NO];
  [view setRichText:NO];
  [view setImportsGraphics:NO];
  [view setAutomaticLinkDetectionEnabled:NO];
  [view setAllowsEditingTextAttributes:NO];
  [view setSelectable:YES];
  [self setBubble:view text:text length:len];
  return view;
}
"""
UPDATE = r"""
- (void)setBubble:(ZbBubbleView *)bubble text:(const char *)text length:(size_t)len {
  size_t shown_len = 0;
  char *shown = zb_drawer_appkit_shown(text, len, &shown_len);
  if (shown == NULL) {
    return;
  }
  NSString *plain = [[NSString alloc] initWithBytes:shown length:shown_len encoding:NSUTF8StringEncoding];
  free(shown);
  [bubble keepOriginal:text length:len];
  [[bubble layoutManager] setAllowsNonContiguousLayout:!zb_drawer_bubble_layout_contiguous(len)];
  [bubble setString:plain ?: @""];
}
"""
INPUT = r"""
  _input = [[NSTextView alloc] initWithFrame:NSZeroRect];
  [_input setRichText:NO];
  [_input setImportsGraphics:NO];
  [_input setAutomaticLinkDetectionEnabled:NO];
  [_input setAllowsEditingTextAttributes:NO];
"""
INPUT_IVAR = "NSTextView *_input;"
INPUT_CLEAR = '[_input setString:@""];'
GUARDED = ("setString:", "setStringValue:", "setAttributedString:", "replaceCharactersInRange:", "insertText:",
           "initWithBytes:", "zb_drawer_appkit_shown", "zb_drawer_appkit_original_offset",
           "zb_drawer_bubble_layout_contiguous", "keepOriginal:", "setAllowsNonContiguousLayout:", "setRichText:",
           "setImportsGraphics:", "setEditable:", "setAutomaticLinkDetectionEnabled:", "setAllowsEditingTextAttributes:",
           "setSelectable:", "NSPasteboard", "setData:", "clearContents", "_original", "copy:", "NSTextView",
           "dragSelectionWithEvent", "validRequestorForSendType", "menuForEvent", "setBubble:_input", "_input setString")
NEVER = ("stringWithUTF8String", "initWithUTF8String", "initWithHTML", "initWithRTF", "initWithRTFD", "initWithData:",
         "NSHTMLTextDocumentType", "NSRTFTextDocumentType", "NSLinkAttributeName", "attributedStringValue",
         "labelWithAttributedString:", "NSTextAttachment", "windowWillReturnFieldEditor", "fieldEditor:",
         "objc/runtime.h", "method_exchangeImplementations", "class_replaceMethod", "class_addMethod",
         "method_setImplementation", "writeSelectionToPasteboard", "writeObjects:", "setPropertyList:", "declareTypes:",
         "NSSharingService")
PROTOTYPES = re.compile(r"^[ \t]*(?:extern[ \t]+)?[\w \t\*]+\bzb_drawer_\w+[ \t]*\([^)]*\)[ \t]*;", re.M)
SIG_FACTORY = r"-\s*\(\s*ZbBubbleView\s*\*\s*\)\s*bubbleWithText:"
SIG_UPDATE = r"-\s*\(\s*void\s*\)\s*setBubble:"


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


def shape(code):
    """The token shape of (lexical) code: each `;`-statement, `{` and `}` in order, whitespace removed."""
    out, cur = [], []
    for ch in code:
        if ch in "{}":
            if "".join(cur).strip():
                out.append(re.sub(r"\s+", "", "".join(cur)))
            out.append(ch)
            cur = []
        elif ch == ";":
            out.append(re.sub(r"\s+", "", "".join(cur)) + ";")
            cur = []
        else:
            cur.append(ch)
    if "".join(cur).strip():
        out.append(re.sub(r"\s+", "", "".join(cur)))
    return out


def block_end(code, open_brace):
    """The index just past the `}` matching the `{` at `open_brace`."""
    depth, i = 0, open_brace
    while i < len(code):
        depth += {"{": 1, "}": -1}.get(code[i], 0)
        i += 1
        if depth == 0:
            return i
    return len(code)


def methods(code, sig):
    """[(start, end)] of every method definition whose signature starts with `sig`."""
    found = []
    for m in re.finditer(sig, code):
        k = code.find("{", m.end())
        semi = code.find(";", m.end())
        if k < 0 or 0 <= semi < k:
            continue  # a declaration
        found.append((m.start(), block_end(code, k)))
    return found


def diff(where, got, want):
    if got == want:
        return []
    i = next((k for k, (a, b) in enumerate(zip(got, want)) if a != b), min(len(got), len(want)))
    g = got[i] if i < len(got) else "<end>"
    w = want[i] if i < len(want) else "<end>"
    return [f"{where}: differs at statement {i}: got `{g}`, want `{w}`"]


def problems(source):
    """agent_drawer_mac.m's source (None: missing) -> the contract's violations (empty: holds)."""
    if source is None:
        return ["src/agent_drawer_mac.m is missing"]
    code = PROTOTYPES.sub("", lexical(source))
    found, bound = [], []
    # V1 the interface
    ifaces = list(re.finditer(r"@interface\s+ZbBubbleView\s*:\s*NSTextView\s*\{", code))
    if len(ifaces) != 1:
        found.append(f"V1: want exactly one `@interface ZbBubbleView : NSTextView {{` ({len(ifaces)})")
    else:
        k = code.find("{", ifaces[0].start())
        ivars_end = block_end(code, k)
        end = code.find("@end", ivars_end)
        found += diff("V1 ivars", shape(code[k + 1:ivars_end - 1]), shape(lexical(BUBBLE_IFACE_IVARS)))
        found += diff("V1 declarations", shape(code[ivars_end:end]), shape(lexical(BUBBLE_IFACE_DECLS)))
        bound.append((ifaces[0].start(), end + 4))
    if re.search(r"@(?:interface|implementation)\s+(?:ZbBubbleView|NSTextView|NSText|NSResponder|NSView)\s*\(", code):
        found.append("V1: a category on the bubble's class chain")
    # V2 the implementation
    impls = list(re.finditer(r"@implementation\s+ZbBubbleView\b", code))
    if len(impls) != 1:
        found.append(f"V2: want exactly one @implementation ZbBubbleView ({len(impls)})")
    else:
        end = code.find("@end", impls[0].end())
        found += diff("V2 ZbBubbleView", shape(code[impls[0].end():end]), shape(lexical(BUBBLE_IMPL)))
        bound.append((impls[0].start(), end + 4))
    # V3 / V4 the factory and the one text path
    for name, sig, want in (("V3 factory", SIG_FACTORY, FACTORY), ("V4 setBubble", SIG_UPDATE, UPDATE)):
        got = methods(code, sig)
        if len(got) != 1:
            found.append(f"{name}: want exactly one definition ({len(got)})")
            continue
        found += diff(name, shape(code[got[0][0]:got[0][1]]), shape(lexical(want)))
        bound.append(got[0])
    # V5 the input
    flat = shape(code)
    want_input = shape(lexical(INPUT))
    at = [i for i in range(len(flat)) if flat[i:i + len(want_input)] == want_input]
    if len(at) != 1:
        found.append(f"V5 input: want exactly one `_input` set-up block INPUT ({len(at)})")
    for stmt in (INPUT, INPUT_IVAR, INPUT_CLEAR):
        pattern = r"\s*".join(re.escape(t) for t in "".join(shape(lexical(stmt))))
        for m in re.finditer(pattern, code):
            bound.append((m.start(), m.end()))
    if len(re.findall(r"\s*".join(map(re.escape, INPUT_IVAR.replace(" ", ""))), code)) != 1:
        found.append("V5 input: want exactly one `NSTextView *_input;`")
    # V6 exclusivity
    rest, last = [], 0
    for s, e in sorted(bound):
        if s >= last:
            rest.append(code[last:s])
            last = e
    rest.append(code[last:])
    rest = "".join(rest)
    for word in GUARDED:
        if re.search(r"\s*".join(map(re.escape, word.replace(" ", ""))), rest):
            found.append(f"V6: {word} outside the bound text")
    if re.search(r"\[\s*ZbBubbleView\s+alloc\b", rest):
        found.append("V6: a ZbBubbleView allocated outside the factory")
    labels = re.sub(r'(?:\bNSTextField\s*\*\s*\w+\s*=\s*)?\[\s*NSTextField\s+labelWithString:\s*@""\s*\]', "", rest)
    if re.search(r"\bNSTextField\b", labels):
        found.append("V6: an NSTextField other than a static [NSTextField labelWithString:@\"...\"]")
    for word in NEVER:
        if word in code:
            found.append(f"V6: {word}")
    return found


HONEST = r'''
#import <AppKit/AppKit.h>
char *zb_drawer_appkit_shown(const char *text, size_t len, size_t *out_len);
size_t zb_drawer_appkit_original_offset(const char *text, size_t len, size_t shown);
int zb_drawer_bubble_layout_contiguous(size_t len);

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
  if (_original == NULL) {
    _originalLen = 0;
    return;
  }
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
- (BOOL)dragSelectionWithEvent:(NSEvent *)event offset:(NSSize)mouseOffset slideBack:(BOOL)slideBack {
  return NO;
}
- (id)validRequestorForSendType:(NSPasteboardType)sendType returnType:(NSPasteboardType)returnType {
  return nil;
}
- (NSMenu *)menuForEvent:(NSEvent *)event {
  return nil;
}
- (void)dealloc {
  free(_original);
}
@end

@interface ZbDrawerView : NSView {
  NSTextView *_input;
  NSStackView *_rows;
}
@end

@implementation ZbDrawerView
- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  NSTextField *title = [NSTextField labelWithString:@"Claude Agent"];
  [self addSubview:title];
  _input = [[NSTextView alloc] initWithFrame:NSZeroRect];
  [_input setRichText:NO];
  [_input setImportsGraphics:NO];
  [_input setAutomaticLinkDetectionEnabled:NO];
  [_input setAllowsEditingTextAttributes:NO];
  [self addSubview:_input];
  return self;
}
- (void)sent {
  [_input setString:@""];
}
- (ZbBubbleView *)bubbleWithText:(const char *)text length:(size_t)len {
  ZbBubbleView *view = [[ZbBubbleView alloc] initWithFrame:NSZeroRect];
  [view setEditable:NO];
  [view setRichText:NO];
  [view setImportsGraphics:NO];
  [view setAutomaticLinkDetectionEnabled:NO];
  [view setAllowsEditingTextAttributes:NO];
  [view setSelectable:YES];
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
  [[bubble layoutManager] setAllowsNonContiguousLayout:!zb_drawer_bubble_layout_contiguous(len)];
  [bubble setString:plain ?: @"{"];
}
- (void)post:(const char *)text length:(size_t)len {
  [_rows addArrangedSubview:[self bubbleWithText:text length:len]];
}
@end
'''


def mutate(old, new):
    assert HONEST.count(old) == 1, old
    return HONEST.replace(old, new)


LAYOUT = "  [[bubble layoutManager] setAllowsNonContiguousLayout:!zb_drawer_bubble_layout_contiguous(len)];\n"
MUTANTS = {  # name -> (source, the rule it must fail)
    # RoseCat 44ca58e's five
    "a correct layout under if (0), then a live constant one": (
        mutate(LAYOUT, "  if (0) {\n  " + LAYOUT + "  }\n  [[bubble layoutManager] setAllowsNonContiguousLayout:YES];\n"), "V4 setBubble"),
    "a correct update, then a live _other update": (
        mutate('  [bubble setString:plain ?: @"{"];\n', '  [bubble setString:plain ?: @"{"];\n  [_other setString:plain ?: @""];\n'),
        "V4 setBubble"),
    "a correct pasteboard write, then a live _other write": (
        mutate("forType:NSPasteboardTypeString];\n}",
               "forType:NSPasteboardTypeString];\n  [pb setData:[NSData dataWithBytes:_other + from length:to - from] "
               "forType:NSPasteboardTypeString];\n}"), "V2 ZbBubbleView"),
    "free(shown) before initWithBytes": (
        mutate("  NSString *plain = [[NSString alloc] initWithBytes:shown length:shown_len encoding:NSUTF8StringEncoding];\n  free(shown);\n",
               "  free(shown);\n  NSString *plain = [[NSString alloc] initWithBytes:shown length:shown_len encoding:NSUTF8StringEncoding];\n"),
        "V4 setBubble"),
    "no clearContents": (mutate("  [pb clearContents];\n", ""), "V2 ZbBubbleView"),
    # the final original, the stored original, the copy
    "the final original leaks": (mutate("- (void)dealloc {\n  free(_original);\n}\n", ""), "V2 ZbBubbleView"),
    "dealloc frees nothing": (mutate("- (void)dealloc {\n  free(_original);\n}\n", "- (void)dealloc {\n}\n"), "V2 ZbBubbleView"),
    "the shown text is kept": (mutate("  [bubble keepOriginal:text length:len];", "  [bubble keepOriginal:shown length:shown_len];"),
                               "V4 setBubble"),
    "a short memcpy": (mutate("  memcpy(_original, text, len);", "  memcpy(_original, text, len - 1);"), "V2 ZbBubbleView"),
    "no malloc check": (mutate("  if (_original == NULL) {\n    _originalLen = 0;\n    return;\n  }\n", ""), "V2 ZbBubbleView"),
    "another view's selection": (mutate("  NSRange r = [self selectedRange];", "  NSRange r = [_other selectedRange];"), "V2 ZbBubbleView"),
    "a one-sided endpoint": (mutate("_originalLen, NSMaxRange(r));", "_originalLen, r.length);"), "V2 ZbBubbleView"),
    # the layout kind
    "an inverted layout": (mutate("setAllowsNonContiguousLayout:!zb_drawer_bubble_layout_contiguous(len)]",
                                  "setAllowsNonContiguousLayout:zb_drawer_bubble_layout_contiguous(len)]"), "V4 setBubble"),
    "the layout set only when made (a streaming bubble never crosses)": (
        mutate(LAYOUT, "").replace("  [self setBubble:view text:text length:len];\n",
                                   "  [[view layoutManager] setAllowsNonContiguousLayout:!zb_drawer_bubble_layout_contiguous(len)];\n"
                                   "  [self setBubble:view text:text length:len];\n"), "V3 factory"),
    # the routes the shown text could leave by
    "copy: on the drawer view": (mutate("- (void)sent {", "- (void)copy:(id)sender {\n}\n- (void)sent {"), "V6: copy:"),
    "drag-out left open": (mutate("- (BOOL)dragSelectionWithEvent:(NSEvent *)event offset:(NSSize)mouseOffset slideBack:(BOOL)slideBack {\n  return NO;\n}\n", ""),
                           "V2 ZbBubbleView"),
    "Services left open": (mutate("- (id)validRequestorForSendType:(NSPasteboardType)sendType returnType:(NSPasteboardType)returnType {\n  return nil;\n}\n", ""),
                           "V2 ZbBubbleView"),
    "the default context menu (Share)": (mutate("- (NSMenu *)menuForEvent:(NSEvent *)event {\n  return nil;\n}\n", ""), "V2 ZbBubbleView"),
    "a field editor route": (mutate("- (void)sent {", "- (id)windowWillReturnFieldEditor:(NSWindow *)w toObject:(id)o {\n  return nil;\n}\n- (void)sent {"),
                             "V6: windowWillReturnFieldEditor"),
    "a selectable NSTextField label": (mutate('[NSTextField labelWithString:@"Claude Agent"]', '[NSTextField wrappingLabelWithString:@"Claude Agent"]'),
                                       "V6: an NSTextField other than"),
    "a category overriding copy:": (mutate("@interface ZbDrawerView", "@implementation ZbBubbleView (Copy)\n- (void)copy:(id)sender {\n}\n@end\n\n@interface ZbDrawerView"),
                                    "V1: a category"),
    "a swizzled copy:": (mutate("#import <AppKit/AppKit.h>\n", "#import <AppKit/AppKit.h>\n#import <objc/runtime.h>\n"), "V6: objc/runtime.h"),
    # the bubbles and the input
    "a second, plain NSTextView bubble": (mutate("  [_rows addArrangedSubview:[self bubbleWithText:text length:len]];",
                                                 "  [_rows addArrangedSubview:[[NSTextView alloc] initWithFrame:NSZeroRect]];"), "V6: NSTextView"),
    "a second ZbBubbleView made elsewhere": (mutate("  [_rows addArrangedSubview:[self bubbleWithText:text length:len]];",
                                                    "  [_rows addArrangedSubview:[[ZbBubbleView alloc] initWithFrame:NSZeroRect]];"),
                                             "V6: a ZbBubbleView allocated outside the factory"),
    "the input shows the conversation": (mutate('  [_input setString:@""];', "  [_input setString:@\"\" ];\n  [_input setString:[_rows description]];"),
                                         "V6: setString:"),
    "a rich input": (mutate("  [_input setRichText:NO];", "  [_input setRichText:YES];"), "V5 input"),
    "the input made a bubble": (mutate("- (void)sent {\n", "- (void)sent {\n  [self setBubble:_input text:NULL length:0];\n"),
                                "V6: setBubble:_input"),
    "a second keepOriginal caller": (mutate("- (void)sent {\n", "- (void)sent {\n  [(ZbBubbleView *)nil keepOriginal:NULL length:0];\n"),
                                     "V6: keepOriginal:"),
    "a NUL-terminated read": (mutate("[[NSString alloc] initWithBytes:shown length:shown_len encoding:NSUTF8StringEncoding]",
                                     "[NSString stringWithUTF8String:shown]"), "V4 setBubble"),
    "editable bubbles": (mutate("  [view setEditable:NO];", "  [view setEditable:YES];"), "V3 factory"),
    "HTML": (mutate("  free(shown);\n", "  free(shown);\n  (void)[[NSAttributedString alloc] initWithHTML:nil documentAttributes:nil];\n"),
             "V6: initWithHTML"),
}


class BubbleInert(unittest.TestCase):
    def test_the_real_drawer_keeps_bubbles_inert(self):
        self.assertEqual(problems(DRAWER.read_text() if DRAWER.exists() else None), [])

    def test_the_honest_fixture_passes(self):
        self.assertEqual(problems(HONEST), [])

    def test_strings_and_comments_do_not_count(self):
        extra = ('// NSTextField setString: initWithHTML zb_drawer_bubble_layout_contiguous copy:\n'
                 'static const char *k = "setStringValue: } { fieldEditor: zb_drawer_appkit_shown( _original";\n')
        self.assertEqual(problems(HONEST + extra), [])

    def test_each_dishonest_fixture_fails_for_its_rule(self):
        for name, (text, rule) in MUTANTS.items():
            with self.subTest(mutant=name):
                self.assertNotEqual(text, HONEST, "the mutation's anchor moved")
                found = problems(text)
                self.assertTrue(any(f.startswith(rule) for f in found), (name, found))


if __name__ == "__main__":
    unittest.main()
