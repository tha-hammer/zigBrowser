//! MS6.5.1 OPEN whole-recovery blocker bd zigBrowser-3gl, 7b29fd6 item 1 (the exact-result two-recoverer oracle).
//! UNREGISTERED, TEST-ONLY PROTOTYPE — there is NO production recovery transaction, and none is added until every
//! zigBrowser-3gl item lands and the destructive gate is reviewed. `protoRecoverOneUnderLock` lives only here,
//! built from the public ledger API (acquireWithinDeadline / load / probeLivenessTagged / recoveryFor / publish);
//! the early-unlock policy is a test-only INJECTED argument, never a production switch (RoseCat 7719). A green of
//! this prototype proves only the flock HOLD BOUNDARY; it does not arm or close whole recovery.
//!
//! BOTH causal branches are proven as distinct scenarios (RoseCat 7719):
//!   * held-lock green  — one process owns the flock across read -> revalidate -> signal -> retire, releasing only
//!     after the publish result. Two recoverers racing ONE proved-dead entry yield the EXACT ordered pair
//!     {R1 .signalled, R2 .already_gone}, exactly ONE signal phase (one reap), an EMPTY final ledger, and two
//!     terminal children. R2 learns `.already_gone` ONLY after it acquires the released flock and reloads state.
//!   * early-unlock mutant — releasing the flock right after the read lets BOTH recoverers enter the signal phase:
//!     TWO signal-phase entries (two reaps). This is the stable mutant invariant (not two `.signalled` returns: a
//!     losing unsynchronized publish may fail only AFTER entering the phase — RoseCat accepted 7743).
//!
//! DETERMINISM (RoseCat 7743):
//!   1. R1 is established FIRST: the parent consumes R1's `present=1` read-done BEFORE forking R2, so R1 holds the
//!      flock before R2 exists — causal ordering, not scheduler luck.
//!   2. ONE absolute monotonic terminal deadline is computed once and threaded through every acquire, poll, read
//!      and reap (children acquire with `acquireWithinDeadline` against that same CLOCK_MONOTONIC deadline); no
//!      per-phase budget is renewed. The pre-release handshake uses a short sub-window CAPPED at the terminal
//!      deadline, purely to distinguish the branches.
//!   3. Reaps are bounded and HONEST: WNOHANG until the same deadline; a real observed status is distinguished
//!      from every wait error/timeout (which fail closed), never a fabricated zero. A guarded SIGKILL is followed
//!      by more WNOHANG against the same deadline, never a blocking `waitpid(..,0)`. The private namespace is the
//!      final containment backstop, not a reason for an unbounded in-test wait.
//!   4. Every fd/read exit path is bounded: all pipe ends start at -1 and the close-all cleanup is installed BEFORE
//!      the first `pipe()`, so a partial creation leaks nothing; R1's proceed read is the same bounded exact-read
//!      (EOF/error/deadline distinguished).
//! The handshake is itself the oracle: R1 read present=1; mutant R2 present=1 BEFORE release; held-lock R2 cannot
//! read before release and later reads present=0. Every fork/signal is gated by a kernel-proof PID-ns sentinel
//! (fd 9); the build runner wraps the step in a private user+PID namespace.
const std = @import("std");
const ledger = @import("agent_run_ledger");
const linux = std.os.linux;

const BASENAME = "zigbrowser-agent-424242-00aa00aa00aa00aa";
const DEAD_PID: i32 = 2147483646; // absent + reuse-proof in this fresh PID namespace

const OUTER_NS_FD: i32 = 9;
const NS_GET_NSTYPE: u32 = 0xB703;
const NS_GET_TGID_IN_PIDNS: u32 = 0x8004B709;
const CLONE_NEWPID: usize = 0x20000000;
const AT_EMPTY_PATH: u32 = 0x1000;
const WNOHANG: u32 = 1;

// ONE terminal budget bounds the whole scenario; everything is capped by the single absolute deadline below it.
const TOTAL_BUDGET_MS: i64 = 30000; // generous: R2's held-lock re-acquire waits for R1 to retire, well within this
const PRE_RELEASE_MS: i64 = 1500; // handshake decision sub-window (capped at the terminal deadline)
const BACKOFF_MS: i64 = 5;

fn nsIno(dirfd: i32, path: [*:0]const u8, flags: u32) ?u64 {
    var sx: linux.Statx = undefined;
    if (linux.errno(linux.statx(dirfd, path, flags, linux.STATX.BASIC_STATS, &sx)) != .SUCCESS) return null;
    return sx.ino;
}

/// Kernel proof that this process runs in a PID namespace strictly BELOW the launcher's held one (fd 9), before
/// any fork or signal. Fail closed on anything missing/malformed/unsupported (no fork, no signal).
fn inPrivatePidNamespace() bool {
    const ty = linux.ioctl(OUTER_NS_FD, NS_GET_NSTYPE, 0);
    if (linux.errno(ty) != .SUCCESS or ty != CLONE_NEWPID) return false;
    const held = nsIno(OUTER_NS_FD, "", AT_EMPTY_PATH) orelse return false;
    const own = nsIno(linux.AT.FDCWD, "/proc/self/ns/pid", 0) orelse return false;
    if (held == own) return false;
    if (linux.errno(linux.ioctl(OUTER_NS_FD, NS_GET_TGID_IN_PIDNS, @as(usize, @intCast(linux.getpid())))) != .SUCCESS) return false;
    if (linux.getpid() != 1 and linux.getppid() != 1) return false;
    return true;
}

// ---- bounded, EINTR-safe I/O helpers -------------------------------------------------------------------------

/// One 100ms poll slice for `waitWithinDeadline`, decoded against the fd's revents: data -> ready, slice elapsed
/// -> again, interrupted -> eintr, any other error -> err (fail closed). Both the rc and `revents` are checked.
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

/// EINTR-safe write of a whole buffer (pipe writes of a byte or two never block here).
fn writeAll(fd: i32, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = linux.write(fd, bytes.ptr + off, bytes.len - off);
        switch (linux.errno(n)) {
            .SUCCESS => {
                if (n == 0) return;
                off += @intCast(n);
            },
            .INTR => {},
            else => return,
        }
    }
}

/// Read exactly `buf.len` bytes, bounded by the absolute monotonic deadline and EINTR-safe: poll readable within
/// the deadline before each read; EOF (n==0), a hard poll error, or the deadline returns false (never an unchecked
/// blocking read).
fn readExactWithin(clock: ledger.RealClock, fd: i32, buf: []u8, deadline_ms: i64) bool {
    var off: usize = 0;
    while (off < buf.len) {
        if (ledger.waitWithinDeadline(clock, deadline_ms, RealPoll{ .fd = fd }) != .ready) return false;
        const n = linux.read(fd, buf.ptr + off, buf.len - off);
        switch (linux.errno(n)) {
            .SUCCESS => {
                if (n == 0) return false; // EOF: the writer died without writing
                off += @intCast(n);
            },
            .INTR => {},
            else => return false,
        }
    }
    return true;
}

fn closeAndClear(p: *i32) void {
    if (p.* >= 0) {
        _ = linux.close(p.*);
        p.* = -1;
    }
}

// ---- bounded, honest child reaping ---------------------------------------------------------------------------

const Child = struct { pid: i32 = -1, reaped: bool = false, status: u32 = 0 };

/// One WNOHANG sweep until the deadline. Returns the REAL observed status, or null if the child has not been
/// observed to exit by the deadline OR a wait error occurs (fail closed — never a fabricated zero).
fn sweepUntil(clock: ledger.RealClock, c: *Child, deadline_ms: i64) ?u32 {
    while (true) {
        var st: u32 = 0;
        const rc = linux.waitpid(c.pid, &st, WNOHANG);
        switch (linux.errno(rc)) {
            .INTR => continue,
            .SUCCESS => {
                if (rc == @as(usize, @intCast(c.pid))) {
                    c.reaped = true;
                    c.status = st;
                    return st; // a real, observed exit status
                }
                // rc == 0: not exited yet -> fall through to the deadline check
            },
            else => return null, // ECHILD/other wait error -> fail closed, do NOT mark reaped
        }
        if (clock.nowMs() >= deadline_ms) return null; // timed out -> fail closed
        var ts: linux.timespec = .{ .sec = 0, .nsec = 2_000_000 };
        _ = linux.nanosleep(&ts, &ts);
    }
}

/// Reap within the single absolute deadline, returning the real observed status or null (timeout/wait-error ->
/// fail closed). A graceful sweep first; then a guarded SIGKILL followed by more WNOHANG against the SAME deadline
/// (never a blocking `waitpid(..,0)`). pid<=1 is refused so a bad pid can never become kill of the session.
fn reapWithin(clock: ledger.RealClock, c: *Child, deadline_ms: i64) ?u32 {
    if (c.reaped) return c.status;
    if (c.pid <= 1) return null;
    if (sweepUntil(clock, c, deadline_ms)) |st| return st;
    _ = linux.kill(c.pid, linux.SIG.KILL);
    return sweepUntil(clock, c, deadline_ms);
}

/// Unconditional containment backstop: guarded SIGKILL + a SINGLE non-blocking WNOHANG. Whatever is still alive is
/// left to the private-namespace teardown. Never blocks, never asserts.
fn cleanupChildren(children: []Child) void {
    for (children) |*c| {
        if (c.reaped or c.pid <= 1) continue;
        _ = linux.kill(c.pid, linux.SIG.KILL);
        var st: u32 = 0;
        const rc = linux.waitpid(c.pid, &st, WNOHANG);
        if (linux.errno(rc) == .SUCCESS and rc == @as(usize, @intCast(c.pid))) c.reaped = true;
    }
}

// ---- the prototype transaction (test-only) -------------------------------------------------------------------

const ProtoAction = enum { signalled, left, fail_closed, already_gone };

/// One non-blocking flock attempt for `acquireWithinDeadline` (the ledger's own `FlockAttempt` is private).
const LockAttempt = struct {
    fd: i32,
    pub fn tryOnce(self: LockAttempt) ledger.AcquireResult {
        return switch (std.posix.errno(std.posix.system.flock(self.fd, std.posix.LOCK.EX | std.posix.LOCK.NB))) {
            .SUCCESS => .acquired,
            .AGAIN => .busy,
            else => .failed,
        };
    }
};

/// Deadline-bounded flock acquire on a freshly opened O_NOFOLLOW|O_CLOEXEC lock fd, against the SHARED absolute
/// monotonic deadline (CLOCK_MONOTONIC is system-wide, so the children honour the same terminal deadline). Returns
/// the held fd (close to release) or null on busy/failed/deadline.
fn acquireLockByDeadline(dir: std.Io.Dir, clock: ledger.RealClock, deadline_ms: i64) ?std.Io.File {
    const fd = std.posix.openat(dir.handle, ledger.LOCK_NAME, .{ .ACCMODE = .RDWR, .CREAT = true, .NOFOLLOW = true, .CLOEXEC = true }, 0o600) catch return null;
    switch (ledger.acquireWithinDeadline(clock, deadline_ms, BACKOFF_MS, LockAttempt{ .fd = fd })) {
        .acquired => return .{ .handle = fd, .flags = .{ .nonblocking = false } },
        else => {
            _ = std.posix.system.close(fd);
            return null;
        },
    }
}

/// Handshake seam. `readdone_fd`: write the one-byte present flag when the read completes (-1 = skip). `proceed_fd`:
/// if >= 0, BLOCK (bounded exact-read against the terminal deadline) reading one byte before the signal phase, so
/// recoverer 1 parks until the parent releases it. On EOF/error/deadline R1 simply proceeds and the test reaps it.
const Ops = struct {
    readdone_fd: i32,
    proceed_fd: i32,
    clock: ledger.RealClock,
    deadline_ms: i64,
    reaped: *bool,
    pub fn afterRead(self: Ops, present: bool) void {
        if (self.readdone_fd >= 0) {
            const b = [1]u8{if (present) 1 else 0};
            writeAll(self.readdone_fd, &b);
        }
        if (self.proceed_fd >= 0) {
            var b: [1]u8 = undefined;
            _ = readExactWithin(self.clock, self.proceed_fd, &b, self.deadline_ms); // bounded; EOF/error/deadline -> proceed
        }
    }
    pub fn reap(self: Ops) void {
        self.reaped.* = true;
    }
};

fn indexOf(l: *const ledger.Ledger, basename: []const u8) ?usize {
    for (l.entries(), 0..) |e, i| if (std.mem.eql(u8, e.basename, basename)) return i;
    return null;
}

fn publishWithout(io: std.Io, dir: std.Io.Dir, sub_path: []const u8, l: *const ledger.Ledger, basename: []const u8) !void {
    var buf: [256]ledger.Entry = undefined;
    var n: usize = 0;
    for (l.entries()) |e| {
        if (std.mem.eql(u8, e.basename, basename)) continue;
        buf[n] = e;
        n += 1;
    }
    try ledger.publish(io, dir, sub_path, buf[0..n]);
}

/// TEST-ONLY prototype. `early_unlock` is an INJECTED mutant policy, not a production switch: when true it releases
/// the flock right after the read (the mutant); when false it holds the flock across read -> revalidate -> signal
/// -> retire, releasing only after the publish result via the defer (the green boundary). The acquire, the parked
/// read and the publish are all bounded by the shared absolute `deadline_ms`.
fn protoRecoverOneUnderLock(io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir, basename: []const u8, clock: ledger.RealClock, deadline_ms: i64, ops: Ops, early_unlock: bool) ProtoAction {
    var lock = acquireLockByDeadline(dir, clock, deadline_ms) orelse return .fail_closed;
    var l = ledger.load(io, gpa, dir, "runs.json") catch {
        lock.close(io);
        return .fail_closed;
    };
    defer l.deinit();
    const idx = indexOf(&l, basename);
    if (early_unlock) lock.close(io); // MUTANT: release right after the read
    defer if (!early_unlock) lock.close(io); // GREEN: hold across the whole recovery
    ops.afterRead(idx != null);
    if (idx == null) return .already_gone;
    const e = l.entries()[idx.?];
    switch (ledger.recoveryFor(ledger.probeLivenessTagged(e.pid, e.start_kind, e.start_sec, e.start_usec))) {
        .leave => return .left,
        .fail_closed => return .fail_closed,
        .recover => {
            ops.reap();
            publishWithout(io, dir, "runs.json", &l, basename) catch return .fail_closed;
            return .signalled;
        },
    }
}

fn runRecoverer(io: std.Io, dir: std.Io.Dir, readdone_fd: i32, proceed_fd: i32, result_fd: i32, clock: ledger.RealClock, deadline_ms: i64, early_unlock: bool) noreturn {
    var reaped = false;
    const act = protoRecoverOneUnderLock(io, std.heap.page_allocator, dir, BASENAME, clock, deadline_ms, Ops{ .readdone_fd = readdone_fd, .proceed_fd = proceed_fd, .clock = clock, .deadline_ms = deadline_ms, .reaped = &reaped }, early_unlock);
    const b = [2]u8{ @intFromEnum(act), if (reaped) 1 else 0 };
    writeAll(result_fd, &b);
    linux.exit_group(0);
}

fn terminal0(status: u32) bool {
    return (status & 0x7f) == 0 and ((status >> 8) & 0xff) == 0; // WIFEXITED && code == 0
}

// ---- the scenario (shared by both branches) ------------------------------------------------------------------

/// Run one two-recoverer race under the injected `early_unlock` policy and assert the full branch oracle. R1 is
/// established first; one absolute terminal deadline bounds everything; every unused pipe end is closed in the
/// parent and each child; reaps are bounded and distinguish a real status from timeout/error; the unconditional
/// cleanup is the private-namespace backstop.
fn runScenario(early_unlock: bool) !void {
    if (!inPrivatePidNamespace()) return error.NotInPrivatePidNamespace;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const clock = ledger.RealClock{ .io = io };
    const terminal = clock.nowMs() + TOTAL_BUDGET_MS; // the ONE absolute monotonic deadline for the whole scenario

    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    const seed = [_]ledger.Entry{.{ .basename = BASENAME, .dev = 1, .ino = 2, .uid = 0, .mode = 16832, .pid = DEAD_PID, .start_kind = .linux_ticks, .start_sec = 123456, .start_usec = 0, .state = .active }};
    try ledger.publish(io, td.dir, "runs.json", &seed);

    // All pipe ends start at -1 and the close-all cleanup is installed BEFORE the first pipe(), so a PARTIAL
    // creation leaks nothing (RoseCat 7743 #4). closeAndClear skips an already-closed -1 end.
    var b1rd = [2]i32{ -1, -1 }; // R1 -> parent  "read done"
    var b1go = [2]i32{ -1, -1 }; // parent -> R1  "proceed"
    var b2rd = [2]i32{ -1, -1 }; // R2 -> parent  "read done"
    var b1res = [2]i32{ -1, -1 }; // R1 -> parent  result
    var b2res = [2]i32{ -1, -1 }; // R2 -> parent  result
    defer for ([_]*i32{ &b1rd[0], &b1rd[1], &b1go[0], &b1go[1], &b2rd[0], &b2rd[1], &b1res[0], &b1res[1], &b2res[0], &b2res[1] }) |p| closeAndClear(p);

    // Child cleanup is the containment backstop; registered after the fd defer so (LIFO) children are SIGKILLed
    // before the fds are closed, and before any fork so a partial setup still reaps (pid -1 -> skipped).
    var children = [_]Child{ .{}, .{} };
    defer cleanupChildren(&children);

    for ([_]*[2]i32{ &b1rd, &b1go, &b2rd, &b1res, &b2res }) |p| {
        if (linux.pipe(p) != 0) return error.PipeFailed; // partial failure -> the fd defer closes whatever opened
    }

    // Recoverer 1: reads, signals read-done present=1, then BLOCKS on `proceed` before its signal phase.
    const p1 = linux.fork();
    if (linux.errno(p1) != .SUCCESS) return error.ForkFailed;
    if (p1 == 0) {
        for ([_]i32{ b1rd[0], b1go[1], b2rd[0], b2rd[1], b1res[0], b2res[0], b2res[1] }) |fd| _ = linux.close(fd);
        runRecoverer(io, td.dir, b1rd[1], b1go[0], b1res[1], clock, terminal, early_unlock);
    }
    children[0] = .{ .pid = @intCast(p1) };
    // Parent closes R1's child-only ends NOW so R1's death EOFs and R2 never inherits them (RoseCat 7743 #1/#4).
    for ([_]*i32{ &b1rd[1], &b1go[0], &b1res[1] }) |p| closeAndClear(p);

    // (1) ESTABLISH R1 FIRST: consume R1's present=1 read-done BEFORE forking R2, so R1 holds the flock before R2
    // exists. This makes the named ordering causal, not scheduler luck (RoseCat 7743 #1).
    var r1rd: [1]u8 = undefined;
    if (!readExactWithin(clock, b1rd[0], &r1rd, terminal)) return error.R1ReadDoneLost;
    try std.testing.expectEqual(@as(u8, 1), r1rd[0]);

    // Recoverer 2: reads, signals read-done, does NOT wait (proceed = -1). Forked only after R1 is established.
    const p2 = linux.fork();
    if (linux.errno(p2) != .SUCCESS) return error.ForkFailed; // defer cleanup reaps R1
    if (p2 == 0) {
        for ([_]i32{ b1rd[0], b1go[1], b2rd[0], b1res[0], b2res[0] }) |fd| _ = linux.close(fd);
        runRecoverer(io, td.dir, b2rd[1], -1, b2res[1], clock, terminal, early_unlock);
    }
    children[1] = .{ .pid = @intCast(p2) };
    for ([_]*i32{ &b2rd[1], &b2res[1] }) |p| closeAndClear(p);

    // (2) pre-release handshake window: does R2 reach read-done BEFORE we release R1? Bounded by a short sub-window
    // CAPPED at the single terminal deadline (never a renewed per-phase budget).
    const pre_deadline = @min(clock.nowMs() + PRE_RELEASE_MS, terminal);
    const pre = ledger.waitWithinDeadline(clock, pre_deadline, RealPoll{ .fd = b2rd[0] });
    if (pre == .poll_error) return error.PreReleasePollFailed;

    if (early_unlock) {
        // MUTANT: R1 released the flock right after its read, so R2 acquires it and reads the STILL-present entry
        // BEFORE R1 is released -> read-done arrives within the window, present=1.
        try std.testing.expectEqual(ledger.WaitResult.ready, pre);
        var r2rd: [1]u8 = undefined;
        if (!readExactWithin(clock, b2rd[0], &r2rd, terminal)) return error.R2ReadDoneLost;
        try std.testing.expectEqual(@as(u8, 1), r2rd[0]);
    } else {
        // GREEN: R1 holds the flock, so R2 blocks on the deadline-bounded acquire and CANNOT read before release
        // -> the window times out.
        try std.testing.expectEqual(ledger.WaitResult.timed_out, pre);
    }

    writeAll(b1go[1], "G"); // release R1 into its signal phase (both branches)

    if (!early_unlock) {
        // GREEN: only AFTER R1 retires + releases does R2 acquire the freed flock, reload the retired state, and
        // read the entry GONE -> present=0 (bounded by the same terminal deadline).
        var r2rd: [1]u8 = undefined;
        if (!readExactWithin(clock, b2rd[0], &r2rd, terminal)) return error.R2ReadDoneLost;
        try std.testing.expectEqual(@as(u8, 0), r2rd[0]);
    }

    var r1: [2]u8 = undefined;
    var r2: [2]u8 = undefined;
    if (!readExactWithin(clock, b1res[0], &r1, terminal)) return error.R1ResultLost;
    if (!readExactWithin(clock, b2res[0], &r2, terminal)) return error.R2ResultLost;

    // (3) bounded, honest reaps against the SAME terminal deadline; a real status, never a fabricated zero.
    const st0 = reapWithin(clock, &children[0], terminal) orelse return error.R1ReapFailed;
    const st1 = reapWithin(clock, &children[1], terminal) orelse return error.R2ReapFailed;
    try std.testing.expect(terminal0(st0)); // both children exited terminally (status 0)
    try std.testing.expect(terminal0(st1));

    const reaped_sum: u32 = @as(u32, r1[1]) + @as(u32, r2[1]);
    const sig = @intFromEnum(ProtoAction.signalled);
    const gone = @intFromEnum(ProtoAction.already_gone);

    if (early_unlock) {
        // MUTANT oracle: dropping the flock early lets BOTH recoverers enter the signal phase -> TWO reaps. Two
        // signal phases is the deterministic invariant; individual return codes are NOT asserted (the two
        // uncoordinated publishes race, so a loser can fail-close AFTER reaping).
        try std.testing.expectEqual(@as(u32, 2), reaped_sum);
    } else {
        // GREEN oracle: exactly ONE signal phase; the exact ordered pair {R1 .signalled, R2 .already_gone}; empty
        // final ledger. R2 is `.already_gone` precisely because it could only read after R1 retired the entry.
        try std.testing.expectEqual(@as(u32, 1), reaped_sum);
        try std.testing.expectEqual(@as(u8, sig), r1[0]);
        try std.testing.expectEqual(@as(u8, gone), r2[0]);
        var l = try ledger.load(io, gpa, td.dir, "runs.json");
        defer l.deinit();
        try std.testing.expectEqual(@as(usize, 0), l.entries().len);
    }
}

test "held-lock green: exact {signalled, already_gone}, one signal phase, empty ledger; R2 learns gone only after release" {
    try runScenario(false);
}

test "early-unlock mutant: both recoverers reach the signal phase (two reaps); R2 reads present=1 before release" {
    try runScenario(true);
}
