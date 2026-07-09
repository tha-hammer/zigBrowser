const std = @import("std");

pub const LoginCheckResult = struct {
    logged_in: bool,
    platform: []const u8,
    username: ?[]const u8,
};

pub const LoginCheckScriptResult = struct {
    logged_in: bool,
    username: ?[]const u8,
};

pub fn loginCheck(port: anytype) LoginCheckResult {
    const url = port.getPageUrl();
    const platform = detectPlatform(url);
    const script_result = port.evalLoginCheck();
    return .{
        .logged_in = script_result.logged_in,
        .platform = platform,
        .username = script_result.username,
    };
}

pub const PacingState = struct {
    remaining_actions: u32,
    reset_at: []const u8,
    daily_cap: u32,
};

pub const RateStatusResult = struct {
    remaining_actions: u32,
    reset_at: []const u8,
    daily_cap: u32,
};

pub fn rateStatus(pacing: anytype) RateStatusResult {
    const state = pacing.getState();
    return .{
        .remaining_actions = state.remaining_actions,
        .reset_at = state.reset_at,
        .daily_cap = state.daily_cap,
    };
}

pub const PauseParams = struct {
    duration_ms: u32,
};

pub const OkResult = struct {
    ok: bool,
};

pub fn pause(queue: anytype, params: PauseParams) OkResult {
    queue.pauseFor(params.duration_ms);
    return .{ .ok = true };
}

pub const SetPacingParams = struct {
    min_delay_ms: u32 = 3000,
    max_delay_ms: u32 = 8000,
    daily_cap: u32 = 100,
};

pub fn setPacing(pacing: anytype, params: SetPacingParams) !OkResult {
    if (params.min_delay_ms > params.max_delay_ms) return error.InvalidParams;
    pacing.configure(params);
    return .{ .ok = true };
}

pub fn detectPlatform(url: []const u8) []const u8 {
    if (std.mem.indexOf(u8, url, "linkedin.com") != null) return "linkedin";
    if (std.mem.indexOf(u8, url, "instagram.com") != null) return "instagram";
    return "unknown";
}
