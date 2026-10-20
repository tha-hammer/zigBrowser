//! S5d fix-forward (RoseCat 6286): `reply_capped` is a prompt-scoped frame like the others,
//! so the S5d id rule comes first. A cap with no active prompt, a stale id or a future id is
//! rejected with reason `prompt`; only a cap that names the active prompt but breaks the
//! cap order (no delta of it yet, a second cap) is `capped`, and so is a delta after the
//! cap. A missing or out-of-range id is `schema`, a session never opened is `session`.
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

fn at(comptime seq: []const u8, comptime body: []const u8) []const u8 {
    return "{\"v\":1,\"seq\":" ++ seq ++ "," ++ body ++ "}";
}
fn cap(comptime id: []const u8) []const u8 {
    return "\"type\":\"reply_capped\",\"session\":\"s-1-1\",\"prompt_id\":" ++ id;
}
fn delta(comptime id: []const u8) []const u8 {
    return "\"type\":\"assistant_delta\",\"session\":\"s-1-1\",\"prompt_id\":" ++ id ++ ",\"text\":\"a\"";
}
fn result(comptime id: []const u8) []const u8 {
    return "\"type\":\"result\",\"session\":\"s-1-1\",\"prompt_id\":" ++ id ++ ",\"sdk_session_id\":\"x\",\"subtype\":\"success\",\"is_error\":false,\"num_turns\":1,\"cost_usd\":null";
}

test "a cap with no active prompt, a stale id or a future id is rejected with reason prompt" {
    var v = try fresh();
    defer v.deinit();
    try expectRejectedAs(&v, at("1", cap("1")), "prompt"); // no prompt written yet
    try v.promptSent("s-1-1", 1);
    try expectAccepted(&v, at("1", delta("1")));
    try expectRejectedAs(&v, at("2", cap("2")), "prompt"); // future
    try expectAccepted(&v, at("2", result("1")));
    try expectRejectedAs(&v, at("3", cap("1")), "prompt"); // prompt 1 ended: none active
    try v.promptSent("s-1-1", 2);
    try expectAccepted(&v, at("3", delta("2")));
    try expectRejectedAs(&v, at("4", cap("1")), "prompt"); // stale, after the next reply's first delta
    try expectAccepted(&v, at("4", cap("2")));
}

test "a cap naming the active prompt but out of order is rejected with reason capped" {
    var v = try fresh();
    defer v.deinit();
    try v.promptSent("s-1-1", 1);
    try expectRejectedAs(&v, at("1", cap("1")), "capped"); // no delta of it yet
    try expectAccepted(&v, at("1", delta("1")));
    try expectAccepted(&v, at("2", cap("1")));
    try expectRejectedAs(&v, at("3", cap("1")), "capped"); // a second cap
    try expectRejectedAs(&v, at("3", delta("1")), "capped"); // a delta after the cap
    try expectAccepted(&v, at("3", result("1")));
}

test "a missing or out-of-range id is schema, a session never opened is session" {
    var v = try fresh();
    defer v.deinit();
    try v.promptSent("s-1-1", 1);
    try expectRejectedAs(&v, at("1", "\"type\":\"reply_capped\",\"session\":\"s-1-1\""), "schema");
    try expectRejectedAs(&v, at("1", cap("0")), "schema");
    try expectRejectedAs(&v, at("1", cap("9007199254740992")), "schema");
    try expectRejectedAs(&v, at("1", "\"type\":\"reply_capped\",\"session\":\"s-9-9\",\"prompt_id\":1"), "session");
}
