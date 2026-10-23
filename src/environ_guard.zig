//! bd zigBrowser-3ui.12: Zig 0.16 keeps the environment as the startup envp array with its startup length and scans
//! it lazily, once (lib/std/Io/Threaded.zig scanEnviron). C code that unsetenv()s an inherited variable (gdk does,
//! for DESKTOP_STARTUP_ID, in gtk_init) shifts that array in place, so a first scan after it panics on the null slot
//! and the panic handler deadlocks re-entering the scan. Two snapshots alias that array: std.debug's Io (std.debug.print,
//! std.log, the panic handler) and main's init.io. Scanning both before any C code runs makes every later use read
//! the cached values.
const std = @import("std");
const builtin = @import("builtin");

/// Windows reads the PEB under its lock, never the startup array, and WASI copies the environment.
pub const needed = builtin.os.tag != .windows and builtin.os.tag != .wasi;

/// Scans std.debug's environment snapshot and `io`'s (main's init.io) now. Call it first in main, before any C code.
pub fn prime(io: std.Io) void {
    if (comptime !needed) return;
    if (std.Options.debug_threaded_io) |t| _ = t.environString("HOME");
    if (threaded(io)) |t| _ = t.environString("HOME");
}

/// `io`'s std.Io.Threaded, or null for another Io implementation (it scans no startup envp array of this kind).
pub fn threaded(io: std.Io) ?*std.Io.Threaded {
    if (io.vtable != std.Io.Threaded.global_single_threaded.io().vtable) return null;
    return @ptrCast(@alignCast(io.userdata.?));
}
