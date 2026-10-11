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

test "N23: a page's queue line goes when its last command releases, so arbitrary page ids never accumulate" {
    var queue = queue_mod.PageCommandQueue.init(gpa, io);
    defer queue.deinit();
    var name_buf: [32]u8 = undefined;
    for (0..500) |i| {
        const page = try std.fmt.bufPrint(&name_buf, "page-{d}", .{4_000_000_000 + i});
        const ticket = try queue.acquire(page);
        queue.release(ticket);
    }
    try std.testing.expectEqual(@as(usize, 0), queue.lineCount());

    // A line with a queued command survives until that one releases too.
    const running = try queue.acquire("page-2");
    try std.testing.expectEqual(@as(usize, 1), queue.lineCount());
    queue.release(running);
    try std.testing.expectEqual(@as(usize, 0), queue.lineCount());
}

test "N23: an acquire that runs out of memory leaves no empty queue line behind (RoseCat 4840)" {
    var fail_index: usize = 0;
    while (fail_index < 16) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
        var queue = queue_mod.PageCommandQueue.init(failing.allocator(), io);
        defer queue.deinit();
        const ticket = queue.acquire("page-4000000001") catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(@as(usize, 0), queue.lineCount());
            continue;
        };
        queue.release(ticket);
        try std.testing.expectEqual(@as(usize, 0), queue.lineCount());
    }
}

test "watchdog: recovery ends a page's queued commands as cancelled at once, flags the running one, and refuses new ones until it ends" {
    var queue = queue_mod.PageCommandQueue.init(gpa, io);
    defer queue.deinit();
    var log: Log = .{};

    const holder = try queue.acquire("window-1");
    const other = try queue.acquire("window-3");
    var result: ?anyerror = null;
    const t = try std.Thread.spawn(.{}, worker, .{ &queue, "window-1", 'q', &log, &result });
    try waitForPending(&queue, "window-1", 1);

    try queue.beginRecovery(&.{ "window-1", "window-2" });
    t.join();
    // The queued command never ran; the running one is flagged; the page
    // that is not recovering is untouched.
    try std.testing.expectEqual(@as(?anyerror, error.Cancelled), result);
    try std.testing.expectEqual(@as(usize, 0), log.len);
    try std.testing.expect(holder.cancelled.load(.acquire));
    try std.testing.expect(!other.cancelled.load(.acquire));
    // New commands for a recovering page are refused, other pages work.
    try std.testing.expectError(error.Recovering, queue.acquire("window-1"));
    try std.testing.expectError(error.Recovering, queue.acquire("window-2"));
    const third = try queue.acquire("window-4");
    queue.release(third);
    // One recovery at a time per page.
    try std.testing.expectError(error.Recovering, queue.beginRecovery(&.{"window-2"}));
    try std.testing.expect(queue.isRecovering("window-1"));

    queue.endRecovery(&.{ "window-1", "window-2" });
    try std.testing.expect(!queue.isRecovering("window-1"));
    queue.release(holder);
    queue.release(other);
    // After it: a fresh command runs and is not cancelled.
    const fresh = try queue.acquire("window-1");
    try std.testing.expect(!fresh.cancelled.load(.acquire));
    queue.release(fresh);
}

test "watchdog: a command whose page call fails after it was cancelled reports -32012 cancelled, not the call's own error" {
    // page.recover cancels the command a frozen page holds; ending the web
    // process then makes its page call fail. Its one reply says cancelled.
    const page_port = automation.page_port;
    const Cut = struct {
        flag: *std.atomic.Value(bool),

        fn port(self: *@This()) page_port.PagePort {
            return .{ .ptr = self, .vtable = &.{ .evalJson = evalJson, .navigate = navigate, .reload = reload, .url = url, .title = title } };
        }
        fn evalJson(_: *anyopaque, _: std.mem.Allocator, _: page_port.World, _: []const u8, _: []const u8, _: u64) page_port.PortError![]u8 {
            return error.EvalFailed;
        }
        fn navigate(_: *anyopaque, _: []const u8, _: u64) page_port.PortError!void {
            return error.EvalFailed;
        }
        fn reload(_: *anyopaque, _: u64) page_port.PortError!void {
            return error.EvalFailed;
        }
        fn url(ptr: *anyopaque, _: std.mem.Allocator, _: u64) page_port.PortError![]u8 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.flag.store(true, .release); // cancelled while the call runs
            return error.EvalFailed;
        }
        fn title(_: *anyopaque, _: std.mem.Allocator, _: u64) page_port.PortError![]u8 {
            return error.Timeout;
        }
    };
    var flag = std.atomic.Value(bool).init(false);
    var cut = Cut{ .flag = &flag };
    var clock = fakes.FakeClock.init(gpa);
    defer clock.deinit();
    var eng = engine.Engine.init(cut.port(), clock.clock());

    var command = try router.parse(gpa, "page.url", "{}", .{});
    defer command.deinit();
    var outcome = try eng.executeWith(gpa, &command, .{ .cancel = &flag });
    defer outcome.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32012), outcome.failure.code);

    // Without a cancellation the call's own error is reported as before.
    var calm = std.atomic.Value(bool).init(false);
    var title_command = try router.parse(gpa, "page.title", "{}", .{});
    defer title_command.deinit();
    var timed_out = try eng.executeWith(gpa, &title_command, .{ .cancel = &calm });
    defer timed_out.deinit(gpa);
    try std.testing.expect(timed_out.failure.code != -32012);
}

test "watchdog: a recovery that runs out of memory changes nothing (RoseCat 5187)" {
    var failing = std.testing.FailingAllocator.init(gpa, .{});
    var queue = queue_mod.PageCommandQueue.init(failing.allocator(), io);
    defer queue.deinit();
    var log: Log = .{};

    const holder = try queue.acquire("window-1");
    var result: ?anyerror = null;
    const t = try std.Thread.spawn(.{}, worker, .{ &queue, "window-1", 'q', &log, &result });
    try waitForPending(&queue, "window-1", 1);

    // Each allocation of a recovery in turn fails: the key list, the first
    // key, the second key, the map's room.
    var nth: usize = 0;
    while (nth < 4) : (nth += 1) {
        failing.fail_index = failing.alloc_index + nth;
        try std.testing.expectError(error.OutOfMemory, queue.beginRecovery(&.{ "window-1", "window-2" }));
        failing.fail_index = std.math.maxInt(usize);
        try std.testing.expect(!queue.isRecovering("window-1"));
        try std.testing.expect(!queue.isRecovering("window-2"));
        try std.testing.expect(!holder.cancelled.load(.acquire));
        try std.testing.expectEqual(@as(usize, 1), queue.pendingCount("window-1"));
    }

    // Nothing was cancelled: the queued command runs as usual, and every
    // page still takes commands.
    queue.release(holder);
    t.join();
    try std.testing.expect(result == null);
    try std.testing.expectEqualStrings("q", log.slice());
    const other = try queue.acquire("window-2");
    queue.release(other);
    // Once memory is there, the same recovery works.
    try queue.beginRecovery(&.{ "window-1", "window-2" });
    try std.testing.expect(queue.isRecovering("window-2"));
    queue.endRecovery(&.{ "window-1", "window-2" });
}
