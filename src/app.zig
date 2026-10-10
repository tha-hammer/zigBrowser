const std = @import("std");
const builtin = @import("builtin");

const automation_gtk_cookie_port = @import("automation_gtk_cookie_port.zig");
const automation_gtk_port = @import("automation_gtk_port.zig");
const automation_server = @import("automation_server.zig");
const automation_transport = @import("automation_transport.zig");
const cli = @import("cli.zig");
const errors = @import("errors.zig");
const uri = @import("uri.zig");
const webkit = @import("webkit.zig");

const c = @cImport({
    @cInclude("webkit_shim.h");
});

const OpenSpec = @TypeOf(@as(cli.Command, .{ .open = undefined }).open);
const ScreenshotSpec = @TypeOf(@as(cli.Command, .{ .screenshot = undefined }).screenshot);

pub fn run(arena: std.mem.Allocator, command: cli.Command) errors.BrowserError!u8 {
    var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    return runWithIo(arena, threaded.io(), command);
}

pub fn runWithIo(arena: std.mem.Allocator, io: std.Io, command: cli.Command) errors.BrowserError!u8 {
    return switch (command) {
        .version => 0,
        .usage => error.Usage,
        .open => |spec| runOpen(arena, io, spec),
        .screenshot => |spec| runScreenshot(arena, spec),
    };
}

fn runOpen(arena: std.mem.Allocator, io: std.Io, spec: OpenSpec) errors.BrowserError!u8 {
    const valid_uri = uri.validate(arena, spec.url) catch |err| {
        return mapUriErr(err);
    };
    try applyProfileDir(arena, spec);

    if (spec.automation_api) {
        // automation.js must be registered before zb_app_run builds the window.
        automation_gtk_port.installScript();
        const config = buildAutomationConfig(arena, io, spec) catch |err| {
            if (err == error.EmptyTokenFile) std.debug.print("--automation-token-file is empty\n", .{});
            return error.WriteFailed;
        };
        var server = automation_server.AutomationApiServer.init(std.heap.smp_allocator, io, config) catch return error.WriteFailed;
        defer server.deinit();
        server.start() catch return error.WriteFailed;
        defer server.stop();

        const code = c.zb_app_run(valid_uri.ptr, if (spec.print_title) 1 else 0,
            if (spec.e2e_protocol) 1 else 0);
        return @intCast(code);
    }

    const code = c.zb_app_run(valid_uri.ptr, if (spec.print_title) 1 else 0,
        if (spec.e2e_protocol) 1 else 0);
    return @intCast(code);
}

/// Persistent profile for cookies and site data: --profile-dir, else the
/// default under $XDG_DATA_HOME or ~/.local/share. An explicit directory that
/// cannot be created is an error; when the default cannot be resolved or
/// created, the browser runs on WebKit's default context.
fn applyProfileDir(arena: std.mem.Allocator, spec: OpenSpec) errors.BrowserError!void {
    if (comptime builtin.os.tag != .linux) return;
    const explicit = spec.profile_dir != null;
    const dir = spec.profile_dir orelse
        (cli.defaultProfileDir(arena, getenvOwned(arena, "XDG_DATA_HOME"), getenvOwned(arena, "HOME")) catch null) orelse {
        // No profile resolved: make sure no earlier run's profile lingers.
        _ = c.zb_app_set_profile_dir(null, null);
        return;
    };
    const dir_z = arena.dupeZ(u8, dir) catch return error.WriteFailed;

    var err: [*c]u8 = null;
    if (c.zb_app_set_profile_dir(dir_z.ptr, &err) == c.ZB_AUTO_OK) return;
    defer c.zb_automation_free(err);
    // On failure the shim already cleared any previous profile.
    std.debug.print("profile: {s}\n", .{if (err != null) std.mem.span(err) else dir});
    if (explicit) return error.WriteFailed;
}

fn runScreenshot(arena: std.mem.Allocator, spec: ScreenshotSpec) errors.BrowserError!u8 {
    const valid_uri = uri.validate(arena, spec.url) catch |err| {
        return mapUriErr(err);
    };

    const out_z = arena.dupeZ(u8, spec.out) catch return error.WriteFailed;
    const code = webkit.runScreenshot(valid_uri, out_z, spec.print_title);
    return @intCast(code);
}

fn mapUriErr(err: uri.UriError) errors.BrowserError {
    return switch (err) {
        error.InvalidUri => error.InvalidUri,
        error.UnsupportedScheme => error.UnsupportedScheme,
        error.RelativeUri => error.InvalidUri,
    };
}

fn buildAutomationConfig(
    allocator: std.mem.Allocator,
    io: std.Io,
    spec: OpenSpec,
) !automation_server.Config {
    const socket_path = try automationSocketPath(allocator, io);
    const credentials = try automationCredentials(allocator, io, spec.automation_token_file, socket_path);
    return .{
        .enabled = true,
        .socket_path = socket_path,
        .token = credentials.token,
        .token_file_path = credentials.token_file_path,
        .page_port = automation_gtk_port.pagePort(),
        .cookie_port = automation_gtk_cookie_port.cookiePort(),
    };
}

fn automationSocketPath(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    if (getenvOwned(allocator, "ZIGBROWSER_SOCKET")) |socket_path| {
        return socket_path;
    }

    const base_dir = getenvOwned(allocator, "XDG_RUNTIME_DIR") orelse try allocator.dupe(u8, "/tmp");
    return automation_transport.planSocketPath(allocator, platform(), base_dir, try socketNonce(io));
}

/// Unpredictable socket-name nonce from OS entropy (no PID, no fallback), so
/// another local user cannot guess the default socket path.
fn socketNonce(io: std.Io) !u64 {
    var bytes: [8]u8 = undefined;
    try io.randomSecure(&bytes);
    return std.mem.readInt(u64, &bytes, .little);
}

test "default socket names use OS entropy, not the PID" {
    const io = std.testing.io;
    const a = try socketNonce(io);
    const b = try socketNonce(io);
    try std.testing.expect(a != b);
    try std.testing.expect(a != @as(u64, @intCast(std.c.getpid())));

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const path = try automation_transport.planSocketPath(arena.allocator(), platform(), "/run/user/1000", a);
    var pid_hex: [32]u8 = undefined;
    const pid_text = try std.fmt.bufPrint(&pid_hex, "{x}", .{@as(u64, @intCast(std.c.getpid()))});
    try std.testing.expect(std.mem.indexOf(u8, path, pid_text) == null or pid_text.len < 4);
}

fn getenvOwned(allocator: std.mem.Allocator, comptime name: [*:0]const u8) ?[]const u8 {
    const raw = std.c.getenv(name) orelse return null;
    return allocator.dupe(u8, std.mem.span(raw)) catch null;
}

const Credentials = struct {
    token: []const u8,
    /// Where the server publishes a generated token ("" for a user-supplied one).
    token_file_path: []const u8,
};

/// The automation API always requires a token. With --automation-token-file
/// the user supplies it (an empty or blank file is an error, never "no auth").
/// Otherwise a per-session token is generated from OS entropy and the server
/// writes it to <socket>.token (mode 0600) for local clients to read: any
/// process able to read that file, i.e. the same user, is trusted.
fn automationCredentials(
    allocator: std.mem.Allocator,
    io: std.Io,
    token_file: ?[]const u8,
    socket_path: []const u8,
) !Credentials {
    if (token_file) |path| {
        const raw = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4096));
        const token = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (token.len == 0) return error.EmptyTokenFile;
        return .{ .token = token, .token_file_path = "" };
    }
    return .{
        .token = try generateToken(allocator, io),
        .token_file_path = try std.fmt.allocPrint(allocator, "{s}.token", .{socket_path}),
    };
}

/// 32 bytes of OS entropy as 64 lower-case hex characters.
fn generateToken(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    var bytes: [32]u8 = undefined;
    try io.randomSecure(&bytes);
    const hex = std.fmt.bytesToHex(bytes, .lower);
    return allocator.dupe(u8, &hex);
}

test "generated automation tokens are 64 hex chars from OS entropy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = try generateToken(arena.allocator(), std.testing.io);
    const b = try generateToken(arena.allocator(), std.testing.io);
    try std.testing.expectEqual(@as(usize, 64), a.len);
    for (a) |ch| try std.testing.expect(std.ascii.isDigit(ch) or (ch >= 'a' and ch <= 'f'));
    try std.testing.expect(!std.mem.eql(u8, a, b));

    const creds = try automationCredentials(arena.allocator(), std.testing.io, null, "/run/zb.sock");
    try std.testing.expectEqual(@as(usize, 64), creds.token.len);
    try std.testing.expectEqualStrings("/run/zb.sock.token", creds.token_file_path);
}

fn platform() automation_transport.Platform {
    return switch (builtin.os.tag) {
        .windows => .windows,
        .macos => .macos,
        else => .linux,
    };
}
