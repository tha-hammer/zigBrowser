//! Dedicated cross-check root for the `cross-check-ws3-win` step (WS3 `.windows` arm + WebView2 cookie
//! port). It is NOT part of the app — it only forces the Windows cookie port and the config-apply arm to
//! be compiled and their `zb_*` C-ABI references emitted, so `check_cross_symbols.py` can verify that
//! `src/webview2_shim.cpp` defines every `zb_*` symbol they need. RED until BlackRobin's Windows shim
//! pre-slice defines `zb_cookies_*` / `zb_app_set_*` / `zb_automation_free`.
comptime {
    _ = &@import("automation_wv2_cookie_port.zig").cookiePort;
    _ = &@import("webview2_config.zig").applyWindowsFlag;
    _ = &@import("webview2_config.zig").applyProfileDir;
}
