//! S6b2's capture at the RESPONSE decision (chat-drawer plan rev 16.20.33; RoseCat 6457 #1, 6466;
//! BlackRobin 6463). WebKitGTK's navigation decision cannot tell a subframe from the main frame
//! (probed: same type, frame name, headers, gesture and redirect flags); only the response
//! decision can (`is_main_frame_main_resource`). So a navigation that decideNavigation would
//! capture only records ONE pending callback (its exact URI) and is let through; the capture
//! happens at its response, decided here by `agent_auth.decideResponse(authorize_url, pending,
//! response_url, main_frame, captured, out)`:
//! - a response that is not the redirect_uri's callback: pass (WebKit's default);
//! - a callback response in a subframe: block `subframe` (ignored before commit; nothing sent);
//! - a main-frame callback response that is not exactly the pending record (none pending, or
//!   another URI): block `unexpected` (pending alone is never authority, nor is a response alone);
//! - the exact pending URI in the main frame: decideNavigation is run again on it, and only its
//!   `capture` captures (`<code>#<state>`); after a capture, `replay`.
//! Outside the gate until the green registers it.
const std = @import("std");
const auth = @import("agent_auth");

const has = @hasDecl(auth, "decideResponse");

const authorize = "https://claude.com/cai/oauth/authorize?code=true&client_id=00000000-0000-4000-8000-00000000fa6e" ++
    "&response_type=code&redirect_uri=https://platform.claude.com/oauth/code/callback&scope=user:inference" ++
    "&code_challenge=Zb3_challenge-0123456789abcdefghijklmnopqrs&code_challenge_method=S256&state=zbState-0123";
const callback = "https://platform.claude.com/oauth/code/callback";
const good = callback ++ "?code=abc&state=zbState-0123";
const other_good = callback ++ "?code=xyz&state=zbState-0123";

const Want = union(enum) { pass, capture: []const u8, block: []const u8 };

fn expect(pending: ?[]const u8, response: []const u8, main_frame: bool, captured: bool, want: Want) !void {
    if (!has) return error.TestNoDecideResponse;
    var buf: [4096]u8 = undefined;
    const got = auth.decideResponse(authorize, pending, response, main_frame, captured, &buf);
    const ok = switch (want) {
        .pass => got == .pass,
        .capture => |w| got == .capture and std.mem.eql(u8, got.capture, w),
        .block => |w| got == .block and std.mem.eql(u8, @tagName(got.block), w),
    };
    if (!ok) {
        std.debug.print("{s} (pending {?s}, main {}, captured {}): got {s}", .{ response, pending, main_frame, captured, @tagName(got) });
        switch (got) {
            .pass => {},
            .capture => |c| std.debug.print(" {s}", .{c}),
            .block => |b| std.debug.print(" {s}", .{@tagName(b)}),
        }
        std.debug.print(", want {s}\n", .{@tagName(want)});
        return error.TestUnexpectedResult;
    }
}

test "the exact pending callback, in the main frame, is captured" {
    try expect(good, good, true, false, .{ .capture = "abc#zbState-0123" });
}

test "a callback response in a subframe is blocked, pending or not, valid or not" {
    try expect(good, good, false, false, .{ .block = "subframe" });
    try expect(null, good, false, false, .{ .block = "subframe" });
    try expect(other_good, good, false, false, .{ .block = "subframe" });
}

test "pending alone is no authority: another callback in the main frame is unexpected" {
    try expect(good, other_good, true, false, .{ .block = "unexpected" });
    try expect(null, good, true, false, .{ .block = "unexpected" });
    // the same path and state, another code: still not the pending record
    try expect(good, callback ++ "?code=abd&state=zbState-0123", true, false, .{ .block = "unexpected" });
}

test "the exact match is decided again: after a capture it is a replay" {
    try expect(good, good, true, true, .{ .block = "replay" });
}

test "a response that is not the callback passes, in any frame" {
    for ([_][]const u8{
        authorize,
        "https://claude.ai/login",
        "https://accounts.google.com/o/oauth2/v2/auth",
        callback ++ "/",
        "https://platform.claude.com:8443/oauth/code/callback?code=abc&state=zbState-0123",
    }) |r| {
        try expect(good, r, true, false, .pass);
        try expect(good, r, false, false, .pass);
        try expect(null, r, true, false, .pass);
    }
}

test "an authorize URL the app refuses: a callback response captures nothing" {
    if (!has) return error.TestNoDecideResponse;
    var buf: [4096]u8 = undefined;
    const bad = "https://claude.com.evil.example/cai/oauth/authorize?code=true&state=s";
    const got = auth.decideResponse(bad, good, good, true, false, &buf);
    try std.testing.expect(got != .capture);
}
