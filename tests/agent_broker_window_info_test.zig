//! S7b (chat-drawer plan section 10, S7, rev 16.20.35; RoseCat 6575): `window_info` is a
//! composite of the broker's own window only. page.health takes no params and answers for
//! every window, so the broker calls it as is, keeps only its window's entry, and adds that
//! window's page.title: the model gets its own window's URL, title and health, and no byte of
//! another window's. A bound window with no health entry is "this window is gone".
const std = @import("std");
const automation_server = @import("automation_server");
const fake = @import("agent_tools_fake.zig");

const testing = std.testing;
const gpa = testing.allocator;
const broker = automation_server.agent_broker;

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

fn windowInfo(window: u32) !Answer {
    const f = try fake.Fixture.create("winfo", "zb-automation-token-canary-7f3a9c");
    defer f.destroy();
    try f.server.startCore();
    var b = broker.Broker.init(gpa, &f.server, window, 30_000);
    defer b.deinit();
    var answer: Answer = .{};
    b.submit("c-1", "mcp__zigbrowser__window_info", "{}", .{ .ctx = &answer, .done = done });
    const until = fake.nowMs() + 10_000;
    while (answer.n.load(.acquire) == 0) {
        if (fake.nowMs() > until) return error.TestNoAnswer;
        testing.io.sleep(.fromMilliseconds(5), .awake) catch {};
    }
    return answer;
}

test "window_info answers its own window's URL, title and health, and nothing of another window" {
    var a = try windowInfo(2);
    const text = a.text[0..a.len];
    if (!a.ok) std.debug.print("window_info failed: {s}\n", .{text});
    try testing.expect(a.ok);
    try testing.expect(std.mem.indexOf(u8, text, "file:///fixture/page2.html") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Page 2") != null);
    try testing.expect(std.mem.indexOf(u8, text, "responsive") != null);
    try testing.expect(std.mem.indexOf(u8, text, "page1.html") == null);
    try testing.expect(std.mem.indexOf(u8, text, "Page 1") == null);
    try testing.expect(std.mem.indexOf(u8, text, "window-1") == null);
}

test "a bound window with no health entry is \"this window is gone\"" {
    var a = try windowInfo(3);
    try testing.expect(!a.ok);
    try testing.expectEqualStrings("this window is gone", a.text[0..a.len]);
}
