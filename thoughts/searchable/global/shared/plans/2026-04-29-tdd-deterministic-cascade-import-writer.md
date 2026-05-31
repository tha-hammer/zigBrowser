---
date: 2026-04-29T06:37:35-04:00
researcher: Codex
git_commit: 6efca11c2d1a72b3e79cd2fb91036e8edb6c43ff
branch: main
repository: silmari-agent-memory
topic: "TDD plan: deterministic cascade import writer"
tags: [plan, tdd, silmari-mcp, cascade-ingest, zettelkasten, folgezettel, implemented]
status: implemented-complete
last_updated: 2026-04-30
last_updated_by: Codex
research: thoughts/searchable/shared/research/2026-04-29-deterministic-cascade-import-boundary.md
review: thoughts/searchable/shared/plans/2026-04-29-tdd-deterministic-cascade-import-writer-REVIEW.md
review_status: all_findings_addressed
implementation_status: all_adf_tasks_closed
---

# Deterministic Cascade Import Writer TDD Plan

## Overview

The KC Baker cascade import should not use the general `saveCard` / `saveCardsBatch` path. The extracted transcript tree already gives us the category/trunk and the exact parent/child structure. Writing cards into the Zettelkasten should therefore be a deterministic import operation:

1. Plan all folgezettel addresses in memory.
2. Create cards with precomputed labels and description metadata.
3. Capture created IDs in the same plan order.
4. Emit structural `branches` / `follows` edges from the in-memory `planKey -> id` map.
5. Flush/verify once at the import boundary.
6. Run hub membership, keyword indexing, line-of-thought, and semantic Gate B later.

This plan is intentionally not a tuning plan for the current `zk_save_cards` implementation. It creates a narrower path for cascade import and leaves normal interactive MCP saves alone.

## Implementation Status

This plan is complete in Beads. The deterministic cascade import writer work landed across `silmari-agent-memory-adf.1` through `silmari-agent-memory-adf.10`, and the parent `silmari-agent-memory-adf` is closed.

Final implementation highlights:

- Deterministic planner, row builder, writer, root reservation, cursor commit, failure reports, resume-by-source-and-fz, and report idempotency are implemented.
- `CASCADE_ENRICHMENT_MODE=off|after-import|enrich-only` separates deterministic import from enrichment.
- Import-only cached extracted data was smoke-tested against a fresh temp `SILMARI_DIR`: 15/15 transcripts, 929 cards, zero Gate B edges, no failure reports.
- `step8-aggregate.ts` has import-only compatibility coverage.
- Stale user-facing `zk_save_cards` / `br create -f` text was updated.

Out-of-plan follow-up: real Gate B validation at scale is tracked separately by `silmari-agent-memory-9hn` / `silmari-agent-memory-9hn.1`. That follow-up is about real semantic classification runtime and edge production after native-primary and batching work; it is not remaining deterministic import-writer scope.

Key completion commits recorded in Beads:

- `7667fb1`: `silmari-agent-memory-adf.3`, card-format save-path rewire.
- `fec72a3`: `silmari-agent-memory-adf.7`, import/enrichment orchestration split.
- `be679ce`: `silmari-agent-memory-adf.8`, cached extracted import-only smoke and Step 8 compatibility.
- `af19a7a`: `silmari-agent-memory-adf.10`, cascade import docs/tool text update.

## Pre-Implementation State Analysis

This section records the state at plan creation time. It is retained for traceability; the implementation status above is the current source for this plan's completion state.

### Key Discoveries

- `saveCardTreeWithCallTool` already knows the cascade tiers and builds thesis, theme, idea, and micro inputs in order (`scripts/kc-baker-pipeline-v2/ingest/ingest-cascade.ts:324`).
- The current importer calls `zk_save_cards`, which dispatches to `saveCardsBatch` (`apps/silmari-mcp/src/index.ts:560`).
- `saveCardsBatch` performs parent resolution, content-hash lookup, folgezettel assignment, `brCreate`, duplicate sweep, edge extraction, keyword writes, anchor logging, and final flush (`apps/silmari-mcp/src/lib/card-ops.ts:1062`).
- The pure folgezettel arithmetic already exists and can compute root, fork, and continue sequences without scanning the store (`apps/silmari-mcp/src/lib/folgezettel.ts:128`, `folgezettel.ts:142`, `folgezettel.ts:154`).
- Low-level `brCreate`, `brSync`, and `brSyncImport` are available as direct write/sync primitives (`apps/silmari-mcp/src/lib/br-adapter.ts:262`, `br-adapter.ts:623`, `br-adapter.ts:658`).
- Gate B is already conceptually separate after save-time ingest inside `ingestCascadeOne` (`scripts/kc-baker-pipeline-v2/ingest/ingest-cascade.ts:584`).

### Existing Test Patterns

- Pipeline helper tests live in `scripts/kc-baker-pipeline-v2/tests/ingest-cascade.test.ts`.
- MCP batch-save tests live in `apps/silmari-mcp/tests/zk-save-cards-batch.test.ts`.
- Explicit address tests live in `apps/silmari-mcp/tests/zk-save-card-fromaddress.test.ts`.
- Tests use `bun:test`, temp `SILMARI_DIR`, and the real `br` binary for integration paths.

## Desired End State

The pipeline has two separate phases:

- **Import phase**: deterministic, no line-of-thought, no keyword writes, no content-hash lookup, no duplicate sweep, no semantic proposal, no store scan on fresh import. It produces backward-compatible `ImportReport` with card counts, zeroed `gateB`, `allIds`, `keyIdMap`, `addressIdMap`, and cursor reservation metadata.
- **Enrichment phase**: optional and separate. It may attach hub membership, build keyword index entries, call line-of-thought, run semantic proposal, and commit links.

The normal MCP `zk_save_card` / `zk_save_cards` path remains available for interactive saves and existing tests.

## What We're NOT Doing

- Not writing directly to `beads.db` with `bun:sqlite`.
- Not modifying `vendor/frankensqlite` or `vendor/asupersync`.
- Not trying to revive `br create -f` until the vendor batch-create data-model issue is separately proved fixed.
- Not running Gate B during import tests.
- Not requiring full-trunk scans for address placement.
- Not deleting the existing `saveCard` path.

## Resource Registry Binding

`specs/schemas/resource_registry.json` does not exist in this repository. All resource IDs below are therefore `[PROPOSED]`. No schema contracts were found under `schema/`, `schemas/`, or `specs/schemas/`; `schema_contract_refs` are `N/A`.

## Testing Strategy

- **Framework**: `bun:test`.
- **Unit tests**: pure address planner and import row builder.
- **Integration tests**: temp `SILMARI_DIR` plus real `br` for writer behavior.
- **Pipeline tests**: fake writer/fake enrichment functions to prove import and Gate B are separate.
- **Performance smoke**: import existing cached `scripts/kc-baker-pipeline-v2/extracted` without running LLM extraction or Gate B.

## Review Closure Matrix

The pre-implementation review found five blocking gaps and several warning-level gaps. This plan now resolves them as follows:

- Root/cursor reservation: handled by `CascadeRootReservation`, `reserveCascadeRoot`, and `commitCascadeCursor` contracts below.
- Structural edge semantics: handled by `PlanCard.mode`, `parentKey`, and `predecessorKey`, with explicit `branches` and `follows` tests.
- Import report compatibility: handled by a versioned, backward-compatible `ImportReport` with zeroed `gateB` and an `import` extension object.
- Import-only boundary: handled by `CASCADE_ENRICHMENT_MODE=off`, including no `zk_hub_create` before import.
- Partial failure and retry: handled by `ImportFailureReport` and `resume-by-source-and-fz`.
- Warning-level review items: addressed by the visibility/export contract, typed fixture-builder contract, explicit ordering contract, report-based idempotency contract, span-ID provenance metadata, and enrichment-only API contract.

## Shared Interfaces And Contracts

These interfaces are part of the implementation contract. Tests should import the real exported types instead of rebuilding partial fixture objects.

```ts
export type CascadeIngestMode = "import-only" | "import-and-enrich" | "enrich-only";
export type PlanCardMode = "root" | "fork" | "continue";
export type PlanCardTier = "thesis" | "theme" | "idea" | "micro";
export type StructuralEdgeType = "branches" | "follows";
export type ImportReportSchemaVersion = 1;

export interface CascadeRootReservation {
  trunk: 1 | 2 | 3 | 4 | 5;
  rootSequence: string;
  cursorBefore: string | null;
  cursorAfterReserve: string;
  reservedAt: string;
  strategy: "assignFolgezettel-root";
}

export interface PlanCascadeImportArgs {
  basename: string;
  trunk: 1 | 2 | 3 | 4 | 5;
  rootReservation: CascadeRootReservation;
  themes: ThemesFile;
  ideas: IdeasFile;
  micros: MicrosFile;
}

export interface PlanCard {
  key: string;                 // thesis | theme:<theme_idx> | idea:<global_idx> | micro:<idea_idx>:<local_idx>
  tier: PlanCardTier;
  mode: PlanCardMode;
  parentKey: string | null;    // tree parent; null for thesis
  predecessorKey: string | null; // same-parent predecessor for continue cards
  fz: string;                  // slash form, e.g. 1/17a1
  title: string;
  body: string;
  source: string;
  metadata: {
    basename: string;
    tier: PlanCardTier;
    theme_idx?: number;
    idea_idx?: number;
    micro_idx?: number;
    text_span_ids?: [number, number];
    source_span?: string;
    source_span_ids?: [number, number];
    source_sentence?: string;
    source_sentence_ids?: [number, number];
  };
}

export interface CascadeImportPlan {
  basename: string;
  trunk: 1 | 2 | 3 | 4 | 5;
  rootReservation: CascadeRootReservation;
  cards: PlanCard[];
  terminalSequence: string;    // final card sequence in write order; committed after successful flush
  planHash: string;            // deterministic hash of basename, trunk, root, keys, fz, source labels
}

export interface ImportRow {
  key: string;
  mode: PlanCardMode;
  parentKey: string | null;
  predecessorKey: string | null;
  fz: string;
  title: string;
  description: string;
  labels: string[];
  source: string;
  priority: 0 | 1 | 2 | 3 | 4 | 5;
  status: "open";
}

export interface WriteCascadeImportDeps {
  create(row: ImportRow, opts: { timeoutMs: number }): Promise<string> | string;
  addEdge(fromId: string, edge: StructuralEdgeType, toId: string): Promise<boolean> | boolean;
  flush(opts: { timeoutMs: number }): Promise<void> | void;
  commitCursor(trunk: 1 | 2 | 3 | 4 | 5, sequence: string): void;
  findExistingBySourceAndFz?(source: string, fz: string): Promise<string | null> | string | null;
}

export interface ImportReport {
  schemaVersion: ImportReportSchemaVersion;
  basename: string;
  mode: "import-only";
  thesis_id: string;
  cards_saved: { thesis: number; themes: number; ideas: number; micros: number };
  gateB: {
    sources_scanned: 0;
    candidates_total: 0;
    edges_proposed: 0;
    edges_committed: 0;
    by_edge_type: Record<string, never>;
  };
  import: {
    planHash: string;
    rootReservation: CascadeRootReservation;
    allIds: string[];
    keyIdMap: Record<string, string>;
    addressIdMap: Record<string, string>;
    createdIds: string[];
    reusedIds: string[];
    structuralEdges: Array<{ fromKey: string; toKey: string; fromId: string; toId: string; edge: StructuralEdgeType }>;
  };
}

export interface EnrichmentReport {
  schemaVersion: ImportReportSchemaVersion;
  basename: string;
  sourcePlanHash: string;
  sourceReportPath: string;
  enriched_at: string;
  gateB: {
    sources_scanned: number;
    candidates_total: number;
    edges_proposed: number;
    edges_committed: number;
    by_edge_type: Record<string, number>;
  };
}

export interface ImportFailureReport {
  schemaVersion: ImportReportSchemaVersion;
  basename: string;
  mode: "import-only";
  planHash: string;
  rootReservation: CascadeRootReservation;
  createdIds: string[];
  keyIdMap: Record<string, string>;
  addressIdMap: Record<string, string>;
  failedKey: string | null;
  failedOperation: "create" | "addEdge" | "flush" | "commitCursor";
  error_message: string;
  started_at: string;
  failed_at: string;
  retryPolicy: "resume-by-source-and-fz";
}
```

### Root And Cursor Contract

Production import must not accept an arbitrary `rootSequence`. Before planning a transcript, `reserveCascadeRoot(trunk)` calls `assignFolgezettel(trunk, "root")` once and captures the returned root sequence plus the prior cursor. The planner uses only that reservation. After all creates, structural edges, and final flush succeed, `writeCascadeImport` calls `commitCascadeCursor(trunk, plan.terminalSequence)` so subsequent cursor-based writes continue after the last imported card, matching the write order that normal `saveCard` calls would have produced. If any create, edge, flush, or cursor commit fails, a failure report is written and automatic reruns must use the retry policy below instead of allocating a new root.

### Structural Edge Contract

`parentKey` models the tree. `predecessorKey` models the same-parent predecessor needed for `continue` semantics. Edge emission follows current `extractFolgezettelParent` behavior:

- `mode: "root"` emits no structural edge.
- `mode: "fork"` emits `branches` from this card to `parentKey`.
- `mode: "continue"` emits `follows` from this card to `predecessorKey`.

The first child under a parent is a `fork`; later same-parent siblings are `continue` cards. Tests must cover both `branches` and `follows`.

### Partial Failure And Retry Contract

The writer is not atomic because `brCreate`, edge label writes, and flush happen as separate store operations. On failure it writes `failure-report.json` with all created/reused IDs and exits non-zero. A transcript directory with a non-empty `failure-report.json` must not run a fresh import by default. Retry uses `resume-by-source-and-fz`: before creating a row, the writer probes the exact `(source:<...>, fz:<...>)` labels. If exactly one card exists, it reuses that ID; if none exists, it creates; if more than one exists, it fails with `BR_WRITE_FATAL` and requires manual cleanup. This exact-label probe is allowed only in retry/resume mode; normal import remains scan-free.

### Import Idempotency Contract

Fresh import checks local artifacts before any store write. If `ingest-report.json` already exists with `schemaVersion: 1`, `mode: "import-only"`, and the same `import.planHash`, the importer returns the existing report and performs no creates, edge writes, cursor commit, or enrichment. If the existing report has a different `planHash`, missing required import fields, or a non-import mode, fresh import fails with a clear stale-artifact error and asks the caller to run enrichment-only or clean the transcript output directory. This duplicate-import protection is artifact-based and must not call content-hash lookup, duplicate sweep, or trunk scans.

### Export And Visibility Contract

- `cascade-import-plan.ts` exports the shared types, `InvalidCascadeTreeError`, and `planCascadeImport`.
- `cascade-import-writer.ts` exports `buildImportRows`, `writeCascadeImport`, `CascadeImportWriteError`, and writer option/dependency types.
- `ingest-cascade.ts` exports `importCascadeOne`, `enrichCascadeOne`, and `ingestCascadeOne` as stable pipeline interfaces.
- `ingestCascadeOneWithDeps` and `runMainWithDeps` are test-only seams. They may be exported, but comments must mark them as internal test seams so downstream callers do not treat them as public APIs.
- No public MCP tool is added for deterministic cascade import in this plan; this remains a pipeline-local API.

### Ordering And Validation Contract

Input JSON order is part of the deterministic import contract. The planner does not sort extracted arrays behind the caller's back.

- Themes are emitted in `themes.themes` order. `theme_idx` is used as the key identity when present, and duplicate theme indexes are rejected.
- Ideas are emitted in `ideas.ideas` array order. Their plan key is `idea:<global_idx>`, where `global_idx` is the array index consumed by Pass 3 micros. Unknown `theme_idx` and duplicate `(theme_idx, idea_idx)` pairs are rejected.
- Micros are grouped by `idea_idx` and preserve original input order within each idea. Unknown `idea_idx` values are rejected. `micro_idx` is the local index within the parent idea's preserved input order.
- The resulting `cards` array is the single source of truth for create order, `allIds` order, structural edge emission order, and cursor terminal sequence.

### Typed Fixture Builder Contract

Plan and writer tests must use typed fixture builders such as `theme(...)`, `idea(...)`, `micro(...)`, `themesFile(...)`, `ideasFile(...)`, and `microsFile(...)`. Builders must populate the full `ThemesFile`, `IdeasFile`, and `MicrosFile` shapes, including `transcript`, `generated_at`, `generated_by_model`, `text_span_ids`, `source_span_ids`, and `source_sentence_ids`. Tests should not use partial object literals that only satisfy runtime behavior while bypassing compile-time schema coverage.

## Behavior 1: Build a Deterministic Import Plan

### Resource Registry Binding

- `resource_id`: `[PROPOSED:cascade_import_plan]`
- `address_alias`: `cascade.import.plan`
- `predicate_refs`: extracted transcript tree; selected trunk; reserved cascade root
- `codepath_ref`: `scripts/kc-baker-pipeline-v2/ingest/cascade-import-plan.ts::planCascadeImport`
- `schema_contract_refs`: `N/A`

### Test Specification

**Given**: one transcript with thesis, two themes, ideas under each theme, and micros under each idea.
**When**: `planCascadeImport({ trunk: 1, rootReservation, themes, ideas, micros })` runs.
**Then**: it returns a stable ordered list with addresses like `1/17`, `1/17a`, `1/17b`, `1/17a1`, `1/17a1a`, plus `mode`, `parentKey`, and `predecessorKey` for every planned card.

**Edge Cases**:

- Empty themes creates only thesis.
- Empty ideas under a theme still keeps the theme card.
- Micros with unknown `idea_idx` are rejected before any write.
- Ideas with unknown `theme_idx` are rejected before any write.
- Duplicate `theme_idx` values and duplicate `(theme_idx, idea_idx)` pairs are rejected before any write.
- A missing or mismatched `rootReservation.trunk` is rejected before any write.
- The planner never calls `assignFolgezettel`; production callers must reserve the root before planning.

### TDD Cycle

#### Red

Add `scripts/kc-baker-pipeline-v2/tests/cascade-import-plan.test.ts`:

```ts
import { describe, expect, it } from "bun:test";
import { planCascadeImport } from "../ingest/cascade-import-plan";
import {
  idea,
  ideasFile,
  micro,
  microsFile,
  theme,
  themesFile,
} from "./fixtures/cascade-import-fixtures";

describe("planCascadeImport", () => {
  it("assigns a full transcript tree from one known root without store access", () => {
    const plan = planCascadeImport({
      basename: "sample",
      trunk: 1,
      rootReservation: {
        trunk: 1,
        rootSequence: "17",
        cursorBefore: "16",
        cursorAfterReserve: "17",
        reservedAt: "2026-04-29T00:00:00.000Z",
        strategy: "assignFolgezettel-root",
      },
      themes: themesFile([
        theme({ theme_idx: 0, theme_title: "Theme A", theme_summary: "A", text_span_ids: [0, 2] }),
        theme({ theme_idx: 1, theme_title: "Theme B", theme_summary: "B", text_span_ids: [3, 5] }),
      ]),
      ideas: ideasFile([
        idea({ theme_idx: 0, idea_idx: 0, idea_title: "Idea A0", idea_body: "A0", source_span: "span", source_span_ids: [0, 1] }),
        idea({ theme_idx: 1, idea_idx: 0, idea_title: "Idea B0", idea_body: "B0", source_span: "span", source_span_ids: [3, 4] }),
      ]),
      micros: microsFile([
        micro({ idea_idx: 0, micro_title: "Micro A0", micro_body: "M", source_sentence: "s", source_sentence_ids: [1, 1] }),
      ]),
    });

    expect(plan.cards.map((c) => [c.key, c.fz, c.mode, c.parentKey, c.predecessorKey])).toEqual([
      ["thesis", "1/17", "root", null, null],
      ["theme:0", "1/17a", "fork", "thesis", null],
      ["theme:1", "1/17b", "continue", "thesis", "theme:0"],
      ["idea:0", "1/17a1", "fork", "theme:0", null],
      ["idea:1", "1/17b1", "fork", "theme:1", null],
      ["micro:0:0", "1/17a1a", "fork", "idea:0", null],
    ]);
    expect(plan.terminalSequence).toBe("17a1a");
  });
});
```

#### Green

Create `scripts/kc-baker-pipeline-v2/ingest/cascade-import-plan.ts` with:

```ts
/**
 * @rr.id [PROPOSED:cascade_import_plan]
 * @rr.alias cascade.import.plan
 * @path.id plan-cascade-import
 * @gwt.given extracted transcript tree plus trunk and reserved root sequence
 * @gwt.when planning cascade import addresses
 * @gwt.then returns deterministic pre-addressed cards and parent keys
 * @reads [PROPOSED:extracted_cascade_json]
 * @writes none
 * @raises [PROPOSED:invalid_cascade_tree:InvalidCascadeTreeError]
 * @schema.contract N/A
 */
export function planCascadeImport(args: PlanCascadeImportArgs): CascadeImportPlan {
  // compute only; no fs, no br, no MCP
}
```

Use existing arithmetic: root comes from `CascadeRootReservation`, theme addresses are `forkSequence(root)` then repeated `continueSequence`, idea addresses fork/continue from theme address, micro addresses fork/continue from idea address. For every sibling group, the first child is `mode: "fork"` with `parentKey`; subsequent siblings are `mode: "continue"` with both the same `parentKey` and the prior sibling's `predecessorKey`.

#### Refactor

Move duplicated body construction from `saveCardTreeWithCallTool` into helper functions used by both tests and the importer.

### Success Criteria

- `bun test tests/cascade-import-plan.test.ts` fails before implementation and passes after.
- No store env vars are needed for the pure planner test.
- Planner output is stable and ordered according to the ordering and validation contract above.

## Behavior 2: Build Preaddressed Store Rows Without General Save Side Effects

### Resource Registry Binding

- `resource_id`: `[PROPOSED:preaddressed_import_rows]`
- `address_alias`: `cascade.import.rows`
- `predicate_refs`: deterministic plan cards
- `codepath_ref`: `scripts/kc-baker-pipeline-v2/ingest/cascade-import-writer.ts::buildImportRows`
- `schema_contract_refs`: `N/A`

### Test Specification

**Given**: a deterministic import plan.
**When**: rows are built for `brCreate`.
**Then**: every row has title, description JSON, `content_hash`, `kind`, `box:idea`, `trunk:N`, `fz:N_seq`, source labels, and structured provenance metadata, with no calls to `saveCard`, `saveCardsBatch`, `findByContentHash`, `sweepDuplicates`, keyword index, or `lineOfThought`.

### TDD Cycle

#### Red

Add tests in `scripts/kc-baker-pipeline-v2/tests/cascade-import-writer.test.ts`:

```ts
describe("buildImportRows", () => {
  it("turns planned cards into brCreate rows with fz labels and full body metadata", () => {
    const rows = buildImportRows(planFixture);
    expect(rows[0].labels).toContain("fz:1_17");
    expect(rows[0].labels).toContain("kind:idea");
    expect(rows[0].labels).toContain("box:idea");
    expect(rows[0].labels).toContain("trunk:1");
    expect(JSON.parse(rows[0].description).body).toContain("cascade thesis");
    expect(JSON.parse(rows[0].description).metadata).toMatchObject({
      basename: "sample",
      tier: "thesis",
    });
  });
});
```

#### Green

First extract `hashBody`, `shortHash`, `titleFromBody`, and `buildDescription` from `apps/silmari-mcp/src/lib/card-ops.ts` into `apps/silmari-mcp/src/lib/card-format.ts`, then update `card-ops.ts` to import from `card-format.ts`. `cascade-import-writer.ts` may import from `card-format.ts` and `labels.ts`; it must not import `card-ops.ts`.

Create `buildImportRows` using `hashBody`, `shortHash`, `contentHashLabel`, `kindLabel`, `boxLabel`, `trunkLabel`, `sourceLabel`, `titleFromBody`, and `buildDescription`. It should not import or call `saveCard` or `saveCardsBatch`. Description JSON must include `body`, `content_hash`, and `metadata` with `basename`, `tier`, and available `theme_idx`, `idea_idx`, `micro_idx`, `text_span_ids`, `source_span`, `source_span_ids`, `source_sentence`, and `source_sentence_ids`.

Documentation contract:

```ts
/**
 * @rr.id [PROPOSED:preaddressed_import_rows]
 * @rr.alias cascade.import.rows
 * @path.id build-import-rows
 * @gwt.given deterministic cascade import plan
 * @gwt.when converting plan cards to br create rows
 * @gwt.then rows contain labels and JSON descriptions required by the store
 * @reads [PROPOSED:cascade_import_plan]
 * @writes none
 * @raises [PROPOSED:invalid_import_row:InvalidImportRowError]
 * @schema.contract N/A
 */
```

#### Refactor

Keep `card-format.ts` free of `br-adapter`, `keyword-index`, `line-of-thought`, and edge imports so it stays a pure formatting helper.

### Success Criteria

- Row builder test passes.
- Static grep test confirms the writer file does not import `card-ops`, `saveCard`, `saveCardsBatch`, `lineOfThought`, or `keyword-index`.

## Behavior 3: Write Cards and Structural Edges From the In-Memory Plan

### Resource Registry Binding

- `resource_id`: `[PROPOSED:cascade_import_writer]`
- `address_alias`: `cascade.import.writer`
- `predicate_refs`: import rows; parent plan keys
- `codepath_ref`: `scripts/kc-baker-pipeline-v2/ingest/cascade-import-writer.ts::writeCascadeImport`
- `schema_contract_refs`: `N/A`

### Test Specification

**Given**: a planned transcript tree and a fake writer that returns deterministic IDs.
**When**: `writeCascadeImport` runs.
**Then**: it creates each card once, records `key -> id` and `fz -> id`, emits `branches` / `follows` structural edges from the in-memory map according to `PlanCard.mode`, flushes once, commits the cascade cursor, and returns an `ImportReport`.

**Edge Cases**:

- If one create fails, the function throws `BR_WRITE_FATAL`, writes `failure-report.json`, and does not return a success `ImportReport`.
- If a structural edge target key is missing, the function throws before flush.
- If `addEdge`, `flush`, or `commitCursor` fails, the thrown `BR_WRITE_FATAL` preserves the original operation, key, stderr/detail, and created IDs in the failure report.
- Retry after a failure requires `resume-by-source-and-fz`; fresh rerun is refused while a non-empty `failure-report.json` exists.

### TDD Cycle

#### Red

Use dependency injection for testability:

```ts
it("creates cards in plan order and emits branch and follows edges from key-id map", () => {
  const calls: string[] = [];
  const result = writeCascadeImport(planFixture, {
    create: (row) => {
      const id = `zk-${row.key}`;
      calls.push(`create:${row.key}`);
      return id;
    },
    addEdge: (fromId, edge, toId) => {
      calls.push(`edge:${fromId}:${edge}:${toId}`);
      return true;
    },
    flush: () => calls.push("flush"),
    commitCursor: (_trunk, sequence) => calls.push(`cursor:${sequence}`),
  });

  expect(calls).toEqual([
    "create:thesis",
    "create:theme:0",
    "create:theme:1",
    "create:idea:0",
    "edge:zk-theme:0:branches:zk-thesis",
    "edge:zk-theme:1:follows:zk-theme:0",
    "edge:zk-idea:0:branches:zk-theme:0",
    "flush",
    "cursor:17a1",
  ]);
  expect(result.addressIdMap["1/17a1"]).toBe("zk-idea:0");
  expect(result.gateB.edges_committed).toBe(0);
});
```

#### Green

Implement `writeCascadeImport(plan, deps = realDeps)`:

- Real `create` calls `brCreate`.
- Real `addEdge` calls `addEdge('idea', fromId, 'branches' | 'follows', toId, { flush: false })`.
- Real `flush` calls `brFlushOrThrow('idea', ...)`.
- Real `commitCursor` atomically updates the folgezettel cursor to `plan.terminalSequence` only after successful flush.
- `mode: "fork"` targets `parentKey` with `branches`; `mode: "continue"` targets `predecessorKey` with `follows`.
- `ImportReport.gateB` is present with zero values so `step8-aggregate.ts` remains compatible in import-only mode.
- It never calls `brList`, `brShow`, `findByContentHash`, `sweepDuplicates`, `addKeywordEntry`, or `lineOfThought`.

Documentation contract:

```ts
/**
 * @rr.id [PROPOSED:cascade_import_writer]
 * @rr.alias cascade.import.writer
 * @path.id write-cascade-import
 * @gwt.given preaddressed import rows and parent plan keys
 * @gwt.when writing the cascade import
 * @gwt.then store contains cards and structural edges without graph scans
 * @reads [PROPOSED:cascade_import_plan]
 * @writes [PROPOSED:br_idea_store]
 * @raises [PROPOSED:br_write_fatal:BR_WRITE_FATAL]
 * @schema.contract N/A
 */
```

#### Refactor

Keep dependency injection local to the writer module. Do not expand it into the general MCP save path.

### Success Criteria

- Fake-deps unit test proves call ordering, `branches` edge targets, `follows` edge targets, and cursor commit ordering.
- Real temp-store integration test verifies `brShow` can read a written card by returned ID and parent edge labels exist.
- No test requires a full trunk scan.
- Failure test proves `failure-report.json` includes created IDs and retry policy when `create`, `addEdge`, or `flush` fails.
- Success `ImportReport` includes `schemaVersion: 1`, backward-compatible top-level fields, zeroed `gateB`, and import extension maps in plan order.

## Behavior 4: Import Phase Does Not Run Enrichment Work

### Resource Registry Binding

- `resource_id`: `[PROPOSED:cascade_import_boundary]`
- `address_alias`: `cascade.import.boundary`
- `predicate_refs`: extracted transcript; import-only execution
- `codepath_ref`: `scripts/kc-baker-pipeline-v2/ingest/ingest-cascade.ts::ingestCascadeOne`
- `schema_contract_refs`: `N/A`

### Test Specification

**Given**: import-only mode.
**When**: ingest runs a transcript.
**Then**: it writes cards and an import report but does not call `zk_hub_create`, `zk_line_of_thought`, `zk_propose_links_semantic`, `zk_hub_members`, `zk_keyword_add`, or `zk_hub_add_card`.

### TDD Cycle

#### Red

Add a fake-runner test to `scripts/kc-baker-pipeline-v2/tests/ingest-cascade.test.ts`:

```ts
it("import-only phase does not call Gate B or keyword/hub enrichment", async () => {
  const calls: string[] = [];
  await ingestCascadeOneWithDeps({
    input: fixtureInput,
    mode: "import-only",
    importWriter: async () => fixtureImportReport,
    callTool: async (_client, name) => {
      calls.push(name);
      throw new Error(`unexpected enrichment call: ${name}`);
    },
  });
  expect(calls).toEqual([]);
});

it("main import-only mode skips person hub creation before transcript ingest", async () => {
  const calls: string[] = [];
  await runMainWithDeps({
    env: { CASCADE_ENRICHMENT_MODE: "off" },
    callTool: async (_client, name) => {
      calls.push(name);
      throw new Error(`unexpected MCP tool call in import-only main: ${name}`);
    },
    importCascadeOne: async () => fixtureImportReport,
  });
  expect(calls).not.toContain("zk_hub_create");
});
```

#### Green

Refactor `ingestCascadeOne` to accept an internal dependency object or split it into:

- `importCascadeOne(...)`
- `enrichCascadeOne(...)`
- `ingestCascadeOne(...)` as orchestration wrapper

Use an env or explicit argument for import-only test mode. Prefer explicit function parameters in tests; env flags are only for `main()`.

`CASCADE_ENRICHMENT_MODE` values:

- `off`: import-only. `main()` must not create the person hub, attach hub membership, write keywords, call line-of-thought, call Gate B, or commit proposals.
- `after-import`: default. Run deterministic import, write the import report, then run enrichment from that produced report.
- `enrich-only`: do not import; read existing `ingest-report.json` files and run enrichment only.

Enrichment-only mode requires each selected `ingest-report.json` to parse as `ImportReport` with `schemaVersion: 1`, `mode: "import-only"`, `import.planHash`, and non-empty `import.allIds`. Files in the old pre-import-report shape must fail validation with a clear message before any enrichment scan or MCP tool call runs. Enrichment writes an `EnrichmentReport` or updates the existing report only after semantic proposal/commit succeeds; import artifacts are not rewritten.

Documentation contract:

```ts
/**
 * @rr.id [PROPOSED:cascade_import_boundary]
 * @rr.alias cascade.import.boundary
 * @path.id import-cascade-one
 * @gwt.given extracted transcript and import-only mode
 * @gwt.when ingesting one transcript
 * @gwt.then writes only deterministic import artifacts and no enrichment calls
 * @reads [PROPOSED:extracted_cascade_json]
 * @writes [PROPOSED:br_idea_store],[PROPOSED:ingest_report]
 * @raises [PROPOSED:br_write_fatal:BR_WRITE_FATAL]
 * @schema.contract N/A
 */
```

#### Refactor

Make `main()` call import first and only call enrichment when `CASCADE_ENRICHMENT_MODE` is not `off`. In `off` mode, person hub creation must move behind the enrichment boundary; it cannot run before import.

### Success Criteria

- Unit test proves import-only calls no enrichment tools, including no `zk_hub_create` from `main()`.
- Existing Gate B tests still pass through `enrichCascadeOne`.
- Enrich-only tests prove invalid or old-shape reports fail before scans, while valid `schemaVersion: 1` import reports drive enrichment without importing cards.
- Re-running import against an existing same-hash `ingest-report.json` returns the report without store writes; different-hash stale artifacts fail before store writes.

## Behavior 5: Existing Extracted Data Imports Without LLM Stages

### Resource Registry Binding

- `resource_id`: `[PROPOSED:extracted_cache_import_smoke]`
- `address_alias`: `cascade.import.smoke`
- `predicate_refs`: cached `scripts/kc-baker-pipeline-v2/extracted`
- `codepath_ref`: `scripts/kc-baker-pipeline-v2/ingest/import-from-extracted.ts`
- `schema_contract_refs`: `N/A`

### Test Specification

**Given**: the existing `extracted` directory.
**When**: import-only smoke runs against a fresh temp store.
**Then**: it imports all cached transcript cards, writes reports, and exits within a bounded time without running Pass 1-5 or Gate B.

The emitted `ingest-report.json` must remain backward-compatible with `step8-aggregate.ts`: top-level `schemaVersion`, `basename`, `thesis_id`, `cards_saved`, and `gateB` are required. Import-only reports add the top-level `mode: "import-only"` and `import` extension object defined above. `gateB` must be zeroed rather than omitted.

### TDD Cycle

#### Red

Add a script-level smoke command, not a default unit test:

```bash
EXTRACTED_DIR=/home/maceo/Dev/silmari-agent-memory/scripts/kc-baker-pipeline-v2/extracted \
SILMARI_DIR="$(mktemp -d)" \
CASCADE_ENRICHMENT_MODE=off \
bun run scripts/kc-baker-pipeline-v2/ingest/ingest-cascade.ts
```

Expected assertions:

- logs include import start and import done.
- logs do not include Pass 1/2/3/Fix.
- reports show 15 transcripts and expected card total from cached JSON.
- each `ingest-report.json` has `schemaVersion: 1`, `mode: "import-only"`, zeroed `gateB`, `import.allIds`, `import.addressIdMap`, and `import.keyIdMap`.
- no fatal store error.

#### Green

Wire `main()` so ingest can be run directly from cached extracted data. Do not require `run.sh` for this smoke. Add `CASCADE_IMPORT_BR_SYNC_TIMEOUT_MS` with default `120000`; the writer passes it to create/flush deps and may fall back to `SILMARI_BR_SYNC_TIMEOUT_MS` when unset.

#### Refactor

Add a small README section showing:

- import-only command (`CASCADE_ENRICHMENT_MODE=off`)
- import-and-enrich default (`CASCADE_ENRICHMENT_MODE=after-import`)
- enrichment-only command (`CASCADE_ENRICHMENT_MODE=enrich-only EXTRACTED_DIR=<dir>`)
- retry command (`CASCADE_IMPORT_RETRY=resume-by-source-and-fz`)

### Success Criteria

- Import-only smoke completes on the existing extracted directory.
- No `failure-report.json` is written for successful imports.
- If a `brCreate` fails, the process exits non-zero immediately and writes a structured failure report.
- Re-running the smoke against the same output directory is a no-op when report hashes match and a pre-write error when they do not.
- `step8-aggregate.ts` continues to read import-only `ingest-report.json` without changes or is explicitly updated in the same implementation commit.
- `CASCADE_ENRICHMENT_MODE` allowed values and defaults are documented in the README/env table.

## Integration and E2E Testing

Automated:

- `cd scripts/kc-baker-pipeline-v2 && bun test tests/cascade-import-plan.test.ts tests/cascade-import-writer.test.ts tests/ingest-cascade.test.ts`
- `cd apps/silmari-mcp && bun test tests/zk-save-cards-batch.test.ts tests/zk-save-card-fromaddress.test.ts tests/br-adapter.test.ts`
- `cd apps/silmari-mcp && bun run typecheck`

Manual/smoke:

- Run import-only from existing `extracted` against a fresh temp `SILMARI_DIR`.
- Inspect active process list during smoke; expected long processes are bounded `br create`/flush only, not repeated `br list -l trunk:1`, `br list -l content_hash:*`, or Gate B semantic calls.
- Then run enrichment separately on the produced import report if needed.
- Run `bun run scripts/kc-baker-pipeline-v2/extract/step8-aggregate.ts` against import-only reports; it must not throw on zeroed `gateB`.

## Implementation Order

1. `silmari-agent-memory-adf.1` (closed): Add pure planner tests and implement `cascade-import-plan.ts`.
2. `silmari-agent-memory-adf.2` (closed): Add row-builder tests and implement `buildImportRows`.
3. `silmari-agent-memory-adf.3` (closed): Rewire existing save-path formatting exports to `card-format.ts`.
4. `silmari-agent-memory-adf.4` (closed): Add fake-deps writer tests and implement `writeCascadeImport`.
5. `silmari-agent-memory-adf.5` (closed): Wire real store dependencies, root reservation, cursor commit, and real temp-store integration coverage.
6. `silmari-agent-memory-adf.6` (closed): Persist `failure-report.json` and implement `resume-by-source-and-fz`.
7. `silmari-agent-memory-adf.9` (closed): Enforce report-based import idempotency and stale-artifact guards.
8. `silmari-agent-memory-adf.7` (closed): Split `ingestCascadeOne` into import and enrichment phases.
9. `silmari-agent-memory-adf.8` (closed): Add import-only smoke command, report compatibility coverage, and `step8-aggregate.ts` tests for import-only reports.
10. `silmari-agent-memory-adf.10` (closed): Update stale tool/readme text that still claims `zk_save_cards` uses one `br create -f` subprocess.

## Beads Linkage

Parent implementation issue:

- `silmari-agent-memory-adf`: `[silmari-mcp] br subprocess ETIMEDOUT under cumulative load — saveCard idea cascade-fails`

Tracked implementation tasks:

| Bead | Status | Plan responsibility |
|------|--------|---------------------|
| `silmari-agent-memory-adf.1` | closed | Pure deterministic planner, reserved-root validation, and planner tests. |
| `silmari-agent-memory-adf.2` | closed | `buildImportRows`, row-builder tests, and pure `card-format.ts` helper creation. |
| `silmari-agent-memory-adf.3` | closed | Rewire existing save-path formatting exports to `card-format.ts` without behavior changes. |
| `silmari-agent-memory-adf.4` | closed | Fake-dependency `writeCascadeImport` core, structural edges, cursor ordering, and structured failure object. |
| `silmari-agent-memory-adf.5` | closed | Real `brCreate`/edge/flush dependencies, root reservation, cursor commit, and temp-store integration coverage. |
| `silmari-agent-memory-adf.6` | closed | Filesystem failure reports, fresh-run failure guard, and `resume-by-source-and-fz` retry policy. |
| `silmari-agent-memory-adf.7` | closed | Import/enrichment orchestration split and `CASCADE_ENRICHMENT_MODE` behavior. |
| `silmari-agent-memory-adf.8` | closed | Cached extracted import-only smoke, report compatibility, and `step8-aggregate.ts` coverage. |
| `silmari-agent-memory-adf.9` | closed | Same-hash import no-op and stale/different/malformed report pre-write failure. |
| `silmari-agent-memory-adf.10` | closed | README/tool text cleanup for stale `zk_save_cards` / `br create -f` claims and env documentation. |

Current downstream follow-up:

| Bead | Status | Relationship |
|------|--------|--------------|
| `silmari-agent-memory-9hn` | blocked | Full real Gate B 15-transcript validation remains downstream of this plan. |
| `silmari-agent-memory-9hn.1` | in_progress | Real Gate B runtime/fanout tuning and bounded validation after native-primary batching. |

Related historical issues:

- `silmari-agent-memory-7qr`
- `silmari-agent-memory-929`
- `silmari-agent-memory-p6i`
- `silmari-agent-memory-6iz`
