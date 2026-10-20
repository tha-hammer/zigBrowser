//! S7b (chat-drawer plan section 10, S7, rev 16.20.34): the app's `tool_result`, built by the
//! export agent_helper.c calls on the GTK thread, `zb_agent_out_tool_result(session, id, ok,
//! body, len)`: with ok, `body` is the content (a JSON array of blocks); without, the error
//! text. Section 3's grammar exactly: the D7b envelope (v 1, the next out seq), `type`,
//! `session`, `id`, `ok`, and exactly `content` (ok) or exactly one non-empty `error` of at
//! most 4 KiB (cut on a UTF-8 boundary). A line (without its newline) over 1 MiB is never
//! sent: the call gets `ok:false` "result too large" instead. A content that is not a JSON
//! array is `ok:false` "the browser sent a bad answer".
//! The export is reached through @hasDecl, so this file compiles before the green and fails.
const std = @import("std");
const frames = @import("agent_frames");

const testing = std.testing;
const limit = 1 << 20;
const has = @hasDecl(frames, "zb_agent_out_tool_result");

const session = "s-1-1";
const id = "6f1c2a9e-3b4d-4e5f-8a7b-0c1d2e3f4a5b";

/// The frame (with its newline) for this call.
fn toolResult(ok: bool, body: []const u8) ![]const u8 {
    if (!has) return error.TestNoToolResultFrame;
    const line = frames.zb_agent_out_tool_result(session, id, @intFromBool(ok), body.ptr, body.len) orelse return error.NoFrame;
    return std.mem.span(line);
}

fn free(line: []const u8) void {
    if (has) frames.zb_agent_out_free(@constCast(@ptrCast(line.ptr)));
}

/// The parsed frame, after checking it ends in exactly one newline.
fn parse(line: []const u8) !std.json.Parsed(std.json.Value) {
    try testing.expect(line.len > 0 and line[line.len - 1] == '\n');
    try testing.expect(std.mem.indexOfScalar(u8, line[0 .. line.len - 1], '\n') == null);
    return std.json.parseFromSlice(std.json.Value, testing.allocator, line[0 .. line.len - 1], .{});
}

fn expectKeys(object: std.json.ObjectMap, comptime keys: []const []const u8) !void {
    try testing.expectEqual(keys.len, object.count());
    inline for (keys) |key| try testing.expect(object.contains(key));
}

fn seqOf(object: std.json.ObjectMap) i64 {
    return object.get("seq").?.integer;
}

test "ok: the envelope, the next seq, and exactly the content" {
    frames.zb_agent_frames_reset();
    try testing.expectEqual(@as(c_int, 0), frames.zb_agent_frames_open_session(session, 1));
    const prompt = frames.zb_agent_out_prompt(session, "hi", 2) orelse return error.NoFrame; // seq 1
    frames.zb_agent_out_free(prompt);
    const content = "[{\"type\":\"text\",\"text\":\"{\\\"text\\\":\\\"Hello from page 1\\\"}\"},{\"type\":\"image\",\"mime\":\"image/jpeg\",\"data_b64\":\"/9j/4AAQ\"}]";
    const line = try toolResult(true, content);
    defer free(line);
    var parsed = try parse(line);
    defer parsed.deinit();
    const o = parsed.value.object;
    try expectKeys(o, &.{ "v", "seq", "type", "session", "id", "ok", "content" });
    try testing.expectEqual(@as(i64, 1), o.get("v").?.integer);
    try testing.expectEqual(@as(i64, 2), seqOf(o));
    try testing.expectEqualStrings("tool_result", o.get("type").?.string);
    try testing.expectEqualStrings(session, o.get("session").?.string);
    try testing.expectEqualStrings(id, o.get("id").?.string);
    try testing.expect(o.get("ok").?.bool);
    const again = try std.json.Stringify.valueAlloc(testing.allocator, o.get("content").?, .{});
    defer testing.allocator.free(again);
    try testing.expectEqualStrings(content, again);
}

test "not ok: exactly one error; a long one is cut to 4 KiB on a UTF-8 boundary; an empty one is named" {
    frames.zb_agent_frames_reset();
    const line = try toolResult(false, "the page has a dialog open");
    defer free(line);
    var parsed = try parse(line);
    defer parsed.deinit();
    try expectKeys(parsed.value.object, &.{ "v", "seq", "type", "session", "id", "ok", "error" });
    try testing.expect(!parsed.value.object.get("ok").?.bool);
    try testing.expectEqualStrings("the page has a dialog open", parsed.value.object.get("error").?.string);

    const long = "é" ** 3000; // 6000 bytes, 2 bytes a code point
    const cut_line = try toolResult(false, long);
    defer free(cut_line);
    var cut = try parse(cut_line);
    defer cut.deinit();
    const text = cut.value.object.get("error").?.string;
    try testing.expect(text.len > 0 and text.len <= 4096);
    try testing.expect(std.unicode.utf8ValidateSlice(text));
    try testing.expect(std.mem.startsWith(u8, long, text));

    const empty_line = try toolResult(false, "");
    defer free(empty_line);
    var empty = try parse(empty_line);
    defer empty.deinit();
    try testing.expect(empty.value.object.get("error").?.string.len > 0);
}

/// A content of one text block whose frame (without its newline) is `size` bytes.
fn contentOfFrame(size: usize) ![]u8 {
    frames.zb_agent_frames_reset();
    const probe = try toolResult(true, "[{\"type\":\"text\",\"text\":\"\"}]");
    const base = probe.len - 1;
    free(probe);
    frames.zb_agent_frames_reset();
    const head = "[{\"type\":\"text\",\"text\":\"";
    const tail = "\"}]";
    const pad = size - base;
    const content = try testing.allocator.alloc(u8, head.len + pad + tail.len);
    @memcpy(content[0..head.len], head);
    @memset(content[head.len .. head.len + pad], 'x');
    @memcpy(content[head.len + pad ..], tail);
    return content;
}

test "a line of exactly 1 MiB is sent; one byte more is ok:false \"result too large\"" {
    const fits = try contentOfFrame(limit);
    defer testing.allocator.free(fits);
    const line = try toolResult(true, fits);
    defer free(line);
    try testing.expectEqual(@as(usize, limit), line.len - 1);
    var parsed = try parse(line);
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("ok").?.bool);

    const over = try contentOfFrame(limit + 1);
    defer testing.allocator.free(over);
    const refused = try toolResult(true, over);
    defer free(refused);
    var p2 = try parse(refused);
    defer p2.deinit();
    try expectKeys(p2.value.object, &.{ "v", "seq", "type", "session", "id", "ok", "error" });
    try testing.expect(!p2.value.object.get("ok").?.bool);
    try testing.expectEqualStrings("result too large", p2.value.object.get("error").?.string);
}

test "a content that is not a JSON array is ok:false \"the browser sent a bad answer\"" {
    frames.zb_agent_frames_reset();
    for ([_][]const u8{ "{\"type\":\"text\"}", "not json", "", "[1,2" }) |bad| {
        const line = try toolResult(true, bad);
        defer free(line);
        var parsed = try parse(line);
        defer parsed.deinit();
        try testing.expect(!parsed.value.object.get("ok").?.bool);
        try testing.expectEqualStrings("the browser sent a bad answer", parsed.value.object.get("error").?.string);
    }
}

test "a content with whitespace and newlines between its blocks is sent compact, on one line" {
    frames.zb_agent_frames_reset();
    const content = "[\n  {\"type\": \"text\", \"text\": \"a\\nb\"},\n  {\"type\":\"text\",\"text\":\"c\"}\n]\n";
    const line = try toolResult(true, content);
    defer free(line);
    var parsed = try parse(line); // exactly one newline, at the end
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("ok").?.bool);
    const again = try std.json.Stringify.valueAlloc(testing.allocator, parsed.value.object.get("content").?, .{});
    defer testing.allocator.free(again);
    try testing.expectEqualStrings("[{\"type\":\"text\",\"text\":\"a\\nb\"},{\"type\":\"text\",\"text\":\"c\"}]", again);
}
