const std = @import("std");
const uri = @import("uri");

test "uri.validate accepts file/http/https and canonicalizes expected forms" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const file_hostless = try uri.validate(arena, "file:///tmp/live.html");
    try std.testing.expectEqualStrings("file:///tmp/live.html", file_hostless);

    const file_minimal = try uri.validate(arena, "file:/tmp/live.html");
    try std.testing.expectEqualStrings("file:///tmp/live.html", file_minimal);

    const http_default_path = try uri.validate(arena, "http://example.com");
    try std.testing.expectEqualStrings("http://example.com/", http_default_path);

    const https_keeps_components = try uri.validate(arena, "https://example.com:8443/a/b?x=1#frag");
    try std.testing.expectEqualStrings("https://example.com:8443/a/b?x=1#frag", https_keeps_components);
}

test "uri.validate rejects unsupported schemes and relative inputs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(error.UnsupportedScheme, uri.validate(arena, "javascript:alert(1)"));
    try std.testing.expectError(error.UnsupportedScheme, uri.validate(arena, "ftp://example.com/resource"));
    try std.testing.expectError(error.RelativeUri, uri.validate(arena, "index.html"));
    try std.testing.expectError(error.InvalidUri, uri.validate(arena, "http://"));
    try std.testing.expectError(error.InvalidUri, uri.validate(arena, "file:relative"));
}

test "uri.validate property: validate(canonical(x)) == canonical(x)" {
    const samples = [_][]const u8{
        "file:///tmp/a.html",
        "file://localhost/tmp/b.html?x=1",
        "http://example.com",
        "https://example.com/path?q=1#sec",
        "HTTPS://Example.com:443/path",
    };

    for (samples) |sample| {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const canonical = try uri.validate(arena, sample);
        const canonical_again = try uri.validate(arena, canonical);
        try std.testing.expectEqualStrings(canonical, canonical_again);
    }
}
