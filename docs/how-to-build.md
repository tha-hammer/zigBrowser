# How to build zigBrowser (WebKitGTK Slice 1)

This project now targets an embedded **WebKitGTK** engine (not the archived custom renderer).

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

## Notes

- Build wiring is expected to resolve WebKit/GTK via `pkg-config`.
- If dependencies are missing, build should fail loudly rather than silently fallback.
