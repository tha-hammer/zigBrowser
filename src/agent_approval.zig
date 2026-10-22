//! S8 decision 16 (chat-drawer plan; the owner's answers through rev 16.20.54): the
//! platform-free core of navigate and reload approval. Whether a navigation gets a card (the
//! user's selector and the run's mode), the selector's store, and the main window's waiting
//! cards: who the main window is, expiry at the card time, and cancellation when it closes.
//! The broker (S8b) asks it; the app (S8c) feeds it windows and the clock; the drawer (S8d)
//! draws its cards.

const std = @import("std");

/// The user's choice (the Secrets window's "Navigation approval" control).
pub const Selector = enum { yes, no, conditional };

/// The owner's default: a card only where no one is watching.
pub const default_selector: Selector = .conditional;

/// How the run is being driven (the owner's definitions, rev 16.20.47).
pub const Mode = enum { interactive, headless, full_automation };

pub const Verb = enum { navigate, reload };

/// Whether navigate or reload asks the user first: `yes` always, `no` never, `conditional` only
/// in headless or full automation. The verb does not change it.
pub fn needsCard(verb: Verb, selector: Selector, mode: Mode) bool {
    _ = verb;
    return switch (selector) {
        .yes => true,
        .no => false,
        .conditional => mode != .interactive,
    };
}

pub const RunFacts = struct {
    /// The bound window's drawer is showing.
    drawer_showing: bool,
    /// A prompt the user typed started this run (not a scheduled or chained one).
    typed_prompt: bool,
};

/// Full automation when no typed prompt started the run; else headless when the bound window's
/// drawer is not showing; else interactive.
pub fn modeOf(facts: RunFacts) Mode {
    if (!facts.typed_prompt) return .full_automation;
    if (!facts.drawer_showing) return .headless;
    return .interactive;
}

/// The store: one file in the agent home's settings directory.
pub const store_name = "navigate_approval";

/// The drawer's line when the store could not be read (the selector is then `yes`).
pub const unreadable_line = "Navigation approval setting is unreadable; asking for every navigation.";

pub const StoreRead = struct { selector: Selector, unreadable: bool = false };

/// The selector the store holds. A missing file is the default; exactly `yes\n`, `no\n` or
/// `conditional\n` in a regular 0600 file (never through a symlink) is that value; anything else
/// fails closed to `yes`, a card in every mode.
pub fn readSelector(io: std.Io, dir: std.Io.Dir, name: []const u8) StoreRead {
    const closed: StoreRead = .{ .selector = .yes, .unreadable = true };
    const file = dir.openFile(io, name, .{ .follow_symlinks = false }) catch |err| return switch (err) {
        error.FileNotFound => .{ .selector = default_selector },
        else => closed,
    };
    defer file.close(io);
    const stat = file.stat(io) catch return closed;
    if (stat.kind != .file or stat.permissions.toMode() & 0o777 != 0o600) return closed;
    var buf: [16]u8 = undefined;
    const n = file.readPositionalAll(io, &buf, 0) catch return closed;
    const text = buf[0..n];
    inline for (.{ Selector.yes, Selector.no, Selector.conditional }) |selector| {
        if (std.mem.eql(u8, text, @tagName(selector) ++ "\n")) return .{ .selector = selector };
    }
    return closed;
}

/// The one writer (the Secrets window's control): exactly the value and a newline, 0600,
/// written to a temporary name and renamed over the store.
pub fn writeSelector(io: std.Io, dir: std.Io.Dir, selector: Selector) !void {
    const tmp_name = store_name ++ ".tmp";
    dir.deleteFile(io, tmp_name) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    {
        const file = try dir.createFile(io, tmp_name, .{ .exclusive = true });
        defer file.close(io);
        try file.setPermissions(io, @enumFromInt(0o600));
        try file.writeStreamingAll(io, switch (selector) {
            inline else => |s| @tagName(s) ++ "\n",
        });
        try file.sync(io);
    }
    try dir.rename(tmp_name, dir, store_name, io);
}

/// The card time (the user's answer 2): an unanswered card is cancelled after it.
pub const card_ttl_ms: u64 = 120_000;

/// The desktop notification: fixed text, whatever the card holds (rev 16.20.50).
pub const notification_title = "zigBrowser";
pub const notification_body = "Claude is waiting for your approval.";

pub const Outcome = enum { waiting, approved, expired, cancelled };

/// What activating the notification may do: only open the main window's drawer.
pub const Activation = union(enum) { open_drawer_of: u64, nothing };

pub const ClockSource = struct {
    ctx: *anyopaque,
    now_ms: *const fn (ctx: *anyopaque) u64,

    fn now(self: ClockSource) u64 {
        return self.now_ms(self.ctx);
    }
};

pub const CardId = u64;

/// The main window's waiting cards (owner, rev 16.20.54). The main window is the first window
/// opened; when it closes there is none, and every waiting card is cancelled. Safe across
/// threads: the broker's worker presents and polls, the GTK thread opens, closes and approves.
pub const Cards = struct {
    lock: std.atomic.Mutex = .unlocked,
    gpa: std.mem.Allocator,
    clock: ClockSource,
    main: ?u64 = null,
    /// A main window was ever chosen: no later window takes its place.
    chosen: bool = false,
    next_id: CardId = 1,
    cards: std.ArrayListUnmanaged(Card) = .empty,

    const Card = struct { id: CardId, presented_ms: u64, outcome: Outcome };

    pub fn init(gpa: std.mem.Allocator, clock: ClockSource) Cards {
        return .{ .gpa = gpa, .clock = clock };
    }

    pub fn deinit(self: *Cards) void {
        self.cards.deinit(self.gpa);
    }

    fn acquire(self: *Cards) void {
        while (!self.lock.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn windowOpened(self: *Cards, window: u64) void {
        self.acquire();
        defer self.lock.unlock();
        if (self.chosen) return;
        self.chosen = true;
        self.main = window;
    }

    pub fn windowClosed(self: *Cards, window: u64) void {
        self.acquire();
        defer self.lock.unlock();
        if (self.main != window) return;
        self.main = null;
        for (self.cards.items) |*card| {
            if (card.outcome == .waiting) card.outcome = .cancelled;
        }
    }

    pub fn mainWindow(self: *Cards) ?u64 {
        self.acquire();
        defer self.lock.unlock();
        return self.main;
    }

    /// A new card waiting in the main window's drawer; without one, the step is cancelled.
    pub fn present(self: *Cards) error{ OutOfMemory, NoMainWindow }!CardId {
        self.acquire();
        defer self.lock.unlock();
        if (self.main == null) return error.NoMainWindow;
        const id = self.next_id;
        self.next_id += 1;
        try self.cards.append(self.gpa, .{ .id = id, .presented_ms = self.clock.now(), .outcome = .waiting });
        return id;
    }

    /// Every waiting card whose time is up ends `expired`.
    pub fn expireDue(self: *Cards) void {
        self.acquire();
        defer self.lock.unlock();
        const now = self.clock.now();
        for (self.cards.items) |*card| self.expireIfDue(card, now);
    }

    fn expireIfDue(_: *Cards, card: *Card, now: u64) void {
        if (card.outcome == .waiting and now -| card.presented_ms >= card_ttl_ms) card.outcome = .expired;
    }

    /// The user's Approve: it wins only while the card waits and its time is not up.
    pub fn approve(self: *Cards, id: CardId) bool {
        self.acquire();
        defer self.lock.unlock();
        const card = self.find(id) orelse return false;
        self.expireIfDue(card, self.clock.now());
        if (card.outcome != .waiting) return false;
        card.outcome = .approved;
        return true;
    }

    pub fn outcome(self: *Cards, id: CardId) ?Outcome {
        self.acquire();
        defer self.lock.unlock();
        const card = self.find(id) orelse return null;
        return card.outcome;
    }

    /// The notification was activated (any payload, any number of times): at most open the main
    /// window's drawer; no card changes.
    pub fn activateNotification(self: *Cards, payload: []const u8) Activation {
        _ = payload;
        self.acquire();
        defer self.lock.unlock();
        const window = self.main orelse return .nothing;
        return .{ .open_drawer_of = window };
    }

    fn find(self: *Cards, id: CardId) ?*Card {
        for (self.cards.items) |*card| if (card.id == id) return card;
        return null;
    }
};
