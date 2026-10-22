//! S8e part 1 red (chat-drawer plan D9 and S8 decision 12; S8b's broker side): the drawer's
//! broker gains `hover` and `scroll`, the two act-on-page tools that need no card.
//! - Without the app's S8 wiring (`Broker.approval`, set by the app) both stay "tool not
//!   available" and reach no engine, like navigate and reload: S7.5 holds until the wiring
//!   lands (tests/agent_broker_test.zig's S7.3/S7.8 row stays true).
//! - With it, each runs `dom.hover` / `dom.scroll` exactly once on the drawer's own window
//!   (window_id added), with exactly the model's args, at once: no card, no `page.list` (phase A
//!   is for carded calls), no notification, whatever the navigate_approval selector and the mode
//!   (every selector x mode).
//! - Exact args, behind the helper's schema: hover is exactly `{selector: non-empty string}`;
//!   scroll exactly `{selector: non-empty string}` or a non-empty subset of `{x, y}`, integers
//!   in [-100000, 100000]. Anything else is "the tool's arguments are not valid" with no engine
//!   call: both shapes, `{}`, a float, a string number, an out-of-range offset, `options`
//!   (`input: native` would move the user's own pointer; `humanize`), `strict`, `timeout_ms`,
//!   `approved`, `grant`, an unknown key, an empty selector. A model's `window_id` is refused
//!   (as for every tool). A refused call also shows no card, raises no notification and leaves
//!   no card outcome, with the selector at `yes` (RoseCat 5a204f3).
//!
//! On HEAD the broker has no hover or scroll: each call is "tool not available" (the red).

const std = @import("std");
const automation_server = @import("automation_server");
const fake = @import("agent_tools_fake.zig");

const testing = std.testing;
const gpa = testing.allocator;

const broker = automation_server.agent_broker;
const approval = broker.approval;

const hover_tool = "mcp__zigbrowser__hover";
const scroll_tool = "mcp__zigbrowser__scroll";
const invalid = "the tool's arguments are not valid";
const engine_ok = "{\"result\":{\"scrollX\":0,\"scrollY\":900}}";

/// The scripted engine: `page.list` is only counted; every other call is recorded and answered.
const Engine = struct {
    mutex: std.Io.Mutex = .init,
    methods: [16][32]u8 = undefined,
    params: [16][256]u8 = undefined,
    lens: [16][2]usize = undefined,
    n: usize = 0,
    lists: usize = 0,

    fn call(ctx: *anyopaque, a: std.mem.Allocator, called: []const u8, with: []const u8) error{OutOfMemory}![]u8 {
        const self: *Engine = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(testing.io);
        defer self.mutex.unlock(testing.io);
        if (std.mem.eql(u8, called, "page.list")) {
            self.lists += 1;
            return a.dupe(u8, "{\"result\":{\"pages\":[]}}");
        }
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
    fn listCount(self: *Engine) usize {
        self.mutex.lockUncancelable(testing.io);
        defer self.mutex.unlock(testing.io);
        return self.lists;
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

/// The app's side of the seam.
const App = struct {
    selector: approval.Selector = .conditional,
    drawer_showing: bool = true,
    typed_prompt: bool = true,
    notifications: std.atomic.Value(u32) = .init(0),
    shown: std.atomic.Value(u32) = .init(0),

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
        _ = self.notifications.fetchAdd(1, .release);
    }
    fn reportUnreadable(_: *anyopaque) void {}
    fn show(ctx: *anyopaque, _: broker.CardView) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        _ = self.shown.fetchAdd(1, .release);
    }
};

const Clock = struct {
    fn now(_: *anyopaque) u64 {
        return 1_000;
    }
};

/// One broker on window 2 with the S8 wiring (or none) and the scripted engine.
const Rig = struct {
    f: *fake.Fixture,
    b: broker.Broker,
    engine: Engine = .{},
    app: App = .{},
    clock: u8 = 0,
    cards: approval.Cards,

    fn create(with_seam: bool) !*Rig {
        const self = try gpa.create(Rig);
        errdefer gpa.destroy(self);
        self.* = .{ .f = try fake.Fixture.create("hover", "zb-automation-token-canary-7f3a9c"), .b = undefined, .cards = undefined };
        try self.f.server.startCore();
        self.b = broker.Broker.init(gpa, &self.f.server, 2, 30_000);
        self.b.engine = .{ .ctx = &self.engine, .call = Engine.call };
        self.cards = approval.Cards.init(gpa, .{ .ctx = &self.clock, .now_ms = Clock.now });
        self.cards.windowOpened(1);
        if (with_seam) self.b.approval = .{
            .ctx = &self.app,
            .cards = &self.cards,
            .read_selector = App.readSelector,
            .facts = App.facts,
            .notify = App.notify,
            .report_unreadable = App.reportUnreadable,
            .show = App.show,
        };
        return self;
    }
    fn destroy(self: *Rig) void {
        self.b.deinit();
        self.cards.deinit();
        self.f.destroy();
        gpa.destroy(self);
    }
    /// One call, answered.
    fn call(self: *Rig, tool: []const u8, args: []const u8) !Answer {
        var answer: Answer = .{};
        self.b.submit("c-1", tool, args, .{ .ctx = &answer, .done = Answer.done });
        try answer.wait();
        return answer;
    }
};

fn settle() void {
    testing.io.sleep(.fromMilliseconds(100), .awake) catch {};
}

test "without the S8 wiring, hover and scroll are not available and reach no engine" {
    const r = try Rig.create(false);
    defer r.destroy();
    for ([_][2][]const u8{ .{ hover_tool, "{\"selector\":\"css=#menu\"}" }, .{ scroll_tool, "{\"y\":900}" } }) |c| {
        var a = try r.call(c[0], c[1]);
        try testing.expect(!a.ok);
        try testing.expectEqualStrings("tool not available", a.failure());
    }
    settle();
    try testing.expectEqual(@as(usize, 0), r.engine.count());
}

test "every selector x mode: hover and scroll run at once on the drawer's window, exactly the model's args, no card" {
    const Row = struct { tool: []const u8, args: []const u8, method: []const u8, params: []const u8 };
    const rows = [_]Row{
        .{ .tool = hover_tool, .args = "{\"selector\":\"css=#menu\"}", .method = "dom.hover", .params = "{\"selector\":\"css=#menu\",\"window_id\":\"window-2\"}" },
        .{ .tool = scroll_tool, .args = "{\"selector\":\"css=#bottom\"}", .method = "dom.scroll", .params = "{\"selector\":\"css=#bottom\",\"window_id\":\"window-2\"}" },
        .{ .tool = scroll_tool, .args = "{\"y\":900}", .method = "dom.scroll", .params = "{\"y\":900,\"window_id\":\"window-2\"}" },
        .{ .tool = scroll_tool, .args = "{\"x\":-100000,\"y\":100000}", .method = "dom.scroll", .params = "{\"x\":-100000,\"y\":100000,\"window_id\":\"window-2\"}" },
    };
    const facts = [_][2]bool{ .{ true, true }, .{ false, true }, .{ true, false } }; // interactive, headless, full automation
    for ([_]approval.Selector{ .yes, .no, .conditional }) |selector| {
        for (facts) |f| {
            const r = try Rig.create(true);
            defer r.destroy();
            r.app.selector = selector;
            r.app.drawer_showing = f[0];
            r.app.typed_prompt = f[1];
            for (rows, 0..) |row, i| {
                const a = try r.call(row.tool, row.args);
                try testing.expect(a.ok);
                try testing.expectEqual(i + 1, r.engine.count());
                try testing.expectEqualStrings(row.method, r.engine.method(i));
                try testing.expectEqualStrings(row.params, r.engine.param(i));
            }
            settle();
            try testing.expectEqual(rows.len, r.engine.count());
            try testing.expectEqual(@as(usize, 0), r.engine.listCount());
            try testing.expectEqual(@as(u32, 0), r.app.notifications.load(.acquire));
            try testing.expectEqual(@as(u32, 0), r.app.shown.load(.acquire));
            try testing.expectEqual(@as(?approval.Outcome, null), r.cards.outcome(1));
        }
    }
}

test "hover and scroll take exactly their args: anything else is refused with no engine call, card or notification" {
    const r = try Rig.create(true);
    defer r.destroy();
    // `yes` (RoseCat 5a204f3 SHOULD): a refusal that wrongly went on to decision 16's gate would
    // show a card and notify, which the end of this test counts.
    r.app.selector = .yes;
    const bad = [_][2][]const u8{
        .{ hover_tool, "{}" },
        .{ hover_tool, "{\"selector\":\"\"}" },
        .{ hover_tool, "{\"selector\":7}" },
        .{ hover_tool, "{\"selector\":\"css=#menu\",\"options\":{\"input\":\"native\"}}" },
        .{ hover_tool, "{\"selector\":\"css=#menu\",\"options\":{\"humanize\":true}}" },
        .{ hover_tool, "{\"selector\":\"css=#menu\",\"strict\":false}" },
        .{ hover_tool, "{\"selector\":\"css=#menu\",\"timeout_ms\":1}" },
        .{ hover_tool, "{\"selector\":\"css=#menu\",\"approved\":true}" },
        .{ hover_tool, "{\"selector\":\"css=#menu\",\"grant\":\"G-123\"}" },
        .{ hover_tool, "{\"selector\":\"css=#menu\",\"x\":1}" },
        .{ hover_tool, "[\"css=#menu\"]" },
        .{ scroll_tool, "{}" },
        .{ scroll_tool, "{\"selector\":\"css=#bottom\",\"y\":900}" },
        .{ scroll_tool, "{\"selector\":\"\"}" },
        .{ scroll_tool, "{\"y\":9.5}" },
        .{ scroll_tool, "{\"y\":\"900\"}" },
        .{ scroll_tool, "{\"y\":100001}" },
        .{ scroll_tool, "{\"x\":-100001}" },
        .{ scroll_tool, "{\"y\":null}" },
        .{ scroll_tool, "{\"y\":900,\"options\":{\"input\":\"native\"}}" },
        .{ scroll_tool, "{\"y\":900,\"behavior\":\"smooth\"}" },
        .{ scroll_tool, "{\"selector\":\"css=#bottom\",\"strict\":false}" },
    };
    for (bad) |c| {
        var a = try r.call(c[0], c[1]);
        try testing.expect(!a.ok);
        testing.expectEqualStrings(invalid, a.failure()) catch |err| {
            std.debug.print("args {s} {s}\n", .{ c[0], c[1] });
            return err;
        };
    }
    for ([_][2][]const u8{
        .{ hover_tool, "{\"selector\":\"css=#menu\",\"window_id\":\"window-1\"}" },
        .{ scroll_tool, "{\"y\":900,\"window_id\":\"window-1\"}" },
    }) |c| {
        var a = try r.call(c[0], c[1]);
        try testing.expect(!a.ok);
        try testing.expect(std.mem.eql(u8, a.failure(), invalid) or std.mem.eql(u8, a.failure(), "window is fixed to this drawer"));
    }
    settle();
    try testing.expectEqual(@as(usize, 0), r.engine.count());
    try testing.expectEqual(@as(usize, 0), r.engine.listCount());
    try testing.expectEqual(@as(u32, 0), r.app.shown.load(.acquire));
    try testing.expectEqual(@as(u32, 0), r.app.notifications.load(.acquire));
    try testing.expectEqual(@as(?approval.Outcome, null), r.cards.outcome(1));
}
