//! S7b (chat-drawer plan section 10, S7, rev 16.20.35; RoseCat 6575): a closed window's broker
//! detaches; it is never joined on the GTK thread. `Broker.detach(&reaper)` returns at once,
//! drops the queued calls unanswered, and drops the running call's answer: no sink is called
//! after it returns. The app's one `Reaper` joins the broker's worker (which ends when its
//! running call's engine work ends) and its deadline thread, and frees the Broker; the
//! reaper is joined at app exit. Nothing leaks (the testing allocator checks) and no thread
//! is left behind.
//! The new API is reached through @hasDecl, so this file compiles before the green and fails.
const std = @import("std");
const automation_server = @import("automation_server");
const fake = @import("agent_tools_fake.zig");

const testing = std.testing;
const gpa = testing.allocator;
const broker = automation_server.agent_broker;
const has = @hasDecl(broker, "Reaper") and @hasDecl(broker.Broker, "create") and @hasDecl(broker.Broker, "detach");

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

/// The process is back to `baseline` threads within `ms`. A joined thread can stay listed in
/// /proc/self/task for a moment after its join returns; a thread left behind never leaves.
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

test "detach while a call runs: returns at once, answers nothing more, the reaper joins and frees" {
    if (!has) return error.TestNoDetach;
    const f = try fake.Fixture.create("detach", "zb-automation-token-canary-7f3a9c");
    defer f.destroy();
    try f.server.startCore();
    const baseline = try threadCount();
    var reaper = broker.Reaper.init(gpa);
    var reaped = false;
    defer if (!reaped) reaper.deinit();

    const w = &f.pages.windows[0];
    w.hold.store(true, .release);
    defer w.hold.store(false, .release);
    const b = try broker.Broker.create(gpa, &f.server, 1, 30_000);
    var ctx: u8 = 0;
    b.submit("c-A", "mcp__zigbrowser__get_text", "{\"selector\":\"css=#a\"}", .{ .ctx = &ctx, .done = done });
    try waitFor(&w.in_flight, 1, 5_000); // A is in the engine
    b.submit("c-B", "mcp__zigbrowser__get_text", "{\"selector\":\"css=#b\"}", .{ .ctx = &ctx, .done = done });

    const before = fake.nowMs();
    b.detach(&reaper); // the GTK thread's call: never a join
    try testing.expect(fake.nowMs() - before < 50);

    w.hold.store(false, .release);
    try waitFor(&w.evals, 1, 5_000); // A's engine work ends
    testing.io.sleep(.fromMilliseconds(300), .awake) catch {};
    try testing.expectEqual(@as(u32, 0), answers.load(.acquire)); // nothing answered after detach
    try testing.expectEqual(@as(u32, 1), w.evals.load(.acquire)); // B never ran

    reaper.deinit(); // joins the reaper, which joined the broker's threads and freed it
    reaped = true;
    try expectThreadsBackTo(baseline, 2_000);
}

test "a broker detached before any call needs no thread and frees at once" {
    if (!has) return error.TestNoDetach;
    const f = try fake.Fixture.create("detach-idle", "zb-automation-token-canary-7f3a9c");
    defer f.destroy();
    try f.server.startCore();
    var reaper = broker.Reaper.init(gpa);
    defer reaper.deinit();
    const b = try broker.Broker.create(gpa, &f.server, 1, 30_000);
    const before = fake.nowMs();
    b.detach(&reaper);
    try testing.expect(fake.nowMs() - before < 50);
}

/// A hold in `Broker.before_publish`: the worker has the engine's answer and waits here,
/// before the locked publication, until released.
const Hold = struct {
    entered: std.atomic.Value(u32) = .init(0),
    release: std.atomic.Value(bool) = .init(false),

    fn run(ctx: *anyopaque) void {
        const self: *Hold = @ptrCast(@alignCast(ctx));
        _ = self.entered.fetchAdd(1, .acq_rel);
        while (!self.release.load(.acquire)) testing.io.sleep(.fromMilliseconds(2), .awake) catch {};
    }
};

var held_answers = std.atomic.Value(u32).init(0);

fn heldDone(_: *anyopaque, _: []const u8, _: broker.Result) void {
    _ = held_answers.fetchAdd(1, .acq_rel);
}

test "detach after a call's engine answer and before its publication: the sink is never called (rev 16.20.36)" {
    if (!has or !@hasField(broker.Broker, "before_publish")) return error.TestNoPublishHold;
    const f = try fake.Fixture.create("detach-held", "zb-automation-token-canary-7f3a9c");
    defer f.destroy();
    try f.server.startCore();
    const baseline = try threadCount();
    var reaper = broker.Reaper.init(gpa);
    var reaped = false;
    defer if (!reaped) reaper.deinit();

    var hold: Hold = .{};
    defer hold.release.store(true, .release);
    const b = try broker.Broker.create(gpa, &f.server, 1, 30_000);
    @field(b, "before_publish") = .{ .ctx = &hold, .run = Hold.run };
    var ctx: u8 = 0;
    b.submit("c-A", "mcp__zigbrowser__get_text", "{\"selector\":\"css=#a\"}", .{ .ctx = &ctx, .done = heldDone });
    try waitFor(&hold.entered, 1, 5_000); // the engine answered; the worker waits before publishing
    try testing.expectEqual(@as(u32, 1), f.pages.windows[0].evals.load(.acquire));

    const before = fake.nowMs();
    b.detach(&reaper);
    try testing.expect(fake.nowMs() - before < 50);
    hold.release.store(true, .release);
    testing.io.sleep(.fromMilliseconds(300), .awake) catch {};
    try testing.expectEqual(@as(u32, 0), held_answers.load(.acquire));

    reaper.deinit();
    reaped = true;
    try expectThreadsBackTo(baseline, 2_000);
}
