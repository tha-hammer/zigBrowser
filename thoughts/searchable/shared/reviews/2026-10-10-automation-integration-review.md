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
| `8c275b5` / `a37fc35` — isolated E2E profiles and N2 press fixes | Exact diff review; included in the clean-export gate at `448c306` | **APPROVED** for the requested scope. | Every build-gated automation launcher gets a fresh XDG data/cache root. Press focus/event order, Enter keypress, cancellation, selection replacement, non-text inputs, and Draft-style cancelled `beforeinput` are covered. Known non-blocking limits: no Backspace/Delete editing default and no Enter newline default in textarea/contenteditable. |
| `fa21e3b` / `955b032` / `448c306` — N3 `dom.selectOption` | Exact diff review; clean-export gate at `448c306` | **BLOCKED pending one native-select fix**. | Popup lookup is scoped, retries own all async waiting, no timer can click after timeout, disabled options/optgroups map to `element_disabled`, and the live socket covers value/label/index, ARIA, delayed render, and ghost-click prevention. BLOCKER: selecting a later native option by label/index when values are duplicated assigns `select.value`, which selects the first duplicate. SHOULD: an ARIA option is checked for visibility but not receives-events before direct synthetic dispatch. |
| `a094020` — external-command PagePort child spans | Exact diff review; clean-export gate at `448c306` | **APPROVED**. | `social.login_check` uses instrumented `Engine.External.url/evalJson`; success emits exactly two correctly parented children and URL failure emits exactly one, with trace/command continuity and no username/script/result leak. This closes the last N6 blocker. |
| `817f369` / `2fd84a2` — N5 cookie routes and follow-up | Exact diff review; author reports 64/64 steps and 431/431 tests for `2fd84a2`; reviewer clean-export gate predates it | **BLOCKED pending follow-up and native integration**. | Socket routing, value-free roots, one EV17 child, C-boundary control rejection, prevalidation, byte/count caps, partial-failure data, and basic adapter-result validation are present. BLOCKERS: malformed JSON/Netscape flags can silently downgrade secure/httpOnly/session/sameSite; 5,000 independent 10-second native budgets permit nearly 14 hours of work; EV17 omits required page/backend dimensions. Production GTK CookiePort and live profile round-trip remain open. |
| Clean export of `448c306` | `task_export_dir=$(mktemp -d); git archive HEAD \| tar -x -C "$task_export_dir"; cd "$task_export_dir"; timeout 900 xvfb-run -a zig build test --summary all` | **GREEN**: 64/64 steps, 426/426 tests. | All five live automation E2Es passed. The expected Windows/runtime probe printed its DISPLAY skip while the overall build step succeeded. This result does not claim coverage for the later `2fd84a2`. |
| Automation socket security pass at `448c306` | Source-level lifecycle/auth audit against the Phase 2/3 transport contract | **BLOCKED**. | Socket mode is inherited from umask and is not forced to 0600; default token is empty and therefore disables authentication while exposing `page.evaluate`; token comparison uses timing-dependent `std.mem.eql`; WebSocket upgrade bypasses the JSON auth gate. Mailed cc_2, cc'ing cc_1 for app-level token coordination. |
| `de0c800` — Python SDK wrapper alignment and auth | Exact diff review; author reports 64/64 steps and 431/431 tests | **BLOCKED**. | Top-level auth serialization matches the current server. BLOCKER: the new mock-only “server alignment” table claims `linkedin.follow` is accepted, but the production server routes only cookies.*, social.*, and the core router, whose method table has no linkedin.*; a live call returns -32601. The canned OK server cannot prove production conformance. Mailed cc_2 with an explicit stop-before-N9b request. |
| `3ecfc25` — Node typed wrappers and auth | Exact diff review; author reports 38 Vitest cases and a green Zig gate | **APPROVED for wire serialization; production conformance remains open**. | All 24 serialized request shapes match the current cookies/social/core router contracts. SHOULD: the suite uses a canned mock and cannot prove the server accepts those requests or returns the declared types; only title has a result-shape assertion. Mailed cc_2 and directed work back to the open N5/security blockers. |
| `fefa281` / `e998714` — strict cookie import, bounded/cancellable batch | Exact diff review; author reports a green gate | **PARTIAL; two persistence blockers remain**. | Strict Netscape field count/booleans/expiry and malformed JSON scalar types are handled; one 30-second set budget, between-entry cancellation, full child dimensions, and non-vacuous partial-count coverage are present. BLOCKER: `session:false` plus `expires:-1`, or conflicting `expirationDate`/`expires`, can still downgrade a persistent cookie to session. BLOCKER: accepted expiry range exceeds GLib's representable range. SHOULD: the stated whole-import deadline begins after read/parse. |
| `4a56ad2` — automation socket hardening | Exact diff review | **PARTIAL**. | Closes forced socket mode 0600, fixed-digest timing-safe token comparison, and configured-token WebSocket auth. Default launch still supplies an empty token, so JSON-RPC and WebSocket dispatch remain unauthenticated; default socket entropy is still only the PID. Generated-token and CSPRNG-path integration remain blocking. |
| `e72b2df` / `279d60c` — GTK cookie bridge and real-binary E2E | Exact diff review; author reports 65/65 steps and 441/441 tests | **BLOCKED pending native lifecycle/range fixes and stronger E2E assertions**. | C inputs/results have clear copied ownership and error strings omit values. BLOCKER: cookie async jobs are not in the tracked set cancelled/released on window/loop teardown. BLOCKER: `g_date_time_new_from_unix_utc` NULL is unchecked for out-of-range expiry. The real socket/profile E2E proves set, HttpOnly, delete, import, and restart persistence, but not exact object-bound secure/expiry round-trip; its output-redaction snapshot races shutdown. |
| `c1c0695` — exact native selection and ARIA actionability | Exact diff review | **APPROVED**. | Selecting by label/index now selects the resolved option even when values repeat; the live socket checks exact `selectedIndex`. ARIA options now pass the click actionability/receives-events checks, with a covered-option no-click regression. Closes the final N3 blocker and SHOULD. |
| `bb5f20c` — shared SDK/server conformance fixture | Exact diff review | **APPROVED for the reported supported-method scope**. | Python and Node emit one shared set of 27 wire cases, and a real AF_UNIX `AutomationApiServer` test proves those cases route without envelope/method/param rejection. Unsupported linkedin/instagram namespaces are explicitly documented and excluded; adding `linkedin.follow` to the aligned set fails -32601. Closes the misleading Python alignment blocker and Node mock-only SHOULD without claiming unsupported routes exist. |
| `4377674` — CSPRNG socket name and object-bound native cookie assertions | Exact diff review | **APPROVED for the stated slice**. | Default socket names now use 64 bits from OS secure randomness. The in-process GTK seam parses each returned cookie and proves exact persistent/session expiry, HttpOnly, Secure, SameSite, domain/path/value, and URL scope on the same object. Watchdog spawn failure is cleaned up. Default auth, native expiry defense, async cookie teardown, and the real-binary output-snapshot race remain separate findings. |
| `c99d4fb` — cookie contradiction/range/deadline follow-up | Exact diff review | **BLOCKED pending three follow-ups**. | Correctly rejects dual expiry fields and most session contradictions, caps every numeric import/set format at GLib year 9999, and checks cancellation before read and after parse. BLOCKER: `session:true` with a positive `expires` field is still silently weakened. BLOCKER: synchronous path reading can block forever on a FIFO/device despite the nominal deadline. BLOCKER: Netscape include-subdomains is parsed then discarded, so `FALSE` with a dotted domain can widen scope. |
| `99fdf20` — server token sidecar | Exact diff review | **PARTIAL; app integration and one failure cleanup remain**. | The server publishes an exclusively created mode-0600 token before listen, refuses a blank sidecar token, replaces rather than follows a pre-planted symlink, removes the sidecar on normal stop and later startup failures, and documents the same-UID trust boundary. BLOCKER: the cleanup `errdefer` is registered only after `writeTokenFile` succeeds, so create-then-write/flush failure can leave a partial sidecar. Production app generation/client auth and missing/wrong live dispatch proof remain open. |
| `9f2e995` — SDK sidecar discovery and CLI trace hint | Exact diff review | **BLOCKED pending reconnect fix**. | Python sync/async and Node read `<socket>.token` when no explicit token is supplied, and the CLI inherits it; the corrected `zigbrowser-cli trace` hint is approved. BLOCKER: the discovered token is cached indistinguishably from an explicit token, so reconnecting the same client after a browser restart continues sending the prior session's token instead of rereading the rotated sidecar. |
| `5f7381c` — SDK token rotation on reconnect | Exact diff review | **APPROVED**. | Python sync/async and Node distinguish explicit credentials from discovered credentials, reread on every connect, and clear a prior discovered token if the sidecar disappears. Same-object rotate/reconnect coverage exists for all three clients. Closes the `9f2e995` blocker. |
| `20340b9` — WebSocket auth casing and init OOM cleanup | Exact diff review | **APPROVED for its stated fixes**. | Header field names and the Bearer scheme are ASCII-case-insensitive while token bytes remain exact; allocation-failure enumeration proves all successful config dupes are released. The separate create-then-write sidecar cleanup blocker remains open. |
| `64fc8e2` — N7 native GDK seam | Exact diff review; author reports 65/65 steps, 451/451 tests | **BLOCKED; isolated seam only**. | Basic native click/key/text reach the page as trusted events and copied string/job ownership is sound. BLOCKERS: a whole native text runs as an unbounded synchronous GTK job; the ack counters accept spoofable untrusted events; tests call the C exports directly rather than the socket production chain; and no Draft-style cancelled-beforeinput contenteditable is covered. Exact function-key parsing and non-ASCII behavior are SHOULDs. Mailed both owners; PagePort/router integration is parked. |
| Clean export of `64fc8e2` (also covers `20340b9` and `5f7381c`) | `review_export_dir=$(mktemp -d); git archive HEAD \| tar -x -C "$review_export_dir"; cd "$review_export_dir"; timeout 900 xvfb-run -a zig build test --summary all` | **GREEN**: 65/65 steps, 452/452 tests. | All real-binary automation E2Es passed, including the exact `dom.selectOption` ghost case on this run. The expected Windows/runtime DISPLAY probe printed its skip while the overall build step succeeded. |
| `2579d7c` — `telemetry.query` and bounded recent-trace store | Exact diff review; author reports 65/65 steps, 456/456 tests | **BLOCKED**. | Auth/envelope placement, redacted sink-boundary storage, bounded trace eviction, configured-sink fanout, and strict params are present. BLOCKER: child spans are emitted before the root, but a full 64-span trace drops every later span before considering `is_root`; a retry-heavy trace therefore loses its root/outcome instead of remaining a root-first tree. Mailed cc_2 with a 64-children-then-root regression requirement. |
| `2891c69` — tracked/drained native cookie jobs and expiry defense | Exact diff review; author reports 65/65 steps, 456/456 tests | **CODE PARTIAL; evidence BLOCKED**. | Cookie jobs now participate in window tracking/cancellation, callback refs are counted, callbacks untrack exactly once, and expiry outside GLib's range or a NULL `GDateTime` is rejected without a value leak. BLOCKER: the 30-call “timeout” regression discards every status and can pass if every call completes normally; no known cookie callback is held across loop end, and the one-second drain silently tolerates exhaustion. Require deterministic abandoned-cookie and loop-end proofs. |
| `c4b763c` — Python/Node SDK live binary tests | Exact diff review; author reports a green 66-step gate and manual Node live run | **PARTIAL**. | Python is build-gated and proves the SDK over the real socket/router/engine/page chain, including typed error and trace lookup. BLOCKER: Node cleanup attaches its exit listener after an unconditional kill; if the child already exited, the promise never resolves. SHOULD: Node live coverage is optional and not CI/build-gated. N9 also remains blocked by `2579d7c`. |
| `e63549e` — real-binary cookie object assertions and output drain | Exact diff review | **APPROVED**. | Exact expiry, HttpOnly, Secure, session/persistent behavior are bound to named objects over the real socket and restart. Output redaction is checked only after both browser processes exit and both stdout/stderr readers reach EOF. Closes the native-cookie round-trip and output-snapshot findings. |
| Clean export of `e63549e` (covers `2579d7c` through `e63549e`) | `review_export_dir=$(mktemp -d); git archive HEAD \| tar -x -C "$review_export_dir"; cd "$review_export_dir"; timeout 900 xvfb-run -a zig build test --summary all` | **GREEN**: 66/66 steps, 456/456 tests. | All real-binary E2Es passed, including Python SDK, cookies, startup readiness, and exact `dom.selectOption`. This does not close the source/test-review blockers recorded above. |
| `1489aab` — authenticated-by-default app integration | Exact diff review; author reports 66/66 steps, 457/457 tests | **APPROVED**. | Default launch uses a 256-bit OS-random per-session token and a mode-0600 sidecar; explicit blank files fail closed. Every real E2E client authenticates, missing/wrong `page.evaluate` cannot dispatch, and normal shutdown removes the sidecar. Same-UID readers are explicitly the trust boundary. Overall security closure still awaits the server's create-then-write failure cleanup. |
| `611a95d` — strict cookie import scope and special-file refusal | Exact diff review; author reports 66/66 steps, 460/460 tests | **APPROVED**. | Nonblocking open plus an opened-descriptor regular-file check rejects FIFO/device/directory without TOCTOU or a blocking open; the 4 MiB bound remains. `session:true` rejects both persistent-expiry spellings, and Netscape subdomain flags must agree with the leading dot. Closes the three remaining Zig cookie-route blockers. |
| `a10fdc4` — readiness E2E budget under gate load | Exact diff review; included in author's 66-step gate | **APPROVED**. | Raising the RPC budget from 3 s to 5 s leaves it above the 2 s delayed-load fixture plus loaded startup while preserving the property that readiness consumes the command budget rather than the 1 s native grace. |
| `9bce6b5` — sidecar failure cleanup, late trace root, Node teardown | Exact diff review; author reports a green gate and Node live 1/1 | **APPROVED**. | Post-create sidecar failures unlink the partial file and a fault-injection test proves neither sidecar nor socket remains. A full recent trace evicts one child for its late root. Node observes exit before signaling and bounds both shutdown stages. Closes the security, trace-store, and Node-hang blockers. NIT: the unused race timer remains referenced for 8 s after a fast Node shutdown. |
| `5f0fcf9` — N10 automation guide and coverage guard | Exact diff review; author reports 66/66 steps, 463/463 tests on rerun | **PARTIAL; SHOULD corrections mailed**. | The guide covers the socket/auth trust boundary, method and error reference, profiles, cookies, SDKs, contenteditable, synthetic input, and telemetry; the guard prevents methods and codes from disappearing entirely. Corrections required: explain explicit-token setup and the CLI limitation; distinguish contenteditable `fill`'s one replacement event from `type`'s per-character key sequence; and qualify blanket deadline/retry/readiness statements for external methods, `dom.query`, navigation, and cookies. The guard is substring-only and cannot prove those semantics. |
| `6d1de0e` — deterministic off-viewport `selectOption` | Exact diff review; author reports 5/5 standalone, Playwright 34/34, and a green full gate | **APPROVED**. | The E2E proves the ghost combobox begins outside the viewport and still requires exact `-32001/no_option`; unexpected errors now include full data. Scrolling the control before its receives-events hit test fixes the root cause without broadening the accepted error set. |
| `845146f` — deterministic loop-end result and live-eval deflake | Raw failing backtrace, exact diff/refcount review; author reports 25/25 stress passes and 66/66 steps, 463/463 tests | **CORE FIX APPROVED; cleanup SHOULD open**. | The observed `expected 5, found 3` is the pending eval returning JS instead of NO_LOOP. The nearby DISPLAY diagnostic belongs to the preceding intentional GTK-init-failure test, not the live test. Retaining the never-settling Promise resolver and completing tracked jobs with NO_LOOP before WebKit process teardown address the two actual races without double completion/ref release. SHOULD: make DISPLAY/stderr restoration and partial `pipe`/`dup` failure cleanup exception-safe. |
| `0a3643d` / `366344b` — deterministic cookie timeout and loop-end teardown | Exact state/refcount review; clean-export gate at `366344b` | **APPROVED**. | The delay-hit handshake proves the timeout case entered RUNNING rather than expiring while queued. A held cookie timer/callback ref is outstanding when the GTK loop ends; the waiter must receive `NO_LOOP`, the timer source and async ref are released once on GTK, and final live-job count is zero. This closes the cookie teardown evidence blocker. |
| `1a29268` — N10 documentation corrections | Exact diff review | **PARTIAL; SHOULD open**. | Explicit-token setup, the CLI limitation, contenteditable fill/type differences, query immediacy, and readiness exceptions are documented. The timeout section still incorrectly applies to every command and `2be72b7` obscures the valid `timeout_ms:0` one-attempt contract: page calls receive only a 1 ms native budget, but the engine still performs one attempt. |
| `87aba0d` — deadline-bounded native text | Exact diff and ownership review; included in clean-export gate at `366344b` | **APPROVED for this N7 blocker**. | Text is split into bounded synchronous per-code-point jobs using the remaining deadline, reports the actual release prefix, and cannot trap the GTK thread for an unbounded whole string. N7 remains open for trusted acknowledgement, production PagePort/socket routing, Draft-style native behavior, and exact key parsing. |
| `106a539` — action scrolling for click/fill/type | Exact diff review; live E2E included in clean-export gate at `366344b` | **APPROVED**. | Non-force actions scroll before visibility/receives-events checks, while force semantics remain unchanged. Live click/fill below the fold are non-vacuous. NIT: add an explicit below-fold type assertion when touching the fixture next. |
| `ddb80b7` / `880b19b` / `2be72b7` — N11 X routing, flows, and live E2E | Exact source/test diff review; clean-export gate at `366344b` | **BLOCKED**. | The page queue is held for the whole flow; nested steps use the same root IDs, sink, and cancellation; strict params, pacing, stale-draft replacement, schedule conversion, and the real socket chain are present. BLOCKER: a successful-but-malformed nested result can leave `failure == null` and panic in `Runner.takeFailure`. BLOCKER: Post selection treats a positive bbox as actionability and can choose a hidden/obscured or wrong duplicate. BLOCKER: the queue E2E can be vacuous and compares client response timestamps even though the queue ticket is released before the first response is written. SHOULD: assert the Draft fixture's cancelled-beforeinput event record, remove the fixture-only public `compose_url`, and define a whole-flow deadline. |
| `8cfd802` — target-specific child-window readiness | Exact concurrency/lifetime review; included in clean-export gate at `366344b` | **CODE APPROVED; regression evidence BLOCKED**. | The mutex-protected snapshot carries readiness per live window, off-thread code only compares opaque pointers, explicit stale targets return `NO_WINDOW`, and GTK still revalidates before use. The local-file child can finish loading before the test issues its eval, so the test does not prove an operation submitted while the child is unready waits for that child's load. |
| Clean export of `366344b` | `D=$(mktemp -d); git archive HEAD \| tar -x -C "$D"; cd "$D"; timeout 900 xvfb-run -a zig build test --summary all` | **GREEN**: 71/71 steps, 486/486 tests. | All real-binary E2Es passed, including cookies, profile/readiness, SDK, input, and X flows. A green gate does not close the source/test-proof blockers above. |
| `1eff576` — held child-load readiness proof | Exact concurrency/test-oracle review; author reports a green full gate | **APPROVED**. | A child subresource is held for 800 ms, the test records that the eval was issued before the child response, then requires the real child title and isolated-world `getText`. This closes the target-specific readiness evidence gap. SHOULD: if `DelayServer.start()` fails while spawning its thread, its listening descriptor is not yet protected by the caller's defer. |
| `b768329` — trusted ACKs and exact F-key parsing | Exact script/C/live-test diff review; author reports 71/71 steps, 486/486 tests | **APPROVED for these N7 findings**. | Isolated-world input acknowledgement ignores page-dispatched untrusted events; existing native checks prove real input advances it. The native parser accepts exact `F1` through `F12` only. Public `dom.press` must still reject unsupported keys as `-32602` before calling the native seam. |
| `6e09368` — below-fold `dom.type` regression | Exact E2E diff review; author reports 71/71 steps, 486/486 tests | **APPROVED**. | The real socket test re-establishes an off-viewport input after fill, types through the production chain, and proves the existing value changes from `deep` to `deeper`. This closes the `106a539` evidence nit. |
| `ff68c95` — native-text partial progress | Exact ABI/state-machine diff review; author reports 71/71 steps, 486/486 tests | **APPROVED for the native seam**. | `out_chars` reports fully completed UTF-8 code points while `out_releases` remains the trusted-ACK target, including modifier releases. Sync jobs already started are waited to completion, making the progress exact at timeout boundaries. PagePort/engine must preserve this rather than retrying a partially emitted full string. Also closes the child `DelayServer.start()` descriptor-leak SHOULD. |
| `335031c` — X totality, Post probing, and queue-race follow-up | Exact diff review; author reports 71/71 steps, 491/491 tests and a 2/2 failing queue mutant | **BLOCKED; partial closure**. | Exact nth-element trial clicks, strict final targeting, Draft-style cancelled-`beforeinput` assertions, HTTP fixture use, and explicit profile isolation are good. BLOCKERS remain: five empty query rounds have no pacing and miss a zero-to-late first button; candidate inspection is capped at four despite the “every copy” contract; and a malformed successful answer after an earlier failed probe returns that stale failure, while the no-prior-failure `-32603` omits trace/command IDs. SHOULD: the 120 s flow limit can overrun by one complete step, and the queue oracle still relies on a 1 s scheduling grace rather than a deterministic dispatch handshake. Mailed cc_2 as message 4542. |
| `75710c9` — native locate and ACK-waiting GTK port methods | Exact script/adapter/live-test diff review; author reports 71/71 steps, 486/486 tests | **BLOCKED**. | One monotonic budget spans baseline, dispatch, and polling; C-owned strings are freed; partial dispatched-character progress survives error mapping. BLOCKERS: document-local ACK counters reset on navigation; `parseFromSliceLeaky` leaks every poll; NUL-bearing key/text truncates at the C ABI; `locate` ignores force and focus does not place the caret at the end; and post-return evals do not prove the method itself waited for ACK. Poll sleep can overrun the remaining deadline. Mailed cc_1 as message 4544. |
| `30b7fed` — PagePort-v3, router, and native engine plumbing | Exact diff review; clean export of this commit under Xvfb | **GREEN gate: 71/71 steps, 506/506 tests; CODE BLOCKED**. | Locate retries and native dispatch share one deadline; trial is side-effect free; keys/NUL are validated; typed secrets stay out of script payloads; dispatch is terminal. BLOCKERS: partial failures are always mislabeled `action_timeout`; short successful sends are accepted as complete; and native force can hit an overlay/prior focus. SHOULD: unsupported `options.input` is silently ignored by several verbs, root telemetry omits required `input.mode`, and fake-port append OOM leaks duplicated input. Mailed cc_2 as message 4551. |
| In-progress N7 PagePort-v3 integration after `75710c9` | Exact live-diff/interface review | **BLOCKED**. | `src/automation_gtk_port.zig` defines native methods but does not install them in its `PagePort.VTable`, so the engine reaches the default `Unsupported` stubs. The live tests call adapter functions directly and bypass this production seam. Additional blockers: mouseup is not click completion; whole-string dispatch can type into a replacement document after mid-string navigation; native `force` can physically hit an overlay or prior focus instead of the resolved target; partial failures lose their source error class; and short successful sends are accepted as full success. Mailed both owners as messages 4546–4549. |
| `6d52cd3` — N7 router/engine review follow-up | Exact diff review; clean export under Xvfb | **GREEN gate: 71/71 steps, 510/510 tests; PARTIAL**. | Closes partial-input error-class preservation, short-success rejection, native-force rejection for click/type, bounded root `input.mode`, and native input on unsupported verbs. Still open: the fake port's append-OOM ownership leak; explicit synthetic input remains accepted on unsupported verbs; and press silently accepts unsupported force/trial. The adapter still needs an independent document-change result even when a one-character call reports full progress. Mailed cc_2 as messages 4557–4558. |
| `b0bf83b` — native ACK/navigation/parser follow-up | Exact diff review; clean export with `timeout 900 xvfb-run -a`, followed by automatic tree deletion | **GREEN gate: 71/71 steps, 510/510 tests; CODE BLOCKED**. | Closes ACK parse ownership, bounded polling sleep, direct NUL rejection, caret-at-end, and the simple post-input navigation wait. BLOCKERS: the production vtable still omits native functions; locate returns no document binding; expected-document validation is not atomic with dispatch; whole-string text can cross navigation; timed-out ACK debt can satisfy a later operation; and click waits for mouseup rather than completed dispatch. The test manually drains debt and direct-calls adapter methods, bypassing the production chain. Mailed cc_1 as message 4566. |
| `904acaf` — strict native option grammar and fake ownership | Exact diff review; clean export with bounded Xvfb gate and automatic deletion | **APPROVED: 71/71 steps, 510/510 tests**. | Closes explicit synthetic input on unsupported verbs, press force/trial acceptance, and fake native-payload ownership on append OOM. No new finding. Mailed cc_2 as message 4567. |
| `fe5638e` — completed-click ACK and locate token producer | Exact diff review; clean export with bounded Xvfb gate and automatic deletion | **GREEN gate: 71/71 steps, 510/510 tests; PARTIAL**. | The queued trusted-click counter runs after non-navigating event dispatch/default activation, closing the mouseup-as-completion implementation defect. Locate now returns the isolated-world document token. Production vtable, token crossing/atomic guard, ACK debt, and socket-chain evidence remain open. SHOULD: make the timestamp proof mutation-sensitive and assert the token in the live test. Mailed cc_1 as message 4570. |
| `631cd01` — PagePort v3.1 document binding | Exact diff/lifetime/error review; clean export with bounded Xvfb gate and automatic deletion | **APPROVED for engine/interface: 71/71 steps, 514/514 tests; integration blocked**. | The engine owns the token, relocalizes only before progress, terminates after progress (including full-count one-codepoint `DocumentChanged`), preserves IDs, and does not emit token/text telemetry. SHOULD: validate the producer's exact token/C-string shape, test repeated changes through deadline, and make the no-yield/timeout-atomic contract explicit. The live adapter must still prove the contract. Mailed cc_2 as message 4573. |
| `85424b9` — native PagePort v3.1 adapter and GTK document guard | Exact C/Zig state-machine and production-vtable review; clean export with `timeout 900 xvfb-run -a`, followed by automatic tree deletion | **GREEN gate: 71/71 steps, 514/514 tests; CODE BLOCKED**. | Correctly wires the production vtable, owns the C token copy, checks the token and dispatches without yielding to the GTK loop, waits per code point, preserves a single deadline, and gives completed click dispatch a mutation-sensitive slow-handler proof. BLOCKERS: a guard callback can still dispatch after its waiter returned timeout; baseline/dispatch/settle transactions are not serialized, so one ACK can satisfy two callers; and post-dispatch errors other than Timeout retain no debt. The tests direct-call the adapter rather than traversing the real socket/router/engine/vtable chain. Mailed both owners as message 4575. |
| `74d7baf` — real-socket trusted-input E2E and implicit submission | Exact production-chain/test-oracle review; clean export with bounded Xvfb gate and automatic deletion | **APPROVED evidence slice: 71/71 steps, 514/514 tests; N7 remains blocked**. | Real socket calls reach native click/type/press through router, engine, and the installed PagePort and prove trusted events, Draft-owned editing, invalid-key mapping, partial-prefix reporting, and debt draining. BLOCKER evidence gap: all typed strings are ASCII, leaving the locale/keymap-sensitive Unicode seam unproved. SHOULD: assert trusted Draft `beforeinput` plus zero `input`; use HTML-reflected button type for implicit-submit default-button detection. The synchronization blockers in `85424b9` remain. Mailed cc_1 as message 4580. |
| `a4d1dc5` — X totality/budget/queue follow-up | Exact source/test diff review; clean export with bounded Xvfb gate and automatic deletion | **GREEN gate: 71/71 steps, 520/520 tests; CODE BLOCKED**. | Closes zero-copy pacing, the four-candidate cap, malformed-result stale errors/missing IDs, and the old queue false-pass. BLOCKERS: clearing every failure on any successful substep makes missing-composer and mixed-candidate exhaustion return fabricated `-32603`; waitFor starts with timeout zero when less than native grace remains and can exceed the flow deadline; the queue test still uses a 1.5 s scheduling grace to establish enqueue and can false-fail. SHOULD: the advertised 10 s Post search is checked only between whole rounds and may run to the 120 s flow limit. Mailed cc_2 as message 4581. |
| `b8344ce` — X sticky-failure, sub-grace deadline, and deterministic queue proof | Exact source/test diff review; clean export with `timeout 900 xvfb-run -a`, followed by automatic tree deletion | **APPROVED: 71/71 steps, 523/523 tests**. | Closes the three remaining X blockers: successful fallback probes preserve the failure that stopped the flow; waitFor is refused at or below its native-grace requirement and the expired latch prevents fallback work; a real socket/server/queue/engine integration waits for `pendingCount(page_id) == 1` while a blocking PagePort holds the flow. SHOULD: clear the fake hold with `defer`, otherwise an assertion failure before release can hang fixture teardown; the nominal 10 s Post search remains checked only between whole rounds. NIT: update the stale runner-contract comment in `src/x.zig`. Mailed cc_2 as message 4585. |
| `a7bd845` — exact document-token contract and repeated relocation | Exact source/test diff review; touched clean export to avoid stale cache metadata, then bounded Xvfb gate and automatic deletion | **GREEN gate: 71/71 steps, 524/524 tests; PARTIAL**. | Exact 16-lowercase-hex validation matches the producer/native seam, rejects malformed length/case/NUL, and the PagePort atomicity wording is correct. BLOCKER: a contract-valid final re-locate Timeout returns `action_timeout` before the new post-locate deadline check; the test instead lets its fake overrun the supplied timeout by 50 ms and weakens the hard-deadline oracle to 1050 ms. Preserve the last document-change evidence through a bounded final locate and assert at/below the 1000 ms deadline. Mailed cc_2 as message 4593. |
| `d699683` — native guarded-commit, transaction serialization, and debt retention | Exact C/Zig state-machine review; independent no-lock mutant; touched clean-export bounded Xvfb gate | **SOURCE PARTIAL; gate RED 69/71**. All 524 Zig tests and native-input E2E passed; automation-core independently flaked from expected `element_not_found` to `action_timeout`. | Late guarded dispatch and whole-transaction serialization are CLOSED: the commit point is mutex-atomic with abandonment, and the no-lock mutant fails only the two intended assertions. Debt is now recorded before every post-dispatch wait, but its non-Timeout behavior lacked red/green evidence in this commit. The unrelated engine retry flake is owned by cc_2. Mailed as messages 4596, 4600, and 4601. |
| `0db5b78` — honest fake deadlines, X test budgets, and local Post bound | Exact diff review; touched clean export with fresh local cache, bounded Xvfb gate, and automatic deletion | **GREEN gate: 71/71 steps, 525/525 tests; CODE BLOCKED**. | Fake eval and X budget seams now respect PagePort deadlines; queue teardown and the runner comment are fixed; production query/probe timeouts obey the 10-second search bound. BLOCKER: the repeated-relocation override converts every failure at the deadline, including cancelled/internal/session failures, to `document_changed`. SHOULD: the first Post-bound test does not prove `start + timeout <= deadline` and survives removal of either clamp. Mailed cc_2 as message 4602. |
| `d1f708e` — ambiguous-debt, Unicode, Draft trust, and reflected-type evidence | Exact diff/thread-safety review; touched clean-export bounded Xvfb gate with fresh local cache | **RED: 69/71 steps, 526/527 tests**. | Unicode, trusted cancelled-`beforeinput`, zero `input`, reflected invalid button type, and the intended debt-state oracle are correct in isolation. BLOCKER: the test swaps a process-global `ack_reader` and resets global debt while the live WebKit test runs concurrently, causing the live navigation/text assertions to consume fake ACKs. Replace the global seam with local reader/context injection. Mailed cc_1 as message 4605. |
| `be28b36` — relocation mapping and mutation-sensitive Post bound | Exact source/test and error-provenance review | **CODE BLOCKED; gate pending the independent N7 race fix**. | Cancelled, session, internal, and direct script-not-found failures retain their classes, and the Post deadline oracle is now mutation-sensitive. BLOCKER: public `-32009 action_timeout` does not prove PagePort Timeout; a final retryable covered/unstable target also ends through `deadlineFailure` as `action_timeout` and is incorrectly rewritten to `document_changed`. Approval 4609 retracted in message 4614. |
| `36a2844` — Python/Node X wrappers and automation docs | Exact diff review; clean archived SDK dependency install, tests, and TypeScript type-check; automatic tree deletion | **Python GREEN 80/80; Node tests GREEN 48/48 + 1 skipped; TypeScript RED**. | Wrapper wire shapes and result types match the routed X contract, and the docs accurately describe X/native/timing behavior. BLOCKER: `@types/node` is not declared in `sdk/node/package.json` or its lockfile, so a clean `npm ci && npx tsc --noEmit` cannot resolve `node:fs`, `node:net`, or `Buffer`. Mailed cc_2 as message 4617. |
| `f3391f6` — isolate native ACK reader/debt test state | Exact diff/thread-safety review; touched clean-export bounded Xvfb gate with fresh local cache and automatic deletion | **APPROVED: 71/71 steps, 528/528 tests**. | Production `page_acks` remains permanently bound to the live reader; tests use independent reader/context/debt tracker values and never mutate production state. Debt locking and failed-read retention remain intact. Closes the `d1f708e` race and the final N7 ACK evidence blocker. Mailed cc_1 as message 4619. |
| `2f0e179` — N8 native move, cache, and locate viewport | Exact C/Zig lifetime, GTK commit, window-identity, and live-oracle review; included in clean export at `78699a4` | **GREEN gate 71/71, 531/531; CODE BLOCKED**. | Guarded move commit is atomic with abandonment, C owns queued strings, stale/held moves have no side effect, successful move/click updates the cache before later settlement, and viewport values are live. BLOCKERS: the cache is process-global rather than keyed to the actual window, and the navigating-codepoint test now hides the production suffix race behind an explicit navigation wait. Mailed cc_1 as 4624, 4625, and 4629. |
| `78699a4` — retry-timeout evidence and relocation provenance | Exact engine/test diff review; touched clean-export bounded Xvfb gate with automatic deletion | **APPROVED: 71/71 steps, 531/531 tests**. | A final deadline-cut-short PagePort call preserves accumulated selector evidence; a first/early PagePort timeout remains `action_timeout`; relocation fallback uses an internal bare-timeout flag rather than public `-32009`. Closes the two retry/provenance blockers. Mailed cc_2 as 4628. |
| `226d85f` — declared Node ambient types | Exact full-archive `npm ci`, runtime suite, and type-check; automatic deletion | **APPROVED: 48 passed, 1 skipped; `tsc --noEmit` GREEN**. | `@types/node` and its transitive lock entry are declared; the lock root version now matches the package. The earlier partial-tree run was discarded because it omitted the shared fixture. Mailed cc_2 as 4628. |
| `713587b` — N12 cross-target/no-backend integrity | Exact diff review; touched clean-HEAD bounded Xvfb gate with automatic deletion | **GREEN 75/75 steps, 532/532 tests; PARTIAL**. | Windows GNU and macOS arm64/x64 objects compile; the parser currently reports the expected three core `zb_*` symbols for each. The real no-backend socket path returns documented `unsupported` data for every native verb. BLOCKER: an empty parsed symbol set is accepted, so the cross checker can become vacuous. Mailed cc_2 as 4627 and 4633. |
| `56a3988` — non-vacuous cross-target symbol gate | Exact diff review; clean-export `zig build cross-check` with a 300-second bound and automatic deletion | **APPROVED: cross-check GREEN for COFF and both Mach-O targets**. | The production objects must expose `zb_app_run` and `zb_version_line`; a parser returning an empty needed set now fails. A fixture requires one real core symbol plus one deliberately absent symbol, and the checker requires exactly that missing symbol for each object format. Closes the N12 vacuity blocker. Mailed cc_2 after review. |
| `04fee3a` — per-window pointer cache and navigation-start ACK | Exact committed C/Zig/JS lifetime and live-oracle review; author reports bounded gate 75/75, 533/533 plus 10/10 standalone | **CODE BLOCKED**. | Per-window ownership and the immediate strict Enter/suffix oracle close the original two `2f0e179` defects. BLOCKERS: the post-event cache write dereferences a raw window without revalidating its lifetime, and canceled/failed navigation leaves a permanent `leaving` latch that rejects every future native text call in the surviving document. Mailed cc_1 as 4637. |
| `c00fc02` — N13 `x.selfcheck` | Exact route/flow/SDK/docs/test review; clean-export bounded Xvfb gate with automatic deletion | **APPROVED: 79/79 steps, 536/536 tests**. | The report is read-only, unpaced, derived from the single selector table, and all-or-error on malformed page answers. The real socket/browser test mutates one selector match and observes exactly that count change without navigation. Shared wire cases and both SDKs are aligned; author additionally reports Python 81/81, Node 49/49, and clean `tsc`. Mailed cc_2 as 4639. |
| `c4572e9` — N8 PagePort/router/engine humanize implementation | Exact interface, schedule, RNG, error, telemetry, and unit-test review; author reports fresh-cache gate 79/79, 547/547 | **CODE BLOCKED**. | The preflight/no-compression and post-progress document-change shape are correct. BLOCKERS: a cached pointer at the target starts at the target; the first generated key delay is omitted from both preflight and dispatch; injected RNG state is shared unsafely by concurrent page queues. SHOULD: no `input.humanize=true` telemetry assertion. Mailed cc_2 as 4642 and 4644. |
| `7a033a7` — N8 engine review follow-up | Exact committed diff; author reports fresh-cache gate 79/79, 551/551 | **PARTIAL**. | Closes cached-target restart, first-code-point timing, concurrent RNG mutation, and unsupported-motion detection. Zig 0.16 has no `std.crypto.random`; `Io.randomSecure` is the pinned toolchain's OS-entropy equivalent. BLOCKER: the bounded fallback changes from the required radial 80–240 px construction to a uniform viewport point. SHOULD: pin one-character preflight failure and humanize=true telemetry. Mailed cc_2 as 4647. |
| `b2d07d0` — GTK PagePort-v3.2 wiring and real humanized-click E2E | Exact adapter and socket-E2E diff; included in cc_2's later reported gate 79/79, 554/554 | **APPROVED for wiring/evidence; N8 still blocked**. | The GTK vtable now installs the nominally identical `page_port.Point`, `nativeMove`, and per-window `pointer` functions. The real socket path observes trusted mousemoves ending at the clicked button. The two inherited `04fee3a` lifetime/navigation-latch blockers remain open. Mailed cc_1 as 4649. |
| `cf7361b` — exact N8 start construction and regression completion | Exact committed diff; author reports combined fresh-cache gate 79/79, 554/554 (one unrelated live move-oracle flake on the first run, immediate rerun green) | **APPROVED for engine/router N8 contract**. | Every attempted unknown start is target plus a radial 80–240 px offset then viewport-clamped; exhaustion returns without dispatch. One-code-point insufficient budget is `-32009`/`humanize_budget` with zero native calls, and root telemetry proves `input.humanize=true` on that path. N8 awaits the native follow-ups and final reviewer gate. Mailed cc_2 as 4652. |
| `410461f` — post-dispatch pointer-cache lifetime | Exact C/Zig lifetime and oracle review; author reports combined gate 79/79, 555/555 | **APPROVED; pointer lifetime BLOCKER CLOSED**. | After reentrant GDK dispatch the stale `ZbWindow *` is only compared by identity under the published-window mutex; only the resolved live entry is written. GdkWindow refs and destruction checks stop the rest of a pointer sequence after synchronous close. A live self-close seam and raw-write mutant prove the former UAF. The held-timeout oracle still rejects motion at the forbidden coordinates while ignoring unrelated replay. Mailed cc_1 as 4655. |
| `551b235` — N16 LinkedIn/Instagram production routes, shared runner and flow helpers | Exact source/test/ownership review; clean-export bounded Xvfb gate with automatic deletion | **GREEN 79/79 steps, 557/557 tests; CODE BLOCKED**. | The X extraction preserves its accepted behavior, and each social route has one external root, queue turn, and flow budget with pre-pacing scalar validation. BLOCKERS: cap admission races across page queues; URLs are not platform-bound; login follows navigation; two user payloads use fill; story_view never advances; production-chain and social telemetry closure evidence is absent. Mailed cc_2 as 4658, 4660, and 4664. |
| `e44e8a9` — N8 humanize/delay router correction | Exact two-file diff; clean-export bounded Xvfb gate with automatic deletion | **APPROVED: 79/79 steps, 557/557 tests**. | The router checks top-level `delay_ms` presence rather than the type-only parsed slot, so click/type/press all reject the forbidden combination, including zero. Closes the reopened N8 rule-5 router gap. Mailed cc_2 as 4663. |
| `e4b6864` — failed/canceled navigation latch recovery | Exact C/Zig/isolated-world/live-test diff; clean-export `timeout 900 xvfb-run -a zig build test --summary all`, with automatic tree deletion | **GREEN 79/79 steps, 559/559 tests; CODE BLOCKED**. | C-owned request URLs are released and the real isolated-world/GTK adapter path is exercised. Canceled and 204 navigations no longer poison every later text sequence. BLOCKER: a late request-ID callback is assigned to the current unnumbered same-URL navigation, and the live oracle waits for A's ID before starting B, excluding the A-callback-after-B-start race. Retain/order started records and prove immediate same-URL supersession plus policy-block completion. Mailed cc_1 as 4667. |
| `a6241b6` — N16 login/cap/URL/typing/story/telemetry follow-up | Exact 12-file diff; clean-export bounded Xvfb gate with automatic deletion | **GREEN 79/79 steps, 564/564 tests; CODE BLOCKED**. | Approves exact platform hosts, removal of request `baseUrl`, pre-page cookie plus post-nav DOM gates, typed payloads, note truncation, basic story iteration, redacted EV7/EV8 shape, and sequential socket routing. BLOCKERS: admitted success can be silently uncounted after pacing reconfiguration; the cookie gate and default-30s story URL read escape the 120s budget; a >64-child trace drops late EV8; concurrency bypasses queue/flow/PagePort; closure does not start at an SDK. SHOULD: conversation/session hash schema. Mailed cc_2 as 4668 and 4671. |
| `1219446` — navigation arrival barrier, policy-block recovery, and native-input reentrancy | Exact six-file diff; clean-export bounded Xvfb gate with automatic deletion | **APPROVED: 79/79 steps, 565/565 tests; N8 BLOCKER CLOSED**. | Each page navigation owns its shell arrival sequence; immediate same-URL C/D proves two page starts and two arrivals, stale completion cannot clear the newer navigation, and live canceled/204/policy-block cases all permit later input without touching a replacement document. The handler is isolated-world, once per shared content manager, synchronous, and has no window userdata. Focus/key self-close retains GObjects and stops later events. The socket E2E proves a repeated-target humanized path starts off-target and ends on-target with trusted moves. Mailed cc_1 approval after the exact gate. |
| `57a56fd` — N17 native set-input-files | Exact C/JS/live-WebKit diff; clean-export `timeout 900 xvfb-run -a zig build test --summary all`, with automatic deletion | **GREEN 79/79 steps, 566/566 tests; CODE BLOCKED**. | Closes the unbounded post-chooser wait: the job stays async and a withheld WebKit callback returns bounded `FILES_UNCONFIRMED`. Paths are copied/validated without logging content, the handler is in the isolated world, and token ordering rejects an earlier unrelated chooser. BLOCKERS: an applied selection followed by JS/window/process failure loses unconfirmed provenance; the same state is set before the single-file rejection; an armed late chooser after timeout can become an unclaimed default dialog. SHOULD: missing `zbFiles` still clicks. Mailed cc_1 as 4693. |
| `30472b3` — N17 exactly-once provenance and late-chooser tombstones | Exact C/JS state-machine, mutex, lifetime and production-path oracle review | **APPROVED; covered by clean gate at `3bcfbe3`**. | `files_applied` is the side-effect commit point and remaps every ambiguous failure; pre-commit/backstop deadlines select nothing; abandoned armed jobs stay as tombstones and cancel late choosers; missing isolated-world handler/token fails before click. C-owned strings, GObjects, tracked refs and exactly-once completion remain balanced. Closes all three open N17 findings. Mailed cc_1 as 4730. |
| `e58635c` — N16 social closure follow-up | Exact deadline, reservation/concurrency, story, telemetry-retention, SDK/live-fixture and lock review | **APPROVED; covered by clean gate at `3bcfbe3`**. | Exact-once reservations and a two-page/full-flow cap oracle close admission races; one deadline covers cookies through page work; story closure uses URL evidence and retains click failures; compound telemetry is pinned and contains hashes/lengths only; the real binary is driven from the Python SDK. Closes the open N16 blockers. Mailed cc_2 as 4731. |
| `8243dcf` — native/humanized X flow options | Exact router/flow/options/timeout/unit-test review, plus later real-binary evidence in `6507b96` | **APPROVED; covered by clean gate at `3bcfbe3`**. | Strict nested option parsing enforces native-only humanize, and the resolved options reach only the intended composer/type/schedule/submit input steps. The 120-second flow deadline remains authoritative. Mailed cc_2 as 4731. |
| `3b4dd8f` — LinkedIn/Instagram SDK and docs closure | Exact Python/Node/shared-wire/server-conformance/docs review | **APPROVED; covered by clean gate at `3bcfbe3`**. | Both SDKs emit the routed production shapes, Node exposes both namespaces, validation helpers match server defaults, and docs describe the live-site and pacing boundaries. Mailed cc_2 as 4731. |
| `9337bde` — N15 human handoff | Exact documentation/evidence review | **SHOULD, covered by clean gate at `3bcfbe3`**. | The delivery, risks and safe-live-run guidance are accurate. The X row attributes SDK verification to the grouped native/humanize options, although the committed typed X wrappers cannot express the `options` object; qualify that evidence or expose/test the options. Mailed cc_2 as 4731. |
| `6507b96` — N14 trusted native/humanized X E2E | Exact fixture/build/live-test review | **APPROVED; covered by clean gate at `3bcfbe3`**. | The production binary is driven over the external socket. Exact posted/scheduled values, trusted per-character editing, humanized timing, trusted schedule/confirm/Post clicks, and trusted movement ending on Post are all observed in the page. Mailed cc_1 as 4730. |
| `3bcfbe3` — browser-editing undo oracle | Exact test-only diff and exact-mutant rerun; clean-export bounded Xvfb gate with automatic deletion | **APPROVED: 81/81 steps, 577/577 tests; mutation guard 8 CLOSED**. | The real binary/socket test requires synthetic contenteditable typing to create browser undo history. The Range-insert fallback leaves `ab` unchanged and fails; the production execCommand path undoes to a proper prefix. The independent gate covers every reviewed commit from `30472b3` through this commit. Mailed cc_1 as 4732. |
| `9ab165f` — N18 native wheel and event-only hover | Exact C/Zig/script/live-WebKit diff and thread/lifetime review; clean-export gate at `5a9031c` | **APPROVED native slice: 81/81 steps, 583/583 tests; public-route closure remains OPEN**. | `nativeScroll` validates finite inputs, atomically guards document identity at dispatch, holds the required GDK references, waits for the trusted-wheel acknowledgement and 100 ms scroll quiet (or 250 ms no-scroll) inside one deadline, and returns no retryable state after dispatch. The live test reads exact outer/inner offsets immediately and directly kills the stale-token shim guard. Synthetic hover is explicitly event-only; native hover must still establish CSS `:hover` through the PagePort/engine/socket path. Mailed cc_1 as 4738. |
| `9b32f84` — flow `timeout_ms` and humanized budget sizing | Exact router/flow/deadline/arithmetic/unit/E2E diff; clean-export gate at `5a9031c` | **APPROVED after `8a16668`: 81/81 steps, 583/583 tests at `5a9031c`**. | Parsing, precedence, allowlists, absolute social deadlines and code-point budget arithmetic are correct. The original E2E did not distinguish sizing from a fixed 120-second route, so this was blocked in 4737. `8a16668` adds a route-level 3-second seeded oracle that dies if `humanized_text` is removed from the production sizing call and corrects the E2E's evidence claim. |
| `5a9031c` — N15 handoff follow-up | Exact documentation diff; clean-export bounded Xvfb gate with automatic deletion | **APPROVED: 81/81 steps, 583/583 tests; one NIT closed by `8a16668`**. | The X evidence now distinguishes default SDK shapes from raw-socket options and the deferred section records window-close, session-hash, in-memory pacing, and SDK option gaps. `8a16668` clarifies that LinkedIn and Instagram share one social cap while X has its separate cap. Mailed cc_2 as 4737. |
| `8a16668` — route-level humanized-budget oracle | Exact test/handoff diff and mutant-sensitivity review; clean export pinned to the commit under bounded Xvfb, with automatic deletion | **APPROVED: 81/81 steps, 584/584 tests**. | `handleWithBudget` receives a 3-second injected default, a seeded native/humanized engine, and 40 code points whose schedule cannot fit that default. Passing `null` instead of the text to `flowBudgetMs` makes the no-timeout request fail; explicit 3000 ms is the control and emits zero typed characters. The long E2E is now described only as trusted long-text evidence, and the pacing wording is exact. Closes 4737. Mailed cc_2 as 4743. |

## Mutation audit at `137dfa1`

Each row changes exactly one production guard in one clean `git archive HEAD`
export. The focused test and relevant live E2E are timeout-bounded; the source is
restored before the next mutation. **KILLED** means at least one test failed.
**SURVIVED** means every test run stayed green and is a blocker for the owning
test suite.

Checkpoint gate after restoring guards 1-5: the same clean export passed
`timeout 900 xvfb-run -a zig build test --summary all` with **79/79 steps and
566/566 tests**.

| # | Guard and mutation | Focused test | Relevant E2E | Result |
|---|---|---|---|---|
| 1 | Auth token comparison: replace `std.crypto.timing_safe.eql` with ordinary early-exit `std.mem.eql`. | `automation_server_test`: `tokensEqual is exact for equal, different and different-length tokens` — pass. | `automation_api_lifecycle_test.py` — pass, including missing/wrong/correct token behavior. | **SURVIVED.** Functional auth tests do not protect the constant-time primitive. Mailed cc_2 as 4706. |
| 2 | Socket permission guard: change the post-bind `chmod` from `0600` to `0666`. | `automation_server_test`: `the socket file is created with mode 0600` — failed (`0666` observed). | `automation_api_lifecycle_test.py` — pass; it checks the token sidecar mode, not the socket mode. | **KILLED** by the focused unit. The live E2E has no socket-mode assertion. |
| 3 | Invalid JSON-RPC IDs: serialize object/array/bool IDs instead of rejecting them. | `automation_server_test`: `object/array/bool ids are Invalid Request and never dispatch` — failed on the first object ID because the command dispatched. | `automation_api_lifecycle_test.py` — pass; it sends only valid integer IDs. | **KILLED** by the focused unit. The live E2E does not cover invalid IDs. |
| 4 | Queue FIFO head guard: flip the uncontended/head comparison so queued waiters return immediately. | `automation_queue_test`: `same-page commands run strictly FIFO` — timed out/panicked with unreleased waiters. | `x_flows_test.py` — failed: the mid-flow racer bypassed serialization and the post timed out. | **KILLED** by both layers. |
| 5 | Retry deadline guard: flip the full-poll-fit condition so a retryable failure terminates while budget remains. | `automation_retry_test`: `actionability failures until the deadline map to action_timeout; no attempt starts at the deadline` — failed after preserving the wrong first-attempt evidence. | `automation_core_test.py` — failed: a click stopped after one invisible attempt instead of retrying until actionable. | **KILLED** by both layers. |
| 6 | Startup readiness: set the native bridge's `need_ready` guard to false so commands may run before the first load completes. | `webkit.test.automation bridge drives a live WebKitGTK page` — failed 10 checks, including initial title and injected-automation availability. | `automation_readiness_test.py` — passed despite the mutation. | **KILLED** by the focused live-WebKit unit. The dedicated readiness E2E does not independently detect removal of the native barrier. |
| 7 | Isolated-world injection: install `automation.js` in the default page world instead of `ZB_AUTOMATION_WORLD`. | The live WebKit bridge unit failed 14 checks, including the missing automation-world object and page-world visibility. | `automation_core_test.py` timed out/failed. | **KILLED** by both layers. |
| 8 | Contenteditable insertion: force the `execCommand('insertText'/'delete')` branch to return false so the Range-splice fallback performs every edit. | All 15 `js_contract` units passed. | `automation_input_test.py` passed at audit target `137dfa1`, including its Draft-style cancellation checks. | **SURVIVED at `137dfa1`; CLOSED by `3bcfbe3`.** The follow-up real-binary undo-history oracle fails on this exact mutant because a Range splice creates no browser undo step. Mailed cc_1 as 4722; reviewed closure mailed as 4732. |

## Closure audit at `b9299f6`

Gate evidence: a clean `git archive HEAD` export at `b9299f6`, run under
`timeout 900 xvfb-run -a zig build test --summary all`, passed **79/79 build
steps and 565/565 tests**. The output included `PASS sdk-python-live`; the
throwaway export was deleted with `find -delete` immediately after the gate.

The closure oracle below is
`tests/e2e/sdk_python_live_test.py::scenario` (build step
`sdk-python-live-e2e`). It launches the production binary with
`--automation-api` at lines 82-95, imports the production SDK at lines 19-24,
and uses only `ZigBrowser` calls. Lines 41-63 navigate, read the title, type,
observe the resulting live DOM text, arm and click a delayed element, observe
the click's live DOM effect, and verify a real JSON-RPC error plus telemetry.
It therefore crosses the entire chain without replacing any production seam.

| Map item | Production implementation at HEAD | Non-bypassing evidence | Classification |
|---|---|---|---|
| Node 0 — SDK call | `sdk/python/src/zigbrowser/client.py:17-40` maps DOM methods to `ZigBrowser.call`; `:416-448` creates the JSON-RPC request and sends/receives the length-prefixed frame. | `sdk_python_live_test.py::scenario`, especially lines 41-59; the test imports the production SDK rather than a socket mock. | Production-covered. |
| Node 1 — server handles request | `src/app.zig:41-55` starts `AutomationApiServer` alongside the browser; `src/automation_server.zig:287-326` reads each framed request, calls `handleRequest`, and writes the response. | Same live SDK scenario, launched against the real `zigBrowser --automation-api` process at lines 82-96. | Production-covered. |
| Node 2 — router parses | `src/automation_server.zig:450-480` calls `automation.router.parse`, queues, executes, and maps the outcome; `src/automation/router.zig:86-140,222-243` validates parameters and maps the method table. | Same scenario: `page.navigate`, `page.title`, `dom.type`, `dom.getText`, `page.evaluate`, and both successful and failing `dom.click` requests are parsed by the production router. | Production-covered. |
| Node 3 — server thread to GTK main-thread handoff | `src/automation/page_port.zig:7-20` defines the blocking cross-thread contract; `src/automation_gtk_port.zig:82-100` invokes the C ABI; `src/webkit_shim.c:1325-1369,2043-2086` attaches an idle source to the default GTK main context and waits for completion. | Same scenario's DOM operations must cross the live GTK PagePort; their resulting mirror/status text is checked at lines 45-50. | Production-covered. |
| Node 4 — native eval plus injected script | `src/app.zig:41-43` installs before window creation; `src/automation_gtk_port.zig:28-40,82-100` embeds the script and selects the automation world; `src/webkit_shim.c:1507-1538,1891-1936,2115-2128` installs at document start in the named world and evaluates asynchronously there. | Same scenario's `dom.type` and `dom.click` succeed in the live WebKit page and their DOM effects are read back; no direct injection/eval test seam is used. | Production-covered. |
| Node 5 — `automation.js` handle to action | `src/automation/script_command.zig:74-121` maps the parsed command to `{op,...}` and calls `__zbAutomation.handle`; `src/automation/engine.zig:405-413,449-503` executes/retries; `src/automation_script/automation.js:92-124,149-185,684-720,1040-1068` dispatches and performs the actual actions from the published isolated-world object. | Same scenario proves both script typing and clicking through observable page state at lines 45-50, including delayed-element retry. | Production-covered. |
| Node 6 — eval result through server/JSON-RPC to SDK return | `src/webkit_shim.c:1891-1936` completes async evaluation; `src/automation_gtk_port.zig:92-100` copies then frees the C result; `src/automation/engine.zig:479-503` parses it; `src/automation_server.zig:467-480,794-800` serializes and frames the reply; `client.py:430-448` receives result/error. | Same scenario asserts typed results, live values, and the stable `AutomationError` path at lines 42-63. | Production-covered. |
| Edge 0→1 — UDS | SDK framing is `client.py:416-448`; server framing is `automation_server.zig:287-320,794-800`. | Same real-process SDK scenario, lines 82-96. | **Production-covered; not test-only.** |
| Edge 1→2 — same-thread router | `automation_server.zig:323-326,450-480` passes the decoded request directly into production routing and execution. | Same scenario exercises several successful methods and one routed failure. | **Production-covered; not test-only.** |
| Edge 2→3 — cross-thread PagePort | `engine.zig:405-413,449-503` calls the configured port; `automation_gtk_port.zig:82-100` enters the blocking native adapter; `webkit_shim.c:1325-1369` schedules GTK work. | Same scenario runs against the application-installed GTK port, not `FakePagePort`. | **Production-covered; not test-only.** |
| Edge 3→4 — Zig to C shim | `automation_gtk_port.zig:82-100` owns NUL-terminated inputs/result copying; `webkit_shim.c:2115-2128` owns the matching eval ABI and job lifetime. | Same scenario's real WebKit DOM effects require this ABI call. | **Production-covered; not test-only.** |
| Edge 4→5 — native to page JS | `webkit_shim.c:1507-1538,1891-1936` injects/evaluates in `zigbrowser-automation`; `automation.js:1040-1068` exports the handler in that world. | Same scenario observes type and click effects produced by that handler. | **Production-covered; not test-only.** |
| Edge 5→6 — async completion to reply | `webkit_shim.c:1891-1936` completes the job; `automation_gtk_port.zig:92-100`, `engine.zig:479-503`, `automation_server.zig:467-480,794-800`, and `client.py:430-448` carry its result back. | Same scenario asserts both a success result and an error with its trace ID. | **Production-covered; not test-only.** |

No closure edge is covered only by test-only code. Lower-level tests that use
`FakePagePort`, directly evaluate `automation.js`, or open a raw socket are
valuable fault-localization tests, but they are not credited for this audit
because they bypass one or more nodes. The live Python SDK scenario is the
non-bypassing proof for all six edges.

## Live-site readiness review at `53dfbfb`

Documentation review only: no live site was touched. This is not approval for
a live run while the open N16 blockers remain. The complete handoff was mailed
to cc_2 as Agent Mail 4686 for N15.

Gate evidence: a clean export of `53dfbfb` passed the bounded
`timeout 900 xvfb-run -a zig build test --summary all` gate with **79/79 steps
and 565/565 tests**. The export was deleted by its `find -delete` exit trap.

### X selectors and assumptions

| Selector | Assumption |
|---|---|
| `testid=tweetTextarea_0` | X retains this testid and the match is the active Draft/contenteditable composer. |
| `testid=tweetButton`, then `testid=tweetButtonInline`; derived `xpath=(//*[@data-testid="<id>"])[n]` | These IDs still mean final post submission; document order plus the first copy that passes a trial click identifies this composer, not a reply/quote/other composer. |
| `testid=toast` | Any attached toast means posting/scheduling succeeded. No toast text/type is checked, so an unrelated or error toast can false-positive. |
| `testid=scheduleOption` | This testid still opens the schedule dialog. |
| `select[aria-label="Month"]`, `Day`, `Year`, `Hour`, `Minute`, `AM/PM` | English labels, native selects, and exact option values 1-12, 1-31, YYYY, 1-12, 0-59 and AM/PM remain. |
| `testid=scheduledConfirmationPrimaryAction` | This testid still confirms scheduling. |
| `a[href="/login"], a[href="/i/flow/login"], [data-testid="loginButton"], [data-testid="signupButton"]` | These variants cover logged-out UI. `x.login_check` itself only tests composer presence, so a logged-in non-composer page reports false. |

### LinkedIn selectors and assumptions

| Selector | Assumption |
|---|---|
| `.global-nav__me, .global-nav__me-photo` | Desktop global-nav classes reliably mean authenticated, including neither checkpoint nor authwall. |
| `a[href*="/login"], a[href*="/uas/login"], .sign-in-form` | Logged-out variants expose one; substring href matching does not select an unrelated link. |
| `main button[aria-label^="Invite "][aria-label$=" to connect"]` | English aria-label grammar remains and Connect is directly visible rather than under More. |
| `main button[aria-label^="Pending"]` | English Pending state remains a button in `main`. |
| `main button[aria-label^="Follow "]` | English profile-target suffix remains and the direct action is visible. |
| `main button[aria-label^="Following "], main button[aria-label^="Unfollow "]` | Either English label denotes the requested profile's successful followed state. |
| `main a[href*="/messaging/compose"], main button[aria-label^="Message "]` | The first non-strict match is the intended profile message action. |
| `button[aria-label="Add a note"]` | The connect dialog retains this exact English label. |
| `textarea[name="message"]` | The invite note remains this textarea and no competing dialog field matches. |
| `button[aria-label="Send invitation"], button[aria-label="Send now"]` | Either English label sends the note; the first non-strict match is correct. |
| `button[aria-label="Send without a note"]` | The no-note action retains this exact English label. |
| `.msg-form__contenteditable[contenteditable="true"]` | The active editor retains the legacy message-form class. |
| `button.msg-form__send-button` | The send control retains the legacy class and is unique. |
| `button.react-button__trigger[aria-pressed="false"]` | The first non-strict unpressed reaction on a post URL is that post's Like, not a feed/comment reaction. |
| `button.react-button__trigger[aria-pressed="true"]` | The first pressed reaction proves the exact button just clicked changed state. |
| `button[aria-label="Comment"]` | The exact English label and first non-strict match identify the post action. |
| `.comments-comment-box__form [contenteditable="true"]` | The intended post's active comment editor retains these classes. |
| `button.comments-comment-box__submit-button` | The first non-strict match submits that comment. |
| `main h1` | The strict match is the profile name. |
| `main .text-body-medium.break-words` | This class stack uniquely identifies the headline. |
| `main .text-body-small.inline.t-black--light.break-words` | This class stack uniquely identifies location. |
| `.reusable-search__result-container` | Each real result has exactly one legacy container, and placeholders/ads do not reuse it. |

### Instagram selectors and assumptions

| Selector | Assumption |
|---|---|
| `svg[aria-label="Home"], a[href="/direct/inbox/"]` | Desktop English Home or the exact inbox href is present whenever authenticated. |
| `a[href^="/accounts/login"], input[name="username"]` | These cover logged-out variants. |
| `//header//button[normalize-space(.)="Follow"]` | Exact English text on a header button is the intended profile action. |
| Header button text `Following` or `Requested` | Exact English text represents the same profile's successful public/private follow state. |
| Header button/role text `Message` | Exact English text is unique in the profile header. |
| First `//section//svg[@aria-label="Like"]` | The first matching icon belongs to the target post and clicking its SVG dispatches the intended action. |
| First `//section//svg[@aria-label="Unlike"]` | The first marker proves that same post changed state. |
| `textarea[aria-label="Add a comment…"]` | English label with U+2026 (not three dots), native textarea and uniqueness remain. |
| Form button/role text `Post` | Exact English text and the matching form identify the active comment. |
| `div[aria-label="Message"][contenteditable="true"]` | The DM composer retains this English aria-label and contenteditable shape. |
| Global button/role text `Send` | Exact English text is unique; strict execution deliberately fails on duplicates. |
| `section video, section img` | The first matching section media is a story frame, not an avatar, decoration or post. |
| `button[aria-label="Next"]` | Exact English label and first non-strict match identify story advance. |

### Selfcheck coverage and blind spots

All three selfchecks are read-only count reports for the current document.
LinkedIn and Instagram use `flow.selectorReport`
(`src/flow_steps.zig:103-120`); X's equivalent
(`src/x.zig:140-167`) reports each post-button testid separately and excludes
the derived indexed XPath template.

They expose selector syntax/query failure, complete removals/renames when a
human compares the correct page with a recorded baseline, surprising count
changes/duplicates, and signed-in/logged-out marker coexistence. They do not
have expected counts or a pass/fail policy: zero or duplicate matches still
produce a successful report. One page normally has many zeros because each
table spans several contexts. They do not navigate, verify the host, or test
visibility, actionability, enabled/covered state, target semantics, events or
terminal transitions. LinkedIn/Instagram selfcheck deliberately skips the
session-cookie gate. The reports also miss localization, native schedule
option values, toast meaning, post/profile binding, challenge/captcha and
rate-limit UI, cookie freshness, and whether a later action works. X does not
exercise the indexed-copy trial-click selection.

### Rate-limit defaults

- X has a separate in-memory per-server limiter. Only `x.post` and
  `x.schedule_post` consume it: 50 successful actions per UTC day and no
  pacing delay. `x.login_check`/`x.selfcheck` do not count, and
  `social.set_pacing` cannot configure X.
- LinkedIn and Instagram share one in-memory per-server limiter: 100
  successful actions per UTC day and a uniform random 3,000-8,000 ms pause
  before each action. `social.set_pacing` changes that shared min/max/cap and
  `social.rate_status` reports it.
- LinkedIn classifies visit, connect, message, like, comment, follow and search
  as actions; extract and selfcheck are unpaced. Instagram classifies follow,
  like, comment, DM and the whole story-view flow as one action; selfcheck is
  unpaced. Each compound flow has a 120,000 ms hard budget. Only successful
  flows count, and the counters reset on the UTC day or server restart.

### First human live-run order

1. Close the N16 blockers and obtain an exact clean-export green gate. Use
   dedicated disposable accounts/content and a dedicated `--profile-dir`;
   require a token and private socket permissions. Do not use a personal or
   production account.
2. Log in manually in the visible browser. Confirm `page.url`/title and
   `social.login_check` on the intended host. Verify the required LinkedIn
   `li_at` / Instagram `sessionid` cookie exists without recording its value;
   on X, manually open the composer and run `x.login_check`.
3. Capture separate selfcheck baselines for every relevant context: X composer
   and opened schedule dialog; LinkedIn profile, post, conversation and search;
   Instagram profile, post, DM and story. Inspect ambiguous counts and English
   label/localization assumptions manually.
4. Read `social.rate_status`, then set a deliberately low shared
   LinkedIn/Instagram cap and long delay for the trial (for example one action
   per fresh server/platform). X remains independently fixed at 50/no delay.
5. Exercise selfchecks, login checks and `linkedin.extract` before mutation.
   LinkedIn visit/search only navigate, but are still paced and counted.
6. Perform exactly one low-impact action against controlled content, one
   platform at a time. Verify the terminal state in the visible UI and query
   its trace; never infer live success from `{"ok":true}` alone.
7. Stop on selector-count drift, strict duplicates, checkpoint/authwall/captcha,
   challenge or rate-limit UI, unexpected navigation, or a terminal state not
   bound to the intended target. Update selectors/baselines, then rerun fixture
   tests and the clean full gate before proceeding.

## Open findings

### BLOCKER — trusted native input is not proven end to end

`64fc8e2` adds useful isolated C seams. Its isolated-world acknowledgement
counters still count untrusted synthetic events, allowing page code to make a
later native step proceed before the prior trusted event arrives. The tests
call `zb_native_*` directly and cover only a plain input, not the socket chain
or a Draft-style contenteditable that cancels `beforeinput`.

Status: **CLOSED by `f3391f6`**. The production behavior and feature evidence
cover trusted ACKs, exact key grammar, per-code-point bounded text, document
binding, partial-prefix handling, a real socket/router/engine/vtable chain,
native Unicode, and a Draft-style editor with trusted cancelled `beforeinput`
and zero `input`. `d699683` closes late dispatch and transaction races;
`f3391f6` keeps the debt oracle while moving all reader/context/debt test state
into independent tracker values. The clean gate is green 71/71, 528/528.
Mailed as 4605 and 4619.

Live PagePort-v3 review after `ff68c95`: the proposed GTK adapter preserves one
deadline and reports C-side progress, but remains blocked until it handles ACK
counter reset across navigation-triggering click/press, removes a
`parseFromSliceLeaky` poll leak, rejects embedded NUL before the C-string ABI,
and has a non-vacuous proof that the method returns after the trusted ACK. The
engine contract must also preserve force/trial semantics, existing
`dom.type.delay_ms`, end-caret placement, and terminal partial-input handling.

Commit `6d52cd3` closes the engine-side error-class, short-success,
native-force, and root-input-mode defects. Commit `b0bf83b` closes the ACK
parse leak, NUL truncation, bounded sleep, simple counter reset, and end-caret
subfindings. `904acaf` closes the remaining router/fake findings. `fe5638e`
closes non-navigating click completion and supplies the isolated-world token;
`631cd01` carries an owned copy through PagePort and gives document change a
terminal/retry contract. `85424b9` wires the live adapter, makes the
navigation-token check and dispatch one non-yielding GTK callback, stops text
after each post-character ACK, and adds initial ACK-debt tracking. `d699683`
atomically commits only a still-RUNNING guarded job, serializes each complete
native transaction, and records debt before every post-dispatch wait.
`74d7baf` and `d1f708e` provide the real socket, Unicode, trusted-Draft,
invalid-key, and partial-prefix evidence. `f3391f6` removes the thread-unsafe
test seam without weakening the debt oracle. Agent Mail messages 4545–4619.

### BLOCKER — native locate and physical dispatch are not bound to one document

The engine resolves a selector to viewport coordinates, then the adapter
samples whichever document is current before sending physical input. Page A
can replace itself with page B between those operations, allowing an action
validated against A to hit an unrelated target at the same coordinates in B.
The same gap lets a fully counted one-codepoint send (notably Enter) navigate
without giving delayed typing an independent signal to stop its suffix.

Status: **CLOSED by `631cd01`, `85424b9`, and `d699683`**. The engine carries
an owned 16-hex document token and gives pre-dispatch replacement a bounded
re-location contract. The GTK callback compares that token and commits input
without a main-loop yield, only if the job remains RUNNING; a timed-out held
guard sends no late click. Live A-to-B and navigating `"a\\nb"` cases prove the
target binding and suffix stop. Mailed as 4568, 4575, 4596, and 4601.

### BLOCKER — timed-out native input leaves unowned acknowledgement debt

After a timed-out native text call, already-dispatched keyups continue to
arrive. ACK counters are cumulative and not request-tagged, so those late
events can satisfy the next operation's wait and make it return before its own
keyup. `b0bf83b` acknowledges the behavior but only drains it inside the live
test before issuing the next operation.

Status: **CLOSED by `d699683`, `d1f708e`, and `f3391f6`**. The whole native
transaction is serialized; debt is recorded immediately after dispatch and
retained through Timeout, EvalFailed, Cancelled, and NoPage until ACK or
document replacement. The failed-read/drain/settlement oracle kills the
Timeout-only mutant, and `f3391f6` runs it through a test-local tracker rather
than swapping production globals. The clean live gate is green. Mailed as
4572, 4575, 4601, 4605, and 4619.

### BLOCKER — relocation exhaustion must not mask a non-timeout failure

`0db5b78` preserves `document_changed` when the last bounded re-locate times
out, but applies that override to every failure observed at the deadline. A
Cancelled, EvalFailed, NoPage, session, or script-specific locate failure can
therefore be rewritten as `-32001 document_changed`, breaking JSON-RPC error
mapping.

Status: **CLOSED by `78699a4`**. Cancelled, NoPage, EvalFailed, direct script
failures, and retry-exhausted actionability evidence keep their classes. Only
an internally recorded bare PagePort Timeout at the relocated deadline yields
to `document_changed`; the code no longer infers provenance from public
`-32009`. The relocated-obscured regression and exact clean gate are green.
Mailed as 4604, 4609 (approval retracted), 4614, and 4628.

### BLOCKER — a final tiny native timeout must not erase retry evidence

The DOM retry loop may sleep after a retryable selector failure, begin one
last eval with about 1 ms remaining, and return that PagePort Timeout directly.
The client then receives `-32009 action_timeout` instead of the accumulated
selector-specific deadline result. An exact `d699683` gate observed the live
missing-selector contract flip from `-32001 element_not_found` to `-32009`.

Status: **CLOSED by `78699a4`**. `LastFailure.recorded` distinguishes a final
deadline-cut-short call after script evidence from a genuine first/early
platform timeout. Deterministic fake-clock tests cover not-found,
actionability, and first-call Timeout, and the exact clean gate is green.
Mailed as 4600, 4609, and 4628.

### BLOCKER — N8 humanize implementation must satisfy the fixed contract

The orchestrator resolved the earlier proposal disagreement: the native side
owns a per-window last-pointer cache; an unknown start is a random 80–240 px
offset from the target, clamped inside returned viewport bounds and never the
target itself. The unchanged complete schedule must fit before any dispatch,
otherwise the command returns `-32009` / `humanize_budget`. Production uses
`std.crypto.random`; tests inject deterministic randomness. A document change
after at least one move is terminal with no relocation or click, preserving
the last dispatched cached point. `delay_ms` plus humanize and synthetic plus
humanize are both `-32602`.

Status: **CLOSED by `c4572e9`, `7a033a7`, `b2d07d0`, `cf7361b`, `e44e8a9`,
`410461f`, and `1219446`**. The intermediate defects and their closure are
recorded chronologically below. The final exact clean-export gate at `1219446`
is green: 79/79 steps and 565/565 tests.

Commit `2f0e179` remains blocked. Its process-global coordinate crosses window
identity when the old primary closes, and its live test permits a navigating
Enter to return success then waits for navigation before trying the suffix,
bypassing the production per-character race. Mailed as 4624, 4625, and 4629.

Commit `04fee3a` moves the cache into `ZbWindow`, adds a primary-replacement
regression, and restores the strict no-suffix oracle, closing the original two
`2f0e179` defects, but it remains blocked by two new findings. It dereferences
`win` to record the pointer after `gtk_main_do_event`; revalidate against the
mutex-protected published snapshot or document a concrete non-reentrancy
invariant that keeps the window alive through dispatch. Its Navigation API
latch is permanent even when the page cancels or the navigation fails, making
every future native text command in the surviving document fail
`document_changed`. Stop the current action conservatively, but clear a failed
navigation generation without racing a newer one, with a live regression.
Mailed as 4630, 4631, and 4637.

The first cc_2 engine working diff has the correct overall preflight and
post-progress document-change shape, but is not yet contract-complete. A
cached point already equal to the target bypasses the mandatory off-target
start; production entropy comes from `std.Io.randomSecure` rather than the
explicitly required `std.crypto.random`, while an injected mutable RNG is not
serialized across concurrent page queues; and the schedule generates but
discards the first per-code-point delay, so a one-character type runs with a
zero-millisecond key delay outside the 80–200 ms bound. Mailed as 4641 and
4642 before commit.

The engine scheduling portion is **CLOSED by `7a033a7` and `cf7361b`**. Cached
target positions use the same off-target construction as unknown positions;
every key delay is both preflighted and consumed; each command gets a private
CSPRNG whose injected seed source is serialized; and tests pin the one-key
budget error, zero dispatch, telemetry, corners, repeated targets, and
document-change behavior. Zig 0.16 removed `std.crypto.random`, so
`std.Io.randomSecure` is the available OS-entropy equivalent rather than a
semantic deviation. `b2d07d0` also closes the missing GTK-vtable wiring and
proves trusted motion through the real socket chain.

The router portion is **CLOSED by `e44e8a9`**. `router.zig` now rejects the
combination based on top-level field presence for click, type, and press,
including `delay_ms:0`; the exact clean gate is green. Mailed as 4656 and
4663.

`410461f` **CLOSES the window-lifetime blocker**: it revalidates the stale
pointer as identity under the published-window mutex, writes only the resolved
live entry, and proves synchronous self-close with a live seam and mutant.

Status remains **OPEN (cc_1 / BlackRobin)** after `e4b6864` and its green exact
clean-export gate (79/79, 559/559). Canceled and 204 navigations now recover,
and an already-numbered older completion does not clear a newer pending
navigation. The request-ID association is still racy: asynchronously delivered
`navigationRequested(A, url)` attaches A's ID to the current unnumbered
same-URL pending object, which may already be B. The live test waits for A's ID
before starting B, excluding that interleaving. Retain/order started records
and prove immediate same-URL supersession; also prove a policy-block request/end
cannot be lost before association. Mailed as 4649, 4651, 4655, 4657, 4662, and
4667.

The next working diff replaces URL/request matching with a page-to-shell
arrival barrier: each JS navigation object receives its own monotonically
increasing shell sequence, and an end snapshot clears only an object whose
reply arrived by that snapshot. This closes the structural A-ID-on-B race.
Evidence is still OPEN: the immediate C/D test assumes `id_d - 1` belongs to C
without proving C produced a navigation/report, so deleting/coalescing C can
leave the test green. It must pin two starts/arrivals. A live policy-block test
must also prove the page report reaches GTK before the policy-end snapshot;
otherwise that blocked navigation remains conservatively pending forever.
Mailed as 4669.

The revised working diff now pins both same-task navigation starts and both
shell arrivals (`navigations == before + 2`, `id_d == id_b + 2`) and adds a live
policy-block recovery test. The isolated-world handler is installed once per
shared content manager, uses no window userdata, and replies synchronously with
a correctly released transfer-none `JSCValue`. One SHOULD remains: installation
marks the script installed even if handler registration fails, permanently
leaving a script that can create unnumbered pending navigations. Mailed as
4673; no native navigation blocker remains subject to the committed gate.

`1219446` closes the remaining native blocker. It returns the policy verdict
with the page-owned sequence, so a policy decision that precedes the page's
report still ends that exact navigation. The live test requires a blocked
script navigation to increment the page counter, clear pending state, preserve
the document, and allow fresh native text. Immediate C/D and focus/key
self-close oracles are mutation-sensitive. The exact clean gate is green.

### BLOCKER — N16 social action admission must be atomic

The in-progress N16 route checks `SocialState.remaining()` before a compound
flow and calls `consume()` after success under a separate lock. Two page queues
can therefore both enter with one slot remaining and both perform an external
action; the second `recordAction` failure is ignored. Reserve capacity
atomically before the flow, release it on failure, and commit it on success so
only successful actions count. A cap-one, two-page concurrency test must prove
that at most one flow touches its page.

Status: **CLOSED by `e58635c`**. `reserve` returns an owned exact-once
reservation, successful admitted actions are counted even after a cap change,
and `rate_status` subtracts in-flight capacity. The cap-one concurrency oracle
runs two complete `Engine.External` flows on distinct page ports sharing one
state; page B is refused before touching its port while page A is held inside
its first page step, and cleanup always releases and joins page A. The pacing
route holds the non-reentrant lock only once. Mailed approval as 4731.

The follow-up WIP adds a locked `in_flight` count, but admission ownership is
still not exact-once: `commit`/`release` saturating-decrement, and `commit`
silently discards `recordAction` failure. Lowering `daily_cap` while an action
is reserved can therefore let the admitted action succeed without ever being
counted. `rate_status` also reports limiter capacity without subtracting
reservations. The concurrency test calls `reserve` directly rather than
running two page-queue flows and proving that only one touches its PagePort.
Mailed as 4665 and 4668.

The next working diff introduces an exact-once `Reservation` and a dedicated
`countAdmitted` transition, but also makes both `PacingPort` methods acquire the
state spin lock while the route still holds that same non-reentrant lock.
`social.rate_status` and `social.set_pacing` therefore deadlock. A bounded
route-level regression is required in addition to the still-missing two-flow
concurrency oracle. The author's own bounded gate then stalled in the social
socket-routing test; GDB showed its 99%-CPU worker spinning in
`SocialState.acquire -> PacingPort.getState -> social.rateStatus`, while the
client waited for the response. Mailed as 4672 and 4674.

The current WIP adds the missing two-flow/PagePort cap oracle, but its spawned
page-A thread is released and joined only after fallible page-B assertions. A
failed assertion therefore leaves page A spinning forever instead of reporting
the cap regression. The release/join must be installed as unconditional
cleanup, and the wait for page A to enter its held step must be bounded. The
non-reentrant route/port lock recursion itself remains present. Mailed as 4679.

### BLOCKER — N16 URLs must be bound to their platform

`551b235` preflights required values, UTF-8/text limits, query type, username,
and a generic absolute-http URL shape before pacing. Its URL check still lets
externally supplied profile, post, conversation, and public `baseUrl` values
navigate to unrelated hosts (including userinfo/lookalike forms). Require
parsed HTTPS LinkedIn/Instagram ownership for every external URL. The fixture
base override must be injected below the public trust boundary rather than
making arbitrary navigation part of the production RPC.

Status: **CLOSED by `a6241b6`**. Public request URLs are restricted to exact
HTTPS platform hosts, fixture origins come only from server configuration, and
lookalike/userinfo/non-default-port cases are covered.

### BLOCKER — N16 user text must go through typing behavior

The in-progress LinkedIn invitation-note and Instagram-comment flows put the
user payload directly into `dom.fill`. The behavioral contract requires user
text to be emitted through `dom.type`; `dom.fill` may clear an editor before
typing but must not write the payload. Production primitive-call tests need to
reject any payload-bearing fill step.

Status: **CLOSED by `a6241b6`**. Invitation notes and Instagram comments now
send the user payload only through `dom.type`, with primitive-call tests that
reject payload-bearing `dom.fill`.

### BLOCKER — N16 login, story, telemetry, and closure tests drift from Phase 5

The in-progress platform flows navigate before checking login state, while the
accepted LinkedIn behavior and C31 require a logged-out failure before page
dispatch. Instagram `story_view` waits for one media element but never advances
through story frames. The new route emits only the generic external-command
root, with no platform/action compound telemetry or deny-list proof. Finally,
the current tests direct-call the route with one universal fake reply, bypassing
the server route, page queue, socket framing, and SDK closure path while failing
to assert primitive order and payloads. These are production contracts, not
unit-only details.

Status: **CLOSED by `e58635c` and `3b4dd8f`**. One absolute deadline now
covers the cookie gate, pacing pause and every page step. Story completion is
positive URL evidence that the viewer left `/stories/`; a failed Next while it
remains open preserves that click failure. The bounded trace store pins the
late compound span beside the root. `social_flows_test.py` launches the real
binary and starts at the production Python SDK, while shared Python/Node wire
cases and the real-server conformance test cover every routed method. Conversation
URLs use `conversation.id_hash`; raw payloads and cookie values do not cross the
telemetry sink. `session.id_hash` remains intentionally undefined because this
server has no session-id contract. Mailed approval as 4731.

HEAD `1219446` substatus for the 4658/4660 review set:

- **CLOSED by `a6241b6`:** platform-bound URLs and server-only fixture origin;
  scalar/text/URL validation before pacing or page work; payloads sent through
  `dom.type`; login cookie gate before navigation plus DOM gate after it; basic
  story frame iteration; redacted EV7/EV8 schema; sequential raw-socket routing.
- **OPEN (cc_2 / BlueBeaver):** exact-once cap accounting under concurrent
  queue/flow/PagePort execution; one absolute deadline including the cookie
  gate and every story step; failure-preserving story completion; retention of
  the late EV8 compound span beyond 64 children; SDK-to-socket production
  closure and aligned SDK/docs. The uncommitted working-tree follow-up does not
  change these HEAD statuses and currently has the separately mailed deadlock
  and story-failure blockers.

The follow-up WIP closes the host, payload-typing, pre-navigation cookie-gate,
and basic EV7/EV8 redaction gaps, but three blocking seams remain. The absolute
120-second budget is reconstructed only after the fixed 10-second cookie read,
and `story_view` then calls `page.url` with its independent default 30-second
timeout after reserving only 16.5 seconds. The fake runner makes primitive
commands instantaneous, so its deadline assertion cannot catch that overrun.
EV8 is emitted after every step; a long story produces more than the bounded
trace store's 64 children, causing the late compound span to be dropped as an
ordinary child. Finally, the raw-socket fake-PagePort test does not start from
an SDK and is sequential, while the Phase-5 blocking closure begins at the
SDK. The Python namespace and alignment-test prose still state that these
methods are unrouted. Conversation URLs are also hashed under
`profile.id_hash` instead of required `conversation.id_hash`, and
`session.id_hash` is absent. Mailed as 4665 and 4668.

The next working diff puts the cookie gate under an absolute deadline and
removes the independently timed `page.url` probe, but its story replacement
currently treats any failed Next click followed by zero media as successful
completion. That masks unrelated element/actionability/timeout/cancellation
failures, and the new unit test codifies the ambiguity. The timeout test also
checks only `timeout_ms <= 120000`, not `step_start + timeout_ms <= deadline`.
The completion signal must discriminate the expected viewer-close condition,
and a fake-clock boundary test must exercise the absolute deadline. Mailed as
4672. Two deadline SHOULDs were mailed as 4675: a CookiePort timeout at the
flow boundary still reports `session_cookie_unreadable` instead of the platform
flow-deadline reason, and the story frame-fit precheck budgets only one of its
two queries.

The subsequent WIP also replaces the story URL check with the broad
`section video, section img` selector. A real profile grid can satisfy that
after the last Next leaves the viewer, incrementing `framesViewed` once too
many; the fixture profile omits this exact decoy. The new Python live E2E does
start at the production SDK and launch the real binary with an isolated
profile, closing the earlier SDK-boundary shape once it is build-gated, but it
cannot validate this live-page assumption as written. Mailed as 4696 together
with the still-present deadlock, masked-click and hanging-test blockers.

### BLOCKER — N17 set-input-files loses its deadline after chooser dispatch

The in-progress native set-files job starts as asynchronous, but the
`run-file-chooser` callback changes it to synchronous immediately after the
chooser arrives. `auto_job_wait` consequently ignores the deadline while it is
still waiting for the WebKit-process async JavaScript completion callback. A
delayed or lost callback after file selection can therefore pin the socket
worker indefinitely. Keep the side-effect commit exactly once without making
that remaining IPC wait unbounded, and cover the chooser-arrived / JS-callback-
withheld boundary deterministically. The current job also claims the next file
chooser on the window rather than proving it came from the requested element;
that association race needs serialization or explicit WebKit ordering evidence.

Status: **CLOSED by `57a56fd`**. `ZB_OP_SET_FILES` remains asynchronous after
the chooser is answered, and the live WebKit test withholds the JavaScript
answer for two seconds under a 500 ms deadline. The call returns bounded
`ZB_AUTO_ERR_FILES_UNCONFIRMED`; the former `is_async = 0` mutant fails that
oracle. The token/message ordering also closes the original “next chooser”
association concern for a chooser that precedes the job's token. Mailed as
4680/4681; closing review and remaining distinct blockers mailed as 4693.

### BLOCKER — N17 loses post-selection exactly-once provenance

`57a56fd` records `files_answered = 1` before the single-file backstop, then
uses that value to decide whether a timeout means files were applied. A
deadline that wins between those operations can report `FILES_UNCONFIRMED`
even though the chooser was cancelled. Conversely, after files really were
selected, an asynchronous JavaScript error, process failure, navigation or
window cancellation returns the ordinary JS/cancel error because only Timeout
is remapped. A caller can therefore retry an already-triggered auto-upload.
The native job needs a separate side-effect-committed state, set only at the
selection call, and every ambiguous failure after it must be unconfirmed.

Status: **CLOSED by `30472b3`**. `files_applied` is set under the automation
mutex only immediately before `webkit_file_chooser_request_select_files`, and
every non-OK completion after that point maps to `FILES_UNCONFIRMED`. A held
pre-commit deadline stays a plain timeout with no selection; a post-commit
script failure reports unconfirmed and is not retry-safe. Mailed approval as
4730.

### BLOCKER — N17 timeout can expose a late default file dialog

On abandonment, `57a56fd` clears the job's target and removes it from the
in-flight list. If the already-issued click's chooser signal arrives after
that cleanup, the chooser callback finds no job and returns false, enabling
WebKit's real default dialog after the socket caller already received Timeout.
The live test globally cancels unmatched choosers through a debug mode, which
masks that production branch. Preserve sufficient armed-job/tombstone state
to cancel the associated late chooser and prove the production behavior with
a deadline-before-chooser oracle.

Status: **CLOSED by `30472b3`**. An abandoned armed job remains tracked as a
tombstone until its late chooser is cancelled or its operation answers. The
production-path oracle leaves unmatched-chooser debug cancellation disabled,
proves the late chooser cannot reach the default-dialog branch, and then proves
a new call succeeds. Mailed approval as 4730.

### SHOULD — N17 clicks when the isolated-world file handler is unavailable

`automation.js` still calls `element.click()` if `zbFiles` is absent or the
injected token is invalid. Handler registration failure therefore opens a
native dialog and waits for timeout instead of failing before side effects.
Require the handler and token, and diagnose `zbFiles` registration failure.

Status: **CLOSED by `30472b3`**. The isolated-world operation rejects a missing
handler/token with `files_unavailable` before `element.click()`, and handler
registration failure has an independent diagnostic. Mailed approval as 4730.

### BLOCKER — N18 synthetic hover does not establish browser hover state

The in-progress `automation.js` hover op dispatches mouse events directly on
the element. Script dispatch neither moves WebKit's pointer nor establishes
CSS `:hover`, so listener-only fixtures can pass while hover-driven menus and
tooltips stay closed; pointerover/enter/move are also absent. Native hover must
finish with a real pointer move and the live oracle must assert a
`:hover`-dependent effect, or the API must explicitly document a weaker
event-only synthetic contract.

Status: **OPEN for production-chain evidence (cc_1 / BlackRobin, cc_2 /
BlueBeaver seam)**. `9ab165f` explicitly defines synthetic hover as event-only
and adds pointerover/enter/move, which resolves the synthetic contract choice.
Its native primitive is a real pointer move. Closure still requires the routed
native-hover implementation and a socket E2E whose oracle is a CSS
`:hover`-dependent effect, not only listener events. Native-slice approval was
mailed as 4738.

### BLOCKER — N18 wheel acknowledgement is not scroll completion

The in-progress GTK port returns when the page acknowledges the trusted wheel
event, but its own native test then polls for up to three seconds outside the
method because smooth scrolling continues. A socket command built directly on
that port can return while the offset is still moving, racing the next command.
The PagePort/engine must verify a stable final offset under the same deadline,
or the public API must be defined as one wheel dispatch rather than completed
scrolling. The socket E2E must read the offset immediately after the response.

Status: **OPEN for PagePort/engine/socket integration (cc_1 / BlackRobin,
cc_2 / BlueBeaver seam)**. `9ab165f` closes the native completion defect: the
method waits for acknowledgement and then 100 ms quiet, or 250 ms with no
scroll, under the same deadline. Its live WebKit test reads exact outer and
inner offsets immediately after return, and a direct stale-token call proves
no wheel dispatch. The agreed PagePort contract returns settled
`ScrollOffsets`; closure still requires that interface to be wired and the
socket E2E to read offsets immediately. Native-slice approval was mailed as
4738.

### SHOULD — closing one window terminates every related WebKit child process

`on_window_destroy` calls `webkit_web_view_terminate_web_process` before
removing one window. Related views created by `window.open` share that web
process, so closing the primary also kills the child page that becomes the new
primary. The `04fee3a` pointer-identity regression consequently needs its own
`zb_app_run` and proves ownership only before that replacement page is used.

Status: **DEFERRED by orchestrator to a follow-up**. This behavior predates N8
and changing shutdown semantics is outside the pointer-cache fix, so it does
not block N8. The follow-up must decide whether single-window close should
preserve related live pages. Reported by cc_1 in message 4636 and classified
in review response 4637.

### BLOCKER — Node SDK type-check is not reproducible from a clean checkout

`36a2844` adds typed X wrappers and reports a clean TypeScript build “with
`@types/node`,” but does not declare that package. After `npm ci`, the runtime
tests pass while `tsc --noEmit` cannot resolve `node:fs`, `node:net`, or
`Buffer` in `sdk/node/src/client.ts`.

Status: **CLOSED by `226d85f`**. The SDK declares and locks `@types/node`; an
exact full archive passes `npm ci`, 48 runtime tests with one live test skipped,
and `tsc --noEmit`. Python's declared dev-extra gate remains green 80/80.
Mailed as 4617 and 4628.

### BLOCKER — N12 no-backend test hides the documented unsupported reason

The N12 working test accepts any `-32011` from a native request when no backend
is installed. The public SDK documentation promises `reason: "unsupported"`
on non-GTK targets, but the application currently supplies no PagePort there;
the server therefore follows the no-page path and returns `session_invalid`
without that reason. A code-only assertion permits this contract drift.

Status: **CLOSED by `713587b`**. The engine detects a backend without native
input before locate/page work and returns `session_invalid` / `unsupported`.
The real socket/server/engine test pins click, type, and press separately, and
the exact clean gate is green. Mailed as 4622 and 4633.

### BLOCKER — N12 cross-symbol check can pass with no symbols examined

`tools/check_cross_symbols.py` regards an empty parsed undefined-symbol set as
success. A parser/layout/reachability regression can therefore print
`needs []` for every object and leave the platform gate green without checking
any shim definition.

Status: **CLOSED by `56a3988`**. The production check requires known core
symbols, so an empty or incomplete parse fails. A separately compiled fixture
requires one defined core symbol and one deliberately missing symbol; the
self-test requires exactly that missing-symbol result for COFF and both Mach-O
targets. An exact clean-export `zig build cross-check` is green. Mailed as
4627 and after the closing review.

### BLOCKER — capped recent traces can discard their root span

`2579d7c` records child spans during command execution and records the root at
completion. `RecentTraceStore.add` drops any incoming span when the trace has
already reached 64 entries before it checks `is_root`; therefore a command with
64 retry children has no root, command status, or duration in
`telemetry.query`, contradicting the root-first tree contract.

Status: **CLOSED by `9bce6b5`**. A late root at the cap evicts the newest child,
is inserted at index zero, and leaves the total at 64; 70 children followed by
a root cover the regression.

### BLOCKER — SDK alignment tests bypass the production router

The Python N9 table in `de0c800` feeds canned success responses and asserts only
the request bytes written by the SDK. It nevertheless claims every row is
accepted by the production server and includes `linkedin.follow`, which is not
routed by `AutomationApiServer` or `automation.router` and therefore returns
`-32601` on the real socket.

Status: **CLOSED by `bb5f20c`**. Unsupported linkedin/instagram namespaces are
explicitly documented as returning `-32601` and are not called server-aligned.
The shared supported-method fixture is consumed by both SDK tests and sent over
a real AF_UNIX connection to `AutomationApiServer`, where method/param/envelope
rejections fail the test.

### BLOCKER — automation socket authentication and permissions are not secure by default

`4a56ad2` forces the socket to mode 0600, compares fixed SHA-256 digests with
`timing_safe.eql`, and applies Bearer authentication to a configured-token
WebSocket upgrade. However, `automationToken()` still returns an empty token
when no token file is supplied, and both JSON-RPC and WebSocket interpret that
as “skip auth,” so default `page.evaluate` remains unauthenticated. Commit
`4377674` closes the predictable-PID path by drawing a 64-bit socket nonce from
OS secure randomness.

Status: **CLOSED by `1489aab` and `9bce6b5`**, building on `4a56ad2` and
`4377674`. Default product launch always authenticates; socket and sidecar are
0600, the path is unpredictable, comparisons are timing-safe, JSON-RPC and
WebSocket enforce the configured token, missing/wrong live `page.evaluate`
does not dispatch, and every tested normal/failure path removes the sidecar.
`AutomationApiServer.Config{ .token = "", .token_file_path = "" }` still
provides an explicit internal/test opt-out; it is not reachable from the
`--automation-api` app path and must not be exposed as a user-facing default.
Same-UID processes that can read the sidecar remain intentionally trusted.

### BLOCKER — cookie persistence can still be weakened or exceed the native range

`fefa281` closes the original malformed scalar-flag downgrade, total-set budget,
and EV17 dimension gaps; `e998714` adds cancellation; `c99d4fb` rejects dual
expiry fields, `session:false` without a persistent expiry, and values beyond
GLib year 9999. Three route/import issues remain. The agreement check only
rejects `session:true` with `expirationDate`, not with a positive `expires`, so
that case is silently weakened to session. The synchronous file read can block
forever on a FIFO/device despite starting the clock first. Netscape's
include-subdomains column is parsed and discarded, allowing `FALSE` plus a
dotted domain to widen scope.

Status: **CLOSED by `611a95d`, `2891c69`, and `e63549e`**. The route now rejects
the remaining session contradiction and Netscape scope mismatch and refuses
non-regular opened handles without a blocking FIFO open. Native range/NULL
validation, exact real-socket object round trip, and shutdown-safe output
redaction are also covered. The separate non-vacuous async-teardown evidence
finding below remains open.

### BLOCKER — GTK cookie jobs need deterministic async teardown

Cookie get/add/delete are async WebKit operations, but `auto_start_cookies()`
does not add them to `zb_auto_inflight`. Window destruction therefore cancels
and releases eval/load jobs but not cookie jobs. If loop end moves a running
cookie job to ABANDONED, the follow-up GTK abandonment source is rejected
because the loop has already ended, leaving the callback-held ref dependent on
a main context that may no longer iterate.

Status: **CLOSED by `366344b`**, building on `2891c69` and `0a3643d`. A hit
counter proves the short-deadline cookie operation entered RUNNING before it
returned TIMEOUT. A separate 60-second held cookie timer is outstanding when
the loop quits; its waiter receives `NO_LOOP`, loop-end removes the source and
releases its async ref on GTK, and the test ends with zero live jobs.

### BLOCKER — X flow error handling and Post selection must be total

`ddb80b7` force-unwraps `Runner.failure` whenever a flow returns null. A
successful nested `dom.query` result that is malformed makes `countMatches` or
`hasVisibleElement` return null while leaving only `last_result`, so an
untrusted page result can panic the server process instead of producing
`-32603`. In addition, `880b19b` treats any positive bounding box as a visible
Post button and later clicks a non-strict selector. `visibility:hidden`, zero
opacity, an overlay, or the first of multiple same-testid elements can make it
choose a target that the click can never act on while a later target is valid.

Status: **CLOSED by `b8344ce`**. Exact nth-element trial clicks and strict final
targeting close the original bbox/non-strict defect, including hidden and
duplicate fixtures. `a4d1dc5` closes zero-copy pacing, the four-copy cap, and
malformed-result stale/missing-ID handling. `b8344ce` preserves the failure
that stopped the flow across later successful fallback probes and refuses a
waitFor that lacks room for native completion grace. Missing-composer and
mixed-candidate regressions cover both paths. The separate SHOULD remains:
the nominal 10-second Post search is checked only between whole query/probe
rounds. Mailed as Agent Mail 4542, 4581, and 4585.

### BLOCKER — X queue E2E does not prove one-turn execution

`2be72b7` delays a second client by 150 ms and compares the two clients'
response receipt times. The fixture has no deliberate mid-flow hold, so the
second request can start only after the X flow already finished and the test
still passes. Conversely, `handleX` releases the queue ticket before
`handleStream` writes the first response, so a correctly queued second request
can reach its client before the first client records its response and make the
test fail.

Status: **CLOSED by `b8344ce`**. The real-binary HTTP scenario retains its
server-answer oracle, and the new production `AutomationApiServer` integration
blocks the flow inside its PagePort, sends the racing socket command, waits
until `pendingCount(page_id) == 1`, and only then releases the flow. It proves
all X page operations precede the racer's navigation without scheduling
grace or response-order timing. SHOULD: install a `defer` that clears the fake
hold so a regression before the explicit release fails promptly instead of
hanging teardown. Mailed as Agent Mail 4542, 4576, 4581, and 4585.

### BLOCKER — native select by label/index mishandles duplicate values

`selectNative()` resolves the correct option, then assigns `select.value` for a
single select. If multiple options share that value, this selects the first one
instead of the option found by label or index while still returning success.

Status: **CLOSED by `c1c0695`**. The resolved option object is selected directly,
duplicate values are covered by label and two indexes in the live socket E2E,
and ARIA options now also pass click actionability before dispatch.

### BLOCKER — GTK dispatch must never run inline on the server thread

The socket server starts before `zb_app_run` enters `gtk_main`. GLib's
`g_main_context_invoke[_full]` may invoke the callback synchronously when the
calling thread owns or can acquire the context. The native bridge must attach an
idle/custom source to the intended context (or otherwise prove UI-thread-only
execution), and the dispatched callback must verify the UI thread before
touching WebKit objects.

Owner: cc_1 / BlackRobin. Mailed 2026-10-10.

Status: **CLOSED by `e0a101f`** for the primary path. The bridge continues to use explicit
idle sources and now tracks/destroys queued sources atomically with loop end.

### BLOCKER — loop shutdown must release queued sources and cover early exits

Commit `e04591f` wakes waiters when `gtk_main` returns, but early failures in
`zb_app_run` return without marking the loop ended. In addition, a queued idle
source that never dispatches after loop exit retains its job ref, including in
the race where submission passes the ended check just before shutdown. Loop
termination must destroy pending sources and cancel future async work, not only
broadcast to waiters.

Owner: cc_1 / BlackRobin. Mailed 2026-10-10.

Status: **CLOSED by `e0a101f`**. Every `zb_app_run` exit marks the loop ended, pending
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

Status: **CLOSED by `e0a101f`** plus the existing engine
cancellation mapping. The timeout, loop-end, window-destruction, and late eval
paths retain refcounted state and release all jobs in the live test.

### BLOCKER — `waitFor` requires WebKit's async-function API

`automation.js:106-168` returns a Promise. The installed WebKit headers state
that `webkit_web_view_call_async_javascript_function` is the API that properly
passes a returned Promise result to the completion callback. Plain
`webkit_web_view_evaluate_javascript` is not sufficient for this command.

Owners: cc_1 and cc_2. The proposed `PagePort.evalJson` contract now explicitly
requires the async-function API.

Status: **CLOSED by `274928b`**. WebKitGTK uses
`webkit_web_view_call_async_javascript_function`, and the live Promise test is
green in the `e0a101f`/`5712919` gate.

### BLOCKER — socket-driven E2E must traverse the production chain

The historical M12 wording prioritizes page-initiated `zbHost`, but this task's
priority is socket to page. At least one GTK E2E must send a framed request to
the real server and assert a live DOM side effect or page-derived typed result.
It must fail if the old template response returns or if a fake port bypasses the
native chain.

Owner: cc_2 / BlueBeaver. Mailed 2026-10-10.

Status: **CLOSED by `afe0498`**. The real binary is driven over a persistent external UDS
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

Status: **CLOSED by `0fc312a`**. It closes the minimum-250-ms extension and all reported ordinary
retry overruns. A zero-timeout command still begins one 1-ms native attempt at
the already-reached deadline; this residual is tracked as SHOULD.

### BLOCKER — delayed typing must obey the deadline and handle empty text

`typeWithDelay` sleeps the raw accepted `u64 delay_ms`, which can exceed the
command deadline by an arbitrary amount and can overflow the real clock's
integer conversion. With empty text it performs no selector/actionability check
and returns success. Delay sleeps must be bounded by remaining time, and empty
text must preserve the same target-validation semantics as the undelayed path.

Owner: cc_2 / BlueBeaver. Mailed 2026-10-10.

Status: **CLOSED by `0fc312a`**. It closes the overflow, over-deadline sleep, and empty-text
bypass. A separate M8 blocker remains: queue shutdown cannot interrupt a legal
long inter-character sleep once it has started.

### BLOCKER — invalid JSON-RPC IDs must not execute commands

Commit `f6a9d05` converts object, array, and boolean IDs to JSON `null`, then
continues through the router and engine. Those are invalid JSON-RPC request IDs;
the server must return `-32600` and avoid executing side effects. A missing ID
(notification) is a separate case and ultimately requires no response.

Owner: cc_2 / BlueBeaver. Mailed 2026-10-10.

Still present in `4644087` at `src/automation_server.zig:253,331-340`.

Status: **CLOSED by `1441fd3`**. It rejects the invalid ID before router/queue/engine and
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

Status: **CLOSED by `e0a101f`** for the primary socket path. The shim publishes readiness
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

Status: **CLOSED by `f1daa1f`**. Queue wait is subtracted from every operation budget and an
exhausted budget fails without touching PagePort.

### BLOCKER — shutdown must interrupt delayed typing waits

`4644087` checks cancellation before each PagePort attempt, but
`typeWithDelay` performs the entire accepted `delay_ms` in one sleep. A delay
just below the maximum command timeout can therefore make `server.stop()` wait
for hours or days. The inter-character wait needs bounded cancellation/deadline
checks, with a test that cancels during a long delay.

Owner: cc_2 / BlueBeaver. Mailed 2026-10-10.

Status: **CLOSED by `1441fd3`**. Long delays sleep in at-most-16-ms slices with cancellation
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

Status: **CLOSED by `5712919`**. `CommandSpanAttrs` structurally contains only a
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

Status: **CLOSED by `a5a28ad` and `7ff7d72`**. These commits close the missing schema keys, duplicate-root
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

Status: **CLOSED by `a5a28ad` and `7ff7d72`**. URL authority normalization
landed in `a5a28ad`; bounded selector kinds landed in `7ff7d72`.

### BLOCKER — native test must not mutate process-global environment in-process

The in-progress early-`zb_app_run` failure test calls raw libc `unsetenv` and
`setenv`. Two independent full-gate runs then hung. GDB showed the live-driver
thread in `std.debug.print` after a panic/deadlock in Zig's environment scan,
while the main thread remained in `gtk_main`. Exercise the no-DISPLAY path in an
isolated subprocess so the test runner's cached environment cannot be
invalidated.

Owner: cc_1 / BlackRobin. Mailed 2026-10-10 with GDB evidence.

Status: **CLOSED by `e0a101f`**. The test replaces the existing `DISPLAY` value rather than
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

Status: **CLOSED by `e0a101f`**. Abandonment runs on GTK, checks window load generation and
displacement, stops only the owned load, untracks it, and the stalled-load live
case leaves zero jobs before the next navigation.

### BLOCKER — the fixed application load timer overrides command deadlines

Every `WEBKIT_LOAD_STARTED` calls `window_reset_load_state`, which installs the
legacy 15-second timeout. An automation `page.navigate` or `page.reload` with a
larger accepted timeout can therefore be terminated early and reported as a
navigation failure rather than `navigation_timeout`. The browser-level timer
and PagePort command deadline need one authoritative policy.

Owner: cc_1 / BlackRobin. Mailed 2026-10-10.

Status: **CLOSED by `e0a101f`**. Automation-owned loads remove the legacy timer and use the
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

Status: **CLOSED by `8cfd802` and `1eff576`**. The production waiter selects the
explicit live window in a mutex-protected snapshot and waits for that window's
first-load flag. The live regression holds a child subresource, proves eval was
issued while that child was still loading, then requires both the real child
title and an isolated-world `getText` result.

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
