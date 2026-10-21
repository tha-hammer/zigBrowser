//! macOS host spawner (MS8 glue; BlackRobin 7035, Q1): the Zig POSIX side that starts netd, learns its
//! ephemeral egress port from the first stdout line, and hands that port to the `launch` helper as
//! `--egress-port <port>`. On Linux `src/agent_host.c` (GLib + prctl) does the equivalent; `agent_host.c` is
//! Linux-only, so macOS gets its own small module here (NOT in `wkwebview_shim.m`, which stays UI glue).
//!
//! Lifecycle (mirrors the Linux ready wait in `agent_host.c`; owner JadeBeacon, MS8):
//!   1. start netd in its OWN process group with stdout on a pipe (via `agent_spawn_posix.c`);
//!   2. read ONLY the first stdout line, under `ready_wait_ms` (10 s, as Linux);
//!   3. `agent_net.parseDarwinReadyPort` that line -> the port, or null;
//!   4. a null parse, the deadline passing, or netd exiting first is the EXISTING drawer "status … network"
//!      failure: SIGKILL netd's group, NO fallback port, do not start the helper;
//!   5. only on a good port, start the helper with `--egress-port <port>` appended to its launch argv.
//! The sign-in netd (Linux `agent_login.c`) uses the same reader from this module.
//!
//! THIS FILE holds the pure, host-independent core (ready-line parse reuse + the helper-argv construction),
//! unit-tested on Linux below. The process orchestration (spawn + pipe + deadline + kill) is the both-Mac e2e
//! (7035) and depends on an `agent_spawn_posix` stdout-pipe seam (see `SpawnStdoutSeam` note) — pending the
//! diff round with BlackRobin before it lands.

const std = @import("std");
const agent_net = @import("agent_net.zig");

/// The browser's wait for netd's `netd ready …` line, matching the Linux ready wait.
pub const ready_wait_ms: u32 = 10_000;

/// After the ready line, how long the browser confirms netd is still ALIVE before starting the helper (RoseCat
/// 7161 #1). netd holds its stdout open for its whole life, so a stdout EOF within this window means netd exited
/// and the ready line is stale. Only a quiet-but-live netd pays the full grace; a dead one is caught at once.
pub const liveness_grace_ms: u32 = 200;

/// On a clean stop (stdin EOF), how long the browser waits for netd to exit on its own — unlinking its egress
/// sockets/dir — before the SIGKILL backstop (RoseCat 7161 #2).
pub const stop_grace_ms: u32 = 2_000;

/// The exact flag the `launch` helper parses on Darwin (BlackRobin 7035, Q2): required on Darwin, refused off
/// it, decimal 1..65535 with no leading zero — the same grammar as netd's port and `parseDarwinReadyPort`.
pub const egress_port_flag = "--egress-port";

/// netd's first stdout line -> the ephemeral egress port, or null for any other shape (a missing/zero/leading-
/// zero/out-of-range port, a trailing byte, a different host, a prefix mismatch). A thin, named reuse of the
/// grammar in `agent_net`, so the spawner and the browser speak one definition.
pub fn readyPort(first_line: []const u8) ?u16 {
    return agent_net.parseDarwinReadyPort(first_line);
}

/// Append `--egress-port <port>` to a helper launch argv. Allocates a new slice in `a` (an arena is expected);
/// the port is rendered as a plain decimal, so the helper's Darwin parse accepts it. The base argv is copied,
/// never mutated, so the caller's `launch` argv (home/python/net-dir/command/…) is untouched.
pub fn appendEgressPort(a: std.mem.Allocator, base_argv: []const []const u8, port: u16) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, base_argv);
    try argv.append(a, egress_port_flag);
    try argv.append(a, try std.fmt.allocPrint(a, "{d}", .{port}));
    return argv.toOwnedSlice(a);
}

/// What the spawner does after reading netd's stdout. `network_failure` is the EXISTING drawer "status … network"
/// failure: netd's group is SIGKILLed and the helper is NOT started — there is NO fallback port (BlackRobin 7035).
pub const Outcome = enum { start_helper, network_failure };

/// The fail-closed lifecycle decision (7035 step 4): start the helper ONLY when netd gave a well-formed port AND
/// the ready line arrived within the deadline AND netd did not exit first. Any one of a null/malformed port, the
/// deadline passing, or netd exiting early is the network failure — no fallback, no guessed port. Pure, so the
/// security-relevant decision is unit-pinned here; a mutant that starts the helper on any failure input reds.
pub fn decide(port: ?u16, timed_out: bool, netd_exited_early: bool) Outcome {
    if (timed_out or netd_exited_early) return .network_failure;
    return if (port == null) .network_failure else .start_helper;
}

/// The first line of a stdout buffer (up to and excluding the first '\n'), or the whole buffer when it holds no
/// newline yet. The spawner reads netd's stdout into a buffer and takes exactly this first line for `readyPort`
/// — netd prints its ready line first and alone, and a glued-on second line never changes the port (a trailing
/// byte on the ready line itself makes `readyPort` return null, by the grammar).
pub fn firstLine(buf: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, buf, '\n') orelse buf.len;
    return buf[0..end];
}

// The C spawn seam (BlueBeaver 06f0e35; BlackRobin 7108 seam 1): the child's stdin/stdout are the given pipe
// ends (fd -1 inherits; a fd in 0..2 is EINVAL), its own process group, and on Darwin it holds EXACTLY 0,1,2.
extern fn zb_agent_spawn_group_io(
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    stdin_fd: c_int,
    stdout_fd: c_int,
    out_pid: *std.c.pid_t,
) c_int;
// Returns 0 when the group was killed + reaped (or a zombie-only group reaped); a nonzero errno when nothing was
// signalled — EINVAL (pid <= 1 / our pid / our group), ECHILD (not our child), EPERM (not its group's leader) —
// or when killpg failed on a still-live leader (BlueBeaver d8f5e76; RoseCat 7172/7182). It does all the
// ownership/group checks itself, so it is safe to call with any pid.
extern fn zb_agent_kill_group(pid: std.c.pid_t) c_int;

pub const SpawnError = error{ NetworkFailure, OutOfMemory };

/// A running netd: its egress port, its pid (its own group), and the stdin write end the browser HOLDS OPEN for
/// netd's whole life. Closing `stdin_fd` is the clean stop (netd exits on stdin EOF); `kill()` is the hard stop.
pub const Netd = struct {
    port: u16,
    pid: std.c.pid_t,
    stdin_fd: c_int, // the browser holds netd's stdin WRITE end open for netd's whole life

    /// Stop netd: close its stdin (EOF -> netd exits CLEANLY, unlinking its egress sockets/dir), wait up to
    /// `stop_grace_ms` for that clean exit, and SIGKILL + reap the group ONLY as a backstop if it does not exit
    /// in time (RoseCat 7161 #2). A clean exit is reaped with NO signal.
    pub fn stop(self: Netd) void {
        _ = stopWith(self.pid, self.stdin_fd, stop_grace_ms);
    }
};

/// How netd stopped: a clean EOF exit (status 0, no signal); a reaped-but-unclean exit (nonzero/signalled — no
/// further signal needed, but netd's own EOF cleanup may not have run); the SIGKILL backstop killed + reaped its
/// group; the backstop ran but `zb_agent_kill_group` returned nonzero so the group was NOT reaped by us (a race
/// to exit, or killpg failed on a live leader); or a refusal to signal because ownership was unproven — a bad
/// pid, or `waitpid` said the pid is not our child (a real spawned netd never hits the last two).
pub const StopResult = enum { clean_exit, exited_unclean, killed, kill_failed, skipped_bad_pid };

/// Only a real child pid (> 1) may be signalled: pid 0/1/negative must never reach `killpg`, because `killpg(1)`
/// is `kill(-1)` — the incident that logged the user out twice (RoseCat 7162/7172). Pure, unit-pinned with zero
/// kill risk, so the backstop provably sits behind it.
pub fn shouldKillBackstop(pid: std.c.pid_t) bool {
    return pid > 1;
}

/// The result of waiting on `pid`: reaped clean/unclean (no signal), a CONFIRMED-ours live child that outlasted
/// the grace (the backstop may kill its group), or ownership we could NOT prove (a bad pid, or `waitpid` said
/// ECHILD) — which must NEVER be signalled (RoseCat 7182).
const WaitOutcome = enum { exited_clean, exited_unclean, alive_ours_grace_expired, not_our_child };

fn cErrno() c_int {
    return std.c._errno().*;
}

const EINTR_: c_int = @intFromEnum(std.c.E.INTR);

/// The clean-then-backstop stop (RoseCat 7161 #2, 7182): close netd's stdin (EOF -> clean exit), wait up to
/// `grace_ms` for it to exit, and SIGKILL + reap its group ONLY if it does not. Returns which path was taken, so
/// each is observable in tests. `zb_agent_kill_group` itself re-verifies ownership and group leadership and does
/// its own kill-safety (EINVAL/ECHILD/EPERM), so this layer's `waitExit` ownership proof is belt-and-suspenders.
pub fn stopWith(pid: std.c.pid_t, stdin_fd: c_int, grace_ms: u32) StopResult {
    _ = std.c.close(stdin_fd);
    return switch (waitExit(pid, grace_ms)) {
        .exited_clean => .clean_exit,
        .exited_unclean => .exited_unclean,
        .not_our_child => .skipped_bad_pid, // bad pid OR ECHILD: ownership unproven -> never signal (kill-safety)
        .alive_ours_grace_expired => blk: {
            // a CONFIRMED-ours live child that will not exit -> kill its OWN group; 0 = killed + reaped, a
            // nonzero errno (raced exit, or killpg failed on a live leader) = NOT reaped by us (BlueBeaver d8f5e76).
            break :blk if (zb_agent_kill_group(pid) == 0) .killed else .kill_failed;
        },
    };
}

/// Wait up to `grace_ms` for `pid`, reaping it. Ownership is proven by `waitpid(pid, WNOHANG)` ITSELF: it
/// succeeds only for our own child, so `== pid` (reaped) and `== 0` (still alive) both PROVE ownership, while
/// ECHILD proves `pid` is NOT our child (RoseCat 7182) — never signalled. pid <= 1 is refused up front so
/// `waitpid` is never called with the 0 / -1 "whole group / any child" forms. `.exited_clean` means exit 0
/// (netd ran its EOF cleanup); `.exited_unclean` a reaped nonzero/signalled exit (no further signal needed).
fn waitExit(pid: std.c.pid_t, grace_ms: u32) WaitOutcome {
    if (!shouldKillBackstop(pid)) return .not_our_child;
    const start = nowMs();
    while (true) {
        var status: c_int = 0;
        const r = std.c.waitpid(pid, &status, std.c.W.NOHANG);
        if (r == pid) {
            const s: u32 = @bitCast(status);
            return if (std.c.W.IFEXITED(s) and std.c.W.EXITSTATUS(s) == 0) .exited_clean else .exited_unclean;
        }
        if (r == 0) { // r == 0 proves pid IS our child and is still alive
            if (nowMs() - start >= grace_ms) return .alive_ours_grace_expired; // our live child outlasted the grace
            var req: std.c.timespec = .{ .sec = 0, .nsec = 5 * std.time.ns_per_ms };
            var rem: std.c.timespec = undefined;
            _ = std.c.nanosleep(&req, &rem);
            continue;
        }
        if (cErrno() == EINTR_) continue; // transient: retry within the grace
        return .not_our_child; // ECHILD or other error: ownership unproven, do NOT signal
    }
}

fn toCArgv(a: std.mem.Allocator, items: []const []const u8) ![*:null]const ?[*:0]const u8 {
    const arr = try a.allocSentinel(?[*:0]const u8, items.len, null);
    for (items, 0..) |s, i| arr[i] = (try a.dupeZ(u8, s)).ptr;
    return arr.ptr;
}

// POSIX fcntl fd-flag constants (identical on Linux and macOS), so the pipe ends can be made close-on-exec.
const F_GETFD: c_int = 1;
const F_SETFD: c_int = 2;
const FD_CLOEXEC_: c_int = 1;

/// FD_CLOEXEC on a pipe end so the spawned child never inherits the browser's copy (BlackRobin 7108): the C's
/// dup2 clears it on the child's own 0/1, and Darwin's CLOEXEC_DEFAULT closes everything else. Best-effort.
fn setCloexec(fd: c_int) void {
    const flags = std.c.fcntl(fd, F_GETFD);
    if (flags < 0) return;
    _ = std.c.fcntl(fd, F_SETFD, flags | FD_CLOEXEC_);
}

/// Start netd in its own process group with a stdin pipe held open by the browser and a stdout pipe the browser
/// reads, learn the ephemeral egress port from netd's FIRST stdout line within `deadline_ms`, and return the
/// running netd. On ANY failure — the spawn errno, a null/malformed ready line, the deadline passing, or netd
/// exiting first (stdout EOF) — the group is SIGKILLed and `SpawnError.NetworkFailure` is returned, with NO
/// fallback port (BlackRobin 7035). `a` is expected to be an arena (the C argv/env dupes live until return).
pub fn spawnNetd(a: std.mem.Allocator, argv: []const []const u8, envp: []const []const u8, deadline_ms: u32) SpawnError!Netd {
    const cargv = try toCArgv(a, argv);
    const cenv = try toCArgv(a, envp);

    // stdin: parent writes [1], child reads [0]; stdout: child writes [1], parent reads [0].
    var inp: [2]c_int = undefined;
    var outp: [2]c_int = undefined;
    if (std.c.pipe(&inp) != 0) return error.NetworkFailure;
    if (std.c.pipe(&outp) != 0) {
        _ = std.c.close(inp[0]);
        _ = std.c.close(inp[1]);
        return error.NetworkFailure;
    }
    for ([_]c_int{ inp[0], inp[1], outp[0], outp[1] }) |fd| setCloexec(fd);

    var pid: std.c.pid_t = -1;
    const rc = zb_agent_spawn_group_io(cargv, cenv, inp[0], outp[1], &pid);
    _ = std.c.close(inp[0]); // the child's ends belong to the child now
    _ = std.c.close(outp[1]);
    if (rc != 0) {
        _ = std.c.close(inp[1]);
        _ = std.c.close(outp[0]);
        return error.NetworkFailure;
    }

    const port = readFirstPort(outp[0], deadline_ms);
    // Liveness oracle (RoseCat 7161 #1): a netd that printed a valid ready line but has since exited — its stdout
    // EOFs within the grace — is NOT a live netd; `decide` turns that into the network failure, no fallback port.
    const netd_exited_early = if (port != null) !netdAlive(outp[0], liveness_grace_ms) else false;
    _ = std.c.close(outp[0]); // done with netd's stdout either way
    switch (decide(port, false, netd_exited_early)) {
        .start_helper => return Netd{ .port = port.?, .pid = pid, .stdin_fd = inp[1] },
        .network_failure => {
            // No fallback port. Close stdin (EOF) and SIGKILL + reap the group. Best-effort: the return (0, or an
            // errno if netd already exited / is not ours) is irrelevant — we fail closed regardless.
            _ = std.c.close(inp[1]);
            _ = zb_agent_kill_group(pid);
            return error.NetworkFailure;
        },
    }
}

/// Post-ready liveness oracle (RoseCat 7161 #1): is netd still running after its ready line? netd holds its
/// stdout open for its whole life, so within `grace_ms`: a stdout EOF (read returns 0) means netd has exited ->
/// NOT alive; a poll timeout (open and quiet) or more output (read > 0) means alive. Only the quiet-alive case
/// pays the full grace; a dead netd is caught as soon as its EOF is readable.
fn netdAlive(fd: c_int, grace_ms: u32) bool {
    const start = nowMs();
    while (true) {
        const elapsed = nowMs() - start;
        if (elapsed >= grace_ms) return true; // still open and quiet within the grace: alive
        const remaining: c_int = @intCast(@as(i64, grace_ms) - elapsed);
        var pfd = [_]std.c.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
        const r = std.c.poll(&pfd, 1, remaining);
        if (r == 0) continue; // poll timeout: re-check the grace at the loop top
        if (r < 0) {
            if (cErrno() == EINTR_) continue; // transient: retry
            return false; // other poll error: fail closed — cannot confirm liveness (RoseCat 7182 SHOULD)
        }
        var b: [64]u8 = undefined;
        const n = std.c.read(fd, &b, b.len);
        if (n == 0) return false; // EOF/HUP: netd closed stdout = exited: NOT alive
        if (n < 0) {
            if (cErrno() == EINTR_) continue; // transient: retry
            return false; // other read error: fail closed
        }
        // n > 0 (late output): DRAIN and keep observing — a later EOF within the grace still means dead, so we
        // must not early-return on extra stdout (RoseCat 7172 #1).
    }
}

/// Read netd's first stdout line within the deadline and parse its port; null on deadline, EOF (netd exited
/// first), a read error, or a line that is not the exact ready grammar.
fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), std.time.ns_per_ms);
}

fn readFirstPort(fd: c_int, deadline_ms: u32) ?u16 {
    var buf: [256]u8 = undefined;
    var len: usize = 0;
    const start = nowMs();
    while (true) {
        const elapsed = nowMs() - start;
        if (elapsed >= deadline_ms) return null;
        const remaining: c_int = @intCast(@as(i64, deadline_ms) - elapsed);
        var pfd = [_]std.c.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.c.poll(&pfd, 1, remaining);
        if (ready <= 0) return null; // 0 = deadline, <0 = error: fail closed
        const n = std.c.read(fd, buf[len..].ptr, buf.len - len);
        if (n <= 0) return readyPort(firstLine(buf[0..len])); // EOF / error: parse what we have
        len += @intCast(n);
        if (std.mem.indexOfScalar(u8, buf[0..len], '\n') != null or len == buf.len)
            return readyPort(firstLine(buf[0..len]));
    }
}

test "decide is fail-closed: the helper starts only on a good port, in time, with netd alive" {
    try std.testing.expectEqual(Outcome.start_helper, decide(50607, false, false));
    try std.testing.expectEqual(Outcome.network_failure, decide(null, false, false)); // malformed/absent port
    try std.testing.expectEqual(Outcome.network_failure, decide(50607, true, false)); // deadline passed
    try std.testing.expectEqual(Outcome.network_failure, decide(50607, false, true)); // netd exited first
    try std.testing.expectEqual(Outcome.network_failure, decide(null, true, true)); // everything wrong
    // a port present but timed out or exited is STILL a failure — no fallback to a port read late
    try std.testing.expectEqual(Outcome.network_failure, decide(1, true, false));
}

test "readyPort reuses the Darwin ready grammar" {
    try std.testing.expectEqual(@as(?u16, 50607), readyPort("netd ready 127.0.0.1:50607"));
    try std.testing.expectEqual(@as(?u16, null), readyPort("netd ready 127.0.0.1:0")); // zero
    try std.testing.expectEqual(@as(?u16, null), readyPort("netd ready 127.0.0.1:050607")); // leading zero
    try std.testing.expectEqual(@as(?u16, null), readyPort("netd ready 127.0.0.1:50607 ")); // trailing byte
    try std.testing.expectEqual(@as(?u16, null), readyPort("netd ready ::1:50607")); // wrong host
    try std.testing.expectEqual(@as(?u16, null), readyPort("netd ready")); // no port
}

test "firstLine takes exactly the first line" {
    try std.testing.expectEqualStrings("netd ready 127.0.0.1:5", firstLine("netd ready 127.0.0.1:5\nextra\n"));
    try std.testing.expectEqualStrings("no newline yet", firstLine("no newline yet"));
    try std.testing.expectEqualStrings("", firstLine("\nsecond"));
}

test "appendEgressPort appends the flag + decimal port and leaves the base untouched" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = [_][]const u8{ "python", "-m", "zb_agent_host", "launch", "--home", "/h", "--command", "chat" };
    const out = try appendEgressPort(a, &base, 50607);
    try std.testing.expectEqual(@as(usize, base.len + 2), out.len);
    try std.testing.expectEqualStrings("--egress-port", out[base.len]);
    try std.testing.expectEqualStrings("50607", out[base.len + 1]);
    // the base argv is unchanged (copied, not aliased)
    try std.testing.expectEqualStrings("python", out[0]);
    try std.testing.expectEqualStrings("chat", out[base.len - 1]);
}

test "appendEgressPort renders the full u16 range as plain decimal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = [_][]const u8{"x"};
    const out = try appendEgressPort(a, &base, 65535);
    try std.testing.expectEqualStrings("65535", out[2]);
    // a round-trip: the helper's Darwin parse (same grammar) accepts exactly what we emit
    try std.testing.expectEqual(@as(?u16, 65535), readyPort("netd ready 127.0.0.1:65535"));
}
