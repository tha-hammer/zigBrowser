//! MS6.5.1 OPEN whole-recovery blocker bd zigBrowser-3gl, 7b29fd6 item 1 — reds/greens for the REAL PRODUCTION
//! transaction `recoverOneUnderLock` (file-private in agent_run_recovery.zig, reached here through its test-build-only
//! `test_support`; NOT the test-only prototype). Registered (step `test-agent-run-ledger-recovery-txn`, in `test`,
//! 4pa.71) and UNARMED (no production caller; `reaper_ready` false). The held-flock design is RoseCat b2f474b /
//! 62888b1; the deadline authority, tagged
//! pin outcome, idempotent teardown and crash-cut handling answer RoseCat 9f62ea4 #2/#3.
//!
//! The destructive action is reached ONLY through a typed lease that RETAINS the pinned run-dir fd (so the
//! provenance check and teardown cannot be split by a path swap). The injected `actuator.pin` returns a TAGGED
//! result {held, gone, mismatch, unreadable}; the `held` lease exposes `fixedPoint`, `teardown`, `deinit`. These
//! tests inject a deterministic, SIGNAL-FREE fake. (Finding 9f62ea4 #1/#4 — a CONCRETE lease wrapping the reviewed
//! reaper C path, an intercepted real marked-child action count, the early-unlock mutant and a held-fd path-swap
//! mutant — are the next step; this signal-free fake does not yet prove a real kill phase.)
//!
//! Every fork/signal is gated by the kernel-proof fd-9 PID-ns sentinel; its build step runs it in a private user+PID
//! namespace, holding the outer PID namespace as fd 9 and keeping the test's exit status. Parent reads/reaps are bounded on one absolute monotonic deadline; children are
//! reaped within it, else SIGKILLed+reaped (only proven-owned); an ownership-lost pid is never signalled.
const std = @import("std");
const ledger = @import("agent_run_ledger");
const recovery = @import("agent_run_recovery");
const linux = std.os.linux;

const BASENAME = "zigbrowser-agent-2147483645-00bb00bb00bb00bb"; // its pid is DEAD_PID, as a ledger entry requires
const STORE = "zigbrowser-agent-runs.json"; // the ledger's real store name (4pa.65)
const DEAD_PID: i32 = 2147483645; // absent + reuse-proof in this fresh PID namespace

const OUTER_NS_FD: i32 = 9;
const NS_GET_NSTYPE: u32 = 0xB703;
const NS_GET_TGID_IN_PIDNS: u32 = 0x8004B709;
const CLONE_NEWPID: usize = 0x20000000;
const AT_EMPTY_PATH: u32 = 0x1000;
const WNOHANG: u32 = 1;

const TOTAL_BUDGET_MS: i64 = 30000; // the ONE absolute monotonic deadline for the whole scenario
const REAP_BUDGET_MS: i64 = 3000;

fn nsIno(dirfd: i32, path: [*:0]const u8, flags: u32) ?u64 {
    var sx: linux.Statx = undefined;
    if (linux.errno(linux.statx(dirfd, path, flags, linux.STATX.BASIC_STATS, &sx)) != .SUCCESS) return null;
    return sx.ino;
}

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

// ---- bounded, EINTR-safe reads + honest reaps (same shapes proven in the prototype) --------------------------

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

fn readExactWithin(clock: anytype, fd: i32, buf: []u8, deadline_ms: i64) bool {
    var off: usize = 0;
    while (off < buf.len) {
        if (ledger.waitWithinDeadline(clock, deadline_ms, RealPoll{ .fd = fd }) != .ready) return false;
        const n = linux.read(fd, buf.ptr + off, buf.len - off);
        switch (linux.errno(n)) {
            .SUCCESS => {
                if (n == 0) return false;
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

const Child = struct { pid: i32 = -1, reaped: bool = false, status: u32 = 0, ownership_lost: bool = false };
const WaitOutcome = union(enum) { exited: u32, running, wait_error };
const SweepResult = union(enum) { exited: u32, timed_out, wait_error };
const ReapResult = union(enum) { status: u32, fail_closed };

const RealWaiter = struct {
    pub fn tryWait(_: RealWaiter, pid: i32) WaitOutcome {
        var st: u32 = 0;
        const rc = linux.waitpid(pid, &st, WNOHANG);
        return switch (linux.errno(rc)) {
            .INTR => .running,
            .SUCCESS => if (rc == @as(usize, @intCast(pid))) .{ .exited = st } else .running,
            else => .wait_error,
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

fn reapWithin(clock: anytype, c: *Child, deadline_ms: i64, waiter: anytype) ReapResult {
    if (c.reaped) return .{ .status = c.status };
    if (c.pid <= 1) {
        c.ownership_lost = true;
        return .fail_closed;
    }
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
        .timed_out => {},
    }
    waiter.kill(c.pid);
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
        .timed_out => return .fail_closed,
    }
}

fn cleanupChildren(children: []Child, waiter: anytype) void {
    for (children) |*c| {
        if (c.reaped or c.pid <= 1 or c.ownership_lost) continue;
        waiter.kill(c.pid);
        switch (waiter.tryWait(c.pid)) {
            .exited => c.reaped = true,
            else => {},
        }
    }
}

fn terminal0(status: u32) bool {
    return (status & 0x7f) == 0 and ((status >> 8) & 0xff) == 0;
}

// ---- the injected actuator + typed lease (deterministic, signal-free fake) -----------------------------------

const FakeLease = struct {
    fp: ledger.FixedPoint,
    td: ledger.Teardown,
    /// The two-recoverer handshake (4pa.71): entering the fixed point, the recoverer writes its id to `arrive_fd`,
    /// then waits for the parent's one byte on `go_fd`, so the parent holds it AT the fixed point, inside the held
    /// flock, for as long as the parent needs. EOF or the deadline ends the wait as an incomplete census (fail closed).
    gate: ?Gate = null,
    pub fn fixedPoint(self: *FakeLease, clock: anytype, deadline_ms: i64) ledger.FixedPoint {
        if (self.gate) |g| {
            writeAll(g.arrive_fd, &[1]u8{g.id});
            var go: [1]u8 = undefined;
            if (!readExactWithin(clock, g.go_fd, &go, deadline_ms)) return .incomplete;
        }
        return self.fp;
    }
    pub fn teardown(self: *FakeLease, clock: anytype, deadline_ms: i64) ledger.Teardown {
        _ = clock;
        _ = deadline_ms;
        return self.td;
    }
    pub fn deinit(self: *FakeLease) void {
        _ = self;
    }
};
const Gate = struct { arrive_fd: i32, go_fd: i32, id: u8 };
const FakePin = union(enum) { held: FakeLease, gone, mismatch, unreadable };
const FakeActuator = struct {
    result: FakePin,
    pub fn pin(self: FakeActuator, dir: std.Io.Dir, entry: ledger.Entry) FakePin {
        _ = dir;
        _ = entry;
        return self.result;
    }
};
/// The happy actuator: provenance matches (held), census is a clean fixed point, teardown done.
fn okActuator() FakeActuator {
    return .{ .result = .{ .held = .{ .fp = .clean, .td = .done } } };
}
/// The happy actuator whose fixed point waits at the handshake `gate` (the two-recoverer race).
fn gatedActuator(gate: Gate) FakeActuator {
    return .{ .result = .{ .held = .{ .fp = .clean, .td = .done, .gate = gate } } };
}

fn seedActive(io: std.Io, dir: std.Io.Dir, pid: i32, start_sec: u64) !void {
    try seedActiveAs(io, dir, BASENAME, pid, start_sec);
}

fn seedActiveAs(io: std.Io, dir: std.Io.Dir, basename: []const u8, pid: i32, start_sec: u64) !void {
    const seed = [_]ledger.Entry{.{ .basename = basename, .dev = 1, .ino = 2, .uid = 0, .mode = 16832, .pid = pid, .start_kind = .linux_ticks, .start_sec = start_sec, .start_usec = 0, .state = .active }};
    try ledger.publish(io, dir, STORE, &seed);
}

fn entryCount(io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir) !usize {
    var l = try ledger.load(io, gpa, dir, STORE);
    defer l.deinit();
    return l.entries().len;
}

// ---- forked two-recoverer race (needs the sentinel) ----------------------------------------------------------

fn runRecoverer(io: std.Io, dir: std.Io.Dir, deadline_ms: i64, result_fd: i32, gate: Gate) noreturn {
    const clock = ledger.RealClock{ .io = io };
    const act = recovery.test_support.recoverOneUnderLock(io, std.heap.page_allocator, dir, STORE, BASENAME, clock, deadline_ms, gatedActuator(gate));
    const b = [1]u8{@intFromEnum(act)};
    writeAll(result_fd, &b);
    linux.exit_group(0);
}

/// Whether some process holds the ledger flock now: one non-blocking attempt on a fresh descriptor, released at once.
fn flockHeldByOther(dir: std.Io.Dir) !bool {
    const fd = std.posix.openat(dir.handle, ledger.LOCK_NAME, .{ .ACCMODE = .RDWR, .NOFOLLOW = true, .CLOEXEC = true }, 0) catch return error.LockOpen;
    defer _ = linux.close(fd);
    return switch (std.posix.errno(std.posix.system.flock(fd, std.posix.LOCK.EX | std.posix.LOCK.NB))) {
        .SUCCESS => false,
        .AGAIN => true,
        else => error.LockProbe,
    };
}

// The handshake, deterministic with no sleep: recoverer A is forked alone and stopped AT its fixed point (inside the
// transaction, past its pin). Only then the parent probes the flock (only A can hold it) and forks B. Held, as the
// production transaction must be: A is released, B waits for the flock and finds the entry retired. Free (a
// recoverer that released the flock before its fixed point): the parent also waits for B to reach ITS fixed point
// -- it can, since the flock is free and A has not yet retired the entry -- and then releases both, so the early
// unlock always gives two signal phases.
test "two recoverers through the PRODUCTION transaction: exact {signalled, already_gone}, empty ledger, terminal" {
    if (!inPrivatePidNamespace()) return error.NotInPrivatePidNamespace;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const clock = ledger.RealClock{ .io = io };
    const terminal = clock.nowMs() + TOTAL_BUDGET_MS;

    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    try seedActive(io, td.dir, DEAD_PID, 234567);

    // [0] read end, [1] write end: results from A and B, the shared arrival pipe, and one go pipe each.
    var res_a = [2]i32{ -1, -1 };
    var res_b = [2]i32{ -1, -1 };
    var arrive = [2]i32{ -1, -1 };
    var go_a = [2]i32{ -1, -1 };
    var go_b = [2]i32{ -1, -1 };
    const all = [_]*[2]i32{ &res_a, &res_b, &arrive, &go_a, &go_b };
    defer for (all) |pp| for (pp) |*fd| closeAndClear(fd);
    var children = [_]Child{ .{}, .{} };
    defer cleanupChildren(&children, RealWaiter{});
    for (all) |pp| if (linux.pipe(pp) != 0) return error.PipeFailed;

    const a = linux.fork();
    if (linux.errno(a) != .SUCCESS) return error.ForkFailed;
    if (a == 0) {
        for ([_]i32{ res_a[0], res_b[0], res_b[1], arrive[0], go_a[1], go_b[0], go_b[1] }) |fd| _ = linux.close(fd);
        runRecoverer(io, td.dir, terminal, res_a[1], .{ .arrive_fd = arrive[1], .go_fd = go_a[0], .id = 'A' });
    }
    children[0] = .{ .pid = @intCast(a) };
    var who: [1]u8 = undefined;
    var fixed_points: u32 = 0; // signal phases: arrivals at a fixed point (census -> kill), read off the arrival pipe
    if (!readExactWithin(clock, arrive[0], &who, terminal)) return error.ANeverReachedItsFixedPoint;
    fixed_points += 1;
    try std.testing.expectEqual(@as(u8, 'A'), who[0]);
    const held_at_fixed_point = try flockHeldByOther(td.dir); // only A exists, and it is at its fixed point

    const b = linux.fork();
    if (linux.errno(b) != .SUCCESS) return error.ForkFailed;
    if (b == 0) {
        for ([_]i32{ res_a[0], res_a[1], res_b[0], arrive[0], go_a[0], go_a[1], go_b[1] }) |fd| _ = linux.close(fd);
        runRecoverer(io, td.dir, terminal, res_b[1], .{ .arrive_fd = arrive[1], .go_fd = go_b[0], .id = 'B' });
    }
    children[1] = .{ .pid = @intCast(b) };
    for ([_]*i32{ &res_a[1], &res_b[1], &arrive[1], &go_a[0], &go_b[0] }) |fd| closeAndClear(fd);

    if (!held_at_fixed_point) {
        if (!readExactWithin(clock, arrive[0], &who, terminal)) return error.BNeverReachedItsFixedPoint;
        try std.testing.expectEqual(@as(u8, 'B'), who[0]);
        fixed_points += 1;
        writeAll(go_b[1], "g");
    }
    writeAll(go_a[1], "g");
    closeAndClear(&go_b[1]); // a B that reaches its fixed point after A released the flock reads EOF: fail closed

    var r1: [1]u8 = undefined;
    var r2: [1]u8 = undefined;
    if (!readExactWithin(clock, res_a[0], &r1, terminal)) return error.R1ResultLost;
    if (!readExactWithin(clock, res_b[0], &r2, terminal)) return error.R2ResultLost;

    const st0 = switch (reapWithin(clock, &children[0], clock.nowMs() + REAP_BUDGET_MS, RealWaiter{})) {
        .status => |s| s,
        .fail_closed => return error.R1ReapFailed,
    };
    const st1 = switch (reapWithin(clock, &children[1], clock.nowMs() + REAP_BUDGET_MS, RealWaiter{})) {
        .status => |s| s,
        .fail_closed => return error.R2ReapFailed,
    };
    try std.testing.expect(terminal0(st0));
    try std.testing.expect(terminal0(st1));
    // Both children are reaped, so every write end of the arrival pipe is closed: count any later arrival to EOF.
    while (readExactWithin(clock, arrive[0], &who, terminal)) fixed_points += 1;
    try std.testing.expectEqual(@as(u32, 1), fixed_points); // exactly ONE signal phase: the held flock serialises

    const sig = @intFromEnum(ledger.RecoveryAction.signalled);
    const gone = @intFromEnum(ledger.RecoveryAction.already_gone);
    var n_sig: u32 = 0;
    var n_gone: u32 = 0;
    for ([_]u8{ r1[0], r2[0] }) |v| {
        if (v == sig) n_sig += 1;
        if (v == gone) n_gone += 1;
    }
    try std.testing.expectEqual(@as(u32, 1), n_sig); // exactly ONE signal phase (the held flock serialises)
    try std.testing.expectEqual(@as(u32, 1), n_gone);
    try std.testing.expectEqual(@as(usize, 0), try entryCount(io, gpa, td.dir)); // EMPTY final ledger
    try std.testing.expect(held_at_fixed_point); // the one flock was held at the fixed point
}

test "a LIVE same-owner entry is LEFT untouched (.left) and RETAINED, never signalled or retired" {
    if (!inPrivatePidNamespace()) return error.NotInPrivatePidNamespace;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const clock = ledger.RealClock{ .io = io };
    const terminal = clock.nowMs() + TOTAL_BUDGET_MS;

    var td = std.testing.tmpDir(.{});
    defer td.cleanup();

    var ready = [2]i32{ -1, -1 };
    defer for ([_]*i32{ &ready[0], &ready[1] }) |p| closeAndClear(p);
    if (linux.pipe(&ready) != 0) return error.PipeFailed;
    var kids = [_]Child{.{}};
    defer cleanupChildren(&kids, RealWaiter{});
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return error.ForkFailed;
    if (pid == 0) {
        _ = linux.close(ready[0]);
        writeAll(ready[1], "R");
        var ts: linux.timespec = .{ .sec = 60, .nsec = 0 };
        _ = linux.nanosleep(&ts, &ts);
        linux.exit_group(0);
    }
    kids[0] = .{ .pid = @intCast(pid) };
    closeAndClear(&ready[1]);
    var rb: [1]u8 = undefined;
    if (!readExactWithin(clock, ready[0], &rb, terminal)) return error.ChildNotReady;

    const ticks = ledger.readStartTicks(@intCast(pid)) orelse return error.NoStartTicks;
    var bn_buf: [64]u8 = undefined;
    const bn = try std.fmt.bufPrint(&bn_buf, "zigbrowser-agent-{d}-00bb00bb00bb00bb", .{pid}); // the entry's own pid
    try seedActiveAs(io, td.dir, bn, @intCast(pid), ticks);

    const act = recovery.test_support.recoverOneUnderLock(io, gpa, td.dir, STORE, bn, clock, terminal, okActuator());
    try std.testing.expectEqual(ledger.RecoveryAction.left, act); // live same-owner -> leave untouched
    try std.testing.expectEqual(@as(usize, 1), try entryCount(io, gpa, td.dir)); // entry RETAINED
}

// ---- no-fork control-flow rows (sentinel-independent; the entry is a dead pid, the actuator is injected) ------

test "deadline AUTHORITY: a free lock at an already-expired deadline fails closed with ZERO mutation" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const clock = ledger.RealClock{ .io = io };

    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    try seedActive(io, td.dir, DEAD_PID, 234567);

    const expired = clock.nowMs() - 1; // already past -> acquire succeeds (free lock) but the post-acquire check bites
    const act = recovery.test_support.recoverOneUnderLock(io, gpa, td.dir, STORE, BASENAME, clock, expired, okActuator());
    try std.testing.expectEqual(ledger.RecoveryAction.fail_closed, act);
    try std.testing.expectEqual(@as(usize, 1), try entryCount(io, gpa, td.dir)); // entry RETAINED, no mutation past expiry
}

test "crash cut C3: a dead entry whose dir is GONE is dropped idempotently (.reconciled), never fail-closed" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const clock = ledger.RealClock{ .io = io };
    const terminal = clock.nowMs() + TOTAL_BUDGET_MS;

    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    try seedActive(io, td.dir, DEAD_PID, 234567);

    const act = recovery.test_support.recoverOneUnderLock(io, gpa, td.dir, STORE, BASENAME, clock, terminal, FakeActuator{ .result = .gone });
    try std.testing.expectEqual(ledger.RecoveryAction.reconciled, act); // dropped, signal-free, never wedged
    try std.testing.expectEqual(@as(usize, 0), try entryCount(io, gpa, td.dir)); // entry DROPPED
}

test "provenance MISMATCH never sweeps: fail closed, entry retained" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const clock = ledger.RealClock{ .io = io };
    const terminal = clock.nowMs() + TOTAL_BUDGET_MS;

    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    try seedActive(io, td.dir, DEAD_PID, 234567);

    const act = recovery.test_support.recoverOneUnderLock(io, gpa, td.dir, STORE, BASENAME, clock, terminal, FakeActuator{ .result = .mismatch });
    try std.testing.expectEqual(ledger.RecoveryAction.fail_closed, act);
    try std.testing.expectEqual(@as(usize, 1), try entryCount(io, gpa, td.dir)); // RETAINED
}

test "UNREADABLE provenance fails closed, entry retained" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const clock = ledger.RealClock{ .io = io };
    const terminal = clock.nowMs() + TOTAL_BUDGET_MS;

    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    try seedActive(io, td.dir, DEAD_PID, 234567);

    const act = recovery.test_support.recoverOneUnderLock(io, gpa, td.dir, STORE, BASENAME, clock, terminal, FakeActuator{ .result = .unreadable });
    try std.testing.expectEqual(ledger.RecoveryAction.fail_closed, act);
    try std.testing.expectEqual(@as(usize, 1), try entryCount(io, gpa, td.dir)); // RETAINED
}

// NOTE: the publish-failure/retry row (RoseCat 9f62ea4 #3) is NOT here yet. Under the required `--map-root-user`
// launcher the test runs as namespace-root with CAP_DAC_OVERRIDE, so a read-only-dir trick cannot force a
// deterministic publish failure, and the atomic temp name is randomized (no collision). It needs a publish
// failure-injection seam, which lands with the concrete C-backed lease (finding #1) in the next step.
