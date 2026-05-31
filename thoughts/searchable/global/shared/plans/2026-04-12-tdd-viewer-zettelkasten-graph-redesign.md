# Viewer Zettelkasten Graph Redesign — TDD Implementation Plan

## Overview

Transform the beads_viewer SPA from an issue-tracker visualization into a Zettelkasten thinking tool. The data pipeline already carries ZK fields through `viewmodel.js` (scope, folgezettel) but the presentation layer doesn't surface them. This plan adds 6 new label extractors, expands the vocabulary layer, rewires graph node/link construction for ZK-aware coloring, redesigns the legend, and implements progressive disclosure (hover = "where am I?", click = "what does this think?").

**Test framework**: `bun:test` (describe/it/expect)
**Primary files**: `apps/silmari-memory-card-viewer/viewer_assets/` (live served directory)
**Secondary sync**: `apps/silmari-viewer/pkg/export/viewer_assets/` (Go export — sync after)
**Run tests**: `bun test apps/silmari-memory-card-viewer/viewer_assets/viewmodel.test.js`

## Current State Analysis

### Key Discoveries:
- `viewmodel.js` already extracts `.scope` (from `scope:*`) and `.folgezettel` (from `fz:*`) — but nothing in templates consumes them
- **CRITICAL**: `fz:` labels use underscore encoding (`fz:2_3a1`) because beads_rust rejects slashes in labels (`labels.ts:118-123`). The existing `extractFolgezettel()` returns the raw encoded form (e.g., `'2_3a1'`), NOT the human-readable `'2/3a1'`. Must decode before display.
- `server.ts:114-151` already synthesizes `ref:*` labels into `dependencies` table rows with `(issue_id, depends_on_id, type)`. Graph links already carry `.type` with the edge type string. Two data paths exist: dependencies table → graph links; `ref:*` labels → card detail panel.
- `viewmodel.test.js` has 15 tests using `bun:test`, covering `toCard`, `toLink`, `toCardList`, `toLifecycle`, `getInProgressCards`, `toNotebookStats`
- `vocab.js` maps Issues→Cards with status tooltips but has no card kind, edge type, or trunk vocabulary
- `graph.js` treats all 12 edge types identically — only `blocks` is distinguished for DAG analytics
- Node construction (`graph.js:1036-1119`) carries `id`, `title`, `status`, `priority`, `labels` but NOT `kind`, `trunk`, `box`, `keywords`, or typed edges
- The live viewer is served from `apps/silmari-memory-card-viewer/server.ts` using `viewer_assets/`

### Existing Test Pattern (`viewmodel.test.js`):
```javascript
import { describe, it, expect } from 'bun:test';
import { toCard, toLink, ... } from './viewmodel.js';

describe('toCard', () => {
  it('maps a basic issue row to a card view model', () => {
    const row = { id: 'br-vuj', labels: '["scope:decisions-sqlite","fz:6"]', ... };
    const card = toCard(row);
    expect(card.scope).toBe('decisions-sqlite');
    expect(card.folgezettel).toBe('6');
  });
});
```

## Desired End State

### Observable Behaviors:
1. `extractKind(labels)` returns the card kind from `kind:*` labels
2. `extractTrunk(labels)` returns trunk number and display name from `trunk:*` labels
3. `extractBox(labels)` returns `'idea'` or `'biblio'` from `box:*` labels
4. `extractKeywords(labels)` returns array of keywords from `keyword:*` labels
5. `extractEdges(labels)` returns typed edge objects from `ref:*` labels
6. `toCard(row)` includes all new ZK fields
7. `vocab.js` provides display names for 11 card kinds, 12 edge types, 5 trunks
8. Graph nodes colored by card kind, sized by kind priority
9. Graph links colored/styled by edge type
10. Legend shows card kinds + edge types
11. Hover tooltip shows fz address, kind badge, trunk, edge summary
12. Click detail shows typed edge list, folgezettel chain, keywords, navigation

## What We're NOT Doing

| NOT Doing | ARE Doing |
|-----------|-----------|
| New view modes (folgezettel tree layout) | Enriching existing 5 modes with ZK data |
| Keyword index search mode | Exposing keywords in detail panel |
| "Surf from here" progressive expansion | Folgezettel chain highlight on hover |
| WASM metric changes | Using existing PageRank/betweenness as-is |
| New heatmap metrics (stub density, contradiction hotspots) | Keeping existing 4 heatmap metrics |
| Modifying the Go export pipeline | Only changing SPA JS/HTML files |
| Touching `server.ts` edge synthesis logic | It already synthesizes `ref:*` labels into dependency rows |

## Testing Strategy

- **Framework**: `bun:test` (existing)
- **Unit tests**: viewmodel.js extractors (6 new functions), vocab.js lookups
- **Integration**: `toCard()` enrichment (existing test file, new assertions)
- **Manual**: Graph rendering, legend, hover tooltip, click detail panel
- **Run**: `bun test apps/silmari-memory-card-viewer/viewer_assets/viewmodel.test.js`

---

╔═══════════════════════════════════════════════╗
║  PHASE 1: viewmodel.js — ZK Label Extractors  ║
║  6 new pure functions, fully testable          ║
╚═══════════════════════════════════════════════╝

## Phase 1: viewmodel.js — Zettelkasten Label Extractors

### Overview
Add 6 new extractor functions to `viewmodel.js` and wire them into `toCard()`. Each follows the same pattern as existing `extractScope()` and `extractFolgezettel()` — iterate labels, match prefix, return value. All pure functions, zero DOM dependency. Also fix the existing `extractFolgezettel()` to decode underscore→slash before display.

---

### Behavior 1.0: Fix extractFolgezettel to decode underscore→slash

**Given**: A labels array containing `'fz:2_3a1'`
**When**: `extractFolgezettel(labels)` is called
**Then**: Returns `'2/3a1'` (decoded), NOT `'2_3a1'` (raw label form)

**Context**: beads_rust rejects `/` in labels (`labels.ts:118-123`), so `fzLabel()` encodes `2/3a1` as `fz:2_3a1`. The MCP's own parser (`parseFzFromLabels` at `labels.ts:217`) decodes this. The viewer's `extractFolgezettel()` must do the same.

**Edge Cases**:
- `fz:6` (no underscore, root-level) → returns `'6'` unchanged
- `fz:2_3a1` → returns `'2/3a1'` (first underscore decoded to slash)
- No `fz:*` label → returns `null`

#### 🔴 Red: Write Failing Test
**File**: `apps/silmari-memory-card-viewer/viewer_assets/viewmodel.test.js`
```javascript
describe('extractFolgezettel — underscore decoding', () => {
  it('decodes underscore to slash in folgezettel address', () => {
    const card = toCard({ id: 'zk-1', title: 'T', status: 'open', labels: '["fz:2_3a1"]' });
    expect(card.folgezettel).toBe('2/3a1');
  });

  it('leaves root-level addresses unchanged', () => {
    const card = toCard({ id: 'zk-2', title: 'T', status: 'open', labels: '["fz:6"]' });
    expect(card.folgezettel).toBe('6');
  });
});
```

#### 🟢 Green: Fix existing extractFolgezettel
**File**: `apps/silmari-memory-card-viewer/viewer_assets/viewmodel.js`
```javascript
export function extractFolgezettel(labels) {
  if (!Array.isArray(labels)) return null;
  for (const l of labels) {
    if (typeof l === 'string' && l.startsWith('fz:')) {
      const raw = l.slice(3);
      return raw.replace('_', '/'); // decode first underscore → slash (trunk/sequence separator)
    }
  }
  return null;
}
```

#### 🔵 Refactor
Verify existing test `expect(card.folgezettel).toBe('6')` still passes (no underscore = no change).

### Success Criteria
**Automated:**
- [x] New test fails before fix (Red)
- [x] New test passes after fix (Green)
- [x] Existing `toCard` test with `fz:6` still passes (no regression)

---

### Behavior 1.1: extractKind(labels) returns card kind

**Given**: A labels array containing `'kind:hub'`
**When**: `extractKind(labels)` is called
**Then**: Returns `'hub'`

**Edge Cases**:
- No `kind:*` label → returns `'idea'` (default kind)
- Multiple `kind:*` labels → returns first match
- Empty/null labels → returns `'idea'`
- Invalid kind value (not in VALID_CARD_KINDS) → returns value as-is (viewer is permissive)

#### 🔴 Red: Write Failing Test
**File**: `apps/silmari-memory-card-viewer/viewer_assets/viewmodel.test.js`
```javascript
describe('extractKind', () => {
  it('extracts kind from kind: label', () => {
    expect(extractKind(['kind:hub', 'scope:foo'])).toBe('hub');
  });

  it('defaults to idea when no kind label', () => {
    expect(extractKind(['scope:bar'])).toBe('idea');
  });

  it('defaults to idea on null/empty', () => {
    expect(extractKind(null)).toBe('idea');
    expect(extractKind([])).toBe('idea');
  });

  it('returns first match when multiple kind labels', () => {
    expect(extractKind(['kind:structure', 'kind:hub'])).toBe('structure');
  });
});
```

#### 🟢 Green: Minimal Implementation
**File**: `apps/silmari-memory-card-viewer/viewer_assets/viewmodel.js`
```javascript
export function extractKind(labels) {
  if (!Array.isArray(labels)) return 'idea';
  for (const l of labels) {
    if (typeof l === 'string' && l.startsWith('kind:')) return l.slice(5);
  }
  return 'idea';
}
```

#### 🔵 Refactor
No refactor needed — follows existing `extractScope`/`extractFolgezettel` pattern exactly.

### Success Criteria
**Automated:**
- [x] Test fails before implementation (Red): `bun test apps/silmari-memory-card-viewer/viewer_assets/viewmodel.test.js`
- [x] Test passes after implementation (Green)
- [x] All existing tests still pass

---

### Behavior 1.2: extractTrunk(labels) returns trunk info

**Given**: A labels array containing `'trunk:2'`
**When**: `extractTrunk(labels)` is called
**Then**: Returns `{ number: 2, name: 'Social Science' }`

**Edge Cases**:
- No `trunk:*` label → returns `null`
- `trunk:root` → returns `{ number: 0, name: 'Root' }`
- Empty/null labels → returns `null`

#### 🔴 Red: Write Failing Test
```javascript
describe('extractTrunk', () => {
  it('extracts trunk number and maps to name', () => {
    const t = extractTrunk(['trunk:2', 'scope:foo']);
    expect(t).toEqual({ number: 2, name: 'Social Science' });
  });

  it('maps all 5 trunks', () => {
    expect(extractTrunk(['trunk:1']).name).toBe('Humanities');
    expect(extractTrunk(['trunk:3']).name).toBe('Natural Science');
    expect(extractTrunk(['trunk:4']).name).toBe('Formal Science');
    expect(extractTrunk(['trunk:5']).name).toBe('Applied Science');
  });

  it('handles trunk:root', () => {
    expect(extractTrunk(['trunk:root'])).toEqual({ number: 0, name: 'Root' });
  });

  it('returns null when no trunk label', () => {
    expect(extractTrunk(['scope:bar'])).toBeNull();
    expect(extractTrunk(null)).toBeNull();
    expect(extractTrunk([])).toBeNull();
  });
});
```

#### 🟢 Green: Minimal Implementation
```javascript
const TRUNK_NAMES = {
  '0': 'Root', 'root': 'Root',
  '1': 'Humanities', '2': 'Social Science', '3': 'Natural Science',
  '4': 'Formal Science', '5': 'Applied Science',
};

export function extractTrunk(labels) {
  if (!Array.isArray(labels)) return null;
  for (const l of labels) {
    if (typeof l === 'string' && l.startsWith('trunk:')) {
      const val = l.slice(6);
      const num = val === 'root' ? 0 : parseInt(val, 10);
      return { number: num, name: TRUNK_NAMES[val] || `Trunk ${val}` };
    }
  }
  return null;
}
```

#### 🔵 Refactor
Export `TRUNK_NAMES` so `vocab.js` can reuse it.

### Success Criteria
**Automated:**
- [x] Red: test fails
- [x] Green: test passes
- [x] All existing tests pass

---

### Behavior 1.3: extractBox(labels) returns box type

**Given**: A labels array containing `'box:biblio'`
**When**: `extractBox(labels)` is called
**Then**: Returns `'biblio'`

**Edge Cases**:
- No `box:*` label → returns `'idea'` (default box)
- Empty/null → returns `'idea'`

#### 🔴 Red: Write Failing Test
```javascript
describe('extractBox', () => {
  it('extracts box from box: label', () => {
    expect(extractBox(['box:biblio'])).toBe('biblio');
    expect(extractBox(['box:idea'])).toBe('idea');
  });

  it('defaults to idea when no box label', () => {
    expect(extractBox(['scope:bar'])).toBe('idea');
    expect(extractBox(null)).toBe('idea');
  });
});
```

#### 🟢 Green: Minimal Implementation
```javascript
export function extractBox(labels) {
  if (!Array.isArray(labels)) return 'idea';
  for (const l of labels) {
    if (typeof l === 'string' && l.startsWith('box:')) return l.slice(4);
  }
  return 'idea';
}
```

### Success Criteria
**Automated:**
- [x] Red → Green → all tests pass

---

### Behavior 1.4: extractKeywords(labels) returns keyword list

**Given**: A labels array containing `'keyword:systems_theory'` and `'keyword:autopoiesis'`
**When**: `extractKeywords(labels)` is called
**Then**: Returns `['systems_theory', 'autopoiesis']`

**Edge Cases**:
- No `keyword:*` labels → returns `[]`
- Underscores in keywords preserved as-is (display layer can humanize)
- Empty/null → returns `[]`

#### 🔴 Red: Write Failing Test
```javascript
describe('extractKeywords', () => {
  it('extracts all keyword labels', () => {
    const kw = extractKeywords(['keyword:systems_theory', 'scope:foo', 'keyword:autopoiesis']);
    expect(kw).toEqual(['systems_theory', 'autopoiesis']);
  });

  it('returns empty array when none found', () => {
    expect(extractKeywords(['scope:bar'])).toEqual([]);
    expect(extractKeywords(null)).toEqual([]);
    expect(extractKeywords([])).toEqual([]);
  });
});
```

#### 🟢 Green: Minimal Implementation
```javascript
export function extractKeywords(labels) {
  if (!Array.isArray(labels)) return [];
  return labels
    .filter(l => typeof l === 'string' && l.startsWith('keyword:'))
    .map(l => l.slice(8));
}
```

### Success Criteria
**Automated:**
- [x] Red → Green → all tests pass

---

### Behavior 1.5: extractEdges(labels) returns typed edge objects

**Purpose**: This extractor feeds the **click detail panel** (Phase 4) — showing typed edges grouped by type on a single card. It is NOT used for graph link construction. Graph links come from the `dependencies` SQL table, which `server.ts:114-151` already populates by synthesizing `ref:*` labels. The two data paths serve different consumers:
- `dependencies` table → **graph force-graph links** (rendering, WASM metrics)
- `extractEdges(labels)` → **card detail panel** (typed edge list in click view)

**Given**: A labels array containing `'ref:supports:zk-abc123'` and `'ref:contradicts:zk-def456'`
**When**: `extractEdges(labels)` is called
**Then**: Returns `[{ type: 'supports', targetId: 'zk-abc123' }, { type: 'contradicts', targetId: 'zk-def456' }]`

**Edge Cases**:
- No `ref:*` labels → returns `[]`
- Malformed `ref:` label (missing parts) → skip it
- Empty/null → returns `[]`

#### 🔴 Red: Write Failing Test
```javascript
describe('extractEdges', () => {
  it('extracts typed edges from ref: labels', () => {
    const edges = extractEdges([
      'ref:supports:zk-abc123',
      'scope:foo',
      'ref:contradicts:zk-def456',
    ]);
    expect(edges).toEqual([
      { type: 'supports', targetId: 'zk-abc123' },
      { type: 'contradicts', targetId: 'zk-def456' },
    ]);
  });

  it('handles ref: labels with colons in target id', () => {
    const edges = extractEdges(['ref:extends:zk-abc:extra']);
    expect(edges[0].type).toBe('extends');
    expect(edges[0].targetId).toBe('zk-abc:extra');
  });

  it('skips malformed ref: labels', () => {
    expect(extractEdges(['ref:', 'ref:supports'])).toEqual([]);
  });

  it('returns empty array when none found', () => {
    expect(extractEdges(['scope:bar'])).toEqual([]);
    expect(extractEdges(null)).toEqual([]);
  });
});
```

#### 🟢 Green: Minimal Implementation
```javascript
export function extractEdges(labels) {
  if (!Array.isArray(labels)) return [];
  const edges = [];
  for (const l of labels) {
    if (typeof l !== 'string' || !l.startsWith('ref:')) continue;
    const rest = l.slice(4); // after "ref:"
    const colonIdx = rest.indexOf(':');
    if (colonIdx < 1) continue; // need at least "type:id"
    edges.push({
      type: rest.slice(0, colonIdx),
      targetId: rest.slice(colonIdx + 1),
    });
  }
  return edges;
}
```

### Success Criteria
**Automated:**
- [x] Red → Green → all tests pass

---

### Behavior 1.6: toCard() includes all new ZK fields

**Given**: A row with labels `'["kind:hub","trunk:2","box:idea","keyword:systems","ref:supports:zk-x"]'`
**When**: `toCard(row)` is called
**Then**: Card object includes `.kind === 'hub'`, `.trunk.name === 'Social Science'`, `.box === 'idea'`, `.keywords === ['systems']`, `.edges` containing the supports edge

#### 🔴 Red: Write Failing Test
```javascript
describe('toCard — ZK enrichment', () => {
  it('includes kind, trunk, box, keywords, edges', () => {
    const row = {
      id: 'zk-hub1',
      title: 'Systems Theory Hub',
      status: 'open',
      labels: '["kind:hub","trunk:2","box:idea","keyword:systems","ref:supports:zk-x"]',
    };
    const card = toCard(row);
    expect(card.kind).toBe('hub');
    expect(card.trunk).toEqual({ number: 2, name: 'Social Science' });
    expect(card.box).toBe('idea');
    expect(card.keywords).toEqual(['systems']);
    expect(card.edges).toEqual([{ type: 'supports', targetId: 'zk-x' }]);
  });

  it('defaults new fields gracefully on empty labels', () => {
    const card = toCard({ id: 'zk-plain', title: 'Plain', status: 'open' });
    expect(card.kind).toBe('idea');
    expect(card.trunk).toBeNull();
    expect(card.box).toBe('idea');
    expect(card.keywords).toEqual([]);
    expect(card.edges).toEqual([]);
  });
});
```

#### 🟢 Green: Add to toCard()
**File**: `apps/silmari-memory-card-viewer/viewer_assets/viewmodel.js` — inside `toCard(row)`:
```javascript
kind: extractKind(labels),
trunk: extractTrunk(labels),
box: extractBox(labels),
keywords: extractKeywords(labels),
edges: extractEdges(labels),
```

#### 🔵 Refactor
Update exports at bottom of file to include all 5 new functions + `TRUNK_NAMES`.

### Success Criteria
**Automated:**
- [x] All new tests pass: `bun test apps/silmari-memory-card-viewer/viewer_assets/viewmodel.test.js`
- [x] All 15 existing tests still pass (no regressions)
- [x] New test count: ~30 total

---

╔═══════════════════════════════════════════════╗
║  PHASE 2: vocab.js — ZK Vocabulary Expansion   ║
║  Display names for kinds, edges, trunks, SAI   ║
╚═══════════════════════════════════════════════╝

## Phase 2: vocab.js — Zettelkasten Vocabulary

### Overview
Expand `vocab.js` with display names and tooltips for card kinds (11), edge types (12), and trunks (5). Add SAI branding strings. All pure data — testable as property lookups.

---

### Behavior 2.1: V.kind maps card kinds to display names and tooltips

**Given**: `V.kind.hub`
**When**: Accessed
**Then**: Returns `{ label: 'Hub', tooltip: 'Topic switchboard — aggregates links across thought chains' }`

#### 🔴 Red: Write Failing Test
**File**: `apps/silmari-memory-card-viewer/viewer_assets/vocab.test.js` (NEW FILE)
```javascript
import { describe, it, expect } from 'bun:test';
import { V } from './vocab.js';

describe('V.kind', () => {
  it('has display names for all 11 card kinds', () => {
    const kinds = ['register', 'hub', 'structure', 'fact', 'preference',
                   'biblio', 'learning', 'decision', 'idea', 'signal', 'stub'];
    for (const k of kinds) {
      expect(V.kind[k]).toBeDefined();
      expect(V.kind[k].label).toBeTruthy();
      expect(V.kind[k].tooltip).toBeTruthy();
    }
  });

  it('maps hub correctly', () => {
    expect(V.kind.hub.label).toBe('Hub');
  });

  it('maps stub correctly', () => {
    expect(V.kind.stub.label).toBe('Stub');
  });
});
```

#### 🟢 Green: Add to vocab.js
```javascript
kind: {
  register:   { label: 'Register',   tooltip: 'Index structure at trunk root — directory of hubs' },
  hub:        { label: 'Hub',        tooltip: 'Topic switchboard — aggregates links across thought chains' },
  structure:  { label: 'Structure',  tooltip: 'Argument outline — organizes a line of reasoning' },
  fact:       { label: 'Fact',       tooltip: 'Permanent factual reference — verified and stable' },
  preference: { label: 'Preference', tooltip: 'User preference or value judgment' },
  biblio:     { label: 'Biblio',     tooltip: 'Bibliographic reference — source material (Box 1)' },
  learning:   { label: 'Learning',   tooltip: 'Synthesized lesson — distilled from experience' },
  decision:   { label: 'Decision',   tooltip: 'Decision record — captures choice and rationale' },
  idea:       { label: 'Idea',       tooltip: 'Standard idea card — the default thinking unit' },
  signal:     { label: 'Signal',     tooltip: 'Raw observation — fleeting, needs development' },
  stub:       { label: 'Stub',       tooltip: 'Placeholder — needs development to unblock dependents' },
},
```

### Success Criteria
**Automated:**
- [x] Red → Green: `bun test apps/silmari-memory-card-viewer/viewer_assets/vocab.test.js`

---

### Behavior 2.2: V.edgeType maps edge types to display names and colors

**Given**: `V.edgeType.supports`
**When**: Accessed
**Then**: Returns `{ label: 'Supports', color: '#50FA7B', style: 'solid' }`

#### 🔴 Red: Write Failing Test
```javascript
describe('V.edgeType', () => {
  it('has display info for all 12 edge types', () => {
    const types = ['follows', 'continues', 'branches', 'derives-from', 'blocks',
                   'refers-to', 'annotates', 'supports', 'contradicts', 'extends',
                   'reinforces', 'refines'];
    for (const t of types) {
      expect(V.edgeType[t]).toBeDefined();
      expect(V.edgeType[t].label).toBeTruthy();
      expect(V.edgeType[t].color).toBeTruthy();
    }
  });

  it('distinguishes auto vs reviewed tiers', () => {
    expect(V.edgeType.follows.tier).toBe('auto');
    expect(V.edgeType.supports.tier).toBe('reviewed');
  });
});
```

#### 🟢 Green: Add to vocab.js
```javascript
edgeType: {
  'follows':      { label: 'Follows',      tier: 'auto',     color: '#8BE9FD', style: 'solid' },
  'continues':    { label: 'Continues',    tier: 'auto',     color: '#8BE9FD', style: 'solid' },
  'branches':     { label: 'Branches',     tier: 'auto',     color: '#6272A4', style: 'solid' },
  'derives-from': { label: 'Derives from', tier: 'auto',     color: '#6272A4', style: 'dashed' },
  'blocks':       { label: 'Blocks',       tier: 'auto',     color: '#FF5555', style: 'solid' },
  'refers-to':    { label: 'Refers to',    tier: 'auto',     color: '#6272A4', style: 'dotted' },
  'annotates':    { label: 'Annotates',    tier: 'auto',     color: '#6272A4', style: 'dotted' },
  'supports':     { label: 'Supports',     tier: 'reviewed', color: '#50FA7B', style: 'solid' },
  'contradicts':  { label: 'Contradicts',  tier: 'reviewed', color: '#FF5555', style: 'dashed' },
  'extends':      { label: 'Extends',      tier: 'reviewed', color: '#8BE9FD', style: 'solid' },
  'reinforces':   { label: 'Reinforces',   tier: 'reviewed', color: '#F1FA8C', style: 'solid' },
  'refines':      { label: 'Refines',      tier: 'reviewed', color: '#BD93F9', style: 'solid' },
},
```

### Success Criteria
**Automated:**
- [x] Red → Green: vocab tests pass

---

### Behavior 2.3: V.trunk maps trunk numbers to display info

#### 🔴 Red: Write Failing Test
```javascript
describe('V.trunk', () => {
  it('has display names for all 5 trunks + root', () => {
    expect(V.trunk[0]).toEqual({ name: 'Root', color: '#6272A4' });
    expect(V.trunk[1].name).toBe('Humanities');
    expect(V.trunk[2].name).toBe('Social Science');
    expect(V.trunk[3].name).toBe('Natural Science');
    expect(V.trunk[4].name).toBe('Formal Science');
    expect(V.trunk[5].name).toBe('Applied Science');
  });
});
```

#### 🟢 Green: Add to vocab.js
```javascript
trunk: {
  0: { name: 'Root',            color: '#6272A4' },
  1: { name: 'Humanities',      color: '#FF79C6' },
  2: { name: 'Social Science',  color: '#FFB86C' },
  3: { name: 'Natural Science', color: '#50FA7B' },
  4: { name: 'Formal Science',  color: '#8BE9FD' },
  5: { name: 'Applied Science', color: '#BD93F9' },
},
```

### Success Criteria
**Automated:**
- [x] All vocab tests pass
- [x] All viewmodel tests still pass

---

### Behavior 2.4: V.brand contains SAI branding

#### 🔴 Red: Write Failing Test
```javascript
describe('V.brand', () => {
  it('has SAI branding strings', () => {
    expect(V.brand.name).toBe('SAI');
    expect(V.brand.full).toBe('Silmari Agent Infrastructure');
    expect(V.brand.graphTitle).toBe('Knowledge Graph');
  });
});
```

#### 🟢 Green: Add to vocab.js
```javascript
brand: {
  name: 'SAI',
  full: 'Silmari Agent Infrastructure',
  graphTitle: 'Knowledge Graph',
  tagline: 'Thinking in context',
},
```

### Success Criteria
**Automated:**
- [x] All vocab tests pass: `bun test apps/silmari-memory-card-viewer/viewer_assets/vocab.test.js`
- [x] All viewmodel tests pass (no regressions)

---

╔══���════════════════════════════════════════════╗
║  PHASE 3: graph.js — Node/Link ZK Enrichment  ║
║  Color by kind, size by priority, edge styles  ║
╚═══════════════════════════════════════════════╝

## Phase 3: graph.js — Graph Node & Link Enrichment

### Overview
Wire the ZK fields from `toCard()` into graph node construction. Change the default coloring from status-based to kind-based. Change link coloring from monochrome to edge-type-based. Redesign the legend. These changes are in `graph.js` and `index.html` — the logic portions are partially testable, the rendering is manual verification.

---

### Behavior 3.1: Node color function maps card kind to color

**Given**: A node with `kind: 'hub'`
**When**: The node color function is called
**Then**: Returns the hub color from `V.kind` palette (distinct from idea, stub, etc.)

This is a function inside `graph.js` but can be extracted and tested.

#### 🔴 Red: Write Failing Test
**File**: `apps/silmari-memory-card-viewer/viewer_assets/graph-helpers.test.js` (NEW FILE)
```javascript
import { describe, it, expect } from 'bun:test';
import { kindColor, kindSize, edgeLinkColor } from './graph-helpers.js';

describe('kindColor', () => {
  it('returns distinct colors for each structural kind', () => {
    const hub = kindColor('hub');
    const register = kindColor('register');
    const idea = kindColor('idea');
    const stub = kindColor('stub');
    expect(hub).not.toBe(idea);
    expect(register).not.toBe(idea);
    expect(stub).not.toBe(idea);
  });

  it('returns default color for unknown kind', () => {
    expect(kindColor('unknown')).toBe(kindColor('idea'));
  });
});
```

#### 🟢 Green: Create graph-helpers.js
**File**: `apps/silmari-memory-card-viewer/viewer_assets/graph-helpers.js` (NEW FILE)
```javascript
/** Graph helper functions — testable, no DOM dependency */

const KIND_COLORS = {
  register:   '#FF79C6', // Pink — structural
  hub:        '#FFB86C', // Orange — structural
  structure:  '#F1FA8C', // Yellow — structural
  fact:       '#8BE9FD', // Cyan — permanent
  preference: '#8BE9FD', // Cyan — permanent
  biblio:     '#6272A4', // Muted blue — reference
  learning:   '#50FA7B', // Green — synthesized
  decision:   '#50FA7B', // Green — synthesized
  idea:       '#F8F8F2', // Foreground — default
  signal:     '#6272A4', // Muted — fleeting
  stub:       '#44475A', // Dark — undeveloped
};

export function kindColor(kind) {
  return KIND_COLORS[kind] || KIND_COLORS.idea;
}

const KIND_SIZE_MULTIPLIER = {
  register: 2.0, hub: 1.8, structure: 1.4,
  fact: 1.0, preference: 1.0, biblio: 0.9,
  learning: 1.0, decision: 1.0, idea: 1.0,
  signal: 0.7, stub: 0.6,
};

export function kindSize(kind, baseSize) {
  const mult = KIND_SIZE_MULTIPLIER[kind] || 1.0;
  return baseSize * mult;
}

export function edgeLinkColor(edgeType) {
  const EDGE_COLORS = {
    'follows': '#8BE9FD', 'continues': '#8BE9FD', 'branches': '#6272A4',
    'derives-from': '#6272A4', 'blocks': '#FF5555', 'refers-to': '#44475A',
    'annotates': '#44475A', 'supports': '#50FA7B', 'contradicts': '#FF5555',
    'extends': '#8BE9FD', 'reinforces': '#F1FA8C', 'refines': '#BD93F9',
  };
  return EDGE_COLORS[edgeType] || '#44475A';
}
```

### Success Criteria
**Automated:**
- [x] Red → Green: `bun test apps/silmari-memory-card-viewer/viewer_assets/graph-helpers.test.js`

---

### Behavior 3.2: kindSize scales nodes by structural importance

#### 🔴 Red: Write Failing Test
```javascript
describe('kindSize', () => {
  it('makes hubs larger than ideas', () => {
    expect(kindSize('hub', 10)).toBeGreaterThan(kindSize('idea', 10));
  });

  it('makes registers largest', () => {
    expect(kindSize('register', 10)).toBeGreaterThan(kindSize('hub', 10));
  });

  it('makes stubs smallest', () => {
    expect(kindSize('stub', 10)).toBeLessThan(kindSize('idea', 10));
  });
});
```

#### 🟢 Green
Already implemented in `kindSize()` above.

### Success Criteria
**Automated:**
- [x] All graph-helpers tests pass

---

### Behavior 3.3: edgeLinkColor returns edge-type-specific colors

#### 🔴 Red: Write Failing Test
```javascript
describe('edgeLinkColor', () => {
  it('colors supports edges green', () => {
    expect(edgeLinkColor('supports')).toBe('#50FA7B');
  });

  it('colors contradicts edges red', () => {
    expect(edgeLinkColor('contradicts')).toBe('#FF5555');
  });

  it('returns default for unknown type', () => {
    expect(edgeLinkColor('unknown')).toBe('#44475A');
  });
});
```

#### 🟢 Green
Already implemented in `edgeLinkColor()` above.

### Success Criteria
**Automated:**
- [x] All graph-helpers tests pass
- [x] All viewmodel tests pass
- [x] All vocab tests pass

---

### Behavior 3.4: Wire helpers into graph.js + Redesign legend

This behavior modifies `graph.js` and `index.html` directly. NOT unit-testable — manual verification.

#### Changes in graph.js:

**Node color callback** (around line 1151-1183):
- Import `kindColor` from `graph-helpers.js`
- In the default (non-heatmap, non-highlighted) branch, replace status-based coloring with `kindColor(node.kind)`
- Keep heatmap/highlight/selection overrides as-is

**Node size callback** (around line 1137-1149):
- Import `kindSize` from `graph-helpers.js`
- Multiply the existing PageRank-based size by `kindSize(node.kind, 1.0)`

**Link color callback** (around line 1341-1413):
- Import `edgeLinkColor` from `graph-helpers.js`
- In the default branch, replace `#44475a` with `edgeLinkColor(link.type)`

**Node data enrichment — INJECTION POINT: `prepareGraphData()` in `graph.js` (~line 1096)**:
- `node.labels` is already a parsed array at this point (parsed by `parseLabelsJSON()` upstream)
- Import the viewmodel extractors at the top of `graph.js`
- After the existing node construction block (~line 1096), add inline enrichment:
  ```javascript
  node.kind = extractKind(node.labels);
  node.trunk = extractTrunk(node.labels);
  node.box = extractBox(node.labels);
  node.keywords = extractKeywords(node.labels);
  node.folgezettel = extractFolgezettel(node.labels);
  // NOTE: Do NOT attach node.edges from labels here.
  // Graph links already come from the `dependencies` table with `.type` set.
  // The `extractEdges()` function is for the click detail panel only (Phase 4).
  ```
- For **link coloring**, use the existing `link.type` from dependency rows (already populated by `server.ts` synthesis), NOT re-extract from labels

#### Changes in index.html — Legend (lines 3295-3329):

Replace status-based legend with card-kind legend:

```html
<!-- Default legend: card kinds -->
<div class="space-y-1.5 text-xs">
  <div class="flex items-center gap-2">
    <span class="w-3 h-3 rounded-full" style="background: #FFB86C"></span>
    <span>Hub — topic switchboard</span>
  </div>
  <div class="flex items-center gap-2">
    <span class="w-3 h-3 rounded-full" style="background: #FF79C6"></span>
    <span>Register — trunk index</span>
  </div>
  <div class="flex items-center gap-2">
    <span class="w-3 h-3 rounded-full" style="background: #F1FA8C"></span>
    <span>Structure — argument outline</span>
  </div>
  <div class="flex items-center gap-2">
    <span class="w-3 h-3 rounded-full" style="background: #F8F8F2"></span>
    <span>Idea — standard card</span>
  </div>
  <div class="flex items-center gap-2">
    <span class="w-3 h-3 rounded-full" style="background: #44475A"></span>
    <span>Stub — needs development</span>
  </div>
</div>
```

### Success Criteria
**Automated:**
- [ ] No JS errors: open viewer in browser, check console
- [x] All test suites pass

**Manual:**
- [ ] Graph nodes colored by card kind (hubs orange, stubs dark, ideas white)
- [ ] Hub and register nodes visibly larger than idea nodes
- [ ] Stub nodes visibly smaller
- [ ] Links colored by edge type (supports green, contradicts red, follows cyan)
- [ ] Legend shows card kinds instead of status
- [ ] Heatmap mode still works (overrides kind colors with gradient)
- [ ] Selection/highlight still works (purple/gold overrides)

---

╔═══════════════════════════════════════════════╗
║  PHASE 4: Hover & Click — Progressive Disclosure ║
║  Tooltip + Detail Panel ZK enrichment            ║
╚═══════════════════════════════════════════════╝

## Phase 4: Hover Tooltip + Click Detail Panel

### Overview
Implement progressive disclosure: hover answers "where am I?" (quick context), click answers "what does this think?" (deep context). Changes are in `graph.js` (tooltip) and `index.html` (detail panel). Manual verification only — no unit tests for DOM rendering.

---

### Behavior 4.1: Hover tooltip shows ZK context

#### Changes in graph.js — showTooltip() function:

Current tooltip shows generic node info. Replace with ZK-aware tooltip:

```
┌──────────────────────────────┐
│ 🏷️ Hub  │  fz: 2/3a1        │
│ 📚 Social Science            │
│ ─────────────────────────── │
│ Systems Theory Hub            │
│ ─────────────────────────── │
│ 3 follows · 2 cross-refs     │
│ 1 contradicts                 │
└──────────────────────────────┘
```

**Implementation**: In the tooltip rendering function (or custom canvas overlay at `graph.js` handleNodeHover), compose a multi-line tooltip string from:
- `node.kind` → badge
- `node.folgezettel` → address (if present)
- `node.trunk?.name` → trunk (if present)
- `node.title` → truncated
- Edge summary: count edges by type from `node.edges`

### Success Criteria
**Manual:**
- [ ] Hover over hub card → tooltip shows "Hub" badge + fz address + trunk
- [ ] Hover over idea card → tooltip shows "Idea" badge (no trunk if none set)
- [ ] Hover over stub → tooltip shows "Stub" badge
- [ ] Edge summary shows count by type
- [ ] Gold glow on folgezettel neighborhood still works

---

### Behavior 4.2: Click detail panel shows ZK fields

#### Changes in index.html — Card Detail Modal (lines 3412-3636):

**Add ZK header section** (after existing ID/status/title, before description):

```html
<!-- ZK Context Bar -->
<div x-show="selectedIssue?.kind" class="flex flex-wrap gap-2 text-xs">
  <!-- Kind badge -->
  <span class="px-2 py-0.5 rounded-full font-medium"
        :class="kindBadgeClass(selectedIssue.kind)"
        x-text="V.kind[selectedIssue.kind]?.label || selectedIssue.kind">
  </span>
  <!-- Folgezettel address -->
  <span x-show="selectedIssue?.folgezettel"
        class="px-2 py-0.5 rounded bg-gray-700 font-mono"
        x-text="'fz: ' + selectedIssue?.folgezettel">
  </span>
  <!-- Trunk badge -->
  <span x-show="selectedIssue?.trunk"
        class="px-2 py-0.5 rounded"
        :style="'background:' + (V.trunk[selectedIssue?.trunk?.number]?.color || '#6272A4') + '33'"
        x-text="selectedIssue?.trunk?.name">
  </span>
  <!-- Box indicator -->
  <span x-show="selectedIssue?.box === 'biblio'"
        class="px-2 py-0.5 rounded bg-blue-900 text-blue-300">
    Biblio
  </span>
</div>
```

**Replace "Blocked By"/"Blocks" with typed edge list** (lines 3540-3599):

```html
<!-- Typed Edges -->
<div x-show="selectedIssue?.edges?.length > 0">
  <h4 class="text-sm font-medium mb-2">Connections</h4>
  <template x-for="edgeGroup in groupEdgesByType(selectedIssue.edges)" :key="edgeGroup.type">
    <div class="mb-2">
      <span class="text-xs font-medium"
            :style="'color:' + (V.edgeType[edgeGroup.type]?.color || '#6272A4')"
            x-text="V.edgeType[edgeGroup.type]?.label || edgeGroup.type">
      </span>
      <span class="text-xs text-gray-500" x-text="'(' + edgeGroup.items.length + ')'"></span>
      <div class="ml-2 space-y-1">
        <template x-for="edge in edgeGroup.items" :key="edge.targetId">
          <button @click="showIssue(edge.targetId)"
                  class="text-xs text-blue-400 hover:text-blue-300 block"
                  x-text="edge.targetId">
          </button>
        </template>
      </div>
    </div>
  </template>
</div>
```

**Add keywords section** (after edges):

```html
<!-- Keywords -->
<div x-show="selectedIssue?.keywords?.length > 0">
  <h4 class="text-sm font-medium mb-2">Keywords</h4>
  <div class="flex flex-wrap gap-1">
    <template x-for="kw in selectedIssue.keywords" :key="kw">
      <span class="px-2 py-0.5 rounded bg-purple-900 text-purple-300 text-xs"
            x-text="kw.replace(/_/g, ' ')">
      </span>
    </template>
  </div>
</div>
```

**Add helper function to viewer.js**:

```javascript
groupEdgesByType(edges) {
  if (!edges?.length) return [];
  const groups = {};
  for (const e of edges) {
    (groups[e.type] ??= []).push(e);
  }
  return Object.entries(groups).map(([type, items]) => ({ type, items }));
}
```

### Success Criteria
**Manual:**
- [ ] Click hub card → shows "Hub" badge, fz address, trunk name, orange accent
- [ ] Click biblio card → shows "Biblio" badge with box indicator
- [ ] Click card with edges → typed edge list grouped by type with colored labels
- [ ] Click edge target → navigates to that card
- [ ] Click card with keywords → shows keyword chips
- [ ] Existing "Description" markdown still renders
- [ ] Existing "What-If" simulation still works
- [ ] Graph metrics grid still visible

---

## Phase 5: Sync to secondary viewer_assets

### Overview
After all changes verified in `apps/silmari-memory-card-viewer/viewer_assets/`, sync modified files to `apps/silmari-viewer/pkg/export/viewer_assets/` so the Go export pipeline stays in sync.

**Files to sync**:
- `viewmodel.js`
- `viewmodel.test.js`
- `vocab.js`
- `vocab.test.js` (new)
- `graph-helpers.js` (new)
- `graph-helpers.test.js` (new)
- `graph.js`
- `index.html`

### Success Criteria
**Automated:**
- [x] `diff -r apps/silmari-memory-card-viewer/viewer_assets/{viewmodel,vocab,graph-helpers}.js apps/silmari-viewer/pkg/export/viewer_assets/` shows no differences
- [x] `bun test apps/silmari-viewer/pkg/export/viewer_assets/viewmodel.test.js` passes

---

## Integration & E2E Testing

### Integration Scenarios:
1. **Full pipeline**: Export beads DB → load in viewer → verify ZK fields appear on nodes
2. **Edge synthesis**: `server.ts` synthesizes `ref:*` labels into dependency rows → verify link colors match edge types
3. **Legend + heatmap interaction**: Toggle heatmap on/off → legend switches between kind-based and metric-gradient

### Manual E2E Test Steps:
1. Start viewer: `bun run apps/silmari-memory-card-viewer/server.ts`
2. Open browser → verify graph loads with kind-based coloring
3. Identify a hub card → verify it's larger and orange
4. Identify a stub card → verify it's smaller and dark
5. Hover hub → verify tooltip shows kind badge + fz address + trunk + edge counts
6. Click hub → verify detail panel shows ZK context bar + typed edge list + keywords
7. Click an edge target → verify navigation works
8. Toggle heatmap (`h`) → verify colors switch to gradient, legend updates
9. Toggle back → kind colors restore
10. Check all 5 view modes (1-5) → no crashes, kind colors persist

## References

- Research: `thoughts/shared/research/2026-04-12-beads-viewer-zettelkasten-graph-redesign.md`
- Zettelkasten methodology: `Research/001_actual-zettelkasten-method.md`
- Prior viewer planning: `Plans/research/2026-04-11-silmari-memory-card-viewer-planning.md`
- Card data model: `apps/silmari-mcp/src/lib/labels.ts`, `card-ops.ts`, `folgezettel.ts`, `edges.ts`
- Live viewer: `apps/silmari-memory-card-viewer/viewer_assets/`
- Go viewer: `apps/silmari-viewer/pkg/export/viewer_assets/`
- Existing tests: `apps/silmari-memory-card-viewer/viewer_assets/viewmodel.test.js`
