const std = @import("std");
const builtin = @import("builtin");

const net = std.Io.net;
const testing = std.testing;

test "P2.0 AF_UNIX roundtrip exchanges bytes without TCP" {
    if (!net.has_unix_sockets) {
        std.debug.print("FAIL\tafunix-windows\tAddressFamilyUnsupported\n", .{});
        return error.AddressFamilyUnsupported;
    }

    const allocator = testing.allocator;
    const socket_path = try socketPath(allocator);
    defer allocator.free(socket_path);

    try testing.expect(socket_path.len < net.UnixAddress.max_len);
    try cleanupSocketPath(socket_path);
    defer cleanupSocketPath(socket_path) catch {};

    const address = net.UnixAddress.init(socket_path) catch |err| switch (err) {
        error.NameTooLong => return err,
    };
    var server = address.listen(testing.io, .{}) catch |err| switch (err) {
        error.AddressFamilyUnsupported => return error.AddressFamilyUnsupported,
        else => return err,
    };
    defer server.deinit(testing.io);

    const client_thread = try std.Thread.spawn(.{}, clientRoundtrip, .{socket_path});

    var accepted = try server.accept(testing.io);
    defer accepted.close(testing.io);

    var accepted_reader_buf: [32]u8 = undefined;
    var accepted_reader = accepted.reader(testing.io, &accepted_reader_buf);
    var ping: [5]u8 = undefined;
    try accepted_reader.interface.readSliceAll(&ping);
    try testing.expectEqualStrings("ping\n", &ping);

    var accepted_writer_buf: [32]u8 = undefined;
    var accepted_writer = accepted.writer(testing.io, &accepted_writer_buf);
    try accepted_writer.interface.writeAll("pong\n");
    try accepted_writer.interface.flush();

    client_thread.join();

    std.debug.print("PASS\tafunix-windows\t{s}\n", .{socket_path});
}

fn clientRoundtrip(socket_path: []const u8) !void {
    const address = try net.UnixAddress.init(socket_path);
    var stream = address.connect(testing.io) catch |err| switch (err) {
        error.AddressFamilyUnsupported => return error.AddressFamilyUnsupported,
        else => return err,
    };
    defer stream.close(testing.io);

    var writer_buf: [32]u8 = undefined;
    var writer = stream.writer(testing.io, &writer_buf);
    try writer.interface.writeAll("ping\n");
    try writer.interface.flush();

    var reader_buf: [32]u8 = undefined;
    var reader = stream.reader(testing.io, &reader_buf);
    var pong: [5]u8 = undefined;
    try reader.interface.readSliceAll(&pong);
    try testing.expectEqualStrings("pong\n", &pong);
}

fn socketPath(allocator: std.mem.Allocator) ![]u8 {
    switch (builtin.os.tag) {
        .windows => {
            const local_app_data = try std.process.getEnvVarOwned(allocator, "LOCALAPPDATA");
            defer allocator.free(local_app_data);
            const dir = try std.fs.path.join(allocator, &.{ local_app_data, "zigbrowser" });
            defer allocator.free(dir);
            try std.Io.Dir.cwd().createDirPath(testing.io, dir);
            const name = try shortSocketName(allocator);
            defer allocator.free(name);
            return std.fs.path.join(allocator, &.{ dir, name });
        },
        else => {
            const name = try shortSocketName(allocator);
            defer allocator.free(name);
            return std.fs.path.join(allocator, &.{ "/tmp", name });
        },
    }
}

fn shortSocketName(allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator, "zb-afunix-{x}.sock", .{testing.random_seed});
}

fn cleanupSocketPath(path: []const u8) !void {
    std.Io.Dir.deleteFileAbsolute(testing.io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}
