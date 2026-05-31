---
date: 2026-04-28T17:43:32-04:00
reviewer: Codex
review_type: cw9-03-abstraction-gap
plan: thoughts/searchable/shared/plans/2026-04-28-silmari-agent-memory-dbh-tdd-card-native-beads-rust-replacement.md
status: failed
critical_gaps: 4
cross_layer_handoffs: 4
---

# Abstraction Gap Review: Card-Native beads_rust Replacement

## Verdict

**Status: FAIL - implementation must not start from this plan without the gap fixes below.**

The plan is substantially more concrete than the TLA+ models, and most GWT boundaries have enough implementation guidance. The remaining failures are not broad missing research. They are specific ownership decisions where an implementation agent can choose an existing function or module that satisfies the words of the plan but violates the proved behavior.

This review also inherits the coverage-review blocker for `gwt-0004`: the plan supersedes the stale CLI error vocabulary, but the `.cw9` model/context/test artifacts still need regeneration before any generated test suite can be treated as authoritative.

## Evidence Reviewed

- Plan: `thoughts/searchable/shared/plans/2026-04-28-silmari-agent-memory-dbh-tdd-card-native-beads-rust-replacement.md`
- TLA+ specs: `.cw9/specs/gwt-0001.tla` through `.cw9/specs/gwt-0008.tla`
- TLC configs and simulation traces for all eight GWTs
- Context files: `.cw9/context/gwt-0001.md` through `.cw9/context/gwt-0008.md`
- Bridge artifacts: `.cw9/bridge/gwt-0001_bridge_artifacts.json` through `.cw9/bridge/gwt-0008_bridge_artifacts.json`
- Crawl DB records in `.cw9/crawl.db`
- Current source modules referenced by the plan and crawl records

## Bridge Artifact Risk

Every inspected bridge artifact has empty `depends_on` metadata for operations and verifiers. That means the bridge layer does not tell an implementer which concrete function to call or avoid. The plan and context files must carry every implementation-choice constraint.

Observed bridge keys include, for example:

- `gwt-0001`: `operations.CheckVersion`, `operations.ApplyV2DDL`, `verifiers.NoPartialMigration`
- `gwt-0002`: `operations.Route`, `verifiers.ReviewedLiveRequiresAuthority`
- `gwt-0003`: `operations.CreateCardTx`, `operations.RunPostSave`, `verifiers.TransactionAtomicity`
- `gwt-0004`: `operations.OpenDatabase`, `operations.ExecuteCommand`
- `gwt-0005`: `operations.StageImport`, `operations.Promote`
- `gwt-0006`: `operations.Dispatch`, `operations.LabelNative`, `operations.LabelLegacy`
- `gwt-0007`: `operations.Export`, `operations.BuildLinks`
- `gwt-0008`: `operations.BuildInjection`, `operations.NormalizeEntryKeys`

Because those records do not name concrete callees, any ambiguous or conflicting plan sentence is a real implementation risk.

## Summary Matrix

| GWT | Boundary | Decision Count | Documented | Critical Gaps | Notes |
| --- | --- | ---: | ---: | ---: | --- |
| `gwt-0001` | Schema v1 to v2 migration | 5 | 4 | 1 | Migration entrypoint ownership conflicts with current `init_schema` usage. |
| `gwt-0002` | Typed edge routing and authority | 6 | 5 | 1 | Accepted review manifest is named but not specified. |
| `gwt-0003` | Native card creation and post-save effects | 7 | 6 | 1 | Rust/TS post-save ownership is unresolved. |
| `gwt-0004` | CLI envelope and DB open policy | 6 | 6 | 0 | Plan is clear, but `.cw9` artifacts are stale. |
| `gwt-0005` | Snapshot/import replacement | 7 | 7 | 0 | Sufficient once review-manifest gap from `gwt-0002` is fixed. |
| `gwt-0006` | MCP adapter facade routing | 7 | 6 | 1 | Adapter file/import ownership is internally inconsistent. |
| `gwt-0007` | Viewer export and link building | 5 | 5 | 0 | Sufficient. |
| `gwt-0008` | SAI recall shape normalization | 4 | 4 | 0 | Sufficient; needs protocol review handoff. |

Total concrete implementation decisions reviewed: 47. Documented clearly: 43. Critical abstraction gaps: 4.

## Critical Gaps

### GAP-001: Migration Entry Point Is Ambiguous

**GWT:** `gwt-0001`

**Spec transition affected:** `CheckVersion -> StartMigration -> ApplyV2DDL -> CommitMigration`
**Current code involved:**

- `apps/silmari_memory_rust/src/schema.rs::init_schema`
- `apps/silmari_memory_rust/src/store.rs::open_native`

The TLA+ model proves properties about version checking, transactional migration, future-version rejection, and idempotent second open. It does not specify whether the implementation should mutate the existing `init_schema` function, add `open_or_migrate`, add `migrate_v1_to_v2`, or split create/open/migrate into separate public APIs.

The plan points at `init_schema`, while the generated context/test language references `open_or_migrate`. Current `store::open_native` calls `schema::init_schema`, and `init_schema` currently creates v1 tables. An implementer can therefore "fix" `init_schema` by piling `CREATE TABLE IF NOT EXISTS` statements into it, which risks partial upgrade behavior the model explicitly rejects.

**Required plan/context fix:**

Pin the entrypoints and negative rule:

```text
Schema ownership decision:
- `init_schema(conn)` creates or verifies an empty/current v2 database only.
- `open_or_migrate(path)` is the public open path for existing databases.
- `migrate_v1_to_v2(conn)` performs the v1-to-v2 DDL and schema_version update in one transaction.
- `store::open_native` must call `open_or_migrate`, not directly call a create-only helper.
- Adding missing v2 tables with standalone `CREATE TABLE IF NOT EXISTS` outside a versioned migration is forbidden.
```

The plan may choose different names, but it must choose exactly one owner for each responsibility.

### GAP-002: Accepted Review Manifest Is Named But Not Contracted

**GWTs:** `gwt-0002`, `gwt-0005`

**Spec transitions affected:** `Classify -> Route`, `StageImport -> Promote`
**Current code involved:**

- `apps/silmari_memory_rust/src/labels.rs::parse_labels`
- `apps/silmari_memory_rust/src/store.rs::insert_edge`
- `apps/silmari_memory_rust/src/importer.rs::import_beads_box_into_conn`
- `apps/silmari-mcp/src/lib/edges.ts::proposeOrAddEdge`

The plan correctly says reviewed agent edges must not become live without authority and that imports may promote reviewed references only when an operator accepted-review manifest exists. It does not define that manifest's schema, path, validation rules, snapshot binding, or failure behavior.

Without that contract, an implementation agent can guess a manifest shape or skip validation and still appear to satisfy the high-level plan. That would undercut `ReviewedLiveRequiresAuthority`.

**Required plan/context fix:**

Add an explicit import authority manifest contract. Minimum fields:

```json
{
  "version": 1,
  "sourceSnapshotHash": "sha256:...",
  "acceptedEdges": [
    {
      "source": "zk-source",
      "target": "zk-target",
      "type": "refers_to",
      "authority": "operator",
      "reviewedBy": "operator-or-agent-id",
      "reviewedAt": "2026-04-28T00:00:00Z"
    }
  ]
}
```

Required rules:

- Missing manifest means reviewed refs import as pending proposals only.
- Manifest `sourceSnapshotHash` must match the imported snapshot.
- Unknown edge types, unknown cards, duplicate rows, or missing authority metadata fail validation before promotion.
- Accepted reviewed edges are written through the same authority gate as runtime reviewed edges, not by direct `insert_edge`.
- The import report must count accepted, pending, refused, and invalid reviewed edges separately.

### GAP-003: Post-Save Ownership Is Split Across Rust And TypeScript

**GWT:** `gwt-0003`

**Spec transitions affected:** `CreateCardTx -> RunPostSave -> BuildReturn`
**Current code involved:**

- `apps/silmari_memory_rust/src/store.rs::insert_card`
- planned `apps/silmari_memory_rust/src/store.rs::create_card`
- `apps/silmari-mcp/src/lib/card-ops.ts::saveCard`
- `apps/silmari-mcp/src/lib/card-ops.ts::runPostSaveSteps`
- `apps/silmari-mcp/src/lib/card-ops.ts::emitReinforcesToPrior`

The TLA+ model abstracts post-save side effects as part of the native create flow. The plan says native create must atomically persist card, labels, content hash, folgezettel cursor, event, keyword index, and initial edges. Current TypeScript `saveCard` still owns `runPostSaveSteps`, recurrence edges, explicit target resolution, keyword lookup side effects, and Beads flush behavior.

The plan does not explicitly say which side owns those effects in native mode, how the TypeScript facade prevents duplicate effects, or which current TypeScript helpers become legacy-only. This is both an implementation-choice gap and a cross-layer protocol issue.

**Required plan/context fix:**

Add a single-owner rule:

```text
Native mode post-save ownership:
- Rust `create_card` owns durable post-save effects for native DB state: keyword entries, content hash, folgezettel state, body-hash recurrence, accepted explicit edges, and card_events.
- TypeScript `saveCard` in native modes only validates caller-facing input, invokes the native create command, maps the result into the existing MCP shape, and runs shadow/parity reporting if the mode requires it.
- TypeScript `runPostSaveSteps`, `emitReinforcesToPrior`, direct Beads flush/rebuild, and `findBeadsByLabel` paths are legacy-only unless explicitly called by the shadow legacy branch.
- No native mode path may run both Rust post-save effects and TS legacy post-save effects for the same create.
```

This also needs a `04cw9`/cross-layer protocol review because the owner decision crosses Rust CLI/store and TypeScript MCP facade boundaries.

### GAP-004: Adapter File Ownership Conflicts With The Import Gate

**GWT:** `gwt-0006`

**Spec transitions affected:** `Dispatch -> LabelNative`, `Dispatch -> LabelLegacy`, `Finish`
**Current code involved:**

- `apps/silmari-mcp/src/lib/br-adapter.ts`
- `apps/silmari-mcp/src/lib/br-sqlite.ts`
- planned `apps/silmari-mcp/src/lib/native-adapter.ts`
- plan-referenced `apps/silmari-mcp/src/lib/legacy-br-adapter.ts`

The plan contains two incompatible implementation directions:

- The negative import-gate test expects `./br-sqlite.js` to be imported only from `apps/silmari-mcp/src/lib/legacy-br-adapter.ts`.
- The Green section also says to keep `br-adapter.ts` as the legacy implementation and route through a thin mode switch.

Those cannot both be true. Current call sites import `br-adapter.ts` as the public surface, and current legacy implementation details also live in that file. If an implementer keeps everything in `br-adapter.ts`, the proposed import gate fails or gets weakened. If they split files, the Green text becomes misleading.

**Required plan/context fix:**

Choose this file ownership explicitly:

```text
Adapter ownership decision:
- `br-adapter.ts` is the public facade and mode switch. Existing public exports keep their names.
- `legacy-br-adapter.ts` owns current Beads subprocess/SQLite compatibility implementation and is the only production file allowed to import `./br-sqlite.js`.
- `native-adapter.ts` owns the native CLI/JSON-envelope client and is imported only by `br-adapter.ts` or test harnesses.
- Production callers must continue importing from `br-adapter.ts`; direct imports from `legacy-br-adapter.ts` or `native-adapter.ts` are forbidden outside facade-owned tests.
```

Update the Green section and negative import tests to match the chosen owner.

## Boundary Decision Checklist

Use this as the implementation handoff checklist after fixing the critical gaps.

### `gwt-0001`: Schema Migration

- **Correct function owner:** Add or explicitly designate `open_or_migrate` and `migrate_v1_to_v2`; do not leave migration ownership implicit inside the old v1 `init_schema`.
- **Wrong function to reuse blindly:** `store::open_native` currently calls `schema::init_schema`; this must not remain the only open path for existing DBs.
- **Future versions:** Any `schema_versions.version > SUPPORTED_SCHEMA_VERSION` must reject without mutating the database.
- **Partial migration:** All v2 DDL and version update must commit atomically.
- **Second open:** Reopening an already-current v2 database must be idempotent and not rewrite data.

### `gwt-0002`: Edge Authority

- **Correct classifier:** Reuse `labels.rs::parse_labels` and `EdgeType::requires_review`.
- **Wrong write for reviewed edges:** Do not call low-level `insert_edge` for normal reviewed agent edges.
- **Authority gate:** Runtime reviewed edges must pass through `proposeOrAddEdge` semantics or a native equivalent authority gate.
- **Import gate:** Imported reviewed refs are pending unless validated by the accepted review manifest described in GAP-002.
- **Compat exception:** Existing Beads compat `addEdge` behavior may remain legacy-only, but it must not become the native normal path.
- **Blocks direction:** `blocks` edge direction must stay source/blocker -> target/blocked.

### `gwt-0003`: Native Create

- **Correct Rust owner:** Implement a native `create_card` path; do not treat existing `insert_card` as sufficient because it is currently an `INSERT OR REPLACE` helper without evented create semantics.
- **From address:** Validate slash-form parent addresses before durable create.
- **Dedupe:** Content-hash lookup must preserve oldest-match semantics.
- **Atomic side effects:** Card row, labels, content hash, folgezettel cursor, event, keyword entries, and accepted initial edges must be committed atomically in native mode.
- **Legacy-only helpers:** Current TS `runPostSaveSteps`, `emitReinforcesToPrior`, and direct Beads lookup helpers must not run after a native create for the same card unless in the legacy branch of shadow mode.
- **Return shape:** TypeScript facade owns current MCP result projection and error mapping.
- **Batch:** Batch create must use the same create contract per card and report partial/atomic behavior explicitly.

### `gwt-0004`: CLI Contract

- **Correct entrypoint:** `cli.rs::run` remains the command entry, but command execution needs a shared open-policy layer.
- **Read DB open:** Read commands must open existing DBs read-only and never create missing SQLite files.
- **Write DB open:** Runtime write commands need read/write existing DBs and map missing DBs to `DB_NOT_FOUND`.
- **Create DB owner:** `init` is the only default command that may create a missing native DB.
- **Envelope:** `--json` success uses `{ok:true,result,...}` and failure uses `{ok:false,error:{code,message,details}}`.
- **Stale vocabulary:** `DB_MISSING`, `PARSE_ERROR`, `POLICY_VIOLATION`, `INPUT_ERROR`, lowercase `cli_parse`, `sqlite`, and `unknown_edge_type` must be removed from generated adapter-facing artifacts.

### `gwt-0005`: Snapshot Import

- **Correct import boundary:** Add a migration/import module for snapshot staging and reporting; do not extend old `import_beads_box_into_conn` directly into the replacement importer.
- **Source contract:** Import from raw Beads source tables with normalized label data; do not use viewer cache tables as canonical source.
- **Staging:** Write into a staging target and promote only after validation succeeds.
- **Rollback:** Failed validation leaves the pre-existing target untouched and writes an actionable report.
- **Field disposition:** Preserve, map, synthesize, or drop fields according to the plan's field-disposition table.
- **Edge policy:** `blocks` can become live; reviewed refs require the accepted manifest from GAP-002.
- **Reports:** Import reports must include row counts, skipped rows, pending reviewed edges, refused rows, and rollback path.

### `gwt-0006`: Adapter Routing

- **Correct public import:** Production MCP code imports the public facade from `br-adapter.ts`.
- **Legacy owner:** `legacy-br-adapter.ts` owns current Beads subprocess/SQLite compatibility details.
- **Native owner:** `native-adapter.ts` owns native CLI calls and JSON envelope parsing.
- **Mode owner:** `native-mode.ts` resolves config, env overrides, rollback modes, and invalid-mode errors.
- **Label lookup:** `findCardsByLabelCompat` must route through native indexed label query in native modes and through legacy Beads lookup only in legacy modes.
- **Error mapping:** `brShow`, `brList`, `brSearch`, and create wrappers must preserve current caller-visible null/array/error behavior.
- **Import gate:** Direct imports of `br-sqlite.ts` and `native-adapter.ts` must be enforced by tests.

### `gwt-0007`: Viewer Export

- **Correct owner:** Rust export module writes authoritative compatibility and card-native viewer caches.
- **Wrong source:** Browser/server label synthesis is fallback compatibility only, not the source of truth for native exported edges.
- **Compat tables:** Write `issues`, `dependencies`, `issue_overview_mv`, `issues_fts`, `export_meta`, and `card_edges`.
- **Go schema reuse:** Reuse or mirror the Go export schema where it is the current viewer contract, then add Silmari-specific `card_edges`.
- **Direction:** Compatibility `dependencies.issue_id` is the blocking/source card and `depends_on_id` is the blocked target it depends on.

### `gwt-0008`: SAI Recall Normalization

- **Correct public boundary:** SAI must consume one public memory client/shim, not direct low-level MCP internals.
- **Shape mapping:** Transitional `entryCards`/snake_case internal shapes map to public `keywordEntries`, `folgezettelNeighbors`, and `crossRefs` only inside the shim.
- **MCP payloads:** Rust and MCP-facing recall payloads remain camelCase and do not expose native lifecycle fields.
- **Fallback:** Missing recall data produces empty arrays, not thrown hook failures, unless the underlying public client reports a typed mode/config error.

## Module Export Analysis

| Module | Existing role | Correct implementation choice | Avoid |
| --- | --- | --- | --- |
| `apps/silmari_memory_rust/src/schema.rs` | v1 schema initializer | Split or designate create, open, and migrate responsibilities explicitly. | Silent best-effort `CREATE TABLE IF NOT EXISTS` upgrades. |
| `apps/silmari_memory_rust/src/store.rs` | Low-level card/edge helpers | Add evented native create and authority-aware edge writes. | Treating `insert_card`/`insert_edge` as sufficient public replacement APIs. |
| `apps/silmari_memory_rust/src/importer.rs` | Current Beads import helper | Keep as legacy/reference or refactor behind snapshot importer. | Extending old direct importer into replacement import without staging/report gates. |
| `apps/silmari_memory_rust/src/cli.rs` | Current CLI entry | Add open-policy and stable envelope layer under `run`. | Direct `Connection::open` in read commands; raw success JSON under `--json`. |
| `apps/silmari-mcp/src/lib/br-adapter.ts` | Current public facade plus legacy implementation | Make it the facade/mode switch only. | Keeping both public facade and legacy implementation details if import gates expect a split. |
| `apps/silmari-mcp/src/lib/br-sqlite.ts` | Direct Beads SQLite lookup | Legacy-only implementation detail. | Any native/production caller importing it directly. |
| `apps/silmari-mcp/src/lib/card-ops.ts` | Current save/post-save orchestration | In native mode, call facade/native create and project result. | Running legacy post-save effects after native create. |
| `apps/silmari-mcp/src/lib/edges.ts` | Legacy add/propose edge routing | Preserve `proposeOrAddEdge` semantics in native authority gate. | Direct `addEdge` for normal reviewed native edges. |
| `apps/silmari-memory-card-viewer/server.ts` | Current viewer compatibility synthesis | Accept Rust-exported card edges as authoritative. | Treating label synthesis as native export truth. |
| `apps/silmari-viewer/pkg/export/sqlite_schema.go` | Current Go viewer schema | Mirror/reuse for compatibility tables, plus add native `card_edges`. | Assuming Go schema alone satisfies Silmari typed-edge export. |
| `SAI/hooks/ThinkWithMemory.hook.ts` | Current direct consumer of MCP internals | Import a public memory shim/client. | Dynamic imports of low-level adapter, labels, navigate, and keyword modules. |

## Cross-Layer Review Handoffs

These are not all abstraction failures, but they require a separate boundary/protocol review before implementation is considered ready.

1. **Native create protocol:** Rust `create_card` and TypeScript `saveCard`/MCP facade must have a transcript showing which side validates, writes, maps errors, and runs shadow reports.
2. **CLI JSON envelope:** Rust CLI and TypeScript native adapter need contract tests for every success/error envelope and timeout/missing-card mapping.
3. **Runtime modes:** `native-mode.ts`, `br-adapter.ts`, shadow parity, and rollback config need a protocol review to prove mode switches are config-only and all public callers route through the facade.
4. **SAI shim:** SAI hook to MCP/native facade needs a transcript proving public `RecallSummary` shape under legacy and native modes.

## Required Context Updates

Update the `.cw9/context` files or the plan before implementation. These are the minimum additions.

### `.cw9/context/gwt-0001.md`

Add a section named `Implementation Decision: Migration Entrypoints` with the ownership rule from GAP-001. Tests should call the selected public open/migrate function, not an undeclared helper name.

### `.cw9/context/gwt-0002.md`

Add `Implementation Decision: Accepted Review Manifest` with the manifest schema and validation rules from GAP-002.

### `.cw9/context/gwt-0003.md`

Add `Implementation Decision: Native Post-Save Ownership` with the no-duplicate-effects rule from GAP-003.

### `.cw9/context/gwt-0006.md`

Add `Implementation Decision: Adapter File Ownership` with the facade/legacy/native split from GAP-004.

### `.cw9/context/gwt-0004.md`

Regenerate or amend the model/context/bridge/generated tests so the plan's `NativeEnvelope` and current error-code set are the only adapter-facing contract. This is inherited from the coverage review, but it remains blocking.

## Final Gate

After the four critical gaps are fixed and `gwt-0004` artifacts are regenerated, rerun:

```bash
$02cw9-Plan-Review thoughts/searchable/shared/plans/2026-04-28-silmari-agent-memory-dbh-tdd-card-native-beads-rust-replacement.md
$03cw9-Plan-Review thoughts/searchable/shared/plans/2026-04-28-silmari-agent-memory-dbh-tdd-card-native-beads-rust-replacement.md
$04cw9-Plan-Review thoughts/searchable/shared/plans/2026-04-28-silmari-agent-memory-dbh-tdd-card-native-beads-rust-replacement.md
```

Implementation should remain blocked until those passes agree that the plan, context files, and generated artifacts describe the same concrete boundaries.
