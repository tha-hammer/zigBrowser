---
date: 2026-04-18T18:40:00-0400
researcher: Maceo Jourdan
git_commit: 1d9024022cd4d8433f36126f2449f4d62740ffd8
branch: main
repository: tha-hammer/silmari-agent-memory
topic: "Dual-layer graph — current implementation, ideal-state research, design, adversarial"
tags: [research, design, viewer, graph, zettelkasten, folgezettel, semantic-substrates, luhmann, adversarial]
status: complete
last_updated: 2026-04-19
last_updated_by: Maceo Jourdan
last_updated_note: "Corrected §1.7 and §4.1 steelman #3 — conflated zk_status.hubs (formal registry, =0) with cards carrying kind:hub label (=28). Substrate design is viable on current data; steelman #3 withdrawn."
---

# Dual-layer Graph — Research & Design (with Adversarial Guard)

**Date**: 2026-04-18 18:40 ET · **Commit**: `1d90240` · **Branch**: main

---

## 🎯 Research Question

> "Real dual-layer graph research: the existing implementation, the research to understand the IDEAL STATE, and design for that. The adversarial take should guard against overengineering."

---

## 🧭 Headline Finding

**The framing "dual-layer graph = tree + graph" is itself the first overengineering trap.** The strongest community ([Doto 2024](https://writing.bobdoto.computer/folgezettel-is-not-an-outline-luhmanns-playful-appreciation-of-disfunction/), [zettelkasten.de](https://zettelkasten.de/posts/luhmann-folgezettel-truth/)) and academic sources ([Schmidt 2018](https://sociologica.unibo.it/article/download/8350/8272/26621)) argue that folgezettel was *not* a strict parent-child tree — it was Luhmann's adaptation to paper constraints, a trace designed to *break linearity* for serendipity. The real structure of a Luhmann-faithful Zettelkasten lives in **hub cards** (structure notes), **typed cross-references**, and the **keyword register** — not in folgezettel addressing.

**Implication for silmari.** The viewer does not need a tree-layout pass over `follows`/`branches` edges. It needs a **semantic substrate** ([Shneiderman & Aris 2006](https://www.cs.umd.edu/~ben/papers/Shneiderman2006Network.pdf)) where hub/structure cards define regions, ordinary cards sit within their hub's region, and typed cross-refs overlay as the discovery layer. Silmari already has `kind:hub` and `kind:structure` in the data model — it just doesn't use them structurally. The right redesign surfaces the structure the user already encodes.

**This reframes "dual-layer."** Layer 1 = **curated substrate** (hubs as regions, trunks as super-regions). Layer 2 = **semantic overlay** (typed cross-references). Folgezettel becomes a trace visible on hover/filter, not the spine.

---

## 📚 Section 1 — Current Implementation (exact citations)

Source: deep-dump by Explore agent + direct reads of `graph.js`, `graph-helpers.js`, `link-builder.js`, `viewmodel.js`, `bv-graph-wasm/src/graph.rs`.

### 1.1 Layout = single merged force simulation

- `initGraph()` at `apps/silmari-memory-card-viewer/viewer_assets/graph.js:789-934` creates one `ForceGraph()` instance (line 805), binds D3 forces: charge+link+center+x/y+collision (lines 865-877).
- `LB.buildLinks()` at `link-builder.js:17-35` **unions** `dependencies` (blocks-only) with `card_edges` (11 semantic types) into a single array — all edges fed to one force pass.
- `applyHierarchyLayout()` at `graph.js:2537-2544` forces Y by `criticalDepth` (a DAG metric), **not by folgezettel address**.
- 5 declared view modes in `VIEW_MODES` at `graph.js:72-78`: `force`, `hierarchy`, `radial`, `cluster`, `label_galaxy`. All run on the merged edge set.

### 1.2 Edge-type differentiation is purely visual

- `GH.edgeLinkColor(type)` at `graph-helpers.js:62-64` maps each of 12 types to a hex color.
- `getLinkColor()` at `graph.js:1368-1444` applies a 7-priority override cascade (what-if, critical-path, highlight, gold-glow, cycle, cross-label, heatmap) and falls through to per-type color at line 1440-1441.
- `getLinkWidth()` at `graph.js:1474-1518` scales width by metric importance (70% PageRank + 30% betweenness); type has no influence.
- No edge *layout* differentiation. A `follows` edge and a `supports` edge exert the same spring force.

### 1.3 Folgezettel is decorative

- `VM.extractFolgezettel()` at `viewmodel.js:150-158` parses `fz:<addr>` labels.
- Used in node enrichment at `graph.js:1115`.
- Rendered **only** in the tooltip (`index.html:3021`) and detail-panel badge (`index.html:3481-3483`).
- `grep folgezettel apps/silmari-memory-card-viewer/viewer_assets/graph.js` confirms zero references inside layout functions.

### 1.4 WASM boundary is type-agnostic & blocks-only

- `bv-graph-wasm/src/graph.rs:10-27`: `DiGraph` stores `adj: Vec<Vec<usize>>` — no edge-type field.
- `buildWasmGraph()` at `graph.js:666-706`: filters dependencies to `type === 'blocks'` (line 690-692) before calling `addEdge`. All WASM analytics (PageRank, betweenness, critical-path, k-core, cycles) compute over the DAG subset only.
- `computeMetrics()` at `graph.js:708-783` runs 9 algorithms from `pkg/algorithms/*.rs`: PageRank, eigenvector, betweenness, HITS, critical-path, slack, k-core, articulation, cycles. All blocks-only, none type-aware.

### 1.5 Hub/structure cards exist in data but have no structural render treatment

- `VM.extractKind()` at `viewmodel.js:166-172` extracts `kind:hub` / `kind:structure` / etc.
- `GH.kindSize()` at `graph-helpers.js:40-43` sizes: hub=1.8×, register=2.0×, structure=1.4×, stub=0.6×.
- `GH.kindColor()` at `graph-helpers.js:27-29` gives each kind a color.
- **Size and color are the ONLY differentiation.** Hubs sit randomly inside the force layout like any other node. The user's curation intent is not expressed in the layout.

### 1.6 LOD is absent

- All edges render at every zoom. No edge-culling or progressive reveal code in `graph.js` (grep confirms). Result: at zoom-out, dense areas become visual noise.

### 1.7 Structural-kind inventory (CORRECTED 2026-04-19)

**Initial claim in this doc was wrong.** I originally wrote "hubs: 0, structures: 0 — substrate data absent" based on `zk_status` output. That counter tracks a separate formal-registry concept (entities created via `zk_hub_create`/`zk_structure_create`/`zk_keyword_add`), NOT cards with a `kind:hub`/`kind:structure`/`kind:register` label. A direct query of the `labels` table shows the actual substrate inventory:

```
kind:hub          28      ← substrate region anchors (orange nodes)
kind:register      6      ← trunk indexes (pink nodes)
kind:structure     1      ← argument outlines (yellow)
kind:learning    109
kind:fact         70
kind:preference   26
kind:signal       26
kind:idea         21
kind:decision      6
```

**Substrate implementability is NOT blocked.** 35 structural-kind cards exist today — enough to anchor regions. The steelman in §4.1 #3 is withdrawn (see §4.1 for the correction).

**Caveat.** `zk_status.hubs = 0` is still a real signal — it means no hubs have been promoted through the formal `zk_hub_create` registry. The design can use either signal (kind-label presence OR formal-registry membership) as the "this card anchors a region" input.

**Single-class-edge gap vs. Luhmann's intended distinction.** The code merges structural ordering edges (`follows`, `branches`, `derives-from`) with semantic reference edges (`supports`, `contradicts`, `refers-to`) into one force pass. That is the layout-level equivalent of treating a URL's `<hr>` and its `<a>` as the same kind of thing. The user sees a ball of string because the two edge classes cancel each other — structural edges pull a card to its lineage while semantic edges pull it toward whoever cited it, and the sim lands on the compromise.

---

## 🧠 Section 2 — Ideal State (with citations)

### 2.1 What Luhmann actually did (cited)

- **Folgezettel is a trace, not a tree.** "[It] doesn't follow from Luhmann's principles but rather came as a consequence of him having to deal with a physical Zettelkasten… it is not important where you store a Zettel as long as you can reference it from every other point." — [zettelkasten.de](https://zettelkasten.de/posts/luhmann-folgezettel-truth/)
- **Folgezettel deliberately breaks linearity.** "Breaking linear sequences is a feature, not a bug… new insertions between existing notes intentionally disrupt proximity." — [Doto 2024](https://writing.bobdoto.computer/folgezettel-is-not-an-outline-luhmanns-playful-appreciation-of-disfunction/)
- **Schmidt (2018) formalization.** The numbering alternates numbers and letters but "Luhmann sometimes violated this rule due to additional insertions of branch cards in existing sequences; furthermore there was no general rule that the main line of argument is numbered consecutively." [Schmidt, *Sociologica* 12(1): 53-60](https://sociologica.unibo.it/article/download/8350/8272/26621). Folgezettel is branching-but-not-strict — every card has at most one immediate predecessor, but the "parent" relation is often semantically arbitrary.
- **Real structure lives elsewhere.** Schmidt and Doto both identify the **structure notes** (what silmari calls `kind:hub` / `kind:structure`) and the **keyword register** (`Schlagwortverzeichnis` — silmari's `kind:register`) as the actual organizing layer. Folgezettel was the filing system; structure notes were the thinking.
- **Digital Luhmann Archive.** [niklas-luhmann-archiv.de](https://niklas-luhmann-archiv.de/bestand/zettelkasten/tutorial) renders the ~90k-card archive as a tree navigator in the left pane and the card content in the right pane. It *does not* render a force-directed graph. The tree IS the navigation; the crossrefs are inline links.

### 2.2 Prior-art survey (does the tool render tree + graph as distinct visual layers?)

| Tool | Tree visible? | Graph visible? | Distinct layers? |
|---|---|---|---|
| **Obsidian** | File tree in sidebar (folder-based) | Force-directed graph view | **No** — tree and graph are separate tabs/panes, not unified. Graph is single-class force. |
| **Roam Research** | Outliner is the primary editing surface (block hierarchy) | Page-graph view + bidirectional links | **Partial** — outliner = tree of blocks, page-graph = force layout. Not rendered together. Roam's [page-graph view](https://medium.com/alvistor/comparing-roamresearch-graph-view-with-logseq-and-obsidian-b0c1fd51c2ee) groups mentions above/below a node cleanly — this is the closest existing semantic-substrate pattern. |
| **Logseq** | Block-outliner (Roam-like) | Force graph | **No** — outliner + force view are alternate UIs. A [Zettelkasten-Forum thread](https://forum.zettelkasten.de/discussion/3425/visualizing-luhmanns-folgezettel-in-logseq) attempts folgezettel visualization via plugin; consensus: plain force layout, color-coded. |
| **Foam** (VS Code) | File-tree sidebar | Force graph (d3) | **No** — sidebar tree + separate graph panel. |
| **The Brain** | Explicit 3-layer: Parent / Siblings / Children + Jump Thoughts as 4th | N/A — that IS the graph | **Yes (radical)** — the whole UI IS a typed relationship display. One node at center, structured ring around it. No force layout. |
| **Niklas Luhmann Archiv** | Tree navigator in left pane | Card content in right pane | **Yes (conservative)** — tree for navigation, inline links for crossrefs. No graph viz at all. |
| **Scrintal / Heptabase** | Canvas (user-drawn boards) | Backlinks panel | **No** — user manually arranges; no algorithmic layout. |
| **Tinderbox** | Outline + Map + Chart views | Typed-link visualizations | **Yes (separated)** — distinct tabs; Map view uses semantic positioning the user configures. |

**Pattern in the data**: every mature tool *separates* structural navigation (tree/outliner) from graph discovery (force layout), rendering them as **different panes**, not different *visual layers of the same canvas*. The Brain is the closest exception, and it abandons the graph metaphor entirely.

### 2.3 Academic visualization principles that apply

1. **Semantic Substrates ([Shneiderman & Aris 2006](https://www.cs.umd.edu/~ben/papers/Shneiderman2006Network.pdf), [Aris & Shneiderman 2007](https://www.cs.umd.edu/~ben/papers/Aris2007Designing.pdf)).** A semantic substrate is "a spatial template for a network, where nodes are grouped into regions and laid out within each region according to one or more node attributes." Their core principles: (1) non-overlapping regions based on user-defined node attributes, (2) interactive sliders to control link visibility and limit clutter. **Directly matches silmari's `kind:hub` + `trunk:*` data.** Typically 2-5 regions.
2. **Layered graph drawing (Sugiyama-style)** — suitable only for DAGs. Silmari's graph has cycles (cross-references between hubs) and lacks a total ordering. Not applicable.
3. **Edge bundling ([Holten 2006](https://www.aviz.fr/wiki/uploads/Teaching2014/bundles_infovis.pdf))** — pulls edges along a spine. Valuable when cross-refs would otherwise cross region boundaries chaotically. Ship-optional optimization, not MVP.
4. **LOD / link visibility filters** — Shneiderman & Aris explicitly ship link-visibility sliders to reveal/hide classes. Silmari has 12 edge types; per-type toggle = UI-navigation problem. Better: 3 tier groups (structural/reference/reviewed) with one slider controlling each.
5. **Small multiples (Tufte 1990)** — rejected for this use case; split canvases lose context, and the semantic-substrate pattern keeps everything on one surface.

### 2.4 Ideal-state properties (synthesized, each citable)

1. **A substrate grounded in user-curated structure** (hubs + trunks), not auto-computed hierarchy (Shneiderman & Aris 2006).
2. **Folgezettel as trace overlay, not spine** (Doto 2024; zettelkasten.de).
3. **Three edge-visibility tiers** (structural / reference / reviewed) with one slider per tier (Shneiderman & Aris 2006).
4. **Region membership visible at all zoom levels** — trunks at zoom-out, hubs at zoom-in (Shneiderman & Aris; [Munzner 2014](https://www.cs.ubc.ca/~tmm/vadbook/) LOD principle).
5. **Graph metrics stay in the detail panel**, not decorated onto the canvas (Tufte chart-junk principle).
6. **One canvas, one force pass** (biased by region-center gravity), not multiple views (Tinderbox-style separation is for professional users; silmari's audience needs one coherent view).
7. **Interactive reveal of folgezettel chain on demand** — click a card → highlight the `follows`/`branches` breadcrumb to root (Luhmann Archiv pattern).
8. **Search and keyword register as first-class entry points**, because [Luhmann's own](https://zettelkasten.de/posts/luhmann-folgezettel-truth/) access pattern relied on the keyword index, not browsing the tree.

---

## 🏗️ Section 3 — Design (hub-substrate, not tree+graph)

### 3.1 Layout algorithm

**Single d3-force pass, semantic-substrate-biased.**

- **Hub-region gravity** — each card belongs to ≥1 hub (via `ref:refers-to:<hubId>` or explicit `kind:hub` assignment). Each hub has an assigned (x, y) center. Cards experience a weak gravitational pull toward their hub center: `d3.forceX(hubCenter.x).strength(0.15)`, same for y. Hub cards themselves are pinned or heavier-weighted.
- **Trunk super-regions** — 5 trunks = 5 colored "sectors" across the canvas. Hub centers are pre-placed within their trunk's sector. Zoom-out reveals sector labels; zoom-in hides them.
- **Link force** — standard `d3.forceLink()` but with per-class strength:
  - Structural (`follows`, `branches`, `derives-from`) — strength 0.3 (weak, keeps lineage loose)
  - Reference (`refers-to`, `annotates`, `blocks`) — strength 0.5
  - Reviewed (`supports`, `contradicts`, `extends`, `reinforces`, `refines`) — strength 0.7 (strongest; these are the user's highest-value curation)
- **Charge** — standard repulsion, unchanged from current.

Rationale: substrate via forceX/forceY-to-region-center is exactly how [Shneiderman & Aris (2007)](https://www.cs.umd.edu/~ben/papers/Aris2007Designing.pdf) recommend implementing it. No custom sim. No tree-layout algorithm. No Sugiyama.

### 3.2 Visual hierarchy (primary → tertiary)

| Tier | Elements | Treatment |
|---|---|---|
| **Primary** | Hub cards, trunk-sector labels | Large (2×), brand color, always visible |
| **Secondary** | Regular cards | Normal size, kind-colored, shown above zoom threshold 0.4 |
| **Tertiary** | Stub cards, `derives-from` edges (folgezettel trace) | 50% opacity, shown above zoom threshold 0.8, dimmed when not hovered |

### 3.3 Interaction model

- **Click card** → detail portal opens (current behavior — unchanged).
- **Hover card** → highlight connected subgraph (current) + also highlight folgezettel chain (new).
- **Click hub** → zoom to hub's region, fade non-region nodes to 20% opacity.
- **Escape** → zoom back to overview.
- **Cmd+click** → path-highlight (unchanged).
- **Shift+click** → what-if cascade (unchanged).
- **Scroll** → standard pan/zoom. LOD fires at 0.4 (show regular cards) and 0.8 (show stubs).

### 3.4 Progressive disclosure rules

- **Zoom < 0.4**: only trunks + hubs + reviewed-tier edges visible. "Map view." ~25-50 nodes.
- **Zoom 0.4–0.8**: + regular cards + reference-tier edges. ~200 nodes.
- **Zoom > 0.8**: + stubs + folgezettel trace edges. Full fidelity.

### 3.5 Data contract

Additions to the exported SQLite / viewer consumption:

- `hubs` table or materialized view: `(hubId, cardId, kind=hub|structure)` — which cards are hubs.
- `card_hubs` relation (optional; can be derived from `ref:refers-to:<hubId>` labels): `(cardId, hubId, weight)` — which hubs a card belongs to.
- `trunk_assignments` — already present via `trunk:N` label.
- No new columns on `issues` or `card_edges`.

If these are not present, design degrades to:
- No hub-gravity → falls back to pure force layout (current behavior).
- Trunk sectors still visible as colored backgrounds (trunk label is already in data).
- Three-tier edge visibility still works (edge-type is already in `card_edges.type`).

**Degradation path is clean** — every feature degrades to current behavior when structural data is missing.

### 3.6 Component boundary

**Replace `apps/silmari-memory-card-viewer/viewer_assets/graph.js` only.** Keep:
- `bv-graph-wasm` (type-agnostic metrics — still useful)
- `link-builder.js` (union logic — still needed)
- `viewmodel.js` (label extractors — still needed)
- `graph-helpers.js` (kindColor/kindSize — extended with new region-center helpers)
- The detail panel, filters, heatmap toggle, search, keyboard bindings

The force-graph library (`3d-force-graph`) is also reused — same API, just different force configuration. No WASM rewrite.

### 3.7 Migration path

1. **Add region-center computation** to `graph-helpers.js` (pure function; testable). Given trunks + hubs, return `{[hubId]: {x, y}}`. ~100 LOC.
2. **Add per-class strength map** to `graph-helpers.js`. ~30 LOC.
3. **Modify `initGraph()`** in `graph.js` to apply `forceX`/`forceY` per-node using the region-center map. ~50 LOC.
4. **Modify `LB.buildLinks()`** output to carry an `edgeClass: 'structural' | 'reference' | 'reviewed'` field alongside `type`. ~20 LOC.
5. **Add tier visibility sliders** to `index.html` + bind to force strength. ~40 LOC UI + 20 LOC wiring.
6. **Add LOD** — single `onZoom` handler toggling visibility flags. ~30 LOC.

**Total: ~300 LOC change**, mostly additive. No rewrite of graph.js wholesale. Deletable if it doesn't land well.

### 3.8 MVP vs. full vision

| Scope | MVP | Ship-optional |
|---|---|---|
| Region gravity from hubs | ✅ | |
| Trunk sector backgrounds | ✅ | |
| Per-class link strength | ✅ | |
| Three visibility slider tiers | ✅ | |
| LOD zoom rules | ✅ | |
| Folgezettel chain highlight on hover | | ✅ |
| Edge bundling (Holten) around spine | | ✅ |
| Hub-zoom interaction | | ✅ |
| Animated region transitions | | ❌ cut (overengineering) |
| Per-type edge toggle (12 checkboxes) | | ❌ cut |
| Custom force simulation | | ❌ cut |

---

## 🛡️ Section 4 — Adversarial Take

### 4.1 Steelman for "don't rewrite, just fix"

Three strongest arguments against doing ANY of this:

1. **Existing graph.js has 3900 LOC of interaction debt that's already paid.** Click, drag, hover, what-if cascade, critical-path highlight, heatmap, search, keyboard shortcuts — all battle-tested. Any rewrite re-opens each. The ≤300-LOC additive migration plan in §3.7 is the defense, but if it slips, we've incrementally touched 3900 LOC with no commit boundary clean enough to revert.
2. **The observed "ball of string" is primarily a visual-encoding problem, not a layout problem.** 12 edge types → 12 colors → cognitive overflow. Fix that in `graph-helpers.js` alone (3 tiers, 3 styles) and the graph reads fine without any layout change. Cost: ~40 LOC. The hub-substrate design may be producing value where the real issue is 9 unnecessary colors.
3. ~~**Silmari has 0 hubs in current data.**~~ **WITHDRAWN 2026-04-19.** The original claim was based on `zk_status.hubs = 0`, which counts entities in a *separate formal-registry* (created via `zk_hub_create`) — NOT cards with a `kind:hub` label. A direct query of the `labels` table shows **28 `kind:hub` + 6 `kind:register` + 1 `kind:structure` = 35 substrate anchors** in the live store. The screenshot at `Pictures/Screenshots/2026-04-19_16-24.jpg` confirms the viewer already renders these in orange/pink/yellow. The substrate design is implementable on current data; steelman #3 is retracted.

**Corrected response to the steelman**: #2 remains a genuine cheap win. #1 (existing-code interaction debt) is mitigated by the additive migration path (§3.7, ~300 LOC diff). #3 is withdrawn. So MVP order is: **(a) collapse 12 colors to 3 tiers first** — still the right sequence because it's genuinely cheaper, fully reversible, and its outcome tells you whether the perceived problem is visual encoding vs. layout; **(b) implement region gravity using existing `kind:hub`/`kind:register`/`kind:structure` cards as anchors** — now unblocked by the correction; **(c) add auto-promotion of high-PageRank cards to hubs** as an enhancement, not a prerequisite.

### 4.2 Ten overengineering risks, each with counter-design

| # | Risk | Counter-design |
|---|---|---|
| 1 | Split-screen tree+graph wastes space | One canvas, substrate regions |
| 2 | 12-color edge palette nobody remembers | 3 tiers, 3 styles (thin/dotted/bold-colored) |
| 3 | Per-type checkbox UI (12 toggles) | 3 tier sliders |
| 4 | Custom force simulation | d3-force with forceX/forceY region targets |
| 5 | Animated zoom/region transitions | Instant pan/zoom, static layout |
| 6 | PageRank numbers decorated on every node | Metrics in detail panel only |
| 7 | Folgezettel as primary spine | Folgezettel as on-hover trace overlay |
| 8 | Sugiyama/hierarchical layout | No — graph has cycles, not a DAG |
| 9 | Edge bundling in MVP | Ship-optional, not MVP |
| 10 | Multiple view modes toggleable by user | One coherent view; modes are a UI-navigation problem |

### 4.3 Explicit cut list

Features considered and **excluded**:

- **3D graph** — network topology is 2D; 3D obscures more than it reveals ([Munzner 2014](https://www.cs.ubc.ca/~tmm/vadbook/)).
- **Split-pane tree+graph** — loses shared context; every mature tool that does this treats them as separate tabs.
- **Per-edge-type toggles** — 12 checkboxes = UI nav problem. Three tier-sliders do the same job at 25% cognitive cost.
- **Animated hub transitions** — satisfying to build, costly to use.
- **Auto-layout of folgezettel as tree** — falsifies the Luhmann model ([Doto 2024](https://writing.bobdoto.computer/folgezettel-is-not-an-outline-luhmanns-playful-appreciation-of-disfunction/)).
- **Matrix view** (adjacency matrix alternative to node-link) — powerful for dense graphs but cognitively far from the "thinking tool" metaphor.
- **Custom WASM layout** — d3-force gets us 95% there; WASM's value is metrics (PageRank etc.), not layout.

### 4.4 First-principles primitives (irreducible user operations)

A Zettelkasten viewer exists to support five atomic user operations:

1. **Find** — locate a specific card by keyword or id.
2. **Orient** — understand where a card sits (which hub, which trunk, which thread).
3. **Navigate** — follow a link to a related card.
4. **Discover** — see cards I didn't know I wanted (serendipity).
5. **Place** — understand where a new card belongs.

The current graph.js primarily serves #4 and weakly serves #1/#3. It mostly *fails* #2 (all nodes look equivalent) and is absent on #5. The hub-substrate design serves #2 and #5 natively (region membership IS orientation; empty space IS place) while keeping #1/#3/#4 at parity. That's the justification — not "graphs are cool."

---

## 📋 Design at a glance

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│    Trunk 5 (Applied Science) — tan background                   │
│    ┌───────────────┐      ┌───────────────┐                     │
│    │   hub-algo    │─────?│   hub-viewer  │                     │
│    │      ○        │supp. │      ○        │                     │
│    │    ·      ·   │      │    ·      ·   │                     │
│    │   card    card│      │   card    card│                     │
│    └───────────────┘      └───────────────┘                     │
│                                                                 │
│    Trunk 2 (Social Sci) — pale-blue bg                          │
│    ┌───────────────┐                                            │
│    │  hub-sociol   │                                            │
│    │      ○        │                                            │
│    └───────────────┘                                            │
│                                                                 │
│    Legend: ○ = hub (primary)  · = card (secondary)              │
│            solid = reviewed edge, thin = reference,             │
│            dotted = structural (folgezettel/derives-from)       │
└─────────────────────────────────────────────────────────────────┘
```

- **Hubs** are visible at all zoom levels; cards appear at zoom > 0.4; stubs at zoom > 0.8.
- **Reviewed edges** (supports/contradicts/extends/reinforces/refines) are the bold drawn layer — these are the user's curated cross-refs.
- **Structural edges** (follows/branches/derives-from) appear dotted, dimmed by default, brightened on hover.

---

## 🧾 Sources

**Luhmann primary & secondary**
- Schmidt, Johannes F.K. (2018) "Niklas Luhmann's Card Index: The Fabrication of Serendipity," *Sociologica* 12(1): 53-60. [sociologica.unibo.it](https://sociologica.unibo.it/article/download/8350/8272/26621)
- Doto, Bob (2024) "Folgezettel is Not an Outline: Luhmann's Playful Appreciation of (Dys)function." [writing.bobdoto.computer](https://writing.bobdoto.computer/folgezettel-is-not-an-outline-luhmanns-playful-appreciation-of-disfunction/)
- zettelkasten.de (n.d.) "No, Luhmann Was Not About Folgezettel." [zettelkasten.de](https://zettelkasten.de/posts/luhmann-folgezettel-truth/)
- Niklas Luhmann Archiv, "Tutorial des Zettelkastens." [niklas-luhmann-archiv.de](https://niklas-luhmann-archiv.de/bestand/zettelkasten/tutorial)

**Visualization academic**
- Shneiderman, B. & Aris, A. (2006) "Network Visualization by Semantic Substrates," *IEEE TVCG* 12(5). [cs.umd.edu](https://www.cs.umd.edu/~ben/papers/Shneiderman2006Network.pdf)
- Aris, A. & Shneiderman, B. (2007) "Designing Semantic Substrates for Visual Network Exploration," *Information Visualization* 6. [cs.umd.edu](https://www.cs.umd.edu/~ben/papers/Aris2007Designing.pdf)
- Holten, D. (2006) "Hierarchical Edge Bundles." [aviz.fr](https://www.aviz.fr/wiki/uploads/Teaching2014/bundles_infovis.pdf)
- Munzner, T. (2014) *Visualization Analysis and Design*. [cs.ubc.ca](https://www.cs.ubc.ca/~tmm/vadbook/)

**Prior-art implementations**
- Roam Research graph comparison: [alvistor / Medium](https://medium.com/alvistor/comparing-roamresearch-graph-view-with-logseq-and-obsidian-b0c1fd51c2ee)
- Logseq Folgezettel visualization thread: [zettelkasten-forum](https://forum.zettelkasten.de/discussion/3425/visualizing-luhmanns-folgezettel-in-logseq)
- Obsidian Graph View docs: [help.obsidian.md](https://help.obsidian.md/Plugins/Graph+view)

**Silmari codebase**
- Current graph.js at `apps/silmari-memory-card-viewer/viewer_assets/graph.js` (commit `1d90240`)
- WASM at `apps/silmari-viewer/bv-graph-wasm/src/graph.rs`
- Prior research: `thoughts/searchable/shared/research/2026-04-18-siyuan-as-beads-viewer-replacement.md`

---

## ❓ Open Questions (for follow-up, not this doc to answer)

1. Should the system auto-promote high-PageRank cards to hubs, or wait for the user to curate? Auto = faster substrate data, slower consensus on what "hub" means. Manual = requires hub-authoring UI, which silmari-mcp has (`zk_hub_create`) but the viewer doesn't surface.
2. When a card belongs to >1 hub (via multiple `ref:refers-to:hub*` labels), where does it sit — between regions, or in the primary-hub region with the secondary as a soft pull? The Shneiderman & Aris paper explicitly assumes non-overlapping regions; soft multi-membership is unresolved.
3. Is the 3-tier edge collapse (structural/reference/reviewed) the right partition, or should `blocks` promote out of reference into its own visual treatment given its semantic weight?
4. Does the user actually want the tier-sliders, or is "always show reviewed, dim everything else" a reasonable hardcoded default? Shipping without sliders would test whether the sliders are necessary.

*End of research + design.*
