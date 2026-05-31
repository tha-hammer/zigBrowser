# WebKitGTK Slice 1 E2E Harness

This harness validates the §C8 protocol against the built binary.

Checks:
- `TITLE\t<title>` stdout protocol from `--print-title`
- screenshot PNG generation + non-uniform pixel oracle
- clean quit by tracking child PIDs while alive, then asserting those exact PIDs exit

Usage:

```bash
python3 tests/e2e/webkitgtk_slice1_e2e.py --mode all
```

Sub-modes:
- `open-title`
- `screenshot`
- `missing-file`
- `all`

Runner behavior:
- Uses `xvfb-run -a` when available (or with `--prefer-xvfb`)
- Falls back to `DISPLAY` (or `:1` when `/tmp/.X11-unix/X1` exists)
- If neither a display nor `xvfb-run` is available, exits with skip code `77` and a loud message

Dependencies:
- `python3`
- `python3-pil`
- `xvfb` for CI environments without a live display
