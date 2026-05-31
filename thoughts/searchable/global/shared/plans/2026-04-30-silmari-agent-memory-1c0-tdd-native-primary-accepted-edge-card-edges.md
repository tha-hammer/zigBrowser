---
date: 2026-04-30T10:18:54-04:00
planner: CobaltRiver
git_commit: 57f4a6514d29f2f62c90dd32d11c30ad344e2eb0
branch: main
repository: silmari-agent-memory
topic: native-primary accepted edge commits write card_edges
type: tdd_plan
status: implemented_closed
related_beads:
  - silmari-agent-memory-1c0
  - silmari-agent-memory-qwy
  - silmari-agent-memory-i3d
  - silmari-agent-memory-29h
  - silmari-agent-memory-1c0.6
  - silmari-agent-memory-1c0.6.1
  - silmari-agent-memory-iaa
related_research:
  - thoughts/searchable/shared/research/2026-04-30-native-primary-live-edge-commit-card-edges-solution.md
related_reviews:
  - thoughts/searchable/shared/plans/2026-04-30-silmari-agent-memory-1c0-tdd-native-primary-accepted-edge-card-edges-REVIEW.md
related_specs:
  - specs/processing-pipeline.md
  - artifacts/specs/2026-04-28-beads-rust-replacement/01-system-architecture.md
  - artifacts/specs/2026-04-28-beads-rust-replacement/02-native-data-model.md
  - artifacts/specs/2026-04-28-beads-rust-replacement/03-store-api-and-adapter.md
  - artifacts/specs/2026-04-28-beads-rust-replacement/04-migration-cutover-and-verification.md
  - artifacts/specs/2026-04-28-beads-rust-replacement/05-viewer-export-and-consumers.md
related_context:
  - thoughts/searchable/shared/plans/2026-04-28-silmari-agent-memory-dbh-tdd-card-native-beads-rust-replacement.md
  - thoughts/searchable/shared/plans/2026-04-29-cross-llm-sai-persistence-and-user-context-routing.md
last_updated: 2026-04-30
last_updated_by: VioletBeacon
implementation_commits:
  - c20ceab Add native create body-hash recurrence
  - e4effb4 Map native create recurrence metadata
review_resolution:
  reviewer: BrownIsland
  review_basis_commit: 803e556
  tracking_bead: silmari-agent-memory-29h
---

# Native-Primary Accepted Edge `card_edges` TDD Implementation Plan

## Overview

This plan fixes the source-of-truth mismatch where live native-primary MCP edge
commits report success but persist only `ref:<edge>:<target>` labels, while Rust
native traversal and viewer export read `card_edges`.

The target behavior is simple to observe: after a reviewed proposal is committed
through `zk_commit_link` in native-primary mode, the native SQLite database must
contain the reviewed `card_edges` row, the projected compatibility label, and an
audit event. Rust viewer export should then emit the edge because the native
source DB is correct, not because export or the browser synthesized edges from
labels.

## Implementation Status (2026-04-30)

This plan is implemented and closed. The Rust recurrence slice landed in
`c20ceab` and the TypeScript native-primary metadata mapping landed in
`e4effb4`. Parent bead `silmari-agent-memory-1c0.6` and child bead
`silmari-agent-memory-1c0.6.1` are closed.

Final verification included the full Rust crate suite, focused MCP native
adapter/CLI/dispatch/facade tests, save-card parity, batch recurrence, runtime
mode routing, edge proposal tests, Gate B ingest/aggregate tests, MCP
typecheck, and a manual native CLI SQL inspection confirming body-hash evidence
contains `contentHash` and no `proposalId`.

## Current State Analysis

### Key Discoveries

- `zk_commit_link` dispatches to `commitLink()` in `apps/silmari-mcp/src/index.ts:669-674`.
- `commitLink()` calls `addEdge(..., { flush: false })`, flushes, then marks the proposal committed in `apps/silmari-mcp/src/lib/edges.ts:334-374`.
- `addEdge()` builds a `ref:<edge>:<target>` label and calls `brLabelAdd()`; only `blocks` is mirrored through `brDepAdd()` in `apps/silmari-mcp/src/lib/edges.ts:79-117`.
- In native-primary mode, `brLabelAdd()` routes to Rust `label-add` through `NativeCliAdapter.labelAddCompat()` in `apps/silmari-mcp/src/lib/br-adapter.ts:405-413` and `apps/silmari-mcp/src/lib/native-adapter.ts:232-240`.
- Rust `label-add` calls `store::add_label()` only; it inserts into `card_labels` and does not project `ref:*` labels into `card_edges` in `apps/silmari_memory_rust/src/cli.rs:486-505` and `apps/silmari_memory_rust/src/store.rs:76-89`.
- Rust already has `card_edges` with all 12 Silmari edge types, `review_state`, `created_by`, and `evidence` in `apps/silmari_memory_rust/src/schema.rs:176-188`.
- Rust `edge-add` exists, but it inserts only `(source_id,target_id,edge_type)`, so reviewed edges default to `review_state='auto'` through `apps/silmari_memory_rust/src/store.rs:62-74` and `apps/silmari_memory_rust/src/cli.rs:507-521`.
- The native data model says accepted proposals insert `card_edges(review_state='reviewed')` in `artifacts/specs/2026-04-28-beads-rust-replacement/02-native-data-model.md:201-217`.
- The same model says reviewed edge types cannot be inserted with `review_state='auto'` in `artifacts/specs/2026-04-28-beads-rust-replacement/02-native-data-model.md:306-315`.
- Rust import already has the authority pattern: accepted reviewed refs update `card_edges` to `review_state='reviewed'`, while unaccepted reviewed refs become pending `edge_proposals`, in `apps/silmari_memory_rust/src/importer.rs:522-592`.
- Rust viewer compatibility export reads native `card_edges` and writes compatibility `card_edges(source,target,type)` in `apps/silmari_memory_rust/src/export.rs:213-239`.
- Gate B `edges_committed` currently means `zk_propose_link` plus `zk_commit_link` returned OK; it is not a native `card_edges` durability assertion. See `scripts/kc-baker-pipeline-v2/ingest/ingest-cascade.ts:1080-1100` and `scripts/kc-baker-pipeline-v2/ingest/ingest-cascade.ts:1473-1507`.
- Body-hash recurrence currently writes a reviewed `reinforces` edge directly through the TypeScript `emitReinforcesToPrior()` legacy post-save helper in `apps/silmari-mcp/src/lib/card-ops.ts:271-286` and calls it from save post-processing in `apps/silmari-mcp/src/lib/card-ops.ts:591-606`. Native-primary must not route recurrence through that helper. Rust `create_card` owns duplicate full-body-hash detection and must commit the recurrence edge through the same authorized reviewed-edge store helper inside the native create transaction.
- `store::insert_edge()` remains an internal low-level/import primitive in `apps/silmari_memory_rust/src/store.rs:62-74`; authority enforcement belongs at `store::add_edge()`, CLI commands, and the new authorized reviewed-edge helper, not by silently changing every import fixture caller.

## Plan Decisions

1. The canonical fix is the live native write path, not Rust viewer export.
   Native `card_edges` is the semantic graph; labels are compatibility
   projection.
2. Add a new Rust command/API named `edge-commit` for authorized reviewed
   edges. Its primary public caller is accepted proposal commits. Body-hash
   recurrence uses the same Rust reviewed-edge store helper as an explicit
   authority from `create_card`, not a TypeScript post-save command call. Do not
   stretch legacy `brDepAdd()`/`DepType` into the semantic edge facade.
3. `edge-commit` writes `card_edges`, projected `card_labels`, and a
   `card_events` audit row in one Rust transaction. The public store API takes
   `&mut Connection` so `rusqlite::Connection::transaction()` can enforce
   atomicity.
4. `edge-add` remains the direct/auto edge command. As part of this plan,
   `edge-add --type <reviewed>` without accepted authority must fail rather
   than inserting a reviewed edge as `auto`.
5. TypeScript `commitLink()` is the accepted-proposal decision point. In
   native-primary mode it calls the new authorized reviewed-edge facade; in
   legacy mode it keeps the existing label-only path.
6. Body-hash recurrence remains a required native-durable reviewed-edge
   behavior, and its implementation boundary is now decided: native-primary
   recurrence belongs wholly inside Rust/native create semantics. Do not route
   native-primary recurrence through TypeScript `runPostSaveSteps()` /
   `emitReinforcesToPrior()` and do not add a narrow TypeScript post-create
   bridge. Legacy and shadow-legacy modes keep the existing TypeScript helper.
7. Reconciliation/backfill repairs native source DBs from committed
   `link-proposals.jsonl`, not from exported viewer caches.
8. Export tests are proof that fixed native data is visible downstream. They are
   not the repair mechanism.
9. `silmari-agent-memory-i3d` owns full current-viewer compatibility coverage.
   This plan asserts Rust cache tables and selected current viewer SQL only
   where needed to prove the source fix did not disappear at export.
10. Duplicate commits are defined before implementation: the same
    source/target/type and same authority key returns `changed=false` and does
    not update edge evidence or insert another `edge.accepted` event; a
    different authority key for an existing reviewed row returns a validation
    conflict.
11. `reviewedAt` is Rust-owned for live writes unless the caller supplies it.
    Reconciliation supplies `reviewedAt` from `resolved_at ?? created_at`.
12. CLI and TypeScript result payloads use camelCase to match current native
    envelope conventions.

## Desired End State

After implementation:

- A committed reviewed MCP proposal in native-primary creates exactly one
  native `card_edges` row with `review_state='reviewed'`.
- The source card still has the compatibility label
  `ref:<edge>:<target>`.
- The write is transactional: no label-only success and no edge-only success.
- Duplicate accepted commits are idempotent.
- Existing reviewed rows with the same authority key are treated as
  already-present; existing reviewed rows with a different authority key are
  validation conflicts.
- Existing `auto` rows for reviewed edge types are corrupt legacy state; an
  authorized commit may promote the matching row to `reviewed` and report
  `changed=true, promoted=true`.
- Body-hash recurrence `reinforces` writes are native-durable because Rust
  `create_card` commits them during the native create transaction.
- Invalid endpoints, unknown edge types, and reviewed `edge-add` without
  accepted authority fail before mutating state.
- Rust compat export and card-native export read the committed native row.
- Existing native-primary stores can be repaired from committed proposal logs.
- Gate B reports or tests can distinguish tool-call success from native edge
  durability.

### Observable Behaviors

1. Given source/target cards and an accepted reviewed edge, when Rust
   `edge-commit` runs, then native `card_edges`, `card_labels`, and
   `card_events` are updated atomically.
2. Given a reviewed edge without accepted authority, when Rust `edge-add` runs,
   then it fails without writing an `auto` reviewed row.
3. Given native-primary mode and a pending proposal, when `zk_commit_link`
   commits it, then the native DB contains the reviewed edge and projected
   label.
4. Given native-primary mode and a body-hash recurrence, when Rust `create_card`
   detects the duplicate full-body hash, then the native DB contains a reviewed
   `body-hash-recurrence` edge and projected label from the same create
   transaction.
5. Given a committed native edge, when Rust viewer export runs, then compat and
   native export contain the edge from `card_edges`.
6. Given old committed proposal logs, when reconciliation runs, then native
   `card_edges` is backfilled idempotently and invalid records are reported.
7. Given Gate B commits in native-primary mode, when ingest reports committed
   edges, then report/test assertions are backed by native edge rows.

## What We're NOT Doing

- We are not making Rust export synthesize authoritative edges from labels.
- We are not relying on the Bun viewer server's cache-side
  `synthesizeEdgesFromLabels()` workaround for acceptance.
- We are not broadening Beads `DepType` to include Silmari semantic edges.
- We are not changing legacy Beads label storage behavior except through the
  existing compatibility path.
- We are not running the full 15-transcript pipeline as a unit test. Full-run
  validation can follow once the focused source and export contracts pass.

## Shared Contracts

### Rust `edge-commit` Command

Add a native command for authorized reviewed edges with this testable shape:

```text
silmari_memory_rust edge-commit \
  --db <native.sqlite> \
  --box idea \
  --source <source-id> \
  --target <target-id> \
  --type <reviewed-edge-type> \
  --authority accepted-proposal \
  --proposal-id <proposal-id> \
  --reviewed-by <actor> \
  --reviewed-at <optional-rfc3339> \
  --reason <optional-reason> \
  --json
```

For `--authority accepted-proposal`, `--proposal-id` is required. For
`--authority body-hash-recurrence`, `--content-hash` is required and
`--proposal-id` is omitted. If `--reviewed-at` is omitted, Rust generates the
timestamp once and reuses it for `card_edges.created_at`,
`card_edges.evidence.reviewedAt`, and `card_events.created_at`.

Native-primary body-hash recurrence must not shell out from TypeScript to
`edge-commit`. Rust `create_card` may call the same internal
`commit_reviewed_edge(&mut Connection, ReviewedEdgeCommit)` helper directly
inside the create transaction.

The JSON envelope payload should include:

```json
{
  "changed": true,
  "alreadyPresent": false,
  "promoted": false,
  "sourceId": "zk-source",
  "targetId": "zk-target",
  "edgeType": "reinforces",
  "reviewState": "reviewed",
  "authority": "accepted-proposal"
}
```

The Rust store input should be a typed struct, not ad hoc CLI strings:

```rust
pub enum EdgeWriteAuthority {
    AcceptedProposal { proposal_id: String },
    BodyHashRecurrence { content_hash: String },
}

pub struct ReviewedEdgeCommit {
    pub card_box: CardBox,
    pub source_id: String,
    pub target_id: String,
    pub edge_type: EdgeType,
    pub authority: EdgeWriteAuthority,
    pub reviewed_by: String,
    pub reviewed_at: Option<String>,
    pub reason: Option<String>,
}

pub struct ReviewedEdgeCommitResult {
    pub changed: bool,
    pub already_present: bool,
    pub promoted: bool,
    pub source_id: String,
    pub target_id: String,
    pub edge_type: EdgeType,
    pub review_state: &'static str,
    pub authority: EdgeWriteAuthority,
}
```

The public store API is:

```rust
pub fn commit_reviewed_edge(
    conn: &mut Connection,
    input: ReviewedEdgeCommit,
) -> crate::Result<ReviewedEdgeCommitResult>
```

It takes `&mut Connection` explicitly so the implementation can use
`conn.transaction()` under `rusqlite 0.37`. A private helper may take
`&Transaction<'_>` if implementation wants to share logic, but tests and CLI
should call the public `&mut Connection` wrapper.

`edge-commit` must reject auto edge types. Auto edges stay on `edge-add`.
`store::insert_edge()` remains an internal unsafe/import primitive; global
authority enforcement is guaranteed only through `store::add_edge()`, CLI
commands, and `commit_reviewed_edge()`.

### Duplicate and Conflict Semantics

For `(source_id,target_id,edge_type)`:

- No row exists: insert reviewed edge, projected label, and one
  `edge.accepted` event. Return `changed=true, alreadyPresent=false`.
- Existing reviewed row has the same authority key:
  return `changed=false, alreadyPresent=true`; do not update `created_at`,
  `created_by`, `evidence`, or insert another event.
- Existing reviewed row has a different authority key:
  return `VALIDATION_ERROR` with details
  `{ "reason": "edge-already-reviewed", "sourceId": "...", "targetId": "...", "edgeType": "..." }`.
- Existing row has `review_state='auto'` for a reviewed edge type:
  treat it as corrupt legacy state. An authorized commit may promote it to
  reviewed, write evidence, write one event, and return
  `changed=true, promoted=true`.
- Duplicate projected labels remain idempotent through the
  `(card_id,label)` primary key.

This retry contract is intentional: `commitLink()` writes native SQLite first
and rewrites `link-proposals.jsonl` second. If the JSONL rewrite fails, retrying
the same pending proposal must be safe and must not duplicate events.

### Evidence and Audit Event

Use one evidence JSON object for both `card_edges.evidence` and
`card_events.payload`.

Evidence schema:

```json
{
  "authority": "accepted-proposal",
  "proposalId": "lp-test",
  "reviewedBy": "operator",
  "reviewedAt": "2026-04-30T10:18:54Z",
  "reason": "accepted by operator",
  "sourceId": "zk-source",
  "targetId": "zk-target",
  "edgeType": "reinforces"
}
```

For body-hash recurrence, use:

```json
{
  "authority": "body-hash-recurrence",
  "contentHash": "<full-sha256>",
  "reviewedBy": "silmari-mcp",
  "reviewedAt": "2026-04-30T10:18:54Z",
  "reason": "body hash recurrence",
  "sourceId": "zk-new",
  "targetId": "zk-prior",
  "edgeType": "reinforces"
}
```

Use event type `edge.accepted` for all authorized reviewed-edge commits.

The event row should set:

- `card_id`: source card ID
- `event_type`: `edge.accepted`
- `actor`: `reviewedBy`
- `payload`: the evidence JSON object above
- `created_at`: the same timestamp used for the edge write

### TypeScript Native Facade

Add a native-primary facade path that is semantic-edge aware:

- `apps/silmari-mcp/src/lib/native-adapter.ts`: `edgeCommitCompat(input)`.
- `apps/silmari-mcp/src/lib/br-adapter.ts`: `brCommitReviewedEdge(input)`.
- `apps/silmari-mcp/src/lib/edges.ts`: `commitLink()` calls
  `brCommitReviewedEdge()` in native-primary and existing `addEdge()` in legacy
  mode.
- `apps/silmari-mcp/src/lib/card-ops.ts`: native-primary save paths call native
  create and map Rust recurrence metadata into the existing `SaveCardResult`
  shape. They must not call `brCommitReviewedEdge()`,
  `runPostSaveSteps()`, or `emitReinforcesToPrior()` for body-hash recurrence.

The TypeScript input should carry the proposal fields already available in
`commitLink()`:

```ts
type ReviewedEdgeCommitInput =
  {
    box: Box;
    source: string;
    target: string;
    edgeType: EdgeType;
    authority: 'accepted-proposal';
    proposalId: string;
    reviewedBy: string;
    reviewedAt?: string;
    reason?: string;
  };
```

`commitLink()` should return a concrete result type:

```ts
type CommitLinkResult = LinkProposal & {
  nativeEdgeCommitted?: boolean;
  nativeEdgeAlreadyPresent?: boolean;
  nativeEdgePromoted?: boolean;
  nativeReviewState?: 'reviewed';
  nativeEdgeType?: EdgeType;
};
```

Legacy mode omits all `native*` fields. Native-primary mode sets
`nativeEdgeCommitted` to `true` for `changed=true`, and sets
`nativeEdgeAlreadyPresent=true` when the same proposal was already applied.

Gate B `commitProposal()` must return a structured result instead of `boolean`:

```ts
type GateBCommitResult = {
  ok: boolean;
  edge: EdgeType;
  nativeEdgeCommitted?: boolean;
  nativeEdgeAlreadyPresent?: boolean;
  nativeEdgePromoted?: boolean;
  nativeEdgeMismatch?: boolean;
};
```

`nativeEdgeMismatch` is true in native-primary mode when `zk_commit_link`
succeeds without native durability metadata or when it reports no changed or
already-present native edge.

`reviewedBy` should resolve as:

1. `process.env.SILMARI_ACTOR`
2. `process.env.USER`
3. `"silmari-mcp"`

### Reconciliation Command

Add a Rust operator command named `edge-reconcile-proposals`:

```text
silmari_memory_rust edge-reconcile-proposals \
  --db <native.sqlite> \
  --box idea \
  --proposals-file <link-proposals.jsonl> \
  --reviewed-by edge-reconcile \
  --json
```

This is an operator CLI, not a hot-path `NativeCliAdapter` call. If later wired
through TypeScript, it should use a dedicated long timeout such as
`SILMARI_NATIVE_RECONCILE_TIMEOUT_MS`, not the normal write timeout.

It reads committed proposals, validates endpoint cards, writes reviewed
`card_edges` plus projected labels through the same transaction helper as
`edge-commit`, and returns counts:

```json
{
  "applied": 2,
  "alreadyPresent": 1,
  "skippedPending": 3,
  "skippedRejected": 1,
  "invalidShape": 1,
  "missingEndpoint": 1
}
```

Malformed JSONL lines are nonfatal and counted, matching current MCP JSONL skip
semantics.

Exact proposal-field mapping:

- committed iff `status === "committed"`;
- source = `from_id`;
- target = `to_id`;
- type = `edge`;
- proposal id = `id`;
- reason = `resolved_reason ?? rationale`;
- reviewed at = `resolved_at ?? created_at`;
- actor = CLI `--reviewed-by`;
- malformed if any required field is missing or the edge is not reviewed.

Pending and rejected proposals never become live edges. The CLI reports them as
`skippedPending` and `skippedRejected`. Missing endpoint cards are reported as
`missingEndpoint` and do not create labels, edges, or events.

### Stable Error Contracts

- `edge-add --type <reviewed>` without authority returns `VALIDATION_ERROR`
  with details `{ "edgeType": "<type>", "authority": "accepted-proposal-required" }`.
- `edge-commit` wrong-box source or target follows existing
  `require_card_in_box()` semantics and returns `CARD_NOT_FOUND`.
- `edge-commit` unknown edge types follow existing `EdgeValidation` mapping.

## Testing Strategy

- **Rust framework**: `cargo test` with focused integration tests under
  `apps/silmari_memory_rust/tests`.
- **TypeScript framework**: Bun tests under `apps/silmari-mcp/tests` and
  `scripts/kc-baker-pipeline-v2/tests`.
- **Database assertions**: direct SQLite queries through Rust `rusqlite` or
  Bun `bun:sqlite`.
- **Mocking/setup**: use existing native DB test helpers and native-primary MCP
  harnesses. Do not mock the Rust command when proving persistence.
- **Order**: Rust transaction first, Rust CLI second, TypeScript accepted-link
  bridge third, Rust/native create body-hash recurrence fourth, export proof
  fifth, reconciliation sixth, Gate B durability reporting last.

## Behavior 1: Rust Authorized Reviewed Edge Transaction

### Test Specification

**Given**: a native DB with source and target cards in the same box.

**When**: a reviewed edge is committed with accepted proposal metadata through
`store::commit_reviewed_edge(&mut conn, ...)`.

**Then**:

- `card_edges` contains exactly one row for `(source,target,edge_type)`.
- `review_state='reviewed'`.
- `created_at`, `created_by`, and JSON `evidence` are populated.
- `card_labels` contains `ref:<edge>:<target>` on the source card.
- `card_events` contains one `edge.accepted` event.
- Repeating the same commit is idempotent.

**Edge Cases**:

- missing source card
- missing target card
- auto edge passed to `edge-commit`
- duplicate accepted commit with same proposal id
- duplicate reviewed commit with a different authority key
- existing corrupt auto row for a reviewed type promoted to reviewed
- invalid/non-JSON evidence payload construction

### TDD Cycle

#### Red: Write Failing Test

**File**: `apps/silmari_memory_rust/tests/accepted_edges.rs`

```rust
#[test]
fn accepted_reviewed_edge_writes_edge_label_and_event_atomically() {
    let (_dir, mut conn) = common::native_db();
    seed_two_cards(&conn, "zk-source", "zk-target");

    let result = silmari_memory_rust::store::commit_reviewed_edge(
        &mut conn,
        ReviewedEdgeCommit {
            card_box: CardBox::Idea,
            source_id: "zk-source".into(),
            target_id: "zk-target".into(),
            edge_type: EdgeType::Reinforces,
            authority: EdgeWriteAuthority::AcceptedProposal {
                proposal_id: "lp-test".into(),
            },
            reviewed_by: "test-operator".into(),
            reviewed_at: Some("2026-04-30T10:18:54Z".into()),
            reason: Some("accepted by test".into()),
        },
    )
    .unwrap();

    assert!(result.changed);
    assert!(!result.already_present);
    assert!(!result.promoted);
    assert_eq!(count_reviewed_edge(&conn, "zk-source", "zk-target", "reinforces"), 1);
    assert_eq!(count_label(&conn, "zk-source", "ref:reinforces:zk-target"), 1);
    assert_eq!(count_event(&conn, "zk-source", "edge.accepted"), 1);

    let duplicate = commit_same_reviewed_edge(&mut conn, "lp-test").unwrap();
    assert!(!duplicate.changed);
    assert!(duplicate.already_present);
    assert_eq!(count_event(&conn, "zk-source", "edge.accepted"), 1);
}
```

Expected red failure: no `ReviewedEdgeCommit`, `EdgeWriteAuthority`, or
`store::commit_reviewed_edge(&mut Connection, ...)` API exists.

#### Green: Minimal Implementation

**Files**:

- `apps/silmari_memory_rust/src/model.rs`
- `apps/silmari_memory_rust/src/store.rs`

Implementation steps:

- Add `EdgeWriteAuthority`, `ReviewedEdgeCommit`, and
  `ReviewedEdgeCommitResult`.
- Add `store::commit_reviewed_edge(&mut Connection, ReviewedEdgeCommit)`.
- Validate source/target card existence and same box.
- Reject `!edge_type.requires_review()`.
- Start a transaction.
- Generate one `reviewedAt` timestamp if the caller omitted it.
- Insert `card_edges` with `review_state='reviewed'`, `created_at`,
  `created_by`, and evidence.
- Treat same-authority duplicates as unchanged/already-present.
- Treat different-authority duplicates as validation conflicts.
- Promote an existing auto row for a reviewed type as corrupt legacy state.
- Insert `ref:<edge>:<target>` into `card_labels`.
- Insert exactly one `edge.accepted` into `card_events` only when the native
  row changed.
- Commit transaction.

#### Refactor

**Files**:

- `apps/silmari_memory_rust/src/store.rs`
- optionally `apps/silmari_memory_rust/src/events.rs`

Refactor targets:

- Extract event insert helper.
- Extract ref label construction/parsing reuse.
- Keep transaction helper reusable by CLI and reconciliation.
- Avoid changing `insert_edge()` callers used by import fixtures.

### Success Criteria

**Automated**:

- [x] Red fails for missing API or missing rows:
  `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml --test accepted_edges accepted_reviewed_edge_writes_edge_label_and_event_atomically`
- [x] Green passes:
  `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml --test accepted_edges`
- [x] Existing import tests still pass:
  `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml --test import_snapshot_cli_contract`

**Manual**:

- [x] Inspect evidence JSON shape once in SQLite.
- [x] Confirm duplicate commits do not create duplicate labels, edges, or events.

---

## Behavior 2: Rust CLI Enforces Reviewed Edge Authority

### Test Specification

**Given**: a native DB with source and target cards.

**When**: `edge-commit --type reinforces` runs with proposal metadata.

**Then**: it returns JSON success and writes a reviewed edge, projected label,
and event.

**Given**: the same DB.

**When**: `edge-add --type reinforces` runs without accepted authority.

**Then**: it fails and writes no reviewed edge row.

**Given**: `edge-add --type blocks`.

**When**: the command runs.

**Then**: it still succeeds with `review_state='auto'`.

### TDD Cycle

#### Red: Write Failing Test

**File**: `apps/silmari_memory_rust/tests/adapter_cli_contract.rs`

Add tests near the existing `edge-add` contract:

```rust
#[test]
fn edge_commit_cli_persists_reviewed_edge_and_projection() {
    let (_dir, db_path) = native_db_path_with_two_cards();

    Command::cargo_bin("silmari_memory_rust")
        .unwrap()
        .args([
            "edge-commit",
            "--db", db_path.to_str().unwrap(),
            "--box", "idea",
            "--source", "zk-source",
            "--target", "zk-target",
            "--type", "reinforces",
            "--authority", "accepted-proposal",
            "--proposal-id", "lp-test",
            "--reviewed-by", "test-operator",
            "--reason", "accepted by test",
            "--json",
        ])
        .assert()
        .success()
        .stdout(predicates::str::contains("\"alreadyPresent\":false"))
        .stdout(predicates::str::contains("\"reviewState\":\"reviewed\""));

    assert_reviewed_edge_and_label(&db_path);
}
```

Expected red failure: CLI subcommand does not exist.

#### Green: Minimal Implementation

**Files**:

- `apps/silmari_memory_rust/src/cli.rs`
- `apps/silmari_memory_rust/src/store.rs`
- `apps/silmari_memory_rust/src/model.rs`

Implementation steps:

- Add `Command::EdgeCommit`.
- Parse box/source/target/type/authority/proposal-id/content-hash/
  reviewed-by/reviewed-at/reason.
- Reject auto edge types.
- Require `proposal-id` for `accepted-proposal`.
- Require `content-hash` for `body-hash-recurrence`.
- Call `store::commit_reviewed_edge(&mut conn, input)`.
- Return standard JSON mutation output plus camelCase edge metadata.
- Update `Command::EdgeAdd` so reviewed types fail without accepted authority
  with `VALIDATION_ERROR` details
  `{ "edgeType": "<type>", "authority": "accepted-proposal-required" }`.
- Preserve wrong-box source/target behavior by reusing
  `require_card_in_box()`, which returns `CARD_NOT_FOUND`.

#### Refactor

- Share source/target/box validation between `edge-add` and `edge-commit`.
- Keep `edge-add` as the direct auto edge API.
- Keep CLI error envelopes stable with existing contract tests.

### Success Criteria

**Automated**:

- [x] Red fails for missing `edge-commit`:
  `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml --test adapter_cli_contract edge_commit_cli_persists_reviewed_edge_and_projection`
- [x] Reviewed `edge-add` rejection passes:
  `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml --test adapter_cli_contract reviewed_edge_add_without_authority_is_rejected`
- [x] Wrong-box source or target preserves `CARD_NOT_FOUND`:
  `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml --test adapter_cli_contract edge_commit_wrong_box_returns_card_not_found`
- [x] Existing blocks path still passes:
  `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml --test adapter_cli_contract`

**Manual**:

- [x] Run CLI once against a temp DB and inspect `card_edges`, `card_labels`,
  and `card_events`.

---

## Behavior 3: native-primary `zk_commit_link` Writes Native `card_edges`

### Test Specification

**Given**: native-primary mode, two saved cards, and a pending reviewed proposal.

**When**: `zk_commit_link` commits the proposal.

**Then**:

- the proposal status becomes `committed`;
- the source card has `ref:<edge>:<target>`;
- native `card_edges` contains the reviewed edge;
- the row is not `review_state='auto'`;
- no legacy Beads DB is written;
- native command log includes `edge-commit`.

### TDD Cycle

#### Red: Write Failing Test

**File**: `apps/silmari-mcp/tests/native-mcp-dispatch-contract.test.ts`

```ts
it('commits reviewed proposals into native card_edges in native-primary mode', async () => {
  const harness = createNativePrimaryHarness();
  const { dispatchTool } = await import('../src/index.js');

  const source = payload<{ id: string }>(await dispatchTool('zk_save_card', {
    box: 'idea',
    body: 'Native reviewed source memory',
    kind: 'idea',
    trunk: 5,
    mode: 'root',
    allowOrphan: true,
  }));
  const target = payload<{ id: string }>(await dispatchTool('zk_save_card', {
    box: 'idea',
    body: 'Native reviewed target memory',
    kind: 'idea',
    trunk: 5,
    mode: 'root',
    allowOrphan: true,
  }));

  const proposal = payload<{ id: string; status: string }>(await dispatchTool('zk_propose_link', {
    box: 'idea',
    fromId: source.id,
    toId: target.id,
    edge: 'reinforces',
    rationale: 'operator-reviewed test edge',
  }));

  const committed = payload<CommitLinkResult>(await dispatchTool('zk_commit_link', {
    proposalId: proposal.id,
    reason: 'accepted by test',
  }));

  expect(committed.status).toBe('committed');
  expect(committed.nativeEdgeCommitted).toBe(true);
  expect(committed.nativeReviewState).toBe('reviewed');
  expect(committed.nativeEdgeType).toBe('reinforces');
  assertNativeReviewedEdge(harness.nativeDbPath, source.id, target.id, 'reinforces');
  expect(readLines(harness.nativeLog).some((line) => line.startsWith('edge-commit '))).toBe(true);
  expect(readLines(harness.legacyBrLog)).toEqual([]);
});
```

Expected red failure: `card_edges` count is zero and no `edge-commit` command is
logged.

#### Green: Minimal Implementation

**Files**:

- `apps/silmari-mcp/src/lib/native-adapter.ts`
- `apps/silmari-mcp/src/lib/br-adapter.ts`
- `apps/silmari-mcp/src/lib/edges.ts`
- `apps/silmari-mcp/tests/native-mcp-dispatch-contract.test.ts`

Implementation steps:

- Expose `nativeDbPath` from the test harness.
- Add `NativeCliAdapter.edgeCommitCompat()`.
- Add `brCommitReviewedEdge()` facade that routes only in native-primary.
- In `commitLink()`, call `brCommitReviewedEdge()` for native-primary reviewed
  proposals. Legacy mode keeps existing `addEdge()` behavior.
- Run native SQLite commit before rewriting `link-proposals.jsonl`.
- Preserve proposal status update semantics. If JSONL rewrite fails after the
  native commit, retry is safe because same-authority duplicate native commits
  return `alreadyPresent=true` and do not duplicate events.
- Preserve `zk_commit_link` output shape, adding optional `native*` durability
  fields only in native-primary mode.

#### Refactor

- Keep all mode detection inside `br-adapter.ts`.
- Keep Rust command argument assembly inside `native-adapter.ts`.
- Avoid importing native adapter directly into `edges.ts` or `index.ts`.

### Success Criteria

**Automated**:

- [x] Red fails for zero native row / missing native bridge:
  `bun test apps/silmari-mcp/tests/native-mcp-dispatch-contract.test.ts`
- [x] Green passes:
  `bun test apps/silmari-mcp/tests/native-mcp-dispatch-contract.test.ts`
- [x] Existing edge proposal tests still pass:
  `bun test apps/silmari-mcp/tests/edges.test.ts`
- [x] Typecheck passes:
  `bun run --cwd apps/silmari-mcp typecheck`

**Manual**:

- [x] Confirm `link-proposals.jsonl` still records `status:"committed"` and
  `resolved_reason`.

---

## Behavior 4: Body-Hash Recurrence Writes Native Reviewed Edge

**Status**: implemented and closed. Rust `create_card` owns this behavior in
commit `c20ceab`; TypeScript maps the native create result in commit `e4effb4`.
The revised DBH plan rejects a native-primary TypeScript post-save bridge.
In native-primary mode, `zk_save_card` / `saveCard` call Rust `create-card`;
Rust `create_card` detects the duplicate full-body hash and commits the
`reinforces` edge through the internal reviewed-edge helper in the same create
transaction. The existing `runPostSaveSteps()` / `emitReinforcesToPrior()` path
remains legacy/shadow-legacy only.

### Test Specification

**Given**: native-primary mode and an existing native card with a full-body hash.

**When**: `zk_save_card` saves a second card whose body has the same full hash
and Rust `create_card` handles the native create transaction.

**Then**:

- native `card_edges` contains a reviewed `reinforces` row from the new card to
  the prior card;
- `card_labels` contains `ref:reinforces:<prior-id>` on the new card;
- `card_events` contains one `edge.accepted` event;
- evidence has `authority:"body-hash-recurrence"` and `contentHash` equal to
  the full-body hash used by native create;
- consolidation labels are applied consistently with legacy behavior;
- the native create response exposes enough recurrence metadata for
  `SaveCardResult.wasReinforced` and related compatibility fields;
- no proposal record is required;
- TypeScript does not issue an external `edge-commit` / `brCommitReviewedEdge`
  call for recurrence.

### TDD Cycle

#### Red: Write Failing Test

**Files**:

- `apps/silmari_memory_rust/tests/store_create.rs`
- `apps/silmari-mcp/tests/card-ops.test.ts`

Add a Rust native-create test first:

```rust
#[test]
fn create_card_duplicate_body_commits_body_hash_recurrence_edge() {
    let harness = NativeHarness::new();

    let first = harness.create_idea_card("Repeated body hash memory");
    let second = harness.create_idea_card("Repeated body hash memory");

    assert_reviewed_edge(
        &harness.conn,
        &second.id,
        &first.id,
        EdgeType::Reinforces,
        EdgeWriteAuthority::BodyHashRecurrence {
            content_hash: first.full_hash.clone(),
        },
    );
    assert_event(&harness.conn, &second.id, "edge.accepted");
    assert_label(&harness.conn, &second.id, &format!("ref:reinforces:{}", first.id));
    assert!(second.was_reinforced);
}
```

Then add a native-primary MCP integration test proving `saveCard()` gets the
same durable native row through `create-card`, without an external
`edge-commit` command for recurrence:

```ts
it('persists body-hash recurrence through native create', async () => {
  const harness = createNativePrimaryHarness();

  const first = await saveNativeCard(harness, {
    box: 'idea',
    body: 'Repeated body hash memory',
    kind: 'idea',
    trunk: 5,
    allowOrphan: true,
  });
  const second = await saveNativeCard(harness, {
    box: 'idea',
    body: 'Repeated body hash memory',
    kind: 'idea',
    trunk: 5,
    allowOrphan: true,
  });

  assertNativeReviewedEdge(
    harness.nativeDbPath,
    second.id,
    first.id,
    'reinforces',
    { authority: 'body-hash-recurrence' },
  );
  assertNativeEvidenceContains(harness.nativeDbPath, {
    sourceId: second.id,
    targetId: first.id,
    edgeType: 'reinforces',
    authority: 'body-hash-recurrence',
    contentHash: first.fullHash,
  });
  expect(readLines(harness.nativeLog).some((line) => line.startsWith('edge-commit '))).toBe(false);
});
```

Expected red failure: native-primary recurrence is still performed by the
legacy TypeScript post-save path and leaves native `card_edges` empty, or emits
an external `edge-commit` command instead of doing the work in `create-card`.

#### Green: Minimal Implementation

**Files**:

- `apps/silmari_memory_rust/src/store.rs`
- `apps/silmari_memory_rust/src/model.rs`
- `apps/silmari_memory_rust/src/cli.rs`
- `apps/silmari-mcp/src/lib/card-ops.ts`
- `apps/silmari-mcp/src/lib/native-adapter.ts`

Implementation steps:

- Extend the Rust native create input/result model only as needed to expose the
  full-body content hash and recurrence result metadata.
- Inside Rust `create_card`, detect the oldest prior card with the same
  full-body hash before committing the create transaction.
- In that same transaction, call the internal reviewed-edge helper with
  `authority: EdgeWriteAuthority::BodyHashRecurrence { content_hash }`,
  `edge_type: EdgeType::Reinforces`, and `reviewed_by: "silmari-mcp"` unless a
  native actor is already present.
- Project `ref:reinforces:<prior-id>` and consolidation labels in the same
  transaction.
- Map the native create result back into the existing TypeScript
  `SaveCardResult` shape.
- In legacy mode, keep the existing TypeScript `addEdge()` label behavior.
- Do not create or mutate `link-proposals.jsonl` for body-hash recurrence.
- Do not call TypeScript `brCommitReviewedEdge()`, `runPostSaveSteps()`, or
  `emitReinforcesToPrior()` in native-primary recurrence.

#### Refactor

- Keep body-hash recurrence evidence construction beside the Rust
  reviewed-edge commit helper.
- Share native reviewed-edge assertions with the `zk_commit_link` test.

### Success Criteria

**Automated**:

- [x] Red failed before implementation because `CreateCardInput` and
  `store::create_card` did not exist:
  `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml --test native_create`
- [x] Native create and reviewed-edge helper tests pass together:
  `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml --test native_create --test accepted_edges`
- [x] MCP native-primary recurrence dispatch passes:
  `bun test apps/silmari-mcp/tests/native-mcp-dispatch-contract.test.ts`
- [x] Existing save-card parity tests still pass:
  `bun test apps/silmari-mcp/tests/save-card-parity-snapshot.test.ts`
- [x] Batch recurrence and runtime routing remain compatible:
  `bun test apps/silmari-mcp/tests/zk-save-cards-batch.test.ts apps/silmari-mcp/tests/native-mode-routing.test.ts`

**Manual**:

- [x] Inspected a native DB recurrence edge through the real CLI path and
  confirmed evidence includes `contentHash` and no `proposalId`.
- [x] Native dispatch contract inspects the native command log and confirms
  recurrence does not issue a TypeScript `edge-commit` or `label-add
  ref:reinforces:*` command.

---

## Behavior 5: Export Emits Committed Native Edges

### Test Specification

**Given**: a native DB with an accepted reviewed `card_edges` row created by the
new authorized reviewed-edge helper, plus a `blocks` edge.

**When**: Rust `export-viewer --mode compat` runs.

**Then**:

- compatibility `card_edges` contains both edges;
- compatibility `dependencies` contains only the `blocks` row;
- summary JSON reports the correct edge and dependency counts.

**When**: Rust card-native export runs.

**Then**:

- `viewer_edges` contains the reviewed edge with `review_state='reviewed'`.

### TDD Cycle

#### Red: Write Failing Test

**File**: `apps/silmari_memory_rust/tests/viewer_export_contract.rs`

Add a test that seeds through `store::commit_reviewed_edge()` rather than
direct `insert_edge()`:

```rust
#[test]
fn accepted_edges_export_from_native_card_edges_without_label_synthesis() {
    let (_dir, mut native) = common::native_db();
    seed_two_cards(&native, "zk-source", "zk-target");
    commit_reviewed_reinforces(&mut native, "zk-source", "zk-target");

    let out_dir = tempdir().unwrap();
    let cache = out_dir.path().join("beads.sqlite3");
    let summary = silmari_memory_rust::export::export_viewer_compat(&native, &cache).unwrap();

    assert_eq!(summary.edges, 1);
    assert_compat_card_edge(&cache, "zk-source", "zk-target", "reinforces");
}
```

Expected red failure before Behavior 1: helper does not exist. If Behavior 1 is
already green, this test guards export against future regression.

#### Green: Minimal Implementation

No new exporter behavior should be required once native `card_edges` is correct.
If the test fails after Behavior 1, fix only the exporter projection from
`card_edges`; do not synthesize from labels.

#### Refactor

- Share test helpers for seeding committed reviewed edges.
- Keep `silmari-agent-memory-i3d` as the owner of full current viewer/browser
  compatibility coverage.

### Success Criteria

**Automated**:

- [x] Rust export contract passes:
  `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml --test viewer_export_contract`
- [x] Rust import accepted-review contract still passes:
  `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml --test import_snapshot_cli_contract`

**Manual**:

- [x] Inspected an exported compatibility cache through the real Rust CLI path
  and confirmed `card_edges` contained `blocks` and `reinforces`, while
  `dependencies` contained only `blocks`.

---

## Behavior 6: Reconcile Existing Committed Proposal Logs

### Test Specification

**Given**: an existing native DB with source/target cards and a
`link-proposals.jsonl` file containing committed, pending, rejected, malformed,
and missing-endpoint proposals.

**When**: `edge-reconcile-proposals` runs.

**Then**:

- committed valid reviewed proposals become reviewed native `card_edges`;
- compatibility labels are present;
- pending and rejected proposals do not become live edges;
- malformed lines are counted but do not abort valid repair;
- missing endpoints are reported without partial writes;
- repeated reconciliation is idempotent.

### TDD Cycle

#### Red: Write Failing Test

**File**: `apps/silmari_memory_rust/tests/edge_reconciliation.rs`

```rust
#[test]
fn reconciliation_replays_only_committed_valid_proposals() {
    let (_dir, mut conn) = common::native_db();
    seed_two_cards(&conn, "zk-source", "zk-target");
    let proposals = write_link_proposals_jsonl([
        committed("lp-ok", "zk-source", "zk-target", "reinforces"),
        pending("lp-pending", "zk-source", "zk-target", "supports"),
        rejected("lp-rejected", "zk-source", "zk-target", "extends"),
        malformed_line(),
        committed("lp-missing", "zk-source", "zk-missing", "refines"),
    ]);

    let report = silmari_memory_rust::reconcile::reconcile_committed_proposals(
        &mut conn,
        CardBox::Idea,
        &proposals,
        "edge-reconcile",
    )
    .unwrap();

    assert_eq!(report.applied, 1);
    assert_eq!(report.skipped_pending, 1);
    assert_eq!(report.skipped_rejected, 1);
    assert_eq!(report.invalid_shape, 1);
    assert_eq!(report.missing_endpoint, 1);
    assert_reviewed_edge(&conn, "zk-source", "zk-target", "reinforces");
}
```

Expected red failure: reconciliation module/command does not exist.

#### Green: Minimal Implementation

**Files**:

- `apps/silmari_memory_rust/src/reconcile.rs`
- `apps/silmari_memory_rust/src/cli.rs`
- `apps/silmari_memory_rust/src/lib.rs`
- `apps/silmari_memory_rust/src/store.rs`

Implementation steps:

- Parse JSONL with skip-and-count semantics.
- Accept only `status:"committed"`.
- Map proposal fields exactly: source = `from_id`, target = `to_id`, type =
  `edge`, proposal id = `id`, reason = `resolved_reason ?? rationale`, and
  reviewed at = `resolved_at ?? created_at`.
- Validate proposal shape and reviewed edge type.
- Validate endpoints and box.
- Call `store::commit_reviewed_edge(&mut conn, input)` with
  `EdgeWriteAuthority::AcceptedProposal { proposal_id }` and evidence from the
  proposal record. Reconciliation must use the same authority key as live
  `zk_commit_link` so reruns and cross-store retries are idempotent.
- Return a structured report and serialize the CLI JSON fields in camelCase
  (`alreadyPresent`, `skippedPending`, `skippedRejected`, `invalidShape`,
  `missingEndpoint`).

#### Refactor

- Share proposal parsing with any future import-snapshot sidecar replay.
- Keep reconciliation independent of viewer export.
- Keep evidence payload stable and documented in the test.

### Success Criteria

**Automated**:

- [x] Focused reconciliation test passes:
  `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml --test edge_reconciliation`
- [x] Reconciliation plus export proof passes:
  `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml --test edge_reconciliation --test viewer_export_contract`

**Manual**:

- [x] Run the command on a copy of RedGorge's temp DB/proposal log if still
  available, never on the original temp output.

---

## Behavior 7: Gate B Reports Native Edge Durability

### Test Specification

**Given**: native-primary Gate B commits a proposal and receives a commit result
with native durability metadata.

**When**: `commitProposal()` counts the edge.

**Then**:

- `edges_committed` remains the semantic committed count;
- native-primary reports also include a native durability count, such as
  `native_edges_committed`;
- missing durability metadata in native-primary is treated as failure or at
  least as `native_edge_commit_mismatches > 0`;
- aggregate reports expose the durability count so a zero-native-edge run cannot
  look healthy.

### TDD Cycle

#### Red: Write Failing Tests

**Files**:

- `scripts/kc-baker-pipeline-v2/tests/ingest-cascade.test.ts`
- `scripts/kc-baker-pipeline-v2/tests/step8-aggregate.test.ts`

Example assertions:

```ts
it('tracks native edge durability separately from tool-call success', () => {
  const gateB = summarizeGateBCommitResults([
    { ok: true, edge: 'reinforces', nativeEdgeCommitted: true },
    { ok: true, edge: 'supports', nativeEdgeAlreadyPresent: true },
    { ok: true, edge: 'extends' },
  ]);

  expect(gateB.edges_committed).toBe(3);
  expect(gateB.native_edges_committed).toBe(2);
  expect(gateB.native_edge_commit_mismatches).toBe(1);
});
```

Expected red failure: no native durability fields exist.

#### Green: Minimal Implementation

**Files**:

- `apps/silmari-mcp/src/lib/edges.ts`
- `apps/silmari-mcp/src/index.ts`
- `scripts/kc-baker-pipeline-v2/ingest/ingest-cascade.ts`
- `scripts/kc-baker-pipeline-v2/extract/step8-aggregate.ts`

Implementation steps:

- Make native-primary `zk_commit_link` return optional durability metadata:
  `nativeEdgeCommitted`, `nativeEdgeAlreadyPresent`,
  `nativeEdgePromoted`, `nativeReviewState`, and `nativeEdgeType`.
- Thread that metadata through `commitProposal()`.
- Add `native_edges_committed` and `native_edge_commit_mismatches` to ingest
  reports and aggregate reports.
- Keep legacy mode compatible by omitting native fields or setting them to zero.
- In native-primary mode, treat a successful commit result as durable only when
  `nativeEdgeCommitted === true` or `nativeEdgeAlreadyPresent === true`. Missing
  durability fields are a mismatch even if `zk_commit_link` returned OK.

#### Refactor

- Keep report field names stable and documented.
- Avoid querying SQLite directly from Gate B if the MCP commit result can carry
  the durability proof.
- Keep full transcript validation separate from this unit/integration layer.

### Success Criteria

**Automated**:

- [x] Gate B ingest tests pass:
  `bun test scripts/kc-baker-pipeline-v2/tests/ingest-cascade.test.ts`
- [x] Step 8 aggregate tests pass:
  `bun test scripts/kc-baker-pipeline-v2/tests/step8-aggregate.test.ts`
- [x] MCP dispatch still passes:
  `bun test apps/silmari-mcp/tests/native-mcp-dispatch-contract.test.ts`

**Manual**:

- [x] Gate B unit/integration coverage verifies native-primary reports expose
  both `edges_committed` and `native_edges_committed`; full real-run
  throughput/classification validation is tracked outside this DBH replacement
  rollup by `silmari-agent-memory-9hn.1`.

## Integration and E2E Testing

After Behaviors 1-7 pass, run the focused integrated gates:

```bash
cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml --test accepted_edges
cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml --test adapter_cli_contract
cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml --test edge_reconciliation
cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml --test viewer_export_contract
cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml --test import_snapshot_cli_contract
bun test apps/silmari-mcp/tests/native-cli-contract.test.ts
bun test apps/silmari-mcp/tests/native-mcp-dispatch-contract.test.ts
bun test apps/silmari-mcp/tests/card-ops.test.ts
bun test apps/silmari-mcp/tests/edges.test.ts
bun run --cwd apps/silmari-mcp typecheck
bun test scripts/kc-baker-pipeline-v2/tests/ingest-cascade.test.ts
bun test scripts/kc-baker-pipeline-v2/tests/step8-aggregate.test.ts
```

Broader confidence gates:

```bash
cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml
bun test apps/silmari-mcp/tests
bun test scripts/kc-baker-pipeline-v2/tests
```

Operational validation after merge:

1. Run a small native-primary import/enrich fixture.
2. Assert `gateB.edges_committed == gateB.native_edges_committed`.
3. Assert native DB `SELECT COUNT(*) FROM card_edges WHERE review_state='reviewed'`
   is nonzero.
4. Run Rust `export-viewer --mode compat`.
5. Assert exported compatibility `card_edges` count matches the native committed
   reviewed count plus any auto edges.

## Implementation Order

1. Behavior 1: Rust transaction helper and audit event.
2. Behavior 2: Rust CLI `edge-commit` and reviewed `edge-add` rejection.
3. Behavior 3: TypeScript native-primary `zk_commit_link` bridge.
4. Behavior 4: Rust/native create body-hash recurrence using the internal
   reviewed-edge helper. This is not a TypeScript post-save bridge.
5. Behavior 5: export proof from committed native rows.
6. Behavior 6: reconciliation/backfill for existing runs.
7. Behavior 7: Gate B durability reporting.

Do not start Behavior 3 before Behavior 2 is green. TypeScript should call a
real Rust command whose behavior is already tested.

## Beads Linkage

- `silmari-agent-memory-1c0`: this TDD plan.
- `silmari-agent-memory-qwy`: completed research that identified the mismatch.
- `silmari-agent-memory-i3d`: related viewer compatibility contract. Keep it
  focused on current viewer compatibility rather than source-of-truth repair.

Current implementation child beads:

1. `1c0.1`: Rust authorized reviewed-edge store transaction and CLI.
2. `1c0.2`: TypeScript native-primary `zk_commit_link` accepted-proposal bridge.
3. `1c0.3`: Rust export proof and current viewer compatibility coordination.
4. `1c0.4`: committed proposal reconciliation/backfill.
5. `1c0.5`: Gate B native durability reporting.
6. `1c0.6`: Rust/native create body-hash recurrence. Closed in coordinated
   Rust commit `c20ceab` and TypeScript child commit `e4effb4`; implemented as
   native create semantics, not as a TypeScript post-save bridge.
7. `1c0.6.1`: TypeScript native-primary save-card mapping for Rust recurrence
   metadata. Closed in `e4effb4`.

## References

- Research: `thoughts/searchable/shared/research/2026-04-30-native-primary-live-edge-commit-card-edges-solution.md`
- Rust schema: `apps/silmari_memory_rust/src/schema.rs:176-188`
- Rust store edge insert: `apps/silmari_memory_rust/src/store.rs:62-101`
- Rust CLI edge add: `apps/silmari_memory_rust/src/cli.rs:143-157`, `apps/silmari_memory_rust/src/cli.rs:507-521`
- Rust import review policy: `apps/silmari_memory_rust/src/importer.rs:522-592`
- Rust export projection: `apps/silmari_memory_rust/src/export.rs:213-239`
- MCP commit path: `apps/silmari-mcp/src/lib/edges.ts:334-374`
- MCP body-hash recurrence path: `apps/silmari-mcp/src/lib/card-ops.ts:271-286`,
  `apps/silmari-mcp/src/lib/card-ops.ts:591-606`
- Native adapter label/edge commands: `apps/silmari-mcp/src/lib/native-adapter.ts:232-255`
- Gate B commit counter: `scripts/kc-baker-pipeline-v2/ingest/ingest-cascade.ts:1473-1507`
- Native data model: `artifacts/specs/2026-04-28-beads-rust-replacement/02-native-data-model.md:134-155`
- Store/API authority rules: `artifacts/specs/2026-04-28-beads-rust-replacement/03-store-api-and-adapter.md:208-249`
