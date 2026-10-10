//! M8: per-page FIFO command queue, cancellation, queue.wait_ms.
const std = @import("std");
const automation = @import("automation");
const fakes = @import("automation/fake_page_port.zig");

const queue_mod = automation.queue;
const engine = automation.engine;
const router = automation.router;

const gpa = std.testing.allocator;
const io = std.testing.io;

const Log = struct {
    mutex: std.Io.Mutex = .init,
    items: [16]u8 = undefined,
    len: usize = 0,

    fn push(self: *Log, c: u8) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.items[self.len] = c;
        self.len += 1;
    }

    fn slice(self: *Log) []const u8 {
        return self.items[0..self.len];
    }
};

fn worker(queue: *queue_mod.PageCommandQueue, page: []const u8, tag: u8, log: *Log, result: *?anyerror) void {
    const ticket = queue.acquire(page) catch |err| {
        result.* = err;
        return;
    };
    log.push(tag);
    queue.release(ticket);
}

fn waitForPending(queue: *queue_mod.PageCommandQueue, page: []const u8, count: usize) !void {
    var tries: usize = 0;
    while (queue.pendingCount(page) < count) : (tries += 1) {
        if (tries > 5000) return error.TestTimeout;
        io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
}

test "same-page commands run strictly FIFO" {
    var queue = queue_mod.PageCommandQueue.init(gpa, io);
    defer queue.deinit();
    var log: Log = .{};

    const holder = try queue.acquire("page-1");
    var results = [_]?anyerror{null} ** 5;
    var threads: [5]std.Thread = undefined;
    for (0..5) |i| {
        threads[i] = try std.Thread.spawn(.{}, worker, .{ &queue, "page-1", @as(u8, 'a') + @as(u8, @intCast(i)), &log, &results[i] });
        // Enqueue order is fixed by waiting until each worker is queued.
        try waitForPending(&queue, "page-1", i + 1);
    }
    try std.testing.expectEqual(@as(usize, 0), log.len);
    queue.release(holder);
    for (threads) |t| t.join();
    try std.testing.expectEqualStrings("abcde", log.slice());
    for (results) |r| try std.testing.expect(r == null);
}

test "different pages progress independently" {
    var queue = queue_mod.PageCommandQueue.init(gpa, io);
    defer queue.deinit();
    var log: Log = .{};

    const holder = try queue.acquire("page-1");
    defer queue.release(holder);
    var result: ?anyerror = null;
    const t = try std.Thread.spawn(.{}, worker, .{ &queue, "page-2", 'x', &log, &result });
    t.join(); // would deadlock if page-2 waited on page-1
    try std.testing.expectEqualStrings("x", log.slice());
}

test "shutdown cancels queued commands and flags the running one" {
    var queue = queue_mod.PageCommandQueue.init(gpa, io);
    defer queue.deinit();
    var log: Log = .{};

    const holder = try queue.acquire("page-1");
    var result: ?anyerror = null;
    const t = try std.Thread.spawn(.{}, worker, .{ &queue, "page-1", 'q', &log, &result });
    try waitForPending(&queue, "page-1", 1);

    queue.shutdown();
    t.join();
    try std.testing.expectEqual(@as(?anyerror, error.Cancelled), result);
    try std.testing.expectEqual(@as(usize, 0), log.len);
    try std.testing.expect(holder.cancelled.load(.acquire));
    queue.release(holder);

    try std.testing.expectError(error.Cancelled, queue.acquire("page-1"));
}

test "acquire reports queue wait in ms (zero when idle)" {
    var queue = queue_mod.PageCommandQueue.init(gpa, io);
    defer queue.deinit();

    const first = try queue.acquire("page-1");
    try std.testing.expectEqual(@as(u64, 0), first.wait_ms);

    const Waiter = struct {
        fn run(q: *queue_mod.PageCommandQueue, out: *u64) void {
            const ticket = q.acquire("page-1") catch return;
            out.* = ticket.wait_ms;
            q.release(ticket);
        }
    };
    var waited: u64 = 0;
    const t = try std.Thread.spawn(.{}, Waiter.run, .{ &queue, &waited });
    try waitForPending(&queue, "page-1", 1);
    io.sleep(.fromMilliseconds(40), .awake) catch {};
    queue.release(first);
    t.join();
    try std.testing.expect(waited >= 30);
}

test "in-flight cancellation stops the retry loop at the next poll" {
    var fake = fakes.FakePagePort.init(gpa);
    defer fake.deinit();
    fake.eval_replies = &.{.{ .json = "{\"ok\":false,\"error\":\"element_not_found\",\"retryable\":true,\"data\":{\"reason\":\"strict_zero\"}}" }};

    const CancellingClock = struct {
        inner: fakes.FakeClock,
        flag: *std.atomic.Value(bool),

        fn clock(self: *@This()) engine.Clock {
            return .{ .ptr = self, .vtable = &.{ .nowMs = nowMs, .sleepMs = sleepMs } };
        }
        fn nowMs(ptr: *anyopaque) u64 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.inner.now_ms;
        }
        fn sleepMs(ptr: *anyopaque, ms: u64) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.inner.now_ms += ms;
            self.inner.sleeps.append(gpa, ms) catch {};
            if (self.inner.sleeps.items.len == 2) self.flag.store(true, .release);
        }
    };
    var flag = std.atomic.Value(bool).init(false);
    var clock = CancellingClock{ .inner = fakes.FakeClock.init(gpa), .flag = &flag };
    defer clock.inner.deinit();

    var eng = engine.Engine.init(fake.port(), clock.clock());
    var command = try router.parse(gpa, "dom.click", "{\"selector\":\"css=#b\"}", .{});
    defer command.deinit();
    var outcome = try eng.executeWith(gpa, &command, .{ .cancel = &flag });
    defer outcome.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32012), outcome.failure.code);
    try std.testing.expectEqual(@as(usize, 2), fake.eval_calls.items.len);
}

test "a command cancelled before it starts never touches the page" {
    var fake = fakes.FakePagePort.init(gpa);
    defer fake.deinit();
    var clock = fakes.FakeClock.init(gpa);
    defer clock.deinit();
    var eng = engine.Engine.init(fake.port(), clock.clock());

    var flag = std.atomic.Value(bool).init(true);
    var command = try router.parse(gpa, "page.url", "{}", .{});
    defer command.deinit();
    var outcome = try eng.executeWith(gpa, &command, .{ .cancel = &flag });
    defer outcome.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32012), outcome.failure.code);
}

test "cancellation interrupts a long inter-character type delay" {
    var fake = fakes.FakePagePort.init(gpa);
    defer fake.deinit();
    fake.eval_replies = &.{.{ .json = "{\"ok\":true,\"value\":{\"ok\":true}}" }};

    const CancellingClock = struct {
        inner: fakes.FakeClock,
        flag: *std.atomic.Value(bool),

        fn clock(self: *@This()) engine.Clock {
            return .{ .ptr = self, .vtable = &.{ .nowMs = nowMs, .sleepMs = sleepMs } };
        }
        fn nowMs(ptr: *anyopaque) u64 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.inner.now_ms;
        }
        fn sleepMs(ptr: *anyopaque, ms: u64) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.inner.now_ms += ms;
            self.inner.sleeps.append(gpa, ms) catch {};
            if (self.inner.sleeps.items.len == 3) self.flag.store(true, .release);
        }
    };
    var flag = std.atomic.Value(bool).init(false);
    var clock = CancellingClock{ .inner = fakes.FakeClock.init(gpa), .flag = &flag };
    defer clock.inner.deinit();

    var eng = engine.Engine.init(fake.port(), clock.clock());
    var command = try router.parse(gpa, "dom.type", "{\"selector\":\"css=#q\",\"text\":\"ab\",\"delay_ms\":3600000,\"options\":{\"timeout_ms\":7200000}}", .{});
    defer command.deinit();
    var outcome = try eng.executeWith(gpa, &command, .{ .cancel = &flag });
    defer outcome.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32012), outcome.failure.code);
    try std.testing.expectEqual(@as(usize, 1), fake.eval_calls.items.len);
    // Slept in bounded slices, stopped right after the cancel.
    try std.testing.expectEqual(@as(usize, 3), clock.inner.sleeps.items.len);
    for (clock.inner.sleeps.items) |ms| try std.testing.expect(ms <= engine.poll_interval_ms);
}
