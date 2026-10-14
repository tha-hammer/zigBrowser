const std = @import("std");

const app = @import("app.zig");
const cli = @import("cli.zig");
const errors = @import("errors.zig");
const render_config = @import("render_config.zig");
const uri = @import("uri.zig");
const webkit = @import("webkit.zig");

comptime {
    _ = @import("ipc.zig");
    _ = @import("nav_policy.zig");
}

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
                    "                  [--hardware-acceleration never|always|webkit] [--renderer default|shm|mesa-egl]\n" ++
                    "                  [--media-source on|off] [--agent-drawer on|off]\n" ++
                    "       zigBrowser --agent-setup [--sai-source DIR] [--agent-token-route r1|env] [--e2e-protocol]\n" ++
                    "       zigBrowser --screenshot <out.png> <URL> [--print-title]\n" ++
                    "                  [--hardware-acceleration never|always|webkit] [--renderer default|shm|mesa-egl]\n" ++
                    "                  [--media-source on|off]\n",
            );
            std.process.exit(errors.exitCode(error.Usage));
        },
        .open => |spec| {
            const code = app.runWithIo(arena, init.io, command) catch |err| {
                switch (err) {
                    error.InvalidUri => try reportUriError(init, error.InvalidUri, spec.url),
                    error.UnsupportedScheme => try reportUriError(init, error.UnsupportedScheme, spec.url),
                    else => {},
                }
                std.process.exit(errors.exitCode(err));
            };
            std.process.exit(@intCast(code));
        },
        .agent_setup => {
            const code = app.runWithIo(arena, init.io, command) catch |err| std.process.exit(errors.exitCode(err));
            std.process.exit(code);
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

            // The same rendering and media settings as an open window (applied before WebKit starts).
            const code = webkit.runScreenshot(valid_uri, out_z, spec.print_title, render_config.resolve(spec.hw_policy, spec.renderer), spec.media_source);
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
