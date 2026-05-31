# STRUCTURED SUMMARY: UI Redesign — Three Research Documents

       ---
       DOC 1: 2026-04-12 Zettelkasten Thinking Tool Dashboard Design

       Key Claims / Decisions

       - Notes must "talk back" — the link structure IS the retrieval mechanism, not full-text search
       - Luhmann's 3-layer architecture (Keyword Register, Hub Notes, Folgezettel Chains) was engineered serendipity, not exhaustive indexing
       - No tool combines graph-theoretic analytics with operational knowledge health
        — white space opportunity
       - Cross-trunk connection density is the strongest signal; stub conversion rate
        + orphan age are actionable triage metrics
       - Dashboard measures thinking state, not task completion or note count

       Specific UI Design Recommendations

       ┌────────────────────┬────────────────────────────────────────────────────────
       ──────┐
       │       Widget       │                           Purpose
             │
       ├────────────────────┼────────────────────────────────────────────────────────
       ──────┤
       │ Thinking Pulse     │ Cards created/linked this week by trunk (accretion
       rate)     │
       ├────────────────────┼────────────────────────────────────────────────────────
       ──────┤
       │ Cluster Density    │ Treemap of trunks, sized by count, colored by link
       density   │
       │ Map                │
             │
       ├────────────────────┼────────────────────────────────────────────────────────
       ──────┤
       │ Orphan Observatory │ Cards with 0-1 links, sorted by age, with suggested
             │
       │                    │ connections
             │
       ├────────────────────┼────────────────────────────────────────────────────────
       ──────┤
       │ Cross-Trunk        │ Edges connecting different trunks (interdisciplinary
       signal) │
       │ Bridges            │
             │
       ├────────────────────┼────────────────────────────────────────────────────────
       ──────┤
       │ Contradiction      │ Cards linked via contradicts edges
             │
       │ Radar              │
             │
       ├────────────────────┼────────────────────────────────────────────────────────
       ──────┤
       │ Stub Pipeline      │ Development queue (age + who's blocked)
             │
       ├────────────────────┼────────────────────────────────────────────────────────
       ──────┤
       │ Recent Activity    │ Last 10 touched cards
             │
       └────────────────────┴────────────────────────────────────────────────────────
       ──────┘

       Three-Zone Detail Portal

       Research specifies thinking-oriented card list views, not a three-zone panel
       yet:
       - By Maturity: Seeds | Growing | Developed | Evergreen
       - By Trunk: Domain-organized with cluster sub-grouping
       - Needs Attention: Stubs >7d old, orphans >14d old, empty hubs
       - Chains: Folgezettel argument threads
       - Contradictions: Pairs of contradicting cards side-by-side

       "Notes Talking Back" Mechanisms

       - Proactive surfacing (no LLM): Keyword overlap, inbound edge scan, structural
        gap detection
       - Contradiction surfacing (contradicts edges) — friction zones where original
       thinking happens
       - Orphan-to-evergreen pipeline — detect cards with 2+ keyword matches but no
       edge
       - Hub-to-leaf rebalancing — detect over-organizing (target Luhmann's 1:28
       ratio)
       - Stub pipeline — processing velocity feedback

       Serendipity Mechanisms

       - Cross-trunk bridges by betweenness centrality (high-leverage connectors)
       - Multiple-storage principle: same idea in new context = new card +
       cross-reference (never suppress saves for duplication)
       - Hub cards as switchboards — 15-25 cross-references as topic overview
       - Keyword index as sparse entry points — 1 entry per ~20 cards, curated NOT
       exhaustive

       Editing Cards In-UI

       DEFERRED — design only mentions card list views (maturity, attention, chains).
        No UI affordances for in-panel editing proposed.

       Deferred vs Agreed

       - Agreed: Dashboard widget specs, metrics hierarchy, Luhmann's 3-layer
       architecture, "thinking pulse" concept
       - CRITICAL BLOCKER FOUND: Folgezettel tree is flat (264 cards, all root
       depth). Algorithm's LEARN phase defaults to continue mode, never calls fork.
       Blocks all tree navigation work. Fix required in v3.8.1: add mode selection
       protocol (fork/continue/root) to Algorithm LEARN Step 3.

       ---
       DOC 2: 2026-04-12 Beads Viewer Zettelkasten Graph Redesign

       Key Claims / Decisions

       - Graph engine is powerful (PageRank, betweenness, k-core, etc.) but mental
       model is project management, not thinking navigation
       - Zettelkasten data is extracted by viewmodel.js but never rendered — pipeline
        carries data through but templates don't consume it
       - Dual-graph distinction needed: folgezettel tree (local coherence) +
       cross-references (global serendipity)
       - Progressive disclosure: hover for "where am I?", click for "what does this
       think?"

       Specific UI Design Recommendations

       Hover Interaction (Quick Context):
       - Show [kind] fz:2/3a1 — Trunk: Social Science badge
       - Highlight folgezettel neighborhood (parent, siblings, children) instead of
       generic 2-hop
       - Show edge count by type (e.g., "3 follows, 2 cross-refs, 1 contradicts")
       - Light up thought chain direction (parent above, children below)

       Click Interaction (Deep Context):
       - Left panel: Folgezettel address, kind badge, trunk badge, title
       - Breadcrumb: Social Science > [parent title] > This card (human-readable
       chain)
       - Chain navigator: prev sibling | next sibling | children buttons
       - Typed edge groups (auto vs reviewed tier, not just "Blocked By / Blocks")
       - Incoming edges ("Referenced by") — requires O(n) scan
       - "See Also" — cards sharing 2+ keywords but no direct edge
       - Keywords this card is an entry point for
       - Source attribution, box indicator (biblio vs idea)

       Three-Zone Detail Portal (Explicit Design)

       Zone 1 — Context Header:
       - ✅ Kind/fz/trunk badges (partially done)
       - ❌ Folgezettel breadcrumb with titles
       - ❌ Chain navigator strip (prev/next/children buttons)

       Zone 2 — Card Body:
       - ❌ Elevate title as primary prose
       - ❌ Hide/collapse JSON description blob
       - ❌ "Develop This Card" panel: 0-3 actionable suggestions (missing keywords,
       no reviewed edges, no children)

       Zone 3 — Connection Navigator:
       - ✅ Outgoing edges with titles (partial)
       - ❌ Incoming edges ("Referenced by")
       - ❌ "See Also" keyword-overlap cards
       - ❌ Edge grouping by tier (auto vs reviewed)

       "Notes Talking Back" Mechanisms

       - Keyword overlap engine: given a card, return unlinked cards sharing 2+
       keywords
       - Incoming edge scan: find cards with ref:*:${cardId} labels
       - Edge-type ratio as quality proxy (reviewed / total edges)
       - Structural gap detector: "This card has 3 shared keywords with 5 unlinked
       cards"
       - Zero LLM — pure label parsing + topology

       Serendipity Mechanisms

       - Cross-references as visual distinction from folgezettel tree (different
       colors, line styles)
       - Contradiction surfacing (red, crossed edges for contradicts type)
       - Hub cards visually distinct — large, prominent shape (currently generic
       dots)
       - Stub density heatmap — find underdeveloped branches
       - Age-since-touched heatmap — Luhmann's "rediscovery" mechanism

       Editing Cards In-UI

       DEFERRED — research focuses on display + discovery. No edit-in-place
       affordances designed.

       Deferred vs Agreed

       - Agreed: three-zone design, progressive disclosure pattern, typed edge
       visualization, keyword overlap engine
       - Deferred: folgezettel tree layout (need branched cards first), sync between
       Silmari MCP and viewer format, biblio box visibility, tree vs flat heatmap
       toggle

       ---
       DOC 3: 2026-04-16 MCP Memory Update + Viewer Redesign Handoff

       Key Claims / Decisions

       - Card detail panel IS the product — dashboard/lists are navigation layers
       only
       - Build order: card panel → computation engines → lists → dashboard → insights
       - Flat tree is accepted legacy; new cards will branch forward
       - ~80% of "notes talking back" needs zero LLM

       Specific UI Design Recommendations (Synthesis)

       Phase 1 — Card Detail Panel (Zone 1-3 as above):
       - Context header (fz breadcrumb, kind/trunk badges, chain navigator)
       - Card body (prose title, hide JSON, "Develop This Card" panel)
       - Connection navigator (grouped typed edges, incoming edges, "See Also",
       keywords)

       Phase 2 — Computation Engines (No UI specs, but feeds panel + dashboard):
       - Keyword overlap (2+ shared keywords = "See Also" candidates)
       - Incoming edge scan (O(n) lookup for "Referenced by")
       - Edge-type ratio (quality metric)
       - Structural gap detector

       Phase 3 — Cards List Views (Spec inherited from Doc 1):
       - By Maturity (Seeds / Growing / Developed / Evergreen)
       - By Trunk (domain-organized)
       - Needs Attention (stubs, orphans, empty hubs)
       - Chains (folgezettel threads)
       - Contradictions (side-by-side pairs)

       Phase 4 — Dashboard Widgets (Spec from Doc 1):
       - Thinking Pulse, Cluster Density Map, Orphan Observatory, Cross-Trunk
       Bridges, Contradiction Radar, Stub Pipeline, Recent Activity

       Phase 5 — Insights (From Doc 1):
       - Knowledge Health Score, Hub Coverage, Bridge Ideas, Dead Ends, Growth
       Trajectory, Keyword Coverage, Trunk Balance

       Three-Zone Detail Portal (Explicit)

       ✅ Partial (index.html:3458–3599):
       - ZK context bar (kind/fz/trunk badges)
       - Outgoing edges with titles + edge-type verbs
       - Keywords section

       ❌ To build:
       - Folgezettel breadcrumb (titles, not raw fz:5_92)
       - Chain navigator (prev/next/children buttons)
       - Elevate title as prose, hide JSON blob
       - "Develop This Card" suggestions panel
       - Incoming edges ("Referenced by")
       - "See Also" (keyword overlap)
       - Edge grouping by tier

       "Notes Talking Back" Mechanisms (Confirmed)

       - Keyword overlap: Set intersection on keyword:* labels
       - Incoming edges: Scan all cards for ref:*:${cardId} labels (trivial for ~265
       cards)
       - Structural gaps: Label parsing, no LLM
       - ~80% achievable with zero LLM — documented as finding

       Serendipity Mechanisms

       - Cross-trunk bridges (betweenness centrality)
       - Contradiction hot spots (cards with contradicts edges)
       - Stub density (find underdeveloped branches)
       - Age-since-touched (rediscovery mechanism)
       - Reinforcement count (ideas confirmed across contexts)

       Editing Cards In-UI

       DEFERRED explicitly — Task 2 focuses on discovery/display. Editing is Phase 6+
        (not in this handoff scope).

       Deferred vs Agreed (Task Status)

       ┌────────────────────────────────┬──────────────┬─────────────────────────────
       ──────┐
       │              Task              │    Status    │               Notes
             │
       ├────────────────────────────────┼──────────────┼─────────────────────────────
       ──────┤
       │ Task 1 — Update MCP memory     │ DEFERRED     │ Marked simple (~10 min), but
        not  │
       │                                │              │ included in this handoff
       scope    │
       ├────────────────────────────────┼──────────────┼─────────────────────────────
       ──────┤
       │ Task 2 — Card detail panel     │ BLOCKED (not │ Research done; detailed zone
             │
       │ (Phases 1-3)                   │  yet         │ specs ready; awaiting
             │
       │                                │ started)     │ implementation
             │
       ├────────────────────────────────┼──────────────┼─────────────────────────────
       ──────┤
       │                                │              │ Depends on Task 2 starting;
       specs │
       │ Task 3 — Computation engines   │ PENDING      │  in this doc (keyword
       overlap,    │
       │                                │              │ incoming edges, etc.)
             │
       ├────────────────────────────────┼──────────────┼─────────────────────────────
       ──────┤
       │ Task 4 —                       │ PENDING      │ Depends on Task 2-3; full
       specs   │
       │ Dashboard/Lists/Insights       │              │ in Dashboard research doc
             │
       ├────────────────────────────────┼──────────────┼─────────────────────────────
       ──────┤
       │ Critical fix — Algorithm       │ IN PLACE     │ Code committed; folgezettel
       tree  │
       │ v3.8.1 mode selection          │ (not yet     │ still flat (needs LEARN
       phase to  │
       │                                │ tested)      │ call fork)
             │
       ├────────────────────────────────┼──────────────┼─────────────────────────────
       ──────┤
       │ Legacy 261 cards               │ ACCEPTED     │ Retroactive branching
       impossible; │
       │                                │ FLAT         │  new cards will branch
       forward    │
       └────────────────────────────────┴──────────────┴─────────────────────────────
       ──────┘

       Other Key Findings

       - MCP env var trap: Use SILMARI_DIR, not SILMARI_STORE (paths.ts:50)
       - CLAUDE.md is generated from template + LATEST pin
       - beads_rust label limit raised 50 → 128 chars (fixes source tag truncation)
       - ionos01 alpha deploy is live with ZK colors + typed-edge tooltips + partial
       detail panel
       - Beads integration: No bd list tracking for viewer work — consider creating
       issues

       ---
       SYNTHESIS: 10 Design-Relevant Takeaways for Today (2026-04-21)

       1. Three-zone detail portal is the product. Hover/click/context bar + body +
       connection navigator. All UI leverages accumulate around the card panel.
       Prioritize Zone 1 (breadcrumb + chain navigator) and Zone 3 (incoming edges +
       "See Also") — Zone 2 prose is simpler.
       2. Folgezettel tree is still flat (264 root cards). Algorithm v3.8.1 spec is
       ready but untested. New cards WILL branch correctly if LEARN phases invoke
       fork mode. Existing flat cards are permanent legacy — accept it and design for
        the forward-growing tree.
       3. Progressive disclosure: hover surfaces folgezettel neighborhood, click
       surfaces cross-references. The dual-graph distinction (tree vs network) is
       non-negotiable. Hover shows parent + siblings + children lit up. Click shows
       typed edges grouped by tier (auto vs reviewed).
       4. Edge types ARE the semantic layer. Collapse 12 edge types into 2 groups
       (auto: follows/continues/branches/derives-from, reviewed:
       supports/contradicts/extends/reinforces/refines). Visualize type with color +
       line style. Current code treats all edges identically — this is the blocker.
       5. Keywords are sparse entry points, not tags. No full-text search by default.
        Search starts with keyword-index layer (curated 1:20 ratio), then folgezettel
        neighborhood, then cross-references. "See Also" (keyword overlap) is a
       zero-LLM connection bridge — 2+ shared keyword:* labels = card suggestion.
       6. ~80% of "notes talking back" is pure topology. Keyword overlap, incoming
       edges, stub density, orphan age, cross-trunk bridges — all via label parsing
       and O(n) scans. No LLM needed. This is the design differentiator vs
       Obsidian/Roam.
       7. Hub cards are visually distinct and large. Not a generic node. Hubs are
       "airports" (up to 25 cross-references as topic switchboard). Size/color/icon
       distinctly, especially in 5-view cluster/radial modes. Current graph treats
       them as normal nodes.
       8. Card kind maturity gradient replaces status badge. Open→InProgress→Closed
       is project thinking. Stub→Seed→Growing→Developed→Evergreen is Zettelkasten
       thinking. Priority field remapped to kind-based maturity. Visual encoding:
       stub (hollow/dashed), seed (faint), growing (medium), developed (solid),
       evergreen (high PageRank + cross-trunk).
       9. "Develop This Card" actionable suggestions cost nearly nothing. Parse
       labels, count incoming edges of each type, scan for shared keywords with
       unlinked cards, check for children. 0-3 bullets: "Add source", "No reviewed
       edges yet", "Missing keyword for X". Zero LLM; pure detection.
       10. Build order: card panel (Zones 1-3) → keyword overlap engine → incoming
       edge scan → then dashboard aggregates. Dashboard is never seen without a card
       detail context. Lists view is navigation to cards. Insights are macro view of
       aggregates. Card panel is where users spend time.


# Code Review

     Surface 1: Cards tab list/table

       Location in index.html: Lines 1213-1329

       - Sort controls: Line 1159-1167 (select with options: priority, updated,
       created, score, blocks count, title)
       - Filter controls: Lines 1100-1197 (status chips, type chips, priority chips,
       assignee select, blocked/blocking toggles)
       - Row template: Lines 1216-1272 (template x-for iterating issues)
       - Pagination: Lines 1302-1328 (previous/next buttons with page display)
       - Empty state: Lines 1274-1299 (message varies by filter/search state)

       Row renders: id (1230), issue_type (1231), status (1237/1250), priority
       (1218), title (1241), description excerpt (1243-1245), assignee (1257),
       blocks_count (1258), blocked_by_count (1259), updated_at (1252/1261). On
       mobile: status shown inline; on desktop: status moved to right column.

       Clicking behavior: Line 1219 @click="showIssue(issue.id)" navigates to
       selectedIssue modal (line 3367).

       Surface 2: Cards tab drilled-in detail panel

       Location in index.html: Lines 3366-3724 (bound to selectedIssue)

       - Header/title: Lines 3385-3442 (id, status badge, priority, kind/fz/trunk
       context bar, breadcrumbs, prev/next siblings, children collapsible)
       - Status/priority: Lines 3392-3407
       - Labels: Lines 3495-3502
       - Description: Lines 3522-3531 (collapsible raw markdown)
       - Metadata Details grid: Lines 3533-3558 (assignee, created, updated, closed
       dates with icons)

       Post-strip status: Confirmed — no "Graph Metrics grid" exists at 3533-3554.
       Instead, a pure metadata grid with date fields renders there. The cycle
       warning does NOT appear in this modal — it appears only in the graph detail
       portal (line 3157).

       Sections and interactions:
       - Develop suggestions box (3505-3520): suggests continuing/forking the card
       - Connections outgoing (3560-3590): typed edges grouped by tier (reviewed vs
       structural)
       - Referenced by incoming (3592-3606): backlinks showing which cards point here
       - See also (3608-3620): keyword overlap suggestions
       - Keywords (3622-3631): tags from label extraction
       - Dependencies section (3633-3692): blocks/blocked-by lists with mermaid
       dependency graph toggle
       - What-If Analysis (3694-3722): "Simulate Close" button calculates impact
       (newly unblocked + cascade count)

       Surface 3: Graph node tooltip

       Location in graph.js: Lines 2818-2876

       Function showTooltip(node): Creates fixed-position DOM element with CSS (lines
        2822-2836):
       - Background: THEME.bgSecondary
       - Max-width: 320px
       - Positioned near cursor via positionTooltip listener (lines 2878-2884)

       Fields rendered in innerHTML (lines 2850-2869):
       - Kind label + colored badge (from kindColor function)
       - Folgezettel address (if present)
       - Trunk name (if present)
       - Node id with icon
       - Node title
       - Grid showing: Blockers, Dependents, Depth (criticalDepth)

       Dismissal: Line 2886-2894 hideTooltip() removes listener and fades out over
       150ms. Positioning uses Math.min() bounds-checking to avoid viewport overflow
       (2882-2883).

       Store state: No dedicated tooltip state in store.* — state is managed via DOM
       element visibility and document.addEventListener('mousemove').

       Surface 4: Drilled-in graph node view (right portal)

       Location in index.html: Lines 3066-3184 (bound to graphDetailNode)

       Header with status/priority/id close button: Lines 3086-3116
       - Status badge (3090-3097): colored by graphDetailNode.status
       - Priority badge (3098-3105): P0-P3 colored
       - ID code block (3106)
       - Close button triggering graph clear and resize (3108)
       - Title (3115)

       Quick Stats grid: Lines 3121-3130 (Type, Assignee if present)

       Dependencies Summary: Lines 3133-3144 (blocker count, dependent count in
       red/blue cards)

       Labels: Lines 3147-3154 (purple chips for each label in array)

       Post-strip status: Confirmed — NO Graph Metrics block exists. Cycle warning IS
        present at line 3157-3159 (orange warning "Part of dependency cycle") as a
       promoted sibling next to labels. Zero metrics grid replaced by simple cycle
       warning.

       Description markdown: Lines 3162-3167 (collapsible, renders via marked.parse)

       Metadata footer: Lines 3172-3182 (createdAt, updatedAt only — minimal, no
       grid)

       No edit buttons in this portal—purely read-only view. Close triggers
       clearSelection() on forceGraphModule.

       MCP Tool Inventory (silmari-mcp)

       All zk_* tools from
       /home/maceo/Dev/silmari-agent-memory/apps/silmari-mcp/src/index.ts (lines
       86-314):

       Read-only (query/navigate):
       - zk_recall — Keyword-based entry-point lookup (Layer 1+2+3) with optional
       cross-ref walk
       - zk_neighborhood — Folgezettel neighborhood (parents, siblings, children)
       - zk_chain — Full genealogy from root to address
       - zk_follow — BFS across typed edges (configurable direction/depth/type
       filter)
       - zk_register_read — Read trunk Register JSON by slot
       - zk_status — Health + counts (br_available, card counts, hubs, structures,
       keywords, version)
       - zk_reflect — Return reflection prompts for a proposed save (non-mutating)
       - zk_recall_by_status — Filter cards by status with optional date range +
       neighborhood enrichment

       State-mutating (create/edit/link/promote):
       - zk_save_card — Create card with folgezettel, kind, trunk, mode
       (continue/fork/root), dedup by content hash
       - zk_propose_link — Propose REVIEWED edge
       (supports/contradicts/extends/reinforces/refines) for human approval
       - zk_commit_link — Commit pending proposal → writes ref:edge:target label
       - zk_hub_create — Upsert hub note (idempotent)
       - zk_hub_add_card — Add card as constituent to hub
       - zk_structure_create — Create structure note (argument outline)
       - zk_block — Mark cardId blocked-by another (writes ref:blocked-by label + br
       dep add)
       - zk_keyword_add — Add entry point (fz address) to keyword index (MAX 4 per
       term, FIFO evict)
       - zk_promote — Transition card status (open/in_progress/blocked/closed, with
       force bypass for blocked→open)

       Card Data Model

       From viewmodel.js lines 38-65 (toCard function):

       Field: id
       Type: string
       Source: row.id
       ────────────────────────────────────────
       Field: title
       Type: string
       Source: row.title
       ────────────────────────────────────────
       Field: description
       Type: string
       Source: row.description
       ────────────────────────────────────────
       Field: status (lifecycle)
       Type: 'open'|'in_progress'|'blocked'|'closed'
       Source: row.status
       ────────────────────────────────────────
       Field: priority
       Type: number
       Source: row.priority (default 2)
       ────────────────────────────────────────
       Field: createdAt
       Type: ISO8601 string|null
       Source: row.created_at
       ────────────────────────────────────────
       Field: updatedAt
       Type: ISO8601 string|null
       Source: row.updated_at
       ────────────────────────────────────────
       Field: closedAt
       Type: ISO8601 string|null
       Source: row.closed_at
       ────────────────────────────────────────
       Field: kind
       Type: 'idea'|'hub'|'register'|'structure'|'fact'|'signal'|'learning'|'preferen
       ce'|'decision'|'stub'|'biblio'
       Source: extracted from labels via kind: prefix
       ────────────────────────────────────────
       Field: trunk
       Type: {number: 0-5, name: string}|null
       Source: extracted from labels via trunk: prefix
       ────────────────────────────────────────
       Field: folgezettel
       Type: string|null
       Source: extracted from labels via fz: prefix (underscore → slash)
       ────────────────────────────────────────
       Field: box
       Type: 'idea'|'biblio'
       Source: extracted from labels via box: prefix, defaults 'idea'
       ────────────────────────────────────────
       Field: tags (labels array)
       Type: string[]
       Source: parsed from row.labels (JSON string, comma-sep, or array)
       ────────────────────────────────────────
       Field: keywords
       Type: string[]
       Source: extracted from labels via keyword: prefix
       ────────────────────────────────────────
       Field: edges
       Type: Array<{type: string, targetId: string}>
       Source: extracted from labels via ref:type:targetId pattern
       ────────────────────────────────────────
       Field: blocksCount (linksOut)
       Type: number
       Source: row.blocks_count
       ────────────────────────────────────────
       Field: blockedByCount (linksIn)
       Type: number
       Source: row.blocked_by_count
       ────────────────────────────────────────
       Field: assignee
       Type: string|null
       Source: row.assignee
       ────────────────────────────────────────
       Field: isStub
       Type: boolean
       Source: labels includes 'kind:stub'
       ────────────────────────────────────────
       Field: inCycle
       Type: boolean
       Source: row.in_cycle (graph engine computed)
       ────────────────────────────────────────
       Field: blockerCount
       Type: number
       Source: row.blocker_count (graph engine)
       ────────────────────────────────────────
       Field: dependentCount
       Type: number
       Source: row.dependent_count (graph engine)
       ────────────────────────────────────────
       Field: scope
       Type: string|null
       Source: extracted from labels via scope: prefix

       All label extractions are idempotent, case-sensitive, and occur via
       parseLabels → extractors (lines 141-214). Edges use the pattern
       ref:TYPE:TARGET_ID where TYPE is one of the VALID_EDGE_TYPES enum. Folgezettel
        addresses use fz:TRUNK_SEQ with first underscore decoded to slash
       (folgezettel separator).
