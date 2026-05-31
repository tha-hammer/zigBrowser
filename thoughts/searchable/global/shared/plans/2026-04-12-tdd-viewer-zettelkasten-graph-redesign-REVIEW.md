# Plan Review Report: Viewer Zettelkasten Graph Redesign TDD Plan

## Review Summary

| Category | Status | Issues Found |
|----------|--------|--------------|
| Contracts | ⚠️ | 2 issues — fz: encoding, extractEdges redundancy |
| Interfaces | ✅ | 0 issues — clean extractor pattern matches existing code |
| Promises | ✅ | 0 issues — all pure functions, no async |
| Data Models | ⚠️ | 1 issue — graph node enrichment injection point unspecified |
| APIs | ✅ | 0 issues — no external APIs involved |

---

## Contract Review

### Well-Defined:
- ✅ `extractKind(labels)` — Contract matches `labels.ts:137` (`kindLabel()` produces `kind:<value>`). All 11 valid kinds confirmed at `labels.ts:51-63`. Default `'idea'` is correct.
- ✅ `extractTrunk(labels)` — Contract matches `labels.ts:145` (`trunkLabel()` produces `trunk:<value>`). Both digit (1-5) and `'root'` confirmed valid at `labels.ts:245-255`.
- ✅ `extractBox(labels)` — Contract matches `labels.ts:141` (`boxLabel()` produces `box:<value>`). Only `'biblio'` and `'idea'` are valid. Default `'idea'` correct.
- ✅ `extractKeywords(labels)` — Contract matches `labels.ts:179` (`keywordLabel()` produces `keyword:<normalized>`). Spaces→underscores confirmed at line 182.
- ✅ `extractEdges(labels)` — Contract matches `labels.ts:161` (`refLabel()` produces `ref:<type>:<targetId>`). Parser at `labels.ts:277-295` confirms same split logic.
- ✅ `V.edgeType` — All 12 edge types confirmed: 7 AUTO (`labels.ts:79-87`) + 5 REVIEWED (`labels.ts:89-95`).
- ✅ `V.kind` — All 11 kinds confirmed at `labels.ts:51-63`.
- ✅ `V.trunk` — 5 trunks + root confirmed at `labels.ts:245-255`.

### Missing or Unclear:

#### ⚠️ Issue 1: `fz:` label uses underscore encoding — plan's extractFolgezettel returns raw underscore form

**What**: The `fz:` label stores `fz:2_3a1` (underscore) not `fz:2/3a1` (slash), because beads_rust rejects slashes in labels (`labels.ts:118-123`). The existing `extractFolgezettel()` in viewmodel.js returns the raw label value after `fz:` — so for address `2/3a1`, it returns `'2_3a1'`.

**Impact**: The hover tooltip and click detail panel will display `2_3a1` instead of `2/3a1` unless a decode step is added. The MCP's own parser (`parseFzFromLabels()` at `labels.ts:217`) translates underscore back to slash, but viewmodel.js doesn't do this.

**Recommendation**: Add a `decodeFzAddress(raw)` helper (or inline in `extractFolgezettel`) that translates the FIRST underscore to a slash (the trunk/sequence separator):
```javascript
// In viewmodel.js, update extractFolgezettel:
export function extractFolgezettel(labels) {
  if (!Array.isArray(labels)) return null;
  for (const l of labels) {
    if (typeof l === 'string' && l.startsWith('fz:')) {
      const raw = l.slice(3);
      return raw.replace('_', '/'); // decode underscore back to slash
    }
  }
  return null;
}
```

Add test:
```javascript
it('decodes underscore to slash in folgezettel address', () => {
  expect(extractFolgezettel(['fz:2_3a1'])).toBe('2/3a1');
});
```

**Severity**: ⚠️ Warning — plan works without this, but display will show encoded form.

---

#### ⚠️ Issue 2: `extractEdges(labels)` overlaps with existing dependency row data path

**What**: The plan proposes `extractEdges(labels)` to parse `ref:*` labels into `[{ type, targetId }]`. But `server.ts:114-151` already synthesizes these same `ref:*` labels into the `dependencies` SQL table with columns `(issue_id, depends_on_id, type)`. The graph's link objects already carry `.type` with the edge type string (e.g., `'supports'`).

**Impact**: Two data paths produce the same information:
1. `dependencies` table → graph links with `.type` (already works)
2. `extractEdges(labels)` → card's `.edges[]` array (new, from labels)

This isn't a bug — it's redundancy. The graph links come from the dependencies table, the card detail panel's edge list could come from either source. But the plan doesn't clarify which source feeds the click detail panel.

**Recommendation**: Keep `extractEdges()` — it's useful for the click detail panel where you want edges grouped by type on a single card. The dependencies table is better for graph link construction (it's already parsed and in SQL). Document the distinction:
- `dependencies` table → **graph links** (for force-graph rendering)
- `extractEdges(labels)` ��� **card detail edges** (for click panel display)

Add a note in the plan that Phase 3's link coloring should use `link.type` from the existing dependency data, NOT re-extract from labels.

**Severity**: ⚠️ Warning — not blocking, but clarity prevents confusion during implementation.

---

## Interface Review

### Well-Defined:
- ✅ All 6 extractor functions follow the existing `extractScope`/`extractFolgezettel` pattern exactly — same signature `(labels: string[]) → T`, same null handling, same iteration pattern.
- ✅ `toCard()` enrichment is additive — 5 new fields appended to existing return object. No existing fields modified.
- ✅ New exports follow the existing `globalThis.VM` pattern for plain-script consumers.
- ✅ `graph-helpers.js` is a new file with a clean interface: 3 pure functions, no side effects, no DOM dependency.
- ✅ `vocab.test.js` follows the identical pattern of `viewmodel.test.js` — `bun:test`, named imports, describe/it blocks.

### No issues found.

---

## Promise Review

### Well-Defined:
- ✅ All Phase 1-2 functions are synchronous, pure, and deterministic — no async, no side effects, no resource management needed.
- ✅ Graph node enrichment (Phase 3) happens during synchronous `prepareGraphData()` — no new async boundaries introduced.
- ✅ No race conditions: `vocab.js` exports are set at module load time via `globalThis.V`, before any consumer reads them.

### No issues found.

---

## Data Model Review

### Well-Defined:
- ✅ Card model extension is backward-compatible — all new fields have defaults (`kind: 'idea'`, `trunk: null`, `box: 'idea'`, `keywords: []`, `edges: []`).
- ✅ Edge object shape `{ type: string, targetId: string }` matches the label format exactly.
- ✅ Trunk object shape `{ number: number, name: string }` is clean and consistent.
- ✅ No migration needed — labels already contain all the data; this is a read-side enrichment only.

### Missing or Unclear:

#### ⚠️ Issue 3: Graph node enrichment injection point unspecified

**What**: Phase 3 says "attach `.kind`, `.trunk`, `.box`, `.keywords`, `.edges`, `.folgezettel` from the card's labels" to graph nodes, but doesn't specify WHERE in the data flow. Research found two options:

1. **At `getGraphViewData()` call site** (viewer.js:~2771) — transform raw rows before calling `loadData()`
2. **Inside `prepareGraphData()`** (graph.js:~1084) — enrich nodes inline during construction

**Impact**: Without specifying, the implementer may guess wrong and either:
- Duplicate extraction logic between viewer.js and graph.js
- Miss the extraction entirely in one code path

**Recommendation**: Specify Option 2 (inside `prepareGraphData()` in graph.js) because:
- The labels array is already available on each node at line 1096
- It keeps the change contained to graph.js
- It doesn't affect the list view's `loadIssues()` path

Add to Phase 3, Behavior 3.4:
```javascript
// In graph.js prepareGraphData(), after node construction (~line 1096):
// Import extractors at top of graph.js (or inline since they're simple)
node.kind = extractKind(node.labels);
node.trunk = extractTrunk(node.labels);
node.box = extractBox(node.labels);
node.keywords = extractKeywords(node.labels);
node.folgezettel = extractFolgezettel(node.labels);
// edges come from link objects via dependencies table, not from labels
```

**Severity**: ⚠️ Warning — ambiguity that could cause implementation confusion.

---

## API Review

No external APIs involved. The viewer is a self-contained SPA reading from a local SQLite database. No review needed.

---

## Critical Issues (Must Address Before Implementation)

None. All issues found are warnings, not blockers. The plan can proceed with the amendments below.

---

## Suggested Plan Amendments

```diff
# In Phase 1, Behavior 1.2 (extractFolgezettel — already exists):

+ Add: Note that existing extractFolgezettel returns underscore-encoded form
+ Add: Update extractFolgezettel to decode underscore→slash (first occurrence)
+ Add: Test case: expect(extractFolgezettel(['fz:2_3a1'])).toBe('2/3a1')
+ Add: Test case: expect(extractFolgezettel(['fz:6'])).toBe('6') (no underscore = no change)

# In Phase 1, Behavior 1.5 (extractEdges):

+ Add: Note that this is for click detail panel display, NOT for graph link construction
+ Add: Clarify: graph links use dependencies table `.type` column (already parsed by server.ts)
+ Add: The two data paths serve different consumers (graph rendering vs detail panel)

# In Phase 3, Behavior 3.4 (Wire helpers into graph.js):

+ Add: Specify injection point: inside prepareGraphData() at ~line 1096
+ Add: node.labels is already available (parsed array), call extractors inline
+ Add: Do NOT attach node.edges from labels — graph links already come from dependencies table
+ Add: For link coloring, use existing link.type from dependency rows, not node.edges

# General:

+ Add: After modifying viewmodel.js extractFolgezettel, verify existing test still passes
  (existing test uses 'fz:6' which has no underscore — should still return '6')
```

---

## Approval Status

- [x] **Ready for Implementation** - All 3 warnings addressed in plan revision (2026-04-12)
- [ ] ~~Needs Minor Revision~~ — RESOLVED
- [ ] **Needs Major Revision** - Critical issues must be resolved first

**Summary**: The plan is architecturally sound. The TDD structure is well-designed with proper Red-Green-Refactor cycles. The 3 warnings are:
1. `fz:` underscore→slash decoding (display correctness)
2. `extractEdges` vs dependencies table clarification (prevents confusion)
3. Graph node enrichment injection point (prevents wrong implementation location)

All three are 1-2 line additions to the plan, not structural changes. After addressing them, the plan is ready for implementation.
