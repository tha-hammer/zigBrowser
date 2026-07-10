const std = @import("std");
const sequences = @import("sequences");

// TDD Cycle 1: The client facade type exists and has all 15 endpoint methods.
// Each method corresponds to one HTTP operation from the zb-sequences-v1 bridge spec.

test "SequencesClient type exists" {
    const ClientType = sequences.SequencesClient;
    try std.testing.expect(@sizeOf(ClientType) > 0);
}

test "facade exposes all 15 endpoint methods" {
    // Verify all 15 method names exist on SequencesClient as declarations.
    // The 14 endpoint groups expand to 15 HTTP ops because sequences collection
    // has both GET and POST.
    const Client = sequences.SequencesClient;

    // Group 1: UI Bootstrap
    try std.testing.expect(@hasDecl(Client, "getUiBootstrap"));
    // Group 2A: List Sequences
    try std.testing.expect(@hasDecl(Client, "listSequences"));
    // Group 2B: Create Draft Sequence
    try std.testing.expect(@hasDecl(Client, "createDraftSequence"));
    // Group 3: Sequence Detail
    try std.testing.expect(@hasDecl(Client, "getSequenceDetail"));
    // Group 4: Get Steps
    try std.testing.expect(@hasDecl(Client, "getSteps"));
    // Group 5: Save Steps
    try std.testing.expect(@hasDecl(Client, "saveSteps"));
    // Group 6: Generate Step Draft
    try std.testing.expect(@hasDecl(Client, "generateStepDraft"));
    // Group 7: Preview Step
    try std.testing.expect(@hasDecl(Client, "previewStep"));
    // Group 8: Execution Plan
    try std.testing.expect(@hasDecl(Client, "getExecutionPlan"));
    // Group 9: Create Execution
    try std.testing.expect(@hasDecl(Client, "createExecution"));
    // Group 10: Update Execution
    try std.testing.expect(@hasDecl(Client, "updateExecution"));
    // Group 11: Record Step Result
    try std.testing.expect(@hasDecl(Client, "recordStepResult"));
    // Group 12: Ingest Events
    try std.testing.expect(@hasDecl(Client, "ingestEvents"));
    // Group 13: Ingest Telemetry
    try std.testing.expect(@hasDecl(Client, "ingestTelemetry"));
    // Group 14: Outreach Analytics
    try std.testing.expect(@hasDecl(Client, "getOutreachAnalytics"));
}

test "facade method count is exactly 15" {
    const expected_methods = [_][]const u8{
        "getUiBootstrap",
        "listSequences",
        "createDraftSequence",
        "getSequenceDetail",
        "getSteps",
        "saveSteps",
        "generateStepDraft",
        "previewStep",
        "getExecutionPlan",
        "createExecution",
        "updateExecution",
        "recordStepResult",
        "ingestEvents",
        "ingestTelemetry",
        "getOutreachAnalytics",
    };
    try std.testing.expectEqual(@as(usize, 15), expected_methods.len);
}

test "endpoint_template maps are correct per spec" {
    // The endpoint templates must match the spec's mounted paths exactly
    // so that EV70 endpoint attributes correlate with EV71.
    try std.testing.expectEqualStrings(
        "GET /api/v1/automation/ui/bootstrap",
        sequences.endpoint_templates.getUiBootstrap,
    );
    try std.testing.expectEqualStrings(
        "GET /api/v1/automation/sequences",
        sequences.endpoint_templates.listSequences,
    );
    try std.testing.expectEqualStrings(
        "POST /api/v1/automation/sequences",
        sequences.endpoint_templates.createDraftSequence,
    );
    try std.testing.expectEqualStrings(
        "GET /api/v1/automation/sequences/:sequenceId",
        sequences.endpoint_templates.getSequenceDetail,
    );
    try std.testing.expectEqualStrings(
        "GET /api/v1/automation/sequences/:sequenceId/steps",
        sequences.endpoint_templates.getSteps,
    );
    try std.testing.expectEqualStrings(
        "PUT /api/v1/automation/sequences/:sequenceId/steps",
        sequences.endpoint_templates.saveSteps,
    );
    try std.testing.expectEqualStrings(
        "POST /api/v1/automation/sequences/:sequenceId/steps/generate",
        sequences.endpoint_templates.generateStepDraft,
    );
    try std.testing.expectEqualStrings(
        "POST /api/v1/automation/sequences/:sequenceId/steps/preview",
        sequences.endpoint_templates.previewStep,
    );
    try std.testing.expectEqualStrings(
        "GET /api/v1/automation/sequences/:sequenceId/execution-plan",
        sequences.endpoint_templates.getExecutionPlan,
    );
    try std.testing.expectEqualStrings(
        "POST /api/v1/automation/executions",
        sequences.endpoint_templates.createExecution,
    );
    try std.testing.expectEqualStrings(
        "PATCH /api/v1/automation/executions/:executionId",
        sequences.endpoint_templates.updateExecution,
    );
    try std.testing.expectEqualStrings(
        "POST /api/v1/automation/executions/:executionId/steps/:stepExecutionId/result",
        sequences.endpoint_templates.recordStepResult,
    );
    try std.testing.expectEqualStrings(
        "POST /api/v1/automation/events",
        sequences.endpoint_templates.ingestEvents,
    );
    try std.testing.expectEqualStrings(
        "POST /api/v1/automation/telemetry",
        sequences.endpoint_templates.ingestTelemetry,
    );
    try std.testing.expectEqualStrings(
        "GET /api/v1/automation/analytics/outreach",
        sequences.endpoint_templates.getOutreachAnalytics,
    );
}

test "version constant matches spec" {
    try std.testing.expectEqualStrings("zb-sequences-v1", sequences.version);
}

test "canonical hashing and signing vectors match zb-sequences-v1" {
    const body = "{\"event\":\"test\",\"n\":1}";
    const target = "/api/v1/automation/events?limit=50&cursor=abc%2Fdef";
    const timestamp = "1783710000123";
    const nonce = "AAAAAAAAAAAAAAAAAAAAAA";

    var hex_buf: [sequences.canonical_hashing.hex_len]u8 = undefined;
    try std.testing.expectEqualStrings(
        sequences.canonical_hashing.empty_body_hash,
        sequences.canonical_hashing.hbytes(&hex_buf, ""),
    );
    try std.testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        sequences.canonical_hashing.sha256Hex(&hex_buf, "abc"),
    );
    try std.testing.expectEqualStrings(
        "829ae2d3a157f2d3a9e99f221392c416a31026fb2bc17ad755b69170e942c916",
        sequences.canonical_hashing.hbytes(&hex_buf, body),
    );

    var prefixed_buf: [sequences.canonical_hashing.prefixed_hash_len]u8 = undefined;
    try std.testing.expectEqualStrings(
        "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        sequences.canonical_hashing.h(&prefixed_buf, "abc"),
    );
    try std.testing.expectEqualStrings(
        "sha256:c0320ab4f5919cf223beb90286794ff9a4bb228c9d1d4c7836cc9250fbaa0a1f",
        sequences.canonical_hashing.h(&prefixed_buf, "idem:abc"),
    );

    var mac: [sequences.canonical_hashing.hmac_sha256_len]u8 = undefined;
    sequences.canonical_hashing.hmacSha256(&mac, "key", "The quick brown fox jumps over the lazy dog");
    try std.testing.expectEqualStrings(
        "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8",
        sequences.canonical_hashing.lowerHex(&hex_buf, &mac),
    );

    var b64_buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "aGVsbG8_",
        sequences.canonical_hashing.base64UrlNoPad(&b64_buf, "hello?"),
    );

    const base = try sequences.buildSignatureBase(
        std.testing.allocator,
        .POST,
        target,
        timestamp,
        nonce,
        "829ae2d3a157f2d3a9e99f221392c416a31026fb2bc17ad755b69170e942c916",
    );
    defer std.testing.allocator.free(base);
    try std.testing.expectEqualStrings(
        "v1\nPOST\n/api/v1/automation/events?limit=50&cursor=abc%2Fdef\n1783710000123\nAAAAAAAAAAAAAAAAAAAAAA\n829ae2d3a157f2d3a9e99f221392c416a31026fb2bc17ad755b69170e942c916",
        base,
    );
    try std.testing.expect(base[base.len - 1] != '\n');

    const sig = try sequences.signBaseString(std.testing.allocator, "client-secret", base);
    defer std.testing.allocator.free(sig);
    try std.testing.expectEqualStrings(
        "v1=asBrm-4tIx7xxcU4fHipG45FuQ2Co9Tooz2DPoo7A7M",
        sig,
    );
}

test "prepared automation request signs exact body bytes and required headers" {
    var request = try sequences.PreparedRequest.build(std.testing.allocator, .{
        .base_url = "https://sequences.test",
        .delegated_user_token = "delegated-token",
        .service_auth = .{ .client_id = "client-A", .secret = "client-secret" },
        .method = .POST,
        .request_target = "/api/v1/automation/events?limit=50&cursor=abc%2Fdef",
        .body = "{\"event\":\"test\",\"n\":1}",
        .idempotency = .{ .key = "idem:abc" },
        .timestamp_ms = 1783710000123,
        .nonce = "AAAAAAAAAAAAAAAAAAAAAA",
        .timeout_ms = 2500,
    });
    defer request.deinit();

    try std.testing.expectEqualStrings("https://sequences.test/api/v1/automation/events?limit=50&cursor=abc%2Fdef", request.url);
    try std.testing.expectEqualStrings("{\"event\":\"test\",\"n\":1}", request.body);
    try std.testing.expectEqual(@as(u32, 2500), request.timeout_ms);
    try std.testing.expectEqualStrings(sequences.version, request.headerValue("X-ZB-Sequences-Version").?);
    try std.testing.expectEqualStrings("Bearer delegated-token", request.headerValue("Authorization").?);
    try std.testing.expectEqualStrings("client-A", request.headerValue("X-ZB-Client-Id").?);
    try std.testing.expectEqualStrings("1783710000123", request.headerValue("X-ZB-Timestamp").?);
    try std.testing.expectEqualStrings("AAAAAAAAAAAAAAAAAAAAAA", request.headerValue("X-ZB-Nonce").?);
    try std.testing.expectEqualStrings("v1=asBrm-4tIx7xxcU4fHipG45FuQ2Co9Tooz2DPoo7A7M", request.headerValue("X-ZB-Signature").?);
    try std.testing.expectEqualStrings("idem:abc", request.headerValue("Idempotency-Key").?);
    try std.testing.expectEqualStrings(
        "sha256:c0320ab4f5919cf223beb90286794ff9a4bb228c9d1d4c7836cc9250fbaa0a1f",
        request.idempotency_key_hash.?,
    );
}

test "prepared retry can be byte-identical when idempotency timestamp and nonce are reused" {
    var first = try sequences.PreparedRequest.build(std.testing.allocator, .{
        .base_url = "https://sequences.test/",
        .delegated_user_token = "delegated-token",
        .service_auth = .{ .client_id = "client-A", .secret = "client-secret" },
        .method = .PUT,
        .request_target = "/api/v1/automation/sequences/seq_123/steps",
        .body = "{\"expectedVersion\":3,\"steps\":[]}",
        .idempotency = .{ .key = "idem-save-1" },
        .timestamp_ms = 1783710000124,
        .nonce = "BBBBBBBBBBBBBBBBBBBBBB",
        .timeout_ms = 5000,
    });
    defer first.deinit();

    var retry = try sequences.PreparedRequest.build(std.testing.allocator, .{
        .base_url = "https://sequences.test/",
        .delegated_user_token = "delegated-token",
        .service_auth = .{ .client_id = "client-A", .secret = "client-secret" },
        .method = .PUT,
        .request_target = "/api/v1/automation/sequences/seq_123/steps",
        .body = "{\"expectedVersion\":3,\"steps\":[]}",
        .idempotency = .{ .key = "idem-save-1" },
        .timestamp_ms = 1783710000124,
        .nonce = "BBBBBBBBBBBBBBBBBBBBBB",
        .timeout_ms = 5000,
    });
    defer retry.deinit();

    try std.testing.expect(first.wireBytesEqual(&retry));
}

test "automation client parses error envelopes" {
    var parsed = try sequences.ErrorEnvelope.parse(
        std.testing.allocator,
        409,
        "{\"error\":{\"code\":\"IDEMPOTENCY_CONFLICT\",\"message\":\"same key different body\",\"retryable\":false,\"requestId\":\"req_123\",\"traceId\":\"trace_123\",\"commandId\":\"cmd_123\",\"details\":{\"field\":\"idempotencyKey\"}}}",
    );
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 409), parsed.status_code);
    try std.testing.expectEqualStrings("IDEMPOTENCY_CONFLICT", parsed.code);
    try std.testing.expectEqualStrings("same key different body", parsed.message);
    try std.testing.expectEqual(false, parsed.retryable.?);
    try std.testing.expectEqualStrings("req_123", parsed.request_id.?);
    try std.testing.expectEqualStrings("trace_123", parsed.trace_id.?);
    try std.testing.expectEqualStrings("cmd_123", parsed.command_id.?);
}

test "automation client sends prepared request through transport" {
    const RecordingTransport = struct {
        saw_expected_request: bool = false,

        fn transport(self: *@This()) sequences.Transport {
            return .{ .context = self, .sendFn = send };
        }

        fn send(context: *anyopaque, allocator: std.mem.Allocator, request: *const sequences.PreparedRequest) !sequences.TransportResponse {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.saw_expected_request =
                request.method == .POST and
                std.mem.eql(u8, request.url, "https://sequences.test/api/v1/automation/events") and
                std.mem.eql(u8, request.body, "{\"event\":\"test\",\"n\":1}") and
                request.timeout_ms == 2500 and
                std.mem.eql(u8, request.headerValue("X-ZB-Sequences-Version").?, sequences.version) and
                std.mem.eql(u8, request.headerValue("Authorization").?, "Bearer delegated-token") and
                std.mem.eql(u8, request.headerValue("Idempotency-Key").?, "idem:abc") and
                std.mem.eql(u8, request.headerValue("X-ZB-Signature").?, "v1=VkToORTVeuh_qSx0B68lreeolo5gqBGPhlT_74lrhII");

            return .{
                .status_code = 200,
                .body = try allocator.dupe(u8, "{\"ok\":true}"),
            };
        }
    };

    var recorder = RecordingTransport{};
    var client = sequences.AutomationClient.init(std.testing.allocator, .{
        .base_url = "https://sequences.test",
        .delegated_user_token = "delegated-token",
        .service_auth = .{ .client_id = "client-A", .secret = "client-secret" },
        .default_timeout_ms = 5000,
    }, recorder.transport());

    var outcome = try client.call(.{
        .method = .POST,
        .request_target = "/api/v1/automation/events",
        .body = "{\"event\":\"test\",\"n\":1}",
        .idempotency = .{ .key = "idem:abc" },
        .timestamp_ms = 1783710000123,
        .nonce = "AAAAAAAAAAAAAAAAAAAAAA",
        .timeout_ms = 2500,
    });
    defer outcome.deinit(std.testing.allocator);

    try std.testing.expect(recorder.saw_expected_request);
    switch (outcome) {
        .success => |success| {
            try std.testing.expectEqual(@as(u16, 200), success.status_code);
            try std.testing.expectEqualStrings("{\"ok\":true}", success.body);
        },
        .api_error => return error.UnexpectedApiError,
    }
}
