---
date: 2026-04-29T06:37:35-04:00
researcher: Codex
git_commit: 6efca11c2d1a72b3e79cd2fb91036e8edb6c43ff
branch: main
repository: silmari-agent-memory
topic: "Deterministic cascade import boundary for KC Baker Zettelkasten ingest"
tags: [research, codebase, silmari-mcp, cascade-ingest, zettelkasten, folgezettel]
status: complete
last_updated: 2026-04-29
last_updated_by: Codex
---

# Research: Deterministic Cascade Import Boundary

## Research Question

Where does the current KC Baker cascade pipeline mix deterministic Zettelkasten card placement with expensive graph/linking work, and what code paths must a TDD plan target to separate those concerns?

## Summary

The current pipeline already knows the transcript tree: thesis -> themes -> ideas -> micros. It also already knows the chosen top-level trunk. The Zettelkasten address for each card can therefore be planned in memory from one root slot and the tree indices.

The code does not currently use that simple boundary. `scripts/kc-baker-pipeline-v2/ingest/ingest-cascade.ts` builds tiered `zk_save_cards` calls, and `apps/silmari-mcp/src/lib/card-ops.ts` routes each batch through the normal `saveCardsBatch` path. That path performs address assignment, parent lookup, body-hash recurrence lookup, duplicate sweep, Tier A edge extraction, keyword writes, and final flush/recovery behavior around the actual `br create` calls. Gate B then separately calls line-of-thought, hub-member lookup, semantic proposal, and commit calls.

The codebase already has the pure components needed to build a deterministic import writer: folgezettel arithmetic in `folgezettel.ts`, body/description/label helpers in `card-ops.ts` and `labels.ts`, and low-level `brCreate`/sync wrappers in `br-adapter.ts`. The missing piece is a pipeline-specific import surface that writes pre-addressed cards and records parent relationships from an in-memory `planKey -> id` map rather than asking the store to rediscover them.

## Detailed Findings

### Pipeline Ingest Shape

- `saveCardTreeWithCallTool` builds four save tiers: thesis, themes, ideas, and micros (`scripts/kc-baker-pipeline-v2/ingest/ingest-cascade.ts:324`).
- The current tier planner passes `mode: "root"` for the thesis and uses `saveArgsForSibling` for each sibling tier (`ingest-cascade.ts:344`, `ingest-cascade.ts:358`, `ingest-cascade.ts:381`, `ingest-cascade.ts:416`).
- The current sibling helper maps first child to `{ mode: "fork", fromAddress: parentFz }` and subsequent siblings to `{ mode: "continue" }` (`ingest-cascade.ts:215`).
- Gate B is already logically separate inside `ingestCascadeOne`: save phase first, then hub/keyword side effects, then line-of-thought and semantic edge proposal for each saved id (`ingest-cascade.ts:559`, `ingest-cascade.ts:569`, `ingest-cascade.ts:584`).

### Current Save Path Work

- `saveCard` begins by resolving an optional explicit parent address, then performs body-hash lookup, folgezettel assignment, `brCreate`, post-save steps, and flush (`apps/silmari-mcp/src/lib/card-ops.ts:896`).
- `saveCardsBatch` repeats the same work for each card: `resolveExplicitTarget`, `findByContentHash`, `assignFolgezettel`, `brCreate`, `runPostSaveSteps`, and final persistence (`card-ops.ts:1062`).
- `findByContentHash` can read from cache, direct SQLite, or `br list` depending on env and fallback state (`card-ops.ts:436`).
- `sweepDuplicates` performs a content-hash label lookup and may write `reinforces` and review labels (`card-ops.ts:526`).
- `runPostSaveSteps` performs duplicate sweep, deterministic edge extraction, optional line-of-thought candidate gathering, body-hash reinforces, keyword writes, and anchor-missing logging (`card-ops.ts:639`).
- Save-time parent edge lookup asks the store for the parent fz label unless there is an explicit target or fast-path cache (`card-ops.ts:647`, `card-ops.ts:798`).

### Addressing Primitives

- `folgezettel.ts` has pure sequence arithmetic for `continueSequence`, `forkSequence`, `rootSequence`, `formatAddress`, and `parseAddress` (`apps/silmari-mcp/src/lib/folgezettel.ts:128`, `folgezettel.ts:142`, `folgezettel.ts:154`, `folgezettel.ts:162`, `folgezettel.ts:170`).
- Cursor state is stored as a trunk-keyed JSON file; `readCursors` and `writeCursors` handle persistence (`folgezettel.ts:208`, `folgezettel.ts:238`).
- `assignFolgezettel` currently computes and writes the cursor immediately (`folgezettel.ts:268`). A deterministic importer can avoid per-card cursor lookups by planning a root sequence once and committing the final root cursor once per successful transcript import.

### Low-Level Store Writes

- `brCreate` creates one bead using `br create`, labels, description JSON, priority, and status (`apps/silmari-mcp/src/lib/br-adapter.ts:262`).
- Write wrappers use `--no-auto-flush`, deferring JSONL export because default `br` auto-flush is O(store size) per write (`br-adapter.ts:155`).
- `brSync` flushes dirty SQLite state to `issues.jsonl` (`br-adapter.ts:623`).
- `brSyncImport` rebuilds SQLite from `issues.jsonl` and is only safe after current writes are flushed (`br-adapter.ts:658`).
- `brCreateBatch` still exists, but comments and tests document that the markdown batch path reuses one FrankenSQLite connection and has produced B-tree/id-visibility failures (`br-adapter.ts:321`, `card-ops.ts:1159`).

### MCP Surface

- `zk_save_card` and `zk_save_cards` both route into `saveCard`/`saveCardsBatch` (`apps/silmari-mcp/src/index.ts:536`, `index.ts:560`).
- The public `zk_save_cards` description is stale: it still claims one `br create -f` invocation even though the implementation uses one `brCreate` per card (`index.ts:130`, `card-ops.ts:1159`).
- Hub creation, hub attach, and line-of-thought are separate MCP tools (`index.ts:676`, `index.ts:686`, `index.ts:701`).

### Existing Tests

- `scripts/kc-baker-pipeline-v2/tests/ingest-cascade.test.ts` already tests the tier planning helpers and callTool timeout wiring (`ingest-cascade.test.ts:46`, `ingest-cascade.test.ts:187`).
- `apps/silmari-mcp/tests/zk-save-cards-batch.test.ts` tests the current `zk_save_cards` contract: per-card creates, ordered results, empty input, body-hash recurrence, and parity with `zk_save_card`.
- `apps/silmari-mcp/tests/zk-save-card-fromaddress.test.ts` tests explicit-address saves and the current hard-fail behavior when a parent address is missing.

## Architecture Documentation

Current architecture:

1. Pipeline extraction writes `themes.json`, `ideas.json`, and `micros.v2.json`.
2. `ingest-cascade.ts` reads those files and builds `zk_save_cards` requests tier by tier.
3. The MCP save tool enters the normal Silmari save path for each card.
4. Normal save path tries to maintain multiple general-purpose invariants: recurrence, duplicate sweep, deterministic edges, keywords, anchor logs, and flush/recovery.
5. Gate B then does graph enrichment after cards are saved.

Target boundary implied by the code:

1. Pipeline import should plan all addresses from the extracted tree and current root cursor.
2. Import should write the pre-addressed cards and structural parent edges from the import plan.
3. Import should flush and verify.
4. Graph enrichment should run later and may use line-of-thought, keyword index, hubs, and semantic proposer.

## Code References

- `scripts/kc-baker-pipeline-v2/ingest/ingest-cascade.ts:324` - current tiered save-card tree orchestration.
- `scripts/kc-baker-pipeline-v2/ingest/ingest-cascade.ts:465` - Gate B candidate collection starts with line-of-thought.
- `scripts/kc-baker-pipeline-v2/ingest/ingest-cascade.ts:559` - `ingestCascadeOne` combines import and enrichment in one per-transcript operation.
- `apps/silmari-mcp/src/lib/card-ops.ts:639` - post-save pipeline bundles duplicate sweep, edge extraction, keyword writes, and anchor logging.
- `apps/silmari-mcp/src/lib/card-ops.ts:896` - normal single-card save path.
- `apps/silmari-mcp/src/lib/card-ops.ts:1062` - normal batch save path.
- `apps/silmari-mcp/src/lib/folgezettel.ts:128` - continue address arithmetic.
- `apps/silmari-mcp/src/lib/folgezettel.ts:142` - fork address arithmetic.
- `apps/silmari-mcp/src/lib/br-adapter.ts:262` - low-level single bead create.
- `apps/silmari-mcp/src/lib/br-adapter.ts:623` - flush to JSONL.
- `apps/silmari-mcp/src/index.ts:560` - MCP `zk_save_cards` dispatch.

## Historical Context

- `thoughts/searchable/shared/plans/2026-04-25-tdd-7qr-cascade-failure-three-layer-fix.md` documented the earlier parent-address lookup failure and WAL visibility hypothesis.
- `thoughts/searchable/shared/plans/2026-04-27-11-30-tdd-brlist-timeout-cascade-fixes.md` documented the prior brList timeout and label lookup mitigation path.
- Open beads related to this boundary: `silmari-agent-memory-7qr`, `silmari-agent-memory-adf`, `silmari-agent-memory-929`, `silmari-agent-memory-p6i`, `silmari-agent-memory-6iz`.

## Open Questions

- The repo currently has no `specs/schemas/resource_registry.json`; TDD plan resource bindings must be marked `[PROPOSED]`.
- The implementation should decide whether deterministic import lives as a direct pipeline writer or as a new MCP tool. The TDD plan below recommends a direct pipeline writer plus a later enrichment phase to avoid exposing pipeline-specific behavior through the general MCP save tools.
