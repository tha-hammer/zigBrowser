//! S8a red (chat-drawer plan, "S8 in detail" decision 14): `options.guard` on the acting DOM
//! verbs. The router accepts `{marks?: [{selector, attribute?, value}] (1..8), target?: true}`
//! (at least one check) on dom.click, dom.fill, dom.type, dom.press and dom.selectOption, with
//! synthetic input only; the engine hands it to automation.js in the action's own command; a
//! guard stop from the script (`expectation_mismatch`, `data.{reason, sent: {events, chars}}`) is
//! -32015 with that reason and those counts, and is never retried.
//! (The guard itself runs in automation.js: tests/e2e/automation_guard_test.py.)

const std = @import("std");
const automation = @import("automation");
const fakes = @import("automation/fake_page_port.zig");

const router = automation.router;
const engine = automation.engine;

const testing = std.testing;
const gpa = testing.allocator;

const good = "{\"marks\":[{\"selector\":\"css=#account\",\"value\":\"alice\"},{\"selector\":\"css=#recipient\",\"attribute\":\"href\",\"value\":\"/in/carol/\"}],\"target\":true}";

fn params(buf: []u8, method: []const u8, guard_json: []const u8, extra: []const u8) ![]const u8 {
    const base = if (std.mem.eql(u8, method, "dom.fill"))
        "\"selector\":\"css=#q\",\"value\":\"v\""
    else if (std.mem.eql(u8, method, "dom.type"))
        "\"selector\":\"css=#q\",\"text\":\"hi\""
    else if (std.mem.eql(u8, method, "dom.press"))
        "\"selector\":\"css=#q\",\"key\":\"Enter\""
    else if (std.mem.eql(u8, method, "dom.selectOption"))
        "\"selector\":\"css=#s\",\"value\":\"a\""
    else
        "\"selector\":\"css=#buy\"";
    return std.fmt.bufPrint(buf, "{{{s},\"options\":{{\"guard\":{s}{s}}}}}", .{ base, guard_json, extra });
}

test "options.guard parses on the five acting verbs" {
    for ([_][]const u8{ "dom.click", "dom.fill", "dom.type", "dom.press", "dom.selectOption" }) |method| {
        var buf: [512]u8 = undefined;
        var command = router.parse(gpa, method, try params(&buf, method, good, ""), .{}) catch |e| {
            std.debug.print("{s}: {s}\n", .{ method, @errorName(e) });
            return e;
        };
        defer command.deinit();
        const g = command.guard orelse return error.TestExpectedGuard;
        try testing.expectEqual(@as(usize, 2), g.marks.len);
        try testing.expectEqualStrings("css=#account", g.marks[0].selector);
        try testing.expectEqual(@as(?[]const u8, null), g.marks[0].attribute);
        try testing.expectEqualStrings("alice", g.marks[0].value);
        try testing.expectEqualStrings("href", g.marks[1].attribute.?);
        try testing.expect(g.target);
    }
}

test "a malformed or misplaced options.guard is BadArgs" {
    const bad = [_]struct { what: []const u8, method: []const u8 = "dom.click", guard: []const u8, extra: []const u8 = "" }{
        .{ .what = "not an object", .guard = "true" },
        .{ .what = "no check at all", .guard = "{}" },
        .{ .what = "target false alone", .guard = "{\"target\":false}" },
        .{ .what = "marks not an array", .guard = "{\"marks\":{}}" },
        .{ .what = "marks empty", .guard = "{\"marks\":[]}" },
        .{ .what = "nine marks", .guard = "{\"marks\":[" ++ ("{\"selector\":\"css=#a\",\"value\":\"x\"}," ** 8) ++ "{\"selector\":\"css=#a\",\"value\":\"x\"}]}" },
        .{ .what = "a mark without a selector", .guard = "{\"marks\":[{\"value\":\"x\"}]}" },
        .{ .what = "an empty selector", .guard = "{\"marks\":[{\"selector\":\"\",\"value\":\"x\"}]}" },
        .{ .what = "a value not a string", .guard = "{\"marks\":[{\"selector\":\"css=#a\",\"value\":7}]}" },
        .{ .what = "a mark without a value", .guard = "{\"marks\":[{\"selector\":\"css=#a\"}]}" },
        .{ .what = "an empty attribute", .guard = "{\"marks\":[{\"selector\":\"css=#a\",\"attribute\":\"\",\"value\":\"x\"}]}" },
        .{ .what = "an unknown mark key", .guard = "{\"marks\":[{\"selector\":\"css=#a\",\"value\":\"x\",\"regex\":true}]}" },
        .{ .what = "an unknown guard key", .guard = "{\"target\":true,\"approved\":true}" },
        .{ .what = "target not a bool", .guard = "{\"target\":1}" },
        .{ .what = "native input", .guard = good, .extra = ",\"input\":\"native\"" },
        .{ .what = "humanize", .method = "dom.type", .guard = good, .extra = ",\"input\":\"native\",\"humanize\":true" },
        .{ .what = "on getText", .method = "dom.getText", .guard = good },
        .{ .what = "on hover", .method = "dom.hover", .guard = good },
        .{ .what = "on waitFor", .method = "dom.waitFor", .guard = good },
    };
    for (bad) |case| {
        var buf: [1024]u8 = undefined;
        const p = try params(&buf, case.method, case.guard, case.extra);
        if (router.parse(gpa, case.method, p, .{})) |parsed| {
            var command = parsed;
            command.deinit();
            std.debug.print("{s}: accepted\n", .{case.what});
            return error.TestExpectedBadArgs;
        } else |err| {
            try testing.expectEqual(error.BadArgs, err);
        }
    }
}

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

    fn run(self: *Harness, method: []const u8, p: []const u8) !engine.Outcome {
        var command = try router.parse(gpa, method, p, .{});
        defer command.deinit();
        return self.engine.execute(gpa, &command);
    }
};

test "the engine hands the guard to automation.js in the action's own command" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{.{ .json = "{\"ok\":true,\"value\":{\"ok\":true}}" }};
    var buf: [512]u8 = undefined;
    var outcome = try h.run("dom.click", try params(&buf, "dom.click", good, ""));
    defer outcome.deinit(gpa);
    try testing.expect(outcome == .result);
    try testing.expectEqual(@as(usize, 1), h.fake.eval_calls.items.len);
    const arg = h.fake.eval_calls.items[0].arg;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, arg, .{});
    defer parsed.deinit();
    const sent_guard = parsed.value.object.get("guard") orelse return error.TestExpectedGuardInCommand;
    const marks = sent_guard.object.get("marks").?.array.items;
    try testing.expectEqual(@as(usize, 2), marks.len);
    try testing.expectEqualStrings("css=#recipient", marks[1].object.get("selector").?.string);
    try testing.expectEqualStrings("href", marks[1].object.get("attribute").?.string);
    try testing.expectEqualStrings("/in/carol/", marks[1].object.get("value").?.string);
    try testing.expect(sent_guard.object.get("target").?.bool);
}

test "a guard stop is -32015 with its reason and sent counts, and is not retried" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{.{ .json = "{\"ok\":false,\"error\":\"expectation_mismatch\",\"retryable\":false,\"data\":{\"reason\":\"mark_changed\",\"sent\":{\"events\":2,\"chars\":1}},\"telemetry\":[]}" }};
    var buf: [512]u8 = undefined;
    var outcome = try h.run("dom.type", try params(&buf, "dom.type", good, ""));
    defer outcome.deinit(gpa);
    try testing.expect(outcome == .failure);
    try testing.expectEqual(@as(i64, -32015), outcome.failure.code);
    var data = try std.json.parseFromSlice(std.json.Value, gpa, outcome.failure.data_json.?, .{});
    defer data.deinit();
    try testing.expectEqualStrings("mark_changed", data.value.object.get("reason").?.string);
    const sent = data.value.object.get("sent") orelse {
        std.debug.print("data {s}\n", .{outcome.failure.data_json.?});
        return error.TestExpectedSent;
    };
    try testing.expectEqual(@as(i64, 2), sent.object.get("events").?.integer);
    try testing.expectEqual(@as(i64, 1), sent.object.get("chars").?.integer);
    try testing.expectEqual(@as(usize, 1), h.fake.eval_calls.items.len);
}
