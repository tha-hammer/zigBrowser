//! MS6.5.1 — RED-FIRST for the OPEN integration blocker (bd zigBrowser-3gl). Per RoseCat a1ba7b1, the proof is now
//! driven through a PRODUCTION SEAM behaviorally (source inference kept leaking), with source used only as a thin
//! call-site binding. UNREGISTERED, signal-free, no display, no Macs; `reaper_ready` false. RED now: the owner
//! module `agent_startup_recovery` does not exist (compile error) and app.zig has no call.
//!
//!   - ORDERING (behavioral): `runStartupThenDispatch` runs the startup hook exactly once, strictly before dispatch
//!     (skip / after / twice mutants are runtime-observable — no brace/depth source heuristic).
//!   - SEAM (behavioral): gate-false touches nothing; gate-true runs each op once, closes once, samples the clock
//!     ONCE over DISTINCT values, and hands recover the deadline (one sampled now + budget) and the SAME clock.
//!   - REALOPS (behavioral): ledgerName() == "runs.json"; buildActuator() is the reviewed ConcreteActuator type.
//!   - SOURCE (thin): recover() reaches recoverAllAtStartup; app.runWithIo routes through the combinator + hook.
const std = @import("std");
const recovery = @import("agent_run_recovery");
const startup = @import("agent_startup_recovery");

// ---- ORDERING: the runWithIo-level combinator runs the hook once, strictly before dispatch --------------------

const Log = struct { hook: usize = 0, disp: usize = 0, hook_before_disp: bool = false };
const SpyHook = struct {
    log: *Log,
    pub fn run(self: SpyHook) void {
        if (self.log.disp == 0) self.log.hook_before_disp = true;
        self.log.hook += 1;
    }
};
const SpyDisp = struct {
    log: *Log,
    pub fn run(self: SpyDisp) u8 {
        self.log.disp += 1;
        return 0;
    }
};

test "ordering: the hook runs exactly once, strictly before dispatch" {
    var log = Log{};
    const rc = startup.runStartupThenDispatch(SpyHook{ .log = &log }, SpyDisp{ .log = &log });
    try std.testing.expectEqual(@as(u8, 0), rc);
    try std.testing.expectEqual(@as(usize, 1), log.hook); // exactly once (skip -> 0, twice -> 2)
    try std.testing.expectEqual(@as(usize, 1), log.disp);
    try std.testing.expect(log.hook_before_disp); // hook ran while disp count was 0 (after-dispatch mutant -> false)
}

// ---- SEAM: the gated owner, driven with counted spy ops + a distinct-valued, identity-tagged clock -------------

const CLOCK_TOKEN: u32 = 0xC10C;
const Caps = struct {
    env: usize = 0,
    open: usize = 0,
    build: usize = 0,
    recover: usize = 0,
    close: usize = 0,
    now: usize = 0,
    now_seq: [3]i64 = .{ 777, 888, 999 }, // DISTINCT values: a literal/second sample differs from the first
    captured_deadline: i64 = -1,
    captured_token: u32 = 0,
};
const SpyActuator = struct {};
const CountedClock = struct {
    caps: *Caps,
    token: u32,
    pub fn nowMs(self: CountedClock) i64 {
        const v = self.caps.now_seq[@min(self.caps.now, self.caps.now_seq.len - 1)];
        self.caps.now += 1;
        return v;
    }
    pub fn sleepMs(_: CountedClock, _: i64) void {}
};
const SpyOps = struct {
    caps: *Caps,
    result: recovery.StartupReport,
    pub fn runtimeDir(self: SpyOps) ?[]const u8 {
        self.caps.env += 1;
        return "/nonexistent-zb-runtime";
    }
    pub fn openDir(self: SpyOps, io: std.Io, path: []const u8) !std.Io.Dir {
        _ = io;
        _ = path;
        self.caps.open += 1;
        return std.Io.Dir.cwd();
    }
    pub fn closeDir(self: SpyOps, io: std.Io, dir: *std.Io.Dir) void {
        _ = io;
        _ = dir;
        self.caps.close += 1;
    }
    pub fn clock(self: SpyOps, io: std.Io) CountedClock {
        _ = io;
        return .{ .caps = self.caps, .token = CLOCK_TOKEN };
    }
    pub fn ledgerName(_: SpyOps) []const u8 {
        return "runs.json";
    }
    pub fn buildActuator(self: SpyOps) SpyActuator {
        self.caps.build += 1;
        return .{};
    }
    pub fn recover(self: SpyOps, io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir, sub: []const u8, clk: anytype, deadline_ms: i64, actuator: anytype) recovery.StartupReport {
        _ = io;
        _ = gpa;
        _ = dir;
        _ = sub;
        _ = actuator;
        self.caps.recover += 1;
        self.caps.captured_deadline = deadline_ms;
        self.caps.captured_token = clk.token; // the clock IDENTITY handed to recover
        return self.result;
    }
};

test "gate FALSE: zero ops — no env, open, clock, actuator, recover, or close" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var caps = Caps{};
    const rep = startup.recoverLeftoverAgentRunsWith(false, io, gpa, SpyOps{ .caps = &caps, .result = .{ .status = .ran } });
    try std.testing.expectEqual(recovery.StartupStatus.disabled, rep.status);
    inline for (.{ caps.env, caps.open, caps.build, caps.recover, caps.close, caps.now }) |c| {
        try std.testing.expectEqual(@as(usize, 0), c);
    }
}

test "gate TRUE: each op once; one close; clock sampled ONCE; deadline = first sampled now + budget; same clock to recover" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var caps = Caps{};
    const rep = startup.recoverLeftoverAgentRunsWith(true, io, gpa, SpyOps{ .caps = &caps, .result = .{ .status = .ran } });
    try std.testing.expectEqual(recovery.StartupStatus.ran, rep.status);
    try std.testing.expectEqual(@as(usize, 1), caps.env);
    try std.testing.expectEqual(@as(usize, 1), caps.open);
    try std.testing.expectEqual(@as(usize, 1), caps.build);
    try std.testing.expectEqual(@as(usize, 1), caps.recover);
    try std.testing.expectEqual(@as(usize, 1), caps.close);
    try std.testing.expectEqual(@as(usize, 1), caps.now); // sampled exactly once over distinct values
    try std.testing.expectEqual(@as(i64, 777) + startup.STARTUP_BUDGET_MS, caps.captured_deadline); // first sample + budget
    try std.testing.expectEqual(CLOCK_TOKEN, caps.captured_token); // the owner handed recover the clock it sampled
}

test "a non-ok report is PROPAGATED, never swallowed; dir still closed once" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var caps = Caps{};
    const rep = startup.recoverLeftoverAgentRunsWith(true, io, gpa, SpyOps{ .caps = &caps, .result = .{ .status = .ran, .fail_closed = 1 } });
    try std.testing.expect(!rep.ok());
    try std.testing.expectEqual(@as(usize, 1), rep.fail_closed);
    try std.testing.expectEqual(@as(usize, 1), caps.close);
}

// ---- REALOPS: the production ops are exercised (not dead): the ledger name and the reviewed actuator type -------

test "RealOps is live: ledgerName is the app-owned runs.json; buildActuator is the reviewed Darwin actuator" {
    const ro = startup.RealOps{};
    try std.testing.expectEqualStrings("runs.json", ro.ledgerName());
    try std.testing.expect(@TypeOf(ro.buildActuator()) == recovery.ConcreteActuator(recovery.DarwinWiring));
}

// ---- SOURCE (thin): recover() reaches the core; app.runWithIo routes through the combinator + hook --------------

fn stripZig(gpa: std.mem.Allocator, src: []const u8) ![]u8 {
    var out = try gpa.alloc(u8, src.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < src.len) {
        if (src[i] == '/' and i + 1 < src.len and src[i + 1] == '/') {
            while (i < src.len and src[i] != '\n') i += 1;
            continue;
        }
        if (src[i] == '\\' and i + 1 < src.len and src[i + 1] == '\\') {
            while (i < src.len and src[i] != '\n') i += 1;
            continue;
        }
        if (src[i] == '/' and i + 1 < src.len and src[i + 1] == '*') {
            i += 2;
            while (i + 1 < src.len and !(src[i] == '*' and src[i + 1] == '/')) i += 1;
            i += 2;
            continue;
        }
        if (src[i] == '"') {
            i += 1;
            while (i < src.len and src[i] != '"') {
                if (src[i] == '\\') i += 1;
                i += 1;
            }
            i += 1;
            continue;
        }
        out[n] = src[i];
        n += 1;
        i += 1;
    }
    return gpa.realloc(out, n);
}
fn methodBody(src: []const u8, decl: []const u8) []const u8 {
    const at = std.mem.indexOf(u8, src, decl) orelse return "";
    var i = at + decl.len;
    while (i < src.len and src[i] != '{') i += 1;
    if (i >= src.len) return "";
    const start = i;
    var depth: usize = 0;
    while (i < src.len) : (i += 1) {
        if (src[i] == '{') depth += 1;
        if (src[i] == '}') {
            depth -= 1;
            if (depth == 0) return src[start .. i + 1];
        }
    }
    return "";
}
fn readSrc(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, .limited(1 << 20));
}

test "source(thin): RealOps.recover reaches recoverAllAtStartup (scoped to the recover method body)" {
    const gpa = std.testing.allocator;
    const raw = try readSrc(gpa, "src/agent_startup_recovery.zig");
    defer gpa.free(raw);
    const src = try stripZig(gpa, raw);
    defer gpa.free(src);
    const recover_body = methodBody(src, "pub fn recover("); // the recover METHOD body, stripped (not the struct)
    try std.testing.expect(recover_body.len != 0);
    try std.testing.expect(std.mem.indexOf(u8, recover_body, "recovery.recoverAllAtStartup(") != null);
}

test "source(thin): app.runWithIo routes startup through the combinator + the recovery hook" {
    const gpa = std.testing.allocator;
    const raw = try readSrc(gpa, "src/app.zig");
    defer gpa.free(raw);
    const src = try stripZig(gpa, raw);
    defer gpa.free(src);
    try std.testing.expect(std.mem.indexOf(u8, raw, "@import(\"agent_startup_recovery\")") != null);
    const body = methodBody(src, "pub fn runWithIo(");
    try std.testing.expect(body.len != 0);
    try std.testing.expect(std.mem.indexOf(u8, body, "runStartupThenDispatch(") != null); // routed through the reviewed combinator
    try std.testing.expect(std.mem.indexOf(u8, body, "recoverLeftoverAgentRuns") != null); // whose hook wires the owner
}
