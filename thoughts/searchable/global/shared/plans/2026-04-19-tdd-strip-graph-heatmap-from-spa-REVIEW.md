# Plan Review: Strip Graph-Node Heatmap from SPA

**Reviewing**: `thoughts/searchable/shared/plans/2026-04-19-tdd-strip-graph-heatmap-from-spa.md`
**Reviewer**: Claude (automated pre-implementation review, 2026-04-19)
**Plan type**: Pure deletion; ~175 LOC removed, 0 added
**Epic**: `silmari-agent-memory-xom` · **Task**: `silmari-agent-memory-9al`

## Summary

| Category | Status | Issues |
|---|---|---|
| Contracts | ✅ | 0 — single promise ("WASM plumbing intact") correctly preserved |
| Interfaces | ✅ | 0 — no public interfaces added/changed, only deleted ones listed correctly |
| Promises | ✅ | 0 — behavioral guarantees clear (graph still renders, metrics still compute, detail-panel metrics untouched) |
| Data Models | ✅ | 0 — `store.heatmapMode` / `store.sizeMetric` are dynamic-assignment fields, not declared struct members (grep confirms); cleanup falls out of assignment-site deletion |
| APIs | N/A | No external APIs touched |
| **Scope precision** | ⚠️ | **5 warnings** — line ranges and identifier names need tightening before execution |

**Verdict**: Plan is structurally sound. No critical issues. Five precision warnings that should be addressed as a ~5-minute amendment before running the deletion, so the first pass lands cleanly instead of requiring follow-up "missed a reference" commits.

---

## Spot-check verification of plan's claims

| Plan claim | Verified against source | Status |
|---|---|---|
| `getHeatmapColor` at graph.js:372 | `grep` confirms line 372 | ✅ |
| `toggleHeatmap`/`setSizeMetric`/`getHeatmapState` at 443-472 | Confirmed — 443, 453, 464 | ✅ |
| `getNodeColor` heatmap branch at 1195-1197 | Confirmed — `if (store.heatmapMode)` at 1196 | ✅ |
| `getLinkColor` slack-gradient at 1408-1437 | Confirmed — `if (store.heatmapMode && …)` at 1408 | ✅ |
| `getLinkWidth` heatmap-gated block at 1496-1514 | Confirmed — `if (store.heatmapMode && …)` at 1498 | ✅ |
| viewer.js state at 2464 (`graphHeatmapActive`) | Confirmed at 2464 | ✅ |
| viewer.js event listener at 2910-2912 | Confirmed at 2911 — BUT there's also a *metric-change* listener at 2917 not named in plan | ⚠️ see W3 |
| viewer.js method at 3639-3647 (`toggleGraphHeatmap`) | Confirmed | ✅ |
| viewer.js method at ~3651 (setter) | Actual method is `setGraphSizeMetric` at 3659 — not "setGraphMetric" | ⚠️ see W2 |
| index.html heatmap controls at 3267-3275 | Actual block is **3267-3291** (select at 3276-3282, gradient bar at 3284-3290 missed) | ⚠️ see W1 |
| WASM plumbing preserved | `store.metrics.slack` at 749 is still consumed by detail-panel slack display at 2982-3015 — intentional by mandate but not highlighted by plan | ⚠️ see W4 |
| `store.heatmapMode` has no struct-declaration site | Confirmed — no `heatmapMode:` or `sizeMetric:` struct-literal match; fields come into existence via mutation | ✅ no extra cleanup needed |

---

## Warnings (address before implementation)

### ⚠️ W1 — `index.html` deletion range is incomplete

**Plan says**: "Heatmap controls block — lines 3267-3275 (div containing the button that calls `toggleGraphHeatmap()`)"

**Reality**: the controls block extends to **line 3291**. Lines 3267-3275 are the button only. Missing from the plan's range:
- `3276-3282` — the `<select x-model="graphSizeMetric">` dropdown with 4 `<option>` values (PageRank / Betweenness / Key Thread / In-Degree)
- `3284-3290` — the green→red gradient bar (`<div class="bg-gradient-to-r from-green-500 via-yellow-500 to-red-500">` + Low/High labels)
- `3291` — closing `</div>` for the outer panel

**If deleted as-written (3267-3275 only)**, the `<select>` + gradient-bar stay orphaned, referencing `graphSizeMetric` and `setGraphSizeMetric()` which will themselves be gone → Alpine runtime errors.

**Recommendation**: change the plan's index.html deletion range to **3267-3291** (entire "Heatmap Controls" panel).

### ⚠️ W2 — viewer.js setter method name is wrong

**Plan says**: "Any `setGraphMetric()` or related size-metric setter at ~3651"

**Reality**: the method is named `setGraphSizeMetric()` and sits at line **3659**. Referenced by `index.html:3276` as `@change="setGraphSizeMetric($event.target.value)"`. The plan's pattern-match phrasing will catch it but the specific name belongs in the plan for grep-assertion precision.

**Recommendation**: replace "setGraphMetric() or related … at ~3651" with explicit `setGraphSizeMetric()` at line 3659.

### ⚠️ W3 — Plan names only one of two event-bridges to delete

**Plan says**: delete the `bv-graph:heatmapToggle` event listener at viewer.js:2910-2912.

**Reality**: there's a *second* event listener immediately following — a `metricChange` listener that syncs `graphSizeMetric` at viewer.js:2917:

```js
this.graphSizeMetric = e.detail?.metric ?? 'pagerank';
```

This is wired to the `dispatchEvent('metricChange', …)` fired by `setSizeMetric()` in graph.js:457. Both events are heatmap-coupled; both listeners become orphan references after `setSizeMetric` is deleted in graph.js.

**Recommendation**: extend plan's Behavior 3 to explicitly list *both* listeners:
- `heatmapToggle` listener at 2910-2912
- `metricChange` listener at ~2915-2918

Same deletion logic, but the plan should name both so the grep-assertion in Behavior 3's success criteria catches both absences.

### ⚠️ W4 — `store.metrics.slack` retention rationale not documented

**Plan says**: "WASM plumbing stays" (general) and lists `store.metrics` as "still populated" under consumers-that-stay-intact.

**Reality**: `slack` specifically has a subtle dependency:
- Populated at `graph.js:749` from `store.wasmGraph.slack()`
- **Consumed by the heatmap branches (deleted)** at lines 1408-1437 and 1498-1514
- **Also consumed by the card detail panel** at lines 2982-3015 (`formatSlack` helper + "Slack: 3d" colored indicator)

If the person implementing this plan reads "all heatmap consumers of slack are deleted" and concludes "slack is now orphaned, kill it too," they will break the detail-panel slack display — which is out of scope for *this* commit (detail-panel metrics grid is a later commit).

**Recommendation**: add to the plan's "Consumers that stay intact" section a specific line:
> `store.metrics.slack` / `node.slack` — **retained**. Heatmap consumers are the only ones being removed in this commit. The detail-panel slack display at lines 2982-3015 still depends on it. Deletion of the detail-panel slack indicator is a separate commit under the detail-panel metrics-grid strip.

### ⚠️ W5 — Plan doesn't flag `"critical"` ↔ `"Key Thread"` user-facing rename leak

**Observation** (not strictly a plan error, more a semantic-debt note for future strip commits):

The `<select>` at index.html:3278-3281 maps internal metric names to user-facing labels:
- `pagerank` → "PageRank"
- `betweenness` → "Betweenness"
- `critical` → **"Key Thread"** ← *already* a Zettelkasten-voiced translation
- `indegree` → "In-Degree"

"Key Thread" is `vocab.js`-style translation pretending the critical-path metric is a Zettelkasten concept. When this `<select>` gets deleted in this commit, that translation disappears with it — no action needed. But flagging because the `critical` → "Key Thread" leak exists in at least one more place: `vocab.js:59` has `cardKeyThread: 'Key Thread'` as a dashboard widget title. That widget should be reviewed for issue-tracker-metric backing in a later pass (the dashboard widgets are on the *Transform* list per the 2026-04-19 inventory).

**Recommendation**: no amendment to this plan. Note in the epic `silmari-agent-memory-xom` description that `vocab.js:59 cardKeyThread` needs verification during the dashboard-widget transform commit.

---

## No-Issues Sections (brief)

### Contracts ✅
The single contract — "WASM metrics engine keeps computing" — is verifiable via Behavior 5 manual smoke: inspect `store.metrics` in browser dev tools post-deletion. Plan covers this correctly.

### Interfaces ✅
Deletions only. All deleted identifiers (`toggleHeatmap`, `setSizeMetric`, `getHeatmapState`, `getHeatmapColor`, `toggleGraphHeatmap`, `setGraphSizeMetric`) are correctly scoped as callable references that disappear from both their definition sites and their call sites.

### Promises ✅
- Graph rendering unchanged: Behavior 5 covers
- Interactions preserved: Behavior 5 covers
- Detail-panel metrics unchanged: explicit out-of-scope, correct boundary
- No async/timeout behaviors involved (pure synchronous deletion)

### Data Models ✅
`store.heatmapMode` and `store.sizeMetric` are dynamic-assignment fields — grep confirms zero struct-literal declaration sites (`heatmapMode:` / `sizeMetric:` as object-key patterns). Their cleanup is automatic from removing the assignment/read sites. No struct-migration or serialization concerns.

### APIs ✅ (N/A)
No external APIs touched. `/api/health` response shape unchanged.

---

## Suggested Plan Amendments

```diff
# Section: Current State Analysis → Exact locations to delete → graph.js
(no changes)

# Section: Current State Analysis → Exact locations to delete → viewer.js
-- `toggleGraphHeatmap()` method — lines 3639-3647
-- `setGraphMetric()` method that follows at ~3651 (size-metric setter)
++ `toggleGraphHeatmap()` method — lines 3639-3647
++ `setGraphSizeMetric()` method — line 3659 (size-metric setter for the <select> dropdown)
++ `metricChange` event listener — lines ~2915-2918 (sets `this.graphSizeMetric = e.detail?.metric`)

# Section: Current State Analysis → Exact locations to delete → index.html
-- Heatmap controls block — lines 3267-3275 (button + toggleGraphHeatmap() call)
++ Heatmap controls block — lines 3267-3291 (outer panel containing button at 3271-3275,
++   <select x-model="graphSizeMetric"> at 3276-3282, green→red gradient bar at 3284-3290)

# Section: Consumers that stay intact (latent plumbing)
+ Add bullet:
+ - `store.metrics.slack` / `node.slack` — RETAINED. Heatmap was one consumer of slack;
+   the detail-panel slack display at graph.js:2982-3015 is the other consumer and stays.
+   Do NOT delete `store.wasmGraph.slack()` at line 749 or the formatSlack helper.

# Section: Behavior 3 (viewer.js) → TDD Cycle → Red grep
-- grep -nE 'graphHeatmapActive|toggleGraphHeatmap|bv-graph:heatmapToggle|setGraphMetric' viewer.js
++ grep -nE 'graphHeatmapActive|graphSizeMetric|toggleGraphHeatmap|setGraphSizeMetric|bv-graph:heatmapToggle|metricChange' viewer.js

# Section: Behavior 3 → Green step
++ Delete metricChange event listener at lines ~2915-2918 (alongside the heatmapToggle listener)
++ Rename "setGraphMetric" to "setGraphSizeMetric" throughout
```

---

## Critical Issues

None.

---

## Approval Status

- [x] **Ready for Implementation after minor revision** — Apply the 5 warning fixes above as a ~5-minute plan amendment, then execute.
- [ ] Needs Major Revision
- [ ] Needs Minor Revision before proceeding — the warnings are scope-precision, not design flaws, so the plan can also be executed as-is if the implementer manually catches the extended ranges during deletion. Recommend applying amendments for cleanliness.

## Tracking

No new bd issue created — findings are all warnings, no criticals. Plan can absorb these amendments inline. Existing task `silmari-agent-memory-9al` continues as the tracking unit; notes field can link to this review.
