const std = @import("std");

pub const version = "zb-sequences-v1";
pub const base_path = "/api/v1/automation";

pub const canonical_hashing = struct {
    pub const digest_len = std.crypto.hash.sha2.Sha256.digest_length;
    pub const hex_len = digest_len * 2;
    pub const prefixed_hash_len = "sha256:".len + hex_len;
    pub const hmac_sha256_len = std.crypto.auth.hmac.sha2.HmacSha256.mac_length;
    pub const empty_body_hash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

    pub fn sha256Hex(dest: *[hex_len]u8, bytes: []const u8) []const u8 {
        var digest: [digest_len]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        return lowerHex(dest, &digest);
    }

    pub fn hbytes(dest: *[hex_len]u8, bytes: []const u8) []const u8 {
        return sha256Hex(dest, bytes);
    }

    pub fn h(dest: *[prefixed_hash_len]u8, text: []const u8) []const u8 {
        @memcpy(dest[0.."sha256:".len], "sha256:");

        var digest: [digest_len]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(text, &digest, .{});
        _ = writeLowerHex(dest["sha256:".len..], &digest);
        return dest[0..prefixed_hash_len];
    }

    pub fn lowerHex(dest: *[hex_len]u8, bytes: []const u8) []const u8 {
        return writeLowerHex(dest[0..], bytes);
    }

    pub fn writeLowerHex(dest: []u8, bytes: []const u8) []const u8 {
        std.debug.assert(dest.len >= bytes.len * 2);
        const alphabet = "0123456789abcdef";
        for (bytes, 0..) |byte, i| {
            dest[i * 2] = alphabet[byte >> 4];
            dest[i * 2 + 1] = alphabet[byte & 0x0f];
        }
        return dest[0 .. bytes.len * 2];
    }

    pub fn hmacSha256(dest: *[hmac_sha256_len]u8, secret: []const u8, message: []const u8) void {
        std.crypto.auth.hmac.sha2.HmacSha256.create(dest, message, secret);
    }

    pub fn base64UrlNoPad(dest: []u8, bytes: []const u8) []const u8 {
        return std.base64.url_safe_no_pad.Encoder.encode(dest, bytes);
    }

    pub fn base64UrlNoPadAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
        const encoded = try allocator.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(bytes.len));
        return @constCast(base64UrlNoPad(encoded, bytes));
    }
};

pub const ServiceAuth = struct {
    client_id: []const u8,
    secret: []const u8,
};

pub const HmacMode = enum {
    none,
    optional,
    required,
};

pub const Idempotency = union(enum) {
    none,
    key: []const u8,
    generate,
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const BuildPreparedRequestError = error{
    MissingServiceAuth,
    InvalidTimeout,
    EntropyUnavailable,
    Canceled,
    OutOfMemory,
};

pub const PreparedRequest = struct {
    arena: std.heap.ArenaAllocator,
    method: std.http.Method,
    request_target: []const u8,
    url: []const u8,
    body: []const u8,
    headers: []const Header,
    timeout_ms: u32,
    body_hash: []const u8,
    idempotency_key_hash: ?[]const u8,
    signature_base: ?[]const u8,

    pub const BuildOptions = struct {
        base_url: []const u8,
        delegated_user_token: []const u8,
        service_auth: ?ServiceAuth = null,
        hmac: HmacMode = .required,
        method: std.http.Method,
        request_target: []const u8,
        body: []const u8 = "",
        idempotency: Idempotency = .none,
        timestamp_ms: ?i64 = null,
        nonce: ?[]const u8 = null,
        timeout_ms: u32 = 5000,
    };

    pub fn build(parent_allocator: std.mem.Allocator, options: BuildOptions) BuildPreparedRequestError!PreparedRequest {
        if (options.timeout_ms == 0) return error.InvalidTimeout;

        var arena = std.heap.ArenaAllocator.init(parent_allocator);
        errdefer arena.deinit();
        const allocator = arena.allocator();

        var headers: std.ArrayListUnmanaged(Header) = .empty;
        const body = try allocator.dupe(u8, options.body);
        const request_target = try allocator.dupe(u8, options.request_target);
        const url = try joinBaseUrl(allocator, options.base_url, options.request_target);

        var body_hash_stack: [canonical_hashing.hex_len]u8 = undefined;
        const body_hash = try allocator.dupe(u8, canonical_hashing.hbytes(&body_hash_stack, body));

        try appendHeader(allocator, &headers, "X-ZB-Sequences-Version", version);
        try appendHeader(
            allocator,
            &headers,
            "Authorization",
            try std.fmt.allocPrint(allocator, "Bearer {s}", .{options.delegated_user_token}),
        );
        if (options.method.requestHasBody()) {
            try appendHeader(allocator, &headers, "Content-Type", "application/json");
        }

        var signature_base: ?[]const u8 = null;
        switch (options.hmac) {
            .none => {},
            .optional => if (options.service_auth) |auth| {
                signature_base = try addSignatureHeaders(allocator, &headers, options, auth, body_hash);
            },
            .required => {
                const auth = options.service_auth orelse return error.MissingServiceAuth;
                signature_base = try addSignatureHeaders(allocator, &headers, options, auth, body_hash);
            },
        }

        var idempotency_key_hash: ?[]const u8 = null;
        switch (options.idempotency) {
            .none => {},
            .key => |key| {
                const owned_key = try allocator.dupe(u8, key);
                try appendHeader(allocator, &headers, "Idempotency-Key", owned_key);
                var prefixed: [canonical_hashing.prefixed_hash_len]u8 = undefined;
                idempotency_key_hash = try allocator.dupe(u8, canonical_hashing.h(&prefixed, owned_key));
            },
            .generate => {
                const key = try generateIdempotencyKey(allocator);
                try appendHeader(allocator, &headers, "Idempotency-Key", key);
                var prefixed: [canonical_hashing.prefixed_hash_len]u8 = undefined;
                idempotency_key_hash = try allocator.dupe(u8, canonical_hashing.h(&prefixed, key));
            },
        }

        return .{
            .arena = arena,
            .method = options.method,
            .request_target = request_target,
            .url = url,
            .body = body,
            .headers = headers.items,
            .timeout_ms = options.timeout_ms,
            .body_hash = body_hash,
            .idempotency_key_hash = idempotency_key_hash,
            .signature_base = signature_base,
        };
    }

    pub fn deinit(self: *PreparedRequest) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn headerValue(self: *const PreparedRequest, name: []const u8) ?[]const u8 {
        for (self.headers) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
        }
        return null;
    }

    pub fn wireBytesEqual(self: *const PreparedRequest, other: *const PreparedRequest) bool {
        if (self.method != other.method) return false;
        if (self.timeout_ms != other.timeout_ms) return false;
        if (!std.mem.eql(u8, self.request_target, other.request_target)) return false;
        if (!std.mem.eql(u8, self.url, other.url)) return false;
        if (!std.mem.eql(u8, self.body, other.body)) return false;
        if (self.headers.len != other.headers.len) return false;
        for (self.headers, other.headers) |left, right| {
            if (!std.mem.eql(u8, left.name, right.name)) return false;
            if (!std.mem.eql(u8, left.value, right.value)) return false;
        }
        return true;
    }

    fn addSignatureHeaders(
        allocator: std.mem.Allocator,
        headers: *std.ArrayListUnmanaged(Header),
        options: BuildOptions,
        auth: ServiceAuth,
        body_hash: []const u8,
    ) ![]const u8 {
        const timestamp_ms = options.timestamp_ms orelse currentUnixMillis();
        const timestamp = try std.fmt.allocPrint(allocator, "{d}", .{timestamp_ms});
        const nonce = if (options.nonce) |provided| try allocator.dupe(u8, provided) else try generateNonce(allocator);
        const signature_base = try buildSignatureBase(
            allocator,
            options.method,
            options.request_target,
            timestamp,
            nonce,
            body_hash,
        );
        const signature = try signBaseString(allocator, auth.secret, signature_base);

        try appendHeader(allocator, headers, "X-ZB-Client-Id", auth.client_id);
        try appendHeader(allocator, headers, "X-ZB-Timestamp", timestamp);
        try appendHeader(allocator, headers, "X-ZB-Nonce", nonce);
        try appendHeader(allocator, headers, "X-ZB-Signature", signature);
        return signature_base;
    }
};

pub fn buildSignatureBase(
    allocator: std.mem.Allocator,
    method: std.http.Method,
    request_target: []const u8,
    timestamp: []const u8,
    nonce: []const u8,
    body_hash: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "v1\n{s}\n{s}\n{s}\n{s}\n{s}",
        .{ @tagName(method), request_target, timestamp, nonce, body_hash },
    );
}

pub fn signBaseString(allocator: std.mem.Allocator, secret: []const u8, base: []const u8) ![]u8 {
    var mac: [canonical_hashing.hmac_sha256_len]u8 = undefined;
    canonical_hashing.hmacSha256(&mac, secret, base);
    const encoded_len = std.base64.url_safe_no_pad.Encoder.calcSize(mac.len);
    const signature = try allocator.alloc(u8, "v1=".len + encoded_len);
    @memcpy(signature[0.."v1=".len], "v1=");
    _ = canonical_hashing.base64UrlNoPad(signature["v1=".len..], &mac);
    return signature;
}

pub const TransportResponse = struct {
    status_code: u16,
    body: []u8,

    pub fn deinit(self: *TransportResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        self.* = undefined;
    }
};

pub const Transport = struct {
    context: *anyopaque,
    sendFn: *const fn (*anyopaque, std.mem.Allocator, *const PreparedRequest) anyerror!TransportResponse,

    pub fn send(self: Transport, allocator: std.mem.Allocator, request: *const PreparedRequest) !TransportResponse {
        return self.sendFn(self.context, allocator, request);
    }
};

pub const SuccessResponse = struct {
    status_code: u16,
    body: []u8,

    pub fn deinit(self: *SuccessResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        self.* = undefined;
    }
};

pub const CallOutcome = union(enum) {
    success: SuccessResponse,
    api_error: ErrorEnvelope,

    pub fn deinit(self: *CallOutcome, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .success => |*success| success.deinit(allocator),
            .api_error => |*api_error| api_error.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub const AutomationClient = struct {
    allocator: std.mem.Allocator,
    config: Config,
    transport: Transport,

    pub const Config = struct {
        base_url: []const u8,
        delegated_user_token: []const u8,
        service_auth: ?ServiceAuth = null,
        default_timeout_ms: u32 = 5000,
    };

    pub const CallOptions = struct {
        method: std.http.Method,
        request_target: []const u8,
        body: []const u8 = "",
        hmac: HmacMode = .required,
        idempotency: Idempotency = .none,
        timestamp_ms: ?i64 = null,
        nonce: ?[]const u8 = null,
        timeout_ms: ?u32 = null,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config, transport: Transport) AutomationClient {
        return .{ .allocator = allocator, .config = config, .transport = transport };
    }

    pub fn call(self: *AutomationClient, options: CallOptions) !CallOutcome {
        var request = try PreparedRequest.build(self.allocator, .{
            .base_url = self.config.base_url,
            .delegated_user_token = self.config.delegated_user_token,
            .service_auth = self.config.service_auth,
            .hmac = options.hmac,
            .method = options.method,
            .request_target = options.request_target,
            .body = options.body,
            .idempotency = options.idempotency,
            .timestamp_ms = options.timestamp_ms,
            .nonce = options.nonce,
            .timeout_ms = options.timeout_ms orelse self.config.default_timeout_ms,
        });
        defer request.deinit();

        var response = try self.transport.send(self.allocator, &request);
        if (response.status_code >= 400) {
            defer response.deinit(self.allocator);
            return .{ .api_error = try ErrorEnvelope.parse(self.allocator, response.status_code, response.body) };
        }

        return .{ .success = .{ .status_code = response.status_code, .body = response.body } };
    }
};

pub const StdHttpTransport = struct {
    client: *std.http.Client,

    pub fn transport(self: *StdHttpTransport) Transport {
        return .{ .context = self, .sendFn = send };
    }

    fn send(context: *anyopaque, allocator: std.mem.Allocator, request: *const PreparedRequest) !TransportResponse {
        const self: *StdHttpTransport = @ptrCast(@alignCast(context));
        var extra_headers = try allocator.alloc(std.http.Header, request.headers.len);
        defer allocator.free(extra_headers);
        for (request.headers, 0..) |header, i| {
            extra_headers[i] = .{ .name = header.name, .value = header.value };
        }

        var body_writer: std.Io.Writer.Allocating = .init(allocator);
        errdefer body_writer.deinit();

        const payload: ?[]const u8 = if (request.method.requestHasBody()) request.body else null;
        const result = try self.client.fetch(.{
            .location = .{ .url = request.url },
            .method = request.method,
            .payload = payload,
            .response_writer = &body_writer.writer,
            .redirect_behavior = .unhandled,
            .extra_headers = extra_headers,
            .keep_alive = false,
        });

        return .{
            .status_code = @as(u16, @intFromEnum(result.status)),
            .body = try body_writer.toOwnedSlice(),
        };
    }
};

pub const ErrorEnvelope = struct {
    status_code: u16,
    code: []u8,
    message: []u8,
    retryable: ?bool = null,
    request_id: ?[]u8 = null,
    trace_id: ?[]u8 = null,
    command_id: ?[]u8 = null,

    pub fn parse(allocator: std.mem.Allocator, status_code: u16, body: []const u8) !ErrorEnvelope {
        const Wire = struct {
            @"error": struct {
                code: []const u8,
                message: []const u8,
                retryable: ?bool = null,
                requestId: ?[]const u8 = null,
                traceId: ?[]const u8 = null,
                commandId: ?[]const u8 = null,
            },
        };
        var parsed = try std.json.parseFromSlice(Wire, allocator, body, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const err = parsed.value.@"error";
        return .{
            .status_code = status_code,
            .code = try allocator.dupe(u8, err.code),
            .message = try allocator.dupe(u8, err.message),
            .retryable = err.retryable,
            .request_id = try dupeOptional(allocator, err.requestId),
            .trace_id = try dupeOptional(allocator, err.traceId),
            .command_id = try dupeOptional(allocator, err.commandId),
        };
    }

    pub fn deinit(self: *ErrorEnvelope, allocator: std.mem.Allocator) void {
        allocator.free(self.code);
        allocator.free(self.message);
        if (self.request_id) |value| allocator.free(value);
        if (self.trace_id) |value| allocator.free(value);
        if (self.command_id) |value| allocator.free(value);
        self.* = undefined;
    }
};

fn appendHeader(
    allocator: std.mem.Allocator,
    headers: *std.ArrayListUnmanaged(Header),
    name: []const u8,
    value: []const u8,
) !void {
    try headers.append(allocator, .{
        .name = name,
        .value = try allocator.dupe(u8, value),
    });
}

fn dupeOptional(allocator: std.mem.Allocator, value: ?[]const u8) !?[]u8 {
    return if (value) |some| try allocator.dupe(u8, some) else null;
}

fn joinBaseUrl(allocator: std.mem.Allocator, base_url: []const u8, request_target: []const u8) ![]u8 {
    const trimmed_base = std.mem.trimEnd(u8, base_url, "/");
    if (std.mem.startsWith(u8, request_target, "/")) {
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ trimmed_base, request_target });
    }
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ trimmed_base, request_target });
}

fn generateNonce(allocator: std.mem.Allocator) ![]u8 {
    var bytes: [16]u8 = undefined;
    try std.Io.Threaded.global_single_threaded.io().randomSecure(&bytes);
    return canonical_hashing.base64UrlNoPadAlloc(allocator, &bytes);
}

fn generateIdempotencyKey(allocator: std.mem.Allocator) ![]u8 {
    var bytes: [16]u8 = undefined;
    try std.Io.Threaded.global_single_threaded.io().randomSecure(&bytes);
    const encoded = canonical_hashing.base64UrlNoPadAlloc(allocator, &bytes) catch return error.OutOfMemory;
    return std.fmt.allocPrint(allocator, "zb_idem_{s}", .{encoded});
}

fn currentUnixMillis() i64 {
    return std.Io.Clock.real.now(std.Io.Threaded.global_single_threaded.io()).toMilliseconds();
}

pub const endpoint_templates = struct {
    pub const getUiBootstrap = "GET /api/v1/automation/ui/bootstrap";
    pub const listSequences = "GET /api/v1/automation/sequences";
    pub const createDraftSequence = "POST /api/v1/automation/sequences";
    pub const getSequenceDetail = "GET /api/v1/automation/sequences/:sequenceId";
    pub const getSteps = "GET /api/v1/automation/sequences/:sequenceId/steps";
    pub const saveSteps = "PUT /api/v1/automation/sequences/:sequenceId/steps";
    pub const generateStepDraft = "POST /api/v1/automation/sequences/:sequenceId/steps/generate";
    pub const previewStep = "POST /api/v1/automation/sequences/:sequenceId/steps/preview";
    pub const getExecutionPlan = "GET /api/v1/automation/sequences/:sequenceId/execution-plan";
    pub const createExecution = "POST /api/v1/automation/executions";
    pub const updateExecution = "PATCH /api/v1/automation/executions/:executionId";
    pub const recordStepResult = "POST /api/v1/automation/executions/:executionId/steps/:stepExecutionId/result";
    pub const ingestEvents = "POST /api/v1/automation/events";
    pub const ingestTelemetry = "POST /api/v1/automation/telemetry";
    pub const getOutreachAnalytics = "GET /api/v1/automation/analytics/outreach";
};

pub const CallResult = struct {
    status_code: u16,
    body: []const u8,
    duplicate: bool,
    owned_allocator: ?std.mem.Allocator = null,
    error_class: ?[]const u8 = null,
    error_code: ?[]const u8 = null,
    retryable: ?bool = null,

    pub fn deinit(self: *CallResult, allocator: std.mem.Allocator) void {
        const alloc = self.owned_allocator orelse allocator;
        if (self.body.len > 0 and self.owned_allocator != null) {
            alloc.free(@constCast(self.body));
        }
        if (self.error_code) |value| {
            if (self.owned_allocator != null) alloc.free(@constCast(value));
        }
        self.* = undefined;
    }
};

pub const TraceContext = struct {
    trace_id: ?[]const u8 = null,
    command_id: ?[]const u8 = null,
    execution_id: ?[]const u8 = null,
    org_id: ?[]const u8 = null,
    sequence_id: ?[]const u8 = null,
    tenant: ?[]const u8 = null,
    parent_span_id: ?[]const u8 = null,
    automation_trace_id: ?[]const u8 = null,
    external_run_id: ?[]const u8 = null,
    actor_user_id_hash: ?[]const u8 = null,
    session_id_hash: ?[]const u8 = null,
};

pub const ClientConfig = struct {
    client_id: ?[]const u8 = null,
    zigbrowser_version: ?[]const u8 = null,
};

pub const Ev70Span = struct {
    name: []const u8,
    endpoint: []const u8,
    http_method: []const u8,
    http_status_code: u16,
    zb_sequences_version: []const u8,
    duplicate: bool,
    trace_id: ?[]const u8 = null,
    span_id: []const u8 = "",
    command_id: ?[]const u8 = null,
    execution_id: ?[]const u8 = null,
    idempotency_key_hash: ?[]const u8 = null,
    duration_ms: u64 = 0,
    error_class: ?[]const u8 = null,
    error_code: ?[]const u8 = null,
    retryable: ?bool = null,
    retry_count: u32 = 0,
    org_id: ?[]const u8 = null,
    sequence_id: ?[]const u8 = null,
    client_id: ?[]const u8 = null,
    automation_api: []const u8 = "v1",
    tenant: ?[]const u8 = null,
    parent_span_id: ?[]const u8 = null,
    automation_trace_id: ?[]const u8 = null,
    external_run_id: ?[]const u8 = null,
    actor_user_id_hash: ?[]const u8 = null,
    session_id_hash: ?[]const u8 = null,
    zigbrowser_version: ?[]const u8 = null,
    redaction_suppressed: bool = false,
};

pub const Ev70Sink = struct {
    allocator: std.mem.Allocator,
    spans: std.ArrayListUnmanaged(Ev70Span),

    pub fn init(allocator: std.mem.Allocator) Ev70Sink {
        return .{ .allocator = allocator, .spans = .empty };
    }

    pub fn deinit(self: *Ev70Sink) void {
        for (self.spans.items) |span| {
            self.allocator.free(span.span_id);
            self.freeOptionals(.{
                span.trace_id,
                span.command_id,
                span.execution_id,
                span.idempotency_key_hash,
                span.error_class,
                span.error_code,
                span.org_id,
                span.sequence_id,
                span.client_id,
                span.tenant,
                span.parent_span_id,
                span.automation_trace_id,
                span.external_run_id,
                span.actor_user_id_hash,
                span.session_id_hash,
                span.zigbrowser_version,
            });
        }
        self.spans.deinit(self.allocator);
    }

    pub fn spanCount(self: *const Ev70Sink) usize {
        return self.spans.items.len;
    }

    fn freeOptionals(self: *Ev70Sink, optionals: anytype) void {
        inline for (optionals) |opt| {
            if (opt) |value| self.allocator.free(value);
        }
    }

    pub fn emit(self: *Ev70Sink, span: Ev70Span) void {
        const span_id = self.allocator.dupe(u8, span.span_id) catch return;
        const trace_id = dupeOptional(self.allocator, span.trace_id) catch return;
        const command_id = dupeOptional(self.allocator, span.command_id) catch return;
        const execution_id = dupeOptional(self.allocator, span.execution_id) catch return;
        const idempotency_key_hash = dupeOptional(self.allocator, span.idempotency_key_hash) catch return;
        const error_class = dupeOptional(self.allocator, span.error_class) catch return;
        const error_code = dupeOptional(self.allocator, span.error_code) catch return;
        const org_id = dupeOptional(self.allocator, span.org_id) catch return;
        const sequence_id = dupeOptional(self.allocator, span.sequence_id) catch return;
        const client_id = dupeOptional(self.allocator, span.client_id) catch return;
        const tenant = dupeOptional(self.allocator, span.tenant) catch return;
        const parent_span_id = dupeOptional(self.allocator, span.parent_span_id) catch return;
        const automation_trace_id = dupeOptional(self.allocator, span.automation_trace_id) catch return;
        const external_run_id = dupeOptional(self.allocator, span.external_run_id) catch return;
        const actor_user_id_hash = dupeOptional(self.allocator, span.actor_user_id_hash) catch return;
        const session_id_hash = dupeOptional(self.allocator, span.session_id_hash) catch return;
        const zigbrowser_version = dupeOptional(self.allocator, span.zigbrowser_version) catch return;

        self.spans.append(self.allocator, .{
            .name = span.name,
            .endpoint = span.endpoint,
            .http_method = span.http_method,
            .http_status_code = span.http_status_code,
            .zb_sequences_version = span.zb_sequences_version,
            .duplicate = span.duplicate,
            .trace_id = trace_id,
            .span_id = span_id,
            .command_id = command_id,
            .execution_id = execution_id,
            .idempotency_key_hash = idempotency_key_hash,
            .duration_ms = span.duration_ms,
            .error_class = error_class,
            .error_code = error_code,
            .retryable = span.retryable,
            .retry_count = span.retry_count,
            .org_id = org_id,
            .sequence_id = sequence_id,
            .client_id = client_id,
            .automation_api = span.automation_api,
            .tenant = tenant,
            .parent_span_id = parent_span_id,
            .automation_trace_id = automation_trace_id,
            .external_run_id = external_run_id,
            .actor_user_id_hash = actor_user_id_hash,
            .session_id_hash = session_id_hash,
            .zigbrowser_version = zigbrowser_version,
            .redaction_suppressed = span.redaction_suppressed,
        }) catch {
            self.allocator.free(span_id);
            self.freeOptionals(.{ trace_id, command_id, execution_id, idempotency_key_hash, error_class, error_code, org_id, sequence_id, client_id, tenant, parent_span_id, automation_trace_id, external_run_id, actor_user_id_hash, session_id_hash, zigbrowser_version });
        };
    }
};

fn extractHttpMethod(comptime template: []const u8) *const [methodLen(template)]u8 {
    return comptime template[0..methodLen(template)];
}

fn methodLen(comptime template: []const u8) comptime_int {
    return comptime std.mem.indexOfScalar(u8, template, ' ') orelse template.len;
}

pub const SequencesClient = struct {
    allocator: std.mem.Allocator,
    sink: *Ev70Sink,
    automation_client: ?*AutomationClient = null,
    trace_ctx: TraceContext = .{},
    client_config: ClientConfig = .{},
    span_counter: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, sink: *Ev70Sink) SequencesClient {
        return .{ .allocator = allocator, .sink = sink };
    }

    pub fn initWithClient(allocator: std.mem.Allocator, sink: *Ev70Sink, automation_client: *AutomationClient) SequencesClient {
        return .{ .allocator = allocator, .sink = sink, .automation_client = automation_client };
    }

    pub fn setTraceContext(self: *SequencesClient, ctx: TraceContext) void {
        self.trace_ctx = ctx;
    }

    pub fn setClientConfig(self: *SequencesClient, config: ClientConfig) void {
        self.client_config = config;
    }

    fn generateSpanId(self: *SequencesClient, buf: *[16]u8) []const u8 {
        self.span_counter += 1;
        const hex_chars = "0123456789abcdef";
        var val = self.span_counter;
        var i: usize = 16;
        while (i > 0) {
            i -= 1;
            buf[i] = hex_chars[@intCast(val & 0xf)];
            val >>= 4;
        }
        return buf[0..];
    }

    fn emitEv70(self: *SequencesClient, comptime endpoint: []const u8, result: CallResult, idempotency_key_hash: ?[]const u8) void {
        var span_id_buf: [16]u8 = undefined;
        self.sink.emit(.{
            .name = "zb_sequences.client_call",
            .endpoint = endpoint,
            .http_method = extractHttpMethod(endpoint),
            .http_status_code = result.status_code,
            .zb_sequences_version = version,
            .duplicate = result.duplicate,
            .trace_id = self.trace_ctx.trace_id,
            .span_id = self.generateSpanId(&span_id_buf),
            .command_id = self.trace_ctx.command_id,
            .execution_id = self.trace_ctx.execution_id,
            .idempotency_key_hash = idempotency_key_hash,
            .error_class = result.error_class,
            .error_code = result.error_code,
            .retryable = result.retryable,
            .org_id = self.trace_ctx.org_id,
            .sequence_id = self.trace_ctx.sequence_id,
            .client_id = self.client_config.client_id,
            .tenant = self.trace_ctx.tenant,
            .parent_span_id = self.trace_ctx.parent_span_id,
            .automation_trace_id = self.trace_ctx.automation_trace_id,
            .external_run_id = self.trace_ctx.external_run_id,
            .actor_user_id_hash = self.trace_ctx.actor_user_id_hash,
            .session_id_hash = self.trace_ctx.session_id_hash,
            .zigbrowser_version = self.client_config.zigbrowser_version,
        });
    }

    fn executeViaTransport(self: *SequencesClient, comptime endpoint: []const u8, idem: Idempotency) CallResult {
        const ac = self.automation_client orelse {
            return .{ .status_code = 0, .body = "", .duplicate = false };
        };
        comptime var method_end = 0;
        inline for (endpoint, 0..) |c, idx| {
            if (c == ' ') {
                method_end = idx;
                break;
            }
        }
        const path = comptime endpoint[method_end + 1 ..];
        const method: std.http.Method = comptime parseMethod(endpoint[0..method_end]);

        const outcome = ac.call(.{
            .method = method,
            .request_target = path,
            .hmac = .optional,
            .idempotency = idem,
        }) catch {
            return .{ .status_code = 0, .body = "", .duplicate = false };
        };
        switch (outcome) {
            .success => |s| return .{
                .status_code = s.status_code,
                .body = s.body,
                .duplicate = false,
                .owned_allocator = self.allocator,
            },
            .api_error => |e| {
                var err = e;
                defer err.deinit(self.allocator);
                const error_code = self.allocator.dupe(u8, err.code) catch null;
                return .{
                    .status_code = err.status_code,
                    .body = "",
                    .duplicate = false,
                    .owned_allocator = if (error_code != null) self.allocator else null,
                    .error_class = "api_error",
                    .error_code = error_code,
                    .retryable = err.retryable,
                };
            },
        }
    }

    fn callAndEmit(self: *SequencesClient, comptime endpoint: []const u8) CallResult {
        const result = self.executeViaTransport(endpoint, .none);
        self.emitEv70(endpoint, result, null);
        return result;
    }

    fn callAndEmitWithParams(self: *SequencesClient, comptime endpoint: []const u8, params: anytype) CallResult {
        const idem = extractIdempotency(params);
        const result = self.executeViaTransport(endpoint, idem);
        const idem_hash = extractIdempotencyKeyHash(params);
        self.emitEv70(endpoint, result, if (idem_hash) |*h| h else null);
        return result;
    }

    fn extractIdempotencyKeyHash(params: anytype) ?[canonical_hashing.prefixed_hash_len]u8 {
        const T = @TypeOf(params);
        if (@typeInfo(T) == .@"struct" and @hasField(T, "idempotency_key")) {
            const field = params.idempotency_key;
            switch (@typeInfo(@TypeOf(field))) {
                .optional => if (field) |key| return hashIdempotencyKey(key),
                else => return hashIdempotencyKey(field),
            }
        }
        return null;
    }

    fn hashIdempotencyKey(key: anytype) [canonical_hashing.prefixed_hash_len]u8 {
        var buf: [canonical_hashing.prefixed_hash_len]u8 = undefined;
        _ = canonical_hashing.h(&buf, key);
        return buf;
    }

    fn extractIdempotency(params: anytype) Idempotency {
        const T = @TypeOf(params);
        if (@typeInfo(T) == .@"struct" and @hasField(T, "idempotency_key")) {
            const field = params.idempotency_key;
            switch (@typeInfo(@TypeOf(field))) {
                .optional => if (field) |key| return .{ .key = key },
                else => return .{ .key = field },
            }
        }
        return .none;
    }

    fn parseMethod(comptime name: []const u8) std.http.Method {
        if (std.mem.eql(u8, name, "GET")) return .GET;
        if (std.mem.eql(u8, name, "POST")) return .POST;
        if (std.mem.eql(u8, name, "PUT")) return .PUT;
        if (std.mem.eql(u8, name, "PATCH")) return .PATCH;
        if (std.mem.eql(u8, name, "DELETE")) return .DELETE;
        @compileError("unsupported HTTP method: " ++ name);
    }

    pub fn getUiBootstrap(self: *SequencesClient, params: anytype) CallResult {
        _ = params;
        return self.callAndEmit(endpoint_templates.getUiBootstrap);
    }

    pub fn listSequences(self: *SequencesClient, params: anytype) CallResult {
        _ = params;
        return self.callAndEmit(endpoint_templates.listSequences);
    }

    pub fn createDraftSequence(self: *SequencesClient, params: anytype) CallResult {
        return self.callAndEmitWithParams(endpoint_templates.createDraftSequence, params);
    }

    pub fn getSequenceDetail(self: *SequencesClient, params: anytype) CallResult {
        _ = params;
        return self.callAndEmit(endpoint_templates.getSequenceDetail);
    }

    pub fn getSteps(self: *SequencesClient, params: anytype) CallResult {
        _ = params;
        return self.callAndEmit(endpoint_templates.getSteps);
    }

    pub fn saveSteps(self: *SequencesClient, params: anytype) CallResult {
        return self.callAndEmitWithParams(endpoint_templates.saveSteps, params);
    }

    pub fn generateStepDraft(self: *SequencesClient, params: anytype) CallResult {
        return self.callAndEmitWithParams(endpoint_templates.generateStepDraft, params);
    }

    pub fn previewStep(self: *SequencesClient, params: anytype) CallResult {
        return self.callAndEmitWithParams(endpoint_templates.previewStep, params);
    }

    pub fn getExecutionPlan(self: *SequencesClient, params: anytype) CallResult {
        _ = params;
        return self.callAndEmit(endpoint_templates.getExecutionPlan);
    }

    pub fn createExecution(self: *SequencesClient, params: anytype) CallResult {
        return self.callAndEmitWithParams(endpoint_templates.createExecution, params);
    }

    pub fn updateExecution(self: *SequencesClient, params: anytype) CallResult {
        return self.callAndEmitWithParams(endpoint_templates.updateExecution, params);
    }

    pub fn recordStepResult(self: *SequencesClient, params: anytype) CallResult {
        return self.callAndEmitWithParams(endpoint_templates.recordStepResult, params);
    }

    pub fn ingestEvents(self: *SequencesClient, params: anytype) CallResult {
        return self.callAndEmitWithParams(endpoint_templates.ingestEvents, params);
    }

    pub fn ingestTelemetry(self: *SequencesClient, params: anytype) CallResult {
        return self.callAndEmitWithParams(endpoint_templates.ingestTelemetry, params);
    }

    pub fn getOutreachAnalytics(self: *SequencesClient, params: anytype) CallResult {
        _ = params;
        return self.callAndEmit(endpoint_templates.getOutreachAnalytics);
    }
};
