//! S8a red (chat-drawer plan rev 16.20.44, "S8 in detail" decision 2, phases A to C for flows):
//! an approved real run of an acting flow carries `options.expect {origin, load_serial, url}` and,
//! inside its own ticket:
//! - phase A, before the session gate, the pacing pause or any page input: the bound window's
//!   origin and load_serial are the card's, no dialog is open and it has not crashed (as for the
//!   verbs: -32013, or -32015 `crashed` / `origin_changed` / `load_serial_changed`);
//! - phase B: the flow's one navigation goes to exactly `url`, else -32015
//!   `unapproved_navigation` and nothing is navigated;
//! - phase C: the navigation committed exactly `url` (-32015 `url_changed`), and the window's new
//!   load_serial and automation.js's per-document token (op `documentToken`, the isolated world's
//!   own) are captured; every later action step finds both unchanged (-32015
//!   `load_serial_changed`, `document_token_changed`), so a superseding navigation or a replaced
//!   document between the approved navigation and the first edit, or between two edits, sends
//!   nothing further. Before phase C, nothing but that one navigation runs (an action, a reload,
//!   another or a second navigation: -32015 `unapproved_navigation`, nothing sent; RoseCat 7098).
//! A refused run consumes no pacing. `expect` with a dry run, without a bound window, or malformed
//! is -32602 and nothing runs. (The per-event in-task guard is the later S8a slice; these checks
//! read the window registry between steps.)

const std = @import("std");
const automation = @import("automation");
const flow_fake = @import("automation/flow_fake.zig");

const social_flow_routes = automation.social_flow_routes;
const engine = automation.engine;
const page_port = automation.page_port;
const Harness = flow_fake.Harness;
const feed = flow_fake.feed;
const post = flow_fake.post;
const likeParams = flow_fake.likeParams;
const expectRefused = flow_fake.expectRefused;
const realClicks = flow_fake.realClicks;
const countOps = flow_fake.countOps;

const testing = std.testing;
const gpa = testing.allocator;

test "flow phases: a matching approval runs the flow once, reading the window before and after its navigation" {
    var h: Harness = undefined;
    h.init(feed);
    defer h.deinit();
    const before = h.state.remaining();
    var buf: [512]u8 = undefined;
    var outcome = try h.call("linkedin.like", try likeParams(&buf, "https://www.linkedin.com", 3, post));
    defer outcome.deinit(gpa);
    if (outcome != .result) {
        std.debug.print("failure {d} {s}\n", .{ outcome.failure.code, outcome.failure.data_json orelse "" });
        return error.TestUnexpectedResult;
    }
    try testing.expectEqualStrings("{\"ok\":true}", outcome.result);
    try testing.expectEqual(@as(usize, 1), h.fake.navigate_calls.items.len);
    try testing.expectEqual(@as(usize, 1), realClicks(&h.fake));
    try testing.expectEqual(before - 1, h.state.remaining());
    // Phase A, phase C, and before the action.
    try testing.expect(h.windows.list_calls >= 3);
    // Phase C captured the document's token, and the action checked it again.
    try testing.expect(h.windows.token_reads >= 2);
}

test "flow phase C: a replaced document with the approved URL and load_serial sends nothing (RoseCat 7098 #1)" {
    var h: Harness = undefined;
    h.init(feed);
    defer h.deinit();
    h.windows.token_bump_after_first_eval_after_nav = true;
    const before = h.state.remaining();
    var buf: [512]u8 = undefined;
    var outcome = try h.call("linkedin.like", try likeParams(&buf, "https://www.linkedin.com", 3, post));
    defer outcome.deinit(gpa);
    try expectRefused(outcome, -32015, "document_token_changed");
    try testing.expectEqual(@as(u64, 1), h.windows.token_bumps);
    try testing.expectEqual(@as(u64, 0), h.windows.bumps);
    try testing.expectEqual(@as(usize, 0), realClicks(&h.fake));
    try testing.expectEqual(before, h.state.remaining());
}

const PhaseA = enum { origin, load_serial, dialog, crashed };

fn phaseA(change: PhaseA, code: i64, reason: []const u8) !void {
    var h: Harness = undefined;
    h.init(feed);
    defer h.deinit();
    switch (change) {
        .origin => h.fake.current_url = "https://www.instagram.com/",
        .load_serial => h.windows.bumps = 1,
        .dialog => h.windows.dialog_open = true,
        .crashed => h.windows.crashed = true,
    }
    const before = h.state.remaining();
    var buf: [512]u8 = undefined;
    var outcome = try h.call("linkedin.like", try likeParams(&buf, "https://www.linkedin.com", 3, post));
    defer outcome.deinit(gpa);
    try expectRefused(outcome, code, reason);
    // Before the gate's pacing pause and any page input.
    try testing.expectEqual(@as(usize, 0), h.fake.navigate_calls.items.len);
    try testing.expectEqual(@as(usize, 0), h.fake.eval_calls.items.len);
    try testing.expectEqual(@as(usize, 0), h.sleeps());
    try testing.expectEqual(before, h.state.remaining());
}

test "flow phase A: another origin, serial, a dialog or a crash refuses before any page input or pacing" {
    try phaseA(.origin, -32015, "origin_changed");
    try phaseA(.load_serial, -32015, "load_serial_changed");
    try phaseA(.dialog, -32013, "");
    try phaseA(.crashed, -32015, "crashed");
}

test "flow phase B: a navigation to anything but the approved URL is refused before it starts" {
    var h: Harness = undefined;
    h.init(feed);
    defer h.deinit();
    const before = h.state.remaining();
    var buf: [512]u8 = undefined;
    var outcome = try h.call("linkedin.like", try likeParams(&buf, "https://www.linkedin.com", 3, "https://www.linkedin.com/feed/update/9/"));
    defer outcome.deinit(gpa);
    try expectRefused(outcome, -32015, "unapproved_navigation");
    try testing.expectEqual(@as(usize, 0), h.fake.navigate_calls.items.len);
    try testing.expectEqual(@as(usize, 0), realClicks(&h.fake));
    try testing.expectEqual(before, h.state.remaining());
}

test "flow phase C: a navigation that commits another URL is refused before the first action" {
    var h: Harness = undefined;
    h.init(feed);
    defer h.deinit();
    h.windows.land_url = "https://www.linkedin.com/feed/update/2/";
    const before = h.state.remaining();
    var buf: [512]u8 = undefined;
    var outcome = try h.call("linkedin.like", try likeParams(&buf, "https://www.linkedin.com", 3, post));
    defer outcome.deinit(gpa);
    try expectRefused(outcome, -32015, "url_changed");
    try testing.expectEqual(@as(usize, 1), h.fake.navigate_calls.items.len);
    try testing.expectEqual(@as(usize, 0), h.fake.eval_calls.items.len);
    try testing.expectEqual(before, h.state.remaining());
}

test "flow phase C: a superseding navigation between the approved one and the first edit sends nothing" {
    var h: Harness = undefined;
    h.init(feed);
    defer h.deinit();
    h.windows.bump_after_first_eval_after_nav = true;
    const before = h.state.remaining();
    var buf: [512]u8 = undefined;
    var outcome = try h.call("linkedin.like", try likeParams(&buf, "https://www.linkedin.com", 3, post));
    defer outcome.deinit(gpa);
    try expectRefused(outcome, -32015, "load_serial_changed");
    try testing.expect(h.windows.bumped);
    try testing.expectEqual(@as(usize, 0), realClicks(&h.fake));
    try testing.expectEqual(before, h.state.remaining());
}

test "flow phase C: a navigation between two edits stops the flow before the next one" {
    var h: Harness = undefined;
    h.init(feed);
    defer h.deinit();
    h.windows.bump_after_op = "fill";
    var outcome = try h.call("linkedin.comment", "{\"postUrl\":\"" ++ post ++ "\",\"text\":\"Nice\",\"options\":{\"expect\":{\"origin\":\"https://www.linkedin.com\",\"load_serial\":3,\"url\":\"" ++ post ++ "\"}}}");
    defer outcome.deinit(gpa);
    try expectRefused(outcome, -32015, "load_serial_changed");
    try testing.expect(h.windows.bumped);
    try testing.expectEqual(@as(usize, 1), countOps(&h.fake, "fill"));
    try testing.expectEqual(@as(usize, 0), countOps(&h.fake, "type"));
    // Nothing was clicked after the fill (the submit included).
    try testing.expectEqual(h.windows.clicks_at_bump, realClicks(&h.fake));
}

// A conversation approval names its recipient (decision 13, rev 16.20.52).
test "flow phases: linkedin.message and instagram.dm take an approval through their own parsers (RoseCat 7098 #2)" {
    const conversation = "https://www.linkedin.com/messaging/thread/7/";
    const cases = [_]struct { method: []const u8, start: []const u8, params: []const u8, navigated: []const u8 }{
        .{ .method = "linkedin.message", .start = feed, .navigated = conversation, .params = "{\"conversationUrl\":\"" ++ conversation ++ "\",\"text\":\"Hi\",\"options\":{\"expect\":{\"origin\":\"https://www.linkedin.com\",\"load_serial\":3,\"url\":\"" ++ conversation ++ "\",\"recipient\":\"carol\"}}}" },
        .{ .method = "instagram.dm", .start = "https://www.instagram.com/", .navigated = "https://www.instagram.com/ada/", .params = "{\"username\":\"ada\",\"text\":\"Hi\",\"options\":{\"expect\":{\"origin\":\"https://www.instagram.com\",\"load_serial\":3,\"url\":\"https://www.instagram.com/ada/\"}}}" },
    };
    for (cases) |case| {
        var h: Harness = undefined;
        h.init(case.start);
        defer h.deinit();
        var outcome = try h.call(case.method, case.params);
        defer outcome.deinit(gpa);
        if (outcome != .result) {
            std.debug.print("{s}: failure {d} {s}\n", .{ case.method, outcome.failure.code, outcome.failure.data_json orelse "" });
            return error.TestUnexpectedResult;
        }
        try testing.expectEqual(@as(usize, 1), h.fake.navigate_calls.items.len);
        try testing.expectEqualStrings(case.navigated, h.fake.navigate_calls.items[0]);
        try testing.expect(h.windows.token_reads >= 2);
    }
}

test "flow phases: an instagram.dm approved for another user navigates nowhere" {
    var h: Harness = undefined;
    h.init("https://www.instagram.com/");
    defer h.deinit();
    var outcome = try h.call("instagram.dm", "{\"username\":\"ada\",\"text\":\"Hi\",\"options\":{\"expect\":{\"origin\":\"https://www.instagram.com\",\"load_serial\":3,\"url\":\"https://www.instagram.com/bob/\"}}}");
    defer outcome.deinit(gpa);
    try expectRefused(outcome, -32015, "unapproved_navigation");
    try testing.expectEqual(@as(usize, 0), h.fake.navigate_calls.items.len);
    try testing.expectEqual(@as(usize, 0), realClicks(&h.fake));
}

const ExpectRow = struct { what: []const u8, expect: []const u8 };

/// Malformed `expect` objects (`{origin}` and `{url}` are substituted per platform).
const malformed = [_]ExpectRow{
    .{ .what = "expect not an object", .expect = "true" },
    .{ .what = "expect an array", .expect = "[]" },
    .{ .what = "no origin", .expect = "{\"load_serial\":3,\"url\":\"{url}\"}" },
    .{ .what = "origin not a string", .expect = "{\"origin\":7,\"load_serial\":3,\"url\":\"{url}\"}" },
    .{ .what = "an empty origin", .expect = "{\"origin\":\"\",\"load_serial\":3,\"url\":\"{url}\"}" },
    .{ .what = "no load_serial", .expect = "{\"origin\":\"{origin}\",\"url\":\"{url}\"}" },
    .{ .what = "load_serial a string", .expect = "{\"origin\":\"{origin}\",\"load_serial\":\"3\",\"url\":\"{url}\"}" },
    .{ .what = "a negative load_serial", .expect = "{\"origin\":\"{origin}\",\"load_serial\":-1,\"url\":\"{url}\"}" },
    .{ .what = "a fractional load_serial", .expect = "{\"origin\":\"{origin}\",\"load_serial\":3.5,\"url\":\"{url}\"}" },
    .{ .what = "no url", .expect = "{\"origin\":\"{origin}\",\"load_serial\":3}" },
    .{ .what = "url not a string", .expect = "{\"origin\":\"{origin}\",\"load_serial\":3,\"url\":7}" },
    .{ .what = "an empty url", .expect = "{\"origin\":\"{origin}\",\"load_serial\":3,\"url\":\"\"}" },
    .{ .what = "an unknown key", .expect = "{\"origin\":\"{origin}\",\"load_serial\":3,\"url\":\"{url}\",\"approved\":true}" },
};

/// The acting flows' parsers, one request shape each ({expect} substituted).
const parsers = [_]struct { method: []const u8, start: []const u8, origin: []const u8, url: []const u8, params: []const u8 }{
    .{ .method = "linkedin.like", .start = feed, .origin = "https://www.linkedin.com", .url = post, .params = "{\"postUrl\":\"" ++ post ++ "\",\"options\":{\"expect\":{expect}}}" },
    .{ .method = "linkedin.message", .start = feed, .origin = "https://www.linkedin.com", .url = "https://www.linkedin.com/messaging/thread/7/", .params = "{\"conversationUrl\":\"https://www.linkedin.com/messaging/thread/7/\",\"text\":\"Hi\",\"options\":{\"expect\":{expect}}}" },
    .{ .method = "instagram.like", .start = "https://www.instagram.com/", .origin = "https://www.instagram.com", .url = "https://www.instagram.com/p/1/", .params = "{\"postUrl\":\"https://www.instagram.com/p/1/\",\"options\":{\"expect\":{expect}}}" },
    .{ .method = "instagram.dm", .start = "https://www.instagram.com/", .origin = "https://www.instagram.com", .url = "https://www.instagram.com/ada/", .params = "{\"username\":\"ada\",\"text\":\"Hi\",\"options\":{\"expect\":{expect}}}" },
};

fn substitute(out: *std.ArrayListUnmanaged(u8), template: []const u8, keys: []const [2][]const u8) !void {
    var rest = template;
    outer: while (rest.len > 0) {
        for (keys) |kv| if (std.mem.startsWith(u8, rest, kv[0])) {
            try out.appendSlice(gpa, kv[1]);
            rest = rest[kv[0].len..];
            continue :outer;
        };
        try out.append(gpa, rest[0]);
        rest = rest[1..];
    }
}

test "flow phases: a malformed expect is -32602 through every acting flow's parser, and nothing runs (RoseCat 7098 SHOULD)" {
    for (parsers) |parser| for (malformed) |row| {
        var expect: std.ArrayListUnmanaged(u8) = .empty;
        defer expect.deinit(gpa);
        try substitute(&expect, row.expect, &.{ .{ "{origin}", parser.origin }, .{ "{url}", parser.url } });
        var params: std.ArrayListUnmanaged(u8) = .empty;
        defer params.deinit(gpa);
        try substitute(&params, parser.params, &.{.{ "{expect}", expect.items }});
        var h: Harness = undefined;
        h.init(parser.start);
        defer h.deinit();
        var outcome = try h.call(parser.method, params.items);
        defer outcome.deinit(gpa);
        testing.expect(outcome == .failure and outcome.failure.code == -32602) catch |e| {
            std.debug.print("{s} / {s}: not -32602\n", .{ parser.method, row.what });
            return e;
        };
        try testing.expectEqual(@as(usize, 0), h.fake.navigate_calls.items.len);
        try testing.expectEqual(@as(usize, 0), h.fake.eval_calls.items.len);
        try testing.expectEqual(@as(usize, 0), h.sleeps());
    };
}

test "flow phases: expect with a dry run or without a window is -32602 and nothing runs" {
    const cases = [_]struct { what: []const u8, params: []const u8, window: ?page_port.WindowId = 1 }{
        .{ .what = "dry run", .params = "{\"postUrl\":\"" ++ post ++ "\",\"options\":{\"dry_run\":true,\"expect\":{\"origin\":\"https://www.linkedin.com\",\"load_serial\":3,\"url\":\"" ++ post ++ "\"}}}" },
        .{ .what = "no window", .params = "{\"postUrl\":\"" ++ post ++ "\",\"options\":{\"expect\":{\"origin\":\"https://www.linkedin.com\",\"load_serial\":3,\"url\":\"" ++ post ++ "\"}}}", .window = null },
        .{ .what = "no url", .params = "{\"postUrl\":\"" ++ post ++ "\",\"options\":{\"expect\":{\"origin\":\"https://www.linkedin.com\",\"load_serial\":3}}}" },
        .{ .what = "url not a string", .params = "{\"postUrl\":\"" ++ post ++ "\",\"options\":{\"expect\":{\"origin\":\"https://www.linkedin.com\",\"load_serial\":3,\"url\":7}}}" },
        .{ .what = "an unknown key", .params = "{\"postUrl\":\"" ++ post ++ "\",\"options\":{\"expect\":{\"origin\":\"https://www.linkedin.com\",\"load_serial\":3,\"url\":\"" ++ post ++ "\",\"approved\":true}}}" },
    };
    for (cases) |case| {
        var h: Harness = undefined;
        h.init(feed);
        defer h.deinit();
        h.window = case.window;
        var outcome = try h.call("linkedin.like", case.params);
        defer outcome.deinit(gpa);
        testing.expect(outcome == .failure and outcome.failure.code == -32602) catch |e| {
            std.debug.print("{s}: not -32602\n", .{case.what});
            return e;
        };
        try testing.expectEqual(@as(usize, 0), h.fake.navigate_calls.items.len);
        try testing.expectEqual(@as(usize, 0), h.fake.eval_calls.items.len);
        try testing.expectEqual(@as(usize, 0), h.sleeps());
    }
}

test "flow phase A: a check that used up the flow budget is its timeout, whatever it found (RoseCat db43ca1)" {
    var h: Harness = undefined;
    h.init(feed);
    defer h.deinit();
    h.windows.clock = &h.clock;
    h.windows.list_cost_ms = social_flow_routes.flow_budget_ms + 1;
    h.windows.bumps = 1; // and it found another load_serial
    const before = h.state.remaining();
    var buf: [512]u8 = undefined;
    var outcome = try h.call("linkedin.like", try likeParams(&buf, "https://www.linkedin.com", 3, post));
    defer outcome.deinit(gpa);
    try expectRefused(outcome, -32009, "expect_used_deadline");
    try testing.expectEqual(@as(usize, 0), h.fake.navigate_calls.items.len);
    try testing.expectEqual(@as(usize, 0), h.fake.eval_calls.items.len);
    try testing.expectEqual(@as(usize, 0), h.sleeps());
    try testing.expectEqual(before, h.state.remaining());
}

test "flow phase A: a stop comes before a check that also used up the budget and found a change (RoseCat 4d62b4e)" {
    var h: Harness = undefined;
    h.init(feed);
    defer h.deinit();
    h.windows.clock = &h.clock;
    h.windows.list_cost_ms = social_flow_routes.flow_budget_ms + 1;
    h.windows.bumps = 1;
    h.windows.stop_during_list = &h.cancel;
    const before = h.state.remaining();
    var buf: [512]u8 = undefined;
    var outcome = try h.call("linkedin.like", try likeParams(&buf, "https://www.linkedin.com", 3, post));
    defer outcome.deinit(gpa);
    try expectRefused(outcome, -32012, "");
    try testing.expectEqual(@as(usize, 0), h.fake.navigate_calls.items.len);
    try testing.expectEqual(@as(usize, 0), h.fake.eval_calls.items.len);
    try testing.expectEqual(@as(usize, 0), h.sleeps());
    try testing.expectEqual(before, h.state.remaining());
}

test "flow phase C: an unreadable document token at capture or at the recheck sends nothing (RoseCat 7107)" {
    const Kind = @FieldType(flow_fake.Windowed, "unreadable");
    for ([_]usize{ 1, 2 }) |ordinal| for ([_]Kind{ .script_failure, .malformed, .empty, .missing }) |kind| {
        var h: Harness = undefined;
        h.init(feed);
        defer h.deinit();
        h.windows.token_unreadable_at = ordinal;
        h.windows.unreadable = kind;
        const before = h.state.remaining();
        var buf: [512]u8 = undefined;
        var outcome = try h.call("linkedin.like", try likeParams(&buf, "https://www.linkedin.com", 3, post));
        defer outcome.deinit(gpa);
        expectRefused(outcome, -32015, "document_token_unreadable") catch |e| {
            std.debug.print("read {d}, {s}\n", .{ ordinal, @tagName(kind) });
            return e;
        };
        try testing.expectEqual(ordinal, h.windows.token_reads);
        try testing.expectEqual(@as(usize, 0), realClicks(&h.fake));
        try testing.expectEqual(before, h.state.remaining());
    };
}
