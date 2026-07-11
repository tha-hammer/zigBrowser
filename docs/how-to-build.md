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

## Notes

- Build wiring is expected to resolve WebKit/GTK via `pkg-config`.
- If dependencies are missing, build should fail loudly rather than silently fallback.
