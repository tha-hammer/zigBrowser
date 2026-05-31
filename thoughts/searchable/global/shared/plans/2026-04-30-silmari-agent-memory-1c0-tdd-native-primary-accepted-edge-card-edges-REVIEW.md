---
date: 2026-04-30T10:38:00-04:00
reviewer: BrownIsland
reviewed_plan: thoughts/searchable/shared/plans/2026-04-30-silmari-agent-memory-1c0-tdd-native-primary-accepted-edge-card-edges.md
plan_commit: 20f4482b9298afa2078f6de596798b61aacb63fd
review_basis_commit: 803e556
status: needs_major_revision
related_beads:
  - silmari-agent-memory-1c0
---

# Plan Review Report: Native-Primary Accepted Edge `card_edges`

## Review Summary

| Category | Status | Issues Found |
|---|---:|---:|
| Contracts | Critical | 3 |
| Interfaces | Critical | 3 |
| Promises | Critical | 2 |
| Data Models | Critical | 3 |
| APIs | Warning | 2 |

Overall: the plan's direction is correct. The source-of-truth fix belongs in the live native write path, and adding an accepted reviewed-edge command is the right boundary. The plan is not yet implementation-ready because the write contract is underspecified in ways that will either fail to compile or produce inconsistent audit/durability behavior.

Review basis: local checkout `803e556`. The plan frontmatter names `20f4482b9298afa2078f6de596798b61aacb63fd`; this review did not pull or rewrite the dirty worktree.

## Contract Review

### Well-Defined

- The component ownership is correctly placed: native `card_edges` is authoritative, and labels are compatibility projection. See plan lines 60-66 and current export projection in `apps/silmari_memory_rust/src/export.rs:213`.
- The Rust CLI boundary is correctly introduced as a separate accepted-edge command instead of overloading Beads dependency types. See plan lines 128-172.
- The TypeScript boundary keeps mode routing in `br-adapter.ts` and command assembly in `native-adapter.ts`, matching the current facade pattern in `apps/silmari-mcp/src/lib/br-adapter.ts:80`.

### Missing or Unclear

1. Critical: `commit_accepted_edge(&conn, ...)` conflicts with the transaction requirement.

   The plan's red test calls `store::commit_accepted_edge(&conn, ...)` at plan lines 312-324, while the implementation steps require "Start a transaction" at line 350. In this repo's Rust stack, `rusqlite = 0.37.0`, and existing transaction code uses `&mut Connection` (`apps/silmari_memory_rust/src/schema.rs:91-92`). A store function that takes `&Connection` cannot call `conn.transaction()` without switching to a different transaction strategy.

   Impact: the first green implementation is likely to fail at compile time, or the implementer may silently skip the atomicity guarantee.

   Recommendation: amend the plan to choose one explicit API:

   - `pub fn commit_accepted_edge(conn: &mut Connection, input: AcceptedEdgeCommit) -> Result<AcceptedEdgeCommitResult>` and update tests/helpers to pass a mutable connection; or
   - `pub fn commit_accepted_edge_unchecked(conn: &Connection, ...)` using `unchecked_transaction()` with a documented no-nested-transaction precondition; or
   - split into `commit_accepted_edge_tx(tx: &Transaction, ...)` plus a public wrapper that owns `&mut Connection`.

2. Critical: duplicate commit semantics are internally inconsistent.

   The desired state says duplicate accepted commits are idempotent at plan line 90. Behavior 1 says exactly one event is present and repeats are idempotent at lines 285-290, and manual criteria say no duplicate events at line 385. But the green steps say "Insert or update `card_edges`" and "Insert `edge.accepted`" at lines 351-354, while the JSON example only shows `"changed": true` at lines 147-154.

   Impact: reconciliation cannot reliably produce `already_present`, retry after a proposal-file write failure can create duplicate audit events, and `created_at`/`evidence` may be overwritten by a later duplicate.

   Recommendation: define result and conflict behavior before implementation:

   - exact duplicate reviewed edge with same `proposal_id`: return `changed=false`; do not update `created_at`, `created_by`, `evidence`, or insert a new event;
   - existing reviewed edge with a different `proposal_id`: either return a validation error or preserve the first evidence and return a distinct `alreadyPresent=true`;
   - existing `auto` row for a reviewed type: define whether accepted commit promotes it or fails as corrupt legacy state;
   - output should include enough data for reconciliation counts, for example `changed`, `alreadyPresent`, `sourceId`, `targetId`, `edgeType`, `reviewState`.

3. Critical: existing direct reviewed-edge writers are not covered by the new authority boundary.

   The plan restricts reviewed `edge-add` and routes `commitLink()` through `edge-commit`, but production code already writes `reinforces` directly through `addEdge()` for body-hash recurrence: `apps/silmari-mcp/src/lib/card-ops.ts:284`. The surrounding comments explicitly say this bypasses `proposeOrAddEdge` because the body hash is considered evidence (`apps/silmari-mcp/src/lib/card-ops.ts:272-282`). Current `addEdge()` still writes any edge type as a `ref:*` label (`apps/silmari-mcp/src/lib/edges.ts:79-117`).

   Impact: after this plan, native-primary can still create reviewed label-only edges outside `card_edges`, or an overzealous `addEdge()` rejection will break the body-hash recurrence path. Either outcome violates the plan's source-of-truth promise.

   Recommendation: explicitly decide the body-hash path. Options:

   - keep it out of scope and state that only accepted proposal commits get native durability in this slice; or
   - generalize the Rust helper from `AcceptedEdgeCommit` to an authorized reviewed-edge commit with `authority: "accepted-proposal" | "body-hash-recurrence"`, then route `emitReinforcesToPrior()` through it in native-primary.

## Interface Review

### Well-Defined

- The new CLI command shape names the right inputs: box, source, target, type, proposal id, reviewer, reason. See plan lines 132-142.
- The TypeScript facade layering matches existing code: callers import `br-adapter.ts`; `br-adapter.ts` owns runtime mode selection; `native-adapter.ts` owns Rust argument assembly.

### Missing or Unclear

1. Critical: timestamp ownership is contradictory.

   `AcceptedEdgeCommit` requires `reviewed_at` at plan lines 160-168. The CLI command shape has no `--reviewed-at` at lines 132-142. The TypeScript input also has no `reviewedAt` at lines 212-221. The event contract says `created_at` should use "the same timestamp used for the edge write" at lines 191-197, but no component owns creating that timestamp.

   Impact: CLI cannot construct the specified store input without inventing hidden behavior, and reconciliation cannot decide whether to preserve proposal `resolved_at` or use repair time.

   Recommendation: amend the contract:

   - live `edge-commit` should either accept `--reviewed-at` or have the Rust store generate it;
   - reconciliation should map `LinkProposal.resolved_at` to `reviewed_at` when present, with an explicit fallback/error policy;
   - the TS type should either include `reviewedAt?: string` or omit the field entirely and document Rust ownership.

2. Critical: TypeScript durability result shape is not defined.

   Behavior 6 requires Gate B to track native durability (`native_edges_committed`, `native_edge_commit_mismatches`) at plan lines 781-794. The implementation steps say `zk_commit_link` returns optional metadata (`nativeEdgeCommitted`, `nativeReviewState`, `nativeEdgeType`) at lines 833-838. But `commitLink()` currently returns `LinkProposal | null` (`apps/silmari-mcp/src/lib/edges.ts:334`), and the plan does not define the new return type or where the metadata lives.

   Impact: TypeScript implementers can produce incompatible shapes, and Gate B tests may assert a shape that `zk_commit_link` does not actually return.

   Recommendation: add a concrete type, for example:

   ```ts
   type CommitLinkResult = LinkProposal & {
     nativeEdgeCommitted?: boolean;
     nativeReviewState?: "reviewed";
     nativeEdgeType?: EdgeType;
   };
   ```

   Also define legacy behavior explicitly: omit native fields, or set `nativeEdgeCommitted=false` with `nativeReviewState` absent. Then update `commitProposal()` to return a structured object instead of `boolean`.

3. Warning: Rust CLI output naming conflicts with current envelope conventions.

   The plan's `edge-commit` payload example uses snake_case fields (`source_id`, `target_id`, `edge_type`, `review_state`) at lines 147-154. Existing Rust command result structs generally serialize camelCase for structured outputs, such as `SchemaCheckOutput` and `MutationOutput` in `apps/silmari_memory_rust/src/cli.rs:289-305`, and traversal emits `sourceId`/`targetId`/`edgeType` through `EdgeStep` in `apps/silmari_memory_rust/src/edges.rs:41-49`.

   Impact: the command can still work, but the new TypeScript adapter will be a one-off shape parser and the CLI contract will drift.

   Recommendation: use camelCase for the result payload (`sourceId`, `targetId`, `edgeType`, `reviewState`) unless there is a deliberate reason to change the Rust CLI convention.

## Promise Review

### Well-Defined

- The plan correctly requires DB-level atomicity for `card_edges`, `card_labels`, and `card_events` at lines 100-102 and 350-355.
- The reconciliation promise to skip malformed JSONL lines nonfatally matches current MCP JSONL semantics. See plan lines 258-259 and current proposal validation in `apps/silmari-mcp/src/lib/edges.ts:281-309`.

### Missing or Unclear

1. Critical: cross-store retry behavior is not specified.

   `commitLink()` will necessarily update two stores: native SQLite and `link-proposals.jsonl`. Current code writes the edge, flushes, then rewrites the proposals file (`apps/silmari-mcp/src/lib/edges.ts:349-374`). The plan keeps proposal status update semantics at lines 571-573 but does not state what happens if native commit succeeds and the proposal-file rewrite fails.

   Impact: a retry can replay the same pending proposal. Without the duplicate semantics above, retry can duplicate events or overwrite evidence. With the wrong reconciliation policy, an edge may exist without a committed proposal record.

   Recommendation: document the intended retry contract:

   - native commit first;
   - proposal JSONL update second;
   - if JSONL update fails, retrying `zk_commit_link` must be safe because `edge-commit` returns `changed=false` and no duplicate event for the same proposal id;
   - reconciliation should treat already-present same-proposal rows as `already_present`, not failure.

2. Warning: timeout/cancellation behavior for new native commands is inherited but not named.

   Native adapter mutations currently use `TIMEOUT_WRITE` by default in `br-adapter.ts:84-95` and `execFileSync` timeout handling in `native-adapter.ts:300-359`. The plan adds potentially file-scanning reconciliation but does not state whether it uses write timeout, init timeout, or a new timeout.

   Impact: large historical proposal files may time out through the same narrow mutation path.

   Recommendation: name the timeout for `edge-reconcile-proposals` in the TS/Rust CLI plan if it will be called from TypeScript, or state that it is an operator CLI not used through `NativeCliAdapter`.

## Data Model Review

### Well-Defined

- The existing schema has the right columns for the intended native row: `review_state`, `created_at`, `created_by`, `evidence` (`apps/silmari_memory_rust/src/schema.rs:176-188`).
- The plan correctly preserves compatibility labels via `ref:<edge>:<target>` and uses the current export path that reads `card_edges`, not labels (`apps/silmari_memory_rust/src/export.rs:213-239`).

### Missing or Unclear

1. Critical: `evidence` JSON shape is not specified.

   Behavior 1 requires JSON `evidence` to be populated at plan line 287, and line 298 names invalid/non-JSON evidence construction as an edge case. The audit event payload is specified at lines 178-188, but the `card_edges.evidence` payload is not. Existing import code stores the full `AcceptedReviewEdge` JSON with camelCase fields (`apps/silmari_memory_rust/src/importer.rs:561-571`), which is a different shape from the proposed event payload.

   Impact: tests can only assert "some JSON exists", and future reconciliation/import/live commits may write incompatible audit data for the same reviewed edge.

   Recommendation: define one evidence schema and reuse it:

   ```json
   {
     "authority": "accepted-proposal",
     "proposalId": "prop-...",
     "reviewedBy": "operator",
     "reviewedAt": "2026-04-30T10:18:54Z",
     "reason": "accepted by operator",
     "sourceId": "zk-source",
     "targetId": "zk-target",
     "edgeType": "reinforces"
   }
   ```

   Then state whether `card_events.payload` is identical to this object or a documented projection.

2. Warning: low-level `insert_edge()` remains an unsafe/import primitive, but the plan overstates global enforcement.

   The plan correctly says not to change `insert_edge()` callers used by import fixtures at line 369. That means direct Rust code can still insert reviewed edge types with default `review_state='auto'` through `store::insert_edge()` (`apps/silmari_memory_rust/src/store.rs:62-74`) and legacy `import_beads_box_into_conn()` currently does this for parsed `ref:*` labels (`apps/silmari_memory_rust/src/importer.rs:245-254`). The plan also cites the data model rule that reviewed types cannot be inserted as `auto` at lines 52-53.

   Impact: if the plan says enforcement is global, tests will contradict it. If enforcement is intentionally only CLI/live-path, that boundary should be explicit.

   Recommendation: amend the plan to classify `insert_edge()` as an internal unsafe/import primitive, with authority enforcement guaranteed only by `store::add_edge()`, CLI `edge-add`, and `commit_accepted_edge()`. Add a follow-up if legacy `import_beads_box` should be brought under review policy too.

3. Warning: reconciliation proposal-field mapping is incomplete.

   The existing MCP proposal record uses `id`, `created_at`, `box`, `from_id`, `to_id`, `edge`, `rationale`, `proposed_by`, `status`, `resolved_at`, and `resolved_reason` (`apps/silmari-mcp/src/lib/edges.ts:216-228`). The reconciliation test helpers in the plan use informal `committed("lp-ok", ...)` records at lines 710-716 and say "evidence from the proposal record" at line 752, but do not map exact fields.

   Impact: implementers may count valid historical records as `invalid_shape`, or lose `resolved_reason` and `resolved_at` during evidence creation.

   Recommendation: add an explicit JSONL input contract:

   - committed iff `status === "committed"`;
   - source = `from_id`;
   - target = `to_id`;
   - type = `edge`;
   - proposal id = `id`;
   - reason = `resolved_reason ?? rationale`;
   - reviewed at = `resolved_at ?? created_at` or defined fallback;
   - malformed if any required field is missing or edge is not a reviewed type.

## API Review

### Well-Defined

- `edge-commit` rejects auto edge types, leaving `edge-add` as the auto API. See plan lines 172 and 458-464.
- `edge-reconcile-proposals` returns structured counters and nonfatal malformed-line behavior. See plan lines 232-259.

### Missing or Unclear

1. Warning: `edge-add` authority failure should have a stable error detail.

   Existing CLI errors map `EdgeValidation` into `VALIDATION_ERROR`, with unknown edge type detail support (`apps/silmari_memory_rust/src/cli.rs:776-793`). The plan says reviewed `edge-add` fails at lines 400-404 but does not define message/details.

   Recommendation: require a stable `VALIDATION_ERROR` with details such as `{ "edgeType": "reinforces", "authority": "accepted-proposal-required" }`, and test that no row was written.

2. Warning: `--box` wrong-box behavior should match existing `CARD_NOT_FOUND` semantics.

   Current CLI `require_card_in_box()` returns `CardNotFound` if the card exists in another box (`apps/silmari_memory_rust/src/cli.rs:721-727`). The plan says validate source/target cards in the same box at lines 348 and 751 but does not state whether wrong-box is `CARD_NOT_FOUND` or `VALIDATION_ERROR`.

   Recommendation: state that `edge-commit` follows existing `require_card_in_box()` behavior unless the plan intentionally introduces a new validation error.

## Critical Issues

1. Store transaction signature must be resolved before Behavior 1. The current plan's `&Connection` test shape is incompatible with `conn.transaction()` in rusqlite 0.37.
2. Idempotency must be specified before writing `edge.accepted` events. Duplicate proposal retries must return `changed=false` and avoid duplicate audit rows, or the plan's own tests will contradict the implementation.
3. The authority boundary must account for existing direct `reinforces` writers, especially body-hash recurrence in `card-ops.ts`.
4. Timestamp and evidence ownership must be concrete across CLI, TS, and reconciliation. The current command/type shapes do not agree.
5. Gate B durability metadata needs a concrete TypeScript result type and legacy-mode behavior.

## Suggested Plan Amendments

```diff
# Behavior 1 / Shared Contracts
+ Define `AcceptedEdgeCommitResult` with `changed`, `alreadyPresent`, `sourceId`, `targetId`, `edgeType`, `reviewState`.
+ Choose transaction API: `&mut Connection`, `unchecked_transaction()` with precondition, or a `Transaction` helper.
+ Define duplicate/conflict semantics before inserting `edge.accepted`.
+ Define `card_edges.evidence` JSON schema and whether `card_events.payload` reuses it.

# Rust CLI `edge-commit`
+ Either add `--reviewed-at` or state Rust generates `reviewedAt`.
+ Use current CLI result naming convention, preferably camelCase.
+ Add stable error details for reviewed `edge-add` without authority.

# TypeScript bridge
+ Define `CommitLinkResult = LinkProposal & { nativeEdgeCommitted?: boolean; nativeReviewState?: "reviewed"; nativeEdgeType?: EdgeType }`.
+ Change Gate B `commitProposal()` from boolean to structured commit telemetry.
+ State legacy behavior for native durability fields.

# Existing reviewed direct writers
+ Add an explicit decision for `emitReinforcesToPrior()` in native-primary.
+ If out of scope, document that this slice only makes accepted proposal commits native-durable.
+ If in scope, generalize accepted-edge commit authority to include body-hash recurrence.

# Reconciliation
+ Add exact `LinkProposal` JSONL field mapping.
+ Define `resolved_at`/`created_at` fallback policy for `reviewedAt`.
```

## Approval Status

- [ ] Ready for Implementation
- [ ] Needs Minor Revision
- [x] Needs Major Revision

The plan should be revised before implementation begins. The core architecture is right, but the missing contracts above are on the implementation path and will otherwise turn into compile failures, inconsistent audit rows, or false-green native durability reports.
