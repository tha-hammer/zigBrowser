---
date: 2026-10-10T16:48:26-04:00
author: BlueBeaver (cc_2), with BlackRobin (cc_1) and RoseCat (cod_1, review)
branch: zb-automation-integration-2026-10-10-11-59
topic: zigBrowser automation integration - handoff for the human
status: ready for human review; live sites NOT exercised
updated: 2026-10-10T21:45-04:00 (final acceptance: two quiet clean gates at 2dc67b6; heavy load can fail live e2e timing)
---

# zigBrowser automation integration: handoff

## In one paragraph

This branch turns zigBrowser into a browser that a program can drive over a
local socket. A client (the Python or Node SDK, or anything that speaks the
length-prefixed JSON-RPC) sends `page.*`, `dom.*`, `cookies.*`, `social.*`,
`x.*`, `linkedin.*`, `instagram.*` and `telemetry.query` requests and gets real
results from the live WebKitGTK page. Every command is retried until a
deadline, queued one at a time per page, and traced. Synthetic input works
everywhere; real (trusted) pointer and key input, optionally human-paced,
works on the Linux/GTK build, as do file uploads through the browser's own
file chooser, real wheel scrolling, real hover and PNG screenshots. X,
LinkedIn and Instagram flows are built from those commands, with a login
gate, pacing (saved in the profile across restarts), one selector table
per site, and a stop on the platforms' own checkpoint, CAPTCHA and limit
pages. Everything is tested against local fixtures and the real binary. **No live
site (x.com, linkedin.com, instagram.com) has been touched by any test.**

## Start it

```bash
zig build
zig-out/bin/zigBrowser https://example.com --automation-api --profile-dir ~/zb-test-profile
# socket: $ZIGBROWSER_SOCKET, else $XDG_RUNTIME_DIR/... (printed path); token: <socket>.token
```

Then from Python:

```python
from zigbrowser import ZigBrowser
with ZigBrowser(socket_path="/run/user/1000/zigbrowser-....sock") as zb:   # token read from <socket>.token
    zb.page.navigate("https://example.com")
    print(zb.page.title())
```

Full user guide: `docs/how-to-automate.md` (every method, params, results,
error codes). Build notes for other platforms: `docs/how-to-build.md`.

## Behaviour changes a user will notice

1. **Default persistent profile.** Without `--profile-dir`, the browser now
   keeps cookies and site data in `$XDG_DATA_HOME/zigbrowser/profile`, else
   `~/.local/share/zigbrowser/profile`. Logins survive a restart. Use
   `--profile-dir <dir>` for a separate (e.g. disposable test) profile. An
   explicit directory that cannot be created is an error; if the default
   cannot be resolved the browser runs on WebKit's default context.
2. **The automation token is always on.** `--automation-api` always requires
   a token. With `--automation-token-file` the user supplies it; otherwise a
   per-session token (32 bytes of OS entropy) is written to
   `<socket>.token` with mode 0600 before the socket accepts anything, and
   removed on stop. The socket itself is mode 0600. The SDKs read the
   sidecar on every connect. Any process that can read that file (the same
   user) is trusted.
3. Native input, humanize and the site flows are new opt-in features; plain
   synthetic `dom.*` behaves as before.
4. **Pacing survives a restart.** The day's action counts (the shared
   LinkedIn/Instagram cap and the X cap) and the `social.set_pacing`
   settings are kept in `<profile dir>/automation-pacing.json` (mode
   0600). To reset them by hand, stop the browser and delete that file.
5. **Site flows stop on platform stop signs.** A checkpoint, CAPTCHA or
   limit dialog/toast ends an `x.*`, `linkedin.*` or `instagram.*` flow
   with -32010 and `data.signal` before anything else is clicked, and the
   action is not counted.
6. **Windows (N23).** `page.list` lists the open windows (a login popup
   appears with its opener), `window_id` sends any other `page.*` call and
   any `dom.*` call to one of them, and `page.close` closes a popup.
   Closing a popup, by `page.close` or by its own `window.close()`, leaves
   its opener's page loaded and working, with its page state (`1088651`).
7. **HTTP/1.1 by default on Linux.** At startup, before WebKit's network
   process starts, the browser sets `SOUP_FORCE_HTTP1=1`. The reason is a bug
   in libsoup 3.6.5 (WebKitGTK 2.52.6): when a server sends a complete
   HTTP/2 response followed by GOAWAY(NO_ERROR), libsoup fails it, and the
   page's fetch rejects with "TypeError: Load failed". On the live site this
   broke X login: the call to `edge.prelude.dev` failed, and X showed
   "Something went wrong". A `SOUP_FORCE_HTTP1` value the user exported is
   kept as it is. `ZIGBROWSER_HTTP2=1` turns the default off. This is tested
   by `tests/e2e/http2_goaway_test.py`, which uses a local HTTP/2 server
   that sends GOAWAY.
8. **Rendering default on Linux (2026-10-11).** Windows, popups and
   `--screenshot` now use WebKit's own hardware-acceleration policy, and the
   browser sets `WEBKIT_DMABUF_RENDERER_FORCE_SHM=1` at startup unless the
   user set it. Before, the policy was forced to `never`. On the user's
   NVIDIA desktop (RTX 3080, WebKitGTK 2.54.0) that made a YouTube window
   show its thumbnail, then go blank as its web process died; with the new
   default the user watched the video play in real time. Opt out with
   `--hardware-acceleration never` and/or `--renderer default` (or
   `--renderer mesa-egl`). A dead web process is now visible: `page.list`
   shows `"crashed"` for the window and stderr names it. Details:
   `docs/how-to-run.md` ("Rendering"). Tested on Xvfb by
   `tests/e2e/render_config_test.py` and `web_process_crash_test.py`; the
   real-screen check is done by hand.

## Every method and how it is verified

Legend: **U** unit tests (fake page/clock), **S** real socket server tests
(fake page), **E** real binary on local fixtures, **SDK** Python/Node
wrapper tests + shared wire cases (`tests/fixtures/automation/sdk_wire_cases.json`,
checked against the real server), **L** real binary driven through the
Python SDK.

| Method(s) | What it does | Verified by |
|---|---|---|
| `page.navigate`, `page.reload`, `page.url`, `page.title`, `page.evaluate` | Page control; evaluate returns JSON, exceptions as -32603 with the class name only | U, S, E (`automation_core_test.py`, readiness), SDK, L (`sdk_python_live_test.py`) |
| `page.screenshot` | `{data: base64 PNG, width, height}` of the viewport or (`fullPage`) the document; at most 16 MiB of PNG and 32 MiP (checked before the capture and again on the captured surface), else -32603 `screenshot_too_large`; a capture that ends at or after its deadline is a timeout (`baf151f`, `b5fab82`) | U, E (`automation_native_ports_test.py`: valid PNG, size = viewport × dpr, a known pixel colour), webkit live tests |
| `dom.query`, `dom.getText`, `dom.getAttribute`, `dom.waitFor` | Reads and waits with selector engines `css=`, `xpath=`, `text=`, `testid=`, `role=` | U, S, E, SDK, L |
| `dom.click`, `dom.fill`, `dom.type`, `dom.press`, `dom.selectOption` | Actions with actionability checks (visible, stable, not covered, enabled, editable), retried until the deadline; contenteditable/Draft editors; `trial`, `force`, `strict`, `delay_ms` | U (incl. retry/deadline mutation tests), E (`automation_input_test.py`), SDK, L |
| `dom.setInputFiles` | Chooses files through WebKit's own file chooser (hidden inputs fine); absolute readable files only (-32602 `bad_file`, nothing clicked); applied-but-unconfirmed is -32009 `files_unconfirmed`, never repeated | U, S, E (`automation_native_ports_test.py`: trusted `change` with exact names and sizes, single and multiple, `bad_file`), SDK |
| `dom.hover` | Synthetic: events only (no CSS `:hover`); native: a real pointer move (humanized: a curved path), so `:hover` menus open | U, S, E (`automation_scroll_test.py`: `:hover` style only for native), SDK |
| `dom.scroll` | A selector into view, or the page by x/y; native: real wheel events, answered once scrolling has settled, never with a replaced page's offsets (`6f12c70`, `569e47a`, `2a31ffd`) | U, S, E (`automation_scroll_test.py`, `automation_native_ports_test.py`: offsets read in the next command equal the answer, trusted wheels), webkit live tests, SDK |
| `options.input: "native"` on click/type/press/hover/scroll | Real GDK pointer/key/wheel events (`isTrusted`), bound to the located document, partial-input reporting, never retried after dispatch | U (engine with fake port, document change, partial input), E (socket native e2e by cc_1), webkit live tests |
| `options.humanize` (native only) | Curved pointer path from the last pointer position, 80-200 ms key gaps, 300-600 ms word pauses, whole schedule pre-checked (`humanize_budget`) | U (seeded RNG, budget, corners, document change), E (cc_1 humanized click/type e2e) |
| `cookies.getAll`, `cookies.set`, `cookies.delete`, `cookies.import` (Netscape/JSON) | Cookie store; values never logged or traced | U, S, E (`automation_cookies` e2e), SDK |
| `social.login_check`, `social.rate_status`, `social.set_pacing`, `social.pause` | Login heuristic, shared social pacing (default 100/day, 3-8 s pause, saved in the profile), queue pause | U, S (restart on the same file, corrupt file), E (`automation_pacing_persist_test.py`: restart, profile isolation, corrupt file), SDK, L |
| `page.list`, `page.close`, `window_id` on `page.*`/`dom.*` (N23) | Window targeting: one queue per window; a gone window is -32011 `no_window` with no page work; the primary cannot be closed | U, S (targeting, close FIFO, gone/unknown ids on every page path, telemetry), E (`automation_windows_test.py`: popup listed with its opener, targeted fill/eval only in the popup, popup login and postMessage to the opener, close by `page.close` and by the popup's own `window.close()`, each leaving the opener's exact URL and its `got:user=alice` state (`d689f72`), then `no_window`), webkit live matrix (cc_1), SDK |
| Platform stop signs in every site flow (N20) | automation.js `rateLimitScan` after every navigation, before actions, after a failed step and before success; -32010 `{signal, platform}`; nothing clicked after a detection; one absolute flow deadline and cancellation respected | U (incl. scan latency, cancellation, mutants), S, E (`x_flows_test.py`: Arkose challenge, daily-limit toast; `social_flows_test.py`: LinkedIn checkpoint redirect, invitation-limit modal, Instagram "Try Again Later") |
| `x.post`, `x.schedule_post`, `x.login_check`, `x.selfcheck` | X composer flows (stale-draft clear, Post button picked by trial probes, toast confirmation, schedule dialog), 50/day cap, 120 s budget (`timeout_ms` up to 600 s), `options.input/humanize` | U (`x_test.zig`, `automation_x_test.zig`), S (deterministic one-queue-turn proof), E (`x_flows_test.py` on `tests/fixtures/x/composer.html`, including a humanized 280-character post; cc_1's `x_native_test.py` proves native, humanized input is trusted), SDK for the default X call shapes only: the Python/Node `x` wrappers cannot pass `options` or `timeout_ms` yet, so those are covered over the raw socket |
| `linkedin.visit/connect/follow/message/like/comment/search/extract/selfcheck` | LinkedIn flows; session-cookie gate before navigation; https://www.linkedin.com URLs only; typed text; note cut to 300 | U (`linkedin_test.zig`, `automation_social_test.zig`), S (socket chain), L (`social_flows_test.py` on `tests/fixtures/linkedin/`), SDK |
| `instagram.follow/like/comment/dm/story_view/selfcheck` | Instagram flows; same rules; stories viewed frame by frame | U (`instagram_test.zig`, `automation_social_test.zig`), S, L (`social_flows_test.py` on `tests/fixtures/instagram/`), SDK |
| `telemetry.query` | The last 128 traces (64 spans each; the root and a social flow's compound span are always kept) | U, S, L |

Errors: JSON-RPC -32700/-32600/-32601/-32602/-32603/-32000 plus the
automation range -32001..-32012, each with `data.trace_id` and
`data.command_id` (table in `docs/how-to-automate.md`).

Gate: `zig build test --summary all` (under Xvfb) runs everything above,
including the real-binary e2e suites and the cross-platform check. Latest
green joint gate (HEAD + the N23 files, fresh cache, for `3528d84`): **85/85 steps, 641/641 tests** (the first handoff was 80/80, 577/577 at `3b4dd8f`; see the review
log for the reviewer's independent gates).

**Final acceptance: two quiet-host clean gates at `2dc67b6`, both GREEN.**
Each ran on a fresh `git archive` of `2dc67b6` with a fresh cache, under
Xvfb, one after the other, on a host with no other builds or stress:
quiet gate A (RoseCat, seed `0xa9b885cd`) and quiet gate B (orchestrator),
each `85/85 steps, 644/644 tests`. (This replaces the earlier "final clean
gate GREEN at `5c15e0b`": a later orchestrator gate at `bc0bad1` crashed
with "attempt to use null value" in "a navigation blocked by policy does
not refuse later typing".) That panic never reproduced in more than 100
loaded runs, including the failing seed (112 of them cc_2's, under gdb). The only
null unwraps on its path were in test code: the driver's `pagePort().?`
and a `std.debug.print` whose stderr unlock can reach the stdlib's
`Io.Threaded.recancelInner` `Thread.current.?` from a plain `std.Thread`.
`2dc67b6` replaces both in the live drivers (explicit checks, raw
`write(2)` prints) and changes no production code. On the orchestrator's
acceptance, that blocker is closed and RoseCat records its root cause as
"probable (test-only), not captured".

**Heavy concurrent load can make live e2e timing fail.** Gates run while
the host was saturated (CPU burners, gdb loops and several full gates at
once) have failed live steps that pass on a quiet host: `x-flows`'s first
`x.post` returned -32007 `navigation_timeout` (RoseCat 4948), as did
`sdk-python-live` once, and the live bridge's navigating `nativeClick`
once returned an error after 8 s or more although page B loaded (4939;
RoseCat 4940). The first `x.post`'s 30 s `page.navigate` (a
production constant, `src/x.zig:46`) also covers the browser's cold start,
because the test sends it as soon as the socket accepts. Both quiet gates
passed all of these steps. Run acceptance gates on a quiet host; a
harness warm-up before the first flow (a SHOULD) would make `x-flows`
robust to this.

## What is NOT verified

- **Live x.com, linkedin.com and instagram.com.** No test touches them. The
  selector tables (`src/x.zig`, `src/linkedin.zig`, `src/instagram.zig`)
  are modelled on the sites' markup but have only been proven against our
  fixtures. They assume English labels in several places (e.g. "Add a
  note", "Following", "Add a comment…"). Expect drift; the `*.selfcheck`
  calls exist to see it.
- **Windows (WebView2) and macOS (WKWebView) at runtime.** `zig build
  cross-check` proves the Zig code compiles for them and that they need no
  GTK-only C symbol; the shims' own compilation, the SDK link and running
  the socket on those systems are not verified. On those builds the page,
  cookie and native-input features answer -32011.
- Proxies are not modelled. CAPTCHA/checkpoint and platform limit pages
  are detected by name since N20 (-32010 with `data.signal`; see "Challenge,
  CAPTCHA and limit pages" in `docs/how-to-automate.md`), but only from the
  English text, paths and frames the fixtures model: a localized or
  redesigned page may still surface as an element failure.
- File uploads, real hover/scroll and screenshots are proven on local
  fixtures only (no site-specific upload widgets).
- `selfcheck` reports counts only: no pass/fail policy, no visibility or
  actionability check, current page only (see "Safe first live run").

## Safe first live run (step by step)

Use a **dedicated test account** on each site and a **disposable profile**.
Never start with a personal or production account.

1. **Start a fresh, separate profile.**
   `zig-out/bin/zigBrowser https://x.com --automation-api --profile-dir ~/zb-live-test`
2. **Log in.** Either log in by hand in the visible window, or import
   cookies exported from another browser (the browser reads the file; values
   are never logged):
   ```python
   zb.cookies.import_file("/path/to/cookies.txt", "netscape")   # or "json"
   ```
   For LinkedIn and Instagram, confirm the session cookie exists **without
   printing its value**:
   `any(c["name"] == "li_at" for c in zb.cookies.get_all(url="https://www.linkedin.com/")["cookies"])`
   (`sessionid` on `https://www.instagram.com/`).
3. **Set conservative pacing first.** Check `zb.social.rate_status()`, then
   e.g. `zb.social.set_pacing(min_delay_ms=8000, max_delay_ms=15000, daily_cap=3)`.
   LinkedIn and Instagram share that cap; X has its own fixed 50/day and no
   configurable pause.
4. **Run the selfchecks on each relevant page** and keep the output as a
   baseline. Navigate by hand (or `zb.page.navigate`) to the page first:
   - X compose page (`https://x.com/compose/post`): `zb.x.selfcheck()` —
     `composer` and at least one `post_button.*` should be ≥ 1; open the
     schedule dialog by hand and run it again for the `schedule_*` entries.
   - LinkedIn profile, a post, a conversation, a search page:
     `zb.linkedin.selfcheck()` on each.
   - Instagram profile, a post, the DM composer, a story:
     `zb.instagram.selfcheck()` on each.
   A 0 where you expect the element means the selector table needs
   updating; duplicates (> 1) on strict entries mean a strict click would
   fail. Do not expect any single page to show all entries.
5. **Dry run with `options.trial`.** Before any real action, check that the
   flow's targets are actionable without clicking them. On the page the
   flow would open:
   ```python
   zb.dom.click("testid=tweetTextarea_0", trial=True)                       # X composer
   zb.dom.click('xpath=(//*[@data-testid="tweetButton"])[1]', trial=True)   # X Post (after typing a draft by hand)
   zb.dom.click('css=main button[aria-label^="Follow "]', trial=True)       # LinkedIn Follow
   zb.dom.click('xpath=//header//button[normalize-space(.)="Follow"]', trial=True)  # Instagram Follow
   ```
   `trial` runs every actionability check and sends no input. (The x.*,
   linkedin.* and instagram.* flows themselves have no dry-run mode; they
   act.)
6. **Read-only calls next:** `zb.x.login_check()`, `zb.social.login_check()`,
   `zb.linkedin.extract(profile_url)`.
7. **One low-impact action, one platform at a time**, on content you
   control (e.g. follow your own second test account). Check the result in
   the visible window, and look at its trace:
   `zb.call("telemetry.query", {"trace_id": ...})` (failed calls carry
   `trace_id` in the error).
8. **Stop immediately** on: selector-count drift, a strict-match error
   (`strict_multiple`), any -32010 with a `data.signal` (checkpoint,
   CAPTCHA, limit dialog or toast), a checkpoint/authwall/CAPTCHA page or
   limit message that was NOT reported as one, unexpected navigation, or a
   result that does not show in the window. Update the selector table, re-run the fixtures and the
   full gate, then repeat from step 4.

## Since the first handoff (9337bde)

All commits gated before commit; none amended.

- **N14 (cc_1, `6507b96`):** `x.post` / `x.schedule_post` with native,
  humanized input are trusted end to end (real binary).
- **Long humanized posts (`9b32f84`, `8a16668`):** `timeout_ms` (default
  120 s, at most 600 s) on x.* and the text-typing social flows; humanized
  X budgets sized from the typing schedule. A real 280-character humanized
  post on the fixture takes about 63 s (the orchestrator measured 62.8 s).
- **N17 / N18 / N19 (`2a4e6ee`, `ee19e40`, `c750b87`, `9534f61`,
  `6f12c70`, `e6cb03e`, `569e47a`, `85797af`):** PagePort v3.3/v3.4
  (setInputFiles, nativeScroll, screenshot), the router/engine/SDK for
  `dom.setInputFiles`, `dom.hover`, `dom.scroll`, `page.screenshot`, the
  GTK adapter wiring (with a test that fails the build if any PagePort
  method keeps its "unsupported" default), one real-binary e2e for all
  three, and the document-replacement and screenshot-deadline follow-ups
  (`569e47a`, `2a31ffd`, `baf151f`, `b5fab82`).
- **N20 (`314a14e`, `f11596b`, `eb49169`, `4f9c341`, `85797af`):**
  platform stop signs (see the table), SHA-256 `text_hash`, hidden nodes
  ignored, the absolute deadline and cancellation kept across scans.
- **N21 (`4dafb3a`, cc_1's `bf0d76b`, `1ca9ac5`, `07bf6b5`):** pacing
  persisted in the profile, proven on the real binary (restart, profile
  isolation, corrupt file).
- **N23 (joint commit with cc_1):** `page.list`, `window_id`,
  `page.close`, a stable window registry, and the popup e2e.
- **X admission (`4497fbd`):** X posts reserve their slot like social
  actions, so concurrent windows cannot overshoot the X cap.

## Open review items at handoff

The running review log is
`thoughts/searchable/shared/reviews/2026-10-10-automation-integration-review.md`
(RoseCat). Updated for N22 (after RoseCat's mails up to 4785):

- **Closed (was open):** the joint N23 commit `3528d84` is APPROVED: its
  WIP findings 4791-4846 were addressed before the commit, and the
  follow-ups below closed what remained, under the final acceptance
  (quiet gates at `2dc67b6`; RoseCat's final quiet gate at `d282373`). The
  popup-close fix (`1088651`, oracles `d689f72`: the shared web process
  ends only with its last window) is approved; its last review item
  (RoseCat 4859, the tracker sweep's test) is CLOSED by `7059814`. The
  final-gate flakes (native Enter acknowledgement race, ScanServer close
  hang) are CLOSED by `b0994ad` + `5c15e0b`. The later intermittent
  blocked-navigation null panic is CLOSED by `2dc67b6` (probable cause in
  test code, not captured); the two quiet clean gates at `2dc67b6` are
  GREEN (see "Final acceptance" above). Only if site flows ever accept
  `window_id` does the two-window X cap oracle (RoseCat 4785) become due;
  today they refuse it.
- **APPROVED or CLOSED since the first handoff:** `8a16668` (closes 4737),
  `5a9031c`, `6507b96`, `9534f61`, `6f12c70` (closes 4749), `e6cb03e`
  (engine half of 4756, native `:hover`), `eb49169` (deadline, 4762),
  `4f9c341` (cancellation, 4766/4769/4772), `4dafb3a` (core), `4497fbd`
  (X admission), N21 closed (`bf0d76b`, `1ca9ac5`, `07bf6b5`), the N22
  handoff corrections (`c8c0d6c`, `875ff2b`), and cc_1's screenshot and
  scroll follow-ups (`569e47a`, `2a31ffd`, `baf151f`, `b5fab82`).

Earlier items, kept for the record:

- **N16 (linkedin.*/instagram.*): APPROVED.** Step 2 (`e58635c`: fixtures,
  real-binary SDK e2e, and fixes for the reservation, deadline, story
  completion, telemetry retention and lock findings) and step 3
  (`3b4dd8f`: wire cases, Node SDK namespaces, docs). `session.id_hash` is
  listed under "Deferred follow-ups" below.
- **x.* `options` (`8243dcf`): APPROVED.** RoseCat's one SHOULD on this
  handoff's SDK evidence wording is fixed in the table above.
- **N14 (cc_1, `6507b96`):** real-binary e2e of `x.post` and
  `x.schedule_post` with native, humanized input; landed.
- **`timeout_ms` for long flows (`9b32f84`):** reviewed; its one
  test-evidence BLOCKER (4737) was closed by `8a16668`. Details in the
  "Long humanized posts" bullet below.
- **N17 `dom.setInputFiles` and N18 `dom.hover` / `dom.scroll`:** native
  sides by cc_1 are landed (`57a56fd`, `30472b3`, `9ab165f`). Since then
  the seams, routes, adapter wiring and e2e are all done (see "Since the
  first handoff").
- RoseCat's live-readiness audit (mail 4686) lists every selector
  assumption (English labels, legacy LinkedIn classes, first-match
  semantics, "any toast means success" on X). Read it before step 4 above.
- Long humanized posts (follow-up to this handoff): `x.post`,
  `x.schedule_post` and the linkedin/instagram flows that type text now
  take `timeout_ms` (default 120000, at most 600000). With `humanize` and
  no `timeout_ms`, the X budget is sized from the slowest possible typing
  schedule plus a margin (at most 600 s). A real 280-character humanized
  post on the fixture took about 63 s, so the earlier "about 190
  characters" limit here was too pessimistic: it counted a word pause for
  every character, not only for spaces.

## Deferred follow-ups

Known, not fixed in this branch, and deliberately left for later:

- ~~Closing one window ends related windows' web process~~: fixed in
  `1088651` after the orchestrator reversed the deferral (the
  process is terminated only when its last window closes; a single hung
  window keeps the timeout and termination).
- **`session.id_hash` is not implemented.** The compound social span has
  no session id hash because there is no session concept yet.
- ~~Pacing state is in memory only~~: done in N21.
- **SDK `x` wrappers lack `options` and `timeout_ms`.** The Python and
  Node `x.post` / `x.schedule_post` wrappers send only the default call
  shape; native input, humanize and `timeout_ms` need a raw socket call
  until the wrappers grow those parameters (RoseCat SHOULD, mail 4731).

## Where things are

- Engine, router, queue, telemetry: `src/automation/`.
- Socket server: `src/automation_server.zig`. GTK page/cookie adapters:
  `src/automation_gtk_port.zig`, `src/automation_gtk_cookie_port.zig`;
  injected script: `src/automation_script/automation.js`; C shim:
  `src/webkit_shim.c`.
- Site flows: `src/x.zig`, `src/linkedin.zig`, `src/instagram.zig`
  (shared helpers `src/flow_steps.zig`, runner
  `src/automation/flow_runner.zig`).
- SDKs: `sdk/python`, `sdk/node`.
- Fixtures: `tests/fixtures/x/`, `tests/fixtures/linkedin/`,
  `tests/fixtures/instagram/`, `tests/fixtures/automation/`.
- E2E: `tests/e2e/*.py` (all wired into `zig build test`, except
  `automation_pacing_persist_test.py`, which waits for the profile
  wiring). Pacing store: `src/automation/pacing_store.zig`.
