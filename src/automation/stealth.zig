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
    owned_strings: std.ArrayListUnmanaged([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TestTelemetrySink {
        return .{
            .events = .empty,
            .owned_strings = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TestTelemetrySink) void {
        for (self.events.items) |*event| {
            event.attrs.deinit();
        }
        for (self.owned_strings.items) |s| {
            self.allocator.free(s);
        }
        self.owned_strings.deinit(self.allocator);
        self.events.deinit(self.allocator);
    }

    pub fn dupeString(self: *TestTelemetrySink, src: []const u8) []const u8 {
        const s = self.allocator.dupe(u8, src) catch return "";
        self.owned_strings.append(self.allocator, s) catch {};
        return s;
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

pub const BehaviorKind = enum { typing, click, session };

pub const TypingDims = struct {
    profile_name: []const u8,
    distribution_name: []const u8,
    char_count: u32,
    delay_min_ms: f64,
    delay_max_ms: f64,
    delay_mean_ms: f64,
};

pub const ClickDims = struct {
    distance_px: f64,
    duration_ms: f64,
    overshoot_px: f64,
    dwell_ms: f64,
    input_mode: []const u8,
};

pub const SessionDims = struct {
    warmup_ms: u64,
    break_count: u32,
    session_elapsed_ms: u64,
    daily_remaining: u32,
};

pub const BehaviorEvent = struct {
    kind: BehaviorKind,
    typing: TypingDims = undefined,
    click: ClickDims = undefined,
    session: SessionDims = undefined,
};

pub fn emitBehaviorSimulation(
    sink: *TestTelemetrySink,
    event: BehaviorEvent,
    trace_id: []const u8,
    parent_span_id: []const u8,
) void {
    var attrs = sink.newAttrs();
    attrs.put("behavior.kind", @tagName(event.kind));

    switch (event.kind) {
        .typing => {
            attrs.put("profile.name", event.typing.profile_name);
            attrs.put("distribution.name", event.typing.distribution_name);
            attrs.put("char_count", "0");
            attrs.put("delay_min_ms", "0");
            attrs.put("delay_max_ms", "0");
            attrs.put("delay_mean_ms", "0");
        },
        .click => {
            attrs.put("distance_px", "0");
            attrs.put("duration_ms", "0");
            attrs.put("overshoot_px", "0");
            attrs.put("dwell_ms", "0");
            attrs.put("input.mode", event.click.input_mode);
        },
        .session => {
            attrs.put("warmup_ms", "0");
            attrs.put("break_count", "0");
            attrs.put("session_elapsed_ms", "0");
            attrs.put("daily.remaining", "0");
        },
    }

    sink.addEvent(
        .{ .trace_id = trace_id, .span_id = parent_span_id },
        "automation.behavior.simulation",
        attrs,
    );
}

pub const SignalSource = enum { dom, network, session, engine };

pub const DetectionSignal = struct {
    source: SignalSource,
    kind: []const u8,
    platform: []const u8,
    confidence: f64,
    raw_text: []const u8,
};

pub fn emitDetectionSignal(
    sink: *TestTelemetrySink,
    signal: DetectionSignal,
    trace_id: []const u8,
    parent_span_id: []const u8,
) void {
    var attrs = sink.newAttrs();
    attrs.put("signal.source", @tagName(signal.source));
    attrs.put("signal.kind", signal.kind);
    attrs.put("platform.name", signal.platform);
    attrs.put("confidence", "0.0");

    // Hash raw text — never emit raw (C48)
    const truncated = if (signal.raw_text.len > 200) signal.raw_text[0..200] else signal.raw_text;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(truncated);
    const digest = hasher.finalResult();
    const hex = std.fmt.bytesToHex(digest, .lower);
    const hash_str = sink.dupeString(&hex);
    attrs.put("dom.signal_hash", hash_str);

    sink.addEvent(
        .{ .trace_id = trace_id, .span_id = parent_span_id },
        "automation.detection.signal",
        attrs,
    );
}

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
