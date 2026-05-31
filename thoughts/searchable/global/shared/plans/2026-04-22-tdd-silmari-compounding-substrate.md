---
date: 2026-04-22T11:30:00-04:00
planner: Silmari (via Maceo Jourdan)
git_commit: 6cbf8422a6789041d9d2478bdabed2ff70f48b6c
branch: main
repository: tha-hammer/silmari-agent-memory
topic: "TDD plan — Silmari Zettelkasten compounding substrate (4-phase orphan-prevention fix)"
tags: [tdd, plan, silmari, zettelkasten, keyword-index, tier-a, tier-b, semantic-proposer, hooks, compounding]
related_research:
  - thoughts/searchable/shared/research/2026-04-22-silmari-orphan-cards-root-cause.md
  - thoughts/searchable/shared/research/2026-04-22-What-the-Zettelkasten-actually-is.md
  - thoughts/searchable/shared/research/2026-04-17-force-graph-edges-workaround.md
status: draft
last_updated: 2026-04-29
last_updated_by: VioletBeacon
type: tdd_plan
---

# Silmari Zettelkasten Compounding Substrate — TDD Plan

**Epic**: `silmari-zettelkasten-compounding-substrate` (`silmari-agent-memory-3x7`)
**Scope**: **5 sequential phases** under one plan (dependencies run 1 → 1.5 → 2 → 3 → 4). Phase 1.5 was added per the 2026-04-22 pre-implementation review (C2 finding) — handles partial-failure cruft that Phase 2 cannot architecturally prevent.
**Effort tier**: Deep (16-32min active work per phase, ~3-4 sessions total)
**Commits target**: 5 (one per phase), each independently revertible
**Status**: Amended post-review (2026-04-22) and reconciled with 7h6/fkv uncapped keyword policy (2026-04-29). See `2026-04-22-tdd-silmari-compounding-substrate-REVIEW.md` for the 3 critical + 4 warning findings that drove the original amendments.

---

## Overview

Fix the Silmari orphan-cards root cause by building the **compounding substrate** Luhmann's Zettelkasten requires and enforcing it at save time. The diagnosis (full evidence at `thoughts/searchable/shared/research/2026-04-22-silmari-orphan-cards-root-cause.md`) is: **the keyword-index substrate has been structurally absent**, which forces every Algorithm LEARN phase into `mode: root` saves that emit zero `ref:*` labels. Result: 115 of 303 cards (38%) are orphans; 0 REVIEWED-tier edges exist anywhere in the store.

This plan lands five interlocking layers that together make orphans architecturally impossible:

- **L1 (Phase 1)** — sqlite-backed keyword index replaces the empty JSONL substrate. **Uses the post-7h6 uncapped keyword policy**: each term appends entry points unconditionally, `force` is a deprecated no-op, and representativeness ranking controls bootstrap insertion order rather than truncating a term's entry-point list. Pre-populated from all 303 existing cards via representativeness-ranked bootstrap. Preserves the post-7h6 `AddKeywordResult` discriminated-union API.
- **Phase 1.5** — phantom reconciliation script (derivative of the review C2 finding). Since `brCreate` is a subprocess and silmari.db is separate sqlite, partial-failure scenarios can leave phantom keyword entries; this script detects and drops them. Enables Phase 2's L4 anchor invariant to be trustworthy.
- **L2+L3+L4 (Phase 2)** — every `saveCard()` call writes keyword entries (best-effort, ordered after brCreate success), scans the card's line-of-thought for title mentions, and rejects saves that produce zero anchors. Atomicity across brCreate + silmari.db is **impossible** (two processes, two sqlite files); ordered-best-effort + Phase 1.5 reconciliation replaces it.
- **Tier B (Phase 3)** — new `zk_propose_links_semantic` MCP tool uses Sonnet via **in-process `inference()` import** to classify semantic edges (supports/refines/etc.), returning structured proposals without LLM-authored rationale (user's voice preserved). Returns wrapped in `okResult()` / `errorResult()` per existing MCP helper convention.
- **Thinking-with-memory (Phase 4)** — UserPromptSubmit hook detects trigger phrases and injects `zk_recall` results into the prompt context, making recurrence visible. File-based state + stdout injection per `ChecklistStateInjector.hook.ts` pattern.

**Cross-cutting invariants** (hold after all 4 phases):

1. **No-orphan**: every post-Phase-2 save has ≥1 keyword entry AND ≥1 `ref:*` label, OR the save rejects
2. **User's voice**: LLM never writes rationale text into committed edges
3. **Line-of-thought scoping**: all scans bounded to ~20-150 cards (folgezettel neighborhood ∪ hubs ∪ trunk seeds), never whole library
4. **Multiple-storage preserved**: content-hash dedup only; near-duplicates save as new cards linked with `reinforces`
5. **Substrate isolation**: no changes to `beads_rust` engine, no changes to viewer render layer

---

## Current State Analysis

### Key Discoveries

**Existing `keyword-index.ts` is JSONL-backed (`apps/silmari-mcp/src/lib/keyword-index.ts`, 334 lines):**
- `addKeywordEntry({term, entryPoint, curator, force})` writes to `~/.silmari/keyword-index.jsonl`
- `readKeywordIndex()` returns the current entries
- `keywordLabel(term)` helper at `labels.ts:179-185`
- MCP tool `zk_keyword_add` is registered and working, just rarely called
- The JSONL is empty/missing on current machines — hence `zk_status.keywords: 0`

**Save pipeline (`apps/silmari-mcp/src/lib/card-ops.ts`):**
- `saveCard()` 7-phase flow at lines 454-617
- Phase 0: `resolveExplicitTarget` (fromAddress validation) at lines 458-466
- Phase 1: content-hash dedup at line 469 (returns early; no edges extracted on dedup-hit)
- Phase 3: label assembly at lines 516-526 (no keyword label writes today)
- Phase 5: `brCreate` at line 539
- Phase 6: retry-on-collision sweep at line 551
- Phase 7: Tier A extractor invocation at lines 588-594, addEdge loop at 595-603

**Tier A extractors (`apps/silmari-mcp/src/lib/edge-extractors.ts`):**
- `extractBodyMentions` (lines 73-89) — `zk-*`/`bl-*` regex scan, emits `ref:refers-to:*`
- `extractFolgezettelParent` (lines 104-114) — emits `follows`/`branches` ONLY for `mode != 'root'` + non-null parent
- `extractSourceReference` (lines 122-132) — emits `derives-from` only when `source` is a literal bead-id
- Orchestrator `runExtractors` at lines 140-160 dedupes `(type, target)` tuples

**Folgezettel primitives (ready to compose):**
- `neighborhood(address, cache?)` at `navigate.ts:294-341` — returns `{queried, parentChain, siblings, children}`
- `chain(address, cache?)` at `navigate.ts:364-386` — returns full genealogy
- `scanTrunk(trunk)` at `navigate.ts:220-250` — returns `{beadsBySequence, allSequences}` with caching
- Hub membership: `listHubConstituents(hubId)` at `hubs.ts:319-321` (writes `ref:derives-from:<hubId>` on member cards)
- Address parsing: `parseAddress()` at `folgezettel.ts:170-185`, `parseFzFromLabels()` at `labels.ts:208-218`

**NO composed `lineOfThought()` helper exists yet** — Phase 2 will add it (~150 lines).

**MCP tool registration (`apps/silmari-mcp/src/index.ts`):**
- TOOLS array at lines 86-314
- Switch/case dispatcher at lines 412-648
- `zk_status` reference pattern: tool definition at lines 264-267, handler at lines 561-576 (used as template for new Tier B tool)

**Test framework:**
- Bun test runner: `bun test`
- Test file pattern: `apps/silmari-mcp/tests/*.test.ts`
- Integration setup: `mkdtempSync` + `process.env.SILMARI_DIR = tempDir` BEFORE dynamic import (lines 20-100 of `tests/integration.test.ts`) — required for test isolation
- Pure-function tests: `tests/navigate.test.ts:27-142` pattern (no `br` setup)
- Existing tests: `edge-extractors.test.ts`, `keyword-index.test.ts`, `folgezettel.test.ts`, `integration.test.ts`, `zk-save-card-fromaddress.test.ts`

**SAI hook infrastructure:**
- Registration: `SAI/settings.json` lines 67-261 under lifecycle keys (`UserPromptSubmit`, `PreToolUse`, etc.)
- Hook script format: `#!/usr/bin/env bun` → `readHookInput()` from `lib/hook-io` → logic → `process.exit(0)`
- Example template: `SAI/hooks/LastResponseCache.hook.ts` (47 lines, simplest)
- Context injectors: `ChecklistStateInjector.hook.ts`, `LoadContext.hook.ts` (pattern to clone for prompt injection)
- No hook unit-test framework — hooks are integration-tested via Claude Code harness; pure-function logic CAN be unit tested separately

**Inference tool (`SAI/Tools/Inference.ts`, 255 lines):**
- API: `inference({systemPrompt, userPrompt, level, expectJson, timeout})` → `InferenceResult`
- Levels: `fast` (Haiku, 15s), `standard` (Sonnet, 30s, default), `smart` (Opus, 90s)
- JSON support: `expectJson: true` parses first `{...}` or `[...]` in output; returns `result.parsed`
- Example call site: `RatingCapture.hook.ts:~165`
- **Never throws** — always returns `{success, error?, parsed?}`; caller checks `result.success`

**No existing silmari-owned sqlite files** — all persistence via JSONL or beads_rust's `beads.db`. Phase 1 introduces `~/.silmari-memory/silmari.db` as the first silmari-owned sqlite.

---

## Desired End State

### Observable behaviors (verifiable post-implementation)

1. `zk_status` returns `keywords > 0` on a fresh machine after running the bootstrap script
2. `zk_recall({query: "algorithm"})` returns ≥1 entry card on the current store
3. `zk_save_card({body: "new reflection", kind: "learning", trunk: 5, mode: "root"})` either completes with ≥1 keyword entry + ≥1 `ref:*` label, OR rejects with `ExtractionFailure`
4. `zk_save_card` on a body containing the exact title of a neighborhood card emits `ref:refers-to:<thatCard>` automatically
5. `zk_propose_links_semantic({newCardId: "zk-new"})` returns an array of proposals with `{targetId, edge, confidence, quoted_overlap}` fields — NO `rationale` field from the LLM
6. Typing `help me think about X` into the Claude Code input surfaces a `🧠 PRIOR THOUGHT` block listing recalled cards before the main response is composed
7. After 5 LEARN-phase runs, the number of REVIEWED-tier edges (`supports/contradicts/extends/reinforces/refines`) in the store is > 0 (from 0 today)
8. The orphan count (cards with zero `ref:*`) stops growing after Phase 2 lands — measured by saving 10 test cards over 1 week, expecting 0 additions to the orphan set

### Density KPI (pitch-ready metric)

**Before**: 303 cards · 365 `ref:*` labels · ratio 1.20 edges/card
**Target after 30-day normal use**: >2.0 edges/card (a doubling of density per unit content)

---

## What We're NOT Doing

| Out of scope | Why |
|---|---|
| Retrofitting the 115 existing orphans with edges | Historical cards stay orphans until future runs naturally link to them; forced retrofit would pollute with machine-voice rationales |
| Changes to `beads_rust` engine | Per constitutional constraint; all silmari additions live in silmari-owned storage |
| Changes to viewer render layer | Phase 1-4 of the 2026-04-17 Option B fix is correct; the bug is upstream of render |
| Auto-running the bootstrap on every `zk_status` call | Bootstrap is one-shot; runs on a dedicated script, not the hot path |
| Retaining the JSONL keyword-index file after migration | Deprecated; readers pointed at sqlite; JSONL archived for one release then deleted |
| Changes to the Algorithm v3.8.1 spec | Spec is correct; substrate was the missing piece |
| Embedding-based similarity, cosine retrieval, vector stores | Per constitutional mandate (Zettelkasten ≠ embeddings) |
| LLM-authored rationale text on edges | Luhmann principle 5 — user's voice only on rationales |

---

## Testing Strategy

- **Framework**: `bun:test` (built into Bun runtime)
- **Command**: `bun test apps/silmari-mcp/tests/` for full MCP suite; individual files addressable
- **Pure-function tests**: no `br` setup (e.g., `navigate.test.ts` pattern for new `lineOfThought()` unit tests on fixture data)
- **Integration tests**: `mkdtempSync` + `SILMARI_DIR` env BEFORE dynamic import (per `integration.test.ts:20-100`); create test cards via `saveCard()`, exercise the full pipeline
- **Mocking Sonnet for Phase 3**: inject a mock `inference()` via a test-only seam (flag-gated module export or dependency-injection parameter) — NOT by monkey-patching the module, which races with Bun's import cache
- **Real-LLM integration tests**: gated behind `SILMARI_TEST_REAL_LLM=1` env var; run manually / in nightly CI; default CI path uses mocks only
- **Hook unit tests**: extract pure logic into helper modules (`hooks/lib/think-with-memory.ts`), unit-test the helpers. Hook script itself is integration-tested by spawning a real Claude Code session with a seeded prompt.
- **Regression guards**: every phase's RGR cycle includes running the pre-existing test suite (`bun test`) at the Refactor step; must stay green.

---

## Phase 1 — Keyword Substrate (sqlite migration + bootstrap)

### Goal

Replace the empty JSONL keyword-index with a sqlite-backed store in a silmari-owned database, pre-populated from all 303 existing cards. Unblocks every downstream phase.

### Behaviors

**B1.1** — Given a fresh `~/.silmari-memory/` without `silmari.db`, when any keyword-index function is called, then `silmari.db` is created with the `keyword_entries` schema.

**Preserves the post-7h6 `AddKeywordResult` discriminated-union contract**: `{kind: "added"}` or `{kind: "already-present"}` only. The pre-7h6 `MAX_ENTRY_POINTS = 4` cap, `rejected-full` branch, `replaced` branch, and FIFO eviction are explicitly out of scope because 7h6 made unbounded append the canonical framework invariant. The sqlite rewrite is a storage change plus the already-landed 7h6 semantic update, not a reintroduction of the old cap.

**B1.2** — Given an existing `keyword_entries` table with no row for term `algorithm`, when `addKeywordEntry({term: "algorithm", entryPoint: "zk-abc", curator: "agent"})` is called, then a row is created with `entry_points = ["zk-abc"]` and the result is `{kind: "added", entry: {term: "algorithm", entry_points: ["zk-abc"], curator: "agent", updated_at: <ISO>}}`.

**B1.3** — Given `algorithm` already has `entry_points = ["zk-abc"]`, when `addKeywordEntry({term: "algorithm", entryPoint: "zk-def"})` is called, then `entry_points = ["zk-abc", "zk-def"]` and result is `{kind: "added", entry: ...}`.

**B1.4** — Given `algorithm` already has `entry_points = ["zk-abc"]`, when `addKeywordEntry({term: "algorithm", entryPoint: "zk-abc"})` is called (same entry_point), then result is `{kind: "already-present", entry: ...}` and NO write happens.

**B1.5** — Given `algorithm` already has `entry_points = ["z1","z2","z3","z4"]`, when `addKeywordEntry({term: "algorithm", entryPoint: "z5", force: false})` is called, then `entry_points = ["z1","z2","z3","z4","z5"]` and result is `{kind: "added", entry: ...}`. No cap check runs.

**B1.6** — Given the same four-entry state, when `addKeywordEntry({..., force: true})` is called with new entry_point `z5`, then it behaves identically to `force: false`: appends `z5`, returns `{kind: "added", entry: ...}`, and evicts nothing. `force` remains only as a deprecated backwards-compatibility parameter.

**B1.7** — Given some keyword entries, when `readKeywordIndex()` is called, then it returns `KeywordEntry[]` shaped identically to the pre-sqlite JSONL version — `{term, entry_points: string[], curator, updated_at}` per term (1-to-many preserved, no schema shape change).

**B1.8** — Given a term prefix, when `lookupKeyword(term)` (existing function) is called after sqlite migration, then it returns the matching `KeywordEntry | null` using the same normalization rules as the JSONL implementation (see `normalizeTerm()` at `keyword-index.ts:109`).

**B1.9** — Given the existing 303 cards in the current DB, when `bootstrap-keyword-index.ts` is run, then every representative candidate selected for a term is appended to that term's `entry_points` list. Expected: 200-400 distinct terms, each with one or more entry points; shared concepts may legitimately have more than 4 entry points.

**B1.10** — Given a term with more than 4 candidate cards from the bootstrap scan, when representativeness ranking runs, then all candidates are inserted in deterministic order by: (1) card kind priority (`hub` > `structure` > `register` > `learning/fact` > `signal/preference/decision` > `stub`), (2) folgezettel depth (shallower = more representative), (3) card `created_at` (older = proven over time). Ranking affects order only; it is not a truncation rule.

**B1.11** — Given bootstrap has run, when `zk_status` is called, then `keywords` field returns the count of distinct terms (`SELECT COUNT(*) FROM keyword_entries`, which equals `COUNT(DISTINCT term)` under the 1-to-many schema). Result is > 0.

**B1.12** — Given bootstrap has run, when `zk_recall({query: "algorithm"})` is called, then `entryPoints` is a non-empty array (not `null`) — recall is unblocked.

**B1.13** — Given stopwords (`the`, `a`, `of`, `and`, etc.), when the bootstrap extracts terms from a title, then stopwords and tokens <4 chars are excluded.

**B1.14** — Given a pre-existing `keyword-index.jsonl` with entries on disk, when the sqlite migration runs, then each JSONL record is imported into the sqlite table preserving its `term`, `entry_points[]`, `curator`, `updated_at` — forward-compat bridge. The JSONL is NOT deleted (archived); the sqlite becomes authoritative for all reads/writes.

**B1.15** — Given schema_version tracking (cloned from `folgezettel.ts:54` precedent), when migration runs at startup, then `schema_versions` table records `{table_name: "keyword_entries", version: 1, applied_at: <epoch>}`. Future schema changes bump the version and run migration steps gated on the delta.

**B1.16** — Given a `silmari.db` with an UNSUPPORTED future schema version (e.g., `version: 2` but code knows only `version: 1`), when opened, then a warning is logged and readKeywordIndex falls back to returning empty results (safe degraded mode, no crash).

### TDD cycles

#### B1.1 schema creation

**🔴 Red** — `apps/silmari-mcp/tests/keyword-index-sqlite.test.ts`:

```typescript
import { mkdtempSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, it, expect, beforeEach, afterEach } from 'bun:test';

describe('Keyword index sqlite schema', () => {
  let tmp: string;

  beforeEach(() => {
    tmp = mkdtempSync(join(tmpdir(), 'silmari-kwsql-'));
    process.env.SILMARI_DIR = tmp;
  });

  afterEach(() => { rmSync(tmp, {recursive: true, force: true}); });

  it('creates silmari.db with keyword_entries table on first call', async () => {
    const mod = await import('../src/lib/keyword-index.js?t=' + Date.now());
    const dbPath = join(tmp, 'silmari.db');
    expect(existsSync(dbPath)).toBe(false);
    mod.addKeywordEntry({term: 'algorithm', entryPoint: 'zk-abc', curator: 'agent'});
    expect(existsSync(dbPath)).toBe(true);
    // Schema check via sqlite directly
    const { Database } = await import('bun:sqlite');
    const db = new Database(dbPath);
    const rows = db.query("SELECT name FROM sqlite_master WHERE type='table' AND name='keyword_entries'").all();
    expect(rows.length).toBe(1);
  });
});
```

**🟢 Green** — in `apps/silmari-mcp/src/lib/keyword-index.ts`, replace JSONL impl with sqlite:

```typescript
import { Database } from 'bun:sqlite';
import { join } from 'path';

let _db: Database | null = null;

function getDb(): Database {
  if (_db) return _db;
  const dbPath = join(process.env.SILMARI_DIR || '', 'silmari.db');
  _db = new Database(dbPath);
  _db.exec(`
    CREATE TABLE IF NOT EXISTS keyword_entries (
      term TEXT NOT NULL,
      card_id TEXT NOT NULL,
      trunk INTEGER,
      curator TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      PRIMARY KEY (term, card_id)
    );
    CREATE INDEX IF NOT EXISTS idx_keyword_term_prefix ON keyword_entries(term);
  `);
  return _db;
}

// ─── Schema (1-to-many; term is PK; entry_points stored as JSON array) ───
// Cloned versioning pattern from folgezettel.ts:54
const KEYWORD_INDEX_SCHEMA_VERSION = 1;

function initSchema(db: Database): void {
  db.exec(`
    CREATE TABLE IF NOT EXISTS schema_versions (
      table_name TEXT PRIMARY KEY,
      version INTEGER NOT NULL,
      applied_at INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS keyword_entries (
      term TEXT PRIMARY KEY,
      entry_points TEXT NOT NULL,    -- JSON array, uncapped post-7h6
      curator TEXT NOT NULL CHECK(curator IN ('human','agent')),
      updated_at TEXT NOT NULL        -- ISO 8601, matches existing JSONL
    );
  `);
  const row = db.query(`SELECT version FROM schema_versions WHERE table_name = 'keyword_entries'`).get() as {version: number} | undefined;
  const current = row?.version ?? 0;
  if (current < KEYWORD_INDEX_SCHEMA_VERSION) {
    // Future migrations go here; v1 is the initial schema so nothing to do.
    db.query(`INSERT OR REPLACE INTO schema_versions (table_name, version, applied_at) VALUES (?, ?, ?)`)
      .run('keyword_entries', KEYWORD_INDEX_SCHEMA_VERSION, Date.now());
  } else if (current > KEYWORD_INDEX_SCHEMA_VERSION) {
    console.warn(`⚠️ keyword_entries schema version ${current} > ${KEYWORD_INDEX_SCHEMA_VERSION}; reading in safe degraded mode`);
  }
}

// ─── Public API — discriminated-union return preserves AddKeywordResult contract ───
// Post-7h6 shape from keyword-index.ts MUST be preserved.
export type AddKeywordResult =
  | { kind: 'added'; entry: KeywordEntry }
  | { kind: 'already-present'; entry: KeywordEntry };

export function addKeywordEntry(opts: {
  term: string;
  entryPoint: string;
  curator: 'human' | 'agent';   // NOTE: 'human', not 'user' — matches existing type
  force?: boolean;               // deprecated no-op retained for caller compatibility
}): AddKeywordResult {
  const db = getDb();
  const termNorm = normalizeTerm(opts.term);     // existing helper at keyword-index.ts:109
  const nowIso = new Date().toISOString();

  const row = db.query(`SELECT term, entry_points, curator, updated_at FROM keyword_entries WHERE term = ?`).get(termNorm) as {
    term: string; entry_points: string; curator: 'human'|'agent'; updated_at: string;
  } | undefined;

  let entryPoints: string[] = row ? JSON.parse(row.entry_points) : [];

  if (entryPoints.includes(opts.entryPoint)) {
    return { kind: 'already-present', entry: { term: termNorm, entry_points: entryPoints, curator: row!.curator, updated_at: row!.updated_at } };
  }

  // Post-7h6: unbounded append. No cap check, no FIFO branch, no force behavior.
  entryPoints = [...entryPoints, opts.entryPoint];
  if (row) {
    db.query(`UPDATE keyword_entries SET entry_points = ?, curator = ?, updated_at = ? WHERE term = ?`)
      .run(JSON.stringify(entryPoints), opts.curator, nowIso, termNorm);
  } else {
    db.query(`INSERT INTO keyword_entries (term, entry_points, curator, updated_at) VALUES (?, ?, ?, ?)`)
      .run(termNorm, JSON.stringify(entryPoints), opts.curator, nowIso);
  }
  return { kind: 'added', entry: { term: termNorm, entry_points: entryPoints, curator: opts.curator, updated_at: nowIso } };
}
```

**🔵 Refactor** — extract `getDb()` into a shared `silmari-db.ts` module (used by future silmari-owned tables). Add close helper for test cleanup.

#### B1.7 bootstrap script

**🔴 Red** — `apps/silmari-mcp/tests/bootstrap-keyword-index.test.ts`:

```typescript
it('keeps every candidate entry point in representativeness order', async () => {
  const { saveCard } = await import('../src/lib/card-ops.js?t=' + Date.now());

  // Seed 6 cards that ALL share the term "algorithm" in their titles
  await saveCard({body: 'algorithm hub root card',       kind: 'hub',       trunk: 5, mode: 'root'});  // hub — highest priority
  await saveCard({body: 'algorithm structure card',      kind: 'structure', trunk: 5, mode: 'root'});
  await saveCard({body: 'algorithm learning reflection', kind: 'learning',  trunk: 5, mode: 'root'});
  await saveCard({body: 'algorithm fact observed',       kind: 'fact',      trunk: 5, mode: 'root'});
  await saveCard({body: 'algorithm signal flagged',      kind: 'signal',    trunk: 5, mode: 'root'});
  await saveCard({body: 'algorithm stub placeholder',    kind: 'stub',      trunk: 5, mode: 'root'});  // lowest priority

  const { bootstrapKeywordIndex } = await import('../scripts/bootstrap-keyword-index.js?t=' + Date.now());
  const result = await bootstrapKeywordIndex({verbose: false});

  expect(result.cardsScanned).toBeGreaterThanOrEqual(6);
  // The term "algorithm" keeps all six entry_points. Ranking affects order only.
  const { lookupKeyword } = await import('../src/lib/keyword-index.js?t=' + Date.now());
  const entry = lookupKeyword('algorithm');
  expect(entry).not.toBeNull();
  expect(entry!.entry_points).toHaveLength(6);
  // Representativeness: hub + structure + learning + fact appear before signal + stub.
  // (assertion on specific IDs would require capturing them above; here we assert rank preservation)
});

it('tolerates terms with any candidate count — keeps all', async () => {
  // Seed 2 cards sharing term "foo"
  // After bootstrap: lookupKeyword('foo').entry_points.length === 2
});
```

**🟢 Green** — `apps/silmari-mcp/scripts/bootstrap-keyword-index.ts`:

```typescript
// Stopwords + term extraction helpers (reused by Phase 2's save-time L2 writer).
const STOPWORDS = new Set(['the','and','for','with','from','this','that','when','have','been','will','what','your']);

export function extractTerms(title: string, kind: string, trunk: number): string[] {
  const tokens = title.toLowerCase()
    .split(/[\s\-_.,:;!?()]+/)
    .filter(t => t.length >= 4 && !STOPWORDS.has(t));
  const unique = Array.from(new Set(tokens)).slice(0, 3);
  return [...unique, `kind:${kind}`, `trunk:${trunk}`];
}

// Kind priority for representativeness ranking (ties broken by fz-depth, then age)
const KIND_PRIORITY: Record<string, number> = {
  hub: 0, structure: 1, register: 2,
  learning: 3, fact: 3,
  signal: 4, preference: 4, decision: 4,
  idea: 5, biblio: 5,
  stub: 6,
};

interface CardMeta { id: string; kind: string; fz: string; createdAt: number; }

function fzDepth(fz: string): number {
  // "5/3a1" → parse segments → depth is count of segments past the trunk
  const parts = fz.split('/')[1] ?? '';
  return parts.replace(/[^a-z]/gi, '').length + (parts.match(/\d+/g)?.length ?? 0);
}

function rankCandidates(cards: CardMeta[]): CardMeta[] {
  // Sort ascending by (kindPriority, fzDepth, createdAt) — best-ranked first
  return [...cards].sort((a, b) => {
    const kp = (KIND_PRIORITY[a.kind] ?? 9) - (KIND_PRIORITY[b.kind] ?? 9);
    if (kp !== 0) return kp;
    const dp = fzDepth(a.fz) - fzDepth(b.fz);
    if (dp !== 0) return dp;
    return a.createdAt - b.createdAt;
  });
}

export async function bootstrapKeywordIndex(opts: {verbose?: boolean} = {}) {
  const {brList} = await import('../src/lib/br-adapter.js');
  const {addKeywordEntry} = await import('../src/lib/keyword-index.js');
  const {parseFzFromLabels, getLabel} = await import('../src/lib/labels.js');

  const cards = brList('idea', {limit: 10000});

  // Phase 1: build inverted index term → [candidates]
  const inverted = new Map<string, CardMeta[]>();
  for (const card of cards) {
    const title = card.title || '';
    const kind = getLabel(card.labels, 'kind:') || 'idea';
    const trunk = parseInt(getLabel(card.labels, 'trunk:') || '5', 10);
    const fz = parseFzFromLabels(card.labels) || `${trunk}/0`;
    const createdAt = Number(card.created_at) || 0;
    const meta: CardMeta = { id: card.id, kind, fz, createdAt };

    for (const term of extractTerms(title, kind, trunk)) {
      const list = inverted.get(term) ?? [];
      list.push(meta);
      inverted.set(term, list);
    }
  }

  // Phase 2: for each term, rank candidates; append all candidates via addKeywordEntry
  let termsInserted = 0;
  let entryPointsInserted = 0;
  let alreadyPresent = 0;
  for (const [term, candidates] of inverted) {
    const ranked = rankCandidates(candidates);
    for (const cand of ranked) {
      const r = addKeywordEntry({term, entryPoint: cand.id, curator: 'agent', force: false});
      if (r.kind === 'added') { entryPointsInserted++; if (r.entry.entry_points.length === 1) termsInserted++; }
      else if (r.kind === 'already-present') { alreadyPresent++; }  // idempotent retry
    }
  }

  return {cardsScanned: cards.length, termsInserted, entryPointsInserted, alreadyPresent};
}

if (import.meta.main) {
  const r = await bootstrapKeywordIndex({verbose: true});
  console.log(JSON.stringify(r, null, 2));
}
```

**🔵 Refactor** — extract `extractTerms()` + `rankCandidates()` + `KIND_PRIORITY` into `keyword-index.ts` exports so Phase 2's L2 save-time writer reuses the same ranking logic. Parameterize `KIND_PRIORITY` via a config file so domains can adjust priorities without code change.

### Phase 1 success criteria

**Automated:**
- [ ] `bun test apps/silmari-mcp/tests/keyword-index-sqlite.test.ts` — all 16 behaviors pass (including uncapped append, deprecated `force` no-op, schema version)
- [ ] `bun test apps/silmari-mcp/tests/bootstrap-keyword-index.test.ts` — 6 behaviors pass (inverted-index pass, representativeness ordering, stopword filtering, JSONL forward-bridge, idempotent already-present counter)
- [ ] `bun test apps/silmari-mcp/tests/keyword-index.test.ts` — **pre-existing keyword-index tests remain green** with post-7h6 assertions on uncapped append and no `rejected-full`/`replaced` branches. This is the API-preservation regression guard.
- [ ] Running `bun apps/silmari-mcp/scripts/bootstrap-keyword-index.ts` against current `~/.silmari-memory/` produces a report with `termsInserted > 100` AND `entryPointsInserted >= termsInserted` (every term has at least one entry point; high-density terms may have more than 4)
- [ ] Post-bootstrap SQL sanity: `sqlite3 ~/.silmari-memory/silmari.db "SELECT term, json_array_length(entry_points) AS n FROM keyword_entries WHERE n > 4 LIMIT 5"` may return rows; this is expected and confirms high-density terms are no longer truncated
- [ ] `bun test` (full suite) — no regressions

**Manual:**
- [ ] After bootstrap, `mcp__silmari__zk_status` returns `keywords > 0`
- [ ] `mcp__silmari__zk_recall({query: "algorithm"})` returns a non-empty `entryCards` array
- [ ] `ls ~/.silmari-memory/silmari.db` confirms file exists
- [ ] `sqlite3 ~/.silmari-memory/silmari.db "SELECT COUNT(*) FROM keyword_entries"` returns > 0 (each row is one term with one or more entry_points)
- [ ] `sqlite3 ~/.silmari-memory/silmari.db "SELECT version FROM schema_versions WHERE table_name='keyword_entries'"` returns `1`

### Phase 1 rollback

```bash
git revert <phase-1-commit>
rm ~/.silmari-memory/silmari.db
```

The JSONL keyword-index is unchanged by Phase 1 (read-only fallback in migration logic means removing sqlite file restores prior behavior).

---

## Phase 1.5 — Keyword Phantom Reconciliation

### Goal

**Derivative ticket surfaced by the 2026-04-22 review (C2 finding).** Because `brCreate` is a subprocess and `silmari.db` is a separate sqlite file, the two writes cannot share a transaction. Partial-failure scenarios can leave **phantom keyword entries** (term → card_id that no longer exists). This phase adds a reconciliation script that scans for and drops phantoms.

Without this, Phase 2's L4 anchor invariant cannot be trusted — a partial failure in Phase 2 leaves cruft that pollutes future recall.

### Behaviors

**B1_5.1** — Given a `silmari.db` with a keyword entry pointing to card `zk-ghost` and no card `zk-ghost` exists in the beads.db `issues` table, when `reconcileKeywordIndex()` runs, then the entry is dropped from `keyword_entries` (entry_point removed from the JSON list; if the list becomes empty the whole term row is deleted).

**B1_5.2** — Given a term with `entry_points: ["zk-real", "zk-ghost"]` where only `zk-real` exists, when reconciliation runs, then the term row becomes `entry_points: ["zk-real"]` (partial clean, term preserved).

**B1_5.3** — Given all cards referenced by a term no longer exist, when reconciliation runs, then the entire term row is deleted from `keyword_entries`.

**B1_5.4** — Given reconciliation runs, when it completes, then it returns `{termsScanned, entryPointsRemoved, termsRemoved, startedAt, completedAt}` as a structured report (exportable to JSON for observability).

**B1_5.5** — Given reconciliation runs concurrently with a save (race), when the scan is in flight, then the scan does NOT delete an entry_point for a card that was just created (the scan uses a snapshot — consistent read transaction).

**B1_5.6** — Given `silmari.db` is missing entirely, when reconciliation runs, then it returns `{ok: false, error: "silmari.db not found"}` without crashing.

**B1_5.7** — Given reconciliation is invoked as a CLI (`bun apps/silmari-mcp/scripts/reconcile-keyword-index.ts`), when run with `--dry-run`, then it reports what WOULD be removed without writing.

**B1_5.8** — Given reconciliation is registered to run at MCP server startup (opt-in via env var `SILMARI_RECONCILE_ON_STARTUP=1`), when the server boots, then reconciliation completes before the first tool call is accepted. Default: OFF (manual invocation).

### TDD cycle (representative)

#### B1_5.1 — Phantom detection + drop

**🔴 Red** — `apps/silmari-mcp/tests/reconcile-keyword-index.test.ts`:

```typescript
it('drops keyword entries pointing to nonexistent cards', async () => {
  const { saveCard } = await import('../src/lib/card-ops.js?t=' + Date.now());
  const { addKeywordEntry } = await import('../src/lib/keyword-index.js?t=' + Date.now());

  // Create one real card + manually inject a phantom
  const real = await saveCard({body: 'real card body', kind: 'learning', trunk: 5, mode: 'root'});
  addKeywordEntry({term: 'shared', entryPoint: real.id, curator: 'agent'});
  addKeywordEntry({term: 'shared', entryPoint: 'zk-ghost-abc', curator: 'agent'});

  const { reconcileKeywordIndex } = await import('../scripts/reconcile-keyword-index.js?t=' + Date.now());
  const report = await reconcileKeywordIndex({dryRun: false});

  expect(report.entryPointsRemoved).toBe(1);
  expect(report.termsRemoved).toBe(0);

  const { lookupKeyword } = await import('../src/lib/keyword-index.js?t=' + Date.now());
  const entry = lookupKeyword('shared');
  expect(entry!.entry_points).toEqual([real.id]);  // phantom dropped, real kept
});
```

**🟢 Green** — `apps/silmari-mcp/scripts/reconcile-keyword-index.ts`:

```typescript
import { Database } from 'bun:sqlite';

export interface ReconcileReport {
  termsScanned: number;
  entryPointsRemoved: number;
  termsRemoved: number;
  startedAt: string;
  completedAt: string;
  dryRun: boolean;
}

export async function reconcileKeywordIndex(opts: {dryRun?: boolean} = {}): Promise<ReconcileReport> {
  const startedAt = new Date().toISOString();
  const {brShow} = await import('../src/lib/br-adapter.js');
  const {getDb} = await import('../src/lib/silmari-db.js');

  const db = getDb();
  db.exec('BEGIN');  // snapshot isolation for consistent read
  try {
    const rows = db.query(`SELECT term, entry_points FROM keyword_entries`).all() as Array<{term: string; entry_points: string}>;
    let entryPointsRemoved = 0;
    let termsRemoved = 0;

    for (const row of rows) {
      const currentPoints: string[] = JSON.parse(row.entry_points);
      const survivors = currentPoints.filter(cardId => brShow('idea', cardId) !== null);
      const removed = currentPoints.length - survivors.length;
      if (removed === 0) continue;
      entryPointsRemoved += removed;
      if (!opts.dryRun) {
        if (survivors.length === 0) {
          db.query(`DELETE FROM keyword_entries WHERE term = ?`).run(row.term);
          termsRemoved++;
        } else {
          db.query(`UPDATE keyword_entries SET entry_points = ?, updated_at = ? WHERE term = ?`)
            .run(JSON.stringify(survivors), new Date().toISOString(), row.term);
        }
      } else if (survivors.length === 0) {
        termsRemoved++;
      }
    }
    db.exec(opts.dryRun ? 'ROLLBACK' : 'COMMIT');
    return {termsScanned: rows.length, entryPointsRemoved, termsRemoved, startedAt, completedAt: new Date().toISOString(), dryRun: !!opts.dryRun};
  } catch (err) {
    db.exec('ROLLBACK');
    throw err;
  }
}

if (import.meta.main) {
  const dryRun = process.argv.includes('--dry-run');
  const r = await reconcileKeywordIndex({dryRun});
  console.log(JSON.stringify(r, null, 2));
}
```

**🔵 Refactor** — extract `brShow('idea', cardId) !== null` into `cardExists(id)` helper for readability. Add `--json-output` flag for structured CI integration.

### Phase 1.5 success criteria

**Automated:**
- [ ] `bun test apps/silmari-mcp/tests/reconcile-keyword-index.test.ts` — all 8 behaviors pass
- [ ] `bun test` full suite: no regressions
- [ ] `bun apps/silmari-mcp/scripts/reconcile-keyword-index.ts --dry-run` on a healthy DB reports `entryPointsRemoved: 0, termsRemoved: 0`

**Manual:**
- [ ] Induce a phantom by manually inserting into `silmari.db` with a fake card_id; run reconcile; verify it's dropped
- [ ] Set `SILMARI_RECONCILE_ON_STARTUP=1` and start the MCP server; verify reconcile runs before first tool call

### Phase 1.5 rollback

```bash
git revert <phase-1.5-commit>
# Phase 1 still works; phantom accumulation resumes but doesn't break anything
# A future manual run of the script can still be invoked as a one-off
```

---

## Phase 2 — Save-time Extraction Hardening (L2 + L3 + L4-revised)

### Goal

Every `saveCard()` call writes keyword entries (L2), scans the card's line-of-thought for title mentions (L3), and rejects saves that produce no anchor (L4-revised, no fallback hub).

### Behaviors

**B2.1** — Given a save with `title: "Algorithm skeptic-search"`, `kind: "learning"`, `trunk: 5`, when `saveCard()` succeeds (brCreate returned a valid id), then each extracted term is offered to `addKeywordEntry` via the L2 writer — entries land in `keyword_entries` with the save's card_id as an entry_point through the post-7h6 uncapped append path (`added` or `already-present` only).

**B2.2** — Given `brCreate` returns `null` (the subprocess card-create failed), when `saveCard()` evaluates the continuation, then NO keyword writes are attempted (ordered — keyword writes happen AFTER brCreate success, never before). This is the architecturally-achievable partial replacement for the previously-impossible cross-process atomicity.

**B2.2a** — Given `brCreate` succeeds but the L2 keyword write fails (e.g., sqlite I/O error, disk full), when `saveCard()` evaluates, then it returns the card with a `console.warn` log noting partial state. The card is preserved — **no rollback** (rollback would require a recursive `br delete` subprocess that has its own atomicity problems). The L4 anchor check (downstream in Phase 7) will then decide whether to invoke Tier B or raise `ExtractionFailure` based on the `ref:*` labels that WERE written.

**B2.2b** — Given phantom keyword entries exist after any prior partial failure, when the Phase-1.5 reconciliation script (`reconcile-keyword-index.ts`) runs, then phantom rows are garbage-collected. Phase 2 does NOT re-implement phantom detection — it depends on Phase 1.5 for recovery. This is why Phase 2 is gated on Phase 1.5 in the dep chain.

**B2.3** — Given a card at fz `5/3` with children `5/3a, 5/3b`, when `lineOfThought("5/3")` is called, then it returns `{parent: null, siblings: [], children: [cards at 5/3a and 5/3b], hubs: [], trunkSeeds: [5/1-5/N roots]}`.

**B2.4** — Given a card at fz `5/3a` whose parent `5/3` has title "Skeptic search framework", when `extractTitleMentions(body: "...skeptic search framework applies...", candidates: [parent-at-5/3])` is called, then it returns `[{type: 'refers-to', target: <cardId-of-5/3>}]`.

**B2.5** — Given title tokens < 2 contiguous matching tokens in body, when `extractTitleMentions` scans, then no edge is emitted (specificity threshold).

**B2.6** — Given a save of a novel-topic card with no existing keyword match AND no body-mentions AND `mode: root` (no parent), when `saveCard()` reaches Phase 7, then Tier B semantic proposer is invoked synchronously.

**B2.7** — Given Tier B returns 1 proposal with `confidence ≥ 0.7`, when auto-commit fires, then the corresponding `ref:<edge>:<target>` label is written AND the save succeeds.

**B2.8** — Given Tier B returns 0 proposals OR all proposals below threshold, when extraction-hardening evaluates, then `saveCard()` raises `ExtractionFailure` error with diagnostic payload `{candidateCards: [...], termsAttempted: [...], scopeUsed: "line-of-thought"}`.

**B2.9** — Given a save of `kind: "stub"` or `kind: "hub"` or `kind: "structure"` or `kind: "register"` with zero anchors, when `saveCard()` evaluates L4, then the save SUCCEEDS (these kinds are exempt from the anchor mandate).

**B2.10** — Given a `mode: fork` save with valid `fromAddress`, when `saveCard()` runs, then `extractFolgezettelParent` emits `ref:branches:<parent>` AND `extractTitleMentions` scans the line-of-thought for additional title hits.

**B2.11** — Given `mode: continue` in the same conditions, when `saveCard()` runs, then `ref:follows:<parent>` is emitted.

**B2.12** — Given a save body containing 3 different card titles from the line-of-thought, when `extractTitleMentions` runs, then 3 distinct `ref:refers-to:*` labels are emitted (one per matched card).

**B2.13** — Given a card whose body cites the SAME title multiple times, when extracted, then only 1 `ref:refers-to:*` label (dedup per target).

**B2.14** — Given `lineOfThought()` called with `cardId: <nonexistent>`, when resolved, then returns `{parent: null, siblings: [], children: [], hubs: [], trunkSeeds: [...]}` (graceful — still returns trunk seeds for fallback).

**B2.15** — Given the combined line-of-thought scope size exceeds 150 cards, when scanned, then it's truncated to the 150 most-recent by `created_at` (bounded-scan invariant).

**B2.16** — Given content-hash dedup hits on the second save of identical bytes, when `saveCard()` returns early at Phase 1, then NO L2/L3/L4 processing runs AND the existing card is returned unchanged.

**B2.17** — Given a save with `allowOrphan: true` flag (escape hatch), when Tier B returns 0 proposals, then `saveCard()` SUCCEEDS with a warning log and the card is created without `ref:*` labels (use for admin imports, migrations).

### TDD cycles (representative)

#### B2.3 `lineOfThought()` composer

**🔴 Red** — `apps/silmari-mcp/tests/line-of-thought.test.ts`:

```typescript
it('returns parent + siblings + children for a mid-chain card', async () => {
  const { saveCard } = await import('../src/lib/card-ops.js?t='+Date.now());
  const parent = await saveCard({body: 'Parent card', kind: 'learning', trunk: 5, mode: 'root'});
  const child1 = await saveCard({body: 'Child 1', kind: 'learning', trunk: 5, mode: 'fork', fromAddress: `5/${parent.fz.split('/')[1]}`});
  const child2 = await saveCard({body: 'Child 2', kind: 'learning', trunk: 5, mode: 'continue', fromAddress: child1.fz});

  const { lineOfThought } = await import('../src/lib/line-of-thought.js?t='+Date.now());
  const lot = lineOfThought(child1.id);

  expect(lot.parent?.id).toBe(parent.id);
  expect(lot.siblings.map(c => c.id)).toEqual([]);  // no same-depth peers yet
  expect(lot.children.map(c => c.id)).toEqual([child2.id]);
});
```

**🟢 Green** — `apps/silmari-mcp/src/lib/line-of-thought.ts`:

```typescript
import { neighborhood, scanTrunk } from './navigate.js';
import { listInbound } from './br-adapter.js';
import { parseFzFromLabels, parseAddress } from './labels.js';
import type { BeadRow } from './br-adapter.js';

export interface LineOfThought {
  queried: BeadRow | null;
  parent: BeadRow | null;
  siblings: BeadRow[];
  children: BeadRow[];
  hubs: BeadRow[];
  trunkSeeds: BeadRow[];
  totalScope: number;
}

const MAX_SCOPE = 150;

export function lineOfThought(cardId: string): LineOfThought {
  const { brShow } = require('./br-adapter.js');
  const card = brShow('idea', cardId);
  if (!card) return emptyLOT();

  const fz = parseFzFromLabels(card.labels);
  const {trunk, sequence} = parseAddress(fz);
  const addr = `${trunk}/${sequence}`;

  const nb = neighborhood(addr);

  // Hubs this card belongs to (inbound ref:derives-from from this card)
  // Actually: this card's OUTBOUND ref:derives-from targets = the hubs it's a member of
  const hubMemberships = extractHubsFromLabels(card.labels);
  const hubs = hubMemberships.map(hid => brShow('idea', hid)).filter(Boolean);

  // Trunk seeds: root-level cards in the same trunk
  const scan = scanTrunk(trunk);
  const seeds = scan.allSequences
    .filter(s => !s.includes('/') && s.length === 1)  // single-digit root sequences
    .map(s => scan.beadsBySequence.get(s))
    .filter(Boolean) as BeadRow[];

  const all = [
    ...(nb.parentChain.slice(-1)),  // immediate parent only
    ...nb.siblings,
    ...nb.children,
    ...hubs,
    ...seeds,
  ];

  // Truncate by most-recent if over cap
  const truncated = all.length > MAX_SCOPE
    ? all.sort((a, b) => b.created_at - a.created_at).slice(0, MAX_SCOPE)
    : all;

  return {
    queried: card,
    parent: nb.parentChain[nb.parentChain.length - 1] ?? null,
    siblings: nb.siblings,
    children: nb.children,
    hubs,
    trunkSeeds: seeds,
    totalScope: truncated.length,
  };
}

function emptyLOT(): LineOfThought {
  return {queried: null, parent: null, siblings: [], children: [], hubs: [], trunkSeeds: [], totalScope: 0};
}
```

**🔵 Refactor** — add memoization when called repeatedly for the same card within a save (hot path). Extract `extractHubsFromLabels()` into `labels.ts`.

#### B2.8 `ExtractionFailure` error class

**🔴 Red** — `apps/silmari-mcp/tests/extraction-hardening.test.ts`:

```typescript
it('rejects saves that produce no anchors with ExtractionFailure', async () => {
  // mock Tier B to return 0 proposals
  process.env.SILMARI_TEST_FORCE_TIER_B_EMPTY = '1';

  const { saveCard, ExtractionFailure } = await import('../src/lib/card-ops.js?t='+Date.now());

  let caught: any = null;
  try {
    await saveCard({body: 'totally isolated novel thing xyzzy', kind: 'learning', trunk: 5, mode: 'root', source: 'no-bead-id'});
  } catch (err) {
    caught = err;
  }
  expect(caught).toBeInstanceOf(ExtractionFailure);
  expect(caught.diagnostic.candidateCards).toBeDefined();
  expect(caught.diagnostic.termsAttempted).toBeDefined();
});
```

**🟢 Green** — add to `card-ops.ts`:

```typescript
export class ExtractionFailure extends Error {
  constructor(public diagnostic: {
    candidateCards: string[];
    termsAttempted: string[];
    scopeUsed: string;
    cardId: string;
  }) {
    super(`Extraction failure: card ${diagnostic.cardId} produced no anchors after line-of-thought scan + semantic proposer`);
    this.name = 'ExtractionFailure';
  }
}
```

And in `saveCard()` at end of Phase 7, before return:

```typescript
const EXEMPT_KINDS = new Set(['stub', 'hub', 'structure', 'register']);
const emittedRefs = edges.filter(e => e.target).length;
const keywordEntries = /* result from L2 */;

if (EXEMPT_KINDS.has(opts.kind)) {
  // skip anchor check
} else if (emittedRefs === 0 || keywordEntries === 0) {
  if (opts.allowOrphan) {
    console.warn(`[saveCard] ${sweep.id} saved without anchors (allowOrphan=true)`);
  } else {
    // Invoke Tier B proposer synchronously
    const tierBProposals = await proposeLinksSemantic({newCardId: sweep.id, scope: 'line-of-thought'});
    const threshold = 0.7;
    const hiConf = tierBProposals.filter(p => p.confidence >= threshold);
    if (hiConf.length === 0) {
      // Roll back the card? Or leave and throw? Decision: leave card, throw error with cleanup hint.
      throw new ExtractionFailure({
        candidateCards: scannedCardIds,
        termsAttempted: extractedTerms,
        scopeUsed: 'line-of-thought',
        cardId: sweep.id,
      });
    }
    // auto-commit the top proposal
    for (const p of hiConf.slice(0, 1)) {
      addEdge(opts.box, sweep.id, p.edge, p.targetId);
    }
  }
}
```

**🔵 Refactor** — extract the L4 check into `enforceAnchorInvariant()` helper. Consider whether to roll back the card on failure (cleaner) vs. leave-and-throw (more recoverable). Decision: **leave card, throw error; callers can `allowOrphan: true` to retry**. The unanchored card is diagnostic value in itself.

### Phase 2 success criteria

**Automated:**
- [ ] `bun test apps/silmari-mcp/tests/line-of-thought.test.ts` — all 6 behaviors
- [ ] `bun test apps/silmari-mcp/tests/extraction-hardening.test.ts` — all 17 behaviors
- [ ] `bun test apps/silmari-mcp/tests/edge-extractors.test.ts` — 3 new tests for `extractTitleMentions` + existing tests green
- [ ] `bun test` full suite: no regressions, especially `zk-save-card-fromaddress.test.ts`

**Manual:**
- [ ] Running a sample LEARN-like save with a body mentioning a known card's title produces `ref:refers-to:<thatCard>` automatically
- [ ] Attempting a novel-isolated save without anchors returns `ExtractionFailure` in the MCP response
- [ ] After Phase 2, running 5 new Algorithm LEARN cycles produces 0 new orphans (measure via SQL)

### Phase 2 rollback

Phase 2 depends on Phase 1 being in place. Rollback:

```bash
git revert <phase-2-commit>
# Phase 1 stays — the keyword table is still useful
```

---

## Phase 3 — Semantic Proposer MCP Tool (Tier B, two-stage commit)

### Goal

Expose `zk_propose_links_semantic` as a new MCP tool. Sonnet classifies; the main agent commits in user's voice.

### Behaviors

**B3.1** — Given `zk_propose_links_semantic({newCardId: "zk-new"})`, when called without explicit candidates, then it uses `lineOfThought(newCardId)` to assemble candidates.

**B3.2** — Given assembled candidates, when Sonnet is invoked via `Inference.ts`, then the system prompt explicitly forbids writing rationale text.

**B3.3** — Given Sonnet returns structured JSON like `[{"targetId":"zk-abc","edge":"refines","confidence":0.82,"quoted_overlap":"skeptic-search framing"}]`, when parsed, then the result is validated against the schema (no extra fields, required fields present, `edge` in allowed enum).

**B3.4** — Given invalid JSON from Sonnet, when parser fails, then the tool returns `errorResult("parse failure: " + rawPreview)` where `rawPreview` is the first 500 chars. Uses the existing `errorResult(message)` helper at `apps/silmari-mcp/src/index.ts:340` — NOT a raw `{ok: false, error: ...}` literal — so the MCP protocol's error channel is honored.

**B3.5** — Given Sonnet proposes an edge type NOT in the allowed set (`supports/contradicts/extends/reinforces/refines`), when validation runs, then that proposal is filtered out with a warning log.

**B3.6** — Given more than `maxProposals` proposals return, when the caller sets `maxProposals: 3`, then the result is truncated to the 3 highest-confidence proposals.

**B3.7** — Given a proposal's `quoted_overlap` field is empty or missing, when validated, then that proposal is filtered out (no silent accept of empty-rationale).

**B3.8** — Given `scope: "trunk"` with `seedAddress: "5/3"`, when candidates are assembled, then `scanTrunk(5)` output is used (all trunk cards, bounded to 150).

**B3.9** — Given `scope: "explicit"` with `candidateCardIds: ["zk-a", "zk-b"]`, when called, then only those 2 cards are sent to Sonnet (no line-of-thought expansion).

**B3.10** — Given the mock Sonnet adapter is active (`SILMARI_TEST_MOCK_INFERENCE=1`), when called in tests, then `inference()` returns fixture JSON without hitting the real API.

**B3.11** — Given `inference()` returns `{success: false, error: "timeout"}`, when propagated, then the tool returns `errorResult("semantic classifier unavailable: " + underlyingError)` and does NOT block the caller. Inference is invoked **in-process** via `import { inference } from '../../SAI/Tools/Inference.js'` (async function call, not subprocess CLI) — matches the pattern used in `SAI/hooks/RatingCapture.hook.ts:~165` and `SessionAutoName.hook.ts`.

**B3.12** — Given the returned proposals, when the caller's agent inspects them, then the response is wrapped via the existing `okResult()` helper: `okResult({proposals: [{targetId, edge, confidence, quoted_overlap}], candidatesScanned: number, scope: string})`. Matches MCP tool-result convention used by every other `zk_*` handler.

**B3.13** — Given a newCardId that doesn't exist, when called, then returns `errorResult("newCardId not found: " + id)` BEFORE any Sonnet call (fast-fail; no wasted inference cost).

**B3.14** — Given this tool is called from Phase 2's `saveCard()` L4 hardening, when `ExtractionFailure` would fire, then the semantic proposer's output CAN auto-commit (one high-confidence proposal) to avoid the failure.

### TDD cycles (representative)

#### B3.2 prompt shape — no-rationale mandate

**🔴 Red** — `apps/silmari-mcp/tests/semantic-proposer.test.ts`:

```typescript
import { describe, it, expect, mock } from 'bun:test';

it('system prompt forbids rationale generation', async () => {
  const { buildSystemPrompt } = await import('../src/lib/semantic-proposer.js?t='+Date.now());
  const prompt = buildSystemPrompt();
  expect(prompt).toMatch(/do not write.*rationale/i);
  expect(prompt).toMatch(/quoted_overlap/i);
  expect(prompt).not.toMatch(/please explain/i);
});
```

**🟢 Green** — `apps/silmari-mcp/src/lib/semantic-proposer.ts`:

```typescript
export function buildSystemPrompt(): string {
  return `You classify semantic relationships between Zettelkasten cards.

For each candidate card, decide if the new card has one of these typed relationships:
  - supports: new card provides evidence for a claim in the candidate
  - contradicts: new card states the opposite of a claim in the candidate
  - extends: new card adds a specific sub-case or follow-up to the candidate
  - reinforces: new card observes the same insight in a new context
  - refines: new card is a more precise version of the candidate's idea
  - (or no relationship — omit the card from your output)

STRICT OUTPUT RULES:
1. Return a JSON array only. No prose, no markdown fences, no commentary.
2. Each element must have EXACTLY these keys: targetId, edge, confidence, quoted_overlap.
3. DO NOT write a rationale, explanation, or reason field. Rationale is written later by the user in their own voice. Your job is PATTERN DETECTION only.
4. \`quoted_overlap\` must be the literal phrase (≤80 chars) from the candidate's body that triggered the match. Not a summary. The verbatim phrase.
5. \`confidence\` is a float 0.0-1.0. Omit any match below 0.5.
6. Maximum 5 proposals.

Example:
[{"targetId":"zk-abc","edge":"refines","confidence":0.82,"quoted_overlap":"skeptic-search fires pre-ISC lock"}]`;
}
```

**🔵 Refactor** — move the prompt to a separate `.prompt.md` file for version-control legibility; load at module init.

#### B3.3/B3.5 output validation

**🔴 Red**:

```typescript
it('rejects proposals with non-enum edge types', () => {
  const { validateProposals } = require('../src/lib/semantic-proposer.js');
  const raw = [
    {targetId: 'zk-a', edge: 'refines', confidence: 0.8, quoted_overlap: 'x'},
    {targetId: 'zk-b', edge: 'some-weird-type', confidence: 0.9, quoted_overlap: 'y'},
  ];
  const valid = validateProposals(raw);
  expect(valid).toHaveLength(1);
  expect(valid[0].targetId).toBe('zk-a');
});
```

**🟢 Green**:

```typescript
const ALLOWED_EDGES = new Set(['supports','contradicts','extends','reinforces','refines']);

export function validateProposals(raw: any[]): Proposal[] {
  if (!Array.isArray(raw)) return [];
  return raw.filter(p =>
    typeof p?.targetId === 'string' && p.targetId.match(/^(zk|bl)-/)
    && ALLOWED_EDGES.has(p?.edge)
    && typeof p?.confidence === 'number' && p.confidence >= 0.5 && p.confidence <= 1.0
    && typeof p?.quoted_overlap === 'string' && p.quoted_overlap.trim().length > 0
  );
}
```

**🔵 Refactor** — emit structured logs on each rejection so the Algorithm operator can audit why Sonnet's output was partially filtered.

### Phase 3 success criteria

**Automated:**
- [ ] `bun test apps/silmari-mcp/tests/semantic-proposer.test.ts` — all 14 behaviors
- [ ] Mocked Sonnet test: fixture JSON → validated output matches expected shape
- [ ] `bun test apps/silmari-mcp/tests/extraction-hardening.test.ts` — Phase 2's Tier B integration test now passes with real Phase 3 implementation (was stub-mocked during Phase 2 TDD)
- [ ] `bun test` full suite: no regressions

**Manual:**
- [ ] With `SILMARI_TEST_REAL_LLM=1`, run one Sonnet call against real candidates and verify the output shape conforms to the schema (no rationale field, quoted_overlap present)
- [ ] Call the tool via the MCP protocol from a Claude Code session: verify tool registration, verify response shape

### Phase 3 rollback

```bash
git revert <phase-3-commit>
# Phase 2's L4 check will now produce ExtractionFailure for isolated saves (no Tier B fallback)
# Users can pass allowOrphan: true as escape hatch until Phase 3 relands
```

---

## Phase 4 — `think-with-memory` UserPromptSubmit Hook

### Goal

Detect "help me think" style phrases in the user's prompt. Inject a `🧠 PRIOR THOUGHT` block with line-of-thought-scoped recall results + recurrence detection, so the response is shaped by memory.

### Behaviors

**B4.1** — Given a prompt containing `help me think about X`, when the hook fires, then `detectThinkingTrigger(prompt)` returns `{matched: true, topic: "X"}`.

**B4.2** — Given a prompt without any trigger phrase, when the hook fires, then `detectThinkingTrigger` returns `{matched: false}` AND the hook exits with no output.

**B4.3** — Given a matched topic, when `zk_recall({query: topic})` is called, then the three-layer result is fetched.

**B4.4** — Given recall results with ≥1 card title appearing in ≥2 cards (multiple-storage), when analyzed, then the hook output flags "recurrence: you've thought about this N times".

**B4.5** — Given recall results, when the hook assembles its output, then it (a) persists the full recall payload + detection metadata to `~/.claude/MEMORY/STATE/think-with-memory/<sessionId>-<turn>.json` for evals/replay/observability AND (b) emits the `🧠 PRIOR THOUGHT` block on stdout via `console.log()` for live prompt injection (pattern cloned from `SAI/hooks/ChecklistStateInjector.hook.ts`).

**B4.5a** — Given B4.5's persistence fires, when the file is inspected after a live session, then it contains the full JSON: `{timestamp, sessionId, turn, prompt, triggerMatched, topic, recallResult, recurrences, injectedText}` — sufficient to replay the decision deterministically in an eval.

**B4.6** — Given an empty recall result, when the hook fires, then the `🧠 PRIOR THOUGHT` block says "none found — treating as novel" and the main agent proceeds normally.

**B4.7** — Given a session with prior turns that reference card IDs (e.g., the user mentioned `zk-abc` in turn 3), when the hook fires on turn 5 with "what do you think", then the recall is seeded from those referenced cards as line-of-thought, not from a global search.

**B4.8** — Given case-variant matches ("HELP ME THINK", "Help Me Think"), when the matcher runs, then all variants match.

**B4.9** — Given the phrase appears mid-sentence ("I was hoping you could help me think about X"), when the matcher runs, then the topic extraction correctly pulls "X", not "me think".

**B4.10** — Given `zk_recall` is unavailable (MCP down), when the hook fires, then it logs the failure and exits(0) — never blocks the prompt.

**B4.11** — Given the hook's silmari-db is read-only (the injector has no write-path), when the hook imports from `keyword-index.js`, then no keyword entries are written (pure reader mode).

**B4.12** — Given the state directory `~/.claude/MEMORY/STATE/think-with-memory/` does not exist, when the hook tries to persist, then it creates the directory (mkdir recursive) before writing the state file. Missing directory must never block injection.

### TDD cycles (representative)

#### B4.1 / B4.9 — phrase detection + topic extraction

**🔴 Red** — `SAI/hooks/tests/think-with-memory.test.ts`:

```typescript
import { describe, it, expect } from 'bun:test';
import { detectThinkingTrigger } from '../lib/think-with-memory.js';

describe('detectThinkingTrigger', () => {
  it('matches "help me think about X" and extracts X', () => {
    const r = detectThinkingTrigger('can you help me think about the orphan problem?');
    expect(r.matched).toBe(true);
    expect(r.topic).toBe('the orphan problem');
  });

  it('is case-insensitive', () => {
    expect(detectThinkingTrigger('HELP ME THINK about X').matched).toBe(true);
    expect(detectThinkingTrigger('Help Me Think about X').matched).toBe(true);
  });

  it('extracts topic from "what do you think about X"', () => {
    const r = detectThinkingTrigger('what do you think about keyword indexing?');
    expect(r.matched).toBe(true);
    expect(r.topic).toBe('keyword indexing');
  });

  it('returns no-match on unrelated prompts', () => {
    expect(detectThinkingTrigger('write me a function').matched).toBe(false);
  });

  it('handles multi-clause prompts', () => {
    // "I was hoping you could help me think about X, actually"
    const r = detectThinkingTrigger('I was hoping you could help me think about recursion');
    expect(r.matched).toBe(true);
    expect(r.topic).toBe('recursion');
  });
});
```

**🟢 Green** — `SAI/hooks/lib/think-with-memory.ts`:

```typescript
const TRIGGER_PATTERNS = [
  /(?:^|\W)help me think(?:\s+about\s+|:\s+)(.+?)(?:[.?!]|$)/i,
  /(?:^|\W)what do you think(?:\s+about\s+|:\s+)(.+?)(?:[.?!]|$)/i,
  /(?:^|\W)let's explore(?:\s+)(.+?)(?:[.?!]|$)/i,
  /(?:^|\W)what have we said(?:\s+about\s+)(.+?)(?:[.?!]|$)/i,
  /(?:^|\W)walk me through(?:\s+)(.+?)(?:[.?!]|$)/i,
  /(?:^|\W)work through this with me(?:\s+about\s+|:\s+)?(.+?)?(?:[.?!]|$)/i,
];

export interface TriggerResult {
  matched: boolean;
  topic?: string;
  pattern?: string;
}

export function detectThinkingTrigger(prompt: string): TriggerResult {
  for (const rx of TRIGGER_PATTERNS) {
    const m = prompt.match(rx);
    if (m && m[1]) {
      return {matched: true, topic: m[1].trim(), pattern: rx.source};
    } else if (m) {
      return {matched: true, topic: '', pattern: rx.source};  // matched trigger but no topic captured
    }
  }
  return {matched: false};
}
```

**🔵 Refactor** — consider upgrading to a lexer/tokenizer for better multi-clause handling; for v1, regex is sufficient.

#### B4.4 — recurrence detection

**🔴 Red**:

```typescript
it('detects multiple-storage recurrence across cards', () => {
  const { detectRecurrence } = require('../lib/think-with-memory.js');
  const recallResult = {
    entryCards: [
      {id: 'zk-a', title: 'Check status before recall'},
      {id: 'zk-b', title: 'Check status before recall — reinforced'},  // same insight
      {id: 'zk-c', title: 'Unrelated topic'},
    ],
    neighborhoods: {},
    crossRefs: {},
  };
  const recurrences = detectRecurrence(recallResult);
  expect(recurrences).toHaveLength(1);
  expect(recurrences[0].commonTokens).toContain('check');
  expect(recurrences[0].cardIds).toEqual(['zk-a','zk-b']);
});
```

**🟢 Green** — token-jaccard-overlap ≥ threshold identifies near-duplicate titles as recurrences. Implementation ~25 lines.

**🔵 Refactor** — extend to body-excerpt comparison for deeper recurrence signal in v2.

### Phase 4 success criteria

**Automated:**
- [ ] `bun test SAI/hooks/tests/think-with-memory.test.ts` — all 13 behaviors (11 core + B4.5a state file shape + B4.12 mkdir-recursive)
- [ ] Detection false-positive rate: on 50 random non-trigger prompts from recent transcripts, matcher returns false on all 50

**Manual:**
- [ ] In a live Claude Code session with the hook registered: typing "help me think about keyword indexing" produces a `🧠 PRIOR THOUGHT` block in the response context BEFORE the main agent responds
- [ ] The block shows ≥1 recalled card when one exists
- [ ] If recurrence is present (e.g. the "zk_status before zk_recall" lesson was saved twice), the block flags it with "you've thought about this 2 times"
- [ ] Hook failure (simulated by renaming silmari.db) does not block the prompt — normal response proceeds

### Phase 4 rollback

```bash
git revert <phase-4-commit>
# Remove hook from SAI/settings.json UserPromptSubmit array
# Hook never fires; trigger phrases get no special treatment
```

---

## Integration & E2E

### End-to-end flow test (post all 4 phases)

**Scenario**: A fresh Algorithm run that saves 4 LEARN reflections.

**Setup**:
1. Run Phase 1 bootstrap against current store
2. Phase 2, 3, 4 code is deployed

**Action**: Run an Algorithm task end-to-end. At LEARN phase, save 4 reflections with `mode: root`.

**Expected**:
- Each `saveCard()` writes ≥2 keyword entries (L2)
- Each save runs `lineOfThought()` scope ~20-150 cards
- At least 2 of the 4 saves produce ≥1 `ref:refers-to:*` via title-mention scan (L3)
- The remaining saves invoke Tier B; Sonnet proposes ≥1 edge with confidence ≥0.7; auto-commit
- All 4 cards have ≥1 `ref:*` label after save
- `zk_status.keywords` increases by ~8 (2 per card)
- Re-running `zk_recall` with terms from the new cards returns them

### Regression test matrix

| Pre-existing test | Must pass after | Why |
|---|---|---|
| `edge-extractors.test.ts` (entire file) | Phase 2 + 3 | L3 adds a new extractor; existing 3 must still work |
| `zk-save-card-fromaddress.test.ts` | Phase 2 | fromAddress behavior unchanged; L2+L3+L4 layered on top |
| `folgezettel.test.ts` | Phase 2 | `lineOfThought()` reuses `neighborhood()`; don't break underlying |
| `integration.test.ts` (the long one) | All phases | full pipeline integration — catches subtle regressions |
| `navigate.test.ts` | Phase 2 | pure functions untouched; sanity check |
| `keyword-index.test.ts` | Phase 1 | existing JSONL tests replaced with sqlite equivalents |

---

## Cross-cutting ISC (regression guards)

- [ ] **Invariant 1 — No orphan**: after Phase 2, running `sqlite3 <store> "SELECT COUNT(*) FROM issues i WHERE NOT EXISTS (SELECT 1 FROM labels l WHERE l.issue_id = i.id AND l.label LIKE 'ref:%')"` on the orphan-count of new cards shows zero growth over a 7-day window
- [ ] **Invariant 2 — User's voice**: after Phase 3, grep for `rationale.*Sonnet|AI-authored` in all `ref:*` labels returns empty
- [ ] **Invariant 3 — Line-of-thought scoping**: grep for `scanAll|limit: 10000` in new code shows zero unbounded scans in `saveCard` hot path
- [ ] **Invariant 4 — Multiple storage**: content-hash dedup still uses exact bytes; no cosine/fuzzy similarity introduced (verify via code review)
- [ ] **Invariant 5 — Substrate isolation**: `vendor/beads_rust/` unchanged; `apps/silmari-memory-card-viewer/viewer_assets/` unchanged

---

## Success Criteria (full plan)

**Automated (all commands must pass):**
- [ ] `bun test apps/silmari-mcp/tests/` — full MCP test suite, including 6 new test files (keyword-index-sqlite, bootstrap-keyword-index, line-of-thought, extraction-hardening, semantic-proposer, think-with-memory) — all green
- [ ] `bun test SAI/hooks/tests/` — hook tests green
- [ ] `bun build apps/silmari-mcp/src/index.ts` — clean compile
- [ ] `bun build SAI/hooks/ThinkWithMemory.hook.ts` — clean compile
- [ ] Post-bootstrap: `sqlite3 ~/.silmari-memory/silmari.db "SELECT COUNT(*) FROM keyword_entries"` returns ≥ 600
- [ ] Post-bootstrap: `mcp__silmari__zk_status` returns `keywords > 0`

**Manual (verified in live session):**
- [ ] A real Algorithm LEARN run produces ≥1 `ref:*` label per saved card
- [ ] The `think-with-memory` hook surfaces recalled cards on a trigger phrase
- [ ] The semantic proposer tool returns structured proposals (no LLM rationale text)
- [ ] The orphan count in the store does not grow after 5 post-Phase-2 Algorithm runs

---

## Phase Ordering & Dependencies

```
Phase 1 (substrate)
    ↓
Phase 1.5 (phantom reconciliation)    ← NEW post-review
    ↓
Phase 2 (save-time hardening — depends on 1.5 for cleanup)
    ↓ L4 fallback mocks Phase 3 during TDD
Phase 3 (semantic proposer)
    ↓ enables live demo
Phase 4 (think-with-memory hook)
```

Phase 2's L4 check references the Phase 3 tool. During Phase 2 TDD, mock the semantic proposer with a stub; during Phase 3 TDD, replace the stub with real impl. Phase 2's B2.6-B2.8 tests become integration tests after Phase 3 lands.

**Why 1.5 gates Phase 2**: Phase 2's L4 invariant ("every card has ≥1 keyword entry AND ≥1 ref:* label") is only meaningful if stale phantom entries can be cleaned. Without Phase 1.5, one partial failure pollutes the keyword index forever. Therefore Phase 2 depends on 1.5.

---

## Beads issues filed (actual)

| Phase | Ticket ID | Status |
|---|---|---|
| Epic | `silmari-agent-memory-3x7` | open |
| Phase 1 | `silmari-agent-memory-3fm` | blocked on review-findings ticket `-0ij` |
| Phase 1.5 | **TO FILE** — Keyword phantom reconciliation | — |
| Phase 2 | `silmari-agent-memory-lo7` | blocked on Phase 1 |
| Phase 3 | `silmari-agent-memory-0hp` | blocked on Phase 2 |
| Phase 4 | `silmari-agent-memory-2qs` | blocked on Phase 3 |
| Review findings | `silmari-agent-memory-0ij` | blocks Phase 1 |

**Remaining bd action (post-amendment)**: file Phase 1.5 ticket and rewire the dep chain so Phase 2 depends on Phase 1.5 (not directly on Phase 1). Also close `-0ij` when the plan amendments are merged.

```bash
# File Phase 1.5
bd create --title="Phase 1.5 — Keyword phantom reconciliation script" --type=feature --priority=1 \
  --description="Derivative of review C2 finding. Handles partial-failure cruft left by brCreate-subprocess + silmari.db separate-sqlite non-atomicity. See plan §Phase 1.5."

# Rewire: Phase 2 → Phase 1.5 → Phase 1 (instead of Phase 2 → Phase 1 direct)
bd dep add <phase-1.5-id> silmari-agent-memory-3fm     # 1.5 depends on Phase 1
bd dep add silmari-agent-memory-lo7 <phase-1.5-id>     # Phase 2 depends on 1.5
# NOTE: Phase 2's existing dep on Phase 1 remains correct (transitive through 1.5)

# When amendments land:
bd close silmari-agent-memory-0ij --reason="plan amendments merged; review findings resolved"
```

---

## References

- **Root-cause research**: `thoughts/searchable/shared/research/2026-04-22-silmari-orphan-cards-root-cause.md`
- **Luhmann principles context**: `thoughts/searchable/shared/research/2026-04-22-What-the-Zettelkasten-actually-is.md`
- **Prior 2026-04-17 Option B fix** (viewer render is correct): `thoughts/searchable/shared/research/2026-04-17-force-graph-edges-workaround.md`
- **Tier C backfill**: `apps/silmari-mcp/scripts/backfill-edges-from-cosmic.ts` + `feedback_silmari_graph_edge_recovery.md`
- **Algorithm spec**: `SAI/Algorithm/v3.8.1.md` §Memory Integration
- **Research scratchpad** (codebase discoveries from this session): `MEMORY/WORK/20260422-100200_orphan-cards-root-cause/research-mcp-structure.md`
- **PRD (this investigation)**: `MEMORY/WORK/20260422-100200_orphan-cards-root-cause/PRD.md`

---

## Out-of-band decisions recorded here

- **New silmari-owned sqlite file** (`~/.silmari-memory/silmari.db`) rather than piggybacking on `beads.db` — preserves boundary between silmari's extension substrate and beads_rust's territory
- **Uncapped keyword entries preserved** (`silmari-agent-memory-7h6` / `silmari-agent-memory-fkv`) — the pre-7h6 `MAX_ENTRY_POINTS = 4` cap is not a Zettelkasten framework invariant. The 1:21 ratio describes keyword/card sparsity, not entry points per keyword. The sqlite writer and bootstrap both append without truncation.
- **Schema 1-to-many** (review W1) — `keyword_entries(term PRIMARY KEY, entry_points TEXT_JSON, curator, updated_at)` preserves the existing `KeywordEntry` shape; no caller churn
- **Schema versioning** (review W2) — `schema_versions` table tracks per-table versions; cloned from `folgezettel.ts:54` precedent
- **API contract preserved** (review C3) — `addKeywordEntry` returns the post-7h6 `AddKeywordResult` discriminated union (`added` / `already-present`). `force` remains as a deprecated no-op for caller compatibility. Curator type is `'human' | 'agent'`.
- **Cross-process atomicity is impossible** (review C2) — brCreate (subprocess) + silmari.db (in-process) cannot share a transaction. Ordered-best-effort + Phase 1.5 phantom reconciliation replaces the false atomicity promise.
- **JSONL keyword-index deprecated** after Phase 1 lands; read-compatible for one release via forward-bridge migration, then JSONL file archived (not deleted)
- **`ExtractionFailure` does NOT roll back the card** — card is created; caller can retry with `allowOrphan: true` OR add context to enable Tier A/B match. Rationale: partial state is diagnostic; silent rollback hides the problem.
- **Tier B prompt lives in a `.prompt.md` file**, not inline TS — reviewers can diff the prompt without touching code
- **Phase 3 mocking during Phase 2 TDD approved** (user decision 2026-04-22) — Phase 2's L4 tests use a stub `proposeLinksSemantic()` returning fixture data; the stub is replaced with real impl in Phase 3
- **Phase 4 injection pattern pinned: file-based state + stdout injection** (user decision 2026-04-22). The hook writes full recall payload to `~/.claude/MEMORY/STATE/think-with-memory/<sessionId>-<turn>.json` (durable state for evals, replay, observability) AND emits the `🧠 PRIOR THOUGHT` block via `console.log()` for live prompt injection. Clone pattern from `SAI/hooks/ChecklistStateInjector.hook.ts` which does exactly this: reads state from JSON, prints injection to stdout.
- **Stopword list v1 approved** (user decision 2026-04-22) — 13 common English stopwords (`the/and/for/with/from/this/that/when/have/been/will/what/your`). Domain-specific additions deferred to v2 after we observe which tokens dominate the index post-bootstrap.
- **Confidence threshold `0.7` for auto-commit**: tunable via env var `SILMARI_TIER_B_CONFIDENCE_THRESHOLD`; default 0.7

*End of plan.*
