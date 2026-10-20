//! S5d fix-forward (RoseCat 6307 item 4): the app's prompt builder (`agent_frames.zig`)
//! gives each prompt the session's next id. Once the last id, 2^53 - 1, is spent it writes
//! no frame and says so (`exhausted`), so the app shows "Agent error", not "Message too
//! long"; nothing is recorded, nothing wraps, and the caller's seq does not move (the
//! builder takes the seq and only a frame uses it).
//! New API is reached by name, so this file compiles before the green.
const std = @import("std");
const frames = @import("agent_frames");

const max: i64 = (1 << 53) - 1;

test "the prompt builder writes no frame once the ids are spent, and says so" {
    if (comptime @hasDecl(frames, "buildPrompt")) try built() else return error.NoBuildPrompt; // red until the green
}

fn built() !void {
    const p = frames.protocol;
    var v = p.Validator.init(std.testing.allocator);
    try v.openSession("s-1-1", 1);
    defer v.deinit();
    const a = std.testing.allocator;
    const first = try frames.buildPrompt(&v, a, 7, "s-1-1", "hello");
    switch (first) {
        .frame => |line| {
            defer a.free(line);
            try std.testing.expect(std.mem.indexOf(u8, line, "\"prompt_id\":1,") != null);
        },
        else => return error.TestUnexpectedResult,
    }
    try v.promptSent("s-1-1", max);
    const spent = try frames.buildPrompt(&v, a, 8, "s-1-1", "hello");
    try std.testing.expect(spent == .exhausted);
    try std.testing.expectEqual(@as(?i64, max), v.currentPrompt("s-1-1")); // nothing recorded, nothing wrapped
    const long = try frames.buildPrompt(&v, a, 8, "s-1-1", "x" ** (64 * 1024 + 1));
    try std.testing.expect(long == .too_long or long == .exhausted);
}
