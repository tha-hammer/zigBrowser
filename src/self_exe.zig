//! The running binary's real path (macOS plan rev 14 item 2): Linux readlink("/proc/self/exe"); macOS
//! _NSGetExecutablePath, then realpath (it may name a symlink or a relative path). The runtime is found
//! beside the binary from it (agent_setup.runtimeFor).
const std = @import("std");
const builtin = @import("builtin");

extern "c" fn _NSGetExecutablePath(buf: [*]u8, bufsize: *u32) c_int;

pub const Error = error{SelfExePathUnavailable};

pub fn path(buf: *[std.fs.max_path_bytes]u8) Error![]const u8 {
    switch (comptime builtin.os.tag) {
        .linux => {
            const n = std.c.readlink("/proc/self/exe", buf, buf.len);
            if (n <= 0) return error.SelfExePathUnavailable;
            return buf[0..@intCast(n)];
        },
        .macos => {
            var raw: [std.fs.max_path_bytes:0]u8 = undefined;
            var size: u32 = raw.len;
            if (_NSGetExecutablePath(&raw, &size) != 0) return error.SelfExePathUnavailable;
            const resolved = std.c.realpath(@ptrCast(&raw), buf) orelse return error.SelfExePathUnavailable;
            return std.mem.span(resolved);
        },
        else => return error.SelfExePathUnavailable,
    }
}
