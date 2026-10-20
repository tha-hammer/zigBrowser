//! S5d fix-forward (RoseCat 6351): the e2e-only seam ZIGBROWSER_AGENT_TEST_PROMPT_BASE, the
//! last prompt id a new session starts from, so a real-chain test can spend a session's ids
//! (2^53 - 1) in two prompts. The decision is pure: without --e2e-protocol, or for anything
//! but plain decimal digits from 0 to 2^53 - 1, the seam is inert. Applied to a session at
//! its open, its next prompt gets base + 1.
//! The new API is reached by name, so this file compiles before the green.
const std = @import("std");
const frames = @import("agent_frames");

const max: i64 = (1 << 53) - 1;

test "the seam is inert without e2e, and refuses anything but 0 to 2^53 - 1 in plain digits" {
    if (comptime @hasDecl(frames, "promptBase")) try decide() else return error.NoPromptBase; // red
}

fn decide() !void {
    try std.testing.expectEqual(@as(?i64, null), frames.promptBase(false, "5"));
    try std.testing.expectEqual(@as(?i64, null), frames.promptBase(true, null));
    try std.testing.expectEqual(@as(?i64, 5), frames.promptBase(true, "5"));
    try std.testing.expectEqual(@as(?i64, 0), frames.promptBase(true, "0"));
    try std.testing.expectEqual(@as(?i64, max), frames.promptBase(true, "9007199254740991"));
    for ([_][]const u8{ "", "-1", "+5", " 5", "5 ", "1e3", "0x10", "abc", "9007199254740992", "99999999999999999999" }) |bad| {
        if (frames.promptBase(true, bad)) |got| {
            std.debug.print("accepted {s} as {d}\n", .{ bad, got });
            return error.TestUnexpectedResult;
        }
    }
}

test "a seeded session's next prompt gets base + 1, and the one after is refused as spent" {
    if (comptime @hasDecl(frames, "zb_agent_frames_seed_prompts")) try seeded() else return error.NoSeed; // red
}

fn seeded() !void {
    frames.zb_agent_frames_reset();
    try std.testing.expectEqual(@as(c_int, 0), frames.zb_agent_frames_open_session("s-1-1", 1));
    try std.testing.expectEqual(@as(c_int, 0), frames.zb_agent_frames_seed_prompts("s-1-1", 1, "9007199254740990"));
    const text = "hello";
    const first = frames.zb_agent_out_prompt("s-1-1", text, text.len) orelse return error.NoFrame;
    defer frames.zb_agent_out_free(first);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(first), "\"prompt_id\":9007199254740991,") != null);
    try std.testing.expect(frames.zb_agent_out_prompt("s-1-1", text, text.len) == null);
    try std.testing.expectEqual(@as(c_int, 2), frames.zb_agent_out_prompt_status());
    // Without e2e the seam changes nothing: a new session starts at 1.
    try std.testing.expectEqual(@as(c_int, 0), frames.zb_agent_frames_open_session("s-1-2", 1));
    try std.testing.expectEqual(@as(c_int, 0), frames.zb_agent_frames_seed_prompts("s-1-2", 0, "9007199254740990"));
    const other = frames.zb_agent_out_prompt("s-1-2", text, text.len) orelse return error.NoFrame;
    defer frames.zb_agent_out_free(other);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(other), "\"prompt_id\":1,") != null);
}
