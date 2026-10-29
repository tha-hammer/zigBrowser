//! S7b (chat-drawer plan section 10, S7, rev 16.20.36; RoseCat 6585, 6606): every reply the
//! broker reads is a genuine engine error (redacted), a well-formed success, or "the browser
//! sent a bad answer". A malformed success never passes through and never becomes an empty
//! title; a window that closes between health and title gives the title's error, never success.
//! window_info takes only the liveness fields from its health entry and calls page.url and
//! page.title with its own window_id (D9).
//! A scripted `Broker.engine` gives each reply. It is reached through @hasField, so this file
//! compiles before the green and fails.
const std = @import("std");
const automation_server = @import("automation_server");
const fake = @import("agent_tools_fake.zig");

const testing = std.testing;
const gpa = testing.allocator;
const broker = automation_server.agent_broker;
const has = @hasField(broker.Broker, "engine");

const bad_answer = "the browser sent a bad answer";
const canary = "foreign_canary";

const Answer = struct { ok: bool = false, text: [4096]u8 = undefined, len: usize = 0, n: std.atomic.Value(u32) = .init(0) };

fn done(ctx: *anyopaque, _: []const u8, result: broker.Result) void {
    const a: *Answer = @ptrCast(@alignCast(ctx));
    const ok, const text = switch (result) {
        .content => |c| .{ true, c },
        .failure => |f| .{ false, f },
    };
    a.ok = ok;
    a.len = @min(text.len, a.text.len);
    @memcpy(a.text[0..a.len], text[0..a.len]);
    _ = a.n.fetchAdd(1, .release);
}

/// The engine's reply for each method, and the params each call was given.
const Script = struct {
    health: []const u8 = good_health,
    url: []const u8 = "{\"result\":{\"url\":\"file:///live/page2.html\"}}",
    title: []const u8 = "{\"result\":{\"title\":\"Live 2\"}}",
    other: []const u8 = "{\"result\":{\"text\":\"a\"}}",
    seen: [4][128]u8 = undefined,
    seen_len: [4]usize = .{ 0, 0, 0, 0 },
    calls: usize = 0,

    fn call(ctx: *anyopaque, a: std.mem.Allocator, method: []const u8, params: []const u8) error{OutOfMemory}![]u8 {
        const self: *Script = @ptrCast(@alignCast(ctx));
        if (self.calls < self.seen.len) {
            const line = std.fmt.bufPrint(&self.seen[self.calls], "{s} {s}", .{ method, params }) catch "";
            self.seen_len[self.calls] = line.len;
        }
        self.calls += 1;
        const reply = if (std.mem.eql(u8, method, "page.health")) self.health else if (std.mem.eql(u8, method, "page.url")) self.url else if (std.mem.eql(u8, method, "page.title")) self.title else self.other;
        return a.dupe(u8, reply);
    }

    fn saw(self: *Script, i: usize) []const u8 {
        return self.seen[i][0..self.seen_len[i]];
    }
};

const good_health = "{\"result\":{\"debounce_ms\":500,\"pages\":[" ++
    "{\"window_id\":\"window-1\",\"url\":\"file:///fixture/page1.html\",\"responsive\":true,\"unresponsive_ms\":0,\"loading\":false,\"dialog_open\":false,\"load_serial\":3}," ++
    "{\"window_id\":\"window-2\",\"url\":\"file:///health-snapshot/page2.html\",\"responsive\":true,\"unresponsive_ms\":0,\"loading\":true,\"dialog_open\":false,\"load_serial\":4}]}}";

fn run(script: *Script, tool: []const u8, args: []const u8) !Answer {
    if (!has) return error.TestNoEngineSeam;
    const f = try fake.Fixture.create("reply", "zb-automation-token-canary-7f3a9c");
    defer f.destroy();
    try f.server.startCore();
    var b = broker.Broker.init(gpa, &f.server, 2, 30_000);
    defer b.deinit();
    @field(b, "engine") = .{ .ctx = script, .call = Script.call };
    var answer: Answer = .{};
    b.submit("c-1", tool, args, .{ .ctx = &answer, .done = done });
    const until = fake.nowMs() + 10_000;
    while (answer.n.load(.acquire) == 0) {
        if (fake.nowMs() > until) return error.TestNoAnswer;
        testing.io.sleep(.fromMilliseconds(5), .awake) catch {};
    }
    testing.io.sleep(.fromMilliseconds(20), .awake) catch {};
    try testing.expectEqual(@as(u32, 1), answer.n.load(.acquire));
    return answer;
}

fn windowInfo(script: *Script) !Answer {
    return run(script, "mcp__zigbrowser__window_info", "{}");
}

fn expectFailure(a: *const Answer, want: []const u8) !void {
    const text = a.text[0..a.len];
    if (a.ok) std.debug.print("unexpected success: {s}\n", .{text});
    try testing.expect(!a.ok);
    try testing.expectEqualStrings(want, text);
}

test "window_info: exactly the liveness fields of its own entry, the URL from page.url and the title from page.title" {
    var script: Script = .{};
    var a = try windowInfo(&script);
    const text = a.text[0..a.len];
    if (!a.ok) std.debug.print("window_info failed: {s}\n", .{text});
    try testing.expect(a.ok);
    var blocks = try std.json.parseFromSlice(std.json.Value, gpa, text, .{});
    defer blocks.deinit();
    try testing.expect(blocks.value == .array and blocks.value.array.items.len == 1);
    const block = blocks.value.array.items[0].object;
    try testing.expectEqual(@as(usize, 2), block.count());
    try testing.expectEqualStrings("text", block.get("type").?.string);
    var info = try std.json.parseFromSlice(std.json.Value, gpa, block.get("text").?.string, .{});
    defer info.deinit();
    const o = info.value.object;
    try testing.expectEqual(@as(usize, 6), o.count());
    try testing.expectEqualStrings("window-2", o.get("window_id").?.string);
    try testing.expectEqualStrings("file:///live/page2.html", o.get("url").?.string);
    try testing.expectEqualStrings("Live 2", o.get("title").?.string);
    try testing.expect(o.get("responsive").? == .bool and o.get("responsive").?.bool);
    try testing.expect(o.get("loading").? == .bool and o.get("loading").?.bool);
    try testing.expect(o.get("dialog_open").? == .bool and !o.get("dialog_open").?.bool);
    try testing.expect(std.mem.indexOf(u8, text, "health-snapshot") == null);
    try testing.expect(std.mem.indexOf(u8, text, "page1") == null);
    try testing.expectEqual(@as(usize, 3), script.calls);
    try testing.expectEqualStrings("page.health {}", script.saw(0));
    try testing.expectEqualStrings("page.url {\"window_id\":\"window-2\"}", script.saw(1));
    try testing.expectEqualStrings("page.title {\"window_id\":\"window-2\"}", script.saw(2));
}

test "window_info: a crashed window's reason is kept, as a string" {
    var script: Script = .{ .health = "{\"result\":{\"pages\":[{\"window_id\":\"window-2\",\"url\":\"x\",\"responsive\":false,\"loading\":false,\"dialog_open\":false,\"crashed\":\"crashed\"}]}}" };
    var a = try windowInfo(&script);
    try testing.expect(a.ok);
    try testing.expect(std.mem.indexOf(u8, a.text[0..a.len], "\\\"crashed\\\":\\\"crashed\\\"") != null);
}

test "a health success without its pages is the bad answer, and its bytes never reach the model" {
    var script: Script = .{ .health = "{\"result\":{\"foreign_canary\":\"window-1/page1\"}}" };
    var a = try windowInfo(&script);
    try expectFailure(&a, bad_answer);
    try testing.expect(std.mem.indexOf(u8, a.text[0..a.len], canary) == null);
    try testing.expectEqual(@as(usize, 1), script.calls);
}

test "a health entry of the wrong shape is the bad answer" {
    for ([_][]const u8{
        "{\"result\":{\"pages\":[{\"window_id\":\"window-2\",\"responsive\":\"yes\",\"loading\":false,\"dialog_open\":false}]}}",
        "{\"result\":{\"pages\":[{\"window_id\":\"window-2\",\"loading\":false,\"dialog_open\":false}]}}",
        "{\"result\":{\"pages\":[{\"window_id\":\"window-2\",\"responsive\":true,\"loading\":false,\"dialog_open\":false,\"crashed\":7}]}}",
        "{\"result\":{\"pages\":{\"window_id\":\"window-2\"}}}",
        "{\"result\":{\"pages\":[]},\"error\":{\"code\":-32000,\"message\":\"failed\"}}",
        "[1,2]",
        "not json",
    }) |health| {
        var script: Script = .{ .health = health };
        var a = try windowInfo(&script);
        try expectFailure(&a, bad_answer);
    }
}

test "a health error is the redacted mapping" {
    var script: Script = .{ .health = "{\"error\":{\"code\":-32010,\"message\":\"window closed\",\"data\":{\"secret\":\"" ++ canary ++ "\"}}}" };
    var a = try windowInfo(&script);
    try expectFailure(&a, "the browser could not do that (window closed, -32010)");
}

test "a page.url or page.title error after a good health is that error, never success" {
    {
        var script: Script = .{ .url = "{\"error\":{\"code\":-32004,\"message\":\"window not found\"}}" };
        var a = try windowInfo(&script);
        try expectFailure(&a, "the browser could not do that (window not found, -32004)");
    }
    {
        var script: Script = .{ .title = "{\"error\":{\"code\":-32004,\"message\":\"window not found\",\"data\":\"" ++ canary ++ "\"}}" };
        var a = try windowInfo(&script);
        try expectFailure(&a, "the browser could not do that (window not found, -32004)");
    }
    {
        var script: Script = .{ .title = "{\"error\":{\"code\":-32013,\"message\":\"dialog open\"}}" };
        var a = try windowInfo(&script);
        try expectFailure(&a, "the page has a dialog open");
    }
}

test "a page.url or page.title success without its string is the bad answer, never an empty one" {
    for ([_][2][]const u8{
        .{ "{\"result\":{\"url\":\"u\"}}", "{\"result\":{}}" },
        .{ "{\"result\":{\"url\":\"u\"}}", "{\"result\":{\"title\":7}}" },
        .{ "{\"result\":{\"url\":\"u\"}}", "{\"result\":\"Live 2\"}" },
        .{ "{\"result\":{\"url\":\"u\"}}", "{\"result\":{\"title\":\"t\"},\"error\":{\"code\":1,\"message\":\"x\"}}" },
        .{ "{\"result\":{\"foreign_canary\":\"u\"}}", "{\"result\":{\"title\":\"t\"}}" },
        .{ "{\"result\":{\"url\":null}}", "{\"result\":{\"title\":\"t\"}}" },
    }) |pair| {
        var script: Script = .{ .url = pair[0], .title = pair[1] };
        var a = try windowInfo(&script);
        try expectFailure(&a, bad_answer);
        try testing.expect(std.mem.indexOf(u8, a.text[0..a.len], canary) == null);
    }
}

test "a single-method tool: any result is its text, an error is redacted, both or neither is the bad answer" {
    {
        var script: Script = .{};
        var a = try run(&script, "mcp__zigbrowser__get_text", "{\"selector\":\"css=#a\"}");
        try testing.expect(a.ok);
        try testing.expectEqualStrings("[{\"type\":\"text\",\"text\":\"{\\\"text\\\":\\\"a\\\"}\"}]", a.text[0..a.len]);
    }
    for ([_][]const u8{
        "{\"result\":{\"text\":\"a\"},\"error\":{\"code\":-32000,\"message\":\"failed\"}}",
        "{\"id\":1}",
        "{\"error\":\"" ++ canary ++ "\"}",
    }) |reply| {
        var script: Script = .{ .other = reply };
        var a = try run(&script, "mcp__zigbrowser__get_text", "{\"selector\":\"css=#a\"}");
        try expectFailure(&a, bad_answer);
    }
}

test "an element error names its sanitized selector, never engine data" {
    var script: Script = .{ .other = "{\"error\":{\"code\":-32001,\"message\":\"element_not_found\",\"data\":{\"reason\":\"strict_zero\",\"page\":\"foreign_canary\"}}}" };
    var a = try run(&script, "mcp__zigbrowser__get_text", "{\"selector\":\"css=.messages button\"}");
    try expectFailure(&a, "no element matched css=.messages button (element_not_found, -32001)");
    try testing.expect(std.mem.indexOf(u8, a.text[0..a.len], canary) == null);

    script = .{ .other = "{\"error\":{\"code\":-32001,\"message\":\"element_not_found\"}}" };
    a = try run(&script, "mcp__zigbrowser__get_text", "{\"selector\":\"css=.messages\\nbutton\"}");
    try expectFailure(&a, "the browser could not do that (element_not_found, -32001)");
}
