---
date: 2026-07-09
author: Codex
repository: zigBrowser
topic: "TDD plan: zigBrowser automation tie-in for Sequences 9.1 tracking and 9.2 analytics"
tags: [tdd, plan, sequences, automation, tracking, analytics, integration]
status: ready_for_implementation
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

This plan intentionally does not redesign the Phase 0 API/DB layer internals. It consumes the
concrete `zb-sequences-v1` backend contract in
`2026-07-09-sequences-integration-api-db-layer-plan.md` as the only product seam between
zigBrowser and the Sequences PostgreSQL database. Existing `/api/v1/sequences/*` routes and
services may be reused behind that backend contract, but zigBrowser must bind only to
`/api/v1/automation/*`.

## Current State Analysis

### Key Discoveries

- PRD 9.1 defines canonical open/click/delivery event names as `MessageOpened`, `LinkClicked`, and
  `MessageDelivered`, with dedupe keys and analytics-read constraints
  (`9.1-sequence-tracking.md:39`, `:92`, `:109`, `:176`, `:264`).
- PRD 9.2 requires every Outreach KPI to derive from `sequence_events`, with Open Rate and Click
  Rate counted from canonical open/click events and never from spans
  (`9.2-analytics.md:49`, `:55-60`, `:529-532`).
- Migration 110 creates `sequence_events`, its `(org_id, dedup_key)` uniqueness, and forced RLS;
  migration 130 additively amends `sequence_events_event_type_chk` for `MessageOpened`,
  `LinkClicked`, and `MessageDelivered` and introduces raw open/click capture tables
  (`110_sequences_engine.sql:149`, `:166-180`, `:185-187`, `:391-396`,
  `130_sequence_tracking.sql:1-40`).
- The existing event writer derives `org_id` from tenant context and currently dedupes with
  `ON CONFLICT ... DO NOTHING` (`backend/sequences_db.js:4-33`). That is sufficient for
  same-payload duplicate collapse but not for PRD 9.1 repeat open/click counter updates or
  different-payload idempotency conflicts.
- The JS event allowlist already includes `MessageOpened`, `LinkClicked`, and `MessageDelivered`,
  but event-specific payload requirements still need to be added near `MessageSent` and
  `CandidateConverted` (`backend/services/sequenceEvents/eventTypes.js:1-64`).
- Existing outreach analytics services already expose filters, date buckets, table controls, and
  PRD-like denominator helpers, while the older generic analytics reader still filters only by
  `sequenceId` (`backend/routes/sequenceMetrics.js:47-90`,
  `backend/services/sequenceMetrics/outreachAnalyticsService.js:1-742`,
  `backend/sequences_db.js:85-100`).
- zigBrowser already has a local automation surface: `dom.*`/`page.*` verbs
  (`src/automation.zig:5`), root `automation.command` spans (`src/automation/telemetry.zig:147`),
  pacing decisions (`src/automation/pacing.zig:88`), detection signals
  (`src/automation/stealth.zig:231`), stealth assessments (`src/automation/stealth.zig:252`),
  JSON-RPC error correlation (`src/automation_rpc.zig:140-152`), and SDK command/event plumbing
  (`sdk/python/src/zigbrowser/client.py:281`, `sdk/node/src/client.ts:48`).
- There is no existing business-context carrier in zigBrowser for backend-issued `sequenceId`,
  `executionPlanId`, `stepExecutionId`, `enrollmentId`, `messageId`, or `stepId`; the integration
  layer must supply those identifiers without changing low-level automation command semantics.

## Concrete Phase 0 Binding

Contract name: `zb-sequences-v1`

Backend base path: `/api/v1/automation`

zigBrowser binds to these method names and backend endpoints exactly:

| Facade method | Backend endpoint | Used for |
|---|---|---|
| `sequences.bootstrap` | `GET /api/v1/automation/ui/bootstrap` | Dashboard shell, actor, feature flags, mailbox summaries, and API version. |
| `sequences.get` | `GET /api/v1/automation/sequences/:sequenceId` | Sequence tracking read with cohort, steps, metrics, execution state, and diagnostic alerts. |
| `sequences.executionPlan` | `GET /api/v1/automation/sequences/:sequenceId/execution-plan` | Backend-issued due work and step execution IDs. |
| `automation.createExecution` | `POST /api/v1/automation/executions` | Create/resume an idempotent automation execution before browser commands begin. |
| `automation.updateExecution` | `PATCH /api/v1/automation/executions/:executionId` | Heartbeat, pause, finish, fail, cancel, or rate-limit an execution. |
| `automation.recordStepResult` | `POST /api/v1/automation/executions/:executionId/steps/:stepExecutionId/result` | Record step terminal state and optionally append one canonical sequence event. |
| `automation.ingestEvents` | `POST /api/v1/automation/events` | Batch canonical sequence events and diagnostic automation events. |
| `automation.ingestTelemetry` | `POST /api/v1/automation/telemetry` | Store redacted command, pacing, stealth, detection, and network diagnostics. |
| `analytics.outreach` | `GET /api/v1/automation/analytics/outreach` | Hosted Outreach Analytics backed by canonical `sequence_events`. |

Every write request must include:

```http
Idempotency-Key: <stable-client-key>
X-ZB-Trace-Id: <zigbrowser-trace-id>
X-ZB-Command-Id: <zigbrowser-command-id-if-known>
```

Every service-authenticated request must include:

```http
Authorization: Bearer <user-session-token-when-available>
X-ZB-Client-Id: <registered-zigbrowser-client-id>
X-ZB-Timestamp: <unix-ms>
X-ZB-Nonce: <random-128-bit-base64url>
X-ZB-Signature: v1=<base64url-hmac-sha256>
```

The signature base string is the Phase 0 contract string:

```text
v1
<method>
<path-and-query>
<x-zb-timestamp>
<x-zb-nonce>
<sha256-hex-body>
```

Successful responses return JSON objects directly. Errors use the Phase 0 envelope:

```json
{
  "error": {
    "code": "AUTOMATION_CONTRACT_INVALID",
    "message": "The request did not match zb-sequences-v1.",
    "retryable": false,
    "requestId": "req_...",
    "traceId": "zb_trace_...",
    "commandId": "zb_cmd_...",
    "details": {}
  }
}
```

This slice uses the Phase 0 error codes `AUTOMATION_CONTRACT_INVALID`, `AUTH_REQUIRED`,
`FORBIDDEN`, `SEQUENCE_NOT_FOUND`, `ENROLLMENT_NOT_FOUND`, `MESSAGE_NOT_FOUND`,
`IDEMPOTENCY_CONFLICT`, `EVENT_TYPE_UNSUPPORTED`, `EVENT_ATTRIBUTION_INVALID`, `RATE_LIMITED`,
`DB_WRITE_FAILED`, and `SEQUENCES_BACKEND_UNAVAILABLE`. The local zigBrowser adapter may expose
`SEQUENCES_AUTOMATION_CONTRACT_UNAVAILABLE` only as a client-side wrapper for missing local
configuration, 404/501 route absence, malformed success envelopes, or Phase 0
`SEQUENCES_BACKEND_UNAVAILABLE`; it must preserve the wrapped Phase 0 `error.code` in details when
one exists.

Idempotency rules are contract requirements, not best-effort dedupe:

- Same endpoint, same backend-derived org, same `Idempotency-Key`, and same normalized request hash
  returns the original success response with `duplicate: true`.
- Same endpoint, same backend-derived org, same `Idempotency-Key`, and a different request hash
  returns `409 IDEMPOTENCY_CONFLICT`.
- `automation.ingestEvents` also enforces item-level `dedupKey`; same canonical event dedup key with
  different event type, attribution, or payload is a conflict, not a silent duplicate.
- `sequence_events.dedup_key` remains the canonical analytics dedupe key, but repeat open/click hits
  must still update the canonical payload counters described below.

Allowed execution statuses are only `queued`, `running`, `succeeded`, `failed`, `cancelled`,
`rate_limited`, and `paused`. Allowed step statuses are only `queued`, `running`, `succeeded`,
`failed`, `skipped`, `rate_limited`, and `cancelled`. Detection challenges are represented as an
allowed status, usually `rate_limited` for the current `platform_rate_limited` error path, plus
`automation.detection.signal` diagnostics and `diagnostics.automationErrorCode`; this slice must not
persist a separate detection-specific status unless Phase 0 is explicitly amended first.

PRD 9.2 metric denominators override the current Phase 0 contacted-denominator table for this
9.1/9.2 slice. Before implementation, the Phase 0 `analytics.outreach` contract must either be
amended to the PRD denominator rules in this plan or the cross-contract analytics tests must fail
closed against `/api/v1/automation/analytics/outreach`.

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
- Given Phase 0 is unavailable, unbound, or returns a malformed contract response, when integration
  tests run, then they fail at the contract binding boundary rather than silently inventing a second
  API or database writer.

## What We Are Not Doing

- No PRD 9.3 New Sequence Creation planning.
- No PRD 9.4 Sequence Step Authoring planning.
- No redesign of Phase 0 API routing, auth, database ownership, or connection pooling beyond the
  explicit PRD 9.2 denominator correction required for `analytics.outreach`.
- No use of OTel spans, automation command success, or mutable ATS state as Outreach KPI sources.
- No raw PII persistence from selectors, typed text, DOM text, cookies, auth tokens, screenshots, or
  full URLs.
- No new parallel metrics source beside `sequence_events` and existing sequence metrics services.

## Data Mapping

### Tenant, Actor, and Context Boundary

zigBrowser must not send `org_id`, `actor_user_id`, or any tenant selector in request bodies. It
carries only backend-issued identifiers from `sequences.executionPlan` and the service-auth/session
headers required by `zb-sequences-v1`.

The Sequences backend derives `org_id` and actor identity from authenticated context, validates every
`sequenceId`, `executionPlanId`, `stepExecutionId`, `enrollmentId`, `messageId`, and `stepId` under
that tenant, and rejects:

- Any request body containing `org_id`, `orgId`, `actor_user_id`, or `actorUserId`.
- Cross-org sequence, enrollment, message, execution, or step IDs, including IDs that exist but are
  hidden by tenant scope.
- Canonical event attempts whose top-level attribution is missing or does not match the authenticated
  tenant.

Phase 0 writes may persist backend-derived `org_id` and `actor_user_id`, but those values are never
trusted from zigBrowser. PRD 9.1 attribution for opens, clicks, unsubscribes, replies, bounces, and
delivery receipts remains signed-token or provider-message derived; client-supplied IDs are not an
attribution source.

### Tracking State

| zigBrowser source | Sequence tracking meaning | Persistence target |
|---|---|---|
| automation run start | Sequence/step execution began | `automation.createExecution` |
| execution heartbeat/terminal status | Run lifecycle state | `automation.updateExecution` |
| step terminal result | Step lifecycle state and optional canonical event link | `automation.recordStepResult` |
| `automation.command` | Command summary and trace join key | `automation.ingestTelemetry`, not KPI |
| JSON-RPC `error.data.trace_id` / `command_id` | Debug link from UI to trace | `automation.ingestTelemetry` |
| `automation.pacing.decision` | Cap/delay/rate-limit diagnostic | `automation.ingestTelemetry` or diagnostic item in `automation.ingestEvents` |
| `automation.detection.signal` | Detection challenge/risk diagnostic | `automation.ingestTelemetry` or diagnostic item in `automation.ingestEvents` |
| `automation.stealth.assessment` | Stealth/risk surface diagnostic | `automation.ingestTelemetry` or diagnostic item in `automation.ingestEvents` |
| provider send success | Contacted/send business fact | `sequence_events.MessageSent` |
| provider delivery receipt | Delivered business fact | `sequence_events.MessageDelivered` |
| tracking pixel hit | Open business fact | `sequence_events.MessageOpened` |
| redirect hit | Click business fact and inferred open when needed | `sequence_events.LinkClicked` plus ensured `MessageOpened` |
| reply/bounce/stop webhooks | Reply, bounce, suppression, stop facts | Existing canonical event types |

### Status Mapping

| zigBrowser outcome | Phase 0 execution status | Phase 0 step status | Required diagnostics |
|---|---|---|---|
| command succeeds with required business evidence | `running` until final step, then `succeeded` | `succeeded` | Trace/command IDs and linked canonical event ID. |
| command succeeds without provider evidence | `running` or final `succeeded` if no later failure | `succeeded` | `canonicalEvent: null`; no KPI event synthesized. |
| `platform_rate_limited` or rate-limit detection challenge | `rate_limited` | `rate_limited` | `automationErrorCode=platform_rate_limited`, detection/pacing diagnostic, retryability. |
| `cancelled` | `cancelled` | `cancelled` | Trace/command IDs and cancellation reason. |
| non-retryable command failure | `failed` | `failed` | `automationErrorCode`, redacted target/selector hashes. |
| backend asks to pause execution | `paused` | Current allowed step status, usually `skipped` or unchanged | Backend pause reason, no canonical KPI event. |

No separate detection-specific status is allowed in this slice.

### Canonical Attribution Requirements

The following top-level columns are required by the Phase 0 canonical ingestion boundary even though
the current `sequence_events` migration leaves them nullable for legacy event types. Missing or
cross-tenant values return `EVENT_ATTRIBUTION_INVALID`. Payload validation is reserved for
event-specific evidence.

| Event type | Required top-level attribution | Required payload evidence |
|---|---|---|
| `MessageSent` | `sequenceId`, `enrollmentId`, `messageId` | `sent_at`, `sender_mailbox_connection_id`, `sender_user_id`, `rendered_subject`, `rendered_body_hash`, `rendered_body_snapshot`, `provider_message_id`, `provider_thread_id`. |
| `MessageDelivered` | `sequenceId`, `enrollmentId`, `messageId` | `provider_message_id` or provider delivery ID, provider name when known. |
| `MessageOpened` | `sequenceId`, `enrollmentId`, `messageId` | `open_count`, `is_probable_bot`, bot/prefetch reason when flagged, capture token/raw-hit reference hash. |
| `LinkClicked` | `sequenceId`, `enrollmentId`, `messageId` | `link_id`, `click_count`, `redirect_target_host`, `is_probable_bot` when known. |
| `ReplySynced` | `sequenceId`, `enrollmentId`, `messageId` | `provider_message_id`, `provider_thread_id`, `reply_classification`, attribution rule. |
| `BounceSynced` | `sequenceId`, `enrollmentId`, `messageId` | `provider_message_id`, `bounce_classification`, provider bounce reason/class. |
| `SuppressionApplied` | `sequenceId`, `enrollmentId`, `messageId` when message-scoped | `suppression_scope`, `suppression_reason`, signed-token attribution when capture-originated. |
| `EnrollmentStopped` | `sequenceId`, `enrollmentId` | `stop_reason`, source event ID when caused by reply/bounce/suppression/booking. |

### Repeat Open/Click Projection

PRD 9.1 repeat hits are write behavior, not read-model decoration:

- A repeated open for the same `(org_id, dedup_key)` must leave exactly one `MessageOpened` row and
  increment `event_payload.open_count` on that canonical row.
- A repeated click for the same `(org_id, dedup_key)` and `link_id` must leave exactly one
  `LinkClicked` row and increment `event_payload.click_count`.
- A click without a prior canonical open must ensure a deduped/inferred `MessageOpened` row for
  funnel consistency, with payload indicating it was inferred from click projection.
- The implementation may use a JSONB `ON CONFLICT ... DO UPDATE` counter path or a separate raw-hit
  aggregation/projection table, but tests must prove the actual write path updates the canonical
  payload before analytics reads it.
- Same idempotency key or dedup key with changed attribution, event type, `link_id`, or payload hash
  returns `409 IDEMPOTENCY_CONFLICT`; it must not reuse the old event ID silently.

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

### Analytics Filter, Grouping, and Export Mapping

The hosted dashboard product API is `GET /api/v1/automation/analytics/outreach`. Existing
`sequenceMetrics` route/service helpers may be reused internally, but they are not an alternate
zigBrowser-facing API.

| UI/API control | Public Phase 0 parameter | Backend source and join path | Cohort/window rule |
|---|---|---|---|
| Sequence | `sequenceId` or `sequenceIds[]` | `sequence_events.sequence_id`, tenant-scoped; join `sequences` for label. | Filter events before cohort build; count enrollment once per sequence. |
| Project | `jobId` or `jobIds[]` | `sequences.job_id`, joined by `(org_id, sequence_id)` to `sequence_events`. | Filter first-sent cohort to matching job/project. |
| Started by | `startedBy` or `startedByUserIds[]` | Backend-derived actor for sends: `event_payload.sender_user_id`, else `sequence_events.actor_user_id`, fallback `sequences.owner_user_id`. | Validate user IDs under tenant scope; non-manager access is narrowed by authorization. |
| Inboxes | `mailboxConnectionId` or `mailboxIds[]` | `event_payload.sender_mailbox_connection_id`, joined to `mailbox_connections`; cross-check `sequence_messages.sender_mailbox_connection_id`. | Filter by send mailbox; expose mismatch diagnostic rather than silently changing attribution. |
| Date range | `dateFrom`/`dateTo` or `start_date`/`end_date` | First `MessageSent.payload.sent_at` when present, else first send `occurred_at`. | Inclusive start, exclusive end, org timezone when configured, UTC fallback. Prior-period delta uses the same duration immediately before the current window. |
| Time grouping | `groupBy=days|weeks|months` | Bucket first-send timestamp with org timezone. | Empty buckets return zeros; prior denominator zero yields `baseline_present=false`. |
| Table grouping | `tableGroupBy=sequence|project|started_by|inbox` | Same source fields as filters. | All table, chart, KPI, and export rows use the same filtered cohort object. |
| Table breakdown | `tableBreakdown=none|month|project|started_by|inbox` | Same source fields as filters plus bucket key for `month`. | Breakdown totals reconcile to table total and KPI raw counts. |
| Export | `format=csv` on Phase 0 export/read variant | Same service result as dashboard response. | Include raw numerator and denominator fields for every rate, selected filters, bucket dates, dimension IDs, and zero-baseline delta state. |

## Testing Strategy

- **Sequences unit tests:** Vitest tests for event vocabulary, payload validation, metrics reducer,
  analytics route query mapping, redaction, idempotency conflicts, projection counters, and
  empty/error states.
- **Sequences migration tests:** SQL shape tests for event type CHECK additions, dedup indexes, RLS,
  and any Phase 0-owned automation tables exposed by contract.
- **zigBrowser unit tests:** Zig tests for business-context correlation on automation telemetry
  adapters, redaction, and no raw selector/text leakage.
- **Cross-repo contract tests:** Node/Python integration tests with a fake Phase 0 server and fake
  zigBrowser command stream, proving required reads/writes, canonical event projection,
  tenant-derived scope, and PRD 9.2 denominators through `/api/v1/automation/analytics/outreach`.
- **E2E smoke:** Launch zigBrowser with automation enabled, execute a fake sequence step, append
  canonical events through the Phase 0 seam, and read the dashboard/analytics result.

## Behavior 1: Contract Binding Fails Closed

### Test Specification

**Given** the 9.1/9.2 integration adapter is configured without the Phase 0 contract  
**When** a sequence automation run starts  
**Then** no automation data is written directly to PostgreSQL, the run fails with
local `SEQUENCES_AUTOMATION_CONTRACT_UNAVAILABLE` wrapping the Phase 0 error when present, and the
error is visible in the dashboard state.

Edge cases:
- Contract endpoint returns 404/501.
- Contract response omits required IDs.
- Contract returns a cross-org ID.
- Phase 0 returns `SEQUENCES_BACKEND_UNAVAILABLE`, `AUTH_REQUIRED`, or
  `AUTOMATION_CONTRACT_INVALID`.
- A request body containing `org_id`, `orgId`, `actor_user_id`, or `actorUserId` is rejected before
  any execution is created.

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
- Local adapter errors preserve Phase 0 `error.code`, `requestId`, `traceId`, and retryability when a
  backend envelope exists.

## Behavior 2: Automation Run and Step State Are Persisted With Business Context

### Test Specification

**Given** a sequence step execution request includes backend-issued `sequenceId`,
`executionPlanId`, `stepExecutionId`, `enrollmentId`, `messageId`, `stepId`, and service-auth headers
**When** zigBrowser starts the run and executes `page.navigate` then `dom.click`  
**Then** Phase 0 receives `automation.createExecution`, one redacted `automation.ingestTelemetry`
item per command, `automation.recordStepResult`, any needed `automation.updateExecution`, and
trace/command IDs that match zigBrowser telemetry.

Edge cases:
- Missing sequence context fails before command execution.
- Client-supplied `org_id`/`actor_user_id` or cross-org IDs return Phase 0 auth/contract errors.
- A command returns `platform_rate_limited`.
- A command returns `cancelled`.
- A later retry keeps the same run ID but appends a new attempt.
- Same `Idempotency-Key` for `automation.createExecution` with a changed request body returns
  `409 IDEMPOTENCY_CONFLICT`.

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
- No zigBrowser request body contains `org_id`, `orgId`, `actor_user_id`, or `actorUserId`.

## Behavior 3: Canonical Event Vocabulary Accepts 9.1 Event Types

### Test Specification

**Given** PRD 9.1's pinned event types  
**When** `appendIdempotentEvent` receives `MessageOpened`, `LinkClicked`, or `MessageDelivered`  
**Then** validation accepts the type, the migration CHECK permits it, required top-level attribution
and payload evidence are enforced, and duplicate `dedup_key` writes collapse to one row only when the
payload hash matches.

Edge cases:
- `MessageOpened` without `message_id` or `enrollment_id`.
- `LinkClicked` without `link_id`.
- `MessageDelivered` without `provider_message_id`.
- Same dedup/idempotency key with changed payload or attribution.
- Unsupported lowercase names still fail.

### TDD Cycle

**Red:** Extend the current event-service and migration tests to fail on the remaining gaps:
`130_sequence_tracking.sql` CHECK coverage in the live migration chain, engagement-event payload
requirements, top-level attribution errors, and changed-payload duplicate conflicts.

Files:
- `/home/maceo/ntm_Dev/sequences/tests/unit/backend/services/sequencesEventService.test.js`
- `/home/maceo/ntm_Dev/sequences/tests/unit/backend/migrations/110_sequences_engine.test.js`
- `/home/maceo/ntm_Dev/sequences/tests/unit/backend/migrations/130_sequence_tracking.test.js`

**Green:** Keep the existing JS allowlist for the three event types, add their payload required-field
validation, add Phase 0 `EVENT_ATTRIBUTION_INVALID` checks for top-level attribution, and add the
`sequence_events_event_type_chk` migration path.

**Refactor:** Put payload requirements near the existing `MessageSent` and `CandidateConverted`
requirements to keep one canonical validator.

Success criteria:
- `npx vitest run --no-cache tests/unit/backend/services/sequencesEventService.test.js`
- Migration shape test proves the CHECK and DB writer agree.
- Duplicate-key same-payload tests return `duplicate`; duplicate-key changed-payload tests return
  `409 IDEMPOTENCY_CONFLICT`.

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
- Detection challenge maps to allowed run/step status `rate_limited` with
  `automationErrorCode=platform_rate_limited` and diagnostic signal payload, not `MessageSent`.
- Duplicate send confirmation returns the existing event ID.
- Same `Idempotency-Key` for `automation.recordStepResult` with changed event evidence returns
  `409 IDEMPOTENCY_CONFLICT`.

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
- Changed-payload replay proves request-hash idempotency conflict behavior for step result and
  canonical event ingestion.

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
- Same dedup key with a changed `link_id`, attribution, or payload hash conflicts.

### TDD Cycle

**Red:** Add projection/write tests and read-model tests against canonical event fixtures containing
repeat opens, click-implies-open, bot-flagged opens, and changed-payload duplicate conflicts.

Files:
- `/home/maceo/ntm_Dev/sequences/tests/unit/backend/services/sequenceTrackingProjection.test.js`
- `/home/maceo/ntm_Dev/sequences/tests/unit/backend/services/sequenceAutomationTrackingReadModel.test.js`
- `/home/maceo/ntm_Dev/zigBrowser/tests/integration/sequences_dashboard_tracking_test.py`

**Green:** Implement the duplicate-hit projection write path that updates
`event_payload.open_count`/`click_count` on the canonical row, then consume Phase 0's read contract
to build tracking state without querying raw capture tables from zigBrowser.

**Refactor:** Share event-normalization helpers with the analytics reducer where possible, but keep
dashboard status formatting out of the metric service.

Success criteria:
- Tracking dashboard state reconciles to exact canonical event IDs.
- Raw capture hits are never required by the zigBrowser dashboard.
- A database assertion proves repeat hits changed the persisted canonical JSONB payload counters.

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
- `/api/v1/automation/analytics/outreach` returns PRD 9.2 denominators even if the older Phase 0
  denominator table still says contacted enrollments.

### TDD Cycle

**Red:** Extend `computeSequenceFunnel` and `analytics.outreach` contract tests with
open/click/delivery fixtures and expected PRD 9.2 fields.

Files:
- `/home/maceo/ntm_Dev/sequences/tests/unit/backend/services/sequencesMetricsService.test.js`
- `/home/maceo/ntm_Dev/sequences/tests/unit/backend/routes/sequenceMetrics.test.js`
- `/home/maceo/ntm_Dev/sequences/tests/integration/automationAnalyticsOutreachContract.test.js`

**Green:** Extend the reducer output with `profiles_contacted`, `opens`, `clicks`, `open_rate`,
`click_rate`, `reply_rate`, `interest_rate`, `bounce_rate`, and raw numerator/denominator fields
while preserving existing funnel fields.

**Refactor:** Split denominator/numerator helpers by metric to keep reply/interest/bounce formulas
auditable.

Success criteria:
- Existing tests for reply, positive reply, conversion, and TTFR still pass.
- New tests prove `automation.command` fixture events are rejected or ignored as noncanonical.
- The same canonical fixture returns identical PRD denominator values through
  `/api/v1/automation/analytics/outreach` and the underlying metrics service.

## Behavior 7: Analytics Filters, Grouping, and Export Use the Phase 0 Product API

### Test Specification

**Given** a manager requests Outreach Analytics with Sequence, Project, Started by, Inboxes, Date
range, and Grouped by filters  
**When** `/api/v1/automation/analytics/outreach` serves KPI/chart/table/export reads
**Then** the same filtered event-derived cohort backs every surface and export includes raw
numerator/denominator fields.

Edge cases:
- Empty cohort returns zero tiles, zero-filled buckets, and empty table rows without 500.
- Non-manager analytics access remains forbidden.
- Prior-period denominator zero returns a no-baseline delta state.

### TDD Cycle

**Red:** Add route tests for filter forwarding and export shape around the Phase 0 automation
analytics route, with fixtures proving the backend may reuse `createSequenceMetricsRouter` and
`outreachAnalyticsService` internally.

Files:
- `/home/maceo/ntm_Dev/sequences/tests/unit/backend/routes/sequenceMetrics.test.js`
- `/home/maceo/ntm_Dev/sequences/tests/unit/backend/services/sequenceOutreachAnalyticsService.test.js`
- `/home/maceo/ntm_Dev/sequences/tests/unit/backend/routes/automationAnalytics.test.js`

**Green:** Implement the Phase 0 `/api/v1/automation/analytics/outreach` adapter as the only
zigBrowser-facing product API; existing `/api/v1/sequences/...` analytics routes remain backend
internals and must return the same service result when reused.

**Refactor:** Keep authorization in the route and query/cohort math in the service.

Success criteria:
- `authorizeOutreachAnalyticsAccess` remains enforced and non-manager scope is narrowed or rejected.
- All dashboard surfaces can reconcile row counts to the same event fixture set.
- Export rows include selected filters, dimensions, bucket dates, raw numerator/denominator fields,
  and zero-baseline delta state.

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
paused states without direct DB access; detection challenges are rendered as rate-limited or failed
states with diagnostic details, not as a separate persisted status.

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
- Client-supplied `org_id`/`actor_user_id` write attempt.
- Same idempotency key with changed create-execution, step-result, or canonical-event payload.
- Automation command failure before send.

### TDD Cycle

**Red:** Add a cross-repo E2E fixture that fails because Phase 0 contract binding and
analytics/event contracts are not aligned.

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
- Repeat open/click replays update canonical counters, while changed-payload replays conflict.

## Implementation Order

1. Bind to the concrete Phase 0 `zb-sequences-v1` contract, including service auth, tenant-derived
   org/actor scope, fail-closed errors, allowed statuses, and PRD 9.2 denominator override tests.
2. Add canonical event migration/payload/attribution validation for `MessageOpened`,
   `LinkClicked`, and `MessageDelivered`.
3. Add idempotency conflict tests for execution creation, step results, canonical event ingestion,
   and duplicate open/click projection.
4. Extend 9.2 metrics reducer and `/api/v1/automation/analytics/outreach` with delivered/open/click
   denominators, raw numerator/denominator fields, filters, grouping, export, and zero guards.
5. Add automation run/step tracking writes around zigBrowser command execution.
6. Add canonical business-event projection from automation outcomes and repeat open/click counter
   writes.
7. Add dashboard read models for tracking state and diagnostic alerts.
8. Add cross-repo E2E reconciliation and tenant isolation tests.

## Verification Commands

From `/home/maceo/ntm_Dev/sequences`:

```bash
npx vitest run --no-cache tests/unit/backend/services/sequencesEventService.test.js
npx vitest run --no-cache tests/unit/backend/migrations/130_sequence_tracking.test.js
npx vitest run --no-cache tests/unit/backend/services/sequenceTrackingProjection.test.js
npx vitest run --no-cache tests/unit/backend/services/sequencesMetricsService.test.js
npx vitest run --no-cache tests/unit/backend/routes/sequenceMetrics.test.js
npx vitest run --no-cache tests/unit/backend/routes/automationAnalytics.test.js
npx vitest run --no-cache tests/integration/automationAnalyticsOutreachContract.test.js
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
- Phase 0 contract plan:
  `/home/maceo/ntm_Dev/zigBrowser/thoughts/searchable/shared/plans/2026-07-09-sequences-integration-api-db-layer-plan.md`
- Existing sequences ledger:
  `/home/maceo/ntm_Dev/sequences/database/migrations/110_sequences_engine.sql`
- Engagement tracking migration:
  `/home/maceo/ntm_Dev/sequences/database/migrations/130_sequence_tracking.sql`
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
