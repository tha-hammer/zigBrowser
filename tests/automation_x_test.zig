//! N11: x.* routed through Engine.executeExternal; each flow step is a real
//! router command run by the engine against the (fake) page.
const std = @import("std");
const automation = @import("automation");
const fakes = @import("automation/fake_page_port.zig");

const x_routes = automation.x_routes;
const engine = automation.engine;

const gpa = std.testing.allocator;

/// Valid both as an action result and as a dom.query answer (one element).
const ok_reply = fakes.EvalReply{ .json = "{\"ok\":true,\"value\":{\"ok\":true,\"elements\":[{\"id\":\"zb-1\",\"tag\":\"button\",\"text\":\"Post\",\"bbox\":{}}]}}" };

const Harness = struct {
    fake: fakes.FakePagePort,
    clock: fakes.FakeClock,
    engine: engine.Engine,
    state: x_routes.XState,
    sink: automation.telemetry.InMemoryTelemetrySink,
    budget_ms: u64 = x_routes.flow_budget_ms,
    /// The command's cancel flag (a server stop).
    cancel: std.atomic.Value(bool) = .init(false),

    fn init(self: *Harness, replies: []const fakes.EvalReply) void {
        self.fake = fakes.FakePagePort.init(gpa);
        self.fake.eval_replies = replies;
        self.clock = fakes.FakeClock.init(gpa);
        self.engine = engine.Engine.init(self.fake.port(), self.clock.clock());
        self.state = x_routes.XState.init(fakeWall);
        self.sink = automation.telemetry.InMemoryTelemetrySink.init(gpa);
        self.budget_ms = x_routes.flow_budget_ms;
        self.cancel = .init(false);
    }

    fn deinit(self: *Harness) void {
        self.sink.deinit();
        self.fake.deinit();
        self.clock.deinit();
    }

    fn call(self: *Harness, method: []const u8, params: []const u8) !engine.Outcome {
        const Call = struct {
            state: *x_routes.XState,
            verb: x_routes.Verb,
            params: []const u8,
            budget_ms: u64,
            fn run(c: @This(), a: std.mem.Allocator, ext: *engine.External) error{OutOfMemory}!engine.Outcome {
                return x_routes.handleWithBudget(a, c.state, ext, c.verb, c.params, c.budget_ms);
            }
        };
        return self.engine.executeExternal(gpa, method, "x", .{ .cancel = &self.cancel, .route = .{ .telemetry_sink = self.sink.sink() } }, Call{
            .state = &self.state,
            .verb = x_routes.verbFromMethod(method).?,
            .params = params,
            .budget_ms = self.budget_ms,
        }, Call.run);
    }

    fn ops(self: *Harness, buf: [][]const u8) ![][]const u8 {
        for (self.fake.eval_calls.items, 0..) |call_item, i| {
            const parsed = try std.json.parseFromSlice(std.json.Value, gpa, call_item.arg, .{});
            defer parsed.deinit();
            buf[i] = if (parsed.value.object.get("op")) |op| opName(op.string) else "?";
        }
        return buf[0..self.fake.eval_calls.items.len];
    }
};

fn opName(op: []const u8) []const u8 {
    for ([_][]const u8{ "waitFor", "click", "type", "query", "selectOption", "fill" }) |known| {
        if (std.mem.eql(u8, known, op)) return known;
    }
    return "?";
}

fn fakeWall() i64 {
    return 1_791_644_400_000;
}

test "x.post runs each flow step through the engine and records one x root span" {
    var h: Harness = undefined;
    h.init(&.{ok_reply});
    defer h.deinit();

    var outcome = try h.call("x.post", "{\"text\":\"hello\",\"compose_url\":\"http://127.0.0.1:9/compose\"}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqualStrings("{\"ok\":true}", outcome.result);
    try std.testing.expectEqualStrings("http://127.0.0.1:9/compose", h.fake.navigate_calls.items[0]);
    var buf: [32][]const u8 = undefined;
    const ops = try h.ops(&buf);
    const expected_ops = [_][]const u8{ "waitFor", "click", "fill", "type", "query", "click", "click", "waitFor" };
    try std.testing.expectEqual(expected_ops.len, ops.len);
    for (expected_ops, ops) |e, a| try std.testing.expectEqualStrings(e, a);

    var roots: usize = 0;
    var root_trace: []const u8 = "";
    for (h.sink.spans.items) |span| {
        if (!std.mem.eql(u8, span.name, "automation.command")) continue;
        roots += 1;
        root_trace = span.trace_id;
        try std.testing.expectEqualStrings("x.post", span.attr("rpc.method").?);
        try std.testing.expectEqualStrings("x", span.attr("rpc.namespace").?);
    }
    try std.testing.expectEqual(@as(usize, 1), roots);
    var children: usize = 0;
    var scans: usize = 0;
    for (h.sink.spans.items) |span| {
        if (std.mem.eql(u8, span.name, "automation.platform.eval")) {
            children += 1;
            try std.testing.expectEqualStrings(root_trace, span.trace_id);
        }
        if (std.mem.eql(u8, span.name, "automation.rate_limit_scan")) {
            scans += 1;
            try std.testing.expectEqualStrings("x", span.attr("platform").?);
            try std.testing.expectEqualStrings("none", span.attr("signal").?);
        }
    }
    // N20 scans: after the navigation, before each action that follows an
    // action (fill, type, trial probe, Post click), and once more before
    // reporting success (the Post click was not scanned after).
    try std.testing.expectEqual(@as(usize, 6), h.fake.scan_calls);
    try std.testing.expectEqual(@as(usize, 6), scans);
    try std.testing.expectEqual(@as(usize, 9 + 6), children); // navigate + 8 step evals + 6 scans
    try std.testing.expect(!h.sink.containsRaw("hello"));
}

test "x.schedule_post drives the schedule dialog" {
    var h: Harness = undefined;
    h.init(&.{ok_reply});
    defer h.deinit();

    var outcome = try h.call("x.schedule_post", "{\"text\":\"later\",\"date\":\"2026-11-05\",\"time\":\"14:07\"}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqualStrings("{\"ok\":true,\"scheduledFor\":\"2026-11-05T14:07\"}", outcome.result);
    var buf: [32][]const u8 = undefined;
    const ops = try h.ops(&buf);
    var selects: usize = 0;
    for (ops) |op| {
        if (std.mem.eql(u8, op, "selectOption")) selects += 1;
    }
    try std.testing.expectEqual(@as(usize, 6), selects);
}

test "logged-out page -> session_invalid with reason logged_out and ids" {
    var h: Harness = undefined;
    h.init(&.{
        .{ .json = "{\"ok\":false,\"error\":\"element_not_found\",\"retryable\":false,\"data\":{\"reason\":\"timeout\"}}" },
        .{ .json = "{\"ok\":true,\"value\":{\"elements\":[{\"id\":\"zb-1\",\"tag\":\"a\",\"text\":\"Log in\",\"bbox\":{}}]}}" },
    });
    defer h.deinit();

    var outcome = try h.call("x.post", "{\"text\":\"hi\"}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32011), outcome.failure.code);
    const data = try std.json.parseFromSlice(std.json.Value, gpa, outcome.failure.data_json.?, .{});
    defer data.deinit();
    try std.testing.expectEqualStrings("logged_out", data.value.object.get("reason").?.string);
    try std.testing.expect(data.value.object.get("trace_id") != null);
}

test "a failing step surfaces that step's error (with ids)" {
    var h: Harness = undefined;
    h.init(&.{ ok_reply, ok_reply, ok_reply, .{ .json = "{\"ok\":false,\"error\":\"element_disabled\",\"retryable\":false,\"data\":{\"reason\":\"enabled\"}}" } });
    defer h.deinit();

    var outcome = try h.call("x.post", "{\"text\":\"hi\"}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32005), outcome.failure.code);
    try std.testing.expect(std.mem.indexOf(u8, outcome.failure.data_json.?, "\"trace_id\"") != null);
}

test "invalid params -> -32602 before touching the page" {
    var h: Harness = undefined;
    h.init(&.{ok_reply});
    defer h.deinit();
    for ([_][2][]const u8{
        .{ "x.post", "{}" },
        .{ "x.post", "{\"text\":\"\"}" },
        .{ "x.post", "{\"text\":1}" },
        .{ "x.post", "{\"text\":\"a\",\"bogus\":1}" },
        .{ "x.schedule_post", "{\"text\":\"a\",\"date\":\"2026-02-30\",\"time\":\"10:00\"}" },
        .{ "x.schedule_post", "{\"text\":\"a\",\"date\":\"2026-02-03\"}" },
        .{ "x.login_check", "{\"x\":1}" },
    }) |c| {
        var outcome = try h.call(c[0], c[1]);
        defer outcome.deinit(gpa);
        try std.testing.expectEqual(@as(i64, -32602), outcome.failure.code);
    }
    try std.testing.expectEqual(@as(usize, 0), h.fake.navigate_calls.items.len);
    try std.testing.expectEqual(@as(usize, 0), h.fake.eval_calls.items.len);
}

test "X pacing: 50 posts per day, then platform_rate_limited without touching the page" {
    var h: Harness = undefined;
    h.init(&.{ok_reply});
    defer h.deinit();
    try std.testing.expectEqual(@as(u32, 50), x_routes.default_daily_cap);

    for (0..x_routes.default_daily_cap) |_| {
        var outcome = try h.call("x.post", "{\"text\":\"hi\"}");
        defer outcome.deinit(gpa);
        try std.testing.expectEqualStrings("{\"ok\":true}", outcome.result);
    }
    const navigations = h.fake.navigate_calls.items.len;
    var limited = try h.call("x.schedule_post", "{\"text\":\"hi\",\"date\":\"2026-11-05\",\"time\":\"10:00\"}");
    defer limited.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32010), limited.failure.code);
    try std.testing.expectEqual(navigations, h.fake.navigate_calls.items.len);
    try std.testing.expectEqual(@as(u32, 0), h.state.remaining());
}

test "a failed post does not consume an X action" {
    var h: Harness = undefined;
    h.init(&.{.{ .json = "{\"ok\":false,\"error\":\"element_disabled\",\"retryable\":false,\"data\":{\"reason\":\"enabled\"}}" }});
    defer h.deinit();
    var outcome = try h.call("x.post", "{\"text\":\"hi\"}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqual(x_routes.default_daily_cap, h.state.remaining());
}

test "x.selfcheck reports a count per selector without navigating, typing or pacing" {
    var h: Harness = undefined;
    h.init(&.{ok_reply});
    defer h.deinit();
    var outcome = try h.call("x.selfcheck", "{}");
    defer outcome.deinit(gpa);
    try std.testing.expect(std.mem.startsWith(u8, outcome.result, "{\"composer\":1,"));
    try std.testing.expectEqual(@as(usize, 0), h.fake.navigate_calls.items.len);
    for (h.fake.eval_calls.items) |call| try std.testing.expect(std.mem.indexOf(u8, call.arg, "\"op\":\"query\"") != null);
    try std.testing.expectEqual(x_routes.default_daily_cap, h.state.remaining());
    var bad = try h.call("x.selfcheck", "{\"selector\":\"x\"}");
    defer bad.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32602), bad.failure.code);
}

test "x.login_check reports the composer on the current page" {
    var h: Harness = undefined;
    h.init(&.{.{ .json = "{\"ok\":true,\"value\":{\"elements\":[{\"id\":\"zb-1\",\"tag\":\"div\",\"text\":\"\",\"bbox\":{}}]}}" }});
    defer h.deinit();
    var outcome = try h.call("x.login_check", "{}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqualStrings("{\"loggedIn\":true,\"platform\":\"x\"}", outcome.result);
    try std.testing.expectEqual(@as(usize, 0), h.fake.navigate_calls.items.len);
}

test "a successful but malformed query answer is an internal error, not a crash" {
    var h: Harness = undefined;
    // composer waitFor fails -> login-link probe answers without "elements".
    h.init(&.{
        .{ .json = "{\"ok\":false,\"error\":\"element_not_found\",\"retryable\":false,\"data\":{\"reason\":\"timeout\"}}" },
        .{ .json = "{\"ok\":true,\"value\":{}}" },
    });
    defer h.deinit();
    var outcome = try h.call("x.post", "{\"text\":\"hi\"}");
    defer outcome.deinit(gpa);
    // The earlier waitFor failure is stale: the malformed answer is what
    // stopped the flow, reported as -32603 with the x.* command's ids.
    try std.testing.expectEqual(@as(i64, -32603), outcome.failure.code);
    try std.testing.expectEqualStrings("Unexpected page answer", outcome.failure.message);
    try std.testing.expect(std.mem.indexOf(u8, outcome.failure.data_json.?, "\"trace_id\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, outcome.failure.data_json.?, "\"command_id\"") != null);

    var h2: Harness = undefined;
    h2.init(&.{.{ .json = "{\"ok\":true,\"value\":{\"elements\":\"nope\"}}" }});
    defer h2.deinit();
    var login = try h2.call("x.login_check", "{}");
    defer login.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32603), login.failure.code);
    try std.testing.expect(std.mem.indexOf(u8, login.failure.data_json.?, "\"trace_id\"") != null);
}

test "an x.* flow has one overall deadline across its steps" {
    var h: Harness = undefined;
    h.init(&.{ok_reply});
    defer h.deinit();
    h.fake.clock = &h.clock;
    // Each page step takes 1 s (within its own timeout); the 3 s budget is
    // spent after waitFor, click and fill, so the type step never starts.
    h.budget_ms = 3_000;
    h.fake.eval_cost_ms = 1_000;

    var outcome = try h.call("x.post", "{\"text\":\"hi\"}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32009), outcome.failure.code);
    try std.testing.expect(std.mem.indexOf(u8, outcome.failure.data_json.?, "x_flow_deadline") != null);
    try std.testing.expect(h.fake.eval_calls.items.len <= 4);
}

test "no Post button ever: element_not_found x_post_button_missing with the x.* ids, after a bounded wait" {
    var h: Harness = undefined;
    h.init(&.{
        ok_reply, // composer waitFor
        ok_reply, // click composer
        ok_reply, // fill ""
        ok_reply, // type
        .{ .json = "{\"ok\":true,\"value\":{\"elements\":[]}}" }, // every Post query from here on
    });
    defer h.deinit();
    var outcome = try h.call("x.post", "{\"text\":\"hi\"}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32001), outcome.failure.code);
    const data = outcome.failure.data_json.?;
    try std.testing.expect(std.mem.indexOf(u8, data, "x_post_button_missing") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "\"trace_id\"") != null);
    var slept: u64 = 0;
    for (h.clock.sleeps.items) |ms| slept += ms;
    try std.testing.expect(slept >= 9_000 and slept <= 10_000);
}

test "a waitFor is not started without room for its native grace (hard flow budget)" {
    var h: Harness = undefined;
    h.init(&.{ok_reply});
    defer h.deinit();
    h.fake.clock = &h.clock;
    // 999 ms of budget: less than the 1 s waitFor grace.
    h.budget_ms = 999;
    var outcome = try h.call("x.post", "{\"text\":\"hi\"}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32009), outcome.failure.code);
    try std.testing.expect(std.mem.indexOf(u8, outcome.failure.data_json.?, "x_flow_deadline") != null);
    try std.testing.expectEqual(@as(usize, 0), h.fake.eval_calls.items.len);
    try std.testing.expectEqual(@as(usize, 0), h.fake.url_calls);
}

test "a later successful lookup does not erase the failure that stopped the flow" {
    // Composer waitFor fails; the login-link probe succeeds with no match:
    // the waitFor failure is what the caller gets (not a fabricated -32603).
    var h: Harness = undefined;
    h.init(&.{
        .{ .json = "{\"ok\":false,\"error\":\"element_not_found\",\"retryable\":false,\"data\":{\"reason\":\"timeout\"}}" },
        .{ .json = "{\"ok\":true,\"value\":{\"elements\":[]}}" },
    });
    defer h.deinit();
    var outcome = try h.call("x.post", "{\"text\":\"hi\"}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32001), outcome.failure.code);
    try std.testing.expect(std.mem.indexOf(u8, outcome.failure.data_json.?, "\"reason\":\"timeout\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, outcome.failure.data_json.?, "\"trace_id\"") != null);

    // Post search: the tweetButton copy fails its trial, then the
    // tweetButtonInline query succeeds with zero copies, every round. The
    // trial failure is the evidence (not -32603, not x_post_button_missing).
    var p: Harness = undefined;
    p.init(&.{
        ok_reply, ok_reply, ok_reply, ok_reply, // waitFor, click, fill, type
        .{ .json = "{\"ok\":true,\"value\":{\"elements\":[{\"id\":\"zb-1\",\"tag\":\"button\",\"text\":\"Post\",\"bbox\":{}}]}}" }, // tweetButton: 1 copy
        .{ .json = "{\"ok\":false,\"error\":\"element_disabled\",\"retryable\":false,\"data\":{\"reason\":\"disabled\"}}" }, // its trial
        .{ .json = "{\"ok\":true,\"value\":{\"elements\":[]}}" }, // inline: 0 copies, from here on
    });
    defer p.deinit();
    var post = try p.call("x.post", "{\"text\":\"hi\"}");
    defer post.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32005), post.failure.code);
}

test "x.post options: input/humanize accepted and validated (humanize needs native; unknown keys and types rejected)" {
    var h: Harness = undefined;
    h.init(&.{ok_reply});
    defer h.deinit();
    for ([_][]const u8{
        "{\"text\":\"hi\",\"options\":{\"humanize\":true}}",
        "{\"text\":\"hi\",\"options\":{\"input\":\"synthetic\",\"humanize\":true}}",
        "{\"text\":\"hi\",\"options\":{\"input\":\"trusted\"}}",
        "{\"text\":\"hi\",\"options\":{\"input\":\"native\",\"delay_ms\":40}}",
        "{\"text\":\"hi\",\"options\":{\"humanize\":\"yes\",\"input\":\"native\"}}",
        "{\"text\":\"hi\",\"options\":\"native\"}",
    }) |params| {
        var outcome = try h.call("x.post", params);
        defer outcome.deinit(gpa);
        if (outcome != .failure or outcome.failure.code != -32602) {
            std.debug.print("accepted {s}\n", .{params});
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), h.fake.navigate_calls.items.len);
    // Valid options reach the flow (engine side: native click needs the
    // native-capable fake port, which this harness has).
    var ok = try h.call("x.post", "{\"text\":\"hi\",\"options\":{\"input\":\"synthetic\"}}");
    defer ok.deinit(gpa);
    try std.testing.expect(ok == .result);
}

test "flow budgets: timeout_ms (1..600000), humanized sizing from the typing schedule, 120 s default" {
    const flow = automation.flow_steps;
    try std.testing.expectEqual(@as(u64, 120_000), flow.flowBudgetMs(120_000, null, null));
    try std.testing.expectEqual(@as(u64, 300_000), flow.flowBudgetMs(120_000, 300_000, null));
    // An explicit timeout wins over humanized sizing.
    try std.testing.expectEqual(@as(u64, 90_000), flow.flowBudgetMs(120_000, 90_000, "word " ** 56));
    // A humanized 280-character post (56 spaces): the default + the typing
    // worst case (224 x 250 + 56 x 650 + 5 000) + 10 s of clicks.
    const long = "word " ** 56;
    try std.testing.expectEqual(@as(u64, 120_000 + 97_400 + 10_000), flow.flowBudgetMs(120_000, null, long));
    try std.testing.expect(flow.flowBudgetMs(120_000, null, long) > 120_000);
    // Capped at 600 s however long the text.
    try std.testing.expectEqual(@as(u64, 600_000), flow.flowBudgetMs(120_000, null, " " ** 2000));
    // timeout_ms values.
    try std.testing.expectEqual(@as(?u64, null), try flow.flowTimeoutParam(null));
    try std.testing.expectEqual(@as(?u64, 600_000), try flow.flowTimeoutParam(.{ .integer = 600_000 }));
    for ([_]std.json.Value{ .{ .integer = 0 }, .{ .integer = -5 }, .{ .integer = 600_001 }, .{ .float = 1.5 }, .{ .string = "5000" }, .{ .bool = true } }) |bad| {
        try std.testing.expectError(error.InvalidParams, flow.flowTimeoutParam(bad));
    }
    // Typing steps scale with the text (not a fixed 30 s).
    try std.testing.expectEqual(@as(u64, 30_000), flow.typingTimeoutMs("hi", false));
    try std.testing.expectEqual(@as(u64, 100 * 1000 + 5_000), flow.typingTimeoutMs("x" ** 1000, false));
}

test "x.post timeout_ms: invalid values are -32602; a slow flow fits a larger budget and hits the default one" {
    var h: Harness = undefined;
    h.init(&.{ok_reply});
    defer h.deinit();
    for ([_][]const u8{
        "{\"text\":\"hi\",\"timeout_ms\":0}",
        "{\"text\":\"hi\",\"timeout_ms\":600001}",
        "{\"text\":\"hi\",\"timeout_ms\":\"5000\"}",
        "{\"text\":\"hi\",\"timeout_ms\":2.5}",
    }) |params| {
        var outcome = try h.call("x.post", params);
        defer outcome.deinit(gpa);
        if (outcome != .failure or outcome.failure.code != -32602) {
            std.debug.print("accepted {s}\n", .{params});
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), h.fake.navigate_calls.items.len);

    // Each page step takes 1 s: a 3 s default budget runs out ...
    var slow: Harness = undefined;
    slow.init(&.{ok_reply});
    defer slow.deinit();
    slow.fake.clock = &slow.clock;
    slow.fake.eval_cost_ms = 1_000;
    slow.budget_ms = 3_000;
    var default_budget = try slow.call("x.post", "{\"text\":\"hi\"}");
    defer default_budget.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32009), default_budget.failure.code);
    try std.testing.expect(std.mem.indexOf(u8, default_budget.failure.data_json.?, "x_flow_deadline") != null);

    // ... while timeout_ms 20000 (larger than that default) lets the same
    // flow finish.
    var roomy: Harness = undefined;
    roomy.init(&.{ok_reply});
    defer roomy.deinit();
    roomy.fake.clock = &roomy.clock;
    roomy.fake.eval_cost_ms = 1_000;
    roomy.budget_ms = 3_000;
    var bigger = try roomy.call("x.post", "{\"text\":\"hi\",\"timeout_ms\":20000}");
    defer bigger.deinit(gpa);
    try std.testing.expectEqualStrings("{\"ok\":true}", bigger.result);
    try std.testing.expect(roomy.clock.now_ms > 3_000 and roomy.clock.now_ms <= 20_000);
}

// Answers every flow step: an action, a one-element query and a native
// locate target (centre, document token, viewport).
const native_reply = fakes.EvalReply{ .json = "{\"ok\":true,\"value\":{\"ok\":true,\"elements\":[{\"id\":\"zb-1\",\"tag\":\"button\",\"text\":\"Post\",\"bbox\":{}}],\"x\":100,\"y\":100,\"document\":\"0123456789abcdef\",\"viewport\":{\"width\":800,\"height\":600}}}" };

test "x.post humanized without timeout_ms: the route sizes its budget from the text (3 s default, 40 characters)" {
    // 40 non-space characters take 3.2-8 s of humanized key delays: more
    // than the 3 s default, well inside the sized budget.
    const text = "a" ** 40;
    const humanized = "{\"text\":\"" ++ text ++ "\",\"options\":{\"input\":\"native\",\"humanize\":true}";
    var prng = std.Random.DefaultPrng.init(0x5eed);

    var sized: Harness = undefined;
    sized.init(&.{native_reply});
    defer sized.deinit();
    sized.fake.clock = &sized.clock;
    sized.budget_ms = 3_000;
    sized.engine.random = prng.random();
    var ok = try sized.call("x.post", humanized ++ "}");
    defer ok.deinit(gpa);
    if (ok != .result) {
        std.debug.print("sized budget failed: {s}\n", .{ok.failure.data_json orelse ok.failure.message});
        return error.TestUnexpectedResult;
    }
    var typed_buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(text, sized.fake.nativeTyped(&typed_buf));
    try std.testing.expect(sized.clock.now_ms > 3_000);

    // The same request held to the 3 s default (what a fixed route budget
    // did) cannot fit the schedule: it fails before typing anything.
    var fixed: Harness = undefined;
    fixed.init(&.{native_reply});
    defer fixed.deinit();
    fixed.fake.clock = &fixed.clock;
    fixed.budget_ms = 3_000;
    fixed.engine.random = prng.random();
    var cut = try fixed.call("x.post", humanized ++ ",\"timeout_ms\":3000}");
    defer cut.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32009), cut.failure.code);
    try std.testing.expectEqualStrings("", fixed.fake.nativeTyped(&typed_buf));
}

// ---- N20: platform rate-limit / challenge signals (automation.js rateLimitScan) ----

fn expectRateLimited(outcome: engine.Outcome, signal: []const u8, platform: []const u8) !void {
    if (outcome != .failure) {
        std.debug.print("expected -32010, got {s}\n", .{outcome.result});
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(@as(i64, -32010), outcome.failure.code);
    try std.testing.expectEqualStrings("platform_rate_limited", outcome.failure.message);
    const data = try std.json.parseFromSlice(std.json.Value, gpa, outcome.failure.data_json.?, .{});
    defer data.deinit();
    try std.testing.expectEqualStrings(signal, data.value.object.get("signal").?.string);
    try std.testing.expectEqualStrings(platform, data.value.object.get("platform").?.string);
    try std.testing.expect(data.value.object.get("trace_id") != null);
    try std.testing.expect(data.value.object.get("command_id") != null);
}

test "N20: a challenge right after navigation stops x.post with -32010 {signal, platform}; nothing on the page, no post counted" {
    var h: Harness = undefined;
    h.init(&.{ok_reply});
    defer h.deinit();
    h.fake.scan_replies = &.{.{ .json = fakes.detectedScan("challenge", "x") }};
    var outcome = try h.call("x.post", "{\"text\":\"hi\"}");
    defer outcome.deinit(gpa);
    try expectRateLimited(outcome, "challenge", "x");
    try std.testing.expectEqual(@as(usize, 1), h.fake.navigate_calls.items.len);
    try std.testing.expectEqual(@as(usize, 1), h.fake.scan_calls);
    try std.testing.expectEqualStrings("x", h.fake.scannedPlatform());
    try std.testing.expectEqual(@as(usize, 0), h.fake.eval_calls.items.len);
    try std.testing.expectEqual(@as(u32, x_routes.default_daily_cap), h.state.remaining());
}

test "N20: a limit modal that appears after a click stops the flow before its next action" {
    var h: Harness = undefined;
    h.init(&.{ok_reply});
    defer h.deinit();
    // Clean after the navigation, then the composer click opens a modal.
    h.fake.scan_replies = &.{ .{ .json = fakes.clean_scan }, .{ .json = fakes.detectedScan("toast", "x") } };
    var outcome = try h.call("x.post", "{\"text\":\"hi\"}");
    defer outcome.deinit(gpa);
    try expectRateLimited(outcome, "toast", "x");
    var buf: [32][]const u8 = undefined;
    const ops = try h.ops(&buf);
    try std.testing.expectEqual(@as(usize, 2), ops.len);
    try std.testing.expectEqualStrings("waitFor", ops[0]);
    try std.testing.expectEqualStrings("click", ops[1]);
    // The second scan ran after that click and before anything else.
    try std.testing.expectEqual(@as(usize, 2), h.fake.scan_calls);
    try std.testing.expectEqual(@as(usize, 2), h.fake.scan_positions[1]);
}

test "N20: a step that fails on a limit page is reported as platform_rate_limited, and no fallback probe runs" {
    var h: Harness = undefined;
    h.init(&.{.{ .json = "{\"ok\":false,\"error\":\"element_not_found\",\"retryable\":false,\"data\":{\"reason\":\"timeout\"}}" }});
    defer h.deinit();
    h.fake.scan_replies = &.{ .{ .json = fakes.clean_scan }, .{ .json = fakes.detectedScan("modal", "x") } };
    var outcome = try h.call("x.post", "{\"text\":\"hi\"}");
    defer outcome.deinit(gpa);
    try expectRateLimited(outcome, "modal", "x");
    try std.testing.expectEqual(@as(usize, 1), h.fake.eval_calls.items.len);
}

test "N20: read-only x.* flows never scan; a scan that cannot run is not evidence" {
    var h: Harness = undefined;
    h.init(&.{ok_reply});
    defer h.deinit();
    h.fake.scan_replies = &.{.{ .json = fakes.detectedScan("challenge", "x") }};
    var check = try h.call("x.login_check", "{}");
    defer check.deinit(gpa);
    try std.testing.expect(check == .result);
    var report = try h.call("x.selfcheck", "{}");
    defer report.deinit(gpa);
    try std.testing.expect(report == .result);
    try std.testing.expectEqual(@as(usize, 0), h.fake.scan_calls);

    var broken: Harness = undefined;
    broken.init(&.{ok_reply});
    defer broken.deinit();
    broken.fake.scan_replies = &.{
        .{ .err = error.EvalFailed },
        .{ .json = "{\"ok\":false,\"error\":\"script_not_ready\",\"retryable\":true,\"data\":{\"reason\":\"script_not_ready\"}}" },
        .{ .json = fakes.clean_scan },
    };
    var posted = try broken.call("x.post", "{\"text\":\"hi\"}");
    defer posted.deinit(gpa);
    try std.testing.expectEqualStrings("{\"ok\":true}", posted.result);
    try std.testing.expect(broken.fake.scan_calls >= 3);
}

test "N20: a limit toast after the final Post click is not a success, and no post is counted" {
    var h: Harness = undefined;
    h.init(&.{ok_reply});
    defer h.deinit();
    const clean = fakes.EvalReply{ .json = fakes.clean_scan };
    h.fake.scan_replies = &.{ clean, clean, clean, clean, clean, .{ .json = fakes.detectedScan("toast", "x") } };
    var outcome = try h.call("x.post", "{\"text\":\"hi\"}");
    defer outcome.deinit(gpa);
    try expectRateLimited(outcome, "toast", "x");
    try std.testing.expectEqual(@as(usize, 6), h.fake.scan_calls);
    try std.testing.expectEqual(@as(u32, x_routes.default_daily_cap), h.state.remaining());
}

test "N20 deadline (RoseCat 4762): a scan that uses up the budget never lets the next action start, and an action after a slow scan gets only what is left" {
    var h: Harness = undefined;
    h.init(&.{ok_reply});
    defer h.deinit();
    h.fake.clock = &h.clock;
    h.budget_ms = 10_000;
    // After the navigation: 4 s (6 s left). Before the fill: 4 s (2 s
    // left). Before the type: more than is left (times out at 0).
    h.fake.scan_costs_ms = &.{4_000};
    var outcome = try h.call("x.post", "{\"text\":\"hi\"}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32009), outcome.failure.code);
    try std.testing.expect(std.mem.indexOf(u8, outcome.failure.data_json.?, "x_flow_deadline") != null);
    var buf: [32][]const u8 = undefined;
    const ops = try h.ops(&buf);
    try std.testing.expectEqual(@as(usize, 3), ops.len);
    try std.testing.expectEqualStrings("fill", ops[2]);
    // The fill was clamped to the 2 s left after its scan, not the 6 s the
    // flow had when it built the step.
    try std.testing.expect(h.fake.eval_calls.items[2].timeout_ms <= 2_000);
    try std.testing.expect(h.clock.now_ms <= 10_000);
}

test "N20 deadline (RoseCat 4762): when the final scan cannot finish in the budget, the post is not a success and is not counted" {
    var h: Harness = undefined;
    h.init(&.{ok_reply});
    defer h.deinit();
    h.fake.clock = &h.clock;
    h.budget_ms = 4_000;
    // Five quick scans, then a final one that needs more than is left of
    // the 4 s budget (under the 5 s scan cap): it uses up the budget.
    h.fake.scan_costs_ms = &.{ 0, 0, 0, 0, 0, 60_000 };
    var outcome = try h.call("x.post", "{\"text\":\"hi\"}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32009), outcome.failure.code);
    try std.testing.expect(std.mem.indexOf(u8, outcome.failure.data_json.?, "x_flow_deadline") != null);
    try std.testing.expectEqual(@as(usize, 6), h.fake.scan_calls);
    try std.testing.expectEqual(@as(u32, x_routes.default_daily_cap), h.state.remaining());
}

test "N20 cancellation (RoseCat 4766): a stop during a scan ends the flow with -32012 before any more page work" {
    // During the scan after the navigation: no step at all, no other scan.
    var a: Harness = undefined;
    a.init(&.{ok_reply});
    defer a.deinit();
    a.fake.cancel = &a.cancel;
    a.fake.cancel_at_scan = 0;
    var first = try a.call("x.post", "{\"text\":\"hi\"}");
    defer first.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32012), first.failure.code);
    try std.testing.expectEqual(@as(usize, 0), a.fake.eval_calls.items.len);
    try std.testing.expectEqual(@as(usize, 1), a.fake.scan_calls);

    // During the scan before the fill: no fill, no reclassification scan.
    var b: Harness = undefined;
    b.init(&.{ok_reply});
    defer b.deinit();
    b.fake.cancel = &b.cancel;
    b.fake.cancel_at_scan = 1;
    var second = try b.call("x.post", "{\"text\":\"hi\"}");
    defer second.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32012), second.failure.code);
    var buf: [32][]const u8 = undefined;
    const ops = try b.ops(&buf);
    try std.testing.expectEqual(@as(usize, 2), ops.len);
    try std.testing.expectEqualStrings("click", ops[1]);
    try std.testing.expectEqual(@as(usize, 2), b.fake.scan_calls);
}

test "N20 cancellation (RoseCat 4766): a step that comes back cancelled stops the flow: no reclassification scan, no fallback probe" {
    var h: Harness = undefined;
    h.init(&.{.{ .err = error.Cancelled }});
    defer h.deinit();
    var outcome = try h.call("x.post", "{\"text\":\"hi\"}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32012), outcome.failure.code);
    try std.testing.expectEqual(@as(usize, 1), h.fake.eval_calls.items.len);
    try std.testing.expectEqual(@as(usize, 1), h.fake.scan_calls);
}

test "N20 cancellation (RoseCat 4772): a stop during a failed step's reclassification scan answers -32012, with no later work" {
    var h: Harness = undefined;
    // Every step succeeds except the last one (the confirmation wait), so
    // no later step can notice the stop: the reclassification scan after
    // it is the last page work.
    const failed = fakes.EvalReply{ .json = "{\"ok\":false,\"error\":\"element_not_found\",\"retryable\":false,\"data\":{\"reason\":\"timeout\"}}" };
    h.init(&.{ ok_reply, ok_reply, ok_reply, ok_reply, ok_reply, ok_reply, ok_reply, failed });
    defer h.deinit();
    h.fake.cancel = &h.cancel;
    // Scans: 0 after the navigation, 1-4 before fill/type/probe/Post, 5
    // after the failed confirmation wait.
    h.fake.cancel_at_scan = 5;
    var outcome = try h.call("x.post", "{\"text\":\"hi\"}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32012), outcome.failure.code);
    try std.testing.expectEqual(@as(usize, 6), h.fake.scan_calls);
    try std.testing.expectEqual(@as(usize, 8), h.fake.eval_calls.items.len);
}

test "N20 cancellation: a platform signal found by a scan that a stop raced still wins (the page showed it)" {
    var h: Harness = undefined;
    h.init(&.{ok_reply});
    defer h.deinit();
    h.fake.scan_replies = &.{.{ .json = fakes.detectedScan("challenge", "x") }};
    h.fake.cancel = &h.cancel;
    h.fake.cancel_at_scan = 0;
    var outcome = try h.call("x.post", "{\"text\":\"hi\"}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32010), outcome.failure.code);
    try std.testing.expectEqual(@as(usize, 0), h.fake.eval_calls.items.len);
}

test "X admission (RoseCat 4777): a post in flight elsewhere holds the last slot; this one is refused with no page work, then admitted once it is released" {
    var h: Harness = undefined;
    h.init(&.{ok_reply});
    defer h.deinit();
    const day: i32 = @intCast(@divFloor(fakeWall(), 86_400_000));
    h.state.restore(.{ .actions_today = 49, .daily_cap = 50, .min_delay_ms = 0, .max_delay_ms = 0 }, day);
    var elsewhere = h.state.reserve().?; // another window's post, still running
    try std.testing.expect(h.state.reserve() == null);
    try std.testing.expectEqual(@as(u32, 0), h.state.remaining());

    var refused = try h.call("x.post", "{\"text\":\"hi\"}");
    defer refused.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32010), refused.failure.code);
    try std.testing.expect(std.mem.indexOf(u8, refused.failure.data_json.?, "x_daily_cap") != null);
    try std.testing.expectEqual(@as(usize, 0), h.fake.navigate_calls.items.len);

    // The other post failed: its slot is free again, and this one counts.
    elsewhere.release();
    var posted = try h.call("x.post", "{\"text\":\"hi\"}");
    defer posted.deinit(gpa);
    try std.testing.expectEqualStrings("{\"ok\":true}", posted.result);
    try std.testing.expectEqual(@as(u32, 0), h.state.remaining());
    try std.testing.expect(h.state.reserve() == null);
}

test "X admission: a failed post releases its slot (nothing counted), and each reservation ends exactly once" {
    var h: Harness = undefined;
    h.init(&.{.{ .json = "{\"ok\":false,\"error\":\"element_not_found\",\"retryable\":false,\"data\":{\"reason\":\"timeout\"}}" }});
    defer h.deinit();
    var failed = try h.call("x.post", "{\"text\":\"hi\"}");
    defer failed.deinit(gpa);
    try std.testing.expect(failed == .failure);
    try std.testing.expectEqual(@as(u32, x_routes.default_daily_cap), h.state.remaining());
    var r = h.state.reserve().?;
    r.commit();
    r.commit();
    r.release();
    try std.testing.expectEqual(@as(u32, x_routes.default_daily_cap - 1), h.state.remaining());
}
