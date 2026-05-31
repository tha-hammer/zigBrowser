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
