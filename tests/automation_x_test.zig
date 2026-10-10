//! N11: x.* routed through Engine.executeExternal; each flow step is a real
//! router command run by the engine against the (fake) page.
const std = @import("std");
const automation = @import("automation");
const fakes = @import("automation/fake_page_port.zig");

const x_routes = automation.x_routes;
const engine = automation.engine;

const gpa = std.testing.allocator;

const ok_reply = fakes.EvalReply{ .json = "{\"ok\":true,\"value\":{\"ok\":true}}" };

const Harness = struct {
    fake: fakes.FakePagePort,
    clock: fakes.FakeClock,
    engine: engine.Engine,
    state: x_routes.XState,
    sink: automation.telemetry.InMemoryTelemetrySink,

    fn init(self: *Harness, replies: []const fakes.EvalReply) void {
        self.fake = fakes.FakePagePort.init(gpa);
        self.fake.eval_replies = replies;
        self.clock = fakes.FakeClock.init(gpa);
        self.engine = engine.Engine.init(self.fake.port(), self.clock.clock());
        self.state = x_routes.XState.init(fakeWall);
        self.sink = automation.telemetry.InMemoryTelemetrySink.init(gpa);
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
            fn run(c: @This(), a: std.mem.Allocator, ext: *engine.External) error{OutOfMemory}!engine.Outcome {
                return x_routes.handle(a, c.state, ext, c.verb, c.params);
            }
        };
        return self.engine.executeExternal(gpa, method, "x", .{ .route = .{ .telemetry_sink = self.sink.sink() } }, Call{
            .state = &self.state,
            .verb = x_routes.verbFromMethod(method).?,
            .params = params,
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
    const expected_ops = [_][]const u8{ "waitFor", "click", "fill", "type", "query", "query", "click", "waitFor" };
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
    for (h.sink.spans.items) |span| {
        if (std.mem.eql(u8, span.name, "automation.platform.eval")) {
            children += 1;
            try std.testing.expectEqualStrings(root_trace, span.trace_id);
        }
    }
    try std.testing.expectEqual(@as(usize, 9), children); // navigate + 8 evals
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

test "x.login_check reports the composer on the current page" {
    var h: Harness = undefined;
    h.init(&.{.{ .json = "{\"ok\":true,\"value\":{\"elements\":[{\"id\":\"zb-1\",\"tag\":\"div\",\"text\":\"\",\"bbox\":{}}]}}" }});
    defer h.deinit();
    var outcome = try h.call("x.login_check", "{}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqualStrings("{\"loggedIn\":true,\"platform\":\"x\"}", outcome.result);
    try std.testing.expectEqual(@as(usize, 0), h.fake.navigate_calls.items.len);
}
