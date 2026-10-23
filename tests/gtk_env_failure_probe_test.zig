//! bd zigBrowser-3ui.11 probe (run only by tests/e2e/gtk_test_env_selftest.py, never by `zig build test` itself):
//! GTK starts in-process, then a test fails on purpose.
//!
//! With a display, gdk's startup removes DESKTOP_STARTUP_ID (and the GIO_LAUNCHED_DESKTOP_FILE pair) when they are
//! inherited. unsetenv shifts libc's environ array in place, so Zig 0.16's startup copy of it gains a null entry; the
//! test runner's first stderr lock then panics in Environ.scan and the panic handler deadlocks on the same environ
//! mutex. The deliberate failure below must therefore be reported, not hang the step.
const std = @import("std");

extern fn gtk_init_check(argc: ?*c_int, argv: ?*anyopaque) c_int;

test "1 GTK starts" {
    try std.testing.expect(gtk_init_check(null, null) != 0);
}

test "2 a deliberate failure after GTK start" {
    return error.DeliberateFailureAfterGtkStart;
}
