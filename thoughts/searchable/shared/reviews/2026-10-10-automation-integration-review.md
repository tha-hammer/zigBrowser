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

## Claude Agent chat-drawer plan rev 7 (`3076758`)

**Verdict at exact `3076758`: BLOCKER.** Rev 7 closes both findings from
`ed14446` at the requested layer: the nested hook sandbox now makes the live
`.claude.json` read-only and S3.11 drives later events in the same session;
S10.1 now enumerates and drives 19 routes, including both cross-root moves.
The newly explicit move/delete implementation, however, contradicts the
fd-stability invariant it is meant to enforce.

This was a docs-only review. No browser, display, socket, site, build or test
was used. `git diff --check ed14446..3076758` is clean. The plan remains pinned
to production commit `b4c23a1a56deced7b3ab7c8a34a660b22ffca622`; the commits
after that pin are documentation only for this project.

### `ed14446` finding disposition

| Prior finding | Rev-7 disposition |
|---|---|
| R6-1: same-session `.claude.json` mutation | **CLOSED.** `zb-hook-run` overlays `.claude.json` read-only in every hook namespace while the outer CLI retains its writable view, and it hides `/run/zb-token` behind a new empty tmpfs (`plan:518-525`). S3.11 attempts in-place, truncate and rename replacement, then drives `UserPromptSubmit`, a real MCP call and `Stop` in the same session while checking the file hash and process census (`plan:1107-1122`). The pre-session validator remains defense in depth. |
| R6-2: missing cross-root `fs_move` routes | **CLOSED for routing and approval coverage.** S10.1 correctly counts 19 calls, sends both directions to the app owner, requires a card, checks denial/timeout against both roots, and includes a source-only-routing red (`plan:1483-1501`). The implementation contract behind those successful moves remains OPEN below. |
| R6 SHOULD: object types and stale text | **CLOSED in substance.** D12 distinguishes securely opened directory descriptors from regular leaves, names traversal limits and cross-root behavior, D11 assigns PID 1 to bwrap's reaper, and the rev-3 row is visibly superseded (`plan:480,543-554,565`). Two precision amendments remain below. |

The revision introduces no host-policy dependency. Nested-namespace failure
still leaves the feature unavailable, and no `ptrace_scope` or other sysctl
change is authorized.

### Current rev-7 BLOCKER finding

1. **`fs_move` and `fs_delete` validate an fd but mutate a pathname.** D12 says
   the checked object and I/O object are always the same descriptor
   (`plan:543`), but its concrete operations are
   `renameat2(src_dir_fd, src_name, ...)` and
   `unlinkat(parent_fd, name, 0)` (`plan:554`). Neither syscall consumes the
   opened leaf fd. They resolve the name again at syscall time; Linux also
   specifies that renaming a symlink renames the link itself and leaves an
   already-open fd for the former path unaffected.

   A writable scratchpad hook can therefore race an approved
   `scratchpad/a.txt -> workspace/a.txt` move: after the app's `openat2` and
   `fstat` accept the regular inode, the hook renames that file aside and puts
   a symlink or FIFO at `a.txt`; the app's later `renameat2` moves the
   replacement object into the workspace. The operation succeeds even though
   the checked regular fd was not moved. This violates the special-file rule
   and S10's success-if-and-only-if-regular property. The current race oracle
   can miss it because moving a symlink does not open or modify the outside
   canary (`plan:1495-1501`). The analogous check-then-`unlinkat` sequence can
   delete a replacement name.

   Either reject cross-root moves fail-closed and update the route/e2e
   contract, or specify an actually fd-stable protocol, including its partial
   failure and concurrency semantics. A second `fstat` before the path-based
   syscall does not close the race. The race test must prove that a successful
   move used the exact opened inode/content and that no symlink, FIFO, socket
   or device ever appears at the destination. Apply the same analysis to
   same-root `fs_move` and `fs_delete`.

### SHOULD amendments

- S3.11 requires every in-place, truncate and temp-plus-rename attempt to fail
  specifically with `EROFS` (`plan:1110-1118`). Renaming over a bind-mounted
  file may instead be refused with `EBUSY`. Name the accepted refusal errno set
  and require byte identity; retain the exact `EROFS` check for direct write
  and truncate.
- D12 says the hook can write only the census state directories and scratchpad
  (`plan:523`), although the nested view also deliberately has ephemeral
  writable `/tmp`, `/run` and `/dev/shm`. Qualify that sentence as persistent
  agent-home paths or enumerate the ephemeral mounts.

The revision otherwise keeps the plan data-driven, names the traversal bounds,
retains the real-binary private-Xvfb closure in each product slice, and covers
all eight threat-model tests red-first. The remaining blocker is a foundation
issue rather than a CodeCleanup control-expression issue: the promised
same-object invariant cannot be layered on a pathname syscall after an fd
check. Agent Mail 5245 sent the finding to BlackRobin.

## Claude Agent chat-drawer plan rev 8 (`2ec7193`)

**Verdict at exact `2ec7193`: BLOCKER.** Rev 8 closes the original
live-name-substitution gap in principle: each move or delete first captures the
named object into a quarantine unavailable to the adversarial writer, verifies
the captured inode, and only then commits. A move into the workspace copies
approved bytes into a fresh inode, so a hook's retained writable descriptor
cannot mutate the workspace object. The new race test observes object type,
exact inode or digest, retained-fd writes, and both real owners. The protocol's
crash and failure-state contract is not yet complete enough to implement.

This was a docs-only review. No browser, display, socket, site, build or test
was used. `git diff --check de0ef43..2ec7193` is clean, and the revision changes
only the plan. The plan remains pinned to production commit
`b4c23a1a56deced7b3ab7c8a34a660b22ffca622`; commits after that pin are
documentation only for this project.

### `de0ef43` finding disposition

| Prior finding | Rev-8 disposition |
|---|---|
| R7-1: path substitution between fd check and name mutation | **CLOSED for the live-race invariant; OPEN for crash/failure atomicity below.** Capture moves whatever currently occupies the source name into an unreachable quarantine; verification then requires the approved/opened regular inode and one link before commit (`plan:554-565`). A substituted object cannot pass the inode check, and a workspace destination receives a fresh digest-checked copy rather than an inode on which a hook may retain a writable fd. S10.4 races symlink, FIFO, socket, another regular file and held descriptors through Zig, Python and the real browser/helper/hook chain (`plan:1533-1556`). |
| R7 SHOULD: bind-mounted rename errno | **CLOSED.** S3.11 requires exact `EROFS` for direct write and truncate, accepts `{EROFS, EBUSY, EXDEV}` only for temp-plus-rename, and always checks byte identity (`plan:1137-1148`). |
| R7 SHOULD: incomplete writable-path statement | **CLOSED.** D12 distinguishes persistent writable agent-home paths from private per-hook `/tmp`, `/run` and `/dev/shm`, and hides `scratchpad/.zb-q` from hooks (`plan:518-525`). |

The revision still introduces no host-policy dependency. It does not change or
depend on `ptrace_scope`; failure of nested namespaces keeps the agent
unavailable.

### Current rev-8 BLOCKER findings

1. **The journal cannot recover several ordinary crash cuts.** D12 records
   `{op, src, dst, dev, ino, content_sha256, phase}`, updates the phase after
   capture, install and unlink, and defines replay only for `captured` and
   `installed` (`plan:566-569`). That is insufficient at the boundaries the
   journal exists to make atomic:

   - a crash after capture but before its phase update leaves the object in
     quarantine under the preceding, unspecified phase;
   - a crash after a scratchpad destination rename or a delete's unlink but
     before the next phase leaves no captured name for `captured` replay;
   - a crash after creating the workspace temp but before install can orphan a
     temp whose name is absent from the journal; and
   - a crash after installing the workspace copy but before recording
     `installed` makes replay restore the source while retaining the
     destination, turning one move into a copy.

   Specify atomic/durable journal transitions and replay for every syscall
   boundary, including the identities or names of source, captured object,
   destination and temp. Add deterministic fault injection at each boundary
   for same-root rename, cross-root copy-move and delete at both owners. The
   prior review explicitly required partial-failure semantics; the current
   two-state replay does not yet meet them.

2. **S10.1 still requires the superseded one-syscall implementation.** It says
   an approved cross-root move removes the source and creates the destination
   "both in the same `renameat2`" (`plan:1519-1523`). D12 now necessarily uses
   a capture rename followed by another rename for a scratchpad destination,
   or capture plus copy/install/unlink for a workspace destination
   (`plan:559-565`). The closure test cannot simultaneously enforce both
   contracts. Replace the old assertion with the rev-8 final-state and
   exactly-once protocol oracle.

3. **The readable-fd and rollback outcomes are internally incomplete.** Verify
   opens the quarantined object with `O_PATH|O_NOFOLLOW` (`plan:560`), but Linux
   rejects `read(2)` on an `O_PATH` descriptor with `EBADF`; commit then copies
   from an unnamed "own fd" (`plan:564`). Require a readable descriptor bound
   to the captured object and `fstat` that same descriptor, whether it is
   retained from preview or opened after capture.

   Separately, rollback can keep the checked object in quarantine when the
   source name has already been retaken (`plan:565`), but the outcome table
   still says "nothing was moved" or unconditionally "rolled back"
   (`plan:570-578`). S10.4 says every failed run leaves both roots unchanged
   and every journal is empty/replayed (`plan:1546-1556`). A continuously
   racing hook makes the retained-quarantine state reachable. Give that state
   its own exact result and message, state whether its journal remains pending,
   and align the outcome table and test oracle with it.

The CodeCleanup review did not find a control-expression or maintainability
issue in the documentation diff; the blockers are conflicting and incomplete
security protocols. Agent Mail 5248 sent the concrete findings to BlackRobin.

## Claude Agent chat-drawer plan rev 9 (`29f7ad0`)

**Verdict at exact `29f7ad0`: BLOCKER.** The orchestrator's scope cut is sound:
`fs_move` and `fs_delete` are absent from the tool surface and deferred to a
later slice, so rev 8's quarantine, journal and rollback protocol is no longer
needed. The remaining write design is substantially smaller: a broker-only
fresh temp, file `fsync`, atomic rename into the read-only-to-sandbox workspace,
and directory `fsync`. Four interface and test contracts still prevent the
plan from being implementation-ready.

This was a docs-only review. No browser, display, socket, site, build or test
was used. `git diff --check 27e4aa2..29f7ad0` is clean, and the revision changes
only the plan. The plan remains pinned to production commit
`b4c23a1a56deced7b3ab7c8a34a660b22ffca622`; commits after that pin are
documentation only for this project.

### `27e4aa2` finding disposition

| Prior finding | Rev-9 disposition |
|---|---|
| Journal cannot recover all crash cuts | **WITHDRAWN by scope.** Move/delete and their capture, quarantine, rollback and journal are removed. A write has only a private temp and atomic install; an interrupted pre-install temp is startup-cleaned (`plan:533-565,603-604,635`). |
| S10 required a stale one-`renameat2` cross-root move | **WITHDRAWN by scope.** S10 now drives 17 read/write/refusal cases and no move operation (`plan:1495-1509`). |
| Move copied from an unspecified readable fd; retained-quarantine outcomes conflicted | **WITHDRAWN by scope.** Neither source-copy nor quarantine remains. Existing-leaf reads now name a readable fd and check that same fd, although the special-file ordering remains OPEN below (`plan:543-551`). |

The two earlier SHOULD findings remain closed: S3.11 retains its exact refusal
errno contract and byte-identity check, while D12 still enumerates persistent
and private ephemeral writable paths. The revision introduces no host-policy
or `ptrace_scope` dependency.

### Current rev-9 BLOCKER findings

1. **The canonical model/broker tool registry contains none of the six file
   tools.** D8 says `agent_broker.zig` owns D9's allowlist, and D9 identifies
   itself as the model-visible tool set (`plan:380-411`). That table has no
   `fs_read`, `fs_list`, `fs_find`, `fs_grep`, `fs_write` or `fs_edit`, and it
   says the read-only set is exactly the five S7 rows. Under that contract,
   D12 and S10's file calls cannot reach either owner.

   Add the six tools to D9 with first registration in S10. Reads need no card;
   write/edit approval is path-dependent—free under scratchpad and exact
   per-action approval under workspace. Extend the recorded-tool and forged
   call assertions so `fs_move` and `fs_delete` remain absent from both MCP
   registration and the broker allowlist.

2. **The leaf-open sequence opens a device before rejecting it.** D12 opens an
   existing leaf `O_RDONLY|O_NOFOLLOW|O_NONBLOCK`, then calls `fstat`, while the
   next row claims special files are never opened (`plan:543-551`).
   `O_NONBLOCK` prevents a FIFO wait, but it cannot make an arbitrary device's
   `open` side-effect-free. This contradicts T7's promise that special files
   fail closed before I/O (`plan:825`).

   Classify with `O_PATH|O_NOFOLLOW` first, then obtain a readable descriptor
   pinned to that verified regular inode—such as through a controlled
   `/proc/self/fd/<n>` handle—and re-`fstat` it, or specify an equivalent
   mechanism that never opens a device. Reopening the original pathname would
   recreate the substitution race.

3. **S10.4 has two impossible observation claims.** First, its racer is
   explicitly allowed to hold `O_RDONLY` descriptors on workspace files
   (`plan:1512-1516`). Once the fresh destination is installed, that racer may
   legally open it too. D12 and S10 nevertheless assert that no sandbox process
   can hold *any* descriptor on the new inode (`plan:558,1525`). The relevant
   safety invariant is no write-capable descriptor; read-only descriptors are
   expected. Inspect the descriptor access mode and inode, and permit reads.

   Second, `/proc/<helper>/fdinfo` cannot prove that a write descriptor's inode
   “was created by `O_EXCL`” (`plan:1524`). Linux fdinfo exposes current access
   and status flags, not the creation operation's history; `O_CREAT` and
   `O_EXCL` are creation flags. Replace that inference with an observable
   oracle—for example a unit seam that records the real open call plus an e2e
   final-state/inotify check, or a deterministic pause paired with an
   independently recorded created inode.

4. **The real-chain racer has no stated way to outlive `SessionStart` without
   blocking it.** S10.4 starts a real malicious hook at `SessionStart`, keeps it
   alive, and then drives later file-tool calls concurrently
   (`plan:1511-1521`). A normal command hook is awaited, so the session cannot
   advance to those calls. Name and test a supported asynchronous-hook mode
   that preserves the nested sandbox, or use another production-representative
   concurrent writer. Merely backgrounding a child is insufficient unless the
   plan also proves how the nested bwrap PID namespace remains alive and is
   cleaned up.

### SHOULD and NIT

- **SHOULD — make broker-temp ownership cross-process.** D6 gives browser
  processes one fixed agent home, but D12 uses only a process-local workspace
  mutex and says startup deletes everything in the shared
  `.zb-broker-tmp/` (`plan:212-223,555-560`). Two browser processes could race
  an overwrite or one could delete the other's live temp. Either take an
  exclusive cross-process agent-home lock and fail closed, or give each
  instance isolated temp ownership plus cross-process mutation serialization.
- **NIT — remove duplicated text.** `plan:565` repeats “Execution is
  impossible, because no tool exists for it” on the same line.

The reduced design addresses the root cause instead of layering more journal
states, which is a CodeCleanup maintainability improvement. The blockers are
now finite interface and oracle defects rather than a move/delete foundation
problem. Agent Mail 5251 sent them to BlackRobin.

## Claude Agent chat-drawer plan rev 10 (`892ffa4`)

**Verdict at exact `892ffa4`: BLOCKER.** Rev 10 closes most of the rev-9
design gaps: D9 and S10.0 register exactly the six intended file tools while
keeping move and delete absent; the readable descriptor is reopened through
the verified `O_PATH` descriptor; the workspace invariant now permits
read-only descriptors and rejects write-capable ones; helper-write provenance
has a unit open-call oracle plus e2e trace/inotify evidence; and the racing
writer is an awaited hook in a second concurrent session. The agent-home
`flock` also closes the earlier cross-process temp-ownership SHOULD in design.
One special-file test does not exercise the guard it claims, and the canonical
D12 text still contradicts its new two-descriptor protocol.

This was a docs-only review. No browser, display, socket, site, build or test
was used. `git diff --check b09a56c..892ffa4` is clean, and the revision changes
only the plan. The plan remains pinned to production commit
`b4c23a1a56deced7b3ab7c8a34a660b22ffca622`; commits after that pin are
documentation only for this project.

### `b09a56c` finding disposition

| Prior finding | Rev-10 disposition |
|---|---|
| D9 omits all six file tools | **CLOSED in design.** D9 adds the four reads and two path-dependent writes, S10.0 checks the exact recorded list and the broker allowlist, and move/delete remain unavailable (`plan:399-416,1526-1531`). |
| A device is opened before its type is checked | **PARTIALLY CLOSED; test BLOCKER remains.** D12 now specifies `O_PATH` classification before any readable open and pins the readable fd through `/proc/self/fd/<n>` (`plan:547-561`). The proposed device regression is ineffective as described; see finding 1. |
| Workspace assertion wrongly forbids read-only fds | **CLOSED.** D12 and S10.4 now inspect `fdinfo` access mode and forbid only write-capable descriptors (`plan:568,1571-1573`). |
| `fdinfo` cannot prove `O_EXCL` creation history | **CLOSED.** The Python unit seam records the real open call, while e2e `FSTRACE` rows and independent inotify creation events cover the production chain (`plan:345,379,729,1567-1570`). |
| `SessionStart` racer cannot coexist with later calls | **CLOSED.** Window 2's awaited `UserPromptSubmit` hook races while window 1's independent session runs the operations, and the test also checks namespace cleanup (`plan:1547-1557`). |
| Cross-process broker-temp ownership | **CLOSED in design.** One browser holds `agent-home/.zb-owner.lock`; a loser starts no agent and cannot touch the temp or workspace (`plan:570-573,1157-1165`). The test-oracle SHOULD below remains. |
| Duplicated execution sentence | **CLOSED.** The sentence appears once (`plan:578`). |

### Current rev-10 BLOCKER findings

1. **The device regression is rejected at the mount boundary before it tests
   `O_PATH`.** S10.4 proposes placing `/dev/null` and `/dev/tty` in the
   scratchpad with bwrap `--dev-bind` (`plan:1566`), while the production
   resolver retains `RESOLVE_NO_XDEV` (`plan:547`). A bind-mounted device is a
   mount crossing, so both the new `O_PATH` call and the pre-fix direct
   `O_RDONLY` call fail with `EXDEV` before the device inode is opened. The
   claimed direct-open red-at-seam therefore survives for the device case
   (`plan:1577`).

   Keep the real FIFO `IN_OPEN` test, but add a failing-first syscall/order
   oracle for a same-mount `S_IFCHR` classification. The existing injected
   `os_ops` seam can require the first open to use `O_PATH`, return a character
   device from `fstat`, and assert that no readable reopen occurs; replacing
   the first call with `O_RDONLY` must make that test fail. The dev-bind case
   can remain as an additional fail-closed check, but it cannot prove the
   no-device-open guard while `RESOLVE_NO_XDEV` short-circuits it.

2. **Canonical D12 states mutually exclusive descriptor contracts.** Its
   preamble still says “The checked object and the I/O object are always the
   same descriptor” (`plan:547`). The new protocol intentionally holds one
   `O_PATH` classification fd and opens a second readable fd through its proc
   magic link, then ties them by equal device, inode and type
   (`plan:550-559`). Replace the stale sentence with that same-inode,
   two-descriptor invariant so an implementer cannot choose the old order.
   The rev-8 history row also describes current reads as using `O_NONBLOCK`
   (`plan:616`); mark that clause superseded by rev 10.

### SHOULD

- **Make the two-instance oracle executable without process attribution from
  inotify.** S3.12 says browser B never opens the broker temp or workspace,
  “with every event attributed to A's writes” (`plan:1161-1163`). Inotify
  events do not carry a PID. Separate the observations: while A is idle, have
  B request a workspace write and require `home-locked`, no helper spawn and
  zero temp/workspace events; then independently hold A's write in flight and
  check its exact expected event and final-state sequence. Alternatively name
  a real process-attribution oracle.

The CodeCleanup review found no new conditional-side-effect, nesting or
literal-maintainability problem in this documentation-only diff. Agent Mail
5254 sent the blockers and SHOULD to BlackRobin.

## Claude Agent chat-drawer plan rev 11 (`2ce6f38`)

**Verdict at exact `2ce6f38`: APPROVED.** Both rev-10 blockers are closed.
S10.4 now tests the leaf-open order at both real owners through injected
syscall tables, including character, block, FIFO and socket classifications,
and its direct-`O_RDONLY` mutant fails before implementation can go green.
D12 now specifies classification fd, proc-link I/O fd, equal device/inode/type
acceptance and no other legal order. The old `O_NONBLOCK` history is explicitly
superseded. The plan is implementation-ready; one cross-process overlap test
remains a SHOULD and two wording/seam details are NITs.

This was a docs-only review. No browser, display, socket, site, build or test
was used. `git diff --check 8aa7329..2ce6f38` is clean, and the revision changes
only the plan. The plan remains pinned to production commit
`b4c23a1a56deced7b3ab7c8a34a660b22ffca622`; commits after that pin are
documentation only for this project.

### `8aa7329` finding disposition

| Prior finding | Rev-11 disposition |
|---|---|
| Bind-mounted device test exits at `RESOLVE_NO_XDEV` | **CLOSED.** Python `os_ops` and Zig `Sys` seams now make `openat2` succeed on the same mount, return each special type from `fstat`, assert `O_PATH|O_NOFOLLOW` is first and prove no I/O reopen follows. The old direct-open path and a direct-open mutant both fail (`plan:1575-1581`). The dev-bind case is correctly retained only as a mount-boundary check. |
| D12 says both one descriptor and two descriptors | **CLOSED.** The canonical sequence is classification fd, conditional proc-link I/O fd, and equality of device, inode and type; opening by pathname or before classification is forbidden (`plan:547-559`). The stale rev-8 `O_NONBLOCK` clause is marked superseded (`plan:622`). |
| Inotify cannot attribute an event to browser A or B | **CLOSED as an observation defect.** S3.12 separates an idle-A/B-refusal observation from A's broker-write observation and uses a deterministic pause seam (`plan:1167-1174`). The original dangerous overlap is not yet driven; see the SHOULD below. |

### Remaining SHOULD

- **Exercise B's lock refusal while A has a live broker temp.** Phase 1 asks B
  to write only while A has no operation in flight; phase 2 quits B before A
  creates the paused temp (`plan:1167-1174`). A buggy B that empties
  `.zb-broker-tmp/` *before* checking the owner lock produces no event when the
  directory is empty, so phase 1 passes, but it can still delete A's live temp
  in production. Pause A after the temp is fully written and closed, drain A's
  initial events, then start and Send in B. While A remains paused, require
  `home-locked`, no new B descendant, no additional temp/workspace event and
  an unchanged live temp. Only then release A and verify the paired move cookie,
  final digest and empty temp directory. This remains non-blocking because the
  exclusive-lock production design itself is complete.

### NITs

- D12's lead sentence says every existing object uses two descriptors
  (`plan:548`), while its next step correctly gives a special object only its
  classification fd (`plan:550`). Say “every accepted regular file or
  directory” in the lead sentence.
- The seam preamble says every e2e variable reaches the helper in `hello`
  (`plan:727`), but `ZIGBROWSER_AGENT_FS_PAUSE` acts in the app broker
  (`plan:739`). Name the app-owned exception, bound its wait, and state the
  filtered inotify mask plus matching move cookie used by the exact sequence;
  otherwise normal `IN_OPEN`/`IN_MODIFY` events make “exact” ambiguous.

The CodeCleanup review found no new conditional-side-effect, mutation,
nesting, literal or maintainability blocker in the docs-only diff. Agent Mail
5257 sent the approval, SHOULD and NITs to BlackRobin.

## Claude Agent drawer S1 (`2e467c4`)

**Verdict at exact `2e467c4`: APPROVED.** S1 implements the launch switch,
native GTK overlay and movable floating icon without adding a privileged page
or socket surface. The default remains off until S5. The closure e2e uses real
XTest input on a private Xvfb, proves the icon's allocation is its input region
rather than the full overlay, and drives primary-window, popup, persistence,
resize, pointer and keyboard paths through the real binary. Two narrow test
coverage SHOULDs remain below; neither exposes a production defect in the
reviewed implementation.

### Contract trace

| S1 contract | Evidence at `2e467c4` | Verdict |
|---|---|---|
| Flag/env/default and screenshot exclusion | `src/agent_config.zig:14-32` resolves flag > env > built-in `off`; its oracle property spans flag/env combinations (`:34-101`). `src/cli.zig:168-197,424-438` validates one exact `on|off` flag and keeps it out of screenshot mode. `src/app.zig:37-50` applies the setting before the first window. | PASS |
| One native overlay per accepted browsing window; off tree unchanged | `src/webkit_shim.c:1147-1190` performs the null, 16-window and id-exhaustion guards before the one attach call, and keeps the former direct `GtkWindow -> WebKitWebView` add when off. Popups traverse the same `zb_window_new`. `src/webkit_shim.c:970-975` detaches before the window record is removed/freed. | PASS |
| Movable icon and click pass-through | `src/agent_drawer.c:124-179` gives the icon exactly its 56x56 allocation, keeps resize placement in ratios and reports each new position; `:195-287` distinguishes a <=6 px click from a drag and implements clamped 16/64 px keyboard moves. `tests/e2e/agent_drawer_icon_test.py:255-316` sends four one-pixel-edge plus 25 seeded outside clicks and six inside clicks through libXtst; `:327-453` drives drag, clamp, popup inheritance, relaunch persistence and keyboard movement. | PASS |
| Page-world and socket isolation | The overlay contains only GTK widgets (`src/agent_drawer.c:298-340`) and is never installed into a `WebKitUserContentManager`, page DOM, script world or automation router. The real socket test sees only the browsing window and gets `-32601` for `agent.ping`, `drawer.open` and `secrets.get` (`tests/e2e/agent_drawer_icon_test.py:267-275`). | PASS |
| Default off until S5 | `src/agent_config.zig:16-17` fixes the built-in value to `off`; `src/webkit.zig:90-101,116-119` applies and checks it. The real-binary off case opens a popup and observes no `DRAWER` row (`tests/e2e/agent_drawer_icon_test.py:216-236`). | PASS |
| Existing zbHost promise settles both ways | `tests/fixtures/app/index.html:84-109` records the page-side promise branch in `document.title`; `tests/e2e/ipc_roundtrip_test.py:77-123` observes it independently through `page.evaluate`. This is an acceptable deviation from the plan's `--print-title` observer because that mode emits only the first title. The production zbHost chain is still the trigger. | PASS |

### Red-first and gate evidence

BlackRobin's timestamped S1 scratch logs precede the green runs and contain
real failures: `agent_config` and CLI rejected the new switch, all 11 drawer
unit stubs failed, and the unchanged binary produced no icon rows. Four
throwaway mutants were also killed: removing `zb_drawer_attach`, expanding the
icon allocation to the full window (0/29 outside clicks reached the page), and
removing either the success or rejection WebKit reply. Thus the new tests do
not merely characterize a permanently green seam.

The author's clean-export full gate log is green: **98/98 steps succeeded;
797/797 tests passed**. I independently ran a bounded clean export, deleted it
immediately afterward, and obtained:

- build: **5/5 steps succeeded**;
- `tests/agent_drawer_test.zig`: **11/11 passed**;
- real-binary private-Xvfb icon closure: **55 checks, 0 failed**;
- real-binary private-Xvfb zbHost round trip: **PASS** for success and bad-args
  rejection.

The X-input helper refuses `:0`, `:1` and any display outside its private
`:200-:399` range (`tests/e2e/xinput.py:34-53`); missing Xvfb, xauth, xwd,
libXtst or the binary is a hard failure rather than a skip
(`tests/e2e/agent_drawer_icon_test.py:456-484`). No live browser or live socket
was touched.

### Non-blocking test-completeness findings

- **SHOULD — drive `page.health` with the drawer on.** S1.5 names both
  `page.list` and `page.health`, but the new closure test only calls
  `page.list` before probing the three forbidden methods
  (`tests/e2e/agent_drawer_icon_test.py:267-275`). Source review shows the
  overlay does not enter either registry path, and the full gate keeps the
  existing health suite green, so this is missing direct coverage rather than
  a product blocker.
- **SHOULD — make close-during-load teardown observable.** The plan's S1.2
  edge asks for no leaked overlay when a loading window closes. Production
  calls `zb_drawer_detach` and frees the per-window allocation
  (`src/webkit_shim.c:970-975`; `src/agent_drawer.c:343-350`), and the private
  Xvfb harness leaves no browser or Xvfb process behind, but the S1 e2e never
  closes one popup while the process remains alive or asserts a live-drawer
  count. Add that lifecycle oracle when the next drawer slice extends the
  debug rows.

## Claude Agent helper prerequisite P0 (`e9b0cbf`)

**Verdict at exact `e9b0cbf`: BLOCKER.** P0 successfully establishes the
real-SDK/real-CLI/fake-API boundary, both token routes, all six hook events,
the in-process MCP round trip and most of the intended filesystem/PID
confinement. Its two new gate steps fail closed when the frozen helper runtime
is missing, and the author's clean-export gate is green at **100/100 steps and
797/797 tests**. However, the P0.5 non-hook child census is a set of a few
process snapshots rather than a lifecycle-complete census, so it can miss the
short-lived child that the downstream S3 security assertion is supposed to
reject. The claimed “full/exact D12” sandbox also omits D11/D12's outer
seccomp filter. Those claims must not become the foundation of S3/S4 as-is.

No live token, API, browser, socket or `DISPLAY :0` was used. The review read
the author's timestamped red/seam logs and green gate log, which use generated
canaries and the loopback fake Messages API. `git diff --check
e29d25b..e9b0cbf` and Python bytecode compilation of the new package/tests are
clean. In an independent clean export at exact `e9b0cbf`, the focused P0 suite
passed **31/31** (19 unit + 12 real-SDK/real-CLI/fake-API contracts) in 29.6 s.
The subsequent private-Xvfb team gate that included this tree passed **102/102
steps and 806/806 tests**. Both throwaway trees were removed after use.

### P0 contract trace

| Contract | Production/test evidence at `e9b0cbf` | Verdict |
|---|---|---|
| P0.1 own config | `options.py:54-69,87-105` makes the agent home authoritative and fixes `setting_sources=["user"]`, `cwd=workspace` and `tools=[]`. `test_contract.py:66-80` launches with a decoy HOME and observes only the agent marker at the real API boundary. | PASS |
| P0.2 fake API and R1/R3 | `token.py:31-57,60-101,104-145` validates fd 3, implements R3 and implements the R1 FIFO-to-wrapper-to-socket handoff. `test_contract.py:83-127` observes the real CLI's bearer, response, route list, refusing proxy, R1 environment absence, mode 0300 and FIFO unlink. | PASS, with finding 1's required plan amendment. |
| P0.4 all hooks and token absence | `provision.py:15-25,32-62` installs the allowlist and wraps hooks; `hook_run.py:20-68` refuses credentials and CLI messaging capabilities, closes fds and enters a nested PID namespace. `test_contract.py:138-177` observes exactly one dump and one notify POST for every event on R1 and R3, including PID 1 under R3. | PASS, with finding 2's required plan amendment. |
| P0.5 exact sandbox and censuses | `sandbox.py:13-54` constructs the outer mount namespace and `hook_run.py:40-55` the nested one. The real contracts prove helper/hook workspace `EROFS`, scratchpad writes, fd closure, hook PID separation, strict MCP and ignored planted MCP configuration (`test_contract.py:222-356`). | **BLOCKER:** the child census is incomplete and the outer seccomp filter is absent; details below. Findings 3, 4 and 6 also require a plan amendment. |
| P0.3 MCP round trip | `bridge.py:24-69` emits one tool call, correlates the result and answers before the CLI deadline; `options.py:21-23` fixes the production budgets. `test_contract.py:387-460` uses the real SDK/CLI to prove delayed stdin echo, built-in Read absence plus zero workspace open/access, helper timeout and CLI timeout. | PASS, with finding 5's required plan amendment. |

### BLOCKER findings

1. **The non-hook CLI-child census can miss the exact class it is meant to
   constrain.** Samples are taken only when the fake API receives a request
   and when the tool call is answered (`agent/host/tests/test_contract.py:243-260`).
   `non_hook_cli_children` later walks only those saved snapshots
   (`:295-311`), and the checked-in allowlist is consequently empty
   (`agent/host/tests/p0_census.json:2`). A short-lived CLI child created and
   reaped between the callbacks is invisible, yet rev 11 D11 and P0.5 require
   the census of non-hook CLI descendants, and S3.9 trusts that allowlist.
   Use lifecycle-complete observation (for example a continuous observer with
   a demonstrated observation bound or a process-event oracle) and start with
   a child that lives wholly between the current sample points; the present
   test must remain green before the fix and fail afterward.

   The requested mutation proves the gap: the clean-export CLI wrapper was
   changed to spawn and reap `/usr/bin/sleep 0.001` before executing the real
   CLI. `test_r1_enforced_sandbox` still passed in 2.0 s and printed
   `CENSUS_MUTANT_SURVIVED`; no saved API/tool snapshot observed the child.

2. **P0 does not run the “exact D12 sandbox” it claims.** Rev 11 D11/D12 keeps
   an outer seccomp filter denying `ptrace`, `process_vm_readv` and
   `process_vm_writev`, while still allowing the nested namespace operations.
   `sandbox.helper_argv` has no `--seccomp` option or filter fd
   (`agent/host/zb_agent_host/sandbox.py:24-54`), and neither P0 test mentions
   seccomp. Either exercise the real filter through the P0 real-CLI contracts,
   including successful nested hooks, or amend P0's scope before approval and
   make the real filter a failing-first prerequisite in S3. The current plan
   and commit cannot both call P0.5 the full/exact D12 sandbox.

### Six implementation findings: disposition

All six technical changes are **ACCEPTED**, and all six are **PLAN AMENDMENT
REQUIRED BEFORE S3/S4**. They are evidence produced by the intended P0
boundary probe, not ad-hoc product widening.

| # | Disposition and required rev-12 change |
|---|---|
| 1. R1 FIFO hangs | Accept `zb-claude` reading and unlinking the random FIFO, then placing the validated bytes on a socketpair fd 3 (`token.py:104-133`). Amend D7b, D11, P0.2 and S3.7: the FIFO is helper→wrapper only, the token briefly exists in wrapper memory, and wrapper→CLI is a socket descriptor. Preserve the installed-CLI probe. The author's literal-plan wrapper red waited about 66 s and failed, so the deviation is evidence-backed. |
| 2. CLI messaging capability in hooks | Accept refusing both `CLAUDE_CODE_MESSAGING_SOCKET` and `CLAUDE_CODE_MESSAGING_TOKEN` (`hook_run.py:20-28`); the P0 census confirms the real CLI supplies both. Add both names to D12's unconditional refused set and make P0.4/A4/S3.9 assert their absence independently of the OAuth canary. |
| 3. live `.claude.json` location and writes | Accept the observed live path `.claude/.claude.json`, keeping it and `backups/` read-only, and adding `sessions/` to the writable state union (`sandbox.py:13-20`; `test_contract.py:313-346`). Correct the host fact, D6 tree, D12 validator/mount text and S3.10/S3.11 paths. Explicitly distinguish the observed writes (`.claude.json`, `backups`, `projects`, `session-env`, `sessions`) from the reviewed writable union (`projects`, `sessions`, `session-env`, `todos`, `statsig`, `debug`, `MEMORY`); the first two remain read-only. |
| 4. nested mount order | Accept root bind first, then a minimal `/dev` and fresh `/proc` (`hook_run.py:40-55`). Replace D12's executable argv and retain the order unit test (`test_unit.py:145-155`); the old order either breaks `/dev/null` or exposes the outer `/proc`. |
| 5. in-process MCP timeout | Accept the observed CLI enforcement and the fixed 130,000 ms CLI / 120 s helper budgets (`options.py:21-23`; `test_contract.py:439-460`). Record those exact production values in D7/D7b/P0.3 and use them in S3/S5 timeout tests; retain the short scaled contract so the gate stays bounded. |
| 6. agent-home remount | Accept remounting the already-confined agent home after private `/tmp`, `/run` and `/dev/shm`, then reapplying read-only workspace constraints (`hook_run.py:46-55`; `test_unit.py:157-164`). Amend D12's exact order before S3. The failing first clean-export gate (98/100, four contract failures) and subsequent 100/100 gate demonstrate the seam. |

The plan's host-fact CLI version must also change from 2.1.296 to the frozen
SDK's bundled **2.1.294** (`pyproject.toml:1-7`, `p0_census.json:3`), and P0.5's
three named census artifacts must either remain separate as planned or the
plan must name and define the combined `p0_census.json` now checked in.

### Non-blocking implementation finding

- **SHOULD — complete atomic regular-file writes.** `files.atomic_write` calls
  `os.write` once (`agent/host/zb_agent_host/files.py:7-17`). A regular-file
  write may be short; installing the truncated wrapper, hook runner or JSON
  file after the subsequent `fsync`/rename violates the helper's own atomic
  write contract. Loop until every byte is written and add an injected
  short-write unit case before S3 provisioning makes this production setup.

Agent Mail 5273 sent the two blockers, all six amendment dispositions and the
version/census drift to BlueBeaver, with BlackRobin copied as plan owner.

## Chat drawer S2 (`aca3e33`)

**Verdict: BLOCKER-for-tests.** The native implementation at `aca3e33`
matches the user's requested shell: the drawer opens full-width at the bottom,
the icon is hidden, the header has `-` at the upper right, the message list is
scrollable, and the input row stays at the bottom. The GTK/frame-clock code
also appears to implement the intended fold into the last icon rect. However,
the blocking closure e2e does not observe the fold while it is visible. A
mutation that hides the stand-in for the entire animation still passes every
open/minimize check, so the test cannot distinguish the requested animation
from a 180 ms blank pause followed by the icon appearing.

No live browser, live socket, account, token or `DISPLAY :0` was used. The
author's exact clean-export private-Xvfb gate passed **102/102 steps and
806/806 tests**. The focused mutation below used its own private Xvfb and the
throwaway export was deleted.

### Contract trace

- **Bottom shell and hidden icon:** `src/agent_drawer.zig:74-82` computes the
  full-width bottom rect with the 40%/220 px/70% bounds;
  `src/agent_drawer.c:372-383` hides the icon, shows the panel and focuses the
  input. `tests/e2e/agent_drawer_test.py:74-103` drives the real icon through X,
  checks the exact bottom rect, top-right minus, focus and a page click at the
  old off-drawer icon position. PASS.
- **Conversation layout:** `src/agent_drawer.c:619-690` constructs header,
  vertical scroller/list and the final input row. The real-binary test checks
  widget order, 200-message scrolling, stable input/header pixels, unread
  behavior and a real 50 KB clipboard paste (`agent_drawer_test.py:83-88,
  156-234`). PASS.
- **Minimize behavior:** `src/agent_drawer.c:400-449` runs a real GDK
  frame-clock callback, updates the stand-in rect, re-targets after resize and
  restores focus/icon at the endpoint. The X e2e covers `-`, Escape and
  Ctrl+Shift+Space and reports 12 frames in its green run
  (`agent_drawer_test.py:105-150`). Production review PASS; closure oracle
  **BLOCKED** as below.
- **T1 isolation:** the drawer subtree contains only native GTK widgets
  (`agent_drawer.c:608-617,692-695`). The hostile top page, same-origin iframe,
  cross-origin iframe and related popup each see all five privileged handler
  names as undefined and all seven candidate `zbHost` methods as
  `UnknownCommand`; the full-viewport page overlay cannot intercept the real X
  clicks on the icon or minus (`agent_isolation_test.py:75-121`). The S1
  regression also sends `agent.ping`, `drawer.open` and `secrets.get` through
  the real automation socket and requires `-32601`
  (`agent_drawer_icon_test.py:119-130`). PASS.
- **Per-window lifecycle/default:** the S1 default remains off. The added live
  Zig driver proves primary + popup count 2, both normal and during-load popup
  close return it to 1 while the primary answers, and quit returns it to 0
  (`src/webkit.zig:1916-1994`). PASS.

### BLOCKER — the visible animation is unobserved

`tests/e2e/agent_drawer_test.py:105-118` waits for the implementation's final
`anim` row, checks its self-reported frame count and endpoints, then captures
only the final icon. It never samples a frame while the stand-in is visible.
In an independent clean export, changing `src/agent_drawer.c:447` from
`gtk_widget_show(d->ghost)` to `gtk_widget_hide(d->ghost)` made the fold wholly
invisible while leaving the frame clock, rows and endpoint intact. The focused
real-X test still passed **25/25** and exited 0 (`MUTANT invisible-fold`). Add a
deterministic intermediate-frame visual oracle and show this no-show mutant
red. An e2e-only pause after an intermediate allocation plus XWD pixels in the
reported intermediate rect would preserve the real X/GDK production chain.
Agent Mail 5278 sent this blocker to BlackRobin.

### Red-first and mutation evidence

The timestamped S1-binary runs precede the green implementation. The S2 unit
stubs failed five new assertions; the drawer e2e lacked `tree`, `minus`,
`anim`, scrolling and the demo seed; and the live drawer-count test expected 2
but observed 0. T1's negative reachability assertions were already true in S1,
as expected for an absent surface, while the new native-shell assertions were
red. Its security sensitivity is established by the later red-at-seam mutant:
registering a page-world `zbDrawer` handler failed in all four hostile
contexts. Five other mutants (disconnect minus, fixed target, WebKit view in
the drawer, forced scroll jump, and omitted detach) also went red. That T1
evidence is acceptable; the independent invisible-fold mutant is the remaining
gap.

### Plan/documentation follow-ups

- Rev 12 should add the implemented `DRAWER unread shown|hidden` row to D7b,
  narrow the impossible area property to componentwise shrink, and explicitly
  place the header account button in S4 rather than D1/S2. These are accurate,
  disclosed deviations, not extra S2 implementation blockers.
- NIT: `git diff --check e9b0cbf..aca3e33` reports a new blank line at EOF in
  `tests/e2e/agent_common.py:290`.

## Claude Agent chat-drawer plan rev 12 (`f035e47`, follow-up `2f363fd`)

**Verdict: BLOCKER before S3/S4.** Rev 12 correctly incorporates the six
accepted P0 discoveries, specifies failing-first replacements for both P0
blockers, and repairs the S2 plan contract. The new ptrace census itself is a
reasonable lifecycle-complete oracle, and the outer seccomp contract now has
both a real-CLI/nested-hook proof and an independent instruction-table proof.
Two documentation defects still prevent this from being an executable plan:
the S3 census seam is assigned to a channel that cannot install the tracer at
the required process boundary, and the plan still labels the pre-S1 baseline
as current HEAD after P0, S1 and S2 have landed.

This review covers the current two-commit revision: `f035e47` plus BlackRobin's
docs-only `2f363fd` follow-up. The latter correctly assigns the account button
to S4 and strengthens the mid-fold pixel oracle to sample page area outside
both endpoint rectangles. No live browser, socket, site, token, display,
build or test was used. Both docs diffs are clean under `git diff --check`.
All in-progress P0/S2 working-tree files were left untouched.

### Rev-12 amendment disposition

| Prior finding | Rev-12 disposition |
|---|---|
| R1 FIFO hang | **CLOSED in the plan.** D7b/D11 now make the FIFO helper-to-wrapper only, give the CLI a socketpair end on fd 3, disclose the wrapper-memory interval, retain the installed-CLI probe and make the old FIFO-as-fd-3 wrapper the red seam (`plan:311-322,466-490,927-936,1164-1168`). |
| Hook messaging capability | **CLOSED for the enforcing tests.** Both messaging names are unconditionally refused, and P0.4 plus the real-binary S3.9 test assert their absence by name independently of the token canary (`plan:565-569,938-946,1189-1195`). See the wording SHOULD below. |
| Live `.claude.json` path/writes | **CLOSED.** The live file is `.claude/.claude.json`; it and `backups/` remain read-only, `sessions/` joins the reviewed writable union, and observed writes are kept distinct from that union. S3.10 tests an outside change while S3.11 requires exact `EROFS` inside (`plan:141-143,214-223,536-552,1199-1238`). |
| Nested mount order | **CLOSED.** D12 fixes root, `/dev`, `/proc`, private tmpfs, agent-home remount and final read-only workspace order, explains why, and pins it with a unit red (`plan:570-586,949-964`). |
| Tool-call timeout | **CLOSED.** The CLI gets 130,000 ms, the helper resolves at 120 s, `ready` publishes the deadline, P0.3 keeps a scaled 10 s-margin contract and S3.2 observes the production values (`plan:263-270,336-346,980-985,1144-1155`). |
| Agent home under private tmpfs | **CLOSED.** The nested order remounts the confined agent home after private `/tmp`, `/run` and `/dev/shm`, then reasserts the workspace read-only (`plan:576-584`). |
| Sampled child census | **DESIGN CLOSED; test wiring BLOCKED below.** TRACEFORK/VFORK/CLONE/EXEC with the tracer as bwrap's parent can see the 1 ms mutant, fails closed when tracing is unavailable, and is re-proved in S3.9 (`plan:499-506,949-964,1193`). |
| Missing outer seccomp | **CLOSED in the plan.** D12 specifies arch/x32/syscall results and nested-namespace allowances; P0.6 runs the real CLI and hooks with the filter and has the no-filter `process_vm_readv` red (`plan:529-539,966-975`). |
| Short regular-file write | **CLOSED in the plan.** P0.7 injects one-byte writes and requires the complete content before fsync/rename (`plan:977-978`). |
| S2 visible fold and as-built drift | **CLOSED in the plan.** D7b gains `fold` and `unread`; S2.2 corrects the area domain and requires both draw-handler rows and a stretched real-XWD mid-flight pixel outside the open drawer and icon endpoints. The hidden-stand-in mutant must be red (`plan:364-375,1077-1101`). The implementation follow-up remains a separate code review/gate. |

### BLOCKER — the census shim cannot arrive through `hello`

D11 requires the test tracer to be the **parent of the outer bwrap**, with its
child calling `PTRACE_TRACEME` before `exec` (`plan:499-506`). S3.9 selects
that tracer through `ZIGBROWSER_AGENT_BWRAP` (`plan:1193-1195`). But the sole
e2e-seam contract says every listed variable, including that one, reaches the
helper inside its `hello` frame (`plan:769-779`). By then outer bwrap has
already launched and the helper exists inside it; a helper-delivered value
cannot retroactively install the helper's parent tracer. Following the seam
contract therefore loses the lifecycle-complete ancestry that is meant to
close the `sleep 0.001` blocker.

Split the seam table by owner. The app must consume and validate the absolute
tracer-shim/bwrap path only under `--e2e-protocol`, before spawn, and launch
the shim in the outer-bwrap slot. Specify that the still-running shim parent
forks a traced child which execs the real bwrap, preserves PDEATHSIG/EXITKILL,
and owns the outside log. Helper-carried values may continue through `hello`.
`ZIGBROWSER_AGENT_ANIM_MS` and `ZIGBROWSER_AGENT_FS_PAUSE` are also app/native
seams rather than helper frames and should be classified accurately.

### BLOCKER — the claimed current-state pin predates the built product

The frontmatter and opening claim every citation and current-state fact is at
HEAD `b4c23a1` and say "no implementation" (`plan:5-16,68`). At the reviewed
revision, committed P0, S1 and S2 precede it. The current production
`zb_window_new` already attaches `ZbDrawer` through a `GtkOverlay`
(`src/webkit_shim.c:1147-1240` at committed HEAD), while the plan's "Current
state analysis" still says the window has one direct WebView child and no
overlay (`plan:72-77`). ClosureMap A calls its table "at HEAD" but cites the
old registration/reply lines (`plan:803-813`); at committed HEAD those nodes
are `src/webkit_shim.c:692-769`. The semantic zbHost chain remains unchanged,
but its status and evidence citations do not.

The earlier requirement was that the ClosureMaps be pinned to current HEAD.
Before S3/S4, repin the plan to the latest committed product baseline, update
the built/current-state section for P0/S1/S2, and correct A/B citations (or
label the `b4c23a1` material explicitly historical and add a current map).
Also remove the false "no implementation" status. This matters directly to
S3/S4 because they extend the already-built drawer/window lifecycle.

### SHOULD and retained debt

- Section 3b says P0.4, A4 and S3.9 all assert the two CLI messaging names,
  but the A4 row and S4.4 still mention only the token canary
  (`plan:895-903,1288-1296`). P0.4 and S3.9 already protect the real boundary,
  so this is not another blocker; make the A4 wording match the claimed
  matrix.
- D7b permits a 512-byte token plus newline in the FIFO but labels the CLI
  socket payload as at most 512 bytes, while D11 reads up to 513 and does not
  state that it strips the newline (`plan:321-322,469-478`). Pin whether the
  wrapper strips the delimiter or passes at most 513 bytes so the protocol and
  implementation have one bound.
- Rev 11's cross-instance lock SHOULD remains open: exercise B's refusal while
  A has a fully written live broker temp, not only while A is idle.
- D3 still describes margins as the icon-placement mechanism, whereas the
  built S1/S2 code uses `GtkOverlay::get-child-position`. Fold that factual
  correction into the current-state repin.

The CodeCleanup plan-hygiene pass found no new side effect in a condition,
mutation in a control expression, nesting, magic-literal ownership or
maintainability blocker. Rev 12 centralizes the new deadlines, schemas,
refused names, mount order and BPF results in their owning contracts.

Agent Mail 5282 sent the two blockers to BlackRobin before this log entry.

### Addendum from P0's lifecycle-complete run (mail 5284)

BlueBeaver reported two new facts after the verdict was committed. They do not
change the BLOCKER result, but rev 12 must incorporate them before approval:

- The working complete oracle is **seccomp user notification**, not the ptrace
  implementation specified at `plan:499-506`. A supervisor outside the
  sandbox receives every inherited `execve`/`execveat` notification before the
  syscall continues, records the host PID/ancestry/path/argv, and then allows
  it. It catches the permanent `sleep 0.001` mutant while avoiding ptrace's
  multithreaded signal machinery. This is an acceptable design in principle,
  but D11, P0.5 and S3.9 must specify and test the mechanism actually being
  built. The app/pre-spawn seam blocker above applies equally: the listener
  and supervisor cannot be installed from the later helper `hello`.
- The complete census sees expected non-hook children `/usr/bin/git`,
  `/usr/bin/dash`, and the bundled CLI executable itself invoked as `rg`.
  Consequently rev 12's "absolute paths under `/usr` only" assertion
  (`plan:503-506,957,1193`) rejects a legitimate turn. Amend the reviewed
  allowlist and its evidence format with a narrow, version-pinned exception:
  the exact bundled-CLI realpath with `argv[0] == "rg"` (and the observed
  argument shape), recorded as `$CLI rg`; every other executable outside
  `/usr` remains a failure.

Agent Mail 5285 sent this addendum to BlackRobin and BlueBeaver.

## Chat drawer S2 visible-fold follow-up (`38e30e5`)

**Verdict: APPROVED. Status: CLOSED by `38e30e5` for the S2
BLOCKER-for-tests at `6fe538f`.** The minimize animation now has both a
production-chain draw observation and an independent on-screen pixel oracle;
the exact invisible-stand-in mutation that previously survived is red. No
live browser, socket, account, token or `DISPLAY :0` was used.

The code keeps the 180 ms production default and adds only a bounded,
e2e-protocol-gated duration seam. `src/agent_drawer.c:401-435` still drives
the real GDK frame clock. `src/agent_drawer.c:438-452` emits a `fold` row from
the stand-in's own `draw` handler, so a hidden widget cannot self-report a
visible frame; `src/agent_drawer.c:455-467` resets the observation state and
shows the stand-in before registering the tick. `src/agent_drawer.zig:113-132,
187-227,312-319` restricts `ZIGBROWSER_AGENT_ANIM_MS` to decimal 180--5000,
resets the process store to 180 at configure time and honours the value only
with `--e2e-protocol`; `src/app.zig:48-54` reads it before the first window.
Unset, refused and invalid values therefore leave the production duration
unchanged.

The closure case checks at least two actually drawn intermediate rectangles,
unique increasing frame numbers, non-growing dimensions and motion of every
edge toward the saved icon rectangle (`tests/e2e/agent_drawer_test.py:163-186`).
The new 3 s case first polls XWD at a fixed corridor point outside both the
open drawer and icon endpoint, then brackets a capture with adjacent draw
rows and samples a point inside both observed rectangles but outside both end
states; it also requires page colour immediately outside and again after the
fold (`tests/e2e/agent_drawer_test.py:189-243`). This is not merely a
self-reporting oracle.

Independent clean-export evidence at exact `38e30e5`:

- unmodified `agent_drawer_test.py --only fold` on its private Xvfb: **18/18
  checks, exit 0**;
- with only `gtk_widget_show(d->ghost)` changed to
  `gtk_widget_hide(d->ghost)`: **8 checks, 2 failed, exit 1**. The
  row-independent `xwd sees the fold pass over the corridor point` assertion
  failed, and no draw rows could straddle the capture. The throwaway export
  was then deleted with `find -delete`.

BlackRobin's clean-export full gate for the same six-file follow-up passed
**102/102 steps and 807/807 tests**; the preserved green fold case is 18/18,
and the author's same mutant also fails both pixel and draw-row oracles. No
new BLOCKER, SHOULD or NIT remains for S2.

## Claude Agent chat-drawer plan rev 13 (`52f8614`, follow-up `5fc0d57`)

**Verdict: BLOCKER before S3/S4.** Rev 13 closes the two rev-12 blockers at
`57d495d`/`313f0f8`: the production map is pinned to `38e30e5`, its cited
window, IPC and automation lines match that source, and the outer-bwrap
replacement is now owned by the app before spawn rather than arriving in a
later helper frame. The `5fc0d57` follow-up also narrows `$CLI rg` to the
observed listing flags and the two read-only roots actually seen by P0. Three
remaining contracts are not implementable or fail closed as written.

This was a docs-only review. I read the complete rev-13 delta and rechecked its
current-source anchors and cross-slice dependencies; both plan diffs pass
`git diff --check`. No live browser, socket, account, token, display, build or
test was used. The in-progress P0 follow-up was inspected read-only and left
untouched.

### Rev-12 finding disposition

| Prior finding | Rev-13 disposition |
|---|---|
| Outer-bwrap seam ownership | **CLOSED in the plan.** `ZIGBROWSER_AGENT_BWRAP` is app-owned and validated before helper spawn; D11/S3.9 put the oracle in that slot (`plan:834-856,1265-1267`). |
| Stale current-state pin | **CLOSED.** The plan distinguishes the built P0/S1/S2 state from the historical pre-drawer baseline, pins ClosureMaps A/B to `38e30e5`, and corrects the overlay placement mechanism. The cited anchors match the pinned source. |
| Seccomp-notification mechanism | **PARTIAL; BLOCKED below.** The mechanism replaces ptrace, but its documented topology and complete-record promise do not match the P0 implementation being described. |
| `$CLI rg` exception | **SHAPE CLOSED, observation BLOCKED below.** The intended accepted tuple is narrow and evidence-based, but bounded argv capture can omit a disallowed suffix. |
| Messaging names, 513-byte token handoff and phase-2b lock overlap | **TEXT CLOSED, phase-2b slice BLOCKED below.** Both names and one handoff bound are explicit; the live-temp test is assigned before its production path exists. |

### BLOCKER — S3.12 requires S8/S10 production paths

S3.12 phases 2 and 2b require an **approved** `fs_write workspace/...`, the
app-owned `agent_fs.zig` broker, its temp/fsync/rename path and the
`ZIGBROWSER_AGENT_FS_PAUSE=after-temp` seam (`plan:1306-1320`). S3's own file
list instead limits `agent_broker.zig` to submit/frame routing and contains no
`agent_fs.zig` (`plan:1354`). Approval first lands in S8
(`plan:1586-1618`); workspace file tools and `agent_fs.zig` first land in S10
(`plan:1680-1701,1755`). Therefore the demanded real-binary phase cannot be
red or green in S3 without either test-only substitution or prematurely
implementing two later slices.

Keep lock acquisition, idle-holder refusal and takeover in S3. Move the live
write phases 2/2b, including the pause seam and exact inotify sequence, to
S10, where the approved broker write exists. Alternatively, explicitly move
the complete approval and workspace-write dependencies into S3 and update its
files, closure test and slice ordering; a mock write would bypass the edge the
test is meant to protect.

### BLOCKER — the e2e CLI seam has no route to either process that needs it

Section 7 says every helper-carried seam travels only in chat `hello.e2e`, and
places `ZIGBROWSER_AGENT_CLAUDE_CLI` in that class (`plan:849-856`). But the
same seam selects an alternate installed CLI for synchronous `--agent-setup`
in S3.7 (`plan:1239-1242`) and the fake `setup-token` executable for S6's
separate one-shot login helper (`plan:1481-1488`). D7b explicitly gives the
login process only `start`, `code` and `cancel`; it has no chat `hello`
(`plan:350-410`). Thus neither required consumer can receive the value by the
only specified channel.

Split this seam by process or add an explicit, app-owned e2e field/argv for
the setup and login launches. It must remain absent without
`--e2e-protocol`, must not enter either helper environment, and each route
needs its own inertness test. Relatedly, S3.6 cannot prove every app-owned
seam at `plan:1323-1327`: approval TTL is first read when S8 mints a grant,
and FS pause is first read during an S10 broker write (`plan:840-847`). Scope
S3.6 to seams whose consumers exist in S3, and put the hostile TTL and pause
checks in S8 and S10 respectively. Merely scanning/logging those variables at
S3 startup would contradict the table's read-at-owner contract and would not
prove that the later consumer is gated.

### BLOCKER — the exec oracle can certify an incomplete record

D11 says the outside supervisor is bwrap's parent, sets
`PR_SET_PDEATHSIG(SIGKILL)`, kills its child and exits with bwrap's status
(`plan:549-565`). The P0 follow-up currently being described instead
double-forks a detached listener supervisor, then has the original tracer
install the filter and `execv` bwrap in place
(`agent/host/tests/exec_tracer.py:151-194`). The detached supervisor is not
bwrap's parent, has no stated death signal and cannot return bwrap's exit
status. The actual exec-in-place design may preserve bwrap's parent identity,
but the plan must describe and test that topology rather than promise a
different one.

More importantly, the current oracle reads at most 64 argv pointers and 512
bytes per argument without recording whether either bound truncated the
input (`exec_tracer.py:64-71,93-106`). The classifier accepts `$CLI rg` after
iterating only the recorded list (`agent/host/tests/test_contract.py:246-262`).
An otherwise allowed 64-argument invocation with a forbidden 65th path can
therefore be certified as `$CLI rg`, contradicting D11's "if and only if"
allowlist. Require complete argv/string capture or mark any truncation/read
failure `UNEXPECTED`, with failing-first cases for a disallowed 65th argument
and an over-limit argument.

D11 also promises `execveat` path resolution against its dirfd
(`plan:551-555`), while the tracer selects the path/argv arguments but never
uses `execveat`'s dirfd and resolves a relative path against cwd
(`exec_tracer.py:109-118,134-146`). Specify and test dirfd plus
`AT_EMPTY_PATH`, or fail closed on every unhandled `execveat`. The exact
allowlist is security evidence only if every allowed record is complete and
correctly resolved.

The CodeCleanup plan-hygiene pass found no independent issue with control-flow
side effects, mutation in conditions, nesting, or literal ownership. The
remaining defects are cross-slice and cross-process boundary contracts, not
formatting concerns. Agent Mail 5299 sent all three blockers to BlackRobin
and copied BlueBeaver before this log entry.

## Claude Agent chat-drawer plan rev 14 (`9f4f732`)

**Verdict: BLOCKER before S3/S4.** Rev 14 closes all three substantive rev-13
findings: the cross-instance live-temp phases now land with the real approval
and filesystem broker in S10.5; both setup and login receive the fake CLI only
through explicit app-owned launch argv; and D11 now specifies the oracle's
exec-in-place topology, completion marker, complete-record rule and fail-closed
`execveat` subset. One stale sentence in the normative S3.9 acceptance case
still prescribes the rejected parent topology, however. Because S3.9 is what
the implementer follows, that contradiction needs a narrow docs follow-up
before S3/S4 start.

This was a docs-only review. I read the complete rev-14 delta and rechecked the
affected cross-slice and cross-process contracts. `git diff --check
efbe1f1..9f4f732` is clean and the revision changes only the plan. No live
browser, socket, account, token, display, build or test was used.

### Rev-13 finding disposition

| Prior finding | Rev-14 disposition |
|---|---|
| S3.12 depended on S8/S10 | **CLOSED.** S3.12 retains lock acquisition, idle-holder refusal and takeover; approved-write overlap, `FS_PAUSE`, its 30 s bound and exact inotify/cookie oracle move together to S10.5 (`plan:1324-1333,1767-1779`). |
| Fake CLI had no route to setup/login | **CLOSED.** The app translates the gated environment seam to `--e2e-claude-cli <path>` only on the synchronous setup and one-shot login helper argv, never an environment or chat `hello`; S3.7 and S6.1 independently prove inertness without `--e2e-protocol` (`plan:847-866,1256-1260,1493-1505`). S3.6 is correctly limited to consumers that exist in S3, with later inertness checks owned by S8/S10. |
| Oracle topology/completeness/`execveat` | **CLOSED in D11/P0.5.** The original oracle process installs the listener and is replaced by bwrap in place, preserving PID, parent, death chain and exit status; the detached supervisor emits `END`, incomplete reads are UNEXPECTED, and only `execveat(AT_FDCWD, ..., flags=0)` is resolved (`plan:553-564,1041-1046`). The tests name the former 64-pointer and 512-byte blind spots, non-plain `execveat`, supervisor death and process identity. |

### BLOCKER — S3.9 contradicts D11's corrected process topology

The normative S3.9 result still says the app launches the oracle in the
outer-bwrap slot and therefore “it is bwrap's parent before the helper exists”
(`plan:1283`). D11 now correctly says the original oracle process installs the
listener and then `execv`s bwrap, so bwrap **replaces** it, retains the same PID
and retains the browser/contract as its parent (`plan:553-558`). Both cannot be
true. Replace the S3.9 sentence with the exec-in-place statement. The historical
R12-C row also retains “parent of bwrap” (`plan:739`) and should be marked
superseded or corrected so it cannot revive the rejected topology.

### NIT

- The opening citation note still says “Line references (rev 13)” at
  `plan:17`; call it rev 14 or omit the revision number.

The CodeCleanup plan-hygiene pass found no independent issue with conditional
side effects, mutation in control expressions, nesting, literal ownership or
maintainability. Agent Mail 5305 sent the topology blocker to BlackRobin and
copied BlueBeaver while the queued P0 review continued.

## Claude Agent helper prerequisite P0 follow-up (`77cbe96`)

**Verdict at exact `77cbe96`: BLOCKER, with both original `66af9e0`
blockers CLOSED.** The follow-up replaces the lossy `/proc` snapshot census
with a seccomp user-notification oracle that stops every descendant at
`execve`/`execveat`, and it passes the real outer BPF filter to bwrap. The real
SDK/CLI contracts observe `EPERM` in the helper and every hook while all six
nested hooks still run. It also closes the short-write SHOULD. Exact
`77cbe96` cannot yet be the approved P0 foundation, however: its records can
silently truncate argv and strings, it resolves non-plain `execveat` against
cwd, it has no completion marker, and its `$CLI rg` classifier accepts a
basename instead of the required literal `argv[0]`.

No live browser, socket, account, token or display was used. I reviewed the
exact ten-file diff and its red-first evidence; `git diff --check
9f4f732..77cbe96` is clean. BlueBeaver's clean-export gate for this exact
commit passed **102/102 steps and 807/807 tests**, including agent-host unit
**26/26** and contract **14/14**. A second, already-started follow-up is adding
the rev-14 completeness cases; this verdict intentionally describes the
committed `77cbe96`, not that uncommitted work.

### Original blocker disposition

| `66af9e0` blocker | Evidence at `77cbe96` | Disposition |
|---|---|---|
| Snapshot census misses a 1 ms child | `tests/exec_tracer.py:33-199` installs a user-notification listener before exec-in-place bwrap and records each still-valid notification before continuing it. `test_contract.py:431-439` permanently inserts `/usr/bin/sleep 0.001` between the former samples and requires it in the census. The author's pre-fix mutation survived the old snapshot test and failed this one. | **CLOSED.** |
| “Exact D12” omitted the outer seccomp filter | `zb_agent_host/seccomp.py:1-59` owns the BPF decision table; `sandbox.py:24-58` passes its fd before bwrap's `--`; and `test_contract.py:306-366` drives that production argv with the real CLI. Helper and all six hook probes require `EPERM`, while nested bwrap hooks and their isolated `/proc` still run. The oracle's stacked filter cannot fake this result because the proof is the four denied calls, not `Seccomp: 2` alone. | **CLOSED.** |
| Atomic regular-file short writes (SHOULD) | `files.py:7-30` loops to completion and rejects no progress. `test_unit.py:83-108` injects one-byte writes through both the helper and the installed atomic file. | **CLOSED.** |

### BLOCKER — exact `77cbe96` still certifies incomplete exec records

`_read_argv` stops after 64 pointers and `_read_cstring` callers cap argv
strings at 512 bytes without recording truncation
(`77cbe96:agent/host/tests/exec_tracer.py:64-71,93-106`). The classifier then treats the captured prefix
as the whole request. A forbidden 65th argument can therefore disappear behind
64 allowed entries and still become `$CLI rg`. The tracer also handles
`execveat`'s pathname and argv slots but ignores its dirfd and flags, resolving
every relative path against cwd (`exec_tracer.py:109-118,134-146`). Finally,
the detached supervisor exits on `POLLHUP` without an `END` record, and the
reader does not wait for or validate a complete log (`exec_tracer.py:121-147`;
`test_contract.py:368-370`). These are the exact rev-14 D11/P0.5 cases and
must land before P0 is approved. BlueBeaver acknowledged all three and is
adding complete-or-UNEXPECTED reads, the plain `execveat` subset, `END`,
supervisor-death and PID/parent/status tests in a follow-up commit.

### BLOCKER — `$CLI rg` accepts the wrong literal `argv[0]`

The reviewed exception requires `argv[0] == "rg"`, but
`test_contract.py:246-249` checks `os.path.basename(argv[0]) == "rg"`.
Consequently `/anything/rg --version` is certified as `$CLI rg`; a direct
read-only probe printed exactly that result. Require literal equality and add
an absolute `/anything/rg` case to the bad-shape table. This defect also
survives in the in-progress extraction to `tests/census.py` and is independent
of record completeness. Agent Mail 5306 sent it to BlueBeaver and copied
BlackRobin while the author's gate was still running.

## Claude Agent chat-drawer plan rev 15 (`7608e73`)

**Verdict: APPROVED. Status: CLOSED by `7608e73` for the sole rev-14 plan
blocker recorded at `5e54b07`.** S3.9 now states the same topology as D11: the
oracle installs its listener before sandbox work, then `execv`s bwrap in place;
bwrap retains that PID and the browser as its parent. The R12-C history row
strikes and explicitly supersedes its old “parent of bwrap” wording, and the
opening line-reference note no longer carries the stale rev-13 label. S3/S4
are no longer blocked by the plan review.

This was a docs-only exact-diff review. `git diff --check
9f4f732..7608e73` is clean, and the commit changes only the plan. No live
browser, socket, account, token, display, build or test was used. Agent Mail
5310 sent the approval to BlackRobin and copied BlueBeaver.

## Claude Agent helper prerequisite P0 closure (`de871e2`)

**Verdict: APPROVED. Status: CLOSED by `77cbe96` plus `de871e2` for all P0
blockers recorded at `66af9e0` and `5e54b07`.** The first follow-up supplied
the lifecycle-complete notification oracle, real outer seccomp filter and
complete writes. This second follow-up makes every accepted exec record
complete, fails closed on non-plain `execveat`, requires a counted terminal
`END` record, and enforces literal `argv[0] == "rg"`. P0 is now suitable as
the test foundation for S3/S4.

No live browser, socket, account, token or display was used. The exact
three-file diff passes `git diff --check`; no helper/product file changed.
BlueBeaver's clean-export full gate passed **102/102 steps and 807/807 tests**,
with agent-host unit **26/26** and contract **23/23**. I independently ran
those two suites from a clean archive of exact `de871e2`: unit **26/26** in
1.05 s and real-SDK/real-CLI/fake-API contract **23/23** in 32.83 s. The
throwaway tree was deleted immediately and left no process behind.

### `5e54b07` blocker disposition

| Blocker | Evidence at `de871e2` | Disposition |
|---|---|---|
| Truncated argv/string records and wrong `execveat` resolution | `tests/exec_tracer.py:80-155` reads pagewise strings and a NULL-terminated argv up to the named bounds, returns `complete: false` on read/bound failure, and resolves only `execve` or `execveat(AT_FDCWD, ..., flags=0)`. `tests/census.py:52-76` classifies every incomplete or unresolved CLI-descendant record as `UNEXPECTED` before considering existence or the allowlist. | **CLOSED.** |
| No completion marker or dead-supervisor proof | `tests/exec_tracer.py:170-197` writes `START`, counts only still-valid notifications, writes `END <count>` on listener HUP, and records before `CONTINUE`. `tests/census.py:34-49` waits at most 10 s for `END` and validates its count. The real tests kill the supervisor and observe `ENOSYS` plus no `END`, and separately preserve command PID, parent and exit status (`test_contract.py:342-376`). | **CLOSED.** |
| `$CLI rg` accepted a basename instead of literal argv zero | `tests/census.py:15-31` requires exact string equality. The bad table includes `/anything/rg`, `x/rg` and `rg `, while the real pinned CLI self-exec remains green (`test_contract.py:242-258,519-540`). | **CLOSED.** |

### Test-chain assessment

The nine `P05ExecOracle` cases are not helper-only assertions: they execute
the real seccomp notification tracer around real child processes and cover the
former 64-pointer/512-byte blind spots, both rejected `execveat` forms, log
completion, supervisor loss and process identity (`test_contract.py:290-376`).
The existing `P05Sandbox` cases then consume the same `census.load` and
classification through the real SDK, pinned CLI, outer bwrap and all six hook
events (`test_contract.py:379-540`). Against the `77cbe96` tracer, the author
recorded six failures and one error, including both former `$CLI rg` bypasses;
the topology identity case stayed green as expected.

### NIT

- `test_contract.py:396-401` still calls the tracer “the parent of bwrap” in
  a docstring. The code and `test_the_traced_command_keeps_its_pid_parent_and_exit_status`
  correctly prove that bwrap replaces it in place. Align the comment when this
  test file next changes; it does not affect this approval.

## Claude Agent chat-drawer plan rev 15.1 (`be46e05`)

**Verdict: BLOCKER.** The narrow changes requested in mail 5316 are otherwise
correct: S3 owns one production read-only token-file loader and the explicit
file-store selection while S4 owns keyring/UI/write/remove; S3.11 now proves
the same-session prompt/stop events without pretending a browser tool exists;
S7.6 owns the real `get_text` continuation; and S3a/S3b/S3c each have their
own red/green/gate/review boundary. The revision also accurately records S3a's
as-built package-copy layout. But replacing the per-home venv with a shared
runtime introduced a production dependency that no slice produces.

This was an exact docs-diff review against rev 15. `git diff --check
7608e73..be46e05` is clean and the plan commit changes only the plan. I read
the complete affected contracts and rechecked them against the built S3a
path. No live browser, account, socket, token or DISPLAY `:0` was used.

### BLOCKER — the production helper runtime has a consumer but no producer

D6 now records an interpreter from `ZB_AGENT_HOST_PYTHON`, else
`/usr/lib/zigbrowser/agent-host/bin/python`, and a copied helper package from
the analogous shared install (`plan:268-273`). S3a implements those consumers
in `app.zig:54-65`. Nothing in the plan assigns creation, locked dependency
installation, compatibility/update handling or cleanup of that shared runtime
to a slice, however, and `build.zig` installs only the browser executable. A
normal `zig build install` therefore leaves the default path absent.

The real-binary S3a test cannot catch this: `agent_setup_test.py:83-86`
injects both the cached developer interpreter and the source package directory.
Without those undocumented production-capable overrides, the ordinary built
binary exits with “agent runtime missing.” Add an owned production installation
contract and a clean-install closure case that sets neither override. A single
shared runtime is acceptable; a hypothetical `/usr/lib` tree is not.

### SHOULD — make the status paragraph match the repository it describes

The rev-15.1 status still says the P0 blocker follow-up is in review and S3 is
unbuilt (`plan:8`), although P0 is approved at `fa0aa48` and S3a is already
built at its parent, `abbf0ea`. This does not alter the design, but a plan whose
status is used as the implementation ledger should name the approved P0 chain
and built S3a exactly.

The CodeCleanup plan-hygiene pass found no new side-effecting or mutating
control-expression, nesting or literal-ownership problem in the narrow plan
delta. The blocker is a missing production boundary and closure test. Agent
Mail 5331 sent it to BlackRobin before this entry.

## Claude Agent drawer S3a (`abbf0ea`)

**Verdict: BLOCKER despite a green gate.** The production chain is real:
`--agent-setup` is parsed by the binary, the app builds a fixed argv/environment,
the C seam holds the owner lock and synchronously starts the helper, and the
Python setup command stages the copied SAI and probes the real bundled CLI
through the R1 wrapper/FIFO/socket path. The tests do not call provisioning
functions in place of that real-binary chain. Five implementation
correctness/security gaps remain, none of which the current 12 unit and 50 e2e
checks exercise; the plan's missing production-runtime producer is a sixth,
shared closure gap.

I reviewed all 27 files in the exact commit, ran direct read-only probes in a
clean archive, and ran one bounded independent clean-export gate at exact
`be46e05` under private Xvfb. The gate was **GREEN: 104/104 steps succeeded;
813/813 tests passed**. The new provisioning unit suite was 12/12 and the S3a
real-binary e2e was 50/50. The tree was deleted immediately. No live browser,
account, user token, live socket or DISPLAY `:0` was touched.

### BLOCKER 1 — a failed re-provision can delete live transcripts and state

`install()` moves each existing `.claude` state directory into the cleanup-owned
staging tree before the first exchange (`setup.py:273-281`). If that exchange
raises, `provision()` deletes staging recursively (`setup.py:301-303`). A clean
fault-injection probe created `projects/keep.jsonl`, made the first exchange
raise `OSError`, and observed `state_survived=False`. The only live copy had
been deleted. Preserve the existing tree until commit or implement and test a
rollback at every install boundary. The first-install per-entry path also
needs interruption recovery: because the owner lock creates the home first,
the nominal one-rename first-install path is not used, and a kill before the
marker can leave colliding partial entries.

### BLOCKER 2 — the copied-text scanner permits forbidden root paths

`PATH_RE` requires at least two slash components (`setup.py:48-50`). Thus
`rewrite_text("read /secret", "/home/u", "/agent", "x.md")` returns
`/secret` unchanged, as do `/tmp` and other one-component absolute paths. The
committed unit test even blesses `/create_tdd_plan` (`test_provision.py:116-119`),
while S3.1 says **every** absolute path outside the six roots and agent home
must refuse. Define any slash-command exception narrowly enough that it cannot
also certify an OS path, and add copied Markdown/JSON/hook-support cases.

### BLOCKER 3 — an absent source HOME rewrites every absolute path

The prefix predicate treats an empty source root as the parent of every
absolute path (`setup.py:82-91`). `app.zig:49-68` passes an empty string when
HOME is absent, a reachable production case with absolute XDG_DATA_HOME and an
explicit `--sai-source`. The probe
`rewrite_text("/srv/private/x", "", "/agent", ...)` produced
`/agent/srv/private/x` rather than refusing it. Require a nonempty absolute
source HOME before prefix rewriting, or disable rewriting and apply the strict
outside-path rule when no valid prefix exists. Cover it through the real binary.

### BLOCKER 4 — the atomic exchange syscall number is x86_64-only

`exchange()` calls raw syscall 316 (`setup.py:243-255`). That is
`__NR_renameat2` on x86_64, but Linux asm-generic/aarch64 defines it as 276.
The implementation therefore fails or calls the wrong syscall on another
supported Linux architecture. Use libc's typed `renameat2` export (failing
closed if unavailable) or an architecture-correct named syscall mapping and
test it. An unqualified numeric ABI literal also fails the CodeCleanup
named-literal/externally-owned-value gate.

### BLOCKER 5 — the setup child can survive the browser's death

The child callback only calls `prctl(PR_SET_PDEATHSIG, SIGKILL)`
(`agent_host.c:39-48`). If the browser dies after fork but before that call,
the child is reparented first; its later `prctl` no longer observes the dead
browser. This contradicts `agent_host.h:13-16`'s promise and can leave the
setup helper or route-probe CLI behind. Pass the expected parent PID, set the
death signal, immediately compare `getppid()` with that PID and exit on a
mismatch. The regression must assert no descendant remains before harness
cleanup.

### Shared BLOCKER — the e2e bypasses the absent production runtime

The runtime-producer finding above applies equally to S3a. The e2e's injected
`ZB_AGENT_HOST_PYTHON` and `ZB_AGENT_HOST_DIR` prove the developer route, not
the new `/usr/lib` default. Add the real installed-runtime case before S3a can
close its production edge.

### SHOULD / NIT

- `agent_setup_test.py:96-121` calls `communicate(timeout=180)` without a
  `finally` that terminates and reaps the setup process and descendants after
  timeout. Given the project's prior orphan leaks, make timeout teardown
  explicit and test it.
- `select_route()` performs the process/network probe directly in an `elif`
  predicate (`setup.py:321-330`). Separate that effect from the condition so
  the branch is a pure question and probe failures are easier to diagnose.
- `git diff --check abbf0ea^..abbf0ea` reports a new blank line at EOF in
  `tests/e2e/agent_common.py:345`.

Agent Mail 5328–5331 sent the blockers to BlackRobin during the review. The
green gate result and free slot were mailed as 5333.

## BLOCKER — accelerated WebKit plus the GTK3 drawer overlay blanks NVIDIA/X11

**Status: CLOSED by `60ce3b6`.** The fixed build passed the required
user-observed default-case-J NVIDIA/X11 check on 2026-10-14: the page and S
icon drew, the icon dragged, the drawer opened at the bottom, and `-` folded it
back into the icon. The original failure and evidence follow for provenance.
On the user's real X11/NVIDIA RTX 3080 screen,
the exact `fa0aa48` build with the case-J default (WebKit policy plus
`WEBKIT_DMABUF_RENDERER_FORCE_SHM=1`) draws only the GTK window background when
`--agent-drawer on`; neither the loaded page nor the orange icon is presented.
The same live page remains fully responsive through the read-only socket, and
drawer-off draws normally. A repeat with `--hardware-acceleration never` draws
both page and icon. This is therefore a presentation failure in the accelerated
UI path, not a page load, WebProcess, automation-FIFO or GTK-main-loop failure.

I reviewed the exact `fa0aa48` sources; `src/agent_drawer.c` is byte-identical at
`7eab90f` (`sha256 1cadccf...579`). The local widget logic does not explain a
zero-sized or opaque cover:

- `zb_drawer_attach` makes the WebView the `GtkOverlay` main child and adds the
  icon, panel and ghost only as overlay children (`agent_drawer.c:734-766`).
- The position callback handles only those three overlay children and never the
  main WebView (`agent_drawer.c:194-223`). GTK allocates the main child to the
  full overlay allocation.
- The panel and ghost have `no-show-all` before the toplevel's later
  `gtk_widget_show_all`; both remain hidden initially (`agent_drawer.c:691-695,
  749-752`; `webkit_shim.c:1239`).
- The ghost draw callback returns `FALSE`, so it does not stop draw propagation
  (`agent_drawer.c:438-453`). The CSS selectors are confined to named drawer
  widgets (`agent_drawer.c:94-109`).

The high-confidence root cause is the GTK3 `GtkOverlay` presentation topology,
not the EventBox alone. GTK 3.24's own
[`gtkoverlay.c`](https://raw.githubusercontent.com/GNOME/gtk/gtk-3-24/gtk/gtkoverlay.c)
creates a `GDK_INPUT_OUTPUT` child `GdkWindow` for **every** overlay child and
sets it as that child's parent window (upstream lines 133-160); hidden children
still get these windows at realize, and visibility controls only whether each
window is mapped (lines 277-299, 383-437). WebKit
[`bug 90085`](https://bugs.webkit.org/show_bug.cgi?id=90085) documents the same
architectural failure: an accelerated WebView behind GtkOverlay child windows
breaks overlay composition; the reporter found that disabling accelerated
compositing avoided it and traced the issue to transparency/native child-window
composition. The user's live acceleration differential is consistent with
that mechanism. Case J forces shared-memory frame transport, but it does not
disable WebKit accelerated compositing or GTK's NVIDIA GL presentation.

### Private-Xvfb attempt and coverage limit

I verified that private Xvfb advertises GLX, Composite, DAMAGE and RENDER, then
ran the existing real-binary pixel oracle with
`LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe` under the harness's private
Xvfb. `agent_drawer_icon_test.py --only clicks` passed **15/15**: the known blue
page pixels appeared outside the icon, the orange fill and white `S` appeared
inside it, all 29 outside clicks reached the page, and icon clicks did not. The
complete exact-`7eab90f` clean gate was also green: **104/104 steps succeeded;
816/816 tests passed**. This confirms that the existing oracle checks the right
pixels, but software GL cannot reproduce the proprietary-NVIDIA presentation
path. No DISPLAY `:0`, live socket, account or live browser was touched.

### Required fix and red-first proof

Do not accept `gtk_event_box_set_visible_window(FALSE)` by itself: GtkOverlay
still creates its own output parent window for that child, and also creates
ones for the icon and panel. The durable product fix is a drawer host that does
not introduce GtkOverlay output child windows around an accelerated WebView
(for example, a proven no-window custom/fixed container), or an explicitly
accepted acceleration-policy fallback while the drawer is enabled. A separate
floating toplevel is another possible topology, but must preserve focus,
stacking, pop-up ownership and click-through contracts.
`--hardware-acceleration never` is a confirmed workaround, not yet an acceptable silent global policy
change.

Red first:

1. Reuse the current X11 pixel oracle on the affected NVIDIA host: under the
   default case J it must see both a distinctive page pixel outside the icon
   and orange/white icon pixels. The current build is red; drawer-off and
   `--hardware-acceleration never` are the controls.
2. Add an e2e-only realized-surface census and a private-Xvfb structural test
   that fails the current `GtkOverlay` hierarchy because it creates output
   child GdkWindows, then passes only on the chosen no-child-window topology.
   Keep the existing input and pixel assertions as the behavioral regression.
3. The fixed scratch build must pass the real-screen default-J pixel case before
   this blocker closes. A green llvmpipe gate alone cannot close it.

Agent Mail 5345 sent the source evidence, the Xvfb result, the matrix correction
(`--renderer shm` is already the failing default) and the test requirement to
BlackRobin.

### Real-screen differential update

The orchestrator's first controlled real-screen variant is decisive within the
limits of the current matrix: exact `fa0aa48`, drawer on and
`--hardware-acceleration never` presents both the page and the S icon on the
same NVIDIA/X11 host where default case J presents neither. This closes the
generic GTK visibility, show/realize, zero-allocation and opaque-cover
hypotheses. It strengthens the class-level diagnosis to **WebKit accelerated
composition interacting with the drawer's GTK child-window topology**. It does
not yet identify which child window is necessary: the pending empty-overlay,
icon-only and no-ghost variants must distinguish “any overlay output window”
from the ghost EventBox's additional descendant window.

The second controlled variant, `--renderer mesa-egl`, also presents both the
page and the S icon. On that passing variant the user moved the icon, opened the
drawer and left it open without instability. The failing intersection is thus
more specific: the proprietary-NVIDIA GL presentation route plus the
accelerated WebView/overlay child-window topology. Accelerated presentation via
Mesa EGL is good; WebKit acceleration disabled is good. The interaction and
lifetime behaviors are good wherever pixels are presented. The pending
`WEBKIT_DISABLE_COMPOSITING_MODE=1` result is a final mechanism cross-check, not
needed to distinguish page/widget logic from the NVIDIA presentation defect.

That final cross-check eventually presented the page and icon, but only after
roughly 20 seconds of severe load-time jitter and flicker. The complete
user-observed NVIDIA matrix is therefore: drawer off good; drawer on with
default case J permanently blank; hardware acceleration never good; Mesa EGL
good; WebKit compositing disabled eventually good but operationally unusable.
None of the environment/policy variants is an acceptable silent product
fallback. BlackRobin owns the no-child-window drawer-host fix; closure requires
the structural GdkWindow census to kill the old topology and the corrected
on-screen pixel oracle to pass the fixed build on the user's NVIDIA screen.

One correction to the proposed fix space: a generic no-window parent cannot
paint the drawer above a WebKitWebView that owns a native child `GdkWindow`;
the native child wins stacking over parent painting. If only `no-ghost` passes,
remove the EventBox's extra window and retain the overlay parent window. If
`icon-only` fails, the realistic candidates are separately shaped native child
windows or a separate app-owned transient surface, with focus, stacking,
click-through and circular-shape tests. Disabling acceleration remains a proven
workaround but conflicts with the media/rendering reason case J exists, so it
is not a silent product fix.

## Claude Agent chat-drawer plan rev 15.3 and hardware check (`d9674c1`)

**Verdict: BLOCKER.** This docs/manual-test commit makes useful progress: it
removes the stale per-home-venv claim, defines marker publication as the setup
commit point, explicitly repairs markerless first installs, rejects dot
segments, reopens S1/S2 for the real NVIDIA failure, and requires a real-screen
check for every UI slice. It touches no product code, and `git diff --check
d9674c1^..d9674c1` is clean. Its independent exact clean-export gate under
private Xvfb is **GREEN: 104/104 steps succeeded; 816/816 tests passed**. Four
contracts remain insufficient.

### BLOCKER-for-test — the real-screen verdict ignores the real screen

`tests/manual/real_screen_check.py:152-163` captures both the client window and
the root window, but computes `page_px`, `icon_px` and the pass/fail result only
from `xwd -id`. A compositing failure can leave a correct client backing pixmap
while presenting blank pixels on the root window—the exact distinction this
test was introduced to catch. The root crop is merely written to disk. Make the
root/on-screen crop authoritative, or require both captures to pass, and add a
unit/fake-capture mutant where the client capture is correct but the root crop
is blank. It must fail.

### BLOCKER-for-test — matrix cases inherit stale rendering overrides

`real_screen_check.py:129-133` copies all of `os.environ`, removes only the
automation socket and then overlays the case environment. A caller's stale
`GDK_GL`, `WEBKIT_DISABLE_COMPOSITING_MODE`,
`WEBKIT_DMABUF_RENDERER_FORCE_SHM`, `WEBKIT_DISABLE_DMABUF_RENDERER`,
`__EGL_VENDOR_LIBRARY_FILENAMES`, `LIBGL_ALWAYS_SOFTWARE` or `GALLIUM_DRIVER`
can silently change every labelled matrix case. Clear all app/WebKit/GDK/GL
render overrides before applying a case's explicit values; preserve only the
display/authentication environment needed to reach the user-approved screen.

### BLOCKER — copied names can still turn OS paths into slash commands

The new prose-position grammar (`plan:1270-1275`) closes the exact `rm`, `open`
and assignment examples, but it still trusts arbitrary copied command and skill
names. A copied skill named `tmp` makes ordinary prose such as `stored in /tmp`
match both a known name and the allowed lead word `in`; `etc` and `proc` are
equally dangerous. The untrusted copied tree must not expand an absolute-path
exception into root-filesystem names. Define a fixed non-path namespace or
refuse copied names that collide with reserved/root path components, with
failing-first `/tmp`, `/etc` and `/proc` collision cases.

### BLOCKER — the interrupted-install and descendant-death tests are not closed

The first-install paragraph says it SIGKILLs setup at each entry move “through
the spawn-delay seam” (`plan:1268`), but the seam is defined only before the
child's `prctl`/parent check (`plan:864`). It cannot synchronize any install
move. Add a separate bounded, e2e-only per-step pause/fault seam (and prove it
is inert outside `--e2e-protocol`) or name another concrete synchronization
mechanism.

Rev 15.3 also predates the exact route-probe result in the companion S3a
review: the CLI survives browser SIGKILL after the real R1 probe begins. The
plan still needs a complete helper-descendant death contract and a regression
that synchronizes after a sleeping probe CLI starts, kills the browser, and
observes both helper and CLI gone before harness cleanup. Protecting only the
immediate setup child is insufficient.

Agent Mail 5350 and 5352 sent these test and plan findings to BlackRobin.

## Claude Agent chat-drawer plan rev 15.2 (`7eab90f`)

**Verdict: BLOCKER.** The revision correctly assigns the production runtime to
S3a, gives it an executable-relative location and clean-install closure case,
and records the direct fork-to-`prctl` race, typed `renameat2`, expanded path
scan and invalid-HOME rules. It does not close the complete contracts it says
the implementation satisfies, and two old passages now contradict the new
runtime design.

This was an exact docs-diff review against rev 15.1. `git diff --check
7eab90f^..7eab90f` is clean. The implementation findings below were reproduced
against the plan's companion commit `4e3b09c`; the independent clean-export
gate at exact `7eab90f` was **GREEN: 104/104 steps succeeded; 816/816 tests
passed** under private Xvfb.

### BLOCKER — rev 15.2 overclaims setup rollback and descendant death

The new hardening contract says any failure restores the old home
(`plan:1234-1239`). The implementation catches failures only through the second
exchange, not later marker/cleanup work, and first install is still a sequence
of unrelated renames. The exact failure probes in the S3a review below leave
partial or new state live. Likewise, the parent-death regression says no setup
helper may survive, but the security contract that prompted it included its
route-probe CLI descendant; that child demonstrably survives browser SIGKILL.
Name and test the complete process tree, not only an argv pattern for the direct
helper.

### BLOCKER — the runtime and file inventory contradict the new design

The production-runtime section says `install_agent_runtime.sh`/`zig build
agent-runtime` creates one locked shared venv (`plan:1225-1232`). The out-of-scope
section still says packaging/shipping the venv is excluded and
`--agent-setup` creates it with uv (`plan:783`); S3a does neither. Replace that
stale sentence with the actual shared-runtime/package boundary. S3.1's files
list also still names nonexistent `provision.py` and omits `setup.py`, the
installer and runtime build target (`plan:1269`). A TDD ownership list cannot
route a fix to the wrong module.

## Claude Agent drawer S3a follow-up (`4e3b09c`)

**Verdict: BLOCKER despite a green gate.** Four prior findings are genuinely
closed: a normal clean install now has a real locked runtime producer and no
developer override; empty/relative/root HOME refuses; `renameat2` uses the
typed libc symbol; and timeout teardown, `select_route` control flow and the
EOF whitespace NIT are fixed. The direct child now also closes the narrow
fork-to-`prctl` race. Five correctness/security failures remain.

I reviewed all 11 changed files, ran exact function-level fault/path probes,
ran a real-binary browser-death probe, and ran the bounded clean-export gate
reported above. The real-binary probe used only a canary sleeping fake CLI; it
was killed and the throwaway tree was deleted immediately. No live browser,
socket, account, token or DISPLAY `:0` was touched.

### BLOCKER 1 — interrupted first install is neither atomic nor recoverable

The browser creates the home and owner lock before setup, so production always
takes `install()`'s per-entry first-install branch (`setup.py:306-320`), never
the advertised one-rename branch. Injecting failure on its second destination
rename left the home containing `.zb-owner.lock` and `runtime` but no marker.
An ordinary retry then failed `ENOTEMPTY` on the existing runtime. No committed
test kills or faults this branch. Stage a complete sibling and install it with
one recoverable directory operation, or explicitly detect and replace a
markerless partial home while preserving only the validated owner lock.

### BLOCKER 2 — slash-command exceptions still certify filesystem paths

`rewrite_text` accepts a known `/name` wherever it occurs
(`setup.py:84-108`). Exact probes accepted `rm /clear`, `open /help` and
`path=/status`. More seriously, arbitrary copied `commands/*.md` stems and
`skills/*` names join that allowlist (`setup.py:156-163`), so a copied skill
named `tmp` certifies `/tmp`. This does not meet the earlier requirement that a
slash-command exception cannot also bless an OS path. Restrict the exception
to an unambiguous command grammar and reject command/skill names colliding with
root filesystem entries.

### BLOCKER 3 — raw-prefix containment accepts dot-segment escapes

`under()` compares the unnormalised matched string (`setup.py:93-105`). Exact
probes accepted `/usr/../secret`, `/proc/self/../../secret` and
`/agent/../secret`; `/home/u/../other` was rewritten to
`/agent/../other`. Normalize lexically before containment/rewrite, then apply
the root rule to the normalized path. Add all four cases as red tests.

### BLOCKER 4 — late re-provision failure leaves an uncommitted new home live

The rollback `try` ends after the runtime exchange (`setup.py:324-336`). The
following mkdirs, marker replacement and staging cleanup are outside it
(`setup.py:337-340`). Injecting failure at the marker replacement after changing
the source `CLAUDE.md` raised from setup but left the changed configuration and
runtime live (`home_unchanged=False`). The old swapped trees were then deleted
by `provision()` cleanup. Extend the transaction/rollback through every
fallible post-swap operation; test marker replacement and cleanup failures, not
only the two exchanges and one state move.

### BLOCKER 5 — the route-probe CLI survives browser death

`die_with_browser` arms PDEATHSIG only for the direct setup child
(`agent_host.c:39-56`). Its CLI subprocess does not inherit that contract. In
the exact real-binary repro, the fake CLI returned its version, wrote its PID
only when the actual R1 probe started, and slept. After the browser was
SIGKILLed and one second elapsed, the result was:

```
BROWSER_KILLED cli_pid=2645604 state=S cli_survived=True
```

The committed regression cannot see this: it kills during the pre-exec delay,
and `helpers_for()` only reports argv containing `zb_agent_host setup`
(`agent_setup_test.py:279-314`). Start setup and its probe in a process
group/PID namespace whose lifetime is tied to the browser, then synchronize the
test after a sleeping probe CLI starts and assert both helper and CLI are gone
before harness cleanup. Agent Mail 5347 sent the exact repro to BlackRobin.

### SHOULD / NIT

- `install_agent_runtime.sh:13-20` updates the shared venv and package in place
  and publishes `runtime.json` last, with no lock or atomic directory swap. A
  concurrent browser/setup or interrupted upgrade can observe a mixed runtime.
  Install into a sibling staging directory, fsync/publish atomically, and lock
  writers/readers before this becomes a packaging path.
- `runtime_lock()` silently turns a missing or malformed runtime manifest into
  `null` (`setup.py:238-244`). S3b's promised compatibility check must refuse
  that state; it must not treat two unknown hashes as compatible.
- Check the return from `prctl(PR_SET_PDEATHSIG, SIGKILL)` and fail closed.
- `test_provision.py:213` reads `setup.__file__` without closing it, producing a
  `ResourceWarning` during the otherwise-green gate.

## Real-screen oracle follow-ups (`220af5a`, `607c3a3`)

**Verdict: `220af5a` APPROVED as a diagnostic utility; `607c3a3` BLOCKER-for-test.**
The page-only variant is correctly separate from normal drawer variants and is
useful for the scratch topology bisect. The later commit fixes both substantive
oracle defects from the `d9674c1` review:

- `judge()` requires both the root/on-screen crop and the client buffer to show
  the page and, when required, icon (`real_screen_check.py:119-131`);
- `case_env()` removes the enumerated GDK/WebKit/EGL/GL overrides and every
  `ZIGBROWSER_*`/`ZB_*` variable before applying a case (`:57-66,134-141`);
- the window is activated before capture, the output reports both views, and a
  failed drawer-off control invalidates the run (`:234-243,294-304`).

The six fake-capture/environment tests pass directly in 0.077 s. Their two
central cases are appropriate: a good client buffer over a blank screen fails,
and planted render variables do not reach a case. However, the new test module
is absent from `build.zig`, the gate script and every existing test runner.
`rg real_screen_check build.zig tools tests` finds only the manual files and a
doc reference. Consequently both reviewed mutants can regress while every
required gate remains green. Add the module as a bounded `zig build test`/gate
step and demonstrate both mutants fail through that step.

**SHOULD:** require the root crop to equal the full captured window geometry,
or fail the run explicitly. The current `min()` crop (`:239-243`) can judge a
partially off-screen window over a smaller area; reporting both dimensions
would make positioning/capture failures diagnosable.

## Claude Agent chat-drawer plan rev 15.3b (`0524293`)

**Verdict: BLOCKER (one drivability ambiguity).** The revision substantively
closes the slash-name collision and descendant-death findings. It refuses names
present under `/` or in a fixed reserved-root list, with copied `tmp`/`etc` and
prose `/tmp` as red cases (`plan:1297-1301`). It specifies a complete browser →
PDEATHSIG helper → bwrap PID namespace/`--die-with-parent` chain and waits until
the fake CLI plus its grandchild are running before killing only the browser
(`:1270-1280`). The direct `prctl` result is now required to be checked.

The install-step seam is now separate from the parent-death seam and has a
bounded, inert-without-e2e route (`:1284-1289`), but it does not say on which
side of each filesystem mutation the `SETUP paused` row occurs. That is the
test's entire causal contract. `first-move:<entry>` must sample after that entry
has moved so the test observes a markerless partial install; `marker` must state
which side of the commit-point replace it samples; `cleanup` must sample after
commit and before deletion; and exchange/state/mkdir steps need equally exact
pre/post states. The e2e should assert that expected intermediate state before
SIGKILL, then assert that a plain rerun repairs it. Otherwise an implementation
can emit every named row before its mutation and never exercise the advertised
interruption states.

Agent Mail 5356 and 5357 sent the two blockers to BlackRobin. Agent Mail 5358
also pre-reviewed the uncommitted no-child-window host: the hardware oracle must
test the **open** drawer, not only the initial icon, and the structural census
must fail closed on unknown/new output-window owners and preserve ancestry.

## Google Workspace WebProcess crash (`c0c1c18`, live evidence; private repro 2026-10-14)

**Finding: the WebProcess root cause was not captured; the blank-after-crash UX
is a confirmed product defect.** The only live evidence is one exact
`zigBrowser: window 1: web process terminated (crashed)` line at 2026-10-13
12:27:35 EDT while the window was in an authenticated Google
Accounts-to-restricted-Sheet flow. There is no core, kernel/journal report or
page state. WebKit's broad `WEBKIT_WEB_PROCESS_CRASHED` reason excludes the
shim's explicit `memory_limit` and `terminated_by_api` reasons, but does not
identify a signal, stack or subsystem. It is not enough to attribute the crash
to Google, NVIDIA, Skia, JavaScriptCore or memory pressure.

The 22-hour blank window is fully explained by the application code, independent
of the unknown crash cause. At exact `c0c1c18`, the termination callback says
the page is gone and the window “shows nothing until it loads again,” stores the
reason, and only prints stderr (`src/webkit_shim.c:4155-4178`). A later real load
commit is the only thing that clears the mark (`:968-979`); `page.list` merely
exposes it (`:3843-3866`). There is no native crash document, automatic recovery
or visible action for the person.

### Private-Xvfb reproduction

I built an exact clean export of `c0c1c18` against Debian's installed
WebKitGTK/JSC 2.54.0, with a fresh HOME, XDG directories and profile for each
case. Each browser used its own private Xvfb, the built-in case-J render
configuration, `--automation-api` and `--media-source off`. `page.list` was
sampled every 10 seconds; a read-only ready/title/URL/DOM probe ran at 15, 60
and 105 seconds; native wheel requests ran every 20 seconds.

| Public page | Observation over 120 s | Termination |
|---|---|---|
| Google Accounts `ServiceLogin` continuing to Sheets | redirected to `v3/signin/identifier`; `readyState=complete`, title `Sign in - Google Accounts` | none |
| Google's official Sheets API sample `1Bxi…upms` | real editor loaded; title `Example Spreadsheet - Google Sheets`, responsive throughout | none |
| Google's official Docs API sample `195j…djFE` | real editor loaded; title `Docs API Quickstart - Google Docs`, responsive throughout | none |

Every read reported `MediaSource` as `undefined`, confirming the requested media
setting. stderr contained `zigBrowser: media-source=off`, no GBM/DRM error and
no termination line. The native wheel calls returned `scrollY: 0`, so this run
did not move the editors' private inner scrollers. The result is therefore a
**limited negative reproduction**, not a clearance: it had no authenticated
account, could not enter the private document's second access gate, did not use
the proprietary NVIDIA presentation path, and observed each page for only two
minutes. I did not use an arbitrary person's restricted document as a fixture.
The throwaway export, profiles and X server were deleted immediately.

### Upstream search

I found no current WebKitGTK 2.54 report specific to `docs.google.com` or
`accounts.google.com`. Historical Google reports concern user-agent/site
compatibility; for example [bug 171770](https://bugs.webkit.org/show_bug.cgi?id=171770)
was a 2017 sign-in blank page fixed as a UA quirk, not a WebProcess death.

The strongest **plausible, not proven** match is
[bug 323049](https://bugs.webkit.org/show_bug.cgi?id=323049) (and duplicate
[324333](https://bugs.webkit.org/show_bug.cgi?id=324333)): a Skia CPU worker
destroys a deferred display list whose buffer release enters a GPU-thread-owned
`GrResourceCache`. Debug builds abort on the ownership assertion; the report
explicitly notes that the underlying thread-safety violation likely exists
unchecked in Release. The fix landed on main on 2026-09-23 and was backported
to `webkitglib/2.54` on 2026-09-28, after the 2.54.0 release. WebKitGTK 2.54 is
the release that replaced the WebProcess compositor with Skia and made threaded
tile painting mandatory, while the 2.54.1 release notes say it fixes several
crashes and rendering issues. This makes a controlled 2.54.1 qualification
worthwhile when available, but without the lost crash stack it cannot be called
this incident's fix. The installed Debian candidate remains 2.54.0.

The earlier `LayerTreeHost::updateRendering` race in
[bug 309296](https://bugs.webkit.org/show_bug.cgi?id=309296) is a weaker match:
it was triggered by load/scroll timing, but its fix (bug 311101) landed in March,
well before 2.54.0. The known variable-font memory growth report, bug 319590,
also does not establish this event: the live reason was `crashed`, there was no
OOM record, and no process memory sample survives.

### Required visible behavior and failing-first test

On `crashed` or `memory_limit`, the same window should show an app-owned,
non-privileged crash document naming the affected window and last committed URL,
with an explicit Reload link/action. It must not auto-reload: that can repeat a
crash loop and silently lose login/form state. `page.list.crashed` must remain
set while the alternate document is visible and clear only when a real target
load commits. `terminated_by_api`, normal quit, `page.close` and `page.recover`
must not flash a crash page. Every related view affected by one process death
needs its own visible crash document.

The failing-first extension belongs in the existing real-binary
`web-process-crash-e2e`: load a counted local fixture, SIGKILL its WebProcess,
and assert (1) the same view visibly renders the native crash document, (2)
`page.list` still reports `crashed`, and (3) the fixture request count does not
increase automatically. Then activate Reload and require the original URL to
load and the reason to clear only on its real commit. Repeat the visible-state
assertion for all related views, and retain the existing checks that deliberate
API termination and quiet shutdown produce no crash page. BlueBeaver's Agent
Mail 5359 design follows this contract; Agent Mail 5362 delivered the private
repro and upstream qualification to both implementers.

## Push-prefix verdict audit through `22ff1f9`

The orchestrator requested an explicit verdict for every unpushed S3a/drawer
commit before any push. The table distinguishes an exact commit's historical
verdict from a later follow-up that closes only that finding. A green gate does
not override a correctness blocker.

| Commit | Explicit verdict | Disposition |
|---|---|---|
| `abbf0ea` | **BLOCKER** | The original S3a implementation has the six findings recorded above; `4e3b09c` closes four, but committed production code still has five later findings. |
| `4e3b09c` | **BLOCKER** | Interrupted first install, slash/path grammar, dot segments, late rollback and route-probe descendant lifetime remain unfixed in committed code (`69c7098`). |
| `be46e05` | **BLOCKER at that revision; producer gap CLOSED by `7eab90f` + `4e3b09c`** | The exact plan omitted the shared-runtime producer. Its later plan/implementation follow-up closes that narrow finding, not the S3a transaction findings. |
| `7eab90f` | **BLOCKER at that revision** | It overclaims rollback/descendant death and contains stale runtime/file inventory. Later plan revisions improve the contract, but the committed S3a implementation remains blocked. |
| `d9674c1` | **BLOCKER at that revision** | Its real-screen oracle, inherited render environment, slash-name collision and interruption/death contracts were incomplete. |
| `0524293` | **BLOCKER at that revision** | It closes the name/death issues but does not locate its pause seam on a defined side of each mutation. |
| `46cdcf2` | **BLOCKER at that revision** | It gives the pause sides and records the drawer host, but the journal cannot distinguish all crash cuts and the dock contradicted the then-current float/no-reflow requirement. Later plan revisions and the user's 2026-10-14 dock decision close those plan findings. |
| `220af5a` | **APPROVED** | The page-only scratch variant is isolated from ordinary cases and is a useful topology-bisect control. |
| `607c3a3` | **APPROVED as completed by `60ce3b6`** | `60ce3b6` puts its nine oracle tests in `zig build test`, rejects partial/off-screen captures, and keeps the screen-plus-window judgment. |
| `60ce3b6` | **APPROVED** | The structural red/green, retained behavioral checks, independent gate and the user's NVIDIA check all pass. The user accepted its docked/page-resized behavior on 2026-10-14. |
| `ddc892e` | **APPROVED** | The crash document and Reload path satisfy the production-chain contract; one `about:blank` edge case is a non-blocking SHOULD below. |
| `22ff1f9` | **BLOCKER at that revision** | Its exchange reconciliation is only half-specified and float versus dock was deliberately unresolved. The user closed the product decision in favor of docked behavior; `f73296b` closes the exchange-state contract. |
| `ce275ab` | **BLOCKER** | It correctly changes §0 and D2 to the accepted docked contract, but leaves section 6 item 4 saying “Floats over the page.” |
| `f73296b` | **BLOCKER** | The exact two-state exchange reconciler, mixed-state test table and first-install cuts close the transaction findings. It inherits `ce275ab`'s contradictory section 6 item 4. |
| `f262998` | **BLOCKER (docs)** | The immutable `dist/current/state` direction is accepted and removes the journal class, but the state placement, durable publish order, garbage namespace, fixed-link first install and old D6/section-6 text are not yet exact. |

Therefore there is **no fully approved linear push prefix after `fa0aa48` yet**:
the first unpushed implementation commit, `abbf0ea`, still has open production
blockers. No push was performed.

## Windowless drawer host and plan rev 15.3c/f (`60ce3b6`, `46cdcf2`, `22ff1f9`)

### `60ce3b6`: APPROVED; NVIDIA blocker CLOSED

The new `ZbDrawerHost` is a real no-window `GtkContainer`
(`src/agent_drawer.c:291-437`). It allocates the WebView above the visible
docked panel (`:364-388`), paints the icon/fold after the page in the page's
own window (`:391-415`), and attaches the page and floating/input children
without `GtkOverlay` (`:967-1003`). The e2e-only census guards an unknown
GdkWindow owner with `G_IS_OBJECT` and reports kind, viewability, ancestry and
geometry (`:189-224`). I found no ownership, teardown or native-window lifetime
regression in the exact diff.

`agent_drawer_test.py` fails closed on any unknown output-window owner and on
any viewable output window overlapping the page; it checks closed, open and
minimized topology (`tests/e2e/agent_drawer_test.py:176-264`). The author
recorded the required red on the old host: 3/9 failures, all
`GtkOverlay:output`, plus mutants for an unshrunk page, a windowed stand-in and
unpainted floats. The existing S1 input/drag/pixel checks and S2 open,
scroll/send and fold-pixel checks remain in their production-chain suites. The
manual `drawer-open` case now uses XTest on its own icon, samples page plus
panel twice, minimizes, and samples page plus icon; partial/off-screen geometry
fails (`tests/manual/real_screen_check.py:306-361`). Its nine pure oracle tests
are a dependency of `zig build test` (`build.zig:698-710,945-948`), closing the
old `607c3a3` test-integration blocker.

The final hardware condition also passed. On the user's NVIDIA/X11 screen with
the default case-J graphics route, drawer on and MSE off, the exact clean build
showed the page and icon, allowed dragging, opened the drawer, and folded it
back. This closes the original blank-presentation blocker. On 2026-10-14 the
user explicitly chose **“Keep it docked”**: the drawer stays at the bottom, the
page is laid out above it, and nothing is hidden. That is now the accepted
contract for this implementation; the floating S icon remains unchanged.

### `46cdcf2`: BLOCKER; `22ff1f9`: BLOCKER

Exact rev 15.3c/d both says the user's drawer floats without page reflow and
specifies a dock which shrinks the WebView. It also writes a journal before a
mutation but does not encode enough state to distinguish a crash before the
mutation from a crash immediately after it. Those are blockers at exact
`46cdcf2`.

Rev 15.3e/f (`22ff1f9`) materially improves the transaction: every mutation
has `:before` and `:after` cuts; intent publication is temp + file fsync +
rename + root-directory fsync; mutations fsync their touched parent
directories; and the journal records inode identities (`plan:1322-1364`). It
also honestly marks float-versus-dock as pending (`:42,214-216,242`) and repins
the drawer glue to `60ce3b6`.

Two blockers remained at exact `22ff1f9`:

1. An exchange records both original inodes, but recovery calls it done merely
   when the live path holds the staging inode (`plan:1342-1355`). The only
   acceptable states must be fully specified: not done iff `(live=A,
   staging=B)`, done iff `(live=B, staging=A)`; a missing path, duplicate inode
   or one-sided/mismatched pair refuses and preserves the evidence. The
   reconciler tests must cover those mixed states, not only “both/neither” for
   one inode.
2. A pending product decision is not an approved contract. The user must
   explicitly choose the proven dock/reflow behavior or retest and accept a
   float-preserving design on NVIDIA; then D1, D2 and the structural test must
   say one thing consistently.

Non-blocking plan cleanup: `plan:1339` says a first install has no journal,
while `:1322-1326` defines every `:before` cut as following a durable journal
intent. State that first-move uses the same observable cut positions without a
journal and that its marker rename plus parent-directory fsync is the durable
first-install commit point.

### Dock decision and rev 15.3g/h (`ce275ab`, `f73296b`)

The user's 2026-10-14 decision closes blocker 2 above: **docked is the accepted
contract**. `ce275ab` updates §0 answer 4 and D2 accordingly, including the
shorter page viewport and the requirement that S7/S8 obtain element geometry
at action time. Therefore `60ce3b6` is approved without a placement
qualification, and the placement finding against `22ff1f9` is closed.

`f73296b` closes blocker 1 and the first-install cleanup. For an exchange it
accepts only the two complete inode pairings `(L=A,S=B)` and `(L=B,S=A)`; all
missing, duplicated, foreign and one-sided combinations refuse while leaving
the journal and staging untouched. Its failing-first table enumerates those
states, plus malformed/unknown records and rename anomalies. It also defines
both pause sides for a first install without pretending that its pre-marker
moves have journal intents.

**Verdict on exact `ce275ab` and `f73296b`: BLOCKER (docs).** Section 6 item 4
still says `Drawer placement | Floats over the page.` (`plan:812`), directly
contradicting §0 and D2 and the user's required section-6 update. A follow-up
must change that row to the dock/page-resize contract. No code change is
required for this finding.

### Independent gate and red evidence

I ran a clean `git archive 46cdcf2` under private Xvfb with a fresh cache and a
bounded timeout. The tree was deleted by its trap. Result:

```text
Build Summary: 105/105 steps succeeded; 816/816 tests passed
```

The run included 79/79 drawer S2 checks, the census case, 56/56 icon/S1 checks,
25/25 isolation checks, and the nine real-screen-oracle unit tests. No live
browser, live socket, account or DISPLAY `:0` was touched. Findings and the
gate result were mailed as Agent Mail 5373, 5375 and 5377. I then ran a second
clean-export gate at exact `22ff1f9`, independently covering the crash-page
follow-up and the latest plan commit. It was also green:

```text
Build Summary: 105/105 steps succeeded; 816/816 tests passed
```

That tree was likewise deleted by its trap; Agent Mail 5379 released the gate
slot.

I later ran another bounded clean-export gate at exact `f73296b`, while
reviewing the mechanism audit below. It was green and the trap deleted its
tree:

```text
Build Summary: 105/105 steps succeeded; 816/816 tests passed
```

`f262998` was committed while that gate was running. It is docs-only, but the
result is recorded against exact `f73296b`, not mislabelled as a gate of the
new revision.

## Visible crash document (`ddc892e`)

**Verdict: APPROVED.** The per-window `committed_uri` is duplicated on a real
load commit and freed with the window; `crash_page` and `terminated` remain
GTK-thread-owned (`src/webkit_shim.c:132-143,526-532,1096-1117`). A spontaneous
crash or memory-limit termination loads static, escaped alternate HTML into the
same WebView (`:984-1045,4483-4518`). Its own load events do not complete an
automation job, emit a navigation row or clear the crash; only a later real
commit does. `terminated_by_api` still shows no crash page. The sentinel
intercept is active only while that window is showing its crash page
(`:1191-1203`), so an ordinary page cannot obtain that navigation exception.

The regression kills real WebKitWebProcesses, checks each affected window's
own crash DOM and URL, waits with a no-store request counter to prove no
automatic reload, then uses a real X click to reload. Related/shared and
independent popup process groups, API termination and quiet shutdown are all
covered (`tests/e2e/web_process_crash_test.py`, 40 checks;
`tests/e2e/slow_load_watchdog_test.py`). This traverses the production
termination callback and same WebView rather than calling the renderer helper
from test code. The author recorded eight failing crash-page assertions before
the implementation and five relevant killed mutants. Their clean-export gate
was 105/105 steps and 816/816 tests. My independent exact-`22ff1f9` clean gate,
which includes this commit, produced the same 105/105 and 816/816 result and
ran all 40 crash-page checks.

**SHOULD:** `src/webkit_shim.c:1004-1026` notes that string-loaded content
cannot follow either `file:` or `about:blank`, but only `file:` is routed
through the sentinel. A blank popup whose last committed URI is `about:blank`
therefore receives a visible Reload link that does nothing. Route that scheme
through the sentinel too, or omit the link, and add the blank-popup case when
this path next changes. Agent Mail 5376 sent the approved verdict and this
follow-up to BlueBeaver.

## Mechanism audit: why the old `GtkOverlay` drawer blanked NVIDIA

This follows up the original `fa0aa48` diagnosis with the exact WebKitGTK
2.54.0 and GTK 3.24.49 source paths. It also corrects an overstatement in the
earlier review: case J is **not, merely because WebKit is accelerated, a GL
texture drawn by GDK or a GLX swap to a native WebView child**. The old host was
still the necessary application-side trigger, and `60ce3b6` remains the right
fix, but bug 90085 does not by itself prove the modern mechanism.

### What actually paints case J

`WEBKIT_DMABUF_RENDERER_FORCE_SHM=1` makes
`rendererBufferTransportMode()` return after adding SharedMemory and before it
adds Hardware
([WebKit 2.54.0 `AcceleratedBackingStore.cpp`:78-113](https://github.com/WebKit/WebKit/blob/5220e80b97a253c60ed899361654142ab5021998/Source/WebKit/UIProcess/gtk/AcceleratedBackingStore.cpp#L78-L113)).
The WebProcess therefore renders through NVIDIA EGL/GL to an off-screen target,
not an X window, and `RenderTargetSHMImage` copies the completed pixels with
Skia `readPixels` or `glReadPixels` into a `ShareableBitmap`
([`AcceleratedSurface.cpp`:409-457](https://github.com/WebKit/WebKit/blob/5220e80b97a253c60ed899361654142ab5021998/Source/WebKit/WebProcess/WebPage/CoordinatedGraphics/AcceleratedSurface.cpp#L409-L457),
[:761-775](https://github.com/WebKit/WebKit/blob/5220e80b97a253c60ed899361654142ab5021998/Source/WebKit/WebProcess/WebPage/CoordinatedGraphics/AcceleratedSurface.cpp#L761-L775)).

In the UI process, `BufferSHM` wraps those bytes in a
`CAIRO_FORMAT_ARGB32` image surface. `Buffer::paint()` uses
`cairo_set_source_surface` and `cairo_fill`; its
`gdk_cairo_draw_from_gl()` branch is for a texture-backed buffer, which this
forced-SHM route does not have
([`AcceleratedBackingStore.cpp`:271-298,634-692](https://github.com/WebKit/WebKit/blob/5220e80b97a253c60ed899361654142ab5021998/Source/WebKit/UIProcess/gtk/AcceleratedBackingStore.cpp#L271-L298)).
`WebKitWebViewBase::draw()` invokes that paint on the WebView's logical
`GDK_INPUT_OUTPUT` child GdkWindow
([`WebKitWebViewBase.cpp`:628-677,918-951](https://github.com/WebKit/WebKit/blob/5220e80b97a253c60ed899361654142ab5021998/Source/WebKit/UIProcess/API/gtk/WebKitWebViewBase.cpp#L628-L677)).

There is one qualification. GTK can promote Cairo content into a whole-window
GL frame if the native implementation window already owns a persistent
`gl_paint_context`; that frame ends in the X11 backend's GLX presentation.
Nothing in the forced-SHM WebKit paint or old drawer directly creates that
context, so source inspection does **not** establish that this happened on the
user's machine. The remaining real-screen `GDK_GL=disable` discriminator below
is needed before blaming the final GLX swap. Without it, the evidence proves a
NVIDIA EGL producer/readback plus GTK damage/presentation interaction, not a
specific GLX call.

### What `GtkOverlay` changes

The old application installed `GtkWindow -> GtkOverlay -> WebKitWebView` and
three overlay children: icon, hidden panel and hidden ghost
(`fa0aa48 src/agent_drawer.c:734-766`). The ghost's draw handler returns
`FALSE` (`:441-452`), so it does not consume or erase the frame.

GTK 3.24.49's `GtkOverlay` itself is no-window, but it creates one
`GDK_WINDOW_CHILD`, `GDK_INPUT_OUTPUT` GdkWindow for **every** overlay child and
makes that the child's parent window
([`gtkoverlay.c`:143-173,415-431,848-853](https://github.com/GNOME/gtk/blob/3.24.49/gtk/gtkoverlay.c#L143-L173)).
Those are logical/client-side GdkWindows by default, not necessarily native X
children. They share the native implementation window until somebody calls
`gdk_window_ensure_native()`
([`gdkwindow.c`:1493-1526,1820-1911](https://github.com/GNOME/gtk/blob/3.24.49/gdk/gdkwindow.c#L1493-L1526)).
Consequently:

- the old mapped icon adds an output child to GDK's clip, damage and stacking
  tree even when `xwininfo` shows no extra X child;
- the hidden panel and ghost have allocated output GdkWindows but are not
  viewable, and GDK excludes hidden/input-only children from visible-region
  subtraction; there is no evidence here that an **unmapped** child alone
  triggers the real failure;
- `GtkOverlay` uses the inherited parent visual, so an ARGB/visual mismatch is
  not its normal construction path; and
- a diagnostic must call `gdk_window_has_native()` before requesting an XID.
  `gdk_x11_window_get_xid()` itself promotes a client-side window and would
  perturb the topology being measured.

This also narrows the relevance of WebKit bug 90085. That 2012 bug involved a
WebView explicitly promoted to a native X window and direct accelerated
rendering; the fix removed that requirement. It is useful historical evidence
that WebView native-window topology and `GtkOverlay` have interacted badly,
but it is not a source-level explanation for today's forced-SHM pipeline.

### Xvfb evidence and the remaining causal boundary

I ran the exact `fa0aa48` binary only under private Xvfb, with isolated profiles
and no automation socket. External `xwininfo -root -tree` saw the 1024x768
toplevel and its ordinary 1x1 helper but no overlay X children. A separate GTK
3.24.49 probe confirmed why: the overlay wrapper began `INPUT_OUTPUT` and
non-native; asking for its XID promoted it and then produced a real X child.
Under Mesa llvmpipe, a `GtkGLArea` control kept correct pixels with the wrapper
client-side, promoted and mapped, and promoted but unmapped.

The browser's first-frame timing likewise showed no overlay-specific stall:

| Exact `fa0aa48` Xvfb case | DOM complete | first blank sample | first page-colour sample |
|---|---:|---:|---:|
| drawer off, case J | 0.380 s | 0.380 s | 0.519 s |
| old overlay, case J | 0.384 s | 0.384 s | 0.520 s |
| old overlay, hardware never | 0.312 s | none | 0.312 s |
| old overlay, Mesa EGL | 0.367 s | 0.367 s | 0.501 s |

The approximately 130 ms post-DOM frame lag is the same accelerated-frame lag
with or without `GtkOverlay`, not the persistent NVIDIA blank. A second run of
the current authoritative pixel oracle on the old binary passed drawer-off,
drawer-on, drawer-open, `GDK_GL=disable` and `GDK_GL=software-draw`; page colour
was 99% and the icon 2,124 pixels in every closed case. `WEBKIT_DEBUG` names
`AcceleratedBackingStore`/`AcceleratedSurface` were rejected as unknown, and
`GDK_DEBUG=frames,opengl G_MESSAGES_DEBUG=all` produced no useful rendering
rows in the packaged release. Every tree and profile was deleted immediately.

The source plus matrix therefore establish a **two-condition failure**:

1. NVIDIA's off-screen EGL producer/readback/fence route is required; replacing
   it with CPU rendering or Mesa EGL removes the failure.
2. The old output-window overlay topology is required; removing it in
   `60ce3b6` removes the failure on the same NVIDIA route.

The most specific defensible mechanism is that GTK's overlay-window topology
changes clipping/damage/invalidation around a Cairo-presented WebView frame,
and the NVIDIA-produced SHM frame then never reaches a visible committed paint.
That blanks the whole content area, including the icon, because both are
scheduled in the same GTK frame. Whether the lost frame is before GTK draw
(producer/readback/fence or damage notification) or at a GDK GL-backed final
present remains **not captured**. “NVIDIA GLX swaps a drawable with a native
child and loses it,” “an unmapped child clips the parent,” and “ARGB mismatch”
are not supported by the evidence currently available.

The clean discriminator, for the orchestrator only and only with the user's
permission, is the existing isolated manual matrix. It opens only a local
solid-colour fixture, uses a throwaway profile, starts no automation socket and
includes `on-gdk-gl-disable`:

```sh
python3 tests/manual/real_screen_check.py \
  --confirm-user-permission \
  --bin /tmp/claude-1000/-home-maceo-ntm-Dev-zigBrowser/2f282cd0-68cc-4a77-9345-4747f7fc7145/scratchpad/build-fa0aa48/zig-out/bin/zigBrowser \
  --out /tmp/zb-overlay-mechanism-fa0aa48 --matrix
```

If default case J blanks but `on-gdk-gl-disable` draws, GTK's final GL-backed
paint/present is implicated. If both blank, the final GLX-swap theory is
falsified and instrumentation should compare a side-effect-free WebKit page
screenshot with the root-window capture, plus raw counters for
`WebKitWebViewBase::draw`, clip rectangles, frame receipt/fence completion and
`gdk_window_has_native()` (without asking for XIDs). A good WebKit screenshot
with a blank root localizes the loss to GTK/GDK presentation; a blank WebKit
screenshot localizes it to NVIDIA rendering/readback/frame delivery.

### Safe ways to float again

| Design | Graphics risk | Product/implementation risk |
|---|---|---|
| Keep the accepted docked `ZbDrawerHost` | **Lowest; proven on the user's NVIDIA screen.** Output panel windows sit beside, never over, the page window. | Page viewport changes while open; already accepted, and action geometry is read at action time. |
| Paint icon/fold or simple chrome in the host/page draw; use input-only windows only for hit testing | Low; this is the proven `60ce3b6` icon/fold pattern. | Visible pixels cannot live in an input-only window. A full chat editor would need custom drawing, focus, IME, selection, scrolling and accessibility. |
| Custom no-window container with all painted descendants on the page/host window | Low only if **every** descendant remains no-window. Merely setting a child `has_window=FALSE` while retaining `GtkOverlay` is ineffective because `GtkOverlay` creates its own output wrapper. | High for stock `GtkTextView`/`GtkScrolledWindow` descendants, which create output windows; substantial event/layout/accessibility work. |
| Separate transient or override-redirect ARGB toplevel | Isolates the drawer from the WebView's child/damage tree; medium risk. Prefer ordinary transient semantics over override-redirect. | Focus/IME, stacking, movement, resize, workspaces, multi-monitor/HiDPI, click-through, screenshots and accessibility are difficult; ARGB composition and another accelerated drawable introduce driver/compositor risk. |
| Stock `GtkOverlay`, pass-through flag, or hidden/input-only wrapper alone | **Not a fix.** Pass-through changes event routing, not the mandatory output wrapper; input-only cannot display the stock panel. | Preserves the trigger or cannot render the UI. |

The required red-first coverage for any future floating redesign has two parts:
(1) a structural census that never calls `gdk_x11_window_get_xid()` on a
non-native window and rejects every viewable output window overlapping the page,
and (2) the authoritative root-pixel real-screen case on NVIDIA, paired with a
WebKit screenshot so a recurrence is localized rather than merely labelled
“blank.” The user has chosen the already-proven dock, so this is follow-up
design evidence, not a reason to reopen `60ce3b6`.

## S3a immutable-build simplification (`f262998`, plan rev 15.4)

**Direction: ACCEPTED. Exact revision: BLOCKER (docs).** Replacing the
multi-mutation journal with complete immutable builds and one `current`
symlink swap is compatible with D6/D12 and is materially safer. It does not
break the contracts behind the prior review: `HOME` stays the agent-home root;
`CLAUDE_CONFIG_DIR=root/.claude` and `root/runtime` remain stable fixed paths;
bwrap resolves their `current` target when the mount is created, so an already
running helper retains its old build; workspace, scratchpad and secrets remain
outside published configuration; and the per-session manifest can still guard
the immutable configuration. The journal, reconciler, rollback and
`renameat2` requirements can therefore be deleted once this design is exact.

Six gaps remain in exact `f262998`:

1. **The state table contradicts the user's decision and D12.** It puts
   `.claude.json` in each `dist-<n>` and leaves `STATE_DIRS` symbolic
   (`plan:1325-1328`). The user explicitly placed `.claude.json` and
   `backups/` in `state/`. The exact layout should enumerate read-only
   `state/.claude.json` and `state/backups/`, plus the reviewed writable union
   `state/{projects,sessions,session-env,todos,statsig,debug,MEMORY}/`. Setup
   creates each once when absent and later only reads/validates it. Each dist
   has empty file/directory mount points; D12 read-only-binds the first pair
   and writable-binds only the reviewed union. This preserves the existing
   rule that CLI attempts to rewrite `.claude.json`/`backups` get `EROFS`.
2. **The publish order omits the target-durability barrier.** The complete temp
   tree must be fsynced, renamed to `dist-<n>`, and the root directory fsynced
   before a temporary symlink can be renamed over `current`. The root is
   fsynced again after that pointer swap. Tests must fault/kill both barriers;
   a durable `current` may never name an unpersisted target.
3. **Best-effort garbage deletion lacks a safe namespace contract.** Cleanup
   must operate fd-relatively without following symlinks and delete only
   validated, setup-owned build directories. A malformed `dist-*`,
   `.dist-tmp-*` or `.current.tmp-*`, wrong type/owner/mode, absolute symlink
   target or `..` target must refuse and preserve evidence. Failing-first
   symlink and foreign-file cases are required; a prefix alone is not deletion
   authority.
4. **D6 still documents the superseded flat layout** (`plan:274-311`). Its tree
   and provisioning bullets need `state/`, `dist-<n>`, `current` and the fixed
   links, and must say that the setup route probe executes the staged wrapper
   and writes staged metadata before publication.
5. **The accepted drawer placement is still contradicted in section 6.** Item
   4 remains `Floats over the page` (`plan:813`) instead of docked at the
   bottom with the page resized above it.
6. **First-install fixed-link repair is underspecified.** Missing `.claude` and
   `runtime` links may be created under the root one component at a time; exact
   relative targets are required. A wrong type/target refuses. A crash after
   creating only one link must be repaired on rerun without altering any
   state.

With those corrections, two external kill cuts are sufficient:
`swap:before` leaves old/no `current`, and `swap:after` leaves the new current;
both retain every state inode. Build-step fault injection still belongs below
the swap to prove incomplete builds are never published. Agent Mail 5390 sent
these findings before implementation proceeds.

## Real-screen matrix safety and compositor-fixture audit (`1be5169`)

**Verdict: BLOCKER. Do not run another input-injecting case on the user's
screen yet.** The repainting fixture and drawer-off DMA-BUF control are useful,
but the committed input guard does not satisfy the requested fail-closed
boundary.

The supplied `fa0aa48` artifacts also need one factual correction. The
`drawer-open.screen.png` capture is the user's terminal and
`drawer-open.window.png` is the browser's still-closed blue page plus icon, so
the sample is not a drawer-open rendering result. However, this particular
case did **not** inject a click or Escape: there are no `open1`, `open2` or
`minimized` captures, and the old runner returned after the initial screen
pixel judgment failed, before its click branch. The incident demonstrates
failed activation/capture identity, while the unsafe-input path remains a
latent time-of-check/time-of-use bug rather than an observed misdirected click.

### BLOCKER: the last-moment XTest boundary is incomplete

At `1be5169`, `tests/manual/real_screen_check.py:391-401` checks only whether
the client id is somewhere in the X window ancestry at the intended point,
then emits synthetic pointer motion, sleeps 200 ms, and checks pointer ancestry
before emitting button events. It does not establish `IsViewable`, current
geometry containment, `_NET_ACTIVE_WINDOW == wid`, or input focus inside the
client before that first XTest event. It also leaves a race between the final
check and the button down/up, including sleeps inside that sequence. If the
post-motion check refuses, the caller at `:497-499` nevertheless reports “no
input sent”, even though pointer motion was already sent. `raise_window()` at
`:381-388` checks only nine stacking samples, not whether activation and focus
succeeded. Escape has a useful focus/PointerRoot guard at `:404-409`, but no
active-window/viewability/anchor recheck.

Required follow-up:

- Resolve and validate the client and its root-frame ancestry; require the
  client/frame to be viewable, the point inside fresh geometry,
  `_NET_ACTIVE_WINDOW` to name the client, and `XGetInputFocus` to be the
  client or a descendant before **any** XTest event.
- Use `XTranslateCoordinates(root, root, x, y, ..., &child)` to require that
  the topmost root child at the point is the target frame. Immediately before
  button down, repeat the checks under a short server grab, move, then use
  `XQueryPointer` to prove the exact root coordinates and root-child path.
  Release the grab in `finally`; if button down was emitted, always emit button
  up. Do not sleep inside the grabbed input sequence.
- Repeat the viewable/active/focus check immediately before Escape. Any absent
  property, failed X query or disagreement aborts the entire matrix before a
  button/key event.
- Add a private-Xvfb decoy-window regression with mouse and key canaries. A
  decoy that steals focus or covers the target immediately before injection
  must receive nothing, and a safety refusal must stop later cases. Fake-unit
  tests alone do not exercise the ctypes/Xlib boundary. Correct their current
  docstring: this artifact did not send the click or Escape.

Agent Mail 5393 and 5395 sent the early finding and the exact follow-up contract
to BlackRobin.

### Source correction: page content is not the 2.54 compositor switch

The proposed explanation “the solid page never entered accelerated
compositing” is false for WebKitGTK 2.54.0 when hardware acceleration is
available. GTK initializes `AcceleratedCompositingEnabled`,
`ForceCompositingMode` and threaded scrolling together
([`WebPreferencesGtk.cpp`:34-42](https://github.com/WebKit/WebKit/blob/5220e80b97a253c60ed899361654142ab5021998/Source/WebKit/UIProcess/gtk/WebPreferencesGtk.cpp#L34-L42)).
The compositor caches that force flag and enters mode from it, independently
of page content
([`RenderLayerCompositor.cpp`:610-645,1041-1073](https://github.com/WebKit/WebKit/blob/5220e80b97a253c60ed899361654142ab5021998/Source/WebCore/rendering/RenderLayerCompositor.cpp#L610-L645)).
Thus the solid fixture and Wikipedia both used the coordinated/accelerated
path in default case J. Their discriminating difference can be layer topology,
backing-store tiling/damage and repaint cadence, not compositor-off versus
compositor-on.

`1be5169` moves the fixture in the right direction, but its guarantees should
be stronger. Intrinsic layer reasons include 3D transforms, running
animations, canvas and `will-change`
([`RenderLayerCompositor.cpp`:3283-3322](https://github.com/WebKit/WebKit/blob/5220e80b97a253c60ed899361654142ab5021998/Source/WebCore/rendering/RenderLayerCompositor.cpp#L3283-L3322)).
On GTK, `will-change` is suppressed under conservative memory policy, and the
current 60-by-60 canvas is below WebKit's 5,000-pixel canvas threshold
([`:3848-4023`](https://github.com/WebKit/WebKit/blob/5220e80b97a253c60ed899361654142ab5021998/Source/WebCore/rendering/RenderLayerCompositor.cpp#L3848-L4023)).
A deterministic local discriminator should therefore use a self-painting,
multi-viewport article wrapper with nonzero
`transform: translate3d(0,0,1px)`, a continuously running transform animation,
dense local text/cards and a sticky header; any canvas intended as a separate
trigger should be at least 96-by-96 (preferably 128-by-128). This exercises
coordinated layers, tiles, dirty regions and repeated paints while preserving
the blue pixel oracle.

### Renderer control

Adding `off-renderer-default` is correct. It should precede the corresponding
drawer-on treatment, or the summary must explicitly classify a drawer-on
failure as non-diagnostic when the off control also fails. The supplied
drawer-on/default log already contains the NVIDIA GBM/KMS allocation errors,
and both its root capture and window capture lack WebKit content while the
app-painted icon remains. That result is the known DMA-BUF producer failure,
not evidence against the old overlay. `GDK_GL=disable` is also not a narrow
final-presentation discriminator here: its stderr says WebKit disabled
hardware acceleration because GTK GL initialization failed.

The display-free unit suite passes 15/15 at exact `1be5169`, but those tests do
not close either blocker above. A quiet clean-export gate at exact `1be5169`
was otherwise green: **Build Summary: 105/105 steps succeeded; 816/816 tests
passed**. The gate tree was deleted immediately. The verdict remains BLOCKER
because the production gate does not exercise the real-screen XTest safety
boundary.

## Real-screen input guard follow-up (`eef2ff6`)

**Explicit verdict: BLOCKER.** The commit correctly moves the final
viewability, active-window, geometry, stacking and post-motion pointer checks
onto one X connection under `XGrabServer`, removes sleeps from the grabbed
sequence, makes button/key release unconditional after a corresponding press,
always ungrabs in `finally`, stops the remaining matrix after an input refusal,
adds the private-Xvfb real-X test step, strengthens the Wikipedia-shaped local
fixture, and orders the DMA-BUF drawer-off control before its treatment.
Those are substantive improvements, but the requested last-moment input
boundary is not complete.

### BLOCKER: a click does not require focus inside the target

`tests/manual/real_screen_check.py:495-515` checks `window_ready`, current
geometry, the X window path, and the post-motion pointer path, but never calls
`XGetInputFocus`. A target can therefore be viewable, active and on top while
another window owns keyboard focus, and `safe_click` still emits XTest motion
and a button click. An exact clean-export probe at `eef2ff6`, using the
committed `FakeX11`, set `wm=True`, `active=OURS`, both point paths to
`[FRAME, OURS]`, and `focus=TERMINAL`; `safe_click` returned `None` and
recorded `[('move', 10, 10), ('button',)]`. The real-X suite's positive case
sets focus correctly, but has no negative case with the target still active
and on top while the decoy alone owns focus.

The follow-up must apply the same focus/PointerRoot ownership rule before the
first click motion, under the existing grab, and add both fake and private-Xvfb
negative cases. This is the remaining requirement from the orchestrator's
“topmost, viewable, focused” safety rule; changing the plan text in this commit
to mention focus only for Escape does not waive it.

### BLOCKER-for-tests: two refusals do not prove zero XTest motion

`tests/manual/test_real_screen_input.py:168-187` uses
`assert_nothing_reached`, which counts ButtonPress/KeyPress and checks that the
button/escape wrappers were not called. The “decoy mapped just before input”
and unmapped-target cases do not additionally assert `self.calls == []`, as
the covered and inactive cases do. A mutant that moves the user's pointer and
then refuses before the button can therefore survive those cases. “No input”
includes XTest motion: every refusal must assert zero `move`, `button` and
`escape` calls as well as zero canary events.

**SHOULD:** `root_window_property` at `real_screen_check.py:362-378` requests
`XA_WINDOW` and validates format/nitems, but should also test
`actual_type_return == XA_WINDOW` explicitly. Xlib normally returns no data on
a requested-type mismatch; the explicit test still makes the ctypes boundary
and fail-closed intent auditable.

The author's clean-export gate covering this commit and `69e6fc4` was green:
**Build Summary: 106/106 steps succeeded; 817/817 tests passed**. All five
private-Xvfb real-X tests ran. The green gate does not change the verdict
because the missing focus state and surviving motion mutant are absent from
the test matrix. Agent Mail 5403 and 5406 sent the findings to BlackRobin.

### Focus and property-type correction (`cc9d135`)

**Explicit verdict for `cc9d135`: APPROVED.** The commit closes the click-focus
BLOCKER and the root-property type SHOULD above. `safe_click` now reads the
focus under the same server grab as the final viewability, active-window,
geometry and stacking checks (`tests/manual/real_screen_check.py:496-524`). A
normal focus must be the target or its descendant; `PointerRoot` is accepted
only when the already-sampled click-point path contains the target. The new
fake and private-Xvfb cases keep the target active and uncovered while a
side-window alone owns focus, and assert that no motion, button or key was
sent (`tests/manual/test_real_screen_input.py:168-180`). The positive
PointerRoot case remains covered.

`root_window_property` now requests `AnyPropertyType` and explicitly requires
`actual_type == XA_WINDOW`, format 32 and exactly one item before interpreting
the value (`tests/manual/real_screen_check.py:362-379`). A real-X
`XA_CARDINAL` mutant for `_NET_ACTIVE_WINDOW` is refused with zero recorded
input (`tests/manual/test_real_screen_input.py:182-188`). This makes the type
check observable instead of relying on Xlib's requested-type filtering.

A quiet clean-export gate at exact `cc9d135`, under private Xvfb, was green:
**Build Summary: 106/106 steps succeeded; 817/817 tests passed**. The export
was deleted immediately after the run. The remaining `eef2ff6`
BLOCKER-for-tests is still **OPEN (BlackRobin)**: at this commit the late-decoy
and unmapped-target real-X refusals still omit `self.calls == []`, so they do
not prove that a pointer-motion-only mutant is killed. That independent test
gap does not invalidate the two corrections in `cc9d135`; the complete
real-screen input-guard chain remains blocked until its queued follow-up lands.

## S3a immutable home implementation (`69e6fc4`)

**Explicit verdict: BLOCKER, with the SAI copy-path policy separately PENDING
USER DECISION.** The commit implements the central rev-15.5 topology correctly:
complete `.dist-tmp-*` builds are checked and route-probed before publication;
the tree and root are fsynced in the specified order; `current` is replaced by
one temporary-symlink rename; both external kill cuts preserve a whole current
and the state inodes; old/malformed build names refuse; validated garbage is
removed fd-relatively without following it; state lives outside builds; and
the route-probe CLI and its descendants run in a PID namespace that dies with
the browser. The exact helper unit suite passed **30/30** in a deleted clean
export, and the author's real-binary e2e/gate reported `agent-setup-e2e` 80/80
and **106/106 steps, 817/817 tests**.

### BLOCKER: the sandbox argv builder mutates a published build

`agent/host/zb_agent_host/sandbox.py:49-64` creates missing state sources and
missing mount-point targets. Under the new layout, `home.claude_dir` resolves
through `.claude -> current/.claude`, so creation of a target writes into the
already-published `dist-<n>`. An exact clean-export probe constructed a
published build without the mount points and called `helper_argv`; it created
`.claude/.claude.json`, `backups/`, and all seven `STATE_DIRS` inside that
build. This contradicts D6's “never written after its publish” invariant and
silently repairs a malformed home instead of failing closed.

Setup must remain the sole creator. `helper_argv` should only validate the
pre-existing state sources and mount-point targets (without following
symlinks) and construct argv, or receive already-validated paths from the
future runtime validator. A regression should delete one mount point from a
published build, call this production path, require failure, and prove the
tree's bytes/names are unchanged.

### BLOCKER-for-contract/tests: a longer inline code span passes the slash grammar

`agent/host/zb_agent_host/setup.py:163-173` tracks triple-backtick fences but
does not track whether a slash-name match lies inside an inline code span. Its
lead-word alternative therefore accepts a known name in a longer span. Exact
probes at `69e6fc4` accepted both ``Text `some before /clear now` `` and
``Text `x use /clear` ``. Rev 15.5 permits the special case only when the
slash command *starts* the inline span, and explicitly says a known name in a
longer code span refuses. Add these red cases and distinguish the span-leading
form before applying the prose lead-word grammar.

**SHOULD:** fixed-link creation at `setup.py:453-457` is path-based
`os.symlink`, catches `FileExistsError`, and does not re-stat/readlink the
result. Rev 15.5 calls for creation beneath the pinned root fd and requires
that each name *then* be the exact relative symlink. An injected create race
can otherwise replace an absent name with a different type/target after the
only earlier layout check and be silently accepted. Use the root fd and
validate the postcondition after success or `EEXIST`.

The policy question discovered from the real SAI is deliberately **not** one
of these blockers: whether strict scanning applies to the whole copied tree,
only executable-path-bearing files, or a reduced instruction-only copy remains
the user's open decision. The current strict policy is judged only for faithful
implementation. Agent Mail 5405 sent the implementation findings to
BlackRobin.

## Rev-16 preparation and S3a WIP audit (`da24aba` HEAD)

**No rev-16 verdict yet:** the committed plan still predates the user's
2026-10-14 decision to keep bwrap but put the helper in a private network
namespace, route all egress through an allowlist proxy, expose only the
51091/31337 bridges, keep the token exclusively on the FIFO-to-fd-3 route,
copy dependency trees without scanning them, and install the stricter filter
inside each hook. BlackRobin's rev-16 edit is still in progress. Agent Mail
5418-5424 gave the pre-review checklist: an exact relay/netd topology and
lifecycle; a bounded fail-closed CONNECT parser; resolve-once/connect-the-
vetted-address behavior; no sensitive proxy logs; literal-X0, host-loopback,
LAN and direct-egress denials; positive fixed-port bridge tests; the complete
per-hook namespace/mount/io_uring filter with `clone3` compatibility; and
removal of every stale R3/environment-token contract.

### BLOCKER: current WIP contradicts the selected copy rule

The uncommitted plan and implementation currently check hook command words
only and explicitly allow arbitrary path text in hook scripts and
`settings.json` (`setup.py:110-175`, and the WIP plan's D6/S3 copy-rule
paragraphs). The user's final rule is stricter: `settings.json`, hook commands
and the scripts they run are the executed-path surface; HOME is merely
rewritten elsewhere. The same decision names `node_modules`, `.git` and build
output as copied-but-not-scanned dependency trees. The WIP instead omits
`.git` via `SKIPPED_NAMES` and does not define build-output names. Rev 16 must
state a syntax-aware rule and its precedence over dependency exclusions,
instead of silently changing the user's decision to command-lines-only.

The current word splitter is also bypassable. `sh -c 'cat /etc/passwd'`,
`node -e "require('/srv/x')"` and `~root/x` are accepted because opaque code
is treated as a relative workspace word and only `~`/`~/` is recognized as a
home path. The plan must either parse a closed set of supported launch forms
or refuse shell/eval/unknown embedded forms. It needs red cases for `sh -c`,
`bash -lc`, `node`/`bun -e`, `~other`, `file:///...`, and `--x=/...`.
Agent Mail 5425 and 5431 sent these findings before the corrected gate.

### BLOCKER: source roots and private-state modes are under-specified

`copy_sai` resolves every top-level allowlisted entry before it establishes
the inside-item boundary (`setup.py:180-195`). Thus it follows a top-level
file or directory symlink anywhere. BlueBeaver's read-only census shows why a
blanket refusal is wrong: the user's real `settings.json`, `SAI`, `hooks`,
`commands`, `skills` and `agents` are top-level links into the real SAI bundle.
Rev 16 must preserve that layout while naming the authority explicitly—for
example, by treating each top-level allowlisted link in the user-selected
source as explicitly authorized, or by requiring another explicit source
root—and keep links below an item confined to that item. An inferred root
from the `SAI` link is not a security boundary: that link could itself name
`$HOME`. Rev 16 must not leave “realpath anywhere” implicit or claim that
inference confines the source. Direct and chained file/directory link cases
need tests. Agent Mail 5438 corrected the earlier inferred-root proposal.

Independently, an allowlisted top-level FIFO reaches `Path.read_bytes()`
(`setup.py:227-229`) and can block setup indefinitely. Every source object
must be classified without following an uncontrolled link and only a regular
file or real directory may be copied; FIFO, socket and device cases must fail
closed in bounded tests. Agent Mail 5428-5430 sent this finding and the real-
layout refinement.

The immutable layout has a second independent privacy gap. `check_layout`
accepts pre-existing state directories and `state/.claude.json` by type and
uid only (`setup.py:372-378`), and does not enforce the agent-home root's 0700
mode. World/group-readable or writable workspace, scratchpad, secrets and
transcript state therefore survive setup despite D6's private layout. Because
setup must not chmod existing state, it should fail closed unless the root and
directories are 0700 and the state file is 0600, with no publish or state
mutation. The C owner-lock object's required type/mode should also be explicit.

The first grammar follow-up does not yet close the command-string blocker.
Claude launches hook strings through `/bin/sh -c`; after seeing one script
path, the WIP accepts later shell composition. Commands such as
`bun ~/.claude/hooks/X.ts; id`, `... && curl ...`, `... $(cat</etc/passwd)`
and backtick substitution can therefore run an unchecked extra command.
Attached eval forms such as `node -eCODE` also evade an exact `-e` token
check. The grammar must reject shell control, substitution, redirection,
variable expansion and attached eval forms, with a real e2e marker/process
mutant in addition to parser units. Agent Mail 5438 sent the concrete matrix.

The first top-level-link follow-up also needs an overlap guard. It derives the
bundle root from the `SAI` link but does not compare that root with the output.
`SAI -> $HOME` (or another ancestor of `agent_home`) is therefore accepted;
copying it reaches the growing `.dist-tmp-*` destination and can recurse
without bound while sweeping unrelated private trees. Every accepted source
and item root must be disjoint from the agent home and staging tree, in both
directions, before copying begins. A bounded source/output-overlap regression
is required. Agent Mail 5439 sent the case.

**SUPERSEDED/CLOSED by the user's 2026-10-14 decision:** linked skills that
leave their containing item keep being skipped. The earlier paragraph and
Agent Mail 5443 interpreted “copy everything” as requiring those 26 external
links to be materialized; the user explicitly answered “Keep skipping them.”
The remaining independent requirement is unchanged: ordinary `.git`,
dependency-tree and named build-output directories that are physically inside
an accepted item are copied byte-for-byte without scanning, and the tests must
prove a skipped external link contributes no target bytes.

A subsequent WIP revision closes the obvious shell-composition forms with a
closed command character grammar and adds the source/output-disjoint check,
but it exposes a different durable-execution gap. `_inside_home` accepts every
path under the agent home and maps relative paths into `workspace/`. Thus
`bun ~/scratchpad/run.ts`, a script in writable state, or a relative script in
the workspace passes setup even though those bytes can be created or replaced
after validation. This contradicts `sandbox.py`'s “data only: no hook may
reference a path in here” contract. The parser must identify every code-bearing
path (main script and preload/import/loader inputs), require it to exist in the
immutable staged SAI/runtime, and refuse workspace, scratchpad, state and
secrets. A real-browser marker mutant is needed in addition to unit cases.
Agent Mail 5444 sent this blocker.

The same WIP cites an earlier “Hook commands only” response as authoritative.
The latest orchestrator instruction instead says strict refusal covers
`settings.json`, hook commands **and the scripts they run**. Rev 16 must apply
the latest decision or obtain an explicit clarification; it cannot silently
retain the older command-line-only behavior.

Three copy-shape cases remain underspecified. Each top-level allowlisted name
needs its expected type (`CLAUDE.md`/`settings.json` files; configuration
collections directories), rather than accepting either type and failing later
with an arbitrary I/O error. A FIFO, socket or device nested below an item is
currently silently omitted; every source object must instead be classified
and such types refused without opening them. Finally, the copied-without-scan
set needs an exact list grounded in the real SAI—`.git`, dependency trees and
all named build-output/cache roots—not a partial set of examples. Agent Mail
5445 sent these cases.

### Rev-16 network/filter requirements found during pre-review

The proposed proxy topology has a test-chain mismatch that the plan must
resolve. P0's fake Messages API is plain HTTP at
`ANTHROPIC_BASE_URL=http://127.0.0.1:<port>`. A CONNECT-only host proxy cannot
carry that request, and the required
`NO_PROXY=127.0.0.1,localhost` would bypass it. Rev 16 must define either a
bounded absolute-form HTTP route for the e2e-only allowlisted fake target or a
working test TLS origin/certificate route. A real-browser red mutation must
prove that bypassing relay/netd prevents the fake API request; a unit proxy
test is not evidence for the production chain.

The inner hook filter's “no new namespaces/mounts” contract must cover the
modern mount surface as well as the legacy calls: `mount`, `umount2`,
`pivot_root`, `fsopen`, `fsconfig`, `fsmount`, `fspick`, `open_tree`,
`move_mount`, `mount_setattr`, `unshare` and `setns`, plus all three
`io_uring` calls. `clone` must inspect and refuse every namespace bit while
ordinary Bun children remain usable; `clone3` returns `ENOSYS`. Because
`zb-hook-run` currently closes every descriptor at and above 3, it must make
the strict-filter descriptor only after that close, pass it to nested bwrap,
then close it. Tests must cover FD hygiene and an ordinary Bun child.

Finally, a relay inserted before the helper temporarily inherits helper fd 3,
which is the token stream. Its parent side must close fd 3 immediately and
must never inspect or log it. The plan needs exact readiness, signal/status
propagation, active-splice shutdown and reaping, with kill-before-readiness and
kill-after-readiness no-orphan cases. Agent Mail 5440 sent these requirements.

The setup-time R1 route probe is another production CLI launch and currently
bypasses the proposed boundary entirely. `setup.py:601-605` builds its
`contained()` prefix with writable `--dev-bind / /`, no private network
namespace and no proxy. `probe_r1` runs the real wrapper/CLI through that
prefix (`:725-749`), so `--agent-setup` exposes the host filesystem, every
loopback listener and abstract X11 before the drawer ever starts. `cli_version`
uses the same prefix. Rev 16 must cover these one-shot executions with minimal
read-only binds and a private netns; the R1 fake API must use the production
relay/netd test route. A real-binary setup e2e needs filesystem, loopback, LAN
and literal-X0 decoys plus a boundary-removal mutant. Agent Mail 5447 marked
this a blocker.

### Unrelated docs commits `da24aba` / `9ca44c9`

The macOS sandbox report is future-work research and introduces no production
change. Its initial three **SHOULD** corrections were: stale “not committed”
frontmatter; omission of the user's qualification that a P0 census may prove
an additional strictly-required CLI endpoint; and a claim that the Linux
netns/proxy/bridges were “built” when only the base bwrap/PID/seccomp
implementation exists today. Agent Mail 5432 sent them to BlueBeaver.
`9ca44c9` makes exactly those corrections (and fixes the RedTeam report's
same stale frontmatter). **Explicit verdict for `9ca44c9`: APPROVED; the
three documentation findings are CLOSED.**

BlackRobin's clean-export gate of the S3a follow-up snapshot was green:
**Build Summary: 106/106 steps succeeded; 817/817 tests passed**, and the
throwaway tree was deleted. This is sufficient evidence for this review-log
commit, but it does not approve that WIP: the hook-commands-only policy and
the blockers above were the tested behavior and still require a corrected
red-first implementation and a later gate.

### Pending crash-page `about:blank` follow-up

BlueBeaver's first clean-export gate of the comment-only shim clarification
and initial `about:blank` reload e2e was **RED: 104/106 steps succeeded;
817/817 tests passed**. `web-process-crash` passed, but `social-flows` failed
with an intermittent `-32603 Evaluation failed`; that flow then passed 3/3 in
isolation. The tested version also lacked the permanent no-click control, so
there is no approval and no commit. The worktree now has two fresh-browser
cases: a 12-second post-crash no-input hold and a clicked recovery bounded to
10 seconds. The targeted private-Xvfb run is green **48/48**. The 3-second
automatic-reload mutant is killed by exactly the new control (one failure:
the crash DOM/list state disappears without input), while the clicked case
stays green. This closes the blocker-for-tests. The overall verdict remains
pending one green full clean-export gate and a resulting commit. Agent Mails
5448-5449 record the disposition and mutant evidence.

## macOS launch plan review (`d857a03`)

**Verdict: BLOCKED.** The direction is right and the user decisions are
visible: universal Intel/Apple-Silicon builds, Seatbelt first with a VM
fallback, one semantic sandbox-backend contract, a docked AppKit drawer,
Keychain secrets, per-action social-write approval, Developer-ID work last,
and user-judged real-screen acceptance are all named. The implementation plan
is not yet safe or specific enough to start MS1-MS6. The following are plan
blockers, not requests to implement them now.

Evidence baseline: a clean archive of the code pin immediately before the
docs-only plan passed **Build Summary: 106/106 steps succeeded; 817/817 tests
passed** under private Xvfb. The plan commit changes documentation only.

### BLOCKER: MS2's closure map is not the full production topology

The generic chain at plan lines 310-365 is valid for ordinary routed
`dom.*`/`page.*` commands, but not for every operation claimed at lines
240-242. `page.list` and `page.health` branch before router parsing at
`automation_server.zig:480-487` and deliberately take no FIFO turn
(`automation_server.zig:686-691`); dialog discovery and recovery also have
special server paths. Therefore the single map cannot prove the out-of-band
frozen-window behavior, per-window FIFO ordering, dialog path, or two-phase
recovery. Add separate production chains/closure e2es for at least (a) an
ordinary socket command, (b) out-of-band list/health while one named window's
FIFO is stuck, and (c) recover. Tests must start at the authenticated socket
and observe through production reads; none may call the WK port or shim
directly.

MS2a/b/c also needs an explicit ABI/test inventory. The current behaviors do
not name `setInputFiles` (including regular-file refusal), native scroll/move
and pointer cache, full-page screenshot, reload/beforeunload, wait/evaluate,
startup readiness, late completion after timeout, or result/error-string
ownership. For every asynchronous Objective-C completion the plan must specify
copied input ownership, exactly-once completion, and a no-dispatch/no-write
guard after the waiter abandons. One representative DOM mutation cannot close
roughly 70 new C exports.

### BLOCKER: multi-window, freeze and recovery contracts are underspecified

Plan lines 292-306 say popups are tracked and crashes recover, but omit the
failure modes already found on GTK. Require real-socket e2es which create a
two-hop related popup chain, route commands to each `window_id`, prove FIFO
independence, and exercise both `page.close` and script `window.close()` while
the opener's URL and DOM state survive. The popup must use the
`WKWebViewConfiguration` supplied by WebKit so process-pool/data-store/content-
world behavior is intentional, not reconstructed accidentally.

`webViewWebContentProcessDidTerminate:` reports termination; it does not by
itself establish that a still-live content process is responsive. MS2c must
name the bounded probe/watchdog that updates per-window state without waiting
behind that window's FIFO, show one frozen window does not poison siblings,
and name the public-API recovery mechanism for a hung WKWebView. Recovery must
retain the existing two-phase consent, blast-radius acknowledgement,
exactly-once queued-job cancellation and “recovering” errors; there is no
automatic kill. If public WKWebView APIs cannot meet that contract, the plan
must stop at a spike rather than assume a reload can recover a hung process.

### BLOCKER: “native input” has no proven capability contract

Lines 150-153 keep WKWebView classified as `js_synthetic`, while lines
280-290 promise `input:"native"` through responder-chain `NSEvent`s. The
engine defines native input as real platform input and the browser contract
depends on trusted events, acknowledgements, atomic document guards and no
dispatch after timeout. Before this can be the default, MS2b needs red-first
real-WKWebView tests for `event.isTrusted`, focus, click, key, text,
contenteditable/beforeinput cancellation, scroll, pointer movement, navigation
during input, partial typing and deadline abandonment on both Macs. Update the
capability table only after those pass. If responder-chain delivery fails,
CGEvent/TCC is a user-visible alternative capability—not a silent fallback—and
its real-screen runner must obtain permission and verify its own app is the
frontmost target before emitting any input.

### BLOCKER: launch-critical setup, persistence and configuration have no owner

The plan adds the helper in MS6 but never ports provisioning. At the pin,
`runAgentSetup` explicitly refuses every non-Linux OS (`app.zig:41-47`) and
uses Linux paths including `/proc/self/exe`; the helper/runtime/SAI therefore
cannot be installed on a Mac. Add a macOS setup slice/behavior for the accepted
immutable `dist-<n>/current/state` layout, Python runtime/helper, SAI rule (a),
skipped outbound linked skills, no access to the real `~/.claude` or user
repositories, the FIFO-to-fd-3 route, and the accepted Claude login/setup-token
onboarding into Keychain.

Likewise `--profile-dir` is discarded off Linux (`app.zig:160-166`) and the
render/media flags are silent no-ops (`webkit.zig:47-72`). A launch plan needs
a persistent, isolated `WKWebsiteDataStore` contract so cookies/logins do not
fall into an implicit global store. It must also decide and test the macOS
meaning of `--hardware-acceleration`, `--renderer` and `--media-source`
(supported mapping or explicit unsupported error/documentation), rather than
silently accepting Linux-only behavior.

### BLOCKER: the shared sandbox interface is asserted at the wrong layer

Lines 163-174 call the interface “Zig, platform-neutral”, but the production
sandbox policy/argv today lives in Python (`agent/host/zb_agent_host/sandbox.py`)
and the Linux spawn/lifetime seam is GLib/C with `prctl`
(`src/agent_host.c:1-73`). The plan must identify the actual interface files,
methods, ownership and wire contract instead of implying an existing Zig
abstraction. Split the behavior-preserving Linux extraction into a pre-MS5
slice with its own Linux gate, then implement Seatbelt against exactly the
same semantic launch spec. The proxy/bridges are also rev-16 work in progress,
not an existing dependency; MS5 must either own them or depend on a named,
green landed revision.

### BLOCKER: Seatbelt failure must block launch and select the VM fallback

The sandbox reports make custom-profile acceptance, other-process info denial,
fd-3 reopening and orphan cleanup spike results, not assumptions. Yet lines
130-131 defer the VM to a later bead even if Seatbelt fails, and lines 539-544
offer a dedicated-user `kill(-1)` fallback that the user has not approved.
Make these hard gates before MS6: if any mandatory proof fails—including the
double-fork/`setsid` no-survivor proof—Mac agent launch remains disabled until
the shared interface's VM backend is implemented. Seatbelt-first is the
choice; “Seatbelt even when its security proof fails” is not.

The tests also need the real network route. MS5.3's direct loopback fake API
(lines 532-537) conflicts with MS5.2's rule that only the proxy and the two
bridges are reachable. The fake Messages API must traverse the production
proxy through an e2e-only allowlist seam, and removing/bypassing that proxy
must turn the real-browser test red. A direct decoy loopback service, LAN
address, public IP, DNS, WindowServer/CGEvent/screen capture, non-allowlisted
host and workspace write must fail; only proxy, 51091 and 31337 succeed. The
token-isolation mutant must use a deterministic sacrificial target so removing
Seatbelt actually exposes the canary; a host/TCC denial that stays green does
not prove the profile.

### BLOCKER: approval, Keychain and chat observability are not closed

MS3 says it reuses “the same approval path as Linux” at lines 400-405, but no
production approval authority exists at the plan pin; the research itself
says the approval card is unimplemented. Specify the grant contract before
flows: exact action, site/account/window/payload binding, one use, expiry,
cancel/refuse, and only the native Approve handler may mint it. Real-binary
tests must prove page worlds, iframes, related popups, automation-socket
clients, prompts and hooks cannot approve; each Send/Post/Follow/Connect/Like/
Next write gets a separate confirmation; dry-run performs no committing click,
real-composer typing or pacing count.

Keychain tests must use a disposable service/account and canary, never a real
user credential, and prove the token reaches only helper fd 3—not env, argv,
logs, telemetry, hook environment or model context. The plan also needs the
accepted claude.ai callback and/or `claude setup-token` acquisition path.
Finally, MS6's proposed observation “through ... the socket” (lines 615-616)
would violate the drawer threat model if it exposed native drawer text to an
automation client. Observe through a gated `--e2e-protocol` native census or
screen capture, never a production socket drawer-read API.

### BLOCKER: the two-architecture and packaging gates can false-green

MS1 must provision two distinct hosts and assert the Intel host is really
`x86_64` and the Apple-Silicon host really executes the `arm64` slice, not an
x86 process under Rosetta. Run the resulting universal app on each machine and
record the executing architecture in production build info; `lipo -archs` and
`--version` alone prove only that two Mach-O slices exist. The gate also needs
to cover every bundled native component and the helper/CLI/runtime strategy,
not only the top-level browser executable, and verify the two per-arch bundles
have compatible non-executable resources before combining them.

Every MS2-MS6 sub-slice needs a named red test, exact failing assertion, green
production files and refactor gate. The current MS2-MS6 prose mostly states
behaviors without the red/green/refactor evidence promised at lines 34-39.
The macOS runner must fail closed when either host lacks an active GUI session,
the expected native architecture, a required runtime/SDK, or a nonzero test
assertion count. MS4 and MS6 correctly require the user's visual verdict; any
script that sends real-screen input must first prove its own window is focused,
viewable, topmost at the target and abort under a server/grab-equivalent guard
if not.

### BLOCKER: signing is last, but its contract is not release-safe yet

Deferring Developer-ID signing/notarization to MS7 correctly follows the
user's decision. However, “whatever the Seatbelt launcher needs” at lines
223-226 is not an entitlement list, and signing the finished bundle with
`codesign --deep` at lines 639-644 does not define the identity/entitlements of
nested helpers, frameworks or executable runtimes. MS1 must derive and test an
exact least-privilege entitlement manifest; MS7 must sign nested code in an
explicit inside-out order and then verify the whole universal bundle under
hardened runtime on both architectures before notarization. Until the user has
a Developer ID, the plan should call the result an ad-hoc development build,
not a distributable launch artifact. The line saying the missing credential is
“tracked as a bead dependency” must instead use Agent Mail/plan status while
the shared beads database remains migration-locked.

### Open-question dispositions

1. Responder-chain NSEvent is a spike result, not an assumption; the trusted-
   event matrix above decides it. CGEvent is explicit TCC-gated fallback only.
2. `/dev/fd/3` reopening is a hard MS5 spike gate on both architectures.
3. Custom `sandbox-exec` profiles are a hard gate; failure selects VM and
   blocks MS6.
4. Yes: extract the Linux backend interface in its own pre-MS5 slice and keep
   the Linux gate isolated.
5. Keep MS2a, MS2b and MS2c as separate reviewed gates; also split the
   out-of-band health/recover closure from crash-page presentation if one
   commit cannot keep a single red seam.

Agent Mail 5458 sent these findings to JadeBeacon, with BlackRobin and
BlueBeaver copied for the cross-owned seams. No source implementation is
authorized by this review.

## S3a rev 15.6 implementation review (`cab60a1`)

**Explicit verdict: BLOCKED.** The revision now follows the user's latest,
direct policy choice: only hook command lines receive strict path/grammar
validation; copied text gets the HOME rewrite; physical dependency, VCS,
cache and build trees copy without inspection; and links leaving an item are
skipped with a warning. The immutable `dist-<n>/current/state` split is also
preserved, `helper_argv` no longer repairs a published build, the state modes
fail closed, and the remaining real-screen refusal cases now assert zero
XTest motion. Those changes close the earlier policy, published-build and
input-guard findings, but three uncovered production failures remain.

### BLOCKER: a top-level link can traverse a link chain in a parent component

`_link_target` normalizes the textual target and calls `os.lstat(target)`
(`agent/host/zb_agent_host/setup.py:305-317`). `lstat` refuses a symlink only
when it is the final component; the kernel follows symlinks in all parent
components. A read-only throwaway probe made
`source/CLAUDE.md -> hop/CLAUDE.md`, `source/hop -> /outside`, and a regular
`/outside/CLAUDE.md`. Setup logged that target and copied its
`CHAIN_CANARY`. That is a two-link chain despite the “followed once” contract.
The existing chain test makes the final target itself a link, so it does not
cover this path shape. Resolve the path component-by-component without
following links, or reject an intermediate link, and add this exact canary
case.

### BLOCKER: the global cycle set silently drops internal aliases

`_copy_tree` shares one `seen` set across the complete item and never removes
an entry on return (`setup.py:320-344`). A throwaway `skills/alias -> real`
fixture produced only `alias/payload.txt`; the later canonical `real` name was
silently omitted. Reversing lexical order would omit the alias instead. This
is especially unsafe for pnpm/node_modules-style internal aliases and violates
the stated rule that nothing vanishes silently. Cycle detection must be based
on the active recursion ancestry, or aliases must be deliberately
materialized; a regression must preserve both names and separately bound a
real cycle.

### BLOCKER: malformed hook quoting escapes the refusal/error contract

Both `check_hooks` and `check_hook_links` call `shlex.split` before the closed
grammar can reject quoting (`setup.py:117-147,214-230`). The probe command
`python3 "unterminated` raised raw `ValueError: No closing quotation` in both
paths. `main` maps `ValueError` to generic exit 1 (`setup.py:817-825`), while
an unsupported hook grammar is a setup refusal and must exit 2 without
publishing. Convert this parser error to `SetupError` (or reject the raw
string before splitting) and cover it in both the unit suite and real-binary
setup e2e.

### SHOULD: pin source objects between classification and read

The recursive copier still classifies a pathname and later reads it by a new
pathname lookup (`setup.py:324-369`). A same-user concurrent change can swap
a checked regular file for a symlink or FIFO before `Path.read_bytes()`.
This is outside the primary hostile-model boundary but is avoidable setup
TOCTOU: prefer directory-fd traversal and an `O_NOFOLLOW` regular-file fd.

BlackRobin's clean-export gate for the committed slice was green:
**Build Summary: 106/106 steps succeeded; 817/817 tests passed**, including
78/78 setup e2e, 74/74 helper unit and 23/23 P0 contract checks. The gate tree
was deleted. Green coverage does not waive the three missing cases. Agent Mail
5468 sent the findings and exact probe results to BlackRobin, with BlueBeaver
copied.

## macOS launch plan rev 2 and 2.1 (`c3d7217`, `9c2b2c3`)

**Explicit verdict for both commits: BLOCKED (docs).** Rev 2 substantially
closes the nine findings against `d857a03`: it splits the socket topology into
ordinary, out-of-band and recovery closure maps; gives multi-window/freeze and
async ownership explicit contracts; makes native input a two-host capability
spike; owns persistent WebKit configuration and setup; identifies the real
Python/C sandbox seam; makes failed Seatbelt proofs select the VM fallback;
requires two actually executing architectures; and keeps signing last. Rev
2.1 adds the requested no-target-bytes proof for a skipped linked skill. Three
contracts remain inconsistent.

1. **BLOCKER — MS5 still names the superseded SAI rule.** The summary and
   MS5.1 call rule (a) an “executed-import-graph”
   (`macos-launch-tdd-plan.md:45,552-558`). The final user decision is **Hook
   commands only**. The Mac port must reuse the corrected Linux behavior:
   copy dependency/VCS/cache/build trees unscanned, HOME-rewrite other copied
   text, validate only hook command lines, and warn/skip outbound links. It
   must also inherit the chain, alias and malformed-quote corrections required
   above rather than port today's defects.
2. **BLOCKER — the grant tuple is weaker than the accepted threat contract.**
   MS4.1 binds action/site/account/window/payload (`:510-514`) but does not
   explicitly bind `origin`, `target_fp`, `load_serial` and each argument.
   Reuse the drawer plan's exact grant schema and its navigation,
   selector-retarget and one-field-at-a-time mutants.
3. **BLOCKER — the positive closure precedes the only grant minter.** MS4's
   closure/gate requires an approved grant to commit through a real flow
   (`:533-542`) while the only permitted native Approve handler is not built
   until MS7 (`:653-687`). MS4 may close the authority and all negative,
   refusal and dry-run paths. Move the positive
   socket-to-card-to-grant-to-flow closure to MS7, or move the production
   handler earlier; a test-only mint would bypass the forbidden span.
4. **BLOCKER — the “explicit ABI inventory” is not the production ABI.** The
   MS2 list at `:318-324` omits `zb_automation_set_script` (private-world
   injection before the first load), `zb_automation_free` (the allocator
   paired with every returned C string), `zb_automation_loop_mark` (ENDED,
   queued-job cancellation and waiter wake-up on app quit),
   `zb_automation_window_alive`, `zb_native_pointer`, protocol-row field
   sanitization, and the cookie ABI. It also does not decide which of the
   roughly 35 deterministic `zb_automation_debug_*` seams exist on macOS or
   require unsupported seams to fail closed instead of silently returning
   zero. Add these to the inventory and tests; at minimum prove private-world
   installation, allocator pairing, immediate quit cancellation and the
   late-completion mutants through real seams.
5. **BLOCKER — window destruction does not close drawer ownership.** MS2c
   covers `page.close` and script `window.close()`, and MS7 says it mounts
   from `zb_window_new`, but the plan never requires every popup to receive
   its own drawer bound to its `window_id`, nor one shared destroy path for
   `webViewDidClose:`, the NSWindow close button and automation close. Specify
   detach before automation notification/free, exact reuse of WebKit's
   supplied configuration, and a live-drawer count of zero after all windows
   close.
6. **BLOCKER — crash presentation parity is absent.** The current Linux
   product reports per-window termination and shows a static crash document,
   keeps the committed URL, excludes API-driven termination, clears
   `crashed` only on a real commit and never auto-reloads (`ddc892e`,
   `44d0d0f`). MS2c names termination and recovery but no visible crash
   contract. Add the macOS analog (for example
   `webViewWebContentProcessDidTerminate:` plus a public simulated-request
   crash document) with real-X/no-input and clicked-Reload controls.

The docked drawer, disposable Keychain canary, callback/setup-token routes,
real Intel plus native arm64 execution, real-Mac visual acceptance and
Developer-ID-last policy are otherwise faithful. Before implementation, the
plan should also make several **SHOULD** details explicit: no main-thread
caller may synchronously wait on a main-queue marshal; dialogs hold completion
handlers rather than running a modal loop; health/list snapshots are
lock/atomic-backed and never `dispatch_sync` to a hung main queue; the public
recover spike should try replacement of the WKWebView while retaining its
window id rather than private SPI; scroll events can be built from a CGEvent
and delivered in-process with `-[NSWindow sendEvent:]` without posting to the
system or asking for TCC; icon/fold views intentionally overlap the page and
need exact hit-testing even though the dock does not; keyboard/fold-row and
Secrets-exclusion parity need named tests; and the real-screen runner must
fail closed when Screen Recording/window-order evidence is unavailable.
Agent Mail 5469 sent the first three findings to JadeBeacon and copied
BlackRobin; the ABI-owner follow-up arrived as mail 5475 and is incorporated
here.

## Chat-drawer plan rev 16 (`cd59bb5`)

**Explicit verdict: BLOCKED (docs).** The selected architecture matches the
user and RedTeam decisions: bwrap remains the Linux backend; the outer helper
gets a private network namespace; host egress is an exact CONNECT allowlist;
only ports 51091 and 31337 cross explicit bridges; hooks get the stricter
post-namespace seccomp filter; and the token remains FIFO to socketpair fd 3,
never environment. The bounded parser, resolve-once rule, sensitive-log
prohibition, fixed bridge handlers and fake API through the production proxy
are sound requirements. Five blockers prevent S3n1/S3n2 from starting.

### BLOCKER: the production setup probe has no usable network route

Section 3c.4 gates `ZIGBROWSER_AGENT_NET_TEST` and its fake TLS mapping on
`--e2e-protocol` (`plan:854-860`), but section 3c.7 says the ordinary
production R1 setup probe reaches its one-shot loopback server through that
same route (`:887-896`). Normal `--agent-setup` has no e2e capability, and the
current probe server is plain loopback HTTP (`setup.py:765-798`). Define a
separate app-owned internal production probe route/capability, not a user env
seam, or put the one-shot server inside the private namespace. If it traverses
CONNECT, specify its TLS name and trust root. A normal setup e2e without
`--e2e-protocol` must prove R1 succeeds while the decoys remain unreachable.

### BLOCKER: “R3 removed everywhere” is contradicted by active requirements

The new section says the flag, route and every assertion are gone, but active
text still permits or tests R3: the decision row at `plan:977`, T6 and A4 at
`:1248,1254`, P0.4 at `:1294-1296`, S3.7 at `:1662`, S3.9 at
`:1683,1689`, S4.2 at `:1794`, and S4.4 at `:1801-1803`. Convert these to
R1-only behavior or explicit legacy-refusal/red-mutant wording. D6 also still
offers bare `curl`/`env` (`:302`) although the final grammar refuses them, and
D12 still describes import scanning (`:629`) despite Hook-commands-only.
The override paragraph does not make mutually executable slice instructions
safe.

### BLOCKER: netd's executable, filesystem and resolver closure is absent

The topology says the netd bwrap “sees only its socket directory”
(`plan:815-819`). A standard-library Python service also needs its interpreter,
runtime/shared libraries and the minimal resolver configuration used by
`getaddrinfo`. Specify the exact read-only binds and environment, including
the deliberately selected `/etc` resolver files, then prove the allowlisted
name resolves while HOME, repository, profile and secrets remain absent.

### BLOCKER: deterministic socket-directory lifetime fails after a crash

`$XDG_RUNTIME_DIR/zigbrowser-agent-<pid>` must not already exist
(`plan:824-827`) and no owner removes it. A SIGKILL followed by PID reuse makes
that PID unable to launch an agent and leaves a predictable stale-path denial.
Use an exclusively created private random-suffix directory with ownership,
mode and no-follow validation; clean it on normal exit and test the stale
crash/PID-reuse case without deleting arbitrary neighbors.

### BLOCKER: the stated PID-1 topology is not the specified bwrap topology

The plan calls the relay namespace PID 1 (`plan:829-836`) but never requests
`--as-pid-1`. By default bwrap's reaper is PID 1 and the command is its child.
Retain that safer, already-used reaper and correct the lifecycle language and
tests, or explicitly add and justify `--as-pid-1`; do not base orphan or
signal claims on an impossible topology.

Two hardening items are **SHOULD**: bind the pre-created socket directory
read-only into the untrusted outer sandbox unless a tested mutation need is
identified, and require the relay/launcher to close every inherited fd at or
above 3 except explicitly owned listener/control descriptors, not fd 3 alone.
BlueBeaver subsequently proved in a throwaway bwrap that `connect()` through
the read-only bind succeeds while create, rename and unlink get `EROFS`, so
the plan should make that read-only bind mandatory. It must also validate the
complete Unix-socket paths against `sun_path`'s 108-byte storage (107 usable
bytes) and use short e2e directories; a long session scratchpad is not a valid
test socket root.
Agent Mail 5470 sent this verdict to BlackRobin and BlueBeaver. BlueBeaver's
independent interface note 5466 agrees on the PID-1 correction, random suffix
and complete inherited-fd census.

## `about:blank` crash-page closure (`44d0d0f`)

**Explicit verdict: APPROVED.** The only production-file change corrects a
comment; behavior is unchanged. The new real-binary private-Xvfb test uses two
fresh browsers: its control sends no post-crash X input for 12 seconds and
requires both the crash DOM and `page.list.crashed` to remain; its action case
uses a real X click and requires a plain `about:blank` Reload link to clear the
crash within 10 seconds. Dropping the link fails both cases, while a delayed
three-second automatic reload fails only the no-input control. That proves the
click rather than a timer causes recovery and closes the prior SHOULD.

BlueBeaver's clean archive plus the two subsequently committed blobs passed
**Build Summary: 106/106 steps succeeded; 817/817 tests passed**; both blobs
are identical to the gated copies and the tree/cache were deleted. The later
commits before `44d0d0f` consist of the separately gated `cab60a1` source and
docs-only plans. This approves `44d0d0f` itself; it does not approve the
blocked S3a or plans beneath it.

I then ran one independent bounded clean-export gate at exact `44d0d0f`, with
a fresh cache under private Xvfb. It passed the combined committed tree:
**Build Summary: 106/106 steps succeeded; 817/817 tests passed**. The EXIT
trap deleted the export and cache immediately. No live browser, live socket,
account, token or DISPLAY `:0` was used.

## Explicit unpushed-prefix audit at `44d0d0f`

Every commit after `origin/zb-automation-integration-2026-10-10-11-59` is
classified here. “Superseded” records an exact historical revision; it is not
an approval of that old snapshot.

| Commits | Explicit verdict |
|---|---|
| `abbf0ea`, `4e3b09c`, `69e6fc4` | **BLOCKED at each exact implementation revision; superseded by `cab60a1`.** |
| `cab60a1` | **BLOCKED** by the three production findings above. Its hook-only policy, published-build validation and final zero-motion assertion are accepted. |
| `220af5a` | **APPROVED.** |
| `607c3a3` | **APPROVED as completed by `60ce3b6`.** |
| `60ce3b6` | **APPROVED**, including the user's real NVIDIA “All works” verdict and accepted docked contract. |
| `ddc892e`, `44d0d0f` | **APPROVED.** The latter closes the former's `about:blank` SHOULD. |
| `1be5169`, `eef2ff6` | **BLOCKED at the exact revisions; superseded.** `cc9d135` plus `cab60a1` close their focus, property-type and zero-motion test gaps. |
| `cc9d135` | **APPROVED.** |
| `be46e05`, `7eab90f`, `d9674c1`, `0524293`, `46cdcf2`, `22ff1f9`, `ce275ab`, `f73296b`, `f262998`, `159c48a` | **BLOCKED at the exact plan revisions; superseded by later revisions/decisions.** Their durable accepted results are folded into the current plan. |
| `c3d7217`, `9c2b2c3` | **BLOCKED** by the three macOS-plan findings above. |
| `cd59bb5` | **BLOCKED** by the five rev-16 plan findings above. |
| `d7527bb`, `f72e63d`, `69c7098`, `7ae9b64`, `a915d44`, `cdc88d2`, `b5886ce`, `120dc57`, `9380c32`, `bcc721d`, `21625eb` | **APPROVED as review/evidence documentation.** Later entries supersede their status conclusions where stated. |
| `ac94248`, `86ddf01`, `da24aba`, `9ca44c9`, `1df5dce` | **APPROVED as research documentation.** `9ca44c9` is the authoritative decision/status correction. |
| `d857a03` | **BLOCKED at rev 1; superseded by rev 2/2.1**, which remain blocked above. |

There is therefore **no approved linear push prefix after the current origin**:
the first unpushed source commit is ultimately replaced by `cab60a1`, and that
current implementation is still blocked. Later approved commits cannot be
pushed as a prefix without also pushing the blocked S3a history. No push or
history rewrite was performed.

## macOS launch plan rev 3 (`a02f1ea`, with `5bebd42` follow-up)

**Explicit verdict for `a02f1ea`: BLOCKED (docs).** **Explicit verdict for
`5bebd42`: APPROVED as a narrow API-name correction; it does not approve the
underlying plan.** Rev 3 correctly adopts the final Hook-commands-only copy
policy and the drawer plan's full grant tuple; specifies per-popup drawer
ownership and one detach-before-free destroy path; adds visible crash-page
parity; keeps the docked drawer, Keychain, per-action approval, universal
two-host gate, Seatbelt-first/VM-fallback rule and Developer-ID-last release
gate; and requires the user's eyes for UI slices. Four implementation-blocking
contracts remain.

1. **BLOCKER — the positive approval closure still has no production source.**
   MS7.8 says an automation-socket `tool_use` starts the chain
   (`macos-launch-tdd-plan.md:780-785,805-811`). The accepted drawer
   architecture explicitly makes the broker unreachable from that socket;
   production `tool_use` arrives from the fake Anthropic API through the CLI,
   helper and protocol pump (`claude-agent-chat-drawer-tdd-plan.md:1231-1232,
   2013-2020`). Those components are not launched or wired until this Mac
   plan's MS8 (`macos-launch-tdd-plan.md:819-840`). Thus MS7 cannot execute its
   claimed end-to-end positive chain without either violating socket
   separation or injecting inside the forbidden span. Move the positive
   closure to MS8 after the production helper/broker path exists (MS7 can
   close native-card mint/deny behavior), or reorder the production connector
   before it. The Mac action must also say AppKit/native click, not “X click.”
2. **BLOCKER — the production ABI inventory is still neither complete nor
   executable in its stated order.** The pinned header also exports
   `zb_main_invoke_sync`, `zb_automation_window_id_at` and
   `zb_automation_run_generation`, none of which the alleged exhaustive list
   at `:353-374` assigns to a slice. App/profile/render/drawer exports are
   assigned elsewhere but not cross-referenced, so “every `webkit_shim.h`
   export” is false as written. More importantly, the plan still says it will
   *decide later* which debug seams exist and that every unsupported seam
   returns an explicit unsupported error; several debug signatures are
   `void` or return an ordinary count/boolean and have no such error channel.
   Add a literal export-by-export table with implementing slice, exact
   unsupported sentinel/error mechanism and named test. Finally, MS2c cannot
   gate its cookie ABI “via MS3's `WKHTTPCookieStore` port” (`:368-369`) when
   dependency order puts MS2c before MS3 (`:869-873`); move those exports/tests
   to MS3 or reorder the slices.
3. **BLOCKER — MS5 depends on corrections that `cab60a1` does not contain.**
   MS5.1 and the references call `cab60a1` the corrected chain/alias/
   malformed-quote implementation (`:647-659,892`), but the exact commit is
   still blocked: a parent-component symlink chain is refused, the global
   seen-set drops valid internal aliases, and an unterminated hook quote exits
   zero. Require a named green follow-up before MS5, or make MS5 own the shared
   fixes and the three red-first regressions before the Mac port reuses them.
4. **BLOCKER — the native-input fallback still contradicts the folded
   decision.** Rev 3 correctly says a CGEvent may be converted to an NSEvent
   and delivered in-process with `-[NSWindow sendEvent:]`, with no system post
   and no TCC (`:60-71`). The executable MS2b contract and the still-active
   disposition instead call CGEvent a TCC-gated alternative (`:87-91,
   385-393`). Distinguish in-process CGEvent-to-NSEvent construction from
   `CGEventPost`: require the former to be spiked first, and leave system-wide
   posting out unless a separately approved capability is genuinely needed.
   `5bebd42` correctly replaces the nonexistent
   `NSRunningApplication.activeApplication` idea with
   `NSWorkspace.frontmostApplication`/`NSApp.isActive`, but it does not resolve
   this delivery contradiction.

Two documentation corrections are **SHOULD**: the testing strategy still says
ClosureMaps are pinned to `21625eb` even though all three JSON maps correctly
pin `833767e` (`:218-219,444-529`), and the crash control still says
“real-X/no-input” on macOS (`:415-423`). The three maps' node/edge counts and
their pinned production symbols otherwise check out. The six prior blockers
therefore stand as: #2, #5 and #6 closed by rev 3; #1 semantically corrected
but dependent on an unlanded green S3a fix; #3 and #4 still open for the
reasons above.

## S3a follow-up and prefix audit at `da5eb70`

**Explicit verdict for `da5eb70`: APPROVED.** It closes all three production
BLOCKERs reported against `cab60a1` without relaxing the selected copy policy:

- `_link_target` now requires the normalized target to equal its `realpath`,
  so a link hidden in any target component is treated as a chain and skipped
  (`agent/host/zb_agent_host/setup.py:318-334`). The new canary exercises the
  concrete `CLAUDE.md -> hop/CLAUDE.md`, `hop -> /outside` escape.
- `_copy_tree` tracks only the real directories on the active recursion path,
  preserving both names of a valid internal alias while still cutting a true
  ancestor cycle (`setup.py:337-372`). The regression places the alias both
  before and after the canonical name so lexical ordering cannot mask a global
  seen-set bug.
- `hook_tokens` applies the closed raw-string grammar before splitting, so an
  unterminated quote produces the named `SetupError`/exit 2 rather than a
  `shlex` exception or a successful setup (`setup.py:214-220`). Both the unit
  path and the real binary exercise that production parser.

The same commit replaces pathname rereads with one
`O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC` descriptor, verifies it with `fstat`, and
reads the bytes from that descriptor (`setup.py:378-399`). This is the right
leaf-file pinning primitive. A **non-blocking SHOULD-for-tests** remains: add a
deterministic swap seam proving `_copy_file` refuses a leaf changed to a link
or FIFO. The current tests do not directly kill a mutation back to
`Path.read_bytes()`. Full parent-component race resistance would require
dirfd-relative traversal (the source is same-user input and this was not the
selected hostile boundary), so it is not a new blocker on S3a.

The TDD evidence is independently reproducible. On `da5eb70^`, transplanting
only the three new unit regressions is red: the component-chain canary is
copied, both alias orderings lose a name, and the malformed quote escapes as
`ValueError`. At exact `da5eb70`, all 44 provisioning tests pass; the
real-binary setup e2e passes **82 checks, 0 failed**, including exit 2, an
unchanged home and no decoy event for the malformed quote. A fresh-cache,
private-Xvfb clean-export full gate at exact `da5eb70` passed **Build Summary:
106/106 steps succeeded; 817/817 tests passed**. Its EXIT trap deleted the
export and cache. No live browser, socket, account, token or DISPLAY `:0` was
used.

This also closes macOS rev 3 finding 3 cumulatively: `da5eb70`, rather than
the stale `cab60a1` citation, is now the named green dependency for MS5. The
plan should correct that citation, but the implementation dependency is no
longer missing. `a02f1ea` nevertheless remains **BLOCKED** by its three
independent contracts: the MS7 positive approval chain starts from the
forbidden automation-socket route before the production helper exists; the
ABI inventory/order is incomplete and gives unsupported semantics to
signatures with no error channel; and the executable CGEvent fallback still
contradicts the accepted in-process, non-TCC delivery decision. `5bebd42`
remains **APPROVED only as its narrow frontmost-application API correction**.

The requested linear range `abbf0ea..da5eb70` is therefore **NOT fully
approved**. Its cumulative S3a implementation is approved at `da5eb70`, and
the previously approved UI/crash/manual-test/research/review commits retain
their verdicts, but the range contains two current blocked plan artifacts:
`cd59bb5` (the five rev-16 network-boundary/topology findings recorded above)
and `a02f1ea` (the three remaining macOS findings just listed). The later
`c9f7b23` rev-16.1 plan commit landed while this gate ran and is outside the
requested range; it needs its own review and cannot retroactively make the
exact range fully approved. There is no approved push-through SHA at
`da5eb70`; no push or history rewrite was performed.

## Per-hook sealed-network decision and plan `6efe260`

The user's 2026-10-14 decision is binding: every hook gets its own network
namespace, can reach only the two fixed bridges at `127.0.0.1:51091` and
`:31337`, and has no route to the HTTP CONNECT proxy or Anthropic API. Only
the Claude CLI may reach the allowlisted API. The slice must measure and
report the added start cost; there is no performance budget before that
measurement.

**Explicit verdict for `c9f7b23`: BLOCKED (docs), with four of the five
`cd59bb5` findings closed.** Rev 16.1 supplies a production setup-probe route
wholly inside one private netns and a normal non-e2e acceptance test; specifies
netd's minimal filesystem/resolver closure; replaces the deterministic socket
directory with exclusive random creation, fd-relative cleanup, a `sun_path`
bound and a read-only sandbox bind; and correctly leaves bwrap's reaper as PID
1 while the relay is its child. It also closes the two associated SHOULDs by
closing inherited descriptors and requiring the read-only bind. Those are
findings 1, 3, 4 and 5 from `833767e`.

Finding 2 remains **OPEN**. Two active risk-table rows still say R3 is an
explicit opt-in and require an S3.9 R3 run
(`claude-agent-chat-drawer-tdd-plan.md@c9f7b23:727,738`). They are neither
historical nor superseded and contradict §3c.1's R1-only contract. Rewrite
R2-2 and R5-2 as legacy-refusal/history, with the current R1-only mitigation.
The other R3 mentions at `:558-559,973-974,1341` are correctly labelled
history, red mutation or refusal tests and may remain.

**Explicit verdict for `6efe260`: BLOCKED (docs).** The chosen separation is
correct, and the revision correctly removes proxy variables from hook
environments, names a bridge-only relay, requires both positive bridge checks
and makes dropping the nested `--unshare-net` a red mutation. It inherits the
open R3 risk-table contradiction from `c9f7b23`, and four additional executable
contract gaps remain before S3n1/S3n2 may build it.

1. **BLOCKER — D12's pinned nested-bwrap argv cannot reach the stated bridge
   sockets.** Its exact order still lacks `--unshare-net` and mounts a private
   tmpfs over `/run` (`claude-agent-chat-drawer-tdd-plan.md:639-649`), which
   hides `/run/zb-net/port-51091.sock` and `port-31337.sock` from the relay
   described at `:953-957`. Rebinding the old whole socket directory would be
   worse: it also contains `proxy.sock`, so a hook could bypass the network
   namespace with a Unix-socket CONNECT. Split the netd output into an
   `egress/` directory holding only `proxy.sock` and a `bridges/` directory
   holding only the two bridge sockets; bind only `bridges/` read-only after
   the nested `/run` tmpfs. Test that both bridge sockets are visible and no
   `proxy.sock` exists anywhere in the hook view.
2. **BLOCKER — the active topology still describes the superseded authority.**
   The §3c.2 diagram draws hooks directly into the outer relay
   (`:813-820`), while D12 still says hook egress goes through the host proxy
   (`:656`). Specify two distinct lifecycles: a proxy-only outer relay for the
   helper/CLI, and one bridge-only nested relay per hook. Give the inner
   relay's exact argv, standard-library-only installed runtime path,
   fork/exec/stdio behavior, status and signal propagation, reap behavior and
   no-orphan test.
3. **BLOCKER — the negative test could reach the real API and does not prove
   the required edge.** The new test sends a CONNECT for
   `api.anthropic.com` to port 3128 (`:960-964`). Under the deliberate
   no-`--unshare-net` mutant that reaches the production allowlist. Use the
   offline e2e allowlist name `fake.zb.invalid`, assert the raw CONNECT/TLS
   path fails and the fake API's request count stays zero, and assert direct
   connection to the proxy Unix socket is impossible. The positive control
   must exchange bytes through both bridge decoys.
4. **BLOCKER — the required cost measurement is assigned to completed P0.**
   The revision says the “P0 census” measures the new relay (`:958`), but P0
   predates it. S3n2 must run and report the measurement: paired warmed runs
   of the same no-op hook with and without the inner netns/relay, at least 30
   samples, with sample count, median and p90/p95. BlueBeaver's 30-run
   prototype measured about 15 ms incremental cost (19.4 ms median versus
   4.1 ms today), but the real slice still must measure its production path.

Two **SHOULD** corrections improve traceability and closure: add a distinct
R16.2 history row rather than silently extending R16.1, and update the
real-binary S3.8/S3.9/S4.4/S7.6 closures to exercise both bridges plus the
fake-API negative, rather than leaving the new edge only in a component test.
Agent Mail 5492 sent the blockers to BlackRobin and BlueBeaver; BlueBeaver's
independent mail 5491 confirmed the Unix-socket bypass and proposed the same
directory split.

This is a docs-only revision after the exact-`da5eb70` clean gate already
recorded above (**106/106 steps, 817/817 tests**); no production source changed
between that gate and `6efe260`. No live browser, DISPLAY `:0`, account or
token was used.

### Linear push-through answer at `6efe260`

The range through and including `c3d7217` is **not** an approved push-through
range. Although the obsolete macOS rev 1/rev 2 plan verdicts can be superseded
by a later plan, the cumulative tree at `c3d7217` ends with the production S3a
implementation from `cab60a1`. Its parent-component link, internal-alias and
malformed-hook-quote defects are not fixed until the later `da5eb70`; pushing
only through `c3d7217` would omit all three fixes. The first unpushed commit,
`abbf0ea`, is itself part of that incomplete S3a chain, so there is no earlier
unpushed safe stopping point. The newest approved push-through SHA remains the
current origin, **`fa0aa48`**. This is a statement about the resulting tree at
the pushed SHA, not an objection to retaining superseded plan revisions in
history. No push was performed.

## Network plan rev 16.2, pinned-read test, and macOS plan rev 4/5

### Drawer network plan rev 16.2 (`3856558`)

**Explicit verdict for `3856558`: APPROVED (docs).** Rev 16.2 closes every
BLOCKER and SHOULD recorded against `c9f7b23`/`6efe260` in the preceding
section:

- R2-2 and R5-2 now mark R3 as history and state the current R1-only route and
  legacy-refusal behavior (`claude-agent-chat-drawer-tdd-plan.md@3856558:
  730,741`).
- The socket authority is physically split into 0700 `egress/` and `bridges/`
  directories, with only 0600 `proxy.sock` in the former and only the two
  bridge sockets in the latter (`:833-841`). D12's pinned nested-bwrap argv now
  includes `--unshare-net`, restores only `bridges/` after the private `/run`,
  installs the hook filter, and invokes the inner relay before the hook
  (`:639-649`). Thus a hook cannot bypass its netns through the proxy's Unix
  socket.
- The active topology has two explicit lifecycles: one proxy-only outer relay
  and one bridge-only inner relay per hook (`:815-848,953-1007`). The inner
  relay has an exact standard-library-only runtime path/argv, descriptor and
  stdio ownership, pre-fork signal mask, fork/exec behavior, bounded splice
  loop, status/signal parity, bwrap-reaper relationship and no-orphan tests.
- The negative is offline-safe: `fake.zb.invalid`, raw CONNECT/TLS failure,
  fake request count zero, `egress/proxy.sock` ENOENT, DNS/direct-IP refusal,
  and two red mutants (missing nested netns and over-broad socket mount). Both
  bridge decoys exchange bytes as the positive control (`:986-1007`).
- The production S3.8, S3.9, S4.4 and S7.6 closures repeat both bridge
  positives and both proxy negatives (`:1786,1804,1919,2086`); the new R16.2
  history row is distinct (`:781`). The real implementation cost is assigned
  to S3n2 as paired, warmed runs with at least 30 samples and reports n,
  median, p90 and p95; the prototype's roughly 15 ms is only an expectation
  (`:980-984`).

The design therefore satisfies the user's “bridges only per hook” decision:
hooks can reach 51091 and 31337, but neither TCP 3128 nor the proxy Unix
socket; only the outer helper/CLI sandbox has the egress relay. The Linux
mechanisms in this revision are the Linux backend contract; macOS portability
is reviewed separately below.

### S3a pinned-read regression (`9cf8fd2`)

**Explicit verdict for `9cf8fd2`: APPROVED.** The test-only commit closes the
non-blocking SHOULD from `db02324`. `PinnedReadTest` directly proves a regular
leaf reads, while a symlink and unopened FIFO refuse without blocking, and its
deterministic `os.stat` seam swaps the classified `README.md` to a symlink
before `_read_regular`; setup reports “changed while setup read it” and
publishes nothing (`agent/host/tests/test_provision.py@9cf8fd2:278-313`). A
mutation back to pathname `Path.read_bytes()` fails these tests (and the FIFO
case is bounded by the gate timeout), so the regression observes the intended
production seam rather than a duplicate test-only implementation.

### macOS launch plan rev 4 (`74413b0`) and rev 5 (`c8b646a`)

**Explicit verdict for `74413b0`: BLOCKED (docs), with three prior contracts
closed and one narrow ABI item still open at that exact SHA.** Rev 4 correctly:

- moves the positive approved-commit closure to MS8.3, where `tool_use` comes
  from the fake Anthropic API through the production proxy, CLI, helper and
  protocol pump—not the automation socket—and leaves MS7.8 to prove only the
  native AppKit card's mint/deny boundary (`macos-launch-tdd-plan.md@74413b0:
  899-946,959-997`);
- inventories all 44 production and 31 debug header exports, assigns the three
  previously omitted registry/marshal exports, and moves the cookie ABI into
  the earlier MS3 data-store slice (`:395-468,664-685`); and
- distinguishes in-process CGEvent-to-NSEvent construction delivered with
  `-[NSWindow sendEvent:]` (no post and no TCC) from out-of-scope,
  TCC-gated system `CGEventPost` (`:478-493`). It also names the approved
  `da5eb70` S3a dependency and fixes the stale pin/crash label.

The remaining exact-revision **BLOCKER** is at `:402-409,425-426,656-662`:
the plan says unsupported config flags return `int<0 + out_err`, but
`zb_app_set_hw_policy` and `zb_app_set_media_source` return `void`, their
getters return bare `int`, and `--renderer` has no C setter. That mechanism
cannot execute. Agent Mail 5501 sent the concrete correction to JadeBeacon.

**Explicit verdict for `c8b646a`: BLOCKED (docs), although it closes the
config-ABI blocker above.** Rev 5 correctly introduces a fallible app-level
`applyMacBackendFlag(flag, value) !void` seam before any void setter, gives
`--renderer` an entirely Zig-owned decision, requires unsupported valid
flag/value pairs to make the real binary exit nonzero with an exact message,
and adds supported-effect, setter-not-reached and apply-before-validate/
swallowed-error tests (`macos-launch-tdd-plan.md@c8b646a:426-474,693-732`).

However, rev 5 also makes the load-bearing MS6 egress transport an explicitly
**unsettled open design item** (`:895-907`). The Linux-private
`127.0.0.1:3128` listener cannot be copied to a shared macOS loopback port,
and the bundled CLI has since been measured to reject Unix-socket proxy URL
forms (BlueBeaver mail 5503). An implementation-ready plan must pin the
remaining viable backend mapping before MS6:

1. host netd listens on an OS-selected, per-session `127.0.0.1:<port>` and the
   generated CLI/helper Seatbelt profile permits only that loopback endpoint;
2. `HTTPS_PROXY`/`HTTP_PROXY` name that exact port and netd retains the exact
   CONNECT/SNI allowlist; arbitrary host processes do not gain a meaningful
   capability because they already have host egress and the proxy grants only
   the same API allowlist;
3. each hook gets its separate profile permitting only loopback ports 51091
   and 31337, with no proxy endpoint or API path; and
4. the real-binary fake-API test proves the selected endpoint, both bridge
   positives, every denial in MS6.4, and that a hook cannot reach the proxy.

This should be expressed as a shared `SandboxBackend` capability (endpoint and
policy supplied by the backend): Linux implements it with private-netns fixed
ports and relays; macOS with an ephemeral host-loopback proxy plus per-process
Seatbelt port rules. Leaving “loopback alias vs Unix socket” open is no longer
valid after the CLI measurement ruled out the Unix-socket option.

### Gate and linear push-through answer

A bounded, fresh-cache clean export of exact `74413b0` under private Xvfb
passed **Build Summary: 106/106 steps succeeded; 817/817 tests passed**. It
included `9cf8fd2`; its 46 provisioning tests, including both new pinned-read
tests, passed. The EXIT trap deleted the export and cache. `c8b646a` is
docs-only after that identical source tree. No live browser, socket, profile,
token or DISPLAY `:0` was used.

The linear range through `3856558` is **not** an approved push-through range:
although `3856558` supersedes the blocked rev-16 network plans, the blocked
macOS rev 3 `a02f1ea` is still the newest macOS contract within that prefix.
The range through `74413b0` is also not approved because of its impossible
config error path. `c8b646a` fixes that path but remains blocked by its newly
explicit unresolved MS6 proxy mapping. Therefore the newest approved
push-through SHA remains the current origin, **`fa0aa48`**. No push or history
rewrite was performed.

## macOS launch plan rev 6 and S3n1 red boundary (`16c822e`)

**Explicit verdict for `16c822e`: APPROVED (docs).** Rev 6 closes the sole
open finding from `ed13e5e`. The shared `SandboxBackend` contract now owns both
the egress endpoint and its reachability policy: Linux supplies the fixed
private-netns endpoint, while macOS supplies an OS-selected per-session
`127.0.0.1:<port>` listener plus per-process Seatbelt rules
(`macos-launch-tdd-plan.md@16c822e:328-355`). On macOS, the generated
CLI/helper profile permits only that exact endpoint, `HTTPS_PROXY` and
`HTTP_PROXY` name it, and netd retains the exact CONNECT/SNI allowlist
(`:932-957`). Each hook has a separate profile that permits only loopback
ports 51091 and 31337, with no proxy endpoint and no API path.

MS6.4 is an executable hard gate rather than a prose-only promise. Its
real-binary fake-API test exercises the selected endpoint through the
production proxy, both bridge positives, direct-loopback/LAN/public-IP/DNS/
non-allowlisted negatives, and a hook's failed attempt to the actual ephemeral
proxy port. Removing the proxy or widening the hook profile must turn the test
red (`:959-978`). This matches BlueBeaver's measured constraint that the
bundled CLI needs a TCP proxy URL and closes the old “loopback alias versus
Unix socket” design fork. The prior config-ABI correction, two-arch gates,
Seatbelt-failure-to-VM rule, fd-3 token route, per-action approvals, native
drawer isolation and real-screen UI gates remain intact.

Implementation review should still verify the natural race-free reading of
“netd listens on an OS-selected port”: netd must bind port zero and retain that
listening socket before publishing the chosen port into the Seatbelt profile
and proxy environment, never discover a free port by closing and rebinding it.
That is an implementation check, not a remaining plan blocker; the plan makes
netd itself the listener and endpoint owner.

### S3n1 red commit and push-through boundary

`850f3da` is a valid failing-first, test-only commit, but it is **not an
approved push milestone**. In a clean export of exact `850f3da`, the named
black-box seam
`test_netd.SocketDirTest.test_the_layout_is_egress_and_bridges_with_exact_modes_and_a_ready_line`
failed in 0.012 s because `zb_agent_host.netd` does not exist. The complete
new test pair is deliberately not registered in `zig build test` until the
green commit: `build.zig` still names its Python unittest modules individually.
Consequently the ordinary gate cannot certify this slice yet.

A bounded clean export of exact HEAD `16c822e` under private Xvfb passed
**Build Summary: 106/106 steps succeeded; 817/817 tests passed**; its trap
deleted the export and cache. This establishes that the pre-existing suite is
unchanged, but it does not override the independently observed S3n1 red.

Because `850f3da` is the parent of `16c822e`, every linear push through rev 6
would include the incomplete red slice. It therefore **blocks the push until
the green S3n1 production commit lands, registers `test_netd` and
`test_relay` in the normal gate, and the resulting clean gate passes**. Rev 6
is architecturally approved, but there is no new contiguous approved
push-through SHA yet: the newest approved push-through remains **`fa0aa48`**.
No push or history rewrite was performed; no live browser, profile, token,
socket or DISPLAY `:0` was used.

## S3n1 red, harness corrections and green (`850f3da`, `fa7b804`, `9fb5a3c`)

### Exact verdicts

**Explicit verdict for `850f3da`: BLOCKED at that exact SHA, but valid as the
initial failing-first artifact.** Its 31 new command-line tests do fail because
the two production modules do not exist, so the red is genuine. The exact
commit nevertheless contains two harness errors: its process lookup also
matches bwrap's monitor/reaper, and its stdout-EOF deadline attributes bwrap's
own retained stdout descriptor to the relay. It also does not observe two
load-bearing mutations described below. The later `fa7b804` repairs the two
false assertions without erasing the original missing-module red.

**Explicit verdict for `fa7b804`: APPROVED as a narrow test correction.** The
exact diff changes only `test_relay.py`. Matching `/proc/<pid>/exe` plus the
exact argv prefix selects the Python relay rather than either bwrap process
(`agent/host/tests/test_relay.py@fa7b804:320-342`). Comparing EOF timing with
the same child under plain bwrap is the correct baseline, while the 1 MiB byte
round trip and relay-fd census remain independent checks (`:237-248,291-304`).
This commit closes the two harness errors in `850f3da`; it does not by itself
close the cumulative S3n1 findings below.

**Explicit verdict for `9fb5a3c`: BLOCKED.** Most of the production boundary
is sound: the socket hierarchy and modes, exact production host set lookup,
address vetting, SNI-before-connect rule, split egress/bridge authority,
private netd filesystem, fixed bridge targets, relay signal/status parity,
non-inheritance for hooks and the two gate registrations all match rev 16.2.
However, one production deadline violation and two mutation-surviving coverage
gaps prevent approval:

1. **BLOCKER — a stalled writer defeats the idle deadline.** `splice()` puts
   its sockets in blocking mode and calls unbounded `dst.sendall(data)`
   (`agent/host/zb_agent_host/netd.py@9fb5a3c:223-261`, especially `:249`). If
   a peer stops reading, execution never returns to the five-minute idle-clock
   check. Sixteen such tunnels permanently consume the semaphore and all later
   traffic receives 503. A direct socketpair reproduction used a 1 KiB send
   buffer and `idle=0.2`: the splice thread was still alive after 0.8 s and
   ended only when the non-reading peer was closed. BlueBeaver acknowledged
   this in mail 5528 and has a failing-first nonblocking/back-pressure fix in
   progress.
2. **BLOCKER-for-tests — exact-host matching is masked by DNS failure.** The
   production lookup is correctly exact (`netd.py:120`), but the lookalikes in
   `test_netd.py:325-348` have no resolution seam. Replacing the check with
   suffix matching still makes them end as 403 with zero connects after DNS
   fails. I independently applied that mutant in a clean export: **all 19
   netd tests passed**. The follow-up must resolve each lookalike to a global
   test address and prove both 403 and zero recorded attempts. BlueBeaver's
   mail 5525 reports that new test red on the mutant and green on the exact
   lookup; it is not committed yet.
3. **BLOCKER-for-tests — the outer-relay test never supplies numeric fd 3.**
   `test_relay.py:139-148` opens its Unix fake first and then opens an arbitrary
   canary descriptor. `pass_fds` preserves that descriptor's number; it does
   not make it fd 3. Consequently removing the special fd-3 preservation at
   `relay.py:227` is not observed, even though that mutation discards the only
   token route in production. A follow-up must give the relay a real,
   inheritable socket at numeric fd 3, prove the helper reads the same socket,
   prove the relay parent closes its copy, and retain the stray-fd and inner
   no-fd negatives. BlueBeaver's mail 5529 reports both relevant mutants red;
   that test is also not committed yet.

The accepted implementation deviation remains documented for the next plan
touch: netd waits for bwrap as its only child, rather than execing bwrap in
place, so the outer process can remove the emptied bind-mount directory. The
spawned PID remains netd's PID and bwrap uses `--die-with-parent`; the existing
ready-state death test passes. This does not close the three findings above.

### Exact gate and push-through boundary

A bounded, fresh-cache clean export of exact `9fb5a3c` under private Xvfb
passed **Build Summary: 108/108 steps succeeded; 817/817 tests passed**. The
new registered steps ran 19 netd tests and 12 relay tests. The EXIT trap
deleted the export and cache. The green gate proves integration stability but
does not override the reproduced deadline failure or the two surviving
mutations. The netd tests also emit repeated unclosed-pipe `ResourceWarning`s;
closing the `Popen` streams is a non-blocking test-hygiene SHOULD.

Therefore the linear range from `fa0aa48` through `9fb5a3c` is **not** an
approved push range. The newest approved push-through SHA remains
**`fa0aa48`** until follow-up commits close all three S3n1 blockers and are
reviewed. No push or history rewrite was performed; no live browser, profile,
token, socket or DISPLAY `:0` was used.

## S3n1 follow-ups (`9391611`, `971ede0`, `998062f`, `40ad263`)

### Exact verdicts

**Explicit verdict for `9391611`: APPROVED.** The new test removes the DNS
failure that masked an allowlist-suffix mutant. Five API and test-host
lookalikes are deliberately resolved to a global address in a sealed netd;
each must still receive 403, and both the recorded-connect list and fake
upstream must remain empty
(`agent/host/tests/test_netd.py@9391611:383-402`). If a mutant answers 200,
the test sends the matching ClientHello so the otherwise latent upstream
attempt becomes observable. BlueBeaver's recorded failing-first run saw two
200 responses and two attempts under the suffix mutant. This is the missing
production-chain negative from finding 5522, with no production change.

**Explicit verdict for `971ede0`: BLOCKED.** The nonblocking poll loop does
fix finding 5526: the new socketpair test proves a non-reading peer cannot hold
the splice beyond its idle deadline (`test_netd.py@971ede0:406-427`), the idle
clock advances only when a byte moves, and a checked ClientHello is queued
rather than written by a blocking `sendall`. However, its advertised 64 KiB
per-direction bound is false. A direction is eligible for `POLLIN` whenever
its destination queue is merely *below* 65,536 bytes, but the subsequent read
still asks for a full 65,536 bytes (`netd.py@971ede0:246-264`). After a partial
write left 65,535 bytes queued, a deterministic fake-socket/poll reproduction
made the next read grow that queue to **131,071 bytes**. The cumulative relay
has the same condition/read mismatch at
`agent/host/zb_agent_host/relay.py@971ede0:84-95`; BlueBeaver independently
measured a 126,592-byte peak in both implementations. Both need failing-first
buffer-bound tests and reads limited to the actual remaining room, including
an explicit greater-than-zero guard so `recv(0)` is never mistaken for EOF.

**Explicit verdict for `998062f`: APPROVED as the focused test follow-up.**
The test now installs the token socket at numeric fd 3, passes fd 3 plus an
unrelated descriptor through the real outer relay, and has the helper prove
the token bytes, socket inode and exact open-fd set `[3]`
(`agent/host/tests/test_relay.py@998062f:150-178`). It separately inspects the
running relay and proves the relay parent retained no copy of the token socket
(`:179-181`). BlueBeaver recorded both load-bearing mutants red: removing the
fd-3 exception prevents the helper report, while retaining the parent copy is
caught by the inode census. A non-blocking test-hygiene SHOULD remains: the
test process already owns daemon server threads when it uses `preexec_fn`; a
later cleanup should prefer a small exec wrapper or another route that avoids
Python's documented threaded-parent `preexec_fn` hazard. That does not weaken
the fd boundary this test observes. Approval of this focused diff does not
make its exact SHA releasable while its parent `971ede0` remains blocked.

**Explicit verdict for `40ad263`: BLOCKED.** Its shared `reap()` correctly
fixes the original netd-pipe warnings and the relay descriptor-census cleanup,
but the commit's “no ResourceWarning” claim is not true for its complete test
suite. The new fd-3 test still registers a kill-only cleanup
(`agent/host/tests/test_relay.py@40ad263:171-174`) and never waits for that
process. The exact full gate emitted
`ResourceWarning: subprocess <pid> is still running` at `subprocess.py:1140`.
The process was gone after cleanup, so this is a wait/reap defect rather than
a surviving orphan, but it directly refutes this test-hygiene milestone.
BlueBeaver acknowledged the missed warning class and has changed all six
kill-only relay cleanups to the common reaper in the pending follow-up.

The 64 KiB finding is release-significant, not merely cosmetic. A producer can
make every pair consume almost twice the configured bound, so the explicit
memory/capacity contract used to size concurrent tunnels is not enforced.
Accordingly the later focused test approval cannot skip over `971ede0`, and
`40ad263` also requires its promised complete cleanup before the range is
approved.

### Exact gate and push-through boundary

My bounded clean export of exact `40ad263`, with a fresh cache under private
Xvfb, finished **Build Summary: 106/108 steps succeeded (1 failed); 817/817
tests passed**. The one failed system-test step was unrelated render-config
coverage: only the screenshot-default child reported
`WEBKIT_DMABUF_RENDERER_FORCE_SHM=<unset>`. A second fresh exact-`40ad263`
export running only `tests/e2e/render_config_test.py` passed all 18 checks,
including screenshot default observing the expected value `1` and producing a
PNG. Thus the rendering failure is recorded as an intermittent, non-reproduced
gate flake; these four commits do not touch rendering or application startup.
The exact full gate nevertheless supplied independent evidence for the
`40ad263` subprocess-reaping blocker above. Both disposable exports and caches
were deleted by their EXIT traps.

The newest approved linear push-through SHA from `fa0aa48` therefore remains
**`fa0aa48`**. `9391611` and the focused `998062f` diff are approved, but the
linear range cannot cross the blocked `971ede0`, and exact `40ad263` is also
blocked. No push or history rewrite was performed; no live browser, profile,
token, socket or DISPLAY `:0` was used.

## S3n1 bounded-buffer and reaping closures (`489dcd1`, `5f84a59`, `f82228c`)

### Exact verdicts

**Explicit verdict for `489dcd1`: APPROVED.** Netd now calculates the current
room in the destination queue and passes exactly that value to `recv`, guarded
by `room > 0` so a full queue cannot turn `recv(0)` into a false EOF
(`agent/host/zb_agent_host/netd.py@489dcd1:253-265`). This preserves the
nonblocking idle-deadline fix while making its 64 KiB per-direction claim
true. The failing-first test uses real socketpairs and a counting socket to
measure bytes read from one side but not yet written to the other. It forces
more than 64 KiB through a deliberately slow destination before requiring the
peak to stay at or below `SPLICE_BUFFER`
(`agent/host/tests/test_netd.py@489dcd1:446-492`). BlueBeaver recorded a
126,592-byte peak on `40ad263` and at most 65,536 after the fix. This closes
the netd half of the buffer-cap blocker in `8058f97`.

**Explicit verdict for `5f84a59`: APPROVED.** `Pair.handle` applies the same
current-room calculation and positive-room guard before reading
(`agent/host/zb_agent_host/relay.py@5f84a59:84-95`). `PairBufferTest` drives a
real production `Pair` and selector with a non-reading sink, proves that it
received more than one buffer's worth, and measures the outstanding peak
against `BUFFER_MAX` (`agent/host/tests/test_relay.py@5f84a59:342-368`). The
same test was red at 126,592 bytes before the fix and green at no more than
65,536 afterward. Because both directions use the same peer-indexed code, the
one-way slow-reader drive exercises the condition shared by either direction.
This closes the relay half of the buffer-cap blocker.

**Explicit verdict for `f82228c`: APPROVED.** Every remaining process created
with `Popen` by `test_relay.py` now registers the shared `reap` cleanup: the
fd-3 boundary test, outer relay signal test, common bwrap-termination helper,
inner relay signal test and both no-orphan loop instances
(`agent/host/tests/test_relay.py@f82228c:170-206,283-320`). The descriptor
census already used the same cleanup, and `eof_after` explicitly closes its
pipe and waits. Thus each started process is waited and every owned pipe is
closed, including when an assertion aborts a test. The exact full gate emitted
no `ResourceWarning`, closing the cleanup blocker from `8058f97`. The separate
non-blocking SHOULD about Python `preexec_fn` in the fd-3 test remains deferred
as previously agreed; it does not invalidate this reaping closure.

### Gate and push-through boundary

A bounded independent clean export of exact `f82228c`, with a fresh cache
under private Xvfb, passed **Build Summary: 108/108 steps succeeded; 817/817
tests passed**. The registered S3n1 steps ran `test_netd` **22/22** and
`test_relay` **14/14**, with no `ResourceWarning` in the output. The EXIT trap
deleted the export and cache immediately afterward.

The three findings that blocked `9fb5a3c` are now all closed by the reviewed
chain: exact-host mutation coverage by `9391611`, the idle-deadline fix plus
bounded netd splice by `971ede0`/`489dcd1`, and the real-fd-3 boundary by
`998062f`; `5f84a59` closes the sibling relay bound, while `f82228c` closes the
test-process cleanup blocker. Therefore the newest approved linear
push-through SHA from `fa0aa48` is **`f82228c`**. No push or history rewrite
was performed; no live browser, profile, token, socket or DISPLAY `:0` was
used.

## Render-config probe race (`49e1420`)

**Explicit verdict for `49e1420`: APPROVED. Root cause PROVEN, not merely made
less likely.** The failure recorded in `8058f97` was in the test probe, not the
browser's startup configuration. The old probe returned the first descendant
whose `/proc/<pid>/comm` matched `WebKitWebProces`, even when that process's
`/proc/<pid>/environ` was temporarily zero bytes during exec or exit. It
therefore converted a transient empty read into `{}` and reported the expected
`WEBKIT_DMABUF_RENDERER_FORCE_SHM=1` as `<unset>`. The fix treats only a
zero-byte environment as “not ready” and keeps walking/polling; a non-empty
environment that legitimately lacks a queried variable remains observable
(`tests/e2e/render_config_test.py@49e1420:44-64`). This also prevents the two
opt-out cases from falsely passing on an empty read.

The new `half_started_reads` check is a causal failing-first reproducer, not a
sleep or enlarged timeout. It repeatedly execs a stand-in named
`WebKitWebProcess` with `ZB_PROBE=1`, polls the production probe without a
pause, and requires zero returned environments missing that variable plus at
least one complete observation (`render_config_test.py@49e1420:67-88,175-178`).
I independently ran five trials against each behavior in a clean exact-
`49e1420` export. With the fixed probe the results were **0 missing** and
16,886–17,435 complete reads per trial. Replacing only `web_process_env` with
the exact pre-fix implementation made every trial red, with **17–21 empty/
missing reads** while still observing 16,684–17,269 complete environments.
That isolates the changed predicate as the cause of the failure mechanism.

BlackRobin's real-binary evidence closes the remaining applicability gap:
under private Xvfb, the old probe reported `<unset>` in 10/20 screenshot-
default runs, while the fixed probe reported `1` in 20/20; separate first-
sighting instrumentation saw an empty environment in 7/20 runs and every
non-empty observation had `SHM=1`. Thus the app's pre-WebKit `setenv` was not
lost. A clean-export full gate of the final test blob passed **Build Summary:
108/108 steps succeeded; 817/817 tests passed**. No production file changed.
No live browser, profile, socket or DISPLAY `:0` was used, and all throwaway
reproducer exports were deleted.

## S3n2 hook-network slice (`1331a4d`, `063a1ce`, `3b217b2`)

### Exact verdicts

**Explicit verdict for `1331a4d`: BLOCKED at that exact SHA, but valid as the
failing-first artifact for this network sub-slice.** The new chain is not a
mock of the decision boundary: it provisions the real runtime, starts the real
S3n1 netd against private decoys, enters the real outer
`sandbox.helper_argv`, runs the real outer relay, and invokes the hook through
the installed `zb-hook-run` exactly as the CLI does
(`agent/host/tests/test_hook_net.py@1331a4d:62-101`). The probe exchanges a
nonce with both 51091 and 31337, attempts raw CONNECT and TLS through 3128,
attempts the Unix egress socket, recursively censuses `proxy.sock`, attempts
DNS and a public IP, and records environment names and its network namespace
(`tests/fixtures/agent/hook_net_probe.py@1331a4d:34-150`). The shared verdict
requires both bridge replies and both decoys' exact received bytes, no 3128,
ENOENT plus no view-visible `proxy.sock`, no DNS/public IP, no fake-API
connection and no upper- or lower-case proxy environment name
(`tests/e2e/agent_hook_net.py@1331a4d:102-130`).

The original targeted run was genuinely red: three errors because
`helper_argv` had no `net_dir` seam and one failure because the inner relay was
not installed. That is coarse API/provisioning red rather than guard-by-guard
red, but the tests are load-bearing: BlackRobin re-ran two one-line mutants on
the committed green chain. Removing nested `--unshare-net` exposed 3128 and
raised the fake API count; binding all of `/run/zb-net` exposed
`egress/proxy.sock` and likewise reached the fake. Both made the reach test
red. The frozen unsealed runner is also a permanent non-vacuity control: it
must share the outer namespace and reach 3128/fake API
(`test_hook_net.py@1331a4d:121-129`). As with S3n1's red commit, however, the
module is deliberately not in the normal gate at this exact SHA, so this is
not by itself an approved push milestone.

**Explicit verdict for `063a1ce`: APPROVED as the focused outer-sandbox
change.** `helper_argv(..., net_dir=)` adds `--unshare-net` only when a netd
directory was supplied and, after the private `/run`, read-only binds exactly
its real, non-symlink `egress/` and `bridges/` directories at the two planned
paths (`agent/host/zb_agent_host/sandbox.py@063a1ce:34-48,84-94`). Missing,
non-directory or symlink sources fail closed with `SandboxError`; omitting
`net_dir` leaves the old argv byte-for-byte unchanged. This is the §3c.2
mount/namespace seam and gives the later outer relay only `proxy.sock` while
retaining the bridge sockets solely for nested hooks. BlueBeaver's clean gate
for this exact blob passed **108/108 steps and 817/817 tests**; the targeted
S3n2 chain progressed from three API errors to its intended production-side
red. Approval is limited to this inert optional seam: browser/netd startup and
the production call site are later S3n2 work, not claimed by this commit.

**Explicit verdict for `3b217b2`: BLOCKED.** The declared production network
portion is correct. `zb-hook-run` creates a distinct network namespace after
building a fresh proxy-free environment, replaces `/run`, binds back only
`/run/zb-net/bridges` read-only, then executes the hook behind the installed
standard-library bridge relay (`agent/host/zb_agent_host/hook_run.py@3b217b2:24-60`).
`provision_runtime` installs that relay from `relay.BRIDGE_RELAY_FILE` at mode
0555 and refuses proxy names in the hook allowlist
(`agent/host/zb_agent_host/provision.py@3b217b2:15-25,48-59`). The registered
reach test passed in the full gate, and BlackRobin's two committed-chain
mutations prove that both the namespace and the bridges-only mount are
necessary. This satisfies the network-only part of §3c.8b: both bridge
positives, both `fake.zb.invalid` negatives, zero fake-upstream attempts,
ENOENT and a whole-view absence for `proxy.sock`, and no proxy environment.

The blocker is a deterministic clean-export placement dependency introduced
while migrating P0.4 to sealed hooks. Its minimal prefix performs
`--dev-bind / / --tmpfs /run` and binds only the bridge directory
(`agent/host/tests/test_contract.py@3b217b2:161-172`). When the clean export
is itself under `/run/user/1000`, that tmpfs hides both the checkout supplied
through `PYTHONPATH` and the test agent home. The cached interpreter remains
visible under `/home`, starts, and then exits with
`No module named zb_agent_host`. Consequently both
`test_r1_hooks_never_see_the_token` and `test_r3_hooks_never_see_the_token`
fail before exercising their contracts. This contradicts D12's explicit
requirement that the agent home may live under `/tmp` or `/run` and makes the
registered gate outcome depend on the throwaway root. The fix must remount the
required checkout and agent-home paths after the `/run` tmpfs (preferably by
using the production-shaped prefix) and add a regression whose checkout/home
actually live below `/run` or `/tmp`; merely moving the acceptance export is
not a fix. Mail 5559 assigned this to BlackRobin before the gate completed.

The other §3c.8b work that BlackRobin explicitly lists as subsequent S3n2
sub-slices remains open and is not approved by this verdict: hook seccomp,
status/stdio/signal/orphan/descriptor parity, R3 removal, the setup probe and
native browser spawn wiring. This review does not mislabel this network green
as completion of all S3n2.

### Per-hook cost and exact gate

The committed measurement is well formed: five warm-ups per arm, 40 samples
per arm, alternating arm order, the same `/bin/true` hook, paired deltas, and
nearest-rank p90/p95 (`test_hook_net.py@3b217b2:132-188`). Every sample must
exit zero, the sealed namespace must differ from the outer one, and the
unsealed namespace must equal it. There is deliberately no pass/fail budget.
BlackRobin reported these values from the registered gate:

| arm | n | median | p90 | p95 |
|---|---:|---:|---:|---:|
| sealed | 40 | 35.9 ms | 37.7 ms | 38.3 ms |
| unsealed | 40 | 19.7 ms | 20.5 ms | 20.8 ms |
| paired overhead | 40 | 16.0 ms | 18.2 ms | 18.3 ms |

A separate standalone run reported sealed 33.8/35.0/35.8 ms,
unsealed 18.3/19.6/20.4 ms and paired overhead 15.5/16.6/16.9 ms
(median/p90/p95), consistent with the plan's approximately 15 ms expectation.

My independent bounded clean export of exact `3b217b2`, under private Xvfb
with the export and fresh cache below `/run/user/1000`, finished
**Build Summary: 107/109 steps succeeded (1 failed); 817/817 tests passed**.
The only failed build step was `test_contract`, for the two import failures
above; the registered hook-network step and all Zig tests passed. The EXIT
trap deleted the export and cache immediately, and mail 5561 announced the
free gate slot with the exact summary.

Because `1331a4d` is an intentionally incomplete red milestone and its green
`3b217b2` is blocked by a registered clean-gate failure, the newest approved
linear push-through SHA from `1a425a7` remains **`1a425a7`**. The focused
`063a1ce` diff is approved, but it cannot be selected without crossing the
unclosed red milestone. No push or history rewrite was performed; no live
browser, profile, token, socket or DISPLAY `:0` was used.

## S3n2 `/run` clean-export closure (`365a463`)

**Explicit verdict for `365a463`: APPROVED.** It closes the sole blocker on
`3b217b2`. P0.4's test-only outer prefix still starts with the historical host
view, overlays a private `/run`, restores the real top-level `/run` entries,
then adds the test bridge directory (`agent/host/tests/test_contract.py@365a463:53-61`).
A checkout and test home below `/run/user/<uid>` consequently remain visible
to the helper, while `/run/zb-net/bridges` exists for the real nested
`zb-hook-run`.

The regression is causal rather than a larger timeout or changed assertion.
It creates both a copied `zb_agent_host` checkout and an agent home below
`/run/user/<uid>`, enters the same prefix, imports from that checkout, reads
the home's marker and lists the bridge mount
(`test_contract.py@365a463:217-238`). I independently ran it in a clean exact-
`365a463` export: it passed. Replacing only `hook_view_prefix` with
`3b217b2`'s old prefix made the same test fail immediately with
`ModuleNotFoundError: No module named 'zb_agent_host'`. This reproduces the two
P0.4 failures from my earlier full gate at their actual cause.

I initially flagged the restore of every top-level `/run` entry because it is
broader than the exact checkout/home paths required by this regression. On
the full execution trace, that is not a release blocker:

- P0.4 deliberately runs the helper and CLI in their pre-S3 host-view
  contract; before the new prefix they already saw the host's `/run` directly.
  This commit restores that baseline so the test can add the otherwise
  uncreatable `/run/zb-net/bridges` mount. It is not the production D12
  sandbox; P0.5 separately drives that exact prefix.
- The hook does **not** inherit this restored `/run`. The production
  `zb-hook-run` starts its nested bwrap, overlays its own private `/run`, and
  binds back only `/run/zb-net/bridges`. The registered S3n2 probe still proves
  `egress/proxy.sock` is ENOENT and absent from the hook's whole view.
- The diff is test-only and makes no production path broader.

An exact-path P0.4 remount would still be a worthwhile non-blocking
test-hygiene improvement: it would keep unrelated user-session runtime sockets
out of the helper/CLI's test view. No current test connects to such a socket,
and this is not a capability newly granted to P0.4 by the S3n2 production
change.

My independent bounded full gate used a clean exact-`365a463` export and
fresh cache below `/run/user/1000`, under private Xvfb. It passed
**Build Summary: 109/109 steps succeeded; 817/817 tests passed**. The repaired
contract module passed 24/24 and the S3n2 hook-network module passed 4/4. This
run measured sealed hooks at 34.7/36.8/37.1 ms, unsealed at
18.7/19.5/20.2 ms, and paired overhead at 15.9/16.9/18.2 ms
(median/p90/p95, n=40 per arm, five warm-ups). The EXIT trap deleted the
export and cache.

Therefore `365a463` cumulatively closes the path-dependent gate blocker on
`3b217b2`; the red `1331a4d`, focused `063a1ce`, green `3b217b2` and this
follow-up form an approved linear network-slice chain. The newest approved
push-through SHA from `1a425a7` is **`365a463`**. The later S3n2 work already
listed in the prior review (hook filter and lifecycle parity, R3 removal,
setup probe and native spawn wiring) remains future work and is not implied
complete by this approval. No push or history rewrite was performed; no live
browser, profile, token, socket or DISPLAY `:0` was used.

## P0.4 exact `/run` remount cleanup (`1e17ef4`)

**Explicit verdict for `1e17ef4`: APPROVED.** This test-only follow-up closes
the non-blocking hygiene note from the `365a463` review. P0.4 still overlays a
private `/run`, but now binds back only each requested keep path that actually
lies below `/run`, before mounting the test bridges read-only
(`agent/host/tests/test_contract.py@1e17ef4:53-63`). The production-shaped
call supplies exactly the resolved helper checkout and this test's agent-home
root (`test_contract.py@1e17ef4:181-185`); paths outside `/run` need no extra
mount because the initial host bind already exposes them. The change neither
alters production code nor broadens a hook's nested bridges-only namespace.

The strengthened regression creates the checkout and agent home under one
`/run/user/<uid>` subtree, a canary in a separate sibling subtree, and proves
all four required observations in one invocation: the host package imports,
the home marker is readable, the bridge mount is present, and the sibling is
absent (`test_contract.py@1e17ef4:220-248`). I independently exercised the
test at exact `1e17ef4`: it passed. Replacing only the helper with `365a463`'s
broad top-level `/run` restoration made the same test fail with
`sibling-seen`; replacing it with `3b217b2`'s prefix made it fail with
`ModuleNotFoundError: No module named 'zb_agent_host'`. The test therefore
kills both the overbroad intermediate implementation and the original
path-dependent failure, rather than merely asserting the new argv text.

My independent bounded full gate used a clean archive of exact `1e17ef4`, an
export and fresh cache below `/run/user/1000`, and private Xvfb. It passed
**Build Summary: 109/109 steps succeeded; 817/817 tests passed**. The gate's
P0.4 regression passed in the 24/24 contract module, and its S3n2 measurement
reported sealed hooks at 34.0/35.8/37.6 ms, unsealed hooks at
18.4/19.5/20.6 ms, and paired overhead at 15.6/16.9/17.0 ms
(median/p90/p95, n=40 per arm, five warm-ups). The EXIT trap deleted the
throwaway export and cache immediately.

The newest approved linear push-through SHA is therefore **`1e17ef4`**. This
approval is intentionally limited to the P0.4 cleanup and the previously
approved S3n2 network chain; hook filter/lifecycle parity, R3 removal, the
setup probe and native spawn wiring remain later slices. No push or history
rewrite was performed; no live browser, profile, socket or DISPLAY `:0` was
used.

## S3n2 native netd spawn (`c3e0152`, `e96c607`)

### Exact verdicts

**Explicit verdict for `c3e0152`: BLOCKED at this exact SHA, while retaining
valid initial red evidence.** The pure contract tests cannot compile on its
parent because `src/agent_net.zig` does not yet exist, and BlueBeaver's
recorded real-binary run on `1e17ef4` produced 28 failures: no netd, no
`AGENTNET` lifecycle and no failure bubbles. The tests that are present are
well targeted, but the red slice omits two rev-16.2 requirements described
below. It is therefore a genuine but incomplete failing-first artifact, not
an approved test boundary.

**Explicit verdict for `e96c607`: BLOCKED for tests; no production-code
blocker found.** The implementation itself matches the reviewed S3n2 native
spawn boundary:

- `configureAgentNet` runs only with the drawer, recognizes a provisioned
  `current`, uses OS entropy for the per-browser directory, gates both test
  seams on `--e2e-protocol`, builds netd's argv/environment and configures the
  C owner before any Send (`src/app.zig@e96c607:112-159,179-190`). The direct
  `python -I -S .../netd.py` form is the already accepted S3n1 deviation from
  the plan's `-m` spelling: the file is standard-library-only and needs no
  ambient import path.
- The first Send crosses one process-global state machine. It spawns through
  `die_with_browser`, keeps CLOEXEC stdin/stdout pipes, accepts only the exact
  `netd ready` line, enforces the five-second pre-ready limit, reports exit
  status, never restarts after a failure, and exposes the directory only in
  `READY` (`src/agent_host.c@e96c607:78-258`). Normal quit removes the child
  watch, closes stdin for netd's fd-relative cleanup, waits two seconds and
  finally kills/reaps if necessary (`:260-285`).
- The drawer owns no second network process. A synchronous refusal or later
  child exit reaches the existing system-message path, and the global drawer
  list avoids dereferencing a detached window
  (`src/agent_drawer.c@e96c607:575-608,1029-1057`). A second Send cannot start
  another netd.
- The real-binary test pins no setup/no start, lazy start, exact argv and
  allowlisted environment, the 0700 split socket tree, malformed seam/CA and
  runtime-dir refusals, exit 2, SIGKILL, five-second readiness timeout, no
  restart, and clean normal shutdown
  (`tests/e2e/agent_netd_spawn_test.py@e96c607:143-318`). The Zig table pins
  the directory length, strict seam grammar, fixed argv/environment and
  no-follow CA check (`tests/agent_net_test.zig@c3e0152:10-128`).

Two mutation-surviving gaps block the exact green commit:

1. **BLOCKER-for-tests — the app-owned seams are never proved inert without
   `--e2e-protocol`.** Every case uses `launch()` at
   `agent_netd_spawn_test.py@e96c607:138-140`, whose `Browser` default enables
   the flag. Deleting the `if (e2e)` condition at `app.zig@e96c607:142` leaves
   all committed tests green, contrary to §3c.4 (`plan:897-903`). A
   real-binary no-flag case must supply hostile values for both environment
   seams and prove production argv, no refusal/effect and no protocol row.
2. **BLOCKER-for-tests — browser death is not driven before or after netd
   readiness.** The e2e performs clean `b.stop()` and separately kills netd,
   but never kills the browser. Replacing `die_with_browser, &setup` with
   `NULL, NULL` at `agent_host.c@e96c607:241-242` therefore survives. Rev 16.2
   explicitly requires both browser-kill cases and no surviving process tree
   (`plan:827-852,1017-1030`). The test must signal only the browser PID and
   observe the tree gone before xsession's eight-second guardian grace, so
   process-group cleanup cannot satisfy it.

BlueBeaver accepted both findings in mail 5586 and reported test-only cases
that kill the two mutants; their follow-up was not committed at this review
cut. A separate non-blocking SHOULD (mail 5589) asks that the shared-netd
claim be exercised from two drawers: one process total and exactly one failure
bubble in each waiting drawer. The committed single-window cases do not pin
that otherwise-correct global-list path.

### Gate, visible failure state and push-through boundary

My independent clean archive of exact `e96c607`, with the helper runtime
prepared first, a fresh cache below `/run/user/1000`, and private Xvfb, passed
**Build Summary: 112/112 steps succeeded; 825/825 tests passed**. The new Zig
module passed 8/8 and the native-spawn e2e passed 44/44. The EXIT trap deleted
the export and cache. This green integration result does not cover the two
surviving mutations above.

The failure report **does draw new user-visible content**: it adds a system
message bubble reading `Agent network unavailable` through the existing
message-list renderer (`agent_drawer.c@e96c607:575-603`). It adds no new GTK
widget type, overlay, geometry or styling, but the new state is only asserted
through protocol rows under Xvfb, not by a real-screen pixel check. Under the
orchestrator's rule, schedule a real-screen check with the user after the test
blockers close.

Because both commits are blocked at this review cut, the newest approved
linear push-through SHA from `828a309` remains **`828a309`**. No push or
history rewrite was performed; no live browser, profile, socket or DISPLAY
`:0` was used.

## S3n2 native-spawn test closure and hook hardening (`f302c01`, `9ae1b5b`, `c8f058f`)

### Explicit verdicts

**Explicit verdict for `f302c01`: APPROVED.** This test-only follow-up closes
both blockers and the SHOULD from the `e96c607` review. Its no-flag case gives
both app-owned network seams hostile values, drives Send through real X input,
and proves the production netd argv, no refusal and no `AGENTNET` protocol row
(`tests/e2e/agent_netd_spawn_test.py@f302c01:343-387`). Removing either
`--e2e-protocol` guard is therefore observable. Its two browser-death cases
SIGKILL only the browser while netd is respectively still starting and fully
ready, snapshot the relevant PID or complete launcher/bwrap/server tree, and
require every process gone within two seconds—before xsession's eight-second
guardian can hide a missing parent-death link (`:390-427`). The two-drawer
case proves one process and one start globally, exactly one failure bubble in
each waiting drawer, and a later Send adding a bubble only to its own drawer
(`:430-455`). No production or UI code changes in this commit.

**Explicit verdict for `9ae1b5b`: APPROVED.** The production hook runner now
honours the required close/filter ordering: it validates and builds the fresh
environment, closes every inherited fd at or above 3, creates one inheritable
filter memfd at fd 10 or higher, and passes only that fd to nested bwrap's
`--seccomp` before `--` (`agent/host/zb_agent_host/hook_run.py@9ae1b5b:88-101,104-145`).
The x86-64 classic-BPF program kills a foreign ABI, refuses x32, denies the
complete §3c.6 namespace/mount/io_uring set, returns ENOSYS for `clone3`, and
denies legacy `clone` only when a `CLONE_NEW*` bit is present, leaving ordinary
forks, subprocesses and threads usable (`:40-85`). Because bwrap installs the
filter only after creating its namespace and mounts, the filter constrains the
relay and hook rather than preventing construction of the sandbox.

The tests cross the production chain through the real outer sandbox, nested
bwrap, inner relay and hook. They exercise live syscall denials and allowed
fork/subprocess/thread/Bun behavior; census both the hook PID namespace and
the exec boundary so neither the caller's canary descriptors nor the filter
memfd survive; compare sealed and frozen-unsealed exit statuses; pass 1 MiB in
both stdio directions and check prompt EOF; forward SIGTERM to a trap; pin the
relay's descriptor classes; and prove no orphan after hook exit, relay death,
nested-bwrap TERM or browser death
(`agent/host/tests/test_hook_net.py@9ae1b5b:193-337,339-432`). BlackRobin's
recorded mutants fail when `--seccomp` or `--unshare-pid` is removed, the
filter is created before close-all, an inherited fd is exempted, or relay
status/signal/stdio behavior is changed. The registered paired measurement
(five warm-ups, 40 samples per arm) was: sealed 34.5/36.4/37.0 ms,
unsealed 18.4/19.5/19.9 ms and paired overhead 16.2/17.7/17.7 ms
(median/p90/p95). This satisfies the measurement contract without turning its
approximately-15-ms expectation into a budget.

**Explicit verdict for `c8f058f`: APPROVED.** The environment route is gone
from the production contract, setup, token helper and native setup argv.
Setup has one outcome: a successful real R1 descriptor probe writes an R1
record; otherwise it refuses without publishing
(`agent/host/zb_agent_host/setup.py@c8f058f:646-706`). The native parser maps
every `--agent-setup --agent-token-route` spelling—including a missing value
and mixed option order—to a dedicated refusal, and `main` writes one stable
diagnostic and exits 2 before setup can mutate the agent home
(`src/cli.zig@c8f058f:38-48,130,485-495`; `src/main.zig@c8f058f:44-47`). Unit,
contract and real-binary setup tests cover successful R1, a failed descriptor
probe, absence of `RISK_LINE`/`r3_env`/`--route`, and the removed flag's
exit-2/no-write behavior. An exact-tree search finds no production R3 branch.

Rev 16 also requires a legacy `token-route.json` containing `"route":"R3"`
to refuse. There is no production consumer of that record at this SHA—setup
is its sole writer—so adding a test-only reader here would bypass the path the
requirement is intended to protect. This is an explicit S3b carry-forward:
the first production reader used by Send/chat must reject the legacy value
with a failing-first test. It does not block removal of every currently
reachable R3 route in `c8f058f`. The §3c.7 sandboxed setup probe remains the
last unimplemented S3n2 slice and is likewise not implied complete by this
approval.

### Independent clean gate and push-through boundary

My bounded full gate used a clean archive of exact `c8f058f`, a fresh cache
below `/run/user/1000`, and private Xvfb. It passed **Build Summary: 112/112
steps succeeded; 826/826 tests passed**. The native-spawn suite reported
63 checks with zero failures; the hook-network module passed 18/18, including
filter and lifecycle parity; the complete setup e2e reported 83 checks with
zero failures. The EXIT trap deleted the export and cache immediately, and a
post-gate process/path census found neither a matching process nor a leftover
tree. Mail 5599 released the gate slot with the exact summary.

Accordingly the newest approved linear push-through SHA from `828a309` is
**`c8f058f`**: `f302c01`, `9ae1b5b` and `c8f058f` are all explicitly approved.
The visible `Agent network unavailable` bubble was introduced by the earlier
`e96c607` production commit; `f302c01` adds only tests and therefore draws
nothing new. The previously requested real-screen observation of that state
remains applicable to the production UI chain. No push or history rewrite was
performed; no live browser, profile, socket or DISPLAY `:0` was used.

## S3n2 setup-execution sandbox and slice closure (`b765f64`)

**Explicit verdict for `b765f64`: APPROVED.** Both setup-owned executions now
cross one production sandbox builder. `setup_sandbox` constructs fresh network,
PID, IPC and UTS namespaces with the existing parent-death chain, an explicit
`/usr` plus the small `/etc` set, only the run's controlled read-only paths,
private `/tmp` and `/run`, and a fresh throwaway home; it never uses the former
`--dev-bind / /` host view
(`agent/host/zb_agent_host/setup.py@b765f64:677-711`). `cli_version` runs there
without any network path. `probe_r1` puts the probe server, SDK, R1 wrapper and
bundled CLI inside one such namespace, so their plain-HTTP loopback exchange is
namespace-local and involves no netd, relay, proxy, TLS override or host route
(`setup.py@b765f64:714-733`; `route_probe.py@b765f64:62-156`). The probe still
requires the real bearer over FIFO → wrapper → socket fd 3 and a live CLI
environment census that finds no token.

The tests do not stop at argv inspection. Production functions run an
attacker CLI against host-loopback and host-LAN listeners plus home/repository
canaries, while the R1 arm continues through the real wrapper and real CLI
(`agent/host/tests/test_provision.py@b765f64:110-170`). The real binary's
`sealed` case proves a normal, unflagged setup still publishes R1 and samples
each CLI in a non-host network namespace without a view of the user's home; a
second run observes zero loopback/LAN connections and zero canary accesses.
A disposable parent network namespace hosts the literal abstract
`@/tmp/.X11-unix/X0` decoy, and inability to construct that test namespace is
a failure rather than a skip (`tests/e2e/agent_setup_test.py@b765f64:335-412`).
The adjusted descendant test observes the actual CLI and its child through
`/proc` and still requires both gone within two seconds of browser death. The
recorded old-host-view bypass mutant makes three unit assertions and four
real-binary checks red, including both decoy classes, the canary and X0.

One non-blocking plan-consistency edit remains: §3c.7 spells the probe command
as `<venv python> -I -m zb_agent_host`, while the built package is deliberately
copied beside—not installed into—the venv. Production therefore uses a wholly
constructed environment with a single read-only `PYTHONPATH` and
`python -m zb_agent_host` (`setup.py@b765f64:725-728`). No caller-provided
Python variable, user site, user home or writable module path survives, so the
security boundary is equivalent; the next plan wording revision should record
the as-built invocation instead of the unusable `-I` spelling. This is a docs
SHOULD, not a code or slice blocker.

My independent bounded gate used a clean archive of exact `b765f64`, a fresh
cache below `/run/user/1000`, and private Xvfb. It passed **Build Summary:
112/112 steps succeeded; 826/826 tests passed**. The EXIT trap deleted the
export and cache immediately; a post-gate path/process census found no matching
tree or process. Mail 5604 released the gate slot with the exact summary.

**S3n2 closure: COMPLETE against the implementable rev-16.2 slice; S4 and MS0
may start.** The approved chain now covers the outer private network and exact
netd/relay socket boundary; per-hook bridges-only namespace, seccomp and
lifecycle parity; native lazy spawn and browser-death behavior; R1-only token
route; and setup's two isolated executions. The legacy `{"route":"R3"}`
record refusal remains deliberately attached to S3b's first production record
reader, where it can be tested without inventing a test-only consumer. The
separate §3c.2 prose correction noted by BlackRobin is documentation cleanup,
not missing runtime behavior.

The newest approved linear push-through SHA from `828a309` is **`b765f64`**.
No push or history rewrite was performed; I did not use the live browser,
profile, socket or DISPLAY `:0`.

### NVIDIA real-screen check for `e96c607`'s visible failure state

**Status: CLOSED by the user's 2026-10-15 observation on clean `c8f058f`.**
On the user's NVIDIA X11 screen, with a throwaway profile and agent home and
media source off, opening the drawer, typing and pressing Enter rendered the
system message `Agent network unavailable` correctly and showed no other
visual problem. The protocol evidence matched it exactly:
`AGENTNET unavailable refused` and
`DRAWER 1 msg system "Agent network unavailable"`. The orchestrator deleted
the throwaway directory. This is user/orchestrator-supplied real-screen
evidence; RoseCat did not connect to DISPLAY `:0` or the live socket.

## Plan rev 16.5 and S4a Secrets review (`a0a0b56`, `cf4c612`, `d47ae67`)

**Explicit verdict for `a0a0b56`: APPROVED.** Rev 16.5 resolves rev 16.4's
contradictions: the browser-to-launcher bootstrap environment is distinct from
the helper's exact final environment; current token ownership belongs to S4a;
and `TEST_PROXY` is removed while the test endpoint remains exactly
`https://fake.zb.invalid`.

**Explicit verdict for `cf4c612`: APPROVED as the red commit.** It records
real pre-green failures (the absent production module plus 9 of 14 E2E checks)
and does not register the new suite in the normal gate before production is
present.

**Explicit verdict for `d47ae67`: BLOCKED.** Four correctness findings remain:

1. **BLOCKER — explicit file fallback does not select the file backend.**
   `on_save_to_file` writes and wipes the pending token but leaves
   `secrets.config.store` set to Secret Service
   (`src/agent_secrets_window.c@d47ae67:85,217-225`). The next Send therefore
   passes Secret Service to `zb_agent_token_fetch`
   (`src/agent_drawer.c@d47ae67:628-629`) and ignores the file the user just
   selected. An exact-commit private-Xvfb reproduction clicked the fallback,
   sent again, and observed `STATUSES_AFTER_SECOND_SEND=['no-keyring']` while
   `FILE_STILL_EXISTS=True`. The selection is also lost across restart unless
   the command line independently requested file mode, contrary to D11.
2. **BLOCKER — an obsolete async store completion can wipe a newer token.** A
   stale generation calls the global `wipe_pending()`
   (`src/agent_secrets_window.c@d47ae67:173-176`). Save A, close, reopen and
   Save B can therefore let A's late callback destroy B before B's explicit
   file fallback. Async requests need request-owned secret state or an epoch;
   stale callbacks must not mutate the current generation.
3. **BLOCKER — the opening lookup races later operations.**
   `show_current_state` starts its async lookup without making the UI busy or
   advancing an operation epoch (`src/agent_secrets_window.c@d47ae67:139-160`).
   A Save or Remove can finish first and then have its current state overwritten
   by the older lookup callback. A controlled delayed-callback regression is
   required.
4. **BLOCKER — file-mode Remove is not S4.1's clear-all operation.** Service
   mode clears the keyring and file (`src/agent_secrets_window.c@d47ae67:230-241`),
   but file mode removes only the file (`:251-258`). A stale keyring item can
   reappear after a backend switch, despite S4.1 saying Remove deletes the item
   and the file. Clear both with defined partial-failure behavior, or amend the
   contract explicitly.

The reviewed privacy seams otherwise hold. The E2E launches either a private
D-Bus plus private keyring and private `XDG_RUNTIME_DIR`, or a dead bus address
with a private runtime directory; pre-launch assertions reject the user's bus
and runtime. No committed test reaches the user's real keyring. Token canary
scanning covers stdout, stderr and every protocol row; production emits fixed
status/error strings, clears the password entry immediately, and wipes owned
token buffers. The exact-commit targeted checks passed under private Xvfb:
`test-agent-secrets` reported **6/6 steps and 15/15 tests**, the dynamic-loader
subsuite reported **5/5**, and the direct E2E reported **35 checks, 0 failed**.

This slice draws a native, non-WebView, non-resizable 460-pixel-wide window
titled `Claude Agent account`, with a masked token entry, Save and Remove
buttons, and a fixed status line. If Secret Service fails after Save, it adds
the unencrypted-file warning and `Save to a private file instead`. Send with no
token adds the drawer bubble `Add a Claude token in the window that opened`
and presents the native window. No drawer account/header button is present in
this slice yet.

The newest approved linear push-through SHA remains **`dc52885`**: `d47ae67`
is blocked, and the earlier interleaved S3b chain is not yet fully approved.
Mail 5648 sent the findings to BlueBeaver with BlackRobin copied. No push or
history rewrite was performed; no live browser, profile, socket or DISPLAY
`:0` was used.

### S4a follow-up (`db7dc12`, `0fca5d1`)

**Explicit verdict for `db7dc12`: APPROVED as red evidence.** Its unit and
private-Xvfb cases reproduce all four `d47ae67` failures: the fallback choice
does not govern the next Send/restart, an old store answer can consume newer
pending state, the opening lookup can overwrite a later result, and file-mode
Remove leaves the keyring item. The answer-delay seam acts only under
`--e2e-protocol` and delays the answer after the Secret Service operation, so
the stale-answer tests exercise the intended ordering. Process NIT: this red
commit added compilation-failing tests to an already registered step and made
the shared HEAD ungateable until its immediate green; BlueBeaver acknowledged
the error and will keep future red tests out of registered gates.

**Explicit verdict for `0fca5d1`: BLOCKED.** The four original findings are
fixed. `effectiveStore` gives the current session's explicit fallback choice
first priority, an explicit launch flag second, and an existing token file
third, so both the drawer and the window use the same persistent selection
(`src/agent_secrets.zig@0fca5d1:262-286`;
`src/agent_secrets_window.c@0fca5d1:116-119,257-266`). Every lookup, store and
clear begins an epoch and disables the action controls; stale lookup/store
answers make no state, row or token-lifetime change
(`src/agent_secrets_window.c@0fca5d1:161-200,214-225`). Remove attempts both
stores and implements the agreed unavailable-keyring exception when the file
store was active (`src/agent_secrets_window.c@0fca5d1:269-300`). The new
fallback-persistence, stale-store, delayed-lookup and clear-both cases drive
the real native window and production store path rather than bypassing them.

One new lifecycle blocker remains: `on_cleared` returns when its epoch is
stale before it calls `zb_secrets_remove_file`
(`src/agent_secrets_window.c@0fca5d1:275-280`), while closing the native window
increments the epoch (`:364-370`). If the user clicks Remove and closes the
window while Secret Service clear is in flight, the irreversible keyring
clear may complete but its callback skips the file deletion. The file token
then remains active on the next Send/restart. Remove's two resource effects
must finish exactly once independent of window lifetime; only widget, row and
status reporting may be epoch-guarded. Mail 5663 reported this, and BlueBeaver
accepted it in mail 5665 with a deterministic `clear=4000` `remove-close` red
case and an operation-owned fix prepared.

The independent bounded gate used a clean archive of exact `0fca5d1`, a fresh
cache below `/run/user/1000`, timeout 1500 and private Xvfb. It passed
**Build Summary: 122/122 steps succeeded; 852/852 tests passed**. The ten S4a
cases printed **57 checks, 0 failed**; the commit/mail's 58-check claim is a
bookkeeping mismatch only. The EXIT trap deleted the export/cache, and mail
5666 released the gate slot. No live browser, profile, socket or DISPLAY `:0`
was used.

**S4a remains NOT APPROVED**, so the Secrets-window real-screen check should
wait for the remove-close follow-up. The newest approved linear push-through
SHA remains **`dc52885`**, because `0fca5d1` is blocked and the earlier
interleaved S3b chain still awaits its follow-ups.

**Superseded:** the later `bc85c37`/`adbb8a0` review below closes this sole
S4a blocker and approves S4a.

## macOS MS0 SandboxBackend seam (`4fffdd8`, `7301c5d`)

**Explicit verdict for `4fffdd8`: BLOCKED-for-tests.** The commit is genuinely
red before production exists: an exact clean export ran all seven new tests and
failed all seven because `SandboxBackend`/`LinuxBwrapBackend` were absent.
However, its central behavior-preservation oracle cannot detect a wrong
refactor. `test_helper_launch_spec_equals_helper_argv` and its network variant
compare a fresh backend's `launch_spec` with `sandbox.helper_argv`
(`agent/host/tests/test_backend_contract.py@4fffdd8:95-120`), but after the green
the alleged oracle calls the same singleton backend method
(`agent/host/zb_agent_host/sandbox.py@7301c5d:183-197`). A clean-export mutant
that appended `--wrong-ms0-mutant` to every `LinuxBwrapBackend.launch_spec`
result therefore left **all 7/7 tests green**. The third “launch” test never
calls `launch.build_argv` or compares an argv; it checks only that the backend
has a method (`test_backend_contract.py@4fffdd8:122-131`). This does not meet
the rev-6 MS0 requirement for an independent, captured pre-refactor golden
over the argument variants. The follow-up needs a fixed pre-refactor oracle
and must drive the real `launch.build_argv` path.

**Explicit verdict for `7301c5d`: BLOCKED.** The extraction of the bwrap argv
builder itself is production-called and appears mechanically behavior-
preserving: `helper_argv` delegates to the singleton `LinuxBwrapBackend`, and
existing callers still receive a list (`sandbox.py@7301c5d:102-159,183-197`).
Three required parts of the rev-6 contract are nevertheless absent:

1. The backend's network capability is only a parallel description.
   `egress_endpoint`, `bridge_policy` and `hook_launch_spec`
   (`sandbox.py@7301c5d:161-180`) have no production callers. The running paths
   still hard-code the proxy in `options.py@7301c5d:21-23`, the egress mount in
   `launch.py@7301c5d:48`, and the hook bridges/network launcher in
   `hook_run.py@7301c5d:38,104-127`. A different backend-supplied endpoint or
   hook policy therefore changes no CLI/helper/hook environment or argv. This
   fails both macOS rev-6 lines 331-350 and drawer-plan §3c's separation of
   helper egress from bridge-only hooks. The tests must inject a changed
   backend capability through the real consumer paths and observe the exact
   production environment/argv; the current hook test does not inspect
   `hook_launch_spec` at all.
2. The required C/GLib spawn/lifetime seam was not implemented. Rev-6 MS0
   explicitly factors both Python policy/argv and C spawn/parent-death behind
   the semantic launch spec and names `launch.py` plus `src/agent_host.c`
   (macOS plan lines 318-376). The green changes only `sandbox.py`;
   `src/agent_host.c@7301c5d:41-75` remains a Linux-specific direct
   `g_spawn_sync`/`prctl(PR_SET_PDEATHSIG)` path with no parameterized backend
   seam or preservation test. Implement it, or revise and approve the plan
   before calling MS0 complete.
3. Consequently `LaunchSpec` contains only an argv tuple. It does not yet
   carry or govern the broader semantic launch contract the plan assigns to
   it: endpoint/policy consumption, per-hook realization, or spawn/lifetime.

The exact new unit was independently checked outside the gate: `4fffdd8`
reported **7 tests, 7 failures**; `7301c5d` reported **7 tests, 0 failures**.
The self-referential wrong-argv mutant also reported **7 tests, 0 failures**.
An independent pre/post comparison between exact `4fffdd8` and `7301c5d`
found identical `helper_argv` output for seven variants: default, seccomp fd,
extra read-only path, writable Claude tree, network binds, a state-directory
subset, and the combined seccomp/read-only/network case. This supports the
narrow argv-extraction claim even though the committed oracle does not guard
it.
All checks used clean exports with DISPLAY and WAYLAND_DISPLAY unset,
and each tree was deleted immediately.

The independent clean-export full gate at exact `00f5ec2`, with fresh caches
under private Xvfb `:106`, was **RED**:
`Build Summary: 124/126 steps succeeded (1 failed); 864/864 tests passed`.
The sole failed build step was the S3b lifecycle e2e described below, not MS0;
all compiled Zig tests passed. The tree was deleted immediately afterward.
These MS0 blockers are contract/test failures independent of that failure.
The newest approved linear push-through SHA remains **`dc52885`**.

## S3b helper lifecycle and native supervision (`00e1f93` through `00f5ec2`)

**Explicit verdict for `00e1f93`: BLOCKED-for-tests.** The red commit is
honest for the busy response, duplicate/failed opens, the SDK-session-id
schema and native validator lifecycle: its commit evidence identifies the
specific old-code failures, and part of the suite cannot compile before the
new validator API exists. But its three cancellation tests are explicitly
false-green on the old implementation. They release the held HTTP reply at
the same time as close and let the SDK's own disconnect stop its reader
(`agent/host/tests/test_chat.py@00e1f93:260-325`), so they do not prove that
the prompt task was cancelled **and awaited** before disconnect and
`session_ended`. A cancellation-resistant task/client must keep its cleanup
pending and make the test fail until close waits for that acknowledgement.

**Explicit verdict for `9740498`: BLOCKED-for-tests.** The implementation is
otherwise internally consistent: one `Session.task` enforces prompt
exclusivity; close cancels and gathers before disconnect; a failed open closes
its token route; `ResultMessage.session_id` supplies the real SDK id; and an
accepted `session_ended` removes the native validator session
(`chat.py@9740498:36-95,116-184`,
`src/agent_protocol.zig@9740498:49-108,127-188`). The missing red oracle above
means the most important ordering change remains unprotected.

**Explicit verdict for `20e7336`: BLOCKED-for-tests.** This is a substantial,
honest red slice: its reported pre-production run failed 10 of 14 lifecycle
checks and could not build the absent pure helper module. The closure e2e uses
the real browser, X input, setup, bwrap, helper, CLI, relay/netd and TLS fake
API; the bad-frame test uses the documented e2e-only helper seam and still
passes every frame through the production native validator. Its coverage is
nevertheless incomplete in three safety-critical places:

1. The `window-close` case waits for the popup reply and only checks that its
   CLI exits (`agent_host_lifecycle_test.py@20e7336:475-505`). It does not
   assert that a normal close emits no rejected-frame line or that repeated
   closes do not restart the healthy shared helper.
2. The restart case leaves no queued old stdout/stderr completion while the
   new helper starts, so it cannot catch a completion from the old generation
   parsing or scheduling a read against the new one.
3. No test exercises the D7 64-KiB redacted stderr-ring contract or proves a
   canary from helper stderr is absent from logs.

**Explicit verdict for `da93d83`: BLOCKED.** The new production chain is real,
not a test bypass: drawer Send routes through the native helper; first use
takes the owner lock, waits for netd and the token, writes fd 3 once, launches
the confined helper, validates its stdout in Zig, and maps accepted frames
back to the named drawer. The closure exercises that chain. Four issues must
be corrected before this green can be accepted:

1. **Normal close consumes its own acknowledgement as a protocol strike.**
   `zb_agent_helper_window_closed` writes `end_session` and immediately removes
   the session from the validator (`src/agent_helper.c@da93d83:613-624`). The
   helper's required `session_ended` then fails `knownSessions`, is logged as a
   rejection and increments the three-strikes restart counter
   (`:272-283`). Closing three ordinary session windows can therefore restart
   a healthy helper. Keep a closing/tombstone session until its terminal frame
   (and safely discard any UI output after detach); cover confirmed and
   not-yet-confirmed opens.
2. **Async reads cross process generations.** The stdout/stderr callbacks use
   global buffers and global current streams when rescheduling
   (`:288-331`). `forget_process` cancels the old reads (`:335-358`) and the
   rejection path immediately starts a new helper (`:361-377`). An already
   queued positive completion from the old stream can therefore parse a
   buffer reused by the new read and schedule a second concurrent read on the
   new stream. Each callback needs a generation-owned stream, buffer and
   cancellation identity; stale completions must neither parse nor reschedule.
3. **D7's stderr contract is not implemented.** The code says stderr is
   drained and kept nowhere (`:323-331`), while the plan requires a bounded
   64-KiB ring whose logged lines are redacted; the defined
   `ZB_STDERR_RING` is unused (`:55`). Implement/test that contract or amend
   and approve the plan to specify deliberate discard.
4. The cancel-before-disconnect ordering remains without a test that fails
   when its `await asyncio.gather(...)` is removed (the `9740498` finding).

Two lower-severity follow-ups are worth keeping visible. `write_frame`
performs a synchronous pipe write on the GTK main thread
(`agent_helper.c@da93d83:160-169`); a helper that stops consuming app frames
can freeze UI, so this needs a bounded/nonblocking design before arbitrary
tool-result traffic arrives. Also, a netd failure calls `go_down` after killing
the helper but does not clear each window's pending prompts (`:514-525`), so
those strings remain retained in an unrestartable unavailable state until the
window closes.

**Explicit verdict for `00f5ec2`: APPROVED (docs only).** Rev 16.6 accurately
records the measured Linux behavior: bwrap's `--chdir` contributes `PWD` with
the workspace value in addition to the built helper allowlist. This plan-only
correction does not waive the production/test blockers above.

Part 2 does draw new user-visible states. It changes the drawer's header from
the static “Not connected” label to Starting/Ready/Working/Stopped/Unavailable
and adds real assistant/error/system bubbles, including the crash bubble and
restart transition (`src/agent_drawer.c@da93d83:577-646,931-1003`). The earlier
real-screen check at `c8f058f` covered only the network-unavailable status and
bubble, not a real reply, crash bubble or restart. Once the blockers are fixed,
the part-2 UI therefore needs a throwaway-profile real-screen check with the
user.

The independent clean-export gate at exact `00f5ec2` was **RED**:
`Build Summary: 124/126 steps succeeded (1 failed); 864/864 tests passed`.
The lifecycle e2e's independent expected set omits `LC_ALL`
(`tests/e2e/agent_host_lifecycle_test.py@00f5ec2:35-36`), even though the plan
and production `HELPER_ENV_NAMES` include it. On this clean run the confined
helper correctly had `LC_ALL`, so the exact-set check at lines 343-345 emitted
the sole failing check. This is a deterministic test-oracle blocker; it was
mailed to BlackRobin as finding 5686. The apparently failed inner Zig commands
printed elsewhere in the log are expected mutation/negative-test subprocesses:
the final summary counted all **864/864** compiled tests green. The throwaway
tree was deleted immediately.

The S3b blockers do not change the linear result: **`dc52885` remains the
newest approved push-through SHA**, because the earlier interleaved MS0 red/
green chain is blocked as well.

## S4a Remove survives Secrets-window close (`bc85c37`, `adbb8a0`)

**Explicit verdict for `bc85c37`: APPROVED (red).** The added `remove-close`
case is an honest production-chain regression. It creates only a private
D-Bus daemon, private gnome-keyring, private runtime directory, throwaway
agent home/profile and Xvfb browser. Through real X input it first places one
canary in the private keyring and another in the selected file store, then
holds the keyring clear for four seconds, clicks Remove, sends the real
`WM_DELETE_WINDOW`, and waits past the held answer. Its three terminal
assertions prove that the file is already absent, the keyring worker finished,
and the stale answer emitted no UI/protocol row
(`tests/e2e/agent_secrets_test.py@bc85c37:748-782`). On `00f5ec2` plus this
test, the old implementation deterministically failed “the file is gone
although the window closed first” (**5 checks, 1 failed**). Leaving the case
out of the build's `--only` list in the red commit is acceptable because the
red was run explicitly and the green commit registers it in the normal gate.

**Explicit verdict for `adbb8a0`: APPROVED.** `on_remove` now deletes the
token file synchronously at the authorized Remove click, records that result,
and starts the asynchronous keyring clear; `on_cleared` only reports the
combined result if the original window/epoch is still current
(`src/agent_secrets_window.c@adbb8a0:273-307`). Closing the window invalidates
only the report callback. It cannot cancel the `GTask` worker, resurrect the
file, or expose a late row. `removed_file` is overwritten for every serialized
Remove operation, and `on_destroy` clears `busy`, so reopening cannot inherit
an in-flight UI lock. The author reports the exact regression **5/5 green**,
the inverse mutant (moving file deletion back behind the epoch check) red, and
a private-Xvfb clean-export gate **126/126 steps, 864/864 tests**.

This closes finding 5663. With the previously accepted functionality in
`cf4c612`, `d47ae67`, `db7dc12` and `0fca5d1`, **S4a is now APPROVED** and its
native Secrets window is ready for the orchestrator's throwaway-profile
real-screen check. The linear push-through SHA nevertheless remains
**`dc52885`**: the interleaved MS0 commit `4fffdd8` is still blocked before this
S4a follow-up in history.

## Real-screen S4a follow-up and selectable drawer text (2026-10-15)

**The S4a real-screen condition is NOT MET.** On the user's NVIDIA X11 screen,
a clean export of `adbb8a0` with a throwaway profile/home, dead D-Bus, explicit
file store and media source off did not reach the Secrets window. Send instead
showed “Agent runtime not set up: run zigBrowser --agent-setup”. This is not a
rendering verdict for the native window: the recipe's hand-made empty
`dist-1/current` tree no longer satisfies S3b's runtime validation, so the UI
under test was never created.

The runtime-before-token order itself matches the approved plan. S4.1 and
Closure Test S4 take a home provisioned by the real `--agent-setup` as their
source (`chat-drawer-tdd-plan.md:1890-1897,1928-1936`), while S3.2 requires a
missing runtime to produce `runtime-missing`. Production validates the runtime
when configuring the helper (`src/app.zig@adbb8a0:193-208`), and
`zb_agent_helper_send` returns that configured unavailability before its
lock/netd/token path (`src/agent_helper.c@adbb8a0:574-605`). The corrected
real-screen recipe must therefore provision a genuine throwaway agent home
offline and must be verified under private Xvfb on that exact build first.

**BLOCKER — S4a has no manual account path.** D1 and D11 say S4 adds an account
button to the drawer header and that this button opens Secrets independently
of Send (`chat-drawer-tdd-plan.md:223,529-534`). At `adbb8a0`, the header has
only title, status and minus (`src/agent_drawer.c@adbb8a0:922-938`); the sole
`zb_secrets_window_present` call is the automatic `no-token` status path
(`:588-600`). A user therefore cannot reach the Secrets window without Send,
and cannot repair credentials while the runtime check fails. Mail 5695 sent
this to BlueBeaver and BlackRobin. Required red: with an intentionally missing
runtime, a real X click on an accessible account button opens the native
Secrets window, while it remains absent from `page.list`, page worlds and the
automation socket. This finding supersedes the S4a approval immediately above:
**S4a is REOPENED / BLOCKED**, and its real-screen check must be rerun after
both the manual path and the recipe are fixed.

**NEW USER REQUIREMENT — every displayed drawer text is selectable and
copyable.** Every user, assistant, system and error message bubble, plus the
header status text, must support mouse selection and Ctrl+C. Merely making a
GTK label focusable, exposing text through an e2e row, or copying through a
test seam is insufficient.

BlackRobin owns the implementation. Its failing-first, real-binary test must
run under a private Xvfb and, for each of the four bubble roles plus status:

1. create the visible text through the production drawer/helper path;
2. use real X pointer input to select a distinctive substring in the rendered
   widget;
3. send real Ctrl+C; and
4. read the private display's clipboard and require exactly that selected
   substring (with a pre-seeded decoy proving the clipboard changed).

The test must not obtain the text from `DRAWER` rows, widget introspection or
an app-owned copy seam as its oracle. Existing scrolling, wrapping, click,
focus and page-isolation assertions remain. Because this changes the drawer's
native widgets and real pointer/keyboard interaction, it is a UI change under
§7.1: after private-Xvfb green, the user must confirm mouse selection and
Ctrl+C on the real screen before the requirement closes.

## S3b lifecycle follow-ups (`eed7742`, `d71ca7f`, `442386e`)

**Explicit verdict for `eed7742`: APPROVED (red), with one new red still
required for the green finding below.** The commit closes the specific test
gaps carried from `00e1f93` and `20e7336`:

- `CancelThenAwaitTest` uses the production `Session.close` with a task that
  remains suspended after receiving cancellation. Before its cleanup is
  released, it requires that disconnect, route close and `session_ended` have
  not happened; afterward it requires their exact order
  (`agent/host/tests/test_chat.py@eed7742:330-371`). In an exact clean export,
  the test passed in **0.204 s**; deleting only the production
  `await asyncio.gather(...)` made it fail with disconnect/route-close/
  session-ended preceding `cancelled`. This is the failing-first oracle
  missing from `9740498`.
- `window-close` now exercises one normal close and four repeats, including a
  close before `session_opened`; it requires zero protocol strikes, no helper
  restart and a still-working opener
  (`tests/e2e/agent_host_lifecycle_test.py@eed7742:487-531`).
- `frames` leaves 400 junk lines in the condemned helper's stdout, requires
  exactly three strikes and one restart, then requires one valid frame from
  the replacement. It also sends the token canary on stderr and requires it
  in no log/row (`:382-419`). This fails the old shared-buffer implementation
  with 403 strikes and covers the old-generation reader gap.
- The independent expected environment now includes `LC_ALL`, and the test
  sets both locale names, so finding 5686 no longer depends on the invoking
  shell (`:35-39,118-121`).

An exact-`442386e` disposable export, built and run under private Xvfb, passed
the focused production cases **24 checks, 0 failed** (`frames,window-close`).
The tree and caches were deleted immediately. BlackRobin's clean-export full
gate reports **126/126 steps succeeded; 864/864 tests passed**.

An independent clean export at exact `4e49a13` (code-identical to `442386e`;
the intervening change is this review document), under private Xvfb with a
fresh cache, was also GREEN: **Build Summary: 126/126 steps succeeded; 864/864
tests passed**. The disposable tree was deleted immediately.

**Explicit verdict for `d71ca7f`: BLOCKED.** The `ZbReader` ownership is
otherwise sound: each process/pipe owns its stream, cancellable, buffer and
partial line; one reference belongs to the process and one to the outstanding
read; stopping invalidates and cancels it, and a late callback can only release
that reader (`src/agent_helper.c@d71ca7f:74-87,300-381`). The third rejection
also stops stdout before remaining bytes can be parsed. Keeping a closed
window's validator session until the helper's `session_ended` is likewise the
right exactly-once direction and prevents ordinary closes from becoming
protocol strikes (`:644-657`).

One routing error remains. Once the `ZbWin` is removed, a valid
session-scoped `error` is accepted by the deliberately retained validator,
but `on_frame` unconditionally calls `zb_drawer_agent_message(win, ...)` with
`win == 0` (`src/agent_helper.c@d71ca7f:226-265`). Zero means broadcast to
every drawer (`src/agent_drawer.c@d71ca7f:603-610`). A prompt cleanup or SDK
failure after a popup closes can therefore put that closed popup's error into
the opener and every sibling. Mail 5699 sent the blocker. Required red: emit a
valid session-scoped error after removing the popup's `ZbWin`; it must produce
zero strikes, appear in no surviving drawer, accept the following
`session_ended`, and leave the opener usable. The error arm must draw only when
its named window still exists; a genuinely global error with null session may
remain broadcast. The stale `agent_frames.zig:54-56` comment saying app close
directly removes the validator session should also be corrected.

**Explicit verdict for `442386e`: APPROVED (docs only).** Rev 16.7 consistently
changes both D7 and D7b from a not-yet-built 64-KiB stderr ring to the actual
S3b contract: continuously drain and discard, retain nothing, and log nothing.
The lifecycle canary assertion guards the no-log property. A bounded redacted
diagnostic log is explicitly deferred to S5.7, where its redaction contract
and tests must land together.

**Closure of earlier findings.** The `9740498` cancel-then-await test blocker
is CLOSED by `eed7742` and the independently killed mutation above. All three
`20e7336` coverage gaps are CLOSED by `eed7742` plus the approved rev-16.7
scope correction: ordinary and early close/restart, old-generation output,
and stderr's now-explicit no-retention/no-log contract. Findings 5681's
manufactured strike, 5682's cross-generation pipe ownership, and 5686's locale
oracle are implemented correctly in `d71ca7f`/`eed7742`; S3b remains blocked
only by the newly exposed late-error broadcast. The earlier nonblocking
SHOULDs remain open: GTK-thread pipe writes are synchronous, and a terminal
netd failure retains pending prompt strings until their windows close.

Because `d71ca7f` is blocked—and the earlier interleaved S4a and MS0 chains
also remain blocked—the newest approved linear push-through SHA remains the
current origin commit, **`dc52885`**.

## Late-error closure and S4a red tests (`2af4d87`, `92239f7`, `10474a0`, `6f65893`)

**Explicit verdict for `2af4d87`: APPROVED (red).** The new `late-error` case
drives the production close path: after a popup session has answered, a real
`page.close` makes the app send `end_session`; the scripted helper answers
with a valid session-scoped `error` and then `session_ended`. The case requires
the error in no surviving drawer, zero rejected-frame strikes, and a still-
working opener (`tests/e2e/agent_host_lifecycle_test.py@2af4d87:537-575`). It
fails on `d71ca7f` because the error is broadcast into window 1. Extending the
scripted helper with `on_end` uses the actual app/helper frame stream rather
than a validator-only seam (`tests/fixtures/agent/fake_host.py@2af4d87:73-94`).

The same red makes `home-locked`'s owner A use the scripted helper rather than
a live CLI and hooks. After A's reply, it performs no reads of the watched
workspace or `.claude`, so the inotify negative now attributes every event to
the rejected owner B. The production lock/start chain is unchanged.

**Explicit verdict for `92239f7`: APPROVED.** `on_frame` now distinguishes a
helper-wide error (`session == NULL`, still broadcast) from a session-scoped
error whose `ZbWin` has disappeared (drop it). It does not weaken validation:
the validator accepts and sequences the error before this routing decision,
and the following `session_ended` still closes the retained session
(`src/agent_helper.c@92239f7:226-279`). The change is GTK-main-thread local,
adds no ownership or lifetime edge, and exactly closes finding 5699. The
`agent_frames.zig` comment now describes the retained-session contract.

BlackRobin's focused `late-error,window-close,frames` run passed **31 checks,
0 failed**. His clean-export private-Xvfb rerun was GREEN: **Build Summary:
126/126 steps succeeded; 864/864 tests passed**. The first run's unrelated
canary false positive is captured by `6f65893` below. **Finding 5699 is CLOSED
by `92239f7`.** NIT: `src/agent_protocol.zig:75-76` still says an app/window
close removes the validator session; that sibling comment should be aligned
with the corrected `agent_frames.zig` comment.

**Explicit verdict for `10474a0`: BLOCKED-for-tests.** The red honestly fails
on the missing `DRAWER account` row and uses real X input to require the native
Secrets window, no Send/message, no `WebKitWebView`, exclusion from
`page.list`, close, and reopen. But D7b and the commit claim that Account opens
Secrets **in any agent state**, while the sole case exercises only
`runtime-missing` (`tests/e2e/agent_secrets_test.py@10474a0:803-831`). A bad
implementation that creates or enables Account only in that state passes.
Mail 5714 asks for the second `no-token` state promised in mail 5698, with a
pre-click assertion that no Secrets window/status already exists. The new
`focus account` schema is also unexercised; keyboard focus plus Return/Space
is a SHOULD so an X-click-only control cannot satisfy the accessibility path.

**Explicit verdict for `6f65893`: APPROVED (red).** The browser-free self-test
uses the production canary generator and leak scanner against seeded hex and
decimal noise plus the protocol/log vocabulary. Independently at exact
`6f65893`, it failed as intended: **50/50 canaries collided, 1 check failed,
exit 1**. This reliably exposes why a 40-hex-character tail and a four-
character leak window produce false positives against netd's unrelated random
hex. Its green and inclusion in the normal S4a case list are still required;
the red commit alone is not a completed slice.

The newest approved linear push-through SHA remains **`dc52885`**: the older
S4a/MS0 blockers remain in the range, and `10474a0`/`6f65893` do not yet have
reviewed green follow-ups.

## S4a Account and canary closure (`a335080`, `d81ad8e`)

**Explicit verdict for `a335080`: APPROVED (red).** This extends the earlier
Account red through the two missing contracts rather than merely adding more
of the same state:

- `account-button` first proves that no Secrets window or `SECRETS status`
  exists, opens it by a real X click while the helper runtime is deliberately
  missing, closes and reopens it, then drives GTK focus from the real drawer
  input to `DRAWER focus account` and activates the button with Space
  (`tests/e2e/agent_secrets_test.py@a335080:818-865`).
- `account-after-no-token` provisions a working runtime, reaches the distinct
  `unavailable/no-token` state through a real Send, closes the automatically
  opened window, proves it stays absent, and only then clicks Account and
  requires a new visible Secrets window (`:868-892`).

On the pre-green `5b2d213` production tree these cases failed on the absent
Account row (6 checks, 2 failed), as reported with the commit. The no-op click
mutant fails four of thirteen checks. This closes the state-gating and
keyboard-access test gaps in finding 5714.

**Explicit verdict for `d81ad8e`: APPROVED.** The Account button is created
only after the provisioned agent home has configured the Secrets subsystem,
is a native named/accessibly named GTK button, stays sensitive independent of
helper status, and its sole handler presents the native Secrets window with
the owning browser toplevel (`src/agent_drawer.c@d81ad8e:938-968,1016-1023`).
No state branch, Send, helper start, page bridge or socket route lies in that
handler. Its allocation and focus are reported through the strict D7b grammar,
and detach disconnects its signal. The two real-binary cases above exercise
pointer, close/reopen, no-token and keyboard paths while retaining the earlier
no-WebView and `page.list` isolation assertions.

The canary green keeps the required four-character leak scan but replaces the
hex tail—which could collide with unrelated netd nonces—with 40 characters
from an uppercase alphabet disjoint from the seeded hex/decimal, protocol-tag
and normal diagnostic corpus. Uppercase is typed through real Shift-modified X
keys (`tests/e2e/agent_secrets_test.py@d81ad8e:67-86,267-274,895-916`). The
browser-free self-test independently passed **1 check, 0 failed (0/50
collisions)**, and `build.zig@d81ad8e:817-823` now includes both Account cases
and the canary self-test in the normal S4a e2e step. The unrelated relay-test
flake fix waits for the one expected inner relay instead of treating one
transient empty `/proc` sample as final; it preserves the exactly-one check.

BlueBeaver's clean-export private-Xvfb gate at the exact committed blobs was
GREEN: **Build Summary: 126/126 steps succeeded; 864/864 tests passed**. No
browser was run on the real display during this review.

My independent clean-export private-Xvfb gate at exact `d81ad8e` was started
after a process scan found no build, but I had not re-fetched Agent Mail after
5720: BlackRobin had already claimed the slot in 5721. His full gate therefore
overlapped mine, so mine was not a quiet-host acceptance run. The S4a step
itself was GREEN:
**80 checks, 0 failed**, including both Account cases and the canary self-test.
The overall run ended **124/126 steps succeeded; 863/864 tests passed** because
the unrelated live WebKit unit `automation bridge drives a live WebKitGTK
page` reported `PagePort maps timeout to Timeout: expected 0, found 1` under
the two concurrent gates. That result does not contradict the exact quiet
green gate above or any changed S4a path; it is recorded rather than presented
as an acceptance gate. The disposable export and cache were deleted by trap.

**S4a code/test review is APPROVED again.** Finding 5695 (no manual account
path), finding 5714 (one-state-only red) and the canary false-positive finding
5709 are CLOSED by `a335080`/`d81ad8e`. Under the plan's UI-slice rule, final
S4a acceptance still awaits the orchestrator's user-observed real-screen run
of the Secrets window and Account button using a genuinely provisioned
throwaway agent home; that check may now proceed. The separate user
requirement that drawer/status text be selectable and copyable remains open
and is not part of these commits.

## S4a real-screen result and setup-token shape blocker (2026-10-15)

The user tested exact `d81ad8e` on the real NVIDIA X11 screen with a genuinely
provisioned throwaway agent home, dead D-Bus, the explicit file store, fake API
base URL and media source disabled. The **native UI portion passed**: the
Secrets window and Account route both drew, and pasted secret text appeared
only as password dots. The browser log contained zero occurrences of
`sk-ant`, and the throwaway home (including the token file) was deleted unread.
This closes the outstanding real-screen drawing, Account-route and masked-
entry conditions from the preceding section.

**S4a acceptance is REOPENED / BLOCKED by the user's new token-shape
requirement.** The same run showed that three non-token-shaped inputs were
accepted and stored. `src/agent_secrets.zig:12-21` currently accepts every
16-512-byte printable non-space line, and the plan still repeats that obsolete
rule at `:1735` and `:1905`. Today's direct user requirement supersedes those
lines. Save must trim surrounding ASCII whitespace (`SP`, `HT`, `CR`, `LF`,
`VT`, `FF`) and then accept only:

`^sk-ant-oat01-[A-Za-z0-9_-]{22,499}$`

The 22-character suffix minimum is a documented local plausibility bound, not
an assertion that Anthropic publishes an exact token length. OAuth 2.0 Threat
Model and Security Considerations, RFC 6819 §5.1.4.2.2, recommends at least
128 bits for non-human token handles. The user-mandated 64-symbol suffix
alphabet carries six bits per character, so 22 characters provide 132 bits
while 21 provide only 126. With the exact 13-byte prefix, the minimum total
length is therefore 35 bytes; retaining the existing 512-byte total maximum
makes the suffix maximum 499. Source:
<https://datatracker.ietf.org/doc/html/rfc6819#section-5.1.4.2.2>.

`sk-ant-api03-` must remain rejected. The accepted route is specifically the
long-lived credential produced by `claude setup-token`; plan `:1076` excludes
API-key authentication and says `ANTHROPIC_API_KEY` is not read. Surrounding
whitespace is removed before both validation and persistence, and only the
trimmed value may be stored. Internal whitespace, a wrong or wrong-case
prefix, a short suffix, non-ASCII, or any suffix byte outside the exact
alphabet must produce `That doesn't look like a token.` and mutate neither
store. No rejected or accepted token bytes may enter a protocol row, stderr or
log.

This should tighten the shared `validToken` contract used by Save, `storeFile`
and `loadFile`, rather than add a UI-only check: otherwise a manually seeded
file bypasses the same boundary and can still reach the CLI. BlackRobin's mail
5730 inventories the short direct-file canaries that must grow in the green.
Required red-first coverage is an independent table/property oracle with the
22/21 boundaries, prefix-only, empty, wrong prefix/case, `sk-ant-api03-`, bad
characters (`.`, `+`, `/`, `=` and non-ASCII), internal whitespace, the
512/513 total boundaries, and surrounding-whitespace trimming. The real-
binary E2E must press Save on a unique near-miss, observe the fixed message,
prove no file/keyring mutation and no input fragment in rows/logs, then prove
that a padded valid canary is stored and loaded only in trimmed form. Mail 5731
sent this blocker and exact contract to BlueBeaver, copied to BlackRobin.

The next user real-screen check is required after the red/green implementation
is reviewed: one rejected near-miss must show the fixed validation message and
leave the store unchanged, followed by one valid setup-token-shaped canary
that connects without revealing text. The already-passed drawing, Account and
password-mask observations need not be treated as failures, but should remain
in the rerun as regression checks.

## Copyable drawer text and setup sampler (`069e019`, `35c6ee7`, `3ae87bb`)

**Explicit verdict for `069e019`: APPROVED.** This is a test-hygiene-only
change. Both process samplers now take one `/proc` parent snapshot, exclude
zombies, and walk each candidate's parent chain back to the particular
`--agent-setup` browser PID. The PPID field is parsed correctly from
`/proc/<pid>/stat` after the final `)`, and the bounded walk is ample for this
fixed browser → setup helper → bwrap/init → CLI topology
(`tests/e2e/agent_setup_test.py@069e019:117-140`). `watch_helper` and
`cli_processes` share that helper, so unrelated setup/CLI processes can no
longer supply either argv/environment observations or the sealed-case CLI
census (`:143-163,359-368`). A disappearing process is still a normal sample
race and is skipped; production code is unchanged.

I independently reproduced the contamination with a process outside the
tested browser's descendant tree whose argv contained `zb_agent_host setup
--e2e-claude-cli` and whose environment contained the seam. Mutating only the
new descendant loop back to the old global `/proc` scan made the `cli` case
fail **3 of 11** checks (argv, environment-name absence and the exact
allowlist). Exact `069e019` passed **11/11** with the same decoy alive. This is
a deterministic red/green proof of the claimed cause, not merely a reduction
in the flake's probability.

**Explicit verdict for `35c6ee7`: APPROVED (red).** The registered real-binary
test obtains all five targets through production paths: a real typed Send;
assistant/error frames from the supervised helper; a real helper SIGKILL for
the system crash bubble; and the live Ready status. `textrect` rows report
only widget/root geometry and carry no copied text, so they can aim the X
pointer but cannot satisfy the oracle. Before every attempt, a separate GTK
process owns the private display's clipboard with a decoy; real multi-click X
input plus real Ctrl+C must replace it, and another GTK process reads back the
exact expected string (`tests/e2e/agent_drawer_copy_test.py@35c6ee7:39-103,
106-135`). The test is registered in the ordinary full gate and runs inside a
sealed network namespace. On an exact clean export of `35c6ee7`, my private-
Xvfb run failed **5 of 19** checks: user, assistant, error, system and status
all left the decoy untouched. Thus the red is both production-chain-complete
and specific to the missing GTK selection capability.

**Explicit verdict for `3ae87bb`: APPROVED.** The sole behavioral change calls
`gtk_label_set_selectable(..., TRUE)` in the shared `report_text` path, which
is applied to every current bubble role and the status label
(`src/agent_drawer.c@3ae87bb:573-599,985-990`). It neither makes text editable
nor introduces a page/socket route. The role row contains only a fixed role
and rectangle; message content remains out of diagnostic rows. The companion
`agent_protocol.zig` edit correctly closes the stale comment from finding
5701: window close retains a validator session until the helper's
`session_ended`.

I added only that production line to the exact red export, rebuilt, and reran
the same private-Xvfb case: **19/19 passed**, including exact whole-line copy
of the multiword system bubble. This kills a delete-the-selectable-line
mutation. The regular drawer/icon/isolation tests remain the regression guard
for focus, click-through and page-world isolation; BlackRobin's exact clean-
export gate for the committed blobs was GREEN: **Build Summary: 127/127 steps
succeeded; 864/864 tests passed**. No test or browser touched the real display,
and the throwaway export and cache were deleted immediately.

The copyable-text implementation may proceed to the combined user real-screen
session. That check should select and copy both a message bubble and the status
label with the mouse and Ctrl+C, alongside the still-pending setup-token-shape
fix.

**Superseded by the closure audit immediately below:** this section originally
said every commit after `dc52885` through `db5818b` was individually approved
and named `db5818b` as the push-through SHA. That aggregate claim was wrong: it
failed to carry forward the still-open MS0 verdicts and treated fixes later in
history as though they were present in an earlier candidate prefix.

## Corrected blocker closure and linear push boundary (2026-10-15)

| Commit | Correct cumulative status at `db5818b` | Closure evidence |
|---|---|---|
| `4fffdd8` | **OPEN — BLOCKED-for-tests** | No committed follow-up yet. Its golden is self-referential and the real `launch.build_argv` path is not driven. JadeBeacon's strengthened independent oracle is still uncommitted. |
| `7301c5d` | **OPEN — BLOCKED** | No committed follow-up yet. Backend network values still lack production consumers, the native C spawn/lifetime seam is absent, and `LaunchSpec` remains argv-only. JadeBeacon's rework is still uncommitted. |
| `00e1f93` | **CLOSED cumulatively by `eed7742`** | `CancelThenAwaitTest` keeps cleanup suspended after cancellation and fails if disconnect/route close/session end runs before the awaited acknowledgement. |
| `9740498` | **CLOSED cumulatively by `eed7742`** | The delete-`await asyncio.gather(...)` mutation is now killed, covering the green's cancel-then-await ordering. |
| `20e7336` | **CLOSED cumulatively by `eed7742` + `442386e`** | Repeated/early normal close, old-generation stdout, locale and stderr-canary tests land in `eed7742`; approved rev 16.7 deliberately changes the unbuilt stderr ring to drain-and-discard/no-log. |
| `da93d83` | **CLOSED cumulatively by `eed7742`, `d71ca7f`, `442386e` and `92239f7`** | Those commits respectively supply the missing tests, generation-owned readers and retained closing sessions, the approved stderr contract, and the final closed-window error-routing fix. `2af4d87` is the failing-first evidence for the last item. |
| `d71ca7f` | **CLOSED cumulatively by `2af4d87` + `92239f7`** | A valid late session error for a destroyed popup is now dropped instead of broadcast, while `session_ended` still closes the retained validator session. |
| `d47ae67` | **Its four original findings are CLOSED by `db7dc12` + `0fca5d1`** | File fallback persistence, request epochs, delayed lookup and clear-both behavior are covered. This does not close `0fca5d1`'s later Remove/close finding or today's new token-shape requirement. |
| `0fca5d1` | **Its Remove/close finding is CLOSED by `bc85c37` + `adbb8a0`** | File deletion commits at the authorized click and keyring clear finishes independently of window lifetime. Those closure commits occur after the open MS0 pair. |
| `10474a0` | **CLOSED cumulatively by `a335080` + `d81ad8e`** | The extended red covers runtime-missing and no-token states, pre-click absence, close/reopen and keyboard activation; the green Account button is state-independent. |
| S4a current contract | **OPEN — new token-shape blocker** | `db5818b` records the user's later requirement; no implementation commit yet accepts only normalized `sk-ant-oat01-...` setup tokens. |

The distinction between cumulative HEAD closure and a **linear push-through
state** is load-bearing. `adbb8a0`, which repairs the last old S4a Remove/close
bug, is after the open MS0 pair; therefore a prefix ending before `4fffdd8`
would still stop at `0fca5d1` with that bug present. Similarly, the commits
that cumulatively close the initial S3b part-one findings are after MS0. A
candidate prefix ending at `a0a0b56` would still contain the blocked
`c320f97`, while a prefix ending at `6fc6719` would additionally contain the
unrepaired `0fca5d1`. The first post-origin commits are red-first artifacts;
the branch rule is to commit/push milestones when green, so neither is a safe
standalone boundary.

Accordingly **no post-`dc52885` contiguous green prefix is currently fully
approved**. The newest confirmed linear push-through SHA remains
**`dc52885`**. Once the MS0 rework and token-shape green land, the cumulative
closures above can be reassessed together at the resulting later SHA.

## MS0 rework after the history replacement (`086f757`, `9d2d1f0`, `be2be38`)

The authoritative SHAs are the three above. The earlier `a350de0`, `935a8f7`
and `93f91d3` were removed from the branch by the prohibited mixed reset and
must not be used as push or review targets. Patch-id comparison shows that
`086f757` is byte-for-byte the same patch as `a350de0`, and `be2be38` is the
same patch as `93f91d3`. `9d2d1f0` differs from `935a8f7` by one fix-forward
hunk: `hook_run.resolve_bridges` now uses the existing fixed bridge directory
when `runtime/net.json` is absent or malformed
(`agent/host/zb_agent_host/hook_run.py@9d2d1f0:155-164`). That compatibility
hunk is reasonable and closes the missing-manifest failures in the directly
constructed hook-test homes. No later correction may use reset, amend or
rebase; every correction below must be a new commit.

**Explicit verdict for `086f757`: APPROVED as the partial MS0 oracle/share
slice.** Its frozen `reference_launch` and `reference_build_argv` do not call
the implementation under test, cover seven launch variants, and drive the
real `launch.build_argv` branches
(`agent/host/tests/test_backend_contract.py@086f757:54-136,159-312`). The
immutable `Mount` sequence, namespace set, workdir and seccomp descriptor are
semantic fields, and the Linux argv's bind sequence is checked as their exact
projection (`agent/host/zb_agent_host/sandbox.py@086f757:48-84,147-205`). In a
clean export I inserted `--wrong-ms0-mutant` into the production backend; **16
assertions failed**, whereas the unmodified unit passed. This cumulatively
closes `4fffdd8`'s self-referential-golden blocker and the mount/share portion
of the former `7301c5d` blocker. It does not claim to finish MS0.

**Explicit verdict for `9d2d1f0`: BLOCKED.** Two real projections are good:
changing the backend endpoint changes the CLI proxy, and changing its egress
directory changes the outer relay argv. The remainder does not yet implement
the composed contract accepted in mail 5707 and repeated in the macOS rev-6
plan at lines 328-351:

1. `LaunchSpec` still ends at `argv`, `unshare`, `mounts`, `workdir` and
   `seccomp_fd` (`sandbox.py@9d2d1f0:60-84`). Network is an adjacent group of
   backend methods, not an immutable field projected by the consumers. The
   backend also supplies no egress allowlist/policy at all: production netd
   still owns the independent `API_HOST = "api.anthropic.com"` literal
   (`agent/host/zb_agent_host/netd.py@9d2d1f0:41`), despite the plan requiring
   the backend to supply endpoint **and policy**.
2. `BridgePolicy.ports` is description-only. Setup serializes only
   `bridges_dir` (`setup.py@9d2d1f0:465-470`), the hook runner passes only that
   directory (`hook_run.py@9d2d1f0:107-130,146-151`), and the copied production
   relay still binds its own fixed `BRIDGES` map
   (`relay.py@9d2d1f0:33-35,137-150`). Changing the backend ports therefore
   changes metadata but no listener/profile/argv. The purported consumer test
   only compares backend metadata to backend metadata, while the directory
   test writes `net.json` itself and bypasses setup's producer
   (`test_backend_contract.py@9d2d1f0:336-356`). A changed backend policy must
   traverse the real setup-to-hook chain and alter the real relay/profile; the
   test must fail when that projection is removed.

**Explicit verdict for `be2be38`: BLOCKED.** Naming the current Linux values
as `ZbSpawnPolicy` and making `zb_agent_die_with_browser` read them is useful,
and the helper still runs `setpgid` before the parent-death setup
(`src/agent_helper.c@be2be38:462-483`). But it is not yet the parameterized
spawn seam agreed in mails 5707/5708. `zb_agent_run_sync` still accepts only a
raw `spawn_delay_ms` and constructs `zb_spawn_policy_linux(...)` internally
(`src/agent_host.h@be2be38:44-51`; `src/agent_host.c@be2be38:62-67`); netd and
the helper likewise select that Linux policy themselves
(`src/agent_host.c@be2be38:241-255`; `src/agent_helper.c@be2be38:479-483`). A
backend/caller cannot inject a policy into the real spawn. There is also no
matching immutable lifetime field or fd-3/broker inherited-channel contract
in `LaunchSpec`, and no changed-policy injection test pins those real
consumers. Per the ruling mailed as 5750, the Python composed spec remains the
portable contract; the native `ZbSpawnPolicy` is its platform realization,
not a replacement for it. Thread a caller-supplied policy through
`zb_agent_run_sync`/child setup, mirror it in `LaunchSpec`, and drive changed
values through the production spawn seam in a failing-first test.

Gate evidence is green but does not waive those contract blockers. JadeBeacon's
clean exact-`be2be38` export reported **Build Summary: 127/127 steps succeeded;
864/864 tests passed** with Zig exit 0. I then ran an independent exact export,
alone on the host, under private Xvfb with a 1500-second timeout; it also exited
0. Its scary inner `failed command` diagnostic belonged to an intentional
negative nested test, not the top-level gate. Both exports were deleted after
their runs; no live display, socket, profile, or worktree change was used. An
already-running gate of the superseded `93f91d3` had gone red under concurrent
load and the pre-fallback hook runtime; it has no acceptance weight and its
tree was also deleted.

The old `4fffdd8` test-oracle defect is now **CLOSED by `086f757`**, but
`7301c5d`'s network/spawn/composed-spec finding remains **OPEN (JadeBeacon)**
through `9d2d1f0`/`be2be38`. Independently, `ba19159` is still a red-only,
unregistered token-shape commit with no committed green. Therefore there is
still no approved contiguous post-origin prefix past the prior boundary. The
newest approved push-through SHA remains **`dc52885`**.

## Setup-token shape and S3c config-check red (`ba19159`, `3b07a37`, `40d5c6d`)

**Explicit verdict for `ba19159`: APPROVED as the failing-first token-shape
commit.** The independent table covers the 22/21 and 512/513 boundaries, the
exact and wrong-case prefixes, `sk-ant-api03-`, internal whitespace, ASCII and
non-ASCII bad bytes, and paste trimming. It also reaches `storeFile` and
`loadFile`, while the real-binary cases drive Save by private-Xvfb input against
both a private Secret Service and a throwaway file store
(`tests/agent_secrets_shape_test.zig@ba19159:27-200`;
`tests/e2e/agent_secrets_test.py@ba19159:504-568`). The old production failed
five of six Zig tests and stored the first E2E near miss. One property
distribution assertion in the red was itself too strict because its generator
put odd bytes into long strings too often; `3b07a37` corrects that generator
without weakening the independent oracle. The other table, store/load and
real-binary failures still provide valid red evidence for the production gap.

**Explicit verdict for `3b07a37`: APPROVED. The setup-token shape is approved,
and the combined real-screen session may proceed.** `validToken` implements
exactly `^sk-ant-oat01-[A-Za-z0-9_-]{22,499}$`, preserving the 512-byte total
ceiling; `tokenFromPaste` trims exactly the six ASCII whitespace bytes before
validation (`src/agent_secrets.zig@3b07a37:12-40`). The same predicate guards
the file write and file read, so a seeded file cannot bypass the boundary
(`:93-148,176-188`). Save clears the GTK entry immediately, duplicates only
the validated trimmed slice, wipes the original paste, shows only the fixed
rejection sentence, and never sends rejected input to either store
(`src/agent_secrets_window.c@3b07a37:234-264`). The registered real-binary
cases prove nine near misses mutate neither private store, the padded canary is
persisted without its padding in both store modes, and no `sk-ant`/near-miss or
four-character canary run enters rows or logs. `build.zig` registers both the
Zig shape suite and the two E2E cases. BlueBeaver's exact clean-export private-
Xvfb gate passed **129/129 steps and 868/868 tests**. This closes the token-
shape blocker recorded under `db5818b`; the user's next run should retain the
already-passed Account button, masked entry and drawing checks, reject one
near miss with `That doesn't look like a token.`, then accept one padded valid
canary without exposing it.

Advisory only: an item inserted into Secret Service by some other same-user
program is still trusted on lookup (`src/agent_secrets.c@3b07a37:285-301`),
whereas the explicit file loader now validates. That is not a bypass of Save
or either requested S4a store path, but applying the same predicate on keyring
fetch would make the read boundary symmetric. Also, the plan's old printable-
token wording at lines 544, 1735 and 1905 is superseded and must be corrected
before S6 builds its login route; BlackRobin was mailed this documentation
follow-up.

**Explicit verdict for `40d5c6d`: BLOCKED-for-tests.** Its committed real-
binary red is otherwise valuable: it provisions with the real setup path,
uses the e2e-only fake helper behind a sealed network namespace, proves the
unchanged/writable-state control, and observes refusal through both the native
drawer state and the helper's actual frame/run files. The reported old-code
result was **47 checks, 38 failed**, with the five unchanged controls passing.
However, rev 16.10 explicitly requires a check on each window's first prompt
*and the first prompt after `session_ended`*. The red covers window 1 followed
by a new window 2, but never ends a session and sends again in the same window
(`tests/e2e/agent_config_check_test.py@40d5c6d:112-153`). A mutant that caches
"checked" forever on each `ZbWin` survives all committed cases. Add a red-
first same-window case that observes a real session end, mutates configuration,
sends again in that window, and proves the fixed refusal/bubble, no second
helper start and no second prompt delivery. Mail 5761 sent this blocker to
BlackRobin while its green gate was still running; the correction must be a
new follow-up commit, never a rewrite.

## User acceptance: S4a and copyable drawer text (2026-10-15)

The user completed the combined real-screen check on the NVIDIA X11 display
using a clean export of exact `3b07a37`, a throwaway agent home provisioned by
the real `--agent-setup`, a dead D-Bus address, the explicit file store, a fake
API base URL and media source disabled. The throwaway directory was deleted
afterward.

- **Account route: PASS.** The drawer's Account button opened the native
  **Claude Agent account** window.
- **Setup-token shape: PASS — user: “All correct.”** `sk-ant-api03-abc` and
  `sk-ant-oat01-short` were refused; a made-up setup-token-shaped `oat01`
  canary was accepted after surrounding whitespace was trimmed; Remove then
  cleared it successfully.
- **Copyable text: PASS — user: “Copy works.”** Drawer text was selected with
  the mouse and copied with Ctrl+C on the real screen.
- **Leak check: PASS.** The browser log contained zero occurrences of
  `sk-ant`.

**S4a is USER-ACCEPTED on the real screen.** This closes the outstanding
Secrets-window drawing, Account-button, password-entry, token-shape and Remove
acceptance conditions for `d81ad8e` through `3b07a37`. **The copyable drawer
text requirement implemented by `35c6ee7`/`3ae87bb` is also USER-ACCEPTED.**
The separate defense-in-depth advisory about validating a credential planted
directly into Secret Service by another same-user program remains advisory;
it was not part of this Save/file-store acceptance run.

## MS0 Slice D, token-plan rev 16.11, and S3c same-window red (`0fb21f4`, `ac07c1a`, `9638900`)

**Explicit verdict for `ac07c1a`: APPROVED as the green, behavior-preserving
MS0 Slice D.** `LaunchSpec` now carries the immutable semantic `Network` value,
whose `Egress` contains the endpoint, backend-owned upstream allowlist and
socket directory and whose `BridgePolicy` contains the bridge ports
(`agent/host/zb_agent_host/sandbox.py@ac07c1a:76-96,125-151,240-275`). The
existing endpoint, egress-directory and bridge-policy accessors project from
that value, and `launch_spec()` carries it. This closes finding 1 under
`9d2d1f0`: network is no longer merely adjacent backend methods, and the
allowlist is no longer absent from the portable backend contract.

The same commit also closes the producer/test-bypass half of finding 2.
`setup.net_manifest()` is the function the real `stage()` calls, and it now
serializes `bridges_dir`, backend bridge ports, endpoint and allowlist
(`agent/host/zb_agent_host/setup.py@ac07c1a:433-450,485`). The changed-network
test injects one whole `Network` and observes its endpoint through the real CLI
proxy, its directory through `launch.build_argv`, its ports/allowlist through
the real setup producer, and the value in `LaunchSpec`; it neither compares
metadata only nor hand-writes `net.json`
(`agent/host/tests/test_backend_contract.py@ac07c1a:383-474`). Defaults remain
byte-identical. JadeBeacon's clean-export private-Xvfb gate at exact
`ac07c1a` was green: **129/129 steps succeeded; 868/868 tests passed; Zig exit
0**. Its export and cache were deleted.

This is deliberately a partial MS0 slice, not a claim that the old finding is
fully closed. **Finding 2's consumer half remains OPEN for Slice E
(JadeBeacon/BlueBeaver):** at exact `ac07c1a`, production netd/hook/relay still
fall back to their fixed allowlist/port maps, so changed manifest values do not
yet alter their real listener/profile behavior. **Finding 3 remains OPEN for
Slice F (JadeBeacon)** as the orchestrator directed: caller-supplied native
spawn policy plus the composed lifetime/channel fields are not part of Slice
D. Neither later slice is a defect in this inert, independently green producer
slice.

**Explicit verdict for `0fb21f4`: BLOCKED (docs).** Its three edited locations
correctly use the approved
`^sk-ant-oat01-[A-Za-z0-9_-]{22,499}$` setup-token rule, the one shared
validator and the exact six-byte surrounding-whitespace trim. But the same
revision still says at plan line 1901 that “whitespace or a multi-line paste is
rejected.” That directly contradicts line 544, `3b07a37`, and the user's
accepted real-screen behavior: surrounding spaces/tabs/newlines around one
valid token are trimmed and accepted. Fix forward, without rewriting history,
to say that internal whitespace, more than one token/non-whitespace line, or
any other nonmatching trimmed value is rejected. This is a plan-only blocker;
it does not reopen the approved production implementation or the user's S4a
acceptance.

**Explicit verdict for `9638900`: APPROVED as failing-first test evidence.**
The new `same-window` case makes the fake helper emit a valid `result` followed
by a real `session_ended`. Its unchanged arm proves the next Send in window 1
opens `s-1-2`, while its changed arm edits `settings.json` after session 1 and
then requires the exact config-changed status/bubble, no new prompt, helper,
child or reply (`tests/e2e/agent_config_check_test.py@9638900:34-48,90-104,
194-226`). Counting replies before the refusal is the correct same-window
oracle. The reported evidence is specific: old code failed **5/15** checks;
the once-per-window mutant failed the same **5/15**; the uncommitted green
passed **15/15**, and the complete file passed **62/62**. This closes the
BLOCKED-for-tests verdict on `40d5c6d`; production remains intentionally red
until the separate green commit lands.

No test was started for this review because BlackRobin held the serialized gate
slot. The exact `ac07c1a` clean-export gate above is valid Slice-D evidence;
`9638900` is intentionally red and its green was still gating. The newest
approved linear push-through SHA therefore remains **`dc52885`**: the current
history still contains the unpaired S3c red (`40d5c6d`/`9638900`), the blocked
plan revision `0fb21f4`, and the staged MS0 E/F closures have not landed. A
later fix-forward may close all of these cumulatively; none may be skipped or
history-rewritten.

## Plan rev 16.12 and S3c config-check green (`04b7977`, `1d5cac0`)

**Explicit verdict for `04b7977`: BLOCKED (docs).** The first half of the
revised S4 edge-case sentence now correctly says that surrounding SP, HT, CR,
LF, VT and FF are trimmed and that only the trimmed token is stored. The same
sentence then independently says that “a multi-line paste” is rejected
(`thoughts/searchable/shared/plans/2026-10-13-claude-agent-chat-drawer-tdd-plan.md@04b7977:1901`).
That still overlaps the accepted case: the production/E2E padded valid token
has leading and trailing CR/LF and is therefore literally a multi-line paste.
The line must state the boundary without overlap: internal whitespace, more
than one token/non-whitespace line, or any other nonmatching trimmed value is
rejected; whitespace-only lines at the edges are part of the surrounding trim.
This remains documentation-only and does not reopen `3b07a37` or the user's
real-screen acceptance.

**Explicit verdict for `1d5cac0`: BLOCKED-for-tests; the reviewed production
path is otherwise correct.** The implementation reads and parses both bounded
manifests, walks `.claude`, skips only top-level state names, hashes each
manifest file in 64-KiB chunks, compares the exact key count, and maps every
read/parse/walk error to `changed`
(`src/agent_config_check.zig@1d5cac0:15-53,68-84`). The native boundary takes
the owner lock before reading, owns the copied home string as GTask data, runs
the expensive work off the GTK thread, resolves the window by ID on the main-
context callback rather than retaining a `ZbWin *`, drops every pending prompt
on refusal, and starts nothing for it
(`src/agent_helper.c@1d5cac0:606-648,672-710,712-725`). The `checking` field is
per window, blocks `flush`, and is cleared exactly once by completion. A closed
window makes the callback a no-op. The original red drives the real setup,
binary, drawer and fake-helper production chain; `9638900` proves the check
runs again in the same window after a real `session_ended`.

One explicit rev-16.10 contract branch is untested. The plan says a symlink
counts as the file it names, and production special-cases `.sym_link` plus
symlink-to-directory (`src/agent_config_check.zig@1d5cac0:38-46,63-65`). The
unit fixture creates no symlink, and the real setup resolves every accepted
source link into an ordinary copied file/directory before the E2E starts.
Neither red therefore fails if a manifest-named symlink merely increments
`seen` without hashing its target. That mutant could accept an arbitrary
replacement while satisfying the count. Add failing-first unit cases that pin
the complete intended rule: a manifest file replaced by a symlink to different
bytes is `changed`; a symlink to identical bytes is `ok`; a symlink to a
directory absent from the manifest is ignored; and a broken symlink is
`changed`. The identical-bytes control is necessary to kill an opposite
reject-all-symlinks implementation and preserve the plan's chosen semantics.

BlackRobin's final clean-export private-Xvfb gate for the five S3c green files
was green: **132/132 steps succeeded; 873/873 tests passed**. The immediately
preceding gate had the same 873 compiled tests pass but lost the unrelated
`agent-secrets-e2e` harness to Xlib `BadWindow` while it inspected a Secrets
window that closed between `XQueryTree` and `XFetchName`; the final gate did
not reproduce it. BlueBeaver owns a separate failing-first XInput harness fix,
so that race does not indict S3c, but it remains tracked until that fix lands.
No independent test was started here because BlueBeaver held the serialized
gate slot.

The newest approved linear push-through SHA remains **`dc52885`**. Rev 16.12
still needs the unambiguous wording follow-up, S3c needs its symlink red/green,
and the previously recorded MS0 Slice E/F closures remain staged. `04b7977`
and `1d5cac0` may be closed only by new follow-up commits; no history rewrite.

## Rev 16.13, S3c symlink closure, and BlueBeaver reds (`8e43934`, `734a1e0`, `738b17a`, `72e663f`)

**Explicit verdict for `8e43934`: APPROVED.** Rev 16.13 removes the
contradictory “multi-line” shorthand from both the current status and the S4
edge-case contract. The normative line now says that SP/HT/CR/LF/VT/FF are
accepted only at the paste's edges and trimmed, while whitespace inside the
trimmed token—more than one token or more than one non-whitespace line—is
rejected (`thoughts/searchable/shared/plans/2026-10-13-claude-agent-chat-drawer-tdd-plan.md@8e43934:8,1901`). This matches `3b07a37` and the user's accepted real-screen behavior. It closes the docs blockers on `0fb21f4`/`04b7977`; those revisions are cumulatively superseded by `8e43934`.

**Explicit verdict for `734a1e0`: APPROVED.** The registered
`agent_config_check_test` step now pins the complete symlink rule: a
manifest-named link to different bytes is `changed`; a link to identical bytes
is `ok` and follows later target changes; a new link to a directory is ignored;
and both a manifest-named and a new dangling link are `changed`
(`tests/agent_config_check_test.zig@734a1e0:166-208`). This covers both sides of
“a symlink counts as the file it names,” rather than merely rejecting every
link. BlackRobin reports **9/9** focused tests and four discriminating mutants:
the old five tests let all four survive, while the new suite kills the
count-without-hashing, reject-all-links, include-link-to-directory and
dangling-link-matches mutants with 3, 2, 1 and 1 failures respectively. No
production file changed. This closes the only BLOCKED-for-tests finding on
`1d5cac0`; cumulatively, `40d5c6d` + `9638900` + `1d5cac0` + `734a1e0` are
**APPROVED**, and S3c config checking is complete.

**Explicit verdict for `738b17a`: APPROVED as failing-first MS0 Slice D/E
evidence; intentionally red and not pushable without its green.** The four
independent layers do not collapse into a test-only shortcut:

- the direct netd suite drives its real command line and socket tree, proves
  that manifest ports carry bytes, that the manifest allowlist replaces the
  built-in host before any upstream attempt, that missing/legacy manifests
  preserve the defaults, and that malformed JSON, types, counts, modes,
  symlink/directory/FIFO inputs fail before ready without leaking the canary
  (`agent/host/tests/test_netd_manifest.py@738b17a:64-195`);
- the direct relay suite runs each real relay command in private network/PID
  namespaces, proves exactly the supplied 1–8 ports carry bytes, proves 3128
  and omitted bridge ports remain absent, checks the hook inherits no fd above
  2, and rejects a complete bad-grammar table before the hook runs
  (`agent/host/tests/test_relay_ports.py@738b17a:56-121`);
- the Zig suite requires production `netdArgv` to place
  `--net-manifest PATH` after `--bwrap` and before e2e seams, preserves the
  exact old argv when no path exists, and derives the path from the agent home
  (`tests/agent_net_manifest_test.zig@738b17a:13-50`); and
- the real-binary E2E provisions through the real setup path, sends through
  the drawer, inspects the actual netd launcher/socket layout, exercises the
  legacy fallback, and observes a refused manifest as `AGENTNET unavailable`
  plus the fixed bubble with no canary in rows or stderr
  (`tests/e2e/agent_netd_manifest_test.py@738b17a:43-170`).

The E2E deliberately replaces only setup's produced `runtime/net.json`; it
does not by itself prove the backend producer. That edge is independently
driven by approved `ac07c1a`, whose test calls the exact producer used by
`stage()`. Together they close the production chain without either test
bypassing its owned boundary. The reported old-code reds are specific: netd
5/8 fail, relay 2/3 fail, Zig 3/3 fail, and real-binary E2E 6/13 checks fail.
Registration and the production consumers still belong to the pending green.

**Explicit verdict for `72e663f`: APPROVED as failing-first BadWindow
evidence; intentionally red and not pushable without its green.** The test
refuses every display outside xsession's private `:200`–`:399` range before it
opens X, creates and destroys its own window, then deterministically issues
the same `XFetchName`/`X_GetProperty` request that killed the Secrets E2E
(`tests/e2e/test_xinput_errors.py@72e663f:54-79`). Old code exits on BadWindow
in exactly one of the three cases. The two controls require a vanished window
to be absent from `toplevels()` while a non-race BadValue still terminates the
process (`:81-91`), so the desired fix cannot turn every X error into success.
This accurately captures BlackRobin's observed harness failure without
touching production browser code.

One green-review item was mailed early to BlueBeaver (5786): the current WIP
handler ignores every BadWindow and BadDrawable process-wide, although such an
error need not come from a read-only census of a window that just disappeared.
The committed red remains approved, but the green must either scope tolerated
errors to justified read-only request codes (and add a BadDrawable case if it
keeps that claim) or provide tests that deliberately establish the broader
harness policy while unrelated mutation errors remain fatal.

No test process was started for this review because BlueBeaver explicitly
holds the serialized gate slot for these red/green pairs. `734a1e0` changes
only an already-registered unit suite and relies on BlackRobin's focused
9/9/mutation evidence plus the prior **132/132-step, 873/873-test** clean gate
for unchanged production; `8e43934` is docs-only. BlueBeaver's final clean-
export private-Xvfb gate must cover both greens.

The newest approved linear push-through SHA remains **`dc52885`**. Although
the plan and S3c findings are now cumulatively closed, the earlier MS0 composed
contract still has open Slice E/F consumer/spawn work, and the linear history
now also contains the unpaired red-only `72e663f` and `738b17a`. Neither red
may be included in an approved push prefix until its registered green lands;
no history rewrite may skip them.

## XInput and netd/relay greens (`463a3eb`, `dee9829`)

**Explicit verdict for `463a3eb`: APPROVED.** The process-wide Xlib handler
now suppresses only BadWindow/BadDrawable whose protocol request is the
read-only GetProperty or GetGeometry used by `toplevels()`; every other error
is handed to Xlib's previous handler (`tests/e2e/xinput.py@463a3eb:45-77`).
The window census naturally skips a failed title read and leaves geometry
outputs zero on a failed geometry read, so it cannot return the vanished
window. The registered private-Xvfb suite retains the original deterministic
XFetchName/BadWindow case and adds both sides requested during pre-review: a
destroyed-window GetGeometry/BadDrawable survives, while ConfigureWindow on a
destroyed window and an ordinary BadValue still terminate the process
(`tests/e2e/test_xinput_errors.py@463a3eb:29-70,89-118`;
`build.zig@463a3eb:883-889,1179`). The unscoped-handler and GetProperty-only
mutants are therefore both distinguished. This closes the green-review item
in mail 5786 and cumulatively closes the `72e663f` red/green pair.

**Explicit verdict for `dee9829`: APPROVED for the netd/relay side of MS0
Slices D/E.** The browser derives `<agent-home>/runtime/net.json`, places it
after `--bwrap` and before any e2e seam, and uses the production argv on both
flagged and unflagged paths (`src/agent_net.zig@dee9829:88-110`;
`src/app.zig@dee9829:122-166`; `tests/e2e/agent_netd_spawn_test.py@dee9829:194-226,376-404`).
Netd's outer stage performs one nonblocking, no-follow open, validates the
same descriptor as an owner-held regular file with no group/world write bit,
caps the read at 64 KiB plus one detection byte, and emits only fixed refusal
text. It requires 1–8 unique lowercase DNS names and 1–8 unique integer ports,
rejects one network key without the other, and preserves the exact built-ins
for a missing or pre-network manifest (`agent/host/zb_agent_host/netd.py@dee9829:559-630`).
Only those checked hosts and ports cross the bwrap boundary as explicit argv;
the sandboxed side validates them again, replaces rather than augments the
production allowlist/bridge set, and creates exactly the corresponding Unix
sockets (`:633-641,669-692,718-778`). Test-only allow/bridge additions remain
gated by the app's existing `--e2e-protocol` seam.

The inner relay accepts `--ports` only after `--bridges`, limits it to 1–8
unique plain-decimal ports, and otherwise preserves the historical fixed map;
egress mode cannot accept that option (`agent/host/zb_agent_host/relay.py@dee9829:51-81,168-185,250-286`).
The registered suites cover exact byte forwarding, no omitted/default/API
listener, descriptor closure, malformed grammar before hook execution,
manifest file kinds/modes/size/types, allowlist replacement after a matching
ClientHello, browser argv/layout, refusal UI and canary-free output
(`agent/host/tests/test_netd_manifest.py@dee9829:61-199`;
`agent/host/tests/test_relay_ports.py@dee9829:64-121`;
`tests/e2e/agent_netd_manifest_test.py@dee9829:43-170`). The allowlist green's
ClientHello correction fixes the red oracle rather than weakening it: netd
intentionally delays its dial until the SNI matches, and the corrected test
now observes both the refusal with no attempt and the allowed host's vetted
attempt.

BlueBeaver's clean export of the exact combined file set at `dee9829`, with a
fresh cache under private Xvfb, passed **138/138 steps and 880/880 tests**;
the export was deleted. I did not start a competing run because JadeBeacon
holds the next serialized gate slot.

These approvals close the red-only push blockers `72e663f` and `738b17a`, but
they do **not** close the earlier composed MS0 finding. **Slice E remains OPEN
(JadeBeacon):** production `hook_run` must still project the backend ports
through the real setup→hook→relay chain and test that changed ports alter the
real sealed hook's listeners. **Slice F remains OPEN (JadeBeacon):** the
caller-supplied native spawn policy plus immutable lifetime/channel fields and
their real consumers have not landed. Consequently the newest approved
linear push-through SHA remains **`dc52885`** until both pre-existing findings
are closed; `463a3eb` and `dee9829` themselves are approved and need no
follow-up from BlueBeaver.

## MS0 Slice E/F closure (`227554f`, `281f33f`)

**Explicit verdict for `227554f`: APPROVED.** The production hook runner now
reads `ports` from the same provisioned `runtime/net.json` that already carries
the backend's `bridges_dir`, and puts `--ports P1,P2` immediately after the
inner relay's `--bridges DIR`; a legacy manifest with no ports keeps the old
fixed-map invocation (`agent/host/zb_agent_host/hook_run.py@227554f:106-135,151-188`).
This is a real consumer, not parallel metadata: the registered sealed-hook test
runs the actual outer bwrap, copied `zb-hook-run`, nested bwrap and copied inner
relay, then proves that a reduced manifest binds 51091 and refuses 31337
(`agent/host/tests/test_hook_net.py@227554f:205-225`). Together with Slice D's
changed-backend injection through the real `setup.net_manifest()` producer and
`dee9829`'s strict relay grammar, this closes `7301c5d` finding 2's remaining
setup -> hook -> relay consumer edge. Dropping `resolve_ports` or `--ports`
would restore 31337 and turn that end-to-end assertion red.

**Explicit verdict for `281f33f`: APPROVED.** `zb_agent_run_sync` no longer
constructs a Linux policy internally: its ABI accepts the caller's complete
`ZbSpawnPolicy`, the child setup copies exactly that value, and the real Zig
setup caller supplies `zb_spawn_policy_linux(spawn_delay_ms)`
(`src/agent_host.h@281f33f:20-54`; `src/agent_host.c@281f33f:42-73`;
`src/app.zig@281f33f:108-112`). Linux behavior is preserved, while the existing
registered parent-death and 5-second-delay timeout cases drive changed delay and
parent-race values through this production caller/spawn boundary.

The immutable Python `LaunchSpec` now also carries backend-neutral `Lifetime`
and `Channel` values, and `LinuxBwrapBackend.launch_spec()` populates both from
the same backend (`agent/host/zb_agent_host/sandbox.py@281f33f:82-101,158-197,288-349`).
The channel has a real production projection: `token.write_wrapper` uses the
backend's descriptor and announcing environment name when it generates
`zb-claude`; the changed-channel test observes the altered `dup2`, inherited fd
and environment assignment rather than inspecting metadata only
(`agent/host/zb_agent_host/token.py@281f33f:98-141`;
`agent/host/tests/test_backend_contract.py@281f33f:505-571`). This closes
`7301c5d` finding 3 and preserves the rule that the credential bytes travel on
the inherited socket, never in the environment.

The cumulative `7301c5d` findings are now all **CLOSED**:

- finding 1 (semantic network capability and allowlist in `LaunchSpec`) by
  `ac07c1a`;
- finding 2 (real netd/relay and hook consumers) by `dee9829` plus `227554f`;
- finding 3 (caller-owned native spawn policy and immutable lifetime/channel)
  by `281f33f`.

I independently ran exact `281f33f` from a clean `git archive`, with a fresh
cache, a 1500-second bound and private Xvfb `:106`. It exited 0 with **Build
Summary: 138/138 steps succeeded; 880/880 tests passed**. The gate included the
new 19-case hook-network suite, 28-case backend-contract suite, setup
parent-death/timeout coverage and the full real-binary e2es. The EXIT trap
deleted the export and cache, and no live display, profile or socket was used.

MS0's Linux extraction is therefore cumulatively **APPROVED**. The newest
approved linear push-through SHA is **`281f33f`**.

## S4.2 helper token-removal seam (`658a403`)

**Explicit verdict for `658a403`: BLOCKED.** The running-helper shutdown path
is otherwise carefully bounded: it fails the currently waiting prompts, sends
the helper shutdown frame, closes its input, escalates from TERM to KILL on
main-loop timers, and guards both timers by the exact removing PID. The exit
callback forgets that process once, suppresses the ordinary crash/restart path,
and starts a fresh helper only if a window accumulated a new prompt while the
old process was stopping (`src/agent_helper.c@658a403:407-488,761-784`). This
also cancels a pending crash-restart timer, so a helper which already has a PID
cannot quietly return after Remove. BlackRobin's reported old-code red (1 of 5
checks failed), focused green (8/8), lifecycle green (89/89), and full private-
Xvfb gate (138/138 steps, 880/880 tests) exercise that already-running case.

However, the public removal seam does not invalidate a token acquisition which
has not spawned the helper yet. `fetch_token()` leaves the helper in
`H_WAIT_TOKEN`; its worker may already have copied the old credential before
delaying its callback. If the user clicks Remove then, the new function sees
`pid <= 0` and returns without changing that state
(`src/agent_helper.c@658a403:588-590,761-774`). The stale callback subsequently
still sees `H_WAIT_TOKEN` and calls `spawn_with(token)`
(`src/agent_helper.c@658a403:573-585`). The same class exists one stage earlier:
Remove leaves `H_WAIT_NET`, so a later net-ready callback can begin a fetch
while the asynchronous store deletion is still running. Consequently the
credential selected before Remove can start a new helper after the click. That
violates S4.2's edge contract that removal ends the session and the next Send
starts afresh; correctness cannot depend on the asynchronous clear winning a
race.

The required regression must hold the existing keyring lookup-delay seam after
it has copied a token, click Remove before delivering the callback, and assert
that no helper or fake-API request uses that stale Bearer, the waiting prompt is
decided exactly once, and a subsequent Send opens Secrets. A second case must
remove while waiting for netd. The fix needs a removal/token generation or an
equivalent state invalidation which wipes every pre-Remove completion. Mail
5813 sent this BLOCKER and the failing-first shape to BlackRobin, with
BlueBeaver copied because the S4b caller is the other half of the edge.

I did not start a test process: the serialized gate slot passed to JadeBeacon
and then BlueBeaver, and the reported gate cannot cover the uncommitted S4b
caller or the missing interleaving. The newest approved linear push-through SHA
therefore remains **`281f33f`**.

## Interim Remove-race and MS0 delay review (`711d78f`, `68e7534`, `51b21b3`)

**Explicit verdict for `51b21b3`: APPROVED.** The registered real-binary
`agent-setup-e2e` now runs otherwise identical setup launches with the native
spawn policy's delay set to zero and 3000 ms, and requires at least a two-second
difference (`tests/e2e/agent_setup_test.py@51b21b3:487-508,689-693`). This is a
changed-value assertion through the production chain: `app.zig` supplies
`zb_spawn_policy_linux(setup_run.spawn_delay_ms)` to `zb_agent_run_sync`, whose
child setup applies that policy before exec. JadeBeacon demonstrated the
policy-ignoring mutant at +0.02 s (red), versus +3.09 s on the production path
(green); the existing parent-death and timeout tests alone did not kill that
mutant. Their clean export under private Xvfb passed **138/138 steps and
880/880 tests**. This closes MS0 Slice F finding 3's test-completeness caveat.

**Interim verdict for `711d78f`: BLOCKED-for-tests.** It is a legitimate
failing-first artifact, and its isolated C test is red on the missing
clear/fetch guard. However, the commit registers none of its new tests, its
original e2es infer the helper state from timing rather than observing it, and
the original replacement sequence cannot distinguish a stale completion after
a fresh Send. BlueBeaver's in-progress follow-up adds token-fetch/remove rows,
holds netd's ready line to prove `H_WAIT_NET`, delays deletion rather than only
the clear answer, and adds a replacement-token overlap. A read-only WIP review
also found one mixed-index bug (`len(ordered)` used to slice
`secrets_events`); mail 5832 reported it, and it was corrected before the
evidence was restarted.

The corrected clean-export failing-first run at exact `711d78f`, with only the
test seams overlaid, has now repeated three times with the same result: the C
test fails both clear-overlap assertions, and each real-binary run reports
**51 checks, 14 failed**. The failures include removed-token Bearer use after a
Remove in both `H_WAIT_TOKEN` and `H_WAIT_NET`, failure to reopen Secrets, and
the store-clear overlap. This proves the old behavior is red; the verdict stays
blocked until the corrected tests are committed, registered and green.

**Interim verdict for `68e7534`: implementation review clean; final verdict
pending its registered green evidence.** `token_gen` invalidates every fetch
begun before Remove; `on_token` wipes an answer from an old generation even if
a later Send has returned the global state to `H_WAIT_TOKEN`; and Remove moves
`H_WAIT_NET`/`H_WAIT_TOKEN` to idle after deciding every waiting prompt once
(`src/agent_helper.c@68e7534:108-113,574-592,768-789`). These callbacks and the
generation update run on the GTK main context, so no native data race is added.
The new store-side guard is still required for a current-generation fetch begun
while asynchronous deletion is in flight. BlueBeaver is separately exercising
three exact mutants: state-only token acceptance, removal without the
`H_WAIT_NET` arm, and removal without the store-clear guard.

The serialized gate slot remains with BlueBeaver for those red/mutant repeats,
the follow-up commits and one full clean-export gate. I have not started a
competing build. Until that evidence is green, the newest approved linear
push-through SHA remains **`281f33f`**; `51b21b3` is individually approved but
is preceded by the still-blocked `711d78f`.

## S4b token-removal race closure (`711d78f`, `68e7534`, `6bcc540`, `463e707`)

**Explicit verdict for `711d78f`: APPROVED as the failing-first base,
cumulatively corrected by `6bcc540`.** The original commit established the
missing clear/fetch unit boundary and three real-binary race cases, but its
timing-only state inference and lack of a replacement overlap were the reasons
for the interim BLOCKED-for-tests verdict above. `6bcc540` replaces those weak
preconditions with observable fetch/remove/netd rows and adds the discriminating
replacement case. The corrected red state was run three times at the old helper:
each real-binary run failed 14 of 51 checks, and the C test failed both overlap
assertions. Every row-order precondition held. This closes the interim test
finding rather than overlooking it.

**Explicit verdict for `68e7534`: APPROVED.** Every Remove increments
`token_gen`; the generation travels with the asynchronous token fetch, and its
completion wipes and ignores an older value even if a subsequent Send has put
the global helper state back in `H_WAIT_TOKEN`. A Remove in `H_WAIT_NET` or
`H_WAIT_TOKEN` decides the queued prompt once, makes the helper idle and prevents
a later net-ready callback from fetching (`src/agent_helper.c@68e7534:108-113,
574-600,768-789`). The state-only mutant fails the replacement overlap, and the
mutant without the `H_WAIT_NET` arm fails the held-netd case, each in three of
three clean runs. This closes the helper half of the `658a403` blocker.

**Explicit verdict for `6bcc540`: APPROVED.** Its seams remain inert without
`--e2e-protocol`: the app only parses the netd ready hold in e2e mode, and only
e2e setup installs the Secrets fetch observer. The observer receives the fixed
result enum, never a credential. The real-binary cases now prove, rather than
infer:

- `fetch begin -> remove click` before any answer (`H_WAIT_TOKEN`);
- `drawer starting -> remove click`, with neither netd-ready nor fetch first
  (`H_WAIT_NET`);
- a post-Remove fetch begins before the delayed clear answers; and
- a distinct replacement's second fetch begins before the stale first answer.

They drive X clicks, the production helper, private keyring, netd and fake HTTPS
API. The hooks case provisions through the real setup path and drives all four
S4 hook events; it proves both bridge positives, no proxy/API path, no token or
messaging environment name, and no canary in the records
(`tests/e2e/agent_secrets_test.py@6bcc540:676-906,1286-1350`). The setup-valid
hook command names the copied `~/.claude/hooks` script and lets it write only to
the agent home's scratchpad. The first owner gate exposed one test-hygiene bug:
two “window did not open/change” assertions counted the new observer rows.
`window_lines()` now limits those assertions to the window's `status`, `text`,
`tree` and `rect` rows without weakening or removing the observer.

**Explicit verdict for `463e707`: APPROVED.** Remove starts the asynchronous
clear, immediately invalidates/stops the helper independently of whether the
Secrets window later closes, and deletes the file at the click
(`src/agent_secrets_window.c@463e707:291-333`). The store-side guard records on
the GTK main context whether a fetch started during a clear, a clear is still
running at its answer, or a clear began in between. Any successful overlapping
fetch is changed to ABSENT and its copied token is wiped before the consumer is
called (`src/agent_secrets.c@463e707:127-142,217-255,271-365`). Multiple clears
compose correctly through the running counter and monotonic start counter; no
worker accesses those counters. The no-store-guard mutant fails the
send-during-clear e2e and two of four C assertions in three of three runs.

The clear/fetch C regression is registered in both `test` and
`test-agent-secrets`, and all seven S4b real-binary cases are in the full gate
(`build.zig@463e707:437-461,898-902,1167-1175`). BlueBeaver's corrected clean
export passed **140/140 steps and 881/881 tests**. I independently ran exact
`463e707` from a clean `git archive`, fresh cache, 1800-second bound and private
Xvfb (seed `0xe843d2b6`): **Build Summary: 140/140 steps succeeded; 881/881 tests
passed**. The apparent `failed command` lines belonged to expected negative
subtests; the top-level gate exited 0. The EXIT trap deleted the export, and no
live display, profile or socket was used.

S4 is now **COMPLETE** against the plan: S4.1 and S4.3 were already approved and
user-accepted on the real screen; this chain closes S4.2 and drives S4.4's
SessionStart, UserPromptSubmit, Stop and SessionEnd closure. S4.4's explicitly
deferred PreToolUse/PostToolUse portion remains assigned to S7.6, not an open S4
item. S4b adds no widget, window, layout or rendering path. It can show the
existing fixed system-bubble component during a removal race, so no new
real-screen UI check is required.

The commits are individually approved, but the newest **linear** approved
push-through SHA is **`51b21b3`**. The intervening S5a red-only commits
`3ca5dea` and `f60e9e9` still lack their promised failing-first runs and formal
verdict, so they prevent a linear push through `463e707`; this S4b verdict does
not silently approve those unrelated commits.

## S5a conversation and planted-keyring closure (`3ca5dea`, `f60e9e9`, `905e5a3`, `fb55315`, `6b34512`)

**Explicit verdict for `3ca5dea`: APPROVED as the failing-first base,
cumulatively corrected by `f60e9e9` and `905e5a3`.** Its real-binary cases
drive the private-Xvfb UI with X input and clipboard selection, the production
helper and bundled Claude CLI through relay/netd to the fake TLS API. The
stream case therefore proves that a visible label grows before the held API
continues, not merely that a protocol row exists. BlackRobin's clean-export
red run on the prior implementation failed 17 of 26 e2e checks: there was no
growing bubble, no Stop row or interrupt behavior, and raw API/helper error
text appeared instead of the fixed sentences. The companion real-CLI error
suite failed its 401/429/529 cases and errored because the retry option did not
exist. The interrupt unit was already green and is correctly recorded as a
pin of existing SDK behavior, not claimed as an invented red.

**Explicit verdict for `f60e9e9`: APPROVED as the failing-first correction,
cumulatively completed by `905e5a3`.** It changes the contract from “two helper
errors make two bubbles” to one ending frame per prompt and adds the
second-ending-frame negative case. During green work its first fixture was
shown to be non-discriminating because an unconfirmed session is forgotten
after the first error; `905e5a3` fixes that setup by emitting
`session_opened` first. With that correction, removing the native no-busy
guard produces two “Agent error” bubbles and the test fails. This is valid
failing-first evidence for the intended production rule rather than a test
which passes because the validator discarded an unknown session.

**Explicit verdict for `905e5a3`: APPROVED.** The helper maps frame codes to
fixed user sentences and never renders a frame's message; a session error with
no running prompt is dropped as a second ending frame
(`src/agent_helper.c@905e5a3:244-301`). Stop is per-window, valid only for an
open busy session, emits one interrupt and suppresses that prompt's later
deltas/messages until its ending frame; a new prompt resets the stopping state
(`src/agent_helper.c@905e5a3:215-226,261-301,787-794`). The drawer owns one
stream label and buffer per window, finalizes exactly one message row, appends
“(stopped)” to the partial bubble, and returns focus to the input
(`src/agent_drawer.c@905e5a3:586-720,1126-1131`). All of this remains on the
GTK main context, and the stream buffer is allocated/destroyed with its drawer.

At the helper boundary, an SDK `AssistantMessage.error` discards its raw text
deltas and produces one error frame in place of the result; production keeps
the CLI's normal retry policy, while `CLAUDE_CODE_MAX_RETRIES=0` is added only
when hello carries the e2e test base URL
(`agent/host/zb_agent_host/chat.py@905e5a3:36-95,111-117`;
`agent/host/zb_agent_host/options.py@905e5a3:93-122`). The full-gate e2e passed
38/38 checks: streamed on-screen selection, stopped partial text, same-session
continuation, fixed 401/529 sentences, no raw server text, one error bubble,
and recovery when an interrupt ends with an error. The stop-state-reset and
second-ending-frame mutants both fail. The two new steps are dependencies of
the full `test` step, so they cannot be bypassed by the gate.

**Explicit verdict for `fb55315`: APPROVED as failing-first.** It plants an
API-key-shaped value through libsecret itself on a private D-Bus/keyring, then
uses the real binary and Send path. On `905e5a3`, two clean runs each failed
four of eight checks: the planted value started the helper and reached the fake
API. The regression requires no fake handoff seam: it checks the private
Secret Service precondition, no-token status and Secrets window, no connected
claim, no API request, no process copy, no row/log copy, and a fixed refusal
line (`tests/e2e/agent_secrets_test.py@fb55315:923-949`).

**Explicit verdict for `6b34512`: APPROVED.** Both Secret Service read paths
reuse the single Zig setup-token parser and additionally require its trimmed
slice to equal the complete stored value. The window lookup treats a malformed
item as absent, while the helper fetch returns `ZB_TOKEN_REFUSED` with only the
fixed `bad-shape` line. Neither branch duplicates the secret; libsecret's
original is released with `secret_password_free`, which wipes its allocation
(`src/agent_secrets.c@6b34512:107-116,201-224,319-344`). The no-fetch-check
mutant fails four assertions and the no-window-check mutant makes the connected
assertion fail. `planted-keyring` is registered in the full Secrets e2e; my
independent run passed the complete 222-check suite, including all eight
planted-item assertions. This closes the earlier planted-keyring S4 advisory.

I independently ran exact `6b34512` from a clean `git archive`, a fresh cache,
a 1,800-second bound and private Xvfb (seed `0xe1b462d8`): **Build Summary:
142/142 steps succeeded; 882/882 tests passed**. The top-level process exited
0. An intermediate “failed command” line was the output of an expected nested
negative-path test; its containing step passed. The EXIT trap deleted the
throwaway export, and no live display, socket, profile or real keyring was
used.

S5a adds visibly growing assistant bubbles, an active Stop state and fixed
error bubbles. Its code and automated closure are approved, and BlackRobin's
throwaway real-screen recipe has passed its private-Xvfb dry run; **S5a is now
ready for the user's real-screen check** of those three states. That visual
acceptance is still to be recorded, but it does not reveal a code or gate
blocker in this review. The planted-keyring fix draws no new UI.

All five requested commits are approved. The newest linear approved
push-through SHA is **`6b34512`**.

## S5a real-screen acceptance at `6b34512` (2026-10-16)

**Status: USER-ACCEPTED on the real screen.** The orchestrator ran a clean
export of `6b34512` on the user's NVIDIA X11 screen with the throwaway S5a
home/profile, fake TLS API and media source disabled. The user confirmed all
three new visible states:

- one assistant bubble grew in place to “Streaming slowly into one bubble”;
- Stop finalized the partial bubble as “This will be stopped (stopped)” and
  restored the Ready state; and
- authentication and overload failures rendered only the fixed sentences
  “Claude rejected the saved token. Open Account to replace it.” and “Claude
  is busy; try again shortly.”

Neither the protocol rows nor stderr contained `SERVER TEXT` or `API Error`.
The supplied screenshots also showed selected bubble text, reconfirming the
previously accepted copyable-text behavior. This closes S5a's required
real-screen check; no visual S5a blocker remains.

**Observation pending owner confirmation, not presently a product blocker.**
During the first, deliberately out-of-order try, the user submitted `stream`,
`stop`, `again` and `token` while the first turn was still streaming. The
queued `stop` turn eventually rendered “This will be stopped but this never
shows” without a Stop click. The saved rows show FIFO was preserved: the first
turn reached Ready before `stop` became Busy, and `stop` reached Ready before
`again`, `token` and `busy` ran. Production likewise refuses to flush a queued
prompt while the window is busy (`src/agent_helper.c:201-227`).

The test server does not actually stall forever. Its documented and enforced
`STALL_MAX_S = 30.0` makes an unset event resume after 30 seconds
(`tests/e2e/fake_anthropic_api.py:10-15,35,64-83`), at which point it emits the
second delta and completes normally. That exactly explains the observed text;
a later queued request or SDK retry need not release the stream. I sent
BlackRobin the row trace in Agent Mail 5860. BlackRobin is running a focused
`queued-during-stall` case to confirm that no later API request starts before
the held response ends. Until that answer lands, the explanation is marked
**probable fixture timeout, pending BlackRobin confirmation**. If the focused
case instead shows a later request advancing the held turn, reopen this as a
product FIFO blocker and require the requested failing-first regression.

## S6a capture red and queued-stall guard (`375c79b`, `ce2aa62`, `aca7638`)

**Explicit verdict for `375c79b`: BLOCKED as landed, cumulatively APPROVED with
`aca7638`.**
The captured fixture itself is safe to commit. I scanned the exact Git object,
not a recollection of the real-screen run: it contains zero case-insensitive
`sk-ant` occurrences, zero setup-token shapes, zero JWT-, hex- or base64-like
32-character runs, and zero `[A-Za-z0-9_-]{32,}` runs. Its pasted-code line is
exactly `<PASTED_CODE_MASKED>` and its token line is exactly `<TOKEN>`; no
asterisk run or visible tail from the user's pasted code remains. Client id,
challenge and state are placeholders, and the metadata contains no user path,
account or other credential. The committed fixture's SHA-256 is
`5cff86ab45fc5e2bbbe50153bfebae31ef90cf3dc2211690f813f351566e89e2`.

The fake is a faithful executable boundary for what this capture establishes:
it requires a pty, prints the captured lines and exact authorize parameter
order, generates fresh state/challenge values, logs synthetic received codes,
re-prompts for missing or foreign state, prints only a planted synthetic token,
and owns no socket. Its nine tests compare every output line with the fixture
and cover those boundary facts.

The blocking problem is in the red callback contract
(`tests/agent_auth_test.zig@375c79b:14-18,125-145,230-235`). It restricts the
opaque authorization code to URI-unreserved bytes and expressly rejects `+`.
The proposed D7b contract in Agent Mail 5858 instead permits visible non-space
ASCII, at most 512 bytes, with exactly one `#` delimiter. Because the captured
code is masked, it cannot prove that the provider will forever return only
`[A-Za-z0-9._~-]`; RFC 6749 Appendix A.11 likewise defines an authorization
code as opaque `1*VSCHAR`, not as an unreserved URI token. As written, the test
would force production to reject a terminal-safe code such as the unambiguous
query value `a%2Bb`. Fix the red forward so decoded visible punctuation is
accepted while SP, control bytes, DEL, `#`, malformed escapes and duplicated
parameters remain refused, or cite a provider guarantee and revise D7b before
the green. I mailed this BLOCKER to BlueBeaver as Agent Mail 5865. The red's
stale “rev 16.17” label is also to be corrected to rev 16.18 in its follow-up;
`ce2aa62` legitimately took 16.17.

**Explicit verdict for `aca7638`: APPROVED.** This follow-up closes both
findings without rewriting history. The red now applies form-query decoding
(`+` becomes SP and `%XX` becomes its byte), accepts decoded ASCII `0x21-0x7e`
except `#`, and has concrete passing cases for `%2B`, `%2F`, `%3D` and the
remaining visible punctuation. It retains negative cases for SP, CR, LF, ESC,
DEL, NUL, non-ASCII bytes, malformed escapes, `#`, empty and duplicated code;
the separate oracle and 10,000-pair generator use the same public contract.
The earlier unreserved-only green draft fails two of ten tests, so the
correction is red against the implementation it is meant to prevent. The
fixture-secret regression now uses the same 32-character threshold as the
independent review census. This closes Agent Mail 5865 and the associated
SHOULD-for-test in 5863.

**Explicit verdict for `ce2aa62`: APPROVED.** The real-helper half holds an API
response after its first delta, shows the queued user bubble, and proves for a
five-second interval that the fake has exactly one Messages request, the
assistant has neither ended nor gained text, and the drawer remains Busy. Stop
then produces `Held (stopped)`; only afterward does the queued prompt become
request two and receive its own answer. Releasing the old fake-server event at
the end proves its held text never reaches a row.

The scripted-helper half observes the other side of the native/helper boundary:
its frame log contains only the first prompt while that prompt is live, then the
queued prompt appears only after the interrupt is answered with the first
prompt's result. Thus the test does not infer FIFO merely from the UI or rely on
the real helper's independent `busy` refusal. Removing both native busy guards
makes 7 of 15 assertions fail, including an extra error bubble and held text.
BlackRobin's clean-export, private-Xvfb run passed the whole module, **53/53**.
BlueBeaver's subsequent clean-export, private-Xvfb S6a overlay gate also
included this registered module and the corrected auth tests: **Build Summary:
145/145 steps succeeded; 892/892 tests passed**. That gate is evidence for this
test chain; its not-yet-reviewed S6a production green receives a separate
verdict when committed.

This also closes the prior real-screen observation. The original rows preserve
FIFO, and the fake server explicitly resumes an unset stall after 30 seconds;
the unstopped response completed for that reason, not because a queued prompt
ended or advanced it. **Status: CLOSED by `ce2aa62` (fixture behavior, no
product defect).**

With `aca7638` correcting the red forward, all three commits are approved as a
linear chain. The newest approved push-through SHA is **`aca7638`**.

## S6 callback green and plan rev 16.18/16.18.1 (`bf3534d`, `12dcb61`, `7872d9a`, `a3bf4ee`)

**Explicit verdict for `bf3534d`: BLOCKED as landed, cumulatively APPROVED with
`a3bf4ee`.** Rev 16.18 correctly replaces the assumed browser callback with the
captured `claude setup-token` behavior: a manual callback navigation is caught
without loading it, `<code>#<state>` is typed only after the CLI prompt, the
one-shot helper uses a 4096-column pty and fd 4 for the resulting token, and the
auth view has an ephemeral app-owned context rather than a related browsing
view. Its callback, frame, paste, replay, popup and real-screen cases agree with
the capture and the accepted token boundary.

Two implementation-defining boundaries were nevertheless absent in this
revision:

1. **BLOCKER — the login-only egress exception was not mapped onto the current
   MS0 contract.** Production has one immutable `LaunchSpec.network`
   (`agent/host/zb_agent_host/sandbox.py:66-103`), one backend allowlist
   (`sandbox.py:47-51`), one `runtime/net.json` producer
   (`agent/host/zb_agent_host/setup.py:433-449,485`), and one app-configured
   netd (`src/app.zig:122-166`, `src/agent_net.zig:101-105`). Rev 16.18 said the
   login launch admits `platform.claude.com` while chat remains API-only, but it
   did not define a distinct capability, manifest, netd instance, ownership or
   lifecycle. Implementing that sentence by widening the existing manifest
   would have widened chat as well.
2. **BLOCKER — the fake-provider seam was deferred to the S6b red.** The S6
   split said its exact form and inertness would “come with S6b's red,” while
   section 7 says its seam table is the complete set of non-production inputs.
   A security-sensitive proxy/CA input needs its parser, consumer, TLS scope,
   refusal behavior and inertness fixed before the implementation tests build
   on it.

I mailed both findings as Agent Mail 5911. **Status: CLOSED by `a3bf4ee`.** Rev
16.18.1 adds a separate immutable `login_network()`/`login_launch_spec`, an
unchanged chat `network()`, a distinct `runtime/net-login.json` with no bridge
ports, and a second login-only netd whose stdin and socket directory end with
the one-shot helper (`plan:625-634`). It pins both allowlists, proves the chat
netd still refuses the platform host, and checks that no login netd or directory
survives. It also defines `ZIGBROWSER_AGENT_AUTH_TEST` in the exhaustive seam
table with exact loopback-proxy/regular-CA grammar, an ephemeral auth-context-only
consumer, host-scoped TLS trust, fail-before-window behavior, and a no-flag
inertness case (`plan:1180,2039,2055`). **Explicit verdict for `a3bf4ee`:
APPROVED.**

**Explicit verdict for `12dcb61`: APPROVED.** `src/agent_auth.zig:35-79`
implements the production callback decision without allocation or page-owned
code: scheme and host compare case-insensitively, explicit/default ports must
match, userinfo is refused, the raw path is exact, state is unique/decoded and
equal, and the unique code plus state is limited to visible ASCII other than
`#` and 512 bytes. Form-query decoding is strict: `+` becomes SP and malformed
`%XX` refuses (`src/agent_auth.zig:98-130`). `checkCallback` deliberately
recognizes a callback whose code is absent or unsafe so the UI can block it as
`code`, while every origin/path/state failure remains false. Nothing logs or
returns the untrusted value on failure.

The table tests cover default ports/case, lookalike hosts, userinfo, alternate
paths, missing/duplicated/malformed state and code, controls, non-ASCII,
punctuation and the exact length edge. The separate 10,000-pair oracle plus the
eleven reported killed mutants exercise the state, host, port, userinfo,
scheme, path, delimiter, form-decoding, byte-range and length guards. The build
registers both this Zig suite and the transcript-matching fake in the full gate
and in `test-agent-auth`; it does not bypass a production chain that exists in
this UI-free part of S6a. NIT: the module header still says rev 16.17, although
the implemented contract is rev 16.18.

Validation on a clean export of exact `12dcb61`, with a fresh cache and private
Xvfb:

- `zig build test-agent-auth --summary all`: **5/5 steps succeeded; 10/10 Zig
  tests passed**, and the fake-capture suite passed **9/9**.
- `timeout 1500 env -u WAYLAND_DISPLAY xvfb-run -a zig build test --summary
  all`: **Build Summary: 145/145 steps succeeded; 892/892 tests passed**.

The throwaway export was deleted immediately after the gate.

**Explicit verdict for `7872d9a`: APPROVED as a failing-first test commit.** It
is test-only and deliberately unregistered until its green. The native contract
requires exact envelopes/schemas, monotonic sequence and noncommitting rejected
frames, ordered login outcomes, bounded values, and the accepted code grammar;
its table and 10,000-string oracle cover the latter independently. The helper
tests drive the captured fake over a pty and pin prompt ordering, fd-4-only
token delivery, cancellation/EOF/timeout, exact authorize shape, fixed
environment and terminal width, escape stripping, malformed inputs and the
absence of token bytes from stdout/stderr. Against the parent there are no
`LoginValidator`/`login` implementations, so the committed red cannot silently
pass; the reported green draft also killed eight protocol and twelve helper
mutants. Its lack of build registration is appropriate only while red and must
end in the corresponding green.

`7872d9a` and `a3bf4ee` add only unregistered red tests and documentation, so
they do not change the production/build graph covered by the exact `12dcb61`
gate. With the plan blockers closed by `a3bf4ee`, every commit after origin is
now explicitly reviewed. The newest approved push-through SHA is
**`a3bf4ee`**.

## S6a part 3: login-network reds and netd green (`dbde6c9`, `10248df`, `69f2207`)

**Explicit verdict for `dbde6c9`: BLOCKED-for-tests.**
The six netd cases pin the correct privilege split: an explicit empty `ports`
list creates only `egress/proxy.sock`; the login manifest admits exactly the API
and platform hosts through vetted test addresses; a chat manifest still refuses
the platform host and keeps its two bridges; a test bridge cannot be smuggled
into the empty set; shutdown removes the socket directory; and nine ports remain
invalid. Reachability tests use the sealed netd fixture, so they exercise the
real manifest/parser/bwrap/serve chain without external network access. Three
of the six fail against the parent implementation, and the other three preserve
the surrounding fail-closed and cleanup contracts. But its own module contract
also says omission of the `ports` key preserves the built-in bridges
(`agent/host/tests/test_netd_login.py:8-9`), and none of the six cases exercises
that rule. This red must either gain that case or have its prose corrected
forward with the plan before it is a complete failing-first contract.

**Explicit verdict for `10248df`: BLOCKED-for-tests.** Its seven backend cases
correctly require a second immutable network capability, the unchanged chat
capability, an egress-only login launch spec, refusal when that egress directory
is absent, a backend-derived manifest, injection of a changed login capability,
and consumption of the resulting manifest by the real netd. The five reported
mutants cover the main abstraction gaps.

The red does not, however, test the commit point assigned to S6a by the approved
plan. `agent/host/tests/test_login_network.py:90-117` calls
`setup.login_net_manifest()` and manually writes its return value to a temporary
manifest, but it never drives `setup.stage()` or otherwise observes
`runtime/net-login.json`. Rev 16.18.1 requires the S6a backend test to prove
that setup publishes both manifests (`plan:627,631`). A green can therefore add
the pure producer and launch spec while forgetting the actual stage write, yet
pass all seven cases. Add a failing-first publication assertion in this slice;
deferring it to S6b would leave S6a green without its planned closure edge.

**Explicit verdict for `69f2207`: BLOCKED.** The production shape is otherwise
good. The outer process validates the manifest, turns the empty bridge set into
one fixed `--no-bridges` flag, refuses that internal flag on the outer command
line or together with a bridge port, and the sealed child consequently creates
only `egress/`. Cleanup tolerates the intentionally absent bridge directory.
Nonempty lists retain the 1-to-8 distinct-port validation, the test seam cannot
name a nonexistent bridge, and `test_netd_login` is registered in the full
gate. BlueBeaver reports a clean-export private-Xvfb gate at exact `69f2207`:
**Build Summary: 146/146 steps succeeded; 892/892 tests passed**, with four
killed mutants.

One advertised manifest rule remains the opposite of production. Rev 16.18.1
says a missing `ports` keeps the built-in two (`plan:628`), and the new red
repeats that statement (`agent/host/tests/test_netd_login.py:8-9`). Yet
`agent/host/zb_agent_host/netd.py:637-644` refuses a manifest without the key,
and `agent/host/tests/test_netd_manifest.py:148-154` deliberately retains
`"ports missing"` in its malformed table. The present behavior is the safer
fail-closed choice: a partially written login manifest must not silently gain
the two hook bridges. Correct the plan and red prose forward to say a partial
manifest missing `ports` remains invalid (while a missing/legacy manifest with
neither network key retains the historical defaults), or implement and test
the promised fallback. Do not leave the contract and implementation opposed.

I mailed both findings as Agent Mail 5925. I ran no local build or browser test
because BlackRobin already held the exclusive full-gate slot for S5b; this
review relies on exact diffs plus BlueBeaver's exact-commit gate above. Until
the two follow-ups land, none of the three requested commits is approved for
the linear prefix. The newest approved push-through SHA remains **`37518ea`**.

## S5b: default-on drawer and per-window session closure (`62d2b72`, `86255dd`)

**Explicit verdict for `62d2b72`: APPROVED as a failing-first and closure-test
commit.** `agent_default_on_test.py` drives the real binary with no flag or
variable, an explicit flag off, an environment off, a fresh data home, a popup
and a real configured fake helper. BlackRobin's clean-parent run at `69f2207`
failed 6 of 15 checks for the intended absent behavior: neither window had the
default icon, no-home Send retained the obsolete sentence and lacked the
runtime-missing status, and `stop_browser` did not object after a helper ran.
The test also verifies that the browser is torn down before the deliberate
AssertionError escapes.

`agent_window_sessions_test.py` was already green, which is acceptable here as
an S5.4 closure test rather than a fabricated red: S3b already implemented the
per-window state machine. It uses the real helper and CLI against the sealed TLS
fake API, not an app-side test double. Its two sequential prompts prove
window-local bubbles and request bodies; two distinct transcript filenames
prove distinct SDK session ids; each transcript contains exactly its own
prompt; neither transcript contains the token canary; and neither the
published `.claude` nor the decoy user's `~/.claude` receives a transcript
(`tests/e2e/agent_window_sessions_test.py:55-95`). Registering this existing
contract in the green is the relevant new coverage.

**Explicit verdict for `86255dd`: APPROVED, with two documentation SHOULDs.**
The production setting—not merely the test oracle—now defaults to `.on` in
`src/agent_config.zig`; the existing resolver still gives the explicit flag
precedence over the environment and the environment over the default. Normal
browsing startup applies the result before `zb_app_run`, and `zb_window_new`
consults it for every primary and related view. The C shim deliberately starts
off, so screenshot mode, which never calls `applyAgentDrawer`, remains
drawer-free. Explicit `--agent-drawer off` and `ZIGBROWSER_AGENT_DRAWER=off`
are both exercised, and the bogus-variable case now correctly falls back to
the on default.

With no provisioned home, Send adds the user bubble and reports
`unavailable/runtime-missing` with the same fixed
`ZB_AGENT_TEXT_RUNTIME` sentence as a configured helper whose runtime is
missing; no process starts. The helper-process guard walks the still-live
browser's descendant tree before teardown, recognizes the helper, netd and
relay command shapes, tears the browser down and only then raises. The
failing-first helper case proves that exact path. Agent tests explicitly opt
out because they intentionally press Send; the non-agent gate continues
through `slice2_common.stop_browser` directly or through its shared
`terminate`/runner wrappers. The detector is a live-descendant census rather
than durable execution history, so a helper that both started and disappeared
before teardown could evade it; that is an advisory test-hygiene limitation,
not a product-path defect, because no non-agent test interacts with the native
drawer and the entire default-on gate is green.

The two documentation SHOULDs were mailed as Agent Mail 5930:

1. `docs/agent-drawer.md:49-50` still describes the drawer as floating over the
   page without resizing it. The accepted user contract and production host
   dock it at the bottom and lay out the page above it (`plan:242`, user
   decision 2026-10-14).
2. `docs/agent-drawer.md:61-63` says the on-disk transcripts live at
   `agent-home/.claude/projects/`. The plan and the new e2e correctly establish
   `agent-home/state/projects/`; it appears as `.claude/projects` only inside
   the sandbox bind.

BlackRobin's exact-chain private-Xvfb validation reported focused results of
15/15 default-on, 15/15 sessions, 79/79 drawer, 63/63 netd-spawn and 56/56
icon checks. The first full gate had one unrelated 100 ms PagePort timeout
flake under load (the same binary then passed its 152 tests three times alone);
the second gate was **Build Summary: 148/148 steps succeeded; 892/892 tests
passed**. I did not start a competing browser run because BlueBeaver took the
exclusive gate slot in mail 5929.

S5b is therefore ready for the user's real-screen check at `86255dd` or a later
build containing it. The check should launch an ordinary page **without** an
agent-drawer flag, confirm the icon appears and the page remains drawn and
clickable, confirm open/drag/fold, and confirm that a fresh agent home produces
the fixed runtime-not-set-up status only after Send. The already-proven
windowless host makes this a default-at-launch qualification, not a reopening
of its NVIDIA rendering fix.

These later approvals cannot cross the earlier blocked S6a part-3 chain
(`dbde6c9`, `10248df`, `69f2207`). The newest linear approved push-through SHA
therefore remains **`37518ea`**.

### S5b real-screen acceptance and documentation closure

**Status: USER-ACCEPTED on `86255dd` (2026-10-19).** On the user's real
screen, with no drawer flag, the drawer appeared; each window retained its own
conversation; and a missing agent home showed the runtime-not-set-up state.
The user explicitly reported **“S 5b accepted.”** This closes S5b's requested
real-screen qualification.

**Explicit verdict for `13d6e9e`: APPROVED.** This docs-only follow-up closes
both SHOULDs from the `86255dd` review: it describes the production/user-chosen
docked panel and page resize, including the NVIDIA reason, and gives the real
on-disk transcript path `agent-home/state/projects/` while explaining its
`.claude/projects` sandbox view. No product or test behavior changes.

## S6a follow-ups, login helper, PagePort flake and MS1 red (`8ccd8c4`, `e33661d`, `edd2c6c`, `f73305e`, `0e41ae1`)

### Login-network cumulative closure

**Explicit verdict for `8ccd8c4`: APPROVED.** It closes both test/prose gaps
from the earlier S6a part-3 review without weakening the fail-closed behavior.
The plan and netd test now say that a partial manifest containing only one of
`egress` and `ports` is invalid; only an absent manifest or a legacy manifest
with neither key receives the built-in defaults. The new publication case
drives the real `setup.provision()` fixture and observes the stage result,
requiring a regular mode-0600 `runtime/net-login.json` equal to the production
producer beside an unchanged API-only `runtime/net.json`
(`agent/host/tests/test_login_network.py:107-117`). It therefore kills a green
that merely adds pure producers while forgetting the setup commit point.

BlueBeaver's clean-export private-Xvfb gate used exact `8ccd8c4` plus the later
`edd2c6c` files and reported **Build Summary: 151/151 steps succeeded; 900/900
tests passed**. The red was also exercised three times: all 8 login-network
cases failed before the backend drafts; removing the stage write from the
draft made the new publication case fail.

Consequently the earlier verdicts are cumulatively closed as follows:

| Commit | Cumulative verdict | Closure |
|---|---|---|
| `dbde6c9` | **APPROVED as failing-first** | `8ccd8c4` corrects its stale missing-`ports` prose to the production fail-closed rule. |
| `10248df` | **APPROVED as failing-first** | `8ccd8c4` adds the missing real-setup publication assertion. |
| `69f2207` | **APPROVED** | `8ccd8c4` aligns the plan/red contract with its safer partial-manifest refusal; the prior 146/146, 892/892 gate remains valid. |

**Explicit verdict for `e33661d`: APPROVED.** This docs-only rev 16.19.1 entry
faithfully records the already reviewed user result: S5b was accepted on the
real NVIDIA screen at `86255dd`, with the default icon, runtime-not-set-up
state, per-window conversations, two agent-home transcripts and an unchanged
decoy `~/.claude`. It changes no implementation or test behavior.

### S6a part 2 (`edd2c6c`)

**Explicit verdict for `edd2c6c`: BLOCKED.** The native frame validator is
bounded, exact and noncommitting on rejection, and the helper correctly uses a
wide pty, a fixed environment, process-group cleanup, fd-4-only token delivery
and a one-shot lifetime. The 151/151, 900/900 clean gate and the reported eight
protocol plus twelve helper killed mutants are good evidence for those covered
paths. Three production contracts remain uncovered and broken:

1. **BLOCKER — the authorize URL is not exact.**
   `agent/host/zb_agent_host/login.py:69-82` accepts the right parameter names,
   redirect URI, nonempty state and `response_type=code`, but it accepts changed
   or empty `code`, `scope`, `code_challenge_method`, `client_id` and
   `code_challenge`. The captured contract fixes `code=true`,
   `scope=user:inference` and `code_challenge_method=S256`
   (`plan:610-615`). A lookalike URL can therefore be forwarded as the CLI's
   authorize URL. Add near-miss table cases, require those fixed values and
   require nonempty client/challenge values (or explicitly pin the captured
   client id if that is the intended contract).
2. **BLOCKER — a later code overwrites the first pending code.**
   `login.py:222-227` assigns `self.code` unconditionally. If callback capture
   and a manual paste both arrive before the next CLI prompt, the second value
   replaces the first, contrary to D7b's “the first one to arrive is used”
   (`plan:430-432`). A slow-prompt regression must send two valid codes before
   `need_code` and prove only the first reaches the CLI.
3. **BLOCKER — terminal completion and token delivery race cancellation.**
   `login.py:189-206` performs an unsynchronized check-then-set in `end()`, so
   the PTY and frame threads can both emit terminal frames. `hand_off()` also
   writes and closes fd 4 before trying to claim `done`; a concurrent cancel
   can win `ended` while the PTY thread still delivers the token. Use a terminal
   claim separate from the screen lock and add deterministic interleaving tests
   proving one terminal frame and no fd-4 token when cancellation wins.

These findings were mailed to BlueBeaver as Agent Mail 5967. The green gate did
not exercise the missing interleavings, so it does not close them.

### PagePort timeout regression (`f73305e`)

**Explicit verdict for `f73305e`: APPROVED.** This is a test-only correction.
The old script created a pending promise with no reachable promise or resolver;
WebKit may collect it and end the call with “Completion handler for function
call is no longer reachable,” which production correctly maps to `EvalFailed`
rather than `Timeout`. The new script retains the resolver on the page global,
matching the existing `__zbHold1` pattern, while preserving the 100 ms timeout
and the same production PagePort chain (`src/webkit.zig:785-792`).

The root cause is demonstrated, not merely made less likely: BlackRobin's
standalone old form ended early in 31–42 ms in 3/3 runs while the held form
remained pending for 8 s in 3/3; the loaded live test failed with the exact old
message in 3/3 runs and passed 152/152 in 3/3 with the held resolver; the unit
binary also passed 152/152 three times. No production code changed. A separate
full gate was correctly deferred because BlueBeaver held the exclusive slot.

### MS1 failing-first Mac gate (`0e41ae1`)

**Explicit verdict for `0e41ae1`: BLOCKED-for-tests.** Its two-host runner
fails closed when the ARM host is absent, retains the real visible WKWebView
checks, requires runtime executing-arch readback rather than accepting `lipo`
alone, and compares the entitlement-key set with the ad-hoc signature. It is
unregistered, so it does not perturb the Linux gate.

MS1.1 can nevertheless false-green. `mac_universal_test.py:103-125` checks
only caller-supplied `--component` paths and accepts an empty list, while
`tests/mac/gate.sh:83-90` passes no component at all. A future green can thus
make only `zigBrowser` fat while omitting the plan's Python runtime, Claude CLI
and helper launcher, and no assertion checks compatibility of their non-exec
resources (`macOS plan:396-401`). The expected component/resource census must
come from a fixed or build-produced inventory, be nonempty and complete, and a
test must kill omission of any expected component. This was mailed to
JadeBeacon as Agent Mail 5968.

Two nonblocking stale comments should be corrected forward:
`mac_universal_test.py:21-24` says the test is not committed and Intel is
unreachable, and `packaging/macos/entitlements.plist:10-12` says the Intel Mac
is offline, while the red commit and its evidence say the host is reachable.

### Linear push-through boundary

The corrected login-network chain, S5b chain and acceptance documentation are
fully approved through **`e33661d`**. `edd2c6c` is the next commit and remains
blocked, so later individual approval of `f73305e` cannot advance the linear
prefix; `0e41ae1` is independently blocked-for-tests. The newest approved
push-through SHA from `37518ea` is therefore **`e33661d`**.

## S6a backend green/login-contract red and MS1 census follow-up (`68948db`, `71abc6f`, `fd4178b`)

### S6a part-3 backend green

**Explicit verdict for `68948db`: APPROVED.** The new login network is a
separate immutable backend capability: it retains the chat endpoint and socket
directory, expands only the login allowlist to the API and platform hosts, and
has no bridge ports (`sandbox.py:320-332`). Supplying no capability to the
ordinary `launch_spec` still selects `network()`, so the chat launch stays
API-only with both bridges. The login launch selects `login_network()` and
derives an egress-only read-only mount; missing egress still refuses before
launch. JadeBeacon independently approved these `SandboxBackend` seam changes
in Agent Mail 5962.

`setup.login_net_manifest()` is a direct projection of that capability, and
the real staging path atomically writes `runtime/net-login.json` mode 0600
beside the unchanged chat manifest (`setup.py:453-463,498-500`). The registered
eight-case suite observes the immutable capability, default chat path,
egress-only launch, missing-directory refusal, injected capability propagation,
real setup publication and real netd consumption. It therefore closes the
previous pure-producer/commit-point gap without bypassing production.

BlueBeaver's clean-export private-Xvfb gate on the exact green content reported
**Build Summary: 152/152 steps succeeded; 900/900 tests passed**, with the login
network module passing 8/8. The reported mutants remove or collapse each main
edge, including the setup write. No additional local gate was started because
BlueBeaver retained the exclusive slot for the next green.

### Login-helper contract red

**Explicit verdict for `71abc6f`: APPROVED as failing-first.** Its fixed-value
table accepts both captured authorize origins and refuses altered `code`,
response type, scope, challenge method, client id, challenge and state, including
duplicate names; the end-to-end altered-scope case exercises the helper rather
than only the parser. The held-prompt fixture sends callback and pasted codes
before the next prompt and proves that only the first reaches the CLI. The
terminal tests include deterministic cancel-first and done-first orderings plus
300 barrier-raced cancel/done/timeout rounds; they require one terminal frame
and fd-4 token bytes only when `done` wins (`test_login_contract.py:147-188`).

Against the clean parent, BlueBeaver reports 15 failures and one error on each
of three runs; the two positive URL guards and done-first control already pass.
That is adequate red-first evidence for all three blockers in Agent Mail 5967.
The module is correctly unregistered until its forward green.

### MS1 component-census follow-up

**Explicit verdict for `fd4178b`: BLOCKED-for-tests.** The commit materially
improves `0e41ae1`: a checked-in manifest names the four required native roles
and an agent-runtime resource; the Mac gate now supplies the bundle root and
manifest; the whole tree is scanned for Mach-O files; every discovered Mach-O
must be fat; required roles/resources must be present; and empty inventory or
empty scan fails. Its pure 6-case unit suite kills omission of the Claude CLI,
a single-arch component, an empty scan, a missing resource and an empty
component inventory. The stale Intel comments and malformed XML comment are
also fixed forward. The Intel gate remains red for the intended missing fat
bundle/signature/readback conditions.

Two promised MS1.1 edges can still false-green:

1. **BLOCKER-for-tests — a failed file-type probe disappears from the census.**
   `tests/e2e/mac_universal_test.py:103-106` invokes `file -b` directly but
   ignores its exit status and stderr. Error/empty output is treated as “not
   Mach-O,” so an unreadable or otherwise unprobeable bundled file is silently
   omitted. Use the fail-closed command wrapper (or check the result explicitly)
   and add a mocked/fixture case proving probe failure rejects the bundle.
2. **BLOCKER-for-tests — resource compatibility is still only prose.**
   `component_census` checks that the declared resource exists in one combined
   tree (`mac_universal_test.py:115-127`). The inventory comment promises that
   a future `build-dmg.sh` will compare the per-arch trees before lipo, but no red
   test requires that comparison and the script does not implement it. MS1.1
   explicitly requires compatible non-executable resources before
   `lipo -create` (`macOS plan:396-401`). Add a pure two-tree digest/map oracle
   whose mismatched-resource fixture fails, then route the green packaging step
   through it.

**SHOULD — bind roles to their expected paths.** Required components are
satisfied by a set of basenames (`mac_universal_test.py:119-123`). A stray
Mach-O named `python3`, `claude` or `zb-claude` elsewhere can satisfy a missing
runtime role. Exact relative paths or unique allowed path patterns in the fixed
inventory, plus a wrong-location decoy, would make the census genuinely
role-complete. These findings were mailed to JadeBeacon as Agent Mail 5974.

### Linear push-through boundary

The orchestrator has pushed through `e33661d`. Although `68948db` and
`71abc6f` are individually approved, the earlier production commit `edd2c6c`
still awaits the green for its three blockers, and `fd4178b` remains
blocked-for-tests. The newest approved linear push-through SHA remains
**`e33661d`**.

## MS1 fail-closed census and two-tree resource red follow-up (`ec434bc`)

**Explicit verdict for `ec434bc`: APPROVED as failing-first.** This follow-up
cumulatively closes both BLOCKER-for-tests findings on `fd4178b`:

- `scan_macho` now sends every real, non-symlink file through `probe_archs` and
  `census_scan`; a nonzero `file` result, any stderr, or BSD `file`'s rc-0
  `cannot open` body raises `FailClosed` and propagates out of the whole scan
  (`mac_universal_test.py:93-127`). The production probe and the pure scan are
  both covered by the new failure cases (`mac_universal_census_test.py:97-124`).
- `resource_compat` requires each declared resource in both arch trees and
  equal digests (`mac_universal_test.py:169-182`). The routable CLI hashes the
  real files from each tree and fails if the resource inventory is empty,
  missing or different (`mac_resource_compat.py:23-55`). The pure cases cover
  equality, mismatch and one-tree absence; the reported CLI smoke gives RC 1
  for differing `runtime.json` and RC 0 for identical input. My independent
  repeat produced the same RCs.

The previous basename false-positive is also materially narrowed: the fixed
inventory supplies full bundle-relative patterns, `component_census` matches
against the relative paths, and a fat `python3` in a decoy directory no longer
satisfies the runtime role (`universal_components.json:15-22`;
`mac_universal_test.py:147-166`; `mac_universal_census_test.py:66-74`). The
off-Mac suite passed **12/12** locally with both display variables removed.
JadeBeacon also reports that all relevant mutants fail and that the updated
census executes on the Intel Mac; the complete Mac gate remains intentionally
red (RC 2) until the universal bundle, ARM leg and executing-arch seam land.

**Nonblocking SHOULD before the MS1 green:** the Claude CLI pattern contains a
single version-directory wildcard, but Python `fnmatch.fnmatch` lets `*` cross
`/`. Consequently a deeper path such as
`venv/lib/decoy/nested/site-packages/.../claude` also matches. Use a
segment-aware matcher such as `PurePosixPath.match` (or explicitly constrain
the version segment) and add that wrong-depth decoy alongside the existing
wrong-location Python test. This does not reopen the two 5974 blockers—the
path-binding item was a SHOULD—but the green should not describe the pattern
as exact until this is tightened. The subprocess probe should also inherit a
bounded timeout before the final fail-closed gate, so a wedged `file` process
cannot hang MS1.4 indefinitely.

No full Linux gate was run for this unregistered, Mac-only red slice. The
newest approved linear push-through SHA remains **`e33661d`**: `edd2c6c` is
still the earlier blocked production commit, and MS1 remains red by design.

## S6a login-helper closure (`da3028f` on red `71abc6f`)

**Explicit verdict for `da3028f`: APPROVED.** It closes all three production
blockers on `edd2c6c`:

1. `authorize_url` now requires exactly the eight parameter names, the captured
   fixed values (`code=true`, `response_type=code`, the callback URI,
   `scope=user:inference`, `S256`), a UUID-shaped client id, a 43-character
   base64url PKCE challenge and nonempty state (`login.py:53-91`). The table
   covers changed/empty fixed fields, malformed client/challenge/state and
   duplicate names, and the real helper path refuses an altered scope
   (`test_login_contract.py:40-82`).
2. Code-frame handling assigns `self.code` only while no code is pending, under
   the existing screen lock; `answer` consumes that pending value only for the
   next prompt (`login.py:195-199,249-255`). The slow-CLI case delivers two
   values before any prompt and observes only the first at the CLI
   (`test_login_contract.py:85-110`).
3. `claim`, serialized by a lock separate from the screen lock, is the sole
   terminal owner. `hand_off` claims before touching fd 4, so a winning cancel
   prevents token delivery; a winning completion writes/closes fd 4 before its
   one `done`, and a failed write still owns exactly one `error`
   (`login.py:201-233`). Deterministic cancel-first and done-first tests plus
   300 three-way cancel/done/timeout races require one terminal frame and token
   bytes only with `done` (`test_login_contract.py:123-188`).

The red `71abc6f` was already approved as failing-first: it failed on the old
helper and directly exercises these three contracts. The green registers that
module in both `test` and `test-agent-auth`. BlueBeaver's clean-export,
private-Xvfb gate on the resulting exact content reported **Build Summary:
153/153 steps succeeded; 900/900 tests passed**; `test_login_contract` passed
8/8 and `test_login` 16/16. Five targeted mutants each failed in three runs.
My independent narrow run passed all **24/24** cases across the two modules.

Consequently **`edd2c6c` is cumulatively APPROVED** by its original coverage,
the failing-first `71abc6f` and this green. S6a is complete through this helper
and the previously approved callback, protocol and isolated login-network
slices.

For the linear range, `ec434bc` also cumulatively closes the MS1.1 false-green
findings that blocked `0e41ae1`/`fd4178b`; those commits are **APPROVED as
failing-first** while the separately invoked Mac gate remains intentionally
red until its later universal-build green. `f73305e`, `68948db`, `71abc6f` and
the intervening review commits are already approved. The newest approved
linear push-through SHA after `e33661d` is therefore **`da3028f`**.

## MS1 census advisories and macOS plan rev 7 (`d48b71c`, `99f11b1`)

### Census follow-up

**Explicit verdict for `d48b71c`: APPROVED.** `path_matches` requires equal
segment counts and applies `fnmatch` within each segment, so the version
wildcard cannot consume `/`; the new extra-depth Claude decoy kills the old
whole-string matcher (`mac_universal_test.py:93-101,175-181`;
`mac_universal_census_test.py:76-85`). The default `file` invocation now has a
30-second subprocess timeout and maps `TimeoutExpired` to `FailClosed`, while
retaining the existing rc/stderr/body checks (`mac_universal_test.py:103-125`).
The timeout fixture was red on the old exception path, and the complete narrow
suite passed **14/14** locally with both display variables removed. This closes
both nonblocking SHOULDs from review `378b37b`.

### Mac plan rev 7

Rev 7 **does bind the deferral to MS5's red**, rather than merely mentioning it
in history: MS1.1 says the three roles and compatibility check enter in MS5's
red (`macOS plan:423-437`), and Behavior MS5.1c requires exact paths for
`python-runtime`, `claude-cli` and `helper-launcher`, the two-tree oracle before
lipo, a red single-arch/mismatched fixture and a fail-closed green gate
(`macOS plan:921-935`). That satisfies the orchestrator's requested ownership
and red-first placement in principle.

**Explicit verdict for `99f11b1`: BLOCKED (two implementation-contract
contradictions must be resolved before the MS1 green).**

1. **BLOCKER — the helper launcher is not a Mach-O.** MS5.1c says all three
   added roles must be fat Mach-O entries. Production creates `zb-claude` from
   a Python shebang template (`agent/host/zb_agent_host/token.py:100-140`) and
   writes it to `runtime/bin/zb-claude` during setup
   (`setup.py:470-503`); the current inventory instead names the nonexistent
   `venv/bin/zb-claude`. Because `component_census` searches roles only inside
   the Mach-O map, the proposed MS5 red can never become green. Rev 8 must give
   the inventory role kinds: native Python/Claude CLI require fat slices, while
   the exact regular executable launcher path requires presence plus compatible
   bytes across the arch trees (or explicitly plan a new native launcher).
2. **BLOCKER — browser-only MS1 has no defined compatible resource.** The
   current inventory's sole resource is agent-runtime `runtime.json`, which rev
   7 defers to MS5. Removing it leaves an empty resource list, but the routable
   oracle deliberately fails closed on an empty list
   (`mac_resource_compat.py:41-48`). Keeping it makes browser-only MS1
   impossible. Yet rev 7 says MS1's two-tree resource oracle is unchanged and
   still runs. Rev 8 must either name and stage the browser resource(s) compared
   in both MS1 arch trees, or explicitly move the first production
   resource-compat invocation to MS5 and align MS1.1 and the empty-resource
   contract. The MS1 green must not silently delete `runtime.json` and skip the
   oracle while claiming the mechanism is unchanged.

The browser-only scope itself is evidence-backed: `build.zig:163-173` installs
only the browser by default and exposes the agent runtime as a separate step.
The block is therefore not against the scope decision; it is against an
inventory/test contract that cannot represent the artifacts the revised
milestones actually ship. Findings were mailed to JadeBeacon before the MS1
green.

## S6b1 split and paste-path red (`2713c20`, `f18a5f1`)

### Plan rev 16.18.3

The architectural split is sound. S6b1 can prove the Secrets-window → native
login owner → dedicated login netd → sandboxed one-shot helper → fd 4 → S4
store chain without pretending that the auth WebView already exists. The plan
also keeps chat's network capability unchanged, gives the login netd its own
directory and lifetime, and leaves the callback/isolation surface wholly in
S6b2 (`plan:2053-2073`). Moving that ownership into the new
`agent_login.c` avoids coupling login lifetime to the long-lived chat helper.

**Explicit verdict for `2713c20`: BLOCKED (one slice-gate contract is still
missing).** The global UI rule says every UI slice adds and names its own
real-hardware case and cannot be approved before the user's screen passes it
(`plan:1209-1235,1393`). S6b1 adds four Secrets-window controls and seven
sentences, and its security boundary explicitly depends on discovering whether
the real `claude setup-token` needs another writable config path
(`plan:2054-2064`). Nevertheless the split assigns “the real-screen check”
only to S6b2 (`plan:2073`), and the login-network census still says merely
“during S6b's” check (`plan:639`). Rev 16.18.4 must give **S6b1 its own named
real-screen case**: exercise the paste UI and fixed sentences with the real
setup-token flow, record the CONNECT census, and prove the current read-only
mounts suffice (or revise them before S6b1 approval). S6b2 then keeps its
separate auth-window/callback/isolation real-screen case. This prevents the
new UI and the allowlist exception from landing one slice before their required
hardware and real-CLI qualification.

### Failing-first e2e

The committed red is genuinely red at the outer production trigger: it opens
the drawer and Secrets window with X input, clicks the planned Sign-in control,
and observes the store/fake/lifetime boundaries rather than calling native
login functions directly. The fake's scratchpad relocation is coherent with
the sandbox, contains only a synthetic setup-token-shaped canary, and its
narrow test passes **10/10**. `py_compile` also passes for all five changed
Python files. BlueBeaver supplied repeatable clean-export red evidence: three
runs, each 15 checks with the same seven intended failures.

**Explicit verdict for `f18a5f1`: BLOCKED-for-tests.** Its direction and red
evidence are accepted, but a correct green cannot satisfy the committed test
as written and several claims are not actually proved:

1. **BLOCKER-for-tests — process census false-positive.** `procs()` matches a
   needle anywhere in every argv, so `login_netds()` counts bwrap/launcher and
   `--serve` wrappers as netd processes (`agent_login_test.py:161-177`). The
   `during-sign-in` assertion requires exactly one (`:255-265`). Restrict the
   census to the real serving process, using the existing netd-launcher pattern.
   BlueBeaver independently hit this in the green draft.
2. **BLOCKER-for-tests — the inert X input is not aimed.** After discovering
   the Secrets toplevel, the no-window-manager Xvfb case sends Alt+I without
   focusing that window (`:327-344`). A correct mnemonic therefore remains
   unreachable. Focus the named Secrets toplevel before input and retain the
   private-display guard. BlueBeaver independently hit this too.
3. **BLOCKER-for-tests — “paste path” never pastes and never rejects malformed
   input.** `SignIn.paste` synthesizes one key at a time (`:83-92,146-150`),
   despite the contract being a pasted `<code>#<state>`. Use the existing
   private-Xvfb `Clipboard` plus Ctrl+V for this synthetic, non-secret code, and
   add a malformed value (no `#`, extra `#`, internal whitespace, or invalid
   byte) that shows “That doesn't look like a sign-in code.”, sends no code to
   the fake, and stores nothing. Otherwise a product that breaks Ctrl+V or
   forwards grammar-invalid input passes S6.4.
4. **BLOCKER-for-tests — close does not prove its stated teardown.** The file
   header and commit message say closing the Secrets window leaves no login
   helper, netd or directory, but `case_close` checks only the cancelled row,
   empty store, netd and directory (`:293-305`); only `case_cancel` checks
   `login_helpers() == []` (`:276-288`). Add the helper assertion before the
   enclosing browser teardown, so `Browser.stop()` cannot mask an orphan.

**SHOULD for the green:** assert the fixed `SECRETS text` sentences at the
relevant states and add focused failure-path coverage for `error-network` and
`error-store`; the plan exposes those as UI contracts, but this red currently
reads only `rect`, `login` and `status`. Also remove the unused `shutil`,
`subprocess` and `e2e_cli` parameter while fixing the test.

No browser or full gate was run: the e2e is intentionally unregistered/red and
JadeBeacon held the gate slot. Only the display-free fake unit test and Python
syntax checks were run locally.

## macOS plan rev 8 (`774ce31`)

Rev 8 **closes the first rev-7 representation blocker**. It now types
`python-runtime` and `claude-cli` as fat native components while classifying
the generated `runtime/bin/zb-claude` Python wrapper as a byte-compatible
resource (`macOS plan:948-974`). That matches production's shebang template and
real output path; the prior impossible `venv/bin/zb-claude` Mach-O role is gone.

**Explicit verdict for `774ce31`: BLOCKED (the empty-resource exception is
prose-only, not a fail-closed phase contract).** Rev 8 declares MS1's
`resources: []`, but resolves the oracle conflict by not invoking
`resource_compat` at all (`macOS plan:447-463`). There is no typed milestone or
policy field consumed by the oracle, nor a red test proving that empty is
accepted only for browser-only MS1 and refused for MS5. Thus an implementation
can delete the invocation (or accidentally ship an undeclared resource) and
look identical to the intended exception; the oracle's current
fail-closed-on-empty rule never sees it.

Rev 9 must make the exception executable and mutation-resistant. For example,
add an explicit inventory policy/milestone value whose only legal MS1 state is
`components={browser}, resources=[]`, still invoke a validating census/oracle
entry point, and add tests that (a) this exact MS1 state passes, (b) empty
resources without the MS1 declaration fail, and (c) MS5's resource-bearing
inventory remains nonempty/fail-closed. An equivalent independent MS1 oracle
is acceptable, but a build-script conditional that merely skips
`mac_resource_compat.py` is not. The MS5 role/resource typing itself is
approved; this finding is only about preventing the MS1 exception from
becoming a generic empty-list bypass.

Because `2713c20` is the first commit after the already approved/pushed S6a
tip and is blocked, the newest approved linear push-through SHA remains
**`da3028f`**.

## S6b1 real-screen/census plan and MS1 resource phase (`4657083`, `c53b580`)

### Chat-drawer plan rev 16.18.4

Rev 16.18.4 closes nearly all of review 5994/5996's missing contracts. It
names `signin-paste`, makes the fake-CLI UI run use a throwaway file store
instead of the user's keyring, exercises clipboard paste and every fixed
sentence, adds malformed/foreign-state, Cancel, close, network/store failure
and helper/netd cleanup cases, makes the authorize URL selectable/copyable,
and defines an e2e-only netd census containing only distinct host, port and
allowed/refused outcome (`plan:2077-2108`). Part B also uses a throwaway file
store, requires the user's explicit consent, requires revocation of the minted
long-lived token, and refuses to widen mounts silently.

**Explicit verdict for `4657083`: BLOCKED (one approval-condition
contradiction remains).** The network exception still says the real CLI census
must show no target outside the two allowlisted hosts *before S6b is approved*
(`plan:639`), and the finding this revision answers required S6b1's own
real-CLI/mount/census qualification. But the new slice gate says only that
S6b1 cannot be approved before fake-only Part A passes (`plan:2100`), then
allows real-CLI Part B to move to S6b2 when the user declines
(`plan:2108`). That permits S6b1 approval while neither the production CLI
mounts nor the exceptional allowlist has been observed. Preserve the user's
absolute right to decline, but make the outcome fail closed: Part B requires
explicit consent; if consent is declined, no real sign-in is run and S6b1
remains unapproved (or explicitly redefine the exception as provisional until
all of S6b is complete, rather than claiming 5994 is closed for S6b1).

No browser run or live sign-in was performed for this docs-only review.
`git diff --check 4657083^ 4657083` passed.

### MS1 resource phase gate

**Explicit verdict for `c53b580`: BLOCKED-for-tests.** The new phase entry
point is called rather than skipped, rejects empty resources for MS5 and
unknown/lowercase labels, and retains the two-tree mismatch oracle for
nonempty resources (`mac_universal_test.py:186-208`;
`mac_universal_census_test.py:174-209`). The narrow off-display suite passes
**19/19**.

However, the exception is keyed only by the caller-provided string `MS1`.
`mac_resource_compat.py` loads the manifest but passes only its `resources`
list into `resource_phase` (`mac_resource_compat.py:34-53`); neither the
oracle nor the tests see `components`. I supplied a manifest with
`components=[python-runtime]`, `resources=[]` and invoked the real CLI with
`--milestone MS1`; it printed `PASS mac-universal 1 assertions` and returned
**0**. Thus the commit does not enforce the requested exact browser-only MS1
state, and any caller can relabel a resource-bearing or incompletely declared
bundle as MS1 to bypass resource compatibility.

Pass the loaded inventory (or an independently derived bundle phase) through
the gate and accept empty only when the milestone is exactly `MS1` **and** the
inventory is exactly one browser component at the fixed browser path with no
resources. Add negatives for an extra/non-browser component, a missing browser
component and `--milestone MS1` against an MS5-shaped empty manifest. The
current MS5/unknown and nonempty mismatch cases should remain.

The concurrent macOS-plan edit landed as `f207087` while this review was in
progress; it was not part of the requested pair and was not reviewed here.
`git diff --check c53b580^ c53b580` passed. With both requested commits
blocked, the newest approved linear push-through SHA remains **`da3028f`**.

## S5c design, S6b1 qualification, and MS1 exact-shape follow-ups (`5ad5c88`, `2e725c7`, `91b6f81`, `58551bb`, `50bc1bd`)

### S5c plan rev 16.20 and 16.20.1

The private-Xvfb probe results in rev 16.20 are useful and the two user
decisions are accepted: long unbroken runs should gain display-only break
opportunities, and the near-term credential fix is transcript cleanup while
the token stand-in becomes the named deferred `SX-standin` slice. The plan is
not yet implementation-ready, however.

**Explicit verdict for `5ad5c88`: BLOCKED.** The appended S5.6 contract
contradicts the still-active acceptance test immediately above it:

1. `plan:2022-2027` combines 50,000 deltas and a 2 MiB final under a 64 MiB
   RSS bound and requires a `DRAWER idles` row, while `plan:2037-2039` removes
   that row, limits the 64 MiB claim to the small-text flood, and permits 200
   MiB for a maximum reply. Replace the old case with separate authoritative
   flood and maximum-reply cases instead of leaving both contracts active.
2. `plan:2035` says every reply is whole with “no size cut”, while
   `plan:2039-2041` retains the helper's 256 KiB cap. The intended decision is
   no *new* 32 KiB cut below the existing cap; state that precisely.
3. Exact-copy coverage must include whole and partial selections crossing an
   inserted U+200B, multibyte UTF-8, and source text that already contains
   U+200B. Define what counts as a character/whitespace/run, so cleanup cannot
   strip a user's original zero-width space.
4. The single pending idle needs an explicit destruction contract and red:
   cancel/remove it when a drawer, window or session dies, and prove no late
   UI update or use-after-free.
5. S5c-1 visibly changes wrapping, copying and fold responsiveness but names
   no section 7.1 real-screen check. Add a case for the user's real display;
   private-Xvfb timing remains the automated gate.

**Explicit verdict for `2e725c7`: BLOCKED.** “Cleanup now, stand-in later” is
an accepted scope decision, but the transcript scrub has no safe persistence
or failure protocol yet:

1. The scrub must finish successfully before the helper emits the terminal
   result/error and before any queued next prompt begins. Open/read/write/fsync
   failure must fail closed with a fixed sentence and stop/refuse that session.
2. The plan must choose a mutation compatible with a persistent CLI process.
   A variable-length rewrite or atomic replacement can leave a CLI that still
   owns the old file descriptor appending to an unlinked inode. Use a proven
   close/reopen boundary, or a bounded equal-length in-place overwrite plus
   fsync, and test that later turns preserve a valid transcript.
3. A crash after the server echo reaches disk but before the reply ends leaves
   the token indefinitely. Add startup/pre-session recovery that cleans this
   residue before a new session, with a kill-at-that-cut test, or obtain an
   explicit user acceptance of that residual risk.
4. Replace stale `plan:2044-2048`: the helper stderr ring no longer exists and
   an app-side redactor cannot independently expose the canary because raw API
   text never reaches the app. Specify exactly which saved fields/patterns are
   scrubbed. The automation-token transcript canary is not a known helper
   value unless the helper actually receives it, so either define a general
   server-error scrub or remove that assertion.

These findings were mailed to BlackRobin as Agent Mail 6009.

### S6b1 real-CLI qualification closure

**Explicit verdict for `91b6f81`: APPROVED.** The revision makes both
`signin-paste` parts prerequisites for S6b1 approval. Part B requires explicit
user consent, the real built app and setup-token CLI, the host/port-only netd
census, and a committed record with no target outside the two declared hosts;
declining correctly means no run and leaves S6b1 and later S6 slices
unapproved (`plan:639`). This cumulatively closes the approval-condition
blocker on `4657083`. Agent Mail 6008 records the verdict.

### MS1 exact browser-only empty-resource phase

**Explicit verdict for `58551bb`: APPROVED.** `mac_resource_compat.py` now
passes the whole manifest into `resource_phase`, and the empty-resource
exception requires the exact fixed bundle shape: milestone `MS1`, one
component at `bin/zigBrowser`, and no resources. MS5, unknown milestones,
extra components, a non-browser path, and an MS5-shaped inventory relabeled
MS1 all fail closed. The display-free suite passes **22/22**. An independent
probe of the former bypass returned **1** for an MS1 manifest containing only
`venv/bin/python3`, while the exact browser-only manifest returned **0**.
This cumulatively closes the blocker on `c53b580`.

**Explicit verdict for `50bc1bd`: APPROVED.** Mac plan rev 9 now describes
the same whole-inventory, exact-path phase gate and binds the MS1 green to
calling it rather than silently skipping the resource oracle. The optional
component `role` remains descriptive; the executable bundle identity is the
fixed bundle-relative path, which is the contract the plan and oracle enforce.
Agent Mail 6010 records both MS1 verdicts.

`git diff --check` passed for all five reviewed commits. No browser or full
gate was run: these are plan/test-only changes, and BlueBeaver held the gate
slot. Because `5ad5c88` is blocked and earlier S6b1 work is not yet green, the
newest approved linear push-through SHA remains **`da3028f`**.

## S5c plan rev 16.20.2 (`1f0c04e`)

Rev 16.20.2 is a substantial correction. It replaces, rather than appends to,
the stale S5.6/S5.7 text. The S5.6 design now has one coherent contract: the
64 MiB bound applies only to the 50,000-delta case, the larger bubble has its
own 200 MiB bound, there is no `DRAWER idles` row, and “no cut” means no new
cut below the existing 256 KiB message cap (`plan:2021-2070`). It precisely
defines runs and whitespace, preserves an original-text copy, covers partial
and whole selections across inserted U+200B with multibyte and original-U+200B
cases, removes the one pending idle on every ending and destruction path, and
names the `long-run` real-screen check (`plan:2035-2094`). The original S5.6
findings in Agent Mail 6009 are therefore **closed by `1f0c04e`**.

The S5.7 rewrite also correctly drops the nonexistent stderr ring and the
non-load-bearing app redactor, scopes the scrub to transcripts, chooses an
equal-length in-place `pwrite` plus `fsync`, orders the ordinary prompt scrub
before the ending frame, and adds start/close sweeps, fail-closed exit and a
kill/restart residue test. Those decisions close most of the earlier finding,
but three load-bearing gaps remain.

**Explicit verdict for `1f0c04e`: BLOCKED.**

1. **BLOCKER — a post-result write can survive indefinitely.** The contract
   scrubs after `ResultMessage` and before the helper's ending frame, but then
   explicitly permits a CLI record written after `ResultMessage`, promising
   only that a future scrub will catch it (`plan:2126-2139`). If the user sends
   no next prompt and leaves the helper/session open, neither close nor helper
   start occurs; the token remains past the user-accepted “until the reply
   ends” window. The plan must either prove with a real-CLI test that all
   transcript writes precede delivery of `ResultMessage`, or introduce a
   deterministic quiescence/monitoring barrier that catches later appends
   before exposing the ending frame. A future prompt/close/restart is not a
   security boundary.
2. **BLOCKER — the incremental cursor is not fail-closed.** A path-only scan
   offset can skip secrets after the JSONL is replaced with a new inode or
   truncated and regrown (`plan:2121-2124`). Track file identity and size,
   reset to zero on inode change or shrink, and add both red cases. Also, 511
   bytes cannot be asserted as a sufficient overlap for the unbounded generic
   pattern `{20,}`. Bound the credential shape to an approved finite maximum
   and derive/name the overlap, or use a streaming/full scan correct for the
   unbounded form. The security and UI bounds (64, 128, 256 KiB and the scan
   overlap) should be named constants rather than independent literals.
3. **BLOCKER — `pause_before_scrub` is outside the exclusive test-seam
   contract.** The crash test introduces it in `hello.e2e`
   (`plan:2147-2150`), but section 7 says its tables contain the only
   non-production inputs and lists no such helper-carried seam
   (`plan:1170-1195`). Define its owner, external name/value, exact hello field,
   validation, `--e2e-protocol` plus exact-test-base gating and production
   inertness red.

**BLOCKER-for-tests:** split the failure-frame promise by lifecycle. At prompt
end, scrub failure replaces `result` with `error sdk`; during idle
`end_session` or shutdown there is no “prompt ending frame,” so the plan must
state whether `session_ended` is suppressed and exit 3 is the sole observable.
The red suite must inject open, read, short-`pwrite` and `fsync` failures;
chmod/read-only alone proves only one of the enumerated failures.

BlackRobin supplied genuine S5c-1 failing-first evidence in Agent Mail 6012:
the app flood, unbroken text, overflow/interrupt and real-chain cases fail;
all four helper flood checks fail; and the pure Zig break test does not compile
because `breakRuns` is absent. That evidence supports the red but does not
change the plan verdict. Findings were mailed as Agent Mail 6013.

`git diff --check 1f0c04e^ 1f0c04e` passed. No browser or full gate was run:
the reviewed commit is docs-only and BlueBeaver holds the gate slot. The newest
approved linear push-through SHA remains **`da3028f`**.

## S5c-1 red and transcript-scrub plan rev 16.20.3 (`ac47497`, `5baf1bc`)

### S5c-1 failing-first tests

BlackRobin's clean-export evidence is genuinely red at the intended seams:
seven of the 25 drawer-e2e checks fail, three of five exact-copy checks fail,
all four helper flood tests fail, and the Zig break test cannot compile before
`breakRuns` exists. The additive fixtures retain the older chat, copy,
lifecycle and error suites. The new cases cover the intended small-frame
flood, long unbroken replies, exact clipboard content, scripted overflow and
the real CLI/API overflow path. Three load-bearing test gaps remain.

**Explicit verdict for `ac47497`: BLOCKED-for-tests.**

1. **BLOCKER-for-tests — the RSS oracle can silently pass without measuring a
   process.** `Rss.__init__` accepts either a failed browser lookup or an
   unreadable first `VmRSS`; that leaves `base=None`, `peak=0`, and
   `growth()==0`, so every `<64/<200 MiB` assertion is green
   (`tests/e2e/agent_flood_test.py:54-76`). Construction must fail unless it
   finds the exact browser PID and reads its baseline. Stop/join the sampler
   and take a final sample before judging the bound as well.
2. **BLOCKER-for-tests — the break and offset oracle is partly derived from
   the implementation under test.** The boundary examples use exported
   `break_run_min`/`break_every`, so a wrong production threshold can make its
   own test pass (`tests/agent_drawer_breaks_test.zig:18-60`). The mapping
   check mostly asks whether the production-selected original offset happens
   to contain the same code point; repeated runs can hide a wrong offset
   (`:74-104`). Pin literal 128/64 cases, including exactly 128, 129 and an
   exact multiple where no trailing break is allowed; table all six ASCII
   whitespace characters and NBSP/U+200B as non-whitespace; and compare the
   complete shown output and every original offset with an independent test
   oracle.
3. **BLOCKER-for-tests — no destruction red exercises the pending idle.** The
   S5.6 contract requires the one pending UI idle to be removed when the
   drawer/window is destroyed, but no new case closes a window during an
   active flood. Add that path and prove no late UI callback, use-after-free
   or helper leak. Ending an ordinary endless turn does not cover destruction.

**SHOULD:** the reused clipboard helper prints the full expected and actual
text on mismatch (`tests/e2e/agent_drawer_copy_test.py:101`); the new 200 KB
case should use bounded prefixes, lengths and/or a digest so one failure does
not flood the gate log.

### Transcript scrub rev 16.20.3

The whole-life 0.25 s monitor closes the original indefinite post-result
window. The revision also removes the undeclared pause seam, makes the four
lifecycle outcomes explicit, enumerates file-operation fault injection and
resets on an observed inode replacement or shrink. It does not yet make the
crash/cursor story fail closed.

**Explicit verdict for `5baf1bc`: BLOCKED.**

1. **BLOCKER — a partial crash tail is deliberately left unsanitized.** Only
   newline-terminated records are scanned (`plan:2124`), including at helper
   start (`:2135`), and the red requires a partial token-bearing line to wait
   until a later newline (`:2155`). A killed writer can leave a final partial
   JSONL line containing a complete token; no newline may ever arrive, so the
   next helper can emit `ready` while the credential remains forever. Scan
   complete matches in the partial suffix while retaining the cursor at that
   line's start, and add idle/start crash-residue reds with no final newline.
2. **BLOCKER — `(st_dev, st_ino, cursor)` is insufficient for the promised
   truncate-and-regrow case.** The reset fires only when a poll observes
   `size < cursor` (`plan:2125-2131`). If a file is truncated and rewritten to
   at least the old cursor before the next poll, the token-bearing prefix is
   skipped. The red at `:2156` must perform that exact sequence without an
   intermediate scan. Identity and size must also come from `fstat` on the
   same opened regular, no-follow fd that is read/written; a path `stat`
   followed by `open` otherwise reintroduces a replacement TOCTOU. Define a
   prefix-integrity/reset mechanism or rescan strategy that catches it.
3. **BLOCKER-for-tests — monitor and close supervision are unexercised.** The
   plan states exit 3 and no `session_ended` for both paths
   (`plan:2137-2141`), but helper-level reds cover only prompt end and startup
   (`:2159-2163`). Add an idle-monitor fault and an `end_session`/shutdown
   fault, each asserting exit 3, no `session_ended`, and no later frame. Direct
   `Scrubber` file-op faults prove the low-level error, not lifecycle wiring.

`python3 -m py_compile` passed for every Python file changed by `ac47497`, and
`git diff --check` passed for both commits. No browser/full gate was run: this
is an unregistered red plus a docs-only plan, and the shared worktree already
contains BlackRobin's in-progress green. Findings were mailed as Agent Mail
6015. Neither verdict advances the approved linear push-through SHA, which
remains **`da3028f`**.

## Transcript scrub plan rev 16.20.4 (`def9c2a`)

Rev 16.20.4 materially improves the scrub contract. It replaces the unsafe
cursor with a whole-file rescan keyed by fd-derived metadata, scans the partial
tail, names the quiet and polling bounds, rejects a symlink/non-regular final
component, and adds helper-level monitor, `end_session`, `shutdown`, prompt-end
and startup failure reds (`plan:2128-2198`). Those changes close the original
partial-tail, leaf-fd TOCTOU and lifecycle-supervision findings in the ordinary
case. Three boundary problems remain.

**Explicit verdict for `def9c2a`: BLOCKED.**

1. **BLOCKER — leaf-only `O_NOFOLLOW` does not confine the scan beneath the
   transcript root.** `plan:2128-2131` still opens a full pathname found below
   `state/projects/*`. `O_NOFOLLOW` rejects only a symlink in the final
   component; a symlinked `projects` or workspace directory is followed, and
   the final JSONL then passes `fstat` as an ordinary file outside the agent
   transcript tree. A local probe reproduced exactly that success. Pin the
   projects directory fd and walk every component with no-follow directory
   opens, or use an equivalent beneath/no-symlink resolution primitive. Add
   an intermediate-directory symlink red and require the outside canary to
   remain byte-identical.
2. **BLOCKER — the whole-file polling work is unbounded.** The cost statement
   says a transcript is “a few MB at most” (`plan:2139-2142`), but no contract
   caps the persistent JSONL files; S5b deliberately retains them and one
   assistant reply alone may be 256 KiB. A changing 100 MiB file at the named
   0.25 s poll interval implies roughly 400 MiB/s of rereads. Define and
   enforce a transcript/scan-work bound and its user-visible failure, or use a
   bounded incremental design with a fail-closed prefix-integrity check. The
   reds need a large, continuously appended transcript and a liveness/CPU/RSS
   bound.
3. **BLOCKER — an unqualified star-run extension corrupts ordinary content.**
   The plan masks token characters following any run of `*` (`plan:2137`). A
   legitimate transcript containing `********documentation` is therefore
   changed, contradicting the same-length/every-other-byte invariant in the
   red suite (`plan:2180`). Track only scrubber-created pending ranges, with
   restart behavior defined, or use another provenance rule that cannot
   collide with user/model text. Add complete-line and EOF negatives for
   ordinary star runs followed by `[A-Za-z0-9_-]`.

**BLOCKER-for-tests:** the truncate/regrow red grows past the prior size
(`plan:2185`), so `st_size` alone catches it and the new `st_mtime_ns` member is
not pinned. Regrow to exactly the old size with a token before the old offset.
Also state explicitly that a pending unterminated match is revisited when its
quiet deadline expires even though the ordinary monitor scans only when the
change key moves (`plan:2145-2152`).

The deferred SX-standin notes are not treated as an approved implementation
contract; the plan correctly keeps that slice subject to a later user
decision. `git diff --check def9c2a^ def9c2a` passed. No browser or full gate
was run for this docs-only review. Findings were mailed as Agent Mail 6019.
The approved linear push-through SHA remains **`da3028f`**.

## Transcript scrub plan rev 16.20.5 (`5be4c4c`)

Rev 16.20.5 closes the four narrow findings from the rev-16.20.4 review:
the walk now uses one-component `openat` calls with `O_NOFOLLOW`, the plan
replaces the unsupported “few MB” assumption with an explicit monitor rate,
mask extension is limited to scrubber-created ranges, and the reds now pin an
exact-size truncate/regrow plus the quiet-deadline revisit
(`plan:2128-2235`). Those corrections are real, but the replacement design
introduces five new boundary failures.

**Explicit verdict for `5be4c4c`: BLOCKED.**

1. **BLOCKER — the whole-life `projects` fd can become detached from the live
   writable bind.** The plan pins `state/projects` once and keeps that fd for
   the helper's lifetime (`plan:2129-2136`). D12 makes that directory writable.
   A writer can rename it and put a replacement at the live path; the CLI then
   writes into the replacement while the scrubber scans only the unlinked old
   tree. Reopen and identity-check the current component from a pinned parent
   on every census, or provide an equivalent fail-closed replacement check.
   Add a post-`ready` directory-swap red that writes a token into the current
   replacement and permits no ending/ready frame while it remains.
2. **BLOCKER — directly mapping a mutable transcript cannot implement the
   promised controlled failure.** A concurrent truncate below a mapped page
   makes a later access raise SIGBUS, not an injectable `mmap` error that the
   helper can convert to exit 3 (`plan:2140-2144,2182-2194`). A local child
   probe mapped 8 MiB read-only, truncated its fd to zero, touched the former
   last byte, and exited **135/SIGBUS**. Use a race-safe streaming matcher or a
   stable snapshot, and add a real-helper truncate-during-scan red.
3. **BLOCKER — the token bucket and worker ownership are not executable
   contracts.** Capacity, initial fill and fairness are unspecified
   (`plan:2166-2172`). A 64 MiB-capacity bucket can never admit the specified
   100 MiB whole-file scan; an accumulating bucket merely delays and then
   bursts one monolithic scan. A Python thread alone also does not establish
   responsiveness while Python matching owns the GIL, and the plan does not
   serialize monitor and lifecycle scans that mutate shared change keys,
   pending ranges and provenance. Define bounded work quanta, cross-chunk
   state, capacity/fill/fairness, and one owner for every scan/mutation.
4. **BLOCKER — mask provenance becomes stale on same-inode rewrite.** A range
   recorded by `(st_dev, st_ino)` survives the plan's own truncate/regrow case
   (`plan:2150-2158`). If replacement content puts legitimate
   `********documentation` at that old range, the stale record authorizes
   corrupting `documentation`. Invalidate or revalidate provenance on every
   non-append change and add that same-inode false-positive red.
5. **BLOCKER-for-tests — the process counters do not measure mmap work.** On
   this host, touching a fresh 32 MiB mapping moved `/proc/self/io:rchar` by
   only 101 bytes, so the helper oracle at `plan:2232-2235` can pass while an
   arbitrary mapping is scanned. Touching a 100 MiB mapping raised `VmRSS`
   from about 12.8 MiB to 115.3 MiB, contradicting the promised <32 MiB growth
   unless pages are actively discarded/chunked. Count logical scan bytes at
   the scrubber seam and bound resident work by construction; retain the
   process-level frame-liveness test separately.

`git diff --check 5be4c4c^ 5be4c4c` passed. No browser/full gate was run for
this docs-only review. The findings and local probes were sent to BlackRobin
as Agent Mail 6023.

## S6b1 paste-path green (`a9dcabe`, `4c659aa`)

The corrected red is production-shaped: X input opens the real Secrets
window, pastes through the private X clipboard, and drives the native login
launcher, login netd, bwrap/relay, real login helper, fd 4 and the S4 token
store. The fake CLI is argv-only and inert without `--e2e-protocol`; the login
sandbox exposes egress but no bridges; chat's netd remains narrow; native
frames are validated; and token bytes do not enter rows or logs. Agent Mail
6022 records the failing-first runs, a patched-tree full gate of **156/156
steps and 910/910 tests**, and four focused green reruns. The census test was
registered after that full gate and passed its exact step 3/3, so it has not
yet participated in a full exact-commit gate.

**Explicit verdict for `a9dcabe`: APPROVED as a failing-first correction.** It
adds the real clipboard paste, malformed input, fixed sentences, link/census,
honest per-browser process counts and teardown checks that the original red
lacked.

**Explicit verdict for `4c659aa`: BLOCKED.**

1. **BLOCKER — the ordinary Save path can race sign-in and leave a different
   credential than the UI reports.** `signin_controls` changes only the
   sign-in widgets; it does not disable entry/Save/Remove/file or mark the
   Secrets operation busy (`src/agent_secrets_window.c:201-206,341-355`). A
   manual async keyring store may therefore start while the login helper waits
   for a code. When fd 4 later supplies the signed-in token, advancing the UI
   epoch does not cancel the first GTask, so the two libsecret writes race;
   the old manual token can win after “Signed in.” Make all credential
   mutations mutually exclusive for the complete sign-in/store lifecycle and
   add a delayed-store e2e that proves both disabled controls and one final
   stored token.
2. **BLOCKER — Secret Service failure followed by the offered file fallback
   emits two login endings.** `on_service_stored` emits `error-store` but
   retains `pending` and `signin_store`; a later “Save to a private file
   instead” succeeds through `store_in_file` and emits `done`
   (`src/agent_secrets_window.c:269-290,325-379`). The row grammar and plan
   classify both as terminal. Add the no-keyring-to-file red and define one
   terminal outcome for that path.
3. **BLOCKER-for-tests — the production-inert case never performs the Cancel
   its contract promises.** It leaves sign-in running and stops the browser
   (`tests/e2e/agent_login_test.py:465-513`), whereas §S6.1 says the test then
   cancels. Drive Cancel by the non-e2e UI and prove the helper, login netd and
   `-login` directory all disappear.

The independent approval condition also remains open: rev 16.18.5 requires
both user-run `signin-paste` parts A and B, including the production CLI's
mounts and committed CONNECT census, before S6b1 or a later S6 slice can be
approved (`plan:2291-2299`). `git diff --check` passed for both reviewed
commits. I did not take the gate slot; JadeBeacon is next. Findings were sent
to BlueBeaver as Agent Mail 6024.

Because the S6b1 green remains blocked, the newest approved linear
push-through SHA remains the already-pushed **`da3028f`**. (The earlier
`e33661d` boundary in this paragraph was stale; review commit `70317c0`
subsequently approved through `da3028f`, which is now on origin.)

## macOS plan rev 10 (`1ccece3`)

Rev 10 states the signing limitation plainly and repeatedly. MS1.1/MS1.2 run
the **unsigned** universal binary; MS1.3 signs a separate copy only for static
`codesign -d` inspection; and the plan explicitly says that MS1 does **not**
prove a signed binary runs (`plan:135-145,521-532`). The new MS1b has a real
Intel execution contract and gate for the ad-hoc-signed universal binary's m9
workload plus the executing-architecture probe (`plan:565-591`). The macOS-only
segfault-handler exception also records the Zig 0.16 alignment failure and
keeps Linux's exact default (`plan:551-563`).

**Explicit verdict for `1ccece3`: BLOCKED.**

- **BLOCKER — MS1b is not binding in the authoritative dependency order.**
  The plan still says `MS0 (Linux) → MS1 → MS2a ...` at `plan:1336-1340`.
  It omits MS1b, so the written dependency graph permits MS2a and every later
  milestone to start after MS1 without the signed-binary launch proof. Section
  placement and “well before MS9” do not create a hard dependency. Change the
  chain to `MS0 (Linux) → MS1 → MS1b → MS2a ...`, or state an equivalent hard
  gate that blocks MS2a and all later milestones until Gate(MS1b) is green.

`git diff --check 1ccece3^ 1ccece3` passed. No code or test gate was run for
this docs-only review. The finding was sent to JadeBeacon as Agent Mail 6025.
The newest approved and pushed linear boundary remains **`da3028f`**.

## Plan follow-ups: credentials, MS1b dependencies and transcript scrub

### S6 rev 16.18.6 (`545c06f`)

The behavior amendment is correct. It makes sign-in and manual credential
mutations mutually exclusive, makes `error-store` the sign-in operation's sole
terminal row before an ordinary explicit file Save, and gives the production-
inert case a real Alt+C Cancel plus process/directory cleanup
(`plan:2297-2299,2337-2342`). This closes the contract portion of all three
findings in Agent Mail 6024.

**Explicit verdict for `545c06f`: BLOCKED-for-tests.**

The S6b1 e2e list remains unchanged at `plan:2303-2314`; it does not drive the
two new asynchronous contracts. Add failing-first cases that:

1. hold a manual Save or Remove in flight and prove Sign in is insensitive and
   a no-op, then hold the sign-in store in flight and prove entry, Save, Remove
   and file fallback are insensitive/no-ops; after release, exactly the
   intended token is stored; and
2. force the sign-in keyring store to fail, observe exactly one
   `SECRETS login error-store`, choose the explicit file fallback, observe the
   ordinary `connected-file` result, and observe no later `SECRETS login`
   terminal row.

The Alt+C inertness test is now specified adequately. Approval of the S6b1
implementation still independently requires both user-run `signin-paste`
parts A and B. Findings were sent to BlueBeaver as Agent Mail 6031.

### macOS MS1b dependency follow-ups (`7a2ff00`, `4075bbe`)

**Explicit verdict for `7a2ff00`: BLOCKED at that SHA and superseded by
`4075bbe`.** It added the immediate `MS1 → MS1b` assignment, made MS1b a hard
MS9 prerequisite, and permitted unsigned MS2+ development in parallel. Its
signed-run edge did not yet enumerate gate and documentation claims from the
re-review criterion in Agent Mail 6026.

**Explicit verdict for `4075bbe`: APPROVED.** The authoritative dependency
section now says all three required things (`macOS plan:1342-1350`):

- MS1b is JadeBeacon's immediate next Mac slice after MS1;
- Gate(MS1b) hard-blocks MS9 and any slice, gate, documentation claim or
  real-screen check that says a signed binary runs; and
- MS2a and later development may proceed in parallel using the unsigned
  universal build, without claiming signed-run coverage.

This cumulatively closes `1ccece3`'s dependency blocker from review commit
`7532df7`, with the orchestrator's correction that MS1b is not a universal
MS2+ blocker. The verdicts were sent to JadeBeacon as Agent Mail 6032.

### Transcript scrub plan rev 16.20.6 (`a69b459`)

Rev 16.20.6 materially closes the five design failures in Agent Mail 6023:
each census re-walks from the pinned root rather than retaining a stale
`projects` fd; `pread` replaces SIGBUS-prone `mmap`; one thread owns scans and
state; bounded chunks and internal logical-byte accounting replace the
underspecified token bucket and invalid `/proc` oracle; and mask provenance is
gone. Replacement, chunk-edge, truncation, memory and lifecycle tests are now
named. Three contradictions/races remain before that design is executable.

**Explicit verdict for `a69b459`: BLOCKED.**

1. **BLOCKER — the matcher masks and defers the same bytes.** The carried
   matcher says every token byte is masked as it is read through EOF
   (`plan:2158-2161`), while the timing contract says a monitor leaves an
   unterminated generic match at EOF untouched (`plan:2174-2180`). Define an
   offset/length candidate that defers `pwrite` until a terminator, or until a
   lifecycle scan accepts EOF. This remains memory-bounded because it retains
   offsets and automaton state rather than the match bytes. The monitor-EOF
   negative must assert byte identity before a lifecycle scan masks it.
2. **BLOCKER — a re-walk is not a stable lifecycle census.** A `projects` or
   workspace replacement, a new directory entry, or a short read can occur
   after that component was listed/opened but before the lifecycle request
   returns. The current text treats a short read as success and can therefore
   release an ending frame while the new live tree contains a token
   (`plan:2138-2157,2182-2203`). Before a lifecycle scan succeeds, revalidate
   the directory generation/entry set and each file's post-scan key; if any
   moved, changed or read short, rescan with a bounded fail-closed outcome.
   Add a mid-lifecycle directory/file swap red that permits no ending frame
   until the replacement is clean.
3. **BLOCKER — the change key omits the non-restorable metadata clock.** The
   current `(dev, ino, size, mtime_ns)` key (`plan:2150-2152`) can be restored
   after a same-inode, same-size rewrite with `utime`; `state/projects` is a
   writable sandbox state directory. Include `ctime_ns`, which an unprivileged
   writer cannot restore, and add a red that restores the old mtime after the
   rewrite but is still rescanned.

The findings were sent to BlackRobin as Agent Mail 6033.

`git diff --check` passed for all four reviewed commits. No browser or full
gate was run for these docs-only revisions. Because the first commit in the
new linear range remains blocked-for-tests, the newest approved and pushed
linear boundary remains **`da3028f`**.

## Transcript scrub plan rev 16.20.7 (`87c9ea1`)

Rev 16.20.7 closes the three mechanisms reported against `a69b459`:

- an open generic match is now an offset/length candidate, not bytes written
  speculatively, so a terminated match can be masked while a monitor leaves an
  EOF candidate untouched (`plan:2158-2162`);
- a lifecycle scan re-walks and revalidates the directory generations,
  listings and post-scan file keys, retries a changed or short-read pass, and
  fails closed after the named three-pass bound (`plan:2183-2187,2198-2217`);
  and
- `st_ctime_ns` joins the change key, with a same-size rewrite that restores
  mtime as its red (`plan:2150-2152,2227-2232`).

The new reds correctly cover monitor-versus-lifecycle EOF behavior, tree and
file replacement during revalidation, repeated instability, a lifecycle short
read, and restored mtime. One state transition remains missing.

**Explicit verdict for `87c9ea1`: BLOCKED.**

- **BLOCKER — dropping an EOF candidate can make the lifecycle scan skip it.**
  A monitor that reaches an unterminated generic candidate drops it and writes
  nothing (`plan:2161`). If that successful monitor commits the file's current
  change key, the later lifecycle scan sees an unchanged file and skips it
  under the “scan when changed” rule and stated lifecycle cost
  (`plan:2150-2152,2167`). It then cannot perform the promised lifecycle mask
  at `plan:2178-2180`. Specify either that such a monitor scan does not commit
  the clean key, or retain a per-file `pending_eof` flag keyed to file identity
  that forces lifecycle rescan even when metadata is unchanged. Define how the
  state is cleared or invalidated after masking, identity replacement or
  content change. The existing several-polls-then-`end_session` red is the
  correct test and need not change.

`git diff --check 87c9ea1^ 87c9ea1` passed. No browser or full gate was run for
this docs-only revision. The finding was sent to BlackRobin as Agent Mail
6036. The newest approved and pushed linear boundary remains **`da3028f`**.

## Transcript scrub plan rev 16.20.8 (`9868a65`)

**Explicit verdict for `9868a65`: APPROVED.** It cumulatively closes the
remaining rev-16.20.7 blocker from Agent Mail 6036:

- a monitor commits a transcript's change key only after a clean scan with no
  unterminated EOF candidate; a candidate therefore leaves the old key in
  place and later monitor censuses revisit the file (`plan:2152-2154`); and
- prompt-end, close and start lifecycle scans ignore the monitor keys and read
  every transcript in the live tree in full. A monitor can no longer make a
  lifecycle scan skip the unchanged candidate (`plan:2153-2154,2191-2198`).

The existing several-monitor-polls then `end_session` red remains the correct
behavioral proof: the monitor leaves the bytes untouched, then the lifecycle
scan masks them before `session_ended` (`plan:2231`). The stable-answer
revalidation and bounded fail-closed retry from rev 16.20.7 remain in force
(`plan:2185-2189`). Thus the current rev 16.20.8 design cumulatively resolves
the blockers recorded against `a69b459` and `87c9ea1`; those earlier SHAs stay
blocked at their own states.

**NIT (nonblocking):** the subsection heading at `plan:2150` still says
“each time it changed,” although lifecycle scans now run regardless of change.
The monitor/lifecycle bullets immediately below are normative and unambiguous,
so this is editorial rather than an approval condition.

`git diff --check 9868a65^ 9868a65` passed. No browser or full gate was run for
this docs-only revision. The verdict was sent to BlackRobin as Agent Mail
6038. The newest approved and pushed linear boundary remains **`da3028f`**
because the earlier `545c06f` is still blocked-for-tests.

## S6b1 credential-operation follow-up (`22a4a8f`, `032a2c9`, `00530d4`)

The production change in `00530d4` is internally coherent. One
`update_sensitivity()` projects `busy || signin_active || signin_store` into
the credential controls; each handler independently refuses the same overlap;
`ZB_LOGIN_EV_DONE` hands the lock from `signin_active` to `signin_store`
before starting the asynchronous token store; and the store callback releases
it only with its answer (`src/agent_secrets_window.c:209-235,292-317,384-439`).
The failed Secret Service store now clears `signin_store` before exposing the
file choice, making `error-store` final and the later file choice an ordinary
Save. `_Cancel` supplies the promised Alt+C mnemonic.

Agent Mail 6053 records the failing-first evidence: `22a4a8f` failed 7 of 37
checks in each of three clean-export runs; `032a2c9` makes the entry-lock mutant
fail; and the green exact tree passed a private-Xvfb clean gate at **158/158
steps and 910/910 tests** (race 41/41, login 106/106, Secrets 222/222). I did
not take JadeBeacon's gate slot for a duplicate gate. The earlier load-saturated
failure is not treated as product evidence; each reported failure passed alone
and the later clean gate was green.

**Explicit verdict for `22a4a8f`: BLOCKED-for-tests at that SHA.** It supplies
useful failing-first cases for the overlap, double ending and inert Cancel, but
does not observe the signed-in-token store interval or widget sensitivity.

**Explicit verdict for `032a2c9`: BLOCKED-for-tests.** It correctly makes the
token entry's insensitive state observable, but only while login is waiting
for a code. It does not close the full coverage requirement from review
`9fa608b`/Agent Mail 6031.

**Explicit verdict for `00530d4`: BLOCKED-for-tests; production logic
approved.** One test gap remains:

- `case_save_during_signin` attempts the conflicting Save before sending the
  code, while `signin_active` is true (`agent_login_races_test.py:46-71`). It
  then waits straight through `done` and inspects only the final store
  (`:72-76`). Removing `signin_store` from `signing_in()`, or releasing it
  before the delayed keyring answer, would therefore survive. The red must
  hold the post-code signed-in-token store in flight, observe/try the manual
  controls before releasing it, and prove the final store.
- Only the entry's insensitive appearance is observed. Save and Sign in are
  clicked and appear to do nothing because their handler guards return;
  Remove and the file choice are never exercised from an enabled state.
  Individual mutations that remove the Save, Remove, file-choice or Sign-in
  `gtk_widget_set_sensitive` calls therefore survive, although `plan:2313`
  requires the controls to be insensitive **and** refuse. Observe each
  meaningful enabled-to-disabled transition through the production widget
  (an e2e-only `gtk_widget_get_sensitive` row or an equivalent pixel oracle),
  while retaining the outcome and stored-token checks.

The one-ending file fallback and the Alt+C cleanup cases adequately cover
their contracts. `git diff --check` passed for all three commits. Findings were
sent to BlueBeaver as Agent Mail 6055. **S6b1 has not cleared code review.**
After this test blocker closes, approval still independently requires both
user-run `signin-paste` parts A and B (`plan:2331-2339`). The newest approved
and pushed linear boundary remains **`da3028f`**.

## S6 sensitivity observability plan and MS1b red (`3e539a2`, `bf0a66f`)

### `3e539a2` — APPROVED (plan amendment)

Rev 16.18.7 closes the plan-contract gap from Agent Mail 6055. The new
E2E-only row reports the actual GTK state for each credential control:
`SECRETS sensitive <entry|save|remove|file|signin> <0|1>`. Its source is
explicitly `gtk_widget_get_sensitive`, after each sensitivity change and once
when each control is built (`plan:461-467`). This is the required production
widget readback, not a shadow state derived from the same booleans under test.
The S6b1 test contract now names all five controls, includes the file choice,
and holds the signed-in token's own asynchronous store while observing them
(`plan:2314`).

The green implementation must still prove the expected unlock as well as the
lock where a control should re-enable (a `1 -> 0 -> 1` transition); this is an
implementation-review criterion, not a blocker on the plan amendment.
`git diff --check 3e539a2^ 3e539a2` passed. The verdict was sent to BlueBeaver
as Agent Mail 6058. This plan approval does not by itself clear S6b1 code
review or its two required user-run sign-in checks.

### `bf0a66f` — BLOCKED-for-tests

The unregistered MS1b red is attached to the right product boundary. It builds
both architecture slices on their native hosts, assembles the universal on the
Intel host, ad-hoc signs that runnable artifact with the real entitlements,
verifies its signature, installs that exact artifact on both Macs, and runs the
M9 workload. JadeBeacon's Agent Mail 6056 reports three right-reason red runs:
the actual signed Intel launch returned 139 each time while the arm64 leg
passed. `bash -n` and `git diff --check` passed.

**BLOCKER-for-tests:** `tests/mac/ms1b_signed_gate.sh:74-98` accepts an
expected architecture but never checks it. At `:94-96`, the exec-arch output
only has to be nonempty. The same host configured twice, or Apple Silicon
running the x86_64 slice under Rosetta, could therefore make both legs green
while the gate claims native x86_64 and arm64 execution. That is a false green
against rev 10's two-architecture MS1b contract. Fix forward by exact-matching
the probe result (with only known alias normalization), asserting distinct
host targets, and retaining the native host checks including
`sysctl.proc_translated=0` on Apple Silicon. Reusing the existing
`mac_universal_test.py --expect-arch ... --reported-arch ...` oracle would
avoid a second architecture definition.

**SHOULD:** replace the throwaway staging cleanup's `rm -rf` with the standing
`find "$STAGING" -delete` rule. The M9 invocation also disables its uniformity
check; remove `--no-uniform-check` or document why MS1b intentionally needs
only signed process execution and protocol readiness rather than that visual
assertion.

The blocker and follow-ups were sent to JadeBeacon as Agent Mail 6059. No
Linux full gate was run for a docs-only plan change plus an unregistered,
Mac-only failing-first script. The newest approved and pushed linear boundary
remains **`da3028f`**.

## S5c-1 correction, MS1b fix-forward and WS0 red (`e6327a5`, `f0e42ea`, `2f6214f`, `e36f5fa`)

### `e6327a5` — BLOCKED-for-tests

This red correction closes most of the findings on `ac47497`. The pure Zig
oracle is independent of production exports, pins the literal 128/64 bounds,
checks 128/129/192/193, distinguishes all six ASCII whitespace bytes from
NBSP/U+200B, and compares every mapped offset. The popup-close case exercises
window destruction during a stream; copy failures have bounded diagnostics;
and the helper test fixture now kills its whole process group. Agent Mail 6066
records credible failing-first results under a 2 GiB scope: all six helper
flood checks fail, three of fourteen copy checks fail, and the pure Zig test
does not compile without `breakRuns`.

Two test oracles still admit false greens:

1. **BLOCKER-for-tests — RSS fails open after its first sample.** A missing
   initial PID or `VmRSS` now refuses correctly, but a later `rss_kb()` failure
   merely returns from the sampler, and a missing final sample is ignored
   (`tests/e2e/agent_flood_test.py:67-90`). `ok` remains true, so `bounded()`
   can pass from a stale peak after the browser disappears or `/proc` becomes
   unreadable. Any missing periodic sample must poison the result, and the
   mandatory final sample must itself be present before the bound can pass.
2. **BLOCKER-for-tests — “at most 256 KiB” permits 272 KiB.** Both the
   over-cap message check and the endless check allow
   `MESSAGE_MAX + DELTA_MAX` (`agent/host/tests/test_chat_flood.py:88-94,
   172-177`). An implementation that forwards one whole extra 16 KiB delta
   therefore passes even though rev 16.20.9 promises at most 256 KiB. Assert
   `<= MESSAGE_MAX` exactly at a UTF-8 boundary and separately prove the
   greatest fitting prefix is forwarded.

**SHOULD:** use `ast.literal_eval` instead of `eval` for PRIMARY's textual
readback (`agent_flood_test.py:210-218`), and make the fake cap slice a piece
to its remaining budget so a future oversized `endless` piece cannot cross
the stated 8 MiB ceiling.

### `f0e42ea` — BLOCKED (plan)

Rev 16.20.9 usefully records the measured reason for replacing labels above
32 KiB with read-only text views, the LF break rule, per-widget refresh
periods, the exact-copy mapping, SDK-client replacement, bounded fake and the
separate SX-memlimit follow-up. The follow-up is explicitly not implementation
ready and must receive its own red and review, so its cgroup-versus-RLIMIT
choice does not block this revision.

One normative contradiction does block the plan. The as-built section says a
triple-click selects one 64-character LF-delimited line and only Ctrl+A/drag
selects the whole long run (`plan:2105-2108`), but the real-screen case still
requires triple-click plus Ctrl+C to copy the entire 200 KiB reply
(`plan:2127-2129`). The recipe must use click, Ctrl+A, Ctrl+C, matching the
E2E. The exact-cap mismatch above is a red-suite blocker, not ambiguity in the
plan: `plan:2117` correctly says **at most** 256 KiB.

The S5c findings were mailed to BlackRobin as Agent Mail 6071.

### `2f6214f` — BLOCKED-for-tests

The fix-forward closes the original host/slice false green: the remote block
now receives the expected architecture, exact-matches normalized `uname -m`
and the socket's `build.exec_arch`, and therefore rejects a duplicated host or
the wrong universal slice. JadeBeacon's three-run evidence still reaches the
intended failure: the signed x86_64 launch returns 139 while the arm64 leg
passes the added checks.

**BLOCKER-for-tests:** the native-arm probe converts failure into success:
`sysctl -n sysctl.proc_translated 2>/dev/null || echo 0`
(`tests/mac/ms1b_signed_gate.sh:110-112`). Missing or failed `sysctl` is thus
reported as the exact native value. Require the command to succeed and then
require its output to equal `0`, as `mac_universal_test.py` does. The earlier
nonblocking cleanup remains: delete staging with `find -delete`, and remove
`--no-uniform-check` or document the intentionally narrower M9 assertion.
The verdict was mailed to JadeBeacon as Agent Mail 6072.

### `e36f5fa` — BLOCKED-for-tests

A clean archive of `e36f5fa` reproduces the declared red: all five tests error
at the absent `tests/windows/gate.sh`; the file is unregistered. The cases are
not yet safe future-green oracles:

1. `NoDisplayTests` and the successful transport case ignore the stage return
   code (`tests/windows/gate_selftest.py:142-160,179-193`). A gate that exits
   before work can pass the former; one that invokes ssh and fails before tar
   can pass the latter. Add a healthy stage that must exit zero and prove all
   expected fakes ran, and make both cases require it.
2. WS0.3 promises every child is display-clean, but only fake ssh records its
   environment. Tar, virsh and every other child need the same observation or
   one common observable launcher.
3. The fake tar logs argv, so it can never see the parent shell's
   `2>/dev/null` redirection. Make it write a sentinel to stderr and require
   that sentinel in captured gate stderr.
4. The partial-tar case accepts any nonzero result, including never invoking
   tar. Couple it to a positive successful stage/tar invocation and require
   the named tar failure or propagated status.
5. The SSH check omits the required known-hosts file, `BatchMode=yes` and
   `ConnectTimeout=15`, and does not reject conflicting later options. Parse
   the complete recorded argv.
6. WS0.5 calls for a property test, but the red has only a fixed corpus. Add a
   deterministic/generated independent oracle over separator, case,
   drive/UNC, dot-segment and prefix-collision combinations.

**SHOULD:** give each selftest a private HOME rather than inheriting the review
host's home. These findings were mailed to AzureRidge as Agent Mail 6073.

`git diff --check` passed for all four commits; `bash -n` passed for the Mac
script; every changed Python file parsed successfully. I did not take the full
gate slot: the two reds are unregistered/platform-specific, the plan is docs
only, and repeating the OOM-sensitive flood was unnecessary given its bounded
clean-export evidence. The clean WS0 export was deleted immediately. The
newest approved and pushed linear boundary remains **`da3028f`**.

## S5c plan and MS1b red follow-ups (`854fbb1`, `41882ae`)

### `854fbb1` — APPROVED

Rev 16.20.10 resolves the copy-procedure contradiction in `f0e42ea`: the
real-screen case now clicks the reply, presses Ctrl+A and Ctrl+C, matching the
E2E and the one-line long-run behavior. It also makes the cap contract exact:
the helper must forward the longest UTF-8 character-boundary prefix that fits
256 KiB, including cutting the final source piece to the remaining budget.
The displayed copy check records length, LF and U+200B counts plus the first
and last characters, so inserted presentation breaks cannot masquerade as the
original payload.

This cumulatively closes the plan blocker on **`f0e42ea`**. It does not close
the separate `e6327a5` test blockers (later RSS samples/final sample must fail
closed, and the tests must assert the exact 256 KiB boundary); BlackRobin says
those fixes are written but not yet committed. The verdict was mailed as
Agent Mail 6077. This is a docs-only revision, so no gate was run.

### `41882ae` — APPROVED (failing-first red)

The MS1b red now treats failure of `sysctl -n sysctl.proc_translated` as a
test failure and separately requires the value `0`. It therefore cannot turn
an unavailable or failed probe into the native-arm result. The exact remote
host and executed-slice architecture checks added by `2f6214f` remain intact.
The follow-up also uses the standing `find -depth -delete` cleanup and explains
why the red intentionally uses `--no-uniform-check`: it proves that the signed
process renders at all, while the later green must send the PNG to the Intel
Pillow oracle.

JadeBeacon's Agent Mail 6075 reports three right-reason runs: the signed Intel
x86_64 leg still returns 139 and the arm64 leg passes. `bash -n` and
`git diff --check` passed. This cumulatively closes the test blockers on
**`bf0a66f`** and **`2f6214f`**; MS1b remains deliberately red until its green
implementation lands and passes the pixel oracle on both architectures. The
verdict was mailed as Agent Mail 6078. No Linux full gate was run for an
unregistered Mac-only red.

Because earlier commits in the linear range remain blocked, the newest
approved and pushed boundary remains **`da3028f`**.

## WS0 selftest red rev 2 (`9128674`)

### `9128674` — BLOCKED-for-tests

The fix-forward correctly closes four of the six findings on `e36f5fa` and
the private-HOME SHOULD. Every healthy stage now must return zero and prove
both tar and ssh ran; all three fake tools record display variables through
one shared log; fake tar emits a stderr sentinel that a parent redirection
would swallow; and the partial-tar case requires invocation, exact status 2
and a named diagnostic. A clean archive ran all seven tests and all seven
failed at the deliberately absent `tests/windows/gate.sh`, so the commit is
still red for its declared reason.

Two false-green gaps remain:

1. **BLOCKER-for-tests — SSH options are still substring-matched.** At
   `tests/windows/gate_selftest.py:257-275`, `$*` destroys argument boundaries
   and the assertions merely require safe strings to occur while forbidding
   three selected strings. They accept, for example, `BatchMode=yes` followed
   by `BatchMode=no`, `ConnectTimeout=15` followed by another timeout,
   `IdentitiesOnly=yes` followed by `IdentitiesOnly=no`, or a second
   `UserKnownHostsFile`. I ran those conflicts through the current predicates
   and they returned true. Record argument boundaries, parse every `-o`
   setting and require the effective value of each security option to be the
   one approved value with no conflicting duplicate.
2. **BLOCKER-for-tests — WS0.5 remains a fixed corpus, not the promised
   property.** `generate_paths` is a literal list of twenty strings
   (`:110-149`), and `:234-245` only loops over that list. This does not meet
   the plan's Hypothesis-style generated-path contract (`plan:698-700`), lets
   interaction mutants across separator/case/drive/dot/prefix dimensions
   survive, and contains no junction/reparse case despite the plan explicitly
   requiring junction names and resolved paths. Add deterministic
   combinatorial generation plus a fakeable resolution/reparse seam, or amend
   that contract before the green is built.

`git diff --check` passed. The clean-export red run was bounded to 60 seconds
and its throwaway tree was deleted immediately. No full gate was run for this
unregistered red. The findings were sent to AzureRidge as Agent Mail 6081.
The newest approved and pushed linear boundary remains **`da3028f`**.

## WS0 selftest red rev 3 (`9b1dbee`)

### `9b1dbee` — BLOCKED-for-tests

The lexical property is now substantive: it spans the full declared
separator × case × head × dot × tail product, producing 270 distinct paths
with 36 independent-oracle ALLOW results and 234 DENY results. Argument
boundaries are also preserved in the fake SSH log. A clean archive ran all
eight tests; each failed at the deliberately absent `gate.sh`, so the red is
still attached to its intended missing implementation.

Two security semantics still admit false greens:

1. **BLOCKER-for-tests — the SSH parser does not implement OpenSSH option
   grammar.** At `tests/windows/gate_selftest.py:294-339`, option keys retain
   case and only `Keyword=value` is recognized. OpenSSH treats keys
   case-insensitively and also accepts `Keyword value`. The red parser accepts
   both `-o batchmode=no -o BatchMode=yes` and
   `-o 'BatchMode no' -o BatchMode=yes`; its approved `BatchMode` predicate is
   true, while `/usr/bin/ssh -G` reports the effective value as `no` in both
   cases. Case-fold keys, parse both forms and reject every conflicting
   occurrence.
2. **BLOCKER-for-tests — resolution remains optional and fail-open.** The
   junction case at `:267-289` only supplies a successful `ZB_RESOLVE_CMD`.
   It never proves that production resolution is mandatory or that resolver
   failure, empty output, malformed output or multiple lines are denied. A
   green that performs resolution only when the test variable is present and
   otherwise trusts the lexical fence passes. The current uncommitted
   `tests/windows/gate.sh:68-78` demonstrates that exact survivor and also
   allows failed or empty resolver output. Keep the 270 cases on an explicit
   lexical-fence seam, but require the production path to use its real
   resolver, with the environment hook only replacing it, and add fail-closed
   red cases for every unusable result.

`git diff --check` passed. The clean-export run and parser probes were bounded
and their throwaway tree was deleted. No full gate was run for this
unregistered red. The findings were sent to AzureRidge as Agent Mail 6084.
The newest approved and pushed linear boundary remains **`da3028f`**.
