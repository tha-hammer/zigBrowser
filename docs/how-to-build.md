# How to build zigBrowser (WebKitGTK App Shell)

This project targets an embedded **WebKitGTK** app shell (not the archived custom renderer).

## Prerequisites

- Zig `0.16.0` on `PATH`
- `pkg-config`
- WebKitGTK + GTK3 development packages
- E2E tool dependencies for screenshot/title protocol checks

Debian/Ubuntu:

```bash
sudo apt-get update
sudo apt-get install -y \
  libwebkit2gtk-4.1-dev \
  libgtk-3-dev \
  xvfb \
  python3 \
  python3-pil \
  pkg-config
```

## Build

```bash
zig version
zig build
ls -l zig-out/bin/zigBrowser
```

## Site config

`zig build` reads `zigbrowser.json` from the repository root by default. The
configured `url` is validated during the build and baked into the binary as the
no-argument app URL.

```json
{
  "url": "https://cosmic-hr-development.up.railway.app/"
}
```

Pass a different config path with `-Dsite_config`:

```bash
zig build -Dsite_config=tests/fixtures/config/valid_http.json
packaging/release-build.sh -Dsite_config=tests/fixtures/config/valid_http.json
```

## Windows and macOS builds

The Windows (WebView2) and macOS (WKWebView) builds need their platform SDKs,
which a Linux machine does not have. What can be checked on Linux runs as
part of `zig build test`, or on its own:

```bash
zig build cross-check
```

This compiles `src/main.zig` to an object file for `x86_64-windows-gnu`,
`aarch64-macos` and `x86_64-macos` (no SDK, no link), then
`tools/check_cross_symbols.py` lists every `zb_*` C function the object
needs and fails if that target's shim (`src/webview2_shim.cpp`,
`src/wkwebview_shim.m`) does not define it. Today each target needs only
`zb_app_run`, `zb_run_screenshot` and `zb_version_line`.

| Checked on Linux | Not checked on Linux |
|---|---|
| All Zig code compiles for Windows and macOS | Compiling the C++/Objective-C shims |
| No GTK-only symbol (`zb_automation_*`, `zb_cookies_*`, `zb_native_*`, `zb_app_set_profile_dir`) is needed by those builds | The final link against WebView2/WebKit.framework |
| A server without a page or cookie port (what those builds run) answers every SDK method with a result or -32011, and native input with -32011 `unsupported` | Running the automation socket on a real Windows or macOS machine |

The automation API's page, cookie and native-input features are
GTK-only for now; on the other backends those methods answer -32011
(`session_invalid`).

## Notes

- Build wiring is expected to resolve WebKit/GTK via `pkg-config`.
- If dependencies are missing, build should fail loudly rather than silently fallback.
