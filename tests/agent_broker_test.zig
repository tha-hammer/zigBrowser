//! S7a (chat-drawer plan section 10, S7, revs 16.20.30 and 16.20.32): the in-process broker
//! (`automation_server.agent_broker`, src/agent_broker.zig) between a drawer's tool calls and
//! the automation core.
//! - S7.5: before S8 the allowlist is exactly the eight read methods (page.health, page.url,
//!   page.title, dom.query, dom.getText, dom.getAttribute, dom.waitFor, page.screenshot).
//! - S7.2: a call runs on the drawer's own window; a window_id in the model's args is refused
//!   ("window is fixed to this drawer") with no engine call.
//! - S7.3 / S7.8: a tool outside the S7 set is "tool not available", with no engine call.
//! - S7.7: an engine error's data (a cookie canary in it) never reaches the tool result.
//! - The worker rule: `submit` returns at once; the call runs on a worker thread, not the caller's.
//! - The deadline (rev 16.20.32): B = H - min(5, H/4) seconds for the helper's H; each call gets
//!   exactly one result, at B "The browser did not answer in time."; an engine completion after
//!   that is discarded and no job outlives it.
//!
//! The new API is reached through @hasDecl, so this file compiles before the green and fails.
const std = @import("std");
const automation_server = @import("automation_server");
const fake = @import("agent_tools_fake.zig");

const testing = std.testing;
const gpa = testing.allocator;

const broker = if (@hasDecl(automation_server, "agent_broker")) automation_server.agent_broker else struct {};
const has_broker = @hasDecl(broker, "Broker") and @hasDecl(broker, "allowedMethod") and @hasDecl(broker, "deadlineMs");

const prefix = "mcp__zigbrowser__";
const read_methods = [_][]const u8{ "page.health", "page.url", "page.title", "dom.query", "dom.getText", "dom.getAttribute", "dom.waitFor", "page.screenshot" };
const canary = "zb-cookie-canary-5e1f0b";
const Result = if (has_broker) broker.Result else void;

fn allowed(method: []const u8) !bool {
    if (!has_broker) return error.TestNoBroker;
    return broker.allowedMethod(method);
}

fn deadlineMs(helper_s: u32) !u64 {
    if (!has_broker) return error.TestNoBroker;
    return broker.deadlineMs(helper_s);
}

/// The broker's answers, as its sink receives them.
const Answers = struct {
    mutex: std.Io.Mutex = .init,
    list: std.ArrayListUnmanaged(struct { id: []u8, ok: bool, text: []u8, at_ms: i64 }) = .empty,

    fn done(ctx: *anyopaque, id: []const u8, result: Result) void {
        if (!has_broker) return;
        const self: *Answers = @ptrCast(@alignCast(ctx));
        const ok, const text = switch (result) {
            .content => |content| .{ true, content },
            .failure => |message| .{ false, message },
        };
        self.mutex.lockUncancelable(testing.io);
        defer self.mutex.unlock(testing.io);
        self.list.append(gpa, .{ .id = gpa.dupe(u8, id) catch unreachable, .ok = ok, .text = gpa.dupe(u8, text) catch unreachable, .at_ms = fake.nowMs() }) catch unreachable;
    }

    fn count(self: *Answers) usize {
        self.mutex.lockUncancelable(testing.io);
        defer self.mutex.unlock(testing.io);
        return self.list.items.len;
    }

    /// Waits up to `ms` for at least `n` answers.
    fn await(self: *Answers, n: usize, ms: i64) !void {
        const until = fake.nowMs() + ms;
        while (self.count() < n) {
            if (fake.nowMs() > until) return error.TestNoAnswer;
            testing.io.sleep(.fromMilliseconds(5), .awake) catch {};
        }
    }

    fn deinit(self: *Answers) void {
        for (self.list.items) |a| {
            gpa.free(a.id);
            gpa.free(a.text);
        }
        self.list.deinit(gpa);
    }
};

/// A started core with `window` bound to a broker, and its answers.
const Bench = struct {
    f: *fake.Fixture,
    answers: Answers = .{},
    b: if (has_broker) broker.Broker else void,

    fn create(comptime tag: []const u8, window: u32, deadline_ms: u64) !*Bench {
        if (!has_broker) return error.TestNoBroker;
        const self = try gpa.create(Bench);
        errdefer gpa.destroy(self);
        self.* = .{ .f = try fake.Fixture.create(tag, "zb-automation-token-canary-7f3a9c"), .b = undefined };
        try self.f.server.startCore();
        self.b = broker.Broker.init(gpa, &self.f.server, window, deadline_ms);
        return self;
    }

    fn submit(self: *Bench, id: []const u8, tool: []const u8, args_json: []const u8) void {
        if (has_broker) self.b.submit(id, tool, args_json, .{ .ctx = &self.answers, .done = Answers.done });
    }

    fn inFlight(self: *Bench) usize {
        if (!has_broker) return 0;
        return self.b.inFlight();
    }

    fn destroy(self: *Bench) void {
        if (has_broker) self.b.deinit(); // waits for every job
        self.f.destroy();
        self.answers.deinit();
        gpa.destroy(self);
    }
};

test "S7.5 property: the allowlist is exactly the eight read methods" {
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer names.deinit(gpa);
    const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, "tests/fixtures/automation/sdk_wire_cases.json", gpa, .limited(1 << 20));
    defer gpa.free(text);
    const doc = try std.json.parseFromSlice(std.json.Value, gpa, text, .{});
    defer doc.deinit();
    for (doc.value.object.get("cases").?.array.items) |case| try names.append(gpa, case.object.get("method").?.string);
    for ([_][]const u8{
        // the router's table and every special the server routes
        "dom.query",       "dom.click",     "dom.fill",         "dom.type",         "dom.getText",  "dom.getAttribute",
        "dom.waitFor",     "dom.press",     "dom.selectOption", "dom.setInputFiles", "dom.hover",    "dom.scroll",
        "page.navigate",   "page.reload",   "page.url",         "page.title",       "page.evaluate", "page.screenshot",
        "page.list",       "page.close",    "page.health",      "page.recover",     "dialog.get",   "dialog.respond",
        "telemetry.query", "cookies.getAll", "cookies.set",     "cookies.delete",   "cookies.import", "secrets.get",
    }) |name| try names.append(gpa, name);
    // Near misses of the allowed names, seeded.
    var prng = std.Random.DefaultPrng.init(0x57a);
    var spelled: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (spelled.items) |s| gpa.free(s);
        spelled.deinit(gpa);
    }
    for (read_methods) |m| {
        try spelled.append(gpa, try std.fmt.allocPrint(gpa, "{s} ", .{m}));
        try spelled.append(gpa, try std.fmt.allocPrint(gpa, "x{s}", .{m}));
        try spelled.append(gpa, try std.fmt.allocPrint(gpa, "{s}2", .{m}));
        const up = try gpa.dupe(u8, m);
        const i = prng.random().uintLessThan(usize, up.len);
        up[i] = std.ascii.toUpper(up[i]);
        if (std.mem.eql(u8, up, m)) up[i] = '_';
        try spelled.append(gpa, up);
    }
    for (spelled.items) |s| try names.append(gpa, s);
    try names.append(gpa, "");

    var seen_allowed: usize = 0;
    for (names.items) |name| {
        const want = for (read_methods) |m| {
            if (std.mem.eql(u8, m, name)) break true;
        } else false;
        if (try allowed(name) != want) {
            std.debug.print("allowedMethod(\"{s}\") should be {}\n", .{ name, want });
            return error.TestUnexpectedResult;
        }
        if (want) seen_allowed += 1;
    }
    try testing.expect(seen_allowed >= read_methods.len);
}

test "S7.2: a call runs on the drawer's own window, on a worker thread, and submit returns at once" {
    const bench = try Bench.create("own", 2, 30_000);
    defer bench.destroy();
    bench.f.pages.windows[1].delay_ms = 300;
    const before = fake.nowMs();
    bench.submit("c-1", prefix ++ "get_text", "{\"selector\":\"css=#greeting\"}");
    try testing.expect(fake.nowMs() - before < 150);
    try bench.answers.await(1, 10_000);
    const a = bench.answers.list.items[0];
    try testing.expectEqualStrings("c-1", a.id);
    try testing.expect(a.ok);
    try testing.expect(std.mem.indexOf(u8, a.text, "Hello from page 2") != null);
    try testing.expectEqual(@as(u32, 0), bench.f.pages.windows[0].evals.load(.acquire));
    try testing.expect(bench.f.pages.windows[1].eval_thread.load(.acquire) != std.Thread.getCurrentId());
}

test "S7.2: a window_id in the model's args is refused, with no engine call" {
    const bench = try Bench.create("fixed", 2, 30_000);
    defer bench.destroy();
    bench.submit("c-1", prefix ++ "get_text", "{\"selector\":\"css=#greeting\",\"window_id\":\"window-1\"}");
    try bench.answers.await(1, 10_000);
    try testing.expect(!bench.answers.list.items[0].ok);
    try testing.expectEqualStrings("window is fixed to this drawer", bench.answers.list.items[0].text);
    try testing.expectEqual(@as(u32, 0), bench.f.pages.evals());
}

test "S7.3 / S7.8: a tool outside the S7 set is not available, with no engine call" {
    const bench = try Bench.create("refused", 1, 30_000);
    defer bench.destroy();
    const tools = [_][]const u8{
        prefix ++ "evaluate", prefix ++ "cookies_get", prefix ++ "secrets_get", prefix ++ "set_pacing",
        prefix ++ "click",    prefix ++ "navigate",    prefix ++ "hover",       prefix ++ "scroll",
        prefix ++ "type",     "get_text",              "mcp__other__get_text",  "",
    };
    for (tools, 0..) |tool, i| {
        var id: [8]u8 = undefined;
        bench.submit(try std.fmt.bufPrint(&id, "c-{d}", .{i}), tool, "{\"selector\":\"css=#greeting\",\"expression\":\"document.cookie\"}");
    }
    try bench.answers.await(tools.len, 10_000);
    for (bench.answers.list.items) |a| {
        try testing.expect(!a.ok);
        try testing.expectEqualStrings("tool not available", a.text);
    }
    try testing.expectEqual(@as(u32, 0), bench.f.pages.evals());
}

test "S7.7: an engine error's data never reaches the tool result" {
    // The engine keeps an exception's `name` in its error data (engine.exceptionData), so the
    // canary rides there; only the broker's own redaction keeps it out of the result.
    const bench = try Bench.create("redact", 1, 30_000);
    defer bench.destroy();
    bench.f.pages.windows[0].reply = "{\"ok\":false,\"error\":\"script_exception\",\"retryable\":false,\"data\":{\"reason\":\"script_exception\",\"name\":\"" ++ canary ++ "\",\"message\":\"" ++ canary ++ "\"}}";
    bench.submit("c-1", prefix ++ "get_text", "{\"selector\":\"css=#" ++ canary ++ "\"}");
    try bench.answers.await(1, 10_000);
    const a = bench.answers.list.items[0];
    try testing.expect(!a.ok);
    try testing.expect(a.text.len > 0);
    try testing.expect(std.mem.indexOf(u8, a.text, canary) == null);
}

test "the deadline formula: B = H - min(5, H/4) seconds, below H at every H from 1 to 120" {
    try testing.expectEqual(@as(u64, 750), try deadlineMs(1));
    try testing.expectEqual(@as(u64, 115_000), try deadlineMs(120));
    var h: u32 = 1;
    while (h <= 120) : (h += 1) {
        const b = try deadlineMs(h);
        try testing.expect(b > 0 and b < @as(u64, h) * 1000);
        try testing.expectEqual(@as(u64, h) * 1000 - @min(5000, @as(u64, h) * 250), b);
    }
}

test "timeout ownership: one result at B, a late engine completion discarded, no job left" {
    const b_ms = try deadlineMs(1); // 750 ms
    const bench = try Bench.create("deadline", 1, b_ms);
    defer bench.destroy();
    bench.f.pages.windows[0].delay_ms = 2500;
    const sent = fake.nowMs();
    bench.submit("c-1", prefix ++ "get_text", "{\"selector\":\"css=#greeting\"}");
    try bench.answers.await(1, 5_000);
    const a = bench.answers.list.items[0];
    try testing.expect(!a.ok);
    try testing.expectEqualStrings("The browser did not answer in time.", a.text);
    try testing.expect(a.at_ms - sent >= 700 and a.at_ms - sent < 1500);
    // The engine finishes at about 2.5 s: its completion is discarded.
    const until = fake.nowMs() + 5_000;
    while (bench.inFlight() > 0) {
        if (fake.nowMs() > until) return error.TestJobLeft;
        testing.io.sleep(.fromMilliseconds(20), .awake) catch {};
    }
    try testing.expectEqual(@as(u32, 1), bench.f.pages.windows[0].evals.load(.acquire));
    try testing.expectEqual(@as(usize, 1), bench.answers.count());
}

/// Waits up to `ms` until `counter` reaches `n`.
fn waitFor(counter: *std.atomic.Value(u32), n: u32, ms: i64) !void {
    const until = fake.nowMs() + ms;
    while (counter.load(.acquire) < n) {
        if (fake.nowMs() > until) return error.TestNotReached;
        testing.io.sleep(.fromMilliseconds(2), .awake) catch {};
    }
}

fn sleepMs(ms: u64) void {
    testing.io.sleep(.fromMilliseconds(@intCast(ms)), .awake) catch {};
}

test "D8 (RoseCat 6566): one call in flight per session; B waits while A runs; answers keep their ids" {
    const bench = try Bench.create("serial", 1, 30_000);
    defer bench.destroy();
    const w = &bench.f.pages.windows[0];
    w.hold.store(true, .release);
    bench.submit("c-A", prefix ++ "get_text", "{\"selector\":\"css=#a\"}");
    try waitFor(&w.in_flight, 1, 5_000); // A is in the engine
    bench.submit("c-B", prefix ++ "get_attribute", "{\"selector\":\"css=#b\",\"name\":\"href\"}");
    sleepMs(300);
    try testing.expectEqual(@as(u32, 1), w.in_flight.load(.acquire));
    try testing.expectEqual(@as(usize, 0), bench.answers.count());
    w.hold.store(false, .release);
    try bench.answers.await(2, 10_000);
    try testing.expectEqual(@as(u32, 1), w.max_in_flight.load(.acquire));
    try testing.expectEqual(@as(u32, 2), w.evals.load(.acquire));
    try testing.expectEqualStrings("c-A", bench.answers.list.items[0].id);
    try testing.expectEqualStrings("c-B", bench.answers.list.items[1].id);
    for (bench.answers.list.items) |a| try testing.expect(a.ok);
}

test "D8: another drawer's broker makes progress while this one's call is held" {
    if (!has_broker) return error.TestNoBroker;
    const bench = try Bench.create("independent", 1, 30_000);
    defer bench.destroy();
    const w = &bench.f.pages.windows[0];
    w.hold.store(true, .release);
    defer w.hold.store(false, .release);
    bench.submit("c-1", prefix ++ "get_text", "{\"selector\":\"css=#greeting\"}");
    try waitFor(&w.in_flight, 1, 5_000);
    var other_answers: Answers = .{};
    defer other_answers.deinit();
    var other = broker.Broker.init(gpa, &bench.f.server, 2, 30_000);
    defer other.deinit();
    other.submit("c-2", prefix ++ "get_text", "{\"selector\":\"css=#greeting\"}", .{ .ctx = &other_answers, .done = Answers.done });
    try other_answers.await(1, 5_000);
    try testing.expect(other_answers.list.items[0].ok);
    try testing.expect(std.mem.indexOf(u8, other_answers.list.items[0].text, "Hello from page 2") != null);
    try testing.expectEqual(@as(usize, 0), bench.answers.count()); // c-1 is still held
    w.hold.store(false, .release);
    try bench.answers.await(1, 10_000);
}

test "D8: a call queued past its deadline is answered then and never runs" {
    const b_ms = try deadlineMs(1); // 750 ms
    const bench = try Bench.create("queued", 1, b_ms);
    defer bench.destroy();
    const w = &bench.f.pages.windows[0];
    w.hold.store(true, .release);
    bench.submit("c-A", prefix ++ "get_text", "{\"selector\":\"css=#a\"}");
    try waitFor(&w.in_flight, 1, 5_000);
    const queued_at = fake.nowMs();
    bench.submit("c-B", prefix ++ "get_text", "{\"selector\":\"css=#b\"}");
    try bench.answers.await(2, 5_000); // both at their deadlines
    for (bench.answers.list.items) |a| {
        try testing.expect(!a.ok);
        try testing.expectEqualStrings("The browser did not answer in time.", a.text);
    }
    try testing.expect(bench.answers.list.items[1].at_ms - queued_at < 1500);
    w.hold.store(false, .release);
    const until = fake.nowMs() + 5_000;
    while (bench.inFlight() > 0) {
        if (fake.nowMs() > until) return error.TestJobLeft;
        sleepMs(20);
    }
    sleepMs(200);
    try testing.expectEqual(@as(u32, 1), w.evals.load(.acquire)); // B never entered the engine
    try testing.expectEqual(@as(usize, 2), bench.answers.count());
}

/// This process's threads now (Linux: /proc/self/task).
fn threadCount() !usize {
    var dir = try std.Io.Dir.cwd().openDir(testing.io, "/proc/self/task", .{ .iterate = true });
    defer dir.close(testing.io);
    var it = dir.iterate();
    var n: usize = 0;
    while (try it.next(testing.io)) |_| n += 1;
    return n;
}

test "D8: a session's queued calls take no thread of their own (one worker per session)" {
    const bench = try Bench.create("threads", 1, 30_000);
    defer bench.destroy();
    const w = &bench.f.pages.windows[0];
    w.hold.store(true, .release);
    defer w.hold.store(false, .release);
    bench.submit("c-0", prefix ++ "get_text", "{\"selector\":\"css=#a\"}");
    try waitFor(&w.in_flight, 1, 5_000);
    const before = try threadCount();
    var i: usize = 1;
    while (i <= 20) : (i += 1) {
        var id: [8]u8 = undefined;
        bench.submit(try std.fmt.bufPrint(&id, "c-{d}", .{i}), prefix ++ "get_text", "{\"selector\":\"css=#a\"}");
    }
    sleepMs(200);
    const after = try threadCount();
    if (after > before + 2) {
        std.debug.print("20 queued calls took {d} more threads\n", .{after - before});
        return error.TestUnexpectedResult;
    }
    try testing.expectEqual(@as(u32, 1), w.max_in_flight.load(.acquire));
    w.hold.store(false, .release);
    try bench.answers.await(21, 20_000);
    for (bench.answers.list.items, 0..) |a, k| {
        var id: [8]u8 = undefined;
        try testing.expectEqualStrings(try std.fmt.bufPrint(&id, "c-{d}", .{k}), a.id); // in order
    }
}
