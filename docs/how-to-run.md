# How to run zigBrowser (WebKitGTK Slice 1)

## Prerequisites

- Build completed (`zig build`)
- A display server:
  - local: `DISPLAY` (for example `:1`)
  - CI/headless: `xvfb-run -a`

## Version check

```bash
./zig-out/bin/zigBrowser --version
```

## Open a page in a real window

```bash
DISPLAY="${DISPLAY:-:1}" ./zig-out/bin/zigBrowser https://example.com
```

## Run against the live local fixture

```bash
DISPLAY="${DISPLAY:-:1}" \
  ./zig-out/bin/zigBrowser "file://$(pwd)/tests/fixtures/live.html" --print-title
```

Expected protocol line on success:

```text
TITLE	WebKitGTK Live
```

## Screenshot mode

```bash
DISPLAY="${DISPLAY:-:1}" \
  ./zig-out/bin/zigBrowser --screenshot /tmp/live.png "file://$(pwd)/tests/fixtures/live.html" --print-title
```

For CI/headless hosts:

```bash
xvfb-run -a ./zig-out/bin/zigBrowser --screenshot /tmp/live.png "file://$(pwd)/tests/fixtures/live.html" --print-title
```
