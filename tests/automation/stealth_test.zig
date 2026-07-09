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
