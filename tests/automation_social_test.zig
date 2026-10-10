//! N6: social.login_check / rate_status / pause / set_pacing routed through
//! src/social.zig with real ports (PagePort, RateLimiter, queue pause).
const std = @import("std");
const automation = @import("automation");
const fakes = @import("automation/fake_page_port.zig");

const social_routes = automation.social_routes;
const engine = automation.engine;

const gpa = std.testing.allocator;

/// 2026-10-10T15:00:00Z
var fake_wall_ms: i64 = 1_791_644_400_000;
fn fakeWall() i64 {
    return fake_wall_ms;
}

const Harness = struct {
    fake: fakes.FakePagePort,
    clock: fakes.FakeClock,
    engine: engine.Engine,
    state: social_routes.SocialState,

    fn init(self: *Harness) void {
        self.fake = fakes.FakePagePort.init(gpa);
        self.clock = fakes.FakeClock.init(gpa);
        self.engine = engine.Engine.init(self.fake.port(), self.clock.clock());
        self.state = social_routes.SocialState.init(fakeWall, self.clock.clock());
    }

    fn deinit(self: *Harness) void {
        self.fake.deinit();
        self.clock.deinit();
    }

    fn call(self: *Harness, method: []const u8, params: []const u8) !engine.Outcome {
        return self.callWithCancel(method, params, false);
    }

    fn callWithCancel(self: *Harness, method: []const u8, params: []const u8, cancelled: bool) !engine.Outcome {
        const flag = std.atomic.Value(bool).init(cancelled);
        const Call = struct {
            state: *social_routes.SocialState,
            verb: social_routes.Verb,
            params: []const u8,
            cancel: *const std.atomic.Value(bool),

            fn run(c: @This(), a: std.mem.Allocator, ext: *engine.External) error{OutOfMemory}!engine.Outcome {
                return social_routes.handle(a, c.state, ext, c.verb, c.params, c.cancel);
            }
        };
        // Not cancelled at the engine level: the pause itself observes `flag`.
        return self.engine.executeExternal(gpa, method, "social", .{}, Call{
            .state = &self.state,
            .verb = social_routes.verbFromMethod(method).?,
            .params = params,
            .cancel = &flag,
        }, Call.run);
    }
};

test "only the four routable social methods are recognised" {
    for ([_][]const u8{ "social.login_check", "social.rate_status", "social.pause", "social.set_pacing" }) |m| {
        try std.testing.expect(social_routes.verbFromMethod(m) != null);
    }
    for ([_][]const u8{ "social.post", "social.", "dom.click", "linkedin.connect" }) |m| {
        try std.testing.expect(social_routes.verbFromMethod(m) == null);
    }
}

test "login_check combines page url (platform) with the in-page login probe" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.current_url = "https://www.linkedin.com/feed/";
    h.fake.eval_replies = &.{.{ .json = "{\"ok\":true,\"value\":{\"logged_in\":true,\"username\":\"Ada L\"}}" }};

    var outcome = try h.call("social.login_check", "{}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqualStrings("{\"loggedIn\":true,\"platform\":\"linkedin\",\"username\":\"Ada L\"}", outcome.result);
    try std.testing.expectEqual(automation.page_port.World.automation, h.fake.eval_calls.items[0].world);
    try std.testing.expectEqualStrings(social_routes.login_check_body, h.fake.eval_calls.items[0].body);
}

test "login_check on an unknown site reports not logged in with null username" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.current_url = "https://example.com/";
    h.fake.eval_replies = &.{.{ .json = "{\"ok\":true,\"value\":{\"logged_in\":false,\"username\":null}}" }};

    var outcome = try h.call("social.login_check", "{}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqualStrings("{\"loggedIn\":false,\"platform\":\"unknown\",\"username\":null}", outcome.result);
}

test "login_check without a page is session_invalid" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.url_result = error.NoPage;

    var outcome = try h.call("social.login_check", "{}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32011), outcome.failure.code);
}

test "rate_status reports the RateLimiter state with the next UTC midnight" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();

    var outcome = try h.call("social.rate_status", "{}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqualStrings("{\"remaining_actions\":100,\"reset_at\":\"2026-10-11T00:00:00Z\",\"daily_cap\":100}", outcome.result);
}

test "set_pacing merges partial params into the current config" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();

    var first = try h.call("social.set_pacing", "{\"daily_cap\":25}");
    defer first.deinit(gpa);
    try std.testing.expectEqualStrings("{\"ok\":true}", first.result);
    var second = try h.call("social.set_pacing", "{\"min_delay_ms\":1000,\"max_delay_ms\":2000}");
    defer second.deinit(gpa);

    const config = h.state.pacingConfig();
    try std.testing.expectEqual(@as(u32, 25), config.daily_cap);
    try std.testing.expectEqual(@as(u32, 1000), config.min_delay_ms);
    try std.testing.expectEqual(@as(u32, 2000), config.max_delay_ms);

    var status = try h.call("social.rate_status", "{}");
    defer status.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, status.result, "\"daily_cap\":25") != null);
}

test "set_pacing rejects min > max and bad types with -32602, leaving config unchanged" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();

    for ([_][]const u8{
        "{\"min_delay_ms\":9000}",
        "{\"min_delay_ms\":10,\"max_delay_ms\":5}",
        "{\"daily_cap\":-1}",
        "{\"daily_cap\":\"10\"}",
        "{\"max_delay_ms\":4294967296}",
        "[]",
    }) |params| {
        var outcome = try h.call("social.set_pacing", params);
        defer outcome.deinit(gpa);
        try std.testing.expectEqual(@as(i64, -32602), outcome.failure.code);
    }
    try std.testing.expectEqual(@as(u32, 100), h.state.pacingConfig().daily_cap);
}

test "pause blocks for duration_ms in cancellable slices, then returns ok" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();

    var outcome = try h.callWithCancel("social.pause", "{\"duration_ms\":50}", false);
    defer outcome.deinit(gpa);
    try std.testing.expectEqualStrings("{\"ok\":true}", outcome.result);
    var total: u64 = 0;
    for (h.clock.sleeps.items) |ms| {
        try std.testing.expect(ms <= engine.poll_interval_ms);
        total += ms;
    }
    try std.testing.expectEqual(@as(u64, 50), total);
}

test "pause 0 returns immediately" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();

    var outcome = try h.callWithCancel("social.pause", "{\"duration_ms\":0}", false);
    defer outcome.deinit(gpa);
    try std.testing.expectEqualStrings("{\"ok\":true}", outcome.result);
    try std.testing.expectEqual(@as(usize, 0), h.clock.sleeps.items.len);
}

test "pause cancelled while waiting returns cancelled" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();

    var outcome = try h.callWithCancel("social.pause", "{\"duration_ms\":600000}", true);
    defer outcome.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32012), outcome.failure.code);
}

test "login_check and rate_status take no params" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    for ([_][]const u8{ "social.login_check", "social.rate_status" }) |method| {
        var outcome = try h.call(method, "{\"x\":1}");
        defer outcome.deinit(gpa);
        try std.testing.expectEqual(@as(i64, -32602), outcome.failure.code);
    }
}

test "pause requires a non-negative u32 duration_ms" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    for ([_][]const u8{ "{}", "{\"duration_ms\":-5}", "{\"duration_ms\":\"5\"}", "{\"duration_ms\":4294967296}" }) |params| {
        var outcome = try h.call("social.pause", params);
        defer outcome.deinit(gpa);
        try std.testing.expectEqual(@as(i64, -32602), outcome.failure.code);
    }
}

test "pause and set_pacing reject unknown params" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    for ([_][2][]const u8{
        .{ "social.pause", "{\"duration_ms\":1,\"durationMs\":5}" },
        .{ "social.set_pacing", "{\"daily_cap\":5,\"dailyCap\":5}" },
    }) |c| {
        var outcome = try h.call(c[0], c[1]);
        defer outcome.deinit(gpa);
        try std.testing.expectEqual(@as(i64, -32602), outcome.failure.code);
    }
    try std.testing.expectEqual(@as(u32, 100), h.state.pacingConfig().daily_cap);
}

test "social failures carry the command ids" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.url_result = error.NoPage;

    var outcome = try h.call("social.login_check", "{}");
    defer outcome.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, outcome.failure.data_json.?, "\"trace_id\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, outcome.failure.data_json.?, "\"command_id\":\"cmd-") != null);
}
