# How to build zigBrowser

This guide builds the `zigBrowser` executable from source with the project's Zig toolchain requirement.

## Prerequisites

- A clone of this repository.
- Zig `0.16.0` available on `PATH`.
- `libcurl` available at `/usr/lib/x86_64-linux-gnu/libcurl.so.4` (this path is referenced directly in `build.zig`).

## Steps

1. Install Zig `0.16.0` for your platform and put `zig` on your `PATH`.
2. Verify the pinned version:
   ```bash
   zig version
   ```
3. Build the project from the repository root:
   ```bash
   zig build
   ```
4. Confirm the executable exists:
   ```bash
   ls -l zig-out/bin/zigBrowser
   ```

## Result

You now have a built executable at `zig-out/bin/zigBrowser`.
