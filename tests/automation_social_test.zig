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

// ---- N16: linkedin.* / instagram.* through the engine ----

const social_flow_routes = automation.social_flow_routes;

/// Answers every page step with a success that also reads as a one-element
/// dom.query result.
const flow_ok = fakes.EvalReply{ .json = "{\"ok\":true,\"value\":{\"ok\":true,\"text\":\"Ada\",\"elements\":[{\"id\":\"zb-1\",\"tag\":\"div\",\"text\":\"\",\"bbox\":{}}]}}" };

fn flowCall(h: *Harness, method: []const u8, params: []const u8) !engine.Outcome {
    const Call = struct {
        state: *social_routes.SocialState,
        call: social_flow_routes.Call,
        params: []const u8,
        fn run(c: @This(), a: std.mem.Allocator, ext: *engine.External) error{OutOfMemory}!engine.Outcome {
            return social_flow_routes.handle(a, c.state, ext, c.call, c.params);
        }
    };
    const call = social_flow_routes.callFromMethod(method).?;
    return h.engine.executeExternal(gpa, method, call.namespace(), .{}, Call{ .state = &h.state, .call = call, .params = params }, Call.run);
}

test "linkedin.*/instagram.* methods route; social.* and x.* do not" {
    for ([_][]const u8{ "linkedin.visit", "linkedin.connect", "linkedin.message", "linkedin.like", "linkedin.comment", "linkedin.follow", "linkedin.search", "linkedin.extract", "linkedin.selfcheck", "instagram.follow", "instagram.like", "instagram.comment", "instagram.dm", "instagram.story_view", "instagram.selfcheck" }) |m| {
        try std.testing.expect(social_flow_routes.callFromMethod(m) != null);
    }
    for ([_][]const u8{ "linkedin.post", "instagram.reel", "social.pause", "x.post", "linkedin" }) |m| {
        try std.testing.expect(social_flow_routes.callFromMethod(m) == null);
    }
}

test "an action pauses within the pacing range, runs, and consumes one action" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{flow_ok};
    const before = h.state.remaining();
    var outcome = try flowCall(&h, "linkedin.follow", "{\"profileUrl\":\"https://www.linkedin.com/in/ada/\"}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqualStrings("{\"ok\":true}", outcome.result);
    try std.testing.expectEqual(before - 1, h.state.remaining());
    var slept: u64 = 0;
    for (h.clock.sleeps.items) |ms| slept += ms;
    const config = h.state.pacingConfig();
    try std.testing.expect(slept >= config.min_delay_ms and slept <= config.max_delay_ms);
    try std.testing.expectEqualStrings("https://www.linkedin.com/in/ada/", h.fake.navigate_calls.items[0]);
}

test "at the daily cap an action fails social_daily_cap without touching the page; reads still work" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{flow_ok};
    h.state.limiter.updateConfig(.{ .min_delay_ms = 0, .max_delay_ms = 0, .daily_cap = 1 });
    var first = try flowCall(&h, "instagram.like", "{\"postUrl\":\"https://www.instagram.com/p/1/\"}");
    defer first.deinit(gpa);
    try std.testing.expectEqualStrings("{\"ok\":true}", first.result);
    var capped = try flowCall(&h, "linkedin.visit", "{\"profileUrl\":\"https://www.linkedin.com/in/ada/\"}");
    defer capped.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32010), capped.failure.code);
    try std.testing.expect(std.mem.indexOf(u8, capped.failure.data_json.?, "social_daily_cap") != null);
    try std.testing.expectEqual(@as(usize, 1), h.fake.navigate_calls.items.len);
    var read = try flowCall(&h, "linkedin.selfcheck", "{}");
    defer read.deinit(gpa);
    try std.testing.expect(std.mem.startsWith(u8, read.result, "{\"signed_in\":1,"));
}

test "a failed action does not consume; logged out is -32011 logged_out" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.state.limiter.updateConfig(.{ .min_delay_ms = 0, .max_delay_ms = 0, .daily_cap = 5 });
    // signed-in marker wait fails; the login link is there.
    h.fake.eval_replies = &.{
        .{ .json = "{\"ok\":false,\"error\":\"element_not_found\",\"retryable\":false,\"data\":{\"reason\":\"timeout\"}}" },
        flow_ok,
    };
    var outcome = try flowCall(&h, "linkedin.connect", "{\"profileUrl\":\"https://www.linkedin.com/in/ada/\"}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32011), outcome.failure.code);
    try std.testing.expect(std.mem.indexOf(u8, outcome.failure.data_json.?, "logged_out") != null);
    try std.testing.expectEqual(@as(u32, 5), h.state.remaining());
}

test "strict params: unknown, missing, wrong-typed or invalid -> -32602 before pacing or the page" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{flow_ok};
    for ([_][2][]const u8{
        .{ "linkedin.visit", "{}" },
        .{ "linkedin.visit", "{\"profileUrl\":\"https://www.linkedin.com/in/a/\",\"x\":\"y\"}" },
        .{ "linkedin.visit", "{\"profileUrl\":1}" },
        .{ "linkedin.message", "{\"text\":\"hi\"}" },
        .{ "linkedin.message", "{\"text\":\"hi\",\"conversationUrl\":\"https://a.b/c\",\"profileUrl\":\"https://a.b/d\"}" },
        .{ "linkedin.search", "{\"query\":\"zig\",\"searchType\":\"groups\"}" },
        .{ "linkedin.search", "{\"query\":\"  \"}" },
        .{ "linkedin.connect", "{\"profileUrl\":\"https://www.linkedin.com/in/a/\",\"note\":\"" ++ "n" ** 301 ++ "\"}" },
        .{ "instagram.dm", "{\"username\":\"a b\",\"text\":\"hi\"}" },
        .{ "instagram.story_view", "{\"username\":\"ada\",\"baseUrl\":\"file:///etc\"}" },
        .{ "instagram.selfcheck", "{\"x\":\"y\"}" },
    }) |case| {
        var outcome = try flowCall(&h, case[0], case[1]);
        defer outcome.deinit(gpa);
        if (outcome != .failure or outcome.failure.code != -32602) {
            std.debug.print("accepted {s} {s}\n", .{ case[0], case[1] });
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), h.fake.navigate_calls.items.len);
    try std.testing.expectEqual(@as(usize, 0), h.clock.sleeps.items.len);
}

test "linkedin.search navigates to the built URL; extract and selfcheck are not paced" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{flow_ok};
    var search = try flowCall(&h, "linkedin.search", "{\"query\":\"zig & c\",\"searchType\":\"companies\",\"baseUrl\":\"http://127.0.0.1:9\"}");
    defer search.deinit(gpa);
    try std.testing.expectEqualStrings("http://127.0.0.1:9/search/results/companies/?keywords=zig%20%26%20c", h.fake.navigate_calls.items[0]);
    const remaining = h.state.remaining();
    var extract = try flowCall(&h, "linkedin.extract", "{\"profileUrl\":\"https://www.linkedin.com/in/ada/\"}");
    defer extract.deinit(gpa);
    try std.testing.expectEqualStrings("{\"name\":\"Ada\",\"headline\":\"Ada\",\"location\":\"Ada\"}", extract.result);
    try std.testing.expectEqual(remaining, h.state.remaining());
}
