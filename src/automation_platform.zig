const std = @import("std");

const testing = std.testing;

pub const BackendName = enum {
    webview2,
    webkitgtk,
    wkwebview,
};

pub const InputMode = enum {
    cdp_input,
    js_synthetic,
};

pub const NetworkSupport = enum {
    supported,
    unsupported,
};

pub const UnsupportedReason = enum {
    web_extension_required,
    no_platform_api,
};

pub const ResultStatus = enum {
    success,
    unsupported,
    dropped,
    failed,
};

pub const PlatformTelemetryContext = struct {
    trace_id: []const u8 = "trace-platform",
    parent_span_id: ?[]const u8 = "span-root",
    command_id: ?[]const u8 = "cmd-platform",
};

pub const CookieOperation = enum {
    get,
    set,
    delete,
    clear,
};

pub const CookieCommandTelemetry = struct {
    backend: BackendName,
    page_id: []const u8,
    operation: CookieOperation,
    domain: []const u8,
    name: []const u8,
    count: usize,
};

pub const InputCapability = struct {
    mode: InputMode,
};

pub const NetworkCapability = struct {
    support: NetworkSupport,
    unsupported_reason: ?UnsupportedReason = null,
};

pub const PlatformCapabilities = struct {
    input: InputCapability,
    network: NetworkCapability,
};

pub fn adapterCapabilities(backend: BackendName) PlatformCapabilities {
    return switch (backend) {
        .webview2 => .{
            .input = .{ .mode = .cdp_input },
            .network = .{ .support = .supported },
        },
        .webkitgtk => .{
            .input = .{ .mode = .js_synthetic },
            .network = .{
                .support = .unsupported,
                .unsupported_reason = .web_extension_required,
            },
        },
        .wkwebview => .{
            .input = .{ .mode = .js_synthetic },
            .network = .{
                .support = .unsupported,
                .unsupported_reason = .no_platform_api,
            },
        },
    };
}

pub const PlatformAdapter = struct {
    backend: BackendName,
    telemetry_sink: ?*InMemoryPlatformTelemetry = null,
    last_unsupported_reason: ?UnsupportedReason = null,

    pub fn init(backend: BackendName) PlatformAdapter {
        return .{ .backend = backend };
    }

    pub fn startNetwork(self: *PlatformAdapter, page_id: []const u8) !void {
        const caps = adapterCapabilities(self.backend);
        if (caps.network.support != .supported) {
            const reason = caps.network.unsupported_reason.?;
            self.last_unsupported_reason = reason;
            self.recordNetworkCapability(page_id, .unsupported, reason, .unsupported);
            return error.CapabilityUnsupported;
        }

        self.recordNetworkCapability(page_id, .supported, null, .success);
    }

    fn recordNetworkCapability(
        self: *PlatformAdapter,
        page_id: []const u8,
        support: NetworkSupport,
        unsupported_reason: ?UnsupportedReason,
        status: ResultStatus,
    ) void {
        const sink = self.telemetry_sink orelse return;
        sink.record(.{
            .backend = self.backend,
            .page_id = page_id,
            .network_capability = support,
            .unsupported_reason = unsupported_reason,
            .result_status = status,
        });
    }
};

pub const MouseAction = enum {
    move,
    down,
    up,
    click,
};

pub const MouseInput = struct {
    action: MouseAction,
    x: f64,
    y: f64,
    button: ?[]const u8 = null,
    trial: bool = false,
};

pub const KeyAction = enum {
    down,
    up,
    type,
};

pub const KeyInput = struct {
    action: KeyAction,
    key: []const u8,
    text: ?[]const u8 = null,
    trial: bool = false,
};

pub const FakeWebView2Cdp = struct {
    methods: [16][]const u8 = undefined,
    call_count: usize = 0,

    pub fn call(self: *FakeWebView2Cdp, method: []const u8) !void {
        if (self.call_count >= self.methods.len) return error.TooManyCdpCalls;
        self.methods[self.call_count] = method;
        self.call_count += 1;
    }

    pub fn called(self: *const FakeWebView2Cdp, method: []const u8) bool {
        for (self.methods[0..self.call_count]) |recorded| {
            if (std.mem.eql(u8, recorded, method)) return true;
        }
        return false;
    }
};

pub const WebView2InputDispatcher = struct {
    cdp: *FakeWebView2Cdp,

    pub fn init(cdp: *FakeWebView2Cdp) WebView2InputDispatcher {
        return .{ .cdp = cdp };
    }

    pub fn dispatchMouse(self: *WebView2InputDispatcher, input: MouseInput) !void {
        if (input.trial) return;
        _ = input.action;
        _ = input.x;
        _ = input.y;
        _ = input.button;
        try self.cdp.call("Input.dispatchMouseEvent");
    }

    pub fn dispatchKey(self: *WebView2InputDispatcher, input: KeyInput) !void {
        if (input.trial) return;
        _ = input.action;
        _ = input.key;
        _ = input.text;
        try self.cdp.call("Input.dispatchKeyEvent");
    }
};

pub const NetworkOperation = enum {
    capability,
    start,
    stop,
    event,
};

pub const ContentWorld = enum {
    isolated,
    automation,
    page,
};

pub const EvalKind = enum {
    synthetic_input,
};

pub const PlatformErrorClass = enum {
    eval_failed,
};

pub const DebtKind = enum {
    network_interception,
};

pub const DropReason = enum {
    queue_full,
};

pub const NetworkEventKind = enum {
    request,
    response,
};

pub const HttpMethod = enum {
    GET,
    POST,
    PUT,
    PATCH,
    DELETE,
    HEAD,
    OPTIONS,
    other,
};

pub const HttpStatusClass = enum {
    unknown,
    informational,
    success,
    redirect,
    client_error,
    server_error,
};

pub const ResourceKind = enum {
    document,
    fetch,
    image,
    other,
};

pub const NetworkEvent = struct {
    kind: NetworkEventKind,
    request_id_hash: []const u8,
    target_host: []const u8,
    target_path_hash: []const u8,
    http_method: HttpMethod,
    status_code: u16,
    status_class: HttpStatusClass,
    resource_kind: ResourceKind,
    rate_limit: bool,
};

pub const PlatformNetworkEvent = struct {
    request_id: []const u8,
    url: []const u8,
    method: HttpMethod,
    status_code: u16 = 0,
    resource_kind: ResourceKind = .other,
};

pub const FakeWebView2NetworkAdapter = struct {
    add_filter_count: usize = 0,
    remove_handler_count: usize = 0,
    handler_registered: bool = false,

    pub fn addWebResourceRequestedFilter(self: *FakeWebView2NetworkAdapter) !void {
        self.add_filter_count += 1;
        self.handler_registered = true;
    }

    pub fn removeWebResourceRequestedHandler(self: *FakeWebView2NetworkAdapter) void {
        self.remove_handler_count += 1;
        self.handler_registered = false;
    }
};

pub const WebView2NetworkInterceptor = struct {
    const max_queue = 8;
    const host_storage_len = 128;
    const hash_storage_len = 32;

    adapter: *FakeWebView2NetworkAdapter,
    page_id: []const u8,
    telemetry_sink: ?*InMemoryPlatformTelemetry = null,
    telemetry_context: PlatformTelemetryContext = .{},
    started: bool = false,
    capacity: usize = max_queue,
    head: usize = 0,
    len: usize = 0,
    queue: [max_queue]NetworkEvent = undefined,
    host_storage: [max_queue][host_storage_len]u8 = undefined,
    path_hash_storage: [max_queue][hash_storage_len]u8 = undefined,
    request_id_hash_storage: [max_queue][hash_storage_len]u8 = undefined,
    drop_count: usize = 0,
    last_drop_reason: ?DropReason = null,

    pub fn init(adapter: *FakeWebView2NetworkAdapter, page_id: []const u8) WebView2NetworkInterceptor {
        return initWithCapacity(adapter, page_id, max_queue);
    }

    pub fn initWithCapacity(adapter: *FakeWebView2NetworkAdapter, page_id: []const u8, capacity: usize) WebView2NetworkInterceptor {
        return .{
            .adapter = adapter,
            .page_id = page_id,
            .capacity = @min(capacity, max_queue),
        };
    }

    pub fn capability(self: *const WebView2NetworkInterceptor) NetworkCapability {
        _ = self;
        return .{ .support = .supported };
    }

    pub fn start(self: *WebView2NetworkInterceptor) !void {
        if (self.started) return;
        try self.adapter.addWebResourceRequestedFilter();
        self.started = true;
        self.recordSpan("automation.network.capability", .start, .success, null);
    }

    pub fn stop(self: *WebView2NetworkInterceptor) !void {
        if (!self.started) return;
        self.adapter.removeWebResourceRequestedHandler();
        self.started = false;
        self.recordSpan("automation.network.capability", .stop, .success, null);
    }

    pub fn capturePlatformEvent(self: *WebView2NetworkInterceptor, input: PlatformNetworkEvent) !void {
        if (!self.started) return error.NetworkInterceptorNotStarted;
        if (self.len >= self.capacity) {
            self.drop_count += 1;
            self.last_drop_reason = .queue_full;
            self.recordSpan("automation.network.event", .event, .dropped, .queue_full);
            return;
        }

        const slot = (self.head + self.len) % max_queue;
        self.queue[slot] = try self.networkEvent(input, slot);
        self.len += 1;
        self.recordNetworkEventSpan(self.queue[slot], .success, null);
    }

    pub fn pollEvent(self: *WebView2NetworkInterceptor) ?NetworkEvent {
        if (self.len == 0) return null;
        const event = self.queue[self.head];
        self.head = (self.head + 1) % max_queue;
        self.len -= 1;
        return event;
    }

    fn networkEvent(self: *WebView2NetworkInterceptor, input: PlatformNetworkEvent, slot: usize) !NetworkEvent {
        const redacted = try redactUrl(
            input.url,
            self.host_storage[slot][0..],
            self.path_hash_storage[slot][0..],
        );
        const request_id_hash = try hashTextToStorage(input.request_id, self.request_id_hash_storage[slot][0..]);
        return .{
            .kind = if (input.status_code == 0) .request else .response,
            .request_id_hash = request_id_hash,
            .target_host = redacted.host,
            .target_path_hash = redacted.path_hash,
            .http_method = input.method,
            .status_code = input.status_code,
            .status_class = statusClass(input.status_code),
            .resource_kind = input.resource_kind,
            .rate_limit = input.status_code == 429 or input.status_code == 403,
        };
    }

    fn recordSpan(
        self: *WebView2NetworkInterceptor,
        name: []const u8,
        operation: NetworkOperation,
        status: ResultStatus,
        drop_reason: ?DropReason,
    ) void {
        if (self.telemetry_sink) |sink| {
            sink.record(.{
                .name = name,
                .trace_id = self.telemetry_context.trace_id,
                .parent_span_id = self.telemetry_context.parent_span_id,
                .command_id = self.telemetry_context.command_id,
                .backend = .webview2,
                .page_id = self.page_id,
                .network_capability = .supported,
                .network_operation = operation,
                .drop_reason = drop_reason,
                .result_status = status,
            });
        }
    }

    fn recordNetworkEventSpan(
        self: *WebView2NetworkInterceptor,
        event: NetworkEvent,
        status: ResultStatus,
        drop_reason: ?DropReason,
    ) void {
        if (self.telemetry_sink) |sink| {
            sink.record(.{
                .name = "automation.network.event",
                .trace_id = self.telemetry_context.trace_id,
                .parent_span_id = self.telemetry_context.parent_span_id,
                .command_id = self.telemetry_context.command_id,
                .backend = .webview2,
                .page_id = self.page_id,
                .network_capability = .supported,
                .network_operation = .event,
                .drop_reason = drop_reason,
                .target_host = event.target_host,
                .target_path_hash = event.target_path_hash,
                .network_request_id_hash = event.request_id_hash,
                .http_method = event.http_method,
                .http_status_code = event.status_code,
                .http_status_class = event.status_class,
                .resource_kind = event.resource_kind,
                .rate_limit = event.rate_limit,
                .result_status = status,
            });
        }
    }
};

pub const ActionResult = struct {
    status: ResultStatus = .success,
};

pub const FakePlatformEval = struct {
    call_count: usize = 0,
    fail_next: bool = false,
    last_content_world: ContentWorld = .isolated,
    last_eval_kind: EvalKind = .synthetic_input,
    last_script_storage: [1024]u8 = undefined,
    last_script: []const u8 = "",

    pub fn evaluate(
        self: *FakePlatformEval,
        content_world: ContentWorld,
        eval_kind: EvalKind,
        script: []const u8,
    ) !ActionResult {
        self.call_count += 1;
        self.last_content_world = content_world;
        self.last_eval_kind = eval_kind;
        if (script.len > self.last_script_storage.len) return error.ScriptTooLarge;
        @memcpy(self.last_script_storage[0..script.len], script);
        self.last_script = self.last_script_storage[0..script.len];

        if (self.fail_next) {
            self.fail_next = false;
            return error.PlatformEvalFailed;
        }
        return .{ .status = .success };
    }
};

pub const WebKitGtkInputDispatcher = struct {
    eval: *FakePlatformEval,
    page_id: []const u8,
    telemetry_sink: ?*InMemoryPlatformTelemetry = null,
    telemetry_context: PlatformTelemetryContext = .{},

    pub fn init(eval: *FakePlatformEval, page_id: []const u8) WebKitGtkInputDispatcher {
        return .{ .eval = eval, .page_id = page_id };
    }

    pub fn dispatchMouse(self: *WebKitGtkInputDispatcher, input: MouseInput) !ActionResult {
        if (input.trial) return .{ .status = .success };
        var script_storage: [512]u8 = undefined;
        const script = try syntheticMouseScript(script_storage[0..], input);
        const result = self.eval.evaluate(.isolated, .synthetic_input, script) catch |err| {
            self.recordInputDispatchSpan(.failed, script.len);
            self.recordEvalSpan(.failed, .eval_failed, script.len);
            return err;
        };
        self.recordInputDispatchSpan(.success, script.len);
        self.recordEvalSpan(.success, null, script.len);
        return result;
    }

    pub fn dispatchKey(self: *WebKitGtkInputDispatcher, input: KeyInput) !ActionResult {
        if (input.trial) return .{ .status = .success };
        var script_storage: [512]u8 = undefined;
        const script = try syntheticKeyScript(script_storage[0..], input);
        const result = self.eval.evaluate(.isolated, .synthetic_input, script) catch |err| {
            self.recordInputDispatchSpan(.failed, script.len);
            self.recordEvalSpan(.failed, .eval_failed, script.len);
            return err;
        };
        self.recordInputDispatchSpan(.success, script.len);
        self.recordEvalSpan(.success, null, script.len);
        return result;
    }

    fn recordInputDispatchSpan(self: *WebKitGtkInputDispatcher, status: ResultStatus, payload_bytes: usize) void {
        if (self.telemetry_sink) |sink| {
            sink.record(.{
                .name = "automation.input.dispatch",
                .trace_id = self.telemetry_context.trace_id,
                .parent_span_id = self.telemetry_context.parent_span_id,
                .command_id = self.telemetry_context.command_id,
                .backend = .webkitgtk,
                .page_id = self.page_id,
                .input_mode = .js_synthetic,
                .content_world = .isolated,
                .payload_bytes = payload_bytes,
                .result_bytes = 2,
                .result_status = status,
            });
        }
    }

    fn recordEvalSpan(self: *WebKitGtkInputDispatcher, status: ResultStatus, error_class: ?PlatformErrorClass, payload_bytes: usize) void {
        if (self.telemetry_sink) |sink| {
            sink.record(.{
                .name = "automation.platform.eval",
                .trace_id = self.telemetry_context.trace_id,
                .parent_span_id = self.telemetry_context.parent_span_id,
                .command_id = self.telemetry_context.command_id,
                .backend = .webkitgtk,
                .page_id = self.page_id,
                .input_mode = .js_synthetic,
                .content_world = .isolated,
                .eval_kind = .synthetic_input,
                .platform_error_class = error_class,
                .payload_bytes = payload_bytes,
                .result_bytes = if (status == .success) 2 else 0,
                .result_status = status,
            });
        }
    }
};

pub const WebKitGtkNetworkInterceptor = struct {
    page_id: []const u8,
    telemetry_sink: ?*InMemoryPlatformTelemetry = null,
    telemetry_context: PlatformTelemetryContext = .{},

    pub fn init(page_id: []const u8) WebKitGtkNetworkInterceptor {
        return .{ .page_id = page_id };
    }

    pub fn capability(self: *const WebKitGtkNetworkInterceptor) NetworkCapability {
        _ = self;
        return .{
            .support = .unsupported,
            .unsupported_reason = .web_extension_required,
        };
    }

    pub fn start(self: *WebKitGtkNetworkInterceptor) !void {
        if (self.telemetry_sink) |sink| {
            sink.record(.{
                .name = "automation.network.capability",
                .trace_id = self.telemetry_context.trace_id,
                .parent_span_id = self.telemetry_context.parent_span_id,
                .command_id = self.telemetry_context.command_id,
                .backend = .webkitgtk,
                .page_id = self.page_id,
                .network_capability = .unsupported,
                .network_operation = .start,
                .unsupported_reason = .web_extension_required,
                .debt_kind = .network_interception,
                .result_status = .unsupported,
            });
        }
        return error.CapabilityUnsupported;
    }
};

pub const WkWebViewInputDispatcher = struct {
    eval: *FakePlatformEval,
    page_id: []const u8,
    telemetry_sink: ?*InMemoryPlatformTelemetry = null,
    telemetry_context: PlatformTelemetryContext = .{},

    pub fn init(eval: *FakePlatformEval, page_id: []const u8) WkWebViewInputDispatcher {
        return .{ .eval = eval, .page_id = page_id };
    }

    pub fn dispatchMouse(self: *WkWebViewInputDispatcher, input: MouseInput) !ActionResult {
        if (input.trial) return .{ .status = .success };
        var script_storage: [512]u8 = undefined;
        const script = try syntheticMouseScript(script_storage[0..], input);
        const result = self.eval.evaluate(.automation, .synthetic_input, script) catch |err| {
            self.recordInputDispatchSpan(.failed, script.len);
            self.recordEvalSpan(.failed, .eval_failed, script.len);
            return err;
        };
        self.recordInputDispatchSpan(.success, script.len);
        self.recordEvalSpan(.success, null, script.len);
        return result;
    }

    pub fn dispatchKey(self: *WkWebViewInputDispatcher, input: KeyInput) !ActionResult {
        if (input.trial) return .{ .status = .success };
        var script_storage: [512]u8 = undefined;
        const script = try syntheticKeyScript(script_storage[0..], input);
        const result = self.eval.evaluate(.automation, .synthetic_input, script) catch |err| {
            self.recordInputDispatchSpan(.failed, script.len);
            self.recordEvalSpan(.failed, .eval_failed, script.len);
            return err;
        };
        self.recordInputDispatchSpan(.success, script.len);
        self.recordEvalSpan(.success, null, script.len);
        return result;
    }

    fn recordInputDispatchSpan(self: *WkWebViewInputDispatcher, status: ResultStatus, payload_bytes: usize) void {
        if (self.telemetry_sink) |sink| {
            sink.record(.{
                .name = "automation.input.dispatch",
                .trace_id = self.telemetry_context.trace_id,
                .parent_span_id = self.telemetry_context.parent_span_id,
                .command_id = self.telemetry_context.command_id,
                .backend = .wkwebview,
                .page_id = self.page_id,
                .input_mode = .js_synthetic,
                .content_world = .automation,
                .payload_bytes = payload_bytes,
                .result_bytes = 2,
                .result_status = status,
            });
        }
    }

    fn recordEvalSpan(self: *WkWebViewInputDispatcher, status: ResultStatus, error_class: ?PlatformErrorClass, payload_bytes: usize) void {
        if (self.telemetry_sink) |sink| {
            sink.record(.{
                .name = "automation.platform.eval",
                .trace_id = self.telemetry_context.trace_id,
                .parent_span_id = self.telemetry_context.parent_span_id,
                .command_id = self.telemetry_context.command_id,
                .backend = .wkwebview,
                .page_id = self.page_id,
                .input_mode = .js_synthetic,
                .content_world = .automation,
                .eval_kind = .synthetic_input,
                .platform_error_class = error_class,
                .payload_bytes = payload_bytes,
                .result_bytes = if (status == .success) 2 else 0,
                .result_status = status,
            });
        }
    }
};

pub const WkWebViewNetworkInterceptor = struct {
    page_id: []const u8,
    telemetry_sink: ?*InMemoryPlatformTelemetry = null,
    telemetry_context: PlatformTelemetryContext = .{},

    pub fn init(page_id: []const u8) WkWebViewNetworkInterceptor {
        return .{ .page_id = page_id };
    }

    pub fn capability(self: *const WkWebViewNetworkInterceptor) NetworkCapability {
        _ = self;
        return .{
            .support = .unsupported,
            .unsupported_reason = .no_platform_api,
        };
    }

    pub fn start(self: *WkWebViewNetworkInterceptor) !void {
        if (self.telemetry_sink) |sink| {
            sink.record(.{
                .name = "automation.network.capability",
                .trace_id = self.telemetry_context.trace_id,
                .parent_span_id = self.telemetry_context.parent_span_id,
                .command_id = self.telemetry_context.command_id,
                .backend = .wkwebview,
                .page_id = self.page_id,
                .network_capability = .unsupported,
                .network_operation = .start,
                .unsupported_reason = .no_platform_api,
                .debt_kind = .network_interception,
                .result_status = .unsupported,
            });
        }
        return error.CapabilityUnsupported;
    }
};

fn syntheticMouseScript(storage: []u8, input: MouseInput) ![]const u8 {
    const x: i64 = @intFromFloat(input.x);
    const y: i64 = @intFromFloat(input.y);
    const button = input.button orelse "left";
    return std.fmt.bufPrint(
        storage,
        "document.elementFromPoint({d},{d})?.dispatchEvent(new PointerEvent('{s}',{{button:'{s}',bubbles:true}}));",
        .{ x, y, mouseEventName(input.action), button },
    ) catch return error.ScriptTooLarge;
}

fn syntheticKeyScript(storage: []u8, input: KeyInput) ![]const u8 {
    return std.fmt.bufPrint(
        storage,
        "document.activeElement?.dispatchEvent(new KeyboardEvent('{s}',{{key:'{s}',bubbles:true}}));",
        .{ keyEventName(input.action), input.key },
    ) catch return error.ScriptTooLarge;
}

fn mouseEventName(action: MouseAction) []const u8 {
    return switch (action) {
        .move => "pointermove",
        .down => "pointerdown",
        .up => "pointerup",
        .click => "click",
    };
}

fn keyEventName(action: KeyAction) []const u8 {
    return switch (action) {
        .down => "keydown",
        .up => "keyup",
        .type => "keydown",
    };
}

const RedactedUrl = struct {
    host: []const u8,
    path_hash: []const u8,
};

fn redactUrl(url: []const u8, host_storage: []u8, path_hash_storage: []u8) !RedactedUrl {
    const parsed = std.Uri.parse(url) catch return error.InvalidNetworkUrl;
    const host_component = parsed.host orelse return error.InvalidNetworkUrl;
    const host = componentBytes(host_component);
    if (host.len > host_storage.len) return error.HostTooLong;
    @memcpy(host_storage[0..host.len], host);

    const path = componentBytes(parsed.path);
    const query = if (parsed.query) |query_component| componentBytes(query_component) else "";
    var path_query_storage: [1024]u8 = undefined;
    const path_query = if (query.len == 0)
        path
    else
        std.fmt.bufPrint(path_query_storage[0..], "{s}?{s}", .{ path, query }) catch return error.PathTooLong;

    return .{
        .host = host_storage[0..host.len],
        .path_hash = try hashTextToStorage(path_query, path_hash_storage),
    };
}

fn componentBytes(component: std.Uri.Component) []const u8 {
    return switch (component) {
        .raw => |raw| raw,
        .percent_encoded => |percent_encoded| percent_encoded,
    };
}

fn hashTextToStorage(value: []const u8, storage: []u8) ![]const u8 {
    const hash = std.hash.Wyhash.hash(0, value);
    return std.fmt.bufPrint(storage, "{x}", .{hash}) catch return error.HashBufferTooSmall;
}

fn statusClass(status_code: u16) HttpStatusClass {
    return switch (status_code) {
        100...199 => .informational,
        200...299 => .success,
        300...399 => .redirect,
        400...499 => .client_error,
        500...599 => .server_error,
        else => .unknown,
    };
}

pub fn recordCookieCommandTelemetry(
    sink: *InMemoryPlatformTelemetry,
    context: PlatformTelemetryContext,
    command: CookieCommandTelemetry,
) void {
    const slot = sink.count % InMemoryPlatformTelemetry.max_spans;
    const domain_hash = hashTextToStorage(command.domain, sink.cookie_domain_hash_storage[slot][0..]) catch "hash-error";
    const name_hash = hashTextToStorage(command.name, sink.cookie_name_hash_storage[slot][0..]) catch "hash-error";
    sink.record(.{
        .name = "automation.cookie.command",
        .trace_id = context.trace_id,
        .parent_span_id = context.parent_span_id,
        .command_id = context.command_id,
        .backend = command.backend,
        .page_id = command.page_id,
        .cookie_operation = command.operation,
        .cookie_domain_hash = domain_hash,
        .cookie_name_hash = name_hash,
        .cookie_count = command.count,
        .payload_bytes = command.domain.len + command.name.len,
        .result_bytes = command.count,
        .result_status = .success,
    });
}

fn expectPlatformSpanComplete(span: PlatformSpan) !void {
    try testing.expect(span.name.len > 0);
    try testing.expect(span.trace_id.len > 0);
    try testing.expect(span.span_id.len > 0);
    try testing.expect(span.parent_span_id != null);
    try testing.expect(span.parent_span_id.?.len > 0);
    try testing.expect(span.command_id != null);
    try testing.expect(span.command_id.?.len > 0);
    try testing.expect(span.page_id.len > 0);
    try testing.expect(span.duration_ms > 0);
}

pub const PlatformSpan = struct {
    name: []const u8 = "automation.network.capability",
    trace_id: []const u8 = "",
    span_id: []const u8 = "",
    parent_span_id: ?[]const u8 = null,
    command_id: ?[]const u8 = null,
    backend: BackendName = .webkitgtk,
    page_id: []const u8 = "",
    input_mode: InputMode = .js_synthetic,
    content_world: ?ContentWorld = null,
    eval_kind: ?EvalKind = null,
    network_capability: NetworkSupport = .unsupported,
    network_operation: NetworkOperation = .capability,
    unsupported_reason: ?UnsupportedReason = null,
    drop_reason: ?DropReason = null,
    debt_kind: ?DebtKind = null,
    platform_error_class: ?PlatformErrorClass = null,
    target_host: ?[]const u8 = null,
    target_path_hash: ?[]const u8 = null,
    network_request_id_hash: ?[]const u8 = null,
    http_method: ?HttpMethod = null,
    http_status_code: ?u16 = null,
    http_status_class: ?HttpStatusClass = null,
    resource_kind: ?ResourceKind = null,
    rate_limit: ?bool = null,
    cookie_operation: ?CookieOperation = null,
    cookie_domain_hash: ?[]const u8 = null,
    cookie_name_hash: ?[]const u8 = null,
    cookie_count: usize = 0,
    payload_bytes: usize = 0,
    result_bytes: usize = 0,
    duration_ms: u64 = 0,
    raw_payload: ?[]const u8 = null,
    result_status: ResultStatus = .unsupported,
};

pub const InMemoryPlatformTelemetry = struct {
    pub const max_spans = 64;

    count: usize = 0,
    last_span: PlatformSpan = .{},
    spans: [max_spans]PlatformSpan = undefined,
    span_id_storage: [max_spans][32]u8 = undefined,
    cookie_domain_hash_storage: [max_spans][32]u8 = undefined,
    cookie_name_hash_storage: [max_spans][32]u8 = undefined,

    pub fn init() InMemoryPlatformTelemetry {
        return .{};
    }

    pub fn record(self: *InMemoryPlatformTelemetry, span: PlatformSpan) void {
        var completed = span;
        if (completed.trace_id.len == 0) completed.trace_id = "trace-platform";
        if (completed.parent_span_id == null) completed.parent_span_id = "span-root";
        if (completed.command_id == null) completed.command_id = "cmd-platform";
        if (completed.duration_ms == 0) completed.duration_ms = 1;
        const slot = self.count % max_spans;
        completed.span_id = std.fmt.bufPrint(self.span_id_storage[slot][0..], "span-{d}", .{self.count + 1}) catch "span-overflow";
        if (self.count < max_spans) self.spans[self.count] = completed;
        self.count += 1;
        self.last_span = completed;
    }

    pub fn hasSpanNamed(self: *const InMemoryPlatformTelemetry, name: []const u8) bool {
        return self.spanByName(name) != null;
    }

    pub fn spanByName(self: *const InMemoryPlatformTelemetry, name: []const u8) ?PlatformSpan {
        for (self.spans[0..@min(self.count, max_spans)]) |span| {
            if (std.mem.eql(u8, span.name, name)) return span;
        }
        return null;
    }
};

test "P3.1 platform capability names are explicit per backend" {
    const webview2 = adapterCapabilities(.webview2);
    try testing.expectEqual(InputMode.cdp_input, webview2.input.mode);
    try testing.expectEqual(NetworkSupport.supported, webview2.network.support);

    const gtk = adapterCapabilities(.webkitgtk);
    try testing.expectEqual(InputMode.js_synthetic, gtk.input.mode);
    try testing.expectEqual(NetworkSupport.unsupported, gtk.network.support);
    try testing.expectEqual(UnsupportedReason.web_extension_required, gtk.network.unsupported_reason.?);

    const wk = adapterCapabilities(.wkwebview);
    try testing.expectEqual(InputMode.js_synthetic, wk.input.mode);
    try testing.expectEqual(NetworkSupport.unsupported, wk.network.support);
    try testing.expectEqual(UnsupportedReason.no_platform_api, wk.network.unsupported_reason.?);
}

test "P3.1 unsupported network start returns typed capability error" {
    var adapter = PlatformAdapter.init(.webkitgtk);
    try testing.expectError(error.CapabilityUnsupported, adapter.startNetwork("page-1"));
    try testing.expect(adapter.last_unsupported_reason == .web_extension_required);
}

test "P3.1 unsupported network capability emits telemetry instead of silent success" {
    var sink = InMemoryPlatformTelemetry.init();
    var adapter = PlatformAdapter.init(.wkwebview);
    adapter.telemetry_sink = &sink;

    try testing.expectError(error.CapabilityUnsupported, adapter.startNetwork("page-42"));

    try testing.expectEqual(@as(usize, 1), sink.count);
    try testing.expectEqualStrings("automation.network.capability", sink.last_span.name);
    try testing.expectEqual(BackendName.wkwebview, sink.last_span.backend);
    try testing.expectEqual(NetworkSupport.unsupported, sink.last_span.network_capability);
    try testing.expectEqual(UnsupportedReason.no_platform_api, sink.last_span.unsupported_reason.?);
    try testing.expectEqual(ResultStatus.unsupported, sink.last_span.result_status);
    try testing.expectEqualStrings("page-42", sink.last_span.page_id);
}

test "P3.2 WebView2 CDP input dispatch records Input.dispatchMouseEvent and Input.dispatchKeyEvent" {
    var cdp = FakeWebView2Cdp{};
    var dispatcher = WebView2InputDispatcher.init(&cdp);

    try dispatcher.dispatchMouse(.{
        .action = .click,
        .x = 10,
        .y = 20,
        .button = "left",
    });
    try dispatcher.dispatchKey(.{
        .action = .type,
        .key = "A",
        .text = "A",
    });

    try testing.expectEqual(@as(usize, 2), cdp.call_count);
    try testing.expectEqualStrings("Input.dispatchMouseEvent", cdp.methods[0]);
    try testing.expectEqualStrings("Input.dispatchKeyEvent", cdp.methods[1]);
    try testing.expect(!cdp.called("Runtime.enable"));
}

test "P3.2 WebView2 input trial mode emits no native dispatch call" {
    var cdp = FakeWebView2Cdp{};
    var dispatcher = WebView2InputDispatcher.init(&cdp);

    try dispatcher.dispatchMouse(.{
        .action = .click,
        .x = 10,
        .y = 20,
        .button = "left",
        .trial = true,
    });

    try testing.expectEqual(@as(usize, 0), cdp.call_count);
}

test "P3.3 WebView2 NetworkInterceptor start and stop register handlers idempotently" {
    var fake = FakeWebView2NetworkAdapter{};
    var telemetry = InMemoryPlatformTelemetry.init();
    var interceptor = WebView2NetworkInterceptor.init(&fake, "page-network");
    interceptor.telemetry_sink = &telemetry;

    try testing.expectEqual(NetworkSupport.supported, interceptor.capability().support);

    try interceptor.start();
    try interceptor.start();
    try testing.expectEqual(@as(usize, 1), fake.add_filter_count);
    try testing.expect(fake.handler_registered);

    try interceptor.stop();
    try interceptor.stop();
    try testing.expectEqual(@as(usize, 1), fake.remove_handler_count);
    try testing.expect(!fake.handler_registered);
    try testing.expectEqualStrings("automation.network.capability", telemetry.last_span.name);
    try testing.expectEqual(ResultStatus.success, telemetry.last_span.result_status);
    try testing.expectEqualStrings("page-network", telemetry.last_span.page_id);
}

test "P3.3 WebView2 NetworkInterceptor polls sanitized events and classifies rate limits" {
    var fake = FakeWebView2NetworkAdapter{};
    var telemetry = InMemoryPlatformTelemetry.init();
    var interceptor = WebView2NetworkInterceptor.init(&fake, "page-network");
    interceptor.telemetry_sink = &telemetry;

    try interceptor.start();
    try interceptor.capturePlatformEvent(.{
        .request_id = "request-429",
        .url = "https://example.test/private/path?token=secret",
        .method = .GET,
        .status_code = 429,
        .resource_kind = .fetch,
    });

    const event = interceptor.pollEvent().?;
    try testing.expectEqual(NetworkEventKind.response, event.kind);
    try testing.expectEqual(HttpMethod.GET, event.http_method);
    try testing.expectEqual(@as(u16, 429), event.status_code);
    try testing.expectEqual(HttpStatusClass.client_error, event.status_class);
    try testing.expectEqual(ResourceKind.fetch, event.resource_kind);
    try testing.expect(event.rate_limit);
    try testing.expectEqualStrings("example.test", event.target_host);
    try testing.expect(!std.mem.eql(u8, "private/path?token=secret", event.target_path_hash));
    try testing.expect(std.mem.indexOf(u8, event.target_path_hash, "token") == null);
    try testing.expectEqualStrings("automation.network.event", telemetry.last_span.name);
    try testing.expectEqual(NetworkOperation.event, telemetry.last_span.network_operation);
    try testing.expectEqual(ResultStatus.success, telemetry.last_span.result_status);
}

test "P3.3 WebView2 NetworkInterceptor bounded queue drops with diagnostics" {
    var fake = FakeWebView2NetworkAdapter{};
    var telemetry = InMemoryPlatformTelemetry.init();
    var interceptor = WebView2NetworkInterceptor.initWithCapacity(&fake, "page-queue", 1);
    interceptor.telemetry_sink = &telemetry;

    try interceptor.start();
    try interceptor.capturePlatformEvent(.{
        .request_id = "request-1",
        .url = "https://example.test/a",
        .method = .GET,
        .status_code = 200,
        .resource_kind = .document,
    });
    try interceptor.capturePlatformEvent(.{
        .request_id = "request-2",
        .url = "https://example.test/b",
        .method = .GET,
        .status_code = 200,
        .resource_kind = .image,
    });

    try testing.expectEqual(@as(usize, 1), interceptor.drop_count);
    try testing.expectEqual(DropReason.queue_full, interceptor.last_drop_reason.?);
    try testing.expectEqualStrings("automation.network.event", telemetry.last_span.name);
    try testing.expectEqual(DropReason.queue_full, telemetry.last_span.drop_reason.?);
    try testing.expect(interceptor.pollEvent() != null);
    try testing.expect(interceptor.pollEvent() == null);
}

test "P3.4 WebKitGTK synthetic input evaluates isolated-world JS command shape" {
    var eval = FakePlatformEval{};
    var telemetry = InMemoryPlatformTelemetry.init();
    var dispatcher = WebKitGtkInputDispatcher.init(&eval, "page-gtk");
    dispatcher.telemetry_sink = &telemetry;

    const mouse_result = try dispatcher.dispatchMouse(.{
        .action = .click,
        .x = 12,
        .y = 34,
        .button = "left",
    });
    try testing.expectEqual(ResultStatus.success, mouse_result.status);
    try testing.expectEqual(@as(usize, 1), eval.call_count);
    try testing.expectEqual(ContentWorld.isolated, eval.last_content_world);
    try testing.expectEqual(EvalKind.synthetic_input, eval.last_eval_kind);
    try testing.expect(std.mem.indexOf(u8, eval.last_script, "dispatchEvent") != null);
    try testing.expect(std.mem.indexOf(u8, eval.last_script, "PointerEvent") != null);
    try testing.expect(std.mem.indexOf(u8, eval.last_script, "window.") == null);
    try testing.expectEqualStrings("automation.platform.eval", telemetry.last_span.name);
    try testing.expectEqual(InputMode.js_synthetic, telemetry.last_span.input_mode);
    try testing.expectEqual(ContentWorld.isolated, telemetry.last_span.content_world.?);

    _ = try dispatcher.dispatchKey(.{
        .action = .type,
        .key = "A",
        .text = "A",
    });
    try testing.expectEqual(@as(usize, 2), eval.call_count);
    try testing.expect(std.mem.indexOf(u8, eval.last_script, "KeyboardEvent") != null);
}

test "P3.4 WebKitGTK eval failure maps to platform error telemetry" {
    var eval = FakePlatformEval{ .fail_next = true };
    var telemetry = InMemoryPlatformTelemetry.init();
    var dispatcher = WebKitGtkInputDispatcher.init(&eval, "page-gtk");
    dispatcher.telemetry_sink = &telemetry;

    try testing.expectError(error.PlatformEvalFailed, dispatcher.dispatchMouse(.{
        .action = .click,
        .x = 1,
        .y = 2,
        .button = "left",
    }));

    try testing.expectEqualStrings("automation.platform.eval", telemetry.last_span.name);
    try testing.expectEqual(ResultStatus.failed, telemetry.last_span.result_status);
    try testing.expectEqual(PlatformErrorClass.eval_failed, telemetry.last_span.platform_error_class.?);
}

test "P3.4 WebKitGTK NetworkInterceptor start returns unsupported Web Extension debt" {
    var telemetry = InMemoryPlatformTelemetry.init();
    var network = WebKitGtkNetworkInterceptor.init("page-gtk");
    network.telemetry_sink = &telemetry;

    const capability = network.capability();
    try testing.expectEqual(NetworkSupport.unsupported, capability.support);
    try testing.expectEqual(UnsupportedReason.web_extension_required, capability.unsupported_reason.?);

    try testing.expectError(error.CapabilityUnsupported, network.start());
    try testing.expectEqualStrings("automation.network.capability", telemetry.last_span.name);
    try testing.expectEqual(BackendName.webkitgtk, telemetry.last_span.backend);
    try testing.expectEqual(NetworkSupport.unsupported, telemetry.last_span.network_capability);
    try testing.expectEqual(UnsupportedReason.web_extension_required, telemetry.last_span.unsupported_reason.?);
    try testing.expectEqual(DebtKind.network_interception, telemetry.last_span.debt_kind.?);
    try testing.expectEqual(ResultStatus.unsupported, telemetry.last_span.result_status);
}

test "P3.5 WKWebView synthetic input evaluates automation content world exactly once" {
    var eval = FakePlatformEval{};
    var telemetry = InMemoryPlatformTelemetry.init();
    var dispatcher = WkWebViewInputDispatcher.init(&eval, "page-wk");
    dispatcher.telemetry_sink = &telemetry;

    const result = try dispatcher.dispatchKey(.{
        .action = .type,
        .key = "A",
        .text = "A",
    });

    try testing.expectEqual(ResultStatus.success, result.status);
    try testing.expectEqual(@as(usize, 1), eval.call_count);
    try testing.expectEqual(ContentWorld.automation, eval.last_content_world);
    try testing.expect(eval.last_content_world != .page);
    try testing.expectEqual(EvalKind.synthetic_input, eval.last_eval_kind);
    try testing.expect(std.mem.indexOf(u8, eval.last_script, "KeyboardEvent") != null);
    try testing.expectEqualStrings("automation.platform.eval", telemetry.last_span.name);
    try testing.expectEqual(BackendName.wkwebview, telemetry.last_span.backend);
    try testing.expectEqual(ContentWorld.automation, telemetry.last_span.content_world.?);
    try testing.expectEqual(ResultStatus.success, telemetry.last_span.result_status);
}

test "P3.5 WKWebView NetworkInterceptor start returns unsupported no-platform-api debt" {
    var telemetry = InMemoryPlatformTelemetry.init();
    var network = WkWebViewNetworkInterceptor.init("page-wk");
    network.telemetry_sink = &telemetry;

    const capability = network.capability();
    try testing.expectEqual(NetworkSupport.unsupported, capability.support);
    try testing.expectEqual(UnsupportedReason.no_platform_api, capability.unsupported_reason.?);

    try testing.expectError(error.CapabilityUnsupported, network.start());
    try testing.expectEqualStrings("automation.network.capability", telemetry.last_span.name);
    try testing.expectEqual(BackendName.wkwebview, telemetry.last_span.backend);
    try testing.expectEqual(NetworkSupport.unsupported, telemetry.last_span.network_capability);
    try testing.expectEqual(UnsupportedReason.no_platform_api, telemetry.last_span.unsupported_reason.?);
    try testing.expectEqual(DebtKind.network_interception, telemetry.last_span.debt_kind.?);
    try testing.expectEqual(ResultStatus.unsupported, telemetry.last_span.result_status);
}

test "P3.6 platform adapter spans carry required correlation fields" {
    var telemetry = InMemoryPlatformTelemetry.init();
    const context = PlatformTelemetryContext{
        .trace_id = "trace-p36",
        .parent_span_id = "root-p36",
        .command_id = "cmd-p36",
    };

    var eval = FakePlatformEval{};
    var gtk_input = WebKitGtkInputDispatcher.init(&eval, "page-p36");
    gtk_input.telemetry_sink = &telemetry;
    gtk_input.telemetry_context = context;
    _ = try gtk_input.dispatchMouse(.{
        .action = .click,
        .x = 3,
        .y = 4,
        .button = "left",
    });

    var fake_network = FakeWebView2NetworkAdapter{};
    var webview2_network = WebView2NetworkInterceptor.init(&fake_network, "page-p36");
    webview2_network.telemetry_sink = &telemetry;
    webview2_network.telemetry_context = context;
    try webview2_network.start();
    try webview2_network.capturePlatformEvent(.{
        .request_id = "request-p36",
        .url = "https://example.test/ok",
        .method = .GET,
        .status_code = 200,
        .resource_kind = .document,
    });

    var gtk_network = WebKitGtkNetworkInterceptor.init("page-p36");
    gtk_network.telemetry_sink = &telemetry;
    gtk_network.telemetry_context = context;
    try testing.expectError(error.CapabilityUnsupported, gtk_network.start());

    recordCookieCommandTelemetry(&telemetry, context, .{
        .backend = .webkitgtk,
        .page_id = "page-p36",
        .operation = .get,
        .domain = "example.test",
        .name = "session",
        .count = 1,
    });

    try testing.expect(telemetry.hasSpanNamed("automation.input.dispatch"));
    try testing.expect(telemetry.hasSpanNamed("automation.platform.eval"));
    try testing.expect(telemetry.hasSpanNamed("automation.network.capability"));
    try testing.expect(telemetry.hasSpanNamed("automation.network.event"));
    try testing.expect(telemetry.hasSpanNamed("automation.cookie.command"));

    for (telemetry.spans[0..telemetry.count]) |span| {
        try expectPlatformSpanComplete(span);
        try testing.expectEqualStrings("trace-p36", span.trace_id);
        try testing.expectEqualStrings("root-p36", span.parent_span_id.?);
        try testing.expectEqualStrings("cmd-p36", span.command_id.?);
    }
}

test "P3.6 platform spans redact raw payloads and expose hashed dimensions" {
    var telemetry = InMemoryPlatformTelemetry.init();
    const context = PlatformTelemetryContext{
        .trace_id = "trace-redact",
        .parent_span_id = "root-redact",
        .command_id = "cmd-redact",
    };

    var fake_network = FakeWebView2NetworkAdapter{};
    var network = WebView2NetworkInterceptor.init(&fake_network, "page-redact");
    network.telemetry_sink = &telemetry;
    network.telemetry_context = context;
    try network.start();
    try network.capturePlatformEvent(.{
        .request_id = "raw-request-id",
        .url = "https://example.test/private/path?token=secret",
        .method = .GET,
        .status_code = 403,
        .resource_kind = .fetch,
    });

    recordCookieCommandTelemetry(&telemetry, context, .{
        .backend = .wkwebview,
        .page_id = "page-redact",
        .operation = .set,
        .domain = "secret.example.test",
        .name = "session_token",
        .count = 1,
    });

    const network_span = telemetry.spanByName("automation.network.event").?;
    try testing.expectEqualStrings("example.test", network_span.target_host.?);
    try testing.expect(network_span.target_path_hash != null);
    try testing.expect(std.mem.indexOf(u8, network_span.target_path_hash.?, "token") == null);
    try testing.expect(std.mem.indexOf(u8, network_span.target_path_hash.?, "secret") == null);
    try testing.expect(network_span.raw_payload == null);

    const cookie_span = telemetry.spanByName("automation.cookie.command").?;
    try testing.expect(cookie_span.cookie_domain_hash != null);
    try testing.expect(cookie_span.cookie_name_hash != null);
    try testing.expect(!std.mem.eql(u8, "secret.example.test", cookie_span.cookie_domain_hash.?));
    try testing.expect(!std.mem.eql(u8, "session_token", cookie_span.cookie_name_hash.?));
    try testing.expect(cookie_span.raw_payload == null);
}
