---
date: 2026-10-29
author: TealCastle (pane 2, zb-clojure-scope team)
base: 14e0012f (branch zb-clojure-scope-2026-10-29-10-21)
status: part 2 of 2, for merge into 2026-10-29-clojure-clojurescript-port-scope.md
scope: product and UI side. Sections 2 (my rows), 4, 5, 7, 9, plus inputs for 1, 6 and 8.
---

# Clojure / ClojureScript port scope: part 2 (product and UI side)

## Note to pane 1 (CopperLynx)

- Module split, agreed by mail on 2026-10-29: I cover the site flows and
  sequences, `src/automation/` flow files (flow_runner, social_routes,
  social_flow_routes, x_routes, pacing, pacing_store, bezier, gaussian,
  stealth), `src/automation_script/`, `src/dashboard/`, the drawer UI files,
  everything under `agent/host/`, `sdk/`, and the test tree. You cover the
  rest of `src/`, `packaging/`, `tools/` and `build.zig`.
- I used your table columns. I added one more target value, **keep as is
  (language)**, for code that should not move at all (the Python agent host,
  the JS page script, the Python and Node SDKs). The five targets you listed
  do not cover "stay in Python". Please keep it when you merge.
- Section "Contracts on my side" below is input for your section 6.
  Section "Phase inputs" is input for your section 8. Section "Risks" is
  input for your section 1.
- Your mail of 14:26 matches what I found: the drawer is native on purpose,
  the Agent SDK is Python and TypeScript only, and the socket uses a 4-byte
  length prefix. I cite those below.

## How to read the labels

- **verified**: I read the code or ran a read-only command and saw it.
- **inferred**: my reasoning from verified facts. Not tested.
- **unknown**: I could not check it.
- **web**: a fact from a web page. The URL is next to it. I checked the
  Agent SDK languages page and the npm and PyPI registries myself. Other web
  facts came from a research helper and are marked "web (helper)".

## Short summary of my side

1. The site flows (LinkedIn, Instagram, X) are already data plus a small
   runner. Each flow is a fixed list of ordinary automation commands with a
   selector table (`src/flow_steps.zig:1-12`, `src/linkedin.zig:1-8`)
   [verified]. That shape fits Clojure well: selector maps and step vectors
   in `.cljc` files, run by one interpreter. This is the best part of the
   port.
2. The page script `automation.js` should stay JavaScript. It is 1,567
   lines of careful event code that runs in a private world on three engines
   (`src/webkit_shim.c:1899-1908`, `src/wkwebview_shim.m:640-647`, Windows
   branch `src/webview2_shim.cpp:2558-2566`) [verified]. It already has a
   direct behaviour test in Playwright (`e2e/automation_script.spec.ts`)
   [verified]. A rewrite gains little and risks a lot.
3. The Python agent host should stay Python. The only official Agent SDKs
   are Python and TypeScript (web, checked). The host is 8,701 lines with
   20,339 lines of tests [verified], and it talks to the app with simple
   NDJSON frames on stdin and stdout (`agent/host/zb_agent_host/frames.py:1`)
   [verified]. A Clojure core can speak those frames without the host
   changing.
4. The drawer is three native UIs today (GTK, AppKit, Win32), on purpose,
   so pages cannot see or script it (`docs/agent-drawer.md:92-94`)
   [verified]. A ClojureScript drawer is possible, but it reverses a
   security decision. That is an owner decision (question Q2).
5. The dashboard and the sequences client are not used by the app. Only
   test modules in `build.zig` import them (`build.zig:5240-5297`) and no
   file in `src/` outside their own imports them [verified by grep]. They
   can be dropped from the port, or rebuilt later in ClojureScript.

---

## Section 2: module inventory (my rows)

Sizes are `wc -l` at 14e0012f [verified]. "Label" is the label of the
target choice, not of the size.

### Site flows, pacing and sequences

| Path | Language | Lines (wc -l) | What it does | Target | Label |
|---|---|---|---|---|---|
| src/flow_steps.zig | Zig | 361 | Shared step helpers and the duck-typed runner contract for all site flows. | Clojure (JVM), as `.cljc` | inferred |
| src/linkedin.zig | Zig | 875 | LinkedIn flows (visit, connect, follow, message, like, comment, extract) and their selector table. | Clojure (JVM), as `.cljc` data + steps | inferred |
| src/instagram.zig | Zig | 452 | Instagram flows (follow, like, comment, dm, story view) and their selector table. | Clojure (JVM), as `.cljc` data + steps | inferred |
| src/x.zig | Zig | 401 | X flows (post, schedule post, login check, selfcheck) and their selector table. | Clojure (JVM), as `.cljc` data + steps | inferred |
| src/social.zig | Zig | 130 | social.* verbs: login check, rate status, pause, set pacing, with their wire shapes. | Clojure (JVM), as `.cljc` | inferred |
| src/profile_step.zig | Zig | 64 | Creates the profile directory before the state files are written into it (macOS). | Clojure (JVM) | inferred |
| src/load_failure_policy.zig | Zig | 56 | Decides what a failed page load does on macOS (exit only on the first load). Pane 1 cites it in section 6. | Clojure (JVM), as `.cljc` pure function | inferred |
| src/automation/flow_runner.zig | Zig | 776 | Runs each flow step as a router command under one root span, with approvals and rate-limit scans. | Clojure (JVM) | inferred |
| src/automation/social_routes.zig | Zig | 389 | Routes social.* methods from the socket to src/social.zig with real ports. | Clojure (JVM) | inferred |
| src/automation/social_flow_routes.zig | Zig | 702 | Routes linkedin.* and instagram.*: strict params, login gate, pacing, then the flow. | Clojure (JVM) | inferred |
| src/automation/x_routes.zig | Zig | 295 | Routes x.* methods to src/x.zig. | Clojure (JVM) | inferred |
| src/automation/pacing.zig | Zig | 144 | The daily-cap and delay rate limiter. | Clojure (JVM), as `.cljc` | inferred |
| src/automation/pacing_store.zig | Zig | 115 | Saves and loads `<profile>/automation-pacing.json` atomically. | Clojure (JVM) | inferred |
| src/automation/bezier.zig | Zig | 87 | Cubic Bézier mouse paths. | Clojure (JVM), as `.cljc` pure math | inferred |
| src/automation/gaussian.zig | Zig | 51 | Normal-distribution samples for typing delays. | Clojure (JVM), as `.cljc` pure math | inferred |
| src/automation/stealth.zig | Zig | 255 | Behaviour-simulation telemetry events and their attributes. | Clojure (JVM) | inferred |
| src/sequences.zig | Zig | 939 | HMAC-signed HTTP client for an external "sequences" service (`/api/v1/automation`). Not used by the app. | drop (or Clojure (JVM) later, see Q5) | verified (not used), inferred (target) |

### Page script and dashboard

| Path | Language | Lines (wc -l) | What it does | Target | Label |
|---|---|---|---|---|---|
| src/automation_script/automation.js | JavaScript | 1,567 | The injected page script: selectors, actionability checks, input acks, waits, rate-limit scan, exposed as `__zbAutomation`. | keep as is (JavaScript) | inferred |
| src/automation_script/js_embed.zig | Zig | 1 | Embeds automation.js into the binary (`@embedFile`). | Clojure (JVM): load as a classpath resource | inferred |
| src/dashboard/content/index.html | HTML + JS | 387 | A sequences dashboard page that calls `zbHost` message handlers. | drop (or ClojureScript later, see Q5) | verified (not used), inferred (target) |
| src/dashboard/ipc.zig | Zig | 468 | Mock IPC answers for the dashboard (all `mock*` functions). | drop | verified (mock only) |
| src/dashboard/embed.zig | Zig | 1 | Embeds the dashboard HTML. | drop | inferred |

### Drawer UI

| Path | Language | Lines (wc -l) | What it does | Target | Label |
|---|---|---|---|---|---|
| src/agent_drawer.zig | Zig | 866 | The drawer's pure logic: icon gestures, clamping, position ratios, `agent-drawer.json`. | Clojure (JVM), as `.cljc` | inferred |
| src/agent_drawer.c / .h | C (GTK) | 1,832 / 32 | Linux drawer: icon, docked panel, message list, input row, all native GTK widgets. | stays native (see Q2) | verified (native), inferred (target) |
| src/agent_drawer_mac_host.m / src/agent_drawer_mac.h | Objective-C (AppKit) | 1,064 / 49 | Mac content view that owns the page WKWebView and the docked panel. | stays native | inferred |
| src/agent_drawer_mac_panel.m | Objective-C (AppKit) | 1,439 | Mac drawer panel with AppKit views. | stays native (see Q2) | inferred |
| Windows drawer, inside src/webview2_shim.cpp (branch zb-windows-impl-2026-10-22-15-03) | C++ (Win32) | part of 3,596 | Win32 drawer with a read-only plain-text RichEdit bubble (`webview2_shim.cpp:7,120,1990`). | stays native (see Q2) | verified (exists), inferred (target) |

### Python agent host (agent/host/zb_agent_host)

All rows: language Python. Target for every row: **keep as is (Python)**,
label inferred, for the reasons in section 5. The sandbox rows are listed
for completeness; pane 1 owns the sandbox interop choice.

| Path | Language | Lines (wc -l) | What it does | Target | Label |
|---|---|---|---|---|---|
| __main__.py | Python | 35 | Command dispatcher (`contract-config`, `provision-runtime`, `launch`, `chat`, `setup`, `probe-r1`, `login`). | keep as is (Python) | inferred |
| __init__.py | Python | 3 | Package marker and version. | keep as is (Python) | inferred |
| chat.py | Python | 429 | The drawer's helper: one ClaudeSDKClient per drawer session, frames in and out. | keep as is (Python) | inferred |
| bridge.py | Python | 239 | Browser tools as an in-process MCP server; asks the app over stdout and waits on stdin. | keep as is (Python) | inferred |
| frames.py | Python | 53 | NDJSON frame encoder and emitter. | keep as is (Python) | inferred |
| contract.py | Python | 115 | P0 contract command: one real SDK turn with the token on route R1. | keep as is (Python) | inferred |
| options.py | Python | 144 | The single builder of the helper's environment and every ClaudeAgentOptions. | keep as is (Python) | inferred |
| token.py | Python | 174 | The token's two hops: app to helper (fd 3) and helper to CLI (route R1). | keep as is (Python) | inferred |
| redact.py | Python | 495 | Scrubs saved transcripts of echoed credentials. | keep as is (Python) | inferred |
| login.py | Python | 588 | One-shot sign-in helper (`claude setup-token` on a pty, token on fd 4). | keep as is (Python) | inferred |
| setup.py | Python | 1,027 | `--agent-setup`: builds the agent home and selects the token route. | keep as is (Python) | inferred |
| provision.py | Python | 77 | Runtime provisioning used by the contract tests. | keep as is (Python) | inferred |
| launch.py | Python | 348 | What the app spawns: builds the sandbox argv and execs it. | keep as is (Python) | inferred |
| launcher.py | Python | 35 | Portable launcher contract (Windows plan). | keep as is (Python) | inferred |
| files.py | Python | 150 | Atomic file writes and safe tree removal. | keep as is (Python) | inferred |
| hook_run.py | Python | 310 | Runs one hook in its own PID and network namespaces. | keep as is (Python) | inferred |
| netd.py | Python | 907 | The agent's only network (an allowlisting proxy daemon). | keep as is (Python) | inferred |
| relay.py | Python | 312 | TCP-to-Unix-socket relay to netd. | keep as is (Python) | inferred |
| route_probe.py | Python | 381 | Setup's R1 probe inside setup's sandbox. | keep as is (Python) | inferred |
| probe.py | Python | 118 | Contract-only probe for the outer seccomp filter. | keep as is (Python) | inferred |
| sandbox.py | Python | 504 | The Linux bwrap argv every helper, CLI and hook runs under. | keep as is (Python) | inferred |
| seccomp.py | Python | 62 | The outer seccomp filter. | keep as is (Python) | inferred |
| sandbox_macos.py | Python | 775 | macOS Seatbelt profile generator. | keep as is (Python) | inferred |
| seatbelt_rules.py | Python | 143 | Curated Seatbelt read and Mach-service rules. | keep as is (Python) | inferred |
| proc_darwin.py | Python | 198 | macOS process inspection (libproc, sysctl). | keep as is (Python) | inferred |
| parent_watch.py | Python | 329 | Makes setup die with the browser on macOS. | keep as is (Python) | inferred |
| owned_group.py | Python | 254 | Runs setup's sandboxed work as one owned process group. | keep as is (Python) | inferred |
| platforms.py | Python | 18 | Makes POSIX-only seams fail closed on Windows. | keep as is (Python) | inferred |
| wincontain.py | Python | 248 | Windows containment branches, pure and testable on Linux. | keep as is (Python) | inferred |
| wincontain_win32.py | Python | 211 | Live Windows Job Object launch backend. | keep as is (Python) | inferred |
| agent/host/pyproject.toml + uv.lock | TOML | 19 + lock | Pins `claude-agent-sdk==0.2.165` and, on macOS, `cryptography==48.0.1`. | keep as is | verified (pins) |

### SDKs

| Path | Language | Lines (wc -l) | What it does | Target | Label |
|---|---|---|---|---|---|
| sdk/python/src/zigbrowser (client, errors, events, types, __init__) | Python | 818 | Python client for the automation socket (sync and async), 38 RPC methods. | keep as is (Python) | inferred |
| sdk/node/src (client, methods, errors, index) | TypeScript | 784 | Node client for the automation socket, 51 method names in methods.ts. | keep as is (TypeScript) | inferred |
| sdk/cli/src/zigbrowser_cli | Python (click) | 80 | `call` and `trace` commands on top of the Python SDK. | keep as is (Python); optional babashka copy later | inferred |
| (new) sdk/clojure | Clojure `.cljc` | 0 | Optional Clojure and ClojureScript client of the same socket. | Clojure (JVM) + ClojureScript, later (Q6) | inferred |

### Tests and test tooling

| Path | Language | Lines (wc -l) | What it does | Target | Label |
|---|---|---|---|---|---|
| tests/*.zig (top level, 134 files) | Zig | 30,468 | White-box unit tests of Zig modules. | rewrite as clojure.test for ported modules; keep for native code | inferred |
| tests/*.c (12 files) | C | 1,159 | Tests of the C run ledger, reaper and secrets dlopen. | stays native | inferred |
| tests/automation/ (9 files) | Zig | 1,775 | Fakes, math tests and source-grep tests of automation.js. | rewrite (math); drop (source-grep, see section 7) | inferred |
| tests/e2e/*.py (257 files) + 18 other | Python, sh, HTML | 61,268 (py) | Black-box tests that launch the binary and drive it, many over the socket. | keep as is (Python): contract tests | inferred |
| tests/mac/ (149 files) | sh, Python, ObjC, C | 33,459 | Mac build, bundle, DMG, Keychain and live tests over ssh. | keep, re-point at the new artifact | inferred |
| tests/windows/ (43 files) + Windows branch additions | Python, sh, PowerShell | 12,226 | Windows gate and live tests. | keep, re-point at the new artifact | inferred |
| tests/fixtures/ (59 files) | HTML, JSON, Python | 3,323 | Site fixtures (linkedin, instagram, x), automation pages, `sdk_wire_cases.json`. | keep as is: shared contract data | verified (contents) |
| tests/dashboard/, tests/sequences/ | Zig | 398 / 983 | Tests of the unused dashboard and sequences client. | drop with their modules | inferred |
| tests/guest, kill_group, manual, snapshots, spikes | mixed | 544 / 472 / 2,537 / 91 / 100 | VM build helper, process-group tests, manual scripts, one snapshot, one spike. | keep as is | inferred |
| agent/host/tests/ (92 files) | Python | 20,339 | Agent host unit and contract tests. | keep as is (Python) | inferred |
| sdk/python/tests, sdk/node/tests, sdk/cli/tests | Python, TypeScript | 747 / 676 / 118 | SDK tests against a mock Unix-socket server. | keep as is | inferred |
| e2e/*.spec.ts + playwright.config.ts + package.json | TypeScript | 381 + 79 + 26 | Playwright tests of automation.js on Chromium, Firefox and WebKit. | keep as is (TypeScript) | inferred |

---

## Section 4: ClojureScript targets

Build tool for everything below: **shadow-cljs**. npm shows 3.5.8,
published 2026-10-26 (web, checked:
https://registry.npmjs.org/shadow-cljs). Its guide documents the
`:browser`, `:esm`, `:node-script`, `:node-library`, `:npm-module`,
`:browser-test`, `:node-test` and `:karma` targets (web (helper):
https://shadow-cljs.github.io/docs/UsersGuide.html). ClojureScript itself
is 1.12.145 (web (helper): https://github.com/clojure/clojurescript/releases).

### 4.1 The page script (automation.js)

What it is today [verified]:

- One IIFE that defines `globalThis.__zbAutomation`, non-writable and
  non-enumerable (`src/automation_script/automation.js:1537-1567`).
- One entry point, `handle(json)`, that switches on `command.op`
  (`automation.js:112-125`, `235-275`). Ops: query, getText, getAttribute,
  click, fill, type, press, selectOption, chooseFiles, hover, scroll, locate,
  measure, waitFor, rateLimitScan, documentToken.
- Results are `{ok, value, telemetry}` or `{ok:false, error, retryable,
  data, telemetry}` (`automation.js:1376-1398`).
- It counts trusted input events so the native side knows when input has
  landed (`automation.js:21-62`), and it reports navigations to the shell
  through the `zbNavigation` message handler (`automation.js:83-104`).
- It is injected at document start into a named private world,
  `zigbrowser-automation` (`src/webkit_shim.h:140`): on Linux with
  `webkit_user_script_new_for_world` (`src/webkit_shim.c:1899-1908`), on Mac
  with a `WKUserScript` in a `WKContentWorld` (`src/wkwebview_shim.m:640-647`),
  on Windows with CDP `Page.addScriptToEvaluateOnNewDocument` and a
  `worldName` (Windows branch `src/webview2_shim.cpp:2558-2566`).
- The Zig side embeds it with `@embedFile` (`src/automation_script/js_embed.zig:1`)
  and hands it to the shim (`src/automation_gtk_port.zig:38`,
  `src/automation_macos_port.zig:43`).

Options:

| Option | Gain | Cost | Label |
|---|---|---|---|
| A. Keep plain JS (recommended) | Zero risk. Same file on all 3 engines. Playwright tests keep working. | One more language in the repo. | inferred |
| B. Full ClojureScript, shadow-cljs `:browser` target, one module, `:advanced` | Clojure syntax and shared `.cljc` selector parsing with the JVM core. | Adds the cljs.core runtime to every document at document start (size and parse time not measured: unknown). `:advanced` renames properties, so every wire field (`op`, `selector`, `ok`, `telemetry`...) must use string keys or `^js` hints, or the protocol breaks. Event-order details (submit before keyup, navigate before input) must be re-proven on 3 engines. | inferred |
| C. Squint (a light ClojureScript dialect that emits small JS and uses plain JS data) | Clojure syntax with small output and no persistent-data runtime. | Smaller community, a dialect with differences from ClojureScript. Version 0.14.207 on Clojars (web: https://www.clojars.org/io.github.squint-cljs/squint, https://github.com/squint-cljs). | inferred |

Recommendation: **A, keep JS**. If the owner wants Clojure syntax here,
choose C before B, and only with a size budget and the full Playwright
suite green on all three engines.

If B or C is chosen, how it is built, injected and tested [inferred]:

- Build: shadow-cljs `:browser` target (B) or the Squint CLI (C), one
  output file. shadow-cljs wraps a single-module release build in an
  anonymous function with no globals (pane 1's note, from the user guide).
  The code must still set `__zbAutomation` itself with
  `Object.defineProperty`, as today.
- Injection: no change in the shims. The JVM core reads the compiled file
  from the classpath and passes it to the same native calls
  (`zb_automation_set_script` today).
- Tests: point `e2e/automation_script.spec.ts:6` (`scriptPath`) at the
  compiled file. The spec loads it with `page.addScriptTag` and calls
  `__zbAutomation.handle` (`e2e/automation_script.spec.ts:20-28`), so it
  tests behaviour, not source. Pure helpers can also get
  `:browser-test` or `:node-test` unit tests.
- Delete the source-grep tests in `tests/automation/js_contract_test.zig`
  (for example lines 7-40 look for strings such as `'rateLimitScan'` and
  `outstandingWaits -= 1` in the source). Compiled output does not keep
  those strings.

### 4.2 The drawer UI

What it is today [verified]:

- Three native UIs: GTK (`src/agent_drawer.c`, header comment lines 1-8),
  AppKit (`src/agent_drawer_mac_panel.m`, `src/agent_drawer_mac_host.m:1-6`),
  and Win32 with a read-only plain-text RichEdit bubble (Windows branch
  `src/webview2_shim.cpp:7,120,1990`). One shared pure-logic file,
  `src/agent_drawer.zig`.
- The choice is deliberate: "The icon and drawer are native GTK widgets,
  with no web content and no JavaScript. Pages, iframes and popups cannot
  see, script or cover them, and the automation socket has no drawer,
  agent or secrets methods" (`docs/agent-drawer.md:92-94`). Model text is
  only set with `gtk_label_set_text`, so it stays inert
  (`src/agent_drawer.c` header).
- The drawer docks under the page, because a floating panel over the page
  blanked an NVIDIA screen (`docs/agent-drawer.md:49-52`).

Options:

| Option | Gain | Cost | Label |
|---|---|---|---|
| A. Keep the three native UIs; port only `agent_drawer.zig` to `.cljc` (recommended for the first release) | No security change. Owner already accepted these UIs on real screens. | Three UIs to keep in step. | inferred |
| B. One ClojureScript drawer in a second, privileged web view per window | One UI for 3 OSes. Long-line breaking, selection and copy become CSS and DOM work. | Reverses the "no web content" rule. Needs its own web view instance that pages cannot reach, no network, a strict CSP, and text set only with `textContent`. Adds a web content process per window (memory not measured: unknown). Every OS needs new native code to host and dock it. Needs owner sign-off on real screens again. | inferred |

Recommendation: **A first**. Revisit B after the core port ships (Q2).

If B is chosen [inferred]: shadow-cljs `:browser` target with `:advanced`.
UI library: **Replicant**, which needs no React (web (helper):
https://github.com/cjohansen/replicant). Reagent 2.0.1 and UIx 1.4.9 need
React (web (helper): https://clojars.org/reagent/reagent,
https://github.com/pitch-io/uix). The HTML is loaded from the app bundle,
not from a URL. The drawer talks to the core with a message handler
(the same `zbHost` pattern the dashboard uses,
`src/dashboard/content/index.html:132-140`), never with the page's
automation world. Tests: `:browser-test` for logic, Playwright TS for the
page itself, and the owner's real-screen check.

### 4.3 The SDKs

- Keep the Python and Node SDKs in their own languages. Their users write
  Python and TypeScript. The wire is plain JSON-RPC 2.0 over a Unix socket
  with a 4-byte big-endian length prefix (`sdk/python/src/zigbrowser/client.py:515-556`,
  server side `src/automation_server.zig:20,347-363` per pane 1) [verified
  on the SDK side]. The port does not change the wire, so the SDKs do not
  change.
- Optional new Clojure SDK as one `.cljc` library (Q6) [inferred]: JVM
  build with deps.edn; JVM Unix sockets through
  `java.nio.channels.SocketChannel` with `UnixDomainSocketAddress`
  (Java 16 and later, inferred, not checked here); ClojureScript build with
  shadow-cljs `:node-library` using `node:net`. It would reuse
  `tests/fixtures/automation/sdk_wire_cases.json` (82 cases [verified]) as
  its test data, like the other SDKs do
  (`sdk/python/tests/test_server_alignment.py:1-19`).
- sdk/cli (80 lines, click) could become a babashka script. babashka
  v1.13.229 has `babashka.process` and an HTTP client built in (web
  (helper): https://github.com/babashka/babashka/releases,
  https://book.babashka.org/). Whether babashka can open a Unix socket is
  unknown. Low value; keep the Python CLI.

### 4.4 The dashboard

- It is a 387-line HTML page with mock data from `src/dashboard/ipc.zig`
  (every command returns a `mock*` answer, `ipc.zig:8-40`). Nothing in the
  app loads it; only test modules in `build.zig:5268-5297` use it
  [verified].
- Recommendation: drop it from the port (Q5). If the sequences service
  becomes real, build a new dashboard in ClojureScript: shadow-cljs
  `:browser`, Replicant, `:browser-test` plus Playwright. It talks to the
  core with the `zbHost` handler, as it does today (`index.html:132-140`).

---

## Section 5: the agent host

### What it is [verified]

- 8,701 lines of Python in 31 files, with 20,339 lines of tests in 92 files.
- Pinned to `claude-agent-sdk==0.2.165` (`agent/host/pyproject.toml:6`).
  PyPI's latest is 0.2.174 (web, checked: https://pypi.org/pypi/claude-agent-sdk/json).
- The Python SDK bundles the Claude Code CLI binary. The host finds it at
  `claude_agent_sdk/_bundled/claude` (`agent/host/zb_agent_host/token.py:170-171`,
  `setup.py:843`). Each wheel is about 98 to 110 MB (`agent/host/uv.lock:156-160`).
- The host uses the SDK in six files: `chat.py:31`, `contract.py:13`,
  `bridge.py:24`, `options.py:11`, `token.py:170`, `route_probe.py:295`.
- App to host: NDJSON frames, one JSON object per line, each
  `{"v":1,"seq":n,"type":...}` (`frames.py:1`, `frames.py:26-32`). App frames:
  hello, open_session, prompt, interrupt, end_session, shutdown,
  tool_result (`chat.py:10-13`, `chat.py:243-267`). Helper frames: ready,
  session_opened, assistant_delta, assistant_message, tool_call, result,
  error, session_ended, reply_capped (`src/agent_frames.zig:34`). Error
  codes: auth, busy, overloaded, protocol, overflow, sdk, sandbox
  (`src/agent_protocol.zig:54`). End reasons: end, interrupt, crash,
  token_removed (`src/agent_protocol.zig:55`).
- Browser tools are an in-process MCP server: 14 tools in three groups,
  read, act and gated (`bridge.py:45-85`).
- About 4,770 of the 8,701 lines are OS containment: bwrap, seccomp,
  Seatbelt, netd, relay, Job Objects, libproc (sum of the sandbox rows
  above) [verified by wc].

### Agent SDK availability by language

- Official: **Python and TypeScript only**. The overview says the SDK is
  "programmable in Python and TypeScript". For other languages it says to
  "run the CLI as a subprocess with the `-p` flag" (web, checked:
  https://code.claude.com/docs/en/agent-sdk/overview).
- TypeScript: `@anthropic-ai/claude-agent-sdk` 0.3.312, with per-platform
  binary packages such as `-darwin-arm64`, `-win32-x64`, `-linux-x64`
  (web, checked: https://registry.npmjs.org/@anthropic-ai/claude-agent-sdk/latest).
- JVM: no official Agent SDK. A community Java SDK exists,
  `org.springaicommunity:claude-code-sdk` (web (helper), version unknown:
  https://central.sonatype.com/artifact/org.springaicommunity/claude-code-sdk).
  `com.anthropic:anthropic-java` covers only the Messages API (pane 1, web:
  https://platform.claude.com/docs/en/cli-sdks-libraries/sdks/java).
- Clojure: none found (web (helper), unconfirmed).
- The CLI's `--input-format stream-json` and `--output-format stream-json`
  flags are documented, but only part of the event schema is
  (web (helper): https://code.claude.com/docs/en/headless,
  https://code.claude.com/docs/en/cli-reference). Driving the CLI directly
  means owning an undocumented protocol.

### Options

| Option | What moves | Gain | Cost | Effort | Label |
|---|---|---|---|---|---|
| A. Keep Python (recommended) | Nothing. The Clojure core speaks the same NDJSON frames. | Official SDK. 20k lines of tests stay valid. Sandbox code is untouched. | Two runtimes ship (JVM and Python). Mac still needs the universal2 Python tree (`pyproject.toml:14-19`). | 1-2 agent-days | inferred |
| B. ClojureScript on Node with the TypeScript SDK (nbb or shadow-cljs `:node-script`) | chat, bridge, frames, options, token, redact (about 1,530 lines). | Official SDK. One Lisp across core and host. | Ships Node instead of Python. Sandbox code must still be Python or native. The host's tests must be rewritten. nbb 1.6.214 can require npm packages (web (helper): https://github.com/babashka/nbb); that it loads this SDK is untested. | 10-15 agent-days | inferred |
| C. Clojure on the JVM driving the CLI's stream-json directly | All of the host's SDK use. | One runtime for core and host. | No official SDK. The input schema is not documented. Every CLI update can break it. MCP tool server must be rebuilt. | 15-25 agent-days, high risk | inferred |
| D. Community Java SDK from Clojure | Same as C. | A library instead of a raw protocol. | Not official. Maturity unknown. | unknown | unknown |

Recommendation: **A**. The app-to-host boundary is already a clean
process boundary with a small, validated frame protocol. The Clojure core
(pane 1's design: a JVM core with small native hosts over a local socket)
only needs a frame reader and writer, which is small [inferred]. Revisit B
only if shipping Python on Mac becomes the main pain.

---

## Contracts on my side (input for pane 1's section 6)

All verified by reading the code at the cited lines.

1. **Page script API.** `__zbAutomation.handle(json)` with the ops listed
   in 4.1 (`automation.js:235-275`), the result shapes
   (`automation.js:1376-1398`), `inputAck()`, `navigationEnded(seq)` and
   `documentToken` (`automation.js:1537-1567`), the world name
   `zigbrowser-automation` (`src/webkit_shim.h:140`), and the message
   handlers `zbNavigation` and `zbFiles` (`src/webkit_shim.c:1910-1928`).
2. **SDK wire.** JSON-RPC 2.0 with a 4-byte big-endian length
   (`sdk/python/src/zigbrowser/client.py:550-556`). The per-session token
   sits next to the socket as `<socket>.token`, mode 0600
   (`client.py:476-485`), and is sent as `auth`
   (`sdk/node/src/client.ts:28`). The automation error range is -32015 to
   -32001 (`sdk/python/src/zigbrowser/errors.py:18`,
   `sdk/node/src/errors.ts:19-20`). The 82 shared wire cases live in
   `tests/fixtures/automation/sdk_wire_cases.json`.
3. **Flow request order.** Strict params, then the login cookie gate
   (`li_at` / `sessionid`, else -32011 logged_out), then pacing (default
   100 actions a day, 3-8 s pause; at the cap -32010 social_daily_cap),
   then the flow. Dry runs skip pacing
   (`src/automation/social_flow_routes.zig:7-29`).
4. **Owner action gates.** LinkedIn connect and follow may click; message
   may not (`src/linkedin.zig:147-152`).
5. **Telemetry privacy.** URLs, usernames and texts never reach the sink,
   only hashes, lengths and selector names
   (`social_flow_routes.zig:31-34`).
6. **On-disk: `<profile>/automation-pacing.json`.** Version 1, at most
   4096 bytes, fields `version, day, social{actions_today, daily_cap,
   min_delay_ms, max_delay_ms}, x{...}`, every field required, none
   unknown, written atomically with mode 0600
   (`src/automation/pacing_store.zig:1-8,20-43`).
7. **On-disk: `<profile>/agent-drawer.json`.** Version 1, `{version, x, y}`
   with x and y between 0 and 1 (`src/agent_drawer.zig:533-565`).
8. **Agent frames.** Listed in section 5 (`frames.py:1`,
   `src/agent_frames.zig:34`, `src/agent_protocol.zig:54-56`). Login
   error codes: cli, timeout, cancelled, shape, protocol, exchange
   (`src/agent_protocol.zig:431`).
9. **Agent tool names and schemas.** The 14 tools (`bridge.py:45-85`).

---

## Section 7: test strategy

The rule: tests that drive the product from outside become the port's
contract tests and do not change. Tests that import Zig code are rewritten
or dropped.

### Tier 1: keep unchanged, run against the ported build (contract tests)

| Tests | Why they are contracts | Label |
|---|---|---|
| `tests/fixtures/automation/sdk_wire_cases.json` (82 cases) with `sdk/python/tests/test_server_alignment.py` and the Node SDK tests | Shared wire cases the real server must accept (`test_server_alignment.py:1-19`). | verified |
| `tests/e2e/*.py`: 115 files take a `--binary` path (default `zig-out/bin/zigBrowser`) and 98 talk to the socket. Key ones: `automation_core_test.py`, `automation_input_test.py`, `automation_guard_test.py`, `automation_pacing_persist_test.py`, `automation_profile_test.py`, `social_flows_test.py`, `x_flows_test.py`, `nav_allow_test.py`, `nav_block_test.py`, `page_health_test.py`, `sdk_python_live_test.py`, `node_live_group_test.py` | They launch a binary and talk to it. Point `--binary` at the new launcher. | verified (counts by grep), inferred (reuse) |
| `tests/fixtures/{linkedin,instagram,x}/*.html` | Offline copies of the sites the flows run against. | verified |
| `e2e/automation_script.spec.ts` (Playwright, 3 engines) | Tests the page script's behaviour through `handle`. | verified |
| `agent/host/tests/` (92 files), above all `test_contract.py`, `test_chat*.py`, `test_bridge*.py`, `test_launcher_contract.py` | Pin the frames and the helper's behaviour. Unchanged if the host stays Python. | inferred |
| `tests/mac/` and `tests/windows/` live and package tests | Test the installed app (DMG, MSI). Re-point them at the new artifact. | inferred |

Rules for running them (from team memory, not code): only under a private
Xvfb, with a private HOME, XDG dirs and `--profile-dir`, and a short socket
path under `/tmp` because of the 108-byte AF_UNIX limit.

### Tier 2: rewrite as clojure.test

- The 134 top-level `tests/*.zig` files (30,468 lines) that test modules
  which move to Clojure. Their test names and cases become the spec for the
  Clojure code. Examples on my side: `tests/linkedin_test.zig`,
  `tests/instagram_test.zig`, `tests/x_test.zig`, `tests/social_test.zig`,
  the `tests/automation_expect*` and `tests/automation_guard*` families, and
  the 5 `tests/agent_drawer*` files (logic parts only) [verified names,
  inferred mapping].
- `tests/automation/bezier_test.zig`, `gaussian_test.zig`,
  `pacing_test.zig`, `stealth_test.zig`: pure math and logic, easy ports.
- Runner: Kaocha for the JVM (web (helper):
  https://clojars.org/lambdaisland/kaocha), shadow-cljs `:node-test` for
  `.cljc` code on the JS side.
- Malli schemas (0.20.3, web (helper): https://github.com/metosin/malli/releases)
  for the wire shapes, with generative tests from those schemas [inferred].

### Tier 3: drop or keep native

- Drop: `tests/automation/js_contract_test.zig` (it greps the JS source
  for strings), and `tests/dashboard/`, `tests/sequences/` if those
  modules are dropped.
- Keep native: the 12 `tests/*.c` files and any Zig or C tests of code that
  stays native (pane 1's list).

### New work the port needs

1. **Golden transcripts** [inferred]. Before porting, run the Tier 1 e2e
   suite against the current Zig build and record every socket request and
   response as JSONL. Replay them against the Clojure build and diff. This
   catches field-order, null and error-data drift that the tests do not
   assert on.
2. **One launcher seam** [inferred]. Make every e2e test read the binary
   path from one variable, so the same suite runs on both builds side by
   side.
3. **Frame recorder** [inferred]. Record app-to-helper frames in the
   current build and replay them against the Clojure core's frame code.

---

## Phase inputs for pane 1's section 8 (my side only)

Agent-days are rough. They assume pane 1's core (router, engine, socket,
native hosts) exists by the time each phase starts.

| Phase | What ships | Effort (agent-days) | Confidence |
|---|---|---|---|
| P0. Contract capture | Golden transcripts, frame recordings, one launcher seam in the e2e suite. No product change. | 3-5 | medium |
| P1. Flows and pacing in `.cljc` | LinkedIn, Instagram, X, social, flow runner, routes, pacing, pacing store, bezier, gaussian, stealth. About 5,000 Zig lines. Tier 1 flow tests green. | 8-12 | medium-low |
| P2. Agent host boundary | Clojure frame reader and writer for the unchanged Python host. Host tests and drawer e2e green. | 1-2 | medium |
| P3. Drawer logic | `agent_drawer.zig` as `.cljc`, native UIs unchanged. | 2-3 | medium |
| P4. Tier 2 test rewrite (my modules) | About 25 to 35 Zig test files ported to clojure.test. Can run alongside P1. | 5-8 | low |
| Optional: page script in Squint or ClojureScript | Same behaviour, Playwright green on 3 engines, size budget met. | 6-10 | low |
| Optional: ClojureScript drawer in a privileged web view | One drawer for 3 OSes, real-screen sign-off. | 15-25 | low |
| Optional: Clojure SDK (`.cljc`) | JVM and Node client, wire cases green. | 3-5 | medium |
| Optional: agent host on Node (option B) | chat, bridge and frames on the TypeScript SDK. | 10-15 | low |
| Optional: dashboard in ClojureScript | Only when the sequences service exists. | 5-8 | low |

Required total on my side (P0 to P4): about 19 to 30 agent-days.

---

## Risks (input for pane 1's section 1)

1. **Lost hard-won behaviour.** The flows and the page script are full of
   fixes from live incidents (for example the exact-text rule in
   `src/flow_steps.zig:17-26` and the navigation-ordering notes in
   `automation.js:37-82`). A rewrite can lose them silently. Mitigation:
   golden transcripts and keeping automation.js as is.
2. **Drawer security.** Moving the drawer to web content reverses
   `docs/agent-drawer.md:92-94`. Mitigation: keep native until the owner
   decides (Q2).
3. **No JVM Agent SDK.** Moving the host to Clojure means owning the CLI
   protocol. Mitigation: keep the Python host.
4. **Test loss.** 30,468 lines of Zig unit tests do not carry over, and
   some tests check source text, not behaviour. Mitigation: Tier 1 first,
   Tier 2 rewrite during each phase.
5. **ClojureScript `:advanced` renaming** breaks wire field names if the
   page script or drawer moves to ClojureScript. Mitigation: string keys,
   `^js` hints, and the Playwright suite.

---

## Section 9: open questions for the owner (my side)

Each question has my recommendation.

- **Q1. Is the goal one language everywhere, or Clojure for the core?**
  Recommendation: Clojure for the core and the flows. Keep the page script
  in JS, the agent host in Python, and the SDKs in Python and TypeScript.
- **Q2. Should the drawer stay native, or become one ClojureScript UI in a
  privileged web view?** Today it is native on purpose
  (`docs/agent-drawer.md:92-94`). Recommendation: stay native for the first
  release. Port only its logic. Decide on a web drawer after the core
  ships, with your real-screen check.
- **Q3. Should automation.js be rewritten?** Recommendation: no. If you
  want Clojure syntax there, use Squint, with a size budget and the
  Playwright suite on all three engines.
- **Q4. Should the agent host stay in Python?** Recommendation: yes.
  Only Python and TypeScript have an official Agent SDK. Revisit a
  Node host (ClojureScript plus the TypeScript SDK) only if shipping Python
  on Mac becomes the main pain.
- **Q5. Drop the dashboard and the sequences client from the port?** The
  app does not use them today. Recommendation: drop them; they stay in git
  history. Build a ClojureScript dashboard when the sequences service is
  real.
- **Q6. Do you want a Clojure SDK for users?** Recommendation: not in the
  first release. Add a small `.cljc` client later if users ask.
- **Q7. Sign-in policy (not caused by the port).** The Agent SDK overview
  says third-party apps should not offer claude.ai login unless approved,
  and should use API keys (web, checked:
  https://code.claude.com/docs/en/agent-sdk/overview). The drawer uses a
  claude.ai setup-token (`docs/agent-drawer.md:29-32`). Recommendation:
  confirm approval or add an API-key path before launch, whatever happens
  with the port.
- **Q8. Upgrade the pinned SDK?** The repo pins 0.2.165; PyPI has 0.2.174.
  Recommendation: a separate task, not part of the port.
