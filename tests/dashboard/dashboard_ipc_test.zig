const std = @import("std");
const testing = std.testing;
const dashboard_ipc = @import("dashboard_ipc");

test "dispatch returns UnknownCommand for unknown dashboard commands" {
    const result = dashboard_ipc.dispatch(testing.allocator, "dashboard.nonexistent", "{}");
    try testing.expectError(error.UnknownCommand, result);
}

test "dispatch dashboard.bootstrap returns valid JSON with required fields" {
    const result = try dashboard_ipc.dispatch(testing.allocator, "dashboard.bootstrap", "{}");
    defer testing.allocator.free(result);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expect(obj.contains("apiVersion"));
    try testing.expect(obj.contains("actor"));
    try testing.expect(obj.contains("featureFlags"));
    try testing.expect(obj.contains("mailboxes"));
    try testing.expect(obj.contains("analyticsDefaults"));

    const api_version = obj.get("apiVersion").?.string;
    try testing.expectEqualStrings("zb-sequences-v1", api_version);
}

test "dispatch dashboard.bootstrap actor has required fields" {
    const result = try dashboard_ipc.dispatch(testing.allocator, "dashboard.bootstrap", "{}");
    defer testing.allocator.free(result);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result, .{});
    defer parsed.deinit();

    const actor = parsed.value.object.get("actor").?.object;
    try testing.expect(actor.contains("userId"));
    try testing.expect(actor.contains("orgId"));
    try testing.expect(actor.contains("roles"));
}

test "dispatch dashboard.bootstrap featureFlags has required fields" {
    const result = try dashboard_ipc.dispatch(testing.allocator, "dashboard.bootstrap", "{}");
    defer testing.allocator.free(result);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result, .{});
    defer parsed.deinit();

    const flags = parsed.value.object.get("featureFlags").?.object;
    try testing.expect(flags.contains("sequenceCreation"));
    try testing.expect(flags.contains("stepAuthoring"));
    try testing.expect(flags.contains("automationExecution"));
    try testing.expect(flags.contains("analytics"));
}

test "dispatch dashboard.sequences.list returns items and nextCursor" {
    const result = try dashboard_ipc.dispatch(testing.allocator, "dashboard.sequences.list", "{}");
    defer testing.allocator.free(result);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expect(obj.contains("items"));
    try testing.expect(obj.contains("nextCursor"));

    const items = obj.get("items").?.array;
    try testing.expect(items.items.len > 0);

    const first = items.items[0].object;
    try testing.expect(first.contains("sequenceId"));
    try testing.expect(first.contains("name"));
    try testing.expect(first.contains("status"));
    try testing.expect(first.contains("ownerUserId"));
    try testing.expect(first.contains("createdAt"));
    try testing.expect(first.contains("updatedAt"));
}

test "dispatch dashboard.analytics.outreach returns groupBy series totals diagnostics" {
    const result = try dashboard_ipc.dispatch(testing.allocator, "dashboard.analytics.outreach", "{}");
    defer testing.allocator.free(result);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expect(obj.contains("groupBy"));
    try testing.expect(obj.contains("series"));
    try testing.expect(obj.contains("totals"));
    try testing.expect(obj.contains("diagnostics"));

    const totals = obj.get("totals").?.object;
    try testing.expect(totals.contains("profilesContacted"));
    try testing.expect(totals.contains("opens"));
    try testing.expect(totals.contains("clicks"));
    try testing.expect(totals.contains("replies"));
    try testing.expect(totals.contains("bounces"));
}

test "dispatch dashboard.sequences.detail returns sequence object" {
    const args =
        \\{"sequenceId":"seq_mock_001"}
    ;
    const result = try dashboard_ipc.dispatch(testing.allocator, "dashboard.sequences.detail", args);
    defer testing.allocator.free(result);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expect(obj.contains("sequence"));

    const seq = obj.get("sequence").?.object;
    try testing.expect(seq.contains("sequenceId"));
    try testing.expect(seq.contains("name"));
    try testing.expect(seq.contains("status"));
    try testing.expect(seq.contains("ownerUserId"));
}

test "dispatch dashboard.sequences.steps returns version and steps array" {
    const args =
        \\{"sequenceId":"seq_mock_001"}
    ;
    const result = try dashboard_ipc.dispatch(testing.allocator, "dashboard.sequences.steps", args);
    defer testing.allocator.free(result);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expect(obj.contains("sequenceId"));
    try testing.expect(obj.contains("version"));
    try testing.expect(obj.contains("steps"));
}

test "dispatch dashboard.executions.create returns executionId and status" {
    const args =
        \\{"externalRunId":"zb_run_mock","sequenceId":"seq_mock_001"}
    ;
    const result = try dashboard_ipc.dispatch(testing.allocator, "dashboard.executions.create", args);
    defer testing.allocator.free(result);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expect(obj.contains("executionId"));
    try testing.expect(obj.contains("status"));
    try testing.expect(obj.contains("duplicate"));
}

test "dispatch dashboard.sequences.create returns sequenceId status cohortSummary" {
    const args =
        \\{"name":"Test Sequence","jobId":"job_mock_003"}
    ;
    const result = try dashboard_ipc.dispatch(testing.allocator, "dashboard.sequences.create", args);
    defer testing.allocator.free(result);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expect(obj.contains("sequenceId"));
    try testing.expect(obj.contains("status"));
    try testing.expect(obj.contains("createdAt"));
    try testing.expect(obj.contains("cohortSummary"));
    try testing.expect(obj.contains("duplicate"));

    const cohort = obj.get("cohortSummary").?.object;
    try testing.expect(cohort.contains("selected"));
    try testing.expect(cohort.contains("contactable"));
    try testing.expect(cohort.contains("missingContact"));
    try testing.expect(cohort.contains("suppressedOrDuplicate"));
    try testing.expect(cohort.contains("skipped"));

    try testing.expectEqualStrings("draft", obj.get("status").?.string);
}

test "dispatch dashboard.sequences.steps.save returns version and validation" {
    const args =
        \\{"sequenceId":"seq_mock_001","expectedVersion":3}
    ;
    const result = try dashboard_ipc.dispatch(testing.allocator, "dashboard.sequences.steps.save", args);
    defer testing.allocator.free(result);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expect(obj.contains("sequenceId"));
    try testing.expect(obj.contains("version"));
    try testing.expect(obj.contains("validation"));
    try testing.expect(obj.contains("steps"));
    try testing.expect(obj.contains("duplicate"));

    const validation = obj.get("validation").?.object;
    try testing.expect(validation.contains("status"));
    try testing.expect(validation.contains("warnings"));
}

test "dispatch dashboard.sequences.steps.generate returns generatedStep and generation" {
    const args =
        \\{"sequenceId":"seq_mock_001","requestId":"zb_gen_001"}
    ;
    const result = try dashboard_ipc.dispatch(testing.allocator, "dashboard.sequences.steps.generate", args);
    defer testing.allocator.free(result);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expect(obj.contains("requestId"));
    try testing.expect(obj.contains("sequenceId"));
    try testing.expect(obj.contains("enrollmentId"));
    try testing.expect(obj.contains("generatedStep"));
    try testing.expect(obj.contains("insertedAfterStepId"));
    try testing.expect(obj.contains("generation"));
    try testing.expect(obj.contains("duplicate"));

    const step = obj.get("generatedStep").?.object;
    try testing.expect(step.contains("stepId"));
    try testing.expect(step.contains("kind"));
    try testing.expect(step.contains("status"));
    try testing.expect(step.contains("groundingStatus"));
    try testing.expect(step.contains("generatedBy"));
    try testing.expectEqualStrings("ai", step.get("generatedBy").?.string);

    const gen = obj.get("generation").?.object;
    try testing.expect(gen.contains("groundingStatus"));
    try testing.expect(gen.contains("reviewQueue"));
    try testing.expect(gen.contains("evidenceMap"));
}

test "dispatch dashboard.sequences.steps.preview returns rendered and validation" {
    const args =
        \\{"sequenceId":"seq_mock_001","stepId":"step_1","enrollmentId":"enr_mock_001"}
    ;
    const result = try dashboard_ipc.dispatch(testing.allocator, "dashboard.sequences.steps.preview", args);
    defer testing.allocator.free(result);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expect(obj.contains("rendered"));
    try testing.expect(obj.contains("validation"));

    const rendered = obj.get("rendered").?.object;
    try testing.expect(rendered.contains("subject"));
    try testing.expect(rendered.contains("bodyPreview"));
    try testing.expect(rendered.contains("renderedHash"));

    const validation = obj.get("validation").?.object;
    try testing.expect(validation.contains("status"));
    try testing.expect(validation.contains("warnings"));
}

test "dispatch dashboard.executions.plan returns sequence pacingPolicy and steps" {
    const args =
        \\{"sequenceId":"seq_mock_001"}
    ;
    const result = try dashboard_ipc.dispatch(testing.allocator, "dashboard.executions.plan", args);
    defer testing.allocator.free(result);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expect(obj.contains("sequence"));
    try testing.expect(obj.contains("executionPlanId"));
    try testing.expect(obj.contains("generatedAt"));
    try testing.expect(obj.contains("pacingPolicy"));
    try testing.expect(obj.contains("steps"));

    const seq = obj.get("sequence").?.object;
    try testing.expect(seq.contains("sequenceId"));
    try testing.expect(seq.contains("status"));
    try testing.expect(seq.contains("approvedAt"));

    const pacing = obj.get("pacingPolicy").?.object;
    try testing.expect(pacing.contains("tenantDailyCapRemaining"));
    try testing.expect(pacing.contains("mailboxDailyCapRemaining"));
    try testing.expect(pacing.contains("minDelayMs"));
    try testing.expect(pacing.contains("maxDelayMs"));

    const steps = obj.get("steps").?.array;
    try testing.expect(steps.items.len > 0);
    const first_step = steps.items[0].object;
    try testing.expect(first_step.contains("stepExecutionId"));
    try testing.expect(first_step.contains("action"));
    try testing.expect(first_step.contains("candidate"));
    try testing.expect(first_step.contains("mailbox"));
    try testing.expect(first_step.contains("renderedMessage"));
    try testing.expect(first_step.contains("idempotencySeed"));
    try testing.expect(first_step.contains("requiredCanonicalEvent"));
}

test "dispatch dashboard.executions.stepResult returns canonicalEvent" {
    const args =
        \\{"executionId":"aexec_mock_001","stepExecutionId":"sexec_mock_001"}
    ;
    const result = try dashboard_ipc.dispatch(testing.allocator, "dashboard.executions.stepResult", args);
    defer testing.allocator.free(result);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expect(obj.contains("stepExecutionId"));
    try testing.expect(obj.contains("status"));
    try testing.expect(obj.contains("canonicalEvent"));
    try testing.expect(obj.contains("duplicate"));

    const evt = obj.get("canonicalEvent").?.object;
    try testing.expect(evt.contains("eventId"));
    try testing.expect(evt.contains("eventType"));
    try testing.expect(evt.contains("dedupKey"));
    try testing.expect(evt.contains("duplicate"));
    try testing.expectEqualStrings("MessageSent", evt.get("eventType").?.string);
}

test "dispatch dashboard.events.ingest returns results array" {
    const args =
        \\{"events":[]}
    ;
    const result = try dashboard_ipc.dispatch(testing.allocator, "dashboard.events.ingest", args);
    defer testing.allocator.free(result);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expect(obj.contains("results"));
    try testing.expect(obj.contains("duplicate"));

    const results = obj.get("results").?.array;
    try testing.expect(results.items.len == 2);

    const first = results.items[0].object;
    try testing.expect(first.contains("clientEventId"));
    try testing.expect(first.contains("status"));
    try testing.expect(first.contains("dedupKey"));
    try testing.expectEqualStrings("inserted", first.get("status").?.string);
}

test "dispatch dashboard.telemetry.ingest returns accepted rejected items" {
    const args =
        \\{"executionId":"aexec_mock_001","items":[]}
    ;
    const result = try dashboard_ipc.dispatch(testing.allocator, "dashboard.telemetry.ingest", args);
    defer testing.allocator.free(result);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expect(obj.contains("accepted"));
    try testing.expect(obj.contains("rejected"));
    try testing.expect(obj.contains("items"));
    try testing.expect(obj.contains("duplicate"));

    const items = obj.get("items").?.array;
    try testing.expect(items.items.len > 0);
    const first = items.items[0].object;
    try testing.expect(first.contains("index"));
    try testing.expect(first.contains("status"));
    try testing.expect(first.contains("diagnosticEventId"));
    try testing.expectEqualStrings("accepted", first.get("status").?.string);
}
