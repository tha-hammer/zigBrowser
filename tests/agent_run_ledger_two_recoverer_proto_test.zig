//! MS6.5.1 OPEN whole-recovery blocker bd zigBrowser-3gl, red for 7b29fd6 item 1 (the exact-result two-recoverer
//! oracle). UNREGISTERED, TEST-ONLY PROTOTYPE — there is NO production recovery transaction, and none is added
//! until RoseCat approves the design. `protoRecoverOneUnderLock` lives only here, built from the public ledger API
//! (acquireLock / load / probeLivenessTagged / recoveryFor / publish).
//!
//! The oracle causally pins the whole-recovery claim (not a boolean): with two independent recoverers racing ONE
//! proved-dead entry under the global flock, the correct (flock-held-across-the-whole-recovery) design yields the
//! EXACT pair {.signalled, .already_gone}, BOTH children terminal (status 0), exactly ONE signal-phase entry
//! (reap), and an EMPTY final ledger. The early-unlock mutant (this prototype's current `EARLY_UNLOCK = true`)
//! releases the flock right after the read, so BOTH recoverers enter the signal phase — the oracle fails.
//!
//! DETERMINISM (fixes RoseCat 7679 — the old fixed `beforeReap` window let the mutant survive 10/10 on a fast
//! host): the race is driven by a HANDSHAKE, not a timing window. Recoverer 1 reads, signals "read done" and then
//! BLOCKS until the parent says proceed. The parent starts recoverer 2 and waits for ITS "read done" signal: in
//! the mutant recoverer 2 acquires the released flock and reads immediately, so its signal arrives fast and the
//! parent lets both proceed → two reaps; in the green recoverer 2 blocks on the held flock and never signals, so
//! the parent times out, lets recoverer 1 retire+release, and recoverer 2 then reads the entry gone → one reap.
//! The mutant path never depends on host speed. Signal path gated by a kernel-proof PID-ns sentinel; the build
//! runner wraps it in unshare.
const std = @import("std");
const ledger = @import("agent_run_ledger");
const linux = std.os.linux;

const BASENAME = "zigbrowser-agent-424242-00aa00aa00aa00aa";
const EARLY_UNLOCK = true; // current prototype behaviour = the mutant; the green flips this to false

const OUTER_NS_FD: i32 = 9;
const NS_GET_NSTYPE: u32 = 0xB703;
const NS_GET_TGID_IN_PIDNS: u32 = 0x8004B709;
const CLONE_NEWPID: usize = 0x20000000;
const AT_EMPTY_PATH: u32 = 0x1000;

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

const ProtoAction = enum { signalled, left, fail_closed, already_gone };

/// Handshake seam. `readdone_fd`: write the one-byte present flag when the read completes (-1 = skip). `proceed_fd`:
/// if >= 0, BLOCK reading one byte before the signal phase (recoverer 1 waits so recoverer 2 can race first).
const Ops = struct {
    readdone_fd: i32,
    proceed_fd: i32,
    reaped: *bool,
    pub fn afterRead(self: Ops, present: bool) void {
        if (self.readdone_fd >= 0) {
            const b = [1]u8{if (present) 1 else 0};
            _ = linux.write(self.readdone_fd, &b, 1);
        }
        if (self.proceed_fd >= 0) {
            var b: [1]u8 = undefined;
            _ = linux.read(self.proceed_fd, &b, 1); // wait for the parent to release us into the signal phase
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

/// TEST-ONLY prototype. With `EARLY_UNLOCK` it releases the flock right after the read (the mutant); the green
/// variant holds the flock across read→revalidate→signal→retire (releases only at the end via the defer).
fn protoRecoverOneUnderLock(io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir, basename: []const u8, max_tries: u32, backoff_ms: i64, ops: Ops) ProtoAction {
    var lock = ledger.acquireLock(io, dir, max_tries, backoff_ms) catch return .fail_closed;
    var l = ledger.load(io, gpa, dir, "runs.json") catch {
        lock.close(io);
        return .fail_closed;
    };
    defer l.deinit();
    const idx = indexOf(&l, basename);
    if (EARLY_UNLOCK) lock.close(io) else {} // MUTANT: unlock right after the read
    defer if (!EARLY_UNLOCK) lock.close(io); // GREEN: hold across the whole recovery
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

fn runRecoverer(io: std.Io, dir: std.Io.Dir, readdone_fd: i32, proceed_fd: i32, result_fd: i32) noreturn {
    var reaped = false;
    const act = protoRecoverOneUnderLock(io, std.heap.page_allocator, dir, BASENAME, 2000, 5, Ops{ .readdone_fd = readdone_fd, .proceed_fd = proceed_fd, .reaped = &reaped });
    const b = [2]u8{ @intFromEnum(act), if (reaped) 1 else 0 };
    _ = linux.write(result_fd, &b, 2);
    linux.exit_group(0);
}

fn terminal0(status: u32) bool {
    return (status & 0x7f) == 0 and ((status >> 8) & 0xff) == 0; // WIFEXITED && code==0
}

test "two recoverers, exact result: {signalled, already_gone}, one signal phase, empty ledger, terminal children" {
    if (!inPrivatePidNamespace()) return error.NotInPrivatePidNamespace;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();

    const dead_pid: i32 = 2147483646; // absent + reuse-proof in this fresh PID namespace
    const seed = [_]ledger.Entry{.{ .basename = BASENAME, .dev = 1, .ino = 2, .uid = 0, .mode = 16832, .pid = dead_pid, .start_kind = .linux_ticks, .start_sec = 123456, .start_usec = 0, .state = .active }};
    try ledger.publish(io, td.dir, "runs.json", &seed);

    var b1rd: [2]i32 = undefined; // recoverer 1 "read done"
    var b1go: [2]i32 = undefined; // parent -> recoverer 1 "proceed"
    var b2rd: [2]i32 = undefined; // recoverer 2 "read done"
    var b1res: [2]i32 = undefined;
    var b2res: [2]i32 = undefined;
    for ([_]*[2]i32{ &b1rd, &b1go, &b2rd, &b1res, &b2res }) |p| try std.testing.expect(linux.pipe(p) == 0);

    // Recoverer 1: signals read-done, then waits for the parent's go before the signal phase.
    const b1 = linux.fork();
    if (b1 == 0) {
        _ = linux.close(b1rd[0]);
        _ = linux.close(b1go[1]);
        _ = linux.close(b2rd[0]);
        _ = linux.close(b2rd[1]);
        _ = linux.close(b1res[0]);
        _ = linux.close(b2res[0]);
        _ = linux.close(b2res[1]);
        runRecoverer(io, td.dir, b1rd[1], b1go[0], b1res[1]);
    }
    if (linux.errno(b1) != .SUCCESS) return error.ForkFailed;
    var rb: [1]u8 = undefined;
    try std.testing.expect(linux.read(b1rd[0], &rb, 1) == 1); // recoverer 1 read the entry (present)

    // Recoverer 2: signals read-done, does NOT wait (proceed_fd = -1).
    const b2 = linux.fork();
    if (b2 == 0) {
        _ = linux.close(b1rd[0]);
        _ = linux.close(b1go[0]);
        _ = linux.close(b1go[1]);
        _ = linux.close(b2rd[0]);
        _ = linux.close(b1res[0]);
        _ = linux.close(b1res[1]);
        _ = linux.close(b2res[0]);
        runRecoverer(io, td.dir, b2rd[1], -1, b2res[1]);
    }
    if (linux.errno(b2) != .SUCCESS) return error.ForkFailed;
    _ = linux.close(b2rd[1]);

    // Wait up to ~3s for recoverer 2's read-done. Mutant: it acquires the released flock and reads fast, so its
    // signal arrives → both proceed. Green: it blocks on the held flock and never signals → timeout, then we let
    // recoverer 1 retire and release so recoverer 2 reads the entry gone.
    var pfd = [_]linux.pollfd{.{ .fd = b2rd[0], .events = linux.POLL.IN, .revents = 0 }};
    _ = linux.poll(&pfd, 1, 3000);
    _ = linux.write(b1go[1], "G", 1); // release recoverer 1 into the signal phase (both cases)

    var r1: [2]u8 = undefined;
    var r2: [2]u8 = undefined;
    try std.testing.expect(linux.read(b1res[0], &r1, 2) == 2);
    try std.testing.expect(linux.read(b2res[0], &r2, 2) == 2);
    var s1: u32 = undefined;
    var s2: u32 = undefined;
    _ = linux.waitpid(@intCast(b1), &s1, 0);
    _ = linux.waitpid(@intCast(b2), &s2, 0);
    for ([_]i32{ b1rd[0], b1go[1], b2rd[0], b1res[0], b2res[0] }) |fd| _ = linux.close(fd);

    try std.testing.expect(terminal0(s1)); // both children exited terminally (status 0)
    try std.testing.expect(terminal0(s2));
    try std.testing.expectEqual(@as(u32, 1), @as(u32, r1[1]) + @as(u32, r2[1])); // exactly ONE signal-phase entry
    const sig = @intFromEnum(ProtoAction.signalled);
    const gone = @intFromEnum(ProtoAction.already_gone);
    const pair_ok = (r1[0] == sig and r2[0] == gone) or (r1[0] == gone and r2[0] == sig); // EXACT {signalled, already_gone}
    try std.testing.expect(pair_ok);
    var l = try ledger.load(io, gpa, td.dir, "runs.json"); // EMPTY final ledger (entry retired)
    defer l.deinit();
    try std.testing.expectEqual(@as(usize, 0), l.entries().len);
}
