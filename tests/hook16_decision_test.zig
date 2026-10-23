//! Hook 16 inert row (SilverRidge 8721b6d, option B): the data-store selection decision of the e2e-only hook
//! ZB_DEBUG_EPHEMERAL_DATA_STORE, probed directly through src/zb_test_hook_gate.h. No AppKit, no window and no WebKit
//! store is created, so nothing is written anywhere. With the variable set to 1 and no --e2e-protocol the decision is
//! the persistent store (production); with --e2e-protocol it is the ephemeral store (the hook works, so the inert
//! case is not vacuous). Dropping the guard in zb_hook16_select_store selects ephemeral without --e2e-protocol and
//! turns this test red. A tripwire pins that the shim selects the store only through this decision, fed by
//! zb_auto_test_hooks_enabled(). Registered in `test` (step test-hook16-decision).
const std = @import("std");
const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("zb_test_hook_gate.h");
});
const shim_src = @embedFile("wkwebview_shim_src");

fn setHookEnv(value: ?[*:0]const u8) !void {
    if (value) |v| {
        try std.testing.expectEqual(@as(c_int, 0), c.setenv("ZB_DEBUG_EPHEMERAL_DATA_STORE", v, 1));
    } else {
        try std.testing.expectEqual(@as(c_int, 0), c.unsetenv("ZB_DEBUG_EPHEMERAL_DATA_STORE"));
    }
}

test "ZB_DEBUG_EPHEMERAL_DATA_STORE=1 without --e2e-protocol selects the persistent store" {
    try setHookEnv("1");
    try std.testing.expectEqual(@as(c_int, c.ZB_STORE_PERSISTENT), c.zb_hook16_select_store(0));
}

test "with --e2e-protocol only the value 1 selects the ephemeral store" {
    try setHookEnv("1");
    try std.testing.expectEqual(@as(c_int, c.ZB_STORE_EPHEMERAL), c.zb_hook16_select_store(1));
    try setHookEnv("0");
    try std.testing.expectEqual(@as(c_int, c.ZB_STORE_PERSISTENT), c.zb_hook16_select_store(1));
    try setHookEnv(null);
    try std.testing.expectEqual(@as(c_int, c.ZB_STORE_PERSISTENT), c.zb_hook16_select_store(1));
}

test "the shim selects the store only through zb_hook16_select_store(zb_auto_test_hooks_enabled())" {
    // Tripwire only: the behavior is the two tests above; this pins the one production call site and its input.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, shim_src, "#include \"zb_test_hook_gate.h\""));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, shim_src, "zb_hook16_select_store("));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, shim_src, "return zb_hook16_select_store(zb_auto_test_hooks_enabled()) == ZB_STORE_EPHEMERAL;"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, shim_src, "getenv(\"ZB_DEBUG_EPHEMERAL_DATA_STORE\")"));
}
