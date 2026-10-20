//! S7b (chat-drawer plan section 10, S7, revs 16.20.34-16.20.36): a drawer's tool calls go
//! to its window's broker; their answers go back to the helper on the GTK thread. GTK app
//! (Linux) only.
//!
//! - `start` (app.zig) gives the in-process automation core; with none, every call is
//!   answered "tool not available".
//! - One broker per window and session, made on that session's first `tool_call`, bound to
//!   the window, with the deadline for the helper's tool_deadline_s (agent_protocol).
//! - Its sink runs on a broker thread under the broker's mutex: it copies the answer and
//!   posts it (`zb_agent_helper_post_tool_result`, agent_helper.c), never blocking. The GTK
//!   side writes it only if that window still has that session open.
//! - A window closed, a session ended, or the helper gone: the broker detaches (never a join
//!   on the GTK thread) and the app's one Reaper joins and frees it; `stop` (after the GTK
//!   loop) detaches the rest and joins the Reaper.
//! Everything here but the sink runs on the GTK thread.
const std = @import("std");
const automation_server = @import("automation_server.zig");
const broker_mod = @import("agent_broker.zig");
const protocol = @import("agent_protocol.zig");

const Server = automation_server.AutomationApiServer;
const gpa = std.heap.smp_allocator;

extern fn zb_agent_helper_post_tool_result(win: c_uint, session: [*:0]const u8, id: [*]const u8, id_len: usize, ok: c_int, body: [*]const u8, len: usize) void;
extern fn zb_agent_image_fit(png: [*]const u8, len: usize, max_b64: usize, out_b64: *?[*:0]u8, out_mime: *?[*:0]const u8) callconv(.c) c_int;
extern fn zb_agent_image_free(b64: ?*anyopaque) callconv(.c) void;

/// A window's broker and its sink's context: the window and the session it answers.
const Bound = struct {
    broker: *broker_mod.Broker,
    win: c_uint,
    session: [48:0]u8,
};

var server: ?*Server = null;
var reaper: broker_mod.Reaper = undefined;
var bound: std.AutoHashMapUnmanaged(c_uint, *Bound) = .empty;

pub fn start(core: *Server) void {
    server = core;
    reaper = .init(gpa);
}

/// After the GTK loop: every broker detached, then the Reaper joined.
pub fn stop() void {
    if (server == null) return;
    zb_agent_tools_detach_all();
    bound.deinit(gpa);
    reaper.deinit();
    server = null;
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
    b.broker = broker_mod.Broker.create(gpa, core, win, broker_mod.deadlineMs(@intCast(protocol.tool_deadline_s))) catch {
        gpa.destroy(b);
        return null;
    };
    b.broker.fit = .{ .fit = zb_agent_image_fit, .free = zb_agent_image_free };
    bound.put(gpa, win, b) catch {
        b.broker.detach(&reaper);
        gpa.destroy(b);
        return null;
    };
    return b;
}

/// GTK thread: a validated `tool_call` of `session`, open in window `win`.
export fn zb_agent_tools_call(win: c_uint, session: [*:0]const u8, id: [*]const u8, id_len: usize, tool: [*]const u8, tool_len: usize, args: [*]const u8, args_len: usize) void {
    const b = brokerFor(win, std.mem.span(session)) orelse return refuse(win, session, id[0..id_len]);
    b.broker.submit(id[0..id_len], tool[0..tool_len], args[0..args_len], .{ .ctx = b, .done = done });
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
