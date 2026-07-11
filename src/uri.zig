const std = @import("std");

pub const UriError = error{ InvalidUri, UnsupportedScheme, RelativeUri };

pub fn checkAllowed(input: []const u8) UriError!void {
    if (isExplicitRelative(input)) {
        return error.RelativeUri;
    }

    const parsed = std.Uri.parse(input) catch return error.InvalidUri;

    if (parsed.scheme.len == 0) {
        return error.RelativeUri;
    }

    if (std.mem.eql(u8, parsed.scheme, "http") or std.mem.eql(u8, parsed.scheme, "https")) {
        if (parsed.host == null) return error.InvalidUri;
    } else if (std.mem.eql(u8, parsed.scheme, "about")) {
        // WebKit handles about:blank natively; pass through.
    } else if (!std.mem.eql(u8, parsed.scheme, "file")) {
        return error.UnsupportedScheme;
    }
}

fn isExplicitRelative(input: []const u8) bool {
    return std.mem.startsWith(u8, input, "./") or
        std.mem.startsWith(u8, input, "../") or
        std.mem.startsWith(u8, input, "/");
}

pub fn validate(arena: std.mem.Allocator, input: []const u8) UriError![:0]const u8 {
    try checkAllowed(input);
    return arena.dupeZ(u8, input) catch return error.InvalidUri;
}

test "checkAllowed validates URI without allocating" {
    try checkAllowed("https://example.com/");
    try checkAllowed("file:///tmp/index.html");
    try checkAllowed("about:blank");

    try std.testing.expectError(error.InvalidUri, checkAllowed("https://"));
    try std.testing.expectError(error.RelativeUri, checkAllowed("./relative"));
    try std.testing.expectError(error.RelativeUri, checkAllowed("../relative"));
    try std.testing.expectError(error.RelativeUri, checkAllowed("/relative"));
    try std.testing.expectError(error.UnsupportedScheme, checkAllowed("javascript:alert(1)"));
}

test "validate accepts file/http/https" {
    const allocator = std.testing.allocator;

    const file_uri = try validate(allocator, "file:///tmp/example.html");
    defer allocator.free(file_uri);

    const http_uri = try validate(allocator, "http://example.com/");
    defer allocator.free(http_uri);

    const https_uri = try validate(allocator, "https://example.com/");
    defer allocator.free(https_uri);
}

test "validate accepts about:blank" {
    const allocator = std.testing.allocator;
    const about_uri = try validate(allocator, "about:blank");
    defer allocator.free(about_uri);
    try std.testing.expectEqualStrings("about:blank", about_uri);
}

test "validate rejects unsupported schemes" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnsupportedScheme, validate(allocator, "javascript:alert(1)"));
    try std.testing.expectError(error.UnsupportedScheme, validate(allocator, "ftp://example.com"));
}

test "validate rejects malformed and relative URIs" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidUri, validate(allocator, "http://"));
    try std.testing.expectError(error.InvalidUri, validate(allocator, "[bad"));
    try std.testing.expectError(error.RelativeUri, validate(allocator, "./relative/path"));
}
