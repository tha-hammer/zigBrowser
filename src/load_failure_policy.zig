//! What a failed page load does to the macOS browser (bd zigBrowser-4pa.55, V03-F1; owner decision R30.3 #1,
//! option C). src/wkwebview_shim.m calls these exports back, as it calls nav_policy's zb_policy_decide.
//!
//! Only the primary window's INITIAL load, before its first finish, may end the session (the M9 single-load
//! contract: a browser started on a dead URL exits with ZB_EXIT_LOAD_FAILED, or ZB_EXIT_TIMEOUT when its 15 s
//! timer fires). Every later failure, in any window, and every recovery reload is recorded (a LOAD_FAIL row) and the
//! browser keeps running, as on Linux (webkit_shim.c on_window_load_failed). A routed (automation) navigation's
//! failure is reported to its caller as navigation_failed, as before.
const std = @import("std");

pub const Action = enum(c_int) {
    report_routed = 0,
    record = 1,
    exit = 2,
};

comptime {
    // src/webkit_shim.h ZB_LOADFAIL_* (the shim switches on these).
    std.debug.assert(@intFromEnum(Action.report_routed) == 0);
    std.debug.assert(@intFromEnum(Action.record) == 1);
    std.debug.assert(@intFromEnum(Action.exit) == 2);
}

pub const Load = struct {
    /// A tagged automation navigation (page.navigate / page.reload).
    routed: bool,
    /// The browser's primary window (the one it was started on), not a popup or policy-opened window.
    primary: bool,
    /// The primary window has finished a load at least once.
    primary_finished: bool,
    /// The load is page.recover's reload of a replaced web view.
    recovery: bool,
};

/// Whether this load is still the primary window's initial load, the only one that may end the session.
pub fn exitEligible(load: Load) bool {
    return !load.routed and load.primary and !load.primary_finished and !load.recovery;
}

pub fn onFailure(load: Load) Action {
    if (load.routed) return .report_routed;
    return if (exitEligible(load)) .exit else .record;
}

/// The 15 s exit timer guards only the initial load; any other load has no exit timer.
pub fn exitTimerArmed(load: Load) bool {
    return exitEligible(load);
}

pub export fn zb_load_failure_action(routed: c_int, primary: c_int, primary_finished: c_int, recovery: c_int) c_int {
    return @intFromEnum(onFailure(.{ .routed = routed != 0, .primary = primary != 0, .primary_finished = primary_finished != 0, .recovery = recovery != 0 }));
}

pub export fn zb_load_exit_timer_armed(primary: c_int, primary_finished: c_int, recovery: c_int) c_int {
    return @intFromBool(exitTimerArmed(.{ .routed = false, .primary = primary != 0, .primary_finished = primary_finished != 0, .recovery = recovery != 0 }));
}
