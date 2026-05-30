const std = @import("std");
const errors = @import("../errors.zig");

pub const NetError = errors.NetError;

pub const ParsedUrl = struct {
    scheme: []const u8,
    host: []const u8,
    port: ?u16 = null,
    path: []const u8,
    query: ?[]const u8 = null,
    fragment: ?[]const u8 = null,
};

pub fn parse(arena: std.mem.Allocator, input: []const u8) NetError!ParsedUrl {
    const uri = std.Uri.parse(input) catch return error.InvalidUrl;
    return fromUri(arena, uri);
}

pub fn resolve(arena: std.mem.Allocator, base: ParsedUrl, ref: []const u8) NetError!ParsedUrl {
    const base_text = serialize(arena, base);
    const base_uri = std.Uri.parse(base_text) catch return error.InvalidUrl;

    const scratch_len = ref.len + base.path.len + 256;
    const scratch = arena.alloc(u8, scratch_len) catch return error.TransferFailed;
    @memcpy(scratch[0..ref.len], ref);
    var tail = scratch;

    const resolved = std.Uri.resolveInPlace(base_uri, ref.len, &tail) catch return error.InvalidUrl;
    return fromUri(arena, resolved);
}

pub fn serialize(arena: std.mem.Allocator, u: ParsedUrl) []const u8 {
    const text = std.fmt.allocPrint(
        arena,
        "{s}://{s}{s}{s}{s}",
        .{
            u.scheme,
            u.host,
            formatPort(arena, u.port),
            if (u.path.len == 0) "/" else u.path,
            formatQueryFragment(arena, u.query, u.fragment),
        },
    ) catch @panic("OOM in serialize");
    return text;
}

fn fromUri(arena: std.mem.Allocator, uri: std.Uri) NetError!ParsedUrl {
    const host_name = uri.getHostAlloc(arena) catch return error.InvalidUrl;
    const raw_path = uri.path.toRawMaybeAlloc(arena) catch return error.TransferFailed;
    const scheme = lowerAlloc(arena, uri.scheme) catch return error.TransferFailed;
    const host = lowerAlloc(arena, host_name.bytes) catch return error.TransferFailed;

    const query = if (uri.query) |q| q.toRawMaybeAlloc(arena) catch return error.TransferFailed else null;
    const fragment = if (uri.fragment) |f| f.toRawMaybeAlloc(arena) catch return error.TransferFailed else null;

    const normalized_port = blk: {
        if (uri.port) |p| {
            if (p == defaultPortForScheme(scheme)) break :blk null;
            break :blk p;
        }
        break :blk null;
    };

    return .{
        .scheme = scheme,
        .host = host,
        .port = normalized_port,
        .path = if (raw_path.len == 0) "/" else raw_path,
        .query = query,
        .fragment = fragment,
    };
}

fn lowerAlloc(arena: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error![]const u8 {
    const out = try arena.alloc(u8, input.len);
    for (input, 0..) |ch, idx| out[idx] = std.ascii.toLower(ch);
    return out;
}

fn defaultPortForScheme(scheme: []const u8) u16 {
    if (std.mem.eql(u8, scheme, "http")) return 80;
    if (std.mem.eql(u8, scheme, "https")) return 443;
    if (std.mem.eql(u8, scheme, "ws")) return 80;
    if (std.mem.eql(u8, scheme, "wss")) return 443;
    return 0;
}

fn formatPort(arena: std.mem.Allocator, port: ?u16) []const u8 {
    if (port) |p| {
        return std.fmt.allocPrint(arena, ":{d}", .{p}) catch @panic("OOM in formatPort");
    }
    return "";
}

fn formatQueryFragment(arena: std.mem.Allocator, query: ?[]const u8, fragment: ?[]const u8) []const u8 {
    if (query == null and fragment == null) return "";

    if (query != null and fragment != null) {
        return std.fmt.allocPrint(arena, "?{s}#{s}", .{ query.?, fragment.? }) catch @panic("OOM");
    }
    if (query != null) {
        return std.fmt.allocPrint(arena, "?{s}", .{query.?}) catch @panic("OOM");
    }
    return std.fmt.allocPrint(arena, "#{s}", .{fragment.?}) catch @panic("OOM");
}

test "url-parse-absolute" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try parse(arena, "https://a.com:8443/p?q=1#f");

    try std.testing.expectEqualStrings("https", parsed.scheme);
    try std.testing.expectEqualStrings("a.com", parsed.host);
    try std.testing.expectEqual(@as(?u16, 8443), parsed.port);
    try std.testing.expectEqualStrings("/p", parsed.path);
    try std.testing.expectEqualStrings("q=1", parsed.query.?);
    try std.testing.expectEqualStrings("f", parsed.fragment.?);
}

test "url-parse-invalid" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    try std.testing.expectError(error.InvalidUrl, parse(arena_state.allocator(), "::::"));
}

test "url-resolve-relative" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const base = try parse(arena, "https://example.com/a/b/c");
    const resolved = try resolve(arena, base, "../d?x=1");

    try std.testing.expectEqualStrings("https", resolved.scheme);
    try std.testing.expectEqualStrings("example.com", resolved.host);
    try std.testing.expectEqualStrings("/a/d", resolved.path);
    try std.testing.expectEqualStrings("x=1", resolved.query.?);
}

test "url parse/serialize round trip is idempotent" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const inputs = [_][]const u8{
        "https://example.com",
        "https://example.com:443/",
        "http://example.com:8080/p?q=1#f",
    };

    for (inputs) |input| {
        const p1 = try parse(arena, input);
        const s = serialize(arena, p1);
        const p2 = try parse(arena, s);

        try std.testing.expectEqualStrings(p1.scheme, p2.scheme);
        try std.testing.expectEqualStrings(p1.host, p2.host);
        try std.testing.expectEqual(p1.port, p2.port);
        try std.testing.expectEqualStrings(p1.path, p2.path);
    }
}
