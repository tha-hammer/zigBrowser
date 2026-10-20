---
date: 2026-10-19T15:25:29-04:00
planner: Claude (Opus 5.5), planning subagent for the voice plans
git_commit: a69b459cb5346e8d25488f41e76c034d6fd8f3fa
branch: zb-automation-integration-2026-10-10-11-59
repository: zigBrowser
topic: "The browser's voice: agent replies spoken aloud, with user-customizable voices — TDD implementation plan"
tags: [plan, tdd, tts, text-to-speech, voice, agent-drawer, pocket-tts, onnxruntime, macos, windows, linux-dev, voice-cloning, miniaudio]
status: plan for review (rev 2.2)
rev: 2.2
last_updated: 2026-10-19
last_updated_note: "Rev 2 records the user's decisions of 2026-10-19: bundled engine first (system voices become a later, secondary option), read-aloud on by default, the STT side bundles whisper medium (installer about 0.8 GB larger), and a separate Windows launch plan as the Windows dependency. Slices re-sequenced: core, test backend, audio layer, bundled engine, then the drawer and Voice window, then Macs, cloning, Windows, and system voices last."
primary_research: thoughts/searchable/shared/research/2026-10-19-voice-output-tts.md
sibling_plan: the voice-input (speech-to-text) plan, written in parallel by another agent
windows_dependency: thoughts/searchable/shared/plans/2026-10-19-windows-launch-tdd-plan.md (milestones WS0-WS13; this plan depends on WS0 hosts, WS1 build, WS5 drawer, WS8 sandbox incl. WS8.7, WS11 helper/chat, WS12 voice hooks, WS13 installer)
---

# The browser's voice (text-to-speech): TDD implementation plan

> **PLAN ONLY.** Nothing here was built, run or committed. Automated tests run only under a
> private Xvfb on Linux, on the two remote Macs over SSH, or on the Windows launch plan's test
> hosts once they exist. They never use the user's display (`DISPLAY :0`), the live profile,
> the live socket, **or the user's real speakers**. Every UI slice ends with a real-screen
> check that the orchestrator runs with the user.

## Revision history

- **Rev 1:** first plan. System voices first; bundled engine decision-gated; read-aloud off by
  default; Windows drawer "no plan" (superseded).
- **Rev 2.2:** the Windows launch plan exists (WS0-WS13). Windows steps now cite its milestones
  by number and name its hosts. A **Windows cloning leg (CW)** is added: consent, local storage,
  delete, and a real-screen check on a Windows host. Stale "being written" and "no Windows
  host" lines are removed.
- **Rev 2.1:** the user confirmed Pocket TTS as the voice engine (DECIDED 4). Cloning uses it
  too, following from that choice. The gate terms (OD7) and the runtime path (OD2) stay open.
  CC-BY-4.0 attribution becomes a packaging task in V3.5.
- **Rev 2:** the user decided on 2026-10-19:
  - **bundled engine first**;
  - **read-aloud on by default**;
  - the STT plan **bundles whisper medium** in the installer;
  - a separate **Windows launch plan** (at the time being written; it now exists, see rev 2.2).

  So:
  - The bundled engine (Pocket TTS, confirmed by the user later the same day) moves right after
    the core, the test backend and the audio layer.
  - System voices move to the end as a secondary option.
  - The drawer gets an always-visible mute and stop control, a first-run notice and a
    screen-reader pause.
  - The TTS model is bundled in the installer (section 6.2).
  - Windows slices now depend on the Windows launch plan (milestones cited in rev 2.2).
  - The real-screen checks follow these changes.

## 0. Requirements

### 0.1 The user's request (verbatim, 2026-10-19)

"We need to break this into 2 plans: 1 plan for the voice of the browser, this will allow the
LLM to generate text that is spoken and allow the user to customize voices. The second plan
is for the user to use voice to text. Mac and Windows are the 2 main target systems, Linux is
my environment, not the primary target for users. I'm comfortable with shipping whisper.cpp
and handling the model as part of the browser."

This plan is the first of the two. It covers:
- the agent's replies in the chat drawer are spoken aloud;
- the user can choose the voice, rate, pitch and volume, and what is read and when;
- macOS and Windows are the primary user platforms. Linux must work well enough to develop and
  test on;
- shipping a local model is acceptable.

### 0.2 Decided by the user (2026-10-19, through the coordinator)

**DECIDED 1. Voice cloning is allowed for personal use.** "Allow voice cloning for personal
use." Consequences, each a test below:
1. Only the user's own voice, or one they are entitled to use, for their own use in their own
   browser. Nothing clones a voice from web audio (page audio, media elements, downloads, tab
   output). Cloned voices are never shared or exported.
2. An explicit consent step before every enrolment. The samples and the cloned voice stay on
   the device. Deletion is complete.
3. The engine must allow commercial redistribution even though the use is personal. Coqui
   XTTS-v2 (CPML, non-commercial), F5-TTS, ZipVoice and Spark-TTS weights cannot be bundled.
4. On macOS, Apple's Personal Voice is an extra (Apple's own enrolment and consent). Windows
   has no OS API for a personal or cloned voice for apps, so cloning everywhere uses the
   bundled engine.
5. Cloning has its own slices (C1-C3 on Linux and macOS, CW on Windows, and S4 for Personal
   Voice), each with a real-screen check.

**DECIDED 2. Bundled engine first.**
- The bundled local engine ships first, as the primary voice on every platform. That way
  every platform sounds the same and cloning works everywhere.
- The system voices (AVSpeechSynthesizer on macOS, WinRT and SAPI on Windows,
  speech-dispatcher on Linux) become a later, secondary option.
- The engine is decided separately (DECIDED 4).

**DECIDED 4. Pocket TTS is the voice engine.** The user said: "Confirm Pocket TTS for the
voice engine" (2026-10-19). Pocket TTS has MIT code and CC-BY-4.0 weights, about 100M
parameters, and runs fast on a CPU. What this confirmation does **not** settle stays open or
unverified:
- **The Hugging Face download-gate terms** on `kyutai/pocket-tts` (if any) must be read before
  shipping. They could add terms on top of CC BY 4.0. This is UNVERIFIED (the README returned
  HTTP 401), and it is a ship gate (OD7).
- **The runtime path** stays open (OD2): our own ONNX export through the ONNX Runtime C API
  (recommended), or PocketTTS.cpp once its license is read.
- **CC-BY-4.0 attribution** is a concrete packaging task (V3.5): a credits screen (About this
  voice in the Voice window, and the app's About or credits screen) and the license text in
  every installer.
- **Cloning engine: follows from this choice.** Pocket TTS clones a voice from a WAV file
  (Kyutai's repo; sherpa-onnx documents cloning from reference audio alone), so it is also the
  cloning engine. One caveat: the ungated repo is named `pocket-tts-without-voice-cloning`,
  which suggests that cloning needs the gated repo's files. That makes the gate terms matter
  for cloning too. If they forbid redistributing the cloning part, the cloning engine goes back
  to the user (Chatterbox, MIT, would be the next candidate).

**DECIDED 3. Read-aloud is on by default.** Automatic read-aloud of agent replies is on in a
new profile. Consequences planned here (section 3, D5, and slice V4):
- an always-visible mute and stop control, including while the drawer is minimized;
- a one-time notice the first time a reply is spoken;
- Stop and Send stop speech (decided by this plan, section 6.2);
- code blocks are not read by default (decided by this plan; whether they are announced is
  OD5);
- automatic reading pauses while a screen reader is active (decided by this plan, section
  6.2).

**Constraint from the STT side (2026-10-19).** The user chose to **bundle the whisper medium
model in the installer**, so the installer is already about 0.8 GB larger. Section 6.2 weighs
the TTS model against that.

**Windows is a main target.** The **Windows launch plan** (`thoughts/searchable/shared/plans/2026-10-19-windows-launch-tdd-plan.md`, milestones WS0-WS13)
covers the Windows drawer (WS5), the sandbox (WS8, with the no-network child WS8.7), the
helper and chat (WS11), the voice hook points (WS12) and the installer (WS13). Its test hosts
(WS0) are the Win11 VM `win11-m8` and the physical Windows 10 machine (`100.123.34.15`, `file-server-win-mac`, run-only). This plan's Windows slices depend on it (section 2.2).

### 0.3 Project rules this plan obeys

- Every UI slice names its own real-screen check, which the orchestrator runs with the user.
  Agents never run it.
- Automated tests run only under a private Xvfb (Linux), on the remote Macs, or on the Windows
  launch plan's two hosts (WS0: `win11-m8` and the physical Windows 10 machine).
- **Tests never use the user's real audio devices.** They use the `record` backend, a private
  PulseAudio null sink in a private `XDG_RUNTIME_DIR`, render-to-file, or a muted test host
  (section 7.3). Hearing the voice is a separate real-audio check run only by the
  orchestrator with the user.
- Red commits go outside gate-registered steps. A new test file is registered in `build.zig`
  only in the commit that makes it green.
- The Mac is tested on two real hosts, Intel and Apple Silicon, over SSH.
- Each slice says whether it can be built and tested from Linux, or needs a Mac or a Windows
  machine (section 7.5).
- Never reset, rebase or amend committed work; fix forward. Stage only your own hunks.

## 1. Overview

The browser speaks the agent's replies, and does so by default. A reply streams into the
drawer as text deltas. The browser:
- cleans the text for speech (code blocks, links, markdown marks);
- cuts it into sentences as it arrives;
- hands each sentence to the speech backend while the next one is prepared.

A mute and stop control is always in view. The agent's Stop and the Send button also silence
speech. A Voice window lets the user choose the voice, rate, pitch and volume, what is read,
and whether replies are read automatically.

Speech runs in the **browser process**, never in the sandboxed agent helper.

The **primary voice is a bundled local engine**, run in its own sandboxed process
(`zb-speech`) with ONNX Runtime. It returns PCM, which the browser plays through the shared
audio layer `zb_audio` (miniaudio). The same engine does cloning.

The portable logic is Zig, and it is all tested on Linux: text clean-up, chunking, the queue,
the settings and the parameter mappings. The system voices of each OS come later as a
secondary choice.

## 2. Current state

### 2.1 Key discoveries (research `2026-10-19-voice-output-tts.md`, pinned at `a69b459`)

Line numbers in `agent_drawer.c`, `agent_drawer.zig`, `agent_helper.c`, `build.zig` and
`chat.py` were read from a working tree that held other agents' uncommitted changes. Re-check
them against HEAD at the start of each slice. Function names are the stable anchor.

- **Where replies arrive.** `on_frame` in `src/agent_helper.c:285` sends:
  - `ZB_FRAME_DELTA` to `zb_drawer_agent_delta`;
  - `ZB_FRAME_MESSAGE` to `zb_drawer_agent_message`;
  - after Stop, on `ZB_FRAME_RESULT`, a call to `zb_drawer_agent_stopped`.

  It drops deltas and messages while the window is `stopping`.
- **The frames** (`src/agent_protocol.zig:26-35`):
  - `assistant_delta` is capped at 16 KiB and `assistant_message` at 256 KiB.
  - There is no message-start frame.
  - The helper coalesces deltas every 50 ms (`chat.py:31`).
  - One prompt can produce several `assistant_message`s.
  - The final text can end with `[output truncated]`.
- **The drawer** is native GTK 3 text, with no web view and no markdown (`agent_drawer.c:1-8`).
  - Bubbles keep their original text as `"zb-original"` (`set_bubble_text`, `:605`).
  - There are no per-message buttons.
  - **Stop is sensitive only while the status is `busy`** (`zb_drawer_agent_status`, `:804`),
    so it cannot be the speech stop once a reply has finished arriving.
- **E2e rows** go through `drawer_row` (`agent_drawer.c:174`) with `--e2e-protocol`. They
  must match the D7b table of the drawer plan
  (`…/2026-10-13-claude-agent-chat-drawer-tdd-plan.md:442-462`), which
  `tests/e2e/agent_common.py` `parse_row` enforces.
- **No audio code exists.** `src/media_config.zig` and `src/env_switch.zig` are the
  flag-then-env-then-default pattern to copy.
- **The helper sandbox** has no `/dev/snd`, no Pulse and no D-Bus, and egress only to
  `api.anthropic.com` (`sandbox.py:51`).
- **Precedents to reuse:**
  - persistence: `<profile>/agent-drawer.json`, written with `atomic_file.replaceJson`
    (`agent_drawer.zig:244`);
  - `dlopen`: libsecret in `agent_secrets.c`;
  - a separate window: the Secrets window (`agent_secrets_window.c`);
  - sandboxing a child process: the shared `SandboxBackend` contract (bwrap on Linux;
    Seatbelt in macOS MS6).
- **The drawer, helper and setup are Linux-only** (`configureGtkBackend`, `build.zig:1503`;
  `app.zig:52-54`).
- **macOS backend** links WebKit, Cocoa and Foundation only (`build.zig:1560`). Other facts:
  - `LSMinimumSystemVersion` is 13.0.
  - `entitlements.plist` holds only `network.client`.
- **Windows backend** builds with the MinGW ABI (`x86_64-windows-gnu`, `build.zig:250`).
  - Zig 0.16.0's bundled MinGW has `sapi.h`, `roapi.h` and `winstring.h`.
  - It has **no** `windows.media.speechsynthesis.h`. That only matters for the later
    system-voice slice.
- **Pocket TTS** (research, checked 2026-10-19):
  - Licenses: MIT code; **CC-BY-4.0** weights (the Hugging Face license tag).
  - Access: the main repo is gated (the gate text could not be read).
  - Size: the bf16 file is 236 MB; an int8 ONNX build is about 100 MB (unverified).
  - Speed: about 6x real time on 2 M4 cores; about 200 ms to first audio.
  - Voices and languages: 26 built-in voices; 6-7 languages.
  - Cloning: from a WAV file.
  - Runtime: **no official C or ONNX runtime**. Community ONNX exports and a C++ ONNX Runtime
    port (PocketTTS.cpp, license unread) exist.
  - sherpa-onnx runs it, but its TTS build vendors GPL espeak-ng.
- **Linux dev machine:** speech-dispatcher, `libspeechd.so.2`, PulseAudio, PipeWire, `parec`
  and `pactl` are installed. `libspeechd-dev` is not.

### 2.2 Dependencies outside this plan

| Platform | What spoken replies need | Where it is planned | Status |
|---|---|---|---|
| Linux | the GTK drawer and helper | drawer plan S1-S5 | built (S5b accepted) |
| macOS | the AppKit drawer | macOS plan **MS7** | not built |
| macOS | the helper on macOS | macOS plan **MS8**, blocked on **MS6** (Seatbelt) or the VM backend | not built |
| macOS | the sandbox for `zb-speech` | macOS plan **MS0** contract + **MS6** Seatbelt backend | MS0 planned, MS6 not built |
| macOS | the universal two-arch build and gate | macOS plan **MS1** | green on both Macs |
| Windows | the Windows drawer, and its speech hook points | Windows launch plan **WS5** (Win32 drawer) and **WS12.1** (`zb_drawer_speaker_toggled`, the `DRAWER speaker` rows) (`thoughts/searchable/shared/plans/2026-10-19-windows-launch-tdd-plan.md`) | not built |
| Windows | the helper and chat on Windows (the frame pump) | Windows launch plan **WS11** (needs WS7 setup, WS8 sandbox, WS9 egress, WS10 sign-in) | not built |
| Windows | a sandbox for `zb-speech` on Windows | Windows launch plan **WS8**, specifically **WS8.7** (a no-network child with read-only access to its model directory); its technology is that plan's OD-W4 | not built; OD-W4 open |
| Windows | test hosts, the gate and the build | Windows launch plan **WS0** (hosts, `tests/windows/gate.sh`, the voice phase in **WS12.2**) and **WS1** (`build-on-windows.sh`, `-Dtarget=x86_64-windows-msvc` on the VM). Hosts: the Win11 VM `win11-m8` and the physical Windows 10 machine (`100.123.34.15`, `file-server-win-mac`, run-only) | being provisioned (WS0) |
| Installer | the TTS model and ONNX Runtime in the installer | Windows: launch plan **WS13** (WS13.1 census, WS13.3 size budget; slot `models\tts\`); Linux and macOS: the distribution plan (`2026-06-03-08-26-ENG-0007-…`) | this plan adds the files (V3.5) |

Summary:
- **Can be finished now on Linux:** the speech core, the test backend, the audio layer, the
  bundled engine, the drawer controls and the Voice window.
- **Can be tested on both Macs now:** the bundled engine (render to file and play through Core
  Audio), without the drawer.
- **Waits for MS7 and MS8:** spoken replies on macOS.
- **Windows:** the engine and audio layer cross-compile from Linux now (W0). Running them waits
  for WS0's hosts and WS8.7 (W1). Spoken replies wait for WS5, WS11 and WS12.1 (W2). Cloning
  on Windows waits for W2 and a capture path (CW).

### 2.3 Shared with the speech-to-text plan

Named the same in both plans. Whichever plan builds a piece first owns it; the other consumes
it.

| Piece | What it is | This plan's use | The STT plan's use |
|---|---|---|---|
| **`zb_audio`** | miniaudio (public domain or MIT-0) on Core Audio, WASAPI and PulseAudio | playback (V2) | capture; cloning enrolment uses capture too |
| **The Voice window** | one native window, opened from the drawer header | the **Read aloud** section (V5) | the **Dictation** section |
| **`<profile>/voice.json`** | the settings store | the `read_aloud` object | the `dictation` object |
| **macOS prompts and usage strings** | added only when a signed Mac build proves a key is needed | Personal Voice authorization (S4) | the microphone (`NSMicrophoneUsageDescription`, `com.apple.security.device.audio-input`); cloning enrolment uses it too |
| **The model manager (`zb_models`)** | a pinned SHA-256 per file; the bundled-model install location; optional downloads | the Pocket TTS files, bundled | whisper medium, bundled |
| **ONNX Runtime** | the inference library | the bundled engine | — |
| **The audio test rule** | section 7.3 | yes | yes |

- **`voice.json`:** each plan validates only its own object and keeps the other's bytes
  unchanged.
- **ONNX Runtime:** if the STT plan ever uses an ONNX model, it should share this copy.
  whisper.cpp does not need it.

## 3. Design

### D1. Speech runs in the browser process, beside the drawer, never in the helper

- The feed is called from `on_frame` in `agent_helper.c`, right beside the drawer calls, so
  the `stopping` rule applies to both.
- On macOS, MS8's frame pump calls the same functions, and on Windows so does the Windows
  launch plan's pump.
- No web view is added and Web Speech is not used: drawer plan D1 forbids web content in the
  drawer, and Web Speech gives no stop, routing or PCM control.

### D2. The feed API (C exports from Zig)

```c
/* src/speech.h — all calls on the main thread */
void zb_speech_reply_delta(unsigned int win, const char *text, size_t len);   /* a delta frame */
void zb_speech_reply_message(unsigned int win, const char *text, size_t len); /* a bubble is whole */
void zb_speech_reply_end(unsigned int win, int reason);  /* result, error, stopped, crash, detach */
void zb_speech_speak_text(unsigned int win, const char *text, size_t len);    /* a bubble's Speak button */
void zb_speech_stop(unsigned int win);       /* win 0: everything */
void zb_speech_set_muted(int muted);         /* the always-visible mute */
int  zb_speech_is_speaking(unsigned int win);
```

- **`reply_delta`** feeds the chunker when automatic reading is on, the app is not muted, and
  no screen reader pause is active.
- **`reply_message`** flushes the chunker. If the message does not start with the text fed so
  far (for example, it was truncated), only the part after the common prefix is spoken.
- **`reply_end`** with `stopped`, `crash` or `detach` stops that window's speech. With
  `result` or `error` it only flushes, so speech already queued finishes.
- **`set_muted(1)`** stops all speech and stops new automatic reading. It does not change the
  automatic-reading setting, so unmuting resumes reading of the next reply.

### D3. The speech core (portable Zig, pure, tested on Linux)

| Module | What it does |
|---|---|
| `src/speech_text.zig` | Markdown to speakable text, streaming-safe. See the clean-up rules below. |
| `src/speech_chunker.zig` | Sentence chunking over deltas. See the chunking rules below. |
| `src/speech_queue.zig` | One speaker for the whole app. See the queue rules below. |
| `src/voice_settings.zig` | `voice.json`'s `read_aloud` object: `auto_read` (default **true**), `muted` (default false), `first_run_notice_shown`, `voice`, `rate`, `pitch`, `volume`, `code_policy` (default **`announce_skip`**, see OD5), `pause_for_screen_reader` (default **true**). Load, validate, clamp, save atomically. Unknown keys and the `dictation` object are kept byte-for-byte. |
| `src/speech_params.zig` | Pure mappings from normalized rate (0.5-2.0), pitch (0.5-2.0) and volume (0-1) to each backend's scale (see below). |

**Clean-up rules (`speech_text.zig`).**
- Fenced code blocks follow the code policy. They are **not read by default**.
- Inline code is read without its backticks.
- `[text](url)` reads "text", and a bare URL reads "link".
- Emphasis, heading marks, list bullets and table pipes are removed. A table becomes
  "Table.".
- Emoji are dropped.
- The fence state carries across deltas.

**Chunking rules (`speech_chunker.zig`).**
- A chunk ends at `.`, `!`, `?` or `…`, at a colon before a newline, or at a blank line.
- It does not end after a known abbreviation, inside a number or version, or inside a URL.
- The first chunk is at least 12 characters, and later chunks at least 40.
- A chunk is at most 280 characters; a longer one is cut at the last comma, semicolon or space.

**Queue rules (`speech_queue.zig`).**
- Each utterance has an id, a window and an epoch.
- `stop(win)` bumps that window's epoch, and events for an older epoch are ignored.
- At most two utterances are handed to the backend ahead.
- A newer reply or Speak press in another window stops the current one.

**Parameter mappings (`speech_params.zig`).**
- The engine scales Pocket TTS's speed through its time-stretch or step control, and volume as
  PCM gain. Pitch is applied only if the engine exposes it; otherwise the slider is hidden for
  that voice (see V3.4).
- The secondary system backends get their own mappings later: AVSpeech, WinRT, SAPI and
  speech-dispatcher.

### D4. The backend contract

```c
/* src/speech_backend.h */
typedef struct {
  const char *name;                                    /* "record", "engine", later "spd", "avspeech", "winrt", "sapi" */
  int  (*open)(char *reason, size_t cap);              /* 0 ok; else unavailable + reason */
  void (*list_voices)(void (*each)(const char *id, const char *name, const char *lang,
                                   const char *kind /* builtin, cloned, personal, system */,
                                   void *ctx), void *ctx);
  unsigned (*caps)(void);                              /* rate, pitch, volume, cloning */
  int  (*speak)(unsigned int utt, const char *text, size_t len, const ZbSpeechParams *p);
  void (*stop)(void);                                  /* cancel current and handed-ahead utterances */
  void (*close)(void);
} ZbSpeechBackend;

void zb_speech_event(unsigned int utt, int kind /* started, done, cancelled, failed */); /* posts to the main loop */
```

**Choosing the backend.**
- The backend is chosen by `--speech-backend auto|engine|system|off`, or the env variable
  `ZIGBROWSER_SPEECH_BACKEND`, through `env_switch`.
- **`auto` = `engine`** (decided 2). Before S1-S3 land, `system` is refused with "system
  voices are not built yet".
- `record` is accepted only with `--e2e-protocol`.

**A backend that fails to open.** The drawer shows "Speech unavailable (<reason>)". Nothing
crashes, and a reply still shows as text.

### D5. Drawer controls under "on by default" (Linux V4; AppKit M2; Windows W2)

- **The mute and stop control** sits in the drawer header and is **always visible** while the
  drawer is open, in every agent state, including "Speech unavailable". It is never greyed out
  by the agent state. It has three states:
  - **Reading on** (speaker icon). Accessible name: "Mute read-aloud".
  - **Speaking** ("Stop speaking"). A click stops speech now. Automatic reading stays on for
    the next reply.
  - **Muted** (crossed speaker). Accessible name: "Unmute read-aloud". `muted` is saved.

  A long press, or the context menu, offers "Turn off automatic reading". That also turns it
  off in the Voice window.
- **While the drawer is minimized and speech plays**, a small **stop badge** appears beside
  the floating "S" icon. It is a separate float with exact hit-testing, painted into the page's
  window like the other floats (drawer plan D1, D3 and §7.1 census rules). A click stops
  speech. The badge disappears when speech ends.
- **First-run notice.** The first time a reply is spoken in a profile, a system line appears in
  the conversation: "Replies are read aloud. Use the speaker button to mute, or turn it off in
  Voice settings." It is shown once (`first_run_notice_shown`).
- **Each assistant bubble has a Speak button.** While its bubble is being spoken it reads
  "Stop".
- **Decided by this plan (section 6.2):**
  - the agent's **Stop** also stops that window's speech;
  - **Send** stops speech before the new prompt goes out;
  - a reply in another window stops the current one.
- **Shortcut:** Ctrl+Shift+S stops speech when the drawer has focus.
- **Screen reader pause** (decided, section 6.2). While a screen reader is active, automatic
  reading pauses. A status line says "Read-aloud paused while a screen reader is on". Speak
  buttons still work.

  Detection:
  - Linux: Orca, through the AT-SPI `org.a11y.Status` `ScreenReaderEnabled` property, read
    through `org.a11y.Bus` on the session bus.
  - macOS: `NSWorkspace.isVoiceOverEnabled`.
  - Windows: `SPI_GETSCREENREADER`.

  These signals are unverified in research, so each platform slice proves its own signal.
- **A Voice button** opens the Voice window.
- **All text stays inert.** No markup is ever set from model text.

### D6. The Voice window (V5; shared with the STT plan)

- A separate native window, like the Secrets window.
- **Read aloud section:**
  - automatic reading (on by default);
  - the voice list: name and language, with built-in, "Your voice" and later "System" groups;
  - rate, pitch (hidden when the voice cannot do it) and volume;
  - the code-block policy;
  - "Pause while a screen reader is on";
  - **Preview** and **Reset to defaults**;
  - **About this voice**: the model's license and attribution, which CC BY 4.0 requires.
- A change applies to the next utterance and is saved at once.
- The cloning controls (C1-C3) live here.

### D7. Rows (`--e2e-protocol` only)

These are added to the D7b row table and to `parse_row`. Text fields are capped like `delta`
rows.

| Row | When |
|---|---|
| `SPEECH\t<win>\tqueued\t<utt>\t<text>` | a chunk enters the queue |
| `SPEECH\t<win>\tstart\t<utt>\t<backend>\t<voice>\t<rate>\t<pitch>\t<volume>` | the backend reports started |
| `SPEECH\t<win>\tend\t<utt>\t<done\|cancelled\|failed>` | the backend reports the end |
| `SPEECH\t<win>\tstate\t<idle\|speaking>` | the window's speaking state changes |
| `SPEECH\t0\tbackend\t<name>\t<ok\|unavailable>\t<reason>` | at startup and on a change |
| `SPEECH\t0\tpause\t<screen-reader\|muted\|none>` | the reason automatic reading is held changes |
| `DRAWER\t<win>\tspeaker\t<on\|speaking\|muted>\t<rect>` | the header control is drawn or changes |
| `DRAWER\t<win>\tspeakbadge\t<shown\|hidden>\t<rect>` | the minimized stop badge appears or goes |
| `DRAWER\t<win>\tspeak\t<bubble>\t<idle\|speaking>\t<rect>` | a bubble's Speak button is drawn or changes |
| `DRAWER\t<win>\tmsg\tsystem\t<text>` | (existing row) carries the first-run notice |
| `VOICE\ttree\t<type names>` | the Voice window is built |
| `VOICE\tsetting\t<key>\t<value>` | a setting is saved |
| `VOICE\tclone\t<consent\|recording\|processing\|ready\|deleted\|refused>\t<reason>` | the cloning state changes |

### D8. The record backend (tests only)

- **How it is turned on.** Set `ZIGBROWSER_SPEECH_BACKEND=record` and
  `ZIGBROWSER_SPEECH_RECORD=<dir>`. These are honored only with `--e2e-protocol`. Without it
  the app prints `zigBrowser: ZIGBROWSER_SPEECH_RECORD ignored without --e2e-protocol`.
- **What it does.**
  - It "speaks" for `ZIGBROWSER_SPEECH_RECORD_MS_PER_CHAR` ms per character (1-200, default
    20) on main-loop timers.
  - It appends one JSON line per utterance to `<dir>/utterances.jsonl`.
  - It reports events like a real backend.
  - It replaces only the engine plus the device, the system boundary.

### D9. The bundled engine process `zb-speech` (V3; primary, decided 2)

**The process.**
- A separate executable, started by the browser on the first utterance and kept warm for 5
  minutes after the last one.
- It runs **Pocket TTS** (DECIDED 4) on the **ONNX Runtime C API**
  (MIT).
- It streams 16-bit PCM frames over a pipe with a small framed protocol: `hello`, `voice`,
  `speak <utt>`, `cancel <utt>`, and `pcm <utt> <n>` / `done <utt>` / `error` back.
- The browser plays the PCM through `zb_audio`, so first audio comes after the first frame,
  not the whole sentence.

**The model path (OD2).** The recommended path is to **export ONNX ourselves** from the MIT
PyTorch code, using the community exports as references. A script
`tools/export_pocket_onnx.py` runs once on a developer machine; the exported files are pinned
by SHA-256 in the model manifest. The process then calls ONNX Runtime directly.
Alternatives:
- PocketTTS.cpp, a C++ ONNX Runtime runtime with a C FFI. Its license must be read first.
- sherpa-onnx's C API. Its TTS build vendors GPL espeak-ng unless the build is patched.

**The sandbox**, through the shared `SandboxBackend` contract:
- **no network**;
- read-only access to the model directory and, for a call that needs it, to that one cloned
  voice's embedding;
- write access only to its own scratch directory;
- no audio devices, because the browser plays the audio.

It dies with the browser. On macOS it uses the MS6 Seatbelt backend. On Windows it uses what
the Windows launch plan provides.

**A crash** gives `failed` for the current utterance and a restart on the next one, with the
same 1/2/4/8 s backoff pattern as the helper.

### D10. Cloning (C1-C3; decided 1)

- **Sources.** Live microphone only, recorded inside the Voice window through `zb_audio`
  capture. No file picker (OD9), no page audio, no media element, no tab capture.
- **Consent.** A consent screen first. The user ticks an attestation and presses Continue.
  The first sample is a random consent sentence (it includes the date) that the user reads
  aloud.
- **Storage.** `voices/<id>/` under the profile's data directory, mode 0700 with 0600 files.
  It holds the samples, the speaker state the engine derives, and `consent.json` (the date,
  the attestation version, the consent sentence, and the engine and model versions). Never
  under the agent home.
- **No sharing.** No export, no automation method, no agent tool, and no page API reaches
  `voices/`.
- **Engine.** Pocket TTS, the same bundled engine (it clones from a WAV; follows from
  DECIDED 4). Pocket TTS mentions no watermark. If OD3 is ever reopened for a watermarking
  engine, the watermark stays on.
- **Delete** removes everything and stops any utterance using the voice.
- **macOS Personal Voice** is a later extra (S4): Apple's flow, and the app stores nothing.

## 4. Desired end state and observable behaviors

- **In a new profile, replies are spoken automatically.** The first spoken reply shows the
  first-run notice. The mute and stop control is in view the whole time.
- **Every way to stop works.** These each silence speech within 200 ms, and no queued
  sentence plays afterwards:
  - mute;
  - "Stop speaking";
  - the minimized stop badge;
  - the bubble's Stop;
  - the agent's Stop;
  - Send;
  - closing the window;
  - a helper crash;
  - a screen reader starting.
- **Every platform sounds the same:** the bundled engine's voice, working offline from the
  first launch, because the model is in the installer.
- **Clean-up:** code blocks are not read by default, links read their text, and markdown marks
  are not spoken.
- **Settings:** the user picks a voice, rate, pitch and volume. Preview uses them, the next
  reply uses them, and they persist.
- **Cloning:** the user can create, use and delete a clone of their own voice, after consent,
  on every platform.
- **Later:** system voices are offered as a secondary choice, and so is Personal Voice on
  macOS.

## 5. What we are NOT doing

- No web `speechSynthesis`, no hidden web view, no reading of web pages aloud.
- No speech inside the agent helper or its sandbox, and no audio device in any sandbox.
- No cloud TTS (OD4 recommends against it; if the user allows it, it is a separate slice).
- No cloning from web audio, no export or sharing of voices, no third-party voices.
- No Narrator "natural" voices through the community SAPI bridge.
- No Windows drawer, helper or test-host work. The Windows launch plan owns them.
- No SSML from model text.
- Nothing on the STT side beyond the shared pieces in section 2.3.

## 6. Decisions

### 6.1 Decided by the user (2026-10-19)

| # | Decision | Where it lands |
|---|---|---|
| 1 | Voice cloning allowed for personal use (consent, local only, no export, no web audio, redistributable engine only) | D10, C1-C3, CW, S4 |
| 2 | Bundled engine first; system voices later and secondary | D4 (`auto` = engine), D9, V3, M1, W1; S1-S3 at the end |
| 3 | Read-aloud on by default | D3 defaults, D5, V4 |
| 4 | Pocket TTS is the voice engine; it is also the cloning engine (follows from the choice) | D9, D10, V3, C1-C3; gate terms (OD7) and runtime path (OD2) stay open |
| — | STT bundles whisper medium (installer about 0.8 GB larger) | 6.2 model delivery |
| — | Windows is a main target; the Windows launch plan (WS0-WS13) covers drawer, helper, sandbox, voice hooks, installer and hosts | 2.2, W0-W2, CW |

### 6.2 Decided by this plan (follow from the user's decisions; the user may override)

- **The TTS model is bundled in the installer, not downloaded.**
  - The installer already carries whisper medium (about 0.8 GB).
  - The Pocket TTS int8 ONNX files are about 100 MB (unverified), and ONNX Runtime is roughly
    10-30 MB per platform (unverified). That is about 0.1-0.13 GB more.
  - Because read-aloud is on by default and the engine is the primary voice, the first reply
    after install must be spoken offline. A download would leave the default feature silent.
  - The model manager still handles updates and optional extra languages.
  - If the measured int8 total exceeds 200 MB, this choice comes back to the user before V3.5
    ships.
- **Stop and Send stop speech.** With reading on by default, a user who sends a new prompt or
  stops the agent should not keep hearing the old reply.
- **One voice at a time.** A reply in another window stops the current one.
- **Automatic reading pauses while a screen reader is active.** With reading on by default,
  screen-reader users would otherwise hear two voices at once. Speak buttons still work. A
  setting allows turning the pause off.
- **Code blocks are not read by default.** Whether they are announced is OD5.
- **Speech continues while the drawer is minimized** (with the stop badge), and stops when the
  window closes.

### 6.3 Open decisions for the user

Each item has a recommended option. Nothing here is decided by this plan.

**OD1. Which bundled engine — DECIDED 2026-10-19: Pocket TTS** (DECIDED 4). Kept here only as
the record of the comparison.
- **Pocket TTS** (chosen).
  - Licenses: MIT code; **CC-BY-4.0** weights. You must give credit, link the license and
    note changes such as an ONNX or int8 conversion.
  - Access: the main repo is gated. **Its gate text is unverified.** It might add terms; read
    it before shipping.
  - Policy: a use policy bans cloning without consent.
  - Size and speed: about 100M parameters and 236 MB bf16 (about 100 MB int8, unverified).
    About 6x real time on 2 M4 cores and about 200 ms to first audio.
  - Voices: 26 built-in voices, 6-7 languages.
  - **It also clones, so one engine covers default voices and cloning.**
- **Kokoro-82M.** Apache-2.0, a strong quality reputation, 54 voices. It has **no cloning**,
  and it needs espeak-ng (GPL) beyond English.
- **Supertonic 3.** OpenRAIL-M, no phonemizer, 31 languages. **No cloning**, and the repo is
  archived.
- **Chatterbox.** MIT, watermarked, clones. It is Python-first, with ONNX exports, and
  110M-500M parameters.
- **Chosen: Pocket TTS.** Its gate terms must still be read (OD7). If those terms forbid
  redistribution, the choice goes back to the user; the fallback would be Kokoro for built-in
  voices plus Chatterbox for cloning.

**OD2. How to run Pocket TTS from Zig.**
- (a) Our own ONNX export plus the ONNX Runtime C API (recommended: the fewest unknown
  licenses, and the same on macOS arm64/x86_64 and Windows x64/arm64).
- (b) PocketTTS.cpp's C FFI. Read its license first.
- (c) sherpa-onnx's C API. It vendors GPL espeak-ng unless patched.

**OD3. Cloning engine — follows from DECIDED 4: Pocket TTS.** It reopens only if the gate
terms forbid redistributing the cloning part, or if the user wants a watermark on every cloned
output (Chatterbox has one; Pocket TTS mentions none).

**OD4. Cloud TTS.** **Recommended: no.**

**OD5. Code blocks.** They are not read by default (decided). Should they be announced
("Code block.") or skipped silently? **Recommended: announce**, so the listener knows
something was skipped.

**OD6. System voices as a secondary option** (S1-S3).
- Ship them at all? **Recommended: yes, after W2.**
- Which first? **Recommended: macOS first** (Premium voices are good), then Windows WinRT, and
  Linux speech-dispatcher only as a developer tool.

**OD7. Legal review before shipping V3.5.**
- Pocket TTS's Hugging Face gate terms.
- The CC BY 4.0 attribution text and where it shows (About this voice and the app's
  licenses file).
- espeak-ng only if OD2 (c) is chosen.
- Apple's "personal, noncommercial use" wording for Personal Voice (S4).
- **Recommended: yes, before V3.5 ships.** Nothing earlier needs it.

**OD8. Windows arm64.** Build it from the start or after x64? **Recommended: x64 first** (the
Windows launch plan's hosts are x64), then arm64.

**OD9. Importing a recording for cloning.** **Recommended: live recording only** in the first
version.

## 7. Testing strategy

### 7.1 Frameworks and steps

- **Zig unit and property tests** (Tier 2) live in `tests/speech_*_test.zig` and
  `tests/voice_settings_test.zig`, under the gate step `speech-core-test`. They are registered
  like `tests/agent_drawer_test.zig` (`build.zig:336-350`). Property tests use a seeded
  `std.Random.DefaultPrng` loop.
- **E2e closure tests** (Tier 1) live in `tests/e2e/speech_*_test.py`,
  `tests/e2e/agent_drawer_speech_test.py` and `tests/e2e/voice_window_test.py`.
  - They run under `xsession.py --xvfb` and are registered like `agent-chat-e2e`
    (`build.zig:819-827`).
  - They reuse `agent_host_lifecycle_test.py`'s world, `fake_host.py` and
    `fake_anthropic_api.py`.
- **Engine tests** use the real `zb-speech` with the real model files from the developer
  cache (`ZB_SPEECH_MODEL_DIR`, filled by `tools/speech_model_env.sh` from the pinned
  manifest). If the files are missing, the test **exits 1** with "run
  tools/speech_model_env.sh". It never skips to green.
- **Mac tests** run on both remote Macs through `tests/mac/build-on-mac.sh` and
  `tests/mac/gate.sh` (step `speech-mac-e2e`). The gate fails closed when `ZB_MAC_ARM_HOST`
  is unset.
- **Windows tests** run on `win11-m8` and the physical Windows 10 machine through the Windows
  launch plan's gate, `tests/windows/gate.sh --phase voice` (WS12.2), which fails closed: a host
  that is down or not provisioned fails the gate, and a missing capture device reports
  `NOT RUN: no capture device` and fails it. They are never green by default.

### 7.2 What is mocked

- Only true system boundaries are mocked:
  - the Anthropic API (`fake_anthropic_api.py`);
  - the helper's output (`fake_host.py`, upstream of the first changed node);
  - in the `record` backend, the engine plus the audio device;
  - in the model fetch test, the model host (a local HTTPS fixture).
- Every record-backend closure has a sibling closure through the **real engine** into a
  private null sink (Linux), a rendered file and Core Audio's muted output (Macs), or the
  Windows hosts.

### 7.3 The audio rule: tests never use the real speakers

**Linux.** Each speech e2e starts with a private `XDG_RUNTIME_DIR` and a dead D-Bus address.
- Real-audio tests start a private PulseAudio in that directory:
  `pulseaudio -n --daemonize=no --exit-idle-time=-1 -L module-native-protocol-unix -L
  module-null-sink sink_name=zbtest -L module-always-sink`.
- The test sets `PULSE_SERVER` to it and records `zbtest.monitor` with `parec`.
- `tests/e2e/audio_common.py` builds this world, and **refuses** with exit 1 if any variable
  would reach the user's session. `audio_common_test.py` proves the refusal.

**Macs.** Tests render to a file, or play with the remote Mac's output muted (the old state is
restored after).

**Windows hosts.** Tests play to a WASAPI device in a muted session, or to miniaudio's null
backend. The WS0 runner sets this up. The Windows 10 machine is also a file server, so tests
there obey the Windows plan's file-server isolation rules (its section on them, and WS0.5,
WS0.7). Microphone settings change only for the test user `zbtest`, never machine-wide.

**The screen-reader tests** start a private AT-SPI bus and set `ScreenReaderEnabled` on it.
They never start the user's Orca.

### 7.4 Real-screen and real-audio checks (orchestrator only, with the user)

**Real-screen.** Each UI slice adds a case to `tests/manual/real_screen_check.py` (drawer plan
§7.1, `--confirm-user-permission`).

| Case | Slice | What the user's screen must show |
|---|---|---|
| `drawer-speech-default` | V4 | a fresh profile with the drawer open: the speaker control in its "on" state (captured twice a second apart); after a scripted reply, the first-run notice line and the control in "Stop speaking"; after a guarded click, the control back to "on" |
| `drawer-speech-muted` | V4 | the control in "muted" after a guarded click, and no speaking state on the next reply |
| `drawer-speech-minimized` | V4 | the drawer minimized while speaking: the "S" icon plus the stop badge beside it; after a guarded click on the badge, the badge gone |
| `drawer-speech-bubble` | V4 | a bubble's Speak button, then its Stop state |
| `drawer-speech-screen-reader` | V4 | the pause status line, drawn while a private AT-SPI bus reports a screen reader. The user's Orca is never started. The case is optional and runs only with the user's consent |
| `voice-window` | V5 | the window with the voice list, sliders and About this voice; Preview pressed through the guarded input |
| `voice-clone-consent`, `voice-clone-ready` | C1, C3 | the consent screen with Record disabled, then enabled; the "Your voice" entry and Delete |
| `mac-drawer-speech-default`, `mac-drawer-speech-minimized`, `mac-voice-window` | M2 | the same cases on the user's Mac |
| `mac-personal-voice` | S4 | the Personal Voice button, the denied guidance, and the authorized voice |
| `win-drawer-speech-default`, `win-drawer-speech-minimized`, `win-voice-window` | W2 | on both Windows hosts (the VM console and the Windows 10 monitor) with the user, through the Windows plan's real-screen runner (WS5, WS12) |
| `win-voice-clone-consent`, `win-voice-clone-ready` | CW | on the physical Windows 10 machine (it has the microphone) with the user; on `win11-m8` only once its capture device is proven (the Windows plan's provisioning item 12) |

**Real-audio.** `tests/manual/real_audio_check.py --confirm-user-permission` speaks one fixed
sentence through the user's default output device with:
- the bundled engine at default settings;
- the bundled engine at rate 1.5;
- the user's cloned voice, if one exists;
- the system voices, once built.

It asks the user y/n per line and refuses without a terminal. Agents check it only with
`--dry-run` (no device opened) in `tests/manual/test_real_audio_check.py`.

### 7.5 Where each slice can be built and tested

| Slice | Build | Automated tests | Needs |
|---|---|---|---|
| V0 core | Linux | Linux | nothing |
| V1 record backend + reply feed | Linux | Linux (Xvfb) | nothing |
| V2 `zb_audio` playback | Linux; cross-compiles for Mac and Windows | Linux (private Pulse); Macs (muted) | nothing; Macs for Core Audio |
| V3 bundled engine `zb-speech` | Linux | Linux (private Pulse, real model) | OD2; OD7 before V3.5 ships |
| V4 drawer controls (UI) | Linux | Linux (Xvfb, private AT-SPI) + real-screen | the user for the check |
| V5 Voice window (UI) | Linux | Linux (Xvfb) + real-screen | the user for the check |
| M1 bundled engine on macOS | **Mac** | **both Macs** | MS1 (done); MS6 for M1.3 |
| C1-C3 cloning (UI) | Linux first, then Macs | Linux (Xvfb, private Pulse with a fixture as the microphone); both Macs | V3, a capture path in `zb_audio` (the STT plan's or added here), the user for the checks |
| M2 Mac drawer speech + Voice window (UI) | **Mac** | both Macs + real-screen + real-audio on the user's Mac | **MS7, MS8** |
| W0 Windows engine + audio, compile only | Linux (cross-compile) | compile and link checks | nothing |
| W1 Windows engine + audio at run time | Windows (built on `win11-m8`, WS1) | `win11-m8` and the physical Windows 10 machine (WS0) | WS0, WS1, WS8.7, WS13 |
| W2 Windows drawer speech (UI) | Windows | both hosts + real-screen + real-audio with the user | WS5, WS11, WS12.1 |
| CW Windows cloning (UI) | Windows | both hosts with the WAV fixture seam; live microphone on the Windows 10 machine | W2, C1-C3, a WASAPI capture path (STT VS10's, or added here), WS8.7 |
| S1 Linux speech-dispatcher (secondary) | Linux | Linux (private Pulse) | OD6 |
| S2 macOS AVSpeechSynthesizer (secondary) | Mac | both Macs | OD6 |
| S3 Windows WinRT + SAPI (secondary) | Windows (compile from Linux with SDK headers) | the Windows hosts | OD6, the SDK `winrt` headers |
| S4 macOS Personal Voice (UI, cloning extra) | Mac | both Macs (status paths); creation needs **Apple Silicon** and the user | S2 |

## 8. Workflow closure

- **BLOCKING:** every behavior that reaches a `SPEECH` row or audio through the frame stream.
  The chain crosses the helper's process boundary, the main-loop queue, the engine process's
  pipe and the audio callback thread.
- **LEAF:** the pure core behaviors in V0 (single Zig module, no async, no registration).

### 8.1 Production operation chain (from the research `Workflow Closure Map`)

`user Send (drawer) -> helper prompt -> SDK stream -> assistant_delta frames on stdout ->
on_read / on_frame (agent_helper.c) -> zb_speech_reply_delta (NEW) -> speech_text +
speech_chunker (NEW) -> speech_queue pump (NEW, main loop) -> engine backend (NEW) -> zb-speech
process (NEW, pipe) -> PCM -> zb_audio (NEW, device thread) -> zb_speech_event (NEW, posted to
main loop) -> SPEECH rows + audio at the sink`

`highest_new_connector` = `on_frame` in `src/agent_helper.c`. A closure test may start at the
helper's stdout (`fake_host.py`) or further out, never below `on_frame`.

### Closure A: a streamed reply is spoken while it arrives, by default   [BLOCKING]
- **SOURCE (seed only):** an **empty profile** (so the defaults apply) plus the scripted frames
  of `fake_host.py`: deltas split mid-word and mid-fence, then the message, then `result`. A
  real-helper variant uses `fake_anthropic_api.py`.
- **TRIGGER:** a real X click on Send after typing with `xinput.py` (`send_input`,
  `agent_drawer.c:893`). Boundary: the outermost one.
- **DRIVERS:** the browser's own main loop (`on_read`, the new `zb_speech_pump` idle, and the
  backend's events). The test waits on rows with deadlines.
- **OBSERVE:** `SPEECH queued/start/end` rows, the first-run notice row, and either
  `utterances.jsonl` (record) or RMS at the null sink (engine).
- **FORBIDDEN SPAN:** `on_frame`, `zb_speech_*`, the core modules, the backend, `zb-speech`
  and `zb_audio`.
- **RED-AT-SEAM:**
  - remove the feed call from `on_frame`: no `queued` row before `msg`;
  - make `auto_read` default false: nothing is spoken in the empty profile;
  - remove the pump registration: `queued` rows appear but no `start`.
- **EXECUTION:** needs Xvfb, xauth, bwrap, the helper venv and (for the engine variant) the
  model cache. If any is missing the test exits 1.

### Closure B: every stop control silences speech at once   [BLOCKING]
- **SOURCE:** six sentences that stall after the fourth; the record backend at 60 ms per
  character; and the engine variant.
- **TRIGGER:** one case per control, each a real X click or key press:
  - mute;
  - "Stop speaking";
  - the minimized badge;
  - the bubble's Stop;
  - the agent's Stop;
  - Send;
  - Ctrl+Shift+S;
  - closing the window.
- **OBSERVE:**
  - `SPEECH end … cancelled` within 200 ms of the input row (engine variant: null-sink RMS
    below the threshold within 250 ms);
  - `state idle`;
  - for 2 s, no further `start` for that window;
  - after mute, the next reply gives `pause muted` and no `queued`.
- **RED-AT-SEAM:**
  - drop `zb_speech_stop` from `on_stop_clicked`: the next sentence starts;
  - drop the epoch check: a late `started` event gives a `start` row;
  - drop the engine's `cancel`: RMS persists past 250 ms.

### Closure C: a saved setting reaches the next utterance and survives a restart   [BLOCKING]
- **TRIGGER:** real X input in the Voice window: a voice, rate 1.5, then Preview.
- **OBSERVE:** the `VOICE setting` rows, and the Preview's `start` row. After a restart, a
  reply's `start` row carries the same values.
- **RED-AT-SEAM:** skip reloading settings in the queue, and the restart case shows the
  defaults.

### Closure D: the bundled engine reaches an audio device   [BLOCKING]
- **Linux (V3):** with the real `zb-speech` and the real model:
  - the null sink's monitor has RMS above the threshold between `start` and `end`;
  - first audio comes within the budget (V3.3);
  - a connect from inside `zb-speech` to `1.1.1.1:443` fails.
- **Macs (M1):** the same engine renders to a WAV file with audio. With output muted, Core
  Audio playback runs and ends with `done`.
- **Windows (W1):** the same on the Windows hosts.
- **RED-AT-SEAM:** a mutant engine that says `done` without sending PCM fails the RMS or WAV
  check.

### Closure E: enrol, speak with, and delete my voice   [BLOCKING]
- **SOURCE:** a fixture recording of a consenting test speaker, fed as the private
  PulseAudio's microphone source (`module-pipe-source`), so real capture runs.
- **TRIGGER:** real X input through the consent screen, Record and Finish.
- **OBSERVE:**
  - `VOICE clone ready`;
  - "Your voice" in the list;
  - a Preview `start` with that voice, and RMS at the sink;
  - after Delete: `VOICE clone deleted`, the directory gone, and the list without it.
- **RED-AT-SEAM:** skip the consent gate, and the row order consent → recording breaks.

### Closure F: a screen reader pauses automatic reading   [BLOCKING: AT-SPI bus → app → queue]
- **SOURCE:** a private AT-SPI bus (`at-spi-bus-launcher` on a private session bus) with
  `ScreenReaderEnabled` false.
- **TRIGGER:** set `ScreenReaderEnabled` true on that bus while a reply streams.
- **OBSERVE:** `SPEECH 0 pause screen-reader`, `end cancelled` for the speaking utterance, no
  `queued` for the next reply, and the status line row. Then set it false, and the next reply
  is spoken.
- **RED-AT-SEAM:** do not subscribe to the property change, and speech continues.

## 9. Slices

**Order:**
1. Linux: `V0 → V1 → V2 → V3 → V4 → V5`.
2. macOS: `M1` (after V3 and MS1; M1.3 after MS6).
3. Cloning: `C1 → C2 → C3` (after V3 and a capture path).
4. macOS drawer: `M2` (after V4, V5, **MS7 and MS8**).
5. Windows: `W0` (after V3, any time); then `W1` (after WS0, WS1, WS8.7, WS13); then `W2`
   (after WS5, WS11, WS12.1); then `CW` (after W2 and C1-C3).
6. Secondary system voices, last: `S1`, `S2`, `S3`, then `S4` (after S2).

Every behavior follows the per-slice gate protocol (section 11).

---

### V0 — The speech core (Linux; no UI; LEAF)

#### Behavior V0.1: markdown becomes speakable text, and code is not read by default
- **Given** reply text with:
  - a fenced code block;
  - inline code;
  - a link;
  - bold text;
  - a heading;
  - a bullet list;
  - a table.
- **When** `speech_text.normalize` runs with the **default** code policy,
- **Then**:
  - the code block becomes "Code block." (OD5's recommended announce form; the silent form is
    a one-line policy switch);
  - inline code is read without backticks;
  - the link reads its text only;
  - no `*`, `#`, `|` or bullet marks remain;
  - the table becomes "Table.".
- **Edge cases:** an unclosed fence; `~~~` fences; a fence in a list item; `**` inside a word;
  a URL with parentheses; text that is only code; empty text; invalid UTF-8.
- **Property (idempotent):** `normalize(normalize(s)) == normalize(s)` over generated
  markdown-like strings up to 4 KiB.
- **Property (invariant):** the output has no backtick, no `](`, and no line starting with
  `#`. With the default policy, no generated fence body appears in the output.
- **Files touched:** `src/speech_text.zig`, `tests/speech_text_test.zig`, `build.zig`
  (registered in the green commit).

🔴 **Red** (`tests/speech_text_test.zig`, unregistered in the red commit):
```zig
test "by default a fenced code block is not read" {
    const out = try speech_text.normalize(testing.allocator,
        "Run this:\n```zig\nconst x = 1;\n```\nThen restart.", settings.defaults().code_policy);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Run this:\nCode block.\nThen restart.", out);
}
```
🟢 **Green:** a line scanner with fence state and a small inline pass. No regex engine.
🔵 **Refactor:** one table of marks; the policy switch in one place; one scanner shared by
the streaming and whole-text forms.

#### Behavior V0.2: deltas become sentences wherever the deltas split
- **Given** a reply split into deltas at arbitrary byte positions,
- **When** the deltas are fed to the chunker and the final message flushes it,
- **Then**:
  - the chunks equal those of the whole text;
  - no chunk ends after an abbreviation, a decimal or a version;
  - the first chunk is at least 12 characters, and no chunk is longer than 280;
  - nothing is lost or repeated.
- **Edge cases:**
  - no punctuation;
  - one very long sentence;
  - only code;
  - "Mr. Smith", "3.14", "v1.2.3.", "…";
  - a truncated final message: only the new suffix is spoken.
- **Property (metamorphic):** `chunks(split(text)) == chunks(text)` for every random split
  into 1-50 deltas.
- **Property (invariant):** `concat(chunks) == normalize(text)` up to whitespace.
- **Files touched:** `src/speech_chunker.zig`, `tests/speech_chunker_test.zig`.

🔴 **Red:**
```zig
test "chunking does not depend on where the deltas split" {
    var prng = std.Random.DefaultPrng.init(0x5be3c4);
    const r = prng.random();
    for (0..5_000) |_| {
        const text = try gen.replyText(testing.allocator, r);
        defer testing.allocator.free(text);
        const whole = try chunkAll(testing.allocator, &.{text});
        defer whole.deinit();
        const parts = try gen.randomSplit(testing.allocator, r, text, r.intRangeAtMost(usize, 1, 50));
        defer parts.deinit();
        const split = try chunkAll(testing.allocator, parts.items);
        defer split.deinit();
        try testing.expectEqualDeep(whole.items, split.items);
    }
}
```
🟢 **Green:** a carry buffer. Boundaries are decided only on text the next delta cannot
change.
🔵 **Refactor:** abbreviations are data; the boundary rule is one function.

#### Behavior V0.3: the queue speaks one thing at a time; a stop or a mute is final
- **Given** a fake backend whose events the test delivers in any order,
- **When** the test runs enqueues, `stop(win)`, `set_muted`, late events and enqueues from
  other windows,
- **Then**:
  - at most two utterances are ever handed to the backend;
  - after a stop, no utterance from the old epoch starts;
  - after mute, nothing from replies is enqueued. A Speak press still plays, because mute
    applies only to automatic reading, and pressing Speak does not unmute;
  - each started utterance ends exactly once.
- **Property (invariant):** generated operation sequences over 3 windows, checked against a
  reference model (a plain list).
- **Files touched:** `src/speech_queue.zig`, `tests/speech_queue_test.zig`.

#### Behavior V0.4: settings default to on, validate, clamp and keep what they don't own
- **Given** `voice.json` that is:
  - missing;
  - corrupt;
  - oversized (over 4 KiB);
  - a symlink;
  - out of range;
  - holding unknown keys;
  - holding the STT plan's `dictation` object.
- **When** loaded and saved,
- **Then**:
  - a missing file gives the **defaults: `auto_read` true, `muted` false, `code_policy`
    `announce_skip`, `pause_for_screen_reader` true**;
  - a corrupt, oversized or symlinked file gives the defaults and is not overwritten until a
    change;
  - out-of-range values are clamped;
  - unknown keys and `dictation` are kept byte-for-byte;
  - writes are atomic.
- **Property (roundtrip):** `parse(write(s)) == s`.
- **Files touched:** `src/voice_settings.zig`, `tests/voice_settings_test.zig`. Reuse
  `atomic_file.replaceJson` and the load shape of `agent_drawer.zig:244-277`.

#### Behavior V0.5: parameter mappings are monotonic, and 1.0 maps to the default
- **Property (invariant):** each mapping is monotonic and clamped, and 1.0 maps to the
  backend's default. The engine mapping comes first; the system mappings come with S1-S3.
- **Files touched:** `src/speech_params.zig`, `tests/speech_params_test.zig`.

**V0 success criteria.**
- [ ] The red tests fail first, run by hand while unregistered.
- [ ] `zig build speech-core-test` is green.
- [ ] `zig build test` is green under a private Xvfb.
- [ ] No duplicated scanner or JSON helper.

---

### V1 — The backend contract, the record backend and the reply feed (Linux; BLOCKING Closure A and B)

#### Behavior V1.1: the record backend is inert without `--e2e-protocol`
- It prints the `ignored` line, writes nothing, and uses the normal choice (`engine`).
- **Files touched:** `src/speech_config.zig` (the `--speech-backend` switch via
  `env_switch`), `src/cli.zig`, `src/main.zig`, `tests/e2e/speech_record_test.py`.

#### Behavior V1.2: in a new profile, a streamed reply is spoken while it arrives (Closure A, record variant)
- **Given:**
  - an **empty profile** (no `voice.json`);
  - the record backend;
  - `fake_host.py` scripting three sentences in nine deltas, with a 1 s stall before the
    last.
- **When** the user types "hi" and clicks Send,
- **Then**:
  - `SPEECH queued` for sentence 1 appears **before** the stall ends;
  - `start` and `end done` rows follow in order;
  - the texts concatenate to the normalized reply;
  - the `DRAWER msg assistant` row is unchanged.
- **Variant:** the real helper and CLI against `fake_anthropic_api.py`.
- **Edge cases:**
  - two `assistant_message`s in one turn: both are spoken, in order;
  - an `error` mid-reply: the spoken part ends, and nothing more is queued;
  - a truncated final message: only the suffix is spoken.
- **Files touched:**
  - `src/speech.zig`, `src/speech.h`, `src/speech_backend.h`;
  - `src/speech_record.c`;
  - `src/agent_helper.c`: three calls in `on_frame`, the production caller;
  - `src/agent_drawer.c`: rows through the shared writer;
  - `src/app.zig`: open the backend at startup;
  - `build.zig`;
  - `tests/e2e/agent_common.py` (`parse_row`);
  - `tests/e2e/speech_record_test.py`.

🔴 **Red** (`tests/e2e/speech_record_test.py`, not registered until green):
```python
def case_stream_default_on(binary):
    with world(binary, script=THREE_SENTENCES_WITH_STALL, speech="record", profile="empty") as w:
        w.type_and_send("hi")                                   # xinput on the private Xvfb
        q1 = w.wait_row("SPEECH", kind="queued", timeout=10)    # FAILS today: no SPEECH rows
        check("first sentence queued before the stall ends", q1.t < w.stall_release_t)
        ends = w.wait_rows("SPEECH", kind="end", n=3, timeout=20)
        check("all done", all(e.fields[-1] == "done" for e in ends))
        check("text is the normalized reply", "".join(w.record_texts()) == NORMALIZED)
```
🟢 **Green:** the feed functions, the pump as a main-loop idle, and the record backend
reporting through `zb_speech_event`.
🔵 **Refactor:** `on_frame` gains three one-line calls; one row writer; the backend table as
data.

#### Behavior V1.3: every way a reply ends ends or keeps its speech correctly
- **Silenced within 200 ms, with no later `start`:** the agent's Stop, closing the window, a
  helper crash and token removal.
- **Allowed to finish:** a normal `result` lets the queued sentences finish.
- **Another window:** a newer reply in another window stops this one.
- **Files touched:** `src/agent_helper.c` (`zb_speech_reply_end` at `result`, `error`,
  stopped and `on_helper_exit`), `src/agent_drawer.c` (`on_stop_clicked` and
  `zb_drawer_detach` call `zb_speech_stop`).

#### Behavior V1.4: no agent output can steer speech
- Frames with SSML-like text, control characters, 16 KiB deltas and a `tool_call` are spoken
  as literal, normalized text, or not at all.
- No frame type asks for speech. The record jsonl carries only the user's settings.

---

### V2 — The shared audio output layer `zb_audio` (Linux build and test; cross-compiles; shared with the STT plan)

#### Behavior V2.1: PCM played through `zb_audio` reaches the device
- **Given** the private PulseAudio world,
- **When** a 1 s 440 Hz tone (16-bit, mono, at the engine's rate) is played through the
  `--e2e-protocol --audio-selftest` seam,
- **Then** the monitor shows an FFT peak within 5 Hz of 440 for about 1 s.
- **Files touched:**
  - `third_party/miniaudio/miniaudio.h` (vendored, pinned, with its license);
  - `src/audio.zig`: open, play stream, stop, device-gone;
  - `src/audio.c`: the single implementation unit;
  - `build.zig`: all three backends; CoreAudio, AudioToolbox and AudioUnit on macOS;
  - `src/app.zig`: the seam;
  - `tests/e2e/audio_common.py`, `tests/e2e/audio_common_test.py`, `tests/e2e/audio_out_test.py`.

#### Behavior V2.2: stop drops queued audio within 50 ms; a lost device is reported
- Stop empties the ring buffer.
- `pactl unload-module` on the sink gives a `failed` end and a status, not a hang.

#### Behavior V2.3: the audio guard refuses the user's session
- With the inherited environment, `audio_common.py` exits 1 before starting anything.

#### Behavior V2.4: it compiles and links for every target
- The Windows cross-check and a macOS build on both Macs compile `audio.c`.
- On both Macs, `--audio-selftest` plays with output muted, and with miniaudio's null backend.

---

### V3 — The bundled engine `zb-speech` on Linux (primary; decided 2; Pocket TTS, decided 4; runtime path OD2)

#### Behavior V3.1: the model files are found, verified and refused when wrong
- **Given** the pinned manifest `engine/models/pocket-tts.json`, which records each file's
  name, size, SHA-256, source revision, license (`CC-BY-4.0`), attribution text and a "changes"
  note (for example "converted to ONNX, int8"),
- **When** `zb-speech` starts with the model directory,
- **Then**:
  - a matching set gives `hello ok <model> <version>`;
  - a wrong hash or a missing file gives `hello error model <file>`;
  - the browser shows "Speech unavailable (model)".
- **Files touched:** `engine/models/pocket-tts.json`, `src/models.zig` (shared with the STT
  plan; if it lands first, this behavior only adds the manifest), `tests/models_test.zig`,
  `tools/speech_model_env.sh` (fills the developer cache from the pinned source; network once).

#### Behavior V3.2: `zb-speech` synthesizes in its own sandbox with no network (Closure D, Linux)
- **Given** the model installed,
- **When** the browser speaks one sentence with the engine backend,
- **Then**:
  - PCM frames arrive over the pipe;
  - `zb_audio` plays them into the null sink (RMS check);
  - from inside the process, a connect to `1.1.1.1:443` fails (a test-only probe flag, honored
    only with `--e2e-protocol`);
  - it cannot read `<profile>` or the agent home;
  - it exits when the browser is killed.
- **Files touched:**
  - `engine/zb_speech/main.zig`: the process and pipe protocol;
  - `engine/zb_speech/pocket.zig`: the model's pre- and post-processing over the ONNX Runtime
    C API, through `@cImport` of `onnxruntime_c_api.h`;
  - `third_party/onnxruntime/` (prebuilt, pinned per platform, with its license);
  - `tools/export_pocket_onnx.py` (OD2 a; developer tool, not shipped);
  - `src/speech_engine.c`: the backend, with spawn, pipe, cancel and restart backoff;
  - the sandbox spec through the shared `SandboxBackend` contract;
  - `build.zig`;
  - `tests/e2e/speech_engine_test.py`.

#### Behavior V3.3: first audio within the budget; stop within 250 ms at the sink
- On the Linux dev machine, first audio comes within 600 ms of the first chunk for a 12-40
  character sentence. The budget is recorded per host, not tuned silently.
- Cancel drops queued PCM and aborts synthesis.

#### Behavior V3.4: voices and controls come from the engine
- The engine's built-in voices are listed (`kind=builtin`), and rate and volume work.
- Pitch is reported in `caps`. If the engine cannot change pitch, the Voice window hides the
  slider for that voice (asserted in V5).

#### Behavior V3.5: the model and runtime are in the installer, with attribution
- **Given** the Linux `.deb`, the macOS `.dmg` and the Windows MSI built by their packaging
  scripts,
- **Then**:
  - each contains `zb-speech`, ONNX Runtime and the pinned model files at the
    model-manager's bundled location;
  - the hashes match the manifest;
  - **CC-BY-4.0 attribution, as a packaging task:**
    - every installer carries the full CC BY 4.0 license text and the attribution ("Pocket
      TTS by Kyutai, licensed under CC BY 4.0", with a link to the license and to the model
      card) and the changes note (for example "converted to ONNX and quantized to int8 by
      zigBrowser");
    - the app shows the same text in a credits screen: "About this voice" in the Voice window
      (V5.4) and the app's About or credits screen;
    - `package_speech_test.py` checks that the license file is present in each package and
      matches the manifest's text, and the Voice window e2e reads the credits text back
      through a `VOICE` row;
    - the exact attribution wording Kyutai asks for (if any) is read with the gate terms
      (OD7);
  - the measured total is recorded in the plan's status. If it exceeds 200 MB, it goes back
    to the user (section 6.2).
- **Gate:** OD7 (legal review) before this behavior ships.
- **Files touched:** `packaging/linux/build-deb.sh`, `packaging/macos/build-dmg.sh`,
  `packaging/macos/universal_components.json`, `packaging/windows/zigBrowser.wxs`,
  `packaging/assets/THIRD_PARTY_LICENSES` (new or extended), `tests/e2e/package_speech_test.py`.

---

### V4 — Drawer controls under "on by default" (Linux; **UI slice**; BLOCKING Closures A, B, F)

#### Behavior V4.1: the mute and stop control is always visible and has three states
- **Given** a fresh profile and the drawer open,
- **Then** `DRAWER speaker on` is drawn in every agent state, including "No token" and
  "Speech unavailable". It is never insensitive.
- **When** a reply is spoken, **then** `speaker speaking`.
- **When** the user clicks it, **then** `end cancelled` within 200 ms and `speaker on`.
- **When** the user clicks it while idle, **then** `speaker muted`, and the next reply gives
  `pause muted` with nothing queued. `muted` survives a restart.
- **Files touched:**
  - `src/agent_drawer.c`: the header control and its handler;
  - `src/agent_drawer.zig`: a pure function from (auto_read, muted, speaking, available,
    paused) to the label and state;
  - `tests/agent_drawer_test.zig`;
  - `tests/e2e/agent_drawer_speech_test.py`.

#### Behavior V4.2: the first spoken reply shows the notice once
- On the first spoken reply in a profile, `DRAWER msg system Replies are read aloud. Use the
  speaker button to mute, or turn it off in Voice settings.` appears.
- It does not appear again after a restart.

#### Behavior V4.3: the minimized stop badge
- **When** the drawer is minimized while speaking, **then** `DRAWER speakbadge shown` with a
  rect beside the icon's rect, and inside the window.
- A guarded click on the badge gives `end cancelled` and `speakbadge hidden`.
- A click on the icon still opens the drawer.
- The §7.1 census rule still holds: no output window overlaps the page window; the badge is
  painted into the page's window like the other floats.

#### Behavior V4.4: Stop, Send, Ctrl+Shift+S and the bubble's Speak (Closure B)
- Each stop path from Closure B.
- The bubble's Speak speaks its original text, and a second Speak on another bubble switches
  to it.
- Error and user bubbles have no Speak button.

#### Behavior V4.5: a screen reader pauses automatic reading (Closure F)
- With the private AT-SPI bus reporting a screen reader:
  - `SPEECH 0 pause screen-reader`;
  - the status line;
  - nothing automatic is queued;
  - Speak still works.
- With the setting off, there is no pause.
- **Files touched:** `src/speech_a11y.c` (reads `ScreenReaderEnabled` through GDBus and
  watches its changes), `tests/e2e/speech_screen_reader_test.py`.

#### Behavior V4.6: keyboard and names
- **Tab order:** input, Send, Stop, speaker, Voice, Account, '-'.
- **Accessible names:** "Mute read-aloud", "Unmute read-aloud", "Stop speaking", "Speak this
  reply", "Voice settings".
- `DRAWER focus` gains `speaker`, `voice`, `speak` and `speakbadge`.

**Real-screen check (V4):** `drawer-speech-default`, `drawer-speech-muted`,
`drawer-speech-minimized` and `drawer-speech-bubble`, plus `drawer-speech-screen-reader` with
the user's consent (section 7.4).
**Real-audio check:** the user hears the first reply without having done anything, hears it
stop on each control, and hears nothing after mute.

---

### V5 — The Voice window, Read aloud section (Linux; **UI slice**; BLOCKING Closure C; shared with the STT plan)

- **V5.1** The window lists the engine's voices and saves each change (`VOICE setting`
  rows, `voice.json`). Automatic reading shows **on** in a fresh profile, and turning it off
  here changes the drawer control's long-press state too.
- **V5.2** Preview speaks with the current settings, and a second Preview stops the first.
- **V5.3** The settings survive a restart and reach the next reply (Closure C).
- **V5.4** "About this voice" shows the license name, the attribution and the changes note
  from the manifest.
- **V5.5** The pitch slider is hidden for a voice whose backend lacks pitch.
- **V5.6** The window is unreachable from pages and the automation socket (the S4.3 shape).
- **V5.7** The "Dictation" section exists as a placeholder for the STT plan.
- **Files touched:** `src/voice_window.c`, `src/voice_window.h`, `src/agent_drawer.c` (Voice
  button), `src/voice_settings.zig`, `tests/e2e/voice_window_test.py`, `build.zig`.
- **Real-screen check:** `voice-window`.
- **Real-audio:** the user hears the preview at the chosen rate.

---

### M1 — The bundled engine on macOS (**needs the Macs**; both hosts; no drawer needed)

- **M1.1** The universal build includes a universal `zb-speech` and the macOS ONNX Runtime
  library (arm64 and x86_64 slices). `lipo -archs` lists both, and the executing-arch row
  proves the native slice runs on each host.
- **M1.2** `zigBrowser --e2e-protocol --speech-selftest "The quick brown fox." --speech-out
  /tmp/zb-say.wav` renders through the engine to a WAV with audio on **both** Macs. First
  audio and the real-time factor are recorded per host. Intel is expected to be the slowest;
  if it misses real time, that goes to the user.
- **M1.3** (after MS6) `zb-speech` runs under the Seatbelt backend with no network and
  read-only model access, proven by the same probes as V3.2.
- **M1.4** With output muted, playback through Core Audio (`zb_audio`) runs and ends `done`,
  and stop gives `cancelled` within 250 ms.
- **M1.5** The hardened-runtime build runs `zb-speech` (a nested signed executable) without a
  new entitlement. If it fails, the key that fixes it is added with its justification, as
  `entitlements.plist` requires.
- **Files touched:** `build.zig` (macOS: build `zb-speech`, link ONNX Runtime, Core Audio
  frameworks), `src/app.zig` (self-test seam), `tests/mac/speech_mac_test.py`,
  `tests/mac/gate.sh` (step `speech-mac-e2e`), `packaging/macos/universal_components.json`.
- **Success:** `speech-mac-e2e` passes on both Macs in one `gate.sh` run.

---

### C1 — Cloning: consent and enrolment (**UI slice**; Linux first, then Macs; decided 1)

Needs V3 (the engine clones) and a capture path in `zb_audio`: the STT plan's, or a minimal
capture added here with the same interface.

- **C1.1 No recording before consent.** "Create my voice…" shows the consent screen
  (`VOICE clone consent`) in plain sentences:
  - this makes a copy of your voice on this computer;
  - use only your own voice, or one you have permission to use;
  - it is for your own use in this browser;
  - it is never uploaded, shared or exported;
  - you can delete it at any time.

  Record stays disabled until the box is ticked and Continue is pressed. Cancel at any step
  leaves nothing on disk.
- **C1.2 A random consent sentence first.** The sentence includes the date and is recorded as
  the first sample. Then the enrolment text. Microphone only, with a level meter. The e2e
  feeds a fixture as the private PulseAudio's source and checks the row order (`consent` →
  `recording` → `processing` → `ready`) and `consent.json`.
- **C1.3 No other source.** No file picker (OD9), no automation method, no agent tool and no
  page API can start or feed enrolment. A test lists the automation methods and the agent's
  tool names. The window is unreachable from page JavaScript.
- **Files touched:** `src/voice_window.c` (clone pages), `src/voice_clone.zig` (state machine,
  storage, consent record), `engine/zb_speech/pocket.zig` (derive the speaker state from the
  samples), `tests/e2e/voice_clone_test.py`.
- **Real-screen check:** `voice-clone-consent`. The orchestrator also asks the user to try one
  real enrolment.

### C2 — Cloning: speaking with my voice (Closure E)

- **C2.1** "Your voice" is listed (`kind=cloned`). Preview speaks with it (RMS at the sink),
  and a reply uses it when chosen. (If OD3 is ever reopened for a watermarking engine, a test
  runs the vendor's detector on the output.)
- **C2.2** `voices/<id>/` is 0700 with 0600 files. `zb-speech` gets read-only access to that
  voice's speaker state for the call, never the samples. The drawer plan's canary scanner
  finds none of the samples' bytes in the agent home, the API requests or the transcripts.
- **C2.3** On both Macs, the remote hosts have no virtual microphone set up, so the Mac test
  feeds the same enrolment fixture to the engine through an `--e2e-protocol`-only self-test
  path. The resulting voice renders to a WAV with audio. Live microphone enrolment on macOS is
  checked once with the user (it needs the microphone permission from the shared prompts).

### C3 — Cloning: delete and lifecycle (**UI slice**)

- **C3.1** "Delete my voice" removes the directory and the `voice.json` reference, stops a
  playing utterance, updates the list, and writes `VOICE clone deleted`. A crash halfway is
  recovered at the next start: a directory without `consent.json` is deleted.
- **C3.2** Re-enrolment asks for consent again. The old voice is replaced only when the new
  one is ready.
- **Real-screen check:** `voice-clone-ready`. The user confirms the delete.

---

### M2 — Spoken replies and the Voice window on macOS (**needs the Macs**; **UI slice**; blocked on MS7 and MS8)

- **M2.1** The AppKit drawer (MS7) gains the same controls as V4: the always-visible
  three-state speaker, the minimized stop badge, Speak buttons, the Voice button and the
  first-run notice. They call the same `zb_speech_*` exports.
- **M2.2** MS8's frame pump calls `zb_speech_reply_*` where it calls the drawer. Closures A and
  B run on both Macs (record and engine variants), observed through MS7's `--e2e-protocol`
  native census.
- **M2.3** The Voice window in AppKit (`src/voice_window_mac.m`), with the same rows.
- **M2.4** VoiceOver pauses automatic reading (`NSWorkspace.isVoiceOverEnabled` and its
  change notification). The automated test injects the value through an `--e2e-protocol`
  seam. The real signal is checked once with the user.
- **Files touched:** `src/agent_drawer_mac.m` (from MS7), the MS8 pump file,
  `src/voice_window_mac.m`, `src/speech_a11y_mac.m`, `tests/mac/agent_drawer_speech_mac_test.py`.
- **Real-screen check:** `mac-drawer-speech-default`, `mac-drawer-speech-minimized` and
  `mac-voice-window` on the user's Mac.
- **Real-audio:** on the user's Mac.

---

### W0 — Windows: engine, audio and feed, compile and link only (Linux; cross-compiled)

- **W0.1** `zb-speech`, `audio.c` (WASAPI through miniaudio) and the speech core build for
  `x86_64-windows-gnu` with the pinned Windows ONNX Runtime import library. The existing
  `cross-check` step (`build.zig:278`) stays green.
- **W0.2** The Windows sandbox spec for `zb-speech` is a stub that **refuses to start** until
  the Windows launch plan's **WS8.7** (the no-network child) is green. The browser then shows "Speech unavailable
  (sandbox)" instead of running the engine unconfined. A compile-time test checks that the
  stub is the only Windows implementation.
- **Files touched:** `build.zig` (step `speech-win-compile`), `engine/zb_speech/main.zig`
  (Windows pipe handling), `tests/speech_win_compile_test.zig`.
- **Note:** this proves only that the code builds. Running it is W1.

### W1 — Windows: engine and audio at run time (WS0 hosts; WS1 build; WS8.7; WS13)

- Built on `win11-m8` by WS1 (`build-on-windows.sh`, `-Dtarget=x86_64-windows-msvc`), then run on
  **`win11-m8`** and the **physical Windows 10 machine** (run-only), both x64 (arm64 per OD8 and
  the Windows plan's OD-W5):
  - **W1.1** The packaged installer (WS13; its format is the Windows plan's OD-W1) installs
    `zb-speech`, ONNX Runtime and the model into the `models\tts\` slot (V3.5; WS13.1 census,
    WS13.3 size budget).
    `--speech-selftest` renders a WAV with audio.
  - **W1.2** `zb-speech` runs as the WS8.7 no-network child (the same probes; the Windows plan's
    test `probe("127.0.0.1", 51091, as_user="zb-speech") == "WSAEACCES"` is LEAF there and
    BLOCKING here).
  - **W1.3** Playback through WASAPI to a muted session or the null backend ends `done`, and
    stop gives `cancelled` within 250 ms.
  - **W1.4** First audio and the real-time factor are recorded for both hosts.
- **Test files:** `tests/windows/speech_win_test.py`, run by `tests/windows/gate.sh --phase voice`
  (WS12.2) on both hosts. The gate fails closed when a host is missing (WS0.2, WS0.6).

### W2 — Spoken replies on Windows (**UI slice**; WS5 drawer, WS11 helper and chat, WS12.1 hook points)

- The Win32 drawer (WS5) gains the V4 controls through the WS12.1 hook point
  `zb_drawer_speaker_toggled` and the same `DRAWER speaker` rows. WS11's frame pump calls
  `zb_speech_reply_*`. The Voice window gets its Win32 port here (`src/voice_window_win.cpp`).
  Closures A, B and F (Narrator through `SPI_GETSCREENREADER`) run on the Windows hosts.
- **Real-screen check:** `win-drawer-speech-default`, `win-drawer-speech-minimized` and
  `win-voice-window`, on both Windows hosts with the user (the VM console and the Windows 10
  monitor), through the Windows plan's real-screen runner.
- **Real-audio:** on the physical Windows 10 machine with the user.

### CW — Cloning on Windows (**UI slice**; after W2 and C1-C3; decided 1)

Pocket TTS clones on every platform (DECIDED 4), so Windows gets the same cloning leg as Linux
and macOS. The rules of D10 apply unchanged.

- **CW.1 Consent before any recording.** The Win32 Voice window shows the same consent screen
  as C1.1 (`VOICE clone consent`). Record stays disabled until the attestation is ticked and
  Continue pressed. The first sample is the random dated consent sentence (C1.2).
- **CW.2 Microphone only.** Capture goes through `zb_audio` on WASAPI (the STT plan's VS10
  capture path, or a minimal one added here with the same interface). Windows' microphone
  privacy switch is handled as the STT plan does: a denied switch gives `VOICE clone refused
  microphone` with guidance, and the test changes the switch only for `zbtest`. No file picker
  (OD9), no automation method, no agent tool and no page API reach enrolment (the C1.3 test,
  run on Windows; the WS5.6 isolation rule).
- **CW.3 Local storage, private to the user.** `voices\<id>\` lives under the profile's data
  directory in `%LOCALAPPDATA%`. Its DACL grants only the current user (and SYSTEM). The WS8
  sandbox users (`zb-agent`, `zb-hook`) are denied; a test opens a sample file as each of them
  and expects `ERROR_ACCESS_DENIED`. The `zb-speech` WS8.7 child gets read access to that one
  voice's speaker state for the call, never the samples. `consent.json` is written as in C1.2.
- **CW.4 Speak with it.** "Your voice" is listed and Preview speaks with it (WASAPI to a
  muted session; the rendered WAV has audio).
- **CW.5 Delete.** "Delete my voice" removes the directory and the `voice.json` reference,
  stops a playing utterance, and writes `VOICE clone deleted`. A half-finished delete is
  recovered at the next start (C3.1). Re-enrolment asks for consent again (C3.2). Uninstall
  (WS13) asks whether to keep or remove personal voices, and removing them is complete.
- **Automated tests:** `tests/windows/voice_clone_win_test.py` on both hosts through the
  voice gate phase. Enrolment is fed from the enrolment fixture through the
  `--e2e-protocol`-only WAV seam (the Windows plan's VS10/VS11 WAV seam), because `win11-m8`
  has no proven capture device. The live microphone path runs on the Windows 10 machine,
  where a missing microphone reports `NOT RUN: no capture device` and fails the gate.
- **Files touched:** `src/voice_window_win.cpp` (clone pages), `src/voice_clone.zig` (shared
  with C1-C3), `src/voice_store_win.c` (DACL), `tests/windows/voice_clone_win_test.py`.
- **Real-screen check:** `win-voice-clone-consent` (consent screen, Record disabled then
  enabled) and `win-voice-clone-ready` ("Your voice" and Delete), on the physical Windows 10
  machine with the user; on `win11-m8` once its capture device is proven (the Windows plan's
  provisioning item 12). The user tries one real enrolment and one delete there.

---

### S1-S4 — System voices (secondary; decided 2; order per OD6)

These come after the bundled engine on each platform. They appear in the Voice window's
"System" group. The engine stays the default.

- **S1 Linux speech-dispatcher** (developer tool).
  - `src/speech_spd.c` `dlopen`s `libspeechd.so.2` (`spd_open2`, `spd_say`, `spd_cancel`, the
    rate, pitch and volume setters, `spd_list_synthesis_voices`, callbacks).
  - Tests run in the private PulseAudio world. If the library or daemon is missing:
    `SPEECH 0 backend spd unavailable <dlopen|connect>`.
  - Step `speech-spd-e2e`.
- **S2 macOS AVSpeechSynthesizer.**
  - `src/speech_mac.m` uses a retained synthesizer, the delegate posting to the main queue,
    `speakUtterance:`, `writeUtterance:toBufferCallback:` for tests, and
    `stopSpeakingAtBoundary:AVSpeechBoundaryImmediate`. `build.zig` links `AVFAudio`.
  - Voices are listed with quality, deduped by identifier.
  - Rate 0.5 vs 2.0 changes the rendered length.
  - The hardened-runtime build speaks without a new entitlement, or the key is added with its
    justification.
  - Tests run on both Macs.
- **S3 Windows WinRT with a SAPI 5 fallback.**
  - `src/speech_win.cpp` uses raw COM on the ABI header from the SDK's `winrt` directory
    (`-Dwinrt_include`; Zig's MinGW lacks `windows.media.speechsynthesis.h`). A
    `CheckWinrtSpeechHeaderStep` names the missing header.
  - It sets `SpeakingRate`, `AudioPitch`, `AudioVolume` and `AppendedSilence = Min`, and plays
    the WAV stream through `zb_audio`.
  - `src/speech_sapi.cpp` uses Zig's own `sapi.h`.
  - On the Windows hosts, first check whether an unpackaged app can activate WinRT
    `SpeechSynthesizer` (unverified in research). If it cannot, SAPI is the only system path.
- **S4 macOS Personal Voice** (cloning extra; **UI slice**).
  - "Use my Personal Voice…" calls `requestPersonalVoiceAuthorizationWithCompletionHandler:`
    once.
  - The window shows authorized ("Your voice"), denied (guidance to "Allow Apps to Request to
    Use", with a button that opens the pane) or unsupported (Intel, or macOS 13: hidden).
  - The automated tests inject the status through an `--e2e-protocol` seam on both Macs; the
    Intel host proves the unsupported path for real.
  - The real authorization happens on the user's Apple Silicon Mac with the user.
  - `Info.plist` gets a usage string only if the Mac proves one is needed.
  - **Real-screen check:** `mac-personal-voice`.

## 10. Test shapes and the refactor checklist (apply to every slice)

The e2e world lives in `tests/e2e/speech_common.py` (new). It wraps the lifecycle world with
the audio guard (7.3), the private AT-SPI bus, the record directory, row parsing for `SPEECH`
and `VOICE`, and `wait_row` with deadlines.

```python
# tests/e2e/agent_drawer_speech_test.py  (red until V4 green)
def case_badge_stops_minimized(binary):
    with speech_world(binary, profile="empty", script=SIX_SENTENCES_STALL_AFTER_4, ms_per_char=60) as w:
        w.type_and_send("hi")
        w.wait_row("SPEECH", kind="start", timeout=10)
        w.press_escape_in_drawer()                                   # minimize
        badge = w.wait_row("DRAWER", kind="speakbadge", value="shown", timeout=2)
        t = w.click_rect(badge.rect)                                 # guarded X click on the private Xvfb
        end = w.wait_row("SPEECH", kind="end", timeout=2)
        check("cancelled", end.fields[-1] == "cancelled")
        check("within 200 ms", end.t - t <= 0.2)
        check("badge hidden", w.wait_row("DRAWER", kind="speakbadge", value="hidden", timeout=1))
        check("nothing later", not w.rows_after(end.t + 2.0, "SPEECH", kind="start"))
```

**The refactor checklist**, run with the tests green before every commit:
- **No duplication:**
  - one row writer for `DRAWER`, `SPEECH` and `VOICE`;
  - one JSON-store helper shared with `agent-drawer.json`;
  - one `env_switch` per flag;
  - one pipe-frame codec shared by the browser and `zb-speech`;
  - the backend table as data.
- **Reveals intent:** toolkit callbacks only translate events into Zig core calls.
- **Complexity goes down:** the queue is one enum and one transition function, and so is the
  speaker control's state.
- **No shallow wrappers:** backends implement the vtable directly.
- **Fits existing patterns:** GTK on the main thread only; `zigBrowser: …` stderr lines; tests
  in `tests/*_test.zig`.

## 11. Per-slice gate protocol (all slices)

1. Mail "taking the gate slot" for the gate run only, and trust only "slot FREE" mails.
2. Write the red tests in files **not registered** in `build.zig`, record the red runs (on a
   remote Mac or Windows host for those e2e), and commit them outside the gate.
3. Green: the minimal code, registering the tests in the same commit.
4. Refactor with the checklist.
5. Run a quiet gate from a clean `git archive HEAD` plus the slice's files, under a private
   Xvfb. Run each Python module alone, count ResourceWarnings, and reap every Popen.
6. Commit only the slice's files and stage only your own hunks.
7. Mail the reviewer.
8. UI slices (V4, V5, C1, C3, M2, W2, S4): the orchestrator runs the real-screen case and the
   real-audio line with the user. **A UI slice is not approved until they pass.**
9. A slice is not done until its closure e2e was observed to execute with nonzero assertions.
   A skip or "NOT RUN" stays open.

## 12. Integration and E2E summary

| Gate step (new) | Slice | Real components | Mocked boundary | Runs on |
|---|---|---|---|---|
| `speech-core-test` | V0 | Zig core | none | Linux |
| `speech-record-e2e` | V1 | browser, GTK, helper or `fake_host.py`, real-CLI variant | Anthropic API; engine + device (record) | Linux Xvfb |
| `audio-common-test`, `audio-out-e2e` | V2 | miniaudio, private PulseAudio | none | Linux |
| `speech-engine-e2e` | V3 | `zb-speech`, ONNX Runtime, real model, sandbox, private PulseAudio | none | Linux |
| `package-speech-e2e` | V3.5 | the three packages | none | Linux (+ Mac and Windows packaging hosts) |
| `agent-drawer-speech-e2e`, `speech-screen-reader-e2e` | V4 | browser, GTK, X input, private AT-SPI | Anthropic API; record and engine variants | Linux Xvfb |
| `voice-window-e2e` | V5 | browser, GTK, X input, settings file | record | Linux Xvfb |
| `speech-mac-e2e` | M1, M2, S2, S4 | universal binary, `zb-speech`, Core Audio (muted), AVSpeech (S2) | none | both Macs |
| `voice-clone-e2e` | C1-C3 | capture through private PulseAudio, `zb-speech` | none | Linux; both Macs |
| `speech-win-compile` | W0 | compiler, linker | none | Linux (cross) |
| `speech-win-e2e` | W1, W2, S3 | engine, WASAPI, Win32 drawer | none | `win11-m8` and the Windows 10 machine via `tests/windows/gate.sh --phase voice` (WS12.2) |
| `voice-clone-win-e2e` | CW | capture (WAV seam; live microphone on Windows 10), `zb-speech`, DACL store | none | both Windows hosts |
| `speech-spd-e2e` | S1 | speech-dispatcher, private PulseAudio | none | Linux |
| `real_screen_check_unit`, `real_audio_check_unit` | V4+ | the manual scripts' logic with fakes | captures, device | Linux |

## 13. Dependency order

| Slice | Comes after |
|---|---|
| V0 → V1 → V2 → V3 → V4 → V5 | each the previous one |
| V3.5 (shipping) | OD7 |
| M1 | V3 and MS1; M1.3 also after MS6 |
| C1 → C2 → C3 | V3 and a capture path |
| M2 | V4, V5, M1, **MS7 and MS8** |
| W0 | V3 |
| W1 | W0 and the Windows plan's **WS0** (hosts), **WS1** (build), **WS8.7** (no-network child), **WS13** (installer slot) |
| W2 | W1 and **WS5** (drawer), **WS11** (helper and chat), **WS12.1** (hook points) |
| CW | W2, C1-C3, and a WASAPI capture path (STT VS10's or added here) |
| S1, S2, S3 | the platform's engine slice (V3, M1, W1 respectively), in OD6's order |
| S4 | S2 |

## 14. Tracking

Beads writes are blocked on this clone: the shared bd database has pending schema migrations,
and agents must not run `bd migrate` or `bd bootstrap`. When it is reconciled:
- file one epic, "Browser voice (text-to-speech)";
- give it the children V0-V5, M1, C1-C3, M2, W0-W2 and S1-S4, with the dependencies of
  section 13;
- link W1 to WS0, WS1, WS8.7 and WS13, W2 to WS5, WS11 and WS12.1, and CW to W2 and C3;
- link M2 to MS7 and MS8.

## 15. References

- **Research:** `thoughts/searchable/shared/research/2026-10-19-voice-output-tts.md` (rev 2:
  decisions, the Pocket TTS check, the Closure Map and ClosureMap JSON).
- **Sibling research (STT):**
  `/home/maceo/ntm_Dev/zigBrowser/thoughts/searchable/shared/research/2026-10-19-voice-recognition-options.md`.
- **Windows launch plan:** `thoughts/searchable/shared/plans/2026-10-19-windows-launch-tdd-plan.md` (milestones WS0-WS13). This plan depends on WS0 (hosts
  and gate), WS1 (build on the VM), WS5 (Win32 drawer), WS8 and WS8.7 (sandbox and the
  no-network child), WS11 (helper and chat), WS12 (voice hooks: WS12.1 hook points, WS12.2
  voice gate phase, the role map) and WS13 (installer slot, census, size budget). Hosts:
  the Win11 VM `win11-m8` and the physical Windows 10 machine (`100.123.34.15`, `file-server-win-mac`, run-only).
- **Drawer plan:** `thoughts/searchable/shared/plans/2026-10-13-claude-agent-chat-drawer-tdd-plan.md`
  (D1, D3, D7b rows at `:442-462`, S5 at `:1976`, §7.1, §10).
- **macOS plan:** `thoughts/searchable/shared/plans/2026-10-14-14-30-macos-launch-tdd-plan.md`
  (MS0, MS1, MS6, MS7 at `:1183`, MS8 at `:1260`, order at `:1338`).
- **Distribution plan:** `thoughts/searchable/shared/plans/2026-06-03-08-26-ENG-0007-tdd-distribution-installers-slice5.md`.
- **Sandbox research:** `…/research/2026-10-14-agent-sandbox-redteam.md`,
  `…/research/2026-10-14-macos-sandbox-option.md`.
- **Code anchors:**
  - `src/agent_helper.c`: `on_frame`, `zb_agent_helper_interrupt`;
  - `src/agent_drawer.c`: `zb_drawer_agent_delta`, `zb_drawer_agent_message`,
    `zb_drawer_agent_stopped`, `on_stop_clicked`, `zb_drawer_agent_status`,
    `set_bubble_text`, `drawer_row`;
  - `src/agent_protocol.zig:26-35,152-153`;
  - `src/env_switch.zig`, `src/media_config.zig`, `src/agent_drawer.zig:244`,
    `src/agent_secrets_window.c`;
  - `build.zig`: the three configure functions and `cross-check`;
  - `tests/mac/gate.sh`, `tests/e2e/agent_chat_test.py`, `tests/e2e/agent_common.py`.
- **Engine sources:**
  - [Pocket TTS repo (MIT)](https://github.com/kyutai-labs/pocket-tts);
  - [Pocket TTS weights (CC-BY-4.0, gated)](https://huggingface.co/kyutai/pocket-tts);
  - [files](https://huggingface.co/kyutai/pocket-tts/tree/main);
  - [no-cloning variant](https://huggingface.co/kyutai/pocket-tts-without-voice-cloning);
  - [sherpa-onnx Pocket](https://k2-fsa.github.io/sherpa/onnx/tts/pocket.html);
  - [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M);
  - [Chatterbox](https://github.com/resemble-ai/chatterbox);
  - [miniaudio](https://github.com/mackron/miniaudio).
- **Platform docs:**
  - [AVSpeechSynthesizer](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer);
  - [Personal Voice on Mac](https://support.apple.com/guide/mac-help/mchldfd72333);
  - [WinRT SpeechSynthesizer](https://learn.microsoft.com/en-us/uwp/api/windows.media.speechsynthesis.speechsynthesizer);
  - [speech-dispatcher](https://github.com/brailcom/speechd/wiki).
- **Closure framework:** `/home/maceo/Dev/silmari-agent-memory/SAI/commands/references/closure-test-framework.md`.
