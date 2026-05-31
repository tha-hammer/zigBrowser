---
date: 2026-04-22
author: Silmari (plan review)
status: review
reviews: thoughts/searchable/shared/plans/2026-04-22-tdd-silmari-cascade-extractor.md
topic: "Pre-implementation contract/interface/API review of the cascade extractor TDD plan"
tags: [silmari, review, cascade, contracts, pre-implementation]
---

# Plan Review Report: 2026-04-22-tdd-silmari-cascade-extractor.md

## Review Summary

| Category | Status | Issues Found |
|----------|--------|--------------|
| Contracts (proposeLinksSemantic, saveCard) | ⚠️ | 3 issues — 1 critical |
| Interfaces (keyword-index, lineOfThought) | ❌ | 3 issues — 2 critical (missing primitives the plan assumes exist) |
| Promises (edge-write ordering, L4 auto-fire) | ❌ | 2 critical — plan's timing is wrong; L4 auto-fire collides with Gate B |
| Data Models (AddKeywordResult, SaveCardResult, edge label enum) | ✅ | Clean — exact matches |
| APIs (MCP tool names, zk_recall limits, Tier A edges) | ⚠️ | 3 issues — naming + Tier A edge count mismatch |
| Stale / post-rewrite artifacts | ⚠️ | 4 dangling references to MiniLM, threshold.json, FDO calibration |

**Approval status:** **Needs Major Revision.** Four critical issues block implementation. The Level-2 rewrite is the right direction; the rewrite hasn't fully reached three adjacent sections of the plan (risk register, acceptance criteria, §9, open questions), and the plan assumes two keyword-index primitives that don't exist. The saveCard rewrite scope is *smaller* than the plan claims (good news); the edge-write ordering claim is *wrong* (must fix before r04 begins).

---

## Critical Issues (Must Address Before Implementation)

### C1. `proposeLinksSemanticSync` auto-fires inside saveCard's L4 check — collides with Gate B's contract

**File:line:** `apps/silmari-mcp/src/lib/card-ops.ts:773-806` + `apps/silmari-mcp/src/lib/semantic-proposer.ts:458-578`

When a save produces zero Tier A `ref:` edges, `card-ops.ts` automatically invokes `proposeLinksSemanticSync()` and, if the top proposal's confidence ≥ `SILMARI_TIER_B_CONFIDENCE_THRESHOLD` (default 0.7), auto-commits that edge via `zk_commit_link`. **The plan's §6-bis Gate B is a DUPLICATE of this implicit behavior, not a replacement.**

Consequence: after r04 ships, every cascade save will:
1. Not find a Tier A edge (micros are often under a theme that forks, so Tier A will typically exist — but anchor cards without explicit source refs won't get one)
2. Auto-invoke proposeLinksSemanticSync at save time
3. Maybe commit one `refines`/`reinforces`/… edge already
4. Then Gate B (the explicit post-transcript pass) fires again over the same candidate space

**Impact:** Double-classification + edge-count telemetry in §11 becomes impossible to interpret (which pass emitted the edge?). Also: saveCard currently blocks on a subprocess shell-out to run the LLM — big latency cost per cascade save that the plan's effort estimate doesn't account for.

**Fix options (plan author to pick):**
- **(a)** Disable L4 auto-fire when a cascade-pipeline env flag is set (`SILMARI_CASCADE_SUPPRESS_L4=1`) and have Gate B be the single authoritative typed-edge source. Document in §6-bis.
- **(b)** Keep L4 auto-fire, and narrow Gate B's explicit pass to candidates the L4 fire didn't cover. Telemetry item 6 (§11) must split emission by origin (`L4-auto` vs `gateB-explicit`) — include both in every run summary.
- **(c)** Remove the L4 auto-fire block from card-ops.ts entirely as part of r04 (reframe L4 as a pure "did this card get any edge at all?" anchor test without the auto-commit side effect). This is the cleanest — the L4 auto-fire predates the cascade design and is a narrower use case.

**Recommendation:** (c). Level-2 Gate B should be the single Sonnet-classified path. The L4 auto-fire was a stopgap from the compounding-substrate Phase 3 work; cascade supersedes it.

---

### C2. Edge-write ordering in §6-bis is factually wrong — Tier A edges are AFTER brCreate, not before

**Plan §6-bis paragraphs 2-3 say:**
> "Tier A deterministic edges written inside saveCard (synchronously, before brCreate returns)"
> "saveCard → brCreate commits the card + its Tier A labels atomically"

**Actual code (`card-ops.ts:612-696`):**
- Line 612: `brCreate` commits the card with `content_hash:<short>` and other initial labels
- Lines 614-696: THEN `runExtractors` runs and each extractor calls `addEdge()` → `brLabelAdd` to write `ref:<type>:<targetId>` labels ONTO the already-created bead

Tier A is NOT atomic with card creation. The card is visible (and queryable) for a few milliseconds before any `ref:*` labels land. The plan's "atomicity" claim misrepresents reality and would guide r04's sweepDuplicates redesign down a wrong path.

**Impact on r04:** The plan's §6-bis is the spec r04 will implement against. If r04 relies on "Tier A is already written by the time reinforces fires," a concurrent reader can see a Tier-A-less card mid-save and make decisions on it. The plan must reflect the actual ordering.

**Fix:** Rewrite §6-bis step 2-3 to:
```
2. saveCard → brCreate commits the card with content_hash + metadata labels
3. runExtractors writes Tier A ref:* edge labels onto the committed card
   (async relative to brCreate but synchronous relative to saveCard's return)
4. Reinforces edge (r04) fires next, on body-hash match, before saveCard returns
```

Also clarify: the "new contract" for r04 is `{id, fz, wasReinforced, priorId, wasSweepDeleted}` — NOT a replacement of `wasDeduped`. Tests already checking `wasDeduped===true` should flip to check `wasReinforced===true` + `priorId!==null`.

---

### C3. Two "existing primitives" that the plan reuses DO NOT EXIST as described

**`gates/graph-candidates.ts` (~200 LOC estimate) assumes three ready-to-call keyword-index functions:**

1. **"look up all cards sharing a given term"** — `lookupKeyword(term)` returns `{term, entry_points: string[]}` (keyword-index.ts:261). These are ADDRESSES, not card ids. Caller must resolve each address via beads_rust → card id. No dedicated helper.
2. **"filter to candidates with ≥2 shared terms"** — **NO FUNCTION EXISTS.** Caller must (a) enumerate the new card's keyword terms, (b) for each term call `lookupKeyword`, (c) build a per-candidate counter, (d) filter counter ≥ 2. ~40-60 LOC of composition logic that isn't in the plan's LOC estimate.
3. **"get cards scoped to a specific hub"** — **NO FUNCTION EXISTS.** `lineOfThought(seedCardId).hubs` returns hubs the SEED derives-from; there's no "give me all cards in hub X" query. Must be composed via `brList -l hub-id:<hubId>` or similar. ~20-30 LOC more.

**Impact:** `graph-candidates.ts` LOC estimate is low by ~60-90 LOC, effort is low by ~1.5 hrs, and the module acquires a dependency on a beads_rust raw-label query for hub-scoped lookup.

**Fix:**
- Add Step 5.5 to the prerequisite ordering: **"Ship `hubMembers(hubId)` and `filterByKeywordOverlap(cardId, minOverlap)` in keyword-index.ts"** — ~1.5 hrs. These belong in `apps/silmari-mcp/src/lib/` as reusable primitives (not pipeline-local utilities) because future MCP tools will want them too.
- Re-estimate §1 LOC: graph-candidates.ts ≈ 280 LOC (not 200). v2 pipeline total ≈ ~1990 LOC.

---

### C4. `lineOfThought` scope is NARROWER than the plan's candidate-enumeration logic assumes

**Plan §5 says:** "lineOfThought(cardId) from `line-of-thought.ts` — returns ancestors + siblings + descendants within the folgezettel tree"

**Actual (`line-of-thought.ts:191-238, LineOfThought shape:66-83`):** returns
- `parent` (immediate parent only — not ancestor chain)
- `siblings` (same-depth peers)
- `children` (immediate children only — not descendant subtree)
- `hubs` (cards seed derives-from)
- `trunkSeeds` (root cards in seed's trunk)
- `all` (deduped union, truncated to `LINE_OF_THOUGHT_MAX = 150`)

**Impact:** A cascade micro-card at depth 4 (e.g. `1/3a2a1`) gets ONLY its depth-3 parent and depth-5 children in the neighborhood set — NOT the grand-parent theme at depth 2 or the great-grand-parent thesis at depth 1. The plan's expected reach ("ancestors + descendants") implies multi-hop traversal. Reality is single-hop + hub membership.

**Also:** The `LINE_OF_THOUGHT_MAX = 150` truncation sorts by `created_at DESC` and keeps newest — for an older card deep in the tree, neighbors added recently win over structurally-adjacent older neighbors. The plan's Gate B candidate-enumeration behavior is **time-biased toward the most-recent 150 siblings+children in the hub**, which at cascade density (120 cards/transcript) will silently drop earlier-same-transcript neighbors once the hub exceeds 150.

**Fix (pick one):**
- **(a)** Add `lineOfThoughtDeep(seedId, depth=3)` primitive that walks multiple hops up/down the fz chain. +~50 LOC in `line-of-thought.ts`.
- **(b)** Accept the single-hop limitation and rename the plan's "ancestors + descendants" language to "immediate folgezettel neighbors." Document the 150-cap truncation behavior explicitly in §5 and note it in the telemetry (item 5 should track "lineOfThought-truncated: true/false per candidate set").

**Recommendation:** (b) for v1 cascade release; (a) as a TODO for later. Keyword-overlap + hub-membership already compensate for the single-hop limitation.

---

## Warnings (Should Be Addressed Before Implementation)

### W1. `proposeLinksSemantic` has an invisible `MAX_CANDIDATES_IN_PROMPT = 20` cap

**File:line:** `semantic-proposer.ts:199`

When a caller passes >20 candidateCardIds, the primitive silently truncates to 20 (unclear ordering — likely insertion order). The plan's §11 telemetry item 5 expects candidate counts of "10-40 per card" and §12 says "default cap at top 10 by shared-keyword count."

**Action:** The cascade's `gates/graph-candidates.ts` must pre-sort candidates (by shared-keyword count descending, then hub-distance, then lineOfThought proximity) and cap to 20 BEFORE calling `proposeLinksSemantic`. Otherwise Sonnet gets an arbitrary 20-subset and typed-edge quality drops. Add to §5 Gate B description.

Alternative: add a `maxCandidatesInPrompt` parameter to `proposeLinksSemantic` (the plan's §1 "reuse infrastructure" claim is cleaner with this exposed).

### W2. `saveCard` test-rewrite scope is vastly smaller than claimed — r04 effort should drop

**Plan §0 prerequisite says:** "rewrite of 62+ `saveCard` callsites in `integration.test.ts` + sibling test files that assert `wasDeduped===true`"

**Actual count:** **6 test assertions** of `wasDeduped === true`/`toBe(true)` across 3 files (`integration.test.ts:289, 514, 580`; `migrate-from-cosmic.ts:417, 426`; `biblio.ts:120`). External consumers outside card-ops itself: 2 files.

**Impact:** r04 effort estimate (6-8 hrs "Deep effort") is over-provisioned. Test-rewrite portion is closer to ~30 minutes of mechanical edits. The harder parts remain:
- `sweepDuplicates` concurrent-writes redesign (plan correctly flags as non-trivial)
- New `wasReinforced` + `priorId` contract
- Ordering against Tier A post-brCreate edges (which itself is mis-described in §6-bis — see C2)

**Fix:** r04 re-estimate to ~4-5 hrs. Update §0 "rewrite of 62+ callsites" to "rewrite of 6 test assertions + 2 external consumers + sweepDuplicates redesign."

### W3. Tier A edge set is 4, not 5 — no `annotates` extractor ships today

**File:line:** `apps/silmari-mcp/src/lib/edge-extractors.ts:11-17` — only 3 extractors registered in `runExtractors`:
- `extractBodyMentions` → `refers-to`
- `extractFolgezettelParent` → `follows` / `branches`
- `extractSourceReference` → `derives-from`

Plan §6-bis lists five: `follows, branches, derives-from, refers-to, annotates`. **`annotates` is not currently emitted by any extractor.** It exists in the label enum (AUTO_EDGE_TYPES, `labels.ts:79-95`) as a valid type, but nothing writes it.

**Fix:** Either (a) drop `annotates` from §6-bis's Tier A list, or (b) file a separate bd issue to add an `extractAnnotates` pass (probably detects `@mentions` in body → annotates the mentioned card). Pick one before r04 starts.

### W4. MCP tool name mismatch — cascade will call `zk_propose_links_semantic`, not `zk_propose_link`

Plan §5, §6-bis, and §11 variously refer to `proposeLinksSemantic` as if the tool name were `zk_propose_link`. Actually:
- `zk_propose_link` (singular, no "_semantic") = manual proposal: operator-provided {sourceId, targetId, edge, rationale}. `index.ts:162-211`
- `zk_propose_links_semantic` (plural, _semantic) = the Sonnet-auto proposer we want. `index.ts:178-211`, handler at `:531-556`

**Fix:** Replace every `zk_propose_link` → `zk_propose_links_semantic` where the plan means the semantic proposer. Keep the singular form only where the plan refers to the manual-proposal path (it doesn't, currently).

### W5. Four post-rewrite stale references still cite MiniLM / threshold / FDO calibration

Level-2 rewrite removed MiniLM and similarity thresholds, but these dangling references remain:

1. **§9 option B:** "Run MiniLM pairwise over the existing 310 cards, emit reinforces edges above threshold." Should be reframed as "Run `proposeLinksSemantic` retroactively against the 310-card corpus, candidate set per hub."
2. **Acceptance criterion #3:** "Gate B with FDO-calibrated threshold proposes ≥5 reinforces edges." The FDO-calibrated threshold doesn't exist anymore; rewrite to "Gate B proposes ≥5 edges above confidence floor 0.7 across the full playlist."
3. **Risk register item 3:** "Gate B threshold mis-calibration" — stale. Replace with "Gate B candidate-enumeration under-recall: hubs whose cards share <2 keyword terms will produce empty candidate sets — monitor via telemetry item 5."
4. **Risk register item 6:** "MiniLM vocabulary mismatch" — drop entirely; no MiniLM anymore.
5. **Open question #3:** "`threshold.json` location" — §10 already declared it eliminated; remove this open question.

### W6. `zk_recall` limit parameter (Step 6.5) is under-specified

Plan promotes Step 6.5 ("per-term limit on entry points") to a hard dependency because "terms with 100+ entry points" break usability. Good call. BUT:

- The limit needs to be per-TERM (not per-response), so that a multi-term query doesn't starve low-density terms.
- It needs a recency tiebreaker (latest N? or highest reinforces-count N?). The plan doesn't pick.
- It needs to surface "truncated: true" in the response so callers know they're seeing a subset.

**Fix:** §6.5 needs a sub-spec: `{ limitPerTerm: number (default 20), sortBy: 'recency' | 'reinforces-density' (default 'reinforces-density'), truncatedIndicator: true }`.

---

## Well-Defined (No Action Needed)

- ✅ **Plan §8 "same claim, different context"** — excellent invariant statement; crystal-clear anti-patterns list; cross-references r04 correctly.
- ✅ **AddKeywordResult type shape** — plan's four-variant claim matches `keyword-index.ts:74-78` exactly.
- ✅ **REVIEWED_EDGE_TYPES enum** — all five types (`reinforces, refines, extends, supports, contradicts`) supported via label encoding today (`labels.ts:79-95`, `edges.ts:326-357`). The stale memory entry `feedback_zettel_link_reinforces_rejected.md` should be updated post-implementation, but it does NOT block this plan.
- ✅ **MAX_ENTRY_POINTS = 4 + FIFO eviction** — plan's 7h6 prerequisite correctly identifies both.
- ✅ **Data flow diagram** — matches actual per-transcript artifact production.
- ✅ **Step 4b A/B methodology** — rigorous, auditable, records the losing model.
- ✅ **§11 telemetry framework** — signals are well-chosen; just needs the L4-vs-Gate-B split (see C1).
- ✅ **V1 pipeline coexistence strategy** — keeping `scripts/kc-baker-pipeline/` for regression is the right call.

---

## Suggested Plan Amendments

```diff
# §5 — add to Gate B description
+ **Pre-sort + cap before calling proposeLinksSemantic:** graph-candidates.ts MUST
+ sort candidates by (shared-keyword-count DESC, hub-distance, lineOfThought-proximity)
+ and cap to MAX_CANDIDATES_IN_PROMPT (20) before invocation. Otherwise Sonnet sees
+ an arbitrary subset and typed-edge quality degrades.

# §6-bis — rewrite steps 2-3
- 2. Tier A deterministic edges written inside saveCard (synchronously,
-    before brCreate returns): follows, branches, derives-from,
-    refers-to, annotates — computed from folgezettel + body mentions
-      ↓
- 3. saveCard → brCreate commits the card + its Tier A labels atomically
+ 2. brCreate commits the card with content_hash + initial metadata labels
+      ↓
+ 3. runExtractors writes Tier A ref:* labels (follows, branches,
+    derives-from, refers-to — NOT annotates; see W3) onto the committed
+    bead. Synchronous within saveCard; atomic w.r.t. brCreate NO.

# §6-bis — add a new paragraph after "If Gate B fails"
+ **L4 auto-fire resolution (see review C1):** r04 MUST remove the
+ `proposeLinksSemanticSync` auto-invocation currently at card-ops.ts:773-806.
+ L4 becomes a pure anchor check ("card has ≥1 ref:* edge?") without auto-
+ commit side effect. The cascade's Gate B is the single Sonnet-classified
+ edge source. This is a pre-requirement of r04, not a follow-up.

# §0 prerequisite r04 row
- (c) rewrite of 62+ `saveCard` callsites in `integration.test.ts` + sibling
-     test files that assert `wasDeduped===true`;
+ (c) rewrite of 6 test assertions on `wasDeduped` across integration.test.ts
+     (3), biblio.ts tests (1), migrate-from-cosmic.ts (2); plus 2 external
+     consumers of SaveCardResult.wasDeduped (biblio.ts, migrate-from-cosmic.ts);
- ~6-8 hours (Deep effort Algorithm run)
+ ~4-5 hours (Advanced; includes sweepDuplicates concurrent redesign + L4
+  auto-fire removal)

# Prerequisite ordering — insert Step 5.5
+ | 5.5 | **New keyword-index primitives** — `hubMembers(hubId)` +
+   `filterByKeywordOverlap(sourceCardId, minOverlap)` — both currently
+   missing despite plan §5 treating them as existing. +~1.5 hrs; ships in
+   `apps/silmari-mcp/src/lib/keyword-index.ts` as reusable primitives. | ~1.5 hours |

# §9 option B — rewrite
- **B — One-shot retroactive Gate B pass.** Run MiniLM pairwise over
-   the existing 310 cards, emit reinforces edges above threshold.
+ **B — One-shot retroactive Gate B pass.** For each of the 310 existing
+   cards, enumerate candidates via the new graph-candidates logic
+   (keyword ≥2 + lineOfThought + hub-membership) and call
+   `proposeLinksSemantic({ scope: 'explicit', candidateCardIds })`.
+   Commit returned edges above confidence floor 0.7. Idempotent — skip
+   pairs that already have any ref:* edge between them.

# Acceptance criteria #3
- Gate B with FDO-calibrated threshold proposes ≥5 reinforces edges
-  across the full playlist
+ Gate B proposes ≥5 typed edges (any of the 5 REVIEWED types) above
+  confidence floor 0.7 across the full playlist

# Risk register
- 3. **Gate B threshold mis-calibration.** [...MiniLM-era language...]
- 6. **MiniLM vocabulary mismatch.** [...]
+ 3. **Gate B candidate under-recall.** Hubs whose cards share <2 keyword
+    terms produce empty candidate sets. Mitigation: telemetry item 5
+    watches for 0-candidate tail; if >20% of cards land there, lower the
+    minOverlap threshold or broaden keyword extraction in Pass 2/3.
  (delete item 6)

# Open questions
  (delete #3 about threshold.json — already resolved in §10)
+ **New open question:** L4 auto-fire removal as part of r04 — confirm
+ this is the right blast radius, or should the removal be its own issue?
```

---

## Beads Tracking

Creating a tracking issue for these plan findings so implementation doesn't drift:

```
bd create \
  --title="Plan Review findings: 2026-04-22 cascade extractor TDD plan" \
  --type=task \
  --priority=1 \
  --description="4 critical + 6 warnings from pre-implementation review. See
    thoughts/searchable/shared/plans/2026-04-22-tdd-silmari-cascade-extractor-REVIEW.md.
    Blocks r04 and 7h6 TDD plan drafting — both r04 and the cascade plan
    need revision before implementation begins."
```

Once the plan is revised, close this issue with a link to the amended plan file. Do NOT begin r04 or 7h6 TDD plans until §6-bis is corrected (C2) and L4 auto-fire resolution (C1) is decided.

---

## Approval Status

- [ ] Ready for Implementation
- [ ] Needs Minor Revision
- [x] **Needs Major Revision** — four critical issues block implementation; three stale sections need rewrite

**Next step:** Apply the diff patches above, then re-request review. Bulk of the rewrite is mechanical (W5 stale refs, W2 scope recalibration, W4 tool-name find/replace); the non-mechanical calls are C1 (pick fix option a/b/c) and C4 (pick a/b for lineOfThought depth).
