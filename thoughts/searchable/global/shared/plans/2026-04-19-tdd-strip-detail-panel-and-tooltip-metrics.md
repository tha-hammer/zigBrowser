# Strip Graph-Metric Surfaces from Detail Panel + Node Tooltip — TDD Implementation Plan

**Date**: 2026-04-19 · **Branch**: main · **Second strip commit under the Viewer Fork-and-Strip mandate**

## Overview

Delete the **PageRank/Betweenness/K-core/HITS/Eigenvector/Slack** displays from two user-facing surfaces:
1. The Card Detail Panel's "Graph Metrics" grid (right portal)
2. The Node Tooltip's metrics section (hover overlay)

This is the semantic continuation of the heatmap strip (`silmari-agent-memory-9al`, closed 2026-04-19): eliminate issue-tracker graph metrics from the user's view while keeping the WASM plumbing latent.

**Scope**: mostly deletion + one small structural promotion (the cycle warning, currently nested inside the Graph Metrics wrapper, gets promoted to a sibling block). Net ~52 LOC deleted / 4 LOC added. WASM engine continues computing; nothing surfaces the metrics.

**Inventory trace**: SPA-9 (Card detail panel — Transform scope: "drop the PageRank/betweenness metrics grid") + implicit sub-scope of SPA-8 (Graph view Transform — the tooltip's `extendedMetrics` block is a user-facing metric surface that lives within the graph-view code). If the inventory wants an explicit tooltip-metrics row, that's a one-line amendment after this lands.

## Current State Analysis

### Files touched (2)

| File | Role |
|---|---|
| `apps/silmari-memory-card-viewer/viewer_assets/index.html` | DOM: Card Detail Panel's "Graph Metrics" grid (PageRank + Betweenness cards) |
| `apps/silmari-memory-card-viewer/viewer_assets/graph.js` | Node tooltip's `extendedMetrics` builder + PageRank line + orphan helpers `formatSlack` / `safeMetric` |

### Exact locations to delete

**`index.html`** — Card Detail Panel "Graph Metrics" block — **STRUCTURED REPLACEMENT, not a line-range delete**:
- Lines **3156-3172** — the outer `<div x-show="graphDetailNode?.pagerank || graphDetailNode?.betweenness">` wrapper (opens at 3157, closes at 3172) transitively contains:
  - the `<!-- Graph Metrics -->` comment at 3156
  - the "Graph Metrics" header label at 3158
  - the 2-column grid wrapper at 3159 + 3168
  - the PageRank card at 3160-3163
  - the Betweenness card at 3164-3167
  - **the NESTED cycle warning at 3169-3171**
  - the outer closing `</div>` at 3172
- A simple line-range delete of 3156-3168 would orphan the cycle warning and produce broken HTML. Instead, **replace the entire 3156-3172 range** with a single 4-line sibling cycle-warning block:
  ```html
          <!-- Cycle warning -->
          <div x-show="graphDetailNode?.inCycle" class="mb-5 bg-orange-50 dark:bg-orange-900/20 rounded-lg p-2.5 border border-orange-100 dark:border-orange-800/30">
            <span class="text-sm text-orange-700 dark:text-orange-300 font-medium">⚠️ Part of dependency cycle</span>
          </div>
  ```
  - Preserves the `x-show="graphDetailNode?.inCycle"` gate verbatim
  - Preserves all color classes verbatim
  - Preserves "⚠️ Part of dependency cycle" text verbatim (SPA-12 Transform reframes this in a later commit, not here)
  - Promotes the cycle warning to sibling level of the Labels block (3146-3154) and the Markdown Content block (currently 3174, shifts upward post-replacement)
- Do NOT touch the Labels block at 3146-3154 or the Markdown Content block starting at 3174.

**`graph.js`** — Node tooltip metrics block:
- **Line 2892** — `<span>PageRank: ${safeMetric(node.pagerank …)}</span>` tooltip line
- **Line 2894** — `${extendedMetrics.join('')}` interpolation
- **Lines 2849-2867** — the `const extendedMetrics = [];` array build and its five push blocks (betweenness / kcore / HITS / eigenvector / slack)
- **Lines 2833-2840** — `const formatSlack = …` helper (becomes orphaned; only used by the slack push block)
- **Lines 2842-2846** — `const safeMetric = …` helper (becomes orphaned; only used by deleted PageRank + Between + HITS + Eigen)

### Consumers that stay intact (latent plumbing)

- `buildWasmGraph()` + `computeMetrics()` + `store.wasmGraph.*` — WASM engine computes pagerank / betweenness / slack / k-core / HITS / eigenvector / articulation / cycles / critical-path on every load. Untouched.
- `store.metrics.*` arrays — populated, unread post-strip, kept as latent plumbing per mandate.
- `node.pagerank` / `node.betweenness` / `node.slack` / `node.criticalDepth` / etc. — still assigned onto node objects during `prepareGraphData`. Just not displayed.
- Tooltip's non-metric content (title / status / ZK context / kind badge / folgezettel badge / trunk badge / Blockers count / Dependents count / Depth line) — NOT touched by this commit. See "What We're NOT Doing" for the `Blockers`/`Dependents`/`Depth` follow-up note.
- Detail panel's **cycle warning** at index.html:3169-3171 — preserved; reframing is SPA-12 Transform scope, not this commit.
- `graph-helpers.js` — no changes.

### Key existing test patterns
- Test framework: `bun:test`
- Test files: `graph-helpers.test.js`, `viewmodel.test.js`, `vocab.test.js`, `link-builder.test.js`, `hybrid_scorer.test.js`
- No tests exercise the tooltip or detail panel directly (DOM/Alpine code is uncovered)
- Regression signal: `bun test` pass count must stay at 87 (unchanged from post-heatmap-strip baseline)

## Desired End State

### Observable behaviors after this commit

1. The Card Detail Panel shows no "Graph Metrics" header, no PageRank card, no Betweenness card — regardless of whether `graphDetailNode.pagerank` or `graphDetailNode.betweenness` is populated.
2. The cycle warning ("⚠️ Part of dependency cycle") still appears in the detail panel when `graphDetailNode?.inCycle` is truthy.
3. The node tooltip shows the card's title, status, ZK context (kind/trunk/folgezettel badges), id, and the **Blockers / Dependents / Depth** lines (unchanged this commit). The **PageRank / Between / K-core / HITS / Eigen / Slack** lines are gone.
4. `store.metrics` still populated; browser console inspection confirms pagerank/betweenness/slack arrays exist post-load.
5. `bun test` returns 87/87 green (unchanged).
6. `bun build graph.js` + `bun build viewer.js` parse cleanly.
7. `grep -n 'formatSlack\|safeMetric\|extendedMetrics' graph.js` returns zero.
8. `grep -n 'Graph Metrics\|graphDetailNode?.pagerank\|graphDetailNode?.betweenness' index.html` returns zero.

## What We're NOT Doing

- **Blockers / Dependents / Depth tooltip lines** (`graph.js:2890-2891, 2893`) — issue-tracker vocabulary but separately scoped in a later **tooltip vocabulary transform** commit. Leaving them alone here keeps the strip narrow. They'll rename/delete when the SPA-8 graph-view transform happens in full.
- **Cycle warning in detail panel** (`index.html:3169-3171`) — SPA-12 Transform scope, later commit.
- **Any `store.metrics.*` or `store.wasmGraph.*` deletion** — plumbing stays per mandate.
- **TUI-side metrics displays** (Bubble Tea model views) — TUI strip is a separate Go-side commit sequence.
- **`graph-helpers.js`** — no metrics logic lives there.
- **`vocab.js`** — no metric strings live in vocab.js.
- **Any rename or repurpose** — pure delete, no transform in this commit.

## Testing Strategy

Same pattern as the heatmap strip — proportionate to the scope, not speculative:

- **Grep-assertion tests (automated)** — scripted verification that `formatSlack` / `safeMetric` / `extendedMetrics` / "Graph Metrics" / `graphDetailNode?.pagerank` / `graphDetailNode?.betweenness` are absent from the post-strip files.
- **Existing unit tests (regression)** — `bun test apps/silmari-memory-card-viewer/viewer_assets/` must return 87/87 green.
- **Parse check** — `bun build graph.js --target=browser` and `bun build viewer.js --target=browser` succeed.
- **Manual browser smoke** — load `http://localhost:8788`, verify the detail panel shows no Graph Metrics section (cycle warning still works), verify hover tooltip shows no PageRank/Between/K-core/HITS/Eigen/Slack lines, zero console errors.

No new test framework added. No new tests written.

## Phase Plan

### Phase 1 — `index.html` detail panel: structured replacement (Graph Metrics wrapper → sibling cycle-warning block)

**Action**: replace the 17-line outer metrics wrapper (3156-3172) — which transitively contains the nested cycle warning — with a 4-line sibling cycle-warning block. This is a **structured replacement, not a pure deletion**: the cycle warning at 3169-3171 is nested inside the wrapper and must be extracted as a sibling to preserve it.

**TDD cycle**:

#### 🔴 Red
Two preconditions:
```bash
# Precondition 1: metrics identifiers present
grep -n 'Graph Metrics\|graphDetailNode?.pagerank\|graphDetailNode?.betweenness' \
    apps/silmari-memory-card-viewer/viewer_assets/index.html
# → expects: multiple matches in the 3156-3167 range

# Precondition 2: cycle warning currently exists, nested inside the metrics wrapper
grep -n 'Part of dependency cycle' \
    apps/silmari-memory-card-viewer/viewer_assets/index.html
# → expects: exactly 1 match at line 3170
```

#### 🟢 Green
Replace the entire 3156-3172 range with the sibling cycle-warning block:
```html
          <!-- Cycle warning -->
          <div x-show="graphDetailNode?.inCycle" class="mb-5 bg-orange-50 dark:bg-orange-900/20 rounded-lg p-2.5 border border-orange-100 dark:border-orange-800/30">
            <span class="text-sm text-orange-700 dark:text-orange-300 font-medium">⚠️ Part of dependency cycle</span>
          </div>
```

Post-replacement, the new block sits between the Labels block (closes at 3154) and the Markdown Content block (begins at what was 3174, now shifts upward).

#### 🔵 Refactor
Verify HTML structure remains valid:
- Labels block at 3146-3154 still closes with its own `</div>` — untouched
- New cycle-warning block has matching open/close, no leftover orphan tags
- Markdown Content block (was `<!-- Markdown Content -->` at 3174) still opens as expected at its new line number
- No stray `</div>` at the old line 3172 position
- No Alpine binding errors on page load (no leftover references to `graphDetailNode?.pagerank` or `.betweenness`)

**Success criteria**:
- [x] `grep -n 'Graph Metrics\|graphDetailNode?.pagerank\|graphDetailNode?.betweenness' index.html` returns zero
- [x] `grep -n 'Part of dependency cycle' index.html` returns exactly 1 match (now at sibling level, not nested)
- [x] `grep -n 'x-show="graphDetailNode?.inCycle"' index.html` returns exactly 1 match
- [x] HTML structure remains valid (no orphan `</div>` tags, no unbalanced brackets)
- [ ] (manual) Browser renders card detail panel without the "Graph Metrics" section; cycle warning still appears when `graphDetailNode.inCycle` is truthy

### Phase 2 — `graph.js` tooltip: PageRank + extendedMetrics interpolation

**Delete**:
- Line 2892 — `<span>PageRank: ${safeMetric(…)}</span>` (keep the `Blockers/Dependents/Depth` siblings at 2890-2893)
- Line 2894 — `${extendedMetrics.join('')}`

**TDD cycle**:

#### 🔴 Red
```bash
grep -n 'PageRank: \${safeMetric\|extendedMetrics.join' \
    apps/silmari-memory-card-viewer/viewer_assets/graph.js
```

#### 🟢 Green
Remove those two lines from the template literal. The result: tooltip grid still shows Blockers / Dependents / Depth — no PageRank, no extended block.

#### 🔵 Refactor
Verify the tooltip innerHTML template literal still parses (matching backticks, no stray `${` without closer).

**Success criteria**:
- [x] `grep -n 'PageRank: \${' graph.js` returns zero
- [x] `grep -n 'extendedMetrics' graph.js` returns matches ONLY in the array-build block at 2849-2867 (to be deleted in Phase 3)

### Phase 3 — `graph.js` tooltip: delete orphan helpers + extendedMetrics build

**Delete**:
- Lines 2833-2840 — `const formatSlack = (slack) => { … };`
- Lines 2842-2846 — `const safeMetric = (val, decimals, suffix) => { … };`
- Lines 2849-2867 — `const extendedMetrics = [];` + five push blocks

All three are orphaned after Phase 2 (their only callers were deleted).

**TDD cycle**:

#### 🔴 Red
```bash
grep -nE 'formatSlack|safeMetric|extendedMetrics' \
    apps/silmari-memory-card-viewer/viewer_assets/graph.js
```

#### 🟢 Green
Delete the three helper/build blocks.

#### 🔵 Refactor
Verify the `showTooltip(node)` function body still assembles cleanly — remaining variables used in the template literal (`icon`, `statusColor`, `priorityColor`, `kindLabel`, `kindColor`, `fzBadge`, `trunkBadge`) are not affected.

**Success criteria**:
- [x] Grep above returns zero matches across the whole viewer_assets/ tree
- [x] `bun build graph.js --target=browser --outfile=/tmp/check.js` succeeds
- [x] `bun test apps/silmari-memory-card-viewer/viewer_assets/` returns 87/87 green

### Phase 4 — Verify

**Automated**:
- `grep -n 'Graph Metrics\|graphDetailNode?.pagerank\|graphDetailNode?.betweenness' index.html` → zero
- `grep -n 'formatSlack\|safeMetric\|extendedMetrics' graph.js` → zero
- `grep -n 'PageRank: \${' graph.js` → zero
- `bun test apps/silmari-memory-card-viewer/viewer_assets/` → 87/87
- `bun build graph.js --target=browser` → clean parse
- `bun build viewer.js --target=browser` → clean parse
- `grep -n 'store\.wasmGraph\|store\.metrics' graph.js` → still present (plumbing intact)
- `grep -n 'Part of dependency cycle' index.html` → still present (cycle warning preserved)

**Manual browser smoke**:
- `bun server.ts` starts cleanly
- `http://localhost:8788` loads without console errors
- Click a graph node → detail panel opens with: title, status, labels, NO "Graph Metrics" section, cycle warning if applicable, description, typed-edge list
- Hover a graph node → tooltip shows title + status + ZK context + Blockers/Dependents/Depth; NO PageRank / Between / K-core / HITS / Eigen / Slack lines
- Browser console: `store.metrics` still populated (inspect via dev tools) — WASM engine ran
- `/api/health` → `lastSynthCount > 0` (unrelated edge synthesis still works)

## Rough LOC Budget

Updated 2026-04-19 after review amendments (C1: structured replacement instead of line-range delete; W2: precise counts).

| File | Expected delete | Expected add |
|---|---|---|
| `index.html` | 17 LOC (3156-3172 outer metrics wrapper + all nested contents) | 4 LOC (sibling cycle-warning block replacement) |
| `graph.js` | 35 LOC (Phase 2: 2 template-literal lines; Phase 3: 8 formatSlack + 5 safeMetric + 20 extendedMetrics build) | 0 |
| **Total** | **52 LOC deleted** | **4 LOC added** (net **-48 LOC**) |

## Success Criteria — Commit-Ready Checklist

**Automated (run before committing):**
- [x] All Phase 1-3 grep-assertion tests pass (zero matches on deleted identifiers)
- [x] `bun test apps/silmari-memory-card-viewer/viewer_assets/` passes (87/87)
- [x] `bun build` on both graph.js and viewer.js parse cleanly
- [x] Plumbing-retention greps (`store.wasmGraph`, `store.metrics`, cycle warning) still return expected matches

**Manual (Phase 4 smoke):**
- [ ] `bun server.ts` starts cleanly
- [ ] Browser loads, graph renders, interactions work
- [ ] Detail panel shows no "Graph Metrics" section; cycle warning still works when applicable
- [ ] Tooltip shows no PageRank/Between/K-core/HITS/Eigen/Slack lines; Blockers/Dependents/Depth/title/ZK-context still shown
- [ ] No console errors
- [ ] `store.metrics` populated (WASM plumbing intact)

## References

- Inventory (source of truth for verdicts): `thoughts/searchable/shared/research/2026-04-19-viewer-fork-and-strip-inventory.md` — rows SPA-9 (Card detail panel Transform) and SPA-8 (Graph view Transform, implicit sub-scope)
- Mandate: `~/.claude/projects/-home-maceo-Dev-silmari-agent-memory/memory/project_viewer_fork_and_strip_mandate.md`
- Epic: `silmari-agent-memory-xom` — Viewer fork-and-strip toward Zettelkasten-native
- Prior strip (closed): `silmari-agent-memory-9al` — heatmap toggle — shipped 2026-04-19, 240 LOC deleted, 87/87 tests pass
- Prior strip plan (for pattern reference): `thoughts/searchable/shared/plans/2026-04-19-tdd-strip-graph-heatmap-from-spa.md`
- **Review**: `thoughts/searchable/shared/plans/2026-04-19-tdd-strip-detail-panel-and-tooltip-metrics-REVIEW.md` — C1 critical + W1/W2 warnings, all addressed; amendments applied directly into this plan on 2026-04-19

## Revision History

- **2026-04-19 initial** — TDD plan drafted covering 2 files, 4 phases, claimed ~53 LOC net delete.
- **2026-04-19 amended** — Applied all 3 review findings:
  - **C1 (critical)**: rewrote Phase 1 target as structured replacement of index.html:3156-3172 (not line-range delete of 3156-3168). Reason: cycle warning at 3169-3171 is nested inside the metrics wrapper, not a sibling — pure deletion would orphan it and produce broken HTML.
  - **W1**: rewrote Phase 1 TDD cycle to reflect structured replacement (two preconditions in Red; sibling-block insertion in Green; structural validity checks in Refactor; 5 success criteria).
  - **W2**: corrected Rough LOC Budget to 52 delete / 4 add (net -48), replacing the imprecise "~53 delete / 0 add".

End of plan.
