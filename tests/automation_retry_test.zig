//! M7: engine retry loop (16 ms poll, deadline mapping) against a fake port
//! and a fake clock.
const std = @import("std");
const automation = @import("automation");
const fakes = @import("automation/fake_page_port.zig");

const router = automation.router;
const engine = automation.engine;
const FakePagePort = fakes.FakePagePort;
const FakeClock = fakes.FakeClock;
const EvalReply = fakes.EvalReply;

const gpa = std.testing.allocator;

const not_found = EvalReply{ .json = "{\"ok\":false,\"error\":\"element_not_found\",\"retryable\":true,\"data\":{\"reason\":\"strict_zero\"}}" };
const obscured = EvalReply{ .json = "{\"ok\":false,\"error\":\"element_obscured\",\"retryable\":true,\"data\":{\"reason\":\"receives-events\"}}" };
const not_visible = EvalReply{ .json = "{\"ok\":false,\"error\":\"element_not_visible\",\"retryable\":true,\"data\":{\"reason\":\"visible\"}}" };
const not_ready = EvalReply{ .json = "{\"ok\":false,\"error\":\"script_not_ready\",\"retryable\":true,\"data\":{\"reason\":\"script_not_ready\"}}" };
const ok = EvalReply{ .json = "{\"ok\":true,\"value\":{\"ok\":true}}" };

const Harness = struct {
    fake: FakePagePort,
    clock: FakeClock,
    engine: engine.Engine,

    fn init(self: *Harness, replies: []const EvalReply) void {
        self.fake = FakePagePort.init(gpa);
        self.clock = FakeClock.init(gpa);
        self.fake.eval_replies = replies;
        self.engine = engine.Engine.init(self.fake.port(), self.clock.clock());
    }

    fn deinit(self: *Harness) void {
        self.fake.deinit();
        self.clock.deinit();
    }

    fn run(self: *Harness, method: []const u8, params: []const u8) !engine.Outcome {
        var command = try router.parse(gpa, method, params, .{});
        defer command.deinit();
        return self.engine.execute(gpa, &command);
    }

    fn evalCount(self: *const Harness) usize {
        return self.fake.eval_calls.items.len;
    }
};

fn dataField(outcome: engine.Outcome, key: []const u8) !?[]u8 {
    const data = outcome.failure.data_json orelse return null;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, data, .{});
    defer parsed.deinit();
    const value = parsed.value.object.get(key) orelse return null;
    return switch (value) {
        .string => |s| try gpa.dupe(u8, s),
        .integer => |i| try std.fmt.allocPrint(gpa, "{d}", .{i}),
        else => null,
    };
}

fn expectData(outcome: engine.Outcome, key: []const u8, expected: []const u8) !void {
    const actual = (try dataField(outcome, key)) orelse return error.TestExpectedDataField;
    defer gpa.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "element_not_found twice then success: three attempts, two 16 ms sleeps" {
    var h: Harness = undefined;
    h.init(&.{ not_found, not_found, ok });
    defer h.deinit();

    var outcome = try h.run("dom.click", "{\"selector\":\"css=#late\"}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqualStrings("{\"ok\":true}", outcome.result);
    try std.testing.expectEqual(@as(usize, 3), h.evalCount());
    try std.testing.expectEqualSlices(u64, &.{ 16, 16 }, h.clock.sleeps.items);
}

test "first-try success never sleeps" {
    var h: Harness = undefined;
    h.init(&.{ok});
    defer h.deinit();

    var outcome = try h.run("dom.click", "{\"selector\":\"css=#b\"}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), h.evalCount());
    try std.testing.expectEqual(@as(usize, 0), h.clock.sleeps.items.len);
}

test "attempt_index increases 0,1,2 and command/trace ids stay constant across retries" {
    var h: Harness = undefined;
    h.init(&.{ not_found, not_found, ok });
    defer h.deinit();

    var outcome = try h.run("dom.click", "{\"selector\":\"css=#late\"}");
    defer outcome.deinit(gpa);
    var first_command: ?[]const u8 = null;
    var first_trace: ?[]const u8 = null;
    var parsed_args: [3]std.json.Parsed(std.json.Value) = undefined;
    for (0..3) |i| parsed_args[i] = try std.json.parseFromSlice(std.json.Value, gpa, h.fake.eval_calls.items[i].arg, .{});
    defer for (&parsed_args) |*p| p.deinit();
    for (parsed_args, 0..) |p, i| {
        const obj = p.value.object;
        try std.testing.expectEqual(@as(i64, @intCast(i)), obj.get("attempt_index").?.integer);
        const command_id = obj.get("command_id").?.string;
        const trace_id = obj.get("trace_id").?.string;
        if (first_command) |c| try std.testing.expectEqualStrings(c, command_id) else first_command = command_id;
        if (first_trace) |t| try std.testing.expectEqualStrings(t, trace_id) else first_trace = trace_id;
    }
}

test "actionability failures until the deadline map to action_timeout; no attempt starts at the deadline" {
    var h: Harness = undefined;
    h.init(&.{ obscured, not_visible });
    defer h.deinit();

    var outcome = try h.run("dom.click", "{\"selector\":\"css=#b\",\"options\":{\"timeout_ms\":50}}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32009), outcome.failure.code);
    try std.testing.expectEqualStrings("action_timeout", outcome.failure.message);
    try expectData(outcome, "last_error", "element_not_visible");
    try expectData(outcome, "reason", "visible");
    // Attempts at t=0,16,32,48; another 16 ms would pass the 50 ms deadline.
    try std.testing.expectEqualSlices(u64, &.{ 16, 16, 16 }, h.clock.sleeps.items);
    try std.testing.expectEqual(@as(usize, 4), h.evalCount());
    try expectData(outcome, "attempts", "4");
    for (h.fake.eval_calls.items) |call| try std.testing.expect(call.timeout_ms <= 50);
}

test "never found until the deadline maps to element_not_found with the script reason" {
    var h: Harness = undefined;
    h.init(&.{not_found});
    defer h.deinit();

    var outcome = try h.run("dom.getText", "{\"selector\":\"css=#missing\",\"options\":{\"timeout_ms\":33}}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32001), outcome.failure.code);
    try expectData(outcome, "reason", "strict_zero");
    try std.testing.expectEqual(@as(usize, 3), h.evalCount());
}

test "script never installed until the deadline maps to element_not_found/script_not_ready" {
    var h: Harness = undefined;
    h.init(&.{not_ready});
    defer h.deinit();

    var outcome = try h.run("dom.click", "{\"selector\":\"css=#b\",\"options\":{\"timeout_ms\":20}}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32001), outcome.failure.code);
    try expectData(outcome, "reason", "script_not_ready");
}

test "script_not_ready then success retries (page still loading)" {
    var h: Harness = undefined;
    h.init(&.{ not_ready, ok });
    defer h.deinit();

    var outcome = try h.run("dom.click", "{\"selector\":\"css=#b\"}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqualStrings("{\"ok\":true}", outcome.result);
    try std.testing.expectEqual(@as(usize, 2), h.evalCount());
}

test "malformed script JSON is not retried" {
    var h: Harness = undefined;
    h.init(&.{.{ .json = "<<garbage" }});
    defer h.deinit();

    var outcome = try h.run("dom.click", "{\"selector\":\"css=#b\"}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32603), outcome.failure.code);
    try std.testing.expectEqual(@as(usize, 1), h.evalCount());
    try std.testing.expectEqual(@as(usize, 0), h.clock.sleeps.items.len);
}

test "malformed selector is not retried even though the script marks it retryable" {
    var h: Harness = undefined;
    h.init(&.{.{ .json = "{\"ok\":false,\"error\":\"element_not_found\",\"retryable\":true,\"data\":{\"reason\":\"malformed_selector\"}}" }});
    defer h.deinit();

    var outcome = try h.run("dom.click", "{\"selector\":\"bogus\"}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32001), outcome.failure.code);
    try expectData(outcome, "reason", "malformed_selector");
    try std.testing.expectEqual(@as(usize, 1), h.evalCount());
}

test "script-flagged non-retryable failure returns immediately" {
    var h: Harness = undefined;
    h.init(&.{.{ .json = "{\"ok\":false,\"error\":\"element_disabled\",\"retryable\":false,\"data\":{\"reason\":\"enabled\"}}" }});
    defer h.deinit();

    var outcome = try h.run("dom.click", "{\"selector\":\"css=#b\"}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32005), outcome.failure.code);
    try std.testing.expectEqual(@as(usize, 1), h.evalCount());
}

test "cancellation during retries returns cancelled without further polls" {
    var h: Harness = undefined;
    h.init(&.{ not_found, .{ .err = error.Cancelled }, ok });
    defer h.deinit();

    var outcome = try h.run("dom.click", "{\"selector\":\"css=#b\"}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32012), outcome.failure.code);
    try std.testing.expectEqual(@as(usize, 2), h.evalCount());
}

test "native timeout of an attempt maps to action_timeout" {
    var h: Harness = undefined;
    h.init(&.{ not_found, .{ .err = error.Timeout } });
    defer h.deinit();

    var outcome = try h.run("dom.click", "{\"selector\":\"css=#b\"}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32009), outcome.failure.code);
}

test "each attempt's native deadline is the remaining command time" {
    var h: Harness = undefined;
    h.init(&.{ not_found, not_found, ok });
    defer h.deinit();
    h.fake.clock = &h.clock;
    h.fake.eval_cost_ms = 4;

    var outcome = try h.run("dom.click", "{\"selector\":\"css=#b\",\"options\":{\"timeout_ms\":1000}}");
    defer outcome.deinit(gpa);
    // attempt 0 at t=0, attempt 1 at t=4+16=20, attempt 2 at t=24+16=40
    try std.testing.expectEqual(@as(u64, 1000), h.fake.eval_calls.items[0].timeout_ms);
    try std.testing.expectEqual(@as(u64, 980), h.fake.eval_calls.items[1].timeout_ms);
    try std.testing.expectEqual(@as(u64, 960), h.fake.eval_calls.items[2].timeout_ms);
}

test "waitFor retries only script_not_ready and passes the remaining time to JS" {
    var h: Harness = undefined;
    h.init(&.{ not_ready, ok });
    defer h.deinit();
    h.fake.clock = &h.clock;
    h.fake.eval_cost_ms = 4;

    var outcome = try h.run("dom.waitFor", "{\"selector\":\"css=#x\",\"timeout_ms\":500}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqualStrings("{\"ok\":true}", outcome.result);
    try std.testing.expect(std.mem.indexOf(u8, h.fake.eval_calls.items[0].arg, "\"timeout_ms\":500") != null);
    try std.testing.expect(std.mem.indexOf(u8, h.fake.eval_calls.items[1].arg, "\"timeout_ms\":480") != null);
    try std.testing.expectEqual(@as(u64, 480 + engine.wait_for_native_grace_ms), h.fake.eval_calls.items[1].timeout_ms);
}

test "waitFor script timeout is final: no retry, element_not_found" {
    var h: Harness = undefined;
    h.init(&.{ .{ .json = "{\"ok\":false,\"error\":\"element_not_found\",\"retryable\":true,\"data\":{\"reason\":\"timeout\"}}" }, ok });
    defer h.deinit();

    var outcome = try h.run("dom.waitFor", "{\"selector\":\"css=#never\",\"timeout_ms\":100}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32001), outcome.failure.code);
    try expectData(outcome, "reason", "timeout");
    try std.testing.expectEqual(@as(usize, 1), h.evalCount());
}

test "dom.type with delay_ms types one character per op with the delay between" {
    var h: Harness = undefined;
    h.init(&.{ok});
    defer h.deinit();

    var outcome = try h.run("dom.type", "{\"selector\":\"css=#q\",\"text\":\"aé€\",\"delay_ms\":40}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqualStrings("{\"ok\":true}", outcome.result);
    try std.testing.expectEqual(@as(usize, 3), h.evalCount());
    try std.testing.expect(std.mem.indexOf(u8, h.fake.eval_calls.items[0].arg, "\"text\":\"a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, h.fake.eval_calls.items[1].arg, "\"text\":\"é\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, h.fake.eval_calls.items[2].arg, "\"text\":\"€\"") != null);
    try std.testing.expectEqualSlices(u64, &.{ 40, 40 }, h.clock.sleeps.items);
}

test "dom.type without delay_ms sends the whole text in one op" {
    var h: Harness = undefined;
    h.init(&.{ok});
    defer h.deinit();

    var outcome = try h.run("dom.type", "{\"selector\":\"css=#q\",\"text\":\"abc\"}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), h.evalCount());
    try std.testing.expect(std.mem.indexOf(u8, h.fake.eval_calls.items[0].arg, "\"text\":\"abc\"") != null);
}

test "dom.type with delay stops at the first failing character" {
    var h: Harness = undefined;
    h.init(&.{ ok, .{ .json = "{\"ok\":false,\"error\":\"element_not_editable\",\"retryable\":false,\"data\":{\"reason\":\"editable\"}}" } });
    defer h.deinit();

    var outcome = try h.run("dom.type", "{\"selector\":\"css=#q\",\"text\":\"abc\",\"delay_ms\":10}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32006), outcome.failure.code);
    try std.testing.expectEqual(@as(usize, 2), h.evalCount());
}

test "a slow attempt that ends past the deadline is not followed by another attempt" {
    var h: Harness = undefined;
    h.init(&.{ not_found, ok });
    defer h.deinit();
    h.fake.clock = &h.clock;
    h.fake.eval_cost_ms = 60;

    var outcome = try h.run("dom.click", "{\"selector\":\"css=#b\",\"options\":{\"timeout_ms\":50}}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32001), outcome.failure.code);
    try std.testing.expectEqual(@as(usize, 1), h.evalCount());
    try std.testing.expectEqual(@as(u64, 50), h.fake.eval_calls.items[0].timeout_ms);
}

test "actionability evidence survives a later not-found before the deadline" {
    var h: Harness = undefined;
    h.init(&.{ obscured, not_found });
    defer h.deinit();

    var outcome = try h.run("dom.click", "{\"selector\":\"css=#b\",\"options\":{\"timeout_ms\":40}}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32009), outcome.failure.code);
    try expectData(outcome, "last_error", "element_obscured");
}

test "delayed typing never sleeps past the deadline, even for u64-max delay_ms" {
    var h: Harness = undefined;
    h.init(&.{ok});
    defer h.deinit();

    var outcome = try h.run("dom.type", "{\"selector\":\"css=#q\",\"text\":\"ab\",\"delay_ms\":18446744073709551615,\"options\":{\"timeout_ms\":1000}}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32009), outcome.failure.code);
    try expectData(outcome, "reason", "type_delay_exceeds_timeout");
    try std.testing.expectEqual(@as(usize, 1), h.evalCount());
    try std.testing.expectEqual(@as(usize, 0), h.clock.sleeps.items.len);
}

test "delayed typing with delay larger than the timeout fails as action_timeout" {
    var h: Harness = undefined;
    h.init(&.{ok});
    defer h.deinit();

    var outcome = try h.run("dom.type", "{\"selector\":\"css=#q\",\"text\":\"ab\",\"delay_ms\":500,\"options\":{\"timeout_ms\":300}}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32009), outcome.failure.code);
}

test "empty text with delay_ms still resolves and checks the element once" {
    var h: Harness = undefined;
    h.init(&.{.{ .json = "{\"ok\":false,\"error\":\"element_not_editable\",\"retryable\":false,\"data\":{\"reason\":\"editable\"}}" }});
    defer h.deinit();

    var outcome = try h.run("dom.type", "{\"selector\":\"css=#q\",\"text\":\"\",\"delay_ms\":10}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32006), outcome.failure.code);
    try std.testing.expectEqual(@as(usize, 1), h.evalCount());
}

test "delayed typing keeps one monotonic attempt_index across characters" {
    var h: Harness = undefined;
    h.init(&.{ not_found, ok, ok });
    defer h.deinit();

    var outcome = try h.run("dom.type", "{\"selector\":\"css=#q\",\"text\":\"ab\",\"delay_ms\":5}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqualStrings("{\"ok\":true}", outcome.result);
    for (h.fake.eval_calls.items, 0..) |call, i| {
        const arg = try std.json.parseFromSlice(std.json.Value, gpa, call.arg, .{});
        defer arg.deinit();
        try std.testing.expectEqual(@as(i64, @intCast(i)), arg.value.object.get("attempt_index").?.integer);
    }
}
