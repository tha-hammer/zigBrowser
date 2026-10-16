//! The browser's side of the agent network (chat-drawer plan rev 16.2, §3c.2,
//! §3c.4; S3n2 native spawn wiring): where netd's socket directory is, the
//! app-owned e2e seams, and netd's exact argv. Pure, except checkTestCa's
//! one no-follow open; app.zig gathers the inputs and spawns
//! (src/agent_host.c).
//!
//! The seams are honoured only with --e2e-protocol, and reach netd or the
//! helper only as arguments, never through an environment (§3c.4):
//! - ZIGBROWSER_AGENT_NET_TEST: netd's test options, exactly pairs of
//!   `--test-allow fake.zb.invalid=<port>` (at most once) and
//!   `--test-bridge 51091|31337=<port>` (at most once each) and
//!   `--test-ready-delay ms=<1-4000>` (at most once: netd holds its ready
//!   line that long, so a test can act while the helper waits for the
//!   network; RoseCat 5830), separated by single spaces; numbers are decimal,
//!   no sign, no leading zero (BlackRobin 5570);
//! - ZIGBROWSER_AGENT_NET_TEST_CA: the fake API's test CA, an absolute path
//!   to a regular file that is not a link, passed to `launch` as --test-ca.

const std = @import("std");
const linux = std.os.linux;

pub const net_test_env = "ZIGBROWSER_AGENT_NET_TEST";
pub const net_test_ca_env = "ZIGBROWSER_AGENT_NET_TEST_CA";
pub const fake_host = "fake.zb.invalid";
/// The longest path netd binds is <dir>/bridges/port-51091.sock; sun_path
/// holds 107 bytes and a NUL.
pub const sun_path_max = 107;
const longest_socket = "/bridges/port-51091.sock";

pub const SockdirError = error{ NoRuntimeDir, RelativeRuntimeDir, PathTooLong, OutOfMemory };

/// `<runtime_dir>/zigbrowser-agent-<pid>-<16 hex of random>`: a fresh name per
/// start, so a reused PID never meets a stale directory (rev 16.1). netd
/// itself creates it with one exclusive mkdir.
pub fn sockdirPath(gpa: std.mem.Allocator, runtime_dir: ?[]const u8, pid: u32, random: [8]u8) SockdirError![]u8 {
    const given = runtime_dir orelse return error.NoRuntimeDir;
    if (given.len == 0) return error.NoRuntimeDir;
    if (given[0] != '/') return error.RelativeRuntimeDir;
    const root = std.mem.trimEnd(u8, given, "/");
    const hex = std.fmt.bytesToHex(random, .lower);
    const dir = try std.fmt.allocPrint(gpa, "{s}/zigbrowser-agent-{d}-{s}", .{ root, pid, &hex });
    if (dir.len + longest_socket.len > sun_path_max) {
        gpa.free(dir);
        return error.PathTooLong;
    }
    return dir;
}

pub const NetTest = struct {
    allow: ?u16 = null,
    bridge_51091: ?u16 = null,
    bridge_31337: ?u16 = null,
    ready_delay_ms: ?u16 = null,
};

/// The longest ready hold: under the browser's 5 s wait for `netd ready`.
pub const max_ready_delay_ms = 4000;

/// ZIGBROWSER_AGENT_NET_TEST's grammar; anything else is error.BadNetTest.
pub fn parseNetTest(text: []const u8) error{BadNetTest}!NetTest {
    if (text.len == 0) return error.BadNetTest;
    var out: NetTest = .{};
    var it = std.mem.splitScalar(u8, text, ' ');
    while (it.next()) |option| {
        const pair = it.next() orelse return error.BadNetTest;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return error.BadNetTest;
        const name = pair[0..eq];
        const port = try parsePort(pair[eq + 1 ..]);
        const slot: *?u16 = if (std.mem.eql(u8, option, "--test-allow") and std.mem.eql(u8, name, fake_host))
            &out.allow
        else if (std.mem.eql(u8, option, "--test-bridge") and std.mem.eql(u8, name, "51091"))
            &out.bridge_51091
        else if (std.mem.eql(u8, option, "--test-bridge") and std.mem.eql(u8, name, "31337"))
            &out.bridge_31337
        else if (std.mem.eql(u8, option, "--test-ready-delay") and std.mem.eql(u8, name, "ms") and port <= max_ready_delay_ms)
            &out.ready_delay_ms
        else
            return error.BadNetTest;
        if (slot.* != null) return error.BadNetTest;
        slot.* = port;
    }
    return out;
}

fn parsePort(text: []const u8) error{BadNetTest}!u16 {
    if (text.len == 0 or text.len > 5 or text[0] == '0') return error.BadNetTest;
    var value: u32 = 0;
    for (text) |ch| {
        if (ch < '0' or ch > '9') return error.BadNetTest;
        value = value * 10 + (ch - '0');
    }
    if (value > 65535) return error.BadNetTest;
    return @intCast(value);
}

/// netd's argv (§3c.2, BlueBeaver 5466): the runtime's netd.py run as a script
/// (standard library only, so -I needs no PYTHONPATH and -S no site), then the
/// backend's network manifest (MS0, BlueBeaver 5755) when there is an agent
/// home, then the seam's options in a fixed order. Allocates in `a` (an arena
/// is expected).
pub fn netdArgv(a: std.mem.Allocator, python: []const u8, package_dir: []const u8, sockdir: []const u8, bwrap: []const u8, manifest: ?[]const u8, seam: ?NetTest) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    const script = try std.fs.path.join(a, &.{ package_dir, "zb_agent_host", "netd.py" });
    try argv.appendSlice(a, &.{ python, "-I", "-S", script, "--sockdir", sockdir, "--bwrap", bwrap });
    if (manifest) |path| try argv.appendSlice(a, &.{ "--net-manifest", path });
    if (seam) |s| {
        if (s.allow) |port| try argv.appendSlice(a, &.{ "--test-allow", try std.fmt.allocPrint(a, fake_host ++ "={d}", .{port}) });
        if (s.bridge_51091) |port| try argv.appendSlice(a, &.{ "--test-bridge", try std.fmt.allocPrint(a, "51091={d}", .{port}) });
        if (s.bridge_31337) |port| try argv.appendSlice(a, &.{ "--test-bridge", try std.fmt.allocPrint(a, "31337={d}", .{port}) });
        if (s.ready_delay_ms) |ms| try argv.appendSlice(a, &.{ "--test-ready-delay", try std.fmt.allocPrint(a, "{d}", .{ms}) });
    }
    return argv.toOwnedSlice(a);
}

/// The backend's network manifest in an agent home: setup writes it from the
/// LaunchSpec network field, and netd reads it (its allow-list and bridge ports).
pub fn netManifestPath(a: std.mem.Allocator, agent_home: []const u8) ![]const u8 {
    return std.fs.path.join(a, &.{ agent_home, "runtime", "net.json" });
}

/// netd's whole environment, built, never inherited from the browser (BlackRobin
/// 5577): no ZIGBROWSER_* seam reaches it except as an argument.
pub fn netdEnv(a: std.mem.Allocator, lang: ?[]const u8, lc_all: ?[]const u8) ![]const []const u8 {
    var env: std.ArrayList([]const u8) = .empty;
    try env.appendSlice(a, &.{ "PATH=/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE=1" });
    if (lang) |v| try env.append(a, try std.fmt.allocPrint(a, "LANG={s}", .{v}));
    if (lc_all) |v| try env.append(a, try std.fmt.allocPrint(a, "LC_ALL={s}", .{v}));
    return env.toOwnedSlice(a);
}

/// ZIGBROWSER_AGENT_NET_TEST_CA must name, by an absolute path, a regular file
/// that is not a symbolic link (checked on one O_PATH|O_NOFOLLOW descriptor).
pub fn checkTestCa(path: []const u8) error{BadNetTestCa}!void {
    if (path.len == 0 or path[0] != '/') return error.BadNetTestCa;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return error.BadNetTestCa;
    const rc = while (true) {
        const r = linux.openat(linux.AT.FDCWD, z, .{ .PATH = true, .NOFOLLOW = true, .CLOEXEC = true }, 0);
        if (linux.errno(r) != .INTR) break r;
    };
    if (linux.errno(rc) != .SUCCESS) return error.BadNetTestCa;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var sx: linux.Statx = undefined;
    const st = linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .TYPE = true }, &sx);
    if (linux.errno(st) != .SUCCESS or !linux.S.ISREG(sx.mode)) return error.BadNetTestCa;
}
