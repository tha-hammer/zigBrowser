# How to run zigBrowser (WebKitGTK App Shell Slice 2)

## Prerequisites

- Build completed (`zig build`)
- A display server:
  - local: `DISPLAY` (for example `:1`)
  - CI/headless: `xvfb-run -a`

## Version check

```bash
./zig-out/bin/zigBrowser --version
```

## Open an app entry page in a real window

With no URL argument, zigBrowser opens the `url` from the build-time
`zigbrowser.json` config. That value is baked into the binary when `zig build`
runs.

```bash
DISPLAY="${DISPLAY:-:1}" \
  ./zig-out/bin/zigBrowser
```

Pass a URL explicitly to override the configured default:

```bash
DISPLAY="${DISPLAY:-:1}" \
  ./zig-out/bin/zigBrowser "file://$(pwd)/tests/fixtures/app/index.html"
```

## Enable E2E protocol lines

```bash
DISPLAY="${DISPLAY:-:1}" \
  ./zig-out/bin/zigBrowser "file://$(pwd)/tests/fixtures/app/index.html#auto=allow" --e2e-protocol
```

Expected protocol lines include:

```text
NAV	<uri>	<title>
BLOCKED	<uri>
SUBWIN	<uri>
WINCOUNT	<n>
IPC	<cmd>	<result>
IPCERR	<cmd>	<message>
LOAD_FAIL	<uri>	<message>
```

## Notes on product scope

- This runtime is an app shell pivot, not a tabbed browser product.
- Active Slice 2 keeps legacy browser-chrome controls out of scope.

## Rendering options (GPU problems)

Two startup flags choose how WebKit renders. Without them the browser uses
its built-in default, which today is `--hardware-acceleration never` with
the default renderer.

| Flag | Values | Effect |
|---|---|---|
| `--hardware-acceleration` | `never` (default), `always`, `webkit` | WebKit's hardware-acceleration policy for every window; `webkit` leaves WebKit's own choice |
| `--renderer` | `default`, `shm`, `mesa-egl` | `shm` sets `WEBKIT_DMABUF_RENDERER_FORCE_SHM=1` (shared-memory frames, no GPU buffers); `mesa-egl` sets `__EGL_VENDOR_LIBRARY_FILENAMES` to Mesa's vendor file (`/usr/share/glvnd/egl_vendor.d/50_mesa.json`) |

A variable you set yourself always wins: the flags never override it.
When a flag changes the default, the browser prints
`zigBrowser: rendering: hardware-acceleration=<policy> renderer=<renderer>`
on stderr.

Why these exist (measured 2026-10-11 on an NVIDIA RTX 3080, driver
550.163.01, X11, WebKitGTK 2.54.0, playing a YouTube video):

- With `never` (the current default) or any other path without DMA-BUF,
  the page's web process died within 10-35 s and the window stayed blank.
  `page.list` now reports such a window as `crashed`.
- With WebKit's own policy (`webkit`) or `always`, the page stayed alive
  and the video played, but nothing was drawn ("Failed to create GBM
  buffer"): the window looked empty but still answered clicks.
- `--hardware-acceleration webkit --renderer shm` and
  `--hardware-acceleration webkit --renderer mesa-egl` kept the page alive
  and the video playing without GBM buffer failures.

DRAFT: the built-in default changes to one of those two once it has been
confirmed on screen (`default_render` in `src/render_config.zig`).
