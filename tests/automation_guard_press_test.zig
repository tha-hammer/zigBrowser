//! S8a red (RoseCat on 9295b0b, SHOULD): a selectorless dom.press has no target of its own to
//! re-resolve, so `options.guard.target` on it is BadArgs (it could only ever stop with
//! target_changed). A press with a selector keeps the target check, and a selectorless press may
//! still carry marks.

const std = @import("std");
const automation = @import("automation");

const router = automation.router;

const testing = std.testing;
const gpa = testing.allocator;

test "a selectorless dom.press with guard.target is BadArgs" {
    try testing.expectError(error.BadArgs, router.parse(gpa, "dom.press", "{\"key\":\"Enter\",\"options\":{\"guard\":{\"target\":true}}}", .{}));
    try testing.expectError(error.BadArgs, router.parse(gpa, "dom.press", "{\"key\":\"Enter\",\"options\":{\"guard\":{\"marks\":[{\"selector\":\"css=#account\",\"value\":\"alice\"}],\"target\":true}}}", .{}));
}

test "a press with a selector keeps the target check; a selectorless press may carry marks" {
    var with_selector = try router.parse(gpa, "dom.press", "{\"selector\":\"css=#msg\",\"key\":\"Enter\",\"options\":{\"guard\":{\"target\":true}}}", .{});
    defer with_selector.deinit();
    try testing.expect(with_selector.guard.?.target);
    var marks_only = try router.parse(gpa, "dom.press", "{\"key\":\"Enter\",\"options\":{\"guard\":{\"marks\":[{\"selector\":\"css=#account\",\"value\":\"alice\"}]}}}", .{});
    defer marks_only.deinit();
    try testing.expectEqual(@as(usize, 1), marks_only.guard.?.marks.len);
}
