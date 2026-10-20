//! S7b (chat-drawer plan section 10, S7, rev 16.20.34): a validated `tool_call` hands its call
//! to the app's C side. `zb_agent_frames_validate` fills, besides the session, the call's
//! `tool_id`, `tool` and `args` (the args object as compact JSON), each with its length,
//! valid until the next validate. Other frames leave them empty.
//! The new fields are reached through @hasField, so this file compiles before the green and fails.
const std = @import("std");
const frames = @import("agent_frames");

const testing = std.testing;
const has = @hasField(frames.CFrame, "tool_id") and @hasField(frames.CFrame, "tool") and @hasField(frames.CFrame, "args");

const id = "6f1c2a9e-3b4d-4e5f-8a7b-0c1d2e3f4a5b";

fn span(ptr: ?[*]const u8, len: usize) []const u8 {
    return if (ptr) |p| p[0..len] else "";
}

test "a tool_call's id, tool and args reach the C frame" {
    if (!has) return error.TestNoToolCallFields;
    frames.zb_agent_frames_reset();
    try testing.expectEqual(@as(c_int, 0), frames.zb_agent_frames_open_session("s-1-1", 1));
    const prompt = frames.zb_agent_out_prompt("s-1-1", "hi", 2) orelse return error.NoFrame; // prompt 1 runs
    frames.zb_agent_out_free(prompt);
    const line = "{\"v\":1,\"seq\":1,\"type\":\"tool_call\",\"session\":\"s-1-1\",\"prompt_id\":1,\"id\":\"" ++ id ++
        "\",\"tool\":\"mcp__zigbrowser__get_text\",\"args\":{ \"selector\" : \"css=#greeting\" }}";
    var out: frames.CFrame = .{};
    try testing.expectEqual(@as(c_int, 0), frames.zb_agent_frames_validate(line.ptr, line.len, &out));
    try testing.expectEqual(@as(c_int, @intFromEnum(frames.Kind.tool_call)), out.kind);
    try testing.expectEqualStrings("s-1-1", span(out.session, out.session_len));
    try testing.expectEqualStrings(id, span(@field(out, "tool_id"), @field(out, "tool_id_len")));
    try testing.expectEqualStrings("mcp__zigbrowser__get_text", span(@field(out, "tool"), @field(out, "tool_len")));
    try testing.expectEqualStrings("{\"selector\":\"css=#greeting\"}", span(@field(out, "args"), @field(out, "args_len")));
}

test "other frames leave the call's fields empty" {
    if (!has) return error.TestNoToolCallFields;
    frames.zb_agent_frames_reset();
    try testing.expectEqual(@as(c_int, 0), frames.zb_agent_frames_open_session("s-1-1", 1));
    const line = "{\"v\":1,\"seq\":1,\"type\":\"session_opened\",\"session\":\"s-1-1\"}";
    var out: frames.CFrame = .{};
    try testing.expectEqual(@as(c_int, 0), frames.zb_agent_frames_validate(line.ptr, line.len, &out));
    try testing.expectEqual(@as(usize, 0), @field(out, "tool_id_len"));
    try testing.expectEqual(@as(usize, 0), @field(out, "tool_len"));
    try testing.expectEqual(@as(usize, 0), @field(out, "args_len"));
}
