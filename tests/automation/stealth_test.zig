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
