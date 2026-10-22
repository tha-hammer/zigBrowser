//! MS6.5.1 — RED-FIRST for the `reaper_ready` arming gate + the startup call-site (bd zigBrowser-3gl follow-on to
//! the APPROVED Darwin actuator d375eb2 / 03a7436). This file is UNREGISTERED (built by no gate step) and references
//! production symbols that DO NOT EXIST yet, so it is RED by compile error until the green commit adds them to
//! `src/agent_run_recovery.zig`:
//!   - `recovery.reaper_ready`            (immutable gate, default FALSE)
//!   - `recovery.recoverAllAtStartup`     (production caller; reads the gate)
//!   - `recovery.recoverAllAtStartupGated`(gated core; gate passed explicitly for the causal proof)
//!   - `recovery.StartupStatus` / `recovery.StartupReport`
//!
//! NOT ARMED, NOT REGISTERED, no real-signal run, off the Macs. The fakes are the deterministic, signal-free lease
//! fakes from the production transaction test; `.signalled` is the ACTION LABEL the transaction returns on the
//! recover path, not a real kill, so these rows need no fork and no PID-namespace sentinel.
//!
//! TWO-FACTOR SAFETY (what the rows prove): a production signal is possible ONLY when BOTH the immutable gate
//! `reaper_ready` is true AND the startup caller runs the per-entry whole-recovery transaction. Removing EITHER
//! factor makes a signal impossible (the gate mutant and the caller mutant each turn a row red, verified offline).
const std = @import("std");
const ledger = @import("agent_run_ledger");
const recovery = @import("agent_run_recovery");

const BASENAME = "zigbrowser-agent-515151-00bb00bb00bb00bb";
const DEAD_PID: i32 = 2147483645; // absent + reuse-proof
const BUDGET_MS: i64 = 30000;

// ---- the deterministic, signal-free injected actuator (+ a pin counter to prove ZERO reachable action) ----------

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

/// Counts every `pin` call: the ONLY path to a census/kill goes through `pin`, so `pins == 0` proves no reachable
/// production action occurred (the gate kept us out before the actuator was ever touched).
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
fn okCounting(pins: *usize) CountingActuator {
    return .{ .pins = pins, .result = .{ .held = .{ .fp = .clean, .td = .done } } }; // recover -> .signalled label
}

fn seedActive(io: std.Io, dir: std.Io.Dir, pid: i32, start_sec: u64) !void {
    const seed = [_]ledger.Entry{.{ .basename = BASENAME, .dev = 1, .ino = 2, .uid = 0, .mode = 16832, .pid = pid, .start_kind = .linux_ticks, .start_sec = start_sec, .start_usec = 0, .state = .active }};
    try ledger.publish(io, dir, "runs.json", &seed);
}
fn entryCount(io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir) !usize {
    var l = try ledger.load(io, gpa, dir, "runs.json");
    defer l.deinit();
    return l.entries().len;
}

// ---- the two-factor causal proof: a signal needs BOTH the gate AND the caller --------------------------------

// FACTOR A — only the caller, gate FALSE: the caller runs but the gate must keep every action unreachable.
test "gate FALSE: a recoverable dead entry is NEVER touched (disabled, zero signal, zero pin, retained)" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const clock = ledger.RealClock{ .io = io };
    const terminal = clock.nowMs() + BUDGET_MS;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    try seedActive(io, td.dir, DEAD_PID, 234567);

    var pins: usize = 0;
    const rep = recovery.recoverAllAtStartupGated(false, io, gpa, td.dir, "runs.json", clock, terminal, okCounting(&pins));
    try std.testing.expectEqual(recovery.StartupStatus.disabled, rep.status);
    try std.testing.expectEqual(@as(usize, 0), rep.scanned); // never even loaded/scanned
    try std.testing.expectEqual(@as(usize, 0), rep.signalled);
    try std.testing.expectEqual(@as(usize, 0), pins); // the actuator was NEVER reached
    try std.testing.expectEqual(@as(usize, 1), try entryCount(io, gpa, td.dir)); // entry RETAINED, no mutation
}

// FACTOR B — only the gate, no caller action: with the gate TRUE the caller MUST run the transaction and signal.
test "gate TRUE: a recoverable dead entry is signalled exactly once and retired (ran)" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const clock = ledger.RealClock{ .io = io };
    const terminal = clock.nowMs() + BUDGET_MS;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    try seedActive(io, td.dir, DEAD_PID, 234567);

    var pins: usize = 0;
    const rep = recovery.recoverAllAtStartupGated(true, io, gpa, td.dir, "runs.json", clock, terminal, okCounting(&pins));
    try std.testing.expectEqual(recovery.StartupStatus.ran, rep.status);
    try std.testing.expectEqual(@as(usize, 1), rep.scanned);
    try std.testing.expectEqual(@as(usize, 1), rep.signalled);
    try std.testing.expectEqual(@as(usize, 1), pins);
    try std.testing.expect(rep.ok());
    try std.testing.expectEqual(@as(usize, 0), try entryCount(io, gpa, td.dir)); // retired under the flock
}

// The SHIPPED default: the sole production caller reads the immutable gate, which is FALSE, so nothing can signal.
test "production default: recoverAllAtStartup reads reaper_ready=false -> disabled, zero signal, zero pin" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const clock = ledger.RealClock{ .io = io };
    const terminal = clock.nowMs() + BUDGET_MS;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    try seedActive(io, td.dir, DEAD_PID, 234567);

    try std.testing.expectEqual(false, recovery.reaper_ready); // the immutable default must be false
    var pins: usize = 0;
    const rep = recovery.recoverAllAtStartup(io, gpa, td.dir, "runs.json", clock, terminal, okCounting(&pins));
    try std.testing.expectEqual(recovery.StartupStatus.disabled, rep.status);
    try std.testing.expectEqual(@as(usize, 0), rep.signalled);
    try std.testing.expectEqual(@as(usize, 0), pins);
}

// Failure reporting: with the gate TRUE, a corrupt ledger fails closed (reported) and signals nothing.
test "gate TRUE: a corrupt ledger fails closed (load_failed, not ok), signals nothing" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const clock = ledger.RealClock{ .io = io };
    const terminal = clock.nowMs() + BUDGET_MS;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    try td.dir.writeFile(io, .{ .sub_path = "runs.json", .data = "this is not valid ledger json {{{" });

    var pins: usize = 0;
    const rep = recovery.recoverAllAtStartupGated(true, io, gpa, td.dir, "runs.json", clock, terminal, okCounting(&pins));
    try std.testing.expect(rep.load_failed);
    try std.testing.expect(!rep.ok());
    try std.testing.expectEqual(@as(usize, 0), rep.signalled);
    try std.testing.expectEqual(@as(usize, 0), pins);
}
