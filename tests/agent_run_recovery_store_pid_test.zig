//! MS6.5.1, bd zigBrowser-4pa.65 and zigBrowser-4pa.68 (plan rev 32 R30-MS6; R29.6 I-W5, D-W1), driven through the
//! production startup core `recoverAllAtStartupGated` and the production `ledger.parse`, with a signal-free
//! counting actuator:
//! - 4pa.65: the ledger's real store name is `zigbrowser-agent-runs.json`. A dead entry in a store of that name is
//!   recovered exactly once and retired, and the store ends empty. (The transaction loaded and published a
//!   hard-coded "runs.json", so with the real name every entry ended `.fail_closed`.)
//! - 4pa.68: an entry `pid` below 2 (0, -1, 1), or one that differs from the pid in its basename, is a malformed
//!   read. It never reaches the actuator: zero pins, nothing signalled, the store bytes unchanged. (pid 0 and -1
//!   read as absent, so they were classified proved-dead and pinned.)
//! RED, UNREGISTERED: the green registers it (step `test-agent-run-recovery-store-pid`, in `test`).
const std = @import("std");
const ledger = @import("agent_run_ledger");
const recovery = @import("agent_run_recovery");

const REAL_STORE = "zigbrowser-agent-runs.json";
const DEAD_PID: i32 = 2147483645; // absent + reuse-proof
const DEAD_BASENAME = "zigbrowser-agent-2147483645-00cc00cc00cc00cc";
const BUDGET_MS: i64 = 30000;

const FakeLease = struct {
    pub fn fixedPoint(_: *FakeLease, clock: anytype, deadline_ms: i64) ledger.FixedPoint {
        _ = clock;
        _ = deadline_ms;
        return .clean;
    }
    pub fn teardown(_: *FakeLease, clock: anytype, deadline_ms: i64) ledger.Teardown {
        _ = clock;
        _ = deadline_ms;
        return .done;
    }
    pub fn deinit(_: *FakeLease) void {}
};
const FakePin = union(enum) { held: FakeLease, gone, mismatch, unreadable };

/// Provenance always matches and the fixed point is clean: every pin would end in a retirement.
const CountingActuator = struct {
    pins: *usize,
    pub fn pin(self: CountingActuator, dir: std.Io.Dir, entry: ledger.Entry) FakePin {
        _ = dir;
        _ = entry;
        self.pins.* += 1;
        return .{ .held = .{} };
    }
};

fn entryOf(basename: []const u8, pid: i32) ledger.Entry {
    return .{ .basename = basename, .dev = 1, .ino = 2, .uid = 0, .mode = 16832, .pid = pid, .start_kind = .linux_ticks, .start_sec = 234567, .start_usec = 0, .state = .active };
}

fn doc(buf: []u8, basename: []const u8, pid: i32) []const u8 {
    return std.fmt.bufPrint(buf, "{{\"schema_version\":2,\"runs\":[{{\"basename\":\"{s}\",\"dev\":1,\"ino\":2,\"uid\":0,\"mode\":16832,\"pid\":{d},\"start_kind\":\"linux_ticks\",\"start_sec\":234567,\"start_usec\":0,\"state\":\"active\"}}]}}", .{ basename, pid }) catch unreachable;
}

test "4pa.65: a dead entry in the REAL store name is recovered once and retired; the store ends empty" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const clock = ledger.RealClock{ .io = io };
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    try ledger.publish(io, td.dir, REAL_STORE, &[_]ledger.Entry{entryOf(DEAD_BASENAME, DEAD_PID)});

    var pins: usize = 0;
    const rep = recovery.recoverAllAtStartupGated(true, io, gpa, td.dir, REAL_STORE, clock, clock.nowMs() + BUDGET_MS, CountingActuator{ .pins = &pins });
    try std.testing.expectEqual(@as(usize, 1), rep.signalled);
    try std.testing.expectEqual(@as(usize, 0), rep.fail_closed);
    try std.testing.expectEqual(@as(usize, 1), pins);
    try std.testing.expect(rep.ok());
    var l = try ledger.load(io, gpa, td.dir, REAL_STORE);
    defer l.deinit();
    try std.testing.expectEqual(@as(usize, 0), l.entries().len);
}

test "4pa.68: parse refuses pid 0, -1 and 1, and a pid that differs from its basename's" {
    const gpa = std.testing.allocator;
    const Row = struct { basename: []const u8, pid: i32 };
    const bad = [_]Row{
        .{ .basename = "zigbrowser-agent-0-0011223344556677", .pid = 0 },
        .{ .basename = "zigbrowser-agent-1-0011223344556677", .pid = -1 },
        .{ .basename = "zigbrowser-agent-1-0011223344556677", .pid = 1 },
        .{ .basename = "zigbrowser-agent-4242-0011223344556677", .pid = 4243 },
        .{ .basename = "zigbrowser-agent-4242-0011223344556677", .pid = DEAD_PID },
    };
    var buf: [512]u8 = undefined;
    for (bad) |row| {
        try std.testing.expectError(error.Malformed, ledger.parse(gpa, doc(&buf, row.basename, row.pid)));
    }
    // The honest row: the entry pid equals its basename's.
    var l = try ledger.parse(gpa, doc(&buf, "zigbrowser-agent-4242-0011223344556677", 4242));
    defer l.deinit();
    try std.testing.expectEqual(@as(i32, 4242), l.entries()[0].pid);
}

test "4pa.68: a pid-0, pid--1 or mismatched-pid entry never reaches the actuator, and the store is unchanged" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const clock = ledger.RealClock{ .io = io };
    const Row = struct { basename: []const u8, pid: i32 };
    const rows = [_]Row{
        .{ .basename = "zigbrowser-agent-0-00dd00dd00dd00dd", .pid = 0 },
        .{ .basename = "zigbrowser-agent-1-00dd00dd00dd00dd", .pid = -1 },
        .{ .basename = "zigbrowser-agent-4242-00dd00dd00dd00dd", .pid = DEAD_PID },
    };
    var buf: [512]u8 = undefined;
    for (rows) |row| {
        var td = std.testing.tmpDir(.{});
        defer td.cleanup();
        const bytes = doc(&buf, row.basename, row.pid);
        try td.dir.writeFile(io, .{ .sub_path = "runs.json", .data = bytes });

        var pins: usize = 0;
        const rep = recovery.recoverAllAtStartupGated(true, io, gpa, td.dir, "runs.json", clock, clock.nowMs() + BUDGET_MS, CountingActuator{ .pins = &pins });
        try std.testing.expectEqual(@as(usize, 0), pins); // never pinned, so never signalled
        try std.testing.expectEqual(@as(usize, 0), rep.signalled);
        try std.testing.expect(!rep.ok()); // a malformed store fails closed, visibly
        const after = try td.dir.readFileAlloc(io, "runs.json", gpa, .limited(1 << 16));
        defer gpa.free(after);
        try std.testing.expectEqualStrings(bytes, after);
    }
}
