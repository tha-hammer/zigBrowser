const std = @import("std");
const uri = @import("uri.zig");

pub const max_url_len: usize = 2048;

pub const ConfigError = error{
    InvalidJson,
    MissingUrl,
    EmptyUrl,
    UrlTooLong,
    InvalidUri,
    UnsupportedScheme,
    RelativeUri,
};

pub const SiteConfig = struct {
    url: []const u8,
};

const RawConfig = struct {
    url: ?[]const u8 = null,
};

pub fn parse(allocator: std.mem.Allocator, json: []const u8) ConfigError!SiteConfig {
    const raw = std.json.parseFromSliceLeaky(RawConfig, allocator, json, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return error.InvalidJson;

    const url = raw.url orelse return error.MissingUrl;
    if (url.len == 0) return error.EmptyUrl;
    if (url.len > max_url_len) return error.UrlTooLong;

    uri.checkAllowed(url) catch |err| return switch (err) {
        error.InvalidUri => error.InvalidUri,
        error.UnsupportedScheme => error.UnsupportedScheme,
        error.RelativeUri => error.RelativeUri,
    };

    return .{ .url = url };
}
