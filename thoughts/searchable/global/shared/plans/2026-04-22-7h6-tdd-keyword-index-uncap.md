---
date: 2026-04-22
author: Maceo Jourdan (with Silmari)
status: implemented
implementation-date: 2026-04-23
topic: "7h6 — keyword-index: remove MAX_ENTRY_POINTS cap + FIFO eviction (framework invariant)"
tags: [silmari, keyword-index, uncap, 7h6, tdd]
bd: silmari-agent-memory-7h6
parent-plan: thoughts/searchable/shared/plans/2026-04-22-tdd-silmari-cascade-extractor.md
blocked-by: silmari-agent-memory-r04
---

# 7h6 TDD implementation plan — keyword-index MAX_ENTRY_POINTS removal

## Implementation status (2026-04-23)

**SHIPPED.** All 7 Observable Behaviors verified by 474 passing tests
across 22 files. r04 landed first (unblocked 7h6); parallel agent on
Step 5.5 pre-landed `filterByKeywordOverlap` in the same file — edits
orthogonal, no conflict.

| Behavior | Status | Evidence |
|---|---|---|
| B1 — unbounded append (5th+ entry) | ✅ | `keyword-index.test.ts` "appends the 5th entry point without eviction" |
| B2 — duplicate detection unchanged | ✅ | "is idempotent when the same entry_point is added twice" (existing) |
| B3 — cascade-density correctness (500 entries) | ✅ | new "is still idempotent at cascade density (500 entries)" |
| B4 — compile-time dead-branch catch | ✅ | `AddKeywordResult` narrowed; all `'replaced'`/`'rejected-full'` sites migrated |
| B5 — `force` deprecated no-op | ✅ | "appends the 5th entry point regardless of force:true" + "force:true on a duplicate still returns already-present" |
| B6 — MCP description honest | ✅ | new `mcp-tool-description.test.ts` — asserts no cap/FIFO/MAX_ENTRY_POINTS in description |
| B7 — lookup unchanged at high density | ✅ | covered by B3's 500-entry assertion |

**Implementation notes:**
- `MAX_ENTRY_POINTS` constant deleted from `keyword-index.ts`
- `AddKeywordResult` narrowed to 2 variants
- `addKeywordEntry` simplified: removed cap check + FIFO branch
- `force?` retained as `@deprecated` no-op for backward-compat (3 production callers stay as-is)
- `ZK_KEYWORD_ADD_DESCRIPTION` extracted as exported constant in `index.ts`
- `force` dropped from `zk_keyword_add` tool's JSON `inputSchema.properties`
- `bootstrap-keyword-index.ts` short-circuit rewritten; `rejectedFull` field removed from `BootstrapReport`
- `apps/silmari-mcp/README.md` created with "Migration notes — 7h6" section (the durable public record since the package is `version: 0.0.0 + private: true`)
- New test file: `tests/mcp-tool-description.test.ts`
- 4 existing test files migrated: `keyword-index.test.ts`, `keyword-index-sqlite.test.ts`, `bootstrap-keyword-index.test.ts`, `integration.test.ts`

**Coordination:** sent a broadcast heads-up to the Step 5.5 agent at the start of implementation via agent_mail (FrostySpring). File reservations were held on all 8 touched files for the duration. Step 5.5's `filterByKeywordOverlap` was already in the file when I arrived; my 7h6 changes were orthogonal (modifying `addKeywordEntry` + `AddKeywordResult` + removing `MAX_ENTRY_POINTS`; their function only reads `lookupKeyword`). No conflict.



## Overview

This plan ships 7h6 — the removal of the `MAX_ENTRY_POINTS = 4` constant and the FIFO eviction it drives from `apps/silmari-mcp/src/lib/keyword-index.ts`. It is scoped narrowly: cap off, FIFO off, `AddKeywordResult` collapsed from four variants to two, MCP tool description rewritten, and existing tests migrated off the dead kinds. It is NOT a performance refactor, NOT a recall-time limiter, and NOT the cascade pipeline itself — each of those is its own item (r04, Step 6.5, Steps 3–6 respectively) in the parent cascade-extractor plan.

The change is framed as an invariant correction — see cascade plan §11 item 3: cascade-density ingests (one playlist = ~1,800 cards) push popular substantive terms to 100–200 entry points, at which point the cap silently truncates 95%+ of the index. That truncation is the framework-level breach 7h6 fixes. The argument for the break is in §"Why this isn't just 'strip the cap'" below — it is the justification for the API break, recorded in `apps/silmari-mcp/README.md` under "Migration notes — 7h6" (the package is `"version": "0.0.0"` + `"private": true`, so there is no npm semver to bump; the README entry is the durable record).

Estimated slice: ~150 LOC of code change, ~300 LOC of new/migrated test code. Single PR.

## Why this isn't just "strip the cap" — the design-choice refutation

The FIFO eviction and the cap-at-4 are NOT a bug. They are documented at `keyword-index.ts:287-291` as a deliberate choice — the comment explicitly notes "we don't track per-entry timestamps, so 'oldest' means 'earliest insertion order'." Someone made that call, with eyes open. 7h6's burden is not "fix a bug"; it's "explain why the deliberate choice is wrong at the workload we're moving to." Five-part argument:

### 1. What the original cap protects against

The cap-at-4 was sized for a pre-cascade workload. In that regime Silmari ingests are dominantly:

- Manual card entry via `zk_save_card` (one card at a time, thought through)
- Algorithm LEARN runs at the end of a session (single-digit to low-double-digit cards per run)

At that density, a term that crosses 4 entry points is USUALLY noise — generic English particles (`the`, `is`, `and`), half-assed keyword extraction from a rushed LEARN pass, or a structural term (`voice-memos`, `claude-code`) that should be a hub tag rather than a content keyword. The cap + FIFO then functions as a cheap defensive filter: if your keyword is appearing more than 4 times you probably picked a bad keyword. Drop the oldest, keep churning. The churn is tolerable because nothing downstream depends on recall completeness.

That reasoning is internally consistent. In a pre-cascade Silmari, I'd defend it.

### 2. Why that reasoning fails at cascade density

The cascade pipeline (parent plan Steps 3–6) ingests a YouTube talk as ~120 atomic cards, each extracting ~5 keyword terms — ~600 term-index writes per talk. A 15-video playlist about a single person produces ~9,000 writes concentrated on a small substrate vocabulary. In that corpus, a SUBSTANTIVE term — `voice`, `shame`, `sobriety`, `memoir`, `craft` — legitimately ends up with 100 to 200 entry points. Those aren't noise. They are the actual density of the thinker's engagement with the concept. That density IS the compounding substrate — the whole point of the cascade.

The cap at 4 turns `zk_recall voice` into a lottery: whichever four cards happened to be saved most recently under that term. 95%+ of the thinker's engagement with `voice` is invisible to retrieval, even though every card is still on disk. The index — the only retrieval surface zk_recall reads — has silently lied about the corpus.

This is a framework invariant breach. The Silmari framework says "Zettelkasten links ARE retrieval" (global MEMORY.md top entry). If the keyword index can't hold the links, the framework is structurally blind.

### 3. Why FIFO is the wrong eviction strategy specifically

Even granting the counterfactual "a cap IS needed," FIFO is backwards. FIFO evicts the EARLIEST entry and keeps the LATEST. In a lecture/talk corpus, the earliest mention of a claim is typically MORE load-bearing than the restatements that follow it — it's the articulation the speaker built everything on. The restatements are scaffolding revisions.

Luhmann's multiple-storage principle (cascade plan §8) is explicit: every restatement is a NEW card with its own address, linked via `reinforces` to the earlier articulation. The earlier card is the anchor of the chain. FIFO systematically destroys anchors and keeps revisions. It inverts the card's value to the thinker.

If we wanted a cap, the correct eviction would be LRU-on-retrieval (drop cards the user hasn't followed in N sessions) or semantic-density-aware (drop cards with lowest edge count). FIFO is the worst possible choice for a thinking substrate. So the fact that FIFO is what's documented is itself a signal that nobody modeled the access pattern — the cap was a default, not a design.

### 4. Why "index 50+ entries under one term" is the right acceptance test

The cascade pipeline produces 50+ entries per substantive term on the very first full-playlist run. That means 50+ is the MINIMUM real-world density, not a stretch. A test at density 50 gates future regressions where someone — reasonably worried about memory or lookup time — "optimizes" the index and re-introduces a cap. The test makes the invariant machine-checkable.

We test up to 500 to exercise the edge (a thinker with 3 years of cascade ingests on one topic will get there).

### 5. Why this is a public API break that warrants explicit migration documentation

Callers branching on `result.kind === 'replaced'` or `result.kind === 'rejected-full'` will see those variants disappear. TypeScript exhaustiveness catches most — the `AddKeywordResult` type narrows — but any test using `as any` casts, or any runtime string comparison on `.kind`, will silently become dead code. There are also the `force: true` callers; once the cap is gone, `force` becomes a no-op (see Behavior 3 for the decision to retain it as a deprecated parameter rather than hard-remove).

Note on semver: `apps/silmari-mcp/package.json` is `"version": "0.0.0"` + `"private": true`. There is no published version to bump — this is an internal monorepo package. The API break is recorded in `apps/silmari-mcp/README.md` under a new "Migration notes — 7h6" section, enumerating the three removed symbols and the deprecation. That README section IS the public record of the break; there is no CHANGELOG.md to maintain.

---

## Current state analysis

All file:line references verified in the parent-plan review; not re-researched here.

- `MAX_ENTRY_POINTS` constant declared and exported at `keyword-index.ts:88` — value 4.
- `AddKeywordResult` discriminated union at `keyword-index.ts:74-78` — four variants: `added`, `already-present`, `rejected-full`, `replaced`.
- `KeywordEntry` type at `keyword-index.ts:52-56` — `{ term: string; entry_points: string[] }`. No per-entry timestamps.
- `addKeywordEntry()` at `keyword-index.ts:298` — implements the cap check, the already-present short-circuit, and the `force:true` FIFO eviction branch at lines 368–379.
- FIFO eviction returns `{ kind: 'replaced', entry, evicted: <shifted address> }`.
- FIFO-as-design comment at `keyword-index.ts:287-291` — justifies choosing insertion order as the eviction key.
- `lookupKeyword(term)` at `keyword-index.ts:261` — returns the full `KeywordEntry | null`; no truncation on read.
- `readKeywordIndex()` at `keyword-index.ts:236` — full scan; no density awareness.
- `removeKeywordEntry()` at `keyword-index.ts:394` — returns boolean; unaffected by 7h6 but re-reviewed for completeness.
- `navigate()` at `apps/silmari-mcp/src/lib/navigate.ts:626` — iterates `entry_points` per term with no per-term cap; after 7h6 will naturally see longer arrays. Step 6.5 of the cascade plan will add a recall-time limit — out of scope for 7h6.
- MCP tool description at `apps/silmari-mcp/src/index.ts:287` currently advertises the `MAX_ENTRY_POINTS=4` behavior to callers. It lies after 7h6 ships if not updated. (Note: `index.ts:251` is `zk_structure_create`; the `zk_keyword_add` registration is at `:286-298` with the description literal at `:287`.)
- Test locations: `apps/silmari-mcp/tests/` contains bun-test files. The ones mentioning `replaced` / `rejected-full` are the migration surface.

### Key discoveries (file:line)

- `apps/silmari-mcp/src/lib/keyword-index.ts:88` — `export const MAX_ENTRY_POINTS = 4;` (to delete)
- `apps/silmari-mcp/src/lib/keyword-index.ts:74-78` — `AddKeywordResult` four-variant union (to reduce to two)
- `apps/silmari-mcp/src/lib/keyword-index.ts:287-291` — FIFO-as-design comment (to delete)
- `apps/silmari-mcp/src/lib/keyword-index.ts:298` — `addKeywordEntry` (to simplify; drop cap branch; drop FIFO branch)
- `apps/silmari-mcp/src/lib/keyword-index.ts:368-379` — FIFO eviction body (to delete)
- `apps/silmari-mcp/src/index.ts:287` — `zk_keyword_add` MCP tool description literal (to rewrite; not `:251` which is `zk_structure_create`)
- `apps/silmari-mcp/src/index.ts:295` — `zk_keyword_add` MCP tool inputSchema (drop `force` property)
- `apps/silmari-mcp/src/index.ts:620` — MCP dispatcher calling `addKeywordEntry({..., force: Boolean(args.force)})` (callsite in migration surface)
- `apps/silmari-mcp/src/lib/card-ops.ts:722` — save-time L2 writer calling `addKeywordEntry({..., force: false})` (callsite in migration surface)
- `apps/silmari-mcp/scripts/bootstrap-keyword-index.ts:207, 218-222` — ops script caller + `rejected-full` short-circuit (semantic change; see Behavior 7)
- `scripts/kc-baker-pipeline/ingest.ts:168, 177` — MCP-side JSON-RPC callers passing `force:true` (no TypeScript compilation path; field becomes a silent no-op after 7h6)
- `apps/silmari-mcp/src/lib/navigate.ts:626` — read-side use of entry_points; no change in 7h6, but verify no assumption of small N

### Migration surface — `MAX_ENTRY_POINTS` importers

Grep verified (expected 0 hits post-7h6 in `apps/silmari-mcp/`):

1. `apps/silmari-mcp/src/lib/keyword-index.ts:88` — declaration (delete)
2. `apps/silmari-mcp/src/index.ts` — comment/reference (audit + delete)
3. `apps/silmari-mcp/src/lib/card-ops.ts:701` — comment (delete)
4. `apps/silmari-mcp/scripts/bootstrap-keyword-index.ts:10, 140` — import + comment (delete)
5. `apps/silmari-mcp/tests/keyword-index.test.ts:28` — destructured import (migrate under Behavior 6)
6. `apps/silmari-mcp/tests/integration.test.ts:68` — destructured import (migrate)
7. `apps/silmari-mcp/tests/bootstrap-keyword-index.test.ts:29` — destructured import (migrate under Behavior 7)
8. `apps/silmari-mcp/tests/keyword-index-sqlite.test.ts:25` — destructured import (migrate under Behavior 7)

Action item: re-run `rg MAX_ENTRY_POINTS apps/silmari-mcp/` immediately before implementation starts; confirm 8 hits (or update the list if drift has occurred).

### Migration surface — `.kind === 'replaced'` / `'rejected-full'` callsites

Grep-verified hits (scope: `apps/silmari-mcp/`):

- `apps/silmari-mcp/tests/keyword-index.test.ts:235` — `r.kind === 'rejected-full'`
- `apps/silmari-mcp/tests/keyword-index.test.ts:251` — `r.kind === 'replaced'`
- `apps/silmari-mcp/tests/integration.test.ts:809` — `forced.kind === 'replaced'`
- `apps/silmari-mcp/scripts/bootstrap-keyword-index.ts:218` — `r.kind === 'rejected-full'` (production short-circuit; see Behavior 7)

Plus additional content hits in the same files asserting `evicted` field contents — walked in Behavior 6. Action item: re-grep both `'replaced'` and `'rejected-full'` (quoted) in `apps/silmari-mcp/` before implementation; expected <10 total callsites.

## Desired end state

After 7h6:

- `MAX_ENTRY_POINTS` constant is gone. No grep hit in `apps/silmari-mcp/`.
- `AddKeywordResult = { kind: 'added'; entry } | { kind: 'already-present'; entry }` — two variants. The `evicted: string` field is gone.
- `addKeywordEntry()` is ~10–15 lines shorter: one path reads the current entry, one path checks membership, one path appends.
- The `force?: boolean` parameter is RETAINED as a deprecated no-op with a JSDoc `@deprecated` tag. Callers passing `force:true` or `force:false` get neither a type error nor a behavior change — the parameter is destructured and discarded. Rationale: three production callsites pass `force` (two TypeScript, one over JSON-RPC from the kc-baker pipeline). Hard-removing it would break `card-ops.ts:722` at compile time and silently ignore the JSON-RPC callers. Backward-compat no-op is the lower-blast-radius choice for 7h6. The MCP JSON schema at `index.ts:295` DOES drop the `force` property so new clients stop advertising it. (Alternative considered and rejected: hard-remove — would force a simultaneous migration of `scripts/kc-baker-pipeline/` outside the silmari-mcp package boundary.)
- MCP tool description at `index.ts:287` rewritten to describe uncapped behavior. New text factored into a shared constant so the description is defined once.
- All tests in `apps/silmari-mcp/tests/` pass. Tests that branched on `'replaced'` or `'rejected-full'` are migrated. Tests that exercised `force:true` are migrated to exercise the new semantics (append without special casing).
- `apps/silmari-mcp/README.md` gains a "Migration notes — 7h6" section (or a new `apps/silmari-mcp/MIGRATION.md` file — pick README; no second doc to maintain) documenting the API break: the three removed symbols (`MAX_ENTRY_POINTS` constant, `AddKeywordResult` `'replaced'` variant, `AddKeywordResult` `'rejected-full'` variant) and the one deprecation (`force` parameter is now a no-op, dropped from JSON schema). Note: `apps/silmari-mcp/package.json` is `"version": "0.0.0"` + `"private": true`, so there is no npm semver to bump — the README entry IS the public record of the break.

### Observable behaviors

**B1 — unbounded append.** Given a `KeywordEntry` with 100 existing entry points, when `addKeywordEntry({ term, entryPoint: <101st>, curator: 'human' })` is called, then the call returns `{ kind: 'added', entry }` and `entry.entry_points.length === 101`.

**B2 — duplicate detection unchanged.** Given an address already in `entry.entry_points`, when `addKeywordEntry` is called with that same `(term, address)` pair, then the call returns `{ kind: 'already-present', entry }` and the entry array length is unchanged.

**B3 — cascade-density correctness.** Given a cascade run ingesting 1,800 cards across 15 transcripts with ~5 keyword terms per card, when all keyword-add calls complete, then no term's entry_points array shows truncation (no `evicted` address appears on disk in any prior snapshot), and the entry_points length histogram matches the natural fan-in of the corpus (popular terms 100–200, tail terms 1–5).

**B4 — compile-time catch of dead branches.** Given legacy test code asserting `result.kind === 'replaced'`, when that test compiles against the new library, then TypeScript narrows `result.kind` to `'added' | 'already-present'` and the dead branch fails to type-check.

**B5 — `force` arg deprecated no-op.** Given caller code calling `addKeywordEntry({ term, entryPoint, curator, force: true })`, when that code runs against the new library, then the call succeeds identically to one without `force`. The `force` parameter is retained in the TypeScript signature as `@deprecated`, destructured and discarded. The MCP JSON schema at `index.ts:295` drops the `force` property so new tool callers no longer see it advertised. (Migration note: callers can leave their `force: true`/`force: false` in place; the behavior is now "unbounded append" in either case, which is stronger than the pre-7h6 `force: true` semantics of "evict oldest + append".)

**B6 — MCP tool description honest.** Given the MCP tool metadata at `index.ts:287`, when the description string is rendered, then it contains no "MAX_ENTRY_POINTS" substring and no numeric cap, and it describes an unbounded `entry_points` array per term.

**B7 — lookup unchanged on the read side.** Given `lookupKeyword(term)` is called on a term with 500 entry points, when the call returns, then the returned `KeywordEntry` has `entry_points.length === 500` and every address is in insertion order. (Read path has no cap today; this test pins that.)

## What we're NOT doing

Explicitly out of scope for 7h6:

- `zk_recall` limit parameter — that's cascade Step 6.5. After 7h6, `zk_recall voice` over 500 entry points returns all 500; Step 6.5 adds an optional `limit`/`offset` to page.
- `hubMembers` + `filterByKeywordOverlap` — cascade Step 5.5. Uses the uncapped index 7h6 produces, but the composition is a later slice.
- The cascade pipeline itself (Steps 3–6).
- Refactoring `keyword-index.ts` for performance at high fan-in — the current linear scan is O(n) on lookup. At n=500 that's still sub-millisecond in practice. If profiling shows a real problem, that's a separate slice — 7h6 does NOT introduce an index-of-the-index.
- Migrating the on-disk keyword store format — still SQLite-backed (post-Phase-1/1.5). 7h6 is pure code + test.
- Adding per-entry timestamps. The FIFO comment's lament that "we don't track per-entry timestamps" goes away because we no longer need them. Do not add them now.

## Testing strategy

- **Framework:** bun test (`bun test` from monorepo root). Existing pattern: `import { describe, it, expect } from 'bun:test'`.
- **Fixture:** each test creates its own temp `SILMARI_DIR` via `mkdtempSync` and tears down in `afterEach`. No shared state.
- **Unit tests (fast, inline):** `addKeywordEntry` at densities 1, 4, 5, 10, 50, 100, 500. The 4→5 transition is the old cap boundary — key regression guard.
- **Type-level tests:** a dedicated `.test-d.ts`-style block (bun-compatible via `expect-type` or inline `// @ts-expect-error`) asserting `AddKeywordResult`'s `kind` union. Catches future re-introduction of the dead variants.
- **Migration tests:** grep run first (`apps/silmari-mcp/tests/` for `'replaced'` and `'rejected-full'` string literals). Each hit becomes a migration. Strategy per hit:
  - If the test was exercising the cap boundary → replace with a density-50 test.
  - If the test was exercising FIFO eviction semantics → delete; eviction no longer exists.
  - If the test was branching on `.kind` in an assertion → narrow to `'added' | 'already-present'`.
- **Integration test:** simulate cascade-density ingest (500 saves under 10 terms = 5,000 entries) and verify (a) no truncation, (b) lookup correctness (every inserted address retrievable), (c) wall-clock under a generous budget (< 2s total for 5,000 inserts on dev hardware — not a perf guarantee, just a regression sentinel).
- **MCP description test:** snapshot-style assertion on the tool description string. Red captures current (cap-mentioning) text. Green rewrites.

## Behavior 1 — addKeywordEntry accepts unlimited entry points per term

### Red

```typescript
// apps/silmari-mcp/tests/keyword-index-uncap.test.ts
import { describe, it, expect, beforeEach, afterAll } from 'bun:test';
import { mkdtempSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

// MODULE-SCOPE env setup — bun-sqlite caches the db binding on first import,
// so SILMARI_DIR must be set BEFORE the dynamic import of keyword-index.
// See memory entry feedback_bun_sqlite_gc_before_subprocess.md and the
// existing pattern in reconcile-keyword-index.test.ts:17-26.
const TEST_TMP = mkdtempSync(join(tmpdir(), '7h6-uncap-'));
process.env.SILMARI_DIR = TEST_TMP;

const { addKeywordEntry, lookupKeyword, _resetSilmariDbCache } = await import(
  '../src/lib/keyword-index'
);

describe('keyword-index uncap — B1 unbounded append', () => {
  beforeEach(() => {
    // Wipe table between tests; module-scope import means we keep the same db.
    // (Implementation detail: keyword-index exposes a helper to drop rows;
    // if not, execute `DELETE FROM keyword_entries` via the shared db handle.)
    // See tests/reconcile-keyword-index.test.ts for the canonical pattern.
  });
  afterAll(() => {
    _resetSilmariDbCache?.();
    rmSync(TEST_TMP, { recursive: true, force: true });
  });

  it('appends a 101st entry point without eviction', () => {
    const term = 'voice';
    for (let i = 0; i < 100; i++) {
      addKeywordEntry({ term, entryPoint: `1/${i + 1}`, curator: 'human' });
    }
    const result = addKeywordEntry({ term, entryPoint: '1/101', curator: 'human' });
    expect(result.kind).toBe('added');
    expect(result.entry.entry_points).toHaveLength(101);
    expect(result.entry.entry_points[0]).toBe('1/1'); // earliest preserved
    expect(result.entry.entry_points[100]).toBe('1/101');
    const roundtrip = lookupKeyword(term);
    expect(roundtrip?.entry_points).toHaveLength(101);
  });
});
```

Run: `bun test apps/silmari-mcp/tests/keyword-index-uncap.test.ts`. Expect failure on `entry_points[0]` — pre-7h6 the cap kicks in at the 5th insert and FIFO evicts; `1/1` is long gone by the 101st.

### Green

- Delete `MAX_ENTRY_POINTS` (`keyword-index.ts:88`).
- In `addKeywordEntry`, delete the `entry.entry_points.length >= MAX_ENTRY_POINTS` branch (and the `force` special-case that follows).
- Replace with: read current entry, if address already present return `{kind: 'already-present', entry}`, else push + persist + return `{kind: 'added', entry}`.

### Refactor

- Inline the read-once pattern — no double `lookupKeyword` call.
- Extract `appendAddress(entry, address): { result, nextEntry }` as a pure helper; makes Behavior 2 trivial.

## Behavior 2 — AddKeywordResult narrowed to two variants

### Red

```typescript
import { describe, it, expect } from 'bun:test';
import type { AddKeywordResult } from '../src/lib/keyword-index';

describe('keyword-index uncap — B4 type narrowing', () => {
  it('AddKeywordResult has exactly two kinds', () => {
    // Exhaustive match — any new kind or removed kind trips this
    const tag = (r: AddKeywordResult): string => {
      switch (r.kind) {
        case 'added': return 'a';
        case 'already-present': return 'p';
        // @ts-expect-error — 'replaced' must no longer be a valid kind
        case 'replaced': return 'r';
      }
    };
    expect(typeof tag).toBe('function');
  });

  it('already-present branch returns the same entry without duplication', () => {
    const term = 'voice';
    addKeywordEntry({ term, entryPoint: '1/1', curator: 'human' });
    const second = addKeywordEntry({ term, entryPoint: '1/1', curator: 'human' });
    expect(second.kind).toBe('already-present');
    expect(second.entry.entry_points).toEqual(['1/1']);
  });
});
```

Red outcome: pre-7h6, `@ts-expect-error` on `'replaced'` fails — the type still includes it, so the error directive is itself an error. The `tag()` compile failure is the signal.

### Green

- Rewrite `AddKeywordResult` at `keyword-index.ts:74-78` to:
  ```typescript
  export type AddKeywordResult =
    | { kind: 'added'; entry: KeywordEntry }
    | { kind: 'already-present'; entry: KeywordEntry };
  ```
- Delete every return statement in `addKeywordEntry` producing `'replaced'` or `'rejected-full'`. (There should be exactly two after the simplification in B1.)

### Refactor

- Grep for `AddKeywordResult` in `src/` and `tests/` — confirm no callsite imports it and destructures `evicted`. If any do, they're now type errors — migrate.

## Behavior 3 — `force` parameter retained as deprecated no-op (with schema update)

**Design choice:** Keep `force?: boolean` in the signature as a silent no-op with a JSDoc `@deprecated` note, rather than removing it. Rationale: two production callsites (`card-ops.ts:722`, `index.ts:620`) and the MCP JSON-RPC surface (`scripts/kc-baker-pipeline/ingest.ts:168, 177` passing `force:true` over the wire) all pass it; making it a no-op keeps the blast radius small. The MCP tool JSON schema at `index.ts:295` IS updated (the `force` property is removed from `inputSchema.properties`) so new clients stop sending it, but the library accepts extra keys gracefully for backward-compat. Alternative considered and rejected: hard-remove `force` — surfaces a type error at `card-ops.ts:722` and break JSON-RPC callers silently. Losing proposition for the scope of 7h6.

### Red

```typescript
describe('keyword-index uncap — B5 force is a no-op', () => {
  it('accepts force:true but does not special-case behavior', () => {
    // Type-level: force is still allowed by the signature (no @ts-expect-error).
    const result = addKeywordEntry({
      term: 'voice',
      entryPoint: '1/1',
      curator: 'human',
      force: true,
    });
    expect(result.kind).toBe('added');
    expect(result.entry.entry_points).toEqual(['1/1']);
  });

  it('force:true on a duplicate still returns already-present (no eviction, no re-insert)', () => {
    addKeywordEntry({ term: 'voice', entryPoint: '1/1', curator: 'human' });
    const dup = addKeywordEntry({
      term: 'voice',
      entryPoint: '1/1',
      curator: 'human',
      force: true,
    });
    expect(dup.kind).toBe('already-present');
    expect(dup.entry.entry_points).toEqual(['1/1']);
  });

  it('appends identically regardless of how many entries exist', () => {
    for (let i = 0; i < 10; i++) {
      addKeywordEntry({ term: 'voice', entryPoint: `1/${i}`, curator: 'human' });
    }
    const eleventh = addKeywordEntry({
      term: 'voice',
      entryPoint: '1/10',
      curator: 'human',
    });
    expect(eleventh.kind).toBe('added');
    expect(eleventh.entry.entry_points).toContain('1/0'); // earliest still there
  });
});
```

### Green

- Keep `force?: boolean` in the `addKeywordEntry` arg type. Add a JSDoc `@deprecated` tag: "No-op since 7h6 — the keyword index is uncapped. Will be removed in a future major."
- Remove the internal `force` branch in the implementation (already dead after B1's green). The parameter is simply destructured and discarded.
- **JSON schema update (MCP surface):** at `apps/silmari-mcp/src/index.ts:295`, remove the `force` property from the `zk_keyword_add` tool's `inputSchema.properties`. Existing JSON-RPC clients passing `force:true` will have the field ignored by the library (no validation error since the library accepts extra keys), but new clients no longer see it in the schema.

### Refactor

- Grep `apps/silmari-mcp/src/` and `scripts/` for `force: true` and `force: false`. Known callsites: `apps/silmari-mcp/src/lib/card-ops.ts:722` (`force: false`), `apps/silmari-mcp/src/index.ts:620` (`force: Boolean(args.force)`), `scripts/kc-baker-pipeline/ingest.ts:168, 177` (`force: true` via MCP tool call). These stay as-is (no-op fields are harmless); optionally delete them in a follow-up cleanup once the deprecation window closes.
- Update README (see Rollout): "`force` parameter deprecated as of 7h6 — retained as a no-op for backward-compat."

## Behavior 4 — cascade-density acceptance test

### Red

```typescript
describe('keyword-index uncap — B3 cascade density', () => {
  it('indexes 500 addresses under one term without truncation', () => {
    const term = 'voice';
    const addresses = Array.from({ length: 500 }, (_, i) => `${1 + Math.floor(i / 20)}/${(i % 20) + 1}`);
    for (const a of addresses) {
      addKeywordEntry({ term, entryPoint: a, curator: 'agent' });
    }
    const entry = lookupKeyword(term);
    expect(entry).not.toBeNull();
    expect(entry!.entry_points).toHaveLength(500);
    expect(new Set(entry!.entry_points).size).toBe(500); // no dupes, no lost
    expect(entry!.entry_points).toEqual(addresses); // insertion order preserved
  });

  it('simulates a 15-transcript cascade: 10 terms × 500 inserts each', () => {
    const terms = ['voice', 'shame', 'sobriety', 'memoir', 'craft',
                   'gaze', 'silence', 'refusal', 'grief', 'reckoning'];
    const start = performance.now();
    for (const term of terms) {
      for (let i = 0; i < 500; i++) {
        addKeywordEntry({ term, entryPoint: `${i}/1`, curator: 'agent' });
      }
    }
    const elapsed = performance.now() - start;
    for (const term of terms) {
      expect(lookupKeyword(term)!.entry_points).toHaveLength(500);
    }
    // Regression sentinel, not a perf guarantee
    expect(elapsed).toBeLessThan(5000);
  });
});
```

### Green

Falls out of B1's simplification — no new code. The test passes once B1 is green.

### Refactor

- Move the 500-address generator into a test helper if other behaviors reuse it.

## Behavior 5 — MCP tool description updated

### Red

```typescript
// apps/silmari-mcp/tests/mcp-tool-description.test.ts
import { describe, it, expect } from 'bun:test';
import { ZK_KEYWORD_ADD_DESCRIPTION } from '../src/index';

describe('keyword-index uncap — B6 MCP description', () => {
  it('tool description does not mention a cap', () => {
    expect(ZK_KEYWORD_ADD_DESCRIPTION).not.toMatch(/MAX_ENTRY_POINTS/i);
    expect(ZK_KEYWORD_ADD_DESCRIPTION).not.toMatch(/\b4\b/);
    expect(ZK_KEYWORD_ADD_DESCRIPTION).not.toMatch(/oldest/i);
    expect(ZK_KEYWORD_ADD_DESCRIPTION).not.toMatch(/evict/i);
  });

  it('tool description describes unbounded entry points', () => {
    expect(ZK_KEYWORD_ADD_DESCRIPTION.toLowerCase()).toMatch(/unbounded|unlimited|any number/);
  });
});
```

Red outcome: pre-7h6 the description string at `index.ts:287` matches `/MAX_ENTRY_POINTS/i` and/or `/\b4\b/`. Also, `ZK_KEYWORD_ADD_DESCRIPTION` doesn't exist yet — it's inlined. Test fails at import.

### Green

- Extract the description literal from `index.ts:287` into an exported constant `ZK_KEYWORD_ADD_DESCRIPTION` at the top of the file.
- Rewrite the text. Candidate copy:
  > "Adds an address to the keyword index under the given term. The term's `entry_points` array is unbounded — every address indexed under a substantive term is retained, including at cascade-ingest density (100+ entries per term is normal). Returns `{kind:'added'}` on first insert, `{kind:'already-present'}` if the address is already indexed under this term."
- Reference the constant in the tool registration block.

### Refactor

- If `apps/silmari-mcp/README.md` or `docs/` reiterates the cap, update those too (grep `MAX_ENTRY_POINTS` across the repo).

## Behavior 6 — test migration of existing `.kind === 'replaced'` / `'rejected-full'` callsites

### Red/Green/Refactor as a single migration pass

```bash
# Run first (re-verify before implementation; the enumeration below is a snapshot)
rg "kind === 'replaced'" apps/silmari-mcp/
rg "kind === 'rejected-full'" apps/silmari-mcp/
rg "\\bevicted\\b" apps/silmari-mcp/tests/ apps/silmari-mcp/src/
```

Expected hits (verified at plan authoring time; re-grep before implementation):

- `apps/silmari-mcp/tests/keyword-index.test.ts:235` — `r.kind === 'rejected-full'`
- `apps/silmari-mcp/tests/keyword-index.test.ts:251` — `r.kind === 'replaced'`
- `apps/silmari-mcp/tests/keyword-index.test.ts:252` — `evicted` field read
- `apps/silmari-mcp/tests/integration.test.ts:800, 808-810` — `replaced` + `evicted` assertions
- `apps/silmari-mcp/scripts/bootstrap-keyword-index.ts:218` — production short-circuit (covered in Behavior 7, NOT here)

Migration patterns:

1. **Cap-boundary test** — was asserting "5th insert returns `rejected-full`":
   - **Before:** `expect(fifth.kind).toBe('rejected-full');`
   - **After:** `expect(fifth.kind).toBe('added'); expect(fifth.entry.entry_points).toHaveLength(5);`

2. **FIFO eviction semantics test** — was asserting `evicted` field content:
   - **Before:** `expect(result.kind).toBe('replaced'); expect(result.evicted).toBe('1/1');`
   - **After:** Delete entire test. FIFO no longer exists.

3. **`force: true` happy-path test** — was asserting force overrides cap:
   - **Before:** `addKeywordEntry({term, entryPoint, curator: 'human', force: true}); expect(...).toBe('replaced');`
   - **After:** `addKeywordEntry({term, entryPoint, curator: 'human'}); expect(...).toBe('added');` (drop `force` from the test for clarity — the parameter is retained as a deprecated no-op, but the test no longer needs to set it; match new `'added'` kind). Note: if the test is asserting the deprecated-no-op behavior itself, keep `force: true` and assert `'added'` (see B3).

Migration is mechanical. Each file touched gets a tiny diff and runs cleanly under `bun test`. Commit separately from the library change so the test delta is easy to review.

## Behavior 7 — bootstrap script + cap-invariant tests migrated

**Why this is its own behavior:** `apps/silmari-mcp/scripts/bootstrap-keyword-index.ts:218-222` has a production short-circuit — `else if (r.kind === 'rejected-full') { rejectedFull++; break; }` — that stops feeding additional candidate addresses to a term once the cap is hit. After 7h6 removes `MAX_ENTRY_POINTS`, `'rejected-full'` never fires and the short-circuit becomes dead code. That means the bootstrap will now index *every* ranked candidate per term (50+), not just the first 4. This is semantically correct given the 7h6 goal (uncap!), but it is a behavior change to an ops script and it breaks three existing tests that pin the old invariant.

### Red/Green/Refactor (migration + new coverage)

**Tests that break and must be migrated:**

1. `apps/silmari-mcp/tests/bootstrap-keyword-index.test.ts:170-210` (approx) — "honors cap even with >4 candidates" / `report.rejectedFull >= 1` assertion. Rewrite: "indexes all ranked candidates regardless of density". `report.rejectedFull` field is gone; delete any assertion on it.
2. `apps/silmari-mcp/tests/keyword-index-sqlite.test.ts:142-153` — `describe('sparsity invariant (MAX_ENTRY_POINTS)', ...)` block asserting "only 4 stick after 10 inserts". Rewrite as a density-10 test asserting all 10 stick.
3. Any `bootstrap-keyword-index.test.ts` assertion on `>= MAX_ENTRY_POINTS` / `<= MAX_ENTRY_POINTS` invariants — convert to no-op deletion or density assertions as appropriate.

**Bootstrap script changes (`apps/silmari-mcp/scripts/bootstrap-keyword-index.ts`):**

- Line 10, 140: drop the `MAX_ENTRY_POINTS` import and any comments referencing it.
- Line 207: the `addKeywordEntry` callsite — update to new arg shape if needed (should already use `entryPoint` + `curator`; verify).
- Line 218-222: rewrite the `else if (r.kind === 'rejected-full')` branch. Correct post-7h6 short-circuit is: "if `r.kind === 'already-present'`, stop feeding this term (it's saturated with the top-ranked candidates we already gave it)". Concretely:

  ```ts
  // BEFORE (7h6 deletes this branch):
  } else if (r.kind === 'rejected-full') {
    rejectedFull++;
    break; // cap reached
  }

  // AFTER:
  } else if (r.kind === 'already-present') {
    // Already indexed — continue to next candidate; this is not a terminator.
    alreadyPresent++;
  }
  ```

- Drop the `rejectedFull` counter from `BootstrapReport` entirely. Update any JSON output or logging that referenced it.

**New test (optional but recommended):** add a `bootstrap-keyword-index.test.ts` block asserting "given 10 candidates for term X, bootstrap indexes all 10 (not 4)". Gates future regressions that re-introduce a cap via the back door.

Commit this behavior alongside Behavior 6 (same test-migration commit) so the git log shows "tests migrated" as one coherent diff.

## Integration & E2E testing

- **E2E sanity:** run the cascade v1 pipeline end-to-end against the KC Baker test transcript (`scripts/kc-baker-pipeline/`, see `MEMORY/WORK/20260422-130501_kc-baker-transcript-to-silmari-docker/`) with 7h6 and r04 shipped together. Assertion: `bv --export-pages` over the resulting store shows ≥1 term with `entry_points.length ≥ 50`. Log the top-5 densest terms and eyeball that they match the transcript's substantive vocabulary.
- **Alpha smoke:** after deploying to ionos01 via `scripts/deploy-ionos01.sh`, run `./scripts/alpha-smoketest.sh`. Note: `zk_status` today exposes `{br_available, cards, hubs, structures, keywords, version}` where `keywords` is a count of TERMS, not max density per term (verified at `apps/silmari-mcp/src/index.ts:624-638`). The plan does NOT gate on a density field — adding `keyword_index_max_entries` or similar is an out-of-scope widening deferred to cascade Step 6.5 or its own slice. Smoke assertion for 7h6: `zk_status.keywords` is non-zero and monotonically non-decreasing across the deploy; perform a manual `zk_recall voice` (or any substantive term in the existing alpha corpus) and eyeball that the returned entry count is larger than pre-deploy for terms that previously saturated at 4.
- **Snapshot check:** capture a pre-deploy `zk_status` JSON on ionos01. After deploy, re-capture. Expect `keywords` (term count) to be monotonically non-decreasing — 7h6 shouldn't touch the on-disk format, so the only change is that future adds succeed where they previously short-circuited; existing data unchanged.

## Rollout / migration plan

- **Single PR.** Commits in order:
  1. **Library change + MCP description rewrite** (paired together). One commit that deletes `MAX_ENTRY_POINTS`, narrows `AddKeywordResult` to two variants, simplifies `addKeywordEntry`, and rewrites/extracts the MCP tool description at `index.ts:287` + drops `force` from the JSON schema at `index.ts:295`. **Both changes land together** so `git log` never shows the constant deleted while the tool description still advertises a cap of 4.
  2. **Test migration** (Behavior 6 + Behavior 7 together). Rewrites/deletes the `'replaced'`/`'rejected-full'` test callsites, the `sparsity invariant` block in `keyword-index-sqlite.test.ts:142-153`, and the cap-invariant tests in `bootstrap-keyword-index.test.ts:170-210`. Also migrates the bootstrap script short-circuit.
  3. **README migration-notes section** added to `apps/silmari-mcp/README.md` under a new heading "Migration notes — 7h6". Enumerates the API break (see below) and links to this plan.
- **No version bump.** `apps/silmari-mcp/package.json` is `"version": "0.0.0"` + `"private": true` — internal monorepo package. No npm publish to gate on. The README entry is the durable record.
- **README "Migration notes — 7h6" section** must enumerate:
  - Removed: `MAX_ENTRY_POINTS` constant
  - Removed: `AddKeywordResult` variants `'replaced'` and `'rejected-full'`, including the `evicted: string` field on `'replaced'`
  - Deprecated (kept as no-op): `force` parameter on `addKeywordEntry` — dropped from MCP JSON schema
  - Changed: MCP tool description for `zk_keyword_add`
  - Migration guide: two code blocks — before/after for TypeScript callers (`.kind === 'replaced'` → exhaustiveness narrows to `'added' | 'already-present'`) and MCP clients (`force` no longer in schema; behavior is "unbounded append" regardless).
- **Deploy order relative to cascade:** 7h6 and r04 ship together, ahead of cascade Steps 3–6. Verified via parent plan §1.
- **Rollback:** revert the PR. On-disk format untouched, so no data migration needed in either direction.

## Risk register

1. **Silent test dead-branches.** Tests using `as any` to bypass the type system and comparing `.kind` strings at runtime. Mitigation: grep the migration surface before ship; the grep in §"Behavior 6" is the safety net. Residual risk: low — Silmari tests avoid `any`.
2. **Downstream MCP clients we don't control.** Third-party callers branching on `'replaced'`. Mitigation: README "Migration notes — 7h6" section documents the three removed symbols by name; JSON schema update removes `force` from the advertised tool surface so new clients see the correct shape. Residual: out of our hands for clients that pin to the old shape; the framework-invariant argument in §"Why this isn't just 'strip the cap'" is the user-facing justification.
3. **Runtime performance at high fan-in.** `lookupKeyword` is O(n) in entry count; at n=500 inside a hot zk_recall loop this could matter. Mitigation: B4's 5,000-insert test pins a 5s budget as a regression sentinel. Residual: if profiling shows a real hotspot, it's a separate slice (an index-of-the-index or a prefix-trie). 7h6 does not speculatively optimize.
4. **`force:true` callers we haven't found.** Third-party scripts (not in the repo grep surface). Mitigation: changelog notes the breakage; type error at compile is loud.
5. **MCP description drift.** The description constant ends up referenced in two places (tool registration + a docs page), and one drifts. Mitigation: B5's refactor to a single exported constant + snapshot test.

## References

- Parent plan: `thoughts/searchable/shared/plans/2026-04-22-tdd-silmari-cascade-extractor.md` (§1 row 7h6, §8 Luhmann multiple-storage, §11 item 3 telemetry justification)
- bd issue: `silmari-agent-memory-7h6`
- Dependency: blocks `silmari-agent-memory-7h6` on `silmari-agent-memory-r04` — both land before cascade Step 6.
- Global memory: `feedback_silmari_no_max_entry_points.md` — "Keyword entries are uncapped; current 4-cap + FIFO eviction is a silmari-mcp artifact to remove"
- Framework axiom: `feedback_zettelkasten_no_embeddings.md` — "Zettelkasten links ARE retrieval"; the cap is a retrieval lie.
- File references:
  - `apps/silmari-mcp/src/lib/keyword-index.ts:52-56` — `KeywordEntry` type
  - `apps/silmari-mcp/src/lib/keyword-index.ts:74-78` — `AddKeywordResult` type (to reduce)
  - `apps/silmari-mcp/src/lib/keyword-index.ts:88` — `MAX_ENTRY_POINTS` constant (to delete)
  - `apps/silmari-mcp/src/lib/keyword-index.ts:236` — `readKeywordIndex`
  - `apps/silmari-mcp/src/lib/keyword-index.ts:261` — `lookupKeyword`
  - `apps/silmari-mcp/src/lib/keyword-index.ts:287-291` — FIFO-as-design comment (to delete)
  - `apps/silmari-mcp/src/lib/keyword-index.ts:298` — `addKeywordEntry` (to simplify)
  - `apps/silmari-mcp/src/lib/keyword-index.ts:368-379` — FIFO eviction body (to delete)
  - `apps/silmari-mcp/src/lib/keyword-index.ts:394` — `removeKeywordEntry` (unchanged)
  - `apps/silmari-mcp/src/index.ts:287` — `zk_keyword_add` MCP tool description literal (to rewrite + extract)
  - `apps/silmari-mcp/src/index.ts:295` — `zk_keyword_add` JSON inputSchema (drop `force` property; see B3)
  - `apps/silmari-mcp/src/index.ts:620` — MCP dispatcher for `zk_keyword_add` (migrate call shape; see Migration surface)
  - `apps/silmari-mcp/src/lib/card-ops.ts:722` — save-time L2 writer (migrate `force:false` callsite; see Migration surface)
  - `scripts/kc-baker-pipeline/ingest.ts:168, 177` — JSON-RPC callers passing `force:true` (stay as-is; server-side no-op)
  - `apps/silmari-mcp/src/lib/navigate.ts:626` — read-side `entry_points` iteration (unchanged)
