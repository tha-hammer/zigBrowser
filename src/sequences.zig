pub const version = "zb-sequences-v1";

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
};

pub const SequencesClient = struct {
    allocator: std.mem.Allocator,
    sink: *Ev70Sink,

    pub fn init(allocator: std.mem.Allocator, sink: *Ev70Sink) SequencesClient {
        return .{ .allocator = allocator, .sink = sink };
    }

    pub fn getUiBootstrap(self: *SequencesClient, params: anytype) CallResult {
        _ = self;
        _ = params;
        return .{ .status_code = 0, .body = "", .duplicate = false };
    }

    pub fn listSequences(self: *SequencesClient, params: anytype) CallResult {
        _ = self;
        _ = params;
        return .{ .status_code = 0, .body = "", .duplicate = false };
    }

    pub fn createDraftSequence(self: *SequencesClient, params: anytype) CallResult {
        _ = self;
        _ = params;
        return .{ .status_code = 0, .body = "", .duplicate = false };
    }

    pub fn getSequenceDetail(self: *SequencesClient, params: anytype) CallResult {
        _ = self;
        _ = params;
        return .{ .status_code = 0, .body = "", .duplicate = false };
    }

    pub fn getSteps(self: *SequencesClient, params: anytype) CallResult {
        _ = self;
        _ = params;
        return .{ .status_code = 0, .body = "", .duplicate = false };
    }

    pub fn saveSteps(self: *SequencesClient, params: anytype) CallResult {
        _ = self;
        _ = params;
        return .{ .status_code = 0, .body = "", .duplicate = false };
    }

    pub fn generateStepDraft(self: *SequencesClient, params: anytype) CallResult {
        _ = self;
        _ = params;
        return .{ .status_code = 0, .body = "", .duplicate = false };
    }

    pub fn previewStep(self: *SequencesClient, params: anytype) CallResult {
        _ = self;
        _ = params;
        return .{ .status_code = 0, .body = "", .duplicate = false };
    }

    pub fn getExecutionPlan(self: *SequencesClient, params: anytype) CallResult {
        _ = self;
        _ = params;
        return .{ .status_code = 0, .body = "", .duplicate = false };
    }

    pub fn createExecution(self: *SequencesClient, params: anytype) CallResult {
        _ = self;
        _ = params;
        return .{ .status_code = 0, .body = "", .duplicate = false };
    }

    pub fn updateExecution(self: *SequencesClient, params: anytype) CallResult {
        _ = self;
        _ = params;
        return .{ .status_code = 0, .body = "", .duplicate = false };
    }

    pub fn recordStepResult(self: *SequencesClient, params: anytype) CallResult {
        _ = self;
        _ = params;
        return .{ .status_code = 0, .body = "", .duplicate = false };
    }

    pub fn ingestEvents(self: *SequencesClient, params: anytype) CallResult {
        _ = self;
        _ = params;
        return .{ .status_code = 0, .body = "", .duplicate = false };
    }

    pub fn ingestTelemetry(self: *SequencesClient, params: anytype) CallResult {
        _ = self;
        _ = params;
        return .{ .status_code = 0, .body = "", .duplicate = false };
    }

    pub fn getOutreachAnalytics(self: *SequencesClient, params: anytype) CallResult {
        _ = self;
        _ = params;
        return .{ .status_code = 0, .body = "", .duplicate = false };
    }
};

pub const Ev70Sink = struct {
    allocator: std.mem.Allocator,
    spans: std.ArrayListUnmanaged(Ev70Span),

    pub fn init(allocator: std.mem.Allocator) Ev70Sink {
        return .{ .allocator = allocator, .spans = .empty };
    }

    pub fn deinit(self: *Ev70Sink) void {
        self.spans.deinit(self.allocator);
    }

    pub fn spanCount(self: *const Ev70Sink) usize {
        return self.spans.items.len;
    }
};

pub const Ev70Span = struct {
    name: []const u8,
    endpoint: []const u8,
    http_method: []const u8,
};

const std = @import("std");
