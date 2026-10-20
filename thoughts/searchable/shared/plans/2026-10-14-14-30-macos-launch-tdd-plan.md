---
date: 2026-10-14T14:30:00-04:00
planner: cc_3 / JadeBeacon (Opus 4.8)
git_commit: ed13e5ef582d1256cbe92bf06bb0bb3526210ca1
branch: zb-automation-integration-2026-10-10-11-59
repository: zigBrowser
topic: "macOS launch support for zigBrowser — TDD implementation plan"
tags: [plan, tdd, macos, wkwebview, appkit, seatbelt, universal-build, automation, drawer, sandbox, launch-critical]
status: plan for review (rev 11)
rev: 11
last_updated: 2026-10-20
last_updated_by: cc_3 / JadeBeacon
last_updated_note: "Rev 11 records MS1b GREEN (commit 3421428, option d): the WKWebView ObjC shim is built by the Apple toolchain as a chained-fixups dylib (xcrun clang -dynamiclib, -Wl,-fixup_chains + -undefined dynamic_lookup; -install_name @executable_path/../Frameworks; exe sets rdynamic macOS-only to export the two back-refs zb_ipc_dispatch/zb_policy_decide), so the SIGNED x86_64 binary runs (was SIGSEGV at [ZBAppHost init]; cause = zig 0.16 classic LC_DYLD_INFO_ONLY into signed __DATA_CONST). The MS1 bundle is now {browser + webview-shim dylib}; resource_phase accepts the empty-resources set only for that exact 2-component shape (6002 bypass protection kept). MS1.3 gains release_least_privilege (disable-library-validation forbidden in a release manifest/binary; ad-hoc dev/test only). ms1b_signed_gate.sh is registered as `zig build ms1b-gate`; validated rc 0 on both Macs (x86_64+arm64, ad-hoc+hardened). Linux/Windows build unchanged. (Frontmatter rev was stale at 6 while body sections advanced to rev 10; bumped to 11.) Shim surface confirmed by BlackRobin (6125)."
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
- **Rev 5** (this): answers RoseCat's **one remaining rev-4 blocker** (mail `5501`), which
  confirmed three of the four db02324 blockers closed and left a narrow one: the rev-4 ABI
  table claimed the config flags' unsupported mechanism was `int<0 + out_err`, but the pinned
  ABI has **`void` setters, bare-`int` getters, and no setter at all for `--renderer`** — that
  error path is not executable. Rev 5 moves the unsupported decision to a **named fallible
  app-level Zig seam, `applyMacBackendFlag(flag, value) !void` in `src/webkit.zig` (called from
  `src/app.zig`)**, which validates each flag/value **before** any void C setter and, on an
  unsupported value, **refuses — the real binary exits nonzero with an exact message and never
  touches the C ABI**; a supported value is applied (void setter and/or `WKPreferences`).
  `--renderer` is handled entirely by this Zig seam (no C ABI). The impossible `out_err` claim is
  dropped from the table and MS3.2, and `mac_config_flags_test.py` is named for both the
  supported-applies and unsupported-exits-nonzero cases. Rev 5 also records the advisory **F2**
  finding (macOS has no per-sandbox loopback for the `127.0.0.1:3128` proxy hop) as an **open
  design item in MS6** that points at the shared sandbox interface, to be settled by BlackRobin
  and RoseCat in the drawer plan — not here. Re-pinned to HEAD `74413b0`.
- **Rev 6** (this): answers RoseCat's **one rev-5 blocker** (review `ed13e5e`): rev 5 left the
  MS6 egress transport as an explicitly unsettled open item, which is not implementation-ready.
  Rev 6 **pins it** as a shared `SandboxBackend` **egress capability** — the backend supplies
  both the loopback proxy *endpoint* and the *policy*. macOS: **host netd on an OS-selected
  per-session `127.0.0.1:<port>`**; the generated CLI/helper Seatbelt profile permits **only** that
  endpoint; `HTTPS_PROXY`/`HTTP_PROXY` name that exact port; netd keeps the exact CONNECT/SNI
  allowlist; **each hook's own profile permits only loopback 51091/31337, with no proxy endpoint
  and no API path**; and MS6.4 proves the endpoint, both bridge positives, every denial, and that a
  hook cannot reach the proxy. The **Unix-socket-proxy option is ruled out** (the bundled CLI
  rejects Unix-socket proxy URLs — BlueBeaver 5503), so a TCP `host:port` hop is mandatory. Linux
  realizes the same capability with private-netns fixed ports + relays. The capability is captured
  in the MS0 launch spec; MS6 realizes the macOS half. Re-pinned to HEAD `ed13e5e`.
- **Rev 7** (this): a docs-only scope correction after MS1's red landed and both Macs built
  (a universal fat binary was assembled with `lipo`, ad-hoc signed, and its entitlements
  verified on both hosts; JadeBeacon). The MS1.1 census required four fat Mach-O components
  (browser, Python runtime, Claude CLI, helper launcher), but the macOS MS1 build ships
  **only the browser** (`build.zig:168` installs `zigBrowser`; the agent runtime is a separate
  non-default step), and there is no universal2 Python (the Intel host has Xcode python 3.9,
  the arm host Homebrew 3.14). Rev 7 sets MS1's **fixed inventory to `{browser}`** — "complete"
  means every component the bundle **actually ships** — while keeping the census mechanism and
  its fail-closed tests unchanged, and moves the three agent-runtime roles (plus the two-tree
  resource-compat check) into **MS5's red**, where the macOS Python runtime/CLI/launcher are
  first installed and the Intel 3.9 vs arm 3.14 Python mismatch is exactly the incompatibility
  the `resource_compat` oracle exists to catch. Re-pinned to HEAD `f18a5f1`.
  (Orchestrator-directed; sent to RoseCat for review before the MS1 green is written against it.)
- **Rev 8** (this): answers RoseCat's two rev-7 representation blockers (mail `5989`, review
  `a15a66b`), both contract-shape — the `{browser}` scope itself was accepted. (1) The helper
  launcher `zb-claude` is a **generated Python shebang script** (`token.py:100-140`, written at
  `setup.py:492`) at `runtime/bin/zb-claude`, **not a Mach-O**, so MS5.1c cannot require it as a
  fat component. Rev 8 classifies the MS5 roles: the **Python interpreter and the bundled Claude
  CLI are native/fat Mach-O**; the **launcher is a generated script** whose bytes must be
  byte-compatible across arches — a **resource** the `resource_compat` oracle checks, not a fat
  Mach-O role (a universal2 runtime at one python path makes the wrapper identical; if it differs,
  the oracle fails closed). (2) A browser-only MS1 ships **no non-exec resource**, so MS1's
  inventory `resources` is **empty by design** and the two-tree oracle is **first exercised at
  MS5** (where the runtime's non-exec files exist in two per-arch trees) — not a silent drop:
  MS1.1 states it, and the oracle's fail-closed-on-empty stays an MS5 guard. Re-pinned to `99f11b1`.

- **Rev 9** (this): answers RoseCat's rev-8 blocker (mail `5995`, review `6a3980c`) — the MS5 role
  typing was accepted, but MS1's `resources: []` was still **prose that resolved the oracle conflict
  by not calling `resource_compat` at all**, which "is indistinguishable from accidentally deleting
  the check." Rev 9 makes it an **executable, mutation-resistant, shape-checked phase policy**:
  `resource_phase(milestone, inventory, …)` (`tests/e2e/mac_universal_test.py`) accepts an empty
  resource inventory **only for the EXACT browser-only MS1 bundle** — milestone `MS1` AND exactly
  one component at the fixed browser path `bin/zigBrowser` AND no resources — and **fails closed for
  any other empty shape** (MS5, unknown/"" label, an extra or non-browser component, or an MS5-shaped
  manifest relabeled MS1); otherwise it runs the two-tree oracle. `mac_resource_compat.py` gains a
  **required `--milestone`**, passes the **whole inventory**, and routes through the gate, so the
  green **calls** it at every milestone (MS1 included) rather than skipping it. The label alone was a
  bypass (RoseCat 6002): checking only `--milestone` let a python-runtime manifest relabeled MS1 pass.
  Tests (`58551bb`): MS1-browser-only-empty passes *and asserts*; MS5-empty, unqualified-empty,
  MS1-extra-component, MS1-non-browser-component, MS5-shaped-relabeled-MS1, and MS5-nonempty-mismatch
  all fail. The executable gate landed in `c53b580` then `58551bb`; re-pinned to HEAD `774ce31`.
- **Rev 10** (this): the MS1 green ran on both Macs and surfaced two macOS realities, split out per the
  user's "split it out, fix now". (1) The **ad-hoc-signed x86_64 binary segfaults at startup** in
  `-[ZBAppHost init]`'s `[super init]` (`0xf0000001`); the unsigned binary and the signed arm64 slice
  run fine — a zig-linker/codesign/ObjC interaction. So **MS1 runs the UNSIGNED universal binary** for
  MS1.1/MS1.2 and signs a **copy** only for the static MS1.3 `codesign -d` check; **MS1 does NOT prove
  a signed binary RUNS**, and the new slice **`MS1b`** does (well before MS9's Developer-ID signing).
  (2) zig 0.16's `fromPosixSignalContext` mis-aligns the x86_64 macOS signal `ucontext_t` and panics,
  hiding the real fault; `src/main.zig` **disables the segfault handler on macOS only** (Linux keeps
  the exact default). MS1 is GREEN on both Macs through `tests/mac/gate.sh` (universal fat binary,
  executing-arch readback x86_64 + arm64, MS1.3 entitlements on the signed copy, m9 render/reply/
  load-fail, the `--milestone MS1` resource gate). Cause write-up: `scratchpad/ms1/CRASH_CAUSE.md`.

## Rev 9 — MS1 empty-resource state made an executable, fail-closed phase contract (RoseCat 5995)

RoseCat accepted the rev-8 MS5 role/resource typing but BLOCKED on MS1's empty-resource exception
being prose-only (it "resolved the oracle conflict by not calling `resource_compat`"). A skip
conditional is indistinguishable from deleting the check, so rev 9 replaces it with a typed gate.

| # | Blocker (5995) | Resolution in rev 9 | Where |
|---|---|---|---|
| 1 | MS1's `resources: []` is enforced only by *not invoking* `resource_compat`; there is no typed MS1-only policy and no red proving empty is accepted only for MS1 while staying fail-closed at MS5. (Rev-9 first pass checked only the `--milestone` label — a bypass: an MS5-shaped manifest relabeled MS1 passed, RoseCat 6002.) | `resource_phase(milestone, inventory, tree_a, tree_b)` is the typed, **shape-checked** gate the green **calls at every milestone**, taking the whole inventory: an empty resource set passes **only for the EXACT browser-only MS1 bundle** (milestone `MS1` + exactly one component at `bin/zigBrowser` + no resources); **any other empty shape fails closed** (MS5, unknown/"" label, extra/non-browser component, MS5-shaped relabeled MS1); a nonempty set runs the two-tree `resource_compat` oracle. `mac_resource_compat.py` passes the inventory and a **required `--milestone`**. Tests pin MS1-browser-only-passes, MS5/unqualified-empty-fails, extra/non-browser-component-fails, MS5-shaped-relabeled-MS1-fails, MS5-nonempty-mismatch-fails; a mutant dropping the shape/milestone check is caught. | MS1.1, MS5.1c, `tests/e2e/mac_universal_test.py` (`resource_phase`, `MS1_BROWSER_GLOB`), `mac_resource_compat.py` |

Re-pinned to HEAD `774ce31` (the executable gate + tests are `c53b580`).

## Rev 8 — MS5 role classification + MS1 resource rule corrected (docs only; RoseCat 5989)

RoseCat approved the `{browser}` MS1 scope (`build.zig:163-173`) but BLOCKED rev 7 on two
representation contradictions in how components and resources are typed. Both are fixed in docs.

| # | Blocker (5989) | Resolution in rev 8 | Where |
|---|---|---|---|
| 1 | `zb-claude` is a generated Python shebang script (`token.py:100-140`, written at `setup.py:492`), real path `runtime/bin/zb-claude`, **not a Mach-O**; `component_census` resolves roles only from the Mach-O map, so MS5.1c's "all three roles are fat Mach-O" can never green. | Classify the MS5 roles by their real form: **`python-runtime` and `claude-cli` are native/fat Mach-O** (added as `components` with their real `path_glob`s at MS5); the **`helper-launcher` (`runtime/bin/zb-claude`) is a generated script**, verified as a **byte-compatible resource** by the `resource_compat` oracle (or re-classified if a native launcher is ever introduced) — NOT a fat-Mach-O role. The embedded python/CLI paths make the wrapper byte-identical only when MS5 ships one universal2 runtime at one path; otherwise the oracle fails closed. | MS5.1c |
| 2 | Browser-only MS1 has no declared non-exec resource; the sole current resource `runtime.json` is deferred, and `mac_resource_compat.py` fails closed on an empty list, so MS1 can neither keep nor drop it — and rev 7 wrongly folded the oracle into the MS1 census. | The MS1 universal browser is a **single fat Mach-O with no non-exec resource**, so MS1's inventory `resources` is **empty by design** and MS1 **does not invoke** the `resource_compat` oracle — stated explicitly in MS1.1 (not a silent skip). The **first production resource check is at MS5**, on the runtime's non-exec files (`runtime.json`, the generated `zb-claude`/`zb-hook-run`/`zb-net-relay` scripts, the `*.json` manifests) across the two per-arch trees. The oracle's **fail-closed-on-empty stays an MS5 guard** (a milestone that ships resources must declare them; MS1 ships none and never calls it). The per-host census still checks Mach-O fatness + role presence + any declared-resource presence. | MS1.1, MS5.1c, `mac_resource_compat.py` |

Re-pinned to HEAD `99f11b1`.

## Rev 7 — MS1.1 component scope corrected to what the bundle ships (docs only)

MS1's red (`0e41ae1` → `ec434bc` → `d48b71c`, JadeBeacon) landed and both Macs built: a universal
fat Mach-O (x86_64 + arm64) assembled by `lipo`, ad-hoc signed, with its entitlements verified on
both hosts. Building it surfaced that the MS1.1 census over-specified for MS1 — it required four
fat components, but the macOS MS1 bundle ships **only the browser**.

| # | Finding | Resolution in rev 7 | Where |
|---|---|---|---|
| 1 | The MS1.1 census requires the Python runtime, Claude CLI and helper launcher as fat Mach-O, but `build.zig:168` installs only `zigBrowser`; the agent runtime is a separate non-default step, not in the macOS bundle at MS1. A green could never satisfy the four-component census, and there is no universal2 Python (Intel Xcode 3.9 vs arm Homebrew 3.14) to make one fat. | **MS1's fixed inventory is `{browser}`** — the only native component the MS1 bundle ships; "complete" = every component actually shipped, so the census stays honest and fail-closed. The census mechanism, the whole-bundle Mach-O scan, the fail-closed probe, the two-tree `resource_compat` oracle and all their tests are **unchanged** — only the MS1 inventory narrows. | MS1.1, `packaging/macos/universal_components.json` |
| 2 | The three agent-runtime roles still must be verified fat **somewhere**, with their cross-arch resources checked before `lipo`. | **MS5's red MUST add** the `python-runtime`, `claude-cli` and `helper-launcher` roles to the universal-components inventory and assert the two-tree `resource_compat` check, because MS5 is where macOS provisioning first installs the Python runtime + helper (MS5.1). The Intel 3.9 vs arm 3.14 Python is exactly the mismatch the oracle catches, so MS5's provisioning must produce a universal2 (or per-arch-reconciled) runtime or fail that check. | MS5.1, MS5 gate |

Re-pinned to HEAD `f18a5f1`.

## Rev 6 — RoseCat's one rev-5 blocker, answered (review ed13e5e)

RoseCat's exact review of `c8b646a` confirmed the config-ABI blocker **closed** (the fallible
`applyMacBackendFlag` seam), but BLOCKED on one point: rev 5 made the load-bearing MS6 egress
transport an explicitly **unsettled open design item**, and BlueBeaver's measurement (mail `5503`)
ruled out the Unix-socket-proxy option, so an implementation-ready plan must **pin** the remaining
viable mapping before MS6.

| # | Blocker (ed13e5e) | Resolution in rev 6 | Where |
|---|---|---|---|
| 1 | MS6 egress is left open; the Linux-private `127.0.0.1:3128` listener can't be copied to a shared macOS loopback port, and the CLI rejects Unix-socket proxy URLs (5503) | **Pinned exactly** as a shared `SandboxBackend` egress capability (endpoint + policy supplied by the backend): (1) host netd on an **OS-selected per-session `127.0.0.1:<port>`**, CLI/helper profile permits **only** that loopback endpoint; (2) `HTTPS_PROXY`/`HTTP_PROXY` name that port, netd keeps the exact CONNECT/SNI allowlist (arbitrary host processes gain nothing — they already have host egress and the proxy grants only the same allowlist); (3) **each hook its own profile permitting only loopback 51091/31337**, no proxy endpoint, no API path; (4) the real-binary fake-API test proves the endpoint, both bridge positives, every MS6.4 denial, and that a hook cannot reach the proxy. **Linux** realizes it with private-netns fixed ports + relays; **macOS** with the ephemeral host-loopback proxy + per-process Seatbelt port rules. Unix-socket proxy ruled out (5503) | MS0 launch spec (egress capability + realization), MS6 "Egress mapping" §, MS6.4 |

## Rev 5 — RoseCat's one remaining rev-4 blocker, answered (review mail 5501)

RoseCat's exact review of `74413b0` (mail `5501`) confirmed the MS8.3 approval-source move, the
in-process CGEvent/CGEventPost split, and the complete 75-export inventory + cookie-move as
**closed**, and left **one** narrow blocker.

| # | Blocker (5501) | Resolution in rev 5 | Where |
|---|---|---|---|
| 1 | The config-flag ABI names an impossible error path: the table/MS3.2 say flags return `int<0 + out_err`, but `zb_app_set_hw_policy`/`zb_app_set_media_source` are **`void`**, their getters are bare `int`, and `--renderer` has **no C setter** — so no such channel exists (same class as rev-3 #2) | Moved the unsupported decision to a **named fallible Zig seam `applyMacBackendFlag(flag, value) !void`** (`src/webkit.zig`, called from `src/app.zig`): it validates each flag/value **before** any void C setter; a supported value is applied (void setter and/or `WKPreferences`), an unsupported value is **refused** so the **real binary exits nonzero with an exact message** and the C ABI is never touched. `--renderer` is handled entirely by this Zig seam. The void setters/int getters are simply **always implemented** (no error channel claimed). Dropped the `out_err` claim from the ABI table and MS3.2; named `mac_config_flags_test.py` for the supported-applies and unsupported-exits-nonzero cases (with a before-validate / swallow-error mutant) | ABI table (config rows + uniform-mechanism note), MS3.2 |

**Also in rev 5 (advisory F2, orchestrator-directed):** rev 5 recorded the F2 egress-hop finding as
an MS6 open design item (macOS has no per-sandbox loopback for the rev-16.2 `127.0.0.1:3128` hop).
**Rev 6 closes that item** — it is no longer open: the egress capability is pinned in MS0 and MS6
(see the Rev 6 table and MS6 "Egress mapping" §), with the Unix-socket-proxy option ruled out by
BlueBeaver's CLI measurement (5503).

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

- One C ABI, three backends: `resolveBackend` build.zig:1107-1114; `configureMacosBackend`
  build.zig:1702+ (**since MS1b `3421428`**: builds `wkwebview_shim.m` as a separate
  Apple-toolchain dylib — `xcrun clang -dynamiclib -Wl,-fixup_chains` → `LC_DYLD_CHAINED_FIXUPS`,
  `-install_name @executable_path/../Frameworks/libwkwebview_shim.dylib` — which the exe links and
  installs to `Frameworks/`; the exe sets `rdynamic` macOS-only to export the two shim back-refs. It
  is **no longer compiled into the exe**); `CheckMacosBackendStep` build.zig:79-105.
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
- **Closure tests** are Tier-1 real-binary e2e; ClosureMaps pinned to HEAD ed13e5e (all three
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
  channel (FIFO then fd 3, never env); **the egress capability (rev 6) — the backend supplies both
  the loopback proxy *endpoint* and the *policy*: the CLI/helper reach egress only at a
  backend-supplied `127.0.0.1:<proxy-port>`, and netd enforces the exact CONNECT/SNI allowlist
  (`api.anthropic.com` + census-proven CLI domains, fail-closed)**; the two bridge ports (51091,
  31337); the shares (agent home read-only, workspace read-only, scratchpad read-write); a per-hook
  confinement launcher (**each hook confined to only loopback 51091/31337, with no proxy endpoint
  and no API path**); and a lifetime contract (everything dies with the browser).
- **Egress capability realization (rev 6, pinned per RoseCat `ed13e5e`):** the *endpoint* is
  backend-chosen, the *policy* (allowlist + per-process reachability) is backend-enforced. **Linux**
  realizes it with a **private network namespace, fixed proxy/bridge ports and relays** (the hook's
  own netns seals it). **macOS** realizes it with an **ephemeral host-loopback proxy** — netd
  listens on an **OS-selected, per-session `127.0.0.1:<port>`** — plus **per-process Seatbelt port
  rules**: the generated CLI/helper profile permits **only** that one loopback endpoint, and each
  hook's profile permits **only** loopback 51091/31337 (no proxy endpoint, no API path). The
  bundled CLI rejects Unix-socket proxy URLs (BlueBeaver 5503), so a TCP `host:port` hop is
  mandatory on every backend; `HTTPS_PROXY`/`HTTP_PROXY` name that exact backend-supplied port.
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
**Then** **every native Mach-O the MS1 bundle ships** is present per arch and the result is a fat
Mach-O with both slices. **At MS1 the bundle ships only the browser** (`build.zig:168` installs
`zigBrowser`; the agent runtime is a separate non-default step), so MS1's fixed inventory
(`packaging/macos/universal_components.json`) is **`{browser}` with an empty `resources` list** —
"complete" means every component actually shipped, and the universal browser is a **single fat
Mach-O with no non-executable resource**. The **per-host census mechanism is general and
unchanged** (it scans the whole bundle for every Mach-O and requires each fat, fails closed on an
unprobeable file, and checks that any declared resource is present); only the MS1 inventory is
narrow. The empty state is **not a skip**: the green **calls the typed phase gate**
`mac_resource_compat.py --milestone MS1` (rev 9), and `resource_phase` (`mac_universal_test.py`)
**accepts an empty inventory only for the EXACT browser-only MS1 bundle** — milestone `MS1` + exactly
one component at the fixed browser path `bin/zigBrowser` + no resources — and **fails closed for any
other empty shape**, so MS1's exception is asserted, shape-checked and mutation-resistant — the
`--milestone` label alone is not enough (RoseCat 5995/6002). The two-tree
`resource_compat` oracle (the nonempty branch of the gate) is **first exercised at MS5** (behavior
MS5.1c), where macOS provisioning installs the Python runtime, the Claude CLI and the generated
launcher, so the non-exec runtime files exist in two per-arch trees and the Intel-3.9-vs-arm-3.14
Python mismatch is exactly what it must catch.

**Updated by MS1b (`3421428`):** since the ObjC shim ships as a dylib the exe links, the MS1 bundle
is now **`{browser, webview-shim}`** — `bin/zigBrowser` + `Frameworks/libwkwebview_shim.dylib`, both
fat. `resource_phase` accepts the empty-resources set only for that **exact two-component** shape;
the 6002 bypass protection is kept (browser-alone, wrong-shim-path, MS5-shaped, non-browser all fail
closed). The census now requires both Mach-Os fat.

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

**Updated by MS1b (`3421428`): a release least-privilege rule.** `release_least_privilege`
(`mac_universal_test.py`) FAILS a release entitlements manifest OR signed binary that carries
`com.apple.security.cs.disable-library-validation`. That key is allowed ONLY in ad-hoc dev/test
builds (a hardened dev exe loading the ad-hoc shim dylib); MS9's real Developer ID signs exe+dylib
under one team, so library validation passes without it. Unit-tested in `mac_universal_census_test`.

**MS1 runs the UNSIGNED universal binary; the MS1.3 check is static (rev 10).** The ad-hoc-signed
x86_64 binary **segfaults at startup in ObjC `-[ZBAppHost init]` (`0xf0000001`)** — a
zig-linker/codesign interaction (see rev 10 and `MS1b`). So MS1.1 (fat) and MS1.2 (executing-arch
readback, which RUNS the binary) run the **unsigned** universal binary (it is fat and runs
natively on both arches), while MS1.3 signs a **copy** and reads it with `codesign -d` only
(static; never run). **MS1 therefore does NOT prove that a signed binary RUNS** — that is the job
of the new slice **`MS1b`**, and the real production signature (Developer ID + hardened runtime) is
MS9. `mac_universal_test.py` takes `--signed-binary` for the static MS1.3 check; `gate.sh` pushes
the unsigned universal to run and the signed copy (outside the bundle) for `codesign -d`.

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

**Zig 0.16 segfault handler disabled on macOS (rev 10).** `std.debug.cpu_context.fromPosixSignalContext`
`@alignCast`es the x86_64 macOS signal `ucontext_t` and panics "incorrect alignment", so the first
signal the browser takes aborts via a misleading panic with a corrupted unwind (it hid the real
ObjC-init fault for a whole debugging cycle). `src/main.zig` sets `std_options.enable_segfault_handler
= (os.tag != .macos AND std.debug.default_enable_segfault_handler)` — OFF on macOS only; every other
target keeps the exact default, so **the Linux build is unchanged**. This is an upstream zig-0.16
issue; disabling the handler on macOS gives honest crash reports and is kept regardless of the signing
fix. (It does NOT by itself make a signed binary run — see `MS1b`.)

---

## MS1b: the signed x86_64 binary runs (zig-linker / codesign / ObjC-init crash) — LANDED `3421428`

**STATUS: LANDED (green `3421428`, option d).** The ad-hoc-signed x86_64 binary ran the m9 workload
rc 0 on both Macs (ad-hoc AND hardened-runtime+`disable-library-validation`).

**Cause (confirmed).** zig 0.16's self-hosted Mach-O linker emits only the classic
`LC_DYLD_INFO_ONLY` rebase scheme, never `LC_DYLD_CHAINED_FIXUPS`. On a **code-signed x86_64** binary
the classic rebases into the signed `__DATA_CONST` (which holds the ObjC metadata) are left at their
raw on-disk values, so `-[ZBAppHost init]`'s `[super init]` dereferences a garbage class/superclass
pointer (`EXC_BAD_ACCESS 0xf0000001`). arm64 dyld handles the same scheme; unsigned works. Hardened
runtime (MS9 shape) hits it too — so MS1b is a HARD prerequisite of MS9 (dependency order).

**Fix (option d).** Build the WKWebView ObjC shim (`src/wkwebview_shim.m`) with the **Apple toolchain**
(`xcrun clang -dynamiclib` → ld64 → `LC_DYLD_CHAINED_FIXUPS`) as a separate dylib, NOT compiled into
the zig exe (`build.zig` `configureMacosBackend`). Key flags: `-Wl,-fixup_chains` (REQUIRED — the
shim's two exe back-references need `-undefined dynamic_lookup`, which otherwise forces classic
fixups) and `-install_name @executable_path/../Frameworks/libwkwebview_shim.dylib` (anchored, so a
hardened process loads it with no relative-rpath rejection). The exe links the dylib and sets
`rdynamic` **macOS-only** to export the two back-ref symbols — `zb_ipc_dispatch` (`src/ipc.zig`) and
`zb_policy_decide` (`src/nav_policy.zig`) — for the dylib's dynamic_lookup. Linux/Windows build and exe
exports are unchanged. Shim surface confirmed by BlackRobin (agent-mail 6125).

**MS1 bundle reshaped to {browser + shim dylib}.** Because the exe now links the dylib, even the
UNSIGNED MS1 run ships it: `gate.sh` lipos+ships the unsigned fat dylib into `Frameworks/`;
`universal_components.json` + `resource_phase` accept the empty-resources set **only for the exact
`{bin/zigBrowser, Frameworks/libwkwebview_shim.dylib}`** two-component shape (the 6002 bypass
protection is kept — browser-alone, wrong-shim-path, MS5-shaped, non-browser all still fail closed).
The census auto-requires the dylib fat (both slices).

### Behavior MS1b.1: a signed universal binary runs the m9 workload on x86_64 — GREEN
**Given** the universal exe + shim dylib, both ad-hoc signed (`codesign -s - --entitlements …`),
**When** they run the m9 workload on the Intel Mac,
**Then** the page loads and `WINCOUNT`/`TITLE`/`NAV` print with no crash. 🔴 Red (`bf0a66f` →
`2f6214f` → `41882ae`, unregistered): the signed x86_64 launch SIGSEGV'd at `0xf0000001`, 3×, right
reason. 🟢 Green (`3421428`): it runs — on x86_64 AND arm64, ad-hoc and hardened. m9 render drives
`zb_policy_decide` and m9 reply-channel drives `zb_ipc_dispatch`, so both dylib→exe back-refs are
exercised through the signed build.

### Durable root-cause evidence
Concrete evidence behind the cause + fix (so the record does not depend on ephemeral scratch):
1. **Minimal zig+ObjC repro** (a tiny zig main calling an ObjC class's `[super init]`): classic
   `LC_DYLD_INFO_ONLY`; **unsigned → rc 0; ad-hoc signed → SIGSEGV in `[super init]`** — reproduces
   the browser crash in isolation, independent of our code.
2. **Fixup-scheme inspection** (`otool -l`, `dyld_info -fixups`): the zig-linked binary has
   `LC_DYLD_INFO_ONLY` only (no `LC_DYLD_CHAINED_FIXUPS`); signing appends only `LC_CODE_SIGNATURE`
   and leaves the rebase entries into `__DATA_CONST` (where the ObjC `__objc_classlist`/`classrefs`/
   `data` sections live) at raw on-disk values → garbage class/superclass pointers.
3. **arch split:** the arm64 slice uses the same classic scheme yet signed arm64 **runs** — the fault
   is x86_64 dyld's handling of classic rebases into a signed `__DATA_CONST`.
4. **signature kind:** ad-hoc AND hardened-runtime (`--options runtime`, the MS9 shape) both crash on
   x86_64 → MS9 would hit it; MS1b is a hard MS9 prerequisite.
5. **Fix validated:** the ObjC shim built by Apple ld64 with `-Wl,-fixup_chains` has
   `LC_DYLD_CHAINED_FIXUPS`; the signed universal exe+dylib then run the m9 workload **rc 0 on both
   Macs, ad-hoc AND hardened** (hardened needs same-team signing — MS9's Developer ID — or, for
   ad-hoc dev only, `disable-library-validation`). Options (e)/(c) were not needed.
Working notes retained in `scratchpad/ms1/CRASH_CAUSE.md` + `MS1b_INVESTIGATION.md` while they exist;
the summary above is the durable record.

**Gate (MS1b):** `tests/mac/ms1b_signed_gate.sh` (registered as `zig build ms1b-gate`) SIGNS both the
universal exe and the universal shim dylib, installs the signed pair, and runs the m9 workload +
exec-arch probe on BOTH Macs, fail-closed. Validated rc 0 both Macs. The MS1.3 least-privilege rule
(`release_least_privilege`) fails a release manifest/binary carrying `disable-library-validation`
(ad-hoc dev/test only). Coordinated with **BlueBeaver** (build/gate) and **BlackRobin** (shim).

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
`ed13e5e` (the `webkit_shim.h` surface is byte-identical across 833767e→176782f→74413b0→ed13e5e),
each assigned an implementing slice, an **on-macOS status / unsupported mechanism**, and a **named
test**. "Every `webkit_shim.h` export" is now literal, not a representative subset (rev 3
blocker 4; rev 4 completeness; rev 5 corrects the config-flag mechanism).

**Unsupported mechanism (uniform, rev 4):** a seam that is **not implemented on macOS is absent
from the macOS shim at link time** — it is simply not compiled into `wkwebview_shim.m`, so any
test or caller that references it **fails to link** (a build failure = fail-closed). This is the
*exact* mechanism, and it is what resolves the rev-3 "no error channel" objection: a `void`,
count- or `bool`-returning seam cannot carry a runtime "unsupported" sentinel, but it *can* be
absent, and absence fails the build louder than any sentinel.

**Config flags have no C-ABI error channel either (rev 5 — RoseCat 5501).** The flag setters
`zb_app_set_hw_policy`/`zb_app_set_media_source` are **`void`**, their getters are bare `int`, and
`--renderer` has **no C setter at all** — so there is no `int<0 + out_err` path to return (the
rev-4 claim was not executable). The unsupported decision therefore lives **one layer up**, in a
**fallible app-level Zig validate/apply seam** (MS3.2, `src/webkit.zig` + `src/app.zig`): it
validates each flag/value **before** any void C setter is called, and for an unsupported
flag/value it **refuses** — the real binary **exits nonzero with an exact message** and never
touches the C ABI. A supported value is simply applied (the void setter and/or `WKPreferences`).
No seam silently returns zero and no config export fakes an error channel it does not have.

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
| `zb_app_set_hw_policy` / `zb_app_get_hw_policy` | void / int | MS3.2 | **always implemented** (void setter, int getter — no error channel); the supported/unsupported decision is upstream in the fallible Zig `applyMacBackendFlag` seam, which refuses an unsupported value **before** calling the void setter | `mac_config_flags_test` (supported value applies; unsupported value → binary exits nonzero, exact message, setter not called) |
| `zb_app_set_media_source` / `zb_app_get_media_source` | void / int | MS3.2 | **always implemented**; `--media-source off` maps to MSE-off via `WKPreferences`/user script; any unsupported value is refused by the Zig seam before the void setter | `mac_config_flags_test` |
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
  "git_commit": "ed13e5ef582d1256cbe92bf06bb0bb3526210ca1",
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
  "git_commit": "ed13e5ef582d1256cbe92bf06bb0bb3526210ca1",
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
  "git_commit": "ed13e5ef582d1256cbe92bf06bb0bb3526210ca1",
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

> Each map's `read_path`/`seedable_store`/`driver` resolves at ed13e5e (the macOS impls are
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

### Behavior MS3.2: decided macOS semantics via a fallible Zig validate/apply seam (rev 5 — RoseCat 5501)
**Given** the Linux-only flag apply path (`webkit.zig:47-72`) and that the C setters are **`void`**
(`zb_app_set_hw_policy`/`zb_app_set_media_source`), their getters bare `int`, and `--renderer` has
**no C setter at all**,
**When** a flag is passed on macOS,
**Then** a **named fallible app-level Zig seam — `applyMacBackendFlag(flag, value) !void` in
`src/webkit.zig`, called from the arg-apply path in `src/app.zig`** — decides each flag/value
**before** any void C setter runs:
- a **supported** value is **applied** (it calls the void C setter and/or sets `WKPreferences`),
  e.g. `--media-source off` → MSE off via `WKPreferences`/a user script (mirrors the
  Instagram-deadlock rationale, media_config.zig:6-12), and `--hardware-acceleration <v>` →
  `zb_app_set_hw_policy(policy)`;
- an **unsupported** flag/value makes the seam **return an error**; `app.zig` prints an **exact
  message** (e.g. `zigBrowser: --renderer=<v> is not supported on macOS`) and the **real binary
  exits nonzero**, **without** calling the void C setter — never a silent accept.

`--renderer` is handled **entirely** by this Zig seam (there is no C ABI to reach): a recognized
value maps to its documented WKWebView behavior, any other value is refused as above. This is the
rev-5 fix for RoseCat 5501: the error channel is the fallible Zig seam, not a non-existent
`out_err` on a void C setter.

- **Test (`mac_config_flags_test.py`, named in the ABI table):** (a) a **supported** value applies
  and the single observable effect is asserted over the socket; (b) an **unsupported** value makes
  the **real binary exit nonzero with the exact message** and apply nothing (the void C setter is
  not reached — proven by a debug read showing the policy unchanged). A mutant that applies before
  validating, or swallows the error to exit zero, turns (b) red.

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

### Behavior MS5.1c: the agent runtime joins the universal-components census (rev 7; roles typed in rev 8)
**Given** MS5 now installs the Python runtime, the Claude CLI and the generated launcher into the
macOS bundle (so these ship for the first time),
**When** the universal bundle is assembled,
**Then** MS5's **red MUST add them to `packaging/macos/universal_components.json` typed by their
real form** (rev 8, RoseCat 5989):
- **`python-runtime` and `claude-cli` are native Mach-O** → added as `components` (each by its
  exact bundle-relative `path_glob`), so the unchanged MS1 census requires each to be a **fat
  Mach-O**;
- the **`helper-launcher` is the generated Python shebang wrapper `zb-claude`** (`token.py:100-140`,
  written at `setup.py:492`, real path `runtime/bin/zb-claude`) — **not a Mach-O**. It is added as
  a **`resource`**, so the two-tree `resource_compat` oracle requires its bytes **byte-identical
  across the two per-arch trees** (a `component_census` fat-Mach-O role would never green for a
  script). The wrapper embeds the python/CLI paths, so it is byte-identical only when MS5 ships one
  **universal2 runtime at one path**; if the arches differ, the oracle **fails closed** — exactly
  its purpose. (If a native launcher is ever introduced, re-classify it as a `component` then.)

MS5's gate MUST run the phase gate `mac_resource_compat.py --milestone MS5` on the x86_64 and arm64
provisioning trees before `lipo`, over the runtime's non-exec files (`runtime.json`, the generated
`zb-claude`/`zb-hook-run`/`zb-net-relay` scripts, the `*.json` manifests). This is the **first
production run of the two-tree oracle** (MS1 runs `--milestone MS1`, which the gate accepts empty;
MS5 is **not** an empty-allowed milestone, so `resource_phase` fails closed unless MS5 declares a
nonempty resource set) — so the empty-allowed exception can never leak past MS1. The Intel Xcode-python-3.9 vs arm
Homebrew-python-3.14 difference is precisely the mismatch it catches. Red-first: with the roles
added but the runtime still single-arch/mismatched, the Mach-O census (python/CLI) and the resource
oracle (the scripts/manifests) both go red; green only when every shipped Mach-O is fat and every
shipped resource is byte-compatible. (MS1's inventory stays `{browser}` with empty `resources`;
this behavior is where the runtime roles enter — rev 7 deferral, rev 8 typing.)

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
  reads, **no `same-sandbox` task-port/process-info rights**, allow only the backend's
  ephemeral loopback proxy port and `:51091`/`:31337` (see the egress mapping below), tiny
  mach-lookup (no WindowServer, no mDNSResponder), **profile file + `-D` params** (not inline),
  fixed `/usr/bin/sandbox-exec`.
- Hooks spawned **app-side**, each in its own profile (profiles don't nest); stdio over
  `SCM_RIGHTS`.
- Orphan cleanup via kqueue `NOTE_EXIT` + pipe EOF + PID tracking. **The dedicated-user `kill(-1)`
  scheme from rev 1 is removed** (unapproved).
- The proxy/bridges are owned here or depend on a named green Linux revision (per MS0/Shared
  contract).

### Egress mapping — the `SandboxBackend` egress capability, pinned (rev 6; RoseCat `ed13e5e`)

The MS0 egress capability (endpoint **and** policy supplied by the backend) is realized on macOS
exactly as follows. This replaces rev 5's open design item: the "Unix-socket proxy" option is
**ruled out** because the bundled CLI rejects Unix-socket proxy URLs (BlueBeaver measured, mail
`5503`), so a TCP `127.0.0.1:<port>` hop is mandatory, and the remaining viable mapping is pinned:

1. **Host netd listens on an OS-selected, per-session `127.0.0.1:<port>`** (an ephemeral port the
   kernel assigns, recorded for the session), and the **generated CLI/helper Seatbelt profile
   permits only that one loopback endpoint** — no other outbound, no other loopback port.
2. **`HTTPS_PROXY`/`HTTP_PROXY` name that exact port**, and **netd keeps the exact CONNECT/SNI
   allowlist** (`api.anthropic.com` + census-proven CLI domains, fail-closed; §MS6.4). An arbitrary
   host process gains no meaningful capability from the port existing: it already has host egress,
   and the proxy grants only the same API allowlist.
3. **Each hook gets its own profile permitting only loopback ports `51091` and `31337`** — **no
   proxy endpoint and no API path**. (Hooks never reach the egress proxy; the per-process rule, not
   a shared loopback, is what isolates them on macOS, since macOS has no per-sandbox loopback.)
4. **The real-binary fake-API test (MS6.4) proves:** the chosen endpoint carries egress; **both
   bridge positives** (`:51091`, `:31337`); **every MS6.4 denial**; and that **a hook cannot reach
   the proxy** (a hook's attempt to the CLI/helper proxy port is refused by its profile).

**Shared capability framing:** the endpoint and policy are the backend's to supply. **Linux**
implements the capability with a **private network namespace, fixed proxy/bridge ports, and relays**
(the hook's own netns seals it). **macOS** implements it with the **ephemeral host-loopback proxy
above plus per-process Seatbelt port rules**. Either way MS0's launch spec is the single owner of
"which endpoint, which policy, who may reach it"; MS6 only realizes the macOS half.

### Hard-gate behaviors (all failing-first; failure ⇒ launch disabled + VM required)
- **MS6.1 (gate):** a malicious hook's `task_for_pid(cli)`, `sysctl KERN_PROCARGS2`,
  `proc_pidinfo`, and `lldb -p <cli>` **all fail**; the token-isolation mutant uses a
  **deterministic sacrificial target** so removing Seatbelt actually **exposes the canary** (a
  host/TCC denial that stays green does **not** prove the profile).
- **MS6.2 (gate):** custom `sandbox-exec` profile is **accepted** on both arches' OS versions
  (disposition 3; failure selects VM).
- **MS6.3 (gate):** the **fd-3 reopen** (`/dev/fd/3`) works with the macOS CLI on **both** arches
  (disposition 2).
- **MS6.4 (gate, egress mapping pinned — rev 6):** network — the CLI/helper reach egress **only at
  the backend's per-session `127.0.0.1:<port>`** (the generated profile permits only that endpoint);
  both bridges `:51091`/`:31337` carry bytes (positive controls); and the sandbox **fails** to
  reach a direct loopback decoy, LAN, public IP, DNS, WindowServer/CGEvent/screen capture, a
  non-allowlisted host, and a workspace write. **A hook (its own profile) cannot reach the proxy
  port at all** — its attempt is refused — while its two bridges still work. The fake
  Messages/Anthropic API is reached **through the production proxy** via an `--e2e-protocol`
  allowlist seam; **removing/bypassing the proxy, or widening the hook profile to admit the proxy
  port, turns the test red**.
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

**MS1b (the signed x86_64 binary runs) — split out, NOT a universal blocker** (user decision
"split it out, fix now", over "fix it before MS1"; orchestrator). Its binding edges:
- **`MS1 → MS1b`, scheduled immediately** — MS1b is the next Mac slice JadeBeacon works on.
- **MS1b is a HARD prerequisite of MS9** (release signing + notarization) **and of any slice, gate,
  documentation claim, or real-screen check that claims a SIGNED binary runs** — no such claim may
  be marked done until Gate(MS1b) is green.
- **MS2a and every later development slice MAY proceed IN PARALLEL with MS1b, running the UNSIGNED
  universal build** (MS1 proved the unsigned universal runs on both arches). Those slices **must
  NOT claim a signed-run result** until MS1b is green; MS1 itself does not prove a signed binary runs.

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
- Code anchors: build.zig:1107-1118/79-105/241-272 + `configureMacosBackend` ~1702+ (MS1b dylib);
  src/wkwebview_shim.m:788-888;
  src/automation_server.zig:412-530/480-487/686-691/942-1106; src/automation_gtk_port.zig:22;
  src/automation_platform.zig:90-95; src/app.zig:41-47/160-166; src/webkit.zig:47-72;
  agent/host/zb_agent_host/sandbox.py; src/agent_host.c:1-73; packaging/macos/build-dmg.sh:90;
  packaging/macos/Info.plist:21-22

## Blocker status (process note — RESOLVED 2026-10-20)

**HISTORICAL:** earlier the shared bd DB had pending schema migrations (v49→v53) and refused
auto-apply on the remote-backed clone, so tracking beads could not be filed (`bd migrate`/`bd
bootstrap` are destructive/coordination actions not taken unilaterally). **This is resolved:** the
orchestrator migrated the local bd DB (with the user's approval) on 2026-10-20, and `bd create`
works again (no `dolt push`). Beads are now filed normally (e.g. the gate parallelism/load finding
is `zigBrowser-tka`). Status is still cross-referenced via Agent Mail + this plan.
