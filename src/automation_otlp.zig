const std = @import("std");

const testing = std.testing;

pub const TelemetryExportDiagnostic = enum {
    invalid_endpoint,
    export_failed,
};

pub const AutomationTelemetryExportConfig = struct {
    enabled: bool = false,
    endpoint: ?[]const u8 = null,
    diagnostic: ?TelemetryExportDiagnostic = null,

    pub fn fromEndpoint(endpoint: ?[]const u8) AutomationTelemetryExportConfig {
        const value = endpoint orelse return .{};
        if (!std.mem.startsWith(u8, value, "http://") and !std.mem.startsWith(u8, value, "https://")) {
            return .{ .diagnostic = .invalid_endpoint };
        }
        return .{
            .enabled = true,
            .endpoint = value,
        };
    }
};

pub const TransportSpan = struct {
    name: []const u8,
    trace_id: []const u8,
    span_id: []const u8,
    command_id: ?[]const u8 = null,
    raw_token: ?[]const u8 = null,
    raw_params: ?[]const u8 = null,
};

pub const FakeOtlpExporter = struct {
    mode: Mode,
    export_count: usize = 0,
    last_payload: ?[]u8 = null,
    last_diagnostic: ?TelemetryExportDiagnostic = null,

    pub const Mode = enum {
        success,
        fail,
    };

    pub fn init(mode: Mode) FakeOtlpExporter {
        return .{ .mode = mode };
    }

    fn exportPayload(self: *FakeOtlpExporter, payload: []u8) !void {
        self.export_count += 1;
        switch (self.mode) {
            .success => self.last_payload = payload,
            .fail => {
                self.last_diagnostic = .export_failed;
                return error.ExportFailed;
            },
        }
    }
};

pub fn exportSpanRedacted(
    allocator: std.mem.Allocator,
    exporter: *FakeOtlpExporter,
    span: TransportSpan,
) !void {
    _ = span.raw_token;
    _ = span.raw_params;
    const command_id = span.command_id orelse "";
    const payload = try std.fmt.allocPrint(
        allocator,
        "{{\"name\":\"{s}\",\"trace_id\":\"{s}\",\"span_id\":\"{s}\",\"command_id\":\"{s}\"}}",
        .{ span.name, span.trace_id, span.span_id, command_id },
    );
    errdefer allocator.free(payload);

    try exporter.exportPayload(payload);
}

pub fn commandResultWithTelemetry(
    allocator: std.mem.Allocator,
    exporter: *FakeOtlpExporter,
    span: TransportSpan,
    command_result: []const u8,
) ![]u8 {
    exportSpanRedacted(allocator, exporter, span) catch {};
    return allocator.dupe(u8, command_result);
}

test "P2.5 OTLP export config is disabled by default" {
    const config = AutomationTelemetryExportConfig.fromEndpoint(null);
    try testing.expect(!config.enabled);
    try testing.expect(config.endpoint == null);
}

test "P2.5 OTLP export config enables explicit endpoint and rejects invalid endpoint" {
    const enabled = AutomationTelemetryExportConfig.fromEndpoint("http://127.0.0.1:4318/v1/traces");
    try testing.expect(enabled.enabled);
    try testing.expectEqualStrings("http://127.0.0.1:4318/v1/traces", enabled.endpoint.?);

    const invalid = AutomationTelemetryExportConfig.fromEndpoint("file:///tmp/traces");
    try testing.expect(!invalid.enabled);
    try testing.expectEqual(TelemetryExportDiagnostic.invalid_endpoint, invalid.diagnostic.?);
}

test "P2.5 fake OTLP exporter redacts denylisted fields before export" {
    var exporter = FakeOtlpExporter.init(.success);
    const span = TransportSpan{
        .name = "automation.transport.request",
        .trace_id = "trace-1",
        .span_id = "span-1",
        .command_id = "command-1",
        .raw_token = "secret-token",
        .raw_params = "{\"selector\":\"#password\",\"text\":\"hunter2\"}",
    };

    try exportSpanRedacted(testing.allocator, &exporter, span);

    try testing.expectEqual(@as(usize, 1), exporter.export_count);
    try testing.expect(exporter.last_payload != null);
    defer testing.allocator.free(exporter.last_payload.?);
    try testing.expect(std.mem.indexOf(u8, exporter.last_payload.?, "automation.transport.request") != null);
    try testing.expect(std.mem.indexOf(u8, exporter.last_payload.?, "trace-1") != null);
    try testing.expect(std.mem.indexOf(u8, exporter.last_payload.?, "command-1") != null);
    try testing.expect(std.mem.indexOf(u8, exporter.last_payload.?, "secret-token") == null);
    try testing.expect(std.mem.indexOf(u8, exporter.last_payload.?, "hunter2") == null);
    try testing.expect(std.mem.indexOf(u8, exporter.last_payload.?, "#password") == null);
}

test "P2.5 exporter failure is isolated from command result" {
    var exporter = FakeOtlpExporter.init(.fail);
    const span = TransportSpan{
        .name = "automation.transport.response",
        .trace_id = "trace-2",
        .span_id = "span-2",
        .command_id = "command-2",
    };

    const result = try commandResultWithTelemetry(testing.allocator, &exporter, span, "ok");
    defer testing.allocator.free(result);

    try testing.expectEqualStrings("ok", result);
    try testing.expectEqual(@as(usize, 1), exporter.export_count);
    try testing.expectEqual(TelemetryExportDiagnostic.export_failed, exporter.last_diagnostic.?);
}
