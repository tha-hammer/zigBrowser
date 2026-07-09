## Plan Review Report: 2026-07-09 Sequences Integration 9.1 Tracking + 9.2 Analytics

Reviewed plan:
`thoughts/searchable/shared/plans/2026-07-09-sequences-integration-91-tracking-92-analytics-plan.md`

Review date: 2026-07-09
Reviewer: Codex
Status: Needs Major Revision

### Review Summary

| Category | Status | Issues Found |
|---|---:|---:|
| Contracts | Critical | 4 |
| Interfaces | Critical | 3 |
| Promises | Warning | 2 |
| Data Models | Critical | 3 |
| APIs | Critical | 4 |
| CodeCleanup Gates | Warning | 1 |

### Critical Issues

1. Phase 0 contract binding is still a placeholder even though the contract file now exists.

   Evidence:
   - Target plan says the Phase 0 contract was missing and leaves endpoint names as "required contract capabilities" (`2026-07-09-sequences-integration-91-tracking-92-analytics-plan.md:31-35`, `:67-96`).
   - The dependency now exists and defines concrete contract name, base path, methods, headers, response envelope, and endpoints (`2026-07-09-sequences-integration-api-db-layer-plan.md:68-91`, `:95-161`, `:547-657`, `:659-729`, `:788-841`).

   Impact: An implementer can still invent a second API shape or bind to the wrong route. This is especially risky because the target plan references existing `/api/v1/sequences/analytics` while Phase 0 defines the hosted-dashboard contract as `/api/v1/automation/analytics/outreach`.

   Required amendment: Replace the capability list with exact Phase 0 method names, backend endpoints, request/response envelopes, headers, idempotency rules, and error codes. Keep any use of existing `/api/v1/sequences/*` routes as backend internals behind the Phase 0 `/api/v1/automation/*` contract.

2. Tenant and actor ownership are assigned to zigBrowser in the plan, but Phase 0 requires backend-derived tenant scope.

   Evidence:
   - Target plan requires an automation run tied to `org_id` and `actor_user_id`, and says the execution request includes `org_id` (`2026-07-09-sequences-integration-91-tracking-92-analytics-plan.md:73-75`, `:209-210`).
   - Phase 0 says the backend rejects any body that attempts to supply `org_id` (`2026-07-09-sequences-integration-api-db-layer-plan.md:126`) and tests attempted client-supplied `org_id` (`:1074`).
   - PRD 9.1 says attribution never trusts client-supplied IDs (`9.1-sequence-tracking.md:255-257`).
   - The existing event writer derives org scope from tenant context, not the request body (`backend/sequences_db.js:4-6`).

   Impact: This weakens the tenant boundary and can produce cross-org writes if implementation follows the target plan literally.

   Required amendment: State that zigBrowser carries only backend-issued sequence/execution/step/message identifiers and service-auth headers. The sequences backend derives `org_id` and actor from authenticated context, validates IDs under tenant scope, and rejects client-supplied org/actor fields.

3. `detection_halted` is not in the Phase 0 status contract or current zigBrowser error model.

   Evidence:
   - Target plan maps detection challenges to run state `detection_halted` and requires the dashboard to render it (`2026-07-09-sequences-integration-91-tracking-92-analytics-plan.md:286-287`, `:449-453`).
   - Phase 0 execution status allows only `queued`, `running`, `succeeded`, `failed`, `cancelled`, `rate_limited`, and `paused`; step status allows only `queued`, `running`, `succeeded`, `failed`, `skipped`, `rate_limited`, and `cancelled` (`2026-07-09-sequences-integration-api-db-layer-plan.md:602`, `:898-900`, `:926-928`).
   - Current zigBrowser detection returns `platform_rate_limited` (`src/automation_script/automation.js:189-190`), and `platform_rate_limited` is the existing retryable automation error (`src/automation/error.zig:5-18`, `:30-45`).

   Impact: Persisting `detection_halted` will fail Phase 0 DB CHECK constraints, or the UI will depend on a state the backend cannot emit.

   Required amendment: Either add `detection_halted` to Phase 0 API, DB CHECKs, and tests, or map detection to an allowed status such as `rate_limited`/`failed` plus `automation.detection.signal` diagnostics and an explicit `automationErrorCode`.

4. Repeat open/click counter updates are specified as a read-model fixture, but require write/projection behavior.

   Evidence:
   - Target plan says repeat opens/clicks increment payload counters without adding rows (`2026-07-09-sequences-integration-91-tracking-92-analytics-plan.md:318-320`), but the Green step only builds read state from fixtures (`:332-336`).
   - PRD 9.1 requires `payload.open_count` and `payload.click_count` to increment on repeated hits (`9.1-sequence-tracking.md:205-223`, `:314-317`).
   - The existing append helper uses `ON CONFLICT ... DO NOTHING` and returns the existing row without updating payload (`backend/sequences_db.js:12-33`).

   Impact: The implementation can pass dashboard fixture tests while the actual canonical row counters never change.

   Required amendment: Add projection/write tests and implementation requirements for duplicate `MessageOpened`/`LinkClicked` events: either a JSONB counter update on conflict or an explicit raw-hit aggregation path that updates the canonical payload before analytics reads it.

5. Outreach Analytics denominators conflict across the target plan, PRD, and Phase 0.

   Evidence:
   - Target plan uses delivered denominators for open/click/reply and sent denominator for hard bounce (`2026-07-09-sequences-integration-91-tracking-92-analytics-plan.md:148-156`).
   - PRD 9.2 agrees: open/click/reply divide by delivered contacted enrollments, interest divides by replies, bounce divides by sent (`9.2-analytics.md:53-60`).
   - Phase 0 currently says open/click/reply/interest/bounce divide by contacted enrollments (`2026-07-09-sequences-integration-api-db-layer-plan.md:832-841`).

   Impact: The hosted dashboard contract and metrics service can return different KPI values for the same event set.

   Required amendment: Amend Phase 0, or explicitly record that PRD 9.2 overrides Phase 0's denominator table for this slice. Add a cross-contract test proving the same canonical fixture returns the PRD denominator values through `/api/v1/automation/analytics/outreach`.

6. Idempotency conflict behavior is missing from this slice's tests.

   Evidence:
   - Target plan only checks duplicate dedup keys returning a single row (`2026-07-09-sequences-integration-91-tracking-92-analytics-plan.md:245-246`, `:306`, `:506`).
   - Phase 0 requires same endpoint/org/idempotency key with a different request hash to return `409 IDEMPOTENCY_CONFLICT` (`2026-07-09-sequences-integration-api-db-layer-plan.md:970-979`) and explicitly calls for duplicate-key different-payload tests (`:1160-1161`).

   Impact: A replay with the same key and changed payload can silently reuse the old event, hiding data corruption or attempted overwrite.

   Required amendment: Add tests for same dedup/idempotency key with changed payload/request hash for execution creation, step result, and canonical event ingestion.

### Warnings

1. Analytics filters and grouping are under-specified at the data-model boundary.

   Evidence:
   - Target plan names Sequence, Project, Started by, Inboxes, Date range, Grouped by, export, and raw numerator/denominator fields (`2026-07-09-sequences-integration-91-tracking-92-analytics-plan.md:381-402`).
   - Existing analytics event reader only filters by `sequenceId` (`backend/sequences_db.js:85-100`).
   - Existing schema has likely sources for some filters, but they require joins or payload mapping: `sequences.job_id`, `sequences.owner_user_id`, and `sequence_messages.sender_mailbox_connection_id` (`090_sequences_foundation.sql:17-25`, `110_sequences_engine.sql:76-118`).

   Recommendation: Add an explicit filter mapping table covering source field, join path, cohort window, timezone behavior, grouping values, export fields, and zero-baseline delta behavior.

2. Event attribution is mixed between top-level columns and payload requirements.

   Evidence:
   - Target plan lists missing `message_id`/`enrollment_id` as edge cases but describes Green work as "payload required-field validation" (`2026-07-09-sequences-integration-91-tracking-92-analytics-plan.md:248-263`).
   - `sequence_events.sequence_id`, `enrollment_id`, and `message_id` are nullable columns today (`110_sequences_engine.sql:149-159`).
   - Phase 0 has a distinct `EVENT_ATTRIBUTION_INVALID` error for missing canonical attribution (`2026-07-09-sequences-integration-api-db-layer-plan.md:157-158`).

   Recommendation: Specify exact top-level attribution requirements for each canonical event and reserve payload validation for event-specific data such as provider IDs, `link_id`, bot flags, and counters.

3. The fail-closed error taxonomy is not bound to Phase 0.

   Evidence:
   - Target plan invents `SEQUENCES_AUTOMATION_CONTRACT_UNAVAILABLE` (`2026-07-09-sequences-integration-91-tracking-92-analytics-plan.md:175-178`).
   - Phase 0 defines `SEQUENCES_BACKEND_UNAVAILABLE`, `AUTOMATION_CONTRACT_INVALID`, `AUTH_REQUIRED`, and related errors (`2026-07-09-sequences-integration-api-db-layer-plan.md:146-161`).

   Recommendation: Define whether `SEQUENCES_AUTOMATION_CONTRACT_UNAVAILABLE` is a local zigBrowser adapter error that wraps Phase 0 failures, or replace it with Phase 0 error codes.

### Well-Defined Areas

- The plan correctly preserves the core analytics invariant: canonical `sequence_events` are KPI source data and automation spans are diagnostic only (`2026-07-09-sequences-integration-91-tracking-92-analytics-plan.md:107-110`, `:410-443`).
- The plan correctly identifies current missing event vocabulary in both JS validation and SQL CHECK constraints (`backend/services/sequenceEvents/eventTypes.js:1-15`, `110_sequences_engine.sql:166-181`).
- The plan keeps low-level `dom.*`/`page.*` command semantics separate from sequence business context (`2026-07-09-sequences-integration-91-tracking-92-analytics-plan.md:229-233`).
- The plan's requested redaction boundaries align with current zigBrowser telemetry patterns for selector hashes, URL hashes, typed length/class, and detection text hashing (`src/automation/telemetry.zig:126-144`, `src/automation/stealth.zig:220-233`).

### CodeCleanup Plan-Hygiene Review

No plan text requires side effects or mutation inside control expressions. The main maintainability issue is ambiguity, not control-flow shape:

- `extend the existing /analytics route or Phase 0 wrapper` leaves two API paths open (`2026-07-09-sequences-integration-91-tracking-92-analytics-plan.md:401-402`). This should be reduced to one bounded implementation path so the code does not grow parallel analytics surfaces.
- The plan's positive hygiene points are worth keeping: mapping tables for terminal states/event types (`:301-302`), split numerator/denominator helpers (`:370-371`), and keeping sequence context out of low-level router parsing (`:232-233`).

### Suggested Plan Amendments

```diff
+ Add a "Concrete Phase 0 Binding" section:
+ - Contract: zb-sequences-v1
+ - Backend base path: /api/v1/automation
+ - Methods/endpoints used by this slice:
+   automation.createExecution -> POST /api/v1/automation/executions
+   automation.updateExecution -> PATCH /api/v1/automation/executions/:executionId
+   automation.recordStepResult -> POST /api/v1/automation/executions/:executionId/steps/:stepExecutionId/result
+   automation.ingestEvents -> POST /api/v1/automation/events
+   automation.ingestTelemetry -> POST /api/v1/automation/telemetry
+   analytics.outreach -> GET /api/v1/automation/analytics/outreach
+
+ Add tenant/auth rule:
+ - zigBrowser MUST NOT send org_id.
+ - Backend derives org/user from auth/session/signature and validates every id under tenant scope.
+ - Tests reject client-supplied org_id and cross-org sequence/enrollment/message IDs.
+
+ Resolve execution status:
+ - Either add detection_halted to Phase 0 API + DB status enums, or map detection to allowed status + diagnostic event.
+
+ Add duplicate counter write behavior:
+ - Repeat MessageOpened increments payload.open_count without adding a row.
+ - Repeat LinkClicked for the same link increments payload.click_count without adding a row.
+ - Same idempotency key with different payload returns conflict, not silent duplicate.
+
+ Resolve metric denominator conflict:
+ - PRD 9.2 denominator rules override Phase 0 contacted-denominator table, or Phase 0 is amended before this plan is implemented.
+
+ Add analytics filter mapping:
+ - Sequence, Project/job, Started by, Inboxes, date range, groupBy, export fields, cohort-window anchoring, and joins.
```

### Approval Status

Needs Major Revision. Do not implement until the Phase 0 binding, tenant/auth boundary, status enum mapping, repeat open/click write behavior, idempotency conflict tests, and denominator conflict are resolved.
