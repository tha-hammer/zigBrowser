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
- V0 the tokens mean what they say (RoseCat 8101 / 07e55fd #1):
  - The drawer's preprocessing is exactly DRAWER_DIRECTIVES, in order: its imports and includes, its own header, and
    the three portable #defines. Its header's preprocessing is exactly HEADER_DIRECTIVES (the include guard and two
    includes). So no #if hides an implementation, and no macro (#define NO YES) changes a bound token.
  - No digraph directive (%:), _Pragma or line splice anywhere in the drawer or its header.
  - The drawer is in the macOS link, and that link is bound EXACTLY by the card oracle's mac_build_problems
    (RoseCat 8112 #1/#2): configureMacosBackend equals the reviewed text, so every source and the whole clang argv are
    fixed. There is no source through a variable, no -D / -Wp forwarding / response file / -trigraphs, and no
    unreviewed member access on root_module, exe or site_options_module.
- V1 the control: `@interface ZbBubbleView : NSTextView` holds exactly the ivars `char *_original; size_t _originalLen;`
  and declares exactly `- (void)keepOriginal:(const char *)text length:(size_t)len;`. There is no category on it or on
  NSTextView / NSResponder, and no runtime method replacement.
- V2 its whole @implementation is exactly BUBBLE_IMPL, in order:
  - keepOriginal frees the old original and copies `len` bytes into a fresh one (malloc failure leaves it empty).
  - copy: refuses a missing original first (an allocation failure copies nothing: no pointer arithmetic on NULL,
    RoseCat 8101 #3), then writes the ORIGINAL bytes between the mapped endpoints of [self selectedRange] to a
    cleared general pasteboard.
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
  editor routes, swizzling, other pasteboard writers) and RUNTIME_REWRITES appear nowhere.
- V8 the Edit menu is live (RoseCat 8129 #2): the shim holds exactly one `static void zb_install_edit_menu(NSApplication
  *application)` equal to REVIEWED_EDIT_MENU (an application-menu slot, then Edit with its one Copy item,
  `action:@selector(copy:) keyEquivalent:@"c"`, target nil, installed with setMainMenu:). It is named only there and
  in its one call, which must be the statement right after `[application
  setActivationPolicy:NSApplicationActivationPolicyRegular];` in zb_app_run's @autoreleasepool block (under no if, loop
  or block). So Cmd+C reaches the first responder: a bubble's copy:, or the page's. RED until the shim has it.
- V7 the rest of the link (RoseCat 8101 #2, 8112 #3/#4): every OTHER native source build.zig links on macOS (the
  shim and the C files) and every project header they include (quoted includes under src/, recursively; a missing
  one fails) holds:
  - no preprocessing that can rename a token: no ##, digraph, _Pragma, trigraph or line splice; every #define is a
    constant (a name, optionally an integer or a string); no #undef or #line; #pragma only `mark` / `clang
    diagnostic`;
  - no category or class extension on ANY class;
  - no RUNTIME_REWRITES (method exchange or replacement, isa swaps, class creation, lookup by name, sel_registerName);
  - no ZbBubbleView and no NSPasteboard;
  - no `copy :` selector token (whitespace allowed) outside the reviewed zb_install_edit_menu (V8);
  - no target or action set anywhere (setTarget:, a `.target` / `.action` property, a key-value-coding setter, a
    binding), and no ivar reflection or message send by hand (class_getInstanceVariable, object_setIvar,
    ivar_getOffset, objc_msgSend, method_invoke, ...), so the Copy item's target stays nil.
Self-checking: an honest drawer, header and link pass (the honest shim wires Edit > Copy and uses associated
objects); names in strings and comments do not count; and each dishonest drawer, header and link fails for its own
stated rule. Among them are RoseCat 8101's #if 0 and #define NO YES, a digraph, a _Pragma, a -D flag, categories,
swizzles, an isa swap, a pasteboard write or a copy: elsewhere in the link, and copy: past a failed allocation; and
RoseCat 44ca58e's five:
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

from mac_drawer_card_authority_test import HONEST_BUILD, mac_build_problems, macos_build_mutant, mac_link_sources

REPO = Path(__file__).resolve().parents[2]
DRAWER = "src/agent_drawer_mac.m"
HEADER = "src/agent_drawer_mac.h"
# The only preprocessing the drawer and its header may hold, exactly and in order (RoseCat 8101: no #if, no other
# #define, no macro may change what the bound tokens mean).
DRAWER_DIRECTIVES = ["#import <AppKit/AppKit.h>", "#import <WebKit/WebKit.h>", "#include <stdlib.h>",
                     "#include <string.h>", '#include "agent_drawer_mac.h"', "#define ZB_CARD_APPROVE 1",
                     "#define ZB_CARD_DENY 2", "#define ZB_GESTURE_DRAG 1"]
HEADER_DIRECTIVES = ["#ifndef ZB_AGENT_DRAWER_MAC_H", "#define ZB_AGENT_DRAWER_MAC_H", "#include <stddef.h>",
                     "#include <stdint.h>", "#endif"]
# Across EVERY linked native source (RoseCat 8101 #2): routes that would change a bubble's behavior at run time.
RUNTIME_REWRITES = ("method_exchangeImplementations", "method_setImplementation", "class_replaceMethod",
                    "class_addMethod", "imp_implementationWithBlock", "object_setClass", "objc_allocateClassPair",
                    "objc_registerClassPair", "objc_duplicateClass", "class_setSuperclass", "NSClassFromString",
                    "NSSelectorFromString", "sel_registerName", "sel_getUid", "objc_msgSend", "method_invoke",
                    # RoseCat 8129 #3: reaching an object's ivars (a menu item's _target) by reflection
                    "class_getInstanceVariable", "class_copyIvarList", "object_setIvar", "object_setIvarWithStrongDefault",
                    "object_getIvar", "object_setInstanceVariable", "object_getInstanceVariable", "ivar_getOffset")
# Any category or class extension, on any class (RoseCat 8112 #3: a macro can build the class name, so none at all).
CATEGORY = re.compile(r"@(?:interface|implementation)\s+\w+\s*\(")
# V8 (RoseCat 8112 #4, 3c0b7b3 #4, 8129 #2): the one copy: the rest of the link may name is the Edit menu's Copy item,
# and that menu is LIVE: the shim's one reviewed zb_install_edit_menu (an application-menu slot, then Edit with its
# one Copy item, target nil, installed as the main menu), called once, by the statement right after
# `[application setActivationPolicy:NSApplicationActivationPolicyRegular];` in zb_app_run's @autoreleasepool.
SHIM = "src/wkwebview_shim.m"
REVIEWED_EDIT_MENU = r"""static void zb_install_edit_menu(NSApplication *application) {
  NSMenu *bar = [[NSMenu alloc] initWithTitle:@""];
  [bar addItemWithTitle:@"" action:nil keyEquivalent:@""];
  NSMenuItem *edit = [bar addItemWithTitle:@"Edit" action:nil keyEquivalent:@""];
  NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Edit"];
  [menu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
  [edit setSubmenu:menu];
  [application setMainMenu:bar];
}"""
EDIT_MENU_SITE = re.compile(r"\[\s*application\s+setActivationPolicy\s*:\s*NSApplicationActivationPolicyRegular\s*\]\s*;"
                            r"\s*zb_install_edit_menu\s*\(\s*application\s*\)\s*;")
# No target or action is set anywhere in the rest of the link: no setter, property, key-value coding or binding.
TARGET_ROUTES = ((re.compile(r"\bsetTarget\s*:"), "setTarget:"), (re.compile(r"\.\s*(?:target|action)\b"), "a target/action property"),
                 (re.compile(r"\b(?:setValue|setValuesForKeysWithDictionary|setNilValueForKey|takeValue)\w*\s*:"),
                  "a key-value-coding setter"), (re.compile(r"\bbind\s*:"), "a binding (bind:)"))
# A macro the rest of the link may define: a name, optionally an integer or a string constant. Nothing a macro
# expands to can then be an identifier, a selector or a class (RoseCat 8112 #3).
CONSTANT_MACRO = re.compile(r'[A-Z][A-Z0-9_]*(?:\s+(?:-?\d+[uUlL]*|"(?:[^"\\\n]|\\.)*"))?')

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
  if (_original == NULL) {
    return;
  }
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
         "NSSharingService", "setValue:", "setValuesForKeysWithDictionary", "setNilValueForKey")
PROTOTYPES = re.compile(r"^[ \t]*(?:extern[ \t]+)?[\w \t\*]+\bzb_drawer_\w+[ \t]*\([^)]*\)[ \t]*;", re.M)
SIG_FACTORY = r"-\s*\(\s*ZbBubbleView\s*\*\s*\)\s*bubbleWithText:"
SIG_UPDATE = r"-\s*\(\s*void\s*\)\s*setBubble:"


def lexical(text, keep_strings=False):
    """`text` with comments removed and every string/character literal's contents blanked (quotes kept), or kept."""
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
            out.append(text[i:j + 1] if keep_strings else q + q)
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


# RoseCat 3c0b7b3 #3: in RAW text (before any lexing, strings included), any carriage return, any line splice (a
# backslash, optional horizontal whitespace, then a line end) and any trigraph is rejected.
RAW = ((re.compile(r"\r"), "a carriage return (CR / CRLF line ends)"),
       (re.compile(r"\\[ \t\f\v]*\n"), "a line splice"),
       (re.compile(r"\?\?[=/'()!<>-]"), "a trigraph"))
# Every include names its header by one literal; this is that header's name, and whether it was <angle> or "quoted".
INCLUDE = re.compile(r'^\s*#\s*(include|import|include_next)\b\s*(.*?)\s*$', re.M)
# Under -I src, a project header in src/ shadows a system header of the same name; so src/ may hold headers only under
# names no system header has (RoseCat 3c0b7b3 #2).
PROJECT_HEADER = re.compile(r"src/(?:agent_\w+|webkit_shim)\.h")


def raw_problems(where, text):
    return [f"{where}: {why}" for rx, why in RAW if rx.search(text)]


def includes(where, text):
    """([(header name, quoted)], violations): every include of `text`, each by exactly one literal name."""
    names, found = [], []
    for kind, rest in INCLUDE.findall(lexical(text, keep_strings=True)):
        m = re.fullmatch(r'<([^<>"]+)>|"([^"]+)"', rest)
        if kind == "include_next" or m is None:
            found.append(f"{where}: an include other than one literal <name> or \"name\" (`#{kind} {rest}`)")
            continue
        names.append((m.group(1) or m.group(2), m.group(2) is not None))
    return names, found


def directives(where, text, allowed):
    """V0: the file's preprocessing is exactly `allowed` (no digraph, _Pragma or line splice to hide one)."""
    found = raw_problems(f"V0 {where}", text)
    blank = lexical(text)
    for word, why in (("%:", "a digraph directive"), ("_Pragma", "a _Pragma")):
        if word in blank:
            found.append(f"V0 {where}: {why}")
    got = [re.sub(r"\s+", " ", line.strip()) for line in lexical(text, keep_strings=True).splitlines()
           if line.lstrip().startswith("#")]
    if got != allowed:
        extra = [d for d in got if d not in allowed] or got
        found.append(f"V0 {where}: preprocessing must be exactly {allowed} (got {extra})")
    return found


def native_closure(sources, read):
    """{path: text or None} of every linked native source but the drawer, and every header any of them includes that
    resolves to a file under src/ (the build's one -I), by <angle> or "quoted" name alike (RoseCat 3c0b7b3 #2)."""
    out, todo = {}, [p for p in sources if p != DRAWER]
    while todo:
        path = todo.pop()
        if path in out:
            continue
        out[path] = read(path)
        if out[path] is None:
            continue
        for name, quoted in includes(path, out[path])[0]:
            if quoted or read("src/" + name) is not None:  # a quoted one that is missing fails closed below
                todo.append("src/" + name)
    return out


def native_preprocessing(path, text):
    """V7: a linked source's (or header's) preprocessing can rename nothing."""
    found = raw_problems(f"V7 {path}", text) + [f"V7 {f}" for f in includes(path, text)[1]]
    blank = lexical(text)
    for word, why in (("##", "token pasting"), ("%:", "a digraph directive"), ("_Pragma", "a _Pragma")):
        if word in blank:
            found.append(f"V7 {path}: {why}")
    for line in lexical(text, keep_strings=True).splitlines():
        m = re.match(r"\s*#\s*(\w+)\s*(.*?)\s*$", line)
        if m is None:
            continue
        kind, rest = m.groups()
        if kind == "define" and not CONSTANT_MACRO.fullmatch(rest):
            found.append(f"V7 {path}: a macro other than a constant (`{line.strip()}`)")
        elif kind in ("undef", "line") or (kind == "pragma" and not re.match(r"(?:mark\b|clang\s+diagnostic\b)", rest)):
            found.append(f"V7 {path}: #{kind}")
    return found


def blank_same(text):
    """`text` without comments, every string literal's contents blanked to spaces: the offsets of lexical(text,
    keep_strings=True), so a span found in one cuts the other."""
    return re.sub(r'"(?:[^"\\\n]|\\.)*"', lambda m: '"' + " " * (len(m.group(0)) - 2) + '"', lexical(text, keep_strings=True))


def edit_menu_problems(text):
    """V8 over the shim -> (violations, the reviewed function's span to exempt from the copy: scan, or None)."""
    found, span = [], None
    kept, blank = lexical(text, keep_strings=True), blank_same(text)
    defs = [m for m in re.finditer(r"\bstatic\s+void\s+zb_install_edit_menu\s*\(", blank)]
    if len(defs) != 1:
        found.append(f"V8: want exactly one `static void zb_install_edit_menu(...)` in {SHIM} ({len(defs)})")
    else:
        end = block_end(blank, blank.find("{", defs[0].end()))
        if shape(kept[defs[0].start():end]) == shape(lexical(REVIEWED_EDIT_MENU, keep_strings=True)):
            span = (defs[0].start(), end)
        else:
            found.append("V8: zb_install_edit_menu differs from REVIEWED_EDIT_MENU")
    if len(re.findall(r"\bzb_install_edit_menu\b", blank)) != 2:
        found.append("V8: zb_install_edit_menu may be named only by its definition and its one call")
    runs = [m for m in re.finditer(r"\bint\s+zb_app_run\s*\(", blank) if blank.find(";", m.end()) > blank.find("{", m.end())]
    sites = list(EDIT_MENU_SITE.finditer(blank))
    ok = False
    if len(runs) == 1 and len(sites) == 1:
        start = blank.find("{", runs[0].end())
        end = block_end(blank, start)
        pool = re.match(r"\{\s*@autoreleasepool\s*\{", blank[start:])
        if pool and start < sites[0].start() < end:
            between = blank[start + pool.end():sites[0].start()]
            ok = between.count("{") == between.count("}")  # in the pool's own block: under no if, loop or block
    if not ok:
        found.append("V8: the Edit menu must be installed, unconditionally, by the statement right after "
                     "[application setActivationPolicy:NSApplicationActivationPolicyRegular] in zb_app_run's @autoreleasepool")
    return found, span


def link_problems(build_zig, sources, others, read=None, headers=()):
    """B / V0 / V7 over the macOS link: build.zig's macOS link is exactly the reviewed one (the card oracle's
    mac_build_problems: every source and the whole clang argv fixed), the drawer is in it, and no other linked native
    source or project header it includes (`others`: {path: text or None}) can rename a token, add a category, rewrite
    the runtime, name the bubble or the pasteboard, or name copy: beyond the Edit menu's one Copy item."""
    found = mac_build_problems(build_zig)
    if DRAWER not in sources:
        found.append(f"V0: {DRAWER} is not in the macOS link ({sources})")
    for h in sorted(headers):
        if not PROJECT_HEADER.fullmatch(h):
            found.append(f"V0: {h} may shadow a system header under -I src (project headers: src/agent_*.h, src/webkit_shim.h)")
    if read is not None:
        for where in (DRAWER, HEADER):
            text = read(where)
            for name, _ in (includes(where, text)[0] if text else []):
                if name != "agent_drawer_mac.h" and read("src/" + name) is not None:
                    found.append(f"V0 {where}: <{name}> resolves to src/{name}, not the system header")
    if others.get(SHIM) is None:
        found.append(f"V8: {SHIM} is not in the link")
    for path, text in sorted(others.items()):
        if text is None:
            found.append(f"V7 {path}: missing (included or linked, and unreadable)")
            continue
        found += native_preprocessing(path, text)
        code = lexical(text)
        if CATEGORY.search(code):
            found.append(f"V7 {path}: a category or class extension")
        for word in RUNTIME_REWRITES + ("ZbBubbleView", "NSPasteboard"):
            if re.search(r"\b" + word + r"\b", code):
                found.append(f"V7 {path}: {word}")
        rest = blank_same(text)
        if path == SHIM:
            menu, span = edit_menu_problems(text)
            found += menu
            if span:
                rest = rest[:span[0]] + rest[span[1]:]
        if re.search(r"\bcopy\s*:", rest):
            found.append(f"V7 {path}: copy: other than the reviewed Edit menu's Copy item")
        for rx, why in TARGET_ROUTES:
            if rx.search(code):
                found.append(f"V7 {path}: {why} (the Edit menu's Copy item keeps target nil)")
    return found


def problems(source, header=None):
    """agent_drawer_mac.m's source (None: missing) and its header -> the contract's violations (empty: holds)."""
    if source is None:
        return ["src/agent_drawer_mac.m is missing"]
    found = directives(DRAWER, source, DRAWER_DIRECTIVES)
    found += ([f"V0: {HEADER} is missing"] if header is None else directives(HEADER, header, HEADER_DIRECTIVES))
    code = PROTOTYPES.sub("", lexical(source))
    bound = []
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
    if CATEGORY.search(code):
        found.append("V1: a category or class extension")
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
    for word in NEVER + RUNTIME_REWRITES:
        if word in code:
            found.append(f"V6: {word}")
    return found


HONEST = r'''
#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>
#include <stdlib.h>
#include <string.h>

#include "agent_drawer_mac.h"

#define ZB_CARD_APPROVE 1
#define ZB_CARD_DENY 2
#define ZB_GESTURE_DRAG 1

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
  if (_original == NULL) {
    return;
  }
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


HONEST_HEADER = """/* the drawer's mount, called by the shim */
#ifndef ZB_AGENT_DRAWER_MAC_H
#define ZB_AGENT_DRAWER_MAC_H

#include <stddef.h>
#include <stdint.h>

void *zb_drawer_mac_mount(void *ns_window, void *wk_web_view, uint32_t window_id);

#endif
"""
BUILD = HONEST_BUILD
OTHERS = {
    "src/wkwebview_shim.m": """#include "webkit_shim.h"
#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
static const char *zb_names[] = {"alpha", """ + '"' + "x" * 600 + '"' + """};
""" + REVIEWED_EDIT_MENU + """
static void zb_tag(id window, id value) {
  objc_setAssociatedObject(window, "zb", value, OBJC_ASSOCIATION_RETAIN);
}
int zb_app_run(const char *uri, int print_title, int e2e_protocol) {
  @autoreleasepool {
    NSApplication *application = [NSApplication sharedApplication];
    [application setActivationPolicy:NSApplicationActivationPolicyRegular];
    zb_install_edit_menu(application);
    [application run];
  }
  return 0;
}
""",
    "src/agent_home_lock.c": "int zb_agent_home_lock(void) { return 0; }\n",
    "src/agent_spawn_posix.c": "#ifdef __APPLE__\n#include <spawn.h>\n#endif\n",
    "src/webkit_shim.h": """#ifndef ZB_WEBKIT_SHIM_H
#define ZB_WEBKIT_SHIM_H
#define ZB_MAX_WINDOWS 16
#define ZB_AUTOMATION_WORLD "zigbrowser-automation"
#define ZB_COOKIE_MAX_EXPIRES 253402300799LL
#endif
""",
}


def link_case(build=BUILD, **others):
    files = dict(OTHERS)
    for path, text in others.items():
        files[path.replace("_dot_", ".").replace("__", "/")] = text
    return build, files


def link_found(build, files):
    sources = mac_link_sources(build)
    return link_problems(build, sources, native_closure(sources, files.get), files.get,
                         [p for p in files if p.endswith(".h")])


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
    "copy : with spaces on the drawer view": (mutate("- (void)sent {", "- (void)copy : (id)sender {\n}\n- (void)sent {"), "V6: copy:"),
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
    "a swizzled copy:": (mutate("#import <AppKit/AppKit.h>\n", "#import <AppKit/AppKit.h>\n#import <objc/runtime.h>\n"),
                         "V0 src/agent_drawer_mac.m: preprocessing"),
    "a swizzle without the header": (mutate("- (void)sent {\n", "- (void)sent {\n  method_exchangeImplementations(NULL, NULL);\n"),
                                     "V6: method_exchangeImplementations"),
    # RoseCat 8101 #1: preprocessing
    "#if 0 around the implementation": (mutate("@implementation ZbBubbleView\n", "#if 0\n@implementation ZbBubbleView\n")
                                        .replace("  free(_original);\n}\n@end\n", "  free(_original);\n}\n@end\n#endif\n"),
                                        "V0 src/agent_drawer_mac.m: preprocessing"),
    "#define NO YES": (mutate("#define ZB_GESTURE_DRAG 1\n", "#define ZB_GESTURE_DRAG 1\n#define NO YES\n"),
                       "V0 src/agent_drawer_mac.m: preprocessing"),
    "a digraph #define": (mutate("#define ZB_GESTURE_DRAG 1\n", "#define ZB_GESTURE_DRAG 1\n%:define NO YES\n"),
                          "V0 src/agent_drawer_mac.m: a digraph directive"),
    "key-value coding on a bubble": (mutate("- (void)sent {\n", '- (void)sent {\n  [_input setValue:@YES forKey:@"richText"];\n'),
                                     "V6: setValue:"),
    "a CRLF splice in the drawer": (mutate("- (void)sent {\n", "- (void)sent {\n  [_input in\\\r\nsertText:@\"x\"];\n"),
                                    "V0 src/agent_drawer_mac.m: a carriage return"),
    "a _Pragma": (mutate("#define ZB_GESTURE_DRAG 1\n", "#define ZB_GESTURE_DRAG 1\n_Pragma(\"clang diagnostic ignored\")\n"),
                  "V0 src/agent_drawer_mac.m: a _Pragma"),
    # RoseCat 8101 #3: allocation failure
    "copy: past a failed allocation": (mutate("- (void)copy:(id)sender {\n  if (_original == NULL) {\n    return;\n  }\n",
                                              "- (void)copy:(id)sender {\n"), "V2 ZbBubbleView"),
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


HEADER_MUTANTS = {  # name -> (header text or None, the rule it must fail)
    "a macro in the drawer's header": (HONEST_HEADER.replace("#include <stdint.h>\n", "#include <stdint.h>\n#define NO YES\n"),
                                       "V0 src/agent_drawer_mac.h: preprocessing"),
    "the drawer's header is missing": (None, "V0: src/agent_drawer_mac.h is missing"),
}
LINK_MUTANTS = {  # name -> ((build.zig, {path: text}), the rule it must fail)
    "the drawer is not linked": (link_case(macos_build_mutant('    shim.addFileArg(b.path("src/agent_drawer_mac.m"));\n', "")),
                                 "V0: src/agent_drawer_mac.m is not in the macOS link"),
    "a -D flag on the shim": (link_case(macos_build_mutant('"-fobjc-arc",', '"-fobjc-arc", "-DNO=YES",')),
                              "B: fn configureMacosBackend differs"),
    # RoseCat 8112
    "a linked source through a variable": (link_case(macos_build_mutant('    shim.addFileArg(b.path("src/agent_drawer_mac.m"));\n',
                                                                  '    shim.addFileArg(b.path("src/agent_drawer_mac.m"));\n'
                                                                  '    const evil = b.path("src/evil.m");\n    shim.addFileArg(evil);\n')),
                                           "B: fn configureMacosBackend differs"),
    "a forwarded -Wp,-DNO=YES": (link_case(macos_build_mutant('"-fobjc-arc",', '"-fobjc-arc", "-Wp,-DNO=YES",')),
                                 "B: fn configureMacosBackend differs"),
    "a token-pasted category": (link_case(src__wkwebview_shim_dot_m=OTHERS["src/wkwebview_shim.m"]
                                          + "#define CAT(a, b) a##b\n@implementation CAT(ZbBubble, View) (Steal)\n- (void)x {\n}\n@end\n"),
                                "V7 src/wkwebview_shim.m: token pasting"),
    "a category through an aliasing macro": (link_case(src__wkwebview_shim_dot_m=OTHERS["src/wkwebview_shim.m"]
                                                       + "#define NSTV NSTextView\n@implementation NSTV (Steal)\n@end\n"),
                                             "V7 src/wkwebview_shim.m: a macro other than a constant"),
    "a category on another class": (link_case(src__wkwebview_shim_dot_m=OTHERS["src/wkwebview_shim.m"]
                                              + "@implementation NSWindow (Steal)\n@end\n"),
                                    "V7 src/wkwebview_shim.m: a category or class extension"),
    "a macro in the shim's header": (link_case(src__webkit_shim_dot_h=OTHERS["src/webkit_shim.h"].replace(
                                         "#endif\n", "#define copyText copy\n#endif\n")),
                                     "V7 src/webkit_shim.h: a macro other than a constant"),
    "an #undef": (link_case(src__webkit_shim_dot_h=OTHERS["src/webkit_shim.h"].replace("#endif\n", "#undef YES\n#endif\n")),
                  "V7 src/webkit_shim.h: #undef"),
    "the shim's header missing": (link_case(src__wkwebview_shim_dot_m=OTHERS["src/wkwebview_shim.m"].replace(
                                      '#include "webkit_shim.h"', '#include "webkit_shim2.h"')),
                                  "V7 src/webkit_shim2.h: missing"),
    "copy : with spaces in the shim": (link_case(src__wkwebview_shim_dot_m=OTHERS["src/wkwebview_shim.m"]
                                                 + "@implementation ZBWindow\n- (void)copy : (id)sender {\n}\n@end\n"),
                                       "V7 src/wkwebview_shim.m: copy: other than the reviewed Edit menu's Copy item"),
    "a Copy item with a target": (link_case(src__wkwebview_shim_dot_m=OTHERS["src/wkwebview_shim.m"]
                                            + "static void zb_t(NSMenuItem *i, id t) {\n  [i setTarget:t];\n}\n"),
                                  "V7 src/wkwebview_shim.m: setTarget:"),
    "a second Copy item": (link_case(src__wkwebview_shim_dot_m=OTHERS["src/wkwebview_shim.m"]
                                     + 'static void zb_m2(NSMenu *m) {\n  [m addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];\n}\n'),
                           "V7 src/wkwebview_shim.m: copy: other than the reviewed Edit menu's Copy item"),
    # RoseCat 3c0b7b3 #2: includes that reach src/ other than by a quoted literal
    "an <angle> include of a project header": (link_case(
        src__wkwebview_shim_dot_m=OTHERS["src/wkwebview_shim.m"].replace('#include "webkit_shim.h"', "#include <webkit_shim.h>"),
        src__webkit_shim_dot_h=OTHERS["src/webkit_shim.h"].replace("#endif\n", "#define NSTV NSTextView\n#endif\n")),
        "V7 src/webkit_shim.h: a macro other than a constant"),
    "an include by macro": (link_case(src__wkwebview_shim_dot_m=OTHERS["src/wkwebview_shim.m"].replace(
        '#include "webkit_shim.h"', '#define ZB_HEADER "webkit_shim.h"\n#include ZB_HEADER')),
        "V7 src/wkwebview_shim.m: an include other than one literal"),
    "an #include_next": (link_case(src__agent_home_lock_dot_c="#include_next <stdio.h>\n"),
                         "V7 src/agent_home_lock.c: an include other than one literal"),
    "a system header shadowed in src/": (link_case(src__stdlib_dot_h="#define NO YES\n",
                                                   src__agent_drawer_mac_dot_m=HONEST, src__agent_drawer_mac_dot_h=HONEST_HEADER),
                                         "V0: src/stdlib.h may shadow a system header"),
    "the drawer's <stdlib.h> resolving into src/": (link_case(src__stdlib_dot_h="#define NO YES\n",
                                                              src__agent_drawer_mac_dot_m=HONEST, src__agent_drawer_mac_dot_h=HONEST_HEADER),
                                                    "V0 src/agent_drawer_mac.m: <stdlib.h> resolves to src/stdlib.h"),
    "a framework header shadowed in src/": (link_case(src__AppKit__AppKit_dot_h="#define NO YES\n"),
                                            "V0: src/AppKit/AppKit.h may shadow a system header"),
    # RoseCat 3c0b7b3 #3: splices the C preprocessor joins
    "a CRLF line splice": (link_case(src__wkwebview_shim_dot_m=OTHERS["src/wkwebview_shim.m"] + "static void zb_c(id o, id s) {\n  [o co\\\r\npy:s];\n}\n"),
                           "V7 src/wkwebview_shim.m: a carriage return"),
    "a CR-only line end": (link_case(src__wkwebview_shim_dot_m=OTHERS["src/wkwebview_shim.m"] + "static int zb_r;\r"),
                           "V7 src/wkwebview_shim.m: a carriage return"),
    "a splice after trailing spaces": (link_case(src__wkwebview_shim_dot_m=OTHERS["src/wkwebview_shim.m"] + "static void zb_c(id o, id s) {\n  [o co\\  \npy:s];\n}\n"),
                                       "V7 src/wkwebview_shim.m: a line splice"),
    "a trigraph backslash": (link_case(src__wkwebview_shim_dot_m=OTHERS["src/wkwebview_shim.m"] + "static void zb_c(id o, id s) {\n  [o co??/\npy:s];\n}\n"),
                             "V7 src/wkwebview_shim.m: a trigraph"),
    # RoseCat 3c0b7b3 #4: the Copy item retargeted
    "the Copy item kept and given a target property": (link_case(src__wkwebview_shim_dot_m=OTHERS["src/wkwebview_shim.m"].replace(
        '  [menu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];\n',
        '  NSMenuItem *item = [menu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];\n  item.target = menu;\n')),
        "V7 src/wkwebview_shim.m: copy: other than the reviewed Edit menu's Copy item"),
    "a target property anywhere": (link_case(src__wkwebview_shim_dot_m=OTHERS["src/wkwebview_shim.m"]
                                             + "static void zb_t(NSMenu *m, id t) {\n  [m itemAtIndex:0].target = t;\n}\n"),
                                   "V7 src/wkwebview_shim.m: a target/action property"),
    "a target set by key-value coding": (link_case(src__wkwebview_shim_dot_m=OTHERS["src/wkwebview_shim.m"]
                                                   + 'static void zb_t(NSMenu *m, id t) {\n  [[m itemAtIndex:0] setValue:t forKey:@"target"];\n}\n'),
                                         "V7 src/wkwebview_shim.m: a key-value-coding setter"),
    "the Copy item retargeted inline": (link_case(src__wkwebview_shim_dot_m=OTHERS["src/wkwebview_shim.m"].replace(
        '  [menu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];\n',
        '  [[menu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"] setTarget:menu];\n')),
        "V7 src/wkwebview_shim.m: copy: other than the reviewed Edit menu's Copy item"),
    # RoseCat 8129 #2: the Copy item not on the live Edit menu
    "a Copy statement under if (0) elsewhere": (link_case(src__wkwebview_shim_dot_m=OTHERS["src/wkwebview_shim.m"]
                                                          + 'static void zb_d(NSMenu *m) {\n  if (0) {\n    [m addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];\n  }\n}\n'),
                                                "V7 src/wkwebview_shim.m: copy: other than the reviewed Edit menu's Copy item"),
    "a Copy item on a detached menu": (link_case(src__wkwebview_shim_dot_m=OTHERS["src/wkwebview_shim.m"]
                                                 + 'static void zb_d(void) {\n  NSMenu *m = [[NSMenu alloc] initWithTitle:@"x"];\n'
                                                   '  [m addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];\n}\n'),
                                       "V7 src/wkwebview_shim.m: copy: other than the reviewed Edit menu's Copy item"),
    "the Edit menu installed under if (0)": (link_case(src__wkwebview_shim_dot_m=OTHERS["src/wkwebview_shim.m"].replace(
        "    zb_install_edit_menu(application);\n", "    if (0) {\n      zb_install_edit_menu(application);\n    }\n")),
        "V8: the Edit menu must be installed, unconditionally"),
    "the Edit menu never installed": (link_case(src__wkwebview_shim_dot_m=OTHERS["src/wkwebview_shim.m"].replace("    zb_install_edit_menu(application);\n", "")),
                                      "V8: the Edit menu must be installed"),
    "the Edit menu installed elsewhere": (link_case(src__wkwebview_shim_dot_m=OTHERS["src/wkwebview_shim.m"].replace("    zb_install_edit_menu(application);\n", "")
                                                    .replace("static void zb_tag", "static void zb_later(NSApplication *application) {\n"
                                                             "  zb_install_edit_menu(application);\n}\nstatic void zb_tag")),
                                         "V8: the Edit menu must be installed"),
    "the Edit menu's item retitled": (link_case(src__wkwebview_shim_dot_m=OTHERS["src/wkwebview_shim.m"].replace('action:@selector(copy:) keyEquivalent:@"c"', 'action:@selector(copy:) keyEquivalent:@"x"')),
                                      "V8: zb_install_edit_menu differs"),
    "a second Edit menu function": (link_case(src__wkwebview_shim_dot_m=OTHERS["src/wkwebview_shim.m"] + REVIEWED_EDIT_MENU.replace("zb_install_edit_menu", "zb_install_edit_menu2") + "\n"),
                                    "V7 src/wkwebview_shim.m: copy: other than the reviewed Edit menu's Copy item"),
    # RoseCat 8129 #3: the item retargeted through its ivar, or bound
    "the Copy item retargeted through its ivar": (link_case(src__wkwebview_shim_dot_m=OTHERS["src/wkwebview_shim.m"]
                                                            + 'static void zb_i(NSMenu *m, id t) {\n  object_setIvar([m itemAtIndex:0], '
                                                              'class_getInstanceVariable([NSMenuItem class], "_target"), t);\n}\n'),
                                                  "V7 src/wkwebview_shim.m: class_getInstanceVariable"),
    "the Copy item's target bound": (link_case(src__wkwebview_shim_dot_m=OTHERS["src/wkwebview_shim.m"]
                                               + 'static void zb_b(NSMenu *m, id t) {\n  [[m itemAtIndex:0] bind:@"target" toObject:t withKeyPath:@"self" options:nil];\n}\n'),
                                     "V7 src/wkwebview_shim.m: a binding (bind:)"),
    "a selector built at run time": (link_case(src__wkwebview_shim_dot_m=OTHERS["src/wkwebview_shim.m"]
                                               + 'static SEL zb_s(void) {\n  return sel_registerName("copy:");\n}\n'),
                                     "V7 src/wkwebview_shim.m: sel_registerName"),
    "a category on ZbBubbleView in the shim": (link_case(src__wkwebview_shim_dot_m=OTHERS["src/wkwebview_shim.m"]
                                                         + "@implementation ZbBubbleView (Steal)\n- (void)copy:(id)s {\n}\n@end\n"),
                                               "V7 src/wkwebview_shim.m: a category"),
    "a category on NSTextView in the shim": (link_case(src__wkwebview_shim_dot_m=OTHERS["src/wkwebview_shim.m"]
                                                       + "@implementation NSTextView (Steal)\n- (void)copy:(id)s {\n}\n@end\n"),
                                             "V7 src/wkwebview_shim.m: a category"),
    "a swizzle in the shim": (link_case(src__wkwebview_shim_dot_m=OTHERS["src/wkwebview_shim.m"]
                                        + "static void zb_s(Method a, Method b) {\n  method_exchangeImplementations(a, b);\n}\n"),
                              "V7 src/wkwebview_shim.m: method_exchangeImplementations"),
    "an isa swap in the shim": (link_case(src__wkwebview_shim_dot_m=OTHERS["src/wkwebview_shim.m"]
                                          + "static void zb_i(id v, Class c) {\n  object_setClass(v, c);\n}\n"),
                                "V7 src/wkwebview_shim.m: object_setClass"),
    "a pasteboard write in the shim": (link_case(src__wkwebview_shim_dot_m=OTHERS["src/wkwebview_shim.m"]
                                                 + "static void zb_p(NSString *t) {\n  [[NSPasteboard generalPasteboard] setString:t forType:NSPasteboardTypeString];\n}\n"),
                                       "V7 src/wkwebview_shim.m: NSPasteboard"),
    "a copy: in the shim's responder chain": (link_case(src__wkwebview_shim_dot_m=OTHERS["src/wkwebview_shim.m"]
                                                        + "@implementation ZBWindow\n- (void)copy:(id)sender {\n}\n@end\n"),
                                              "V7 src/wkwebview_shim.m: copy: other than"),
    "a runtime rewrite in a C source": (link_case(src__agent_home_lock_dot_c="void zb_r(void) { class_replaceMethod(0, 0, 0, 0); }\n"),
                                        "V7 src/agent_home_lock.c: class_replaceMethod"),
}


class BubbleInert(unittest.TestCase):
    def test_the_real_drawer_keeps_bubbles_inert(self):
        build = (REPO / "build.zig").read_text()
        sources = mac_link_sources(build)
        self.assertIn("src/wkwebview_shim.m", sources, "the link parser found no macOS sources")
        read = (lambda p: (REPO / p).read_text() if (REPO / p).is_file() else None)
        headers = [str(h.relative_to(REPO)) for h in (REPO / "src").rglob("*.h")]
        self.assertEqual(link_problems(build, sources, native_closure(sources, read), read, headers)
                         + problems(read(DRAWER), read(HEADER)), [])

    def test_the_honest_fixture_passes(self):
        self.assertEqual(problems(HONEST, HONEST_HEADER), [])

    def test_the_honest_link_passes_with_the_edit_menu(self):
        self.assertEqual(link_found(*link_case()), [])

    def test_each_dishonest_header_fails_for_its_rule(self):
        for name, (header, rule) in HEADER_MUTANTS.items():
            with self.subTest(mutant=name):
                found = problems(HONEST, header)
                self.assertTrue(any(f.startswith(rule) for f in found), (name, found))

    def test_each_dishonest_link_fails_for_its_rule(self):
        for name, ((build, files), rule) in LINK_MUTANTS.items():
            with self.subTest(mutant=name):
                found = link_found(build, files)
                self.assertTrue(any(f.startswith(rule) for f in found), (name, found))

    def test_strings_and_comments_do_not_count(self):
        extra = ('// NSTextField setString: initWithHTML zb_drawer_bubble_layout_contiguous copy:\n'
                 'static const char *k = "setStringValue: } { fieldEditor: zb_drawer_appkit_shown( _original";\n')
        self.assertEqual(problems(HONEST + extra, HONEST_HEADER), [])

    def test_each_dishonest_fixture_fails_for_its_rule(self):
        for name, (text, rule) in MUTANTS.items():
            with self.subTest(mutant=name):
                self.assertNotEqual(text, HONEST, "the mutation's anchor moved")
                found = problems(text, HONEST_HEADER)
                self.assertTrue(any(f.startswith(rule) for f in found), (name, found))


if __name__ == "__main__":
    unittest.main()
