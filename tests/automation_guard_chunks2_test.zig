//! S8a red (RoseCat on 76cb14a): the chunks of a guarded dom.type are one action.
//! - Chunk 1 returns the isolated world's token of its target element and of its document, and
//!   every later chunk carries both, so automation.js types only into that same element of that
//!   same document (a same-selector clone, or another document, stops it).
//! - No chunk after the first starts at or after the command's deadline: -32009
//!   `type_chunk_deadline`, with the exact counts of the chunks that ran.
//! - The completed chunks are an exact `sent` only when the failing chunk is known to have sent
//!   nothing more, or reports its own counts (a guard stop); after an ambiguous failure (the page
//!   call failed or the script threw once it may have acted) they are only `sent_at_least`.
//! - A guard refuses `delay_ms` whenever it is present, 0 included.
//! - Chunks are not retries: a three-chunk type with no retry reports retry.count 0.

const std = @import("std");
const automation = @import("automation");
const fakes = @import("automation/fake_page_port.zig");

const router = automation.router;
const engine = automation.engine;
const telemetry = automation.telemetry;

const testing = std.testing;
const gpa = testing.allocator;

const guard = "{\"marks\":[{\"selector\":\"css=#account\",\"value\":\"alice\"}],\"target\":true}";
const forty = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMN";

const Harness = struct {
    fake: fakes.FakePagePort,
    clock: fakes.FakeClock,
    engine: engine.Engine,
    sink: telemetry.InMemoryTelemetrySink,

    fn init(self: *Harness) void {
        self.fake = fakes.FakePagePort.init(gpa);
        self.clock = fakes.FakeClock.init(gpa);
        self.engine = engine.Engine.init(self.fake.port(), self.clock.clock());
        self.sink = telemetry.InMemoryTelemetrySink.init(gpa);
    }
    fn deinit(self: *Harness) void {
        self.sink.deinit();
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
        return self.engine.executeWith(gpa, &command, .{ .route = .{ .telemetry_sink = self.sink.sink() } });
    }
};

fn ok(comptime events: u64, comptime chars: u64, comptime target: []const u8, comptime document: []const u8) fakes.EvalReply {
    return .{ .json = std.fmt.comptimePrint("{{\"ok\":true,\"value\":{{\"ok\":true,\"sent\":{{\"events\":{d},\"chars\":{d}}},\"target\":\"{s}\",\"document\":\"{s}\"}},\"telemetry\":[]}}", .{ events, chars, target, document }) };
}

fn dataOf(outcome: engine.Outcome) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, gpa, outcome.failure.data_json orelse "{}", .{});
}

test "later chunks carry chunk 1's target and document tokens; chunk 1 carries none" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{ ok(48, 16, "t-1", "d-1"), ok(48, 16, "t-1", "d-1"), ok(24, 8, "t-1", "d-1") };
    var outcome = try h.typeText(null);
    defer outcome.deinit(gpa);
    try testing.expect(outcome == .result);
    const calls = h.fake.eval_calls.items;
    try testing.expectEqual(@as(usize, 3), calls.len);
    try testing.expect(std.mem.indexOf(u8, calls[0].arg, "chunk_target") == null);
    for (calls[1..]) |call| {
        try testing.expect(std.mem.indexOf(u8, call.arg, "\"chunk_target\":\"t-1\"") != null);
        try testing.expect(std.mem.indexOf(u8, call.arg, "\"chunk_document\":\"d-1\"") != null);
    }
}

test "no chunk starts at or after the command deadline: -32009 type_chunk_deadline with the exact counts so far" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.clock = &h.clock;
    h.fake.eval_cost_ms = 100;
    h.fake.eval_replies = &.{ ok(48, 16, "t-1", "d-1"), ok(48, 16, "t-1", "d-1"), ok(24, 8, "t-1", "d-1") };
    var outcome = try h.typeText(100);
    defer outcome.deinit(gpa);
    try testing.expect(outcome == .failure);
    try testing.expectEqual(@as(i64, -32009), outcome.failure.code);
    var data = try dataOf(outcome);
    defer data.deinit();
    const reason = data.value.object.get("reason") orelse {
        std.debug.print("no reason in {s}\n", .{outcome.failure.data_json.?});
        return error.TestExpectedReason;
    };
    try testing.expectEqualStrings("type_chunk_deadline", reason.string);
    const sent = data.value.object.get("sent") orelse return error.TestExpectedExactSent;
    try testing.expectEqual(@as(i64, 16), sent.object.get("chars").?.integer);
    try testing.expectEqual(@as(usize, 1), h.fake.eval_calls.items.len);
}

test "an ambiguous later chunk failure does not claim an exact sent" {
    const replies = [_]fakes.EvalReply{
        .{ .err = error.Timeout },
        .{ .json = "{\"ok\":false,\"error\":\"script_exception\",\"retryable\":false,\"data\":{\"reason\":\"script_exception\",\"name\":\"TypeError\"}}" },
        .{ .json = "not a script result" },
    };
    for (replies) |second| {
        var h: Harness = undefined;
        h.init();
        defer h.deinit();
        const both = [_]fakes.EvalReply{ ok(48, 16, "t-1", "d-1"), second };
        h.fake.eval_replies = &both;
        var outcome = try h.typeText(null);
        defer outcome.deinit(gpa);
        try testing.expect(outcome == .failure);
        var data = try dataOf(outcome);
        defer data.deinit();
        if (data.value == .object) {
            testing.expect(data.value.object.get("sent") == null) catch |e| {
                std.debug.print("an ambiguous failure claimed {s}\n", .{outcome.failure.data_json.?});
                return e;
            };
            const at_least = data.value.object.get("sent_at_least") orelse return error.TestExpectedSentAtLeast;
            try testing.expectEqual(@as(i64, 16), at_least.object.get("chars").?.integer);
        } else return error.TestExpectedData;
    }
}

test "a guard refuses delay_ms whenever it is present, 0 included; absent is fine" {
    try testing.expectError(error.BadArgs, router.parse(gpa, "dom.type", "{\"selector\":\"css=#msg\",\"text\":\"hi\",\"delay_ms\":0,\"options\":{\"guard\":" ++ guard ++ "}}", .{}));
    try testing.expectError(error.BadArgs, router.parse(gpa, "dom.type", "{\"selector\":\"css=#msg\",\"text\":\"hi\",\"delay_ms\":5,\"options\":{\"guard\":" ++ guard ++ "}}", .{}));
    var command = try router.parse(gpa, "dom.type", "{\"selector\":\"css=#msg\",\"text\":\"hi\",\"options\":{\"guard\":" ++ guard ++ "}}", .{});
    command.deinit();
}

test "chunks are not retries: three chunks with no retry report retry.count 0" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{ ok(48, 16, "t-1", "d-1"), ok(48, 16, "t-1", "d-1"), ok(24, 8, "t-1", "d-1") };
    var outcome = try h.typeText(null);
    defer outcome.deinit(gpa);
    try testing.expect(outcome == .result);
    var root: ?*const telemetry.Span = null;
    for (h.sink.spans.items) |*span| {
        if (std.mem.eql(u8, span.name, "automation.command")) root = span;
    }
    const count = root.?.attr("retry.count") orelse return error.TestExpectedRetryCount;
    try testing.expectEqualStrings("0", count);
}
