//! Third-party sign-in in the auth window (chat-drawer plan rev 16.20.26, the user's decision on
//! ca1a7b7's question): `agent_auth.decideNavigation`'s allowlist gains exactly
//! `accounts.google.com` and `appleid.apple.com`, by the same rule as every allowed host (https,
//! port 443, no user info, ASCII lowercase). Nothing else is added: other labels, the apex
//! domains, country domains and lookalikes stay refused. Capture stays only on Claude's exact
//! callback: a `code` and `state` on a third-party host are the provider's, never a capture or a
//! replay. Outside the gate; the green moves these cases into agent_auth_navigation_test.zig.
const std = @import("std");
const auth = @import("agent_auth");

const authorize = "https://claude.com/cai/oauth/authorize?code=true&client_id=00000000-0000-4000-8000-00000000fa6e" ++
    "&response_type=code&redirect_uri=https://platform.claude.com/oauth/code/callback&scope=user:inference" ++
    "&code_challenge=Zb3_challenge-0123456789abcdefghijklmnopqrs&code_challenge_method=S256&state=zbState-0123";
const callback = "https://platform.claude.com/oauth/code/callback";

const Want = union(enum) { allow: []const u8, capture: []const u8, block: []const u8 };

fn expectDecision(nav: []const u8, captured: bool, want: Want) !void {
    var buf: [4096]u8 = undefined;
    const got = auth.decideNavigation(authorize, nav, captured, &buf);
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

const google = "https://accounts.google.com:443";
const apple = "https://appleid.apple.com:443";

test "Google's and Apple's sign-in hosts are allowed, https and port 443 only" {
    for ([_][]const u8{
        "https://accounts.google.com/o/oauth2/v2/auth?client_id=x&redirect_uri=https://claude.ai/x",
        "https://accounts.google.com/",
        "https://accounts.google.com:443/signin",
        "https://ACCOUNTS.Google.COM/x",
    }) |nav| try expectDecision(nav, false, .{ .allow = google });
    for ([_][]const u8{
        "https://appleid.apple.com/auth/authorize?client_id=x",
        "https://appleid.apple.com/",
        "https://appleid.apple.com:443/x",
        "https://AppleID.Apple.com/x",
    }) |nav| try expectDecision(nav, false, .{ .allow = apple });
}

test "only those two exact hosts: everything near them stays refused" {
    for ([_][]const u8{
        "https://google.com/",
        "https://www.google.com/",
        "https://x.accounts.google.com/",
        "https://accounts.google.com.evil.example/",
        "https://accountsgoogle.com/",
        "https://accounts-google.com/",
        "https://accounts.google.co.uk/",
        "https://accounts.google.com./x",
        "https://accounts.google.com:8443/",
        "https://user@accounts.google.com/",
        "https://ssl.gstatic.com/",
        "https://www.gstatic.com/",
        "https://accounts.youtube.com/",
        "https://apple.com/",
        "https://www.apple.com/",
        "https://idmsa.apple.com/",
        "https://appleid.cdn-apple.com/",
        "https://x.appleid.apple.com/",
        "https://appleid.apple.com.evil.example/",
        "https://appleidapple.com/",
        "https://appleid.apple.com:8443/",
        "https://user@appleid.apple.com/",
    }) |nav| try expectDecision(nav, false, .{ .block = "origin" });
    for ([_][]const u8{
        "http://accounts.google.com/",
        "http://appleid.apple.com/",
        "ws://accounts.google.com/",
    }) |nav| try expectDecision(nav, false, .{ .block = "scheme" });
}

test "capture stays only on Claude's exact callback" {
    // the callback's path and a valid code and state, on a third-party host: allowed, never captured
    try expectDecision("https://accounts.google.com/oauth/code/callback?code=abc&state=zbState-0123", false, .{ .allow = google });
    try expectDecision("https://appleid.apple.com/oauth/code/callback?code=abc&state=zbState-0123", false, .{ .allow = apple });
    // and never a replay after a capture
    try expectDecision("https://accounts.google.com/oauth/code/callback?code=abc&state=zbState-0123", true, .{ .allow = google });
    try expectDecision("https://appleid.apple.com/o?code=abc&state=zbState-0123", true, .{ .allow = apple });
    // Claude's callback still captures, then replays
    try expectDecision(callback ++ "?code=abc&state=zbState-0123", false, .{ .capture = "abc#zbState-0123" });
    try expectDecision(callback ++ "?code=abc&state=zbState-0123", true, .{ .block = "replay" });
}
