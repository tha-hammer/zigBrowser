//! S5c-1 (chat-drawer plan S5.6, rev 16.20.11 to 16.20.13; RoseCat ae39e2a, e2cb1b0,
//! 5aea621): `reply_capped`, the helper's frame for "the reply to this prompt has text past
//! its longest prefix that fits the content bound". Its schema is exactly `session` and
//! `prompt_id`. The app records each prompt it writes (`Validator.promptSent`); a cap is
//! accepted only for the session's current prompt, once. A duplicate, a stale id (whenever
//! it arrives) and an id never sent are rejected with reason `capped`, as is a delta after
//! the cap; a message after the cap is accepted (the app does not show it over the cap).
//! The new API and reason are reached by name, so this file compiles before the green.
const std = @import("std");
const p = @import("agent_protocol");

fn fresh() !p.Validator {
    var v = p.Validator.init(std.testing.allocator);
    try v.openSession("s-1-1", 1);
    return v;
}

fn sent(v: *p.Validator, session: []const u8, id: i64) !void {
    if (comptime @hasDecl(p.Validator, "promptSent")) {
        try v.promptSent(session, id);
    } else {
        return error.NoPromptSent; // red: the validator does not know prompts yet
    }
}

fn expectRejectedAs(v: *p.Validator, frame: []const u8, reason: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = v.validate(arena.allocator(), frame);
    if (out != .rejected) {
        std.debug.print("accepted: {s}\n", .{frame});
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqualStrings(reason, @tagName(out.rejected));
}

fn expectAccepted(v: *p.Validator, frame: []const u8, kind: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = v.validate(arena.allocator(), frame);
    if (out != .ok) {
        std.debug.print("rejected ({s}): {s}\n", .{ @tagName(out.rejected), frame });
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqualStrings(kind, @tagName(out.ok));
}

fn at(comptime seq: []const u8, comptime body: []const u8) []const u8 {
    return "{\"v\":1,\"seq\":" ++ seq ++ "," ++ body ++ "}";
}

const delta = "\"type\":\"assistant_delta\",\"session\":\"s-1-1\",\"text\":\"a\"";
const message = "\"type\":\"assistant_message\",\"session\":\"s-1-1\",\"text\":\"a\"";
const result = "\"type\":\"result\",\"session\":\"s-1-1\",\"sdk_session_id\":\"x\",\"subtype\":\"success\",\"is_error\":false,\"num_turns\":1,\"cost_usd\":null";
fn cap(comptime id: []const u8) []const u8 {
    return "\"type\":\"reply_capped\",\"session\":\"s-1-1\",\"prompt_id\":" ++ id;
}

test "reply_capped for the current prompt is accepted as that frame" {
    var v = try fresh();
    defer v.deinit();
    try sent(&v, "s-1-1", 1);
    try expectAccepted(&v, at("1", delta), "assistant_delta");
    try expectAccepted(&v, at("2", cap("1")), "reply_capped");
}

test "a missing or extra field, a non-integer id, or a session never opened is rejected by schema or session" {
    var v = try fresh();
    defer v.deinit();
    try sent(&v, "s-1-1", 1);
    try expectRejectedAs(&v, at("1", "\"type\":\"reply_capped\",\"session\":\"s-1-1\""), "schema");
    try expectRejectedAs(&v, at("1", "\"type\":\"reply_capped\",\"prompt_id\":1"), "schema");
    try expectRejectedAs(&v, at("1", cap("1") ++ ",\"text\":\"x\""), "schema");
    try expectRejectedAs(&v, at("1", "\"type\":\"reply_capped\",\"session\":\"s-1-1\",\"prompt_id\":\"1\""), "schema");
    try expectRejectedAs(&v, at("1", "\"type\":\"reply_capped\",\"session\":\"s-9-9\",\"prompt_id\":1"), "session");
}

test "a cap before any prompt, and an id never sent, are rejected" {
    var v = try fresh();
    defer v.deinit();
    try expectRejectedAs(&v, at("1", cap("1")), "capped");
    try sent(&v, "s-1-1", 1);
    try expectAccepted(&v, at("1", delta), "assistant_delta");
    try expectRejectedAs(&v, at("2", cap("2")), "capped");
    // Rev 16.20.16: an id is 1 to 2^53 - 1, so 0 and 2^53 are schema errors.
    try expectRejectedAs(&v, at("2", cap("0")), "schema");
    try expectRejectedAs(&v, at("2", cap("9007199254740992")), "schema");
}

test "a cap with the current id before any delta of its reply is rejected (RoseCat 6d812b4)" {
    var v = try fresh();
    defer v.deinit();
    try sent(&v, "s-1-1", 1);
    try expectRejectedAs(&v, at("1", cap("1")), "capped");
    try expectAccepted(&v, at("1", delta), "assistant_delta");
    try expectAccepted(&v, at("2", result), "result");
    // The next prompt starts unstreamed again, though the last one streamed.
    try sent(&v, "s-1-1", 2);
    try expectRejectedAs(&v, at("3", cap("2")), "capped");
    try expectAccepted(&v, at("3", delta), "assistant_delta");
    try expectAccepted(&v, at("4", cap("2")), "reply_capped");
}

test "a duplicate cap and a delta after the cap are rejected; a message after it is accepted" {
    var v = try fresh();
    defer v.deinit();
    try sent(&v, "s-1-1", 1);
    try expectAccepted(&v, at("1", delta), "assistant_delta");
    try expectAccepted(&v, at("2", cap("1")), "reply_capped");
    try expectRejectedAs(&v, at("3", cap("1")), "capped");
    try expectRejectedAs(&v, at("3", delta), "capped");
    // A rejected frame commits nothing: seq 3 is still free.
    try expectAccepted(&v, at("3", message), "assistant_message");
    try expectAccepted(&v, at("4", result), "result");
}

test "a stale cap is rejected whenever it arrives, even after the next reply's first delta" {
    var v = try fresh();
    defer v.deinit();
    try sent(&v, "s-1-1", 1);
    try expectAccepted(&v, at("1", delta), "assistant_delta");
    try expectAccepted(&v, at("2", result), "result");
    try sent(&v, "s-1-1", 2);
    try expectRejectedAs(&v, at("3", cap("1")), "capped");
    try expectAccepted(&v, at("3", delta), "assistant_delta");
    try expectRejectedAs(&v, at("4", cap("1")), "capped");
    try expectAccepted(&v, at("4", delta), "assistant_delta");
}

test "after a capped prompt, the next prompt streams and may be capped once" {
    var v = try fresh();
    defer v.deinit();
    try sent(&v, "s-1-1", 1);
    try expectAccepted(&v, at("1", delta), "assistant_delta");
    try expectAccepted(&v, at("2", cap("1")), "reply_capped");
    try expectAccepted(&v, at("3", result), "result");
    try sent(&v, "s-1-1", 2);
    try expectAccepted(&v, at("4", delta), "assistant_delta");
    try expectAccepted(&v, at("5", cap("2")), "reply_capped");
    try expectRejectedAs(&v, at("6", cap("2")), "capped");
}

test "prompts and caps are kept per session" {
    var v = try fresh();
    defer v.deinit();
    try v.openSession("s-2-1", 2);
    try sent(&v, "s-1-1", 1);
    try expectAccepted(&v, at("1", delta), "assistant_delta");
    try expectRejectedAs(&v, at("2", "\"type\":\"reply_capped\",\"session\":\"s-2-1\",\"prompt_id\":1"), "capped");
    try expectAccepted(&v, at("2", cap("1")), "reply_capped");
    try expectAccepted(&v, at("3", "\"type\":\"assistant_delta\",\"session\":\"s-2-1\",\"text\":\"b\""), "assistant_delta");
}

test "the active prompt ends at its result, its session error or session_ended: a same-id cap after it is rejected (RoseCat 6135)" {
    var v = try fresh();
    defer v.deinit();
    try sent(&v, "s-1-1", 1);
    try expectAccepted(&v, at("1", delta), "assistant_delta");
    try expectAccepted(&v, at("2", result), "result");
    try expectRejectedAs(&v, at("3", cap("1")), "capped");
    try sent(&v, "s-1-1", 2);
    try expectAccepted(&v, at("3", delta), "assistant_delta");
    try expectAccepted(&v, at("4", "\"type\":\"error\",\"session\":\"s-1-1\",\"code\":\"sdk\",\"message\":\"x\""), "error");
    try expectRejectedAs(&v, at("5", cap("2")), "capped");
    // A helper-wide error (no session) ends no prompt.
    try sent(&v, "s-1-1", 3);
    try expectAccepted(&v, at("5", delta), "assistant_delta");
    try expectAccepted(&v, at("6", "\"type\":\"error\",\"session\":null,\"code\":\"sdk\",\"message\":\"x\""), "error");
    try expectAccepted(&v, at("7", cap("3")), "reply_capped");
    try expectAccepted(&v, at("8", "\"type\":\"session_ended\",\"session\":\"s-1-1\",\"reason\":\"end\""), "session_ended");
    if (comptime @hasDecl(p.Validator, "currentPrompt")) {
        try std.testing.expect(v.currentPrompt("s-1-1") == null);
    } else return error.NoCurrentPrompt;
}
