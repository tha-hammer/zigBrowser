//! MS6.5.1 red (whole-recovery live-stalled-holder; macOS-plan Rev 27). A LIVE owner that holds the one global
//! ledger flock and stalls must NOT wedge startup: independent B's `runStartupRecovery` acquires BOUNDED within
//! one total monotonic deadline and, on timeout, FAILS CLOSED — `acquired=false`, a `recovery_busy` incident, the
//! first new run `refused_deferred`, zero on-disk mutation (the seeded entry retained), zero signals. Two real
//! processes + a parent watchdog; no signal is sent on the success path. UNREGISTERED until green.
//!
//! The mutant this catches: a BLOCKING `flock(LOCK_EX)` acquire (no bound) -> B hangs on the stalled holder and
//! is killed by the parent watchdog past the deadline. The registered step must never wedge.
const std = @import("std");
const ledger = @import("agent_run_ledger");
const linux = std.os.linux;

const SEED = [_]ledger.Entry{.{ .basename = "zigbrowser-agent-7-00aa00aa00aa00aa", .dev = 1, .ino = 2, .uid = 0, .mode = 16832, .pid = 7, .start_sec = 0, .start_usec = 0, .state = .active }};

test "a live stalled flock holder cannot wedge startup recovery: B fails closed within the deadline, no mutation" {
    const io = std.testing.io;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    try ledger.publish(io, td.dir, "runs.json", &SEED); // the entry B must RETAIN on a fail-closed recovery

    // A (separate process): take LOCK_EX on the global lock, signal ready, stall ALIVE for a bounded window
    // (outlasting B's deadline + the parent watchdog), then self-release by exiting. A holds the flock across
    // B's whole bounded attempt — no signal is needed to free it.
    var aready: [2]i32 = undefined;
    try std.testing.expect(linux.pipe(&aready) == 0);
    const a_pid = linux.fork();
    if (a_pid == 0) {
        _ = linux.close(aready[0]);
        const lf = linux.openat(td.dir.handle, ledger.LOCK_NAME, .{ .ACCMODE = .RDWR, .CREAT = true }, 0o600);
        _ = linux.flock(@intCast(lf), std.posix.LOCK.EX);
        _ = linux.write(aready[1], "R", 1);
        var ts: linux.timespec = .{ .sec = 3, .nsec = 0 }; // hold across B's ~100ms deadline + the 1s watchdog
        _ = linux.nanosleep(&ts, &ts);
        linux.exit_group(0);
    }
    _ = linux.close(aready[1]);
    var rb: [1]u8 = undefined;
    try std.testing.expect(linux.read(aready[0], &rb, 1) == 1); // A now holds the lock

    // B (separate process): run startup recovery with a bounded deadline (~100ms), write the 3-field result to a
    // pipe, exit. A blocking-acquire mutant never writes -> the parent watchdog kills B.
    var bpipe: [2]i32 = undefined;
    try std.testing.expect(linux.pipe(&bpipe) == 0);
    const b_pid = linux.fork();
    if (b_pid == 0) {
        _ = linux.close(bpipe[0]);
        const r = ledger.runStartupRecovery(io, td.dir, 20, 5); // bounded ~100ms
        const bytes = [3]u8{ @intFromBool(r.acquired), @intFromEnum(r.incident), @intFromEnum(r.first_run) };
        _ = linux.write(bpipe[1], &bytes, 3);
        linux.exit_group(0);
    }
    _ = linux.close(bpipe[1]);

    // Parent watchdog: wait ~1s for B's result. Present => B returned within the deadline (green). Absent => B
    // hung on a blocking acquire (mutant) -> kill it and fail. Either way A is reaped (it self-releases at 3s).
    var pfd = [_]linux.pollfd{.{ .fd = bpipe[0], .events = linux.POLL.IN, .revents = 0 }};
    const pn = linux.poll(&pfd, 1, 1000); // 1s watchdog, shorter than A's 3s hold
    if (pn == 0) {
        _ = linux.kill(@intCast(b_pid), linux.SIG.KILL); // wedged past the deadline -> reap and fail
        var bst: u32 = undefined;
        _ = linux.waitpid(@intCast(b_pid), &bst, 0);
        var ast: u32 = undefined;
        _ = linux.waitpid(@intCast(a_pid), &ast, 0);
        return error.RecoveryWedgedPastDeadline;
    }
    var rbuf: [3]u8 = undefined;
    try std.testing.expect(linux.read(bpipe[0], &rbuf, 3) == 3);
    var bst: u32 = undefined;
    _ = linux.waitpid(@intCast(b_pid), &bst, 0);

    // reap A (it self-releases at 3s) before asserting, so a failed assertion never strands it
    var ast: u32 = undefined;
    _ = linux.waitpid(@intCast(a_pid), &ast, 0);

    // fail-closed result: not acquired, recovery-busy, first run refused/deferred
    try std.testing.expectEqual(@as(u8, 0), rbuf[0]); // acquired == false
    try std.testing.expectEqual(@as(u8, @intFromEnum(ledger.RecoveryIncident.recovery_busy)), rbuf[1]);
    try std.testing.expectEqual(@as(u8, @intFromEnum(ledger.FirstRun.refused_deferred)), rbuf[2]);

    // zero on-disk mutation: the seeded entry is retained unchanged
    var l = try ledger.load(io, std.testing.allocator, td.dir, "runs.json");
    defer l.deinit();
    try std.testing.expectEqual(@as(usize, 1), l.entries().len);
    try std.testing.expectEqualStrings(SEED[0].basename, l.entries()[0].basename);
}
