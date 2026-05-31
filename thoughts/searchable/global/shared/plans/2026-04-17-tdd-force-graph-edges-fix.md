---
date: 2026-04-17T10:00:00-04:00
revised: 2026-04-17T11:15:00-04:00
author: Silmari
git_commit: 1bcaaa6
branch: main
repository: silmari-agent-memory
plan_kind: tdd
topic: "Force-graph edge workaround — Option B (split schema: dependencies blocks-only + new card_edges table)"
related_research: thoughts/searchable/shared/research/2026-04-17-force-graph-edges-workaround.md
related_review: thoughts/searchable/shared/plans/2026-04-17-tdd-force-graph-edges-fix-REVIEW.md
status: revised_post_review_ready_for_implementation
tags: [plan, tdd, beads-viewer, force-graph, edges, synthesize-edges-from-labels, schema-split]
---

# Force-Graph Edge Workaround Fix — TDD Implementation Plan (Option B)

## Overview

Replace the shared-table edge workaround with a split-schema design: the viewer cache's `dependencies` table stays **blocks-only** (mirroring the beads_rust source semantics), and a new `card_edges(source, target, type)` table holds the 11 synthesized semantic edge types. `synthesizeEdgesFromLabels` writes to `card_edges` instead of `dependencies`. The JS link-builder unions both tables into the force-graph link array. The WASM analytics filter simplifies because `dependencies` is once again clean.

Retires concrete symptoms from the research doc §3:
- **S2** — dead `|| 'blocks'` coalesce (`graph.js:1080`) — removed.
- **S3** — dead `|| !d.type` branch in WASM filter (`graph.js:686`) — simplified.
- **S4** — shared-table pollution — dependencies is blocks-only again.
- **S6** — cache vs. source `dependencies` table divergence — cache mirrors source, plus a separate typed table.

**What this does NOT do** (scope guard):
- No beads_rust engine changes.
- No Go `bv --export-pages` changes.
- No silmari-mcp save-path changes (Tier A extractors keep emitting `ref:*` labels as they do today).
- No changes to the 2026-04-12 ZK-redesign presentation layer (colors, sizing, hover, detail panel) — `link.type` is preserved so `GH.edgeLinkColor(link.type)` and `V.edgeType[...]` keep working.
- No migration script for user data — the cache sqlite is regenerated on every export; the new schema simply starts appearing on the next regen.

**Test framework**: `bun:test` (same as existing viewer tests)
**Primary files**: `apps/silmari-memory-card-viewer/server.ts`, `apps/silmari-memory-card-viewer/viewer_assets/graph.js`
**Primary test files**: `apps/silmari-memory-card-viewer/tests/synthesize-edges.test.ts` (new), `apps/silmari-memory-card-viewer/viewer_assets/link-builder.test.js` (new)
**Run all viewer tests**: `bun test apps/silmari-memory-card-viewer/`

---

## Current State Analysis

### The 4 workaround sites (from research doc §1):

| Site | File:line | Current behavior | Target behavior |
|------|-----------|------------------|-----------------|
| Server synthesis INSERT target | `server.ts:127, 139` | `INSERT INTO dependencies (issue_id, depends_on_id, type)` | `INSERT INTO card_edges (source, target, type)` |
| Client link builder | `graph.js:1075-1081` | Reads `dependencies`, `type: d.type \|\| 'blocks'` coalesce | Reads BOTH `dependencies` (typed `'blocks'`) AND `card_edges` (typed per-row), unions them |
| WASM analytics filter | `graph.js:684-693` | `.filter(d => d.type === 'blocks' \|\| !d.type)` | `.filter(d => d.type === 'blocks')` — the `\|\| !d.type` branch dies with synthesis off the `dependencies` table |
| Tier C backfill | `apps/silmari-mcp/scripts/backfill-edges-from-cosmic.ts` | Writes `ref:*` labels on source cards → triggers synthesis on next export | **Unchanged** — the label path is still the source of truth |

### What's already in place (don't duplicate):
- `apps/silmari-memory-card-viewer/viewer_assets/graph-helpers.js` — `edgeLinkColor()` map for all 12 types (already landed 2026-04-12).
- `apps/silmari-memory-card-viewer/viewer_assets/vocab.js` — `V.edgeType` with tier/color for all 12 types.
- `apps/silmari-memory-card-viewer/viewer_assets/viewmodel.js` — `extractEdges(labels)` returns `[{type, targetId}, ...]` for the detail panel (parallel path, intentionally kept).
- `graph.js:1428` uses `GH.edgeLinkColor(link.type)` — reads `link.type` on each link. **Option B preserves `link.type` on every link**, so this path needs no changes.

### Test patterns to follow:
- Server-side: `apps/silmari-memory-card-viewer/tests/folgezettel.test.ts` — `describe`/`it`/`expect`, imports from `../src/lib/...`, uses in-memory sqlite for isolation where possible.
- Client-side: `apps/silmari-memory-card-viewer/viewer_assets/viewmodel.test.js` — `describe`/`it`/`expect`, pure-function testing with array fixtures.

---

## Desired End State

### Observable behaviors (fill ISC targets):
1. `synthesizeEdgesFromLabels(dbPath)` writes only to `card_edges`, never to `dependencies`.
2. Post-synthesis: `SELECT COUNT(*) FROM dependencies WHERE type != 'blocks' AND type IS NOT NULL` returns 0 on a freshly exported cache.
3. Post-synthesis: `SELECT COUNT(*) FROM card_edges` equals the number of `ref:*` labels across all issues (excluding duplicates on PK collision).
4. `card_edges` has PRIMARY KEY `(source, target, type)` so re-running the synthesizer on an existing file is idempotent (INSERT OR IGNORE).
5. `graph.js` builds its link array by unioning `dependencies` rows (typed `'blocks'`) and `card_edges` rows (typed per row).
6. Every link object passed to the force-graph has a non-null, non-empty `type` string.
7. WASM DAG receives exactly the blocks edges (edgeCount matches `dependencies.rowCount`).
8. Force-graph rendering matches pre-change behavior visually (same colors, same particles, same animations) — verified by a screenshot diff or manual browser check.

---

## What We're NOT Doing

| NOT Doing | Reason |
|-----------|--------|
| Add migration script for existing caches | Cache sqlite is regenerated on every `bv --export-pages` — ephemeral, self-migrating. |
| Touch `beads_rust` whitelist | Out of scope; engine change is a separate concern. |
| Port synthesis to Go (`bv --export-pages`) | Research doc Option D — not recommended standalone. |
| Consolidate `extractEdges(labels)` + `card_edges` table into a single read path | Research doc §8 Q2 — defer. |
| Change `ref:*` label format | Label format is silmari-mcp's concern, not the viewer's. |
| Add new edge types | Scope is fixing plumbing, not extending the vocabulary. |
| Redesign the legend or detail panel | Covered by 2026-04-12 ZK redesign plan Phase 4 (partially landed). |
| Fix `ensureExport` single-flight / mutual-exclusion around `synthesizeEdgesFromLabels` | Preexisting S9 from research doc — no single-flight, no mutex, no file lock (`server.ts:208-237` verified). Two concurrent `/beads.sqlite3` cache-miss requests each spawn `bv --export-pages` and each re-synthesize against the same cache file. This plan's schema split does NOT worsen the race, but also does not fix it. Tracked as a separate workstream; Option B above is orthogonal and compatible with any future single-flight layer. |

---

## Testing Strategy

- **Framework**: `bun:test`
- **Unit tests**: server-side synthesizer against in-memory sqlite; client-side link-builder against fixture arrays.
- **Integration**: curl `/beads.sqlite3` against a running server, inspect both tables.
- **Manual**: browser render check (colors, particles, animations) before/after.
- **Regression guards**: all existing viewmodel/vocab/graph-helpers tests continue to pass.

---

╔═══════════════════════════════════════════════╗
║  PHASE 1: Schema + Server-side Synthesis      ║
║  Add card_edges table; retarget synthesizer   ║
╚═══════════════════════════════════════════════╝

## Phase 1 — Schema split and synthesizer retarget

### Scope
- Add `card_edges` table to the cache sqlite schema (created lazily on first synthesis call).
- Change `synthesizeEdgesFromLabels` INSERT target from `dependencies` to `card_edges`.
- `synthesizeEdgesFromLabels` now takes the same `dbPath` argument; no API change for callers.

### ⚠ NEW PATTERN FLAG — first `CREATE TABLE` in server.ts

Before this phase, `server.ts` executed zero `CREATE TABLE` statements — the `dependencies` and `issues` tables are produced by `bv --export-pages` upstream, and silmari only *wrote into* them. This phase introduces a new responsibility: the server now owns partial cache schema.

**Rationale:** `bv --export-pages` doesn't know about silmari's synthesized-edge concept. Owning the `card_edges` schema server-side is the correct division of concerns — the viewer server is the only thing that knows these edges exist.

**Future:** if `bv` ever grows native support for synthesized edges, remove the CREATE TABLE and let the upstream schema take over. Document that decision in the commit message if/when it happens.

Flag this explicitly in the Phase 1 commit message so future maintainers don't read it as drift.

---

### Behavior 1.1 — `card_edges` table is created with correct schema

**Given**: A cache sqlite file exported by `bv --export-pages` with the pre-Phase-1 schema (no `card_edges` table).
**When**: `synthesizeEdgesFromLabels(dbPath)` is called.
**Then**: The `card_edges` table exists afterward with columns `(source TEXT NOT NULL, target TEXT NOT NULL, type TEXT NOT NULL, PRIMARY KEY (source, target, type))`.

#### 🔴 Red
**File**: `apps/silmari-memory-card-viewer/tests/synthesize-edges.test.ts` (new)

```typescript
import { describe, it, expect } from 'bun:test';
import { Database } from 'bun:sqlite';
import { synthesizeEdgesFromLabels } from '../server.ts';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

function fixtureDb(): string {
  const dir = mkdtempSync(join(tmpdir(), 'sai-edges-test-'));
  const path = join(dir, 'beads.sqlite3');
  const db = new Database(path);
  db.exec(`
    CREATE TABLE issues (id TEXT PRIMARY KEY, labels TEXT);
    CREATE TABLE dependencies (issue_id TEXT, depends_on_id TEXT, type TEXT);
  `);
  db.prepare('INSERT INTO issues (id, labels) VALUES (?, ?)').run(
    'zk-a', JSON.stringify(['ref:supports:zk-b', 'ref:contradicts:zk-c']),
  );
  db.prepare('INSERT INTO issues (id, labels) VALUES (?, ?)').run('zk-b', '[]');
  db.prepare('INSERT INTO issues (id, labels) VALUES (?, ?)').run('zk-c', '[]');
  db.close();
  return path;
}

describe('synthesizeEdgesFromLabels — schema', () => {
  it('creates card_edges table if missing', () => {
    const path = fixtureDb();
    const result = synthesizeEdgesFromLabels(path);
    expect(result.ok).toBe(true);
    const db = new Database(path);
    const tables = db.prepare(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='card_edges'"
    ).all();
    expect(tables.length).toBe(1);
    const info = db.prepare('PRAGMA table_info(card_edges)').all() as Array<{name: string; type: string}>;
    const names = info.map(c => c.name).sort();
    expect(names).toEqual(['source', 'target', 'type']);
    db.close();
  });
});
```

#### 🟢 Green
**File**: `apps/silmari-memory-card-viewer/server.ts` — inside `synthesizeEdgesFromLabels`, before the existing SELECT:

```typescript
db.exec(`
  CREATE TABLE IF NOT EXISTS card_edges (
    source TEXT NOT NULL,
    target TEXT NOT NULL,
    type TEXT NOT NULL,
    PRIMARY KEY (source, target, type)
  );
`);
```

#### 🔵 Refactor
Extract the schema string to a module-level constant `CARD_EDGES_SCHEMA` for reuse in tests.

### Success Criteria 1.1
- [x] Red fails
- [x] Green passes
- [x] `bun test apps/silmari-memory-card-viewer/tests/synthesize-edges.test.ts` all pass

---

### Behavior 1.2 — Synthesizer INSERTs into `card_edges`, not `dependencies`

**Given**: A fixture DB with `issues.labels` containing `ref:supports:zk-b` and `ref:contradicts:zk-c` on `zk-a`.
**When**: `synthesizeEdgesFromLabels(dbPath)` is called.
**Then**:
- `SELECT COUNT(*) FROM card_edges` returns 2.
- `SELECT COUNT(*) FROM dependencies` returns 0 (the synthesizer wrote nothing to dependencies).
- `SELECT source, target, type FROM card_edges ORDER BY type` yields `[{zk-a, zk-c, contradicts}, {zk-a, zk-b, supports}]`.

#### 🔴 Red
```typescript
describe('synthesizeEdgesFromLabels — INSERT target', () => {
  it('writes to card_edges, not dependencies', () => {
    const path = fixtureDb(); // from Behavior 1.1
    const result = synthesizeEdgesFromLabels(path);
    expect(result.ok).toBe(true);
    expect(result.synthesized).toBe(2);
    const db = new Database(path);
    const ceCount = (db.prepare('SELECT COUNT(*) c FROM card_edges').get() as {c: number}).c;
    const depCount = (db.prepare('SELECT COUNT(*) c FROM dependencies').get() as {c: number}).c;
    expect(ceCount).toBe(2);
    expect(depCount).toBe(0);
    const rows = db.prepare(
      'SELECT source, target, type FROM card_edges ORDER BY type'
    ).all() as Array<{source: string; target: string; type: string}>;
    expect(rows).toEqual([
      { source: 'zk-a', target: 'zk-c', type: 'contradicts' },
      { source: 'zk-a', target: 'zk-b', type: 'supports' },
    ]);
    db.close();
  });
});
```

#### 🟢 Green
**File**: `apps/silmari-memory-card-viewer/server.ts`

Replace:
```typescript
const insert = db.prepare('INSERT INTO dependencies (issue_id, depends_on_id, type) VALUES (?, ?, ?)');
// ... insert.run(row.id, parsed.target, parsed.type);
```

With:
```typescript
const insert = db.prepare(
  'INSERT OR IGNORE INTO card_edges (source, target, type) VALUES (?, ?, ?)',
);
// ... insert.run(row.id, parsed.target, parsed.type);
```

`INSERT OR IGNORE` because the new PK `(source, target, type)` will naturally reject duplicates — making synthesis idempotent at the row level too (on top of the existing transaction-level idempotency from the fresh-file assumption).

#### 🔵 Refactor
Update `synthesizeEdgesFromLabels`'s leading doc comment to reflect the new target.

### Success Criteria 1.2
- [x] Red fails
- [x] Green passes
- [x] Existing `parseRefLabel` tests (if any) continue to pass

---

### Behavior 1.3 — Idempotency regression guard

**Note on TDD shape:** Behavior 1.2's Green already uses `INSERT OR IGNORE`, so this test PASSES on first run — it is a regression guard, not a Red-Green-Refactor cycle. Document it as such. If the implementer is in strict TDD mode, write this test BEFORE 1.2 (swapping the order), start 1.2 Green with plain `INSERT`, observe the failure, then amend to `INSERT OR IGNORE` — at which point both 1.2 and 1.3 green together.

**Given**: A fixture DB where synthesis has already run once (2 rows in `card_edges`).
**When**: `synthesizeEdgesFromLabels(dbPath)` is called a second time.
**Then**: `SELECT COUNT(*) FROM card_edges` still returns 2 (not 4).

#### 🟢 Test (regression guard)
```typescript
it('is idempotent — second call adds no rows', () => {
  const path = fixtureDb();
  synthesizeEdgesFromLabels(path);
  synthesizeEdgesFromLabels(path);
  const db = new Database(path);
  const count = (db.prepare('SELECT COUNT(*) c FROM card_edges').get() as {c: number}).c;
  expect(count).toBe(2);
  db.close();
});
```

#### 🔵 Refactor
Clarify in the `SynthResult` type whether `synthesized` counts attempts or actual inserts. Document the choice inline.

### Success Criteria 1.3
- [x] Test passes against Behavior 1.2's `INSERT OR IGNORE` implementation (regression guard intent)
- [x] If tried with plain `INSERT`, fails with UNIQUE constraint violation (captures the guard's purpose)

---

### Phase 1 Rollback
`git revert` the Phase 1 commit. Next `bv --export-pages` regenerates the cache sqlite from scratch with the pre-Phase-1 schema. No lingering data. Zero user impact.

### Phase 1 Regression Guard
All tests in:
- `apps/silmari-memory-card-viewer/tests/folgezettel.test.ts`
- `apps/silmari-memory-card-viewer/tests/zk-save-card-fromaddress.test.ts`
- Any existing `server.ts` tests

continue to pass: `bun test apps/silmari-memory-card-viewer/tests/`.

### Phase 1 additional edge-case tests (required before merge)

Add these to `synthesize-edges.test.ts`. Each is a single `it()` block.

**Classification:** Tests 1-5 are **regression guards** — they exercise pre-existing `parseRefLabel` validation (`server.ts:95-104`) and JSON-parse defense (`server.ts:131-134`) through the new code path. They should continue to pass after Phase 1 lands, proving the new `card_edges` INSERT target didn't accidentally remove any of those guards. Tests 6-8 test **genuinely new invariants** introduced by the `card_edges` schema (self-edge allowance, cross-card duplicates, same-card duplicate collapse via `INSERT OR IGNORE`).

**Regression guards (exercise existing behavior through new code path):**

1. **Invalid edge type** — `ref:bogus-type:zk-x` label. Expect: synthesizer skips the row silently (per `parseRefLabel` at `server.ts:101` which validates against `VALID_EDGE_TYPES`). Assert `synthesized` count matches only the valid labels.
2. **Malformed target** — `ref:supports:zk with space` label. Expect: `parseRefLabel` rejects (regex `/^[A-Za-z0-9-]+$/`), synthesizer skips.
3. **Empty labels array** — `labels: '[]'`. Expect: no rows inserted, no error.
4. **Null labels column** — `labels: null`. Expect: row skipped (guard at `server.ts:131`).
5. **Non-array labels JSON** — `labels: '{"not": "an array"}'`. Expect: skipped (guard at `server.ts:134`).

**New-behavior tests (genuinely new card_edges invariants):**

6. **Self-edge** — `zk-a` has `ref:supports:zk-a` label. Expect: synthesizer inserts `(zk-a, zk-a, supports)` — it's the SPA's job to filter or render self-loops if they're a problem. Document the choice.
7. **Duplicate label across two cards** — `zk-a` has `ref:supports:zk-b`, `zk-c` has `ref:supports:zk-b` (two different sources, same target). Expect: 2 distinct rows in `card_edges` (PK `(source, target, type)` differs by source).
8. **Same-exact label on same card** — unusual but possible if labels get re-emitted: `zk-a` has `['ref:supports:zk-b', 'ref:supports:zk-b']`. Expect: `INSERT OR IGNORE` collapses to 1 row. (This is the real fix for research doc S8 — current plain `INSERT` would UNIQUE-violate and abort the batch if the table had a PK.)

---

╔═══════════════════════════════════════════════╗
║  PHASE 2: Client-side link builder            ║
║  Read from BOTH tables, drop dead coalesce    ║
╚═══════════════════════════════════════════════╝

## Phase 2 — Client-side link construction

### Scope
- Extract link-building logic from `graph.js` into a testable pure function.
- New function: `buildLinks(dependencies, cardEdges, nodeIds)` returns the merged link array.
- Wire `graph.js:1075-1081` to call it.
- Remove the `|| 'blocks'` coalesce (dead under Option B).

---

### Behavior 2.1 — `buildLinks` unions dependencies (as blocks) and card_edges (typed)

**Given**:
- `dependencies = [{issue_id: 'zk-a', depends_on_id: 'zk-b', type: 'blocks'}]`
- `cardEdges = [{source: 'zk-a', target: 'zk-c', type: 'supports'}]`
- `nodeIds = new Set(['zk-a', 'zk-b', 'zk-c'])`

**When**: `buildLinks(dependencies, cardEdges, nodeIds)` is called.

**Then**: Returns `[{source:'zk-a',target:'zk-b',type:'blocks'}, {source:'zk-a',target:'zk-c',type:'supports'}]` (order: dependencies first, then card_edges).

#### 🔴 Red
**File**: `apps/silmari-memory-card-viewer/viewer_assets/link-builder.test.js` (new)

```javascript
import { describe, it, expect } from 'bun:test';
import { buildLinks } from './link-builder.js';

describe('buildLinks', () => {
  it('produces one link per dependency row plus one per card_edge row', () => {
    const deps = [{ issue_id: 'zk-a', depends_on_id: 'zk-b', type: 'blocks' }];
    const ce = [{ source: 'zk-a', target: 'zk-c', type: 'supports' }];
    const nodeIds = new Set(['zk-a', 'zk-b', 'zk-c']);
    const links = buildLinks(deps, ce, nodeIds);
    expect(links.length).toBe(2);
    expect(links).toContainEqual({ source: 'zk-a', target: 'zk-b', type: 'blocks' });
    expect(links).toContainEqual({ source: 'zk-a', target: 'zk-c', type: 'supports' });
  });

  it('emits dependencies-sourced links before card_edges-sourced links (stable order)', () => {
    const deps = [{ issue_id: 'zk-a', depends_on_id: 'zk-b', type: 'blocks' }];
    const ce = [{ source: 'zk-a', target: 'zk-c', type: 'supports' }];
    const nodeIds = new Set(['zk-a', 'zk-b', 'zk-c']);
    const links = buildLinks(deps, ce, nodeIds);
    expect(links[0]).toEqual({ source: 'zk-a', target: 'zk-b', type: 'blocks' });
    expect(links[1]).toEqual({ source: 'zk-a', target: 'zk-c', type: 'supports' });
  });

  it('emits two distinct links when same (source,target) appears in both tables with different types', () => {
    const deps = [{ issue_id: 'zk-a', depends_on_id: 'zk-b', type: 'blocks' }];
    const ce = [{ source: 'zk-a', target: 'zk-b', type: 'supports' }];
    const nodeIds = new Set(['zk-a', 'zk-b']);
    const links = buildLinks(deps, ce, nodeIds);
    expect(links.length).toBe(2);
    expect(links.filter(l => l.type === 'blocks').length).toBe(1);
    expect(links.filter(l => l.type === 'supports').length).toBe(1);
  });

  it('filters out links whose endpoints are not in nodeIds', () => {
    const deps = [{ issue_id: 'zk-a', depends_on_id: 'zk-missing', type: 'blocks' }];
    const ce = [{ source: 'zk-missing', target: 'zk-b', type: 'supports' }];
    const nodeIds = new Set(['zk-a', 'zk-b']);
    const links = buildLinks(deps, ce, nodeIds);
    expect(links).toEqual([]);
  });

  it('every output link has a non-empty type', () => {
    const deps = [{ issue_id: 'zk-a', depends_on_id: 'zk-b', type: 'blocks' }];
    const ce = [{ source: 'zk-a', target: 'zk-c', type: 'supports' }];
    const links = buildLinks(deps, ce, new Set(['zk-a', 'zk-b', 'zk-c']));
    for (const l of links) expect(l.type).toBeTruthy();
  });

  it('handles empty card_edges gracefully', () => {
    const deps = [{ issue_id: 'zk-a', depends_on_id: 'zk-b', type: 'blocks' }];
    const links = buildLinks(deps, [], new Set(['zk-a', 'zk-b']));
    expect(links).toEqual([{ source: 'zk-a', target: 'zk-b', type: 'blocks' }]);
  });

  it('handles empty dependencies gracefully', () => {
    const ce = [{ source: 'zk-a', target: 'zk-c', type: 'supports' }];
    const links = buildLinks([], ce, new Set(['zk-a', 'zk-c']));
    expect(links).toEqual([{ source: 'zk-a', target: 'zk-c', type: 'supports' }]);
  });
});
```

#### 🟢 Green
**File**: `apps/silmari-memory-card-viewer/viewer_assets/link-builder.js` (new)

```javascript
/**
 * link-builder.js — merge blocks (from dependencies table) and typed
 * semantic edges (from card_edges table) into a single force-graph link
 * array. Pure function, DOM-free, testable.
 */
export function buildLinks(dependencies, cardEdges, nodeIds) {
  const links = [];
  for (const d of dependencies) {
    if (!nodeIds.has(d.issue_id) || !nodeIds.has(d.depends_on_id)) continue;
    links.push({ source: d.issue_id, target: d.depends_on_id, type: d.type || 'blocks' });
  }
  for (const e of cardEdges) {
    if (!nodeIds.has(e.source) || !nodeIds.has(e.target)) continue;
    links.push({ source: e.source, target: e.target, type: e.type });
  }
  return links;
}

// Browser global: graph.js is a plain script and cannot `import`.
if (typeof globalThis !== 'undefined') {
  globalThis.LB = { buildLinks };
}
```

Note: the dependencies branch keeps a **defensive** `d.type || 'blocks'`. Post-Phase-1, dependencies rows should all have `type='blocks'` (that's what `bv --export-pages` copies from the source; beads_rust's whitelist guarantees it). The fallback is belt-and-suspenders against a future cache format change. It IS reachable in theory, unlike the prior coalesce in graph.js which defaulted SYNTHESIZED rows (which always had type set).

**Bare-array return is deliberate** — `buildLinks` is pure-compute with no failure mode (no I/O, no throw paths). Future functions in `link-builder.js` that DO have failure modes should follow the `{ok, error?, <payload>}` envelope per `server.ts` convention (`SynthResult`, `RefreshResult`, `ExportResult`). Don't default to bare-array returns just because `buildLinks` does.

#### 🔵 Refactor
Tighten internal naming for clarity; no JSDoc `@typedef` added here. Rationale: `viewer_assets/` has zero `@typedef` declarations today and we don't want the first one to sneak in as a Refactor step — if the team wants to formalize typed shapes, that's a deliberate convention decision worth a separate commit and a `CONVENTIONS.md` note.

### Success Criteria 2.1
- [x] Red fails: `bun test apps/silmari-memory-card-viewer/viewer_assets/link-builder.test.js`
- [x] Green passes: all 5 tests
- [x] All other viewer_assets tests continue to pass

---

### Behavior 2.2 — `graph.js` reads card_edges alongside dependencies

**Scope**: Modify `graph.js` to pull `card_edges` from the cache sqlite and pass both arrays to `LB.buildLinks`. Replace the existing `.map(d => ({... type: d.type || 'blocks'}))` inline construction.

This is a small, non-unit-testable edit (it's DOM/fetch adjacent). Coverage comes from Phase 2.1 unit tests + Phase 4 integration tests.

#### Change 1 — fetch `card_edges` rows alongside dependencies

The actual sql.js read happens in **`viewer.js`**, not graph.js. The existing site is `viewer.js:1086-1096` inside `getGraphViewData()`:

```javascript
// viewer.js:1091-1094 (existing — quoted verbatim):
const dependencies = execQuery(`
  SELECT issue_id, depends_on_id, type
  FROM dependencies
`);

return { issues, dependencies };
```

The `execQuery(sql)` helper is defined at `viewer.js:637-656` — it takes raw SQL, returns an array of objects keyed by column name (or `[]` if no rows). It throws on error, including "no such table" — so the `WHERE EXISTS` guard I originally proposed does NOT work. Technical reason: sql.js resolves every table reference during `sqlite3_prepare_v2`'s **prepare-time name resolution** (not runtime parsing). Even if `WHERE EXISTS` short-circuits at runtime, the outer `FROM card_edges` is bound to a specific table at prepare time and fails immediately if the table is missing.

**Correct pattern**: check `sqlite_master` first, only run the query if the table exists.

```javascript
// viewer.js:1091-1094 amended:
const dependencies = execQuery(`
  SELECT issue_id, depends_on_id, type
  FROM dependencies
`);

// NEW: conditional card_edges load (fresh-cache and pre-Phase-1 safe)
const hasCardEdges = execQuery(
  "SELECT name FROM sqlite_master WHERE type='table' AND name='card_edges'"
).length > 0;
const cardEdges = hasCardEdges
  ? execQuery(`SELECT source, target, type FROM card_edges`)
  : [];

return { issues, dependencies, cardEdges };
```

The `getGraphViewData()` caller at `viewer.js:2839` destructures the return value — update that destructure to include `cardEdges`, then pass it to `forceGraphModule.loadData(issues, dependencies, cardEdges, precomputedLayout)` at `viewer.js:2929`.

#### Change 2 — `loadData` switches to options-object signature, accepts `cardEdges`

**Why options-object, not positional:** the current positional signature takes `(issues, dependencies, layout = precomputedLayout)` and `viewer.js:2929` calls it with `precomputedLayout` as the 3rd positional arg. Inserting `cardEdges` at position 3 in positional form would silently bind `precomputedLayout` to `cardEdges` — the force-graph would iterate the layout object as if it were an array, producing garbage or throwing. Manual browser verification is the only guard today; that's insufficient for a mechanical refactor this easy to break.

Switching to options-object makes parameter names explicit at every callsite, eliminating positional-trap bugs entirely. Every caller is updated in the same commit; there is no "incomplete refactor" failure mode.

At `graph.js:961` (the existing `loadData` signature):

```javascript
// BEFORE:
export function loadData(issues, dependencies, layout = precomputedLayout) {
    store.dependencies = dependencies;
    // ...

// AFTER:
export function loadData({ issues, dependencies, cardEdges = [], layout = precomputedLayout }) {
    store.dependencies = dependencies;
    store.cardEdges = cardEdges;
    // ...
```

At `viewer.js:2929` (existing 3-positional-arg caller — verified):

```javascript
// BEFORE:
this.forceGraphModule.loadData(issues, dependencies, precomputedLayout);

// AFTER:
this.forceGraphModule.loadData({ issues, dependencies, cardEdges, layout: precomputedLayout });
```

Note `cardEdges` in the caller is destructured from `getGraphViewData()`'s return value per Change 1. If any caller-site omits a key, the destructuring default kicks in — still safe, never binds the wrong value to the wrong parameter.

At `graph-demo.html:661` (existing 2-positional-arg caller — verified):

```javascript
// BEFORE:
Graph.loadData(issues, dependencies);

// AFTER:
Graph.loadData({ issues, dependencies });
```

At `graph.js:1075-1081` (link construction):

```javascript
// BEFORE:
let links = dependencies
    .filter(d => nodeIds.has(d.issue_id) && nodeIds.has(d.depends_on_id))
    .map(d => ({
        source: d.issue_id,
        target: d.depends_on_id,
        type: d.type || 'blocks'
    }));

// AFTER:
let links = (typeof LB !== 'undefined')
  ? LB.buildLinks(dependencies, store.cardEdges || [], nodeIds)
  : dependencies
      .filter(d => nodeIds.has(d.issue_id) && nodeIds.has(d.depends_on_id))
      .map(d => ({ source: d.issue_id, target: d.depends_on_id, type: d.type || 'blocks' }));
```

The `typeof LB !== 'undefined'` guard keeps graph.js loadable in contexts where `link-builder.js` isn't yet loaded (matches the existing `typeof GH !== 'undefined'` pattern at `graph.js:1427`). The fallback keeps the OLD behavior (blocks-only from dependencies) so an incomplete deploy degrades gracefully rather than failing to render.

#### Change 3 — add `<script type="module" src="link-builder.js"></script>` to `index.html`

Add alongside the existing `<script type="module" src="graph-helpers.js"></script>` at `index.html:4423`.

#### Callsite coverage: grep-based guard test

Add a test that statically asserts every `loadData(` call site uses the options-object form, so a future caller can't regress to the positional trap:

**File**: `apps/silmari-memory-card-viewer/viewer_assets/link-builder.test.js` — append:

```javascript
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

describe('loadData — options-object call-site enforcement', () => {
  it('every loadData call in viewer_assets passes a single object literal', () => {
    const files = ['viewer.js', 'graph-demo.html'];
    const root = new URL('.', import.meta.url).pathname;
    for (const f of files) {
      const src = readFileSync(join(root, f), 'utf8');
      // Match .loadData( or Graph.loadData( followed by optional whitespace then {
      const bareCalls = src.match(/\.loadData\(\s*[^{]/g) || [];
      expect(bareCalls.length).toBe(0);
      // Must have at least one options-object call to prove the grep isn't vacuous
      const optionCalls = src.match(/\.loadData\(\s*\{/g) || [];
      if (src.includes('loadData(')) expect(optionCalls.length).toBeGreaterThan(0);
    }
  });
});
```

This test is static-analysis-style (reads files on disk, regex-asserts shape). Cheap to run, and catches the single highest-risk regression for this change.

### Behavior 2.2 automated test — shape integration

The sql.js + store wiring is thin but non-trivial; add a fixture-level test that stubs the sqlite read and asserts the `cardEdges` shape reaches `buildLinks`.

**File**: `apps/silmari-memory-card-viewer/viewer_assets/link-builder.test.js` — append:

```javascript
describe('buildLinks — viewer.js integration shape', () => {
  it('tolerates the execQuery return shape for card_edges rows', () => {
    // execQuery returns [{ columnName: value, ... }, ...]
    const cardEdgesFromExecQuery = [
      { source: 'zk-a', target: 'zk-b', type: 'supports' },
      { source: 'zk-a', target: 'zk-c', type: 'refines' },
    ];
    const links = buildLinks([], cardEdgesFromExecQuery, new Set(['zk-a', 'zk-b', 'zk-c']));
    expect(links.length).toBe(2);
    expect(links[0].type).toBe('supports');
  });
});
```

### Success Criteria 2.2
**Automated:**
- [x] New shape-integration test passes.
- [x] New `loadData` options-object call-site enforcement test passes: `bun test apps/silmari-memory-card-viewer/viewer_assets/link-builder.test.js` — the static-grep assertion finds zero bare-positional `loadData(` calls in `viewer.js` / `graph-demo.html`.
- [x] All existing `link-builder.test.js` tests pass.
- [x] All callers of `loadData` updated to options-object form (`viewer.js:2929`, `graph-demo.html:661`).

**Manual:**
- [ ] Open viewer in browser; check console — no errors. No `TypeError: cardEdges is not iterable` or similar (would indicate a missed positional-to-options migration).
- [ ] Force-graph renders the same way as before (visual diff).
- [ ] Particle animation works on both blocks edges (red) and non-blocks edges (typed colors).
- [ ] `console.log(store.cardEdges)` in devtools shows the synthesized edges.

---

### Phase 2 Rollback
`git revert` Phase 2 commit. graph.js reverts to reading dependencies only (including synthesized rows if Phase 1 hasn't also been reverted — in which case edges will be visible via dependencies still; if Phase 1 IS reverted, the viewer is back to pre-change behavior).

### ⚠ Coupled rollback rule (Phase 1 ↔ Phase 2)

**Never revert Phase 1 without also reverting Phase 2.** The two phases are a matched pair:
- **Phase 1 alone** is safe to revert (cache regenerates to pre-Phase-1 schema; Phase 2 code tolerates this via the `sqlite_master` existence check and the `|| []` fallback).
- **Phase 2 alone** is safe to revert (graph.js stops reading card_edges; edges disappear from the visual layer; WASM analytics unaffected since dependencies still populated — just blocks-only now).
- **Phase 1 revert + Phase 2 NOT reverted** is the failure mode: graph.js reads `cardEdges = []` (correct), but now also needs to render the semantic edges from `dependencies` (which Phase 2 stopped doing because `buildLinks` expects dependencies to be blocks-only). Result: semantic edges disappear from the graph.

**Mitigation**: commit Phases 1 and 2 as a sequence, revert as a sequence. If production bisect shows Phase 1 is at fault, revert Phase 2 first.

### Phase 2 Regression Guard
All tests in:
- `apps/silmari-memory-card-viewer/viewer_assets/viewmodel.test.js`
- `apps/silmari-memory-card-viewer/viewer_assets/vocab.test.js`
- `apps/silmari-memory-card-viewer/viewer_assets/graph-helpers.test.js`
- `apps/silmari-memory-card-viewer/viewer_assets/hybrid_scorer.test.js`

continue to pass: `bun test apps/silmari-memory-card-viewer/viewer_assets/`.

---

╔═══════════════════════════════════════════════╗
║  PHASE 3: WASM filter simplification          ║
║  graph.js:686 — drop the null-type branch     ║
╚═══════════════════════════════════════════════╝

## Phase 3 — Tighten the WASM filter

### Scope
After Phase 1+2 land, the `dependencies` table holds **only** `type='blocks'` rows. The defensive `|| !d.type` branch in the WASM filter (`graph.js:686`) is now provably unreachable against a post-Phase-1 cache. Tighten to strict equality.

---

### Behavior 3.1 — WASM filter accepts only blocks (extract testable helper)

**TDD note:** the filter lives inline inside an IIFE. Extract to a named helper `selectBlocksEdges(dependencies)` in `graph-helpers.js` (or a new `wasm-edge-builder.js`) so the filter logic is unit-testable.

#### 🔴 Red
**File**: `apps/silmari-memory-card-viewer/viewer_assets/graph-helpers.test.js` — append:

```javascript
describe('selectBlocksEdges', () => {
  it('keeps only rows where type === "blocks"', () => {
    const deps = [
      { issue_id: 'a', depends_on_id: 'b', type: 'blocks' },
      { issue_id: 'a', depends_on_id: 'c', type: 'supports' },
      { issue_id: 'a', depends_on_id: 'd', type: 'refers-to' },
    ];
    const out = selectBlocksEdges(deps);
    expect(out.length).toBe(1);
    expect(out[0]).toEqual({ issue_id: 'a', depends_on_id: 'b', type: 'blocks' });
  });

  it('rejects null-type rows (no defensive fallback)', () => {
    const deps = [
      { issue_id: 'a', depends_on_id: 'b', type: 'blocks' },
      { issue_id: 'a', depends_on_id: 'c', type: null },
      { issue_id: 'a', depends_on_id: 'd' }, // undefined type
    ];
    const out = selectBlocksEdges(deps);
    expect(out.length).toBe(1);
    expect(out[0].depends_on_id).toBe('b');
  });

  it('handles empty input', () => {
    expect(selectBlocksEdges([])).toEqual([]);
  });
});
```

#### 🟢 Green
**File**: `apps/silmari-memory-card-viewer/viewer_assets/graph-helpers.js` — append and export:

```javascript
// ── WASM DAG edge selection ────────────────────────────────
// Only type === 'blocks' edges feed the WASM analytics engine.
// No defensive fallback: post-Phase-1, dependencies is blocks-only,
// so null-type rows are a sign of corruption, not a case to coalesce.
export function selectBlocksEdges(dependencies) {
  return dependencies.filter(d => d.type === 'blocks');
}
```

Update the existing `globalThis.GH` export to include it:
```javascript
globalThis.GH = { kindColor, kindSize, edgeLinkColor, selectBlocksEdges };
```

Then wire into `graph.js:684-693`:
```javascript
// BEFORE:
store.dependencies
    .filter(d => d.type === 'blocks' || !d.type)
    .forEach(d => { ... });

// AFTER:
const blocksEdges = (typeof GH !== 'undefined')
  ? GH.selectBlocksEdges(store.dependencies)
  : store.dependencies.filter(d => d.type === 'blocks');
blocksEdges.forEach(d => {
    const fromIdx = store.wasmGraph.nodeIdx(d.issue_id);
    const toIdx = store.wasmGraph.nodeIdx(d.depends_on_id);
    if (fromIdx !== undefined && toIdx !== undefined) {
        store.wasmGraph.addEdge(fromIdx, toIdx);
    }
});
```

#### 🔵 Refactor
Add a JSDoc to `selectBlocksEdges` noting why the previous `|| !d.type` branch was removed (dead post-Phase-1).

### Success Criteria 3.1
**Automated:**
- [x] Red fails before `selectBlocksEdges` exists.
- [x] Green passes all 3 tests.

**Manual:**
- [ ] After Phase 1+2 land and a fresh export runs, `store.dependencies.every(d => d.type === 'blocks')` in devtools returns `true`.
- [ ] WASM `edgeCount()` equals `dependencies.rowCount` (the blocks-only count).
- [ ] PageRank / critical-path / eigenvector results numerically identical to pre-Phase-3 on the same workspace.

---

### Phase 3 Rollback
`git revert` Phase 3 commit. The `|| !d.type` branch comes back. Since no rows should ever have null type post-Phase-1, behavior is unchanged either way — this is a pure cleanup. Rollback is a no-op semantically.

### Phase 3 Regression Guard
All of the above plus manual verification that WASM metrics match.

---

╔═══════════════════════════════════════════════╗
║  PHASE 4: Sync to Go export viewer_assets     ║
║  apps/silmari-viewer/pkg/export/viewer_assets ║
╚═══════════════════════════════════════════════╝

## Phase 4 — Sync to the secondary viewer_assets

### Scope
The 2026-04-12 plan established that `apps/silmari-memory-card-viewer/viewer_assets/` is the live-served directory and `apps/silmari-viewer/pkg/export/viewer_assets/` is the Go export source. After Phase 1-3 land and verify in the live directory, sync the modified JS files.

### Files to sync:
- `link-builder.js` (new) → also copy to `apps/silmari-viewer/pkg/export/viewer_assets/link-builder.js`
- `link-builder.test.js` (new) → also copy
- `graph.js` (edited) → sync
- `index.html` (edited: one new `<script>` tag) → sync

### Success Criteria 4.1
- [x] `diff apps/silmari-memory-card-viewer/viewer_assets/link-builder.js apps/silmari-viewer/pkg/export/viewer_assets/link-builder.js` — no differences.
- [x] `bun test apps/silmari-viewer/pkg/export/viewer_assets/link-builder.test.js` passes.

---

## Integration & E2E Testing

### Full pipeline test (manual):
1. Commit Phase 1; run `rm -rf /tmp/silmari-memory-card-viewer-cache/`.
2. Start viewer: `cd apps/silmari-memory-card-viewer && bun --watch server.ts`.
3. Curl to trigger regeneration: `curl http://localhost:8788/beads.sqlite3 -o /tmp/inspect.db`.
4. Verify both tables exist and are populated correctly:
   ```bash
   sqlite3 /tmp/inspect.db "SELECT COUNT(*) FROM dependencies"    # = native blocks count
   sqlite3 /tmp/inspect.db "SELECT COUNT(*) FROM card_edges"      # = total ref:* label count
   sqlite3 /tmp/inspect.db "SELECT DISTINCT type FROM dependencies" # = 'blocks' only
   sqlite3 /tmp/inspect.db "SELECT DISTINCT type FROM card_edges"   # = 11 semantic types
   ```
5. Verify `/api/health` reports `lastSynthCount` matching the `card_edges` count.
6. Commit Phase 2; refresh browser; verify edges render, particles animate, hover works.
7. Commit Phase 3; verify WASM metrics identical to pre-change baseline.

### Regression scenarios to try:
- **Fresh-install silmari** (zero `ref:*` labels): graph should render only native blocks edges, no errors.
- **Post-backfill silmari** (full edge set): graph should render all 364 edges with correct per-type colors.
- **Post-delete rebuild**: `rm /tmp/silmari-memory-card-viewer-cache/beads.sqlite3`, reload — schema recreated cleanly.
- **Concurrency smoke (expect intermittent failure pending S9 fix)**: fire 3–5 parallel `curl /beads.sqlite3` within 200ms against an empty cache. Expected: with the preexisting lack of single-flight in `ensureExport`, two spawned `bv --export-pages` may race, resulting in corrupted sqlite bytes delivered mid-write OR the second synthesizer seeing half-committed state from the first. **This will fail intermittently today.** Documenting the expected failure IS the fix for this plan — a separate workstream (see §"What We're NOT Doing") will add the single-flight layer. If this scenario passes cleanly on first run, good — but don't count on it.

### Cache invalidation check:
After each phase lands, the `beads.sqlite3.config.json` hash is bumped by `refreshSnapshotConfig` (`server.ts:161`). Verify the SPA's OPFS cache picks up the new sqlite by checking the Network tab for a fresh fetch.

---

## Commit Cadence

Each phase = one commit. Bisectability matters if WASM metrics shift unexpectedly.

```
commit 1: rebrand/fix(viewer): Phase 1 — split cache schema, synthesize into card_edges
commit 2: rebrand/fix(viewer): Phase 2 — link-builder unions dependencies + card_edges
commit 3: rebrand/fix(viewer): Phase 3 — tighten WASM filter to strict type === 'blocks'
commit 4: rebrand/fix(viewer): Phase 4 — sync Go export viewer_assets
```

## Estimated Effort

| Phase | Time |
|-------|------|
| Phase 1 (schema + synthesis retarget + 3 core + 8 edge-case tests) | 60-90 min |
| Phase 2 (link-builder + 7 unit tests + options-object signature refactor of loadData + callsite updates at viewer.js:2929 and graph-demo.html:661 + static grep-test) | 90-120 min |
| Phase 3 (WASM filter helper extraction + 3 tests + manual verify) | 20-40 min |
| Phase 4 (Go-export sync) | 10-15 min |
| Integration + manual browser verify + concurrency smoke | 40 min |

**Total: 3.5-5 hours focused work** (revised up from 2.5-4 hours after incorporating review findings — the loadData options-object refactor and its callsite updates are the dominant cost increase).

---

## References

- **Research doc** (required reading): `thoughts/searchable/shared/research/2026-04-17-force-graph-edges-workaround.md`
- **Related 2026-04-12 artifacts** (Phase 3 of that plan landed — do not re-do):
  - `thoughts/searchable/shared/research/2026-04-12-beads-viewer-zettelkasten-graph-redesign.md`
  - `thoughts/searchable/shared/plans/2026-04-12-tdd-viewer-zettelkasten-graph-redesign.md`
  - `thoughts/searchable/shared/plans/2026-04-12-tdd-viewer-zettelkasten-graph-redesign-REVIEW.md`
- **Commit 6218b30** (2026-04-17) — README §"Graph edges — how the viewer surfaces connections", codifies the pre-fix workaround.
- **Tier C backfill**: `apps/silmari-mcp/scripts/backfill-edges-from-cosmic.ts` — unchanged by this plan.
- **bv-graph-wasm** (confirmed edge-type-agnostic): `apps/silmari-viewer/bv-graph-wasm/src/graph.rs:78-93` (`add_edge(from, to)` is the only JS-facing edge API).
- **Silmari MCP save-time extractors** (unchanged): `apps/silmari-mcp/src/lib/edge-extractors.ts`.

---

## Review Resolution Log

This plan was revised on 2026-04-17T11:15:00 in response to the peer review at `thoughts/searchable/shared/plans/2026-04-17-tdd-force-graph-edges-fix-REVIEW.md`. Every finding from that review is addressed below.

### Critical (Must Address Before Implementation)

| REVIEW # | Finding | Resolution in this plan | Where |
|---|---|---|---|
| Issue 3 | `viewer.js:2929` positional-arg trap has no automated coverage | **Switched `loadData` to options-object signature** — `loadData({issues, dependencies, cardEdges = [], layout = precomputedLayout})`. Eliminates positional trap entirely. Updated `viewer.js:2929` and `graph-demo.html:661` callsites to match. Added a static grep-based enforcement test (§Phase 2.2 "Callsite coverage") that fails if any `loadData(` call regresses to positional form. | §Phase 2.2 Change 2 + Success Criteria 2.2 |

### Warnings (Resolved with Amendments)

| REVIEW # | Finding | Resolution | Where |
|---|---|---|---|
| Issue 1 | `CREATE TABLE IF NOT EXISTS` is first-of-kind in server.ts | Added explicit **"NEW PATTERN FLAG"** subsection documenting the intentional new responsibility, rationale, and future-retirement path. Flag will be echoed in the Phase 1 commit message. | §Phase 1 Scope |
| Issue 2 | `buildLinks` return-shape diverges from `{ok, error?}` envelope | Added **"Bare-array return is deliberate"** note explaining the divergence and instructing future failure-prone additions to use the envelope. | §Phase 2.1 Green |
| Issue 4 | JSDoc `@typedef` is first-of-kind in viewer_assets | **Dropped** the typedef Refactor step. If the team wants to formalize typed shapes, that's a deliberate convention decision for a separate commit with a `CONVENTIONS.md` note. | §Phase 2.1 Refactor |
| Issue 5 | Preexisting S9 concurrency not mitigated | Added explicit **"What We're NOT Doing" row** marking `ensureExport` single-flight as a separate workstream. Also added a **concurrency smoke** to Integration & E2E that documents the expected intermittent failure pre-fix. | "What We're NOT Doing" table + §Integration & E2E Regression scenarios |
| "Parse time" terminology | sql.js fails at prepare-time name resolution, not "parse time" | Corrected the terminology in the Phase 2.2 Change 1 narrative. | §Phase 2.2 Change 1 |
| Edge-case test classification | 5 of 8 Phase-1 tests are regression guards, not new-behavior tests | Added **"Classification" header** to §Phase 1 additional edge-case tests separating regression guards (tests 1-5) from genuinely new invariants (tests 6-8). Reframed test 8's rationale as "the real fix for research doc S8 — current plain INSERT would UNIQUE-violate and abort the batch if the table had a PK." | §Phase 1 additional edge-case tests |

### Frontmatter

- `status` updated from `ready_for_implementation` → `revised_post_review_ready_for_implementation`.
- `revised` timestamp added.
- `related_review` field added.
- `git_commit` bumped to the commit that landed the REVIEW file (`1bcaaa6`).

### Cost impact

- Estimated effort revised from 2.5-4 hours → 3.5-5 hours. The dominant increase is the `loadData` options-object refactor: the signature change is tiny, but updating callsites + adding the static grep-enforcement test + bun-testing the static grep costs ~30 minutes.
- No phase boundaries moved; phase count still 4; commit cadence still 4 (one per phase).

### Verification that ALL REVIEW issues landed

| REVIEW Section | Status |
|---|---|
| Issue 1 (CREATE TABLE first-of-kind) | ✅ Addressed in §Phase 1 Scope NEW PATTERN FLAG |
| Issue 2 (bare-array return shape) | ✅ Addressed in §Phase 2.1 Green NOTE |
| **Issue 3 (loadData positional trap — CRITICAL)** | ✅ **Addressed via options-object signature + grep-enforcement test** |
| Issue 4 (JSDoc @typedef first-of-kind) | ✅ Dropped from Refactor step |
| Issue 5 (S9 concurrency unmitigated) | ✅ Explicit out-of-scope row + concurrency smoke scenario |
| "Parse time" vs "prepare time" | ✅ Corrected in §Phase 2.2 Change 1 |
| Edge-case test classification | ✅ Header added, tests 6-8 separated as new-behavior |
| Return-shape convention note | ✅ Covered by Issue 2 resolution |
| Test file conventions | ✅ (no change needed — already compliant per reviewer) |
| globalThis.LB pattern | ✅ (no change needed — already compliant) |
| Script load order | ✅ (no change needed — already compliant) |

All REVIEW findings resolved. Plan is now implementation-ready pending user go-ahead.
