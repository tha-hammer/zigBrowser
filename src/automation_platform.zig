const std = @import("std");

const testing = std.testing;

pub const BackendName = enum {
    webview2,
    webkitgtk,
    wkwebview,
};

pub const InputMode = enum {
    cdp_input,
    js_synthetic,
};

pub const NetworkSupport = enum {
    supported,
    unsupported,
};

pub const UnsupportedReason = enum {
    web_extension_required,
    no_platform_api,
};

pub const ResultStatus = enum {
    success,
    unsupported,
};

pub const InputCapability = struct {
    mode: InputMode,
};

pub const NetworkCapability = struct {
    support: NetworkSupport,
    unsupported_reason: ?UnsupportedReason = null,
};

pub const PlatformCapabilities = struct {
    input: InputCapability,
    network: NetworkCapability,
};

pub fn adapterCapabilities(backend: BackendName) PlatformCapabilities {
    return switch (backend) {
        .webview2 => .{
            .input = .{ .mode = .cdp_input },
            .network = .{ .support = .supported },
        },
        .webkitgtk => .{
            .input = .{ .mode = .js_synthetic },
            .network = .{
                .support = .unsupported,
                .unsupported_reason = .web_extension_required,
            },
        },
        .wkwebview => .{
            .input = .{ .mode = .js_synthetic },
            .network = .{
                .support = .unsupported,
                .unsupported_reason = .no_platform_api,
            },
        },
    };
}

pub const PlatformAdapter = struct {
    backend: BackendName,
    telemetry_sink: ?*InMemoryPlatformTelemetry = null,
    last_unsupported_reason: ?UnsupportedReason = null,

    pub fn init(backend: BackendName) PlatformAdapter {
        return .{ .backend = backend };
    }

    pub fn startNetwork(self: *PlatformAdapter, page_id: []const u8) !void {
        const caps = adapterCapabilities(self.backend);
        if (caps.network.support == .supported) {
            if (self.telemetry_sink) |sink| {
                sink.record(.{
                    .backend = self.backend,
                    .page_id = page_id,
                    .network_capability = .supported,
                    .result_status = .success,
                });
            }
            return;
        }

        self.last_unsupported_reason = caps.network.unsupported_reason.?;
        if (self.telemetry_sink) |sink| {
            sink.record(.{
                .backend = self.backend,
                .page_id = page_id,
                .network_capability = .unsupported,
                .unsupported_reason = caps.network.unsupported_reason,
                .result_status = .unsupported,
            });
        }
        return error.CapabilityUnsupported;
    }
};

pub const MouseAction = enum {
    move,
    down,
    up,
    click,
};

pub const MouseInput = struct {
    action: MouseAction,
    x: f64,
    y: f64,
    button: ?[]const u8 = null,
    trial: bool = false,
};

pub const KeyAction = enum {
    down,
    up,
    type,
};

pub const KeyInput = struct {
    action: KeyAction,
    key: []const u8,
    text: ?[]const u8 = null,
    trial: bool = false,
};

pub const FakeWebView2Cdp = struct {
    methods: [16][]const u8 = undefined,
    call_count: usize = 0,

    pub fn call(self: *FakeWebView2Cdp, method: []const u8) !void {
        if (self.call_count >= self.methods.len) return error.TooManyCdpCalls;
        self.methods[self.call_count] = method;
        self.call_count += 1;
    }

    pub fn called(self: *const FakeWebView2Cdp, method: []const u8) bool {
        for (self.methods[0..self.call_count]) |recorded| {
            if (std.mem.eql(u8, recorded, method)) return true;
        }
        return false;
    }
};

pub const WebView2InputDispatcher = struct {
    cdp: *FakeWebView2Cdp,

    pub fn init(cdp: *FakeWebView2Cdp) WebView2InputDispatcher {
        return .{ .cdp = cdp };
    }

    pub fn dispatchMouse(self: *WebView2InputDispatcher, input: MouseInput) !void {
        if (input.trial) return;
        _ = input.action;
        _ = input.x;
        _ = input.y;
        _ = input.button;
        try self.cdp.call("Input.dispatchMouseEvent");
    }

    pub fn dispatchKey(self: *WebView2InputDispatcher, input: KeyInput) !void {
        if (input.trial) return;
        _ = input.action;
        _ = input.key;
        _ = input.text;
        try self.cdp.call("Input.dispatchKeyEvent");
    }
};

pub const PlatformSpan = struct {
    name: []const u8 = "automation.network.capability",
    backend: BackendName = .webkitgtk,
    page_id: []const u8 = "",
    network_capability: NetworkSupport = .unsupported,
    unsupported_reason: ?UnsupportedReason = null,
    result_status: ResultStatus = .unsupported,
};

pub const InMemoryPlatformTelemetry = struct {
    count: usize = 0,
    last_span: PlatformSpan = .{},

    pub fn init() InMemoryPlatformTelemetry {
        return .{};
    }

    pub fn record(self: *InMemoryPlatformTelemetry, span: PlatformSpan) void {
        self.count += 1;
        self.last_span = span;
    }
};

test "P3.1 platform capability names are explicit per backend" {
    const webview2 = adapterCapabilities(.webview2);
    try testing.expectEqual(InputMode.cdp_input, webview2.input.mode);
    try testing.expectEqual(NetworkSupport.supported, webview2.network.support);

    const gtk = adapterCapabilities(.webkitgtk);
    try testing.expectEqual(InputMode.js_synthetic, gtk.input.mode);
    try testing.expectEqual(NetworkSupport.unsupported, gtk.network.support);
    try testing.expectEqual(UnsupportedReason.web_extension_required, gtk.network.unsupported_reason.?);

    const wk = adapterCapabilities(.wkwebview);
    try testing.expectEqual(InputMode.js_synthetic, wk.input.mode);
    try testing.expectEqual(NetworkSupport.unsupported, wk.network.support);
    try testing.expectEqual(UnsupportedReason.no_platform_api, wk.network.unsupported_reason.?);
}

test "P3.1 unsupported network start returns typed capability error" {
    var adapter = PlatformAdapter.init(.webkitgtk);
    try testing.expectError(error.CapabilityUnsupported, adapter.startNetwork("page-1"));
    try testing.expect(adapter.last_unsupported_reason == .web_extension_required);
}

test "P3.1 unsupported network capability emits telemetry instead of silent success" {
    var sink = InMemoryPlatformTelemetry.init();
    var adapter = PlatformAdapter.init(.wkwebview);
    adapter.telemetry_sink = &sink;

    try testing.expectError(error.CapabilityUnsupported, adapter.startNetwork("page-42"));

    try testing.expectEqual(@as(usize, 1), sink.count);
    try testing.expectEqualStrings("automation.network.capability", sink.last_span.name);
    try testing.expectEqual(BackendName.wkwebview, sink.last_span.backend);
    try testing.expectEqual(NetworkSupport.unsupported, sink.last_span.network_capability);
    try testing.expectEqual(UnsupportedReason.no_platform_api, sink.last_span.unsupported_reason.?);
    try testing.expectEqual(ResultStatus.unsupported, sink.last_span.result_status);
    try testing.expectEqualStrings("page-42", sink.last_span.page_id);
}

test "P3.2 WebView2 CDP input dispatch records Input.dispatchMouseEvent and Input.dispatchKeyEvent" {
    var cdp = FakeWebView2Cdp{};
    var dispatcher = WebView2InputDispatcher.init(&cdp);

    try dispatcher.dispatchMouse(.{
        .action = .click,
        .x = 10,
        .y = 20,
        .button = "left",
    });
    try dispatcher.dispatchKey(.{
        .action = .type,
        .key = "A",
        .text = "A",
    });

    try testing.expectEqual(@as(usize, 2), cdp.call_count);
    try testing.expectEqualStrings("Input.dispatchMouseEvent", cdp.methods[0]);
    try testing.expectEqualStrings("Input.dispatchKeyEvent", cdp.methods[1]);
    try testing.expect(!cdp.called("Runtime.enable"));
}

test "P3.2 WebView2 input trial mode emits no native dispatch call" {
    var cdp = FakeWebView2Cdp{};
    var dispatcher = WebView2InputDispatcher.init(&cdp);

    try dispatcher.dispatchMouse(.{
        .action = .click,
        .x = 10,
        .y = 20,
        .button = "left",
        .trial = true,
    });

    try testing.expectEqual(@as(usize, 0), cdp.call_count);
}
