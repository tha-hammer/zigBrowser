const std = @import("std");
pub const automation = @import("automation.zig");
const automation_websocket = @import("automation_websocket.zig");

const net = std.Io.net;
const page_port = automation.page_port;
const engine_mod = automation.engine;
const queue_mod = automation.queue;
const social_routes = automation.social_routes;
const cookie_routes = automation.cookie_routes;
const x_routes = automation.x_routes;

/// The automation API drives the primary window's page.
pub const primary_route = automation.router.RouteContext{ .page_id = "page-1", .window_id = "window-1" };

const max_frame_bytes = 64 * 1024;

pub const Config = struct {
    enabled: bool = false,
    socket_path: []const u8 = "",
    token: []const u8 = "",
    /// When set, the server writes `token` to this path (new file, mode
    /// 0600, never through an existing file or symlink) before accepting
    /// connections, and removes it on stop or failed start. Clients read it
    /// to authenticate. Requires a non-blank token.
    token_file_path: []const u8 = "",
    /// Live page the engine drives. Without one, every command answers
    /// session_invalid (-32011).
    page_port: ?page_port.PagePort = null,
    /// Receives one root `automation.command` span (plus child spans) per
    /// command. Optional; must be thread-safe.
    telemetry_sink: ?automation.telemetry.TelemetrySink = null,
    /// Browser cookie store for cookies.*. Without one they answer
    /// session_invalid (-32011).
    cookie_port: ?automation.cookie_port.CookiePort = null,
    /// Backend/version dimensions stamped on every span.
    build_info: automation.telemetry.BuildInfo = .{},
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
    engine: engine_mod.Engine = undefined,
    connections_mutex: std.Io.Mutex = .init,
    connections: std.ArrayListUnmanaged(*Connection) = .empty,
    /// Serializes commands per page (M8) and cancels them on stop().
    queue: queue_mod.PageCommandQueue,
    /// Recent redacted spans for telemetry.query (always on, bounded).
    recent_traces: automation.telemetry.RecentTraceStore,
    /// Fans spans out to recent_traces and the configured sink.
    tee: TeeSink = undefined,
    /// x.* pacing (50 X actions per UTC day).
    x_state: x_routes.XState = undefined,
    /// social.* state: RateLimiter + pause window (N6).
    social: social_routes.SocialState = undefined,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        config: Config,
    ) !AutomationApiServer {
        const socket_path = try allocator.dupe(u8, config.socket_path);
        errdefer allocator.free(socket_path);
        const token = try allocator.dupe(u8, config.token);
        errdefer allocator.free(token);
        const token_file_path = try allocator.dupe(u8, config.token_file_path);
        return .{
            .allocator = allocator,
            .io = io,
            .clock = .{ .io = io },
            .queue = queue_mod.PageCommandQueue.init(allocator, io),
            .recent_traces = automation.telemetry.RecentTraceStore.init(allocator, recent_trace_capacity),
            .config = .{
                .enabled = config.enabled,
                .socket_path = socket_path,
                .token = token,
                .token_file_path = token_file_path,
                .page_port = config.page_port,
                .telemetry_sink = config.telemetry_sink,
                .build_info = config.build_info,
                .cookie_port = config.cookie_port,
            },
        };
    }

    pub fn deinit(self: *AutomationApiServer) void {
        self.stop();
        self.connections.deinit(self.allocator);
        self.queue.deinit();
        self.recent_traces.deinit();
        self.allocator.free(self.config.socket_path);
        self.allocator.free(self.config.token);
        self.allocator.free(self.config.token_file_path);
        self.* = undefined;
    }

    pub fn start(self: *AutomationApiServer) !void {
        if (!self.config.enabled) return;
        if (!net.has_unix_sockets) return error.AddressFamilyUnsupported;
        if (self.listener != null) return;

        // The engine keeps a pointer to `self.clock`, so it is built here,
        // once the server has reached its final address. Without a page every
        // command answers session_invalid through the engine (ids + span).
        self.engine = engine_mod.Engine.init(self.config.page_port orelse page_port.no_page, self.clock.clock());
        self.social = social_routes.SocialState.init(wallClockMs, self.clock.clock());
        self.x_state = x_routes.XState.init(wallClockMs);
        self.tee = .{ .recent = self.recent_traces.sink(), .configured = self.config.telemetry_sink };
        // A previous stop() shut the queue down for good; give a restarted
        // server a fresh one (every ticket was released when stop() joined
        // the connections).
        if (self.queue.shutting_down) {
            self.queue.deinit();
            self.queue = queue_mod.PageCommandQueue.init(self.allocator, self.io);
        }

        if (self.config.token_file_path.len > 0) {
            if (std.mem.trim(u8, self.config.token, &std.ascii.whitespace).len == 0) return error.EmptyToken;
            try writeTokenFile(self.io, self.config.token_file_path, self.config.token);
        }
        errdefer self.removeTokenFile();

        try cleanupSocketPath(self.io, self.config.socket_path);
        const address = try net.UnixAddress.init(self.config.socket_path);
        self.listener = try address.listen(self.io, .{});
        // Only the owning user may connect, whatever the umask or directory.
        restrictSocketMode(self.allocator, self.config.socket_path) catch |err| {
            self.listener.?.deinit(self.io);
            self.listener = null;
            cleanupSocketPath(self.io, self.config.socket_path) catch {};
            return err;
        };
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

        if (had_listener) {
            cleanupSocketPath(self.io, self.config.socket_path) catch {};
            self.removeTokenFile();
        }
    }

    fn removeTokenFile(self: *AutomationApiServer) void {
        if (self.config.token_file_path.len == 0) return;
        cleanupSocketPath(self.io, self.config.token_file_path) catch {};
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
            try handleWebSocketUpgrade(&reader, &writer, &header, self.config.token);
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
        var route = primary_route;
        route.telemetry_sink = self.tee.sink();
        return handleRequestWith(allocator, payload, self.config.token, &self.engine, &self.queue, &self.social, route, self.config.build_info, .{ .io = self.io, .port = self.config.cookie_port, .stopping = &self.stopping }, &self.recent_traces, &self.x_state);
    }
};

const recent_trace_capacity = 128;

/// Sends every span to the recent-trace store and to the configured sink.
const TeeSink = struct {
    recent: automation.telemetry.TelemetrySink,
    configured: ?automation.telemetry.TelemetrySink,

    fn sink(self: *TeeSink) automation.telemetry.TelemetrySink {
        return .{ .ptr = self, .vtable = &.{ .recordCommandSpan = recordCommand, .recordChildSpan = recordChild } };
    }

    fn recordCommand(ptr: *anyopaque, attrs: automation.telemetry.CommandSpanAttrs) anyerror!void {
        const self: *TeeSink = @ptrCast(@alignCast(ptr));
        self.recent.recordCommandSpan(attrs) catch {};
        if (self.configured) |configured| try configured.recordCommandSpan(attrs);
    }

    fn recordChild(ptr: *anyopaque, span: automation.telemetry.ChildSpan) anyerror!void {
        const self: *TeeSink = @ptrCast(@alignCast(ptr));
        self.recent.recordChildSpan(span) catch {};
        if (self.configured) |configured| try configured.recordChildSpan(span);
    }
};

const max_trace_id_len = 128;

/// telemetry.query {trace_id} -> {spans:[...]} (redacted spans of a recent
/// command; empty when unknown or evicted). Runs after the envelope/auth
/// checks like every other method; records no span itself.
fn telemetryQuery(
    allocator: std.mem.Allocator,
    id_json: []const u8,
    params_json: []const u8,
    store: *automation.telemetry.RecentTraceStore,
) error{OutOfMemory}![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, params_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return jsonRpcError(allocator, id_json, -32602, "Invalid params", null),
    };
    defer parsed.deinit();
    const params = parsed.value.object;
    if (params.count() != 1) return jsonRpcError(allocator, id_json, -32602, "Invalid params", null);
    const trace_id = switch (params.get("trace_id") orelse return jsonRpcError(allocator, id_json, -32602, "Invalid params", null)) {
        .string => |text| text,
        else => return jsonRpcError(allocator, id_json, -32602, "Invalid params", null),
    };
    if (trace_id.len == 0 or trace_id.len > max_trace_id_len) return jsonRpcError(allocator, id_json, -32602, "Invalid params", null);

    const spans_json = try store.queryJson(allocator, trace_id);
    defer allocator.free(spans_json);
    return std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"result\":{s},\"id\":{s}}}", .{ spans_json, id_json });
}

fn handleRequestWith(
    allocator: std.mem.Allocator,
    payload: []const u8,
    token: []const u8,
    engine: *engine_mod.Engine,
    queue: *queue_mod.PageCommandQueue,
    social: *social_routes.SocialState,
    route: automation.router.RouteContext,
    build_info: automation.telemetry.BuildInfo,
    cookies: CookieContext,
    recent_traces: *automation.telemetry.RecentTraceStore,
    x_state: *x_routes.XState,
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

    const id_json = (try idJson(allocator, obj.get("id"))) orelse return jsonRpcError(allocator, "null", -32600, "Invalid Request", null);
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

    if (std.mem.eql(u8, method, "telemetry.query")) {
        return telemetryQuery(allocator, id_json, params_json, recent_traces);
    }
    if (cookie_routes.verbFromMethod(method)) |verb| {
        return handleCookies(allocator, id_json, method, verb, params_json, engine, cookies, route, build_info);
    }
    if (x_routes.verbFromMethod(method)) |verb| {
        return handleX(allocator, id_json, method, verb, params_json, engine, queue, x_state, route, build_info);
    }
    if (social_routes.verbFromMethod(method)) |verb| {
        return handleSocial(allocator, id_json, method, verb, params_json, engine, queue, social, route, build_info);
    }

    // The engine records the root span after execution; the router gets the
    // page identity only, so it does not record a second root span.
    var command = automation.router.parse(allocator, method, params_json, .{ .page_id = route.page_id, .window_id = route.window_id }) catch |err| switch (err) {
        error.UnknownCommand => return jsonRpcError(allocator, id_json, -32601, "Method not found", null),
        error.BadArgs => return jsonRpcError(allocator, id_json, -32602, "Invalid params", null),
    };
    defer command.deinit();

    // A command cancelled while queued still goes through the engine (with
    // the cancel flag already set) so it gets ids and one root span.
    const already_cancelled = std.atomic.Value(bool).init(true);
    const maybe_ticket: ?queue_mod.Ticket = queue.acquire(route.page_id) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Cancelled => null,
    };
    defer if (maybe_ticket) |ticket| queue.release(ticket);

    var outcome = try engine.executeWith(allocator, &command, .{
        .cancel = if (maybe_ticket) |ticket| &ticket.cancelled else &already_cancelled,
        .queue_wait_ms = if (maybe_ticket) |ticket| ticket.wait_ms else 0,
        .route = route,
        .build = build_info,
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

const CookieContext = struct {
    io: std.Io,
    port: ?automation.cookie_port.CookiePort,
    /// cookies.* skip the page queue, so they observe server stop directly.
    stopping: *const std.atomic.Value(bool),
};

/// cookies.* do not touch the page DOM, so they skip the page queue; they
/// still get ids and one root span via executeExternal.
fn handleCookies(
    allocator: std.mem.Allocator,
    id_json: []const u8,
    method: []const u8,
    verb: cookie_routes.Verb,
    params_json: []const u8,
    engine: *engine_mod.Engine,
    cookies: CookieContext,
    route: automation.router.RouteContext,
    build_info: automation.telemetry.BuildInfo,
) error{OutOfMemory}![]u8 {
    const CookieCall = struct {
        cookies: CookieContext,
        verb: cookie_routes.Verb,
        params_json: []const u8,

        fn run(self: @This(), gpa: std.mem.Allocator, ext: *engine_mod.External) error{OutOfMemory}!engine_mod.Outcome {
            return cookie_routes.handle(gpa, self.cookies.io, self.cookies.port, ext, self.verb, self.params_json);
        }
    };
    var outcome = try engine.executeExternal(allocator, method, "cookies", .{ .cancel = cookies.stopping, .route = route, .build = build_info }, CookieCall{
        .cookies = cookies,
        .verb = verb,
        .params_json = params_json,
    }, CookieCall.run);
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

/// x.* drive the page, so they hold its queue ticket for the whole flow.
fn handleX(
    allocator: std.mem.Allocator,
    id_json: []const u8,
    method: []const u8,
    verb: x_routes.Verb,
    params_json: []const u8,
    engine: *engine_mod.Engine,
    queue: *queue_mod.PageCommandQueue,
    x_state: *x_routes.XState,
    route: automation.router.RouteContext,
    build_info: automation.telemetry.BuildInfo,
) error{OutOfMemory}![]u8 {
    // Cancelled while queued -> no ticket; the flow then starts already
    // cancelled, so the reply still has ids and a root span.
    const ticket: ?queue_mod.Ticket = queue.acquire(route.page_id) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Cancelled => null,
    };
    defer if (ticket) |t| queue.release(t);
    const already_cancelled = std.atomic.Value(bool).init(true);

    const XCall = struct {
        state: *x_routes.XState,
        verb: x_routes.Verb,
        params_json: []const u8,

        fn run(self: @This(), gpa: std.mem.Allocator, ext: *engine_mod.External) error{OutOfMemory}!engine_mod.Outcome {
            return x_routes.handle(gpa, self.state, ext, self.verb, self.params_json);
        }
    };
    var outcome = try engine.executeExternal(allocator, method, "x", .{
        .cancel = if (ticket) |t| &t.cancelled else &already_cancelled,
        .queue_wait_ms = if (ticket) |t| t.wait_ms else 0,
        .route = route,
        .build = build_info,
    }, XCall{ .state = x_state, .verb = verb, .params_json = params_json }, XCall.run);
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

fn handleSocial(
    allocator: std.mem.Allocator,
    id_json: []const u8,
    method: []const u8,
    verb: social_routes.Verb,
    params_json: []const u8,
    engine: *engine_mod.Engine,
    queue: *queue_mod.PageCommandQueue,
    social: *social_routes.SocialState,
    route: automation.router.RouteContext,
    build_info: automation.telemetry.BuildInfo,
) error{OutOfMemory}![]u8 {
    // login_check reads the page and pause holds the page, so both take
    // their turn in the page queue.
    // Cancelled while queued: still runs through executeExternal (pre-set
    // flag) so the reply has ids and a root span.
    const needs_page = verb == .login_check or verb == .pause;
    var queued_cancelled = false;
    var ticket: ?queue_mod.Ticket = null;
    if (needs_page) {
        ticket = queue.acquire(route.page_id) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Cancelled => blk: {
                queued_cancelled = true;
                break :blk null;
            },
        };
    }
    defer if (ticket) |t| queue.release(t);

    const not_cancelled = std.atomic.Value(bool).init(false);
    const already_cancelled = std.atomic.Value(bool).init(true);
    const SocialCall = struct {
        social: *social_routes.SocialState,
        verb: social_routes.Verb,
        params_json: []const u8,
        cancel: *const std.atomic.Value(bool),

        fn run(self: @This(), gpa: std.mem.Allocator, ext: *engine_mod.External) error{OutOfMemory}!engine_mod.Outcome {
            return social_routes.handle(gpa, self.social, ext, self.verb, self.params_json, self.cancel);
        }
    };
    const cancel = if (ticket) |t| &t.cancelled else if (queued_cancelled) &already_cancelled else &not_cancelled;
    var outcome = try engine.executeExternal(allocator, method, "social", .{
        .cancel = cancel,
        .queue_wait_ms = if (ticket) |t| t.wait_ms else 0,
        .route = route,
        .build = build_info,
    }, SocialCall{ .social = social, .verb = verb, .params_json = params_json, .cancel = cancel }, SocialCall.run);
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

/// Wall-clock ms for the RateLimiter's UTC day rollover.
fn wallClockMs() i64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &ts) != 0) return 0;
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn requestHasToken(obj: std.json.ObjectMap, token: []const u8) bool {
    const auth = obj.get("auth") orelse return false;
    return switch (auth) {
        .string => |value| tokensEqual(value, token),
        else => false,
    };
}

/// Constant-time token comparison: both sides are hashed to fixed-size
/// digests first, so neither the length nor the first differing byte of the
/// configured token leaks through timing.
pub fn tokensEqual(given: []const u8, expected: []const u8) bool {
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var given_digest: [Sha256.digest_length]u8 = undefined;
    var expected_digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(given, &given_digest, .{});
    Sha256.hash(expected, &expected_digest, .{});
    return std.crypto.timing_safe.eql([Sha256.digest_length]u8, given_digest, expected_digest);
}

/// Test-only fault injection; never set outside tests.
pub const testing_hooks = struct {
    /// Make the token sidecar write fail after the file was created.
    pub var fail_token_write: bool = false;
};

/// Unlinks whatever is at `path` (unlink never follows a symlink), then
/// creates a brand-new 0600 file exclusively. If something re-appears in
/// between, the exclusive create fails and so does startup.
fn writeTokenFile(io: std.Io, path: []const u8, token: []const u8) !void {
    try cleanupSocketPath(io, path);
    var file = try std.Io.Dir.cwd().createFile(io, path, .{
        .exclusive = true,
        .truncate = false,
        .permissions = .fromMode(0o600),
    });
    defer file.close(io);
    // Created: from here on any failure removes the partial file.
    errdefer cleanupSocketPath(io, path) catch {};
    if (testing_hooks.fail_token_write) return error.InjectedTokenWriteFailure;
    var buf: [256]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.interface.writeAll(token);
    try writer.interface.flush();
}

fn restrictSocketMode(allocator: std.mem.Allocator, socket_path: []const u8) !void {
    const path_z = try allocator.dupeZ(u8, socket_path);
    defer allocator.free(path_z);
    if (std.c.chmod(path_z, 0o600) != 0) return error.SocketPermissions;
}

fn paramsJson(allocator: std.mem.Allocator, maybe_params: ?std.json.Value) error{ OutOfMemory, InvalidParams }![]u8 {
    const params = maybe_params orelse return allocator.dupe(u8, "{}");
    return switch (params) {
        .object => try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(params, .{})}),
        else => error.InvalidParams,
    };
}

/// JSON text of a valid JSON-RPC id (string, number or null; absent -> null).
/// Returns null for object/array/bool ids, which are Invalid Request.
fn idJson(allocator: std.mem.Allocator, maybe_id: ?std.json.Value) error{OutOfMemory}!?[]u8 {
    const id = maybe_id orelse return try allocator.dupe(u8, "null");
    return switch (id) {
        .null,
        .integer,
        .float,
        .number_string,
        .string,
        => try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(id, .{})}),
        .bool, .object, .array => null,
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

fn handleWebSocketUpgrade(reader: anytype, writer: anytype, initial: *const [4]u8, token: []const u8) !void {
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

    // The event channel is authenticated like JSON-RPC requests:
    // "Authorization: Bearer <token>" when a token is configured.
    if (token.len > 0) {
        // Header names and the auth scheme are case-insensitive (RFC 9110).
        const bearer_prefix = "bearer ";
        const authorization = webSocketHeader(request_text, "Authorization") orelse "";
        const has_bearer = authorization.len > bearer_prefix.len and std.ascii.eqlIgnoreCase(authorization[0..bearer_prefix.len], bearer_prefix);
        const given = if (has_bearer) std.mem.trim(u8, authorization[bearer_prefix.len..], " \t") else "";
        if (!tokensEqual(given, token)) {
            try writer.interface.writeAll("HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            try writer.interface.flush();
            return;
        }
    }

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
        if (line.len < prefix.len or !std.ascii.eqlIgnoreCase(line[0..prefix.len], prefix)) continue;
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
