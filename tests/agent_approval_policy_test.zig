//! S8 red (chat-drawer plan, decision 16; the owner's answers through rev 16.20.54): the
//! platform-free core of navigate/reload approval, `src/agent_approval.zig`. The broker's cards
//! (S8b) are not built yet, so this red pins the decisions that core owns; S8b-S8d wire it.
//! - The selector (`yes | no | conditional`, default `conditional`) and the mode (interactive,
//!   headless, full automation) decide whether navigate and reload get a card: the whole 3x3
//!   table, the same for both verbs.
//! - The mode: full automation when no user-typed prompt started the run; else headless when
//!   the bound window's drawer is not showing; else interactive.
//! - The store, one file `navigate_approval` (0600): missing gives `conditional`; exactly
//!   `yes\n`, `no\n` or `conditional\n` gives that; anything else (other text, extra bytes, no
//!   newline, a symlink, mode 0644) gives `yes` and says it was unreadable. The one writer
//!   writes 0600, exactly the value and a newline.
//! - The main window is the FIRST zigBrowser window opened; no later window takes its place.
//!   A card waits in its drawer; with no main window there is no card (the step is cancelled).
//!   When the main window closes, every waiting card ends `cancelled`. A card left unanswered
//!   ends `expired` at 120 s exactly. Expiry and cancellation win over a late Approve.
//! - The desktop notification is fixed text whatever the card holds; activating it only asks to
//!   open the main window's drawer and changes no card.

const std = @import("std");
const approval = @import("agent_approval");

const testing = std.testing;
const gpa = testing.allocator;
const io = testing.io;

const Selector = approval.Selector;
const Mode = approval.Mode;

test "the 3x3 table decides a card, the same for navigate and reload" {
    const rows = [_]struct { selector: Selector, mode: Mode, card: bool }{
        .{ .selector = .yes, .mode = .interactive, .card = true },
        .{ .selector = .yes, .mode = .headless, .card = true },
        .{ .selector = .yes, .mode = .full_automation, .card = true },
        .{ .selector = .no, .mode = .interactive, .card = false },
        .{ .selector = .no, .mode = .headless, .card = false },
        .{ .selector = .no, .mode = .full_automation, .card = false },
        .{ .selector = .conditional, .mode = .interactive, .card = false },
        .{ .selector = .conditional, .mode = .headless, .card = true },
        .{ .selector = .conditional, .mode = .full_automation, .card = true },
    };
    for (rows) |row| for ([_]approval.Verb{ .navigate, .reload }) |verb| {
        testing.expectEqual(row.card, approval.needsCard(verb, row.selector, row.mode)) catch |e| {
            std.debug.print("{s} {s} {s}\n", .{ @tagName(verb), @tagName(row.selector), @tagName(row.mode) });
            return e;
        };
    };
    try testing.expectEqual(Selector.conditional, approval.default_selector);
}

test "native page input actions always require approval" {
    for ([_]approval.Verb{ .click, .type_text }) |verb| {
        for ([_]Selector{ .yes, .no, .conditional }) |selector| {
            for ([_]Mode{ .interactive, .headless, .full_automation }) |mode| {
                try testing.expect(approval.needsCard(verb, selector, mode));
            }
        }
    }
}

test "the mode: full automation without a typed prompt, else headless without a showing drawer, else interactive" {
    try testing.expectEqual(Mode.interactive, approval.modeOf(.{ .drawer_showing = true, .typed_prompt = true }));
    try testing.expectEqual(Mode.headless, approval.modeOf(.{ .drawer_showing = false, .typed_prompt = true }));
    try testing.expectEqual(Mode.full_automation, approval.modeOf(.{ .drawer_showing = true, .typed_prompt = false }));
    try testing.expectEqual(Mode.full_automation, approval.modeOf(.{ .drawer_showing = false, .typed_prompt = false }));
}

test "the store: missing is conditional, exact values are read, anything else is yes and unreadable" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const name = approval.store_name;

    const missing = approval.readSelector(io, tmp.dir, name);
    try testing.expectEqual(Selector.conditional, missing.selector);
    try testing.expect(!missing.unreadable);

    for ([_]struct { bytes: []const u8, want: Selector }{
        .{ .bytes = "yes\n", .want = .yes },
        .{ .bytes = "no\n", .want = .no },
        .{ .bytes = "conditional\n", .want = .conditional },
    }) |row| {
        try writeMode(tmp.dir, name, row.bytes, 0o600);
        const got = approval.readSelector(io, tmp.dir, name);
        try testing.expectEqual(row.want, got.selector);
        try testing.expect(!got.unreadable);
    }

    for ([_][]const u8{ "maybe\n", "no\nno\n", "no", "NO\n", " no\n", "", "conditional\n\x00" }) |bytes| {
        try writeMode(tmp.dir, name, bytes, 0o600);
        const got = approval.readSelector(io, tmp.dir, name);
        testing.expect(got.selector == .yes and got.unreadable) catch |e| {
            std.debug.print("{any} read as {s}, unreadable {}\n", .{ bytes, @tagName(got.selector), got.unreadable });
            return e;
        };
    }

    // A wrong mode, even with a good value, is unreadable: yes.
    try writeMode(tmp.dir, name, "no\n", 0o644);
    const loose = approval.readSelector(io, tmp.dir, name);
    try testing.expect(loose.selector == .yes and loose.unreadable);

    // A symlink to a good value is never followed: yes.
    try tmp.dir.deleteFile(io, name);
    try writeMode(tmp.dir, "elsewhere", "no\n", 0o600);
    try tmp.dir.symLink(io, "elsewhere", name, .{});
    const linked = approval.readSelector(io, tmp.dir, name);
    try testing.expect(linked.selector == .yes and linked.unreadable);
}

test "the store's one writer writes 0600, exactly the value and a newline, and reads back" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_]Selector{ .no, .yes, .conditional }) |selector| {
        try approval.writeSelector(io, tmp.dir, selector);
        const stat = try tmp.dir.statFile(io, approval.store_name, .{ .follow_symlinks = false });
        try testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
        var buf: [32]u8 = undefined;
        const got = try tmp.dir.readFile(io, approval.store_name, &buf);
        var want: [32]u8 = undefined;
        try testing.expectEqualStrings(try std.fmt.bufPrint(&want, "{s}\n", .{@tagName(selector)}), got);
        try testing.expectEqual(selector, approval.readSelector(io, tmp.dir, approval.store_name).selector);
    }
}

test "the main window is the first opened; its close cancels every waiting card; no later window takes over" {
    var clock = Clock{};
    var cards = approval.Cards.init(gpa, clock.source());
    defer cards.deinit();

    // No window yet: no card can wait anywhere; the step is cancelled.
    try testing.expectError(error.NoMainWindow, cards.present());

    cards.windowOpened(1);
    cards.windowOpened(2);
    try testing.expectEqual(@as(?u64, 1), cards.mainWindow());

    const a = try cards.present();
    const b = try cards.present();
    try testing.expectEqual(approval.Outcome.waiting, cards.outcome(a).?);

    // Another window closing changes nothing.
    cards.windowClosed(2);
    try testing.expectEqual(approval.Outcome.waiting, cards.outcome(a).?);

    // The main window closes: every waiting card is cancelled.
    cards.windowClosed(1);
    try testing.expectEqual(approval.Outcome.cancelled, cards.outcome(a).?);
    try testing.expectEqual(approval.Outcome.cancelled, cards.outcome(b).?);
    try testing.expectEqual(@as(?u64, null), cards.mainWindow());

    // A later window is never the main window.
    cards.windowOpened(3);
    try testing.expectEqual(@as(?u64, null), cards.mainWindow());
    try testing.expectError(error.NoMainWindow, cards.present());

    // A late Approve changes nothing.
    try testing.expect(!cards.approve(a));
    try testing.expectEqual(approval.Outcome.cancelled, cards.outcome(a).?);
}

test "an unanswered card expires at 120 s exactly; expiry beats a late Approve; an Approve in time wins" {
    var clock = Clock{};
    var cards = approval.Cards.init(gpa, clock.source());
    defer cards.deinit();
    cards.windowOpened(1);
    try testing.expectEqual(@as(u64, 120_000), approval.card_ttl_ms);

    const late = try cards.present();
    clock.now_ms += approval.card_ttl_ms - 1;
    cards.expireDue();
    try testing.expectEqual(approval.Outcome.waiting, cards.outcome(late).?);
    clock.now_ms += 1;
    cards.expireDue();
    try testing.expectEqual(approval.Outcome.expired, cards.outcome(late).?);
    try testing.expect(!cards.approve(late));
    try testing.expectEqual(approval.Outcome.expired, cards.outcome(late).?);

    // An Approve before the deadline, even when expiry is only checked afterwards, wins.
    const in_time = try cards.present();
    clock.now_ms += approval.card_ttl_ms - 1;
    try testing.expect(cards.approve(in_time));
    clock.now_ms += 10;
    cards.expireDue();
    try testing.expectEqual(approval.Outcome.approved, cards.outcome(in_time).?);

    // An Approve that arrives at or after the deadline loses even if expiry has not run yet.
    const at_deadline = try cards.present();
    clock.now_ms += approval.card_ttl_ms;
    try testing.expect(!cards.approve(at_deadline));
    try testing.expectEqual(approval.Outcome.expired, cards.outcome(at_deadline).?);
}

test "the notification is fixed text whatever the card holds; activating it only asks for the main drawer" {
    var clock = Clock{};
    var cards = approval.Cards.init(gpa, clock.source());
    defer cards.deinit();
    cards.windowOpened(1);
    const card = try cards.present();
    try testing.expectEqualStrings("zigBrowser", approval.notification_title);
    try testing.expectEqualStrings("Claude is waiting for your approval.", approval.notification_body);
    // Activation, with any payload and any number of times, is only "open the main drawer".
    for ([_][]const u8{ "", "approve", "{\"card\":1,\"approve\":true}", "deny" }) |payload| {
        try testing.expectEqual(approval.Activation{ .open_drawer_of = 1 }, cards.activateNotification(payload));
        try testing.expectEqual(approval.Outcome.waiting, cards.outcome(card).?);
    }
}

/// A fake millisecond clock for the cards' expiry.
const Clock = struct {
    now_ms: u64 = 1_000,
    fn now(ctx: *anyopaque) u64 {
        const self: *Clock = @ptrCast(@alignCast(ctx));
        return self.now_ms;
    }
    fn source(self: *Clock) approval.ClockSource {
        return .{ .ctx = self, .now_ms = now };
    }
};

fn writeMode(dir: std.Io.Dir, name: []const u8, bytes: []const u8, mode: std.posix.mode_t) !void {
    dir.deleteFile(io, name) catch {};
    const file = try dir.createFile(io, name, .{ .exclusive = true });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
    try file.setPermissions(io, @enumFromInt(mode));
}
