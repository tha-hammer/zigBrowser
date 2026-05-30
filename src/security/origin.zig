const std = @import("std");
const url_mod = @import("../net/url.zig");

pub const Origin = struct {
    scheme: []const u8,
    host: []const u8,
    port: u16,
};

pub fn fromUrl(u: url_mod.ParsedUrl) Origin {
    return .{
        .scheme = u.scheme,
        .host = u.host,
        .port = u.port orelse defaultPortForScheme(u.scheme),
    };
}

pub fn eql(a: Origin, b: Origin) bool {
    return std.mem.eql(u8, a.scheme, b.scheme) and
        std.mem.eql(u8, a.host, b.host) and
        a.port == b.port;
}

pub fn defaultPortForScheme(scheme: []const u8) u16 {
    if (std.mem.eql(u8, scheme, "http")) return 80;
    if (std.mem.eql(u8, scheme, "https")) return 443;
    if (std.mem.eql(u8, scheme, "ws")) return 80;
    if (std.mem.eql(u8, scheme, "wss")) return 443;
    return 0;
}

test "origin normalization treats explicit default port as equal" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const a = try url_mod.parse(arena, "https://example.com");
    const b = try url_mod.parse(arena, "https://example.com:443");

    try std.testing.expect(eql(fromUrl(a), fromUrl(b)));
}
