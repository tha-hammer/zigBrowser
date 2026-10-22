//! MS6.5.1 — RED-FIRST for the `reaper_ready` arming gate + the startup-recovery CORE (bd zigBrowser-3gl; follow-on
//! to the APPROVED Darwin actuator d375eb2 / 03a7436; strengthened per RoseCat 33a9bf2 then 3a71253). UNREGISTERED
//! (built by no gate step), UNARMED, signal-free fakes only, off the Macs. RED by compile error on the not-yet-
//! existing production symbols: `reaper_ready`, `MAX_RECOVER_PER_START`, `StartupStatus`, `StartupReport`,
//! `RealLoader`, `recoverAllAtStartup`, `recoverAllAtStartupGated`, `recoverAllAtStartupGatedH`,
//! `recoverAllAtStartupFull`.
//!
//! SCOPE (RoseCat 33a9bf2 #1): this slice is the startup-recovery CORE. Wiring a real app-startup OWNER that calls
//! `recoverAllAtStartup` is an OPEN integration blocker, retained separately — deliberately NOT in this slice.
//!
//! TWO-FACTOR SAFETY: a production signal is possible ONLY when BOTH the immutable gate `reaper_ready` is true AND
//! the caller runs the per-entry whole-recovery transaction. `.signalled` is the ACTION LABEL the signal-free fake
//! lease returns on the recover path, not a real kill, so these rows need no fork and no PID-namespace sentinel.
const std = @import("std");
const linux = std.os.linux;
const ledger = @import("agent_run_ledger");
const recovery = @import("agent_run_recovery");

const BASENAME = "zigbrowser-agent-2147483645-00bb00bb00bb00bb"; // its pid is DEAD_PID, as a ledger entry requires
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

/// Routes per entry: `fail_bn` pins `.mismatch` (-> fail_closed); every other `.held`/clean/done (-> signalled).
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

/// Counts every store load, so a row can prove gate-off performs ZERO reads (RoseCat 3a71253 #1).
const CountingLoader = struct {
    loads: *usize,
    pub fn load(self: CountingLoader, io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir, sub_path: []const u8) ledger.ParseError!ledger.Ledger {
        self.loads.* += 1;
        return ledger.load(io, gpa, dir, sub_path);
    }
};

/// A deterministic clock: `before` for the first `cross_at` calls, then `after`. With `cross_at` = one entry's
/// clock-call count (measured: 5 for the signalled path = 1 loop pre-check + 4 recover boundaries), entry one
/// completes under the bound and the SAME deadline has expired by entry two's pre-check (RoseCat 3a71253 #4).
const StepClock = struct {
    n: *usize,
    cross_at: usize,
    before: i64,
    after: i64,
    pub fn nowMs(self: StepClock) i64 {
        const i = self.n.*;
        self.n.* += 1;
        return if (i < self.cross_at) self.before else self.after;
    }
    pub fn sleepMs(_: StepClock, _: i64) void {}
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
fn fileExists(io: std.Io, dir: std.Io.Dir, sub: []const u8) bool {
    dir.access(io, sub, .{}) catch return false;
    return true;
}
fn isDir(io: std.Io, dir: std.Io.Dir, sub: []const u8) bool {
    var d = dir.openDir(io, sub, .{}) catch return false;
    d.close(io);
    return true;
}
const CORRUPT = "this is not valid ledger json {{{"; // the exact corrupt bytes we snapshot and require unchanged
fn expectBytes(io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir, sub: []const u8, want: []const u8) !void {
    const got = try dir.readFileAlloc(io, sub, gpa, .limited(1 << 20));
    defer gpa.free(got);
    try std.testing.expectEqualStrings(want, got); // byte-for-byte equality: the store was NOT mutated
}
var g_bn_bufs: [128][64]u8 = undefined;
fn basenameN(i: usize) []const u8 {
    return std.fmt.bufPrint(&g_bn_bufs[i], "zigbrowser-agent-2147483645-{x:0>16}", .{i}) catch unreachable;
}
fn seedActiveN(io: std.Io, dir: std.Io.Dir, n: usize) !void {
    var ents: [128]ledger.Entry = undefined;
    for (0..n) |i| ents[i] = entryOf(basenameN(i), DEAD_PID, 234567, .active, 2 + i);
    try ledger.publish(io, dir, "runs.json", ents[0..n]);
}

// ================================================================================================================
// RoseCat 3a71253 #1: gate OFF performs NO store read (injected loader counter == 0), on every store shape.
// ================================================================================================================

fn expectGateOffNoRead(io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir) !void {
    var pins: usize = 0;
    var loads: usize = 0;
    const clock = ledger.RealClock{ .io = io };
    const rep = recovery.recoverAllAtStartupFull(false, io, gpa, dir, "runs.json", clock, clock.nowMs() + BUDGET_MS, act(&pins, HELD_CLEAN), CountingLoader{ .loads = &loads }, null);
    try std.testing.expectEqual(recovery.StartupStatus.disabled, rep.status);
    try std.testing.expectEqual(@as(usize, 0), loads); // the store was NEVER read (move-load-before-gate mutant catches this)
    try std.testing.expect(!rep.load_failed);
    try std.testing.expectEqual(@as(usize, 0), rep.scanned);
    try std.testing.expectEqual(@as(usize, 0), pins);
}

test "#1 gate OFF + MISSING store: no read (loads==0), disabled, no mutation" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    try expectGateOffNoRead(io, gpa, td.dir);
    try std.testing.expect(!fileExists(io, td.dir, "runs.json"));
}

test "#1 gate OFF + CORRUPT store: no read (loads==0), disabled, bytes byte-for-byte unchanged" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    try td.dir.writeFile(io, .{ .sub_path = "runs.json", .data = CORRUPT });
    try expectGateOffNoRead(io, gpa, td.dir);
    try expectBytes(io, gpa, td.dir, "runs.json", CORRUPT); // the exact corrupt bytes survive the gate-off call
}

test "#1 gate OFF + UNREADABLE store (a directory at the path): no read (loads==0), disabled, shape kept" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    if (linux.errno(linux.mkdirat(td.dir.handle, "runs.json", 0o700)) != .SUCCESS) return error.Mkdir;
    try expectGateOffNoRead(io, gpa, td.dir);
    try std.testing.expect(isDir(io, td.dir, "runs.json")); // still a directory: not replaced/removed
}

// ================================================================================================================
// RoseCat 3a71253 #2: readiness is bound SOLELY to reaper_ready; no getenv/argv/env_switch/build-option arming.
// ================================================================================================================

test "#2 reaper_ready is the literal immutable false constant; readiness has NO env/argv/env_switch/build source" {
    comptime { // a runtime (env/argv) source would make this non-comptime and fail as a comptime branch
        if (recovery.reaper_ready != false) @compileError("reaper_ready must ship false");
    }
    const gpa = std.testing.allocator;
    const src = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/agent_run_recovery.zig", gpa, .limited(1 << 20));
    defer gpa.free(src);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub const reaper_ready: bool = false;") != null); // literal
    // The wrapper's readiness is `reaper_ready` and nothing else: it delegates that constant (RoseCat 6b324c8 #1).
    // A mutant hard-coding literal false (`recoverAllAtStartupFull(false,`) or any other readiness removes this.
    try std.testing.expect(std.mem.indexOf(u8, src, "recoverAllAtStartupFull(reaper_ready,") != null);
    // readiness is not derived from any of these arming sources anywhere in the module:
    for ([_][]const u8{ "build_options", "env_switch", "getenv", "getEnvVarOwned", "std.os.argv", "std.process" }) |banned| {
        try std.testing.expect(std.mem.indexOf(u8, src, banned) == null);
    }
}

test "#2 no env name arms the wrapper (several set): still disabled, zero pin" {
    for ([_][*:0]const u8{ "ZB_REAPER_READY", "REAPER_READY", "ZB_REAPER", "ZB_ARM_REAPER", "REAPER" }) |name| _ = setenv(name, "1", 1);
    defer for ([_][*:0]const u8{ "ZB_REAPER_READY", "REAPER_READY", "ZB_REAPER", "ZB_ARM_REAPER", "REAPER" }) |name| {
        _ = unsetenv(name);
    };
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
// RoseCat 3a71253 #3: the cap is a positive bounded LITERAL contract (not derived from the constant).
// ================================================================================================================

test "#3 MAX_RECOVER_PER_START is a positive bounded literal; the plan selects 64" {
    try std.testing.expect(recovery.MAX_RECOVER_PER_START > 0); // a zero cap would recover nothing
    try std.testing.expectEqual(@as(usize, 64), recovery.MAX_RECOVER_PER_START);
}

test "#3/#5 the cap processes exactly 64 and defers the remaining 2 (retained)" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const clock = ledger.RealClock{ .io = io };
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    try seedActiveN(io, td.dir, 66); // 64 + 2, LITERAL, not derived from the constant
    var pins: usize = 0;
    const rep = recovery.recoverAllAtStartupGated(true, io, gpa, td.dir, "runs.json", clock, clock.nowMs() + BUDGET_MS, act(&pins, HELD_CLEAN));
    try std.testing.expectEqual(@as(usize, 64), rep.scanned); // a zero-cap mutant recovers 0 -> fails here
    try std.testing.expectEqual(@as(usize, 64), rep.signalled);
    try std.testing.expectEqual(@as(usize, 2), rep.deferred);
    try std.testing.expectEqual(@as(usize, 2), try entryCount(io, gpa, td.dir)); // the 2 residual RETAINED
}

// ================================================================================================================
// RoseCat 3a71253 #4: one ABSOLUTE deadline across the iteration (deterministic clock); not a per-entry reset.
// ================================================================================================================

test "#4 entry one completes before the bound; the SAME deadline expires before entry two -> deferred + retained" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    const bn0 = basenameN(0);
    const bn1 = basenameN(1);
    try ledger.publish(io, td.dir, "runs.json", &[_]ledger.Entry{
        entryOf(bn0, DEAD_PID, 234567, .active, 2),
        entryOf(bn1, DEAD_PID, 234567, .active, 3),
    });
    var n: usize = 0;
    var pins: usize = 0;
    // before=0 (< deadline) for entry one's 5 clock calls, after=2000 (>= deadline 1000) from entry two's pre-check.
    const clock = StepClock{ .n = &n, .cross_at = 5, .before = 0, .after = 2000 };
    const rep = recovery.recoverAllAtStartupGated(true, io, gpa, td.dir, "runs.json", clock, 1000, act(&pins, HELD_CLEAN));
    try std.testing.expectEqual(@as(usize, 1), rep.scanned); // entry one only
    try std.testing.expectEqual(@as(usize, 1), rep.signalled); // entry one completed before the bound
    try std.testing.expectEqual(@as(usize, 1), rep.deferred); // entry two deferred by the SAME absolute deadline
    try std.testing.expectEqual(@as(usize, 1), pins); // the deferred entry was never acted on
    try std.testing.expectEqual(@as(usize, 1), try entryCount(io, gpa, td.dir)); // entry two RETAINED (bn1 remains)
}

// ================================================================================================================
// RoseCat 3a71253 #5: gate-true corrupt-ledger; zero actuator pins for the live-owner `left` row.
// ================================================================================================================

test "#5 gate TRUE + corrupt ledger: load_failed, non-ok, zero action, no mutation" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const clock = ledger.RealClock{ .io = io };
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    try td.dir.writeFile(io, .{ .sub_path = "runs.json", .data = CORRUPT });
    var pins: usize = 0;
    const rep = recovery.recoverAllAtStartupGated(true, io, gpa, td.dir, "runs.json", clock, clock.nowMs() + BUDGET_MS, act(&pins, HELD_CLEAN));
    try std.testing.expect(rep.load_failed);
    try std.testing.expect(!rep.ok());
    try std.testing.expectEqual(@as(usize, 0), rep.signalled);
    try std.testing.expectEqual(@as(usize, 0), pins); // zero action
    try expectBytes(io, gpa, td.dir, "runs.json", CORRUPT); // gate-true + corrupt: store NOT mutated either
}

// ================================================================================================================
// Outcome matrix: signalled / left / already_gone / reconciled / fail_closed, with fail_closed never hidden.
// ================================================================================================================

test "signalled: gate TRUE, a dead entry is recovered exactly once and retired (ok)" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const clock = ledger.RealClock{ .io = io };
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    try seedActive(io, td.dir, DEAD_PID, 234567);
    var pins: usize = 0;
    const rep = recovery.recoverAllAtStartupGated(true, io, gpa, td.dir, "runs.json", clock, clock.nowMs() + BUDGET_MS, act(&pins, HELD_CLEAN));
    try std.testing.expectEqual(@as(usize, 1), rep.signalled);
    try std.testing.expectEqual(@as(usize, 1), pins);
    try std.testing.expect(rep.ok());
    try std.testing.expectEqual(@as(usize, 0), try entryCount(io, gpa, td.dir));
}

test "left: a LIVE same-owner entry (this process) is left untouched, RETAINED, with ZERO actuator pins" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const clock = ledger.RealClock{ .io = io };
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    const self = linux.getpid();
    const ticks = ledger.readStartTicks(self) orelse return error.NoStartTicks;
    var bn_buf: [64]u8 = undefined;
    const bn = try std.fmt.bufPrint(&bn_buf, "zigbrowser-agent-{d}-00bb00bb00bb00bb", .{self}); // the entry's own pid
    try ledger.publish(io, td.dir, "runs.json", &[_]ledger.Entry{entryOf(bn, self, ticks, .active, 2)});
    var pins: usize = 0;
    const rep = recovery.recoverAllAtStartupGated(true, io, gpa, td.dir, "runs.json", clock, clock.nowMs() + BUDGET_MS, act(&pins, HELD_CLEAN));
    try std.testing.expectEqual(@as(usize, 1), rep.left);
    try std.testing.expectEqual(@as(usize, 0), rep.signalled);
    try std.testing.expectEqual(@as(usize, 0), pins); // a live owner is decided BEFORE the actuator -> never pinned
    try std.testing.expect(rep.ok());
    try std.testing.expectEqual(@as(usize, 1), try entryCount(io, gpa, td.dir));
}

test "reconciled: a dead entry whose dir is GONE (C3) is dropped idempotently, signal-free" {
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
    try std.testing.expectEqual(@as(usize, 0), try entryCount(io, gpa, td.dir));
}

var g_hook_io: std.Io = undefined;
var g_hook_dir: std.Io.Dir = undefined;
fn retireAllHook() void {
    ledger.publish(g_hook_io, g_hook_dir, "runs.json", &[_]ledger.Entry{}) catch {};
}

test "already_gone: an entry retired concurrently (after our snapshot) is tallied, not acted on" {
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
    try std.testing.expectEqual(@as(usize, 0), pins);
    try std.testing.expect(rep.ok());
    try std.testing.expectEqual(@as(usize, 0), try entryCount(io, gpa, td.dir));
}

test "fail_closed: a mismatch entry keeps the entry and makes the report NON-ok" {
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
    try std.testing.expect(!rep.ok()); // never hidden by the `ran` status
    try std.testing.expectEqual(@as(usize, 1), try entryCount(io, gpa, td.dir)); // RETAINED
}

test "a fail_closed entry alongside a signalled one still makes the aggregate NON-ok, keeps the failed entry" {
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
    try std.testing.expect(!rep.ok());
    try std.testing.expectEqual(@as(usize, 1), try entryCount(io, gpa, td.dir)); // only the fail_closed entry remains
}

// ================================================================================================================
// The two-factor seed rows.
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
