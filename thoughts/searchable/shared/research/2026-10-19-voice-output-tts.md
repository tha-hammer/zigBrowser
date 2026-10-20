---
date: 2026-10-19T15:25:29-04:00
researcher: Claude (Opus 5.5), research subagent for the voice plans
git_commit: a69b459cb5346e8d25488f41e76c034d6fd8f3fa
branch: zb-automation-integration-2026-10-10-11-59
repository: zigBrowser
topic: "The browser's voice: speaking agent replies aloud (text-to-speech) with user-customizable voices, on macOS and Windows first, Linux for development"
tags: [research, codebase, tts, text-to-speech, voice, agent-drawer, agent-protocol, avspeechsynthesizer, winrt, sapi, speech-dispatcher, piper, kokoro, sherpa-onnx, pocket-tts, voice-cloning, miniaudio]
status: complete
last_updated: 2026-10-19
last_updated_by: Claude (Opus 5.5)
last_updated_note: "Rev 2: recorded the user's decisions of 2026-10-19 (cloning for personal use; bundled engine first; read-aloud on by default; the STT side bundles whisper medium), the Pocket TTS license and model-file check, and the separate Windows launch plan as a dependency."
sibling_research: /home/maceo/ntm_Dev/zigBrowser/thoughts/searchable/shared/research/2026-10-19-voice-recognition-options.md (speech-to-text, written in parallel)
---

# Research: the browser's voice (text-to-speech for agent replies)

**Date**: 2026-10-19T15:25:29-04:00
**Researcher**: Claude (Opus 5.5), research subagent
**Git Commit**: `a69b459` (HEAD of the shared worktree when this was written)
**Branch**: zb-automation-integration-2026-10-10-11-59
**Repository**: zigBrowser

> **Line numbers.** The worktree is shared by four agents. When this was written it held
> uncommitted changes by other agents in `src/agent_drawer.c`, `src/agent_drawer.zig`,
> `src/agent_helper.c`, `build.zig` and `agent/host/zb_agent_host/chat.py` (seen with
> `git diff --stat`). The `file:line` references below were read from the working tree at
> that moment. In those five files they may be a few lines off from HEAD `a69b459`. Function
> names are the stable anchor; re-check the line numbers against HEAD before relying on them.

## Research Question

The user's words: "We need to break this into 2 plans: 1 plan for the voice of the browser,
this will allow the LLM to generate text that is spoken and allow the user to customize
voices. The second plan is for the user to use voice to text. Mac and Windows are the 2 main
target systems, Linux is my environment, not the primary target for users. I'm comfortable
with shipping whisper.cpp and handling the model as part of the browser."

This document covers the first plan only: the agent's replies in the chat drawer are spoken
aloud, and the user can choose a voice, rate, pitch and volume. It maps where replies arrive
in the code today, what each platform offers, which local engines could be shipped, and how
speaking a streamed reply works. The speech-to-text side is in the sibling document named in
the front matter.

**User decisions received during research (2026-10-19, through the coordinator):**
1. "Allow voice cloning for personal use." Recorded in the section on cloning below.
2. "Bundled engine first." The bundled local engine ships first, as the primary path, so
   every platform sounds the same and cloning works everywhere. System voices
   (AVSpeechSynthesizer, WinRT) become a later, secondary option.
3. "On by default." Automatic read-aloud of agent replies is on by default.
4. From the STT side: the whisper **medium** model is **bundled in the installer**, so the
   installer is already about 0.8 GB larger.
5. Windows is a main target. The **Windows launch plan** now exists (`thoughts/searchable/shared/plans/2026-10-19-windows-launch-tdd-plan.md`,
   milestones WS0-WS13). It covers the Win32 drawer (WS5), the sandbox (WS8, with the
   no-network child WS8.7), the helper and chat (WS11), voice hooks (WS12) and the installer
   (WS13). Its test hosts (WS0) are the Win11 VM `win11-m8` and the physical Windows 10 machine (`100.123.34.15`, `file-server-win-mac`, run-only). See section 2.

Section "Decisions recorded 2026-10-19 and what they change" below records what these mean
for the facts in this document.

## Summary

- **Where replies arrive.** The Python helper turns the Claude Agent SDK stream into NDJSON
  frames: `assistant_delta` (coalesced every 50 ms, at most 16 KiB) and then one
  `assistant_message` with the full text, then `result` or `error`. The browser reads them on
  the GLib main loop in `src/agent_helper.c` (`on_frame`) and calls
  `zb_drawer_agent_delta`, `zb_drawer_agent_message` and `zb_drawer_agent_stopped` in
  `src/agent_drawer.c`. There is no frame for "message start". This is the one place where a
  speech feature can listen to a reply as it streams.
- **The drawer is native GTK 3 widgets with no web content** (a `GtkListBox` of label
  bubbles; plain text only, no markdown rendering). So the web `speechSynthesis` API is not
  reachable from the drawer without adding a web view, which the drawer plan rules out (D1).
- **There is no audio code anywhere** in `src/`, `agent/` or `build.zig`. The only media code
  is the `--media-source on|off` switch.
- **The agent sandbox has no audio and only one host.** The helper runs in bwrap with no
  `/dev/snd`, no Pulse or D-Bus variables, and egress only to `api.anthropic.com`. Speech
  must therefore run in the browser process, not in the helper.
- **The drawer, the helper and setup are Linux-only today.** `build.zig` compiles the drawer
  only for the GTK backend, and `app.zig` refuses agent setup off Linux. The macOS plan ports
  the drawer in **MS7** (AppKit drawer) and the helper in **MS8** (blocked on the MS6
  Seatbelt sandbox). The drawer plan and the macOS plan both leave Windows to a separate
  track. That track is the **Windows launch plan** (WS5 drawer, WS11 helper and chat, WS8
  sandbox, WS12 voice hooks, WS13 installer; hosts `win11-m8` and the physical Windows 10
  machine). So spoken replies on Mac depend on MS7 and MS8, and on Windows on WS5, WS11 and
  WS12.
- **macOS:** `AVSpeechSynthesizer` (Objective-C, macOS 10.14+) gives voices (including
  user-downloaded Enhanced and Premium voices), rate, pitch, volume, queueing, stop at an
  immediate or word boundary, SSML on macOS 13+, rendering to PCM buffers (`write:`), and
  **Personal Voice** (macOS 14+, the user creates it in System Settings, and the app asks for
  permission). `NSSpeechSynthesizer` is deprecated as of macOS 14. The app's minimum is macOS
  13.0, and AVFAudio is not linked today.
- **Windows:** WinRT `Windows.Media.SpeechSynthesis.SpeechSynthesizer` (OneCore voices, SSML,
  rate 0.5-6.0, pitch, volume) returns a WAV stream that the app must play. SAPI 5
  (`ISpVoice`) is the older COM API that plays audio itself. Narrator's "natural" voices are
  **not** officially available to other apps. Zig's bundled MinGW headers include `sapi.h`,
  `roapi.h` and `winstring.h` but **not** `windows.media.speechsynthesis.h` (checked on this
  machine).
- **Linux (development):** speech-dispatcher 0.12.0 with its espeak-ng module, `libspeechd.so.2`,
  `libespeak-ng.so.1`, `libflite.so.1`, PulseAudio and PipeWire are installed here.
  `libspeechd-dev` is not installed. WebKitGTK is 2.54.0.
- **Local engines that could be shipped:** the license picture decides most of it.
  - **espeak-ng is GPL-3.0**, and it is the phonemizer behind Piper and (by default) Kokoro.
    **sherpa-onnx always vendors an espeak-ng fork when its TTS is enabled** (verified in its
    `CMakeLists.txt`), so linking sherpa-onnx TTS brings GPL code with it.
  - **Piper**: the MIT repo was archived on 2025-10-06. The active fork is GPL-3.0, and the
    voices' licenses vary (the default terms say "personal use and research").
  - **Kokoro-82M**: Apache-2.0 weights, 54 voices in 8 languages in v1.0, about 300 MB (about
    80 MB quantized). Its G2P library misaki is Apache-2.0 and can run English without the
    espeak-ng fallback, but it is Python only.
  - **Supertonic 3**: MIT code and OpenRAIL-M model, no phonemizer, 31 languages, a C++ ONNX
    Runtime example. The repo was archived on 2026-09-09.
  - **Pocket TTS (Kyutai)**: MIT code and CC-BY-4.0 weights, about 100M parameters, six
    languages, about 6x real time on two cores of a MacBook Air M4, about 200 ms to first
    audio, and **voice cloning from a WAV**. Its use policy bans cloning without explicit and
    lawful consent.
  - **Not shippable** in a commercial product: Coqui XTTS-v2 (CPML, non-commercial), F5-TTS
    weights and ZipVoice weights (CC-BY-NC), Spark-TTS (CC BY-NC-SA), and KittenTTS 2 (its
    own restrictive license). NeuTTS Nano has a revenue cap.
- **Streaming.** Speaking while a reply streams needs a sentence chunker over the deltas,
  markdown clean-up (code blocks, links, emphasis), a queue that synthesizes the next sentence
  while the current one plays, and a stop that flushes everything. The drawer's Stop button is
  enabled only while the agent is busy, so a reply that has finished arriving but is still
  being spoken has no stop control today.
- **Shared with the speech-to-text plan:** an audio device layer (miniaudio, public domain or
  MIT-0, does playback and capture on CoreAudio, WASAPI and PulseAudio), a voice settings
  window, the macOS permission prompts and usage strings, a model manager (the STT side
  bundles whisper medium in the installer), and the rule that tests never use the real audio
  devices.
- **Rev 2 decisions** (section "Decisions recorded 2026-10-19"): bundled engine first, with
  Pocket TTS, **confirmed by the user as the voice engine** (MIT code, CC-BY-4.0 weights, a
  236 MB bf16 file, about 100 MB int8 (unverified), no official C or ONNX runtime); it is also
  the cloning engine, following from that choice; read-aloud on by default; the TTS model
  bundled in the installer. Still open: the download-gate terms and the runtime path.

## Detailed Findings

### 1. How an agent reply reaches the drawer today

**The helper (Python, inside the sandbox).**
- `agent/host/zb_agent_host/options.py:127` sets `include_partial_messages=True`, so the SDK
  emits text deltas.
- `agent/host/zb_agent_host/chat.py` `Session.prompt` consumes the stream. Text deltas are
  collected and flushed as `assistant_delta` frames when `DELTA_INTERVAL_S` (`chat.py:31`,
  0.05 s) has passed, in pieces of at most 16 KiB. Each `AssistantMessage` then becomes one
  `assistant_message` frame with its joined `TextBlock` text, truncated with
  `"\n[output truncated]"` past the cap. Thinking and tool-use blocks are not sent.
- A turn with tool use produces several `AssistantMessage`s, so one prompt can produce
  several delta runs, each followed by its own `assistant_message`.
- `interrupt` calls `client.interrupt()`; the prompt then ends through the SDK stream,
  normally with a `result`.
- `agent/host/zb_agent_host/frames.py` `Emitter.emit` writes `{"v":1,"seq":n,"type":...}`.

**The frame contract.** `src/agent_protocol.zig:26-35` is the `Frame` union: `ready`,
`session_opened`, `assistant_delta`, `assistant_message`, `tool_call`, `result`, `error`,
`session_ended`. `assistant_delta` text is capped at 16 KiB and `assistant_message` at
256 KiB (`agent_protocol.zig:152-153`). Error codes are `auth, busy, overloaded, protocol,
overflow, sdk, sandbox`, and end reasons are `end, interrupt, crash, token_removed`
(`agent_protocol.zig:44-45`). There is no message-start frame.

**The browser side (C on the GLib main loop).**
- `src/agent_helper.c` spawns the helper with `GSubprocessLauncher` (`spawn_with`), reads
  stdout asynchronously (`reader_start`, `on_read`), splits lines, validates each through
  `zb_agent_frames_validate` (`src/agent_frames.zig`), and dispatches in `on_frame`
  (`agent_helper.c:285`).
- In `on_frame`:
  - `ZB_FRAME_DELTA` calls `zb_drawer_agent_delta(win, w->session, text, len)` unless the
    window is `stopping` (`agent_helper.c:296-305`);
  - `ZB_FRAME_MESSAGE` calls `zb_drawer_agent_message(win, "assistant", ...)` unless stopping;
  - `ZB_FRAME_RESULT` ends a stopped reply with `zb_drawer_agent_stopped(win)` and sets the
    status to ready;
  - `ZB_FRAME_ERROR` shows one fixed sentence per code (`error_text`, `agent_helper.c:278`).
- `zb_agent_helper_interrupt` (`agent_helper.c:831`) sets `stopping = 1` and writes the
  `interrupt` frame. Later deltas and messages for that window are dropped until the ending
  frame.

**The drawer (C, GTK 3).**
- The header comment (`src/agent_drawer.c:1-8`) says text is only ever set with
  `gtk_label_set_text`: "model output stays inert". There is no markdown or HTML rendering.
- `zb_drawer_agent_delta` (`agent_drawer.c:842`) appends to `d->stream_text`
  (`stream_append`, `:776`, capped at 256 KiB), creates the assistant bubble on the first
  delta, and refreshes it at most every `ZB_STREAM_REFRESH_MS` (100 ms, `:49`).
- `zb_drawer_agent_message` (`:820`) ends the stream with the full text (`end_stream`,
  `:754`), or adds a new bubble.
- `zb_drawer_agent_stopped` (`:863`) ends the bubble with `"(stopped)"` (`ZB_STOPPED_TEXT`,
  `:46`).
- `on_stop_clicked` (`:883`) calls `zb_agent_helper_interrupt` and gives focus back to the
  input.
- `zb_drawer_agent_status` (`:804`) sets the status label and makes Stop sensitive **only
  while the state is `busy`** (`gtk_widget_set_sensitive(d->stop, strcmp(state, "busy") ==
  0)`).
- `set_bubble_text` (`:605`) keeps each bubble's original text as object data
  `"zb-original"`, which Copy uses. **No per-message buttons exist**; the only per-bubble
  behavior is selection and Copy.
- The header has a title, a status label, an "Account" button (opens the Secrets window), and
  a "-" minimize button. There is no settings or voice UI.

**E2e observation rows.** With `--e2e-protocol`, the drawer writes `DRAWER` rows through
`drawer_row` (`agent_drawer.c:174`). The row schema is the D7b table in the drawer plan
(`thoughts/searchable/shared/plans/2026-10-13-claude-agent-chat-drawer-tdd-plan.md:442-462`),
for example `DRAWER <win> delta <session> <text>` and `DRAWER <win> msg assistant <text>`. A
parser in `tests/e2e/agent_common.py` rejects any row that does not match the table.

### 2. Platform backends and the drawer's platform scope

- `resolveBackend` (`build.zig:1481`) maps Linux to `.gtk_backend`, Windows to
  `.webview2_backend` and macOS to `.macos_backend`.
- `configureGtkBackend` (`build.zig:1503`) compiles `webkit_shim.c`, `agent_drawer.c`,
  `agent_host.c`, `agent_helper.c`, `agent_secrets.c` and `agent_secrets_window.c`, and
  links `webkit2gtk-4.1`, `gtk+-3.0` and `gio-unix-2.0`.
- `configureWebView2Backend` (`build.zig:1535`) compiles `webview2_shim.cpp` as C++17. It
  adds include paths from `-Dwebview2_include` and `-Dwinrt_include` (the directory with
  `wrl.h`), and links `WebView2LoaderStatic`, `ole32`, `oleaut32`, `user32`, `gdi32`,
  `shell32` and `advapi32`. The cross-check target is `x86_64-windows-gnu`
  (`build.zig:250`), which is the MinGW ABI.
- `configureMacosBackend` (`build.zig:1560`) compiles `wkwebview_shim.m` with `-fobjc-arc`
  and links WebKit, Cocoa and Foundation. **AVFAudio and AVFoundation are not linked.**
- The drawer's Zig exports are compiled only on Linux (`src/agent_drawer.zig:336-339`).
  `runAgentSetup` prints "the Claude Agent is Linux-only" off Linux (`src/app.zig:52-54`).
  `zb_drawer_attach` is called from `src/webkit_shim.c:1285`.
- `src/wkwebview_shim.m` and `src/webview2_shim.cpp` contain no agent or drawer code.

**The Mac port of the drawer (dependency).**
`thoughts/searchable/shared/plans/2026-10-14-14-30-macos-launch-tdd-plan.md`:
- **MS7** (`:1183`): "AppKit drawer + Keychain Secrets window + approval card + chat
  observability", a UI slice with a real-screen check. Design: `src/agent_drawer_mac.m`,
  reusing `agent_drawer.zig`'s portable geometry and persistence, mounted from `zb_window_new`.
- **MS8** (`:1260`): "Agent helper on macOS (blocked on MS6 green or the VM backend)". It
  streams `assistant_delta` and `assistant_message` to the AppKit drawer.
- Dependency order (`:1338`): `MS0 → MS1 → MS2a → MS2b → MS2c → MS3 → MS4 → MS5 → MS6 → MS7
  → MS8 → MS9`. MS7 needs MS4 and MS5; MS8 needs MS5, MS6 and MS7.
- The plan does not mention voice, speech or audio.
- Its "What we're NOT doing" says: "Not building a Windows drawer / Windows automation parity
  (separate track)" (`:373`).

**Windows.**
- The drawer plan's non-goals: "macOS and Windows drawers. The C ABI is shared, but the drawer
  is Linux/GTK-first" (`2026-10-13-claude-agent-chat-drawer-tdd-plan.md:1095`), and "voice"
  is listed among non-goals at `:1097`.
- The Windows backend plan (`2026-06-01-18-16-ENG-0006-tdd-windows-webview2-backend-m8.md`)
  covers a WebView2 window with IPC (`ping`, `echo`, `os.info`) and no drawer. The installer
  plan (`2026-06-03-08-26-ENG-0007-...`) says a Windows exe and an MSI were built in a Win11
  KVM guest. Whether that guest still exists was not checked. When this research started
  there was no Windows test host. Rev 2.2: the **Windows launch plan** covers the Win32
  drawer (WS5), the helper and chat (WS11), the sandbox (WS8/WS8.7), voice hooks (WS12) and the
  installer (WS13), with two test hosts in WS0: the Win11 VM `win11-m8` and the physical Windows 10 machine (`100.123.34.15`, `file-server-win-mac`, run-only). Its path is `thoughts/searchable/shared/plans/2026-10-19-windows-launch-tdd-plan.md`. Its milestones are WS0-WS13 (verified in the file on 2026-10-19).
- The sandbox red-team research says a Windows agent backend should run the Linux sandbox in
  WSL2 rather than build an AppContainer backend
  (`thoughts/searchable/shared/research/2026-10-14-agent-sandbox-redteam.md:322`).

**Mac test hosts.** `tests/mac/gate.sh` builds natively on two hosts over SSH:
the Intel host `ZB_MAC_HOST` (default `maceojourdan@100.92.212.47`, key
`/home/maceo/vms/mac-m9/zb_mac_key`) and the Apple Silicon host `ZB_MAC_ARM_HOST`, which has
no default. When it is unset the gate prints "NOT RUN: arm64 host not configured" and exits
nonzero. `tests/mac/build-on-mac.sh` copies `src build.zig build.zig.zon tests` and runs
`zig build <step>` on the Mac.

### 3. Audio and media code

- No code for audio, TTS, speech, GStreamer, PulseAudio, PipeWire, ALSA, AVSpeech, SAPI,
  `speechSynthesis`, miniaudio or PortAudio exists in `src/`, `agent/` or `build.zig`.
- `src/media_config.zig` defines `MediaSource = enum { on, off }`, default on, env
  `ZIGBROWSER_MEDIA_SOURCE`, resolved by `env_switch.Switch` (flag, then env, then default).
  It exists because of an MSE deadlock with GStreamer on Instagram. The same `env_switch`
  pattern is used by `agent_config.zig` (`AgentDrawer`, `SecretStore`).
- The project memory records that the live browser must always be relaunched with
  `--media-source off`.

### 4. The agent sandbox and network policy

- `agent/host/zb_agent_host/sandbox.py:51`: `EGRESS_ALLOW = ("api.anthropic.com",)`.
  `:56`: `LOGIN_EGRESS_ALLOW` adds `platform.claude.com` for sign-in only.
- netd accepts only `CONNECT host:443` to an allowlisted name and rejects private addresses
  (`netd.py` `parse_head`, `vetted`).
- The helper's bwrap gets `--dev /dev` (the minimal device set, no `/dev/snd`), a tmpfs
  `/run`, no `XDG_RUNTIME_DIR`, and only `PATH, LANG, LC_ALL, HOME, CLAUDE_CONFIG_DIR, TMPDIR`
  and two Claude flags (`options.py:16-19`). Display, Pulse and D-Bus variables are dropped.
- Hooks reach only the bridges `127.0.0.1:51091` and `127.0.0.1:31337`. Port 51091 is the
  SAI voice-notification server from the user's global setup; it is unrelated to this
  feature, and nothing in `src/` names it.
- Consequence: the helper cannot play audio and must not be given audio. Any speech must run
  in the browser process (or in a new, separately sandboxed speech process that the browser
  starts). A cloud TTS call from the browser process would not pass through netd, but it would
  still be a new network destination and a privacy decision.

### 5. Settings and persistence

- There is no runtime user-settings file. Settings are CLI flags plus environment variables
  (`render_config.zig`, `media_config.zig`, `agent_config.zig`).
- The precedent for persisted UI state is `<profile>/agent-drawer.json`
  (`agent_drawer.zig:244`: `file_name`, 1024-byte max, `{version, x, y}`), written atomically
  with `atomic_file.replaceJson`.
- The Secrets window (`src/agent_secrets_window.c`) is a separate top-level GTK window opened
  from the drawer's Account button (`zb_secrets_window_present`, `:711`). It is the precedent
  for a separate native settings window.
- Paths: `xdg.zig` `dataSubdir` gives `$XDG_DATA_HOME/zigbrowser/...`; the profile is
  `zigbrowser/profile`; the agent home is `zigbrowser/agent-home`.
- libsecret is loaded with `dlopen` (`agent_secrets.c:1-4`). That is the precedent for loading
  an optional system library such as `libspeechd.so.2` at run time.

### 6. Packaging and permissions

- `packaging/macos/entitlements.plist` has only `com.apple.security.network.client`, and its
  comment says a key is added only after a signed Mac build proves it is needed.
- `packaging/macos/Info.plist` has `LSMinimumSystemVersion 13.0` and no usage-description keys.
- No Windows manifest or `.rc` file exists. `packaging/windows/` has `zigBrowser.wxs`,
  `build-msi.ps1`, `gate.ps1` and the WebView2 bootstrapper.
- The `.deb` depends only on `libwebkit2gtk-4.1-0` and `libgtk-3-0`
  (`packaging/linux/control.in:6`).

### 7. Test infrastructure the plan can reuse

- Zig unit tests in `tests/*_test.zig` registered in `build.zig` (for example
  `tests/agent_drawer_test.zig`), with seeded-PRNG property loops.
- Python e2e in `tests/e2e/` run under a private Xvfb by `xsession.py --xvfb`. The chat e2e is
  `tests/e2e/agent_chat_test.py` (gate step `agent-chat-e2e`), with the fake Messages API
  `tests/e2e/fake_anthropic_api.py` scripting SSE deltas.
- `tests/manual/real_screen_check.py` (needs `--confirm-user-permission`; the orchestrator
  runs it on the user's screen; each UI slice adds its own case).
- Project memory rules that apply directly: tests never use the real display; keyring tests
  need a dead bus and a private `XDG_RUNTIME_DIR`; run each Python test module alone as
  `build.zig` does; red commits go outside gate-registered steps.

### 8. The local Linux development machine

Checked with `dpkg -l` and `command -v`:
- installed: `speech-dispatcher 0.12.0-5`, `speech-dispatcher-espeak-ng`, `libspeechd2`,
  `python3-speechd`, `libespeak-ng1 1.52.0`, `espeak-ng-data`, `libflite1 2.2`,
  `pulseaudio`, `pipewire`, `pipewire-pulse 1.4.2`, `pw-cat`, `parec`, `pactl`, `spd-say`,
  `libasound2-dev`;
- not installed: `libspeechd-dev`, the `espeak-ng` command, the `flite` command;
- `pkg-config --modversion webkit2gtk-4.1` = 2.54.0.

## Platform text-to-speech (web research)

Items marked UNVERIFIED were not confirmed against a primary source.

### macOS

- **AVSpeechSynthesizer** (AVFAudio, macOS 10.14+), all usable from Objective-C
  ([AVSpeechSynthesizer](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer)).
  - Queueing: "If the synthesizer is speaking, the synthesizer adds utterances to a queue and
    speaks them in the order it receives them." Stopping removes the queued utterances.
  - The app must retain the synthesizer until speech ends. A synthesizer released early gives
    no audio and no callbacks ([forum 683471](https://developer.apple.com/forums/thread/683471)).
  - Controls: `speakUtterance:`, `pauseSpeakingAtBoundary:`, `continueSpeaking`,
    `stopSpeakingAtBoundary:` with `AVSpeechBoundaryImmediate` or `AVSpeechBoundaryWord`.
  - Delegate: `didStart`, `willSpeakRangeOfSpeechString`, `willSpeak:(marker)`, `didPause`,
    `didContinue`, `didFinish`, `didCancel`
    ([delegate](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizerdelegate)).
    Apple suggests one utterance per meaningful unit to get progress callbacks.
  - **AVSpeechUtterance**: `rate` (named min, max and default constants; the values 0.0, 1.0
    and 0.5 are UNVERIFIED), `pitchMultiplier` (0.5-2.0, UNVERIFIED on the page), `volume`
    (0-1), `preUtteranceDelay`, `postUtteranceDelay`, and
    `prefersAssistiveTechnologySettings`
    ([utterance](https://developer.apple.com/documentation/avfaudio/avspeechutterance)).
  - **Voices**: `AVSpeechSynthesisVoice speechVoices`, `voiceWithIdentifier:`,
    `voiceWithLanguage:`, with `identifier`, `name`, `language`, `quality`, `gender`,
    `voiceTraits` ([voice](https://developer.apple.com/documentation/avfaudio/avspeechsynthesisvoice)).
    Quality values default, enhanced and premium; premium on macOS 13+ (UNVERIFIED).
  - Enhanced and Premium voices are downloaded by the user in System Settings > Accessibility
    > Spoken Content. Developers report that an app cannot start the download and cannot list
    voices that are not downloaded ([forum 758460](https://developer.apple.com/forums/thread/758460),
    iOS-centric). The voice list can be stale after an OS upgrade
    ([forum 735893](https://developer.apple.com/forums/thread/735893)). Siri voices are reported
    as not available to third-party apps ([forum 682438](https://developer.apple.com/forums/thread/682438)).
  - **SSML**: `initWithSSMLRepresentation:` on macOS 13+; `rate` and `pitchMultiplier` do not
    apply to an SSML utterance ([doc](https://developer.apple.com/documentation/avfaudio/avspeechutterance/init(ssmlrepresentation:)-8zam9)).
    The list of supported tags is not published (UNVERIFIED).
  - **Rendering to PCM**: `writeUtterance:toBufferCallback:` (macOS 10.15+) delivers
    `AVAudioBuffer`s without playing them
    ([doc](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer/write(_:tobuffercallback:))).
    That lets a test check real synthesis without using speakers. A zero-length buffer as the
    end marker is UNVERIFIED.
  - **Audio routing**: speech plays on the default output device. `outputChannels` uses
    AVAudioSession types, which are not a routing API on macOS (UNVERIFIED). To route, render
    with `write` and play through the app's own audio output.
  - **No entitlement is known to be needed** to speak (UNVERIFIED; test under hardened runtime).
  - Reported bugs: an Enhanced voice silent in a sandboxed Mac Catalyst app
    ([forum 844422](https://developer.apple.com/forums/thread/844422)); no speech on macOS
    15.1.1 in one report ([forum 769442](https://developer.apple.com/forums/thread/769442)); a
    premium voice silent on a macOS 13 beta ([forum 717207](https://developer.apple.com/forums/thread/717207)).
- **Personal Voice** (macOS 14+):
  - The user creates the voice in System Settings > Accessibility > Personal Voice. Apple's
    Mac guide says creating it is "available only on Mac computers with Apple silicon", it
    works "only with Live Speech and with third-party apps you allow", it is for "your own
    personal, noncommercial use", and it supports English (US), Mandarin (mainland China) and
    Spanish (Mexico) ([Apple guide](https://support.apple.com/guide/mac-help/mchldfd72333)).
  - The app calls `requestPersonalVoiceAuthorizationWithCompletionHandler:` and reads
    `personalVoiceAuthorizationStatus`; the voice then appears in `speechVoices` with the
    `isPersonalVoice` trait. If "Allow Apps to Request to Use" is off, the request is denied
    ([forum 731532](https://developer.apple.com/forums/thread/731532),
    [Ben Dodson](https://bendodson.com/weblog/2024/04/03/using-your-personal-voice-in-an-ios-app/)).
  - Whether an Info.plist usage string or an entitlement is needed is UNVERIFIED. Whether an
    Intel Mac can use a Personal Voice made elsewhere is UNVERIFIED.
  - Apple's "personal, noncommercial use" wording describes the user's use of their own voice.
    Whether it constrains a commercial app that offers the feature is a question for counsel
    (UNVERIFIED).
- **NSSpeechSynthesizer** is deprecated (availability "macOS 10.3-14.0")
  ([doc](https://developer.apple.com/documentation/appkit/nsspeechsynthesizer)).

### Windows

- **WinRT `Windows.Media.SpeechSynthesis.SpeechSynthesizer`** (Windows 10 10240+), an agile,
  activatable class ([class](https://learn.microsoft.com/en-us/uwp/api/windows.media.speechsynthesis.speechsynthesizer)).
  - `SynthesizeTextToStreamAsync` and `SynthesizeSsmlToStreamAsync` (SSML 1.1) return a WAV
    `SpeechSynthesisStream`. The app must play it (MediaPlayer, or decode and send PCM to
    WASAPI or XAudio2).
  - `AllVoices` and `DefaultVoice`; "Only Microsoft-signed voices installed on the system can
    be used."
  - `SpeechSynthesizerOptions`: `SpeakingRate` 0.5-6.0 (default 1.0; some voices narrower),
    `AudioPitch`, `AudioVolume` (Windows 10 1709+), `AppendedSilence` and
    `PunctuationSilence` (1803+; the default adds about 750 ms of silence, which matters for
    sentence-by-sentence speech), and word and sentence boundary metadata
    ([options](https://learn.microsoft.com/en-us/uwp/api/windows.media.speechsynthesis.speechsynthesizeroptions)).
    The pitch range 0-2 is UNVERIFIED.
  - **No source says it needs package identity**; Microsoft's list of identity-gated features
    does not include it ([packaging](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/packaging/)).
    That an unpackaged Win32 app can use it is UNVERIFIED and must be tested.
  - From C or C++ without C++/WinRT, the class is reached as raw COM through
    `RoActivateInstance` and the ABI header `windows.media.speechsynthesis.h`. Upstream
    mingw-w64 v14 ships that header
    ([mingw-w64](https://mingw.googlesource.com/mingw-w64/+/refs/heads/v14.x/mingw-w64-headers/include/windows.media.speechsynthesis.h)),
    but **Zig 0.16.0's bundled MinGW headers do not** (checked: no such file under
    `/home/maceo/Dev/zig-0.16.0/lib/libc/include/any-windows-any`). The Windows SDK's `winrt`
    include directory (the one `-Dwinrt_include` points at for `wrl.h`) has the ABI header
    (UNVERIFIED).
- **SAPI 5 `ISpVoice`** (COM): `Speak` with `SPF_ASYNC`, `SPF_PURGEBEFORESPEAK` to stop,
  `SetRate` -10..10, `SetVolume` 0..100, SAPI XML and SSML, `SPEI_WORD_BOUNDARY` events; it
  plays audio itself (UNVERIFIED in detail; no primary page fetched). **Zig's bundled MinGW
  has `sapi.h`, `sapi51.h` (with `ISpVoice`), `sapi53.h`, `sapi54.h`, `roapi.h` and
  `winstring.h`** (checked). SAPI on native arm64 is UNVERIFIED.
- **OneCore and SAPI voices** live under different registry keys
  (`Speech_OneCore\Voices` vs `Speech\Voices`). Plain SAPI enumeration sees only the classic
  set; reaching OneCore voices from SAPI is unofficial
  ([Mozilla 1544143](https://bugzilla.mozilla.org/show_bug.cgi?id=1544143),
  [MS Q&A](https://learn.microsoft.com/en-us/answers/questions/2006006/would-copying-registry-entries-to-get-access-to-al)).
- **Narrator "natural" voices** are on-device after download, but Microsoft does not offer
  them to third-party apps. The community SAPI bridge NaturalVoiceSAPIAdapter says
  "Microsoft has not allowed third-party apps to use the Narrator or Edge voices" and that it
  uses keys extracted from system files and "can stop working at any time"
  ([README](https://github.com/gexgd0419/NaturalVoiceSAPIAdapter/blob/master/README.md)). Not
  shippable.
- **Azure Speech** is cloud and needs a key. Its embedded (offline) mode is limited access,
  Windows 11 only, and needs approval ([embedded speech](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/embedded-speech)).
- **Windows AI APIs** (Copilot+) list no TTS ([comparison](https://learn.microsoft.com/windows/ai/windows-ai-comparison)).
- **Personal or cloned voice on Windows:** no OS API for third-party apps was found
  (UNVERIFIED as an absence). Azure "personal voice" is a cloud, limited-access service that
  requires a recorded verbal consent statement from the speaker and an approved use case
  ([overview](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/personal-voice-overview)).

### Web Speech `speechSynthesis` in the three web views

- It cannot serve the drawer as built: the drawer has no web view and the drawer plan's D1
  keeps it that way. It would only help if a hidden web view were added, which conflicts with
  the drawer's isolation design.
- WKWebView: same engine as Safari, which shows fewer voices than the OS has
  ([forum 723503](https://developer.apple.com/forums/thread/723503)). A user-gesture rule
  exists on iOS ([forum 49875](https://developer.apple.com/forums/thread/49875)); macOS is
  UNVERIFIED.
- WebView2: Edge speech is built on WinRT SpeechSynthesis
  ([Edge blog](https://blogs.windows.com/msedgedev/?p=17243)). Whether WebView2 exposes Edge's
  online "Natural" voices is UNVERIFIED. An Edge 150 bug returned voices with undefined names
  ([thread](https://techcommunity.microsoft.com/discussions/edgeinsiderdiscussions/edge-version-150-javascript-speechsynthesis-getvoices-undefined-voices/4538591)).
- WebKitGTK: upstream moved from Flite to libspiel in late 2024
  ([WebKit 270742](https://bugs.webkit.org/show_bug.cgi?id=270742)); Debian's 2.48.5 package
  builds with `flite1-dev` and disables speech only on Ubuntu
  ([debian/control](https://salsa.debian.org/webkit-team/webkit/-/raw/debian/2.48.5-1_deb13u1/debian/control),
  [debian/rules](https://salsa.debian.org/webkit-team/webkit/-/raw/debian/2.48.5-1_deb13u1/debian/rules)).
  The installed 2.54.0 backport was not checked (UNVERIFIED).
- General limits: no PCM access, no routing, voices vary, and Chrome cuts long utterances
  ([DEV](https://dev.to/jankapunkt/cross-browser-speech-synthesis-the-hard-way-and-the-easy-way-353)).

### Linux (development only)

- **speech-dispatcher**: the client library `libspeechd` is LGPL-2.1+, the daemon is GPL
  ([speechd wiki](https://github.com/brailcom/speechd/wiki)). It plays audio itself and gives
  no PCM. It is installed here with the espeak-ng module, and `libspeechd.so.2` can be loaded
  with `dlopen` (the headers package is not installed). It autostarts a per-user daemon that
  talks to the user's sound server through `XDG_RUNTIME_DIR`, so tests must give it a private
  runtime directory or they would speak through the user's speakers.
- **libspiel** (LGPL-2.1+, a D-Bus speech API modeled on Web Speech): no Debian package found
  ([FreshPorts](https://www.freshports.org/accessibility/libspiel)).
- **espeak-ng** (GPL-3.0): robotic; the library is installed here, not the command.

## Local engines that could be shipped (web research)

| Engine | Code license | Weights license | Commercial bundling | Size | CPU | Phonemizer | Cloning | Status |
|---|---|---|---|---|---|---|---|---|
| Piper ([rhasspy/piper](https://github.com/rhasspy/piper)) | MIT | per voice | code yes; check every voice | 15-110 MB per voice (UNVERIFIED) | much faster than real time (UNVERIFIED) | espeak-ng (GPL) | no | archived 2025-10-06 |
| Piper ([OHF-Voice/piper1-gpl](https://github.com/OHF-Voice/piper1-gpl)) | GPL-3.0 | per voice; default "personal use and research" ([VOICES.md](https://github.com/OHF-Voice/piper1-gpl/blob/main/docs/VOICES.md)) | GPL obligations | same | same | embeds espeak-ng | no | seeking maintainers |
| Kokoro-82M ([card](https://huggingface.co/hexgrad/Kokoro-82M)) | Apache-2.0 | Apache-2.0 (training data includes two CC-BY sets) | yes, attribution may apply | about 300 MB, about 80 MB quantized ([kokoro-onnx](https://github.com/thewh1teagle/kokoro-onnx)) | "near real-time on M1" (vendor claim) | misaki (Apache-2.0, Python, English works without espeak fallback ([misaki](https://github.com/hexgrad/misaki))); espeak-ng for other languages and in sherpa-onnx | no; speed only | active |
| sherpa-onnx ([repo](https://github.com/k2-fsa/sherpa-onnx)) | Apache-2.0 | per model | **TTS build vendors an espeak-ng fork** (see below) | small runtime + model | per model | espeak-ng always linked with TTS on | Pocket, ZipVoice | active |
| Supertonic 3 ([repo](https://github.com/supertone-inc/supertonic)) | MIT | OpenRAIL-M (use restrictions passed to users) | yes, with OpenRAIL-M terms | about 99M parameters | "fast on CPU"; RTF 0.3 on an e-reader | none (raw text) | no | archived 2026-09-09 |
| Pocket TTS ([card](https://huggingface.co/kyutai/pocket-tts), [repo](https://github.com/kyutai-labs/pocket-tts)) | MIT | CC-BY-4.0, gated download | yes, attribution, use policy | about 100M; sherpa int8 about 98 MB (third-party figure) | about 6x real time on 2 cores of an M4 Air; about 200 ms to first audio | not mentioned | **yes, from a WAV** | active |
| Chatterbox ([repo](https://github.com/resemble-ai/chatterbox)) | MIT | MIT | yes | 110M-500M | Nano about 3x real time on 8 cores | not mentioned (UNVERIFIED) | yes; Perth watermark on every output | active; ONNX export [onnx-community](https://huggingface.co/onnx-community/chatterbox-ONNX) |
| OpenVoice V2 ([repo](https://github.com/myshell-ai/OpenVoice)) | MIT | MIT | yes ("free for commercial use") | UNVERIFIED | UNVERIFIED | via MeloTTS (UNVERIFIED) | tone-color conversion | quiet |
| MeloTTS | MIT (UNVERIFIED) | MIT (UNVERIFIED) | yes (UNVERIFIED) | about 200 MB (UNVERIFIED) | real time on CPU (claimed) | UNVERIFIED | no | quiet |
| KittenTTS v1 | Apache-2.0 | Apache-2.0 | yes | 25-80 MB | fast | espeak-ng (UNVERIFIED) | no | superseded |
| StyleTTS2 ([repo](https://github.com/yl4579/StyleTTS2)) | MIT | must tell listeners speech is synthetic | yes, with disclosure | 100-200 MB (UNVERIFIED) | moderate | espeak-ng (UNVERIFIED) | style transfer | low activity |
| espeak-ng | GPL-3.0 | n/a | GPL obligations | a few MB | instant | is the phonemizer | no | maintained |
| Coqui XTTS-v2 ([card](https://huggingface.co/coqui/XTTS-v2)) | MPL (UNVERIFIED) | CPML: non-commercial ("only so far as you do not receive any direct or indirect payment arising from the use of the model or its output") | **no** | about 1.8 GB | slow | — | yes | Coqui closed |
| F5-TTS ([card](https://huggingface.co/SWivid/F5-TTS)) | MIT (UNVERIFIED) | CC-BY-NC-4.0 | **no** | — | — | — | yes | — |
| ZipVoice ([card](https://huggingface.co/k2-fsa/ZipVoice)) | Apache-2.0 | CC-BY-NC (Emilia data) | **no** | about 104 MB int8 | — | espeak-ng data passed | yes | — |
| NeuTTS Air / Nano ([repo](https://github.com/neuphonic/neutts)) | UNVERIFIED | Air Apache-2.0; Nano "NeuTTS Open License 1.0" (under $5M revenue) | Air yes; Nano conditional | 0.7B / about 229M, GGUF | built for laptop CPU | **espeak-ng required** | yes, Perth watermark | active |
| Spark-TTS, IndexTTS2, KittenTTS 2, VibeVoice | — | NC-SA / custom / Stellon / restricted | no or by agreement | — | — | — | — | — |

**sherpa-onnx and espeak-ng (verified).** In sherpa-onnx's `CMakeLists.txt`,
`option(SHERPA_ONNX_ENABLE_TTS ... ON)` and:

```cmake
if(SHERPA_ONNX_ENABLE_TTS)
  include(espeak-ng-for-piper)
  ...
  include(piper-phonemize)
endif()
```

`cmake/espeak-ng-for-piper.cmake` downloads `github.com/csukuangfj/espeak-ng` (a fork of the
GPL-3.0 espeak-ng). sherpa-onnx's Kokoro models need an `espeak-ng-data/` directory
([sherpa Kokoro page](https://k2-fsa.github.io/sherpa/onnx/tts/pretrained_models/kokoro.html)).
So any build with sherpa-onnx TTS links GPL code, even for a model that does not use it.
Whether running it as a separate executable avoids the GPL's effect on the browser is a legal
question, not answered here.

**Kokoro in sherpa-onnx** (from the page above): `kokoro-multi-lang-v1_0` (53 speakers,
model 310 MB, `voices.bin` 26 MB), `kokoro-multi-lang-v1_1` (103 speakers, float and int8),
`kokoro-en-v0_19` (11 speakers, 330 MB); 24 kHz output; RTF on a Raspberry Pi 4 between 2.8
(4 threads) and 7.6 (1 thread), meaning slower than real time there.

**Inference runtime.** ONNX Runtime is MIT; CPU-only library roughly 10-30 MB per platform
(UNVERIFIED); CoreML provider on macOS; DirectML on Windows is in maintenance mode
(UNVERIFIED). ggml-based TTS projects exist but are less mature (UNVERIFIED).

## Voice cloning

**User decision (2026-10-19): "Allow voice cloning for personal use."** As relayed by the
coordinator, this means:
- The scope is the user's own voice, or a voice they are entitled to use, for their own use in
  their own browser. No feature clones a third party's voice from web audio, and cloned voices
  are not shared or exported.
- An explicit consent step comes before enrolment. Voice samples and the cloned voice stay
  local, and the user can delete them.
- Licensing still matters because zigBrowser is a shipped product. An engine whose license
  forbids commercial distribution (Coqui XTTS-v2 under CPML, confirmed above from its
  LICENSE.txt definition of non-commercial purpose) cannot be bundled, even when the end use is
  personal.

What exists:
- **macOS Personal Voice** (above): Apple's own enrolment (about 15 minutes of reading in
  System Settings, UNVERIFIED duration) and Apple's own consent and permission flow. The app
  cannot create the voice; it can only ask to use it. Creation needs Apple Silicon. Languages
  are limited.
- **Windows**: no OS cloning or personal-voice API for apps was found. Azure personal voice is
  cloud-only and gated. On Windows, cloning means a bundled engine.
- **Commercially redistributable local cloning engines:** Pocket TTS (CC-BY-4.0, its policy
  bans cloning "without explicit and lawful consent"), Chatterbox (MIT, with the Perth
  watermark on by default; Resemble's sample turns it off), OpenVoice V2 (MIT), NeuTTS Air
  (Apache-2.0, but needs espeak-ng). The phonemizer dependencies of Chatterbox and OpenVoice
  are UNVERIFIED.
- **Consent practice in the field:** Azure requires a recorded verbal consent statement from
  the speaker; Kyutai and others ban cloning without consent; Chatterbox and NeuTTS watermark
  output. ElevenLabs' and Resemble's consent flows were not researched.
- **Law (UNVERIFIED, background only):** Tennessee's ELVIS Act (2024) targets unauthorized
  voice replicas; EU AI Act Article 50 requires machine-readable marking of synthetic audio
  by providers. Counsel should confirm what applies to a browser that clones only the user's
  own voice locally.

## Speaking a streamed reply

Sources: Open WebUI splits at `.`, `!`, `?` by default, or by paragraph
([docs](https://docs.openwebui.com/features/chat-conversations/audio/text-to-speech/openai-tts-integration));
Pipecat holds text until a sentence ends and has a markdown filter
([text](https://docs.pipecat.ai/server/utilities/text/overview),
[filters](https://docs.pipecat.ai/server/base-classes/text)); stream2sentence (RealtimeTTS)
splits LLM token streams into sentences and can emit an early first fragment
([PyPI](https://pypi.org/project/stream2sentence/0.2.5)). How ChatGPT's read-aloud works was
not found (UNVERIFIED).

Facts from the codebase that shape it:
- Deltas arrive coalesced at about 50 ms and refreshed on screen at 100 ms, and can split a
  word or a markdown fence anywhere.
- One prompt can produce several bubbles (one per `AssistantMessage`).
- The final `assistant_message` may be truncated (`[output truncated]`) and replaces the
  bubble's text.
- Stop drops later deltas and ends the bubble with "(stopped)". Stop is enabled only while
  busy.
- The drawer shows plain text. The model often writes markdown (fences, `**`, links), which
  the drawer shows raw today.

Common practice (the plan decides): buffer until a sentence end that is not an abbreviation,
decimal or version number; a short first chunk to cut the time to first audio; a maximum chunk
length that splits at a comma; synthesize the next chunk while the current one plays; stop
flushes the queue and cancels the current synthesis; replace code blocks with a short phrase;
read link text, not URLs; strip emphasis, headings and bullets.

Accessibility (UNVERIFIED, no source found): when a screen reader (VoiceOver, Narrator, Orca)
is active, automatic reading would talk over it; respect the system's spoken-content settings
where an API exposes them (`prefersAssistiveTechnologySettings` on macOS).

## Decisions recorded 2026-10-19 and what they change

### Bundled engine first

The user decided that the bundled local engine is the primary path on every platform. The
engine choice was left open unless the research made it clear. Of the engines surveyed, only
**Pocket TTS** meets every constraint together: a license that allows commercial
redistribution, no espeak-ng (as far as its sources say), fast on a laptop CPU, and cloning in
the same model. Kokoro has no cloning and needs espeak-ng outside English. Supertonic has no
cloning and its repo is archived. Chatterbox clones but is Python-first and larger. So the
research points to Pocket TTS. The checks below say which facts are confirmed.

**User decision (2026-10-19): "Confirm Pocket TTS for the voice engine."** The engine is
decided. Not settled by this confirmation, and still open or unverified:
- the Hugging Face download-gate terms on `kyutai/pocket-tts` (unread; to be read before
  shipping);
- the runtime path: our own ONNX export through the ONNX Runtime C API, or PocketTTS.cpp once
  its license is read;
- the CC-BY-4.0 attribution, which becomes a packaging task (a credits screen, and the license
  text in each installer).

Cloning follows from the choice: Pocket TTS clones from a WAV file (Kyutai's repo), and
sherpa-onnx documents cloning from reference audio alone. The ungated repo's name,
`pocket-tts-without-voice-cloning`, suggests the cloning part comes only with the gated repo,
so the gate terms decide whether the cloning part can be redistributed (UNVERIFIED).

**Pocket TTS, checked 2026-10-19:**

| Fact | Finding | Source | Status |
|---|---|---|---|
| Code license | MIT ("MIT license", LICENSE file in the repo) | [kyutai-labs/pocket-tts](https://github.com/kyutai-labs/pocket-tts) | verified |
| Weights license | **CC-BY-4.0** (Creative Commons Attribution 4.0 International) on both `kyutai/pocket-tts` and `kyutai/pocket-tts-without-voice-cloning` | [card](https://huggingface.co/kyutai/pocket-tts), [no-cloning card](https://huggingface.co/kyutai/pocket-tts-without-voice-cloning) | verified as the Hugging Face license **tag**; no LICENSE file is shown in the weights repo |
| Attribution | CC BY 4.0 requires credit to the licensor, a link to the license, and a note of any changes (for example a conversion to ONNX or int8). This is from the license itself, not from Kyutai's page | CC BY 4.0 legal code | from the license text (well known); Kyutai's own attribution or citation wording was not readable |
| Access | `kyutai/pocket-tts` is **gated**: the user must accept conditions and share their Hugging Face details to download. The gate text could not be read (the README returned HTTP 401). `kyutai/pocket-tts-without-voice-cloning` shows no gate. The main repo has a script `remove_voice_cloning_and_push.py`, which suggests the no-cloning repo is the main model with the cloning part removed | the two cards | gate wording **UNVERIFIED**; whether the gate adds contractual terms on top of CC BY 4.0 is **UNVERIFIED** |
| Use policy | Prohibited use includes "voice impersonation or cloning without explicit and lawful consent" and presenting generated content "as genuine recordings of real people or events" | [card](https://huggingface.co/kyutai/pocket-tts) | verified |
| Commercial use | No statement for or against. CC BY 4.0 allows commercial use | repo, card | the license allows it; no Kyutai statement |
| Size | About 100M parameters. Weights file `tts_b6369a24.safetensors` is **236 MB**. Tokenizer `tokenizer.model` 59 kB, `tokenizer.json` 245 kB. Folders `embeddings/`, `embeddings_v2/`, `embeddings_v3/` (voice embeddings) and `languages/` (sizes not shown) | [files](https://huggingface.co/kyutai/pocket-tts/tree/main) | verified for the files shown; the total with `languages/` is **UNVERIFIED** |
| Quantized size | sherpa-onnx's package `sherpa-onnx-pocket-tts-int8-2026-01-26` has `lm_flow.int8.onnx`, `lm_main.int8.onnx`, `decoder.int8.onnx`, `encoder.onnx`, `text_conditioner.onnx`, `vocab.json` and `token_scores.json`. About 98 MB for the int8 build is a third-party figure | [sherpa Pocket page](https://k2-fsa.github.io/sherpa/onnx/tts/pocket.html) | file list verified; size **UNVERIFIED** |
| Speed | About 6x real time on a MacBook Air M4 using 2 CPU cores; about 200 ms to the first audio chunk; streaming output; CPU-first (a T4 GPU gave only about 2.6x over CPU) | repo, card | vendor figures, verified as stated; no figure for Intel Macs or Windows arm64 |
| Voices and languages | 26 built-in voices (21 English, plus one each in Italian, Spanish, German, Portuguese and French). Languages: English, French, German, Portuguese, Italian, Spanish and Dutch (the card says six without Dutch; the repo lists Dutch) | repo, card | verified, with the Dutch discrepancy noted |
| Cloning | A WAV file as the voice; the repo advises cleaning the sample first. Reference length is not stated. sherpa-onnx needs only the reference audio, no transcript | repo, sherpa page | verified; length **UNVERIFIED** |
| Sample rate | Read from `tts_model.sample_rate`; the value is not stated | repo | **UNVERIFIED** |
| Watermark | None mentioned | repo, card | — |
| Phonemizer | None mentioned (SentencePiece tokenizer) | repo, card, sherpa page | no espeak-ng mentioned; **UNVERIFIED** as an absence |

**Ways to call it from Zig on macOS arm64/x86_64 and Windows x64:**
- **The official runtime is Python and PyTorch only.** There is no official ONNX export.
- **sherpa-onnx** (Apache-2.0) runs Pocket TTS through its C API (`pocket-tts-en-c-api.c`
  example). But a sherpa-onnx build with TTS on **always vendors the GPL espeak-ng fork**
  (verified in its `CMakeLists.txt`, section above), even though Pocket does not appear to
  use it. Using it as-is brings the GPL question back. Patching the build to drop espeak-ng
  for a Pocket-only build was not checked (**UNVERIFIED**).
- **PocketTTS.cpp** (VolgaGerm): a single-file C++ runtime on ONNX Runtime with a C FFI API,
  voice cloning and streaming. It is listed in Kyutai's README. It is small (about 50 stars,
  last push 2026-03-29). Its code license was not read (**UNVERIFIED**). Its ONNX exports are
  hosted in `HeddyRogue/PocketTTS-VolgaGerm-ONNX` (MIT per the search result, **UNVERIFIED**).
- **pocket-tts-onnx-export** (KevinAHM) exports ONNX for ONNX Runtime Web (license
  **UNVERIFIED**).
- Also listed: Rust ports (`wasm-pocket-tts`, `pocket-tts-candle`), MLX for Apple Silicon, a
  Core ML macOS app, and C#.
- **The path with the fewest unknowns**: export ONNX ourselves from the MIT PyTorch code
  (using the community exports as a reference), then call the **ONNX Runtime C API** from
  Zig. ONNX Runtime is MIT and publishes prebuilt libraries for macOS (arm64 and x86_64) and
  Windows (x64 and arm64). That last fact is from general knowledge and was not re-checked
  here (**UNVERIFIED**).

### Bundle or download the TTS model

- The STT plan bundles whisper medium, so the installer already grows by about 0.8 GB.
- The Pocket TTS int8 ONNX build is about 100 MB (**UNVERIFIED** figure). The bf16
  safetensors file is 236 MB. Add ONNX Runtime (roughly 10-30 MB per platform,
  **UNVERIFIED**) and miniaudio (one header).
- Read-aloud is on by default and the engine is the primary voice, so the first reply after
  install must be spoken offline. A download on first use would leave the default feature
  silent until it finished.
- Measured against an installer that is already about 0.8 GB larger, roughly 0.1-0.13 GB more
  is small.
- The plan's choice is to **bundle the int8 model and ONNX Runtime in the installer**, with the
  model manager kept for updates and optional extra languages. The user can reverse this.

### On by default

What changes because read-aloud is on by default (the plan decides the details):
- A mute and stop control has to be visible whenever speech can happen, including while the
  drawer is minimized. Today the drawer's Stop is greyed out once a reply has finished
  arriving (`zb_drawer_agent_status`), so it cannot be that control.
- A screen-reader user would hear two voices at once. Platform signals exist: Orca through the
  AT-SPI bus's `org.a11y.Status` `ScreenReaderEnabled` property, VoiceOver through
  `NSWorkspace.isVoiceOverEnabled` (macOS 10.13+), Narrator and others through
  `SystemParametersInfo(SPI_GETSCREENREADER)`. These are from general knowledge and were not
  re-checked here (**UNVERIFIED**).
- Code is common in agent replies, so reading code blocks by default would be loud and long.
- A first-run notice is the plain way to tell the user why the browser is talking.

## Shared pieces with the speech-to-text plan

Named here so both plans can use the same names:
- **Audio device layer** (`zb_audio`): miniaudio ([repo](https://github.com/mackron/miniaudio),
  public domain or MIT-0, one C header) covers playback and capture on Core Audio, WASAPI,
  PulseAudio (and PipeWire through it) and ALSA. TTS needs playback (for WinRT streams and any
  bundled engine); STT needs capture; cloning enrolment needs capture too.
- **Voice settings window**: one native window with a "Read aloud" section (this plan) and a
  "Dictation" section (the STT plan), opened from the drawer, built like the Secrets window.
- **Voice settings store**: `<profile>/voice.json`, versioned, atomic, like `agent-drawer.json`.
- **Permission prompts and usage strings**: microphone (`NSMicrophoneUsageDescription`,
  `com.apple.security.device.audio-input`) for STT and for cloning enrolment; Personal Voice
  authorization for TTS. Each Mac key is added only when a signed build proves it is needed,
  per `entitlements.plist`'s rule.
- **Model manager**: download, checksum-pin, store under `$XDG_DATA_HOME/zigbrowser/models/`
  (and the platform equivalents), and delete. Used by whisper.cpp models and any bundled TTS
  or cloning model.
- **Test rule**: no automated test opens the user's real audio devices, just as no test uses
  the real display.

## Code References

- `agent/host/zb_agent_host/options.py:127` - `include_partial_messages=True`
- `agent/host/zb_agent_host/chat.py:31` - `DELTA_INTERVAL_S = 0.05`
- `agent/host/zb_agent_host/sandbox.py:51` - `EGRESS_ALLOW = ("api.anthropic.com",)`
- `src/agent_protocol.zig:26-35` - the `Frame` union
- `src/agent_protocol.zig:152-153` - delta 16 KiB and message 256 KiB caps
- `src/agent_helper.c:285` - `on_frame` dispatch
- `src/agent_helper.c:831` - `zb_agent_helper_interrupt`
- `src/agent_drawer.c:1-8` - inert-text rule
- `src/agent_drawer.c:174` - `drawer_row`
- `src/agent_drawer.c:605` - `set_bubble_text` (original text kept for Copy)
- `src/agent_drawer.c:754` - `end_stream`
- `src/agent_drawer.c:804` - `zb_drawer_agent_status` (Stop live only while busy)
- `src/agent_drawer.c:820` - `zb_drawer_agent_message`
- `src/agent_drawer.c:842` - `zb_drawer_agent_delta`
- `src/agent_drawer.c:863` - `zb_drawer_agent_stopped`
- `src/agent_drawer.c:883` - `on_stop_clicked`
- `src/agent_drawer.zig:244` - `agent-drawer.json` persistence
- `src/agent_drawer.zig:336-339` - exports only on Linux
- `src/agent_config.zig:14-32` - `AgentDrawer` env switch pattern
- `src/media_config.zig:17-35` - `MediaSource` env switch
- `src/app.zig:52-54` - agent setup is Linux-only
- `src/webkit_shim.c:1285` - `zb_drawer_attach`
- `build.zig:1481` - `resolveBackend`
- `build.zig:1503`, `:1535`, `:1560` - the three backend configure functions
- `build.zig:250` - Windows cross-check target `x86_64-windows-gnu`
- `packaging/macos/entitlements.plist`, `packaging/macos/Info.plist:21-22`
- `tests/mac/gate.sh:23-25,44-46` - Mac hosts and the fail-closed arm64 check
- `tests/e2e/agent_chat_test.py`, `tests/e2e/fake_anthropic_api.py`

## Architecture Documentation

- One C ABI, three backends selected by target OS. Portable logic lives in Zig, toolkit glue
  in C or Objective-C; GTK is touched only on the main thread.
- The agent side is three processes (netd, helper, CLI) plus hooks, all sandboxed; the
  browser process owns the UI and the frames' validation.
- Persisted state is small versioned JSON written atomically into the profile.
- E2e observation is through `--e2e-protocol` rows with a fixed schema, never through a
  production read API on the automation socket.
- Optional system libraries are loaded with `dlopen` (libsecret).

## Workflow Closure Map

**Behavior:** "When the agent streams a reply into a drawer window, the browser speaks it
aloud, sentence by sentence, and stops speaking when the user stops it."

Today the chain ends at the drawer bubble. The speech nodes do not exist.

| Depth | Node | Location | Label | This work adds or changes |
|---|---|---|---|---|
| 0 | scripted turns of the fake Messages API (SOURCE) | `tests/e2e/fake_anthropic_api.py` | test boundary (true system boundary, mocking allowed) | no |
| 1 | `Session.prompt` turns SDK deltas into `assistant_delta` / `assistant_message` | `agent/host/zb_agent_host/chat.py` | production-called | no |
| 2 | `on_frame` dispatches `ZB_FRAME_DELTA` / `MESSAGE` / `RESULT` | `src/agent_helper.c:285` | production-called | **changed**: also feeds speech (highest_new_connector) |
| 3 | speech feed: markdown clean-up, sentence chunking, per-window queue | new (`src/speech_*.zig`) | not found | added |
| 4 | speech backend: speak / stop / voice list | new (per platform) | not found | added |
| 5 | observable: `SPEECH` rows under `--e2e-protocol` and the synthesized audio | new rows beside `drawer_row` | not found | added |

Edges:
- 0→1: HTTP SSE through relay → netd → fake API. Async, cross-process. Errors become `error`
  frames. Tested by `tests/e2e/agent_chat_test.py`.
- 1→2: NDJSON on the helper's stdout, read by `on_read` on the GLib main loop and validated
  by `zb_agent_frames_validate`. Async, cross-process. Rejected frames are dropped, the third
  kills the helper. Runtime context: the session id maps to a window (`win_of_session`); the
  `stopping` flag drops frames after Stop. Tested by `agent_chat_test.py`.
- 2→3: an in-process call on the main thread (does not exist yet).
- 3→4: a queue drained on the main loop; the backend works on its own thread or the OS's
  (does not exist yet).
- 4→5: backend callbacks posted back to the main loop write the rows (does not exist yet).

Negative evidence: `grep -ri` for `speech`, `tts`, `voice`, `AVSpeech`, `SAPI`,
`SpeechSynthesis`, `miniaudio` in `src/`, `agent/` and `build.zig` found no speech code. No
test writes speech rows today.

`highest_new_connector`: `on_frame` in `src/agent_helper.c` (depth 2), the first node the
work changes. A plan may instead hook at the drawer functions (`zb_drawer_agent_delta` and
friends, one level down); either way the trigger must be the real frame stream.

### ClosureMap (structured — derive() input)

```json
{
  "behavior": "When the agent streams a reply into a drawer window, the browser speaks it aloud sentence by sentence and stops when the user stops it.",
  "git_commit": "a69b459cb5346e8d25488f41e76c034d6fd8f3fa",
  "repo": "/home/maceo/ntm_Dev/zb-automation-integration-2026-10-10-11-59",
  "nodes": [
    { "id": "fake_api_turns", "module": "tests/e2e/fake_anthropic_api.py", "is_entrypoint": false, "adds_or_changes": false, "read_path": null, "seedable_store": "fake_anthropic_api scripted turns" },
    { "id": "chat_session_prompt", "module": "agent/host/zb_agent_host/chat.py", "is_entrypoint": true, "adds_or_changes": false, "read_path": null, "seedable_store": null },
    { "id": "helper_on_frame", "module": "src/agent_helper.c", "is_entrypoint": false, "adds_or_changes": true, "read_path": null, "seedable_store": null },
    { "id": "speech_feed", "module": "src/speech (new)", "is_entrypoint": false, "adds_or_changes": true, "read_path": null, "seedable_store": null },
    { "id": "speech_backend", "module": "src/speech backends (new)", "is_entrypoint": false, "adds_or_changes": true, "read_path": null, "seedable_store": null },
    { "id": "speech_rows", "module": "src/agent_drawer.c (rows beside drawer_row)", "is_entrypoint": false, "adds_or_changes": true, "read_path": "SPEECH rows on stdout under --e2e-protocol (new; does not resolve at the pin)", "seedable_store": null }
  ],
  "edges": [
    { "is_async": true, "cross_boundary": true, "driver": "Session.prompt" },
    { "is_async": true, "cross_boundary": true, "driver": "on_read" },
    { "is_async": false, "cross_boundary": true, "driver": null },
    { "is_async": true, "cross_boundary": false, "driver": "speech queue pump on the GLib main loop (new)" },
    { "is_async": true, "cross_boundary": true, "driver": "backend completion callback posted to the main loop (new)" }
  ]
}
```

The observable and two drivers are new and do not resolve at the pin, so this map is
under-specified on purpose and should derive to BLOCKING. The plan names the real symbols.

### Closure adapter (staged proposal)

The research skill would stage this as a sibling `.closure-adapter.py` file. The brief for
this task allows only two files to be written, so it is kept here, inside the document, and is
not written to disk.

```python
"""Closure adapter (STAGED PROPOSAL — not wired into the repo, not written to disk).
Derived from the ClosureMap for: agent reply spoken aloud.  Pin: a69b459.
Promote into the repo and complete each TODO(promote) before use.
"""
import http.server, json, sys
ASYNC_EDGES = ["api_to_chat", "chat_to_on_frame", "feed_to_backend", "backend_to_rows"]
CONNECTOR = {e: True for e in ASYNC_EDGES}
SINK = []

def handle(op, p):
    if op == "/reset":        SINK.clear(); CONNECTOR.update({e: True for e in ASYNC_EDGES}); return {"ok": True}
    if op == "/set_connector": CONNECTOR[p["edge"]] = p["enabled"]; return {"ok": True}
    if op == "/seed_sink":     SINK.append(p["value"]); return {"ok": True}
    if op == "/seed":
        # TODO(promote): script fake_anthropic_api turns with p["data"]   (tests/e2e/fake_anthropic_api.py)
        return {"ok": True}
    if op == "/trigger":
        # TODO(promote): send a prompt in the drawer (send_input -> zb_agent_helper_send)  (src/agent_drawer.c:893, src/agent_helper.c:791)
        return {"ok": True}
    if op == "/drive":
        if not CONNECTOR.get(p["edge"], True): return {"ok": True}
        # TODO(promote): wait on the real main loop: on_read (src/agent_helper.c), then the new speech pump
        return {"ok": True}
    if op == "/observe":
        # TODO(promote): return the SPEECH rows parsed from the browser's stdout (new row family)
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

- `thoughts/searchable/shared/plans/2026-10-13-claude-agent-chat-drawer-tdd-plan.md` - the
  drawer plan. D1 (native widgets, no web content), the D7b row table, S5 (streaming and
  Stop), §7.1 (real-screen check). Voice is a non-goal (`:1097`).
- `thoughts/searchable/shared/plans/2026-10-14-14-30-macos-launch-tdd-plan.md` - MS7 (AppKit
  drawer), MS8 (helper on macOS), the two-host Mac gate. Windows drawer out of scope (`:373`).
- `thoughts/searchable/shared/research/2026-10-14-agent-sandbox-redteam.md` - egress allowlist,
  bridges, WSL2 for Windows.
- `thoughts/searchable/shared/research/2026-10-14-macos-sandbox-option.md` - Seatbelt; the
  helper is denied most mach services, so audio inside the helper is not an option on macOS
  either.
- Search of thoughts/ for `tts`, `text-to-speech`, `speech`, `piper`, `kokoro`, `whisper`
  found nothing before today except the sibling STT document.
- Beads: `bd list` reports pending schema migrations on this clone; per the project rule, no
  `bd` writes were made and no issue was filed.

## Related Research

- `/home/maceo/ntm_Dev/zigBrowser/thoughts/searchable/shared/research/2026-10-19-voice-recognition-options.md`
  - speech-to-text (sibling).
- `thoughts/searchable/shared/research/2026-10-14-14-19-macos-launch-support-surface.md`

## Open Questions

- Does an unpackaged Win32 app get WinRT `SpeechSynthesizer` on Windows 10 and 11 (x64 and
  arm64)? Does the Windows SDK `winrt` directory hold `windows.media.speechsynthesis.h`, and
  does Zig's linker find `RoActivateInstance` (`runtimeobject` or the `api-ms-win-core-winrt`
  import libraries)?
- Does AVSpeechSynthesizer speak under the hardened runtime with no added entitlement? Does
  Personal Voice need an Info.plist string? Can an Intel Mac use a Personal Voice?
- Does the installed WebKitGTK 2.54.0 have `speechSynthesis` (only relevant if a web path were
  ever used)?
- The engine is decided (Pocket TTS, also for cloning). Still open: do Pocket TTS's gate
  terms allow redistributing its files (including the cloning part), and what attribution
  wording does Kyutai ask for?
- The phonemizer dependencies of Chatterbox, OpenVoice V2 and MeloTTS.
- Real latency to first audio for each backend on the two Macs.
- Windows: whether `win11-m8` gets a working capture device (the Windows plan's provisioning
  item 12), which decides whether cloning enrolment can run live there or only through the WAV
  fixture seam; and the Windows plan's open sandbox technology (OD-W4), which WS8.7 depends on.
- Pocket TTS: the gate's wording on `kyutai/pocket-tts`, the code license of PocketTTS.cpp,
  the int8 size, the sample rate, the reference-audio length, and whether sherpa-onnx can be
  built for Pocket without espeak-ng.
