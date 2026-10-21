//! S8a red (chat-drawer plan, "S8 in detail" decision 15): under `options.guard`, dom.type runs
//! in chunks of at most 16 Unicode code points, split at code-point boundaries (never bytes or
//! UTF-16 units), each its own automation.js evaluation; the command's cancellation is checked
//! before every chunk; and one cumulative `data.sent` covers the chunks that completed plus the
//! one that stopped (automation.js reports each chunk's own counts, on success too).
//! Without a guard, dom.type stays one evaluation.

const std = @import("std");
const automation = @import("automation");
const fakes = @import("automation/fake_page_port.zig");

const router = automation.router;
const engine = automation.engine;
const page_port = automation.page_port;

const testing = std.testing;
const gpa = testing.allocator;

const guard = "{\"marks\":[{\"selector\":\"css=#account\",\"value\":\"alice\"}],\"target\":true}";

/// The shared fake, plus a stop that arrives once `cancel_after` evaluations have answered.
const Port = struct {
    inner: fakes.FakePagePort,
    cancel: std.atomic.Value(bool) = .init(false),
    cancel_after: ?usize = null,

    fn port(self: *Port) page_port.PagePort {
        return .{ .ptr = self, .vtable = &vtable };
    }
    fn from(ptr: *anyopaque) *Port {
        return @ptrCast(@alignCast(ptr));
    }
    const vtable = page_port.PagePort.VTable{ .evalJson = evalJson, .navigate = navigate, .reload = reload, .url = url, .title = title };
    fn innerPort(self: *Port) page_port.PagePort {
        return self.inner.port();
    }
    fn evalJson(ptr: *anyopaque, a: std.mem.Allocator, world: page_port.World, body: []const u8, arg: []const u8, timeout_ms: u64) page_port.PortError![]u8 {
        const self = from(ptr);
        const p = self.innerPort();
        const answer = try p.vtable.evalJson(p.ptr, a, world, body, arg, timeout_ms);
        if (self.cancel_after) |n| if (self.inner.eval_calls.items.len == n) self.cancel.store(true, .release);
        return answer;
    }
    fn navigate(ptr: *anyopaque, u: []const u8, t: u64) page_port.PortError!void {
        const p = from(ptr).innerPort();
        return p.vtable.navigate(p.ptr, u, t);
    }
    fn reload(ptr: *anyopaque, t: u64) page_port.PortError!void {
        const p = from(ptr).innerPort();
        return p.vtable.reload(p.ptr, t);
    }
    fn url(ptr: *anyopaque, a: std.mem.Allocator, t: u64) page_port.PortError![]u8 {
        const p = from(ptr).innerPort();
        return p.vtable.url(p.ptr, a, t);
    }
    fn title(ptr: *anyopaque, a: std.mem.Allocator, t: u64) page_port.PortError![]u8 {
        const p = from(ptr).innerPort();
        return p.vtable.title(p.ptr, a, t);
    }
};

const Harness = struct {
    port: Port,
    clock: fakes.FakeClock,
    engine: engine.Engine,

    fn init(self: *Harness) void {
        self.port = .{ .inner = fakes.FakePagePort.init(gpa) };
        self.clock = fakes.FakeClock.init(gpa);
        self.engine = engine.Engine.init(self.port.port(), self.clock.clock());
    }
    fn deinit(self: *Harness) void {
        self.port.inner.deinit();
        self.clock.deinit();
    }
    fn typeText(self: *Harness, text: []const u8, with_guard: bool) !engine.Outcome {
        var buf: [2048]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        try w.writeAll("{\"selector\":\"css=#msg\",\"text\":");
        try std.json.Stringify.value(text, .{}, &w);
        if (with_guard) try w.writeAll(",\"options\":{\"guard\":" ++ guard ++ "}");
        try w.writeAll("}");
        var command = try router.parse(gpa, "dom.type", w.buffered(), .{});
        defer command.deinit();
        return self.engine.executeWith(gpa, &command, .{ .cancel = &self.port.cancel });
    }
    /// The `text` of each evaluation's command, in order.
    fn chunkTexts(self: *Harness, out: [][]const u8, arena: std.mem.Allocator) ![][]const u8 {
        var n: usize = 0;
        for (self.port.inner.eval_calls.items) |call| {
            const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, call.arg, .{});
            const text = parsed.object.get("text") orelse continue;
            out[n] = text.string;
            n += 1;
        }
        return out[0..n];
    }
};

fn ok(comptime events: u64, comptime chars: u64) fakes.EvalReply {
    return .{ .json = std.fmt.comptimePrint("{{\"ok\":true,\"value\":{{\"ok\":true,\"sent\":{{\"events\":{d},\"chars\":{d}}}}},\"telemetry\":[]}}", .{ events, chars }) };
}

fn sentOf(outcome: engine.Outcome) !struct { events: i64, chars: i64 } {
    var data = try std.json.parseFromSlice(std.json.Value, gpa, outcome.failure.data_json.?, .{});
    defer data.deinit();
    const sent = data.value.object.get("sent") orelse {
        std.debug.print("no sent in {s}\n", .{outcome.failure.data_json.?});
        return error.TestExpectedSent;
    };
    return .{ .events = sent.object.get("events").?.integer, .chars = sent.object.get("chars").?.integer };
}

test "a guarded dom.type of 40 code points is three evaluations of 16, 16 and 8" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.port.inner.eval_replies = &.{ ok(48, 16), ok(48, 16), ok(24, 8) };
    const text = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMN";
    var outcome = try h.typeText(text, true);
    defer outcome.deinit(gpa);
    try testing.expect(outcome == .result);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var buf: [8][]const u8 = undefined;
    const chunks = try h.chunkTexts(&buf, arena.allocator());
    try testing.expectEqual(@as(usize, 3), chunks.len);
    try testing.expectEqualStrings(text[0..16], chunks[0]);
    try testing.expectEqualStrings(text[16..32], chunks[1]);
    try testing.expectEqualStrings(text[32..], chunks[2]);
    // Every chunk carries the guard.
    for (h.port.inner.eval_calls.items) |call| try testing.expect(std.mem.indexOf(u8, call.arg, "\"guard\"") != null);
}

test "chunks split at code points: a non-BMP and a two-byte character at the 16/17 boundary, and one at 32" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.port.inner.eval_replies = &.{ ok(48, 16), ok(48, 16), ok(6, 2) };
    // 15 ASCII, then U+1F600 (16th), U+00E9 (17th), 14 ASCII, U+4E2D (32nd), "z" "!" (33rd, 34th).
    const text = "aaaaaaaaaaaaaaa\u{1F600}\u{00E9}bbbbbbbbbbbbbb\u{4E2D}z!";
    var outcome = try h.typeText(text, true);
    defer outcome.deinit(gpa);
    try testing.expect(outcome == .result);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var buf: [8][]const u8 = undefined;
    const chunks = try h.chunkTexts(&buf, arena.allocator());
    try testing.expectEqual(@as(usize, 3), chunks.len);
    try testing.expectEqualStrings("aaaaaaaaaaaaaaa\u{1F600}", chunks[0]);
    try testing.expectEqualStrings("\u{00E9}bbbbbbbbbbbbbb\u{4E2D}", chunks[1]);
    try testing.expectEqualStrings("z!", chunks[2]);
    for (chunks) |chunk| {
        try testing.expect(std.unicode.utf8ValidateSlice(chunk));
        try testing.expect((try std.unicode.utf8CountCodepoints(chunk)) <= 16);
    }
}

test "one cumulative data.sent: chunk 1 done, chunk 2 stopped after 3 characters, no chunk 3" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.port.inner.eval_replies = &.{ ok(48, 16), .{ .json = "{\"ok\":false,\"error\":\"expectation_mismatch\",\"retryable\":false,\"data\":{\"reason\":\"mark_changed\",\"sent\":{\"events\":8,\"chars\":3}},\"telemetry\":[]}" } };
    var outcome = try h.typeText("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMN", true);
    defer outcome.deinit(gpa);
    try testing.expect(outcome == .failure);
    try testing.expectEqual(@as(i64, -32015), outcome.failure.code);
    const sent = try sentOf(outcome);
    try testing.expectEqual(@as(i64, 56), sent.events);
    try testing.expectEqual(@as(i64, 19), sent.chars);
    try testing.expectEqual(@as(usize, 2), h.port.inner.eval_calls.items.len);
}

test "a stop between chunks: -32012 with what the completed chunks sent, no later chunk" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.port.inner.eval_replies = &.{ ok(48, 16), ok(48, 16), ok(24, 8) };
    h.port.cancel_after = 1;
    var outcome = try h.typeText("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMN", true);
    defer outcome.deinit(gpa);
    try testing.expect(outcome == .failure);
    try testing.expectEqual(@as(i64, -32012), outcome.failure.code);
    const sent = try sentOf(outcome);
    try testing.expectEqual(@as(i64, 48), sent.events);
    try testing.expectEqual(@as(i64, 16), sent.chars);
    try testing.expectEqual(@as(usize, 1), h.port.inner.eval_calls.items.len);
}

test "a later chunk that fails otherwise keeps its error and reports the completed chunks as a lower bound" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.port.inner.eval_replies = &.{ ok(48, 16), .{ .json = "{\"ok\":false,\"error\":\"element_not_editable\",\"retryable\":false,\"data\":{\"reason\":\"readonly\"},\"telemetry\":[]}" } };
    var outcome = try h.typeText("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMN", true);
    defer outcome.deinit(gpa);
    try testing.expect(outcome == .failure);
    try testing.expectEqual(@as(i64, -32006), outcome.failure.code);
    const sent = try sentOf(outcome);
    try testing.expectEqual(@as(i64, 48), sent.events);
    try testing.expectEqual(@as(i64, 16), sent.chars);
    try testing.expectEqual(@as(usize, 2), h.port.inner.eval_calls.items.len);
}

test "without a guard, dom.type is one evaluation of the whole text" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.port.inner.eval_replies = &.{.{ .json = "{\"ok\":true,\"value\":{\"ok\":true},\"telemetry\":[]}" }};
    const text = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMN";
    var outcome = try h.typeText(text, false);
    defer outcome.deinit(gpa);
    try testing.expect(outcome == .result);
    try testing.expectEqual(@as(usize, 1), h.port.inner.eval_calls.items.len);
}

test "a guard with a per-character delay_ms is BadArgs (a guarded type has its own chunk schedule)" {
    try testing.expectError(error.BadArgs, router.parse(gpa, "dom.type", "{\"selector\":\"css=#msg\",\"text\":\"hi\",\"delay_ms\":5,\"options\":{\"guard\":" ++ guard ++ "}}", .{}));
    var command = try router.parse(gpa, "dom.type", "{\"selector\":\"css=#msg\",\"text\":\"hi\",\"delay_ms\":0,\"options\":{\"guard\":" ++ guard ++ "}}", .{});
    command.deinit();
}
