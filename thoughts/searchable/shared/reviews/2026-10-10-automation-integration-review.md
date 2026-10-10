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

Status: **OPEN for implementation (cc_1 / BlackRobin and cc_2 / BlueBeaver)**.
The policy dispute is CLOSED by the orchestrator decision, but the code/evidence
is not present yet. `nativeMove(...)->void` alone also gives an engine-owned
path generator no way to read cc_1's authoritative cache; PagePort needs an
agreed cached-position read seam (or an equivalent concrete contract) rather
than a duplicate engine cache. The native evidence must prove stale/held
guards send no move, and the E2E must cover the five fixed rules. Mailed as
4611, 4612, 4618, and 4620.

Commit `2f0e179` remains blocked. Its process-global coordinate crosses window
identity when the old primary closes, and its live test permits a navigating
Enter to return success then waits for navigation before trying the suffix,
bypassing the production per-character race. Mailed as 4624, 4625, and 4629.

The follow-up working diff moves the cache into `ZbWindow`, adds a
primary-replacement regression, and restores the strict no-suffix oracle, but
has two new blockers. It dereferences `win` to record the pointer after
`gtk_main_do_event` has run arbitrary page handlers that may close the window;
revalidate against the mutex-protected published snapshot first. Its new
Navigation API latch is permanent even when the page cancels or the navigation
fails, making every future native text command in the unchanged document fail
`document_changed`. Stop the current action conservatively, but clear a failed
navigation without racing a newer one. Mailed as 4630 and 4631.

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

Status: **OPEN (cc_2 / BlueBeaver)**. Either make the production no-backend
chain return the documented stable reason or revise the public contract, then
assert the full error data. Mailed as 4622. This is queued after the three
orchestrator-priority fixes.

The working diff now fails native verbs before page work with
`session_invalid` / `unsupported` and checks click, type, and press through the
real socket/server/engine chain. Status remains OPEN until commit and exact
gate evidence.

### BLOCKER — N12 cross-symbol check can pass with no symbols examined

`tools/check_cross_symbols.py` regards an empty parsed undefined-symbol set as
success. A parser/layout/reachability regression can therefore print
`needs []` for every object and leave the platform gate green without checking
any shim definition.

Status: **OPEN (cc_2 / BlueBeaver)**. Require a known core-symbol baseline per
target and prove COFF and Mach-O missing-symbol detection fails under a
mutation or parser fixture. Mailed as 4627.

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
