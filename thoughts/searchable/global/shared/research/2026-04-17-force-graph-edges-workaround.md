---
date: 2026-04-17T09:50:00-04:00
researcher: Silmari
git_commit: 6218b302af045b474bd8ec8f39b538fb4d5003fe
branch: main
repository: silmari-agent-memory
tags: [research, beads-viewer, force-graph, edges, synthesize-edges-from-labels, bv-graph-wasm, dependencies-table]
status: complete
last_updated: 2026-04-17
last_updated_by: Silmari
topic: "Force-graph edge-rendering workaround — synthesizeEdgesFromLabels + `d.type || 'blocks'` coalesce"
---

# Research: Force-Graph Edge Workaround — Why It Exists, What It Hides, and How to Retire It

## Research Question

The silmari-viewer displays card-to-card edges via a layered **workaround** that re-derives `ref:*` labels into a `dependencies` table at viewer-cache export time and defensively coalesces null edge types to `'blocks'` in the client. What is the shape of this workaround, what concrete bugs or design debts does it carry, and what are the realistic options for replacing it with a first-principles design — constrained to the viewer layer (no beads_rust engine changes)?

---

## Summary

The workaround is a **4-part scaffold** that makes edges visible in the force-graph at all — without it, a freshly-migrated silmari store renders as an disconnected cluster of isolated nodes. It was built because `beads_rust`'s dependency-type whitelist (a hard constraint inherited from the engine) rejected every edge type cosmic used except `blocks`, so the native `dependencies` table cannot hold silmari's 11 other edge kinds. Silmari instead stores edges **as labels on source cards** (`ref:<type>:<target>`) and re-synthesizes them into the **viewer cache sqlite's** `dependencies` table at export time.

The scaffold works, but it fights gravity in five quiet ways:

1. **Fresh-install blindness** — a cosmic→silmari migration yields a silmari store with zero `ref:*` labels (the migration ran before the Tier A extractors landed), so the viewer shows no edges until a one-shot Tier C backfill runs.
2. **Dead defensive coalesce** — `graph.js:1080` coalesces `d.type || 'blocks'`, but the only two sources of `dependencies` rows (native `blocks` + synthesized `ref:*`) both always set `type`; the coalesce is unreachable and hides a lurking silent-failure mode if that invariant ever breaks.
3. **Shared-table pollution** — writing 11 semantic edge types into the `dependencies` table (even a *cache* copy) conflates DAG-shaped "blocks" with undirected-in-practice semantic edges (`supports`, `contradicts`, `refers-to`, …). Every downstream consumer must filter-by-type, and one missed filter means analytics wrongly include semantic edges in DAG algorithms.
4. **Every-export synthesis cost** — `synthesizeEdgesFromLabels` runs on every `bv --export-pages`, scanning every card's label JSON. At 278 cards × avg ~5 labels it's fine today; the pattern doesn't scale linearly forever.
5. **WASM-filter dependency on invariant #2** — the filter at `graph.js:686` is `type === 'blocks' || !d.type`, which includes null-type rows. It only works because no row actually has null type. A bug that produces a null-type row silently poisons PageRank / critical-path output.

**The Rust crate (bv-graph-wasm) has zero awareness of edge types** — edges are pure `(usize, usize)` index pairs in `adj: Vec<Vec<usize>>` (`graph.rs:19`), the WASM-exported `addEdge(from, to)` (`graph.rs:78-93`) takes no type parameter, and **no algorithm** in `src/algorithms/*.rs` branches on edge type. This means every realistic fix is **pure JS + sqlite schema work** on the viewer cache layer — the analytics engine is already edge-type-agnostic.

Recommended fix: **split the cache schema** into a blocks-only `dependencies` table (preserving the WASM contract) and a typed `card_edges(source, target, type)` table (for visual/detail-panel rendering). Non-destructive: keep synthesizeEdgesFromLabels writing to `card_edges` instead of `dependencies`, update the JS link-builder to union both tables. Retires the dead coalesce, tightens the WASM filter to `=== 'blocks'`, eliminates shared-table pollution, preserves all existing animation / color work landed in 2026-04-12's ZK-redesign Phase 3.

---

## Detailed Findings

### §1 — The 4-Part Workaround

#### 1.1 — Server-side: re-synthesis on every export (`server.ts:119-151`)

`apps/silmari-memory-card-viewer/server.ts:119 synthesizeEdgesFromLabels(dbPath)` is called after `bv --export-pages` writes the cache sqlite (`/tmp/silmari-memory-card-viewer-cache/beads.sqlite3`). It:

1. Opens the cache sqlite read-write.
2. `SELECT id, labels FROM issues` — pulls every card's label JSON.
3. For each card, parses the JSON array and for each label of shape `ref:<type>:<target>`:
   - Validates `type` against `VALID_EDGE_TYPES` set (defined at `server.ts:85-89`, used inside `parseRefLabel` at `server.ts:101`) — 12 entries.
   - Validates `target` against `/^[A-Za-z0-9-]+$/`.
   - `INSERT INTO dependencies (issue_id, depends_on_id, type) VALUES (?, ?, ?)` (`server.ts:139`).
4. All inserts in a single `BEGIN`/`COMMIT` transaction; schema mismatch aborts the whole batch.
5. Returns `{ ok, synthesized, error? }`; the viewer's `/api/health` endpoint surfaces `lastSynthCount`.

Every synthesized row has `type` set to a non-null, validated edge-type string. The synthesizer never writes null.

#### 1.2 — Client-side: defensive coalesce (`graph.js:1067-1081`)

```javascript
// Card Lifecycle Protocol: keep ALL edge types (related,
// discovered-from, relates-to, derived-from, follows, parent-child,
// blocks). The previous filter dropped everything except `blocks`,
// which made the visual graph appear empty for any workspace where
// the dominant link types are auto-interlinks rather than explicit
// blocked_by edges. The WASM analytics engine still filters to
// blocks separately at viewer.js:708 because PageRank/critical-path
// are DAG-only.
let links = dependencies
    .filter(d => nodeIds.has(d.issue_id) && nodeIds.has(d.depends_on_id))
    .map(d => ({
        source: d.issue_id,
        target: d.depends_on_id,
        type: d.type || 'blocks'
    }));
```

This `|| 'blocks'` defaults any null-type row to `'blocks'`. The preceding comment makes clear this was added after a prior bug where "keep blocks-only" rendered an empty graph. But with the current synthesizer (§1.1) always setting `type`, and with the cache's native `dependencies` rows (copied by `bv --export-pages` from `beads_rust`'s whitelist-enforced source) also always having `type='blocks'`, **the coalesce is dead code today**. It is a silent-failure canary — if any future path writes a null-type row, that row will be invisibly mislabeled as blocks.

#### 1.3 — WASM analytics filter (`graph.js:684-693`)

```javascript
store.dependencies
    .filter(d => d.type === 'blocks' || !d.type)
    .forEach(d => {
        const fromIdx = store.wasmGraph.nodeIdx(d.issue_id);
        const toIdx = store.wasmGraph.nodeIdx(d.depends_on_id);
        if (fromIdx !== undefined && toIdx !== undefined) {
            store.wasmGraph.addEdge(fromIdx, toIdx);
        }
    });
```

Only `blocks`-type (and null-type, via the `|| !d.type` branch) rows enter the WASM DAG. PageRank, critical-path heights, eigenvector centrality, k-core, cycle detection, articulation points, HITS — every WASM analytic — operates only on this DAG subset. Correct behavior for a DAG-shaped algorithm on a DAG-shaped relationship. The `|| !d.type` branch is the same dead reachability as §1.2 but with an *opposite* failure mode: a null-type row would be incorrectly admitted into DAG analytics and silently distort PageRank output.

#### 1.4 — Tier C one-shot backfill (`apps/silmari-mcp/scripts/backfill-edges-from-cosmic.ts`)

Fresh-install silmari (i.e. any store created via the 2026-04-06 cosmic→silmari migration or restored from a snapshot taken before the Tier A extractors landed) has **zero** `ref:*` labels, so the synthesizer in §1.1 writes zero rows, so the force-graph shows zero non-blocks edges.

The backfill script retroactively imports historical cosmic `dependencies` rows as silmari `ref:*` labels via `brLabelAdd`. It:

- Reads cosmic's `dependencies` table (readonly).
- Builds a `cosmic_id → silmari_id` lookup from silmari's `legacy-id:*` labels.
- Maps cosmic edge types to silmari types via `COSMIC_TO_SILMARI_TYPE` (`related/relates-to/replies-to → refers-to`; `discovered-from/derived-from/caused-by → derives-from`; `follows → follows`; `parent-child → branches`; `blocks → skipped (already native)`; `duplicates/supersedes/waits-for/conditional-blocks → skipped (no equivalent)`).
- Is idempotent via a pre-existing-ref-label set check (`script line 204-214`).
- Has a critical `SILMARI_DIR` env-var trap: the script's `--silmari-db` flag sets the **read** path, but writes go through `brLabelAdd` which reads `SILMARI_DIR` (see the 2026-04-17 README §Graph edges).
- Works around a `bun:sqlite` fd-leak gotcha: calls `Bun.gc(true)` after reading silmari sqlite before the subsequent `brLabelAdd` subprocess writes (`script:246-248`). Without this, the child process races the parent's still-open fd and ETIMEDOUTs on the WAL lock.

Typical restored breakdown (per README): `derives-from: 192, refers-to: 105, follows: 63, branches: 4` — total 364 edges.

### §2 — Why the Workaround Exists

The root cause is the **2026-04-06 cosmic→silmari migration** and `beads_rust`'s dependency-type whitelist. Context, in order:

1. **Cosmic** (the pre-silmari store) used its own beads fork with a richer `dependencies` table — types `related`, `discovered-from`, `derived-from`, `caused-by`, `relates-to`, `replies-to`, `follows`, `parent-child`, `blocks`, `duplicates`, `supersedes`, `waits-for`, `conditional-blocks`. Cosmic's web viewer populated its force-graph via `patchExportedDependencies()` (ATTACH DATABASE + INSERT FROM src.dependencies) — a straight copy from the source.
2. **beads_rust** — the Rust-rewritten engine silmari uses — accepts only **one** dependency type (`blocks`) via its internal whitelist (`Plans/tdd/2026-04-11-tdd-edge-creation-loop.md §B.7.3`). When the cosmic → silmari migration ran, every cosmic dependency row whose type was NOT `blocks` was silently dropped because `br dep add` rejected it.
3. **Lost edges**, not lost data — the cosmic issue text was all imported, but the edge topology was erased for 11 of 12 types. ~360 edges silently disappeared.
4. **Tier A extractors** (`apps/silmari-mcp/src/lib/edge-extractors.ts`) were added at save time: every `zk_save_card` call emits `ref:<type>:<target>` **labels** on the source card (labels pass `beads_rust`'s label whitelist, unlike dependency types). This made edges recoverable *going forward*.
5. **Tier C backfill** (§1.4) closes the gap for *already-migrated* data.
6. **Server-side synthesis** (§1.1) is the runtime half — it translates the label representation into what the force-graph SPA already knows how to consume (rows in a `dependencies` table).

In short: **the workaround exists because `beads_rust` has an opinion about dependency types that silmari's knowledge-graph use-case doesn't share**, and silmari chose to work around the engine via labels rather than fork the engine's whitelist.

### §3 — Concrete Symptoms of the Workaround

What actually breaks / degrades because of this design, beyond the structural critique:

| # | Symptom | Location | Severity |
|---|---------|----------|----------|
| S1 | Fresh silmari installs render the force-graph as a disconnected cluster until the Tier C backfill runs (requires cosmic snapshot access). | Any new client machine. Documented README §Graph edges. | High — first-run UX |
| S2 | `\|\| 'blocks'` coalesce at `graph.js:1080` is dead today (synthesizer always sets type, native rows always have `type='blocks'`), but remains as a silent-failure canary — any future regression that produces a null-type row will be invisibly mislabeled rather than caught. | `graph.js:1080` | Medium — latent |
| S3 | The `\|\| !d.type` branch in the WASM filter (`graph.js:686`) would admit null-type rows into PageRank and critical-path analytics — wrong answer, no error surfaced. | `graph.js:686` | Medium — latent |
| S4 | Every new feature that queries the `dependencies` table must remember to filter by type; a single forgotten filter means a feature incorrectly conflates semantic edges with blocks edges. | Codebase-wide (any `dependencies` query) | Ongoing |
| S5 | `synthesizeEdgesFromLabels` runs on every `bv --export-pages` invocation (scans every card, every label). Current cost is negligible at 278 cards, but the every-export pattern doesn't scale. | `server.ts:119` | Low — scale-only |
| S6 | The cache's `dependencies` table and the **source** `~/.silmari-memory/box2-ideas/.beads/beads.db`'s `dependencies` table hold semantically different data (cache has 364 rows; source has only the native `blocks` rows). Debuggers expect them to match; they don't. | Cross-file (source vs. cache sqlite) | Low — bug-hunter confusion |
| S7 | Edges are invisible in the viewer **list** mode — only the force-graph consumes the `dependencies` table. The card detail panel reads edges from `selectedIssue.edges` (viewmodel.js via `extractEdges(labels)`), which reads from `ref:*` labels directly, bypassing the synthesis. Two parallel edge-reading paths. | `viewer_assets/viewmodel.js` + `graph.js` | Low — duplication |
| S8 | Duplicate `ref:X:Y` labels across two cards (or on a single card via copy-paste) cause `INSERT INTO dependencies (...)` to hit a potential UNIQUE violation if the table has a composite PK. On collision, the surrounding transaction ROLLBACKs and the whole synthesis batch is lost — the viewer shows zero synthesized edges with only an error logged to stderr. No `ON CONFLICT` clause today. | `server.ts:127, 139` | Medium — silent-fail mode |
| S9 | `synthesizeEdgesFromLabels` opens the cache sqlite read-write; the HTTP handler concurrently serves `/beads.sqlite3` to SPA clients. Two near-simultaneous export-trigger requests could race on the WAL (same fd-leak class captured in the auto-memory `feedback_bun_sqlite_gc_before_subprocess.md`). The current code relies on `ensureExport` single-flight behavior but the invariant isn't asserted. | `server.ts:119` + HTTP layer | Low — latent under load |

### §4 — Fix Options

All 4 options constrain themselves to the viewer cache layer (sqlite schema + JS code). None require changes to `beads_rust`, the Go `bv` exporter, or the silmari-mcp save path.

#### Option A — Minimal cleanup (remove dead code + tighten filter)

**Mechanism:**
- Remove `|| 'blocks'` from `graph.js:1080`.
- Tighten WASM filter at `graph.js:686` from `type === 'blocks' || !d.type` to `type === 'blocks'`.
- Add an assertion/warning in `synthesizeEdgesFromLabels` that validates every inserted row has non-null type (belt-and-suspenders; the code already enforces this structurally).

**Blast radius:** graph.js (2 edits) + server.ts (1 edit). No schema change. No migration.

**Perf:** unchanged.

**Test story:** existing viewmodel/graph-helpers tests still cover the rendering paths. Add a 1-line server.ts test: after synthesis, `SELECT COUNT(*) FROM dependencies WHERE type IS NULL` returns 0.

**Rollback:** `git revert` the single commit. No data loss.

**Leaves in place:** the shared-table pollution (S4, S6). `dependencies` still holds both blocks and semantic edges. Every downstream consumer still has to filter by type.

#### Option B — Split schema (recommended)

**Mechanism:**
- Add a new table to the cache sqlite: `card_edges(source TEXT, target TEXT, type TEXT, PRIMARY KEY (source, target, type))`.
- Change `synthesizeEdgesFromLabels` to INSERT into `card_edges` (not `dependencies`). The `dependencies` table now holds only the beads_rust-native `blocks` rows that `bv --export-pages` copies from the source.
- In `graph.js`, the link-construction block reads from **both** tables:
  ```javascript
  let links = [
    ...dependencies.map(d => ({ source: d.issue_id, target: d.depends_on_id, type: 'blocks' })),
    ...cardEdges.map(e => ({ source: e.source, target: e.target, type: e.type })),
  ].filter(l => nodeIds.has(l.source) && nodeIds.has(l.target));
  ```
- The WASM filter at `graph.js:686` becomes trivially correct: `dependencies` is blocks-only, so no filter is needed (or a defensive `type === 'blocks'` just in case).
- Remove `|| 'blocks'` coalesce (dead under the new split).

**Blast radius:** server.ts (1 schema edit + 1 INSERT target change), graph.js (~10 lines in link-builder + WASM-filter simplification), cache schema migration (auto-runs on next export since `bv --export-pages` regenerates the file from scratch; no manual migration for users).

**Perf:** identical — same number of inserts, different table.

**Test story:**
- Unit: `synthesizeEdgesFromLabels` writes to `card_edges`, not `dependencies`. Assert `SELECT COUNT(*) FROM dependencies WHERE type != 'blocks'` returns 0 post-synthesis.
- Unit: link-builder unions both tables correctly. Assert full link-type distribution.
- Unit: WASM DAG builder receives only blocks edges. Assert `wasmGraph.edgeCount() === blocksCount`.
- Integration: existing browser-manual verification (hover, click, particle colors) — should be identical.

**Rollback:** `git revert` reverts both schema and JS changes. The cache sqlite is regenerated on next export, so no lingering state.

**Retires:** S2, S3, S4, S6. Leaves S1 (fresh-install blindness — still needs Tier C backfill) and S5 (every-export cost) and S7 (two parallel edge-reading paths — but now the schema is clean enough that consolidating them later is tractable).

#### Option C — Config-driven synthesis (hybrid)

**Mechanism:**
- Keep the shared `dependencies` table; add a config flag to `synthesizeEdgesFromLabels` that filters which edge types to synthesize (`all` / `blocks-only` / explicit list).
- Introduce a `config.edgeSynthesis` section in `beads.sqlite3.config.json` that the server writes and the SPA reads.

**Blast radius:** server.ts + config file schema + graph.js awareness of the config.

**Perf:** unchanged.

**Test story:** server-side synthesis tests per config mode; integration flaky due to config read timing.

**Rollback:** straightforward.

**Drawbacks:** doesn't retire any symptom; adds config surface; complicates the ADR for no real semantic gain. **Not recommended.**

#### Option D — Move synthesis to Go (`bv --export-pages`)

**Mechanism:**
- Port `synthesizeEdgesFromLabels` from TypeScript (`server.ts`) into the Go `bv` binary (`apps/silmari-viewer/cmd/bv/`).
- Remove the runtime JS synthesis step entirely; `server.ts` becomes a pure static server.

**Blast radius:** Go code (new function in bv), TS code (delete synthesizeEdgesFromLabels + all its callers), integration (regression tests for Go-side synthesis).

**Perf:** marginally better — synthesis runs once per export rather than per server request that triggers `bv`.

**Test story:** Go unit tests for synthesis; cross-language integration test. Much higher.

**Rollback:** `git revert` removes the Go code AND restores the TS synthesis. Two moving pieces.

**Drawbacks:** highest blast radius. Doesn't retire S2/S3/S4/S6 (the schema pollution stays). Gains only modest performance. **Not recommended as a standalone change** — worth revisiting later *combined* with Option B if scale becomes an issue.

### §5 — Recommendation: Option B (split schema)

**Why B over A:** Option A removes the symptoms that are already dead code (S2, S3) but leaves the structural issue (S4: shared-table pollution) and does nothing for S8 (duplicate-label ROLLBACK risk). Every future feature still needs to filter by type; every future bug still has a chance to forget. B retires S2, S3, S4, S6, and S8 in one stroke. The incremental cost over A is modest — B adds a `CREATE TABLE` + a slightly larger JS link-builder but the total touch surface is still <50 lines of production code across 2 files.

**Why B over C:** C adds config surface without semantic gain. B has a cleaner final state.

**Why B over D:** D has a much larger blast radius (cross-language) and doesn't retire the shared-table pollution. If we ever want D's perf benefit, B's split schema is a prerequisite — because a Go-side synthesizer should write to the cleaner target table, not inherit the pollution.

**Why B is safe:** the cache sqlite is regenerated from scratch on every `bv --export-pages` (the file lives under `/tmp/silmari-memory-card-viewer-cache/` — ephemeral). No migration logic needed; the next export just starts producing the new schema. If the new code has a bug, `git revert` plus a cache clear (`rm /tmp/silmari-memory-card-viewer-cache/beads.sqlite3`) restores the prior behavior with zero data loss.

**Why B doesn't break animation/colors:** the 2026-04-12 ZK-redesign Phase 3 (already landed — `graph-helpers.js:47-60` EDGE_COLORS, `graph.js:1428` uses `GH.edgeLinkColor(link.type)`, `vocab.js` has `V.edgeType` with per-type colors) reads `link.type` from the link object. Option B preserves `link.type` on every link; the coloring pipeline is unchanged.

**Why no Rust changes:** confirmed by the 2026-04-17 bv-graph-wasm audit — the crate's `addEdge(from: usize, to: usize)` API is type-agnostic (`apps/silmari-viewer/bv-graph-wasm/src/graph.rs:78-93`) and no algorithm in `src/algorithms/*.rs` branches on edge properties.

### §6 — Code References

#### The workaround, with line numbers

| File | Line(s) | What |
|------|---------|------|
| `apps/silmari-memory-card-viewer/server.ts` | 95-104 | `parseRefLabel` + `VALID_EDGE_TYPES` set (12 entries) |
| `apps/silmari-memory-card-viewer/server.ts` | 119-151 | `synthesizeEdgesFromLabels` — reads every card's labels, INSERTs synthetic rows with type set |
| `apps/silmari-memory-card-viewer/server.ts` | 127 | `INSERT INTO dependencies (issue_id, depends_on_id, type) VALUES (?, ?, ?)` — the INSERT target |
| `apps/silmari-memory-card-viewer/server.ts` | 161-178 | `refreshSnapshotConfig` — sha256 hash bump that invalidates the SPA's OPFS cache key; runs after synthesis |
| `apps/silmari-memory-card-viewer/viewer_assets/graph.js` | 684-693 | WASM filter: `d.type === 'blocks' \|\| !d.type` → `wasmGraph.addEdge(fromIdx, toIdx)` |
| `apps/silmari-memory-card-viewer/viewer_assets/graph.js` | 1067-1081 | Link construction: `type: d.type \|\| 'blocks'` coalesce |
| `apps/silmari-memory-card-viewer/viewer_assets/graph.js` | 1426-1429 | `GH.edgeLinkColor(link.type)` — already reads type correctly |
| `apps/silmari-memory-card-viewer/viewer_assets/graph-helpers.js` | 47-64 | `EDGE_COLORS` + `edgeLinkColor()` — the 12-type → hex-color map |
| `apps/silmari-memory-card-viewer/viewer_assets/vocab.js` | (V.edgeType section) | Per-type label/tier/color — consumed by detail panel at `index.html:3645-3671` |
| `apps/silmari-memory-card-viewer/viewer_assets/viewmodel.js` | `extractEdges()` | Parses `ref:*` labels for the detail panel (parallel path to synthesis) |
| `apps/silmari-mcp/scripts/backfill-edges-from-cosmic.ts` | entire | Tier C one-shot retroactive import |
| `apps/silmari-mcp/scripts/backfill-edges-from-cosmic.ts` | 48-67 | `COSMIC_TO_SILMARI_TYPE` mapping |
| `apps/silmari-mcp/scripts/backfill-edges-from-cosmic.ts` | 239-248 | Bun.gc(true) fd-leak workaround before subprocess writes |

#### Rust (for completeness — no changes needed)

| File | Line(s) | What |
|------|---------|------|
| `apps/silmari-viewer/bv-graph-wasm/src/graph.rs` | 19 | `adj: Vec<Vec<usize>>` — forward adjacency, edge = (from, to) indices only |
| `apps/silmari-viewer/bv-graph-wasm/src/graph.rs` | 23 | `rev_adj: Vec<Vec<usize>>` — reverse adjacency |
| `apps/silmari-viewer/bv-graph-wasm/src/graph.rs` | 33 | `GraphSnapshot.edges: Vec<(usize, usize)>` — serialization shape |
| `apps/silmari-viewer/bv-graph-wasm/src/graph.rs` | 78-93 | `#[wasm_bindgen(js_name = addEdge)] pub fn add_edge(&mut self, from: usize, to: usize)` — the only JS-facing edge API |
| `apps/silmari-viewer/bv-graph-wasm/src/graph.rs` | 173-186 | `fromJson` reconstructs via `(from, to)` tuples only |

Grep confirmation: `Edge|EdgeType|edge_type|\.type|label|kind` across all `.rs` files under `bv-graph-wasm/src/` returns **zero** hits in code paths (only doc comments and unrelated variable names).

### §7 — Cross-Coupling with the 2026-04-12 ZK Redesign

The 2026-04-12 TDD plan (`thoughts/searchable/shared/plans/2026-04-12-tdd-viewer-zettelkasten-graph-redesign.md`) has 5 phases; what landed:

- **Phase 1** (viewmodel.js extractors) — landed. Confirmed: `viewmodel.js` exports `extractKind/extractTrunk/extractBox/extractKeywords/extractFolgezettel/extractEdges`; `viewmodel.test.js` has the tests.
- **Phase 2** (vocab.js: V.kind, V.edgeType, V.trunk, V.brand) — landed. Confirmed: `vocab.test.js` exercises `V.edgeType` for all 12 types with tier/color.
- **Phase 3** (graph-helpers.js + graph.js wiring) — landed. Confirmed: `graph-helpers.js` exposes `kindColor/kindSize/edgeLinkColor` via `globalThis.GH`; `graph.js:1098-1102` calls `VM.extractKind/extractTrunk/extractBox/extractKeywords/extractFolgezettel` during `prepareGraphData()`; `graph.js:1428` uses `GH.edgeLinkColor(link.type)` for link coloring.
- **Phase 4** (hover tooltip + click detail panel) — partially landed. `index.html:3645-3671` has ZK-aware edge grouping with per-type colors; hover tooltip likely still using the older shape (not verified in this pass).
- **Phase 5** (sync to `apps/silmari-viewer/pkg/export/viewer_assets/`) — not verified in this pass.

**What the 2026-04-12 plan explicitly did NOT do (see its "What We're NOT Doing" table):**
> "Touching server.ts edge synthesis logic | It already synthesizes `ref:*` labels into dependency rows"

This is exactly the scope of the *current* (2026-04-17) research. The two plans are **complementary, non-overlapping**:

- 2026-04-12: ZK enrichment of the **presentation layer** (node colors, edge colors, card detail, hover) — assumed synthesis as a given.
- 2026-04-17 (this): cleanup of the **synthesis layer itself** — the presentation layer above it is now correct, so the synthesis can be cleaned up without breaking colors/animation.

The recommended Option B preserves `link.type` on every link, so all the 2026-04-12 Phase 3 coloring/sizing work continues to function unchanged.

### §8 — Open Questions

1. **Cache invalidation race:** when the schema changes (add `card_edges` table), the next `bv --export-pages` regenerates the whole sqlite file — safe. But does any long-running SPA session cache the OLD schema in OPFS? Need to verify `beads.sqlite3.config.json` hash bump is enough, or if a stronger cache-bust signal is needed.
2. **Detail-panel consolidation:** §3 S7 notes the detail panel reads edges via `extractEdges(labels)`, which is a separate path from the force-graph's `dependencies` table read. After Option B lands, should the detail panel read from the new `card_edges` table instead (one source of truth) — or keep the label-parsing path for robustness? Probably defer: the label path survives cache-file absence; the table path requires a live cache. Leave both for now, revisit if they drift.
3. **What if `beads_rust` relaxes the whitelist later?** The 2026-04-11 TDD plan §B.7.3 discussed this. If the engine accepts arbitrary dependency types in future, silmari could write edges directly into the source `dependencies` table and retire synthesis altogether. Option B does not preclude this — it simplifies the future migration (just stop populating `card_edges` and start populating `dependencies`).
4. **Viewer list-mode (non-graph) edge display:** none today. Out of scope for this research but worth surfacing.

---

## Architecture Documentation

The viewer has a **three-tier data pipeline**:

```
┌─────────────────────────────────────┐
│ silmari-mcp (source of truth)       │
│   ~/.silmari-memory/box2-ideas/     │
│   .beads/beads.db                   │
│   - issues table (card body + labels)│
│   - dependencies table (blocks only) │
└────────────────┬────────────────────┘
                 │  bv --export-pages
                 ▼
┌─────────────────────────────────────┐
│ Viewer cache (ephemeral)            │
│   /tmp/silmari-memory-card-viewer-  │
│     cache/beads.sqlite3             │
│   - issues table (copied)           │
│   - dependencies (blocks + NOW ALSO │
│     11 synthesized semantic types)  │
│   + synthesizeEdgesFromLabels runs  │
│     AFTER copy to inject synth rows │
└────────────────┬────────────────────┘
                 │  HTTP /beads.sqlite3
                 ▼
┌─────────────────────────────────────┐
│ SPA (Alpine.js + Force-Graph)       │
│   graph.js: reads dependencies table│
│     - filter → WASM (blocks-only)   │
│     - map → force-graph links       │
│       (all types, with `||'blocks'`)│
│   viewmodel.js: reads labels        │
│     - extractEdges for detail panel │
└─────────────────────────────────────┘
```

**Option B reshapes the middle tier** into:

```
┌─────────────────────────────────────┐
│ Viewer cache (Option B)             │
│   beads.sqlite3                     │
│   - issues                          │
│   - dependencies (blocks only — the │
│     copy stays clean)               │
│   + card_edges (NEW) — 11 types,    │
│     populated by synthesizer        │
└─────────────────────────────────────┘
```

and the SPA reads both tables into a unified link array.

---

## Historical Context (from thoughts/, memory, commits)

- **2026-04-06** — cosmic→silmari migration. ~360 non-blocks edges silently dropped because `beads_rust`'s whitelist rejected them.
- **2026-04-11** — TDD plan §B.7.3 (`Plans/tdd/2026-04-11-tdd-edge-creation-loop.md`) documented the whitelist constraint and the plan to work around it via labels. Introduced the Tier A save-time extractors (`apps/silmari-mcp/src/lib/edge-extractors.ts`) that emit `ref:*` labels on card save.
- **2026-04-12** — ZK viewer redesign research + TDD plan (5 phases, 1100 lines). Phases 1-3 focus on presentation-layer ZK enrichment; phases 4-5 on detail panel / sync. Explicitly punts on server.ts edge synthesis.
- **2026-04-17** — commit `6218b30` adds README §"Graph edges — how the viewer surfaces connections" documenting the workaround externally and capturing the Tier C backfill procedure. Also captured the `feedback_silmari_graph_edge_recovery.md` and `reference_cosmic_db_canonical_location.md` auto-memory files.
- **2026-04-17** — this research.

---

## Related Research

- `thoughts/searchable/shared/research/2026-04-12-beads-viewer-zettelkasten-graph-redesign.md` — parent research; this 2026-04-17 doc is the synthesis-layer follow-up.
- `thoughts/searchable/shared/plans/2026-04-12-tdd-viewer-zettelkasten-graph-redesign.md` — parent plan; Phases 1-3 landed, Phase 4-5 partially.
- `thoughts/searchable/shared/plans/2026-04-12-tdd-viewer-zettelkasten-graph-redesign-REVIEW.md` — REVIEW of the parent plan, all 3 warnings resolved.
- `Plans/tdd/2026-04-11-tdd-edge-creation-loop.md §B.7.3` — origin of the whitelist constraint and label workaround.

---

## TDD Plan Pointer

Chosen option (Option B) is elaborated into a Red-Green-Refactor implementation plan at:

`thoughts/searchable/shared/plans/2026-04-17-tdd-force-graph-edges-fix.md`
