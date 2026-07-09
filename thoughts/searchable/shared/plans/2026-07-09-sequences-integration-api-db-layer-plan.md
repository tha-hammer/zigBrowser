# Sequences Integration API and DB Layer TDD Plan

**Date:** 2026-07-09
**Scope:** Exposed API and database integration contract between zigBrowser automation/dashboard code and the sequences Express/PostgreSQL product
**Owner slice:** shared seam consumed by the automation UI, sequence tracking, analytics, new sequence creation, and step authoring agents
**Primary repos:** `/home/maceo/ntm_Dev/zigBrowser` and `/home/maceo/ntm_Dev/sequences`

## Overview

zigBrowser has a built local automation engine: JSON-RPC 2.0 over a Unix domain socket, `dom.*` and `page.*` command verbs, injected `automation.js`, SDKs, CLI entry points, anti-detection/pacing, and privacy-aware wide-event telemetry. It does not yet have a user-facing automation UI or a product API that can read/write sequence data.

The sequences app already owns the sequence product model, tenant-scoped PostgreSQL access, route-level auth, canonical sequence events, ATS/CRM links, and analytics reads. This plan defines the connective contract that lets zigBrowser host the automation dashboard, read executable sequence data, push automation execution and tracking records, and feed analytics through the existing canonical ledger without putting database credentials or tenant decisions inside zigBrowser.

The core decision is: zigBrowser must talk to the sequences Express backend, not directly to PostgreSQL. The backend remains the source of truth for auth, tenant scoping, validation, idempotency, and analytics projection.

## Source Findings

### zigBrowser automation state

- `src/automation.zig` exports the current automation modules and Phase 1 verbs: `dom.query`, `dom.click`, `dom.fill`, `dom.type`, `dom.getText`, `dom.getAttribute`, `dom.waitFor`, `page.navigate`, `page.reload`, `page.url`, `page.title`, `page.evaluate`, and `page.screenshot`.
- `src/automation_rpc.zig` implements line-delimited JSON-RPC 2.0 framing, first-frame auth, request ids, and stable automation error mapping. Automation error responses carry `trace_id` and `command_id` in `error.data`.
- `src/automation_transport.zig` creates the per-session Unix-domain-socket transport for automation commands.
- `src/automation_websocket.zig` pushes JSON-RPC notifications over WebSocket on the local transport.
- `src/automation_otlp.zig` exports redacted telemetry only when configured. Export failure is isolated from command success.
- `src/automation/telemetry.zig`, `src/automation/router.zig`, `src/automation/pacing.zig`, and `src/automation/stealth.zig` already emit or shape privacy-aware diagnostic events with trace and command correlation.
- The current automation transport is a local browser-control seam. It is not a product data API and should not be reused as a database boundary.

### sequences database state

- `database/migrations/090_sequences_foundation.sql` creates `sequences`, `sequence_enrollments`, `sequence_cohort_sources`, and `sequence_messages`.
- `090_sequences_foundation.sql` forces tenant RLS through `app.current_org` and owner checks through `app.current_user` on the foundation tables.
- `database/migrations/110_sequences_engine.sql` creates `mailbox_connections`, extends `sequence_messages`, creates the canonical `sequence_events` ledger, inbound receipt tables, outreach claims, send caps, suppression entries, metric rollups, metric cursors, and benchmark presets.
- `sequence_events` already has `dedup_key` plus a unique `(org_id, dedup_key)` index for idempotent canonical writes.
- `sequence_events.event_type` in `110_sequences_engine.sql` originally supports `ContactReadinessAssessed`, `SequenceCreated`, `AudienceSelected`, `DraftGenerated`, `SequenceApproved`, `MessageSent`, `ReplySynced`, `BounceSynced`, `SuppressionApplied`, `EnrollmentStopped`, `AtsWritebackSucceeded`, `AtsWritebackFailed`, and `CandidateConverted`.
- The current sequences checkout also has `database/migrations/130_sequence_tracking.sql` and `backend/services/sequenceEvents/eventTypes.js` extending the canonical allowlist with `MessageOpened`, `LinkClicked`, and `MessageDelivered`. The integration implementation must keep the database `CHECK`, JS allowlist, and tests synchronized, and must add or assert this migration on branches where it is absent.
- `backend/services/sequenceMetrics/metricsService.js` already counts `MessageOpened` and `LinkClicked`, but its delivered funnel semantics still derive delivery from `MessageSent` minus hard bounces in the current code. PRD 9.2 delivery metrics must explicitly account for canonical `MessageDelivered` before the automation analytics wrapper claims delivered-event support.
- `database/migrations/120_sequences_ats_crm.sql` creates ATS connection/reference/diagnostic/sync tables. ATS sync writes already have an idempotency key model.

### sequences route state

- `backend/routes/sequences.js` exposes draft creation, cohort operations, finalization, draft generation, candidate-to-draft flow, approval, and enrollment pause under `/api/v1/sequences`.
- `backend/routes/sequenceMetrics.js` exposes analytics, funnel, drilldown, and hygiene reads. These routes already use authorization and return standard `{ error: { code, message } }` responses.
- `backend/routes/sequenceContinuity.js` exposes action context, dashboard, and per-sequence metrics reads.
- `backend/routes/sequencesWebhook.js` handles signed mailbox webhooks and writes inbound receipts under tenant context.
- `backend/routes/sequencesAts.js` handles ATS connection and webhook concerns.

## Topology Decision

### Recommended data flow

1. zigBrowser hosts the automation dashboard UI.
2. The hosted UI calls a zigBrowser-local UI/API facade owned by the Phase 0 exposed-API layer.
3. The zigBrowser facade uses a sequences integration client to call the sequences Express backend over HTTPS or the configured internal service URL.
4. The sequences backend validates auth, derives org/user context, runs with tenant settings, reads/writes PostgreSQL, and returns redacted product responses.
5. The existing zigBrowser JSON-RPC Unix socket remains the browser automation command channel. It is not used for sequence database access.

### Why not direct PostgreSQL from zigBrowser

- The sequences schema relies on RLS session variables such as `app.current_org` and `app.current_user`; a desktop/browser host would have to duplicate sensitive tenant context handling.
- Direct DB access would require distributing database credentials to zigBrowser.
- Existing backend routes already centralize auth, rate limits, validation, event append semantics, and analytics contracts.
- The analytics PRDs require canonical `sequence_events` writes, not ad hoc writes into rollup tables.
- Backend mediation allows service-to-service auth, request signing, and idempotency to be tested once and shared by all UI and automation slices.

Direct DB access is allowed only for backend tests and migrations inside the sequences repo. It is not a production topology for zigBrowser.

## Contract Summary

The canonical product API lives in the sequences backend under `/api/v1/automation`. The Phase 0 zigBrowser host API may expose local routes, IPC methods, or another local transport for the hosted dashboard, but it must preserve the method names and JSON shapes below when proxying to the backend.

Contract name: `zb-sequences-v1`

Backend base path: `/api/v1/automation`

Local zigBrowser facade methods:

| Method | Backend endpoint | Purpose |
|---|---|---|
| `sequences.bootstrap` | `GET /api/v1/automation/ui/bootstrap` | Load dashboard shell data, actor, feature flags, mailbox summaries, and API version. |
| `sequences.list` | `GET /api/v1/automation/sequences` | List tenant-scoped sequences for dashboard and creation flows. |
| `sequences.get` | `GET /api/v1/automation/sequences/:sequenceId` | Read one sequence with optional cohort, steps, metrics, and execution state. |
| `sequences.createDraft` | `POST /api/v1/automation/sequences` | Create a draft sequence through backend sequence services. |
| `sequences.getSteps` | `GET /api/v1/automation/sequences/:sequenceId/steps` | Read the durable versioned step-authoring contract. |
| `sequences.saveSteps` | `PUT /api/v1/automation/sequences/:sequenceId/steps` | Save the step-authoring contract for draft sequences. |
| `sequences.generateStepDraft` | `POST /api/v1/automation/sequences/:sequenceId/steps/generate` | Ask backend services to generate grounded step content. |
| `sequences.previewStep` | `POST /api/v1/automation/sequences/:sequenceId/steps/preview` | Render and validate a step without sending. |
| `sequences.executionPlan` | `GET /api/v1/automation/sequences/:sequenceId/execution-plan` | Read the due executable work for automation. |
| `automation.createExecution` | `POST /api/v1/automation/executions` | Create or resume an idempotent automation execution run. |
| `automation.updateExecution` | `PATCH /api/v1/automation/executions/:executionId` | Heartbeat, pause, finish, fail, or rate-limit an execution. |
| `automation.recordStepResult` | `POST /api/v1/automation/executions/:executionId/steps/:stepExecutionId/result` | Record one automation step result. |
| `automation.ingestEvents` | `POST /api/v1/automation/events` | Batch ingest canonical sequence events and diagnostic automation events. |
| `automation.ingestTelemetry` | `POST /api/v1/automation/telemetry` | Store or forward redacted diagnostics that must not feed analytics counters. |
| `analytics.outreach` | `GET /api/v1/automation/analytics/outreach` | Read outreach analytics for the hosted dashboard, backed by existing sequence metrics services. |

## Backend API Contract

### Common headers

Every write request:

```http
Idempotency-Key: <stable-client-key>
X-ZB-Trace-Id: <zigbrowser-trace-id>
X-ZB-Command-Id: <zigbrowser-command-id-if-known>
```

Every service-authenticated request from zigBrowser:

```http
Authorization: Bearer <user-session-token-when-available>
X-ZB-Client-Id: <registered-zigbrowser-client-id>
X-ZB-Timestamp: <unix-ms>
X-ZB-Nonce: <random-128-bit-base64url>
X-ZB-Signature: v1=<base64url-hmac-sha256>
```

Signature base string:

```text
v1
<method>
<path-and-query>
<x-zb-timestamp>
<x-zb-nonce>
<sha256-hex-body>
```

The backend rejects stale timestamps, repeated nonces, unknown client ids, invalid signatures, missing session delegation for user-owned operations, and any request body that attempts to supply `org_id`.

### Common response envelope

Successful responses return JSON objects directly. Errors use:

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

Common error codes:

| HTTP | Code | Retryable | Meaning |
|---|---|---|---|
| 400 | `AUTOMATION_CONTRACT_INVALID` | false | Schema, enum, or cross-field validation failed. |
| 401 | `AUTH_REQUIRED` | false | No valid user/session or service signature. |
| 403 | `FORBIDDEN` | false | Authenticated principal cannot access the sequence or org. |
| 404 | `SEQUENCE_NOT_FOUND` | false | Sequence is missing or hidden by tenant scope. |
| 404 | `ENROLLMENT_NOT_FOUND` | false | Enrollment is missing or hidden by tenant scope. |
| 404 | `MESSAGE_NOT_FOUND` | false | Message/step is missing or hidden by tenant scope. |
| 409 | `IDEMPOTENCY_CONFLICT` | false | Same idempotency key was used with a different request hash. |
| 409 | `STEP_VERSION_CONFLICT` | false | `expectedVersion` does not match the durable step contract version. |
| 409 | `SEQUENCE_NOT_EXECUTABLE` | false | Sequence is not active, not approved, archived, paused, suppressed, or otherwise ineligible for execution planning. |
| 422 | `EVENT_TYPE_UNSUPPORTED` | false | Event type is not allowed for canonical ingestion. |
| 422 | `EVENT_ATTRIBUTION_INVALID` | false | Canonical event lacks required sequence/enrollment/message attribution. |
| 429 | `RATE_LIMITED` | true | Backend rate limit or tenant send cap blocked the request. |
| 500 | `DB_WRITE_FAILED` | true | Backend failed while writing after validation. |
| 503 | `SEQUENCES_BACKEND_UNAVAILABLE` | true | Dependency outage or maintenance window. |

### Mount order and auth matrix

`/api/v1/automation` must be mounted in `backend/server.js` after the existing `/api/v1/` middleware chain:

```text
authenticate -> auditCrossTenant -> tenantContextMiddleware -> sequencesAutomationRoutes
```

No automation endpoint may bypass `tenantContextMiddleware`; all PostgreSQL access must run with backend-derived `app.current_org` and `app.current_user`. `zigBrowserAutomationAuth` is a route-level narrowing middleware inside `sequencesAutomationRoutes`: it validates the `X-ZB-*` HMAC when required, binds the registered client id to the delegated user session, and rejects any body/query/path attempt to supply `org_id`.

| Endpoint group | User session | Service HMAC | Notes |
|---|---|---|---|
| `GET /ui/bootstrap`, `GET /sequences`, `GET /sequences/:id`, `GET /sequences/:id/steps`, `GET /analytics/outreach` | Required | Optional | User-session-only reads are allowed for first-party dashboard calls; if `X-ZB-Client-Id` is present, the HMAC must validate. |
| `POST /sequences/:id/steps/preview` | Required | Optional | Read-only render/validation operation; must not persist rendered body text. If a future implementation persists preview audit rows, it becomes a write and must require HMAC plus idempotency. |
| `POST /sequences`, `PUT /sequences/:id/steps`, `POST /sequences/:id/steps/generate` | Required | Required | State-changing authoring operations from zigBrowser; require delegated user plus registered client signature. |
| `GET /sequences/:id/execution-plan` | Required | Required | Exposes executable work and rendered send material; reject user-session-only requests. |
| `POST /executions`, `PATCH /executions/:id`, `POST /executions/:id/steps/:stepExecutionId/result` | Required | Required | Automation execution writes; require delegated user, registered client signature, and idempotency. |
| `POST /events`, `POST /telemetry` | Required | Required | Ingestion writes; canonical events still derive tenant scope from auth and object ownership, never from client-supplied org fields. |

### `GET /api/v1/automation/ui/bootstrap`

Purpose: provide the hosted dashboard with stable shell data without exposing database implementation details.

Query:

```text
include=mailboxes,templates,featureFlags,analyticsDefaults
```

Response:

```json
{
  "apiVersion": "zb-sequences-v1",
  "actor": {
    "userId": "usr_123",
    "orgId": "org_123",
    "roles": ["sequence_admin"]
  },
  "featureFlags": {
    "sequenceCreation": true,
    "stepAuthoring": true,
    "automationExecution": true,
    "analytics": true
  },
  "mailboxes": [
    {
      "mailboxConnectionId": "mbx_123",
      "displayName": "Recruiting",
      "provider": "gmail",
      "status": "connected",
      "dailyCapRemaining": 120
    }
  ],
  "analyticsDefaults": {
    "dateRangeDays": 30,
    "groupBy": "week"
  }
}
```

### `GET /api/v1/automation/sequences`

Purpose: tenant-scoped dashboard listing.

Query:

```text
status=draft,pending_approval,archived
ownerUserId=usr_123
jobId=job_123
workspaceSearchId=ws_123
include=metrics,executionSummary
cursor=<opaque>
limit=50
```

Response:

```json
{
  "items": [
    {
      "sequenceId": "seq_123",
      "name": "Senior Backend Search",
      "status": "draft",
      "ownerUserId": "usr_123",
      "jobId": "job_123",
      "workspaceSearchId": "ws_123",
      "createdAt": "2026-07-09T16:00:00.000Z",
      "updatedAt": "2026-07-09T16:05:00.000Z",
      "metrics": {
        "profilesContacted": 0,
        "openRate": null,
        "replyRate": null,
        "bounceRate": null
      },
      "executionSummary": {
        "dueSteps": 0,
        "runningExecutions": 0,
        "lastExecutionStatus": null
      }
    }
  ],
  "nextCursor": null
}
```

### `GET /api/v1/automation/sequences/:sequenceId`

Purpose: read one sequence for the hosted dashboard.

Query:

```text
include=cohort,steps,metrics,executionSummary,mailboxes
```

Response:

```json
{
  "sequence": {
    "sequenceId": "seq_123",
    "name": "Senior Backend Search",
    "status": "draft",
    "ownerUserId": "usr_123",
    "jobId": "job_123",
    "workspaceSearchId": "ws_123"
  },
  "cohort": {
    "included": 25,
    "skipped": 3,
    "preview": [
      {
        "enrollmentId": "enr_123",
        "candidateSource": "workspace",
        "workspaceCandidateId": "cand_123",
        "contactStatus": "ready"
      }
    ]
  },
  "steps": [],
  "metrics": null,
  "executionSummary": null
}
```

### `POST /api/v1/automation/sequences`

Purpose: create a draft sequence from zigBrowser-hosted UI without allowing the client to supply org scope.

Request:

```json
{
  "name": "Senior Backend Search",
  "ownerUserId": "usr_123",
  "jobId": "job_123",
  "workspaceSearchId": "ws_123",
  "source": {
    "kind": "workspace_search",
    "ref": "ws_123"
  },
  "initialAudience": {
    "candidateIds": ["cand_123"],
    "workspaceCandidateIds": ["wc_123"]
  }
}
```

Response:

```json
{
  "sequenceId": "seq_123",
  "status": "draft",
  "createdAt": "2026-07-09T16:00:00.000Z"
}
```

### `GET /api/v1/automation/sequences/:sequenceId/steps`

Purpose: read the durable step-authoring contract for PRD 9.4.

Response:

```json
{
  "sequenceId": "seq_123",
  "version": 3,
  "steps": [
    {
      "stepId": "step_1",
      "kind": "email",
      "index": 0,
      "replyMode": "new_thread",
      "waitBefore": null,
      "senderMailboxId": "mbx_123",
      "subject": "Quick question",
      "body": "Hi {{first_name}}, ...",
      "tokens": ["first_name"],
      "signatureId": "sig_123",
      "includeUnsubscribe": true,
      "groundingStatus": "grounded",
      "evidenceMap": {},
      "reviewQueue": [],
      "status": "draft",
      "messageId": "msg_123"
    },
    {
      "stepId": "step_2",
      "kind": "wait",
      "index": 1,
      "duration": 3,
      "unit": "days"
    }
  ]
}
```

Storage note: the current foundation migrations expose `sequence_messages` with `is_current`/`supersedes_id` for draft email bodies, not a durable versioned step model. The backend integration layer must adapt this API-level step contract onto storage while keeping consumers dependent on this API shape, not table names.

#### Step version source and compare-and-swap

`expectedVersion` is backed by a durable backend-owned step contract row, not by a client counter, `sequence_messages.updated_at`, or the number of current messages. The integration migration must add `sequence_step_contracts` unless a dedicated Phase 9.4 step table with the same guarantees exists first.

Required version behavior:

- `sequence_step_contracts.version` is the only value returned as `GET /steps` `version`.
- For an existing sequence with no row, the backend bootstraps one under tenant context from current `sequence_messages` before returning or saving steps. If no steps exist, the bootstrapped version is `0`.
- `PUT /steps` runs in one transaction: lock the `sequence_step_contracts` row with `FOR UPDATE`, compare `expectedVersion`, validate all mailbox/token/message references under the same `org_id`, update/supersede `sequence_messages` as needed, replace the serialized step contract, increment `version` by exactly one, and commit.
- A stale `expectedVersion` returns `409 STEP_VERSION_CONFLICT` with the current version and no partial message writes.
- Idempotent replay of a previously successful `PUT /steps` returns the stored response even if the sequence version has since advanced; a new idempotency key with an old `expectedVersion` must fail with `STEP_VERSION_CONFLICT`.

### `PUT /api/v1/automation/sequences/:sequenceId/steps`

Purpose: save step authoring changes for draft or pre-approval sequences.

Request:

```json
{
  "expectedVersion": 3,
  "steps": [
    {
      "stepId": "step_1",
      "kind": "email",
      "index": 0,
      "replyMode": "new_thread",
      "waitBefore": null,
      "senderMailboxId": "mbx_123",
      "subject": "Quick question",
      "body": "Hi {{first_name}}, ...",
      "tokens": ["first_name"],
      "signatureId": "sig_123",
      "includeUnsubscribe": true
    }
  ]
}
```

Response:

```json
{
  "sequenceId": "seq_123",
  "version": 4,
  "validation": {
    "status": "valid",
    "warnings": []
  },
  "steps": []
}
```

The backend rejects raw org scope, invalid token references, missing unsubscribe requirements, mailbox ownership violations, stale versions, and attempts to edit approved/archived immutable content.

### `POST /api/v1/automation/sequences/:sequenceId/steps/generate`

Purpose: generate grounded step content by reusing backend grounding services instead of letting zigBrowser synthesize product copy.

Request:

```json
{
  "enrollmentId": "enr_123",
  "stepIndex": 0,
  "candidateContextRef": "workspace_candidate:cand_123",
  "strategy": "concise_recruiting_intro",
  "constraints": {
    "maxWords": 120,
    "includeUnsubscribe": true
  }
}
```

Response:

```json
{
  "messageId": "msg_123",
  "stepDraft": {
    "subject": "Quick question",
    "body": "Hi {{first_name}}, ...",
    "groundingStatus": "grounded",
    "evidenceMap": {},
    "reviewQueue": []
  },
  "canonicalEvent": {
    "eventType": "DraftGenerated",
    "dedupKey": "sequences:DraftGenerated:seq_123:enr_123:msg_123"
  }
}
```

### `POST /api/v1/automation/sequences/:sequenceId/steps/preview`

Purpose: render a step for one enrollment without sending or appending a canonical send event.

Request:

```json
{
  "enrollmentId": "enr_123",
  "stepId": "step_1",
  "overrides": {
    "subject": "Quick question",
    "body": "Hi {{first_name}}, ..."
  }
}
```

Response:

```json
{
  "rendered": {
    "subject": "Quick question",
    "bodyPreview": "Hi Ada, ...",
    "renderedHash": "sha256:..."
  },
  "validation": {
    "status": "valid",
    "warnings": []
  }
}
```

The backend may return previews, hashes, and validation diagnostics, but logs and telemetry must not record raw rendered body text.

### `GET /api/v1/automation/sequences/:sequenceId/execution-plan`

Purpose: read executable work for zigBrowser automation after sequence approval and scheduler selection.

Query:

```text
limit=25
mailboxConnectionId=mbx_123
dueBefore=2026-07-09T17:00:00.000Z
include=renderedMessage,pacingPolicy,candidateRefs
```

Response:

```json
{
  "sequence": {
    "sequenceId": "seq_123",
    "status": "active",
    "name": "Senior Backend Search",
    "approvedAt": "2026-07-09T15:55:00.000Z"
  },
  "executionPlanId": "plan_20260709_001",
  "generatedAt": "2026-07-09T16:00:00.000Z",
  "pacingPolicy": {
    "tenantDailyCapRemaining": 120,
    "mailboxDailyCapRemaining": 50,
    "minDelayMs": 1500,
    "maxDelayMs": 9000
  },
  "steps": [
    {
      "stepExecutionId": "sexec_123",
      "sequenceId": "seq_123",
      "enrollmentId": "enr_123",
      "messageId": "msg_123",
      "stepId": "step_1",
      "stepIndex": 0,
      "kind": "email",
      "action": "send_email",
      "candidate": {
        "candidateSource": "workspace",
        "candidateId": null,
        "workspaceCandidateId": "wc_123"
      },
      "mailbox": {
        "mailboxConnectionId": "mbx_123",
        "provider": "gmail",
        "status": "connected"
      },
      "renderedMessage": {
        "subject": "Quick question",
        "body": "Hi Ada, ...",
        "renderedHash": "sha256:..."
      },
      "idempotencySeed": "seq_123:enr_123:msg_123:step_1:attempt_1",
      "requiredCanonicalEvent": "MessageSent"
    }
  ]
}
```

The backend owns whether a step is due. zigBrowser must not infer send eligibility from raw database rows. The execution-plan service must match the current send-side gate in `backend/services/sequences/sendStore.js`: sequence `status = 'active'`, `approved_at IS NOT NULL`, enrollment `status = 'active'`, no stop reason, not suppressed, within caps, and due by `dueBefore`. Draft and `pending_approval` sequences must be rejected with `409 SEQUENCE_NOT_EXECUTABLE`, not returned with an empty executable plan.

### `POST /api/v1/automation/executions`

Purpose: create or resume an idempotent automation run before browser commands begin.

Request:

```json
{
  "externalRunId": "zb_run_123",
  "sequenceId": "seq_123",
  "executionPlanId": "plan_20260709_001",
  "stepExecutionIds": ["sexec_123"],
  "zigBrowser": {
    "sessionIdHash": "sha256:...",
    "version": "0.1.0",
    "platform": "linux",
    "automationApi": "jsonrpc-uds"
  },
  "trace": {
    "traceId": "zb_trace_123",
    "commandId": null
  }
}
```

Response:

```json
{
  "executionId": "aexec_123",
  "status": "running",
  "duplicate": false,
  "createdAt": "2026-07-09T16:00:00.000Z"
}
```

### `PATCH /api/v1/automation/executions/:executionId`

Purpose: update execution state without appending canonical analytics events.

Request:

```json
{
  "status": "rate_limited",
  "lastStepExecutionId": "sexec_123",
  "lastErrorCode": "platform_rate_limited",
  "trace": {
    "traceId": "zb_trace_123",
    "commandId": "zb_cmd_456"
  },
  "occurredAt": "2026-07-09T16:01:00.000Z"
}
```

Allowed statuses: `queued`, `running`, `succeeded`, `failed`, `cancelled`, `rate_limited`, `paused`.

### `POST /api/v1/automation/executions/:executionId/steps/:stepExecutionId/result`

Purpose: record the result of one automation step and, when valid, append the required canonical sequence event through the backend append service.

Request:

```json
{
  "status": "succeeded",
  "sequenceId": "seq_123",
  "enrollmentId": "enr_123",
  "messageId": "msg_123",
  "stepId": "step_1",
  "eventCandidate": {
    "eventType": "MessageSent",
    "occurredAt": "2026-07-09T16:01:00.000Z",
    "dedupKey": "zigbrowser:MessageSent:seq_123:enr_123:msg_123:step_1",
    "payload": {
      "mailboxConnectionId": "mbx_123",
      "providerMessageId": "provider_msg_123",
      "providerThreadId": "provider_thread_123",
      "renderedHash": "sha256:...",
      "automation": {
        "executionId": "aexec_123",
        "externalRunId": "zb_run_123",
        "traceId": "zb_trace_123",
        "commandId": "zb_cmd_456"
      }
    }
  },
  "diagnostics": {
    "automationErrorCode": null,
    "retryable": false,
    "redacted": true
  }
}
```

Response:

```json
{
  "stepExecutionId": "sexec_123",
  "status": "succeeded",
  "canonicalEvent": {
    "eventId": "evt_123",
    "eventType": "MessageSent",
    "dedupKey": "zigbrowser:MessageSent:seq_123:enr_123:msg_123:step_1",
    "duplicate": false
  }
}
```

If the automation step succeeds but lacks required canonical send evidence, the backend records the step result as diagnostic only and returns `canonicalEvent: null`. A `MessageSent` event must not be synthesized from a generic browser-command success.

### `POST /api/v1/automation/events`

Purpose: batch ingest canonical sequence events and redacted diagnostic automation events.

Request:

```json
{
  "events": [
    {
      "clientEventId": "zb_evt_123",
      "kind": "canonical_sequence_event",
      "eventType": "MessageDelivered",
      "sequenceId": "seq_123",
      "enrollmentId": "enr_123",
      "messageId": "msg_123",
      "occurredAt": "2026-07-09T16:05:00.000Z",
      "dedupKey": "zigbrowser:MessageDelivered:seq_123:enr_123:msg_123:provider_msg_123",
      "payload": {
        "provider": "gmail",
        "providerMessageId": "provider_msg_123",
        "automation": {
          "executionId": "aexec_123",
          "traceId": "zb_trace_123",
          "commandId": "zb_cmd_456"
        }
      }
    },
    {
      "clientEventId": "zb_evt_124",
      "kind": "automation_diagnostic",
      "eventType": "AutomationCommandFailed",
      "sequenceId": "seq_123",
      "enrollmentId": "enr_123",
      "messageId": "msg_123",
      "occurredAt": "2026-07-09T16:06:00.000Z",
      "dedupKey": "zigbrowser:AutomationCommandFailed:aexec_123:zb_cmd_789",
      "payload": {
        "rpcMethod": "dom.click",
        "automationErrorCode": "platform_rate_limited",
        "retryable": true,
        "traceId": "zb_trace_123",
        "commandId": "zb_cmd_789"
      }
    }
  ]
}
```

Response:

```json
{
  "results": [
    {
      "clientEventId": "zb_evt_123",
      "status": "inserted",
      "eventId": "evt_123",
      "dedupKey": "zigbrowser:MessageDelivered:seq_123:enr_123:msg_123:provider_msg_123"
    },
    {
      "clientEventId": "zb_evt_124",
      "status": "inserted",
      "diagnosticEventId": "diag_123",
      "dedupKey": "zigbrowser:AutomationCommandFailed:aexec_123:zb_cmd_789"
    }
  ]
}
```

Result statuses: `inserted`, `duplicate`, `conflict`, `rejected`.

Canonical event allowlist for this integration:

```text
MessageSent
MessageDelivered
MessageOpened
LinkClicked
ReplySynced
BounceSynced
SuppressionApplied
EnrollmentStopped
AtsWritebackSucceeded
AtsWritebackFailed
CandidateConverted
```

`MessageOpened`, `LinkClicked`, and `MessageDelivered` require the database `CHECK`, `backend/services/sequenceEvents/eventTypes.js`, and ingestion tests to agree before this endpoint accepts them. The current sequences checkout already has this allowlist in migration `130_sequence_tracking.sql`; the automation integration must assert it remains present rather than reintroducing a divergent allowlist.

### `POST /api/v1/automation/telemetry`

Purpose: ingest redacted diagnostics from zigBrowser when they are useful for product support, while keeping analytics sourced from canonical `sequence_events`.

Request:

```json
{
  "executionId": "aexec_123",
  "items": [
    {
      "name": "automation.command",
      "traceId": "zb_trace_123",
      "spanId": "span_123",
      "commandId": "zb_cmd_456",
      "occurredAt": "2026-07-09T16:01:00.000Z",
      "attributes": {
        "rpc.method": "dom.click",
        "result.status": "failed",
        "automation.error": "platform_rate_limited",
        "selector.kind": "css",
        "selector.hash": "sha256:..."
      }
    }
  ]
}
```

Response:

```json
{
  "accepted": 1,
  "rejected": 0
}
```

The backend must reject telemetry items containing raw selectors, raw typed text, raw message body, raw cookies, raw tokens, raw URLs with paths, or candidate PII. This endpoint must never write `sequence_metrics_rollup`.

### `GET /api/v1/automation/analytics/outreach`

Purpose: give the zigBrowser-hosted analytics UI a stable product API backed by `sequence_events` and existing sequence metrics services.

Query:

```text
sequenceId=seq_123
jobId=job_123
ownerUserId=usr_123
mailboxConnectionId=mbx_123
startedBy=usr_123
dateFrom=2026-06-01
dateTo=2026-07-09
groupBy=week
```

Response:

```json
{
  "groupBy": "week",
  "series": [
    {
      "bucketStart": "2026-07-06T00:00:00.000Z",
      "profilesContacted": 42,
      "openRate": 0.62,
      "clickRate": 0.11,
      "replyRate": 0.19,
      "interestRate": 0.07,
      "bounceRate": 0.02
    }
  ],
  "totals": {
    "profilesContacted": 42,
    "opens": 26,
    "clicks": 5,
    "replies": 8,
    "interestedReplies": 3,
    "bounces": 1
  }
}
```

Metric definitions:

| Metric | Source |
|---|---|
| Profiles Contacted | distinct enrollments with canonical `MessageSent`. |
| Open Rate | distinct opened enrollments from canonical `MessageOpened` divided by contacted enrollments. |
| Click Rate | distinct clicked enrollments from canonical `LinkClicked` divided by contacted enrollments. |
| Reply Rate | distinct replied enrollments from canonical `ReplySynced` divided by contacted enrollments. |
| Interest Rate | distinct positive replies where `event_payload.reply_classification = positive` divided by contacted enrollments. |
| Bounce Rate | distinct bounced enrollments from canonical `BounceSynced` divided by contacted enrollments. |

## Database Integration Plan

### Canonical ledger

`sequence_events` remains the canonical product ledger. The integration layer appends rows only through a backend service that runs under tenant context.

For zigBrowser-originated rows:

- `source_system = 'zigbrowser'`
- `actor_user_id` is the delegated user for user actions or the backend service actor for system ingestion.
- `sequence_id`, `enrollment_id`, and `message_id` are required for tracking events that feed analytics.
- `dedup_key` is required for all zigBrowser writes.
- `event_payload.automation.traceId` and `event_payload.automation.commandId` preserve correlation without storing raw automation parameters.

### Required migration

Add a migration in the sequences repo, using the next available sequence number, for the integration layer:

```sql
-- Name suggestion: 13X_sequence_automation_integration.sql

-- Extend or assert the canonical event-type allowlist for PRD 9.1/9.2.
-- If migration 130_sequence_tracking.sql is already present in the target branch,
-- this block must preserve the same values and must not fork a second allowlist.
ALTER TABLE sequence_events
  DROP CONSTRAINT IF EXISTS sequence_events_event_type_chk;

ALTER TABLE sequence_events
  ADD CONSTRAINT sequence_events_event_type_chk
  CHECK (event_type IN (
    'ContactReadinessAssessed',
    'SequenceCreated',
    'AudienceSelected',
    'DraftGenerated',
    'SequenceApproved',
    'MessageSent',
    'MessageDelivered',
    'MessageOpened',
    'LinkClicked',
    'ReplySynced',
    'BounceSynced',
    'SuppressionApplied',
    'EnrollmentStopped',
    'AtsWritebackSucceeded',
    'AtsWritebackFailed',
    'CandidateConverted'
  ));

CREATE TABLE sequence_step_contracts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  sequence_id UUID NOT NULL,
  version INTEGER NOT NULL DEFAULT 0 CHECK (version >= 0),
  steps JSONB NOT NULL DEFAULT '[]'::jsonb,
  steps_hash TEXT NOT NULL DEFAULT 'sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
  updated_by_user_id UUID REFERENCES users(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT sequence_step_contracts_org_id_uniq UNIQUE (org_id, id),
  CONSTRAINT sequence_step_contracts_sequence_uniq UNIQUE (org_id, sequence_id),
  CONSTRAINT sequence_step_contracts_sequence_fk
    FOREIGN KEY (org_id, sequence_id)
    REFERENCES sequences(org_id, id)
    ON DELETE CASCADE
);

CREATE TABLE sequence_automation_executions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  actor_user_id UUID REFERENCES users(id),
  sequence_id UUID NOT NULL,
  execution_plan_id TEXT,
  external_run_id TEXT NOT NULL,
  idempotency_key TEXT NOT NULL,
  request_hash TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN (
    'queued', 'running', 'succeeded', 'failed', 'cancelled', 'rate_limited', 'paused'
  )),
  zigbrowser_session_id_hash TEXT,
  zigbrowser_version TEXT,
  platform TEXT,
  automation_api TEXT,
  trace_id TEXT,
  command_id TEXT,
  last_step_execution_id TEXT,
  last_error_code TEXT,
  started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  finished_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT sequence_automation_executions_org_id_uniq UNIQUE (org_id, id),
  UNIQUE (org_id, idempotency_key),
  UNIQUE (org_id, external_run_id),
  CONSTRAINT sequence_automation_executions_sequence_fk
    FOREIGN KEY (org_id, sequence_id)
    REFERENCES sequences(org_id, id)
    ON DELETE CASCADE
);

CREATE TABLE sequence_automation_idempotency_keys (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  actor_user_id UUID REFERENCES users(id),
  method TEXT NOT NULL,
  endpoint TEXT NOT NULL,
  idempotency_key TEXT NOT NULL,
  request_hash TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('in_progress', 'succeeded', 'failed')),
  response_status INTEGER,
  response_body JSONB,
  resource_type TEXT,
  resource_id UUID,
  sequence_id UUID,
  execution_id UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT sequence_automation_idempotency_keys_org_id_uniq UNIQUE (org_id, id),
  CONSTRAINT sequence_automation_idempotency_keys_scope_uniq UNIQUE (
    org_id, method, endpoint, idempotency_key
  ),
  CONSTRAINT sequence_automation_idempotency_keys_sequence_fk
    FOREIGN KEY (org_id, sequence_id)
    REFERENCES sequences(org_id, id)
    ON DELETE CASCADE,
  CONSTRAINT sequence_automation_idempotency_keys_execution_fk
    FOREIGN KEY (org_id, execution_id)
    REFERENCES sequence_automation_executions(org_id, id)
    ON DELETE CASCADE
);

CREATE TABLE sequence_automation_step_results (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  execution_id UUID NOT NULL,
  sequence_id UUID NOT NULL,
  enrollment_id UUID NOT NULL,
  message_id UUID,
  step_execution_id TEXT NOT NULL,
  step_id TEXT,
  status TEXT NOT NULL CHECK (status IN (
    'queued', 'running', 'succeeded', 'failed', 'skipped', 'rate_limited', 'cancelled'
  )),
  idempotency_key TEXT NOT NULL,
  request_hash TEXT NOT NULL,
  automation_error_code TEXT,
  retryable BOOLEAN NOT NULL DEFAULT false,
  trace_id TEXT,
  command_id TEXT,
  canonical_sequence_event_id UUID,
  diagnostic_payload JSONB NOT NULL DEFAULT '{}'::jsonb,
  occurred_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT sequence_automation_step_results_org_id_uniq UNIQUE (org_id, id),
  UNIQUE (org_id, idempotency_key),
  UNIQUE (org_id, execution_id, step_execution_id),
  CONSTRAINT sequence_automation_step_results_execution_fk
    FOREIGN KEY (org_id, execution_id)
    REFERENCES sequence_automation_executions(org_id, id)
    ON DELETE CASCADE,
  CONSTRAINT sequence_automation_step_results_sequence_fk
    FOREIGN KEY (org_id, sequence_id)
    REFERENCES sequences(org_id, id)
    ON DELETE CASCADE,
  CONSTRAINT sequence_automation_step_results_enrollment_fk
    FOREIGN KEY (org_id, enrollment_id)
    REFERENCES sequence_enrollments(org_id, id)
    ON DELETE CASCADE,
  CONSTRAINT sequence_automation_step_results_message_fk
    FOREIGN KEY (org_id, message_id)
    REFERENCES sequence_messages(org_id, id)
    ON DELETE CASCADE,
  CONSTRAINT sequence_automation_step_results_event_fk
    FOREIGN KEY (org_id, canonical_sequence_event_id)
    REFERENCES sequence_events(org_id, id)
);

CREATE TABLE sequence_automation_diagnostic_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  execution_id UUID,
  sequence_id UUID,
  enrollment_id UUID,
  message_id UUID,
  event_type TEXT NOT NULL,
  dedup_key TEXT,
  request_hash TEXT,
  trace_id TEXT,
  command_id TEXT,
  span_id TEXT,
  payload JSONB NOT NULL DEFAULT '{}'::jsonb,
  occurred_at TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT sequence_automation_diagnostic_events_org_id_uniq UNIQUE (org_id, id),
  CONSTRAINT sequence_automation_diagnostic_events_execution_fk
    FOREIGN KEY (org_id, execution_id)
    REFERENCES sequence_automation_executions(org_id, id)
    ON DELETE CASCADE,
  CONSTRAINT sequence_automation_diagnostic_events_sequence_fk
    FOREIGN KEY (org_id, sequence_id)
    REFERENCES sequences(org_id, id)
    ON DELETE CASCADE,
  CONSTRAINT sequence_automation_diagnostic_events_enrollment_fk
    FOREIGN KEY (org_id, enrollment_id)
    REFERENCES sequence_enrollments(org_id, id)
    ON DELETE CASCADE,
  CONSTRAINT sequence_automation_diagnostic_events_message_fk
    FOREIGN KEY (org_id, message_id)
    REFERENCES sequence_messages(org_id, id)
    ON DELETE CASCADE
);

CREATE UNIQUE INDEX sequence_automation_diagnostic_events_org_dedup_uniq
  ON sequence_automation_diagnostic_events (org_id, dedup_key)
  WHERE dedup_key IS NOT NULL;
```

RLS requirements:

- Enable and force RLS on `sequence_step_contracts`, `sequence_automation_executions`, `sequence_automation_idempotency_keys`, `sequence_automation_step_results`, and `sequence_automation_diagnostic_events`.
- Add tenant policies using `org_id = NULLIF(current_setting('app.current_org', true), '')::uuid` for both `USING` and `WITH CHECK`, matching the current forced-RLS migration style.
- Migration tests must prove a row cannot reference a sequence, enrollment, message, execution, or canonical event from another org, even when the bare UUID exists.
- Do not add an owner-only restrictive policy to automation diagnostics unless the product requires per-owner isolation; support users and admins need to debug automation failures across a tenant.
- Keep all new tables out of analytics rollup queries except where explicitly joined for support/debug correlation.

### Idempotency

Every state-changing write endpoint requires an `Idempotency-Key` header. The backend computes a canonical request hash from the normalized request body plus effective actor, method, endpoint template, path params, and tenant. Successful write responses are persisted in `sequence_automation_idempotency_keys` unless the endpoint has a stronger resource-specific idempotency table; resource-specific tables still link back to the same request hash semantics. `POST /steps/preview` is excluded only because it is specified as read-only and must not persist rendered content.

Rules:

- Same method, endpoint template, org, actor, idempotency key, and request hash returns the original success response with `duplicate: true`.
- Same method, endpoint template, org, actor, and idempotency key with a different request hash returns `409 IDEMPOTENCY_CONFLICT`.
- Batch event ingestion uses item-level `dedupKey` in addition to the request-level idempotency key.
- `sequence_events.dedup_key` remains the canonical dedupe mechanism for analytics events.
- Validation/auth failures do not create durable idempotency rows. Once the backend begins a write transaction, either the resource mutation and idempotency row commit together or both roll back.
- Stored idempotency responses must never include raw rendered bodies, raw selectors, raw typed text, tokens, cookies, or candidate PII.

Write-path persistence matrix:

| Endpoint | Persistence and replay contract |
|---|---|
| `POST /api/v1/automation/sequences` | Store response in `sequence_automation_idempotency_keys` with `resource_type = 'sequence'`; replay returns the same `sequenceId` and `duplicate: true`; conflict blocks a second draft create with the same key. |
| `PUT /api/v1/automation/sequences/:sequenceId/steps` | Store the successful CAS response in `sequence_automation_idempotency_keys`; replay returns the saved post-update `version` even if the current version has advanced; a new key with stale `expectedVersion` returns `STEP_VERSION_CONFLICT`. |
| `POST /api/v1/automation/sequences/:sequenceId/steps/generate` | Store response in `sequence_automation_idempotency_keys` and use canonical `DraftGenerated` `dedupKey` for the ledger write; replay returns the same `messageId`/event metadata. |
| `POST /api/v1/automation/executions` | Persist execution idempotency in `sequence_automation_executions` plus the response envelope in `sequence_automation_idempotency_keys`; replay returns the same `executionId`. |
| `PATCH /api/v1/automation/executions/:executionId` | Persist each status update response in `sequence_automation_idempotency_keys`; replay is a no-op that returns the original state transition response, while a different body with the same key returns `IDEMPOTENCY_CONFLICT`. |
| `POST /api/v1/automation/executions/:executionId/steps/:stepExecutionId/result` | Persist in `sequence_automation_step_results` keyed by `(org_id, idempotency_key)` and `(org_id, execution_id, step_execution_id)`; replay returns the same diagnostic and canonical event outcome. |
| `POST /api/v1/automation/events` | Persist the batch response in `sequence_automation_idempotency_keys`; canonical items also dedupe through `sequence_events(org_id, dedup_key)`, and diagnostic items dedupe through `sequence_automation_diagnostic_events(org_id, dedup_key)`. |
| `POST /api/v1/automation/telemetry` | Persist the accepted/rejected response in `sequence_automation_idempotency_keys`; each accepted item stores a deterministic diagnostic `dedupKey` derived from `executionId`, `traceId`, `spanId`, `commandId`, `name`, and `occurredAt` when the client did not provide one. |

Recommended dedup key shapes:

```text
zigbrowser:execution:<externalRunId>
zigbrowser:step-result:<executionId>:<stepExecutionId>
zigbrowser:MessageSent:<sequenceId>:<enrollmentId>:<messageId>:<stepId>
zigbrowser:MessageDelivered:<sequenceId>:<enrollmentId>:<messageId>:<providerMessageId>
zigbrowser:MessageOpened:<sequenceId>:<enrollmentId>:<messageId>:<trackingPixelId>
zigbrowser:LinkClicked:<sequenceId>:<enrollmentId>:<messageId>:<linkId>
zigbrowser:AutomationCommandFailed:<executionId>:<commandId>
```

## Telemetry and Analytics Mapping

### Canonical events that feed analytics

Only these canonical `sequence_events` rows feed PRD 9.1/9.2 analytics:

| Event type | Required attribution | Analytics use |
|---|---|---|
| `MessageSent` | sequence, enrollment, message | Profiles contacted denominator. |
| `MessageDelivered` | sequence, enrollment, message | Delivery diagnostics and funnel. |
| `MessageOpened` | sequence, enrollment, message | Open rate numerator. |
| `LinkClicked` | sequence, enrollment, message | Click rate numerator. |
| `ReplySynced` | sequence, enrollment, message | Reply and interest rate numerator. |
| `BounceSynced` | sequence, enrollment, message | Bounce rate numerator. |
| `SuppressionApplied` | sequence, enrollment | Hygiene and stop conditions. |
| `EnrollmentStopped` | sequence, enrollment | Sequence stop state. |

### Automation diagnostics that do not feed analytics

These zigBrowser events are operational diagnostics and must not be counted as product outcomes:

- `automation.command`
- `automation.transport.request`
- `automation.transport.response`
- `automation.transport.websocket.push`
- `automation.platform.eval`
- `automation.input.dispatch`
- `automation.network.event`
- `automation.pacing.decision`
- `automation.detection.signal`
- `platform_rate_limited`
- `AutomationCommandSucceeded`
- `AutomationCommandFailed`
- `AutomationExecutionStarted`
- `AutomationExecutionFinished`

Mapping rule: a successful browser command may support a canonical event, but it is not itself a canonical product event. For example, `dom.click` on a send button is insufficient for `MessageSent`; the backend needs provider message evidence, rendered hash, sequence/enrollment/message attribution, and a dedup key.

### Redaction boundary

The integration API accepts only redacted automation context:

- Allowed: `traceId`, `commandId`, `spanId`, `rpcMethod`, low-cardinality status/error enums, selector kind, selector hash, host, path hash, rendered content hash, provider ids, mailbox connection id.
- Rejected: raw selectors, raw typed text, raw email body in telemetry, raw cookies, raw auth tokens, raw tracking URLs, candidate PII in diagnostic payloads, raw page screenshots.

## PRD Coverage Matrix

| PRD | Required endpoints | Required DB contract |
|---|---|---|
| 9.1 Sequence Tracking | `POST /api/v1/automation/events`, `POST /api/v1/automation/executions/:executionId/steps/:stepExecutionId/result`, existing mailbox/webhook routes | Append canonical tracking events to `sequence_events`; add `MessageDelivered`, `MessageOpened`, `LinkClicked`; use `dedup_key`; store automation diagnostics separately. |
| 9.2 Analytics | `GET /api/v1/automation/analytics/outreach`, existing `sequenceMetrics.js` services | Analytics reads canonical `sequence_events` and rollups only; telemetry tables are excluded from metric counters. |
| 9.3 New Sequence Creation | `GET /api/v1/automation/ui/bootstrap`, `GET /api/v1/automation/sequences`, `POST /api/v1/automation/sequences`, `GET /api/v1/automation/sequences/:sequenceId` | Create draft `sequences` rows under backend tenant context; do not accept client-supplied org id; expose mailbox/template/status summaries. |
| 9.4 Step Authoring | `GET /api/v1/automation/sequences/:sequenceId/steps`, `PUT /api/v1/automation/sequences/:sequenceId/steps`, `POST /api/v1/automation/sequences/:sequenceId/steps/generate`, `POST /api/v1/automation/sequences/:sequenceId/steps/preview`, `GET /api/v1/automation/sequences/:sequenceId/execution-plan` | API-level `SequenceStep` schema abstracts current storage; `sequence_step_contracts.version` is the durable CAS source; email drafts map to `sequence_messages`; generated drafts emit `DraftGenerated`; send execution emits `MessageSent` only through backend validation after approval. |

## Implementation Plan by Testable Behavior

### 1. Service topology and configuration

Red:

- Add zigBrowser-side tests for a sequences integration client config that requires `SEQUENCES_API_BASE_URL` or equivalent Phase 0 host configuration.
- Add a negative test proving no Postgres DSN, username, password, or direct SQL adapter is accepted by the zigBrowser integration layer.

Green:

- Introduce a small zigBrowser sequences integration client module that calls HTTP endpoints and can be used by the Phase 0 local UI facade.
- Keep the automation JSON-RPC Unix socket unchanged and out of product data calls.

Refactor:

- Centralize request ids, trace id forwarding, timeouts, and retry policy in one client helper.

Success criteria:

- A hosted dashboard path can call sequence APIs through the client.
- There is no direct PostgreSQL dependency in zigBrowser.

### 2. Backend service authentication

Red:

- Add backend route tests for missing service signature, stale timestamp, replayed nonce, invalid body hash, missing delegated user, and attempted client-supplied `org_id`.
- Add tests that user-session-only reads still derive org/user from existing auth middleware.
- Add mount-order tests proving `/api/v1/automation` runs after `authenticate`, `auditCrossTenant`, and `tenantContextMiddleware`, and that execution/write routes reject user-session-only calls when the auth matrix requires HMAC.

Green:

- Mount `sequencesAutomationRoutes` after the existing `/api/v1/` auth/audit/tenant middleware chain, then add route-level `zigBrowserAutomationAuth` middleware that validates `X-ZB-*` request signing where required by the auth matrix.
- Store registered client secrets in backend environment or secrets manager, not source files.

Refactor:

- Reuse existing request id/error helpers where available so route errors match sequences conventions.

Success criteria:

- All `/api/v1/automation` routes run with backend-derived tenant context.
- Client bodies cannot select an org.

### 3. Read APIs for dashboard and execution planning

Red:

- Add integration tests that seed two orgs and verify `/ui/bootstrap`, `/sequences`, `/sequences/:id`, `/steps`, and `/execution-plan` return only the authenticated org's rows.
- Add tests that `execution-plan` excludes archived, paused, suppressed, over-cap, and not-due work.
- Add tests that `execution-plan` rejects `draft` and `pending_approval` sequences with `409 SEQUENCE_NOT_EXECUTABLE` and never returns executable steps unless the sequence is `active` with `approved_at IS NOT NULL`.

Green:

- Add `backend/routes/sequencesAutomation.js` mounted at `/api/v1/automation`.
- Add backend service methods that compose existing sequence, mailbox, metric, and continuity services into the response schemas above.

Refactor:

- Extract serialization functions for `SequenceSummary`, `SequenceDetail`, `SequenceStep`, and `ExecutionPlanStep`.

Success criteria:

- The UI agents can build dashboards and editors against one stable contract.
- Automation agents receive due work from the backend instead of inferring from raw rows.

### 4. Draft creation and step authoring write APIs

Red:

- Add tests that `POST /sequences` creates draft rows with backend-derived `org_id`.
- Add tests that `PUT /sequences/:id/steps` rejects stale `expectedVersion`, invalid mailboxes, invalid tokens, archived sequences, and cross-org ids.
- Add tests that `expectedVersion` is compared against `sequence_step_contracts.version`, that successful saves increment by exactly one, that stale saves leave `sequence_messages` unchanged, and that idempotent replay returns the original saved version.
- Add tests that generate/preview routes do not log raw rendered bodies.

Green:

- Route draft creation through existing sequence services.
- Implement the `SequenceStep` API adapter over current storage. Use `sequence_step_contracts` for version/CAS and serialized step order, and use `sequence_messages` for email content until the feature implementation introduces a dedicated step table.
- Reuse grounded draft generation paths for step generation.

Refactor:

- Keep step storage mapping private to the backend service. Consumer tests should assert API shape, not table layout.

Success criteria:

- PRD 9.3 and 9.4 flows can save and reload draft state through backend APIs.
- No raw org id or database table dependency leaks to zigBrowser.

### 5. Automation execution tables and idempotent writes

Red:

- Add migration tests for `sequence_step_contracts`, `sequence_automation_executions`, `sequence_automation_idempotency_keys`, `sequence_automation_step_results`, and `sequence_automation_diagnostic_events` with forced tenant RLS, `UNIQUE (org_id, id)`, and composite cross-org FK rejection.
- Add service tests for idempotent execution creation, execution update, step-result write, duplicate replay, and idempotency conflict.
- Add route/service tests that `POST /sequences`, `PUT /steps`, `POST /steps/generate`, `PATCH /executions`, `POST /events`, and `POST /telemetry` all persist replay/conflict state according to the write-path matrix.
- Add tests for execution status transitions and trace/command correlation persistence.

Green:

- Add `13X_sequence_automation_integration.sql` or the next available migration number.
- Implement an automation execution service that owns request hashing, idempotent create/update, and step result persistence.

Refactor:

- Share idempotency helper code with ATS sync if its implementation is reusable.

Success criteria:

- Every automation run and step result can be correlated to a sequence and a zigBrowser trace without feeding analytics by default.

### 6. Canonical event ingestion

Red:

- Add tests that canonical event ingestion rejects unsupported types, missing attribution, cross-org ids, duplicate keys with different payloads, and telemetry-only event types.
- Add tests that duplicate canonical events with the same dedup key return `duplicate`.
- Add tests that `MessageOpened`, `LinkClicked`, and `MessageDelivered` are accepted only when the database `CHECK`, `backend/services/sequenceEvents/eventTypes.js`, and route ingestion allowlist agree.
- Add a drift test that fails if canonical event types are added to the migration but omitted from `eventTypes.js`, or added to `eventTypes.js` but rejected by the database check.

Green:

- Implement `automationEventIngestService` that writes canonical events through the existing sequence event append path and diagnostics through automation diagnostic tables.
- Enforce the canonical event allowlist from this plan.

Refactor:

- Keep event-type normalization and attribution validation in one module used by step result and batch ingest endpoints.

Success criteria:

- Product outcomes land in `sequence_events`.
- Browser diagnostics land in diagnostic tables.
- One request can safely retry without double-counting analytics.

### 7. Analytics read contract

Red:

- Add tests that outreach analytics counts are driven by `sequence_events`, not telemetry or diagnostic tables.
- Seed `MessageSent`, `MessageOpened`, `LinkClicked`, `ReplySynced`, and `BounceSynced` events and assert metric definitions from this plan.
- Seed `MessageDelivered` and assert delivery metrics use canonical delivery events where PRD 9.2 requires them, rather than silently aliasing delivered to `MessageSent`.
- Add tests for date range, sequence, job, owner, mailbox, and group-by filters.

Green:

- Implement `/api/v1/automation/analytics/outreach` as a thin wrapper around existing sequence metrics services where possible.
- Extend `backend/services/sequenceMetrics/metricsService.js` and metric queries where PRD 9.2 requires filters or delivered-event semantics not currently available.

Refactor:

- Reuse rollup/cursor code and avoid writing rollup rows directly from zigBrowser calls.

Success criteria:

- The hosted analytics dashboard can query the backend without knowing rollup table details.
- Diagnostic telemetry never changes outreach rates.

### 8. zigBrowser integration client error handling

Red:

- Add client tests for every backend error code and retryable flag.
- Add tests that backend `traceId` and zigBrowser `commandId` survive errors.
- Add tests that retryable `429`, `500`, and `503` responses use bounded retries and preserve idempotency keys.

Green:

- Implement typed client errors that mirror backend error envelopes.
- Add redaction tests for client-side logging and telemetry.

Refactor:

- Align error names with `AutomationError` only where the concepts match. Do not overload browser command errors for product API failures.

Success criteria:

- UI and automation runners can distinguish validation failures, tenant failures, duplicate replays, rate limits, and backend outages.

### 9. End-to-end contract test

Red:

- Add a cross-repo contract test harness that starts a test sequences backend, seeds a tenant, creates a draft sequence, saves steps, returns an execution plan, creates an automation execution, records a step result, appends `MessageSent`, retries the same write, and reads analytics.

Green:

- Wire zigBrowser's sequences integration client to the test backend.
- Use fake automation trace and command ids; no real WebView is required for this contract test.

Refactor:

- Publish reusable JSON fixtures for the other three agents.

Success criteria:

- The contract test proves the whole seam: hosted UI reads, automation writes, idempotency, canonical analytics, and trace correlation.

## Proposed File Changes

sequences repo:

- `database/migrations/13X_sequence_automation_integration.sql`
- `database/migrations/130_sequence_tracking.sql` only if the target branch has not already landed the `MessageDelivered`/`MessageOpened`/`LinkClicked` event-type extension; otherwise add guard tests that assert it remains synchronized.
- `backend/routes/sequencesAutomation.js`
- `backend/middleware/zigBrowserAutomationAuth.js`
- `backend/services/sequenceEvents/eventTypes.js`
- `backend/services/sequenceMetrics/metricsService.js`
- `backend/services/sequences/automationIntegrationService.js`
- `backend/services/sequences/automationEventIngestService.js`
- `backend/services/sequences/automationAnalyticsService.js` if existing metrics services cannot directly cover PRD 9.2
- `backend/tests/...` using the repo's existing backend test layout

zigBrowser repo:

- `src/sequences_integration.zig` or the Phase 0 equivalent client module
- `src/sequences_api.zig` or the Phase 0 local dashboard facade adapter
- `tests/sequences_integration_contract_test.zig`
- JSON fixtures under the existing test fixture convention once confirmed

## Acceptance Gates

- sequences backend tests pass for auth, tenant scoping, event ingestion, idempotency, analytics, and step serialization.
- zigBrowser tests pass for the integration client, local facade contract, error mapping, redaction, and retry behavior.
- Cross-repo contract test passes without a real browser and without direct DB access from zigBrowser.
- The migration applies cleanly, enables forced RLS on new tables, uses `UNIQUE (org_id, id)` plus composite FKs for tenant-owned references, and does not weaken existing RLS policies.
- Every state-changing write route has durable idempotent replay and conflict tests, including `PUT /steps`, `PATCH /executions`, `POST /events`, and `POST /telemetry`.
- Execution planning rejects `draft` and `pending_approval` sequences and returns executable work only for active approved sequences.
- Step authoring uses a durable version source with compare-and-swap semantics; stale saves cannot partially update `sequence_messages`.
- Analytics reads use canonical `sequence_events` and existing rollup paths; telemetry/diagnostic rows do not affect counters.
- Canonical event allowlists and metrics stay synchronized across the database migration, `eventTypes.js`, ingestion services, and `metricsService.js`.
- The API contract in this document is linked from the implementation bead so sibling agents can consume it.

## Open Integration Points for Phase 0

These points are intentionally narrow so the Phase 0 exposed-API layer can choose its local host mechanics without changing product semantics:

- Whether the hosted dashboard calls a local HTTP route, local IPC bridge, or another zigBrowser-owned facade.
- The exact module names for the zigBrowser sequences integration client.
- How the dashboard obtains a user session token. The backend contract requires a delegated user/session for user-owned actions and a service signature for zigBrowser-originated calls.
- Whether telemetry diagnostics are stored in PostgreSQL only, forwarded to the existing OTLP path, or both. Analytics must still ignore diagnostics.

The backend REST contract, schemas, idempotency rules, event allowlist, and no-direct-Postgres decision are the stable shared seam.
