//! MS6.5.1 whole-recovery blocker bd zigBrowser-3gl, RoseCat 9f62ea4 #1 (+ #3 real C2/C3): the CONCRETE,
//! capability-carrying lease driven against REAL filesystem run-dir states. UNREGISTERED and UNARMED; built only by
//! the manual `zig build test-agent-run-recovery-txn` step, which links `src/agent_run_reaper.c` and runs inside a
//! private user/PID/mount namespace behind the fd-9 sentinel (refusing before any signal if fd 9 is absent).
//!
//! This increment proves the CONCRETE provenance + fd-relative idempotent teardown + crash cuts, with the census a
//! trivial clean wiring (no survivors). The reviewed `zb_reaper_fixed_point` engine with an INTERCEPTED
//! marked-child kill count, the early-unlock mutant (two action entries) and the held-fd path-swap mutant
//! (finding #4) land in the next commit on this same step.
const std = @import("std");
const ledger = @import("agent_run_ledger");
const recovery = @import("agent_run_recovery");
const linux = std.os.linux;

const BASENAME = "zigbrowser-agent-515151-00bb00bb00bb00bb";
const OUTER_NS_FD: i32 = 9;
const NS_GET_NSTYPE: u32 = 0xB703;
const NS_GET_TGID_IN_PIDNS: u32 = 0x8004B709;
const CLONE_NEWPID: usize = 0x20000000;
const AT_EMPTY_PATH: u32 = 0x1000;
const TOTAL_BUDGET_MS: i64 = 30000;

fn nsIno(dirfd: i32, path: [*:0]const u8, flags: u32) ?u64 {
    var sx: linux.Statx = undefined;
    if (linux.errno(linux.statx(dirfd, path, flags, linux.STATX.BASIC_STATS, &sx)) != .SUCCESS) return null;
    return sx.ino;
}

/// The step runs inside the private PID namespace; refuse (skip) before any work if fd 9 is not the held outer
/// namespace. None of this increment's rows signal, but the sentinel is the step's standing guarantee.
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

/// A trivial census wiring: a complete, empty final census (no survivors). The real `zb_reaper_fixed_point` engine
/// with an intercepted kill count lands next; here the point is the concrete provenance + fd-relative teardown.
const CleanWiring = struct {
    pub fn run(_: CleanWiring, clock: anytype, run_dir_fd: i32, pinned: *const recovery.DirId, deadline_ms: i64) ledger.FixedPoint {
        _ = clock;
        _ = run_dir_fd;
        _ = pinned;
        _ = deadline_ms;
        return .clean;
    }
};
const Actuator = recovery.ConcreteActuator(CleanWiring);
fn actuator() Actuator {
    return .{ .wiring = .{} };
}

/// A clock that returns a valid time for the first `expire_at` reads, then a far-expired time, so a test can place
/// the deadline crossing at a precise teardown checkpoint.
const StepClock = struct {
    calls: *usize,
    expire_at: usize,
    pub fn nowMs(self: StepClock) i64 {
        const n = self.calls.*;
        self.calls.* += 1;
        return if (n >= self.expire_at) 1_000_000_000 else 1000;
    }
};
const STEP_DEADLINE: i64 = 2000; // between 1000 (valid) and 1e9 (expired)

const RealId = struct { dev: u64, ino: u64, uid: u32, mode: u32 };

/// Create a REAL run dir (0700) relative to `dir`, optionally with a 0400 `run.marker`, and return its real
/// (dev,ino,uid,mode) from `fstat` — the same values `zb_reaper_pin_fd` will compute, so the seeded ledger entry
/// matches exactly what `pin` provenance-checks.
fn makeRunDir(dir: std.Io.Dir, with_marker: bool) !RealId {
    if (linux.errno(linux.mkdirat(dir.handle, BASENAME, 0o700)) != .SUCCESS) return error.Mkdir;
    const fd = std.posix.openatZ(dir.handle, BASENAME, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, 0) catch return error.OpenRunDir;
    defer _ = std.posix.system.close(fd);
    if (with_marker) {
        const mfd = std.posix.openatZ(fd, "run.marker", .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, 0o400) catch return error.MarkerCreate;
        _ = std.posix.system.close(mfd);
    }
    const id = recovery.pinDir(dir, BASENAME) orelse return error.PinFd;
    return .{ .dev = @intCast(id.dev), .ino = @intCast(id.ino), .uid = @intCast(id.uid), .mode = @intCast(id.mode) };
}

fn seedFrom(io: std.Io, dir: std.Io.Dir, id: RealId) !void {
    const seed = [_]ledger.Entry{.{
        .basename = BASENAME,
        .dev = id.dev,
        .ino = id.ino,
        .uid = id.uid,
        .mode = id.mode,
        .pid = 2147483645, // absent + reuse-proof -> proved dead
        .start_kind = .linux_ticks,
        .start_sec = 234567,
        .start_usec = 0,
        .state = .active,
    }};
    try ledger.publish(io, dir, "runs.json", &seed);
}

fn seedExplicit(io: std.Io, dir: std.Io.Dir, dev: u64, ino: u64) !void {
    const seed = [_]ledger.Entry{.{ .basename = BASENAME, .dev = dev, .ino = ino, .uid = 0, .mode = 16832, .pid = 2147483645, .start_kind = .linux_ticks, .start_sec = 234567, .start_usec = 0, .state = .active }};
    try ledger.publish(io, dir, "runs.json", &seed);
}

fn entryCount(io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir) !usize {
    var l = try ledger.load(io, gpa, dir, "runs.json");
    defer l.deinit();
    return l.entries().len;
}

fn runDirExists(dir: std.Io.Dir) bool {
    const fd = std.posix.openatZ(dir.handle, BASENAME, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, 0) catch return false;
    _ = std.posix.system.close(fd);
    return true;
}

fn markerExists(dir: std.Io.Dir) bool {
    const d = std.posix.openatZ(dir.handle, BASENAME, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, 0) catch return false;
    defer _ = std.posix.system.close(d);
    const m = std.posix.openatZ(d, "run.marker", .{ .ACCMODE = .RDONLY }, 0) catch return false;
    _ = std.posix.system.close(m);
    return true;
}

fn entryFor(id: RealId) ledger.Entry {
    return .{ .basename = BASENAME, .dev = id.dev, .ino = id.ino, .uid = id.uid, .mode = id.mode, .pid = 2147483645, .start_kind = .linux_ticks, .start_sec = 234567, .start_usec = 0, .state = .active };
}

test "concrete lease: a dead entry with matching provenance is recovered — marker unlinked, dir rmdir'd, entry retired" {
    if (!inPrivatePidNamespace()) return error.NotInPrivatePidNamespace;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const clock = ledger.RealClock{ .io = io };
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();

    const id = try makeRunDir(td.dir, true);
    try seedFrom(io, td.dir, id);

    const act = ledger.recoverOneUnderLock(io, gpa, td.dir, BASENAME, clock, clock.nowMs() + TOTAL_BUDGET_MS, actuator());
    try std.testing.expectEqual(ledger.RecoveryAction.signalled, act);
    try std.testing.expectEqual(@as(usize, 0), try entryCount(io, gpa, td.dir)); // entry retired
    try std.testing.expect(!runDirExists(td.dir)); // the real run dir was torn down through the held fd
}

test "concrete lease crash cut C2: a marker-less (already-unlinked) dir tears down idempotently and is retired" {
    if (!inPrivatePidNamespace()) return error.NotInPrivatePidNamespace;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const clock = ledger.RealClock{ .io = io };
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();

    const id = try makeRunDir(td.dir, false); // NO marker -> the marker unlink must be idempotent (ENOENT = done)
    try seedFrom(io, td.dir, id);

    const act = ledger.recoverOneUnderLock(io, gpa, td.dir, BASENAME, clock, clock.nowMs() + TOTAL_BUDGET_MS, actuator());
    try std.testing.expectEqual(ledger.RecoveryAction.signalled, act);
    try std.testing.expectEqual(@as(usize, 0), try entryCount(io, gpa, td.dir));
    try std.testing.expect(!runDirExists(td.dir));
}

test "concrete lease crash cut C3: a dead entry whose dir is GONE is dropped (.reconciled), not fail-closed" {
    if (!inPrivatePidNamespace()) return error.NotInPrivatePidNamespace;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const clock = ledger.RealClock{ .io = io };
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();

    try seedExplicit(io, td.dir, 1, 2); // the dir named by the entry does NOT exist -> ENOENT -> gone (C3)

    const act = ledger.recoverOneUnderLock(io, gpa, td.dir, BASENAME, clock, clock.nowMs() + TOTAL_BUDGET_MS, actuator());
    try std.testing.expectEqual(ledger.RecoveryAction.reconciled, act);
    try std.testing.expectEqual(@as(usize, 0), try entryCount(io, gpa, td.dir)); // entry dropped
}

test "concrete lease provenance MISMATCH (recorded dev/ino != the real dir) never sweeps: fail closed, dir kept" {
    if (!inPrivatePidNamespace()) return error.NotInPrivatePidNamespace;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const clock = ledger.RealClock{ .io = io };
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();

    _ = try makeRunDir(td.dir, true); // a REAL dir exists...
    try seedExplicit(io, td.dir, 999999, 888888); // ...but the entry records a DIFFERENT (dev,ino) -> mismatch

    const act = ledger.recoverOneUnderLock(io, gpa, td.dir, BASENAME, clock, clock.nowMs() + TOTAL_BUDGET_MS, actuator());
    try std.testing.expectEqual(ledger.RecoveryAction.fail_closed, act);
    try std.testing.expectEqual(@as(usize, 1), try entryCount(io, gpa, td.dir)); // entry RETAINED
    try std.testing.expect(runDirExists(td.dir)); // the mismatched dir is NOT torn down
}

test "concrete lease #1 rename/replacement race: a swapped-in empty replacement is NOT removed (held-identity revalidation)" {
    if (!inPrivatePidNamespace()) return error.NotInPrivatePidNamespace;
    const io = std.testing.io;
    const clock = ledger.RealClock{ .io = io };
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();

    const id = try makeRunDir(td.dir, true);
    var a = actuator();
    switch (a.pin(td.dir, entryFor(id))) {
        .held => |held| {
            var lease = held;
            defer lease.deinit();
            // SWAP after the pin: rename the real (held) dir away, install an EMPTY replacement at the same name.
            if (linux.errno(linux.renameat(td.dir.handle, BASENAME, td.dir.handle, BASENAME ++ "-moved")) != .SUCCESS) return error.Rename;
            if (linux.errno(linux.mkdirat(td.dir.handle, BASENAME, 0o700)) != .SUCCESS) return error.Mkdir2;
            const r = lease.teardown(clock, clock.nowMs() + TOTAL_BUDGET_MS);
            try std.testing.expectEqual(ledger.Teardown.failed, r); // the name is a DIFFERENT inode now -> refuse
            try std.testing.expect(runDirExists(td.dir)); // the replacement dir is NOT removed
        },
        else => return error.ExpectedHeld,
    }
}

test "concrete lease #2 deadline between marker-unlink and rmdir: fail closed, C2 state preserved (marker gone, dir kept)" {
    if (!inPrivatePidNamespace()) return error.NotInPrivatePidNamespace;
    const io = std.testing.io;
    _ = io;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();

    const id = try makeRunDir(td.dir, true);
    var a = actuator();
    switch (a.pin(td.dir, entryFor(id))) {
        .held => |held| {
            var lease = held;
            defer lease.deinit();
            var calls: usize = 0;
            // expire on the 2nd nowMs read: pre-marker-unlink check passes, the between-check (before rmdir) expires.
            const r = lease.teardown(StepClock{ .calls = &calls, .expire_at = 1 }, STEP_DEADLINE);
            try std.testing.expectEqual(ledger.Teardown.failed, r);
            try std.testing.expect(runDirExists(td.dir)); // rmdir NOT reached -> dir kept
            try std.testing.expect(!markerExists(td.dir)); // marker WAS unlinked before expiry -> C2 state
        },
        else => return error.ExpectedHeld,
    }
}

test "concrete lease #4 unreadable: an open that fails for a non-shape reason is .unreadable, distinct from mismatch" {
    if (!inPrivatePidNamespace()) return error.NotInPrivatePidNamespace;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();

    // A 256-char basename makes openat fail ENAMETOOLONG -> the catch's `else` -> .unreadable (could not even open
    // to read the identity), NOT mismatch (which is a readable-but-wrong-shape/identity dir) and NOT gone (ENOENT).
    const long = "z" ** 256;
    const entry = ledger.Entry{ .basename = long, .dev = 1, .ino = 2, .uid = 0, .mode = 16832, .pid = 2147483645, .start_kind = .linux_ticks, .start_sec = 234567, .start_usec = 0, .state = .active };
    var a = actuator();
    switch (a.pin(td.dir, entry)) {
        .unreadable => {},
        .held => |held| {
            var l = held;
            l.deinit();
            return error.ExpectedUnreadable;
        },
        else => return error.ExpectedUnreadable,
    }
}

// ---- finding #5: the reviewed zb_reaper_fixed_point over the held fd, with an INTERCEPTED (counting) kill -------

const Counters = struct {
    kills: u32 = 0,
    gone: bool = false,
    // Handshake fds for the deterministic two-recoverer row (RoseCat e034dda #3); role 0 = no handshake.
    role: u8 = 0,
    r1kill_fd: i32 = -1, // role 1 writes "in the kill phase" here
    proceed_fd: i32 = -1, // role 1 BLOCKS here until the parent releases it (parked inside the held flock)
    r2kill_fd: i32 = -1, // role 2 writes "in the kill phase" here
};
var g_pass: usize = 0; // census pass counter; the per-pass SIZING call (buf==null) advances it. Per-process (fork).
const SCRIPTED_PID: i32 = 424242; // a marked child; > 1, not us; the kill is intercepted so no real signal
const DUMMY_PATH: [*:0]const u8 = "/run/zb/zigbrowser-agent-515151-00bb00bb00bb00bb";

// zb_reaper_gather calls scan(NULL,0) for a size estimate, then scan(buf, bytes) to fill. Pass 1 yields the one
// marked pid; every later pass is empty -> the complete empty final census (clean). The sizing call is the pass
// boundary, so it advances g_pass.
fn scanCb(buf: ?*anyopaque, bytes: c_int) callconv(.c) c_int {
    if (buf == null) { // size-estimate call: starts a new gather pass
        const p = g_pass;
        g_pass += 1;
        return if (p == 0) 1 else 0;
    }
    if (g_pass == 1) { // fill call for pass 1
        if (bytes < @sizeOf(i32)) return 0;
        const pp: [*]i32 = @ptrCast(@alignCast(buf.?));
        pp[0] = SCRIPTED_PID;
        return 1;
    }
    return 0; // fill call for a later (empty) pass
}
const ESRCH: c_int = @intFromEnum(std.posix.E.SRCH);
fn inspectCb(pid: recovery.pid_t, dir: [*c]const u8, out: [*c]recovery.ReaperId, ctx: ?*anyopaque) callconv(.c) void {
    _ = pid;
    _ = dir;
    _ = ctx;
    // A matching survivor of our uid with a stable identity (so the pre-kill re-inspect's same_proc holds).
    out.* = .{ .matches = 1, .have_bsd = 1, .uid = linux.getuid(), .start_sec = 111, .start_usec = 0 };
}
fn killCb(pid: recovery.pid_t, sig: c_int, ctx: ?*anyopaque) callconv(.c) c_int {
    _ = pid;
    const o: *recovery.OpsCtx = @ptrCast(@alignCast(ctx.?));
    const cnt: *Counters = @ptrCast(@alignCast(o.user.?));
    if (sig == 0) return if (cnt.gone) ESRCH else 0; // engine_gone liveness probe: gone AFTER our kill
    // The SIGKILL = entering the real kill phase. The handshake makes the flock serialisation OBSERVABLE: under the
    // held-flock green only role 1 reaches here (it parks, holding the flock); an early-unlock regime lets role 2
    // reach here too. role 0 = no handshake (the single-recoverer rows).
    if (cnt.role == 1) {
        if (cnt.r1kill_fd >= 0) writeAll(cnt.r1kill_fd, "K");
        if (cnt.proceed_fd >= 0) {
            var b: [1]u8 = undefined;
            while (linux.errno(linux.read(cnt.proceed_fd, &b, 1)) == .INTR) {}
        }
    } else if (cnt.role == 2) {
        if (cnt.r2kill_fd >= 0) writeAll(cnt.r2kill_fd, "K");
    }
    cnt.kills += 1; // the real SIGKILL -> INTERCEPTED (counted, never actually sent)
    cnt.gone = true;
    return 0;
}

const ReaperWiring = struct {
    counters: *Counters,
    pub fn run(self: ReaperWiring, clock: anytype, run_dir_fd: i32, pinned: *const recovery.DirId, deadline_ms: i64) ledger.FixedPoint {
        _ = clock; // the generic census uses the real monotonic now-fn; the deadline is the ledger's absolute one
        return recovery.runFixedPoint(&recovery.realNowMs, deadline_ms, run_dir_fd, pinned, DUMMY_PATH, 8, scanCb, inspectCb, killCb, self.counters);
    }
};

test "concrete lease #5 real census: one marked child is killed (intercepted count==1), fixed point clean -> recovered" {
    if (!inPrivatePidNamespace()) return error.NotInPrivatePidNamespace;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const clock = ledger.RealClock{ .io = io };
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();

    const id = try makeRunDir(td.dir, true);
    try seedFrom(io, td.dir, id);
    g_pass = 0;
    var counters = Counters{};
    const act = ledger.recoverOneUnderLock(io, gpa, td.dir, BASENAME, clock, clock.nowMs() + TOTAL_BUDGET_MS, recovery.ConcreteActuator(ReaperWiring){ .wiring = .{ .counters = &counters } });
    try std.testing.expectEqual(ledger.RecoveryAction.signalled, act);
    try std.testing.expectEqual(@as(u32, 1), counters.kills); // ONE marked child entered the real kill phase (observed, not an enum)
    try std.testing.expectEqual(@as(usize, 0), try entryCount(io, gpa, td.dir));
    try std.testing.expect(!runDirExists(td.dir));
}

// ---- compact bounded-reap harness for the forked two-recoverer row (same shapes proven elsewhere) -------------

const WNOHANG: u32 = 1;
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
const Child = struct { pid: i32 = -1, reaped: bool = false, status: u32 = 0 };
fn reapWithin(clock: anytype, c: *Child, deadline_ms: i64) bool {
    if (c.reaped or c.pid <= 1) return c.reaped;
    while (true) {
        var st: u32 = 0;
        const rc = linux.waitpid(c.pid, &st, WNOHANG);
        switch (linux.errno(rc)) {
            .INTR => continue,
            .SUCCESS => if (rc == @as(usize, @intCast(c.pid))) {
                c.status = st;
                c.reaped = true;
                return true;
            },
            else => return false,
        }
        if (clock.nowMs() >= deadline_ms) break;
        var ts: linux.timespec = .{ .sec = 0, .nsec = 2_000_000 };
        _ = linux.nanosleep(&ts, &ts);
    }
    _ = linux.kill(c.pid, linux.SIG.KILL);
    var st: u32 = 0;
    while (linux.errno(linux.waitpid(c.pid, &st, 0)) == .INTR) {}
    c.reaped = true;
    return true;
}
fn cleanupKids(kids: []Child) void {
    for (kids) |*c| {
        if (c.reaped or c.pid <= 1) continue;
        _ = linux.kill(c.pid, linux.SIG.KILL);
        var st: u32 = 0;
        _ = linux.waitpid(c.pid, &st, WNOHANG);
    }
}
fn terminal0(status: u32) bool {
    return (status & 0x7f) == 0 and ((status >> 8) & 0xff) == 0;
}

fn runReaperRecoverer(io: std.Io, dir: std.Io.Dir, deadline_ms: i64, result_fd: i32) noreturn {
    g_pass = 0;
    var counters = Counters{};
    const act = ledger.recoverOneUnderLock(io, std.heap.page_allocator, dir, BASENAME, ledger.RealClock{ .io = io }, deadline_ms, recovery.ConcreteActuator(ReaperWiring){ .wiring = .{ .counters = &counters } });
    const b = [2]u8{ @intFromEnum(act), @intCast(@min(counters.kills, 255)) };
    writeAll(result_fd, &b);
    linux.exit_group(0);
}

test "concrete lease #5 two recoverers: exactly ONE enters the real kill phase (intercepted count), the other already_gone" {
    if (!inPrivatePidNamespace()) return error.NotInPrivatePidNamespace;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const clock = ledger.RealClock{ .io = io };
    const terminal = clock.nowMs() + TOTAL_BUDGET_MS;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();

    const id = try makeRunDir(td.dir, true);
    try seedFrom(io, td.dir, id);

    var p1 = [2]i32{ -1, -1 };
    var p2 = [2]i32{ -1, -1 };
    defer for ([_]*i32{ &p1[0], &p1[1], &p2[0], &p2[1] }) |p| closeAndClear(p);
    var kids = [_]Child{ .{}, .{} };
    defer cleanupKids(&kids);
    if (linux.pipe(&p1) != 0) return error.Pipe;
    if (linux.pipe(&p2) != 0) return error.Pipe;

    const a = linux.fork();
    if (linux.errno(a) != .SUCCESS) return error.Fork;
    if (a == 0) {
        for ([_]i32{ p1[0], p2[0], p2[1] }) |fd| _ = linux.close(fd);
        runReaperRecoverer(io, td.dir, terminal, p1[1]);
    }
    kids[0] = .{ .pid = @intCast(a) };
    const b = linux.fork();
    if (linux.errno(b) != .SUCCESS) return error.Fork;
    if (b == 0) {
        for ([_]i32{ p1[0], p1[1], p2[0] }) |fd| _ = linux.close(fd);
        runReaperRecoverer(io, td.dir, terminal, p2[1]);
    }
    kids[1] = .{ .pid = @intCast(b) };
    for ([_]*i32{ &p1[1], &p2[1] }) |p| closeAndClear(p);

    var r1: [2]u8 = undefined;
    var r2: [2]u8 = undefined;
    if (!readExactWithin(clock, p1[0], &r1, terminal)) return error.R1Lost;
    if (!readExactWithin(clock, p2[0], &r2, terminal)) return error.R2Lost;
    try std.testing.expect(reapWithin(clock, &kids[0], clock.nowMs() + 3000));
    try std.testing.expect(reapWithin(clock, &kids[1], clock.nowMs() + 3000));
    try std.testing.expect(terminal0(kids[0].status));
    try std.testing.expect(terminal0(kids[1].status));

    const sig = @intFromEnum(ledger.RecoveryAction.signalled);
    const gone = @intFromEnum(ledger.RecoveryAction.already_gone);
    var n_sig: u32 = 0;
    var n_gone: u32 = 0;
    var total_kills: u32 = 0;
    for ([_][2]u8{ r1, r2 }) |rr| {
        if (rr[0] == sig) {
            n_sig += 1;
            try std.testing.expectEqual(@as(u8, 1), rr[1]); // the signaller killed exactly one marked child
        }
        if (rr[0] == gone) {
            n_gone += 1;
            try std.testing.expectEqual(@as(u8, 0), rr[1]); // the loser never entered the kill phase
        }
        total_kills += rr[1];
    }
    try std.testing.expectEqual(@as(u32, 1), n_sig);
    try std.testing.expectEqual(@as(u32, 1), n_gone);
    try std.testing.expectEqual(@as(u32, 1), total_kills); // ONE signal phase OBSERVED across both recoverers
    try std.testing.expectEqual(@as(usize, 0), try entryCount(io, gpa, td.dir));
}

// A publish ops whose rename FAILS, to exercise the atomic-retirement failure path (the temp is created+synced,
// then the rename errors, so publishCut's defer removes the temp and the store is left unchanged).
const FailingPublishOps = struct {
    pub fn syncFile(_: FailingPublishOps, file: std.Io.File, io: std.Io) !void {
        _ = file;
        _ = io;
    }
    pub fn rename(_: FailingPublishOps, dir: std.Io.Dir, old_sub: []const u8, new_sub: []const u8, io: std.Io) !void {
        _ = dir;
        _ = old_sub;
        _ = new_sub;
        _ = io;
        return error.InjectedPublishFailure;
    }
    pub fn syncDir(_: FailingPublishOps, dir: std.Io.Dir, io: std.Io) !void {
        _ = dir;
        _ = io;
    }
};

test "concrete lease #5 publish-retry: a failed atomic retirement fails closed (entry RETAINED); the retry completes it" {
    if (!inPrivatePidNamespace()) return error.NotInPrivatePidNamespace;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const clock = ledger.RealClock{ .io = io };
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();

    const id = try makeRunDir(td.dir, true);
    try seedFrom(io, td.dir, id);

    // attempt 1: census clean + dir torn down, but the atomic retirement PUBLISH fails -> fail closed, entry kept.
    g_pass = 0;
    var c1 = Counters{};
    const a1 = ledger.recoverOneUnderLockP(io, gpa, td.dir, BASENAME, clock, clock.nowMs() + TOTAL_BUDGET_MS, recovery.ConcreteActuator(ReaperWiring){ .wiring = .{ .counters = &c1 } }, FailingPublishOps{});
    try std.testing.expectEqual(ledger.RecoveryAction.fail_closed, a1);
    try std.testing.expectEqual(@as(usize, 1), try entryCount(io, gpa, td.dir)); // RETAINED for retry

    // attempt 2: retry with the real publish. The dir is already torn down, so the retry reconciles (C3) and
    // completes the retirement -> the entry is finally removed.
    g_pass = 0;
    var c2 = Counters{};
    const a2 = ledger.recoverOneUnderLock(io, gpa, td.dir, BASENAME, clock, clock.nowMs() + TOTAL_BUDGET_MS, recovery.ConcreteActuator(ReaperWiring){ .wiring = .{ .counters = &c2 } });
    try std.testing.expectEqual(ledger.RecoveryAction.reconciled, a2);
    try std.testing.expectEqual(@as(usize, 0), try entryCount(io, gpa, td.dir)); // removed only after the retry succeeds
}

// ---- 30afe68 #1: the check/use-window swap, caught by the post-rmdir held-inode verification -----------------

var g_swap_dirfd: i32 = -1; // the runtime dir fd the window hook swaps within (set per test)
fn swapHook() void {
    // Runs AFTER nameMatchesHeld and BEFORE the rmdir (the check/use window): rename the real (held) dir away and
    // plant an empty same-uid replacement at the same basename, exactly as a concurrent same-uid actor would.
    _ = linux.renameat(g_swap_dirfd, BASENAME, g_swap_dirfd, BASENAME ++ "-win");
    _ = linux.mkdirat(g_swap_dirfd, BASENAME, 0o700);
}

test "concrete lease #1b check/use-window swap: caught by the post-rmdir held-inode verification -> fail closed" {
    if (!inPrivatePidNamespace()) return error.NotInPrivatePidNamespace;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const clock = ledger.RealClock{ .io = io };
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();

    const id = try makeRunDir(td.dir, true);
    try seedFrom(io, td.dir, id);
    g_swap_dirfd = td.dir.handle;
    const act = ledger.recoverOneUnderLock(io, gpa, td.dir, BASENAME, clock, clock.nowMs() + TOTAL_BUDGET_MS, recovery.ConcreteActuator(CleanWiring){ .wiring = .{}, .window_hook = &swapHook });
    // The by-name rmdir removed the swapped-in replacement, but the HELD inode survived (nlink > 0), so the
    // post-rmdir verification fails the teardown -> recoverOneUnderLock fails closed and does NOT retire the entry.
    try std.testing.expectEqual(ledger.RecoveryAction.fail_closed, act);
    try std.testing.expectEqual(@as(usize, 1), try entryCount(io, gpa, td.dir)); // entry RETAINED (real run not proven gone)
}

test "concrete lease #2b deadline AFTER the re-open/fstat validation (before rmdir): fail closed, dir kept" {
    if (!inPrivatePidNamespace()) return error.NotInPrivatePidNamespace;
    const io = std.testing.io;
    _ = io;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();

    const id = try makeRunDir(td.dir, true);
    var a = actuator();
    switch (a.pin(td.dir, entryFor(id))) {
        .held => |held| {
            var lease = held;
            defer lease.deinit();
            // teardown reads the clock at: (a) top, (b) after the marker unlink, (c) after nameMatchesHeld, just
            // before the rmdir. expire_at=2 keeps (a),(b) valid and expires (c) -- the check RoseCat 30afe68 #2
            // requires AFTER the re-open/fstat validation. rmdir must not run.
            var calls: usize = 0;
            const r = lease.teardown(StepClock{ .calls = &calls, .expire_at = 2 }, STEP_DEADLINE);
            try std.testing.expectEqual(ledger.Teardown.failed, r);
            try std.testing.expect(runDirExists(td.dir)); // rmdir NOT reached -> the real dir is kept
        },
        else => return error.ExpectedHeld,
    }
}

// ---- e034dda #1: the wiring enforces the single absolute deadline ---------------------------------------------

// Controlled now-fns (C-callable) so a row can place the deadline crossing precisely. Deadline for both = 1000.
fn nowExpired() callconv(.c) i64 {
    return 2000; // already past the deadline at the pre-engine check
}
var g_now_calls: usize = 0;
fn nowCrossBeforeKill() callconv(.c) i64 {
    const n = g_now_calls; // call 0 = pre-engine (under), call 1 = dir_ok right before the kill (over)
    g_now_calls += 1;
    return if (n == 0) 500 else 1500;
}

fn openRunDir(dir: std.Io.Dir) !i32 {
    return std.posix.openatZ(dir.handle, BASENAME, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, 0) catch error.Open;
}

test "#5 deadline pre-engine: a census begun past the deadline is refused (incomplete, no inspect/act)" {
    if (!inPrivatePidNamespace()) return error.NotInPrivatePidNamespace;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    _ = try makeRunDir(td.dir, true);
    const fd = try openRunDir(td.dir);
    defer _ = std.posix.system.close(fd);
    const pinned = recovery.pinDir(td.dir, BASENAME) orelse return error.Pin;
    g_pass = 0;
    var counters = Counters{};
    const fp = recovery.runFixedPoint(&nowExpired, 1000, fd, &pinned, DUMMY_PATH, 8, scanCb, inspectCb, killCb, &counters);
    try std.testing.expectEqual(ledger.FixedPoint.incomplete, fp);
    try std.testing.expectEqual(@as(u32, 0), counters.kills); // never entered the engine
}

test "#5 deadline mid-census: the clock crossing immediately before a kill stops the engine with ZERO kills" {
    if (!inPrivatePidNamespace()) return error.NotInPrivatePidNamespace;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    _ = try makeRunDir(td.dir, true);
    const fd = try openRunDir(td.dir);
    defer _ = std.posix.system.close(fd);
    const pinned = recovery.pinDir(td.dir, BASENAME) orelse return error.Pin;
    g_pass = 0;
    g_now_calls = 0;
    var counters = Counters{};
    // Pre-engine now=500 (< 1000) passes; the scripted pid is scanned+inspected; then `dir_ok` reads now=1500
    // (>= 1000) RIGHT BEFORE the kill -> the engine overflows and breaks -> incomplete, and NO kill is sent.
    const fp = recovery.runFixedPoint(&nowCrossBeforeKill, 1000, fd, &pinned, DUMMY_PATH, 8, scanCb, inspectCb, killCb, &counters);
    try std.testing.expectEqual(ledger.FixedPoint.incomplete, fp);
    try std.testing.expectEqual(@as(u32, 0), counters.kills); // the deadline crossed before the kill -> zero action
}

// ---- e034dda #2: a post-open readability-probe failure is .unreadable, distinct from a shape/identity mismatch

fn nullProbe(_: i32) ?u64 {
    return null;
}

test "#4b unreadable AFTER a successful open: a failing readability probe -> unreadable, not mismatch" {
    if (!inPrivatePidNamespace()) return error.NotInPrivatePidNamespace;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    const id = try makeRunDir(td.dir, true); // a REAL openable dir with MATCHING provenance...
    var a = recovery.ConcreteActuator(CleanWiring){ .wiring = .{}, .probe = &nullProbe }; // ...but the probe fails
    switch (a.pin(td.dir, entryFor(id))) {
        .unreadable => {}, // the open succeeded + provenance matches, yet the identity read failed -> unreadable
        .held => |held| {
            var l = held;
            l.deinit();
            return error.ExpectedUnreadable;
        },
        else => return error.ExpectedUnreadable,
    }
}

// ---- e034dda #3: a deterministic held-flock handshake -- only ONE recoverer reaches the kill phase ------------

fn runHandshakeRecoverer(io: std.Io, dir: std.Io.Dir, deadline_ms: i64, role: u8, r1kill: i32, r2kill: i32, proceed: i32, start_fd: i32, result_fd: i32) noreturn {
    if (start_fd >= 0) writeAll(start_fd, "S"); // "I have started and am about to attempt the flock acquire"
    g_pass = 0;
    var counters = Counters{ .role = role, .r1kill_fd = r1kill, .r2kill_fd = r2kill, .proceed_fd = proceed };
    const act = ledger.recoverOneUnderLock(io, std.heap.page_allocator, dir, BASENAME, ledger.RealClock{ .io = io }, deadline_ms, recovery.ConcreteActuator(ReaperWiring){ .wiring = .{ .counters = &counters } });
    const b = [2]u8{ @intFromEnum(act), @intCast(@min(counters.kills, 255)) };
    writeAll(result_fd, &b);
    linux.exit_group(0);
}

test "#5 deterministic handshake: the held flock serialises the kill phase; exactly ONE recoverer reaches it" {
    if (!inPrivatePidNamespace()) return error.NotInPrivatePidNamespace;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const clock = ledger.RealClock{ .io = io };
    const terminal = clock.nowMs() + TOTAL_BUDGET_MS;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    const id = try makeRunDir(td.dir, true);
    try seedFrom(io, td.dir, id);

    var r1k = [2]i32{ -1, -1 }; // R1 -> parent "in kill phase"
    var r2k = [2]i32{ -1, -1 }; // R2 -> parent "in kill phase"
    var r2s = [2]i32{ -1, -1 }; // R2 -> parent "started, about to attempt the acquire"
    var go = [2]i32{ -1, -1 }; // parent -> R1 "proceed"
    var p1 = [2]i32{ -1, -1 };
    var p2 = [2]i32{ -1, -1 };
    defer for ([_]*i32{ &r1k[0], &r1k[1], &r2k[0], &r2k[1], &r2s[0], &r2s[1], &go[0], &go[1], &p1[0], &p1[1], &p2[0], &p2[1] }) |p| closeAndClear(p);
    var kids = [_]Child{ .{}, .{} };
    defer cleanupKids(&kids);
    for ([_]*[2]i32{ &r1k, &r2k, &r2s, &go, &p1, &p2 }) |p| if (linux.pipe(p) != 0) return error.Pipe;

    // R1: role 1 -- enters the kill phase, announces it on r1k, and BLOCKS on `go` while holding the flock.
    const a = linux.fork();
    if (linux.errno(a) != .SUCCESS) return error.Fork;
    if (a == 0) {
        for ([_]i32{ r1k[0], r2k[0], r2k[1], r2s[0], r2s[1], go[1], p1[0], p2[0], p2[1] }) |fd| _ = linux.close(fd);
        runHandshakeRecoverer(io, td.dir, terminal, 1, r1k[1], -1, go[0], -1, p1[1]);
    }
    kids[0] = .{ .pid = @intCast(a) };
    for ([_]*i32{ &r1k[1], &go[0], &p1[1] }) |p| closeAndClear(p);

    // Wait for R1 to be in the kill phase BEFORE R2 exists -- the barrier RoseCat #3 requires.
    var rb: [1]u8 = undefined;
    if (!readExactWithin(clock, r1k[0], &rb, terminal)) return error.R1NotInKill;
    // Prove R1 actually HOLDS the one global ledger flock right now: a parent non-blocking LOCK_EX attempt must be
    // EWOULDBLOCK (RoseCat 0b7805a #2). This is the fact that forces R2 to block on acquire.
    {
        const lf = std.posix.openatZ(td.dir.handle, ledger.LOCK_NAME, .{ .ACCMODE = .RDWR, .CREAT = true, .NOFOLLOW = true, .CLOEXEC = true }, 0o600) catch return error.LockOpen;
        defer _ = std.posix.system.close(lf);
        try std.testing.expectEqual(std.posix.E.AGAIN, std.posix.errno(std.posix.system.flock(lf, std.posix.LOCK.EX | std.posix.LOCK.NB)));
    }

    // R2: role 2 -- it announces it has STARTED (about to acquire), then blocks on the flock acquire while R1 holds
    // it; if it ever reaches the kill phase it announces on r2k.
    const b = linux.fork();
    if (linux.errno(b) != .SUCCESS) return error.Fork;
    if (b == 0) {
        for ([_]i32{ r1k[0], r2k[0], r2s[0], go[1], p1[0], p2[0] }) |fd| _ = linux.close(fd);
        runHandshakeRecoverer(io, td.dir, terminal, 2, -1, r2k[1], -1, r2s[1], p2[1]);
    }
    kids[1] = .{ .pid = @intCast(b) };
    for ([_]*i32{ &r2k[1], &r2s[1], &p2[1] }) |p| closeAndClear(p);

    // Barrier: wait until R2 has STARTED and is entering the acquire, so the negative window below judges a
    // recoverer that actually reached the contested flock -- not one the scheduler simply hadn't run yet.
    if (!readExactWithin(clock, r2s[0], &rb, terminal)) return error.R2NotStarted;

    // Pre-release window: R2 must NOT reach the kill phase while R1 holds the flock. Under the held-flock green
    // this times out; an early-unlock regime lets R2 acquire and reach the kill phase -> r2k becomes ready.
    const pre = ledger.waitWithinDeadline(clock, @min(clock.nowMs() + 1500, terminal), RealPoll{ .fd = r2k[0] });
    try std.testing.expectEqual(ledger.WaitResult.timed_out, pre); // held flock serialises -> R2 is blocked

    writeAll(go[1], "G"); // release R1 -> it finishes census + teardown + retire + releases the flock
    var r1: [2]u8 = undefined;
    var r2: [2]u8 = undefined;
    if (!readExactWithin(clock, p1[0], &r1, terminal)) return error.R1Lost;
    if (!readExactWithin(clock, p2[0], &r2, terminal)) return error.R2Lost;
    try std.testing.expect(reapWithin(clock, &kids[0], clock.nowMs() + 3000));
    try std.testing.expect(reapWithin(clock, &kids[1], clock.nowMs() + 3000));
    try std.testing.expect(terminal0(kids[0].status));
    try std.testing.expect(terminal0(kids[1].status));

    const sig = @intFromEnum(ledger.RecoveryAction.signalled);
    const gone = @intFromEnum(ledger.RecoveryAction.already_gone);
    try std.testing.expectEqual(@as(u8, sig), r1[0]); // R1 ran the recovery...
    try std.testing.expectEqual(@as(u8, 1), r1[1]); // ...and killed exactly one marked child (one kill phase)
    try std.testing.expectEqual(@as(u8, gone), r2[0]); // R2 blocked, then found it already retired
    try std.testing.expectEqual(@as(u8, 0), r2[1]); // R2 never entered the kill phase
    try std.testing.expectEqual(@as(usize, 0), try entryCount(io, gpa, td.dir));
}

// ---- 9e19fd0 / afdffbf: drive the REAL capability composite `zb_reaper_prod_fixed_point` (the production actuator
// reaches the SAME composite via `zb_reaper_prod_recover`). These rows causally exercise the grammar check, the
// UP-FRONT and FINAL pin/deadline revalidation, and the injected-callback selection, with every kill intercepted
// (no real Mac signal). The composite owns the ops ctx (`&pc`), so these fakes count via globals and ignore ctx. ---

const EPERM: c_int = @intFromEnum(std.posix.E.PERM);
var g_prod_kills: u32 = 0; // intercepted SIGKILLs through the composite (reset per row)
var g_prod_gone: bool = false; // engine_gone liveness: gone AFTER our kill
// (the step-clock call counter `g_now_calls` is declared above with nowCrossBeforeKill; reused here)

fn nowFar() callconv(.c) i64 {
    return 0; // far under any positive deadline -> the deadline never bites in these rows
}
// Returns < deadline on the FIRST call (up-front), then saturates: the empty census crosses the deadline exactly at
// the FINAL recheck, so only a composite that rechecks the deadline before Clean stays non-Clean (afdffbf #2).
fn nowStepExpire() callconv(.c) i64 {
    const n = g_now_calls;
    g_now_calls += 1;
    return if (n == 0) 0 else std.math.maxInt(i64);
}
fn scanEmpty(buf: ?*anyopaque, bytes: c_int) callconv(.c) c_int {
    _ = buf;
    _ = bytes;
    return 0; // a complete, EMPTY census every pass
}
// ctx-free match (identity readable -> killable) + a counting intercepted kill, for the composite seam.
fn pInspectMatch(pid: recovery.pid_t, dir: [*c]const u8, out: [*c]recovery.ReaperId, ctx: ?*anyopaque) callconv(.c) void {
    _ = pid;
    _ = dir;
    _ = ctx;
    out.* = .{ .matches = 1, .have_bsd = 1, .uid = linux.getuid(), .start_sec = 111, .start_usec = 0 };
}
fn pKillCount(pid: recovery.pid_t, sig: c_int, ctx: ?*anyopaque) callconv(.c) c_int {
    _ = pid;
    _ = ctx;
    if (sig == 0) return if (g_prod_gone) ESRCH else 0; // engine_gone probe: gone AFTER our kill
    g_prod_kills += 1; // the real SIGKILL -> INTERCEPTED (counted, never sent)
    g_prod_gone = true;
    return 0;
}
fn scanFull(buf: ?*anyopaque, bytes: c_int) callconv(.c) c_int {
    if (buf == null) return 64; // size estimate
    const cap: usize = @intCast(@divTrunc(bytes, @sizeOf(i32)));
    const p: [*]i32 = @ptrCast(@alignCast(buf.?));
    var i: usize = 0;
    while (i < cap) : (i += 1) p[i] = @intCast(900000 + i);
    return @intCast(cap); // n == cap every attempt -> gather stays full -> INCOMPLETE
}
fn scanOnePersistent(buf: ?*anyopaque, bytes: c_int) callconv(.c) c_int {
    if (buf == null) return 1;
    if (bytes < @sizeOf(i32)) return -1;
    const p: [*]i32 = @ptrCast(@alignCast(buf.?));
    p[0] = SCRIPTED_PID;
    return 1; // the same pid EVERY pass (never killed below -> never a clean empty census)
}
fn inspectUnreadable(pid: recovery.pid_t, dir: [*c]const u8, out: [*c]recovery.ReaperId, ctx: ?*anyopaque) callconv(.c) void {
    _ = pid;
    _ = dir;
    _ = ctx;
    out.* = .{ .matches = 1, .have_bsd = 0, .uid = @intCast(linux.getuid()), .start_sec = 0, .start_usec = 0 }; // identity UNREADABLE
}
fn killEPERM(pid: recovery.pid_t, sig: c_int, ctx: ?*anyopaque) callconv(.c) c_int {
    _ = pid;
    _ = ctx;
    if (sig == 0) return 0; // "still alive" on the liveness probe
    return EPERM; // the SIGKILL is refused EPERM -> a survivor, never clean
}

// Mutation-injection clocks (RoseCat afdffbf-followup #2/#3): a controlled side effect fires at the FINAL now()
// call (n == 1 for an empty census: call 0 is up-front, call 1 is the final recheck), so a change that happens
// strictly BETWEEN the up-front and final capability checks is exercised. They never cross the deadline (return 0),
// isolating the pin check (#2) and the path check (#3) from the deadline check.
var g_mut_fd: i32 = -1; // the held fd whose mode `nowChmodAtFinal` flips (#2)
var g_mut_dirfd: i32 = -1; // the runtime dir fd `nowSwapAtFinal` renames within (#3)
var g_now_n: usize = 0;
fn nowChmodAtFinal() callconv(.c) i64 {
    const n = g_now_n;
    g_now_n += 1;
    if (n == 1 and g_mut_fd >= 0) _ = linux.fchmod(g_mut_fd, 0o755); // identity changes between up-front and FINAL pin
    return 0;
}
fn nowSwapAtFinal() callconv(.c) i64 {
    const n = g_now_n;
    g_now_n += 1;
    if (n == 1 and g_mut_dirfd >= 0) { // rename the held inode away + plant a replacement at the old path
        _ = linux.renameat(g_mut_dirfd, BASENAME, g_mut_dirfd, BASENAME ++ "-win");
        _ = linux.mkdirat(g_mut_dirfd, BASENAME, 0o700);
    }
    return 0;
}
// Injectable clock reads for the fail-closed mapping oracle (#4).
fn failClock() recovery.ClockRead {
    return .{ .ok = false, .sec = 999, .nsec = 0 }; // a FAILED read; the sec/nsec must be ignored
}
fn okClock() recovery.ClockRead {
    return .{ .ok = true, .sec = 5, .nsec = 500_000_000 };
}

// A row's held fd + its matching pin, under a fresh run dir; resets the per-row global counters.
fn prodFixture(td: *std.testing.TmpDir) !struct { fd: i32, pinned: recovery.DirId } {
    _ = try makeRunDir(td.dir, true);
    const fd = try openRunDir(td.dir);
    const pinned = recovery.pinDir(td.dir, BASENAME) orelse return error.Pin;
    g_pass = 0;
    g_prod_kills = 0;
    g_prod_gone = false;
    g_now_calls = 0;
    g_now_n = 0;
    g_mut_fd = -1;
    g_mut_dirfd = -1;
    return .{ .fd = fd, .pinned = pinned };
}

test "afdffbf composite: the happy path reaches Clean with exactly one intercepted kill" {
    if (!inPrivatePidNamespace()) return error.NotInPrivatePidNamespace;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    const f = try prodFixture(&td);
    defer _ = std.posix.system.close(f.fd);
    // scanCb: pass 1 yields the marked pid, every later pass is empty -> the revalidated empty final census.
    const fp = recovery.prodFixedPoint(&scanCb, &pInspectMatch, &pKillCount, f.fd, &f.pinned, &nowFar, 1000, DUMMY_PATH, 8);
    try std.testing.expectEqual(ledger.FixedPoint.clean, fp);
    try std.testing.expectEqual(@as(u32, 1), g_prod_kills);
}

test "afdffbf composite: an incomplete libproc scan is non-Clean (incomplete), zero action" {
    if (!inPrivatePidNamespace()) return error.NotInPrivatePidNamespace;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    const f = try prodFixture(&td);
    defer _ = std.posix.system.close(f.fd);
    const fp = recovery.prodFixedPoint(&scanFull, &pInspectMatch, &pKillCount, f.fd, &f.pinned, &nowFar, 1000, DUMMY_PATH, 3);
    try std.testing.expectEqual(ledger.FixedPoint.incomplete, fp);
    try std.testing.expectEqual(@as(u32, 0), g_prod_kills);
}

test "afdffbf composite: an UNREADABLE identity is never swept -> non-Clean, zero kills" {
    if (!inPrivatePidNamespace()) return error.NotInPrivatePidNamespace;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    const f = try prodFixture(&td);
    defer _ = std.posix.system.close(f.fd);
    const fp = recovery.prodFixedPoint(&scanOnePersistent, &inspectUnreadable, &pKillCount, f.fd, &f.pinned, &nowFar, 1000, DUMMY_PATH, 3);
    try std.testing.expect(fp != .clean); // never clean while an unreadable-identity match persists
    try std.testing.expectEqual(@as(u32, 0), g_prod_kills); // never killed (have_bsd == 0)
}

test "afdffbf composite: an EPERM kill is a survivor -> non-Clean" {
    if (!inPrivatePidNamespace()) return error.NotInPrivatePidNamespace;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    const f = try prodFixture(&td);
    defer _ = std.posix.system.close(f.fd);
    const fp = recovery.prodFixedPoint(&scanOnePersistent, &pInspectMatch, &killEPERM, f.fd, &f.pinned, &nowFar, 1000, DUMMY_PATH, 3);
    try std.testing.expect(fp != .clean); // an EPERM-refused kill is a survivor, never clean
}

test "afdffbf #2: a wrong UP-FRONT pin never authorizes a Clean teardown, zero action" {
    if (!inPrivatePidNamespace()) return error.NotInPrivatePidNamespace;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    const f = try prodFixture(&td);
    defer _ = std.posix.system.close(f.fd);
    var bogus = f.pinned;
    bogus.ino +%= 1; // the held fd no longer fstats to this pinned identity
    // An EMPTY census would otherwise return Clean; the up-front pin check must fail closed before the engine.
    const fp = recovery.prodFixedPoint(&scanEmpty, &pInspectMatch, &pKillCount, f.fd, &bogus, &nowFar, 1000, DUMMY_PATH, 3);
    try std.testing.expect(fp != .clean);
    try std.testing.expectEqual(@as(u32, 0), g_prod_kills);
}

test "afdffbf #2: the deadline crossing at the FINAL recheck downgrades an empty census from Clean" {
    if (!inPrivatePidNamespace()) return error.NotInPrivatePidNamespace;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    const f = try prodFixture(&td);
    defer _ = std.posix.system.close(f.fd);
    // nowStepExpire: < deadline up front (census runs, empty -> would be Clean), saturated by the final recheck.
    const fp = recovery.prodFixedPoint(&scanEmpty, &pInspectMatch, &pKillCount, f.fd, &f.pinned, &nowStepExpire, 1000, DUMMY_PATH, 3);
    try std.testing.expectEqual(ledger.FixedPoint.incomplete, fp);
    try std.testing.expectEqual(@as(u32, 0), g_prod_kills);
}

test "afdffbf composite: a dir failing the sockdir grammar fails closed before the engine, zero action" {
    if (!inPrivatePidNamespace()) return error.NotInPrivatePidNamespace;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    const f = try prodFixture(&td);
    defer _ = std.posix.system.close(f.fd);
    // "/tmp" is not the sockdir grammar; a mutant dropping the grammar check would run the engine and reach Clean.
    const fp = recovery.prodFixedPoint(&scanCb, &pInspectMatch, &pKillCount, f.fd, &f.pinned, &nowFar, 1000, "/tmp", 8);
    try std.testing.expect(fp != .clean);
    try std.testing.expectEqual(@as(u32, 0), g_prod_kills);
}

const EINVAL: c_int = @intFromEnum(std.posix.E.INVAL);

test "afdffbf #1: a NULL clock is rejected before any callback (EINVAL, zero action)" {
    if (!inPrivatePidNamespace()) return error.NotInPrivatePidNamespace;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    const f = try prodFixture(&td);
    defer _ = std.posix.system.close(f.fd);
    // At the composite boundary: a recoverable dead entry would otherwise be signalled, but the mandatory deadline
    // capability (a non-null clock) is absent -> reject with EINVAL before scan/inspect/kill.
    const r = recovery.prodFixedPointRc(&scanCb, &pInspectMatch, &pKillCount, f.fd, &f.pinned, null, 1000, DUMMY_PATH, 8);
    try std.testing.expectEqual(EINVAL, r.@"0");
    try std.testing.expect(r.@"1" != .clean);
    try std.testing.expectEqual(@as(u32, 0), g_prod_kills); // no callback ran
}

test "afdffbf #2: the pinned identity CHANGING at the FINAL check downgrades an empty census from Clean" {
    if (!inPrivatePidNamespace()) return error.NotInPrivatePidNamespace;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    const f = try prodFixture(&td);
    defer _ = std.posix.system.close(f.fd);
    g_mut_fd = f.fd; // nowChmodAtFinal flips the held dir's mode at the final clock call (after the up-front pin check)
    const fp = recovery.prodFixedPoint(&scanEmpty, &pInspectMatch, &pKillCount, f.fd, &f.pinned, &nowChmodAtFinal, 1000, DUMMY_PATH, 3);
    try std.testing.expect(fp != .clean); // up-front pin passed; ONLY the FINAL pin recheck catches the mode change
    try std.testing.expectEqual(@as(u32, 0), g_prod_kills);
}

test "afdffbf #3: a RENAME of the held inode after capture fails closed before Clean (classifier bound to the fd)" {
    if (!inPrivatePidNamespace()) return error.NotInPrivatePidNamespace;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    const f = try prodFixture(&td);
    defer _ = std.posix.system.close(f.fd);
    g_mut_dirfd = td.dir.handle; // nowSwapAtFinal renames BASENAME away + plants a replacement at the final clock call
    const fp = recovery.prodFixedPoint(&scanEmpty, &pInspectMatch, &pKillCount, f.fd, &f.pinned, &nowSwapAtFinal, 1000, DUMMY_PATH, 3);
    try std.testing.expect(fp != .clean); // the held inode's fstat still matches, but its CURRENT path diverged -> fail closed
    try std.testing.expectEqual(@as(u32, 0), g_prod_kills);
}

test "afdffbf #4: a FAILED clock read saturates (fail closed) without reading the timespec; a good read maps to ms" {
    try std.testing.expectEqual(std.math.maxInt(i64), recovery.nowMsFrom(&failClock)); // failure -> deadline crossed
    try std.testing.expectEqual(@as(i64, 5500), recovery.nowMsFrom(&okClock)); // 5s + 500ms
}
