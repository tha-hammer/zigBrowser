---
date: "2026-04-13T02:15:00-04:00"
reviewer: Silmari
plan_reviewed: "thoughts/searchable/shared/plans/2026-04-13-algorithm-v381-folgezettel-mode-selection.md"
status: needs_major_revision
---

# Plan Review: Algorithm v3.8.1 — Folgezettel Mode Selection

## Review Summary

| Category | Status | Issues Found |
|----------|--------|--------------|
| Contracts | :x: | 1 CRITICAL — fork cannot target a specific card |
| Interfaces | :x: | 1 CRITICAL — zk_save_card missing `fromAddress` parameter |
| Promises | :warning: | 1 WARNING — multi-save ordering assumes shared parent |
| Data Models | :white_check_mark: | 0 issues — cursor file schema is adequate |
| APIs | :x: | 1 CRITICAL — MCP tool surface needs expansion |

---

## CRITICAL ISSUE: `mode: "fork"` Cannot Target a Specific Card

**Severity:** CRITICAL — blocks entire plan

**The plan assumes:** "If RECALL hit card zk-XXX at address 5/3, fork from it → new card gets 5/3a"

**Reality:** `assignFolgezettel(trunk, mode)` at `folgezettel.ts:268` takes NO address parameter. It ALWAYS operates on the per-trunk cursor:

```typescript
// folgezettel.ts:277-285
const current = file.cursors[key];  // ← always the LAST assigned sequence
if (mode === 'fork') {
    next = forkSequence(current);    // ← forks from cursor, NOT from target
}
```

**Concrete failure scenario:** Trunk 5 cursor is at `129` (the last card). Algorithm recalls card at `5/3` and calls `zk_save_card({mode: "fork", trunk: 5})`. Code runs `forkSequence("129")` → `"129a"`. New card lands at `5/129a` — a child of card 129, NOT card 3.

**Impact:** Every "fork from recalled card" instruction in the plan silently forks from the WRONG card. The tree grows from the wrong location.

### Required Fix: Add `fromAddress` parameter

Add a `fromAddress` parameter to `zk_save_card` that, when present, overrides the cursor for fork/continue operations. This requires changes in 3 files:

**1. `apps/silmari-mcp/src/index.ts`** — tool schema + dispatch:
- Add `fromAddress` to `zk_save_card` inputSchema properties
- Pass it through to `saveCard()`

**2. `apps/silmari-mcp/src/lib/card-ops.ts`** — SaveCardOpts + saveCard():
- Add `fromAddress?: string` to SaveCardOpts (idea box variant)
- In saveCard(), when `fromAddress` is present, temporarily set the cursor to that address before calling `assignFolgezettel`

**3. `apps/silmari-mcp/src/lib/folgezettel.ts`** — assignFolgezettel():
- Add optional `fromSequence?: string` parameter
- When present, use it instead of `file.cursors[key]` for the fork/continue base
- Still update the cursor to the new sequence afterward

**The Algorithm call becomes:**
```
# Fork from recalled card at 5/3:
mcp__silmari__zk_save_card({ 
  body: "{q1}", kind: "learning", trunk: 5, 
  mode: "fork", 
  fromAddress: "5/3",   ← NEW: tells the system WHERE to fork from
  source: "algorithm-{slug}-learn" 
})
# Result: new card at 5/3a (correct!)
```

---

## WARNING: Multi-Save Ordering

**The plan says:** Q1 gets fork, Q2-Q4 get continue (creating siblings).

**Issue:** After Q1 forks to `5/3a`, Q2's continue gives `5/3b`. But what if Q2 should branch from a DIFFERENT recalled card (e.g., `5/7`)? The current "Q1=fork, Q2-Q4=continue" blanket rule doesn't support this.

**Recommendation:** Each save call should independently specify its `fromAddress` when forking. Only use `continue` when the card is genuinely a sibling of the previous save. The Algorithm should evaluate mode AND fromAddress per question, not assume all 4 share a parent.

---

## WARNING: Restatement Handling Inconsistency

**v3.8.0 LEARN DIFF table** still says: "Restatement → Do NOT save duplicate. Propose reinforces edge only."

**Research doc says:** Luhmann's multiple-storage principle — ALWAYS save in the new context, the location IS the meaning.

**The v3.7.0.md** was updated (commit 62577b9) to save restatements as new cards. But the LEARN phase section in v3.8.0 may not have this update (the Architect found v3.7.0 line 635 still says "Do NOT save").

**Recommendation:** Reconcile in v3.8.1. If adopting multiple-storage, update the DIFF table to: "Restatement → Save a new card at the current context (mode: fork from recalled card), then propose reinforces edge." This requires the `fromAddress` fix above.

---

## Suggested Plan Amendments

### Add Phase 0: Code Change — `fromAddress` Parameter

**Before ANY Algorithm prompt changes**, implement:

```diff
+ Phase 0: Add fromAddress to zk_save_card
+   - folgezettel.ts: assignFolgezettel(trunk, mode, fromSequence?)
+   - card-ops.ts: SaveCardOpts.fromAddress, saveCard() cursor override
+   - index.ts: zk_save_card schema + dispatch
+   - Tests: fork from specific address, continue from specific address
+   - Verify: forkSequence("3") → "3a" when fromAddress="5/3"
```

### Update Phase 1: Algorithm calls use fromAddress

```diff
- mcp__silmari__zk_save_card({ body: "{q1}", kind: "learning", trunk: 5, mode: "fork" })
+ mcp__silmari__zk_save_card({ body: "{q1}", kind: "learning", trunk: 5, mode: "fork", fromAddress: "{recalled_card_address}" })
```

### Update Phase 2: THINK/EXECUTE/VERIFY also use fromAddress

Same pattern — when forking from a recalled card, specify `fromAddress`.

---

## Approval Status

- [ ] **Ready for Implementation** — No critical issues
- [ ] **Needs Minor Revision** — Address warnings before proceeding
- [x] **Needs Major Revision** — Critical issue: `fromAddress` parameter must be implemented first
