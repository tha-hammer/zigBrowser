# Networking Specification (WebKitGTK Slice 1)

Grounding:
- Plan: `thoughts/searchable/shared/plans/2026-05-31-12-48-ENG-0003-tdd-webkitgtk-browser-slice1.md`

## 1. Scope

Networking for Slice 1 is delegated to WebKitGTK.  
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
- do not emit success title protocol on stdout
- in screenshot mode, do not write a success PNG artifact

## 4. Ownership boundary

- WebKit networking stack owns HTTP/TLS transport behavior.
- Shell owns:
  - URI allowlist gate
  - CLI protocol/exit mapping
  - testable stderr/stdout contracts

## 5. Test fixtures and deterministic checks

- Local deterministic fixture: `tests/fixtures/live.html`
- Missing-file negative path marker: `tests/fixtures/missing-file.txt`
- E2E harness: `tests/e2e/webkitgtk_slice1_e2e.py`

## 6. Obsolete legacy scope

Any spec text describing direct `libcurl` subprocess fetch, custom URL structs, or custom-origin store as active runtime behavior is obsolete for Slice 1 and retained only in archived history.
