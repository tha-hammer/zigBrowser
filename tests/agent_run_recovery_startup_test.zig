//! MS6.5.1 — RED-FIRST for the `reaper_ready` arming gate + the startup-recovery CORE (bd zigBrowser-3gl, follow-on
//! to the APPROVED Darwin actuator d375eb2 / 03a7436; strengthened per RoseCat 33a9bf2). UNREGISTERED (built by no
//! gate step), UNARMED, signal-free fakes only, off the Macs. RED by compile error until the green commit adds to
//! `src/agent_run_recovery.zig`: `reaper_ready`, `MAX_RECOVER_PER_START`, `StartupStatus`, `StartupReport`,
//! `recoverAllAtStartup`, `recoverAllAtStartupGated`.
//!
//! SCOPE (RoseCat 33a9bf2 #1): this slice is the startup-recovery CORE. Wiring a real app-startup OWNER that calls
//! `recoverAllAtStartup` is an OPEN integration blocker, retained separately — it is deliberately NOT in this slice.
//!
//! TWO-FACTOR SAFETY: a production signal is possible ONLY when BOTH the immutable gate `reaper_ready` is true AND
//! the caller runs the per-entry whole-recovery transaction. `.signalled` is the ACTION LABEL the signal-free fake
//! lease returns on the recover path, not a real kill, so these rows need no fork and no PID-namespace sentinel.
const std = @import("std");
const linux = std.os.linux;
const ledger = @import("agent_run_ledger");
const recovery = @import("agent_run_recovery");

const BASENAME = "zigbrowser-agent-515151-00bb00bb00bb00bb";
const DEAD_PID: i32 = 2147483645; // absent + reuse-proof
const BUDGET_MS: i64 = 30000;

extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern fn unsetenv(name: [*:0]const u8) c_int;

// ---- deterministic, signal-free injected actuator + typed lease (the production transaction's fake shape) --------

const FakeLease = struct {
    fp: ledger.FixedPoint,
    td: ledger.Teardown,
    pub fn fixedPoint(self: *FakeLease, clock: anytype, deadline_ms: i64) ledger.FixedPoint {
        _ = clock;
        _ = deadline_ms;
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
const FakePin = union(enum) { held: FakeLease, gone, mismatch, unreadable };
const HELD_CLEAN = FakePin{ .held = .{ .fp = .clean, .td = .done } };

/// Counts every `pin` call: the ONLY path to a census/kill is through `pin`, so `pins == 0` proves zero reachable
/// action. `result` lets a row drive any outcome (held->signalled, gone->reconciled, mismatch->fail_closed).
const CountingActuator = struct {
    pins: *usize,
    result: FakePin,
    pub fn pin(self: CountingActuator, dir: std.Io.Dir, entry: ledger.Entry) FakePin {
        _ = dir;
        _ = entry;
        self.pins.* += 1;
        return self.result;
    }
};
fn act(pins: *usize, result: FakePin) CountingActuator {
    return .{ .pins = pins, .result = result };
}

/// Routes per entry: the one basename in `fail_bn` pins `.mismatch` (-> fail_closed); every other `.held`/clean/done
/// (-> signalled). Proves a fail-closed entry is tallied and never hidden by the signalled ones.
const RoutingActuator = struct {
    pins: *usize,
    fail_bn: []const u8,
    pub fn pin(self: RoutingActuator, dir: std.Io.Dir, entry: ledger.Entry) FakePin {
        _ = dir;
        self.pins.* += 1;
        if (std.mem.eql(u8, entry.basename, self.fail_bn)) return .mismatch;
        return HELD_CLEAN;
    }
};

fn entryOf(basename: []const u8, pid: i32, start_sec: u64, state: ledger.State, ino: u64) ledger.Entry {
    return .{ .basename = basename, .dev = 1, .ino = ino, .uid = 0, .mode = 16832, .pid = pid, .start_kind = .linux_ticks, .start_sec = start_sec, .start_usec = 0, .state = state };
}
fn seedActive(io: std.Io, dir: std.Io.Dir, pid: i32, start_sec: u64) !void {
    try ledger.publish(io, dir, "runs.json", &[_]ledger.Entry{entryOf(BASENAME, pid, start_sec, .active, 2)});
}
fn entryCount(io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir) !usize {
    var l = try ledger.load(io, gpa, dir, "runs.json");
    defer l.deinit();
    return l.entries().len;
}
var g_bn_bufs: [128][64]u8 = undefined;
fn basenameN(i: usize) []const u8 {
    return std.fmt.bufPrint(&g_bn_bufs[i], "zigbrowser-agent-515151-{x:0>16}", .{i}) catch unreachable;
}
fn seedActiveN(io: std.Io, dir: std.Io.Dir, n: usize) !void {
    var ents: [128]ledger.Entry = undefined;
    for (0..n) |i| ents[i] = entryOf(basenameN(i), DEAD_PID, 234567, .active, 2 + i);
    try ledger.publish(io, dir, "runs.json", ents[0..n]);
}

// ================================================================================================================
// RoseCat 33a9bf2 #3: `reaper_ready` is a LITERAL immutable source constant; no env/argv/build-option arming.
// ================================================================================================================

test "#3 reaper_ready is the literal immutable false source constant (not build-option/env/argv derived)" {
    comptime { // a runtime (env/argv) source would make this non-comptime and fail to compile as a comptime branch
        if (recovery.reaper_ready != false) @compileError("reaper_ready must ship false");
    }
    const gpa = std.testing.allocator;
    const src = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/agent_run_recovery.zig", gpa, .limited(1 << 20));
    defer gpa.free(src);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub const reaper_ready: bool = false;") != null); // literal constant
    try std.testing.expect(std.mem.indexOf(u8, src, "build_options") == null); // never build-option armed
}

test "#3 setting a plausible arming env var does NOT arm the gate (still disabled, zero pin)" {
    _ = setenv("ZB_REAPER_READY", "1", 1);
    _ = setenv("REAPER_READY", "true", 1);
    defer _ = unsetenv("ZB_REAPER_READY");
    defer _ = unsetenv("REAPER_READY");
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const clock = ledger.RealClock{ .io = io };
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    try seedActive(io, td.dir, DEAD_PID, 234567);
    var pins: usize = 0;
    const rep = recovery.recoverAllAtStartup(io, gpa, td.dir, "runs.json", clock, clock.nowMs() + BUDGET_MS, act(&pins, HELD_CLEAN));
    try std.testing.expectEqual(false, recovery.reaper_ready);
    try std.testing.expectEqual(recovery.StartupStatus.disabled, rep.status);
    try std.testing.expectEqual(@as(usize, 0), pins);
}

// ================================================================================================================
// RoseCat 33a9bf2 #2: gate OFF reads NO ledger — missing, corrupt and unreadable stores all disabled, zero action.
// ================================================================================================================

fn expectGateOffNoRead(io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir) !void {
    var pins: usize = 0;
    const clock = ledger.RealClock{ .io = io };
    const rep = recovery.recoverAllAtStartupGated(false, io, gpa, dir, "runs.json", clock, clock.nowMs() + BUDGET_MS, act(&pins, HELD_CLEAN));
    try std.testing.expectEqual(recovery.StartupStatus.disabled, rep.status);
    try std.testing.expect(!rep.load_failed); // gate off NEVER loads, so a bad store does not even surface load_failed
    try std.testing.expectEqual(@as(usize, 0), rep.scanned);
    try std.testing.expectEqual(@as(usize, 0), rep.signalled);
    try std.testing.expectEqual(@as(usize, 0), pins); // actuator never reached
}

test "#2 gate OFF + MISSING store: disabled, no read, zero pin/mutation" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    try expectGateOffNoRead(io, gpa, td.dir); // no runs.json seeded
    try std.testing.expect(!fileExists(io, td.dir, "runs.json")); // nothing was written
}

test "#2 gate OFF + CORRUPT store: disabled, no read, store left untouched" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    try td.dir.writeFile(io, .{ .sub_path = "runs.json", .data = "not valid ledger json {{{" });
    try expectGateOffNoRead(io, gpa, td.dir);
}

test "#2 gate OFF + UNREADABLE store (a directory at the path): disabled, no read" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    if (linux.errno(linux.mkdirat(td.dir.handle, "runs.json", 0o700)) != .SUCCESS) return error.Mkdir; // a dir where the file should be
    try expectGateOffNoRead(io, gpa, td.dir);
}

fn fileExists(io: std.Io, dir: std.Io.Dir, sub: []const u8) bool {
    dir.access(io, sub, .{}) catch return false;
    return true;
}

// ================================================================================================================
// RoseCat 33a9bf2 #4: drive every outcome; a fail-closed entry makes the report non-ok and is never hidden.
// ================================================================================================================

test "#4 signalled: gate TRUE, a dead entry is recovered exactly once and retired (ok)" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const clock = ledger.RealClock{ .io = io };
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    try seedActive(io, td.dir, DEAD_PID, 234567);
    var pins: usize = 0;
    const rep = recovery.recoverAllAtStartupGated(true, io, gpa, td.dir, "runs.json", clock, clock.nowMs() + BUDGET_MS, act(&pins, HELD_CLEAN));
    try std.testing.expectEqual(recovery.StartupStatus.ran, rep.status);
    try std.testing.expectEqual(@as(usize, 1), rep.signalled);
    try std.testing.expectEqual(@as(usize, 1), pins);
    try std.testing.expect(rep.ok());
    try std.testing.expectEqual(@as(usize, 0), try entryCount(io, gpa, td.dir));
}

test "#4 left: a LIVE same-owner entry (this process) is left untouched and retained" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const clock = ledger.RealClock{ .io = io };
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    const self = linux.getpid();
    const ticks = ledger.readStartTicks(self) orelse return error.NoStartTicks;
    try ledger.publish(io, td.dir, "runs.json", &[_]ledger.Entry{entryOf(BASENAME, self, ticks, .active, 2)});
    var pins: usize = 0;
    const rep = recovery.recoverAllAtStartupGated(true, io, gpa, td.dir, "runs.json", clock, clock.nowMs() + BUDGET_MS, act(&pins, HELD_CLEAN));
    try std.testing.expectEqual(@as(usize, 1), rep.left);
    try std.testing.expectEqual(@as(usize, 0), rep.signalled);
    try std.testing.expect(rep.ok());
    try std.testing.expectEqual(@as(usize, 1), try entryCount(io, gpa, td.dir)); // live -> retained
}

test "#4 reconciled: a dead entry whose dir is GONE (C3) is dropped idempotently, signal-free" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const clock = ledger.RealClock{ .io = io };
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    try seedActive(io, td.dir, DEAD_PID, 234567);
    var pins: usize = 0;
    const rep = recovery.recoverAllAtStartupGated(true, io, gpa, td.dir, "runs.json", clock, clock.nowMs() + BUDGET_MS, act(&pins, .gone));
    try std.testing.expectEqual(@as(usize, 1), rep.reconciled);
    try std.testing.expect(rep.ok());
    try std.testing.expectEqual(@as(usize, 0), try entryCount(io, gpa, td.dir)); // dropped
}

var g_hook_io: std.Io = undefined;
var g_hook_dir: std.Io.Dir = undefined;
fn retireAllHook() void {
    // a CONCURRENT recoverer retired the snapshot's entry under the flock, in the window before our per-entry
    // acquisition -> our recoverOneUnderLock reloads and finds it gone.
    ledger.publish(g_hook_io, g_hook_dir, "runs.json", &[_]ledger.Entry{}) catch {};
}

test "#4 already_gone: an entry retired concurrently (after our snapshot) is tallied, not acted on" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const clock = ledger.RealClock{ .io = io };
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    try seedActive(io, td.dir, DEAD_PID, 234567);
    g_hook_io = io;
    g_hook_dir = td.dir;
    var pins: usize = 0;
    const rep = recovery.recoverAllAtStartupGatedH(true, io, gpa, td.dir, "runs.json", clock, clock.nowMs() + BUDGET_MS, act(&pins, HELD_CLEAN), &retireAllHook);
    try std.testing.expectEqual(@as(usize, 1), rep.scanned);
    try std.testing.expectEqual(@as(usize, 0), rep.signalled);
    try std.testing.expectEqual(@as(usize, 1), rep.already_gone);
    try std.testing.expectEqual(@as(usize, 0), pins); // already-gone returns before the actuator
    try std.testing.expect(rep.ok());
    try std.testing.expectEqual(@as(usize, 0), try entryCount(io, gpa, td.dir));
}

test "#4 fail_closed: a mismatch entry keeps the entry and makes the report NON-ok" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const clock = ledger.RealClock{ .io = io };
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    try seedActive(io, td.dir, DEAD_PID, 234567);
    var pins: usize = 0;
    const rep = recovery.recoverAllAtStartupGated(true, io, gpa, td.dir, "runs.json", clock, clock.nowMs() + BUDGET_MS, act(&pins, .mismatch));
    try std.testing.expectEqual(recovery.StartupStatus.ran, rep.status);
    try std.testing.expectEqual(@as(usize, 1), rep.fail_closed);
    try std.testing.expect(!rep.ok()); // a fail-closed entry is NEVER hidden by the `ran` status
    try std.testing.expectEqual(@as(usize, 1), try entryCount(io, gpa, td.dir)); // entry RETAINED
}

test "#4 a fail_closed entry alongside a signalled one still makes the aggregate NON-ok, keeps the failed entry" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const clock = ledger.RealClock{ .io = io };
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    const bn_ok = basenameN(0);
    const bn_fail = basenameN(1);
    try ledger.publish(io, td.dir, "runs.json", &[_]ledger.Entry{
        entryOf(bn_ok, DEAD_PID, 234567, .active, 2),
        entryOf(bn_fail, DEAD_PID, 234567, .active, 3),
    });
    var pins: usize = 0;
    const rep = recovery.recoverAllAtStartupGated(true, io, gpa, td.dir, "runs.json", clock, clock.nowMs() + BUDGET_MS, RoutingActuator{ .pins = &pins, .fail_bn = bn_fail });
    try std.testing.expectEqual(@as(usize, 1), rep.signalled);
    try std.testing.expectEqual(@as(usize, 1), rep.fail_closed);
    try std.testing.expect(!rep.ok()); // not hidden by the one success
    try std.testing.expectEqual(@as(usize, 1), try entryCount(io, gpa, td.dir)); // only the fail_closed entry remains
}

// ================================================================================================================
// RoseCat 33a9bf2 #5: per-start entry cap + one absolute deadline across the whole iteration; residuals retained.
// ================================================================================================================

test "#5 the per-start cap defers the overflow entries (retained + reported), processes exactly the cap" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const clock = ledger.RealClock{ .io = io };
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    const cap = recovery.MAX_RECOVER_PER_START;
    try seedActiveN(io, td.dir, cap + 2);
    var pins: usize = 0;
    const rep = recovery.recoverAllAtStartupGated(true, io, gpa, td.dir, "runs.json", clock, clock.nowMs() + BUDGET_MS, act(&pins, HELD_CLEAN));
    try std.testing.expectEqual(cap, rep.scanned);
    try std.testing.expectEqual(cap, rep.signalled);
    try std.testing.expectEqual(@as(usize, 2), rep.deferred); // the overflow entries
    try std.testing.expectEqual(@as(usize, 2), try entryCount(io, gpa, td.dir)); // residual RETAINED
}

test "#5 an already-expired absolute deadline defers every active entry, retains all, acts on none" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const clock = ledger.RealClock{ .io = io };
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    try seedActiveN(io, td.dir, 3);
    var pins: usize = 0;
    const rep = recovery.recoverAllAtStartupGated(true, io, gpa, td.dir, "runs.json", clock, clock.nowMs() - 1, act(&pins, HELD_CLEAN));
    try std.testing.expectEqual(recovery.StartupStatus.ran, rep.status);
    try std.testing.expectEqual(@as(usize, 0), rep.scanned);
    try std.testing.expectEqual(@as(usize, 3), rep.deferred);
    try std.testing.expectEqual(@as(usize, 0), pins); // nothing acted on past the deadline
    try std.testing.expectEqual(@as(usize, 3), try entryCount(io, gpa, td.dir)); // all RETAINED
}

// ================================================================================================================
// The two-factor seed rows (gate off vs on; production default).
// ================================================================================================================

test "gate FALSE: a recoverable dead entry is NEVER touched (disabled, zero signal, zero pin, retained)" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const clock = ledger.RealClock{ .io = io };
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    try seedActive(io, td.dir, DEAD_PID, 234567);
    var pins: usize = 0;
    const rep = recovery.recoverAllAtStartupGated(false, io, gpa, td.dir, "runs.json", clock, clock.nowMs() + BUDGET_MS, act(&pins, HELD_CLEAN));
    try std.testing.expectEqual(recovery.StartupStatus.disabled, rep.status);
    try std.testing.expectEqual(@as(usize, 0), rep.signalled);
    try std.testing.expectEqual(@as(usize, 0), pins);
    try std.testing.expectEqual(@as(usize, 1), try entryCount(io, gpa, td.dir));
}

test "production default: recoverAllAtStartup reads reaper_ready=false -> disabled, zero signal, zero pin" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const clock = ledger.RealClock{ .io = io };
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    try seedActive(io, td.dir, DEAD_PID, 234567);
    var pins: usize = 0;
    const rep = recovery.recoverAllAtStartup(io, gpa, td.dir, "runs.json", clock, clock.nowMs() + BUDGET_MS, act(&pins, HELD_CLEAN));
    try std.testing.expectEqual(recovery.StartupStatus.disabled, rep.status);
    try std.testing.expectEqual(@as(usize, 0), pins);
}
