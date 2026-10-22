//! MS6.5.1 OPEN whole-recovery blocker bd zigBrowser-3gl, 7b29fd6 item 1 (the exact-result two-recoverer oracle).
//! UNREGISTERED, TEST-ONLY PROTOTYPE — there is NO production recovery transaction, and none is added until every
//! zigBrowser-3gl item lands and the destructive gate is reviewed. `protoRecoverOneUnderLock` lives only here,
//! built from the public ledger API (acquireLock / load / probeLivenessTagged / recoveryFor / publish); the
//! early-unlock policy is a test-only INJECTED argument, never a production switch or a flipped const (RoseCat
//! 7719). A green of this prototype proves only the flock HOLD BOUNDARY; it does not arm or close whole recovery.
//!
//! BOTH causal branches are proven as distinct scenarios (RoseCat 7719):
//!   * held-lock green  — one process owns the flock across read -> revalidate -> signal -> retire, releasing only
//!     after the publish result. Two recoverers racing ONE proved-dead entry yield the EXACT pair
//!     {.signalled, .already_gone}, exactly ONE signal phase (one reap), an EMPTY final ledger, and two terminal
//!     children. Recoverer 2 learns `.already_gone` ONLY after it acquires the released flock and reloads the
//!     retired state.
//!   * early-unlock mutant — releasing the flock right after the read lets BOTH recoverers enter the signal phase:
//!     two reaps, both `.signalled`. The oracle (one reap) fails, so the mutant is caught.
//!
//! DETERMINISM via a HANDSHAKE, not a timing window (RoseCat 7679): recoverer 1 reads, signals "read done", then
//! BLOCKS until the parent says proceed. The handshake is itself the oracle (RoseCat 7706/7719):
//!   * R1's read-done is always present=1.
//!   * mutant: R2 acquires the released flock and its read-done arrives present=1 BEFORE R1 is released.
//!   * held-lock: R2 blocks on the held flock, so its read-done CANNOT arrive before release; after R1 retires it
//!     arrives present=0 and yields `.already_gone`.
//! No path depends on host speed. Every fork/signal is gated by a kernel-proof PID-ns sentinel (fd 9); the build
//! runner wraps the step in a private user+PID namespace. Parent waits/reads/polls are bounded against an absolute
//! monotonic deadline (reusing the reviewed `waitWithinDeadline`); every unused pipe end is closed in the parent
//! and each child; children are reaped within a deadline and otherwise SIGKILLed and reaped unconditionally.
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

// Bounds (absolute monotonic deadlines are computed from these at each wait).
const READ_BUDGET_MS: i64 = 5000; // a read-done/result byte that should already be available
const PRE_RELEASE_MS: i64 = 1500; // pre-release window: mutant R2 reads in ms; held-lock R2 is blocked -> timeout
const ACQUIRE_BUDGET_MS: i64 = 12000; // held-lock R2 must re-acquire the released flock (bounded retry) then read
const REAP_BUDGET_MS: i64 = 3000; // graceful reap before a forced SIGKILL+reap

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

/// Read exactly `buf.len` bytes, bounded by an absolute monotonic deadline and EINTR-safe: poll readable within the
/// deadline before each read; EOF (n==0), a hard poll error, or the deadline returns false (never an unchecked
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

// ---- bounded child reaping -----------------------------------------------------------------------------------

const Child = struct { pid: i32 = 0, reaped: bool = false, status: u32 = 0 };

/// Force-reap: SIGKILL (idempotent) then an EINTR-safe blocking waitpid. Bounded because the kill guarantees exit.
/// Guards pid <= 1 so a bad pid can never become killpg/kill of the session (MEMORY: mocked pid + killpg logout).
fn forceReap(c: *Child) void {
    if (c.reaped) return;
    if (c.pid <= 1) {
        c.reaped = true;
        return;
    }
    _ = linux.kill(c.pid, linux.SIG.KILL);
    while (true) {
        var st: u32 = 0;
        const rc = linux.waitpid(c.pid, &st, 0);
        if (linux.errno(rc) == .INTR) continue;
        c.status = st;
        c.reaped = true;
        return;
    }
}

/// Reap within a deadline (recording the real exit status), else SIGKILL+reap. Never an unchecked blocking waitpid.
fn reapWithin(clock: ledger.RealClock, c: *Child, deadline_ms: i64) void {
    if (c.reaped) return;
    if (c.pid <= 1) {
        c.reaped = true;
        return;
    }
    while (true) {
        var st: u32 = 0;
        const rc = linux.waitpid(c.pid, &st, WNOHANG);
        switch (linux.errno(rc)) {
            .INTR => continue,
            .SUCCESS => {
                if (rc == @as(usize, @intCast(c.pid))) {
                    c.status = st;
                    c.reaped = true;
                    return;
                }
                // rc == 0: not exited yet
            },
            else => {
                c.reaped = true; // ECHILD etc. -> nothing to reap
                return;
            },
        }
        if (clock.nowMs() >= deadline_ms) break;
        var ts: linux.timespec = .{ .sec = 0, .nsec = 2_000_000 };
        _ = linux.nanosleep(&ts, &ts);
    }
    forceReap(c);
}

fn cleanupChildren(children: []Child) void {
    for (children) |*c| forceReap(c);
}

// ---- the prototype transaction (test-only) -------------------------------------------------------------------

const ProtoAction = enum { signalled, left, fail_closed, already_gone };

/// Handshake seam. `readdone_fd`: write the one-byte present flag when the read completes (-1 = skip). `proceed_fd`:
/// if >= 0, BLOCK (EINTR-safe) reading one byte before the signal phase, so recoverer 1 parks until the parent
/// releases it. On EOF (the parent closed `go` during cleanup) R1 simply proceeds and the test then reaps it.
const Ops = struct {
    readdone_fd: i32,
    proceed_fd: i32,
    reaped: *bool,
    pub fn afterRead(self: Ops, present: bool) void {
        if (self.readdone_fd >= 0) {
            const b = [1]u8{if (present) 1 else 0};
            writeAll(self.readdone_fd, &b);
        }
        if (self.proceed_fd >= 0) {
            var b: [1]u8 = undefined;
            while (true) {
                const n = linux.read(self.proceed_fd, &b, 1);
                if (linux.errno(n) == .INTR) continue; // EINTR-safe
                break; // one byte, or EOF -> release into the signal phase
            }
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
/// -> retire, releasing only after the publish result via the defer (the green boundary).
fn protoRecoverOneUnderLock(io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir, basename: []const u8, max_tries: u32, backoff_ms: i64, ops: Ops, early_unlock: bool) ProtoAction {
    var lock = ledger.acquireLock(io, dir, max_tries, backoff_ms) catch return .fail_closed;
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

fn runRecoverer(io: std.Io, dir: std.Io.Dir, readdone_fd: i32, proceed_fd: i32, result_fd: i32, early_unlock: bool) noreturn {
    var reaped = false;
    const act = protoRecoverOneUnderLock(io, std.heap.page_allocator, dir, BASENAME, 2000, 5, Ops{ .readdone_fd = readdone_fd, .proceed_fd = proceed_fd, .reaped = &reaped }, early_unlock);
    const b = [2]u8{ @intFromEnum(act), if (reaped) 1 else 0 };
    writeAll(result_fd, &b);
    linux.exit_group(0);
}

fn terminal0(status: u32) bool {
    return (status & 0x7f) == 0 and ((status >> 8) & 0xff) == 0; // WIFEXITED && code == 0
}

// ---- the scenario (shared by both branches) ------------------------------------------------------------------

/// Run one two-recoverer race under the injected `early_unlock` policy and assert the full branch oracle. All parent
/// waits/reads are bounded; every unused pipe end is closed in the parent and each child; both children are reaped
/// within a deadline and otherwise SIGKILLed+reaped by the unconditional cleanup defer behind the fd-9 sentinel.
fn runScenario(early_unlock: bool) !void {
    if (!inPrivatePidNamespace()) return error.NotInPrivatePidNamespace;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const clock = ledger.RealClock{ .io = io };

    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    const seed = [_]ledger.Entry{.{ .basename = BASENAME, .dev = 1, .ino = 2, .uid = 0, .mode = 16832, .pid = DEAD_PID, .start_kind = .linux_ticks, .start_sec = 123456, .start_usec = 0, .state = .active }};
    try ledger.publish(io, td.dir, "runs.json", &seed);

    var b1rd: [2]i32 = undefined; // R1 -> parent  "read done"
    var b1go: [2]i32 = undefined; // parent -> R1  "proceed"
    var b2rd: [2]i32 = undefined; // R2 -> parent  "read done"
    var b1res: [2]i32 = undefined; // R1 -> parent  result
    var b2res: [2]i32 = undefined; // R2 -> parent  result
    for ([_]*[2]i32{ &b1rd, &b1go, &b2rd, &b1res, &b2res }) |p| {
        if (linux.pipe(p) != 0) return error.PipeFailed;
    }
    // Close EVERY pipe end on EVERY exit path exactly once (closeAndClear skips an already-closed -1 end). Child-only
    // ends are closed in the parent immediately after the forks (below); this defer closes whatever remains.
    defer for ([_]*i32{ &b1rd[0], &b1rd[1], &b1go[0], &b1go[1], &b2rd[0], &b2rd[1], &b1res[0], &b1res[1], &b2res[0], &b2res[1] }) |p| closeAndClear(p);

    // Unconditional child cleanup. Registered BEFORE the forks and LIFO-ahead of the fd defer, so a fork/poll/read
    // failure or a failed assertion still SIGKILLs+reaps exactly the fork-returned children (pid still 0 -> skipped).
    var children = [_]Child{ .{}, .{} };
    defer cleanupChildren(&children);

    // Recoverer 1: reads, signals read-done present=1, then BLOCKS on `proceed` before its signal phase.
    const p1 = linux.fork();
    if (linux.errno(p1) != .SUCCESS) return error.ForkFailed;
    if (p1 == 0) {
        for ([_]i32{ b1rd[0], b1go[1], b2rd[0], b2rd[1], b1res[0], b2res[0], b2res[1] }) |fd| _ = linux.close(fd);
        runRecoverer(io, td.dir, b1rd[1], b1go[0], b1res[1], early_unlock);
    }
    children[0] = .{ .pid = @intCast(p1) };

    // Recoverer 2: reads, signals read-done, does NOT wait (proceed = -1).
    const p2 = linux.fork();
    if (linux.errno(p2) != .SUCCESS) return error.ForkFailed; // defer cleanup reaps R1
    if (p2 == 0) {
        for ([_]i32{ b1rd[0], b1rd[1], b1go[0], b1go[1], b2rd[0], b1res[0], b1res[1], b2res[0] }) |fd| _ = linux.close(fd);
        runRecoverer(io, td.dir, b2rd[1], -1, b2res[1], early_unlock);
    }
    children[1] = .{ .pid = @intCast(p2) };

    // Parent closes every child-only end NOW so a child's death produces EOF at the parent (RoseCat 7706 #2).
    for ([_]*i32{ &b1rd[1], &b1go[0], &b2rd[1], &b1res[1], &b2res[1] }) |p| closeAndClear(p);

    // (a) R1 always reads the present entry first: present=1.
    var r1rd: [1]u8 = undefined;
    if (!readExactWithin(clock, b1rd[0], &r1rd, clock.nowMs() + READ_BUDGET_MS)) return error.R1ReadDoneLost;
    try std.testing.expectEqual(@as(u8, 1), r1rd[0]);

    // (b) pre-release window: does R2 reach read-done BEFORE we release R1?
    const pre = ledger.waitWithinDeadline(clock, clock.nowMs() + PRE_RELEASE_MS, RealPoll{ .fd = b2rd[0] });
    if (pre == .poll_error) return error.PreReleasePollFailed;

    if (early_unlock) {
        // MUTANT: R1 released the flock right after its read, so R2 acquires it and reads the STILL-present entry
        // BEFORE R1 is released -> read-done arrives within the window, present=1.
        try std.testing.expectEqual(ledger.WaitResult.ready, pre);
        var r2rd: [1]u8 = undefined;
        if (!readExactWithin(clock, b2rd[0], &r2rd, clock.nowMs() + READ_BUDGET_MS)) return error.R2ReadDoneLost;
        try std.testing.expectEqual(@as(u8, 1), r2rd[0]);
    } else {
        // GREEN: R1 holds the flock, so R2 blocks on acquire and CANNOT read before release -> the window times out.
        try std.testing.expectEqual(ledger.WaitResult.timed_out, pre);
    }

    writeAll(b1go[1], "G"); // release R1 into its signal phase (both branches)

    if (!early_unlock) {
        // GREEN: only AFTER R1 retires + releases does R2 acquire the freed flock, reload the retired state, and
        // read the entry GONE -> present=0 (bounded by the re-acquire retry budget).
        var r2rd: [1]u8 = undefined;
        if (!readExactWithin(clock, b2rd[0], &r2rd, clock.nowMs() + ACQUIRE_BUDGET_MS)) return error.R2ReadDoneLost;
        try std.testing.expectEqual(@as(u8, 0), r2rd[0]);
    }

    var r1: [2]u8 = undefined;
    var r2: [2]u8 = undefined;
    if (!readExactWithin(clock, b1res[0], &r1, clock.nowMs() + READ_BUDGET_MS)) return error.R1ResultLost;
    if (!readExactWithin(clock, b2res[0], &r2, clock.nowMs() + ACQUIRE_BUDGET_MS)) return error.R2ResultLost;

    reapWithin(clock, &children[0], clock.nowMs() + REAP_BUDGET_MS);
    reapWithin(clock, &children[1], clock.nowMs() + REAP_BUDGET_MS);
    try std.testing.expect(terminal0(children[0].status)); // both children exited terminally (status 0)
    try std.testing.expect(terminal0(children[1].status));

    const reaped_sum: u32 = @as(u32, r1[1]) + @as(u32, r2[1]);
    const sig = @intFromEnum(ProtoAction.signalled);
    const gone = @intFromEnum(ProtoAction.already_gone);

    if (early_unlock) {
        // MUTANT oracle: dropping the flock early lets BOTH recoverers enter the signal phase -> TWO reaps. Two
        // signal phases is the deterministic invariant. Their individual return codes are NOT asserted: with the
        // lock gone, the two uncoordinated `publishWithout` writes race, so one can collide and fail-close AFTER
        // reaping -- itself a vivid symptom of releasing the lock before the retirement completes.
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
