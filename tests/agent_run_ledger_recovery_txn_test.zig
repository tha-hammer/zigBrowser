//! MS6.5.1 OPEN whole-recovery blocker bd zigBrowser-3gl, 7b29fd6 item 1 — the exact-result two-recoverer red
//! against the REAL PRODUCTION transaction `ledger.recoverOneUnderLock` (NOT the test-only prototype). UNREGISTERED,
//! failing-first: production is a fail-closed STUB that arms nothing, so this red FAILS until the reviewed GREEN
//! implements the held-flock recovery (RoseCat b2f474b; plan rev 28).
//!
//! Oracle (the approved exact result): two recoverers race ONE proved-dead entry through the production transaction.
//! Because the real transaction holds the ONE global flock across the whole recovery (load -> fresh owner check ->
//! provenance -> census/kill fixed point -> marker unlink -> rmdir -> ledger retirement, released only after the
//! publish result), the flock SERIALISES them deterministically — no in-test handshake needed: whichever acquires
//! first performs the whole recovery and retires the entry (`.signalled`); the other blocks on acquire, then loads
//! the retired state and returns `.already_gone`. Exactly ONE `.signalled`, exactly ONE `.already_gone`, an EMPTY
//! final ledger, and two terminal children. The fail-closed stub returns `.fail_closed` from both, so the oracle
//! currently fails (0 signalled, entry retained) — the intended failing-first state.
//!
//! The recovery action is INJECTED through `actuator` (deterministic, signal-free here): the production actuator
//! will be the already-reviewed reaper/provenance C path (`zb_reaper_dir_fd_ok` + `zb_reaper_fixed_point`), never a
//! second Zig implementation. Every fork/signal is gated by the kernel-proof fd-9 PID-ns sentinel; the eventual
//! build step wraps the run in a private user+PID namespace. Parent reads/reaps are bounded against one absolute
//! monotonic deadline; children are reaped within it, else SIGKILLed+reaped (only proven-owned), and an
//! ownership-lost pid is never signalled.
const std = @import("std");
const ledger = @import("agent_run_ledger");
const linux = std.os.linux;

const BASENAME = "zigbrowser-agent-515151-00bb00bb00bb00bb";
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
            c.ownership_lost = true; // lost ownership -> never signal
            return .fail_closed;
        },
        .timed_out => {},
    }
    waiter.kill(c.pid); // only a proven-owned timeout reaches the guarded stop
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

// ---- the injected recovery actuator (deterministic, signal-free) ---------------------------------------------

/// The injected actuator the production transaction will call for the destructive action. Here it is deterministic
/// and signal-free: the seeded entry is proved dead, its run-dir provenance matches, its census is already a clean
/// fixed point (no live process), and the dir retires. The PRODUCTION actuator will instead be the reviewed reaper/
/// provenance C path (`zb_reaper_dir_fd_ok` + `zb_reaper_fixed_point`). This is my RECOMMENDED interface shape
/// (provenanceMatches / fixedPointClean / retireDir) pending RoseCat's confirmation.
const FakeActuator = struct {
    pub fn provenanceMatches(_: FakeActuator, entry: ledger.Entry) bool {
        _ = entry;
        return true;
    }
    pub fn fixedPointClean(_: FakeActuator, entry: ledger.Entry, clock: anytype, deadline_ms: i64) ledger.FixedPoint {
        _ = entry;
        _ = clock;
        _ = deadline_ms;
        return .clean;
    }
    pub fn retireDir(_: FakeActuator, entry: ledger.Entry) bool {
        _ = entry;
        return true;
    }
};

fn runRecoverer(io: std.Io, dir: std.Io.Dir, deadline_ms: i64, result_fd: i32) noreturn {
    const clock = ledger.RealClock{ .io = io };
    const act = ledger.recoverOneUnderLock(io, std.heap.page_allocator, dir, BASENAME, clock, deadline_ms, FakeActuator{});
    const b = [1]u8{@intFromEnum(act)};
    writeAll(result_fd, &b);
    linux.exit_group(0);
}

test "two recoverers through the PRODUCTION transaction: exact {signalled, already_gone}, empty ledger, terminal" {
    if (!inPrivatePidNamespace()) return error.NotInPrivatePidNamespace;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const clock = ledger.RealClock{ .io = io };
    const terminal = clock.nowMs() + TOTAL_BUDGET_MS;

    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    const seed = [_]ledger.Entry{.{ .basename = BASENAME, .dev = 1, .ino = 2, .uid = 0, .mode = 16832, .pid = DEAD_PID, .start_kind = .linux_ticks, .start_sec = 234567, .start_usec = 0, .state = .active }};
    try ledger.publish(io, td.dir, "runs.json", &seed);

    var p1res = [2]i32{ -1, -1 };
    var p2res = [2]i32{ -1, -1 };
    defer for ([_]*i32{ &p1res[0], &p1res[1], &p2res[0], &p2res[1] }) |p| closeAndClear(p);
    var children = [_]Child{ .{}, .{} };
    defer cleanupChildren(&children, RealWaiter{});
    if (linux.pipe(&p1res) != 0) return error.PipeFailed;
    if (linux.pipe(&p2res) != 0) return error.PipeFailed;

    const a = linux.fork();
    if (linux.errno(a) != .SUCCESS) return error.ForkFailed;
    if (a == 0) {
        for ([_]i32{ p1res[0], p2res[0], p2res[1] }) |fd| _ = linux.close(fd);
        runRecoverer(io, td.dir, terminal, p1res[1]);
    }
    children[0] = .{ .pid = @intCast(a) };

    const b = linux.fork();
    if (linux.errno(b) != .SUCCESS) return error.ForkFailed;
    if (b == 0) {
        for ([_]i32{ p1res[0], p1res[1], p2res[0] }) |fd| _ = linux.close(fd);
        runRecoverer(io, td.dir, terminal, p2res[1]);
    }
    children[1] = .{ .pid = @intCast(b) };
    for ([_]*i32{ &p1res[1], &p2res[1] }) |p| closeAndClear(p);

    var r1: [1]u8 = undefined;
    var r2: [1]u8 = undefined;
    if (!readExactWithin(clock, p1res[0], &r1, terminal)) return error.R1ResultLost;
    if (!readExactWithin(clock, p2res[0], &r2, terminal)) return error.R2ResultLost;

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

    // Exact result: one recoverer signalled, the other found the entry already gone.
    const sig = @intFromEnum(ledger.RecoveryAction.signalled);
    const gone = @intFromEnum(ledger.RecoveryAction.already_gone);
    var n_sig: u32 = 0;
    var n_gone: u32 = 0;
    for ([_]u8{ r1[0], r2[0] }) |v| {
        if (v == sig) n_sig += 1;
        if (v == gone) n_gone += 1;
    }
    try std.testing.expectEqual(@as(u32, 1), n_sig); // exactly ONE signal phase
    try std.testing.expectEqual(@as(u32, 1), n_gone); // the other recoverer saw it already gone

    var l = try ledger.load(io, gpa, td.dir, "runs.json"); // EMPTY final ledger (the entry was retired)
    defer l.deinit();
    try std.testing.expectEqual(@as(usize, 0), l.entries().len);
}
