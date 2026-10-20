//! S7b (chat-drawer plan section 10, S7, rev 16.20.36; RoseCat 55079fa, Agent Mail 6650): a
//! closed window's broker is never joined on the GTK thread, even when memory runs out.
//! Adopting a broker into the app's Reaper must allocate nothing: with a Reaper whose
//! allocator fails every allocation, `detach` on a broker whose call is still running in the
//! engine (which, in the app, needs the GTK thread) returns at once; once the call is
//! released, no sink is called, and the reaper later joins and frees it, leaving no thread
//! and no allocation behind.
//! Before the fix, a failed adoption joined the broker on the caller: `detach` blocked until
//! the engine call ended. `detach` runs on a helper thread here, so that red ends as a failure,
//! not a hang.
const std = @import("std");
const automation_server = @import("automation_server");
const fake = @import("agent_tools_fake.zig");

const testing = std.testing;
const gpa = testing.allocator;
const broker = automation_server.agent_broker;

var answers = std.atomic.Value(u32).init(0);

fn done(_: *anyopaque, _: []const u8, _: broker.Result) void {
    _ = answers.fetchAdd(1, .acq_rel);
}

fn threadCount() !usize {
    var dir = try std.Io.Dir.cwd().openDir(testing.io, "/proc/self/task", .{ .iterate = true });
    defer dir.close(testing.io);
    var it = dir.iterate();
    var n: usize = 0;
    while (try it.next(testing.io)) |_| n += 1;
    return n;
}

/// The process is back to `baseline` threads within `ms` (a joined thread can stay listed in
/// /proc/self/task for a moment after its join returns).
fn expectThreadsBackTo(baseline: usize, ms: i64) !void {
    const until = fake.nowMs() + ms;
    while (try threadCount() > baseline) {
        if (fake.nowMs() > until) return error.TestThreadLeftBehind;
        testing.io.sleep(.fromMilliseconds(5), .awake) catch {};
    }
}

fn waitFor(counter: *std.atomic.Value(u32), n: u32, ms: i64) !void {
    const until = fake.nowMs() + ms;
    while (counter.load(.acquire) < n) {
        if (fake.nowMs() > until) return error.TestNotReached;
        testing.io.sleep(.fromMilliseconds(2), .awake) catch {};
    }
}

/// `detach` on its own thread, standing in for the GTK thread, timed.
const Detach = struct {
    b: *broker.Broker,
    reaper: *broker.Reaper,
    returned: std.atomic.Value(u32) = .init(0),
    took_ms: i64 = 0,

    fn run(self: *Detach) void {
        const before = fake.nowMs();
        self.b.detach(self.reaper);
        self.took_ms = fake.nowMs() - before;
        self.returned.store(1, .release);
    }
};

test "out of memory: detach of a broker whose call is running still returns at once and never joins on the caller" {
    const f = try fake.Fixture.create("detach-oom", "zb-automation-token-canary-7f3a9c");
    defer f.destroy();
    try f.server.startCore();
    const baseline = try threadCount();
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    var reaper = broker.Reaper.init(failing.allocator());
    var reaped = false;
    defer if (!reaped) reaper.deinit();

    const w = &f.pages.windows[0];
    w.hold.store(true, .release); // the engine call cannot end until released, as with GTK busy
    defer w.hold.store(false, .release);
    const b = try broker.Broker.create(gpa, &f.server, 1, 30_000);
    var ctx: u8 = 0;
    b.submit("c-A", "mcp__zigbrowser__get_text", "{\"selector\":\"css=#a\"}", .{ .ctx = &ctx, .done = done });
    try waitFor(&w.in_flight, 1, 5_000); // the call is in the engine

    var call: Detach = .{ .b = b, .reaper = &reaper };
    const t = try std.Thread.spawn(.{}, Detach.run, .{&call});
    const returned = waitFor(&call.returned, 1, 500); // while the engine call is still held
    w.hold.store(false, .release);
    t.join();
    try returned;
    try testing.expect(call.took_ms < 50);

    try waitFor(&w.evals, 1, 5_000); // the engine work ends after detach
    testing.io.sleep(.fromMilliseconds(300), .awake) catch {};
    try testing.expectEqual(@as(u32, 0), answers.load(.acquire)); // nothing answered after detach

    reaper.deinit(); // joins the reaper, which joined and freed the broker
    reaped = true;
    try expectThreadsBackTo(baseline, 2_000);
}
