"""MS7 compiled two-Mac hard gate (RoseCat c6b2b32 items 2-4; orchestrator 2026-10-22): the CHECKER. A pure function from
one Mac leg's evidence to the contract's findings (empty: the leg passes). tests/mac/ms7_appkit_case.py gathers the
evidence on the Mac and calls it; tests/e2e/ms7_appkit_gate_test.py checks it offline against an honest and each
dishonest evidence set. The source oracles (tests/e2e/mac_drawer_bubble_inert_test.py,
tests/e2e/mac_drawer_card_authority_test.py) are offline tripwires; this is the runtime authority.

Evidence (all gathered from ONE exact-commit export on that Mac):
- argv: every argv the native production build ran through `xcrun` (a logging xcrun first on PATH), the repo root
  and the dylib output path normalized to <repo> / <out>;
- pre_drawer, pre_shim: `xcrun clang -E` of src/agent_drawer_mac.m and src/wkwebview_shim.m under the production
  argv's preprocessing flags;
- nm: `nm -u` / `nm -gU` of zig-out/bin/zigBrowser and of the shipped libwkwebview_shim.dylib;
- report: the JSON the in-process probe (tests/mac/ms7_appkit_probe.m, injected into the real app started with a
  throwaway HOME and profile, a local file: page and no credential) wrote after the app initialized.

Rows (each one bounded assertion, printed by the case):
- A argv: exactly one shim compile, equal to REVIEWED_ARGV (the reviewed configureMacosBackend's argv).
- P preprocessor: in the preprocessed drawer, ZbBubbleView's @implementation has the reviewed shape (the bubble
  oracle's BUBBLE_IMPL), and no @implementation/@interface of any category appears in either preprocessed TU; the
  preprocessed shim holds the reviewed zb_install_edit_menu.
- L link: neither the executable nor the dylib leaves a GTK-only card / helper / image symbol undefined; the
  executable defines the minters and the bridge.
- O ObjC, live: ZbBubbleView's superclass is NSTextView; its instance methods are exactly the reviewed six, each IMP in
  the shim image; the shim and the executable register no category (__objc_catlist / __objc_nlcatlist empty); no
  watched AppKit class (NSTextView, NSText, NSView, NSResponder, NSMenuItem, NSMenu, NSApplication, NSWindow,
  NSPasteboard) has a method whose IMP lies outside the system images.
- M menu, live: exactly one item anywhere in the main menu has action copy:; it is Edit > Copy, key "c" with Command
  only, and its target is nil.
- B bubbles, live: for each probe bubble (small with invalid UTF-8, a NUL and an astral character; label_text_max + 1
  bytes; 200 KiB unbroken) a real ZbBubbleView was first responder and a real Cmd+C (an NSEvent through
  -[NSApplication sendEvent:]) put EXACTLY the original bytes on the pasteboard, for the whole selection and for a
  leading ASCII prefix; the 200 KiB bubble laid out non-contiguously, the small one contiguously.
- W page fallback, live: with the page's WKWebView first responder and its text selected, Cmd+C put that text.
- C card, live: a card was presented by the real chain; its Approve control's action is approveClicked: with the
  card view as target; one real click (mouse NSEvents through -[NSWindow sendEvent:]) minted exactly one grant, a
  second click none, Deny on another card none, and the page could not reach a card (no script message handler).
- R the leg: the report names this leg's architecture and carries no probe error.
"""
import json
import re

BUBBLE_METHODS = sorted(["keepOriginal:length:", "copy:", "dragSelectionWithEvent:offset:slideBack:",
                         "validRequestorForSendType:returnType:", "menuForEvent:", "dealloc"])
WATCHED = ("NSTextView", "NSText", "NSView", "NSResponder", "NSMenuItem", "NSMenu", "NSApplication", "NSWindow",
           "NSPasteboard")
GTK_ONLY = ("_zb_drawer_card_show", "_zb_drawer_card_end", "_zb_drawer_card_notify", "_zb_drawer_post_system",
            "_zb_agent_helper_home", "_zb_agent_helper_post_tool_result", "_zb_agent_image_fit", "_zb_agent_image_free")
EXE_DEFINES = ("_zb_agent_tools_approve", "_zb_agent_tools_deny", "_zb_drawer_card_press")
REVIEWED_ARGV = ["xcrun", "clang", "-dynamiclib", "-fobjc-arc", "-Wl,-undefined,dynamic_lookup", "-Wl,-fixup_chains",
                 "-I", "<repo>/src", "<repo>/src/wkwebview_shim.m", "<repo>/src/agent_drawer_mac.m",
                 "-framework", "WebKit", "-framework", "Cocoa", "-framework", "Foundation",
                 "-install_name", "@executable_path/../Frameworks/libwkwebview_shim.dylib", "-o", "<out>"]
BUBBLES = ("small", "boundary", "large")
ARCHES = {"x86_64": "x86_64", "arm64": "arm64"}


def originals():
    """The probe's bubbles, by label: the exact original bytes it posts (label_text_max is 32 KiB)."""
    small = b"plain \xff\xfe bytes \x00 nul \xf0\x9f\x98\x80 astral, then words"
    boundary = (b"0123456789abcdef" * 2049)[:32 * 1024 + 1]
    large = b"x" * (200 * 1024)
    return {"small": small, "boundary": boundary, "large": large}


PAGE_TEXT = "zigBrowser MS7 page copy fallback"
PREFIX = 5  # the leading ASCII prefix each bubble starts with: shown UTF-16 units == original bytes


def normalize(argv, repo, out_dir):
    """An argv with the repo root and the dylib's output path made position-independent."""
    norm = []
    for a in argv:
        a = a.replace(repo, "<repo>")
        if a.endswith("libwkwebview_shim.dylib") and not a.startswith("@"):
            a = "<out>"
        norm.append(a)
    return norm


def shim_compiles(argvs):
    return [a for a in argvs if a[:3] == ["xcrun", "clang", "-dynamiclib"]]


def problems(ev, arch):
    """One leg's evidence (see the module doc) -> findings; empty means this leg passes."""
    found = []
    from mac_drawer_bubble_inert_test import BUBBLE_IMPL, REVIEWED_EDIT_MENU, blank_same, lexical, shape  # reviewed
    # A argv
    compiles = shim_compiles(ev.get("argv", []))
    if len(compiles) != 1 or compiles[0] != REVIEWED_ARGV:
        found.append(f"A: the shim compile must be exactly REVIEWED_ARGV (got {compiles})")
    # P preprocessor
    for name, text in (("drawer", ev.get("pre_drawer", "")), ("shim", ev.get("pre_shim", ""))):
        code = lexical(text)
        if not code.strip():
            found.append(f"P: no preprocessed {name}")
        if re.search(r"@(?:interface|implementation)\s+(?:ZbBubbleView|ZbDrawerView|ZbCardView|ZbIconView|ZB\w+|Zb\w+)\s*\(", code):
            found.append(f"P: a category on one of our classes in the preprocessed {name}")
    drawer = lexical(ev.get("pre_drawer", ""))
    m = re.search(r"@implementation\s+ZbBubbleView\b(.*?)@end", drawer, re.S)
    if m is None or shape(m.group(1)) != shape(lexical(BUBBLE_IMPL)):
        found.append("P: the preprocessed ZbBubbleView implementation is not the reviewed one")
    want_menu = shape(lexical(REVIEWED_EDIT_MENU, keep_strings=True))  # titles and key equivalents count
    blank, kept = blank_same(ev.get("pre_shim", "")), lexical(ev.get("pre_shim", ""), keep_strings=True)
    hits = [k.start() for k in re.finditer(r"\bstatic\s+void\s+zb_install_edit_menu\s*\(", blank)]
    if len(hits) != 1 or shape(kept[hits[0]:blank.find("}", hits[0]) + 1]) != want_menu:
        found.append("P: the preprocessed shim does not hold exactly the reviewed zb_install_edit_menu")
    # L link
    nm = ev.get("nm", {})
    for image in ("exe_undefined", "dylib_undefined"):
        bad = sorted(set(nm.get(image, [])) & set(GTK_ONLY))
        if bad:
            found.append(f"L: {image} needs GTK-only symbols {bad}")
    missing = sorted(set(EXE_DEFINES) - set(nm.get("exe_defined", [])))
    if missing:
        found.append(f"L: the executable does not define {missing}")
    # R the report itself
    rep = ev.get("report")
    if not isinstance(rep, dict):
        return found + ["R: no probe report"]
    if rep.get("arch") != ARCHES.get(arch):
        found.append(f"R: the report is for {rep.get('arch')!r}, this leg is {arch!r}")
    if rep.get("errors"):
        found.append(f"R: the probe reported errors {rep['errors']}")
    # O ObjC
    shim_image = rep.get("shim_image")
    bubble = rep.get("classes", {}).get("ZbBubbleView")
    if not shim_image or not bubble:
        found.append("O: ZbBubbleView is not loaded")
    else:
        if bubble.get("super") != "NSTextView":
            found.append(f"O: ZbBubbleView's superclass is {bubble.get('super')!r}")
        if bubble.get("image") != shim_image:
            found.append("O: ZbBubbleView is not the shim's class")
        sels = sorted(mm.get("sel") for mm in bubble.get("methods", []))
        if sels != BUBBLE_METHODS:
            found.append(f"O: ZbBubbleView's methods are {sels}, want {BUBBLE_METHODS}")
        for mm in bubble.get("methods", []):
            if mm.get("image") != shim_image:
                found.append(f"O: ZbBubbleView {mm.get('sel')} runs from {mm.get('image')}")
    for image, counts in sorted(rep.get("catlists", {}).items()):
        if counts.get("catlist", 1) or counts.get("nlcatlist", 1):
            found.append(f"O: {image} registers categories {counts}")
    if set(rep.get("catlists", {})) != {rep.get("shim_image"), rep.get("exe_image")} or None in rep.get("catlists", {}):
        found.append("O: the category census must cover exactly the shim and the executable")
    if sorted(rep.get("watched", [])) != sorted(WATCHED):
        found.append(f"O: the watched classes were {rep.get('watched')}")
    for imp in rep.get("foreign_imps", []):
        found.append(f"O: {imp.get('class')} {imp.get('sel')} runs from {imp.get('image')}")
    counts = rep.get("watched_counts", {})
    if sorted(counts) != sorted(WATCHED) or any(not isinstance(n, int) or n <= 0 for n in counts.values()):
        found.append(f"O: every watched class must have been examined, with methods ({counts})")
    # M menu
    items = rep.get("copy_items", [])
    if len(items) != 1:
        found.append(f"M: want exactly one copy: item in the main menu ({len(items)})")
    else:
        it = items[0]
        if it.get("path") != ["Edit", "Copy"] or it.get("key") != "c" or it.get("modifiers") != ["command"]:
            found.append(f"M: the copy: item is {it}")
        if it.get("target_nil") is not True:
            found.append("M: the Copy item's target is not nil")
    # B bubbles
    want = originals()
    rows = {(b.get("label"), b.get("selection")): b for b in rep.get("bubbles", [])}
    for label in BUBBLES:
        for sel, expect in (("whole", want[label]), ("prefix", want[label][:PREFIX])):
            row = rows.get((label, sel))
            if row is None:
                found.append(f"B: no {label} / {sel} copy")
                continue
            if row.get("first_responder") != "ZbBubbleView":
                found.append(f"B: {label} / {sel}: the first responder was {row.get('first_responder')}")
            if row.get("via") != "NSApplication sendEvent: Cmd+C":
                found.append(f"B: {label} / {sel}: copied via {row.get('via')}")
            if row.get("pasteboard_hex") != expect.hex():
                found.append(f"B: {label} / {sel}: the pasteboard did not get the exact original bytes")
    for row in rep.get("bubbles", []):
        if row.get("contiguous") is not (row.get("label") == "small"):
            found.append(f"B: {row.get('label')} / {row.get('selection')}: contiguous layout {row.get('contiguous')} "
                         f"(want only the small one, up to label_text_max, contiguous)")
    # W page
    page = rep.get("page", {})
    if not str(page.get("first_responder", "")).startswith("WKWebView") or page.get("pasteboard") != PAGE_TEXT \
            or page.get("via") != "NSApplication sendEvent: Cmd+C":
        found.append(f"W: the page fallback copy was {page}")
    # C card
    card = rep.get("card", {})
    if card.get("source") != "chain":
        found.append(f"C: no card presented by the real chain on macOS ({card.get('source')!r})")
    else:
        if card.get("approve_action") != "approveClicked:" or card.get("approve_target") != "ZbCardView":
            found.append(f"C: the Approve control is wired to {card.get('approve_target')} {card.get('approve_action')}")
        if card.get("deny_action") != "denyClicked:" or card.get("deny_target") != "ZbCardView":
            found.append(f"C: the Deny control is wired to {card.get('deny_target')} {card.get('deny_action')}")
        if card.get("via") != "NSWindow sendEvent: mouse":
            found.append(f"C: the click went via {card.get('via')}")
        if card.get("grants") != [0, 1, 1, 1]:
            found.append(f"C: grants before / after Approve / after a second Approve / after Deny on another card "
                         f"were {card.get('grants')}, want [0, 1, 1, 1]")
    if rep.get("page_handlers") != 0:
        found.append(f"C: the page can reach a script message handler ({rep.get('page_handlers')})")
    return found


def head_problems(repo):
    """The offline RED row: what this commit still lacks for the compiled gate to pass (empty only at the green)."""
    found = []
    def read(p):
        try:
            return (repo / p).read_text()
        except OSError:
            return None
    drawer, build, shim, zig = read("src/agent_drawer_mac.m"), read("build.zig") or "", read("src/wkwebview_shim.m") or "", \
        read("src/agent_drawer.zig") or ""
    if drawer is None:
        found.append("src/agent_drawer_mac.m is missing")
    if 'shim.addFileArg(b.path("src/agent_drawer_mac.m"));' not in build:
        found.append("the drawer is not in the macOS link")
    if "zb_install_edit_menu(application);" not in shim:
        found.append("the shim installs no Edit menu")
    if '.name = "zb_drawer_card_press"' not in zig:
        found.append("the drawer exports no card bridge")
    return found


def load_report(path):
    with open(path) as f:
        return json.load(f)
