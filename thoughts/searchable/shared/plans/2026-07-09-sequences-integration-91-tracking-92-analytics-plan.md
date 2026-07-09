---
date: 2026-07-09
author: Codex
repository: zigBrowser
topic: "TDD plan: zigBrowser automation tie-in for Sequences 9.1 tracking and 9.2 analytics"
tags: [tdd, plan, sequences, automation, tracking, analytics, integration]
status: ready_for_review
scope: "PRD 9.1 Sequence Tracking and PRD 9.2 Analytics only"
depends_on:
  - "/home/maceo/ntm_Dev/zigBrowser/thoughts/searchable/shared/plans/2026-07-09-sequences-integration-api-db-layer-plan.md"
  - "/home/maceo/ntm_Dev/sequences/thoughts/searchable/shared/prds/sequences/9.1-sequence-tracking.md"
  - "/home/maceo/ntm_Dev/sequences/thoughts/searchable/shared/prds/sequences/9.2-analytics.md"
last_updated: 2026-07-09
---

# Sequences Integration 9.1 Tracking + 9.2 Analytics TDD Plan

## Overview

This plan covers the product tie-in between zigBrowser's built automation runtime and the
Sequences product for PRD 9.1 Sequence Tracking and PRD 9.2 Outreach Analytics.

The slice has two responsibilities:

1. Track automation execution for each sequence/enrollment/message step that zigBrowser runs, with
   run state, step state, command traces, pacing/rate-limit/detection outcomes, and canonical
   business events linked together.
2. Feed Outreach Analytics from canonical `sequence_events` only, while using zigBrowser
   `automation.*` wide events as diagnostic context, not as KPI source data.

This plan intentionally does not design the Phase 0 API/DB layer internals. It consumes that layer
as the seam between zigBrowser and the Sequences PostgreSQL database. The requested Phase 0 contract
file was not present on disk at planning time, so the endpoint names below are expressed as required
contract capabilities. Bind them to the exact endpoint names and payload envelopes from
`2026-07-09-sequences-integration-api-db-layer-plan.md` before implementation.

## Current State Analysis

### Key Discoveries

- PRD 9.1 defines canonical open/click/delivery event names as `MessageOpened`, `LinkClicked`, and
  `MessageDelivered`, with dedupe keys and analytics-read constraints
  (`9.1-sequence-tracking.md:39`, `:92`, `:109`, `:176`, `:264`).
- PRD 9.2 requires every Outreach KPI to derive from `sequence_events`, with Open Rate and Click
  Rate counted from canonical open/click events and never from spans
  (`9.2-analytics.md:49`, `:55-60`, `:529-532`).
- The current 110 migration creates `sequence_events`, its `(org_id, dedup_key)` uniqueness, and
  forced RLS, but the `event_type` CHECK still lacks `MessageOpened`, `LinkClicked`, and
  `MessageDelivered` (`110_sequences_engine.sql:149`, `:166-180`, `:185-187`, `:391-396`).
- The existing event writer already has the idempotent insert behavior this slice should reuse
  (`backend/sequences_db.js:4`, `:13-28`), and the validator is the narrow place that must learn the
  new canonical event types (`backend/services/sequenceEvents/eventTypes.js:1`, `:17-36`).
- Existing metrics routes and services already expose sequence analytics/funnel reads, but they only
  reduce sent, bounced, replied, positive replied, and converted events today
  (`backend/routes/sequenceMetrics.js:34`, `:48`, `backend/services/sequenceMetrics/metricsService.js:183`,
  `:216-284`, `:345-356`).
- zigBrowser already has a local automation surface: `dom.*`/`page.*` verbs
  (`src/automation.zig:5`), root `automation.command` spans (`src/automation/telemetry.zig:147`),
  pacing decisions (`src/automation/pacing.zig:88`), detection signals
  (`src/automation/stealth.zig:231`), stealth assessments (`src/automation/stealth.zig:252`),
  JSON-RPC error correlation (`src/automation_rpc.zig:140-152`), and SDK command/event plumbing
  (`sdk/python/src/zigbrowser/client.py:281`, `sdk/node/src/client.ts:48`).
- There is no existing business-context carrier in zigBrowser for `org_id`, `sequence_id`,
  `enrollment_id`, `message_id`, or `step_id`; the integration layer must supply it without
  changing low-level automation command semantics.

## Phase 0 Contract Capabilities This Slice Requires

Bind these capabilities to the exact Phase 0 endpoint names when the contract plan exists.

### Writes

- **Automation run upsert:** create/update a run tied to `org_id`, `sequence_id`, optional
  `enrollment_id`, `message_id`, `step_id`, `actor_user_id`, `status`, `started_at`, `completed_at`,
  `error_code`, and `trace_id`.
- **Automation step/command append:** append step transitions and per-command summaries keyed by
  `automation_run_id`, `sequence_id`, `enrollment_id`, `message_id`, `step_id`, `trace_id`,
  `command_id`, `rpc.method`, `result.status`, `automation.error`, `target.host`, duration, retry
  count, and redacted selector/target hashes.
- **Automation diagnostic event append:** append non-KPI diagnostic events derived from
  `automation.pacing.decision`, `automation.stealth.assessment`, `automation.detection.signal`, and
  `automation.network.event` with only redacted/hash-safe attributes.
- **Canonical sequence event append:** call the Sequences event writer for business facts only:
  `MessageSent`, `MessageDelivered`, `MessageOpened`, `LinkClicked`, `ReplySynced`,
  `BounceSynced`, `SuppressionApplied`, and `EnrollmentStopped`.

### Reads

- **Automation dashboard read:** query run/step state, recent command summaries, diagnostic alerts,
  and linked canonical event IDs for the zigBrowser-hosted dashboard.
- **Sequence tracking read:** query per-sequence/per-enrollment statuses and event counts from
  canonical `sequence_events`, including open/click/reply/bounce/stop state.
- **Outreach analytics read:** extend or wrap the existing `GET /api/v1/sequences/analytics` route
  so 9.2 filters and groupings can read contacted/open/click/reply/interest/bounce metrics.
- **Analytics export read:** return the same filtered rows and raw numerator/denominator fields the
  UI displays.

## Desired End State

### Observable Behaviors

- Given a sequence step is executed by zigBrowser, when the first automation command starts, then a
  tenant-scoped automation run is visible in the zigBrowser dashboard as `running`.
- Given a command succeeds, fails, is cancelled, is rate limited, or emits a detection signal, when
  the run is read back, then the dashboard shows the terminal state with trace/command IDs and
  redacted diagnostic fields.
- Given an automation step produces a true outreach business fact, when that fact is persisted, then
  it is written as a canonical `sequence_events` row with an idempotent `dedup_key`.
- Given automation emits wide events, when Outreach Analytics computes KPI tiles, then those spans
  are ignored unless they were projected into canonical `sequence_events`.
- Given open/click/delivery events exist, when 9.2 metrics are computed, then Open Rate, Click Rate,
  delivered denominator, table columns, and exports use the PRD definitions.
- Given bot/prefetch opens are flagged in canonical payloads, when headline Open Rate is computed,
  then probable-bot opens are excluded but remain available in diagnostic drilldown.
- Given no Phase 0 contract is present, when integration tests run, then they fail at the contract
  binding boundary rather than silently inventing a second API or database writer.

## What We Are Not Doing

- No PRD 9.3 New Sequence Creation planning.
- No PRD 9.4 Sequence Step Authoring planning.
- No redesign of Phase 0 API routing, auth, database ownership, or connection pooling.
- No use of OTel spans, automation command success, or mutable ATS state as Outreach KPI sources.
- No raw PII persistence from selectors, typed text, DOM text, cookies, auth tokens, screenshots, or
  full URLs.
- No new parallel metrics source beside `sequence_events` and existing sequence metrics services.

## Data Mapping

### Tracking State

| zigBrowser source | Sequence tracking meaning | Persistence target |
|---|---|---|
| automation run start | Sequence/step execution began | Phase 0 automation run write |
| `automation.command` | Command summary and trace join key | Phase 0 command append, not KPI |
| JSON-RPC `error.data.trace_id` / `command_id` | Debug link from UI to trace | Phase 0 command append |
| `automation.pacing.decision` | Cap/delay/rate-limit diagnostic | Phase 0 diagnostic append |
| `automation.detection.signal` | Detection challenge/risk diagnostic | Phase 0 diagnostic append |
| `automation.stealth.assessment` | Stealth/risk surface diagnostic | Phase 0 diagnostic append |
| provider send success | Contacted/send business fact | `sequence_events.MessageSent` |
| provider delivery receipt | Delivered business fact | `sequence_events.MessageDelivered` |
| tracking pixel hit | Open business fact | `sequence_events.MessageOpened` |
| redirect hit | Click business fact and inferred open when needed | `sequence_events.LinkClicked` plus ensured `MessageOpened` |
| reply/bounce/stop webhooks | Reply, bounce, suppression, stop facts | Existing canonical event types |

### Analytics Metrics

| PRD 9.2 metric | Canonical source | Rule |
|---|---|---|
| Profiles Contacted | `MessageSent` | Distinct enrollments with first send inside cohort window |
| Open Rate | `MessageOpened` | Distinct enrollments with non-bot open / delivered denominator |
| Click Rate | `LinkClicked` | Distinct enrollments with at least one click / delivered denominator |
| Reply Rate | `ReplySynced` | Distinct replied enrollments / delivered denominator |
| Interest Rate | `ReplySynced.payload.reply_classification = positive` | Distinct positive replies / replies |
| Bounce Rate | `BounceSynced.payload.bounce_classification = hard` | Distinct hard-bounced enrollments / sent denominator |
| Delivered denominator | `MessageDelivered` if present, else `MessageSent - hard BounceSynced` | Provider-confirmed delivery wins; fallback preserved |

## Testing Strategy

- **Sequences unit tests:** Vitest tests for event vocabulary, payload validation, metrics reducer,
  analytics route query mapping, redaction, and empty/error states.
- **Sequences migration tests:** SQL shape tests for event type CHECK additions, dedup indexes, RLS,
  and any Phase 0-owned automation tables exposed by contract.
- **zigBrowser unit tests:** Zig tests for business-context correlation on automation telemetry
  adapters, redaction, and no raw selector/text leakage.
- **Cross-repo contract tests:** Node/Python integration tests with a fake Phase 0 server and fake
  zigBrowser command stream, proving required reads/writes and canonical event projection.
- **E2E smoke:** Launch zigBrowser with automation enabled, execute a fake sequence step, append
  canonical events through the Phase 0 seam, and read the dashboard/analytics result.

## Behavior 1: Contract Binding Fails Closed

### Test Specification

**Given** the 9.1/9.2 integration adapter is configured without the Phase 0 contract  
**When** a sequence automation run starts  
**Then** no automation data is written directly to PostgreSQL, the run fails with
`SEQUENCES_AUTOMATION_CONTRACT_UNAVAILABLE`, and the error is visible in the dashboard state.

Edge cases:
- Contract endpoint returns 404/501.
- Contract response omits required IDs.
- Contract returns a cross-org ID.

### TDD Cycle

**Red:** Add a cross-repo contract test that instantiates the zigBrowser-side sequences adapter with
no contract binding and asserts a fail-closed result.

Files:
- `/home/maceo/ntm_Dev/zigBrowser/tests/integration/sequences_contract_binding_test.py`
- `/home/maceo/ntm_Dev/zigBrowser/src/sequences_integration.zig` or the Phase 0 adapter filename

**Green:** Add a thin adapter interface in zigBrowser that can be backed by the Phase 0 API client,
returning typed unavailable errors without touching DB internals.

**Refactor:** Move shared error codes and response parsing into a small contract module consumed by
the dashboard and run executor.

Success criteria:
- `python3 tests/integration/sequences_contract_binding_test.py` fails before the adapter exists and
  passes once fail-closed behavior is implemented.
- No direct PostgreSQL connection string appears in zigBrowser code.

## Behavior 2: Automation Run and Step State Are Persisted With Business Context

### Test Specification

**Given** a sequence step execution request includes `org_id`, `sequence_id`, `enrollment_id`,
`message_id`, `step_id`, and `actor_user_id`  
**When** zigBrowser starts the run and executes `page.navigate` then `dom.click`  
**Then** Phase 0 receives one run start, one command append per command, a terminal step state, and
trace/command IDs that match zigBrowser telemetry.

Edge cases:
- Missing sequence context fails before command execution.
- A command returns `platform_rate_limited`.
- A command returns `cancelled`.
- A later retry keeps the same run ID but appends a new attempt.

### TDD Cycle

**Red:** Add a fake Phase 0 server test that records writes and asserts the run/step state sequence.

Files:
- `/home/maceo/ntm_Dev/zigBrowser/tests/integration/sequences_run_tracking_test.py`
- `/home/maceo/ntm_Dev/zigBrowser/sdk/python/tests/test_sequences_context.py`

**Green:** Add sequence context to the integration adapter and wrap SDK/CLI-driven automation runs
with run start/command append/terminal update calls.

**Refactor:** Keep context propagation outside `dom.*`/`page.*` router parsing so low-level
automation remains reusable.

Success criteria:
- `automation.command` command IDs join to persisted command summaries.
- Raw selector, typed text, token, cookie, and full URL values are absent from the captured payload.

## Behavior 3: Canonical Event Vocabulary Accepts 9.1 Event Types

### Test Specification

**Given** PRD 9.1's pinned event types  
**When** `appendIdempotentEvent` receives `MessageOpened`, `LinkClicked`, or `MessageDelivered`  
**Then** validation accepts the type, the migration CHECK permits it, and duplicate `dedup_key`
writes collapse to one row.

Edge cases:
- `MessageOpened` without `message_id` or `enrollment_id`.
- `LinkClicked` without `link_id`.
- `MessageDelivered` without `provider_message_id`.
- Unsupported lowercase names still fail.

### TDD Cycle

**Red:** Extend the current event-service and migration tests to fail on the missing event types.

Files:
- `/home/maceo/ntm_Dev/sequences/tests/unit/backend/services/sequencesEventService.test.js`
- `/home/maceo/ntm_Dev/sequences/tests/unit/backend/migrations/110_sequences_engine.test.js`

**Green:** Add the three event types to `CANONICAL_SEQUENCE_EVENT_TYPES`, payload required-field
validation, and the `sequence_events_event_type_chk` migration path.

**Refactor:** Put payload requirements near the existing `MessageSent` and `CandidateConverted`
requirements to keep one canonical validator.

Success criteria:
- `npx vitest run --no-cache tests/unit/backend/services/sequencesEventService.test.js`
- Migration shape test proves the CHECK and DB writer agree.

## Behavior 4: Tracking Projection Writes Canonical Business Facts Only

### Test Specification

**Given** zigBrowser automation completes a send step and the provider returns message/thread IDs  
**When** the integration projects the result  
**Then** a `MessageSent` row is appended with the existing required payload and an idempotent
dedup key; the automation run stores the linked event ID.

**Given** an automation command succeeds but no provider message ID exists  
**When** projection runs  
**Then** only automation run diagnostics are persisted and no `MessageSent` KPI row is created.

Edge cases:
- `platform_rate_limited` maps to run state `rate_limited`, not `MessageSent`.
- Detection challenge maps to run state `detection_halted`, not `MessageSent`.
- Duplicate send confirmation returns the existing event ID.

### TDD Cycle

**Red:** Add a projection service test with fake Phase 0 canonical append and command append clients.

Files:
- `/home/maceo/ntm_Dev/zigBrowser/tests/integration/sequences_canonical_projection_test.py`
- `/home/maceo/ntm_Dev/sequences/tests/unit/backend/services/sequenceAutomationProjection.test.js`

**Green:** Implement projection logic at the integration boundary: business facts use the canonical
event append capability; diagnostics use automation tracking writes.

**Refactor:** Isolate mapping tables for terminal states and event types so adding future non-email
sequence channels does not alter 9.2 KPI formulas.

Success criteria:
- An automation success without provider identifiers cannot inflate Profiles Contacted.
- Duplicate send confirmation proves `(org_id, dedup_key)` idempotency.

## Behavior 5: Open, Click, and Delivery Events Feed Tracking Status

### Test Specification

**Given** canonical `MessageOpened`, `LinkClicked`, and `MessageDelivered` rows exist for an
enrollment  
**When** the zigBrowser-hosted tracking dashboard reads that enrollment  
**Then** it shows delivered/opened/clicked state, per-message attribution, counters, and bot/open
diagnostics from canonical payloads.

Edge cases:
- Repeat opens/clicks increment payload counters but do not add rows.
- A click without a prior open ensures/infer an open for funnel consistency.
- Probable-bot open is shown in diagnostics but excluded from headline rate.

### TDD Cycle

**Red:** Add read-model tests against canonical event fixtures containing repeat opens, click-implies
open, and bot-flagged opens.

Files:
- `/home/maceo/ntm_Dev/sequences/tests/unit/backend/services/sequenceAutomationTrackingReadModel.test.js`
- `/home/maceo/ntm_Dev/zigBrowser/tests/integration/sequences_dashboard_tracking_test.py`

**Green:** Reuse `listSequenceEventsForMetrics`/analytics reads or Phase 0's read contract to build
tracking state without querying raw capture tables.

**Refactor:** Share event-normalization helpers with the analytics reducer where possible, but keep
dashboard status formatting out of the metric service.

Success criteria:
- Tracking dashboard state reconciles to exact canonical event IDs.
- Raw capture hits are never required by the zigBrowser dashboard.

## Behavior 6: Outreach Analytics Computes 9.2 KPIs From Canonical Events

### Test Specification

**Given** a filtered cohort with sends, delivered events, opens, clicks, replies, positive replies,
and hard bounces  
**When** analytics are computed  
**Then** KPI numerators, denominators, table columns, deltas, and zero guards match PRD 9.2.

Edge cases:
- Delivered denominator uses `MessageDelivered` when present.
- Without delivery confirmations, delivered falls back to sent minus hard bounce.
- Soft bounces remain visible but do not remove delivered denominator.
- Bot opens are excluded from Open Rate numerator.
- Multiple opens/clicks by the same enrollment count once for rate.

### TDD Cycle

**Red:** Extend `computeSequenceFunnel` tests with open/click/delivery fixtures and expected 9.2
fields.

Files:
- `/home/maceo/ntm_Dev/sequences/tests/unit/backend/services/sequencesMetricsService.test.js`
- `/home/maceo/ntm_Dev/sequences/tests/unit/backend/routes/sequenceMetrics.test.js`

**Green:** Extend the reducer output with `profiles_contacted`, `opens`, `clicks`, `open_rate`,
`click_rate`, `interest_rate`, and `bounce_rate` while preserving existing funnel fields.

**Refactor:** Split denominator/numerator helpers by metric to keep reply/interest/bounce formulas
auditable.

Success criteria:
- Existing tests for reply, positive reply, conversion, and TTFR still pass.
- New tests prove `automation.command` fixture events are rejected or ignored as noncanonical.

## Behavior 7: Analytics Filters, Grouping, and Export Reuse Existing Metrics Routes

### Test Specification

**Given** a manager requests Outreach Analytics with Sequence, Project, Started by, Inboxes, Date
range, and Grouped by filters  
**When** the route serves KPI/chart/table/export reads  
**Then** the same filtered event-derived cohort backs every surface and export includes raw
numerator/denominator fields.

Edge cases:
- Empty cohort returns zero tiles, zero-filled buckets, and empty table rows without 500.
- Non-manager analytics access remains forbidden.
- Prior-period denominator zero returns a no-baseline delta state.

### TDD Cycle

**Red:** Add route tests for filter forwarding and export shape around
`createSequenceMetricsRouter`.

Files:
- `/home/maceo/ntm_Dev/sequences/tests/unit/backend/routes/sequenceMetrics.test.js`
- `/home/maceo/ntm_Dev/sequences/tests/unit/backend/services/sequenceOutreachAnalyticsService.test.js`

**Green:** Extend the existing `/analytics` route or Phase 0 wrapper to accept PRD 9.2 filters and
return dashboard, chart, table, and export DTOs.

**Refactor:** Keep authorization in the route and query/cohort math in the service.

Success criteria:
- `authorizeDashboardAccess` remains enforced.
- All dashboard surfaces can reconcile row counts to the same event fixture set.

## Behavior 8: Automation Diagnostics Join Analytics Without Becoming KPI Sources

### Test Specification

**Given** a sequence has canonical sends plus automation diagnostics for pacing, stealth, detection,
and command failures  
**When** the dashboard displays diagnostics beside analytics  
**Then** diagnostics group by trace/run/sequence/enrollment, but KPI rates do not change unless a
canonical business event is appended.

Edge cases:
- Rate-limit detection suppresses projected send.
- Detection signal includes hashed DOM text only.
- Command failure has `trace_id` and `command_id` but no event ID.

### TDD Cycle

**Red:** Add reducer tests that mix canonical events with diagnostic automation records and assert
unchanged KPI outputs.

Files:
- `/home/maceo/ntm_Dev/sequences/tests/unit/backend/services/sequenceAutomationDiagnostics.test.js`
- `/home/maceo/ntm_Dev/zigBrowser/tests/automation/stealth_test.zig`
- `/home/maceo/ntm_Dev/zigBrowser/tests/automation/pacing_test.zig`

**Green:** Add diagnostic aggregation/read helpers that join by `automation_run_id`, `trace_id`, and
sequence IDs while keeping analytics reducers limited to `sequence_events`.

**Refactor:** Centralize redaction assertions in zigBrowser telemetry fixtures and Sequences API
request validation.

Success criteria:
- Open/click/reply/bounce rates are identical before and after adding diagnostic-only records.
- No raw text, selector, token, cookie, or full URL appears in diagnostic payload snapshots.

## Behavior 9: zigBrowser-Hosted Dashboard Reads Tracking and Analytics

### Test Specification

**Given** the Phase 0 read contract returns run state, linked event counts, analytics KPIs, and
diagnostic alerts  
**When** the zigBrowser dashboard loads  
**Then** it renders stable loading, empty, error, running, failed, completed, rate-limited, and
detection-halted states without direct DB access.

Edge cases:
- Phase 0 returns auth error.
- Analytics read succeeds but diagnostics read fails.
- Run state is terminal but late canonical events arrive later and update analytics.

### TDD Cycle

**Red:** Add dashboard service/client tests using fake Phase 0 responses.

Files:
- `/home/maceo/ntm_Dev/zigBrowser/tests/integration/sequences_dashboard_read_test.py`
- UI files as established by the Phase 0 dashboard hosting plan.

**Green:** Implement the dashboard read client and UI state adapter, consuming Phase 0 only.

**Refactor:** Keep UI copy/presentation separate from metric formulas and tracking projection code.

Success criteria:
- Dashboard tests pass with no PostgreSQL connection string in zigBrowser.
- Read failures are retryable and do not leak tenant/provider details.

## Behavior 10: Cross-Repo E2E Proves End-to-End Flow

### Test Specification

**Given** a fake sequence with one enrollment and a fake zigBrowser automation server  
**When** a step sends a message, receives delivery/open/click events, and the dashboard/analytics
reads back state  
**Then** run tracking, canonical sequence events, and 9.2 metrics all reconcile to the same IDs.

Edge cases:
- Duplicate send/open/click replay.
- Cross-org read attempt.
- Automation command failure before send.

### TDD Cycle

**Red:** Add a cross-repo E2E fixture that fails because Phase 0 contract binding and new event
types are absent.

Files:
- `/home/maceo/ntm_Dev/zigBrowser/tests/e2e/sequences_integration_91_92_test.py`
- `/home/maceo/ntm_Dev/sequences/tests/integration/sequences-automation-91-92.test.js`

**Green:** Wire the Phase 0 API client, canonical event projection, metrics reducer, and dashboard
read path.

**Refactor:** Replace fake servers with real local app instances only after unit/contract tests are
green.

Success criteria:
- Duplicate replays do not create duplicate canonical rows.
- Org B cannot read org A run state, event rows, or analytics.
- KPI values reconcile to exact canonical event IDs and not to automation spans.

## Implementation Order

1. Bind to Phase 0 contract capabilities and add fail-closed tests.
2. Add canonical event vocabulary and payload validation for `MessageOpened`, `LinkClicked`, and
   `MessageDelivered`.
3. Extend 9.2 metrics reducer with delivered/open/click/contacted denominators and zero guards.
4. Add automation run/step tracking writes around zigBrowser command execution.
5. Add canonical business-event projection from automation outcomes.
6. Add dashboard read models for tracking state and diagnostic alerts.
7. Add route/export coverage for 9.2 filters and grouped analytics.
8. Add cross-repo E2E reconciliation and tenant isolation tests.

## Verification Commands

From `/home/maceo/ntm_Dev/sequences`:

```bash
npx vitest run --no-cache tests/unit/backend/services/sequencesEventService.test.js
npx vitest run --no-cache tests/unit/backend/services/sequencesMetricsService.test.js
npx vitest run --no-cache tests/unit/backend/routes/sequenceMetrics.test.js
npx vitest run --no-cache tests/integration/sequences-automation-91-92.test.js
```

From `/home/maceo/ntm_Dev/zigBrowser`:

```bash
zig build test --summary all
python3 tests/integration/sequences_contract_binding_test.py
python3 tests/integration/sequences_run_tracking_test.py
python3 tests/e2e/sequences_integration_91_92_test.py --prefer-xvfb
```

## References

- PRD 9.1:
  `/home/maceo/ntm_Dev/sequences/thoughts/searchable/shared/prds/sequences/9.1-sequence-tracking.md`
- PRD 9.2:
  `/home/maceo/ntm_Dev/sequences/thoughts/searchable/shared/prds/sequences/9.2-analytics.md`
- Missing Phase 0 contract path:
  `/home/maceo/ntm_Dev/zigBrowser/thoughts/searchable/shared/plans/2026-07-09-sequences-integration-api-db-layer-plan.md`
- Existing sequences ledger:
  `/home/maceo/ntm_Dev/sequences/database/migrations/110_sequences_engine.sql`
- Existing metrics route:
  `/home/maceo/ntm_Dev/sequences/backend/routes/sequenceMetrics.js`
- Existing metrics reducer:
  `/home/maceo/ntm_Dev/sequences/backend/services/sequenceMetrics/metricsService.js`
- Existing event writer:
  `/home/maceo/ntm_Dev/sequences/backend/services/sequenceEvents/eventService.js`
- Existing zigBrowser automation surfaces:
  `/home/maceo/ntm_Dev/zigBrowser/src/automation.zig`,
  `/home/maceo/ntm_Dev/zigBrowser/src/automation/telemetry.zig`,
  `/home/maceo/ntm_Dev/zigBrowser/src/automation/pacing.zig`,
  `/home/maceo/ntm_Dev/zigBrowser/src/automation/stealth.zig`,
  `/home/maceo/ntm_Dev/zigBrowser/src/automation_rpc.zig`
