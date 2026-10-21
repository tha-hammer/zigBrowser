//! S8a red (RoseCat 0c1132b #1 on f290168): phase A of `options.expect` shares the command's one
//! absolute deadline and its cancellation. After the window check the engine looks again: a
//! command cancelled while the check ran, or one whose check used up its time, sends nothing to
//! the page; otherwise the action gets only what is left of the deadline, never a fresh one.
//! (Plan, "S8 in detail" decision 1: a phase that runs over starts no later phase.)
//!
//! Driven through `AutomationApiServer.callInProcess` with the shared fake (expect_fake.zig).

const std = @import("std");
const fake = @import("automation/expect_fake.zig");
const Harness = fake.Harness;
const Reply = fake.Reply;

const testing = std.testing;

fn clickParams(buf: []u8, timeout_ms: u64) ![]const u8 {
    return std.fmt.bufPrint(buf, "{{\"selector\":\"css=#buy\",\"window_id\":\"window-2\",\"options\":{{\"timeout_ms\":{d},\"expect\":{{\"origin\":\"https://shop.example\",\"load_serial\":4}}}}}}", .{timeout_ms});
}

test "a command cancelled while its window check is held sends nothing, for every acting verb" {
    for (fake.acting) |verb| {
        const h = try Harness.start();
        defer h.deinit();
        h.world.list_hold.store(true, .release);

        const Call = struct {
            fn run(harness: *Harness, method: []const u8, p: []const u8, out: *Reply) void {
                out.* = harness.call(method, p) catch Reply{ .code = -1 };
            }
        };
        var buf: [512]u8 = undefined;
        const p = try fake.paramsFor(&buf, verb.args, "window-2", fake.expect_ok);
        var reply: Reply = .{};
        var thread: ?std.Thread = try std.Thread.spawn(.{}, Call.run, .{ h, verb.method, p, &reply });
        // On every path: release the hold, then join once.
        defer if (thread) |t| {
            h.world.list_hold.store(false, .release);
            t.join();
        };

        var waited: u32 = 0;
        while (!h.world.list_held.load(.acquire) and waited < 5000) : (waited += 1) testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
        try testing.expect(h.world.list_held.load(.acquire));

        // Stop: the queue cancels its running command (as stop() and page.recover do), while the
        // matching window check is still in flight.
        h.server.queue.shutdown();
        h.world.list_hold.store(false, .release);
        thread.?.join();
        thread = null;

        testing.expectEqual(@as(?i64, -32012), reply.code) catch |e| {
            std.debug.print("{s}: code {?d}\n", .{ verb.method, reply.code });
            return e;
        };
        testing.expectEqual(@as(u32, 0), h.world.ops()) catch |e| {
            std.debug.print("{s}: {d} page operations after the cancel\n", .{ verb.method, h.world.ops() });
            return e;
        };
    }
}

test "a window check that uses up the command's time sends nothing" {
    const h = try Harness.start();
    defer h.deinit();
    h.world.list_delay_ms = 400;
    var buf: [256]u8 = undefined;
    const reply = try h.call("dom.click", try clickParams(&buf, 300));
    try testing.expectEqual(@as(?i64, -32009), reply.code);
    try testing.expectEqual(@as(u32, 0), h.world.ops());
}

test "after a slow window check the action gets only what is left of its deadline" {
    const h = try Harness.start();
    defer h.deinit();
    h.world.list_delay_ms = 400;
    var buf: [256]u8 = undefined;
    const reply = try h.call("dom.click", try clickParams(&buf, 1000));
    try testing.expectEqual(@as(?i64, null), reply.code);
    const page = &h.world.ports[1];
    try testing.expectEqual(@as(u32, 1), page.evals.load(.acquire));
    const given = page.last_timeout_ms.load(.acquire);
    // At most the 600 ms that remain after the 400 ms check, and something.
    testing.expect(given > 0 and given <= 600) catch |e| {
        std.debug.print("the action was given {d} ms\n", .{given});
        return e;
    };
}

test "after a slow window check a navigation gets only what is left of its deadline" {
    const h = try Harness.start();
    defer h.deinit();
    h.world.list_delay_ms = 400;
    const reply = try h.call("page.navigate", "{\"url\":\"https://shop.example/next\",\"timeout_ms\":1000,\"window_id\":\"window-2\",\"options\":{\"expect\":{\"origin\":\"https://shop.example\",\"load_serial\":4}}}");
    try testing.expectEqual(@as(?i64, null), reply.code);
    const page = &h.world.ports[1];
    try testing.expectEqual(@as(u32, 1), page.navigates.load(.acquire));
    const given = page.last_timeout_ms.load(.acquire);
    testing.expect(given > 0 and given <= 600) catch |e| {
        std.debug.print("the navigation was given {d} ms\n", .{given});
        return e;
    };
}
