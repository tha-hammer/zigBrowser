//! The WS3.2 `.windows` config-apply arm. It validates a present flag/value through the shared,
//! all-OS decision (`backend_flag.backendFlagDecision(.windows, …)`) FIRST, then applies a supported
//! value through the WebView2 shim's C setters; an unsupported flag/value returns `error.UnsupportedFlag`
//! so `app.zig` prints `zigBrowser: --<flag>=<value> is not supported on Windows` and exits nonzero,
//! never touching the C ABI (WS3 coordination, Windows plan rev 2.4).
//!
//! The setters are the shared cross-backend ABI (declared in `webkit_shim.h`); on Windows they are
//! defined by `webview2_shim.cpp` (BlackRobin's shim pre-slice): `zb_app_set_media_source` installs /
//! omits the document-start user script that deletes `MediaSource`/`SourceBuffer`;
//! `zb_app_set_hw_policy` maps to the environment's `AdditionalBrowserArguments` (`--disable-gpu` for
//! `never`); `zb_app_set_profile_dir` sets the user-data folder. Until that shim lands,
//! `cross-check-ws3-win` is RED (these symbols are undefined in the Windows object and absent from
//! `webview2_shim.cpp`).
const std = @import("std");
const builtin = @import("builtin");
const backend_flag = @import("backend_flag.zig");
const render_config = @import("render_config.zig");
const media_config = @import("media_config.zig");

const c = @cImport({
    @cInclude("webkit_shim.h");
});

pub const supported = builtin.os.tag == .windows;
pub const Error = error{UnsupportedFlag};

/// Apply one PRESENT command-line flag on Windows, or refuse it. Validation is the shared decision;
/// only a supported value reaches a C setter.
pub fn applyWindowsFlag(flag: []const u8, value: []const u8) Error!void {
    if (backend_flag.backendFlagDecision(.windows, flag, value) == .refuse) return error.UnsupportedFlag;
    if (std.mem.eql(u8, flag, "media-source")) {
        const ms = media_config.parse(value).?; // non-null: validated by the decision above
        c.zb_app_set_media_source(@as(c_int, @intFromBool(ms == .on)));
    } else if (std.mem.eql(u8, flag, "hardware-acceleration")) {
        const pol = render_config.parseHwPolicy(value).?;
        c.zb_app_set_hw_policy(@as(c_int, @intFromEnum(pol)));
    }
    // `renderer` is always refused on Windows (handled by the decision); `profile-dir` is applied at
    // startup via `zb_app_set_profile_dir` (WS3.1), not through this per-flag arm.
}

/// WS3.1: set the WebView2 user-data folder (owner-only DACL dir from WS2.0). Separate from the flag
/// arm because it runs at startup, before the environment is created.
pub fn applyProfileDir(dir: [*:0]const u8) Error!void {
    var err: [*c]u8 = null;
    const rc = c.zb_app_set_profile_dir(dir, &err);
    c.zb_automation_free(err);
    if (rc != c.ZB_AUTO_OK) return error.UnsupportedFlag;
}
