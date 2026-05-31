# Networking Specification (WebKitGTK App Shell Slice 2)

Grounding:
- Plan: `thoughts/searchable/shared/plans/2026-05-31-14-41-ENG-0004-tdd-webkitgtk-appshell-slice2.md`

## 1. Scope

Networking for Slice 2 is delegated to WebKitGTK.  
The browser shell validates URIs, invokes WebKit load APIs, and reports outcomes.

## 2. URI policy

Accepted schemes:
- `file`
- `http`
- `https`

Rejected schemes include (non-exhaustive):
- `javascript`
- `ftp`
- `data`
- `mailto`
- relative or scheme-less input

Validation failures must occur before any GTK/WebKit load call.

## 3. Load-failure surface

Transport, DNS, TLS, certificate, and file-load errors come from WebKit load-failed callbacks.

Shell behavior:
- emit diagnostics to stderr
- return non-zero exit
- emit machine-readable `LOAD_FAIL` protocol lines in e2e mode
- do not emit success `NAV` protocol lines for superseded/cancelled loads

## 4. Ownership boundary

- WebKit networking stack owns HTTP/TLS transport behavior.
- Shell owns:
  - URI allowlist gate
  - navigation policy allow/block decisions
  - CLI protocol/exit mapping
  - testable stderr/stdout contracts

## 5. Test fixtures and deterministic checks

- Local deterministic fixtures: `tests/fixtures/app/index.html`, `tests/fixtures/app/page-b.html`
- Mutable reload fixture: `tests/fixtures/app/index.mutable.html`
- E2E harness tests:
  - `tests/e2e/reload_test.py`
  - `tests/e2e/nav_allow_test.py`
  - `tests/e2e/nav_block_test.py`
  - `tests/e2e/subwindow_test.py`
  - `tests/e2e/ipc_roundtrip_test.py`

## 6. Obsolete legacy scope

Any spec text describing direct `libcurl` subprocess fetch, custom URL structs, or custom-origin store as active runtime behavior is obsolete for the WebKitGTK app-shell runtime and retained only in archived history.
