//! S8 red (chat-drawer plan decision 16, part 4; RoseCat f87368e on ebe6529, findings 1-3): a
//! navigate or reload card is bound to its prompt and to the document it describes, and a
//! stop that comes after the card was looked at still wins at the dispatch boundary.
//! - **Phase A (decisions 1 and 9; S8a's options.expect).** Before a card is presented the
//!   broker reads the bound window from the engine (`page.list`): its page's origin (the
//!   engine's own `originOf`) and its `load_serial`. They are the card's (`CardView.origin`,
//!   `CardView.load_serial`), and the approved dispatch carries them as `options.expect`, so
//!   the engine refuses it (-32015, inside its own ticket) if the document changed meanwhile:
//!   `{"url":...,"window_id":"window-N","options":{"expect":{"origin":...,"load_serial":N}}}`.
//!   A window the engine does not list, or one that crashed, gets no card and no dispatch.
//! - **The refusal's ending.** A -32015 answer ends the card `changed`, or `crashed` when the
//!   engine's reason is `crashed` (D7b's outcomes); the model gets the call's failure.
//! - **Prompt binding (decision 8; RoseCat 7802).** A call carries its validated tool_call's
//!   `prompt_id` (`Broker.submitPrompt`); `Broker.promptOver(prompt_id)` ends exactly that
//!   prompt (the app calls it with the id of the prompt its result, its error or its Stop
//!   ends). Its waiting cards end `revoked` and are cancelled in the core; its approved calls
//!   not yet dispatched are revoked too. Another prompt's calls are never touched: an end for an
//!   earlier prompt, or a late or duplicate end for N once N+1 runs, revokes nothing of N+1
//!   and never releases N's card. A call with no prompt (`submit`) belongs to none.
//! - **The dispatch boundary (finding 3).** After the worker saw the card approved, it checks
//!   again, under the broker's mutex, that the broker is live and the prompt not over, before
//!   the engine call. `Broker.before_dispatch` (test seam; production sets none) holds it
//!   between the two, so a red can let a detach or a prompt's end win there: revoked, the
//!   engine never asked to navigate.
//!
//! On HEAD there is no `submitPrompt`, `promptOver`, `before_dispatch` or `CardView.origin`: this file does not
//! compile there (the red). Unregistered until its green.

const std = @import("std");
const automation_server = @import("automation_server");
const fake = @import("agent_tools_fake.zig");

const testing = std.testing;
const gpa = testing.allocator;

const broker = automation_server.agent_broker;
const approval = broker.approval;

const navigate_tool = "mcp__zigbrowser__navigate";
const reload_tool = "mcp__zigbrowser__reload";
const navigate_args = "{\"url\":\"https://example.com/next\"}";
const listed = "{\"result\":{\"pages\":[{\"window_id\":\"window-1\",\"url\":\"https://main.example/\",\"title\":\"m\",\"primary\":true,\"load_serial\":1}," ++
    "{\"window_id\":\"window-2\",\"url\":\"HTTPS://User@Shop.Example:8443/a/b?q=1#f\",\"title\":\"a\",\"primary\":false,\"opener_window_id\":\"window-1\",\"load_serial\":5}]}}";
const expect_json = "\"options\":{\"expect\":{\"origin\":\"https://shop.example:8443\",\"load_serial\":5}}";
const navigate_params = "{\"url\":\"https://example.com/next\",\"window_id\":\"window-2\"," ++ expect_json ++ "}";
const reload_params = "{\"window_id\":\"window-2\"," ++ expect_json ++ "}";
const engine_ok = "{\"result\":{\"ok\":true}}";

/// The scripted engine: `page.list` answers `list`, every other method `reply`.
const Engine = struct {
    mutex: std.Io.Mutex = .init,
    list: []const u8 = listed,
    reply: []const u8 = engine_ok,
    methods: [8][32]u8 = undefined,
    params: [8][256]u8 = undefined,
    lens: [8][2]usize = undefined,
    n: usize = 0,

    fn call(ctx: *anyopaque, a: std.mem.Allocator, called: []const u8, with: []const u8) error{OutOfMemory}![]u8 {
        const self: *Engine = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(testing.io);
        defer self.mutex.unlock(testing.io);
        if (self.n < self.methods.len) {
            const m = @min(called.len, 32);
            const p = @min(with.len, 256);
            @memcpy(self.methods[self.n][0..m], called[0..m]);
            @memcpy(self.params[self.n][0..p], with[0..p]);
            self.lens[self.n] = .{ m, p };
        }
        self.n += 1;
        return a.dupe(u8, if (std.mem.eql(u8, called, "page.list")) self.list else self.reply);
    }
    fn method(self: *Engine, i: usize) []const u8 {
        return self.methods[i][0..self.lens[i][0]];
    }
    fn param(self: *Engine, i: usize) []const u8 {
        return self.params[i][0..self.lens[i][1]];
    }
    /// How many calls asked the page to change (anything but `page.list`).
    fn dispatches(self: *Engine) usize {
        self.mutex.lockUncancelable(testing.io);
        defer self.mutex.unlock(testing.io);
        var n: usize = 0;
        for (0..@min(self.n, self.methods.len)) |i| n += @intFromBool(!std.mem.eql(u8, self.method(i), "page.list"));
        return n;
    }
};

const Answer = struct {
    n: std.atomic.Value(u32) = .init(0),
    ok: bool = false,

    fn done(ctx: *anyopaque, _: []const u8, result: broker.Result) void {
        const self: *Answer = @ptrCast(@alignCast(ctx));
        self.ok = result == .content;
        _ = self.n.fetchAdd(1, .release);
    }
    fn wait(self: *Answer) !void {
        const until = fake.nowMs() + 10_000;
        while (self.n.load(.acquire) == 0) {
            if (fake.nowMs() > until) return error.TestNoAnswer;
            testing.io.sleep(.fromMilliseconds(5), .awake) catch {};
        }
    }
};

const App = struct {
    mutex: std.Io.Mutex = .init,
    shown: usize = 0,
    origin: [64]u8 = undefined,
    origin_len: usize = 0,
    load_serial: u64 = 0,
    params: [256]u8 = undefined,
    params_len: usize = 0,
    endings: [4]broker.Ending = undefined,
    ended_n: usize = 0,

    fn readSelector(_: *anyopaque) approval.StoreRead {
        return .{ .selector = .yes };
    }
    fn facts(_: *anyopaque) approval.RunFacts {
        return .{ .drawer_showing = false, .typed_prompt = true };
    }
    fn notify(_: *anyopaque) void {}
    fn reportUnreadable(_: *anyopaque) void {}
    fn show(ctx: *anyopaque, card: broker.CardView) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(testing.io);
        defer self.mutex.unlock(testing.io);
        self.shown += 1;
        self.origin_len = @min(card.origin.len, self.origin.len);
        @memcpy(self.origin[0..self.origin_len], card.origin[0..self.origin_len]);
        self.load_serial = card.load_serial;
        self.params_len = @min(card.params.len, self.params.len);
        @memcpy(self.params[0..self.params_len], card.params[0..self.params_len]);
    }
    fn ended(ctx: *anyopaque, _: approval.CardId, ending: broker.Ending) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(testing.io);
        defer self.mutex.unlock(testing.io);
        if (self.ended_n < self.endings.len) self.endings[self.ended_n] = ending;
        self.ended_n += 1;
    }
    fn endedCount(self: *App) usize {
        self.mutex.lockUncancelable(testing.io);
        defer self.mutex.unlock(testing.io);
        return self.ended_n;
    }
};

const Clock = struct {
    fn now(_: *anyopaque) u64 {
        return 1_000;
    }
};

/// Holds the worker inside a hook once armed, until released.
const Hold = struct {
    armed: std.atomic.Value(bool) = .init(false),
    held: std.atomic.Value(bool) = .init(false),
    released: std.atomic.Value(bool) = .init(false),

    fn run(ctx: *anyopaque) void {
        const self: *Hold = @ptrCast(@alignCast(ctx));
        if (!self.armed.load(.acquire) or self.released.load(.acquire)) return;
        self.held.store(true, .release);
        const until = fake.nowMs() + 10_000;
        while (!self.released.load(.acquire) and fake.nowMs() < until) testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    fn waitHeld(self: *Hold) !void {
        const until = fake.nowMs() + 10_000;
        while (!self.held.load(.acquire)) {
            if (fake.nowMs() > until) return error.TestWorkerNotHeld;
            testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
        }
    }
};

const Rig = struct {
    f: *fake.Fixture,
    b: *broker.Broker,
    reaper: broker.Reaper,
    engine: Engine = .{},
    app: App = .{},
    clock: u8 = 0,
    cards: approval.Cards,
    detached: bool = false,

    fn create() !*Rig {
        const self = try gpa.create(Rig);
        errdefer gpa.destroy(self);
        self.* = .{ .f = try fake.Fixture.create("navbind", "zb-automation-token-canary-7f3a9c"), .b = undefined, .reaper = .init(gpa), .cards = undefined };
        try self.f.server.startCore();
        self.b = try broker.Broker.create(gpa, &self.f.server, 2, 30_000);
        self.b.engine = .{ .ctx = &self.engine, .call = Engine.call };
        self.cards = approval.Cards.init(gpa, .{ .ctx = &self.clock, .now_ms = Clock.now });
        self.b.approval = .{
            .ctx = &self.app,
            .cards = &self.cards,
            .read_selector = App.readSelector,
            .facts = App.facts,
            .notify = App.notify,
            .report_unreadable = App.reportUnreadable,
            .show = App.show,
            .ended = App.ended,
        };
        self.cards.windowOpened(1);
        self.cards.windowOpened(2);
        return self;
    }
    fn detach(self: *Rig) void {
        if (self.detached) return;
        self.detached = true;
        self.b.detach(&self.reaper);
    }
    fn destroy(self: *Rig) void {
        self.detach();
        self.reaper.deinit();
        self.cards.deinit();
        self.f.destroy();
        gpa.destroy(self);
    }
    fn submit(self: *Rig, tool: []const u8, args: []const u8, answer: *Answer) void {
        self.b.submit("c-1", tool, args, .{ .ctx = answer, .done = Answer.done });
    }
    fn submitIn(self: *Rig, prompt_id: i64, tool: []const u8, args: []const u8, answer: *Answer) void {
        self.b.submitPrompt(prompt_id, "c-1", tool, args, .{ .ctx = answer, .done = Answer.done });
    }
    fn waitCard(self: *Rig, id: approval.CardId) !void {
        const until = fake.nowMs() + 10_000;
        while (true) {
            if (self.cards.outcome(id)) |o| if (o == .waiting) return;
            if (fake.nowMs() > until) return error.TestNoCard;
            testing.io.sleep(.fromMilliseconds(5), .awake) catch {};
        }
    }
    fn waitEnded(self: *Rig, n: usize) !void {
        const until = fake.nowMs() + 10_000;
        while (self.app.endedCount() < n) {
            if (fake.nowMs() > until) return error.TestNotEnded;
            testing.io.sleep(.fromMilliseconds(5), .awake) catch {};
        }
    }
};

fn settle() void {
    testing.io.sleep(.fromMilliseconds(100), .awake) catch {};
}

test "phase A: the card holds the bound window's origin and load_serial, and the dispatch expects them" {
    for ([_]struct { tool: []const u8, args: []const u8, method: []const u8, params: []const u8 }{
        .{ .tool = navigate_tool, .args = navigate_args, .method = "page.navigate", .params = navigate_params },
        .{ .tool = reload_tool, .args = "{}", .method = "page.reload", .params = reload_params },
    }) |row| {
        const r = try Rig.create();
        defer r.destroy();
        var a: Answer = .{};
        r.submit(row.tool, row.args, &a);
        try r.waitCard(1);
        try testing.expectEqual(@as(usize, 1), r.app.shown);
        try testing.expectEqualStrings("https://shop.example:8443", r.app.origin[0..r.app.origin_len]);
        try testing.expectEqual(@as(u64, 5), r.app.load_serial);
        try testing.expectEqualStrings(row.params, r.app.params[0..r.app.params_len]);
        try testing.expectEqual(@as(usize, 0), r.engine.dispatches());
        try testing.expect(r.cards.approve(1));
        try a.wait();
        try testing.expect(a.ok);
        try r.waitEnded(1);
        try testing.expectEqual(@as(usize, 2), r.engine.n);
        try testing.expectEqualStrings("page.list", r.engine.method(0));
        try testing.expectEqualStrings(row.method, r.engine.method(1));
        try testing.expectEqualStrings(row.params, r.engine.param(1));
        try testing.expectEqual(broker.Ending.done, r.app.endings[0]);
    }
}

test "phase A: a window the engine does not list, or one that crashed, gets no card and no dispatch" {
    for ([_][]const u8{
        "{\"result\":{\"pages\":[{\"window_id\":\"window-1\",\"url\":\"https://main.example/\",\"title\":\"m\",\"primary\":true,\"load_serial\":1}]}}",
        "{\"result\":{\"pages\":[{\"window_id\":\"window-2\",\"url\":\"https://shop.example/\",\"title\":\"a\",\"primary\":false,\"load_serial\":5,\"crashed\":\"crashed\"}]}}",
        "{\"error\":{\"code\":-32603,\"message\":\"Internal error\"}}",
        "{\"result\":{\"pages\":[{\"window_id\":\"window-2\",\"url\":\"https://shop.example/\",\"title\":\"a\",\"primary\":false}]}}",
    }) |list| {
        const r = try Rig.create();
        defer r.destroy();
        r.engine.list = list;
        var a: Answer = .{};
        r.submit(navigate_tool, navigate_args, &a);
        try a.wait();
        try testing.expect(!a.ok);
        settle();
        try testing.expectEqual(@as(usize, 0), r.app.shown);
        try testing.expectEqual(@as(?approval.Outcome, null), r.cards.outcome(1));
        try testing.expectEqual(@as(usize, 0), r.engine.dispatches());
    }
}

test "the engine refuses a changed document: ended changed (crashed when its reason is crashed), the model told" {
    for ([_]struct { reply: []const u8, ending: broker.Ending }{
        .{ .reply = "{\"error\":{\"code\":-32015,\"message\":\"expectation_mismatch\",\"data\":{\"reason\":\"load_serial_changed\"}}}", .ending = .changed },
        .{ .reply = "{\"error\":{\"code\":-32015,\"message\":\"expectation_mismatch\",\"data\":{\"reason\":\"origin_changed\"}}}", .ending = .changed },
        .{ .reply = "{\"error\":{\"code\":-32015,\"message\":\"expectation_mismatch\",\"data\":{\"reason\":\"crashed\"}}}", .ending = .crashed },
        .{ .reply = "{\"error\":{\"code\":-32001,\"message\":\"element_not_found\"}}", .ending = .failed },
    }) |row| {
        const r = try Rig.create();
        defer r.destroy();
        r.engine.reply = row.reply;
        var a: Answer = .{};
        r.submit(navigate_tool, navigate_args, &a);
        try r.waitCard(1);
        try testing.expect(r.cards.approve(1));
        try a.wait();
        try testing.expect(!a.ok);
        try r.waitEnded(1);
        settle();
        try testing.expectEqual(@as(usize, 1), r.app.ended_n);
        try testing.expectEqual(row.ending, r.app.endings[0]);
    }
}

test "prompt 7's end revokes its waiting card: cancelled in the core, nothing dispatched; a later Approve is false" {
    const r = try Rig.create();
    defer r.destroy();
    var a: Answer = .{};
    r.submitIn(7, navigate_tool, navigate_args, &a);
    try r.waitCard(1);
    r.b.promptOver(7);
    try r.waitEnded(1);
    try testing.expectEqual(broker.Ending.revoked, r.app.endings[0]);
    try testing.expectEqual(approval.Outcome.cancelled, r.cards.outcome(1).?);
    try testing.expect(!r.cards.approve(1));
    try a.wait();
    try testing.expect(!a.ok);
    settle();
    try testing.expectEqual(@as(usize, 0), r.engine.dispatches());
    try testing.expectEqual(@as(usize, 1), r.app.ended_n);
}

test "an end for another prompt revokes nothing: prompt 7's card waits through ends of 6 and 8, then runs" {
    const r = try Rig.create();
    defer r.destroy();
    var a: Answer = .{};
    r.submitIn(7, navigate_tool, navigate_args, &a);
    try r.waitCard(1);
    r.b.promptOver(6);
    r.b.promptOver(8);
    settle();
    try testing.expectEqual(approval.Outcome.waiting, r.cards.outcome(1).?);
    try testing.expectEqual(@as(usize, 0), r.app.endedCount());
    try testing.expect(r.cards.approve(1));
    try a.wait();
    try testing.expect(a.ok);
    try r.waitEnded(1);
    try testing.expectEqual(broker.Ending.done, r.app.endings[0]);
    try testing.expectEqual(@as(usize, 1), r.engine.dispatches());
}

test "a late or duplicate end for prompt 7 once prompt 8 runs: 8's card waits on, 7's stays revoked, only 8 dispatches" {
    const r = try Rig.create();
    defer r.destroy();
    var a: Answer = .{};
    r.submitIn(7, navigate_tool, navigate_args, &a);
    try r.waitCard(1);
    r.b.promptOver(7);
    try r.waitEnded(1);
    try a.wait();
    var b: Answer = .{};
    r.submitIn(8, reload_tool, "{}", &b);
    try r.waitCard(2);
    r.b.promptOver(7); // late
    r.b.promptOver(7); // and again
    settle();
    try testing.expectEqual(approval.Outcome.waiting, r.cards.outcome(2).?);
    try testing.expectEqual(approval.Outcome.cancelled, r.cards.outcome(1).?);
    try testing.expect(!r.cards.approve(1));
    try testing.expectEqual(@as(usize, 1), r.app.endedCount());
    try testing.expect(r.cards.approve(2));
    try b.wait();
    try testing.expect(b.ok);
    try r.waitEnded(2);
    try testing.expectEqual(broker.Ending.done, r.app.endings[1]);
    try testing.expectEqual(@as(usize, 1), r.engine.dispatches());
    try testing.expectEqualStrings("page.reload", r.engine.method(r.engine.n - 1));
}

test "Approve won, then prompt 7 ended before the dispatch (held at before_dispatch): revoked, nothing dispatched" {
    const r = try Rig.create();
    defer r.destroy();
    var hold: Hold = .{};
    hold.armed.store(true, .release);
    r.b.before_dispatch = .{ .ctx = &hold, .run = Hold.run };
    var a: Answer = .{};
    r.submitIn(7, navigate_tool, navigate_args, &a);
    try r.waitCard(1);
    try testing.expect(r.cards.approve(1));
    try hold.waitHeld();
    r.b.promptOver(7);
    hold.released.store(true, .release);
    try r.waitEnded(1);
    try a.wait();
    settle();
    try testing.expect(!a.ok);
    try testing.expectEqual(broker.Ending.revoked, r.app.endings[0]);
    try testing.expectEqual(@as(usize, 0), r.engine.dispatches());
}

test "Approve won, then another prompt ended before the dispatch (held at before_dispatch): prompt 7's call runs" {
    const r = try Rig.create();
    defer r.destroy();
    var hold: Hold = .{};
    hold.armed.store(true, .release);
    r.b.before_dispatch = .{ .ctx = &hold, .run = Hold.run };
    var a: Answer = .{};
    r.submitIn(7, navigate_tool, navigate_args, &a);
    try r.waitCard(1);
    try testing.expect(r.cards.approve(1));
    try hold.waitHeld();
    r.b.promptOver(6);
    hold.released.store(true, .release);
    try a.wait();
    try testing.expect(a.ok);
    try r.waitEnded(1);
    try testing.expectEqual(broker.Ending.done, r.app.endings[0]);
    try testing.expectEqual(@as(usize, 1), r.engine.dispatches());
}

test "Approve won, then the bound window's broker detached before the dispatch (held at before_dispatch): revoked, nothing dispatched" {
    const r = try Rig.create();
    defer r.destroy();
    var hold: Hold = .{};
    hold.armed.store(true, .release);
    r.b.before_dispatch = .{ .ctx = &hold, .run = Hold.run };
    var a: Answer = .{};
    r.submit(navigate_tool, navigate_args, &a);
    try r.waitCard(1);
    try testing.expect(r.cards.approve(1));
    try hold.waitHeld();
    r.detach();
    hold.released.store(true, .release);
    try r.waitEnded(1);
    settle();
    try testing.expectEqual(broker.Ending.revoked, r.app.endings[0]);
    try testing.expectEqual(@as(usize, 0), r.engine.dispatches());
    try testing.expectEqual(@as(u32, 0), a.n.load(.acquire));
}
