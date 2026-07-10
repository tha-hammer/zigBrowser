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

    fn transport(self: *MockTransport) sequences.Transport {
        return .{ .context = self, .sendFn = send };
    }

    fn send(context: *anyopaque, allocator: std.mem.Allocator, _: *const sequences.PreparedRequest) !sequences.TransportResponse {
        const self: *MockTransport = @ptrCast(@alignCast(context));
        self.call_count += 1;
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
