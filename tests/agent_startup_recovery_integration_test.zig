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

/// The text between the matching parens of the first `call` (a "name(" prefix) in `code`; null if absent.
fn callInner(code: []const u8, call: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, code, call) orelse return null;
    var i = at + call.len;
    var depth: usize = 1;
    const start = i;
    while (i < code.len) : (i += 1) {
        if (code[i] == '(') depth += 1;
        if (code[i] == ')') {
            depth -= 1;
            if (depth == 0) return code[start..i];
        }
    }
    return null;
}
/// The nth top-level (comma-separated, ()/[]/{}-aware) argument in `inner`, trimmed; null if absent.
fn nthArg(inner: []const u8, n: usize) ?[]const u8 {
    var depth: usize = 0;
    var start: usize = 0;
    var idx: usize = 0;
    var i: usize = 0;
    while (i <= inner.len) : (i += 1) {
        const at_end = i == inner.len;
        const c: u8 = if (at_end) ',' else inner[i];
        if (!at_end and (c == '(' or c == '[' or c == '{')) {
            depth += 1;
        } else if (!at_end and (c == ')' or c == ']' or c == '}')) {
            depth -= 1;
        } else if ((at_end or c == ',') and depth == 0) {
            if (idx == n) return std.mem.trim(u8, inner[start..i], " \t\r\n");
            idx += 1;
            start = i + 1;
        }
    }
    return null;
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

// (1) call-site: the FIRST argument of runStartupThenDispatch is the named owner hook. The additive-decoy mutant
// (OtherHook{} first + an unrelated StartupHook{} elsewhere) is committed below as a row, not an offline edit.
test "call-site: runStartupThenDispatch's first arg is StartupHook; additive-decoy is rejected" {
    const gpa = std.testing.allocator;
    const app = try readSrc(gpa, "src/app.zig");
    defer gpa.free(app);
    const code = try lex(gpa, app, false);
    defer gpa.free(code);
    const nc = try lex(gpa, app, true); // comment-safe import binding (strings kept)
    defer gpa.free(nc);
    try std.testing.expect(std.mem.indexOf(u8, nc, "@import(\"agent_startup_recovery\")") != null);
    const body = balancedBody(code, "pub fn runWithIo(");
    try std.testing.expect(body.len != 0);
    const inner = callInner(body, "runStartupThenDispatch(") orelse return error.NoCall;
    const a0 = nthArg(inner, 0) orelse return error.NoArg;
    try std.testing.expect(std.mem.indexOf(u8, a0, "StartupHook") != null); // first arg IS the owner hook

    const MUT = // additive decoy: the real first arg is OtherHook; a StartupHook{} sits unrelated nearby
        "pub fn runWithIo() void {\n    const decoy = StartupHook{};\n    _ = decoy;\n" ++
        "    _ = runStartupThenDispatch(OtherHook{ .a = 1 }, Dispatch{ .c = 2 });\n}\n";
    const mcode = try lex(gpa, MUT, false);
    defer gpa.free(mcode);
    const mbody = balancedBody(mcode, "pub fn runWithIo(");
    const minner = callInner(mbody, "runStartupThenDispatch(") orelse return error.NoCall;
    const ma0 = nthArg(minner, 0) orelse return error.NoArg;
    try std.testing.expect(std.mem.indexOf(u8, ma0, "StartupHook") == null); // the FIRST-arg bind rejects the decoy
}

// (2) StartupHook.run IS the owner, as a LIVE top-level statement. The dead-branch mutant is a committed row.
test "StartupHook.run calls the owner as a live top-level statement; dead-branch is rejected" {
    const gpa = std.testing.allocator;
    const owner = try readSrc(gpa, "src/agent_startup_recovery.zig");
    defer gpa.free(owner);
    const code = try lex(gpa, owner, false);
    defer gpa.free(code);
    const run = balancedBody(balancedBody(code, "pub const StartupHook = struct"), "pub fn run(");
    try std.testing.expect(run.len != 0);
    const at = std.mem.indexOf(u8, run, "recoverLeftoverAgentRuns(") orelse return error.NoCall;
    try std.testing.expectEqual(@as(i64, 1), braceNet(run, at)); // live, top-level (not a dead branch)

    const MUT = "pub fn run(self: H) void {\n    if (false) {\n        _ = recoverLeftoverAgentRuns(self.a, self.b);\n    }\n}\n";
    const mcode = try lex(gpa, MUT, false);
    defer gpa.free(mcode);
    const mrun = balancedBody(mcode, "pub fn run(");
    const mat = std.mem.indexOf(u8, mrun, "recoverLeftoverAgentRuns(") orelse return error.NoCall;
    try std.testing.expect(braceNet(mrun, mat) != 1); // nested in if (false) -> depth 2 -> rejected
}

// (3) RealOps.recover forwards the live ledger/clock/deadline/actuator args to recoverAllAtStartup. The dead-call
// mutant is a committed row.
test "RealOps.recover forwards the live args to recoverAllAtStartup; dead-call is rejected" {
    const gpa = std.testing.allocator;
    const owner = try readSrc(gpa, "src/agent_startup_recovery.zig");
    defer gpa.free(owner);
    const code = try lex(gpa, owner, false);
    defer gpa.free(code);
    const realops = balancedBody(code, "pub const RealOps = struct");
    const recover = balancedBody(realops, "pub fn recover("); // RealOps body first, then its recover method
    try std.testing.expect(recover.len != 0);
    const inner = callInner(recover, "recovery.recoverAllAtStartup(") orelse return error.NoCall;
    try std.testing.expectEqualStrings("dir", nthArg(inner, 2).?); // the opened dir
    try std.testing.expectEqualStrings("sub", nthArg(inner, 3).?); // the ledger name argument
    try std.testing.expectEqualStrings("clk", nthArg(inner, 4).?); // the clock
    try std.testing.expectEqualStrings("deadline_ms", nthArg(inner, 5).?); // the one absolute deadline
    try std.testing.expectEqualStrings("actuator", nthArg(inner, 6).?); // the reviewed actuator

    const MUT = "pub fn recover(self: R) Rep {\n    _ = self;\n    return .{ .status = .disabled };\n}\n"; // dead: no call
    const mcode = try lex(gpa, MUT, false);
    defer gpa.free(mcode);
    const mrec = balancedBody(mcode, "pub fn recover(");
    try std.testing.expect(callInner(mrec, "recovery.recoverAllAtStartup(") == null); // no live call -> rejected
}
