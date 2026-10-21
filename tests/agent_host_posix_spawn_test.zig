//! spawnNetd integration (BlackRobin 7035/7108 seam 1+Q1; RoseCat 7161): the Zig spawner drives BlueBeaver's
//! zb_agent_spawn_group_io (compiled in by build.zig), so this runs on Linux with a stand-in netd — a
//! /bin/sh that prints a ready line (or not) and then `cat`s (blocking on the held-open stdin). It pins:
//!   - a good ready line AND a live netd -> the exact egress port, netd stays up (its stdin is held);
//!   - a malformed first line -> NetworkFailure (no fallback port);
//!   - netd exiting before any line (stdout EOF) -> NetworkFailure;
//!   - a VALID ready line but netd then exits (the ready-then-exit race) -> NetworkFailure: the port is stale,
//!     there is no live netd to serve egress, so the liveness oracle rejects it (RoseCat 7161 #1);
//!   - no line within the deadline -> NetworkFailure;
//!   - stop() on a netd that exits on stdin EOF is a CLEAN exit, reaped with no signal; stop() on a netd that
//!     ignores the EOF SIGKILLs its group only after the grace (RoseCat 7161 #2).
//! The real both-Mac fake-netd e2e is separate; this is the Linux unit. (CLOEXEC_DEFAULT is Darwin-only and
//! #ifdef'd out here; the stdin/stdout wiring + exit-on-stdin-EOF are the same on Linux.) The cases that stop a
//! netd send a SIGKILL to that netd's OWN new process group (posix_spawn SETPGROUP), never kill(-1): run the
//! module under `unshare --user --map-root-user --pid --fork --mount-proc` per the kill-safety rule.
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

test "a valid ready line but netd then exits (ready-then-exit race) is NetworkFailure" {
    // netd prints a well-formed ready line and then EXITS: the port is learned but no live netd remains. The
    // liveness oracle must reject this (RoseCat 7161 #1) — without it the spawner accepts a dead netd.
    try std.testing.expectError(error.NetworkFailure, run("printf 'netd ready 127.0.0.1:50607\\n'; exit 0", 4000));
}

test "stop() is a clean exit (no signal) when netd exits on stdin EOF" {
    // `cat` exits 0 when its stdin closes, so closing netd's stdin is enough: stopWith observes the clean exit
    // within the grace and reaps it WITHOUT a SIGKILL (RoseCat 7161 #2).
    const netd = try run("printf 'netd ready 127.0.0.1:50607\\n'; cat", 4000);
    try std.testing.expectEqual(spawner.StopResult.clean_exit, spawner.stopWith(netd.pid, netd.stdin_fd, 2000));
}

test "stop() SIGKILLs the group only after the grace when netd ignores stdin EOF" {
    // `exec sleep 5` holds stdout open (so the liveness check sees a live netd) and ignores the stdin EOF, so the
    // clean path times out and the SIGKILL backstop reaps its OWN process group (RoseCat 7161 #2; never kill(-1)).
    const netd = try run("printf 'netd ready 127.0.0.1:50607\\n'; exec sleep 5", 4000);
    try std.testing.expectEqual(spawner.StopResult.killed, spawner.stopWith(netd.pid, netd.stdin_fd, 300));
}

test "late output after the ready line does not mask an exit within the liveness grace" {
    // netd prints the ready line, then (after a delay, so it arrives mid-poll) extra output, then EXITS inside
    // the grace. The liveness oracle must drain the late output and keep observing, not accept on read>0, or a
    // dead netd slips through (RoseCat 7172 #1).
    try std.testing.expectError(error.NetworkFailure,
        run("printf 'netd ready 127.0.0.1:50607\\n'; sleep 0.05; printf 'late diagnostic\\n'; exit 0", 4000));
}

test "stop() reports a reaped nonzero exit as unclean (no signal, cleanup may not have run)" {
    // On stdin EOF `cat` exits 0, then the shell exits 3: the leader is reaped without a signal, but not cleanly.
    const netd = try run("printf 'netd ready 127.0.0.1:50607\\n'; cat; exit 3", 4000);
    try std.testing.expectEqual(spawner.StopResult.exited_unclean, spawner.stopWith(netd.pid, netd.stdin_fd, 2000));
}

test "shouldKillBackstop refuses pid 0/1/negative — killpg(1) is kill(-1)" {
    // Pure guard, zero kill risk: the backstop in stopWith sits behind exactly this (RoseCat 7172 #3). A
    // behavioural pid==1 test is deliberately NOT written — it would itself risk kill(-1) on any regression.
    try std.testing.expect(!spawner.shouldKillBackstop(1));
    try std.testing.expect(!spawner.shouldKillBackstop(0));
    try std.testing.expect(!spawner.shouldKillBackstop(-1));
    try std.testing.expect(spawner.shouldKillBackstop(2));
    try std.testing.expect(spawner.shouldKillBackstop(1234));
}
