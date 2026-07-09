const std = @import("std");

pub const DetectionSurface = enum {
    isolated_world,
    cdp_usage,
    extension_telltales,
    input_realism,
    timing_artifacts,
    rate_limiting,
};

pub const RiskLevel = enum { none, low, medium, high };

pub const StealthAssessment = struct {
    surface: DetectionSurface,
    risk_level: RiskLevel,
    script_world: []const u8,
    observer_cleanup_count: u32,
    prototype_modified: bool,
};

pub const TelemetryEvent = struct {
    name: []const u8,
    trace_id: []const u8,
    parent_span_id: []const u8,
    attrs: AttrMap,
};

pub const AttrMap = struct {
    entries: std.ArrayListUnmanaged(Entry),
    allocator: std.mem.Allocator,

    pub const Entry = struct {
        key: []const u8,
        value: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator) AttrMap {
        return .{ .entries = .empty, .allocator = allocator };
    }

    pub fn deinit(self: *AttrMap) void {
        self.entries.deinit(self.allocator);
    }

    pub fn put(self: *AttrMap, key: []const u8, value: []const u8) void {
        self.entries.append(self.allocator, .{ .key = key, .value = value }) catch {};
    }

    pub fn putBool(self: *AttrMap, key: []const u8, value: bool) void {
        self.entries.append(self.allocator, .{ .key = key, .value = if (value) "true" else "false" }) catch {};
    }

    pub fn contains(self: *const AttrMap, key: []const u8) bool {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.key, key)) return true;
        }
        return false;
    }

    pub fn get(self: *const AttrMap, key: []const u8) ?[]const u8 {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.key, key)) return entry.value;
        }
        return null;
    }

    pub fn containsValue(self: *const AttrMap, needle: []const u8) bool {
        for (self.entries.items) |entry| {
            if (std.mem.indexOf(u8, entry.value, needle) != null) return true;
        }
        return false;
    }
};

pub const TestTelemetrySink = struct {
    events: std.ArrayListUnmanaged(TelemetryEvent),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TestTelemetrySink {
        return .{
            .events = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TestTelemetrySink) void {
        for (self.events.items) |*event| {
            event.attrs.deinit();
        }
        self.events.deinit(self.allocator);
    }

    pub fn newAttrs(self: *TestTelemetrySink) AttrMap {
        return AttrMap.init(self.allocator);
    }

    pub fn addEvent(
        self: *TestTelemetrySink,
        span: struct { trace_id: []const u8, span_id: []const u8 },
        name: []const u8,
        attrs: AttrMap,
    ) void {
        self.events.append(self.allocator, .{
            .name = name,
            .trace_id = span.trace_id,
            .parent_span_id = span.span_id,
            .attrs = attrs,
        }) catch {};
    }
};

pub fn emitStealthAssessment(
    sink: *TestTelemetrySink,
    assessment: StealthAssessment,
    trace_id: []const u8,
    parent_span_id: []const u8,
) void {
    var attrs = sink.newAttrs();
    attrs.put("stealth.surface", @tagName(assessment.surface));
    attrs.put("stealth.risk_level", @tagName(assessment.risk_level));
    attrs.put("stealth.control", "observer_cleanup");
    attrs.put("script.world", assessment.script_world);
    attrs.put("observer.cleanup_count", "0");
    attrs.putBool("prototype.modified", assessment.prototype_modified);

    sink.addEvent(
        .{ .trace_id = trace_id, .span_id = parent_span_id },
        "automation.stealth.assessment",
        attrs,
    );
}
