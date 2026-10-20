//! S5d fix-forward (RoseCat 6307 item 4, 6314): the production prompt path, through the
//! exports agent_helper.c calls. Once a session's prompt ids are spent (2^53 - 1, never
//! wrapped), `zb_agent_out_prompt` gives no frame, `zb_agent_out_prompt_status` says the
//! ids are spent (before "too long": exhaustion comes first), the sentence the app shows is
//! exactly "Agent error", and the out seq does not skip: the next frame has the next seq.
//! The exports are reached by name, so this file compiles before the green.
const std = @import("std");
const frames = @import("agent_frames");

const max: i64 = (1 << 53) - 1;

fn seqOf(line: [*:0]const u8) !i64 {
    const text = std.mem.span(line);
    const at = std.mem.indexOf(u8, text, "\"seq\":") orelse return error.NoSeq;
    var end = at + 6;
    while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
    return std.fmt.parseInt(i64, text[at + 6 .. end], 10);
}

test "spent prompt ids: no frame, the exact Agent error, and no skipped seq" {
    if (comptime @hasDecl(frames, "zb_agent_out_prompt_refusal") and @hasDecl(frames, "validator")) try production() else return error.NotYetExported; // red until the green
}

fn production() !void {
    frames.zb_agent_frames_reset();
    try std.testing.expectEqual(@as(c_int, 0), frames.zb_agent_frames_open_session("s-1-1", 1));
    const hello = "hello";
    const first = frames.zb_agent_out_prompt("s-1-1", hello, hello.len) orelse return error.NoFrame;
    const first_seq = try seqOf(first);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(first), "\"prompt_id\":1,") != null);
    frames.zb_agent_out_free(first);
    try std.testing.expectEqual(@as(c_int, 0), frames.zb_agent_out_prompt_status());

    try frames.validator.?.promptSent("s-1-1", max); // the session's last id is spent
    try std.testing.expect(frames.zb_agent_out_prompt("s-1-1", hello, hello.len) == null);
    try std.testing.expectEqual(@as(c_int, 2), frames.zb_agent_out_prompt_status());
    try std.testing.expectEqualStrings("Agent error", std.mem.span(frames.zb_agent_out_prompt_refusal()));
    const long = "x" ** (64 * 1024 + 1);
    try std.testing.expect(frames.zb_agent_out_prompt("s-1-1", long, long.len) == null);
    try std.testing.expectEqual(@as(c_int, 2), frames.zb_agent_out_prompt_status()); // exhaustion first
    try std.testing.expectEqual(@as(?i64, max), frames.validator.?.currentPrompt("s-1-1"));

    const next = frames.zb_agent_out_session(0, "s-1-1") orelse return error.NoFrame;
    defer frames.zb_agent_out_free(next);
    try std.testing.expectEqual(first_seq + 1, try seqOf(next));
}

test "a long prompt on a fresh session says too long, with its own sentence" {
    if (comptime @hasDecl(frames, "zb_agent_out_prompt_refusal") and @hasDecl(frames, "validator")) try tooLong() else return error.NotYetExported;
}

fn tooLong() !void {
    frames.zb_agent_frames_reset();
    try std.testing.expectEqual(@as(c_int, 0), frames.zb_agent_frames_open_session("s-1-1", 1));
    const long = "x" ** (64 * 1024 + 1);
    try std.testing.expect(frames.zb_agent_out_prompt("s-1-1", long, long.len) == null);
    try std.testing.expectEqual(@as(c_int, 1), frames.zb_agent_out_prompt_status());
    try std.testing.expectEqualStrings("Message too long (64 KiB at most)", std.mem.span(frames.zb_agent_out_prompt_refusal()));
    try std.testing.expectEqual(@as(?i64, null), frames.validator.?.currentPrompt("s-1-1")); // nothing recorded
}
