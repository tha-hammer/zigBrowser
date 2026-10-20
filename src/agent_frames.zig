//! The C face of the helper's frames (chat-drawer plan D7, D7b, S3.3; S3b):
//! src/agent_helper.c validates every helper stdout line here before it acts
//! on it, and builds every frame it writes here. One helper at a time, GTK
//! main thread only. A frame's strings stay valid until the next validate.

const std = @import("std");
pub const protocol = @import("agent_protocol.zig");
const helper = @import("agent_helper.zig");
const config_check = @import("agent_config_check.zig");

const gpa = std.heap.c_allocator;

pub var validator: ?protocol.Validator = null; // pub: the production-path test (S5d)
var frame_arena: std.heap.ArenaAllocator = .init(gpa);
var out_seq: u64 = 0;
var hello_home: ?[]u8 = null;
var hello_e2e: ?helper.HelloE2e = null;

/// app.zig, once: what the helper's `hello` frame says.
pub fn setHello(home: []const u8, e2e: ?helper.HelloE2e) !void {
    hello_home = try gpa.dupe(u8, home);
    hello_e2e = if (e2e) |value| .{
        .test_base_url = if (value.test_base_url) |url| try gpa.dupe(u8, url) else null,
        .tool_deadline_s = value.tool_deadline_s,
    } else null;
}

/// The helper's tool deadline H for the app's brokers (S7b): hello.e2e.tool_deadline_s when
/// the e2e seam set it, else agent_protocol.tool_deadline_s.
pub fn toolDeadlineS() i64 {
    return (if (hello_e2e) |e2e| e2e.tool_deadline_s else null) orelse protocol.tool_deadline_s;
}

pub const Kind = enum(c_int) { ready, session_opened, assistant_delta, assistant_message, tool_call, result, @"error", session_ended, reply_capped };

pub const CFrame = extern struct {
    kind: c_int = 0,
    session: ?[*]const u8 = null,
    session_len: usize = 0,
    /// delta and message text, an error's message, an ended session's reason.
    text: ?[*]const u8 = null,
    text_len: usize = 0,
    /// an error's code.
    code: ?[*]const u8 = null,
    code_len: usize = 0,
    is_error: c_int = 0,
    /// A tool_call's call (S7b): its id, its tool, and its args object as compact JSON.
    tool_id: ?[*]const u8 = null,
    tool_id_len: usize = 0,
    tool: ?[*]const u8 = null,
    tool_len: usize = 0,
    args: ?[*]const u8 = null,
    args_len: usize = 0,
};

/// A new helper process: a fresh validator (its seq and sessions) and out seq.
pub export fn zb_agent_frames_reset() void {
    if (validator) |*v| v.deinit();
    validator = protocol.Validator.init(gpa);
    _ = frame_arena.reset(.free_all);
    out_seq = 0;
}

/// The app opened `session` for window `window` (sent `open_session`).
pub export fn zb_agent_frames_open_session(session: [*:0]const u8, window: u32) c_int {
    const v = if (validator) |*v| v else return -1;
    v.openSession(std.mem.span(session), window) catch return -1;
    return 0;
}

/// The app gives up on `session` without a session_ended: a session the helper
/// reported it could not open (an error before session_opened). A window close
/// does not call this: the helper's session_ended closes that session (RoseCat 5681).
export fn zb_agent_frames_close_session(session: [*:0]const u8) void {
    if (validator) |*v| v.closeSession(std.mem.span(session));
}

/// 0 and `out` filled when the line is a valid frame; otherwise 1 + the
/// protocol.Reason (zb_agent_frames_reason names it). Never logs content.
pub export fn zb_agent_frames_validate(line: [*]const u8, len: usize, out: *CFrame) c_int {
    const v = if (validator) |*v| v else return 1 + @as(c_int, @intFromEnum(protocol.Reason.envelope));
    _ = frame_arena.reset(.retain_capacity);
    const outcome = v.validate(frame_arena.allocator(), line[0..len]);
    const frame = switch (outcome) {
        .rejected => |reason| return 1 + @as(c_int, @intFromEnum(reason)),
        .ok => |f| f,
    };
    out.* = .{ .kind = @intFromEnum(std.meta.stringToEnum(Kind, @tagName(frame)).?) };
    switch (frame) {
        .ready => {},
        .session_opened => |f| setSession(out, f.session),
        .assistant_delta, .assistant_message => |f| {
            setSession(out, f.session);
            setText(out, f.text);
        },
        .tool_call => |f| {
            setSession(out, f.session);
            out.tool_id, out.tool_id_len = .{ f.id.ptr, f.id.len };
            out.tool, out.tool_len = .{ f.tool.ptr, f.tool.len };
            out.args, out.args_len = .{ f.args_json.ptr, f.args_json.len };
        },
        .result => |f| {
            setSession(out, f.session);
            out.is_error = @intFromBool(f.is_error);
        },
        .@"error" => |f| {
            if (f.session) |s| setSession(out, s);
            setText(out, f.message);
            out.code = f.code.ptr;
            out.code_len = f.code.len;
        },
        .session_ended => |f| {
            setSession(out, f.session);
            setText(out, f.reason);
        },
        .reply_capped => |f| setSession(out, f.session),
    }
    return 0;
}

fn setSession(out: *CFrame, session: []const u8) void {
    out.session = session.ptr;
    out.session_len = session.len;
}

fn setText(out: *CFrame, text: []const u8) void {
    out.text = text.ptr;
    out.text_len = text.len;
}

export fn zb_agent_frames_reason(code: c_int) [*:0]const u8 {
    const fields = @typeInfo(protocol.Reason).@"enum".fields;
    inline for (fields) |field| if (code == 1 + field.value) return field.name;
    return "unknown";
}

// --- frames the app writes (NUL-terminated, newline included; free with
// zb_agent_out_free). NULL when the frame cannot be built or is too large. ---

fn owned(built: anyerror![]u8) ?[*:0]u8 {
    const bytes = built catch return null;
    defer gpa.free(bytes);
    const z = gpa.dupeZ(u8, bytes) catch return null;
    return z.ptr;
}

fn nextSeq() u64 {
    out_seq += 1;
    return out_seq;
}

/// S7b (rev 16.20.34): a tool call's answer, built on the GTK thread. With `ok`, `body` is
/// the content (a JSON array of blocks); without, the error text. Section 3's grammar: the
/// D7b envelope, then exactly `content` or exactly one non-empty `error` of at most 4 KiB (cut
/// on a UTF-8 boundary). A line over 1 MiB (without its newline) is never sent: the call gets
/// `ok:false` "result too large" instead; a content that is not a JSON array, "the browser sent
/// a bad answer". The content is written compact, so the frame is one line.
pub export fn zb_agent_out_tool_result(session: [*:0]const u8, id: [*:0]const u8, ok: c_int, body: [*]const u8, len: usize) ?[*:0]u8 {
    return owned(toolResultFrame(gpa, nextSeq(), std.mem.span(session), std.mem.span(id), ok != 0, body[0..len]));
}

const tool_result_max = 1 << 20;
const tool_error_max = 4096;

fn toolResultFrame(a: std.mem.Allocator, seq: u64, session: []const u8, id: []const u8, ok: bool, body: []const u8) ![]u8 {
    if (!ok) return toolFailure(a, seq, session, id, body);
    const parsed = std.json.parseFromSlice(std.json.Value, a, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return toolFailure(a, seq, session, id, "the browser sent a bad answer"),
    };
    defer parsed.deinit();
    if (parsed.value != .array) return toolFailure(a, seq, session, id, "the browser sent a bad answer");
    // Written again, compact: a content's own whitespace may hold newlines, and a frame is one line.
    const line = try std.fmt.allocPrint(a, "{{\"v\":1,\"seq\":{d},\"type\":\"tool_result\",\"session\":{f},\"id\":{f},\"ok\":true,\"content\":{f}}}\n", .{ seq, std.json.fmt(session, .{}), std.json.fmt(id, .{}), std.json.fmt(parsed.value, .{}) });
    if (line.len - 1 <= tool_result_max) return line;
    a.free(line);
    return toolFailure(a, seq, session, id, "result too large");
}

fn toolFailure(a: std.mem.Allocator, seq: u64, session: []const u8, id: []const u8, text: []const u8) ![]u8 {
    var cut = text[0..@min(text.len, tool_error_max)];
    while (cut.len > 0 and !std.unicode.utf8ValidateSlice(cut)) cut = cut[0 .. cut.len - 1]; // a code point never split
    const message = if (cut.len == 0) "failed" else cut;
    return std.fmt.allocPrint(a, "{{\"v\":1,\"seq\":{d},\"type\":\"tool_result\",\"session\":{f},\"id\":{f},\"ok\":false,\"error\":{f}}}\n", .{ seq, std.json.fmt(session, .{}), std.json.fmt(id, .{}), std.json.fmt(message, .{}) });
}

export fn zb_agent_out_hello() ?[*:0]u8 {
    return owned(helper.helloFrame(gpa, nextSeq(), hello_home orelse return null, hello_e2e));
}

export fn zb_agent_out_open_session(window: u32, k: u32) ?[*:0]u8 {
    return owned(helper.openSessionFrame(gpa, nextSeq(), window, k));
}

pub const Prompt = union(enum) { frame: []u8, too_long, exhausted };

/// A prompt's frame at `seq`, with the session's next prompt_id, which becomes its active
/// prompt (rev 16.20.13 and 16.20.16): its frames must carry that id. Once the ids are
/// spent (RoseCat 6307) or the text is over its cap, no frame and nothing recorded.
pub fn buildPrompt(v: *protocol.Validator, a: std.mem.Allocator, seq: u64, session: []const u8, text: []const u8) !Prompt {
    const prompt_id = v.nextPromptId(session) orelse return .exhausted;
    const built = (try helper.promptFrame(a, seq, session, prompt_id, text)) orelse return .too_long;
    errdefer a.free(built);
    try v.promptSent(session, prompt_id);
    return .{ .frame = built };
}

/// Why the last zb_agent_out_prompt gave no frame: 0 it gave one, 1 too long, 2 the
/// session's prompt ids are spent, 3 another failure.
var last_prompt_status: c_int = 0;

pub export fn zb_agent_out_prompt(session: [*:0]const u8, text: [*]const u8, len: usize) ?[*:0]u8 {
    last_prompt_status = 3;
    const v = if (validator) |*v| v else return null;
    const result = buildPrompt(v, gpa, out_seq + 1, std.mem.span(session), text[0..len]) catch return null;
    switch (result) {
        .too_long => {
            last_prompt_status = 1;
            return null;
        },
        .exhausted => {
            last_prompt_status = 2;
            return null;
        },
        .frame => |built| {
            const frame = owned(built) orelse return null;
            out_seq += 1;
            last_prompt_status = 0;
            return frame;
        },
    }
}

pub export fn zb_agent_out_prompt_status() c_int {
    return last_prompt_status;
}

/// ZIGBROWSER_AGENT_TEST_PROMPT_BASE (--e2e-protocol only; RoseCat 6351): the last prompt
/// id a new session starts from, so a real-chain test can spend a session's ids. Inert
/// without e2e; only plain decimal digits from 0 to 2^53 - 1.
pub fn promptBase(e2e: bool, raw: ?[]const u8) ?i64 {
    const text = raw orelse return null;
    if (!e2e or text.len == 0 or text.len > 16) return null;
    for (text) |c| if (!std.ascii.isDigit(c)) return null;
    const base = std.fmt.parseInt(i64, text, 10) catch return null;
    return if (base <= protocol.max_prompt_id) base else null;
}

/// agent_helper.c, at a session's open: applies the seam (0 applied or inert, -1 failed).
pub export fn zb_agent_frames_seed_prompts(session: [*:0]const u8, e2e: c_int, raw: ?[*:0]const u8) c_int {
    const base = promptBase(e2e != 0, if (raw) |r| std.mem.span(r) else null) orelse return 0;
    const v = if (validator) |*v| v else return -1;
    v.startPromptsAt(std.mem.span(session), base) catch return -1;
    return 0;
}

/// The sentence the app shows when the last zb_agent_out_prompt gave no frame (RoseCat
/// 6314: spent ids are an agent error, not a long message).
pub export fn zb_agent_out_prompt_refusal() [*:0]const u8 {
    return if (last_prompt_status == 1) "Message too long (64 KiB at most)" else "Agent error";
}

/// kind: 0 interrupt, 1 end_session.
pub export fn zb_agent_out_session(kind: c_int, session: [*:0]const u8) ?[*:0]u8 {
    const which: helper.SessionFrame = if (kind == 0) .interrupt else .end_session;
    return owned(helper.sessionFrame(gpa, nextSeq(), which, std.mem.span(session)));
}

export fn zb_agent_out_shutdown() ?[*:0]u8 {
    return owned(helper.shutdownFrame(gpa, nextSeq()));
}

/// 0 when the agent home's `.claude` still matches its config manifest
/// (agent_config_check.zig), 1 when it changed or the manifest is unreadable.
/// agent_helper.c calls it on a GTask worker thread: it touches no state here,
/// and the single-threaded Io only makes plain file syscalls for it.
export fn zb_agent_config_changed(home: [*:0]const u8) c_int {
    const io = std.Io.Threaded.global_single_threaded.io();
    return @intFromBool(config_check.check(gpa, io, std.mem.span(home)) != .ok);
}

pub export fn zb_agent_out_free(frame: ?[*:0]u8) void {
    if (frame) |p| gpa.free(std.mem.span(p));
}
