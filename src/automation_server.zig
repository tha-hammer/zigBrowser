const std = @import("std");
const automation = @import("automation.zig");
const automation_websocket = @import("automation_websocket.zig");

const net = std.Io.net;

const max_frame_bytes = 64 * 1024;

pub const Config = struct {
    enabled: bool = false,
    socket_path: []const u8 = "",
    token: []const u8 = "",
};

pub const AutomationApiServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config,
    listener: ?net.Server = null,
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .{ .raw = false },

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        config: Config,
    ) !AutomationApiServer {
        return .{
            .allocator = allocator,
            .io = io,
            .config = .{
                .enabled = config.enabled,
                .socket_path = try allocator.dupe(u8, config.socket_path),
                .token = try allocator.dupe(u8, config.token),
            },
        };
    }

    pub fn deinit(self: *AutomationApiServer) void {
        self.stop();
        self.allocator.free(self.config.socket_path);
        self.allocator.free(self.config.token);
        self.* = undefined;
    }

    pub fn start(self: *AutomationApiServer) !void {
        if (!self.config.enabled) return;
        if (!net.has_unix_sockets) return error.AddressFamilyUnsupported;
        if (self.listener != null) return;

        try cleanupSocketPath(self.io, self.config.socket_path);
        const address = try net.UnixAddress.init(self.config.socket_path);
        self.listener = try address.listen(self.io, .{});
        self.stopping.store(false, .release);
        self.thread = try std.Thread.spawn(.{}, serveLoop, .{self});
    }

    pub fn stop(self: *AutomationApiServer) void {
        const had_listener = self.listener != null;
        self.stopping.store(true, .release);

        if (self.thread) |thread| {
            wakeAccept(self.io, self.config.socket_path);
            thread.join();
            self.thread = null;
        }

        if (self.listener) |*listener| {
            listener.deinit(self.io);
            self.listener = null;
        }

        if (had_listener) cleanupSocketPath(self.io, self.config.socket_path) catch {};
    }

    fn serveLoop(self: *AutomationApiServer) void {
        while (!self.stopping.load(.acquire)) {
            var stream = self.listener.?.accept(self.io) catch |err| {
                if (self.stopping.load(.acquire)) break;
                switch (err) {
                    error.SocketNotListening,
                    error.ConnectionAborted,
                    error.WouldBlock,
                    => continue,
                    else => break,
                }
            };
            defer stream.close(self.io);

            if (self.stopping.load(.acquire)) break;
            self.handleStream(stream) catch {};
        }
    }

    fn handleStream(self: *AutomationApiServer, stream: net.Stream) !void {
        var reader_buf: [4096]u8 = undefined;
        var reader = stream.reader(self.io, &reader_buf);
        var writer_buf: [4096]u8 = undefined;
        var writer = stream.writer(self.io, &writer_buf);

        var header: [4]u8 = undefined;
        reader.interface.readSliceAll(&header) catch return;
        if (std.mem.eql(u8, &header, "GET ")) {
            try handleWebSocketUpgrade(&reader, &writer, &header);
            return;
        }

        const payload_len = std.mem.readInt(u32, &header, .big);
        if (payload_len > max_frame_bytes) {
            const response = try jsonRpcError(std.heap.smp_allocator, "null", -32700, "Parse error");
            defer std.heap.smp_allocator.free(response);
            try writeFrame(&writer, response);
            return;
        }

        const payload = try std.heap.smp_allocator.alloc(u8, payload_len);
        defer std.heap.smp_allocator.free(payload);
        reader.interface.readSliceAll(payload) catch return;

        const response = handleRequest(std.heap.smp_allocator, payload, self.config.token) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => try jsonRpcError(std.heap.smp_allocator, "null", -32603, "Internal error"),
        };
        defer std.heap.smp_allocator.free(response);
        try writeFrame(&writer, response);
    }
};

fn handleRequest(allocator: std.mem.Allocator, payload: []const u8, token: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch {
        return jsonRpcError(allocator, "null", -32700, "Parse error");
    };
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |object| object,
        else => return jsonRpcError(allocator, "null", -32600, "Invalid Request"),
    };

    const id_json = try idJson(allocator, obj.get("id"));
    defer allocator.free(id_json);

    const jsonrpc = switch (obj.get("jsonrpc") orelse return jsonRpcError(allocator, id_json, -32600, "Invalid Request")) {
        .string => |value| value,
        else => return jsonRpcError(allocator, id_json, -32600, "Invalid Request"),
    };
    if (!std.mem.eql(u8, jsonrpc, "2.0")) {
        return jsonRpcError(allocator, id_json, -32600, "Invalid Request");
    }

    if (token.len > 0 and !requestHasToken(obj, token)) {
        return jsonRpcError(allocator, id_json, -32000, "Authentication failed");
    }

    const method = switch (obj.get("method") orelse return jsonRpcError(allocator, id_json, -32600, "Invalid Request")) {
        .string => |value| value,
        else => return jsonRpcError(allocator, id_json, -32600, "Invalid Request"),
    };
    if (method.len == 0) return jsonRpcError(allocator, id_json, -32600, "Invalid Request");

    const params_json = try paramsJson(allocator, obj.get("params"));
    defer allocator.free(params_json);

    var command = automation.router.parse(allocator, method, params_json, .{}) catch |err| switch (err) {
        error.UnknownCommand => return jsonRpcError(allocator, id_json, -32601, "Method not found"),
        error.BadArgs => return jsonRpcError(allocator, id_json, -32602, "Invalid params"),
    };
    defer command.deinit();

    const method_json = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(method, .{})});
    defer allocator.free(method_json);
    return std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"result\":{{\"ok\":true,\"method\":{s}}},\"id\":{s}}}",
        .{ method_json, id_json },
    );
}

fn requestHasToken(obj: std.json.ObjectMap, token: []const u8) bool {
    const auth = obj.get("auth") orelse return false;
    return switch (auth) {
        .string => |value| std.mem.eql(u8, value, token),
        else => false,
    };
}

fn paramsJson(allocator: std.mem.Allocator, maybe_params: ?std.json.Value) ![]u8 {
    const params = maybe_params orelse return allocator.dupe(u8, "{}");
    return switch (params) {
        .object => std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(params, .{})}),
        else => error.InvalidParams,
    };
}

fn idJson(allocator: std.mem.Allocator, maybe_id: ?std.json.Value) ![]u8 {
    const id = maybe_id orelse return allocator.dupe(u8, "null");
    return switch (id) {
        .null,
        .integer,
        .number_string,
        .string,
        => std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(id, .{})}),
        else => allocator.dupe(u8, "null"),
    };
}

fn jsonRpcError(
    allocator: std.mem.Allocator,
    id_json: []const u8,
    code: i64,
    message: []const u8,
) ![]u8 {
    const message_json = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(message, .{})});
    defer allocator.free(message_json);
    return std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"error\":{{\"code\":{},\"message\":{s}}},\"id\":{s}}}",
        .{ code, message_json, id_json },
    );
}

fn writeFrame(writer: anytype, payload: []const u8) !void {
    var header: [4]u8 = undefined;
    std.mem.writeInt(u32, &header, @intCast(payload.len), .big);
    try writer.interface.writeAll(&header);
    try writer.interface.writeAll(payload);
    try writer.interface.flush();
}

fn handleWebSocketUpgrade(reader: anytype, writer: anytype, initial: *const [4]u8) !void {
    var request: [4096]u8 = undefined;
    @memcpy(request[0..4], initial);
    var len: usize = 4;
    while (len < request.len) : (len += 1) {
        try reader.interface.readSliceAll(request[len .. len + 1]);
        if (len >= 3 and std.mem.eql(u8, request[len - 3 .. len + 1], "\r\n\r\n")) {
            len += 1;
            break;
        }
    }
    const request_text = request[0..len];
    const key = webSocketHeader(request_text, "Sec-WebSocket-Key") orelse return;

    const accept = try automation_websocket.secWebSocketAccept(std.heap.smp_allocator, key);
    defer std.heap.smp_allocator.free(accept);
    const response = try std.fmt.allocPrint(
        std.heap.smp_allocator,
        "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: {s}\r\n" ++
            "\r\n",
        .{accept},
    );
    defer std.heap.smp_allocator.free(response);

    const payload = try automation_websocket.eventNotificationJson(std.heap.smp_allocator, .{
        .method = "automation.ready",
        .params_json = "{\"status\":\"ready\"}",
    });
    defer std.heap.smp_allocator.free(payload);
    const frame = try automation_websocket.writeTextFrame(std.heap.smp_allocator, payload);
    defer std.heap.smp_allocator.free(frame);

    try writer.interface.writeAll(response);
    try writer.interface.writeAll(frame);
    try writer.interface.flush();
}

fn webSocketHeader(request: []const u8, comptime name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, request, "\r\n");
    const prefix = name ++ ":";
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        return std.mem.trim(u8, line[prefix.len..], " \t");
    }
    return null;
}

fn wakeAccept(io: std.Io, socket_path: []const u8) void {
    const address = net.UnixAddress.init(socket_path) catch return;
    var stream = address.connect(io) catch return;
    stream.close(io);
}

fn cleanupSocketPath(io: std.Io, socket_path: []const u8) !void {
    std.Io.Dir.deleteFileAbsolute(io, socket_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}
