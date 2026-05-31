---
date: 2026-04-21T18:30:00-0400
researcher: Maceo Jourdan
git_commit: 1d9024022cd4d8433f36126f2449f4d62740ffd8
branch: main
repository: tha-hammer/silmari-agent-memory
topic: "Card view + tooltip + graph drill-in redesign — Serendipity + Extend/Edit"
tags: [research, design, viewer, cards, serendipity, zettelkasten, tooltip, detail-panel, edit, extend, luhmann]
status: complete
last_updated: 2026-04-21
last_updated_by: Maceo Jourdan
---

# Card-view Serendipity Redesign

**Date**: 2026-04-21 · **Commit**: `1d90240` · **Epic**: `silmari-agent-memory-xom`

---

## 🎯 Scope

Redesign four UI surfaces in the silmari SPA toward the Luhmann-serendipity experience, with added **edit** and **extend** affordances:

1. **Tooltip** — graph node hover
2. **Drilled-in graph node** — right portal (`graphDetailNode`)
3. **Cards tab list** — row browser
4. **Drilled-in card view** — Cards-tab modal (`selectedIssue`)

---

## 🧭 Headline findings

1. **Surfaces 2 and 4 are the same product at different fidelities.** The Cards-tab drilled-in view (`index.html:3366-3724`) already has most of the three-zone treatment from the 2026-04-12 research (breadcrumb, prev/next siblings, outgoing edges grouped by tier, Referenced-by, See-Also, keywords, Develop suggestions, What-If). The graph right-portal (`index.html:3066-3184`) has a fraction of that. **The redesign is mostly a unification, not a greenfield.**
2. **"Edit" in the Zettelkasten model ≠ modify-body.** There's no `zk_edit_card` MCP tool. There's also no philosophical need for one: Luhmann's multiple-storage principle says the way you "edit" is by **forking a new card** in the new context. "Extend" maps to propose-link. The UI should respect this — not fight it.
3. **~80% of serendipity is already-wired topology.** Keyword overlap + incoming edges + folgezettel neighborhood are all extracted in `viewmodel.js`. The Cards-tab uses them. The graph portal doesn't. The tooltip doesn't. Surfacing them costs render code, not retrieval code.
4. **The tooltip is the first serendipity surface, not a summary card.** A tooltip that shows "Blockers: 3, Dependents: 2, Depth: 4" is the old issue-tracker model. A tooltip that shows "3 shared keywords with 5 unlinked cards" is Zettelkasten.

---

## 📚 1. What serendipity means here

From [Schmidt 2018 *The Fabrication of Serendipity*](https://sociologica.unibo.it/article/download/8350/8272/26621) and [Doto 2024](https://writing.bobdoto.computer/folgezettel-is-not-an-outline-luhmanns-playful-appreciation-of-disfunction/):

> Serendipity is produced by **structural proximity that was not designed to be meaningful** — a side effect of the filing act that creates unexpected neighbors, which on re-encounter produce insight the author never planned.

Operationally in silmari:
- **Folgezettel neighbors** — cards Luhmann happened to file near each other
- **Shared keywords** — cards indexed under the same entry point, possibly unlinked
- **Cross-trunk edges** — connections that cross intellectual categories (rare + high signal)
- **Contradictions** — pairs of cards the user explicitly marked as disagreeing
- **Aged orphans** — cards with no inbound links that haven't been touched in a long time (re-read opportunity)
- **Unexpected hub membership** — cards that belong to multiple hubs

Each maps to a **zero-LLM** detection pattern: label parsing + O(n) scan. Every surface redesign below is built on these.

**What serendipity is NOT**: "recommendation." We do not rank, we do not score, we do not use embeddings. The graph structure IS the retrieval mechanism, per the memory feedback at `feedback_zettelkasten_no_embeddings.md`.

---

## 🗺️ 2. Current-state snapshot (post 2026-04-21 strips)

| Surface | File:line | Fidelity today |
|---|---|---|
| 1. Graph tooltip (hover) | `graph.js:2818-2876` | Title + ZK context + Blockers/Dependents/Depth. Issue-tracker vocabulary. |
| 2. Graph right portal (click) | `index.html:3066-3184` | Header + Labels + cycle warning + Description + minimal metadata. No breadcrumb, no See-Also, no incoming edges, no actions. |
| 3. Cards-tab list | `index.html:1100-1329` | Sort + filter + row template. Clicking opens surface 4. |
| 4. Cards-tab detail modal | `index.html:3366-3724` | **Rich already**: ZK context bar, breadcrumb, prev/next siblings, children, Develop suggestions, outgoing edges by tier, Referenced-by, See-Also, keywords, dependencies + mermaid, What-If. |

The asymmetry between 2 and 4 is the biggest gap. Same card, clicked from two contexts, shown two totally different ways.

**MCP tools available** (from `apps/silmari-mcp/src/index.ts:86-314`):

| Tool | Mutates? | UI affordance candidate |
|---|---|---|
| `zk_recall`, `zk_neighborhood`, `zk_chain`, `zk_follow`, `zk_register_read`, `zk_status`, `zk_reflect`, `zk_recall_by_status` | read | navigation |
| `zk_save_card` | ✅ create | **Fork** button (new card with `mode:"fork"`) |
| `zk_propose_link` | ✅ create proposal | **Extend** button (propose typed edge) |
| `zk_commit_link` | ✅ commit edge | commit step after review |
| `zk_hub_create` / `zk_hub_add_card` | ✅ | **Add to hub** |
| `zk_structure_create` | ✅ | **Promote to structure** |
| `zk_promote` | ✅ status | **Status** dropdown |
| `zk_block` | ✅ | **Mark blocked** (stub flow) |
| `zk_keyword_add` | ✅ | **Add keyword entry-point** |

**No `zk_edit_card` exists** — by design. "Edit" in this model is fork + link.

---

## 🔀 3. Unification thesis

The drilled-in card view is **one component, two invocation contexts**:

| Context | Container | Width | Extras |
|---|---|---|---|
| Cards-tab modal | Full-page overlay | wide (max-w-4xl) | Back-to-list breadcrumb, pagination arrows |
| Graph right portal | Side panel | 400px fixed | Close-button, resizes graph canvas |

**Single shared body.** Everything below the context-bar header is identical: the same three zones, the same edges, the same keyword, the same action row.

**Extraction approach** (conceptual, not implementation):
- Template the modal body as `<card-detail-body>` (Alpine component or included partial)
- Both contexts bind to the same underlying `card` object (whether `selectedIssue` or `graphDetailNode` — rename the state or normalize)
- Width-dependent layout via `@container` queries or Alpine class-binding
- The Cards-tab ALSO gains Zone 1 features (breadcrumb, siblings) that it already has; no loss
- The graph portal GAINS everything at surface-4 parity

**Delta-spec** — features the graph portal lacks today that come from the Cards-tab:

| Feature | Cards-tab line | Graph portal today | Post-unification |
|---|---|---|---|
| Folgezettel breadcrumb | 3385-3442 | ❌ | ✅ |
| Prev/next siblings | 3385-3442 | ❌ | ✅ |
| Children collapsible | 3385-3442 | ❌ | ✅ |
| Outgoing edges by tier | 3560-3590 | partial | ✅ |
| Referenced-by (incoming) | 3592-3606 | ❌ | ✅ |
| See Also (keyword overlap) | 3608-3620 | ❌ | ✅ |
| Develop suggestions | 3505-3520 | ❌ | ✅ |
| What-If | 3694-3722 | ❌ | **DELETED** — issue-tracker, per mandate |

---

## 🏗️ 4. Per-surface redesign

### 4.1 Tooltip (surface 1) — "tease the unexpected"

**Today** (graph.js:2848-2872): title, id, Blockers/Dependents/Depth — issue-tracker vocabulary.

**Proposed** — keep 2 lines that orient (ZK context + title), add 1-2 lines that **tease serendipity**:

```
┌─────────────────────────────────────┐
│ [Hub]  fz:5/7a   Applied Sci        │  ← context bar (kept)
│ ⚡ zk-cwbp                           │
│                                     │
│ Fire skeptic-search on framing      │  ← title (kept, slightly larger)
│ before ISC lock                     │
│                                     │
│ ─────────────────────────────────   │
│ 3 shared keywords · 5 unlinked      │  ← serendipity tease #1
│ Contradicts 1 card                  │  ← serendipity tease #2 (only if applicable)
│ ↻ 47d since last touch              │  ← serendipity tease #3 (only if old)
└─────────────────────────────────────┘
```

**Tease rules** (shown only when signal present — tooltip stays short):
- **Shared keywords** if ≥2 of this card's keywords match ≥2 unlinked cards (teases See Also)
- **Contradicts** if card has any `ref:contradicts:*` labels (teases debate)
- **Rediscovery** if `updated_at > 30d ago` AND the card is not a stub (teases re-read)
- **Cross-trunk** if card has edges to cards of a different `trunk` (teases bridge)
- **Orphan** if `blockerCount + dependentCount + inbound == 0` AND age > 14d (teases "develop this")

Only 0-2 of these render at a time (pick highest-value signal per priority). Drop the Blockers/Dependents/Depth lines entirely — they're issue-tracker.

**Data**: extractable from `viewmodel.js` already + O(n) scan of other cards for inbound/keyword-overlap. No MCP call. No LLM.

### 4.2 Drilled-in graph node (surface 2) — unified

After unification, surface 2 is surface 4 in a 400px side panel. Structure:

```
┌────────────────────────────────────┐
│ [×]                                │  close
│                                    │
│ Zone 1 · Context                   │
│ ┌────────────────────────────────┐ │
│ │ [Hub] fz:5/7a  Applied Science │ │  kind/fz/trunk badges
│ │                                │ │
│ │ Humanities › [grandparent]     │ │  breadcrumb
│ │   › [parent] › THIS            │ │
│ │                                │ │
│ │ ◀ 5/7   5/7a   5/7b ▶  ▼3     │ │  sib nav + children
│ └────────────────────────────────┘ │
│                                    │
│ Zone 2 · Card                      │
│ ┌────────────────────────────────┐ │
│ │ # Fire skeptic-search on       │ │  title as heading
│ │   framing before ISC lock      │ │
│ │                                │ │
│ │ Body markdown renders here.    │ │  body
│ │ Labels as tags below.          │ │
│ │                                │ │
│ │ #framing #premortem            │ │
│ │                                │ │
│ │ ⚠ Part of dependency cycle     │ │  cycle warn (conditional)
│ └────────────────────────────────┘ │
│                                    │
│ Zone 3 · Connections               │
│ ┌────────────────────────────────┐ │
│ │ ▸ Reviewed edges (3)           │ │  collapsible group
│ │   supports →  zk-abc           │ │
│ │   contradicts →  zk-def        │ │
│ │   extends →  zk-ghi            │ │
│ │                                │ │
│ │ ▸ Structural edges (5)         │ │  auto-tier, collapsed default
│ │                                │ │
│ │ ▸ Referenced by (2)            │ │  incoming
│ │                                │ │
│ │ ▸ See Also · keyword-overlap  │ │  unlinked matches
│ │   3 candidates · [propose all] │ │
│ │                                │ │
│ │ ▸ Develop                      │ │  zero-LLM suggestions
│ │   • No reviewed edges yet      │ │
│ │   • 2 shared keywords with     │ │
│ │     zk-xyz — link?             │ │
│ └────────────────────────────────┘ │
│                                    │
│ [Edit mode]                        │  toggle (off by default)
│ [+ Fork]  [⟿ Extend]  [🎯 Promote] │  actions (hidden unless edit-mode on)
└────────────────────────────────────┘
```

**Conditional rendering**:
- "Referenced by" hidden if empty
- "See Also" hidden if 0 candidates
- "Develop" hidden if 0 suggestions
- "Cycle warning" hidden unless `inCycle`
- Actions row hidden unless `editMode === true`

**Scroll**: whole zone-2-and-3 area scrolls independently; Zone-1 + actions sticky.

### 4.3 Cards-tab list (surface 3) — Discover strip

Leave the table as-is for browsing. Add **one new row at the top**: a deterministic 5-slot "Discover" strip.

```
┌───────────────────────────────────────────────────────────────────────┐
│  Discover                                                     [refresh]│
├────────────┬────────────┬────────────┬────────────┬────────────┬──────┤
│  Orphan    │ Cross-trunk│ Debate     │ Stub ready │ Re-read    │      │
│            │ bridge     │            │            │            │      │
│ zk-u8gt    │ zk-cwbp    │ zk-abc vs  │ zk-xyz     │ zk-71cl    │      │
│ 47d, 0 in  │ Applied →  │ zk-def     │ blocks 3   │ 92d, unread│      │
│            │ Humanities │ contradicts│            │            │      │
│ [view]     │ [view]     │ [view both]│ [develop]  │ [view]     │      │
└────────────┴────────────┴────────────┴────────────┴────────────┴──────┘
```

**Slot rules** (one best pick per slot, deterministic — no scoring alchemy):
1. **Orphan**: oldest card with `inbound + outbound == 0` that is not a stub
2. **Cross-trunk bridge**: edge where source and target have different `trunk.number`, prioritize `extends`/`supports` edges
3. **Debate**: any `ref:contradicts:*` edge, pick the pair with the most recent of the two cards
4. **Stub ready**: stub card that blocks the most open cards (has the most `blocked-by → this-stub` incoming)
5. **Re-read**: non-stub card with largest `now - updated_at` older than 30d, with at least one inbound edge (so it's not an orphan)

All 5 computable from labels + timestamps. One button per slot.

**Refresh**: manual button (top-right of strip). No auto-refresh, no algorithm, no freshness logic — deterministic repeat on the same data.

**Missing slots**: if a signal isn't present (no contradictions exist, no stubs), the slot shows "—" with a one-line explanation. Don't force-fill.

### 4.4 Cards-tab drilled-in modal (surface 4)

Already mostly there. Three changes to land unification:

1. **Remove What-If** block (`3694-3722`) — issue-tracker per mandate
2. **Rename Dependencies** section (`3633-3692`) from "Blocks / Blocked by" to **"Structural links"** (kind: blocks + derives-from + follows) — aligns with the Zone 3 grouping
3. **Add the action row** (same as graph portal) — `[+ Fork] [⟿ Extend] [🎯 Promote]`, behind edit-mode toggle

Everything else stays. The modal already does what the three-zone design prescribes.

---

## ✏️ 5. Edit + Extend affordances

Philosophy first: **"Edit" in a Zettelkasten is a new card in a new context, linked to the prior.** Per Luhmann's multiple-storage principle and the existing memory note `feedback_zettelkasten_no_embeddings.md` / `project_phase*`.

The action row exposes **5 affordances**, all mapped to existing MCP tools:

### 5.1 Fork (`+ Fork`) → `zk_save_card`

Opens a composer:
```
┌─────────────────────────────────────┐
│ New card, forked from zk-cwbp (5/7a)│
│                                     │
│ Kind: [▾ learning]                  │
│ Trunk: Applied Sci (inherited)      │
│                                     │
│ ┌─────────────────────────────────┐ │
│ │ Body markdown...                │ │
│ │                                 │ │
│ └─────────────────────────────────┘ │
│                                     │
│ [Cancel]             [Save fork]    │
└─────────────────────────────────────┘
```

Call: `zk_save_card({ body, kind, trunk: parent.trunk.number, mode: "fork", fromAddress: parent.folgezettel, source: "ui-fork-YYYYMMDD" })`.

Result: new card appears as child in the folgezettel tree. Viewer refreshes.

### 5.2 Extend (`⟿ Extend`) → `zk_propose_link` + `zk_commit_link`

Opens a link composer:
```
┌─────────────────────────────────────┐
│ Link from zk-cwbp to...             │
│                                     │
│ Target card: [🔍 Search or paste id]│
│                                     │
│ Edge type:                          │
│   ● supports   ○ contradicts        │
│   ○ extends    ○ reinforces         │
│   ○ refines                         │
│   (reviewed tier; auto-tier skipped)│
│                                     │
│ Rationale: ________________________ │
│                                     │
│ [Cancel]           [Propose → Commit]│
└─────────────────────────────────────┘
```

Call sequence: `zk_propose_link(...)` → auto `zk_commit_link(proposalId)`. Result: `ref:<type>:<target>` label appears on source card. Graph refreshes.

The 5 reviewed-tier types are the only options shown in UI — auto-tier (`follows`, `branches`, `derives-from`, `refers-to`, `annotates`, `continues`, `blocks`) are emitted by `zk_save_card`'s save-time extractors and shouldn't be hand-authored per `SAI/Algorithm/v3.8.1.md:64-75`.

**One-click propose** from "See Also" / "Develop" suggestions: clicking `[propose all]` on the See-Also bar opens the composer pre-filled with the suggested target and `extends` as default edge type. User picks the real type + writes rationale → commit.

### 5.3 Promote status (`🎯 Promote`) → `zk_promote`

Small dropdown:
```
  Status:  [▾ open]
           ○ open
           ○ in_progress
           ○ closed
```

No `blocked` option — that's the stub flow and requires the separate `zk_block` tool with stubs-first constraint.

Call: `zk_promote({ cardId, toStatus })`.

### 5.4 Add to hub (`Add to hub` — in Zone 1 overflow menu)

Hidden behind an overflow menu (three-dot) since it's rarer:
- Pick an existing hub (autocomplete on cards with `kind:hub`)
- `zk_hub_add_card({ hubId, cardId })`

### 5.5 Add keyword entry-point (`Add keyword` — in Zone 1 overflow menu)

- Input for keyword term
- `zk_keyword_add({ term, cardAddress: card.folgezettel })`

### Edit-mode toggle

A single toggle at the top of the action row (or Zone 1). Default OFF.

- OFF: card is read-only, no edit buttons visible
- ON: all 5 affordances visible

Why: preserves the "viewer" mental model for browsing; explicit opt-in to mutation keeps accidents away.

---

## 🌟 6. Serendipity surfacing — cross-cutting

Three places where serendipity is surfaced beyond the core views:

1. **Tooltip teases** — §4.1 — 0-2 lines
2. **Discover strip** — §4.3 — 5 deterministic slots
3. **Develop suggestions in Zone 3** — already present in Cards-tab modal, propagates to graph portal on unification

**Single underlying engine** (all zero-LLM):

| Signal | Input | Compute |
|---|---|---|
| Orphan | `card.edges` + inbound scan + `updated_at` | O(n) once on load |
| Cross-trunk | `card.edges` + target `.trunk` | O(edges) |
| Debate | `ref:contradicts:*` labels | O(edges) |
| Stub-ready | `kind:stub` + inbound `ref:blocks:*` count | O(n) |
| Re-read | `updated_at` + inbound count | O(n) |
| Shared keywords | `card.keywords` intersection | O(n × avg keywords) |

All precomputable once per load, cached in `store.*`. No MCP calls during browse.

---

## 🛡️ 7. Adversarial pass

### Steelman: don't build this at all

Three strongest arguments against:

1. **Cards-tab detail (surface 4) is already good.** The three-zone treatment landed earlier. Users who want depth can open the Cards tab. Unifying into the graph portal costs effort for redundant access.
2. **Edit mode is a mental-model shift.** Silmari was MCP-first by design. Every card was written by an Algorithm run. Adding click-to-edit trains users to bypass the reflection discipline that MCP saves enforce.
3. **The Discover strip is a dashboard creeping in.** The inventory explicitly put dashboard widgets in the Transform column. A 5-slot Discover strip is 5 widgets in disguise.

### Rebuttal

1. Graph → Cards-tab roundtrip is friction. When users are in graph-mode, making them switch tabs to see incoming edges is hostile. Unification cost is ~40 LOC of Alpine if template extraction is clean.
2. Edit mode defaults OFF. The MCP path is still the default; UI edit is a conscious escalation. This preserves discipline while unlocking quick captures.
3. Discover is 5 slots with deterministic rules, not 15 widgets with algorithms. It's a **browse** aid, not a dashboard. Cuttable if shown to bloat.

### Overengineering cut list

| Feature | Considered | Excluded — reason |
|---|---|---|
| Body-edit composer | ✋ | No MCP tool; violates multiple-storage |
| Undo/redo | ✋ | Cards are immutable by design |
| Embeddings-based See Also | ✋ | Memory rule: no embeddings |
| LLM-suggested titles | ✋ | Out of scope; breaks zero-LLM principle |
| Real-time collaborative edit | ✋ | Single-user product |
| Auto-linking from body-body similarity | ✋ | Embeddings smell |
| Per-edge-type filter UI in tooltip | ✋ | 12-type UI is noise; collapsed to 2 tiers |
| Animated breadcrumb hover | ✋ | Gratuitous |
| Export card to Markdown file from UI | ✋ | Already exists via `bv --export-md`; UI duplication |
| "Thinking streaks" gamification | ✋ | Gamification noise |
| Dashboard widgets (velocity, health, trajectory) | ✋ | Transform-tier, separate commits per inventory |
| 3D graph view, VR mode | ✋ | 2D is enough |

### Ordering proposal (MVP → full)

| Order | Surface | Why this order |
|---|---|---|
| 1 | **Unify graph portal with Cards-tab detail** (surface 2 ← surface 4) | Largest asymmetry; lowest new-design cost; purely wins |
| 2 | **Tooltip teases** (surface 1) | Single function rewrite; immediate visible change |
| 3 | **Action row — Fork + Extend + Promote** (surfaces 2+4) | Unlocks editing; most-requested affordance |
| 4 | **Discover strip** (surface 3) | Needs the O(n) serendipity-signal engine precomputed |
| 5 | **Overflow menu — Hub/Keyword/Block** (surfaces 2+4) | Polish |

Each step is independent, reversible, and ships behind an `editMode` toggle where applicable.

---

## 📐 8. Data contracts + MVP vs full

### Required data per surface (all available today unless marked):

| Surface | Fields from `card` object | New precomputations |
|---|---|---|
| Tooltip | id, title, kind, folgezettel, trunk, keywords, edges, updated_at, inbound | `sharedKeywordMatches(card)` — O(n × avg-keywords) |
| Graph portal | all of above + description + labels | inbound edges + see-also + develop suggestions (all derivable) |
| Cards list | id, title, status, priority, kind, updated_at | none new |
| Cards modal | all | same as graph portal |
| Discover strip | all + timestamps | 5 signal buckets (all O(n)) |

**No schema change.** Everything extractable from the existing `labels` table + issues columns. The post-strip `card_edges` table provides `edges`. Inbound edges require one O(n) scan at load → cache in `store.inboundByTarget`.

### MVP vs full vision

| Scope | MVP | Full |
|---|---|---|
| Unified body component | ✅ | |
| Tooltip teases | ✅ (3 signal types) | 5 signal types |
| Fork button | ✅ | |
| Extend button | ✅ | Auto-open from See-Also |
| Promote button | ✅ | |
| Edit-mode toggle | ✅ | Persistent per-user |
| Discover strip | | ✅ (separate commit) |
| Overflow menu (hub/kw/block) | | ✅ |
| Breadcrumb full titles (not just fz) | ✅ | |
| Children collapsible list | ✅ | |

---

## 📓 9. Open questions

1. Where does the edit-mode toggle live — header, settings modal, or persisted per-user preference?
2. Should the Fork composer be a modal, a slide-over, or inline below the card? (My bias: modal, matching the Extend pattern)
3. Do we surface the `source:` tag on saved UI-fork cards as "ui-fork" vs "algorithm-learn" so audits can distinguish? (Recommend: yes — set `source: "ui-fork"`)
4. When unifying, do we rename `graphDetailNode` and `selectedIssue` to a common `currentCard`, or keep both and dispatch at the template level? (Lower-risk: keep both, normalize on read)
5. Does the Discover strip survive on mobile (Cards tab is narrow-column there), or is it desktop-only?

---

## 🧾 Sources

- [Schmidt 2018 *The Fabrication of Serendipity*](https://sociologica.unibo.it/article/download/8350/8272/26621)
- [Doto 2024, Folgezettel is Not an Outline](https://writing.bobdoto.computer/folgezettel-is-not-an-outline-luhmanns-playful-appreciation-of-disfunction/)
- [zettelkasten.de, No, Luhmann Was Not About Folgezettel](https://zettelkasten.de/posts/luhmann-folgezettel-truth/)
- Prior silmari research:
  - `thoughts/searchable/shared/research/2026-04-12-zettelkasten-thinking-tool-dashboard-design.md` — widget spec + "notes talking back"
  - `thoughts/searchable/shared/research/2026-04-12-beads-viewer-zettelkasten-graph-redesign.md` — original three-zone design
  - `thoughts/searchable/shared/handoffs/general/2026-04-16_18-08-14_mcp-memory-update-viewer-redesign.md` — Task 2 status
  - `thoughts/searchable/shared/research/2026-04-19-viewer-fork-and-strip-inventory.md` — per-surface verdicts
  - `thoughts/searchable/shared/research/2026-04-18-dual-layer-graph-design.md` — hub-substrate reference (Path B)
- Source code (commit `1d90240`):
  - `apps/silmari-memory-card-viewer/viewer_assets/graph.js:2818-2876` — current tooltip
  - `apps/silmari-memory-card-viewer/viewer_assets/index.html:3066-3184` — graph portal
  - `apps/silmari-memory-card-viewer/viewer_assets/index.html:3366-3724` — Cards modal
  - `apps/silmari-mcp/src/index.ts:86-314` — MCP tool surface

*End of design.*
