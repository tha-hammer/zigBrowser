//! MS8.2a part 1 red (macOS plan MS8.2; chat-drawer plan D7, D7b, S3, S5d, S7b, S8 decision 8): the
//! portable helper core, the chat helper's process side as src/agent_helper.c has it on Linux, with
//! no GLib. It runs on the app's main thread and reaches the world only through its `Ports`
//! (home lock, config check, network, token fetch, spawn, write, kill, timers; the drawer; the
//! brokers). Every port's answer comes back on the main thread as a Core call. macOS uses it as
//! production (MS8.2c); here it is driven with recording fake ports: no process, display or signal.
//!
//! The chat path, as agent_helper.c does it:
//! - the first Send of a window takes the home lock, then runs the window's config check; nothing
//!   starts before the check answers;
//! - a passed check starts the agent: status `starting`, the network, then a token fetch, then
//!   exactly one spawn with that token; nothing is written to the helper before its `ready`;
//! - `ready`: status `ready`, the `hello` frame, then the window's `open_session` (session
//!   `s-<win>-<k>`); its prompt waits for `session_opened` (S5d), then goes, status `busy`;
//! - deltas and the message reach the window's drawer; the `result` ends the prompt: its cards
//!   (`prompt_over`, decision 8), the drawer's `end`, status `ready`; a prompt queued meanwhile goes
//!   then;
//! - a `tool_call` reaches the window's broker with its prompt; the broker's answer is written as
//!   one `tool_result` to the session that asked, and a failure also gives the drawer
//!   "Browser tool failed: <text>" (S7.7);
//! - Stop: the running prompt's cards end at once, `interrupt` is written, the prompt's later
//!   frames are dropped, and its `result` shows `stopped`;
//! - a window closed: `end_session` written, its broker done; a later `tool_call` for that session
//!   is answered "tool not available" with no broker;
//! - a crash: status `crashed` (`exit-<n>`) and "Agent stopped (exit <n>). Send to restart." for
//!   every window; the next Send restarts it after the first backoff, 1 s.
//!
//! The core re-exports the agent_frames module it uses (`core.frames`): one validator, one output
//! sequence. On HEAD there is no src/agent_helper_core.zig: this file does not compile (the red).

const std = @import("std");
const core = @import("agent_helper_core");

const testing = std.testing;
const gpa = testing.allocator;

const tool_id = "6f1c2a9e-3b4d-4e5f-8a7b-0c1d2e3f4a5b";
const ready_line = "{\"v\":1,\"seq\":1,\"type\":\"ready\",\"version\":\"0.1.0\",\"route\":\"R1\",\"selfcheck\":{\"ok\":true,\"failures\":[]},\"tool_deadline_s\":120}";

fn line(comptime seq: u32, comptime body: []const u8) []const u8 {
    return std.fmt.comptimePrint("{{\"v\":1,\"seq\":{d},{s}}}", .{ seq, body });
}

fn resultBody(comptime session: []const u8, comptime prompt: u32) []const u8 {
    return std.fmt.comptimePrint("\"type\":\"result\",\"session\":\"{s}\",\"prompt_id\":{d},\"sdk_session_id\":\"x\",\"subtype\":\"success\",\"is_error\":false,\"num_turns\":1,\"cost_usd\":null", .{ session, prompt });
}

/// Every port call, in order, as one line of text; the frames written, parsed.
const Rec = struct {
    events: std.ArrayListUnmanaged([]u8) = .empty,
    frames: std.ArrayListUnmanaged([]u8) = .empty,
    lock: core.Lock = .ok,
    net: core.Net = .ready,
    spawn: core.Spawn = .started,
    now: u64 = 10_000,
    max: usize = 64 * 1024,

    fn deinit(self: *Rec) void {
        for (self.events.items) |e| gpa.free(e);
        self.events.deinit(gpa);
        for (self.frames.items) |f| gpa.free(f);
        self.frames.deinit(gpa);
    }
    fn add(self: *Rec, comptime fmt: []const u8, args: anytype) void {
        self.events.append(gpa, std.fmt.allocPrint(gpa, fmt, args) catch @panic("oom")) catch @panic("oom");
    }
    fn of(ctx: *anyopaque) *Rec {
        return @ptrCast(@alignCast(ctx));
    }
    /// Events since `from`, so a test reads exactly what one step did.
    fn since(self: *Rec, from: usize) []const []u8 {
        return self.events.items[from..];
    }
    fn has(self: *Rec, from: usize, want: []const u8) bool {
        for (self.since(from)) |e| if (std.mem.eql(u8, e, want)) return true;
        return false;
    }
    fn count(self: *Rec, from: usize, prefix: []const u8) usize {
        var n: usize = 0;
        for (self.since(from)) |e| {
            if (std.mem.startsWith(u8, e, prefix)) n += 1;
        }
        return n;
    }
    /// The `type` of each frame written since frame index `from`.
    fn types(self: *Rec, from: usize, out: *[16][]const u8) [][]const u8 {
        var n: usize = 0;
        for (self.frames.items[from..]) |f| {
            if (n == out.len) break;
            out[n] = jsonString(f, "type") orelse "?";
            n += 1;
        }
        return out[0..n];
    }

    fn homeLock(ctx: *anyopaque) core.Lock {
        of(ctx).add("lock", .{});
        return of(ctx).lock;
    }
    fn configCheck(ctx: *anyopaque, win: u32) void {
        of(ctx).add("config_check {d}", .{win});
    }
    fn netEnsure(ctx: *anyopaque) core.Net {
        of(ctx).add("net", .{});
        return of(ctx).net;
    }
    fn tokenFetch(ctx: *anyopaque, gen: u32) void {
        of(ctx).add("token_fetch {d}", .{gen});
    }
    fn spawnHelper(ctx: *anyopaque, token: []const u8) core.Spawn {
        of(ctx).add("spawn {s}", .{token});
        return of(ctx).spawn;
    }
    fn write(ctx: *anyopaque, frame: []const u8) void {
        const self = of(ctx);
        self.frames.append(gpa, gpa.dupe(u8, frame) catch @panic("oom")) catch @panic("oom");
        self.add("write {s}", .{jsonString(frame, "type") orelse "?"});
    }
    fn kill(ctx: *anyopaque, signal: core.Signal) void {
        of(ctx).add("kill {s}", .{@tagName(signal)});
    }
    fn timer(ctx: *anyopaque, which: core.Timer, ms: u64) void {
        of(ctx).add("timer {s} {d}", .{ @tagName(which), ms });
    }
    fn nowMs(ctx: *anyopaque) u64 {
        return of(ctx).now;
    }
    fn status(ctx: *anyopaque, win: u32, state: []const u8, reason: []const u8) void {
        of(ctx).add("status {d} {s} {s}", .{ win, state, reason });
    }
    fn message(ctx: *anyopaque, win: u32, kind: []const u8, text: []const u8) void {
        of(ctx).add("message {d} {s} {s}", .{ win, kind, text });
    }
    fn delta(ctx: *anyopaque, win: u32, session: []const u8, text: []const u8) void {
        of(ctx).add("delta {d} {s} {s}", .{ win, session, text });
    }
    fn end(ctx: *anyopaque, win: u32) void {
        of(ctx).add("end {d}", .{win});
    }
    fn stopped(ctx: *anyopaque, win: u32) void {
        of(ctx).add("stopped {d}", .{win});
    }
    fn capped(ctx: *anyopaque, win: u32) void {
        of(ctx).add("capped {d}", .{win});
    }
    fn replyMax(ctx: *anyopaque) usize {
        return of(ctx).max;
    }
    fn toolsCall(ctx: *anyopaque, win: u32, session: []const u8, prompt_id: i64, id: []const u8, tool: []const u8, args: []const u8) void {
        of(ctx).add("tools_call {d} {s} {d} {s} {s} {s}", .{ win, session, prompt_id, id, tool, args });
    }
    fn promptOver(ctx: *anyopaque, win: u32, prompt_id: i64) void {
        of(ctx).add("prompt_over {d} {d}", .{ win, prompt_id });
    }
    fn windowDone(ctx: *anyopaque, win: u32) void {
        of(ctx).add("window_done {d}", .{win});
    }
    fn detachAll(ctx: *anyopaque) void {
        of(ctx).add("detach_all", .{});
    }

    fn ports(self: *Rec) core.Ports {
        return .{
            .ctx = self,
            .home_lock = homeLock,
            .config_check = configCheck,
            .net_ensure = netEnsure,
            .token_fetch = tokenFetch,
            .spawn = spawnHelper,
            .write = write,
            .kill = kill,
            .timer = timer,
            .now_ms = nowMs,
            .drawer = .{ .status = status, .message = message, .delta = delta, .end = end, .stopped = stopped, .capped = capped, .reply_content_max = replyMax },
            .tools = .{ .call = toolsCall, .prompt_over = promptOver, .window_done = windowDone, .detach_all = detachAll },
        };
    }
};

/// A top-level string field of a JSON object, or null (frames are small; this is a test helper).
fn jsonString(json: []const u8, comptime key: []const u8) ?[]const u8 {
    const needle = "\"" ++ key ++ "\":\"";
    const at = std.mem.indexOf(u8, json, needle) orelse return null;
    const start = at + needle.len;
    const stop = std.mem.indexOfScalarPos(u8, json, start, '"') orelse return null;
    return json[start..stop];
}

const Bench = struct {
    rec: Rec = .{},
    c: core.Core = undefined,

    fn create() !*Bench {
        const self = try gpa.create(Bench);
        self.* = .{};
        try core.frames.setHello("/tmp/zb-core-test-home", null);
        self.c = core.Core.init(gpa, self.rec.ports(), .{ .home = "/tmp/zb-core-test-home" });
        return self;
    }
    fn destroy(self: *Bench) void {
        self.c.deinit();
        self.rec.deinit();
        gpa.destroy(self);
    }
    /// The first Send of window `win`, through the check and the token, to a started helper.
    fn started(self: *Bench, win: u32, text: []const u8) !void {
        self.c.send(win, text);
        self.c.configChecked(win, false);
        self.c.tokenFetched(self.c.tokenGeneration(), "sk-ant-oat01-core-test-token");
    }
    /// ... then ready and the window's session opened: its first prompt is running.
    fn running(self: *Bench, win: u32, text: []const u8) !void {
        try self.started(win, text);
        self.c.line(ready_line);
        self.c.line(line(2, "\"type\":\"session_opened\",\"session\":\"s-1-1\""));
    }
};

test "the first Send takes the home lock, runs the window's config check, and starts nothing before it answers" {
    const b = try Bench.create();
    defer b.destroy();
    b.c.send(1, "hello");
    try testing.expect(b.rec.has(0, "lock"));
    try testing.expect(b.rec.has(0, "config_check 1"));
    try testing.expectEqual(@as(usize, 0), b.rec.count(0, "net"));
    try testing.expectEqual(@as(usize, 0), b.rec.count(0, "spawn"));
    try testing.expectEqual(@as(usize, 0), b.rec.frames.items.len);
}

test "a passed check starts the agent: starting, the network, the token, then one spawn with it; nothing written before ready" {
    const b = try Bench.create();
    defer b.destroy();
    b.c.send(1, "hello");
    const at = b.rec.events.items.len;
    b.c.configChecked(1, false);
    try testing.expect(b.rec.has(at, "status 0 starting -"));
    try testing.expect(b.rec.has(at, "net"));
    try testing.expectEqual(@as(usize, 1), b.rec.count(at, "token_fetch"));
    try testing.expectEqual(@as(usize, 0), b.rec.count(at, "spawn"));
    const fetched = b.rec.events.items.len;
    b.c.tokenFetched(b.c.tokenGeneration(), "sk-ant-oat01-core-test-token");
    try testing.expect(b.rec.has(fetched, "spawn sk-ant-oat01-core-test-token"));
    try testing.expectEqual(@as(usize, 1), b.rec.count(0, "spawn"));
    try testing.expectEqual(@as(usize, 0), b.rec.frames.items.len);
}

test "ready: hello then the window's open_session; the prompt waits for session_opened, then goes, busy" {
    const b = try Bench.create();
    defer b.destroy();
    try b.started(1, "hello");
    const at = b.rec.events.items.len;
    b.c.line(ready_line);
    try testing.expect(b.rec.has(at, "status 0 ready -"));
    var buf: [16][]const u8 = undefined;
    const before = b.rec.types(0, &buf);
    try testing.expectEqual(@as(usize, 2), before.len);
    try testing.expectEqualStrings("hello", before[0]);
    try testing.expectEqualStrings("open_session", before[1]);
    const opened = b.rec.events.items.len;
    b.c.line(line(2, "\"type\":\"session_opened\",\"session\":\"s-1-1\""));
    const after = b.rec.types(2, &buf);
    try testing.expectEqual(@as(usize, 1), after.len);
    try testing.expectEqualStrings("prompt", after[0]);
    try testing.expectEqualStrings("s-1-1", jsonString(b.rec.frames.items[2], "session").?);
    try testing.expectEqualStrings("hello", jsonString(b.rec.frames.items[2], "text").?);
    try testing.expect(b.rec.has(opened, "status 1 busy -"));
}

test "the reply: deltas and the message reach the window; the result ends it (cards, end, ready) and a queued prompt goes then" {
    const b = try Bench.create();
    defer b.destroy();
    try b.running(1, "first");
    b.c.send(1, "second"); // queued: one prompt runs per session
    try testing.expectEqual(@as(usize, 3), b.rec.frames.items.len);
    const at = b.rec.events.items.len;
    b.c.line(line(3, "\"type\":\"assistant_delta\",\"session\":\"s-1-1\",\"prompt_id\":1,\"text\":\"Hel\""));
    b.c.line(line(4, "\"type\":\"assistant_message\",\"session\":\"s-1-1\",\"prompt_id\":1,\"text\":\"Hello there\""));
    try testing.expect(b.rec.has(at, "delta 1 s-1-1 Hel"));
    try testing.expect(b.rec.has(at, "message 1 assistant Hello there"));
    const done = b.rec.events.items.len;
    b.c.line(line(5, resultBody("s-1-1", 1)));
    try testing.expect(b.rec.has(done, "prompt_over 1 1"));
    try testing.expect(b.rec.has(done, "end 1"));
    try testing.expect(b.rec.has(done, "status 1 ready -"));
    try testing.expectEqual(@as(usize, 4), b.rec.frames.items.len);
    try testing.expectEqualStrings("prompt", jsonString(b.rec.frames.items[3], "type").?);
    try testing.expectEqualStrings("second", jsonString(b.rec.frames.items[3], "text").?);
}

test "a tool_call reaches the window's broker with its prompt; the answer is one tool_result, and a failure also tells the drawer" {
    const b = try Bench.create();
    defer b.destroy();
    try b.running(1, "read it");
    const at = b.rec.events.items.len;
    b.c.line(line(3, "\"type\":\"tool_call\",\"session\":\"s-1-1\",\"prompt_id\":1,\"id\":\"" ++ tool_id ++ "\",\"tool\":\"mcp__zigbrowser__get_text\",\"args\":{\"selector\":\"css=#greeting\"}"));
    try testing.expect(b.rec.has(at, "tools_call 1 s-1-1 1 " ++ tool_id ++ " mcp__zigbrowser__get_text {\"selector\":\"css=#greeting\"}"));
    const frames_before = b.rec.frames.items.len;
    b.c.toolResult(1, "s-1-1", tool_id, true, "[{\"type\":\"text\",\"text\":\"Hello from page 1\"}]");
    try testing.expectEqual(frames_before + 1, b.rec.frames.items.len);
    try testing.expectEqualStrings("tool_result", jsonString(b.rec.frames.items[frames_before], "type").?);
    try testing.expectEqualStrings(tool_id, jsonString(b.rec.frames.items[frames_before], "id").?);
    try testing.expectEqual(@as(usize, 0), b.rec.count(at, "message 1 error"));
    const failed = b.rec.events.items.len;
    b.c.toolResult(1, "s-1-1", tool_id, false, "tool not available");
    try testing.expectEqual(frames_before + 2, b.rec.frames.items.len);
    try testing.expect(b.rec.has(failed, "message 1 error Browser tool failed: tool not available"));
    // An answer for a session that is not the window's open one is dropped.
    b.c.toolResult(1, "s-1-9", tool_id, true, "[]");
    b.c.toolResult(7, "s-7-1", tool_id, true, "[]");
    try testing.expectEqual(frames_before + 2, b.rec.frames.items.len);
}

test "Stop: the prompt's cards end at once, interrupt is written, its later frames are dropped, and its result shows stopped" {
    const b = try Bench.create();
    defer b.destroy();
    try b.running(1, "long");
    const at = b.rec.events.items.len;
    const frames_before = b.rec.frames.items.len;
    b.c.interrupt(1);
    try testing.expect(b.rec.has(at, "prompt_over 1 1"));
    try testing.expectEqual(frames_before + 1, b.rec.frames.items.len);
    try testing.expectEqualStrings("interrupt", jsonString(b.rec.frames.items[frames_before], "type").?);
    b.c.interrupt(1); // a second Stop writes nothing more
    try testing.expectEqual(frames_before + 1, b.rec.frames.items.len);
    const late = b.rec.events.items.len;
    b.c.line(line(3, "\"type\":\"assistant_delta\",\"session\":\"s-1-1\",\"prompt_id\":1,\"text\":\"late\""));
    b.c.line(line(4, "\"type\":\"assistant_message\",\"session\":\"s-1-1\",\"prompt_id\":1,\"text\":\"late too\""));
    try testing.expectEqual(@as(usize, 0), b.rec.count(late, "delta"));
    try testing.expectEqual(@as(usize, 0), b.rec.count(late, "message"));
    b.c.line(line(5, resultBody("s-1-1", 1)));
    try testing.expect(b.rec.has(late, "stopped 1"));
    try testing.expectEqual(@as(usize, 0), b.rec.count(late, "end 1"));
    try testing.expect(b.rec.has(late, "status 1 ready -"));
}

test "a window closed: end_session written and its broker done; a later tool_call of its session gets 'tool not available'" {
    const b = try Bench.create();
    defer b.destroy();
    try b.running(1, "hi");
    const at = b.rec.events.items.len;
    const frames_before = b.rec.frames.items.len;
    b.c.windowClosed(1);
    try testing.expectEqual(frames_before + 1, b.rec.frames.items.len);
    try testing.expectEqualStrings("end_session", jsonString(b.rec.frames.items[frames_before], "type").?);
    try testing.expect(b.rec.has(at, "window_done 1"));
    const late = b.rec.events.items.len;
    b.c.line(line(3, "\"type\":\"tool_call\",\"session\":\"s-1-1\",\"prompt_id\":1,\"id\":\"" ++ tool_id ++ "\",\"tool\":\"mcp__zigbrowser__get_text\",\"args\":{}"));
    try testing.expectEqual(@as(usize, 0), b.rec.count(late, "tools_call"));
    try testing.expectEqual(frames_before + 2, b.rec.frames.items.len);
    const answer = b.rec.frames.items[frames_before + 1];
    try testing.expectEqualStrings("tool_result", jsonString(answer, "type").?);
    try testing.expect(std.mem.indexOf(u8, answer, "tool not available") != null);
}

test "a crash: crashed status and text for every window; the next Send restarts after the first backoff, 1 s" {
    const b = try Bench.create();
    defer b.destroy();
    try b.running(1, "hi");
    const at = b.rec.events.items.len;
    b.c.exited(.{ .code = 1 });
    try testing.expect(b.rec.has(at, "status 0 crashed exit-1"));
    try testing.expect(b.rec.has(at, "message 0 system Agent stopped (exit 1). Send to restart."));
    try testing.expect(b.rec.has(at, "detach_all")); // the dead helper's calls end with it
    const resend = b.rec.events.items.len;
    b.c.send(1, "again"); // its session died with the helper: a new one is checked first
    try testing.expect(b.rec.has(resend, "config_check 1"));
    b.c.configChecked(1, false);
    try testing.expect(b.rec.has(resend, "timer restart 1000"));
    try testing.expectEqual(@as(usize, 0), b.rec.count(resend, "spawn"));
    b.rec.now += 1000;
    b.c.timerDue(.restart);
    try testing.expect(b.rec.has(resend, "status 0 starting -"));
    try testing.expectEqual(@as(usize, 1), b.rec.count(resend, "token_fetch"));
    b.c.tokenFetched(b.c.tokenGeneration(), "sk-ant-oat01-core-test-token");
    try testing.expectEqual(@as(usize, 1), b.rec.count(resend, "spawn"));
}
