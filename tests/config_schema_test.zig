const std = @import("std");
const config_schema = @import("config_schema");

test "parse extracts url from valid config" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const parsed = try config_schema.parse(arena.allocator(),
        \\{"url":"https://example.com/app"}
    );
    try std.testing.expectEqualStrings("https://example.com/app", parsed.url);
}

test "parse accepts file url" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const parsed = try config_schema.parse(arena.allocator(),
        \\{"url":"file:///tmp/app/index.html"}
    );
    try std.testing.expectEqualStrings("file:///tmp/app/index.html", parsed.url);
}

test "parse ignores unknown fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const parsed = try config_schema.parse(arena.allocator(),
        \\{"url":"https://example.com/app","title":"future","permissions":{"x":true}}
    );
    try std.testing.expectEqualStrings("https://example.com/app", parsed.url);
}

test "parse rejects missing url" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.MissingUrl, config_schema.parse(arena.allocator(), "{}"));
}

test "parse rejects empty url" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.EmptyUrl, config_schema.parse(arena.allocator(),
        \\{"url":""}
    ));
}

test "parse rejects malformed json" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidJson, config_schema.parse(arena.allocator(),
        \\{"url":
    ));
}

test "parse rejects non-string url" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidJson, config_schema.parse(arena.allocator(),
        \\{"url":42}
    ));
}

test "parse rejects unsupported scheme" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.UnsupportedScheme, config_schema.parse(arena.allocator(),
        \\{"url":"javascript:alert(1)"}
    ));
}

test "parse rejects relative url" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.RelativeUri, config_schema.parse(arena.allocator(),
        \\{"url":"./index.html"}
    ));
}

test "parse rejects overly long url" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const prefix = "https://example.com/";
    const url_len = config_schema.max_url_len + 1;
    const url = try allocator.alloc(u8, url_len);
    @memcpy(url[0..prefix.len], prefix);
    @memset(url[prefix.len..], 'a');

    const json = try std.fmt.allocPrint(allocator, "{{\"url\":\"{s}\"}}", .{url});
    try std.testing.expectError(error.UrlTooLong, config_schema.parse(allocator, json));
}
