//! bd zigBrowser-4pa.63 (plan R30-MS6, R30.2 T5): the Darwin guard selftest's probe. An UNREFERENCED pub fn whose
//! body is a type error on macOS only (the array has 1 element on macOS, 2 elsewhere), so a Darwin guard that really
//! analyses every declaration fails on it, and a Linux build of the same file compiles.
const builtin = @import("builtin");

pub fn darwinOnly() u8 {
    const a: [if (builtin.os.tag == .macos) 1 else 2]u8 = .{ 1, 2 };
    return a[0];
}
