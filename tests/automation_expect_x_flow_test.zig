//! S8a red (chat-drawer plan, "S8 in detail" decision 2 for the X flows): an approved real run of
//! `x.post` or `x.schedule_post` carries `options.expect {origin, load_serial, url}`, exactly as the
//! LinkedIn and Instagram flows do (tests/automation_expect_flow_test.zig), inside its own ticket:
//! - phase A, before the daily cap's reservation or any page input: the bound window's origin and
//!   load_serial are the card's (-32015 `origin_changed` / `load_serial_changed`), and a refused
//!   run reserves nothing;
//! - phase B: the flow's one navigation goes to exactly `url`, its `compose_url` (else -32015
//!   `unapproved_navigation`, nothing navigated);
//! - phase C: the navigation committed exactly `url` (-32015 `url_changed`), and every later
//!   action finds the window's load_serial and automation.js's document token unchanged
//!   (`load_serial_changed`, `document_token_changed`): nothing further is clicked or typed.
//! `expect` with `dry_run`, without a bound window, with native or humanized input (decision 4),
//! malformed, or naming a `recipient`, is -32602 and nothing runs.

const std = @import("std");
const automation = @import("automation");
const fakes = @import("automation/fake_page_port.zig");
const flow_fake = @import("automation/flow_fake.zig");

const x_routes = automation.x_routes;
const engine = automation.engine;
const page_port = automation.page_port;
const realClicks = flow_fake.realClicks;
const countOps = flow_fake.countOps;
const expectRefused = flow_fake.expectRefused;

const testing = std.testing;
const gpa = testing.allocator;

var fake_wall_ms: i64 = 1_791_644_400_000;
fn fakeWall() i64 {
    return fake_wall_ms;
}

const home = "https://x.com/home";
const compose = "https://x.com/compose/post";

/// An X flow through `engine.executeExternal` with a bound window over flow_fake's one-window
/// registry (its load_serial, URL and automation.js document token under the test's control).
const XHarness = struct {
    fake: fakes.FakePagePort,
    windows: flow_fake.Windowed,
    clock: fakes.FakeClock,
    engine: engine.Engine,
    state: x_routes.XState,
    window: ?page_port.WindowId = 1,
    cancel: std.atomic.Value(bool) = .init(false),

    fn init(self: *XHarness) void {
        self.fake = fakes.FakePagePort.init(gpa);
        self.fake.eval_replies = &.{flow_fake.flow_ok};
        self.fake.navigate_sets_url = true;
        self.fake.current_url = home;
        self.windows = .{ .inner = &self.fake };
        self.clock = fakes.FakeClock.init(gpa);
        self.engine = engine.Engine.init(self.windows.port(), self.clock.clock());
        self.state = x_routes.XState.init(fakeWall);
        self.window = 1;
        self.cancel = .init(false);
    }

    fn deinit(self: *XHarness) void {
        self.fake.deinit();
        self.clock.deinit();
    }

    fn call(self: *XHarness, method: []const u8, params: []const u8) !engine.Outcome {
        const Call = struct {
            state: *x_routes.XState,
            verb: x_routes.Verb,
            params: []const u8,
            fn run(c: @This(), a: std.mem.Allocator, ext: *engine.External) error{OutOfMemory}!engine.Outcome {
                return x_routes.handle(a, c.state, ext, c.verb, c.params);
            }
        };
        return self.engine.executeExternal(gpa, method, "x", .{ .window = self.window, .cancel = &self.cancel }, Call{
            .state = &self.state,
            .verb = x_routes.verbFromMethod(method).?,
            .params = params,
        }, Call.run);
    }
};

/// The two X verbs an approval binds, each with the page input that commits it.
const Verb = struct {
    method: []const u8,
    /// Request params before `"options"` (the approval is appended).
    head: []const u8,
    /// Real clicks a completed run sends (x.post: the composer and Post; a schedule adds its
    /// option and its confirm), and the schedule's selectOption steps.
    clicks: usize,
    selects: usize,
};

const verbs = [_]Verb{
    .{ .method = "x.post", .head = "{\"text\":\"Hello\",\"compose_url\":\"" ++ compose ++ "\"", .clicks = 2, .selects = 0 },
    .{ .method = "x.schedule_post", .head = "{\"text\":\"Later\",\"date\":\"2026-11-05\",\"time\":\"14:07\",\"compose_url\":\"" ++ compose ++ "\"", .clicks = 4, .selects = 6 },
};

fn approved(buf: []u8, verb: Verb, serial: u64, approved_url: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s},\"options\":{{\"expect\":{{\"origin\":\"https://x.com\",\"load_serial\":{d},\"url\":\"{s}\"}}}}}}", .{ verb.head, serial, approved_url });
}

/// The daily cap is as it was: nothing reserved now, nothing left in flight.
fn expectCapUntouched(h: *XHarness, remaining_before: u32) !void {
    try testing.expectEqual(remaining_before, h.state.remaining());
    try testing.expectEqual(@as(u32, 0), h.state.in_flight);
}

fn expectNothingRan(h: *XHarness, remaining_before: u32) !void {
    try testing.expectEqual(@as(usize, 0), h.fake.navigate_calls.items.len);
    try testing.expectEqual(@as(usize, 0), realClicks(&h.fake));
    try expectCapUntouched(h, remaining_before);
}

fn refusedAs(h: *XHarness, verb: Verb, params: []const u8, reason: []const u8) !void {
    var outcome = try h.call(verb.method, params);
    defer outcome.deinit(gpa);
    expectRefused(outcome, -32015, reason) catch |e| {
        std.debug.print("{s}: wanted {s}\n", .{ verb.method, reason });
        return e;
    };
}

test "x flow phases: a matching approval runs each verb once, its approved navigation, its committing input, one cap slot and the phase reads" {
    for (verbs) |verb| {
        var h: XHarness = undefined;
        h.init();
        defer h.deinit();
        const before = h.state.remaining();
        var buf: [512]u8 = undefined;
        var outcome = try h.call(verb.method, try approved(&buf, verb, 3, compose));
        defer outcome.deinit(gpa);
        if (outcome != .result) {
            std.debug.print("{s}: failure {d} {s}\n", .{ verb.method, outcome.failure.code, outcome.failure.data_json orelse "" });
            return error.TestUnexpectedResult;
        }
        // The one approved navigation, to exactly the approved URL.
        try testing.expectEqual(@as(usize, 1), h.fake.navigate_calls.items.len);
        try testing.expectEqualStrings(compose, h.fake.navigate_calls.items[0]);
        // The committing page input: the text typed, the schedule's choices made, and every
        // click up to Post.
        try testing.expectEqual(@as(usize, 1), countOps(&h.fake, "type"));
        try testing.expectEqual(verb.selects, countOps(&h.fake, "selectOption"));
        testing.expectEqual(verb.clicks, realClicks(&h.fake)) catch |e| {
            std.debug.print("{s}: {d} real clicks\n", .{ verb.method, realClicks(&h.fake) });
            return e;
        };
        // One cap slot, committed.
        try testing.expectEqual(before - 1, h.state.remaining());
        try testing.expectEqual(@as(u32, 0), h.state.in_flight);
        // Phase A, phase C, and before each action.
        try testing.expect(h.windows.list_calls >= 3);
        try testing.expect(h.windows.token_reads >= 2);
    }
}

test "x flow phase A: a stale load_serial or another origin refuses each verb before any page input or reservation" {
    const rows = [_]struct { serial: u64, start: []const u8, reason: []const u8 }{
        .{ .serial = 2, .start = home, .reason = "load_serial_changed" },
        .{ .serial = 3, .start = "https://www.linkedin.com/feed/", .reason = "origin_changed" },
    };
    for (verbs) |verb| for (rows) |row| {
        var h: XHarness = undefined;
        h.init();
        defer h.deinit();
        h.fake.current_url = row.start;
        const before = h.state.remaining();
        var buf: [512]u8 = undefined;
        try refusedAs(&h, verb, try approved(&buf, verb, row.serial, compose), row.reason);
        try expectNothingRan(&h, before);
        try testing.expectEqual(@as(usize, 0), h.fake.eval_calls.items.len);
    };
}

test "x flow phase B: an approval for another URL than the compose_url navigates nowhere, for each verb" {
    for (verbs) |verb| {
        var h: XHarness = undefined;
        h.init();
        defer h.deinit();
        const before = h.state.remaining();
        var buf: [512]u8 = undefined;
        try refusedAs(&h, verb, try approved(&buf, verb, 3, "https://x.com/compose/other"), "unapproved_navigation");
        try expectNothingRan(&h, before);
    }
}

test "x flow phase C: another committed URL, a superseding navigation or a replaced document sends nothing further and leaves the cap as it was, for each verb" {
    const Change = enum { url, serial, document };
    const rows = [_]struct { change: Change, reason: []const u8 }{
        .{ .change = .url, .reason = "url_changed" },
        .{ .change = .serial, .reason = "load_serial_changed" },
        .{ .change = .document, .reason = "document_token_changed" },
    };
    for (verbs) |verb| for (rows) |row| {
        var h: XHarness = undefined;
        h.init();
        defer h.deinit();
        switch (row.change) {
            .url => h.windows.land_url = "https://x.com/i/flow/login",
            .serial => h.windows.bump_after_first_eval_after_nav = true,
            .document => h.windows.token_bump_after_first_eval_after_nav = true,
        }
        const before = h.state.remaining();
        var buf: [512]u8 = undefined;
        try refusedAs(&h, verb, try approved(&buf, verb, 3, compose), row.reason);
        try testing.expectEqual(@as(usize, 0), realClicks(&h.fake));
        try testing.expectEqual(@as(usize, 0), countOps(&h.fake, "type"));
        try expectCapUntouched(&h, before);
    };
}

test "x expect is -32602 with dry_run, without a window, with native or humanized input, malformed, or with a recipient" {
    const exp = "\"expect\":{\"origin\":\"https://x.com\",\"load_serial\":3,\"url\":\"" ++ compose ++ "\"}";
    const head = "{\"text\":\"Hello\",\"compose_url\":\"" ++ compose ++ "\",\"options\":{";
    const rows = [_]struct { what: []const u8, params: []const u8, window: bool = true }{
        .{ .what = "with dry_run", .params = head ++ exp ++ ",\"dry_run\":true}}" },
        .{ .what = "without a window", .params = head ++ exp ++ "}}", .window = false },
        .{ .what = "with native input", .params = head ++ exp ++ ",\"input\":\"native\"}}" },
        .{ .what = "with humanize", .params = head ++ exp ++ ",\"input\":\"native\",\"humanize\":true}}" },
        .{ .what = "expect not an object", .params = head ++ "\"expect\":true}}" },
        .{ .what = "no load_serial", .params = head ++ "\"expect\":{\"origin\":\"https://x.com\",\"url\":\"" ++ compose ++ "\"}}}" },
        .{ .what = "an empty url", .params = head ++ "\"expect\":{\"origin\":\"https://x.com\",\"load_serial\":3,\"url\":\"\"}}}" },
        .{ .what = "an unknown key", .params = head ++ "\"expect\":{\"origin\":\"https://x.com\",\"load_serial\":3,\"url\":\"" ++ compose ++ "\",\"approved\":true}}}" },
        .{ .what = "a recipient", .params = head ++ "\"expect\":{\"origin\":\"https://x.com\",\"load_serial\":3,\"url\":\"" ++ compose ++ "\",\"recipient\":\"ada\"}}}" },
    };
    for (rows) |row| {
        var h: XHarness = undefined;
        h.init();
        defer h.deinit();
        if (!row.window) h.window = null;
        const before = h.state.remaining();
        var outcome = try h.call("x.post", row.params);
        defer outcome.deinit(gpa);
        expectRefused(outcome, -32602, "") catch |e| {
            std.debug.print("{s}: not refused\n", .{row.what});
            return e;
        };
        try expectNothingRan(&h, before);
        try testing.expectEqual(@as(usize, 0), h.fake.eval_calls.items.len);
    }
}
