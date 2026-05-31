const std = @import("std");

const cli = @import("cli.zig");
const errors = @import("errors.zig");
const uri = @import("uri.zig");
const webkit = @import("webkit.zig");

const c = @cImport({
    @cInclude("webkit_shim.h");
});

pub fn run(arena: std.mem.Allocator, command: cli.Command) errors.BrowserError!u8 {
    return switch (command) {
        .version => 0,
        .usage => error.Usage,
        .open => |spec| runOpen(arena, spec),
        .screenshot => |spec| runScreenshot(arena, spec),
    };
}

fn runOpen(arena: std.mem.Allocator, spec: cli.Command.open) errors.BrowserError!u8 {
    const valid_uri = uri.validate(arena, spec.url) catch |err| {
        return mapUriErr(err);
    };

    const code = c.zb_app_run(valid_uri.ptr, if (spec.print_title) 1 else 0,
        if (spec.e2e_protocol) 1 else 0);
    return @intCast(code);
}

fn runScreenshot(arena: std.mem.Allocator, spec: cli.Command.screenshot) errors.BrowserError!u8 {
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
