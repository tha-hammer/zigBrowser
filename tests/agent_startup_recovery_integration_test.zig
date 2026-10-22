//! MS6.5.1 — RED-FIRST for the OPEN integration blocker (bd zigBrowser-3gl). Per RoseCat 2f8f5a8 the hook and the
//! adapter are INJECTABLE and DRIVEN: tests run the real StartupHook.run and RealOps.recover under spies and observe
//! that the owner call happens, its result is returned, and the forwarded args are exact. Source is bound to ONE
//! exact token sequence (import alias + constructor); the additive decoys are committed rows. UNREGISTERED,
//! signal-free, no display, no Macs; reaper_ready false. RED now: `agent_startup_recovery` absent (compile error).
const std = @import("std");
const recovery = @import("agent_run_recovery");
const startup = @import("agent_startup_recovery");

const HOOK_SENTINEL = recovery.StartupReport{ .status = .ran, .signalled = 41 };
const CORE_SENTINEL = recovery.StartupReport{ .status = .ran, .signalled = 42 };

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

// ---- DRIVE StartupHook.run: the hook IS the owner (injected spy recover) --------------------------------------

var g_recover_calls: usize = 0;
fn spyRecover(arena: std.mem.Allocator, io: std.Io) recovery.StartupReport {
    _ = arena;
    _ = io;
    g_recover_calls += 1;
    return HOOK_SENTINEL;
}

test "StartupHook.run calls the owner exactly once and returns its result" {
    g_recover_calls = 0;
    const hook = startup.StartupHook{ .arena = std.testing.allocator, .io = std.testing.io, .recover = &spyRecover };
    const got = hook.run(); // the REAL StartupHook.run, driven with a spy owner
    try std.testing.expectEqual(@as(usize, 1), g_recover_calls); // the owner call happens (dead run -> 0)
    try std.testing.expectEqual(HOOK_SENTINEL.signalled, got.signalled); // its result is returned (not swallowed)
    try std.testing.expectEqual(HOOK_SENTINEL.status, got.status);
}

// ---- DRIVE RealOps.recover: it forwards the exact args to the core and returns its result ---------------------

const TagClock = struct {
    token: usize,
    pub fn nowMs(_: TagClock) i64 {
        return 0;
    }
    pub fn sleepMs(_: TagClock, _: i64) void {}
};
const TagActuator = struct { token: usize };
const CoreCaps = struct { calls: usize = 0, sub: []const u8 = "", deadline: i64 = -1, clk: usize = 0, act: usize = 0 };
const SpyCore = struct {
    caps: *CoreCaps,
    pub fn run(self: SpyCore, io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir, sub: []const u8, clk: anytype, deadline_ms: i64, actuator: anytype) recovery.StartupReport {
        _ = io;
        _ = gpa;
        _ = dir;
        self.caps.calls += 1;
        self.caps.sub = sub;
        self.caps.deadline = deadline_ms;
        self.caps.clk = clk.token;
        self.caps.act = actuator.token;
        return CORE_SENTINEL;
    }
};

test "RealOps.recover calls the core once, forwards the exact args, and returns its result" {
    var caps = CoreCaps{};
    const ops = startup.RealOpsG(SpyCore){ .core = .{ .caps = &caps } };
    const got = ops.recover(std.testing.io, std.testing.allocator, std.Io.Dir.cwd(), "runs.json", TagClock{ .token = 5 }, 1234, TagActuator{ .token = 9 });
    try std.testing.expectEqual(@as(usize, 1), caps.calls); // the core (recoverAllAtStartup) call happens (dead-call -> 0)
    try std.testing.expectEqualStrings("runs.json", caps.sub); // ledger arg forwarded
    try std.testing.expectEqual(@as(i64, 1234), caps.deadline); // deadline forwarded
    try std.testing.expectEqual(@as(usize, 5), caps.clk); // the clock forwarded
    try std.testing.expectEqual(@as(usize, 9), caps.act); // the actuator forwarded
    try std.testing.expectEqual(CORE_SENTINEL.signalled, got.signalled); // its result is returned
}

// ---- SEAM: the gated owner, with counted ops + a clock whose construction is counted and identity-tagged -------

const Caps = struct {
    env: usize = 0,
    open: usize = 0,
    build: usize = 0,
    recover: usize = 0,
    close: usize = 0,
    now: usize = 0,
    construct: usize = 0,
    now_seq: [3]i64 = .{ 777, 888, 999 },
    captured_deadline: i64 = -1,
    captured_token: usize = 0,
};
const SpyActuator = struct {};
const CountedClock = struct {
    caps: *Caps,
    token: usize,
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
        self.caps.construct += 1;
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

test "gate FALSE: zero ops" {
    var caps = Caps{};
    const rep = startup.recoverLeftoverAgentRunsWith(false, std.testing.io, std.testing.allocator, SpyOps{ .caps = &caps, .result = .{ .status = .ran } });
    try std.testing.expectEqual(recovery.StartupStatus.disabled, rep.status);
    inline for (.{ caps.env, caps.open, caps.build, caps.recover, caps.close, caps.now, caps.construct }) |c| {
        try std.testing.expectEqual(@as(usize, 0), c);
    }
}

test "gate TRUE: each op once; one close; one clock construction; first identity at recover; deadline = first now + budget" {
    var caps = Caps{};
    const rep = startup.recoverLeftoverAgentRunsWith(true, std.testing.io, std.testing.allocator, SpyOps{ .caps = &caps, .result = .{ .status = .ran } });
    try std.testing.expectEqual(recovery.StartupStatus.ran, rep.status);
    try std.testing.expectEqual(@as(usize, 1), caps.env);
    try std.testing.expectEqual(@as(usize, 1), caps.open);
    try std.testing.expectEqual(@as(usize, 1), caps.build);
    try std.testing.expectEqual(@as(usize, 1), caps.recover);
    try std.testing.expectEqual(@as(usize, 1), caps.close);
    try std.testing.expectEqual(@as(usize, 1), caps.now);
    try std.testing.expectEqual(@as(usize, 1), caps.construct);
    try std.testing.expectEqual(@as(usize, 1), caps.captured_token);
    try std.testing.expectEqual(@as(i64, 777) + startup.STARTUP_BUDGET_MS, caps.captured_deadline);
}

test "a non-ok report is PROPAGATED, never swallowed; dir still closed once" {
    var caps = Caps{};
    const rep = startup.recoverLeftoverAgentRunsWith(true, std.testing.io, std.testing.allocator, SpyOps{ .caps = &caps, .result = .{ .status = .ran, .fail_closed = 1 } });
    try std.testing.expect(!rep.ok());
    try std.testing.expectEqual(@as(usize, 1), rep.fail_closed);
    try std.testing.expectEqual(@as(usize, 1), caps.close);
}

test "RealOps builds the reviewed Darwin actuator type" {
    const ro = startup.RealOps{ .core = .{} };
    try std.testing.expect(@TypeOf(ro.buildActuator()) == recovery.ConcreteActuator(recovery.DarwinWiring));
    try std.testing.expectEqualStrings("runs.json", ro.ledgerName());
}

// ---- SOURCE binding: ONE exact token sequence (import alias + constructor); additive decoys committed as rows ---

fn commentStripped(gpa: std.mem.Allocator, src: []const u8) ![]u8 {
    // strip // and /* */ and `\\` multiline comments; KEEP "..." strings (so the import path survives).
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
        out[n] = src[i];
        n += 1;
        i += 1;
    }
    return gpa.realloc(out, n);
}

const IMPORT_TOKEN = "const agent_startup_recovery = @import(\"agent_startup_recovery\")";
const CTOR_TOKEN = "runStartupThenDispatch(agent_startup_recovery.StartupHook{";

test "source: app binds the import alias and passes EXACTLY agent_startup_recovery.StartupHook to the combinator" {
    const gpa = std.testing.allocator;
    const app = try readSrc(gpa, "src/app.zig");
    defer gpa.free(app);
    const code = try commentStripped(gpa, app);
    defer gpa.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, IMPORT_TOKEN) != null);
    try std.testing.expect(std.mem.indexOf(u8, code, CTOR_TOKEN) != null);
}

test "source(committed mutants): additive decoy and wrong-hook do NOT satisfy the exact constructor token" {
    const gpa = std.testing.allocator;
    // additive decoy: the real first arg is OtherHook carrying a StartupHook{} payload; a loose predicate passes.
    const DECOY = "_ = runStartupThenDispatch(OtherHook{ .decoy = agent_startup_recovery.StartupHook{} }, Dispatch{});";
    const d = try commentStripped(gpa, DECOY);
    defer gpa.free(d);
    try std.testing.expect(std.mem.indexOf(u8, d, CTOR_TOKEN) == null); // first arg is OtherHook -> rejected

    // wrong-hook: a different type whose name merely contains "StartupHook".
    const WRONG = "_ = runStartupThenDispatch(agent_startup_recovery.WrongStartupHook{}, Dispatch{});";
    const w = try commentStripped(gpa, WRONG);
    defer gpa.free(w);
    try std.testing.expect(std.mem.indexOf(u8, w, CTOR_TOKEN) == null); // ".WrongStartupHook{" != ".StartupHook{"
}

fn readSrc(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, .limited(1 << 20));
}
