# How to test zigBrowser (WebKitGTK App Shell Slice 2)

## Prerequisites

- Zig `0.16.0`
- WebKitGTK/GTK3 dev deps (see `docs/how-to-build.md`)
- `python3` + `python3-pil`
- Display for runtime checks:
  - `Xvfb` + `xauth` (package `xvfb`) for CI: `--prefer-xvfb` runs each
    browser on a private display owned by `tests/e2e/xsession.py`
  - or local `DISPLAY` (for example `:1`)

## Unit/integration suite

```bash
zig build test --summary all
```

## Slice 1 harness (baseline)

Run all harness checks:

```bash
python3 tests/e2e/webkitgtk_slice1_e2e.py --mode all
```

Force xvfb path:

```bash
python3 tests/e2e/webkitgtk_slice1_e2e.py --mode all --prefer-xvfb
```

## Slice 2 harness tests (§C8+)

Local display path (this workstation):

```bash
DISPLAY="${DISPLAY:-:1}" python3 tests/e2e/reload_test.py
DISPLAY="${DISPLAY:-:1}" python3 tests/e2e/nav_allow_test.py
DISPLAY="${DISPLAY:-:1}" python3 tests/e2e/nav_block_test.py
DISPLAY="${DISPLAY:-:1}" python3 tests/e2e/subwindow_test.py
DISPLAY="${DISPLAY:-:1}" python3 tests/e2e/ipc_roundtrip_test.py
```

CI/headless path:

```bash
python3 tests/e2e/reload_test.py --prefer-xvfb
python3 tests/e2e/nav_allow_test.py --prefer-xvfb
python3 tests/e2e/nav_block_test.py --prefer-xvfb
python3 tests/e2e/subwindow_test.py --prefer-xvfb
python3 tests/e2e/ipc_roundtrip_test.py --prefer-xvfb
```

Slice 2 protocol checks:

- `NAV`, `BLOCKED`, `SUBWIN`, `WINCOUNT`, `IPC`, `IPCERR`, `LOAD_FAIL`
- helper-PID tracking while process is alive, then exact-PID exit assertion on shutdown

If required tools are missing (binary, Pillow, display/xvfb), the harness exits with code `77` and a loud skip reason on stderr.

## Node SDK live test (opt-in)

`sdk/node/tests/live.test.ts` drives the real binary through the Node SDK.
It runs only when `ZB_BINARY` is set and `python3`, `Xvfb` and `xauth` are
installed (after `npm ci` in `sdk/node`):

```bash
cd sdk/node && ZB_BINARY=../../zig-out/bin/zigBrowser npx vitest run tests/live.test.ts
```

It starts the browser through `tests/e2e/xsession.py` on a private Xvfb
display, never your `DISPLAY`, and tears down the browser's whole process
group. If the vitest run is killed, the launcher's guardian ends the browser
and removes the display. `tests/e2e/node_live_group_test.py --binary
zig-out/bin/zigBrowser` checks that: while the browser is up, it SIGKILLs
the whole vitest run (the main process and its workers, not the browser) and
expects no zigBrowser, WebKit helper or Xvfb from it to remain, and no
display lock or socket. The old live test, which started the browser
directly, left the browser and its helpers running.

That check runs vitest on a display of its own (an Xvfb it starts), and that
Xvfb and the vitest run die with the check however it ends: the kernel
signals them when it exits (`PR_SET_PDEATHSIG`), and Xvfb removes its own
lock and socket. `tests/e2e/node_live_group_kill_test.py --binary
zig-out/bin/zigBrowser` checks that: it SIGKILLs `node_live_group_test.py`
once its Xvfb is up and expects that Xvfb, its lock and its socket to be
gone within 10 s. Before this, they stayed.

None of the three runs in `zig build test`. When a tool is missing, the two
Python checks exit `77` (skip); the vitest live test is skipped
(`describe.skip`) and vitest exits `0`.

## Known issues with WebKitGTK 2.54.0

The host moved from WebKitGTK 2.52.6 to 2.54.0 (`2.54.0-1~deb13u2`) on
2026-10-11. Gates run on 2.54.0 from then on; treat a new failure as possible
upgrade fallout.

- **Native hover and the `automation-scroll` e2e: fixed in `53b5c66`.** On
  2.54.0, `automation-scroll` failed every time with "hover moved away:
  expected False, got True". A native mouse move was reported done before the
  page had received it, and 2.54.0 delivers moves later, so the page's next
  evaluation could run first. `53b5c66` makes a native hover wait until the
  page has the final move (PagePort `settlePointer`). The reviewer's clean
  gate at `53b5c66` passed 88/88 steps, including `automation-scroll` and
  `native-hover`. Its follow-up `6f90a1a` makes a page that is replaced while
  the hover waits fail with `document_changed` instead of succeeding (review
  5052, closed).
- **YouTube watch page goes blank (default changed, cc_1).** On the live NVIDIA/X11
  desktop, a YouTube watch page opened as a popup showed its poster, then the
  window went blank, while the page itself still loaded and answered. The live
  log shows NVIDIA buffer-allocation errors (`nv_gbm_create_device`,
  `DRM_IOCTL_MODE_CREATE_DUMB ... Permission denied`) even though every view
  used hardware-acceleration policy `NEVER` (the old default). 2.54.0 no longer crashes the
  browser there, but on Xvfb the popup's web process is lost: the window
  stays black and `page.evaluate` there fails with -32603. Since `1c4d0d8`
  that loss is reported: stderr says `zigBrowser: window <n>: web process
  terminated (<reason>)` and `page.list` shows `"crashed": "<reason>"` for
  the window. The same commit adds `--hardware-acceleration` and
  `--renderer` (see `docs/how-to-run.md`). After the user watched the cases
  on the real NVIDIA screen, the Linux default became WebKit's policy with
  `WEBKIT_DMABUF_RENDERER_FORCE_SHM=1` (case J, which played the video in
  real time); `--hardware-acceleration never` and `--renderer default` opt
  out. Xvfb has no NVIDIA GPU, so the gate proves only that nothing else
  broke; the real-screen check is the orchestrator's. The diagnosis is in
  `thoughts/searchable/shared/reviews/2026-10-10-automation-integration-review.md`
  ("Live YouTube blank-window investigation").
