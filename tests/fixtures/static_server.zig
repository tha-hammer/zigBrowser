const std = @import("std");

pub const Server = struct {
    io: std.Io,
    child: std.process.Child,
    port: u16,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Server {
        const port: u16 = 38981;
        const port_text = try std.fmt.allocPrint(allocator, "{d}", .{port});
        defer allocator.free(port_text);

        const child = try std.process.spawn(io, .{
            .argv = &.{
                "python3",
                "-m",
                "http.server",
                port_text,
                "--bind",
                "127.0.0.1",
                "--directory",
                "tests/fixtures/www",
            },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });

        try waitUntilReady(allocator, io, port);

        return .{ .io = io, .child = child, .port = port };
    }

    pub fn deinit(self: *Server) void {
        self.child.kill(self.io);
    }

    pub fn url(self: *const Server, arena: std.mem.Allocator, path: []const u8) ![]const u8 {
        const normalized_path = if (std.mem.startsWith(u8, path, "/")) path else try std.fmt.allocPrint(arena, "/{s}", .{path});
        return std.fmt.allocPrint(arena, "http://127.0.0.1:{d}{s}", .{ self.port, normalized_path });
    }
};

fn waitUntilReady(allocator: std.mem.Allocator, io: std.Io, port: u16) !void {
    const probe_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/index.html", .{port});
    defer allocator.free(probe_url);

    var attempts: usize = 0;
    while (attempts < 30) : (attempts += 1) {
        const result = std.process.run(allocator, io, .{
            .argv = &.{ "curl", "--silent", "--output", "/dev/null", "--max-time", "1", probe_url },
            .stdout_limit = .unlimited,
            .stderr_limit = .unlimited,
        }) catch continue;
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        switch (result.term) {
            .exited => |code| if (code == 0) return,
            else => {},
        }
    }
    return error.ConnectionRefused;
}
