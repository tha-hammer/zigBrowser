---
date: 2026-10-10
reviewer: cod_1 (Agent Mail identity RoseCat)
branch: zb-automation-integration-2026-10-10-11-59
status: in_progress
---

# Automation Integration Review

## Scope and contracts

Reviewed before implementation:

- `thoughts/searchable/shared/research/2026-10-10-11-32-automation-layer-current-state.md`, including the Workflow Closure Map.
- `thoughts/searchable/shared/plans/2026-07-09-phase1-core-automation-engine-tdd-plan.md`, milestones M6 through M12.
- `src/automation_script/automation.js` and its Playwright tests.
- Installed WebKitGTK 2.52.6 headers for isolated-world injection and async JavaScript evaluation.

Priority acceptance path: a length-prefixed JSON-RPC request sent to the real
`--automation-api` socket must traverse the production router, engine, GTK
main-thread handoff, isolated automation world, and live page, then return the
actual typed result. A fake `PagePort`, direct `page.evaluate`, or page-initiated
`zbHost` call does not close that path.

## Review ledger

| Commit/diff | Gate | Result | Findings |
|---|---|---|---|
| Baseline at `master` plus in-progress engine files | `DISPLAY=:1 zig build test --summary all` | **FAIL**: 268/268 Zig tests passed; GTK E2E failed because `gtk_init_check` could not open `DISPLAY=:1` | Re-run under `xvfb-run`; this is an environment failure, not a green milestone. |
| In-progress combined worktree | `xvfb-run -a zig build test --summary all` | **EXPECTED RED**: existing GTK lifecycle E2E passed on `DISPLAY=:99`; new engine modules were not exported yet and new native symbols were declared/tested but not implemented | TDD red phase; not commit-reviewable. |
| In-progress `src/automation/page_port.zig` | Live diff review | Changes requested via Agent Mail | BLOCKER: `url`/`title` omit deadlines despite performing a cross-thread blocking handoff. BLOCKER: request/result ownership across timeout and late callback needed a concrete C-owned/refcounted contract. SHOULD: M6 screenshot is deferred outside the user's ten-method priority scope. |
| In-progress `src/automation/script_command.zig` and `tests/automation_engine_test.zig` | Live diff review | Changes requested via Agent Mail | BLOCKER: `parent_span_id` omitted from the script command, breaking M7/M11 child-span parenting. SHOULD: `dom.type.delay_ms` omitted; raw evaluate exception messages are exposed; adversarial JSON escaping lacks coverage. |
| `e04591f` — native main-thread handoff | Shared tree: `xvfb-run -a zig build test --summary all` | **NOT GREEN in shared tree**: existing GTK lifecycle E2E passed; concurrent cc_2 red-phase files caused compile failures. Author reports clean-export 48/48 steps, 273/273 tests. | BLOCKER: early `zb_app_run` failures never mark the loop ended. BLOCKER: loop end does not destroy queued idle sources, retaining their job refs; submit-vs-end race can attach after shutdown. SHOULD: destruction is not tested. |
| `b80d0fb` — PagePort + engine mapping | Exact diff review; full shared gate deferred because uncommitted v2 ABI already supersedes v1 | Author reports clean-export 50/50 steps, 300/300 tests. | V1 retained earlier blockers: URL/title lacked deadlines, DOM JSON was embedded in generated source, child parent span and RPC trace IDs were absent. Visible v2 diff addresses these. Remaining: timeout addition/ABI narrowing overflow, script still hard-codes attempt zero, `delay_ms` omitted. |
| `20cf9b5` — PagePort v2 and mapping fixes | Exact diff review; then `xvfb-run -a zig build test --summary all` on the moving shared tree | **NOT GREEN in shared tree**: 307/308 completed tests passed; cc_2's new server tests did not compile until its uncommitted server wiring lands, and cc_1's live bridge test had four failures. Author reports clean-export 50/50 steps, 309/309 tests. | Fixed command-as-data transport, bounded URL/title calls, parent span propagation, sanitized evaluate exceptions, and RPC trace/command IDs. BLOCKER: `u64` grace addition can overflow and the PagePort/C ABI narrows to 32 bits without a defined bound. |
| In-progress native injection/eval/navigation bridge after `20cf9b5` | Live diff review and Xvfb gate above | **RED**: initial live test failed title for both fixtures, reload, and title after reload; cc_1 changed title retrieval after this run, so a fresh gate is required. | BLOCKER: timed-out navigation/reload is not cancelled and retains its in-flight ref; the pre-existing fixed 15s page timer overrides longer command deadlines. SHOULD: the transfer-none `GVariant` argument is not released after starting eval. |
| `f6a9d05` — server dispatch through Engine/PagePort | Exact diff review; isolated server suite | **9/9 server tests pass**. A full gate against the moving tree hung once in the WebSocket test, but is not reproducible against the committed server suite. Author reports 50/50 steps, 318/318 tests. | BLOCKER: invalid object/array/bool JSON-RPC IDs are converted to null and the command still executes. BLOCKER for final acceptance: lifecycle E2E temporarily accepts `session_invalid`. SHOULD: allocation failure during connection shutdown can strand live threads; completed connections are reaped only on a later accept/stop. |
| `274928b` — GTK injection, eval, navigation, primary-window bridge | Exact diff review | Author reports 50/50 steps, 319/319 tests and five green live-test repeats. | Named-world injection and Promise-aware eval are correct. BLOCKER: timed-out loads are not stopped/untracked; fixed 15s application timer overrides command deadlines; early app failures do not mark the loop ended. SHOULD: eval argument variant leaks; raw URI comparison is fragile and hash navigation is unsupported. |
| `fba3ffd` — M7 retry loop and delayed typing | Exact diff review | Author reports 52/52 steps, 338/338 tests. | BLOCKER: starts a 250 ms native attempt at/after the deadline; delayed typing sleeps unbounded client input and can panic/hang; empty delayed text bypasses the PagePort entirely. SHOULD: later not-found errors overwrite more-specific actionability evidence; per-character calls reset attempt indexes. |
| `e2b02ec` — automation.js strictness, zero-match, attempt indexes | Exact diff review; included in a later green shared gate | Strict `waitFor` and zero-match action/getter behavior are fixed; child spans consume the engine attempt index. | SHOULD: the script clamps indexes at 1,000,000, so accepted long-running commands eventually stop producing monotonic attempt indexes. SHOULD: contenteditable is classified editable but fill/type still mutate only `.value`. |
| `4d53189` — GTK PagePort adapter, app wiring, live socket E2E | `xvfb-run -a zig build test --summary all` | **GREEN** on then-current shared tree: 52/52 steps, 341/341 tests; lifecycle E2E passed. | Production socket reaches the live page for URL/title/getText/click. SHOULD: final acceptance still lacks live socket coverage for six priority methods. SHOULD: embedded NUL in URL/evaluate input is silently truncated at the C-string boundary. |
| `0fc312a` — retry/deadline follow-up | Exact diff review | Author reports 52/52 steps, 347/347 tests. | The five findings on `fba3ffd` are materially fixed. SHOULD: timeout zero still starts a 1 ms native attempt at the reached deadline. SHOULD: script attempt-index clamp remains. |
| `4644087` — M8 per-page queue and cancellation | Exact diff review; full shared gate temporarily blocked by cc_1's in-progress native patch | Author reports 54/54 steps, 355/355 tests. | FIFO and cross-page independence are correct. BLOCKER: queue wait does not consume the pre-existing command deadline. BLOCKER: shutdown cannot interrupt a long inter-character typing sleep. Existing invalid JSON-RPC ID blocker remains. SHOULD: queue telemetry is passed but not yet emitted; restart after stop silently leaves the queue shut down. |
| `f1daa1f` — M11 root/child telemetry and queue-budget follow-up | Exact diff review | Author reports 56/56 steps, 368/368 tests. Reviewer gate overlapped a moving native diff and was not valid. | Closes the queue-budget blocker and zero-timeout/attempt-index SHOULDs. BLOCKER: required root/platform schema is incomplete; routed pre-engine failures have no root; URL credentials and unbounded selector kinds can leak; obsolete router emission permits duplicate roots. SHOULD: concrete in-memory sink is wired as the production abstraction; root duration excludes queue wait. |
| `1441fd3` — server/engine review fixes | Exact diff review | Author reports 56/56 steps, 371/371 tests; shared gate pending native stabilization. | Correctly rejects invalid IDs before dispatch, makes long type delays cancellation-responsive, and restores restart semantics. These M8/server findings are closed. |
| `a5a28ad` — telemetry vtable/schema/redaction follow-up | Exact diff review; full shared gate blocked by the in-progress native test hang | Author reports 56/56 steps, 374/374 tests. | Closes required attribute presence, duplicate router/engine roots, URL-userinfo output, and queue-inclusive duration. BLOCKER: the vtable's `CommandSpanAttrs` still carries raw selector, typed value, and URL into every sink; redaction occurs only inside the in-memory implementation, contrary to the pre-sink contract. |
| `7ff7d72` — routed-failure roots and bounded selector kind | Exact diff review; full shared gate blocked by the in-progress native test hang | Author reports 56/56 steps, 377/377 tests. | Correctly routes no-page and queued-cancel outcomes through the engine so they receive one root plus IDs. `selector.kind` is now a bounded enum. The pre-sink redaction blocker from `a5a28ad` remains. |
| `afe0498` — M12 real-binary socket E2E | Exact diff review; author reports 57/57 steps, 377/377 tests and four standalone passes | Production chain and scenario breadth are strong: all ten requested methods, one persistent socket, typed evaluate, >4 KiB framing, retries, side effects, navigation, and stable errors. BLOCKER for the reported startup race: the test calls `dom.waitFor` before title, masking the empty-document failure; title must be the first RPC against a deterministically in-flight initial load. |
| In-progress native reliability/readiness follow-up | Shared `xvfb-run -a zig build test --summary all`, GDB thread dump | **HANG** after lifecycle E2E passed; reviewer interrupted after >3 minutes. | BLOCKER: test mutates libc `environ`; later `LiveDriver.diag` panics/deadlocks in Zig environment/stderr initialization while main remains in `gtk_main`. Test no-DISPLAY behavior in a subprocess. The diagnostic path also indicates a new native navigation check returned non-OK. |
| `e0a101f` — startup readiness and native reliability closure | Exact diff review, then `xvfb-run -a zig build test --summary all` at `5712919` | **GREEN**: 57/57 steps, 379/379 tests; lifecycle and core real-binary E2Es passed. | Closes the primary-page startup race, loop-end source leak/race, early-exit waiter, abandoned load, legacy timer, argument-variant, and URI/hash-navigation findings. SHOULD: explicit child-window calls still wait on primary readiness rather than the child's own first load. |
| `5712919` — pre-sink telemetry redaction | Exact diff review in the same green gate | **GREEN**: alternate spy sink proves raw selector/value/URL/expression inputs do not cross the vtable. | Closes the M11 pre-sink redaction blocker. The uncontended queue wait fast path correctly preserves exact zero. |
| `ccd0153` / `5e52182` — deterministic first-call readiness and NUL rejection | Exact diff review; their E2Es passed in the later moving-tree gate | Approved. | `page.title` is issued before the delayed `/core` response completes, and NUL-bearing URL/evaluate strings are rejected before the C-string seam. |
| `1f2a2b2` — contenteditable fill/type | Exact diff review; live input E2E passed in the later moving-tree gate | Approved with follow-ups. | The socket test reaches live WebKitGTK and its Draft-style editor cancels `beforeinput`, owns the model update, and rerenders successfully. SHOULD: assert exact input-event counts and cover the separate empty-fill/delete path for both plain and Draft-style editors. NIT: remove no-op `time.sleep(0)`. |
| `998c228` — `dom.press` / `dom.selectOption` router and engine | Exact diff review; author reports 58/58 steps, 386/386 tests | Approved for the engine-side split. | Validation, mapping, retries, results, and telemetry action names are coherent. N2/N3 are not production-complete until the script ops and live socket E2E land. |
| `7da96d2` — persistent-profile CLI | Exact diff review; author reports 58/58 steps, 390/390 tests | Approved for the CLI-side split. | Flag grammar and XDG/HOME default resolution are sound. N4 still needs app/shim wiring and restart persistence/isolation coverage. |
| In-progress N4 native profile diff after `7da96d2` | `xvfb-run -a zig build test --summary all` | **RED**: 55/58 steps; 320/320 completed tests and all three automation E2Es passed, but the native test did not compile. | BLOCKER: `src/webkit.zig:575` treats this target's `std.c.Stat` as a struct with `.mode`; replace with a portable test seam. NIT: remove the `profile contents` debug print. Mailed cc_1. |
| `763f9b0` — persistent-profile native context | Exact diff review; included in reviewer gate at `18ccce6` | **GREEN**: portable GIO mode test replaced the broken `std.c.Stat` binding; profile-backed live bridge passed. | Approved. Main/related child context sharing, data/cache paths, SQLite cookie storage, ownership, and screenshot isolation are sound. Final restart persistence/isolation E2E remains for N4 integration. |
| `18ccce6` — post-readiness `dom.waitFor` deadline | Exact diff review, then `xvfb-run -a zig build test --summary all` | **GREEN**: 59/59 steps, 394/394 tests; first-RPC readiness E2E passed in 3.01 s. | Closes the script/native timeout-ordering blocker. The engine consumes readiness from the command budget before serializing the JS timeout and adding bounded native completion grace. |
| `0c041cc` — profile app wiring and restart E2E | Exact diff review; author reports 60/60 steps, 394/394 tests twice | **NOT STANDALONE**: the commit's `build.zig` also references cc_2's uncommitted N6 test file, so its reported gate depended on another owner's dirty files. | Profile restart and fresh-profile isolation scenario is strong. BLOCKER: ordinary E2Es now default to the user's real persistent profile and must receive per-test profile/XDG isolation. SHOULD: reset native profile state when no default directory resolves in a reused process. |
| In-progress N6 `social.*` diff after `0c041cc` | Shared `xvfb-run -a zig build test --summary all` during red phase | **RED**: initially 37/60 steps, 274/274 completed tests; nine compile steps failed because `social_routes.zig` was imported before it existed. | Early BLOCKERS mailed: external key must be `loggedIn`, platform detection must parse the host, pause must be proven through the actual queue/socket path with cancellation/deadline semantics, and server routing must not stop at an exported module. |
| `cab8829` — contenteditable/profile follow-ups | Exact diff review; pending the next stable full gate | Contenteditable follow-ups approved. | The live Draft-style fixture cancels every `beforeinput`, updates its own model synchronously, and rerenders; socket assertions cover model + DOM for type, replacement fill, and empty fill. Plain-editor assertions now prove exactly one `input` per edit. The app reset SHOULD is closed. The separate E2E profile-isolation BLOCKER remains open because this and other launchers still omit `--profile-dir` and inherit the real default profile. |
| `4d9b7a1` — `social.*` production routing | Exact diff review; author reports 62/62 steps, 407/407 tests, but the commit removed its standalone social-test build step (restored only in the live worktree) | **BLOCKED**. | BLOCKER: public result says `logged_in`, not contracted `loggedIn`; pause acknowledges immediately and cannot return cancelled during its own pause; platform detection substring-matches the entire URL rather than the host; social automation failures bypass root telemetry and omit trace/command IDs. SHOULD: overlapping shorter pauses must not shorten a longer one; reject unknown params. Mailed cc_2 with an explicit stop-before-N5 request. |
| `2bd2735` — N6 contract follow-up | Exact diff review; author reports 60/60 steps, 398/398 tests on exact HEAD | **PARTIAL**. | Closes `loggedIn`, authority/host matching, blocking/cancellable queue-owned pause, and empty-param validation for login/rate. BLOCKER remains: all social calls still bypass root telemetry and -320xx errors omit trace/command IDs. SHOULD remains: pause/set-pacing silently accept unknown fields. |
| `4e20e65` — restore N6 test target and readiness deflake | Exact diff review | Approved. | Restores the social route tests lost in the shared-index race. The readiness E2E still sends `dom.waitFor` first, but now waits for the delayed fixture's serve timestamp before comparing, removing a parallel-load observation race without weakening the startup assertion. |
| `ab9bab3` — `dom.press` script/live E2E | Exact diff review; an isolated-XDG reviewer gate caught the expected red phase immediately before the JS landed; author reports final 60/60 steps, 398/398 tests | **BLOCKED pending follow-up**. | BLOCKER: printable insertion appends instead of replacing the caret/selection and treats all input types as text. SHOULD: focus must precede modifier keydowns; tests must assert exact keydown/keypress/keyup ordering, exact counts, suppression after cancelled keydown, and no Draft-style synthetic `input` after cancelled `beforeinput`. Mailed cc_1 before N3. |
| `5046b78` — social IDs/root spans and strict params | Exact diff review; included in the later 62/62 reviewer gate | **PARTIAL**. | Closes error/root ID continuity, one root per routed social call, queued-cancellation lifecycle, and strict params. BLOCKER remains: `social.login_check` calls `PagePort.url` and `evalJson` directly, so both native operations omit required `automation.platform.eval` children. Mailed cc_2 before N5. |
| In-progress cc_1 profile/press follow-up after `5046b78` | Exact diff review, then `xvfb-run -a zig build test --summary all` | **GREEN**: 62/62 steps, 413/413 tests; all five real-binary automation E2Es passed. | The shared E2E runner now supplies a unique temporary XDG data/cache root per test process, closing the real-profile contamination/parallel-sharing blocker. Press now focuses before modifiers, replaces selections, excludes non-text inputs, respects cancelled keydown/beforeinput, emits the contracted keypress sequence, and has exact live assertions. Awaiting owner commit. |

## Open findings

### BLOCKER — GTK dispatch must never run inline on the server thread

The socket server starts before `zb_app_run` enters `gtk_main`. GLib's
`g_main_context_invoke[_full]` may invoke the callback synchronously when the
calling thread owns or can acquire the context. The native bridge must attach an
idle/custom source to the intended context (or otherwise prove UI-thread-only
execution), and the dispatched callback must verify the UI thread before
touching WebKit objects.

Owner: cc_1 / BlackRobin. Mailed 2026-10-10.

Closed for the primary path by `e0a101f`: the bridge continues to use explicit
idle sources and now tracks/destroys queued sources atomically with loop end.

### BLOCKER — loop shutdown must release queued sources and cover early exits

Commit `e04591f` wakes waiters when `gtk_main` returns, but early failures in
`zb_app_run` return without marking the loop ended. In addition, a queued idle
source that never dispatches after loop exit retains its job ref, including in
the race where submission passes the ended check just before shutdown. Loop
termination must destroy pending sources and cancel future async work, not only
broadcast to waiters.

Owner: cc_1 / BlackRobin. Mailed 2026-10-10.

Closed by `e0a101f`; every `zb_app_run` exit marks the loop ended, pending
sources are destroyed, and the live-job counter reaches zero in the green gate.

### BLOCKER — exactly-once completion requires heap/refcounted state

The waiter can time out while the main-thread source or WebKit async callback is
still pending. No queued callback may retain caller-stack state or Zig slice
pointers. One locked terminal transition must cover success, platform error,
timeout, cancellation, window destruction, and late callback; the final owner
frees the request/result state. Shutdown must wake pending calls before the
server thread is joined.

Owner: cc_1 / BlackRobin, with engine cancellation mapping owned by cc_2 /
BlueBeaver. Mailed 2026-10-10.

Closed for the reviewed operations by `e0a101f` plus the existing engine
cancellation mapping. The timeout, loop-end, window-destruction, and late eval
paths retain refcounted state and release all jobs in the live test.

### BLOCKER — `waitFor` requires WebKit's async-function API

`automation.js:106-168` returns a Promise. The installed WebKit headers state
that `webkit_web_view_call_async_javascript_function` is the API that properly
passes a returned Promise result to the completion callback. Plain
`webkit_web_view_evaluate_javascript` is not sufficient for this command.

Owners: cc_1 and cc_2. The proposed `PagePort.evalJson` contract now explicitly
requires the async-function API.

Closed by `274928b`; WebKitGTK uses
`webkit_web_view_call_async_javascript_function`, and the live Promise test is
green in the `e0a101f`/`5712919` gate.

### BLOCKER — socket-driven E2E must traverse the production chain

The historical M12 wording prioritizes page-initiated `zbHost`, but this task's
priority is socket to page. At least one GTK E2E must send a framed request to
the real server and assert a live DOM side effect or page-derived typed result.
It must fail if the old template response returns or if a fake port bypasses the
native chain.

Owner: cc_2 / BlueBeaver. Mailed 2026-10-10.

Closed by `afe0498`: the real binary is driven over a persistent external UDS
connection for all ten priority methods and verifies page-derived results and
side effects. `e0a101f` additionally makes the lifecycle E2E's first RPC a
title read, covering the startup race without a DOM synchronization command.

### BLOCKER — retry child spans cannot hard-code attempt zero

`automation.js` currently emits `attempt.index = 0` for every selector span.
M7 requires child spans from successive retries to carry monotonic indexes. The
engine must pass the current attempt into the script or normalize the returned
child spans before recording them.

Owner: cc_2 / BlueBeaver. Mailed 2026-10-10.

Status: **CLOSED by `e2b02ec`**. The engine-supplied `attempt_index` is consumed
by `automation.js`; `f1daa1f` subsequently removed the residual one-million
clamp and covers the complete `u32` range.

### BLOCKER — retries must not start or finish beyond the command deadline

Commit `fba3ffd` computes a remaining budget but starts another attempt even at
zero remaining time, then grants non-wait attempts a minimum 250 ms native
deadline. This makes success after the command deadline possible. Only the
`waitFor` script/native ordering grace has a documented reason to extend the
native wait; ordinary retry attempts must fit the remaining command budget.

Owner: cc_2 / BlueBeaver. Mailed 2026-10-10.

Commit `0fc312a` closes the minimum-250-ms extension and all reported ordinary
retry overruns. A zero-timeout command still begins one 1-ms native attempt at
the already-reached deadline; this residual is tracked as SHOULD.

### BLOCKER — delayed typing must obey the deadline and handle empty text

`typeWithDelay` sleeps the raw accepted `u64 delay_ms`, which can exceed the
command deadline by an arbitrary amount and can overflow the real clock's
integer conversion. With empty text it performs no selector/actionability check
and returns success. Delay sleeps must be bounded by remaining time, and empty
text must preserve the same target-validation semantics as the undelayed path.

Owner: cc_2 / BlueBeaver. Mailed 2026-10-10.

Commit `0fc312a` closes the overflow, over-deadline sleep, and empty-text
bypass. A separate M8 blocker remains: queue shutdown cannot interrupt a legal
long inter-character sleep once it has started.

### BLOCKER — invalid JSON-RPC IDs must not execute commands

Commit `f6a9d05` converts object, array, and boolean IDs to JSON `null`, then
continues through the router and engine. Those are invalid JSON-RPC request IDs;
the server must return `-32600` and avoid executing side effects. A missing ID
(notification) is a separate case and ultimately requires no response.

Owner: cc_2 / BlueBeaver. Mailed 2026-10-10.

Still present in `4644087` at `src/automation_server.zig:253,331-340`.

Closed by `1441fd3`, which rejects the invalid ID before router/queue/engine and
asserts zero PagePort calls.

### BLOCKER — startup commands must not observe the transient empty document

The server begins accepting before the initial WebKit load completes. DOM
retries handle `script_not_ready` and retryable no-match results, but
`page.url`, `page.title`, and `page.evaluate` are intentionally single-shot and
an empty title is a valid result. The PagePort/native bridge must therefore
gate live-page reads/evals until the primary window's initial load reaches a
terminal state, bounded by the caller deadline. The acceptance test must send a
socket command immediately, without first polling lifecycle readiness.

Owner: cc_1 / BlackRobin. Mailed 2026-10-10 after orchestrator reproduction.

Closed for the primary socket path by `e0a101f`. The shim publishes readiness
only after the first load finishes or fails and waits on it for reads/evals
within the caller's deadline. DOM commands additionally retain the engine's
deadline-bounded `script_not_ready` retry. The lifecycle E2E's first RPC is now
`page.title`; the author reports that it fails consistently on the parent
binary and passes with the fix, and the reviewer reproduced the green result.

### BLOCKER — queue wait must consume the command deadline

`4644087` acquires the same-page ticket before the engine derives its deadline.
Consequently a command with a 1-ms timeout may wait behind a 30-second command,
then receive a fresh 1-ms budget and mutate the page. The formal interface puts
`deadline` on `IN8_AutomationCommand` before `C14_PageFIFO`; derive the absolute
deadline before enqueue or subtract the saturated queue wait for every page and
DOM operation. If the budget is exhausted, PagePort must not be touched.

Owner: cc_2 / BlueBeaver. Mailed 2026-10-10.

Closed by `f1daa1f`; queue wait is subtracted from every operation budget and an
exhausted budget fails without touching PagePort.

### BLOCKER — shutdown must interrupt delayed typing waits

`4644087` checks cancellation before each PagePort attempt, but
`typeWithDelay` performs the entire accepted `delay_ms` in one sleep. A delay
just below the maximum command timeout can therefore make `server.stop()` wait
for hours or days. The inter-character wait needs bounded cancellation/deadline
checks, with a test that cancels during a long delay.

Owner: cc_2 / BlueBeaver. Mailed 2026-10-10.

Closed by `1441fd3`; long delays sleep in at-most-16-ms slices with cancellation
checks, including a one-hour-delay cancellation test.

### BLOCKER — raw command data still crosses the `TelemetrySink` boundary

`a5a28ad` introduces a production sink vtable, but `CommandSpanAttrs` still
contains raw `selector`, `typed_value`, and `url`, and the engine passes those
fields directly to `TelemetrySink.recordCommandSpan`. Only
`InMemoryTelemetrySink` hashes/classifies them. A future OTLP sink therefore
receives exactly the sensitive data M11 says must be removed before every sink
call. Add a `TelemetryRedactor` (or an equivalent redacted span type) before the
vtable and test it with an alternate rejecting/spy sink; `containsRaw` on the
in-memory implementation cannot detect this abstraction-boundary leak.

Owner: cc_2 / BlueBeaver. Mailed 2026-10-10 with plan lines 805-809.

Closed by `5712919`; `CommandSpanAttrs` structurally contains only a
`RedactedCommand`, and an alternate spy sink checks the vtable boundary.

### BLOCKER — M11 telemetry must match the full schema and every routed outcome

`f1daa1f` establishes trace continuity and allowlisted child forwarding, but its
required-root test omits several attributes mandated by M11 and its platform
span lacks backend/version, timeout, page/window, and platform error class.
Commands that parse successfully but fail before engine entry (`session_invalid`
or cancellation while queued) record no root span or trace/command IDs. In
addition, the obsolete parser-side root emitter remains callable alongside the
engine emitter and can create two roots for one command.

Owner: cc_2 / BlueBeaver. Mailed 2026-10-10.

Commits `a5a28ad` and `7ff7d72` close the missing schema keys, duplicate-root
path, no-page root/IDs, queued-cancellation root/IDs, queue-inclusive duration,
URL userinfo output, and unbounded selector-kind issues. Pre-sink redaction
remains separately blocked above.

### BLOCKER — telemetry redaction must normalize URL authority and selector kind

The root redactor treats the complete URL authority as `target.host`, leaking
userinfo from URLs such as `https://user:password@example.com/path`. It also
stores any selector prefix before `=` as `selector.kind`, allowing malformed,
attacker-controlled high-cardinality or secret-like text. Both fields need
bounded parsing/normalization plus denylist tests.

Owner: cc_2 / BlueBeaver. Mailed 2026-10-10.

URL authority normalization landed in `a5a28ad`; bounded selector kinds landed
in `7ff7d72`. Those output-specific leaks are closed.

### BLOCKER — native test must not mutate process-global environment in-process

The in-progress early-`zb_app_run` failure test calls raw libc `unsetenv` and
`setenv`. Two independent full-gate runs then hung. GDB showed the live-driver
thread in `std.debug.print` after a panic/deadlock in Zig's environment scan,
while the main thread remained in `gtk_main`. Exercise the no-DISPLAY path in an
isolated subprocess so the test runner's cached environment cannot be
invalidated.

Owner: cc_1 / BlackRobin. Mailed 2026-10-10 with GDB evidence.

Closed by `e0a101f`: the test replaces the existing `DISPLAY` value rather than
removing its environment slot. The reviewer reran the full gate successfully
with 379/379 tests.

### BLOCKER — script and native deadlines race for `dom.waitFor`

`waitFor` schedules a JavaScript timeout at the command's remaining timeout,
while the native call proposes to cancel at the same deadline. If native
cancellation wins, the engine loses the script's specific
`element_not_found`/`timeout` result. The native deadline needs completion grace
or another ordering guarantee, with the command deadline remaining authoritative.

Owners: cc_1 and cc_2. Mailed 2026-10-10.

Status: **CLOSED by `18ccce6`**. The engine now performs the readiness barrier
within the command budget before it computes and serializes the script timeout;
the native call receives that post-readiness remainder plus bounded completion
grace. A real-socket regression delays the initial page for two seconds (longer
than the old grace) and receives the script's `element_not_found`/`timeout`
result for the first RPC.

### BLOCKER — timeout arithmetic and ABI narrowing must be bounded

The v2 engine adds native grace with ordinary `u64` addition, while the native
ABI takes a 32-bit `unsigned int`. A caller-provided near-maximum timeout can
panic on addition or narrowing. Use saturating arithmetic and explicit
validation/clamping at the boundary, with limit tests.

Owners: cc_2 for engine arithmetic and cc_1 for the C wrapper boundary. Mailed
2026-10-10.

Status: **CLOSED by `4d53189`**. The engine clamp landed in `f6a9d05`, including
near-`u64.max` wait/navigation tests, and `4d53189` added a saturating
`u64`-to-`c_uint` adapter conversion with its own boundary test.

### BLOCKER — timed-out navigation must stop and release its exact load

The current native diff gives navigation/reload jobs a `GCancellable`, but
`auto_start_load` never supplies it to WebKit or otherwise consumes it. After
the waiter marks a load job abandoned, cancelling that unused object does not
stop the navigation and does not remove the job from `zb_auto_inflight`. A
stalled load can therefore retain the job until window destruction, and a call
that already returned timeout can continue changing the live page. Cancellation
must run on GTK, remove exactly the abandoned load's ownership, and must not
stop a newer command's navigation.

Owner: cc_1 / BlackRobin. Mailed 2026-10-10.

Closed by `e0a101f`; abandonment runs on GTK, checks window load generation and
displacement, stops only the owned load, untracks it, and the stalled-load live
case leaves zero jobs before the next navigation.

### BLOCKER — the fixed application load timer overrides command deadlines

Every `WEBKIT_LOAD_STARTED` calls `window_reset_load_state`, which installs the
legacy 15-second timeout. An automation `page.navigate` or `page.reload` with a
larger accepted timeout can therefore be terminated early and reported as a
navigation failure rather than `navigation_timeout`. The browser-level timer
and PagePort command deadline need one authoritative policy.

Owner: cc_1 / BlackRobin. Mailed 2026-10-10.

Closed by `e0a101f`; automation-owned loads remove the legacy timer and use the
caller's deadline.

### BLOCKER — command payloads must not become generated-code injection

Selector, fill/type text, URL, and evaluation expressions cross a native
JavaScript boundary. DOM-command JSON must be transported as data (preferably a
WebKit async-function argument) or embedded only through a proven JSON-string
encoding; it must never be concatenated as raw JavaScript source. The local
WebKit API's `arguments` parameter expects an `a{sv}` variant rather than an
undocumented null value.

Owners: cc_1 and cc_2. Mailed 2026-10-10.

Status: **CLOSED by `274928b`**. `20cf9b5` made the DOM function body fixed and
passed the serialized command as a WebKit async-function argument; `274928b`
implemented that `a{sv}`/`GVariant` transport in the production shim. The
client-provided `page.evaluate` expression remains executable code by contract,
not command data interpolated into the DOM dispatcher.

### BLOCKER — script child spans need the root `parent_span_id`

The in-progress command mapper carries `trace_id` and `command_id` but not
`parent_span_id`. `automation.js` consumes that field for selector and
actionability child spans, so the current shape produces orphaned spans and
cannot meet M7/M11 trace continuity.

Owner: cc_2 / BlueBeaver. Mailed 2026-10-10.

Status: **CLOSED by `20cf9b5`**. The mapper serializes the root span id as
`parent_span_id`; engine and script tests cover the field, and `f1daa1f`
additionally reparents allowlisted script spans at the telemetry sink boundary.

### SHOULD — raw native/JavaScript diagnostics must remain internal

WebKit `GError` messages and JavaScript exception messages can contain full
expressions, URLs, selectors, or typed values. JSON-RPC and telemetry should
expose stable error classes/codes, not raw diagnostic strings.

Owners: cc_1 and cc_2. Mailed 2026-10-10.

### SHOULD — release the WebKit argument `GVariant`

The installed WebKit GIR declares the async-function `arguments` parameter as
transfer-ownership `none`. The current bridge creates it with
`g_variant_dict_end` and never releases it, leaking one dictionary and its
copied command string per evaluation. Sink/release it after initiating the
async call, while preserving WebKit's borrowed lifetime requirements.

Owner: cc_1 / BlackRobin. Mailed 2026-10-10.

Closed by `e0a101f`; the argument dictionary is ref-sunk and unrefed after the
transfer-none WebKit call starts.

### SHOULD — explicit child windows need target-specific readiness

`e0a101f` correctly gates the priority primary-page path, but `auto_run_op`
always waits on the primary readiness flag, including when the caller supplied
an explicit child `ZbWindow`. Once the primary is ready, a child command can
therefore run against that child's initial empty document; before the primary
is ready, an otherwise-ready child is unnecessarily blocked. Track readiness
for the resolved target before declaring the second-priority M9/window path
complete.

Owner: cc_1 / BlackRobin. Mailed 2026-10-10.

### SHOULD — preserve accepted `dom.type.delay_ms`

The router accepts `delay_ms`, but the in-progress script command drops it.
Either carry it into an implementation that honors it or explicitly reject and
document it; silently accepting it is not a faithful command mapping.

Owner: cc_2 / BlueBeaver. Mailed 2026-10-10.

Commit `fba3ffd` implements per-code-point delayed typing, so the silent-drop
issue is closed. Deadline, empty-input, and attempt-index issues in that
implementation were closed by `0fc312a`; shutdown interruption is tracked as a
separate blocker above.

### SHOULD — retry timeout mapping must retain the most specific observation

The current retry accumulator stores only the latest failure. If an element is
matched but obscured, then disappears before the deadline, the final
`element_not_found` overwrites the stronger actionability evidence. Preserve an
actionability match/error once observed and test changing failure classes.

Owner: cc_2 / BlueBeaver. Mailed 2026-10-10.

Commit `0fc312a` preserves actionability evidence, closing this finding.

### SHOULD — attempt indexes must stay monotonic for every accepted timeout

The engine uses a `u32` attempt index, which JavaScript represents exactly, but
`automation.js` clamps it to 1,000,000. The accepted maximum timeout permits
roughly 134 million 16-ms attempts, so child span indexes become constant after
about 4.4 hours and violate the M7 monotonicity contract. Validate the engine's
actual `u32` range rather than flattening it.

Owner: cc_2 / BlueBeaver. Mailed 2026-10-10.

### SHOULD — `automation.js` behavior not covered by the production gate

Current script tests load the source directly into Playwright and bypass the
server, native bridge, isolated world, and WebKitGTK runtime. Additional gaps
relevant to the live path are contenteditable fill/type behavior, native setter
compatibility for framework-controlled inputs, untrusted synthetic events,
Promise completion for `waitFor`, isolation from the page world, and cleanup on
native cancellation rather than only script timeout.

Owners: cc_1 for WebKit behavior and cc_2 for fixture coverage.

## Deferred scope note

M6 includes `page.screenshot`, while the task's priority method list does not.
The current PagePort proposal deliberately defers screenshot. This is acceptable
only as an explicit task-scope divergence; it does not satisfy the complete M6
milestone as originally written.
