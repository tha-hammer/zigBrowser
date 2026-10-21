//! spawnNetd integration (BlackRobin 7035/7108 seam 1+Q1): the Zig spawner drives BlueBeaver's
//! zb_agent_spawn_group_io (compiled in by build.zig), so this runs on Linux with a stand-in netd — a
//! /bin/sh that prints a ready line (or not) and then `cat`s (blocking on the held-open stdin). It pins:
//!   - a good ready line -> the exact egress port, and netd stays up (its stdin is held);
//!   - a malformed first line -> NetworkFailure (no fallback port);
//!   - netd exiting before any line (stdout EOF) -> NetworkFailure;
//!   - no line within the deadline -> NetworkFailure.
//! The real both-Mac fake-netd e2e is separate; this is the Linux unit. (CLOEXEC_DEFAULT is Darwin-only and
//! #ifdef'd out here; the stdin/stdout wiring + exit-on-stdin-EOF are the same on Linux.)
const std = @import("std");
const spawner = @import("agent_host_posix");

fn run(script: []const u8, deadline_ms: u32) spawner.SpawnError!spawner.Netd {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = [_][]const u8{ "/bin/sh", "-c", script };
    const envp = [_][]const u8{"PATH=/usr/bin:/bin"};
    return spawner.spawnNetd(a, &argv, &envp, deadline_ms);
}

test "a good ready line yields the exact port and netd stays up" {
    const netd = try run("printf 'netd ready 127.0.0.1:50607\\n'; cat", 4000);
    defer netd.stop();
    try std.testing.expectEqual(@as(u16, 50607), netd.port);
    try std.testing.expect(netd.pid > 0);
    // netd (the `cat`) is still running: spawnNetd read the ready line while the child blocks on its held-open
    // stdin. stop() below closes that stdin (EOF -> the child exits) and reaps the group.
}

test "a malformed first line is NetworkFailure, no port" {
    try std.testing.expectError(error.NetworkFailure, run("printf 'garbage line\\n'; cat", 4000));
}

test "netd exiting before any line (stdout EOF) is NetworkFailure" {
    try std.testing.expectError(error.NetworkFailure, run("exit 0", 4000));
}

test "no ready line within the deadline is NetworkFailure" {
    try std.testing.expectError(error.NetworkFailure, run("sleep 5", 200));
}

test "the ready line still parses when netd keeps writing after it" {
    const netd = try run("printf 'netd ready 127.0.0.1:65535\\nmore output\\n'; cat", 4000);
    defer netd.stop();
    try std.testing.expectEqual(@as(u16, 65535), netd.port);
}
