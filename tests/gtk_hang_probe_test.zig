//! bd zigBrowser-3ui.11 probe (run only by tests/e2e/gtk_test_env_selftest.py, never by `zig build test` itself):
//! GTK starts in-process, then a test never returns. The step's time bound must end it as a named failure; without
//! one the build runner waits forever (Zig 0.16 has no per-test timeout unless `--test-timeout` is given).
const std = @import("std");

extern fn gtk_init_check(argc: ?*c_int, argv: ?*anyopaque) c_int;
extern fn sleep(seconds: c_uint) c_uint;

test "1 GTK starts" {
    try std.testing.expect(gtk_init_check(null, null) != 0);
}

test "2 a test that never returns" {
    // Bounded (one hour) so a probe run outside every time bound still ends; it allocates nothing.
    _ = sleep(3600);
}
