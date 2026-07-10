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
