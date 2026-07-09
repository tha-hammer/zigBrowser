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

pub fn detectPlatform(url: []const u8) []const u8 {
    if (std.mem.indexOf(u8, url, "linkedin.com") != null) return "linkedin";
    if (std.mem.indexOf(u8, url, "instagram.com") != null) return "instagram";
    return "unknown";
}
