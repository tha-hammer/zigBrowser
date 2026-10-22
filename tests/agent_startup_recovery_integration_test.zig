//! MS6.5.1 — RED-FIRST for the OPEN integration blocker (bd zigBrowser-3gl), strengthened per RoseCat 5a204f3: the
//! real app-startup OWNER must call the startup-recovery core, EXACTLY ONCE, BEFORE command dispatch, and while the
//! gate is false it must open/construct NOTHING. UNREGISTERED (built by no gate step), signal-free, no display, no
//! Macs. `reaper_ready` stays false. RED now: the owner module `agent_startup_recovery` does not exist yet (compile
//! error) and app.zig has no call (source assertions fail).
//!
//! Two independent kinds of proof (RoseCat 5a204f3 #4):
//!   - BEHAVIORAL (the real owner seam): gate-false is zero-filesystem / zero-actuator / zero-recover; gate-true runs
//!     each exactly once; a non-ok report is propagated, not swallowed.
//!   - SOURCE (bound to the real startup path): balanced-brace fn bodies, comments & strings stripped, EXACT
//!     qualified call expressions; the owner call appears exactly once before dispatch; the owner reaches
//!     recoverAllAtStartup; the app-owned ledger name, one absolute deadline and the reviewed actuator are pinned.
const std = @import("std");
const recovery = @import("agent_run_recovery");
const startup = @import("agent_startup_recovery");

// ---- behavioral: the real owner seam, driven with spy ops ------------------------------------------------------

const Counts = struct { env: usize = 0, open: usize = 0, build: usize = 0, recover: usize = 0, close: usize = 0 };
const SpyActuator = struct {}; // never pinned in these rows; buildActuator just hands one back
const SpyOps = struct {
    counts: *Counts,
    result: recovery.StartupReport,
    pub fn runtimeDir(self: SpyOps) ?[]const u8 {
        self.counts.env += 1;
        return "/nonexistent-zb-runtime"; // never opened for real below
    }
    pub fn openDir(self: SpyOps, io: std.Io, path: []const u8) !std.Io.Dir {
        _ = io;
        _ = path;
        self.counts.open += 1;
        return std.Io.Dir.cwd(); // a handle, no real filesystem open
    }
    pub fn closeDir(self: SpyOps, io: std.Io, dir: *std.Io.Dir) void {
        _ = io;
        _ = dir;
        self.counts.close += 1;
    }
    pub fn buildActuator(self: SpyOps) SpyActuator {
        self.counts.build += 1;
        return .{};
    }
    pub fn recover(self: SpyOps, io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir, sub: []const u8, clock: anytype, deadline_ms: i64, actuator: anytype) recovery.StartupReport {
        _ = io;
        _ = gpa;
        _ = dir;
        _ = sub;
        _ = clock;
        _ = deadline_ms;
        _ = actuator;
        self.counts.recover += 1;
        return self.result;
    }
};

test "#3 gate FALSE: the owner opens NOTHING, constructs NO actuator, and does not recover (zero ops)" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var counts = Counts{};
    const rep = startup.recoverLeftoverAgentRunsWith(false, io, gpa, SpyOps{ .counts = &counts, .result = .{ .status = .ran } });
    try std.testing.expectEqual(recovery.StartupStatus.disabled, rep.status);
    try std.testing.expectEqual(@as(usize, 0), counts.env); // no environment read
    try std.testing.expectEqual(@as(usize, 0), counts.open); // zero filesystem
    try std.testing.expectEqual(@as(usize, 0), counts.build); // zero actuator construction
    try std.testing.expectEqual(@as(usize, 0), counts.recover); // and no recovery call
}

test "#2 gate TRUE: the owner opens, builds and recovers EXACTLY once" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var counts = Counts{};
    const rep = startup.recoverLeftoverAgentRunsWith(true, io, gpa, SpyOps{ .counts = &counts, .result = .{ .status = .ran } });
    try std.testing.expectEqual(recovery.StartupStatus.ran, rep.status);
    try std.testing.expectEqual(@as(usize, 1), counts.env);
    try std.testing.expectEqual(@as(usize, 1), counts.open);
    try std.testing.expectEqual(@as(usize, 1), counts.build);
    try std.testing.expectEqual(@as(usize, 1), counts.recover); // exactly once
}

test "#4 a non-ok report is PROPAGATED by the owner, never swallowed" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var counts = Counts{};
    const non_ok = recovery.StartupReport{ .status = .ran, .fail_closed = 1 };
    try std.testing.expect(!non_ok.ok());
    const rep = startup.recoverLeftoverAgentRunsWith(true, io, gpa, SpyOps{ .counts = &counts, .result = non_ok });
    try std.testing.expect(!rep.ok()); // the owner returns the non-ok report
    try std.testing.expectEqual(@as(usize, 1), rep.fail_closed);
}

// ---- source helpers: strip comments/strings, extract balanced fn bodies, exact qualified-call counting ----------

fn stripZig(gpa: std.mem.Allocator, src: []const u8) ![]u8 {
    var out = try gpa.alloc(u8, src.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < src.len) {
        if (src[i] == '/' and i + 1 < src.len and src[i + 1] == '/') {
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
    return gpa.realloc(out, n); // shrink to the exact length so the caller frees the right allocation
}

/// The brace-balanced body of `decl` (a `[pub ]fn name(` prefix) in already-stripped `src`. Empty if absent.
fn fnBodyBalanced(src: []const u8, decl: []const u8) []const u8 {
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

// ---- source link 1 (app.zig): runWithIo calls the owner EXACTLY ONCE, BEFORE dispatch -------------------------

test "link1: app.runWithIo calls recoverLeftoverAgentRuns exactly once, before command dispatch" {
    const gpa = std.testing.allocator;
    const raw = try readSrc(gpa, "src/app.zig");
    defer gpa.free(raw);
    const src = try stripZig(gpa, raw);
    defer gpa.free(src);

    // the import path is a STRING literal, so check the RAW source (stripZig blanks string contents).
    try std.testing.expect(std.mem.indexOf(u8, raw, "@import(\"agent_startup_recovery\")") != null);

    // the call-site proof runs on the STRIPPED, brace-balanced runWithIo body (no comment/string false matches).
    const body = fnBodyBalanced(src, "pub fn runWithIo(");
    try std.testing.expect(body.len != 0);

    const call = "agent_startup_recovery.recoverLeftoverAgentRuns(";
    try std.testing.expectEqual(@as(usize, 1), countOcc(body, call)); // exactly once (duplicate-call mutant -> 2)

    const call_at = std.mem.indexOf(u8, body, call).?;
    const dispatch_at = std.mem.indexOf(u8, body, "switch (command)") orelse body.len;
    try std.testing.expect(call_at < dispatch_at); // BEFORE dispatch (branch-only / after-dispatch mutants -> fail)
}

// ---- source link 2 (the owner module): RealOps.recover reaches the gated core; pins ----------------------------

test "link2: the owner's RealOps.recover reaches recoverAllAtStartup; ledger name, deadline and actuator pinned" {
    const gpa = std.testing.allocator;
    const raw = try readSrc(gpa, "src/agent_startup_recovery.zig");
    defer gpa.free(raw);
    const src = try stripZig(gpa, raw);
    defer gpa.free(src);

    // RealOps.recover delegates to the gated core (the second call link, independent of link1) — CODE, stripped.
    const recover_body = fnBodyBalanced(src, "pub fn recover(");
    try std.testing.expect(recover_body.len != 0);
    try std.testing.expect(std.mem.indexOf(u8, recover_body, "recovery.recoverAllAtStartup(") != null);

    // the gated owner seam pins ONE absolute deadline (CODE, stripped) and the app-owned ledger name (STRING, raw).
    const seam = fnBodyBalanced(src, "pub fn recoverLeftoverAgentRunsWith(");
    try std.testing.expect(seam.len != 0);
    try std.testing.expectEqual(@as(usize, 1), countOcc(seam, "+ STARTUP_BUDGET_MS")); // ONE absolute deadline
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"runs.json\"") != null); // app-owned ledger location
    try std.testing.expect(std.mem.indexOf(u8, raw, "@import(\"agent_run_recovery\")") != null);

    // readiness bound to the gate (CODE, stripped); the reviewed Darwin actuator + its Mac compile boundary (CODE).
    const prod = fnBodyBalanced(src, "pub fn recoverLeftoverAgentRuns(");
    try std.testing.expect(std.mem.indexOf(u8, prod, "recovery.reaper_ready") != null);

    // the reviewed actuator appears in buildActuator's return type (the signature, not its brace body) — CODE.
    try std.testing.expect(std.mem.indexOf(u8, src, "ConcreteActuator(recovery.DarwinWiring)") != null);
}
