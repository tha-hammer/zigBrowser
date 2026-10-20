//! S6b2's navigation decision (chat-drawer plan rev 16.18.16): `agent_auth.decideNavigation(
//! authorize_url, nav_url, captured, out)` decides each main-frame navigation of the auth window,
//! before any window exists; the GTK body (and a later WKWebView body) only act on it.
//! 1. An authorize URL that `authorizeUrl` refuses: block `origin`, whatever the navigation.
//! 2. The callback (the redirect_uri's scheme, host, port and path, as checkCallback compares
//!    them): after a capture, block `replay`; else callbackCode decides: capture `<code>#<state>`,
//!    or block state, origin, path, scheme or code.
//! 3. Anything else: `https` (else block `scheme`) to an allowlisted origin (else block
//!    `origin`): claude.ai, platform.claude.com, claude.com, accounts.google.com and
//!    appleid.apple.com (rev 16.20.26; tests/agent_auth_thirdparty_test.zig), or one or more labels
//!    under anthropic.com (not anthropic.com itself); port 443 only; no user info; hosts in ASCII
//!    lowercase. Allowed: `https://<host>:443` for the `AUTH allowed` row.
//! Section 9's A2 cases are cases here: wrong state, missing state, another port, http versus
//! https, a host lookalike, a replayed callback after success.
const std = @import("std");
const auth = @import("agent_auth");

const has = @hasDecl(auth, "decideNavigation");

const authorize = "https://claude.com/cai/oauth/authorize?code=true&client_id=00000000-0000-4000-8000-00000000fa6e" ++
    "&response_type=code&redirect_uri=https://platform.claude.com/oauth/code/callback&scope=user:inference" ++
    "&code_challenge=Zb3_challenge-0123456789abcdefghijklmnopqrs&code_challenge_method=S256&state=zbState-0123";
const callback = "https://platform.claude.com/oauth/code/callback";

const Want = union(enum) { allow: []const u8, capture: []const u8, block: []const u8 };

fn expectDecision(authorize_url: []const u8, nav: []const u8, captured: bool, want: Want) !void {
    if (!has) return error.TestNoDecideNavigation;
    var buf: [4096]u8 = undefined;
    const got = auth.decideNavigation(authorize_url, nav, captured, &buf);
    const ok = switch (want) {
        .allow => |w| got == .allow and std.mem.eql(u8, got.allow, w),
        .capture => |w| got == .capture and std.mem.eql(u8, got.capture, w),
        .block => |w| got == .block and std.mem.eql(u8, @tagName(got.block), w),
    };
    if (!ok) {
        std.debug.print("{s} (captured {}): got {s}", .{ nav, captured, @tagName(got) });
        switch (got) {
            .allow => |a| std.debug.print(" {s}", .{a}),
            .capture => |c| std.debug.print(" {s}", .{c}),
            .block => |b| std.debug.print(" {s}", .{@tagName(b)}),
        }
        std.debug.print(", want {s}\n", .{@tagName(want)});
        return error.TestUnexpectedResult;
    }
}

test "the allowlist: the sign-in's own origins, https, port 443" {
    try expectDecision(authorize, authorize, false, .{ .allow = "https://claude.com:443" });
    try expectDecision(authorize, "https://claude.ai/login", false, .{ .allow = "https://claude.ai:443" });
    try expectDecision(authorize, "https://claude.ai:443/x", false, .{ .allow = "https://claude.ai:443" });
    try expectDecision(authorize, "https://CLAUDE.AI/x", false, .{ .allow = "https://claude.ai:443" });
    try expectDecision(authorize, "https://platform.claude.com/settings", false, .{ .allow = "https://platform.claude.com:443" });
    try expectDecision(authorize, "https://www.anthropic.com/", false, .{ .allow = "https://www.anthropic.com:443" });
    try expectDecision(authorize, "https://a.b.anthropic.com/x", false, .{ .allow = "https://a.b.anthropic.com:443" });
    // the callback's origin but not its path: an ordinary platform.claude.com page
    try expectDecision(authorize, callback ++ "/", false, .{ .allow = "https://platform.claude.com:443" });
}

test "the callback is captured once, as <code>#<state>" {
    try expectDecision(authorize, callback ++ "?code=abc&state=zbState-0123", false, .{ .capture = "abc#zbState-0123" });
    try expectDecision(authorize, "https://PLATFORM.claude.com:443/oauth/code/callback?state=zbState-0123&code=x-1", false, .{ .capture = "x-1#zbState-0123" });
}

test "section 9's A2 cases" {
    // wrong state
    try expectDecision(authorize, callback ++ "?code=abc&state=another", false, .{ .block = "state" });
    // missing state
    try expectDecision(authorize, callback ++ "?code=abc", false, .{ .block = "state" });
    // another port: not the callback, and not an allowed origin
    try expectDecision(authorize, "https://platform.claude.com:8443/oauth/code/callback?code=abc&state=zbState-0123", false, .{ .block = "origin" });
    // http versus https
    try expectDecision(authorize, "http://platform.claude.com/oauth/code/callback?code=abc&state=zbState-0123", false, .{ .block = "scheme" });
    // a host lookalike
    try expectDecision(authorize, "https://platform.claude.com.evil.example/oauth/code/callback?code=abc&state=zbState-0123", false, .{ .block = "origin" });
    // a replayed callback after success
    try expectDecision(authorize, callback ++ "?code=abc&state=zbState-0123", true, .{ .block = "replay" });
    // after a capture, only the exact callback is a replay: another port, scheme or host is not
    try expectDecision(authorize, "https://platform.claude.com:8443/oauth/code/callback?code=abc&state=zbState-0123", true, .{ .block = "origin" });
    try expectDecision(authorize, "http://platform.claude.com/oauth/code/callback?code=abc&state=zbState-0123", true, .{ .block = "scheme" });
    try expectDecision(authorize, "https://platform.claude.com.evil.example/oauth/code/callback?code=abc&state=zbState-0123", true, .{ .block = "origin" });
}

test "the callback's other refusals come from callbackCode" {
    try expectDecision(authorize, callback ++ "?state=zbState-0123", false, .{ .block = "code" });
    try expectDecision(authorize, callback ++ "?code=&state=zbState-0123", false, .{ .block = "code" });
    try expectDecision(authorize, callback ++ "?code=a%20b&state=zbState-0123", false, .{ .block = "code" });
    try expectDecision(authorize, callback ++ "?code=abc&state=zbState-0123&state=zbState-0123", false, .{ .block = "state" });
}

test "everything else is refused: scheme or origin" {
    for ([_][]const u8{
        "https://anthropic.com/",
        "https://evilanthropic.com/",
        "https://anthropic.com.evil.example/",
        "https://claude.ai.evil.example/",
        "https://claude.ai:8443/",
        "https://user@claude.ai/",
        "https://claude.ai./x",
        "https://xn--claude-xxx.ai/",
    }) |nav| try expectDecision(authorize, nav, false, .{ .block = "origin" });
    for ([_][]const u8{
        "http://claude.ai/",
        "javascript:alert(1)",
        "data:text/html,hi",
        "file:///etc/passwd",
        "about:blank",
        "ws://claude.ai/",
    }) |nav| try expectDecision(authorize, nav, false, .{ .block = "scheme" });
}

test "an authorize URL the app refuses allows nothing" {
    const bad = "https://claude.com.evil.example/cai/oauth/authorize?code=true&state=s";
    try expectDecision(bad, "https://claude.ai/login", false, .{ .block = "origin" });
    try expectDecision(bad, callback ++ "?code=abc&state=s", false, .{ .block = "origin" });
}
