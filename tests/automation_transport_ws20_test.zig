//! WS2.0 (Windows plan, rev 2.6): where the automation socket lives on each OS.
//! - planSocketPath(.windows, base, nonce) is always `base\zigbrowser\zigbrowser-automation-<hex>.sock`
//!   and fits UnixAddress.max_len, for every nonce; a base too long for that is
//!   error.SocketPathTooLong, never a path the bind would cut (Linux and macOS alike).
//! - socketBaseDir: Windows uses %LOCALAPPDATA% and nothing else (no /tmp, no XDG_RUNTIME_DIR
//!   fallback: a missing LOCALAPPDATA is error.NoLocalAppData); Linux and macOS keep
//!   XDG_RUNTIME_DIR, else /tmp.
//! Outside the gate until the green.
const std = @import("std");
const t = @import("automation_transport");

const has = @hasDecl(t, "socketBaseDir");
const max_len = std.Io.net.UnixAddress.max_len;

test "Windows paths stay under base\\zigbrowser\\ and fit, for every nonce" {
    if (!has) return error.TestNoSocketBaseDir;
    const base = "C:\\Users\\zbtext\\AppData\\Local";
    var prng = std.Random.DefaultPrng.init(0x20);
    var nonces: [1002]u64 = undefined;
    for (&nonces) |*n| n.* = prng.random().int(u64);
    nonces[1000] = 0;
    nonces[1001] = std.math.maxInt(u64);
    for (nonces) |n| {
        const p = try t.planSocketPath(std.testing.allocator, .windows, base, n);
        defer std.testing.allocator.free(p);
        try std.testing.expect(std.mem.startsWith(u8, p, base ++ "\\zigbrowser\\zigbrowser-automation-"));
        try std.testing.expect(std.mem.endsWith(u8, p, ".sock"));
        try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, p[base.len..], "\\"));
        try std.testing.expect(p.len < max_len);
    }
}

test "a base too long for the socket is an error, never a cut path" {
    if (!has) return error.TestNoSocketBaseDir;
    const long = "C:\\Users\\" ++ "x" ** 80 ++ "\\AppData\\Local";
    try std.testing.expectError(error.SocketPathTooLong, t.planSocketPath(std.testing.allocator, .windows, long, 1));
    const long_posix = "/run/user/" ++ "1" ** 90;
    try std.testing.expectError(error.SocketPathTooLong, t.planSocketPath(std.testing.allocator, .linux, long_posix, 1));
}

test "Windows uses %LOCALAPPDATA% only" {
    if (!has) return error.TestNoSocketBaseDir;
    try std.testing.expectEqualStrings("C:\\Users\\zbtext\\AppData\\Local", try t.socketBaseDir(.windows, "/run/user/1000", "C:\\Users\\zbtext\\AppData\\Local"));
    try std.testing.expectError(error.NoLocalAppData, t.socketBaseDir(.windows, "/run/user/1000", null));
    try std.testing.expectError(error.NoLocalAppData, t.socketBaseDir(.windows, null, null));
    try std.testing.expectError(error.NoLocalAppData, t.socketBaseDir(.windows, null, ""));
}

test "Linux and macOS keep XDG_RUNTIME_DIR, else /tmp" {
    if (!has) return error.TestNoSocketBaseDir;
    for ([_]t.Platform{ .linux, .macos }) |p| {
        try std.testing.expectEqualStrings("/run/user/1000", try t.socketBaseDir(p, "/run/user/1000", "C:\\x"));
        try std.testing.expectEqualStrings("/tmp", try t.socketBaseDir(p, null, null));
    }
}
