---
date: 2026-10-19T15:27:08-04:00
researcher: Claude (subagent for the orchestrator; voice-input STT track)
git_commit: a69b459cb5346e8d25488f41e76c034d6fd8f3fa
branch: zb-automation-integration-2026-10-10-11-59
repository: zigBrowser (worktree zb-automation-integration-2026-10-10-11-59)
topic: "Voice input (speech-to-text) for zigBrowser with whisper.cpp: codebase surface, per-platform mic capture, whisper.cpp build/models/latency, model management, privacy, and web-page mic"
tags: [research, codebase, voice, stt, whisper.cpp, microphone, agent-drawer, macos, windows, webview2, wkwebview, webkitgtk, miniaudio, model-management]
status: complete
last_updated: 2026-10-19
last_updated_by: Claude (voice-input STT track)
last_updated_note: "Includes the user's decision (via the coordinator) to start with the whisper MEDIUM model; exact file sizes and SHA-256 values read from the Hugging Face API. Follow-up 2026-10-19: user decisions recorded — the model is BUNDLED in the installer (no first-run download); Windows is covered by the Windows launch plan (thoughts/searchable/shared/plans/2026-10-19-windows-launch-tdd-plan.md, WS0-WS13; hosts win11-m8 and the physical Windows 10 machine) with a Win11 VM and a physical Windows 10 machine; Windows 10 must be supported."
prior_research: /home/maceo/ntm_Dev/zigBrowser/thoughts/searchable/shared/research/2026-10-19-voice-recognition-options.md
---

# Research: voice input (speech-to-text) for zigBrowser with whisper.cpp

**Date**: 2026-10-19 15:27 -04:00
**Git Commit**: `a69b459` (the worktree HEAD at write time; all `file:line` below are at this commit)
**Branch**: `zb-automation-integration-2026-10-10-11-59`
**Repository**: zigBrowser integration worktree, `/home/maceo/ntm_Dev/zb-automation-integration-2026-10-10-11-59`

Read-only research. Nothing was built, run, downloaded or committed. Web facts carry a link. Anything not confirmed is marked **UNVERIFIED**.

## Research Question

The user wants two plans: one for the browser's voice (text-to-speech, a sibling agent's track) and one for voice-to-text (this one). The user's words: "Mac and Windows are the 2 main target systems, Linux is my environment, not the primary target for users. I'm comfortable with shipping whisper.cpp and handling the model as part of the browser."

This document maps what exists today and what the outside world offers for:
1. the agent chat drawer's input path, and whether web-page fields could also receive dictated text;
2. the three platform backends and the build system's handling of C/C++ code;
3. microphone capture on macOS, Windows and Linux;
4. whisper.cpp models, sizes, licenses, acceleration, streaming and latency;
5. model management and the network decision it implies;
6. privacy and UX facts;
7. web-page microphone and Web Speech support in WebView2, WKWebView and WebKitGTK.

**User decisions received during research (via the coordinator, 2026-10-19):**
- "Let's start with the medium model (769MB)." The 769 M figure is Whisper medium's parameter count. The files are larger or smaller depending on precision; see section 4.1.
- **"Bundle in the installer."** (DECIDED 2026-10-19.) The medium model ships inside each installer. There is no first-run download, and dictation works offline from the first launch. Section 6 below records what this means; the plan's D5 and slice VSP carry it out.
- **Windows** (DECIDED 2026-10-19): the Windows launch plan exists at `thoughts/searchable/shared/plans/2026-10-19-windows-launch-tdd-plan.md` (rev 2, milestones WS0-WS13). It covers:
  - the test hosts and two-host gate (WS0, `:614`) and the native build (WS1, `:724`);
  - the Win32 drawer port (WS5, `:1148`) and the helper (WS11, `:1540`);
  - voice hooks (WS12, `:1587`) and packaging (WS13, `:1644`).
  Its hosts are the Win11 VM `win11-m8` (build and run host) and the physical Windows 10 machine `100.123.34.15` (`file-server-win-mac`, run-only, also a file server). Windows 10 must be supported.

## Summary

- **No voice code exists.** A case-insensitive grep of `src/` for `audio|microphone|mic|speech|whisper|pulse|pipewire|AVAudio|wasapi` finds nothing. The drawer plan lists voice under "What we are NOT doing" (`thoughts/searchable/shared/plans/2026-10-13-claude-agent-chat-drawer-tdd-plan.md:1097`).
- **The drawer is GTK/Linux only.** Its input is a `GtkTextView` named `zb-agent-input` (`src/agent_drawer.c:1241`). Text leaves the box only through `send_input` (`src/agent_drawer.c:881-898`), on Enter or the Send button. No code inserts text into the input programmatically today. The drawer and agent C files are compiled only in `configureGtkBackend` (`build.zig:1503-1533`).
- **Mac drawer:** the macOS plan's slice **MS7** builds a native AppKit drawer (`src/agent_drawer_mac.m`), after MS4 and MS5 (`thoughts/searchable/shared/plans/2026-10-14-14-30-macos-launch-tdd-plan.md:1183-1258, 1336-1351`). **Windows drawer:** at `a69b459` no committed plan covers it. The macOS plan says "Not building a Windows drawer / Windows automation parity (separate track)" (macOS plan `:373`), and the drawer plan excludes it (drawer plan `:1095`). Since 2026-10-19 the Windows launch plan covers it: the native Win32 drawer is its WS5 (`thoughts/searchable/shared/plans/2026-10-19-windows-launch-tdd-plan.md:1148`), with the voice hook `zb_drawer_set_draft` in WS12.1.
- **No backend handles microphone permission.** No `permission-request` handler and no `enable-media-stream` setting on GTK. No `requestMediaCapturePermissionForOrigin` on WKWebView; the only WKUIDelegate method is `createWebViewWithConfiguration` (`src/wkwebview_shim.m:564`). No `add_PermissionRequested` on WebView2; only `add_NavigationCompleted` (`src/webview2_shim.cpp:613`) and `add_WebMessageReceived` (`:647`).
- **macOS packaging has no audio keys.** `packaging/macos/entitlements.plist` has only `com.apple.security.network.client`, with the rule that a key is added only after the Mac build proves it is needed. `packaging/macos/Info.plist` has no `NSMicrophoneUsageDescription`.
- **No third-party C library is built today.** `build.zig.zon` has an empty `.dependencies` table, and no `third_party/` or `vendor/` directory exists. whisper.cpp would be the first.
- **macOS builds run natively per arch over SSH, then lipo** (`tests/mac/gate.sh`, `tests/mac/build-on-mac.sh:32-37`). **Windows builds run inside a Win11 KVM guest** with `-Dtarget=x86_64-windows-msvc` (`tests/guest/build-in-guest.sh`; the Windows launch plan's WS1 moves this onto its own build script and gate on the `win11-m8` VM). No Windows arm64 target exists in `build.zig`.
- **The agent egress allowlist covers only the agent sandbox.** `EGRESS_ALLOW = ("api.anthropic.com",)` (`agent/host/zb_agent_host/sandbox.py:51`) confines the helper and CLI through netd. The browser process has no allowlist and no downloader of its own. A browser-side model download would be a new product network destination, not a sandbox change. Since the user decided to bundle the model, the running browser needs no model download at all; only the release build fetches the file.
- **whisper.cpp v1.9.5** (2026-10-06) is MIT. OpenAI says the Whisper weights are MIT. Exact medium file sizes on Hugging Face: `ggml-medium.bin` 1,533,763,059 B, `ggml-medium-q8_0.bin` 823,369,779 B, `ggml-medium-q5_0.bin` 539,212,467 B (section 4.1).
- **Medium is heavy on CPU.** Published encoder times per 30 s window: about 1.9 s on an M1 Pro CPU, about 0.1-0.2 s on M2 Ultra / M4 Max with Metal, 4.4 s on a desktop Ryzen 5950X, and about 25 s on a Windows i5-1135G7 laptop. No Intel Mac medium figure was found (section 4.4).
- **Capture:** miniaudio (public domain or MIT-0) covers Core Audio, WASAPI, PulseAudio and ALSA in one C file. It reaches PipeWire through pipewire-pulse, and it can decode WAV files for headless tests.
- **Web pages:** WebView2 shows its default prompt when `PermissionRequested` is not handled. WKWebView returns `.prompt` when the delegate method is missing. WebKitGTK denies unhandled requests. Web Speech `SpeechRecognition` is unreliable or missing on all three engines. Page-level mic is a separate concern from drawer dictation (section 7).

## Detailed Findings

### 1. The drawer input path (Linux GTK, the only drawer today)

Widget and layout (`src/agent_drawer.c`, `build_panel`):
- The composer row is a horizontal `GtkBox` named `zb-agent-input-row`, spacing 6 (`:1234`).
- The input is a `GtkTextView` named `zb-agent-input` with the accessible name "Message Claude", wrap `GTK_WRAP_WORD_CHAR` (`:1241-1242`). It sits in a `GtkScrolledWindow`, 36 to 120 px tall (`:1235-1240`).
- The row packs, left to right: the input scroller (expands), `Send` (`zb-agent-send`) and `Stop` (`zb-agent-stop`, insensitive at start) (`:1244-1251`).
- Signals: `send` clicked calls `on_send_clicked`, `stop` clicked calls `on_stop_clicked`, and the input's `key-press-event` calls `on_input_key` (`:1278-1281`).

Submit chain:
- `on_input_key` (`:905-914`): Return, KP_Enter or ISO_Enter without Shift calls `send_input`. Shift+Enter inserts a newline.
- `send_input` (`:881-898`) reads the whole buffer, strips it, and for non-empty text calls `add_message(d, "user", text)`. It then calls `zb_agent_helper_send(d->win_id, text)` if the helper is configured, or reports `unavailable/runtime-missing`. Finally it clears the buffer (`:895`), the only programmatic write to the input.
- `zb_agent_helper_send` (`src/agent_helper.c:791`) queues the text, and `flush` (`src/agent_helper.c:234-262`) frames it with `zb_agent_out_prompt` (`src/agent_frames.zig:138`) and writes it to the helper's stdin.

Header and status (possible place for a recording indicator; what exists):
- The header box `zb-agent-header` holds the title "Claude Agent", a status `GtkLabel` `zb-agent-status` (initial "Not connected"), a "-" minimize button and an optional "Account" button (`:1203-1220`). `status_text()` maps states to "Starting…", "Ready", "Working…", "Stopped", "No token", "Unavailable" (`:783-790`).

E2E observability:
- Rows are `DRAWER <win> <kind> ...`, emitted by `drawer_row` (`:174-180`) through `zb_emit_protocol_row` under `--e2e-protocol`. Existing kinds include `tree`, `icon`, `status` (`:810`), `msg` (`:732`), `delta`, `scroll`, `textrect`, `anim`, `fold`.
- No row reports the input box's current text. A sent message appears as `DRAWER <win> msg user <text>` (`:732`), through `add_message` from `send_input`.
- There are no C or Zig hooks that set the input text or click Send. Tests drive the drawer with real X input on a private Xvfb (`tests/e2e/agent_drawer_test.py:85-87` types one key per character).
- Drawer e2e steps: `agent_drawer_icon_e2e`, `agent_drawer_e2e`, `agent_drawer_copy_e2e` (`build.zig:788-818`), all on `test_step` (`build.zig:1306-1308`). The pure-Zig unit test is `tests/agent_drawer_test.zig` (`build.zig:341-350`).

Portable logic:
- `src/agent_drawer.zig` holds gesture, clamp, ratios, persistence and text helpers, and is shared by design (macOS MS7 plans to reuse `agent_drawer.zig:16-181`).

Settings UI:
- No general settings or preferences window exists. The only secondary window is the Secrets window (`src/agent_secrets_window.c:603`, `zb_secrets_window_present` at `:711`), opened from the drawer's Account button (`src/agent_drawer.c:1191-1196`) or automatically on `no-token` (`:801-804`).

CLI flag pattern:
- `--media-source on|off` and `--agent-drawer on|off` are parsed in `src/cli.zig:204-213`, with env fallbacks `ZIGBROWSER_MEDIA_SOURCE` (`src/media_config.zig:23`) and `ZIGBROWSER_AGENT_DRAWER` (`src/agent_config.zig:20`). The drawer is gated to Linux on the Zig side (`src/app.zig:52-55`, `:341`).

### 2. Platform backends

Selection (`build.zig:1481-1501`): Linux uses `gtk_backend`, Windows `webview2_backend`, macOS `macos_backend`; anything else panics `NoBackendLinked`.

Linux, `configureGtkBackend` (`build.zig:1503-1533`):
- Compiles `webkit_shim.c` and `agent_drawer.c` (`-std=c11`) plus `agent_host.c`, `agent_helper.c`, `agent_secrets.c`, `agent_secrets_window.c` (`-std=gnu11`).
- Links `webkit2gtk-4.1`, `gtk+-3.0`, `gio-unix-2.0` via pkg-config.
- `webkit_shim.c` connects no `permission-request` signal and sets no `enable-media-stream`, `enable-webrtc` or `enable-mock-capture-devices`. Its per-window settings are only `javascript_can_open_windows_automatically`, the hardware policy and the media-source switch (`src/webkit_shim.c:1290-1296`).
- The drawer is attached in `zb_window_new` when it is on: `zb_drawer_attach(...)` (`src/webkit_shim.c:1285`), otherwise the view is added directly (`:1287`).

macOS, `configureMacosBackend` (`build.zig:1560-1570`):
- Compiles `src/wkwebview_shim.m` with `-fobjc-arc`; links WebKit, Cocoa, Foundation.
- `ZBWindowHost` adopts `WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandlerWithReply` (`src/wkwebview_shim.m:242`). The window's `contentView` is the WKWebView itself (`:379`); there is no native panel.
- `newConfiguredWebView` (`:383`) sets only `javaScriptCanOpenWindowsAutomatically` and one user script. No media-capture delegate method exists.
- The app starts in `zb_app_run` (`NSApplication sharedApplication`, `ZBAppHost` init, `[application run]`).

Windows, `configureWebView2Backend` (`build.zig:1535-1558`):
- Compiles `src/webview2_shim.cpp` with `-std=c++17` against WebView2 headers whose paths come from `-Dwebview2_include`, `-Dwebview2_lib`, `-Dwinrt_include` (`build.zig:111-130`), checked by `CheckWebView2SdkStep` (`build.zig:16-77`).
- Links `WebView2LoaderStatic`, `ole32`, `oleaut32`, `user32`, `gdi32`, `shell32`, `advapi32`.
- `zb_app_run` calls `CoInitializeEx(COINIT_APARTMENTTHREADED)` (`src/webview2_shim.cpp:713`), creates the window and the environment (`:692`), then runs the message loop. Only two WebView2 events are registered (`:613`, `:647`). There is no native non-web UI.

Platform abstraction:
- `PagePort` (`src/automation/page_port.zig:181-185`) has one real adapter, GTK (`src/automation_gtk_port.zig`, `supported = builtin.os.tag == .linux` at `:22`).
- `src/automation_platform.zig:13-17` names the backends `webview2`, `webkitgtk`, `wkwebview`.
- There is no audio or speech abstraction anywhere.

### 3. Build system facts relevant to vendoring whisper.cpp

- `build.zig.zon:34-64`: empty `.dependencies`. `.paths` = `build.zig`, `build.zig.zon`, `src`, `tests`. `minimum_zig_version = "0.16.0"`.
- No third-party C/C++ library is compiled by `zig build` today. The only C files are the repo's shims and two libsecret test C files (`build.zig:460-461`, `:479-480`).
- **macOS:** no universal step in `zig build`. `tests/mac/build-on-mac.sh` tars the sources and runs `zig build` natively on each Mac with no `-Dtarget`, because passing `-Dtarget` stops Zig from auto-detecting the Xcode SDK (`tests/mac/build-on-mac.sh:32-37`). `tests/mac/gate.sh` builds x86_64 on `ZB_MAC_HOST` (default `maceojourdan@100.92.212.47`, `:24`) and arm64 on `ZB_MAC_ARM_HOST` (`:25`, fails "NOT RUN" when unset, `:44-49`), then lipos on the Intel host (`:74-77`). The component inventory is `packaging/macos/universal_components.json` (browser only).
- **Cross-check from Linux:** `cross-check` emits objects for `aarch64-macos`, `x86_64-macos` and `x86_64-windows-gnu` with no link and checks `zb_*` symbol parity with `tools/check_cross_symbols.py` (`build.zig:243-277`).
- **Windows:** real builds happen in the Win11 KVM guest over SSH (`tests/guest/build-in-guest.sh`, default host `maceo@100.103.8.90`, key `/home/maceo/vms/win11-m8/zb_guest_key`; WebView2 NuGet `1.0.3967.48`, Windows Kits `10.0.26100.0`). The M8 plan says "No cross-compile-from-Linux build path — COM/MSVC import-lib linkage forces an in-guest build" (`thoughts/searchable/shared/plans/2026-06-01-18-16-ENG-0006-tdd-windows-webview2-backend-m8.md`, "What We're NOT Doing"). No arm64 Windows target appears in `build.zig`.
- **Gates:** `zig build test` aggregates everything (`build.zig:1245`). Python e2e steps map exit 77 to success in most wrappers (e.g. `build.zig:642`). `guardDisplay` makes every step wait on `tools/display_guard.py`, which refuses a display that is not a private Xvfb (`build.zig:1456-1464`). macOS verification is `mac-gate` (`build.zig:180-181`), outside `zig build test`.
- **Runtime flags, not build options:** `b.option` exists only for the WebView2 paths and `site_config` (`build.zig:111-135`). The media source is a runtime flag.

### 4. whisper.cpp

#### 4.1 Models and exact sizes (the user chose medium)

Read on 2026-10-19 from the Hugging Face API for `ggerganov/whisper.cpp` (repo revision `5359861c739e955e79d9a303bcbc70fb988958b1`, last modified 2024-10-29, license tag `mit`): `https://huggingface.co/api/models/ggerganov/whisper.cpp/tree/main`. The LFS `oid` is the file's SHA-256.

| File | Bytes | Approx. | SHA-256 |
|---|---:|---|---|
| `ggml-medium.bin` (f16) | 1,533,763,059 | 1.53 GB / 1.43 GiB | `6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208` |
| `ggml-medium-q8_0.bin` | 823,369,779 | 823 MB / 785 MiB | `42a1ffcbe4167d224232443396968db4d02d4e8e87e213d3ee2e03095dea6502` |
| `ggml-medium-q5_0.bin` | 539,212,467 | 539 MB / 514 MiB | `19fea4b380c3a618ec4723c3eef2eb785ffba0d0538cf43f8f235e7b3b34220f` |
| `ggml-medium.en.bin` | 1,533,774,781 | 1.53 GB | `cc37e93478338ec7700281a7ac30a10128929eb8f427dda2e865faa8f6da4356` |
| `ggml-medium.en-q8_0.bin` | 823,382,461 | 823 MB | `43fa2cd084de5a04399a896a9a7a786064e221365c01700cea4666005218f11c` |
| `ggml-medium.en-q5_0.bin` | 539,225,533 | 539 MB | `76733e26ad8fe1c7a5bf7531a9d41917b2adc0f20f2e4f5531688a8c6cd88eb0` |
| `ggml-medium-encoder.mlmodelc.zip` (Core ML, optional) | 567,829,413 | 568 MB | `79b0b8d436d47d3f24dd3afc91f19447dd686a4f37521b2f6d9c30a642133fbd` |

For comparison (same listing): `ggml-tiny.en.bin` 77,704,715 B; `ggml-base.en.bin` 147,964,211 B; `ggml-small.bin` 487,601,967 B; `ggml-small-q8_0.bin` 264,464,607 B; `ggml-large-v3-turbo.bin` 1,624,555,275 B; `ggml-large-v3-turbo-q8_0.bin` 874,188,075 B; `ggml-large-v3-turbo-q5_0.bin` 574,041,195 B.

- The whisper.cpp README gives medium as 1.5 GiB on disk and **~2.1 GB RAM** for f16 ([README](https://github.com/ggml-org/whisper.cpp/blob/master/README.md)). RAM for the quantized medium files is UNVERIFIED (it should be lower, not measured).
- Multilingual unless the name has `.en` ([models README](https://github.com/ggml-org/whisper.cpp/blob/master/models/README.md)). The "99 languages" count was not confirmed in the fetched pages (UNVERIFIED). OpenAI's README points to `tokenizer.py` for the language list ([openai/whisper](https://github.com/openai/whisper)).
- The models README lists SHA-1 values. The upstream download script `models/download-ggml-model.sh` does **not** verify a checksum ([script](https://raw.githubusercontent.com/ggml-org/whisper.cpp/master/models/download-ggml-model.sh)). A browser manager must pin and check SHA-256 itself.
- Quantized medium RAM and accuracy loss: no measured WER comparison of medium f16 vs q8_0 vs q5_0 was found (UNVERIFIED). q8_0 is generally treated as near-lossless; that is common knowledge, not a cited measurement.

#### 4.2 Licensing
- whisper.cpp: MIT ([README badge](https://github.com/ggml-org/whisper.cpp/blob/master/README.md); the LICENSE file text itself was not read, so the exact wording is UNVERIFIED).
- OpenAI Whisper: "Whisper's code and model weights are released under the MIT License" ([openai/whisper](https://github.com/openai/whisper), [LICENSE](https://raw.githubusercontent.com/openai/whisper/main/LICENSE), "Copyright (c) 2022 OpenAI").
- The ggml conversions on Hugging Face carry the `mit` license tag (API read above). No separate license statement for the conversions was found beyond that tag.
- Silero VAD: MIT ([LICENSE](https://raw.githubusercontent.com/snakers4/silero-vad/master/LICENSE)). The ggml VAD models are at [ggml-org/whisper-vad](https://huggingface.co/ggml-org/whisper-vad), license MIT.
- miniaudio: "public domain or the 'MIT No Attribution' license" ([README](https://github.com/mackron/miniaudio)).
- SDL2 (used by the upstream `stream` example): zlib license from general knowledge, UNVERIFIED. It is not needed if miniaudio is used.

#### 4.3 Acceleration and building for the targets
- **Releases:** v1.9.5 (2026-10-06), v1.9.4 (2026-09-11). The prerelease `b5454` ships `whisper-bin-win-cpu-arm64.zip`, `whisper-bin-x64.zip`, CUDA builds and an xcframework ([releases API](https://api.github.com/repos/ggml-org/whisper.cpp/releases?per_page=3)). So upstream builds Windows arm64 CPU binaries (with CMake).
- **Apple Silicon:** "the inference runs fully on the GPU via Metal". `GGML_METAL` is on by default on Apple ([README](https://github.com/ggml-org/whisper.cpp/blob/master/README.md), [ggml CMakeLists](https://raw.githubusercontent.com/ggml-org/whisper.cpp/master/ggml/CMakeLists.txt)).
- **Metal shader embedding:** `GGML_METAL_EMBED_LIBRARY` defaults on. It places the processed `.metal` source in a `__DATA,__ggml_metallib` section through an assembly `.incbin`, and the source is compiled at runtime with `newLibraryWithSource`, so no `xcrun metal` is needed at build time ([ggml-metal CMakeLists](https://raw.githubusercontent.com/ggml-org/whisper.cpp/master/ggml/src/ggml-metal/CMakeLists.txt), [ggml-metal-device.m](https://raw.githubusercontent.com/ggml-org/whisper.cpp/master/ggml/src/ggml-metal/ggml-metal-device.m)). A `zig build` port must reproduce the embed step (flatten the includes, then embed). Doing that in `build.zig` is UNVERIFIED.
- **Intel Mac:** the Metal device code gates features by GPU family; flash attention needs Apple7-class hardware. Whether Metal is usable or fast on Intel Macs with AMD or Intel GPUs is UNVERIFIED. Plan on the CPU path (AVX2 plus Accelerate; `GGML_ACCELERATE` and `GGML_BLAS` default on for Apple).
- **Core ML (optional):** `-DWHISPER_COREML=1` plus `ggml-<model>-encoder.mlmodelc`. Prebuilt `.mlmodelc.zip` files exist on Hugging Face (medium: 568 MB). "The first run on a device is slow, since the ANE service compiles the Core ML model."
- **x86 CPU:** `GGML_NATIVE` defaults on (off when cross-compiling) and tunes for the build machine only. AVX/AVX2/AVX512 are off unless `GGML_NATIVE` is off and they are set. Runtime CPU dispatch (`GGML_CPU_ALL_VARIANTS`) needs `GGML_BACKEND_DL`, which needs shared libraries ([ggml src CMakeLists](https://raw.githubusercontent.com/ggml-org/whisper.cpp/master/ggml/src/CMakeLists.txt)). A single static binary therefore targets one baseline ISA.
- **Windows GPU options:** Vulkan (`-DGGML_VULKAN=1`), CUDA, OpenVINO, BLAS. Each adds SDK or runtime dependencies.
- **Zig builds of whisper.cpp:** no maintained one found. Candidates are `kassane/whisper.cpp` (a fork with `build.zig` on a `zig-pkg` branch; Zig version unknown) and stale or incomplete bindings ([kassane/whisper.cpp](https://github.com/kassane/whisper.cpp), [whisper.zig](https://github.com/XandeCoding/whisper.zig), [a 2024 note](https://notes.billmill.org/programming/zig/A_half-assed_attempt_to_package_whisper.cpp_for_zig.html)). A port written for this repo is the likely path (UNVERIFIED effort).

#### 4.4 Streaming, latency and the medium model

API:
- Input is 16 kHz float PCM (`WHISPER_SAMPLE_RATE 16000`, `whisper_full(ctx, params, samples, n_samples)`) ([whisper.h](https://raw.githubusercontent.com/ggml-org/whisper.cpp/master/include/whisper.h)).
- Callbacks: `new_segment_callback`, `progress_callback`, `encoder_begin_callback` (return false to abort), `abort_callback`. `whisper_full` is not thread-safe for one context. A per-token partial callback was not seen (UNVERIFIED).
- VAD: `whisper_full_params.vad`, `vad_model_path`, `vad_params`, plus `whisper_vad_*` functions; `_no_reset` is suggested for streaming (same header). VAD models silero v5.1.2 and v6.2.0 come from `ggml-org/whisper-vad`.
- The `stream` example is "a naive example" using SDL2, `--step 500 --length 5000` for a sliding window, or `--step 0` for VAD mode ([stream README](https://raw.githubusercontent.com/ggml-org/whisper.cpp/master/examples/stream/README.md)).
- **Every call pays a 30 s encoder window by default.** `WHISPER_CHUNK_SIZE` is 30. A 3 s utterance is padded to 30 s unless `audio_ctx` is lowered. `audio_ctx` ("0 = use default") is listed with options that "can significantly reduce the quality". Users reported about 2x speed at half context and instability below about 512 (about 10 s) on small models ([issue #137](https://github.com/ggml-org/whisper.cpp/issues/137)). Behavior on medium is UNVERIFIED.

Medium encoder benchmarks (ms per 30 s encoder pass; [issue #89](https://github.com/ggml-org/whisper.cpp/issues/89) unless noted; mostly older builds):

| Hardware | Config | Medium encoder |
|---|---|---|
| M1 Pro | NEON + BLAS, CPU, 8 threads | 1,928 ms |
| Mac mini M1 | CPU, 4 threads | 3,980 ms |
| M2 Ultra | Metal, FA off; f16 / q8_0 / q5_0 | 122.6 / 131.0 / 140.6 (units not stated; likely ms; [bench mirror](https://huggingface.co/spaces/Xenobd/whisper.cpp/commit/d4f72cd38997a79451851f0eac3ac336fb83338e)) |
| M4 Max | Metal, FA off; f16 / q8_0 | 208.5 / 212.9 (same source) |
| M1 Ultra | Core ML + Metal | ~347 ms (same source) |
| Ryzen 9 5950X (desktop) | AVX2, 8 threads | 4,404 ms |
| Ryzen 9 3900X (desktop) | AVX2, 8 threads | 9,610 ms |
| Ryzen 5 4500U (laptop) | 6 threads, medium.en | 19,673 ms |
| i5-1135G7 (Windows 10 laptop) | AVX2, CPU only, 8 threads | encoder 24,890 ms, decoder 10,958 ms |

What these numbers imply (estimates, UNVERIFIED until measured on the real hosts):
- **Apple Silicon with Metal:** medium should be well under real time for short dictation. A base M1 will be slower than the Ultra/Max rows (no base-M1 Metal medium row was found).
- **Intel Mac (CPU, no Metal assumed):** the Intel host's CPU model is not recorded in the repo. A 4- to 8-core Intel laptop or iMac lands between the 5950X desktop (4.4 s) and the thin-laptop rows (20-25 s) per 30 s window, plus decoding. Expect **several seconds to tens of seconds after the user stops speaking**, unless `audio_ctx` is lowered or a quantized file is faster there.
- **Windows CPU-only:** the only Windows row (i5-1135G7) is about 25 s for the encoder alone per 30 s window. Medium on a typical Windows laptop CPU is far from real time.
- **Quantized on CPU:** whether q8_0 or q5_0 medium beats f16 on AVX2 is UNVERIFIED. On Metal (M2 Ultra) the quantized files were slightly slower than f16. One report on an old SSE4.2-only CPU found q5_0 about 5x slower than q8_0 ([discussion #3752](https://github.com/ggml-org/whisper.cpp/discussions/3752)); it does not transfer to AVX2.
- **Live partial text with medium on CPU is not realistic.** Batch-after-release (push-to-talk or VAD end-of-speech) is the shape the numbers support. `scripts/bench.py` writes `benchmark_results.csv` for measuring on the real hosts ([bench.py](https://raw.githubusercontent.com/ggml-org/whisper.cpp/master/scripts/bench.py)).

Streaming alternative: sherpa-onnx (Apache-2.0) has true streaming models (Zipformer and others), Silero VAD and a C API, on Linux, macOS and Windows x64/arm64 ([README](https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/master/README.md)). Model licenses vary (UNVERIFIED per model). The user chose whisper.cpp; sherpa-onnx is noted only as the streaming fallback.

### 5. Microphone capture per platform

#### 5.1 macOS
- **Info.plist:** `NSMicrophoneUsageDescription` "is required if your app uses APIs that access the device's microphone" ([Apple](https://developer.apple.com/documentation/bundleresources/information-property-list/nsmicrophoneusagedescription)). Without the key (and, on macOS, the entitlement) before using a capture device, "the system terminates your app" ([Requesting authorization](https://developer.apple.com/documentation/avfoundation/requesting-authorization-to-capture-and-save-media)).
- **Entitlement:** `com.apple.security.device.audio-input`: "the app may record audio using the built-in microphone and access audio input using Core Audio", under Hardened Runtime > Resource Access ([Apple](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.audio-input)). App Sandbox uses `com.apple.security.device.microphone` (forum and third-party evidence; which key applies to which signing mode is UNVERIFIED by Apple text) ([forum 741303](https://developer.apple.com/forums/thread/741303), [Unity doc](https://docs.unity.com/ja-jp/vivox-core/developer-guide/macos/macos-requirements)). zigBrowser does not use App Sandbox (macOS plan MS6 uses Seatbelt for the helper only).
- **TCC API:** `AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio`, then `requestAccessForMediaType:completionHandler:`. The request raises an exception without a usage string. It does not block. Until permission is granted, capture delivers silence ([requestAccess](https://developer.apple.com/documentation/avfoundation/avcapturedevice/requestaccess(for:completionhandler:))).
- **Reset for tests:** `tccutil reset Microphone <bundle-id>` ([Apple](https://developer.apple.com/documentation/xcode/resetting-access-to-protected-resources-in-macos)). The bundle id is `com.cosmichq.zigBrowser` (`packaging/macos/Info.plist`).
- **Attribution and signing (forum and issue evidence, UNVERIFIED by Apple):** a tool launched from Terminal is attributed to Terminal (the "responsible process") ([VS Code #307364](https://github.com/microsoft/vscode/issues/307364)). AVFoundation command-line tools crashed over SSH without an embedded Info.plist ([forum 111100](https://developer.apple.com/forums/thread/111100)). TCC needs the usage string plus a valid signature, even ad-hoc ([t3code #728](https://github.com/pingdotgg/t3code/issues/728)). So **live-mic tests need a signed `.app` launched in the user's GUI session**, not a bare binary over SSH. On the Intel Mac that runs into the open MS1b crash of the ad-hoc-signed x86_64 binary (macOS plan `:565-591`).
- **Capture API:** the common pattern is an `AVAudioEngine` input-node tap at the hardware format plus `AVAudioConverter` (`convert(to:error:withInputFrom:)`) to 16 kHz mono float. Route changes (for example AirPods) can change the rate, so the converter is rebuilt ([AVAudioConverter](https://developer.apple.com/documentation/avfaudio/avaudioconverter), [Swift forums](https://forums.swift.org/t/swift-avaudioengine-airpod-convert-samplerate/34243)). Alternatively miniaudio's Core Audio backend. Its manual warns that runtime framework linking may fail notarization; use `MA_NO_RUNTIME_LINKING` and link the frameworks ([miniaudio manual](https://miniaud.io/docs/manual/index.html)).

#### 5.2 Windows
- **WASAPI:** `IAudioClient::Initialize` in shared mode with `AUDCLNT_STREAMFLAGS_EVENTCALLBACK`, and `AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM` (+ `SRC_DEFAULT_QUALITY`) to get the engine to resample to 16 kHz mono ([stream flags](https://learn.microsoft.com/en-us/windows/win32/coreaudio/audclnt-streamflags-xxx-constants), [Initialize](https://learn.microsoft.com/en-us/windows/win32/api/audioclient/nf-audioclient-iaudioclient-initialize)). The shim already initializes COM as STA (`src/webview2_shim.cpp:713`); capture would run on its own thread.
- **Privacy settings:** Settings > Privacy & security > Microphone has a "Let desktop apps access your microphone" switch for unpackaged desktop apps. Microsoft says desktop apps "don't use Windows privacy permission prompts" and may not be listed ([Windows desktop apps and privacy](https://support.microsoft.com/topic/8b3b13bc-d8ff-5460-8423-7d5d5c1f6665), [camera and microphone privacy](https://support.microsoft.com/en-us/windows/windows-camera-microphone-and-privacy-a83257bc-e990-d54a-d212-b5e41beba857)). So an MSI-installed zigBrowser gets **no OS prompt**. If the switch is off, capture fails or returns silence.
- **What a denial returns is UNVERIFIED.** `E_ACCESSDENIED` is not in the documented return codes for `Initialize` or `IMMDevice::Activate`. Real-world reports show 0x80070005 "access denied" ([Audacity](https://manual.audacityteam.org/man/error_opening_sound_device.html)). Handle both an error HRESULT and an all-zero stream.
- **Packaged (MSIX):** declare the `microphone` capability. Apps "must handle the case in which the user has disabled the microphone" ([capability declarations](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/app-capability-declarations)). zigBrowser ships an MSI today (`packaging/windows/zigBrowser.wxs`), so the unpackaged rules apply.
- **Upcoming changes:** an Insider build (26340.9233, reported 2026-08-26) adds per-app microphone switches for desktop apps, possibly listing unsigned apps under other names ([BleepingComputer](https://www.bleepingcomputer.com/news/microsoft/microsoft-tests-new-privacy-controls-for-windows-11-desktop-apps/)). Microsoft also announced consent prompts ("User Transparency and Consent") in Feb 2026 ([The Register](https://www.theregister.com/2026/02/10/microsoft_windows_security/)). Timing for stable Windows is UNVERIFIED.
- **Test hosts:** at `a69b459`, the Win11 KVM guest builds and runs the MSI gate (`packaging/windows/gate.ps1`). Whether it has any audio input device is UNVERIFIED (a QEMU guest usually has none unless one is configured). The Windows launch plan names two hosts:
  - the Win11 VM `win11-m8`;
  - the physical Windows 10 machine `100.123.34.15` (`file-server-win-mac`), whose OpenSSH Server is not yet running per that plan.

  Its provisioning notes (`:364-502`) say:
  - the `win11-m8` domain defines an `ich9` sound device with a SPICE audio backend;
  - whether Windows shows a capture endpoint, and whether `virt-viewer` forwards a microphone, is unverified (item 12);
  - the physical machine is to get a microphone and the per-user desktop-apps microphone switch for its test user `zbtest` (item 10).

  So the only host expected to have a working microphone is the physical Windows 10 machine. No Windows arm64 machine exists.
- **Windows 10 (must be supported, user decision 2026-10-19):**
  - The per-app desktop microphone switches above are reported only for a Windows 11 Insider build. On Windows 10 the user-facing controls are the device-wide microphone switch and the desktop-apps switch (general knowledge; exact wording per Windows 10 build UNVERIFIED).
  - Microsoft's WASAPI flag pages fetched here do not state a Windows 11 requirement for `AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM` or event-driven shared mode. Behavior on specific Windows 10 builds is UNVERIFIED.
  - Windows 10 reached end of mainstream support on 2025-10-14 (general knowledge, not fetched here; UNVERIFIED).

#### 5.3 Linux (development only)
- miniaudio's PulseAudio backend reaches PipeWire through pipewire-pulse. miniaudio has no built-in PipeWire backend ([discussion 711](https://github.com/mackron/miniaudio/discussions/711)).
- `pa_simple` gives blocking capture with a fixed sample spec ([pa_simple](https://www.freedesktop.org/software/pulseaudio/doxygen/simple.html)).
- Test feeds: `pw-play` into a null sink and record its monitor ([pw-cat](https://docs.pipewire.org/page_man_pw-cat_1.html)). A null sink or virtual source recipe is community-documented (UNVERIFIED). The simplest headless path is to skip the OS and decode a WAV with `ma_decoder_init_file` at 16 kHz mono f32 ([manual](https://miniaud.io/docs/manual/index.html)).

#### 5.4 miniaudio (cross-platform option)
- One file (`miniaudio.h`), public domain or MIT-0. Backends: WASAPI, DirectSound, WinMM, Core Audio, ALSA, PulseAudio, JACK, a Null backend and others ([README](https://github.com/mackron/miniaudio)).
- It converts to the requested capture format (`ma_format_f32`, 1 channel, 16000). The default resampler quality is UNVERIFIED (the linear resampler is the fastest and lowest-quality).
- Null-backend capture behavior (silence) is UNVERIFIED.
- It also does playback, which the text-to-speech plan needs too.

### 6. Model management and the network decision

What exists:
- No downloader in the browser process. A `std.http.Client` transport exists in `src/sequences.zig:359-380`, but it is built only into tests and a tool (`build.zig:1365-1388`), not the browser binary.
- `src/atomic_file.zig` provides atomic file writes (used by `agent_drawer.zig` persistence).
- The agent sandbox's egress allowlist is `("api.anthropic.com",)` (`agent/host/zb_agent_host/sandbox.py:51`), with `platform.claude.com` added only for sign-in (`:56`). netd refuses any CONNECT not to an allowed host (`agent/host/zb_agent_host/netd.py:122-142`). This confines the agent helper and CLI. It does not apply to the browser process, which loads arbitrary pages.
- The agent CLI runs with `DISABLE_AUTOUPDATER=1` (`agent/host/zb_agent_host/options.py:95`).
- Today's macOS bundle ships only the browser binary (`packaging/macos/universal_components.json:15-18`).

What this means as facts, not decisions:
- A model download fetched by the browser process adds a new outbound destination for the product (Hugging Face, or a mirror the project controls). It would not pass through netd unless designed to.
- The agent must never trigger it. The sandboxed helper cannot reach Hugging Face by policy, and the drawer plan keeps the agent away from browser-privileged surfaces.
- Who decides: adding a product network destination and its consent wording is a user decision. The code can make it explicit (a one-time consent with the size and destination shown) and testable (a fake HTTPS host).
- Storage location conventions (general knowledge, UNVERIFIED as zigBrowser policy): macOS `~/Library/Application Support/<app>/`, Windows `%LOCALAPPDATA%\<app>\`, Linux `$XDG_DATA_HOME/<app>/` (the repo already resolves `XDG_DATA_HOME` for the agent home, `src/app.zig:56-57`).
- Size facts: medium q8_0 is 823 MB and f16 is 1.53 GB. Bundling either makes each installer roughly that much bigger for every user, including users who never dictate. Whether WiX/MSI has a hard cabinet or package size limit at this scale is UNVERIFIED.

**User decision (2026-10-19): bundle the model in the installer.** Facts that bear on that, from the codebase:
- macOS: the component inventory `packaging/macos/universal_components.json:15-18` lists only the browser and an empty `resources` list. Its comment says the empty list is accepted by the MS1 phase gate only for that exact browser-only shape, and that non-executable resources are checked by the two-tree `resource_compat` oracle first exercised at MS5.1c (macOS plan `:486-506`, `:1040-1067`). A bundled model would be the kind of non-Mach-O resource that oracle compares across the arm64 and x86_64 trees. Since the model file has no architecture, the two copies are expected to be byte-identical.
- macOS packaging: `packaging/macos/build-dmg.sh` builds the `.app`, ad-hoc signs it with `codesign --deep` (`:90` per the macOS plan) and makes the DMG with `hdiutil`. Developer ID signing and notarization are MS9. Apple's notarization upload limit and time for a ~1 GB DMG are UNVERIFIED.
- Windows packaging: `packaging/windows/zigBrowser.wxs` and `build-msi.ps1` build the MSI; `gate.ps1` installs per-user and checks it.
- Linux packaging: `packaging/linux/build-deb.sh` and `control.in`; `gate.sh` installs the .deb in a container.
- With the model bundled, the network facts above (downloader, consent, destination host) no longer apply to first use. They would apply again only to an optional later update path.

### 7. Privacy and UX facts

- whisper.cpp runs fully locally. Audio never leaves the device unless code sends it.
- Nothing in the drawer persists the input box's text. Chat transcripts live in the agent's own config (drawer plan S5.4). Dictated text, once in the input box, is the user's draft, and it is sent only when the user presses Enter or Send (`src/agent_drawer.c:905-914`, `:1278`).
- On macOS, the system shows its own orange microphone-in-use indicator in the menu bar while any app records (general knowledge, UNVERIFIED by a fetched Apple page). Windows shows a microphone icon in the taskbar notification area while an app uses the mic (general knowledge, UNVERIFIED).
- The drawer already has a status label (`zb-agent-status`) whose text changes by state (`src/agent_drawer.c:783-790`). This is where an in-app state could be shown; no recording state exists.

### 8. Web pages: getUserMedia, Web Speech, and filling page fields

Permission APIs:
- **WebView2:** `ICoreWebView2PermissionRequestedEventArgs` has `PermissionKind`, `Uri`, `IsUserInitiated`, `State` and `GetDeferral`. With `COREWEBVIEW2_PERMISSION_STATE_DEFAULT`, "the default browser behavior is used, which normally prompt users for decision". `COREWEBVIEW2_PERMISSION_KIND_MICROPHONE` is audio capture ([event args](https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/win32/icorewebview2permissionrequestedeventargs), [IDL](https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/win32/webview2-idl?view=webview2-1.0.4258.31&accept=text/markdown)). A state set in the handler is saved in the profile by default (`SavesInProfile`, [args3](https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/win32/icorewebview2permissionrequestedeventargs3)). `ICoreWebView2Profile4::SetPermissionState` and `GetNonDefaultPermissionSettings` manage saved state ([Profile4](https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/win32/icorewebview2profile4)). Since zigBrowser registers no handler, WebView2's default prompt is what a page gets today (inferred from the docs; not run).
- **WKWebView:** `webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:` (macOS 12+). "If you don't implement this method in your delegate, the system returns `WKPermissionDecision.prompt`" ([Apple JSON doc](https://developer.apple.com/tutorials/data/documentation/webkit/wkuidelegate/webview(_:requestmediacapturepermissionfor:initiatedbyframe:type:decisionhandler:).json)). The host still needs the usage string and entitlement (section 5.1).
- **WebKitGTK:** unhandled `WebKitUserMediaPermissionRequest` is denied by default; `enable-media-stream` is documented with default FALSE ([class](https://webkitgtk.org/reference/webkit2gtk/stable/class.UserMediaPermissionRequest.html), [setting](https://webkitgtk.org/reference/webkit2gtk/stable/property.Settings.enable-media-stream.html)). The default on 2.54 is UNVERIFIED.

Web Speech `SpeechRecognition`:
- **WebView2:** a Microsoft engineer said `webkitSpeechRecognition` works from runtime 93.0.954.0 ([#1613](https://github.com/MicrosoftEdge/WebView2Feedback/issues/1613)). It relies on Microsoft speech services and regressed with a "network" error in Runtime 153.0.4234.48 (open bug [#5724](https://github.com/MicrosoftEdge/WebView2Feedback/issues/5724), opened 2026-09-21). Audio goes to Microsoft servers in that path (per the reporter's logs).
- **WKWebView (macOS):** exposed; uses Apple's Speech framework and may need `NSSpeechRecognitionUsageDescription`; may use Apple servers. A working third-party macOS embedder was not confirmed (UNVERIFIED) ([WebKit 239816](https://bugs.webkit.org/show_bug.cgi?id=239816), [SFSpeechRecognizer](https://developer.apple.com/documentation/speech/sfspeechrecognizer.md)).
- **WebKitGTK:** not shipped. Bugs 251939 (NEW, prototype with whisper.cpp `base.en` and `WEBKIT_WHISPER_MODEL_PATH`) and 260709 (NEW) ([251939](https://bugs.webkit.org/show_bug.cgi?id=251939), [260709](https://bugs.webkit.org/show_bug.cgi?id=260709)).
- **Electron** never supported it ("not a bug so there will be no fix") ([electron #46143](https://github.com/electron/electron/issues/46143)).
- No existing project was found that polyfills `SpeechRecognition` with a native engine over a script message handler (UNVERIFIED as absent). `tauri-plugin-stt` uses `whisper-rs` and `cpal` but does not polyfill ([docs.rs](https://docs.rs/tauri-plugin-stt)).

Filling a focused page field with dictated text:
- `document.execCommand('insertText', false, text)` inserts at the caret, replaces the selection, and keeps the undo stack. MDN marks `execCommand` "Avoid using this feature in new projects" ([MDN](https://developer.mozilla.org/en-US/docs/Web/API/Document/execCommand)). Behavior on contenteditable and React inputs is UNVERIFIED. For React-controlled inputs, the known workaround is the prototype value setter plus a bubbling `input` event ([Cory Rylan](https://coryrylan.com/blog/trigger-input-updates-with-react-controlled-inputs), [React #10135](https://github.com/facebook/react/issues/10135)).
- OS-level text injection: Windows `SendInput` (fails silently under UIPI) ([SendInput](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput)); macOS `NSTextInputClient insertText:replacementRange:` (page not rendered; UNVERIFIED).
- zigBrowser already has a native text-input path on Linux for automation (`gdk_event_new` + `gtk_main_do_event`, `src/webkit_shim.c:3373` per the macOS plan's key discoveries), and the PagePort has a native text method (`src/automation/page_port.zig`). Whether it is safe to reuse for user dictation (it is an automation surface) is a design question, not researched here.

## Code References

- `src/agent_drawer.c:881-898` — `send_input`: the only reader and the only clearer of the input buffer.
- `src/agent_drawer.c:905-914` — `on_input_key`: Enter sends, Shift+Enter is a newline.
- `src/agent_drawer.c:1234-1251` — the composer row: input scroller, Send, Stop.
- `src/agent_drawer.c:1278-1281` — signal wiring for Send, Stop, unread and the input key handler.
- `src/agent_drawer.c:174-180` — `drawer_row`, the `DRAWER` e2e row emitter; `:732` the `msg` row.
- `src/agent_drawer.c:783-810` — status text and the `status` row.
- `src/agent_drawer.c:1203-1220` — the header (title, status label, "-", Account).
- `src/agent_secrets_window.c:603`, `:711` — the only secondary window.
- `src/agent_helper.c:791`, `:234-262` — prompt queueing and framing.
- `src/webkit_shim.c:1281-1296` — window creation, drawer attach, settings applied.
- `src/wkwebview_shim.m:242`, `:379`, `:383`, `:564` — macOS window host, content view, configuration, only UIDelegate method.
- `src/webview2_shim.cpp:613`, `:647`, `:692`, `:713` — the two events, environment creation, COM STA init.
- `build.zig:1481-1570` — backend selection and the three configure functions.
- `build.zig:243-277` — `cross-check`.
- `build.zig:1245`, `:1306-1308`, `:1456-1464` — `test` step, drawer e2e registration, display guard.
- `build.zig.zon:34-64` — empty dependencies.
- `tests/mac/gate.sh:24-25`, `:44-49`, `:74-77` — Mac hosts, fail-closed, lipo.
- `tests/mac/build-on-mac.sh:32-37` — native build, no `-Dtarget`.
- `tests/guest/build-in-guest.sh` — Win11 guest build.
- `packaging/macos/entitlements.plist`, `packaging/macos/Info.plist`, `packaging/macos/universal_components.json:15-18`.
- `agent/host/zb_agent_host/sandbox.py:51`, `:56` — agent egress allowlists.
- `src/cli.zig:204-213` — `--media-source`/`--agent-drawer` flag parsing pattern.
- `src/app.zig:52-55`, `:341` — Linux-only agent gates.

## Architecture Documentation

- **One C ABI, three shims.** `src/webkit_shim.h` is shared. Zig code calls the shim through `@cImport` (`src/webkit.zig`). Platform-neutral logic lives in Zig, toolkit glue in C/ObjC/C++ (the drawer splits exactly this way: `agent_drawer.zig` logic, `agent_drawer.c` GTK glue).
- **Privileged native UI is isolated from page worlds.** The drawer and the Secrets window are native widgets, never web content and never reachable from the automation socket (drawer plan D1, 0.3).
- **E2E observability is `--e2e-protocol` rows,** not a production read API. Tests drive real input on a private Xvfb (Linux) or a real `NSWindow` on the remote Macs (macOS plan testing strategy).
- **Runtime switches are flags with env fallbacks,** resolved flag > env > default (`src/media_config.zig:35`).
- **Gates:** every step behind the display guard; e2e wrappers mostly map exit 77 to pass; Mac checks in `mac-gate`, Windows checks in the guest scripts.
- **Packaging rule for macOS keys:** an entitlement or Info.plist key is added only after the Mac build proves it is needed (`packaging/macos/entitlements.plist` comment).

## Workflow Closure Map

The behavior: **the user presses the drawer's microphone control, speaks, and the recognized text appears in the drawer's input box, where it is sent only when the user presses Enter or Send.**

None of the voice nodes exist at HEAD `a69b459`. The chain below documents what would be crossed, anchored to the existing production nodes at both ends.

| Depth | Node | Location | Label | Voice adds/changes |
|---|---|---|---|---|
| 0 | Recorded audio source (WAV fixture standing in for the mic) | none today | not found | adds |
| 1 | Mic control click in the composer row (new GTK button, X input) | `src/agent_drawer.c` composer row `:1234-1251` (new button would join it) | not found | adds (**highest_new_connector**) |
| 2 | Dictation session start (state machine, capture thread) | none today | not found | adds |
| 3 | Audio capture to 16 kHz mono f32 | none today | not found | adds |
| 4 | whisper.cpp transcription on a worker thread | none today | not found | adds |
| 5 | Main-loop handoff (GLib idle) and insert at the input's cursor | `GtkTextView zb-agent-input` `src/agent_drawer.c:1241` | production-called (the widget) | changes (new insert) |
| 6 | User presses Enter, `on_input_key` → `send_input` | `src/agent_drawer.c:905-914`, `:881-898` | production-called | unchanged |
| 7 | `add_message(d, "user", text)` → `DRAWER <win> msg user <text>` row | `src/agent_drawer.c:732` | production-called | unchanged (observable) |

Edges:
- 0→1, 1→2: X button event delivered by GTK (async: X server → GTK main loop; registration: a new `g_signal_connect` in `build_panel`, `src/agent_drawer.c:1278-1281` region). Runtime context: the drawer's `win_id`.
- 2→3: capture thread start (async, cross-boundary into the audio library). Error behavior: permission denied or no device must surface as a drawer status, not a hang.
- 3→4: end-of-speech (button release or VAD) hands samples to the engine thread (async). Cancellation: Escape or a second click.
- 4→5: worker thread → GTK main thread via an idle callback (async; driver: the GLib main loop iteration). The text is inserted, never sent.
- 5→6: the user's own Enter (X input). This edge is the "never auto-send" guarantee: no code path from 4 to 6 except the user's key.
- 6→7: existing synchronous call chain.

Negative evidence: `grep -rn` for `audio|mic|speech|whisper` in `src/` finds nothing; no test writes into the input buffer; the only programmatic write is the clear at `src/agent_drawer.c:895`.

### ClosureMap (structured — derive() input)

```json
{
  "behavior": "The user clicks the drawer's microphone control, speaks, and the recognized text appears in the drawer input; it is sent only when the user presses Enter, observed as the DRAWER msg user row.",
  "git_commit": "a69b459cb5346e8d25488f41e76c034d6fd8f3fa",
  "repo": "/home/maceo/ntm_Dev/zb-automation-integration-2026-10-10-11-59",
  "nodes": [
    { "id": "audio_fixture", "module": "voice/audio (new)", "is_entrypoint": false, "adds_or_changes": true, "read_path": null, "seedable_store": "recorded WAV file fed through the e2e audio seam (new)" },
    { "id": "mic_click", "module": "agent_drawer.c composer row (new button)", "is_entrypoint": true, "adds_or_changes": true, "read_path": null, "seedable_store": null },
    { "id": "dictation_start", "module": "voice/dictation (new)", "is_entrypoint": false, "adds_or_changes": true, "read_path": null, "seedable_store": null },
    { "id": "capture", "module": "voice/audio (new)", "is_entrypoint": false, "adds_or_changes": true, "read_path": null, "seedable_store": null },
    { "id": "transcribe", "module": "voice/whisper engine (new)", "is_entrypoint": false, "adds_or_changes": true, "read_path": null, "seedable_store": null },
    { "id": "insert_input", "module": "agent_drawer.c zb-agent-input", "is_entrypoint": false, "adds_or_changes": true, "read_path": null, "seedable_store": null },
    { "id": "user_enter_send", "module": "agent_drawer.c on_input_key/send_input", "is_entrypoint": true, "adds_or_changes": false, "read_path": null, "seedable_store": null },
    { "id": "msg_row", "module": "agent_drawer.c add_message/drawer_row", "is_entrypoint": false, "adds_or_changes": false, "read_path": "drawer_row(d, \"msg\", ...) via zb_emit_protocol_row (src/agent_drawer.c:732)", "seedable_store": null }
  ],
  "edges": [
    { "is_async": false, "cross_boundary": true, "driver": null },
    { "is_async": true, "cross_boundary": true, "driver": "GTK main loop delivering the X button event (gtk_main_iteration)" },
    { "is_async": true, "cross_boundary": true, "driver": "capture thread start (new)" },
    { "is_async": true, "cross_boundary": true, "driver": "end-of-speech handoff to the engine thread (new)" },
    { "is_async": true, "cross_boundary": true, "driver": "g_idle_add callback on the GTK main loop (new insert)" },
    { "is_async": true, "cross_boundary": false, "driver": "GTK main loop delivering the user's X Enter key (on_input_key)" },
    { "is_async": false, "cross_boundary": false, "driver": null }
  ]
}
```

Resolvability note: `send_input`, `on_input_key`, `add_message`, `drawer_row` and `zb_emit_protocol_row` resolve at `a69b459`. The `(new)` names do not exist yet; they are placeholders for the plan to name. An under-specified map fails safe to BLOCKING downstream.

### Closure adapter (staged proposal — embedded here only)

The research skill normally stages this as a sibling `2026-10-19-voice-input-stt.closure-adapter.py`. The task's hard rule allows only two files, so the scaffold is kept inside this document and was **not** written as a separate file.

```python
"""Closure adapter (STAGED PROPOSAL — not wired into the repo).
Derived from the ClosureMap for: drawer dictation inserts text, sent only on the user's Enter.
Pin: a69b459cb5346e8d25488f41e76c034d6fd8f3fa.
Promote into the repo and complete each TODO(promote) before use.
"""
import http.server, json, sys
ASYNC_EDGES = ["mic_click->dictation_start", "dictation_start->capture",
               "capture->transcribe", "transcribe->insert_input", "insert_input->user_enter_send"]
CONNECTOR = {e: True for e in ASYNC_EDGES}
SINK = []

def handle(op, p):
    if op == "/reset":        SINK.clear(); CONNECTOR.update({e: True for e in ASYNC_EDGES}); return {"ok": True}
    if op == "/set_connector": CONNECTOR[p["edge"]] = p["enabled"]; return {"ok": True}
    if op == "/seed_sink":     SINK.append(p["value"]); return {"ok": True}
    if op == "/seed":
        # TODO(promote): point the e2e audio seam (new flag) at p["data"] (a WAV path) before launch
        return {"ok": True}
    if op == "/trigger":
        # TODO(promote): X click on the new mic button inside the drawer (tests/e2e/xinput.py), new button in src/agent_drawer.c build_panel
        return {"ok": True}
    if op == "/drive":
        if not CONNECTOR.get(p["edge"], True): return {"ok": True}
        # TODO(promote): wait for the new DRAWER voice rows; for the last edge send X Return (on_input_key, src/agent_drawer.c:905)
        return {"ok": True}
    if op == "/observe":
        # TODO(promote): return the DRAWER <win> msg user <text> rows (drawer_row "msg", src/agent_drawer.c:732)
        return {"ok": True, "value": json.dumps(SINK)}
    return {"ok": False, "error": "unknown op"}

class Hn(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        out = json.dumps(handle(self.path, json.loads(self.rfile.read(n) or "{}"))).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(out))); self.end_headers(); self.wfile.write(out)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), Hn).serve_forever()
```

## Historical Context (from thoughts/)

- `thoughts/searchable/shared/plans/2026-10-13-claude-agent-chat-drawer-tdd-plan.md` — the drawer plan. Voice is out of scope (`:1097`). macOS and Windows drawers are out of scope (`:1095`). Format conventions: slices with Given/When/Then and red/green/refactor (e.g. `:1495-1503`), closure test blocks (`:1552-1560`), §7.1 real-hardware check (`:1218-1293`), §8 closure maps (`:1295-1381`), §11 gate steps (`:2655-2672`).
- `thoughts/searchable/shared/plans/2026-10-14-14-30-macos-launch-tdd-plan.md` — MS0-MS9. MS7 is the AppKit drawer (`:1183-1258`). MS1b is the ad-hoc-signed x86_64 crash at `-[ZBAppHost init]` (`:565-591`), scheduled next and a hard prerequisite of any claim that a signed binary runs (`:1342-1351`). MS9 (Developer ID) is blocked on the user's Apple Developer ID.
- `thoughts/searchable/shared/plans/2026-06-01-18-16-ENG-0006-tdd-windows-webview2-backend-m8.md` — the Windows backend, built and tested in the Win11 KVM guest over SSH.
- `thoughts/searchable/shared/research/2026-10-14-agent-sandbox-redteam.md` and `2026-10-14-macos-sandbox-option.md` — the voice notify bridge on port 51091 (an unrelated SAI hook service, not product voice); Windows agent sandbox pointed at WSL2.
- Prior voice research in the main repo: `/home/maceo/ntm_Dev/zigBrowser/thoughts/searchable/shared/research/2026-10-19-voice-recognition-options.md` (engines compared, WebKit support per port, macOS-native options). This document extends it with Windows, build, model and latency details.
- Note: the drawer plan does not itself state the rule "red commits go outside gate-registered steps"; that rule is in the user's project memory and is applied by the plans' authors.

## Related Research

- `thoughts/searchable/shared/research/2026-10-14-14-19-macos-launch-support-surface.md`
- `thoughts/searchable/shared/research/2026-05-31-16-52-slice3-4-ipc-and-cross-os-backends.md`

## Open Questions

- Real latency of medium (f16, q8_0, q5_0) on the actual Intel Mac and Apple Silicon hosts, and on any Windows x64 CPU. The Intel Mac's CPU model is not recorded in the repo.
- Whether Metal works usefully on the Intel Mac's GPU.
- Whether ggml's Metal embed step can be reproduced in `build.zig` cleanly.
- What WASAPI returns when Windows microphone access is off.
- Whether the Win11 VM `win11-m8` exposes a usable capture endpoint through its `ich9`/SPICE audio device (Windows launch plan provisioning item 12), and when the physical Windows 10 machine is provisioned (OpenSSH, `zbtest`, a microphone).
- WASAPI and privacy-setting behavior on the Windows 10 builds that must be supported.
- Whether notarization and MSI packaging have size limits that matter for a ~0.8-1.5 GB bundled model.
- Whether the ad-hoc-signed universal `.app` gets a TCC microphone prompt on each Mac (this depends on MS1b on Intel).
- Whether `webkitSpeechRecognition` works in a macOS WKWebView embedder.
- Beads: `bd list` fails on this clone with a pending schema migration (the designated-migrator message). Per project memory, no migration was attempted and no bead was filed.
