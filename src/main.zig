const std = @import("std");

const cli = @import("cli.zig");
const errors = @import("errors.zig");
const uri = @import("uri.zig");
const webkit = @import("webkit.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const command = cli.parseArgs(args);

    switch (command) {
        .version => {
            var version_buf: [160]u8 = undefined;
            const version = webkit.versionLine(&version_buf);

            var line_buf: [192]u8 = undefined;
            const line = try std.fmt.bufPrint(&line_buf, "{s}\n", .{version});
            try writeStdout(init, line);
            std.process.exit(0);
        },
        .usage => {
            try writeStderr(
                init,
                "usage: zigBrowser --version\n" ++
                    "       zigBrowser <URL> [--print-title] [--e2e-protocol]\n" ++
                    "       zigBrowser --screenshot <out.png> <URL> [--print-title]\n",
            );
            std.process.exit(errors.exitCode(error.Usage));
        },
        .open => |spec| {
            const valid_uri = uri.validate(arena, spec.url) catch |err| {
                try reportUriError(init, err, spec.url);
                std.process.exit(errors.exitCode(mapUriErr(err)));
            };

            const code = webkit.c.zb_app_run(
                valid_uri.ptr,
                if (spec.print_title) 1 else 0,
                if (spec.e2e_protocol) 1 else 0,
            );
            std.process.exit(@intCast(code));
        },
        .screenshot => |spec| {
            const valid_uri = uri.validate(arena, spec.url) catch |err| {
                try reportUriError(init, err, spec.url);
                std.process.exit(errors.exitCode(mapUriErr(err)));
            };

            const out_z = arena.dupeZ(u8, spec.out) catch {
                try writeStderr(init, "failed to allocate output path\n");
                std.process.exit(errors.exitCode(error.WriteFailed));
            };

            const code = webkit.runScreenshot(valid_uri, out_z, spec.print_title);
            std.process.exit(@intCast(code));
        },
    }
}

fn mapUriErr(err: uri.UriError) anyerror {
    return switch (err) {
        error.InvalidUri => error.InvalidUri,
        error.UnsupportedScheme => error.UnsupportedScheme,
        error.RelativeUri => error.InvalidUri,
    };
}

fn reportUriError(init: std.process.Init, err: uri.UriError, text: []const u8) !void {
    const msg = switch (err) {
        error.InvalidUri => "invalid URI",
        error.UnsupportedScheme => "unsupported URI scheme (allowed: file, http, https)",
        error.RelativeUri => "relative URI is not allowed",
    };

    var buffer: [1024]u8 = undefined;
    const line = try std.fmt.bufPrint(&buffer, "{s}: {s}\n", .{ msg, text });
    try writeStderr(init, line);
}

fn writeStdout(init: std.process.Init, text: []const u8) !void {
    var out_buffer: [2048]u8 = undefined;
    var writer: std.Io.File.Writer = .init(.stdout(), init.io, &out_buffer);
    try writer.interface.writeAll(text);
    try writer.interface.flush();
}

fn writeStderr(init: std.process.Init, text: []const u8) !void {
    var err_buffer: [2048]u8 = undefined;
    var writer: std.Io.File.Writer = .init(.stderr(), init.io, &err_buffer);
    try writer.interface.writeAll(text);
    try writer.interface.flush();
}
