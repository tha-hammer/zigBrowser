---
date: 2026-10-22
author: orchestrator, through an independent read-only Opus subagent (the owner asked for it)
checks: thoughts/searchable/shared/plans/2026-10-13-claude-agent-chat-drawer-tdd-plan-REVIEW.md (review_plan by JadeBeacon, commit 074636b)
bd: zigBrowser-4pa.3
---

VERDICT: Review is materially wrong

(It is wrong about what is built and about Workflow Closure. Its Test-Spec Quality verdict mostly holds for the slices that are actually built.)

Scope: an independent spot-check of
thoughts/searchable/shared/plans/2026-10-13-claude-agent-chat-drawer-tdd-plan-REVIEW.md (074636b)
against the plan (2026-10-13-claude-agent-chat-drawer-tdd-plan.md, rev 16.20.58) and the code at
HEAD e4f705f. The review was written at c07899f, and only 3 docs commits have landed since, so the
findings hold at the review's own HEAD. This was read-only work: nothing was built, run, or edited.
P = plan line. R = review line. CONFIRMED = I checked the code. SUSPECTED = an inference I did not run.

## 1. Claims checked (18)

| # | Claim (plan) | P | Code evidence | Result |
|---|---|---|---|---|
| 1 | S1.5: drawer methods (agent.ping, drawer.open, secrets.get) give -32601 | 1588-1592 | tests/e2e/agent_drawer_icon_test.py:126-131; registered as agent-drawer-icon-e2e (build.zig:2192) | HOLDS, CONFIRMED |
| 2 | S1.6: zbHost promise settles in the page (title resolved/rejected) | 1594-1600 | tests/fixtures/app/index.html:86-91; ipc_roundtrip_test.py:107,116; build.zig:2421,3850 | HOLDS, CONFIRMED (but the step maps exit 77 to 0, build.zig:2424) |
| 3 | S1/S2 e2e fail closed (exit 1, not 77) | 1412 | the agent drawer steps have no 77-to-0 wrapper (build.zig:2192-2228) | HOLDS, CONFIRMED |
| 4 | S3.3: frames are validated natively, with a production caller | 1849 | zb_agent_frames_validate (src/agent_frames.zig:82) is called by src/agent_helper.c:493 | HOLDS, CONFIRMED |
| 5 | S3.4 (f): with no bwrap, "Agent sandbox unavailable" and nothing spawned | 359 | src/agent_helper.zig:249; tests/e2e/agent_host_lifecycle_test.py:577-583 (registered) | HOLDS, CONFIRMED |
| 6 | S3.12: the home lock is taken before the first spawn | 1926-1934 | src/agent_helper.c:952 zb_agent_home_lock; home-locked case in agent_host_lifecycle_test.py | HOLDS, CONFIRMED |
| 7 | S5.5: the drawer default flips to on | 2059 | src/agent_config.zig:17 `.on`; agent_default_on_e2e (build.zig:2395) | HOLDS, CONFIRMED |
| 8 | S5.6: per-bubble cap 256 KiB, then interrupt 10 s later | 2110-2112 | src/agent_helper.c:87-90, 281-297; chat.py:43-45 | HOLDS, CONFIRMED |
| 9 | D7b: inbound queue of 256 frames / 1 MiB; app stops reading the pipe (backpressure) | 364-367 | no such queue: on_line is dispatched directly from the reader (agent_helper.c:532-554); no 256-frame or 1 MiB bound in agent_helper.c, agent_frames.zig or agent_protocol.zig | NOT BUILT, CONFIRMED |
| 10 | D7b: per-conversation view cap of 2,000 bubbles / 16 MiB, "earlier messages hidden" | 369 | no cap and no such row in src/agent_drawer.c or agent_drawer.zig | NOT BUILT, CONFIRMED |
| 11 | S7.1: the core runs without the socket; the broker calls callInProcess | 2755 | automation_server.zig:172,377; app.zig:473 startCore; agent_broker.zig:471 | HOLDS, CONFIRMED |
| 12 | S6: the auth window has a production caller | 2709 | zb_auth_window_open (agent_auth_window.c:200) is called by agent_secrets_window.c:508 | HOLDS, CONFIRMED |
| 13 | S6.2: state check, with a property test | 2725 | tests/agent_auth_test.zig:84, :290 (10k-pair std.Uri oracle) | HOLDS, CONFIRMED |
| 14 | D9 / S8.0: the S8 tool set (30 tools) is registered at S8 | 506-509 | bridge.py:45-75 has only READ (6) + hover, scroll + navigate, reload. Missing: click, fill, type, press, select_option; the 9 previews (red, unregistered); all 12 committing flow tools | 4 OF 30 BUILT, CONFIRMED |
| 15 | S8.1-S8.7 / S8b: an exact-tuple grant binds each committing action (T4, T5) | 2994-3053, 3201-3203 | no grant concept: "grant" appears 0 times in agent_broker.zig, agent_approval.zig and agent_tools.zig; tests/agent_broker_grant_test.zig and tests/e2e/agent_approval_test.py do not exist | NOT BUILT, CONFIRMED |
| 16 | S8a: an `account` expectation gives -32015 | 3192, 3027 | no account in src/automation/engine.zig or flow_runner.zig; 0 "account" hits in every tests/automation_expect_*; recipient is built (social_flow_routes.zig:210-214) | NOT BUILT, CONFIRMED |
| 17 | S9.1-S9.4: dialog and crash banners, the Recover card, drawer notified on terminate | 3301-3325 | no banner strings in the drawer or helper; the only zb_drawer_* calls in webkit_shim.c are attach and detach (:1304, :996); agent_lifecycle_invalidation_test.py and agent_dialogs_test.py are absent | NOT BUILT (only the navigate-card part of S9.3 is, via agent_navigate_stale_test), CONFIRMED |
| 18 | §11: the `agent-no-orphans` gate step scans /proc after the whole gate | 3486-3488 | no such step in build.zig; the `--zb-agent-gate` marker is in no file under src, agent, tests, tools or build.zig | NOT BUILT, CONFIRMED |

Other gate-step names from plan §11 that do not exist in build.zig: agent-approval-e2e,
agent-lifecycle-invalidation-e2e, agent-dialogs-e2e, agent-files-e2e and agent-no-orphans (CONFIRMED). The
review noted only the agent-host-unit and agent-host-contract labels.

## 2. The "exemplary" verdicts, re-checked against review_plan.md

### Workflow Closure (review: 0 issues). 6 behaviors checked; 3 fail.
- Closure S1 (icon click): real X input, fails closed with exit 1, registered. HOLDS.
- Closure S5 (prompt to streamed reply): agent_chat_test.py:16-21 runs the real helper and the real CLI against the
  TLS fake API, and the step is registered (build.zig:2222, 3827). HOLDS.
- Closure S7 (read tool returns page text): agent_tools_test.py is registered (build.zig:2231, 3828). HOLDS. I did not re-run its mutant.
- Closure S8 ("an approved LinkedIn like commits exactly once"), P:3043: no test and no feature (rows 14-15).
  review_plan.md calls a missing BLOCKING closure test critical. FAILS, CONFIRMED.
- Lifecycle registration (review_plan.md Step 6.2, "implemented but not registered"): the after-gate orphan scan
  the plan relies on does not exist (row 18). The review says it does (R:152). FAILS, CONFIRMED.
- Green tests left out of the gate: (a) agent/host/tests/test_login_boundary.py went green in 522f252
  (2026-10-20, "the exchange boundary is the CLI's masked echo"), but build.zig never runs it. The plan cites it
  as the proof (P:2658). (b) tests/e2e/agent_approval_negatives_test.py (9f5b24e: 47/47 green, and its mutant
  fails 15 of 47) is the only test showing that a page, iframe, popup or model text cannot approve a card, and
  it is "unregistered" (its docstring, line 26). FAILS, CONFIRMED. SUSPECTED: reverting login.py's boundary fix
  would not fail the gate.

### Test-Spec Quality (review: 0 issues). 5 behaviors checked; 4 hold, 1 is misleading.
- S1.4: real property tests (roundtrip and invariant) in tests/agent_drawer_test.zig:63, 81, 169, 210, 222. HOLDS.
- S3.3: roundtrip and random-mutation properties in tests/agent_protocol_test.zig:157, 182. HOLDS.
- S6.2: a 10k oracle property in tests/agent_auth_test.zig:290. HOLDS.
- S7.5: the allowlist property reads a fixture, not source text (tests/agent_broker_test.zig:115-130). HOLDS.
- S8.3 and S8.6 (R:159 lists them as "run through the production path"): the 10k-tuple grant property
  (P:3016) has no test, and no grant exists to test. The plan spec is fine, but the review's wording says it runs.
  MISLEADING, CONFIRMED.
- Source-text oracles: none found in the drawer tests. The only source-reading tests I saw are WS7/MS6 recovery
  tests (tests/agent_run_recovery_startup_test.zig:189-198 and agent_startup_recovery_integration_test.zig:237),
  which belong to the parked Windows/startup-owner track, not this plan. This failure class mostly does not apply here.

## 3. Critical issues the review missed

C1. S8 is mostly not built, but the review calls the plan "implemented through roughly S8" (R:19). CONFIRMED.
    - Only 4 of D9's 30 S8 tools exist (bridge.py:45-75).
    - The exact-tuple grant for committing actions (S8.1-S8.7, threats T4 and T5) does not exist, and neither do
      its reds (agent_broker_grant_test.zig, agent_approval_test.py) or Closure Test S8.
    - The `account` expectation (S8a, S8.6) is absent.
    - What exists is decision 16's navigate/reload card, plus hover and scroll.
    - Impact: any enhance or validate step that trusts the review thinks the core write-safety slice is done.
      It is the riskiest unbuilt part of the plan.

C2. S9 is not built, and the review counts it as built ("9/10", R:171; "only fs_* absent", R:73). CONFIRMED.
    - The dialog, crash and freeze banners, the user-confirmed Recover card, and the webkit_shim to drawer
      notifications (P:3325) are absent, and so are their two e2e files.
    - Only the navigate-card part of S9.3 exists (agent_navigate_stale_test.py, registered).
    - The real absent list for S3-S10 is: most of S8, S9, and S10.

C3. The `agent-no-orphans` gate step (P:3486-3488) does not exist, and the review cites it as proof of closure (R:152). CONFIRMED.
    - No step in build.zig, and no `--zb-agent-gate` marker in any file under src, agent, tests, tools or build.zig.
    - Each e2e uses its own PID namespace, so leftovers are partly contained per test.
    - But the plan's gate-wide guarantee ("an early driver exit cannot hide a leftover agent") is not enforced.

C4. D7b's flow-control promises are stated but not built, and the review praises them as "strong" (R:107-108). CONFIRMED.
    - There is no 256-frame / 1 MiB inbound queue and no stop-reading backpressure (P:364-367).
    - There is no per-conversation view cap of 2,000 bubbles / 16 MiB (P:369).
    - The S5.6 rewrite (P:2077-2140) replaced only the per-reply contract. It never retracted these lines.
    - SUSPECTED impact: a long conversation grows the drawer's memory without limit. A GtkLabel costs about
      0.6 KB per character (P:2091), and nothing removes old bubbles.
    - This sits next to the review's own critical finding about the helper's memory (zigBrowser-4pa.16), and the
      review missed it.

C5. Green tests left out of the gate (details in §2). CONFIRMED.
    - test_login_boundary.py (green since 522f252).
    - agent_approval_negatives_test.py (green 9f5b24e, a forged-approval negative test).
    - Also committed and unregistered, but honestly labelled red: agent_broker_preview_test.zig and
      agent_previews_test.py (S8e part 2).
    - Not drawer scope: agent_helper_core_test.zig (MS8.2a red; it names src/agent_helper_core.zig, which is not
      in src/), plus three run-ledger and recovery reds.

## 4. Review claims that are wrong

W1. R:73 and R:171 say only fs_* is absent and 9 of 10 S3-S10 components are built. Wrong: see C1, C2 and the
    missing S10. CONFIRMED.
W2. R:19 and R:28 say the plan is implemented through roughly S8 and "faithfully implemented". Wrong for S8:
    see C1. Where code exists it does follow the plan's seams (rows 4, 11, 12). CONFIRMED.
W3. R:46 and R:143-152 say Workflow Closure is exemplary with 0 issues, including the agent-no-orphans step. Wrong:
    see C3, C5 and Closure S8. CONFIRMED.
W4. R:107-108 call the bounded queues and per-conversation caps strong promises. Wrong: they are not built (C4). CONFIRMED.
W5. R:194 says substantial macOS drawer work is built, including "wkwebview_shim.m drawer wiring". Wrong. CONFIRMED.
    - src/wkwebview_shim.m has 0 "drawer" references (at c07899f too), and there is no agent_drawer_mac.m.
    - The macOS AppKit drawer exports (agent_drawer.zig:632-636: zb_drawer_page_rect, zb_drawer_appkit_frame,
      zb_drawer_appkit_shown, zb_drawer_appkit_original_offset, zb_drawer_bubble_layout_contiguous) have no
      caller in any .c, .m or .cpp file. That matches the sibling reviews' "no production caller" class.
    - src/agent_secrets_window_mac.h:23 declares zb_secrets_window_open(unsigned long long). No .m implements it,
      and the Linux symbol of the same name takes no arguments (agent_secrets_window.c:188).
    - Windows is different: webview2_shim.cpp has 287 drawer references.
    - The review's scope warning is right, but for the wrong reason: the macOS work it says needs review mostly
      does not exist.
W6. R:122-124 say approval outcomes are a single terminal approvalend enum with
    {denied|expired|closed|crashed|revoked|done|changed|partial|failed|unknown}. The code has two enums:
    agent_approval.zig:188 `Outcome {waiting, approved, denied, expired, cancelled}` and agent_broker.zig:102
    `Ending {done, failed, changed, crashed, denied, expired, cancelled, revoked}`. There is no closed, partial or
    unknown. Minor. CONFIRMED.

## 5. Review claims that check out
- §2.0 is stale (R:166-171), and the plan does say "Not built: everything from S3 on" (P:104). CONFIRMED.
- The helper has no memory bound: no rlimit or cgroup in agent_host.c, agent_spawn_posix.c, sandbox.py or
  launch.py. CONFIRMED.
- The tri-platform drawer exports (agent_drawer.zig:602), uv.lock pinning SDK 0.2.165 with the CLI 2.1.294 only
  in p0_census.json, and the missing agent-host-unit/-contract labels. CONFIRMED.
- The automation_server seam line numbers (172, 202, 377, 509), and dispatchParsed having no agent.*, drawer.*
  or secrets.* routes. CONFIRMED.
- The broker refuses a model-supplied window_id (agent_broker.zig:404-414). CONFIRMED.

## 6. Failure classes from the sibling reviews, applied here
- Features the plan calls built that don't exist: the plan itself mostly doesn't do this. The review does
  (C1, C2, C3, W5). The plan's own unbuilt promise is D7b (C4).
- Tests that only grep source text: not found in the drawer tests (§2).
- Registered steps that pass with zero real rows: not found. The agent e2e steps fail closed, and the
  owned_group and sandbox_lifetime steps reject "skipped" (build.zig:2577, 2583). One remaining gap:
  test_netd_darwin_v6 and test_setup_darwin_r1_v6 skip silently without IPv6 (macOS track).
- Components with no production caller: the macOS AppKit drawer exports (W5). The Linux drawer, helper, broker,
  approval and auth paths all have callers (rows 4, 11, 12; agent_drawer.c:1218, 1228; agent_secrets_window.c:700).
- Current-state text that contradicts HEAD: plan §2.0 (caught by the review). D7b (missed, C4). Review R:194 itself (W5).
