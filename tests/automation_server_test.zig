const std = @import("std");
const automation_server = @import("automation_server");

const net = std.Io.net;
const testing = std.testing;

test "automation API server listens on UDS and round-trips length-prefixed JSON-RPC" {
    if (!net.has_unix_sockets) return error.AddressFamilyUnsupported;

    const socket_path = try std.fmt.allocPrint(
        testing.allocator,
        "/tmp/zigbrowser-automation-server-{x}.sock",
        .{testing.random_seed},
    );
    defer testing.allocator.free(socket_path);
    cleanupSocketPath(socket_path);
    defer cleanupSocketPath(socket_path);

    var server = try automation_server.AutomationApiServer.init(testing.allocator, testing.io, .{
        .enabled = true,
        .socket_path = socket_path,
        .token = "",
    });
    defer server.deinit();

    try server.start();
    defer server.stop();

    const address = try net.UnixAddress.init(socket_path);
    var stream = try address.connect(testing.io);
    defer stream.close(testing.io);

    try writeFrame(
        stream,
        "{\"jsonrpc\":\"2.0\",\"method\":\"page.url\",\"params\":{},\"id\":1}",
    );

    const response = try readFrame(stream);
    defer testing.allocator.free(response);

    try testing.expect(std.mem.indexOf(u8, response, "\"jsonrpc\":\"2.0\"") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\"id\":1") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\"method\":\"page.url\"") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\"ok\":true") != null);

    server.stop();
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, socket_path, .{}));
}

fn writeFrame(stream: net.Stream, payload: []const u8) !void {
    var header: [4]u8 = undefined;
    std.mem.writeInt(u32, &header, @intCast(payload.len), .big);

    var writer_buf: [1024]u8 = undefined;
    var writer = stream.writer(testing.io, &writer_buf);
    try writer.interface.writeAll(&header);
    try writer.interface.writeAll(payload);
    try writer.interface.flush();
}

fn readFrame(stream: net.Stream) ![]u8 {
    var reader_buf: [1024]u8 = undefined;
    var reader = stream.reader(testing.io, &reader_buf);

    var header: [4]u8 = undefined;
    try reader.interface.readSliceAll(&header);
    const len = std.mem.readInt(u32, &header, .big);

    const payload = try testing.allocator.alloc(u8, len);
    errdefer testing.allocator.free(payload);
    try reader.interface.readSliceAll(payload);
    return payload;
}

fn cleanupSocketPath(path: []const u8) void {
    std.Io.Dir.deleteFileAbsolute(testing.io, path) catch {};
}
