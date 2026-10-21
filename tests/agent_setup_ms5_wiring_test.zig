//! macOS plan rev 14 items 2 and 5, the Linux-provable half of wiring macOS `--agent-setup` (behind the
//! "sandbox not ready" gate until MS6):
//! - item 5: `agent_setup.launch` passes the browser's pid to setup as `--browser-pid <pid>` (setup.py's
//!   Darwin parent watch arms on it); with no pid the argv is exactly today's (Linux byte-identical);
//! - item 2: `self_exe.path(buf)` is the running binary's real path. On Linux it is readlink("/proc/self/exe");
//!   on macOS it is _NSGetExecutablePath then realpath (compiled by the cross-check, run on the Macs).
//! Unregistered until the green (run: zig test -lc --dep agent_setup --dep self_exe
//!   -Mroot=tests/agent_setup_ms5_wiring_test.zig -Magent_setup=src/agent_setup.zig -Mself_exe=src/self_exe.zig).
const std = @import("std");
const agent_setup = @import("agent_setup");
const self_exe = @import("self_exe");

fn launchWith(gpa: std.mem.Allocator, pid: ?u32) !agent_setup.Launch {
    var in: agent_setup.Inputs = .{
        .home = "/d/agent-home", .python = "/rt/bin/python3.12", .package_dir = "/rt",
        .sai_source = "/u/.claude", .source_home = "/u", .source_path = "/usr/bin", .e2e_protocol = false,
    };
    if (!@hasField(agent_setup.Inputs, "browser_pid")) return error.MissingBrowserPid;
    @field(in, "browser_pid") = pid;
    return agent_setup.launch(gpa, in);
}

test "item 5: the browser's pid reaches setup as --browser-pid, right after --python" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const run = try launchWith(arena.allocator(), 4242);
    var at: ?usize = null;
    for (run.argv, 0..) |a, i| if (std.mem.eql(u8, a, "--browser-pid")) {
        try std.testing.expect(at == null);
        at = i;
    };
    try std.testing.expect(at != null);
    try std.testing.expectEqualStrings("4242", run.argv[at.? + 1]);
    try std.testing.expectEqualStrings("--python", run.argv[at.? - 2]);
}

test "item 5: with no pid the argv is exactly today's (Linux unchanged)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const run = try launchWith(arena.allocator(), null);
    for (run.argv) |a| try std.testing.expect(!std.mem.eql(u8, a, "--browser-pid"));
    try std.testing.expectEqual(@as(usize, 13), run.argv.len);
}

test "item 2: self_exe.path is the running binary's real path (Linux: /proc/self/exe)" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    if (!@hasDecl(self_exe, "path")) return error.MissingSelfExePath;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const got = try self_exe.path(&buf);
    var want_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.c.readlink("/proc/self/exe", &want_buf, want_buf.len);
    try std.testing.expect(n > 0);
    try std.testing.expectEqualStrings(want_buf[0..@intCast(n)], got);
    try std.testing.expect(std.fs.path.isAbsolute(got));
}
