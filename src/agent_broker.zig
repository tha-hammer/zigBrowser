//! S7a (chat-drawer plan section 10, S7, revs 16.20.30 and 16.20.32): the drawer's broker
//! between its helper's browser tool calls and the automation core, in process
//! (AutomationApiServer.callInProcess; no socket, no auth).
//!
//! - Before S8 the model has read tools only (S7.5): six tools over the eight read methods.
//!   Anything else is "tool not available" and reaches no engine (S7.3, S7.8). With the app's
//!   S8 wiring (`approval`) it also has hover and scroll (no card, S8 decision 12) and navigate
//!   and reload (decision 16).
//! - A drawer's calls run on its own window: the broker adds `window_id`, and a `window_id` in
//!   the model's args is refused (S7.2).
//! - The engine's error data never reaches the model: a failure is a fixed text and the error's
//!   name (S7.7).
//! - `submit` returns at once. A session's calls run one at a time, in order, on its one worker
//!   thread, never the caller's (the GTK thread in the app) (D8). Each gets exactly one answer:
//!   the engine's, or at the deadline "The browser did not answer in time." (a queued call is
//!   then never run; a running one's late engine completion is discarded).
//! - Every reply is a genuine engine error (redacted), a well-formed success, or "the browser
//!   sent a bad answer" (rev 16.20.36): a malformed success never reaches the model.
//! - A call's answer is claimed and published under the broker's mutex, which `detach` also
//!   takes: no sink is called after `detach` returns (rev 16.20.36).
const std = @import("std");
const server_mod = @import("automation_server.zig");
/// S8 decision 16's core: whether navigate and reload wait for a card, and the cards.
pub const approval = @import("agent_approval.zig");

const Server = server_mod.AutomationApiServer;

/// S7.5: the read methods, the only ones a drawer may call before S8.
pub const read_methods = [_][]const u8{ "page.health", "page.url", "page.title", "dom.query", "dom.getText", "dom.getAttribute", "dom.waitFor", "page.screenshot" };

pub fn allowedMethod(method: []const u8) bool {
    for (read_methods) |m| {
        if (std.mem.eql(u8, m, method)) return true;
    }
    return false;
}

const tool_prefix = "mcp__zigbrowser__";

/// S7.5's tools (the helper's MCP server lists exactly these), each one read method.
const tools = [_]struct { name: []const u8, method: []const u8 }{
    .{ .name = "window_info", .method = "page.health" },
    .{ .name = "query", .method = "dom.query" },
    .{ .name = "get_text", .method = "dom.getText" },
    .{ .name = "get_attribute", .method = "dom.getAttribute" },
    .{ .name = "wait_for", .method = "dom.waitFor" },
    .{ .name = "screenshot", .method = "page.screenshot" },
};

fn toolMethod(tool: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, tool, tool_prefix)) return null;
    const name = tool[tool_prefix.len..];
    for (tools) |t| {
        if (std.mem.eql(u8, t.name, name) and allowedMethod(t.method)) return t.method;
    }
    return null;
}

/// Rev 16.20.32: the broker's deadline for a helper deadline of `helper_s` seconds,
/// B = H - min(5, H/4), so 0 < B < H for every H in 1..120.
pub fn deadlineMs(helper_s: u32) u64 {
    const h: u64 = @as(u64, helper_s) * 1000;
    return h - @min(5000, h / 4);
}

pub const timeout_text = "The browser did not answer in time.";
/// S8 decision 16: a navigate or reload whose card was not approved within its time.
pub const not_approved_text = "The navigation was not approved in time.";
/// S8 decision 16: a navigate or reload whose card was cancelled (no main window, or it closed).
pub const cancelled_text = "The navigation was cancelled.";

/// S8 decision 16 (the app sets it, S8c): the store's selector, the run's facts, the main
/// window's cards, the desktop notification and the unreadable-store report. Without it the
/// gated tools are not available (S7.5).
pub const Approval = struct {
    ctx: *anyopaque,
    cards: *approval.Cards,
    read_selector: *const fn (ctx: *anyopaque) approval.StoreRead,
    facts: *const fn (ctx: *anyopaque) approval.RunFacts,
    notify: *const fn (ctx: *anyopaque) void,
    report_unreadable: *const fn (ctx: *anyopaque) void,
    /// Part 3 (rev 16.20.56): on the worker, once per card, before its notification.
    show: ?*const fn (ctx: *anyopaque, card: CardView) void = null,
    /// Part 3: on the worker, exactly once per shown card, with its one ending.
    ended: ?*const fn (ctx: *anyopaque, id: approval.CardId, ending: Ending) void = null,
};

/// A card as the app shows it: `params` are the exact bytes the engine gets if it is approved;
/// `origin` and `load_serial` are the bound window's document when the card was made (phase A,
/// RoseCat f87368e #2), which `params` carry as `options.expect`. Valid only during `show`.
pub const CardView = struct {
    id: approval.CardId,
    verb: approval.Verb,
    window: u32,
    params: []const u8,
    origin: []const u8,
    load_serial: u64,
};
/// A shown card's one ending: `done`/`failed` after its approved dispatch answered, `changed`
/// or `crashed` when the engine refused it because the document is no longer the card's;
/// `revoked` when its window's broker stopped or its prompt ended first.
pub const Ending = enum { done, failed, changed, crashed, denied, expired, cancelled, revoked };
/// Phase A could not read the bound window's document: no card, nothing dispatched.
pub const unchecked_text = "The page could not be checked for approval; nothing was done.";
/// S8 decision 16: a navigate or reload whose card the user denied.
pub const denied_text = "The navigation was denied.";

fn endCard(gate: Approval, id: approval.CardId, ending: Ending) void {
    if (gate.ended) |ended| ended(gate.ctx, id, ending);
}

/// S8 decision 16's tools: each one method, gated by the core.
const gated_tools = [_]struct { name: []const u8, method: []const u8, verb: approval.Verb }{
    .{ .name = "navigate", .method = "page.navigate", .verb = .navigate },
    .{ .name = "reload", .method = "page.reload", .verb = .reload },
};

fn gatedTool(tool: []const u8) ?@TypeOf(gated_tools[0]) {
    if (!std.mem.startsWith(u8, tool, tool_prefix)) return null;
    const name = tool[tool_prefix.len..];
    for (gated_tools) |t| if (std.mem.eql(u8, t.name, name)) return t;
    return null;
}

/// navigate takes exactly {url: non-empty string}; reload exactly {}.
fn gatedArgsOk(gpa: std.mem.Allocator, verb: approval.Verb, args_json: []const u8) error{OutOfMemory}!bool {
    const text = std.mem.trim(u8, args_json, &std.ascii.whitespace);
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, if (text.len == 0) "{}" else text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const object = parsed.value.object;
    switch (verb) {
        .reload => return object.count() == 0,
        .navigate => {
            if (object.count() != 1) return false;
            const url = object.get("url") orelse return false;
            return url == .string and url.string.len > 0;
        },
    }
}

/// Act-on-page tools that need no card. Like navigate and reload they exist only with the
/// app's S8 wiring, but they never ask the selector.
const ActKind = enum { click, hover, scroll };
const act_tools = [_]struct { name: []const u8, method: []const u8, kind: ActKind }{
    .{ .name = "click", .method = "dom.click", .kind = .click },
    .{ .name = "hover", .method = "dom.hover", .kind = .hover },
    .{ .name = "scroll", .method = "dom.scroll", .kind = .scroll },
};

fn actTool(tool: []const u8) ?@TypeOf(act_tools[0]) {
    if (!std.mem.startsWith(u8, tool, tool_prefix)) return null;
    const name = tool[tool_prefix.len..];
    for (act_tools) |t| if (std.mem.eql(u8, t.name, name)) return t;
    return null;
}

const max_offset = 100_000;

/// click and hover take exactly {selector: non-empty string}; scroll exactly that, or a non-empty
/// subset of {x, y}, integers in [-100000, 100000]. Never `options`: native input would move
/// the user's own pointer.
fn actArgsOk(gpa: std.mem.Allocator, kind: ActKind, args_json: []const u8) error{OutOfMemory}!bool {
    const text = std.mem.trim(u8, args_json, &std.ascii.whitespace);
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, if (text.len == 0) "{}" else text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const object = parsed.value.object;
    if (object.get("selector")) |selector| {
        return object.count() == 1 and selector == .string and selector.string.len > 0;
    }
    if (kind != .scroll or object.count() == 0) return false;
    var it = object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (!std.mem.eql(u8, key, "x") and !std.mem.eql(u8, key, "y")) return false;
        const value = entry.value_ptr.*;
        if (value != .integer or value.integer < -max_offset or value.integer > max_offset) return false;
    }
    return true;
}

/// A call's one answer: `.content`, the tool_result content (a JSON array), or `.failure`,
/// its error text. Valid only during the sink's call.
pub const Result = union(enum) { content: []const u8, failure: []const u8 };

pub const Sink = struct {
    ctx: *anyopaque,
    done: *const fn (ctx: *anyopaque, id: []const u8, result: Result) void,
};

/// Test seam (rev 16.20.36): the engine a broker calls in place of the server's
/// `callInProcess`, so a test can script each reply. Production sets none.
pub const Engine = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, method: []const u8, params: []const u8) error{OutOfMemory}![]u8,
};

/// The screenshot fit (rev 16.20.35): in the GTK app `zb_agent_image_fit` and
/// `zb_agent_image_free` (src/agent_image.c), so this file stays platform-free.
pub const Fit = struct {
    fit: *const fn (png: [*]const u8, len: usize, max_b64: usize, out_b64: *?[*:0]u8, out_mime: *?[*:0]const u8) callconv(.c) c_int,
    free: *const fn (b64: ?*anyopaque) callconv(.c) void,
};

/// An image block's base64 at most, leaving room for its tool_result frame (1 MiB a line).
pub const image_max_b64: usize = (1 << 20) - 4096;

/// Test seam (rev 16.20.36): called on the worker after the engine's answer and before its
/// locked publication. Production sets none.
pub const Hook = struct {
    ctx: *anyopaque,
    run: *const fn (ctx: *anyopaque) void,
};

/// D8: one broker per drawer session. Its calls run one at a time, in order, on its one
/// worker thread (one in-flight browser call per session); its deadline thread answers a call
/// whose deadline passes: a queued one is then removed and never runs, a running one's late
/// engine completion is discarded. Both threads start with the first call.
pub const Broker = struct {
    gpa: std.mem.Allocator,
    server: *Server,
    window: u32,
    deadline_ms: u64,
    mutex: std.Io.Mutex = .init,
    /// Signalled when a call is queued, one ends, or the broker stops.
    cond: std.Io.Condition = .init,
    queue: std.ArrayListUnmanaged(*Job) = .empty,
    running: ?*Job = null,
    stopping: bool = false,
    /// Set by `detach`, under the mutex: nothing is published after it.
    detached: bool = false,
    worker: ?std.Thread = null,
    timer: ?std.Thread = null,
    engine: ?Engine = null,
    before_publish: ?Hook = null,
    /// Test seam (RoseCat 304a41b): called on the worker before each look at a waiting card, so a
    /// red can hold it there. Production sets none.
    before_card_look: ?Hook = null,
    /// Test seam (RoseCat f87368e #3): called on the worker after its card was seen approved and
    /// before the live check that guards the dispatch. Production sets none.
    before_dispatch: ?Hook = null,
    /// A screenshot's fit; with none, a screenshot is "the screenshot could not be read".
    fit: ?Fit = null,
    /// S8 decision 16 (S8c sets it): with none, navigate and reload are not available.
    approval: ?Approval = null,
    /// The next broker in its Reaper's list: adopting a broker allocates nothing (RoseCat 6650).
    reap_next: ?*Broker = null,

    pub fn init(gpa: std.mem.Allocator, server: *Server, window: u32, deadline_ms: u64) Broker {
        return .{ .gpa = gpa, .server = server, .window = window, .deadline_ms = deadline_ms };
    }

    /// A broker on the heap, for `detach` (the app's brokers).
    pub fn create(gpa: std.mem.Allocator, server: *Server, window: u32, deadline_ms: u64) !*Broker {
        const self = try gpa.create(Broker);
        self.* = init(gpa, server, window, deadline_ms);
        return self;
    }

    /// For a closed window, on the GTK thread: returns at once, never joins (its running call
    /// may need the GTK thread to finish). Under the mutex it marks the broker detached and
    /// stopping and drops the queued calls unanswered; `reaper` then joins its threads and
    /// frees it. A broker that never started a thread is freed here.
    pub fn detach(self: *Broker, reaper: *Reaper) void {
        const io = self.server.io;
        self.mutex.lockUncancelable(io);
        self.detached = true;
        self.stopping = true;
        for (self.queue.items) |job| job.destroy();
        self.queue.clearRetainingCapacity();
        self.cond.broadcast(io);
        const idle = self.worker == null and self.timer == null;
        self.mutex.unlock(io);
        if (idle) return self.reap();
        reaper.adopt(self, io);
    }

    /// On the reaper (or in `detach` when no thread started): joins and frees a detached broker.
    fn reap(self: *Broker) void {
        if (self.worker) |t| t.join();
        if (self.timer) |t| t.join();
        self.queue.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// Stops both threads (after the running call's engine work ends) and drops the calls
    /// still queued, unanswered.
    pub fn deinit(self: *Broker) void {
        const io = self.server.io;
        self.mutex.lockUncancelable(io);
        self.stopping = true;
        self.cond.broadcast(io);
        self.mutex.unlock(io);
        if (self.worker) |t| t.join();
        if (self.timer) |t| t.join();
        for (self.queue.items) |job| job.destroy();
        self.queue.deinit(self.gpa);
        self.* = undefined;
    }

    /// S8 decision 8 (RoseCat f87368e #1, 7802): prompt `prompt_id` ended (the app: its result,
    /// its error, or Stop). Exactly its calls, queued or running, are revoked before any
    /// dispatch; another prompt's are never touched.
    pub fn promptOver(self: *Broker, prompt_id: i64) void {
        const io = self.server.io;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (self.queue.items) |job| {
            if (job.prompt == prompt_id) job.revoked = true;
        }
        if (self.running) |job| if (job.prompt == prompt_id) {
            job.revoked = true;
        };
        self.cond.broadcast(io);
    }

    /// Under the mutex: `job` may still act (its broker live, its prompt not over).
    fn liveFor(self: *Broker, job: *const Job) bool {
        return !self.stopping and !self.detached and !job.revoked;
    }

    fn live(self: *Broker, job: *const Job) bool {
        self.mutex.lockUncancelable(self.server.io);
        defer self.mutex.unlock(self.server.io);
        return self.liveFor(job);
    }

    /// The calls not ended yet: queued, or running in the engine.
    pub fn inFlight(self: *Broker) usize {
        self.mutex.lockUncancelable(self.server.io);
        defer self.mutex.unlock(self.server.io);
        return self.queue.items.len + @intFromBool(self.running != null);
    }

    /// Runs `tool` with `args_json` for the call `id`; `sink` gets its one answer. A refusal
    /// is answered before this returns; any other call is queued for the worker. A sink must
    /// not call back into this broker.
    pub fn submit(self: *Broker, id: []const u8, tool: []const u8, args_json: []const u8, sink: Sink) void {
        self.submitIn(null, id, tool, args_json, sink);
    }

    /// `submit` for a call of prompt `prompt_id` (the validated tool_call's): `promptOver` of
    /// that prompt revokes it (decision 8).
    pub fn submitPrompt(self: *Broker, prompt_id: i64, id: []const u8, tool: []const u8, args_json: []const u8, sink: Sink) void {
        self.submitIn(prompt_id, id, tool, args_json, sink);
    }

    fn submitIn(self: *Broker, prompt_id: ?i64, id: []const u8, tool: []const u8, args_json: []const u8, sink: Sink) void {
        // S8 decisions 12 and 16: hover, scroll, navigate and reload exist only with the approval seam.
        const gated = gatedTool(tool);
        const act = actTool(tool);
        if ((gated != null or act != null) and self.approval == null) return sink.done(sink.ctx, id, .{ .failure = "tool not available" });
        const args_ok = if (gated) |g| gatedArgsOk(self.gpa, g.verb, args_json) else if (act) |a| actArgsOk(self.gpa, a.kind, args_json) else true;
        const ok = args_ok catch return sink.done(sink.ctx, id, .{ .failure = "out of memory" });
        if (!ok) return sink.done(sink.ctx, id, .{ .failure = "the tool's arguments are not valid" });
        const method = if (gated) |g| g.method else if (act) |a| a.method else toolMethod(tool) orelse return sink.done(sink.ctx, id, .{ .failure = "tool not available" });
        const params = self.bound(args_json) catch |err| return sink.done(sink.ctx, id, .{ .failure = switch (err) {
            error.WindowFixed => "window is fixed to this drawer",
            error.BadArgs => "the tool's arguments are not an object",
            error.OutOfMemory => "out of memory",
        } });
        const io = self.server.io;
        // A gated call's budget also holds its card's time (rev 16.20.37: gated calls get their
        // own deadline budget).
        const budget_ms = self.deadline_ms + if (gated != null) approval.card_ttl_ms else 0;
        const job = Job.create(self.gpa, id, method, params, sink, nowMs(io) + @as(i64, @intCast(budget_ms)), self.window) catch {
            self.gpa.free(params);
            return sink.done(sink.ctx, id, .{ .failure = "out of memory" });
        };
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.startThreads() catch {
            job.destroy();
            return sink.done(sink.ctx, id, .{ .failure = "out of memory" });
        };
        self.queue.append(self.gpa, job) catch {
            job.destroy();
            return sink.done(sink.ctx, id, .{ .failure = "out of memory" });
        };
        if (gated) |g| job.verb = g.verb;
        job.prompt = prompt_id;
        self.cond.broadcast(io);
    }

    /// Under the mutex. Named, so a test can see that none is left behind.
    fn startThreads(self: *Broker) !void {
        if (self.worker == null) {
            self.worker = try std.Thread.spawn(.{}, work, .{self});
            self.worker.?.setName(self.server.io, "zb-broker") catch {};
        }
        if (self.timer == null) {
            self.timer = try std.Thread.spawn(.{}, time, .{self});
            self.timer.?.setName(self.server.io, "zb-broker-time") catch {};
        }
    }

    /// The model's args with this drawer's window added; a window of the model's own is refused.
    fn bound(self: *Broker, args_json: []const u8) error{ OutOfMemory, WindowFixed, BadArgs }![]u8 {
        const text = std.mem.trim(u8, args_json, &std.ascii.whitespace);
        var parsed = std.json.parseFromSlice(std.json.Value, self.gpa, if (text.len == 0) "{}" else text, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.BadArgs,
        };
        defer parsed.deinit();
        if (parsed.value != .object) return error.BadArgs;
        if (parsed.value.object.contains("window_id")) return error.WindowFixed;
        var window: [24]u8 = undefined;
        try parsed.value.object.put(parsed.arena.allocator(), "window_id", .{ .string = std.fmt.bufPrint(&window, "window-{d}", .{self.window}) catch unreachable });
        return std.json.Stringify.valueAlloc(self.gpa, parsed.value, .{});
    }

    /// The one worker: each queued call in turn, one at a time.
    fn work(self: *Broker) void {
        const io = self.server.io;
        self.mutex.lockUncancelable(io);
        while (true) {
            while (!self.stopping and self.queue.items.len == 0) self.cond.waitUncancelable(io, &self.mutex);
            if (self.stopping) break;
            const job = self.queue.orderedRemove(0);
            self.running = job;
            self.mutex.unlock(io);
            job.run(self);
            self.mutex.lockUncancelable(io);
            self.running = null; // the deadline thread looks at it only under the mutex
            job.destroy();
            self.cond.broadcast(io);
        }
        self.mutex.unlock(io);
    }

    /// The deadline thread: while calls are pending, answers each whose deadline has passed.
    fn time(self: *Broker) void {
        const io = self.server.io;
        self.mutex.lockUncancelable(io);
        while (!self.stopping) {
            if (self.queue.items.len == 0 and self.running == null) {
                self.cond.waitUncancelable(io, &self.mutex);
                continue;
            }
            const now = nowMs(io);
            var i: usize = 0;
            while (i < self.queue.items.len) {
                const job = self.queue.items[i];
                if (job.deadline_at > now) {
                    i += 1;
                    continue;
                }
                _ = self.queue.orderedRemove(i); // never runs
                if (!self.detached and job.claim()) job.sink.done(job.sink.ctx, job.id, .{ .failure = timeout_text });
                job.destroy();
            }
            if (self.running) |job| {
                if (job.deadline_at <= now and !self.detached and job.claim()) job.sink.done(job.sink.ctx, job.id, .{ .failure = timeout_text });
            }
            self.mutex.unlock(io);
            io.sleep(.fromMilliseconds(5), .awake) catch {};
            self.mutex.lockUncancelable(io);
        }
        self.mutex.unlock(io);
    }

    /// The engine's reply to `method` with `params`, owned by the caller.
    fn call(self: *Broker, method: []const u8, params: []const u8) error{OutOfMemory}![]u8 {
        if (self.engine) |e| return e.call(e.ctx, self.gpa, method, params);
        return self.server.callInProcess(self.gpa, method, params);
    }

    /// The worker's answer for `job`, in one step under the mutex (rev 16.20.36): not after
    /// `detach`, and only if the deadline has not answered first. The sink must not block or
    /// call back into the broker.
    fn publish(self: *Broker, job: *Job, outcome: Outcome) void {
        defer outcome.deinit(self.gpa);
        if (self.before_publish) |h| h.run(h.ctx);
        const io = self.server.io;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (!self.detached and job.claim()) job.sink.done(job.sink.ctx, job.id, outcome.result);
    }
};

/// The app's one reaper thread (rev 16.20.35): it joins each detached broker's threads and
/// frees it, never on the GTK thread. Adopting a broker allocates nothing, so no failure can
/// make `detach` join on its caller (RoseCat 6650): the list is linked through the brokers.
/// If the thread cannot start, the brokers wait in the list for `deinit`, at app exit, after
/// the GTK loop has ended.
pub const Reaper = struct {
    io: ?std.Io = null,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    head: ?*Broker = null,
    stopping: bool = false,
    thread: ?std.Thread = null,

    /// `gpa` is not used: the Reaper allocates nothing.
    pub fn init(gpa: std.mem.Allocator) Reaper {
        _ = gpa;
        return .{};
    }

    pub fn deinit(self: *Reaper) void {
        if (self.io) |io| {
            self.mutex.lockUncancelable(io);
            self.stopping = true;
            self.cond.broadcast(io);
            self.mutex.unlock(io);
        }
        if (self.thread) |t| t.join();
        while (self.take()) |b| b.reap(); // only if the thread could not start
        self.* = undefined;
    }

    fn adopt(self: *Reaper, broker: *Broker, io: std.Io) void {
        if (self.io == null) self.io = io;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        broker.reap_next = self.head;
        self.head = broker;
        if (self.thread == null) {
            self.thread = std.Thread.spawn(.{}, reapAll, .{ self, io }) catch null;
            if (self.thread) |t| t.setName(io, "zb-reaper") catch {};
        }
        self.cond.broadcast(io);
    }

    /// Under the mutex, or once the thread has ended.
    fn take(self: *Reaper) ?*Broker {
        const b = self.head orelse return null;
        self.head = b.reap_next;
        return b;
    }

    fn reapAll(self: *Reaper, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        while (true) {
            while (!self.stopping and self.head == null) self.cond.waitUncancelable(io, &self.mutex);
            const next = self.take() orelse break; // stopping, and none left
            self.mutex.unlock(io);
            next.reap();
            self.mutex.lockUncancelable(io);
        }
        self.mutex.unlock(io);
    }
};

/// How often a card-waiting call looks at its card (Approve, expiry, a close).
const approval_poll_ms = 10;

fn nowMs(io: std.Io) i64 {
    return std.Io.Clock.now(.awake, io).toMilliseconds();
}

/// One call. The first to claim `answered` (its run, or the deadline) answers it.
const Job = struct {
    gpa: std.mem.Allocator,
    id: []u8,
    method: []const u8,
    params: []u8,
    sink: Sink,
    deadline_at: i64,
    window: u32,
    answered: std.atomic.Value(bool) = .init(false),
    /// S8 decision 16: set for navigate and reload, which the core may hold for a card.
    verb: ?approval.Verb = null,
    /// Its approved card, whose ending follows the dispatch's answer.
    card: ?approval.CardId = null,
    /// The prompt whose validated tool_call asked for it (decision 8); null: none.
    prompt: ?i64 = null,
    /// Under the broker's mutex: its prompt ended (`promptOver`), so it never dispatches.
    revoked: bool = false,

    fn create(gpa: std.mem.Allocator, id: []const u8, method: []const u8, params: []u8, sink: Sink, deadline_at: i64, window: u32) !*Job {
        const job = try gpa.create(Job);
        errdefer gpa.destroy(job);
        job.* = .{ .gpa = gpa, .id = try gpa.dupe(u8, id), .method = method, .params = params, .sink = sink, .deadline_at = deadline_at, .window = window };
        return job;
    }

    fn claim(self: *Job) bool {
        return self.answered.cmpxchgStrong(false, true, .acq_rel, .acquire) == null;
    }

    /// On the worker: the call's answer, published unless the deadline answered first.
    fn run(self: *Job, broker: *Broker) void {
        if (self.verb) |verb| {
            if (self.awaitApproval(broker, verb)) |refused| return broker.publish(self, Outcome.fail(refused));
        }
        if (self.card) |card| {
            // The dispatch boundary (RoseCat f87368e #3): checked again after the approval was seen.
            if (broker.before_dispatch) |h| h.run(h.ctx);
            if (!broker.live(self)) {
                endCard(broker.approval.?, card, .revoked);
                return broker.publish(self, Outcome.fail(cancelled_text));
            }
        }
        var ending: Ending = .done;
        const outcome = if (std.mem.eql(u8, self.method, "page.health")) self.windowInfo(broker) else if (std.mem.eql(u8, self.method, "page.screenshot")) self.screenshot(broker) else blk: {
            const reply = broker.call(self.method, self.params) catch break :blk Outcome.fail("out of memory");
            defer self.gpa.free(reply);
            if (self.card != null) ending = endingOf(self.gpa, reply);
            break :blk answer(self.gpa, reply);
        };
        if (self.card) |card| endCard(broker.approval.?, card, if (outcome.result == .content) .done else if (ending == .done) .failed else ending);
        broker.publish(self, outcome);
    }

    /// S8 decision 16: null when the call may run now (no card needed, or its card approved);
    /// else the refusal text, with nothing dispatched. The card waits in the main window's drawer
    /// with one desktop notification; the cards' own clock expires it.
    fn awaitApproval(self: *Job, broker: *Broker, verb: approval.Verb) ?[]const u8 {
        const gate = broker.approval.?;
        if (!broker.live(self)) return cancelled_text; // its prompt ended while it was queued
        const store = gate.read_selector(gate.ctx);
        if (store.unreadable) gate.report_unreadable(gate.ctx);
        if (!approval.needsCard(verb, store.selector, approval.modeOf(gate.facts(gate.ctx)))) return null;
        // Phase A: the document the card describes, which its dispatch will expect.
        var doc = self.phaseA(broker) catch |err| return switch (err) {
            error.OutOfMemory => "out of memory",
            error.Unchecked => unchecked_text,
        };
        defer doc.deinit(self.gpa);
        const card = gate.cards.present() catch return cancelled_text;
        if (gate.show) |show| show(gate.ctx, .{ .id = card, .verb = verb, .window = broker.window, .params = self.params, .origin = doc.origin, .load_serial = doc.load_serial });
        gate.notify(gate.ctx);
        while (true) {
            if (broker.before_card_look) |h| h.run(h.ctx);
            // The stop first (RoseCat 7698): a broker that stopped, or whose prompt ended
            // (decision 8), never dispatches, even when an Approve won its card after that.
            if (!broker.live(self)) {
                gate.cards.cancel(card);
                endCard(gate, card, .revoked);
                return cancelled_text;
            }
            gate.cards.expireDue();
            switch (gate.cards.outcome(card) orelse .cancelled) {
                .waiting => {},
                .approved => {
                    self.card = card;
                    return null;
                },
                .denied => {
                    endCard(gate, card, .denied);
                    return denied_text;
                },
                .expired => {
                    endCard(gate, card, .expired);
                    return not_approved_text;
                },
                .cancelled => {
                    endCard(gate, card, .cancelled);
                    return cancelled_text;
                },
            }
            broker.server.io.sleep(.fromMilliseconds(approval_poll_ms), .awake) catch {};
        }
    }

    const Document = struct {
        origin: []u8,
        load_serial: u64,

        fn deinit(self: *Document, gpa: std.mem.Allocator) void {
            gpa.free(self.origin);
        }
    };

    /// Phase A (decisions 1 and 9): the bound window's origin (the engine's own `originOf`) and
    /// load_serial from `page.list`, added to the dispatch as `options.expect`. A window that is
    /// not listed, crashed, or listed without them is Unchecked: no card.
    fn phaseA(self: *Job, broker: *Broker) error{ OutOfMemory, Unchecked }!Document {
        const gpa = self.gpa;
        var window_id: [24]u8 = undefined;
        const mine = std.fmt.bufPrint(&window_id, "window-{d}", .{self.window}) catch unreachable;
        const reply = try broker.call("page.list", "{}");
        defer gpa.free(reply);
        var parsed = (try parse(gpa, reply)) orelse return error.Unchecked;
        defer parsed.deinit();
        const result = switch (replyOf(gpa, parsed.value)) {
            .result => |r| r,
            .failure => |f| {
                f.deinit(gpa);
                return error.Unchecked;
            },
        };
        const pages = field(result, "pages", .array) orelse return error.Unchecked;
        const entry = for (pages.array.items) |page| {
            const wid = field(page, "window_id", .string) orelse continue;
            if (std.mem.eql(u8, wid.string, mine)) break page;
        } else return error.Unchecked;
        if (entry.object.get("crashed") != null) return error.Unchecked;
        const url = field(entry, "url", .string) orelse return error.Unchecked;
        const serial = field(entry, "load_serial", .integer) orelse return error.Unchecked;
        const load_serial = std.math.cast(u64, serial.integer) orelse return error.Unchecked;
        const origin = try server_mod.automation.engine.originOf(gpa, url.string);
        errdefer gpa.free(origin);

        var args = std.json.parseFromSlice(std.json.Value, gpa, self.params, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Unchecked,
        };
        defer args.deinit();
        if (args.value != .object) return error.Unchecked;
        const arena = args.arena.allocator();
        var expect: std.json.ObjectMap = .empty;
        try expect.put(arena, "origin", .{ .string = origin });
        try expect.put(arena, "load_serial", .{ .integer = @intCast(load_serial) });
        var options: std.json.ObjectMap = .empty;
        try options.put(arena, "expect", .{ .object = expect });
        try args.value.object.put(arena, "options", .{ .object = options });
        const params = try std.json.Stringify.valueAlloc(gpa, args.value, .{});
        gpa.free(self.params);
        self.params = params;
        return .{ .origin = origin, .load_serial = load_serial };
    }

    /// window_info (revs 16.20.35 and 16.20.36; RoseCat 6575, 6585, 6606): page.health answers
    /// for every window and takes no params, so only this window's entry is kept, and only its
    /// liveness fields; the URL and title are page.url's and page.title's for this window.
    /// Nothing of another window reaches the model.
    fn windowInfo(self: *Job, broker: *Broker) Outcome {
        const gpa = self.gpa;
        var window_id: [24]u8 = undefined;
        const mine = std.fmt.bufPrint(&window_id, "window-{d}", .{self.window}) catch unreachable;
        var params_buf: [64]u8 = undefined;
        const params = std.fmt.bufPrint(&params_buf, "{{\"window_id\":\"{s}\"}}", .{mine}) catch unreachable;

        const health = broker.call("page.health", "{}") catch return Outcome.fail("out of memory");
        defer gpa.free(health);
        var health_parsed = parse(gpa, health) catch return Outcome.fail("out of memory");
        defer if (health_parsed) |*p| p.deinit();
        const health_result = switch (replyOf(gpa, if (health_parsed) |p| p.value else null)) {
            .result => |r| r,
            .failure => |f| return f,
        };
        const pages = field(health_result, "pages", .array) orelse return Outcome.fail(bad_answer);
        const entry = for (pages.array.items) |page| {
            if (page != .object) continue;
            const wid = page.object.get("window_id") orelse continue;
            if (wid == .string and std.mem.eql(u8, wid.string, mine)) break page;
        } else return Outcome.fail("this window is gone");
        const responsive = field(entry, "responsive", .bool) orelse return Outcome.fail(bad_answer);
        const loading = field(entry, "loading", .bool) orelse return Outcome.fail(bad_answer);
        const dialog_open = field(entry, "dialog_open", .bool) orelse return Outcome.fail(bad_answer);
        const crashed = entry.object.get("crashed");
        if (crashed) |c| if (c != .string) return Outcome.fail(bad_answer);

        const url_reply = broker.call("page.url", params) catch return Outcome.fail("out of memory");
        defer gpa.free(url_reply);
        var url_parsed = parse(gpa, url_reply) catch return Outcome.fail("out of memory");
        defer if (url_parsed) |*p| p.deinit();
        const url = switch (replyOf(gpa, if (url_parsed) |p| p.value else null)) {
            .result => |r| field(r, "url", .string) orelse return Outcome.fail(bad_answer),
            .failure => |f| return f,
        };

        const title_reply = broker.call("page.title", params) catch return Outcome.fail("out of memory");
        defer gpa.free(title_reply);
        var title_parsed = parse(gpa, title_reply) catch return Outcome.fail("out of memory");
        defer if (title_parsed) |*p| p.deinit();
        const title = switch (replyOf(gpa, if (title_parsed) |p| p.value else null)) {
            .result => |r| field(r, "title", .string) orelse return Outcome.fail(bad_answer),
            .failure => |f| return f,
        };

        var info: std.json.ObjectMap = .empty;
        defer info.deinit(gpa);
        const entries = [_]struct { []const u8, ?std.json.Value }{
            .{ "window_id", .{ .string = mine } }, .{ "url", url },         .{ "title", title },
            .{ "responsive", responsive },         .{ "loading", loading }, .{ "dialog_open", dialog_open },
            .{ "crashed", crashed },
        };
        for (entries) |e| if (e[1]) |v| info.put(gpa, e[0], v) catch return Outcome.fail("out of memory");
        return textBlock(gpa, .{ .object = info });
    }

    /// screenshot (rev 16.20.35): `page.screenshot`'s base64 PNG, decoded and fitted into one
    /// image block of at most `image_max_b64` base64 (Broker.fit).
    fn screenshot(self: *Job, broker: *Broker) Outcome {
        const gpa = self.gpa;
        const unreadable = "the screenshot could not be read";
        const reply = broker.call(self.method, self.params) catch return Outcome.fail("out of memory");
        defer gpa.free(reply);
        var parsed = parse(gpa, reply) catch return Outcome.fail("out of memory");
        defer if (parsed) |*p| p.deinit();
        const result = switch (replyOf(gpa, if (parsed) |p| p.value else null)) {
            .result => |r| r,
            .failure => |f| return f,
        };
        const data = field(result, "data", .string) orelse return Outcome.fail(bad_answer);
        const fit = broker.fit orelse return Outcome.fail(unreadable);
        const decoder = std.base64.standard.Decoder;
        const size = decoder.calcSizeForSlice(data.string) catch return Outcome.fail(unreadable);
        const png = gpa.alloc(u8, size) catch return Outcome.fail("out of memory");
        defer gpa.free(png);
        decoder.decode(png, data.string) catch return Outcome.fail(unreadable);
        var b64: ?[*:0]u8 = null;
        var mime: ?[*:0]const u8 = null;
        const rc = fit.fit(png.ptr, png.len, image_max_b64, &b64, &mime);
        defer if (b64) |p| fit.free(p);
        if (rc == 1) return Outcome.fail("result too large");
        if (rc != 0 or b64 == null or mime == null) return Outcome.fail(unreadable);
        const content = std.json.Stringify.valueAlloc(gpa, [_]struct { type: []const u8, mime: []const u8, data_b64: []const u8 }{.{
            .type = "image",
            .mime = std.mem.span(mime.?),
            .data_b64 = std.mem.span(b64.?),
        }}, .{}) catch return Outcome.fail("out of memory");
        return .{ .result = .{ .content = content }, .owned = content };
    }

    fn destroy(self: *Job) void {
        self.gpa.free(self.id);
        self.gpa.free(self.params);
        self.gpa.destroy(self);
    }
};

const bad_answer = "the browser sent a bad answer";

/// A call's answer before its publication: the result, and the bytes it holds (if any).
const Outcome = struct {
    result: Result,
    owned: ?[]u8 = null,

    fn fail(text: []const u8) Outcome {
        return .{ .result = .{ .failure = text } };
    }

    fn deinit(self: Outcome, gpa: std.mem.Allocator) void {
        if (self.owned) |bytes| gpa.free(bytes);
    }
};

/// A carded dispatch's ending from the engine's reply: an S8 refusal (-32015) is `changed`, or
/// `crashed` for that reason; anything else is decided by the answer (`done` here).
fn endingOf(gpa: std.mem.Allocator, reply: []const u8) Ending {
    var parsed = (parse(gpa, reply) catch return .failed) orelse return .failed;
    defer parsed.deinit();
    const err = field(parsed.value, "error", .object) orelse return .done;
    const code = field(err, "code", .integer) orelse return .failed;
    if (code.integer != -32015) return .failed;
    const data = field(err, "data", .object) orelse return .changed;
    const reason = field(data, "reason", .string) orelse return .changed;
    return if (std.mem.eql(u8, reason.string, "crashed")) .crashed else .changed;
}

/// The parsed reply, or null if it is no JSON.
fn parse(gpa: std.mem.Allocator, reply: []const u8) error{OutOfMemory}!?std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, gpa, reply, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
}

/// Rev 16.20.36 (RoseCat 6606): a reply is a genuine engine error (an `error` object and no
/// `result`), mapped to its redacted text; a success (a `result` and no `error`); or anything
/// else, the fixed bad answer.
fn replyOf(gpa: std.mem.Allocator, reply: ?std.json.Value) union(enum) { result: std.json.Value, failure: Outcome } {
    const obj = if (reply) |r| (if (r == .object) r.object else null) else null;
    const o = obj orelse return .{ .failure = Outcome.fail(bad_answer) };
    const result, const err = .{ o.get("result"), o.get("error") };
    if (result != null and err == null) return .{ .result = result.? };
    if (result == null and err != null and err.? == .object) return .{ .failure = redacted(gpa, err.?.object) };
    return .{ .failure = Outcome.fail(bad_answer) };
}

/// `value`'s `key`, if `value` is an object and that key has the tag `tag`.
fn field(value: std.json.Value, key: []const u8, comptime tag: std.meta.Tag(std.json.Value)) ?std.json.Value {
    if (value != .object) return null;
    const v = value.object.get(key) orelse return null;
    return if (v == tag) v else null;
}

/// One text block holding `value`'s JSON.
fn textBlock(gpa: std.mem.Allocator, value: std.json.Value) Outcome {
    const text = std.json.Stringify.valueAlloc(gpa, value, .{}) catch return Outcome.fail("out of memory");
    defer gpa.free(text);
    const content = std.json.Stringify.valueAlloc(gpa, [_]struct { type: []const u8, text: []const u8 }{.{ .type = "text", .text = text }}, .{}) catch
        return Outcome.fail("out of memory");
    return .{ .result = .{ .content = content }, .owned = content };
}

/// A single-method tool's answer for a JSON-RPC `reply`: its result as one text block, or the
/// failure (S7.7: the error's data and message never reach the model).
fn answer(gpa: std.mem.Allocator, reply: []const u8) Outcome {
    var parsed = parse(gpa, reply) catch return Outcome.fail("out of memory");
    defer if (parsed) |*p| p.deinit();
    return switch (replyOf(gpa, if (parsed) |p| p.value else null)) {
        .result => |r| textBlock(gpa, r),
        .failure => |f| f,
    };
}

/// An engine error's fixed text: its name and code, never its data or message text.
fn redacted(gpa: std.mem.Allocator, err: std.json.ObjectMap) Outcome {
    const code = if (err.get("code")) |c| (if (c == .integer) c.integer else 0) else 0;
    const name = if (err.get("message")) |m| (if (m == .string and isName(m.string)) m.string else "failed") else "failed";
    if (code == -32013) return Outcome.fail("the page has a dialog open");
    const text = std.fmt.allocPrint(gpa, "the browser could not do that ({s}, {d})", .{ name, code }) catch return Outcome.fail("the browser could not do that");
    return .{ .result = .{ .failure = text }, .owned = text };
}

/// An engine error name: lowercase letters, digits, '_' and ' ' only, so no page text rides on it.
fn isName(text: []const u8) bool {
    if (text.len == 0 or text.len > 64) return false;
    for (text) |c| {
        if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_' or c == ' ')) return false;
    }
    return true;
}
