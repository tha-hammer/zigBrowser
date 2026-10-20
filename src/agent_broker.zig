//! S7a (chat-drawer plan section 10, S7, revs 16.20.30 and 16.20.32): the drawer's broker
//! between its helper's browser tool calls and the automation core, in process
//! (AutomationApiServer.callInProcess; no socket, no auth).
//!
//! - Before S8 the model has read tools only (S7.5): six tools over the eight read methods.
//!   Anything else is "tool not available" and reaches no engine (S7.3, S7.8).
//! - A drawer's calls run on its own window: the broker adds `window_id`, and a `window_id` in
//!   the model's args is refused (S7.2).
//! - The engine's error data never reaches the model: a failure is a fixed text and the error's
//!   name (S7.7).
//! - `submit` returns at once. A session's calls run one at a time, in order, on its one worker
//!   thread, never the caller's (the GTK thread in the app) (D8). Each gets exactly one answer:
//!   the engine's, or at the deadline "The browser did not answer in time." (a queued call is
//!   then never run; a running one's late engine completion is discarded).
const std = @import("std");
const server_mod = @import("automation_server.zig");

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

/// A call's one answer: `.content`, the tool_result content (a JSON array), or `.failure`,
/// its error text. Valid only during the sink's call.
pub const Result = union(enum) { content: []const u8, failure: []const u8 };

pub const Sink = struct {
    ctx: *anyopaque,
    done: *const fn (ctx: *anyopaque, id: []const u8, result: Result) void,
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
    worker: ?std.Thread = null,
    timer: ?std.Thread = null,

    pub fn init(gpa: std.mem.Allocator, server: *Server, window: u32, deadline_ms: u64) Broker {
        return .{ .gpa = gpa, .server = server, .window = window, .deadline_ms = deadline_ms };
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
        const method = toolMethod(tool) orelse return sink.done(sink.ctx, id, .{ .failure = "tool not available" });
        const params = self.bound(args_json) catch |err| return sink.done(sink.ctx, id, .{ .failure = switch (err) {
            error.WindowFixed => "window is fixed to this drawer",
            error.BadArgs => "the tool's arguments are not an object",
            error.OutOfMemory => "out of memory",
        } });
        const io = self.server.io;
        const job = Job.create(self.gpa, id, method, params, sink, nowMs(io) + @as(i64, @intCast(self.deadline_ms))) catch {
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
        self.cond.broadcast(io);
    }

    /// Under the mutex.
    fn startThreads(self: *Broker) !void {
        if (self.worker == null) self.worker = try std.Thread.spawn(.{}, work, .{self});
        if (self.timer == null) self.timer = try std.Thread.spawn(.{}, time, .{self});
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
            job.run(self.server);
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
                if (job.claim()) job.sink.done(job.sink.ctx, job.id, .{ .failure = timeout_text });
                job.destroy();
            }
            if (self.running) |job| {
                if (job.deadline_at <= now and job.claim()) job.sink.done(job.sink.ctx, job.id, .{ .failure = timeout_text });
            }
            self.mutex.unlock(io);
            io.sleep(.fromMilliseconds(5), .awake) catch {};
            self.mutex.lockUncancelable(io);
        }
        self.mutex.unlock(io);
    }
};

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
    answered: std.atomic.Value(bool) = .init(false),

    fn create(gpa: std.mem.Allocator, id: []const u8, method: []const u8, params: []u8, sink: Sink, deadline_at: i64) !*Job {
        const job = try gpa.create(Job);
        errdefer gpa.destroy(job);
        job.* = .{ .gpa = gpa, .id = try gpa.dupe(u8, id), .method = method, .params = params, .sink = sink, .deadline_at = deadline_at };
        return job;
    }

    fn claim(self: *Job) bool {
        return self.answered.cmpxchgStrong(false, true, .acq_rel, .acquire) == null;
    }

    /// On the worker: the engine's answer, unless the deadline answered first.
    fn run(self: *Job, server: *Server) void {
        const reply = server.callInProcess(self.gpa, self.method, self.params) catch {
            if (self.claim()) self.sink.done(self.sink.ctx, self.id, .{ .failure = "out of memory" });
            return;
        };
        defer self.gpa.free(reply);
        if (!self.claim()) return; // the deadline answered first: discarded
        answer(self.gpa, self.id, reply, self.sink);
    }

    fn destroy(self: *Job) void {
        self.gpa.free(self.id);
        self.gpa.free(self.params);
        self.gpa.destroy(self);
    }
};

/// The sink's answer for a JSON-RPC `reply`: its result as one text block, or a fixed text
/// naming the error (S7.7: the error's data and message never reach the model).
fn answer(gpa: std.mem.Allocator, id: []const u8, reply: []const u8, sink: Sink) void {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, reply, .{}) catch
        return sink.done(sink.ctx, id, .{ .failure = "the browser sent a bad answer" });
    defer parsed.deinit();
    const obj = if (parsed.value == .object) parsed.value.object else return sink.done(sink.ctx, id, .{ .failure = "the browser sent a bad answer" });
    if (obj.get("result")) |result| {
        const text = std.json.Stringify.valueAlloc(gpa, result, .{}) catch return sink.done(sink.ctx, id, .{ .failure = "out of memory" });
        defer gpa.free(text);
        const content = std.json.Stringify.valueAlloc(gpa, [_]struct { type: []const u8, text: []const u8 }{.{ .type = "text", .text = text }}, .{}) catch
            return sink.done(sink.ctx, id, .{ .failure = "out of memory" });
        defer gpa.free(content);
        return sink.done(sink.ctx, id, .{ .content = content });
    }
    const err = if (obj.get("error")) |e| (if (e == .object) e.object else null) else null;
    const code = if (err) |e| (if (e.get("code")) |c| (if (c == .integer) c.integer else 0) else 0) else 0;
    const name = if (err) |e| (if (e.get("message")) |m| (if (m == .string and isName(m.string)) m.string else "failed") else "failed") else "failed";
    var buf: [160]u8 = undefined;
    const text = switch (code) {
        -32013 => "the page has a dialog open",
        else => std.fmt.bufPrint(&buf, "the browser could not do that ({s}, {d})", .{ name, code }) catch "the browser could not do that",
    };
    sink.done(sink.ctx, id, .{ .failure = text });
}

/// An engine error name: lowercase letters, digits, '_' and ' ' only, so no page text rides on it.
fn isName(text: []const u8) bool {
    if (text.len == 0 or text.len > 64) return false;
    for (text) |c| {
        if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_' or c == ' ')) return false;
    }
    return true;
}
