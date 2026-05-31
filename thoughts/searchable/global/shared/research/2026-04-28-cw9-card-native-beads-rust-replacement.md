---
title: "CW9 Research: card-native beads_rust replacement"
date: 2026-04-28T07:30:51-04:00
researcher: Codex
repository: silmari-agent-memory
branch: main
git_commit: c078c552164bfe54cca743a68ac86b6cf66fb122
plan: thoughts/searchable/shared/plans/2026-04-28-silmari-agent-memory-dbh-tdd-card-native-beads-rust-replacement.md
bead: silmari-agent-memory-q59
status: complete
tags:
  - cw9
  - research
  - silmari-memory-rust
  - beads-rust-replacement
  - sqlite
  - migration
  - mcp
  - viewer
  - sai
---

# Research Question

Use CW9 to identify the concrete implementation surfaces for replacing runtime dependence on `vendor/beads_rust`/`br` with a card-native Rust SQLite store while preserving the existing MCP TypeScript facade, viewer export compatibility, and SAI memory consumers.

The starting plan is:

`thoughts/searchable/shared/plans/2026-04-28-silmari-agent-memory-dbh-tdd-card-native-beads-rust-replacement.md`

# Extraction Status

CW9 was initialized for `/home/maceo/Dev/silmari-agent-memory` and scoped ingestion covered the surfaces required by the plan:

- `apps/silmari_memory_rust/` as Rust
- `apps/silmari-mcp/` as TypeScript
- `apps/silmari-memory-card-viewer/` as TypeScript
- `apps/silmari-memory-card-viewer/viewer_assets/` as JavaScript
- `apps/silmari-viewer/pkg/export/` as Go
- `SAI/hooks/` as TypeScript

The `.cw9/crawl.db` currently contains 1,742 records total. Of those, 1,260 are in the scoped target surfaces above. The targeted DFS crawl through the plan entry points was intentionally stopped after it slowed to roughly 44 seconds per function; the research therefore uses CW9 UUID records for stable references and direct source reads for behavior details. The crawl state is preserved under `.cw9/`.

# Codebase Overview

The replacement crosses five implementation layers:

1. Rust native store: `apps/silmari_memory_rust/src/` owns schema creation, label parsing, card/edge storage, import from beads-shaped SQLite, retrieval, and the Rust CLI.
2. MCP compatibility facade: `apps/silmari-mcp/src/lib/` owns the existing `br-adapter.ts` surface and high-level card, edge, keyword, navigation, and line-of-thought behavior.
3. Viewer compatibility: `apps/silmari-memory-card-viewer/` and `apps/silmari-memory-card-viewer/viewer_assets/` consume a beads-viewer-shaped SQLite export and synthesized typed edges.
4. Go exporter baseline: `apps/silmari-viewer/pkg/export/` defines the current static SQLite schema used by the viewer SPA.
5. SAI consumers: `SAI/hooks/` imports MCP internals directly today and consumes recall payloads with a different naming convention from the current Rust JSON.

The plan is correct to avoid replacing these in a single unbounded edit. The riskiest part is not the Rust schema itself; it is preserving the compatibility behavior currently encoded in TypeScript shell wrappers and viewer query assumptions.

# Key Functions

## Rust Native Store

### `init_schema()`

- UUID: `dbd532d0-1a6f-5c9a-9d8b-47662eed5e46`
- File: `apps/silmari_memory_rust/src/schema.rs:22`
- Role: Creates the current native SQLite schema and writes `schema_versions` rows.
- Calls: `Connection::open()`, `pragma_update(foreign_keys=ON)`, `execute_batch()`, `query_row()`, `execute()`.
- Called by: `open_native()`, `import_beads_box()`, CLI `run()` via `Command::Init`.
- Research finding: `SUPPORTED_SCHEMA_VERSION` is still `1`. The function creates tables with `CREATE TABLE IF NOT EXISTS`, checks only for future schema versions, and writes version rows with `INSERT OR IGNORE`. It does not migrate existing v1 databases, does not update stale version rows, and does not create the plan's v2 fields or indexes.

### `insert_card()`

- UUID: `19727657-5cfe-5d42-b0c2-2adb24f25d24`
- File: `apps/silmari_memory_rust/src/store.rs:17`
- Role: Inserts or replaces a card row and rewrites its label set.
- Calls: `parse_labels()`, `validate_card_label_parity()`, `dedupe_labels()`, `Connection::execute()`.
- Called by: `import_beads_box_into_conn()`.
- Research finding: The current implementation uses `INSERT OR REPLACE` into `cards` and then `DELETE FROM card_labels WHERE card_id = ?`. That is acceptable for bulk import but is too destructive for live MCP CRUD semantics unless wrapped behind stricter APIs and event/audit behavior.

### `insert_edge()`

- UUID: `ce391b3b-23a7-5203-b3ec-bdb1320ffaf3`
- File: `apps/silmari_memory_rust/src/store.rs:64`
- Role: Inserts a typed edge into `card_edges`.
- Calls: `Connection::execute()`.
- Called by: `import_beads_box_into_conn()`, `import_block_dependencies()`, retrieval helpers indirectly through persisted rows.
- Research finding: The table has no source/target foreign keys and no review state metadata. `insert_edge()` accepts any `EdgeType`, so authority must be enforced above this function or by a new write API.

### `parse_labels()`

- UUID: `048510c5-6cb3-53ad-84fa-f9ff11ac6abf`
- File: `apps/silmari_memory_rust/src/labels.rs:66`
- Role: Parses `fz:`, `kind:`, `box:`, `trunk:`, `source:`, `content-hash:`, `keyword:`, and `ref:` labels.
- Calls: `CardKind::from_str()`, `CardBox::from_str()`, `parse_ref_label()`, `is_valid_native_trunk()`.
- Called by: `insert_card()`, `import_beads_box_into_conn()`.
- Research finding: There is no `scope:` parsing yet. `ref:` labels carry `requires_review`, but importer currently inserts all parsed refs directly rather than preserving a proposed/pending state.

### `import_beads_box()` and `import_beads_box_into_conn()`

- UUIDs:
  - `6869a633-adab-5d72-b7b6-25073d80f02f` for `import_beads_box()`
  - `0b394571-85f3-52f3-930c-06388faec490` for `import_beads_box_into_conn()`
- File: `apps/silmari_memory_rust/src/importer.rs:23`
- Role: Imports a beads-shaped SQLite database into the native card schema.
- Calls: `init_schema()`, `Connection::open()`, `ensure_table()`, `read_labels()`, `parse_labels()`, `insert_card()`, `insert_edge()`, `upsert_keyword_entry()`, `import_block_dependencies()`, `import_keyword_entries()`.
- Called by: CLI `run()` through `Command::ImportBeads`.
- Research finding: The source database is opened with normal `Connection::open()`, the target is initialized in place, and there is no snapshot, read-only source connection, staging database, manifest, validation report, rollback, or `--replace` safety protocol. Deleted, ephemeral, template, and `status=deleted` issues are skipped.

### `import_block_dependencies()`

- UUID: `12357492-97e3-5572-9b87-35012c41a0da`
- File: `apps/silmari_memory_rust/src/importer.rs:249`
- Role: Imports `dependencies` rows where `type = 'blocks'`.
- Calls: `table_exists()`, `EdgeType::from_str()`, `insert_edge()`.
- Called by: `import_beads_box_into_conn()`.
- Research finding: Direction matches the existing viewer convention: `issue_id` is the source/blocking card and `depends_on_id` is the target/blocked card.

### `import_keyword_entries()`

- UUID: `0c3fed87-ee36-561f-94ad-28ad8cc6e0a2`
- File: `apps/silmari_memory_rust/src/importer.rs:274`
- Role: Imports existing `keyword_entries` rows.
- Calls: `serde_json::from_str()`, `upsert_keyword_entry()`.
- Called by: `import_beads_box_into_conn()`.
- Research finding: `entry_points` are preserved from source JSON. The plan's compat boundary must decide whether public payloads use snake_case source shape or camelCase Rust structs.

### `run()`

- UUID: `2a3e3b3d-c5c6-5be8-a92f-181d0c84d824`
- File: `apps/silmari_memory_rust/src/cli.rs:159`
- Role: Parses CLI args and emits JSON for `init`, `import-beads`, `recall`, `neighborhood`, `edges`, and `line-of-thought`.
- Calls: `Cli::try_parse_from()`, `execute()`, `print_json()`, `print_error()`.
- Called by: Rust binary entrypoint.
- Research finding: Success outputs are raw command values, while errors are `{error:{code,message,details}}` without a top-level `ok:false`. Read commands use `Connection::open(db)`, which can create a missing database. The plan's `NativeEnvelope` and open policy are necessary compatibility contracts, not polish.

### `recall()`, `line_of_thought()`, and `line_of_thought_at_address()`

- UUIDs:
  - `3916704b-9956-5d24-a69a-a55b0b82ef63` for `recall()`
  - `d7d88c14-71b9-524e-a78a-7289aa82bec5` for `line_of_thought()`
  - `8a8af46f-60ab-563e-954d-b8c5ff839acb` for `line_of_thought_at_address()`
- File: `apps/silmari_memory_rust/src/retrieval.rs:123`
- Role: Provides native retrieval and line-of-thought payloads.
- Calls: keyword lookup, card hydration, neighborhood and cross-ref traversal helpers.
- Called by: CLI `run()` and future native facade.
- Research finding: Rust structs use serde camelCase for several payloads, while existing SAI hook code reads `entry_points` from the TS keyword index. This mismatch must be covered by runtime fixtures before changing the facade.

## MCP TypeScript Compatibility

### `brCreate()`

- UUID: `1ff54aa0-7323-5e66-a49b-b4fdc4c25bee`
- File: `apps/silmari-mcp/src/lib/br-adapter.ts:187`
- Role: Creates one bead through `br create` and returns the ID or `null`.
- Calls: `ensureBoxWorkspace()`, `baseFlags()`, `execFileSync()`, `JSON.parse()`.
- Called by: `saveCard()`, related card creation flows.
- Research finding: Failure semantics are intentionally lossy for callers: it logs and returns `null`. Native routing must preserve this behavior for the compatibility facade even if the Rust CLI returns typed errors.

### `brCreateBatch()`

- UUID: `ae7c4368-d3fa-50ee-8d26-5ede361186c9`
- File: `apps/silmari-mcp/src/lib/br-adapter.ts:260`
- Role: Creates N beads via one markdown import subprocess and returns IDs in input order.
- Calls: `ensureBoxWorkspace()`, `writeFileSync()`, `execFileSync()`, `JSON.parse()`, `unlinkSync()`.
- Called by: currently avoided by `saveCardsBatch()` because of known batch-path risk.
- Research finding: Native batch creation should provide true transactionality and ID-to-input alignment, but the facade cannot simply switch old call sites to a new batch path without reproducing the current error semantics.

### `brList()`

- UUID: `9e8c7ac9-fb5c-57f6-a3c5-b507b3b45b2e`
- File: `apps/silmari-mcp/src/lib/br-adapter.ts:368`
- Role: Lists beads with filters, sorting, status, labels, `all`, and timeout behavior.
- Calls: `ensureBoxWorkspace()`, `getDbFlag()`, `execFileSync()`, `JSON.parse()`.
- Called by: navigation, recall scans, consolidation and maintenance flows.
- Research finding: Most failures degrade to `[]`, but `ETIMEDOUT` throws `BrListTimeoutError`. The plan's facade tests need to preserve this split exactly. Sort direction documentation warns that `br list --sort` is descending by default and `--reverse` flips to ascending.

### `brSearch()`

- UUID: `03d60a50-8570-5530-b82a-0a72519a994a`
- File: `apps/silmari-mcp/src/lib/br-adapter.ts:416`
- Role: Full-text search wrapper used for biblio/catalog search, not idea-box navigation hot paths.
- Calls: `ensureBoxWorkspace()`, `getDbFlag()`, `execFileSync()`, `JSON.parse()`.
- Called by: biblio-oriented search callers.
- Research finding: Native compatibility should not accidentally route idea recall through text search. The plan should retain the biblio-only assumption.

### `brShow()`

- UUID: `cdf8a01b-5ee0-5a39-b5bf-f08e77c46944`
- File: `apps/silmari-mcp/src/lib/br-adapter.ts:457`
- Role: Shows one bead by exact ID.
- Calls: `ensureBoxWorkspace()`, `execFileSync()`, `JSON.parse()`, a retry helper.
- Called by: edge reads, navigation, SAI hook hydration, post-save checks.
- Research finding: It rejects fuzzy prefix matches and retries recoverable `ISSUE_NOT_FOUND`/`AMBIGUOUS_ID` once. Native read APIs must reproduce exact-ID behavior without depending on `br show` quirks.

### `saveCard()`

- UUID: `3487392d-db8a-5327-ab2c-b81638334d6b`
- File: `apps/silmari-mcp/src/lib/card-ops.ts:786`
- Role: High-level card creation flow.
- Calls: address assignment/preflight helpers, `brCreate()`, `runPostSaveSteps()`, `brSync()`.
- Called by: MCP tool dispatch and cascade save flows.
- Research finding: The native create path must preserve preflight ordering, especially explicit `fromAddress` validation before dedupe, folgezettel assignment, and post-save edge/keyword hooks.

### `saveCardsBatch()`

- UUID: `decd400a-2d2b-598d-acef-e5e46d13f7bb`
- File: `apps/silmari-mcp/src/lib/card-ops.ts:948`
- Role: Saves multiple cards while preserving current per-card semantics.
- Calls: currently loops through single-card creation behavior rather than relying on `brCreateBatch()`.
- Called by: cascade/card batch workflows.
- Research finding: The new native batch API should be a real store transaction, but the migration must explicitly test alignment, partial failure, and post-save hook behavior rather than assuming the existing TS batch helper is safe to route wholesale.

### `runPostSaveSteps()`

- UUID: `42d22bf8-effc-591b-b654-328f120e0e0a`
- File: `apps/silmari-mcp/src/lib/card-ops.ts:551`
- Role: Runs duplicate sweep, Tier A edge extraction, body-hash recurrence, keyword writes, and L4 anchor checks after a card is created.
- Calls: edge helpers, label helpers, keyword writers, duplicate/consolidation helpers.
- Called by: `saveCard()` and batch save flow.
- Research finding: This function is the real compatibility boundary for live writes. Replacing only `brCreate()` without porting post-save behavior would pass simple CRUD tests while losing memory graph semantics.

### `addEdge()`

- UUID: `56a8d647-39f2-5305-a597-7f4de79914a6`
- File: `apps/silmari-mcp/src/lib/edges.ts:76`
- Role: Low-level direct edge write helper.
- Calls: `refLabel()`, `brLabelAdd()`, and `brDepAdd()` for `blocks`.
- Called by: `proposeOrAddEdge()` for auto edges and older direct callers.
- Research finding: It unconditionally writes the label for every edge type, including reviewed edge types if called directly. This is the concrete source of the reviewed-edge authority conflict flagged in the plan review.

### `proposeOrAddEdge()`

- UUID: `943ec4bf-9848-514a-90ef-e0118546c5fb`
- File: `apps/silmari-mcp/src/lib/edges.ts:403`
- Role: Routes auto edge types to `addEdge()` and reviewed edge types to proposal queue.
- Calls: `edgeRequiresReview()`, `proposeLink()`, `addEdge()`.
- Called by: agent-facing edge creation flows.
- Research finding: `EdgeWriteAuthority` should make this policy impossible to bypass in native writes. Tests should assert both old direct-call behavior and new native authority behavior so the migration is deliberate.

### `lookupKeyword()`, `lineOfThought()`, and `loadRecallScan()`

- UUIDs:
  - `f69c0e96-95cf-5716-8a40-6eb9705e3f5d` for `lookupKeyword()`
  - `63352abf-32f1-5e5e-8297-0dfac1ab5654` for `lineOfThought()`
  - `061bdb06-78d2-5fac-b0ff-1ea29fa30864` for `loadRecallScan()`
- Files:
  - `apps/silmari-mcp/src/lib/keyword-index.ts:253`
  - `apps/silmari-mcp/src/lib/line-of-thought.ts:187`
  - `apps/silmari-mcp/src/lib/navigate.ts:702`
- Role: Current retrieval and navigation compatibility layer.
- Calls: `brList()`, `brShow()`, keyword entry readers, neighborhood helpers.
- Called by: MCP tools and SAI hook imports.
- Research finding: `loadRecallScan()` currently performs a broad `brList({box:'idea', all:true, limit:10000})` scan. Native mode should replace this with indexed native queries, but contract tests must preserve output shape and sorting assumptions.

## Viewer and Export Compatibility

### `synthesizeEdgesFromLabels()`

- UUID: `d196bdde-ae6c-5c0c-a0fa-73c257898fa1`
- File: `apps/silmari-memory-card-viewer/server.ts:141`
- Role: Lazily creates `card_edges` in a viewer export and populates it from `ref:<type>:<target>` labels on `issues`.
- Calls: `Database()`, `db.exec()`, `db.prepare()`, `parseRefLabel()`, transaction commands.
- Called by: viewer refresh/server paths.
- Research finding: Current viewer compatibility is label-derived and idempotent. A native exporter can write `card_edges` directly, but must keep the same column names: `source`, `target`, `type`.

### `buildLinks()`

- UUID: `e43905e6-7d56-53ca-8d6c-565e7931c331`
- File: `apps/silmari-memory-card-viewer/viewer_assets/link-builder.js:17`
- Role: Merges `dependencies` and `card_edges` into force-graph links.
- Calls: no external code; pure function.
- Called by: graph rendering.
- Research finding: Link direction is source to target for both tables. `dependencies.issue_id -> dependencies.depends_on_id` and `card_edges.source -> card_edges.target` must remain aligned in native export tests.

### `CreateSchema()` and `CreateMaterializedViews()`

- UUIDs:
  - `86802258-7da3-586c-9148-e50d244b00ad` for `CreateSchema()`
  - `e7c8c497-9fa5-5804-95ef-54fa3e0a7ba2` for `CreateMaterializedViews()`
- File: `apps/silmari-viewer/pkg/export/sqlite_schema.go:16`
- Role: Defines the current static export schema and denormalized `issue_overview_mv`.
- Calls: `createCoreTables()`, `createMetricsTables()`, `createIndexes()`, `createMetaTable()`, SQL `Exec()`.
- Called by: Go export pipeline.
- Research finding: The viewer SPA queries `issues`, `dependencies`, `comments`, `export_meta`, `card_edges`, and `issue_overview_mv`. Native export must either reproduce this schema exactly or update the SPA and tests in the same slice.

## SAI Runtime Consumers

### `loadZkRecall()`

- UUID: `c1f41f77-c903-5c61-8c52-71e275512a98`
- File: `SAI/hooks/ThinkWithMemory.hook.ts:117`
- Role: Dynamically imports MCP internals and hydrates recurrence memory from keyword hits, card show, neighborhood, and edge walk.
- Calls: dynamic `import()` of `keyword-index.ts`, `br-adapter.ts`, `navigate.ts`, `labels.ts`; then `lookupKeyword()`, `brShow()`, `neighborhood()`, `parseFzFromLabels()`, `followEdges()`.
- Called by: Think-with-memory hook execution.
- Research finding: This is not using a stable public MCP API. It expects `hit.entry_points` in snake_case and directly couples to TS internals. The replacement needs either a public shim with this shape or an explicit SAI migration.

### `buildInjection()`

- UUID: `f740ed31-fc1d-5a1a-9bb4-08ba0baf612a`
- File: `SAI/hooks/lib/think-with-memory.ts:218`
- Role: Builds the text injected into the model from recall summary sections.
- Calls: formatting helpers over `keywordEntries`, `folgezettelNeighbors`, and `crossRefs`.
- Called by: Think-with-memory hook execution.
- Research finding: SAI only needs stable recurrence summary sections. The lowest-risk migration is to add a public `zkRecall`/native shim that feeds the current `RecallSummary` shape and test it against both old TS and native Rust payloads.

# Call Graph

The replacement-critical flow is:

```text
MCP save path
saveCard()
  -> brCreate()
  -> runPostSaveSteps()
     -> addEdge() / proposeOrAddEdge()
     -> keyword/index maintenance
     -> brSync()

MCP list/show path
brList()
brShow()
  -> navigation, recall scan, edge reads, SAI hydration

Rust native import path
run()
  -> import_beads_box()
     -> init_schema()
     -> import_beads_box_into_conn()
        -> read_labels()
        -> parse_labels()
        -> insert_card()
        -> insert_edge()
        -> upsert_keyword_entry()
        -> import_block_dependencies()
        -> import_keyword_entries()

Rust native retrieval path
run()
  -> recall()
  -> line_of_thought()
  -> line_of_thought_at_address()

Viewer path
CreateSchema()
CreateMaterializedViews()
  -> viewer queries issue_overview_mv/issues/dependencies/card_edges/export_meta
synthesizeEdgesFromLabels()
  -> card_edges(source,target,type)
buildLinks()
  -> graph links(source,target,type)

SAI path
loadZkRecall()
  -> lookupKeyword()
  -> brShow()
  -> neighborhood()
  -> followEdges()
  -> buildInjection()
```

# Findings

## 1. Schema v2 migration cannot be a patch to `init_schema()` alone

`init_schema()` is currently a v1 idempotent creator, not a migration framework. It uses `CREATE TABLE IF NOT EXISTS` and `INSERT OR IGNORE` for version rows. Adding columns into this function without a real migration path would leave existing v1 databases silently missing fields such as `status`, `priority`, `scope`, `deleted_at`, `card_trunks`, cursors, edge review metadata, and events.

Required plan addition:

- Add a real `migration.rs` or equivalent migration module.
- Add tests that create a literal v1 database fixture first, then open it with the v2 code.
- Assert both DDL and `schema_versions` row updates.
- Assert idempotent second open.
- Assert future-version rejection still works.

## 2. Domain row types and compatibility payloads must split before adding lifecycle fields

`Card` is currently both a native row model and a retrieval payload member. Retrieval structs use serde camelCase in several places, while current SAI code expects snake_case `entry_points` from TS internals. Adding fields directly to `Card` will leak v2 lifecycle columns into recall/neighborhood payloads unless the implementation introduces separate row and wire DTOs.

Required plan addition:

- Use a native row/domain type for SQLite CRUD.
- Use explicit compat DTOs for `br-adapter.ts` and CLI output.
- Use retrieval DTOs that preserve current public JSON shapes.
- Add serialization snapshot tests in Rust and TS.

## 3. Edge authority is split today and must become explicit

The Rust model knows `AUTO` and `REVIEWED` edge classes, and parsed refs can identify `requires_review`. But `insert_edge()` and importer call sites do not enforce that boundary. In TypeScript, `proposeOrAddEdge()` enforces review routing, while `addEdge()` can still write reviewed edges directly.

Required plan addition:

- Introduce an `EdgeWriteAuthority` boundary for native writes.
- Preserve existing TS direct-call semantics only behind the compatibility facade where required.
- Add tests proving reviewed edge labels from import do not become live reviewed edges unless the migration policy says so.
- Add tests proving native agent writes queue reviewed edges and directly apply only auto edges.

## 4. CLI contracts need both envelopes and file open policy

The current Rust CLI prints raw JSON values for success and an error-only object for JSON errors. It opens read databases with `Connection::open(db)`, which can create a missing file. That is incompatible with a safe native facade where read commands must fail if the database does not exist and write commands must be explicit.

Required plan addition:

- Define `NativeEnvelope<T> = { ok: true, data: T } | { ok: false, error: { code, message, details } }`.
- Add command-specific open modes: create/init, read-only existing, read-write existing, migration staging.
- Test missing DB behavior for every read command.
- Test malformed JSON/parse failure handling at the TS facade boundary.

## 5. Migration import needs snapshot, staging, validation, and rollback

`import_beads_box()` currently initializes the target in place and opens source/target directly. There is no source snapshot, manifest, dry run, staging database, replacement guard, rollback, or validation report. The review's `--replace` safety concern is valid.

Required plan addition:

- Implement `snapshot_source()` using SQLite backup or file-copy semantics that preserve WAL consistency.
- Open source snapshots read-only.
- Write into a staging native DB first.
- Validate counts, edge referential integrity, keyword JSON, required labels, and viewer-export compatibility.
- Replace target atomically only after validation passes.
- Emit a migration report manifest that tests can assert.

## 6. The TS facade is the migration boundary, not just a wrapper file

`br-adapter.ts` encodes non-obvious behavior: `brCreate()` logs and returns `null`, `brList()` returns `[]` for most errors but throws `BrListTimeoutError` on timeout, `brShow()` rejects fuzzy matches and retries selected structured misses, and `brSearch()` is intentionally biblio-oriented. A native adapter must match those behaviors before call sites route to it.

Required plan addition:

- Add a `native-adapter.ts` behind the existing `br-adapter.ts` exports.
- Add routing tests that cover every exported function used by card, edge, keyword, navigation, and SAI flows.
- Assert legacy and native mode shapes for representative success and failure cases.
- Preserve `BrListTimeoutError`.

## 7. Viewer export compatibility is a hard contract

The SPA expects the current Go-export-shaped SQLite schema. `buildLinks()` proves directionality: `dependencies.issue_id -> dependencies.depends_on_id` and `card_edges.source -> card_edges.target`. `synthesizeEdgesFromLabels()` proves current edge table names and idempotent behavior.

Required plan addition:

- Build native export tests against the actual viewer query set.
- Include `issue_overview_mv` and `export_meta` in the native exporter.
- Include `card_edges(source,target,type)` directly rather than relying on server-side synthesis for native exports.
- Add link-builder regression tests using native export rows.

## 8. SAI is already coupled to MCP internals

`loadZkRecall()` imports TS files by path and reads `hit.entry_points`. It does not call a stable MCP server API. The plan's SAI phase must treat this as an integration surface, not just a consumer update.

Required plan addition:

- Add a public recall shim with the current `RecallSummary` shape.
- Test the shim with existing TS-backed data and native Rust-backed data.
- Preserve `buildInjection()` inputs: `keywordEntries`, `folgezettelNeighbors`, and `crossRefs`.

# Proposed Changes to the Plan

1. Make schema v2 the first executable gate.
   - Implement v1 fixture creation and v1-to-v2 migration before facade routing.
   - Tie tests directly to `init_schema()` and the new migration module.

2. Define serialization boundaries before adding fields.
   - Add explicit Rust row, compat, and retrieval DTOs.
   - Add TS facade DTOs that preserve `br` output shapes.

3. Add an edge authority module before porting edge writes.
   - Model allowed auto writes, reviewed proposals, import-preserved proposals, and human-approved reviewed writes separately.

4. Replace importer behavior with a migration workflow.
   - Snapshot source, stage target, validate, report, and atomically replace only with an explicit `--replace`.

5. Implement native CLI contracts before TS routing.
   - Add stable envelopes and open policies so TS can distinguish missing DB, parse errors, empty results, and timeouts.

6. Route through existing `br-adapter.ts` exports only.
   - Do not migrate call sites by importing new native internals directly.
   - Use mode selection and shadow comparison under the facade.

7. Treat viewer export as a schema fixture.
   - Native exporter must satisfy the viewer SPA query set, not merely export card rows.

8. Treat SAI as a first-class runtime contract.
   - The current hook imports internals; add a stable shim before removing legacy paths.

# CW9 Mention Summary

Functions to mention:

- `init_schema()`
- `insert_card()`
- `insert_edge()`
- `parse_labels()`
- `import_beads_box()`
- `import_beads_box_into_conn()`
- `import_block_dependencies()`
- `import_keyword_entries()`
- `run()`
- `recall()`
- `line_of_thought()`
- `line_of_thought_at_address()`
- `brCreate()`
- `brCreateBatch()`
- `brList()`
- `brSearch()`
- `brShow()`
- `saveCard()`
- `saveCardsBatch()`
- `runPostSaveSteps()`
- `addEdge()`
- `proposeOrAddEdge()`
- `lookupKeyword()`
- `lineOfThought()`
- `loadRecallScan()`
- `synthesizeEdgesFromLabels()`
- `buildLinks()`
- `CreateSchema()`
- `CreateMaterializedViews()`
- `loadZkRecall()`
- `buildInjection()`

Files to mention:

- `apps/silmari_memory_rust/src/schema.rs`
- `apps/silmari_memory_rust/src/store.rs`
- `apps/silmari_memory_rust/src/model.rs`
- `apps/silmari_memory_rust/src/labels.rs`
- `apps/silmari_memory_rust/src/importer.rs`
- `apps/silmari_memory_rust/src/retrieval.rs`
- `apps/silmari_memory_rust/src/cli.rs`
- `apps/silmari-mcp/src/lib/br-adapter.ts`
- `apps/silmari-mcp/src/lib/card-ops.ts`
- `apps/silmari-mcp/src/lib/edges.ts`
- `apps/silmari-mcp/src/lib/keyword-index.ts`
- `apps/silmari-mcp/src/lib/line-of-thought.ts`
- `apps/silmari-mcp/src/lib/navigate.ts`
- `apps/silmari-memory-card-viewer/server.ts`
- `apps/silmari-memory-card-viewer/viewer_assets/link-builder.js`
- `apps/silmari-memory-card-viewer/viewer_assets/viewer.js`
- `apps/silmari-viewer/pkg/export/sqlite_schema.go`
- `SAI/hooks/ThinkWithMemory.hook.ts`
- `SAI/hooks/lib/think-with-memory.ts`

Directories to mention:

- `apps/silmari_memory_rust/src/`
- `apps/silmari-mcp/src/lib/`
- `apps/silmari-memory-card-viewer/`
- `apps/silmari-memory-card-viewer/viewer_assets/`
- `apps/silmari-viewer/pkg/export/`
- `SAI/hooks/`
