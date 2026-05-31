# Strip Graph-Node Heatmap from SPA — TDD Implementation Plan

**Date**: 2026-04-19 · **Branch**: main · **First strip commit under the Viewer Fork-and-Strip mandate**

## Overview

Delete the **graph-node heatmap mode** from the SPA viewer (`apps/silmari-memory-card-viewer/viewer_assets/`). This is the first concrete commit in the fork-and-strip trajectory toward a Zettelkasten-native viewer. The feature colors force-graph nodes and links by PageRank / betweenness / critical-depth / in-degree — all workflow metrics with no Zettelkasten analog.

**Scope**: deletion only. No replacement. WASM engine and metric computation remain intact as latent infrastructure per mandate.

**Explicit disambiguation**: there is a *second* heatmap feature in this codebase — a "Label Dependency Heatmap" widget in `charts.js` + `index.html:1033-1043`. It is a different surface. **Not in scope for this commit**; it gets its own strip-commit later.

## Current State Analysis

### Files touched (3)

| File | Role |
|---|---|
| `apps/silmari-memory-card-viewer/viewer_assets/graph.js` | Force-graph canvas logic; owns `toggleHeatmap`, `setSizeMetric`, `getHeatmapState`, `getHeatmapColor` + heatmap branches in color/width functions |
| `apps/silmari-memory-card-viewer/viewer_assets/viewer.js` | Alpine root component; owns `graphHeatmapActive` state, `toggleGraphHeatmap()` action, `bv-graph:heatmapToggle` event listener |
| `apps/silmari-memory-card-viewer/viewer_assets/index.html` | DOM surface: heatmap toggle button, size-metric picker, legend variant, keyboard hint, help-text mentions |

### Exact locations to delete

**`graph.js`**:
- `getHeatmapColor(node)` — **line 372**, function body ~30 LOC
- `toggleHeatmap()` — **lines 443-451**
- `setSizeMetric()` — **lines 453-462**
- `getHeatmapState()` — **lines 464-472**
- Heatmap intensity branch in `getNodeColor()` — **lines 1195-1197**
- Heatmap slack-gradient block in `getLinkColor()` — **lines 1408-1437**
- Any heatmap-triggered branches in `getLinkWidth()` — **lines 1496-1514** (metric-based width scaling; verify coupling)
- `bv-graph:heatmapToggle` event dispatch from keyboard handler — **~line 928** area
- All remaining references to `store.heatmapMode` and `store.sizeMetric`

**`viewer.js`**:
- `graphHeatmapActive: false,` state — **line 2464**
- `graphSizeMetric: 'pagerank',` state — **line 2465** (follows `graphHeatmapActive` immediately)
- `bv-graph:heatmapToggle` event listener — **lines 2910-2912** (sets `graphHeatmapActive`)
- `metricChange` event listener — **lines ~2915-2918** (sets `this.graphSizeMetric = e.detail?.metric ?? 'pagerank'` at line 2917)
- `toggleGraphHeatmap()` method — **lines 3639-3647**
- `setGraphSizeMetric()` method — **line 3659** (size-metric setter wired to the `<select>` at `index.html:3276` via `@change="setGraphSizeMetric($event.target.value)"`)
- Any bindings/x-effect watchers depending on `graphHeatmapActive` or `graphSizeMetric`

**`index.html`**:
- Heatmap controls panel — **lines 3267-3291** (entire panel, contains):
  - Outer `<div class="bg-white/90 ...">` wrapper at 3267-3268 + closing 3291
  - "Heatmap" header label at 3269
  - Toggle button at 3271-3275 (calls `toggleGraphHeatmap()`)
  - **`<select x-model="graphSizeMetric" @change="setGraphSizeMetric(...)">` at 3276-3282** (4 options: PageRank / Betweenness / Key Thread / In-Degree)
  - **Green→red gradient bar + Low/High labels at 3284-3290**
- Legend variant branches — **lines 3299-3315** (ternary `graphHeatmapActive` controls legend content; `x-show="!graphHeatmapActive"` at 3301 and `x-show="graphHeatmapActive"` at 3310 — after deletion the card-kind legend becomes unconditional, strip the `x-show` wrapping)
- Keyboard hint — **line 3323** (`H` Heatmap kbd)
- "Heatmap" help-text mention — **line 4139**
- "Heatmap" help-text mention — **line 4298**

### Consumers that stay intact (latent plumbing)
- `buildWasmGraph()` and `computeMetrics()` in `graph.js` — still run on every load
- `store.metrics` object — still populated with pagerank/betweenness/etc.
- Detail-panel metrics grid in `index.html:3157-3168` — still displays PageRank/betweenness (separate strip-commit later)
- **`store.metrics.slack` / `node.slack` — RETAINED** (critical not to accidentally delete). Heatmap was one consumer of slack (`getLinkColor` at 1408-1437, `getLinkWidth` at 1498-1514); the **detail-panel slack display at `graph.js:2982-3015`** (`formatSlack` helper + colored "Slack: 3d" indicator) is the other consumer and stays. Do NOT delete `store.wasmGraph.slack()` at line 749, do NOT delete `store.metrics.slack` initialization at line 232, do NOT delete `formatSlack()` at 2983. Deletion of the detail-panel slack indicator is a separate commit under the detail-panel metrics-grid strip.

### Key existing test patterns
- Test framework: `bun:test` with `describe/it/expect`
- Test files: `graph-helpers.test.js`, `viewmodel.test.js`, `vocab.test.js`, `link-builder.test.js`, `hybrid_scorer.test.js`
- No existing DOM tests, no Alpine component tests, no browser E2E harness
- Tests are pure-function assertions — perfect for the `graph-helpers.js` layer, but most of `graph.js` / `viewer.js` / `index.html` is untested

## Desired End State

### Observable behaviors after this commit

1. The right-side graph panel does not show a "Heatmap" button, size-metric picker, or fire-emoji indicator.
2. Pressing the `H` key does nothing (unbound).
3. The legend shows only card-kind colors; no green→red gradient variant under any condition.
4. All nodes color by the default status/priority cascade; no PageRank-intensity gradient.
5. Links color by the existing edge-type fall-through; no slack-based red/orange/yellow/cyan gradient.
6. Graph still renders, all cards visible, force simulation runs, click/hover/drag/zoom all work.
7. Card detail panel's PageRank/betweenness metric grid still shows values (separate surface, not in this commit).
8. WASM still loads; `store.metrics` still populated on every graph init.
9. Zero browser-console errors related to `graphHeatmapActive`, `toggleHeatmap`, `bv-graph:heatmapToggle`, or `store.heatmapMode`.
10. Running `bun test` for viewer_assets passes.
11. `grep -i heatmap apps/silmari-memory-card-viewer/viewer_assets/graph.js` returns zero matches.
12. `grep -i heatmap apps/silmari-memory-card-viewer/viewer_assets/viewer.js` returns zero matches.
13. `grep -i heatmap apps/silmari-memory-card-viewer/viewer_assets/index.html` returns **only** matches for the Label Dependency Heatmap widget at `index.html:1033-1043` (explicit exclusion).

## What We're NOT Doing

- **Label Dependency Heatmap** (`charts.js` + `index.html:1033-1043`) — separate commit later
- **Detail-panel PageRank/betweenness metric grid** (`index.html:3157-3168`) — separate commit
- **Detail-panel slack indicator** (`graph.js:2982-3015`) — separate commit under the detail-panel metrics-grid strip. `store.metrics.slack` + `node.slack` are RETAINED by this commit.
- **What-if cascade / Shift+click** — separate commit
- **Critical-path keyboard highlight** — separate commit
- **Insights, Sprint, Triage, Board, Flow Matrix, Velocity, History, Attention views** — TUI-side, separate Go commits
- **WASM engine deletion** — never (plumbing stays per mandate)
- **`store.metrics` struct cleanup** — wait until all consumers are stripped; last-mover cleanup
- **Repurposing `H` keyboard binding** — leave unbound; future vocabulary commit can reassign
- **`vocab.js` changes** — no strings in vocab.js are heatmap-specific (the label lives inline in index.html). Note for later: `vocab.js:59 cardKeyThread: 'Key Thread'` is an issue-tracker-metric ("critical path") translation that will be audited during the Dashboard widgets transform commit (per 2026-04-19 epic inventory). NOT touched in this heatmap-strip commit.
- **`graph-helpers.js`** — no heatmap logic lives there; no changes

## Testing Strategy

**Framework**: `bun:test` for any unit-testable logic, plus **grep-assertion tests** (a bash script that verifies specific identifiers are absent) for deletion verification.

**Test types**:
- **Grep assertions (automated)** — scripted verification that `heatmap`/`toggleHeatmap`/`graphHeatmapActive` identifiers are gone from the 3 files (with the one documented exception for the Label Dependency Heatmap widget in `index.html:1033-1043`).
- **Existing unit tests (regression)** — `bun test apps/silmari-memory-card-viewer/viewer_assets/` must still pass.
- **Browser smoke test (manual)** — load `http://localhost:8788`, click around, verify no regressions.

No DOM-test framework is added for this commit. Adding one for a deletion is overkill; grep + manual smoke is proportionate.

## Behavior 1: Heatmap functions removed from graph.js

### Test Specification
**Given**: The checked-out `graph.js` after the commit
**When**: Searching for identifiers `toggleHeatmap`, `setSizeMetric`, `getHeatmapState`, `getHeatmapColor`
**Then**: Zero matches

**Edge cases**: None (pure deletion)

### TDD Cycle

#### 🔴 Red — grep-assertion test fails pre-deletion
```bash
# Run from repo root
! grep -nE 'function (toggleHeatmap|setSizeMetric|getHeatmapState|getHeatmapColor)' \
    apps/silmari-memory-card-viewer/viewer_assets/graph.js
```
Currently fails (functions exist at lines 372, 443, 453, 464).

#### 🟢 Green — delete the four function bodies
Remove:
- `getHeatmapColor()` (line 372 + body)
- `toggleHeatmap()` (lines 443-451)
- `setSizeMetric()` (lines 453-462)
- `getHeatmapState()` (lines 464-472)

#### 🔵 Refactor — remove call sites
After function deletion, grep for the now-dangling call sites:
```bash
grep -nE 'toggleHeatmap|setSizeMetric|getHeatmapState|getHeatmapColor' \
    apps/silmari-memory-card-viewer/viewer_assets/
```
Remove every match. Expected orphans: `getNodeColor`'s call to `getHeatmapColor`, `viewer.js`'s call to `toggleHeatmap`.

### Success Criteria
- [x] `grep -nE 'function (toggleHeatmap|setSizeMetric|getHeatmapState|getHeatmapColor)' graph.js` returns zero
- [x] `grep -nE '(toggleHeatmap|setSizeMetric|getHeatmapState|getHeatmapColor)\(' apps/silmari-memory-card-viewer/viewer_assets/` returns zero

## Behavior 2: Heatmap branches removed from getNodeColor + getLinkColor + getLinkWidth

### Test Specification
**Given**: `graph.js` after the commit
**When**: Inspecting `getNodeColor`, `getLinkColor`, `getLinkWidth` function bodies
**Then**: No reference to `store.heatmapMode`, `store.sizeMetric`, `heatmap`, or slack-gradient logic

### TDD Cycle

#### 🔴 Red
```bash
sed -n '1175,1227p' apps/silmari-memory-card-viewer/viewer_assets/graph.js | grep -iE 'heatmap|sizeMetric'
sed -n '1368,1444p' apps/silmari-memory-card-viewer/viewer_assets/graph.js | grep -iE 'heatmap|slack'
sed -n '1474,1520p' apps/silmari-memory-card-viewer/viewer_assets/graph.js | grep -iE 'heatmap|slack'
```
Returns matches pre-deletion.

#### 🟢 Green
- Remove the heatmap intensity branch in `getNodeColor` — **lines 1195-1197**.
- Remove the heatmap slack-gradient block in `getLinkColor` — **lines 1408-1437** (the "Heatmap mode: color links by slack/urgency" block).
- Inspect `getLinkWidth` lines 1496-1514 for the "metric-based width scaling when heatmap is active" branch; remove if coupled to heatmap state.

#### 🔵 Refactor
- Verify `getNodeColor` cascade ends cleanly at the default status-based fall-through.
- Verify `getLinkColor` cascade ends at the edge-type color fall-through (line 1440-1441 stays; slack block between 1408 and 1440 gone).
- Verify `getLinkWidth` uses only highlighted/connected/critical-depth branches; no heatmap gating.

### Success Criteria
- [x] Grep of `getNodeColor` body returns zero for `heatmap|sizeMetric`
- [x] Grep of `getLinkColor` body returns zero for `heatmap|slack` (unless slack is used outside heatmap, verify)
- [x] Grep of `getLinkWidth` body returns zero for `heatmap`
- [x] `grep -n 'store.heatmapMode\|store.sizeMetric' apps/silmari-memory-card-viewer/viewer_assets/graph.js` returns zero

## Behavior 3: Heatmap state + actions removed from viewer.js

### Test Specification
**Given**: `viewer.js` after the commit
**When**: Searching for `graphHeatmapActive`, `toggleGraphHeatmap`, `bv-graph:heatmapToggle`
**Then**: Zero matches

### TDD Cycle

#### 🔴 Red
```bash
grep -nE 'graphHeatmapActive|graphSizeMetric|toggleGraphHeatmap|setGraphSizeMetric|bv-graph:heatmapToggle|metricChange' \
    apps/silmari-memory-card-viewer/viewer_assets/viewer.js
```
Returns matches at lines 2464 (graphHeatmapActive state), 2465 (graphSizeMetric state), 2911 (heatmapToggle listener), 2917 (metricChange listener), 3642/3646/3647 (toggleGraphHeatmap method body), and 3659 (setGraphSizeMetric body).

#### 🟢 Green
- Delete state declaration at line 2464 (`graphHeatmapActive: false,`)
- Delete state declaration at line 2465 (`graphSizeMetric: 'pagerank',`)
- Delete `bv-graph:heatmapToggle` event listener at lines 2910-2912
- Delete `metricChange` event listener at lines ~2915-2918 (sets `this.graphSizeMetric = e.detail?.metric`)
- Delete method `toggleGraphHeatmap()` at lines 3639-3647 (including the preceding `/** Toggle heatmap mode in the graph */` JSDoc)
- Delete method `setGraphSizeMetric()` at line 3659 (including the preceding `/** Set the metric used for heatmap coloring and node sizing */` JSDoc at line 3651)

#### 🔵 Refactor
- After deletions, rerun the Red grep — should return zero matches.
- Verify no Alpine `x-effect`, `x-bind`, `x-init`, or `watch` in viewer.js depends on `graphHeatmapActive` or `graphSizeMetric`.
- Verify no other methods in viewer.js reference `this.graphHeatmapActive` or `this.graphSizeMetric`.

### Success Criteria
- [x] `grep -nE 'graphHeatmapActive|graphSizeMetric|toggleGraphHeatmap|setGraphSizeMetric' viewer.js` returns zero
- [x] `grep -nE 'bv-graph:heatmapToggle|metricChange' apps/silmari-memory-card-viewer/viewer_assets/` returns zero

## Behavior 4: Heatmap DOM + Alpine bindings removed from index.html

### Test Specification
**Given**: `index.html` after the commit
**When**: Searching for `heatmap`, `graphHeatmapActive`, `toggleGraphHeatmap`, `graphSizeMetric` (case-insensitive)
**Then**: Only matches are within the Label Dependency Heatmap widget block (`index.html:1033-1043`) — intentional exclusion

### TDD Cycle

#### 🔴 Red
```bash
grep -nE 'heatmap|graphHeatmapActive|toggleGraphHeatmap|graphSizeMetric' \
    apps/silmari-memory-card-viewer/viewer_assets/index.html \
  | grep -v 'Label Dependency Heatmap'
```
Currently returns many matches (the graph-heatmap feature).

#### 🟢 Green
Delete from index.html:
- **Heatmap controls panel — lines 3267-3291** (entire panel: outer wrapper, "Heatmap" header, toggle button, `<select x-model="graphSizeMetric">` dropdown with 4 options, and green→red gradient bar with Low/High labels)
- Legend variant controls — **lines 3299-3315** (both the `x-text` ternary at 3299 and the two `x-show` legend variants at 3301 and 3310; retain the default card-kind legend at 3301-3308 by stripping its `x-show="!graphHeatmapActive"` wrapping — it becomes unconditional)
- Keyboard hint line for `H` — **line 3323**
- "Heatmap" help-text mention — **line 4139**
- "Heatmap" help-text mention — **line 4298**

#### 🔵 Refactor
After deletion, the default card-kind legend (previously `x-show="!graphHeatmapActive"`) becomes the *only* legend — strip the `x-show` binding on it (it's unconditionally visible now).

### Success Criteria
- [x] The filtered grep (excluding `Label Dependency Heatmap` lines) returns zero matches
- [x] The Label Dependency Heatmap widget at `index.html:1033-1043` is untouched (grep explicitly confirms its presence)
- [x] Legend block shows card-kind colors unconditionally (no `x-show`/`x-if` wrapping)

## Behavior 5: Graph renders without regression (manual smoke)

### Test Specification
**Given**: The silmari store with ~291 cards at `~/.silmari-memory/box2-ideas/.beads/beads.db`
**When**: User starts `bun server.ts` and opens `http://localhost:8788`
**Then**:
- Graph container renders all cards
- Click/hover/drag/zoom all work
- No browser-console errors
- `store.metrics` object (inspected via dev-tools) still shows populated pagerank/betweenness (plumbing intact)

**Edge cases**: fresh install with zero edges (verify graph still loads with only nodes)

### TDD Cycle

No Red/Green — this is a manual verification step.

### Success Criteria (manual)
- [ ] `bun server.ts` starts without error
- [ ] Browser loads `http://localhost:8788` without error
- [ ] Graph canvas shows all ~291 cards
- [ ] Click a node → detail panel opens with full card content
- [ ] Drag a node → moves freely; pin-on-release works
- [ ] Scroll → zoom in/out smoothly
- [ ] Ctrl+click (dependency-path highlight) still works (separate commit deletes it)
- [ ] Shift+click (what-if cascade) still works (separate commit deletes it)
- [ ] Browser dev console shows zero errors
- [ ] `http://localhost:8788/api/health` returns `"lastSynthCount" > 0` (edge synthesis not broken)
- [ ] In browser console: `store.metrics` object has populated pagerank/betweenness arrays — WASM engine still ran

## Behavior 6: Existing unit tests still pass

### Test Specification
**Given**: The test files at `apps/silmari-memory-card-viewer/viewer_assets/*.test.js`
**When**: `bun test apps/silmari-memory-card-viewer/viewer_assets/` runs
**Then**: Exit code 0; no failures

### TDD Cycle

#### 🔴 Red (exploration)
```bash
bun test apps/silmari-memory-card-viewer/viewer_assets/
```
Pre-deletion: passes (no existing test asserts heatmap behavior).

Post-deletion (if any tests happen to reference heatmap): fails.

#### 🟢 Green
```bash
grep -l heatmap apps/silmari-memory-card-viewer/viewer_assets/*.test.js
```
If any test file matches, remove the heatmap-specific test cases.

(Expected: no matches. Current tests are on graph-helpers, viewmodel, vocab, link-builder, hybrid_scorer — none of which touch heatmap.)

#### 🔵 Refactor
None.

### Success Criteria
- [x] `bun test apps/silmari-memory-card-viewer/viewer_assets/` passes (87 pass, 0 fail)
- [x] `grep -l heatmap apps/silmari-memory-card-viewer/viewer_assets/*.test.js` returns nothing

## Integration & E2E Testing

- **Integration**: none beyond Behavior 5's manual smoke
- **E2E**: no E2E harness in this repo

## Rough LOC Budget

Updated 2026-04-19 after review amendments (W1 index.html range extended to 3267-3291; W3 added metricChange listener + graphSizeMetric state in viewer.js).

| File | Expected delete | Expected add |
|---|---|---|
| `graph.js` | ~110 LOC (4 functions ~80 + 3 branch blocks ~30) | 0 |
| `viewer.js` | ~40 LOC (2 state fields + 2 event listeners + 2 methods with JSDoc) | 0 |
| `index.html` | ~55 LOC (25-line heatmap controls panel + legend variant + hints + help-text mentions) | 0 |
| `*.test.js` | 0 (no existing heatmap tests) | 0 |
| **Total** | **~205 LOC deleted** | **0 added** |

## Success Criteria — Commit-Ready Checklist

**Automated (run before committing):**
- [x] All grep-assertion tests (Behaviors 1-4) pass
- [x] `bun test apps/silmari-memory-card-viewer/viewer_assets/` passes (87 pass, 0 fail)
- [x] `grep -niE 'heatmap|toggleHeatmap|sizeMetric|setSizeMetric|getHeatmapState|getHeatmapColor' apps/silmari-memory-card-viewer/viewer_assets/graph.js` returns zero
- [x] `grep -niE 'heatmap|graphHeatmapActive|graphSizeMetric|toggleGraphHeatmap|setGraphSizeMetric|metricChange' apps/silmari-memory-card-viewer/viewer_assets/viewer.js` returns zero
- [x] `grep -niE 'heatmap|graphHeatmapActive|graphSizeMetric|toggleGraphHeatmap|setGraphSizeMetric' apps/silmari-memory-card-viewer/viewer_assets/index.html | grep -v 'Label Dependency Heatmap'` returns zero
- [x] `grep -n 'store\.wasmGraph\.slack' apps/silmari-memory-card-viewer/viewer_assets/graph.js` still returns line 749 (slack WASM call retained per W4)
- [x] `grep -n 'formatSlack' apps/silmari-memory-card-viewer/viewer_assets/graph.js` still returns line 2983 (detail-panel formatter retained per W4)

**Manual (Behavior 5 smoke):**
- [ ] `bun server.ts` starts cleanly
- [ ] Browser loads, graph renders, interactions work
- [ ] No console errors
- [ ] `store.metrics` populated (WASM plumbing intact)

## References

- Mandate: `~/.claude/projects/-home-maceo-Dev-silmari-agent-memory/memory/project_viewer_fork_and_strip_mandate.md`
- Research (Path B reference only, not this commit): `thoughts/searchable/shared/research/2026-04-18-dual-layer-graph-design.md`
- Conversation: 2026-04-19 exchange establishing Path A = fork-and-strip in place
- Screenshot anchoring this decision: `~/Pictures/Screenshots/2026-04-19_16-24.jpg`
- Prior work the user ran: `/create_tdd_plan` on 2026-04-18 (40-line color collapse) — retracted as a phantom problem after screenshot review
- **Review**: `thoughts/searchable/shared/plans/2026-04-19-tdd-strip-graph-heatmap-from-spa-REVIEW.md` — all 5 scope-precision warnings (W1-W5) addressed; amendments applied directly into this plan on 2026-04-19

## Revision History

- **2026-04-19 initial** — TDD plan drafted covering 3 files, 6 behaviors, ~175 LOC delete estimate.
- **2026-04-19 amended** — Applied all 5 review warnings (W1 index.html range 3267-3275 → 3267-3291; W2 setGraphMetric → setGraphSizeMetric at line 3659; W3 added metricChange listener + graphSizeMetric state; W4 explicit slack retention section; W5 vocab.js:59 note in NOT-doing). LOC budget revised to ~205.

End of plan.
