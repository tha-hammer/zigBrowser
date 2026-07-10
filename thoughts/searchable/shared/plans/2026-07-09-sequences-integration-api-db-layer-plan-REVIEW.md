# Plan Review Report: Sequences Integration API + DB Layer

**Reviewed plan:** `thoughts/searchable/shared/plans/2026-07-09-sequences-integration-api-db-layer-plan.md`
**Reviewer:** Codex (pane 0, `$review_plan`), captured from inline review + beads `zigBrowser-yqf`
**Date:** 2026-07-09
**Approval status:** ⚠️ **Needs Major Revision before implementation**

---

## Findings

### 1. CRITICAL — Proposed migration lacks tenant-safe composite FKs
The new tables reference bare IDs (executions / step results / diagnostics) at `api-db-layer-plan.md:889`. The existing sequences schema consistently uses `UNIQUE (org_id, id)` plus composite FKs for tenant-owned relations — see `sequences/database/migrations/090_sequences_foundation.sql:57`, `110_sequences_engine.sql:162`, `120_sequences_ats_crm.sql:60`.
**Fix:** amend the migration to add `org_id` FKs, `UNIQUE (org_id, id)`, and composite FKs for sequence/enrollment/message/execution/event references.

### 2. CRITICAL — Execution-plan example returns pre-approval work
The plan says execution work happens after approval, but the response example returns `status: "pending_approval"` at `api-db-layer-plan.md:483`. Current code only selects due work when sequence and enrollment are active and `approved_at IS NOT NULL` (`sequences/backend/services/sequences/sendStore.js:14`); approval sets those fields (`sequenceExecutionService.js:82`).
**Fix:** amend tests to reject `draft` and `pending_approval` execution plans.

### 3. CRITICAL — `expectedVersion` has no durable storage contract
The step API promises optimistic concurrency at `api-db-layer-plan.md:367`, but current storage is `sequence_messages` current/supersede state, not a versioned step model (`090_sequences_foundation.sql:112`, `draftPersistence.js:44`).
**Fix:** define the version source and compare-and-swap behavior before implementation.

### 4. CRITICAL — Idempotency is overclaimed
The plan requires `Idempotency-Key` on every write (`api-db-layer-plan.md:97`), but tests/schema mainly cover execution-create and step-result writes (~`api-db-layer-plan.md:1135`). `PUT /steps`, `PATCH /executions`, batch events, and telemetry need explicit replay/conflict behavior and persistence.
**Fix:** specify replay/conflict semantics + persistence for every write path.

### 5. WARNING — Auth middleware order is underspecified
Existing `/api/v1/` routes run `authenticate` → `auditCrossTenant` → `tenantContextMiddleware` (`sequences/backend/server.js:418`). The plan adds service HMAC auth but doesn't say whether `/api/v1/automation` mounts before/after that chain, or which endpoints allow user-session-only access.
**Fix:** add an endpoint auth matrix and mount order.

### 6. WARNING — Event/metrics implementation files missing from proposed changes
The plan adds `MessageDelivered`, `MessageOpened`, `LinkClicked`, but current `eventTypes.js` rejects them (`sequences/backend/services/sequenceEvents/eventTypes.js:1`), and current metrics treat delivered as `MessageSent` (`sequenceMetrics/metricsService.js:100`).
**Fix:** add those existing files to the plan's change set.

---

## CodeCleanup gates
No side-effecting conditionals or mutation-in-control issues (this is a plan), but the **duplicated event allowlists** and **migration/status drift** are maintainability risks to resolve.

## Summary
4 Critical + 2 Warning. The connective contract is directionally sound (backend-mediated topology) but must be hardened on tenant-safety, approval gating, step versioning, and idempotency before it can drive implementation.
