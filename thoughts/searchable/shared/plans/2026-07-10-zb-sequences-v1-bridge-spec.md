# zb-sequences-v1 Bridge Spec

**Date:** 2026-07-10
**Contract:** `zb-sequences-v1`
**Backend base path:** `/api/v1/automation`
**Purpose:** single handoff contract between zigBrowser automation/dashboard code and the sequences backend. The sequences session implements these endpoints; the zigBrowser session consumes them.

This spec supersedes the reviewed 2026-07-09 API-layer plan by grounding the contract in the live sequences backend at commit `bf640403` and baking in the review hardening: tenant-safe composite FKs, active-and-approved execution planning, durable step versioning with compare-and-swap, and explicit idempotent replay/conflict behavior for every write.

The user-facing shorthand says "14 endpoints." This document preserves that as 14 endpoint groups; the sequence collection group contains both `GET` and `POST` on `/sequences`, so the expanded HTTP operation count is 15.

## Source Grounding

All implementation must wrap the existing sequences model and services. Do not create parallel sequence, enrollment, message, event, mailbox, or analytics tables.

Primary live sources:

- Auth mount order: `/home/maceo/ntm_Dev/sequences/backend/server.js:426-432`.
- Existing sequence routes: `/home/maceo/ntm_Dev/sequences/backend/routes/sequences.js:71-188`.
- Metrics routes: `/home/maceo/ntm_Dev/sequences/backend/routes/sequenceMetrics.js:87-95`.
- Continuity routes: `/home/maceo/ntm_Dev/sequences/backend/routes/sequenceContinuity.js:29-42`.
- Webhook idempotency/envelope precedent: `/home/maceo/ntm_Dev/sequences/backend/routes/sequencesWebhook.js:48-120`.
- ATS error/idempotency precedent: `/home/maceo/ntm_Dev/sequences/backend/routes/sequencesAts.js:28-44`.
- Sequence creation/cohort service: `/home/maceo/ntm_Dev/sequences/backend/services/sequences/sequenceService.js:29-72`, `/home/maceo/ntm_Dev/sequences/backend/services/sequences/sequenceService.js:81-113`, `/home/maceo/ntm_Dev/sequences/backend/services/sequences/sequenceService.js:286-301`.
- Draft persistence and `DraftGenerated`: `/home/maceo/ntm_Dev/sequences/backend/services/sequences/draftService.js:92-146`, `/home/maceo/ntm_Dev/sequences/backend/services/sequences/draftPersistence.js:51-84`.
- Side-effect-free authoring generation: `/home/maceo/ntm_Dev/sequences/backend/services/sequences/generateStepService.js:329-463`.
- Send approval gate and provider-backed `MessageSent`: `/home/maceo/ntm_Dev/sequences/backend/services/sequences/sequenceExecutionService.js:49-123`, `/home/maceo/ntm_Dev/sequences/backend/services/sequences/sequenceExecutionService.js:175-286`.
- Due-work gate: `/home/maceo/ntm_Dev/sequences/backend/services/sequences/sendStore.js:14-28`, `/home/maceo/ntm_Dev/sequences/backend/services/sequences/sendStore.js:30-39`.
- Send payload and canonical required fields: `/home/maceo/ntm_Dev/sequences/backend/services/sequences/sendPayload.js:1-12`, `/home/maceo/ntm_Dev/sequences/backend/services/sequences/sendPayload.js:56-101`.
- Event allowlist and required payloads: `/home/maceo/ntm_Dev/sequences/backend/services/sequenceEvents/eventTypes.js:1-65`.
- Canonical event append and dedupe: `/home/maceo/ntm_Dev/sequences/backend/services/sequenceEvents/eventService.js:25-31`, `/home/maceo/ntm_Dev/sequences/backend/sequences_db.js:4-49`.
- Metrics over `sequence_events`: `/home/maceo/ntm_Dev/sequences/backend/services/sequenceMetrics/metricsService.js:189-320`, `/home/maceo/ntm_Dev/sequences/backend/services/sequenceMetrics/metricsService.js:322-400`.
- Outreach analytics service: `/home/maceo/ntm_Dev/sequences/backend/services/sequenceMetrics/outreachAnalyticsService.js:602-740`.
- Schema/RLS patterns: `/home/maceo/ntm_Dev/sequences/database/migrations/090_sequences_foundation.sql:17-165`, `/home/maceo/ntm_Dev/sequences/database/migrations/110_sequences_engine.sql:149-187`, `/home/maceo/ntm_Dev/sequences/database/migrations/110_sequences_engine.sql:391-445`, `/home/maceo/ntm_Dev/sequences/database/migrations/120_sequences_ats_crm.sql:3-131`, `/home/maceo/ntm_Dev/sequences/database/migrations/130_sequence_tracking.sql:18-126`, `/home/maceo/ntm_Dev/sequences/database/migrations/140_outreach_analytics_scope.sql:12-49`.

## Cross-Cutting Contract

### Version Header

Every request must include:

```http
X-ZB-Sequences-Version: zb-sequences-v1
```

Every response, including errors, must echo:

```http
X-ZB-Sequences-Version: zb-sequences-v1
```

Missing or mismatched version returns:

```json
{ "error": { "code": "AUTOMATION_VERSION_UNSUPPORTED", "message": "X-ZB-Sequences-Version must be zb-sequences-v1." } }
```

Use HTTP `400` for a missing or unsupported version. Do not silently fall forward to a later contract.

### Auth And Tenant Context

`/api/v1/automation` must mount below the existing `/api/v1/` chain:

```text
authenticate -> auditCrossTenant -> tenantContextMiddleware -> automation routes
```

This is the same chain currently applied at `/home/maceo/ntm_Dev/sequences/backend/server.js:426-432`. The route-level automation middleware validates zigBrowser service identity, but it must not derive tenant scope. Tenant scope remains `req.user.orgId` plus the `app.current_org`/`app.current_user` GUCs installed by `tenantContextMiddleware`.

Required user/session header:

```http
Authorization: Bearer <delegated-user-session-token>
```

Required HMAC service headers when the auth matrix below says "HMAC required":

```http
X-ZB-Client-Id: <registered zigBrowser client id>
X-ZB-Timestamp: <unix milliseconds>
X-ZB-Nonce: <base64url 128-bit nonce>
X-ZB-Signature: v1=<base64url hmac-sha256>
```

Signature base string:

```text
v1
<UPPERCASE_METHOD>
<path-and-query-exactly-as-sent>
<x-zb-timestamp>
<x-zb-nonce>
<sha256-hex-of-raw-request-body-or-empty-string>
```

The backend must reject stale timestamps, reused nonces, unknown client ids, invalid signatures, a missing delegated user for user-owned operations, and any request body/query/path field attempting to supply `orgId`, `org_id`, `tenantId`, or `tenant_id`.

Auth matrix:

| Endpoint group | User session | HMAC service auth |
|---|---:|---:|
| `GET /ui/bootstrap` | Required | Optional; validate if present |
| `GET /sequences` | Required | Optional; validate if present |
| `POST /sequences` | Required | Required |
| `GET /sequences/:sequenceId` | Required | Optional; validate if present |
| `GET /sequences/:sequenceId/steps` | Required | Optional; validate if present |
| `PUT /sequences/:sequenceId/steps` | Required | Required |
| `POST /sequences/:sequenceId/steps/generate` | Required | Required |
| `POST /sequences/:sequenceId/steps/preview` | Required | Optional; validate if present |
| `GET /sequences/:sequenceId/execution-plan` | Required | Required |
| `POST /executions` | Required | Required |
| `PATCH /executions/:executionId` | Required | Required |
| `POST /executions/:executionId/steps/:stepExecutionId/result` | Required | Required |
| `POST /events` | Required | Required |
| `POST /telemetry` | Required | Required |
| `GET /analytics/outreach` | Required | Optional; validate if present |

### Error Envelope

Errors must use the sequences convention:

```json
{
  "error": {
    "code": "AUTOMATION_CONTRACT_INVALID",
    "message": "Request body does not match zb-sequences-v1.",
    "retryable": false,
    "requestId": "req_123",
    "traceId": "zb_trace_123",
    "commandId": "zb_cmd_123",
    "details": {}
  }
}
```

Only `code` and `message` are required. `retryable`, `requestId`, `traceId`, `commandId`, and `details` are optional but must be present when known.

Common codes:

| HTTP | Code | Retryable | Meaning |
|---:|---|---:|---|
| 400 | `AUTOMATION_CONTRACT_INVALID` | false | Schema, enum, or cross-field validation failed. |
| 400 | `AUTOMATION_VERSION_UNSUPPORTED` | false | Missing or wrong `X-ZB-Sequences-Version`. |
| 401 | `AUTH_REQUIRED` | false | User/session auth missing or invalid. |
| 401 | `ZIGBROWSER_SIGNATURE_INVALID` | false | HMAC headers missing, stale, replayed, or invalid. |
| 403 | `FORBIDDEN` | false | Authenticated principal cannot access the tenant object. |
| 404 | `SEQUENCE_NOT_FOUND` | false | Sequence absent or hidden by tenant scope. |
| 404 | `ENROLLMENT_NOT_FOUND` | false | Enrollment absent or hidden by tenant scope. |
| 404 | `MESSAGE_NOT_FOUND` | false | Message absent or hidden by tenant scope. |
| 404 | `EXECUTION_NOT_FOUND` | false | Automation execution absent or hidden by tenant scope. |
| 409 | `IDEMPOTENCY_CONFLICT` | false | Same idempotency key reused for a different canonical request hash. |
| 409 | `STEP_VERSION_CONFLICT` | false | `expectedVersion` does not match `sequence_step_contracts.version`. |
| 409 | `SEQUENCE_NOT_EXECUTABLE` | false | Sequence is not `active`, lacks `approved_at`, is archived/paused/suppressed, or has no eligible due work. |
| 422 | `EVENT_TYPE_UNSUPPORTED` | false | Event type is not accepted by `eventTypes.js` and the DB CHECK. |
| 422 | `EVENT_ATTRIBUTION_INVALID` | false | Canonical event lacks required sequence/enrollment/message attribution. |
| 422 | `TELEMETRY_REDACTION_FAILED` | false | Telemetry contains raw selectors, raw body, tokens, cookies, candidate PII, or raw URLs. |
| 429 | `RATE_LIMITED` | true | Backend rate limit or tenant send cap blocked the operation. |
| 500 | `DB_WRITE_FAILED` | true | Backend write failed after validation. |
| 503 | `SEQUENCES_BACKEND_UNAVAILABLE` | true | Dependency outage or maintenance. |

### Idempotency-Key Semantics

All state-changing writes require:

```http
Idempotency-Key: <stable client-generated key>
```

The backend stores write idempotency in `sequence_automation_idempotency_keys` from migration 150 unless a resource table also has a stronger uniqueness constraint. The canonical request hash must include:

- normalized request body,
- effective actor user id,
- effective org id,
- HTTP method,
- endpoint template, not raw URL,
- path parameters,
- query parameters that affect behavior,
- `X-ZB-Sequences-Version`.

Replay rules:

- Same org, actor, method, endpoint template, idempotency key, and request hash returns the original success response with `duplicate: true`.
- Same org, actor, method, endpoint template, and idempotency key with a different request hash returns `409 IDEMPOTENCY_CONFLICT`.
- Validation/auth failures must not create durable idempotency rows.
- Once a write transaction starts, the resource mutation and idempotency row commit together or roll back together.
- Stored idempotency responses must not include raw selectors, raw typed text, cookies, auth tokens, raw screenshots, or candidate PII.

Write-path replay matrix:

| Write | Replay behavior | Conflict behavior |
|---|---|---|
| `POST /sequences` | Returns same `sequenceId`, `status`, and `duplicate: true`. | Blocks a second draft create with the same key and different hash. |
| `PUT /sequences/:sequenceId/steps` | Returns the original post-save `version` and serialized response even if current version advanced later. | Same key different body returns `IDEMPOTENCY_CONFLICT`; new key with stale `expectedVersion` returns `STEP_VERSION_CONFLICT`. |
| `POST /sequences/:sequenceId/steps/generate` | Returns same generated step response; no sequence state mutation is replayed. | Same key different generation inputs returns `IDEMPOTENCY_CONFLICT`. |
| `POST /executions` | Returns same `executionId`; `sequence_automation_executions` also enforces `(org_id, external_run_id)`. | Same key or same external run id with different hash returns `IDEMPOTENCY_CONFLICT`. |
| `PATCH /executions/:executionId` | No-op replay returning the original transition response. | Same key different transition body returns `IDEMPOTENCY_CONFLICT`. |
| `POST /executions/:executionId/steps/:stepExecutionId/result` | Returns same step result and canonical/diagnostic event outcome. | Same key different body or same `(execution_id, step_execution_id)` with incompatible body returns `IDEMPOTENCY_CONFLICT`. |
| `POST /events` | Returns same batch result. Canonical items also dedupe through `sequence_events(org_id, dedup_key)`. Diagnostic items dedupe through `sequence_automation_diagnostic_events(org_id, dedup_key)`. | Same request key with different batch hash returns `IDEMPOTENCY_CONFLICT`; same item `dedupKey` with different canonical payload returns item `conflict`. |
| `POST /telemetry` | Returns same accepted/rejected counts and per-item diagnostics. | Same key different telemetry body returns `IDEMPOTENCY_CONFLICT`. |

`POST /steps/preview` is specified as read-only and must not persist rendered body text, so it does not require `Idempotency-Key`. If implementation later persists preview audits, that endpoint becomes a write and must adopt the idempotency contract.

### Pagination

List endpoints use cursor pagination:

```text
limit=50
cursor=<opaque>
```

Rules:

- `limit` default is `50`; max is `100`; min is `1`.
- `cursor` is opaque to clients. It must encode the stable sort tuple and filters needed for the next page.
- Cursor-bearing responses use `{ "items": [...], "nextCursor": "..." }`.
- A cursor created under one org/user/filter/version cannot be reused under another; return `400 AUTOMATION_CONTRACT_INVALID`.
- Stable sort for sequence lists is `updated_at DESC, id DESC` unless endpoint-specific semantics override it.

### Step Versioning And CAS

The durable API version for steps is `sequence_step_contracts.version` from migration 150. It is not derived from `sequence_messages.updated_at`, message count, or a client counter.

Rules:

- `GET /steps` bootstraps one `sequence_step_contracts` row under tenant context if none exists.
- Bootstrap reads current `sequence_messages` (`is_current = true`) and serializes them into the step contract. If no current messages exist, `version = 0` and `steps = []`.
- `PUT /steps` runs in one transaction: lock the `sequence_step_contracts` row with `FOR UPDATE`, compare `expectedVersion`, validate all referenced mailboxes/messages/enrollments under `org_id`, update/supersede `sequence_messages` as needed, replace `steps`, increment `version` by exactly one, store the idempotency response, and commit.
- Stale `expectedVersion` returns `409 STEP_VERSION_CONFLICT` with `currentVersion`; no partial message writes are allowed.
- Approved/active and archived sequences are immutable for authoring. Save is allowed only while sequence status is `draft` or `pending_approval`.

### Canonical Events Versus Diagnostics

Canonical product outcomes must land in `sequence_events` through `appendSequenceEvent`, which validates event types and required payloads in `/home/maceo/ntm_Dev/sequences/backend/services/sequenceEvents/eventTypes.js:43-65` and dedupes via `/home/maceo/ntm_Dev/sequences/backend/sequences_db.js:11-49`.

Automation diagnostics must land in `sequence_automation_diagnostic_events` from migration 150 and must never feed `sequence_metrics_rollup`.

Accepted canonical event types for this bridge:

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

`MessageOpened`, `LinkClicked`, and `MessageDelivered` are already present in migration 130 and `eventTypes.js` at `/home/maceo/ntm_Dev/sequences/database/migrations/130_sequence_tracking.sql:18-42` and `/home/maceo/ntm_Dev/sequences/backend/services/sequenceEvents/eventTypes.js:15-20`. Migration 150 must not fork that allowlist.

## Endpoint Groups

### 1. UI Bootstrap

**Method/path:** `GET /api/v1/automation/ui/bootstrap`
**Auth:** user session required; HMAC optional but validated if present.
**Wraps:** existing auth/tenant chain (`server.js:426-432`), `mailbox_connections` (`110_sequences_engine.sql:26-45`), outreach analytics defaults (`outreachAnalyticsService.js:602-641`).

Request:

```text
include=mailboxes,featureFlags,analyticsDefaults
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

Errors: `AUTH_REQUIRED`, `FORBIDDEN`, `AUTOMATION_VERSION_UNSUPPORTED`, `SEQUENCES_BACKEND_UNAVAILABLE`.

Idempotency: read-only; no `Idempotency-Key`.

### 2. Sequence Collection: List And Create Draft

#### 2A. List Sequences

**Method/path:** `GET /api/v1/automation/sequences`
**Auth:** user session required; HMAC optional but validated if present.
**Wraps:** `sequences` (`090_sequences_foundation.sql:17-29`), `sequence_enrollments` (`090_sequences_foundation.sql:35-71`), continuity dashboard query (`dashboardService.js:41-85`), metrics from `sequence_events` (`metricsService.js:368-400`), optional execution summaries from migration-150 automation tables.

Request query:

```text
status=draft,pending_approval,active,archived
ownerUserId=usr_123
jobId=job_123
workspaceSearchId=ws_123
include=metrics,executionSummary
limit=50
cursor=<opaque>
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
        "clickRate": null,
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

Errors: `AUTH_REQUIRED`, `FORBIDDEN`, `AUTOMATION_CONTRACT_INVALID`, `AUTOMATION_VERSION_UNSUPPORTED`.

Idempotency: read-only; no `Idempotency-Key`.

#### 2B. Create Draft Sequence

**Method/path:** `POST /api/v1/automation/sequences`
**Auth:** user session and HMAC required.
**Wraps:** `createSequence` (`sequenceService.js:29-72`), optional `addCohortCandidates` (`sequenceService.js:81-92`, `sequenceService.js:286-301`), `sequences` (`090_sequences_foundation.sql:17-29`), `sequence_enrollments` (`090_sequences_foundation.sql:35-71`), canonical `SequenceCreated` event (`sequenceService.js:52-59`).

Headers: `Idempotency-Key` required.

Request body:

```json
{
  "name": "Senior Backend Search",
  "jobId": "job_123",
  "workspaceSearchId": "ws_123",
  "source": {
    "kind": "workspace_search",
    "ref": "ws_123"
  },
  "initialAudience": {
    "candidateRefs": [
      { "source": "workspace", "refId": "wc_123" }
    ],
    "overrideDuplicatesFor": []
  }
}
```

Rules:

- `name` is required and trimmed by the existing service.
- Client must not send `orgId`, `ownerUserId`, or tenant fields. Owner is the delegated user from tenant context.
- If `initialAudience` is present, bridge maps it to `addCohortCandidates`.

Response:

```json
{
  "sequenceId": "seq_123",
  "status": "draft",
  "createdAt": "2026-07-09T16:00:00.000Z",
  "cohortSummary": {
    "selected": 1,
    "contactable": 1,
    "missingContact": 0,
    "suppressedOrDuplicate": 0,
    "skipped": []
  },
  "duplicate": false
}
```

Errors: `AUTH_REQUIRED`, `ZIGBROWSER_SIGNATURE_INVALID`, `FORBIDDEN`, `AUTOMATION_CONTRACT_INVALID`, `IDEMPOTENCY_CONFLICT`, `DB_WRITE_FAILED`.

Idempotency: replay returns same `sequenceId` and `duplicate: true`; conflict blocks a second create.

### 3. Sequence Detail

**Method/path:** `GET /api/v1/automation/sequences/:sequenceId`
**Auth:** user session required; HMAC optional but validated if present.
**Wraps:** `sequences`, `sequence_enrollments`, `sequence_messages`, `sequence_events`, `mailbox_connections`, `getCohortSummary` (`sequenceService.js:99-113`), continuity metrics (`sequenceContinuity/metricsService.js:67-97`), optional automation execution tables from migration 150.

Request query:

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
    "workspaceSearchId": "ws_123",
    "approvedAt": null
  },
  "cohort": {
    "included": 25,
    "skipped": 3,
    "preview": [
      {
        "enrollmentId": "enr_123",
        "candidateSource": "workspace",
        "workspaceCandidateId": "wc_123",
        "contactStatus": "ready"
      }
    ]
  },
  "steps": [],
  "metrics": null,
  "executionSummary": null
}
```

Errors: `AUTH_REQUIRED`, `FORBIDDEN`, `SEQUENCE_NOT_FOUND`, `AUTOMATION_CONTRACT_INVALID`.

Idempotency: read-only.

### 4. Get Steps

**Method/path:** `GET /api/v1/automation/sequences/:sequenceId/steps`
**Auth:** user session required; HMAC optional but validated if present.
**Wraps:** `sequence_step_contracts` from migration 150, current `sequence_messages` (`090_sequences_foundation.sql:97-134`, `110_sequences_engine.sql:74-145`), side-effect-free bootstrap serialization under tenant context.

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
      "replyMode": "stop_on_reply",
      "waitBefore": null,
      "senderMailboxId": "mbx_123",
      "subject": "Quick question",
      "body": "Hi {{first_name}}, ...",
      "tokens": ["first_name"],
      "signatureId": null,
      "includeUnsubscribe": true,
      "groundingStatus": "grounded",
      "evidenceMap": [],
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

Errors: `AUTH_REQUIRED`, `FORBIDDEN`, `SEQUENCE_NOT_FOUND`, `DB_WRITE_FAILED` if bootstrap row creation fails.

Idempotency: read-only. Bootstrap row creation is internal and must be idempotent on `(org_id, sequence_id)`.

### 5. Save Steps

**Method/path:** `PUT /api/v1/automation/sequences/:sequenceId/steps`
**Auth:** user session and HMAC required.
**Wraps:** `sequence_step_contracts` from migration 150, `sequence_messages` current/supersede storage (`draftPersistence.js:61-84` pattern; table at `090_sequences_foundation.sql:97-134`), mailbox ownership via `mailbox_connections` (`110_sequences_engine.sql:26-45`).

Headers: `Idempotency-Key` required.

Request body:

```json
{
  "expectedVersion": 3,
  "steps": [
    {
      "stepId": "step_1",
      "kind": "email",
      "index": 0,
      "replyMode": "stop_on_reply",
      "waitBefore": null,
      "senderMailboxId": "mbx_123",
      "subject": "Quick question",
      "body": "Hi {{first_name}}, ...",
      "tokens": ["first_name"],
      "signatureId": null,
      "includeUnsubscribe": true
    }
  ]
}
```

Validation:

- `expectedVersion` required integer, `>= 0`.
- `steps` indexes must be contiguous from zero.
- `kind` is `email` or `wait`.
- Email steps require `subject`, `body`, `senderMailboxId`, `includeUnsubscribe: true`, and tokens resolvable by backend token rules.
- Wait steps require positive duration and unit `minutes`, `hours`, or `days`.
- Sequence status must be `draft` or `pending_approval`.
- All ids are checked by composite `(org_id, id)` lookup, never bare UUID lookup.

Response:

```json
{
  "sequenceId": "seq_123",
  "version": 4,
  "validation": {
    "status": "valid",
    "warnings": []
  },
  "steps": [],
  "duplicate": false
}
```

Errors: `AUTH_REQUIRED`, `ZIGBROWSER_SIGNATURE_INVALID`, `FORBIDDEN`, `SEQUENCE_NOT_FOUND`, `AUTOMATION_CONTRACT_INVALID`, `STEP_VERSION_CONFLICT`, `IDEMPOTENCY_CONFLICT`, `DB_WRITE_FAILED`.

Idempotency: same key/hash returns original response and `duplicate: true`; different hash returns `IDEMPOTENCY_CONFLICT`; a new key with stale `expectedVersion` returns `STEP_VERSION_CONFLICT` and must leave `sequence_messages` unchanged.

### 6. Generate Step Draft

**Method/path:** `POST /api/v1/automation/sequences/:sequenceId/steps/generate`
**Auth:** user session and HMAC required.
**Wraps:** live side-effect-free authoring generation route/service: `sequences.js:111-127`, `generateStepService.js:87-167`, `generateStepService.js:176-213`, `generateStepService.js:329-463`, `groundedOutreachGeneration.js:22-49`, `draftPersistence.callDraft` (`draftPersistence.js:129-147`).

Headers: `Idempotency-Key` required because this consumes LLM capacity and stores idempotency metadata, even though it must not mutate sequence state.

Request body:

```json
{
  "requestId": "zb_gen_123",
  "target": {
    "enrollmentId": "enr_123",
    "senderMailboxConnectionId": "mbx_123"
  },
  "instruction": "Add a concise intro email referencing the candidate's backend work.",
  "currentSteps": [
    {
      "id": "step_1",
      "type": "email",
      "index": 0,
      "subject": "Quick question",
      "body": "Hi {{first_name}}, ...",
      "replyMode": "stop_on_reply"
    }
  ],
  "selectedStepId": "step_1",
  "insertionIndex": 1
}
```

Response:

```json
{
  "requestId": "zb_gen_123",
  "sequenceId": "seq_123",
  "enrollmentId": "enr_123",
  "generatedStep": {
    "stepId": "step_generated_123",
    "kind": "email",
    "index": 1,
    "status": "draft",
    "subject": "Quick question",
    "body": "Hi Ada, ...",
    "replyMode": "stop_on_reply",
    "includeUnsubscribe": true,
    "tokens": [],
    "groundingStatus": "grounded",
    "evidenceMap": [],
    "reviewQueue": [],
    "generatedBy": "ai"
  },
  "insertedAfterStepId": "step_1",
  "generation": {
    "groundingStatus": "grounded",
    "reviewQueue": [],
    "evidenceMap": []
  },
  "duplicate": false
}
```

Rules:

- This endpoint must not write `sequence_messages` or `sequence_events`; live service records `side_effects_skipped` at `/home/maceo/ntm_Dev/sequences/backend/services/sequences/generateStepService.js:442-445`.
- Durable authoring state changes occur only through `PUT /steps`.
- Backend rejects body fields that directly supply candidate identity outside `target.enrollmentId`, matching `/home/maceo/ntm_Dev/sequences/backend/services/sequences/generateStepService.js:92-95`.

Errors: `AUTH_REQUIRED`, `ZIGBROWSER_SIGNATURE_INVALID`, `SEQUENCE_NOT_FOUND`, `ENROLLMENT_NOT_FOUND`, `AUTOMATION_CONTRACT_INVALID`, `DRAFT_GROUNDING_VIOLATION`, `IDEMPOTENCY_CONFLICT`, `RATE_LIMITED`, `SEQUENCES_BACKEND_UNAVAILABLE`.

Idempotency: same key/hash returns the same generated step; different hash returns `IDEMPOTENCY_CONFLICT`.

### 7. Preview Step

**Method/path:** `POST /api/v1/automation/sequences/:sequenceId/steps/preview`
**Auth:** user session required; HMAC optional but validated if present.
**Wraps:** `sequence_step_contracts`, `sequence_messages`, enrollment/contact data in `sequence_enrollments`, but must not persist preview output. Rendering/validation must use the same token and mailbox checks as save.

Request body:

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

Rules:

- Logs, telemetry, and idempotency storage must not contain raw rendered body text.
- `bodyPreview` is returned only to the authenticated caller and should be truncated to the UI-safe preview limit. The full raw body must not be stored by this endpoint.

Errors: `AUTH_REQUIRED`, `FORBIDDEN`, `SEQUENCE_NOT_FOUND`, `ENROLLMENT_NOT_FOUND`, `MESSAGE_NOT_FOUND`, `AUTOMATION_CONTRACT_INVALID`.

Idempotency: read-only preview; no idempotency row.

### 8. Execution Plan

**Method/path:** `GET /api/v1/automation/sequences/:sequenceId/execution-plan`
**Auth:** user session and HMAC required.
**Wraps:** approval and due-work gates in `sendStore.listDueEnrollments` (`sendStore.js:14-28`), `sendStore.isApproved` (`sendStore.js:30-39`), approval state from `sequenceExecutionService.approveSequence` (`sequenceExecutionService.js:82-120`), current messages in `sequence_messages`, mailbox rows in `mailbox_connections`.

Request query:

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

Hard gate:

- Return executable work only when `sequences.status = 'active'` and `sequences.approved_at IS NOT NULL`.
- Enrollment must be `active`, `stop_reason IS NULL`, and `next_send_at <= dueBefore` or null, matching `/home/maceo/ntm_Dev/sequences/backend/services/sequences/sendStore.js:20-24`.
- Draft and `pending_approval` sequences return `409 SEQUENCE_NOT_EXECUTABLE`, not an empty executable plan.
- Suppressed, paused, stopped, bounced, over-cap, or not-due work is excluded.

Errors: `AUTH_REQUIRED`, `ZIGBROWSER_SIGNATURE_INVALID`, `FORBIDDEN`, `SEQUENCE_NOT_FOUND`, `SEQUENCE_NOT_EXECUTABLE`, `RATE_LIMITED`.

Idempotency: read-only. `executionPlanId` can be deterministic from sequence id, due window, filters, and generated timestamp bucket; creating an execution is the durable write.

### 9. Create Execution

**Method/path:** `POST /api/v1/automation/executions`
**Auth:** user session and HMAC required.
**Wraps:** new `sequence_automation_executions` and `sequence_automation_idempotency_keys` from migration 150; validates `sequence_id` via existing `sequences(org_id, id)` unique key (`110_sequences_engine.sql:52-62`).

Headers: `Idempotency-Key` required.

Request body:

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

Errors: `AUTH_REQUIRED`, `ZIGBROWSER_SIGNATURE_INVALID`, `FORBIDDEN`, `SEQUENCE_NOT_FOUND`, `SEQUENCE_NOT_EXECUTABLE`, `AUTOMATION_CONTRACT_INVALID`, `IDEMPOTENCY_CONFLICT`, `DB_WRITE_FAILED`.

Idempotency: same key/hash returns same execution. Same `(org_id, external_run_id)` with incompatible request hash returns `IDEMPOTENCY_CONFLICT`.

### 10. Update Execution

**Method/path:** `PATCH /api/v1/automation/executions/:executionId`
**Auth:** user session and HMAC required.
**Wraps:** `sequence_automation_executions` and `sequence_automation_idempotency_keys` from migration 150.

Headers: `Idempotency-Key` required.

Request body:

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

Response:

```json
{
  "executionId": "aexec_123",
  "status": "rate_limited",
  "updatedAt": "2026-07-09T16:01:00.000Z",
  "duplicate": false
}
```

Rules:

- This endpoint never appends canonical analytics events.
- Terminal statuses are `succeeded`, `failed`, and `cancelled`. Transitioning from a terminal status with a new key must return `409 EXECUTION_STATE_CONFLICT` unless the new status is identical and the body is semantically equivalent.

Errors: `AUTH_REQUIRED`, `ZIGBROWSER_SIGNATURE_INVALID`, `EXECUTION_NOT_FOUND`, `AUTOMATION_CONTRACT_INVALID`, `IDEMPOTENCY_CONFLICT`, `EXECUTION_STATE_CONFLICT`, `DB_WRITE_FAILED`.

Idempotency: replay returns original transition response; same key different body returns `IDEMPOTENCY_CONFLICT`.

### 11. Record Step Result

**Method/path:** `POST /api/v1/automation/executions/:executionId/steps/:stepExecutionId/result`
**Auth:** user session and HMAC required.
**Wraps:** new `sequence_automation_step_results`, canonical `appendSequenceEvent` (`eventService.js:25-31`), existing `sequence_events` (`110_sequences_engine.sql:149-187`), `eventTypes.js` required `MessageSent` payload fields (`eventTypes.js:24-41`), and sent-message field semantics from `sendPayload.js:56-101`.

Headers: `Idempotency-Key` required.

Request body:

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
      "message_id": "msg_123",
      "sent_at": "2026-07-09T16:01:00.000Z",
      "sender_mailbox_connection_id": "mbx_123",
      "sender_user_id": "usr_123",
      "rendered_subject": "Quick question",
      "rendered_body_hash": "sha256:...",
      "rendered_body_snapshot": "Hi Ada, ...",
      "provider_message_id": "provider_msg_123",
      "provider_thread_id": "provider_thread_123",
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
  },
  "duplicate": false
}
```

Rules:

- A successful browser command is not enough for `MessageSent`. The canonical event requires provider message evidence and the required payload fields listed in `eventTypes.js`.
- If step status is not `succeeded`, persist a diagnostic result and do not append a canonical event.
- If `status = succeeded` but `eventCandidate` is missing or invalid, persist diagnostic result and return `canonicalEvent: null` with validation warnings; do not synthesize product outcomes.

Errors: `AUTH_REQUIRED`, `ZIGBROWSER_SIGNATURE_INVALID`, `EXECUTION_NOT_FOUND`, `SEQUENCE_NOT_FOUND`, `ENROLLMENT_NOT_FOUND`, `MESSAGE_NOT_FOUND`, `AUTOMATION_CONTRACT_INVALID`, `EVENT_TYPE_UNSUPPORTED`, `EVENT_ATTRIBUTION_INVALID`, `IDEMPOTENCY_CONFLICT`, `DB_WRITE_FAILED`.

Idempotency: replay returns same diagnostic/canonical outcome. Same `executionId` plus `stepExecutionId` with incompatible body returns `IDEMPOTENCY_CONFLICT`.

### 12. Ingest Events

**Method/path:** `POST /api/v1/automation/events`
**Auth:** user session and HMAC required.
**Wraps:** `appendSequenceEvent` (`eventService.js:25-31`), `sequence_events` dedupe (`sequences_db.js:11-49`), `CANONICAL_SEQUENCE_EVENT_TYPES` (`eventTypes.js:1-22`), diagnostic table from migration 150.

Headers: `Idempotency-Key` required.

Request body:

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
        "provider_message_id": "provider_msg_123",
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
  ],
  "duplicate": false
}
```

Item statuses: `inserted`, `duplicate`, `conflict`, `rejected`.

Rules:

- Canonical events require `sequenceId`; tracking/funnel events require `enrollmentId`; message-level events require `messageId`.
- `source_system` for zigBrowser canonical events is `zigbrowser`.
- If `sequence_events` already has the same `(org_id, dedup_key)` with the same canonical payload hash, return item `duplicate`.
- If the same dedup key exists with different event type, attribution, or payload hash, return item `conflict`; do not insert.
- Diagnostic events are stored in `sequence_automation_diagnostic_events`; they do not feed analytics.

Errors: request-level `AUTH_REQUIRED`, `ZIGBROWSER_SIGNATURE_INVALID`, `AUTOMATION_CONTRACT_INVALID`, `IDEMPOTENCY_CONFLICT`, `DB_WRITE_FAILED`. Per-item errors use `status: "rejected"` with an item `error`.

Idempotency: request-level replay returns the same batch result. Item-level dedupe still applies if a new request key resubmits known dedup keys.

### 13. Ingest Telemetry

**Method/path:** `POST /api/v1/automation/telemetry`
**Auth:** user session and HMAC required.
**Wraps:** `sequence_automation_diagnostic_events` and idempotency table from migration 150; zigBrowser telemetry redaction contract from the automation plans; must not write `sequence_events` or `sequence_metrics_rollup`.

Headers: `Idempotency-Key` required.

Request body:

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
  "rejected": 0,
  "items": [
    {
      "index": 0,
      "status": "accepted",
      "diagnosticEventId": "diag_123"
    }
  ],
  "duplicate": false
}
```

Redaction rejection list:

- raw selectors,
- raw typed text,
- raw message bodies,
- raw cookies,
- auth tokens,
- raw URLs with paths/query strings,
- screenshots,
- candidate PII,
- unbounded DOM text.

Errors: `AUTH_REQUIRED`, `ZIGBROWSER_SIGNATURE_INVALID`, `EXECUTION_NOT_FOUND`, `AUTOMATION_CONTRACT_INVALID`, `TELEMETRY_REDACTION_FAILED`, `IDEMPOTENCY_CONFLICT`, `DB_WRITE_FAILED`.

Idempotency: replay returns same accepted/rejected response. If client omits item dedup keys, backend derives one from `executionId`, `traceId`, `spanId`, `commandId`, `name`, and `occurredAt`.

### 14. Outreach Analytics

**Method/path:** `GET /api/v1/automation/analytics/outreach`
**Auth:** user session required; HMAC optional but validated if present.
**Wraps:** existing route `sequenceMetrics.js:87-95`, filter authorization in `sequenceMetrics.js:47-58`, `getOutreachAnalytics` (`outreachAnalyticsService.js:644-740`), `listOutreachAnalyticsEvents` over `sequence_events` (`sequences_db.js:113-185`), analytics RLS scope (`140_outreach_analytics_scope.sql:12-49`).

Request query:

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
  },
  "diagnostics": {
    "source": "sequence_events",
    "telemetryIncluded": false
  }
}
```

Metric definitions:

| Metric | Source |
|---|---|
| `profilesContacted` | Distinct enrollments with canonical `MessageSent`. |
| `openRate` | Distinct non-bot `MessageOpened` enrollments divided by contacted enrollments. |
| `clickRate` | Distinct non-bot `LinkClicked` enrollments divided by contacted enrollments. |
| `replyRate` | Distinct `ReplySynced` enrollments divided by contacted enrollments. |
| `interestRate` | Distinct positive `ReplySynced` enrollments divided by contacted enrollments. |
| `bounceRate` | Distinct hard `BounceSynced` enrollments divided by contacted enrollments. |

Implementation note: live `metricsService.computeSequenceFunnel` currently computes delivered as sent minus hard bounces at `/home/maceo/ntm_Dev/sequences/backend/services/sequenceMetrics/metricsService.js:270-294`; if the bridge exposes delivered-specific fields, it must use canonical `MessageDelivered` events rather than silently aliasing delivered to `MessageSent`.

Errors: `AUTH_REQUIRED`, `FORBIDDEN`, `AUTOMATION_CONTRACT_INVALID`, `SEQUENCES_BACKEND_UNAVAILABLE`.

Idempotency: read-only.

## Migration 150 Spec

**File to implement in sequences repo:** `database/migrations/150_sequence_automation_integration.sql`

Do not edit existing migrations. Migration 150 creates only bridge-owned automation and step-contract tables. It must reuse existing sequence/enrollment/message/event tables through composite `(org_id, id)` FKs.

Required DDL:

```sql
CREATE EXTENSION IF NOT EXISTS pgcrypto;

DO $$
BEGIN
  -- Guardrail only: migration 130 already owns the additive tracking allowlist.
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint c
    JOIN pg_class t ON t.oid = c.conrelid
    WHERE t.relname = 'sequence_events'
      AND c.conname = 'sequence_events_event_type_chk'
      AND pg_get_constraintdef(c.oid) LIKE '%MessageOpened%'
      AND pg_get_constraintdef(c.oid) LIKE '%LinkClicked%'
      AND pg_get_constraintdef(c.oid) LIKE '%MessageDelivered%'
  ) THEN
    RAISE EXCEPTION 'sequence_events additive tracking event types from migration 130 are required before migration 150';
  END IF;
END $$;

CREATE TABLE sequence_step_contracts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  sequence_id UUID NOT NULL,
  version INTEGER NOT NULL DEFAULT 0 CHECK (version >= 0),
  steps JSONB NOT NULL DEFAULT '[]'::jsonb,
  steps_hash TEXT NOT NULL,
  updated_by_user_id UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (org_id, id),
  UNIQUE (org_id, sequence_id),
  FOREIGN KEY (org_id, sequence_id)
    REFERENCES sequences(org_id, id)
    ON DELETE CASCADE
);

CREATE TABLE sequence_automation_executions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  actor_user_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  sequence_id UUID NOT NULL,
  external_run_id TEXT NOT NULL,
  execution_plan_id TEXT,
  status TEXT NOT NULL CHECK (
    status IN ('queued','running','succeeded','failed','cancelled','rate_limited','paused')
  ),
  idempotency_key TEXT NOT NULL,
  request_hash TEXT NOT NULL,
  zigbrowser_session_id_hash TEXT,
  zigbrowser_version TEXT,
  platform TEXT,
  automation_api TEXT,
  trace_id TEXT,
  command_id TEXT,
  last_step_execution_id TEXT,
  last_error_code TEXT,
  started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  finished_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (org_id, id),
  UNIQUE (org_id, external_run_id),
  UNIQUE (org_id, idempotency_key),
  FOREIGN KEY (org_id, sequence_id)
    REFERENCES sequences(org_id, id)
    ON DELETE CASCADE
);

CREATE TABLE sequence_automation_idempotency_keys (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  actor_user_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  method TEXT NOT NULL,
  endpoint_template TEXT NOT NULL,
  idempotency_key TEXT NOT NULL,
  request_hash TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('in_progress','succeeded','failed')),
  response_status INTEGER,
  response_body JSONB,
  resource_type TEXT,
  resource_id UUID,
  sequence_id UUID,
  execution_id UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (org_id, id),
  UNIQUE (org_id, actor_user_id, method, endpoint_template, idempotency_key),
  FOREIGN KEY (org_id, sequence_id)
    REFERENCES sequences(org_id, id)
    ON DELETE CASCADE,
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
  status TEXT NOT NULL CHECK (
    status IN ('queued','running','succeeded','failed','skipped','rate_limited','cancelled')
  ),
  idempotency_key TEXT NOT NULL,
  request_hash TEXT NOT NULL,
  automation_error_code TEXT,
  retryable BOOLEAN NOT NULL DEFAULT false,
  trace_id TEXT,
  command_id TEXT,
  canonical_sequence_event_id UUID,
  diagnostic_payload JSONB NOT NULL DEFAULT '{}'::jsonb,
  occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (org_id, id),
  UNIQUE (org_id, idempotency_key),
  UNIQUE (org_id, execution_id, step_execution_id),
  FOREIGN KEY (org_id, execution_id)
    REFERENCES sequence_automation_executions(org_id, id)
    ON DELETE CASCADE,
  FOREIGN KEY (org_id, sequence_id)
    REFERENCES sequences(org_id, id)
    ON DELETE CASCADE,
  FOREIGN KEY (org_id, enrollment_id)
    REFERENCES sequence_enrollments(org_id, id)
    ON DELETE CASCADE,
  FOREIGN KEY (org_id, message_id)
    REFERENCES sequence_messages(org_id, id)
    ON DELETE CASCADE,
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
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (org_id, id),
  FOREIGN KEY (org_id, execution_id)
    REFERENCES sequence_automation_executions(org_id, id)
    ON DELETE CASCADE,
  FOREIGN KEY (org_id, sequence_id)
    REFERENCES sequences(org_id, id)
    ON DELETE CASCADE,
  FOREIGN KEY (org_id, enrollment_id)
    REFERENCES sequence_enrollments(org_id, id)
    ON DELETE CASCADE,
  FOREIGN KEY (org_id, message_id)
    REFERENCES sequence_messages(org_id, id)
    ON DELETE CASCADE
);

CREATE UNIQUE INDEX sequence_automation_diagnostic_events_org_dedup_uniq
  ON sequence_automation_diagnostic_events (org_id, dedup_key)
  WHERE dedup_key IS NOT NULL;

CREATE INDEX sequence_step_contracts_sequence_idx
  ON sequence_step_contracts (org_id, sequence_id);

CREATE INDEX sequence_automation_executions_sequence_status_idx
  ON sequence_automation_executions (org_id, sequence_id, status, updated_at DESC);

CREATE INDEX sequence_automation_step_results_execution_idx
  ON sequence_automation_step_results (org_id, execution_id, created_at DESC);

CREATE INDEX sequence_automation_diagnostic_events_execution_idx
  ON sequence_automation_diagnostic_events (org_id, execution_id, occurred_at DESC);

DO $$
DECLARE
  t text;
  automation_tables text[] := ARRAY[
    'sequence_step_contracts',
    'sequence_automation_executions',
    'sequence_automation_idempotency_keys',
    'sequence_automation_step_results',
    'sequence_automation_diagnostic_events'
  ];
BEGIN
  FOREACH t IN ARRAY automation_tables LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON %I', t || '_tenant_isolation', t);
    EXECUTE format(
      'CREATE POLICY %I ON %I FOR ALL ' ||
      'USING (org_id = NULLIF(current_setting(''app.current_org'', true), '''')::uuid) ' ||
      'WITH CHECK (org_id = NULLIF(current_setting(''app.current_org'', true), '''')::uuid)',
      t || '_tenant_isolation',
      t
    );
  END LOOP;
END $$;
```

Migration 150 acceptance:

- Every new tenant-owned table has `UNIQUE (org_id, id)`.
- Every sequence, enrollment, message, execution, and canonical event reference uses a composite `(org_id, id)` FK.
- Forced RLS is enabled on every new table.
- RLS policy uses the same `NULLIF(current_setting('app.current_org', true), '')::uuid` pattern as migrations 090, 110, 120, and 130.
- Cross-org FK inserts fail even when the bare UUID exists in another tenant.
- Diagnostics tables are not read by analytics rollups.
- Migration does not alter `sequence_events` event-type CHECK except for the guard assertion that migration 130 is present.

## Who Builds What

### Sequences Session

- Implement `backend/routes/sequencesAutomation.js` mounted at `/api/v1/automation` after the existing auth/audit/tenant chain.
- Implement `backend/middleware/zigBrowserAutomationAuth.js` for HMAC validation and nonce replay rejection.
- Implement migration `150_sequence_automation_integration.sql` exactly to the tenant-safe pattern above.
- Add services for step-contract CAS, execution tracking, idempotency, event ingestion, telemetry diagnostics, and automation analytics adaptation.
- Reuse existing `sequenceService`, `draftService`, `draftPersistence`, `generateStepService`, `sendStore`, `sequenceExecutionService`, `eventService`, and metrics services.
- Add backend tests for auth matrix, tenant isolation, composite FKs, idempotency replay/conflict, step CAS, active/approved execution-plan gating, canonical event ingestion, telemetry redaction, and analytics exclusion of diagnostics.

### zigBrowser Session

- Build a `zb-sequences-v1` client facade that calls only `/api/v1/automation`; no direct PostgreSQL access.
- Forward `X-ZB-Sequences-Version`, delegated user session, HMAC headers, trace ids, command ids, and stable idempotency keys.
- Wire browser automation runtime to `execution-plan`, `executions`, `recordStepResult`, `events`, and `telemetry`.
- Build the hosted dashboard against this spec's response schemas.
- Preserve the existing JSON-RPC browser command channel as local automation control; do not use it for sequence database access.
- Add contract/client tests for all error codes, retryability, idempotent replay, redaction, and no-DB-credential topology.
