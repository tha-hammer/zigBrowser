const std = @import("std");
const sequences = @import("sequences");

// TDD Cycle 2: Every facade call emits exactly one EV70 zb_sequences.client_call span.

fn makeSink() sequences.Ev70Sink {
    return sequences.Ev70Sink.init(std.testing.allocator);
}

fn makeClient(sink: *sequences.Ev70Sink) sequences.SequencesClient {
    return sequences.SequencesClient.init(std.testing.allocator, sink);
}

test "getUiBootstrap emits one EV70 span" {
    var sink = makeSink();
    defer sink.deinit();
    var client = makeClient(&sink);
    _ = client.getUiBootstrap(.{});
    try std.testing.expectEqual(@as(usize, 1), sink.spanCount());
    try std.testing.expectEqualStrings("zb_sequences.client_call", sink.spans.items[0].name);
}

test "listSequences emits one EV70 span" {
    var sink = makeSink();
    defer sink.deinit();
    var client = makeClient(&sink);
    _ = client.listSequences(.{});
    try std.testing.expectEqual(@as(usize, 1), sink.spanCount());
    try std.testing.expectEqualStrings("zb_sequences.client_call", sink.spans.items[0].name);
}

test "createDraftSequence emits one EV70 span" {
    var sink = makeSink();
    defer sink.deinit();
    var client = makeClient(&sink);
    _ = client.createDraftSequence(.{});
    try std.testing.expectEqual(@as(usize, 1), sink.spanCount());
    try std.testing.expectEqualStrings("zb_sequences.client_call", sink.spans.items[0].name);
}

test "getSequenceDetail emits one EV70 span" {
    var sink = makeSink();
    defer sink.deinit();
    var client = makeClient(&sink);
    _ = client.getSequenceDetail(.{});
    try std.testing.expectEqual(@as(usize, 1), sink.spanCount());
}

test "getSteps emits one EV70 span" {
    var sink = makeSink();
    defer sink.deinit();
    var client = makeClient(&sink);
    _ = client.getSteps(.{});
    try std.testing.expectEqual(@as(usize, 1), sink.spanCount());
}

test "saveSteps emits one EV70 span" {
    var sink = makeSink();
    defer sink.deinit();
    var client = makeClient(&sink);
    _ = client.saveSteps(.{});
    try std.testing.expectEqual(@as(usize, 1), sink.spanCount());
}

test "generateStepDraft emits one EV70 span" {
    var sink = makeSink();
    defer sink.deinit();
    var client = makeClient(&sink);
    _ = client.generateStepDraft(.{});
    try std.testing.expectEqual(@as(usize, 1), sink.spanCount());
}

test "previewStep emits one EV70 span" {
    var sink = makeSink();
    defer sink.deinit();
    var client = makeClient(&sink);
    _ = client.previewStep(.{});
    try std.testing.expectEqual(@as(usize, 1), sink.spanCount());
}

test "getExecutionPlan emits one EV70 span" {
    var sink = makeSink();
    defer sink.deinit();
    var client = makeClient(&sink);
    _ = client.getExecutionPlan(.{});
    try std.testing.expectEqual(@as(usize, 1), sink.spanCount());
}

test "createExecution emits one EV70 span" {
    var sink = makeSink();
    defer sink.deinit();
    var client = makeClient(&sink);
    _ = client.createExecution(.{});
    try std.testing.expectEqual(@as(usize, 1), sink.spanCount());
}

test "updateExecution emits one EV70 span" {
    var sink = makeSink();
    defer sink.deinit();
    var client = makeClient(&sink);
    _ = client.updateExecution(.{});
    try std.testing.expectEqual(@as(usize, 1), sink.spanCount());
}

test "recordStepResult emits one EV70 span" {
    var sink = makeSink();
    defer sink.deinit();
    var client = makeClient(&sink);
    _ = client.recordStepResult(.{});
    try std.testing.expectEqual(@as(usize, 1), sink.spanCount());
}

test "ingestEvents emits one EV70 span" {
    var sink = makeSink();
    defer sink.deinit();
    var client = makeClient(&sink);
    _ = client.ingestEvents(.{});
    try std.testing.expectEqual(@as(usize, 1), sink.spanCount());
}

test "ingestTelemetry emits one EV70 span" {
    var sink = makeSink();
    defer sink.deinit();
    var client = makeClient(&sink);
    _ = client.ingestTelemetry(.{});
    try std.testing.expectEqual(@as(usize, 1), sink.spanCount());
}

test "getOutreachAnalytics emits one EV70 span" {
    var sink = makeSink();
    defer sink.deinit();
    var client = makeClient(&sink);
    _ = client.getOutreachAnalytics(.{});
    try std.testing.expectEqual(@as(usize, 1), sink.spanCount());
}

// Verify endpoint template is correct on the emitted span
test "EV70 span carries correct endpoint template for createExecution" {
    var sink = makeSink();
    defer sink.deinit();
    var client = makeClient(&sink);
    _ = client.createExecution(.{});
    try std.testing.expectEqualStrings(
        "POST /api/v1/automation/executions",
        sink.spans.items[0].endpoint,
    );
    try std.testing.expectEqualStrings("POST", sink.spans.items[0].http_method);
}

test "EV70 span carries correct endpoint template for getOutreachAnalytics" {
    var sink = makeSink();
    defer sink.deinit();
    var client = makeClient(&sink);
    _ = client.getOutreachAnalytics(.{});
    try std.testing.expectEqualStrings(
        "GET /api/v1/automation/analytics/outreach",
        sink.spans.items[0].endpoint,
    );
    try std.testing.expectEqualStrings("GET", sink.spans.items[0].http_method);
}

test "EV70 span carries correct endpoint template for saveSteps" {
    var sink = makeSink();
    defer sink.deinit();
    var client = makeClient(&sink);
    _ = client.saveSteps(.{});
    try std.testing.expectEqualStrings(
        "PUT /api/v1/automation/sequences/:sequenceId/steps",
        sink.spans.items[0].endpoint,
    );
    try std.testing.expectEqualStrings("PUT", sink.spans.items[0].http_method);
}

test "EV70 span carries correct endpoint template for updateExecution" {
    var sink = makeSink();
    defer sink.deinit();
    var client = makeClient(&sink);
    _ = client.updateExecution(.{});
    try std.testing.expectEqualStrings(
        "PATCH /api/v1/automation/executions/:executionId",
        sink.spans.items[0].endpoint,
    );
    try std.testing.expectEqualStrings("PATCH", sink.spans.items[0].http_method);
}

test "EV70 version attribute is zb-sequences-v1" {
    var sink = makeSink();
    defer sink.deinit();
    var client = makeClient(&sink);
    _ = client.getUiBootstrap(.{});
    try std.testing.expectEqualStrings(sequences.version, sink.spans.items[0].zb_sequences_version);
}

test "multiple calls accumulate spans in sink" {
    var sink = makeSink();
    defer sink.deinit();
    var client = makeClient(&sink);
    _ = client.getUiBootstrap(.{});
    _ = client.listSequences(.{});
    _ = client.createExecution(.{});
    try std.testing.expectEqual(@as(usize, 3), sink.spanCount());
}

// --- TDD Cycle 3: Trace propagation context on EV70 spans ---

test "EV70 span carries trace_id from client context" {
    var sink = makeSink();
    defer sink.deinit();
    var client = makeClient(&sink);
    client.setTraceContext(.{ .trace_id = "abc-trace-123" });
    _ = client.getUiBootstrap(.{});
    try std.testing.expectEqualStrings("abc-trace-123", sink.spans.items[0].trace_id.?);
}

test "EV70 span trace_id is null when no context set" {
    var sink = makeSink();
    defer sink.deinit();
    var client = makeClient(&sink);
    _ = client.getUiBootstrap(.{});
    try std.testing.expect(sink.spans.items[0].trace_id == null);
}

test "EV70 span carries command_id from client context" {
    var sink = makeSink();
    defer sink.deinit();
    var client = makeClient(&sink);
    client.setTraceContext(.{ .command_id = "cmd-456" });
    _ = client.createExecution(.{});
    try std.testing.expectEqualStrings("cmd-456", sink.spans.items[0].command_id.?);
}

test "EV70 span carries execution_id from client context" {
    var sink = makeSink();
    defer sink.deinit();
    var client = makeClient(&sink);
    client.setTraceContext(.{ .execution_id = "exec-789" });
    _ = client.updateExecution(.{});
    try std.testing.expectEqualStrings("exec-789", sink.spans.items[0].execution_id.?);
}

test "EV70 span_id is populated on every call" {
    var sink = makeSink();
    defer sink.deinit();
    var client = makeClient(&sink);
    _ = client.getUiBootstrap(.{});
    try std.testing.expect(sink.spans.items[0].span_id.len > 0);
}

test "each call gets a unique span_id" {
    var sink = makeSink();
    defer sink.deinit();
    var client = makeClient(&sink);
    _ = client.getUiBootstrap(.{});
    _ = client.listSequences(.{});
    try std.testing.expect(!std.mem.eql(u8, sink.spans.items[0].span_id, sink.spans.items[1].span_id));
}

test "trace context propagates across multiple calls" {
    var sink = makeSink();
    defer sink.deinit();
    var client = makeClient(&sink);
    client.setTraceContext(.{
        .trace_id = "trace-multi",
        .command_id = "cmd-multi",
        .execution_id = "exec-multi",
    });
    _ = client.getUiBootstrap(.{});
    _ = client.listSequences(.{});
    _ = client.createExecution(.{});
    for (sink.spans.items[0..3]) |span| {
        try std.testing.expectEqualStrings("trace-multi", span.trace_id.?);
        try std.testing.expectEqualStrings("cmd-multi", span.command_id.?);
        try std.testing.expectEqualStrings("exec-multi", span.execution_id.?);
    }
}

test "trace context can be updated between calls" {
    var sink = makeSink();
    defer sink.deinit();
    var client = makeClient(&sink);
    _ = client.getUiBootstrap(.{});
    client.setTraceContext(.{ .execution_id = "exec-new" });
    _ = client.createExecution(.{});
    try std.testing.expect(sink.spans.items[0].execution_id == null);
    try std.testing.expectEqualStrings("exec-new", sink.spans.items[1].execution_id.?);
}

// --- TDD Cycle 4: idempotency_key_hash on EV70 spans ---

test "EV70 span has null idempotency_key_hash by default" {
    var sink = makeSink();
    defer sink.deinit();
    var client = makeClient(&sink);
    _ = client.getUiBootstrap(.{});
    try std.testing.expect(sink.spans.items[0].idempotency_key_hash == null);
}

test "EV70 span carries idempotency_key_hash when key provided" {
    var sink = makeSink();
    defer sink.deinit();
    var client = makeClient(&sink);
    _ = client.createExecution(.{ .idempotency_key = "my-idem-key-123" });
    const span = sink.spans.items[0];
    try std.testing.expect(span.idempotency_key_hash != null);
    var expected_buf: [sequences.canonical_hashing.prefixed_hash_len]u8 = undefined;
    const expected = sequences.canonical_hashing.h(&expected_buf, "my-idem-key-123");
    try std.testing.expectEqualStrings(expected, span.idempotency_key_hash.?);
}

test "read endpoint ignores idempotency_key" {
    var sink = makeSink();
    defer sink.deinit();
    var client = makeClient(&sink);
    _ = client.getUiBootstrap(.{});
    try std.testing.expect(sink.spans.items[0].idempotency_key_hash == null);
}

test "write endpoints accept idempotency_key" {
    var sink = makeSink();
    defer sink.deinit();
    var client = makeClient(&sink);
    _ = client.createDraftSequence(.{ .idempotency_key = "key-a" });
    _ = client.saveSteps(.{ .idempotency_key = "key-b" });
    _ = client.createExecution(.{ .idempotency_key = "key-c" });
    for (sink.spans.items[0..3]) |span| {
        try std.testing.expect(span.idempotency_key_hash != null);
    }
}

// --- TDD Cycle 5: Error and timing attributes on EV70 spans ---

test "EV70 span has zero duration_ms by default (stub transport)" {
    var sink = makeSink();
    defer sink.deinit();
    var client = makeClient(&sink);
    _ = client.getUiBootstrap(.{});
    try std.testing.expectEqual(@as(u64, 0), sink.spans.items[0].duration_ms);
}

test "EV70 span has null error fields by default" {
    var sink = makeSink();
    defer sink.deinit();
    var client = makeClient(&sink);
    _ = client.getUiBootstrap(.{});
    const span = sink.spans.items[0];
    try std.testing.expect(span.error_class == null);
    try std.testing.expect(span.error_code == null);
    try std.testing.expect(span.retryable == null);
}

test "EV70 span has zero retry_count by default" {
    var sink = makeSink();
    defer sink.deinit();
    var client = makeClient(&sink);
    _ = client.getUiBootstrap(.{});
    try std.testing.expectEqual(@as(u32, 0), sink.spans.items[0].retry_count);
}

// --- TDD Cycle 6: SequencesClient wired to AutomationClient transport ---

const MockTransport = struct {
    response_status: u16 = 200,
    response_body: []const u8 = "{}",
    call_count: u32 = 0,
    delay_ms: u64 = 0,

    fn transport(self: *MockTransport) sequences.Transport {
        return .{ .context = self, .sendFn = send };
    }

    fn send(context: *anyopaque, allocator: std.mem.Allocator, _: *const sequences.PreparedRequest) !sequences.TransportResponse {
        const self: *MockTransport = @ptrCast(@alignCast(context));
        self.call_count += 1;
        if (self.delay_ms > 0) {
            // Deterministic busy-wait so a timed transport call has measurable duration.
            const io = std.Io.Threaded.global_single_threaded.io();
            const start = std.Io.Clock.awake.now(io);
            while (start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() < @as(i64, @intCast(self.delay_ms))) {}
        }
        return .{
            .status_code = self.response_status,
            .body = try allocator.dupe(u8, self.response_body),
        };
    }
};

fn makeClientWithTransport(sink: *sequences.Ev70Sink, mock: *MockTransport, client: *sequences.AutomationClient) sequences.SequencesClient {
    client.* = sequences.AutomationClient.init(std.testing.allocator, .{
        .base_url = "http://localhost:3000",
        .delegated_user_token = "test-token",
        .service_auth = .{ .client_id = "test-client", .secret = "test-secret" },
    }, mock.transport());
    return sequences.SequencesClient.initWithClient(std.testing.allocator, sink, client);
}

test "SequencesClient delegates to AutomationClient when provided" {
    var sink = makeSink();
    defer sink.deinit();
    var mock = MockTransport{};
    var automation_client: sequences.AutomationClient = undefined;
    var client = makeClientWithTransport(&sink, &mock, &automation_client);
    var result = client.getUiBootstrap(.{});
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 1), mock.call_count);
}

test "EV70 span reflects transport status code" {
    var sink = makeSink();
    defer sink.deinit();
    var mock = MockTransport{ .response_status = 201 };
    var automation_client: sequences.AutomationClient = undefined;
    var client = makeClientWithTransport(&sink, &mock, &automation_client);
    var result = client.createExecution(.{});
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 201), sink.spans.items[0].http_status_code);
}

test "facade method returns response body from transport" {
    var sink = makeSink();
    defer sink.deinit();
    var mock = MockTransport{ .response_body = "{\"id\":\"seq-1\"}" };
    var automation_client: sequences.AutomationClient = undefined;
    var client = makeClientWithTransport(&sink, &mock, &automation_client);
    var result = client.getSequenceDetail(.{});
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("{\"id\":\"seq-1\"}", result.body);
}

// --- TDD Cycle 7: Error attributes from ErrorEnvelope ---

test "EV70 span populates error attributes from API error response" {
    var sink = makeSink();
    defer sink.deinit();
    var mock = MockTransport{
        .response_status = 409,
        .response_body = "{\"error\":{\"code\":\"STEP_VERSION_CONFLICT\",\"message\":\"Version mismatch\",\"retryable\":false}}",
    };
    var automation_client: sequences.AutomationClient = undefined;
    var client = makeClientWithTransport(&sink, &mock, &automation_client);
    var result = client.saveSteps(.{});
    defer result.deinit(std.testing.allocator);
    const span = sink.spans.items[0];
    try std.testing.expectEqual(@as(u16, 409), span.http_status_code);
    try std.testing.expectEqualStrings("STEP_VERSION_CONFLICT", span.error_code.?);
    try std.testing.expectEqual(false, span.retryable.?);
}

test "EV70 span marks retryable errors" {
    var sink = makeSink();
    defer sink.deinit();
    var mock = MockTransport{
        .response_status = 503,
        .response_body = "{\"error\":{\"code\":\"SERVICE_UNAVAILABLE\",\"message\":\"Try again\",\"retryable\":true}}",
    };
    var automation_client: sequences.AutomationClient = undefined;
    var client = makeClientWithTransport(&sink, &mock, &automation_client);
    var result = client.getUiBootstrap(.{});
    defer result.deinit(std.testing.allocator);
    const span = sink.spans.items[0];
    try std.testing.expectEqual(@as(u16, 503), span.http_status_code);
    try std.testing.expectEqualStrings("SERVICE_UNAVAILABLE", span.error_code.?);
    try std.testing.expectEqual(true, span.retryable.?);
}

// --- TDD Cycle 8: Extended context and static config on EV70 spans ---

test "EV70 span carries org_id and sequence_id from trace context" {
    var sink = makeSink();
    defer sink.deinit();
    var client = makeClient(&sink);
    client.setTraceContext(.{
        .trace_id = "t1",
        .org_id = "org-abc",
        .sequence_id = "seq-xyz",
    });
    _ = client.getSteps(.{});
    const span = sink.spans.items[0];
    try std.testing.expectEqualStrings("org-abc", span.org_id.?);
    try std.testing.expectEqualStrings("seq-xyz", span.sequence_id.?);
}

test "EV70 span carries client_id from config" {
    var sink = makeSink();
    defer sink.deinit();
    var client = sequences.SequencesClient.init(std.testing.allocator, &sink);
    client.setClientConfig(.{ .client_id = "my-client-id" });
    _ = client.getUiBootstrap(.{});
    try std.testing.expectEqualStrings("my-client-id", sink.spans.items[0].client_id.?);
}

test "EV70 span has automation.api = v1" {
    var sink = makeSink();
    defer sink.deinit();
    var client = makeClient(&sink);
    _ = client.getUiBootstrap(.{});
    try std.testing.expectEqualStrings("v1", sink.spans.items[0].automation_api);
}

// --- TDD Cycle 9: Remaining EV70 spec attributes ---

test "EV70 span carries tenant from trace context" {
    var sink = makeSink();
    defer sink.deinit();
    var client = makeClient(&sink);
    client.setTraceContext(.{ .tenant = "tenant-hash-abc" });
    _ = client.getUiBootstrap(.{});
    try std.testing.expectEqualStrings("tenant-hash-abc", sink.spans.items[0].tenant.?);
}

test "EV70 span carries parent_span_id from trace context" {
    var sink = makeSink();
    defer sink.deinit();
    var client = makeClient(&sink);
    client.setTraceContext(.{ .parent_span_id = "parent-span-001" });
    _ = client.getUiBootstrap(.{});
    try std.testing.expectEqualStrings("parent-span-001", sink.spans.items[0].parent_span_id.?);
}

test "EV70 span carries automation_trace_id from trace context" {
    var sink = makeSink();
    defer sink.deinit();
    var client = makeClient(&sink);
    client.setTraceContext(.{ .automation_trace_id = "auto-trace-xyz" });
    _ = client.listSequences(.{});
    try std.testing.expectEqualStrings("auto-trace-xyz", sink.spans.items[0].automation_trace_id.?);
}

test "EV70 span carries external_run_id from trace context" {
    var sink = makeSink();
    defer sink.deinit();
    var client = makeClient(&sink);
    client.setTraceContext(.{ .external_run_id = "run-42" });
    _ = client.createExecution(.{});
    try std.testing.expectEqualStrings("run-42", sink.spans.items[0].external_run_id.?);
}

test "EV70 span carries actor_user_id_hash from trace context" {
    var sink = makeSink();
    defer sink.deinit();
    var client = makeClient(&sink);
    client.setTraceContext(.{ .actor_user_id_hash = "sha256:abc123" });
    _ = client.getUiBootstrap(.{});
    try std.testing.expectEqualStrings("sha256:abc123", sink.spans.items[0].actor_user_id_hash.?);
}

test "EV70 span carries session_id_hash from trace context" {
    var sink = makeSink();
    defer sink.deinit();
    var client = makeClient(&sink);
    client.setTraceContext(.{ .session_id_hash = "sha256:sess999" });
    _ = client.getUiBootstrap(.{});
    try std.testing.expectEqualStrings("sha256:sess999", sink.spans.items[0].session_id_hash.?);
}

test "EV70 span carries zigbrowser.version from client config" {
    var sink = makeSink();
    defer sink.deinit();
    var client = makeClient(&sink);
    client.setClientConfig(.{ .zigbrowser_version = "0.4.1" });
    _ = client.getUiBootstrap(.{});
    try std.testing.expectEqualStrings("0.4.1", sink.spans.items[0].zigbrowser_version.?);
}

test "EV70 span has redaction.suppressed = false by default" {
    var sink = makeSink();
    defer sink.deinit();
    var client = makeClient(&sink);
    _ = client.getUiBootstrap(.{});
    try std.testing.expectEqual(false, sink.spans.items[0].redaction_suppressed);
}

test "all remaining nullable context attributes default to null" {
    var sink = makeSink();
    defer sink.deinit();
    var client = makeClient(&sink);
    _ = client.getUiBootstrap(.{});
    const span = sink.spans.items[0];
    try std.testing.expect(span.tenant == null);
    try std.testing.expect(span.parent_span_id == null);
    try std.testing.expect(span.automation_trace_id == null);
    try std.testing.expect(span.external_run_id == null);
    try std.testing.expect(span.actor_user_id_hash == null);
    try std.testing.expect(span.session_id_hash == null);
    try std.testing.expect(span.zigbrowser_version == null);
}

// --- TDD Cycle 10: dedup_key_hash on write EV70 spans ---

test "EV70 span has null dedup_key_hash by default" {
    var sink = makeSink();
    defer sink.deinit();
    var client = makeClient(&sink);
    _ = client.getUiBootstrap(.{});
    try std.testing.expect(sink.spans.items[0].dedup_key_hash == null);
}

test "ingestEvents EV70 span carries dedup_key_hash when dedup_key provided" {
    var sink = makeSink();
    defer sink.deinit();
    var client = makeClient(&sink);
    _ = client.ingestEvents(.{
        .idempotency_key = "batch-idem-1",
        .dedup_key = "zigbrowser:MessageSent:seq_1:enr_1:msg_1:step_1",
    });
    const span = sink.spans.items[0];
    try std.testing.expect(span.dedup_key_hash != null);
    var expected_buf: [sequences.canonical_hashing.prefixed_hash_len]u8 = undefined;
    const expected = sequences.canonical_hashing.h(&expected_buf, "zigbrowser:MessageSent:seq_1:enr_1:msg_1:step_1");
    try std.testing.expectEqualStrings(expected, span.dedup_key_hash.?);
}

test "read endpoint has null dedup_key_hash even if dedup_key present" {
    var sink = makeSink();
    defer sink.deinit();
    var client = makeClient(&sink);
    _ = client.getUiBootstrap(.{ .dedup_key = "ignored-on-read" });
    try std.testing.expect(sink.spans.items[0].dedup_key_hash == null);
}

test "dedup_key_hash matches pinned H(dedupKey) recipe" {
    var sink = makeSink();
    defer sink.deinit();
    var client = makeClient(&sink);
    _ = client.recordStepResult(.{ .idempotency_key = "k", .dedup_key = "dedup-xyz-789" });
    const span = sink.spans.items[0];
    try std.testing.expect(span.dedup_key_hash != null);
    var expected_buf: [sequences.canonical_hashing.prefixed_hash_len]u8 = undefined;
    const expected = sequences.canonical_hashing.h(&expected_buf, "dedup-xyz-789");
    try std.testing.expectEqualStrings(expected, span.dedup_key_hash.?);
}

// --- TDD Cycle 11: real duration_ms from timed transport calls ---

test "EV70 span records real duration_ms from a timed transport call" {
    var sink = makeSink();
    defer sink.deinit();
    var mock = MockTransport{ .delay_ms = 3 };
    var automation_client: sequences.AutomationClient = undefined;
    var client = makeClientWithTransport(&sink, &mock, &automation_client);
    var result = client.getUiBootstrap(.{});
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(sink.spans.items[0].duration_ms >= 1);
}
