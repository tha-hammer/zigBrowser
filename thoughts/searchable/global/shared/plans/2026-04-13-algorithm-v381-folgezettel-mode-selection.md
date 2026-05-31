---
date: "2026-04-13T01:30:00-04:00"
researcher: Silmari
git_commit: b75931b
branch: main
repository: silmari-agent-memory
topic: "Algorithm v3.8.1 — folgezettel mode selection protocol"
tags: [plan, algorithm, folgezettel, branching, zettelkasten, mode-selection]
status: ready
last_updated: "2026-04-13"
last_updated_by: Silmari
type: implementation_plan
depends_on: "thoughts/searchable/shared/research/2026-04-12-zettelkasten-thinking-tool-dashboard-design.md"
review: "thoughts/searchable/shared/plans/2026-04-13-algorithm-v381-folgezettel-mode-selection-REVIEW.md"
review_status: "all critical issues resolved"
---

# Algorithm v3.8.1 — Folgezettel Mode Selection Protocol

## Overview

Add `mode` + `fromAddress` parameter selection logic to every `zk_save_card` call in the Algorithm so cards are PLACED in the folgezettel tree rather than dumped sequentially at root depth. Currently 264 cards have zero branching — this is the prerequisite for all viewer tree navigation work.

## Current State Analysis

- `SAI/Algorithm/v3.8.0.md` — 647 lines, caveman mode at lines 581-648
- `zk_save_card` appears in **6 locations** across the file, NONE with `mode` or `fromAddress`:
  - Memory Integration LEARN Step 3: lines 80, 83, 86, 89 (template `{trunk}`)
  - LEARN phase section: lines 510, 513, 516, 519 (hardcoded `trunk: 5`)
  - THINK: line 129/431 (risk save)
  - EXECUTE: line 137/456 (decision save)
  - VERIFY: line 143/463 (finding save)
  - AUTO-CAPTURE STATE: line 545 (in_progress save)
- Banner example at line 304 still says v3.7.0
- LEARN DIFF table (line ~502) still says "Restatement → Do NOT save duplicate" — needs multiple-storage update
- Caveman section (lines 581-648) preserved as-is

### Key Discoveries:
- `folgezettel.ts` — `assignFolgezettel(trunk, mode, fromSequence?)` NOW supports explicit target (Phase 0 landed)
- `card-ops.ts` — `SaveCardOpts.fromAddress` NOW overrides cursor for fork/continue
- `index.ts` — `zk_save_card` schema NOW includes `fromAddress` parameter
- 382/382 tests pass including 11 new `fromAddress` integration tests
- `fork fromAddress:"5/3"` correctly produces `5/3a` even with cursor at 129 (verified)

### Review Findings Addressed:

| Review Issue | Severity | Resolution |
|---|---|---|
| `mode: "fork"` cannot target specific card | CRITICAL | **RESOLVED** — Phase 0 landed `fromAddress` parameter |
| Multi-save ordering assumes shared parent | WARNING | **RESOLVED** — each save independently specifies `fromAddress` |
| Restatement handling inconsistency | WARNING | **RESOLVED** — adopting multiple-storage principle in DIFF table |
| MCP tool surface needs expansion | CRITICAL | **RESOLVED** — `fromAddress` added to `zk_save_card` schema |

## Desired End State

After this plan:
1. The Algorithm decides `fork`/`continue`/`root` AND specifies `fromAddress` based on RECALL results
2. New cards get branched addresses like `5/3a`, `5/3a1` when they relate to recalled cards
3. `neighborhood()` returns non-empty parent/sibling/children for branched cards
4. The cursor file shows branched-depth entries (e.g., `"5": "3a1"` not just `"5": "130"`)
5. LEARN DIFF table adopts Luhmann's multiple-storage principle (restatements get new cards + reinforces edge)
6. Version is 3.8.1, banner updated, caveman section untouched

### Verification:
- Run Algorithm on a test task → LEARN saves with `mode: "fork", fromAddress: "5/N"`
- Check `folgezettel-cursors.json` shows letter-segment cursor
- Call `zk_neighborhood` on a new branched card → non-empty `parentChain`
- `grep -c 'fromAddress' SAI/Algorithm/v3.8.1.md` returns 8+ (every fork/continue save has it)

## What We're NOT Doing

| NOT Doing | ARE Doing |
|-----------|-----------|
| Retroactively branching existing 264 flat cards | Accepting flat legacy, branching forward |
| ~~Changing folgezettel.ts or card-ops.ts~~ | Phase 0 already landed these changes |
| Adding new MCP tools | Using existing `mode` + `fromAddress` parameters |
| Viewer redesign | Only the Algorithm spec — viewer is next plan |
| Changing caveman section | Preserving lines 581-648 exactly |

---

╔═══════════════════════════════════════════════════╗
║  PHASE 0: fromAddress Parameter (COMPLETE)         ║
║  Code change that unblocks all Algorithm work       ║
╚═══════════════════════════════════════════════════╝

## Phase 0: `fromAddress` Parameter — COMPLETE

- [x] `folgezettel.ts:268` — `assignFolgezettel(trunk, mode, fromSequence?)` added
- [x] `card-ops.ts:61` — `fromAddress?: string` added to `SaveCardOpts`
- [x] `card-ops.ts:375` — `resolveExplicitTarget()` preflight validates before dedup
- [x] `index.ts:99` — `fromAddress` in tool schema
- [x] `index.ts:430` — forwarded through dispatch
- [x] `index.ts:422` — biblio-box rejection
- [x] 52/52 folgezettel tests pass (4 new)
- [x] 11/11 fromAddress integration tests pass
- [x] 382/382 full suite — zero regressions

---

╔═══════════════════════════════════════════════════════╗
║  PHASE 1: Mode + fromAddress Protocol — LEARN          ║
║  The core change: decide WHERE to place each card       ║
╚═══════════════════════════════════════════════════════╝

## Phase 1: Mode + fromAddress Selection for LEARN

### Overview

Insert a PLACE step between LEARN Step 2 (DIFF) and Step 3 (SAVE). For every card the Algorithm saves, it must decide: mode (`fork`/`continue`/`root`) AND, when forking, the `fromAddress` of the recalled card to branch from.

### Changes Required:

#### 1. Add "Step 2.5 — PLACE" to Memory Integration section

**File**: `SAI/Algorithm/v3.8.1.md`
**Location**: After Step 2 DIFF table, before Step 3 SAVE

```markdown
   **Step 2.5 — PLACE each card in the folgezettel tree (mode + fromAddress selection).**

   Luhmann's "placing IS thinking" — deciding where a card belongs forces you to reason about how it relates to existing thought. Before calling `zk_save_card`, determine BOTH `mode` and `fromAddress`:

   | RECALL result | mode | fromAddress | What happens |
   |---|---|---|---|
   | Hit: branches from recalled card at `{addr}` | `"fork"` | `"{addr}"` | Child one level deeper (e.g., `5/3` → `5/3a`) |
   | Previous save in this run was at `{addr}` and this is a sibling | `"continue"` | omit (cursor is already there) | Bumps last segment (e.g., `5/3a` → `5/3b`) |
   | Recall returned nothing / genuinely new topic | `"root"` | omit | New root-level entry (e.g., `5/130`) |

   **Decision tree:**
   ```
   Did RECALL find a specific card this insight branches from?
   ├── YES → mode: "fork", fromAddress: "{that card's fz address}"
   │         (most common — LEARN saves react to recalled cards)
   └── NO → Did you just save a sibling card in this LEARN phase?
       ├── YES → mode: "continue" (cursor is already at the right depth)
       └── NO → mode: "root"
   ```

   **`fork` + `fromAddress` is the most common correct choice.** The `fromAddress` parameter tells the system WHERE in the tree to branch from — without it, `fork` branches from the cursor position, which may be a completely different card.

   **Each save independently evaluates its mode.** Q1 may fork from recalled card A. Q2 may fork from a DIFFERENT recalled card B (different `fromAddress`). Q3 may continue as a sibling of Q2. Do NOT assume all saves share a parent.
```

#### 2. Update LEARN Step 3 SAVE calls — Memory Integration section (lines 77-90)

**New:**
```markdown
   **Step 3 — SAVE only the novel, using precise `kind`, `mode`, and `fromAddress`:**
   ```
   # Q1 "should have done differently" → learning OR signal
   # If RECALL hit card at address "5/X", fork from it:
   mcp__silmari__zk_save_card({ body: "{q1}", kind: "learning", trunk: {trunk}, mode: "fork", fromAddress: "{recalled_address}", source: "algorithm-{slug}-learn" })
   # If no recall hit, new topic:
   mcp__silmari__zk_save_card({ body: "{q1}", kind: "learning", trunk: {trunk}, mode: "root", source: "algorithm-{slug}-learn" })

   # Q2 "smarter algorithm" → learning OR fact
   # If sibling of Q1 (same parent topic): continue (cursor already at right depth)
   # If branches from a DIFFERENT recalled card: fork with that card's fromAddress
   mcp__silmari__zk_save_card({ body: "{q2}", kind: "learning", trunk: {trunk}, mode: "{mode}", fromAddress: "{addr_if_fork}", source: "algorithm-{slug}-learn" })

   # Q3, Q4 — same pattern: evaluate mode + fromAddress independently per question
   mcp__silmari__zk_save_card({ body: "{q3}", kind: "preference", trunk: {trunk}, mode: "{mode}", fromAddress: "{addr_if_fork}", source: "algorithm-{slug}-learn" })
   mcp__silmari__zk_save_card({ body: "{q4}", kind: "learning", trunk: {trunk}, mode: "{mode}", fromAddress: "{addr_if_fork}", source: "algorithm-{slug}-learn" })
   ```

   **`fromAddress` is required for `mode: "fork"`, omit for `mode: "continue"` and `mode: "root"`.**
```

#### 3. Update LEARN Step 3 SAVE calls — LEARN phase section (lines 506-522)

Mirror the same changes with hardcoded `trunk: 5`:

```markdown
  - **SAVE REFLECTIONS USING PRECISE `kind`, `mode`, AND `fromAddress`:**

    For each reflection classified as Novel, Restatement, or Reinforcement-with-new-angle:
    - RECALL hit → `mode: "fork"`, `fromAddress: "{recalled_card_fz_address}"`
    - Sibling of previous save this run → `mode: "continue"` (no fromAddress needed)
    - No recall hit → `mode: "root"` (no fromAddress needed)

    ```
    # Q1 — fork from recalled card, or root if no recall hit
    mcp__silmari__zk_save_card({ body: "{q1}", kind: "learning", trunk: 5, mode: "fork", fromAddress: "{recalled_address}", source: "algorithm-{slug}-learn" })

    # Q2 — evaluate independently: fork from different card, continue as sibling, or root
    mcp__silmari__zk_save_card({ body: "{q2}", kind: "learning", trunk: 5, mode: "{mode}", fromAddress: "{addr_if_fork}", source: "algorithm-{slug}-learn" })

    # Q3, Q4
    mcp__silmari__zk_save_card({ body: "{q3}", kind: "preference", trunk: 5, mode: "{mode}", fromAddress: "{addr_if_fork}", source: "algorithm-{slug}-learn" })
    mcp__silmari__zk_save_card({ body: "{q4}", kind: "learning", trunk: 5, mode: "{mode}", fromAddress: "{addr_if_fork}", source: "algorithm-{slug}-learn" })
    ```
```

#### 4. Update LEARN DIFF table — adopt multiple-storage principle

**Current** (v3.8.0 line ~502):
```
| **Restatement** — same lesson already exists as `br-XXX` | Do NOT save duplicate. Call propose_link reinforces. |
```

**New** (Luhmann multiple-storage):
```markdown
   | **Restatement** — same lesson observed again, prior card `zk-XXX` at address `{addr}` | **Save a new card in the current context** — the new context IS the value (Luhmann's multiple-storage principle). `mode: "fork"`, `fromAddress: "{addr}"` to place it near the recalled card. Then `mcp__silmari__zk_propose_link({fromId: <newId>, toId: "zk-XXX", edge: "reinforces", rationale: "same lesson in context of {current-task}"})` then `zk_commit_link`. The graph now has TWO cards connected by `reinforces` — future recall sees how the same idea appeared in different contexts. |
```

### Success Criteria:

#### Automated:
- [ ] `grep -c 'fromAddress' SAI/Algorithm/v3.8.1.md` returns >= 8
- [ ] `grep 'zk_save_card' SAI/Algorithm/v3.8.1.md | grep -v 'mode'` returns 0 (every save has mode)
- [ ] The string "Step 2.5" and "PLACE" appear in the file
- [ ] "multiple-storage" or "placing IS thinking" appears in the file
- [ ] "Restatement" row in DIFF table says "Save a new card" (not "Do NOT save")

#### Manual:
- [ ] Decision tree is unambiguous: fork needs fromAddress, continue/root don't
- [ ] Each save call independently evaluates mode + fromAddress
- [ ] DIFF table matches Luhmann multiple-storage principle

---

╔═══════════════════════════════════════════════════════╗
║  PHASE 2: Mode + fromAddress for THINK/EXECUTE/VERIFY  ║
║  All save paths must branch, not just LEARN             ║
╚═══════════════════════════════════════════════════════╝

## Phase 2: Mode + fromAddress for Non-LEARN Save Calls

### Overview

THINK, EXECUTE, and VERIFY phases also save cards. Each must specify `mode` and `fromAddress` when forking.

### Changes Required:

#### 1. THINK risk saves (Memory Integration ~line 129 + THINK phase ~line 431)

**New:**
```
# Per-risk RECALL first. If recall hit card at {addr}, fork from it:
mcp__silmari__zk_save_card({ body: "{risk}", kind: "signal", trunk: 5, mode: "fork", fromAddress: "{recalled_risk_address}", source: "algorithm-{slug}-think" })
# If novel risk (no recall hit):
mcp__silmari__zk_save_card({ body: "{risk}", kind: "signal", trunk: 5, mode: "root", source: "algorithm-{slug}-think" })
```

#### 2. EXECUTE decision saves (Memory Integration ~line 137 + EXECUTE phase ~line 456)

**New:**
```
# If this decision relates to a recalled card at {addr}:
mcp__silmari__zk_save_card({ body: "{decision} (reason: {why})", kind: "fact", trunk: 5, mode: "fork", fromAddress: "{recalled_address}", source: "algorithm-{slug}-execute" })
# If standalone decision:
mcp__silmari__zk_save_card({ body: "{decision} (reason: {why})", kind: "fact", trunk: 5, mode: "root", source: "algorithm-{slug}-execute" })
```

#### 3. VERIFY finding saves (Memory Integration ~line 143 + VERIFY phase ~line 463)

**New:**
```
# If this finding relates to a recalled card at {addr}:
mcp__silmari__zk_save_card({ body: "{finding}", kind: "signal", trunk: 5, mode: "fork", fromAddress: "{recalled_address}", source: "algorithm-{slug}-verify" })
# If novel finding:
mcp__silmari__zk_save_card({ body: "{finding}", kind: "signal", trunk: 5, mode: "root", source: "algorithm-{slug}-verify" })
```

#### 4. AUTO-CAPTURE STATE save (LEARN phase ~line 545)

**New:**
```
mcp__silmari__zk_save_card({
  body: "in_progress: {PRD title} ...",
  kind: "stub",
  trunk: 5,
  mode: "root",
  status: "in_progress",
  source: "algorithm-{slug}-state"
})
```

State captures are ALWAYS `root` — they are standalone status markers, not branches of prior thought. No `fromAddress` needed.

### Success Criteria:

#### Automated:
- [ ] `grep 'zk_save_card' SAI/Algorithm/v3.8.1.md | grep -vc 'mode'` returns 0
- [ ] THINK, EXECUTE, VERIFY saves show fork+fromAddress pattern
- [ ] AUTO-CAPTURE STATE uses `mode: "root"` (no fromAddress)

---

╔═══════════════════════════════════════════════════════╗
║  PHASE 3: Version Bump + Banner Fix                    ║
║  Increment to 3.8.1, preserve caveman section          ║
╚═══════════════════════════════════════════════════════╝

## Phase 3: Version Bump

### Changes Required:

#### 1. Copy v3.8.0.md → v3.8.1.md
```bash
cp SAI/Algorithm/v3.8.0.md SAI/Algorithm/v3.8.1.md
```
Then apply all Phase 1 + Phase 2 edits to v3.8.1.md.

#### 2. Update title (line 1)
```
## The Algorithm 3.8.0  →  ## The Algorithm 3.8.1
```

#### 3. Update banner example (line ~304)
```
♻︎ Entering the SAI ALGORITHM… (v3.7.0)  →  ♻︎ Entering the SAI ALGORITHM… (v3.8.1)
```

#### 4. Update CLAUDE.md reference
`~/.claude/CLAUDE.md` references the Algorithm file path. Update:
```
SAI/Algorithm/v3.8.0.md  →  SAI/Algorithm/v3.8.1.md
```

#### 5. Preserve caveman section (lines 581-648)
**No changes.** Verbatim from v3.8.0.

### Success Criteria:

#### Automated:
- [ ] `head -1 SAI/Algorithm/v3.8.1.md` contains "3.8.1"
- [ ] `grep 'v3.8.1' SAI/Algorithm/v3.8.1.md` finds the banner
- [ ] `diff <(tail -68 SAI/Algorithm/v3.8.0.md) <(tail -68 SAI/Algorithm/v3.8.1.md)` shows no differences (caveman preserved)
- [ ] `grep 'v3.8.1' ~/.claude/CLAUDE.md` confirms reference update

---

╔═══════════════════════════════════════════════════════╗
║  PHASE 4: Verification — Test Branching on Real Task   ║
║  Confirm the tree actually grows                        ║
╚═══════════════════════════════════════════════════════╝

## Phase 4: Verification

### Test Protocol:

1. **Start a fresh Algorithm run** on any task (can be trivial)
2. **OBSERVE phase** — RECALL should find existing cards
3. **LEARN phase** — saves should use `mode: "fork", fromAddress: "5/N"` when branching from recalled cards
4. **After the run**, verify:

```bash
# Check cursor file for branched depth
cat ~/.silmari-memory/box2-ideas/.beads/folgezettel-cursors.json
# Expected: cursor has a letter segment like "5": "3a" (not just "5": "130")

# Check labels table for branched addresses
sqlite3 ~/.silmari-memory/box2-ideas/.beads/beads.db \
  "SELECT label FROM labels WHERE label LIKE 'fz:%' AND label GLOB 'fz:*[a-z]*'"
# Expected: at least 1 result (e.g., fz:5_3a)

# Test neighborhood on a branched card
# Via MCP: zk_neighborhood({ address: "5/3a" })
# Expected: parentChain includes the card at 5/3, siblings may be empty (first branch)
```

### Success Criteria:

#### Automated:
- [ ] `sqlite3 ... "SELECT COUNT(*) FROM labels WHERE label LIKE 'fz:%' AND label GLOB 'fz:*[a-z]*'"` returns > 0
- [ ] Cursor file contains at least one entry with letter segments
- [ ] `zk_neighborhood` on a branched card returns non-empty `parentChain`

#### Manual:
- [ ] Run an Algorithm task end-to-end with new v3.8.1
- [ ] Observe LEARN phase selecting modes (fork/continue/root) with fromAddress in output
- [ ] Confirm no regressions — Algorithm completes all 7 phases
- [ ] New card body is placed as a child of the recalled card (verify fz address)

---

## Testing Strategy

### Primary Test:
Run the Algorithm on a small task and verify:
1. LEARN Phase fires RECALL → hits existing cards
2. LEARN Phase selects `mode: "fork"`, `fromAddress: "5/N"` for at least one save
3. New card gets a letter-segment address (e.g., `5/3a`)
4. `neighborhood()` returns the parent card in `parentChain`

### Edge Cases:
- RECALL returns nothing → all saves should be `mode: "root"`, no `fromAddress`
- Multiple saves in one LEARN → Q1 forks from card A, Q2 forks from card B (different fromAddress), Q3 continues as sibling of Q2
- Different trunk than 5 → mode selection works the same across all trunks
- Recalled card is at branched depth already (e.g., `5/3a`) → fork produces `5/3a1`
- Recalled card is a Register (`5/0`) → fromAddress validation should reject it

### Regression:
- Algorithm completes all 7 phases without errors
- Existing 264 flat cards are not modified (addresses are permanent)
- OBSERVE RECALL still works with mixed flat + branched address space
- Caveman section still renders correctly

## References

- Research: `thoughts/searchable/shared/research/2026-04-12-zettelkasten-thinking-tool-dashboard-design.md` (§CRITICAL FINDING)
- Review: `thoughts/searchable/shared/plans/2026-04-13-algorithm-v381-folgezettel-mode-selection-REVIEW.md`
- Current Algorithm: `SAI/Algorithm/v3.8.0.md`
- Folgezettel implementation: `apps/silmari-mcp/src/lib/folgezettel.ts` (now with `fromSequence` param)
- Card operations: `apps/silmari-mcp/src/lib/card-ops.ts` (now with `fromAddress` + `resolveExplicitTarget`)
- MCP tool schema: `apps/silmari-mcp/src/index.ts` (now with `fromAddress` in zk_save_card)
- Navigation: `apps/silmari-mcp/src/lib/navigate.ts:81-175` (parent/sibling/child)
- fromAddress tests: `apps/silmari-mcp/tests/zk-save-card-fromaddress.test.ts` (11 tests)
