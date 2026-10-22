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
    pub fn run(_: CleanWiring, run_dir_fd: i32, pinned: *const recovery.DirId, deadline_ms: i64) ledger.FixedPoint {
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
