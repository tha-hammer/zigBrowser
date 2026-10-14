---
date: 2026-10-14T14:30:00-04:00
planner: cc_3 / JadeBeacon (Opus 4.8)
git_commit: 176782f7d558d51eae12e5520e4f0ca99c2f0814
branch: zb-automation-integration-2026-10-10-11-59
repository: zigBrowser
topic: "macOS launch support for zigBrowser — TDD implementation plan"
tags: [plan, tdd, macos, wkwebview, appkit, seatbelt, universal-build, automation, drawer, sandbox, launch-critical]
status: plan for review (rev 4)
rev: 4
last_updated: 2026-10-14
last_updated_by: cc_3 / JadeBeacon
last_updated_note: "Rev 4 answers RoseCat's 3 rev-3 blockers (review db02324): positive approval closure moved to MS8 (real helper path); literal export-by-export ABI table with link-time fail-closed; CGEvent in-process vs CGEventPost split; cab60a1→da5eb70 dependency; re-pinned to HEAD 176782f"
primary_research: thoughts/searchable/shared/research/2026-10-14-14-19-macos-launch-support-surface.md
---

# macOS Launch Support for zigBrowser — TDD Implementation Plan

> **PLAN ONLY.** No implementation, no live runs. Agents prepare e2e scripts and may run
> them on the **remote Macs** over Tailscale SSH, never on the user's local `DISPLAY :0`,
> live profile, or live sockets. Every UI slice ends with a real-screen check judged by the
> user, coordinated by the orchestrator.

## Revision history

- **Rev 1** (`d857a03`): first plan, slices MS1–MS7.
- **Rev 2** (this): answers RoseCat's review `21625eb` ("BLOCKED", 9 blockers + 5
  open-question dispositions). Direction and user decisions were accepted; the plan was
  blocked for not being safe/specific enough to start. Rev 2 re-pins to HEAD `21625eb`,
  corrects the sandbox-interface layer, adds a pre-MS5 **Linux extraction slice (MS0)** and a
  **macOS setup/provisioning slice (MS5)**, splits MS2's single closure map into **three
  production chains**, gives native input a **capability spike contract**, makes the
  **Seatbelt security proofs hard launch gates that select the VM fallback**, specifies the
  **approval grant contract**, closes **Keychain + chat observability**, hardens the
  **two-arch/packaging gates against false-green**, and makes the **signing contract
  release-safe**. Slices are renumbered MS0–MS9.
- **Rev 3** (this): answers RoseCat's review `833767e` ("BLOCKED (docs)", 6 remaining
  blockers + a SHOULD list). Rev 2 "substantially closes the nine findings"; three contracts
  remained inconsistent and three more surfaced. Rev 3 re-pins to HEAD `833767e`, corrects
  MS5 to the final **"Hook commands only"** SAI rule (and inherits the S3a chain/alias/
  malformed-quote corrections), binds the **exact drawer grant schema**, moves the **positive
  approval closure to MS7** (where the only grant minter is built), makes the **ABI inventory
  the real production ABI** (adds `set_script`/`free`/`loop_mark`/`window_alive`/
  `native_pointer`/row-sanitization/cookie ABI + a debug-seam fail-closed decision), gives
  **every popup its own drawer bound to its `window_id` with one shared destroy path and a
  live-drawer-count-of-zero** proof, and adds the **crash-presentation parity** contract. The
  SHOULD items are folded into MS2/MS7.
- **Rev 4** (this): answers RoseCat's review `db02324` ("BLOCKED (docs)" for `a02f1ea`;
  `5bebd42` APPROVED only as the frontmost-application API-name fix), three remaining
  contracts. Rev 4 re-pins to HEAD `176782f`, **moves the positive end-to-end approval
  commit closure out of MS7 into MS8** (where the production CLI/helper/protocol-pump path
  that delivers `tool_use` actually exists, so the chain never injects inside the forbidden
  span or routes through the automation socket) and leaves MS7 owning only native-card
  mint/deny with a **native AppKit `sendEvent:` click** (not "X click"); replaces the prose
  ABI inventory with a **literal export-by-export table of all 75 `webkit_shim.h` exports**
  (every export assigned a slice, including `zb_main_invoke_sync`/`zb_automation_window_id_at`/
  `zb_automation_run_generation`), with a **link-time fail-closed** mechanism for every seam
  not implemented on macOS (an unsupported seam is absent from the macOS shim, so any test or
  caller referencing it fails to link — a build failure, not a silent zero); **moves the
  cookie ABI from MS2c to MS3** so it no longer depends on a slice ordered after it; and
  **splits in-process CGEvent→NSEvent delivery (`-[NSWindow sendEvent:]`, no system post, no
  TCC) from `CGEventPost`** (the former is the spiked-first primary, the latter stays out
  unless a separately approved capability is genuinely needed). It also updates the MS5
  dependency from the superseded `cab60a1` to the approved green `da5eb70`, and fixes the two
  SHOULD items (the stale `21625eb` pin prose and the Linux-idiom "real-X" crash control
  label).

## Rev 4 — how each of RoseCat's 3 rev-3 blockers is answered (review db02324)

RoseCat's `db02324` BLOCKS `a02f1ea` and APPROVES `5bebd42` only as the narrow
frontmost-application API-name correction. Rev-3 blockers #2/#5/#6 were confirmed closed, #1
semantically corrected but dependent on the then-unlanded S3a green (now landed at `da5eb70`),
and #3/#4 left open. Rev 4 answers all three remaining contracts.

| # | Blocker (db02324) | Resolution in rev 4 | Where |
|---|---|---|---|
| 1 | The MS7 positive approval chain starts from the forbidden automation-socket route before the production helper exists; and the Mac action says "X click" | **Moved the positive end-to-end commit closure from MS7.8 to MS8.3**, after MS8 wires the production CLI/helper/protocol-pump that actually delivers `tool_use` (drawer plan :1231-1232, 2013-2020). The `tool_use` now arrives from the fake Anthropic API **through the production proxy and the helper** (same source as MS8.2), not the automation socket, so the forbidden span is never injected and socket separation holds. **MS7.8 now closes only native-card mint/deny** (the native Approve handler mints a valid MS4 grant, Deny mints nothing), triggered by a **native AppKit `-[NSWindow sendEvent:]` click** (not "X click"), observed as grant-minted/not — no helper, no socket | MS7.8 (card mint/deny), MS8.3 (positive commit), MS4 closure pointer |
| 2 | The ABI inventory is neither complete nor executable in its stated order, and gives unsupported semantics to signatures with no error channel; cookie ABI gated on a later slice | Added a **literal export-by-export table of all 75 `webkit_shim.h` exports** with implementing slice + unsupported mechanism + named test. `zb_main_invoke_sync`, `zb_automation_window_id_at` and `zb_automation_run_generation` are now assigned; app/profile/render/drawer/version exports are cross-referenced to their slices. The unsupported mechanism is **link-time absence**: a seam not implemented on macOS is **not compiled into the macOS shim**, so any test or caller that references it **fails to link** (a build failure = fail-closed) — this resolves the `void`/count/`bool` "no error channel" problem, since a void seam cannot signal unsupported at runtime but *can* be absent. Production (non-debug) exports are all implemented; the **cookie ABI (`zb_cookies_*`) moved from MS2c to MS3** (which owns `WKWebsiteDataStore`/`WKHTTPCookieStore`), so it no longer depends on a slice ordered after it | ABI table (MS2 §), MS3, MS4.4 |
| 3 | The CGEvent native-input fallback still contradicts the accepted in-process, non-TCC delivery decision | **Split the two CGEvent uses.** In-process **CGEvent→NSEvent** construction delivered with `-[NSWindow sendEvent:]` (no system post, no TCC) is a **primary delivery path, spiked first** alongside responder-chain `NSEvent`. System-wide **`CGEventPost`** is the only TCC-gated, out-of-process posting, and it **stays out of scope unless a separately approved capability is genuinely needed**. The executable MS2b contract and disposition 1 now state this split explicitly, so no executable contract calls in-process delivery TCC-gated | MS2b.1, disposition 1, rev-2 blocker-3 row |

**Also corrected:** the MS5 dependency citation `cab60a1` → **`da5eb70`** (the approved green S3a
follow-up that actually contains the chain/internal-alias/malformed-quote corrections); the
stale testing-strategy pin prose `21625eb` → `176782f`; and the Linux-idiom crash control label
"real-X/no-input" → **"real-crash/no-input"** (macOS has no window-close "X").

## Rev 3 — how each of RoseCat's 6 rev-2 blockers is answered (review 833767e)

| # | Blocker (833767e) | Resolution in rev 3 | Where |
|---|---|---|---|
| 1 | MS5 still names the superseded SAI rule ("executed-import-graph") | Corrected to the final **"Hook commands only"**: copy dependency/VCS/cache/build trees **unscanned**, HOME-rewrite other copied text, **validate only hook command lines**, warn/skip outbound links; and **inherit** the S3a chain/alias/malformed-quote corrections (da5eb70, BlackRobin — approved green; supersedes the earlier cab60a1 citation per rev 4) rather than port today's defects | MS5.1, MS5.1b, rev-2 table note |
| 2 | Grant tuple weaker than the threat contract | Reuse the drawer plan's **exact** schema: `sha256(tool, window_id, origin, account, target_fp, load_serial, normalized_args)`, 120 s expiry, pre-dispatch revalidation of origin/`load_serial`/`crashed`/`recovering`, `options.expect={account,target_fp}` checked **atomically in the same FIFO ticket** (error **−32015 expectation_mismatch**); add the navigation (`load_serial` change), selector-retarget and one-field-at-a-time mutants (drawer T5) | MS4.1 |
| 3 | Positive closure precedes the only grant minter | MS4 closes the **authority + all negative/refusal/dry-run** paths only; the positive commit closure moves out of MS4 — no test-only mint bypasses the forbidden span. _(Rev 4 note: rev 3 placed the positive closure in MS7.8 from a socket `tool_use`; rev 4 corrected this — MS7.8 proves only native-card mint/deny, and the full commit closure is **MS8.3**, driven by the real helper `tool_use`, since the socket route is forbidden.)_ | MS4 (closure), MS7.8, MS8.3 |
| 4 | "ABI inventory" is not the production ABI | Added `zb_automation_set_script` (private-world injection before first load), `zb_automation_free` (allocator paired with every returned C string), `zb_automation_loop_mark` (ENDED + queued-job cancellation + waiter wake-up on quit), `zb_automation_window_alive`, `zb_native_pointer`, protocol-row field sanitization, and the cookie ABI; **decided** which `zb_automation_debug_*` seams exist on macOS and required unsupported seams to **fail closed** (not silently return zero); added the private-world-install, allocator-pairing, immediate-quit-cancellation and late-completion tests | MS2 inventory, MS2a/b |
| 5 | Window destruction does not close drawer ownership | **Every popup gets its own drawer bound to its `window_id`**; **one shared destroy path** for `webViewDidClose:`, the NSWindow close button and automation close, which **detaches before** the automation notification/free; exact reuse of WebKit's supplied configuration; a **live-drawer count of zero** after all windows close (macOS analog of `zb_drawer_debug_live_count`) | MS2c.5, MS7.9 |
| 6 | Crash-presentation parity absent | Added the macOS crash contract: `webViewWebContentProcessDidTerminate:` + a **public simulated-request crash document** that reports per-window termination, shows a **static** crash document, **keeps the committed URL**, **excludes API-driven termination**, clears `crashed` **only on a real commit**, and **never auto-reloads** (parity with Linux `ddc892e`/`44d0d0f`); with **real-crash/no-input** (rev 4 label) and **clicked-Reload** controls | MS2c.4 |

### SHOULD items folded in (833767e)

No main-thread caller may synchronously wait on a main-queue marshal (MS2); dialogs **hold
completion handlers** rather than running a modal loop (MS2b); health/list snapshots are
**lock/atomic-backed** and never `dispatch_sync` to a hung main queue (MS2c.2); the public
recover spike **tries replacing the WKWebView while retaining its window id** rather than
private SPI (MS2c.3); scroll events may be built from a CGEvent and delivered **in-process**
with `-[NSWindow sendEvent:]` **without** posting to the system or asking for TCC (MS2b);
icon/fold views **intentionally overlap** the page and need **exact hit-testing** even though
the dock does not (MS7); keyboard/fold-row and Secrets-exclusion parity need **named tests**
(MS7); the real-screen runner **fails closed** when Screen-Recording/window-order evidence is
unavailable (MS7, MS8).

## Rev 2 — how each of RoseCat's 9 blockers is answered

| # | Blocker (21625eb) | Resolution in rev 2 | Where |
|---|---|---|---|
| 1 | MS2 closure map is not the full production topology (list/health/dialog/recover branch before the router and take no FIFO turn) | Split into **three** production chains + closure e2es: (a) ordinary routed command, (b) out-of-band `page.list`/`page.health` while a named window's FIFO is stuck, (c) two-phase `recover`; plus an explicit ABI/test inventory and an async-completion ownership contract (copied input, exactly-once, no-dispatch-after-abandon) | MS2, Closure Maps A/B/C |
| 2 | Multi-window / freeze / recovery contracts underspecified | New behaviors: two-hop related-popup chain, per-`window_id` FIFO independence, `page.close` **and** script `window.close()` with opener survival, popups use WebKit's supplied `WKWebViewConfiguration`; a **bounded responsiveness probe/watchdog** not behind the window FIFO; frozen window does not poison siblings; two-phase consent + blast-radius ack + exactly-once cancel + "recovering"; **if public WKWebView APIs can't recover a hung process, MS2c stops at a spike** | MS2b.*, MS2c.* |
| 3 | "native input" has no proven capability contract | MS2b is a **red-first capability spike** (`isTrusted`, focus, click, key, text, contenteditable/`beforeinput` cancel, scroll, pointer move, navigation-during-input, partial typing, deadline abandonment) on **both** Macs; the capability table is updated **only after** it passes; **in-process CGEvent→NSEvent** delivery (`-[NSWindow sendEvent:]`, no system post, no TCC) is a primary path spiked first, while system-wide **`CGEventPost`** is the only TCC-gated use and is out of scope unless a separately approved capability is genuinely needed — never a silent fallback (rev 4 split); the real-screen runner proves its window is frontmost before any native emit | MS2b, disposition 1 |
| 4 | Launch-critical setup / persistence / configuration have no owner | New **MS5 (macOS setup & provisioning)** ports `runAgentSetup` for macOS (immutable `dist-<n>/current/state`, Python runtime/helper, the final **"Hook commands only"** SAI rule — see rev 3 blocker 1, skipped linked skills, no real `~/.claude`/repos, FIFO→fd 3, Keychain onboarding); new **MS3 (config & persistence)** adds an isolated persistent `WKWebsiteDataStore` contract and a decided macOS mapping/explicit-unsupported for `--profile-dir`/`--hardware-acceleration`/`--renderer`/`--media-source` | MS3, MS5 |
| 5 | Shared sandbox interface asserted at the wrong layer ("Zig, platform-neutral") | Corrected: the real seam is **Python** (`agent/host/zb_agent_host/sandbox.py` + `launch.py`, policy/argv) and **C/GLib** (`src/agent_host.c:1-73`, spawn/lifetime/`prctl`). New **MS0** extracts a behavior-preserving `SandboxBackend` seam on **Linux** with its own Linux gate, naming exact files/methods/ownership/wire contract; Seatbelt then implements the same semantic launch spec. Proxy/bridges are rev-16 WIP: MS6 **owns them or depends on a named green landed revision** | MS0, MS6, Shared contract, disposition 4 |
| 6 | Seatbelt failure must block launch and select the VM fallback | The spike proofs (custom-profile acceptance, other-process-info denial, fd-3 reopen, orphan incl. double-fork/`setsid`) are **hard gates before MS8**; **any failure disables Mac agent launch until the shared interface's VM backend is implemented**; the unapproved dedicated-user `kill(-1)` scheme is **removed** as a shipping fallback. MS6 network tests traverse the **production proxy via an e2e-only allowlist seam** (removing the proxy → red); deterministic sacrificial canary | MS6, disposition 3 |
| 7 | Approval / Keychain / chat observability not closed | **Approval grant contract** specified before flows (action+site+account+window+payload binding, one-use, expiry, cancel/refuse, only the native Approve handler mints; negative proofs that page worlds/iframes/popups/socket clients/prompts/hooks cannot approve; per-write confirmation; dry-run no-commit). **Keychain** tests use a disposable service/account + canary, prove the token reaches **only** helper fd 3. **Chat observability** is a gated `--e2e-protocol` native census or screen capture — **never** a production socket drawer-read | MS4, MS5, MS7 |
| 8 | Two-arch and packaging gates can false-green | MS1 provisions **two distinct hosts**, asserts the Intel host is really `x86_64` and the Apple-Silicon host **executes the arm64 slice (not x86 under Rosetta)**, records the **executing arch in production build info**, covers **every bundled native component** (browser, helper, CLI, runtime) and compatible non-exec resources before `lipo`; the runner **fails closed** on no GUI session / wrong arch / missing runtime-SDK / zero assertions; every sub-slice gets a named red test + exact failing assertion + green files + refactor gate | MS1, Testing Strategy |
| 9 | Signing is last but its contract is not release-safe | MS1 **derives and tests a least-privilege entitlement manifest**; MS9 signs nested code **inside-out** then verifies the whole universal bundle **under hardened runtime on both arches before notarization**; until the Developer ID exists the result is called an **ad-hoc development build, not a distributable artifact**; the missing credential is tracked via **Agent Mail / plan status**, not a bead (beads DB is migration-locked) | MS1.3, MS9 |

## Open-question dispositions (accepted from the review)

1. **Native input (rev 4 split):** responder-chain `NSEvent` is a **spike result, not an
   assumption**; the trusted-event matrix (MS2b) decides it. Delivery has **two distinct CGEvent
   uses, not conflated**: (a) **in-process CGEvent→NSEvent** construction delivered via
   `-[NSWindow sendEvent:]` — **no system post, no TCC** — is a **primary path spiked first**
   alongside responder-chain `NSEvent`; (b) system-wide **`CGEventPost`** (out-of-process posting)
   is the **only** TCC-gated use and is **out of scope unless a separately approved capability is
   genuinely needed**. "In-process delivery" is never called TCC-gated.
2. **fd-3 reopen:** `/dev/fd/3` reopening is a **hard MS6 spike gate on both arches**.
3. **sandbox-exec:** custom profiles are a **hard gate**; failure **selects the VM backend and
   blocks MS8**.
4. **Linux extraction:** **yes** — extract the backend interface in its own pre-MS5 slice
   (**MS0**) and keep the Linux gate isolated.
5. **MS2 split:** keep **MS2a/MS2b/MS2c as separate reviewed gates**, and split the out-of-band
   health/recover closure from crash-page presentation if one commit cannot keep a single red
   seam.

## Overview

macOS is launch-critical (most users on Mac). Today zigBrowser has a working macOS
app/window/render/IPC seam only (`src/wkwebview_shim.m`, 6 of ~76 C-ABI functions; bead
`zigBrowser-8g7` proved render + ping/pong on a real Intel Mac). Everything a launch needs
beyond opening a window — automation, multi-window/freeze/recovery, native input, site
flows, approval, the AppKit drawer, setup/persistence/config, the OS-native sandbox, the
agent helper, and signed universal packaging — does not exist on macOS. This plan turns the
research map (`…/research/2026-10-14-14-19-macos-launch-support-surface.md`, 1df5dce) into
small, red-first, gated slices. House conventions follow the drawer plan: small slices, one
gate each, native work lands with its adapter in the same slice, a real-binary e2e ends every
slice, UI slices need a real-screen check on the user's hardware, and a slice is not done
until its closure e2e was **observed to execute** with nonzero assertions (a "SKIP" is
UNCLOSED).

## Current State Analysis

### Key discoveries (research 1df5dce + review 21625eb, verified file:line)

- One C ABI, three backends: `resolveBackend` build.zig:1107-1114;
  `configureMacosBackend` build.zig:1174-1184 (compiles `wkwebview_shim.m` `-fobjc-arc`, links
  WebKit/Cocoa/Foundation); `CheckMacosBackendStep` build.zig:79-105.
- macOS shim = 6 core fns (wkwebview_shim.m:788/834/838/853/872/880) + `zb_policy_decide`
  (nav_policy.zig:40) + `zb_ipc_dispatch` (ipc.zig:41). None of the ~70 `zb_automation_*`/
  `zb_native_*`.
- The single `PagePort` impl is Linux-gated (automation_gtk_port.zig:22); `pagePort()`→null off
  Linux (:39-41). Server/router/engine/queue/recover/flows/token-sidecar are platform-neutral
  Zig.
- **Out-of-band server paths (review):** `page.list`/`page.health` branch **before** router
  parsing at `automation_server.zig:480-487` and deliberately **take no FIFO turn**
  (`automation_server.zig:686-691`); dialog discovery and two-phase recover have their own
  server paths (`handleDialogs` :1123-1180; `handleRecover` :942-1106). The MS2 closure cannot
  be a single chain.
- Capability table models macOS: `.wkwebview = { js_synthetic, network unsupported
  (no_platform_api) }` (automation_platform.zig:90-95). **Rev 2:** this entry is changed only
  after MS2b's trusted-event matrix passes.
- Native input on Linux is toolkit-path (`gdk_event_new` + `gtk_main_do_event`
  webkit_shim.c:3373), not XTEST; the macOS NSEvent path is a **spike** (MS2b), not an assumed
  equivalent.
- **Config/persistence/setup are Linux-only (review):** `runAgentSetup` refuses every non-Linux
  OS (`app.zig:41-47`) and uses `/proc/self/exe`; `--profile-dir` is discarded off Linux
  (`app.zig:160-166`); render/media flags are silent no-ops (`webkit.zig:47-72`).
- **The sandbox seam's real layer (review):** policy/argv is **Python**
  (`agent/host/zb_agent_host/sandbox.py`, `launch.py`); the spawn/lifetime seam is **C/GLib**
  with `prctl` (`src/agent_host.c:1-73`). There is **no** existing Zig sandbox abstraction. The
  token route FIFO→socketpair→fd 3 is portable POSIX (token.py:63-134). `--unshare-net` + the
  host allowlist proxy + the two bridges are **rev-16 WIP**, not built.
- Packaging ships an ad-hoc `.dmg` (`codesign --force --sign - --deep`,
  packaging/macos/build-dmg.sh:90); `Info.plist` `LSMinimumSystemVersion 13.0`. No Developer
  ID, hardened runtime, entitlements, notarization, or universal binary; M9 was Intel-only.
- Drawer is 100% GTK3 widgets (agent_drawer.c; portable logic agent_drawer.zig:16-181); secrets
  via libsecret `dlopen` (agent_secrets.c); isolated from page JS structurally. The approval
  card is **unimplemented** (research + review). The NVIDIA real-screen lesson (drawer plan
  §7.1) applies to macOS GPU compositing too.
- e2e harness is Xvfb/X11-bound (xsession.py, xinput.py); macOS tests are three `m9_*` run
  remotely (tests/mac/gate.sh:24-44). The cross-target no-backend integrity test `713587b` is
  green (review line 135). Baseline for this plan: a clean archive of the pin before the plan
  passed **106/106 steps, 817/817 tests** under private Xvfb (review line 7200).

## Desired End State

A Mac user installs a **Developer-ID-signed, hardened-runtime, notarized universal** zigBrowser
and can: open pages with an isolated persistent data store; drive the full automation API
(including multi-window, freeze/recovery, dialogs, popups) with the same client contract and
per-window FIFO semantics as Linux; use native input proven trusted by a capability matrix;
run site flows with a fully specified per-action approval grant; use a native AppKit drawer
(docked, movable "S" icon, fold animation, Keychain secrets) isolated from page worlds; and
run the Claude agent inside an **OS-native Seatbelt sandbox** (behind one shared backend
contract) whose security proofs are hard launch gates that select the VM backend on failure.
Verified by real-binary e2e on **both** remote Macs and by the user's eyes on screen. The
ad-hoc development build is explicitly **not** a distributable artifact; MS9 produces the
distributable one once the user has a Developer ID.

## What We're NOT Doing

- Not changing Linux GTK behavior; MS0's extraction is behavior-preserving and the Linux gate
  stays green.
- Not shipping the VM sandbox in this plan **as the primary path** — but MS6 **requires** the VM
  backend to exist behind the shared contract **before Mac agent launch** if any Seatbelt proof
  fails (it is not deferred to a later bead when it gates launch).
- Not shipping the unapproved dedicated-agent-user `kill(-1)` orphan scheme (removed from rev 1).
- Not exposing native drawer text through a production automation socket read (chat observation
  is `--e2e-protocol` native census / screen capture only).
- Not calling any ad-hoc build a distributable artifact; not obtaining the Apple Developer ID
  (user action); MS9 is gated on it and tracked via Agent Mail / plan status.
- Not running anything on the user's local `DISPLAY :0`, live profile, or live sockets.
- Not building a Windows drawer / Windows automation parity (separate track).

## Testing Strategy

- **Frameworks:** Zig `std.testing`; Python e2e driving the real binary via the Python SDK over
  the automation Unix socket; ObjC behavior asserted through the C ABI / e2e (no separate ObjC
  runner).
- **macOS harness (new):** `tests/e2e/mac_session.py` (macOS analog of `xsession.py`; real
  `NSWindow`, **no Xvfb/DISPLAY**; guards the process tree; sets `ZIGBROWSER_SOCKET`). A
  two-host, two-arch `tests/mac/gate.sh`.
- **Fail-closed runner (blocker 8):** the runner **exits nonzero** (never SKIP-to-green) when a
  host lacks an active GUI session, is not the expected native architecture (not Rosetta),
  lacks a required runtime/SDK, or when a test records zero assertions.
- **Arch-execution proof (blocker 8):** assert the Intel host reports `x86_64` and the
  Apple-Silicon host **executes the arm64 slice**; the running app records its **executing
  arch in production build info**; `lipo -archs`/`--version` alone are insufficient.
- **Native input (blocker 3):** a red-first trusted-event matrix on both Macs decides the
  capability; the table is updated only after it passes; any real-screen input script proves its
  own window is focused/viewable/topmost at the target and aborts under a server/grab-equivalent
  guard (drawer plan §7.1, `test_real_screen_input.py` model).
- **Network (blocker 6):** the fake Messages/Anthropic API is reached **through the production
  proxy** via an `--e2e-protocol` allowlist seam; removing/bypassing the proxy turns the test
  **red**. Direct loopback decoy, LAN, public IP, DNS, WindowServer/CGEvent/screen capture,
  non-allowlisted host and workspace write must **fail**; only the proxy, `:51091`, `:31337`
  succeed.
- **Keychain (blocker 7):** disposable `Security.framework` service/account + canary token,
  never a real credential; prove the token reaches **only** helper fd 3 — not env, argv, logs,
  telemetry, hook env, or model context.
- **Chat observability (blocker 7):** assert via a gated `--e2e-protocol` native drawer census
  or screen capture, never a production socket drawer-read API.
- **Real-screen (UI slices):** macOS cases in the real-screen check, run by the orchestrator on
  the user's Mac; a UI slice is not approved until it passes there.
- **Closure tests** are Tier-1 real-binary e2e; ClosureMaps pinned to HEAD 176782f (all three
  JSON maps re-pinned in rev 4). **Both arches every run.**

## Shared sandbox backend contract (corrected layer — blocker 5)

The sandbox seam is **not** a Zig abstraction. Today it is:

- **Policy/argv (Python):** `agent/host/zb_agent_host/sandbox.py` (`helper_argv`, the bwrap argv,
  `STATE_DIRS`, binds) and `launch.py` (`build_argv`, `os.execv(bwrap, …)`); the per-hook nested
  profile is `hook_run.py`; seccomp is `seccomp.py`.
- **Spawn/lifetime (C/GLib):** `src/agent_host.c:1-73` (`g_spawn_sync` with the `die_with_browser`
  child-setup hook and `prctl(PR_SET_PDEATHSIG)`).

**MS0** defines a **`SandboxBackend` semantic launch spec** and refactors the Linux code behind
it **without behavior change**, naming the exact files, methods, ownership, and wire contract:

- Launch spec (the contract both Linux and macOS satisfy): the broker byte stream; the token
  channel (FIFO then fd 3, never env); the host allowlist-proxy endpoint (`api.anthropic.com` +
  census-proven CLI domains, fail-closed) and the two bridge ports (51091, 31337); the shares
  (agent home read-only, workspace read-only, scratchpad read-write); a per-hook confinement
  launcher; and a lifetime contract (everything dies with the browser).
- Ownership: the **Python** side owns policy/argv/profile generation; the **C** side owns spawn +
  parent-death; the **host** side (shared, Linux+macOS) owns the proxy, bridges, in-process
  broker, and approval logic.
- Implementations: **Linux** = bwrap (MS0 extraction, behavior-preserving); **macOS Seatbelt** =
  SBPL profile + app-side hook launcher (MS6); **VM** = the fallback behind the same spec,
  required before Mac agent launch if Seatbelt's proofs fail (MS6).
- Dependency note: the proxy/bridges are **rev-16 WIP**. MS6 either **owns** them or **depends on
  a named, green, landed Linux revision** that provides them; the plan does not treat them as an
  already-existing dependency.

---

## MS0: Extract the Linux sandbox-backend seam (pre-MS5, behavior-preserving, Linux gate)

**Goal (blocker 5, disposition 4).** Factor the Linux sandbox policy/argv (Python) and
spawn/lifetime (C) behind the `SandboxBackend` launch spec with **no behavior change**, so
Seatbelt can implement the same spec. Its gate is the existing Linux gate — it must stay green.

### Behavior MS0.1: the Linux backend implements the spec with identical argv
**Given** the current bwrap argv (`sandbox.py helper_argv`) and spawn (`agent_host.c`),
**When** they are moved behind a `SandboxBackend` interface (a Python `LinuxBwrapBackend` +
the parameterized C spawn seam),
**Then** the generated argv, binds, seccomp fd, and spawn/parent-death behavior are **byte-for-
byte** what they are today (golden-argv test), and the full Linux gate stays **106/106,
817/817**.

- **Files touched:** `agent/host/zb_agent_host/sandbox.py` (extract `SandboxBackend`
  protocol + `LinuxBwrapBackend`), `launch.py`, `src/agent_host.c` (parameterize the spawn
  seam), new `agent/host/tests/test_backend_contract.py`.
- **Property:** oracle — for any `(home, workspace, route, extra_ro)` the new backend's argv
  equals the pre-refactor `helper_argv` output (compare against a captured golden).
- 🔴 Red: `test_backend_contract.py` asserts the `SandboxBackend` type exists and that
  `LinuxBwrapBackend.launch_spec(...)` reproduces the golden argv; red today (no such type).
- 🟢 Green: introduce the protocol + adapter with no argv change.
- 🔵 Refactor: one argv builder, no duplication between `launch.py` and `sandbox.py`.
- **Closure:** LEAF (pure argv/spec construction, platform-neutral Python; the real spawn is
  already covered by the existing Linux contract e2es, unchanged).

**Gate (MS0):** the existing Linux gate (`agent-host-unit`, `agent-host-contract`, all e2es) +
the new golden-argv test. **No macOS work.** Coordinate with **BlueBeaver** (helper/sandbox).

---

## MS1: Universal build + two-arch remote gate (false-green-proof) + entitlement manifest

**Goal (blockers 8, 9-part).** A universal (arm64 + x86_64) build, a two-host two-arch gate that
cannot false-green, and a tested least-privilege entitlement manifest so MS9 is small.

### Behavior MS1.1: universal fat Mach-O covering every bundled native component
**Given** both Macs reachable,
**When** each arch builds natively and the slices are combined,
**Then** the browser executable **and every bundled native component** (the Python runtime, the
Claude CLI, the helper launcher) are present per arch, their non-executable resources are
verified compatible before `lipo -create`, and the result is a fat Mach-O with both slices.

### Behavior MS1.2: real two-host identity + executing-arch proof (no Rosetta false-green)
**Given** two distinct hosts,
**When** the gate runs,
**Then** it asserts the Intel host is really `x86_64` and the Apple-Silicon host **executes the
arm64 slice** (not an x86 process under Rosetta — check `sysctl.proc_translated`/
`NSBundle`/`mach` arch at runtime), and the running app records its **executing architecture in
production build info** read back over the socket; `lipo -archs` + `--version` alone do not pass.

### Behavior MS1.3: tested least-privilege entitlement manifest (release-safe seed for MS9)
**Given** the features MS2–MS8 will need,
**When** the bundle is built ad-hoc,
**Then** `packaging/macos/entitlements.plist` holds an **exact least-privilege** manifest
(network client; the specific keys the Seatbelt launcher and helper need — derived, not "whatever
it needs"), `codesign -d --entitlements -` lists exactly those, and the ad-hoc build still
verifies. The manifest is the single source MS9 signs with.

### Behavior MS1.4: the runner fails closed
**Given** the fail-closed conditions,
**When** a host lacks a GUI session / the expected arch / a required runtime-SDK, or a test
records zero assertions,
**Then** the gate **exits nonzero** (never SKIP-to-green), per host and per arch.

- **Files touched:** `build.zig` (`mac-universal`, no `-Dtarget`), `tests/mac/build-on-mac.sh`,
  `packaging/macos/build-dmg.sh` (lipo + verify compatible resources), `packaging/macos/entitlements.plist`
  (new), `packaging/macos/Info.plist`, `tests/mac/gate.sh` (two-host matrix + fail-closed),
  `tests/e2e/mac_universal_test.py`, `src/*` build-info (record executing arch).
- 🔴 Red: `mac_universal_test.py` asserts both slices exist, each component is fat, the executing
  arch matches the host, build info reports it, and the entitlements file lists the exact keys —
  red today. 🟢 Green: per-arch build + lipo + arch-record + entitlements. 🔵 Refactor: one
  per-arch build fn shared by `gate.sh`/`build-dmg.sh`; one signing fn (ad-hoc now, Developer ID
  in MS9) selected by flag.
- **Closure:** LEAF (packaging/build-info assertions; no cross-process product behavior).

**Gate (MS1):** two-host `mac-gate`, fail-closed; Linux gate untouched. Not a UI slice.
Coordinate with **BlueBeaver** (build/gate) and **BlackRobin** (version/build-info seam).

---

## MS2: WKWebView PagePort adapter + automation ABI (three gated parts, three closure maps)

**Goal (blockers 1, 2, 3; dispositions 1, 5).** Implement the automation surface on macOS with
the **same client contract and per-window FIFO semantics** as Linux, proven by **three** distinct
production chains. Native work lands with its adapter in the same part. Three separate reviewed
gates: **MS2a** (routed dom/page + eval/readiness), **MS2b** (native-input capability spike +
dialogs), **MS2c** (multi-window/popups + freeze/recovery; split crash-page presentation off if a
single red seam can't hold).

### Design
- New `src/automation_wk_port.zig` implements `PagePort` (gated `os.tag == .macos`), wired in
  `buildAutomationConfig` (app.zig:220-237) beside the GTK port.
- `wkwebview_shim.m` gains the `zb_automation_*`/`zb_native_*` functions against WKWebView, the
  automation script in a **private `WKContentWorld`** (not `pageWorld`), and a main-thread marshal
  mirroring Linux's `auto_queue_on_gtk`/`auto_job_wait` (webkit_shim.c:1692-1812):
  `dispatch_async(main)` + a bounded, deadline-guarded wait.
- **Async-completion ownership contract (blocker 1), asserted per function:** every asynchronous
  Objective-C completion **copies its inputs** (no borrowed Zig memory after return), fires
  **exactly once**, and a **no-dispatch / no-write guard** prevents any effect after the waiter
  abandons on deadline (the macOS analog of the GTK generation/`auto_job` guard).

### Explicit ABI / test inventory (blockers 1, 4; rev 4 — literal export-by-export table)

This is the **complete production ABI** — **all 75 `webkit_shim.h` exports** at the pin
`176782f`, each assigned an implementing slice, an **on-macOS status / unsupported mechanism**,
and a **named test**. "Every `webkit_shim.h` export" is now literal, not a representative subset
(rev 3 blocker 4; rev 4 completeness).

**Unsupported mechanism (uniform, rev 4):** a seam that is **not implemented on macOS is absent
from the macOS shim at link time** — it is simply not compiled into `wkwebview_shim.m`, so any
test or caller that references it **fails to link** (a build failure = fail-closed). This is the
*exact* mechanism, and it is what resolves the rev-3 "no error channel" objection: a `void`,
count- or `bool`-returning seam cannot carry a runtime "unsupported" sentinel, but it *can* be
absent, and absence fails the build louder than any sentinel. The only exports with a runtime
unsupported path are the **config flags** (MS3.2), which return an explicit negative error +
`out_err` "unsupported on macOS" rather than a silent accept. No seam silently returns zero.

#### Production (non-debug) exports — 44, all implemented on macOS

| Export | Ret | Slice | On macOS | Named test |
|---|---|---|---|---|
| `zb_run_open` | int | MS1 | impl (launch) | `mac_universal_test` |
| `zb_app_run` | int | MS1 | impl — the `[NSApp run]` closure driver | every e2e driver (Closure A/B/C) |
| `zb_run_screenshot` | int | MS2b | impl | `mac_screenshot_test` |
| `zb_version_line` | void | MS1 | impl — records executing arch in build info | `mac_universal_test` (MS1.2) |
| `zb_window_new` | ptr | core + MS7 | impl — window create; drawer mount point | mac render e2e + MS7 drawer e2e |
| `zb_reload` | void | MS2a | impl | MS2a.1 |
| `zb_main_invoke_sync` | int | **MS2a** | impl — the main-thread marshal primitive (macOS analog of `auto_queue_on_gtk`) | MS2a.3 async-completion ownership tests |
| `zb_policy_decide` | int | exists; MS2a consumer | impl (`nav_policy.zig`) | mac nav-policy e2e |
| `zb_ipc_dispatch` | int | exists (core) | impl (`ipc.zig`) — ping/pong (bead 8g7) | existing `m9_*` e2e |
| `zb_app_set_profile_dir` | int+err | MS3.1 | impl | `mac_profile_persist_test` |
| `zb_app_set_hw_policy` / `zb_app_get_hw_policy` | void / int | MS3.2 | WKWebView mapping **or** explicit unsupported-on-macOS error (int<0 + `out_err`) | `mac_config_flags_test` |
| `zb_app_set_media_source` / `zb_app_get_media_source` | void / int | MS3.2 | mapping (MSE-off via `WKPreferences`) **or** explicit unsupported | `mac_config_flags_test` |
| `zb_app_set_agent_drawer` / `zb_app_get_agent_drawer` | void / int | MS7 | impl — drawer on/off | mac drawer e2e |
| `zb_automation_set_script` | void | MS2a | impl — private `WKContentWorld`, before first load | MS2a.2 |
| `zb_automation_eval_json` | int+out | MS2a | impl | Closure A / MS2a.1 |
| `zb_automation_navigate` / `_navigate_guarded` / `_reload` | int | MS2a | impl (incl. `beforeunload`) | MS2a.1 |
| `zb_automation_get_url` / `_get_title` | int+out | MS2a | impl | MS2a.1 |
| `zb_automation_free` | void | MS2a | impl — allocator paired with every returned C string | allocator-pairing test (MS2a) |
| `zb_automation_loop_mark` | void | MS2a | impl — ENDED + queued-job cancel + waiter wake on quit | immediate-quit-cancellation test (MS2a) |
| `zb_automation_window_alive` | int | MS2a | impl | MS2a window test |
| `zb_automation_window_id_at` | uint32 | **MS2a** | impl — window-registry enumeration (backs `list`/`alive`) | MS2a window-registry test |
| `zb_automation_run_generation` | uint32 | **MS2a** | impl — the generation counter the no-dispatch-after-abandon guard reads (macOS analog of the GTK generation guard) | MS2a.3 late-completion test |
| `zb_automation_list_dialogs` / `_respond_dialog` | int | MS2b | impl — `WKUIDelegate` (incl. beforeunload) | MS2b.2 |
| `zb_automation_list_windows` / `_close_window` / `_recover_windows` | int | MS2c | impl | MS2c.1 / MS2c.3, Closure B / C |
| `zb_cookies_get_all` / `_add` / `_delete` | int | **MS3** (moved from MS2c) | impl over `WKHTTPCookieStore` (the MS3 data-store owner); MS4.4 login gate consumes | `mac_cookie_test` (MS3) |
| `zb_set_input_files` | int | MS2b | impl — incl. regular-file refusal | MS2b input-files test |
| `zb_screenshot_png` | int | MS2b | impl — full-page | MS2b screenshot test |
| `zb_native_scroll` / `_move` / `_pointer` / `_click` / `_key` / `_text` | int | MS2b | impl — in-process NSEvent / CGEvent→NSEvent via `-[NSWindow sendEvent:]` (no post, no TCC) + pointer cache | MS2b.1 |

> **`zb_cookies_*` moved from MS2c to MS3 (rev 4 blocker 2):** the cookie ABI is implemented by
> the slice that owns the `WKWebsiteDataStore`/`WKHTTPCookieStore` (MS3), so the inventory no
> longer gates a cookie export "via MS3's port" while sitting in a slice (MS2c) ordered *before*
> MS3. MS2c no longer lists the cookie ABI; MS4.4 is the login-gate consumer.

#### Debug seams — 31 (`zb_automation_debug_*` ×30 + `zb_drawer_debug_live_count`)

Debug seams are **test-only**. Per rev 4, a debug seam is compiled into the macOS shim **only in
the slice whose named e2e actually drives it**; every debug seam **not** promoted is **absent at
link time** (fail-closed — a referencing test/caller fails to build). No debug seam carries a
runtime "unsupported" sentinel (most are `void`/count/`bool` and have no channel); **absence is
the mechanism**, and each slice's gate records exactly which seams it promoted.

| Debug seam(s) | Promoting slice (impl) — else absent at link time | Drives |
|---|---|---|
| `zb_drawer_debug_live_count` | MS2c.5 / MS7.9 | live-drawer-count-of-zero after all windows close |
| `zb_automation_debug_live_jobs`, `_waiter_grace` | MS2a | late-completion-after-timeout / abandon window |
| `zb_automation_debug_next_window_id`, `_destroy_window`, `_window_work`, `_close_on_motion`, `_close_on_key` | MS2c | deterministic ids, synthesized destroy, per-window work, close-during-input |
| `zb_automation_debug_native_guard_hold`(`_hits`), `_native_preguard`, `_native_skipped`, `_pointer_lost` | MS2b | native-input guard / abandon / pointer-cache invalidation |
| `zb_automation_debug_png_write_hold`, `_png_stopped`, `_png_deadline_stops`, `_png_ignore_abandon`, `_shot_after_measure`, `_shot_postcapture_refusals` | MS2b (only if its screenshot-abandon e2e lands on macOS) | screenshot deadline/abandon/measure |
| `zb_automation_debug_files_hold`, `_files_unmatched`(`_hits`), `_files_late_cancels`, `_files_preclick` | MS2b (only if its input-files e2e lands) | input-files timing/cancel |
| `zb_automation_debug_dialog_policy_hold`, `_dialog_policy_scheduled` | MS2b | dialog policy timing |
| `zb_automation_debug_cookie_delay`(`_hits`) | MS3 | cookie-store race |
| `zb_automation_debug_hw_policy`, `_webkit_default_hw_policy`, `_media_source` | MS3.2 (only where the flag is supported on macOS) | config-effect read-back |

### MS2a behaviors (routed commands)
- **MS2a.1** `page.navigate` + `page.url`/`page.title` over the socket (same envelope/auth/errors
  as automation_server.zig:412-530).
- **MS2a.2** `dom.*` via the **private** WKContentWorld; the page world cannot see or spoof the
  automation globals (**property: metamorphic** — a page that redefines `window.__zbAutomation`
  does not change the result).
- **MS2a.3** startup readiness, late completion after timeout (the guard drops it), and
  result/error-string ownership (no use-after-free; strings owned by the caller side).

### MS2b behaviors (native-input capability spike + dialogs) — red-first, both Macs (blocker 3)
- **MS2b.1 (spike)** the trusted-event matrix: `event.isTrusted` true, focus, click, key, text,
  contenteditable + `beforeinput` cancellation honored, scroll, pointer movement, navigation
  during input, partial typing, and **deadline abandonment** (no dispatch after the waiter
  leaves). **The capability table entry (automation_platform.zig:90-95) is changed only after
  this passes.**
  - **Delivery contract (rev 4 — two CGEvent uses kept distinct, blocker 4):** the spiked-first
    primary delivery is **responder-chain `NSEvent`** and, where an event type needs it, an
    **in-process CGEvent→NSEvent** construction delivered with `-[NSWindow sendEvent:]` — both
    stay **in-process with no system post and no TCC**. These are what MS2b must prove first.
  - System-wide **`CGEventPost`** (posting to the window server out-of-process) is a **different
    thing**: it is the only TCC-gated use, and it is **out of scope unless a separately approved
    capability is genuinely needed** for an event type that neither in-process path can deliver.
    If such a need is documented, its real-screen runner obtains permission and verifies its app
    is frontmost before emitting — never a silent default, and never conflated with the in-process
    paths above.
- **MS2b.2** dialogs (alert/confirm/prompt/beforeunload) captured by the `WKUIDelegate` and
  answered via the ABI (analog of webkit_shim.c:4523-4625).

### MS2c behaviors (multi-window / freeze / recovery) — blocker 2
- **MS2c.1** a **two-hop related-popup chain**: `window.open` twice; the popups use **WebKit's
  supplied `WKWebViewConfiguration`** (process-pool/data-store/content-world intentional); each
  gets its own `window_id`; routing a command to each proves **per-window FIFO independence**;
  the opener's URL and DOM survive both `page.close` **and** script `window.close()`.
- **MS2c.2** a **bounded responsiveness probe/watchdog** updates per-window state **without
  waiting behind that window's FIFO**; one frozen window **does not poison siblings**
  (`webViewWebContentProcessDidTerminate:` reports termination, not liveness, so a separate
  bounded probe is named). **SHOULD:** the health/list snapshot is **lock/atomic-backed** and
  **never `dispatch_sync`** to a possibly-hung main queue; no main-thread caller synchronously
  waits on the main-queue marshal.
- **MS2c.3** recovery of a **hung** WKWebView via a **named public-API mechanism**, retaining the
  two-phase consent, blast-radius acknowledgement, exactly-once queued-job cancellation, and
  "recovering" errors (automation_server.zig:810-1106); **no automatic kill**. **SHOULD:** the
  spike first tries **replacing the WKWebView while retaining its `window_id`** (new view, same
  id, re-mount its drawer per MS2c.5) rather than private SPI. **If no public WKWebView API can
  recover a hung content process, MS2c stops at a documented spike** and the plan does not assume
  a reload recovers it.
- **MS2c.4 (crash-presentation parity — blocker 6):** on `webViewWebContentProcessDidTerminate:`,
  the macOS shim **reports per-window termination**, shows a **static crash document** via a
  **public simulated-request** load (not a private reload), **keeps the committed URL**,
  **excludes API-driven termination** (`terminated_by_api` is not a crash), clears the `crashed`
  flag **only on a real load commit**, and **never auto-reloads** — parity with the Linux product
  (`ddc892e`, `44d0d0f`; the about:blank crash-page follow-up). Controls: a **real-crash/no-input**
  case (a genuine content-process termination, then the crash DOM + list state persist with **no
  input** for a bounded hold — rev 4 renamed from the Linux idiom "real-X", since macOS has no
  window-close "X") and a **clicked-Reload** case (recovery only on the user's click). A 3-second
  automatic-reload mutant must be **killed** by the no-input control.
- **MS2c.5 (drawer ownership on window destruction — blocker 5):** **every popup receives its own
  drawer bound to its `window_id`** (when the drawer is on), built on WebKit's **supplied**
  `WKWebViewConfiguration`. There is **one shared destroy path** for `webViewDidClose:`, the
  NSWindow close button, and an automation `page.close`, which **detaches the drawer and frees it
  before** the automation close notification/C-struct free (detach-before-notify/free ordering).
  After **all** windows close, a **live-drawer count of zero** is asserted (the macOS analog of
  `zb_drawer_debug_live_count`, per the MS2 debug-seam decision). The opener's URL and DOM survive
  a child's destruction (ties to MS2c.1).

### Workflow Closure (three chains — blocker 1)

#### Closure A — ordinary routed command   [BLOCKING: Zig→ObjC boundary + async WK completion edge]
- **Chain:** `socket -> handleRequestWith (:412) -> router.parse (:503) -> queue.acquire (:518) -> engine.executeWith (:526) -> PagePort(automation_wk_port) -> wk_shim zb_automation_eval_json (dispatch to WK main) -> WKWebView effect -> zb_automation_eval_json read -> JSON-RPC result`
- **SOURCE (seed):** the page loaded via `zb_automation_navigate_guarded` (macOS, MS2a). **TRIGGER:**
  `handleRequestWith` (automation_server.zig:412, outermost; above `highest_new_connector =
  automation_wk_port`). **DRIVER:** the real `[NSApp run]` loop (`zb_app_run`
  wkwebview_shim.m:788). **OBSERVE:** `zb_automation_eval_json`. **FORBIDDEN SPAN:** router,
  queue, engine, port, adapter, shim. **RED-AT-SEAM:** with the adapter absent, `pagePort()`→null
  returns the documented `unsupported` data; the DOM-change assertion is red until MS2a lands.

```json
{
  "behavior": "An ordinary routed automation command drives the live WKWebView page and its result is observable to the client.",
  "git_commit": "176782f7d558d51eae12e5520e4f0ca99c2f0814",
  "repo": "/home/maceo/ntm_Dev/zb-automation-integration-2026-10-10-11-59",
  "nodes": [
    { "id": "loaded_page",         "module": "src/wkwebview_shim.m",         "is_entrypoint": false, "adds_or_changes": true,  "read_path": null,                     "seedable_store": "zb_automation_navigate_guarded" },
    { "id": "socket_request",      "module": "src/automation_server.zig",    "is_entrypoint": true,  "adds_or_changes": false, "read_path": null,                     "seedable_store": null },
    { "id": "router_command",      "module": "src/automation/router.zig",    "is_entrypoint": false, "adds_or_changes": false, "read_path": null,                     "seedable_store": null },
    { "id": "engine_execute",      "module": "src/automation/engine.zig",    "is_entrypoint": false, "adds_or_changes": false, "read_path": null,                     "seedable_store": null },
    { "id": "pageport_call",       "module": "src/automation/page_port.zig", "is_entrypoint": false, "adds_or_changes": false, "read_path": null,                     "seedable_store": null },
    { "id": "wk_port_adapter",     "module": "src/automation_wk_port.zig",   "is_entrypoint": false, "adds_or_changes": true,  "read_path": null,                     "seedable_store": null },
    { "id": "wk_shim_effect",      "module": "src/wkwebview_shim.m",         "is_entrypoint": false, "adds_or_changes": true,  "read_path": null,                     "seedable_store": null },
    { "id": "observable_readback", "module": "src/wkwebview_shim.m",         "is_entrypoint": false, "adds_or_changes": true,  "read_path": "zb_automation_eval_json", "seedable_store": null }
  ],
  "edges": [
    { "is_async": false, "cross_boundary": false, "driver": null },
    { "is_async": false, "cross_boundary": false, "driver": null },
    { "is_async": false, "cross_boundary": false, "driver": null },
    { "is_async": false, "cross_boundary": false, "driver": null },
    { "is_async": false, "cross_boundary": true,  "driver": null },
    { "is_async": true,  "cross_boundary": true,  "driver": "zb_app_run" },
    { "is_async": false, "cross_boundary": false, "driver": null }
  ]
}
```

#### Closure B — out-of-band `page.health`/`page.list` while a sibling window's FIFO is stuck   [BLOCKING: proves the no-FIFO-turn branch + sibling isolation]
- **Chain:** `socket -> handleRequestWith (:412) -> handleWindows branch (:480-487, NO queue.acquire :686-691) -> ext.listWindows / responsiveness probe (MS2c bounded watchdog) -> wk_shim per-window state -> page.health JSON read`
- **SOURCE (seed):** two loaded windows **and** a long-running routed command in flight on
  window 1 (so window 1's FIFO is occupied). **TRIGGER:** `handleRequestWith` (:412). **DRIVER:**
  the MS2c bounded probe/watchdog + the `[NSApp run]` loop (no sleep). **OBSERVE:** `page.health`/
  `page.list` JSON for **both** windows. **FORBIDDEN SPAN:** the stuck window's FIFO/queue —
  health/list must **not** wait behind it. **RED-AT-SEAM:** if health is implemented behind the
  per-window FIFO, the stuck window makes the sibling's health time out → red; correct = both
  return promptly.

```json
{
  "behavior": "page.health/page.list answer for all windows without waiting behind a sibling window's stuck FIFO.",
  "git_commit": "176782f7d558d51eae12e5520e4f0ca99c2f0814",
  "repo": "/home/maceo/ntm_Dev/zb-automation-integration-2026-10-10-11-59",
  "nodes": [
    { "id": "two_windows_one_stuck", "module": "src/wkwebview_shim.m",      "is_entrypoint": false, "adds_or_changes": true,  "read_path": null,               "seedable_store": "zb_automation_navigate_guarded" },
    { "id": "socket_health_request", "module": "src/automation_server.zig", "is_entrypoint": true,  "adds_or_changes": false, "read_path": null,               "seedable_store": null },
    { "id": "handle_windows_branch", "module": "src/automation_server.zig", "is_entrypoint": false, "adds_or_changes": false, "read_path": null,               "seedable_store": null },
    { "id": "wk_responsiveness",     "module": "src/wkwebview_shim.m",      "is_entrypoint": false, "adds_or_changes": true,  "read_path": null,               "seedable_store": null },
    { "id": "health_json",           "module": "src/automation_server.zig", "is_entrypoint": false, "adds_or_changes": false, "read_path": "handleWindows",    "seedable_store": null }
  ],
  "edges": [
    { "is_async": false, "cross_boundary": false, "driver": null },
    { "is_async": false, "cross_boundary": false, "driver": null },
    { "is_async": true,  "cross_boundary": true,  "driver": "zb_app_run" },
    { "is_async": false, "cross_boundary": false, "driver": null }
  ]
}
```

#### Closure C — two-phase recover of a hung window   [BLOCKING: cross-process terminate + reload, two-phase consent]
- **Chain:** `socket -> handleRecover (:942-1106, NO queue turn) -> phase1 issue incident token -> phase2 consume + beginRecovery (exactly-once cancel) + recoverWindows -> wk_shim terminate+reload (named public API) -> page.health/page.url read`
- **SOURCE (seed):** a frozen window + its process family. **TRIGGER:** `handleRecover` (:942).
  **DRIVER:** the `[NSApp run]` loop + the bounded probe. **OBSERVE:** post-recover `page.url`/
  `page.health`. **FORBIDDEN SPAN:** the recover state machine, the terminate/reload. **RED-AT-
  SEAM:** a wrong incident token / stale blast-radius ack must return `unknown`/`mismatch`
  (automation_server.zig:872-902); an automatic kill (no consent) must be **absent**. If no public
  API recovers a hung process, this closure is **not green** and MS2c stops at a spike.

```json
{
  "behavior": "A hung WKWebView window is recovered only via two-phase consent, with exactly-once job cancellation and no automatic kill.",
  "git_commit": "176782f7d558d51eae12e5520e4f0ca99c2f0814",
  "repo": "/home/maceo/ntm_Dev/zb-automation-integration-2026-10-10-11-59",
  "nodes": [
    { "id": "frozen_window",     "module": "src/wkwebview_shim.m",      "is_entrypoint": false, "adds_or_changes": true,  "read_path": null,                  "seedable_store": "zb_automation_navigate_guarded" },
    { "id": "socket_recover",    "module": "src/automation_server.zig", "is_entrypoint": true,  "adds_or_changes": false, "read_path": null,                  "seedable_store": null },
    { "id": "recover_statemach", "module": "src/automation_server.zig", "is_entrypoint": false, "adds_or_changes": false, "read_path": null,                  "seedable_store": null },
    { "id": "wk_terminate_reload","module": "src/wkwebview_shim.m",     "is_entrypoint": false, "adds_or_changes": true,  "read_path": null,                  "seedable_store": null },
    { "id": "post_recover_read", "module": "src/wkwebview_shim.m",      "is_entrypoint": false, "adds_or_changes": true,  "read_path": "zb_automation_get_url","seedable_store": null }
  ],
  "edges": [
    { "is_async": false, "cross_boundary": false, "driver": null },
    { "is_async": false, "cross_boundary": false, "driver": null },
    { "is_async": true,  "cross_boundary": true,  "driver": "zb_app_run" },
    { "is_async": true,  "cross_boundary": true,  "driver": "zb_app_run" }
  ]
}
```

> Each map's `read_path`/`seedable_store`/`driver` resolves at 176782f (the macOS impls are
> added by MS2; `handleWindows`/`handleRecover`/`zb_app_run`/`zb_automation_*` resolve now). All
> three e2es start at the authenticated socket and observe through production reads; **none** call
> the WK port or shim directly (FORBIDDEN SPAN).

**Gate (MS2):** three gates (MS2a/b/c), each a real-binary macOS e2e on both arches. MS2b gets a
real-screen confirmation that a native click visibly actuates the page (orchestrator-run).
Coordinate with **BlackRobin** (shim/ABI) and **BlueBeaver** (port/engine).

---

## MS3: Config & persistence on macOS (blocker 4 — persistence/config half)

**Goal.** An isolated persistent data store and a decided meaning for the config flags, so logins
and cookies do not fall into an implicit global store and the flags are not silent no-ops.

### Behavior MS3.1: an isolated persistent `WKWebsiteDataStore` bound to the profile
**Given** `--profile-dir <dir>` (today discarded off Linux, app.zig:160-166),
**When** the WKWebView build launches,
**Then** cookies/localStorage/logins persist to a **profile-scoped** `WKWebsiteDataStore` (not the
default global store), isolated per profile, surviving restart — the macOS analog of the Linux
persistent context (verified by a login→restart→still-logged-in e2e over the socket).

### Behavior MS3.2: decided macOS semantics for `--hardware-acceleration`/`--renderer`/`--media-source`
**Given** the Linux-only flag apply path (`webkit.zig:47-72`),
**When** a flag is passed on macOS,
**Then** each flag either has a **documented WKWebView mapping** (and the e2e proves the effect,
e.g. `--media-source off` disables MSE via `WKPreferences`/a user script) **or returns an explicit
"unsupported on macOS" error/documentation** — never a silent accept. (The MSE-off workaround
mirrors the Instagram-deadlock rationale, media_config.zig:6-12.)

### Behavior MS3.3: the cookie ABI + `CookiePort` over `WKHTTPCookieStore` (moved here in rev 4)
**Given** the profile-scoped `WKWebsiteDataStore` MS3.1 builds,
**When** `zb_cookies_get_all`/`_add`/`_delete` are called,
**Then** they operate on **that store's `WKHTTPCookieStore`** with the same contract as the GTK
cookie port. A new `src/automation_wk_cookie_port.zig` (gated `os.tag == .macos`) implements
`CookiePort` over it. The cookie ABI lives **here** (the data-store owner), not in MS2c — this is
the rev-4 fix for the dependency-order contradiction (MS2c was ordered before MS3 yet claimed the
cookie ABI "via MS3's port"). MS4.4 is the login-gate **consumer** of this port, not its builder.

- **Files touched:** `src/webkit.zig` (macOS apply path), `src/wkwebview_shim.m` (data store +
  settings + `zb_cookies_*` over `WKHTTPCookieStore`), `src/automation_wk_cookie_port.zig` (new,
  moved from MS4), `src/app.zig` (`--profile-dir` on macOS), `tests/e2e/mac_profile_persist_test.py`,
  `tests/e2e/mac_config_flags_test.py`, `tests/e2e/mac_cookie_test.py`.
- **Closure:** MS3.1 is **BLOCKING** (persistence across a restart crosses the process-lifetime
  boundary) — SOURCE = a logged-in profile dir; TRIGGER = relaunch (production entrypoint); OBSERVE
  = cookie/login present via `page.evaluate` over the socket; driver = the real relaunch. MS3.2 is
  LEAF per flag (config apply + a single observable effect). MS3.3 is **BLOCKING** (the cookie
  value crosses the Zig↔WKHTTPCookieStore async boundary) — SOURCE = a cookie seeded through the
  port; OBSERVE = `document.cookie` via `page.evaluate` over the socket.

**Gate (MS3):** real-binary macOS persistence + config + cookie e2e, both arches. Not a UI slice.
Coordinate with **BlueBeaver** (engine/config/cookie port) and **BlackRobin** (shim data store).

---

## MS4: Site-flow parity + the approval grant contract (blocker 7 — approval half)

**Goal.** Flows behave as on Linux, and the **approval grant authority** is fully specified before
any committing flow, since no production approval exists at the pin.

### Behavior MS4.1: the grant contract (the drawer plan's exact schema — blocker 2)
**Given** a committing social action,
**When** the native Approve handler mints a grant,
**Then** the grant is **single-use**, expires after **120 s**, and is bound to the drawer plan's
**exact tuple**
`sha256(tool, window_id, origin, account, target_fp, load_serial, normalized_args)`
(drawer plan rev 16 :507-514), where:
- `origin` = the bound window's committed origin; `account` = the platform's logged-in identity
  (`x.login_check`/`linkedin.selfcheck`/`instagram.selfcheck`); `target_fp` = for a raw DOM tool
  the resolved element's tag/id/name/role/accessible-name/text-hash/frame-URL/rect, for a flow the
  dry-run trial target description + target URL/recipient; `load_serial` = a **per-window counter**
  that increments on load-commit, published through `WindowInfo`/the list JSON.
- **Before dispatch** the broker **revalidates** the window's `origin`, `load_serial`, `crashed`
  and `recovering`; any difference **revokes** the grant and dispatches nothing.
- The check is **atomic with the commit**, inside the same FIFO ticket: the real run carries
  `options.expect = {account, target_fp}`; a mismatch returns **−32015 `expectation_mismatch`**
  and commits nothing (so a same-document account switch or a selector that now resolves to a
  different element commits nothing even when `load_serial` is unchanged).
- **Mutants (reuse drawer T5):** a **navigation** that bumps `load_serial`, a **selector-retarget**
  to a different element, a **wrong-account** switch, and **one-field-at-a-time** tuple tampering
  — each must refuse (no engine call; telemetry root-span count unchanged).
- **Only** the native Approve button's handler mints; text from the model or a page can never
  approve. Deny/timeout/window-close/crash/navigation/session-end dispatch nothing and consume
  neither the grant nor pacing.

### Behavior MS4.2: nothing else can approve (negative proofs)
**Given** the grant authority,
**When** a page world, iframe, related popup, automation-socket client, model prompt, or hook
attempts to approve,
**Then** each **fails** — proven by real-binary tests.

### Behavior MS4.3: per-write confirmation + dry-run is inert
**Given** a flow,
**When** it reaches each `Send`/`Post`/`Follow`/`Connect`/`Like`/`Next` write,
**Then** **each** gets a separate confirmation; a **dry-run** performs no committing click, no
real-composer typing, and no pacing count (social_flow_routes.zig; flow_steps.zig:142-235).

### Behavior MS4.4: login gate consumes the MS3 cookie port (rev 4 — port moved to MS3)
The `CookiePort`/`WKHTTPCookieStore` implementation (`src/automation_wk_cookie_port.zig`) is built
in **MS3.3** (the data-store owner), **not** here — rev 4 moved it so the cookie ABI no longer
depends on a slice ordered after the one that uses it. MS4.4 is the **consumer**: the flow login
gate reads the session cookie **through the MS3 port** (same contract as the GTK cookie port), and
its test proves the gate opens only when the session cookie is present.

- **Closure (MS4) — authority + negatives only (blocker 3):** MS4 closes the **negative,
  refusal and dry-run** belts: without a valid grant the write is refused (no engine call,
  telemetry root-span count unchanged); the T5 mutants above all refuse; a dry-run performs no
  committing click, no real-composer typing, and no pacing count; page worlds/iframes/popups/
  socket clients/prompts/hooks cannot approve. **The positive end-to-end commit closure is NOT in
  MS4** — the only permitted native Approve minter is built in **MS7** (MS7.8 proves the native
  card mints/denies a grant), and the **full `tool_use`→approve→commit chain is MS8.3** (rev 4),
  after the production helper that delivers `tool_use` off the socket exists. A test-only mint
  would bypass the forbidden span, so neither MS4 nor MS7 runs the commit chain.
- **Why:** at the plan pin there is **no production approval authority** (the card is
  unimplemented). MS4 builds the grant **authority and its revalidation/`options.expect` seam**
  and proves everything **refuses** without a real grant; MS7 wires the native Approve handler and
  proves it mints/denies a grant (MS7.8); MS8.3 proves the one positive commit path once per
  approval, driven by the real helper `tool_use`.

**Gate (MS4):** real-binary macOS flow + approval-refusal e2e (dry-run against fixtures; no live
sites), both arches. Not a UI slice (the card is MS7; the positive commit closure is MS8.3).
Coordinate with **BlueBeaver** (flows/approval authority).

---

## MS5: macOS setup & provisioning + Keychain onboarding (blocker 4 setup half, blocker 7 Keychain half)

**Goal.** Port provisioning to macOS so the helper/runtime/SAI can be installed, and onboard the
Claude token into the Keychain. Today `runAgentSetup` refuses non-Linux (`app.zig:41-47`) and uses
`/proc/self/exe`.

### Behavior MS5.1: macOS `runAgentSetup` builds the immutable home
**Given** a macOS build,
**When** `--agent-setup` runs,
**Then** it builds the accepted **immutable `dist-<n>/current/state`** layout, installs the Python
runtime + helper, applies the **final SAI rule — "Hook commands only"** (rev 3 blocker 1): copy
dependency/VCS/cache/build trees **unscanned**, HOME-rewrite other copied text, **validate only
hook command lines** (not a whole import graph), and warn/skip outbound links — and grants **no
access to the real `~/.claude` or user repositories** — the macOS analog of the **corrected**
Linux provisioning (setup.py), replacing `/proc/self/exe` with a macOS executable-path API. It
**inherits** the S3a corrections (**da5eb70**, BlackRobin — the approved green follow-up that
actually contains these fixes; the earlier `cab60a1` was still blocked and is superseded): a top-level link resolved through a
parent-component link **chain**, the global cycle set keeping **internal aliases**, and the
**malformed-hook-quote** refusal — the Mac port must reuse the corrected behavior, not port
today's defects.

### Behavior MS5.1b: skipped linked skills leave no bytes; dependency trees copy unscanned (RoseCat, linked-skills resolution)
**Given** the user's decision **"keep skipping"** outbound linked skills (RoseCat mail 5458),
**When** setup runs on macOS,
**Then** a symlink that resolves **outside** its item root is skipped and the test proves the
**target's bytes are absent** from the built home (not merely that the link is gone), while the
internal dependency/build trees (`node_modules`, `.venv`, `venv`, `site-packages` —
`setup.py DEPENDENCY_DIRS`) still copy **verbatim and unscanned** — matching the Linux
`_copy_tree` skip-link + verbatim-dependency behavior. Red-first: a fixture SAI with an
out-of-root linked skill whose target holds a canary string; the test asserts the canary is
**not present** anywhere in `dist-<n>/`.

### Behavior MS5.2: Keychain onboarding (disposable canary in tests)
**Given** the Secrets flow,
**When** the user onboards via **claude.ai callback and/or `claude setup-token`** (the accepted
paths),
**Then** the token is validated and stored in the **Keychain** (`Security.framework SecItem*`),
and the test uses a **disposable service/account + canary**, never a real credential.

### Behavior MS5.3: the token reaches only helper fd 3
**Given** a stored token,
**When** a session starts,
**Then** the token reaches **only** helper fd 3 via FIFO→socketpair — **not** env, argv, logs,
telemetry, hook environment, or model context (canary-scan proof, analog of
agent_secrets_test.py:247-254).

- **Closure (MS5.3):** **BLOCKING** (token crosses the store→helper process boundary) — SOURCE =
  the Keychain-stored token; TRIGGER = session start (`zb_agent_run_sync`); OBSERVE = a canary scan
  of env/argv/logs/hook-env showing **absence** + the helper confirming receipt on fd 3; FORBIDDEN
  SPAN = the FIFO/socketpair plumbing; RED-AT-SEAM = route the token via env and the canary scan
  goes red.

**Gate (MS5):** real-binary macOS setup + Keychain e2e, both arches; `--agent-setup` needs no
display. Not a UI slice (the Secrets window is MS7). Coordinate with **BlueBeaver** (helper/setup)
and **BlackRobin** (Keychain/Secrets window later).

---

## MS6: Seatbelt sandbox backend (hard launch gates; VM fallback blocks launch) — blocker 6, dispositions 2/3

**Goal.** Implement the macOS Seatbelt backend against the **MS0 launch spec**, and make the
spike proofs **hard launch gates**. **If any mandatory proof fails, Mac agent launch stays
disabled until the shared interface's VM backend is implemented** — Seatbelt-first is the choice,
"Seatbelt even when its proof fails" is not.

### Design (from `…/research/2026-10-14-macos-sandbox-option.md`)
- `MacSeatbeltBackend` implements the MS0 `SandboxBackend` spec: `(deny default)`, deny-default
  reads, **no `same-sandbox` task-port/process-info rights**, allow only `localhost:<proxy>`/
  `:51091`/`:31337`, tiny mach-lookup (no WindowServer, no mDNSResponder), **profile file + `-D`
  params** (not inline), fixed `/usr/bin/sandbox-exec`.
- Hooks spawned **app-side**, each in its own profile (profiles don't nest); stdio over
  `SCM_RIGHTS`.
- Orphan cleanup via kqueue `NOTE_EXIT` + pipe EOF + PID tracking. **The dedicated-user `kill(-1)`
  scheme from rev 1 is removed** (unapproved).
- The proxy/bridges are owned here or depend on a named green Linux revision (per MS0/Shared
  contract).

### Hard-gate behaviors (all failing-first; failure ⇒ launch disabled + VM required)
- **MS6.1 (gate):** a malicious hook's `task_for_pid(cli)`, `sysctl KERN_PROCARGS2`,
  `proc_pidinfo`, and `lldb -p <cli>` **all fail**; the token-isolation mutant uses a
  **deterministic sacrificial target** so removing Seatbelt actually **exposes the canary** (a
  host/TCC denial that stays green does **not** prove the profile).
- **MS6.2 (gate):** custom `sandbox-exec` profile is **accepted** on both arches' OS versions
  (disposition 3; failure selects VM).
- **MS6.3 (gate):** the **fd-3 reopen** (`/dev/fd/3`) works with the macOS CLI on **both** arches
  (disposition 2).
- **MS6.4 (gate):** network — the agent reaches the proxy, `:51091`, `:31337`; and **fails** to
  reach a direct loopback decoy, LAN, public IP, DNS, WindowServer/CGEvent/screen capture, a
  non-allowlisted host, and a workspace write. The fake Messages/Anthropic API is reached **through
  the production proxy** via an `--e2e-protocol` allowlist seam; **removing/bypassing the proxy
  turns the test red**.
- **MS6.5 (gate):** **no survivors** after `kill -9` of the browser, **including a hook that
  double-forks and `setsid`** — via the kqueue/pipe-EOF launcher. Failure ⇒ VM required.

### Workflow Closure (MS6.1 — token isolation; the load-bearing security belt)   [BLOCKING]
- **Chain:** `token stored -> helper reads fd 3 -> MacSeatbeltBackend spawns CLI under profile -> CLI holds token -> hook spawned app-side under its own profile -> hook attempts task_for_pid/KERN_PROCARGS2 -> kernel denies -> hook's recorded result = denied, no canary bytes`
- **SOURCE (seed):** the stored token (Keychain/file) + the fixture SAI with the malicious hook +
  a **deterministic sacrificial target**. **TRIGGER:** the browser launching the agent
  (`zb_agent_run_sync`), boundary = `highest_new_connector = MacSeatbeltBackend`. **DRIVER:** none
  async in the observed span (the read returns bytes or EPERM synchronously). **OBSERVE:** the
  hook's recorded attempt file scanned for the canary + the syscall return codes. **FORBIDDEN
  SPAN:** the launcher internals, the profile application, the CLI process. **RED-AT-SEAM:** remove
  the task-port/process-info denies → the hook reads the canary → **red**. **EXECUTION:** real
  binary on a Mac via `mac_session.py`; needs `/usr/bin/sandbox-exec` + the bundled CLI; missing ⇒
  **exit nonzero**. (ClosureMap emitted at build time pinned to the then-current HEAD; its symbols
  — `MacSeatbeltBackend`, the app-side hook spawn — are created here.)

**Gate (MS6):** real-binary macOS sandbox e2e (MS6.1–MS6.5) on both arches; the one-day spike is
run on a Mac by an agent, results recorded as red→green. **MS8 is blocked** until all MS6 gates are
green **or** the VM backend lands behind the shared contract. Not a UI slice. Coordinate with
**BlueBeaver** (sandbox/helper) and the orchestrator (spike scheduling).

---

## MS7: AppKit drawer + Keychain Secrets window + approval card + chat observability

**Goal.** The native AppKit drawer matching the accepted Linux UX, the Secrets window, the approval
**card** (authority from MS4), and **drawer observability that does not violate the threat model**.
**UI slice** — real-screen check required.

### Design
- `src/agent_drawer_mac.m` (+ reuse portable `agent_drawer.zig:16-181` geometry/animation/
  persistence). Mounted from `zb_window_new` (wkwebview_shim.m:880) when the drawer is on.
- **Dock:** bottom `NSView`; the WKWebView frame is resized **above** it (no overlay over the
  GPU-composited layer — the NVIDIA lesson applies to macOS). **"S" icon:** borderless draggable
  view, hidden while open, click-vs-drag (6 px), keyboard move, `agent-drawer.json` persistence
  (reused). **Fold:** `-` animates the panel into the icon's last position over the shared 180 ms
  cubic ease-out via `NSAnimationContext`/`CVDisplayLink`. **Isolation:** native AppKit views, not
  a webview — structurally isolated from page worlds. **Secrets:** Keychain (MS5 backend) in the
  Secrets window.
- **Approval card:** the native row; **only the Approve handler mints** the MS4 grant.

### Behaviors
- **MS7.1** dock resizes the page above it; **MS7.2** the "S" icon drags/persists/hides-while-open;
  **MS7.3** `-` folds into the icon's last position (180 ms ease-out); **MS7.4** conversation
  scrolls, input pinned at bottom, bubbles **inert text**; **MS7.5** the Secrets window stores to
  Keychain; **MS7.6** the approval card mints a one-use grant on Approve and nothing on Deny.
- **MS7.7 chat observability (blocker 7):** the chat round-trip and bubble text are asserted via a
  gated **`--e2e-protocol` native drawer census** (the macOS analog of the `DRAWER windows` row) or
  screen capture — **never** a production socket drawer-read API.
- **MS7.8 native approval-card mint/deny (rev 4 — not the end-to-end chain):** the native
  approval card is the **only** production grant minter. On a **native AppKit click** of Approve —
  a real `-[NSWindow sendEvent:]`-delivered `NSEvent` on the card's Approve control (never "X
  click"; MS7 is a real-screen slice, orchestrator-run) — `on_approve` mints a **valid MS4 grant**
  (correct tuple, 120 s, single-use); a **Deny** click mints nothing. This closes the card's mint
  **authority and binding** at the native boundary **without** the helper or the automation socket:
  there is no `tool_use` source wired at MS7, so the full commit chain cannot and does not run
  here. The observable is the minted grant (present and well-formed on Approve, absent on Deny),
  read through MS4's grant seam — **not** a flow commit. **The positive end-to-end commit closure
  (socket-free `tool_use` → broker preview → this card → Approve → grant → revalidate → commit
  once) lives in MS8.3**, after MS8 wires the production CLI/helper/protocol-pump that actually
  delivers `tool_use` (rev 4 blocker 1).
- **MS7.9 drawer ownership / window-destroy parity (blocker 5):** the drawer honors MS2c.5 —
  every window (incl. popups) has its own drawer bound to its `window_id`, the shared destroy path
  detaches/frees the drawer before the automation close notification, and the live-drawer count is
  **zero** after all windows close. **SHOULD:** the icon/fold views **intentionally overlap** the
  page, so they need **exact hit-testing** (a click on the icon/`-` hits the drawer, a click
  elsewhere reaches the page) even though the docked panel does not overlap.

- **Property (MS7.2):** roundtrip — `parse(write(ratios)) == ratios` (reuse the platform-neutral
  `agent_drawer.zig` property).
- **SHOULD named tests (833767e):** keyboard/fold-row parity (Enter/Shift-Enter/Escape/
  Ctrl+Shift+Space-equivalent + arrow-key icon move) and **Secrets-exclusion** parity (the Secrets
  window is not in the window registry and is unreachable from the automation socket) each get a
  **named** macOS test.
- **Real-screen (blocker 8):** add macOS `drawer-open`, `secrets-window`, `approval-card` cases to
  the real-screen check; the orchestrator runs them on the user's Mac; **not approved until they
  pass**. The input guard proves its window is frontmost/topmost before emitting — via
  `NSWorkspace.sharedWorkspace.frontmostApplication` compared with
  `NSRunningApplication.currentApplication` (or `[NSApp isActive]` inside the app); there is no
  `NSRunningApplication.activeApplication` (BlackRobin 5477) — and aborts under a grab-equivalent
  guard, and the runner **fails closed when Screen-Recording / window-order evidence is
  unavailable**.

#### Workflow Closure (MS7.8 — native card mint/deny)   [BLOCKING: AppKit action → MS4 grant seam]
- **Chain:** `native AppKit Approve click (-[NSWindow sendEvent:]) -> on_approve -> MS4 grant minted (tuple/120s/single-use)`; a Deny click mints nothing.
- **SOURCE (seed):** a loaded bound window + a pending approval card (built from fixture
  parameters, **no helper**). **TRIGGER:** the native Approve/Deny click (the card is the entry
  point; there is no socket or helper at MS7). **DRIVER:** the real `[NSApp run]` loop + the real
  native click (real-screen case, orchestrator-run). **OBSERVE:** the MS4 grant seam — a valid
  grant exists after Approve, none after Deny. **FORBIDDEN SPAN:** the grant minter internals.
  **RED-AT-SEAM:** route the mint off the native handler (e.g. let page/model text mint) → the
  negative proofs (MS4.2) go red. **Scope:** this closure does **not** reach a flow commit — the
  committing chain is MS8.3.

**Gate (MS7):** real-binary macOS drawer e2e (native census + snapshot) on both arches **plus** the
real-screen check (incl. the MS7.8 native Approve/Deny click). Coordinate with **BlackRobin**
(drawer owner) and **BlueBeaver** (grant authority from MS4).

---

## MS8: Agent helper on macOS (blocked on MS6 green or the VM backend)

**Goal.** Run the Python helper + Claude Agent SDK **inside the Seatbelt sandbox** (MS6), wired to
the drawer, streaming replies. **Blocked until MS6's gates are all green or the VM backend lands.**

### Behaviors
- **MS8.1** the helper launches under the `MacSeatbeltBackend`, reads the token on fd 3, and emits
  a `ready` frame validated by `agent_protocol.zig` (platform-neutral, already covered).
- **MS8.2** a chat round-trip streams `assistant_delta`/`assistant_message` to the AppKit drawer.
- **MS8.3 positive approved commit — the one end-to-end chain (rev 4, moved from MS7.8, blocker
  1):** a `tool_use` emitted by the fake Anthropic API arrives **through the production proxy and
  the helper/protocol-pump** (the same source as MS8.2, **never** the automation socket) → the
  broker renders a **dry-run preview** → the **MS7 native approval card** → a **native AppKit
  Approve click** → `on_approve` mints the MS4 grant → **revalidate** (origin/`load_serial`/
  `crashed`/`recovering`) → the **real flow commits exactly once** with `options.expect` checked
  in-ticket. This chain can only exist here because the production `tool_use` source (CLI →
  helper → protocol pump) is not wired until MS8 — at MS7 there is no non-socket `tool_use`
  source, so attempting it at MS7 would have to route through the forbidden automation socket or
  inject inside the span. Deny / an expired or retargeted grant commits **0**.

### Workflow Closure (MS8.3 — positive approved commit)   [BLOCKING: helper tool_use → native approve → single commit]
- **Chain:** `fake-Anthropic tool_use (through proxy) -> helper/protocol pump -> broker preview (dry run) -> MS7 native card -> native AppKit Approve click -> on_approve mints MS4 grant -> revalidate (origin/load_serial/crashed/recovering) -> real flow commit (options.expect in-ticket) -> fixture records exactly 1 commit`
- **SOURCE (seed):** a logged-in social fixture + a loaded bound window + the fake Anthropic API
  **reached through the production proxy** (`--e2e-protocol` seam, per MS6.4) emitting the
  `tool_use`. **TRIGGER:** the helper delivering the `tool_use` to the broker (the production
  entrypoint; **not** the automation socket). **DRIVER:** the real helper stdin/stdout pump
  (`chat.py _pump`) + the real `[NSApp run]` loop + the real native Approve click (real-screen
  case, orchestrator-run). **OBSERVE:** the social fixture's commit log = **exactly 1**.
  **FORBIDDEN SPAN:** the helper Session/SDK client, the broker, the grant minter, the flow engine.
  **RED-AT-SEAM:** Deny, or an expired/navigation-retargeted/wrong-account grant → commit **0**;
  routing the `tool_use` over the automation socket must be **impossible** (socket separation, per
  the drawer architecture). **EXECUTION:** real binary + helper venv + a Mac with a GUI session;
  missing venv or no real-screen operator ⇒ exit nonzero (never SKIP-to-green).

### Workflow Closure (MS8.2 — drawer↔helper↔broker chat)   [BLOCKING]
- **Chain:** `drawer Send (AppKit) -> app frame on helper stdin -> chat.py Session -> ClaudeSDKClient (CLI under Seatbelt) -> assistant frames on stdout -> agent_protocol.zig validate -> drawer bubble`
- **SOURCE (seed):** the prompt + a fake Anthropic API **reached through the production proxy**
  (`--e2e-protocol` seam, per MS6.4). **TRIGGER:** the drawer Send handler (MS7), boundary =
  highest_new_connector (the drawer→helper wiring, MS8). **DRIVER:** the real helper stdin/stdout
  pump (`chat.py _pump`) + the 50 ms coalescer. **OBSERVE:** the rendered bubble via the
  `--e2e-protocol` **native census** (not a production socket read). **FORBIDDEN SPAN:** the
  Session, SDK client, frame validator. **RED-AT-SEAM:** disconnect the drawer→helper wiring → no
  bubble → red. **EXECUTION:** real binary + helper venv on a Mac; missing venv ⇒ exit nonzero.

**Gate (MS8):** real-binary macOS chat e2e (MS8.1/8.2) **and the positive approved-commit e2e
(MS8.3)** on both arches **plus** a real-screen check of a streamed reply and of the MS8.3 native
Approve click (orchestrator-run). Coordinate with **BlueBeaver** (helper + grant authority from
MS4) and **BlackRobin** (drawer/native card from MS7).

---

## MS9: Developer-ID signing + hardened runtime + notarization (gated on the Apple Developer ID)

**Goal (blocker 9).** Turn the ad-hoc **development** build into a Developer-ID-signed,
hardened-runtime, notarized, stapled **universal** `.dmg`. **Blocked on the user obtaining the
Developer ID**, tracked via **Agent Mail / plan status** (the beads DB is migration-locked).

### Behaviors
- **MS9.1 inside-out nested signing:** sign nested code in explicit **inside-out order** (helper,
  CLI, embedded frameworks/runtimes, then the `.app`) with the **MS1.3 least-privilege entitlement
  manifest** and `--options runtime`, per arch.
- **MS9.2 whole-bundle hardened-runtime verify on both arches, then notarize:** `codesign --verify
  --strict` passes on the universal bundle on **both** arches; then `xcrun notarytool submit
  --wait` returns `Accepted`, `xcrun stapler staple` + `stapler validate` succeed, and `spctl
  --assess --type execute` accepts the `.app`.
- Until the Developer ID exists, the artifact is explicitly an **ad-hoc development build, not a
  distributable launch artifact**.

- **Closure:** LEAF (packaging assertions) — assert via `codesign --verify --strict`, `spctl
  --assess`, `stapler validate`, each per arch.

**Gate (MS9):** release gate on both arches producing a distributable `.dmg`. Not a UI slice.
**Blocked on:** the Apple Developer ID (Agent Mail / plan status).

---

## Dependency order

`MS0 (Linux) → MS1 → MS2a → MS2b → MS2c → MS3 → MS4 → MS5 → MS6 (hard gates) → MS7 → MS8 (blocked
on MS6) → MS9 (blocked on Developer ID)`. MS3/MS4/MS5 may proceed in parallel after MS2a; MS7
needs MS4 (grant) + MS5 (Keychain); MS8 needs MS5 (setup) + MS6 (sandbox) + MS7 (drawer).

## Per-slice gate protocol (all slices)

1. Mail "taking the gate slot" only for the gate run (docs-only commits exempt). 2. Write the
slice's red tests; record the red runs (on a remote Mac for e2e). 3. Green. 4. Refactor (remove
duplication). 5. Quiet gate from a clean `git archive HEAD` + the slice's files. 6. Commit only the
slice's files (stage only your own). 7. Mail RoseCat. 8. UI slice (MS7, MS8 reply render): add the
macOS real-screen case; the orchestrator runs it on the user's Mac; **not approved until it passes
there**. A slice is not done until its closure e2e was **observed to execute** with nonzero
assertions; "SKIP" counts as UNCLOSED. Every MS2–MS8 sub-slice carries a **named red test, an exact
failing assertion, named green production files, and a refactor gate**.

## References

- Reviews answered: `thoughts/searchable/shared/reviews/2026-10-10-automation-integration-review.md`
  — §"macOS launch plan review (d857a03)" (rev-1 blockers, commit 21625eb), §"macOS launch
  plan rev 2 and 2.1 (c3d7217, 9c2b2c3)" (rev-2 blockers, commit 833767e), §"macOS launch plan
  rev 3 (a02f1ea, with 5bebd42 follow-up)" and §"S3a follow-up and prefix audit at da5eb70"
  (rev-3 blockers, commit db02324)
- Drawer grant schema reused (rev 3 blocker 2): `…/plans/2026-10-13-claude-agent-chat-drawer-tdd-plan.md:503-519` (grant tuple, `load_serial`, `options.expect`, −32015, T5 mutants)
- Production `tool_use` source (rev 4 blocker 1 — why the positive commit closure is MS8.3, not from the socket): `…/plans/2026-10-13-claude-agent-chat-drawer-tdd-plan.md:1231-1232, 2013-2020` (CLI → helper → protocol pump; the broker is unreachable from the automation socket)
- S3a corrections inherited by MS5 (rev 3 blocker 1, dependency corrected in rev 4): **da5eb70** (chain / internal-alias / malformed-quote — approved green per review db02324 §"S3a follow-up and prefix audit"), owned by BlackRobin. Supersedes the earlier `cab60a1`, which was still blocked.
- Research: `…/research/2026-10-14-14-19-macos-launch-support-surface.md` (1df5dce) + its `.closure-adapter.py`
- Sandbox: `…/research/2026-10-14-macos-sandbox-option.md`, `…/2026-10-14-agent-sandbox-redteam.md`
- Drawer plan (conventions, real-screen §7.1): `…/plans/2026-10-13-claude-agent-chat-drawer-tdd-plan.md`
- Prior WKWebView backend plan: `…/plans/2026-05-31-18-00-ENG-0005-tdd-ipc-surface-and-cross-os-backends-slice3-4.md`
- Bead `zigBrowser-8g7` (M9 render + ping/pong DONE on Intel Mac)
- Code anchors: build.zig:1107-1184/79-105/241-272; src/wkwebview_shim.m:788-888;
  src/automation_server.zig:412-530/480-487/686-691/942-1106; src/automation_gtk_port.zig:22;
  src/automation_platform.zig:90-95; src/app.zig:41-47/160-166; src/webkit.zig:47-72;
  agent/host/zb_agent_host/sandbox.py; src/agent_host.c:1-73; packaging/macos/build-dmg.sh:90;
  packaging/macos/Info.plist:21-22

## Blocker status (not a code blocker, a process note)

Tracking bead for this work **cannot be filed**: the shared bd DB has pending schema migrations
(v49→v53) and refuses auto-apply on a remote-backed clone; `bd migrate`/`bd bootstrap` are
destructive/coordination actions not taken unilaterally. Status is tracked via Agent Mail / this
plan until the designated migrator resolves it.
