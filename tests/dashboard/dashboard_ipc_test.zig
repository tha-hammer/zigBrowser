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
