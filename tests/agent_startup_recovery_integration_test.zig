//! MS6.5.1 — RED-FIRST for the OPEN integration blocker (bd zigBrowser-3gl). Per RoseCat a1ba7b1/bc224f7 the proof
//! drives a PRODUCTION SEAM behaviorally, source only as a comment-safe, scoped call-site binding. UNREGISTERED,
//! signal-free, no display, no Macs; `reaper_ready` false. RED now: the owner module `agent_startup_recovery` does
//! not exist (compile error) and app.zig has no call.
const std = @import("std");
const recovery = @import("agent_run_recovery");
const startup = @import("agent_startup_recovery");

// ---- ORDERING: the combinator runs the hook once, strictly before dispatch ------------------------------------

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
    try std.testing.expectEqual(@as(usize, 1), log.hook);
    try std.testing.expectEqual(@as(usize, 1), log.disp);
    try std.testing.expect(log.hook_before_disp);
}

// ---- SEAM: the gated owner, with counted ops + a clock whose CONSTRUCTION is counted and identity-tagged -------

const Caps = struct {
    env: usize = 0,
    open: usize = 0,
    build: usize = 0,
    recover: usize = 0,
    close: usize = 0,
    now: usize = 0,
    construct: usize = 0, // clock CONSTRUCTIONS (ops.clock calls)
    now_seq: [3]i64 = .{ 777, 888, 999 },
    captured_deadline: i64 = -1,
    captured_token: usize = 0, // the clock identity (construction ordinal) handed to recover
};
const SpyActuator = struct {};
const CountedClock = struct {
    caps: *Caps,
    token: usize, // a DISTINCT token per construction (the construction ordinal)
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
        self.caps.construct += 1; // count each construction; hand out a distinct token
        return .{ .caps = self.caps, .token = self.caps.construct };
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
        self.caps.captured_token = clk.token;
        return self.result;
    }
};

test "gate FALSE: zero ops — no env, open, clock construction, actuator, recover, close" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var caps = Caps{};
    const rep = startup.recoverLeftoverAgentRunsWith(false, io, gpa, SpyOps{ .caps = &caps, .result = .{ .status = .ran } });
    try std.testing.expectEqual(recovery.StartupStatus.disabled, rep.status);
    inline for (.{ caps.env, caps.open, caps.build, caps.recover, caps.close, caps.now, caps.construct }) |c| {
        try std.testing.expectEqual(@as(usize, 0), c);
    }
}

test "gate TRUE: each op once; one close; ONE clock construction; its FIRST identity at recover; deadline = first now + budget" {
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
    try std.testing.expectEqual(@as(usize, 1), caps.now); // sampled once
    try std.testing.expectEqual(@as(usize, 1), caps.construct); // exactly one clock constructed (two-clock mutant -> 2)
    try std.testing.expectEqual(@as(usize, 1), caps.captured_token); // recover got the FIRST clock's identity
    try std.testing.expectEqual(@as(i64, 777) + startup.STARTUP_BUDGET_MS, caps.captured_deadline);
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

test "RealOps is live: ledgerName is runs.json; buildActuator is the reviewed Darwin actuator" {
    const ro = startup.RealOps{};
    try std.testing.expectEqualStrings("runs.json", ro.ledgerName());
    try std.testing.expect(@TypeOf(ro.buildActuator()) == recovery.ConcreteActuator(recovery.DarwinWiring));
}

// ---- source lexers: strip-all (code-token checks) and strip-comments-only (import/string checks) ---------------

fn lex(gpa: std.mem.Allocator, src: []const u8, comptime keep_strings: bool) ![]u8 {
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
            if (keep_strings) {
                out[n] = src[i];
                n += 1;
                i += 1;
                while (i < src.len and src[i] != '"') {
                    out[n] = src[i];
                    n += 1;
                    if (src[i] == '\\' and i + 1 < src.len) {
                        i += 1;
                        out[n] = src[i];
                        n += 1;
                    }
                    i += 1;
                }
                if (i < src.len) {
                    out[n] = src[i];
                    n += 1;
                    i += 1;
                }
            } else {
                i += 1;
                while (i < src.len and src[i] != '"') {
                    if (src[i] == '\\') i += 1;
                    i += 1;
                }
                i += 1;
            }
            continue;
        }
        out[n] = src[i];
        n += 1;
        i += 1;
    }
    return gpa.realloc(out, n);
}

fn balancedBody(src: []const u8, decl: []const u8) []const u8 {
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

test "source(thin): RealOps.recover reaches recoverAllAtStartup — RealOps body, then its recover method, lexed" {
    const gpa = std.testing.allocator;
    const raw = try readSrc(gpa, "src/agent_startup_recovery.zig");
    defer gpa.free(raw);
    const code = try lex(gpa, raw, false);
    defer gpa.free(code);
    const realops = balancedBody(code, "pub const RealOps = struct"); // scope to RealOps first
    try std.testing.expect(realops.len != 0);
    const recover = balancedBody(realops, "pub fn recover("); // then its named recover method (in-module decoy ignored)
    try std.testing.expect(recover.len != 0);
    try std.testing.expect(std.mem.indexOf(u8, recover, "recovery.recoverAllAtStartup(") != null);
}

test "source(thin): StartupHook.run IS the owner; runWithIo routes through the combinator + StartupHook" {
    const gpa = std.testing.allocator;
    const owner = try readSrc(gpa, "src/agent_startup_recovery.zig");
    defer gpa.free(owner);
    const owner_code = try lex(gpa, owner, false);
    defer gpa.free(owner_code);
    const hook_run = balancedBody(balancedBody(owner_code, "pub const StartupHook = struct"), "pub fn run(");
    try std.testing.expect(hook_run.len != 0);
    try std.testing.expect(std.mem.indexOf(u8, hook_run, "recoverLeftoverAgentRuns(") != null); // the hook IS the owner

    const app = try readSrc(gpa, "src/app.zig");
    defer gpa.free(app);
    const app_nc = try lex(gpa, app, true); // comment-safe (strings kept) for the import binding
    defer gpa.free(app_nc);
    try std.testing.expect(std.mem.indexOf(u8, app_nc, "@import(\"agent_startup_recovery\")") != null);
    const app_code = try lex(gpa, app, false);
    defer gpa.free(app_code);
    const run_body = balancedBody(app_code, "pub fn runWithIo(");
    try std.testing.expect(run_body.len != 0);
    try std.testing.expect(std.mem.indexOf(u8, run_body, "runStartupThenDispatch(") != null);
    try std.testing.expect(std.mem.indexOf(u8, run_body, "StartupHook") != null); // the hook arg IS the owner's hook (wrong-hook mutant -> fail)
}
