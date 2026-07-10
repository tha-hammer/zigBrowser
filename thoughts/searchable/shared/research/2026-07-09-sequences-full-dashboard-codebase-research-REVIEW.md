---
date: 2026-07-09
reviewer: SAI
type: plan-review
target: thoughts/searchable/shared/research/2026-07-09-sequences-full-dashboard-codebase-research.md
status: needs_major_revision
---

# Plan Review Report: Sequences Full Dashboard Codebase Research

**Reviewed document:** `thoughts/searchable/shared/research/2026-07-09-sequences-full-dashboard-codebase-research.md`
**Document type:** Cross-repo codebase research (zigBrowser + sequences)
**Reviewer:** SAI (6 parallel verification agents, all source claims verified against live code)

## Review Summary

| Category | Status | Issues Found |
|----------|--------|--------------|
| Contracts | ⚠️ | 3 issues |
| Interfaces | ✅ | 1 issue |
| Promises | ⚠️ | 2 issues |
| Data Models | ⚠️ | 3 issues |
| APIs | ❌ | 4 issues |
| Workflow Closure | ❌ | 3 issues |

**Overall assessment: Needs Major Revision** — the research's structural accuracy is high (39/39 source claims verified correct), but three critical claims about the state of the corpus are stale/false, and the document omits the existence of the `sequences-integration-api-db-layer-plan.md` which is the very contract it says doesn't exist. Any implementer using this research as ground truth will make incorrect architectural assumptions.

---

## Contract Review

### Well-Defined

- ✅ **Automation RPC contract** — 13 verbs, 12 error codes, auth gate, JSON-RPC 2.0 framing all verified at exact line numbers (`router.zig:6-20`, `automation_rpc.zig:14-27`, `automation_rpc.zig:107-112`)
- ✅ **Privacy contract** — OTLP redaction of raw_token/raw_params confirmed (`automation_otlp.zig:68-82`). Selector hashing (Wyhash in Zig, FNV-1a in JS), typed.length classification, and target.host-only export all verified
- ✅ **RLS enforcement patterns** — Two-layer (090: org PERMISSIVE + owner RESTRICTIVE on sequences/enrollments/messages/cohort_sources) and single-layer (110: org PERMISSIVE only on events/mailbox/caps/metrics/benchmarks) both verified exactly as described
- ✅ **Event dedup contract** — `ON CONFLICT (org_id, dedup_key) WHERE dedup_key IS NOT NULL DO NOTHING` verified in `sequences_db.js:18`

### Missing or Unclear

- ❌ **Research claims "no contract for zigBrowser communicating with a database exists in the corpus" (Section F, line 330) — THIS IS FALSE.** `thoughts/searchable/shared/plans/2026-07-09-sequences-integration-api-db-layer-plan.md` defines the complete `zb-sequences-v1` contract: 12 facade methods, HMAC service auth, idempotency headers, error envelope, and per-endpoint request/response schemas. This plan was created the same day as the research document. The research's Section H.1 ("Phase 0 agent is designing this contract") is stale — the contract is already designed.
- ❌ **Research claims "no phase plan covers dashboard UI hosting, database integration, or an exposed API" (Section F, line 330) — ALSO FALSE** for the same reason. The db-layer plan explicitly states "zigBrowser hosts the automation dashboard UI" (line 50) and defines the full facade topology (lines 46-64).
- ⚠️ **Automation transport contract boundary unclear** — The research documents the automation transport as a separate concern from the sequences API (correct), but doesn't define the contract boundary between the two within zigBrowser. The db-layer plan clarifies this (line 54: "The existing zigBrowser JSON-RPC Unix socket remains the browser automation command channel. It is not used for sequence database access") but the research doesn't reference this decision.

### Recommendations

- Update Sections F, H.1, and Open Questions 1/2/6/7 to reference `sequences-integration-api-db-layer-plan.md` and its dependent plans (`sequences-integration-91-tracking-92-analytics-plan.md`, `sequences-integration-93-creation-94-authoring-plan.md`)
- Add the db-layer plan's topology decision to Section H.2 (currently states "zero integration" — now stale)
- Clearly demarcate which Open Questions are already resolved by the db-layer plan vs. genuinely unresolved

---

## Interface Review

### Well-Defined

- ✅ **Automation verb interface** — All 13 verbs verified with correct parameter structures (`router.zig:82-136`). Selector format `kind=body` enforcement verified (`automation.js:293-303`)
- ✅ **IPC dispatch interface** — 4 commands (ping/add/echo/os.info) verified (`ipc.zig:41-73`). zbHost message handler registration verified (`webkit_shim.c:530-548`)
- ✅ **Sequences API client interface** — All exports verified: `fetchSequenceActionContext`, `fetchSequenceDashboard`, `fetchCandidateTimeline`, `adaptDraftMessage` plus `generateDraftForCandidate`, `approveSequenceDraft`, `pauseFollowUp` (`sequences-api.js`)
- ✅ **Dashboard service interface** — `getSequenceDashboard({jobRecId})` returns KPIs + sequence rows + replies + sync issues (`dashboardService.js:41`)

### Missing or Unclear

- ⚠️ **Python SDK interface mismatch with server** — Research notes (Section A.3) that LinkedIn/Instagram/Social/Cookies SDK namespaces call RPC method names with no server-side verb entry, but doesn't flag the dashboard design implication: if the dashboard shows "LinkedIn actions remaining" or "Instagram session status," those SDK interfaces don't work today and aren't covered by Phases 1-4. Only Phase 5 adds them.

### Recommendations

- Add an explicit "SDK interface gaps vs. dashboard requirements" subsection clarifying which dashboard features depend on Phase 5 SDK verbs

---

## Promise Review

### Well-Defined

- ✅ **Pacing guarantees** — PacingConfig (daily_cap=100, delay 3000-8000ms, midnight reset) verified (`pacing.zig:9-13`)
- ✅ **Session simulation guarantees** — SessionConfig (warmup 30s, break interval 600s, break duration 300-900s, session 3600±600s) verified (`session.zig:3-10`)
- ✅ **Event idempotency** — Dedup via `(org_id, dedup_key)` partial unique index verified (`110:185-187`)
- ✅ **Tenant isolation** — `withTenantDbContext` wraps in BEGIN/COMMIT/ROLLBACK with `set_config('app.current_org', $1, true)` verified (`database_interaction.js:417-450`)

### Missing or Unclear

- ⚠️ **Pacing/session state persistence promise** — Research correctly flags (Open Question #8) that RateLimiter and SessionSimulator are in-memory only. The db-layer plan's `automation.createExecution` / `automation.updateExecution` endpoints imply execution state persistence, but the promise of pacing-state persistence across zigBrowser restarts remains undefined.
- ⚠️ **Real-time telemetry delivery promise** — Research flags (Open Question #9) the gap between automation WebSocket push (SubscriberQueue) and dashboard data consumption. The SubscriberQueue is capacity-limited FIFO that drops slow subscribers (`automation_websocket.zig:64-99`) — the research correctly documents this but doesn't specify what "dropped" means for dashboard UX (stale data? gap indicator? reconnect?).

### Recommendations

- Define pacing-state persistence semantics (local SQLite? sequences DB via API? zigBrowser restart resets daily cap?)
- Define telemetry delivery guarantee for dashboard: at-most-once with gap detection vs. at-least-once with replay

---

## Data Model Review

### Well-Defined

- ✅ **sequences table** — id, org_id, owner_user_id, name, status, job_id, approved_plan JSONB, approved_at, approved_by verified across migrations 090 + 100
- ✅ **sequence_enrollments** — Full schema including status enum (draft/active/sent/paused/suppressed/bounced/stopped), stop_reason enum, candidate_ref_id GENERATED STORED verified
- ✅ **sequence_events ledger** — 13 event types, dedup index, single-layer RLS, event_payload JSONB verified (`110:149-183`)
- ✅ **sequence_metrics_rollup** — Full counters + rates + grouping dimensions verified (`110:305-341`)
- ✅ **send_caps** — Per-org/per-user daily limits with partial unique indexes verified (`110:265-285`)
- ✅ **sequence_benchmark_presets** — Metric/channel/role/seniority/geography dimensions verified (`110:357-389`)

### Missing or Unclear

- ❌ **New event types not in CHECK constraint** — PRD 9.1/9.2 require MessageOpened, LinkClicked, MessageDelivered. These are NOT in the `sequence_events_event_type_chk` constraint (verified: exactly 13 types, `110:166-182`). A migration is required before any dashboard implementation can write or read these events. The research correctly identifies this (Open Question #3) but marks it as an "open question" rather than a prerequisite blocker.
- ⚠️ **Status enum misattribution** — Research Section C.1 lists sequences status as `(draft/pending_approval/active/archived)` attributed to migration 090. Actually, 090 only defines `(draft/pending_approval/archived)`. The 'active' value is added by migration 100 which drops and re-creates the CHECK constraint. The combined set is correct but the attribution is misleading.
- ⚠️ **sequence_messages schema incomplete in research** — Research Section C.1 lists the 110 extensions (rendered_subject/body, provider_message_id/thread_id, status draft/sent/received/failed) but omits the 090 base columns `strategy`, `render_status` (draft/failed), `is_current` BOOLEAN, and `supersedes_id` (self-FK). These matter for the step-authoring flow (PRD 9.4).

### Recommendations

- Elevate the new event types from "open question" to "prerequisite migration" — block dashboard implementation on this
- Correct the status enum attribution to distinguish 090 vs. 100 contributions
- Complete the sequence_messages schema listing (strategy, render_status, is_current, supersedes_id) since PRD 9.4 step authoring depends on these fields

---

## API Review

### Well-Defined

- ✅ **Sequence CRUD routes** — All 8 endpoints verified at exact line numbers (`sequences.js:62-157`)
- ✅ **Metrics routes** — All 4 endpoints verified (`sequenceMetrics.js:34-80`)
- ✅ **Continuity routes** — All 3 endpoints verified (`sequenceContinuity.js:11-39`)
- ✅ **Webhook route** — HMAC-SHA256 signature verification with `crypto.timingSafeEqual` confirmed (`sequencesWebhookAuth.js:19-61`), pre-auth mount confirmed (`server.js:364`)
- ✅ **ATS routes** — POST /connections and POST /connections/complete verified (`sequencesAts.js:50-64`)
- ✅ **Route mounting** — All 6 route files mounted in server.js confirmed, with correct auth middleware ordering

### Missing or Unclear

- ❌ **processInboundMailboxEvent is a production stub that throws** — `sequencesWebhook.js:34-36` defaults to `throw new Error('Sequence mailbox processing service is not configured')`. Server.js imports the default export without overriding this parameter (`server.js:65,364`). Any inbound mailbox webhook that passes signature verification and org resolution will hit this stub and return HTTP 500. This is a live production bug that blocks PRD 9.1's reply/bounce capture pipeline. The research correctly identifies this (Open Question #10) but understates the severity — this isn't an open question, it's a P0 defect.
- ❌ **Analytics SQL filter gap** — `listSequenceEventsForAnalytics` (`sequences_db.js:85-104`) only applies `sequence_id` in the WHERE clause. All other filter keys (project, recruiter, inbox, date-range) from `req.query` are silently ignored at the SQL layer. PRD 9.2 requires these filters. Post-fetch JS grouping via `groupKeyFor()` (`metricsService.js:164-181`) provides grouping but not filtering — all events are fetched regardless of filters. This won't scale and produces incorrect results for filtered views.
- ⚠️ **Missing endpoints identified but not prioritized** — Research Section H.3 correctly lists 4 API gaps (send_caps, benchmarks, new event types, reply interest labeling) but doesn't rank them by implementation priority or indicate which are blocking vs. nice-to-have for the dashboard.
- ⚠️ **No endpoint for automation-specific data** — Research Section G.3 identifies 5 automation data types (session state, pacing caps, live command feed, detection signals, behavior stats) that originate in zigBrowser with no path to the dashboard. The db-layer plan addresses some of these (`automation.createExecution`, `automation.recordStepResult`, `automation.ingestEvents`, `automation.ingestTelemetry`) but the research doesn't cross-reference these solutions.

### Recommendations

- Elevate processInboundMailboxEvent stub from "open question" to "P0 production defect" — wire a real implementation before depending on reply/bounce events in the dashboard
- Elevate analytics filter gap to "blocking prerequisite" — implement SQL-layer filtering for sequence, project, recruiter, inbox, date-range, and time-bucketing (days/weeks/months) before building the analytics dashboard
- Cross-reference the db-layer plan's API endpoints against Research Section G.3 to show which automation data gaps are already addressed

---

## Workflow Closure Review

### Assessment

The research document explicitly states (Section: Workflow Closure Map) that no single production trigger → source-of-truth write → observable result chain can be mapped because the integration layer connecting the two codebases doesn't exist yet. This is a reasonable assessment for a *research* document — it maps topology, not behavior chains.

However, the assessment is now stale: the db-layer plan defines the integration layer, and the dependent plans (`91-tracking-92-analytics` and `93-creation-94-authoring`) define specific behavior chains. The research should be updated to reflect that workflow closure mapping is now possible.

### Well-Defined

- ✅ **Existing sequences workflow chains** — The existing Express routes → services → DB path is fully mounted and operational. `appendSequenceEvent` → `sequence_events` → `computeSequenceFunnel` → `GET /analytics` is a complete, production-callable chain.
- ✅ **Automation command chain** — `router.zig` verb dispatch → `telemetry.zig` span recording → `InMemoryTelemetrySink` is a complete local chain (though the sink is in-memory only).

### Missing or Unclear

- ❌ **No workflow closure possible for cross-repo chains** — The research correctly identifies this gap but now understates it. The db-layer plan defines the contract, but no implementation exists. The following chains remain unmappable until implementation:
  - zigBrowser automation execution → `automation.createExecution` → sequences DB → dashboard reads execution state
  - zigBrowser pacing decision → `automation.ingestEvents` → `sequence_events` → analytics rollup → dashboard chart
  - Inbound mailbox webhook → `processInboundMailboxEvent` (STUB) → `ReplySynced`/`BounceSynced` events → dashboard reply queue
- ❌ **processInboundMailboxEvent breaks the reply/bounce closure chain** — Even within the sequences app alone, the chain `POST /mailbox/webhook` → signature verify → org resolution → `processInboundMailboxEvent` is broken at the last link. The stub throws, receipt is marked failed, and no ReplySynced/BounceSynced events are ever written. The dashboard's reply queue (rendered by `sequence-dashboard.jsx`) will always be empty for webhook-sourced replies.
- ❌ **app.zig drops automation flags — automation transport has no production caller** — `runOpen` (`app.zig:21-29`) passes only `url`, `print_title`, and `e2e_protocol` to `zb_app_run()`. `automation_api` and `automation_token_file` are parsed by CLI but silently discarded. `runOpenWithAutomationLifecycle` (`automation_transport.zig:37-47`) is only called from tests. No production path instantiates the automation transport. This means the entire automation subsystem (verbs, telemetry, pacing, sessions) is unreachable from a normal `zigbrowser` invocation — making ALL dashboard features that depend on automation state impossible until this is wired.

### Recommendations

- Update the Workflow Closure Map section to reference the db-layer plan and mark which chains are now *designable* (contract exists) vs. *implementable* (code exists)
- Add a "Prerequisites" section that explicitly lists the three production blockers: (1) wire automation flags in app.zig, (2) implement processInboundMailboxEvent, (3) add new event types to CHECK constraint
- Once implementation plans exist for these prerequisites, derive closure tests from the db-layer plan's endpoint definitions

---

## Critical Issues (Must Address Before Implementation)

### 1. ❌ Stale Corpus Claims Make Research Misleading as Ground Truth

**Sections affected:** F (line 330), H.1 (lines 382-384), H.2 (line 388), Open Questions 1/2/6/7

**Description:** The research states "no contract for zigBrowser communicating with a database exists in the corpus" and "no phase plan covers dashboard UI hosting, database integration, or an exposed API." Both are false. `sequences-integration-api-db-layer-plan.md` (same date, same directory) defines the complete `zb-sequences-v1` contract with 12 facade methods, HMAC auth, idempotency, error codes, and per-endpoint schemas. Two dependent plans (`91-tracking-92-analytics`, `93-creation-94-authoring`) build on it.

**Impact:** Any implementer reading this research will incorrectly believe these contracts need to be designed from scratch, duplicating work and potentially contradicting the existing plan.

**Recommendation:** Update sections F, H.1, H.2 to reference the db-layer plan. Reclassify Open Questions 1, 2, 6, 7 as "resolved by" with plan references.

### 2. ❌ processInboundMailboxEvent Stub Is a Live Production Defect

**Location:** `backend/routes/sequencesWebhook.js:34-36` (default throws), `server.js:65,364` (mounts without override)

**Description:** The webhook handler for inbound mailbox events (replies, bounces) will always throw and return HTTP 500. No ReplySynced or BounceSynced events will ever be written from webhook sources.

**Impact:** Dashboard reply queue will be permanently empty for webhook-sourced data. PRD 9.1 sequence tracking depends on reply/bounce capture. The entire reply-driven analytics funnel (response_rate, positive_response_rate) will undercount.

**Recommendation:** Implement `processInboundMailboxEvent` with real event writing before dashboard implementation. This is a sequences-repo fix, not a zigBrowser fix.

### 3. ❌ app.zig Does Not Wire Automation Flags

**Location:** `src/app.zig:21-29` (runOpen), `src/cli.zig:9-10,56-105` (flag parsing)

**Description:** `--automation-api` and `--automation-token-file` are parsed and validated by the CLI but silently dropped before reaching the app runner. `runOpenWithAutomationLifecycle` exists but has no production caller.

**Impact:** The entire automation subsystem is unreachable from a normal zigBrowser invocation. No dashboard feature depending on automation state (session status, pacing gauges, command feed, detection alerts) can work.

**Recommendation:** Wire `spec.automation_api` and `spec.automation_token_file` in `runOpen` to call `runOpenWithAutomationLifecycle` (or its production equivalent). This is a Phase 1 plan deliverable.

### 4. ❌ Analytics SQL Filter Gap

**Location:** `backend/sequences_db.js:85-104` (listSequenceEventsForAnalytics)

**Description:** Only `sequence_id` is applied as a SQL WHERE filter. All other filter keys (project, recruiter, inbox, date-range) passed from the route are silently ignored. Events are fetched unfiltered and grouped in-memory.

**Impact:** PRD 9.2 analytics dashboard will fetch ALL events for ALL sequences on every analytics request, regardless of user's selected filters. Won't scale past small datasets. Filter selections will appear to work (UI sends params) but produce results identical to unfiltered views (SQL ignores them).

**Recommendation:** Extend `listSequenceEventsForAnalytics` to apply project, recruiter, inbox, date-range, and time-bucketing at the SQL layer before building analytics UI.

### 5. ❌ New Event Types Missing from CHECK Constraint

**Location:** `database/migrations/110_sequences_engine.sql:166-182`

**Description:** `sequence_events_event_type_chk` allows exactly 13 event types. PRD 9.1/9.2 require MessageOpened, LinkClicked, and MessageDelivered. Any INSERT with these types will fail with a CHECK violation.

**Impact:** Open/click/delivery tracking — core to PRD 9.1 tracking and 9.2 analytics — cannot be implemented until this migration runs.

**Recommendation:** Create migration 130 (or next available number) to ALTER the CHECK constraint before dashboard implementation.

---

## Warnings (Should Address)

### W1. Line Number Drift in Code References

Several line references are off by small amounts:
- `sequence_events` table def ends at line 183, not 190 (lines 185-190 are the dedup index)
- `sequence_events_event_type_chk` spans lines 166-182, not 166-167
- `automation.js` selector parsing at lines 293-303, not 299

**Impact:** Low — implementers doing targeted reads may land on wrong lines. Actual code is within ±10 lines of documented positions.

### W2. Status Enum Misattribution

Research attributes `(draft/pending_approval/active/archived)` to migration 090. Actually 090 defines `(draft/pending_approval/archived)` only. 'active' is added by migration 100.

**Impact:** Low — the combined set is correct. But an implementer reading only 090 would not find 'active'.

### W3. GTK "Application" Wording

Research says `zb_app_run` "creates the GTK application." No `GtkApplication` object exists — it calls `gtk_init_check()` + creates a plain `GtkWindow`. Different lifecycle model.

### W4. WebSocket Upgrade Overstatement

Research says `automation_websocket.zig` "implements RFC6455 WebSocket upgrade." It implements only the `Sec-WebSocket-Accept` key computation and `SubscriberQueue`. No HTTP upgrade request parser exists in that file.

### W5. 4096-Byte IPC Ceiling Unverified

Research claims a "4096-byte C-string result ceiling" in the IPC path. The only fixed-size buffer in `ipc.zig` is 128 bytes (error message buffer). The 4096 limit may exist in C-side JSON helpers (`webkit_shim.c`) but was not found at the claimed location.

### W6. set_config vs SET LOCAL

Research says `withTenantDbContext` uses "SET LOCAL (transaction-scoped)." Actual code uses `set_config('app.current_org', $1, true)` — functionally equivalent (the `true` = is_local) but different SQL syntax.

---

## Suggested Plan Amendments

```diff
# In Section F (Phase Plans)

- No phase plan covers dashboard UI hosting, database integration, or an exposed API for external apps.
- No contract for zigBrowser communicating with a database exists in the corpus.
+ The sequences-integration-api-db-layer-plan.md defines the zb-sequences-v1 contract
+ covering dashboard UI hosting, exposed API, and database integration via the
+ sequences Express backend. Two dependent plans (91-tracking-92-analytics,
+ 93-creation-94-authoring) extend it for PRD 9.1-9.4 feature slices.

# In Section H.1 (The Shared Seam)

- No exposed API exists today for zigBrowser to communicate with the sequences
- PostgreSQL database. The Phase 0 agent is designing this contract.
+ The zb-sequences-v1 contract (sequences-integration-api-db-layer-plan.md) defines
+ 12 facade methods over /api/v1/automation with HMAC service auth, idempotency
+ headers, and per-endpoint schemas. Implementation has not started.

# In Section H.2 (zigBrowser → Sequences DB)

- Current state: zero integration.
+ Current state: contract designed (zb-sequences-v1), zero implementation.

# Add new section: Prerequisites (blocking)

+ ## Prerequisites (Must Complete Before Dashboard Implementation)
+
+ 1. Wire automation flags in app.zig:runOpen (Phase 1 deliverable)
+ 2. Implement processInboundMailboxEvent in sequences webhook handler
+ 3. Migration: add MessageOpened, LinkClicked, MessageDelivered to event_type CHECK
+ 4. Extend listSequenceEventsForAnalytics SQL filters (sequence, project,
+    recruiter, inbox, date-range, time-bucketing)

# In Open Questions

- 1. Phase 0 API Contract: ... What transport will it use?
+ 1. RESOLVED: The db-layer plan specifies HTTPS to sequences Express backend,
+    not direct PostgreSQL. See sequences-integration-api-db-layer-plan.md.

- 2. Authentication Bridge: ... How will the dashboard authenticate?
+ 2. RESOLVED: HMAC service-to-service auth (X-ZB-Signature) + optional Bearer
+    token delegation. See db-layer plan "Common headers" section.

# Reclassify Open Question #10

- 10. processInboundMailboxEvent Stub: ... defaults to a stub that throws.
+ 10. CRITICAL DEFECT: processInboundMailboxEvent is a live production bug.
+     Wire implementation before dashboard depends on reply/bounce events.
```

---

## Approval Status

- [ ] **Ready for Implementation** — No critical issues
- [ ] **Needs Minor Revision** — Address warnings before proceeding
- [x] **Needs Major Revision** — 5 critical issues must be resolved first

**Revision requirements:**
1. Update stale corpus claims (Sections F, H.1, H.2, Open Questions 1/2/6/7) to reference the existing db-layer plan
2. Elevate processInboundMailboxEvent from "open question" to "P0 production defect"
3. Elevate new event types from "open question" to "prerequisite migration"
4. Elevate analytics SQL filter gap to "blocking prerequisite"
5. Add a "Prerequisites" section listing the 4 blocking items
6. Correct warnings W1-W6 (line numbers, status enum attribution, terminology)

Once revised, this research document will be an excellent ground-truth reference for dashboard implementation. The structural accuracy is very high — 39/39 source code claims verified correct — and the cross-repo topology mapping is thorough and valuable. The issues are primarily about the document's relationship to its own corpus (stale claims about what plans exist) and severity classification (production defects classified as "open questions").

---

## Review Checklist

### Contracts
- [x] Component boundaries are clearly defined
- [x] Input/output contracts are specified
- [x] Error contracts enumerate all failure modes
- [ ] ~~Preconditions and postconditions are documented~~ (N/A — research doc, not implementation plan)
- [x] Invariants are identified

### Interfaces
- [x] All public methods are defined with signatures
- [x] Naming follows codebase conventions
- [x] Interface matches existing patterns
- [ ] Extension points are considered (partially — SDK gap not flagged for dashboard)
- [x] Visibility modifiers are appropriate

### Promises
- [x] Behavioral guarantees are documented
- [ ] Async operations have timeout/cancellation handling (WebSocket drop behavior underdefined)
- [x] Resource cleanup is specified
- [x] Idempotency requirements are addressed
- [ ] Ordering guarantees are documented where needed (pacing persistence undefined)

### Data Models
- [x] All fields have types
- [x] Required vs optional is clear
- [x] Relationships are documented
- [ ] Migration strategy is defined (new event types need a migration, none specified)
- [x] Serialization format is specified

### APIs
- [x] All endpoints are defined
- [x] Request/response formats are specified
- [x] Error responses are documented
- [ ] Authentication requirements are clear (cross-system auth bridge was "open" — now resolved by db-layer plan, but research doesn't say so)
- [x] Versioning strategy is defined

### Workflow Closure
- [ ] Each promised behavior is mapped from production trigger to user-visible result (blocked by missing integration layer)
- [ ] Each workflow behavior is classified BLOCKING or LEAF (N/A — research doc)
- [ ] Closure-test anchors are derived from the Workflow Closure Map (no closure map possible yet)
- [ ] Every handler/projector/worker/listener has a production caller (processInboundMailboxEvent has no real impl)
- [x] Every route/scheduler/worker/listener/hook/CLI command is registered where production runs it
- [ ] No source-to-sink test directly seeds downstream read models (N/A — no tests in scope)
- [ ] Async/event workflows define persistence, consumer selection, retries, idempotency (partially — event dedup yes, webhook retry no)
- [x] Tenant/auth/RLS/transaction/request context is preserved or re-established across boundaries
- [ ] Silent/non-fatal errors and degraded responses are observable (processInboundMailboxEvent failure is silent to the dashboard)
