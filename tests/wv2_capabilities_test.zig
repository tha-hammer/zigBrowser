//! Windows plan WS2b.0 (rev 2.17, C5; rewritten rev 2.19): capability-table honesty.
//! `adapterCapabilities(.webview2)` (src/automation_platform.zig) declared `input = .cdp_input`
//! before either spike ran (WS2a.0 isolated world, WS2b.1 `isTrusted`). Until a recorded WS2b.1
//! run on the Win11 VM AND the Win10 box shows CDP input is trusted, the row is UNPROVEN, so the
//! production function must say so. The flip to `cdp_input` is allowed only by that recorded run.
//! The row also declared `network = .supported` with only a fake adapter behind it
//! (zigBrowser-ong.7): it is `unproven` too.
//! The `capabilities` RPC (orchestrator decision (a)) answers `capabilitiesJson(running_backend)`;
//! the webview2 JSON row is driven here because the Linux e2e (tests/e2e/capabilities_rpc_test.py)
//! can only reach the webkitgtk row.
//! The fake-backed `P3.1` test inside automation_platform.zig is a tripwire, not this proof.
//! Tags are compared by name and `capabilitiesJson` is looked up with @hasDecl, so this file
//! compiles against the pre-fix module and fails at run time for the stated reason.
const std = @import("std");
const platform = @import("automation_platform");

const has_json = @hasDecl(platform, "capabilitiesJson");

test "WS2b.0 webview2 input mode is unproven until a recorded WS2b.1 isTrusted run" {
    const caps = platform.adapterCapabilities(.webview2);
    try std.testing.expectEqualStrings("unproven", @tagName(caps.input.mode));
}

test "WS2b.0 webview2 network support is unproven (zigBrowser-ong.7)" {
    const caps = platform.adapterCapabilities(.webview2);
    try std.testing.expectEqualStrings("unproven", @tagName(caps.network.support));
}

test "WS2b.0 the capabilities RPC row for webview2 reports both unproven" {
    if (!has_json) return error.CapabilitiesJsonMissing;
    const json = try platform.capabilitiesJson(std.testing.allocator, .webview2);
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings(
        "{\"backend\":\"webview2\",\"input\":{\"mode\":\"unproven\"},\"network\":{\"support\":\"unproven\"}}",
        json,
    );
}

test "WS2b.0 webkitgtk and wkwebview keep their input and network rows" {
    const gtk = platform.adapterCapabilities(.webkitgtk);
    try std.testing.expectEqualStrings("js_synthetic", @tagName(gtk.input.mode));
    try std.testing.expectEqualStrings("unsupported", @tagName(gtk.network.support));
    try std.testing.expectEqualStrings("web_extension_required", @tagName(gtk.network.unsupported_reason.?));
    const wk = platform.adapterCapabilities(.wkwebview);
    try std.testing.expectEqualStrings("js_synthetic", @tagName(wk.input.mode));
    try std.testing.expectEqualStrings("unsupported", @tagName(wk.network.support));
    try std.testing.expectEqualStrings("no_platform_api", @tagName(wk.network.unsupported_reason.?));
}
