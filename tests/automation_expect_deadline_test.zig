//! S8a red (RoseCat db43ca1 on 804f3f0): phase A's one deadline comes before what the window
//! check found. In order: a command stopped while the check ran is -32012; a check that used up
//! the command's time is the verb's timeout (-32009 for the DOM verbs, -32007 for navigate and
//! reload) with `data.reason` `expect_used_deadline`, whatever the check found; only a check
//! with time left returns its own refusal. In every case nothing reaches the page.
//!
//! Driven through `AutomationApiServer.callInProcess` with the shared fake (expect_fake.zig).

const std = @import("std");
const fake = @import("automation/expect_fake.zig");
const Harness = fake.Harness;
const Reply = fake.Reply;

const testing = std.testing;

const expect_300 = "\"timeout_ms\":300,\"window_id\":\"window-2\",\"options\":{\"expect\":{\"origin\":\"https://shop.example\",\"load_serial\":4}}";

const over_budget = [_]struct { method: []const u8, params: []const u8, code: i64 }{
    .{ .method = "dom.click", .params = "{\"selector\":\"css=#buy\",\"window_id\":\"window-2\",\"options\":{\"timeout_ms\":300,\"expect\":{\"origin\":\"https://shop.example\",\"load_serial\":4}}}", .code = -32009 },
    .{ .method = "page.navigate", .params = "{\"url\":\"https://shop.example/next\"," ++ expect_300 ++ "}", .code = -32007 },
    .{ .method = "page.reload", .params = "{" ++ expect_300 ++ "}", .code = -32007 },
};

const Found = enum { match, load_serial, dialog, crashed };

fn overBudget(found: Found) !void {
    for (over_budget) |case| {
        const h = try Harness.start();
        defer h.deinit();
        h.world.list_delay_ms = 400;
        switch (found) {
            .match => {},
            .load_serial => h.world.load_serials[1].store(5, .release),
            .dialog => h.world.dialog_open[1] = true,
            .crashed => h.world.crashed[1] = true,
        }
        const reply = try h.call(case.method, case.params);
        testing.expectEqual(@as(?i64, case.code), reply.code) catch |e| {
            std.debug.print("{s} ({s}): code {?d}, reason {s}\n", .{ case.method, @tagName(found), reply.code, reply.reason() });
            return e;
        };
        try testing.expectEqualStrings("expect_used_deadline", reply.reason());
        try testing.expectEqual(@as(u32, 0), h.world.ops());
    }
}

test "a check that used up the time is the verb's timeout, expect_used_deadline" {
    try overBudget(.match);
}

test "the deadline comes before what an over-budget check found" {
    try overBudget(.load_serial);
    try overBudget(.dialog);
    try overBudget(.crashed);
}

test "a stop comes before what a held check found" {
    const h = try Harness.start();
    defer h.deinit();
    h.world.load_serials[1].store(5, .release);
    h.world.list_hold.store(true, .release);

    const Call = struct {
        fn run(harness: *Harness, out: *Reply) void {
            out.* = harness.call("dom.click", "{\"selector\":\"css=#buy\",\"window_id\":\"window-2\"," ++ fake.expect_ok ++ "}") catch Reply{ .code = -1 };
        }
    };
    var reply: Reply = .{};
    var thread: ?std.Thread = try std.Thread.spawn(.{}, Call.run, .{ h, &reply });
    defer if (thread) |t| {
        h.world.list_hold.store(false, .release);
        t.join();
    };
    var waited: u32 = 0;
    while (!h.world.list_held.load(.acquire) and waited < 5000) : (waited += 1) testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
    try testing.expect(h.world.list_held.load(.acquire));
    h.server.queue.shutdown();
    h.world.list_hold.store(false, .release);
    thread.?.join();
    thread = null;

    try testing.expectEqual(@as(?i64, -32012), reply.code);
    try testing.expectEqual(@as(u32, 0), h.world.ops());
}

test "with time left, the check's own refusal stands" {
    const h = try Harness.start();
    defer h.deinit();
    h.world.list_delay_ms = 100;
    h.world.load_serials[1].store(5, .release);
    const reply = try h.call("dom.click", "{\"selector\":\"css=#buy\",\"window_id\":\"window-2\",\"options\":{\"timeout_ms\":5000,\"expect\":{\"origin\":\"https://shop.example\",\"load_serial\":4}}}");
    try testing.expectEqual(@as(?i64, -32015), reply.code);
    try testing.expectEqualStrings("load_serial_changed", reply.reason());
    try testing.expectEqual(@as(u32, 0), h.world.ops());
}

test "a stop comes before a held check that also outlived the budget and found a change (RoseCat 4d62b4e)" {
    const h = try Harness.start();
    defer h.deinit();
    h.world.load_serials[1].store(5, .release);
    h.world.list_hold.store(true, .release);

    const Call = struct {
        fn run(harness: *Harness, out: *Reply) void {
            out.* = harness.call("dom.click", "{\"selector\":\"css=#buy\",\"window_id\":\"window-2\",\"options\":{\"timeout_ms\":300,\"expect\":{\"origin\":\"https://shop.example\",\"load_serial\":4}}}") catch Reply{ .code = -1 };
        }
    };
    var reply: Reply = .{};
    var thread: ?std.Thread = try std.Thread.spawn(.{}, Call.run, .{ h, &reply });
    defer if (thread) |t| {
        h.world.list_hold.store(false, .release);
        t.join();
    };
    var waited: u32 = 0;
    while (!h.world.list_held.load(.acquire) and waited < 5000) : (waited += 1) testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
    try testing.expect(h.world.list_held.load(.acquire));
    // Held past the call's whole 300 ms budget, then stopped, then released with a mismatch.
    testing.io.sleep(.fromMilliseconds(400), .awake) catch {};
    h.server.queue.shutdown();
    h.world.list_hold.store(false, .release);
    thread.?.join();
    thread = null;

    try testing.expectEqual(@as(?i64, -32012), reply.code);
    try testing.expectEqualStrings("", reply.reason());
    try testing.expectEqual(@as(u32, 0), h.world.ops());
}
