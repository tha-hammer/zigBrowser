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

test "login_check's LinkedIn probe anchors on the nav's \"Me\" button (hashed classes since 2026-10)" {
    const body = social_routes.login_check_body;
    try std.testing.expect(std.mem.indexOf(u8, body, "global-nav") == null);
    // Only the top nav's buttons: a "Me" button in page content must not count.
    try std.testing.expect(std.mem.indexOf(u8, body, "document.querySelectorAll('header button, nav button')") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "=== 'Me'") != null);
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
const cookie_port = automation.cookie_port;
const telemetry = automation.telemetry;

/// Answers every page step with a success that also reads as a one-element
/// dom.query result.
// One element with a box, like a real dom.query answer (the LinkedIn
// profile click counts only matches with a box).
const flow_ok = fakes.EvalReply{ .json = "{\"ok\":true,\"value\":{\"ok\":true,\"text\":\"Ada\",\"elements\":[{\"id\":\"zb-1\",\"tag\":\"div\",\"text\":\"\",\"bbox\":{\"x\":0,\"y\":0,\"width\":80,\"height\":32}}]}}" };

/// Cookie store holding the given cookie names (values are placeholders).
const SessionCookies = struct {
    names: []const []const u8 = &.{ "li_at", "sessionid" },
    get_all_calls: usize = 0,
    /// Simulated store latency on `clock` (never past the given timeout).
    clock: ?*fakes.FakeClock = null,
    cost_ms: u64 = 0,
    last_url: [256]u8 = undefined,
    last_url_len: usize = 0,

    fn port(self: *SessionCookies) cookie_port.CookiePort {
        return .{ .ptr = self, .vtable = &.{ .getAll = getAll, .set = set, .delete = delete } };
    }
    fn getAll(ptr: *anyopaque, a: std.mem.Allocator, url: ?[]const u8, timeout_ms: u64) cookie_port.PortError![]u8 {
        const self: *SessionCookies = @ptrCast(@alignCast(ptr));
        self.get_all_calls += 1;
        if (self.clock) |clock| {
            if (self.cost_ms > timeout_ms) {
                clock.now_ms += timeout_ms;
                return error.Timeout;
            }
            clock.now_ms += self.cost_ms;
        }
        const u = url orelse "";
        self.last_url_len = @min(u.len, self.last_url.len);
        @memcpy(self.last_url[0..self.last_url_len], u[0..self.last_url_len]);
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(a);
        out.append(a, '[') catch return error.OutOfMemory;
        for (self.names, 0..) |name, i| {
            if (i > 0) out.append(a, ',') catch return error.OutOfMemory;
            out.print(a, "{{\"name\":\"{s}\",\"value\":\"secret-session-value\",\"domain\":\"x\"}}", .{name}) catch return error.OutOfMemory;
        }
        out.append(a, ']') catch return error.OutOfMemory;
        return out.toOwnedSlice(a) catch error.OutOfMemory;
    }
    fn set(_: *anyopaque, _: []const u8, _: u64) cookie_port.PortError!void {}
    fn delete(_: *anyopaque, _: []const u8, _: ?[]const u8, _: u64) cookie_port.PortError!void {}
};

const FlowHarness = struct {
    h: Harness,
    cookies: SessionCookies,
    sink: telemetry.InMemoryTelemetrySink,
    fixture_origin: ?[]const u8 = null,
    budget_ms: u64 = social_flow_routes.flow_budget_ms,

    fn init(self: *FlowHarness) void {
        self.h.init();
        self.cookies = .{};
        self.sink = telemetry.InMemoryTelemetrySink.init(gpa);
        self.fixture_origin = null;
        self.budget_ms = social_flow_routes.flow_budget_ms;
        self.h.fake.eval_replies = &.{flow_ok};
    }

    fn deinit(self: *FlowHarness) void {
        self.sink.deinit();
        self.h.deinit();
    }

    fn call(self: *FlowHarness, method: []const u8, params: []const u8) !engine.Outcome {
        const Call = struct {
            state: *social_routes.SocialState,
            env: social_flow_routes.Env,
            call: social_flow_routes.Call,
            params: []const u8,
            budget_ms: u64,
            fn run(c: @This(), a: std.mem.Allocator, ext: *engine.External) error{OutOfMemory}!engine.Outcome {
                return social_flow_routes.handleWithBudget(a, c.state, c.env, ext, c.call, c.params, c.budget_ms);
            }
        };
        const flow_call = social_flow_routes.callFromMethod(method).?;
        return self.h.engine.executeExternal(gpa, method, flow_call.namespace(), .{ .route = .{ .telemetry_sink = self.sink.sink() } }, Call{
            .state = &self.h.state,
            .env = .{ .cookies = self.cookies.port(), .fixture_origin = self.fixture_origin },
            .call = flow_call,
            .params = params,
            .budget_ms = self.budget_ms,
        }, Call.run);
    }
};

test "linkedin.*/instagram.* methods route; social.* and x.* do not" {
    for ([_][]const u8{ "linkedin.visit", "linkedin.connect", "linkedin.message", "linkedin.like", "linkedin.comment", "linkedin.follow", "linkedin.search", "linkedin.extract", "linkedin.selfcheck", "instagram.follow", "instagram.like", "instagram.comment", "instagram.dm", "instagram.story_view", "instagram.selfcheck" }) |m| {
        try std.testing.expect(social_flow_routes.callFromMethod(m) != null);
    }
    for ([_][]const u8{ "linkedin.post", "instagram.reel", "social.pause", "x.post", "linkedin" }) |m| {
        try std.testing.expect(social_flow_routes.callFromMethod(m) == null);
    }
}

test "an action pauses within the pacing range, runs, and counts one action" {
    var f: FlowHarness = undefined;
    f.init();
    defer f.deinit();
    const before = f.h.state.remaining();
    var outcome = try f.call("linkedin.like", "{\"postUrl\":\"https://www.linkedin.com/feed/update/1/\"}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqualStrings("{\"ok\":true}", outcome.result);
    try std.testing.expectEqual(before - 1, f.h.state.remaining());
    var slept: u64 = 0;
    for (f.h.clock.sleeps.items) |ms| slept += ms;
    const config = f.h.state.pacingConfig();
    try std.testing.expect(slept >= config.min_delay_ms and slept <= config.max_delay_ms);
    try std.testing.expectEqualStrings("https://www.linkedin.com/feed/update/1/", f.h.fake.navigate_calls.items[0]);
}

test "a page dialog that stops a flow is -32013 and the compound span records automation.error dialog_open" {
    var f: FlowHarness = undefined;
    f.init();
    defer f.deinit();
    f.h.fake.navigate_result = error.DialogOpen;
    var outcome = try f.call("linkedin.like", "{\"postUrl\":\"https://www.linkedin.com/feed/update/1/\"}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32013), outcome.failure.code);
    var compound: ?*const telemetry.Span = null;
    for (f.sink.spans.items) |*span| {
        if (std.mem.eql(u8, span.name, "automation.social.compound")) compound = span;
    }
    try std.testing.expectEqualStrings("dialog_open", compound.?.attr("automation.error").?);
}

test "login gate before navigation (C31): no session cookie -> -32011 logged_out, no page step, no pacing" {
    var f: FlowHarness = undefined;
    f.init();
    defer f.deinit();
    f.cookies.names = &.{"lang"};
    for ([_][2][]const u8{
        .{ "linkedin.visit", "{\"profileUrl\":\"https://www.linkedin.com/in/ada/\"}" },
        .{ "instagram.story_view", "{\"username\":\"ada\"}" },
    }) |case| {
        var outcome = try f.call(case[0], case[1]);
        defer outcome.deinit(gpa);
        try std.testing.expectEqual(@as(i64, -32011), outcome.failure.code);
        try std.testing.expect(std.mem.indexOf(u8, outcome.failure.data_json.?, "logged_out") != null);
    }
    try std.testing.expectEqual(@as(usize, 0), f.h.fake.navigate_calls.items.len);
    try std.testing.expectEqual(@as(usize, 0), f.h.fake.eval_calls.items.len);
    try std.testing.expectEqual(@as(usize, 0), f.h.clock.sleeps.items.len);
    try std.testing.expectEqualStrings("https://www.instagram.com/", f.cookies.last_url[0..f.cookies.last_url_len]);
    // The other platform's cookie does not count.
    f.cookies.names = &.{"sessionid"};
    var cross = try f.call("linkedin.like", "{\"postUrl\":\"https://www.linkedin.com/feed/update/1/\"}");
    defer cross.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32011), cross.failure.code);
    // selfcheck reads the current page and needs no session.
    var check = try f.call("instagram.selfcheck", "{}");
    defer check.deinit(gpa);
    try std.testing.expect(check == .result);
}

test "logged-out page after navigating (cookie present, marker absent, login link) -> logged_out, nothing counted" {
    var f: FlowHarness = undefined;
    f.init();
    defer f.deinit();
    f.h.state.limiter.updateConfig(.{ .min_delay_ms = 0, .max_delay_ms = 0, .daily_cap = 5 });
    f.h.fake.eval_replies = &.{
        .{ .json = "{\"ok\":false,\"error\":\"element_not_found\",\"retryable\":false,\"data\":{\"reason\":\"timeout\"}}" },
        flow_ok,
    };
    var outcome = try f.call("linkedin.connect", "{\"profileUrl\":\"https://www.linkedin.com/in/ada/\"}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32011), outcome.failure.code);
    try std.testing.expectEqual(@as(u32, 5), f.h.state.remaining());
}

test "daily cap: atomic reservation; at the cap no page work; reads still work" {
    var f: FlowHarness = undefined;
    f.init();
    defer f.deinit();
    f.h.state.limiter.updateConfig(.{ .min_delay_ms = 0, .max_delay_ms = 0, .daily_cap = 1 });
    var first = try f.call("instagram.like", "{\"postUrl\":\"https://www.instagram.com/p/1/\"}");
    defer first.deinit(gpa);
    try std.testing.expectEqualStrings("{\"ok\":true}", first.result);
    var capped = try f.call("linkedin.visit", "{\"profileUrl\":\"https://www.linkedin.com/in/ada/\"}");
    defer capped.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32010), capped.failure.code);
    try std.testing.expect(std.mem.indexOf(u8, capped.failure.data_json.?, "social_daily_cap") != null);
    try std.testing.expectEqual(@as(usize, 1), f.h.fake.navigate_calls.items.len);
    var read = try f.call("linkedin.selfcheck", "{}");
    defer read.deinit(gpa);
    try std.testing.expect(std.mem.startsWith(u8, read.result, "{\"signed_in\":1,"));
}

test "reservation is atomic across threads: at cap=1 exactly one of many concurrent admissions wins" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.state.limiter.updateConfig(.{ .min_delay_ms = 0, .max_delay_ms = 0, .daily_cap = 1 });
    var go = std.atomic.Value(bool).init(false);
    var wins = std.atomic.Value(u32).init(0);
    var won: [8]?social_routes.SocialState.Reservation = .{null} ** 8;
    const Worker = struct {
        fn run(state: *social_routes.SocialState, start: *std.atomic.Value(bool), count: *std.atomic.Value(u32), slot: *?social_routes.SocialState.Reservation) void {
            while (!start.load(.acquire)) std.atomic.spinLoopHint();
            slot.* = state.reserve();
            if (slot.* != null) _ = count.fetchAdd(1, .acq_rel);
        }
    };
    var threads: [8]std.Thread = undefined;
    for (&threads, &won) |*t, *slot| t.* = try std.Thread.spawn(.{}, Worker.run, .{ &h.state, &go, &wins, slot });
    go.store(true, .release);
    for (threads) |t| t.join();
    try std.testing.expectEqual(@as(u32, 1), wins.load(.acquire));
    // In flight counts against the cap until committed or released.
    try std.testing.expectEqual(@as(u32, 0), h.state.remaining());
    for (&won) |*slot| if (slot.*) |*r| r.release();
    try std.testing.expectEqual(@as(u32, 1), h.state.remaining());
    var again = h.state.reserve().?;
    again.commit();
    try std.testing.expectEqual(@as(u32, 0), h.state.remaining());
    try std.testing.expect(h.state.reserve() == null);
}

test "strict params: unknown, missing, wrong-typed, off-platform or invalid -> -32602 before the gate, pacing or the page" {
    var f: FlowHarness = undefined;
    f.init();
    defer f.deinit();
    for ([_][2][]const u8{
        .{ "linkedin.visit", "{}" },
        .{ "linkedin.visit", "{\"profileUrl\":\"https://www.linkedin.com/in/a/\",\"x\":\"y\"}" },
        .{ "linkedin.visit", "{\"profileUrl\":1}" },
        .{ "linkedin.visit", "{\"profileUrl\":\"https://evil.example/in/a/\"}" },
        .{ "linkedin.visit", "{\"profileUrl\":\"https://www.linkedin.com.evil.example/in/a/\"}" },
        .{ "linkedin.message", "{\"text\":\"hi\"}" },
        .{ "linkedin.message", "{\"text\":\"hi\",\"conversationUrl\":\"https://evil.example/c\"}" },
        .{ "linkedin.message", "{\"text\":\"\",\"conversationUrl\":\"https://www.linkedin.com/messaging/1/\"}" },
        .{ "linkedin.like", "{\"postUrl\":\"https://www.instagram.com/p/1/\"}" },
        .{ "linkedin.comment", "{\"postUrl\":\"https://www.linkedin.com/feed/1/\",\"text\":\"" ++ "c" ** 1251 ++ "\"}" },
        .{ "linkedin.comment", "{\"postUrl\":\"https://www.linkedin.com/feed/1/\",\"text\":\"\\u00ff\\udcff\"}" },
        .{ "linkedin.search", "{\"query\":\"zig\",\"searchType\":\"groups\"}" },
        .{ "linkedin.search", "{\"query\":\"  \"}" },
        .{ "linkedin.search", "{\"query\":\"zig\",\"baseUrl\":\"http://127.0.0.1:9\"}" },
        .{ "linkedin.connect", "{\"profileUrl\":\"https://www.linkedin.com/in/a/\",\"note\":\"   \"}" },
        .{ "instagram.dm", "{\"username\":\"a b\",\"text\":\"hi\"}" },
        .{ "instagram.dm", "{\"username\":\"ada\",\"text\":\"" ++ "d" ** 1001 ++ "\"}" },
        .{ "instagram.story_view", "{\"username\":\"ada\",\"baseUrl\":\"http://127.0.0.1:9\"}" },
        .{ "instagram.follow", "{\"profileUrl\":\"https://www.linkedin.com/in/a/\"}" },
        .{ "instagram.selfcheck", "{\"x\":\"y\"}" },
    }) |case| {
        var outcome = try f.call(case[0], case[1]);
        defer outcome.deinit(gpa);
        if (outcome != .failure or outcome.failure.code != -32602) {
            std.debug.print("accepted {s} {s}\n", .{ case[0], case[1] });
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), f.h.fake.navigate_calls.items.len);
    try std.testing.expectEqual(@as(usize, 0), f.h.clock.sleeps.items.len);
    try std.testing.expectEqual(@as(usize, 0), f.cookies.get_all_calls);
}

test "search navigates to the built URL (fixture origin from server config); extract and selfcheck are not paced" {
    var f: FlowHarness = undefined;
    f.init();
    defer f.deinit();
    f.fixture_origin = "http://127.0.0.1:9";
    var search = try f.call("linkedin.search", "{\"query\":\"zig & c\",\"searchType\":\"companies\"}");
    defer search.deinit(gpa);
    try std.testing.expectEqualStrings("http://127.0.0.1:9/search/results/companies/?keywords=zig%20%26%20c", f.h.fake.navigate_calls.items[0]);
    const remaining = f.h.state.remaining();
    // The name comes from the profile's title, on the profile's own URL.
    f.h.fake.navigate_sets_url = true;
    f.h.fake.current_title = "Ada | LinkedIn";
    var extract = try f.call("linkedin.extract", "{\"profileUrl\":\"http://127.0.0.1:9/in/ada/\"}");
    defer extract.deinit(gpa);
    try std.testing.expectEqualStrings("{\"name\":\"Ada\",\"headline\":\"Ada\",\"location\":\"Ada\"}", extract.result);
    try std.testing.expectEqual(remaining, f.h.state.remaining());
}

test "telemetry: one compound span and one action event per step; no URL, username, note, text or cookie value crosses the sink" {
    var f: FlowHarness = undefined;
    f.init();
    defer f.deinit();
    const note = "Hi Ada, a private note";
    // The owner's name (from the title) is in the click's selector: it must
    // not reach telemetry either.
    f.h.fake.navigate_sets_url = true;
    f.h.fake.current_title = "Ada Secret | LinkedIn";
    var outcome = try f.call("linkedin.connect", "{\"profileUrl\":\"https://www.linkedin.com/in/ada-secret/\",\"note\":\"" ++ note ++ "\"}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqualStrings("{\"ok\":true}", outcome.result);
    var compound: ?*const telemetry.Span = null;
    var actions: usize = 0;
    for (f.sink.spans.items) |*span| {
        if (std.mem.eql(u8, span.name, "automation.social.compound")) compound = span;
        if (std.mem.eql(u8, span.name, "automation.social.action")) actions += 1;
    }
    const c = compound orelse return error.TestNoCompound;
    try std.testing.expectEqualStrings("linkedin", c.attr("social.platform").?);
    try std.testing.expectEqualStrings("connect", c.attr("social.action").?);
    try std.testing.expectEqualStrings("www.linkedin.com", c.attr("target.host").?);
    try std.testing.expectEqualStrings("true", c.attr("note.provided").?);
    try std.testing.expectEqualStrings("22", c.attr("note.length").?);
    try std.testing.expectEqualStrings("false", c.attr("note.truncated").?);
    try std.testing.expectEqualStrings("true", c.attr("platform.login_verified").?);
    try std.testing.expectEqualStrings("ok", c.attr("result.status").?);
    try std.testing.expectEqual(@as(usize, 64), c.attr("profile.id_hash").?.len);
    const steps = try std.fmt.parseInt(usize, c.attr("social.step_count").?, 10);
    try std.testing.expectEqual(steps, actions);
    try std.testing.expect(steps >= 8);
    for (f.sink.spans.items) |*span| {
        if (!std.mem.eql(u8, span.name, "automation.social.action")) continue;
        try std.testing.expectEqualStrings(c.span_id, span.parent_span_id.?);
        try std.testing.expect(span.attr("social.step") != null);
    }
    for ([_][]const u8{ "ada-secret", "Ada Secret", note, "private note", "secret-session-value", "linkedin.com/in" }) |raw| {
        if (f.sink.containsRaw(raw)) {
            std.debug.print("leaked into telemetry: {s}\n", .{raw});
            return error.TestLeak;
        }
    }

    // A failing step is named on the compound span.
    var g: FlowHarness = undefined;
    g.init();
    defer g.deinit();
    g.h.fake.eval_replies = &.{
        flow_ok, // signed-in marker
        .{ .json = "{\"ok\":false,\"error\":\"element_disabled\",\"retryable\":false,\"data\":{\"reason\":\"disabled\"}}" },
    };
    var failed = try g.call("instagram.follow", "{\"profileUrl\":\"https://www.instagram.com/ada/\"}");
    defer failed.deinit(gpa);
    var last: ?*const telemetry.Span = null;
    for (g.sink.spans.items) |*span| {
        if (std.mem.eql(u8, span.name, "automation.social.compound")) last = span;
    }
    try std.testing.expectEqualStrings("error", last.?.attr("result.status").?);
    try std.testing.expectEqualStrings("element_disabled", last.?.attr("automation.error").?);
    try std.testing.expectEqualStrings("click_follow_button", last.?.attr("error.step").?);
}

test "a long flow (story_view, hundreds of step spans) keeps its compound span and root in telemetry.query's bounded store" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{flow_ok};
    // The viewer never closes: frames until the budget runs low.
    h.fake.current_url = "https://www.instagram.com/stories/ada/1/";
    h.state.limiter.updateConfig(.{ .min_delay_ms = 0, .max_delay_ms = 0, .daily_cap = 5 });
    var cookies = SessionCookies{};
    var store = telemetry.RecentTraceStore.init(gpa, 4);
    defer store.deinit();
    const Call = struct {
        state: *social_routes.SocialState,
        env: social_flow_routes.Env,
        fn run(c: @This(), a: std.mem.Allocator, ext: *engine.External) error{OutOfMemory}!engine.Outcome {
            return social_flow_routes.handle(a, c.state, c.env, ext, .{ .instagram = .story_view }, "{\"username\":\"ada\"}");
        }
    };
    var outcome = try h.engine.executeExternal(gpa, "instagram.story_view", "instagram", .{ .route = .{ .telemetry_sink = store.sink() } }, Call{
        .state = &h.state,
        // The frames loop is the long flow; it runs only where the story
        // viewer is verified (tests: unverified_actions).
        .env = .{ .cookies = cookies.port(), .unverified_actions = true },
    }, Call.run);
    defer outcome.deinit(gpa);
    try std.testing.expect(std.mem.startsWith(u8, outcome.result, "{\"ok\":true,\"framesViewed\":"));
    const trace_id = store.traces.items[0].trace_id;
    const json = try store.queryJson(gpa, trace_id);
    defer gpa.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer parsed.deinit();
    const spans = parsed.value.object.get("spans").?.array.items;
    try std.testing.expectEqual(telemetry.RecentTraceStore.max_spans_per_trace, spans.len);
    try std.testing.expectEqualStrings("automation.command", spans[0].object.get("name").?.string);
    try std.testing.expectEqualStrings("automation.social.compound", spans[1].object.get("name").?.string);
    const steps = spans[1].object.get("attributes").?.object.get("social.step_count").?;
    const step_count = switch (steps) {
        .integer => |n| n,
        .string => |t| try std.fmt.parseInt(i64, t, 10),
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(step_count > telemetry.RecentTraceStore.max_spans_per_trace);
}

test "cap=1 across two pages: while page A's admitted flow is in its page step, page B is refused without touching its page" {
    var a: Harness = undefined;
    a.init();
    defer a.deinit();
    var b: Harness = undefined;
    b.init();
    defer b.deinit();
    // One server-wide social state shared by both pages.
    const shared = &a.state;
    shared.limiter.updateConfig(.{ .min_delay_ms = 0, .max_delay_ms = 0, .daily_cap = 1 });
    a.fake.eval_replies = &.{flow_ok};
    b.fake.eval_replies = &.{flow_ok};
    var hold = std.atomic.Value(bool).init(true);
    a.fake.hold = &hold;
    var cookies_a = SessionCookies{};
    var cookies_b = SessionCookies{};

    const Run = struct {
        fn flow(h: *Harness, state: *social_routes.SocialState, cookies: *SessionCookies, out: *?engine.Outcome) void {
            const Call = struct {
                state: *social_routes.SocialState,
                env: social_flow_routes.Env,
                fn run(c: @This(), alloc: std.mem.Allocator, ext: *engine.External) error{OutOfMemory}!engine.Outcome {
                    return social_flow_routes.handle(alloc, c.state, c.env, ext, .{ .linkedin = .like }, "{\"postUrl\":\"https://www.linkedin.com/feed/update/1/\"}");
                }
            };
            out.* = h.engine.executeExternal(gpa, "linkedin.like", "linkedin", .{}, Call{ .state = state, .env = .{ .cookies = cookies.port() } }, Call.run) catch null;
        }
    };
    var outcome_a: ?engine.Outcome = null;
    const thread_a = try std.Thread.spawn(.{}, Run.flow, .{ &a, shared, &cookies_a, &outcome_a });
    // Whatever happens below, page A is released and joined (a failed check
    // must not leave it spinning).
    var joined = false;
    defer if (!joined) {
        hold.store(false, .release);
        thread_a.join();
        if (outcome_a) |*o| o.deinit(gpa);
    };
    // Page A has reserved the only slot and is inside its first page step
    // (bounded wait: a failure before that reports instead of hanging).
    var spins: u64 = 0;
    while (!a.fake.held.load(.acquire)) : (spins += 1) {
        if (spins > 2_000_000_000) return error.PageANeverHeld;
        std.atomic.spinLoopHint();
    }

    var outcome_b: ?engine.Outcome = null;
    Run.flow(&b, shared, &cookies_b, &outcome_b);
    defer if (outcome_b) |*o| o.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32010), outcome_b.?.failure.code);
    try std.testing.expectEqual(@as(usize, 0), b.fake.navigate_calls.items.len);
    try std.testing.expectEqual(@as(usize, 0), b.fake.eval_calls.items.len);

    hold.store(false, .release);
    thread_a.join();
    joined = true;
    defer if (outcome_a) |*o| o.deinit(gpa);
    try std.testing.expectEqualStrings("{\"ok\":true}", outcome_a.?.result);
    try std.testing.expectEqual(@as(u32, 0), shared.remaining());
}

test "reservations complete exactly once, and an admitted success counts even if the cap is lowered meanwhile" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.state.limiter.updateConfig(.{ .min_delay_ms = 0, .max_delay_ms = 0, .daily_cap = 2 });
    var r = h.state.reserve().?;
    try std.testing.expectEqual(@as(u32, 1), h.state.remaining());
    // social.set_pacing lowers the cap to 0 while the action runs.
    h.state.limiter.updateConfig(.{ .min_delay_ms = 0, .max_delay_ms = 0, .daily_cap = 0 });
    r.commit();
    try std.testing.expectEqual(@as(u32, 1), h.state.limiter.actions_today);
    // A second completion does nothing (no double count, no underflow).
    r.commit();
    r.release();
    try std.testing.expectEqual(@as(u32, 1), h.state.limiter.actions_today);
    try std.testing.expectEqual(@as(u32, 0), h.state.in_flight);

    h.state.limiter.updateConfig(.{ .min_delay_ms = 0, .max_delay_ms = 0, .daily_cap = 5 });
    var released = h.state.reserve().?;
    released.release();
    released.commit();
    try std.testing.expectEqual(@as(u32, 1), h.state.limiter.actions_today);
    try std.testing.expectEqual(@as(u32, 4), h.state.remaining());
}

test "social.rate_status counts actions in flight" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.state.limiter.updateConfig(.{ .min_delay_ms = 0, .max_delay_ms = 0, .daily_cap = 3 });
    var r = h.state.reserve().?;
    defer r.release();
    var outcome = try h.call("social.rate_status", "{}");
    defer outcome.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, outcome.result, "\"remaining_actions\":2") != null);
}

test "telemetry: a conversation message hashes the conversation URL as conversation.id_hash, not profile.id_hash" {
    var f: FlowHarness = undefined;
    f.init();
    defer f.deinit();
    var outcome = try f.call("linkedin.message", "{\"conversationUrl\":\"https://www.linkedin.com/messaging/thread/2-secret/\",\"text\":\"hello\"}");
    defer outcome.deinit(gpa);
    try std.testing.expect(outcome == .result);
    for (f.sink.spans.items) |*span| {
        if (!std.mem.eql(u8, span.name, "automation.social.compound")) continue;
        try std.testing.expectEqual(@as(usize, 64), span.attr("conversation.id_hash").?.len);
        try std.testing.expect(span.attr("profile.id_hash") == null);
    }
    try std.testing.expect(!f.sink.containsRaw("2-secret"));
    try std.testing.expect(!f.sink.containsRaw("hello"));
}

test "one absolute flow deadline covers the cookie gate and every later step" {
    // The cookie read takes 9 s of a 20 s budget: the flow's page steps get
    // at most the remaining 11 s.
    var f: FlowHarness = undefined;
    f.init();
    defer f.deinit();
    f.budget_ms = 20_000;
    f.h.state.limiter.updateConfig(.{ .min_delay_ms = 0, .max_delay_ms = 0, .daily_cap = 5 });
    f.h.fake.clock = &f.h.clock;
    f.cookies.clock = &f.h.clock;
    f.cookies.cost_ms = 9_000;
    var outcome = try f.call("linkedin.like", "{\"postUrl\":\"https://www.linkedin.com/feed/update/1/\"}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqualStrings("{\"ok\":true}", outcome.result);
    try std.testing.expect(f.h.fake.navigate_timeouts.items[0] <= 11_000);
    for (f.h.fake.eval_calls.items) |call| try std.testing.expect(call.timeout_ms <= 11_000);

    // A cookie store slower than the whole budget: cut at the flow deadline,
    // reported as the flow deadline, nothing opened.
    var g: FlowHarness = undefined;
    g.init();
    defer g.deinit();
    g.budget_ms = 5_000;
    g.cookies.clock = &g.h.clock;
    g.cookies.cost_ms = 10_000;
    var slow = try g.call("linkedin.visit", "{\"profileUrl\":\"https://www.linkedin.com/in/zed/\"}");
    defer slow.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32009), slow.failure.code);
    try std.testing.expect(std.mem.indexOf(u8, slow.failure.data_json.?, "linkedin_flow_deadline") != null);
    try std.testing.expectEqual(@as(u64, 5_000), g.h.clock.now_ms);
    try std.testing.expectEqual(@as(usize, 0), g.h.fake.navigate_calls.items.len);
}

test "timeout_ms on the text-typing social flows: accepted and used as the flow deadline; refused elsewhere or out of range" {
    var f: FlowHarness = undefined;
    f.init();
    defer f.deinit();
    for ([_][2][]const u8{
        .{ "linkedin.like", "{\"postUrl\":\"https://www.linkedin.com/feed/1/\",\"timeout_ms\":5000}" },
        .{ "linkedin.visit", "{\"profileUrl\":\"https://www.linkedin.com/in/a/\",\"timeout_ms\":5000}" },
        .{ "instagram.story_view", "{\"username\":\"ada\",\"timeout_ms\":5000}" },
        .{ "linkedin.comment", "{\"postUrl\":\"https://www.linkedin.com/feed/1/\",\"text\":\"x\",\"timeout_ms\":600001}" },
        .{ "instagram.dm", "{\"username\":\"ada\",\"text\":\"x\",\"timeout_ms\":\"9\"}" },
        .{ "linkedin.message", "{\"text\":\"x\",\"conversationUrl\":\"https://www.linkedin.com/messaging/1/\",\"timeout_ms\":0}" },
    }) |case| {
        var outcome = try f.call(case[0], case[1]);
        defer outcome.deinit(gpa);
        if (outcome != .failure or outcome.failure.code != -32602) {
            std.debug.print("accepted {s} {s}\n", .{ case[0], case[1] });
            return error.TestUnexpectedResult;
        }
    }

    // A 2000-character comment needs a 205 s typing step: the default
    // 120 s budget caps it, timeout_ms 300000 gives it the full time.
    const long_text = "c" ** 2000;
    for ([_]struct { extra: []const u8, check: enum { capped, full } }{
        .{ .extra = "", .check = .capped },
        .{ .extra = ",\"timeout_ms\":300000", .check = .full },
    }) |case| {
        var g: FlowHarness = undefined;
        g.init();
        defer g.deinit();
        g.h.state.limiter.updateConfig(.{ .min_delay_ms = 0, .max_delay_ms = 0, .daily_cap = 5 });
        const params = try std.fmt.allocPrint(gpa, "{{\"postUrl\":\"https://www.instagram.com/p/1/\",\"text\":\"{s}\"{s}}}", .{ long_text, case.extra });
        defer gpa.free(params);
        var outcome = try g.call("instagram.comment", params);
        defer outcome.deinit(gpa);
        try std.testing.expectEqualStrings("{\"ok\":true}", outcome.result);
        var type_timeout: ?u64 = null;
        for (g.h.fake.eval_calls.items) |call| {
            if (std.mem.indexOf(u8, call.arg, "\"op\":\"type\"") != null) type_timeout = call.timeout_ms;
        }
        switch (case.check) {
            .capped => try std.testing.expect(type_timeout.? <= 120_000),
            .full => try std.testing.expectEqual(@as(u64, 205_000), type_timeout.?),
        }
    }
}

// ---- N20: platform rate-limit / challenge signals ----

fn expectRateLimited(outcome: engine.Outcome, signal: []const u8, platform: []const u8) !void {
    if (outcome != .failure) {
        std.debug.print("expected -32010, got {s}\n", .{outcome.result});
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(@as(i64, -32010), outcome.failure.code);
    const data = try std.json.parseFromSlice(std.json.Value, gpa, outcome.failure.data_json.?, .{});
    defer data.deinit();
    try std.testing.expectEqualStrings(signal, data.value.object.get("signal").?.string);
    try std.testing.expectEqualStrings(platform, data.value.object.get("platform").?.string);
}

fn countOps(fake: *const fakes.FakePagePort, op: []const u8) usize {
    var buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "\"op\":\"{s}\"", .{op}) catch unreachable;
    var n: usize = 0;
    for (fake.eval_calls.items) |call| {
        if (std.mem.indexOf(u8, call.arg, needle) != null) n += 1;
    }
    return n;
}

test "N20: a LinkedIn checkpoint right after navigating stops the flow: -32010 {signal, platform}, no page step, no action counted" {
    var f: FlowHarness = undefined;
    f.init();
    defer f.deinit();
    f.h.fake.scan_replies = &.{.{ .json = fakes.detectedScan("challenge", "linkedin") }};
    const before = f.h.state.remaining();
    var outcome = try f.call("linkedin.connect", "{\"profileUrl\":\"https://www.linkedin.com/in/ada/\"}");
    defer outcome.deinit(gpa);
    try expectRateLimited(outcome, "challenge", "linkedin");
    try std.testing.expectEqualStrings("linkedin", f.h.fake.scannedPlatform());
    try std.testing.expectEqual(@as(usize, 1), f.h.fake.navigate_calls.items.len);
    try std.testing.expectEqual(@as(usize, 0), f.h.fake.eval_calls.items.len);
    try std.testing.expectEqual(before, f.h.state.remaining());
    var compound: ?*const telemetry.Span = null;
    for (f.sink.spans.items) |*span| {
        if (std.mem.eql(u8, span.name, "automation.social.compound")) compound = span;
    }
    try std.testing.expectEqualStrings("platform_rate_limited", compound.?.attr("automation.error").?);
}

test "profile message stops before any click while the profile's own Message is unverified live; nothing counted" {
    var f: FlowHarness = undefined;
    f.init();
    defer f.deinit();
    f.h.state.limiter.updateConfig(.{ .min_delay_ms = 0, .max_delay_ms = 0, .daily_cap = 5 });
    f.h.fake.navigate_sets_url = true;
    f.h.fake.current_title = "Sam Example | LinkedIn";
    var outcome = try f.call("linkedin.message", "{\"profileUrl\":\"https://www.linkedin.com/in/sam/\",\"text\":\"hi\"}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32001), outcome.failure.code);
    try std.testing.expect(std.mem.indexOf(u8, outcome.failure.data_json.?, "linkedin_profile_owner_unverified") != null);
    try std.testing.expectEqual(@as(usize, 0), countOps(&f.h.fake, "click"));
    try std.testing.expectEqual(@as(u32, 5), f.h.state.remaining());
}

test "N20: an invitation-limit modal after the Connect click: the next click never happens" {
    var f: FlowHarness = undefined;
    f.init();
    defer f.deinit();
    f.h.fake.navigate_sets_url = true;
    f.h.fake.current_title = "Sam Example | LinkedIn";
    // Clean after the navigation; the Connect click opens the limit modal.
    f.h.fake.scan_replies = &.{ .{ .json = fakes.clean_scan }, .{ .json = fakes.detectedScan("invitation_limit", "linkedin") } };
    var outcome = try f.call("linkedin.connect", "{\"profileUrl\":\"https://www.linkedin.com/in/sam/\"}");
    defer outcome.deinit(gpa);
    try expectRateLimited(outcome, "invitation_limit", "linkedin");
    try std.testing.expectEqual(@as(usize, 1), countOps(&f.h.fake, "click"));
    try std.testing.expectEqual(@as(usize, 2), f.h.fake.scan_calls);
}

test "N20: Instagram flows scan for their own platform; a blocked-action dialog stops a comment before typing" {
    var f: FlowHarness = undefined;
    f.init();
    defer f.deinit();
    f.h.fake.scan_replies = &.{ .{ .json = fakes.clean_scan }, .{ .json = fakes.detectedScan("action_blocked", "instagram") } };
    var outcome = try f.call("instagram.comment", "{\"postUrl\":\"https://www.instagram.com/p/C0ffee/\",\"text\":\"So good\"}");
    defer outcome.deinit(gpa);
    try expectRateLimited(outcome, "action_blocked", "instagram");
    try std.testing.expectEqualStrings("instagram", f.h.fake.scannedPlatform());
    try std.testing.expectEqual(@as(usize, 0), countOps(&f.h.fake, "type"));
    try std.testing.expectEqual(@as(usize, 0), countOps(&f.h.fake, "fill"));

    // Read-only selfcheck never scans.
    var g: FlowHarness = undefined;
    g.init();
    defer g.deinit();
    g.h.fake.scan_replies = &.{.{ .json = fakes.detectedScan("challenge", "instagram") }};
    var report = try g.call("instagram.selfcheck", "{}");
    defer report.deinit(gpa);
    try std.testing.expect(report == .result);
    try std.testing.expectEqual(@as(usize, 0), g.h.fake.scan_calls);
}

// ---- Dry run (options.dry_run) ----

/// Real (non-trial) clicks the page received.
fn realClicks(fake: *const fakes.FakePagePort) usize {
    var n: usize = 0;
    for (fake.eval_calls.items) |call| {
        if (std.mem.indexOf(u8, call.arg, "\"op\":\"click\"") != null and std.mem.indexOf(u8, call.arg, "\"trial\":true") == null) n += 1;
    }
    return n;
}

test "dry run: every one of the eight flows runs to its target with trials only; no pacing pause, nothing counted or saved, scans reported" {
    const cases = [_][2][]const u8{
        .{ "linkedin.connect", "{\"profileUrl\":\"https://www.linkedin.com/in/sam/\",\"note\":\"Hi\",\"options\":{\"dry_run\":true}}" },
        .{ "linkedin.follow", "{\"profileUrl\":\"https://www.linkedin.com/in/sam/\",\"options\":{\"dry_run\":true}}" },
        .{ "linkedin.like", "{\"postUrl\":\"https://www.linkedin.com/feed/update/1/\",\"options\":{\"dry_run\":true}}" },
        .{ "linkedin.comment", "{\"postUrl\":\"https://www.linkedin.com/feed/update/1/\",\"text\":\"Great\",\"options\":{\"dry_run\":true}}" },
        .{ "instagram.follow", "{\"profileUrl\":\"https://www.instagram.com/sam/\",\"options\":{\"dry_run\":true}}" },
        .{ "instagram.like", "{\"postUrl\":\"https://www.instagram.com/p/1/\",\"options\":{\"dry_run\":true}}" },
        .{ "instagram.comment", "{\"postUrl\":\"https://www.instagram.com/p/1/\",\"text\":\"So good\",\"options\":{\"dry_run\":true}}" },
    };
    for (cases) |case| {
        var f: FlowHarness = undefined;
        f.init();
        defer f.deinit();
        var counter: ChangeCounter = .{};
        f.h.state.on_change = counter.hook();
        f.h.fake.navigate_sets_url = true;
        f.h.fake.current_title = "Sam Example | LinkedIn";
        const before = f.h.state.remaining();
        var outcome = try f.call(case[0], case[1]);
        defer outcome.deinit(gpa);
        if (outcome != .result) {
            std.debug.print("{s}: {d} {s}\n", .{ case[0], outcome.failure.code, outcome.failure.data_json orelse "" });
            return error.TestUnexpectedResult;
        }
        try std.testing.expect(std.mem.startsWith(u8, outcome.result, "{\"dry_run\":true,\"would_act\":\""));
        try std.testing.expect(std.mem.indexOf(u8, outcome.result, "Sam") == null);
        // The runner's clean rate-limit scans: after navigating, before the trial, at the end.
        try std.testing.expect(std.mem.indexOf(u8, outcome.result, "{\"name\":\"rate_limit_scans\",\"result\":\"pass\",\"count\":") != null);
        try std.testing.expect(f.h.fake.scan_calls >= 2);
        try std.testing.expect(std.mem.indexOf(u8, outcome.result, "{\"name\":\"daily_cap\",\"result\":\"note\",\"count\":100,\"reason\":\"a dry run is not counted\"}") != null);
        try std.testing.expectEqual(@as(usize, 0), realClicks(&f.h.fake));
        for ([_][]const u8{ "type", "fill", "press", "selectOption" }) |op| try std.testing.expectEqual(@as(usize, 0), countOps(&f.h.fake, op));
        try std.testing.expectEqual(before, f.h.state.remaining());
        try std.testing.expectEqual(@as(usize, 0), counter.count);
        try std.testing.expectEqual(@as(usize, 0), f.h.clock.sleeps.items.len);
    }
}

test "dry run story_view: no Next clicked, no frame viewed, nothing counted" {
    var f: FlowHarness = undefined;
    f.init();
    defer f.deinit();
    f.h.fake.navigate_sets_url = true;
    const before = f.h.state.remaining();
    // flow_ok answers every query with one element: the "View story" gate
    // check then finds one, so the dry run stops before that click.
    var outcome = try f.call("instagram.story_view", "{\"username\":\"sam\",\"options\":{\"dry_run\":true}}");
    defer outcome.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, outcome.result, "instagram_story_view_needs_click") != null);
    try std.testing.expectEqual(@as(usize, 0), realClicks(&f.h.fake));
    try std.testing.expectEqual(before, f.h.state.remaining());
    try std.testing.expectEqual(@as(usize, 0), f.h.clock.sleeps.items.len);
}

test "dry run at the daily cap: not refused (no admission at all); pacing state byte for byte unchanged; the note names the real call's error" {
    var f: FlowHarness = undefined;
    f.init();
    defer f.deinit();
    f.h.state.limiter.updateConfig(.{ .min_delay_ms = 3000, .max_delay_ms = 8000, .daily_cap = 1 });
    var counter: ChangeCounter = .{};
    f.h.state.on_change = counter.hook();
    var used = f.h.state.reserve().?;
    used.commit();
    try std.testing.expectEqual(@as(u32, 0), f.h.state.remaining());
    const saved = f.h.state.persisted();
    const changes = counter.count;
    var outcome = try f.call("instagram.like", "{\"postUrl\":\"https://www.instagram.com/p/1/\",\"options\":{\"dry_run\":true}}");
    defer outcome.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, outcome.result, "{\"name\":\"daily_cap\",\"result\":\"note\",\"count\":0,\"reason\":\"the real call would be refused now: social_daily_cap\"}") != null);
    try std.testing.expectEqual(@as(usize, 1), f.h.fake.navigate_calls.items.len);
    try std.testing.expect(std.meta.eql(saved, f.h.state.persisted()));
    try std.testing.expectEqual(changes, counter.count);
    try std.testing.expectEqual(@as(u32, 0), f.h.state.in_flight);
    try std.testing.expectEqual(@as(usize, 0), f.h.clock.sleeps.items.len);

    // The real call is refused there.
    var real = try f.call("instagram.like", "{\"postUrl\":\"https://www.instagram.com/p/1/\"}");
    defer real.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32010), real.failure.code);
}

test "dry run: a challenge page after navigating is the real flow's -32010; a failed trial is the real click's failure" {
    var f: FlowHarness = undefined;
    f.init();
    defer f.deinit();
    f.h.fake.scan_replies = &.{.{ .json = fakes.detectedScan("challenge", "linkedin") }};
    var outcome = try f.call("linkedin.like", "{\"postUrl\":\"https://www.linkedin.com/feed/update/1/\",\"options\":{\"dry_run\":true}}");
    defer outcome.deinit(gpa);
    try expectRateLimited(outcome, "challenge", "linkedin");
    try std.testing.expectEqual(@as(usize, 0), f.h.fake.eval_calls.items.len);
}

test "options: only {dry_run: bool} and only on the ten acting flows; anything else is -32602 before any page work" {
    var f: FlowHarness = undefined;
    f.init();
    defer f.deinit();
    for ([_][2][]const u8{
        .{ "linkedin.connect", "{\"profileUrl\":\"https://www.linkedin.com/in/a/\",\"options\":{\"dry_run\":\"yes\"}}" },
        .{ "linkedin.connect", "{\"profileUrl\":\"https://www.linkedin.com/in/a/\",\"options\":{\"dry_run\":true,\"x\":1}}" },
        .{ "linkedin.connect", "{\"profileUrl\":\"https://www.linkedin.com/in/a/\",\"options\":true}" },
        .{ "linkedin.follow", "{\"profileUrl\":\"https://www.linkedin.com/in/a/\",\"options\":[]}" },
        .{ "linkedin.visit", "{\"profileUrl\":\"https://www.linkedin.com/in/a/\",\"options\":{\"dry_run\":true}}" },
        .{ "linkedin.message", "{\"text\":\"hi\",\"conversationUrl\":\"https://www.linkedin.com/messaging/1/\",\"options\":{\"dry_run\":true}}" },
        .{ "linkedin.search", "{\"query\":\"zig\",\"options\":{\"dry_run\":true}}" },
        .{ "instagram.dm", "{\"username\":\"ada\",\"text\":\"hi\",\"options\":{\"dry_run\":true}}" },
        .{ "instagram.selfcheck", "{\"options\":{\"dry_run\":true}}" },
        .{ "instagram.comment", "{\"postUrl\":\"https://www.instagram.com/p/1/\",\"options\":{\"dry_run\":true}}" },
    }) |case| {
        var outcome = try f.call(case[0], case[1]);
        defer outcome.deinit(gpa);
        if (outcome != .failure or outcome.failure.code != -32602) {
            std.debug.print("accepted {s} {s}\n", .{ case[0], case[1] });
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), f.h.fake.navigate_calls.items.len);

    // dry_run false is the real flow.
    var real = try f.call("instagram.like", "{\"postUrl\":\"https://www.instagram.com/p/1/\",\"options\":{\"dry_run\":false}}");
    defer real.deinit(gpa);
    try std.testing.expectEqualStrings("{\"ok\":true}", real.result);
}

// ---- N21: pacing state persists across restarts ----

const pacing_store = automation.pacing_store;
const x_routes = automation.x_routes;

/// Absolute path of `name` inside a fresh test dir.
const StoreDir = struct {
    tmp: std.testing.TmpDir,
    buf: [std.fs.max_path_bytes]u8 = undefined,
    path: []const u8 = "",

    fn init(self: *StoreDir) !void {
        self.tmp = std.testing.tmpDir(.{ .iterate = true });
        var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try self.tmp.dir.realPath(std.testing.io, &dir_buf);
        self.path = try std.fmt.bufPrint(&self.buf, "{s}/{s}", .{ dir_buf[0..n], pacing_store.file_name });
    }

    fn deinit(self: *StoreDir) void {
        self.tmp.cleanup();
    }

    fn write(self: *StoreDir, text: []const u8) !void {
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = pacing_store.file_name, .data = text });
    }

    fn entries(self: *StoreDir) !usize {
        var it = self.tmp.dir.iterate();
        var n: usize = 0;
        while (try it.next(std.testing.io)) |_| n += 1;
        return n;
    }
};

const day_now: i32 = @intCast(@divFloor(1_791_644_400_000, 86_400_000));

test "N21 store: save then load round-trips; the file is 0600 and no temp file is left" {
    var d: StoreDir = .{ .tmp = undefined };
    try d.init();
    defer d.deinit();
    const io = std.testing.io;
    try std.testing.expect(pacing_store.load(io, gpa, d.path) == .missing);
    const snapshot = pacing_store.Snapshot{
        .day = day_now,
        .social = .{ .actions_today = 3, .daily_cap = 40, .min_delay_ms = 100, .max_delay_ms = 200 },
        .x = .{ .actions_today = 7, .daily_cap = 50, .min_delay_ms = 0, .max_delay_ms = 0 },
    };
    try pacing_store.save(io, d.path, snapshot);
    const loaded = pacing_store.load(io, gpa, d.path);
    try std.testing.expect(loaded == .ok);
    try std.testing.expectEqualDeep(snapshot, loaded.ok);
    const stat = try d.tmp.dir.statFile(io, pacing_store.file_name, .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
    try std.testing.expectEqual(@as(usize, 1), try d.entries());
    // A second save replaces it (still one file, still 0600).
    var later = snapshot;
    later.social.actions_today = 4;
    try pacing_store.save(io, d.path, later);
    try std.testing.expectEqual(@as(u32, 4), pacing_store.load(io, gpa, d.path).ok.social.actions_today);
    try std.testing.expectEqual(@as(usize, 1), try d.entries());
}

test "N21 store: garbage, a wrong version, impossible values or an oversized file are corrupt (fall back to defaults)" {
    var d: StoreDir = .{ .tmp = undefined };
    try d.init();
    defer d.deinit();
    const io = std.testing.io;
    const part = "{\"actions_today\":1,\"daily_cap\":10,\"min_delay_ms\":1,\"max_delay_ms\":2}";
    for ([_][]const u8{
        "not json",
        "{\"version\":2,\"day\":1,\"social\":" ++ part ++ ",\"x\":" ++ part ++ "}",
        "{\"version\":1,\"day\":1,\"social\":{\"actions_today\":1,\"daily_cap\":10,\"min_delay_ms\":5,\"max_delay_ms\":2},\"x\":" ++ part ++ "}",
        "{\"version\":1,\"day\":1,\"social\":" ++ part ++ "}",
        "{\"version\":1,\"day\":1,\"social\":{\"actions_today\":-1,\"daily_cap\":10,\"min_delay_ms\":1,\"max_delay_ms\":2},\"x\":" ++ part ++ "}",
        "{\"version\":1,\"day\":1,\"social\":" ++ part ++ ",\"x\":" ++ part ++ "}" ++ " " ** 5000,
        // Every field is required: no version, no count, no day.
        "{\"day\":1,\"social\":" ++ part ++ ",\"x\":" ++ part ++ "}",
        "{\"version\":1,\"day\":1,\"social\":{\"daily_cap\":10,\"min_delay_ms\":1,\"max_delay_ms\":2},\"x\":" ++ part ++ "}",
        "{\"version\":1,\"social\":" ++ part ++ ",\"x\":" ++ part ++ "}",
        "{\"version\":1,\"day\":1,\"social\":" ++ part ++ ",\"x\":" ++ part ++ ",\"extra\":1}",
    }) |text| {
        try d.write(text);
        if (pacing_store.load(io, gpa, d.path) != .corrupt) {
            std.debug.print("accepted {s}\n", .{text[0..@min(text.len, 80)]});
            return error.TestUnexpectedResult;
        }
    }
}

test "N21 restore: today's counts and the config come back; a file from another UTC day keeps the config, not the counts" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    const part = pacing_store.Part{ .actions_today = 3, .daily_cap = 40, .min_delay_ms = 100, .max_delay_ms = 200 };
    h.state.restore(part, day_now);
    try std.testing.expectEqual(@as(u32, 37), h.state.remaining());
    try std.testing.expectEqual(@as(u32, 200), h.state.pacingConfig().max_delay_ms);

    var other: Harness = undefined;
    other.init();
    defer other.deinit();
    other.state.restore(part, day_now - 1);
    try std.testing.expectEqual(@as(u32, 40), other.state.remaining());
    try std.testing.expectEqual(@as(u32, 100), other.state.pacingConfig().min_delay_ms);

    var x = x_routes.XState.init(fakeWall);
    x.restore(.{ .actions_today = 49, .daily_cap = 50, .min_delay_ms = 0, .max_delay_ms = 0 }, day_now);
    try std.testing.expectEqual(@as(u32, 1), x.remaining());
}

const ChangeCounter = struct {
    count: usize = 0,
    fn hook(self: *ChangeCounter) automation.pacing.ChangeHook {
        return .{ .ctx = self, .changed = changed };
    }
    fn changed(ctx: *anyopaque) void {
        const self: *ChangeCounter = @ptrCast(@alignCast(ctx));
        self.count += 1;
    }
};

test "N21 hook: a counted action and social.set_pacing report a change; a released reservation and a read do not" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    var counter: ChangeCounter = .{};
    h.state.on_change = counter.hook();
    var released = h.state.reserve().?;
    released.release();
    try std.testing.expectEqual(@as(usize, 0), counter.count);
    var committed = h.state.reserve().?;
    committed.commit();
    try std.testing.expectEqual(@as(usize, 1), counter.count);
    var status = try h.call("social.rate_status", "{}");
    defer status.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), counter.count);
    var set = try h.call("social.set_pacing", "{\"daily_cap\":5}");
    defer set.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), counter.count);
    var bad = try h.call("social.set_pacing", "{\"daily_cap\":\"x\"}");
    defer bad.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), counter.count);
}

test "N21 persister: actions are written as they count, and a fresh server state loaded from the file has the reduced remaining count" {
    var d: StoreDir = .{ .tmp = undefined };
    try d.init();
    defer d.deinit();
    const io = std.testing.io;
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    var x = x_routes.XState.init(fakeWall);
    var persister = pacing_store.Persister{ .io = io, .path = d.path, .social = &h.state, .x = &x };
    persister.attach();
    for (0..2) |_| {
        var r = h.state.reserve().?;
        r.commit();
    }
    var x_post = x.reserve().?;
    x_post.commit();
    const saved = pacing_store.load(io, gpa, d.path).ok;
    try std.testing.expectEqual(@as(u32, 2), saved.social.actions_today);
    try std.testing.expectEqual(@as(u32, 1), saved.x.actions_today);

    // "Restart": new states, loaded from the file.
    var again: Harness = undefined;
    again.init();
    defer again.deinit();
    var x2 = x_routes.XState.init(fakeWall);
    var p2 = pacing_store.Persister{ .io = io, .path = d.path, .social = &again.state, .x = &x2 };
    try std.testing.expect(p2.loadInto(gpa) == .ok);
    try std.testing.expectEqual(@as(u32, 98), again.state.remaining());
    try std.testing.expectEqual(@as(u32, 49), x2.remaining());
}
