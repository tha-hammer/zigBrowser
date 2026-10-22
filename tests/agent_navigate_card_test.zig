//! S8 red (chat-drawer plan decision 16, part 3; S8c/S8d's broker side): what the app needs
//! from the core and the broker to show a navigate or reload card in the main window's drawer
//! and end it there. Part 2's seam (`Broker.approval`, d3655a8) stays as it is; part 3 adds:
//! - **Deny.** `Cards.deny(id)` ends a waiting card `denied` (the drawer's native Deny button,
//!   the only caller). Deny, like Approve, loses at or after the 120 s deadline and after any
//!   other ending; a later Approve or Deny changes nothing. The broker answers a denied call
//!   "The navigation was denied." with nothing dispatched.
//! - **Show.** `Approval.show` (optional, so part 2's rigs still build) is called once per card,
//!   on the worker, after the card is presented and before its notification, with a `CardView`:
//!   the card's id, its verb, the bound window, and the exact params the engine will get if it
//!   is approved (`{"url":...,"window_id":"window-N"}` / `{"window_id":"window-N"}`). The app
//!   hops it to the main window's drawer. No card, no show; no main window, no show.
//! - **Ended.** `Approval.ended` (optional) is called exactly once per shown card with its one
//!   ending: `done` after an approved dispatch answered, `denied`, `expired`, `cancelled` (the
//!   main window closed), `revoked` (the bound window's broker detached or stopped while the
//!   card waited; the card is cancelled in the core too, so a late Approve in the main
//!   drawer dispatches nothing; and an Approve that wins after that stop, before the worker
//!   looks again, still dispatches nothing: RoseCat 7698). The drawer's `approvalend` row is
//!   made from it.
//! - **`Broker.before_card_look`** (test seam, RoseCat 304a41b; production sets none): called on
//!   the worker before each look at a waiting card, so a red can hold it there and force the
//!   close-vs-Approve schedule.
//!
//! On HEAD there is no `Broker.Approval` seam and no `Cards.deny`: this file does not compile
//! there (the red). Unregistered until its green.

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
/// Part 4 (RoseCat f87368e #2): the card's params carry its document (phase A) as options.expect.
const listed = "{\"result\":{\"pages\":[{\"window_id\":\"window-2\",\"url\":\"https://example.com/start\",\"title\":\"s\",\"primary\":false,\"load_serial\":3}]}}";
const expect_json = "\"options\":{\"expect\":{\"origin\":\"https://example.com\",\"load_serial\":3}}";
const navigate_params = "{\"url\":\"https://example.com/next\",\"window_id\":\"window-2\"," ++ expect_json ++ "}";
const reload_params = "{\"window_id\":\"window-2\"," ++ expect_json ++ "}";
const denied = "The navigation was denied.";
const engine_ok = "{\"result\":{\"ok\":true}}";

/// The scripted engine: `page.list` (phase A) answers `listed`; every other call is counted and
/// answered `engine_ok`.
const Engine = struct {
    n: std.atomic.Value(usize) = .init(0),
    fn call(ctx: *anyopaque, a: std.mem.Allocator, called: []const u8, _: []const u8) error{OutOfMemory}![]u8 {
        const self: *Engine = @ptrCast(@alignCast(ctx));
        if (std.mem.eql(u8, called, "page.list")) return a.dupe(u8, listed);
        _ = self.n.fetchAdd(1, .acq_rel);
        return a.dupe(u8, engine_ok);
    }
    fn count(self: *Engine) usize {
        return self.n.load(.acquire);
    }
};

/// The call's one answer.
const Answer = struct {
    n: std.atomic.Value(u32) = .init(0),
    ok: bool = false,
    text: [512]u8 = undefined,
    len: usize = 0,

    fn done(ctx: *anyopaque, _: []const u8, result: broker.Result) void {
        const self: *Answer = @ptrCast(@alignCast(ctx));
        const ok, const text = switch (result) {
            .content => |c| .{ true, c },
            .failure => |m| .{ false, m },
        };
        self.ok = ok;
        self.len = @min(text.len, self.text.len);
        @memcpy(self.text[0..self.len], text[0..self.len]);
        _ = self.n.fetchAdd(1, .release);
    }
    fn wait(self: *Answer) !void {
        const until = fake.nowMs() + 10_000;
        while (self.n.load(.acquire) == 0) {
            if (fake.nowMs() > until) return error.TestNoAnswer;
            testing.io.sleep(.fromMilliseconds(5), .awake) catch {};
        }
    }
    fn failure(self: *Answer) []const u8 {
        return self.text[0..self.len];
    }
};

/// What the app saw, in order: each show, notification and ending.
const Event = struct {
    kind: enum { show, notify, ended },
    id: approval.CardId = 0,
    verb: approval.Verb = .navigate,
    window: u32 = 0,
    params: [256]u8 = undefined,
    params_len: usize = 0,
    ending: broker.Ending = .done,
    /// The engine's call count when it happened.
    dispatched: usize = 0,

    fn paramsText(self: *const Event) []const u8 {
        return self.params[0..self.params_len];
    }
};

const App = struct {
    selector: approval.Selector = .conditional,
    drawer_showing: bool = false,
    typed_prompt: bool = true,
    engine: *Engine,
    mutex: std.Io.Mutex = .init,
    events: [16]Event = undefined,
    n: usize = 0,

    fn record(self: *App, event: Event) void {
        self.mutex.lockUncancelable(testing.io);
        defer self.mutex.unlock(testing.io);
        var e = event;
        e.dispatched = self.engine.count();
        if (self.n < self.events.len) self.events[self.n] = e;
        self.n += 1;
    }
    fn seen(self: *App) []const Event {
        self.mutex.lockUncancelable(testing.io);
        defer self.mutex.unlock(testing.io);
        return self.events[0..@min(self.n, self.events.len)];
    }
    fn count(self: *App, kind: @FieldType(Event, "kind")) usize {
        var n: usize = 0;
        for (self.seen()) |e| n += @intFromBool(e.kind == kind);
        return n;
    }

    fn readSelector(ctx: *anyopaque) approval.StoreRead {
        const self: *App = @ptrCast(@alignCast(ctx));
        return .{ .selector = self.selector, .unreadable = false };
    }
    fn facts(ctx: *anyopaque) approval.RunFacts {
        const self: *App = @ptrCast(@alignCast(ctx));
        return .{ .drawer_showing = self.drawer_showing, .typed_prompt = self.typed_prompt };
    }
    fn notify(ctx: *anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.record(.{ .kind = .notify });
    }
    fn reportUnreadable(_: *anyopaque) void {}
    fn show(ctx: *anyopaque, card: broker.CardView) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        var e: Event = .{ .kind = .show, .id = card.id, .verb = card.verb, .window = card.window };
        e.params_len = @min(card.params.len, e.params.len);
        @memcpy(e.params[0..e.params_len], card.params[0..e.params_len]);
        self.record(e);
    }
    fn ended(ctx: *anyopaque, id: approval.CardId, ending: broker.Ending) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.record(.{ .kind = .ended, .id = id, .ending = ending });
    }
};

/// The cards' clock, advanced by the test.
const Clock = struct {
    now_ms: std.atomic.Value(u64) = .init(1_000),
    fn now(ctx: *anyopaque) u64 {
        const self: *Clock = @ptrCast(@alignCast(ctx));
        return self.now_ms.load(.acquire);
    }
};

/// One heap broker on window 2 (the app's kind, so it can be detached), with the full seam.
const Rig = struct {
    f: *fake.Fixture,
    b: *broker.Broker,
    reaper: broker.Reaper,
    engine: Engine = .{},
    app: App,
    clock: Clock = .{},
    cards: approval.Cards,
    detached: bool = false,

    fn create() !*Rig {
        const self = try gpa.create(Rig);
        errdefer gpa.destroy(self);
        self.* = .{ .f = try fake.Fixture.create("navcard", "zb-automation-token-canary-7f3a9c"), .b = undefined, .reaper = .init(gpa), .app = undefined, .cards = undefined };
        self.app = .{ .engine = &self.engine };
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
        // Both live: the main window (1, opened first) and the bound one (2), so a close of
        // window 1 is the main window's close, not merely the last window's (RoseCat 7626).
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
    fn waitCard(self: *Rig) !approval.CardId {
        const until = fake.nowMs() + 10_000;
        while (true) {
            if (self.cards.outcome(1)) |o| if (o == .waiting and self.app.count(.notify) == 1) return 1;
            if (fake.nowMs() > until) return error.TestNoCard;
            testing.io.sleep(.fromMilliseconds(5), .awake) catch {};
        }
    }
    fn waitEnded(self: *Rig) !void {
        const until = fake.nowMs() + 10_000;
        while (self.app.count(.ended) == 0) {
            if (fake.nowMs() > until) return error.TestNotEnded;
            testing.io.sleep(.fromMilliseconds(5), .awake) catch {};
        }
    }
};

fn settle() void {
    testing.io.sleep(.fromMilliseconds(100), .awake) catch {};
}

/// The app saw exactly: one show (with `view`), then one notification, then one ending.
fn expectShownThenEnded(r: *Rig, verb: approval.Verb, params: []const u8, ending: broker.Ending) !void {
    const seen = r.app.seen();
    try testing.expectEqual(@as(usize, 3), seen.len);
    try testing.expectEqual(.show, seen[0].kind);
    try testing.expectEqual(@as(approval.CardId, 1), seen[0].id);
    try testing.expectEqual(verb, seen[0].verb);
    try testing.expectEqual(@as(u32, 2), seen[0].window);
    try testing.expectEqualStrings(params, seen[0].paramsText());
    try testing.expectEqual(@as(usize, 0), seen[0].dispatched);
    try testing.expectEqual(.notify, seen[1].kind);
    try testing.expectEqual(.ended, seen[2].kind);
    try testing.expectEqual(@as(approval.CardId, 1), seen[2].id);
    try testing.expectEqual(ending, seen[2].ending);
}

test "Deny ends a waiting card denied; a later Approve or Deny changes nothing" {
    var clock = Clock{};
    var cards = approval.Cards.init(gpa, .{ .ctx = &clock, .now_ms = Clock.now });
    defer cards.deinit();
    cards.windowOpened(1);
    const id = try cards.present();
    try testing.expect(cards.deny(id));
    try testing.expectEqual(approval.Outcome.denied, cards.outcome(id).?);
    try testing.expect(!cards.approve(id));
    try testing.expect(!cards.deny(id));
    try testing.expectEqual(approval.Outcome.denied, cards.outcome(id).?);
    // The main window's close does not turn a denied card into a cancelled one.
    cards.windowClosed(1);
    try testing.expectEqual(approval.Outcome.denied, cards.outcome(id).?);
}

test "Deny loses at or after the deadline, after an Approve, and after a cancel" {
    var clock = Clock{};
    var cards = approval.Cards.init(gpa, .{ .ctx = &clock, .now_ms = Clock.now });
    defer cards.deinit();
    cards.windowOpened(1);

    const late = try cards.present();
    _ = clock.now_ms.fetchAdd(approval.card_ttl_ms, .acq_rel);
    try testing.expect(!cards.deny(late));
    try testing.expectEqual(approval.Outcome.expired, cards.outcome(late).?);

    const approved = try cards.present();
    try testing.expect(cards.approve(approved));
    try testing.expect(!cards.deny(approved));
    try testing.expectEqual(approval.Outcome.approved, cards.outcome(approved).?);

    const in_time = try cards.present();
    _ = clock.now_ms.fetchAdd(approval.card_ttl_ms - 1, .acq_rel);
    try testing.expect(cards.deny(in_time));
    try testing.expectEqual(approval.Outcome.denied, cards.outcome(in_time).?);

    const closed = try cards.present();
    cards.windowClosed(1);
    try testing.expect(!cards.deny(closed));
    try testing.expectEqual(approval.Outcome.cancelled, cards.outcome(closed).?);
    try testing.expect(!cards.deny(9999));
}

test "a denied navigate is answered 'The navigation was denied.', nothing dispatched, ended denied once" {
    const r = try Rig.create();
    defer r.destroy();
    var a: Answer = .{};
    r.submit(navigate_tool, navigate_args, &a);
    const id = try r.waitCard();
    try testing.expect(r.cards.deny(id));
    try a.wait();
    try testing.expect(!a.ok);
    try testing.expectEqualStrings(denied, a.failure());
    try r.waitEnded();
    settle();
    try testing.expectEqual(@as(usize, 0), r.engine.count());
    try expectShownThenEnded(r, .navigate, navigate_params, .denied);
}

test "an approved card is shown once with its exact params, then ends done after its one dispatch" {
    for ([_]struct { tool: []const u8, args: []const u8, verb: approval.Verb, params: []const u8 }{
        .{ .tool = navigate_tool, .args = navigate_args, .verb = .navigate, .params = navigate_params },
        .{ .tool = reload_tool, .args = "{}", .verb = .reload, .params = reload_params },
    }) |row| {
        const r = try Rig.create();
        defer r.destroy();
        var a: Answer = .{};
        r.submit(row.tool, row.args, &a);
        const id = try r.waitCard();
        try testing.expect(r.cards.approve(id));
        try a.wait();
        try testing.expect(a.ok);
        try r.waitEnded();
        settle();
        try testing.expectEqual(@as(usize, 1), r.engine.count());
        try expectShownThenEnded(r, row.verb, row.params, .done);
        try testing.expectEqual(@as(usize, 1), r.app.seen()[2].dispatched);
    }
}

test "an unanswered card ends expired; the main window's close ends it cancelled; neither dispatches" {
    {
        const r = try Rig.create();
        defer r.destroy();
        var a: Answer = .{};
        r.submit(reload_tool, "{}", &a);
        _ = try r.waitCard();
        _ = r.clock.now_ms.fetchAdd(approval.card_ttl_ms, .acq_rel);
        try a.wait();
        try r.waitEnded();
        settle();
        try testing.expectEqual(@as(usize, 0), r.engine.count());
        try expectShownThenEnded(r, .reload, reload_params, .expired);
    }
    {
        const r = try Rig.create();
        defer r.destroy();
        var a: Answer = .{};
        r.submit(navigate_tool, navigate_args, &a);
        _ = try r.waitCard();
        r.cards.windowClosed(1);
        try a.wait();
        try r.waitEnded();
        settle();
        try testing.expectEqual(@as(usize, 0), r.engine.count());
        try expectShownThenEnded(r, .navigate, navigate_params, .cancelled);
    }
}

test "the bound window's broker detaches while its card waits: ended revoked, the card cancelled, a late Approve dispatches nothing" {
    const r = try Rig.create();
    defer r.destroy();
    var a: Answer = .{};
    r.submit(navigate_tool, navigate_args, &a);
    const id = try r.waitCard();
    r.detach();
    try r.waitEnded();
    try testing.expectEqual(approval.Outcome.cancelled, r.cards.outcome(id).?);
    try testing.expect(!r.cards.approve(id));
    settle();
    try testing.expectEqual(@as(usize, 0), r.engine.count());
    // A detached broker answers nothing: the window that would get it is gone.
    try testing.expectEqual(@as(u32, 0), a.n.load(.acquire));
    try expectShownThenEnded(r, .navigate, navigate_params, .revoked);
}

test "the bound window closes just as Approve wins (RoseCat 7698, 304a41b): revoked, never dispatched" {
    // The schedule, forced with the broker's `before_card_look` seam: the worker is held just
    // before its next look at the waiting card; the bound window's broker detaches; the main
    // drawer's Approve then wins the card (asserted: it is still waiting, so Approve must win);
    // the worker is released. It must see the stop before the approval: revoked, no dispatch.
    const r = try Rig.create();
    defer r.destroy();
    var hold: Hold = .{};
    r.b.before_card_look = .{ .ctx = &hold, .run = Hold.run };
    var a: Answer = .{};
    r.submit(navigate_tool, navigate_args, &a);
    const id = try r.waitCard();
    hold.arm();
    try hold.waitHeld();
    r.detach();
    try testing.expect(r.cards.approve(id));
    try testing.expectEqual(approval.Outcome.approved, r.cards.outcome(id).?);
    hold.release();
    try r.waitEnded();
    settle();
    try testing.expectEqual(@as(usize, 0), r.engine.count());
    try testing.expectEqual(@as(u32, 0), a.n.load(.acquire));
    try expectShownThenEnded(r, .navigate, navigate_params, .revoked);
}

/// Holds the worker inside `before_card_look` once armed, until released.
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
    fn arm(self: *Hold) void {
        self.armed.store(true, .release);
    }
    fn waitHeld(self: *Hold) !void {
        const until = fake.nowMs() + 10_000;
        while (!self.held.load(.acquire)) {
            if (fake.nowMs() > until) return error.TestWorkerNotHeld;
            testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
        }
    }
    fn release(self: *Hold) void {
        self.released.store(true, .release);
    }
};

test "no card, no show and no ending; no main window, no show and no ending" {
    {
        const r = try Rig.create();
        defer r.destroy();
        r.app.drawer_showing = true; // interactive, conditional: no card
        var a: Answer = .{};
        r.submit(navigate_tool, navigate_args, &a);
        try a.wait();
        try testing.expect(a.ok);
        settle();
        try testing.expectEqual(@as(usize, 0), r.app.seen().len);
    }
    {
        const r = try Rig.create();
        defer r.destroy();
        r.cards.windowClosed(1);
        var a: Answer = .{};
        r.submit(navigate_tool, navigate_args, &a);
        try a.wait();
        try testing.expectEqualStrings("The navigation was cancelled.", a.failure());
        settle();
        try testing.expectEqual(@as(usize, 0), r.app.seen().len);
        try testing.expectEqual(@as(usize, 0), r.engine.count());
    }
}
