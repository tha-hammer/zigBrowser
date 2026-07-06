---
date: 2026-07-04T08:57:01-04:00
researcher: RainyFox
git_commit: af2e4c35a9a6f927d9b3d1e3bcff835fcc97aa21
branch: master
repository: zigBrowser
topic: "zigBrowser filestore seams, interfaces, contracts, existing grammar, and future grammar"
tags: [research, codebase, filestore, storage, configuration, ipc, backend-seams]
status: complete
last_updated: 2026-07-04
last_updated_by: RainyFox
last_updated_note: "Added follow-up decisions for comptime config, config-owned literals, best-practice locations, and mandatory backend-specific files"
related_beads: [zigBrowser-2aa]
---

# Research: zigBrowser Filestore Seams, Interfaces, Contracts, Existing Grammar, and Future Grammar

**Date**: 2026-07-04 08:57:01 -04:00
**Researcher**: RainyFox
**Git Commit**: af2e4c35a9a6f927d9b3d1e3bcff835fcc97aa21
**Branch**: master
**Repository**: zigBrowser

## Research Question

Use the existing browser-storage research summary to map the codebase seams, interfaces, contracts, existing grammar, and future grammar for using zigBrowser/Chromium/WebKit as an isolated filestore. The intended storage invariant is that users can isolate files they want to use with the app, including byte-for-byte duplicate copies inside the isolated zigBrowser environment.

## Summary

zigBrowser currently has no active filestore grammar, no profile-directory grammar, no OPFS/File System Access probe, no native file-copy IPC command, and no backend-specific persistent storage configuration. The active app shell does provide the seams that a filestore can attach to:

- **Build/config seam**: `build.zig` selects a backend and already has an open beads issue for build-time JSON config ingestion (`zigBrowser-2aa`).
- **Runtime entry seam**: `src/cli.zig` produces `Command.open{url, print_title, e2e_protocol}` and `src/main.zig` passes only a validated URI to `zb_app_run`.
- **Origin/navigation seam**: `src/uri.zig` validates URI shape; `src/nav_policy.zig` decides allow/block/subwindow behavior.
- **Host IPC seam**: `src/ipc.zig` dispatches string-named JSON commands through `zb_ipc_dispatch`.
- **Backend storage seams**: GTK, WebView2, and WKWebView shims each create their browser runtime without explicit per-app profile/data-store configuration today.
- **E2E observation seam**: `--e2e-protocol` emits tab-separated events, but no storage events exist yet.

The existing IPC C ABI is JSON text with a 4096-byte result buffer. That is enough to return metadata and small proofs, but not enough to return arbitrary file bytes. A byte-for-byte filestore contract should therefore treat host IPC as a control plane: import/copy/list/hash/forget operations return JSON metadata, while the bytes are copied by browser storage APIs or native backend code inside an isolated profile/workspace.

## Related Issue

`zigBrowser-2aa` is open: "Build-time JSON config ingestion (zigbrowser.json)". Its description points to `thoughts/shared/plans/2026-07-04-12-50-tdd-build-time-json-config.md`. That plan's v1 grammar only defines `url`; filestore/profile/workspace grammar is not yet represented.

## Existing Grammar

### CLI Grammar

`src/cli.zig` defines the current process grammar as a `Command` union:

- `version`
- `open { url, print_title, e2e_protocol }`
- `screenshot { url, out, w, h, print_title }`
- `usage`

Evidence:

- `src/cli.zig:3-18` defines the union and fields.
- `src/cli.zig:20-33` routes `--version`, `--screenshot`, or open mode.
- `src/cli.zig:54-84` accepts one URL plus optional `--print-title` and `--e2e-protocol`.
- There are no `--profile-dir`, `--storage-dir`, `--workspace`, `--ephemeral`, or `--filestore` flags.

The no-args default URL is currently a hardcoded string at `src/cli.zig:21`. Build-time JSON config research identifies that line as the current app identity seam.

### URI Grammar

`src/uri.zig` accepts URI strings only after `std.Uri.parse` succeeds:

- `http` and `https` require a host.
- `about` is passed through.
- `file` is accepted.
- other schemes and relative inputs are rejected.

Evidence:

- `src/uri.zig:5-21` contains validation.
- `src/main.zig:37-48` calls `uri.validate` before `zb_app_run`.
- `src/main.zig:63-75` maps URI errors to user-visible messages and exit codes.

Current test grammar in `tests/uri_test.zig` describes canonical output for `file:/tmp/live.html` and `http://example.com`, while the live `src/uri.zig` implementation returns the input bytes after validation. That is a current source/test contract split relevant to any future stable-origin grammar.

### Navigation Policy Grammar

`src/nav_policy.zig` defines two enum grammars pinned to C integer ordinals:

```zig
Decision = use | ignore | open_in_subwindow
DecisionType = navigation_action | new_window_action | response
```

Rules in live code:

- `new_window_action` always returns `open_in_subwindow`.
- `response` always returns `use`.
- `navigation_action` applies file URI containment only if `app_base` canonicalizes as a file URI.
- If `app_base` is not a file URI, navigation action falls through to `use`.

Evidence:

- `src/nav_policy.zig:3-22` pins enum names and ordinals.
- `src/nav_policy.zig:24-38` defines the routing.
- `src/nav_policy.zig:55-89` implements file URI path containment.
- `tests/nav_policy_test.zig:69-83` asserts non-file app bases allow normal web browsing.

For filestore isolation, this is the current app-vs-external-origin gate. It does not yet model storage permissions, app-origin capability gates, or host IPC access by origin.

### IPC Grammar

`src/ipc.zig` is the host command grammar. It currently accepts:

| Command | Args | Result |
|---|---|---|
| `ping` | missing, `null`, or `{}` | JSON string `"pong"` |
| `add` | object with integer `a` and `b` | JSON number text |
| `echo` | object with string `msg` | JSON string text |
| `os.info` | missing, `null`, or `{}` | JSON object |

Evidence:

- `src/ipc.zig:16-40` is the command dispatch table.
- `src/ipc.zig:42-74` exports `zb_ipc_dispatch`.
- `src/ipc.zig:12-14` defines threadlocal scratch/result/error buffers.
- `tests/ipc_test.zig:128-160` asserts the 4096-byte C result ceiling.

The IPC grammar is JSON text, not binary. Returning file bytes through this path would collide with the 4096-byte result buffer and JSON string encoding. Current IPC can carry file metadata, operation status, object IDs, hashes, sizes, and short diagnostic samples.

### E2E Protocol Grammar

`tests/e2e/PROTOCOL.md` defines line-delimited UTF-8 stdout events:

- `NAV\t<uri>\t<title>`
- `IPC\t<cmd>\t<result_json>`
- `IPCERR\t<cmd>\t<error_name>`
- `BLOCKED\t<candidate_uri>`
- `LOAD_FAIL\t<uri>\t<domain>\t<code>`
- `SUBWIN\t<uri>`
- `WINCOUNT\t<n>`

There is no storage/import/profile/hash event grammar yet.

## Backend Storage Seams Today

### GTK / WebKitGTK

GTK app state currently tracks windows and app base, not profile/storage state:

- `ZbWindow` has `gtk_window`, `view`, `ucm`, `context`, URI/load state, timers, signal IDs, and app pointer.
- `ZbApp` has `windows`, `n_windows`, `app_base`, protocol flags, exit code, pending subwindow seed, and signal source IDs.

Evidence:

- `src/webkit_shim.c:61-110` defines `ZbWindow` and `ZbApp`.
- `src/webkit_shim.c:1120-1124` uses `webkit_web_context_get_default()` and sets cookie accept policy.
- `src/webkit_shim.c:1126-1135` creates a `WebKitUserContentManager` and `webkit_web_view_new_with_user_content_manager`.
- `src/webkit_shim.c:893-953` wires each WebView into a window and installs IPC.

No code creates a `WebKitWebsiteDataManager`, passes an app-specific data/cache directory, registers a custom URI scheme, handles file chooser requests, probes OPFS, or exposes persistent storage status.

Historical plan context says related child views intentionally share context/cookies/localStorage/IndexedDB/cache (`thoughts/shared/plans/2026-05-31-14-41-ENG-0004-tdd-webkitgtk-appshell-slice2.md:363-368`). In live GTK code, child windows use `webkit_web_view_new_with_related_view` at `src/webkit_shim.c:620-621`.

### WebView2

WebView2 app state currently tracks a window, URI, flags, exit code, and WebView COM objects:

- `src/webview2_shim.cpp:28-40` defines `AppState`.
- `src/webview2_shim.cpp:692-693` calls `CreateCoreWebView2EnvironmentWithOptions(nullptr, nullptr, nullptr, ...)`.
- `src/webview2_shim.cpp:646-657` registers `WebMessageReceived`.
- `src/webview2_shim.cpp:412-463` dispatches IPC and posts JSON reply strings.

The `userDataFolder` argument is currently `nullptr`. There is no virtual host mapping, explicit profile directory, File System Access handle integration, directory picker handling, storage capability probe, or runtime origin allowlist.

### WKWebView

WKWebView app state tracks app base and windows:

- `src/wkwebview_shim.m:212-226` defines `ZBAppHost`.
- `src/wkwebview_shim.m:242-256` defines `ZBWindowHost`.
- `src/wkwebview_shim.m:383-392` creates a `WKWebViewConfiguration` with JavaScript window-open support, a user content controller, and a backend marker script.
- `src/wkwebview_shim.m:367-368` registers `zbHost`.
- `src/wkwebview_shim.m:582-623` dispatches IPC through `zb_ipc_dispatch`.

There is no explicit `WKWebsiteDataStore`, no named persistent data store, no nonpersistent mode, no custom scheme handler, no open panel/file picker delegate path, and no storage probe.

## Existing Interface Map

| Layer | Current interface | Current payload | Filestore relevance |
|---|---|---|---|
| Build | `build.zig` target/backend switch | backend C/ObjC/C++ source and libs | place to add config schema and backend storage options |
| CLI | `parseArgs(argv) -> Command` | URL plus booleans | no storage/profile fields today |
| URI | `validate(arena, input) -> [:0]const u8` | URI C string | constrains app origin and custom scheme choices |
| Run ABI | `zb_app_run(uri, print_title, e2e_protocol)` | URI C string, ints | no room for profile/workspace/options today except baked config or ABI extension |
| Policy ABI | `zb_policy_decide(base, candidate, dtype)` | C strings + int enum | current navigation gate, not a capability gate |
| IPC ABI | `zb_ipc_dispatch(cmd, args_json, out_result, out_err)` | command string + JSON args/result | control plane for future storage commands, not byte plane |
| E2E | `--e2e-protocol` stdout rows | tab-separated text | can add observable storage/profile/hash rows |

## Future Grammar For Isolated Byte-For-Byte Filestore

The planned `zigbrowser.json` v1 grammar defines only:

```json
{
  "url": "https://example.com/app"
}
```

The plan reserves future fields such as `title`, `width`, `height`, and `permissions`, but not storage/profile/filestore. A future filestore grammar can extend the same config seam additively:

```json
{
  "url": "https://app.example/",
  "app_id": "example-app",
  "origin": {
    "mode": "https",
    "host": "app.example"
  },
  "storage": {
    "profile": {
      "mode": "persistent",
      "scope": "per_app",
      "base_dir": "${user_data}/zigBrowser/example-app"
    },
    "filestore": {
      "mode": "opfs_copy",
      "duplicate_policy": "always_copy",
      "identity_hash": "sha256",
      "manifest": "indexeddb"
    },
    "workspace": {
      "mode": "user_selected",
      "visibility": "isolated_copy"
    }
  },
  "permissions": {
    "host_ipc": ["filestore.import", "filestore.stat", "filestore.readMeta", "filestore.forget"],
    "external_navigation": "block"
  }
}
```

This grammar is not implemented. It names the contracts that the existing seams would need to carry.

## Future Contract Shape

### Isolation Contract

An app/workspace must have a distinct browser profile/data directory. Browser-private storage, cookies, permissions, IndexedDB, Cache Storage, OPFS, and any manifest/index belong to that profile. Launching a different profile/workspace must not see the first profile's stored file objects.

Backend seams:

- GTK: `zb_app_run` setup is where a `WebKitWebsiteDataManager` / non-default `WebKitWebContext` would be attached.
- WebView2: `create_environment` is where `userDataFolder` would stop being `nullptr`.
- WKWebView: `newConfiguredWebView` is where `configuration.websiteDataStore` would be selected.

### Stable Origin Contract

The app needs a stable origin for OPFS/IndexedDB/Cache Storage. Existing `file`, `http`, `https`, and `about` URI validation limits what can be loaded. A custom scheme would require URI grammar changes; an HTTPS/loopback/virtual-host approach fits the current `https` grammar but still needs backend runtime setup.

### Byte-For-Byte Duplicate Contract

The intended duplicate behavior is "copy, do not deduplicate":

- Importing a source file reads its bytes and writes a new isolated object.
- Importing the same source file twice creates two manifest records and two logical objects.
- Importing two separate source files with identical bytes also creates two logical objects.
- Each record can store `sha256`, byte length, original display name, import timestamp, and isolated object ID.
- The hash is an audit/proof field, not a dedup key.
- A verification read must reproduce the exact original bytes for that imported object.

This contract fits OPFS, a native workspace copy, or a hybrid. It does not fit an IPC design that tries to return arbitrary file contents through `zb_ipc_dispatch` result strings.

### Host IPC Contract

Future commands should remain JSON metadata commands. A minimal command grammar could be:

| Command | Args | Result |
|---|---|---|
| `filestore.capabilities` | `{}` | `{backend, opfs, directoryPicker, nativeWorkspace, persistentStorage}` |
| `filestore.import` | `{sourceHandleId? name?}` or native-selected source | `{objectId, sha256, size, duplicateOrdinal}` |
| `filestore.stat` | `{objectId}` | `{objectId, sha256, size, name, createdAt}` |
| `filestore.list` | `{}` | `{objects:[...]}` |
| `filestore.forget` | `{objectId}` | `{ok:true}` |

Large bytes should move through browser APIs or native copy side effects, with IPC returning IDs and hashes. If chunk streaming is introduced later, the C ABI needs explicit chunk size, ordering, backpressure, and result-buffer contracts.

### E2E Protocol Contract

Future protocol rows can mirror the existing tab-separated style:

- `STORE_CAPS\t<json>`
- `STORE_IMPORT\t<object_id>\t<sha256>\t<size>`
- `STORE_DUP\t<object_id>\t<sha256>\t<duplicate_ordinal>`
- `STORE_FORGET\t<object_id>`
- `STORE_ERR\t<operation>\t<error_name>`

Fields must follow the existing protocol rule: one event per line, tab-separated, sanitized, and flushed.

## Contract Tests To Pin Before Implementation

### Unit Tests

- Config parser accepts v1 `{url}` and future storage fields while ignoring unknown fields.
- Config parser rejects empty `app_id`, unsupported `storage.profile.mode`, unsupported `storage.filestore.duplicate_policy`, and non-absolute configured profile dirs if configured paths are allowed.
- URI/origin tests pin whether the app origin is `https`, `file`, loopback, or custom scheme.
- IPC tests pin every future `filestore.*` command schema, error name, and result JSON size ceiling.

### Backend E2E Tests

- Launch profile A, import fixture bytes, relaunch profile A, verify object and hash still exist.
- Launch profile B, verify profile B cannot see profile A's object.
- Launch ephemeral profile, import fixture bytes, exit, relaunch, verify object is gone.
- Import the same fixture twice and assert two object IDs, same SHA-256, same size, and byte-for-byte equality for both stored copies.
- Try traversal or outside-root object references and assert denial.
- Load an external origin and assert it cannot call `filestore.*` host IPC.

### Browser Capability Probe

A fixture page should report:

- `location.origin`
- `isSecureContext`
- `indexedDB` availability
- `caches` availability
- `navigator.storage.getDirectory` availability
- `navigator.storage.persist` / `estimate` availability
- `showDirectoryPicker` availability

This should be recorded per backend because WebKitGTK, WebView2, and WKWebView differ in browser storage APIs.

## Follow-up Research 2026-07-04 09:09 - User Decisions

The user answered the related configuration open questions with these decisions:

| Question | Decision |
|---|---|
| Comptime vs runtime config parse | **Comptime**. Config is build-time input baked into the binary. |
| Future config schema scope | **All tunable parameters, all string literals, and UI text belong in config files.** Code lookups should be one jump from a generated config/accessor surface. |
| Config file location convention | **Follow best practices.** For build-time project config, use explicit project files instead of runtime search/discovery. For generated runtime storage paths, follow OS data/cache conventions per backend/platform. |
| Per-backend overrides | **Yes; mandatory backend-specific files.** Backend-specific config files are required to maintain isolation because GTK/WebKitGTK, WebView2, and WKWebView have different profile/data-store mechanisms and storage API behavior. |

### Resulting Future Grammar Direction

The config grammar should be split into a root manifest plus mandatory backend files. The root manifest carries app identity and cross-backend policy; each backend file carries storage/profile/origin settings for that backend only.

Example shape, not implemented:

```json
{
  "app_id": "example-app",
  "url": "https://app.example/",
  "strings": "config/strings/en-US.json",
  "ui": "config/ui/default.json",
  "tunables": "config/tunables/default.json",
  "storage": "config/storage/common.json",
  "backends": {
    "gtk": "config/backends/gtk.json",
    "webview2": "config/backends/webview2.json",
    "wkwebview": "config/backends/wkwebview.json"
  }
}
```

One-jump lookup means application code should import a generated config module or accessor table and read a named field directly, rather than parsing JSON ad hoc at each call site or reaching through nested loader layers. Backend shims should receive already-resolved backend-specific values through a narrow config/run-options seam.

### Resulting Contract Updates

- Config parsing and validation should happen at build time.
- Missing root config or missing backend-specific config should fail the build.
- All user-visible strings and UI labels should be config-owned, including future storage permission/revoke/copy wording.
- Backend-specific files are part of the isolation boundary, not optional overrides.
- Tests should include one negative build case per backend: selecting a backend without its required backend config file fails before linking/running.

## Remaining Open Questions

1. Is the isolated environment expected to be browser-private only (OPFS/profile) or user-visible on disk after import?
2. Should duplicate copies be physically separate byte blobs, or can a manifest expose separate logical objects over one content-addressed blob? The user's stated intention says "byte for byte duplicates", which reads as separate logical copies at minimum.
3. Should the app origin be a configured HTTPS origin, a loopback server, a WebView2 virtual host, or a backend custom scheme?
4. Should profile/workspace selection have a runtime user choice layered under the comptime defaults, or should all isolation roots be fixed at build time?
5. Should all backends expose one cross-backend native `filestore.*` control plane, or should WebView2 use Chromium File System Access API directly with WebKit backends using native copy fallback?

## Code References

- `src/cli.zig:3-18` - current `Command` union grammar.
- `src/cli.zig:20-84` - CLI parser and open/screenshot grammar.
- `src/uri.zig:5-21` - URI validation grammar.
- `src/main.zig:37-48` - validated URI passed to `zb_app_run`.
- `src/nav_policy.zig:3-38` - navigation decision grammar and routing.
- `src/nav_policy.zig:55-89` - file URI containment.
- `src/ipc.zig:16-40` - current host IPC commands.
- `src/ipc.zig:42-74` - C ABI IPC adapter.
- `src/webkit_shim.h:30-41` - C ABI seam.
- `src/webkit_shim.c:61-110` - GTK app/window state.
- `src/webkit_shim.c:1120-1135` - GTK default WebKit context and view creation.
- `src/webview2_shim.cpp:28-40` - WebView2 app state.
- `src/webview2_shim.cpp:671-693` - WebView2 environment creation with null user data folder.
- `src/wkwebview_shim.m:383-392` - WKWebView configuration without explicit data store.
- `tests/e2e/PROTOCOL.md:1-40` - E2E protocol grammar.
- `thoughts/shared/plans/2026-07-04-12-50-tdd-build-time-json-config.md` - planned `zigbrowser.json` v1 grammar.
- `thoughts/shared/research/2026-07-04-12-30-build-time-config-seams.md` - related build-time config seam research.

## Related Research

- `thoughts/shared/research/2026-07-04-12-30-build-time-config-seams.md`
- `thoughts/shared/research/2026-05-31-16-52-slice3-4-ipc-and-cross-os-backends.md`
