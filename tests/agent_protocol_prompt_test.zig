//! S5d (chat-drawer plan section 10, S5d, rev 16.20.16 and 16.20.17; RoseCat 6136, 4990de9):
//! prompt correlation. Every prompt-scoped helper frame (`assistant_delta`,
//! `assistant_message`, `tool_call`, `result`, a session's `error`, `reply_capped`) carries
//! the `prompt_id` of the session's active prompt. A missing id is a schema error; a stale,
//! future or no-active-prompt id is rejected with reason `prompt`, and so is a second ending
//! frame. The active prompt ends exactly once (its `result` or session `error`, or
//! `session_ended`). A helper-wide `error` (session null) carries no id; a session `error`
//! with `prompt_id: null` is accepted only while the session has no active prompt. A
//! rejected frame commits nothing. The reason is named by its tag, so this file compiles
//! before the green.
const std = @import("std");
const p = @import("agent_protocol");

fn fresh() !p.Validator {
    var v = p.Validator.init(std.testing.allocator);
    try v.openSession("s-1-1", 1);
    return v;
}

fn expectRejectedAs(v: *p.Validator, frame: []const u8, reason: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = v.validate(arena.allocator(), frame);
    if (out != .rejected) {
        std.debug.print("accepted: {s}\n", .{frame});
        return error.TestUnexpectedResult;
    }
    if (!std.mem.eql(u8, reason, @tagName(out.rejected))) {
        std.debug.print("rejected ({s}, want {s}): {s}\n", .{ @tagName(out.rejected), reason, frame });
        return error.TestUnexpectedResult;
    }
}

fn expectAccepted(v: *p.Validator, frame: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = v.validate(arena.allocator(), frame);
    if (out != .ok) {
        std.debug.print("rejected ({s}): {s}\n", .{ @tagName(out.rejected), frame });
        return error.TestUnexpectedResult;
    }
}

/// `{"v":1,"seq":<seq>,"type":<kind>,"session":"s-1-1"<id>,<rest>}`; `id` is `,"prompt_id":N`,
/// `,"prompt_id":null` or "" (missing).
fn at(comptime seq: []const u8, comptime kind: []const u8, comptime id: []const u8, comptime rest: []const u8) []const u8 {
    return "{\"v\":1,\"seq\":" ++ seq ++ ",\"type\":\"" ++ kind ++ "\",\"session\":\"s-1-1\"" ++ id ++ rest ++ "}";
}

fn pid(comptime n: []const u8) []const u8 {
    return ",\"prompt_id\":" ++ n;
}

const Kind = struct { name: []const u8, rest: []const u8, ends: bool };
/// Every prompt-scoped kind but reply_capped (S5c's own suite covers its order). The tool
/// call ids are made unique per use by `toolCall`.
const kinds = [_]Kind{
    .{ .name = "assistant_delta", .rest = ",\"text\":\"a\"", .ends = false },
    .{ .name = "assistant_message", .rest = ",\"text\":\"a\"", .ends = false },
    .{ .name = "tool_call", .rest = "", .ends = false },
    .{ .name = "result", .rest = ",\"sdk_session_id\":\"x\",\"subtype\":\"success\",\"is_error\":false,\"num_turns\":1,\"cost_usd\":null", .ends = true },
    .{ .name = "error", .rest = ",\"code\":\"sdk\",\"message\":\"x\"", .ends = true },
};

var tool_n: usize = 0;

/// A frame of `kind` at `seq` with `id`; a tool call gets a fresh UUID each time.
fn build(buf: []u8, comptime kind: Kind, seq: usize, id: []const u8) ![]const u8 {
    if (std.mem.eql(u8, kind.name, "tool_call")) {
        tool_n += 1;
        return std.fmt.bufPrint(buf, "{{\"v\":1,\"seq\":{d},\"type\":\"tool_call\",\"session\":\"s-1-1\"{s},\"id\":\"123e4567-e89b-42d3-a456-{d:0>12}\",\"tool\":\"mcp__zigbrowser__x\",\"args\":{{}}}}", .{ seq, id, tool_n });
    }
    return std.fmt.bufPrint(buf, "{{\"v\":1,\"seq\":{d},\"type\":\"{s}\",\"session\":\"s-1-1\"{s}{s}}}", .{ seq, kind.name, id, kind.rest });
}

fn sent(v: *p.Validator, id: i64) !void {
    try v.promptSent("s-1-1", id);
}

test "every prompt-scoped frame with the active prompt's id is accepted" {
    inline for (kinds) |kind| {
        var v = try fresh();
        defer v.deinit();
        var buf: [512]u8 = undefined;
        try sent(&v, 1);
        try expectAccepted(&v, try build(&buf, kind, 1, pid("1")));
    }
}

test "a missing prompt_id is a schema error for every prompt-scoped frame" {
    inline for (kinds) |kind| {
        var v = try fresh();
        defer v.deinit();
        var buf: [512]u8 = undefined;
        try sent(&v, 1);
        try expectRejectedAs(&v, try build(&buf, kind, 1, ""), "schema");
        try expectRejectedAs(&v, try build(&buf, kind, 1, pid("\"1\"")), "schema");
        try expectRejectedAs(&v, try build(&buf, kind, 1, pid("0")), "schema");
    }
}

test "a stale, a future and a no-active-prompt id are rejected with reason prompt, and commit nothing" {
    inline for (kinds) |kind| {
        var v = try fresh();
        defer v.deinit();
        var buf: [512]u8 = undefined;
        // No prompt yet: any id is rejected.
        try expectRejectedAs(&v, try build(&buf, kind, 1, pid("1")), "prompt");
        try sent(&v, 1);
        try expectAccepted(&v, at("1", "result", pid("1"), kinds[3].rest));
        // Prompt 1 ended, prompt 2 not written: 1 is stale, 2 is future.
        try expectRejectedAs(&v, try build(&buf, kind, 2, pid("1")), "prompt");
        try expectRejectedAs(&v, try build(&buf, kind, 2, pid("2")), "prompt");
        try sent(&v, 2);
        try expectRejectedAs(&v, try build(&buf, kind, 2, pid("1")), "prompt");
        try expectRejectedAs(&v, try build(&buf, kind, 2, pid("3")), "prompt");
        // Nothing was committed: seq 2 is still free, and prompt 2 is still active.
        try expectAccepted(&v, try build(&buf, kind, 2, pid("2")));
    }
}

test "the active prompt ends exactly once: a second result or error for it is rejected" {
    inline for (.{ kinds[3], kinds[4] }) |first| {
        inline for (.{ kinds[3], kinds[4] }) |second| {
            var v = try fresh();
            defer v.deinit();
            var buf: [512]u8 = undefined;
            try sent(&v, 1);
            try expectAccepted(&v, try build(&buf, kinds[0], 1, pid("1")));
            try expectAccepted(&v, try build(&buf, first, 2, pid("1")));
            try expectRejectedAs(&v, try build(&buf, second, 3, pid("1")), "prompt");
            try expectRejectedAs(&v, try build(&buf, kinds[0], 3, pid("1")), "prompt");
        }
    }
}

test "session_ended ends the active prompt" {
    var v = try fresh();
    defer v.deinit();
    try sent(&v, 1);
    try expectAccepted(&v, at("1", "assistant_delta", pid("1"), ",\"text\":\"a\""));
    try expectAccepted(&v, at("2", "session_ended", "", ",\"reason\":\"end\""));
    try std.testing.expect(v.currentPrompt("s-1-1") == null);
}

test "Stop does not end a prompt: its deltas and its own result still carry its id" {
    // The validator sees no interrupt; the app's interrupt must not clear the active
    // prompt either (zb_agent_out_session(0, ...) leaves the validator's state alone).
    var v = try fresh();
    defer v.deinit();
    try sent(&v, 1);
    try expectAccepted(&v, at("1", "assistant_delta", pid("1"), ",\"text\":\"a\""));
    try expectAccepted(&v, at("2", "assistant_delta", pid("1"), ",\"text\":\"b\""));
    try expectAccepted(&v, at("3", "result", pid("1"), ",\"sdk_session_id\":\"x\",\"subtype\":\"error_during_execution\",\"is_error\":true,\"num_turns\":1,\"cost_usd\":null"));
}

test "a helper-wide error (session null) carries no prompt_id and ends no prompt" {
    var v = try fresh();
    defer v.deinit();
    try sent(&v, 1);
    try expectAccepted(&v, "{\"v\":1,\"seq\":1,\"type\":\"error\",\"session\":null,\"code\":\"sdk\",\"message\":\"x\"}");
    try expectRejectedAs(&v, "{\"v\":1,\"seq\":2,\"type\":\"error\",\"session\":null,\"prompt_id\":1,\"code\":\"sdk\",\"message\":\"x\"}", "schema");
    try expectAccepted(&v, at("2", "assistant_delta", pid("1"), ",\"text\":\"a\""));
}

test "a session error with prompt_id null is accepted only while the session has no active prompt (rev 16.20.17)" {
    var v = try fresh();
    defer v.deinit();
    const no_id = ",\"code\":\"sdk\",\"message\":\"x\"";
    // Before the first prompt, and after a prompt's ending frame: accepted, nothing ended.
    try expectAccepted(&v, at("1", "error", pid("null"), no_id));
    try sent(&v, 1);
    // While prompt 1 is active: rejected, and prompt 1 stays active.
    try expectRejectedAs(&v, at("2", "error", pid("null"), no_id), "prompt");
    try expectAccepted(&v, at("2", "assistant_delta", pid("1"), ",\"text\":\"a\""));
    try expectAccepted(&v, at("3", "result", pid("1"), kinds[3].rest));
    try expectAccepted(&v, at("4", "error", pid("null"), no_id));
    try std.testing.expect(v.currentPrompt("s-1-1") == null);
}
