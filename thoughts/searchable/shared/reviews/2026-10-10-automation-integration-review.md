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
| `2a4e6ee` — N19 native screenshots | Exact C/Zig async-state, ownership, deadline, size-limit and live-test review | **CODE BLOCKED; integrated gate pending**. | C/Zig byte ownership, async refs, cancellation, window teardown and TooLarge transfer are balanced. BLOCKER: once the snapshot callback starts, synchronous Cairo encoding blocks GTK without observing abandonment/deadline, so a timed-out call can leave the browser main thread doing unbounded abandoned work; the 1 ms test does not hold the writer across expiry. SHOULD: overflow-safe/first-chunk TooLarge classification and a raw-pixel bound for full-page surfaces. NIT: remove the test's `zb-shot-*` directory. Public PagePort/router/socket evidence remains pending. Mailed cc_1 as 4746. |
| `ee19e40` — PagePort v3.3/v3.4 and N17/N18/N19 engine/routes | Exact PagePort/router/engine/SDK/fake/live-test diff review | **CODE BLOCKED; native integration pending**. | BLOCKER: after a selector wheel succeeds, the next `measure` can come from a replacement document and be accepted as success or drive another wheel; preserve/compare the dispatched document token and return `document_changed`. SHOULD: screenshot base64/JSON allocation and encoding sit outside the PagePort deadline. Parser ownership, file-path isolation, terminal port-error mapping, native hover and synthetic socket evidence otherwise look coherent. Mailed cc_2 as 4749. |
| `314a14e` — N20 platform rate-limit signals | Exact automation.js and live-WebKit test review | **CODE BLOCKED; flow integration pending**. | BLOCKER: signal `text_hash` is the existing 32-bit FNV-1a, not the Phase-4 contract's SHA-256; the test checks only that a hash-shaped field exists. SHOULD: hidden Arkose/authwall nodes are treated as user-visible blocking signals. Platform scoping, hidden-toast handling, raw-text omission and real isolated-world injection are otherwise covered. Mailed cc_1 as 4750. |
| `c750b87` — GTK PagePort v3.3/v3.4 wiring and measure op | Exact adapter/script/live-WebKit diff and cross-seam review | **CODE BLOCKED; public E2E pending**. | Vtable completeness, C-string ownership, file error mapping and the non-scrolling measure op are correct. BLOCKER: post-wheel `.document_changed` or `.leaving` from the acknowledgement is ignored, then offsets are read from the replacement document; offset-form scroll returns those as success. The seam needs distinct after-dispatch provenance. Mailed cc_1 as 4756. |
| `6f12c70` — scroll document continuity and screenshot deadline | Exact engine/fake/test/docs diff | **APPROVED engine follow-up**. | Closes 4749: after one selector wheel, either in-view or out-of-view measure from doc B yields `-32001 document_changed` and no second wheel. Capture arriving at/past the screenshot deadline is now `screenshot_deadline`; base64 is explicitly defined as size-bounded after capture. The GTK after-dispatch seam issue in c750b87 remains separate. Mailed approval in 4755. |
| `9534f61` — one real-binary PagePort v3.3/v3.4 E2E | Exact Python SDK/error mapping, fixture, PNG oracle and build wiring review | **APPROVED for stated scope: author gate 83/83 steps, 607/607 tests**. | The real binary is driven through the Python SDK. The test independently decodes PNG chunks/CRCs/filters and checks dimensions/pixels; observes trusted file changes with exact names/sizes and pre-click `bad_file`; and checks trusted wheels plus immediate offsets. Temporary profile/uploads are cleaned. Separate open items: after-wheel document provenance and CSS-based native hover. Mailed approval as 4758. |
| `f11596b` — N20 flow-side platform-signal integration | Exact runner/routes/unit/server/live-fixture/docs diff review | **CODE BLOCKED; author reports 83/83 steps, 615/615 tests**. | The scan schedule, signal allowlisting/redaction, terminal `-32010`, cap release/no-count behavior, and real X/LinkedIn/Instagram socket oracles match the N20 contract. BLOCKER: a required pre-action or final scan may consume the remaining absolute flow budget, but the runner then starts an action with its pre-scan timeout or reports success when the final scan has zero time. The fake scan path consumes no fake-clock time, masking the regression. Mailed cc_2 as 4762. |
| `eb49169` — N20 absolute-deadline and cancellation follow-up | Exact runner/fake/test diff and shared-worktree gate | **DEADLINE APPROVED; cancellation CODE BLOCKED. Author reports 83/83 steps, 620/620 tests**. | Scan latency now consumes the fake clock, the action budget is rechecked and both timeout locations are lowered, and a final scan that spends the budget prevents success/counting. BLOCKER: a non-cancelled failed child's reclassification scan still has no post-scan cancellation check, despite the commit's “after every scan” claim; the new cancellation tests do not cover that branch. Mailed cc_2 as 4772. |
| `4f9c341` — failed-step scan cancellation follow-up | Exact runner/test diff review | **APPROVED: author gate 83/83 steps, 622/622 tests**. | The failed-step reclassification branch performs the missing post-scan cancellation check and returns `-32012` without later work. The regression uses the final failed child so no later step can mask the error and pins exact scan/eval counts; a separate test explicitly gives a detected signal precedence when it races cancellation. Closes 4766/4769/4772. Mailed approval as 4778. |
| `e6cb03e` — terminal after-dispatch document provenance and native CSS-hover oracle | Exact PagePort/engine/fake/socket-E2E diff review | **APPROVED engine/evidence slice: author gate 83/83 steps, 616/616 tests; adapter half pending**. | `DocumentReplaced` precisely means input was dispatched and the page was then replaced; the engine maps it terminally to `-32001` with no relocate/retry. The real socket oracle proves synthetic hover does not establish CSS `:hover`, while plain and humanized native hover do so with trusted moves and clear again after moving away. Mailed approval as 4764. |
| `569e47a` — nativeScroll after-dispatch `DocumentReplaced` adapter half | Exact adapter/ACK/debt/unit/live-WebKit diff review | **CODE BLOCKED; author gate 83/83 steps, 617/617 tests**. | ACK and settle reads now reject a replacement/leaving document and the final read rejects a changed token; the engine seam remains terminal. BLOCKER: the final offsets result carries only the document token, dropping same-document `navigations`/`leaving` provenance. A navigation beginning in the settle-to-offset gap can therefore return old-page offsets as success. Mailed cc_1 as 4776. |
| `85797af` — screenshot encoding/cap and N20 signal follow-up | Exact C async-state/deadline/size review plus JS SHA-256 and live-oracle review | **CODE BLOCKED; author reports 83/83 steps, 607/607 tests**. | SHA-256 matches an independent Zig digest, hidden Arkose/authwall nodes are ignored, byte-limit accounting is overflow-safe, ownership is balanced, and temporary directories are removed. BLOCKER: the PNG sink observes only whether the waiter has marked the job abandoned, not the absolute deadline; `auto_job_wait` can accept `DONE` after expiry if completion wins the mutex/scheduling race. SHOULD: the full-page measurement and snapshot are separate async operations, so dynamic layout growth can evade the claimed raw-pixel cap. Mailed cc_1 as 4768. |
| Clean export of `f11596b` | `D=$(mktemp -d); trap 'find "$D" -delete' EXIT; git archive f11596b \| tar -x -C "$D"; cd "$D"; timeout 900 xvfb-run -a zig build test --summary all` | **GREEN: 83/83 steps, 615/615 tests**. | All production-chain E2Es at that commit passed. The throwaway export was deleted immediately after the gate. This evidence predates `e6cb03e` and `85797af` and does not close their source-review findings. |
| Shared WIP after `85797af`, pre-log-commit gate | `timeout 900 xvfb-run -a zig build test --summary all` in the worktree | **RED: 80/83 steps; 530/530 executed tests passed; one compile error**. | Every live E2E reached by the gate passed. Root-test compilation failed at untracked cc_2 WIP `src/automation/pacing_store.zig:118`: unqualified `save` is ambiguous between `Persister.save` and the module-level function. Mailed cc_2 as 4770. This is not a committed-HEAD regression. |
| `4dafb3a` — N21 pacing store and server integration | Exact store/state/server/unit diff review plus `timeout 240 zig build cross-check --summary all` | **CORE APPROVED; PRODUCTION BLOCKED; cross-check GREEN 10/10; author gate 83/83, 629/629**. | The strict schema, atomic 0600 replacement, file and parent-directory sync, same-day restore, rollover reset, serialized hooks outside state locks, owned config lifetime, value-free logs, corrupt fallback, and unit/server evidence are sound. BLOCKER: `src/app.zig:104-118` never sets `Config.pacing_state_path`; the real binary therefore remains memory-only and the real-binary E2E is still untracked/unwired. Mailed cc_2 as 4773 and exact review 4784; cc_2 routed the owned `app.zig` hunk to cc_1 in 4781. |
| Clean export of `4dafb3a` | `git archive 4dafb3a` into one trapped `/tmp/gate-cod1-*`; `timeout 900 xvfb-run -a zig build test --summary all` | **GREEN: 83/83 steps, 629/629 tests**. | Independently confirms the exact N21 core commit and all production-chain suites then present. The export, including its cache, was deleted by `find -delete` immediately on exit; no cod_1 gate tree remains. |
| `4497fbd` — exact-once X post admission | Exact X state/route/persistence-test diff review | **CODE APPROVED; N23 EVIDENCE OPEN; author gate 83/83, 631/631**. | `reserve` includes in-flight posts atomically; route validation precedes admission; success commits and persists; every error/cancellation releases; reservation completion is idempotent and hooks run outside the lock. The direct held-reservation test proves state plus one route, but not two window-targeted route queues. The required cap=1 A-held/B-refused production-chain oracle remains a BLOCKER-for-N23 evidence. Mailed as 4785; author agrees it remains open. |
| `878d789` + `c8c0d6c` + `875ff2b` — N22 handoff update and qualification follow-ups | Exact documentation diff review | **APPROVED by the two follow-up commits**. | `878d789` initially stated intended pacing, native-scroll, screenshot-deadline and 32 MiP guarantees as current behavior while their production blockers remained open. `c8c0d6c` qualifies pacing as built-but-unwired and scroll/deadline behavior as pending; `875ff2b` describes 32 MiP as a best-effort preflight because the document can grow before capture. The handoff now distinguishes shipped behavior from open work. Mailed cc_2 as 4790/4794 and approval 4799. |
| Clean export of `878d789` | `git archive 878d789` into one trapped `/tmp/gate-cod1-*`; `timeout 900 xvfb-run -a zig build test --summary all` | **GREEN: 83/83 steps, 631/631 tests**. | Independently covers `4497fbd` and the original N22 handoff commit. The later two commits are documentation-only. The export and its cache were deleted by `find -delete` immediately after the gate; no cod_1 gate tree remains. |
| `2a31ffd` — atomic final native-scroll provenance | Exact adapter/unit diff review | **CODE APPROVED; TEST BLOCKED**. | The final offsets eval atomically returns document token, navigation count and leaving state, and production rejects drift in any one. BLOCKER-for-tests: the only new case sets both count drift and leaving, so deleting either predicate survives. Requested independent navigation-only and leaving-only cases in a follow-up commit; mailed cc_1 as 4802. |
| `baf151f` — screenshot absolute deadline and post-capture cap | Exact C/Zig async/deadline/ownership diff plus clean-export gate | **GREEN 83/83 steps, 631/631 tests; CODE BLOCKED**. | The sink independently enforces the absolute deadline; async refs and the awaited growth hook are balanced; the post-capture cap honestly narrows the raw-allocation contract. BLOCKER: the snapshot callback classifies NULL-surface and oversized-surface results before testing expiry, and the final caller comparison is `>` rather than contract-correct `>=`. The slow-encoder oracle cannot see either branch. NIT: remove committed growth debug output. Mailed cc_1 as 4802. The trapped clean export was deleted immediately; `/tmp` returned to 21% used. |
| `b5fab82` — screenshot deadline-first and split scroll-provenance regressions | Exact C/Zig async/ownership and test-sensitivity diff plus a clean-export full gate | **APPROVED; GREEN 84/84 steps, 632/632 tests**. | The snapshot callback makes `>= deadline` its first post-finish classification and balances both surface/error ownership paths; the final caller boundary is also `>=`. The late-waiter/grown-document oracle distinguishes Timeout from TooLarge. Navigation-count and leaving drift now have independent regressions. This closes both 4802 blockers and removes the debug-output NIT. Mailed as 4821/4822. The trapped export and cache were deleted immediately; `/tmp` returned to 19% used. |
| `bf0d76b` — N21 effective-profile app wiring | Exact `src/app.zig` diff; author gate 83/83, 632/632; cc_2 separately ran the pending real-binary E2E 5/5 | **CODE APPROVED; E2E COMMIT PENDING**. | `applyProfileDir` returns only the profile accepted by the GTK setter; fallback/no-profile stays null. The server config uses `<effective profile>/automation-pacing.json`, with arena lifetime and correct trailing-slash joining. This closes the production-code half of 4773. The restart, second-profile isolation, 0600 and corrupt/value-free-log E2E already passes but is still uncommitted/unwired. Mailed approval as 4805. |
| `1ca9ac5` + `07bf6b5` — N21 real-binary pacing restart E2E and cleanup follow-up | Exact test/build/docs diffs plus a clean-export build and direct bounded Xvfb execution | **APPROVED; direct E2E GREEN 5/5; N21 CLOSED**. | The real CLI/server, Python SDK/socket, routed LinkedIn actions and effective profile are exercised without bypassing production. Same-profile restart restores 98 remaining, a second profile starts 100/100, the file is 0600, and corrupt content falls back without entering stderr. The clean export and cache were deleted immediately (`/tmp` 22% used). `07bf6b5` closes 4808 by stopping the launched process and closing stderr if the socket wait fails. Mailed approval as 4810/4816. |
| Shared N23 WIP after the stable-id C/adapter seam was connected | `timeout 900 xvfb-run -a zig build test --summary all` in the worktree | **GREEN 84/84 steps, 636/636 tests**. | All existing production-chain E2Es and the expanded server/engine/queue/adapter unit suites passed. This is an in-progress shared-tree gate, not commit evidence: the dedicated live popup/target-matrix E2E and its build wiring were not yet present, and cc_1's tracker-lifetime SHOULD 4824 remains open. |
| Shared N23/native-fix WIP before this review checkpoint | `timeout 900 xvfb-run -a zig build test --summary all` in the worktree | **RED: 81/83 steps, 634/635 tests**. | The sole failure is the deliberately fail-closed adapter completeness test: `PagePort.listWindows is not implemented by the GTK adapter`. All reached production E2Es passed, including core, SDK, profile, social, X, readiness, lifecycle, scroll, native ports and cookies. This is expected while cc_1's N23 registry/adapter half is absent, not a committed-HEAD regression. |
| Shared N23 WIP with the stable-id GTK adapter and real socket popup test | Exact in-progress diff review; bounded shared-worktree Xvfb gate | **GREEN 85/85 steps, 639/639 tests; CODE/EVIDENCE PARTIAL; commit pending**. | Stable u32 ids, GTK-only pointer resolution, primary id 1, target-specific readiness, primary-first owned list JSON, exact-id close, all PagePort target propagation, id-exhaustion refusal, refused-child release and an in-flight work-counter barrier are present. The production binary/socket probe passes popup listing/opener identity, targeted title/fill/click/eval isolation, postMessage to the opener, primary-close refusal, popup close and later `no_window`, then stops without pinning the deferred broken-opener state. `page.list`/`page.close` use instrumented `External` wrappers; their sink regression checks three parented children, operation order, standard error mapping and absence of URL/title content. Queue OOM after a newly-created line now drops the empty line, with a failing-allocator regression that kills the mutant (closes 4840). Still open before commit: a per-id ACK/debt isolation oracle that kills a shared-tracker mutant (4830), a retained resolver for the pending close-race Promise (4833), and preservation of OOM while parsing the GTK list JSON (4837/4838). SHOULD: generation reset prevents cross-run debt, but UI close and expired post-close lock still retain tracker entries for the rest of a run. |
| `3528d84` — joint N23 window targeting | Exact 22-file diff review, byte-for-byte comparison with the authors' clean gated snapshot, then reviewer `timeout 900 xvfb-run -a zig build test --summary all` on exact HEAD | **BLOCKED despite GREEN 85/85 steps, 641/641 tests.** | Stable ids, targeting, per-window queues, per-id native state, close cancellation, standard error/telemetry mapping, SDKs and popup login/postMessage all pass. The final tests close the popup and stop after `no_window`; they do not assert that the related opener remains usable. A real binary/SDK probe shows that `on_window_destroy` terminates the shared web process: the opener's URL/title become empty, eval fails, reload times out, and state is lost. Closing a related popup therefore defeats the OAuth use case. Orchestrator reversed the earlier deferral; this is now a BLOCKER. Mailed cc_1/cc_2 as 4848. |
| `96571ce` — N23 handoff update | Exact documentation diff | **FOLLOW-UP REQUIRED.** | The N21, screenshot and scroll updates are accurate, but its N23 workaround/deferred-language became obsolete when the orchestrator reversed the deferral. After the native fix lands, cc_2 must remove the claims that closing a popup unloads the opener and that navigating it again is the supported recovery. |
| `1088651` — shared-process-safe popup close | Exact six-file diff review; author clean-snapshot gate and two reported mutants | **CODE APPROVED; TEST FOLLOW-UP REQUIRED. Author gate GREEN 85/85 steps, 641/641 tests.** | Related views inherit one GTK-thread-only process-group id; destroy terminates only the last live member, while single-window timeout and app teardown retain termination. The WebKit `close` signal destroys only a script-opened popup and is disconnected before `ZbWindow` free. Both client `page.close` and fixture-owned `window.close()` traverse the production chain and kill always-terminate/no-close-handler mutants. The committed E2E captured its first URL baseline after close, did not pin the requested exact Alice state, and could race the second postMessage against self-close. Mailed required follow-up as 4852/4853/4855. |
| `e76679a` — popup-close docs/handoff | Exact two-file documentation diff; clean-HEAD gate is separate baseline evidence | **APPROVED subject to removal of one transient review note.** | Correctly removes the obsolete navigate workaround and deferred item, documents both close paths, and cites `1088651`. Its evidence row openly says the exact oracle is still being tightened; replace that transient RoseCat-mail note with the test follow-up SHA when it lands. Mailed as 4856. |
| `d689f72` — exact popup-close oracles and uncapped tracker sweep | Exact three-file diff review; reviewer `timeout 900 xvfb-run -a zig build test --summary all` with pre/post author-file hashes; author full gate | **POPUP-CLOSE APPROVED / BLOCKER CLOSED; GREEN 85/85 steps, 641/641 tests. TRACKER TEST BLOCKER OPEN.** | The socket E2E captures the opener URL before either close and requires exact equality after both; resets the opener to a sentinel; waits for the second postMessage; requires `got:user=alice`; and checks the self-closed id is `-32011 no_window`. The production chain passes and the three author-file hashes stayed unchanged. Separate BLOCKER-for-TDD: the same commit replaces the eight-entry tracker cleanup batch with a complete sweep, but no >8 oracle kills restoration of the old cap; add that test or revert the sweep in a no-amend follow-up. Mailed as 4859/4863/4868. |
| `92ea230` — final N23 handoff evidence update | Exact one-file documentation diff | **DOCS APPROVED; FINAL GATE RED.** | The handoff correctly cites `d689f72` for both exact popup-close opener oracles and assigns the remaining tracker-sweep test to cc_1. BlueBeaver's independent clean export passed 85/85 steps and 641/641 tests, but the orchestrator's clean gate at the same HEAD timed out in `native text: a navigation blocked by policy does not refuse later typing` and ended 640/641. The latter reopens final/N23 gate acceptance until cc_1 fixes the hang and a clean full gate passes. |
| `7059814` — gone-tracker >8 oracle | Exact committed adapter-test diff; owner clean export and restoration mutant | **APPROVED; TRACKER TEST BLOCKER CLOSED. Owner gate GREEN 85/85 steps, 642/642 tests; mutant RED.** | The test creates ids 1..16 while all are live, makes only id 1 live, and requires one lookup to leave exactly id 1. Restoring the old eight-removal cap leaves stale entries and fails. This closes 4859/4865/4868, but does not supersede the independent policy-blocked-navigation hang. Mailed as 4870/4873. |
| Shared worktree after `4dafb3a`, pre-log-commit gate | `timeout 900 xvfb-run -a zig build test --summary all` | **RED: 81/83 steps, 628/629 tests; committed N21 tests passed**. | The only failed test was uncommitted cc_1 screenshot WIP: `webkit.test.screenshot returns a PNG...` failed its late-encoder counter and both dynamic-growth assertions. The after-measure test hook starts an asynchronous JS evaluation and immediately starts the snapshot, so the capture can beat the growth. All reached socket E2Es passed. Mailed cc_1 as 4783. This is not an N21 or committed-HEAD regression. |
| Shared N17–N20 WIP before mutation checkpoint | Bounded `timeout 900 xvfb-run -a zig build test --summary all` | **RED: 81/83 steps, 612/613 tests**. | Every real-binary E2E passed, including the new native screenshot/file/scroll and platform-signal cases. The sole failure is `automation_server_test.zig:1056`: the routed x.post oracle expects 8 evals, while the new N20 scans make 14. Mailed cc_2 as 4752; this is owner WIP, not a committed-HEAD regression. |

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
| 9 | Native no-dispatch-after-abandonment: force the document-guard commit decision true even after the waiter changed the job from RUNNING to ABANDONED. | Root native live-WebKit unit — failed: the page saw the late trusted click and move at `(30,30)`, and the pointer cache changed; 86/87 tests passed. | `automation_input_test.py` — passed. | **KILLED** by the focused native live unit. The public E2E does not exercise the held-guard deadline race. |
| 10 | Humanize budget preflight: delete the whole-path fit check for a humanized click. | `automation_engine_test` — failed: the tight-budget click reached dispatch logic and returned `deadline_before_input` instead of pre-dispatch `humanize_budget`; 77/78 tests passed. | `automation_input_test.py` — passed. | **KILLED** by the focused engine unit. The public E2E exercises humanized input but no tight-budget/no-dispatch case. |
| 11 | Cookie telemetry redaction: copy the raw cookie value into the owned telemetry `name_hash` buffer instead of hashing the cookie name. | `automation_cookie_test` — failed its rejecting-sink assertion with `raw value crossed the sink: s3cret-v4lue`; 26/27 tests passed. | `automation_cookies_test.py` — passed. | **KILLED** by the focused telemetry unit. The real-binary E2E checks process output, not the TelemetrySink boundary. |
| 12 | Strict Netscape import parsing: disable the check that the include-subdomains flag agrees with the domain's leading dot. | `automation_cookie_test` — failed the dedicated scope check: `imported:4, skipped:0` instead of `imported:2, skipped:2`; 26/27 tests passed. | `automation_cookies_test.py` — passed. | **KILLED** by the focused parser unit. The live E2E imports only well-formed lines. |
| 13 | X logged-out gate: disable the login-link branch that converts a missing composer into `error.LoggedOut`. | `automation_x_test` — failed: expected `-32011`, got `-32001`; 17/18 tests passed. | `x_flows_test.py` — failed the same public contract after driving the real binary: expected `-32011 logged_out`, got `-32001`. | **KILLED** by both layers. |
| 14 | Social RateLimiter daily cap: disable `SocialState.reserve`'s admission check against limiter remaining capacity and in-flight reservations. | `automation_social_test` — the cap/no-page-work and two-page tests received success instead of `-32010`, and the 8-thread cap=1 race admitted all 8 instead of exactly 1; 27/30 tests passed (two expected-error assertions trapped on success). | `social_flows_test.py` — failed `daily cap: no error`; the forbidden Instagram request reached the fixture. | **KILLED** by both layers. |
| 15 | `dom.setInputFiles` regular-file guard: remove `G_FILE_TEST_IS_REGULAR` while retaining absolute-path/readability checks. | Root live-WebKit unit — failed `a directory is refused` plus its no-side-effect checks; 89/90 tests passed. | `automation_native_ports_test.py` — passed all six scenarios because its `bad_file` case supplies only a missing path. | **KILLED** by the focused native unit. The public socket E2E does not independently reject a readable directory. |

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

Status: **CLOSED by `9ab165f` + `ee19e40` + `e6cb03e`.** `9ab165f`
explicitly defines synthetic hover as event-only and makes the native primitive
a real pointer move. `ee19e40` routes that primitive through PagePort/engine,
and `e6cb03e` drives the real socket and proves synthetic hover does not
establish CSS `:hover` while plain and humanized native hover do, with trusted
moves, then clear after moving away. Mailed as 4738/4749/4764.

### BLOCKER — N18 wheel acknowledgement is not scroll completion

The in-progress GTK port returns when the page acknowledges the trusted wheel
event, but its own native test then polls for up to three seconds outside the
method because smooth scrolling continues. A socket command built directly on
that port can return while the offset is still moving, racing the next command.
The PagePort/engine must verify a stable final offset under the same deadline,
or the public API must be defined as one wheel dispatch rather than completed
scrolling. The socket E2E must read the offset immediately after the response.

Status: **CLOSED by `c750b87` and `9534f61` for scroll completion**.
`9ab165f` closes the native completion defect: the
method waits for acknowledgement and then 100 ms quiet, or 250 ms with no
scroll, under the same deadline. Its live WebKit test reads exact outer and
inner offsets immediately after return, and a direct stale-token call proves
no wheel dispatch. `c750b87` wires the settled `ScrollOffsets` through the GTK
PagePort, and `9534f61` drives both offset and selector forms over the external
socket, requires trusted wheels, and compares the returned offsets with an
immediate page read. The separate post-dispatch document-replacement defect is
tracked below.

### BLOCKER — N18 selector scrolling accepts a replacement document after dispatch

`ee19e40` binds each wheel to the document returned by that iteration's
`measure`, but after a successful wheel it discards that token. The next
`measure` is allowed to come from another document; if that replacement has
the same selector, the engine can report success or dispatch another wheel
there. This violates the agreed rule that a document change after any wheel is
terminal and no replacement target is acted upon.

Status: **CLOSED by `6f12c70` (engine side)**. The first successfully
dispatched document token is preserved and every later measure is compared
before success or dispatch. Regressions cover doc A/out-of-view followed by
doc B both in view and out of view; each requires one wheel and
`-32001 document_changed`. The adapter's loss of after-dispatch provenance
is tracked separately below. Mailed approval in 4755.

### BLOCKER — N18 adapter returns replacement offsets after a dispatched wheel

`c750b87` asks the acknowledgement tracker whether a wheel was acknowledged,
the document changed, or navigation began. Only the acknowledged case is
handled; the other two still call `readScrollOffsets`, which evaluates the
current (replacement) document. Offset-form `dom.scroll` immediately returns
those offsets as success, and selector-form performs an unnecessary read of
the replacement before the engine's later token check.

Status: **CLOSED by `2a31ffd` + `b5fab82`**. `e6cb03e` defines and tests the
terminal engine-side `DocumentReplaced` seam. `569e47a` returns it when the
first ACK, the settle wait, or the final offsets read sees a changed document
token. `2a31ffd` adds navigation-count and leaving provenance to the atomic
final offsets read and rejects either drift. `b5fab82` makes those two
predicates independently mutation-sensitive with navigation-only and
leaving-only cases. Mailed as 4756, 4776, 4786, 4802 and 4821.

### BLOCKER — screenshot encoding observes abandonment, not its absolute deadline

`85797af` checks `job->state == ZB_JOB_RUNNING` at each Cairo PNG sink chunk.
That bounds work after the waiter has changed the state to `ABANDONED`, but it
does not itself observe the operation's deadline. `auto_job_wait` checks
`DONE` before time and may accept a completion signalled after expiry if the
encoder finishes before the awakened waiter reacquires the mutex. The slow
writer oracle exercises only the favorable schedule where the waiter runs
between chunks.

Status: **CLOSED by `baf151f` + `b5fab82`**. `baf151f` makes the PNG sink reject
at/after the absolute deadline independent of waiter scheduling. `b5fab82`
checks expiry immediately after snapshot finish, before NULL-surface,
post-capture-size or encoder classification, and uses `>=` again at the final
caller boundary. Its late-waiter/grown-document oracle proves Timeout wins
over TooLarge; removing the deadline-first check makes the test fail. Mailed
as 4768, 4780, 4802 and 4821; independent clean-export gate at `b5fab82` was
green 84/84 steps and 632/632 tests.

### SHOULD — full-page screenshot pixel cap has a measure/snapshot race

`85797af` measures the document in the automation world and then starts a
separate asynchronous full-document snapshot. Timer-driven layout or a
navigation can enlarge the document between those operations, so the raw
surface WebKit materializes is not strictly bounded by the measured 32 Mi
pixels. The static 50,000-pixel-height oracle proves refusal of an already
large document but cannot detect this race.

Status: **CLOSED by `baf151f` and `875ff2b`**. The awaited dynamic-growth
oracle proves an oversized captured surface is refused before encoding, while
the shim and handoff explicitly state that WebKit owns the intervening raw
allocation. This is an honest best-effort preflight/postflight contract rather
than a strict raw-allocation cap.

### BLOCKER — N21 pacing persistence is not connected to the effective profile

The N21 core adds `Config.pacing_state_path`, loads it at server start, and
saves strict, value-free snapshots after counted actions and pacing changes.
However, the production `buildAutomationConfig` initializer at
`src/app.zig:104-118` leaves the new field at its empty default. Consequently
the real `--automation-api` binary never initializes the persister even when
`--profile-dir` or the default profile is active; unit tests inject the path
directly and bypass this missing edge.

Status: **CLOSED by `bf0d76b` + `1ca9ac5`**. `bf0d76b` retains the directory
actually accepted by `applyProfileDir` and passes
`<effective profile>/automation-pacing.json` into the server, leaving memory-
only state when no profile resolves. `1ca9ac5` wires a real-binary E2E covering
same-profile restart, 0600, second-profile isolation and corrupt/value-free
fallback. Independent direct clean-export execution passed all five reported
steps. Mailed as 4773, 4805 and 4810.

### BLOCKER — N20 signal text hashing does not meet the SHA-256 contract

`314a14e` sends only `text_hash`, but `hashText` is 32-bit FNV-1a. The
Phase-4 rate-limit contract explicitly requires SHA-256. The current small
hash is collision-prone and readily reversible for predictable platform modal
strings, so the value is not a sufficient telemetry redaction boundary.

Status: **CLOSED by `85797af`**. `automation.js` now hashes the UTF-8 bytes with
SHA-256 and emits 64 lowercase hex; the live WebKit test independently computes
the exact fixture digest with Zig's SHA-256. Hidden Arkose/authwall nodes also
require visibility. Raw text is neither returned by the scan nor forwarded by
the runner. Mailed as 4750 and reviewed in 4768.

### BLOCKER — N20 scans can outlive the absolute flow deadline

`f11596b` checks the flow deadline before a pre-action scan, but the action's
parameters already contain the timeout computed from that pre-scan remainder.
A clean or fail-open scan can consume the whole remainder; the runner then
starts the action with the stale timeout. At the end, `scanClean` treats zero
remaining time as success, so `finish` can return and count success without
the required final scan when the last action reaches the deadline.

Status: **CLOSED by `eb49169`**. The fake port now charges scan latency and
honors its supplied timeout. The runner rechecks the one absolute deadline
after a scan, lowers both root and `options.timeout_ms` before dispatching the
following action, and converts a required final scan that spends the budget to
`-32009 <platform>_flow_deadline` without counting success. Regressions cover
both stale action timeout and final-scan exhaustion. Mailed as 4762 and
reviewed in 4772.

### BLOCKER — flow cancellation must remain authoritative around N20 scans

`f11596b` dispatches scans directly through `External.evalJson`. It did not
check cancellation before those calls, and a child step returning cancelled
could be followed by a failed-step reclassification scan. `eb49169` checks the
pre-action, navigation, finish, and directly-cancelled child paths, but its
failed-step branch still does not recheck cancellation after a non-cancelled
failure's scan.

Status: **CLOSED by `4f9c341`**. The failed-step branch now rechecks
cancellation after its reclassification scan and returns `-32012` without a
fallback or later page call. Its regression places the stop in the final
failed child's scan and pins exact work counts; a separate test documents that
a platform signal already found by a racing scan wins as `-32010`. Mailed as
4766, 4769, 4772, and approved in 4778.

### SHOULD — closing one window terminates every related WebKit child process

`on_window_destroy` calls `webkit_web_view_terminate_web_process` before
removing one window. Related views created by `window.open` share that web
process, so closing the primary also kills the child page that becomes the new
primary. The `04fee3a` pointer-identity regression consequently needs its own
`zb_app_run` and proves ownership only before that replacement page is used.

Status: **CLOSED by `1088651` + `d689f72` after the orchestrator reversed the
deferral.** Related windows now share a process-group id and destruction
terminates the web process only for its last live member; the single-window
timeout/teardown behavior remains. The real socket E2E covers both client
`page.close` and popup-owned `window.close()`, then requires the opener's exact
URL and `got:user=alice` DOM state to remain. See the N23 closure section below.

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

### BLOCKER — N23 window targeting must preserve session-wide engine state and stable identity

The first PagePort v3.5 proposal would run a targeted request on a newly
initialized engine. `Engine` owns the session-wide command-id counter and the
injected RNG plus its lock, so per-request engines would duplicate command ids
and allow copied deterministic RNG state to run under independent locks. The
existing native bridge also identifies the default window as current array
index zero and compacts that array on close; after the original primary closes,
an untargeted call can silently fall through to a popup.

Status: **CLOSED by `1088651` + `d689f72`.** The engine,
stable-id registry, default-primary binding, per-window FIFO and empty-line
retirement contracts are **CLOSED by `3528d84`**. N23 deliberately targets
only `page.*`/`dom.*`; site-flow `window_id` support and its two-window X route
oracle remain outside this slice (the proactive global admission fix is
`4497fbd`). The orchestrator reversed the earlier close deferral after a real
binary/SDK reproduction: closing a related popup terminates the process shared
with its opener, losing its DOM state and breaking eval/navigation. N23 now
requires shared-process-aware close behavior before approval. `1088651`
implements it with an explicit related-view process family and a real WebKit
`close` handler; the implementation and both substantive mutants are approved.
`d689f72` adds the exact pre-close URL baseline, requested
`got:user=alice` state, deterministic second-message wait and self-closed
`no_window` assertion; the reviewer full gate is green with unchanged hashes.
Seam review was mailed as 4791/4795; the reopened close BLOCKER and follow-ups
were mailed as 4848/4852/4853/4855/4863.

The four server/queue points mailed as 4798 are **CLOSED by `3528d84`**: the
out-of-deadline `listWindows` probe is gone; targeted
`NoPage` is classified by the first ordinary bounded call; every idle queue
line is removed under its mutex (500 arbitrary ids return to zero); and
primary refusal is a real `-32602 primary_window` outcome before root-span
recording. Re-review mailed as 4806.

The server-fake half of 4812 is **CLOSED by `3528d84`**:
every bounded fake-handle operation now returns `NoPage` when gone, and routed
closed/unknown-window cases cover reload, screenshot, navigate, title,
setInputFiles, native scroll, synthetic eval and native click with zero page,
eval or input work. The GTK adapter half is also present in the current WIP:
every adapter method passes the numeric id from its handle, and the direct live
matrix distinguishes window 2 by URL/title, page-world value, trusted input
log, scroll offsets, screenshot pixels, file change, navigation and pointer
cache while checking that no page work reached window 1. The native registry
carries only a stable never-reused numeric id across threads, resolves it on
GTK, binds the default permanently to id 1, returns an owned atomic
primary-first list snapshot, refuses u32 wrap, releases a refused child view,
and cancels an in-flight eval when its exact window closes. `ReplaceDriver` is
inverted so the child at array index zero is never promoted. BlueBeaver's real
binary/socket probe independently passes popup listing/opener identity,
targeted title/fill/eval isolation, close and subsequent `no_window`. Mailed as
4812/4818/4827; this targeting matrix is committed and green in `3528d84`.

The 4817 ACK/debt drift is **CLOSED by `3528d84`**. ACK trackers are keyed per
stable id, the unit oracle requires distinct tracker/context pointers and debt
isolation, and the direct live matrix performs native work on id 1 after id 2.
BlackRobin's shared-tracker mutant is killed by both tests. The retained
`globalThis.__zbWindowHold` resolver keeps the in-flight Promise genuinely
pending until exact-window close, closing 4833 as well.

**CLOSED by `3528d84` (4824):** tracker lookup probes native window liveness and
evicts gone entries; generation reset protects later runs. Native windows are
hard-capped at 16, so even the fixed eight-entry cleanup batch leaves retention
bounded. NIT: the nearby comment overstates immediate cleanup when more than
eight windows disappear together, but the lifetime/memory safety concern is
closed.

The targeted-command `forWindow` telemetry finding 4819 is **CLOSED by
`3528d84`**. A refused handle is replaced by a complete
NoPage/Unsupported stand-in and the already-parsed command still runs through
`executeWith`; the normal root therefore retains its real namespace and
redacted command facts. The sink regression pins `dom`, `window-2` and
`selector.kind` while the wire remains `-32011 unsupported`. Re-reviewed and
mailed approval as 4826.

The platform-child telemetry finding 4834 is **CLOSED by `3528d84`**.
`External.listWindows` and `External.closeWindow` emit the
same `automation.platform.eval` child shape as the other PagePort calls, and
`handleWindows` uses those wrappers. The sink regression observes one child
for `page.list`, then list-plus-close for `page.close`, requires each child's
parent to be a command root, and rejects representative URL/title content.
It also pins `EvalFailed` as `-32603` and list timeout as `-32009`. The docs now
correctly say only the other `page.*` calls and `dom.*` take an optional id.
Re-reviewed and mailed as 4837; the joint and reviewer gates are green.

**CLOSED by `3528d84` (4835/4837/4838):** GTK `listWindows` distinguishes
`OutOfMemory` from malformed JSON; allocation failure propagates while malformed
native output becomes `EvalFailed`. The server maps the latter to `-32603`, not
`session_invalid`, and preserves timeout/cancellation mappings.

**CLOSED by `1088651` + `d689f72`: popup close preserves its opener.** The
real socket test stops after close plus later `no_window`, so the green gate is
a false negative. The orchestrator's real binary/Python SDK probe proves both
the symptom and its shared-process cause: `on_window_destroy` unconditionally
calls `webkit_web_view_terminate_web_process`, taking down related live views.
`1088651` now terminates only for the last live related view (retaining the sole
hung-window fallback), and wires popup-initiated `window.close()` to the exact
toplevel. Its production-chain E2E covers both paths and kills the old behavior,
and `d689f72` captures URL before either close, requires exact
equality after each, resets and waits for the second Alice postMessage, pins
`got:user=alice`, and requires the self-closed id to answer `-32011 no_window`.
That exact production-chain scenario passes in the reviewer gate. The test
follow-up is approved and committed; the orchestrator's reversed close blocker
is closed.

### BLOCKER-for-tests — uncapped gone-window tracker sweep lacks a >8 oracle

`d689f72` also replaces the adapter's eight-entry cleanup batch with a complete
sweep and strengthens the comment to claim that every gone tracker is removed
on the next lookup. The existing acknowledgement-state test creates only ids 1
and 2. Restoring the old `[8]` batch therefore passes all 641 tests, so the new
behavior was not introduced under the required red/green TDD loop.

Status: **CLOSED by `7059814`.** The follow-up populates ids 1 through 16 under
an all-alive fake, makes only id 1 live, and requires the next lookup to leave
exactly id 1. Its clean export passed 85/85 steps and 642/642 tests. Restoring
the old cap makes the new test fail, so the behavior is now mutation-sensitive.
Mailed before and after commit as 4859/4865/4868/4870/4873.

### BLOCKER — policy-blocked-navigation live test can exceed its watchdog

**Status: CLOSED by `2dc67b6`; root cause PROBABLE (test-only), not captured.**
The reproduced symptom was the null-unwrap panic at `blocked: typing a,
Enter, b` described below. The compiled-xref audit found no reachable unwrap
in the production adapter and narrowed the candidates to the test driver's
`pagePort().?` and `std.debug.print` reaching the stdlib stderr cancellation
unwrap. `2dc67b6` removes both paths without changing production behavior.
Post-fix evidence is 30/30 clean loaded **server-runner** iterations plus two
sequential quiet clean-export gates at exact `2dc67b6`, both 85/85 steps and
644/644 tests. If a later captured stack enters production code, reopen this
classification and blocker.

The orchestrator's clean gate at `92ea230` ended **640/641** when
`native text: a navigation blocked by policy does not refuse later typing`
hit the live-test watchdog and exited 124. Independent green gates do not
override that reproduced final-gate failure. Popup-close code and exact
oracles remain approved in isolation, but N23/final integration is not green
until this hang is fixed and a clean gate passes every test.

The direct hang seam is `BlockedDriver.run`: its focus/token failure paths
return without invoking `LiveDriver.quit`, which is called only at the success
tail. Any bounded setup failure therefore leaves `zb_app_run` alive until the
60 s process watchdog hides the original failure with exit 124;
`NavEndDriver.run` has the same pattern. A second boundedness defect is in the
shared helper: `waitNotLeaving` counts only its requested 20 ms sleeps toward
an 8 s budget, although every embedded eval may itself wait 5000 ms.
`pendingId` has the same accounting error. A failed or delayed eval can thus
keep either helper alive far beyond its stated bound. The fix must quit the GTK
loop on every driver exit, identify the actual failed operation, retain the
production policy-blocked-navigation semantics, and use real monotonic
deadlines; merely raising the watchdog is insufficient.

A reviewer rerun of the existing root-test binary passed all 95 tests in about
30 s; the affected case took WebKit's `never started` policy-order branch and
printed `sent 3, value abc`. This confirms the behavior can pass but does not
clear the intermittent final-gate failure. Its setup first ignores an empty
result from a fixed-5-second readiness eval, then gives the focus click only
another five seconds. A slow initial load under the full parallel gate can
therefore reach the early-return/no-quit path. Readiness must be explicit and
checked under its own adequate bound without weakening the action deadlines.
The driver's chained per-operation maxima also exceed its 60-second watchdog;
after cleanup is unconditional, it must either stop at the first failed
prerequisite or enforce one overall deadline so a series of bounded failures
cannot still be reclassified as exit 124.

A later bounded reviewer worktree gate at `7059814`, while cc_1's eight-worker
stress reproduction was running, passed **85/85 steps and 642/642 tests**; the
affected case again took `never started`. That passing sample is useful load
evidence but does not close the orchestrator's reproduced hang or repair the
deterministic cleanup/deadline defects above.

cc_1's repeated 96-test root-binary run under eight CPU workers completed
29/30 green. Iteration 8 failed in the earlier bridge scenario: the single
Enter code point was sent, but `nativeText("\\n")` did not return the required
`DocumentChanged`; the next call with the old token was refused and no key
reached page B. The test does not print whether the first result was success,
Timeout, or another error, so the production-ordering-race hypothesis is not
yet established; the 10-second settle deadline may instead have expired under
stress. The policy-blocked-navigation case itself passed all 30 iterations.
Preserve and diagnose the exact result before changing production behavior.
Mailed as 4879 with the qualification/correction in 4880.

cc_1 reports that the orchestrator's failing-process excerpt contains `panic:
attempt to use null value` before the watchdog exit. Thus the process had
panicked rather than merely remaining inside the policy wait, while the
watchdog/panic-handler interaction hid the useful stack trace. The fix still
has to make every driver exit quit the main loop and identify the last live
stage. A bounded worktree gate begun at `262f54d` passed 85/85 steps and
642/642 tests, but cc_1's source WIP appeared while it was running, so this is
only a checkpoint and not clean-export closure evidence.

The first instrumented WIP stress batch exposed another native-text ordering
failure on iteration 5. The whole-string `nativeText("a\\nb")` returned
`DocumentChanged`, but `sent_chars` was not the required two; the subsequent
page-B no-key oracle still passed. The exact count was not printed, but the
result is consistent with the isolated-world keyup counter being observable
before the Enter default action's navigation report, permitting `b` to be
dispatched before the later settle notices the navigation. Keep the exact
`sent_chars == 2` oracle and establish a post-default-action acknowledgement
boundary; an arbitrary delay or weakened assertion is not a fix. Mailed as
4883/4884. Iteration 12 then resolved the earlier per-code-point ambiguity:
`nativeText("\\n")` returned success after dispatching its one Enter, rather
than `DocumentChanged`. This directly confirms that keyup acknowledgement can
win the race against observing the navigation caused by that key. Mailed as
4886; this production correctness blocker is separate from the original
policy-test panic and must also close before final.

The next uncommitted WIP adds unconditional GTK-loop teardown to every live
driver (including the formerly missed primary driver), caps helper evals by
their local monotonic deadline as well as the 45-second aggregate driver
budget, and counts a trusted form `submit` before its later Navigation API
task. A bounded worktree gate passed 85/85 steps and 642/642 tests under the
ongoing stress load; the policy case took the new `stopped after Enter` path
with `sent 2, value ac`. The exact PagePort contract requires stopping when
the character's acknowledgement shows a navigation; it does not require
predicting arbitrary navigation scheduled for a later task. Because the
trusted submit marker makes the reproduced form Enter visible synchronously,
this is the right production fix if its rebuilt stress run and a committed
clean gate remain green. The speculative immediate-second-call concern from
4887 is therefore a non-blocking follow-up, as corrected in 4895/4897. Loop
iteration 16 also confirmed the pre-fix whole-string call could return success
and over-dispatch (4888).

BlueBeaver independently ran the `92ea230` root binary 30 times idle and 30
times beside a full gate. Test 15 reproduced zero times, but the same Enter
race failed eight times each in tests 10 and 14. More importantly, two runs
stalled in `ScanServer.close`: gdb showed the server thread blocked in
`read(conn)` on an accepted speculative connection while the main thread
waited in `join()`. Closing only the listening fd cannot release that read.
Bound every accepted connection read (the identical seam is also in
DelayServer and NoContentServer) and add an idle-client close oracle. Mailed as
4891/4893. The relaxed wheel-navigation branch is contract-valid when it
returns page A before navigation starts, but `y != 777` is too weak: require
the exact page-A offsets and eventual navigation to Next (4895).

`765a32b` is an accurate docs-only handoff correction: it explicitly records
the `92ea230` gate as RED, retains the Enter-race and ScanServer findings as
open with cc_1, closes only the tracker oracle by `7059814`, and requires a
clean full-gate pass before integration is called green. Exact diff reviewed
and approved in mail 4901.

An intermediate navigation-marker WIP expanded beyond the surgical form-submit
ACK fix and was not safe to land. `automation.js:103-148` pre-marked capture-time
submit and click destinations as real pending navigations, posted them to the
shell, then cleared them only when `defaultPrevented` was later true. A page
handler can instead change the action/href or target (including a final
`_blank`/`<base target>` destination) without preventing default. That leaves
this document permanently `leaving`, because it receives no matching
Navigation API event/end; normal same-context actions also count/report both
the pre-marker and the real `navigate`. The reproduced contract needs only a
trusted submit to increment the key acknowledgement's navigation counter. The
real Navigation API event must remain the sole owner of pending state and
shell reporting. The reviewer's required worktree gate compiled this
intermediate version and failed the exact policy test, **83/85 steps and
642/643 tests**, seed `0xec4f4630`: the blocked and prevented submits stopped
after Enter, but later fresh typing into the unchanged document failed. This
directly validates the objection. cc_1 reverted while that already-compiled
test was running; the current source is the approved one-line trusted-submit
counter only, with no pending/shell/click pre-marker. It landed in `b0994ad`;
the mutant and clean-gate evidence is recorded below. Mailed as
4898/4902/4904/4905.

The accepted-connection timeout is the right production-shaped test-server
fix and covers ScanServer, NoContentServer and DelayServer. Its first oracle
slept 200 ms and assumed the server entered `read`, permitting a false green
if close won before accept. The current follow-up gives each server an atomic
accepted count, waits for that accepted fd, applies a two-second receive/send
bound before publishing the count, and releases an unbounded mutant only after
six seconds; the three-second close ceiling therefore distinguishes the
mutant. `idleClient` also closes its fd on connect failure. Code shape approved;
the mutation and clean-gate results below close the evidence requirement.
Mailed as 4900/4902/4905.

`b0994ad` lands the approved surgical submit counter and accepted-socket
timeout/oracle. cc_1's frozen-files gate passed **85/85 steps, 643/643 tests**;
removing the submit counter makes both strict submit cases send three
characters, and removing the socket bounds makes the idle-close oracle observe
6000 ms and fail. Those two production/test changes are approved. Exact commit
review found two remaining deadline blockers in its harness, however. First,
`NavEndDriver.run` declares a 45-second aggregate deadline but all eight native
click/text calls still receive raw 5/10-second limits; text failures continue,
so their chain can exceed the 60-second watchdog. Second, `waitNotLeaving` and
`pendingId` pass `end - monotonicMs()` from a second clock read into `left`;
after a scheduler pause it can be negative, and `std.math.clamp(value, 0, cap)`
asserts on the reversed bounds. Saturate non-positive caps, route every native
call through `left`, and advance the NavEnd stage labels. Mailed as
4906/4907/4909.

Historical status at `bc0bad1`: **SUPERSEDED by the CLOSED status at
`2dc67b6` above; this is not an open finding.**
`5c15e0b` replaces the unsafe clamp with a saturating `remainingMs` helper and
mutation-sensitive boundary cases, passes all eight NavEnd native operations
through the 45-second aggregate budget, and advances the four phase labels.
`55d5463` closes the last non-gating diagnostic SHOULD by clearing the global
stage before each completed watchdog join can hand off to the next test.

The reviewer had run a bounded fresh `git archive` gate twice. Exact `5c15e0b`
passed **85/85 steps, 644/644 tests**; the strict policy case printed
`DocumentChanged after 2`, `stopped after Enter, sent 2, value ac`, and the
prevented submit after two. After the stage-reset and handoff commits, exact
branch tip `bc0bad1` again passed **85/85 steps, 644/644 tests**, including the
popup/opener survival E2E. Both `/tmp/gate-*` exports were deleted immediately
by their traps; `/tmp` remained 19% used. Those successes do **not** close the
intermittent failure: the orchestrator subsequently ran an independent clean
export of the same `bc0bad1` and got **83/85 steps, 643/644 tests**, with this
test exiting 124 after `thread ... panic: attempt to use null value`; the raw
watchdog identified `blocked: typing a, Enter, b` as the active stage and then
timed out. Therefore `bc0bad1`'s handoff green claim is stale.

Closure now requires the exact null unwrap and stack, a surgical correction
(plus regression if production), at least 30 loaded iterations of this test,
and **two consecutive** bounded clean-export gates at **85/85, 644/644**. My
initial static trace found no explicit unwrap in `automation_gtk_port.nativeText`;
the driver's `gtk_port.pagePort().?` at `src/webkit.zig:2037` executes before the
recorded typing stage and is not yet a credible attribution. The owner must use
a raw-write test panic handler or repeated gdb panic/ABRT catch rather than let
the ordinary panic handler deadlock and lose the stack. Earlier green messages
4914/4917 were retracted in urgent mail 4918.

Reviewer reproduction at exact `bc0bad1`: a clean export compiled the root
binary with only module reachability and this blocked-navigation case, then ran
that three-test binary **60 times under six CPU burners**. Every invocation ran
under gdb with a breakpoint on `FullPanic.unwrapNull`; all **60/60 passed**, no
breakpoint fired, and the strict output remained `DocumentChanged after 2`,
value `ac`, and prevented submit after two. This confirms only that the
intermittent failure did not recur; it does not supply the required stack or
close the blocker. The throwaway tree was immediately deleted and `/tmp`
remained 21% used. Mailed as 4920.

That 60-run result is weaker than a build-step reproduction for one additional
reason: direct invocation selects Zig's `mainTerminal` test runner, whereas
`zig build test` launches the binary with `--listen=-` and selects
`mainServer`. The owner was asked in 4931 to keep the server-runner path while
filtering the root test step for a faster faithful loop; the cold full gates
already preserve it.

A reviewer clean-export gate of `d7a64d3` then preserved the exact failing
server-runner seed under the active parallel build/stress load:
`timeout 900 xvfb-run -a zig build test --seed 0x23dcdd56 --summary all`.
It passed **85/85 steps, 644/644 tests** (root 98/98 in 53 seconds); the blocked
case again returned `DocumentChanged after 2`, value `ac`, and prevented submit
after two. The tree was deleted immediately and `/tmp` remained 24% used.
This is another non-reproduction, not closure. Mailed as 4935.

`983a179` + `9c8fdb0` make the next recurrence diagnosable without
changing production behavior. If a live-test watchdog expires, it first names
the stage with raw writes, then on Linux permits ptrace and runs a bounded
30-second gdb `thread apply all bt 40` before preserving exit 124. A deliberate
stall at the failing stage printed all 13 threads, including
`BlockedDriver.run` and the GTK main loop. The follow-up keeps the Linux-only
`prctl`, pid, and gdb body out of non-Linux compilation. Both exact diffs are
approved. The reviewer's full Xvfb gate of the guarded bytes, concurrently with
another full-build load, passed **85/85 steps, 644/644 tests**; the author's
frozen clean-export gate did too.

The static audit also narrows, but does not yet prove, the cause. The original
excerpt continued with `error return context:`, which places the null unwrap
inside an active error branch. At stage `blocked: typing a, Enter, b`, the only
such driver branch is the expected `DocumentChanged` diagnostic
`std.debug.print`. One reachable stdlib unwrap is Zig 0.16
`Io.Threaded.recancelInner` (`Thread.current.?`) when stderr unlock observes
`error.Canceled`; a plain `std.Thread.spawn` driver has no `Thread.current`.
There is not yet evidence for why that writer state would be canceled, so this
remains a candidate, not a finding. The exact gdb stack is still required
before classifying and fixing the failure. The owner is looping cold-cache
clean exports because direct and warm-cache loops have not reproduced it.

History strengthens that candidate without proving it: `git blame` attributes
the normal expected-error `std.debug.print("blocked: typing ended...")` to
`b0994ad`, the hardening follow-up after the earlier `92ea230` timeout. The
later `bc0bad1` failure is the one that added a null panic while remaining at
that stage. If the stack confirms `unlockStderr -> recancelInner ->
Thread.current.?`, this is a test-driver/Zig-Io defect, not a production shim,
adapter, or engine defect; the narrow correction is to avoid the high-level
stderr path in that expected branch. Mailed as 4932.

A compiled-xref audit at `4f2de62` strengthens the same classification.
`webkit.BlockedDriver.run` contains exactly one direct call to
`FullPanic.unwrapNull`, the pre-stage `pagePort().?`. The compiled
`automation_gtk_port.nativeText` body contains none, and neither do the audited
direct and second-level adapter helpers (`acksFor`/`acksForRun`, `windowOf`,
`AckTracker.begin`/`settle`/ack waits, `SpinLock.lockUntil`, `docZ`, or the
deadline helpers). Immediately after the normal `DocumentChanged` result, the
driver calls the diagnostic at `src/webkit.zig:2052`; its compiled unlock path
does reach the stdlib `recancelInner` unwrap. JSON parsing and deeper library
invariants prevent this from being a complete call-graph proof, so the blocker
remained open at that checkpoint pending the orchestrator's defensive-fix
decision. Mailed as 4937.

A warm-cache worktree gate of exact `4f2de62`, deliberately overlapping
cc_1's six-CPU target stress and cc_2's full-build/gdb load, passed **85/85
steps, 644/644 tests** with seed `0xb59213c8`. The strict case again returned
`DocumentChanged after 2`, value `ac`, and the prevented submit after two.
This supplies another loaded server-runner sample and the pre-commit gate for
the review note, but it is neither a clean-export gate nor a reproduction and
does not change the OPEN status.

The defensive-fix decision does not reinterpret the stack as captured: the
two reachable test unwraps remain `pagePort().?` and the expected-error
`std.debug.print` stderr-unlock path; the production adapter audit found none.
The fix must therefore change only test drivers, retain the gdb watchdog, and
preserve production behavior. Mailed as 4941.

Commit `2dc67b6` is the accepted defensive implementation for the two
reachable candidate paths.
Its eight `pagePort()` uses now fail explicitly through the drivers' named
check path, `CountingJob` returns on a missing context, all executable
`std.debug.print` calls in `src/webkit.zig` use the lock-free `rawPrint`
helper, the gdb watchdog remains, and the commit changes no production code.
However, guarded optional unwrap operators remain in live driver code at
`src/webkit.zig:535`, 592, 595, 609, 631, 648, 696, 904-914, 956, 1054,
1073, 1104, 1119, 1280, and 2992. Short-circuit guards make these unlikely to
execute with null values. The orchestrator accepted the candidate-path fix at
`2dc67b6`; removing these guarded sites remains a separate test-only defensive
hardening follow-up. **CLOSED by `ffd3725`:** exact review confirms that its
optional captures/helpers preserve the predicates, it changes only live test
drivers/oracles, `rg` finds no executable `.?` or `std.debug.print` in
`src/webkit.zig`, and its quiet clean export passed 85/85 steps and 644/644
tests. Mailed as 4946/4947/4959.

Exact-diff confirmation requested by the orchestrator: **both candidate
paths are removed by `2dc67b6`**. The parent's `BlockedDriver.run`
`gtk_port.pagePort().?` (reported at `src/webkit.zig:2037`, line 2038 in the
parent object) becomes an `orelse return d.check(false, "the page port is
installed")` at committed line 2052. The parent's expected-error
`std.debug.print` at line 2052 becomes `rawPrint` at committed line 2066;
`rawPrint` formats into a fixed stack buffer and calls `write(2)` directly,
so it does not enter `Io.Threaded` or its `Thread.current.?` cancellation
path. **No production behavior changes:** the only changed file is
`src/webkit.zig`; every modified call site belongs to the main-thread test
scaffolding, a live test driver, or a `test` oracle/diagnostic. `rawPrint` and
the defensive `CountingJob` change are likewise test helpers, and the
production entry points at lines 8-20 and all production adapter/shim files
are unchanged.

Clean-export closure evidence at exact `2dc67b6` is not consecutive GREEN:

- Orchestrator gate #1: `timeout 1500 xvfb-run -a zig build test --summary
  all`, fresh clean archive/cache: **85/85 steps succeeded; 644/644 tests
  passed**.
- Independent RoseCat gate #2: same command shape and a fresh archive/cache,
  seed `0x217d74fa`: **83/85 steps succeeded (1 failed); 644/644 tests
  passed**. The sole failed step was `x-flows`: its first `x.post` command
  returned `-32007 navigation_timeout`. Later native X flow cases passed.
  The disposable tree `/tmp/zb-review-gate-8H2h67` was deleted by its EXIT
  trap. Therefore the required two consecutive clean-export gates have not
  been achieved.

The orchestrator subsequently established a **quiet-host acceptance
protocol** because those two gates overlapped cc_1's six-CPU stress, cc_2's
gdb/load loop, and other builds. Loaded gate #2 remains an observed timeout,
but it is not one of the two quiet acceptance gates. It was initially mailed
as BLOCKER 4948 and is reclassified below as a harness-robustness SHOULD after
both quiet gates passed.

cc_1's required post-`2dc67b6` loaded server-runner tally is **30/30 clean**:
zero failures, panics, or watchdog fires. Every iteration ran both the
blocked-navigation and live-bridge/navigating-click cases under the Zig build
server runner with six CPU burners; the first used the formerly failing seed
`0x23dcdd56`. Each reported 5/5 steps and 4/4 filtered tests, and every log
contained the blocked-submit oracle. The trap killed the burners and deleted
the export. A separate scratch-instrumented navigating-click loop was stopped
at 26/26 clean, with click completion in 9-12 ms; this is diagnostic support,
not a substitute for the production regression still required by BLOCKER
4940. Evidence: mails 4949/4950.

Quiet-host acceptance gate A at exact
`2dc67b6b52e63aed28e31c7f481a0d6f1d85a5dc` is **GREEN**. Both owners had
explicitly stopped their load, and a preflight process check found no Zig
build/test, gdb, CPU burner, or reproduction loop. A fresh clean archive and
cache ran under `timeout 1500 xvfb-run -a zig build test --summary all`, seed
`0xa9b885cd`, exit 0:

`Build Summary: 85/85 steps succeeded; 644/644 tests passed`

The formerly loaded-only `x-flows` failure passed, as did both native X flow
cases, the blocked-navigation oracle, and the popup-close e2e. The export
`/tmp/zb-review-quiet-a-KDaGvA` was deleted immediately by the EXIT trap, and
the postflight check again found no competing Zig/gdb/load process. This is
quiet gate A. The orchestrator's immediately sequential quiet gate B also
passed **85/85 steps and 644/644 tests** at exact `2dc67b6`. Together with the
30/30 loaded server-runner tally, this meets the acceptance protocol and
closes the blocked-navigation blocker.

### SHOULD — make the X-flow cold-start harness robust under extreme host load

**Status: CLOSED by `e7af69d`; APPROVE.** The first `x.post`
in `x_flows_test.py` returned `-32007 navigation_timeout` only during a clean
gate that overlapped multiple full gates, two stress loops, gdb, and six CPU
burners. The flow has a 120-second total budget, but its first `page.navigate`
is capped at 30 seconds and is sent as soon as the socket accepts, so that
single step includes the browser's cold startup and same-URL reload. The
client itself waits 50 seconds and did not expire. No elapsed-time or
`error.data` diagnostic was captured, so heavy-load exhaustion is plausible
but not proven.

Both quiet clean-export gates at exact `2dc67b6` passed `x-flows`, and quiet
gate A also passed the native X cases. Treat the failure as observed only
under heavy concurrent load, not reproduced on a quiet host. A test-only
robustness follow-up may first warm the fixture with a bounded 90-second
`page.navigate` plus composer wait, and should print elapsed time and the full
JSON-RPC error on recurrence. Production navigation and flow defaults must
not change. Read-only audit: mail 4953.

`e7af69d` implements that test-only shape exactly. `warm_up` uses a dedicated
client with a 150-second socket bound, a 90-second `page.navigate`, and a
30-second visible composer wait before the first flow. The real `x.post`
still performs its own production navigation, so the warm-up removes the
WebKit cold-start cost without bypassing the flow edge. `TimedRpcClient`
preserves `RpcClient.raw` and adds client name, method, elapsed time, and the
complete JSON-RPC error only when `call` fails; intentional raw-error checks
remain unchanged. The author reports a clean-export gate of **87/87 steps,
675/675 tests**, with a 0.6-second warm-up. Approved in Agent Mail 5016.

### SHOULD — diagnose a navigating native click timeout seen only under extreme host load

**Status: BLOCKED in review at `51c1954` (cc_1 follow-up required).** In a loaded direct-root-binary run of exact `bc0bad1`,
`automation bridge drives a live WebKitGTK page` failed only its navigating
click result and latency checks at `src/webkit.zig:1174-1175`: the 20-second
`nativeClick` returned an as-yet unprinted error after at least eight seconds.
The immediately following URL oracle passed on `b.html`, proving that the
trusted click was dispatched and its default navigation completed. This is
production-path evidence despite the terminal-mode runner: the PagePort did
not recognize replacement as delivery promptly, contrary to
`src/automation_gtk_port.zig:665-666`.

The failure is downstream of dispatch in `acks.settle` at
`src/automation_gtk_port.zig:679` / `waitAck` at lines 355-364. A likely seam
is an acknowledgement eval canceled by the old document's unload and
propagated instead of observing the replacement, but the exact PagePort error
was not captured. The post-`2dc67b6` server-runner tally passed 30/30 under
load, a scratch-instrumented loop passed 26/26 with 9-12 ms click completion,
and both quiet acceptance gates passed this live test. The orchestrator's
quiet-host protocol therefore removes this from acceptance blocking, while
retaining the observed production-path symptom as a follow-up. On any quiet
or repeatable recurrence, capture the exact error before changing semantics:
pre-dispatch cancellation and timeout must remain failures, and an ordinary
failed ack read must not be blindly converted to success. A correction would
still require a deterministic adapter regression for the transient-read /
replaced-document transition. Mailed as 4940. This is independent of the
probable test-only null panic.

`51c1954` captures the production root cause: an acknowledgement eval issued
against the old document can be suspended with WebKit's back/forward-cache
entry and never answer. One read is therefore bounded to one second and a
replacement-document observation can complete promptly. The author's loaded
reproducer measured 7/300 failures with the page cache enabled, 0/500 with it
disabled, and 0/300 after the fix while eight lost reads were observed. An
independent clean-export RED/GREEN check filtered the root suite to the exact
regression: the fixed commit passed **5/5 steps, 3/3 tests** in about one
second; restoring the pre-fix whole-deadline read failed the named test with
`error.Timeout` after six seconds (**3/5 steps, 2/3 tests**). The export was
deleted immediately.

The commit is not yet approvable because the retry encoding regresses another
production caller. `AckTracker.read` converts an inner slice timeout into
`null`, while `waitScrollSettled` at `src/automation_gtk_port.zig:751`
interprets every `null` as `DocumentReplaced`. A suspended/lost eval after an
already-acknowledged wheel is therefore reported as `document_changed`
instead of being read again on the same live document. The follow-up must
preserve the distinction between a reader that actually returns null and an
inner slice timeout, and add `{moving ack}, lost read, {quiet ack}` coverage
through `waitScrollSettled`. Blocker and failing-first evidence: Agent Mail
5015/5017.

The reviewer also ran a bounded clean export of exact `51c1954` on a quiet
host, with `DISPLAY`, `WAYLAND_DISPLAY`, and `ZIGBROWSER_SOCKET` unset and a
fresh Xvfb display. It passed **87/87 steps and 677/677 tests**, seed
`0x358fd7a1`; the X fixture warm-up completed in 0.6 seconds. The disposable
tree was deleted immediately. This validates the existing suite and the
approved `e7af69d` production-chain path, but does not waive the untested
native-scroll caller regression above.

Review thread:
4871/4872/4874/4875/4879/4880/4882/4883/4884/4886/4887/4888/4889/4891/4893/4895/4897/4898/4900/4902/4904/4905/4906/4907/4909/4910/4912/4914/4915/4917/4918/4919/4920/4921/4922/4923/4924/4925/4926/4927/4928/4929/4930/4931/4932/4933/4934/4935/4936/4937.

## Deferred scope note

Historical note: M6 included `page.screenshot` outside the task's original ten-
method priority list. That deferral is now closed by the N19 PagePort/GTK/socket
implementation and production-chain PNG oracle; the remaining screenshot
finding above concerns exact deadline classification, not feature absence.

## HTTP/2 GOAWAY workaround review at 06ebee8

**Status: APPROVED. No blockers.** Commit `06ebee8d60da6c306539e141269dd47f01077d32`
implements the Linux-only HTTP/1.1 default early enough and preserves both
forms of user control. `src/app.zig:35-45` calls `preferHttp1` before profile C
work, automation threads, script installation, or `zb_app_run`; the direct
WebKit entry points call it immediately before the C boundary for both open
and screenshot at `src/webkit.zig:14-21`. The decision helper and application
at `src/webkit.zig:25-38` preserve any existing `SOUP_FORCE_HTTP1` value and
use `setenv(..., overwrite=0)`; exact `ZIGBROWSER_HTTP2=1` opts out. This
covers the main-window and screenshot startup paths before a WebKit network
process can be created.

The helper test at `src/webkit.zig:40-51` covers the unset default, user-set
values including empty and `0`, the exact opt-out, non-opt-out values, and the
combined user-value/opt-out case. The regression is wired into the full gate
at `build.zig:536-544` and `build.zig:752`.

`tests/e2e/http2_goaway_test.py` is a faithful wire-level reproducer, not only
a WebKitNetworkProcess environment check. Its local TLS server negotiates ALPN
and sends complete HTTP/2 HEADERS, DATA with END_STREAM, and
GOAWAY(NO_ERROR) in one `sendall` (`:80-147`). A real page `fetch` supplies the
behavioral oracle (`:198-211`). The opt-out control must negotiate HTTP/2 and
observe `TypeError: Load failed`; the default must negotiate HTTP/1.1 and
observe `ok opaque`; it separately checks the inherited environment and the
screenshot path (`:316-375`). The self-signed trust override is confined to
the browser processes created by the test, and every browser is launched
under its own Xvfb display.

Independent failing-first proof used a disposable clean export of parent
`f1cab4a`, overlaid only the new regression script, and ran it against the
parent binary. It exited 1 with five failed checks: the HTTP/2 control still
reproduced the TypeError, while default open used HTTP/2, returned the
TypeError, lacked the forced environment value, and the screenshot path also
used HTTP/2 and failed its title oracle. The user-supplied value was preserved.
The export was deleted immediately afterward.

`docs/how-to-automate.md:37-47` matches the implementation: Linux defaults to
HTTP/1.1 for the named libsoup/WebKitGTK failure, exact
`ZIGBROWSER_HTTP2=1` opts out, and a user-exported `SOUP_FORCE_HTTP1` value is
not overwritten.

An independent quiet clean-export gate at exact `06ebee8`, with fresh cache,
ran under `timeout 1500 xvfb-run -a` on display `:111`; `DISPLAY`,
`WAYLAND_DISPLAY`, and `ZIGBROWSER_SOCKET` were removed from the parent
environment. It exited 0 with seed `0x533dc7a5`:

`Build Summary: 86/86 steps succeeded; 645/645 tests passed`

The GOAWAY e2e reported all ten checks green. The disposable export was
deleted immediately, and the live browser on display `:0` and its live socket
were never touched. BlackRobin independently reported the same 86/86,
645/645 result in Agent Mail 4964.

## X selector refresh review at f8c1f14

**Status: APPROVED. No blockers.** Commit `f8c1f14a83dc2da0154235636fa58dfa331dfa97`
replaces the stale schedule-select assumptions and makes the compose dialog win
over simultaneous timeline controls. The XPath union at `src/x.zig:51-55`
selects the dialog copy whenever any matching control exists inside a dialog;
otherwise it selects the page copy. More than one dialog copy remains an
ambiguity for strict resolution and therefore fails closed. The labelled-select
selector at `src/x.zig:58-60` follows `aria-labelledby` to exact label text and
does not depend on generated `SELECTOR_*` ids or the absent `aria-label`
attribute.

The fixture at `tests/fixtures/x/composer.html:70-115` mirrors both relevant
live structures: generated select ids with text-bearing labels, and a compose
dialog over timeline controls that record any accidental use. The socket-level
`x.post` and `x.schedule_post` scenarios at
`tests/e2e/x_flows_test.py:145-165` prove that both timeline controls stay
untouched. They traverse the production router, queue, engine, and PagePort;
the test does not call selector helpers directly. Failing-first is mechanically
credible and recorded in the commit: the old `select[aria-label=...]`
selectors cannot match the new fixture selects, so scheduling times out before
the production change.

`git diff --check f8c1f14^ f8c1f14` is clean. An independent clean archive of
exact `f8c1f14`, with a fresh cache, live display/socket variables removed, and
Xvfb, exited 0 with seed `0x2e78fc95`:

`Build Summary: 86/86 steps succeeded; 647/647 tests passed`

The X production-chain E2E reported `compose-dialog-over-timeline` and
`x-flows` PASS. The disposable export was deleted immediately. Verdict mailed
to BlueBeaver as Agent Mail 4977.

## Page-dialog review at a8678c1

**Status: BLOCKED pending follow-up.** The native ownership and primary-window
production chain are otherwise sound: the shim owns one explicit
`WebKitScriptDialog` reference per window, duplicates prompt text across the C
ABI, closes and unreferences through one GTK-thread path, and the synchronous
main-thread bridge keeps call storage alive even if the caller's wait expires.
The socket-level dialog e2e uses the real binary, server, engine, GTK adapter,
and WebKit page; it covers alert, both confirm outcomes, prompt text/dismiss,
beforeunload fail/accept/dismiss, popup targeting, and popup closure.

Open blockers from the exact committed diff:

- `src/automation/engine.zig:1102` still bounded root-span automation errors at
  `.cancelled`, excluding new `-32013 dialog_open`; the root span therefore had
  no `automation.error`. `src/automation/social_flow_routes.zig:557-558` had
  the same stale bound and emitted `internal` for a dialog-blocked compound
  flow. The owner follow-ups must derive this bound from the taxonomy and test
  both root and compound spans.
- `sdk/node/src/errors.ts:19` still used `AUTOMATION_MIN = -32012`, so the Node
  SDK classified `dialog_open` as a generic `ProtocolError`. Its error table
  and wire/API coverage must include the thirteenth code and the new methods.
  The independent legacy enum in `src/automation_rpc.zig:14-27` was also still
  twelve values and should reuse the canonical taxonomy rather than drift.
- A popup dialog blocks the opener's JavaScript because related WebViews share
  a WebKit process, but the committed pre-dispatch checks inspect only the
  target window (`src/webkit_shim.c:2125-2128`, `:2654-2657`) and
  `auto_dialog_opened` completes only jobs whose target is the dialog's window
  (`:3966-3990`). Thus a known popup alert can leave an opener DOM/eval call to
  consume its deadline. Related-window jobs must fail fast with `dialog_open`
  both when already open and when the dialog appears in flight, while the
  dialog remains available to `dialog.get/respond`; a production-chain popup
  regression is required.
- The automatic beforeunload answer is deferred with `g_idle_add`, and the
  code explicitly permits a person or `dialog.respond` to close the dialog
  first (`src/webkit_shim.c:3925-3957`). In that ordering the idle callback
  skips its reconciliation. A requested dismiss that actually stays, or an
  accept whose dialog is dismissed, can remain in flight until
  `navigation_timeout`; an opposite human answer can also contradict the
  requested policy. Every close ordering must give the tracked navigation one
  exactly-once outcome, with a deterministic race regression.
- The dialog guards cover ordinary eval and load jobs, but
  `auto_start_files` (`src/webkit_shim.c:2314-2353`) and full-page screenshot
  measurement (`:2627-2643`) call page JavaScript directly. They have no
  already-open check, and `auto_dialog_opened` does not complete these job
  kinds when a dialog appears in flight. The native input document guard is a
  third direct JS call (`:3494-3514`) that is missed when a dialog opens after
  locate but before dispatch. `dom.setInputFiles`, a full-page screenshot, and
  an in-flight native guard can therefore still wait to deadline; the follow-up
  must include them without weakening set-files' late-chooser tombstone or
  native no-dispatch-after-failure guarantees.

Findings were mailed to BlackRobin and BlueBeaver as 4984, 4985, 4987, 4990,
and 4991.
Approval and an independent gate are deferred until the follow-up commits land.

## LinkedIn/Instagram selector refresh review at d9fc82b

**Status: APPROVED.** The wrong-person risk is fail-closed in production.
`src/linkedin.zig:88` makes
`owner_actions_enabled` an immutable false constant. Although the future
scoped path can be exercised through `flow_steps.Site.unverified_actions`, the
production server constructs `social_flow_routes.Env` without that field at
`src/automation_server.zig:469`; repository-wide xref at this commit finds the
true capability only in unit/route tests.

All three profile mutations—Connect, Follow, and Message from a profile—open
the page, pass the signed-in gate, check the final URL with both `Site.allows`
and `/in/<x>`, read the owner from `<Name> | LinkedIn`, and then return
`linkedin_profile_owner_unverified` before any click
(`src/linkedin.zig:248-295`, `src/linkedin.zig:404-475`). The socket-level
`social_flows_test.py` drives the real server and
asserts for each that `result` is null, `wrongPerson` is empty, and the event
list is empty. This test covers the production refusal; the prospective
enabled selector remains intentionally test-only/unverified. That helper uses
the exact title-derived label outside `aside`, counts the owner and the same
label across the document, rejects zero/multiple/duplicate matches, and sends
a strict click (`:447-465`). It therefore never falls back to a generic
sidebar button, but must not be enabled until the live owner container is
verified.

Instagram story viewing follows the same safe-off pattern: the final URL must
be on the configured site and have a real `/stories/<x>` path, then production
returns `instagram_story_viewer_unverified` before waiting for media or
clicking Next (`src/instagram.zig:141-159,196-224`). The production-chain e2e
keeps both the ordinary story and an earlier decoy carousel untouched. The
future frames loop strictly rejects more than one Next.

The refreshed fixtures use synthetic `Sam Example` / `Riley Sample`; a search
found none of the known real-person names removed from the prior fixtures.
The signed-out fixture includes a content-only Me decoy, the LinkedIn fixture
renders owner actions late beside suggestion-card actions, and the Instagram
fixture renders late profile buttons plus both highlight and story Next
controls. `git diff --check d9fc82b^ d9fc82b` is clean.

The follow-up docs commits `3b53df8` and `040a719` were also reviewed. Their net
tree documents strict `dom.waitFor`, the X compose dialog/leave prompt, and the
safe-off social-flow reasons. `040a719` removes only the three dialog-document
hunks accidentally captured from BlackRobin's working tree; those edits remain
unstaged for their owner. The historical `3b53df8` subject/body described the X
draft failure as `-32007`, but both the committed docs and resulting tree
correctly say `-32013`; no history rewrite is warranted.

Independent clean-export gate at exact `040a719`, with a fresh cache and Xvfb,
exited 0 with seed `0x892ba706`:

```text
Build Summary: 87/87 steps succeeded; 671/671 tests passed
```

The selector production-chain cases reported `linkedin`, `instagram`,
`social-flows`, and `x-flows` PASS. The disposable export was deleted
immediately. Preliminary review was mailed to BlueBeaver as Agent Mail 4992;
the final APPROVE follows this review-log commit.

## Page-dialog follow-up review at a3dcca8

**Historical status at `a3dcca8`: BLOCKED pending a new follow-up commit.** The
exact diff closes the known production-code gaps from the `a8678c1` review:
dispatch-time dialog checks cover the full related-view `process_group`;
`auto_dialog_opened`
completes tracked eval/load/screenshot/native work and preserves the
set-input-files tombstone; a policy-owned beforeunload prompt is not shown,
listed, or answerable through `dialog.respond`; native input still in its
document guard cannot dispatch; and the canonical `isAutomationCode` bound is
used by root and social compound telemetry. Node, Python, the legacy Zig enum,
and the documentation agree on `-32013 dialog_open`. C dialog refs, copied
strings, tracked-job refs, and late callback ownership are sound. The exact
diff passes `git diff --check`.

Three in-flight lifecycle branches are not yet protected by tests:

- `tests/e2e/automation_dialogs_test.py:196-210` opens the popup alert before
  starting any opener command. It proves `auto_window_blocked` but does not
  drive `src/webkit_shim.c:4062-4086` when an opener eval/DOM job is already
  tracked and the related popup opens a dialog. A two-connection production
  chain regression must prove prompt `-32013`, retain the popup dialog for
  response, and drop the opener's late eval result.
- The E2E's screenshot and setInputFiles checks at
  `tests/e2e/automation_dialogs_test.py:129-147` are likewise dispatch-time
  checks. The live test covers native input in flight, but no test opens a
  dialog after full-page measurement or after set-files tracking. Regressions
  must exercise the existing screenshot/set-files seams, prove `-32013`, and
  then prove no snapshot/file application and cancellation of the late file
  chooser.
- `ZbDialogAnswer` stores only the window, dialog, and desired response
  (`src/webkit_shim.c:4008-4030`), not the navigation job that owns the
  prompt. A held ACCEPT callback therefore has no proof that its navigation
  is still RUNNING after the waiter times out. A short-timeout regression must
  prove the held callback cannot navigate after abandonment; if it can, the
  answer must be bound to a held ref on the exact owner job and stale answers
  must dismiss rather than leave.

Small SHOULD: declare `zb_auto_debug_policy_hold_ms` as `gint` instead of
casting a `guint *` through the `g_atomic_int_*` API.

The author reports a quiet exact-tree gate of `87/87 steps, 675/675 tests` and
six killed mutants, but those mutants do not exercise the three branches
above. Formal findings were mailed to BlackRobin as Agent Mail 5000. An
independent final gate is deferred until the follow-up lands.

### Resolution at `fd961a8`

**Status: CLOSED by `ca8d84b` + `fd961a8`; APPROVE.** `ca8d84b` binds a
policy-owned beforeunload prompt to a held ref on its exact navigation job
(`src/webkit_shim.c:3985-4004`, `4100-4120`). A delayed ACCEPT now leaves only
while that owner is still RUNNING, stale answers stay on the page, and window
teardown releases the tracked and policy-held refs without using a freed
window or job. The debug atomic is the matching `gint` type. The author
reported honestly that removing this defense-in-depth owner check survives:
the existing abandonment path already stops and untracks the pending load.
The regression still proves the required externally observable invariant
after the delayed callback actually runs: timeout, no later navigation, no
prompt, and no leaked job (`src/webkit.zig:3360-3376`).

The other missing in-flight branches now have direct oracles. A dialog ends
related-view eval/load/screenshot/native jobs and preserves a set-files
tombstone at `src/webkit_shim.c:4055-4090`. The live policy test opens an alert
between full-page measurement and capture, requiring `DIALOG_OPEN`, no PNG,
and a drained job (`src/webkit.zig:3402-3418`); it also opens one after
set-files tracking, requiring the late chooser cancellation counter to advance
and `files.length` to remain zero (`src/webkit.zig:3420-3438`). The author
reports that deleting each of those in-flight handlers kills its new test.

`fd961a8` makes the production-chain related-popup test deterministic. The
worker evaluation first sets the opener's title, and the main client observes
that native title through queue-free `page.list` before opening the popup alert
(`tests/e2e/automation_dialogs_test.py:212-240`). Thus the expected `-32013`
must come from ending already-tracked work, not the dispatch-time guard; the
popup's alert remains open and answerable. The abandoned-ACCEPT test likewise
uses a 900 ms deadline, an 1800 ms hold, and waits 2200 ms after the call
returns, so its postconditions cannot run before the delayed answer.

Both follow-up diffs pass `git diff --check`. BlackRobin's quiet frozen-files
gate passed **87/87 steps, 675/675 tests**. The independent reviewer gate used
a fresh `git archive fd961a8`, unset `DISPLAY`, `WAYLAND_DISPLAY`, and
`ZIGBROWSER_SOCKET`, and Xvfb; it passed **87/87 steps, 675/675 tests**, seed
`0x2c33c323`. The disposable tree was deleted immediately. Findings and the
test-validity follow-ups were mailed as Agent Mail 5000-5007; final approval
follows this log commit.

## Final quiet clean-export gate at 07643a1

**Status: GREEN.** On a quiet host, the reviewer exported exact commit
`07643a1` into a fresh disposable directory, unset `DISPLAY`,
`WAYLAND_DISPLAY`, and `ZIGBROWSER_SOCKET`, and ran the full suite under a
new Xvfb display with a 1500-second bound. The result was **87/87 steps
succeeded; 675/675 tests passed**, seed `0xeb3b72b9`. This includes the dialog
production-chain regression, popup-close survival, the HTTP/2 GOAWAY control
and default cases, selector/social flows, and the live WebKit input tests. The
throwaway export was deleted by its `find -delete` exit trap. No live browser,
DISPLAY `:0`, or `zb-live.sock` was used.

## Test-hygiene audit at fc4ebfa

### BLOCKER-for-tests — killing `xvfb-run` leaks its X server and browser

**Status: CLOSED by `34238a3`; approved as Agent Mail 5090.** See the exact
fix and regression evidence under the later Node live-test launcher section.
PIDs 3116183 and 3147132 were still-live 16-hour-old
`zigBrowser ... --automation-api` processes. Their
PPID is the user systemd (1368), and each retains its WebKit network/web
children. Xvfb PIDs 3116172 (`:105`) and 3147127 (`:106`) began in the same
second as the matching browser, share its now-dead session and process group,
and are also reparented to 1368. The retained
`/tmp/xvfb-run.zjLLe2/Xauthority` and
`/tmp/xvfb-run.XfV748/Xauthority`, live X105/X106 sockets, and lock files prove
that `xvfb-run`'s EXIT cleanup did not execute. The processes were inspected
only and deliberately left alive for the orchestrator.

The wider `/tmp/.X11-unix` inventory separates live leaks from stale residue.
At audit time X105, X106, and X107 had live Xvfb processes in cc_1's scope;
X111 and X119 had live Xvfb processes in cc_2's scope. Most other X99-X120
lock files named dead PIDs, so their sockets/locks are stale artifacts rather
than live servers. Because `xvfb-run` chooses a display by the existence of
the lock file, that residue also explains why later tests kept advancing to
higher display numbers. The cross-agent Xvfb residue reinforces that the
shared harness boundary is the owner even though the two preserved browsers
are specifically cc_1 probes.

The boundary error is concrete. `tests/e2e/slice2_common.py:97-112` returns
`[xvfb-run, -a]` as a command prefix, so every caller's `Popen` object denotes
the wrapper shell, not zigBrowser. `tests/e2e/automation_core_test.py:196-204`
and `tests/e2e/automation_api_lifecycle_test.py:97-105` signal that one PID and
fall back to `proc.kill()` on that PID. `slice2_common.run_interactive_until`
does the same at lines 175-213, while `sdk_python_live_test.py:86-110`,
`social_flows_test.py:276-301`, `automation_scroll_test.py:158-183`, and
`automation_native_ports_test.py:246-271` carry local copies. On this host,
`/usr/bin/xvfb-run:79-92,158-165,198-205` cleans its auth directory and Xvfb
only from an EXIT trap. SIGKILL of the wrapper cannot run that trap and never
targets the separately running browser; both descendants survive.

Exact attribution is narrower than the systemic defect. Both leaked browsers
belong to BlackRobin's systemd/Claude scope, and both environments contain
`XDG_DATA_HOME`/`XDG_CACHE_HOME` values made by
`slice2_common.isolate_profile_env`. However, their bare fixture URL `/` and
unprefixed `TemporaryDirectory()/a.sock` shape occur in no committed E2E at
HEAD or in branch history (`git log -S'a.sock'` is empty). They came from an
ad-hoc cc_1 native/E2E probe, not `x_flows_test.py`. The committed tests remain
vulnerable to the same teardown failure. `automation_dialogs_test.py:274-307`
already shows the minimum internal-cleanup shape: a new session followed by
bounded signals to the whole process group, not one wrapper PID.

Required failing-first coverage: put browser/Xvfb ownership in one shared
helper, launch an INT/TERM-resistant harmless client through the real
`xvfb-run` with a unique marker, force the current escalation path, and assert
that the wrapper, Xvfb, and client PIDs all disappear and its X lock/socket and
auth directory are removed. The current PID-only fallback must fail this
test. Then migrate every `detect_runner` consumer to the helper and remove
direct error-path `proc.kill()` calls. The helper should start a distinct
session, signal the full group (INT, then bounded TERM/KILL), wait, and verify
the tracked descendants. A second regression should terminate the Python
driver with catchable TERM to prove its signal handler also tears down the
group. Uncatchable SIGKILL cannot be repaired by `finally`; if that case is a
required contract, the outer timeout must kill a dedicated process group or
cgroup rather than only the driver.

Finding mailed to BlackRobin, with BlueBeaver copied because the flow E2Es use
the vulnerable shared launch pattern, as Agent Mail 5011.

## Live YouTube blank-window investigation at `8e80655`

### BLOCKER — the NVIDIA media/presentation failure is not guarded or diagnosable

**Status: CLOSED by `ee00876`; superseded by the approved Linux case-J
default at the section below.** This paragraph records the original state:
the probable root cause and captured symptom before the physical-presentation
matrix and user-watched case-J run supplied the missing evidence. The user's
live `07643a1` browser
opened a YouTube watch page as the second related popup. It showed the poster
briefly and then the physical GTK window went blank. All investigation of the
live instance was read-only; no navigation, reload, input, window close,
process signal, account action, or DISPLAY `:0` capture was performed. The two
socket screenshots remain outside the repository.

The document did not fail to load. At 08:51--08:54 EDT, `page.url`,
`page.title`, `dialog.get`, and side-effect-free `page.evaluate` calls on
window-3 answered in milliseconds. The document was `complete` and `visible`,
with 58 body children, about 2.29 MB of HTML, 87 resource entries, and a
1.514-second load event. The YouTube app, player, and video existed; the video
reported `readyState=4`, an 854x480 stream, and no `MediaError`. A viewport
PagePort snapshot completed in 53 ms and a full-document snapshot contained
the poster, controls, comments, and recommendations. That snapshot proves
WebKit could still rasterize the document; it does not prove that GTK
successfully presented the same pixels to the X11 window, which is the layer
the user saw fail.

The frozen 08:49 live log supplies the matching lower-layer failure. It has
NVIDIA `nv_gbm_create_device` errors, repeated
`DRM_IOCTL_MODE_CREATE_DUMB ... Permission denied`, and four exact
`Failed to create GBM buffer of size 1024x768: Permission denied` messages.
The allocation size is the window size configured at
`src/webkit_shim.c:1080-1083`. Media-process warnings report GStreamer sticky
events out of order around the same period, but those warnings alone do not
identify the failed view. The relevant WebProcesses remained alive and
CPU-active and mapped EGL, GBM, DRM, CUDA/nvcodec, and GStreamer while holding
NVIDIA and render-node descriptors. This occurs despite the `NEVER` hardware
policy applied to every view at `src/webkit_shim.c:1085-1090`, so that setting
does not remove the media transport/presentation path.

Competing causes were checked. The browser cgroup had about 22.3 GiB host
memory available, zero current memory pressure, and no OOM event. The network
process was alive, every WebKit child had inherited `SOUP_FORCE_HTTP1=1`, and
the page had completed its navigation and resource load; the prior HTTP/2
GOAWAY failure is not implicated. Both stdout and stderr feed the inspected
live log, which contains no `LOAD_FAIL`, timeout, termination, crash, or
GOAWAY line. That plus the 1.514-second completed load rules out the shim's
legacy 15-second load watchdog for this occurrence.

This is also a known project and platform failure class. The July handoff at
`thoughts/searchable/shared/handoffs/general/2026-07-04_09-04-50_linux-deb-launch-debug.md:48-50`
records the same GBM permission error causing blank renders; `a78fa5c` added
the current hardware-policy setting but no presentation regression. Upstream
WebKit [bug 281279](https://bugs.webkit.org/show_bug.cgi?id=281279) describes
invisible-but-interactive GTK3 views on proprietary NVIDIA and names
`WEBKIT_DISABLE_DMABUF_RENDERER=1` and
`WEBKIT_DISABLE_COMPOSITING_MODE=1` as workarounds. WebKit bug 260654 is more
specific to YouTube/media: decoder output can require a raw-NV12-to-DMABUF
conversion in which WebKit allocates a GBM buffer and has no reliable
nonaccelerated fallback ([WebKit bug 260654](https://bugs.webkit.org/show_bug.cgi?id=260654)).
The exact host package is Debian WebKitGTK
2.52.6-1~deb13u1. Debian includes `disable-nvidia-dmabuf.patch` for the normal
[UI backing store](https://sources.debian.org/patches/webkit2gtk/2.52.6-1~deb13u1/disable-nvidia-dmabuf.patch/),
so the remaining live failure may be the GStreamer/video DMABUF path; neither
generic environment flag may be sufficient. No production environment default
is approved without a discriminating test.

The isolated result corroborates an upstream WebKitGTK/YouTube problem but is
not the same phenotype. Exact `07643a1` reaches a complete YouTube player under
Xvfb and then the zigBrowser UI process's GTK main thread dereferences a null
WebKit object at offset `0x48` inside `libwebkit2gtk`; direct, one-hop, and
two-hop watch-page launches do the same in roughly 4--8 seconds. Actual X11
root-window pixels are nonblank and changing until that crash. The result
persists with
`WEBKIT_DISABLE_DMABUF_RENDERER=1`, `WEBKIT_DISABLE_COMPOSITING_MODE=1`, and
`ZIGBROWSER_HTTP2=1`. Stock WebKitGTK 2.52.6 MiniBrowser also crashes on the
same page, with both default HTTP and forced HTTP/1, and reports
`WebLoaderStrategy.cpp:640` before exiting. A local VP9/Opus autoplay page and
YouTube's homepage and embed route survive, isolating the controlled failure
to the watch-page path rather than generic media. This rules out the popup
chain, zigBrowser shim, HTTP/1 default, and the two generic renderer switches
as causes or fixes for the Xvfb crash. Because the live UI process and document
survived, the Xvfb crash is not claimed as the exact live root cause.

There is now a concrete failing-first compatibility test: make an opt-in
network E2E open the same public watch URL through a local two-hop popup
fixture, confirm title/DOM/video readiness, and then require the UI process,
socket reads, and actual X11 window pixels to remain live and nonblank at 10
and 35 seconds. Exact `07643a1` currently fails in 5--8 seconds. Keep it out of
the hermetic default gate because it depends on a public site, but run it when
qualifying a WebKitGTK package; the installed version is 2.52.6 and the
currently available Debian candidate is 2.54.0, which was not installed or
tested. A fully local generic-media fixture is not a substitute: the VP9/Opus
control survived 20 seconds, as did YouTube homepage/embed controls for 15
seconds.

The live blank-with-responsive-DOM symptom still needs an actual-presentation
matrix on the affected NVIDIA/X11 path. Do not use `page.screenshot` as the
sole oracle because the live snapshot bypassed the failed presentation.
Preserve stderr and compare baseline with
`WEBKIT_DISABLE_DMABUF_RENDERER=1`, `WEBKIT_DISABLE_COMPOSITING_MODE=1`,
`WEBKIT_DMABUF_RENDERER_FORCE_SHM=1`, and diagnostically
`WEBKIT_GST_DMABUF_SINK_DISABLED=1`. A viable mitigation must keep the actual
window nonblank, retain playback, and remove the allocation failure. Also
connect WebKit's `web-process-terminated` signal and expose its reason with
`window_id`; the current connections at
`src/webkit_shim.c:1092-1118` cannot distinguish a crash, API termination, or
memory-limit exit. Findings and the corrected X11-pixel oracle were mailed to
BlackRobin as Agent Mail 5024--5026.

The review-note pre-commit gate exported exact parent `8e80655` into a fresh
throwaway directory, unset `DISPLAY`, `WAYLAND_DISPLAY`, and
`ZIGBROWSER_SOCKET`, and ran the full suite under a private Xvfb display with
a 1500-second bound. It passed **87/87 steps, 677/677 tests**, seed
`0xa00e20f1`. The export and its cache were deleted immediately by the
`find -delete` exit trap; the live browser was not involved.

### SHOULD — the legacy 15-second human-load watchdog can create the same symptom

**Status: CLOSED by `20e0265`; separately discovered and not the cause of this
incident.**
Every non-automation `WEBKIT_LOAD_STARTED` arms a fixed timer at
`src/webkit_shim.c:360-380`; only a tracked automation load suppresses it at
`src/webkit_shim.c:932-937` and `1942-1951`. If a human navigation commits but
does not reach `FINISHED` within 15 seconds, `on_window_timeout` marks failure
and unconditionally terminates the WebProcess at lines 736-768. The current
test at `tests/e2e/load_timeout_test.py:109-139` asserts only `LOAD_FAIL` and
that the browser parent is alive. It does not prove the affected view renders
or answers afterward, nor that related siblings retain state.

Add a local three-view regression whose last response commits a DOM sentinel
but remains unfinished beyond 15 seconds. At 14 and 16 seconds, assert the
specified recovery contract for that view and prove both related siblings
remain usable. A separate test-only termination should assert that the new
`web-process-terminated` handler records `TERMINATED_BY_API` for the exact
window. The live YouTube document finished in 1.514 seconds and emitted no
`LOAD_FAIL`, so this latent defect is deliberately not labeled its root cause.

The fix and production-chain evidence are recorded under “Committed-load
watchdog and popup crash attribution” below. A committed page now remains
alive and usable, a never-committed related popup is stopped without ending
its shared process, and a lone never-committed window retains the prior
termination recovery.

### WebKitGTK 2.54.0 qualification on Xvfb

**Status: BLOCKER remains OPEN (cc_1). The old UI-process SIGSEGV was not
observed, but the upgrade does not produce a usable YouTube view.** After the
host was upgraded to Debian `libwebkit2gtk-4.1-0` and
`libjavascriptcoregtk-4.1-0` `2.54.0-1~deb13u2`, the reviewer rebuilt exact
`07643a1` from a fresh `git archive` with private local and global Zig caches.
The resulting binary's SHA-256 was
`4a251625ac8a30814ff5426d0aea8d071398cb6d15cf9ee7a81f66d4eba2642c`.
Every run used a new Xvfb display and throwaway HOME, XDG directories,
profile, and socket; neither DISPLAY `:0` nor the live socket/profile was
touched. The package-download experiment requested before the system upgrade
was stopped and its complete scratch tree was deleted.

The installed MiniBrowser reached the exact watch URL through a local
opener-to-middle-to-YouTube `window.open` chain, with automatic popups enabled
explicitly. At 10 and 35 seconds from launch, its UI process, network process,
and three WebProcesses were alive, and the top-level X title still named the
expected video. The actual 1280x900 X11 root captures were nevertheless
uniformly black at both samples: mean 0, standard deviation 0, and identical
MD5 `54ab45ed329c9f0bfdefff6e74753459`. MiniBrowser emitted no crash marker and
no GBM, DRM-dumb-buffer, or explicit GBM-buffer-allocation error. Thus 2.54.0
does avoid the old 2.52.6 MiniBrowser process exit in this run, but its
two-hop popup still fails the real-presentation oracle.

The fresh zigBrowser used actual `dom.click` commands for both links, proving
the production window chain and recording `window-3` with the expected URL,
full title, and `opener_window_id: window-2` before the failure. By 10 seconds
after that readiness point, the target WebProcess had disappeared while the
UI process, network process, and the opener/middle WebProcess remained alive.
At both 10 and 35 seconds, `page.list` kept `window-3` but cleared only its URL
and title, side-effect-free `page.evaluate` returned `-32603 Evaluation
failed`, and the X11 frame was the same all-zero frame as MiniBrowser. stderr
contained no WebProcess-termination diagnostic and zero GBM/DRM allocation
errors. This is a silent target-WebProcess failure rather than the old
whole-UI-process SIGSEGV, but it is still the blank-window failure from a
client's perspective.

One installed-MiniBrowser discriminator ties the document loss to
zigBrowser's configuration. Repeating the same two-hop chain with only
`--hardware-acceleration-policy=never`, matching
`src/webkit_shim.c:1085-1090`, produced `WebProcess CRASHED` within 20 seconds
while MiniBrowser's UI shell remained alive. The default-policy MiniBrowser
run did not emit that crash. No GBM or DRM line appeared in either Xvfb run,
so this result is not an NVIDIA-path reproduction. It makes the `NEVER` policy
the probable trigger for zigBrowser's 2.54.0 target-document loss; the
default-policy MiniBrowser's all-black popup is a separate presentation
failure and prevents treating that control as healthy.

The restarted live 2.54.0 log was inspected read-only and confirms that the
package upgrade also does not remove the physical NVIDIA errors. At the time
of inspection it already contained 24 `DRM_IOCTL_MODE_CREATE_DUMB` permission
failures and three NVIDIA `nv_gbm_create_device` failures. The frozen 2.52.6
log contained 78 and nine respectively, plus six explicit `Failed to create
GBM buffer` messages. Counts are not directly comparable because the logs
cover different run lengths, but the error class persists. Xvfb has no NVIDIA
path, so changing the production acceleration policy still requires a
user-authorized real-presentation matrix on DISPLAY `:0`.

The proposed opt-in package-qualification test remains required and is now a
known failing test on 2.54.0: open the public watch URL through the two-hop
fixture and, at 10 and 35 seconds, require the UI and target WebProcess to be
alive, the target URL/title to remain populated, a side-effect-free evaluation
to succeed, and real X11 pixels to be nonblack. Add a MiniBrowser
`hardware-acceleration-policy=never` control. Independently connect WebKit's
`web-process-terminated` signal and record its reason and `window_id`; without
that diagnostic, zigBrowser silently turns the target into an empty window.
The finding and reproducer contract were mailed to BlackRobin as Agent Mail
5039.

The required pre-commit gate used a clean `git archive` of exact HEAD
`61a62ea`, a private Xvfb display, unset `DISPLAY`, `WAYLAND_DISPLAY`, and
`ZIGBROWSER_SOCKET`, and a 1500-second bound. It reported **86/88 steps
succeeded (1 failed); 685/685 tests passed**. The only failed step was
`automation-scroll`, with `hover moved away: expected False, got True`. That
is the WebKitGTK-2.54.0 upgrade regression that BlackRobin reproduced 5/5 on
clean `cf004fe` and 5/5 on the harness tree; BlueBeaver's preceding gate also
failed only that step. No additional failure appeared. The disposable gate
tree and its Xvfb were deleted by the `find -delete` exit trap.

## Social owner-scope, launcher ownership, and acknowledgement follow-ups

Reviewed commits `61a62ea`, `38a1e78`, and `e112995` against the redacted live
probe captures and their exact committed blobs. The full clean-export gate at
`61a62ea` is recorded immediately above; it exercised both earlier commits too
and had 685/685 tests pass, with only the independently reproduced WebKitGTK
2.54 hover-ordering step failing.

### BLOCKER — story ownership is checked after, not before, the next click

**Status: CLOSED by `d91eba9`; approved as Agent Mail 5068.** The Instagram probe supports
the new selectors: the page-behind zero-sized button is inside `<main>`, while
the viewer's SVG-backed role button and video are outside it. The selectors at
`src/instagram.zig:45-46` therefore exclude the observed page-behind target,
require the exact `Next` label, and the flow refuses zero or multiple matches.
However, the loop at `src/instagram.zig:175-190` counts and clicks Next before
calling `onStories`/`isStoryOf`. If Instagram auto-advances during the frame
pause, the next iteration can click the other account's Next once before the
URL check detects the change. The tests at `tests/instagram_test.zig:284-300`
and `tests/e2e/social_flows_test.py:223-228` cover only a transition caused by
the flow's preceding click, not an automatic transition before the next click.
Add a pre-click ownership check on every iteration and a regression that changes
the URL during the pause and proves no later `dom.click` is dispatched.

`d91eba9` performs that check at the top of every frame iteration, before
counting or clicking Next, and retains the post-click ownership check. Its
deadline reserve now covers all three per-frame queries, the click, and the
viewing pause. Unit regressions cover an automatic transition during both the
first and a later frame, assert that no later query/click occurs, and pin the
budget boundary. The production-chain e2e makes the fixture advance from
`auto.user` to `riley.sample` on its own and requires Riley's frame list to
remain `[1]`.

Failing-first was observed directly in the earlier shared-worktree gate: its
browser had compiled the old flow, while the newly edited fixture and Python
test were read later at runtime. The old flow advanced Riley to `[1,2]`, so
the regression caught the real wrong-story click. This was a mixed-snapshot
gate, not an intermittent test race. With the fix, clean exports passed first
at `793e55f` plus the four-file overlay (**88/88 steps, 691/691 tests**) and
then at exact `6f90a1a` plus that same now-committed content (**88/88 steps,
693/693 tests**). `social-flows` passed both. Both export/cache pairs were
deleted by their `find -delete` traps.

The LinkedIn half passes the wrong-person review. The probe has exactly one
`//main//section[@aria-label="Primary content"]`; it holds one visible owner
Connect, one hidden owner Connect, and one visible owner Follow. The visible
aria-hidden toolbar clone is outside `<main>`, and recommendation actions are
in an `<aside>` outside that section. `profileNameFromTitle` derives the exact
owner name from `<Name> | LinkedIn`; `clickProfileAction` scopes every candidate
to that owner area, excludes aria-hidden ancestry, waits for visibility,
requires exactly one positive-size bbox and exactly one owner area, and then
strict-clicks only the owner-scoped indexed selector
(`src/linkedin.zig:80-131,418-493`). Zero or multiple visible candidates fail
closed. The socket e2e renders sidebar, toolbar, hidden-copy, same-name, and
duplicate-owner decoys and records every wrong target
(`tests/e2e/social_flows_test.py:137-167`). Fixtures contain only the plainly
synthetic `Sam Example` and `Riley Sample`; no probe identity was copied.

### `38a1e78` launcher ownership

**Status: APPROVED; BLOCKER 5011 CLOSED; mailed as Agent Mail 5050.**
`xsession.py` execs into the browser, gives it a dedicated process group, and
starts a detached guardian that uses pidfds for both driver and browser. Driver
death drains the browser group; browser-first exit gives helpers eight seconds
then drains them; only then does the guardian terminate its private Xvfb and
remove its owned lock/socket/auth directory. `detect_runner` always supplies
this launcher, including for an existing private display, and the three former
self-launching scripts were migrated. `stop_browser` retains a clean SIGINT
grace and group-kills only a browser still running. On a clean archive of the
commit, `harness_group_test.py` passed all five cases: Xvfb driver SIGKILL,
Xvfb driver SIGTERM, explicit stop, browser-first child-left, and existing-
display driver SIGKILL.

Failing-first was independently verified by changing only `detect_runner` in
that clean export back to the exact old `xvfb-run -a` launch shape while
retaining the new regression. Its Xvfb/SIGKILL case reported that zigBrowser,
the WebKit network and web processes, Xvfb, and xvfb-run all survived the
driver, together with the X lock, socket, and auth directory. The regression's
PID-targeted cleanup then removed them; a post-run process and residue check
was empty. All launcher-review trees were deleted immediately.

### `e112995` acknowledgement retry

**Status: APPROVED; mailed to cc_1 as Agent Mail 5049.** A timed-out
one-second acknowledgement read is now retried inside `AckTracker.read` until
the caller's absolute deadline. A real `null` remains reserved for a page on
which no automation script answers, non-timeout errors still propagate, and a
deadline still returns `Timeout`; debt ownership and clearing are unchanged.
That removes the false `DocumentReplaced` path in `waitScrollSettled` without
re-dispatching input. The new `{moving}, lost, {quiet}` regression exercises the
same tracker used by production rather than bypassing it
(`src/automation_gtk_port.zig:406-425,993-1006`).

An independent clean-export filtered build ran module reachability plus the
new acknowledgement regression: **5/5 steps, 3/3 tests passed**. Replacing
only `AckTracker.read` with the exact parent behavior while retaining the test
failed it at `waitScrollSettled` with `DocumentReplaced` (**2/3 passed, 1
failed**). This verifies the claimed red-before behavior. The disposable tree
and its cache were deleted immediately with `find -delete`.

### BLOCKER — `53b5c66` turns post-move document replacement into success

**Status: CLOSED by `6f90a1a`; approved as Agent Mail 5067.** PagePort v3.7 and the
trusted-mousemove position acknowledgement correctly close the WebKitGTK 2.54
move/evaluation ordering race, and the engine settles only the final hover move.
But `AckTracker.settleMove` returns success when the acknowledgement comes from
a different document (`src/automation_gtk_port.zig:481-495`), after which
`settleHover` returns `{ok:true}` (`src/automation/engine.zig:811-819`). A
humanized hover has already dispatched one or more moves at that point. Fixed
N8 rule 4 requires `document_changed`, with no relocation, and the pointer cache
must retain the last position actually dispatched. The new GTK test explicitly
pins the contrary “new document counts as delivered” behavior and there is no
engine test for document replacement during settle. Return `DocumentChanged`
from the adapter, map that post-dispatch case to the public
`element_not_found`/`document_changed` result, and cover both single and
multi-move humanized hover.

`6f90a1a` makes the production GTK tracker return `DocumentChanged` on a new
document and clears only the pending settle target. The engine treats that
post-dispatch outcome as terminal `element_not_found` with reason
`document_changed`, never relocation. The adapter regression is red on
`53b5c66` (which returns success); the engine regressions cover single and
humanized hover, one settle, no second locate, and the cached pointer remaining
at the last dispatched move. The exact combined clean-export gate recorded
above passed **88/88 steps and 693/693 tests**, including `native-hover` and
`automation-scroll`.

The `6f90a1a` commit message's own 86/88 pre-commit result calls its social
failure intermittent. That attribution is superseded: the run was the
mixed-snapshot failing-first case described above. The later clean combined
gate is the green evidence for this commit; history was not rewritten.

The independent clean-export gate at exact `53b5c66`, under a private Xvfb
and with live-display/socket variables unset, was fully green: **88/88 steps
succeeded; 689/689 tests passed**. Native hover, automation-scroll,
social-flows, and all five launcher-hygiene cases passed. A fixture-server
BrokenPipe during a canceled response did not fail its social-flow test. The
export and cache were deleted by the `find -delete` exit trap. This green gate
does not waive either semantic blocker above.

## Web-process diagnostics and rendering startup review (`1c4d0d8`)

**Status: APPROVED; both SHOULD follow-ups are now closed.** The rendering
wording was corrected by `ee00876`, and the popup crash-attribution regression
landed in `20e0265`. No production blocker was found.
The review used the exact committed blobs, not the later shared-worktree HEAD.
It did not access DISPLAY `:0`, the live socket, or the live browser.

The dead-process reason follows the production chain. Every `ZbWindow` owns a
GTK-thread-only static-string termination field and its own
`web-process-terminated` handler (`src/webkit_shim.c:116-120,1138-1139`). The
handler maps all WebKitGTK 2.54 reasons, conservatively maps an unknown future
reason to `crashed`, stores the result on that signal's window, and prints the
numeric window id and reason to stderr
(`src/webkit_shim.c:4122-4145`). Intentional window destruction disconnects the
handler before the last related view's process can be terminated, so a normal
`page.close` is not misreported (`src/webkit_shim.c:834-843`). A committed load
clears the prior reason (`src/webkit_shim.c:942-945`). The GTK window snapshot
serializes the reason on that same window, the Zig bridge parses it into the
closed `Termination` enum with owned URL/title cleanup on every error path, and
the server emits the public optional `crashed` field
(`src/webkit_shim.c:3810-3838`, `src/automation_gtk_port.zig:177-212`,
`src/automation_server.zig:708-723`). No borrowed C string crosses the shim;
only the snapshot JSON does.

`tests/e2e/web_process_crash_test.py:88-134` drives the real binary through its
Unix socket, kills its actual WebKitWebProcess, then proves `page.list` reports
`window-1` as `crashed`, stderr reports `window 1` plus `crashed`, and a later
committed navigation clears the field. This does not bypass the C signal,
PagePort parser, or server serializer. **SHOULD CLOSED by `20e0265`:** extend it with a
popup/related-view case and assert that the reported field and stderr id belong
to the affected popup (and that an unaffected window is not marked). The
production handler is correctly per-window, but the current e2e only exercises
the primary window, so a future accidental primary-window assignment would not
be caught.

The rendering defaults remain unchanged in both layers: the pure default is
`NEVER` plus no renderer environment (`src/render_config.zig:31-34,105-108`),
and the C fallback is initialized to `ZB_HW_POLICY_NEVER`
(`src/webkit_shim.c:165-167`). `runOpen` applies the resolved config before
profile setup, automation threads, WebKit context/view construction, EGL, and
child processes (`src/app.zig:36-62`; `src/webkit_shim.c:4699-4735`). Every
new main or popup view reads the same atomic policy before loading
(`src/webkit_shim.c:1103-1111`), and the live policy test checks both. Renderer
flags set only their documented environment variable, preserve even an empty
user-set value, and the external e2e reads the actual WebKitWebProcess
environment (`src/webkit.zig:40-66`; `tests/e2e/render_config_test.py:60-135`).
The CLI accepts only `never|always|webkit` and
`default|shm|mesa-egl`; missing, unknown, underscore-spelled, and duplicate
values become usage (`src/cli.zig:108-118,311-329`).

The supplied NVIDIA/X11 matrix supports the implementation's cautious default:
the original C/NEVER control lost its target WebProcess by 35-40 seconds, while
J (WebKit policy plus force-SHM) and L (WebKit policy plus Mesa EGL) retained two
WebProcesses through 60 seconds. The fresh J and L samples have changing,
non-uniform pixels and live video state; J still recorded two DRM-dumb and two
NVIDIA-GBM setup errors, while L recorded none of those three classes. This is
stronger automated presentation evidence than the earlier 24-bpp samples, but
the review artifacts contain no record of the watching user's verbal verdict.
**SHOULD CLOSED by `ee00876`:** narrow `src/render_config.zig:6-8` and
`docs/how-to-run.md:77-78`. “Every/any other non-DMABUF path died” is broader
than the data and reads as contradicting the surviving force-SHM case. The
matrix specifically establishes failure for policy NEVER and for the tested
`WEBKIT_DISABLE_DMABUF_RENDERER=1` combinations.

The independent clean-export gate at exact `1c4d0d8` used fresh local/global
Zig caches, a private Xvfb, unset `DISPLAY`, `WAYLAND_DISPLAY`, and
`ZIGBROWSER_SOCKET`, and a 1500-second bound. It reported **90/90 steps
succeeded; 700/700 tests passed**. Both new production-chain e2es passed. The
export and caches were deleted immediately by the `find -delete` trap.

## Node live-test launcher follow-up (`5c7d5dd`)

The production-representative Node live test now launches its browser through
`xsession.py --xvfb`, strips the caller's display variables, and uses the
browser/session-leader PID for bounded SIGINT then process-group SIGKILL
(`sdk/node/tests/live.test.ts:42-67,76-114`). This correctly closes the direct
spawn gap left by BLOCKER 5011. The launcher's guardian watches the Vitest
worker (the launcher's parent) and the browser; killing that worker therefore
drains the browser group and private Xvfb. The opt-in regression passed locally,
the plain Node live test passed 1/1, and neither left a browser, helper, Xvfb,
display lock, or socket on their successful paths.

### BLOCKER — the kill regression's own outer Xvfb can be orphaned

**Status: CLOSED by `34238a3`; approved as Agent Mail 5090.** The regression creates a
second Xvfb directly with `subprocess.Popen` to provide Vitest's caller display
(`tests/e2e/node_live_group_test.py:97-115,143-150`). That Xvfb has neither the
`xsession.py` guardian nor a parent-death signal. If the Python regression is
itself SIGKILLed, or its required outer `timeout` expires and sends SIGTERM,
Python's `finally` does not run; the Xvfb and its lock/socket can outlive the
test. This recreates the test-hygiene failure class the regression is supposed
to catch. Its caught-exception path also calls `kill_marked` before cleanup
(`tests/e2e/node_live_group_test.py:190-206`), which can SIGKILL the marked
inner Xvfb and guardian together before the guardian removes its display
files.

Add a failing-first meta-regression: start `node_live_group_test.py` with a
unique inherited marker, wait for its outer Xvfb and display files, SIGKILL the
Python test process (not Xvfb), and require all marked processes and display
files to disappear. Prefer giving the outer Vitest/Xvfb pair to
`xsession.py --xvfb`; alternatively give Xvfb a parent-death signal and an
independent lock-owner cleanup path. On caught failure, let the guardians clean
before any last-resort direct Xvfb kill. This blocker is isolated to the new
opt-in regression; the Node live-test launcher itself is correct.

The claimed failing-first behavior is independently confirmed. In a clean
`5c7d5dd` export, changing only `startBrowser` back to direct binary spawn while
retaining the new hold hook made the regression fail after 30 seconds with the
browser, WebKit network process, and WebKit web process still alive. The fixed
launcher passed the same regression, and the ordinary Node live test passed
1/1. Each run's marked processes were gone afterward and the export was deleted
immediately. Thus the test catches the production leak, but its separately
owned outer Xvfb still makes the test process itself unsafe under a hard kill.

**SHOULD (cc_2), mailed as Agent Mail 5079:** `docs/how-to-test.md` says the
Node Vitest live test and the Python regression both exit 77 when prerequisites
are missing. The Python entry point does; Vitest uses `describe.skip`, so it
exits successfully with a skipped suite. The WebKitGTK 2.54 known-issues text
is otherwise accurate after `ee00876`: the hover closure needs both `53b5c66`
and `6f90a1a`, and case J is now the documented Linux default.

`34238a3` arms the outer Xvfb with Linux `PR_SET_PDEATHSIG(SIGTERM)` and
vitest with `PR_SET_PDEATHSIG(SIGKILL)`, including the post-`prctl` parent-race
check. Its caught-failure path now ends vitest and marked workers first, gives
the launcher's guardian time to drain its browser and private Xvfb, and only
then applies marker-scoped SIGKILL cleanup; display-file removal additionally
requires that the lock name the killed Xvfb PID. The new meta-regression kills
only `node_live_group_test.py` and requires that its direct-child outer Xvfb,
lock, and socket disappear. The recorded failing-first run left Xvfb plus both
display files on the old test and passed after the change. Documentation now
correctly distinguishes the Python checks' exit-77 skips from Vitest's
successful `describe.skip` result, closing SHOULD 5079 as well.

Independent bounded runs at exact `34238a3` passed both opt-in tests:
`node_live_group_kill_test.py` and `node_live_group_test.py`. Their private
displays `:450` and `:201` had no remaining process, lock, or socket. cc_2's
fresh clean-export gate reported **90/90 steps succeeded; 704/704 tests
passed**. No live display or live browser was accessed.

## Linux case-J rendering default (`ee00876`)

**Status: APPROVED; mailed to cc_1 as Agent Mail 5081.** The exact diff makes
the Linux built-in choice WebKit's own hardware-acceleration policy plus
`WEBKIT_DMABUF_RENDERER_FORCE_SHM=1`. Each command-line half resolves
independently, an existing environment value (including `0` or empty) wins,
and `setenv` uses `overwrite=0`. Invalid, missing, and duplicate rendering
flags still fail as usage. The shared C policy helper leaves WebKit untouched
for `ZB_HW_POLICY_WEBKIT` and is used by main views, related popups, and the
screenshot view. The screenshot path applies HTTP and rendering configuration
before constructing WebKit state.

The tests drive production seams rather than fakes: the live test compares a
real window's policy with a fresh `WebKitSettings` default, and
`render_config_test.py` inspects the spawned WebKitWebProcess environment for
the default, user override, both opt-outs, and Mesa path. It also exercises the
real screenshot process and checks that a PNG is written. The failing-first run
reported 10 failed assertions against the `74af56c` binary; the new binary
passed all 18 assertions. cc_1's bounded clean-export gate at the exact commit
reported **90/90 steps succeeded; 704/704 tests passed**.

An independent quiet clean-export gate at exact `ee00876`, with the live
display/socket variables unset and a private Xvfb, produced the same result:
**90/90 steps succeeded; 704/704 tests passed**. Its export and caches were
deleted immediately by the `find -delete` exit trap.

The supplied `rerun_JL.json` evidence matches the documentation. Case J
advanced video time from 4.6 to 29.9 to 54.6 seconds at the three samples and
had no GBM-buffer failures, while retaining two DRM-dumb and two NVIDIA-GBM
startup lines. Case L rendered but video time moved 2.9, 5.4, then backward to
3.8 seconds. The docs therefore accurately explain why the user chose J, and
the previously overbroad non-DMABUF statement is now limited to policy NEVER
and the tested `WEBKIT_DISABLE_DMABUF_RENDERER=1` combinations. No live display
or live browser was accessed during this review. The popup-specific crash-
diagnostic SHOULD recorded under `1c4d0d8` is closed by `20e0265`.

## Flow-level dry run (`7d0fa8a`)

**Status: APPROVED; mailed to cc_2 as Agent Mail 5097.** The exact committed
diff implements `options.dry_run` only for the ten acting flows in the brief.
The social routes branch around admission, reservation, pacing, commit, and
the persistence hook at `src/automation/social_flow_routes.zig:216-251`; the X
routes do the same at `src/automation/x_routes.zig:162-217`. The dry paths
branch before every real input sequence. Their only action-shaped operations
are `dom.click` trials: there is no real click, fill, type, press,
`selectOption`, native locate/dispatch, or frame-viewing pause. In particular,
X branches before draft clearing and typing at `src/x.zig:145-164` and only
trials the composer and, for scheduling, the schedule option at lines 186-218.

LinkedIn Connect and Follow reuse the real flow's extracted
`resolveProfileAction` path. The owner area must match exactly once, the
title-derived owner label must have exactly one visible copy, and ambiguity
fails closed before the trial (`src/linkedin.zig:399-423,529-571`). Instagram
story dry run checks the requested user's story before resolving Next, never
pauses on or advances a frame, rejects multiple Next controls, and stops
before a View-story gate. Its unavoidable direct navigation may mark the first
frame seen; the result and documentation disclose that side effect instead of
claiming otherwise.

The route tests assert unchanged persisted limiter state, hook count,
`in_flight`, remaining actions, and sleep count, including at the daily cap.
The real-binary fixture tests install page-level pointer, key, and edit
recorders before platform handlers and prove all ten paths leave those
recorders and page state untouched. The recorded mutation replacing the trial
with a real click is killed by both social and X E2Es, so the tests do not
bypass the production dispatch boundary. cc_2's clean-export gate reported
**90/90 steps succeeded; 724/724 tests passed**.

**SHOULD (cc_2), mailed in Agent Mail 5097:**
`sdk/node/src/methods.ts:331` makes a widened runtime `boolean` return only the
normal result type. A caller with `const flag: boolean` can receive a
`DryRunResult` at runtime, but `FlowResult<O, R>` currently exposes only `R`.
Literal true should remain `DryRunResult`, literal false/absence should remain
`R`, and widened boolean should be `DryRunResult | R`, with a compile-time
test. This is an SDK type-safety issue, not a weakness in the zero-event
runtime contract.

`ede6dbf` improves this by returning the union for a widened `boolean` and an
optional `dryRun`, and it adds a real `tsc` compile-time suite. Its
`"dryRun" extends keyof O` extractor is non-distributive. For
`O = {dryRun:true} | {}`, `keyof O` lacks `dryRun`, so the SDK again exposes
only the normal result although the runtime can return `DryRunResult`. An
independent TypeScript equality assertion reproduced the failure. The owner
gate at `ede6dbf` was otherwise green at **90/90 steps, 724/724 tests**.

**Status: SHOULD CLOSED by `14676f3`; approved in Agent Mail 5111.** The
extractor now distributes over every union member and the public SDK type suite
adds both `{dryRun:true}|{}` and false-or-true union calls. The dedicated type
suite and the whole Node SDK passed. The full Zig gate also reported **90/90
steps, 724/724 tests**, but overlapped cc_1's bounded WebKit mutation runs; it
is recorded as green under concurrent load, not as a quiet acceptance gate.

## Committed-load watchdog and popup crash attribution (`20e0265`)

**Status: APPROVED; legacy watchdog and popup-diagnostic SHOULD CLOSED.** The
committed production diff resets `load_committed` on STARTED, sets it on
COMMITTED, clears the timer's source id in its own callback, and lets a
committed document keep loading while releasing first-load readiness
(`src/webkit_shim.c:372-392,749-795,951-984`). A never-committed related view
still gets LOAD_FAIL and `stop_loading`, but does not terminate the WebProcess
shared by live siblings. The retained termination branch still ends a lone
never-committed window. All of these transitions stay on the GTK main thread;
the change introduces no new cross-thread object or string lifetime.

The expanded popup crash test uses the real binary and socket, kills the actual
isolated WebProcess, and requires only that popup's page-list and stderr reason;
it then kills the shared process and requires both related ids, while checking
preserved sibling state after the isolated kill
(`tests/e2e/web_process_crash_test.py:86-187`). It does not bypass the WebKit
termination signal, GTK snapshot, PagePort parser, or server serialization.

The two early test gaps were resolved in the later working diff (Agent Mail
5108). The related-window request issued before 15 seconds must not answer
before 14.8 seconds, so readiness-at-COMMITTED is caught. A new sole
never-committed-window phase requires one LOAD_FAIL, exact
`page.list.crashed == "terminated_by_api"`, and exact window-1 stderr, so
removing the retained last-window `terminate_window_web_process` branch is
caught. The final committed test is a gate step (`build.zig:574-583,804`). It
also checks a committed slow page at 14 and 16 seconds, retained process
identity, absence of LOAD_FAIL/termination, nonblank screenshot pixels, a
related never-commit popup that answers after being stopped, and the exact
lone-window termination recovery
(`tests/e2e/slow_load_watchdog_test.py:184-248,251-390`).

The owner additionally mutation-checked both repaired oracles before the
formal gate (Agent Mail 5113): releasing readiness at COMMITTED made the
pre-timer call answer at 14.0 seconds and fail the 14.8-second lower bound;
removing termination from the lone never-commit branch failed both the
`terminated_by_api` page-list assertion and the exact stderr assertion.

The pre-change binary failed the 14-second calls at the 15-second boundary and
marked every related window `terminated_by_api`. The owner's clean gated
snapshot passed **91/91 steps, 724/724 tests**. An independent quiet clean
export of exact `20e0265`, with live display/socket variables removed, a fresh
cache, private Xvfb, and a 1500-second bound, also passed **91/91 steps,
724/724 tests**, seed `0x9f557033`. The disposable tree was deleted by its
`find -delete` trap; neither DISPLAY `:0` nor the live browser was accessed.

**SHOULD (cc_1, pre-existing diagnostic noise):** normal SIGINT shutdown and
post-main teardown terminate views before disconnecting
`sig_web_process_terminated` (`src/webkit_shim.c:1268-1285,4795-4808`), so a
healthy exit prints `terminated_by_api` for ordinary windows. It is harmless
to state and does not weaken the watchdog or crash-attribution regressions, but
the diagnostic is misleading and should be suppressed just as normal
`page.close` already suppresses it.

## Instagram media deadlock investigation (`ac7450d`, WebKitGTK 2.54.0)

**Status: BLOCKER (cc_1 / upstream WebKit); high-confidence root cause; mailed
as Agent Mail 5135.** The affected WebProcess did not stall in rendering,
NVIDIA, networking, or zigBrowser's GTK hand-off. Its main thread was wedged in
WebKit's MSE seek flush, in a two-thread GStreamer lock cycle. The frozen
884-line stack was symbolized against the exact installed WebKitGTK 2.54.0 and
GStreamer 1.26.2 binaries:

1. WebProcess main TID 3500107 entered
   `MediaPlayerPrivateGStreamerMSE::doSeek`, held the pipeline state lock, and
   called `gst_element_seek` (`MediaPlayerPrivateGStreamerMSE.cpp:282-297`).
2. `WebKitMediaSrc` handled that seek synchronously on the main thread and
   pushed `FLUSH_START` downstream from `webKitMediaSrcStreamFlush`
   (`WebKitMediaSourceGStreamer.cpp:649-690`).
3. `gst_multi_queue_sink_event` forwarded/flushed the queue and called
   `gst_pad_pause_task` (`gstmultiqueue.c:2683-2690`). That call waits for the
   pad task by acquiring its stream lock (`gstpad.c:6477-6512`).
4. TID 3500391 owned that multiqueue source-task stream lock but was asleep in
   `do_probe_callbacks` / `GST_PAD_BLOCK_WAIT` while pushing a queued sticky
   event (`gstpad.c:3850-3935`, `gstmultiqueue.c:2067-2072`).

The exact lock endpoints and MSE seek/flush chain are proven. The downstream
blocking probe is very likely playsink reconfiguration, but its pad name was
not captured, so that subtype remains an inference. The observed sequence is
consistent with a page `currentTime` change or equivalent seek while the MSE
pipeline was being reconfigured; it does not require a GPU-present path and
explains why scrolling could still expose redraw while page script, title,
and input stopped answering.

The closest upstream match is open WebKit bug
[#320336](https://bugs.webkit.org/show_bug.cgi?id=320336) and its still-open,
unmerged [PR #70222](https://github.com/WebKit/WebKit/pull/70222). That change
moves MSE flush events from the main thread to streaming threads specifically
to break the main-thread/multiqueue/playsink cycle. Its reported trigger is
encrypted video plus clear audio waiting for a DRM response; this capture has
no identifiable EME/decrypt frame, so the DRM trigger is not proven even
though the deadlock mechanism matches. Open bug
[#272975](https://bugs.webkit.org/show_bug.cgi?id=272975) is the strongest
unencrypted/early-link variant: `FLUSH_START` is lost at an unlinked
multiqueue source, then a sticky `STREAM_START` blocks at a pad probe. Its WIP
[PR #27517](https://github.com/WebKit/WebKit/pull/27517) is also unmerged.
GStreamer [MR 6763](https://gitlab.freedesktop.org/gstreamer/gstreamer/-/merge_requests/6763)
fixed one streamsynchronizer ordering case, but the WebKit report explicitly
records that the relevant MSE test still hangs after it. WebKit bug 320329 is
only analogous: its other side is a WebKit repaint/ParkingLot wait, absent
from this capture.

### Private-Xvfb reproducer and env matrix

A throwaway clean export of exact `ac7450d` served local H.264/AAC and VP9/Opus
clips. Six muted autoplay players were scrolled, sought, paused/played, and
removed/recreated every 40 ms. The fragmented-H.264/AAC variant used
`MediaSource`; an external socket client polled `page.title` and a monotonic
page counter. On a failed run, out-of-band `page.list` still returned the
cached title and URL while the isolated-world title call failed to answer.
`eu-stack` of the throwaway WebKitWebProcess captured the same
`doSeek -> webKitMediaSrcStreamFlush -> gst_pad_pause_task` main-thread chain
and the same pad blocking-probe streaming thread as the live incident.

The deliberately aggressive fixture is a statistical race, not a claim about
normal failure frequency. Its bounded results were:

| Fixture / environment | Result | Interpretation |
| --- | --- | --- |
| Plain URL, default | 2/4 responsive, 2/4 exceeded 4 s | Short responsiveness misses occurred; this oracle alone does not prove a permanent deadlock. |
| Plain URL, `WEBKIT_GST_USE_PLAYBIN3=0` | 3/4 responsive, 1/4 exceeded 4 s | This is the default choice for ordinary media, not an MSE switch. |
| Plain URL, `WEBKIT_GST_USE_PLAYBIN3=1` | 0/4 responsive | Forcing ordinary media onto playbin3 made short misses deterministic in this sample. |
| MSE, default / `=0` / `=1` | Every setting produced a failed run with the 4 s oracle | WebKit's MSE path always uses playbin3; the later exact-stack captures distinguish permanent hangs. |
| MSE, `=1`, 12 s liveness bound | 1/1 wedged with the exact live stack | `=1` is redundant for MSE and is not a mitigation. |
| MSE, `WEBKIT_GST_DMABUF_SINK_DISABLED=1` | 1/2 wedged with the exact stack | Disabling the DMABUF sink does not break the lock cycle. |
| MSE, `WEBKIT_GST_DISABLE_GL_SINK=1` | 2/2 wedged with the exact stack | Disabling the GL sink does not break the lock cycle. |

WebKitGTK 2.54.0's production selection explicitly makes MSE, Blob, and
MediaStream use playbin3; `WEBKIT_GST_USE_PLAYBIN3=1` only opts ordinary media
into it (`MediaPlayerPrivateGStreamer.cpp:3548-3563`). Therefore setting that
variable to `0` cannot force MSE to legacy playbin and is not a workaround.
The two sink variables are presentation/transport switches, while the captured
cycle occurs upstream in MSE flush, multiqueue, and a pad probe. No tested
environment variable stopped the defect. All private Xvfb instances, browser
processes, profiles, caches, and the throwaway export were deleted immediately.
Neither `DISPLAY :0` nor the live socket/process/profile was accessed.

### Required failing test and watchdog direction

The useful failing-first test is an external-watchdog MSE fixture with audio
and video SourceBuffers. It should append init/video while delaying or
withholding audio, seek during early construction/reconfiguration, and assert
from outside the WebProcess that the page main loop continues answering. It
should loop with bounded duration and retain `GST_DEBUG` pad/event names on
failure. A second variant can delay an EME response to exercise PR 70222's
published trigger. PR 70222 currently adds no regression test.

Recovery should be a user-confirmed safety mechanism, not an automatic kill:

- Subscribe on the GTK thread to WebKitGTK's
  `notify::is-web-process-responsive`, debounce continuous `false`, and expose
  an out-of-band `page.health` route that cannot sit behind the affected
  page's FIFO. A return to `true` cancels the incident.
- Report `dialog_open` and `loading` separately. A script dialog blocks related
  views by design, and finite CPU-heavy JavaScript is indistinguishable from a
  deadlock for part of its run, so `false` is only
  `suspected_unresponsive` and never triggers termination itself.
- Make `page.recover` two-phase: require the current incident token and an
  explicit acknowledgement of every window at risk. Related views can share a
  WebProcess, while WebKit exposes no public OS-process PID mapping and the
  app's creation-time `process_group` is only an approximation after process
  swaps. The safest default is to refuse recovery while another live window
  exists unless the caller explicitly accepts the multi-window blast radius.
- On confirmation, install a recovery gate, cancel/complete affected tracked
  jobs exactly once, call `webkit_web_view_terminate_web_process`, wait for
  `TERMINATED_BY_API`, invalidate document/input/pointer state, and only then
  offer reload from captured URLs. Do not imply preservation of in-memory page
  state. Commands arriving during recovery must fail as recovering rather than
  run against an empty replacement document.

Current production already provides the pieces but not the health layer:
normal page methods acquire a per-window FIFO (`src/automation_server.zig:482-533`),
while `page.list` bypasses it (`:657-744`); native work is abandoned/cancelled
at its deadline (`src/webkit_shim.c:1552-1609,2122-2147`). The shim connects
`web-process-terminated` but not responsiveness
(`src/webkit_shim.c:1141-1169,4150-4174`). WebKitGTK 2.54 exposes both
`webkit_web_view_get_is_web_process_responsive` and
`webkit_web_view_terminate_web_process`; no public getter exposes the actual
WebProcess PID. Existing crash E2E covers an external kill followed by an
explicit navigation, but not responsiveness, recovery consent, shared-process
blast radius, queued-job cancellation, or terminate-plus-reload.

Verification: a quiet clean-export gate at exact HEAD `907c204`, under a
private Xvfb with the live display, socket, and token variables removed, was
green: **Build Summary: 91/91 steps succeeded; 728/728 tests passed** (seed
`0x8759c85c`). The throwaway export was deleted when the gate completed.

## Media Source opt-out review (`c0c1c18`)

**Verdict: APPROVED as an opt-in mitigation; it removes the reproduced MSE
path, but it is not a general cure for GStreamer media hangs.** The upstream
WebKit/GStreamer blocker remains open, and Instagram's behavior with the
switch is not live-qualified.

The production chain is complete and fail-closed at startup:

- `src/media_config.zig:16-42` accepts exactly `on` or `off`, keeps the default
  `on`, and resolves flag over environment over default. An invalid
  `ZIGBROWSER_MEDIA_SOURCE` value is reported and falls back to `on`.
- `src/cli.zig:54-99,102-186` accepts the option once for normal and screenshot
  modes and rejects missing, duplicate, or non-exact values. `src/app.zig:36-67`
  applies it before `zb_app_run` creates the first WebView; the screenshot
  path applies it before its load (`src/app.zig:111-119`).
- Every `zb_window_new`, including views created through
  `webkit_web_view_new_with_related_view`, applies the effective setting
  before loading (`src/webkit_shim.c:1128-1144`). The screenshot view does the
  same at `src/webkit_shim.c:5285-5290`.
- WebKitGTK 2.54.0 ignores `enable-mediasource=false` by itself, so
  `src/webkit_shim.c:4596-4627` also installs a page-world, all-frame,
  document-start script that removes the MSE constructors. The per-content-
  manager marker prevents duplicate installation in related views. The switch
  does not alter the automation isolated world.

The new production-binary E2E does not stop at an internal setting getter. It
checks page-visible constructors in the primary view, a same-origin related
popup, a cross-origin noopener popup running in another WebProcess, and a
dynamically created `about:blank` iframe. It also checks screenshot mode,
default `on`, explicit `on`/`off`, environment precedence, and invalid values
(`tests/e2e/media_source_test.py:47-204`). It passed independently. Thus popup
inheritance is exercised through the real creation and page-script chain.

### Private-Xvfb behavioral matrix

The same six-player fixture used for the `d87ca04` investigation served local
H.264/AAC and VP9/Opus files, scrolled, sought, paused/played, and replaced a
player every 40 ms. The MSE variant used fragmented H.264/AAC. Each launch had
its own Xvfb, socket, profile, and process guardian. Liveness came from an
external `page.title` call, not an in-page watchdog.

| Fixture / configuration | Bound | Result | Interpretation |
| --- | --- | --- | --- |
| MSE-only, `--media-source off` | 2 x 15 s, 4 s response bound | **2/2 responsive**; page reported `mse-unavailable`; maximum post-readiness response 0.94 ms | The MSE constructors and therefore the reproduced MSE seek/flush path are absent. |
| MSE-only, `--media-source off` | 1 x 30 s, 12 s response bound | **1/1 responsive**; maximum post-readiness response 0.96 ms | No main-thread MSE hang occurred under the stricter bound. |
| Feature-detecting page, `--media-source off` | 1 x 15 s, 4 s response bound | **PASS**: chose `progressive`, `readyState=4`, remained unpaused, emitted two `playing` events, zero errors, and advanced through/looped the 12 s MP4 | A site that implements progressive fallback can still play ordinary `<video>`. |
| Pathological plain URL, `--media-source off` | 4 x 15 s, 4 s response bound | **0/4 met the bound** | The switch does not prevent a separate regular-media seek/event lockup under extreme churn. |
| Same pathological plain URL, `--media-source on` control | 4 x 15 s, 4 s response bound | **0/4 met the bound** | Matched control: the plain failure is not introduced by the opt-out. |
| Pathological plain URL, `--media-source off`, supplemental strict probe | 12 s response bound | Two launches remained unresponsive past 12 s; one WebProcess crashed before readiness with `g_mutex_clear() called on uninitialised or locked mutex` | A captured off-stack waits in `pthread_mutex_lock <- gst_element_send_event <- WebKit`; it has no `MediaPlayerPrivateGStreamerMSE::doSeek` or `webKitMediaSrcStreamFlush` frame. The same stack occurred with `on`. |

The exact live MSE deadlock is therefore removed when the option is off, and a
normal feature-detecting fallback plays progressive MP4. The adversarial plain
fixture establishes an important limit: regular playbin media can still hang
or crash when six videos are seeked and replaced every 40 ms. This is an
upstream residual, not a regression caused by `c0c1c18`, but the documentation
should say sites *that implement* a progressive fallback can use it rather
than implying that every video site necessarily does.

Neither `DISPLAY :0`, the live socket/browser/profile, nor a live site was
accessed. All evidence came from local fixtures under private Xvfb.

Verification at exact `c0c1c18`, from a clean archive export under private
Xvfb: **Build Summary: 92/92 steps succeeded; 736/736 tests passed** (seed
`0x396004d4`). The gate included the production-binary media-source E2E.

## Deferred formal reviews through `907c204`

These reviews use the exact committed snapshots, not the later shared-worktree
WIP. The three commits are a linear series (`0a211b0` -> `2609d04` ->
`907c204`). The already-recorded quiet clean-export gate at exact `907c204`
therefore covers the code and tests from all three: **Build Summary: 91/91
steps succeeded; 728/728 tests passed** (seed `0x8759c85c`). No reviewed
production or test blob was changed between its introduction and that gate.

### `0a211b0` handoff follow-up

**Verdict: APPROVED.** This is documentation only. The handoff accurately
distinguishes local-fixture tests from the orchestrator's read-only live probes
(`handoff:6,26-27,330-335`), documents the Linux HTTP/1.1 and case-J rendering
defaults and their opt-outs (`:79-101`), and replaces the obsolete dry-run
limitation with the committed `options.dry_run` behavior. It also keeps the
remaining SDK wrapper limitation narrow: the X wrappers have `dry_run` but not
`input`, `humanize`, or `timeout_ms` (`:595-599`).

The statement at `:318-323` that normal quit still emitted
`terminated_by_api` was true at this exact snapshot and explicitly named as a
follow-up; it is not stale within the commit. The immediately following
`2609d04` resolves it and updates the same handoff text. The selector and
wrong-person warnings remain fail-closed and the fixture names are identified
as invented (`:330-405`).

### `2609d04` quiet normal shutdown

**Verdict: APPROVED.** `window_stop_reporting_termination` disconnects only
the `web-process-terminated` signal and zeros its handler id
(`src/webkit_shim.c:271-286`). It is called before browser-owned termination
from `page.close`/window destruction (`:860-875`), signal-driven shutdown
(`:1272-1301`), and post-`gtk_main` teardown (`:4810-4825`). Real crashes and
the lone never-committed load watchdog do not call this helper, so their
diagnostics and `page.list.crashed` state remain intact. Disconnecting every
window before terminating the first view is necessary because related views
may share the web process; it also prevents a sibling callback from racing the
shutdown diagnostic.

The production-binary regression creates three windows in two web processes,
sends SIGTERM and SIGINT in separate runs, waits for browser exit, and asserts
that stderr has no termination report
(`tests/e2e/web_process_crash_test.py:195-248`). The same test file retains the
real SIGKILL crash and related-window attribution phases (`:91-190,274-323`),
so it does not obtain quietness by globally disabling the signal. The owner's
failing-first evidence reported that the pre-change binary printed all three
windows for both signals; the exact-`907c204` gate exercises the fixed E2E.

### `907c204` failed-step attribution, LinkedIn timeout, and story gate

**Verdict: BLOCKER (cc_2; Agent Mail 5149).** Most of the slice is correct:

- LinkedIn alone receives a 60-second navigation allowance, still clamped by
  the flow deadline (`src/linkedin.zig:215-218`); Instagram remains at 30
  seconds. The unit oracle checks both values
  (`tests/automation_social_test.zig:1158-1170`).
- The real `instagram.story_view`, not only its dry run, counts the
  `story_view_gate` after verifying the requested viewer and returns
  `instagram_story_view_needs_click` before any frame wait, pause, or click
  (`src/instagram.zig:151-173`). Unit and real-socket fixture tests assert that
  the gate is never clicked (`tests/instagram_test.zig:559-571`,
  `tests/e2e/social_flows_test.py:319-342`).
- Runner and trace step indexes advance on the same actually-executed command,
  and route-level refusals/platform detections clear attribution before
  `withFailedStep` can expose it (`src/automation/flow_runner.zig:79-121,
  250-258`; `src/automation/social_flow_routes.zig:255-262,543-561`).

The cancellation branch is the exception. A primitive returning JSON-RPC
`-32012 cancelled` first records its index at
`src/automation/flow_runner.zig:104-106`, then returns through the
`cancelled_step` branch at `:110-115` without clearing `failed_step`.
`social_flow_routes.takeFailure` sees the same trace index and appends the step
at `src/automation/social_flow_routes.zig:258-262`. This produces, for example,
`data.step = "navigate"` when the PagePort returns `error.Cancelled`, contrary
to both the commit contract and the public documentation that cancellation has
no step (`docs/how-to-automate.md:372-380`).

Required regression: make a `FlowHarness` navigation return
`error.Cancelled`, assert `-32012`, and assert that `data.step` is absent. The
fix must clear only cancellation attribution while preserving the terminal
stop/no-further-page-work behavior. The clean 728/728 gate is valid evidence
for the rest of the slice, but this path has no oracle and therefore does not
close the blocker.

**Status: CLOSED by `bbd5d74` (APPROVED; Agent Mail 5150/5151 superseded by
5155).** The follow-up clears `failed_step` only when the primitive's actual
failure code is `cancelled`, before the existing terminal return
(`src/automation/flow_runner.zig:104-117`). It retains the held `-32012` and
does not permit a scan, fallback probe, or later page step. If the external
cancel flag becomes set while a primitive independently fails for its own
reason, that primitive failure correctly keeps its attribution.

The exact requested regression sets `navigate_result = error.Cancelled`,
asserts code `-32012`, asserts no `data.step`, and confirms no evaluation ran
after navigation (`tests/automation_social_test.zig:1185-1197`). The owner
reported RED as `step: "navigate"`, then GREEN, followed by a clean-export,
private-Xvfb gate at exact `bbd5d74`: **Build Summary: 92/92 steps succeeded;
752/752 tests passed**. This closes the only blocker on `907c204`.

## LinkedIn More-menu Connect and shadow piercing (`c1bfeb3`)

**Historical verdict: BLOCKER (cc_2, wrong-person risk; Agent Mail 5157).
Status: CLOSED by `518098f` plus `7f74e97`; the full chain is APPROVED below.** The direct
owner-button route, the shadow-root primitive, the live label refresh, and the
late-dialog behavior are otherwise correctly implemented and tested, but the
More-menu item is not causally bound to the owner-scoped More button.

### What matches the live evidence

- The profile owner still comes from `<Name> | LinkedIn`; the owner area is
  exactly the one `//main//section[@aria-label="Primary content"]`. The flow
  counts visible copies and strictly clicks the sole visible More in that
  area, so its hidden copy, sticky clone, and suggestion-card More are not
  candidates (`src/linkedin.zig:99-114,629-663`).
- The menu item is an innermost clickable with normalized text exactly
  `Connect`; it does not assume the full-name aria-label that the live menu
  lacks (`src/linkedin.zig:45-51`). Zero or multiple visible candidates fail
  rather than choosing by order (`:665-681`).
- The dialog wait is 15 seconds, comfortably covering the observed 3-5
  seconds, and its exact `Add a note` / `Send without a note` buttons use the
  new open-shadow-root `pierce=` engine (`src/linkedin.zig:52-59,245-248,
  296-317`). Pending and Following are checked inside the owner area using the
  live prefix-plus-owner-name labels. The invitation toast is selfcheck-only,
  never success evidence (`:60-63,92-97,129-155,731-735`).
- `automation.js` leaves the five old selector engines on `[document]`, while
  `pierce=` searches document plus nested open roots, rejects XPath, and
  deduplicates matches (`src/automation_script/automation.js:1047-1158`). Its
  hit test descends shadow roots and checks composed-tree containment, focus
  descends through `shadowRoot.activeElement`, and synthetic input events are
  composed. The real-binary input E2E covers query, wait, synthetic/native
  clicks, fill/type/press, scrolling, obscuration, strict duplicates, nested
  and closed roots, and a slotted node
  (`tests/e2e/automation_input_test.py:400-477`).
- The social-flow fixture places the invite dialog in an open shadow root,
  delays the More route by four seconds, uses the live Pending/Following/toast
  shapes, and contains only invented names. Its direct, external-menu, inline-
  menu, note, no-item, and dry-run paths drive the real socket chain.

### Blocker: an unrelated menu can supply the committing Connect

`selectors.more_menu_connect` is the union of the owner area and **every**
`role=menu` in the document (`src/linkedin.zig:50-51`). After clicking the
owner's More, `clickMenuConnect` accepts the sole visible exact-text Connect in
that union (`:665-681`). It neither records that zero such external candidate
was visible before the click nor links the resulting menu to the clicked
button through `aria-controls`/`aria-owns` or another stable relationship.

Therefore, if an unrelated profile/card menu is already open and contains the
only visible `Connect`, while the owner's menu has none or fails to open, the
flow clicks the unrelated irreversible action. The later Pending check is
post-commit and cannot make that safe. This violates the owner-scope contract
even though the More button itself was selected correctly.

The existing fixture has only the owner's external `role=menu`; its
no-Connect case has no competing open menu, so the production-chain tests do
not exercise this risk. Required failing-first case: keep the owner's menu
without Connect, add one unrelated visible `role=menu` with exact-text
Connect, and assert the flow fails closed with the unrelated click log empty.
A conservative implementation can require zero visible external candidate
before the owner's More click and exactly one newly visible candidate after
it; if live markup exposes a stable `aria-controls`/`aria-owns` relationship,
binding through that is stronger.

Verification evidence is otherwise green: `c1bfeb3`'s clean-export gate
passed **92/92 steps, 751/751 tests**, and the exact descendant `bbd5d74` gate
passed **92/92 steps, 752/752 tests**, both under private Xvfb. The green gates
do not close this blocker because neither contains the competing-menu oracle.
No live browser, live socket, DISPLAY `:0`, or user account was accessed.

## Advisory: descendant-icon text and post-commit state audit at `ab90775`

This is a read-only audit prompted by the live Instagram result in which the
owner's Follow action succeeded, but its confirmation timed out: the rendered
button label was `Following`, while its DOM `textContent` was
`FollowingDown chevron icon` because a descendant SVG contributed its
`<title>`. **This section is advisory, not a new release blocker.** The
previous `c1bfeb3` More-menu provenance BLOCKER remains independently open.

There are three distinct selector facts:

- XPath `normalize-space(.)` collapses whitespace but uses the entire
  descendant string value, including an SVG `<title>`, hidden text and counts.
- `text=` and named `role=` are exact matches, but their implementation is
  only `normalizeText(aria-label || textContent)`
  (`src/automation_script/automation.js:1081-1089,1127-1136,1170-1175,
  1349-1351`). An `aria-label` on the target is therefore safe from descendant
  text; without one, SVG titles/counts contaminate the name. A descendant
  icon's own `aria-label` does not itself enter its parent's `textContent`,
  though the icon's `<title>` does. `aria-labelledby` is not implemented.
- Changing exact matching to prefix matching globally would trade these false
  negatives for wrong-control matches. Keep exact public semantics. Prefer a
  stable exact attribute; otherwise use a live-probed structural selector for
  an exact non-SVG label token, scoped to the owning container, with an
  exactly-one check.

### Every post-click/completion check

| Flow/check | Current matcher and location | Risk | Proposed matcher/oracle |
|---|---|---:|---|
| X schedule dialog opened | After schedule-option click, waits for Month via `//select[@aria-labelledby = //*[normalize-space(.)="Month"]/@id]` (`src/x.zig:36,58-60,166-167`) | LOW: an icon/title or supplemental label text causes a safe false-negative; a second `Month` label can broaden the ID set. | Resolve the select from its own `aria-labelledby` target and require that label's exact semantic/visible token, or pin a stable select/test id when available; require one visible select. |
| X post sent | Any attached `data-testid=toast` after Post (`src/x.zig:26-27,288-295`) | **HIGH false-success:** an old or unrelated toast confirms the post. The fixture itself can pre-create such a toast. | Before clicking, fail closed if a matching success toast is already present; afterwards require a newly appearing toast with the post-success semantic text/state, scoped to `data-testid=toast`. Do not use a document-global prefix alone. |
| X post scheduled | The same generic toast after schedule Confirm and the final Post click (`src/x.zig:156-183,288-295`) | **HIGH false-success:** it does not distinguish scheduled success, an unrelated toast, or a stale post toast. | Use a pre-click baseline plus the schedule-specific success message/state (for example the live “will be sent” semantic token), exactly within the toast. |
| LinkedIn owner More opened | Waits for exact descendant text `Connect` anywhere in the owner area or any `role=menu` (`src/linkedin.zig:45-51,665-681`) | **HIGH:** an SVG title can hide the intended item; an unrelated menu can supply the sole candidate and be clicked. The latter is existing BLOCKER 5157, not downgraded by this advisory. | Bind/baseline the external menu to the owner's More click as required by 5157, then require one exact non-SVG `Connect` label token in that menu. |
| LinkedIn invite dialog opened | Named `pierce=role=button` exact `Add a note` or `Send without a note` (`src/linkedin.zig:52-59,296-308`) | MED: text-only buttons acquire contaminated names if an SVG `<title>` or count is added; this fails before the confirming click rather than choosing a prefix match. | Prefer a stable exact target `aria-label`; otherwise use a shadow-piercing structural selector for one button with an exact non-SVG label token. Do not loosen it to `starts-with("Send")`. |
| LinkedIn invitation sent | Owner-area state is `starts-with(@aria-label,"Pending") and contains(@aria-label,<owner name>)`; the wait is non-strict (`src/linkedin.zig:129-155,290-317,731-743`) | LOW: attribute matching is icon-proof and owner-scoped, but arbitrary Pending variants and substring names are accepted; multiple matches also satisfy the wait. | Accept the known full label `Pending, click to withdraw invitation sent to <Name>` (or a small explicit set of full live labels), inside the sole owner area, and require exactly one visible state. |
| LinkedIn follow completed | Owner-area label starts `Following` or `Unfollow` and contains the title-derived owner name; non-strict wait (`src/linkedin.zig:129-155,320-329,731-743`) | LOW: icon-proof and owner-scoped, but a future unrelated state with the same prefix/name or duplicate passes. | Match the full known owner label `Following, click to unfollow <Name>` plus explicitly enumerated legacy form if still supported; require exactly one visible match. |
| LinkedIn like completed | First reaction-state button whose label is no longer exact `Reaction button state: no reaction` (`src/linkedin.zig:67-73,354-360`) | MED: icon/count-proof, and still restricted to the reaction-state family, but any unknown/malformed non-`no reaction` state is treated as success. | Enumerate accepted positive reaction labels (at least exact `Reaction button state: like`) or use a stable pressed/selected attribute if live markup exposes one; keep it on the same first post control. |
| LinkedIn message sent | No post-click state check; success follows the strict send-button click (`src/linkedin.zig:334-351`) | MED false-success: dispatch is not evidence that LinkedIn accepted or rendered the message. | Wait for one scoped outgoing message carrying the submitted text or an explicit sent status; a composer-clear check alone is weaker but still better than no oracle. |
| LinkedIn comment sent | No post-click state check; success follows a non-strict global class click (`src/linkedin.zig:363-371`) | MED: no acceptance proof, and a multi-post page can make “first match” the wrong form. | Scope input and submit to the target post's same form, require one submit, then wait for the new own-comment node or explicit success state. |
| Instagram follow completed | Exact descendant string `Following` or `Requested` in any header button; non-strict wait (`src/instagram.zig:23-24,104-111,403-405`) | **HIGH, observed live:** `FollowingDown chevron icon` misses after the irreversible Follow has succeeded. A broad `starts-with("Following")` would risk a different header control and still permits duplicates. | In the profile-owner header, match a descendant non-SVG label token exactly `Following` or `Requested`, exclude hidden/aria-hidden copies, and require exactly one visible state. |
| Instagram like completed | First section SVG with exact `aria-label="Unlike"` (`src/instagram.zig:26-29,114-120`) | LOW: exact attribute is not contaminated by its `<title>`; the first-section assumption remains the only site-shape risk. | Keep the exact icon state, but scope the section structurally to the opened post article and require exactly one visible marker. |
| Instagram comment sent | No post-click check after an exact-descendant-text `Post` control in any form (`src/instagram.zig:30-31,123-132`) | MED: SVG title/count can cause a safe miss, while another form could become the sole strict target; a dispatched click is not acceptance proof. | Scope to the form containing the exact comment textarea, match an exact non-SVG `Post` token, require one, then wait for the new comment or explicit submitted state. |
| Instagram DM sent | No post-click check after a document-global exact-descendant-text `Send` (`src/instagram.zig:32-34,135-145`) | **HIGH wrong-action risk:** contamination can remove the intended candidate while one unrelated Send remains and is clicked; success then has no acceptance oracle. | Scope Send to the conversation composer containing `dm_input`, require one exact non-SVG `Send` token, then wait for an outgoing message/status tied to the submitted text. |
| Instagram story may require View-story commit | Counts exact descendant string `View story`; zero permits viewing to proceed (`src/instagram.zig:47-51,151-173`) | **HIGH safety false-negative:** an SVG title can hide this stop gate, after which the flow may wait/view/click Next. | In the verified viewer overlay, conservatively detect exactly labelled non-SVG `View story` and any live-probed equivalent commit gate; ambiguity or an unknown clickable overlay must fail closed. |
| Instagram story Next completed | Before and after each click, compares the URL's exact story username; Next itself is one SVG with exact `aria-label="Next"` outside `main` (`src/instagram.zig:35-46,176-215,222-248`) | LOW: attribute and URL checks are icon-proof; count >1 and owner change both stop before another click. | Keep this design. If markup changes, preserve exact `aria-label`, outside-`main` viewer scope, exactly-one count and both pre/post URL-owner checks. |

### Other text/state selectors that gate actions or diagnostics

| Selector | Current matcher and location | Risk | Proposed matcher |
|---|---|---:|---|
| Instagram Follow action | Header button with exact descendant string `Follow` (`src/instagram.zig:19-24,106-110`) | MED false-negative; exact/strict prevents a prefix-based wrong click, but SVG title text can remove the owner button. | Owner-header structural scope plus one exact non-SVG `Follow` token or stable exact target attribute. |
| Instagram Message action | Header clickable with exact descendant string `Message` (`src/instagram.zig:19-25,135-142`) | MED false-negative for the same reason. | Owner-header structural scope plus one exact non-SVG token/stable exact attribute. |
| Instagram story Next | Exact SVG `aria-label="Next"`, outside `main`, then exactly-one count (`src/instagram.zig:35-46,190-201`) | LOW; this is the strongest pattern in the three selector tables for icon controls. | Keep. Never replace it with text prefix `Next`, which would admit highlight/carousel controls. |
| LinkedIn signed-in gate | Nav/header button exact descendant string `Me` (`src/linkedin.zig:17-23,515-520`) | LOW/MED availability: icon title/badge text can make a signed-in page look indeterminate, but it does not select a person or commit. | Prefer the live nav control's stable exact attribute/relationship; otherwise exact non-SVG `Me` within the nav, not prefix `Me`. |
| LinkedIn owner More | Exact descendant string `More` or exact target aria-label (`src/linkedin.zig:41-44,110-114`) | LOW/MED: aria-label branches are safe; the text-only live branch is SVG-title-sensitive. Owner-area and one-visible-copy logic prevent sidebar selection. | Preserve owner scope and exactly-one logic; use an exact target aria-label if live provides one, else exact non-SVG `More` token. |
| LinkedIn selfcheck Pending/Following and invitation toast | Broad state prefixes in `main`, and toast prefix `Invitation sent` (`src/linkedin.zig:24-40,60-63`) | LOW because these are diagnostics only; they may count suggestion/other-profile controls or unrelated invitation alerts. | Report owner-scoped and global counts separately, or label these fields explicitly as broad diagnostics. Never promote them to action-success oracles. |
| Custom `role=` / `text=` engines | Exact normalized `aria-label || textContent`; no `aria-labelledby`, no exclusion of SVG/hidden descendants (`src/automation_script/automation.js:1081-1089,1127-1175`) | MED ecosystem-wide false-negative; changing to prefix would create broad false positives. | Keep exact match semantics. Implement a tested accessible-name subset (`aria-label`, `aria-labelledby`, then rendered/semantic descendant text excluding `aria-hidden` and SVG titles), or add an explicit structural visible-text primitive rather than silently changing existing selectors. |

Tests should mutate every text-only fixture control by adding
`<svg><title>…</title></svg>` and, separately, add an unrelated prefix-sharing
control. The intended exact owner-scoped action/state must still match once;
the unrelated control must remain untouched. Existing fixtures currently make
the vulnerable Instagram Follow state plain `textContent = "Following"`
(`tests/fixtures/instagram/index.html:181-185`) and the LinkedIn menu icon is
an empty SVG (`tests/fixtures/linkedin/index.html:180-188`), so neither catches
the live class of regression. Agent Mail 5160 sent the HIGH items to cc_2.

No live browser, live socket, live site, DISPLAY `:0`, or user account was
accessed for this audit.

## Out-of-band page health (`fe17bd9`)

**Verdict: APPROVED.** Reviewer clean-export gate at exact `fe17bd9`, under a
private Xvfb with no live socket: **Build Summary: 93/93 steps succeeded;
755/755 tests passed**. The throwaway export was deleted immediately. No live
browser, DISPLAY `:0`, or user account was accessed.

The production path is genuinely out of band from the affected page's FIFO.
`handleRequestWith` sends `page.health` to `handleWindows` before router
parsing/window targeting (`src/automation_server.zig:475-480`). Only
`page.close` acquires `PageCommandQueue`; list and health pass a null cancel
flag and no ticket into `executeExternal` (`:687-705,770-785`). Their platform
operation is `listWindows`, which queues one synchronous, page-independent
snapshot on GTK and reads cached WebView/window state
(`src/webkit_shim.c:3857-3914`). It does not evaluate page JavaScript or take
the global native-input transaction lock.

Responsiveness is stored per `ZbWindow`, updated only on GTK's
`notify::is-web-process-responsive`, initialized immediately for a popup born
into an already-unresponsive process, and reset on the first responsive
notification (`src/webkit_shim.c:113-120,1180-1185,4183-4195`). The server's
2,000 ms debounce has the correct inclusive boundary: raw false remains API
true below 2,000 ms and becomes false at 2,000 ms; raw true wins immediately
(`src/automation_server.zig:657-668`). A related view can correctly share the
same underlying failure, while each unrelated window retains independent
state.

The same consistent snapshot supplies `loading` from
`webkit_web_view_is_loading`, `dialog_open` from the ordinary or
policy-owned dialog, and the existing termination reason (`crashed`,
`memory_limit`, or `terminated_by_api`) (`src/webkit_shim.c:3876-3890`). The
Zig adapter owns copied URL/title strings, parses all four health fields, and
preserves backward compatibility for a snapshot without them
(`src/automation_gtk_port.zig:194-249`). `page.health` reports the termination
reason without changing the established `page.list` wire shape
(`src/automation_server.zig:728-766`).

The socket unit holds window 1's real queue turn while health returns all
three windows; it pins the debounce boundary and all health fields, including
the optional crash reason (`tests/automation_server_test.zig:1632-1710`). The
production-chain E2E kills no process: a trusted click enters an infinite
loop, and health still returns immediately while that command holds its turn.
In the reviewer run it changed to false at 5.01 s, every health call took
under 0.01 s, another web process stayed responsive and evaluable, a 9-second
busy loop recovered to true/0, the never-finishing load alone reported
`loading`, and an alert alone reported `dialog_open`
(`tests/e2e/page_health_test.py:157-265`). These assertions kill queueing,
missing debounce/reset, global-state, loading, and dialog regressions without
bypassing the socket/server/GTK chain. The existing crash E2E in the same
green gate separately proves the native termination state and per-process
window attribution.

Non-blocking follow-ups mailed to cc_1:

- **SHOULD (documentation):** a blocked synchronous SDK call occupies its
  connection; polling `page.health` concurrently requires another SDK client
  / socket connection. State that explicitly in “A frozen page” so “answers
  at once” is not read as transport multiplexing.
- **SHOULD (test completeness):** extend the real web-process-crash E2E to
  assert the same reason through `page.health`, not only `page.list`. The
  server unit already pins health serialization, so this is production-chain
  hardening rather than a code blocker.
- **NIT (test diagnostics):** assign `busy_at` before starting the busy-click
  thread (`tests/e2e/page_health_test.py:222-230`); an immediate error can
  otherwise make the thread's exception reporter raise `NameError` and hide
  the original failure.

## LinkedIn owner-menu provenance follow-up (`518098f`)

**Historical verdict: BLOCKER (cc_2; Agent Mail 5169/5170). Status: CLOSED by
`7f74e97`; the full chain is APPROVED below.** The follow-up closes the
original, demonstrated form of BLOCKER 5157 but still broadens away from an
available owner-to-menu relationship in two cases. `c1bfeb3` therefore remains
blocked pending one more fail-closed follow-up.

The main defense is correct. After resolving exactly one visible `More` inside
the already-verified owner area, `resolveConnect` queries for any visible
`role=menu` or any visible exact `Connect` candidate before dispatching input.
Any match produces `linkedin_profile_menu_already_open`, with neither the
owner's More nor a menu item clicked; the dry run uses the same path
(`src/linkedin.zig:654-686`). After the click, a one-token `aria-controls`
value restricts all wait, count and strict-click operations to descendants of
that id (`:697-734`). Zero and multiple visible Connect candidates still fail
closed. The new real-socket fixture proves the original counterexample: an
already-open unrelated menu with its own Connect causes both real and dry-run
calls to stop with an empty wrong-person click log
(`tests/e2e/social_flows_test.py:234-245`,
`tests/fixtures/linkedin/index.html:269-296`). The SVG-title fixture also
drives the exact non-SVG-text selector through the production chain.

Two remaining provenance failures are release blockers:

- `ownerMenuItem` treats any non-empty, whitespace-separated
  `aria-controls` value as if the attribute were absent, falling back to the
  page-wide owner-area/any-`role=menu` union (`src/linkedin.zig:726-727`). If
  the owner More names multiple controlled elements and an unrelated menu
  becomes visible after its click, the sole exact Connect may again come from
  outside every named id. This contradicts the documented rule that, when
  More names its menu, only that menu is searched
  (`docs/how-to-automate.md:482-490`). A present multi-ID value must either be
  parsed and scoped to only those ids or fail closed; it must never select the
  global fallback. The controlled id must also resolve uniquely, so duplicate
  ids cannot supply a sole Connect under the wrong duplicate.
- The JSON parser gives `value` a default of null
  (`src/linkedin.zig:717-727`). A malformed successful reply such as
  `{"ok":true}` is therefore silently interpreted as “attribute absent” and
  also enables the broad fallback. The unit fake's default response currently
  exercises exactly this accidental path (`tests/linkedin_test.zig:29-44,
  713-744`). `value` must be required in a successful reply (explicit null is
  the valid absent-attribute result); a missing/wrong field must call
  `runner.malformed()` and stop before any menu-item click.

Required failing-first coverage: give the owner More
`aria-controls="owner-menu auxiliary"`, reveal an unrelated menu with the
only Connect after the More click, and assert no menu-item click; separately
return a successful object without `value` and assert malformed failure with
no committing input. No reviewer gate was started because cc_2 still held the
private-Xvfb gate slot and a correctness blocker was already established. The
author's clean-export gate for the committed blobs was green at **93/93 steps,
758/758 tests**; those tests do not cover either case above. No live browser,
live socket, DISPLAY `:0`, or user account was accessed.

## LinkedIn owner-menu provenance closure (`c1bfeb3`, `518098f`, `7f74e97`)

**Verdict: APPROVED.** `7f74e97` closes BLOCKERs 5169 and 5170, completing
the safety chain that began with the More-menu route in `c1bfeb3` and the
pre-click provenance defense in `518098f`. The earlier BLOCKER verdicts above
are historical and are explicitly superseded by this closure.

The final route fails closed at every owner/menu boundary:

- The profile title supplies the owner's name; exactly one owner area and one
  visible owner `More` are required. A visible menu anywhere before that
  `More` click gives `linkedin_profile_menu_already_open`, with no input in
  either the real or dry-run path (`src/linkedin.zig:654-686`).
- A missing or blank `aria-controls` may use the guarded general path. A
  nonblank value is an IDREF list and is never discarded: at most eight ids
  are accepted, every named id must resolve to exactly one element, and the
  eventual exact-text Connect selector is built only below the union of those
  named elements. Missing, duplicate or excessive controlled ids close the
  menu and return `linkedin_profile_menu_unbound`; an unnamed concurrent menu
  cannot supply the action (`src/linkedin.zig:710-772`).
- The successful attribute result requires a `value` field whose value is a
  string or null. Missing/wrong-typed data records a malformed internal reply
  and stops before another page step. `alloc_always` gives the parsed IDs
  independent lifetime across the per-id queries; the fake runner now poisons
  and frees every previous answer before the next step, so the unit test
  detects a borrowed-buffer regression (`src/linkedin.zig:722-735`,
  `tests/linkedin_test.zig:14-64,948-957`).
- Unit tests cover one and multiple controlled ids, missing/duplicate roots,
  the eight-id bound, and malformed replies. The real-socket fixture opens an
  unrelated menu containing the sole Connect at the same instant as the
  owner's multi-ID menu; the flow closes the owner's menu with
  `linkedin_profile_connect_not_in_menu` and the unrelated click log stays
  empty (`tests/e2e/social_flows_test.py:241-245`,
  `tests/fixtures/linkedin/index.html:185-207,284-305`). This directly kills
  the original wrong-person behavior without bypassing production routing.

The author's exact-blob clean-export gate passed **93/93 steps, 761/761
tests**. The independent reviewer gate at exact `7f74e97`, with fresh cache,
private Xvfb, live variables unset and a 1,500-second timeout, also passed:
**Build Summary: 93/93 steps succeeded; 761/761 tests passed**. Its
`more-menu-connect` production-chain phase passed. The throwaway export was
deleted immediately by its `find -delete` trap; `/tmp` was 32% used after
cleanup. No live browser, live socket, DISPLAY `:0`, or user account was
accessed.

## Instagram Following state with an SVG title (`6a9264a`)

**Verdict: APPROVED.** The live failure was a false negative after a real
Follow: the owner control visibly said `Following`, but its descendant SVG
`<title>` made `textContent` read `FollowingDown chevron icon`. The replacement
selector remains scoped to `//header//button`, excludes SVG text nodes, and
accepts only the exact remaining visible text `Following` or `Requested`; the
flow then requires exactly one visible match (`src/instagram.zig:21-32,
125-133`). It is not a prefix match, and the suggested-account Follow controls
below the header cannot satisfy it.

The unit test pins the predicate plus `state:"visible"` and `strict:true`.
The production-chain social-flow E2E uses the observed nested text plus SVG
title, a private-account `Requested` state, a Similar Accounts control, and
nine suggested Follow controls outside the header
(`tests/instagram_test.zig:112-129`,
`tests/fixtures/instagram/index.html:189-213`,
`tests/e2e/social_flows_test.py:255-268`). The author's failing-first run
reproduced the post-click timeout on the old selector, and its exact-blob
clean-export gate passed **93/93 steps, 762/762 tests**. The approval is
independent of the later X finding below.

## X stale-toast confirmation (`32721f9`)

**Historical verdict: BLOCKER (cc_2; Agent Mail 5185). Status: CLOSED by
`0484dcf` (APPROVED; Agent Mail 5192).** Requiring no
visible `data-testid=toast` before Post and a visible toast afterward correctly
kills the demonstrated false success from a toast that predated the action.
The fixture proves both a persistent stale toast (no commit input, error
`x_toast_already_shown`) and one that fades before a successful post. However,
the production ordering introduces a wrong-action race.

`submit` first probes the current Post copies and retains a positional selector
such as `xpath=(//*[@data-testid="tweetButton"])[1]`. It then waits as long as
10 seconds for the old toast to disappear before resolving and clicking that
selector (`src/x.zig:298-308`). X is a dynamic React page; during that interval
the matching copies can be inserted, removed, or reordered. The same selector
can consequently identify a different composer's Post control. The new
`stale=fade` fixture leaves the DOM stable, so neither it nor the index-only
unit assertion detects this (`tests/fixtures/x/composer.html:97-105,223-224`,
`tests/x_test.zig:208-240`).

Required fix: establish the hidden-toast precondition before
`findPostButton`, then probe and commit the selected copy without the new
multi-second gap. A failing-first test must at least pin hidden-wait-before-
query/probe ordering; a production-chain case should reorder the copies as
the toast disappears and prove that no decoy/other-composer Post is clicked.
The author's clean gate (**93/93 steps, 763/763 tests**) does not cover this
race. Separately, the audit's semantic-oracle HIGH remains open: this commit
deliberately accepts any newly visible toast, not a proven post-success state.

The follow-up moves the entire hidden-toast precondition before
`findPostButton`, so no Post copy is queried or trialed until the page is quiet;
the selected positional copy is then committed immediately after its successful
trial (`src/x.zig:298-312`). Unit and engine-route tests pin the exact sequence
and prove a persistent toast prevents even discovery
(`tests/x_test.zig:208-256`, `tests/automation_x_test.zig:90-97`). The
production-chain `stale=reorder` case removes the toast while inserting another
composer's disabled Post before the intended one. The old ordering retained
the now-wrong index and failed on `element_disabled`; the fixed ordering
discovers after insertion, skips the decoy, and posts the intended text
(`tests/fixtures/x/composer.html:227-240`,
`tests/e2e/x_flows_test.py:169-179`). The decoy's click counter is only a NIT:
a disabled button cannot fire that listener, so the regression is actually
killed by the old failure plus the new intended-post success. The author's
exact-blob clean gate passed **93/93 steps, 763/763 tests**. The separate
semantic-toast HIGH remains open exactly as documented; it does not reopen this
ordering blocker.

## `page.recover` review (`9f09035`)

**Verdict: APPROVED. BLOCKER 5187, BLOCKER 5196 and SHOULD 5199 are CLOSED by
`9f09035`.** The committed implementation satisfies the user-confirmed
recovery contract and does not add an automatic termination path.

The two-phase boundary is real and revalidated at confirmation time. Phase 1
requires a currently debounced frozen target, ends nothing, and issues a
32-hex OS-random token bound to the target's current responsiveness incident
and current process-family window list. Phase 2 lists the windows again, then
requires the same live incident, an unexpired current token, and a duplicate-
free acknowledgement equal to both the originally disclosed and current
blast radius (`src/automation_server.zig:841-895,935-1021`). A mismatch,
changed incident, expired/unknown/used token, or responsive target returns
without calling the native recovery. A successful consume invalidates every
outstanding token whose family intersects the acknowledged one while holding
the confirmation mutex, so overlapping sibling confirmations cannot terminate
the replacement process a second time. The overlap regression holds the first
native call, rejects the sibling token both during and after it, and observes
exactly one `recoverWindows` call
(`tests/automation_server_test.zig:1825-1898,1942-1999`).

Confirmed recovery establishes the per-window queue gate before native
termination. `beginRecovery` now owns every unique key and reserves all map
capacity before inserting anything or setting a cancellation flag; its
failing-allocator test forces each allocation to fail in turn and proves no
window is stranded as recovering and no waiter is cancelled. Once installed,
queued waiters leave immediately as `-32012`, the running ticket is flagged,
and new page work for every family window is refused as `-32014 recovering`;
`endRecovery` removes the gate on every exit
(`src/automation/queue.zig:60-94,137-176`,
`tests/automation_queue_test.zig:247-283,334-370`). The engine remaps the page
call failure caused by termination to cancelled, while the native job state
machine accepts only its first completion. The socket/server test and real
binary E2E each prove one reply for the held command, immediate cancellation
of the queued command, refusal of new family work, and continued operation of
an independent window (`src/automation/engine.zig:337-360`,
`src/webkit_shim.c:1499-1515`,
`tests/automation_server_test.zig:2001-2105`,
`tests/e2e/page_recover_test.py:195-286`).

The only new call to `webkit_web_view_terminate_web_process` is reachable from
the confirmed `page.recover` handler through `PagePort.recoverWindows`; neither
`page.health` nor the responsiveness callback invokes it. The shim captures
owned URL strings, marks the acknowledged family, terminates only the target
view's web process, waits for WebKit's termination notification, clears native
pointer state, reloads only windows WebKit reported ended, serializes the
result, and frees every captured string and call object
(`src/automation_server.zig:1023-1036`,
`src/automation_gtk_port.zig:260-304`,
`src/webkit_shim.c:3944-4070,4315-4358`). The real E2E drives the full
socket/server/engine/GTK/shim chain: refusals leave three windows intact;
confirmation ends/reloads the two actual shared-process pages, preserves the
acknowledged over-approximation in its separate process, clears old page
state, restores native input, and rejects token reuse. This does not bypass
the production chain.

Telemetry is target-specific and redacted: `windowRoute` binds both phase
roots to the requested window, the child reports counts only, and tests reject
URLs and the incident token in the sink (`src/automation_server.zig:1086-1102`,
`tests/automation_server_test.zig:1900-1940`). The SDK wire fixtures and both
clients agree on the two request shapes and `-32014`. Documentation explicitly
warns that page memory and popup opener links are not preserved.

The author's exact-blob clean-export gate passed **94/94 steps, 774/774
tests**. The independent reviewer gate at exact `9f09035`, with a fresh cache,
private Xvfb, live variables unset and a 1,500-second timeout, also passed:
**Build Summary: 94/94 steps succeeded; 774/774 tests passed**. Its
`page-recover` production-chain phase passed all 27 checks. The throwaway tree
was deleted immediately by its `find -delete` trap. No live browser, live
socket, DISPLAY `:0`, or user account was accessed.

## Instagram DM Send and story-gate text (`ddd5e8a`, `430da5d`)

**Historical verdict on `ddd5e8a`: BLOCKER (Agent Mail 5194). Status: CLOSED
by `430da5d`; the combined chain is APPROVED.** The `View story` change is
conservative and correct: it uses exact non-SVG visible text for a stop-only
gate, so a false positive can only stop the flow before a committing click
(`src/instagram.zig:63-69`). The original DM change fixed the demonstrated
SVG-title mismatch when both Send controls existed, but its ancestor search
was not a stable composer boundary.

The XPath starts from the contenteditable and selects the nearest ancestor
that contains *any* matching Send (`src/instagram.zig:39-47`). If the intended
composer Send is absent, renamed, hidden, or otherwise no longer matches while
an unrelated share-sheet Send remains, the ancestor search widens to their
lowest common ancestor (potentially the document root), and the unrelated
control becomes the sole strict match. This is the same wrong-action class the
change is intended to close. The fixture always renders both controls, so its
`shareSends == 0` assertion does not cover disappearance or drift of the
intended action (`tests/fixtures/instagram/index.html:184-193`,
`tests/e2e/social_flows_test.py:271-275`).

`430da5d` removes that widening behavior. The contenteditable's immediate
parent is now the fixed scope, independent of whether any Send exists; only an
exact non-SVG visible-text `Send` below that parent, outside hidden ancestry,
can satisfy the strict click (`src/instagram.zig:38-49,77-81,158-167`). If the
live composer layout differs from the unverified boundary, the flow fails
closed instead of searching the page.

The real-socket regression renames the composer's control while leaving the
share sheet as the page's sole global exact `Send`. The old selector returned
success after clicking that unrelated control; the follow-up refuses with no
DM result and `shareSends == 0`, while the ordinary both-present case still
sends (`tests/fixtures/instagram/index.html:181-205`,
`tests/e2e/social_flows_test.py:270-288`). The unit test also pins the absence
of any `ancestor::*[.//...]` search. The independent green gate at `9f09035`
passed the Instagram production-chain phase. The separate live message-arrival
acceptance oracle remains advisory and unimplemented, exactly as documented;
it does not reopen this wrong-action closure.

## Frozen-window stderr transitions (`9e49912`)

**Verdict: APPROVED.** Each `ZbWindow` owns its own timer and reported bit.
The WebKit responsiveness notification records only the start of an unbroken
stretch, arms one GLib timeout, emits one line after the shared 2-second
debounce, and emits the matching recovery line only if that stretch had been
reported (`src/webkit_shim.c:4333-4367`). All of this runs on the GTK main
context; the callback does not cross threads or retain a borrowed string. The
line contains only the stable numeric window id and elapsed whole seconds, not
a URL, title, page text, or account data.

Close and shutdown disconnect the responsiveness signal before WebKit process
termination and remove the timer; final destruction removes it again safely
(`src/webkit_shim.c:291-305,478-485`). That prevents a normal quit from being
misreported as recovery and prevents a timer from retaining a freed window.
The debounce constant is compile-time pinned to `page.health`'s constant.

The production-chain `page-health` E2E freezes window 1 indefinitely, runs a
bounded 9-second busy loop in independent window 2, and keeps a loading window
responsive. It then checks the complete transition sequence after normal
shutdown: one frozen line for window 1, one frozen/recovered pair for window 2,
none for the loading window, and no duplicate or shutdown recovery line
(`tests/e2e/page_health_test.py:89-139,194-291`). The new assertions necessarily
failed on the predecessor, which emitted none of these lines; the author's
quit-guard mutant also produced the forbidden recovery line and failed.

**SHOULD (cc_1, test coverage):** add a private-Xvfb case that kills a web
process after its frozen line has been emitted. WebKit reports a dead view as
responsive in `page.health`, while the termination callback does not explicitly
retire the outstanding responsiveness state (`src/webkit_shim.c:4350-4395`).
The current tests therefore do not prove that a freeze-to-crash transition
cannot append a misleading `page responding again` line. This is a diagnostic
edge and does not block the normal freeze/recovery feature approved here.

## Social selector MEDIUM fixes (`2965a9f`)

**Verdict: APPROVED.** The changed committing selectors stay exact and become
more tightly scoped; none introduces a prefix or page-wide fallback. Instagram
Follow and Message remain under the profile header, exclude hidden ancestry,
and compare only non-SVG text. Comment Post is now below the unique form that
contains the comment textarea, so another form's Post cannot become the sole
candidate (`src/instagram.zig:19-44`). The flow uses strict clicks for all
three controls (`src/instagram.zig:134-142,154-163,166-175`). LinkedIn's
owner-area More text branch likewise remains under the previously proven owner
area, and the post-click Like state now accepts exactly
`Reaction button state: like`, rather than treating every unknown reaction as
success (`src/linkedin.zig:72-83,118-127,367-373`). The nav `Me` changes affect
only signed-in detection, not selection of an action target.

The fixtures add SVG-title text to all affected controls and a second-form
Post decoy. The real-socket E2E proves the intended actions still work and the
decoy counter remains zero; on the predecessor the titled LinkedIn `Me` and
owner More controls fail the flow, so the regression is failing-first
(`tests/fixtures/instagram/index.html:152-160,199-210`,
`tests/fixtures/linkedin/index.html:112-115,203-209`,
`tests/e2e/social_flows_test.py:263-275`). No real identity was added to the
fixtures.

The existing advisory is narrower but still open: `visibleTextIs` excludes SVG
text, not hidden descendant text or a visible counter, and the standalone
LinkedIn login probe does the same (`src/flow_steps.zig:17-24`,
`src/automation/social_routes.zig:35-56`). Those cases fail closed for the
reviewed action selectors rather than selecting another person. The general
`role=`/`text=` accessible-name cleanup and live acceptance oracles remain
separate follow-ups, as the commit documents.

## Site-flow `window_id` routing (`817f23b`)

**Verdict: APPROVED.** All `x.*` verbs enter one handler and all
`linkedin.*`/`instagram.*` verbs enter the other; both now remove and validate
`window_id` before strict flow parsing, derive the named page/telemetry route,
take that page's queue turn, and pass the named `PagePort` through
`Engine.executeExternal` (`src/automation_server.zig:458-477,568-606,
1270-1322,1334-1387`). Every primitive step and final stop-sign scan runs
through that one external context, so there is no secondary primary-page path.
If the id is absent, `flow_route` remains the original primary route and the
port stays null, preserving the old primary-window behavior. Malformed ids are
`-32602`; a disappeared targeted page becomes `-32011 no_window`; a recovering
target uses that target's queue and `-32014` response. Cookie/session state,
pacing, and caps remain intentionally account-global.

The server regression drives both LinkedIn and X against separate fake window
ports, observes navigation and scans only there, and proves the primary port
untouched. It also covers malformed/gone ids and a shared X cap while two
window queues progress independently (`tests/automation_server_test.zig:
2121-2233`). The real-binary `social-flows` phase opens a popup through the
browser, targets LinkedIn Follow plus the owner-More Connect dry run to it,
checks the popup's navigation and action log, and verifies the primary URL and
input log are unchanged; the predecessor rejects this request as invalid
params (`tests/e2e/social_flows_test.py:422-446`). Existing no-`window_id`
phases in the same test continue to exercise the primary default. Both SDKs
expose the option on every X, LinkedIn, and Instagram method, with shared wire
fixtures covering read, action, dry-run, message, search, story, and selfcheck
shapes (`sdk/node/src/methods.ts:372-424,442-564`,
`sdk/python/src/zigbrowser/client.py:268-363,439-473`).

One independent clean-export gate at exact `817f23b`, with a fresh cache,
private Xvfb, live variables unset, and a 1,500-second timeout, passed:
**Build Summary: 94/94 steps succeeded; 778/778 tests passed**. The
`page-health`, `social-flows/window-id`, SDK-live, and all other phases ran. The
throwaway tree was deleted immediately by its `find -delete` trap. No live
browser, live socket, DISPLAY `:0`, or user account was accessed.

## Historical Claude Agent chat-drawer plan review (`e03c6d5`)

**Status: SUPERSEDED during review by follow-up `7922624`.** This records the
first revision's findings. The current formal verdict and the disposition of
those findings are in the next section.

**Verdict: BLOCKER — needs major revision before implementation.** The native
GTK drawer is a sound, stronger adaptation of the threat model's WebView-
specific isolation design, and the plan covers the user's visual requirements
and chosen Python/auth surfaces. The blockers are in the security contracts,
the claimed closure tests, and child-process ownership.

This was a docs-only review. No browser, display, socket, site, build, or test
was run. `e03c6d5` changes only the plan. Its production pin
`b4c23a1a56deced7b3ab7c8a34a660b22ffca622` is its exact parent, so the pin is
reproducible and the production tree is identical to review-time `HEAD`.

### Contract matrix

| Required check | Result | Evidence |
|---|---|---|
| Verbatim drawer behavior | PASS | The bottom drawer, movable floating S, hidden icon while open, scrollable conversation, bottom input, top-right `-`, animation to the saved icon rectangle, and direct browser control are all explicit (`plan:20-22,147-193,357-371`). |
| User's auth/helper decisions | PASS | The plan selects the Python Agent SDK helper, a native privileged Secrets window, pasted `claude setup-token` tokens, and a captured claude.ai callback (`plan:24-31,311-343,884-913`). The real CLI contract still needs the blocker below. |
| Page/popup/socket privilege isolation | PASS in design | Native GTK eliminates drawer JavaScript, a privileged renderer, and its bridge. T1 still probes hostile top pages, same/cross-origin frames and related popups; T3 probes the authenticated socket (`plan:147-159,557-560`). This is an acceptable adaptation of afe9c0f T1/T2, not a skipped control. |
| T1-T8 placed red first | PARTIAL | All eight labels appear in section 9 and the slice rule requires red first (`plan:553-571`), but T4, T6 and T7 do not yet implement the full threat-model oracles; see blockers 2 and 5. |
| Real-binary private-Xvfb E2E in every slice | FAIL | S1-S10 name real-binary closure tests. S0 is explicitly helper-only/LEAF and has only helper contract/unit steps (`plan:575-607,1096-1108`), contradicting `plan:49,55,409,571`. |
| Agent config/SAI/sandbox/scratchpad never touch the user's `.claude` or repositories | PARTIAL | Runtime HOME/config/cwd are private and the final bwrap mount excludes the real home (`plan:195-218,345-355`). The proposed open oracle and built-in file-tool design do not prove/enforce the promise; see blockers 3 and 10. |
| Exact approval for every social write | PARTIAL | Every committing social flow is classified as approval-required and grants are single-use/no-retry (`plan:275-305`). Account/target identity and all-flow coverage are missing; see blocker 4. |
| ClosureMaps pinned and re-derived at the production base | PASS with one missing test | Maps A and B match the `b4c23a1` production topology: `zb_window_new`, the shared-popup UCM, page-world `zbHost`, explicit window routing, per-window FIFO, GTK handoff/waiter, envelope, and the special out-of-band paths (`plan:57-117,465-537`). The committed `page.health` regression already proves an answer while the target FIFO is held (`tests/automation_server_test.zig:1672-1742`; `tests/e2e/page_health_test.py:224-225`). Closure A's page-side Promise oracle remains unscheduled; see blocker 7. |

The spot-checked map locations are current: the standard-window seam is
`src/webkit_shim.c:1127-1217`; the direct child and current render/media policy
are at `:1163-1174`; the page-world handler/return path is `:674-752`; and the
socket, parser/auth, special routes, target route, queue and envelope are
`src/automation_server.zig:277-356,412-543,568-607`. The plan also correctly
keeps screenshot construction separate and accounts for per-window sessions,
related popups, crash state, dialogs, `page.health`/`page.recover`, and current
render/MSE configuration.

### BLOCKER findings

1. **S0 violates the every-slice real-binary closure rule.** It is expressly a
   helper-only LEAF slice with `agent-host-contract` and `agent-host-unit`, not
   a real zigBrowser process under the private Xvfb (`plan:575-607,1098`). Make
   it a prerequisite outside S0-S10, or add a non-bypassing real-binary Xvfb
   E2E to S0. Merely running the binary as a wrapper around a helper unit test
   would still bypass the product chain.

2. **T7 deliberately weakens the accepted filesystem approval invariant.**
   Afe9c0f requires every file write/delete/move/execute to stop at an exact
   trusted confirmation and its T7 requires ungranted writes/deletes to fail.
   The plan instead permits scratchpad writes without a card and calls that
   T7 (`plan:354,390,563,1032-1034`). Until the user explicitly changes the
   invariant, every scratchpad mutation must also be approved. Scratchpad
   usefulness is not itself authority to weaken the threat model.

3. **The filesystem TOCTOU defense is attached to the permission check, not
   the actual I/O.** `can_use_tool` can canonicalize/open/fstat a path, but the
   SDK's built-in Read/Write/Edit implementation later opens that pathname
   independently (`plan:245-249,353-355,1025-1042`). The inode checked by the
   policy is therefore not the inode used by the tool, so the promised symlink-
   swap test cannot be killed by that design. The bwrap layout also exposes the
   whole writable `agent-home`, including `.claude`, transcripts, and the
   fallback secret (`plan:197-207,347-354`). Use app-owned/custom MCP file
   tools that perform the actual fd-relative/openat2 operation, or an equally
   strong kernel-enforced design, and run the swap against the actual I/O seam.

4. **The approval tuple is missing the selected account and resolved action
   target.** The card names origin/target/payload, but not account; the grant
   digest binds only `(tool, window_id, origin, load_serial, normalized_args)`
   (`plan:290-300`). A same-document account switch or DOM retarget need not
   advance `load_serial`, so an approved selector/flow can execute against a
   different account or control. Afe9c0f requires
   `(tool, window, origin/account, target, payload)`. Define a deterministic
   account and resolved-target fingerprint, display and bind it, and revalidate
   it at the dispatch seam. T5 needs wrong-account, same-document retarget, and
   every D9 committing social method in its table-driven approval tests; a
   single LinkedIn Like E2E does not by itself prove the user's all-social-
   writes rule (`plan:959-999`).

5. **T4 and T6 are only partial copies of their required threat tests.** T4's
   sole hostile instruction asks for `linkedin_like`; it does not attempt the
   required secret revelation or tool enablement, or representative
   Post/Follow/Connect requests (`plan:560,959-968`; afe9c0f:67). T6's scanner
   inventories processes, logs, files, API requests, rows and page storage, but
   omits `telemetry.query`; the mapped tests do not explicitly seed and observe
   the API-token/cookie/auth-header/automation-token canaries through telemetry,
   crash text and model-visible error paths (`plan:445-450,562,815-822`;
   afe9c0f:69). Add those red-first oracles in S4/S5/S7/S9.

6. **The plaintext secret fallback is automatic, contrary to the threat
   model.** The plan silently chooses a 0600 file whenever Secret Service does
   not answer or libsecret cannot load (`plan:322-330,808-812`). Afe9c0f:46
   permits such a fallback only when explicit. Default failure must fail closed
   and ask the user, or require `--agent-secret-store file`; it must never
   silently downgrade storage. The secret directory must also stay outside the
   agent-visible sandbox mount.

7. **The research check's Closure A assertion is acknowledged but never
   scheduled.** The plan correctly says the existing E2E stops at native
   `IPC`/`IPCERR` rows and does not assert page-side Promise settlement
   (`plan:68-70,467-495`). 05c3c17:139-143,224-228 required a failing test that
   reads the fixture DOM after both resolve and reject. No slice adds it, while
   `plan:1121` claims every required update is addressed. Put that real-WebKit
   assertion in a slice (it can also contribute to S0's missing binary E2E) or
   correct the closure claim and track it as an explicit prerequisite.

8. **The native-to-helper streaming channel is not bounded.** A 256-KiB
   per-frame maximum does not bound an unlimited stream of assistant deltas,
   queued GTK-idle callbacks, chat rows, or total session memory
   (`plan:230-256`). 05c3c17:216-221 required buffering/backpressure,
   cancellation, and process-exit behavior. Specify named per-message,
   per-queue, and per-session limits; delta coalescing/backpressure; overflow
   behavior; cancellation/drain ordering; and a real-process E2E that exceeds
   each bound without growing or hanging the UI process.

9. **The S3 parent-death mechanism cannot satisfy its descendant cleanup
   promise.** `PR_SET_PDEATHSIG(SIGKILL)` kills only the direct helper, not its
   Claude CLI descendant. The helper deliberately creates a new process group,
   while the test guardian owns the browser's group (`plan:221-229,770-791`).
   Browser SIGKILL can therefore orphan the CLI; helper SIGKILL can do the
   same. Define a production supervisor/pid-namespace/cgroup mechanism that
   owns the whole descendant tree for both deaths, and have S3 prove cleanup
   before the harness guardian acts. Deferring bwrap's `--die-with-parent` to
   S10 cannot support the guarantee claimed in S3.

10. **The “never touch the user's `.claude` or repos” oracle is too weak.**
    S3 checks atime/mtime on a decoy `.claude` tree (`plan:738-750`). An open is
    not reliably observable that way under relatime/noatime, and no decoy user
    repository is named. Use a real-process file-access trace or open-event
    oracle over both trees. Scan every copied SAI document/skill/agent/hook for
    outside absolute paths, not only generated `settings.json`, and prove the
    runtime starts with its CWD/config/scratch/TMPDIR inside the private home.

11. **The fake Messages API is not reachable through the stated production
    spawn contract.** S0 can pass `--base-url` directly to its helper command,
    but S3-S10 all require the fake API while D7's exact helper environment
    allowlist excludes `ANTHROPIC_BASE_URL` (`plan:221-228,461-463,1096-1108`).
    Add an explicit, `--e2e-protocol`-gated app-to-helper test configuration
    path. It must not become a production environment-inheritance escape.

12. **The `claude setup-token` fake is accepted before its external contract
    is known.** Its output is explicitly unconfirmed (`plan:440-443`), but the
    real-CLI characterization is manual and after S6 (`plan:884-913`). Make the
    orchestrator's throwaway-config characterization a prerequisite to S6's
    green/approval, and pin the fake parser to the observed URL, callback/code,
    and token-output shapes. Otherwise the required login path can go green
    against an invented protocol.

### Interface and plan-hygiene amendments

- The NDJSON type list omits S6's `auth_url` and code/token handoff, and the
  `DRAWER` row table omits row types later used as closure observations:
  `tree`, `minus`, `scroll`, `delta`, and `BLOCKED`
  (`plan:230-240,420-433,557,706,724,828,851,896`). Define their exact schemas,
  ownership and size limits. Clarify whether login is a separate one-shot
  helper and which direction each fd/pipe carries; normal token handoff and
  login-token return cannot use one unidirectional fd-3 pipe in opposite
  directions without separate processes/pipes.
- Name the gesture, movement, animation, frame, rejection, backoff, shutdown,
  approval-TTL and message/queue limits in their owning modules. Keep protocol
  version and externally observed enum values stable. The plan's data-driven
  tool table, flat GTK-to-Zig callbacks, strict schemas, shared atomic writer,
  and explicit no-duplication/refactor pass otherwise satisfy the applicable
  CodeCleanup plan-hygiene criteria (`plan:1044-1092`).
- Keep the current explicit choice that the native drawer survives a page-web-
  process crash, never joins a browsing UCM/process, and never becomes a
  socket-visible `window_id`. This is the main architectural strength of the
  plan.

Agent Mail 5230 sent the blockers to BlackRobin. BlackRobin then landed the
docs-only follow-up `7922624` while this review was in progress; it is reviewed
below.

## Claude Agent chat-drawer TDD plan rev 2 (`7922624`)

**Verdict: BLOCKER — needs major revision before implementation.** Revision 2
correctly records the user's five additional decisions: default-on after S5,
all SAI hooks enabled, free scratchpad writes, a floating drawer, and empty
initial memory (`plan:33-42,420-430`). It also makes a good safety correction:
before S8 the model sees only the exact read-only S7 tool set, while previews,
hover, scroll and every mutation remain both unregistered and refused by the
broker (`plan:295-309,1009-1017,1037-1041`).

The user's scratchpad decision **supersedes and closes** e03 finding 2. T7 must
describe free scratchpad writes as the explicit user-approved exception to the
earlier every-file-write threat invariant; workspace writes remain per-action.
No other e03 blocker was closed by rev 2. The production ClosureMaps remain
correctly pinned to `b4c23a1`, the production ancestor shared by both docs-only
plan commits.

### BLOCKER findings still open from e03

1. **S0 still has no real-binary/private-Xvfb E2E.** It remains a helper-only
   LEAF slice with only contract/unit steps (`plan:614-661,1180-1192`), while
   the requirements say every S0-S10 slice ends with a real binary under a
   private Xvfb (`plan:60,66,447`).

2. **Built-in SDK file tools still cannot enforce the promised symlink-swap
   invariant at the actual I/O seam.** `can_use_tool` checks one open/inode and
   Read/Write/Edit later open the pathname again (`plan:263-269,378-389,
   1109-1126`). Use app-owned MCP file tools that perform the actual fd-relative
   operation, or an equivalent kernel-enforced primitive. This remains a T7
   test-validity blocker even with the user's free-scratchpad decision.

3. **Approval still omits current account and resolved target identity.** The
   card and digest remain origin/`load_serial`/arguments only
   (`plan:311-328,1043-1083`). A same-document account switch or selector
   retarget can therefore survive revalidation. Bind, display and atomically
   revalidate an account/target fingerprint, and test every committing D9
   social method plus wrong-account and same-document retarget cases.

4. **T4 and T6 remain incomplete.** T4 still tests only a page instruction to
   Like, not the required attempts to reveal a secret, enable a tool, or make
   representative Post/Follow/Connect requests (`plan:598,1043-1051`). The T6
   scanner still omits `telemetry.query`, and the plan does not explicitly
   drive canaries through telemetry, crash text and model-visible errors
   (`plan:483-487,600,871-893,1019-1022`). A4 improves hook-environment
   coverage but does not close those other T6 surfaces.

5. **Secret storage can still silently downgrade to plaintext.** Failure of
   Secret Service still automatically chooses a 0600 file
   (`plan:345-348,864-870`), contrary to afe9c0f's explicit-fallback rule.
   Require `--agent-secret-store file` or native user confirmation and otherwise
   fail closed.

6. **Closure A's page-side Promise oracle is still unscheduled.** The plan
   acknowledges that `ipc_roundtrip_test.py` observes only native protocol rows
   (`plan:79-81,505-533`) but still does not add the DOM assertion required by
   05c3c17. It can be combined with S0's missing real-binary test.

7. **Streaming is still bounded per frame only, not per queue/session.** The
   plan still lacks aggregate delta/GTK-idle/message/conversation limits,
   backpressure, coalescing, overflow behavior and cancellation/drain ordering
   (`plan:250-276`). Add a real-process over-limit E2E as required by the
   research check.

8. **`PR_SET_PDEATHSIG` still does not own descendants.** It kills the direct
   helper, not the Claude CLI, while the helper is deliberately placed in a
   process group separate from the browser (`plan:241-248,271-276,824-846`).
   Define a production descendant supervisor/pid namespace/cgroup and prove
   browser death and helper death leave no CLI or hook process, without relying
   on the test guardian.

9. **The no-touch oracle remains atime/mtime based and omits a decoy user
   repository.** That does not prove absence of opens on relatime/noatime
   filesystems (`plan:790-806`). Use a real-process file-access trace/open-event
   oracle, and scan all copied SAI scripts/documents for outside path references.

10. **S3-S10 E2Es still lack a defined app-to-helper fake-API seam.** The exact
    helper environment allowlist excludes `ANTHROPIC_BASE_URL`, while those
    closure tests depend on the fake Messages API (`plan:243-248,499-501,
    1180-1192`). Define a `--e2e-protocol`-gated handoff that cannot widen
    production environment inheritance.

11. **The `claude setup-token` fake still precedes characterization of the real
    CLI contract.** Its URL/token output is explicitly unconfirmed
    (`plan:478-481`), while the real check remains manual after S6
    (`plan:986-988`). Make that throwaway-config characterization a prerequisite
    to S6 green/approval and pin the fake parser to the observed contract.

12. **The helper and `DRAWER` protocols remain incomplete on paper.** The
    NDJSON schema omits `auth_url`, auth-code input and login-token return; the
    row table omits `tree`, `minus`, `scroll`, `delta` and `BLOCKED`, although
    later closure tests depend on them (`plan:250-260,458-471,595,760,778,
    884,924,969`). Define exact schemas, limits, ownership and pipe direction.

### New rev-2 blockers

13. **All hooks run with the user's filesystem authority before the sandbox
    exists.** The plan explicitly acknowledges that S3-S9 hooks can read the
    rest of the user's files (`plan:420-430`), directly contradicting the
    requirement that the agent never touch the user's `.claude` or repositories
    (`plan:57`). Default-on at S5 makes this an ordinary product path. Move
    bwrap/kernel confinement into S3 before the first real helper/prompt, or
    keep the feature unable to start until confinement lands. Path-token checks
    cannot constrain what an accepted hook script itself opens, nor a shell
    command that computes a path dynamically.

14. **R2 deliberately exposes the credential to hooks and file tools.** It
    writes the token into `.claude/.credentials.json` inside the agent HOME
    (`plan:352-363`), and the plan itself records that every unsandboxed hook
    can read it (`plan:430`). This contradicts A4 and the privileged Secrets
    boundary. Remove R2 unless the credential can be placed outside every
    hook/tool-visible mount. A proven R1 followed by R3 with scrubbed hook
    environments is safer.

15. **The product A4 test is scheduled before product tools exist.** S4.4
    requires `PreToolUse` and `PostToolUse` from a real read-only tool call
    (`plan:880-885`), but browser tools first land in S7 and built-ins remain
    disabled until S10 (`plan:263-269,295-309,990-1033`). Keep the complete
    helper-level hook contract in S0, test the non-tool lifecycle hooks in S4,
    then test Pre/Post at the first real MCP call in S7 and again inside bwrap.

16. **Token-route selection has no installed-runtime owner.** S0 gate probes
    R1/R2/R3 and D11 says the selection is written to
    `runtime/token-route.json` (`plan:352-363,629-650`), but a developer gate or
    cached helper environment cannot choose a route for the user's installed
    CLI/home. Specify that the real `--agent-setup` probes the installed CLI,
    writes the selected route atomically, and fails closed when none succeeds.

The updated default-on/read-only design also needs one whole-gate process-tree
oracle after S5, not only per-test helper checks, so a test that exits before
`stop_browser` cannot leave an agent process behind. This is a SHOULD once the
early-sandbox and descendant-ownership blockers are designed.

Agent Mail 5230 contains the e03 findings; Agent Mail 5232 records the rev-2
hook/sandbox/token-route findings. No browser, live site, socket, display,
build, or test was used for either docs-only review.

## Claude Agent chat-drawer plan rev 3 (`fdf3783`) and rev 4 (`ad07556`)

**Verdict at exact `fdf3783`: BLOCKER, then SUPERSEDED by `ad07556`.** Rev 3
substantially improves the plan, but it does not close every blocker in
`09069e3`. While this review was in progress, BlackRobin landed the docs-only
rev-4 follow-up `ad07556`; its separate current verdict is below. The production
pin `b4c23a1a56deced7b3ab7c8a34a660b22ffca622` remains reproducible because
every intervening commit is docs-only.

This was a docs-only review. No browser, display, socket, site, build, test, or
user repository was opened. `git diff --check 09069e3..ad07556` is clean.

### `09069e3` finding disposition

| Finding | `fdf3783` | Current `ad07556` |
|---|---|---|
| 1. helper-only S0 | CLOSED: it is now prerequisite P0, and S1-S10 retain real-binary private-Xvfb closure tests (`fdf plan:64-66,683-730`) | CLOSED |
| 2. built-in file-tool TOCTOU | CLOSED: built-ins stay off and app-owned `fs_*` tools own the `openat2` I/O seam (`fdf plan:405-426,1216-1237`) | CLOSED, subject to the direct-hook bypass below |
| 3. grant lacks account/target | CLOSED in design: the card and digest include both, with `options.expect` checked inside the FIFO ticket at the commit seam (`fdf plan:332-349,1174-1190`) | CLOSED in design |
| 4. T4/T6 incomplete | **OPEN:** adding scanner destinations is not the same as driving canaries through them, and T4 still covers only Like (`fdf plan:667-669,1143-1151`) | **OPEN**, blocker 3 below |
| 5. silent plaintext fallback | CLOSED: only a flag or explicit native click selects the 0600 file (`fdf plan:371-375,940-953`) | CLOSED |
| 6. Closure A Promise oracle | CLOSED: S1.6 observes success and rejection through page-set title, with a red-at-seam mutation (`fdf plan:786-791`) | CLOSED |
| 7. aggregate streaming bounds | CLOSED: queue/view/bubble/result limits, coalescing, one GTK idle, pipe backpressure, overflow and Stop behavior are specified and driven by S5.6 (`fdf plan:286-297,1023-1031`) | CLOSED |
| 8. descendant ownership | CLOSED in design: the bwrap PID namespace is production-owned and S3.4 checks it before harness cleanup (`fdf plan:278-284,918-930`) | CLOSED |
| 9. no-touch oracle | The inotify/open-event oracle is CLOSED, but the product invariant remains OPEN because rev 3 deliberately exposes `/` until S10 (`fdf plan:283,484`) | Outside-user-tree confinement is CLOSED by early bwrap; workspace gating has a new bypass below |
| 10. fake-API E2E seam | CLOSED: all seams require `--e2e-protocol`, loopback validation and an inert-production test (`fdf plan:543-556,896-907`) | CLOSED |
| 11. real setup-token characterization | CLOSED: a redacted real transcript is a prerequisite and the fake must replay it (`fdf plan:1080-1086`) | CLOSED |
| 12. helper/DRAWER protocol completeness | **OPEN:** S6 and multiple closure rows still use message/row types absent from the protocol tables | **OPEN**, blocker 4 below |
| 13. hooks run before filesystem confinement | **OPEN:** S3 uses `--dev-bind / /` and the plan explicitly records the exposure (`fdf plan:278-284,484`) | CLOSED by moving the full filesystem sandbox to S3 (`plan:279-284,420-427,934-941`) |
| 14. R2 credential visible to hooks | **OPEN:** R2 remains inside hook-visible `.claude` (`fdf plan:379-390,484`) | CLOSED: R2 is removed (`plan:379-398`) |
| 15. S4 A4 calls tools before S7 | **OPEN:** S4.4 still requires a real read-only tool (`fdf plan:964-968`) | CLOSED: lifecycle hooks stay in S4 and Pre/Post move to S7.6 (`plan:1004-1009,1157-1160`) |
| 16. no installed-runtime token-route owner | **OPEN:** P0 chooses and writes the route (`fdf plan:698-708`) | CLOSED: real `--agent-setup` probes the installed CLI, pins its version and fails closed (`plan:390-398,929-932`) |

Rev 3 correctly records the five latest user choices: the drawer flips on after
S5 with chat-only, then the exact S7 read-only set; every SAI hook is retained;
scratchpad creates/writes are free while workspace mutations are intended to be
gated; the drawer floats; and memory starts empty. Rev 4 preserves those
choices. The remaining blockers concern whether the implementation actually
enforces them.

### Current rev-4 BLOCKER findings

1. **Arbitrary hooks can bypass every workspace approval.** The helper, CLI
   and all copied hooks share a sandbox in which `agent-home/workspace` is
   writable (`plan:420-438`). The native card controls only calls through
   `fs_*`; a hook can call `open`, `rename` or `unlink` directly. S10 tests only
   the MCP tools (`plan:1264-1283`), so they cannot detect this bypass. This
   contradicts the user's “scratchpad free, workspace gated” decision. Add a
   real-process malicious hook that attempts direct create/overwrite/rename
   after no card or a denied card and assert zero workspace mutation. The CLI
   and hooks need a read-only workspace view, with approved mutation performed
   by an app-owned broker outside that view, or an equivalent privilege/mount
   boundary.

2. **The token boundary is conditional on an unanswered root-level host
   choice.** The plan records that this host's `ptrace_scope=0` lets a hook read
   the CLI's token from `/proc/<pid>/mem`; seccomp does not stop that path
   (`plan:399-411,504-511`). A4 skips the memory-read assertion unless the
   setting is already at least 1 (`plan:702`). A default-on privileged feature
   cannot satisfy its no-credential invariant conditionally. Either fail closed
   on an unsafe host or use and test a production isolation mechanism that does
   not depend on a global sysctl (for example a verified non-dumpable,
   different-identity or PID-visibility boundary). The malicious hook's real
   `/proc` read must fail in the real-binary E2E.

3. **The required T4/T6 attacks are still not failing-first tests.** T4 drives
   only hostile page text requesting `linkedin_like` (`plan:694,1189-1197`). It
   still omits hostile page/tool output asking the model to reveal a credential,
   enable a forbidden tool, and issue representative Post, Follow and Connect
   calls, as required by `afe9c0f:67`. T6 now scans telemetry, crash/error
   lines, JSON-RPC data, tool errors and drawer errors (`plan:567,696`), but no
   behavior deliberately seeds a canary into each of those paths. A removed
   redactor can therefore survive. Add the missing inputs plus red-at-seam
   evidence that bypassing policy/redaction makes each test fail.

4. **The cross-process login protocol and E2E observation protocol remain
   incomplete.** D7's exact NDJSON list omits S6's `auth_url`, auth-code input
   and login-token return (`plan:250-260`). Normal startup defines fd 3 as
   app-to-helper, while S6 says the helper writes the captured token back on fd
   3 (`plan:377-403,1094-1127`). Specify whether login is a distinct one-shot
   process and give every pipe/fd one direction, exact frame schema, owner and
   size/lifetime limit. The `DRAWER` table also omits `tree`, `minus`, `scroll`,
   `delta`, `BLOCKED` and `idles`, even though closure tests consume them
   (`plan:539-552,1033-1039,1069-1077,1103-1105`). Those schemas must be fixed
   before implementation so tests and production do not invent incompatible
   contracts.

### SHOULD amendments

- Update D6's stale statement that hook command directories are bound in S10;
  rev 4 makes that an S3 requirement (`plan:229-234`).
- Remove the duplicate `Property: none` in P0.4 (`plan:736-745`).
- Name the minimal `/dev` and runtime/config binds required by Python and the
  bundled CLI. The early sandbox must be executable as written, not discovered
  ad hoc during green.
- Add a whole-gate process-tree oracle after the S5 default-on transition, in
  addition to per-test cleanup, so an early Python-driver exit cannot leave an
  agent namespace behind.

The data-driven tool table, strict schemas as a design goal, flat GTK-to-Zig
callbacks, named bounds and explicit per-slice refactor checklist otherwise
continue to satisfy the applicable CodeCleanup plan-hygiene criteria. Agent
Mail 5236 sent the current blockers to BlackRobin.

## Claude Agent chat-drawer plan rev 5 (`3f48207`)

**Verdict at exact `3f48207`: BLOCKER.** Rev 5 adopts the right enforcement
direction: the workspace is read-only to the sandbox, approved workspace
mutations move to the browser process, and hooks get a nested PID namespace
instead of relying on `kernel.yama.ptrace_scope`. The T4/T6 matrix and the
chat/login protocol are also substantially more concrete. Four contradictory
or bypassable contracts still prevent implementation.

This was a docs-only review. No browser, display, socket, site, build or test
was used. `git diff --check 23e0264..3f48207` is clean. The plan remains pinned
to production commit `b4c23a1a56deced7b3ab7c8a34a660b22ffca622`; the commits
since that pin are documentation only for this project.

### `23e0264` blocker disposition

| Prior finding | Rev-5 disposition |
|---|---|
| R4-1: hooks bypass workspace approval | **PARTIALLY CLOSED, still OPEN.** The read-only workspace plus browser-side `agent_fs.zig` is the required privilege split (`plan:502-528`, S3.9), but the file-tool ownership text still conflicts, and writable hook configuration can remove the wrapper on a later invocation. See blockers 1 and 3 below. |
| R4-2: token protection depends on `ptrace_scope` | **The host-policy dependency is CLOSED; the token boundary is still OPEN.** A working nested PID namespace hides the helper and CLI even when `ptrace_scope=0`, and failure leaves the agent unavailable (`plan:478-485`). No host sysctl change is part of or authorized by this plan. The mutable hook definitions and R3 pre-namespace environment leak below still bypass that design. |
| R4-3: T4/T6 attacks are not failing first | **CLOSED in the plan.** S5.7, S7.7, S7.8, S8.7 and S9.4 deliberately drive the credential and policy attacks through API errors, telemetry, JSON-RPC/tool/drawer errors, crash text, hostile page text and hostile tool output, with red-at-seam mutations (`plan:787-789,1201-1206,1291-1305,1372-1379,1410-1414`). |
| R4-4: helper/login/row protocols incomplete | **PARTIALLY CLOSED, still OPEN.** D7b now fixes distinct chat/login processes, pipe directions, frame schemas and a complete row table (`plan:299-377`), but a second conflicting row table and one wrong row consumer remain. See blocker 4. |

The former SHOULD items are otherwise addressed: D6 says the hook command
directories are bound from S3, the duplicate property is gone, D12 enumerates
the intended binds and P0.5 proves them before product work, and the final
`agent-no-orphans` step depends on the full agent gate (`plan:229-235,839-850,
1501-1513`).

### Current rev-5 BLOCKER findings

1. **Writable hook configuration lets a hook remove its own isolation.** Setup
   stores the rewritten `zb-hook-run -- ...` definitions in the copied,
   sanitized SAI (`plan:225-236`), but the outer sandbox binds all of
   `agent-home/.claude` writable (`plan:505-510`). A malicious wrapped hook can
   replace `.claude/settings.json`, its hook command, or a copied hook script.
   On the next CLI/session invocation, the direct replacement runs outside
   `zb-hook-run`, can see the outer PID namespace, and defeats both the token
   and workspace boundaries. The pre-ready self-check proves only that the
   wrapper works; it does not prove that every active hook definition still
   names it (`plan:483`). S3.9 does not attempt persistence followed by a
   second session (`plan:1048-1063`). Make the provisioned settings, SAI and
   hook definitions immutable in the sandbox, with only the exact CLI state
   and transcript paths writable, or construct and hash-verify an immutable
   per-session view. Add a two-session malicious-hook red: session 1 attempts
   to replace its definition, and session 2 must still run nested, fail to read
   the token, and fail to mutate the workspace. With the configuration bind
   writable, that test must go red.

2. **The R3 token is removed after the namespace monitor has already inherited
   it.** Rev 5 specifies
   `zb-hook-run -- env -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_AUTH_TOKEN ...`
   (`plan:235,468-469`). Its nested bwrap invocation does not use
   `--as-pid-1`, so bwrap installs a PID-1 reaper. Removing variables only in
   the final `env` command is too late: unless `zb-hook-run` sanitizes its own
   environment before it execs bwrap, that namespace-visible PID 1 inherits
   the R3 token and the hook can read `/proc/1/environ`. Specify pre-bwrap
   `unsetenv` or bwrap `--clearenv` plus an exact allowlist, and assert the
   canary is absent from every visible `/proc/*/environ`, including PID 1.
   P0.4 and S4.4 must also stop expecting the command line to begin with
   `env -u`; that contradicts the mandatory `zb-hook-run` prefix
   (`plan:829-836,1126-1131`). This fix is intrinsic and must not use or request
   a `ptrace_scope` change.

3. **The file-tool owner and scratchpad approval contract have two answers.**
   D12 first says every workspace mutation is performed by browser-side
   `agent_fs.zig` and the helper retains reads plus scratchpad operations
   (`plan:513-514`). Eight lines later it says the helper's
   `fs_write/fs_edit/fs_delete/fs_move` perform the I/O themselves
   (`plan:519-525`), and S10.1 repeats the latter (`plan:1424-1426`). The T7
   table and the old response row say scratchpad delete/move/rename require a
   card (`plan:537,790`), while the current user decision and S10.2 make every
   scratchpad operation free (`plan:526-528,1430-1435`). Replace those passages
   with one routing table: helper-side reads plus all scratchpad operations;
   app-side `agent_fs` for every workspace mutation. Drive write, edit, delete,
   move and rename at their real production owner, with denied/unapproved and
   approved cases.

4. **The supposedly exact observation protocol still has competing schemas.**
   D7b's canonical table includes the approval account, status reason, error
   message role, minus/scroll/delta/idles/tree rows and a `SECRETS tree` row
   (`plan:361-377`). The later `DRAWER protocol rows` table omits or changes
   those fields (`plan:632-644`): approval lacks `account`, status lacks its
   reason, and message roles omit `error`. S4.3 then observes
   `DRAWER ... tree` for the Secrets window even though D7b defines
   `SECRETS tree` (`plan:1133-1137`). Delete the competing table or make it
   refer to D7b, and make every closure assertion consume the one canonical
   schema.

### Host-policy decision

The PID-namespace design itself satisfies the orchestrator's constraint: it
does not rely on `ptrace_scope`, does not change it, and fails closed when a
host cannot create the required nested namespace (`plan:478-485,602-604,
839-850`). The sentences about taking a future host question to the user are
not authorization to change a sysctl and are outside this plan's green path.
Implementation must leave the agent unavailable on such a host unless the user
later makes a separate explicit decision.

The remaining structure continues to meet the reviewed CodeCleanup criteria:
policy is data-driven, security limits are named, callback logic is intended to
stay in Zig, and each product slice retains a real-binary private-Xvfb closure
test. Agent Mail 5239 sent the rev-5 blockers to BlackRobin.

## Claude Agent chat-drawer plan rev 6 (`ea2eb63`)

**Verdict at exact `ea2eb63`: BLOCKER.** Rev 6 closes the four findings from
`bdd9ba7` in their original form. The `.claude` configuration tree is now
read-only, the hook launcher constructs a fresh allowlisted environment before
starting bwrap, D12 contains one file-operation routing table, and D7b is the
only observation-row schema. Two security-critical cases remain unspecified or
untested.

This was a docs-only review. No browser, display, socket, site, build or test
was used. `git diff --check bdd9ba7..ea2eb63` is clean. The plan remains pinned
to production commit `b4c23a1a56deced7b3ab7c8a34a660b22ffca622`; the commits
after that pin are documentation only for this project.

### `bdd9ba7` blocker disposition

| Prior finding | Rev-6 disposition |
|---|---|
| R5-1: writable hook configuration | **CLOSED for `.claude`; a narrower same-session `.claude.json` path remains OPEN below.** The whole `.claude` tree is read-only, only census-derived data directories are overlaid writable, setup rejects hook scripts/imports from those directories, and S3.10 attacks the persistence paths across two sessions (`plan:503-517,1073-1089`). |
| R5-2: token reaches the namespace monitor before `env -u` | **CLOSED.** `zb-hook-run` closes descriptors, constructs a fresh allowlisted environment, refuses all credential names, and execs bwrap with `--clearenv` and explicit `--setenv`; P0.4 and S3.9 inspect PID 1 and every visible environment under R3 (`plan:518-523,834-842,1056-1070`). |
| R5-3: conflicting file owner and scratchpad approval contracts | **CLOSED as a design table; route coverage remains OPEN below.** D12 is now the single contract: helper reads and scratchpad operations, while the app owns any mutation whose move endpoint is in the workspace (`plan:529-543`). |
| R5-4: competing observation schemas | **CLOSED.** The later table is gone, all prose refers to D7b, `parse_row` validates exact rows, approval retains `account`, status retains its reason, and the Secrets widget tree uses `SECRETS tree` (`plan:298-378,650-650,1159-1163`). |

The no-host-policy requirement is also satisfied. Nested PID-namespace failure
leaves the agent unavailable; the plan neither depends on nor changes
`kernel.yama.ptrace_scope` (`plan:479-486`). A host change would require a new
user decision and is not part of this plan's green path.

### Current rev-6 BLOCKER findings

1. **A hook can still mutate live `.claude.json` during the same session.** The
   outer sandbox deliberately keeps `agent-home/.claude.json` writable for the
   CLI, and the app checks it only before each session (`plan:512-514`). The
   nested hook sandbox binds `/` writable and re-binds only the workspace
   read-only (`plan:518-523`), so a malicious hook can write that file too.
   S3.10 proves that planted `hooks` and `mcpServers` refuse *session 2*, but it
   does not prove that the live CLI cannot re-read the planted configuration
   before a later event in session 1 (`plan:1073-1088`). The hook sandbox must
   re-bind `.claude.json` read-only while leaving it writable to the outer CLI,
   or use an equivalent immutable/app-mediated per-session view. Add a
   failing-first same-session test: an early hook attempts the write and a
   later hook event in the same session must not execute any planted command.
   Prefer asserting the hook write itself gets `EROFS`; retain the pre-session
   validator for corruption by the CLI or another same-user process.

2. **The tests do not drive either cross-root `fs_move` route.** D12 makes a
   move card-free only when both endpoints are under `scratchpad/`, and routes
   it to the app plus an exact card when either endpoint is under `workspace/`
   (`plan:531-539`). S10.1 tests reads, same-root mutations and an outside path,
   but omits both `scratchpad -> workspace` and `workspace -> scratchpad`
   (`plan:1450-1465`). A source-only routing bug could therefore make a
   workspace mutation card-free. Add both directions and prove that denial or
   timeout leaves both roots byte-identical and approval commits exactly once
   at the app owner. The stated count is also wrong: the existing bullets name
   17 calls, not 13; adding both cross-root cases makes 19.

### SHOULD amendments

- Make the filesystem object-type contract executable. D12 currently says
  every open requires `S_ISREG`, but `fs_list` and recursive `fs_find`/
  `fs_grep` must open and traverse directories (`plan:535-541`). Specify
  securely opened `S_ISDIR` directory descriptors separately from regular-file
  leaf I/O while preserving the `openat2` resolution constraints.
- Remove two stale implementation traps: D11 says the hook is PID 1 even though
  D12 correctly assigns PID 1 to bwrap's reaper (`plan:480,522`), and the rev-3
  history row still describes all of `.claude` as writable. Mark historical
  text explicitly superseded or rewrite it to the current contract.

The plan otherwise preserves the required real-binary private-Xvfb closure per
slice, all eight threat-model tests land red-first in named slices, the drawer
defaults on after S5 with read-only tools, social writes remain per-action
approved, and the agent home/scratchpad/workspace separation remains explicit.
Agent Mail 5242 sent the rev-6 blockers to BlackRobin.
