//! S5d fix-forward (RoseCat 6307 item 4): prompt ids run from 1 to 2^53 - 1, per session,
//! never wrapped. The validator refuses an id outside that range, gives no next id after
//! the last one (the app's prompt builder's half is tests/agent_frames_prompt_test.zig).
const std = @import("std");
const p = @import("agent_protocol");

const max: i64 = (1 << 53) - 1;

fn fresh() !p.Validator {
    var v = p.Validator.init(std.testing.allocator);
    try v.openSession("s-1-1", 1);
    return v;
}

fn isNull(value: anytype) bool {
    return switch (@typeInfo(@TypeOf(value))) {
        .optional => value == null,
        else => false,
    };
}

test "promptSent refuses an id outside 1 to 2^53 - 1" {
    var v = try fresh();
    defer v.deinit();
    for ([_]i64{ 0, -1, max + 1, std.math.maxInt(i64) }) |bad| {
        if (v.promptSent("s-1-1", bad)) |_| {
            std.debug.print("accepted prompt id {d}\n", .{bad});
            return error.TestUnexpectedResult;
        } else |_| {}
    }
    try v.promptSent("s-1-1", max);
    try std.testing.expectEqual(@as(?i64, max), v.currentPrompt("s-1-1"));
}

test "after the last id there is no next one" {
    var v = try fresh();
    defer v.deinit();
    try v.promptSent("s-1-1", max - 1);
    try std.testing.expect(!isNull(v.nextPromptId("s-1-1")));
    try v.promptSent("s-1-1", max);
    try std.testing.expect(isNull(v.nextPromptId("s-1-1")));
}
