const std = @import("std");

pub const AutomationError = enum {
    element_not_found,
    element_not_visible,
    element_not_stable,
    element_obscured,
    element_disabled,
    element_not_editable,
    navigation_timeout,
    navigation_failed,
    action_timeout,
    platform_rate_limited,
    session_invalid,
    cancelled,
};

pub const error_count = @typeInfo(AutomationError).@"enum".fields.len;

pub fn name(err: AutomationError) []const u8 {
    return @tagName(err);
}

pub fn downstreamCode(err: AutomationError) i32 {
    return -32001 - @as(i32, @intCast(@intFromEnum(err)));
}

pub fn isRetryable(err: AutomationError) bool {
    return switch (err) {
        .element_not_found,
        .element_not_visible,
        .element_not_stable,
        .element_obscured,
        .element_disabled,
        .element_not_editable,
        .platform_rate_limited,
        => true,
        .navigation_timeout,
        .navigation_failed,
        .action_timeout,
        .session_invalid,
        .cancelled,
        => false,
    };
}

pub fn fromName(text: []const u8) !AutomationError {
    inline for (@typeInfo(AutomationError).@"enum".fields) |field| {
        if (std.mem.eql(u8, text, field.name)) {
            return @enumFromInt(field.value);
        }
    }
    return error.UnknownAutomationError;
}
