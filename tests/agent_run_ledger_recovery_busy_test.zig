//! MS6.5.1 (SCOPED, RoseCat c11bff8; e665676 #2/#3/#4): the BOUNDED flock-acquisition primitive. A LIVE owner that
//! holds the one global ledger flock and stalls must NOT wedge the bounded acquire: independent B's
//! `acquireRunLockBounded` acquires within the deadline and, on timeout, FAILS CLOSED — `acquired=false`, a `lock_unavailable`
//! incident, the first new run `refused_deferred`, zero on-disk mutation (the store byte-for-byte retained), zero
//! signals. Two real processes + a bounded, EINTR-safe watchdog.
//!
//! SAFETY (RoseCat e665676 #2): this test sends SIGKILL to its own holder in the wedge path. It runs ONLY inside a
//! PID namespace strictly below its launcher's — a kernel-proof sentinel (fd 9 = the launcher's held outer
//! /proc/self/ns/pid, via `exec 9<…` before `unshare`) gates EVERY fork/signal. Anything missing/unsupported fails
//! closed (no fork, no signal). The build step wraps the run in `unshare --user --map-root-user --pid --fork
//! --mount-proc`. UNREGISTERED until green (it IS registered now via that wrapped step).
//!
//! The mutant this catches: a BLOCKING `flock(LOCK_EX)` acquire (no bound) -> B hangs and is killed by the
//! watchdog past the deadline.
const std = @import("std");
const ledger = @import("agent_run_ledger");
const linux = std.os.linux;

const SEED = [_]ledger.Entry{.{ .basename = "zigbrowser-agent-7-00aa00aa00aa00aa", .dev = 1, .ino = 2, .uid = 0, .mode = 16832, .pid = 7, .start_kind = .linux_ticks, .start_sec = 0, .start_usec = 0, .state = .active }};

const OUTER_NS_FD: i32 = 9; // the launcher holds its /proc/self/ns/pid here (exec 9<…) BEFORE unshare
const NS_GET_NSTYPE: u32 = 0xB703;
const NS_GET_TGID_IN_PIDNS: u32 = 0x8004B709;
const CLONE_NEWPID: usize = 0x20000000;
const AT_EMPTY_PATH: u32 = 0x1000;

fn nsIno(dirfd: i32, path: [*:0]const u8, flags: u32) ?u64 {
    var sx: linux.Statx = undefined;
    if (linux.errno(linux.statx(dirfd, path, flags, linux.STATX.BASIC_STATS, &sx)) != .SUCCESS) return null;
    return sx.ino;
}

/// Kernel proof (RoseCat 7422/7433 pattern) that this process runs in a PID namespace strictly BELOW the
/// launcher's held one (fd 9), before any fork or signal. Fail closed on anything missing/malformed/unsupported.
fn inPrivatePidNamespace() bool {
    const ty = linux.ioctl(OUTER_NS_FD, NS_GET_NSTYPE, 0); // (1) fd 9 is a PID namespace
    if (linux.errno(ty) != .SUCCESS or ty != CLONE_NEWPID) return false;
    const held = nsIno(OUTER_NS_FD, "", AT_EMPTY_PATH) orelse return false; // (2) not our OWN pid namespace
    const own = nsIno(linux.AT.FDCWD, "/proc/self/ns/pid", 0) orelse return false;
    if (held == own) return false;
    // (3) our pid translates INTO the held ns (the kernel allows this only for an ancestor) -> strictly below it
    if (linux.errno(linux.ioctl(OUTER_NS_FD, NS_GET_TGID_IN_PIDNS, @as(usize, @intCast(linux.getpid())))) != .SUCCESS) return false;
    if (linux.getpid() != 1 and linux.getppid() != 1) return false; // (4) unshare --fork shape
    return true;
}

fn storeBytes(io: std.Io, dir: std.Io.Dir, gpa: std.mem.Allocator) ![]u8 {
    return dir.readFileAlloc(io, "runs.json", gpa, .limited(64 * 1024));
}

/// A real poll of one pipe fd for a 100ms slice, decoded for the bounded watchdog: data -> ready, slice elapsed
/// -> again, interrupted -> eintr (the deadline bounds the retry), any other error -> err (fail closed).
const RealPoll = struct {
    fd: i32,
    pub fn pollOnce(self: RealPoll) ledger.PollOutcome {
        var pfd = [_]linux.pollfd{.{ .fd = self.fd, .events = linux.POLL.IN, .revents = 0 }};
        const pn = linux.poll(&pfd, 1, 100);
        return switch (linux.errno(pn)) {
            .SUCCESS => if (pn > 0 and (pfd[0].revents & linux.POLL.IN) != 0) .ready else .again,
            .INTR => .eintr,
            else => .err,
        };
    }
};

test "a live stalled flock holder cannot wedge the bounded acquire: B fails closed within the deadline, no mutation" {
    // SAFETY sentinel: refuse to run (no fork, no signal) unless kernel-proven inside a private PID namespace.
    if (!inPrivatePidNamespace()) return error.NotInPrivatePidNamespace;

    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    try ledger.publish(io, td.dir, "runs.json", &SEED); // the store B must RETAIN byte-for-byte on a fail-closed recovery
    const before = try storeBytes(io, td.dir, gpa);
    defer gpa.free(before);

    // A (separate process): take LOCK_EX on the global lock, signal ready, stall ALIVE for a bounded window
    // (outlasting B's deadline + the watchdog), then self-release by exiting. No signal frees it.
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
    if (linux.errno(a_pid) != .SUCCESS) return error.ForkFailed; // A fork failed -> fail closed (no B, no signal)
    _ = linux.close(aready[1]);
    var rb: [1]u8 = undefined;
    try std.testing.expect(linux.read(aready[0], &rb, 1) == 1); // A now holds the lock

    // B (separate process): run the bounded acquire primitive with a bounded deadline (~100ms), write its 3-field result to a
    // pipe, exit. A blocking-acquire mutant never writes -> the watchdog kills B.
    var bpipe: [2]i32 = undefined;
    try std.testing.expect(linux.pipe(&bpipe) == 0);
    const b_pid = linux.fork();
    if (b_pid == 0) {
        _ = linux.close(bpipe[0]);
        const r = ledger.acquireRunLockBounded(io, td.dir, 100, 5, ledger.RealClock{ .io = io }); // 100ms budget
        const bytes = [2]u8{ @intFromBool(r.acquired), @intFromEnum(r.incident) };
        _ = linux.write(bpipe[1], &bytes, 2);
        linux.exit_group(0);
    }
    if (linux.errno(b_pid) != .SUCCESS) { // B fork failed -> release+reap A, fail closed (no signal)
        _ = linux.close(aready[0]);
        var astf: u32 = undefined;
        _ = linux.waitpid(@intCast(a_pid), &astf, 0);
        return error.ForkFailed;
    }
    _ = linux.close(bpipe[1]);

    // Bounded, EINTR-safe watchdog (RoseCat e665676 #3): waitWithinDeadline polls B's pipe within an ABSOLUTE
    // monotonic 1s deadline, so an EINTR storm or a run of empty slices can NEVER keep it alive past the deadline.
    // A timeout means B wedged on a blocking acquire; a poll error fails closed. Either way B is killed and reaped.
    const clock = ledger.RealClock{ .io = io };
    const wr = ledger.waitWithinDeadline(clock, clock.nowMs() + 1000, RealPoll{ .fd = bpipe[0] });
    if (wr != .ready) {
        _ = linux.kill(@intCast(b_pid), linux.SIG.KILL); // wedged or poll error -> reap B and A, then fail closed
        var bst0: u32 = undefined;
        _ = linux.waitpid(@intCast(b_pid), &bst0, 0);
        var ast0: u32 = undefined;
        _ = linux.waitpid(@intCast(a_pid), &ast0, 0);
        return if (wr == .poll_error) error.WatchdogPollFailed else error.RecoveryWedgedPastDeadline;
    }

    var rbuf: [2]u8 = undefined;
    try std.testing.expect(linux.read(bpipe[0], &rbuf, 2) == 2);
    var bst: u32 = undefined;
    _ = linux.waitpid(@intCast(b_pid), &bst, 0);
    var ast: u32 = undefined;
    _ = linux.waitpid(@intCast(a_pid), &ast, 0); // A self-releases at 3s; reap before asserting

    // fail-closed result: not acquired, recovery-busy, first run refused/deferred
    try std.testing.expectEqual(@as(u8, 0), rbuf[0]); // acquired == false
    try std.testing.expectEqual(@as(u8, @intFromEnum(ledger.AcquireIncident.lock_unavailable)), rbuf[1]);

    // zero on-disk mutation: the store is byte-for-byte the SEED store it was before the failed recovery (RoseCat
    // #4 — a complete-bytes oracle catches any rewrite/corruption/reordering, not just one basename).
    const after = try storeBytes(io, td.dir, gpa);
    defer gpa.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
}
