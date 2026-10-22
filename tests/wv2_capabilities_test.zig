//! Windows plan WS2b.0 (rev 2.17, C5; rewritten rev 2.19): capability-table honesty.
//! `adapterCapabilities(.webview2)` (src/automation_platform.zig) declared `input = .cdp_input`
//! before either spike ran (WS2a.0 isolated world, WS2b.1 `isTrusted`). Until a recorded WS2b.1
//! run on the Win11 VM AND the Win10 box shows CDP input is trusted, the row is UNPROVEN, so the
//! production function must say so. The flip to `cdp_input` is allowed only by that recorded run.
//! The fake-backed `P3.1` test inside automation_platform.zig is a tripwire, not this proof.
//! The tag is compared by name so this file compiles against the pre-fix enum (no `.unproven`)
//! and fails at run time for the stated reason.
const std = @import("std");
const platform = @import("automation_platform");

test "WS2b.0 webview2 input mode is unproven until a recorded WS2b.1 isTrusted run" {
    const caps = platform.adapterCapabilities(.webview2);
    try std.testing.expectEqualStrings("unproven", @tagName(caps.input.mode));
}

test "WS2b.0 webkitgtk and wkwebview keep js_synthetic input" {
    try std.testing.expectEqualStrings("js_synthetic", @tagName(platform.adapterCapabilities(.webkitgtk).input.mode));
    try std.testing.expectEqualStrings("js_synthetic", @tagName(platform.adapterCapabilities(.wkwebview).input.mode));
}
