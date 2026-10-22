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
//!     TWO signal-phase entries (two reaps). This is the stable mutant invariant (RoseCat accepted 7743).
//!
//! DETERMINISM + LIFECYCLE, with CAUSAL injected coverage for each safety property (RoseCat 7743/7749):
//!   1. R1 is established FIRST: the parent consumes R1's `present=1` read-done BEFORE forking R2. The proceed
//!      handshake read is CHECKED: EOF/error/deadline makes R1 fail closed (it does NOT enter liveness/reap/
//!      publish). Pinned by the "dropped handshake" scenario.
//!   2. ONE absolute monotonic terminal deadline, computed once and threaded through every acquire/poll/read/reap;
//!      children acquire with `acquireWithinDeadline` against that same CLOCK_MONOTONIC deadline. The pre-release
//!      handshake uses a short sub-window CAPPED at the terminal deadline.
//!   3. Reaps go through an INJECTABLE waiter. A real observed status is distinguished from a hard wait error
//!      (fail closed, never a fabricated zero) and from a timeout (bounded); after a guarded SIGKILL it keeps
//!      sweeping WNOHANG against the same deadline, never a blocking `waitpid(..,0)`. Pinned by the wait-error,
//!      never-exits and exit-only-after-kill reap rows.
//!   4. Pipe creation goes through an INJECTABLE maker with all ends pre-set to -1 and the prefix cleaned on a
//!      partial failure. Pinned by the partial-creation row.
//! Every fork/signal is gated by a kernel-proof PID-ns sentinel (fd 9); the build runner wraps the step in a
//! private user+PID namespace. The reap/pipe unit rows inject fakes and send no real signal, so they are sentinel-
//! independent.
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
const F_GETFD: i32 = 1;

const TOTAL_BUDGET_MS: i64 = 30000; // the ONE terminal budget; R2's held-lock re-acquire waits well within it
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

/// One 100ms poll slice for `waitWithinDeadline`, decoded against the fd's revents: data OR a closed/errored writer
/// (POLLIN | POLLHUP | POLLERR) -> ready, slice elapsed -> again, interrupted -> eintr, a hard poll error -> err
/// (fail closed). Both the rc and `revents` are checked. HUP/ERR count as ready so a closed write end (EOF) is seen
/// PROMPTLY — the following `read` then returns 0 and the caller fails closed, instead of spinning to the deadline.
const RealPoll = struct {
    fd: i32,
    pub fn pollOnce(self: RealPoll) ledger.PollOutcome {
        var pfd = [_]linux.pollfd{.{ .fd = self.fd, .events = linux.POLL.IN, .revents = 0 }};
        const pn = linux.poll(&pfd, 1, 100);
        return switch (linux.errno(pn)) {
            .SUCCESS => if (pn > 0 and (pfd[0].revents & (linux.POLL.IN | linux.POLL.HUP | linux.POLL.ERR)) != 0) .ready else .again,
            .INTR => .eintr,
            else => .err,
        };
    }
};

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

/// Read exactly `buf.len` bytes, bounded by the absolute monotonic deadline and EINTR-safe. Returns false on EOF
/// (n==0), a hard poll error, or the deadline — the CALLER must treat false as fail-closed, never proceed.
fn readExactWithin(clock: anytype, fd: i32, buf: []u8, deadline_ms: i64) bool {
    var off: usize = 0;
    while (off < buf.len) {
        if (ledger.waitWithinDeadline(clock, deadline_ms, RealPoll{ .fd = fd }) != .ready) return false;
        const n = linux.read(fd, buf.ptr + off, buf.len - off);
        switch (linux.errno(n)) {
            .SUCCESS => {
                if (n == 0) return false; // EOF: the writer died/closed without writing
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

// ---- injectable pipe creation (RoseCat 7749 #3: partial-creation prefix cleanup) -----------------------------

const RealMaker = struct {
    pub fn make(_: RealMaker, p: *[2]i32) bool {
        return linux.pipe(p) == 0;
    }
};

/// Initialise every end to -1, then create each pair via the injected `maker`. On the first failure the already
/// created prefix is closed (errdefer) and the error propagates — a partial creation leaks no fd.
fn createAllOrClose(pairs: []const *[2]i32, maker: anytype) !void {
    for (pairs) |p| {
        p[0] = -1;
        p[1] = -1;
    }
    errdefer for (pairs) |p| {
        closeAndClear(&p[0]);
        closeAndClear(&p[1]);
    };
    for (pairs) |p| if (!maker.make(p)) return error.PipeFailed;
}

// ---- injectable, bounded, honest child reaping (RoseCat 7749 #2/#3) ------------------------------------------

const Child = struct { pid: i32 = -1, reaped: bool = false, status: u32 = 0, ownership_lost: bool = false };

/// A sweep's outcome: a real observed exit status, still owned but timed out, or a hard wait error = LOST OWNERSHIP
/// (the pid is no longer this process's child and may be reaped/reused). These are distinct so only a timeout — in
/// which ownership is still proven — may enter the guarded stop path (RoseCat dfaf431).
const SweepResult = union(enum) { exited: u32, timed_out, wait_error };
/// A reap's outcome: a real observed status, or fail-closed (a hard wait error with NO signal, or deadline).
const ReapResult = union(enum) { status: u32, fail_closed };

/// A wait attempt's outcome: a real observed exit status, still running, or a hard wait error (fail closed).
const WaitOutcome = union(enum) { exited: u32, running, wait_error };

/// Production waiter: WNOHANG + guarded SIGKILL + a 2ms nap. EINTR maps to `running` so the deadline loop retries.
const RealWaiter = struct {
    pub fn tryWait(_: RealWaiter, pid: i32) WaitOutcome {
        var st: u32 = 0;
        const rc = linux.waitpid(pid, &st, WNOHANG);
        return switch (linux.errno(rc)) {
            .INTR => .running,
            .SUCCESS => if (rc == @as(usize, @intCast(pid))) .{ .exited = st } else .running,
            else => .wait_error, // ECHILD or any other hard error -> fail closed
        };
    }
    pub fn kill(_: RealWaiter, pid: i32) void {
        _ = linux.kill(pid, linux.SIG.KILL);
    }
    pub fn napMs(_: RealWaiter) void {
        var ts: linux.timespec = .{ .sec = 0, .nsec = 2_000_000 };
        _ = linux.nanosleep(&ts, &ts);
    }
};

/// One WNOHANG sweep until the deadline, with DISTINCT outcomes: a real observed status, a hard wait error (lost
/// ownership), or a timeout with ownership still proven. Never collapses a wait error into a timeout or a status.
fn sweepUntil(clock: anytype, deadline_ms: i64, pid: i32, waiter: anytype) SweepResult {
    while (true) {
        switch (waiter.tryWait(pid)) {
            .exited => |st| return .{ .exited = st },
            .wait_error => return .wait_error,
            .running => {},
        }
        if (clock.nowMs() >= deadline_ms) return .timed_out;
        waiter.napMs();
    }
}

/// Reap within the single absolute deadline. A hard wait error means the pid is NO LONGER our child (it may be
/// reaped/reused): fail CLOSED immediately with NO signal and mark ownership lost — `pid > 1` is not ownership
/// proof (RoseCat dfaf431). ONLY a timeout, in which ownership is still proven, enters the guarded SIGKILL path,
/// then MORE WNOHANG against the SAME deadline (never a blocking `waitpid(..,0)`).
fn reapWithin(clock: anytype, c: *Child, deadline_ms: i64, waiter: anytype) ReapResult {
    if (c.reaped) return .{ .status = c.status };
    if (c.pid <= 1) {
        c.ownership_lost = true; // never a real owned child -> never signal it
        return .fail_closed;
    }
    switch (sweepUntil(clock, deadline_ms, c.pid, waiter)) {
        .exited => |st| {
            c.reaped = true;
            c.status = st;
            return .{ .status = st };
        },
        .wait_error => {
            c.ownership_lost = true; // LOST OWNERSHIP -> fail closed with NO signal (pid may be foreign/reused)
            return .fail_closed;
        },
        .timed_out => {}, // ownership still proven -> fall through to the guarded stop
    }
    waiter.kill(c.pid); // only reached on a proven-owned timeout
    switch (sweepUntil(clock, deadline_ms, c.pid, waiter)) {
        .exited => |st| {
            c.reaped = true;
            c.status = st;
            return .{ .status = st };
        },
        .wait_error => {
            c.ownership_lost = true;
            return .fail_closed;
        },
        .timed_out => return .fail_closed, // still not reaped by the deadline -> bounded fail-closed
    }
}

/// Containment backstop via an injected killer: a guarded SIGKILL + a SINGLE non-blocking wait. An ownership-lost
/// child is NEVER signalled here either, so the fallback cannot undo reapWithin's fail-closed decision (dfaf431).
/// Whatever is still alive is left to the private-namespace teardown. Never blocks, never asserts.
fn cleanupChildren(children: []Child, waiter: anytype) void {
    for (children) |*c| {
        if (c.reaped or c.pid <= 1 or c.ownership_lost) continue;
        waiter.kill(c.pid);
        switch (waiter.tryWait(c.pid)) {
            .exited => c.reaped = true,
            else => {}, // leave to the namespace backstop
        }
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

/// Handshake seam. `afterRead` writes the one-byte present flag, then (if `proceed_fd >= 0`) does a CHECKED bounded
/// read of one proceed byte against the terminal deadline. It returns whether to continue: a real proceed byte (or
/// no wait at all) -> true; EOF/error/deadline -> false, so the caller fails closed (RoseCat 7749 #1).
const Ops = struct {
    readdone_fd: i32,
    proceed_fd: i32,
    clock: ledger.RealClock,
    deadline_ms: i64,
    reaped: *bool,
    pub fn afterRead(self: Ops, present: bool) bool {
        if (self.readdone_fd >= 0) {
            const b = [1]u8{if (present) 1 else 0};
            writeAll(self.readdone_fd, &b);
        }
        if (self.proceed_fd >= 0) {
            var b: [1]u8 = undefined;
            return readExactWithin(self.clock, self.proceed_fd, &b, self.deadline_ms);
        }
        return true;
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

/// TEST-ONLY prototype. `early_unlock` is an INJECTED mutant policy. A failed proceed handshake (afterRead false)
/// fails CLOSED before any liveness/reap/publish. The acquire, the parked read and the publish are all bounded by
/// the shared absolute `deadline_ms`.
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
    if (!ops.afterRead(idx != null)) return .fail_closed; // dropped/failed handshake -> fail closed, NO signal phase
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

// ---- the scenario (shared by the race branches) --------------------------------------------------------------

/// `release` runs the full race; `drop_handshake` closes R1's go pipe instead of releasing it, to pin that a
/// dropped handshake fails R1 closed WITHOUT entering the signal phase (RoseCat 7749 #1).
const Mode = enum { release, drop_handshake };

fn runScenario(early_unlock: bool, mode: Mode) !void {
    if (!inPrivatePidNamespace()) return error.NotInPrivatePidNamespace;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const clock = ledger.RealClock{ .io = io };
    const terminal = clock.nowMs() + TOTAL_BUDGET_MS; // the ONE absolute monotonic deadline for the whole scenario

    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    const seed = [_]ledger.Entry{.{ .basename = BASENAME, .dev = 1, .ino = 2, .uid = 0, .mode = 16832, .pid = DEAD_PID, .start_kind = .linux_ticks, .start_sec = 123456, .start_usec = 0, .state = .active }};
    try ledger.publish(io, td.dir, "runs.json", &seed);

    var b1rd = [2]i32{ -1, -1 }; // R1 -> parent  "read done"
    var b1go = [2]i32{ -1, -1 }; // parent -> R1  "proceed"
    var b2rd = [2]i32{ -1, -1 }; // R2 -> parent  "read done"
    var b1res = [2]i32{ -1, -1 }; // R1 -> parent  result
    var b2res = [2]i32{ -1, -1 }; // R2 -> parent  result
    defer for ([_]*i32{ &b1rd[0], &b1rd[1], &b1go[0], &b1go[1], &b2rd[0], &b2rd[1], &b1res[0], &b1res[1], &b2res[0], &b2res[1] }) |p| closeAndClear(p);
    var children = [_]Child{ .{}, .{} };
    defer cleanupChildren(&children, RealWaiter{});

    try createAllOrClose(&[_]*[2]i32{ &b1rd, &b1go, &b2rd, &b1res, &b2res }, RealMaker{});

    // Recoverer 1: reads, signals read-done present=1, then BLOCKS on `proceed` before its signal phase.
    const p1 = linux.fork();
    if (linux.errno(p1) != .SUCCESS) return error.ForkFailed;
    if (p1 == 0) {
        for ([_]i32{ b1rd[0], b1go[1], b2rd[0], b2rd[1], b1res[0], b2res[0], b2res[1] }) |fd| _ = linux.close(fd);
        runRecoverer(io, td.dir, b1rd[1], b1go[0], b1res[1], clock, terminal, early_unlock);
    }
    children[0] = .{ .pid = @intCast(p1) };
    for ([_]*i32{ &b1rd[1], &b1go[0], &b1res[1] }) |p| closeAndClear(p);

    // (1) ESTABLISH R1 FIRST: consume R1's present=1 read-done BEFORE forking R2.
    var r1rd: [1]u8 = undefined;
    if (!readExactWithin(clock, b1rd[0], &r1rd, terminal)) return error.R1ReadDoneLost;
    try std.testing.expectEqual(@as(u8, 1), r1rd[0]);

    // Positive R1-first invariant (RoseCat 7749 #1): R1 sends present=1 only after taking the flock and reading
    // under it, so in the held-lock case the lock is HELD right now, before R2 exists -- a non-blocking parent
    // probe MUST be busy. (In the early-unlock case R1 has already released and R2 is not yet a contender, so we
    // skip the probe there rather than briefly steal the lock from the about-to-fork R2.)
    if (!early_unlock) {
        const probe_fd = std.posix.openat(td.dir.handle, ledger.LOCK_NAME, .{ .ACCMODE = .RDWR, .CREAT = true, .NOFOLLOW = true, .CLOEXEC = true }, 0o600) catch return error.ProbeOpenFailed;
        const pe = std.posix.errno(std.posix.system.flock(probe_fd, std.posix.LOCK.EX | std.posix.LOCK.NB));
        _ = std.posix.system.close(probe_fd);
        try std.testing.expectEqual(std.posix.E.AGAIN, pe); // R1 holds the flock before R2 is forked
    }

    // Recoverer 2: reads, signals read-done, does NOT wait (proceed = -1). Forked only after R1 is established.
    const p2 = linux.fork();
    if (linux.errno(p2) != .SUCCESS) return error.ForkFailed;
    if (p2 == 0) {
        for ([_]i32{ b1rd[0], b1go[1], b2rd[0], b1res[0], b2res[0] }) |fd| _ = linux.close(fd);
        runRecoverer(io, td.dir, b2rd[1], -1, b2res[1], clock, terminal, early_unlock);
    }
    children[1] = .{ .pid = @intCast(p2) };
    for ([_]*i32{ &b2rd[1], &b2res[1] }) |p| closeAndClear(p);

    // (2) pre-release handshake window, bounded by a short sub-window CAPPED at the single terminal deadline.
    const pre_deadline = @min(clock.nowMs() + PRE_RELEASE_MS, terminal);
    const pre = ledger.waitWithinDeadline(clock, pre_deadline, RealPoll{ .fd = b2rd[0] });
    if (pre == .poll_error) return error.PreReleasePollFailed;

    if (early_unlock) {
        try std.testing.expectEqual(ledger.WaitResult.ready, pre);
        var r2rd: [1]u8 = undefined;
        if (!readExactWithin(clock, b2rd[0], &r2rd, terminal)) return error.R2ReadDoneLost;
        try std.testing.expectEqual(@as(u8, 1), r2rd[0]);
    } else {
        try std.testing.expectEqual(ledger.WaitResult.timed_out, pre);
    }

    if (mode == .drop_handshake) {
        // FINDING 1 (7749 #1): DROP the handshake (close go instead of writing "G"). R1's proceed read EOFs ->
        // afterRead false -> R1 FAILS CLOSED without entering the signal phase.
        closeAndClear(&b1go[1]);
        var r1: [2]u8 = undefined;
        var r2: [2]u8 = undefined;
        if (!readExactWithin(clock, b1res[0], &r1, terminal)) return error.R1ResultLost;
        if (!readExactWithin(clock, b2res[0], &r2, terminal)) return error.R2ResultLost;
        const sd0 = switch (reapWithin(clock, &children[0], terminal, RealWaiter{})) {
            .status => |s| s,
            .fail_closed => return error.R1ReapFailed,
        };
        const sd1 = switch (reapWithin(clock, &children[1], terminal, RealWaiter{})) {
            .status => |s| s,
            .fail_closed => return error.R2ReapFailed,
        };
        try std.testing.expect(terminal0(sd0));
        try std.testing.expect(terminal0(sd1));
        try std.testing.expectEqual(@as(u8, @intFromEnum(ProtoAction.fail_closed)), r1[0]); // R1 fails closed
        try std.testing.expectEqual(@as(u8, 0), r1[1]); // and did NOT enter the signal phase (no reap)
        return;
    }

    writeAll(b1go[1], "G"); // release R1 into its signal phase

    if (!early_unlock) {
        var r2rd: [1]u8 = undefined;
        if (!readExactWithin(clock, b2rd[0], &r2rd, terminal)) return error.R2ReadDoneLost;
        try std.testing.expectEqual(@as(u8, 0), r2rd[0]); // R2 saw the entry GONE only after release
    }

    var r1: [2]u8 = undefined;
    var r2: [2]u8 = undefined;
    if (!readExactWithin(clock, b1res[0], &r1, terminal)) return error.R1ResultLost;
    if (!readExactWithin(clock, b2res[0], &r2, terminal)) return error.R2ResultLost;

    const st0 = switch (reapWithin(clock, &children[0], terminal, RealWaiter{})) {
        .status => |s| s,
        .fail_closed => return error.R1ReapFailed,
    };
    const st1 = switch (reapWithin(clock, &children[1], terminal, RealWaiter{})) {
        .status => |s| s,
        .fail_closed => return error.R2ReapFailed,
    };
    try std.testing.expect(terminal0(st0));
    try std.testing.expect(terminal0(st1));

    const reaped_sum: u32 = @as(u32, r1[1]) + @as(u32, r2[1]);
    const sig = @intFromEnum(ProtoAction.signalled);
    const gone = @intFromEnum(ProtoAction.already_gone);

    if (early_unlock) {
        // MUTANT oracle: two signal phases (two reaps). Individual return codes are not asserted (the two
        // uncoordinated publishes race, so a loser can fail-close AFTER reaping).
        try std.testing.expectEqual(@as(u32, 2), reaped_sum);
    } else {
        // GREEN oracle: one signal phase; exact ordered pair {R1 .signalled, R2 .already_gone}; empty ledger.
        try std.testing.expectEqual(@as(u32, 1), reaped_sum);
        try std.testing.expectEqual(@as(u8, sig), r1[0]);
        try std.testing.expectEqual(@as(u8, gone), r2[0]);
        var l = try ledger.load(io, gpa, td.dir, "runs.json");
        defer l.deinit();
        try std.testing.expectEqual(@as(usize, 0), l.entries().len);
    }
}

test "held-lock green: exact {signalled, already_gone}, one signal phase, empty ledger; R2 learns gone only after release" {
    try runScenario(false, .release);
}

test "early-unlock mutant: both recoverers reach the signal phase (two reaps); R2 reads present=1 before release" {
    try runScenario(true, .release);
}

test "dropped handshake: EOF on the proceed read fails R1 CLOSED without entering the signal phase" {
    try runScenario(false, .drop_handshake);
}

// ---- injected reap/pipe unit rows (no fork, no real signal; sentinel-independent) ----------------------------

/// A monotonic fake clock that advances one tick per read, so a small deadline is reached deterministically.
const FakeClock = struct {
    t: *i64,
    pub fn nowMs(self: FakeClock) i64 {
        const v = self.t.*;
        self.t.* += 1;
        return v;
    }
};

/// Every wait is a hard error (ECHILD-like). Records that a guarded kill was attempted.
const WaitErrorWaiter = struct {
    killed: *bool,
    pub fn tryWait(_: WaitErrorWaiter, pid: i32) WaitOutcome {
        _ = pid;
        return .wait_error;
    }
    pub fn kill(self: WaitErrorWaiter, pid: i32) void {
        _ = pid;
        self.killed.* = true;
    }
    pub fn napMs(_: WaitErrorWaiter) void {}
};

/// Never observes an exit, even after the kill (worst case for a blocking wait).
const NeverExitsWaiter = struct {
    killed: *bool,
    pub fn tryWait(_: NeverExitsWaiter, pid: i32) WaitOutcome {
        _ = pid;
        return .running;
    }
    pub fn kill(self: NeverExitsWaiter, pid: i32) void {
        _ = pid;
        self.killed.* = true;
    }
    pub fn napMs(_: NeverExitsWaiter) void {}
};

/// Runs until killed, then reports a real exit status (proves the post-kill WNOHANG sweep observes the status).
const ExitOnKillWaiter = struct {
    killed: *bool,
    status: u32,
    pub fn tryWait(self: ExitOnKillWaiter, pid: i32) WaitOutcome {
        _ = pid;
        return if (self.killed.*) .{ .exited = self.status } else .running;
    }
    pub fn kill(self: ExitOnKillWaiter, pid: i32) void {
        _ = pid;
        self.killed.* = true;
    }
    pub fn napMs(_: ExitOnKillWaiter) void {}
};

/// A killer that only records the kill (and never observes an exit), for the cleanup-backstop rows.
const RecordingKiller = struct {
    killed: *bool,
    pub fn kill(self: RecordingKiller, pid: i32) void {
        _ = pid;
        self.killed.* = true;
    }
    pub fn tryWait(_: RecordingKiller, pid: i32) WaitOutcome {
        _ = pid;
        return .running;
    }
};

test "reap fails CLOSED on a hard wait error with NO signal (ownership lost; never a fabricated zero)" {
    var t: i64 = 0;
    var killed = false;
    var c = Child{ .pid = 4242 }; // fake pid; the injected waiter never touches a real process
    const got = reapWithin(FakeClock{ .t = &t }, &c, 5, WaitErrorWaiter{ .killed = &killed });
    try std.testing.expect(got == .fail_closed); // fail closed, NOT a fabricated zero status
    try std.testing.expect(!killed); // a lost-ownership pid may be reused/foreign -> it must NEVER be signalled
    try std.testing.expect(c.ownership_lost);
    try std.testing.expect(!c.reaped);
}

test "reap is BOUNDED: a never-exiting (still-owned) wait fail-closes at the deadline AFTER a guarded kill" {
    var t: i64 = 0;
    var killed = false;
    var c = Child{ .pid = 4242 };
    const got = reapWithin(FakeClock{ .t = &t }, &c, 6, NeverExitsWaiter{ .killed = &killed });
    try std.testing.expect(got == .fail_closed); // bounded by the deadline, never a blocking waitpid(..,0)
    try std.testing.expect(killed); // ownership proven by the TIMEOUT -> the guarded kill did happen
    try std.testing.expect(!c.ownership_lost);
    try std.testing.expect(!c.reaped);
}

test "reap observes a real exit status that only appears AFTER the guarded kill (timeout branch)" {
    var t: i64 = 0;
    var killed = false;
    var c = Child{ .pid = 4242 };
    const got = reapWithin(FakeClock{ .t = &t }, &c, 4, ExitOnKillWaiter{ .killed = &killed, .status = 0 });
    try std.testing.expect(got == .status);
    try std.testing.expectEqual(@as(u32, 0), got.status);
    try std.testing.expect(c.reaped);
    try std.testing.expect(killed);
}

test "cleanup NEVER signals an ownership-lost child, but DOES signal a still-owned one" {
    var ka = false;
    var kb = false;
    var lost = [_]Child{.{ .pid = 4242, .ownership_lost = true }};
    var owned = [_]Child{.{ .pid = 4243 }};
    cleanupChildren(&lost, RecordingKiller{ .killed = &ka });
    cleanupChildren(&owned, RecordingKiller{ .killed = &kb });
    try std.testing.expect(!ka); // ownership lost in reapWithin -> the fallback cleanup must NOT undo that with a kill
    try std.testing.expect(kb); // a still-owned leftover child IS given the guarded SIGKILL
}

/// Succeeds until the `fail_at`-th call, recording each created fd so the test can prove it was later closed.
const FailAtMaker = struct {
    fail_at: usize,
    i: *usize,
    rec: *[10]i32,
    n: *usize,
    pub fn make(self: FailAtMaker, p: *[2]i32) bool {
        self.i.* += 1;
        if (self.i.* == self.fail_at) return false; // simulate pipe() failure WITHOUT creating fds
        if (linux.pipe(p) != 0) return false;
        self.rec[self.n.*] = p[0];
        self.n.* += 1;
        self.rec[self.n.*] = p[1];
        self.n.* += 1;
        return true;
    }
};

test "partial pipe creation closes every successfully created prefix (no fd leak)" {
    var b1 = [2]i32{ -1, -1 };
    var b2 = [2]i32{ -1, -1 };
    var b3 = [2]i32{ -1, -1 };
    var b4 = [2]i32{ -1, -1 };
    var b5 = [2]i32{ -1, -1 };
    var i: usize = 0;
    var rec = [_]i32{-1} ** 10;
    var n: usize = 0;
    const err = createAllOrClose(&[_]*[2]i32{ &b1, &b2, &b3, &b4, &b5 }, FailAtMaker{ .fail_at = 3, .i = &i, .rec = &rec, .n = &n });
    try std.testing.expectError(error.PipeFailed, err);
    // pairs 1 and 2 were created (4 fds recorded); each must now be CLOSED by the prefix cleanup.
    try std.testing.expectEqual(@as(usize, 4), n);
    for (rec[0..n]) |fd| {
        try std.testing.expect(fd >= 0);
        try std.testing.expectEqual(linux.E.BADF, linux.errno(linux.fcntl(fd, F_GETFD, 0))); // closed
    }
    // the failed/untouched pairs stay -1 (never opened).
    for ([_][2]i32{ b3, b4, b5 }) |pr| {
        try std.testing.expectEqual(@as(i32, -1), pr[0]);
        try std.testing.expectEqual(@as(i32, -1), pr[1]);
    }
}
