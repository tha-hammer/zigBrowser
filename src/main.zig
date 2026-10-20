const std = @import("std");
const builtin = @import("builtin");

const app = @import("app.zig");
const cli = @import("cli.zig");
const errors = @import("errors.zig");
const uri = @import("uri.zig");
const webkit = @import("webkit.zig");

/// MS1 (2026-10-19): zig 0.16's segfault handler mishandles the x86_64 macOS signal
/// `ucontext_t` — `std.debug.cpu_context.fromPosixSignalContext` panics "incorrect alignment"
/// (`@alignCast`). An ad-hoc code-signed x86_64 binary takes a signal that handler would catch
/// and aborts at startup, while the unsigned binary runs cleanly. We therefore disable zig's
/// segfault handler on macOS ONLY; every other target keeps the exact default
/// (`std.debug.default_enable_segfault_handler`), so the Linux build is unchanged.
pub const std_options: std.Options = .{
    .enable_segfault_handler = builtin.os.tag != .macos and std.debug.default_enable_segfault_handler,
};

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
                    "                  [--agent-secret-store secret-service|file]\n" ++
                    "       zigBrowser --agent-setup [--sai-source DIR] [--e2e-protocol]\n" ++
                    "       zigBrowser --screenshot <out.png> <URL> [--print-title]\n" ++
                    "                  [--hardware-acceleration never|always|webkit] [--renderer default|shm|mesa-egl]\n" ++
                    "                  [--media-source on|off]\n",
            );
            std.process.exit(errors.exitCode(error.Usage));
        },
        .agent_route_removed => {
            try writeStderr(init, "zigBrowser: --agent-token-route was removed: the token reaches the Claude CLI only on fd 3 (R1)\n");
            std.process.exit(2);
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
            // The URI's own message first (a check, no native call), as before.
            _ = uri.validate(arena, spec.url) catch |err| {
                try reportUriError(init, err, spec.url);
                std.process.exit(errors.exitCode(mapUriErr(err)));
            };
            // j76 (RoseCat 6564): through app.runWithIo, as `.open`, so the startup's flag step
            // (backend_flag.startup) decides every present flag before the one native apply.
            const code = app.runWithIo(arena, init.io, command) catch |err| {
                if (err == error.WriteFailed) try writeStderr(init, "failed to allocate output path\n");
                std.process.exit(errors.exitCode(err));
            };
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
