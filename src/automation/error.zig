const std = @import("std");

const downstream_code_base = -32001;

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
    /// -32013: a page dialog (alert, confirm, prompt, or the beforeunload
    /// "Leave site?" prompt) is open and blocks the command; dialog.get shows
    /// it, dialog.respond answers it.
    dialog_open,
};

pub const error_count = @typeInfo(AutomationError).@"enum".fields.len;

pub fn name(err: AutomationError) []const u8 {
    return @tagName(err);
}

pub fn downstreamCode(err: AutomationError) i32 {
    return downstream_code_base - @as(i32, @intCast(@intFromEnum(err)));
}

/// True for the downstream codes of this taxonomy (-32001 down to the last
/// variant's code), so telemetry never needs its own copy of the bounds.
pub fn isAutomationCode(code: i64) bool {
    return code <= downstream_code_base and code > downstream_code_base - @as(i64, error_count);
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
        .dialog_open,
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
