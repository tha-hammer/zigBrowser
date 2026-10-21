//! S8a red (RoseCat 7280 on 52cfb6c): the exact oracles of a guarded dom.type's chunk contract.
//! - Chunk 1 carries neither `chunk_target` nor `chunk_document`; every later chunk carries both.
//! - The deadline stop's exact `sent` and an ambiguous failure's `sent_at_least` are the completed
//!   chunks' events and characters both (48 and 16), never just the characters.
//! - A chunk success whose target or document token is missing, empty or not a string is an
//!   internal error, and nothing more is typed. Its own counts are known, so they join the
//!   completed chunks' as `sent_at_least` (never an exact `sent`); counts that are themselves
//!   unusable add nothing.

const std = @import("std");
const automation = @import("automation");
const fakes = @import("automation/fake_page_port.zig");

const router = automation.router;
const engine = automation.engine;

const testing = std.testing;
const gpa = testing.allocator;

const guard = "{\"marks\":[{\"selector\":\"css=#account\",\"value\":\"alice\"}],\"target\":true}";
const forty = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMN";

const Harness = struct {
    fake: fakes.FakePagePort,
    clock: fakes.FakeClock,
    engine: engine.Engine,

    fn init(self: *Harness) void {
        self.fake = fakes.FakePagePort.init(gpa);
        self.clock = fakes.FakeClock.init(gpa);
        self.engine = engine.Engine.init(self.fake.port(), self.clock.clock());
    }
    fn deinit(self: *Harness) void {
        self.fake.deinit();
        self.clock.deinit();
    }
    fn typeText(self: *Harness, timeout_ms: ?u64) !engine.Outcome {
        var buf: [512]u8 = undefined;
        const p = if (timeout_ms) |t|
            try std.fmt.bufPrint(&buf, "{{\"selector\":\"css=#msg\",\"text\":\"" ++ forty ++ "\",\"options\":{{\"timeout_ms\":{d},\"guard\":{s}}}}}", .{ t, guard })
        else
            "{\"selector\":\"css=#msg\",\"text\":\"" ++ forty ++ "\",\"options\":{\"guard\":" ++ guard ++ "}}";
        var command = try router.parse(gpa, "dom.type", p, .{});
        defer command.deinit();
        return self.engine.executeWith(gpa, &command, .{});
    }
};

/// A chunk success whose `value` ends with `tail` after its counts.
fn reply(comptime events: u64, comptime chars: u64, comptime tail: []const u8) fakes.EvalReply {
    return .{ .json = std.fmt.comptimePrint("{{\"ok\":true,\"value\":{{\"ok\":true,\"sent\":{{\"events\":{d},\"chars\":{d}}}{s}}},\"telemetry\":[]}}", .{ events, chars, tail }) };
}

fn ok(comptime events: u64, comptime chars: u64) fakes.EvalReply {
    return reply(events, chars, ",\"target\":\"t-1\",\"document\":\"d-1\"");
}

const Counts = struct { events: i64, chars: i64 };

/// The failure's `data[key]` counts, or null when the key is absent.
fn countsOf(outcome: engine.Outcome, key: []const u8) !?Counts {
    var data = try std.json.parseFromSlice(std.json.Value, gpa, outcome.failure.data_json orelse "{}", .{});
    defer data.deinit();
    if (data.value != .object) return error.TestExpectedData;
    const counts = data.value.object.get(key) orelse return null;
    return .{ .events = counts.object.get("events").?.integer, .chars = counts.object.get("chars").?.integer };
}

fn expectCounts(outcome: engine.Outcome, key: []const u8, expected: ?Counts) !void {
    const actual = try countsOf(outcome, key);
    testing.expectEqualDeep(expected, actual) catch |e| {
        std.debug.print("{s}: expected {?}, data {s}\n", .{ key, expected, outcome.failure.data_json orelse "null" });
        return e;
    };
}

test "chunk 1 carries neither token; every later chunk carries both" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{ ok(48, 16), ok(48, 16), ok(24, 8) };
    var outcome = try h.typeText(null);
    defer outcome.deinit(gpa);
    try testing.expect(outcome == .result);
    const calls = h.fake.eval_calls.items;
    try testing.expectEqual(@as(usize, 3), calls.len);
    try testing.expect(std.mem.indexOf(u8, calls[0].arg, "chunk_target") == null);
    try testing.expect(std.mem.indexOf(u8, calls[0].arg, "chunk_document") == null);
    for (calls[1..]) |call| {
        try testing.expect(std.mem.indexOf(u8, call.arg, "\"chunk_target\":\"t-1\"") != null);
        try testing.expect(std.mem.indexOf(u8, call.arg, "\"chunk_document\":\"d-1\"") != null);
    }
}

test "the deadline stop's exact sent is the completed chunks' events and characters" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.clock = &h.clock;
    h.fake.eval_cost_ms = 100;
    h.fake.eval_replies = &.{ ok(48, 16), ok(48, 16), ok(24, 8) };
    var outcome = try h.typeText(100);
    defer outcome.deinit(gpa);
    try testing.expect(outcome == .failure);
    try testing.expectEqual(@as(i64, -32009), outcome.failure.code);
    try expectCounts(outcome, "sent", .{ .events = 48, .chars = 16 });
    try expectCounts(outcome, "sent_at_least", null);
    try testing.expectEqual(@as(usize, 1), h.fake.eval_calls.items.len);
}

test "an ambiguous later chunk failure: sent_at_least is the completed chunks' events and characters" {
    const replies = [_]fakes.EvalReply{
        .{ .err = error.Timeout },
        .{ .json = "{\"ok\":false,\"error\":\"script_exception\",\"retryable\":false,\"data\":{\"reason\":\"script_exception\",\"name\":\"TypeError\"}}" },
        .{ .json = "not a script result" },
    };
    for (replies) |second| {
        var h: Harness = undefined;
        h.init();
        defer h.deinit();
        const both = [_]fakes.EvalReply{ ok(48, 16), second };
        h.fake.eval_replies = &both;
        var outcome = try h.typeText(null);
        defer outcome.deinit(gpa);
        try testing.expect(outcome == .failure);
        try expectCounts(outcome, "sent", null);
        try expectCounts(outcome, "sent_at_least", .{ .events = 48, .chars = 16 });
    }
}

test "a chunk 1 success with a bad target or document token: internal error, its own counts only as sent_at_least, no chunk 2" {
    const tails = [_][]const u8{
        ",\"document\":\"d-1\"", // no target
        ",\"target\":\"t-1\"", // no document
        ",\"target\":\"\",\"document\":\"d-1\"",
        ",\"target\":\"t-1\",\"document\":\"\"",
        ",\"target\":7,\"document\":\"d-1\"",
        ",\"target\":\"t-1\",\"document\":null",
    };
    const replies = comptime blk: {
        var out: [tails.len]fakes.EvalReply = undefined;
        for (tails, 0..) |tail, i| out[i] = reply(48, 16, tail);
        break :blk out;
    };
    for (replies, 0..) |first, i| {
        var h: Harness = undefined;
        h.init();
        defer h.deinit();
        const all = [_]fakes.EvalReply{ first, ok(48, 16), ok(24, 8) };
        h.fake.eval_replies = &all;
        var outcome = try h.typeText(null);
        defer outcome.deinit(gpa);
        testing.expect(outcome == .failure) catch |e| {
            std.debug.print("tail {d} ({s}) was accepted\n", .{ i, tails[i] });
            return e;
        };
        try testing.expectEqual(@as(i64, -32603), outcome.failure.code);
        try expectCounts(outcome, "sent", null);
        try expectCounts(outcome, "sent_at_least", .{ .events = 48, .chars = 16 });
        try testing.expectEqual(@as(usize, 1), h.fake.eval_calls.items.len);
    }
}

test "a later chunk success with a bad token: the completed chunks plus its own counts as sent_at_least" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{ ok(48, 16), reply(48, 16, ",\"target\":\"t-1\""), ok(24, 8) };
    var outcome = try h.typeText(null);
    defer outcome.deinit(gpa);
    try testing.expect(outcome == .failure);
    try testing.expectEqual(@as(i64, -32603), outcome.failure.code);
    try expectCounts(outcome, "sent", null);
    try expectCounts(outcome, "sent_at_least", .{ .events = 96, .chars = 32 });
    try testing.expectEqual(@as(usize, 2), h.fake.eval_calls.items.len);
}

test "a chunk success with unusable counts adds nothing: the completed chunks only, as sent_at_least" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{ ok(48, 16), .{ .json = "{\"ok\":true,\"value\":{\"ok\":true,\"sent\":{\"events\":\"x\",\"chars\":16},\"target\":\"t-1\",\"document\":\"d-1\"},\"telemetry\":[]}" } };
    var outcome = try h.typeText(null);
    defer outcome.deinit(gpa);
    try testing.expect(outcome == .failure);
    try testing.expectEqual(@as(i64, -32603), outcome.failure.code);
    try expectCounts(outcome, "sent", null);
    try expectCounts(outcome, "sent_at_least", .{ .events = 48, .chars = 16 });
}

test "a total that would overflow u64 is not saturated: internal error, the completed chunks as sent_at_least (RoseCat 7310)" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{ ok(18446744073709551615, 16), ok(1, 16), ok(24, 8) };
    var outcome = try h.typeText(null);
    defer outcome.deinit(gpa);
    try testing.expect(outcome == .failure);
    try testing.expectEqual(@as(i64, -32603), outcome.failure.code);
    const data = outcome.failure.data_json orelse return error.TestExpectedData;
    testing.expect(std.mem.indexOf(u8, data, "\"sent_at_least\":{\"events\":18446744073709551615,\"chars\":16}") != null) catch |e| {
        std.debug.print("data {s}\n", .{data});
        return e;
    };
    try testing.expect(std.mem.indexOf(u8, data, "\"sent\":") == null);
    try testing.expectEqual(@as(usize, 2), h.fake.eval_calls.items.len);
}
