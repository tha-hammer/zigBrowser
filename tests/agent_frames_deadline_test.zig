//! S7b (chat-drawer plan S7b, rev 16.20.34): the app's brokers use the helper's tool deadline
//! H: options.TOOL_DEADLINE_S (120), or hello.e2e.tool_deadline_s when the e2e seam set it.
//! `agent_frames.toolDeadlineS()` answers it after `setHello`. Reached through @hasDecl, so
//! this file compiles before the green and fails.
const std = @import("std");
const frames = @import("agent_frames");

const has = @hasDecl(frames, "toolDeadlineS");

test "the brokers' H is 120 without the seam and the seam's value with it" {
    if (!has) return error.TestNoToolDeadline;
    try frames.setHello("/d/agent-home", null);
    try std.testing.expectEqual(@as(i64, 120), frames.toolDeadlineS());
    try frames.setHello("/d/agent-home", .{ .test_base_url = "https://fake.zb.invalid" });
    try std.testing.expectEqual(@as(i64, 120), frames.toolDeadlineS());
    var e2e: @typeInfo(@TypeOf(frames.setHello)).@"fn".params[1].type.? = .{};
    if (@hasField(@TypeOf(e2e.?), "tool_deadline_s")) @field(e2e.?, "tool_deadline_s") = 3;
    try frames.setHello("/d/agent-home", e2e);
    try std.testing.expectEqual(@as(i64, 3), frames.toolDeadlineS());
}
