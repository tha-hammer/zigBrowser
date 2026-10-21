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

fn approvedPost(buf: []u8, serial: u64, approved_url: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{{\"text\":\"Hello\",\"compose_url\":\"" ++ compose ++ "\",\"options\":{{\"expect\":{{\"origin\":\"https://x.com\",\"load_serial\":{d},\"url\":\"{s}\"}}}}}}", .{ serial, approved_url });
}

fn expectNothingRan(h: *XHarness, reserved_before: u32) !void {
    try testing.expectEqual(@as(usize, 0), h.fake.navigate_calls.items.len);
    try testing.expectEqual(@as(usize, 0), realClicks(&h.fake));
    try testing.expectEqual(reserved_before, h.state.remaining());
}

test "x flow phases: a matching approval posts once, reading the window before and after its navigation" {
    var h: XHarness = undefined;
    h.init();
    defer h.deinit();
    const before = h.state.remaining();
    var buf: [512]u8 = undefined;
    var outcome = try h.call("x.post", try approvedPost(&buf, 3, compose));
    defer outcome.deinit(gpa);
    if (outcome != .result) {
        std.debug.print("failure {d} {s}\n", .{ outcome.failure.code, outcome.failure.data_json orelse "" });
        return error.TestUnexpectedResult;
    }
    try testing.expectEqual(@as(usize, 1), h.fake.navigate_calls.items.len);
    try testing.expect(realClicks(&h.fake) >= 1);
    try testing.expectEqual(before - 1, h.state.remaining());
    // Phase A, phase C, and before each action.
    try testing.expect(h.windows.list_calls >= 3);
    try testing.expect(h.windows.token_reads >= 2);
}

test "x flow phase A: a stale load_serial or another origin refuses before any page input or reservation" {
    const rows = [_]struct { serial: u64, start: []const u8, reason: []const u8 }{
        .{ .serial = 2, .start = home, .reason = "load_serial_changed" },
        .{ .serial = 3, .start = "https://www.linkedin.com/feed/", .reason = "origin_changed" },
    };
    for (rows) |row| {
        var h: XHarness = undefined;
        h.init();
        defer h.deinit();
        h.fake.current_url = row.start;
        const before = h.state.remaining();
        var buf: [512]u8 = undefined;
        var outcome = try h.call("x.post", try approvedPost(&buf, row.serial, compose));
        defer outcome.deinit(gpa);
        try expectRefused(outcome, -32015, row.reason);
        try expectNothingRan(&h, before);
        try testing.expectEqual(@as(usize, 0), h.fake.eval_calls.items.len);
    }
}

test "x flow phase B: an approval for another URL than the compose_url navigates nowhere" {
    var h: XHarness = undefined;
    h.init();
    defer h.deinit();
    const before = h.state.remaining();
    var buf: [512]u8 = undefined;
    var outcome = try h.call("x.post", try approvedPost(&buf, 3, "https://x.com/compose/other"));
    defer outcome.deinit(gpa);
    try expectRefused(outcome, -32015, "unapproved_navigation");
    try expectNothingRan(&h, before);
}

test "x flow phase C: a navigation that commits another URL is refused before the first action" {
    var h: XHarness = undefined;
    h.init();
    defer h.deinit();
    h.windows.land_url = "https://x.com/i/flow/login";
    var buf: [512]u8 = undefined;
    var outcome = try h.call("x.post", try approvedPost(&buf, 3, compose));
    defer outcome.deinit(gpa);
    try expectRefused(outcome, -32015, "url_changed");
    try testing.expectEqual(@as(usize, 0), realClicks(&h.fake));
}

test "x flow phase C: a navigation or a replaced document after the approved one sends nothing further" {
    const Row = struct { what: []const u8, nav: bool, reason: []const u8 };
    for ([_]Row{ .{ .what = "a superseding navigation", .nav = true, .reason = "load_serial_changed" }, .{ .what = "a replaced document", .nav = false, .reason = "document_token_changed" } }) |row| {
        var h: XHarness = undefined;
        h.init();
        defer h.deinit();
        if (row.nav) h.windows.bump_after_first_eval_after_nav = true else h.windows.token_bump_after_first_eval_after_nav = true;
        var buf: [512]u8 = undefined;
        var outcome = try h.call("x.post", try approvedPost(&buf, 3, compose));
        defer outcome.deinit(gpa);
        expectRefused(outcome, -32015, row.reason) catch |e| {
            std.debug.print("{s}\n", .{row.what});
            return e;
        };
        try testing.expectEqual(@as(usize, 0), realClicks(&h.fake));
    }
}

test "an approved x.schedule_post takes the same approval" {
    var h: XHarness = undefined;
    h.init();
    defer h.deinit();
    var outcome = try h.call("x.schedule_post", "{\"text\":\"Later\",\"date\":\"2026-11-05\",\"time\":\"14:07\",\"compose_url\":\"" ++ compose ++ "\",\"options\":{\"expect\":{\"origin\":\"https://x.com\",\"load_serial\":3,\"url\":\"" ++ compose ++ "\"}}}");
    defer outcome.deinit(gpa);
    if (outcome != .result) {
        std.debug.print("failure {d} {s}\n", .{ outcome.failure.code, outcome.failure.data_json orelse "" });
        return error.TestUnexpectedResult;
    }
    try testing.expect(h.windows.token_reads >= 2);
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
