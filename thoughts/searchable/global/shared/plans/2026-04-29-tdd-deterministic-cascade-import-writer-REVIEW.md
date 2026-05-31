---
date: 2026-04-29T07:10:00-04:00
reviewer: Codex
git_commit_reviewed: 6efca11c2d1a72b3e79cd2fb91036e8edb6c43ff
branch: main
repository: silmari-agent-memory
topic: "Plan review: deterministic cascade import writer"
tags: [review, plan-review, tdd, cascade-ingest, silmari-mcp, folgezettel]
status: needs_major_revision
post_review_resolution: "Blocking amendments applied in commit 1e0f214 via silmari-agent-memory-642"
plan: thoughts/searchable/shared/plans/2026-04-29-tdd-deterministic-cascade-import-writer.md
research: thoughts/searchable/shared/research/2026-04-29-deterministic-cascade-import-boundary.md
---

# Plan Review Report: Deterministic Cascade Import Writer

## Review Summary

| Category | Status | Issues Found |
|----------|--------|--------------|
| Contracts | CRITICAL | 4 critical, 1 warning |
| Interfaces | CRITICAL | 2 critical, 2 warnings |
| Promises | CRITICAL | 2 critical, 1 warning |
| Data Models | CRITICAL | 1 critical, 2 warnings |
| APIs | WARNING | 2 warnings |

Approval status: **Needs Major Revision**. The plan has the right architectural direction, but implementation should not start until the address allocation/cursor contract, structural edge contract, import report schema, import-only boundary, and partial-failure policy are made explicit.

Post-review update: blocker `silmari-agent-memory-642` was closed after this review by commit `1e0f214`, which amended the plan for the critical findings below. This report records the review of the pre-amendment plan at `6efca11c2d1a72b3e79cd2fb91036e8edb6c43ff`.

## Contract Review

### Well-Defined

- The plan correctly separates the cascade-specific import path from the general `saveCard` / `saveCardsBatch` path (`2026-04-29-tdd-deterministic-cascade-import-writer.md:19`, `2026-04-29-tdd-deterministic-cascade-import-writer.md:28`).
- The no-side-effect write boundary is clear for the row builder and writer: no `saveCard`, `saveCardsBatch`, `findByContentHash`, `sweepDuplicates`, keyword writes, or line-of-thought during import (`2026-04-29-tdd-deterministic-cascade-import-writer.md:52`, `2026-04-29-tdd-deterministic-cascade-import-writer.md:188`, `2026-04-29-tdd-deterministic-cascade-import-writer.md:303`).
- The low-level store primitives named by the plan exist. `brCreate` accepts title, labels, description, priority, and status (`apps/silmari-mcp/src/lib/br-adapter.ts:240`), and `brFlushOrThrow` is available as a flush boundary (`apps/silmari-mcp/src/lib/br-adapter.ts:693`).

### Missing or Unclear

- CRITICAL: The plan does not define who allocates `rootSequence`, who reserves it, or how the folgezettel cursor is advanced after bypassing `assignFolgezettel`. The plan says the root is caller-provided (`2026-04-29-tdd-deterministic-cascade-import-writer.md:164`), while the existing allocator updates the cursor inside `assignFolgezettel` (`apps/silmari-mcp/src/lib/folgezettel.ts:268`). A direct `brCreate` writer will not update `fz-cursors.json` unless the plan adds a cursor contract. That can produce duplicate roots or wrong subsequent `continue` / `fork` behavior after import.
- CRITICAL: The structural edge contract is under-specified. The planner records `parentKey` for every non-root card (`2026-04-29-tdd-deterministic-cascade-import-writer.md:92`), but existing structural semantics distinguish `fork -> branches` and `continue -> follows` (`apps/silmari-mcp/src/lib/edge-extractors.ts:91`). Sibling cards need predecessor information, not only tree parent information. The fake writer test only exercises `branches` (`2026-04-29-tdd-deterministic-cascade-import-writer.md:284`), so a writer that emits `branches` for all children could pass the plan while breaking the existing line-of-thought edge shape.
- CRITICAL: Import-only mode is not fully specified at the `main()` boundary. Existing `main()` creates a hub before per-transcript ingest (`scripts/kc-baker-pipeline-v2/ingest/ingest-cascade.ts:659`), and hub creation uses the normal `saveCard` path. Behavior 4 excludes `zk_hub_add_card` and `zk_keyword_add` (`2026-04-29-tdd-deterministic-cascade-import-writer.md:344`), but the smoke command uses `ingest-cascade.ts` directly (`2026-04-29-tdd-deterministic-cascade-import-writer.md:428`) and does not say whether `zk_hub_create` is disabled when `CASCADE_ENRICHMENT_MODE=off`.
- CRITICAL: The plan says a failed create throws and returns no partial success report (`2026-04-29-tdd-deterministic-cascade-import-writer.md:257`), but it does not define rollback, resume, cleanup, or retry semantics. Because the import deliberately skips duplicate lookup and sweep, rerunning after a mid-import failure can create duplicate cards with the same intended folgezettel labels.
- WARNING: The plan proposes direct use of helpers from `card-ops.ts` (`2026-04-29-tdd-deterministic-cascade-import-writer.md:213`). That module imports the normal save pipeline dependencies, including keyword index and line-of-thought (`apps/silmari-mcp/src/lib/card-ops.ts:61`, `apps/silmari-mcp/src/lib/card-ops.ts:63`). To preserve the import-only boundary, extracting `card-format.ts` should be required before the writer imports any formatting helpers.

### Recommendations

- Add a named allocator/commit contract, for example `reserveCascadeRoot(trunk): { rootSequence, reservedAt }` and `commitCascadeCursor(trunk, terminalSequence)`, or state that the writer calls `assignFolgezettel(trunk, "root")` once and then atomically commits the final planned cursor after successful flush.
- Add `mode` and `predecessorKey` to each planned card. Use `branches` for the first child fork and `follows` for same-parent continuations, matching `extractFolgezettelParent`.
- Treat `CASCADE_ENRICHMENT_MODE=off` as disabling hub creation, hub attach, keyword writes, line-of-thought, semantic proposal, and commit calls from `main()`, not just inside `ingestCascadeOne`.
- Define partial failure as one of: fail-fast fresh-store only, write a partial failure report with created IDs and require manual cleanup, or make reruns idempotent by checking existing `source`/`fz` labels before create.
- Make `card-format.ts` extraction a required phase before `buildImportRows`.

## Interface Review

### Well-Defined

- `planCascadeImport(args: PlanCascadeImportArgs): CascadeImportPlan` has a clear high-level intent and should be pure (`2026-04-29-tdd-deterministic-cascade-import-writer.md:159`).
- `writeCascadeImport(plan, deps = realDeps)` uses dependency injection for fake writer tests (`2026-04-29-tdd-deterministic-cascade-import-writer.md:266`), which fits the current pipeline unit-test style in `ingest-cascade.test.ts`.

### Missing or Unclear

- CRITICAL: `PlanCascadeImportArgs`, `CascadeImportPlan`, planned card row shape, writer dependency shape, and `ImportReport` are not defined as concrete TypeScript interfaces. The plan names them but never enumerates fields, required vs optional values, or map key formats.
- CRITICAL: The plan does not reconcile the new `ImportReport` with the existing `IngestReport`. Current downstream aggregation requires `basename`, `thesis_id`, `cards_saved`, and `gateB` (`scripts/kc-baker-pipeline-v2/extract/step8-aggregate.ts:15`) and dereferences `r.gateB.by_edge_type` and `r.gateB.edges_committed` (`scripts/kc-baker-pipeline-v2/extract/step8-aggregate.ts:94`). The plan says import produces `allIds` and `addressIdMap` (`2026-04-29-tdd-deterministic-cascade-import-writer.md:52`) but does not define whether `ingest-report.json` remains backward-compatible.
- WARNING: The test fixtures in the plan omit required fields from `ThemesFile`, `IdeasFile`, and `MicrosFile` such as `transcript`, `generated_at`, model fields, and source span IDs (`scripts/kc-baker-pipeline-v2/types/themes.ts:28`, `scripts/kc-baker-pipeline-v2/types/ideas.ts:25`, `scripts/kc-baker-pipeline-v2/types/micros.ts:31`). Existing tests sometimes do this, but this plan should define typed fixture builders if these new modules are intended to typecheck cleanly.
- WARNING: The plan does not define visibility boundaries. `ingestCascadeOneWithDeps`, `importCascadeOne`, and `enrichCascadeOne` are suggested (`2026-04-29-tdd-deterministic-cascade-import-writer.md:372`), but it does not say which are exported test-only helpers and which are stable pipeline interfaces.

### Recommendations

- Add an interface block to the plan with exact `PlanCard`, `PlanCardMode`, `ImportRow`, `CascadeImportPlan`, `WriteCascadeImportDeps`, `ImportReport`, and `CascadeIngestMode` definitions.
- Keep `ingest-report.json` compatible by either preserving `gateB` with zeroed values in import-only mode or updating `step8-aggregate.ts` in the same plan with a discriminated report schema.
- Add typed fixture builders in tests instead of incomplete object literals.

## Promise Review

### Well-Defined

- Import is promised to avoid line-of-thought, keyword writes, content-hash lookup, duplicate sweep, semantic proposal, and full store scans (`2026-04-29-tdd-deterministic-cascade-import-writer.md:52`).
- The write order promise is clear: create cards in plan order, capture IDs in that same order, then emit edges and flush once (`2026-04-29-tdd-deterministic-cascade-import-writer.md:21`).

### Missing or Unclear

- CRITICAL: Idempotency is explicitly affected but not specified. Skipping content-hash lookup and duplicate sweep is correct for performance, but the plan needs to state what happens when the same transcript/import plan is run twice.
- CRITICAL: Failure atomicity is not realistic as written. `brCreate` writes one card at a time (`apps/silmari-mcp/src/lib/br-adapter.ts:262`), and `addEdge` writes labels one edge at a time (`apps/silmari-mcp/src/lib/edges.ts:79`). A thrown `BR_WRITE_FATAL` can leave already-created cards or edges in the store. The plan needs a post-failure promise that callers can rely on.
- WARNING: Timeout behavior is not assigned for the new writer. Existing pipeline saves pass a long MCP timeout (`scripts/kc-baker-pipeline-v2/ingest/ingest-cascade.ts:346`), and `brSync` warns callers to pass a higher timeout for large stores (`apps/silmari-mcp/src/lib/br-adapter.ts:619`). The plan should name the writer's create/flush timeout knobs and expected defaults.

### Recommendations

- State one explicit retry policy: non-idempotent fresh-store-only smoke, idempotent import by `(source, fz)` probe, or resumable cleanup using partial failure artifacts.
- Define `BR_WRITE_FATAL` wrapping rules for failed `create`, failed `addEdge`, and failed `flush`, including whether the original stderr/detail is preserved.
- Add `CASCADE_IMPORT_BR_SYNC_TIMEOUT_MS` or reuse `SILMARI_BR_SYNC_TIMEOUT_MS` in the writer contract.

## Data Model Review

### Well-Defined

- Existing description and label helpers provide the correct storage model: full body and content hash live in JSON description (`apps/silmari-mcp/src/lib/card-ops.ts:367`), and folgezettel labels encode slash addresses as underscores (`apps/silmari-mcp/src/lib/labels.ts:114`).
- The plan correctly includes `content_hash`, `kind`, `box:idea`, `trunk:N`, `fz:N_seq`, and source labels in import rows (`2026-04-29-tdd-deterministic-cascade-import-writer.md:188`).

### Missing or Unclear

- CRITICAL: `ImportReport` is named but not defined. Required fields, `allIds` order, `addressIdMap` key format, `keyIdMap`, failure fields, and compatibility with existing reports are all unspecified.
- WARNING: Source/provenance metadata is too thin. Existing sources use strings like `kc-baker-pipeline-v2:${basename}:theme-${tIdx}` (`scripts/kc-baker-pipeline-v2/ingest/ingest-cascade.ts:367`), but the new plan should state whether descriptions also carry structured metadata such as `basename`, tier, `theme_idx`, `idea_idx`, `micro_idx`, and source span IDs.
- WARNING: Card ordering is partly implicit. The plan says output is stable and ordered, but it should specify whether input arrays are trusted as ordered or sorted by `theme_idx`, `idea_idx`, and original micro order. This matters for micros because `groupMicrosByIdea` currently preserves first-seen bucket order (`scripts/kc-baker-pipeline-v2/ingest/ingest-cascade.ts:179`).

### Recommendations

- Add a concrete `ImportReport` schema and update downstream readers in the same plan.
- Add structured metadata to each description for provenance and retry/debugging.
- Make ordering deterministic by contract: either reject non-monotonic indices or sort explicitly while preserving source order inside equal parent buckets.

## API Review

### Well-Defined

- The plan wisely keeps this as a direct pipeline writer rather than a new public MCP save endpoint. That avoids broadening the public API surface.
- Existing public MCP `zk_save_card` / `zk_save_cards` behavior is intentionally preserved (`2026-04-29-tdd-deterministic-cascade-import-writer.md:55`).

### Missing or Unclear

- WARNING: The CLI/script API for import-only mode is incomplete. The smoke command sets `CASCADE_ENRICHMENT_MODE=off` (`2026-04-29-tdd-deterministic-cascade-import-writer.md:428`), but the env var is not listed in the README env table and the plan does not define allowed values or default behavior.
- WARNING: The plan says "Then run enrichment separately" (`2026-04-29-tdd-deterministic-cascade-import-writer.md:468`) but does not define the separate enrichment command or input file contract.

### Recommendations

- Define `CASCADE_ENRICHMENT_MODE` values, default, and where they are read.
- Add a minimal enrichment API contract, even if implementation is deferred: command, inputs, required `ImportReport` fields, and output report behavior.

## Critical Issues

1. **Folgezettel root/cursor reservation is undefined**
   - Impact: Direct preaddressed writes can leave `fz-cursors.json` stale or wrong, causing future saves to allocate duplicate or surprising addresses.
   - Recommendation: Add an explicit root reservation and cursor commit contract before Behavior 1/3 implementation.

2. **Structural edge semantics cannot be derived from `parentKey` alone**
   - Impact: Tests can pass while all siblings get `branches` edges instead of `follows` edges, diverging from `extractFolgezettelParent` and degrading navigation/line-of-thought semantics.
   - Recommendation: Add `mode` and `predecessorKey` to plan cards and test both `branches` and `follows`.

3. **Import report schema conflicts with existing aggregation**
   - Impact: `step8-aggregate.ts` can crash or silently misreport if `ingest-report.json` changes shape.
   - Recommendation: Preserve the current report shape with import-only extensions, or update aggregation in the same plan.

4. **Import-only mode still has a likely hub-create side effect**
   - Impact: The smoke can still enter the normal `saveCard` path and store scans before import, violating the performance and side-effect claims.
   - Recommendation: Move hub creation/attach/keyword work behind enrichment mode and test `main()` or a `runMainWithDeps` wrapper, not only `ingestCascadeOneWithDeps`.

5. **Partial failure/retry semantics are unsafe**
   - Impact: A mid-import `brCreate` or `addEdge` failure can leave created cards behind, and rerun can duplicate them because duplicate lookup is intentionally disabled.
   - Recommendation: Define fresh-store-only failure handling, resumable cleanup, or idempotent `(source, fz)` checks.

## Suggested Plan Amendments

```diff
In Behavior 1: Build a Deterministic Import Plan
+ Add exact TypeScript interfaces for PlanCascadeImportArgs, PlanCard, CascadeImportPlan.
+ Add PlanCard.mode: "root" | "fork" | "continue".
+ Add PlanCard.predecessorKey for continue edges and PlanCard.parentKey for tree parent.
+ Add root allocation/cursor contract: source of rootSequence and cursor commit policy.

In Behavior 2: Build Preaddressed Store Rows
+ Require extracting card-format.ts before writer implementation.
+ Add structured metadata fields: basename, tier, theme_idx, idea_idx, micro_idx, source span ids.
~ Static grep must reject direct/transitive import of card-ops.ts in cascade-import-writer.ts.

In Behavior 3: Write Cards and Structural Edges
+ Test both first-child branch and later-sibling follows.
+ Test addEdge failure and flush failure wrap BR_WRITE_FATAL.
+ Define partial failure artifact or idempotent retry policy.

In Behavior 4: Import Phase Does Not Run Enrichment Work
+ Include zk_hub_create in the prohibited import-only call list.
+ Test main/import smoke dependency path, not only ingestCascadeOneWithDeps.

In Behavior 5: Existing Extracted Data Imports Without LLM Stages
+ Define ImportReport schema and compatibility with ingest-report.json / step8-aggregate.ts.
+ Define CASCADE_ENRICHMENT_MODE allowed values and separate enrichment command.
```

## Review Checklist

### Contracts

- [ ] Component boundaries are clearly defined
- [ ] Input/output contracts are specified
- [ ] Error contracts enumerate all failure modes
- [ ] Preconditions and postconditions are documented
- [ ] Invariants are identified

### Interfaces

- [ ] All public methods are defined with signatures
- [ ] Naming follows codebase conventions
- [ ] Interface matches existing patterns
- [ ] Extension points are considered
- [ ] Visibility modifiers are appropriate

### Promises

- [ ] Behavioral guarantees are documented
- [ ] Async operations have timeout/cancellation handling
- [ ] Resource cleanup is specified
- [ ] Idempotency requirements are addressed
- [ ] Ordering guarantees are documented where needed

### Data Models

- [ ] All fields have types
- [ ] Required vs optional is clear
- [ ] Relationships are documented
- [ ] Migration strategy is defined
- [ ] Serialization format is specified

### APIs

- [ ] All endpoints/commands are defined
- [ ] Request/response formats are specified
- [ ] Error responses are documented
- [ ] Authentication requirements are clear or out of scope
- [ ] Versioning strategy is defined or out of scope
