//! bd zigBrowser-4pa.55 (V03-F1, CRITICAL; owner decision R30.3 #1, option C): a failed or recovered page load must
//! not quit the macOS browser. The shim (src/wkwebview_shim.m) asks src/load_failure_policy.zig, through the C ABI
//! below, what to do with a load failure and whether to arm the 15 s exit timer; this drives that decision on Linux
//! through the same exports and the constants of src/webkit_shim.h.
//! Rows, as the plan's (R30-MS2 4pa.55): 1-3 a failure after the primary window's first finish (a link to a dead
//! host, a page's own `location=`, a response WebKit does not display) is recorded, never an exit; 4 a recovery
//! reload arms no exit timer and never exits; 5 the primary window's INITIAL load, before its first finish, still
//! exits (the M9 single-load contract; flips if the owner picks option B). A policy-opened window never exits, and a
//! routed (automation) navigation is reported to its caller as before.
//! The macOS call sites are bound by tests/e2e/mac_load_exit_timer_binding_test.py (lexical, hostless); their runtime
//! proof is a released Mac run. tests/e2e/load_failure_policy_mutant_selftest.py makes both proofs reject the old rules.
const std = @import("std");
const policy = @import("load_failure_policy");
const c = @cImport({
    @cInclude("webkit_shim.h");
});

fn action(routed: bool, primary: bool, primary_finished: bool, recovery: bool) c_int {
    return policy.zb_load_failure_action(@intFromBool(routed), @intFromBool(primary), @intFromBool(primary_finished), @intFromBool(recovery));
}

fn timerArmed(primary: bool, primary_finished: bool, recovery: bool) bool {
    return policy.zb_load_exit_timer_armed(@intFromBool(primary), @intFromBool(primary_finished), @intFromBool(recovery)) != 0;
}

test "rows 1-3: after the primary window's first finish, a failed untagged load is recorded, not an exit" {
    try std.testing.expectEqual(@as(c_int, c.ZB_LOADFAIL_RECORD), action(false, true, true, false));
    try std.testing.expect(!timerArmed(true, true, false));
}

test "row 4: a recovery reload arms no exit timer and its failure is recorded, whatever the window's history" {
    for ([_]bool{ false, true }) |primary| for ([_]bool{ false, true }) |finished| {
        try std.testing.expect(!timerArmed(primary, finished, true));
        try std.testing.expectEqual(@as(c_int, c.ZB_LOADFAIL_RECORD), action(false, primary, finished, true));
    };
}

test "row 5: the primary window's initial load, before its first finish, still exits and arms the exit timer" {
    try std.testing.expectEqual(@as(c_int, c.ZB_LOADFAIL_EXIT), action(false, true, false, false));
    try std.testing.expect(timerArmed(true, false, false));
}

test "a policy-opened or popup window never exits and arms no exit timer" {
    for ([_]bool{ false, true }) |finished| {
        try std.testing.expectEqual(@as(c_int, c.ZB_LOADFAIL_RECORD), action(false, false, finished, false));
        try std.testing.expect(!timerArmed(false, finished, false));
    }
}

test "a routed (automation) navigation's failure is reported to its caller in every state" {
    for ([_]bool{ false, true }) |primary| for ([_]bool{ false, true }) |finished| for ([_]bool{ false, true }) |recovery| {
        try std.testing.expectEqual(@as(c_int, c.ZB_LOADFAIL_REPORT_ROUTED), action(true, primary, finished, recovery));
    };
}

test "property: exit iff untagged primary initial non-recovery load, over all 16 states; the timer matches it" {
    var exits: usize = 0;
    for ([_]bool{ false, true }) |routed| for ([_]bool{ false, true }) |primary| for ([_]bool{ false, true }) |finished| for ([_]bool{ false, true }) |recovery| {
        const got = action(routed, primary, finished, recovery);
        const want_exit = !routed and primary and !finished and !recovery;
        try std.testing.expectEqual(want_exit, got == c.ZB_LOADFAIL_EXIT);
        if (want_exit) exits += 1;
        try std.testing.expect(got == c.ZB_LOADFAIL_EXIT or got == c.ZB_LOADFAIL_RECORD or got == c.ZB_LOADFAIL_REPORT_ROUTED);
        if (!routed) try std.testing.expectEqual(want_exit, timerArmed(primary, finished, recovery));
    };
    try std.testing.expectEqual(@as(usize, 1), exits);
}

test "the C ABI reads any nonzero int as true, as the shim's BOOLs and ints pass it" {
    try std.testing.expectEqual(@as(c_int, c.ZB_LOADFAIL_EXIT), policy.zb_load_failure_action(0, 7, 0, 0));
    try std.testing.expectEqual(@as(c_int, c.ZB_LOADFAIL_RECORD), policy.zb_load_failure_action(0, -1, 2, 0));
    try std.testing.expect(policy.zb_load_exit_timer_armed(255, 0, 0) != 0);
}
