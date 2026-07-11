const std = @import("std");
const sequences = @import("sequences");

const default_base_url = "http://127.0.0.1:3017";
const default_client_id = "zb-smoke-2026";
const default_client_secret = "zb-smoke-secret-2026-DEV-ONLY";
const default_delegated_token = "zb-smoke-dev-token";

const sequence_id = "00000000-0000-0000-0000-00000000c101";
const enrollment_id = "00000000-0000-0000-0000-00000000e101";
const message_id = "00000000-0000-0000-0000-00000000a101";
const sender_user_id = "00000000-0000-0000-0000-000000000001";
const mailbox_id = "00000000-0000-0000-0000-00000000b101";

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    const base_url = envOrDefault(init, "ZB_SMOKE_BASE_URL", default_base_url);
    const client_id = envOrDefault(init, "ZB_SMOKE_CLIENT_ID", default_client_id);
    const client_secret = envOrDefault(init, "ZB_SMOKE_CLIENT_SECRET", default_client_secret);
    const delegated_token = envOrDefault(init, "ZB_SMOKE_DELEGATED_TOKEN", default_delegated_token);

    const now_ms = currentUnixMillis();
    const idempotency_key = try std.fmt.allocPrint(allocator, "zb-smoke-2026-idem-{d}", .{now_ms});
    defer allocator.free(idempotency_key);
    const dedup_key = try std.fmt.allocPrint(
        allocator,
        "zigbrowser:MessageSent:{s}:{s}:{s}:smoke-{d}",
        .{ sequence_id, enrollment_id, message_id, now_ms },
    );
    defer allocator.free(dedup_key);
    const nonce = try std.fmt.allocPrint(allocator, "zb-smoke-nonce-{d}", .{now_ms});
    defer allocator.free(nonce);

    var idem_hash_buf: [sequences.canonical_hashing.prefixed_hash_len]u8 = undefined;
    const idempotency_key_hash = sequences.canonical_hashing.h(&idem_hash_buf, idempotency_key);
    var dedup_hash_buf: [sequences.canonical_hashing.prefixed_hash_len]u8 = undefined;
    const dedup_key_hash = sequences.canonical_hashing.h(&dedup_hash_buf, dedup_key);

    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"events\":[{{\"clientEventId\":\"zb_evt_smoke_2026\",\"kind\":\"canonical_sequence_event\",\"eventType\":\"MessageSent\",\"sequenceId\":\"{s}\",\"enrollmentId\":\"{s}\",\"messageId\":\"{s}\",\"occurredAt\":\"2026-07-11T12:00:00.000Z\",\"dedupKey\":\"{s}\",\"payload\":{{\"message_id\":\"{s}\",\"sent_at\":\"2026-07-11T12:00:00.000Z\",\"sender_mailbox_connection_id\":\"{s}\",\"sender_user_id\":\"{s}\",\"rendered_subject\":\"Smoke test\",\"rendered_body_hash\":\"sha256:1111111111111111111111111111111111111111111111111111111111111111\",\"rendered_body_snapshot\":\"Smoke body redacted fixture\",\"provider_message_id\":\"provider_msg_smoke_2026\",\"provider_thread_id\":\"provider_thread_smoke_2026\",\"automation\":{{\"traceId\":\"zb_trace_smoke_2026\",\"commandId\":\"zb_cmd_smoke_2026\"}}}}}}]}}",
        .{ sequence_id, enrollment_id, message_id, dedup_key, message_id, mailbox_id, sender_user_id },
    );
    defer allocator.free(body);

    var request = try sequences.PreparedRequest.build(allocator, .{
        .base_url = base_url,
        .delegated_user_token = delegated_token,
        .service_auth = .{ .client_id = client_id, .secret = client_secret },
        .method = .POST,
        .request_target = "/api/v1/automation/events",
        .body = body,
        .idempotency = .{ .key = idempotency_key },
        .timestamp_ms = now_ms,
        .nonce = nonce,
        .timeout_ms = 5000,
    });
    defer request.deinit();

    var http_client = std.http.Client{ .allocator = allocator, .io = init.io };
    defer http_client.deinit();
    var transport_impl = sequences.StdHttpTransport{ .client = &http_client };
    var response = transport_impl.transport().send(allocator, &request) catch |err| {
        var out_buffer: [4096]u8 = undefined;
        var out_writer: std.Io.File.Writer = .init(.stdout(), init.io, &out_buffer);
        try printPrepared(&out_writer.interface, request, idempotency_key, idempotency_key_hash, dedup_key, dedup_key_hash);
        try out_writer.interface.flush();
        var err_buffer: [1024]u8 = undefined;
        var err_writer: std.Io.File.Writer = .init(.stderr(), init.io, &err_buffer);
        try err_writer.interface.print("transport_error={s}\n", .{@errorName(err)});
        try err_writer.interface.flush();
        return err;
    };
    defer response.deinit(allocator);

    const parsed = try parseAutomationError(allocator, response.status_code, response.body);
    defer parsed.deinit(allocator);

    var sink = sequences.Ev70Sink.init(allocator);
    defer sink.deinit();
    sink.emit(.{
        .name = "zb_sequences.client_call",
        .endpoint = sequences.endpoint_templates.ingestEvents,
        .http_method = "POST",
        .http_status_code = response.status_code,
        .zb_sequences_version = sequences.version,
        .duplicate = false,
        .trace_id = "zb_trace_smoke_2026",
        .span_id = "0000000000000001",
        .command_id = "zb_cmd_smoke_2026",
        .idempotency_key_hash = idempotency_key_hash,
        .error_class = if (response.status_code >= 400) "api_error" else null,
        .error_code = parsed.code,
        .retryable = parsed.retryable,
        .client_id = client_id,
        .automation_trace_id = "zb_trace_smoke_2026",
        .zigbrowser_version = "zigBrowser-smoke",
    });

    var out_buffer: [16 * 1024]u8 = undefined;
    var out_writer: std.Io.File.Writer = .init(.stdout(), init.io, &out_buffer);
    const out = &out_writer.interface;
    try printPrepared(out, request, idempotency_key, idempotency_key_hash, dedup_key, dedup_key_hash);
    try out.print("http_status={d}\n", .{response.status_code});
    if (parsed.code) |code| try out.print("error_code={s}\n", .{code});
    if (parsed.message) |message| try out.print("error_message={s}\n", .{message});
    if (parsed.retryable) |retryable| try out.print("retryable={}\n", .{retryable});
    try out.print("response_body={s}\n", .{response.body});
    if (sink.spans.items.len > 0) {
        const span = sink.spans.items[0];
        try out.print("ev70.name={s}\n", .{span.name});
        try out.print("ev70.endpoint={s}\n", .{span.endpoint});
        try out.print("ev70.http_status_code={d}\n", .{span.http_status_code});
        try out.print("ev70.idempotency_key_hash={s}\n", .{span.idempotency_key_hash orelse ""});
        try out.print("ev70.dedup_key_hash=<not representable in current Ev70Span>; computed={s}\n", .{dedup_key_hash});
    }
    try out.flush();
}

fn envOrDefault(init: std.process.Init, name: []const u8, default: []const u8) []const u8 {
    return init.environ_map.get(name) orelse default;
}

fn currentUnixMillis() i64 {
    return std.Io.Clock.real.now(std.Io.Threaded.global_single_threaded.io()).toMilliseconds();
}

fn printPrepared(
    out: anytype,
    request: sequences.PreparedRequest,
    idempotency_key: []const u8,
    idempotency_key_hash: []const u8,
    dedup_key: []const u8,
    dedup_key_hash: []const u8,
) !void {
    try out.print("endpoint=POST /api/v1/automation/events\n", .{});
    try out.print("url={s}\n", .{request.url});
    try out.print("body_hash={s}\n", .{request.body_hash});
    try out.print("idempotency_key={s}\n", .{idempotency_key});
    try out.print("idempotency_key_hash={s}\n", .{idempotency_key_hash});
    try out.print("dedup_key={s}\n", .{dedup_key});
    try out.print("dedup_key_hash={s}\n", .{dedup_key_hash});
    try out.print("signature_base={s}\n", .{request.signature_base orelse ""});
}

const ParsedError = struct {
    code: ?[]u8 = null,
    message: ?[]u8 = null,
    retryable: ?bool = null,

    fn deinit(self: ParsedError, allocator: std.mem.Allocator) void {
        if (self.code) |value| allocator.free(value);
        if (self.message) |value| allocator.free(value);
    }
};

fn parseAutomationError(allocator: std.mem.Allocator, status_code: u16, body: []const u8) !ParsedError {
    if (status_code < 400 or body.len == 0) return .{};
    const Wire = struct {
        @"error": struct {
            code: ?[]const u8 = null,
            message: ?[]const u8 = null,
            retryable: ?bool = null,
        },
    };
    var parsed = std.json.parseFromSlice(Wire, allocator, body, .{ .ignore_unknown_fields = true }) catch return .{};
    defer parsed.deinit();
    return .{
        .code = if (parsed.value.@"error".code) |code| try allocator.dupe(u8, code) else null,
        .message = if (parsed.value.@"error".message) |message| try allocator.dupe(u8, message) else null,
        .retryable = parsed.value.@"error".retryable,
    };
}
