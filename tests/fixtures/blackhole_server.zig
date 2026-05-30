const std = @import("std");

pub const Server = struct {
    io: std.Io,
    child: std.process.Child,
    port: u16,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Server {
        var attempt: usize = 0;
        while (attempt < 32) : (attempt += 1) {
            const port: u16 = @as(u16, 39100) + @as(u16, @intCast(attempt));
            const script = try std.fmt.allocPrint(
                allocator,
                "import socket,time; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('127.0.0.1', {d})); s.listen(16); time.sleep(120)",
                .{port},
            );
            defer allocator.free(script);

            var child = std.process.spawn(io, .{
                .argv = &.{ "python3", "-c", script },
                .stdin = .ignore,
                .stdout = .ignore,
                .stderr = .ignore,
            }) catch |err| switch (err) {
                error.FileNotFound => return error.FileNotFound,
                else => continue,
            };

            waitUntilReady(allocator, io, port) catch {
                child.kill(io);
                continue;
            };

            return .{ .io = io, .child = child, .port = port };
        }

        return error.ConnectionRefused;
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
    const probe_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/", .{port});
    defer allocator.free(probe_url);

    var attempts: usize = 0;
    while (attempts < 50) : (attempts += 1) {
        const result = std.process.run(allocator, io, .{
            .argv = &.{ "curl", "--silent", "--output", "/dev/null", "--connect-timeout", "1", "--max-time", "2", probe_url },
            .stdout_limit = .unlimited,
            .stderr_limit = .unlimited,
        }) catch continue;
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        switch (result.term) {
            .exited => |code| if (code != 7) return,
            else => {},
        }
    }
    return error.ConnectionRefused;
}
