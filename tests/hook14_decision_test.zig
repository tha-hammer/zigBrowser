//! Hook 14 inert row (4pa.58; SilverRidge 7f8b217, by the hook-16 option B shape of 8721b6d): the title decision of
//! the e2e-only hook ZB_DEBUG_NATIVE_CLOSE_ON_TITLE, probed directly through src/zb_test_hook_gate.h. No AppKit and no
//! window. With the variable set and no --e2e-protocol there is no close title, so no page title closes a window
//! (production); with --e2e-protocol the title is the variable's value (the hook works, so the inert case is not
//! vacuous). Dropping the guard in zb_hook14_native_close_title returns the title without --e2e-protocol and turns
//! this test red. A tripwire pins that the shim reads the hook only through this decision, fed by
//! zb_auto_test_hooks_enabled(). The Mac half is row 5 of tests/e2e/mac_ms2a_hook_inert_test.py (a popup titled with
//! the hook's value stays listed and routable). Registered in `test` (step test-hook14-decision).
const std = @import("std");
const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("zb_test_hook_gate.h");
});
const shim_src = @embedFile("wkwebview_shim_src");

fn setHookEnv(value: ?[*:0]const u8) !void {
    if (value) |v| {
        try std.testing.expectEqual(@as(c_int, 0), c.setenv("ZB_DEBUG_NATIVE_CLOSE_ON_TITLE", v, 1));
    } else {
        try std.testing.expectEqual(@as(c_int, 0), c.unsetenv("ZB_DEBUG_NATIVE_CLOSE_ON_TITLE"));
    }
}

test "ZB_DEBUG_NATIVE_CLOSE_ON_TITLE without --e2e-protocol gives no close title" {
    try setHookEnv("zb-native-close");
    try std.testing.expect(c.zb_hook14_native_close_title(0) == null);
}

test "with --e2e-protocol a non-empty value is the close title" {
    try setHookEnv("zb-native-close");
    const title = c.zb_hook14_native_close_title(1) orelse return error.TestExpectedTitle;
    try std.testing.expectEqualStrings("zb-native-close", std.mem.span(title));
    try setHookEnv("");
    try std.testing.expect(c.zb_hook14_native_close_title(1) == null);
    try setHookEnv(null);
    try std.testing.expect(c.zb_hook14_native_close_title(1) == null);
}

test "the shim reads hook 14 only through zb_hook14_native_close_title(zb_auto_test_hooks_enabled())" {
    // Tripwire only: the behavior is the two tests above; this pins the one production call site and its input.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, shim_src, "zb_hook14_native_close_title("));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, shim_src, "return zb_hook14_native_close_title(zb_auto_test_hooks_enabled());"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, shim_src, "getenv(\"ZB_DEBUG_NATIVE_CLOSE_ON_TITLE\")"));
}
