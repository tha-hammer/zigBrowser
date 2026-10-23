//! bd zigBrowser-3ui.12: environ_guard.prime scans every startup-envp snapshot that may run after GTK, so a later
//! unsetenv-style shift of that array is never scanned. Drives a real std.Io.Threaded built as start.zig builds
//! main's init.io (Threaded.init with the envp block), then shifts the block exactly as glibc unsetenv does.
//! The browser-level proof is tests/e2e/gtk_launch_env_product_test.py (same step).
const std = @import("std");
const environ_guard = @import("environ_guard");

fn entry(comptime s: [:0]const u8) ?[*:0]u8 {
    return @constCast(s.ptr);
}

test "prime scans main's Threaded io and std.debug's; a later unsetenv-style shift is never scanned" {
    if (comptime !environ_guard.needed) return error.SkipZigTest;
    var envp = [_:null]?[*:0]u8{ entry("HOME=/zb/home"), entry("DESKTOP_STARTUP_ID=zb-3ui12"), entry("PATH=/zb/bin") };
    var t: std.Io.Threaded = .init(std.testing.allocator, .{ .environ = .{ .block = .{ .slice = envp[0..] } } });
    defer t.deinit();
    try std.testing.expect(environ_guard.threaded(t.io()) == &t);
    try std.testing.expect(!t.environ_initialized);

    environ_guard.prime(t.io());
    try std.testing.expect(t.environ_initialized);
    try std.testing.expect(std.Options.debug_threaded_io.?.environ_initialized);

    // glibc unsetenv("DESKTOP_STARTUP_ID"): later entries move down; the startup-length slice now ends in null.
    envp[1] = envp[2];
    envp[2] = null;
    try std.testing.expectEqualStrings("/zb/home", t.environString("HOME").?);
    try std.testing.expectEqualStrings("/zb/bin", t.environString("PATH").?);
}
