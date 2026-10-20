//! S7b (chat-drawer plan section 10, S7, rev 16.20.35): a screenshot reaches the model as one
//! image block. `page.screenshot` answers `{data: base64 PNG, width, height}`; the broker
//! decodes `data` and hands the PNG to its fit function (`Broker.fit`, in the GTK app
//! `zb_agent_image_fit`) with the bound `max_b64` (1 MiB - 4096). Its answer becomes
//! `[{"type":"image","mime":<mime>,"data_b64":<b64>}]`; too large is "result too large", and
//! unreadable bytes, `data` that is no base64, or no fit at all are "the screenshot could not
//! be read". A reply without its `data` string is the bad answer; an engine error is redacted.
//! A scripted `Broker.engine` and a scripted fit; `Broker.fit` is reached through @hasField,
//! so this file compiles before the green and fails.
const std = @import("std");
const automation_server = @import("automation_server");
const fake = @import("agent_tools_fake.zig");

const testing = std.testing;
const gpa = testing.allocator;
const broker = automation_server.agent_broker;
const has = @hasField(broker.Broker, "fit");
const max_b64: usize = (1 << 20) - 4096;

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

/// The engine's one reply, and what it was asked.
const Engine = struct {
    reply: []const u8,
    seen: [128]u8 = undefined,
    seen_len: usize = 0,

    fn call(ctx: *anyopaque, a: std.mem.Allocator, method: []const u8, params: []const u8) error{OutOfMemory}![]u8 {
        const self: *Engine = @ptrCast(@alignCast(ctx));
        const line = std.fmt.bufPrint(&self.seen, "{s} {s}", .{ method, params }) catch "";
        self.seen_len = line.len;
        return a.dupe(u8, self.reply);
    }
};

/// The scripted fit: what it was given, and its answer.
var fit_rc: c_int = 0;
var fit_calls: u32 = 0;
var fit_max: usize = 0;
var fit_png: [64]u8 = undefined;
var fit_png_len: usize = 0;
var frees: u32 = 0;
var fit_out: [8:0]u8 = "QUJDRA==".*;

fn scriptedFit(png: [*]const u8, len: usize, max: usize, out_b64: *?[*:0]u8, out_mime: *?[*:0]const u8) callconv(.c) c_int {
    fit_calls += 1;
    fit_max = max;
    fit_png_len = @min(len, fit_png.len);
    @memcpy(fit_png[0..fit_png_len], png[0..fit_png_len]);
    out_b64.* = null;
    out_mime.* = null;
    if (fit_rc == 0) {
        out_b64.* = &fit_out;
        out_mime.* = "image/jpeg";
    }
    return fit_rc;
}

fn scriptedFree(p: ?*anyopaque) callconv(.c) void {
    if (p != null) frees += 1;
}

fn screenshot(reply: []const u8, with_fit: bool, rc: c_int) !struct { Answer, Engine } {
    if (!has) return error.TestNoFitSeam;
    fit_rc, fit_calls, fit_png_len, frees = .{ rc, 0, 0, 0 };
    const f = try fake.Fixture.create("shot", "zb-automation-token-canary-7f3a9c");
    defer f.destroy();
    try f.server.startCore();
    var b = broker.Broker.init(gpa, &f.server, 2, 30_000);
    defer b.deinit();
    var engine: Engine = .{ .reply = reply };
    b.engine = .{ .ctx = &engine, .call = Engine.call };
    if (with_fit) @field(b, "fit") = .{ .fit = scriptedFit, .free = scriptedFree };
    var answer: Answer = .{};
    b.submit("c-1", "mcp__zigbrowser__screenshot", "{}", .{ .ctx = &answer, .done = done });
    const until = fake.nowMs() + 10_000;
    while (answer.n.load(.acquire) == 0) {
        if (fake.nowMs() > until) return error.TestNoAnswer;
        testing.io.sleep(.fromMilliseconds(5), .awake) catch {};
    }
    return .{ answer, engine };
}

fn expectFailure(a: *const Answer, want: []const u8) !void {
    if (a.ok) std.debug.print("unexpected success: {s}\n", .{a.text[0..a.len]});
    try testing.expect(!a.ok);
    try testing.expectEqualStrings(want, a.text[0..a.len]);
}

test "a screenshot is one image block: the decoded PNG goes to the fit with the bound, its answer to the model" {
    const a, const e = try screenshot("{\"result\":{\"data\":\"UE5HQllURVM=\",\"width\":2,\"height\":3}}", true, 0); // "PNGBYTES"
    try testing.expect(a.ok);
    try testing.expectEqualStrings("[{\"type\":\"image\",\"mime\":\"image/jpeg\",\"data_b64\":\"QUJDRA==\"}]", a.text[0..a.len]);
    try testing.expectEqual(@as(u32, 1), fit_calls);
    try testing.expectEqualStrings("PNGBYTES", fit_png[0..fit_png_len]);
    try testing.expectEqual(max_b64, fit_max);
    try testing.expectEqual(@as(u32, 1), frees); // the fit's output is freed with its own free
    try testing.expectEqualStrings("page.screenshot {\"window_id\":\"window-2\"}", e.seen[0..e.seen_len]);
}

test "the fit's too large and unreadable answers are the model's failures" {
    {
        const a, _ = try screenshot("{\"result\":{\"data\":\"UE5HQllURVM=\",\"width\":2,\"height\":3}}", true, 1);
        try expectFailure(&a, "result too large");
    }
    {
        const a, _ = try screenshot("{\"result\":{\"data\":\"UE5HQllURVM=\",\"width\":2,\"height\":3}}", true, 2);
        try expectFailure(&a, "the screenshot could not be read");
    }
    try testing.expectEqual(@as(u32, 0), frees);
}

test "data that is no base64, or no fit at all, is \"the screenshot could not be read\"; the fit is not called" {
    {
        const a, _ = try screenshot("{\"result\":{\"data\":\"not base64 !!\",\"width\":2,\"height\":3}}", true, 0);
        try expectFailure(&a, "the screenshot could not be read");
        try testing.expectEqual(@as(u32, 0), fit_calls);
    }
    {
        const a, _ = try screenshot("{\"result\":{\"data\":\"UE5HQllURVM=\",\"width\":2,\"height\":3}}", false, 0);
        try expectFailure(&a, "the screenshot could not be read");
    }
}

test "a reply without its data string is the bad answer; an engine error is redacted" {
    for ([_][]const u8{
        "{\"result\":{\"width\":2,\"height\":3}}",
        "{\"result\":{\"data\":7}}",
        "{\"result\":\"UE5HQllURVM=\"}",
    }) |reply| {
        const a, _ = try screenshot(reply, true, 0);
        try expectFailure(&a, "the browser sent a bad answer");
        try testing.expectEqual(@as(u32, 0), fit_calls);
    }
    const a, _ = try screenshot("{\"error\":{\"code\":-32013,\"message\":\"dialog open\"}}", true, 0);
    try expectFailure(&a, "the page has a dialog open");
}
