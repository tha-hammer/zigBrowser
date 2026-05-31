---
date: 2026-04-22T12:15:00-04:00
reviewer: Silmari (via Maceo Jourdan)
git_commit: 6cbf8422a6789041d9d2478bdabed2ff70f48b6c
branch: main
repository: tha-hammer/silmari-agent-memory
topic: "Pre-implementation architectural review — Silmari compounding substrate TDD plan"
tags: [review, tdd, silmari, keyword-index, sparsity, contracts, api]
reviewed_plan: thoughts/searchable/shared/plans/2026-04-22-tdd-silmari-compounding-substrate.md
status: needs-major-revision
verdict: "3 critical defects + 4 warnings. Plan cannot ship as written — sparsity principle violated, atomicity promise impossible, existing API contract broken."
last_updated: 2026-04-22
---

# Plan Review Report — Silmari Compounding Substrate

**Plan**: `thoughts/searchable/shared/plans/2026-04-22-tdd-silmari-compounding-substrate.md`
**Verdict**: ❌ **Needs Major Revision** — 3 critical defects must be resolved before implementation begins

---

## Review Summary

| Category | Status | Issues |
|---|---|---|
| Contracts | ⚠️ Warning | 1 critical + 1 warning |
| Interfaces | ❌ Critical | 2 critical |
| Promises | ❌ Critical | 1 critical + 1 warning |
| Data Models | ❌ Critical | 1 critical + 1 warning |
| APIs | ✅ Well-Defined | 0 issues |

---

## Critical Findings (must resolve before coding begins)

### C1 — Sparsity Principle Violated (Phase 1)

**Where**: Plan §Phase 1, behaviors B1.7 / B1.10, bootstrap script spec.

**What I missed**: The existing `keyword-index.ts` at line 77 declares a constitutional constraint:

```typescript
/**
 * Maximum entry points per keyword. Luhmann's Zettelkasten ratio is
 * ~1:21 (3,200 keywords for 67,000 cards); the 4-entry cap forces
 * curators to choose the most representative entry points rather than
 * indexing every card that mentions a term. Plan §2.5.
 */
export const MAX_ENTRY_POINTS = 4;
```

And the data model (`KeywordEntry`, line 41-46) is **1-to-many** with explicit cap:

```typescript
export interface KeywordEntry {
  term: string;
  entry_points: string[];   // capped at MAX_ENTRY_POINTS=4
  curator: 'human' | 'agent';
  updated_at: string;
}
```

**What my plan says**: "Bootstrap script: one-pass scan of all 303 existing cards. For each card emit 2-4 terms... expect ≥600 entries". This treats the index as unbounded ("just upsert"). Scanning 303 cards × 3 terms = ~900 term emissions. If "algorithm" appears as a title token in 100 cards, my plan would index all 100. **This overrides Luhmann's sparsity cap and breaks the module's design.**

**Impact if shipped as-is**:
- Common terms explode to hundreds of entry points (defeats the purpose — recall returns a flood, not a curated navigator)
- Entry-point lists cease to mean "most representative"; they mean "all matches"
- The existing module's `rejected-full` branch gets triggered constantly; bootstrap either crashes or silently truncates FIFO-style without ranking
- The pitch-deck framing ("structure emerges from use", "typed curation") loses its substrate

**Required amendment**:

```diff
# Phase 1 bootstrap strategy MUST be rewritten

- Per-card: extract 2-4 terms, upsert each term → card mapping
+ Per-term-first pass with representativeness ranking:
+   1. Scan all 303 cards, collect {term → [candidate_cards]} inverted index
+   2. For each term with >4 candidates, rank by:
+      - Title-token match > kind-label > trunk-label
+      - Card kind priority (hub > structure > register > learning > fact > ...)
+      - Card folgezettel depth (shallower = more representative)
+      - Card created_at (older = proven over time)
+   3. Keep the top 4 entry points per term
+   4. Terms with ≤4 candidates: keep all
+ Expected result: ~200-400 terms, each with ≤4 entry points, total entries ≤1,600 (bounded)
```

**Severity**: ❌ Critical. This is a Luhmann-principle violation the plan's own research doc warns about.

---

### C2 — L2 Atomicity Promise is Architecturally Impossible (Phase 2)

**Where**: Plan §Phase 2 B2.2 — "Given a save in the same transaction as the card create, when the card create fails (rollback), then NO keyword entries are written (atomicity)."

**What I missed**: `brCreate` at `apps/silmari-mcp/src/lib/br-adapter.ts:142` uses `execFileSync` (synchronous **subprocess** invocation of the `br` binary). Subprocess writes to a DIFFERENT sqlite database (`~/.silmari-memory/box2-ideas/.beads/beads.db`, owned by beads_rust). Silmari.db (Phase 1's new keyword table) is a **separate sqlite file**, accessed via `bun:sqlite` in-process.

**Two processes, two sqlite files. They cannot share a transaction.** There is no primitive that makes "write keyword + invoke br subprocess" atomic.

**Impact if shipped as-is**:
- Test B2.2 can never pass as written — no implementation can satisfy it
- If card create succeeds and keyword write fails, partial state: card exists, no keyword entry (an orphan by keyword-absence)
- If card create fails and keyword write already ran, partial state: phantom keyword entry pointing to a nonexistent card
- L4's anchor check would see partial states and either accept orphans or reject legitimate saves

**Required amendment**:

```diff
# B2.2 must be reframed from "atomic transaction" to "ordered best-effort with compensation"

- **B2.2** — Given a save in the same transaction as the card create,
-   when the card create fails (rollback), then NO keyword entries are written.
+ **B2.2** — Given card create via `brCreate` (subprocess) succeeds,
+   when subsequent keyword-write fails, then saveCard returns with a
+   warning log noting partial state; the card is preserved (not rolled
+   back — rollback would require `br delete` which is its own subprocess
+   and introduces a recursive atomicity problem).
+ **B2.2a** — Given `brCreate` fails (returns null), when saveCard
+   evaluates, then no keyword-writes have happened (ordered: keyword
+   writes occur AFTER brCreate success, never before).
+ **B2.2b** — Given a phantom keyword entry (points to a nonexistent
+   cardId after an orphaned write), when the next bootstrap or keyword
+   reconciliation runs, then the phantom entry is garbage-collected.
+   (Reconciliation is a new Phase-1.5 script.)
```

**This needs a new Phase 1.5 ticket**: a keyword-reconciliation script that periodically scans for phantom entries (keyword_entries.card_id not in issues.id) and drops them. Without it, partial-failure accumulates cruft.

**Severity**: ❌ Critical. The atomicity invariant as written is unachievable; partial-state handling must replace it.

---

### C3 — API Contract Breaking Change (Phase 1)

**Where**: Plan §Phase 1 Green pseudocode at ~line 270 and ~line 285.

**What I missed**: The existing `addKeywordEntry` at `keyword-index.ts:233` returns a sophisticated discriminated union:

```typescript
export type AddKeywordResult =
  | { kind: 'added'; entry: KeywordEntry }
  | { kind: 'already-present'; entry: KeywordEntry }
  | { kind: 'rejected-full'; entry: KeywordEntry }
  | { kind: 'replaced'; entry: KeywordEntry; evicted: string };
```

My plan's green implementation returns `{ok: true, inserted: boolean}` — a completely different shape with no `kind` discriminator, no `entry` payload, no `rejected-full` / `replaced` branches, no `evicted` field.

**Callers that rely on this today** (verified via grep):
- `apps/silmari-mcp/src/index.ts:`~559 — `zk_keyword_add` MCP handler
- `apps/silmari-mcp/tests/keyword-index.test.ts` — tests assert on `result.kind === 'added' | 'rejected-full' | ...`

**Impact if shipped as-is**:
- All existing keyword-index tests break silently (assertion on `.kind` returns undefined, many tests become vacuous passes)
- `zk_keyword_add` MCP handler breaks at runtime (the returned shape changes)
- The FIFO-eviction semantics on `replaced` are lost — if the sparsity cap IS enforced in the new sqlite impl (per C1 fix), the `kind: 'replaced'` branch must still surface the evicted entry_point to callers

**Required amendment**:

```diff
# Phase 1 Green for addKeywordEntry MUST preserve the existing discriminated-union return type

- export function addKeywordEntry(opts): {ok: true; inserted: boolean}
+ export function addKeywordEntry(opts: {
+   term: string;
+   entryPoint: string;
+   curator: 'human' | 'agent';
+   force?: boolean;
+ }): AddKeywordResult

# The sqlite rewrite must replicate all 4 branches:
# - 'added' when the entry_point list grows
# - 'already-present' when the entry_point already exists
# - 'rejected-full' when the term has MAX_ENTRY_POINTS and !force
# - 'replaced' when force=true evicts oldest (FIFO by updated_at or insertion order)
```

**Also fix**: `curator` field in my plan used `'user' | 'agent'`; existing type is `'human' | 'agent'`. Typing mismatch.

**Severity**: ❌ Critical. Breaking an existing, well-documented, test-covered API without migration is a regression.

---

## Warnings (should address before ship)

### W1 — Data Model Shape Mismatch

**Where**: Plan §Phase 1 schema (`keyword_entries` table).

**My plan's sqlite schema**:
```sql
CREATE TABLE keyword_entries (
  term TEXT NOT NULL,
  card_id TEXT NOT NULL,
  trunk INTEGER,
  curator TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (term, card_id)
);
```

This is a **many-to-many** model (one row per term-card pair).

**Existing JSONL model**:
```typescript
KeywordEntry = {
  term: string;
  entry_points: string[];   // list
  curator: 'human' | 'agent';
  updated_at: string;       // ISO timestamp, not epoch
}
```

This is a **1-to-many** model (one record per term, with a list of entry_points).

**The mismatch breaks**:
- `readKeywordIndex()` — returns `KeywordEntry[]` today (grouped by term); my schema forces a GROUP BY in every read
- Eviction semantics — FIFO eviction in 1-to-many means "drop entry_points[0]"; in many-to-many it means "delete the row with oldest created_at for this term"
- `updated_at` semantics — timestamp of LAST UPDATE to the term (when any entry_point changed), not creation of a row

**Required amendment**: EITHER keep the 1-to-many shape in sqlite (less relational-idiomatic, but API-preserving), OR add a view/accessor layer that serves the old shape from the new schema:

```sql
-- Option A: Preserve 1-to-many shape (recommended for minimal churn)
CREATE TABLE keyword_entries (
  term TEXT PRIMARY KEY,
  entry_points TEXT NOT NULL,   -- JSON array; constrained to ≤4 elements at write-time
  curator TEXT NOT NULL,
  updated_at TEXT NOT NULL       -- ISO 8601
);

-- Option B: Many-to-many + view (more relational; larger caller churn)
CREATE TABLE keyword_entries (...);
CREATE VIEW keyword_index AS
  SELECT term, json_group_array(card_id) AS entry_points, ...
  FROM keyword_entries GROUP BY term;
```

**Severity**: ⚠️ Warning (contingent on C3's API preservation). Pick Option A for minimum disruption.

---

### W2 — Schema Versioning Missing

**Where**: Plan §Phase 1 Green (`CREATE TABLE IF NOT EXISTS ...`).

**Existing precedent**: `apps/silmari-mcp/src/lib/folgezettel.ts:54` uses a `_schema_version: 2` field with an explicit migration warning at line 213-217 when versions don't match.

**My plan**: No version tracking; relies solely on `CREATE TABLE IF NOT EXISTS`. Works for the first deployment, silently fails for schema evolution (e.g., adding a `representativeness_score` column later).

**Required amendment**:

```diff
# Phase 1 migration code

+ // Schema version tracking (pattern cloned from folgezettel.ts:54)
+ const KEYWORD_INDEX_SCHEMA_VERSION = 1;
+
+ db.exec(`
+   CREATE TABLE IF NOT EXISTS schema_versions (
+     table_name TEXT PRIMARY KEY,
+     version INTEGER NOT NULL,
+     applied_at INTEGER NOT NULL
+   );
+   CREATE TABLE IF NOT EXISTS keyword_entries ( ... );
+ `);
+
+ const currentVersion = db.query(`SELECT version FROM schema_versions WHERE table_name = 'keyword_entries'`).get()?.version ?? 0;
+ if (currentVersion < KEYWORD_INDEX_SCHEMA_VERSION) {
+   runMigrations(db, currentVersion);  // empty today; populates as new versions land
+   db.query(`INSERT OR REPLACE INTO schema_versions VALUES (?, ?, ?)`).run('keyword_entries', KEYWORD_INDEX_SCHEMA_VERSION, Date.now());
+ }
```

**Severity**: ⚠️ Warning. Current scope doesn't need migrations, but shipping without the scaffold creates a no-migration-path liability.

---

### W3 — Inference API Shape Unspecified (Phase 3)

**Where**: Plan §Phase 3 — "Internally calls Sonnet via `bun Tools/Inference.ts`".

**What I missed**: `SAI/Tools/Inference.ts:65` exports `async function inference(options: InferenceOptions): Promise<InferenceResult>` — an **in-process async import**, not a subprocess CLI. The prior verification shows hooks use `import { inference } from '../Tools/Inference'`.

**My plan was ambiguous** — "via `bun Tools/Inference.ts`" could mean subprocess OR import. Implementation difference:

- **In-process import** (recommended, matches prior hook pattern): faster, no subprocess overhead, easier mocking via module seam
- **Subprocess CLI**: slower, but cross-runtime compatible, easier process-level kill/timeout

**Required amendment**: Pin to **in-process import**:

```diff
# Phase 3 implementation

- Internally calls Sonnet via `bun Tools/Inference.ts`
+ Internally calls `inference()` via `import { inference } from '../../SAI/Tools/Inference.js'`
+ (in-process async call; matches pattern in RatingCapture.hook.ts:~165 and SessionAutoName.hook.ts).
+ Level: 'standard' (Sonnet, 30s timeout default).
+ Pass `expectJson: true` so the returned `result.parsed` is pre-parsed.
+ Caller checks `result.success`; on failure, returns `errorResult("semantic classifier unavailable: " + result.error)`.
```

**Severity**: ⚠️ Warning. Plan wasn't wrong, just underspecified.

---

### W4 — MCP Error Response Shape Inconsistent

**Where**: Plan §Phase 3 B3.4, B3.11, B3.13 return shapes like `{ok: false, error: "parse failure"}`.

**What I missed**: The actual helper at `apps/silmari-mcp/src/index.ts:340-344`:

```typescript
function errorResult(message: string) { ... }
function okResult(payload: unknown) { ... }
```

**Required amendment**: Every Phase 3 return shape must use `okResult(payload)` or `errorResult(message)` — NOT a raw `{ok, error}` literal. This preserves the MCP protocol's error channel vs. result-with-error-field distinction.

```diff
- return {ok: false, error: "newCardId not found"};
+ return errorResult("newCardId not found");

- return {ok: true, proposals: [...], candidatesScanned: N, scope: "line-of-thought"};
+ return okResult({proposals: [...], candidatesScanned: N, scope: "line-of-thought"});
```

**Severity**: ⚠️ Warning. Works either way, but inconsistent with existing tool handlers creates callsite confusion.

---

## Well-Defined sections (no changes needed)

- ✅ Phase 4 hook file-based state persistence + stdout injection pattern correctly cloned from `ChecklistStateInjector.hook.ts`
- ✅ `lineOfThought()` composition over existing `neighborhood()`, `chain()`, `listHubConstituents()`, `scanTrunk()` — primitives exist, plan uses them correctly
- ✅ Test isolation pattern (`mkdtempSync` + `SILMARI_DIR` before dynamic import) correctly identified
- ✅ `extractTitleMentions` as a new Tier A extractor — fits existing `edge-extractors.ts` shape
- ✅ `ExtractionFailure` error class — matches saveCard's existing `throw Error(...)` pattern for hard failures
- ✅ Phase 3 mock-then-real testing strategy — clean separation, no false coupling
- ✅ Phase-to-phase dependency chain in bd (1→2→3→4)
- ✅ Rollback strategy per phase (git revert + file cleanup)
- ✅ Cross-cutting invariants (#1-5)
- ✅ Anti-patterns explicitly excluded ("What we're NOT doing")

---

## Summary of required amendments

| # | Section | Type | Summary |
|---|---|---|---|
| C1 | Phase 1 B1.7, B1.10 | Critical | Bootstrap must honor MAX_ENTRY_POINTS=4 sparsity cap; add representativeness ranking |
| C2 | Phase 2 B2.2 | Critical | Remove atomic-transaction promise; add ordered-best-effort + phantom-entry reconciliation task |
| C3 | Phase 1 Green pseudocode | Critical | `addKeywordEntry` must return `AddKeywordResult` discriminated union; preserve all 4 branches; curator is `'human' | 'agent'` |
| W1 | Phase 1 schema | Warning | Preserve 1-to-many data model (term with entry_points list), not many-to-many |
| W2 | Phase 1 migration | Warning | Add schema-version tracking per folgezettel.ts:54 precedent |
| W3 | Phase 3 Inference call | Warning | Pin to in-process import (not subprocess CLI) |
| W4 | Phase 3 return shapes | Warning | Use `okResult()`/`errorResult()` helpers, not raw `{ok, error}` literals |

**New ticket required** (surfaced by C2):

- **Phase 1.5 — Keyword-entry phantom reconciliation script** — scans `keyword_entries` for rows whose `card_id` no longer exists in `issues`, drops them. Runs on startup OR on a schedule OR manually via CLI. Without this, partial-failure accumulates.

---

## Suggested Plan Amendments (unified)

```diff
# In §Phase 1 — Keyword Substrate

  **B1.7** — ...bootstrap script is run, then ≥ 600 entries land in keyword_entries
- (2-4 terms × 303 cards, minus dedup).
+ ≤ 4 × number of distinct terms (cap enforced per term); typical expected ≈ 800-1,200 entries.

+ **B1.7a** — Given a term with >4 candidate cards, when ranked, then the top 4 are
+   selected by: (1) title-token match weight, (2) card kind priority (hub>structure>...),
+   (3) folgezettel depth (shallower = more representative), (4) card age.
+
+ **B1.7b** — Given a term that already has MAX_ENTRY_POINTS=4 entries and bootstrap
+   encounters a 5th candidate, when `addKeywordEntry({force: false})` is called,
+   then result.kind === 'rejected-full' and no write happens.

# In §Phase 1 API contract

  export function addKeywordEntry(opts: {
    term: string;
    entryPoint: string;
-   curator: 'user'|'agent';
+   curator: 'human'|'agent';
    trunk?: number;
    force?: boolean;
- }): {ok: true; inserted: boolean}
+ }): AddKeywordResult

+ // AddKeywordResult remains the existing discriminated union:
+ //   | {kind: 'added'; entry: KeywordEntry}
+ //   | {kind: 'already-present'; entry: KeywordEntry}
+ //   | {kind: 'rejected-full'; entry: KeywordEntry}
+ //   | {kind: 'replaced'; entry: KeywordEntry; evicted: string}

# In §Phase 2 — Save-time Hardening

- **B2.2** — Given a save in the same transaction as the card create...
+ **B2.2** — Given brCreate returns null (create failed), when saveCard evaluates,
+   then no keyword writes have run (ordered: keywords written AFTER brCreate success).
+ **B2.2a** — Given brCreate succeeds and the subsequent keyword write fails, then
+   saveCard returns the card with a warning log; the card is preserved (no rollback).
+ **B2.2b** — Given phantom keyword entries exist after a partial failure, when
+   the Phase-1.5 reconciliation script runs, then phantom rows are garbage-collected.

# Add new ticket to bd chain:
+ Phase 1.5 — Keyword phantom reconciliation (P2, blocks Phase 2)
```

---

## Approval Status

- [ ] Ready for Implementation
- [ ] Needs Minor Revision
- [x] **Needs Major Revision** — 3 critical defects must be resolved before Phase 1 begins

---

## Recommended next actions

1. **Update the plan file** with the 3 critical amendments (C1, C2, C3) and 4 warnings (W1-W4). Estimated edit: ~60 lines changed across 3 sections.
2. **File a new bd ticket for Phase 1.5** (keyword-entry phantom reconciliation) and insert it into the dep chain between Phase 1 and Phase 2.
3. **Re-read the existing `keyword-index.ts` module header comment in full** (lines 1-40) before writing the sqlite rewrite — it encodes design principles that the plan must honor.
4. **Review `keyword-index.test.ts`** for the existing assertion shapes on `AddKeywordResult` discriminator. The sqlite rewrite's tests should preserve those assertions; new tests add sparsity-cap coverage.

---

## Appendix: What I got right (for future-me)

- Using `lineOfThought()` as a composition over existing primitives (not new plumbing) — correct
- File-based state + stdout injection for Phase 4 hook — correct (matches `ChecklistStateInjector.hook.ts`)
- Mocking Phase 3 during Phase 2 TDD — correct separation
- The single-sqlite-file approach (silmari.db) — correct (but see W2 about versioning)
- Cross-cutting invariants as regression guards — correct
- Deep-tier ISC count (55 behaviors) — adequate after C1/C2/C3 amendments will likely push it to ~62

## Appendix: What I got wrong (for the record)

1. Rubber-stamped my own rewrite of `keyword-index.ts` without reading the existing module's design principles — specifically the `MAX_ENTRY_POINTS` sparsity cap and FIFO eviction semantics
2. Assumed sqlite transaction atomicity was possible across brCreate (subprocess) and silmari.db (in-process) — architecturally impossible
3. Changed the public API shape of `addKeywordEntry` without noting the breaking change
4. Drifted curator type from `'human'` to `'user'` — minor typing regression
5. Skipped schema versioning despite precedent in the same codebase
6. Under-specified the Inference integration mechanism (CLI vs import) — ambiguity, not error

Lesson locked in: **when a review phase exists for a self-authored plan, genuinely re-read the code being modified**. The module header comment on `keyword-index.ts` is the single most important artifact I should have read FIRST during planning. I didn't. This review caught it; next time the plan should have.

*End of review.*
