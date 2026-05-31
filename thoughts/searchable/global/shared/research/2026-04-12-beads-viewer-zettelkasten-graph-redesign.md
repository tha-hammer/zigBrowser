---
date: 2026-04-12T17:30:00-05:00
researcher: Silmari
git_commit: 34f563102086552119b07596d894ba4717b2fb1e
branch: main
repository: silmari-agent-memory
topic: "Beads Viewer Zettelkasten Graph Redesign — SAI Branding, Card Model, Thinking-Tool UX"
tags: [research, beads-viewer, zettelkasten, graph, UX, silmari-viewer, cards, legend, heatmap, hover, click]
status: complete
last_updated: 2026-04-12
last_updated_by: Silmari
---

# Research: Beads Viewer Zettelkasten Graph Redesign

**Date**: 2026-04-12T17:30:00-05:00
**Researcher**: Silmari
**Git Commit**: 34f5631
**Branch**: main
**Repository**: silmari-agent-memory

## Research Question

Study the beads_viewer to understand how to revise it for SAI branding and Zettelkasten methodology. Analyze the card data model, graph visualization, legend, search, heatmap, and the difference between mouseover and click interactions — to inform making the Graph view a useful "thinking tool."

---

## Summary

The silmari-viewer (forked from beads_viewer) is a sophisticated Go + WASM + Alpine.js SPA that visualizes a bead database as an interactive force-directed graph. It was designed for **issue-tracker workflows** (blockers, priorities, burndown) and has been partially rebranded to card/Zettelkasten vocabulary via `vocab.js`. The graph engine is powerful (PageRank, betweenness, k-core, critical path, cycle detection, what-if simulation) but its mental model is **project management**, not **thinking navigation**. The Zettelkasten data model (folgezettel addresses, 5 trunks, 11 card kinds, 12 typed edges, keyword index, hub/register/structure cards, dual-graph topology) is rich but almost none of it surfaces in the viewer today — `viewmodel.js` extracts `.scope` and `.folgezettel` from labels but nothing in the templates consumes them.

---

## Detailed Findings

### 1. Current Graph Architecture

**Library**: Force-Graph (3D-force-graph) wrapping D3.js v7
**WASM Engine**: `bv-graph-wasm` (Rust) computing PageRank, betweenness, critical path, eigenvector, k-core, HITS, slack, articulation points, cycles
**File**: `apps/silmari-viewer/viewer_assets/graph.js` (128 KB)
**File**: `apps/silmari-viewer/viewer_assets/viewer.js` (109 KB)  
**File**: `apps/silmari-viewer/viewer_assets/index.html` (312 KB)

#### 1.1 Five View Modes (graph.js:72-78, 102-202)

| Key | Mode | Layout | Mental Model |
|-----|------|--------|--------------|
| `1` | FORCE | Physics simulation | Default — everything floats |
| `2` | HIERARCHY | Top-down tree | Dependency chains |
| `3` | RADIAL | Emanates from center | Ego-centric view |
| `4` | CLUSTER | Groups by status | Sprint planning |
| `5` | LABEL_GALAXY | Groups by label, convex hulls | Tag clustering |

None of these map to Zettelkasten navigation patterns (folgezettel tree traversal, trunk separation, entry-point → neighborhood → cross-reference surfing).

#### 1.2 Node Construction (graph.js:1036-1119)

Each node carries:
- `id`, `title`, `description`, `status`, `priority`, `type`, `labels`, `assignee`
- WASM-computed: `pagerank`, `betweenness`, `criticalDepth`, `eigenvector`, `kcore`, `inCycle`, `blockerCount`, `dependentCount`

**Missing from nodes**: `folgezettel` address, `trunk`, `kind`, `box`, `scope`, `content_hash`, `keywords`, edge type distinctions.

#### 1.3 Link Construction (graph.js:1075-1081)

Links are `{ source, target, type }` from the `dependencies` table. The server supports 12 edge types (`blocks`, `follows`, `continues`, `branches`, `derives-from`, `refers-to`, `annotates`, `supports`, `contradicts`, `extends`, `reinforces`, `refines`) but the graph treats ALL edges identically for layout — only `blocks` is distinguished for DAG analytics.

---

### 2. Current Legend (graph.js:3042-3195, index.html:3295-3329)

**Default (status-based):**
- Green = Open
- Yellow = In Progress
- Gray = Closed
- Red = Blocked

**Heatmap mode:**
- Green-to-red gradient by: PageRank, Betweenness, Critical Depth, or In-degree

**Label Galaxy mode:**
- 10 colorblind-friendly colors assigned to labels
- Convex hulls with label names at centroids

**What's absent**: No legend for card kind (hub, structure, register, idea, stub), no legend for edge types, no trunk coloring, no folgezettel depth indicator.

---

### 3. Current Search & Find (graph.js:2429-2430, viewer.js:1170)

**Graph search** (`Ctrl+F`): Case-insensitive substring match on id, title, description.

**List search**: Text mode (FTS5 full-text) or Hybrid mode (text + graph metrics weighted by presets: bug-hunting, sprint-planning, impact-first).

**Filters**: Status, Type, Priority, Labels, Assignee, hasBlockers, isBlocking.

**What's absent**: No keyword-index search (the Zettelkasten Layer 1), no folgezettel address search (find `2/3a1` and its neighborhood), no trunk filter, no card-kind filter, no edge-type filter, no "show me the neighborhood of this card" as a search mode.

---

### 4. Current Heatmap (graph.js:372-395, 443-448)

Toggle with `h`. Colors nodes green-to-red by one of 4 metrics:
- `pagerank` — importance
- `betweenness` — bottleneck
- `critical` — critical path depth
- `indegree` — blocker count

Link coloring by slack (schedule flexibility): red (urgent) → cyan (relaxed).

**What's absent**: No heatmap by card kind maturity, no folgezettel depth gradient, no "density of cross-references" heat (which would highlight hub cards), no "age since last touched" heat, no "stub density" view to find underdeveloped branches.

---

### 5. Current Mouseover vs Click (graph.js:1556-1605)

#### On Mouseover (handleNodeHover, line 1583)
- Sets `store.hoveredNode`
- **Gold glow**: 2-hop BFS neighborhood highlighted with golden radial gradient
- Connected links glow gold
- Non-connected nodes dim to 0.2 opacity
- Shows tooltip (node info)
- Cursor → pointer

#### On Click (handleNodeClick, line 1556)
- **Regular click**: Select node → purple highlight, 3px border. Opens detail panel showing:
  - ID, status, priority, title
  - Type & labels (as purple chips)
  - Full description (markdown rendered)
  - **Graph metrics grid**: PageRank, Betweenness, Critical Depth, Triage Score
  - **Dependencies**: "Blocked By" list + "Blocks" list + Mermaid diagram toggle
  - **What-If**: "Simulate Close" button → shows cascade unblocks
- **Shift+click**: What-If simulation (simulates closing, shows green/cyan cascade)
- **Ctrl/Cmd+click**: Highlight dependency path (traces recursively)
- **Right-click**: Context menu event

#### What's absent from hover
No folgezettel address shown. No trunk/kind indicators. No edge-type labels on connecting links. No "thought chain" context (parent → siblings → children in the folgezettel tree). No keyword associations.

#### What's absent from click detail
No folgezettel address or tree position. No card kind badge. No trunk assignment. No box indicator. No cross-reference list with typed edges. No keyword list. No "Navigate to parent/sibling/child" buttons. No "entry point for keywords" section. No source attribution. No content hash or dedup info.

---

### 6. Silmari Card Data Model (What's Available to Display)

From `apps/silmari-mcp/src/lib/`:

#### 6.1 Card Fields

| Field | Source | Currently Displayed? | Viewer Potential |
|-------|--------|---------------------|-----------------|
| `id` | bead id | Yes | Keep |
| `title` | first 200 chars | Yes | Keep |
| `body` | description.body | Yes (as description) | Keep — full markdown |
| `status` | lifecycle | Yes | Remap to ZK lifecycle |
| `priority` | kind-based (0-4) | Yes (as P0-P3+) | Remap to maturity gradient |
| `folgezettel` | `fz:` label | Extracted, NOT displayed | **Critical** — address IS the relationship |
| `kind` | `kind:` label | NOT displayed | **Critical** — 11 types with different roles |
| `trunk` | `trunk:` label | NOT displayed | **Critical** — 5 academic disciplines |
| `box` | `box:` label | NOT displayed | Important — biblio vs idea |
| `scope` | `scope:` label | Extracted, NOT displayed | Important — thematic grouping |
| `keywords` | `keyword:` labels | NOT displayed | **Critical** — Layer 1 retrieval entry points |
| `edges` | `ref:` labels | NOT displayed as typed | **Critical** — 12 edge types collapsed to generic links |
| `source` | `source:` label | NOT displayed | Useful — provenance |
| `content_hash` | `content_hash:` label | NOT displayed | Internal — dedup |
| `created_at` | timestamp | Yes | Keep |
| `updated_at` | timestamp | Yes | Keep |

#### 6.2 Card Kinds (11 types, maturity gradient)

| Kind | Priority | Role in Zettelkasten | Visual Treatment Needed |
|------|----------|---------------------|------------------------|
| `register` | 0 | Index at trunk root (reserved fz: N/0) | Large, distinct shape — "directory" |
| `hub` | 0 | Topic switchboard (up to 25 links) | Large, visually prominent — "nexus" |
| `structure` | 0 | Argument outline | Medium, structured look — "blueprint" |
| `fact` | 1 | Permanent factual reference | Solid, stable — "stone" |
| `preference` | 1 | User preference | Solid — "compass" |
| `biblio` | 1 | Bibliographic reference (Box 1) | Distinct from idea cards — "book" |
| `learning` | 2 | Synthesized lesson | Medium — "lightbulb" |
| `decision` | 2 | Decision record | Medium — "gavel" |
| `idea` | 2 | Standard idea card | Default — "card" |
| `signal` | 3 | Raw observation (fleeting) | Faint — "spark" |
| `stub` | 4 | Placeholder needing development | Dashed/hollow — "seed" |

#### 6.3 Edge Types (12 types, 2 tiers)

| Type | Tier | Visual Treatment Needed |
|------|------|------------------------|
| `follows` | AUTO | Folgezettel continuation — **thick, directional** |
| `continues` | AUTO | Sibling sequence — **medium, directional** |
| `branches` | AUTO | Sub-thought — **medium, angled** |
| `derives-from` | AUTO | Causal origin — **dashed** |
| `blocks` | AUTO | Dependency — **red, bold** (existing) |
| `refers-to` | AUTO | General mention — **thin, gray** |
| `annotates` | AUTO | Meta-edge — **dotted** |
| `supports` | REVIEWED | Evidence — **green** |
| `contradicts` | REVIEWED | Disconfirming — **red, crossed** |
| `extends` | REVIEWED | Nuance — **blue** |
| `reinforces` | REVIEWED | Restatement — **gold, double** |
| `refines` | REVIEWED | Specialization — **purple** |

#### 6.4 The Three-Layer Retrieval

| Layer | What | How to Surface in Graph |
|-------|------|------------------------|
| 1. Keyword Index | Sparse entry points (1 per 20 cards) | Search by keyword → highlight entry-point cards → glow neighborhood |
| 2. Folgezettel Navigation | Parent/sibling/child by address | Show tree structure, allow "surf" along folgezettel chain |
| 3. Cross-References | Typed edges to distant cards | Color-coded link types, "jump across" visual distinction |

---

### 7. Existing Vocabulary Layer

**File**: `apps/silmari-viewer/pkg/export/viewer_assets/vocab.js` (or `apps/silmari-memory-card-viewer/viewer_assets/vocab.js`)

Current mappings (already rebranded from Issues→Cards):

| Internal | Display |
|----------|---------|
| Issues | Cards |
| Search issues | Search notes... |
| Blocked by | Builds on |
| Blocks | Leads to |
| In Progress | In Progress |
| Status tooltips | ZK-flavored (e.g., "Developable. Part of the library.") |

**Not yet mapped**: Card kinds, edge types, trunks, folgezettel terminology, keyword index, hub/register/structure roles.

---

### 8. viewmodel.js — Already Extracts But Doesn't Surface

**File**: `apps/silmari-viewer/pkg/export/viewer_assets/viewmodel.js`

`toCard(row)` (lines 38-60) already produces:
- `.scope` — extracted from `scope:*` label
- `.folgezettel` — extracted from `fz:*` label
- `.isStub` — checks `kind:stub` in labels
- `.tags` — all parsed labels

But the HTML templates in `index.html` only consume: `id`, `title`, `lifecycle`, `isStub`, `priority`, `linksOut`, `linksIn`, `createdAt`, `updatedAt`. The `.scope` and `.folgezettel` fields flow through the pipeline but are never rendered.

---

### 9. Thinking-Tool Design Considerations from Zettelkasten Research

From `Research/001_actual-zettelkasten-method.md`:

#### 9.1 The Dual Graph IS the Thinking Tool

> "The tree gives you a way IN, the network gives you a way ACROSS"

The graph view should distinguish two topological layers:
1. **Folgezettel tree** (spanning forest) — local coherence, thought chains, parent→child sequences
2. **Cross-references** (general graph) — global connections, surprise, serendipity

Currently the viewer collapses both into one flat force-directed graph.

#### 9.2 Navigation, Not Retrieval

> "After finding his entry point, Luhmann relied on the linking system and began to surf."

The workflow is: **keyword → entry card → follow local chains → jump via cross-reference → follow new chains → repeat.** The graph should support this "surfing" pattern, not just static visualization.

#### 9.3 The Address IS the Relationship

> Card `21/3a1p5` tells you topic cluster 21, branch 3, continuation a, sub-branch 1, continuation p, sub-branch 5 — the entire genealogy of the idea.

Folgezettel addresses should be visually prominent. The depth of an address indicates depth of elaboration. The prefix shared between two addresses indicates their conceptual distance.

#### 9.4 Hub Cards as Switchboards

> Hub notes aggregate pointers, serving as switchboards. Following a cross-reference JUMPS you across the tree.

Hub cards should be visually distinct and prominently sized — they are the "airports" of the graph.

#### 9.5 Sparse Keyword Index as Entry Points

> The term "system" — central to Luhmann's entire life's work — had a SINGLE entry.

Keywords are not tags. They are curated entry points into the graph. A keyword search should highlight the 1-4 entry-point cards and then expand to show their neighborhoods.

#### 9.6 Communication Partner — Surprise Matters

> "One of the most basic presuppositions of communication is that the partners can mutually surprise each other."

The graph should surface **unexpected connections** — cross-references between distant trunks, contradictions, ideas that reinforced each other across different contexts. The `contradicts` and `reinforces` edge types are high-signal.

---

### 10. Mouseover vs Click — What Should Change

Based on the Zettelkasten model, there's a natural **progressive disclosure** pattern:

#### Hover (Quick Context — "Where am I?")

The hover should answer: **"What IS this card and where does it SIT?"**

| Current Hover | Zettelkasten Hover |
|---------------|-------------------|
| Gold glow on 2-hop neighborhood | Gold glow on **folgezettel neighborhood** (parent, siblings, children) |
| Generic tooltip | **Card kind badge** + **folgezettel address** + **trunk name** |
| All connections shown equally | **Folgezettel edges** highlighted differently from **cross-references** |
| No direction/flow indication | Show the **thought chain direction** (parent above, children below) |

Hover should show:
- `[kind] fz:2/3a1 — Trunk: Social Science`
- Title (truncated)
- Edge count by type (e.g., "3 follows, 2 cross-refs, 1 contradicts")
- The immediate **folgezettel chain** (parent → this → children) lit up

#### Click (Deep Context — "What does this card THINK?")

The click should answer: **"What is this idea, how does it connect, and where can I go next?"**

| Current Click | Zettelkasten Click |
|---------------|-------------------|
| ID, status, priority, title | **Folgezettel address**, kind badge, trunk badge, title |
| Description (markdown) | Body (markdown) — same |
| Graph metrics (PageRank, Betweenness, ...) | **Folgezettel position** (depth, parent chain) + **cross-ref summary** |
| "Blocked By" / "Blocks" lists | **Typed edge list** grouped by type (follows, supports, contradicts...) |
| What-If simulation | **Navigate**: "Go to parent", "Next sibling", "First child", "Jump to cross-ref" |
| — | **Keywords** this card is an entry point for |
| — | **Source** attribution |
| — | **Box** indicator (biblio vs idea) |

---

### 11. Legend Redesign Considerations

| Current Legend | Zettelkasten Legend |
|---------------|-------------------|
| Status: Open/InProgress/Closed/Blocked | **Card Kind**: hub(large)/structure/register/idea/stub(dashed)/biblio/signal... |
| Heatmap: PageRank/Betweenness/Critical/InDeg | **Heatmap by**: Cross-ref density / Stub ratio / Card age / Folgezettel depth |
| Label Galaxy: color-by-label | **Trunk Galaxy**: color by 5 academic disciplines + cross-trunk bridges |
| — | **Edge Types**: Legend showing all 12 edge types with their visual styles |

---

### 12. Search Redesign Considerations

| Current Search | Zettelkasten Search |
|---------------|-------------------|
| Free-text on title/description | Layer 1: **Keyword index** search (curated entry points) |
| Hybrid: text + graph metrics | Layer 2: **Folgezettel address** search (`2/3a*` → show branch) |
| Filter by status/type/priority | Filter by **trunk**, **kind**, **box**, **edge type** |
| — | **"Surf from here"**: select card → expand neighborhood progressively |
| — | **Cross-trunk bridges**: show cards that connect different disciplines |

---

### 13. Heatmap Redesign Considerations

| Current Heatmap Metric | Zettelkasten Equivalent | What It Reveals |
|------------------------|------------------------|-----------------|
| PageRank | **Cross-reference density** | Hub cards — the switchboards |
| Betweenness | **Bridge score** | Cards connecting distant thought-chains |
| Critical Depth | **Folgezettel depth** | How deep the elaboration goes |
| In-degree | **Inbound typed edges** | Most-referenced ideas |
| — (new) | **Stub density** | Branches with many undeveloped placeholders |
| — (new) | **Contradiction hotspots** | Cards with `contradicts` edges — unresolved tensions |
| — (new) | **Age since last touch** | Forgotten cards (Luhmann's "rediscovery" mechanism) |
| — (new) | **Reinforcement count** | Ideas confirmed across multiple contexts |

---

## Code References

- `apps/silmari-memory-card-viewer/viewer_assets/graph.js` — 128KB graph engine
- `apps/silmari-memory-card-viewer/viewer_assets/viewer.js` — 109KB Alpine.js SPA
- `apps/silmari-memory-card-viewer/viewer_assets/index.html` — 312KB SPA shell
- `apps/silmari-memory-card-viewer/viewer_assets/vocab.js` — Vocabulary mappings
- `apps/silmari-memory-card-viewer/viewer_assets/viewmodel.js` — Card transforms (scope/fz extraction)
- `apps/silmari-mcp/src/lib/labels.ts` — Label system, card kinds, edge types
- `apps/silmari-mcp/src/lib/folgezettel.ts` — Folgezettel address parsing
- `apps/silmari-mcp/src/lib/card-ops.ts` — Card operations, kind priorities
- `apps/silmari-mcp/src/lib/edges.ts` — Link proposal queue
- `Research/001_actual-zettelkasten-method.md` — Foundational Zettelkasten research

## Architecture Documentation

The viewer is a two-layer system:
1. **Go CLI** (`apps/silmari-viewer/cmd/bv/`) exports beads DB to static SQLite + JSON
2. **SPA** (`viewer_assets/`) renders in-browser using SQL.js WASM + Force-Graph + Alpine.js

The vocabulary layer (`vocab.js`) maps internal issue-tracker terms to card terms. The view model (`viewmodel.js`) extracts Zettelkasten fields from labels. The graph engine (`graph.js`) computes WASM metrics and renders. **The data pipeline already carries Zettelkasten data through — but the presentation layer doesn't surface it.**

## Historical Context

- `Plans/research/2026-04-11-silmari-memory-card-viewer-planning.md` — Three-track planning doc (Track A: UI delta, Track B: edge extraction, Track C: beads_rust workarounds). Recommended A1+A2 for alpha, A3 after store decision.
- `Research/001_actual-zettelkasten-method.md` — 9-section deep research on actual Zettelkasten methodology, explicitly correcting v1's embedding-overlay error.
- Prior research on Phase 2 (three-layer retrieval) and Phase 4 (migration) established the card model and 255-card corpus.

## Related Research

- `thoughts/shared/research/2026-04-12-sai-installation-audit.md` — SAI branding audit (AAI→SAI complete)
- `thoughts/shared/research/2026-04-12-zk-recall-by-status-zk-promote-implementation.md` — MCP tool implementation

## Open Questions

1. Should the viewer consume the silmari-mcp SQLite directly, or should there be an export/sync step that materializes the Zettelkasten graph structure into the beads-viewer format?
2. How should the 5 trunks be color-coded? (Academic discipline colors are not standardized.)
3. Should the "surfing" pattern be interactive (click-to-expand neighborhood) or pre-rendered (show full local neighborhood on hover)?
4. Should folgezettel tree layout be a new 6th view mode, or should it replace one of the existing 5?
5. How to handle the biblio box cards — should they appear in the graph at all, or only as reference links from idea cards?
