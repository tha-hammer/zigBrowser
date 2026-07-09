const std = @import("std");
const automation = @import("automation");

const automation_error = automation.errors;

test "AutomationError exposes stable names, downstream codes, and retryability" {
    const cases = [_]struct {
        err: automation_error.AutomationError,
        name: []const u8,
        code: i32,
        retryable: bool,
    }{
        .{ .err = .element_not_found, .name = "element_not_found", .code = -32001, .retryable = true },
        .{ .err = .element_not_visible, .name = "element_not_visible", .code = -32002, .retryable = true },
        .{ .err = .element_not_stable, .name = "element_not_stable", .code = -32003, .retryable = true },
        .{ .err = .element_obscured, .name = "element_obscured", .code = -32004, .retryable = true },
        .{ .err = .element_disabled, .name = "element_disabled", .code = -32005, .retryable = true },
        .{ .err = .element_not_editable, .name = "element_not_editable", .code = -32006, .retryable = true },
        .{ .err = .navigation_timeout, .name = "navigation_timeout", .code = -32007, .retryable = false },
        .{ .err = .navigation_failed, .name = "navigation_failed", .code = -32008, .retryable = false },
        .{ .err = .action_timeout, .name = "action_timeout", .code = -32009, .retryable = false },
        .{ .err = .platform_rate_limited, .name = "platform_rate_limited", .code = -32010, .retryable = true },
        .{ .err = .session_invalid, .name = "session_invalid", .code = -32011, .retryable = false },
        .{ .err = .cancelled, .name = "cancelled", .code = -32012, .retryable = false },
    };

    try std.testing.expectEqual(cases.len, automation_error.error_count);
    for (cases) |case| {
        try std.testing.expectEqualStrings(case.name, automation_error.name(case.err));
        try std.testing.expectEqual(case.code, automation_error.downstreamCode(case.err));
        try std.testing.expectEqual(case.retryable, automation_error.isRetryable(case.err));
        try std.testing.expectEqual(case.err, try automation_error.fromName(case.name));
    }
}

test "AutomationError rejects unknown names" {
    try std.testing.expectError(error.UnknownAutomationError, automation_error.fromName("timeout"));
    try std.testing.expectError(error.UnknownAutomationError, automation_error.fromName("cookies_denied"));
}
