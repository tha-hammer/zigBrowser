const std = @import("std");

pub const DashboardIpcError = error{
    UnknownCommand,
    BadArgs,
};

pub fn dispatch(allocator: std.mem.Allocator, cmd: []const u8, args_json: []const u8) DashboardIpcError![]const u8 {
    if (std.mem.eql(u8, cmd, "dashboard.bootstrap")) {
        return mockBootstrap(allocator);
    }
    if (std.mem.eql(u8, cmd, "dashboard.sequences.list")) {
        return mockSequencesList(allocator);
    }
    if (std.mem.eql(u8, cmd, "dashboard.sequences.detail")) {
        return mockSequenceDetail(allocator, args_json);
    }
    if (std.mem.eql(u8, cmd, "dashboard.sequences.steps")) {
        return mockSequenceSteps(allocator, args_json);
    }
    if (std.mem.eql(u8, cmd, "dashboard.analytics.outreach")) {
        return mockAnalyticsOutreach(allocator);
    }
    if (std.mem.eql(u8, cmd, "dashboard.executions.create")) {
        return mockExecutionCreate(allocator, args_json);
    }
    if (std.mem.eql(u8, cmd, "dashboard.executions.update")) {
        return mockExecutionUpdate(allocator, args_json);
    }

    return error.UnknownCommand;
}

fn mockBootstrap(allocator: std.mem.Allocator) DashboardIpcError![]const u8 {
    return allocator.dupe(u8,
        \\{
        \\  "apiVersion": "zb-sequences-v1",
        \\  "actor": {
        \\    "userId": "usr_mock_001",
        \\    "orgId": "org_mock_001",
        \\    "roles": ["sequence_admin"]
        \\  },
        \\  "featureFlags": {
        \\    "sequenceCreation": true,
        \\    "stepAuthoring": true,
        \\    "automationExecution": true,
        \\    "analytics": true
        \\  },
        \\  "mailboxes": [
        \\    {
        \\      "mailboxConnectionId": "mbx_mock_001",
        \\      "provider": "gmail",
        \\      "status": "connected",
        \\      "dailyCapRemaining": 120
        \\    }
        \\  ],
        \\  "analyticsDefaults": {
        \\    "dateRangeDays": 30,
        \\    "groupBy": "week"
        \\  }
        \\}
    ) catch return error.BadArgs;
}

fn mockSequencesList(allocator: std.mem.Allocator) DashboardIpcError![]const u8 {
    return allocator.dupe(u8,
        \\{
        \\  "items": [
        \\    {
        \\      "sequenceId": "seq_mock_001",
        \\      "name": "Senior Backend Search",
        \\      "status": "active",
        \\      "ownerUserId": "usr_mock_001",
        \\      "jobId": "job_mock_001",
        \\      "workspaceSearchId": "ws_mock_001",
        \\      "createdAt": "2026-07-09T16:00:00.000Z",
        \\      "updatedAt": "2026-07-09T16:05:00.000Z",
        \\      "metrics": {
        \\        "profilesContacted": 42,
        \\        "openRate": 0.62,
        \\        "clickRate": 0.11,
        \\        "replyRate": 0.19,
        \\        "bounceRate": 0.02
        \\      },
        \\      "executionSummary": {
        \\        "dueSteps": 3,
        \\        "runningExecutions": 1,
        \\        "lastExecutionStatus": "running"
        \\      }
        \\    },
        \\    {
        \\      "sequenceId": "seq_mock_002",
        \\      "name": "Frontend React Outreach",
        \\      "status": "draft",
        \\      "ownerUserId": "usr_mock_001",
        \\      "jobId": "job_mock_002",
        \\      "workspaceSearchId": null,
        \\      "createdAt": "2026-07-10T10:00:00.000Z",
        \\      "updatedAt": "2026-07-10T10:00:00.000Z",
        \\      "metrics": {
        \\        "profilesContacted": 0,
        \\        "openRate": null,
        \\        "clickRate": null,
        \\        "replyRate": null,
        \\        "bounceRate": null
        \\      },
        \\      "executionSummary": {
        \\        "dueSteps": 0,
        \\        "runningExecutions": 0,
        \\        "lastExecutionStatus": null
        \\      }
        \\    }
        \\  ],
        \\  "nextCursor": null
        \\}
    ) catch return error.BadArgs;
}

fn mockSequenceDetail(allocator: std.mem.Allocator, args_json: []const u8) DashboardIpcError![]const u8 {
    _ = args_json;
    return allocator.dupe(u8,
        \\{
        \\  "sequence": {
        \\    "sequenceId": "seq_mock_001",
        \\    "name": "Senior Backend Search",
        \\    "status": "active",
        \\    "ownerUserId": "usr_mock_001",
        \\    "jobId": "job_mock_001",
        \\    "workspaceSearchId": "ws_mock_001",
        \\    "approvedAt": "2026-07-09T15:55:00.000Z"
        \\  },
        \\  "cohort": {
        \\    "included": 25,
        \\    "skipped": 3,
        \\    "preview": [
        \\      {
        \\        "enrollmentId": "enr_mock_001",
        \\        "candidateSource": "workspace",
        \\        "workspaceCandidateId": "wc_mock_001",
        \\        "contactStatus": "ready"
        \\      }
        \\    ]
        \\  },
        \\  "steps": [],
        \\  "metrics": null,
        \\  "executionSummary": null
        \\}
    ) catch return error.BadArgs;
}

fn mockSequenceSteps(allocator: std.mem.Allocator, args_json: []const u8) DashboardIpcError![]const u8 {
    _ = args_json;
    return allocator.dupe(u8,
        \\{
        \\  "sequenceId": "seq_mock_001",
        \\  "version": 3,
        \\  "steps": [
        \\    {
        \\      "stepId": "step_1",
        \\      "kind": "email",
        \\      "index": 0,
        \\      "replyMode": "stop_on_reply",
        \\      "waitBefore": null,
        \\      "senderMailboxId": "mbx_mock_001",
        \\      "subject": "Quick question about your backend work",
        \\      "body": "Hi {{first_name}}, I came across your profile and was impressed by your work...",
        \\      "tokens": ["first_name"],
        \\      "signatureId": null,
        \\      "includeUnsubscribe": true,
        \\      "groundingStatus": "grounded",
        \\      "evidenceMap": [],
        \\      "reviewQueue": [],
        \\      "status": "draft",
        \\      "messageId": "msg_mock_001"
        \\    },
        \\    {
        \\      "stepId": "step_2",
        \\      "kind": "wait",
        \\      "index": 1,
        \\      "duration": 3,
        \\      "unit": "days"
        \\    }
        \\  ]
        \\}
    ) catch return error.BadArgs;
}

fn mockAnalyticsOutreach(allocator: std.mem.Allocator) DashboardIpcError![]const u8 {
    return allocator.dupe(u8,
        \\{
        \\  "groupBy": "week",
        \\  "series": [
        \\    {
        \\      "bucketStart": "2026-06-29T00:00:00.000Z",
        \\      "profilesContacted": 18,
        \\      "openRate": 0.56,
        \\      "clickRate": 0.08,
        \\      "replyRate": 0.14,
        \\      "interestRate": 0.06,
        \\      "bounceRate": 0.03
        \\    },
        \\    {
        \\      "bucketStart": "2026-07-06T00:00:00.000Z",
        \\      "profilesContacted": 42,
        \\      "openRate": 0.62,
        \\      "clickRate": 0.11,
        \\      "replyRate": 0.19,
        \\      "interestRate": 0.07,
        \\      "bounceRate": 0.02
        \\    }
        \\  ],
        \\  "totals": {
        \\    "profilesContacted": 60,
        \\    "opens": 36,
        \\    "clicks": 6,
        \\    "replies": 10,
        \\    "interestedReplies": 4,
        \\    "bounces": 2
        \\  },
        \\  "diagnostics": {
        \\    "source": "sequence_events",
        \\    "telemetryIncluded": false
        \\  }
        \\}
    ) catch return error.BadArgs;
}

fn mockExecutionCreate(allocator: std.mem.Allocator, args_json: []const u8) DashboardIpcError![]const u8 {
    _ = args_json;
    return allocator.dupe(u8,
        \\{
        \\  "executionId": "aexec_mock_001",
        \\  "status": "running",
        \\  "duplicate": false,
        \\  "createdAt": "2026-07-10T12:00:00.000Z"
        \\}
    ) catch return error.BadArgs;
}

fn mockExecutionUpdate(allocator: std.mem.Allocator, args_json: []const u8) DashboardIpcError![]const u8 {
    _ = args_json;
    return allocator.dupe(u8,
        \\{
        \\  "executionId": "aexec_mock_001",
        \\  "status": "succeeded",
        \\  "updatedAt": "2026-07-10T12:05:00.000Z",
        \\  "duplicate": false
        \\}
    ) catch return error.BadArgs;
}
