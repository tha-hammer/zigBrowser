const std = @import("std");
const stealth = @import("stealth");

test "stealth assessment emits event with required dimensions" {
    var sink = stealth.TestTelemetrySink.init(std.testing.allocator);
    defer sink.deinit();

    const assessment = stealth.StealthAssessment{
        .surface = .isolated_world,
        .risk_level = .none,
        .script_world = "zbAutomation",
        .observer_cleanup_count = 3,
        .prototype_modified = false,
    };

    stealth.emitStealthAssessment(&sink, assessment, "trace-123", "span-456");

    try std.testing.expectEqual(@as(usize, 1), sink.events.items.len);
    const event = sink.events.items[0];
    try std.testing.expectEqualStrings("automation.stealth.assessment", event.name);
    try std.testing.expect(event.attrs.contains("stealth.surface"));
    try std.testing.expect(event.attrs.contains("stealth.risk_level"));
    try std.testing.expect(event.attrs.contains("script.world"));
    try std.testing.expect(event.attrs.contains("observer.cleanup_count"));
    try std.testing.expect(event.attrs.contains("prototype.modified"));

    // C48 deny-list: forbidden keys must NOT be present
    try std.testing.expect(!event.attrs.contains("text"));
    try std.testing.expect(!event.attrs.contains("cookie"));
    try std.testing.expect(!event.attrs.contains("token"));
    try std.testing.expect(!event.attrs.contains("password"));
    try std.testing.expect(!event.attrs.contains("secret"));
    try std.testing.expect(!event.attrs.contains("selector"));
    try std.testing.expect(!event.attrs.contains("element.text"));

    // C47: trace propagation
    try std.testing.expectEqualStrings("trace-123", event.trace_id);
    try std.testing.expectEqualStrings("span-456", event.parent_span_id);
}

test "behavior simulation event contains required typing dimensions" {
    var sink = stealth.TestTelemetrySink.init(std.testing.allocator);
    defer sink.deinit();

    stealth.emitBehaviorSimulation(&sink, .{
        .kind = .typing,
        .typing = .{
            .profile_name = "default",
            .distribution_name = "gaussian",
            .char_count = 11,
            .delay_min_ms = 82,
            .delay_max_ms = 197,
            .delay_mean_ms = 121,
        },
    }, "trace-1", "span-1");

    try std.testing.expectEqual(@as(usize, 1), sink.events.items.len);
    const event = sink.events.items[0];
    try std.testing.expectEqualStrings("automation.behavior.simulation", event.name);
    try std.testing.expect(event.attrs.contains("behavior.kind"));
    try std.testing.expect(event.attrs.contains("char_count"));
    try std.testing.expect(event.attrs.contains("delay_mean_ms"));

    // Forbidden fields must NOT be present
    try std.testing.expect(!event.attrs.contains("text"));
    try std.testing.expect(!event.attrs.contains("value"));
    try std.testing.expect(!event.attrs.contains("message"));
}

test "behavior simulation event contains required click dimensions" {
    var sink = stealth.TestTelemetrySink.init(std.testing.allocator);
    defer sink.deinit();

    stealth.emitBehaviorSimulation(&sink, .{
        .kind = .click,
        .click = .{
            .distance_px = 447,
            .duration_ms = 320,
            .overshoot_px = 8,
            .dwell_ms = 95,
            .input_mode = "native",
        },
    }, "trace-2", "span-2");

    const event = sink.events.items[0];
    try std.testing.expect(event.attrs.contains("distance_px"));
    try std.testing.expect(event.attrs.contains("overshoot_px"));
    try std.testing.expect(event.attrs.contains("dwell_ms"));
    try std.testing.expect(!event.attrs.contains("selector"));
    try std.testing.expect(!event.attrs.contains("element.text"));
}

test "detection signal emits hashed DOM text, never raw text" {
    var sink = stealth.TestTelemetrySink.init(std.testing.allocator);
    defer sink.deinit();

    stealth.emitDetectionSignal(&sink, .{
        .source = .dom,
        .kind = "modal",
        .platform = "linkedin",
        .confidence = 0.9,
        .raw_text = "You've reached the weekly invitation limit",
    }, "trace-3", "span-3");

    try std.testing.expectEqual(@as(usize, 1), sink.events.items.len);
    const event = sink.events.items[0];
    try std.testing.expectEqualStrings("automation.detection.signal", event.name);
    try std.testing.expect(event.attrs.contains("signal.source"));
    try std.testing.expect(event.attrs.contains("signal.kind"));
    try std.testing.expect(event.attrs.contains("dom.signal_hash"));
    try std.testing.expect(event.attrs.contains("confidence"));

    // Raw text must NOT appear anywhere
    try std.testing.expect(!event.attrs.contains("text"));
    try std.testing.expect(!event.attrs.contains("raw_text"));
    try std.testing.expect(!event.attrs.containsValue("You've reached"));

    // Hash is deterministic and 64 hex chars (SHA-256)
    const hash = event.attrs.get("dom.signal_hash").?;
    try std.testing.expectEqual(@as(usize, 64), hash.len);

    // C47: trace propagation
    try std.testing.expectEqualStrings("trace-3", event.trace_id);
}

test "detection signal hash is deterministic" {
    var sink1 = stealth.TestTelemetrySink.init(std.testing.allocator);
    defer sink1.deinit();
    var sink2 = stealth.TestTelemetrySink.init(std.testing.allocator);
    defer sink2.deinit();

    const signal = stealth.DetectionSignal{
        .source = .dom,
        .kind = "modal",
        .platform = "linkedin",
        .confidence = 0.9,
        .raw_text = "limit reached",
    };

    stealth.emitDetectionSignal(&sink1, signal, "t", "s");
    stealth.emitDetectionSignal(&sink2, signal, "t", "s");

    const hash1 = sink1.events.items[0].attrs.get("dom.signal_hash").?;
    const hash2 = sink2.events.items[0].attrs.get("dom.signal_hash").?;
    try std.testing.expectEqualStrings(hash1, hash2);
}

test "telemetry fixture: stealth.assessment has all required dimensions" {
    var sink = stealth.TestTelemetrySink.init(std.testing.allocator);
    defer sink.deinit();

    inline for (std.meta.fields(stealth.DetectionSurface)) |field| {
        const surface: stealth.DetectionSurface = @enumFromInt(field.value);
        stealth.emitStealthAssessment(&sink, .{
            .surface = surface,
            .risk_level = .none,
            .script_world = "zbAutomation",
            .observer_cleanup_count = 0,
            .prototype_modified = false,
        }, "trace-fixture", "span-fixture");
    }

    const required_keys = [_][]const u8{
        "stealth.surface", "stealth.risk_level", "stealth.control",
    };
    for (sink.events.items) |event| {
        for (required_keys) |key| {
            try std.testing.expect(event.attrs.contains(key));
        }
    }
}

test "telemetry fixture: redaction scanner finds zero forbidden keys" {
    var sink = stealth.TestTelemetrySink.init(std.testing.allocator);
    defer sink.deinit();

    stealth.emitStealthAssessment(&sink, .{
        .surface = .isolated_world,
        .risk_level = .none,
        .script_world = "zbAutomation",
        .observer_cleanup_count = 0,
        .prototype_modified = false,
    }, "t", "s");
    stealth.emitBehaviorSimulation(&sink, .{
        .kind = .typing,
        .typing = .{
            .profile_name = "default",
            .distribution_name = "gaussian",
            .char_count = 5,
            .delay_min_ms = 80,
            .delay_max_ms = 200,
            .delay_mean_ms = 120,
        },
    }, "t", "s");
    stealth.emitDetectionSignal(&sink, .{
        .source = .dom,
        .kind = "modal",
        .platform = "linkedin",
        .confidence = 0.9,
        .raw_text = "limit reached",
    }, "t", "s");

    const forbidden = [_][]const u8{
        "cookie",  "token",          "password",
        "secret",  "bearer",         "text",
        "message", "value",          "raw_text",
        "screenshot", "dom_snapshot", "local_storage",
        "session_storage",
    };

    for (sink.events.items) |event| {
        for (forbidden) |key| {
            try std.testing.expect(!event.attrs.contains(key));
        }
    }
}
