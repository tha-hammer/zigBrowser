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
//! - two windows: each has its own session (`s-1-1`, `s-2-1`) and prompt ids; one window's Stop,
//!   tool call, close or session end never reaches the other; after Stop and the next prompt, the
//!   old prompt's late frames (delta, message, result, error) are rejected by the validator and
//!   never append to, end, stop or release the new one.
//!
//! Every step asserts the exact list of port calls it made, in order (RoseCat c5cc3b2), and the
//! window, session, prompt and tool ids each one carries.
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
    /// Exactly these port calls since `from`, in this order, and nothing else.
    fn expect(self: *Rec, from: usize, want: []const []const u8) !void {
        const got = self.since(from);
        var same = got.len == want.len;
        if (same) {
            for (got, want) |g, w| {
                if (!std.mem.eql(u8, g, w)) same = false;
            }
        }
        if (same) return;
        std.debug.print("\nwant {d} events:\n", .{want.len});
        for (want) |w| std.debug.print("  {s}\n", .{w});
        std.debug.print("got {d}:\n", .{got.len});
        for (got) |g| std.debug.print("  {s}\n", .{g});
        return error.TestUnexpectedEvents;
    }
    /// The frame written at index `i`.
    fn frameAt(self: *Rec, i: usize) []const u8 {
        return self.frames.items[i];
    }
    /// A mark: the next step's events and frames start here.
    fn mark(self: *Rec) Mark {
        return .{ .events = self.events.items.len, .frames = self.frames.items.len };
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

/// A top-level integer field of a JSON object, or null.
fn jsonInt(json: []const u8, comptime key: []const u8) ?i64 {
    const needle = "\"" ++ key ++ "\":";
    const at = std.mem.indexOf(u8, json, needle) orelse return null;
    var end = at + needle.len;
    while (end < json.len and std.ascii.isDigit(json[end])) end += 1;
    return std.fmt.parseInt(i64, json[at + needle.len .. end], 10) catch null;
}

const Mark = struct { events: usize, frames: usize };

/// The frame written at `i`: its type, session and prompt id (null when it has none).
fn expectFrame(rec: *Rec, i: usize, typ: []const u8, session: ?[]const u8, prompt_id: ?i64) !void {
    try testing.expect(i < rec.frames.items.len);
    const f = rec.frameAt(i);
    try testing.expectEqualStrings(typ, jsonString(f, "type") orelse "?");
    if (session) |want| try testing.expectEqualStrings(want, jsonString(f, "session") orelse "?");
    try testing.expectEqual(prompt_id, jsonInt(f, "prompt_id"));
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


const test_token = "sk-ant-oat01-core-test-token";
const tool_id_2 = "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d";

fn tokenFetchEvent(buf: []u8, b: *Bench) []const u8 {
    return std.fmt.bufPrint(buf, "token_fetch {d}", .{b.c.tokenGeneration()}) catch unreachable;
}

test "the first Send takes the home lock, then runs the window's config check, and starts nothing before it answers" {
    const b = try Bench.create();
    defer b.destroy();
    b.c.send(1, "hello");
    try b.rec.expect(0, &.{ "lock", "config_check 1" });
    try testing.expectEqual(@as(usize, 0), b.rec.frames.items.len);
}

test "a passed check starts the agent: starting, the network, the token, then one spawn with it; nothing written before ready" {
    const b = try Bench.create();
    defer b.destroy();
    b.c.send(1, "hello");
    const checked = b.rec.mark();
    b.c.configChecked(1, false);
    var buf: [32]u8 = undefined;
    try b.rec.expect(checked.events, &.{ "lock", "status 0 starting -", "net", tokenFetchEvent(&buf, b) });
    const fetched = b.rec.mark();
    b.c.tokenFetched(b.c.tokenGeneration(), test_token);
    try b.rec.expect(fetched.events, &.{"spawn " ++ test_token});
    try testing.expectEqual(@as(usize, 0), b.rec.frames.items.len);
}

test "ready: hello then the window's open_session; the prompt waits for session_opened, then goes, busy" {
    const b = try Bench.create();
    defer b.destroy();
    try b.started(1, "hello");
    const ready = b.rec.mark();
    b.c.line(ready_line);
    try b.rec.expect(ready.events, &.{ "status 0 ready -", "write hello", "write open_session" });
    try expectFrame(&b.rec, 0, "hello", null, null);
    try expectFrame(&b.rec, 1, "open_session", "s-1-1", null);
    const opened = b.rec.mark();
    b.c.line(line(2, "\"type\":\"session_opened\",\"session\":\"s-1-1\""));
    try b.rec.expect(opened.events, &.{ "write prompt", "status 1 busy -" });
    try expectFrame(&b.rec, 2, "prompt", "s-1-1", 1);
    try testing.expectEqualStrings("hello", jsonString(b.rec.frameAt(2), "text").?);
}

test "the reply: deltas and the message reach the window; the result ends it (cards, end, ready), then the queued prompt goes" {
    const b = try Bench.create();
    defer b.destroy();
    try b.running(1, "first");
    const queued = b.rec.mark();
    b.c.send(1, "second"); // queued: one prompt runs per session
    try b.rec.expect(queued.events, &.{});
    try testing.expectEqual(@as(usize, 3), b.rec.frames.items.len);
    const reply = b.rec.mark();
    b.c.line(line(3, "\"type\":\"assistant_delta\",\"session\":\"s-1-1\",\"prompt_id\":1,\"text\":\"Hel\""));
    b.c.line(line(4, "\"type\":\"assistant_message\",\"session\":\"s-1-1\",\"prompt_id\":1,\"text\":\"Hello there\""));
    try b.rec.expect(reply.events, &.{ "delta 1 s-1-1 Hel", "message 1 assistant Hello there" });
    const done = b.rec.mark();
    b.c.line(line(5, resultBody("s-1-1", 1)));
    try b.rec.expect(done.events, &.{ "prompt_over 1 1", "end 1", "status 1 ready -", "write prompt", "status 1 busy -" });
    try expectFrame(&b.rec, 3, "prompt", "s-1-1", 2);
    try testing.expectEqualStrings("second", jsonString(b.rec.frameAt(3), "text").?);
}

test "a tool_call reaches the window's broker with its prompt; the answer is one tool_result, and a failure also tells the drawer" {
    const b = try Bench.create();
    defer b.destroy();
    try b.running(1, "read it");
    const call = b.rec.mark();
    b.c.line(line(3, "\"type\":\"tool_call\",\"session\":\"s-1-1\",\"prompt_id\":1,\"id\":\"" ++ tool_id ++ "\",\"tool\":\"mcp__zigbrowser__get_text\",\"args\":{\"selector\":\"css=#greeting\"}"));
    try b.rec.expect(call.events, &.{"tools_call 1 s-1-1 1 " ++ tool_id ++ " mcp__zigbrowser__get_text {\"selector\":\"css=#greeting\"}"});
    const ok = b.rec.mark();
    b.c.toolResult(1, "s-1-1", tool_id, true, "[{\"type\":\"text\",\"text\":\"Hello from page 1\"}]");
    try b.rec.expect(ok.events, &.{"write tool_result"});
    try expectFrame(&b.rec, ok.frames, "tool_result", "s-1-1", null);
    try testing.expectEqualStrings(tool_id, jsonString(b.rec.frameAt(ok.frames), "id").?);
    const failed = b.rec.mark();
    b.c.toolResult(1, "s-1-1", tool_id, false, "tool not available");
    try b.rec.expect(failed.events, &.{ "write tool_result", "message 1 error Browser tool failed: tool not available" });
    try expectFrame(&b.rec, failed.frames, "tool_result", "s-1-1", null);
    // An answer for a session that is not the window's open one is dropped.
    const stray = b.rec.mark();
    b.c.toolResult(1, "s-1-9", tool_id, true, "[]");
    b.c.toolResult(7, "s-7-1", tool_id, true, "[]");
    try b.rec.expect(stray.events, &.{});
}

test "Stop: the prompt's cards end at once, interrupt is written, its later frames are dropped, and its result shows stopped" {
    const b = try Bench.create();
    defer b.destroy();
    try b.running(1, "long");
    const stop = b.rec.mark();
    b.c.interrupt(1);
    try b.rec.expect(stop.events, &.{ "prompt_over 1 1", "write interrupt" });
    try expectFrame(&b.rec, stop.frames, "interrupt", "s-1-1", null);
    const again = b.rec.mark();
    b.c.interrupt(1); // a second Stop writes nothing more
    try b.rec.expect(again.events, &.{});
    const late = b.rec.mark();
    b.c.line(line(3, "\"type\":\"assistant_delta\",\"session\":\"s-1-1\",\"prompt_id\":1,\"text\":\"late\""));
    b.c.line(line(4, "\"type\":\"assistant_message\",\"session\":\"s-1-1\",\"prompt_id\":1,\"text\":\"late too\""));
    try b.rec.expect(late.events, &.{});
    const result = b.rec.mark();
    b.c.line(line(5, resultBody("s-1-1", 1)));
    try b.rec.expect(result.events, &.{ "prompt_over 1 1", "stopped 1", "status 1 ready -" });
}

test "a window closed: end_session written and its broker done; a later tool_call of its session gets 'tool not available'" {
    const b = try Bench.create();
    defer b.destroy();
    try b.running(1, "hi");
    const close = b.rec.mark();
    b.c.windowClosed(1);
    try b.rec.expect(close.events, &.{ "write end_session", "window_done 1" });
    try expectFrame(&b.rec, close.frames, "end_session", "s-1-1", null);
    const late = b.rec.mark();
    b.c.line(line(3, "\"type\":\"tool_call\",\"session\":\"s-1-1\",\"prompt_id\":1,\"id\":\"" ++ tool_id ++ "\",\"tool\":\"mcp__zigbrowser__get_text\",\"args\":{}"));
    try b.rec.expect(late.events, &.{"write tool_result"}); // no broker
    try expectFrame(&b.rec, late.frames, "tool_result", "s-1-1", null);
    try testing.expectEqualStrings(tool_id, jsonString(b.rec.frameAt(late.frames), "id").?);
    try testing.expect(std.mem.indexOf(u8, b.rec.frameAt(late.frames), "tool not available") != null);
}

test "a crash: crashed status and text for every window; the next Send rechecks, then restarts after the first backoff, 1 s" {
    const b = try Bench.create();
    defer b.destroy();
    try b.running(1, "hi");
    const crash = b.rec.mark();
    b.c.exited(.{ .code = 1 });
    // The dead helper's calls end with it, then every window is told.
    try b.rec.expect(crash.events, &.{ "detach_all", "status 0 crashed exit-1", "message 0 system Agent stopped (exit 1). Send to restart." });
    const resend = b.rec.mark();
    b.c.send(1, "again"); // its session died with the helper: a new one is checked first
    try b.rec.expect(resend.events, &.{ "lock", "config_check 1" });
    const checked = b.rec.mark();
    b.c.configChecked(1, false);
    try b.rec.expect(checked.events, &.{"timer restart 1000"});
    b.rec.now += 1000;
    const due = b.rec.mark();
    b.c.timerDue(.restart);
    var buf: [32]u8 = undefined;
    try b.rec.expect(due.events, &.{ "lock", "status 0 starting -", "net", tokenFetchEvent(&buf, b) });
    const fetched = b.rec.mark();
    b.c.tokenFetched(b.c.tokenGeneration(), test_token);
    try b.rec.expect(fetched.events, &.{"spawn " ++ test_token});
}

test "two windows: own sessions and prompt ids; one window's Stop, next prompt, stale frames, tool answer and close never reach the other" {
    const b = try Bench.create();
    defer b.destroy();
    try b.running(1, "one"); // s-1-1, prompt 1; frames 0-2
    // Window 2's first Send: its own lock and check, then its own session.
    const second = b.rec.mark();
    b.c.send(2, "two");
    try b.rec.expect(second.events, &.{ "lock", "config_check 2" });
    const checked = b.rec.mark();
    b.c.configChecked(2, false);
    try b.rec.expect(checked.events, &.{"write open_session"});
    try expectFrame(&b.rec, 3, "open_session", "s-2-1", null);
    const opened = b.rec.mark();
    b.c.line(line(3, "\"type\":\"session_opened\",\"session\":\"s-2-1\""));
    try b.rec.expect(opened.events, &.{ "write prompt", "status 2 busy -" });
    try expectFrame(&b.rec, 4, "prompt", "s-2-1", 1);
    // Window 2's tool call reaches window 2's broker only.
    const call = b.rec.mark();
    b.c.line(line(4, "\"type\":\"tool_call\",\"session\":\"s-2-1\",\"prompt_id\":1,\"id\":\"" ++ tool_id_2 ++ "\",\"tool\":\"mcp__zigbrowser__get_text\",\"args\":{}"));
    try b.rec.expect(call.events, &.{"tools_call 2 s-2-1 1 " ++ tool_id_2 ++ " mcp__zigbrowser__get_text {}"});
    // Window 1's Stop: its own cards and its own session only.
    const stop = b.rec.mark();
    b.c.interrupt(1);
    try b.rec.expect(stop.events, &.{ "prompt_over 1 1", "write interrupt" });
    try expectFrame(&b.rec, 5, "interrupt", "s-1-1", null);
    // Window 1's next prompt waits for the stopped one's result, then goes as prompt 2.
    const queued = b.rec.mark();
    b.c.send(1, "one-b");
    try b.rec.expect(queued.events, &.{});
    const stopped = b.rec.mark();
    b.c.line(line(5, resultBody("s-1-1", 1)));
    try b.rec.expect(stopped.events, &.{ "prompt_over 1 1", "stopped 1", "status 1 ready -", "write prompt", "status 1 busy -" });
    try expectFrame(&b.rec, 6, "prompt", "s-1-1", 2);
    // The old prompt's late delta and result: rejected, and prompt 2 is neither appended to nor ended.
    const stale = b.rec.mark();
    b.c.line(line(6, "\"type\":\"assistant_delta\",\"session\":\"s-1-1\",\"prompt_id\":1,\"text\":\"stale\""));
    b.c.line(line(7, resultBody("s-1-1", 1)));
    try b.rec.expect(stale.events, &.{});
    try testing.expectEqual(stale.frames, b.rec.frames.items.len);
    // Prompt 2 is still the one running: its delta shows, under window 1.
    const live = b.rec.mark();
    b.c.line(line(8, "\"type\":\"assistant_delta\",\"session\":\"s-1-1\",\"prompt_id\":2,\"text\":\"B\""));
    try b.rec.expect(live.events, &.{"delta 1 s-1-1 B"});
    // Window 2's broker answer goes to window 2's session, with its id.
    const answer = b.rec.mark();
    b.c.toolResult(2, "s-2-1", tool_id_2, true, "[]");
    try b.rec.expect(answer.events, &.{"write tool_result"});
    try expectFrame(&b.rec, answer.frames, "tool_result", "s-2-1", null);
    try testing.expectEqualStrings(tool_id_2, jsonString(b.rec.frameAt(answer.frames), "id").?);
    // Window 1 closed: its session ends and its broker is done; window 2 is untouched.
    const close = b.rec.mark();
    b.c.windowClosed(1);
    try b.rec.expect(close.events, &.{ "write end_session", "window_done 1" });
    try expectFrame(&b.rec, close.frames, "end_session", "s-1-1", null);
    const ended = b.rec.mark();
    b.c.line(line(9, "\"type\":\"session_ended\",\"session\":\"s-1-1\",\"reason\":\"end\""));
    try b.rec.expect(ended.events, &.{});
    // Window 2's reply and result still reach window 2, ending its prompt 1.
    const reply = b.rec.mark();
    b.c.line(line(10, "\"type\":\"assistant_message\",\"session\":\"s-2-1\",\"prompt_id\":1,\"text\":\"two done\""));
    b.c.line(line(11, resultBody("s-2-1", 1)));
    try b.rec.expect(reply.events, &.{ "message 2 assistant two done", "prompt_over 2 1", "end 2", "status 2 ready -" });
}

test "after Stop and the next prompt, the old prompt's late message and error never replace, stop or release the new one" {
    const b = try Bench.create();
    defer b.destroy();
    try b.running(1, "one");
    b.c.interrupt(1);
    b.c.send(1, "two");
    b.c.line(line(3, resultBody("s-1-1", 1)));
    try expectFrame(&b.rec, 4, "prompt", "s-1-1", 2);
    const stale = b.rec.mark();
    b.c.line(line(4, "\"type\":\"assistant_message\",\"session\":\"s-1-1\",\"prompt_id\":1,\"text\":\"stale\""));
    b.c.line(line(5, "\"type\":\"error\",\"session\":\"s-1-1\",\"prompt_id\":1,\"code\":\"sdk\",\"message\":\"stale\""));
    try b.rec.expect(stale.events, &.{});
    try testing.expectEqual(stale.frames, b.rec.frames.items.len);
    // Prompt 2 still runs: a third Send queues behind it, and its own result ends it.
    const queued = b.rec.mark();
    b.c.send(1, "three");
    try b.rec.expect(queued.events, &.{});
    const done = b.rec.mark();
    b.c.line(line(6, "\"type\":\"assistant_message\",\"session\":\"s-1-1\",\"prompt_id\":2,\"text\":\"fresh\""));
    b.c.line(line(7, resultBody("s-1-1", 2)));
    try b.rec.expect(done.events, &.{ "message 1 assistant fresh", "prompt_over 1 2", "end 1", "status 1 ready -", "write prompt", "status 1 busy -" });
    try expectFrame(&b.rec, done.frames, "prompt", "s-1-1", 3);
}
