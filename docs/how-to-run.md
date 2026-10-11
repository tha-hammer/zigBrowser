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

## Rendering (GPU problems)

On Linux the browser now renders with **WebKit's own hardware-acceleration
policy** and **shared-memory frames**: it sets
`WEBKIT_DMABUF_RENDERER_FORCE_SHM=1` before WebKit starts, unless you have
set that variable yourself (to anything, even `0` or empty). This applies to
normal windows, their popups and `--screenshot`. Two startup flags change it:

| Flag | Values | Effect |
|---|---|---|
| `--hardware-acceleration` | `webkit` (default), `never`, `always` | WebKit's hardware-acceleration policy for every window; `webkit` leaves WebKit's own choice |
| `--renderer` | `shm` (default), `default`, `mesa-egl` | `shm` sets `WEBKIT_DMABUF_RENDERER_FORCE_SHM=1` (shared-memory frames, no GPU buffers); `default` sets nothing; `mesa-egl` sets `__EGL_VENDOR_LIBRARY_FILENAMES` to Mesa's vendor file (`/usr/share/glvnd/egl_vendor.d/50_mesa.json`) instead |

The flags work the same after `--screenshot <out.png> <URL>`. Each flag
changes only its own half: `--hardware-acceleration never` alone keeps the
`shm` renderer. A variable you set yourself always wins over a flag and over
the default. When the flags differ from the default, the browser prints
`zigBrowser: rendering: hardware-acceleration=<policy> renderer=<renderer>`
on stderr.

### Why this is the default

Measured on 2026-10-11 on an NVIDIA RTX 3080 (driver 550.163.01, X11,
WebKitGTK 2.54.0) with a YouTube video, and watched by a person on the real
screen:

- **The old default, `never`, failed.** The thumbnail showed, then the
  window went blank and the page's web process died (within 10-35 s). So
  did the tested combinations with `WEBKIT_DISABLE_DMABUF_RENDERER=1`. `page.list` now reports such a
  window as `"crashed"`, and stderr says `zigBrowser: window <n>: web
  process terminated (<reason>)`.
- **WebKit's policy on its own** (`--renderer default`) kept the page alive,
  but nothing was drawn ("Failed to create GBM buffer"): the window looked
  empty yet still answered clicks.
- **WebKit's policy with `shm` (the new default) worked.** The video played
  in real time (at 10, 35 and 60 s its time was 4.6, 29.9 and 54.6 s), with no
  GBM buffer failures. The log still shows two harmless `nv_gbm` lines from
  NVIDIA's start-up.
- **WebKit's policy with `mesa-egl` drew the page too**, but the video's time
  jumped back and forth (2.9, 5.4, then 3.8 s), so it is not the default.

### Opting out

- Use the old behaviour: `--hardware-acceleration never --renderer default`.
- Keep WebKit's policy without shared memory: `--renderer default`, or export
  `WEBKIT_DMABUF_RENDERER_FORCE_SHM=0`.
- Try Mesa's EGL instead: `--renderer mesa-egl`.

Shared memory copies each frame through the CPU instead of handing GPU
buffers over, which costs some CPU on large, fast-changing pages. The
default lives in `default_render` in `src/render_config.zig`.

## Media Source Extensions (video pages that freeze)

| Switch | Values | Effect |
|---|---|---|
| `--media-source` | `on` (default), `off` | `off`: pages in every window, popups included, and `--screenshot` get no Media Source Extensions (`window.MediaSource`, `ManagedMediaSource` and `SourceBuffer` are undefined) |
| `ZIGBROWSER_MEDIA_SOURCE` | `on`, `off` | Used when the flag is not given |

The flag wins over the variable, and the variable wins over the default. A
variable that is not exactly `on` or `off` is ignored, with
`zigBrowser: ZIGBROWSER_MEDIA_SOURCE=<value> is not on or off; using on`
on stderr. With `off`, the browser prints `zigBrowser: media-source=off`.

Why: on 2026-10-11 an Instagram window froze twice. Its web process was
stuck in WebKitGTK 2.54.0's Media Source seek, in a lock cycle with
GStreamer (WebKit bugs 320336 and 272975; review log, "Instagram media
deadlock investigation"). No environment variable avoided it. Sites
that find no `MediaSource` usually play plain video files instead. The
default stays `on` until the user decides from evidence.

How: `off` sets WebKit's `enable-mediasource` setting to false. WebKitGTK
2.54.0 ignores that setting: a bare WebKit view still runs Media Source
with it off. So the browser also adds a script that runs in every frame
before the page's own scripts and deletes `MediaSource`,
`ManagedMediaSource`, `SourceBuffer`, `SourceBufferList` and
`ManagedSourceBuffer`. A page cannot reach Media Source through an empty iframe
either; workers have no Media Source in this WebKit. The values live in
`src/media_config.zig`.
