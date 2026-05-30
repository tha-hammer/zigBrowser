# How to run zigBrowser on a URL

This guide runs the browser entrypoint in `src/main.zig` against a URL.

## Prerequisites

- Build completed (`zig build`).

## Steps

1. Run the built executable directly with a URL:
   ```bash
   ./zig-out/bin/zigBrowser https://example.com
   ```
2. Or run through the build step:
   ```bash
   zig build run -- https://example.com
   ```
3. Check the version path handled by `main.zig`:
   ```bash
   zig build run -- --version
   ```
4. If you pass no URL and no `--version`, expect:
   ```text
   usage: zigBrowser [--version|URL]
   ```

## Result

The browser fetches and processes the URL via `Page.navigate` and exits.
