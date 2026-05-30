const std = @import("std");
const errors = @import("../errors.zig");
const url_mod = @import("url.zig");

pub const NetError = errors.NetError;
pub const ParsedUrl = url_mod.ParsedUrl;

pub const Response = struct {
    status: u16,
    content_type: []const u8,
    bytes: []const u8,
};

pub const FETCH_TIMEOUT_MS: c_long = 30_000;

const marker_status = "__ZB_STATUS__:";
const marker_content_type = "__ZB_CTYPE__:";
const write_out_fmt = marker_status ++ "%{http_code}\\n" ++ marker_content_type ++ "%{content_type}";

pub fn fetch(arena: std.mem.Allocator, io: std.Io, url: ParsedUrl) NetError!Response {
    const serialized = url_mod.serialize(arena, url);

    const run_result = std.process.run(arena, io, .{
        .argv = &.{
            "curl",
            "--silent",
            "--show-error",
            "--location",
            "--max-redirs",
            "10",
            "--max-time",
            "30",
            "--output",
            "-",
            "--write-out",
            write_out_fmt,
            serialized,
        },
        .stdout_limit = .unlimited,
        .stderr_limit = .unlimited,
    }) catch |err| switch (err) {
        error.Timeout => return error.Timeout,
        else => return error.TransferFailed,
    };

    switch (run_result.term) {
        .exited => |code| if (code != 0) return mapCurlExit(code),
        else => return error.TransferFailed,
    }

    const status_pos = std.mem.lastIndexOf(u8, run_result.stdout, marker_status) orelse return error.TransferFailed;
    const body = run_result.stdout[0..status_pos];
    const meta = run_result.stdout[status_pos + marker_status.len ..];

    const status_end = std.mem.indexOfScalar(u8, meta, '\n') orelse return error.TransferFailed;
    const status_slice = meta[0..status_end];
    const status = std.fmt.parseUnsigned(u16, status_slice, 10) catch return error.TransferFailed;

    const content_meta = meta[status_end + 1 ..];
    if (!std.mem.startsWith(u8, content_meta, marker_content_type)) return error.TransferFailed;

    const raw_content_type = content_meta[marker_content_type.len..];
    const content_type = trimLineEndings(raw_content_type);

    return .{
        .status = status,
        .content_type = arena.dupe(u8, if (content_type.len == 0) "application/octet-stream" else content_type) catch return error.TransferFailed,
        .bytes = arena.dupe(u8, body) catch return error.TransferFailed,
    };
}

fn mapCurlExit(code: u8) NetError {
    return switch (code) {
        6 => error.DnsFailed,
        7 => error.ConnectionRefused,
        28 => error.Timeout,
        35 => error.TlsError,
        51, 60 => error.CertInvalid,
        else => error.TransferFailed,
    };
}

fn trimLineEndings(input: []const u8) []const u8 {
    var end = input.len;
    while (end > 0) {
        const ch = input[end - 1];
        if (ch == '\n' or ch == '\r') {
            end -= 1;
            continue;
        }
        break;
    }
    return input[0..end];
}

test "fetch-success and fetch-404 via static fixture" {
    const static_server = @import("fixture_static");

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var server = try static_server.Server.init(std.testing.allocator, std.testing.io);
    defer server.deinit();

    const ok_url = try server.url(arena, "/index.html");
    const ok_parsed = try url_mod.parse(arena, ok_url);
    const ok_response = try fetch(arena, std.testing.io, ok_parsed);
    try std.testing.expectEqual(@as(u16, 200), ok_response.status);
    try std.testing.expect(std.mem.indexOf(u8, ok_response.bytes, "Hello from zigBrowser fixture") != null);

    const missing_url = try server.url(arena, "/missing.html");
    const missing_parsed = try url_mod.parse(arena, missing_url);
    const missing_response = try fetch(arena, std.testing.io, missing_parsed);
    try std.testing.expectEqual(@as(u16, 404), missing_response.status);
}

test "fetch-bad-cert and timeout fixtures" {
    const tls_server = @import("fixture_tls");
    const blackhole = @import("fixture_blackhole");

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tls = try tls_server.Server.init(std.testing.allocator, std.testing.io);
    defer tls.deinit();

    const tls_url = try tls.url(arena, "/");
    const tls_parsed = try url_mod.parse(arena, tls_url);
    try std.testing.expectError(error.CertInvalid, fetch(arena, std.testing.io, tls_parsed));

    var hole = try blackhole.Server.init(std.testing.allocator, std.testing.io);
    defer hole.deinit();

    const hole_url = try hole.url(arena, "/");
    const hole_parsed = try url_mod.parse(arena, hole_url);
    try std.testing.expectError(error.Timeout, fetch(arena, std.testing.io, hole_parsed));
}
