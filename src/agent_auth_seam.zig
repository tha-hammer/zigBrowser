//! S6b2's provider seam, ZIGBROWSER_AGENT_AUTH_TEST (chat-drawer plan rev 16.18.1, RoseCat
//! 5911; rev 16.18.15): decided once per sign-in, before the auth window exists.
//! - Unset: nothing.
//! - Set without --e2e-protocol: ignored, whatever its text (it is not parsed).
//! - With it: exactly `proxy=` + proxy + `,ca=` + path, else refused `shape`. The proxy is
//!   exactly `http://127.0.0.1:` + a port of 1-65535 in decimal, with no sign and no leading
//!   zero, else `proxy`. The path is absolute and names a regular file that is not a symbolic
//!   link (one no-follow open, as agent_net.checkTestCa) of at most 65536 bytes, else `ca`.
//! When it is ok, the auth window's own ephemeral context uses that proxy and allows that CA
//! for claude.com and platform.claude.com only; a file the TLS library cannot load is also
//! `ca`, decided in C when the window opens. Pure, but for the one open and its size.
const std = @import("std");
const linux = std.os.linux;

pub const env = "ZIGBROWSER_AGENT_AUTH_TEST";
/// The largest CA file accepted.
pub const max_ca_bytes = 65536;

pub const Reason = enum { shape, proxy, ca };

pub const Seam = union(enum) {
    none,
    ignored,
    refused: Reason,
    ok: struct { port: u16, ca: []const u8 },
};

const proxy_prefix = "http://127.0.0.1:";

pub fn authTestSeam(e2e_protocol: bool, value: ?[]const u8) Seam {
    const v = value orelse return .none;
    if (!e2e_protocol) return .ignored;
    if (!std.mem.startsWith(u8, v, "proxy=")) return .{ .refused = .shape };
    const rest = v["proxy=".len..];
    const comma = std.mem.indexOfScalar(u8, rest, ',') orelse return .{ .refused = .shape };
    const proxy = rest[0..comma];
    const after = rest[comma + 1 ..];
    if (!std.mem.startsWith(u8, after, "ca=")) return .{ .refused = .shape };
    const ca = after["ca=".len..];
    const port = proxyPort(proxy) orelse return .{ .refused = .proxy };
    if (!caFileOk(ca)) return .{ .refused = .ca };
    return .{ .ok = .{ .port = port, .ca = ca } };
}

/// The port of `http://127.0.0.1:<port>`: 1-65535, decimal, no sign, no leading zero.
fn proxyPort(proxy: []const u8) ?u16 {
    if (!std.mem.startsWith(u8, proxy, proxy_prefix)) return null;
    const digits = proxy[proxy_prefix.len..];
    if (digits.len == 0 or digits.len > 5 or digits[0] == '0') return null;
    for (digits) |c| if (!std.ascii.isDigit(c)) return null;
    const port = std.fmt.parseInt(u32, digits, 10) catch return null;
    if (port > 65535) return null; // 0 cannot occur: no leading zero
    return @intCast(port);
}

/// An absolute path to a regular file, not a symbolic link, of at most max_ca_bytes.
fn caFileOk(path: []const u8) bool {
    if (path.len == 0 or path[0] != '/') return false;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return false;
    const rc = while (true) {
        const r = linux.openat(linux.AT.FDCWD, z, .{ .PATH = true, .NOFOLLOW = true, .CLOEXEC = true }, 0);
        if (linux.errno(r) != .INTR) break r;
    };
    if (linux.errno(rc) != .SUCCESS) return false;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var sx: linux.Statx = undefined;
    const st = linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .TYPE = true, .SIZE = true }, &sx);
    if (linux.errno(st) != .SUCCESS or !linux.S.ISREG(sx.mode)) return false;
    return sx.size <= max_ca_bytes;
}

/// The seam's stderr line, if any: `ignored` and `refused` have one; none and ok have none.
pub fn stderrLine(buf: []u8, s: Seam) ?[]const u8 {
    return switch (s) {
        .none, .ok => null,
        .ignored => "zigBrowser: " ++ env ++ " ignored without --e2e-protocol",
        .refused => |r| std.fmt.bufPrint(buf, "zigBrowser: " ++ env ++ " refused ({s})", .{@tagName(r)}) catch null,
    };
}
