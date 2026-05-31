# Plan Review: Strip Graph-Metric Surfaces from Detail Panel + Tooltip

**Reviewing**: `thoughts/searchable/shared/plans/2026-04-19-tdd-strip-detail-panel-and-tooltip-metrics.md`
**Reviewer**: Claude (automated pre-implementation review, 2026-04-19)
**Plan type**: Pure deletion; ~53 LOC claimed, 0 added
**Epic**: `silmari-agent-memory-xom` · **Task**: `silmari-agent-memory-5tu`

## Summary

| Category | Status | Issues |
|---|---|---|
| Contracts | ✅ | 0 — single promise ("WASM plumbing + cycle warning both preserved") intended, but cycle-warning preservation is **broken** by the current deletion range — see C1 |
| Interfaces | ✅ | 0 |
| Promises | ❌ | **1 critical** (C1 — cycle warning would be destroyed, not preserved, by the plan as written) |
| Data Models | ✅ | 0 |
| APIs | N/A | No external APIs |
| **Scope precision** | ⚠️ | 2 nits (W1-W2) |

**Verdict**: **NOT ready for implementation.** One critical structural issue requires a plan amendment. The rest is clean.

---

## Spot-check verification of plan's claims

| Plan claim | Verified against source | Status |
|---|---|---|
| `formatSlack` at graph.js:2834 | `grep` confirms line 2834 | ✅ |
| `safeMetric` at graph.js:2843 | Confirmed | ✅ |
| `extendedMetrics` array at graph.js:2849 | Confirmed | ✅ |
| Tooltip PageRank line at graph.js:2892 | Confirmed | ✅ |
| `extendedMetrics.join('')` at graph.js:2894 | Confirmed | ✅ |
| index.html detail panel block "3156-3168" + preserve "3169-3171" | **Structurally wrong** — cycle warning at 3169-3171 is NESTED INSIDE the outer div that starts at 3157 and closes at 3172, not a sibling | ❌ see C1 |
| No other consumers of `formatSlack`/`safeMetric`/`extendedMetrics` | `grep --files-with-matches` returns only graph.js | ✅ |
| `node.inCycle` plumbing preserved | Populated at graph.js:1060; consumed at 1102, 1180, 1220, 1308 + index.html:3169 — all outside the scope of this commit | ✅ |

---

## Critical Issues (Must Address Before Implementation)

### ❌ C1 — The cycle warning is NESTED inside the Graph Metrics block, not a sibling. Deleting lines 3156-3168 will destroy it and produce invalid HTML.

**Plan says**: "Delete lines 3156-3168 (Graph Metrics grid); preserve 3169-3171 (cycle warning)"

**Reality** — actual DOM structure at `index.html:3156-3172`:

```html
3156    <!-- Graph Metrics -->
3157    <div x-show="graphDetailNode?.pagerank || graphDetailNode?.betweenness" class="mb-5">
3158      <span>Graph Metrics</span>
3159      <div class="grid grid-cols-2 gap-2">
3160–3163   [PageRank card]
3164–3167   [Betweenness card]
3168      </div>
3169      <div x-show="graphDetailNode?.inCycle" ...>           ← cycle warning
3170        ⚠️ Part of dependency cycle
3171      </div>
3172    </div>                                                    ← outer closer
```

Problems if deleted as-written:
1. **HTML invalidated**: deleting 3156-3168 leaves 3169-3172 orphaned — `<div x-show="...inCycle">` + closing `</div>` with no matching parent. Page would render broken DOM.
2. **Cycle warning loses its trigger condition**: the outer `x-show="graphDetailNode?.pagerank || graphDetailNode?.betweenness"` is what currently gates the *entire* nested region. The cycle warning only appears when pagerank or betweenness is populated (which is effectively always, once WASM runs). Once PageRank/Betweenness disappear as *concepts*, that outer condition is meaningless.
3. **Semantic mismatch**: the cycle warning is conceptually a card-status indicator, not a "graph metric." Nesting it under "Graph Metrics" was a structural shortcut; stripping metrics is the right time to also promote the cycle warning to a sibling block.

**Required fix**: rewrite the deletion as a **structured replacement**, not a line-range delete. The outer wrapper's `x-show` condition must change AND the inner PageRank/Betweenness content must be removed AND the "Graph Metrics" label must be removed, while the cycle warning is preserved inside or promoted out.

**Recommended approach**: promote the cycle warning to a sibling block. Replace the entire 3156-3172 range with:

```html
          <!-- Cycle warning -->
          <div x-show="graphDetailNode?.inCycle" class="mb-5 bg-orange-50 dark:bg-orange-900/20 rounded-lg p-2.5 border border-orange-100 dark:border-orange-800/30">
            <span class="text-sm text-orange-700 dark:text-orange-300 font-medium">⚠️ Part of dependency cycle</span>
          </div>
```

This:
- Removes the `<!-- Graph Metrics -->` comment, outer wrapper, header label, PageRank card, Betweenness card, grid wrapper
- Promotes the cycle warning to sibling level (same level as Labels block at 3147-3154 and Markdown Content at 3174)
- Keeps `class="mb-5"` for vertical spacing consistency with adjacent blocks
- Keeps the exact same `x-show="graphDetailNode?.inCycle"` gate and the same color classes
- Preserves the text "Part of dependency cycle" verbatim (SPA-12 Transform handles the *reframing* in a later commit)

Net LOC: delete 17 (3156-3172), add 4 = net -13. Matches original LOC estimate.

**Impact if unfixed**: invalid HTML, broken cycle warning, probable browser console errors on card select.

---

## Warnings (non-blocking but worth addressing)

### ⚠️ W1 — Phase 1 "TDD cycle" language doesn't match the actual change

Plan's Phase 1 describes a pure deletion ("Delete the 13-line … block entirely"). After C1, it becomes a **delete-and-replace** — which is a structured transform, not a simple deletion. Update Phase 1's Red/Green/Refactor to reflect that the final state has a single sibling `<div x-show="graphDetailNode?.inCycle">` block, not just a removal.

**Recommendation**: rewrite Phase 1's TDD cycle using a `structured replacement` framing. Red: grep confirms `"Graph Metrics"` exists. Green: replace 3156-3172 block with the 4-line cycle-warning sibling above. Refactor: verify Labels block at 3147-3154 and Markdown Content at 3174 still bracket the new cycle warning correctly.

### ⚠️ W2 — Plan's tooltip LOC estimate is slightly off

Plan says "Phase 2 = 2 lines, Phase 3 = ~38 lines" for graph.js. Actual counts:

| Phase 3 delete target | Lines | Count |
|---|---|---|
| `formatSlack` helper | 2833-2840 | 8 |
| `safeMetric` helper | 2842-2846 | 5 |
| `extendedMetrics` array + 5 push blocks | 2848-2867 | 20 |
| **Phase 3 subtotal** | — | **33** |
| Phase 2 (PageRank + join lines) | 2892, 2894 | 2 |
| **graph.js total** | — | **35** (not ~40) |

Combined with the corrected index.html LOC (13 delete + 4 add = -9 net), total commit LOC budget is ~-48 / +4 = **-44 net**. Plan claimed -53 net. Small discrepancy — update the table in the LOC Budget section.

**Recommendation**: update Rough LOC Budget table to:

| File | Delete | Add |
|---|---|---|
| `index.html` | 17 | 4 |
| `graph.js` | 35 | 0 |
| **Total** | **52** | **4** (net -48) |

---

## No-issue sections (brief)

### Contracts ✅
The single contract — "WASM plumbing remains callable and populating node.pagerank/betweenness/slack/criticalDepth/etc." — is preserved. Verified no consumers of `formatSlack` / `safeMetric` / `extendedMetrics` outside the tooltip block being deleted.

### Interfaces ✅
No public interface changes. Deleted identifiers are all local-scope (const within `showTooltip(node)` function body) or DOM elements.

### Promises ✅ (once C1 is fixed)
Post-fix behavioral guarantees are clear:
- Detail panel: cycle warning fires when `inCycle` (unchanged semantics, just moved structurally)
- Tooltip: shows title/status/ZK context/Blockers/Dependents/Depth (unchanged)
- WASM: still computes every metric on every load

### Data Models ✅
`graphDetailNode` shape unchanged — this commit only removes *consumers* of its `.pagerank`/`.betweenness` fields, not the fields themselves.

### APIs ✅ (N/A)
No external APIs touched.

---

## Suggested Plan Amendments

```diff
# Section: Exact locations to delete → `index.html`
-- Lines **3156-3168** — the `<div x-show="graphDetailNode?.pagerank || graphDetailNode?.betweenness">` block containing the "Graph Metrics" header, PageRank card (3160-3163), and Betweenness card (3164-3167)
-- **Preserve lines 3169-3171** — the `<div x-show="graphDetailNode?.inCycle">` cycle-warning block. Cycles are SPA-12 Transform (reframe as "debate loop"), not this commit.

++ Lines **3156-3172** — replace the entire outer `<div x-show="graphDetailNode?.pagerank || graphDetailNode?.betweenness">` block (which transitively contains the Graph Metrics header, PageRank card, Betweenness card, grid wrapper, AND the nested cycle warning at 3169-3171) with a single sibling `<div x-show="graphDetailNode?.inCycle">` block that preserves the cycle warning at the same level as the Labels block above and the Markdown Content block below.

++ **Reason for structural replacement (not simple deletion)**: the cycle warning at 3169-3171 is NESTED INSIDE the outer metrics wrapper, not a sibling. A line-range delete of 3156-3168 would orphan the cycle warning and break HTML structure. This is the minimum correct unit of change.

# Section: Phase 1 — TDD cycle
~ Rewrite Red/Green/Refactor to reflect a structured replacement:
~   Red: `grep -n 'Graph Metrics\|graphDetailNode?.pagerank\|graphDetailNode?.betweenness' index.html` → multiple matches AND `grep -n 'Part of dependency cycle' index.html` → 1 match (inside the wrapper)
~   Green: delete 3156-3172, insert replacement block with cycle warning at sibling level
~   Refactor: verify (a) grep for metrics strings → zero, (b) grep for cycle-warning text → still 1 match, (c) new block has `class="mb-5"` and `x-show="graphDetailNode?.inCycle"` gate

# Section: Rough LOC Budget
~ Update table: index.html 17 delete + 4 add; graph.js 35 delete; total 52 delete + 4 add (net -48)
```

---

## Approval Status

- [ ] Ready for Implementation
- [ ] **Needs Minor Revision**
- [x] **Needs Major Revision** — C1 is a structural HTML correctness issue that will produce broken DOM if implemented as written. Apply the amendments above before executing.

## Tracking

No new bd issue created — findings are plan-amendment scope, handled inline. Task `silmari-agent-memory-5tu` remains open pending the plan revision.
