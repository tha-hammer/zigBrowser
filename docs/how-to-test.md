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
