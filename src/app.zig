const std = @import("std");
const builtin = @import("builtin");

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

    if (spec.automation_api) {
        // automation.js must be registered before zb_app_run builds the window.
        automation_gtk_port.installScript();
        const config = buildAutomationConfig(arena, io, spec) catch return error.WriteFailed;
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
    return .{
        .enabled = true,
        .socket_path = try automationSocketPath(allocator),
        .token = try automationToken(allocator, io, spec.automation_token_file),
        .page_port = automation_gtk_port.pagePort(),
    };
}

fn automationSocketPath(allocator: std.mem.Allocator) ![]const u8 {
    if (getenvOwned(allocator, "ZIGBROWSER_SOCKET")) |socket_path| {
        return socket_path;
    }

    const base_dir = getenvOwned(allocator, "XDG_RUNTIME_DIR") orelse try allocator.dupe(u8, "/tmp");
    const nonce: u64 = @intCast(std.c.getpid());
    return automation_transport.planSocketPath(allocator, platform(), base_dir, nonce);
}

fn getenvOwned(allocator: std.mem.Allocator, comptime name: [*:0]const u8) ?[]const u8 {
    const raw = std.c.getenv(name) orelse return null;
    return allocator.dupe(u8, std.mem.span(raw)) catch null;
}

fn automationToken(
    allocator: std.mem.Allocator,
    io: std.Io,
    token_file: ?[]const u8,
) ![]const u8 {
    const path = token_file orelse return "";
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4096));
    return std.mem.trim(u8, raw, &std.ascii.whitespace);
}

fn platform() automation_transport.Platform {
    return switch (builtin.os.tag) {
        .windows => .windows,
        .macos => .macos,
        else => .linux,
    };
}
