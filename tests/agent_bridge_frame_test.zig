//! S7.0.3 (chat-drawer plan section 10, S7, rev 16.20.30): the producer test. The line under
//! test is the real Bridge's own `tool_call`, written by the real Emitter
//! (agent/host/tests/bridge_producer.py, which the build runs and hands over as
//! "bridge_frames"); the app's real Validator judges it. Since S5d a `tool_call` must name
//! the session's active prompt: the Bridge's line is accepted at prompt 7, and the same line
//! without its `prompt_id` is a schema error, or naming the previous prompt a `prompt` one.
const std = @import("std");
const p = @import("agent_protocol");

const produced = @embedFile("bridge_frames");

/// The producer's one line (it writes nothing else).
fn line() ![]const u8 {
    var lines = std.mem.tokenizeScalar(u8, produced, '\n');
    const first = lines.next() orelse return error.NoFrame;
    if (lines.next() != null) return error.MoreThanOneFrame;
    return first;
}

/// `s-1-1` open, its prompt 7 written (prompts 1 to 6 ended before it).
fn atPrompt7() !p.Validator {
    var v = p.Validator.init(std.testing.allocator);
    errdefer v.deinit();
    try v.openSession("s-1-1", 1);
    try v.startPromptsAt("s-1-1", 6);
    try v.promptSent("s-1-1", 7);
    return v;
}

/// The line with `from` replaced by `to`, where `from` must occur exactly once.
fn edited(gpa: std.mem.Allocator, from: []const u8, to: []const u8) ![]u8 {
    const text = try line();
    if (std.mem.count(u8, text, from) != 1) {
        std.debug.print("want {s} once in {s}\n", .{ from, text });
        return error.TestUnexpectedResult;
    }
    return std.mem.replaceOwned(u8, gpa, text, from, to);
}

fn outcome(v: *p.Validator, arena: std.mem.Allocator, text: []const u8) p.Outcome {
    const out = v.validate(arena, text);
    if (out == .rejected) std.debug.print("rejected ({s}): {s}\n", .{ @tagName(out.rejected), text });
    return out;
}

test "the Bridge's tool_call is accepted at the session's active prompt" {
    var v = try atPrompt7();
    defer v.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = outcome(&v, arena.allocator(), try line());
    try std.testing.expect(out == .ok);
    try std.testing.expect(out.ok == .tool_call);
    try std.testing.expectEqual(@as(i64, 7), out.ok.tool_call.prompt_id);
    try std.testing.expectEqualStrings("s-1-1", out.ok.tool_call.session);
    try std.testing.expectEqualStrings("mcp__zigbrowser__get_text", out.ok.tool_call.tool);
}

test "the same line without its prompt_id is a schema error" {
    var v = try atPrompt7();
    defer v.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = try edited(arena.allocator(), ",\"prompt_id\":7", "");
    const out = v.validate(arena.allocator(), text);
    try std.testing.expect(out == .rejected);
    try std.testing.expectEqualStrings("schema", @tagName(out.rejected));
}

test "the same line naming the previous prompt is rejected as prompt" {
    var v = try atPrompt7();
    defer v.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = try edited(arena.allocator(), ",\"prompt_id\":7,", ",\"prompt_id\":6,");
    const out = v.validate(arena.allocator(), text);
    try std.testing.expect(out == .rejected);
    try std.testing.expectEqualStrings("prompt", @tagName(out.rejected));
}
