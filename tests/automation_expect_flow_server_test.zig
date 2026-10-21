//! S8a red (RoseCat 7098 #3): an approved flow through the production server path,
//! `AutomationApiServer.callInProcess` -> `handleSocialFlow` (splitWindowTarget, targetPort, the
//! window's FIFO ticket, the bound window handed to the engine) -> social_flow_routes:
//! - a flow for a named window acts on that window only;
//! - phase A runs after the flow's ticket is acquired: a navigation that commits while the flow
//!   waits behind another command on that window is seen (-32015 load_serial_changed, nothing
//!   navigated);
//! - a window being recovered answers -32014 before the ticket, and nothing runs;
//! - `expect` without `window_id` is -32602, and a window that does not exist is -32011
//!   no_window, nothing run in either case.
//!
//! The shared two-window fake (expect_fake.zig): window 2 starts on the LinkedIn feed.

const std = @import("std");
const fake = @import("automation/expect_fake.zig");
const Harness = fake.Harness;
const Reply = fake.Reply;

const testing = std.testing;

const feed = "https://www.linkedin.com/feed/";
const post = "https://www.linkedin.com/feed/update/1/";
const approved = "{\"postUrl\":\"" ++ post ++ "\",\"window_id\":\"window-2\",\"options\":{\"expect\":{\"origin\":\"https://www.linkedin.com\",\"load_serial\":4,\"url\":\"" ++ post ++ "\"}}}";

fn start() !*Harness {
    const h = try Harness.start();
    errdefer h.deinit();
    h.world.urls[1] = feed;
    // No pacing pause in these tests (the pacing itself is covered elsewhere).
    const paced = try h.call("social.set_pacing", "{\"min_delay_ms\":0,\"max_delay_ms\":0}");
    try testing.expectEqual(@as(?i64, null), paced.code);
    return h;
}

test "an approved flow for a named window acts on that window only" {
    const h = try start();
    defer h.deinit();
    const reply = try h.call("linkedin.like", approved);
    testing.expectEqual(@as(?i64, null), reply.code) catch |e| {
        std.debug.print("code {?d}, reason {s}\n", .{ reply.code, reply.reason() });
        return e;
    };
    try testing.expectEqual(@as(u32, 1), h.world.ports[1].navigates.load(.acquire));
    try testing.expect(h.world.ports[1].evals.load(.acquire) >= 1);
    try testing.expectEqual(@as(u32, 0), h.world.ports[0].ops());
}

test "phase A runs after the flow's ticket: a navigation while it waits in line is seen" {
    const h = try start();
    defer h.deinit();
    const second = &h.world.ports[1];
    second.hold.store(true, .release);
    var threads = Threads{ .hold = &second.hold };
    defer threads.joinAll();

    var first_reply: Reply = .{};
    threads.list[0] = try std.Thread.spawn(.{}, Call.run, .{ h, "dom.click", "{\"selector\":\"css=#a\",\"window_id\":\"window-2\"}", &first_reply });
    try testing.expect(waitUntil(Held{ .page = second }, 5000));

    var flow_reply: Reply = .{};
    threads.list[1] = try std.Thread.spawn(.{}, Call.run, .{ h, "linkedin.like", approved, &flow_reply });
    try testing.expect(waitUntil(Pending{ .harness = h, .page_id = "page-2" }, 5000));

    // A navigation commits while the approved flow waits; then the first command ends.
    _ = h.world.load_serials[1].fetchAdd(1, .acq_rel);
    threads.joinAll();

    try testing.expectEqual(@as(?i64, null), first_reply.code);
    testing.expectEqual(@as(?i64, -32015), flow_reply.code) catch |e| {
        std.debug.print("code {?d}, reason {s}\n", .{ flow_reply.code, flow_reply.reason() });
        return e;
    };
    try testing.expectEqualStrings("load_serial_changed", flow_reply.reason());
    try testing.expectEqual(@as(u32, 0), second.navigates.load(.acquire));
    try testing.expectEqual(@as(u32, 1), second.evals.load(.acquire));
}

test "a window being recovered answers -32014 before the flow's ticket, and nothing runs" {
    const h = try start();
    defer h.deinit();
    try h.server.queue.beginRecovery(&.{"page-2"});
    defer h.server.queue.endRecovery(&.{"page-2"});
    const reply = try h.call("linkedin.like", approved);
    try testing.expectEqual(@as(?i64, -32014), reply.code);
    try testing.expectEqual(@as(u32, 0), h.world.ops());
}

test "an approval without window_id is -32602, and one for a window that does not exist is no_window" {
    const h = try start();
    defer h.deinit();
    const unbound = try h.call("linkedin.like", "{\"postUrl\":\"" ++ post ++ "\",\"options\":{\"expect\":{\"origin\":\"https://www.linkedin.com\",\"load_serial\":4,\"url\":\"" ++ post ++ "\"}}}");
    try testing.expectEqual(@as(?i64, -32602), unbound.code);
    const gone = try h.call("linkedin.like", "{\"postUrl\":\"" ++ post ++ "\",\"window_id\":\"window-9\",\"options\":{\"expect\":{\"origin\":\"https://www.linkedin.com\",\"load_serial\":4,\"url\":\"" ++ post ++ "\"}}}");
    testing.expectEqual(@as(?i64, -32011), gone.code) catch |e| {
        std.debug.print("code {?d}, reason {s}\n", .{ gone.code, gone.reason() });
        return e;
    };
    try testing.expectEqualStrings("no_window", gone.reason());
    try testing.expectEqual(@as(u32, 0), h.world.ops());
}

const Call = struct {
    fn run(harness: *Harness, method: []const u8, p: []const u8, out: *Reply) void {
        out.* = harness.call(method, p) catch Reply{ .code = -1 };
    }
};

/// Clears the hold, then joins each started thread once, on every path.
const Threads = struct {
    hold: *std.atomic.Value(bool),
    list: [2]?std.Thread = .{ null, null },

    fn joinAll(self: *Threads) void {
        self.hold.store(false, .release);
        for (&self.list) |*slot| if (slot.*) |thread| {
            thread.join();
            slot.* = null;
        };
    }
};

const Held = struct {
    page: *const fake.Page,
    fn done(self: Held) bool {
        return self.page.held.load(.acquire);
    }
};

const Pending = struct {
    harness: *Harness,
    page_id: []const u8,
    fn done(self: Pending) bool {
        return self.harness.server.queue.pendingCount(self.page_id) == 1;
    }
};

fn waitUntil(condition: anytype, max_ms: u32) bool {
    var waited: u32 = 0;
    while (!condition.done()) : (waited += 1) {
        if (waited >= max_ms) return false;
        testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    return true;
}
