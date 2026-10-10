const std = @import("std");
pub const automation = @import("automation.zig");
const automation_websocket = @import("automation_websocket.zig");

const net = std.Io.net;
const page_port = automation.page_port;
const engine_mod = automation.engine;
const queue_mod = automation.queue;

/// The automation API drives the primary window's page.
pub const primary_route = automation.router.RouteContext{ .page_id = "page-1", .window_id = "window-1" };

const max_frame_bytes = 64 * 1024;

pub const Config = struct {
    enabled: bool = false,
    socket_path: []const u8 = "",
    token: []const u8 = "",
    /// Live page the engine drives. Without one, every command answers
    /// session_invalid (-32011).
    page_port: ?page_port.PagePort = null,
    /// Receives one root `automation.command` span (plus child spans) per
    /// command. Optional; the in-memory sink grows without bound, so only
    /// tests and diagnostics should set it.
    telemetry_sink: ?*automation.telemetry.InMemoryTelemetrySink = null,
};

/// One accepted client. Each connection has its own thread and may carry any
/// number of length-prefixed requests until the client closes it.
const Connection = struct {
    server: *AutomationApiServer,
    stream: net.Stream,
    thread: std.Thread = undefined,
    done: std.atomic.Value(bool) = .{ .raw = false },
};

pub const AutomationApiServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config,
    listener: ?net.Server = null,
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .{ .raw = false },
    clock: engine_mod.IoClock,
    engine: ?engine_mod.Engine = null,
    connections_mutex: std.Io.Mutex = .init,
    connections: std.ArrayListUnmanaged(*Connection) = .empty,
    /// Serializes commands per page (M8) and cancels them on stop().
    queue: queue_mod.PageCommandQueue,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        config: Config,
    ) !AutomationApiServer {
        return .{
            .allocator = allocator,
            .io = io,
            .clock = .{ .io = io },
            .queue = queue_mod.PageCommandQueue.init(allocator, io),
            .config = .{
                .enabled = config.enabled,
                .socket_path = try allocator.dupe(u8, config.socket_path),
                .token = try allocator.dupe(u8, config.token),
                .page_port = config.page_port,
                .telemetry_sink = config.telemetry_sink,
            },
        };
    }

    pub fn deinit(self: *AutomationApiServer) void {
        self.stop();
        self.connections.deinit(self.allocator);
        self.queue.deinit();
        self.allocator.free(self.config.socket_path);
        self.allocator.free(self.config.token);
        self.* = undefined;
    }

    pub fn start(self: *AutomationApiServer) !void {
        if (!self.config.enabled) return;
        if (!net.has_unix_sockets) return error.AddressFamilyUnsupported;
        if (self.listener != null) return;

        // The engine keeps a pointer to `self.clock`, so it is built here,
        // once the server has reached its final address.
        if (self.config.page_port) |port| self.engine = engine_mod.Engine.init(port, self.clock.clock());

        try cleanupSocketPath(self.io, self.config.socket_path);
        const address = try net.UnixAddress.init(self.config.socket_path);
        self.listener = try address.listen(self.io, .{});
        self.stopping.store(false, .release);
        self.thread = try std.Thread.spawn(.{}, serveLoop, .{self});
    }

    pub fn stop(self: *AutomationApiServer) void {
        const had_listener = self.listener != null;
        self.stopping.store(true, .release);
        // Queued commands fail with `cancelled`; running ones stop at their
        // next retry poll.
        self.queue.shutdown();

        if (self.thread) |thread| {
            wakeAccept(self.io, self.config.socket_path);
            thread.join();
            self.thread = null;
        }

        self.closeConnections();

        if (self.listener) |*listener| {
            listener.deinit(self.io);
            self.listener = null;
        }

        if (had_listener) cleanupSocketPath(self.io, self.config.socket_path) catch {};
    }

    /// Unblocks every connection thread (read shutdown wakes a pending read) and
    /// joins it. A thread busy in the engine finishes its current command
    /// first; PagePort calls are bounded by their deadline or by the GTK loop
    /// ending.
    fn closeConnections(self: *AutomationApiServer) void {
        self.connections_mutex.lockUncancelable(self.io);
        const list = self.connections.toOwnedSlice(self.allocator) catch &.{};
        self.connections_mutex.unlock(self.io);
        defer self.allocator.free(list);

        // Read side only: wakes handlers blocked waiting for the next frame,
        // while a command that is finishing can still write its response.
        for (list) |connection| connection.stream.shutdown(self.io, .recv) catch {};
        for (list) |connection| self.destroyConnection(connection);
    }

    fn destroyConnection(self: *AutomationApiServer, connection: *Connection) void {
        connection.thread.join();
        connection.stream.close(self.io);
        self.allocator.destroy(connection);
    }

    /// Joins connections whose client already hung up.
    fn reapConnections(self: *AutomationApiServer) void {
        self.connections_mutex.lockUncancelable(self.io);
        defer self.connections_mutex.unlock(self.io);
        var i: usize = 0;
        while (i < self.connections.items.len) {
            const connection = self.connections.items[i];
            if (connection.done.load(.acquire)) {
                _ = self.connections.swapRemove(i);
                self.destroyConnection(connection);
            } else i += 1;
        }
    }

    fn serveLoop(self: *AutomationApiServer) void {
        while (!self.stopping.load(.acquire)) {
            const stream = self.listener.?.accept(self.io) catch |err| {
                if (self.stopping.load(.acquire)) break;
                switch (err) {
                    error.SocketNotListening,
                    error.ConnectionAborted,
                    error.WouldBlock,
                    => continue,
                    else => break,
                }
            };

            if (self.stopping.load(.acquire)) {
                stream.close(self.io);
                break;
            }
            self.reapConnections();
            self.spawnConnection(stream) catch stream.close(self.io);
        }
    }

    fn spawnConnection(self: *AutomationApiServer, stream: net.Stream) !void {
        const connection = try self.allocator.create(Connection);
        errdefer self.allocator.destroy(connection);
        connection.* = .{ .server = self, .stream = stream };

        self.connections_mutex.lockUncancelable(self.io);
        defer self.connections_mutex.unlock(self.io);
        try self.connections.ensureUnusedCapacity(self.allocator, 1);
        connection.thread = try std.Thread.spawn(.{}, connectionMain, .{connection});
        self.connections.appendAssumeCapacity(connection);
    }

    fn connectionMain(connection: *Connection) void {
        defer connection.done.store(true, .release);
        const server = connection.server;
        server.handleStream(connection.stream) catch {};
        // Hang up now so the client sees EOF; the fd itself is closed when
        // the connection is reaped or the server stops.
        connection.stream.shutdown(server.io, .both) catch {};
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

        while (!self.stopping.load(.acquire)) {
            const payload_len = std.mem.readInt(u32, &header, .big);
            if (payload_len > max_frame_bytes) {
                const response = try jsonRpcError(std.heap.smp_allocator, "null", -32700, "Parse error", null);
                defer std.heap.smp_allocator.free(response);
                try writeFrame(&writer, response);
                return;
            }

            const payload = try std.heap.smp_allocator.alloc(u8, payload_len);
            defer std.heap.smp_allocator.free(payload);
            reader.interface.readSliceAll(payload) catch return;

            const response = self.handleRequest(std.heap.smp_allocator, payload) catch |err| switch (err) {
                error.OutOfMemory => return err,
            };
            defer std.heap.smp_allocator.free(response);
            try writeFrame(&writer, response);

            reader.interface.readSliceAll(&header) catch return;
        }
    }

    fn handleRequest(self: *AutomationApiServer, allocator: std.mem.Allocator, payload: []const u8) error{OutOfMemory}![]u8 {
        const engine: ?*engine_mod.Engine = if (self.engine) |*e| e else null;
        var route = primary_route;
        route.telemetry_sink = self.config.telemetry_sink;
        return handleRequestWith(allocator, payload, self.config.token, engine, &self.queue, route);
    }
};

fn handleRequestWith(
    allocator: std.mem.Allocator,
    payload: []const u8,
    token: []const u8,
    engine: ?*engine_mod.Engine,
    queue: *queue_mod.PageCommandQueue,
    route: automation.router.RouteContext,
) error{OutOfMemory}![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return jsonRpcError(allocator, "null", -32700, "Parse error", null),
    };
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |object| object,
        else => return jsonRpcError(allocator, "null", -32600, "Invalid Request", null),
    };

    const id_json = try idJson(allocator, obj.get("id"));
    defer allocator.free(id_json);

    const jsonrpc = switch (obj.get("jsonrpc") orelse return jsonRpcError(allocator, id_json, -32600, "Invalid Request", null)) {
        .string => |value| value,
        else => return jsonRpcError(allocator, id_json, -32600, "Invalid Request", null),
    };
    if (!std.mem.eql(u8, jsonrpc, "2.0")) {
        return jsonRpcError(allocator, id_json, -32600, "Invalid Request", null);
    }

    if (token.len > 0 and !requestHasToken(obj, token)) {
        return jsonRpcError(allocator, id_json, -32000, "Authentication failed", null);
    }

    const method = switch (obj.get("method") orelse return jsonRpcError(allocator, id_json, -32600, "Invalid Request", null)) {
        .string => |value| value,
        else => return jsonRpcError(allocator, id_json, -32600, "Invalid Request", null),
    };
    if (method.len == 0) return jsonRpcError(allocator, id_json, -32600, "Invalid Request", null);

    const params_json = paramsJson(allocator, obj.get("params")) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidParams => return jsonRpcError(allocator, id_json, -32602, "Invalid params", null),
    };
    defer allocator.free(params_json);

    // The engine records the root span after execution; the router gets the
    // page identity only, so it does not record a second root span.
    var command = automation.router.parse(allocator, method, params_json, .{ .page_id = route.page_id, .window_id = route.window_id }) catch |err| switch (err) {
        error.UnknownCommand => return jsonRpcError(allocator, id_json, -32601, "Method not found", null),
        error.BadArgs => return jsonRpcError(allocator, id_json, -32602, "Invalid params", null),
    };
    defer command.deinit();

    const active_engine = engine orelse {
        const session_invalid = automation.errors.AutomationError.session_invalid;
        return jsonRpcError(allocator, id_json, automation.errors.downstreamCode(session_invalid), automation.errors.name(session_invalid), null);
    };

    const ticket = queue.acquire(route.page_id) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Cancelled => {
            const cancelled = automation.errors.AutomationError.cancelled;
            return jsonRpcError(allocator, id_json, automation.errors.downstreamCode(cancelled), automation.errors.name(cancelled), null);
        },
    };
    defer queue.release(ticket);

    var outcome = try active_engine.executeWith(allocator, &command, .{
        .cancel = &ticket.cancelled,
        .queue_wait_ms = ticket.wait_ms,
        .route = route,
    });
    defer outcome.deinit(allocator);
    return switch (outcome) {
        .result => |result_json| std.fmt.allocPrint(
            allocator,
            "{{\"jsonrpc\":\"2.0\",\"result\":{s},\"id\":{s}}}",
            .{ result_json, id_json },
        ),
        .failure => |failure| jsonRpcError(allocator, id_json, failure.code, failure.message, failure.data_json),
    };
}

fn requestHasToken(obj: std.json.ObjectMap, token: []const u8) bool {
    const auth = obj.get("auth") orelse return false;
    return switch (auth) {
        .string => |value| std.mem.eql(u8, value, token),
        else => false,
    };
}

fn paramsJson(allocator: std.mem.Allocator, maybe_params: ?std.json.Value) error{ OutOfMemory, InvalidParams }![]u8 {
    const params = maybe_params orelse return allocator.dupe(u8, "{}");
    return switch (params) {
        .object => try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(params, .{})}),
        else => error.InvalidParams,
    };
}

fn idJson(allocator: std.mem.Allocator, maybe_id: ?std.json.Value) error{OutOfMemory}![]u8 {
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
    /// Optional JSON object for `error.data`, inserted as-is.
    data_json: ?[]const u8,
) error{OutOfMemory}![]u8 {
    const message_json = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(message, .{})});
    defer allocator.free(message_json);
    if (data_json) |data| return std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"error\":{{\"code\":{},\"message\":{s},\"data\":{s}}},\"id\":{s}}}",
        .{ code, message_json, data, id_json },
    );
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
