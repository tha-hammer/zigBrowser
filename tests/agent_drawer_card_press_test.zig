//! MS7.6 / MS7.8 (macOS plan line 2158; RoseCat 8055 / bdc8202 on 698ba02): what a press on the AppKit approval
//! card may do is decided in the portable src/agent_drawer.zig, so src/agent_drawer_mac.m's two button actions only
//! report (their card's id, which control, whether the sender is that card's own control) and the decision is tested
//! here against the REAL MS4 cards (src/agent_approval.zig: Cards, card_ttl_ms) on a fake clock:
//! - cardPress(card, control, own, approver): Approve (1) on the card's own Approve control asks the approver to
//!   approve exactly that card; Deny (2) on its own Deny control asks to deny exactly that card; a press whose sender
//!   is not the card's own control, or whose control is anything else (0, 3, -1, INT_MAX, INT_MIN), is ignored and
//!   asks nothing (fail closed). The result says which: ignored, approved, denied, or lost (the card had ended).
//! - the grant's shape is the cards': an Approve wins only while the card waits and before card_ttl_ms (120 s: won
//!   at 119 999 ms, lost and `expired` at 120 000 ms); it wins once (a second press, or an Approve after Deny, is
//!   lost); it never touches another card.
//! - zb_drawer_card_press(card, control, own) is the C export the .m calls: it reaches zb_agent_tools_approve /
//!   zb_agent_tools_deny (here: this test's own recording definitions) exactly as cardPress decides, `own` by C truth
//!   (any non-zero is own), and returns the Press value.
//! RED until the green adds them; build step `test-agent-drawer-card-press`, not in `test`.
const std = @import("std");
const drawer = @import("agent_drawer");
const approval = @import("agent_approval");

const gpa = std.testing.allocator;

const Clock = struct {
    now: u64 = 0,
    fn read(ctx: *anyopaque) u64 {
        const self: *Clock = @ptrCast(@alignCast(ctx));
        return self.now;
    }
};

/// The approver the test hands cardPress: the real cards, and a log of what it was asked.
const Real = struct {
    cards: *approval.Cards,
    asked: std.ArrayListUnmanaged(struct { verb: u8, card: u64 }) = .empty,

    fn approve(ctx: *anyopaque, card: u64) bool {
        const self: *Real = @ptrCast(@alignCast(ctx));
        self.asked.append(gpa, .{ .verb = 'a', .card = card }) catch unreachable;
        return self.cards.approve(card);
    }
    fn deny(ctx: *anyopaque, card: u64) bool {
        const self: *Real = @ptrCast(@alignCast(ctx));
        self.asked.append(gpa, .{ .verb = 'd', .card = card }) catch unreachable;
        return self.cards.deny(card);
    }
    fn approver(self: *Real) drawer.Approver {
        return .{ .ctx = self, .approve = approve, .deny = deny };
    }
};

const Fixture = struct {
    clock: Clock = .{},
    cards: approval.Cards = undefined,
    real: Real = undefined,

    fn init(self: *Fixture) void {
        self.cards = approval.Cards.init(gpa, .{ .ctx = &self.clock, .now_ms = Clock.read });
        self.cards.windowOpened(1);
        self.real = .{ .cards = &self.cards };
    }
    fn deinit(self: *Fixture) void {
        self.real.asked.deinit(gpa);
        self.cards.deinit();
    }
};

const APPROVE: c_int = 1;
const DENY: c_int = 2;

test "Approve on the card's own control approves exactly that card, once" {
    var f: Fixture = .{};
    f.init();
    defer f.deinit();
    const a = try f.cards.present();
    const b = try f.cards.present();
    try std.testing.expectEqual(drawer.Press.approved, drawer.cardPress(b, APPROVE, true, f.real.approver()));
    try std.testing.expectEqual(approval.Outcome.approved, f.cards.outcome(b).?);
    try std.testing.expectEqual(approval.Outcome.waiting, f.cards.outcome(a).?); // never another card
    try std.testing.expectEqual(drawer.Press.lost, drawer.cardPress(b, APPROVE, true, f.real.approver())); // single use
    try std.testing.expectEqual(@as(usize, 2), f.real.asked.items.len);
    for (f.real.asked.items) |q| try std.testing.expect(q.verb == 'a' and q.card == b);
}

test "Deny on its own control denies that card and mints nothing; a later Approve is lost" {
    var f: Fixture = .{};
    f.init();
    defer f.deinit();
    const a = try f.cards.present();
    try std.testing.expectEqual(drawer.Press.denied, drawer.cardPress(a, DENY, true, f.real.approver()));
    try std.testing.expectEqual(approval.Outcome.denied, f.cards.outcome(a).?);
    try std.testing.expectEqual(drawer.Press.lost, drawer.cardPress(a, APPROVE, true, f.real.approver()));
    try std.testing.expectEqual(approval.Outcome.denied, f.cards.outcome(a).?);
    try std.testing.expectEqual(@as(u8, 'd'), f.real.asked.items[0].verb);
}

test "a press from another control, or an unknown control, is ignored and asks nothing" {
    var f: Fixture = .{};
    f.init();
    defer f.deinit();
    const a = try f.cards.present();
    for ([_]c_int{ APPROVE, DENY }) |control| {
        try std.testing.expectEqual(drawer.Press.ignored, drawer.cardPress(a, control, false, f.real.approver()));
    }
    for ([_]c_int{ 0, 3, -1, std.math.maxInt(c_int), std.math.minInt(c_int) }) |control| {
        for ([_]bool{ true, false }) |own| {
            try std.testing.expectEqual(drawer.Press.ignored, drawer.cardPress(a, control, own, f.real.approver()));
        }
    }
    try std.testing.expectEqual(@as(usize, 0), f.real.asked.items.len);
    try std.testing.expectEqual(approval.Outcome.waiting, f.cards.outcome(a).?);
}

test "the cards' expiry holds: won at 119 999 ms, lost and expired at 120 000 ms" {
    var f: Fixture = .{};
    f.init();
    defer f.deinit();
    const early = try f.cards.present();
    const late = try f.cards.present();
    f.clock.now = approval.card_ttl_ms - 1;
    try std.testing.expectEqual(drawer.Press.approved, drawer.cardPress(early, APPROVE, true, f.real.approver()));
    f.clock.now = approval.card_ttl_ms;
    try std.testing.expectEqual(drawer.Press.lost, drawer.cardPress(late, APPROVE, true, f.real.approver()));
    try std.testing.expectEqual(approval.Outcome.expired, f.cards.outcome(late).?);
    try std.testing.expectEqual(@as(u64, 120_000), approval.card_ttl_ms);
}

// The C export's targets, defined here so the export's calls are observable (the app's are agent_tools.zig's).
var c_calls: std.ArrayListUnmanaged(struct { verb: u8, card: u64 }) = .empty;
var c_answer: c_int = 1;

export fn zb_agent_tools_approve(card: u64) c_int {
    c_calls.append(gpa, .{ .verb = 'a', .card = card }) catch unreachable;
    return c_answer;
}

export fn zb_agent_tools_deny(card: u64) c_int {
    c_calls.append(gpa, .{ .verb = 'd', .card = card }) catch unreachable;
    return c_answer;
}

test "zb_drawer_card_press reaches the cards exactly as cardPress decides" {
    defer c_calls.deinit(gpa);
    const Row = struct { control: c_int, own: c_int, answer: c_int, want: drawer.Press, call: ?u8 };
    const rows = [_]Row{
        .{ .control = APPROVE, .own = 1, .answer = 1, .want = .approved, .call = 'a' },
        .{ .control = APPROVE, .own = 1, .answer = 0, .want = .lost, .call = 'a' },
        .{ .control = DENY, .own = 1, .answer = 1, .want = .denied, .call = 'd' },
        .{ .control = DENY, .own = 1, .answer = 0, .want = .lost, .call = 'd' },
        .{ .control = APPROVE, .own = 2, .answer = 1, .want = .approved, .call = 'a' }, // C truth
        .{ .control = APPROVE, .own = -1, .answer = 1, .want = .approved, .call = 'a' },
        .{ .control = APPROVE, .own = 0, .answer = 1, .want = .ignored, .call = null },
        .{ .control = DENY, .own = 0, .answer = 1, .want = .ignored, .call = null },
        .{ .control = 0, .own = 1, .answer = 1, .want = .ignored, .call = null },
        .{ .control = 3, .own = 1, .answer = 1, .want = .ignored, .call = null },
    };
    for (rows, 0..) |row, i| {
        c_calls.clearRetainingCapacity();
        c_answer = row.answer;
        const card: u64 = 1000 + i;
        const got = drawer.zb_drawer_card_press(card, row.control, row.own);
        try std.testing.expectEqual(@intFromEnum(row.want), got);
        if (row.call) |verb| {
            try std.testing.expectEqual(@as(usize, 1), c_calls.items.len);
            try std.testing.expect(c_calls.items[0].verb == verb and c_calls.items[0].card == card);
        } else {
            try std.testing.expectEqual(@as(usize, 0), c_calls.items.len);
        }
    }
}
