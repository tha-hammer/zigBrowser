# How to test zigBrowser (WebKitGTK Slice 1)

## Prerequisites

- Zig `0.16.0`
- WebKitGTK/GTK3 dev deps (see `docs/how-to-build.md`)
- `python3` + `python3-pil`
- Display for runtime checks:
  - `xvfb-run` for CI
  - or local `DISPLAY` (for example `:1`)

## Unit/integration suite

```bash
zig build test --summary all
```

## E2E protocol harness (§C8)

Run all harness checks:

```bash
python3 tests/e2e/webkitgtk_slice1_e2e.py --mode all
```

Force xvfb path:

```bash
python3 tests/e2e/webkitgtk_slice1_e2e.py --mode all --prefer-xvfb
```

## Harness semantics

- Oracle 1: stdout title line `TITLE\t<title>`
- Oracle 2: screenshot PNG non-uniformity via `tests/snapshots/pillow_tools.py nonuniform`
- Clean quit: records child PIDs while alive, then asserts those exact PIDs exit

If required tools are missing (binary, Pillow, display/xvfb), the harness exits with code `77` and a loud skip reason on stderr.
