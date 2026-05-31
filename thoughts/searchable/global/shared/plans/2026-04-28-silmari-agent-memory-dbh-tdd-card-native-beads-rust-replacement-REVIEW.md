---
date: 2026-04-28T06:27:11-04:00
reviewer: Codex
plan_under_review: thoughts/searchable/shared/plans/2026-04-28-silmari-agent-memory-dbh-tdd-card-native-beads-rust-replacement.md
review_type: pre_implementation_contract_review
status: needs_major_revision
related_beads_issues:
  - silmari-agent-memory-dbh
  - silmari-agent-memory-32d
  - silmari-agent-memory-7jo
  - silmari-agent-memory-j8v
tags: [review, tdd, plan, rust, sqlite, beads-rust, migration, mcp, viewer, contracts]
---

# Plan Review Report: Card-Native beads_rust Replacement

## Review Summary

| Category | Status | Issues Found |
|----------|--------|--------------|
| Contracts | Critical | 7 issues, 4 blocking |
| Interfaces | Critical | 6 issues, 3 blocking |
| Promises | Critical | 7 issues, 4 blocking |
| Data Models | Critical | 7 issues, 4 blocking |
| APIs | Critical | 8 issues, 4 blocking |

**Approval Status:** **Needs Major Revision**. The plan is directionally strong and grounded in the new specs, but it still leaves multiple implementation-defining contracts open. Several gaps would let a reasonable implementer choose behavior that violates existing MCP, viewer, SAI, or migration safety guarantees.

Tracking issue for these findings: `silmari-agent-memory-j8v`.

---

## Critical Issues

### C-1. v1-to-v2 schema handling is not pinned by a failing test

**Plan location:** Behavior 1, especially `schema_v2.rs` empty-DB test at plan lines 178-204 and migration note at line 214.

**Evidence:**

- Current schema version is still `SUPPORTED_SCHEMA_VERSION = 1` in `apps/silmari_memory_rust/src/schema.rs:7`.
- Current init only rejects future versions at `apps/silmari_memory_rust/src/schema.rs:41`.
- Current DDL uses `CREATE TABLE IF NOT EXISTS` at `apps/silmari_memory_rust/src/schema.rs:55`, so existing v1 tables would not gain v2 columns.
- Current version rows are inserted with `INSERT OR IGNORE` at `apps/silmari_memory_rust/src/schema.rs:123`, so old rows can remain unchanged after a version bump.

**Impact:** A developer can bump `SUPPORTED_SCHEMA_VERSION`, pass the empty-DB test, and silently leave upgraded v1 databases without `status`, `priority`, `scope`, `deleted_at`, event tables, or review metadata. That is a data loss and cutover blocker.

**Recommendation:**

- Add a red test that creates a real v1 DB, runs v2 init or migration, and asserts either a complete v2 upgrade or a typed `SchemaCompatibility` rejection.
- Define the allowed transition explicitly: `migrate_v1_to_v2`, `reject_v1_without_migration`, or `import-to-new-db-only`.
- Assert `schema_versions` rows update to v2 for every v2 table and cannot remain stale.

---

### C-2. Reviewed edge semantics conflict across import, create, and edge-add

**Plan location:** Behavior 2 lines 269, 277-278; Behavior 3 lines 383 and 447; Behavior 4 line 489.

**Evidence:**

- Current Rust `EdgeType::requires_review()` marks `supports`, `contradicts`, `extends`, `reinforces`, and `refines` as reviewed at `apps/silmari_memory_rust/src/model.rs:180`.
- Current importer commits all parsed `ref:*` labels directly with `insert_edge` at `apps/silmari_memory_rust/src/importer.rs:97`.
- Current TypeScript `addEdge` writes any edge directly at `apps/silmari-mcp/src/lib/edges.ts:59` and `apps/silmari-mcp/src/lib/edges.ts:91`.
- Current TypeScript default path `proposeOrAddEdge` routes reviewed edges to proposals at `apps/silmari-mcp/src/lib/edges.ts:403`.
- Body-hash recurrence deliberately bypasses review for `reinforces` at `apps/silmari-mcp/src/lib/card-ops.ts:188` and emits at `apps/silmari-mcp/src/lib/card-ops.ts:620`.
- The API spec says reviewed edge types require proposal acceptance unless the caller is an explicit commit path at `artifacts/specs/2026-04-28-beads-rust-replacement/03-store-api-and-adapter.md:246`.

**Impact:** The implementation can incorrectly put imported reviewed labels into `card_edges`, incorrectly turn all reviewed `edge-add` calls into proposals, or incorrectly block body-hash recurrence. The plan does not define which paths are accepted evidence, pending proposals, warnings, or forced commits.

**Recommendation:**

- Define an `EdgeWriteAuthority` or equivalent input: `auto`, `proposal`, `accepted-proposal`, `body-hash-recurrence`, `imported-legacy`.
- For legacy import, decide whether reviewed `ref:*` labels become `card_edges(review_state='reviewed')`, `edge_proposals(status='accepted')`, or warnings requiring manual review.
- Add tests for all three paths: normal reviewed edge creates proposal, accepted proposal commits edge, body-hash recurrence commits `reinforces` with `review_state='reviewed'`.

---

### C-3. Rust domain model vs compatibility serialization boundary is unclear

**Plan location:** Desired state lines 98-110; Behavior 4 lines 478-490; Behavior 9 lines 1033-1045.

**Evidence:**

- Current `Card` lacks `status`, `priority`, `scope`, and `deleted_at` at `apps/silmari_memory_rust/src/model.rs:255`.
- Current retrieval serializes `RecallSession` with `Vec<Card>` directly at `apps/silmari_memory_rust/src/retrieval.rs:61`.
- Current CLI serializes retrieval results directly at `apps/silmari_memory_rust/src/cli.rs:231`.
- v2 schema requires those lifecycle fields at `artifacts/specs/2026-04-28-beads-rust-replacement/02-native-data-model.md:80`.

**Impact:** If v2 fields are added to `Card`, current MCP-facing recall and neighborhood payloads may leak new fields and drift from existing snapshots. If they are not added, CRUD/list/tombstone semantics cannot be represented. This is not just an implementation detail; it defines the external contract.

**Recommendation:**

- Split `CardRow` or `NativeCard` from compatibility payload types.
- Define serializers for `show-card`, `list-cards`, `recall`, `neighborhood`, `line-of-thought`, and viewer export separately.
- Add snapshot tests that confirm retrieval payload casing and fields remain stable while CRUD/list can expose lifecycle fields.

---

### C-4. JSON CLI envelope and DB-open policy are underspecified

**Plan location:** Behavior 11 lines 1237-1247 and red test lines 1257-1264.

**Evidence:**

- Current CLI success path prints raw values, not an `{ok:true,...}` envelope, at `apps/silmari_memory_rust/src/cli.rs:180`.
- Current error envelope omits `ok:false` at `apps/silmari_memory_rust/src/cli.rs:135`.
- Current parse errors use lowercase-ish code strings through `print_error("cli_parse", ...)` at `apps/silmari_memory_rust/src/cli.rs:172`.
- Current commands open SQLite paths directly at `apps/silmari_memory_rust/src/cli.rs:223`; `Connection::open` can create a missing DB file.
- The red test expects `show-card --db /tmp/missing-native.db` to return `CARD_NOT_FOUND`, but that command could create an empty DB unless the plan says otherwise.

**Impact:** The TypeScript facade cannot reliably map Rust errors to `null`, `false`, `[]`, or `BrListTimeoutError`. Worse, probing a missing DB could mutate disk and then report the wrong failure class.

**Recommendation:**

- Define a single `NativeEnvelope<T> = { ok: true, result: T } | { ok: false, error: NativeError }`.
- Define open modes per command: read-only existing DB for reads, create-if-missing only for `init`, explicit target creation for import/export.
- Add an `ErrorCode` enum with stable strings: `CARD_NOT_FOUND`, `QUERY_TIMEOUT`, `VALIDATION_ERROR`, `SCHEMA_INCOMPATIBLE`, `DB_NOT_FOUND`, `CLI_PARSE`.
- Fix the red test to distinguish missing DB from missing card, or state that `show-card` creates schema before lookup and then returns `CARD_NOT_FOUND`.

---

### C-5. TypeScript native facade interface and routing are not concrete enough

**Plan location:** Behavior 7 lines 879 and 883-897.

**Evidence:**

- Current call sites import `br-adapter.ts` directly from MCP code, including `apps/silmari-mcp/src/index.ts:25` and `apps/silmari-mcp/src/lib/card-ops.ts:26`.
- The plan sketches `mapNativeResult<T>` but does not define `NativeOperation`, `NativeEnvelope`, mode flag source, per-method facade signatures, or how existing imports are routed.
- Runtime modes are specified in `artifacts/specs/2026-04-28-beads-rust-replacement/01-system-architecture.md:85`, but the plan only lists manual shadow-read/write steps at lines 1326 and 1328.

**Impact:** The implementation can add `native-adapter.ts` while leaving existing code on `br-adapter.ts`, or route only some calls through native mode. Shadow parity then becomes partial and misleading.

**Recommendation:**

- Add a concrete `SilmariMemoryAdapter` interface with every method in the replacement matrix.
- Define mode resolution: env var, config file, test override, and default.
- Define the migration path for imports: either all call sites import the facade, or `br-adapter.ts` becomes the mode switch while preserving exported names.
- Add a smoke test that toggles native mode and verifies `saveCard`, `saveCardsBatch`, `zk_block`, `zk_recall`, and `silmari://card/<id>` all cross the facade.

---

### C-6. Migration snapshot and `--replace` safety are missing from the TDD plan

**Plan location:** Behavior 6 lines 725-782.

**Evidence:**

- The migration spec requires a read-only timestamped snapshot command at `artifacts/specs/2026-04-28-beads-rust-replacement/04-migration-cutover-and-verification.md:109`.
- The same spec requires snapshot idempotence at `artifacts/specs/2026-04-28-beads-rust-replacement/04-migration-cutover-and-verification.md:115`.
- The architecture spec requires copying Beads DBs before import at `artifacts/specs/2026-04-28-beads-rust-replacement/01-system-architecture.md:128`.
- Data safety rules require a new DB path unless `--replace` is explicit, and `--replace` must require an existing snapshot at `artifacts/specs/2026-04-28-beads-rust-replacement/04-migration-cutover-and-verification.md:279`.
- The plan starts with “Given: a timestamped snapshot” at line 725 and the red test only uses `replace: false` at line 762.

**Impact:** A migration implementation can be built that imports from live sources, mutates/replaces a target without a verified snapshot, or treats snapshot creation as manual operator discipline. That violates the reversible cutover promise.

**Recommendation:**

- Add Behavior 6a for snapshot creation: input source paths, output manifest, file hashes, idempotence, read-only source access.
- Add tests for `replace=false`, `replace=true without snapshot` failure, and `replace=true with snapshot` success.
- Require all reports to include source paths/hashes, target DB path, git commit, started/finished timestamps, counts, mismatch counts, and representative mismatches.

---

### C-7. Viewer compatibility export is table-name only, not schema-compatible

**Plan location:** Behavior 10 lines 1137-1183.

**Evidence:**

- Current viewer list/filter paths query `issue_overview_mv` at `apps/silmari-memory-card-viewer/viewer_assets/viewer.js:981`.
- Current graph load selects fixed `issues` columns at `apps/silmari-memory-card-viewer/viewer_assets/viewer.js:1070`.
- Current graph reads compatibility `card_edges(source,target,type)` at `apps/silmari-memory-card-viewer/viewer_assets/viewer.js:1104`, matching server schema at `apps/silmari-memory-card-viewer/server.ts:125`.
- Current dependency detail treats `dependencies.issue_id` as the blocked/dependent card and `depends_on_id` as what it depends on at `apps/silmari-memory-card-viewer/viewer_assets/viewer.js:1895`.
- Current export metadata is key/value `export_meta` read at `apps/silmari-memory-card-viewer/viewer_assets/viewer.js:1884`, while the Go exporter writes keys like `version` and `schema_version` at `apps/silmari-viewer/pkg/export/sqlite_export.go:460`.
- The plan’s red test only asserts table names at line 1167.

**Impact:** The Rust export can pass the planned test while producing a cache the current viewer cannot query, misreads edge direction from, or cannot version-check.

**Recommendation:**

- Add a compatibility export contract table listing required columns, types, defaults, JSON encodings, and metadata keys for `issues`, `dependencies`, `issue_overview_mv`, `issues_fts`, `export_meta`, and `card_edges`.
- Pin `blocks` direction: native `card_edges(source_id=A,target_id=B,edge_type='blocks')` exports `dependencies.issue_id=A, depends_on_id=B, type='blocks'`.
- Pin casing boundary: compatibility `card_edges(source,target,type)`; card-native `viewer_edges(source_id,target_id,edge_type,review_state,created_at)`.
- Add a test that actually runs current viewer queries, not only table-existence checks.

---

### C-8. SAI consumer reality contradicts the MCP-only claim

**Plan location:** Current-state note line 65; Integration scenario line 1319.

**Evidence:**

- The consumer spec says SAI calls MCP and receives unchanged tool results at `artifacts/specs/2026-04-28-beads-rust-replacement/05-viewer-export-and-consumers.md:64`.
- Current SAI hook dynamically imports MCP internals at `SAI/hooks/ThinkWithMemory.hook.ts:130`.
- It reads `hit.entry_points` snake_case directly at `SAI/hooks/ThinkWithMemory.hook.ts:149`.
- The plan says parity must cover key casing, but does not require removing or adapting the direct import path.

**Impact:** Native-primary can preserve MCP tool JSON while breaking SAI, because SAI bypasses the tool layer and reads internal TypeScript module shapes. This is a cutover blocker unless intentionally audited.

**Recommendation:**

- Add an explicit SAI audit/remediation behavior: remove direct imports, wrap them behind the MCP tool, or preserve the internal module shape until a second migration.
- Add a fixture that runs `ThinkWithMemory.hook.ts` against native mode and validates `entryCards`, `folgezettelNeighbors`, `keywordEntries`, and `crossRefs`.
- Decide whether Rust keyword output must support both camelCase MCP and snake_case internal TS compatibility during transition.

---

## Contract Review

### Well-Defined

- The top-level component boundary is clear: Rust owns durable state; TypeScript owns MCP schemas, process-boundary handling, and compatibility payload shaping (`plan:81-110`).
- Current `br-adapter` observables are explicitly enumerated in the compatibility table (`plan:98-110`).
- Label and edge vocabulary is mostly carried forward, including all 12 edge types and the AUTO/REVIEWED split (`plan:265-278`).
- Migration field disposition is much stronger than the prior plan and lists every significant Beads field (`plan:675-721`).
- Viewer export explicitly keeps issue-shaped compatibility export until the card-native viewer has shipped through one dual-mode release (`plan:112-118`).

### Missing Or Unclear

- The v1-to-v2 schema contract says “migrate or reject” but tests only empty DB init.
- Error contracts are not aligned between Rust enum variants, JSON codes, and TypeScript compatibility mapping.
- Reviewed-edge authority is not normalized across import, direct `edge-add`, proposal commit, and recurrence.
- `fromAddress` timeout vs genuine missing parent is required by parity (`plan:944`) but current direct SQLite path has no timeout channel.
- `brShow` recoverable-miss retry is not listed as an observable, even though current code retries after 100ms at `apps/silmari-mcp/src/lib/br-adapter.ts:520`.

### Recommendations

- Add a “contract matrix” with one row per public operation: Rust function, CLI command, JSON success payload, JSON error codes, facade mapping, retry/timeout behavior, event rows.
- Treat “compatibility facade output” and “native CLI direct output” as separate contracts; they deliberately have different error and field surfaces.

---

## Interface Review

### Well-Defined

- The Rust module split proposed by the plan matches the existing crate shape.
- Store APIs have concrete names and rough signatures for schema, create, CRUD, batch, import, retrieval, and export.
- The adapter replacement matrix in the spec covers every current low-level `br-adapter.ts` function, including `brDepList`, `brLabelAdd`, and `brLabelRemove`.

### Missing Or Unclear

- `search-biblio` is required by the API spec at `artifacts/specs/2026-04-28-beads-rust-replacement/03-store-api-and-adapter.md:60` and mapped at line 259, but Behavior 4 omits it from codepath/mapping at plan lines 467 and 473.
- Behavior 11’s title says “mode commands,” but its tests cover only health/schema/error envelope.
- `line_of_thought_at_address` is listed in the codepath ref at plan line 1022, but the red test only covers card-id lookup at line 1070. Prior review required the address variant at `thoughts/searchable/shared/plans/2026-04-27-tdd-silmari-memory-rust-retrieval-substrate-REVIEW.md:207`.
- `allowOrphan` event semantics are not exposed through current MCP schemas (`apps/silmari-mcp/src/index.ts:109`, `apps/silmari-mcp/src/index.ts:137`) even though the native plan wants an `orphan.allowed` event at lines 384 and 447.
- `NativeOperation`, `NativeEnvelope`, mode flags, direct CLI spawn policy, and facade method signatures are not defined.

### Recommendations

- Add concrete interface definitions for `CreateCardInput`, `CreateCardResult`, `ListCardsInput`, `NativeEnvelope`, `NativeError`, `ShadowCompareInput`, `ExportSummary`, and the TypeScript facade interface.
- Add a Behavior 4 or 11 subsection dedicated to `search-biblio`: exact command, direct-store search strategy, no idea-box recall leakage, and facade return shape.
- Add explicit mode configuration commands or remove “mode commands” from the Behavior 11 title and create a separate runtime-mode behavior.

---

## Promise Review

### Well-Defined

- Single create and batch create both promise transaction boundaries and event emission.
- Shadow-read/write says user-visible output remains legacy while parity report artifacts are written.
- Rollback keeps legacy Beads DBs through the first native-primary rollout.
- Retrieval promises exact keyword recall, no Beads `LIKE` search for idea recall, and tombstone exclusion by default.

### Missing Or Unclear

- Migration import does not specify transaction/staging semantics. Current importer writes row-by-row (`apps/silmari_memory_rust/src/importer.rs:65`, `apps/silmari_memory_rust/src/importer.rs:93`) and current store uses direct writes (`apps/silmari_memory_rust/src/store.rs:17`).
- Batch-create all-or-nothing conflicts with current TypeScript behavior, where `saveCardsBatch` currently performs per-card `brCreate` operations around `apps/silmari-mcp/src/lib/card-ops.ts:1038` and has no rollback after partial writes.
- Shadow-write cannot share a transaction across Beads and native DBs; the spec calls this out as an open question at `artifacts/specs/2026-04-28-beads-rust-replacement/04-migration-cutover-and-verification.md:308`, but the plan does not convert it into a concrete reconciliation protocol.
- Parent lookup timeout semantics are named in parity (`plan:944`) but the current direct SQLite helper collapses errors to empty results.
- Resource cleanup promises for temp files, snapshot directories, and rollback manifests are not specified.

### Recommendations

- Require migration to write into a new/staging DB and atomically promote only after reports pass, or explicitly document partial-state behavior.
- Add a reconciliation event for shadow-write mismatches with both legacy and native IDs, operation input hash, and replay instructions.
- Add timeout classification tests for `fromAddress`, list, show, and biblio search separately.

---

## Data Model Review

### Well-Defined

- The target native schema is card-native and avoids primary `issues` / `dependencies` tables.
- The plan preserves `card_labels` as durable compatibility data while projecting native fields.
- `blocks` is correctly treated as both a semantic edge and a dependency-compatible export.
- The Beads field disposition table is concrete enough to prevent most accidental issue-tracker leakage.

### Missing Or Unclear

- Edge referential integrity is not defined. Current `card_edges` has no foreign keys (`apps/silmari_memory_rust/src/schema.rs:88`), and `insert_edge` accepts missing source/target IDs (`apps/silmari_memory_rust/src/store.rs:64`). The architecture invariant says unresolved imported edges become warnings/events at `artifacts/specs/2026-04-28-beads-rust-replacement/01-system-architecture.md:147`.
- `scope:*` is promised by the plan at lines 267 and 320, but current `ParsedLabels` has no scope field at `apps/silmari_memory_rust/src/model.rs:239`, and Behavior 2’s red test does not exercise scope projection.
- Required indexes from the data model spec (`cards(box,status,updated_at)`, `cards(content_hash)`, `card_events(card_id,created_at)`) are not asserted in Behavior 1.
- Compatibility and card-native export metadata use different table/key shapes, but the plan does not define a version conversion.
- The direct body-hash recurrence exception is a new data-model rule not grounded as an explicit commit path in the specs.

### Recommendations

- Define foreign-key policy for `card_edges`: enforce for native writes; for import, route unresolved edges to warnings/proposals without inserting invalid rows.
- Add schema tests for required indexes, partial unique `fz_address` among non-deleted idea cards, and generated-label regeneration.
- Add a failing `scope:*` test to Behavior 2.

---

## API Review

### Well-Defined

- The command surface required by the specs is mostly named in the plan.
- `BrListTimeoutError` is preserved as an observable TypeScript distinction.
- `brShow` exact-ID behavior and structured-error rejection are called out in current-state analysis.
- `zk_block` text drift is identified as a required fix.

### Missing Or Unclear

- `brSearch` / `search-biblio` lacks concrete tests and implementation mapping beyond a mention.
- The CLI error envelope lacks a full code table and operation-specific mapping.
- The facade does not define whether `brSync` becomes a no-op, a native checkpoint/export command, or stays legacy-only during shadow modes.
- `zk_block` schema text is still wrong in code (`apps/silmari-mcp/src/index.ts:352`) and the plan only says to align it, not what test to add.
- Viewer compatibility export tests do not execute the current viewer query set.
- SAI hook compatibility is not tested against the actual direct-import code path.

### Recommendations

- Add adapter snapshot tests for every replacement matrix row in `03-store-api-and-adapter.md:250`.
- Add a `zk_block` schema/dispatcher test asserting the description and result both use canonical `blocks` direction.
- Add native-mode SAI and viewer smoke tests as required gates, not only manual verification.

---

## Suggested Plan Amendments

```diff
# Behavior 1: Schema V2 Initializes The Live Native Store
+ Add a red test that starts from a real v1 schema and asserts full v2 migration or typed rejection.
+ Assert required indexes and schema_versions rows for every v2 table.

# Behavior 2 / 4: Labels And Edge Tiers
+ Define EdgeWriteAuthority: auto, proposal, accepted-proposal, body-hash-recurrence, imported-legacy.
+ Add reviewed-edge tests for proposal, accepted commit, recurrence, and imported legacy refs.
+ Add scope label parsing/projection tests.

# Behavior 6: Migration
+ Add snapshot command behavior before import_snapshot.
+ Add --replace safety tests requiring an existing snapshot manifest.
+ Require staging/new target DB semantics or a single transaction with rollback.
+ Assert report fields, not just report file existence.

# Behavior 7: TypeScript Compatibility Facade
+ Define the full SilmariMemoryAdapter interface and mode resolution source.
+ Route existing br-adapter imports through the facade or make br-adapter itself the mode switch.
+ Preserve brShow retry and BrListTimeoutError mapping in tests.

# Behavior 9: Retrieval
+ Add line_of_thought_at_address test coverage.
+ Add payload snapshot tests proving native row lifecycle fields do not leak into MCP recall JSON.

# Behavior 10: Viewer Export
+ Add compatibility export column/type/default contract for issues, dependencies, issue_overview_mv, export_meta, and card_edges.
+ Pin blocks direction and edge column casing for compatibility vs card-native modes.
+ Execute current viewer queries against the exported cache.

# Behavior 11 / New Behavior: Runtime Modes
+ Define mode commands or config switch semantics for legacy-br, import-only, shadow-read, shadow-write, native-primary, and legacy-read-only.
+ Add rollback config-switch tests.
```

---

## Approval Status

- [ ] Ready for Implementation
- [ ] Needs Minor Revision
- [x] Needs Major Revision

Implementation should wait until the blocking items above are amended in the plan. The highest-risk fixes are schema migration, edge authority, CLI/facade envelope, migration safety, and viewer/SAI compatibility tests.
