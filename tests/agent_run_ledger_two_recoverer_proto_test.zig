//! MS6.5.1 OPEN whole-recovery blocker bd zigBrowser-3gl, red for 7b29fd6 item 1 (the exact-result two-recoverer
//! oracle). This is an UNREGISTERED, TEST-ONLY PROTOTYPE — there is NO production recovery transaction, and none is
//! added until RoseCat approves the design. The prototype `protoRecoverOneUnderLock` lives only here and is built
//! from the public ledger API (acquireLock / load / probeLivenessTagged / recoveryFor / publish).
//!
//! The oracle causally pins the whole-recovery claim (not just a boolean): with two independent recoverers racing
//! ONE proved-dead entry under the global flock, the correct (flock-held-across-the-whole-recovery) design yields
//! the EXACT pair {.signalled, .already_gone}, BOTH children exit terminally (status 0), exactly ONE signal-phase
//! entry (reap), and an EMPTY final ledger. The mutant this must catch — releasing the flock right after the read
//! (this prototype's current behaviour) — lets BOTH recoverers enter the signal phase (two reaps) and breaks the
//! pair, so the oracle fails. The GREEN (flock held across read→revalidate→signal→retire) lands with the approved
//! design. Signal path: a kernel-proof PID-ns sentinel gates every fork; the build runner wraps it in unshare.
const std = @import("std");
const ledger = @import("agent_run_ledger");
const linux = std.os.linux;

const BASENAME = "zigbrowser-agent-424242-00aa00aa00aa00aa";

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

const Ops = struct {
    ready_fd: i32,
    sleep_ms: i64,
    reaped: *bool,
    pub fn afterRead(self: Ops) void {
        if (self.ready_fd >= 0) _ = linux.write(self.ready_fd, "R", 1);
    }
    pub fn beforeReap(self: Ops) void {
        var ts: linux.timespec = .{ .sec = 0, .nsec = self.sleep_ms * std.time.ns_per_ms };
        _ = linux.nanosleep(&ts, &ts);
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

/// TEST-ONLY prototype. CURRENT = the early-unlock MUTANT: it releases the flock right after the read, so two
/// recoverers both enter the signal phase. The green holds the flock across read→revalidate→signal→retire.
fn protoRecoverOneUnderLock(io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir, basename: []const u8, max_tries: u32, backoff_ms: i64, ops: Ops) ProtoAction {
    var lock = ledger.acquireLock(io, dir, max_tries, backoff_ms) catch return .fail_closed;
    var l = ledger.load(io, gpa, dir, "runs.json") catch {
        lock.close(io);
        return .fail_closed;
    };
    defer l.deinit();
    const idx = indexOf(&l, basename);
    lock.close(io); // MUTANT: release right after the read (not across revalidate+signal+retire)
    ops.afterRead();
    if (idx == null) return .already_gone;
    const e = l.entries()[idx.?];
    switch (ledger.recoveryFor(ledger.probeLivenessTagged(e.pid, e.start_kind, e.start_sec, e.start_usec))) {
        .leave => return .left,
        .fail_closed => return .fail_closed,
        .recover => {
            ops.beforeReap();
            ops.reap();
            publishWithout(io, dir, "runs.json", &l, basename) catch return .fail_closed;
            return .signalled;
        },
    }
}

fn runRecoverer(io: std.Io, dir: std.Io.Dir, ready_fd: i32, result_fd: i32) noreturn {
    var reaped = false;
    const act = protoRecoverOneUnderLock(io, std.heap.page_allocator, dir, BASENAME, 1000, 5, Ops{ .ready_fd = ready_fd, .sleep_ms = 1000, .reaped = &reaped });
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

    var b1ready: [2]i32 = undefined;
    var b1res: [2]i32 = undefined;
    var b2res: [2]i32 = undefined;
    try std.testing.expect(linux.pipe(&b1ready) == 0);
    try std.testing.expect(linux.pipe(&b1res) == 0);
    try std.testing.expect(linux.pipe(&b2res) == 0);

    const b1 = linux.fork();
    if (b1 == 0) {
        _ = linux.close(b1ready[0]);
        _ = linux.close(b1res[0]);
        _ = linux.close(b2res[0]);
        _ = linux.close(b2res[1]);
        runRecoverer(io, td.dir, b1ready[1], b1res[1]);
    }
    if (linux.errno(b1) != .SUCCESS) return error.ForkFailed;
    _ = linux.close(b1ready[1]);
    var rb: [1]u8 = undefined;
    try std.testing.expect(linux.read(b1ready[0], &rb, 1) == 1); // recoverer 1 has read the ledger

    const b2 = linux.fork();
    if (b2 == 0) {
        _ = linux.close(b1res[0]);
        _ = linux.close(b1res[1]);
        _ = linux.close(b2res[0]);
        runRecoverer(io, td.dir, -1, b2res[1]);
    }
    if (linux.errno(b2) != .SUCCESS) return error.ForkFailed;
    _ = linux.close(b1res[1]);
    _ = linux.close(b2res[1]);

    var r1: [2]u8 = undefined;
    var r2: [2]u8 = undefined;
    try std.testing.expect(linux.read(b1res[0], &r1, 2) == 2);
    try std.testing.expect(linux.read(b2res[0], &r2, 2) == 2);
    var s1: u32 = undefined;
    var s2: u32 = undefined;
    _ = linux.waitpid(@intCast(b1), &s1, 0);
    _ = linux.waitpid(@intCast(b2), &s2, 0);
    _ = linux.close(b1ready[0]);
    _ = linux.close(b1res[0]);
    _ = linux.close(b2res[0]);

    // (a) both children exited terminally with status 0
    try std.testing.expect(terminal0(s1));
    try std.testing.expect(terminal0(s2));

    // (b) exactly ONE recoverer entered the signal phase (reaped)
    try std.testing.expectEqual(@as(u32, 1), @as(u32, r1[1]) + @as(u32, r2[1]));

    // (c) the EXACT action pair is {.signalled, .already_gone} (in either order)
    const sig = @intFromEnum(ProtoAction.signalled);
    const gone = @intFromEnum(ProtoAction.already_gone);
    const pair_ok = (r1[0] == sig and r2[0] == gone) or (r1[0] == gone and r2[0] == sig);
    try std.testing.expect(pair_ok);

    // (d) the final ledger is EMPTY (the one recoverer retired the entry)
    var l = try ledger.load(io, gpa, td.dir, "runs.json");
    defer l.deinit();
    try std.testing.expectEqual(@as(usize, 0), l.entries().len);
}
