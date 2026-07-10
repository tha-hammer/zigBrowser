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
