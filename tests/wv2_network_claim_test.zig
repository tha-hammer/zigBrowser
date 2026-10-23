//! zigBrowser-ong.7 (NavyCanyon c9862e91): the WebView2 network interceptor may not claim more than the one
//! capability table. `adapterCapabilities(.webview2).network` (src/automation_platform.zig) is `.unproven` until a
//! recorded Windows network-capture run exists (WS2b.0, 90d2214), and the capabilities RPC and the production gate
//! `PlatformAdapter.startNetwork` follow it. `WebView2NetworkInterceptor`, backed only by
//! `FakeWebView2NetworkAdapter`, must report that same record from `capability()` and in both telemetry spans it
//! writes (the capability span from `start()`, the event span from a non-dropping `capturePlatformEvent`).
//! The portable fake-backed queue, redaction, drop and idempotence behavior is not this test's subject.
const std = @import("std");
const platform = @import("automation_platform");
const testing = std.testing;

const capability_span = "automation.network.capability";
const event_span = "automation.network.event";

test "ong.7 the WebView2 interceptor's capability is the whole table record, which is unproven" {
    const table = platform.adapterCapabilities(.webview2).network;
    try testing.expectEqual(platform.NetworkSupport.unproven, table.support);

    var fake = platform.FakeWebView2NetworkAdapter{};
    const interceptor = platform.WebView2NetworkInterceptor.init(&fake, "page-ong7");
    const claimed = interceptor.capability();
    try testing.expectEqual(table.support, claimed.support);
    try testing.expectEqual(table.unsupported_reason, claimed.unsupported_reason);
    try testing.expectEqual(table, claimed);
}

test "ong.7 both WebView2 interceptor spans record the table's network capability" {
    const table = platform.adapterCapabilities(.webview2).network;
    var fake = platform.FakeWebView2NetworkAdapter{};
    var telemetry = platform.InMemoryPlatformTelemetry.init();
    var interceptor = platform.WebView2NetworkInterceptor.init(&fake, "page-ong7");
    interceptor.telemetry_sink = &telemetry;

    try interceptor.start();
    try interceptor.capturePlatformEvent(.{
        .request_id = "request-ong7",
        .url = "https://example.test/ong7",
        .method = .GET,
        .status_code = 200,
        .resource_kind = .fetch,
    });
    try testing.expectEqual(@as(usize, 0), interceptor.drop_count);
    try testing.expectEqual(@as(usize, 2), telemetry.count);

    var capability_spans: usize = 0;
    var event_spans: usize = 0;
    for (telemetry.spans[0..telemetry.count]) |span| {
        if (std.mem.eql(u8, span.name, capability_span)) {
            capability_spans += 1;
        } else if (std.mem.eql(u8, span.name, event_span)) {
            event_spans += 1;
        } else {
            std.debug.print("unexpected span {s}\n", .{span.name});
            return error.UnexpectedSpan;
        }
        try testing.expectEqual(platform.BackendName.webview2, span.backend);
        try testing.expectEqual(table.support, span.network_capability);
        try testing.expectEqual(platform.NetworkSupport.unproven, span.network_capability);
    }
    try testing.expectEqual(@as(usize, 1), capability_spans);
    try testing.expectEqual(@as(usize, 1), event_spans);
}

test "ong.7 the capability span (start) records the table's network capability" {
    const table = platform.adapterCapabilities(.webview2).network;
    var fake = platform.FakeWebView2NetworkAdapter{};
    var telemetry = platform.InMemoryPlatformTelemetry.init();
    var interceptor = platform.WebView2NetworkInterceptor.init(&fake, "page-ong7");
    interceptor.telemetry_sink = &telemetry;
    try interceptor.start();
    try testing.expectEqual(@as(usize, 1), telemetry.count);
    try testing.expectEqualStrings(capability_span, telemetry.spans[0].name);
    try testing.expectEqual(table.support, telemetry.spans[0].network_capability);
    try testing.expectEqual(platform.NetworkSupport.unproven, telemetry.spans[0].network_capability);
}

test "ong.7 the event span (non-dropping capture) records the table's network capability" {
    const table = platform.adapterCapabilities(.webview2).network;
    var fake = platform.FakeWebView2NetworkAdapter{};
    var telemetry = platform.InMemoryPlatformTelemetry.init();
    var interceptor = platform.WebView2NetworkInterceptor.init(&fake, "page-ong7");
    try interceptor.start(); // no sink yet: only the event span is recorded below
    interceptor.telemetry_sink = &telemetry;
    try interceptor.capturePlatformEvent(.{
        .request_id = "request-ong7-event",
        .url = "https://example.test/ong7-event",
        .method = .POST,
        .status_code = 201,
        .resource_kind = .fetch,
    });
    try testing.expectEqual(@as(usize, 1), telemetry.count);
    try testing.expectEqualStrings(event_span, telemetry.spans[0].name);
    try testing.expectEqual(table.support, telemetry.spans[0].network_capability);
    try testing.expectEqual(platform.NetworkSupport.unproven, telemetry.spans[0].network_capability);
}
