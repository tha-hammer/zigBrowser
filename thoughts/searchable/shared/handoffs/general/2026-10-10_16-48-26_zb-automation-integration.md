---
date: 2026-10-10T16:48:26-04:00
author: BlueBeaver (cc_2), with BlackRobin (cc_1) and RoseCat (cod_1, review)
branch: zb-automation-integration-2026-10-10-11-59
topic: zigBrowser automation integration - handoff for the human
status: ready for human review; live sites NOT exercised
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
works on the Linux/GTK build. X, LinkedIn and Instagram flows are built from
those commands, with a login gate, pacing and one selector table per site.
Everything is tested against local fixtures and the real binary. **No live
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

## Every method and how it is verified

Legend: **U** unit tests (fake page/clock), **S** real socket server tests
(fake page), **E** real binary on local fixtures, **SDK** Python/Node
wrapper tests + shared wire cases (`tests/fixtures/automation/sdk_wire_cases.json`,
checked against the real server), **L** real binary driven through the
Python SDK.

| Method(s) | What it does | Verified by |
|---|---|---|
| `page.navigate`, `page.reload`, `page.url`, `page.title`, `page.evaluate` | Page control; evaluate returns JSON, exceptions as -32603 with the class name only | U, S, E (`automation_core_test.py`, readiness), SDK, L (`sdk_python_live_test.py`) |
| `page.screenshot` | Not supported (-32603) | U |
| `dom.query`, `dom.getText`, `dom.getAttribute`, `dom.waitFor` | Reads and waits with selector engines `css=`, `xpath=`, `text=`, `testid=`, `role=` | U, S, E, SDK, L |
| `dom.click`, `dom.fill`, `dom.type`, `dom.press`, `dom.selectOption` | Actions with actionability checks (visible, stable, not covered, enabled, editable), retried until the deadline; contenteditable/Draft editors; `trial`, `force`, `strict`, `delay_ms` | U (incl. retry/deadline mutation tests), E (`automation_input_test.py`), SDK, L |
| `options.input: "native"` on click/type/press | Real GDK pointer/key events (`isTrusted`), bound to the located document, partial-input reporting, never retried after dispatch | U (engine with fake port, document change, partial input), E (socket native e2e by cc_1), webkit live tests |
| `options.humanize` (native only) | Curved pointer path from the last pointer position, 80-200 ms key gaps, 300-600 ms word pauses, whole schedule pre-checked (`humanize_budget`) | U (seeded RNG, budget, corners, document change), E (cc_1 humanized click/type e2e) |
| `cookies.getAll`, `cookies.set`, `cookies.delete`, `cookies.import` (Netscape/JSON) | Cookie store; values never logged or traced | U, S, E (`automation_cookies` e2e), SDK |
| `social.login_check`, `social.rate_status`, `social.set_pacing`, `social.pause` | Login heuristic, shared social pacing (default 100/day, 3-8 s pause), queue pause | U, S, SDK, L |
| `x.post`, `x.schedule_post`, `x.login_check`, `x.selfcheck` | X composer flows (stale-draft clear, Post button picked by trial probes, toast confirmation, schedule dialog), 50/day cap, 120 s budget (`timeout_ms` up to 600 s), `options.input/humanize` | U (`x_test.zig`, `automation_x_test.zig`), S (deterministic one-queue-turn proof), E (`x_flows_test.py` on `tests/fixtures/x/composer.html`, including a humanized 280-character post; cc_1's `x_native_test.py` proves native, humanized input is trusted), SDK for the default X call shapes only: the Python/Node `x` wrappers cannot pass `options` or `timeout_ms` yet, so those are covered over the raw socket |
| `linkedin.visit/connect/follow/message/like/comment/search/extract/selfcheck` | LinkedIn flows; session-cookie gate before navigation; https://www.linkedin.com URLs only; typed text; note cut to 300 | U (`linkedin_test.zig`, `automation_social_test.zig`), S (socket chain), L (`social_flows_test.py` on `tests/fixtures/linkedin/`), SDK |
| `instagram.follow/like/comment/dm/story_view/selfcheck` | Instagram flows; same rules; stories viewed frame by frame | U (`instagram_test.zig`, `automation_social_test.zig`), S, L (`social_flows_test.py` on `tests/fixtures/instagram/`), SDK |
| `telemetry.query` | The last 128 traces (64 spans each; the root and a social flow's compound span are always kept) | U, S, L |

Errors: JSON-RPC -32700/-32600/-32601/-32602/-32603/-32000 plus the
automation range -32001..-32012, each with `data.trace_id` and
`data.command_id` (table in `docs/how-to-automate.md`).

Gate: `zig build test --summary all` (under Xvfb) runs everything above,
including the real-binary e2e suites and the cross-platform check. Last
green author gate before this handoff (at `3b4dd8f`): 80/80 steps,
577/577 tests (see the review log for the reviewer's independent gates).

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
- Proxy, CAPTCHA/checkpoint and platform rate-limit pages: not modelled.
  The flows stop with an element/selector failure if one appears; they do
  not detect them by name.
- The social pacing state (counts, cap) is in memory: a restart resets it.
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
   (`strict_multiple`), a checkpoint/authwall/CAPTCHA page, a platform
   rate-limit message, unexpected navigation, or a result that does not show
   in the window. Update the selector table, re-run the fixtures and the
   full gate, then repeat from step 4.

## Open review items at handoff

The running review log is
`thoughts/searchable/shared/reviews/2026-10-10-automation-integration-review.md`
(RoseCat). Updated after RoseCat's review (mail 4731):

- **N16 (linkedin.*/instagram.*): APPROVED.** Step 2 (`e58635c`: fixtures,
  real-binary SDK e2e, and fixes for the reservation, deadline, story
  completion, telemetry retention and lock findings) and step 3
  (`3b4dd8f`: wire cases, Node SDK namespaces, docs). `session.id_hash` is
  listed under "Deferred follow-ups" below.
- **x.* `options` (`8243dcf`): APPROVED.** RoseCat's one SHOULD on this
  handoff's SDK evidence wording is fixed in the table above.
- **N14 (cc_1, `6507b96`):** real-binary e2e of `x.post` and
  `x.schedule_post` with native, humanized input; landed.
- **`timeout_ms` for long flows (`9b32f84`):** sent to RoseCat for
  review; details in the "Long humanized posts" bullet below.
- **N17 `dom.setInputFiles` and N18 `dom.hover` / `dom.scroll`:** native
  sides by cc_1 are landed (`57a56fd`, `30472b3`, `9ab165f`); the
  PagePort/router/engine seams are agreed (scroll returns only once
  scrolling has settled) but not written.
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

- **Closing one window ends related windows' web process.** Windows that
  share a WebKit web process lose it when one of them is closed. This predates the automation work; RoseCat
  raised it as a SHOULD and the orchestrator deferred it.
- **`session.id_hash` is not implemented.** The compound social span has
  no session id hash because there is no session concept yet.
- **Social pacing state is in memory only.** The per-platform daily caps
  and reservations in the social pacing state reset when the browser
  restarts; nothing is written to disk.
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
- E2E: `tests/e2e/*.py` (all wired into `zig build test`).
