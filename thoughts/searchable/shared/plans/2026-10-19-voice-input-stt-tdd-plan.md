---
date: 2026-10-19T15:27:08-04:00
planner: Claude (subagent for the orchestrator; voice-input STT track)
git_commit: a69b459cb5346e8d25488f41e76c034d6fd8f3fa
branch: zb-automation-integration-2026-10-10-11-59
repository: zigBrowser
topic: "Voice input (speech-to-text) with whisper.cpp — TDD implementation plan"
tags: [plan, tdd, voice, stt, whisper.cpp, microphone, agent-drawer, macos, windows, linux, model-management, miniaudio]
status: plan for review (rev 2.2)
rev: 2.2
last_updated: 2026-10-20
last_updated_note_2_2: "Rev 2.2 (2026-10-20): macOS paths made as concrete as the Windows ones AND RoseCat's re-review drift cleared. VF §4 is now byte-identical to the TTS plan's §2.4 between explicit VF:BEGIN/VF:END markers (a proposed tools/check_vf_identical.sh asserts diff is empty); the VF privacy oracle allowlists exactly the test's declared FileSink artifact; automated gates are Null/WAV/FileSink only (VS10's live mic moved to the manual win-voice-live check). The §4a contracts are folded into the owning slices as concrete reds: VS4.7 async epoch/cancel/close/restart, VS4.6+VS4.8 the unforgeable capture capability + sandbox negatives, VS5.8 the first-use privacy notice (no capture before Accept / decline / persistence / corrupt re-prompt), VSP.5 upgrade/repair/downgrade/tamper/orphan, VSP.6 the orchestrator-only remote model-transfer, and concrete reds for VS9/VS11. SHOULD: whisper_init_from_buffer_with_params (nondeprecated 1.9.5). macOS entitlement/census deltas are proposed to JadeBeacon, not edited into his plan."
last_updated_note: "Rev 2.1 (2026-10-20): major revision clearing RoseCat's 9a6973b / 9663333 voice-plan review (NOT APPROVED). The shared subsystems are now specified once in §4 Shared Voice Foundation (VF), byte-identical in the TTS plan: one path set (src/voice/*, src/voice_settings_window.c), one audio API, one owner, one voice.json schema with migration + lock + single writer, verify-through-consumption model loading (whisper_init_from_buffer), the render-to-file/null test-device rule, and a native ZbChild interface (not the Python agent SandboxBackend). The dictation state machine (D4) gains an epoch/session token and stale-result rejection; a headless native permission contract and the VS5/VS8 privacy-notice UI assertions are added; the macOS mic source is bound to the signing/census route; a range-aware insert ABI replaces zb_drawer_set_draft; the medium verify/load race is closed and installer upgrade/repair/downgrade/tamper/orphan tests added; failing-first is made executable for VS0.2/VS9-VS11/VSP; live capture is put behind an unforgeable capability; and remote packaging gets a model-transfer protocol. No user decision is changed; open decisions are sharpened only. Rev 2 (2026-10-19): recorded the user's decisions — bundle the model (O2), Windows launch plan dependency, Windows 10 support; VS2 optional; VSP added."
primary_research: thoughts/searchable/shared/research/2026-10-19-voice-input-stt.md
prior_research: /home/maceo/ntm_Dev/zigBrowser/thoughts/searchable/shared/research/2026-10-19-voice-recognition-options.md
sibling_plan: "browser voice (text-to-speech), written in parallel by another agent; shared pieces named in section 4"
---

# Voice input (speech-to-text) for zigBrowser: TDD implementation plan

> **PLAN ONLY.** Nothing here was built, run or downloaded. Automated tests run only under a
> private Xvfb (Linux), on the two remote Macs over SSH, or on the two Windows hosts through the
> Windows plan's gate (the Win11 VM `win11-m8` and the physical Windows 10 machine). They never
> run on the user's display, live profile or live socket. Every UI slice names its own
> real-screen check, which the orchestrator runs with the user.

**Line references** cite HEAD `a69b459` unless marked. "Research" means
`thoughts/searchable/shared/research/2026-10-19-voice-input-stt.md`. "Drawer plan" means
`thoughts/searchable/shared/plans/2026-10-13-claude-agent-chat-drawer-tdd-plan.md`. "macOS plan"
means `thoughts/searchable/shared/plans/2026-10-14-14-30-macos-launch-tdd-plan.md`.

## 0. Requirements

### 0.1 The user's request (verbatim, 2026-10-19)

> "We need to break this into 2 plans: 1 plan for the voice of the browser, this will allow the LLM to generate text that is spoken and allow the user to customize voices. The second plan is for the user to use voice to text. Mac and Windows are the 2 main target systems, Linux is my environment, not the primary target for users. I'm comfortable with shipping whisper.cpp and handling the model as part of the browser."

This plan is the second one: the user speaks, and the speech becomes text.

### 0.2 Decided by the user

1. **Engine: whisper.cpp,** shipped with the browser. The model is handled by the browser (bundled and/or downloaded and managed by it).
2. **Targets:** macOS and Windows are primary. Linux must work for development and testing but is not the shipping priority.
3. **Model: start with whisper medium** (decided 2026-10-19, through the coordinator). The user's words: "Let's start with the medium model (769MB)."
   - "769MB" is most likely medium's **769 million parameters**. The files are different sizes (research 4.1, read from the Hugging Face API at repo revision `5359861c739e955e79d9a303bcbc70fb988958b1`):

     | File | Exact bytes | Size | Note |
     |---|---:|---|---|
     | `ggml-medium.bin` | 1,533,763,059 | 1.53 GB (1.43 GiB) | full precision (f16); about 2.1 GB RAM per the whisper.cpp README |
     | `ggml-medium-q8_0.bin` | 823,369,779 | 823 MB (785 MiB) | 8-bit quantized |
     | `ggml-medium-q5_0.bin` | 539,212,467 | 539 MB (514 MiB) | 5-bit quantized |
     | `ggml-medium.en*.bin` | about the same three sizes | | English-only variants |

   - **Medium itself is decided.** Which medium file ships (f16, q8_0 or q5_0, multilingual or `.en`) is still open (decision O1).
4. **The model ships inside the installer** (decision O2, DECIDED 2026-10-19). The user's words, through the coordinator: "Bundle in the installer."
   - There is no first-run download, and dictation works offline from the first launch.
   - Each installer grows by the chosen file. With q8_0, that is about 823 MB (823,369,779 bytes) per DMG, MSI and .deb.
   - The model file is architecture-independent, so it must be **byte-identical** in the arm64 and x86_64 macOS slices.
   - Its integrity is checked **at build time** (pinned SHA-256, the build fails otherwise) and **at first load** (the browser refuses a file that does not match).
5. **Windows** (DECIDED 2026-10-19, through the coordinator):
   - The **Windows launch plan** (WLP) exists at `thoughts/searchable/shared/plans/2026-10-19-windows-launch-tdd-plan.md` (rev 2, milestones WS0-WS13). This plan depends on these milestones, each checked in that file:
     - **WS0**: test hosts and the fail-closed two-host gate `tests/windows/gate.sh` (WLP `:614`).
     - **WS1**: the native build on the VM (`-Dtarget=x86_64-windows-msvc`) that runs on both hosts (WLP `:724`).
     - **WS5**: the native Win32 drawer, the "drawer-port milestone" (WLP `:1148`).
     - **WS11**: the agent helper and chat on Windows (WLP `:1540`).
     - **WS12**: voice hooks. WS12.1 adds the drawer draft hook (must be the range-aware `zb_drawer_insert_text` of §4a #4 — cursor insert + selection replace, not a whole-draft `set_draft`); WS12.2 adds `tests/windows/gate.sh --phase voice` (WLP `:1587-1640`).
     - **WS13**: packaging. WS13.1 is the MSI census and WS13.3 the size budget with split cabinets (WLP `:1644`).
   - **Hosts** (WLP "Host provisioning", `:359-502`):
     - **Win11 VM `win11-m8`**: the libvirt domain, reached by default through the passt forward `127.0.0.1:2222`. It is the build host and a run host, and it is marked [W11] there.
     - **The physical Windows 10 machine** `100.123.34.15` (`file-server-win-mac`): a run-only host that is also a file server, under WLP's isolation rules. Tests run as the standard user `zbtest`. It is marked [W10] there.
   - **Windows 10 must be supported.** This matters for WASAPI and the microphone privacy settings (D8, VS10).

### 0.3 Project rules this plan obeys (each is a gate or a test below)

- Every UI slice names its own real-screen check, run by the orchestrator with the user (drawer plan §7.1). An Xvfb pass is necessary, not sufficient.
- Agents never use `DISPLAY :0`, the live browser, its profile or its socket. Automated tests run under a private Xvfb (`tests/e2e/xsession.py --xvfb`), on the remote Macs, or on the Windows hosts through WLP's gate (WS0).
- **Red commits go outside gate-registered steps.** A red test lands in an unregistered file or step. It is registered in the green commit.
- Never reset, rebase or amend committed work; fix forward. Stage only your own hunks (the worktree is shared).
- The Mac is tested on two real hosts over SSH: Intel (`ZB_MAC_HOST`, default `maceojourdan@100.92.212.47`, `tests/mac/gate.sh:24`) and Apple Silicon (`ZB_MAC_ARM_HOST`, `:25`). The gate fails closed when one is missing (`:44-49`).
- **Open dependency MS1b:** the ad-hoc-signed x86_64 binary crashes at ObjC init (`-[ZBAppHost init]`, `0xf0000001`; macOS plan `:565-591`). No slice may claim a signed binary runs on Intel until MS1b's gate is green (macOS plan `:1342-1351`).
- **Windows test hosts are WLP's two hosts (WS0):** the Win11 VM `win11-m8` and the physical Windows 10 machine (`100.123.34.15`, `file-server-win-mac`).
  - **Only the physical Windows 10 machine runs live-microphone checks.** It is to get a microphone and the per-user "Let desktop apps access your microphone" switch for `zbtest` (WLP provisioning item 10).
  - **The VM has no proven capture device.** Its domain defines an `ich9` sound device with a SPICE audio backend, but whether Windows shows a capture endpoint and whether `virt-viewer` forwards a microphone is unverified (WLP provisioning item 12). Until that is proven (D8, "Proving a VM capture device"), the VM runs recorded-file (WAV seam) tests only.
  - No Windows arm64 machine or target exists.
- Tests feed **recorded audio files** instead of a live microphone wherever possible, so most of the plan is testable headless. The live microphone is checked only in the real-hardware checks with the user.
- A new port or platform method ships with its adapter and a live e2e in the same slice (project memory). A closure e2e that prints SKIP is UNCLOSED. Missing tools exit 1, not 77.

## 1. Overview

This plan adds **dictation into the agent chat drawer's input box**:
1. The user clicks a microphone control (or uses a shortcut) and speaks.
2. whisper.cpp transcribes locally.
3. The text is inserted at the cursor in the input box.
4. **The user sends it.** Nothing is ever sent automatically.

The work splits into a **portable Zig core** that is built and tested on Linux first, and thin **per-platform glue**:
- The core covers audio capture behind an interface, whisper.cpp behind an interface, the dictation state machine, and the locator and verifier for the **bundled** model.
- The glue covers the GTK drawer today, the AppKit drawer after macOS MS7, the Windows drawer from the Windows launch plan, plus the OS microphone permission per platform.
- The medium model ships inside every installer (0.2.4). The packaging slice VSP puts it there and proves it is intact.

Four pieces are designed to be **shared with the sibling text-to-speech plan**: the audio device layer, the model store (bundled-model locator and verifier, plus an optional downloader), the permission and consent layer, and a Voice settings window (section 4).

Slices VS0-VS11 and VSP, plus a deferred web-page track VW (section 10). VS2 (download) is now optional and off the v1 path. Section 11 gives the platform matrix: which slices build and test from Linux, which need a Mac, and which need Windows.

## 2. Current state (research, verified at `a69b459`)

### Key discoveries
- **No voice code anywhere.** A grep for `audio|microphone|mic|speech|whisper|pulse|pipewire|AVAudio|wasapi` over `src/` finds nothing. The drawer plan excludes voice (`:1097`).
- **Drawer input:** a `GtkTextView` `zb-agent-input` (`src/agent_drawer.c:1241`) in the composer row with Send and Stop (`:1234-1251`; signals `:1278-1281`).
  - Enter without Shift sends (`on_input_key`, `:905-914`).
  - `send_input` reads, strips, emits `msg user`, hands off to the helper, then clears the buffer (`:881-898`).
  - Nothing inserts text programmatically today.
- **Drawer keys already taken:**
  - Ctrl+Shift+Space toggles the drawer (`src/agent_drawer.c:1038-1050`).
  - Escape with the drawer open minimizes it (`:1052`).
  - Voice must not steal these (D4).
- **E2E rows:** `DRAWER <win> <kind> ...` via `drawer_row` (`:174-180`). The `msg` row is at `:732` and the `status` row at `:810`. There is no row for the input's text.
- **The drawer is Linux/GTK only.**
  - Its C files are compiled only in `configureGtkBackend` (`build.zig:1503-1533`), and the Zig side is Linux-gated (`src/app.zig:52-55`, `:341`).
  - The **macOS drawer is MS7** (AppKit, `src/agent_drawer_mac.m`, after MS4 and MS5; macOS plan `:1183-1258`, `:1336-1340`).
  - The **Windows drawer port is WLP's WS5** (native Win32 drawer, `thoughts/searchable/shared/plans/2026-10-19-windows-launch-tdd-plan.md:1148`), with the voice hook `zb_drawer_set_draft` (must be the range-aware `zb_drawer_insert_text` of §4a #4 — cursor insert + selection replace, not a whole-draft set) in WS12.1. (At `a69b459` the macOS plan `:373` and the drawer plan `:1095` both exclude a Windows drawer; WLP now covers it.)
- **No backend handles microphone permission:**
  - GTK has no `permission-request` handler and does not set `enable-media-stream` (`src/webkit_shim.c:1290-1296`).
  - WKWebView's only UIDelegate method is `createWebViewWithConfiguration` (`src/wkwebview_shim.m:564`).
  - WebView2 registers only `NavigationCompleted` and `WebMessageReceived` (`src/webview2_shim.cpp:613`, `:647`).
- **macOS packaging:**
  - `packaging/macos/entitlements.plist` has only `network.client`. Its rule is that a key is added only after the Mac build proves it is needed.
  - `packaging/macos/Info.plist` has no `NSMicrophoneUsageDescription`.
  - The bundle id is `com.cosmichq.zigBrowser`, and `LSMinimumSystemVersion` is 13.0.
- **Build:**
  - No third-party C library is built today, and `build.zig.zon` has no dependencies (`:34-64`).
  - The Mac builds natively per arch over SSH with no `-Dtarget` (`tests/mac/build-on-mac.sh:32-37`), then lipos (`tests/mac/gate.sh:74-77`).
  - Windows builds in the guest with `-Dtarget=x86_64-windows-msvc` (`tests/guest/build-in-guest.sh` at `a69b459`). WLP's WS1 replaces calling it directly with its own build-on-the-VM script and the WS0 gate.
  - `cross-check` compiles objects for `aarch64-macos`, `x86_64-macos` and `x86_64-windows-gnu` from Linux (`build.zig:243-277`).
- **Network:**
  - The agent's egress allowlist is `("api.anthropic.com",)` (`agent/host/zb_agent_host/sandbox.py:51`), enforced by netd for the helper and CLI only.
  - The browser process has no allowlist and no downloader (`src/sequences.zig`'s HTTP client is test-only, `build.zig:1365-1388`).
- **Reusable pieces:**
  - `src/atomic_file.zig` (atomic writes).
  - The flag-plus-env resolution pattern (`src/media_config.zig:35`, `src/cli.zig:204-213`).
  - The `--e2e-protocol` row emitter.
  - `tests/e2e/xinput.py` and `xsession.py`.
  - `tests/manual/real_screen_check.py` (drawer plan §7.1).
- **whisper.cpp facts** (research 4):
  - v1.9.5 (2026-10-06), MIT; OpenAI's weights are MIT.
  - Input is 16 kHz float PCM.
  - Each call pays a 30 s encoder window unless `audio_ctx` is lowered.
  - Metal on Apple Silicon, with the shader embedded and compiled at runtime.
  - On x86 a static build targets one baseline ISA.
  - The upstream download script does not verify checksums.
- **Medium latency (published encoder times per 30 s window; research 4.4):**
  - M2 Ultra / M4 Max with Metal: about 0.1-0.2 s.
  - M1 Pro CPU: 1.9 s.
  - Desktop Ryzen 5950X: 4.4 s.
  - Windows i5-1135G7 laptop CPU: about 25 s for the encoder alone.
  - No Intel Mac row exists.

## 3. Design

### D1. Module layout: portable Zig core, thin platform glue

| Module (new) | Role | Shared with TTS? |
|---|---|---|
| `src/voice/audio.zig` | `AudioSource` (capture) and `AudioSink` (playback, declared for TTS) vtable interfaces; `WavFileSource`; ring buffer; resample to 16 kHz mono f32 | **yes** (the audio device layer) |
| `src/voice/audio_miniaudio.c` + `third_party/miniaudio/miniaudio.h` | live capture on Core Audio, WASAPI, PulseAudio (PipeWire via pipewire-pulse), ALSA; Null backend for lifecycle tests | **yes** |
| `src/voice/stt_engine.zig` | `SttEngine` vtable: `load(model_path)`, `transcribe(samples, opts) -> Segments`, `abort()`; `FakeEngine` (scripted text, for tests) | no |
| `src/voice/whisper_engine.zig` | `@cImport("whisper.h")`; one `whisper_context` per process on one worker thread; VAD and `audio_ctx` policy | no |
| `src/voice/dictation.zig` | pure state machine (D4); owns the session, the audio buffer and the cancel token | no |
| `src/voice/models.zig` | model catalog (pinned name, source URL for the build fetch, revision, size, SHA-256), per-OS **bundled resource directory**, verify at first load | **yes** (model management) |
| `build/voice_model.zig` (build helper) | build-time check of the pinned SHA-256 and copy of the model into the install tree | **yes** (TTS voices can use the same check) |
| `src/voice/download.zig` | *optional, not in v1 (VS2):* consent-gated HTTPS download for later model updates or alternate models | **yes** if TTS downloads voices |
| `src/voice/voice_config.zig` | `--voice-input on|off` + `ZIGBROWSER_VOICE_INPUT`, plus the persisted user settings (mode, language, model file) | settings file **shared** |
| `src/voice/consent.zig` | app-level consent records (the first-use mic notice; download consent only if VS2 is ever built) | **yes** (permission/consent layer) |
| `src/voice_mac.m` | `AVCaptureDevice` authorization status, request and settings deep-link | **yes** (OS permission glue) |
| `src/voice_win.cpp` | maps WASAPI access failures; opens `ms-settings:privacy-microphone` | **yes** |
| `src/agent_drawer.c` (changed) | mic control, indicator, insert at cursor | no |
| `src/voice_settings_window.c` (new, GTK) | the Voice settings window (D9) | **yes** (one window, two sections) |

Rules, from the existing pattern (drawer D4: decisions in Zig, glue in C):
- The GTK, AppKit and Win32 code only translates events into calls on `dictation.zig`. It never decides state.
- `whisper_engine.zig` is the only file that includes `whisper.h`. Tests that do not need real recognition use `FakeEngine`.

### D2. Audio layer (shared)

- **Capture contract:**
  - The consumer always receives **16 kHz, mono, f32 samples in [-1, 1]**, in blocks.
  - Device format conversion happens in the layer: miniaudio's converter, configured as `ma_format_f32`, 1 channel, 16000.
  - Its resampler quality is unverified. VS3 measures it.
- **Sources:**
  - `MiniaudioSource` is the live mic.
  - `WavFileSource` reads 16-bit PCM or f32 WAV at any rate and resamples through the same converter, so the test path and the live path share the conversion.
  - `SilenceSource` is for lifecycle tests.
- **Threading:** a capture callback on the audio thread writes into a lock-free ring buffer. `dictation.zig` drains it on its own thread. No GTK or AppKit calls happen on audio threads.
- **Device loss** (unplug, AirPods route change) ends the session with `error device-lost`. It does not hang.
- **Playback:** `AudioSink` is declared with the same block contract (rate chosen by the producer), so the TTS plan implements it in the same module rather than adding a second audio library.

### D3. Engine

- **One engine instance per process.** The model is loaded from the bundled resource directory (D5) lazily on the first dictation, not at browser start. It is kept loaded for a configurable idle time and then freed, because medium f16 is about 2.1 GB of RAM.
- **Batch after end-of-speech.** The numbers in research 4.4 do not support live partial text with medium on CPU. The session records until the user stops (or VAD detects end-of-speech, D4), then transcribes once.
- **`audio_ctx` policy:** the encoder context is sized to the recorded length (with a floor), instead of always 30 s. The floor is a tunable in `voice_config`; research reports instability below about 10 s on small models. VS4 measures the accuracy cost on medium against fixtures before the policy is turned on by default.
- **Language:** `auto` (multilingual model) or a fixed language from settings.
- **Abort:** cancel sets `abort_callback` to stop compute promptly.
- **CPU ISA (x86_64):** one static build per OS. The baseline is an open item inside O1/VS7 (recommended x86-64-v3 = AVX2+FMA). At startup, `cpuid` checks the baseline. On a CPU without it, voice input shows "Voice input needs a newer processor" and the mic control stays insensitive. It never crashes with an illegal instruction.

### D4. Dictation state machine and UX invariants

States: `idle → (permission) → listening → transcribing → inserted | empty | cancelled | error(reason)`, then back to `idle`.

Invariants, each a test:
1. **Never auto-send.** No path from a dictation result reaches `send_input`, `zb_agent_helper_send` or a prompt frame. Only the user's Enter or Send does (`src/agent_drawer.c:905-914`, `:1278`).
2. **Insert at the cursor, replacing the selection.** It goes into the existing buffer as one user-action group, so a single Undo removes it if the text view supports undo. GTK3 `GtkTextView` has no built-in undo, so this is recorded as unverified and not promised. A leading space is added only when the character before the cursor is not whitespace.
3. **A visible indicator for every non-idle state.**
   - The mic control changes look and accessible name ("Start dictation" ↔ "Stop dictation").
   - The status label shows "Listening…" with elapsed seconds, or "Transcribing…".
   - The OS indicators (macOS menu-bar dot, Windows taskbar icon) are the OS's own.
4. **Audio never leaves the device and is never persisted.**
   - Samples live only in memory and are zeroed (`std.crypto.secureZero`) when the session ends.
   - No file, temp file or log line contains audio.
   - The transcript text is not logged. Rows carry only the length unless `--e2e-protocol` is set.
5. **Cancel discards.**
   - Escape while listening or transcribing cancels and is consumed. Escape when idle keeps its existing meaning (minimize, `:1052`).
   - A second click while transcribing cancels.
   - A cancelled session inserts nothing.
6. **Bounded.** Recording stops at a maximum length (default 60 s, tunable) with a notice; it never runs on silently.
7. **One session at a time per process.** A second window's mic control is insensitive while another window dictates. The engine is not thread-safe per context.
8. **The agent cannot start dictation.** There is no tool, frame or automation-socket method that starts it (the drawer plan's T3 isolation rule). This is a negative test.
9. **The agent window's state is respected.** Closing the window or the drawer mid-session cancels and frees everything; the live session count goes to 0.

Interaction mode (push-to-talk vs toggle) is open decision O3. The state machine supports both. The mode only changes which input events map to `start` and `stop`.

### D5. The bundled model: catalog, build-time check, packaging, first-load check (shared)

The user decided to bundle the model (0.2.4). There is no first-run download.

- **Catalog:** compiled-in, one entry per file with `{id, file, source_url, hf_revision, bytes, sha256, license}`.
  - The source URL is used **only by the release build's fetch tool**, never by the running browser. It is pinned to the Hugging Face **revision**, not `main`: `https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/<file>`.
  - The three medium entries use the exact sizes and hashes in research 4.1. The build picks one by `-Dvoice_model=<id>` (O1; default = the decided file).
- **Getting the file into the build (build time):**
  1. `tools/fetch_voice_model.sh <id>` downloads the file once into a cache outside the repo (`$ZB_VOICE_MODEL_CACHE`). It is run by the orchestrator or the release builder, never by a gate. The model is far too large to commit or to put in the Zig package cache.
  2. A build step `voice-model-check` hashes the cached file and **fails the build** when it is missing or its size or SHA-256 differs from the catalog. Every packaging step depends on it.
  3. The install step copies the file into the install tree at `share/zigbrowser/models/stt/<file>`.
- **Where it lives in each installer** (the bundled resource directory):
  - macOS: `zigBrowser.app/Contents/Resources/models/stt/<file>`, a non-code resource inside the signed bundle.
  - Windows (MSI): `INSTALLFOLDER\models\stt\<file>` (the WiX directory id is `INSTALLFOLDER`), next to `zigBrowser.exe`.
  - Linux (.deb): `/usr/share/zigbrowser/models/stt/<file>`.
  - Development runs from `zig-out/` use `zig-out/share/zigbrowser/models/stt/`.
  - `ZIGBROWSER_MODEL_DIR` overrides all of these, for tests.
  - The locator takes the executable path, the OS tag and the environment as inputs, so all three layouts are unit-tested on Linux.
- **First-load check (run time):**
  - The engine verifies size + SHA-256 against the compiled catalog once per process and then loads **the verified bytes** via `whisper_init_from_buffer_with_params` (VF's verify-through-consumption, §4) — it never re-opens the path for the load, so a swap at the verify/use seam cannot reach whisper.
  - Hashing 0.8 to 1.5 GB takes seconds, not milliseconds; VS1 measures it. It runs on the engine thread while the status shows "Preparing voice…", so the UI never blocks.
  - A cached verify record keyed by `(size, mtime, inode)` is the refactor option if the hash cost hurts.
  - A missing or damaged file disables voice input with "The voice model is missing or damaged. Reinstall zigBrowser." It never loads an unverified file.
- **The bundle is read-only.** The browser never writes, moves or deletes the bundled model. That also keeps the macOS signature intact.
- **Network:** the running browser makes **no** network request for the model. O5 (download host) is no longer needed for first use. It only matters if the optional update path (VS2) is ever built, and then it is the user's decision again. The agent sandbox's allowlist (`sandbox.py:51`) is unchanged, and the agent never touches models.
- **Updates:** the model changes only when the catalog changes in a new browser release, shipped in the new installer. There is no background check.
- **Installer size:** each DMG, MSI and .deb grows by the chosen file. That is 823,369,779 bytes with q8_0, 1,533,763,059 with f16, or 539,212,467 with q5_0 (O1).
- **macOS specifics** (packaging is VSP, coordinated with the macOS plan):
  - The model is a **resource** in `packaging/macos/universal_components.json`. It is not a Mach-O, so the census treats it as a byte-compatible resource.
  - It must be **byte-identical in the arm64 and x86_64 per-arch trees**. This is exactly what the macOS plan's two-tree `resource_compat` oracle checks (MS5.1c; macOS plan `:1040-1067`).
  - Adding the first resource moves the MS1 inventory off its "empty resources, browser only" shape. The MS1 phase gate accepts that shape only for MS1 (`universal_components.json` comment; macOS plan `:486-506`). So VSP's macOS part lands with, or after, MS5.1c's oracle. The resource's role name (proposed `stt-model`) must be agreed with the macOS plan's owner.
  - Code signing seals the resource's hash in the bundle's `CodeResources`. Notarization uploads the whole DMG. Apple's upload size limit and the notarization time for a ~1 GB DMG are unverified; VSP measures them on the ad-hoc path now and MS9 on the real path.
- **Windows specifics:**
  - The MSI (`packaging/windows/zigBrowser.wxs`) gains the file. WiX/MSI cabinet and package size limits are unverified at this size. A 2 GB cabinet limit, if it applies, is above q8_0 and f16.
  - The MSI packaging change is made with WLP's **WS13** (packaging). WS13.1's census lists the model, and WS13.3's size budget sums every bundled payload and uses split cabinets so that no cabinet exceeds 2 GB.

### D6. E2E seams (inert in production)

- `--e2e-voice-source wav:PATH|silence` replaces the mic with a `WavFileSource`. It is accepted only together with `--e2e-protocol`; otherwise the result is usage (exit 2).
- `--e2e-voice-engine fake:TEXT|fake-delay:MS:TEXT|fake-error:REASON` replaces whisper with `FakeEngine`. Same rule.
- New rows (only under `--e2e-protocol`):
  - `DRAWER <win> voice <state> [detail]`: states as in D4; detail is a reason or byte length.
  - `VOICE model <id> <status>`: absent, verifying, ready, damaged.
- A test proves both seams are inert without `--e2e-protocol`, in the shape of drawer S3.6.

### D7. whisper.cpp in `zig build`

- **Vendoring:** a `build.zig.zon` dependency on the **v1.9.5 source tarball** with Zig's content hash, so the build verifies the bytes. It is the first `.dependencies` entry. The alternative is an in-tree copy under `third_party/whisper.cpp/`; the plan recommends the `.zon` pin. Fetching at build time needs network once per cache; the Mac hosts and the Win11 guest each need the package cache primed. `zig build --fetch` is run by the orchestrator, not by agents in a gate.
- **What is compiled** (a static library step `whisper`):
  - `ggml/src/ggml.c`, `ggml-alloc.c`, `ggml-backend*.cpp`, `ggml-quants.c`, `ggml-threading.cpp`
  - the CPU backend `ggml/src/ggml-cpu/*`
  - `src/whisper.cpp`
  - C11 and C++17, `-DNDEBUG`, `-O3` for these files even in Debug builds (so tests are not unbearably slow)
  - no `GGML_NATIVE`; an explicit baseline ISA (D3)
- **Per target:**
  - Linux x86_64 (dev): CPU backend only.
  - macOS arm64: CPU (NEON) + Accelerate + Metal, with the shader embedded. The build step concatenates `ggml-metal.metal` with its two includes and exposes the bytes through the `ggml_metallib_start` / `ggml_metallib_end` symbols that ggml's embed path reads. Doing this in `build.zig` is unverified; VS7 proves it on the arm64 Mac.
  - macOS x86_64: CPU (AVX2 baseline) + Accelerate. Metal off until a Mac test shows it helps on the Intel GPU (research 4.3: unverified).
  - Windows x64 (msvc, built in the guest; run on the Win11 VM and the physical Windows 10 machine): CPU (AVX2 baseline). No Vulkan, CUDA or OpenVINO in this plan. The binary must run on Windows 10, so it uses no API newer than Windows 10's (the Windows launch plan sets the minimum build).
  - Windows arm64: not built (no target in `build.zig`, no host). Upstream ships `whisper-bin-win-cpu-arm64` with CMake, so it is feasible later.
- **Universal macOS:** each arch builds natively on its own host (the existing rule), and `lipo` combines them. The library is linked statically into `zigBrowser`, so `universal_components.json` gains no new Mach-O component. The census still proves the single binary is fat. The bundled **model** is a separate, non-code **resource** entry (D5, VSP).
- **Cross-check:** the CPU-only ggml and whisper objects join `cross-check` for `aarch64-macos`, `x86_64-macos` and `x86_64-windows-gnu`, so a Linux developer catches portability breaks before a Mac or guest run. The Metal `.m` files are excluded; they need the SDK.

### D8. OS microphone permission (shared permission layer)

| Platform | What the OS needs | How zigBrowser asks | How denial looks |
|---|---|---|---|
| macOS | `NSMicrophoneUsageDescription` in Info.plist; `com.apple.security.device.audio-input` for hardened runtime; a signed `.app` | `AVCaptureDevice authorizationStatusForMediaType:` then `requestAccessForMediaType:` the first time the user starts dictation | status `denied`/`restricted` → drawer shows "Microphone access is off for zigBrowser" + a button opening System Settings > Privacy & Security > Microphone |
| Windows 10 and 11 | unpackaged (MSI) app: the microphone master switch plus "Let desktop apps access your microphone" (wording differs between 10 and 11, "Allow…" vs "Let…"; unverified per build); no OS prompt for desktop apps | none from the OS; zigBrowser shows its own first-use notice | WASAPI error HRESULT (unverified which, and may differ between 10 and 11; research 5.2) **or** an all-zero stream → "Windows is blocking the microphone" + a button for `ms-settings:privacy-microphone` |
| Linux (dev) | none (no portal used) | none | no device / open failure → "No microphone found" |

- **The usage string** (proposed; the user can change it): "zigBrowser uses the microphone only while you dictate into the Claude Agent box. Audio stays on this Mac."
- **The entitlement** is added only when VS8's red proves the hardened-runtime build cannot capture without it (the file's own rule).
- **The app-level first-use notice** is the same on all platforms: "Dictation runs on this device. Audio is not saved or sent." The user acknowledges it once. It is stored by `consent.zig`.
- **Silence detection:** on every platform, a session whose captured RMS stays below −70 dBFS for the first 1.5 s reports `error no-signal` with the platform hint. This catches the macOS "silent until granted" behavior and the Windows silent-stream case.
- **Windows 10 must be supported** (0.2.5). Facts and unknowns that matter:
  - The per-app desktop microphone switches reported for a Windows 11 Insider build (research 5.2) do not exist on Windows 10. Windows 10 has only the master switch and the desktop-apps switch. The code must not depend on a per-app setting.
  - Windows 10 reached end of mainstream support on 2025-10-14 (general knowledge, unverified here). Users there may run older builds.
  - The WASAPI flags D2 relies on (`AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM`, `SRC_DEFAULT_QUALITY`, event callback in shared mode) are documented by Microsoft without a Windows 11 requirement. Their availability on the Windows 10 builds the Windows launch plan supports is unverified, and VS10 tests it on the physical Windows 10 machine.
  - If the engine's automatic conversion is missing or misbehaves on a Windows 10 build, miniaudio's own resampler is the fallback (the same path the WAV source uses).
  - The supported Windows builds come from WLP's OD-W7, still a user decision there. It proposes Windows 10 22H2 (build 19045) and Windows 11 22621+, x64.
- **Proving a VM capture device** (needed before any live-microphone test runs on the Win11 VM `win11-m8`). All four steps must pass and be recorded in WLP's provisioning item 12:
  1. **Endpoint present:** `zigBrowser.exe --voice-capture-probe --list` on the VM (as the test user) lists at least one WASAPI capture endpoint in the ACTIVE state, with its name and mix format.
  2. **Signal arrives:** the orchestrator plays a known 1 kHz tone into the microphone that `virt-viewer` forwards (SPICE audio record) for 3 s. `--voice-capture-probe --seconds 3` on the VM reports a dominant frequency of 1000 ± 5 Hz and RMS above the −70 dBFS floor.
  3. **Negative control:** with forwarding stopped, the same probe reports `no-signal`.
  4. **Repeatable:** the result holds after a VM reboot (the gate restarts it).

  Until all four pass, the VM's voice phase registers **recorded-file tests only**. `win-voice-live` and every live-capture case run on the physical Windows 10 machine.

### D9. Voice settings window (shared with TTS)

There is no settings window today; the only secondary window is Secrets (`src/agent_secrets_window.c:603`).
- A **Voice** window is opened from a new header button in the drawer, next to Account (`src/agent_drawer.c:1216-1220`).
- It has one **"Voice input"** section from this plan: the bundled model's name, size and check status ("Ready", "Checking…", "Damaged — reinstall"); mode (O3); language; maximum length. There is no Download button, because the model is bundled (0.2.4). The TTS plan adds a **"Browser voice"** section to the same window.
- Like Secrets, it is a native window, absent from the window registry and the automation socket (drawer plan T3).
- Per-user settings are stored in `<profile>/voice.json` via `atomic_file.zig`, with one schema shared by both sections and versioned.

### D10. Web pages (scoped, deferred to track VW; decision O6)

These are three different features, and none of them is drawer dictation:
1. **Page microphone permission** (`getUserMedia`): handling `permission-request` (GTK), `requestMediaCapturePermissionForOrigin` (WKWebView) and `PermissionRequested` (WebView2) with a native prompt and per-origin memory. Today GTK denies, WebView2 shows its default prompt, and WKWebView returns `.prompt` (research 8). This is browser-permission work that the TTS plan does not need, and it belongs to a browser-permissions plan.
2. **Web Speech `SpeechRecognition` for pages:** unreliable everywhere (WebView2 uses Microsoft cloud and regressed in Runtime 153; WebKitGTK has none; WKWebView is unverified). A polyfill backed by this plan's engine is possible but needs its own threat model, because pages could then trigger local recognition.
3. **Dictating into a focused page field** (the user's own dictation, not the page's API): inserting the transcript with `document.execCommand('insertText')` in the focused frame through a privileged channel. It needs care with React-controlled inputs and with which frame has focus.

The plan recommends drawer-only for v1 and lists VW as a later track.

## 4. Shared Voice Foundation (VF) — one slice, one owner

The bytes between the `VF:BEGIN` and `VF:END` markers below are **byte-identical in the sibling TTS
plan** (TTS §2.4). They are the single source of truth for everything the two plans share; a change
lands in both plans in the **same commit**, and `tools/check_vf_identical.sh` (proposed; see §13)
asserts `diff` of the two marked regions is empty, so the copies cannot drift (RoseCat shared
BLOCKER 1). Plan-specific notes stay **outside** the markers.

<!-- VF:BEGIN -->
> **This section is the single source of truth for everything the TTS and STT plans share. The bytes
> between VF:BEGIN and VF:END are byte-identical in both plans; any change lands in both, in the same
> commit.** It replaces the conflicting shared definitions the review flagged (shared review 1;
> `9663333` TTS/STT BLOCKER 1-2).

**Owner and order.** VF is **one slice**, landed **once**, before any consumer slice in either
plan. It is owned by a single implementing agent (the orchestrator assigns them; it is **not**
split across the two plans). The STT track carries VF (its VS-VF cluster: the old VS3 audio, VS1
model locator, VS6 window shell, plus the schema/child modules), because those slices were already
written to land first; the TTS track **consumes** VF and adds only its playback `AudioSink` impl
and its "Browser voice" settings section. Every consumer slice in either plan carries a
`depends on VF` edge.

**One path set (canonical — both plans use exactly these).**

| File | Role |
|---|---|
| `src/voice/audio.zig` | `AudioSource` (capture) + `AudioSink` (playback) vtables; ring buffer; resample to the consumer's format; `WavFileSource`, `SilenceSource`, `NullSink`, `FileSink` |
| `src/voice/audio_miniaudio.c` + `third_party/miniaudio/miniaudio.h` | one `ma_context` per process; Core Audio / WASAPI / PulseAudio (PipeWire via pipewire-pulse) / ALSA; the **Null** backend for tests |
| `src/voice/models.zig` + `build/voice_model.zig` | one catalog `{id,file,source_url,revision,bytes,sha256,license,kind}`; one bundled resource root `…/models/` with `stt/` and `tts/`; build-time SHA-256 check; the verify-through-consumption loader (below) |
| `src/voice/voice_config.zig` | the **only** writer of `voice.json`: the outer schema, `migrate`, the lock and compare-and-retry (below) |
| `src/voice_settings_window.c` (GTK; `*_mac.m` / `*_win.cpp` later) | one Voice window; sections register themselves into it |
| `src/voice/consent.zig` | app-level consent records; keys namespaced `stt.*` / `tts.*` |
| `src/voice_mac.m`, `src/voice_win.cpp` | OS permission / usage-string glue (microphone; Personal Voice) |

The TTS plan's former `src/audio.zig`, `src/audio.c`, `src/models.zig`, `src/voice_settings.zig`,
`src/voice_window.c` are **withdrawn** — TTS uses the paths above. The engine/core files that are
**not** shared stay plan-private: TTS `src/speech_text.zig`, `speech_chunker.zig`,
`speech_queue.zig`, `speech_params.zig`, `speech.h`, `speech_backend.h`, `zb-speech`; STT
`src/voice/stt_engine.zig`, `whisper_engine.zig`, `dictation.zig`.

**One audio API.** `AudioSource`/`AudioSink` are vtable interfaces over blocks of f32 samples.
Capture always delivers **16 kHz mono f32 in [-1,1]**; playback runs at the producer's rate. One
`ma_context` per process. A capture callback writes a lock-free ring buffer drained on the consumer
thread; no GTK/AppKit/Win32 call ever runs on an audio thread. Device loss (unplug, route change)
ends the session with `error device-lost` and never hangs.

**One `voice.json` schema, migration, lock and single writer.**
- Outer object: `{ "schema": <int>, "read_aloud": { … }, "dictation": { … } }`. `voice/voice_config.zig`
  is the **only** module that writes the file; both sections call it.
- A mutation: acquire the OS advisory lock on `voice.json.lock`; read the file + its `schema`; run
  `migrate(old)->current` if needed; merge **only the caller's own section**; **preserve unknown
  top-level keys and the sibling section byte-for-byte**; write via `atomic_file.replaceJson`;
  release the lock. A generation counter + compare-and-retry covers a writer that slipped in before
  the lock (belt and suspenders).
- `migrate` is pure and tested vN→vN+1: lossless for known keys, untouched for unknown ones.
- **Red suite (VF):** two windows (or two processes) open; interleave a `read_aloud` write and a
  `dictation` write; assert both changes persist, an unknown top-level key survives, and no write
  is lost (mutant: drop the lock / last-writer-wins ⇒ a lost update ⇒ red). A `schema`-bump fixture
  proves `migrate` runs and preserves the sibling byte-for-byte.

**Model integrity pinned through consumption.** The loader verifies size + SHA-256 and then loads
**the verified bytes**, never a re-opened path:
- STT: `whisper_init_from_buffer_with_params(verified_bytes, params)` (not `whisper_init_from_file`).
- TTS/ONNX: `OrtCreateSessionFromArray(verified_bytes)` (not a path), or a single OS handle opened
  once, verified, and memory-mapped for the load.
- A `(size, mtime, inode)` record is a **performance hint only**, never the identity proof.
- **Red (VF):** at the verify/use seam, replace or truncate the file after verify and before load;
  the load must consume the verified bytes/handle, and the swapped file must never reach the engine
  (mutant: reopen-by-path ⇒ the swapped bytes load ⇒ red). "The bundle is read-only" is an install
  policy, not an identity proof on the per-user Windows layout or under a test override.

**The test-device rule (automated runs never touch a real device).** Every automated run uses the
miniaudio **Null** backend, a `WavFileSource`/`SilenceSource`, and a render-to-file **`FileSink`** —
never Core Audio/WASAPI/PulseAudio/ALSA, and never a "muted real device". A hermetic **privacy write
oracle** runs the process in a test-owned temp/mount namespace with a file-open census and asserts
that, on complete/cancel/error, **no audio-derived bytes are written anywhere EXCEPT the one
`FileSink` artifact path the test explicitly declared** (the oracle allowlists exactly that path, and
a render-to-file test asserts the artifact exists; every other audio-derived write — temp, log, cwd —
fails the test). A dictation/no-output test declares **no** `FileSink`, so any audio-derived write
fails. Every PCM/transcript buffer is zeroed (`std.crypto.secureZero`) at session end. Only the
orchestrator's user-approved `real_audio_check` / `real_screen_check` open a physical device.

**The native arbitrary-child interface `ZbChild` (NOT the agent `SandboxBackend`).** The production
`SandboxBackend` is a **Python, agent-home-specific** launch contract
(`agent/host/zb_agent_host/sandbox.py`); the speech engine and the cloning-enrolment helper are
**native** children the browser spawns, so VF defines its own `ZbChild` platform interface,
implemented per OS:
- inherits **exactly** the PCM pipe (and, for enrolment, the sample pipe) and nothing else; **no
  network**; read-only model dir; write only its own scratch; **no audio device** (the browser
  plays/records);
- parent-death kill (Linux `PR_SET_PDEATHSIG`; macOS kqueue `NOTE_EXIT` or a watchdog; Windows a
  **Job Object** with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`, create-suspended → assign → resume, per
  the Windows plan's bead `zigBrowser-d1d`), child reaping, graceful shutdown, and explicit
  **main-loop ownership** (which thread pumps the pipe);
- Linux reuses bwrap-style confinement where it fits; macOS uses the macOS plan's MS6 Seatbelt
  profile; Windows uses the Windows plan's **WS8.7** no-network `zb-speech` sandbox user + WFP.
- VF names the interface and ships the Linux impl + reds; each platform slice (M1, W1) implements
  and live-verifies its own.

**VF red suite + dependency edges.** VF ships, each red-first on Linux: `voice/audio.zig` +
`audio_miniaudio.c` (Null + WavFile + FileSink), `voice/models.zig` + `build/voice_model.zig`
(catalog + verify-through-consumption), `voice/voice_config.zig` (schema + migrate + lock),
`voice_settings_window.c` (shell + section registry), `voice/consent.zig`, and `ZbChild` (Linux).
Consumers declaring `depends on VF` — TTS: V2, V3, V3.0, V5, C1-C3, M1, M2, W1, W2, CW. STT: VS1,
VS3, VS4, VS5, VS6, VS7, VS8, VS9, VS10, VS11, VSP.
<!-- VF:END -->

**STT-specific notes (outside VF).** STT itself needs no native child today — whisper runs
in-process — but it shares VF's `ZbChild` interface for the TTS engine and any future out-of-process
STT. The `--e2e-protocol` rows this section covers (D6): STT emits `DRAWER voice …` / `VOICE model`
…`, TTS emits `VOICE tts …`.

## 4a. Review-clearing contracts (rev 2.1)

These contracts clear the nine blockers in RoseCat's `9a6973b` STT review. Each is a failing-first
test in the slice named.

1. **Async lifetime and cancellation (clears review #1).** Every dictation has a **session epoch**
   `(win, u64)`. The mic control, the `AudioSource`, the engine worker and every queued callback
   carry the epoch they were started under. `cancel` is **idempotent** (a second cancel is a no-op)
   and bumps the epoch; a permission, preparing, transcription, queued-result or idle callback whose
   epoch ≠ the window's current epoch is **dropped** before it touches the drawer. Close/restart
   **joins/drains** the worker and the audio thread in a fixed order (stop capture → signal abort →
   join worker → `secureZero` buffers → free), so no callback targets a destroyed drawer. VS4 reds:
   a late transcription after cancel, a result after close, and a restart during transcription each
   insert nothing and leave the live-session count at 0 (mutant: ignore the epoch ⇒ a stale insert).

2. **First-use privacy notice as real UI (clears review #2).** The first-use notice is a **VS5 UI
   assertion**, not only a `consent.zig` record: the notice shows before the first capture; **no
   audio is captured before Accept**; Decline leaves the mic insensitive; the choice persists; a
   corrupt/missing consent record re-prompts (never silently allows); a reset re-prompts. Windows has
   **no OS prompt**, so the app notice is the only gate there. VS8 adds the **drawer denial UI**
   before VS9 creates the Mac drawer. A **headless native permission contract** test
   (`tests/e2e/voice_permission_contract_test.py`) drives the permission layer with fake OS statuses
   (granted/denied/restricted/undetermined) and asserts the state machine, with no real device.

3. **macOS mic source bound to the signing/census route (clears review #3).** `src/voice_mac.m`
   compiles on the **same chained-fixups dylib / Apple-clang route** as the existing Objective-C, and
   the DMG signer applies the **hardened runtime plus `NSMicrophoneUsageDescription` and
   `com.apple.security.device.audio-input`**. VS8 proves capture works under the signed, hardened
   build and that the component census and the macOS plan's two-tree `resource_compat` accept it —
   **without** reintroducing the Intel signed-binary crash (the macOS plan's known failure). Named
   files/tests: `packaging/macos/*` signer step, `tests/mac/voice_entitlement_test.py`.

4. **Range-aware insert ABI (clears review #4).** `zb_drawer_set_draft` (whole-draft replace) is
   replaced by `zb_drawer_insert_text(win, const char *utf8, size_t len, int replace_selection)`:
   it inserts at the cursor and replaces the current selection, as D4 invariant 2 requires. Tests
   (GTK and Windows WS5 drawer): Unicode/grapheme boundaries, an active selection is replaced,
   focus-change between start and result targets the right field (or drops on the epoch rule), and a
   late result after the user kept typing inserts at the **current** cursor, not the old offset.

5. **Medium artifact + verify/load race (clears review #5).** The catalog/installers need **one**
   default artifact; O1 stays the user's decision but is **sharpened** (§5): `q5_0` (539 MB, lowest
   accuracy), `q8_0` (823 MB, near-f16 accuracy, recommended default pending O1), `f16` (1.53 GB,
   reference accuracy, 2× install). The verify/load race is closed by **VF's
   verify-through-consumption** (`whisper_init_from_buffer_with_params` over the verified bytes; no reopen; the
   `(size,mtime,inode)` cache is a perf hint only). VSP tests cover not just fresh install but
   **upgrade, repair, downgrade, tamper (swapped/truncated file at the verify/use seam), and orphan
   cleanup** of an old model on upgrade.

6. **CPU baseline (clears review #6).** "Windows x64" does not imply AVX2/x86-64-v3. O1 is sharpened
   to a **minimum-CPU-vs-runtime-dispatch** trade-off (§5): (a) a single x86-64-v3 baseline build
   (simplest; refuses on older CPUs with "Voice input needs a newer processor"); (b) runtime
   dispatch or a baseline SSE build (wider reach, more build/test cost). The test matrix adds a
   **real non-AVX2 target** (or an emulated one) that must either run or refuse cleanly — never an
   illegal-instruction crash. The decision stays the user's; both paths are specified.

7. **Failing-first made executable (clears review #7).** VS0.2's "or record that it compiled first
   time" is removed: VS0.2 ships a **registration/object oracle or a build mutant** (as WS0 does for
   `cross-check`) so a red precedes the green. VS9, VS10, VS11 and VSP2-VSP4 each gain concrete
   **red, registration and mutant** steps; a census seam does **not** substitute for native UI input
   in a UI closure — the AppKit/Win32 dictation UI slices name a native-input red (synthetic key/clic
   through the OS, asserted at the drawer).

8. **Live capture behind an unforgeable capability (clears review #8).** The shipping executable's
   `--voice-selftest` and `--voice-capture-probe` entry points are gated by an **unforgeable
   inherited capability** (an inherited descriptor/handle the browser passes only to itself), or
   built only into a **test-only binary**. A negative test from **every real sandbox** (agent helper,
   each hook) proves agent/hook code cannot reach a live capture path — not merely that no frame/tool/
   socket method names it.

9. **Remote packaging model-transfer protocol (clears review #9).** The model reaches the Mac and
   Windows builders by an **orchestrator-only** cache transfer: a named remote cache location, a
   **pre-transfer and post-transfer SHA-256** check against the catalog, owner-only permissions, a
   cleanup step, and a **package-input manifest** listing the exact file + hash that entered each
   build. No builder fetches from the network during a gated build.

**SHOULD items folded (rev 2.1):** typed `preparing`/`model`/`device` errors and explicit
**ring-buffer bounds**; the VF **write oracle** replaces the global `/tmp` scan (D-invariant 4 /
VS4.3) and every PCM/transcript buffer is `secureZero`-ed; an ambiguous capture reports **`no-signal`
with the specific HRESULT** rather than claiming Windows denied permission; **AppKit (VS9) and Win32
(VS11) settings-window** sections are named; third-party notices are packaged; dependency status is
repinned; cleanup rules use guard clauses, no side-effectful conditions, and named timing/sample
constants. The WiX directory id is **`INSTALLFOLDER`** (not the plan's `<INSTALLDIR>`).

## 5. Decisions for the user

Decided so far (2026-10-19): the medium model (0.2.3), **O2 bundle in the installer** (0.2.4), and Windows through the Windows launch plan with Windows 10 support (0.2.5, which replaces the old O7). **O5 is moot for v1.** The rest are still open; each has a recommendation and the trade-offs. None is decided by this plan.

**O1. Which medium file ships by default.** Medium itself is decided (0.2.3).

| Option | Size | Accuracy | Speed |
|---|---|---|---|
| f16 `ggml-medium.bin` | 1.53 GB, ~2.1 GB RAM | reference | on Metal, slightly faster than quantized (M2 Ultra rows); on CPU, unmeasured vs quantized |
| q8_0 `ggml-medium-q8_0.bin` | 823 MB | generally near-lossless (common knowledge, not a cited measurement) | on Metal ~7% slower than f16; on AVX2 CPU unmeasured |
| q5_0 `ggml-medium-q5_0.bin` | 539 MB | lower; unmeasured | one old non-AVX CPU was much slower with q5_0 (research 4.4); AVX2 unmeasured |

- **Recommendation: q8_0, multilingual,** confirmed or overturned by VS7's measurements on the Intel Mac and VS10's on the physical Windows 10 machine. Because the model is now bundled (O2), this choice **sets the installer's size directly**: q8_0 adds 823 MB, f16 1.53 GB, and q5_0 539 MB to every DMG, MSI and .deb. q8_0 halves that versus f16 with the smallest expected accuracy loss.
- Trade-offs:
  - f16 doubles the installer growth, disk and RAM for a small accuracy gain.
  - q5_0 is the smallest, but its accuracy and CPU speed are unmeasured.
  - The `.en` variant is English-only but may be slightly more accurate for English. It is unmeasured here.

**O2. Bundle the model in the installer vs download on first use. — DECIDED 2026-10-19: bundle in the installer.**
- The user's words: "Bundle in the installer." Dictation works offline from the first launch, and there is no first-run download.
- Rev 1 had recommended download on first use, because of installer size. The user chose bundling. The plan now carries these consequences:
  - Every installer grows by the O1 file, and every app update carries it again.
  - The macOS bundle gains a large signed resource, which must be byte-identical in both arch slices and pass the resource census and `resource_compat` (VSP, MS5.1c).
  - Integrity is checked at build time and at first load (D5).
  - VS2 (consented download) is **no longer on the v1 path**. It stays only as an optional, later update or alternate-model path (VS2, marked optional).
  - MSI cabinet size limits at this scale are unverified (VSP measures).

**O3. Push-to-talk vs toggle.**
- **Recommendation: toggle by default.** Click the mic, speak, then click again or press the shortcut to stop. Add an optional VAD auto-stop after 1.5 s of silence, plus an optional hold-to-talk shortcut.
- Reasoning:
  - Toggle works with a mouse, a trackpad and accessibility tools.
  - Hold-to-talk is faster for short phrases, but needs a key that the page and the drawer do not use. Ctrl+Shift+Space is taken (`src/agent_drawer.c:1038`). Proposed: Ctrl+Shift+M (macOS Cmd+Shift+M), unverified for conflicts.
- Trade-offs: VAD auto-stop can cut off slow speakers; it is off by default in the recommendation.

**O4. Latency target and slow-hardware fallback.**
- Medium on a laptop CPU may take tens of seconds per utterance (research 4.4). **Recommendation:**
  - Set the target "text appears ≤ 3 s after the user stops, for a 10 s utterance" on Apple Silicon, and measure the Intel Mac and the physical Windows 10 machine in VS7/VS10.
  - If the Intel Mac or the Windows 10 machine misses the target by a wide margin, the user decides whether slow machines are offered a smaller model (for example small q8_0 at 264 MB) as an explicit, labeled choice in settings.
- Trade-offs:
  - Medium-only keeps one quality level but may feel broken on slow PCs.
  - A fallback adds a second catalog entry and a second test row. Because models are bundled (O2), it also adds its size to every installer, unless the fallback alone is downloaded, which would bring back VS2 and O5.

**O5. Where the model is downloaded from. — Moot for v1 (the model is bundled, O2).**
- The running browser makes no model request. Only the release build fetches the file, from Hugging Face `ggerganov/whisper.cpp` pinned to revision `5359861c…` and checked by SHA-256 (D5). That is a build-machine fetch, not a product network destination.
- O5 returns only if the optional update path (VS2) or a downloaded fallback model (O4) is ever built. Then the choice is again Hugging Face vs a project-controlled mirror, and it is the user's.

**O6. Web pages.** Is page `getUserMedia` permission handling, a `SpeechRecognition` polyfill, or dictation into page fields in scope?
- **Recommendation: none in v1.** Track VW as a separate plan, starting with page permission prompts, which browsers need anyway.
- Dictation into page fields is the most user-visible of the three and is the next candidate.

**O7. The Windows drawer. — DECIDED 2026-10-19: the separate Windows launch plan (WLP) covers it.**
- WLP (`thoughts/searchable/shared/plans/2026-10-19-windows-launch-tdd-plan.md`) covers the drawer port (WS5), the helper (WS11) and the test hosts (WS0: the Win11 VM `win11-m8` and the physical Windows 10 machine).
- VS11 (Windows drawer dictation) depends on WS5 and the WS12.1 hook. VS10 (Windows engine and capture) depends on WS0 and WS1. VSP.4 depends on WS13.

**O8. Model memory policy.**
- **Recommendation:** load on first dictation and free after 10 minutes idle (tunable). The alternative is keeping it loaded for instant start at a cost of about 1-2 GB of RAM held by the browser.

## 6. Desired end state and observable behaviors

A Mac user (both arches) and a Windows x64 user on Windows 10 or 11 can:
1. install zigBrowser and dictate **offline from the first launch**, because the medium model is inside the installer;
2. click the drawer's mic control, grant the OS permission the first time, speak, see "Listening…", stop, see "Transcribing…", and find the text at the cursor in the input box;
3. edit it and press Enter to send it. Nothing is sent before that.

Audio stays in memory and never reaches disk or the network. Denied permission, no signal, a missing or damaged bundled model, an unsupported CPU and device loss each give a plain message and recover. Linux supports all of this for development.

Observable behaviors (each is a slice behavior below):
- Given a WAV fixture and the real engine with a test model, when the transcriber runs, then the known sentence comes back (VS0).
- Given a model file whose SHA-256 differs from the catalog, then the build fails (VSP), and at run time the file is not loaded (VS1).
- Given each installer, then the model inside it is the pinned file, and on macOS it is byte-identical in both arch slices (VSP).
- Given any WAV at any rate and channel count, when it is captured, then the consumer gets 16 kHz mono f32 within a tolerance (VS3).
- Given a dictation, when it ends in any way, then no audio byte is on disk, and the buffer is zeroed (VS4).
- Given the drawer, when the user dictates, then the text appears at the cursor and no `msg user` row or prompt frame exists until the user presses Enter (VS5).
- Given a denied macOS permission, when the user starts dictation, then the drawer shows the denial and the settings button, and no capture starts (VS8).

## 7. What we are NOT doing

- No web-page microphone permission handling, no `SpeechRecognition` polyfill, and no dictation into page fields (track VW, decision O6).
- No Windows drawer port or Windows test-host setup here; both belong to WLP (WS5 and WS0). No Windows arm64 build.
- No first-run model download and no product network request for models (O2 bundled; VS2 is optional and later).
- No GPU acceleration on Windows (Vulkan, CUDA, OpenVINO), no Core ML encoder, and no Metal on Intel Macs unless VS7 shows it helps.
- No live partial transcripts while speaking (batch after end-of-speech; D3).
- No cloud recognition, no Apple Speech framework, no SpeechAnalyzer, and no sherpa-onnx (the user chose whisper.cpp).
- No voice commands ("send", "new line") or punctuation commands. Text is inserted as transcribed.
- No transcription of audio files chosen by the user, and no wake word.
- No agent-initiated dictation. The agent gets no voice tool.
- No change to the agent sandbox's network allowlist.
- No text-to-speech (the sibling plan), beyond declaring the shared interfaces in section 4.

## 8. Testing strategy

**Frameworks:**
- Zig `std.testing` with seeded `std.Random.DefaultPrng` property loops (the repo's pattern, e.g. `tests/automation_x_test.zig:463`).
- Python e2e driving the real binary under `xsession.py --xvfb` with `xinput.py` (Linux), `tests/e2e/mac_session.py` (planned in the macOS plan) over SSH on the Macs, and WLP's `tests/windows/gate.sh --phase voice` (WS12.2) on the two Windows hosts.

**Headless by design:**
- Recognition tests use `WavFileSource` and either `FakeEngine` (fast, deterministic) or the real engine with the **test model** `ggml-tiny.en.bin` (77,704,715 B, SHA-256 `921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f`).
  - The size and SHA-256 were read from the HF API listing on 2026-10-19 (revision `5359861c…`).
  - The test model is provisioned once by `tools/fetch_voice_test_models.sh` into `$ZB_TEST_MODEL_DIR`, run by the orchestrator, never by a gate.
  - A gate step that needs it and does not find it **exits 1**.
- Medium is used only in the manual benchmark (`zig build voice-bench`), the Mac/Windows accuracy checks and the **packaging gates** (VSP), never in the per-commit gate. The packaging gates need the medium file in `$ZB_VOICE_MODEL_CACHE` (provisioned by the orchestrator with `tools/fetch_voice_model.sh`). Without it they exit 1.

**Audio fixtures** (`tests/fixtures/voice/`):
- `jfk.wav` from the vendored whisper.cpp `samples/`. The speech is a US government work; its license status as a fixture is unverified, and the test may use it from the package cache instead of committing it.
- Plus generated fixtures: silence, −80 dBFS noise, a 1 kHz tone, 44.1 kHz stereo and 8 kHz mono resamples of `jfk.wav` (made by the test with miniaudio, not committed).
- A 65 s concatenation for the maximum-length test.

**Live-microphone behavior** is checked only in the real-hardware checks (section 8.1), with the user's microphone and the user's permission.

**Red-commit rule:** each slice's red tests land in files or steps **not yet registered** in `build.zig`'s `test_step` or the Mac/Windows gates. The green commit registers them. A red e2e is recorded by running it directly (`python3 tests/e2e/voice_*_test.py --binary …` under `xsession.py --xvfb`), not through the gate.

**Fail-closed:** missing Xvfb, libXtst, `xwd`, the test model, a Mac host or a Windows host is exit 1. Zero assertions is a failure. A live-capture test is never registered on a host without a proven capture device, so "no device" is never turned into a SKIP. That matches WLP's WS12.2 rule that `NOT RUN: no capture device` fails the gate.

**Mutants:** every closure test lists the mutant that must turn it red. Per project memory, the mutant is actually run and observed red before the closure is claimed.

### 8.1 Real-hardware checks (UI slices)

The orchestrator runs these with the user. Agents only prepare them and dry-run them on a private Xvfb with the WAV seam.

| Case | Slice | Where | What the user does | Pass |
|---|---|---|---|---|
| `drawer-voice-idle` | VS5 | Linux, user's NVIDIA screen | nothing | screen capture shows the mic control in the composer row; page and drawer drawn (drawer plan §7.1 pixel rules) |
| `drawer-voice-live` | VS5 | Linux, user's screen and mic | clicks mic, reads a printed sentence, clicks stop | indicator visible while listening; text appears in the box; nothing sent; word error rate (WER) vs the printed sentence ≤ 15% (tunable, recorded) |
| `voice-settings` | VS6 | Linux | opens Voice settings | window drawn; the bundled model's name, size and "Ready" shown; settings saved |
| `mac-voice-permission` | VS8 | each Mac, user at the screen | first dictation → OS prompt → Allow; then `tccutil reset`, Deny | prompt names zigBrowser with the usage string; Deny shows the drawer message and settings button |
| `mac-drawer-voice-live` | VS9 | each Mac | as `drawer-voice-live` | same, on both arches |
| `win-voice-permission` | VS10 | the physical Windows 10 machine (WLP WS0, [W10]), user at the screen as `zbtest` | dictation with the per-user desktop-apps microphone switch on, then off | on: text captured; off: the drawer-less selftest reports the blocked message and the settings link |
| `win-voice-live` | VS11 | **the physical Windows 10 machine only** (WLP [W10]). It is added on the Win11 VM `win11-m8` only after a VM capture device is proven (D8) | as `drawer-voice-live`, in the WS5 drawer | same; run through WLP's real-screen runner |

The real-screen script gains these cases. The input guard (drawer plan §7.1) applies to every click. A sentence card is shown to the user; the script never records the user's audio to disk. It reports only the WER and timings.

## 9. Workflow closure

### 9.1 ClosureMap V-A: dictation into the drawer (from research §Workflow Closure Map, pinned `a69b459`)

`X click on mic (new) → dictation.start (new) → AudioSource (WAV seam) → engine.transcribe (worker thread) → g_idle insert at cursor (new) → [user's X Enter] → on_input_key → send_input → add_message → DRAWER msg user <text> (src/agent_drawer.c:732)`

- BLOCKING: four async edges (X→GTK, capture thread, engine thread, idle) and a registration boundary (the new `g_signal_connect` in `build_panel`).
- `highest_new_connector` = the mic control's click handler.

### 9.2 ClosureMap V-B: the bundled model reaches the engine (rev 2; replaces the download chain)

`cached model file → voice-model-check (build: size + SHA-256 vs catalog) → install step copies to share/zigbrowser/models/stt/ → packaging puts it in the .app / MSI / .deb → installed app starts → first dictation → models.locate (bundled resource dir) → first-load verify (engine thread) → whisper_init_from_buffer_with_params over the verified bytes → VOICE model <id> ready row + Voice settings shows "Ready"`

- BLOCKING: build-to-package-to-run crosses three registration boundaries (build step, packaging script, app start) and one async edge (the engine thread verifying, then an idle back to GTK).
- SOURCE: the cached model file (the medium file in packaging gates; a small fake model with an injected catalog entry, `ZB_E2E_MODEL_CATALOG`, inert without `--e2e-protocol`, in the per-commit gate).
- RED-AT-SEAM: flip one byte in the cached file → `voice-model-check` fails the build. Flip one byte in the installed copy → `VOICE model <id> damaged`, and no load over the verified bytes happens.

The rev-1 download chain survives only as VS2's optional closure.

### 9.3 ClosureMap V-C: denied permission

`mic click → permission check (OS glue) → denied → dictation error(permission-denied) → drawer status + settings button → DRAWER voice error permission-denied row`

- BLOCKING on macOS (TCC is cross-process).
- On Linux the denial is simulated by a capture-open failure through the e2e seam `--e2e-voice-source deny`.

## 10. Slices

Every slice:
1. Mail "taking the gate slot" for the gate run only.
2. Write the red tests in **unregistered** files or steps and record the red runs.
3. Green: register the steps.
4. Refactor.
5. Quiet gate from a clean `git archive HEAD` plus the slice's files.
6. Commit only the slice's files.
7. Mail the reviewer (RoseCat).
8. For a UI slice, add its real-hardware case and ask the orchestrator to run it.

A UI slice is approved only after that run passes. A closure e2e that prints SKIP is UNCLOSED.

Platform marks:
- **[L]** built and tested entirely from Linux.
- **[L+X]** Linux, plus cross-check objects for macOS and Windows.
- **[M]** needs both remote Macs.
- **[W]** needs Windows through WLP's gate (WS0): the build on the Win11 VM `win11-m8` (WS1), recorded-file tests on both hosts, and live-microphone tests on the physical Windows 10 machine only.
- **[P]** packaging slice: needs the medium file in the model cache.
- **[U]** UI slice with a real-hardware check.

---

### VS0 — whisper.cpp builds under `zig build` and transcribes a WAV [L+X]

**Goal.** The engine exists and is proven on Linux with a real model, and its CPU objects compile for the Mac and Windows targets.

#### Behavior VS0.1: `zig build whisper-smoke` transcribes `jfk.wav` with the tiny.en test model
- **Given / When / Then:** given `$ZB_TEST_MODEL_DIR/ggml-tiny.en.bin` (SHA-256 checked) and `jfk.wav`, when `zig-out/bin/zb-whisper-smoke` runs, then stdout contains, case-insensitively and ignoring punctuation, "ask not what your country can do for you".
- An absent or wrong model exits 1 with `model missing` or `model checksum mismatch`.
- LEAF (one process, synchronous). Integration test.
- **Property:** no property — fixed input, nothing to generate over.
- **Files touched:** `build.zig.zon` (whisper.cpp v1.9.5 dependency + hash), `build.zig` (`whisper` static library step, `zb-whisper-smoke` exe, `whisper-smoke` step), `tools/whisper_smoke.zig` (new), `tools/fetch_voice_test_models.sh` (new; run by the orchestrator).
- 🔴 `tests/e2e/whisper_smoke_test.py` (unregistered) fails: no such binary.
- 🟢 Add the dependency, the library step (D7 file list, explicit baseline flags, `-O3` for vendored files) and the tool.
- 🔵 Put the vendored-library definition in one `build/whisper.zig` helper module called from `build.zig`, so VS7 and VS10 reuse it per target. No duplicated flag lists.

#### Behavior VS0.2: the CPU objects compile for the other targets
- **Given / When / Then:** when `zig build cross-check` runs, then ggml-cpu and whisper objects are emitted for `aarch64-macos`, `x86_64-macos` and `x86_64-windows-gnu`, and the existing symbol check still passes.
- LEAF.
- **Files touched:** `build.zig` (cross-check list).
- 🔴 Add the objects to an unregistered `cross-check-voice` step with a **failing-first oracle** (as
  WS0 does for `cross-check`): a `--require`/registration or object check that is **red** before the
  step is wired, or a small build mutant (drop a required object) that must flip it. "It compiled
  first time" is not an acceptable record — the slice must demonstrate a red before it joins
  `cross-check` (§4a #7).
- 🟢 Fold it into `cross-check`.
- 🔵 One per-target flag table.

**Gate (VS0):** Linux gate plus `whisper-smoke`. Not a UI slice.

---

### VS1 — Model catalog, bundled-model locator and first-load check (shared with TTS) [L]

Rev 2: the model is bundled (0.2.4), so VS1 locates and verifies a **read-only bundled file**. It no longer installs one.

#### Behavior VS1.1: the bundled resource directory resolves per OS
- **Given / When / Then:** given an injected executable path, OS tag and environment, `models.bundledDir` returns:
  - macOS: `<exe>/../../Resources/models/stt` (inside `zigBrowser.app/Contents/`)
  - Windows: `<exe dir>\models\stt`
  - Linux: `<exe>/../share/zigbrowser/models/stt` (covers both `/usr/bin` → `/usr/share` and `zig-out/bin` → `zig-out/share`)
  - `ZIGBROWSER_MODEL_DIR` wins everywhere.
  - An unresolvable path gives a typed error, never a cwd-relative path.
- LEAF. Unit tests for all three OS tags on Linux (the function takes the OS tag as a parameter).
- **Property:** Oracle against a small reference table over generated executable paths and env maps (variable present, absent or empty).
- **Files touched:** `src/voice/models.zig` (new), `tests/voice_models_test.zig` (new), `build.zig`.
- 🔴 `tests/voice_models_test.zig` in an unregistered step.
- 🟢 Implement.
- 🔵 One path-joining helper for the three layouts. No per-OS copies of the join logic.

#### Behavior VS1.2: the first-load check refuses a wrong file
- **Given / When / Then:**
  - given a bundled file whose size or SHA-256 differs from its catalog entry, `models.verify` returns `damaged`, the engine is never initialized, and the row is `VOICE model <id> damaged`;
  - given a missing file, `missing`;
  - given a matching file, `ready`;
  - the check runs once per process, on the engine thread.
- LEAF for the decision; the thread edge is covered by VS5's closure.
- **Property:** Invariant. For generated byte strings and a catalog entry built from a *different* string, `verify` never yields `ready`; for the same string it always does.
- **Files touched:** `src/voice/models.zig`, `tests/voice_models_test.zig`.
- Also measured: hashing time for a 823 MB and a 1.53 GB file on the Linux machine (recorded; it feeds the "Preparing voice…" status design).

#### Behavior VS1.3: the medium catalog entries are exact
- **Given / When / Then:** the compiled catalog's three medium entries equal research 4.1's byte counts and SHA-256 values, and their source URLs are pinned to revision `5359861c739e955e79d9a303bcbc70fb988958b1`. A test fails on drift.
- LEAF.
- **Files touched:** `src/voice/models_catalog.zig` (new, data only).

#### Behavior VS1.4: the bundle is never written
- **Given / When / Then:** after any dictation, error or settings change, the bundled directory's file list, sizes and mtimes are unchanged. Checked in the VS5 e2e with a read-only bind of the model directory (`chmod a-w` in the test's own copy).
- LEAF.

**Gate (VS1):** Linux gate. Not a UI slice.

---

### VS2 — Consent-gated model download (shared with TTS) [L] — OPTIONAL, not in v1

**Rev 2 status.** The model is bundled (O2 decided), so v1 needs no download. VS2 is kept only as an **optional later path** for one of these, each needing its own user decision first:
- an alternate model (for example a smaller fallback, O4);
- a model update between browser releases;
- TTS voice downloads, if the sibling plan wants them (it would then own this slice).

If none is chosen, VS2 is dropped. When it is built, O5 (download host) comes back as a user decision, and the behaviors below apply unchanged. The Voice window's Download button (VS6) appears only with VS2.

#### Behavior VS2.1: no consent, no connection
- **Given / When / Then:** given no consent record for an entry, when `download.start(entry)` is called, then it returns `consent-required`, and the fake HTTPS server records **zero** connections.
- LEAF for the refusal (same module); the zero-connection assertion uses the real server.

#### Behavior VS2.2: a consented download installs a verified file, with progress and resume
- **Given / When / Then:**
  - given consent and a local HTTPS server serving a 3 MiB fake model whose entry is injected via `ZB_E2E_MODEL_CATALOG`, when `zigBrowser --voice-model install fake-3m --e2e-protocol` runs, then rows show `VOICE model fake-3m downloading <n>` (increasing), `verifying`, `installed`;
  - killing the process at 50% and rerunning resumes with a `Range` request (the server log shows `Range: bytes=<n>-`);
  - a corrupted response ends `failed:checksum-mismatch` with no installed file.
- BLOCKING (network + worker thread). See the closure test below.
- **Files touched:** `src/voice/download.zig` (new; `std.http.Client` with a CA override for tests), `src/voice/consent.zig` (new), `src/cli.zig` (`--voice-model install|status|remove <id>`), `src/app.zig`, `tests/e2e/voice_model_download_test.py` (new), `tests/e2e/fake_model_server.py` (new; TLS with a throwaway CA; the CA is passed to the client through an e2e-only variable, inert without `--e2e-protocol`).
- 🔴 The e2e is unregistered and fails: the flag is unknown.
- 🟢 Implement the downloader, consent store and CLI.
- 🔵 Resume, verify and rename live in one `install` function used by both the CLI and VS6's window.

#### Behavior VS2.3: the downloader only talks to the catalog host
- **Given / When / Then:** a redirect to a host other than the entry's host (other than Hugging Face's documented CDN redirect host, which is pinned in the catalog as an allowed redirect target) is refused with `failed:redirect-host`.
- The exact CDN host Hugging Face redirects to is unverified; VS2 records it from a real `curl -I` run by the orchestrator.
- LEAF (decision in `download.zig`) plus one e2e case with the fake server redirecting to a decoy.

#### Behavior VS2.4: the agent cannot start or consent to a download
- **Given / When / Then:** no frame type, MCP tool or automation-socket method reaches `download.start` or `consent.record`.
- A static test lists the callers of `download.start`: only the CLI handler and the Voice window's button handler.
- LEAF (negative evidence test, in the shape of drawer plan T3).

**Closure Test VS2: "after consent, the model is downloaded, verified and reported installed" — BLOCKING**
- **SOURCE (seed only):** the fake server's file and the injected catalog entry; a consent record written through `consent.record` by the CLI's `--voice-model consent fake-3m`.
- **TRIGGER:** `zigBrowser --voice-model install fake-3m --e2e-protocol` (outermost entrypoint).
- **DRIVERS:** the real HTTPS exchange with the local server; the process's own worker; no sleeps (rows are awaited).
- **OBSERVE:** `--voice-model status fake-3m` prints `installed <sha256>` (the production read path), plus the `VOICE model` rows.
- **FORBIDDEN SPAN:** `download.*`, `models.verify`, `models.install`, and writing into the store directory.
- **RED-AT-SEAM:** make `install` skip `verify` → the corrupted-response case installs → red. Remove the consent check → VS2.1's zero-connection assertion → red.
- **DRIVABILITY:** the store directory is injectable (`ZIGBROWSER_MODEL_DIR`), and so are the catalog and CA (e2e-only). No missing seam.
- **EXECUTION:** Python `ssl` + `openssl` for the throwaway CA. If absent, exit 1.

**Gate (VS2):** Linux gate + `voice-model-download-e2e`. Not a UI slice.

---

### VS3 — Audio layer (shared with TTS) [L]

#### Behavior VS3.1: any WAV becomes 16 kHz mono f32
- **Given / When / Then:** given WAVs at 8, 16, 44.1 and 48 kHz, mono and stereo, 16-bit and f32, `WavFileSource` yields 16 kHz mono f32, and:
  - the sample count is within ±1 block of `duration × 16000`;
  - a 1 kHz tone keeps its peak frequency within ±5 Hz (FFT in the test);
  - RMS is preserved within 1 dB.
- LEAF.
- **Property:** Metamorphic. For generated tones (100-4000 Hz) and source rates, resampling to 16 kHz keeps the dominant frequency and the duration.
- **Files touched:** `third_party/miniaudio/miniaudio.h` (pinned version; public domain or MIT-0; or a `.zon` dependency, same choice as D7), `src/voice/audio.zig` (new), `src/voice/audio_miniaudio.c` (new; `MA_NO_RUNTIME_LINKING` on macOS per the miniaudio manual), `tests/voice_audio_test.zig` (new), `build.zig`.
- 🔴 Unregistered test.
- 🟢 Implement using `ma_decoder` with output config f32/1/16000.
- 🔵 One conversion path shared by the WAV source and the live source.

#### Behavior VS3.2: live capture lifecycle on the Null backend
- **Given / When / Then:** with miniaudio forced to the Null backend, start → 1 s → stop → start → stop delivers blocks, and leaves no thread or device open (checked by a live-context counter). A second start while running returns `busy`.
- LEAF (one module), run in the unit gate.

#### Behavior VS3.3: device loss ends the session
- **Given / When / Then:** with a test hook that fires miniaudio's stop notification, the source reports `device-lost` within one block, and the consumer is woken (no hang). The test times out at 2 s.

#### Behavior VS3.4: live capture on the developer's Linux machine
- PulseAudio/PipeWire. This is a **manual dev check** (`zig build voice-capture-probe` prints device name, rate and RMS for 3 s). It is not a gate step, because the gate has no audio server.
- It is used by the user's real-hardware check in VS5.

**Gate (VS3):** Linux gate. Not a UI slice.

---

### VS4 — Dictation core: state machine, engine thread, privacy invariants [L]

#### Behavior VS4.1: the state machine
- **Given / When / Then:** for each event sequence, `dictation.step(state, event)` follows D4:
  - start → listening; stop → transcribing; result → inserted or empty; cancel from listening or transcribing → cancelled;
  - a second start while active → `busy`; max length → transcribing with a `max-length` notice;
  - error events map to `error(reason)`.
- LEAF.
- **Property:** Invariant. For generated event sequences (length ≤ 50), the machine never reaches `inserted` after `cancelled` in the same session, never has two active sessions, and every sequence ends in a terminal state or `idle` after a terminal event. Seeded PRNG loop.
- **Files touched:** `src/voice/dictation.zig` (new), `tests/voice_dictation_test.zig` (new).

#### Behavior VS4.2: the engine thread transcribes and can be aborted
- **Given / When / Then:**
  - given `FakeEngine fake-delay:2000:hello`, cancel after 100 ms returns `cancelled` within 200 ms and produces no result;
  - given the real engine with tiny.en and `jfk.wav`, the result contains the known sentence;
  - with `audio_ctx` sized to the recording, it still does (accuracy guard).
- BLOCKING inside the core (thread edge); covered by VS5's closure. Here it is a Tier-2 integration test.
- **Files touched:** `src/voice/stt_engine.zig`, `src/voice/whisper_engine.zig` (new).

#### Behavior VS4.3: no audio on disk, buffers zeroed
- **Given / When / Then:**
  - the VF **write oracle** (§4) runs the session in a test-owned temp/mount namespace with a
    file-open census and asserts that, on complete/cancel/error, **no audio-derived bytes are
    written anywhere** (not the fragile global-`/tmp` RIFF/64 KiB heuristic, which can fail on
    another process or miss a different encoding/dir), and that every PCM/transcript buffer is
    `secureZero`-ed;
  - the session's buffer owner reports `zeroed=true` through a test-only accessor.
- LEAF.

#### Behavior VS4.4: the transcript is not logged
- **Given / When / Then:** with a canary phrase in the FakeEngine's text, stderr and every log contain no canary without `--e2e-protocol`. With it, only `DRAWER voice inserted <len>` (length, not text) appears.
- LEAF. It mirrors the drawer plan's canary scans (`agent_common.py`).

#### Behavior VS4.5: the medium benchmark tool (manual, not gated)
- `zig build voice-bench -- --model PATH --wav PATH --runs 5` prints load time, encoder and decoder ms, and end-to-end ms for 5 s, 10 s and 30 s utterances, with `audio_ctx` default vs sized.
- The orchestrator runs it on the Linux machine, both Macs (VS7) and both Windows hosts (VS10). Results are recorded in this plan's appendix and decide O1 and O4.
- No test: it is a measurement.

#### Behavior VS4.6: `--voice-selftest` runs the whole core without a window
- **Given / When / Then:** `zigBrowser --voice-selftest wav:PATH --e2e-protocol` locates and checks the bundled model (VS1), runs one dictation session from the WAV through the real engine, and prints `VOICE model <id> ready` and `voice inserted <len>` (and the text, under `--e2e-protocol` only). Without `--e2e-protocol` it is usage (exit 2), like the D6 seams.
- This is the headless probe that VS7, VS8, VS10 and VSP run on the Macs, the Windows hosts and inside installed packages.
- LEAF for parsing; the run is a Tier-2 integration test.
- **Files touched:** `src/cli.zig`, `src/app.zig`, `src/voice/dictation.zig`, `tests/e2e/voice_selftest_test.py` (new).

#### Behavior VS4.7: async lifetime — the epoch rejects every stale callback (clears §4a #1, review #1)
- **Given / When / Then:** each session carries an epoch `(win, u64)`; `cancel` bumps it and is idempotent (a second cancel is a no-op). A permission, preparing, transcription, queued-result or idle callback whose epoch ≠ the window's current epoch is **dropped before it touches the drawer**. Close/restart joins/drains in a fixed order (stop capture → abort → join worker → `secureZero` → free).
- 🔴 **Reds (each a mutant that flips it):** a late transcription delivered **after** cancel inserts nothing; a result delivered **after** close targets no drawer and the live-session count stays 0; a **restart during transcription** does not let the old session's result land. Mutant: ignore the epoch on the callback ⇒ a stale insert ⇒ red.
- **Files touched:** `src/voice/dictation.zig` (epoch, idempotent cancel, join order), `tests/e2e/voice_async_lifetime_test.py` (new).

#### Behavior VS4.8: live capture is unreachable from agent/hook code (clears §4a #8, review #8)
- **Given / When / Then:** `--voice-selftest` and `--voice-capture-probe` require an **unforgeable inherited capability** — a descriptor/handle the browser passes only to itself — **in addition to** `--e2e-protocol`; without the capability they are usage (exit 2), so a sandboxed agent/hook that re-execs the binary cannot start capture. (Or they are built only into a test-only binary; the plan picks the capability form in the green.)
- 🔴 **Negative reds from every real sandbox:** from the agent helper's sandbox and from each hook's sandbox, an attempt to invoke a live-capture entry point **fails** — not merely "no frame/tool/socket method names it", but the entry point itself refuses without the capability. Mutant: gate on `--e2e-protocol` alone ⇒ the sandboxed re-exec reaches capture ⇒ red.
- This slice **owns the sandbox-capture negatives** (they are not left to a summary). The agent-sandbox allowlist (`sandbox.py:51`) is unchanged; the agent never touches audio.
- **Files touched:** `src/cli.zig` (capability check), `src/app.zig`, `tests/e2e/voice_capture_capability_test.py` (new), reused agent/hook sandbox harnesses.

**Gate (VS4):** Linux gate + `voice-core` unit and integration steps + `voice-async-lifetime` + `voice-capture-capability`. Not a UI slice.

---

### VS5 — GTK drawer dictation: mic control, indicator, insert at cursor, never auto-send [L][U]

#### Behavior VS5.1: `--voice-input on|off` and `ZIGBROWSER_VOICE_INPUT`
- **Given / When / Then:** the flag beats the env, which beats the default. The default is off until VS6 lands, then on. With it off, the composer row is unchanged (the `tree` row equals today's).
- LEAF.
- **Property:** Oracle, as drawer S1.1.
- **Files touched:** `src/voice/voice_config.zig`, `src/cli.zig`, `src/app.zig`, `src/webkit.zig`.

#### Behavior VS5.2: the mic control and the indicator
- **Given / When / Then:** given the drawer open with voice on, then:
  - the composer row holds the input, **Mic** (`zb-agent-mic`, accessible name "Start dictation"), Send and Stop;
  - clicking Mic sets its name to "Stop dictation", the status to "Listening… 0 s" (counting), and emits `DRAWER 1 voice listening`;
  - clicking again → "Transcribing…" → back to the previous status.
- Pixel check: the Mic control shows its "recording" colour while listening.

#### Behavior VS5.3: dictated text lands at the cursor and is not sent
- **Given / When / Then:** given the input holds "Please " with the cursor at the end, when the user dictates with the seam `fake:summarize this page`, then the input reads "Please summarize this page", the cursor is after it, `DRAWER 1 voice inserted 19` is emitted, and **no** `DRAWER 1 msg user` row exists, and the fake API received no prompt.
- When the user then presses Enter, then `DRAWER 1 msg user Please summarize this page` appears.
- With a selection, the selection is replaced. With an empty transcript (`fake:`), the result is `voice empty` and nothing changes.

#### Behavior VS5.4: Escape cancels while active and keeps its meaning when idle
- **Given / When / Then:** while listening, Escape → `voice cancelled`, nothing inserted, and the drawer stays open. Idle Escape still minimizes (the existing `:1052` behavior, re-asserted).

#### Behavior VS5.5: errors are plain and recover
- **Given / When / Then:** `--e2e-voice-source deny` → "Microphone unavailable" and `voice error permission-denied`; a missing or damaged bundled model → "The voice model is missing or damaged. Reinstall zigBrowser." with the Mic control insensitive; `fake-error:engine` → "Couldn't transcribe. Try again."; `silence` for 1.5 s → `error no-signal`. After each, the next click works.

#### Behavior VS5.6: one session per process; closing cleans up
- **Given / When / Then:** with two windows, Mic in window 2 is insensitive while window 1 dictates. Closing window 1 mid-session → `voice cancelled`, and the live-session count is 0 (debug seam, like `zb_drawer_debug_live_count`, `src/agent_drawer.c:63`).

#### Behavior VS5.7: the agent cannot start dictation
- **Given / When / Then:** scripted `tool_use` for every registered tool name, plus raw frames of every type, never produce a `voice listening` row. A static census shows no caller of `dictation.start` other than the GTK handlers.
- LEAF (negative evidence).

#### Behavior VS5.8: the first-use privacy notice gates the first capture (clears §4a #2, review #2)
- **Given / When / Then:** on the **first** Mic click with no stored consent, the drawer shows the notice ("Dictation runs on this device. Audio is not saved or sent.") with Accept / Not now, and **no audio is captured before Accept** (the capture source is not opened; a census proves zero `AudioSource.start`). Accept persists the consent (`consent.zig` key `stt.first_use`) and starts the session; **Not now** leaves the Mic insensitive and captures nothing. The choice persists across restarts. A **corrupt or missing** consent record **re-prompts** (never silently allows); a settings "reset voice consent" re-prompts. On Windows there is **no OS prompt**, so this app notice is the only gate; on macOS it precedes the TCC prompt (VS8).
- 🔴 **Reds (mutants):** capture opened before Accept ⇒ the no-capture census fails; a corrupt consent record that silently allows ⇒ red; Not now that still starts a session ⇒ red.
- **Files touched:** `src/voice/consent.zig` (the `stt.first_use` record + corrupt/reset handling), `src/agent_drawer.c` (the notice UI + the no-capture-before-accept gate), `tests/e2e/voice_consent_test.py` (new), and the headless native permission contract `tests/e2e/voice_permission_contract_test.py` (§4a #2).

**Files touched (VS5):** `src/agent_drawer.c` (Mic button in `build_panel`, `:1234-1251`; handlers; idle insert; Escape precedence; rows), `src/agent_drawer.h`, `src/voice/dictation.zig` (C exports `zb_voice_*`), `src/voice/voice_config.zig`, `src/cli.zig`, `src/app.zig`, `build.zig` (new C/Zig sources in `configureGtkBackend`; new e2e step), `tests/e2e/voice_drawer_test.py` (new), `tests/e2e/agent_common.py` (canary helper reuse), `tests/manual/real_screen_check.py` (cases `drawer-voice-idle`, `drawer-voice-live`).
- Production callers and registration: `on_mic_clicked` is connected in `build_panel` next to `:1278-1281`; `zb_voice_on_result` runs from a `g_idle_add` scheduled by the engine thread.

**Closure Test VS5: "the user dictates, the text appears in the input, and it is sent only on the user's Enter" — BLOCKING (X→GTK, capture thread, engine thread, GLib idle; registration in `build_panel`)**
- **SOURCE (seed only):** `--e2e-voice-source wav:jfk.wav` and the tiny.en test model (`ZIGBROWSER_MODEL_DIR` with a verified file); `--agent-drawer on --voice-input on --e2e-protocol`; the fake API for the post-Enter leg (as drawer S5).
- **TRIGGER:** a real X click on `zb-agent-mic` via `xinput.py` (the highest new connector and the outermost user input).
- **DRIVERS:** the X server + `gtk_main`, the real capture and engine threads, and the GLib main loop. Everything is awaited on `DRAWER` rows with `run_interactive_until`; no sleeps.
- **OBSERVE:** after the user's X Return, the existing `DRAWER 1 msg user <text>` row (`src/agent_drawer.c:732`) contains "ask not what your country". **Before** Return, no `msg user` row exists and the fake API log is empty.
- **FORBIDDEN SPAN:** `dictation.*`, `zb_voice_*`, `whisper_engine.*`, the input `GtkTextBuffer`, `send_input`, and any `zb_native_*` synthesized input.
- **RED-AT-SEAM (each mutant run and observed red):**
  - drop the `g_idle_add` insert → the `msg user` text lacks the phrase → red;
  - make the result call `send_input` → a `msg user` row appears before Return → red;
  - disconnect the Mic signal → no `voice listening` row → red.
- **DRIVABILITY:** the store (model directory) and the audio source are injectable; the threads and loop run for real. No missing seam.
- **EXECUTION:** `xsession.py --xvfb`, libXtst, the test model. Any missing → exit 1.

**Real-hardware checks (VS5):** `drawer-voice-idle` and `drawer-voice-live` (section 8.1), run by the orchestrator with the user on the NVIDIA screen and the user's microphone. Not approved until both pass.

**Gate (VS5):** Linux gate + `voice-drawer-e2e`.

---

### VS6 — Voice settings window (shared window) [L][U]

Rev 2: no download or consent UI, because the model is bundled (0.2.4).

#### Behavior VS6.1: the window opens from the drawer and is isolated
- **Given / When / Then:** the drawer header's new "Voice" button opens the window (`VOICESETTINGS shown` row). It is absent from `page.list` and the automation socket's window registry (as the Secrets window, drawer S4.3).

#### Behavior VS6.2: the bundled model's status is shown
- **Given / When / Then:** the "Voice input" section shows the bundled model's name and size. Its status reads "Checking…" while the first-load check runs, then "Ready". A damaged file (the e2e copies a one-byte-flipped model into `ZIGBROWSER_MODEL_DIR`) shows "Damaged — reinstall zigBrowser", and the drawer's Mic control is insensitive.
- **Closure:** ClosureMap V-B's run-time half. The TRIGGER is an X click on the Voice button. The OBSERVE is the `VOICE model <id> ready|damaged` row and the window's status label pixel/text census. BLOCKING (engine thread → idle).

#### Behavior VS6.3: settings persist
- **Given / When / Then:** mode, language and maximum length are saved to `<profile>/voice.json` and reloaded. A corrupt file falls back to defaults with a notice.
- **Property:** Roundtrip `parse(write(s)) == s` over generated settings.

#### Behavior VS6.4: the voice-input default flips to on
- After VS6, `--voice-input` defaults to on, and the existing drawer e2e stays green (as drawer S5.5).

**Files touched (VS6):** `src/voice_settings_window.c` (new) + `.h`, `src/agent_drawer.c` (header button), `src/voice/voice_config.zig`, `build.zig`, `tests/e2e/voice_settings_test.py` (new), `tests/manual/real_screen_check.py` (case `voice-settings`).

**Real-hardware check (VS6):** `voice-settings` on the user's screen.

**Gate (VS6):** Linux gate + `voice-settings-e2e`.

---

### VS7 — macOS engine build (Metal on arm64, CPU on x86_64) and medium measurements [M]

**Depends on:** MS1 (green). It runs on the **unsigned** universal binary (allowed by macOS plan `:1349-1351`), so MS1b does not block it.

#### Behavior VS7.1: the universal binary includes the engine on both arches
- **Given / When / Then:** `tests/mac/gate.sh` builds natively on both hosts; `zb-whisper-smoke` (or `zigBrowser --voice-selftest` with a WAV seam, if the tool is folded in) transcribes `jfk.wav` with tiny.en on **both** hosts. The arm64 run reports `backend=metal`, the x86_64 run `backend=cpu`. `mac_universal_test.py` still finds one fat Mach-O.
- **Files touched:** `build/whisper.zig` (Metal embed step for arm64; Accelerate on both), `build.zig`, `tests/mac/gate.sh` (voice smoke on each host), `tests/e2e/mac_voice_smoke_test.py` (new).
- 🔴 The Mac voice smoke, unregistered in `gate.sh`, fails on arm64 (no Metal) and/or both (no engine).
- 🟢 Implement.
- 🔵 One per-target table in `build/whisper.zig`.

#### Behavior VS7.2: the Metal shader embeds without Xcode's `metal` tool
- **Given / When / Then:** the arm64 build contains the `__DATA,__ggml_metallib` bytes (checked with `otool -s __DATA __ggml_metallib` or the chosen symbol), and the first run compiles them (logged).
- If the embed cannot be reproduced in `build.zig`, the fallback is shipping `default.metallib` built by `xcrun metal` on the arm64 host. That would add a non-Mach-O resource to `universal_components.json` (MS5.1c's resource rules) and needs review.

#### Behavior VS7.3: medium measurements decide O1 and O4 (manual, recorded)
- `voice-bench` runs on both Macs with all three medium files and 5/10/30 s utterances, `audio_ctx` default vs sized.
- Results go into this plan's appendix as a table, with WER on a fixed 10-sentence fixture set.
- The user then decides O1 (file) and O4 (fallback).

**Gate (VS7):** two-host `mac-gate` + the voice smoke. Not a UI slice.

---

### VS8 — macOS microphone permission and capture [M][U]

**Depends on:** VS3, VS7, MS1.
- **Live-mic and permission behaviors on the Intel host need a signed `.app`,** so they depend on **MS1b** (the ad-hoc-signed x86_64 crash).
- Until MS1b is green, VS8's permission checks run on the arm64 host only (its signed slice runs, macOS plan `:567-570`), and the Intel results are marked pending.

#### Behavior VS8.1: headless WAV-path dictation over SSH (no TCC involved)
- **Given / When / Then:** on both hosts, `zigBrowser --voice-selftest wav:jfk.wav --e2e-protocol` (no mic, no AppKit window needed) transcribes with the real engine and prints `voice inserted <len>`.
- This proves capture-free parity on both arches without a GUI session.

#### Behavior VS8.2: the usage string and the entitlement are present and proven
- **Given / When / Then:** Info.plist has `NSMicrophoneUsageDescription` (exact proposed text, D8). The red, run on the arm64 host under a hardened-runtime ad-hoc signature (`--options runtime`), shows capture blocked or terminated without `com.apple.security.device.audio-input`. The green adds the key. `mac_universal_test.py`'s MS1.3 entitlement comparison is updated to the new exact set.
- **Files touched:** `packaging/macos/Info.plist`, `packaging/macos/entitlements.plist` (comment updated with the proof), `tests/e2e/mac_universal_test.py` (expected keys), `packaging/macos/build-dmg.sh` (if the plist stamping needs it).

#### Behavior VS8.3: the authorization flow maps every status
- **Given / When / Then:** `voice_mac.m` maps `notDetermined` → request → granted/denied, and `denied`/`restricted` → `error permission-denied` with the settings deep-link. A test seam `ZB_E2E_MIC_AUTH=denied|granted|restricted` (inert without `--e2e-protocol`) exercises the mapping on both hosts headless.
- The real prompt is checked only in `mac-voice-permission`.
- **Files touched:** `src/voice_mac.m` (new; compiled in `configureMacosBackend`, `build.zig:1560-1570`; links `AVFoundation`), `src/voice/dictation.zig` (platform permission hook).

#### Behavior VS8.4: live capture through Core Audio
- miniaudio Core Audio backend, 16 kHz mono f32, route-change rebuild.
- There is no automated live test (TCC needs the GUI session). It is checked in `mac-voice-permission` and VS9's live case.

**Real-hardware check (VS8):** `mac-voice-permission` on each Mac with the user at the screen. It uses `tccutil reset Microphone com.cosmichq.zigBrowser` between the Allow and Deny runs. Intel is pending MS1b.

**Gate (VS8):** `mac-gate` + `mac_voice_selftest` on both hosts + the permission-mapping tests.

---

### VS9 — AppKit drawer dictation [M][U]

**Depends on:** **MS7** (the AppKit drawer; macOS plan `:1183-1258`), VS8. Signed-run claims depend on MS1b.

#### Behaviors
- **VS9.1-VS9.6** repeat VS5.2-VS5.7 on `src/agent_drawer_mac.m`: an `NSButton` Mic in the composer, the indicator, the insert at the `NSTextView` selection (`insertText:replacementRange:`, the **range-aware** insert of §4a #4 — cursor insert + selection replace), never auto-send, Escape precedence, one session per process, agent cannot start. **VS9.7** folds in VS5.8's first-use notice + denial UI on AppKit (VS8 is the headless permission layer and does **not** own drawer UI; the Mac denial UI lives here).
- They are observed through MS7.7's gated `--e2e-protocol` native drawer census, never a production socket read.
- **Closure:** as VS5, with the TRIGGER being a real `NSEvent` click (MS7's real-screen rules) or the census-driven seam MS7 defines for automated runs. The OBSERVE is MS7's `msg user` census row after the user's Return.
- 🔴 **Reds (each a mutant, against MS7's census seam):** dictated text that lands outside the selection range (not range-aware) ⇒ red; a result that calls send/Enter ⇒ a `msg user` row before Return ⇒ red; the first-use notice skipped ⇒ capture before Accept ⇒ red. Unregistered until green, then wired into the mac drawer-voice e2e.
- **Files touched:** `src/agent_drawer_mac.m` (new), `tests/e2e/mac_voice_drawer_test.py` (new).

**Real-hardware check (VS9):** `mac-drawer-voice-live` on both Macs (Intel pending MS1b).

**Gate (VS9):** `mac-gate` + the macOS drawer voice e2e on both arches.

---

### VS10 — Windows engine, capture and permission mapping (no drawer UI) [W]

**Depends on:** VS0-VS4, and WLP's **WS0** (hosts and the two-host gate) and **WS1** (the build on the VM).
- Builds run on the Win11 VM `win11-m8` with `-Dtarget=x86_64-windows-msvc` (WS1).
- Tests run through `tests/windows/gate.sh --phase voice` (WS12.2) on both hosts:
  - the **automated gate is recorded-file only** (WAV seam → VF `WavFileSource`; render/verify via FileSink), on both hosts — **no automated gate opens a live microphone** (VF test-device rule).
  - **Live-microphone** is a **user-approved manual check** (`win-voice-live`, §8.1) on the **physical Windows 10 machine only**; it is not part of `--phase voice`. The Win11 VM `win11-m8` is added to the manual check only after a VM capture device is proven (D8).
- **Windows 10 support is required** (0.2.5). Every recorded-file behavior runs on both Windows 10 and Windows 11.
- On the physical machine, which is also a file server, every run follows WLP's file-server isolation rules (`:415-470`): user `zbtest`, under `C:\Users\zbtest\zb\` only, and recorded load windows for CPU-heavy runs such as `voice-bench`.

#### Behavior VS10.1: the engine builds and transcribes on Windows 10 and 11
- **Given / When / Then:** the WS1 build on the VM produces `zigBrowser.exe`. On both the Win11 VM `win11-m8` and the physical Windows 10 machine, `zigBrowser.exe --voice-selftest wav:jfk.wav --e2e-protocol` prints the known sentence with tiny.en.
- A CPU without the baseline ISA prints the D3 message and exits cleanly. The test records `cpuid` on both hosts (the VM's virtual CPU flags are unverified).
- **Files touched:** `build/whisper.zig` (msvc flags), `src/voice/whisper_engine.zig` (loads via `whisper_init_from_buffer_with_params` over the verified bytes — VF §4 — so no Windows wide-char path-open is needed for the load), `tests/e2e/win_voice_selftest_test.py` (new).

#### Behavior VS10.2: WASAPI capture and access failures on Windows 10 and 11
- **Given / When / Then:**
  - on the physical Windows 10 machine with a microphone, live capture delivers 16 kHz mono f32 (RMS above the D8 floor while the user speaks, in `win-voice-permission`);
  - on the physical Windows 10 machine, with the desktop-apps microphone switch turned off **for `zbtest` only, never machine-wide** (WLP WS12 table; by the orchestrator through Settings; the registry key path is unverified), starting capture yields `error permission-denied` or `error no-signal`, whichever that build shows. The exact HRESULT is recorded. The same case runs on the VM once its capture device is proven, because 10 and 11 may differ (research 5.2);
  - on the VM while no capture device is proven, `--voice-capture-probe --list` reports `no-device` and the dictation core maps it to `error no-device`. This is a recorded-file-tier assertion about the mapping, not a live-capture test.
  - The probe itself (`--voice-capture-probe`, `--e2e-protocol`-gated like D6) is added here. It is also the tool for D8's VM proof.
- If `AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM` misbehaves on the Windows 10 build, the capture path falls back to miniaudio's resampler (D8). A test asserts the same output format either way.
- **Files touched:** `src/voice_win.cpp` (new; compiled in `configureWebView2Backend`, `build.zig:1535-1558`; links `ole32`, already linked), `src/voice/audio_miniaudio.c` (conversion fallback).

#### Behavior VS10.3: medium measurements on Windows x64 (manual, recorded)
- `voice-bench` on the physical Windows 10 machine (the representative number, run in a recorded load window per WLP's file-server rules) and on the Win11 VM `win11-m8` (with the caveat that a VM understates a real PC). Both use recorded files, so neither needs a microphone. This feeds O1 and O4.

**Real-hardware check (VS10):** `win-voice-permission` on the physical Windows 10 machine, user at the screen.

**Gate (VS10):** WS1 build + `tests/windows/gate.sh --phase voice`: `win_voice_selftest` (recorded file) on both hosts, plus live capture on the physical Windows 10 machine.

---

### VS11 — Windows drawer dictation [W][U]

**Depends on:** WLP's **WS5** (native Win32 drawer, the drawer-port milestone), its **WS12.1** hook `zb_drawer_set_draft` (must be the range-aware `zb_drawer_insert_text` of §4a #4 — cursor insert + selection replace, not a whole-draft set) (dictated text goes into the draft through it), and VS10. The post-Enter send leg also needs **WS11** (helper and chat).
- VS11 repeats VS5's behaviors (VS5.2-VS5.8) on the WS5 drawer, observed through that drawer's `--e2e-protocol` census (`DRAWER draft` rows per WS12.1), using the **range-aware** `zb_drawer_insert_text` (§4a #4).
- **Automated, recorded-file (WAV seam) only:** on both hosts through `gate.sh --phase voice`. **No automated gate opens a live microphone** (VF test-device rule); live capture is the manual `win-voice-live` check.
- **Live microphone (manual):** on the **physical Windows 10 machine only**, in `win-voice-live`. The Win11 VM `win11-m8` is added only after D8's VM capture proof passes.
- 🔴 **Reds (mutants, unregistered until green):** a whole-draft `set_draft` that discards the cursor/selection (not range-aware) ⇒ red; dictation that reaches the send path ⇒ a user message before Enter ⇒ red; the first-use notice skipped on Windows ⇒ capture before Accept ⇒ red.
- **Files touched:** `src/agent_drawer_win.cpp` (mic control + range-aware insert via WS12.1), `tests/e2e/win_voice_drawer_test.py` (new).

---

### VSP — The bundled model in every installer [P] (rev 2, new)

**Goal.** The decided medium file is inside the .deb, the macOS .app/DMG and the MSI. It is checked at build time and intact in every installer, and on macOS it is byte-identical in both arch slices.

#### Behavior VSP.1: the build refuses a missing or wrong model [L]
- **Given / When / Then:**
  - given `$ZB_VOICE_MODEL_CACHE` without the file, `zig build voice-model-check` exits nonzero with `voice model missing: <file>`;
  - with a one-byte-flipped copy, it exits nonzero with `voice model checksum mismatch`;
  - with the real file, it passes and the install tree contains `share/zigbrowser/models/stt/<file>` with the pinned SHA-256.
- LEAF (build step). The e2e uses a small fake model with an injected catalog for the per-commit gate. The real medium file is used only in the packaging gate.
- **Files touched:** `build/voice_model.zig` (new), `build.zig` (`voice-model-check` step, install step, `-Dvoice_model=<id>` option), `tools/fetch_voice_model.sh` (new; orchestrator-run), `tests/e2e/voice_model_check_test.py` (new).
- 🔴 The test, unregistered, fails: no such step.
- 🟢 Implement.
- 🔵 One hash-and-compare function shared with VS1's first-load check (Zig, used by both the build helper and the browser).

#### Behavior VSP.2: the .deb carries the model [L][P]
- **Given / When / Then:** `packaging/linux/build-deb.sh` includes `/usr/share/zigbrowser/models/stt/<file>`. `packaging/linux/gate.sh` (container install) checks its SHA-256 after install, and runs `zigBrowser --voice-selftest wav:jfk.wav --e2e-protocol` under `xvfb-run`, which reports `VOICE model <id> ready`.
- 🔴 **Red (mutant):** the `.deb` built without the model ⇒ `deb_install_test.py` fails the post-install SHA-256 check and the selftest reports `damaged`; registered in the packaging gate on green.
- **Files touched:** `packaging/linux/build-deb.sh`, `packaging/linux/control.in` (installed size), `packaging/linux/gate.sh`, `tests/e2e/deb_install_test.py`.

#### Behavior VSP.3: the macOS bundle carries one byte-identical model in both arch trees [M][P]
- **Given / When / Then:**
  - the per-arch trees built on the Intel and Apple Silicon hosts each contain `Contents/Resources/models/stt/<file>` with the pinned SHA-256;
  - the two copies are byte-identical (`resource_compat`, the nonempty branch of the macOS plan's census, MS5.1c);
  - the universal `.app` contains exactly one copy;
  - `universal_components.json` lists it as a resource (proposed role `stt-model`);
  - an ad-hoc `codesign --verify --strict` on the bundle passes (sealed resource);
  - the signed `.app` still runs the voice selftest on arm64, and on x86_64 once MS1b is green.
- Also measured and recorded: the DMG size and the `hdiutil` time.
- **Mutants (each run and observed red):** a different file in one arch tree → `resource_compat` red; the model missing from the inventory → census red; the model edited after signing → `codesign --verify` red.
- **Depends on:** VS7, and the macOS plan's **MS5.1c** two-tree `resource_compat` oracle (or it lands together with it). The resource role must be agreed with the macOS plan's owner (JadeBeacon). Notarization of the large DMG is part of **MS9**; its upload limit and time are unverified.
- **Files touched:** `packaging/macos/build-dmg.sh` (copy the model into `Contents/Resources`), `packaging/macos/universal_components.json` (resource entry), `tests/mac/gate.sh`, `tests/e2e/mac_universal_test.py` / `mac_resource_compat.py` (expect the resource; coordinated with the macOS plan, not edited by this plan unilaterally).

#### Behavior VSP.4: the MSI carries the model [W][P]
- **Given / When / Then:** `packaging/windows/zigBrowser.wxs` installs to `INSTALLFOLDER\models\stt\<file>` (WiX id `INSTALLFOLDER`). `packaging/windows/gate.ps1` checks its SHA-256 after a per-user install, runs the recorded-file voice selftest on the Win11 VM `win11-m8` and on the physical Windows 10 machine, and checks that uninstall removes it. WS13.1's census lists the file, and WS13.3's size budget counts it.
- Also measured and recorded: MSI size and install time. MSI/cabinet size limits at this size are unverified, and this behavior settles them.
- 🔴 **Red (mutant):** the MSI built without the model (or with a tampered copy) ⇒ `gate.ps1` fails the post-install SHA-256 check and the selftest reports `damaged`; uninstall that leaves the model behind ⇒ the uninstall census fails. Registered on green.
- **Depends on:** VS10 and WLP's **WS13** (WS13.1 census, WS13.3 size budget; the installer format is WLP's OD-W1).
- **Files touched:** `packaging/windows/zigBrowser.wxs`, `packaging/windows/build-msi.ps1`, `packaging/windows/gate.ps1`.

#### Behavior VSP.5: installer lifecycle — upgrade, repair, downgrade, tamper, orphan (clears §4a #5, review #5) [P]
- **Given / When / Then,** per platform installer:
  - **upgrade** from an older build whose model id changed installs the new model, **removes the orphaned old model** (no two medium files left), and the selftest reports the new `<id> ready`;
  - **repair/reinstall** over a **tampered** installed model (one byte flipped) restores the pinned bytes; before repair, the running app reports `VOICE model <id> damaged` and the Mic is insensitive (it never loads the tampered file — VF verify-through-consumption);
  - **downgrade** to a prior build installs that build's pinned model and selftest passes (no stale newer file);
  - **orphan cleanup** leaves no model under the install root that is not in the current catalog.
- 🔴 **Mutants:** skip the orphan removal on upgrade ⇒ two models present ⇒ red; load-by-path instead of verify-through-consumption ⇒ the tampered file loads ⇒ red.
- **Files touched:** `packaging/linux/build-deb.sh`/`postinst`, `packaging/macos/build-dmg.sh`, `packaging/windows/zigBrowser.wxs` (`RemoveFile`/component rules), `tests/e2e/model_lifecycle_test.py` (new; per-platform install→upgrade→repair→downgrade).

#### Behavior VSP.6: the model reaches remote builders by an orchestrator-only transfer (clears §4a #9, review #9) [P]
- **Given / When / Then:** the Mac and Windows builders obtain the model from a **named remote cache location** by an **orchestrator-only** transfer with a **pre-transfer and post-transfer SHA-256** check against the catalog, **owner-only** permissions on the cached file, a **cleanup** step after the build, and a **package-input manifest** recording the exact file + hash that entered each build. No builder fetches from the network during a gated build; a missing/mismatched cache **fails the gate** (never a silent skip).
- 🔴 **Mutants:** a post-transfer hash mismatch must fail; a build that proceeds without the manifest entry must fail.
- **Files touched:** `tools/fetch_voice_model.sh` (remote cache + SHA gate), `tests/mac/gate.sh` / `tests/windows/gate.ps1` (consume the cache + manifest), `packaging/*/model-input-manifest.json` (new).

**Workflow closure (VSP):** ClosureMap V-B (section 9.2). BLOCKING. The OBSERVE is the installed app's own `VOICE model <id> ready` row from `--voice-selftest`, never a direct file read by the test.

**Gate (VSP):** the Linux packaging gate; `mac-gate` with the census and `resource_compat`; the Windows MSI gate. Each needs the model cache, and exits 1 without it. Not a UI slice.

---

### VW — Web pages (deferred; decision O6)

Not scheduled. If the user puts it in scope, the first slice is **page microphone permission** on all three backends:
- GTK `permission-request` with `WebKitUserMediaPermissionRequest` + `enable-media-stream`;
- WKWebView `requestMediaCapturePermissionForOrigin…`;
- WebView2 `add_PermissionRequested` with `COREWEBVIEW2_PERMISSION_KIND_MICROPHONE` and `SavesInProfile = FALSE` until the user chooses "remember".

These go through a native prompt with per-origin memory. Tests use WebKitGTK's `enable-mock-capture-devices` headless. The polyfill and page-field dictation follow as separate slices with their own threat model.

## 11. Platform matrix and dependency order

| Slice | Linux | macOS (2 Macs) | Windows (WLP WS0: Win11 VM `win11-m8` builds; recorded-file tests on both hosts; live mic on the physical Windows 10 machine only) | Depends on |
|---|---|---|---|---|
| **VF Shared Voice Foundation** (§4) | **build + test** | cross-check compile only | cross-check compile only | — (lands first; every shared-consuming slice below depends on it) |
| VS0 engine build | **build + test** | cross-check compile only | cross-check compile only | — |
| VS1 bundled-model locator + check | **build + test** (all 3 OS layouts) | — | — | **VF** |
| VS2 download (**optional, not v1**) | build + test, if ever scheduled | — | — | **VF** + VS1 + a user decision (O4/O5) |
| VS3 audio layer | **build + test** (WAV, Null) | — | — | **VF** (VS3 is VF's capture `AudioSource` + its reds) |
| VS4 dictation core | **build + test** | — | — | VS0, VS3 |
| VS5 GTK drawer | **build + test + real-screen** | — | — | VS1, VS4, drawer S2/S5 (done) |
| VS6 settings window | **build + test + real-screen** | — | — | VS1, VS5 |
| VSP bundled model in installers | **.deb + build check** | **.app census + resource_compat + codesign** | **MSI** | VSP.1 first; Mac part VS7 + MS5.1c; Windows part VS10 + WLP WS13 |
| VS7 Mac engine | cross-check only | **build + test** | — | VS0, macOS MS1 |
| VS8 Mac permission | — | **build + test + real-screen** (Intel pending MS1b) | — | VS3, VS7, MS1, MS1b (Intel) |
| VS9 AppKit drawer | — | **build + test + real-screen** | — | VS8, macOS MS7 (needs MS4 + MS5) |
| VS10 Windows engine + capture | cross-check only | — | **build + recorded-file tests** on both hosts; **live capture + real-screen** on the physical Windows 10 machine | VS0-VS4, WLP WS0 + WS1 (+ WS12.2 voice phase) |
| VS11 Windows drawer | — | — | **recorded-file e2e** on both hosts; **`win-voice-live`** on the physical Windows 10 machine | VS10, WLP WS5 + WS12.1 (+ WS11 for the send leg) |

Order: **VF first**, then `VS0 → VS1`, `VS3` in parallel, then `VS4 → VS5 → VS6` (each depends on
VF). `VSP.1` and `VSP.2` follow VS1.
- `VS7` may start after VS0 and MS1. `VSP.3` follows VS7 and MS5.1c.
- `VS8` after VS7, VS3 and MS1 (Intel parts after MS1b).
- `VS9` after VS8 and MS7.
- `VS10` after VS4 and WLP's WS0 and WS1. `VSP.4` follows VS10 and WLP's WS13.
- `VS11` after VS10 and WLP's WS5 and WS12.1. Its send leg needs WS11.
- `VS2` only if the user schedules it.

The shared pieces are **VF** (§4), one slice landed once before any consumer in either plan — not
"whichever plan lands first owns it" (that arrangement is withdrawn). The STT track carries VF; the
TTS track consumes it.

## 12. Per-slice gate protocol

1. Mail "taking the gate slot" only for the gate run. Trust only "slot FREE" mails.
2. Red tests in unregistered files or steps; record the red runs (on a remote Mac for VS7-VS9 and VSP.3; on the Windows hosts for VS10, VS11 and VSP.4).
3. Green: implement and register.
4. Refactor (the checklist below).
5. Quiet gate from a clean `git archive HEAD` plus the slice's files, under a private Xvfb.
6. Commit only the slice's files; stage only your own hunks.
7. Mail RoseCat.
8. For UI slices, add the real-hardware case; the orchestrator runs it with the user; not approved until it passes.
9. A closure e2e must be observed to execute with nonzero assertions, and each listed mutant must be observed red.

**Refactor checklist (every slice):**
- **No duplication:** one conversion path (D2); one `install` (D5); one per-target flag table for whisper/ggml; reuse `atomic_file.zig`, the env-enum resolution and the canary scanner (`agent_common.py`).
- **Reveals intent:** C, ObjC and C++ handlers only translate events to `zb_voice_*` calls; decisions stay in `dictation.zig`.
- **Complexity goes down:** the catalog is data; the error-to-message mapping is one table, not a switch per platform.
- **No shallow wrappers:** `SttEngine` and `AudioSource` exist because there are two real implementations of each (real and fake/file). No other interfaces.
- **Fits existing patterns:** flags like `--media-source` (`src/media_config.zig:35`), rows like `drawer_row` (`src/agent_drawer.c:174-180`), and gates like the drawer plan's §10.

## 13. References

- **`tools/check_vf_identical.sh` (proposed, rev 2.1):** diffs the `VF:BEGIN`..`VF:END` region of this plan against the TTS plan's and exits nonzero if they differ, so the shared foundation cannot drift. A docs-only CI check, not product code.
- **Sibling + macOS plans:** TTS `2026-10-19-voice-output-tts-tdd-plan.md` (VF §2.4, macOS §D11); macOS `2026-10-14-14-30-macos-launch-tdd-plan.md` (MS1.1/MS1.3/MS5.1c/MS6/MS9).
- Research: `thoughts/searchable/shared/research/2026-10-19-voice-input-stt.md` (this plan's source; its ClosureMap and the closure adapter scaffold are embedded there).
- Prior research: `/home/maceo/ntm_Dev/zigBrowser/thoughts/searchable/shared/research/2026-10-19-voice-recognition-options.md`.
- Drawer plan: conventions (`:1400-1402`, `:1495-1562`, `:2605-2653`), real-hardware rule (§7.1 `:1218-1293`), out of scope (`:1095-1097`).
- macOS plan: MS1 (`:481-562`), MS1b (`:565-591`, dependency `:1342-1351`), MS7 (`:1183-1258`), testing strategy (`:375-406`).
- Windows: **the Windows launch plan (WLP)**, `thoughts/searchable/shared/plans/2026-10-19-windows-launch-tdd-plan.md` (rev 2):
  - hosts: provisioning `:359-502`, with the physical Windows 10 machine at `:364` and the Win11 VM `win11-m8` at `:471`;
  - WS0 `:614`, WS1 `:724`, WS5 `:1148`, WS11 `:1540`, WS12 `:1587` (its voice-plan table `:1594-1615`), WS13 `:1644`.
- Older Windows material: `thoughts/searchable/shared/plans/2026-06-01-18-16-ENG-0006-tdd-windows-webview2-backend-m8.md`; `tests/guest/build-in-guest.sh`; `packaging/windows/gate.ps1`.
- macOS resource census and `resource_compat`: macOS plan MS1.1 (`:486-506`) and MS5.1c (`:1040-1067`).
- whisper.cpp: [repo](https://github.com/ggml-org/whisper.cpp), [models on Hugging Face](https://huggingface.co/ggerganov/whisper.cpp/tree/main), [whisper.h](https://raw.githubusercontent.com/ggml-org/whisper.cpp/master/include/whisper.h), [bench issue #89](https://github.com/ggml-org/whisper.cpp/issues/89), [audio_ctx issue #137](https://github.com/ggml-org/whisper.cpp/issues/137).
- miniaudio: [repo](https://github.com/mackron/miniaudio), [manual](https://miniaud.io/docs/manual/index.html).
- Apple: [NSMicrophoneUsageDescription](https://developer.apple.com/documentation/bundleresources/information-property-list/nsmicrophoneusagedescription), [audio-input entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.audio-input), [requesting authorization](https://developer.apple.com/documentation/avfoundation/requesting-authorization-to-capture-and-save-media).
- Microsoft: [WASAPI stream flags](https://learn.microsoft.com/en-us/windows/win32/coreaudio/audclnt-streamflags-xxx-constants), [desktop apps and privacy](https://support.microsoft.com/topic/8b3b13bc-d8ff-5460-8423-7d5d5c1f6665), [WebView2 PermissionRequested args](https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/win32/icorewebview2permissionrequestedeventargs).

## 14. Tracking and unverified items

**Tracking.**
- No bead was filed: `bd list` on this clone reports a pending schema migration for the designated migrator only, and per project memory no migration was attempted.
- `silmari-oracle sync` was not run, because this task allowed writing only two files.
- Status is tracked through Agent Mail and this plan.

**Unverified, each to be settled by the named slice:**
- `build.zig` reproduction of ggml's Metal embed (VS7.2).
- Metal usefulness on the Intel Mac (VS7).
- Medium latency on the Intel Mac and Windows CPU, and q8_0/q5_0 vs f16 on AVX2 (VS4.5, VS7.3, VS10.3).
- What WASAPI returns when access is off, per Windows version (VS10.2).
- WASAPI auto-conversion behavior on the supported Windows 10 builds (VS10.2).
- Whether the Win11 VM `win11-m8` has a usable capture device through its `ich9`/SPICE audio. It is proven only by D8's four steps; until then the VM runs recorded-file tests only.
- WLP's open decisions that affect this plan: OD-W7 (minimum Windows builds) and OD-W1 (installer format, for VSP.4).
- Provisioning of the physical Windows 10 machine (OpenSSH, `zbtest`, a microphone; WLP provisioning items 1-10).
- **Open coordination item:** the macOS resource role name for the bundled model (proposed `stt-model`), routed to JadeBeacon by the coordinator (VSP.3).
- Notarization upload limit and time for a ~1 GB DMG (VSP.3, MS9).
- Hashing time for the bundled model at first load (VS1.2).
- The TCC prompt for an ad-hoc-signed `.app` on each Mac (VS8; Intel after MS1b).
- The Hugging Face CDN redirect host (VS2.3, only if VS2 is built; the release fetch tool follows redirects and checks SHA-256, so it does not depend on it).
- GTK3 `GtkTextView` undo (D4.2).
- MSI/cabinet size limits with the bundled model (VSP.4).
- miniaudio's default resampler quality (VS3.1).
- The license status of `jfk.wav` as a test fixture.
