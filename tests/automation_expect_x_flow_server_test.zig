//! S8a red (decision 2 for the X flows, the production server path): `AutomationApiServer`'s
//! x.* route hands the request's bound window (`window_id`) to the engine, so an approved
//! `x.post` checks and acts on that window only, as the LinkedIn and Instagram flows do
//! (tests/automation_expect_flow_server_test.zig):
//! - an approved post for window-2 navigates window 2 only;
//! - a stale load_serial is -32015 load_serial_changed, nothing navigated;
//! - `expect` without `window_id` is -32602, and one for a window that does not exist is -32011
//!   no_window, nothing run in either case.

const std = @import("std");
const fake = @import("automation/expect_fake.zig");
const Harness = fake.Harness;

const testing = std.testing;

const home = "https://x.com/home";
const compose = "https://x.com/compose/post";

fn approved(comptime window: []const u8, comptime serial: []const u8) []const u8 {
    return "{\"text\":\"Hello\",\"compose_url\":\"" ++ compose ++ "\"" ++ window ++ ",\"options\":{\"expect\":{\"origin\":\"https://x.com\",\"load_serial\":" ++ serial ++ ",\"url\":\"" ++ compose ++ "\"}}}";
}

fn start() !*Harness {
    const h = try Harness.start();
    errdefer h.deinit();
    h.world.urls[1] = home;
    return h;
}

test "an approved x.post for a named window passes its phases on that window and acts on it only" {
    const h = try start();
    defer h.deinit();
    const reply = try h.call("x.post", approved(",\"window_id\":\"window-2\"", "4"));
    // This fake answers every page query with a bare {ok:true}, so the post's own button search
    // ends the flow later (the flow itself is tests/automation_expect_x_flow_test.zig); what this
    // pins is that no phase refused it and that it ran on window 2 only.
    for ([_]i64{ -32602, -32011, -32015 }) |refused| testing.expect(reply.code != refused) catch |e| {
        std.debug.print("code {?d}, reason {s}\n", .{ reply.code, reply.reason() });
        return e;
    };
    try testing.expectEqual(@as(u32, 1), h.world.ports[1].navigates.load(.acquire));
    try testing.expectEqual(@as(u32, 0), h.world.ports[0].ops());
}

test "an approved x.post with a stale load_serial is load_serial_changed, nothing navigated" {
    const h = try start();
    defer h.deinit();
    const reply = try h.call("x.post", approved(",\"window_id\":\"window-2\"", "3"));
    testing.expectEqual(@as(?i64, -32015), reply.code) catch |e| {
        std.debug.print("code {?d}, reason {s}\n", .{ reply.code, reply.reason() });
        return e;
    };
    try testing.expectEqualStrings("load_serial_changed", reply.reason());
    try testing.expectEqual(@as(u32, 0), h.world.ports[1].navigates.load(.acquire));
}

test "an x approval without window_id is -32602, and one for a window that does not exist is no_window" {
    const h = try start();
    defer h.deinit();
    const unbound = try h.call("x.post", approved("", "4"));
    try testing.expectEqual(@as(?i64, -32602), unbound.code);
    const gone = try h.call("x.post", approved(",\"window_id\":\"window-9\"", "4"));
    testing.expectEqual(@as(?i64, -32011), gone.code) catch |e| {
        std.debug.print("code {?d}, reason {s}\n", .{ gone.code, gone.reason() });
        return e;
    };
    try testing.expectEqualStrings("no_window", gone.reason());
    try testing.expectEqual(@as(u32, 0), h.world.ops());
}
