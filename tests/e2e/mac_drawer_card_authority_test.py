"""MS7.6 / MS7.8 (macOS plan line 2158; RoseCat 8055 / bdc8202 on 698ba02): on macOS the approval card's native
Approve control is the ONLY production minter, and Deny mints nothing. What a press may do is decided and tested in the
portable logic (tests/agent_drawer_card_press_test.zig: zb_drawer_card_press over the real MS4 cards: own control, own
card, single use, the 120 s expiry). This oracle binds the AppKit side to it, over EXACTLY the sources of the macOS
link: build.zig's configureMacosBackend, the Objective-C files it hands `xcrun clang` (shim.addFileArg) and the C files
it compiles into the exe (module.addCSourceFile). Each source is read lexically: comments removed and the contents of
string and character literals blanked, so a name inside a string or a comment never counts (button titles are read
from the comment-free text with strings kept).
- B (RoseCat 8112): that link is bound EXACTLY, failing closed on any other link expression:
  - configureMacosBackend equals REVIEWED_MACOS_BACKEND, token for token. That is today's function plus the drawer's
    line, so every source, every C flag and the whole clang argv are fixed: no source through a variable, no -Wp
    forwarding, response file or -trigraphs.
  - configureBackend equals REVIEWED_CONFIGURE_BACKEND, resolveBackend equals REVIEWED_RESOLVE_BACKEND, and
    configureMacosBackend is called once.
  - The production call is live (RoseCat 3c0b7b3 #1): build() holds `const backend = resolveBackend(target);` once
    and the one root_module createModule, followed directly by `configureBackend(root_module, b, backend,
    webview2_paths);`, all at build()'s own brace depth (under no if, loop or block).
  - Every member access on root_module, exe or the generated site_options_module is a reviewed statement.
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
- Z (RoseCat 8074 / 64e2225; 8079 / 2796d94): the executable's Zig side, where the minters live, is inventoried too,
  fail closed. This is the SECONDARY layer: the primary proof is by symbol and relocation on the real cross-compiled
  Darwin objects (mac_card_authority_objects_test.py, build step check-card-authority-mac).
  - The root is derived from build.zig, never assumed: exactly one installed `zigBrowser` executable, whose
    root_module's root source must be src/main.zig, importing exactly build_options and gaining no other import.
  - The graph is every .zig file reachable from that root through relative @import, keyed by its full normalized
    repo-relative path (an absolute import or one leaving the repository is a violation; so is an import of any module
    other than std, builtin, root and build_options).
  - Each file is read twice with the same offsets: comment-free with literal contents blanked to spaces, and
    comment-free with literals kept. Every occurrence of the identifiers zb_agent_tools_approve, zb_agent_tools_deny,
    zb_drawer_card_press, approve and deny, and every string literal containing one of the three symbol names (or
    equal to "approve" / "deny"), is located by path and innermost enclosing fn ("-": none). The census must equal
    ALLOWED exactly: the two minter definitions (src/agent_tools.zig, each the only caller of cards.approve /
    cards.deny), Cards.approve / Cards.deny's definitions (src/agent_approval.zig), and the reviewed bridge in
    src/agent_drawer.zig (its Approver fields, cardPress's two calls, the adapter's .approve/.deny, the extern
    declarations, one call each in toolsApprove / toolsDeny, zb_drawer_card_press's definition, its one @export and
    that export's one name string).
  - No lookup by name: no @extern, dlsym, dlopen or DynLib anywhere in the graph. Every @field names its member with
    one plain literal, except the six reviewed reflective sites in REFLECTIVE (none reaches Cards, a minter or the
    bridge), each at most as often as reviewed. Every @export names its symbol with one plain literal.
  - The bodies of the two minters, toolsApprove / toolsDeny and zb_drawer_card_press are exactly BODIES (statements,
    order, count and control flow: RoseCat 8097 / 4124a1b), so neither an alias called twice nor a loop around one
    call consumes a card twice.
  - The minter definitions must be `export fn` and the drawer's declarations `extern fn`; the bridge's @export,
    read comment-free, is exactly one, under exactly "zb_drawer_card_press".
  The ObjC rules above stay the narrower authority for native event ingress.
The real native click (MS7.8's -[NSWindow sendEvent:] Approve/Deny) stays the owner-run real-screen closure.
Self-checking: an honest fixture passes; names in strings and comments do not count; and each dishonest fixture
fails, the Zig graphs and build.zig roots each for their own stated reason (RoseCat 2796d94's four among them).
RED until build.zig's macOS link has src/agent_drawer_mac.m with that shape. No process, no signal.
Run: cd tests/e2e && python3 -X dev -m unittest -v mac_drawer_card_authority_test
Unregistered until the green."""
import os
import re
import unittest
from collections import Counter, deque
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


# RoseCat 8112 #1/#2: the macOS link and its compiler argv are bound EXACTLY (no prefix denylist), so a source
# reached through a variable, a forwarded preprocessor flag (-Wp,...), a response file or -trigraphs is a change to
# reviewed text. REVIEWED_MACOS_BACKEND is today's configureMacosBackend plus the drawer's one line.
REVIEWED_MACOS_BACKEND = r'''fn configureMacosBackend(module: *std.Build.Module, b: *std.Build) void {
    module.addIncludePath(b.path("src"));
    module.addCSourceFile(.{ .file = b.path("src/agent_home_lock.c"), .flags = &.{"-std=gnu11"} });
    module.addCSourceFile(.{ .file = b.path("src/agent_spawn_posix.c"), .flags = &.{"-std=gnu11"} });
    const shim = b.addSystemCommand(&.{ "xcrun", "clang", "-dynamiclib", "-fobjc-arc", "-Wl,-undefined,dynamic_lookup", "-Wl,-fixup_chains" });
    shim.addArg("-I");
    shim.addDirectoryArg(b.path("src"));
    shim.addFileArg(b.path("src/wkwebview_shim.m"));
    shim.addFileArg(b.path("src/agent_drawer_mac.m"));
    shim.addArgs(&.{ "-framework", "WebKit", "-framework", "Cocoa", "-framework", "Foundation" });
    shim.addArgs(&.{ "-install_name", "@executable_path/../Frameworks/libwkwebview_shim.dylib", "-o" });
    const dylib = shim.addOutputFileArg("libwkwebview_shim.dylib");
    module.addLibraryPath(dylib.dirname());
    module.linkSystemLibrary("wkwebview_shim", .{});
    module.linkFramework("WebKit", .{});
    module.linkFramework("Cocoa", .{});
    module.linkFramework("Foundation", .{});
    const install_dylib = b.addInstallFileWithDir(dylib, .{ .custom = "Frameworks" }, "libwkwebview_shim.dylib");
    b.getInstallStep().dependOn(&install_dylib.step);
}
'''
REVIEWED_CONFIGURE_BACKEND = r'''fn configureBackend(
    module: *std.Build.Module,
    b: *std.Build,
    backend: Backend,
    webview2_paths: WebView2Paths,
) void {
    switch (backend) {
        .gtk_backend => configureGtkBackend(module, b),
        .webview2_backend => configureWebView2Backend(module, b, webview2_paths),
        .macos_backend => configureMacosBackend(module, b),
    }
}
'''
# The backend choice (RoseCat 3c0b7b3 #1): reviewed exactly, so the macOS target keeps the macOS backend.
REVIEWED_RESOLVE_BACKEND = r'''fn resolveBackend(target: std.Build.ResolvedTarget) Backend {
    return switch (target.result.os.tag) {
        .linux => .gtk_backend,
        .windows => .webview2_backend,
        .macos => .macos_backend,
        else => std.debug.panic("NoBackendLinked: no backend for target os '{s}'", .{@tagName(target.result.os.tag)}),
    };
}
'''
# Every other statement that can add to the shipped executable's link: a member access on root_module, exe or the
# generated site_options_module (its one import), each a reviewed statement, at most as often as reviewed.
REVIEWED_MEMBER_USES = Counter({
    "configureBackend(root_module,b,backend,webview2_paths);": 1,
    ".root_source_file=root_module.root_source_file.?,": 1,
    "if(backend==.macos_backend)exe.rdynamic=true;": 1,
    "exe.subsystem=.Windows;": 1,
    'exe.entry=.{.symbol_name="mainCRTStartup"};': 1,
    "exe.step.dependOn(pkg_guard);": 1,
})
MEMBER_USE = re.compile(r"(?<![.\w])(?:root_module\b(?!\s*=\s*b\.createModule)|exe\s*\.|site_options_module\s*\.)")


def production_call_problems(build_zig):
    """B (RoseCat 3c0b7b3 #1): the reviewed link statements are not mere upper bounds. In build()'s own body
    (brace depth 1, so under no if, loop or block): `const backend = resolveBackend(target);` exactly once, the one
    `const root_module = b.createModule(...);` and, as the very next statement, the one
    `configureBackend(root_module, b, backend, webview2_paths);`."""
    code = zig_lexical(build_zig)
    m = re.search(r"\bpub\s+fn\s+build\s*\([^)]*\)\s*void\s*\{", code)
    if m is None:
        return ["B: no pub fn build"]
    start, depth = m.end(), 1
    end = start
    while end < len(code) and depth:
        depth += {"{": 1, "}": -1}.get(code[end], 0)
        end += 1
    body = code[start:end]

    def depth_of(pos):
        return 1 + body[:pos].count("{") - body[:pos].count("}")

    found = []
    checks = (("const backend = resolveBackend(target);", r"\bconst\s+backend\s*=\s*resolveBackend\(\s*target\s*\)\s*;"),
              ("const root_module = b.createModule(...)", r"\bconst\s+root_module\s*=\s*b\.createModule\("))
    for what, pattern in checks:
        hits = [h.start() for h in re.finditer(pattern, body)]
        if len(hits) != 1 or depth_of(hits[0]) != 1:
            found.append(f"B: build() must hold `{what}` exactly once, unconditionally ({len(hits)})")
    if len(re.findall(r"\b(?:var|const)\s+backend\b", body)) != 1:
        found.append("B: build() must declare backend exactly once")
    mod = re.search(r"\bconst\s+root_module\s*=\s*b\.createModule\(", body)
    if mod:
        i, d = mod.end(), 1
        while i < len(body) and d:
            d += {"(": 1, ")": -1}.get(body[i], 0)
            i += 1
        call = re.match(r"\s*;\s*configureBackend\(\s*root_module\s*,\s*b\s*,\s*backend\s*,\s*webview2_paths\s*\)\s*;", body[i:])
        if call is None or depth_of(i) != 1:
            found.append("B: `configureBackend(root_module, b, backend, webview2_paths);` must be the statement right "
                         "after root_module's createModule, unconditionally in build()")
    return found


def mac_build_problems(build_zig):
    """B: build.zig's macOS link is exactly the reviewed one (fail closed on any other link expression)."""
    code = zig_lexical(build_zig, keep_strings=True)
    found = []
    for name, want in (("configureMacosBackend", REVIEWED_MACOS_BACKEND), ("configureBackend", REVIEWED_CONFIGURE_BACKEND),
                       ("resolveBackend", REVIEWED_RESOLVE_BACKEND)):
        got = re.findall(r"\bfn\s+" + name + r"\s*\(.*?\n}\n", code, re.S)
        if len(got) != 1:
            found.append(f"B: want exactly one fn {name} ({len(got)})")
        elif shape(got[0]) != shape(want):
            g, w = shape(got[0]), shape(want)
            i = next((k for k, (x, y) in enumerate(zip(g, w)) if x != y), min(len(g), len(w)))
            found.append(f"B: fn {name} differs from the reviewed text at statement {i}: got "
                         f"`{g[i] if i < len(g) else '<end>'}`, want `{w[i] if i < len(w) else '<end>'}`")
    for name, calls in (("configureMacosBackend", 1), ("configureBackend", None)):
        n = len(re.findall(r"(?<!fn )\b" + name + r"\s*\(", code))
        if calls is not None and n != calls:
            found.append(f"B: {name} must be called exactly {calls} time(s) ({n})")
    found += production_call_problems(build_zig)
    uses = Counter()
    for line in code.splitlines():
        if MEMBER_USE.search(line) and not re.match(r"\s*\.root_module\s*=\s*root_module\s*,\s*$", line):
            uses[re.sub(r"\s+", "", line)] += 1
    for use, n in sorted(uses.items()):
        if n > REVIEWED_MEMBER_USES[use]:
            found.append(f"B: an unreviewed link statement `{use}`")
    return found


HONEST_BUILD = """pub fn build(b: *std.Build) void {
    const backend = resolveBackend(target);
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
    });
    configureBackend(root_module, b, backend, webview2_paths);
    const exe = b.addExecutable(.{
        .name = "zigBrowser",
        .root_module = root_module,
    });
    if (backend == .macos_backend) exe.rdynamic = true;
    exe.step.dependOn(pkg_guard);
    b.installArtifact(exe);
    const card_authority_mac_module = b.createModule(.{
        .root_source_file = root_module.root_source_file.?,
    });
}

""" + REVIEWED_RESOLVE_BACKEND + "\n" + REVIEWED_CONFIGURE_BACKEND + "\n" + REVIEWED_MACOS_BACKEND


def macos_build_mutant(old, new, text=None):
    text = HONEST_BUILD if text is None else text
    assert text.count(old) == 1, old
    return text.replace(old, new)


BUILD_MUTANTS = {  # name -> (build.zig, the reason it must fail for); RoseCat 8112 #1 / #2
    "a linked source through a variable": (macos_build_mutant('    shim.addFileArg(b.path("src/agent_drawer_mac.m"));\n',
                                                        '    shim.addFileArg(b.path("src/agent_drawer_mac.m"));\n'
                                                        '    const evil = b.path("src/evil.m");\n    shim.addFileArg(evil);\n'),
                                           "B: fn configureMacosBackend differs"),
    "a C source through a variable": (macos_build_mutant('    module.addIncludePath(b.path("src"));\n',
                                                   '    module.addIncludePath(b.path("src"));\n    const evil = b.path("src/evil.c");\n'
                                                   "    module.addCSourceFile(.{ .file = evil });\n"), "B: fn configureMacosBackend differs"),
    "a forwarded -Wp,-DNO=YES": (macos_build_mutant('"-fobjc-arc",', '"-fobjc-arc", "-Wp,-DNO=YES",'), "B: fn configureMacosBackend differs"),
    "a response file": (macos_build_mutant('"-fobjc-arc",', '"-fobjc-arc", "@zb.rsp",'), "B: fn configureMacosBackend differs"),
    "trigraphs on": (macos_build_mutant('"-fobjc-arc",', '"-fobjc-arc", "-trigraphs",'), "B: fn configureMacosBackend differs"),
    "a C flag": (macos_build_mutant('.flags = &.{"-std=gnu11"} });\n    module.addCSourceFile(.{ .file = b.path("src/agent_spawn_posix.c")',
                              '.flags = &.{ "-std=gnu11", "-DNO=1" } });\n    module.addCSourceFile(.{ .file = b.path("src/agent_spawn_posix.c")'),
                 "B: fn configureMacosBackend differs"),
    "a source on the root module in build()": (macos_build_mutant("    exe.step.dependOn(pkg_guard);\n",
                                                            "    exe.step.dependOn(pkg_guard);\n"
                                                            '    root_module.addCSourceFile(.{ .file = b.path("src/evil.c") });\n'),
                                               "B: an unreviewed link statement `root_module.addCSourceFile"),
    "an object on the exe": (macos_build_mutant("    exe.step.dependOn(pkg_guard);\n",
                                          '    exe.step.dependOn(pkg_guard);\n    exe.addObjectFile(b.path("evil.o"));\n'),
                             "B: an unreviewed link statement `exe.addObjectFile"),
    "a source on the exe's root module": (macos_build_mutant("    exe.step.dependOn(pkg_guard);\n",
                                                       "    exe.step.dependOn(pkg_guard);\n"
                                                       '    exe.root_module.addCSourceFile(.{ .file = b.path("src/evil.c") });\n'),
                                          "B: an unreviewed link statement `exe.root_module.addCSourceFile"),
    "a source on the imported options module": (macos_build_mutant("    exe.step.dependOn(pkg_guard);\n",
                                                             "    exe.step.dependOn(pkg_guard);\n"
                                                             '    site_options_module.addCSourceFile(.{ .file = b.path("src/evil.c") });\n'),
                                                "B: an unreviewed link statement `site_options_module.addCSourceFile"),
    # RoseCat 3c0b7b3 #1: the reviewed call dead or moved
    "the production configureBackend call removed": (macos_build_mutant("    configureBackend(root_module, b, backend, webview2_paths);\n", ""),
                                                     "B: `configureBackend(root_module, b, backend, webview2_paths);` must be"),
    "the production call under if (gtk)": (macos_build_mutant("    configureBackend(root_module, b, backend, webview2_paths);\n",
                                                              "    if (backend == .gtk_backend) {\n"
                                                              "        configureBackend(root_module, b, backend, webview2_paths);\n    }\n"),
                                           "B: `configureBackend(root_module, b, backend, webview2_paths);` must be"),
    "the production call moved later": (macos_build_mutant("    configureBackend(root_module, b, backend, webview2_paths);\n", "")
                                        .replace("    b.installArtifact(exe);\n",
                                                 "    b.installArtifact(exe);\n    configureBackend(root_module, b, backend, webview2_paths);\n"),
                                        "B: `configureBackend(root_module, b, backend, webview2_paths);` must be"),
    "the backend chosen another way": (macos_build_mutant("    const backend = resolveBackend(target);\n",
                                                          "    const backend: Backend = .gtk_backend;\n"),
                                       "B: build() must hold `const backend = resolveBackend(target);`"),
    "macOS resolved to another backend": (macos_build_mutant("        .macos => .macos_backend,\n", "        .macos => .gtk_backend,\n"),
                                          "B: fn resolveBackend differs"),
    "the macOS backend configured twice": (macos_build_mutant("    exe.step.dependOn(pkg_guard);\n",
                                                        "    exe.step.dependOn(pkg_guard);\n    configureMacosBackend(other, b);\n"),
                                           "B: configureMacosBackend must be called exactly 1 time(s)"),
}


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


def zig_lexical(text, keep_strings=False):
    """Zig source without // comments; "..." / '...' literal contents and \\\\ multiline strings blanked (to spaces,
    so offsets match the kept form), or kept."""
    out, i, n = [], 0, len(text)
    while i < n:
        if text.startswith("//", i):
            j = text.find("\n", i); i = n if j < 0 else j
        elif text.startswith("\\\\", i):
            j = text.find("\n", i); j = n if j < 0 else j
            out.append(text[i:j] if keep_strings else '""' + " " * (j - i - 2)); i = j
        elif text[i] in "\"'":
            q, j = text[i], i + 1
            while j < n and text[j] != q and text[j] != "\n":
                j += 2 if text[j] == "\\" else 1
            out.append(text[i:j + 1] if keep_strings else q + " " * max(0, min(j, n - 1) - i - 1) + q); i = j + 1
        else:
            out.append(text[i]); i += 1
    return "".join(out)

EXE_ROOT = "src/main.zig"

def exe_root(build_zig):
    """build.zig -> (the shipped zigBrowser executable's root source, violations): derived, never assumed."""
    code = zig_lexical(build_zig, keep_strings=True)
    exes = re.findall(r'const\s+(\w+)\s*=\s*b\.addExecutable\(\s*\.\{\s*\.name\s*=\s*"zigBrowser"\s*,\s*\.root_module\s*=\s*(\w+)\s*,', code)
    if len(exes) != 1:
        return None, [f"R: want exactly one zigBrowser executable in build.zig ({len(exes)})"]
    exe, module = exes[0]
    bad = []
    if len(re.findall(r"\bb\.installArtifact\(\s*" + exe + r"\s*\)", code)) != 1:
        bad.append(f"R: build.zig must install {exe} once")
    roots = re.findall(r"const\s+" + module + r'\s*=\s*b\.createModule\(\s*\.\{\s*\.root_source_file\s*=\s*b\.path\("([^"]+)"\)', code)
    if len(roots) != 1:
        return None, bad + [f"R: want exactly one root source for {module} ({len(roots)})"]
    imports = re.search(r"const\s+" + module + r"\s*=\s*b\.createModule\(\s*\.\{.*?\.imports\s*=\s*&\.\{(.*?)\}\s*,\s*\.target", code, re.S)
    if imports is None or re.findall(r'\.name\s*=\s*"([^"]+)"', imports.group(1)) != ["build_options"]:
        bad.append(f"R: {module} must import exactly build_options")
    if re.search(r"\b" + module + r"\.add(?:Anonymous)?Import\(", code):
        bad.append(f"R: {module} must gain no other import")
    if roots[0] != EXE_ROOT:
        bad.append(f"R: the shipped executable's root is {roots[0]}, want {EXE_ROOT}")
    return roots[0], bad

def graph(read, root):
    """{repo-relative path: text} of every .zig reachable from `root` by relative @import, and import violations."""
    seen, q, bad = {}, deque([os.path.normpath(root)]), []
    while q:
        f = q.popleft()
        if f in seen: continue
        if os.path.isabs(f) or f == ".." or f.startswith("../"):
            bad.append(f"import outside the repository: {f}"); seen[f] = ""; continue
        text = read(f)
        if text is None: bad.append(f"missing {f}"); continue
        seen[f] = text
        for imp in re.findall(r'@import\(\s*"([^"]+)"\s*\)', zig_lexical(text, keep_strings=True)):
            if imp.endswith(".zig"):
                q.append(imp if os.path.isabs(imp) else os.path.normpath(os.path.join(os.path.dirname(f), imp)))
            elif imp not in ("std", "builtin", "root", "build_options"):
                bad.append(f"{f} imports the unreviewed module {imp!r}")
    return seen, bad

def fn_spans(code):
    spans = []
    for m in re.finditer(r"\bfn\s+(\w+)\s*\(", code):
        k = code.find("{", m.end())
        semi = code.find(";", m.end())
        if k < 0 or (0 <= semi < k): continue  # a declaration (extern fn ...;)
        depth, i = 1, k + 1
        while i < len(code) and depth:
            depth += {"{": 1, "}": -1}.get(code[i], 0); i += 1
        spans.append((k, i, m.group(1)))
    return spans

def where(code, spans, pos):
    inner = [s for s in spans if s[0] <= pos < s[1]]
    return min(inner, key=lambda s: s[1] - s[0])[2] if inner else "-"

TOKENS = ("zb_agent_tools_approve", "zb_agent_tools_deny", "zb_drawer_card_press", "approve", "deny")
SYMBOLS = TOKENS[:3]
# The graph's reflective @field sites, reviewed (none reaches Cards, a minter or the bridge): (path, fn, expression).
# Any other @field whose name is not one plain literal is a violation; a reviewed site may go away.
REFLECTIVE = Counter({
    ("src/agent_protocol.zig", "encode", "@field(f,fd.name)"): 1,
    ("src/automation/social_flow_routes.zig", "tableName", "@field(linkedin.selectors,decl.name)"): 1,
    ("src/automation/social_flow_routes.zig", "tableName", "@field(instagram.selectors,decl.name)"): 1,
    ("src/automation_gtk_port.zig", "-", "@field(vtable,field.name)"): 1,
    ("src/flow_steps.zig", "selectorReportExcept", "@field(Table,decl.name)"): 1,
    ("src/x.zig", "selfCheck", "@field(selectors,decl.name)"): 1,
})
DYNAMIC = ("@extern", "dlsym", "dlopen", "DynLib")

def call_args(code, start):
    """The top-level comma-separated arguments of the call whose `(` ends just before `start`, and its end."""
    args, depth, cur, i = [], 1, start, start
    while i < len(code) and depth:
        ch = code[i]
        if ch == '"':
            j = i + 1
            while j < len(code) and code[j] not in '"\n':
                j += 2 if code[j] == "\\" else 1
            i = j
        elif ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
            if depth == 0:
                args.append(code[cur:i])
        elif ch == "," and depth == 1:
            args.append(code[cur:i]); cur = i + 1
        i += 1
    return args, i


def census(files):
    """Identifiers (strings blanked) and string literals naming them, by (repo-relative path, token, enclosing fn)."""
    c = Counter()
    for f, text in files.items():
        code = zig_lexical(text); spans = fn_spans(code)
        for tok in TOKENS:
            for m in re.finditer(r"\b" + tok + r"\b", code):
                c[(f, tok, where(code, spans, m.start()))] += 1
        kept = zig_lexical(text, keep_strings=True)  # same offsets as `code`: only literal contents differ
        for m in re.finditer(r'"((?:[^"\\\n]|\\.)*)"|\\\\([^\n]*)', kept):
            s = m.group(1) if m.group(1) is not None else m.group(2)
            for tok in TOKENS:
                if (tok in s) if tok in SYMBOLS else (s == tok):
                    c[(f, f'"{tok}"', where(code, spans, m.start()))] += 1
    return c

ALLOWED = Counter({
    ("src/agent_approval.zig", "approve", "-"): 1, ("src/agent_approval.zig", "deny", "-"): 1,
    ("src/agent_tools.zig", "zb_agent_tools_approve", "-"): 1, ("src/agent_tools.zig", "zb_agent_tools_deny", "-"): 1,
    ("src/agent_tools.zig", "approve", "zb_agent_tools_approve"): 1, ("src/agent_tools.zig", "deny", "zb_agent_tools_deny"): 1,
    ("src/agent_drawer.zig", "approve", "-"): 1, ("src/agent_drawer.zig", "deny", "-"): 1,
    ("src/agent_drawer.zig", "approve", "cardPress"): 1, ("src/agent_drawer.zig", "deny", "cardPress"): 1,
    ("src/agent_drawer.zig", "approve", "zb_drawer_card_press"): 1, ("src/agent_drawer.zig", "deny", "zb_drawer_card_press"): 1,
    ("src/agent_drawer.zig", "zb_agent_tools_approve", "-"): 1, ("src/agent_drawer.zig", "zb_agent_tools_deny", "-"): 1,
    ("src/agent_drawer.zig", "zb_agent_tools_approve", "toolsApprove"): 1,
    ("src/agent_drawer.zig", "zb_agent_tools_deny", "toolsDeny"): 1,
    ("src/agent_drawer.zig", "zb_drawer_card_press", "-"): 2,
    ("src/agent_drawer.zig", '"zb_drawer_card_press"', "-"): 1,
})


# RoseCat 8097 / 4124a1b: the reviewed bodies, exactly (statements, order, count, control flow), so neither an alias
# called twice nor a loop around one call consumes a card twice.
BODIES = {
    ("src/agent_tools.zig", "zb_agent_tools_approve"): "{ if (server == null) return 0; return @intFromBool(cards.approve(card)); }",
    ("src/agent_tools.zig", "zb_agent_tools_deny"): "{ if (server == null) return 0; return @intFromBool(cards.deny(card)); }",
    ("src/agent_drawer.zig", "toolsApprove"): "{ return zb_agent_tools_approve(card) != 0; }",
    ("src/agent_drawer.zig", "toolsDeny"): "{ return zb_agent_tools_deny(card) != 0; }",
    ("src/agent_drawer.zig", "zb_drawer_card_press"):
        "{ var unused: u8 = 0; return @intFromEnum(cardPress(card, control, own != 0, "
        ".{ .ctx = &unused, .approve = toolsApprove, .deny = toolsDeny })); }",
}


def shape(code):
    """The token shape of (lexical) code: each `;`-statement, `{` and `}` in order, whitespace removed."""
    out, cur = [], ""
    for ch in code:
        if ch in "{};":
            if ch == ";" or cur.strip():
                out.append(re.sub(r"\s+", "", cur) + (";" if ch == ";" else ""))
            if ch != ";":
                out.append(ch)
            cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(re.sub(r"\s+", "", cur))
    return out


def zig_problems(files, bad):
    """The Zig graph ({repo-relative path: text}, import violations) -> the inventory's violations (empty: holds)."""
    found = list(bad)
    got = census(files)
    for key in sorted(set(got) | set(ALLOWED)):
        if got[key] != ALLOWED[key]:
            found.append(f"Z: {key} occurs {got[key]} times, want {ALLOWED[key]}")
    reflective = Counter()
    for f, text in files.items():
        code, kept = zig_lexical(text), zig_lexical(text, keep_strings=True)
        spans = fn_spans(code)
        for word in DYNAMIC:
            if re.search(re.escape(word) + (r"\b" if word[0] != "@" else r"\s*\("), code):
                found.append(f"Z: {f} uses {word} (a lookup by name)")
        for m in re.finditer(r"@field\(", code):
            args, end = call_args(kept, m.end())
            if len(args) != 2 or not re.fullmatch(r'"(?:[^"\\\n]|\\.)*"', args[1].strip()):
                reflective[(f, where(code, spans, m.start()), re.sub(r"\s+", "", kept[m.start():end]))] += 1
        for m in re.finditer(r"@export\(", kept):
            if not re.match(r'@export\(\s*&\w+\s*,\s*\.\{\s*\.name\s*=\s*"[A-Za-z0-9_]+"\s*\}\s*\)', kept[m.start():]):
                found.append(f"Z: {f}: every @export names its symbol with one plain literal")
    for key in sorted(reflective):
        if reflective[key] > REFLECTIVE[key]:
            found.append(f"Z: reflective @field {key} occurs {reflective[key]} times, at most {REFLECTIVE[key]} reviewed")
    tools = zig_lexical(files.get("src/agent_tools.zig", ""))
    drawer = files.get("src/agent_drawer.zig", "")
    for name in ("zb_agent_tools_approve", "zb_agent_tools_deny"):
        if not re.search(r"\bexport\s+fn\s+" + name + r"\s*\(", tools):
            found.append(f"Z: {name} must be src/agent_tools.zig's `export fn`")
        if not re.search(r"\bextern\s+fn\s+" + name + r"\s*\(", zig_lexical(drawer)):
            found.append(f"Z: src/agent_drawer.zig must declare {name} as `extern fn`")
    for (path, fn), want in BODIES.items():
        code = zig_lexical(files.get(path, ""))
        spans = [sp for sp in fn_spans(code) if sp[2] == fn]
        if len(spans) != 1:
            found.append(f"Z: want exactly one {path} fn {fn} ({len(spans)})")
        elif shape(code[spans[0][0]:spans[0][1]]) != shape(zig_lexical(want)):
            found.append(f"Z: {path} fn {fn} must be exactly `{want}`")
    exports = re.findall(r'@export\(\s*&zb_drawer_card_press\s*,\s*\.\{\s*\.name\s*=\s*"([^"]*)"\s*\}\s*\)',
                         zig_lexical(drawer, keep_strings=True))
    if exports != ["zb_drawer_card_press"]:
        found.append(f'Z: zb_drawer_card_press must be exported once, under exactly that name (got {exports})')
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


Z_FILES = {
    "src/main.zig": 'const app = @import("app.zig");\n',
    "src/app.zig": 'const drawer = @import("agent_drawer.zig");\nconst tools = @import("agent_tools.zig");\n',
    "src/agent_approval.zig": "pub const Cards = struct {\n    pub fn approve(self: *Cards, id: u64) bool { _ = self; _ = id; return true; }\n"
                              "    pub fn deny(self: *Cards, id: u64) bool { _ = self; _ = id; return true; }\n};\n",
    "src/agent_tools.zig": 'const approval = @import("agent_approval.zig");\nvar cards: approval.Cards = .{};\n'
                           "// the main drawer's Approve button, the only caller of zb_agent_tools_approve\n"
                           "var server: ?*u8 = null;\n"
                           "export fn zb_agent_tools_approve(card: u64) c_int {\n    if (server == null) return 0;\n"
                           "    return @intFromBool(cards.approve(card));\n}\n"
                           "export fn zb_agent_tools_deny(card: u64) c_int {\n    if (server == null) return 0;\n"
                           "    return @intFromBool(cards.deny(card));\n}\n",
    "src/agent_drawer.zig": "pub const Approver = struct { ctx: *anyopaque, approve: *const fn (*anyopaque, u64) bool, "
                            "deny: *const fn (*anyopaque, u64) bool };\n"
                            "pub fn cardPress(card: u64, control: c_int, own: bool, approver: Approver) c_int {\n"
                            "    if (!own) return 0;\n    return switch (control) {\n"
                            "        1 => if (approver.approve(approver.ctx, card)) 1 else 3,\n"
                            "        2 => if (approver.deny(approver.ctx, card)) 2 else 3,\n        else => 0,\n    };\n}\n"
                            "extern fn zb_agent_tools_approve(card: u64) c_int;\nextern fn zb_agent_tools_deny(card: u64) c_int;\n"
                            "fn toolsApprove(_: *anyopaque, card: u64) bool {\n    return zb_agent_tools_approve(card) != 0;\n}\n"
                            "fn toolsDeny(_: *anyopaque, card: u64) bool {\n    return zb_agent_tools_deny(card) != 0;\n}\n"
                            "pub fn zb_drawer_card_press(card: u64, control: c_int, own: c_int) callconv(.c) c_int {\n"
                            "    var unused: u8 = 0;\n"
                            "    return @intFromEnum(cardPress(card, control, own != 0, .{ .ctx = &unused, .approve = toolsApprove, .deny = toolsDeny }));\n}\n"
                            'comptime {\n    @export(&zb_drawer_card_press, .{ .name = "zb_drawer_card_press" });\n}\n',
}


def z_graph(files):
    return graph(lambda f: files.get(f), "src/main.zig")


def z_mutant(path, old, new):
    assert Z_FILES[path].count(old) == 1, old
    return dict(Z_FILES, **{path: Z_FILES[path].replace(old, new)})


def z_substituted():
    files = {k: v for k, v in Z_FILES.items() if k not in ("src/agent_tools.zig", "src/agent_approval.zig")}
    files["src/evil/agent_tools.zig"] = Z_FILES["src/agent_tools.zig"]
    files["src/evil/agent_approval.zig"] = Z_FILES["src/agent_approval.zig"]
    files["src/app.zig"] = Z_FILES["src/app.zig"].replace('"agent_tools.zig"', '"evil/agent_tools.zig"')
    return files


Z_MUTANTS = {  # name -> (graph, the reason it must fail for)
    "a planted second Zig caller": (z_mutant("src/app.zig", "const tools", "extern fn zb_agent_tools_approve(card: u64) c_int;\n"
                                             "pub fn auto() void { _ = zb_agent_tools_approve(7); }\nconst tools"),
                                    "('src/app.zig', 'zb_agent_tools_approve', 'auto')"),
    "an alias of the minter": (z_mutant("src/agent_drawer.zig", "fn toolsDeny", "const mint = zb_agent_tools_approve;\nfn toolsDeny"),
                               "('src/agent_drawer.zig', 'zb_agent_tools_approve', '-') occurs 2"),
    "an alias of Cards.approve": (z_mutant("src/app.zig", "const tools", 'const f = @import("agent_approval.zig").Cards.approve;\nconst tools'),
                                  "('src/app.zig', 'approve', '-')"),
    "a second cards.approve caller": (z_mutant("src/agent_tools.zig", "export fn zb_agent_tools_deny",
                                               "export fn zb_auto(card: u64) c_int { return @intFromBool(cards.approve(card)); }\n"
                                               "export fn zb_agent_tools_deny"), "('src/agent_tools.zig', 'approve', 'zb_auto')"),
    "Zig calls the bridge": (z_mutant("src/app.zig", "const tools", "pub fn k() void { _ = drawer.zb_drawer_card_press(1, 1, 1); }\nconst tools"),
                             "('src/app.zig', 'zb_drawer_card_press', 'k')"),
    "a second export of the bridge": (z_mutant("src/agent_drawer.zig", "comptime {\n", 'comptime {\n    @export(&zb_drawer_card_press, .{ .name = "zb_more" });\n'),
                                      "exported once, under exactly that name"),
    "the bridge under another name": (z_mutant("src/agent_drawer.zig", '.name = "zb_drawer_card_press"', '.name = "zb_press"'),
                                      "exported once, under exactly that name"),
    "an unreviewed module": (z_mutant("src/app.zig", "const tools", 'const sneaky = @import("sneaky");\nconst tools'), "unreviewed module 'sneaky'"),
    "the minter not exported": (z_mutant("src/agent_tools.zig", "export fn zb_agent_tools_approve", "pub fn zb_agent_tools_approve"),
                                "must be src/agent_tools.zig's `export fn`"),
    "an unreachable drawer": (z_mutant("src/app.zig", 'const drawer = @import("agent_drawer.zig");\n', ""),
                              "('src/agent_drawer.zig', 'zb_drawer_card_press', '-') occurs 0"),
    # RoseCat 8079 / 2796d94
    "an @field caller by string": (z_mutant("src/agent_tools.zig", "export fn zb_agent_tools_deny",
                                            'export fn zb_auto(c: u64) c_int { return @field(@This(), "zb_agent_tools_approve")(c); }\n'
                                            "export fn zb_agent_tools_deny"), "('src/agent_tools.zig', '\"zb_agent_tools_approve\"', 'zb_auto')"),
    "an @extern caller by string": (z_mutant("src/app.zig", "const tools",
                                             'pub fn auto(c: u64) c_int { return @extern(*const fn (u64) callconv(.c) c_int, .{ .name = "zb_agent_tools_approve" })(c); }\n'
                                             "const tools"), "src/app.zig uses @extern"),
    "an @extern by a built name": (z_mutant("src/app.zig", "const tools",
                                            'pub fn auto(c: u64) c_int { return @extern(*const fn (u64) callconv(.c) c_int, .{ .name = "zb_agent_" ++ "tools_appr" ++ "ove" })(c); }\n'
                                            "const tools"), "src/app.zig uses @extern"),
    "an @field by a built name": (z_mutant("src/agent_tools.zig", "export fn zb_agent_tools_deny",
                                           'export fn zb_auto(c: u64) c_int { return @field(@This(), "zb_agent_" ++ "tools_appr" ++ "ove")(c); }\n'
                                           "export fn zb_agent_tools_deny"), "reflective @field ('src/agent_tools.zig', 'zb_auto'"),
    "a lookup through dlsym": (z_mutant("src/app.zig", "const tools", 'pub fn auto() ?*anyopaque { return std.c.dlsym(null, name); }\nconst tools'),
                               "src/app.zig uses dlsym"),
    "files substituted under src/evil/": (z_substituted(), "('src/evil/agent_tools.zig', 'zb_agent_tools_approve', '-') occurs 1 times, want 0"),
    "an import outside the repository": (z_mutant("src/app.zig", "const tools", 'const out = @import("../../outside/agent_tools.zig");\nconst tools'),
                                         "import outside the repository: ../outside/agent_tools.zig"),
    # RoseCat 8097 / 4124a1b: a card consumed twice
    "Cards.approve called twice through an alias": (z_mutant("src/agent_tools.zig", "    return @intFromBool(cards.approve(card));\n",
                                                             "    const mint = approval.Cards.approve;\n"
                                                             "    return @intFromBool(mint(&cards, card)) + @intFromBool(mint(&cards, card));\n"),
                                                    "src/agent_tools.zig fn zb_agent_tools_approve must be exactly"),
    "Cards.deny called twice through an alias": (z_mutant("src/agent_tools.zig", "    return @intFromBool(cards.deny(card));\n",
                                                          "    const mint = approval.Cards.deny;\n"
                                                          "    return @intFromBool(mint(&cards, card)) + @intFromBool(mint(&cards, card));\n"),
                                                 "src/agent_tools.zig fn zb_agent_tools_deny must be exactly"),
    "Cards.approve in a loop": (z_mutant("src/agent_tools.zig", "    return @intFromBool(cards.approve(card));\n",
                                         "    var won = false;\n    for (0..2) |_| won = cards.approve(card);\n    return @intFromBool(won);\n"),
                                "src/agent_tools.zig fn zb_agent_tools_approve must be exactly"),
    "the minter asked twice by the bridge": (z_mutant("src/agent_drawer.zig", "    return zb_agent_tools_approve(card) != 0;\n",
                                                      "    _ = zb_agent_tools_approve(card);\n    return zb_agent_tools_approve(card) != 0;\n"),
                                             "src/agent_drawer.zig fn toolsApprove must be exactly"),
    "a renamed export behind a comment decoy": (z_mutant("src/agent_drawer.zig", '    @export(&zb_drawer_card_press, .{ .name = "zb_drawer_card_press" });\n',
                                                         '    // @export(&zb_drawer_card_press, .{ .name = "zb_drawer_card_press" });\n'
                                                         '    @export(&zb_drawer_card_press, .{ .name = "zb_press" });\n'),
                                                "under exactly that name (got ['zb_press'])"),
}

BUILD_ZIG = '''pub fn build(b: *std.Build) void {
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .imports = &.{
            .{ .name = "build_options", .module = site_options_module },
        },
        .target = target,
        .optimize = optimize,
    });
    configureBackend(root_module, b, backend, webview2_paths);

    const exe = b.addExecutable(.{
        .name = "zigBrowser",
        .root_module = root_module,
    });
    b.installArtifact(exe);
}
'''


def build_mutant(old, new):
    assert BUILD_ZIG.count(old) == 1, old
    return BUILD_ZIG.replace(old, new)


ROOT_MUTANTS = {  # name -> (build.zig, the reason it must fail for)
    "a substituted executable root": (build_mutant('b.path("src/main.zig")', 'b.path("src/evil_main.zig")'),
                                      "root is src/evil_main.zig, want src/main.zig"),
    "the root in a comment, another in code": (build_mutant('        .root_source_file = b.path("src/main.zig"),\n',
                                                            '        // .root_source_file = b.path("src/main.zig"),\n'
                                                            '        .root_source_file = b.path("src/evil_main.zig"),\n'),
                                               "root is src/evil_main.zig"),
    "another import on the root module": (build_mutant("    configureBackend(", '    root_module.addImport("evil", evil_module);\n    configureBackend('),
                                          "must gain no other import"),
    "a second executable named zigBrowser": (build_mutant("    b.installArtifact(exe);\n",
                                                          "    b.installArtifact(exe);\n    const exe2 = b.addExecutable(.{\n"
                                                          '        .name = "zigBrowser",\n        .root_module = other,\n    });\n'),
                                             "want exactly one zigBrowser executable"),
    "the executable not installed": (build_mutant("    b.installArtifact(exe);\n", ""), "must install exe once"),
}


class CardAuthority(unittest.TestCase):
    def test_the_real_macos_link_keeps_the_one_minter(self):
        build = (REPO / "build.zig").read_text()
        sources = mac_link_sources(build)
        self.assertIn("src/wkwebview_shim.m", sources, "the link parser found no macOS sources")
        files = {p: (REPO / p).read_text() for p in sources if (REPO / p).exists()}
        self.assertEqual(mac_build_problems(build) + problems(sources, files), [])

    def test_the_honest_build_passes(self):
        self.assertEqual(mac_build_problems(HONEST_BUILD), [])

    def test_each_dishonest_build_fails_for_its_reason(self):
        for name, (text, reason) in BUILD_MUTANTS.items():
            with self.subTest(mutant=name):
                found = mac_build_problems(text)
                self.assertTrue(any(f.startswith(reason) for f in found), (name, found))

    def test_the_real_zig_graph_keeps_the_one_minter(self):
        root, bad_root = exe_root((REPO / "build.zig").read_text())
        self.assertEqual(bad_root, [])
        files, bad = graph(lambda f: (REPO / f).read_text() if (REPO / f).is_file() else None, root)
        self.assertGreater(len(files), 20, "the graph walk found too little of the app")
        self.assertEqual(zig_problems(files, bad), [])

    def test_the_honest_build_root_passes(self):
        self.assertEqual(exe_root(BUILD_ZIG), ("src/main.zig", []))

    def test_each_dishonest_build_root_fails_for_its_reason(self):
        for name, (text, reason) in ROOT_MUTANTS.items():
            with self.subTest(mutant=name):
                found = exe_root(text)[1]
                self.assertTrue(any(reason in f for f in found), (name, found))

    def test_the_honest_zig_graph_passes(self):
        self.assertEqual(zig_problems(*z_graph(Z_FILES)), [])

    def test_each_dishonest_zig_graph_fails_for_its_reason(self):
        for name, (files, reason) in Z_MUTANTS.items():
            with self.subTest(mutant=name):
                found = zig_problems(*z_graph(files))
                self.assertTrue(any(reason in f for f in found), (name, found))

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
