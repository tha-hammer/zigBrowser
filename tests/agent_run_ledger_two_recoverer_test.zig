//! MS6.5.1 red (whole-recovery claim; RoseCat 97c6215 #3; macOS-plan Rev 26). Two INDEPENDENT recoverer processes
//! race the whole recovery of ONE proved-dead entry under the ONE global flock. Because the flock is held across
//! the WHOLE recovery (read -> revalidate -> signal phase -> retire), EXACTLY ONE recoverer enters the signal
//! phase; the other, once it acquires, re-reads and finds the entry already gone and does nothing. The signal
//! phase is an injectable seam (recording `.signalled` return), so no real signal is sent. UNREGISTERED until green.
//!
//! SAFETY: this is the signal-phase recovery transaction, so it runs ONLY inside a PID namespace strictly below
//! its launcher's — a kernel-proof sentinel (fd 9) gates every fork; the build step wraps it in unshare.
//!
//! The mutant this catches: release the flock EARLY (hold it only across the read, not across revalidate + the
//! signal phase + retire). Then both recoverers read the entry present before either retires it, and BOTH enter
//! the signal phase -> two signals for one dead run.
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

/// Injectable seam. `afterRead` optionally signals the harness that the read is done (so the parent can start the
/// second recoverer at that exact point); `beforeReap` opens a window where the other recoverer can race; `reap`
/// is the production signal phase (a no-op here — the `.signalled` return is the observable).
const Ops = struct {
    ready_fd: i32,
    sleep_ms: i64,
    reaped: *bool, // set true the instant the signal phase is ENTERED (independent of whether retire then succeeds)
    pub fn afterRead(self: Ops) void {
        if (self.ready_fd >= 0) _ = linux.write(self.ready_fd, "R", 1);
    }
    pub fn beforeReap(self: Ops) void {
        var ts: linux.timespec = .{ .sec = 0, .nsec = self.sleep_ms * std.time.ns_per_ms };
        _ = linux.nanosleep(&ts, &ts);
    }
    pub fn reap(self: Ops, basename: []const u8) void {
        _ = basename;
        self.reaped.* = true;
    }
};

fn runRecoverer(io: std.Io, dir: std.Io.Dir, ready_fd: i32, result_fd: i32) noreturn {
    // 1000ms beforeReap window (comfortably longer than the second recoverer's fork+start+acquire+read, so the
    // early-release mutant deterministically races); a 5s acquire deadline (1000 tries x 5ms) >> the window, so in
    // the green the blocked recoverer still acquires after the holder releases and finds the entry gone.
    var reaped = false;
    _ = ledger.recoverOneUnderLock(io, std.heap.page_allocator, dir, "runs.json", BASENAME, 1000, 5, Ops{ .ready_fd = ready_fd, .sleep_ms = 1000, .reaped = &reaped });
    // Report whether THIS recoverer ENTERED the signal phase (reaped) — the observable the whole-recovery claim
    // bounds, independent of whether its retire/publish then raced.
    const b = [1]u8{if (reaped) 1 else 0};
    _ = linux.write(result_fd, &b, 1);
    linux.exit_group(0);
}

test "two recoverers race one dead entry: exactly one enters the signal phase; the other finds it gone" {
    if (!inPrivatePidNamespace()) return error.NotInPrivatePidNamespace;
    const io = std.testing.io;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();

    // A PROVED-DEAD owner: a high pid that is absent in this fresh PID namespace AND cannot be reused by the
    // recoverer forks (which get low pids), so probeLivenessTagged reliably returns .dead (-> .recover) and never
    // a false .live_reused from a reaped-then-reused pid.
    const dead_pid: i32 = 2147483646;

    const seed = [_]ledger.Entry{.{ .basename = BASENAME, .dev = 1, .ino = 2, .uid = 0, .mode = 16832, .pid = dead_pid, .start_kind = .linux_ticks, .start_sec = 123456, .start_usec = 0, .state = .active }};
    try ledger.publish(io, td.dir, "runs.json", &seed);

    var b1ready: [2]i32 = undefined;
    var b1res: [2]i32 = undefined;
    var b2res: [2]i32 = undefined;
    try std.testing.expect(linux.pipe(&b1ready) == 0);
    try std.testing.expect(linux.pipe(&b1res) == 0);
    try std.testing.expect(linux.pipe(&b2res) == 0);

    // Recoverer 1: signals ready after its read, so the parent can start recoverer 2 at that exact moment.
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

    // Recoverer 2 starts now. In the green, recoverer 1 still HOLDS the flock (it signalled ready while holding),
    // so recoverer 2 blocks on acquire until recoverer 1 retires + releases, then reads the entry gone. In the
    // early-release mutant, recoverer 1 already released, so recoverer 2 reads the entry still present and races.
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

    var r1: [1]u8 = undefined;
    var r2: [1]u8 = undefined;
    try std.testing.expect(linux.read(b1res[0], &r1, 1) == 1);
    try std.testing.expect(linux.read(b2res[0], &r2, 1) == 1);
    var s1: u32 = undefined;
    var s2: u32 = undefined;
    _ = linux.waitpid(@intCast(b1), &s1, 0);
    _ = linux.waitpid(@intCast(b2), &s2, 0);
    _ = linux.close(b1ready[0]);
    _ = linux.close(b1res[0]);
    _ = linux.close(b2res[0]);

    // EXACTLY one recoverer entered the signal phase (reaped); the other found the entry already gone and did not.
    const n: u32 = @as(u32, r1[0]) + @as(u32, r2[0]);
    try std.testing.expectEqual(@as(u32, 1), n);
}
