//! S8 red (chat-drawer plan decision 16, part 2; S8b's broker side): the drawer's broker gains
//! `navigate` and `reload`, gated by the decision-16 core (src/agent_approval.zig, d5cac3e).
//! - Without the approval seam (`Broker.approval`, set by the app in S8c) both tools stay "tool
//!   not available" and reach no engine: S7.5 holds until the wiring lands.
//! - `navigate` takes exactly `{url: string}`, `reload` exactly `{}`; anything else is refused
//!   with no engine call. Both run on the drawer's own window (window_id added; one of the
//!   model's own refused, as for every tool).
//! - Whether a call waits for a card is the core's `needsCard(selector, modeOf(facts))`: no card
//!   means the engine's page.navigate / page.reload runs at once. A store that could not be read
//!   is `yes` and is reported once.
//! - A card waits in the main window's drawer (the core's Cards) with one desktop notification;
//!   nothing is dispatched while it waits. Approve dispatches exactly once and the model gets the
//!   engine's answer. Expiry (120 s on the cards' clock) answers "The navigation was not
//!   approved in time.", a main-window close (or no main window) "The navigation was
//!   cancelled.": the engine is never called, and a late Approve changes nothing.
//!
//! On HEAD there is no `Broker.Approval` seam: this file does not compile there (the red).

const std = @import("std");
const automation_server = @import("automation_server");
const fake = @import("agent_tools_fake.zig");

const testing = std.testing;
const gpa = testing.allocator;

const broker = if (@hasDecl(automation_server, "agent_broker")) automation_server.agent_broker else struct {};
const has = @hasDecl(broker, "Approval") and @hasDecl(broker, "approval");
const approval = if (has) broker.approval else struct {};

const navigate_tool = "mcp__zigbrowser__navigate";
const reload_tool = "mcp__zigbrowser__reload";
const not_approved = "The navigation was not approved in time.";
const cancelled = "The navigation was cancelled.";
const engine_ok = "{\"result\":{\"ok\":true}}";

/// The scripted engine: every call recorded, every answer `engine_ok`.
const Engine = struct {
    mutex: std.Io.Mutex = .init,
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
        return a.dupe(u8, engine_ok);
    }
    fn count(self: *Engine) usize {
        self.mutex.lockUncancelable(testing.io);
        defer self.mutex.unlock(testing.io);
        return self.n;
    }
    fn method(self: *Engine, i: usize) []const u8 {
        return self.methods[i][0..self.lens[i][0]];
    }
    fn param(self: *Engine, i: usize) []const u8 {
        return self.params[i][0..self.lens[i][1]];
    }
};

/// The call's one answer.
const Answer = struct {
    n: std.atomic.Value(u32) = .init(0),
    ok: bool = false,
    text: [512]u8 = undefined,
    len: usize = 0,

    fn done(ctx: *anyopaque, _: []const u8, result: if (has) broker.Result else void) void {
        if (!has) return;
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

/// The app's side of the seam: the selector the store holds, the run's facts, the
/// notifications raised, and an unreadable store reported.
const App = struct {
    selector: if (has) approval.Selector else u8 = if (has) .conditional else 0,
    unreadable: bool = false,
    drawer_showing: bool = true,
    typed_prompt: bool = true,
    notifications: std.atomic.Value(u32) = .init(0),
    unreadable_reports: std.atomic.Value(u32) = .init(0),

    fn readSelector(ctx: *anyopaque) if (has) approval.StoreRead else void {
        if (!has) return;
        const self: *App = @ptrCast(@alignCast(ctx));
        return .{ .selector = self.selector, .unreadable = self.unreadable };
    }
    fn facts(ctx: *anyopaque) if (has) approval.RunFacts else void {
        if (!has) return;
        const self: *App = @ptrCast(@alignCast(ctx));
        return .{ .drawer_showing = self.drawer_showing, .typed_prompt = self.typed_prompt };
    }
    fn notify(ctx: *anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        _ = self.notifications.fetchAdd(1, .release);
    }
    fn reportUnreadable(ctx: *anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        _ = self.unreadable_reports.fetchAdd(1, .release);
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

/// One broker on window 2 with the approval seam (or none), the scripted engine and the cards.
const Rig = struct {
    f: *fake.Fixture,
    b: if (has) broker.Broker else void,
    engine: Engine = .{},
    app: App = .{},
    clock: Clock = .{},
    cards: if (has) approval.Cards else void,

    fn create(with_seam: bool) !*Rig {
        if (!has) return error.TestNoApprovalSeam;
        const self = try gpa.create(Rig);
        errdefer gpa.destroy(self);
        self.* = .{ .f = try fake.Fixture.create("navigate", "zb-automation-token-canary-7f3a9c"), .b = undefined, .cards = undefined };
        try self.f.server.startCore();
        self.b = broker.Broker.init(gpa, &self.f.server, 2, 30_000);
        self.b.engine = .{ .ctx = &self.engine, .call = Engine.call };
        self.cards = approval.Cards.init(gpa, .{ .ctx = &self.clock, .now_ms = Clock.now });
        if (with_seam) self.b.approval = .{
            .ctx = &self.app,
            .cards = &self.cards,
            .read_selector = App.readSelector,
            .facts = App.facts,
            .notify = App.notify,
            .report_unreadable = App.reportUnreadable,
        };
        return self;
    }
    fn destroy(self: *Rig) void {
        if (!has) return;
        self.b.deinit();
        self.cards.deinit();
        self.f.destroy();
        gpa.destroy(self);
    }
    fn submit(self: *Rig, tool: []const u8, args: []const u8, answer: *Answer) void {
        if (!has) return;
        self.b.submit("c-1", tool, args, .{ .ctx = answer, .done = Answer.done });
    }
    /// Waits until the card the call presented is waiting (the broker presented it).
    fn waitCard(self: *Rig) !u64 {
        if (!has) return error.TestNoApprovalSeam;
        const until = fake.nowMs() + 10_000;
        while (true) {
            if (self.cards.outcome(1)) |o| if (o == .waiting) return 1;
            if (fake.nowMs() > until) return error.TestNoCard;
            testing.io.sleep(.fromMilliseconds(5), .awake) catch {};
        }
    }
};

fn settle() void {
    testing.io.sleep(.fromMilliseconds(100), .awake) catch {};
}

test "without the approval seam, navigate and reload are not available and reach no engine" {
    const r = try Rig.create(false);
    defer r.destroy();
    for ([_][2][]const u8{ .{ navigate_tool, "{\"url\":\"https://example.com/\"}" }, .{ reload_tool, "{}" } }) |call| {
        var answer: Answer = .{};
        r.submit(call[0], call[1], &answer);
        try answer.wait();
        try testing.expectEqualStrings("tool not available", answer.failure());
    }
    settle();
    try testing.expectEqual(@as(usize, 0), r.engine.count());
}

test "interactive with conditional: navigate and reload run at once on the drawer's window, no card" {
    const r = try Rig.create(true);
    defer r.destroy();
    r.cards.windowOpened(1);
    var a: Answer = .{};
    r.submit(navigate_tool, "{\"url\":\"https://example.com/next\"}", &a);
    try a.wait();
    try testing.expect(a.ok);
    var b: Answer = .{};
    r.submit(reload_tool, "{}", &b);
    try b.wait();
    try testing.expect(b.ok);
    try testing.expectEqual(@as(usize, 2), r.engine.count());
    try testing.expectEqualStrings("page.navigate", r.engine.method(0));
    try testing.expect(std.mem.indexOf(u8, r.engine.param(0), "\"url\":\"https://example.com/next\"") != null);
    try testing.expect(std.mem.indexOf(u8, r.engine.param(0), "\"window_id\":\"window-2\"") != null);
    try testing.expectEqualStrings("page.reload", r.engine.method(1));
    try testing.expectEqual(@as(?approval.Outcome, null), r.cards.outcome(1));
    try testing.expectEqual(@as(u32, 0), r.app.notifications.load(.acquire));
}

test "headless with conditional: a card waits in the main window, one notification, nothing dispatched; Approve dispatches once" {
    const r = try Rig.create(true);
    defer r.destroy();
    r.cards.windowOpened(1);
    r.app.drawer_showing = false;
    var a: Answer = .{};
    r.submit(navigate_tool, "{\"url\":\"https://example.com/next\"}", &a);
    const card = try r.waitCard();
    settle();
    try testing.expectEqual(@as(u32, 0), a.n.load(.acquire));
    try testing.expectEqual(@as(usize, 0), r.engine.count());
    try testing.expectEqual(@as(u32, 1), r.app.notifications.load(.acquire));
    try testing.expect(r.cards.approve(card));
    try a.wait();
    try testing.expect(a.ok);
    try testing.expectEqual(@as(usize, 1), r.engine.count());
    try testing.expectEqualStrings("page.navigate", r.engine.method(0));
}

test "full automation: an unanswered card expires at 120 s, nothing dispatched, a late Approve changes nothing" {
    const r = try Rig.create(true);
    defer r.destroy();
    r.cards.windowOpened(1);
    r.app.typed_prompt = false;
    var a: Answer = .{};
    r.submit(reload_tool, "{}", &a);
    const card = try r.waitCard();
    _ = r.clock.now_ms.fetchAdd(approval.card_ttl_ms, .acq_rel);
    try a.wait();
    try testing.expectEqualStrings(not_approved, a.failure());
    try testing.expect(!r.cards.approve(card));
    settle();
    try testing.expectEqual(@as(usize, 0), r.engine.count());
}

test "the main window closes while the card waits: cancelled, nothing dispatched" {
    const r = try Rig.create(true);
    defer r.destroy();
    r.cards.windowOpened(1);
    r.app.drawer_showing = false;
    var a: Answer = .{};
    r.submit(navigate_tool, "{\"url\":\"https://example.com/next\"}", &a);
    _ = try r.waitCard();
    r.cards.windowClosed(1);
    try a.wait();
    try testing.expectEqualStrings(cancelled, a.failure());
    settle();
    try testing.expectEqual(@as(usize, 0), r.engine.count());
}

test "no main window: the carded call is cancelled at once, no notification, nothing dispatched" {
    const r = try Rig.create(true);
    defer r.destroy();
    r.app.drawer_showing = false;
    var a: Answer = .{};
    r.submit(navigate_tool, "{\"url\":\"https://example.com/next\"}", &a);
    try a.wait();
    try testing.expectEqualStrings(cancelled, a.failure());
    settle();
    try testing.expectEqual(@as(usize, 0), r.engine.count());
    try testing.expectEqual(@as(u32, 0), r.app.notifications.load(.acquire));
}

test "the selector overrides: yes cards interactive use, no never cards headless; an unreadable store is yes and reported once" {
    {
        const r = try Rig.create(true);
        defer r.destroy();
        r.cards.windowOpened(1);
        r.app.selector = .yes;
        var a: Answer = .{};
        r.submit(navigate_tool, "{\"url\":\"https://example.com/next\"}", &a);
        _ = try r.waitCard();
        try testing.expectEqual(@as(usize, 0), r.engine.count());
        r.cards.windowClosed(1);
        try a.wait();
    }
    {
        const r = try Rig.create(true);
        defer r.destroy();
        r.cards.windowOpened(1);
        r.app.selector = .no;
        r.app.drawer_showing = false;
        r.app.typed_prompt = false;
        var a: Answer = .{};
        r.submit(navigate_tool, "{\"url\":\"https://example.com/next\"}", &a);
        try a.wait();
        try testing.expect(a.ok);
        try testing.expectEqual(@as(usize, 1), r.engine.count());
    }
    {
        const r = try Rig.create(true);
        defer r.destroy();
        r.cards.windowOpened(1);
        r.app.selector = .yes;
        r.app.unreadable = true;
        var a: Answer = .{};
        r.submit(navigate_tool, "{\"url\":\"https://example.com/next\"}", &a);
        _ = try r.waitCard();
        try testing.expectEqual(@as(u32, 1), r.app.unreadable_reports.load(.acquire));
        r.cards.windowClosed(1);
        try a.wait();
        try testing.expectEqual(@as(usize, 0), r.engine.count());
    }
}

test "navigate takes exactly {url: string} and reload exactly {}; a model's window_id is refused; no engine call" {
    const r = try Rig.create(true);
    defer r.destroy();
    r.cards.windowOpened(1);
    const bad = [_][2][]const u8{
        .{ navigate_tool, "{}" },
        .{ navigate_tool, "{\"url\":7}" },
        .{ navigate_tool, "{\"url\":\"\"}" },
        .{ navigate_tool, "{\"url\":\"https://example.com/\",\"extra\":1}" },
        .{ reload_tool, "{\"hard\":true}" },
        .{ navigate_tool, "{\"url\":\"https://example.com/\",\"window_id\":\"window-1\"}" },
    };
    for (bad) |call| {
        var answer: Answer = .{};
        r.submit(call[0], call[1], &answer);
        try answer.wait();
        testing.expect(!answer.ok) catch |e| {
            std.debug.print("{s} {s} was accepted\n", .{ call[0], call[1] });
            return e;
        };
    }
    settle();
    try testing.expectEqual(@as(usize, 0), r.engine.count());
}
