//! S7b (chat-drawer plan section 10, S7, revs 16.20.34-16.20.36): a drawer's tool calls go
//! to its window's broker; their answers go back to the helper on the GTK thread. The tool calls
//! are the GTK app's (Linux) only; the approval cards, their two minters and the window lifecycle
//! are in every build (MS8.0: on macOS the AppKit card's bridge in agent_drawer.zig calls the same
//! minters).
//!
//! - `start` (app.zig) gives the in-process automation core; with none, every call is
//!   answered "tool not available".
//! - One broker per window and session, made on that session's first `tool_call`, bound to
//!   the window, with the deadline for the helper's H (agent_frames.toolDeadlineS: 120 s, or
//!   the e2e seam's hello.e2e.tool_deadline_s).
//! - Its sink runs on a broker thread under the broker's mutex: it copies the answer and
//!   posts it (`zb_agent_helper_post_tool_result`, agent_helper.c), never blocking. The GTK
//!   side writes it only if that window still has that session open.
//! - A window closed, a session ended, or the helper gone: the broker detaches (never a join
//!   on the GTK thread) and the app's one Reaper joins and frees it; `stop` (after the GTK
//!   loop) detaches the rest and joins the Reaper.
//! - S8 decision 16 part 3 (plan rev 16.20.56): every window's opening and closing reaches the
//!   one set of cards, whose main window is the first opened. Each broker gets the approval seam
//!   (its context is its window id, which outlives the broker); its callbacks run on the
//!   broker's worker and hop to GTK (agent_drawer.c). The drawer's Approve and Deny reach the
//!   cards through zb_agent_tools_approve/deny, their only callers.
//! Everything here but the sink and the approval callbacks runs on the GTK thread.
const std = @import("std");
const builtin = @import("builtin");
const automation_server = @import("automation_server.zig");
const broker_mod = @import("agent_broker.zig");
const agent_frames = @import("agent_frames.zig");
const approval = broker_mod.approval;

const Server = automation_server.AutomationApiServer;
const gpa = std.heap.smp_allocator;

extern fn zb_agent_helper_post_tool_result(win: c_uint, session: [*:0]const u8, id: [*]const u8, id_len: usize, ok: c_int, body: [*]const u8, len: usize) void;
extern fn zb_agent_image_fit(png: [*]const u8, len: usize, max_b64: usize, out_b64: *?[*:0]u8, out_mime: *?[*:0]const u8) callconv(.c) c_int;
extern fn zb_agent_image_free(b64: ?*anyopaque) callconv(.c) void;
// agent_drawer.c (any thread: each hops to GTK) and agent_helper.c.
extern fn zb_drawer_card_show(main_win: c_uint, card: u64, verb: [*:0]const u8, bound_win: c_uint, params: [*]const u8, params_len: usize, url: ?[*:0]const u8, origin: [*:0]const u8) void;
extern fn zb_drawer_card_end(card: u64, ending: [*:0]const u8) void;
extern fn zb_drawer_card_notify(title: [*:0]const u8, body: [*:0]const u8) void;
extern fn zb_drawer_post_system(win: c_uint, text: [*]const u8, len: usize) void;
extern fn zb_agent_helper_home() ?[*:0]const u8;

/// A window's broker and its sink's context: the window and the session it answers.
const Bound = struct {
    broker: *broker_mod.Broker,
    win: c_uint,
    session: [48:0]u8,
};

var server: ?*Server = null;
var reaper: broker_mod.Reaper = undefined;
var bound: std.AutoHashMapUnmanaged(c_uint, *Bound) = .empty;
/// S8 decision 16: the main window's cards, made by `start` (before the first window).
var cards: approval.Cards = undefined;
/// Which windows' drawers are showing, mirrored from GTK for the workers' `facts`.
var showing_lock: std.atomic.Mutex = .unlocked;
var showing: std.AutoHashMapUnmanaged(c_uint, void) = .empty;

pub fn start(core: *Server) void {
    server = core;
    reaper = .init(gpa);
    cards = .init(gpa, .{ .ctx = core, .now_ms = nowMs });
}

fn nowMs(ctx: *anyopaque) u64 {
    const core: *Server = @ptrCast(@alignCast(ctx));
    return @intCast(std.Io.Clock.now(.awake, core.io).toMilliseconds());
}

/// After the GTK loop: every broker detached, then the Reaper joined. The helper's own stop
/// runs after this and detaches again (forget_process): that finds an empty map.
pub fn stop() void {
    if (server == null) return;
    zb_agent_tools_detach_all();
    bound.deinit(gpa);
    bound = .empty;
    reaper.deinit();
    cards.deinit();
    showing.deinit(gpa);
    showing = .empty;
    server = null;
}

// --- S8 decision 16 part 3: the approval seam (on a broker's worker) ------------------------

/// A broker's approval context is its window id, never a pointer to its Bound: an ending can
/// come after the window's broker was detached and its Bound freed.
fn seamFor(win: c_uint) broker_mod.Approval {
    return .{
        .ctx = @ptrFromInt(win),
        .cards = &cards,
        .read_selector = readSelector,
        .facts = facts,
        .notify = notify,
        .report_unreadable = reportUnreadable,
        .show = show,
        .ended = ended,
    };
}

fn windowOf(ctx: *anyopaque) c_uint {
    return @intCast(@intFromPtr(ctx));
}

/// The store, agent-home/settings/navigate_approval, read for each call: the user's own file
/// in the user's own settings directory, never through a symlink (RoseCat f87368e #4).
fn readSelector(_: *anyopaque) approval.StoreRead {
    const core = server orelse return .{ .selector = .yes, .unreadable = true };
    const home = zb_agent_helper_home() orelse return .{ .selector = approval.default_selector };
    return approval.readStore(core.io, std.mem.span(home), approval.effectiveUid());
}

/// Every prompt today is one the user typed: full automation has no entry yet.
fn facts(ctx: *anyopaque) approval.RunFacts {
    while (!showing_lock.tryLock()) std.atomic.spinLoopHint();
    defer showing_lock.unlock();
    return .{ .drawer_showing = showing.contains(windowOf(ctx)), .typed_prompt = true };
}

fn notify(_: *anyopaque) void {
    zb_drawer_card_notify(approval.notification_title, approval.notification_body);
}

fn reportUnreadable(ctx: *anyopaque) void {
    zb_drawer_post_system(windowOf(ctx), approval.unreadable_line, approval.unreadable_line.len);
}

fn show(_: *anyopaque, card: broker_mod.CardView) void {
    const main = cards.mainWindow() orelse return; // closed since: the card is cancelled
    var parsed = std.json.parseFromSlice(struct { url: ?[]const u8 = null }, gpa, card.params, .{ .ignore_unknown_fields = true }) catch null;
    defer if (parsed) |*p| p.deinit();
    const url: ?[:0]u8 = if (parsed) |p| (if (p.value.url) |u| gpa.dupeZ(u8, u) catch null else null) else null;
    defer if (url) |u| gpa.free(u);
    const origin = gpa.dupeZ(u8, card.origin) catch return;
    defer gpa.free(origin);
    zb_drawer_card_show(@intCast(main), card.id, @tagName(card.verb), card.window, card.params.ptr, card.params.len, if (url) |u| u.ptr else null, origin.ptr);
}

fn ended(_: *anyopaque, id: approval.CardId, ending: broker_mod.Ending) void {
    // `cancelled`: the main window closed, so its drawer is gone (D7b's `closed`).
    zb_drawer_card_end(id, if (ending == .cancelled) "closed" else @tagName(ending));
}

/// GTK thread (agent_helper.c): prompt `prompt_id` of window `win` ended (its result, its
/// error, or Stop): its broker revokes exactly that prompt's calls first (decision 8).
export fn zb_agent_tools_prompt_over(win: c_uint, prompt_id: i64) void {
    const b = bound.get(win) orelse return;
    b.broker.promptOver(prompt_id);
}

/// GTK thread (agent_secrets_window.c's Navigation approval control, part 5): the store's value,
/// 0 yes, 1 no, 2 conditional, and whether it was unreadable (then yes).
export fn zb_agent_navapproval_read(home: [*:0]const u8, unreadable: *c_int) c_int {
    const core = server orelse {
        unreadable.* = 1;
        return @intFromEnum(approval.Selector.yes);
    };
    const read = approval.readStore(core.io, std.mem.span(home), approval.effectiveUid());
    unreadable.* = @intFromBool(read.unreadable);
    return @intFromEnum(read.selector);
}

/// GTK thread: the control's one write (0 yes, 1 no, 2 conditional). 0 when written, -1 when
/// refused (an unsafe settings directory) or failed: then nothing was written.
export fn zb_agent_navapproval_write(home: [*:0]const u8, value: c_int) c_int {
    const core = server orelse return -1;
    const selector: approval.Selector = switch (value) {
        0 => .yes,
        1 => .no,
        2 => .conditional,
        else => return -1,
    };
    approval.writeStore(core.io, std.mem.span(home), approval.effectiveUid(), selector) catch return -1;
    return 0;
}

/// GTK thread: every window that opens; the first is the main window.
export fn zb_agent_tools_window_opened(win: c_uint) void {
    if (server == null) return;
    cards.windowOpened(win);
}

/// GTK thread: every window that closes; the main window's close cancels every waiting card.
export fn zb_agent_tools_window_closed(win: c_uint) void {
    if (server == null) return;
    cards.windowClosed(win);
    zb_agent_tools_drawer_showing(win, 0);
}

/// GTK thread: window `win`'s drawer opened (1) or began to fold away (0).
export fn zb_agent_tools_drawer_showing(win: c_uint, shown: c_int) void {
    if (server == null) return;
    while (!showing_lock.tryLock()) std.atomic.spinLoopHint();
    defer showing_lock.unlock();
    if (shown != 0) showing.put(gpa, win, {}) catch {} else _ = showing.remove(win);
}

/// GTK thread: the main drawer's Approve button, the only caller. 1 when it won the card.
export fn zb_agent_tools_approve(card: u64) c_int {
    if (server == null) return 0;
    return @intFromBool(cards.approve(card));
}

/// GTK thread: the main drawer's Deny button, the only caller. 1 when it ended the card.
export fn zb_agent_tools_deny(card: u64) c_int {
    if (server == null) return 0;
    return @intFromBool(cards.deny(card));
}

/// GTK thread: the desktop notification was activated by its server. The window whose drawer
/// to open (the main one), or 0; no card changes.
export fn zb_agent_tools_activate() c_uint {
    if (server == null) return 0;
    return switch (cards.activateNotification("")) {
        .open_drawer_of => |win| @intCast(win),
        .nothing => 0,
    };
}

fn done(ctx: *anyopaque, id: []const u8, result: broker_mod.Result) void {
    const b: *Bound = @ptrCast(@alignCast(ctx));
    const ok: c_int, const body = switch (result) {
        .content => |content| .{ 1, content },
        .failure => |text| .{ 0, text },
    };
    zb_agent_helper_post_tool_result(b.win, &b.session, id.ptr, id.len, ok, body.ptr, body.len);
}

fn refuse(win: c_uint, session: [*:0]const u8, id: []const u8) void {
    const text = "tool not available";
    zb_agent_helper_post_tool_result(win, session, id.ptr, id.len, 0, text, text.len);
}

/// This window's broker for `session`: a session that ended leaves its broker detached.
fn brokerFor(win: c_uint, session: []const u8) ?*Bound {
    if (bound.get(win)) |b| {
        if (std.mem.eql(u8, std.mem.sliceTo(&b.session, 0), session)) return b;
        zb_agent_tools_window_done(win);
    }
    const core = server orelse return null;
    if (session.len >= 48) return null;
    const b = gpa.create(Bound) catch return null;
    b.* = .{ .broker = undefined, .win = win, .session = @splat(0) };
    @memcpy(b.session[0..session.len], session);
    b.broker = broker_mod.Broker.create(gpa, core, win, broker_mod.deadlineMs(@intCast(agent_frames.toolDeadlineS()))) catch {
        gpa.destroy(b);
        return null;
    };
    b.broker.fit = .{ .fit = zb_agent_image_fit, .free = zb_agent_image_free };
    b.broker.approval = seamFor(win);
    bound.put(gpa, win, b) catch {
        b.broker.detach(&reaper);
        gpa.destroy(b);
        return null;
    };
    return b;
}

/// GTK thread: a validated `tool_call` of `session`'s prompt `prompt_id`, open in window `win`.
/// Linux only (MS8.0): its broker's sink and card callbacks are agent_helper.c's and agent_drawer.c's.
fn zb_agent_tools_call(win: c_uint, session: [*:0]const u8, prompt_id: i64, id: [*]const u8, id_len: usize, tool: [*]const u8, tool_len: usize, args: [*]const u8, args_len: usize) callconv(.c) void {
    const b = brokerFor(win, std.mem.span(session)) orelse return refuse(win, session, id[0..id_len]);
    b.broker.submitPrompt(prompt_id, id[0..id_len], tool[0..tool_len], args[0..args_len], .{ .ctx = b, .done = done });
}

comptime {
    if (builtin.os.tag == .linux) @export(&zb_agent_tools_call, .{ .name = "zb_agent_tools_call" });
}

/// GTK thread: window `win`'s session ended, or the window closed. Its broker detaches:
/// after this returns no sink of it runs, so its context is freed here.
export fn zb_agent_tools_window_done(win: c_uint) void {
    const entry = bound.fetchRemove(win) orelse return;
    entry.value.broker.detach(&reaper);
    gpa.destroy(entry.value);
}

/// GTK thread: the helper is gone, and with it every session.
export fn zb_agent_tools_detach_all() void {
    while (bound.count() > 0) {
        var it = bound.keyIterator();
        zb_agent_tools_window_done(it.next().?.*);
    }
}
