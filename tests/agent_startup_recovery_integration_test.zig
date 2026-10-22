//! MS6.5.1 — RED-FIRST for the OPEN integration blocker (bd zigBrowser-3gl), strengthened per RoseCat 1d7dbd7:
//! the real app-startup OWNER must call the startup-recovery core as an UNCONDITIONAL top-level statement, exactly
//! once, BEFORE command dispatch; while the gate is false it opens/samples/constructs NOTHING; it closes the dir
//! exactly once on any open path; it samples the clock once and the deadline is that now + the budget.
//! UNREGISTERED, signal-free, no display, no Macs; `reaper_ready` false. RED now: the owner module
//! `agent_startup_recovery` does not exist (compile error) and app.zig has no call.
const std = @import("std");
const recovery = @import("agent_run_recovery");
const startup = @import("agent_startup_recovery");

// ---- behavioral: the real owner seam, driven with counted spy ops ----------------------------------------------

const Caps = struct {
    env: usize = 0,
    open: usize = 0,
    build: usize = 0,
    recover: usize = 0,
    close: usize = 0,
    now: usize = 0,
    now_val: i64 = 1000,
    captured_deadline: i64 = -1,
};
const SpyActuator = struct {};
const CountedClock = struct {
    caps: *Caps,
    pub fn nowMs(self: CountedClock) i64 {
        self.caps.now += 1;
        return self.caps.now_val;
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
        return .{ .caps = self.caps };
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
        _ = clk;
        _ = actuator;
        self.caps.recover += 1;
        self.caps.captured_deadline = deadline_ms;
        return self.result;
    }
};

test "gate FALSE: zero ops — no env, no open, no clock sample, no actuator, no recover, no close" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var caps = Caps{};
    const rep = startup.recoverLeftoverAgentRunsWith(false, io, gpa, SpyOps{ .caps = &caps, .result = .{ .status = .ran } });
    try std.testing.expectEqual(recovery.StartupStatus.disabled, rep.status);
    inline for (.{ caps.env, caps.open, caps.build, caps.recover, caps.close, caps.now }) |c| {
        try std.testing.expectEqual(@as(usize, 0), c);
    }
}

test "gate TRUE: env/open/build/recover each once; close once; clock sampled ONCE; deadline = now + budget" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var caps = Caps{ .now_val = 1000 };
    const rep = startup.recoverLeftoverAgentRunsWith(true, io, gpa, SpyOps{ .caps = &caps, .result = .{ .status = .ran } });
    try std.testing.expectEqual(recovery.StartupStatus.ran, rep.status);
    try std.testing.expectEqual(@as(usize, 1), caps.env);
    try std.testing.expectEqual(@as(usize, 1), caps.open);
    try std.testing.expectEqual(@as(usize, 1), caps.build);
    try std.testing.expectEqual(@as(usize, 1), caps.recover);
    try std.testing.expectEqual(@as(usize, 1), caps.close); // exactly one close after a successful open (no-close mutant -> 0)
    try std.testing.expectEqual(@as(usize, 1), caps.now); // clock sampled exactly once
    try std.testing.expectEqual(@as(i64, 1000) + startup.STARTUP_BUDGET_MS, caps.captured_deadline); // one now + budget
}

test "a non-ok report is PROPAGATED, never swallowed; the dir is still closed exactly once" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var caps = Caps{};
    const non_ok = recovery.StartupReport{ .status = .ran, .fail_closed = 1 };
    try std.testing.expect(!non_ok.ok());
    const rep = startup.recoverLeftoverAgentRunsWith(true, io, gpa, SpyOps{ .caps = &caps, .result = non_ok });
    try std.testing.expect(!rep.ok());
    try std.testing.expectEqual(@as(usize, 1), rep.fail_closed);
    try std.testing.expectEqual(@as(usize, 1), caps.close); // closed on the recovery path too
}

// ---- source helpers: strip comments + "..." strings + `\\` multiline strings; balanced bodies; brace depth ------

fn stripZig(gpa: std.mem.Allocator, src: []const u8) ![]u8 {
    var out = try gpa.alloc(u8, src.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < src.len) {
        if (src[i] == '/' and i + 1 < src.len and src[i + 1] == '/') {
            while (i < src.len and src[i] != '\n') i += 1;
            continue;
        }
        if (src[i] == '\\' and i + 1 < src.len and src[i + 1] == '\\') { // Zig `\\` multiline string line
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

/// The brace-balanced body of `decl` (a `fn`/`struct` prefix) in already-stripped `src`. Includes the outer braces.
fn balancedBody(src: []const u8, decl: []const u8) []const u8 {
    const at = std.mem.indexOf(u8, src, decl) orelse return "";
    var i = at + decl.len;
    while (i < src.len and src[i] != '{') i += 1;
    if (i >= src.len) return "";
    const body_start = i;
    var depth: usize = 0;
    while (i < src.len) : (i += 1) {
        if (src[i] == '{') depth += 1;
        if (src[i] == '}') {
            depth -= 1;
            if (depth == 0) return src[body_start .. i + 1];
        }
    }
    return "";
}

fn braceNet(s: []const u8, pos: usize) i64 {
    var d: i64 = 0;
    var i: usize = 0;
    while (i < pos) : (i += 1) {
        if (s[i] == '{') d += 1;
        if (s[i] == '}') d -= 1;
    }
    return d;
}

fn countOcc(hay: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, hay, i, needle)) |p| {
        n += 1;
        i = p + needle.len;
    }
    return n;
}

fn readSrc(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, .limited(1 << 20));
}

// ---- source link 1 (app.zig): the owner call is an UNCONDITIONAL top-level statement, once, before dispatch -----

test "link1: runWithIo calls the owner once, unconditionally at top level, before command dispatch" {
    const gpa = std.testing.allocator;
    const raw = try readSrc(gpa, "src/app.zig");
    defer gpa.free(raw);
    const src = try stripZig(gpa, raw);
    defer gpa.free(src);

    try std.testing.expect(std.mem.indexOf(u8, raw, "@import(\"agent_startup_recovery\")") != null);

    const body = balancedBody(src, "pub fn runWithIo(");
    try std.testing.expect(body.len != 0);

    // the dispatch marker MUST be present (so "before dispatch" is meaningful, not vacuous).
    const dispatch_at = std.mem.indexOf(u8, body, "switch (command)");
    try std.testing.expect(dispatch_at != null);

    const call = "agent_startup_recovery.recoverLeftoverAgentRuns(";
    try std.testing.expectEqual(@as(usize, 1), countOcc(body, call)); // exactly once (duplicate-call mutant -> 2)

    const call_at = std.mem.indexOf(u8, body, call).?;
    try std.testing.expect(call_at < dispatch_at.?); // before dispatch (branch-only / after-dispatch -> fail)
    try std.testing.expectEqual(@as(i64, 1), braceNet(body, call_at)); // UNCONDITIONAL top-level (if (false) {..} -> depth 2)
}

// ---- source link 2 (the owner module): RealOps body carries the ledger arg, actuator and core call --------------

test "link2: RealOps carries the ledger arg, the reviewed actuator and the core call; seam pins one deadline" {
    const gpa = std.testing.allocator;
    const raw = try readSrc(gpa, "src/agent_startup_recovery.zig");
    defer gpa.free(raw);
    const src = try stripZig(gpa, raw);
    defer gpa.free(src);

    // scope strictly to the RealOps struct body (a decoy string/comment outside it, or stripped away, does not count).
    const realops = balancedBody(src, "pub const RealOps = struct");
    try std.testing.expect(realops.len != 0);
    try std.testing.expect(std.mem.indexOf(u8, realops, "recovery.recoverAllAtStartup(") != null); // the core call
    try std.testing.expect(std.mem.indexOf(u8, realops, "ConcreteActuator(recovery.DarwinWiring)") != null); // actuator
    const realops_raw = balancedBody(raw, "pub const RealOps = struct");
    try std.testing.expect(std.mem.indexOf(u8, realops_raw, "\"runs.json\"") != null); // the app-owned ledger argument

    // seam pins ONE absolute deadline (one sampled now + the budget) and readiness bound to the gate.
    const seam = balancedBody(src, "pub fn recoverLeftoverAgentRunsWith(");
    try std.testing.expect(seam.len != 0);
    try std.testing.expectEqual(@as(usize, 1), countOcc(seam, "+ STARTUP_BUDGET_MS"));
    const prod = balancedBody(src, "pub fn recoverLeftoverAgentRuns(");
    try std.testing.expect(std.mem.indexOf(u8, prod, "recovery.reaper_ready") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "@import(\"agent_run_recovery\")") != null);
}
