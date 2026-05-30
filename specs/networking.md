# Networking Specification

Baseline: commit `3d43b1d`.

## 1. Scope

This spec covers URL handling, fetch behavior, origin/storage boundary, and networking error-set discipline.

Primary files:
- `src/net/url.zig`
- `src/net/fetch.zig`
- `src/security/origin.zig`
- `src/net/store.zig`
- `src/errors.zig`

## 2. Error-Set Discipline

Centralized error contracts (`src/errors.zig`):

```zig
pub const NetError = error{
    InvalidUrl,
    DnsFailed,
    ConnectionRefused,
    Timeout,
    CertInvalid,
    TlsError,
    TransferFailed,
};

pub const ParseError = error{MalformedDocument};
pub const NavError = NetError || ParseError;
pub const StoreError = error{CrossOriginDenied};
```

Rules:
- URL and fetch modules return `NetError` only.
- Navigation APIs (`Page.navigate`, `Page.navigateLink`) surface `NavError`.
- Origin store APIs surface `StoreError` (+ allocator error on `set`).
- Unknown low-level failures are normalized to `TransferFailed` rather than leaked as ad hoc errors.

## 3. URL Parse / Resolve / Serialize

`src/net/url.zig` defines:

```zig
pub const ParsedUrl = struct {
    scheme: []const u8,
    host: []const u8,
    port: ?u16 = null,
    path: []const u8,
    query: ?[]const u8 = null,
    fragment: ?[]const u8 = null,
};
```

Behavior:
- `parse(arena, input)` uses `std.Uri.parse`, lowercases scheme/host, normalizes empty path to `/`.
- Explicit default ports are canonicalized away (`https:443`, `http:80`, `wss:443`, `ws:80` -> `port = null`).
- `resolve(arena, base, ref)` resolves relative references via `std.Uri.resolveInPlace`.
- `serialize(arena, ParsedUrl)` round-trips back to canonical URL text.

Navigation usage:
- `Page.navigateLink` treats absolute `http/https` hrefs via `parse`.
- Relative hrefs are resolved against `current_url` via `resolve`.
- If no base URL is available, relative navigation fails with `error.InvalidUrl`.

## 4. Fetch and Response Contract

`src/net/fetch.zig`:

```zig
pub const Response = struct {
    status: u16,
    content_type: []const u8,
    bytes: []const u8,
};
```

Execution model:
- `fetch` shells out to `curl` with redirect following and explicit timeouts.
- Body is captured from stdout.
- Status and content-type are parsed from curl `--write-out` markers.
- Empty content-type is normalized to `application/octet-stream`.

Curl exit mapping (`mapCurlExit`):
- `6` -> `DnsFailed`
- `7` -> `ConnectionRefused`
- `28` -> `Timeout`
- `18,23,26,52,55,56` -> `Timeout` (blackhole/transfer timeout family)
- `35` -> `TlsError`
- `51,60` -> `CertInvalid`
- everything else -> `TransferFailed`

## 5. Origin Model

`src/security/origin.zig`:
- `Origin = { scheme, host, port }`
- `fromUrl(ParsedUrl)` applies default port when URL port is null.
- `eql(a, b)` is strict scheme+host+port equality.

Implication:
- `https://example.com` and `https://example.com:443` become equal origins after normalization.

## 6. Origin-Keyed Store

`src/net/store.zig`:
- `Store` is initialized with a single origin.
- `get`/`set` require origin match.
- Cross-origin access returns `error.CrossOriginDenied`.
- `delete` is no-op for cross-origin requests.

This enforces a same-origin boundary at storage API level independent of caller behavior.

## 7. Integration with Page Navigation

`src/page.zig` networking integration:
- `Page.navigate(io, ParsedUrl)` calls `fetch` first.
- On success, response bytes enter parser/render pipeline.
- Page origin is set from `origin.fromUrl(url)`.
- On pipeline parse/build failures, navigation returns `error.MalformedDocument`.

As a result, navigation exposes a unified `NavError` surface that composes transport (`NetError`) with parse (`MalformedDocument`) failure modes.
