---
date: "2026-04-13T11:15:00-04:00"
researcher: Silmari
git_commit: b75931b282032ed4edc7d2997aee51a0f2f0dc42
branch: main
repository: silmari-agent-memory
topic: "CRITICAL: assignFolgezettel cannot target a specific card — fromAddress parameter needed"
tags: [research, codebase, folgezettel, fromAddress, algorithm, critical-bug, mode-selection]
status: complete
last_updated: "2026-04-13"
last_updated_by: Silmari
---

```
┌──────────────────────────────────────────────────────────────────────┐
│  RESEARCH: assignFolgezettel Cannot Target a Specific Card           │
│  Status: COMPLETE | 2026-04-13                                       │
│  Triggered by: Plan Review CRITICAL finding                          │
└──────────────────────────────────────────────────────────────────────┘
```

# Research: CRITICAL — `assignFolgezettel` Cannot Target a Specific Card

**Date**: 2026-04-13T11:15:00-04:00
**Researcher**: Silmari
**Git Commit**: b75931b282032ed4edc7d2997aee51a0f2f0dc42
**Branch**: main
**Repository**: silmari-agent-memory

## Research Question

Verify the CRITICAL ISSUE raised in the v3.8.1 plan review: does `assignFolgezettel()` actually prevent fork/continue from targeting a specific recalled card? What is the concrete failure path? What files need changes?

## Summary

**The review is correct. The critical issue is verified across all three layers.** `assignFolgezettel()` always forks/continues from the per-trunk cursor (the last-assigned sequence), not from a recalled card's address. Additionally, the parent edge extraction in `saveCard()` also uses the prior cursor — so both the **address** and the **structural edge** are wrong when the intent is to branch from a specific recalled card.

---

## 📊 Detailed Findings

### 1. `assignFolgezettel()` — Cursor-Only Allocation

| Claim from Review | Verified? | Evidence |
|---|---|---|
| Function takes NO address parameter | ✅ | `folgezettel.ts:268-271` — signature is `(trunk: TrunkId, mode: FolgezettelMode): string` |
| Always reads per-trunk cursor | ✅ | `folgezettel.ts:277` — `const current = file.cursors[key]` |
| Fork uses cursor, not target | ✅ | `folgezettel.ts:284-285` — `forkSequence(current)` |
| Continue uses cursor, not target | ✅ | `folgezettel.ts:287` — `continueSequence(current)` |

**The function signature:**

```typescript
// folgezettel.ts:268-271
export function assignFolgezettel(
  trunk: TrunkId,
  mode: FolgezettelMode,
): string {
```

**The cursor read (no override possible):**

```typescript
// folgezettel.ts:276-288
const key = String(trunk);
const current = file.cursors[key];   // ← always the LAST assigned sequence

let next: string;
if (mode === 'root' || !current) {
    const maxRoot = current ? sequenceRootInt(current) : 0;
    next = rootSequence(maxRoot);
} else if (mode === 'fork') {
    next = forkSequence(current);    // ← forks from cursor, NOT from a target
} else {
    next = continueSequence(current); // ← continues from cursor, NOT from a target
}
```

---

### 2. `saveCard()` — Parent Edge Also Uses Cursor

The structural edge extraction has the **same cursor dependency**:

```typescript
// card-ops.ts:417-421
const mode = opts.mode || 'continue';
effectiveMode = mode;
const cursors = readCursors();
priorCursorSeq = cursors.cursors[String(opts.trunk)] ?? null;  // ← prior cursor
const sequence = assignFolgezettel(opts.trunk, mode);
```

Then at `card-ops.ts:486-494`:

```typescript
const parentFzLabel = fzLabel(opts.trunk, priorCursorSeq);  // ← label from cursor
const parents = brList({
    box: 'idea',
    labels: [parentFzLabel],
    limit: 1,
    all: true,
});
if (parents.length > 0) parentCardId = parents[0].id as string;
```

This `parentCardId` feeds into `extractFolgezettelParent()` at `edge-extractors.ts:104-114`, which emits either a `follows` (continue) or `branches` (fork) edge. **Both the address and the parent edge point to the wrong card** when the intent is to fork from a specific recalled card.

---

### 3. `zk_save_card` MCP Tool — No `fromAddress` Property

```typescript
// index.ts:86-103 — tool schema
{
    name: 'zk_save_card',
    inputSchema: {
        type: 'object',
        required: ['body', 'kind'],
        properties: {
            body: { type: 'string' },
            kind: { type: 'string', enum: KIND_ENUM },
            box:  { type: 'string', enum: [...BOX_ENUM], default: 'idea' },
            trunk: { type: 'number', enum: TRUNK_ENUM },
            mode: { type: 'string', enum: [...MODE_ENUM], default: 'continue' },
            scope: { type: 'string' },
            source: { type: 'string' },
            status: { type: 'string', enum: [...STATUS_ENUM] },
            // ⚠️ NO fromAddress property
        },
    },
},
```

The dispatch at `index.ts:412-432` passes `mode` through to `saveCard()` but has no mechanism to pass a target address.

`SaveCardOpts` at `card-ops.ts:61-89` also has no `fromAddress` field:

```typescript
export type SaveCardOpts =
  | {
      box: 'idea';
      body: string;
      kind: CardKind;
      trunk: TrunkId;
      mode?: FolgezettelMode;
      scope?: string;
      source?: string;
      status?: 'open' | 'in_progress' | 'blocked' | 'closed';
      extraLabels?: string[];
      priority?: number;
      // ⚠️ NO fromAddress
    }
  | { box: 'biblio'; /* ... */ };
```

---

### 4. Concrete Failure Scenario (Verified)

Given:
- Trunk 5 cursor is at `"129"` (the last card assigned)
- Algorithm recalls card `zk-ABC` at address `5/3`
- Algorithm calls `zk_save_card({ mode: "fork", trunk: 5, body: "..." })`

What happens:
1. `saveCard()` reads cursor → `priorCursorSeq = "129"`
2. `assignFolgezettel(5, "fork")` reads cursor → `current = "129"`
3. `forkSequence("129")` → `"129a"`
4. New card gets address `5/129a` (child of card 129, NOT card 3)
5. Parent edge lookup finds card at `fz:5_129`, NOT `fz:5_3`
6. A `branches` edge is created from the new card → card at 5/129

**Result:** New card is a child of card 129 instead of card 3. The tree grows from the wrong location. Every "fork from recalled card" instruction in the plan silently branches from the WRONG card.

---

### 5. Restatement Handling Inconsistency (Verified)

| File | Line | What it says |
|---|---|---|
| `v3.7.0.md` | 502 | "Do NOT save duplicate. Call `zk_propose_link`... `reinforces`" |
| `v3.8.0.md` | 67 | "**Save a new card in the current context** (multiple-storage principle)... then `zk_propose_link`... `reinforces`" |

v3.8.0 reconciled this in favor of Luhmann's multiple-storage principle (save the restatement as a new card, then link). v3.7.0 was NOT updated — line 502 still says "Do NOT save duplicate." This is an internal inconsistency in v3.7.0 vs. the commit 62577b9 which updated the LEARN specification to adopt multiple-storage.

The restatement handling works correctly in v3.8.0 and is consistent with the multiple-storage principle. **But** it requires `fromAddress` to work properly: the restatement card should fork from the recalled card's address (placing it near the original in the tree), not from the cursor.

---

### 6. Existing Test Coverage

| Test File | Coverage | Relevant to fromAddress? |
|---|---|---|
| `apps/silmari-mcp/tests/folgezettel.test.ts` | `parseSequence`, `continueSequence`, `forkSequence`, `assignFolgezettel`, `formatAddress`, `parseAddress`, `trunkHasPriorCards` | ✅ Tests exist for `assignFolgezettel` but none test a `fromSequence` parameter (it doesn't exist yet) |
| `apps/silmari-mcp/tests/edge-extractors.test.ts` | `extractFolgezettelParent` (lines 119-146) — tests `follows` for continue, `branches` for fork | ✅ Tests verify correct edge type but don't test parent resolution from a specific address |

The test infrastructure is healthy — adding `fromSequence` tests to `folgezettel.test.ts` is straightforward.

---

## 🎯 Impact Assessment

```
┌────────────────────────────────────────────────────────────────────┐
│  Without fromAddress, the v3.8.1 mode selection plan is BLOCKED.  │
│                                                                    │
│  - "fork from recalled card" → forks from WRONG card (cursor)     │
│  - "continue as sibling of recalled card" → continues from WRONG  │
│  - Structural edges (branches/follows) point to WRONG parent      │
│  - The tree grows from the tip, not from the recalled context     │
│                                                                    │
│  The ONLY mode that works correctly today: "root"                  │
│  (root ignores the cursor and allocates a fresh top-level entry)  │
└────────────────────────────────────────────────────────────────────┘
```

---

## 📁 Code References

- `apps/silmari-mcp/src/lib/folgezettel.ts:268-293` — `assignFolgezettel()` function, cursor-only allocation
- `apps/silmari-mcp/src/lib/folgezettel.ts:277` — `const current = file.cursors[key]` — the cursor read
- `apps/silmari-mcp/src/lib/folgezettel.ts:284-285` — `forkSequence(current)` — fork from cursor
- `apps/silmari-mcp/src/lib/card-ops.ts:61-89` — `SaveCardOpts` type, no `fromAddress`
- `apps/silmari-mcp/src/lib/card-ops.ts:390-530` — `saveCard()` function
- `apps/silmari-mcp/src/lib/card-ops.ts:419-421` — `priorCursorSeq` capture + `assignFolgezettel` call
- `apps/silmari-mcp/src/lib/card-ops.ts:486-494` — parent card lookup from prior cursor
- `apps/silmari-mcp/src/index.ts:86-103` — `zk_save_card` tool schema, no `fromAddress`
- `apps/silmari-mcp/src/index.ts:412-432` — `zk_save_card` dispatch, no `fromAddress` passthrough
- `apps/silmari-mcp/src/lib/edge-extractors.ts:104-114` — `extractFolgezettelParent()`, uses `parentCardId` from cursor
- `apps/silmari-mcp/tests/folgezettel.test.ts` — existing test suite for folgezettel
- `apps/silmari-mcp/tests/edge-extractors.test.ts:119-146` — existing tests for parent edge extraction

## 📚 Architecture Documentation

The folgezettel allocation system is a three-layer stack:

```
Layer 3: MCP Tool (index.ts)
  ↓ parses args, calls saveCard()
Layer 2: Card Operations (card-ops.ts)
  ↓ dedup, folgezettel assignment, label composition, edge extraction
Layer 1: Folgezettel Arithmetic (folgezettel.ts)
  ↓ pure address arithmetic + atomic cursor file I/O
```

The cursor file (`folgezettel-cursors.json`) stores one cursor per trunk — the sequence of the last-assigned card. This cursor advances monotonically: every `assignFolgezettel()` call reads the cursor, computes the next sequence, and writes the new sequence back as the cursor.

The design works correctly for **sequential** card creation (each new card is a continuation or fork of the most recent card). It breaks when the caller wants to fork/continue from a **specific historic card** that is not the most recent.

## 📜 Historical Context

- `thoughts/shared/research/2026-04-12-zettelkasten-thinking-tool-dashboard-design.md` — identified the flat-tree problem (264 cards, zero branching)
- `thoughts/shared/plans/2026-04-13-algorithm-v381-folgezettel-mode-selection.md` — the plan being reviewed
- `thoughts/shared/plans/2026-04-13-algorithm-v381-folgezettel-mode-selection-REVIEW.md` — the review that identified this critical issue

## Related Research

- `thoughts/shared/research/2026-04-12-algorithm-determinism-context-efficiency.md`
- `thoughts/shared/research/2026-04-12-beads-viewer-zettelkasten-graph-redesign.md`

## ✅ Conclusions

1. **The review's CRITICAL finding is 100% verified.** `assignFolgezettel()` cannot target a specific card — it always operates on the per-trunk cursor.

2. **The impact is broader than the review states.** Not only is the address wrong, but the structural edge (follows/branches) also points to the wrong parent, because `saveCard()` resolves `parentCardId` from the same cursor.

3. **Three files need changes** (as the review correctly identifies):
   - `folgezettel.ts:268` — add optional `fromSequence?: string` parameter
   - `card-ops.ts:61-89` — add `fromAddress?: string` to `SaveCardOpts`
   - `index.ts:86-103` — add `fromAddress` to `zk_save_card` schema

4. **The plan's "What We're NOT Doing" table says "Changing `folgezettel.ts` or `card-ops.ts`"** — this must be revised. The `fromAddress` parameter IS a prerequisite for mode selection to work correctly.

5. **Existing test infrastructure supports the fix.** `folgezettel.test.ts` and `edge-extractors.test.ts` provide a solid base for adding `fromSequence` tests.

## Open Questions

1. Should `fromAddress` override ONLY the fork/continue base, or should it also set the cursor afterward? (The review says "still update the cursor to the new sequence afterward" — this seems correct.)
2. Should `fromAddress` accept a full address (`5/3`) or just the sequence (`3`)? Full address is more ergonomic for MCP callers; the function would strip the trunk prefix.
3. Should there be validation that `fromAddress` belongs to the same trunk as the `trunk` parameter?
