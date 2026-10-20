const std = @import("std");
pub const automation = @import("automation.zig");
/// S7a: the chat drawer's in-process broker over this core (callInProcess).
pub const agent_broker = @import("agent_broker.zig");
const automation_websocket = @import("automation_websocket.zig");
const owner_only = @import("owner_only.zig");

const net = std.Io.net;
const page_port = automation.page_port;
const engine_mod = automation.engine;
const queue_mod = automation.queue;
const social_routes = automation.social_routes;
const cookie_routes = automation.cookie_routes;
const x_routes = automation.x_routes;
const social_flow_routes = automation.social_flow_routes;

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
    /// TESTS ONLY: an origin (e.g. "http://127.0.0.1:41234") that stands in
    /// for www.linkedin.com and www.instagram.com in linkedin.*/instagram.*
    /// flows, so they can run against local fixtures. Null: the environment
    /// variable ZIGBROWSER_SOCIAL_FIXTURE_ORIGIN, else none (production).
    /// Requests can never change it.
    social_fixture_origin: ?[]const u8 = null,
    /// N21: where the pacing state (daily counts, caps, delays) persists
    /// across restarts: "<profile dir>/automation-pacing.json". Loaded at
    /// start, saved after every counted action and social.set_pacing.
    /// Empty: memory only.
    pacing_state_path: []const u8 = "",
};

/// ZIGBROWSER_SOCIAL_FIXTURE_ORIGIN, if it is an http(s) origin (scheme and
/// host[:port], no path); trailing slashes are dropped.
fn fixtureOriginFromEnv() ?[]const u8 {
    const raw = std.c.getenv("ZIGBROWSER_SOCIAL_FIXTURE_ORIGIN") orelse return null;
    return validFixtureOrigin(std.mem.span(raw));
}

pub fn validFixtureOrigin(text: []const u8) ?[]const u8 {
    const origin = std.mem.trimEnd(u8, text, "/");
    const rest = if (std.mem.startsWith(u8, origin, "http://")) origin[7..] else if (std.mem.startsWith(u8, origin, "https://")) origin[8..] else return null;
    if (rest.len == 0) return null;
    for (rest) |c| if (c <= ' ' or c == '/' or c == '?' or c == '#' or c == '@' or c == 0x7f) return null;
    return origin;
}

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
    /// N21: saves `social` and `x_state` to config.pacing_state_path.
    persister: automation.pacing_store.Persister = undefined,
    /// page.recover's outstanding incident tokens.
    recover: RecoverState,
    /// S7.1: the engine and its state are made (startCore); the socket may or may not be.
    core_started: bool = false,

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
        errdefer allocator.free(token_file_path);
        const fixture_origin: ?[]const u8 = if (if (config.social_fixture_origin) |o| validFixtureOrigin(o) else fixtureOriginFromEnv()) |o| try allocator.dupe(u8, o) else null;
        errdefer if (fixture_origin) |o| allocator.free(o);
        const pacing_state_path = try allocator.dupe(u8, config.pacing_state_path);
        return .{
            .allocator = allocator,
            .io = io,
            .clock = .{ .io = io },
            .queue = queue_mod.PageCommandQueue.init(allocator, io),
            .recover = .{ .allocator = allocator, .io = io },
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
                .social_fixture_origin = fixture_origin,
                .pacing_state_path = pacing_state_path,
            },
        };
    }

    pub fn deinit(self: *AutomationApiServer) void {
        self.stop();
        self.connections.deinit(self.allocator);
        self.queue.deinit();
        self.recover.deinit();
        self.recent_traces.deinit();
        self.allocator.free(self.config.socket_path);
        self.allocator.free(self.config.token);
        self.allocator.free(self.config.token_file_path);
        if (self.config.social_fixture_origin) |o| self.allocator.free(o);
        self.allocator.free(self.config.pacing_state_path);
        self.* = undefined;
    }

    /// N21: restore the saved pacing state (or say why defaults are used,
    /// never what the file holds), then save on every change.
    fn loadPacing(self: *AutomationApiServer) void {
        const path = self.config.pacing_state_path;
        self.persister = .{ .io = self.io, .path = path, .social = &self.social, .x = &self.x_state };
        switch (self.persister.loadInto(self.allocator)) {
            .ok => {},
            .missing => std.log.info("automation pacing: no saved state at {s}; using defaults", .{path}),
            .corrupt => std.log.warn("automation pacing: saved state at {s} is unreadable or invalid; using defaults", .{path}),
        }
        self.persister.attach();
    }

    /// S7.1: the automation core without the socket: the engine and its state, for the
    /// drawer's in-process broker (callInProcess). No socket file, no token sidecar.
    pub fn startCore(self: *AutomationApiServer) !void {
        if (self.core_started) return;
        // The engine keeps a pointer to `self.clock`, so it is built here,
        // once the server has reached its final address. Without a page every
        // command answers session_invalid through the engine (ids + span).
        self.engine = engine_mod.Engine.init(self.config.page_port orelse page_port.no_page, self.clock.clock());
        self.social = social_routes.SocialState.init(wallClockMs, self.clock.clock());
        self.x_state = x_routes.XState.init(wallClockMs);
        if (self.config.pacing_state_path.len > 0) self.loadPacing();
        self.tee = .{ .recent = self.recent_traces.sink(), .configured = self.config.telemetry_sink };
        // A previous stop() shut the queue down for good; give a restarted
        // server a fresh one (every ticket was released when stop() joined
        // the connections).
        if (self.queue.shutting_down) {
            self.queue.deinit();
            self.queue = queue_mod.PageCommandQueue.init(self.allocator, self.io);
        }
        self.core_started = true;
    }

    /// The core and the socket (`--automation-api`).
    pub fn start(self: *AutomationApiServer) !void {
        if (!self.config.enabled) return;
        if (!net.has_unix_sockets) return error.AddressFamilyUnsupported;
        if (self.listener != null) return;
        try self.startCore();
        try self.startSocket();
    }

    /// D8: the token sidecar, the listening socket and its serve loop, over a started core.
    fn startSocket(self: *AutomationApiServer) !void {
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
        self.core_started = false; // a later start makes a fresh core

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
        return handleRequestWith(allocator, payload, self.config.token, self.core());
    }

    /// S7.1: `method` with `params_json` (an object, or "" for none), answered as the socket
    /// answers `{auth, method, params}`: the same routing and checks after auth, with no auth.
    /// The JSON-RPC response has id 0. Call it after startCore, off the GTK thread.
    pub fn callInProcess(self: *AutomationApiServer, allocator: std.mem.Allocator, method: []const u8, params_json: []const u8) error{OutOfMemory}![]u8 {
        if (method.len == 0) return jsonRpcError(allocator, "0", -32600, "Invalid Request", null);
        const trimmed = std.mem.trim(u8, params_json, &std.ascii.whitespace);
        var parsed: ?std.json.Parsed(std.json.Value) = if (trimmed.len == 0) null else std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return jsonRpcError(allocator, "0", -32602, "Invalid params", null),
        };
        defer if (parsed) |*p| p.deinit();
        const params = paramsJson(allocator, if (parsed) |p| p.value else null) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidParams => return jsonRpcError(allocator, "0", -32602, "Invalid params", null),
        };
        defer allocator.free(params);
        return dispatchParsed(allocator, "0", method, params, self.core());
    }

    fn core(self: *AutomationApiServer) Core {
        var route = primary_route;
        route.telemetry_sink = self.tee.sink();
        return .{ .engine = &self.engine, .queue = &self.queue, .social = &self.social, .route = route, .build_info = self.config.build_info, .cookies = .{ .io = self.io, .port = self.config.cookie_port, .stopping = &self.stopping, .fixture_origin = self.config.social_fixture_origin }, .recent_traces = &self.recent_traces, .x_state = &self.x_state, .recover = &self.recover };
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

/// What a request is answered with once it has passed the socket's checks.
const Core = struct {
    engine: *engine_mod.Engine,
    queue: *queue_mod.PageCommandQueue,
    social: *social_routes.SocialState,
    route: automation.router.RouteContext,
    build_info: automation.telemetry.BuildInfo,
    cookies: CookieContext,
    recent_traces: *automation.telemetry.RecentTraceStore,
    x_state: *x_routes.XState,
    recover: *RecoverState,
};

/// The socket's path: parse, envelope and auth, then dispatchParsed.
fn handleRequestWith(allocator: std.mem.Allocator, payload: []const u8, token: []const u8, c: Core) error{OutOfMemory}![]u8 {
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
    return dispatchParsed(allocator, id_json, method, params_json, c);
}

/// S7.1: everything after auth, shared by the socket and callInProcess.
fn dispatchParsed(allocator: std.mem.Allocator, id_json: []const u8, method: []const u8, params_json: []const u8, c: Core) error{OutOfMemory}![]u8 {
    const engine, const queue, const social, const route, const build_info, const cookies, const recent_traces, const x_state, const recover =
        .{ c.engine, c.queue, c.social, c.route, c.build_info, c.cookies, c.recent_traces, c.x_state, c.recover };
    if (std.mem.eql(u8, method, "telemetry.query")) {
        return telemetryQuery(allocator, id_json, params_json, recent_traces);
    }
    if (cookie_routes.verbFromMethod(method)) |verb| {
        return handleCookies(allocator, id_json, method, verb, params_json, engine, cookies, route, build_info);
    }
    if (x_routes.verbFromMethod(method)) |verb| {
        return handleX(allocator, id_json, method, verb, params_json, engine, queue, x_state, route, build_info);
    }
    if (social_flow_routes.callFromMethod(method)) |call| {
        return handleSocialFlow(allocator, id_json, method, call, params_json, engine, queue, social, .{ .cookies = cookies.port, .fixture_origin = cookies.fixture_origin }, route, build_info);
    }
    if (social_routes.verbFromMethod(method)) |verb| {
        return handleSocial(allocator, id_json, method, verb, params_json, engine, queue, social, route, build_info);
    }

    if (std.mem.eql(u8, method, "page.list") or std.mem.eql(u8, method, "page.close") or std.mem.eql(u8, method, "page.health")) {
        return handleWindows(allocator, id_json, method, params_json, engine, queue, route, build_info);
    }
    if (std.mem.eql(u8, method, "page.recover")) {
        return handleRecover(allocator, id_json, params_json, engine, queue, recover, route, build_info);
    }
    if (std.mem.eql(u8, method, "dialog.get") or std.mem.eql(u8, method, "dialog.respond")) {
        return handleDialogs(allocator, id_json, method, params_json, engine, route, build_info);
    }

    // N23: `window_id` sends a page.* or dom.* command to that window. It is
    // taken out of the params before the router sees them.
    const target = splitWindowTarget(allocator, params_json) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidParams => return jsonRpcError(allocator, id_json, -32602, "Invalid params", null),
    };
    defer if (target.params) |owned| allocator.free(owned);
    var window_route = route;
    var route_bufs: [2][24]u8 = undefined;
    if (target.id) |window| window_route = windowRoute(route, window, &route_bufs);

    // The engine records the root span after execution; the router gets the
    // page identity only, so it does not record a second root span.
    var command = automation.router.parse(allocator, method, target.params orelse params_json, .{ .page_id = window_route.page_id, .window_id = window_route.window_id }) catch |err| switch (err) {
        error.UnknownCommand => return jsonRpcError(allocator, id_json, -32601, "Method not found", null),
        error.BadArgs => return jsonRpcError(allocator, id_json, -32602, "Invalid params", null),
    };
    defer command.deinit();

    // forWindow is a pure handle constructor; when it refuses (no window
    // support, or an id it already knows is gone), the command still runs
    // through the engine on a stand-in page that answers the same way, so
    // its root span is the normal one.
    const window_port = try targetPort(engine, target.id);

    // A command cancelled while queued still goes through the engine (with
    // the cancel flag already set) so it gets ids and one root span.
    const already_cancelled = std.atomic.Value(bool).init(true);
    const maybe_ticket: ?queue_mod.Ticket = queue.acquire(window_route.page_id) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Cancelled => null,
        error.Recovering => return recoveringReply(allocator, id_json, engine, method, window_route, build_info),
    };
    defer if (maybe_ticket) |ticket| queue.release(ticket);


    var outcome = try engine.executeWith(allocator, &command, .{
        .cancel = if (maybe_ticket) |ticket| &ticket.cancelled else &already_cancelled,
        .queue_wait_ms = if (maybe_ticket) |ticket| ticket.wait_ms else 0,
        .route = window_route,
        .build = build_info,
        .port = window_port,
        // The handle's first bounded call finds a closed window (in this
        // window's turn, after any page.close queued before it).
        .no_page_reason = if (target.id != null) "no_window" else null,
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

// ---- N23: windows ----

const window_prefix = "window-";
/// listWindows / closeWindow bound.
const window_op_timeout_ms: u64 = 10_000;

/// "window-<id>" (id >= 1, decimal) -> id.
fn parseWindowId(text: []const u8) ?page_port.WindowId {
    if (!std.mem.startsWith(u8, text, window_prefix)) return null;
    const digits = text[window_prefix.len..];
    if (digits.len == 0 or digits[0] == '0') return null;
    for (digits) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(page_port.WindowId, digits, 10) catch null;
}

const WindowTarget = struct {
    id: ?page_port.WindowId = null,
    /// The params without `window_id` (owned), when it was present.
    params: ?[]u8 = null,
};

fn splitWindowTarget(allocator: std.mem.Allocator, params_json: []const u8) error{ OutOfMemory, InvalidParams }!WindowTarget {
    if (std.mem.indexOf(u8, params_json, "\"window_id\"") == null) return .{};
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, params_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidParams,
    };
    defer parsed.deinit();
    var object = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidParams,
    };
    const value = object.fetchOrderedRemove("window_id") orelse return .{};
    const id = switch (value.value) {
        .string => |text| parseWindowId(text) orelse return error.InvalidParams,
        else => return error.InvalidParams,
    };
    const rest = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = object }, .{});
    return .{ .id = id, .params = rest };
}

/// The page a command with `window_id` runs on (null without one: the
/// primary's). forWindow is a pure handle constructor; when it refuses (no
/// window support, or an id it already knows is gone), a stand-in page that
/// answers the same way takes its place, so the command still runs through
/// the engine with its normal root span.
fn targetPort(engine: *engine_mod.Engine, id: ?page_port.WindowId) error{OutOfMemory}!?page_port.PagePort {
    const window = id orelse return null;
    return engine.port.forWindow(window) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NoPage => gone_window,
        else => unsupported_windows,
    };
}

fn windowRoute(base: automation.router.RouteContext, id: page_port.WindowId, bufs: *[2][24]u8) automation.router.RouteContext {
    var route = base;
    route.page_id = std.fmt.bufPrint(&bufs[0], "page-{d}", .{id}) catch unreachable;
    route.window_id = std.fmt.bufPrint(&bufs[1], window_prefix ++ "{d}", .{id}) catch unreachable;
    return route;
}

/// Stand-in pages for a targeted command whose window forWindow refused:
/// every call answers NoPage (gone; the engine reports no_window) or
/// Unsupported (no window support).
const gone_window: page_port.PagePort = .{ .ptr = @constCast(&stand_in_tag), .vtable = &stand_in(error.NoPage).vtable };
const unsupported_windows: page_port.PagePort = .{ .ptr = @constCast(&stand_in_tag), .vtable = &stand_in(error.Unsupported).vtable };
var stand_in_tag: u8 = 0;

fn stand_in(comptime answer: page_port.PortError) type {
    return struct {
        const vtable = page_port.PagePort.VTable{
            .evalJson = eval,
            .navigate = navigate,
            .reload = reload,
            .url = read,
            .title = read,
            .nativeClick = point,
            .nativeMove = point,
            .nativeKey = key,
            .nativeText = text,
            .setInputFiles = files,
            .nativeScroll = scroll,
            .screenshot = shot,
        };
        fn eval(_: *anyopaque, _: std.mem.Allocator, _: page_port.World, _: []const u8, _: []const u8, _: u64) page_port.PortError![]u8 {
            return answer;
        }
        fn navigate(_: *anyopaque, _: []const u8, _: u64) page_port.PortError!void {
            return answer;
        }
        fn reload(_: *anyopaque, _: u64) page_port.PortError!void {
            return answer;
        }
        fn read(_: *anyopaque, _: std.mem.Allocator, _: u64) page_port.PortError![]u8 {
            return answer;
        }
        fn point(_: *anyopaque, _: f64, _: f64, _: ?[]const u8, _: u64) page_port.PortError!void {
            return answer;
        }
        fn key(_: *anyopaque, _: []const u8, _: u8, _: ?[]const u8, _: u64) page_port.PortError!void {
            return answer;
        }
        fn text(_: *anyopaque, _: []const u8, _: ?[]const u8, _: u64, sent: *usize) page_port.PortError!void {
            sent.* = 0;
            return answer;
        }
        fn files(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8, _: []const []const u8, _: u64) page_port.PortError![]u8 {
            return answer;
        }
        fn scroll(_: *anyopaque, _: f64, _: f64, _: f64, _: f64, _: ?[]const u8, _: u64) page_port.PortError!page_port.ScrollOffsets {
            return answer;
        }
        fn shot(_: *anyopaque, _: std.mem.Allocator, _: bool, _: u64) page_port.PortError!page_port.Screenshot {
            return answer;
        }
    };
}

fn outcomeJson(allocator: std.mem.Allocator, id_json: []const u8, outcome: engine_mod.Outcome) error{OutOfMemory}![]u8 {
    return switch (outcome) {
        .result => |result_json| std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"result\":{s},\"id\":{s}}}", .{ result_json, id_json }),
        .failure => |failure| jsonRpcError(allocator, id_json, failure.code, failure.message, failure.data_json),
    };
}

/// How long WebKit must keep saying a window's web process is unresponsive
/// before page.health reports it (WebKit itself says so only after the
/// process missed a reply for about 3 s). Busy JavaScript that ends sooner
/// is not reported.
pub const health_debounce_ms: u64 = 2000;

/// page.health's `responsive`: false only after WebKit has said
/// unresponsive for the whole debounce, and true again as soon as it says
/// responsive. Suspected only: a long, finite busy loop looks the same.
pub fn healthResponsive(web_process_responsive: bool, unresponsive_ms: u64) bool {
    return web_process_responsive or unresponsive_ms < health_debounce_ms;
}

/// page.list {} -> {pages:[{window_id, url, title, primary, opener_window_id?}]}.
/// page.health {} -> {debounce_ms, pages:[{window_id, url, responsive,
/// unresponsive_ms, loading, dialog_open, crashed?}]} (watchdog slice 1).
/// Neither takes a queue turn: they answer while a window's command waits
/// on a frozen page.
/// page.close {window_id} -> {ok:true}; runs in that window's queue turn.
/// The primary window cannot be closed (-32602 primary_window).
fn handleWindows(
    allocator: std.mem.Allocator,
    id_json: []const u8,
    method: []const u8,
    params_json: []const u8,
    engine: *engine_mod.Engine,
    queue: *queue_mod.PageCommandQueue,
    route: automation.router.RouteContext,
    build_info: automation.telemetry.BuildInfo,
) error{OutOfMemory}![]u8 {
    const closing = std.mem.eql(u8, method, "page.close");
    const health = std.mem.eql(u8, method, "page.health");
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, params_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return jsonRpcError(allocator, id_json, -32602, "Invalid params", null),
    };
    defer parsed.deinit();
    const params = switch (parsed.value) {
        .object => |o| o,
        else => return jsonRpcError(allocator, id_json, -32602, "Invalid params", null),
    };
    var target: page_port.WindowId = 0;
    if (closing) {
        if (params.count() != 1) return jsonRpcError(allocator, id_json, -32602, "Invalid params", null);
        target = switch (params.get("window_id") orelse return jsonRpcError(allocator, id_json, -32602, "Invalid params", null)) {
            .string => |text| parseWindowId(text) orelse return jsonRpcError(allocator, id_json, -32602, "Invalid params", null),
            else => return jsonRpcError(allocator, id_json, -32602, "Invalid params", null),
        };
    } else if (params.count() != 0) return jsonRpcError(allocator, id_json, -32602, "Invalid params", null);

    const Call = struct {
        target: page_port.WindowId,
        closing: bool,
        health: bool,

        fn run(self: @This(), gpa: std.mem.Allocator, ext: *engine_mod.External) error{OutOfMemory}!engine_mod.Outcome {
            // Through ext: each PagePort call gets its platform child span,
            // and errors get the standard mapping (NoPage -> no_window,
            // Unsupported -> unsupported, EvalFailed -> -32603, ...).
            const windows = ext.listWindows(gpa, window_op_timeout_ms) catch |err| return engine_mod.portFailure(gpa, err, .action, ext.ids());
            defer page_port.freeWindows(gpa, windows);
            if (self.health) return healthJson(gpa, windows);
            if (!self.closing) return listJson(gpa, windows);
            for (windows) |w| if (w.id == self.target and w.primary) {
                // Invalid params, recorded as such on the root span too.
                return engine_mod.failureWithReason(gpa, engine_mod.invalid_params_code, "Invalid params", "primary_window", ext.ids());
            };
            ext.closeWindow(self.target, window_op_timeout_ms) catch |err| return engine_mod.portFailure(gpa, err, .action, ext.ids());
            return .{ .result = try gpa.dupe(u8, "{\"ok\":true}") };
        }

        fn listJson(gpa: std.mem.Allocator, windows: []const page_port.WindowInfo) error{OutOfMemory}!engine_mod.Outcome {
            var out: std.Io.Writer.Allocating = .init(gpa);
            defer out.deinit();
            const w = &out.writer;
            w.writeAll("{\"pages\":[") catch return error.OutOfMemory;
            for (windows, 0..) |window, i| {
                if (i > 0) w.writeAll(",") catch return error.OutOfMemory;
                w.print("{{\"window_id\":\"" ++ window_prefix ++ "{d}\",\"url\":{f},\"title\":{f},\"primary\":{}", .{
                    window.id, std.json.fmt(window.url, .{}), std.json.fmt(window.title, .{}), window.primary,
                }) catch return error.OutOfMemory;
                if (window.opener) |opener| w.print(",\"opener_window_id\":\"" ++ window_prefix ++ "{d}\"", .{opener}) catch return error.OutOfMemory;
                if (window.terminated) |reason| w.print(",\"crashed\":\"{s}\"", .{@tagName(reason)}) catch return error.OutOfMemory;
                w.writeAll("}") catch return error.OutOfMemory;
            }
            w.writeAll("]}") catch return error.OutOfMemory;
            return .{ .result = try out.toOwnedSlice() };
        }

        fn healthJson(gpa: std.mem.Allocator, windows: []const page_port.WindowInfo) error{OutOfMemory}!engine_mod.Outcome {
            var out: std.Io.Writer.Allocating = .init(gpa);
            defer out.deinit();
            const w = &out.writer;
            w.print("{{\"debounce_ms\":{d},\"pages\":[", .{health_debounce_ms}) catch return error.OutOfMemory;
            for (windows, 0..) |window, i| {
                if (i > 0) w.writeAll(",") catch return error.OutOfMemory;
                const unresponsive_ms: u64 = if (window.web_process_responsive) 0 else window.unresponsive_ms;
                w.print("{{\"window_id\":\"" ++ window_prefix ++ "{d}\",\"url\":{f},\"responsive\":{},\"unresponsive_ms\":{d},\"loading\":{},\"dialog_open\":{}", .{
                    window.id,
                    std.json.fmt(window.url, .{}),
                    healthResponsive(window.web_process_responsive, window.unresponsive_ms),
                    unresponsive_ms,
                    window.loading,
                    window.dialog_open,
                }) catch return error.OutOfMemory;
                if (window.terminated) |reason| w.print(",\"crashed\":\"{s}\"", .{@tagName(reason)}) catch return error.OutOfMemory;
                w.writeAll("}") catch return error.OutOfMemory;
            }
            w.writeAll("]}") catch return error.OutOfMemory;
            return .{ .result = try out.toOwnedSlice() };
        }
    };

    var close_route = route;
    var route_bufs: [2][24]u8 = undefined;
    if (closing) close_route = windowRoute(route, target, &route_bufs);
    const already_cancelled = std.atomic.Value(bool).init(true);
    const ticket: ?queue_mod.Ticket = if (closing) (queue.acquire(close_route.page_id) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Cancelled => null,
        error.Recovering => return recoveringReply(allocator, id_json, engine, method, close_route, build_info),
    }) else null;
    defer if (ticket) |t| queue.release(t);
    var outcome = try engine.executeExternal(allocator, method, "page", .{
        .cancel = if (!closing) null else if (ticket) |t| &t.cancelled else &already_cancelled,
        .queue_wait_ms = if (ticket) |t| t.wait_ms else 0,
        .route = close_route,
        .build = build_info,
        .no_page_reason = "no_window",
    }, Call{ .target = target, .closing = closing, .health = health }, Call.run);
    defer outcome.deinit(allocator);
    return outcomeJson(allocator, id_json, outcome);
}

// ---- Watchdog slice 2: page.recover ----

/// How long a page.recover incident token stays valid.
pub const recover_incident_ttl_ms: u64 = 60_000;
/// Bound for one confirmed recovery (the process ending, reloads started).
const recover_timeout_ms: u64 = 15_000;
const recover_list_timeout_ms: u64 = 10_000;
const incident_token_len = 32;

/// page.recover's outstanding incidents: at most one per window (a newer
/// first call replaces it). Each token is used once.
pub const RecoverState = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    pending: std.ArrayListUnmanaged(Pending) = .empty,

    const Pending = struct {
        window: page_port.WindowId,
        token: [incident_token_len]u8,
        incident: u32,
        /// Owned; the target first.
        at_risk: []page_port.WindowId,
        issued_ms: u64,
    };

    fn deinit(self: *RecoverState) void {
        for (self.pending.items) |p| self.allocator.free(p.at_risk);
        self.pending.deinit(self.allocator);
    }

    fn indexOf(self: *RecoverState, window: page_port.WindowId) ?usize {
        for (self.pending.items, 0..) |p, i| if (p.window == window) return i;
        return null;
    }

    fn drop(self: *RecoverState, i: usize) void {
        self.allocator.free(self.pending.items[i].at_risk);
        _ = self.pending.swapRemove(i);
    }

    /// A new token for `window`'s incident, replacing any older one.
    fn issue(self: *RecoverState, window: page_port.WindowId, incident: u32, at_risk: []const page_port.WindowId, now_ms: u64) error{ OutOfMemory, NoEntropy }![incident_token_len]u8 {
        var bytes: [incident_token_len / 2]u8 = undefined;
        self.io.randomSecure(&bytes) catch return error.NoEntropy;
        const token = std.fmt.bytesToHex(bytes, .lower);
        const owned = try self.allocator.dupe(page_port.WindowId, at_risk);
        errdefer self.allocator.free(owned);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.indexOf(window)) |i| self.drop(i);
        try self.pending.append(self.allocator, .{ .window = window, .token = token, .incident = incident, .at_risk = owned, .issued_ms = now_ms });
        return token;
    }

    const Check = enum { ok, unknown, over, mismatch };

    /// Phase 2: the token must be `window`'s current one and unexpired, the
    /// window still `frozen` in the same incident, and `at_risk_now` and
    /// `acknowledged` both equal to the windows it listed. On .ok the token
    /// is used up, and so is every other token for a window of that family
    /// (one confirmation per incident: a sibling's token must not end the
    /// reloaded process again); an unknown, over or changed incident drops
    /// it; a wrong acknowledgement keeps it. Confirmations are serialized
    /// by `mutex`.
    fn consume(self: *RecoverState, window: page_port.WindowId, token: []const u8, incident: u32, frozen: bool, at_risk_now: []const page_port.WindowId, acknowledged: []const page_port.WindowId, now_ms: u64) Check {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const i = self.indexOf(window) orelse return .unknown;
        const p = self.pending.items[i];
        if (!std.mem.eql(u8, &p.token, token)) return .unknown;
        if (now_ms -| p.issued_ms >= recover_incident_ttl_ms) {
            self.drop(i);
            return .unknown;
        }
        if (!frozen or p.incident != incident) {
            self.drop(i);
            return .over;
        }
        if (!sameWindows(p.at_risk, at_risk_now)) {
            self.drop(i);
            return .mismatch;
        }
        if (!sameWindows(p.at_risk, acknowledged)) return .mismatch;
        var j: usize = self.pending.items.len;
        while (j > 0) {
            j -= 1;
            const other = self.pending.items[j];
            const same_family = std.mem.indexOfScalar(page_port.WindowId, at_risk_now, other.window) != null or
                for (other.at_risk) |id| {
                    if (std.mem.indexOfScalar(page_port.WindowId, at_risk_now, id) != null) break true;
                } else false;
            if (same_family) self.drop(j);
        }
        return .ok;
    }
};

/// The same windows, each once, in any order.
fn sameWindows(a: []const page_port.WindowId, b: []const page_port.WindowId) bool {
    if (a.len != b.len) return false;
    for (b, 0..) |id, i| {
        if (std.mem.indexOfScalar(page_port.WindowId, b[0..i], id) != null) return false;
        if (std.mem.indexOfScalar(page_port.WindowId, a, id) == null) return false;
    }
    return true;
}

/// -32014 recovering for a command whose window page.recover is working on
/// (with ids and a root span, like any refused command).
fn recoveringReply(
    allocator: std.mem.Allocator,
    id_json: []const u8,
    engine: *engine_mod.Engine,
    method: []const u8,
    route: automation.router.RouteContext,
    build_info: automation.telemetry.BuildInfo,
) error{OutOfMemory}![]u8 {
    const Refuse = struct {
        fn run(_: void, gpa: std.mem.Allocator, ext: *engine_mod.External) error{OutOfMemory}!engine_mod.Outcome {
            return engine_mod.automationFailure(gpa, .recovering, "recovering", ext.ids());
        }
    };
    const dot = std.mem.indexOfScalar(u8, method, '.') orelse method.len;
    var outcome = try engine.executeExternal(allocator, method, method[0..dot], .{ .route = route, .build = build_info }, {}, Refuse.run);
    defer outcome.deinit(allocator);
    return outcomeJson(allocator, id_json, outcome);
}

/// page.recover {window_id} -> {incident, window_id, unresponsive_ms,
/// at_risk:[{window_id, url}], expires_in_ms}: phase 1, nothing ended.
/// page.recover {window_id, incident, acknowledge:[window_id...]} ->
/// {recovered:[{window_id, url, ended, reloaded}]}: phase 2. Out of band
/// (no queue turn: the frozen window's turn is held by the command it
/// froze on). See docs/how-to-automate.md "Recovering a frozen page".
fn handleRecover(
    allocator: std.mem.Allocator,
    id_json: []const u8,
    params_json: []const u8,
    engine: *engine_mod.Engine,
    queue: *queue_mod.PageCommandQueue,
    recover: *RecoverState,
    route: automation.router.RouteContext,
    build_info: automation.telemetry.BuildInfo,
) error{OutOfMemory}![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, params_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return jsonRpcError(allocator, id_json, -32602, "Invalid params", null),
    };
    defer parsed.deinit();
    const params = switch (parsed.value) {
        .object => |o| o,
        else => return jsonRpcError(allocator, id_json, -32602, "Invalid params", null),
    };
    const window: page_port.WindowId = switch (params.get("window_id") orelse return jsonRpcError(allocator, id_json, -32602, "Invalid params", null)) {
        .string => |text| parseWindowId(text) orelse return jsonRpcError(allocator, id_json, -32602, "Invalid params", null),
        else => return jsonRpcError(allocator, id_json, -32602, "Invalid params", null),
    };
    const incident_value = params.get("incident");
    const ack_value = params.get("acknowledge");
    const confirming = incident_value != null;
    if ((incident_value == null) != (ack_value == null)) return jsonRpcError(allocator, id_json, -32602, "Invalid params", null);
    if (params.count() != @as(usize, if (confirming) 3 else 1)) return jsonRpcError(allocator, id_json, -32602, "Invalid params", null);
    var incident_token: []const u8 = "";
    var acknowledged: std.ArrayListUnmanaged(page_port.WindowId) = .empty;
    defer acknowledged.deinit(allocator);
    if (confirming) {
        incident_token = switch (incident_value.?) {
            .string => |text| text,
            else => return jsonRpcError(allocator, id_json, -32602, "Invalid params", null),
        };
        if (incident_token.len != incident_token_len) return jsonRpcError(allocator, id_json, -32602, "Invalid params", null);
        for (incident_token) |ch| if (!std.ascii.isHex(ch)) return jsonRpcError(allocator, id_json, -32602, "Invalid params", null);
        const items = switch (ack_value.?) {
            .array => |a| a.items,
            else => return jsonRpcError(allocator, id_json, -32602, "Invalid params", null),
        };
        for (items) |item| {
            const id = switch (item) {
                .string => |text| parseWindowId(text) orelse return jsonRpcError(allocator, id_json, -32602, "Invalid params", null),
                else => return jsonRpcError(allocator, id_json, -32602, "Invalid params", null),
            };
            try acknowledged.append(allocator, id);
        }
    }

    const Call = struct {
        window: page_port.WindowId,
        confirming: bool,
        token: []const u8,
        acknowledged: []const page_port.WindowId,
        queue: *queue_mod.PageCommandQueue,
        recover: *RecoverState,

        fn run(self: @This(), gpa: std.mem.Allocator, ext: *engine_mod.External) error{OutOfMemory}!engine_mod.Outcome {
            const windows = ext.listWindows(gpa, recover_list_timeout_ms) catch |err| return engine_mod.portFailure(gpa, err, .action, ext.ids());
            defer page_port.freeWindows(gpa, windows);
            const target = for (windows) |w| {
                if (w.id == self.window) break w;
            } else return engine_mod.portFailure(gpa, error.NoPage, .action, ext.ids());
            // Every window of the target's process family, primary first.
            const family = groupOf(target);
            var at_risk: std.ArrayListUnmanaged(page_port.WindowId) = .empty;
            defer at_risk.deinit(gpa);
            try at_risk.append(gpa, target.id);
            for (windows) |w| if (w.id != target.id and groupOf(w) == family) try at_risk.append(gpa, w.id);
            const frozen = !healthResponsive(target.web_process_responsive, target.unresponsive_ms);
            const now_ms = ext.engine.clock.nowMs();
            if (!self.confirming) {
                if (!frozen) return engine_mod.failureWithReason(gpa, engine_mod.invalid_params_code, "Invalid params", "not_unresponsive", ext.ids());
                const issued = self.recover.issue(target.id, target.incident, at_risk.items, now_ms) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.NoEntropy => return .{ .failure = .{ .code = engine_mod.internal_error_code, .message = "No entropy for the incident token" } },
                };
                return incidentJson(gpa, &issued, target, at_risk.items, windows);
            }
            switch (self.recover.consume(target.id, self.token, target.incident, frozen, at_risk.items, self.acknowledged, now_ms)) {
                .ok => {},
                .unknown => return engine_mod.failureWithReason(gpa, engine_mod.invalid_params_code, "Invalid params", "incident_unknown", ext.ids()),
                .over => return engine_mod.failureWithReason(gpa, engine_mod.invalid_params_code, "Invalid params", "incident_over", ext.ids()),
                .mismatch => return mismatchFailure(gpa, at_risk.items, ext.ids()),
            }

            // Confirmed: the windows' queues refuse new commands and cancel
            // the ones they hold, until the process ended and reloads began.
            var page_bufs: [64][24]u8 = undefined;
            var page_ids: [64][]const u8 = undefined;
            const n = @min(at_risk.items.len, page_ids.len);
            for (at_risk.items[0..n], 0..) |id, i| page_ids[i] = std.fmt.bufPrint(&page_bufs[i], "page-{d}", .{id}) catch unreachable;
            self.queue.beginRecovery(page_ids[0..n]) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Recovering => return engine_mod.automationFailure(gpa, .recovering, "recovering", ext.ids()),
            };
            defer self.queue.endRecovery(page_ids[0..n]);
            const recovered = ext.recoverWindows(gpa, at_risk.items, recover_timeout_ms) catch |err| return engine_mod.portFailure(gpa, err, .action, ext.ids());
            defer page_port.freeRecovered(gpa, recovered);
            return recoveredJson(gpa, recovered);
        }

        fn groupOf(w: page_port.WindowInfo) page_port.WindowId {
            return if (w.process_group != 0) w.process_group else w.id;
        }

        fn incidentJson(gpa: std.mem.Allocator, issued: []const u8, target: page_port.WindowInfo, at_risk: []const page_port.WindowId, windows: []const page_port.WindowInfo) error{OutOfMemory}!engine_mod.Outcome {
            var out: std.Io.Writer.Allocating = .init(gpa);
            defer out.deinit();
            const w = &out.writer;
            w.print("{{\"incident\":\"{s}\",\"window_id\":\"" ++ window_prefix ++ "{d}\",\"unresponsive_ms\":{d},\"at_risk\":[", .{ issued, target.id, target.unresponsive_ms }) catch return error.OutOfMemory;
            for (at_risk, 0..) |id, i| {
                if (i > 0) w.writeAll(",") catch return error.OutOfMemory;
                const url = for (windows) |win| {
                    if (win.id == id) break win.url;
                } else "";
                w.print("{{\"window_id\":\"" ++ window_prefix ++ "{d}\",\"url\":{f}}}", .{ id, std.json.fmt(url, .{}) }) catch return error.OutOfMemory;
            }
            w.print("],\"expires_in_ms\":{d}}}", .{recover_incident_ttl_ms}) catch return error.OutOfMemory;
            return .{ .result = try out.toOwnedSlice() };
        }

        fn mismatchFailure(gpa: std.mem.Allocator, at_risk: []const page_port.WindowId, ids: anytype) error{OutOfMemory}!engine_mod.Outcome {
            var out: std.Io.Writer.Allocating = .init(gpa);
            defer out.deinit();
            const w = &out.writer;
            w.writeAll("{\"reason\":\"acknowledge_mismatch\",\"at_risk\":[") catch return error.OutOfMemory;
            for (at_risk, 0..) |id, i| {
                if (i > 0) w.writeAll(",") catch return error.OutOfMemory;
                w.print("\"" ++ window_prefix ++ "{d}\"", .{id}) catch return error.OutOfMemory;
            }
            w.print("],\"trace_id\":{f},\"command_id\":{f}}}", .{ std.json.fmt(ids.trace_id, .{}), std.json.fmt(ids.command_id, .{}) }) catch return error.OutOfMemory;
            return .{ .failure = .{ .code = engine_mod.invalid_params_code, .message = "Invalid params", .data_json = try out.toOwnedSlice() } };
        }

        fn recoveredJson(gpa: std.mem.Allocator, recovered: []const page_port.RecoveredWindow) error{OutOfMemory}!engine_mod.Outcome {
            var out: std.Io.Writer.Allocating = .init(gpa);
            defer out.deinit();
            const w = &out.writer;
            w.writeAll("{\"recovered\":[") catch return error.OutOfMemory;
            for (recovered, 0..) |r, i| {
                if (i > 0) w.writeAll(",") catch return error.OutOfMemory;
                w.print("{{\"window_id\":\"" ++ window_prefix ++ "{d}\",\"url\":{f},\"ended\":{},\"reloaded\":{}}}", .{ r.id, std.json.fmt(r.url, .{}), r.ended, r.reloaded }) catch return error.OutOfMemory;
            }
            w.writeAll("]}") catch return error.OutOfMemory;
            return .{ .result = try out.toOwnedSlice() };
        }
    };

    // Telemetry names the window asked about, as page.close does.
    var route_bufs: [2][24]u8 = undefined;
    const recover_route = windowRoute(route, window, &route_bufs);
    var outcome = try engine.executeExternal(allocator, "page.recover", "page", .{
        .route = recover_route,
        .build = build_info,
        .no_page_reason = "no_window",
    }, Call{
        .window = window,
        .confirming = confirming,
        .token = incident_token,
        .acknowledged = acknowledged.items,
        .queue = queue,
        .recover = recover,
    }, Call.run);
    defer outcome.deinit(allocator);
    return outcomeJson(allocator, id_json, outcome);
}

// ---- v3.6: page dialogs ----

/// listDialogs / respondDialog bound.
const dialog_op_timeout_ms: u64 = 5_000;

/// dialog.get {window_id?} -> {open:false} | {open:true, type, message,
/// default_text? (prompt), window_id}: that window's dialog, else the first
/// open one (the primary's first). dialog.respond {accept, text?,
/// window_id?} -> {ok:true}: answers that window's dialog, else the one
/// dialog.get reports; none is -32602 no_dialog. Neither takes a queue
/// turn: the command a dialog blocks still holds its window's turn.
fn handleDialogs(
    allocator: std.mem.Allocator,
    id_json: []const u8,
    method: []const u8,
    params_json: []const u8,
    engine: *engine_mod.Engine,
    route: automation.router.RouteContext,
    build_info: automation.telemetry.BuildInfo,
) error{OutOfMemory}![]u8 {
    const responding = std.mem.eql(u8, method, "dialog.respond");
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, params_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return jsonRpcError(allocator, id_json, -32602, "Invalid params", null),
    };
    defer parsed.deinit();
    const params = switch (parsed.value) {
        .object => |o| o,
        else => return jsonRpcError(allocator, id_json, -32602, "Invalid params", null),
    };

    var call = DialogCall{ .responding = responding };
    var keys = params.iterator();
    while (keys.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (std.mem.eql(u8, key, "window_id")) {
            call.target = switch (value) {
                .string => |text| parseWindowId(text),
                else => null,
            } orelse return jsonRpcError(allocator, id_json, -32602, "Invalid params", null);
        } else if (responding and std.mem.eql(u8, key, "accept")) {
            call.accept = switch (value) {
                .bool => |b| b,
                else => return jsonRpcError(allocator, id_json, -32602, "Invalid params", null),
            };
        } else if (responding and std.mem.eql(u8, key, "text")) {
            call.text = switch (value) {
                // The text crosses the C ABI: no embedded NUL.
                .string => |text| if (std.mem.indexOfScalar(u8, text, 0) == null) text else return jsonRpcError(allocator, id_json, -32602, "Invalid params", null),
                else => return jsonRpcError(allocator, id_json, -32602, "Invalid params", null),
            };
        } else return jsonRpcError(allocator, id_json, -32602, "Invalid params", null);
    }
    if (responding and call.accept == null) return jsonRpcError(allocator, id_json, -32602, "Invalid params", null);

    var dialog_route = route;
    var route_bufs: [2][24]u8 = undefined;
    if (call.target) |target| dialog_route = windowRoute(route, target, &route_bufs);
    var outcome = try engine.executeExternal(allocator, method, "dialog", .{
        .route = dialog_route,
        .build = build_info,
        .no_page_reason = "no_window",
    }, call, DialogCall.run);
    defer outcome.deinit(allocator);
    return outcomeJson(allocator, id_json, outcome);
}

const DialogCall = struct {
    responding: bool,
    target: ?page_port.WindowId = null,
    accept: ?bool = null,
    text: ?[]const u8 = null,

    fn run(self: @This(), gpa: std.mem.Allocator, ext: *engine_mod.External) error{OutOfMemory}!engine_mod.Outcome {
        const dialogs = ext.listDialogs(gpa, dialog_op_timeout_ms) catch |err| return engine_mod.portFailure(gpa, err, .action, ext.ids());
        defer page_port.freeDialogs(gpa, dialogs);
        var found: ?page_port.DialogInfo = null;
        for (dialogs) |dialog| {
            if (self.target == null or self.target.? == dialog.window) {
                found = dialog;
                break;
            }
        }
        if (self.responding) {
            // An explicit window answers for itself (no_window, no_dialog).
            const window = self.target orelse if (found) |dialog| dialog.window else return engine_mod.portFailure(gpa, error.NoDialog, .action, ext.ids());
            ext.respondDialog(window, self.accept.?, self.text, dialog_op_timeout_ms) catch |err| return engine_mod.portFailure(gpa, err, .action, ext.ids());
            return .{ .result = try gpa.dupe(u8, "{\"ok\":true}") };
        }
        const dialog = found orelse {
            // A window that is gone is no_window, not "no dialog".
            if (self.target) |target| {
                const windows = ext.listWindows(gpa, dialog_op_timeout_ms) catch |err| return engine_mod.portFailure(gpa, err, .action, ext.ids());
                defer page_port.freeWindows(gpa, windows);
                for (windows) |w| {
                    if (w.id == target) break;
                } else return engine_mod.portFailure(gpa, error.NoPage, .action, ext.ids());
            }
            return .{ .result = try gpa.dupe(u8, "{\"open\":false}") };
        };
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const w = &out.writer;
        w.print("{{\"open\":true,\"type\":\"{s}\",\"message\":{f}", .{ @tagName(dialog.type), std.json.fmt(dialog.message, .{}) }) catch return error.OutOfMemory;
        if (dialog.default_text) |text| w.print(",\"default_text\":{f}", .{std.json.fmt(text, .{})}) catch return error.OutOfMemory;
        w.print(",\"window_id\":\"" ++ window_prefix ++ "{d}\"}}", .{dialog.window}) catch return error.OutOfMemory;
        return .{ .result = try out.toOwnedSlice() };
    }
};

const CookieContext = struct {
    io: std.Io,
    port: ?automation.cookie_port.CookiePort,
    /// cookies.* skip the page queue, so they observe server stop directly.
    stopping: *const std.atomic.Value(bool),
    /// linkedin.*/instagram.* test-only fixture origin (Config).
    fixture_origin: ?[]const u8 = null,
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
/// With `window_id` (as for page.*/dom.*) every step runs in that window:
/// its queue turn, its page; a window that is gone is -32011 no_window. The
/// X cap stays global (one account).
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
    const target = splitWindowTarget(allocator, params_json) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidParams => return jsonRpcError(allocator, id_json, -32602, "Invalid params", null),
    };
    defer if (target.params) |owned| allocator.free(owned);
    var flow_route = route;
    var route_bufs: [2][24]u8 = undefined;
    if (target.id) |window| flow_route = windowRoute(route, window, &route_bufs);
    const window_port = try targetPort(engine, target.id);

    // Cancelled while queued -> no ticket; the flow then starts already
    // cancelled, so the reply still has ids and a root span.
    const ticket: ?queue_mod.Ticket = queue.acquire(flow_route.page_id) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Cancelled => null,
        error.Recovering => return recoveringReply(allocator, id_json, engine, method, flow_route, build_info),
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
        .route = flow_route,
        .build = build_info,
        .port = window_port,
        .no_page_reason = if (target.id != null) "no_window" else null,
    }, XCall{ .state = x_state, .verb = verb, .params_json = target.params orelse params_json }, XCall.run);
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

/// linkedin.* / instagram.* drive the page, so like x.* they hold its queue
/// ticket for the whole flow, and take `window_id` the same way. The session
/// cookie gate, pacing and the daily cap stay global (one account).
fn handleSocialFlow(
    allocator: std.mem.Allocator,
    id_json: []const u8,
    method: []const u8,
    call: social_flow_routes.Call,
    params_json: []const u8,
    engine: *engine_mod.Engine,
    queue: *queue_mod.PageCommandQueue,
    social: *social_routes.SocialState,
    env: social_flow_routes.Env,
    route: automation.router.RouteContext,
    build_info: automation.telemetry.BuildInfo,
) error{OutOfMemory}![]u8 {
    const target = splitWindowTarget(allocator, params_json) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidParams => return jsonRpcError(allocator, id_json, -32602, "Invalid params", null),
    };
    defer if (target.params) |owned| allocator.free(owned);
    var flow_route = route;
    var route_bufs: [2][24]u8 = undefined;
    if (target.id) |window| flow_route = windowRoute(route, window, &route_bufs);
    const window_port = try targetPort(engine, target.id);

    // Cancelled while queued -> no ticket; the flow then starts already
    // cancelled, so the reply still has ids and a root span.
    const ticket: ?queue_mod.Ticket = queue.acquire(flow_route.page_id) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Cancelled => null,
        error.Recovering => return recoveringReply(allocator, id_json, engine, method, flow_route, build_info),
    };
    defer if (ticket) |t| queue.release(t);
    const already_cancelled = std.atomic.Value(bool).init(true);

    const FlowCall = struct {
        state: *social_routes.SocialState,
        env: social_flow_routes.Env,
        call: social_flow_routes.Call,
        params_json: []const u8,

        fn run(self: @This(), gpa: std.mem.Allocator, ext: *engine_mod.External) error{OutOfMemory}!engine_mod.Outcome {
            return social_flow_routes.handle(gpa, self.state, self.env, ext, self.call, self.params_json);
        }
    };
    var outcome = try engine.executeExternal(allocator, method, call.namespace(), .{
        .cancel = if (ticket) |t| &t.cancelled else &already_cancelled,
        .queue_wait_ms = if (ticket) |t| t.wait_ms else 0,
        .route = flow_route,
        .build = build_info,
        .port = window_port,
        .no_page_reason = if (target.id != null) "no_window" else null,
    }, FlowCall{ .state = social, .env = env, .call = call, .params_json = target.params orelse params_json }, FlowCall.run);
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
            error.Recovering => return recoveringReply(allocator, id_json, engine, method, route, build_info),
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
    // WS2.0: on Windows `.permissions` sets no DACL, so the empty file is made owner-only before
    // the token is written (its directory's owner-only ACE is inherited already).
    if (comptime @import("builtin").os.tag == .windows) owner_only.restrictToOwner(path, .file) catch return error.TokenPermissions;
    if (testing_hooks.fail_token_write) return error.InjectedTokenWriteFailure;
    var buf: [256]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.interface.writeAll(token);
    try writer.interface.flush();
}

/// WS2.0: the socket is its owner's alone (owner_only.restrictToOwner: 0600 on POSIX, a protected
/// owner-only DACL on Windows).
fn restrictSocketMode(allocator: std.mem.Allocator, socket_path: []const u8) !void {
    _ = allocator;
    owner_only.restrictToOwner(socket_path, .file) catch return error.SocketPermissions;
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
