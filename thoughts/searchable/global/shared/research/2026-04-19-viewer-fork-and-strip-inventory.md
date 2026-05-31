---
date: 2026-04-19T18:00:00-0400
researcher: Maceo Jourdan
git_commit: 1d9024022cd4d8433f36126f2449f4d62740ffd8
branch: main
repository: tha-hammer/silmari-agent-memory
topic: "Viewer fork-and-strip — complete surface inventory with keep/transform/delete verdicts"
tags: [inventory, viewer, fork-and-strip, zettelkasten, issue-tracker, bv, spa, tui, robot, analysis, source-of-truth]
status: complete
last_updated: 2026-04-19
last_updated_by: Maceo Jourdan
---

# Viewer Fork-and-Strip — Complete Surface Inventory

**Date**: 2026-04-19 · **Commit**: `1d90240` · **Epic**: `silmari-agent-memory-xom`

---

## Purpose

This document is the **source of truth** for per-surface verdicts (Keep / Transform / Delete) across every component of the current silmari viewer stack (SPA + TUI + robot API + Go analysis pipeline). Every strip commit under epic `silmari-agent-memory-xom` cites this inventory for its scope justification. If a surface isn't listed here, it's undecided — add it before acting.

Verdicts were settled in the 2026-04-19 conversation, after:
1. Review of `apps/silmari-viewer/` and `apps/silmari-memory-card-viewer/` source code (Explore agent dump)
2. Corrected understanding of the data model vs. the UI semantics (issue-tracker substrate being forced into Zettelkasten dress)
3. Explicit trade-off framing — replacement vs. fork-and-strip vs. incremental de-issue-trackering
4. User's choice of **Path A** (fork-and-strip in place) with **Path B** (greenfield) as long-term destination

The inventory is not a ranking or a roadmap — it's a disposition table. Ordering of commits is a separate discussion handled per strip task.

---

## 1. SPA — what loads at `http://localhost:8788`

What the user sees daily. The most important inventory.

| # | Surface | Verdict | Rationale |
|---|---|---|---|
| 1 | Cards list / table | **Keep** | List-of-cards is universal; vocab already reads as Zettelkasten |
| 2 | Markdown body render | **Keep** | Universal |
| 3 | Search bar | **Keep** | Universal |
| 4 | Resume banner (in-progress cards) | **Keep** | Session-resume is Zettelkasten-native |
| 5 | Zoom controls, pan, drag | **Keep** | Universal graph plumbing |
| 6 | Legend (by card kind) | **Keep** | Kind-legend is Zettelkasten-native (already) |
| 7 | OPFS snapshot / sql.js cache | **Keep** | Infrastructure; semantics-neutral |
| 8 | Graph view (layout + nodes + edges) | **Transform** | Keep the "see the network of my thinking" intent; redesign what it shows (drop PageRank heatmap, critical-path coloring, blocker-path highlight) |
| 9 | Card detail panel (right portal) | **Transform** | Keep the portal + kind/trunk/folgezettel context bar + markdown body + typed-edge list. Drop the PageRank/betweenness metrics grid. |
| 10 | Filter panel (lifecycle / priority / labels) | **Transform** | Drop "priority" (issue-tracker). Keep status, keep labels (rename to keywords/trunk/hub). |
| 11 | Dashboard widgets ("Ready to Develop", "Most Connected", etc.) | **Transform** | The vocab fits Zettelkasten. What each widget computes probably needs rewrite (if "Most Connected" is PageRank, transform; if raw edge count, keep). Depends on implementation — audit per widget. |
| 12 | Cycle detection rendering (pink nodes) | **Transform** | Cycles are meaningful in thinking (extends+contradicts loops = live debate). Keep detection, reframe: "this card is in a debate loop" not "bug". |
| 13 | Cmd+click dependency path highlight | **Transform** | Current behavior is "show blockers and blocking" — issue-tracker. The interaction pattern (pick a card, see its lineage) is valuable; rewrite what it shows → folgezettel-chain / crossref-chain highlight. |
| 14 | WASM metrics engine (PageRank / betweenness / k-core / critical-path / HITS / slack / cycles / articulation) | **Transform** | Keep as infrastructure. Most of the 9 algorithms compute questions you don't ask — delete their user-facing call sites. What might survive in new use: cycles, connected-component, raw edge count per node. |
| 15 | Heatmap toggle (PageRank/betweenness/critical-depth coloring) | **Delete** | Every option is issue-tracker. Link-authority, bottleneck, deadline-depth — no Zettelkasten analog. *(First strip commit: `silmari-agent-memory-9al`.)* |
| 16 | What-if cascade (Shift+click) | **Delete** | "Simulate closing this issue, what gets unblocked" — pure issue-tracker. |
| 17 | Critical path highlight (keyboard shortcut) | **Delete** | Critical path is delivery-deadline math. |
| 18 | Cards-tab detail-panel Graph Metrics grid (PageRank/Betweenness/Critical Depth/Triage Score) | **Delete** | All four values are issue-tracker metrics; semantically identical to the Graph-view detail-panel metrics grid. Discovered and stripped inline during `silmari-agent-memory-5tu` execution (2026-04-19); row added post-hoc via `silmari-agent-memory-jgi`. |

**SPA totals**: 7 Keep · 7 Transform · 4 Delete (18 surfaces)

---

## 2. TUI — terminal mode (`./bv --db ...`)

Mostly collateral damage of the issue-tracker origin. The user primarily works through the SPA; TUI strips are lower-priority but the verdicts stand.

| # | View | Verdict | Rationale |
|---|---|---|---|
| 1 | Semantic Search (text search) | **Keep** | Universal |
| 2 | Tree (hierarchy) | **Transform** | Currently shows dependency tree — rewrite as folgezettel tree or hub-membership tree |
| 3 | Recipe Picker (saved filter presets) | **Transform** | The concept "saved views" is universal; existing recipes (triage, actionable, high-impact) are issue-tracker and get replaced |
| 4 | Label Dashboard | **Transform** | Rename to keyword/trunk/hub dashboard; rewrite the metrics it computes |
| 5 | Graph (ASCII) | **Transform** | Same fate as SPA graph (→ row SPA-8) |
| 6 | Board (kanban columns) | **Delete** | Kanban is workflow ritual, not thinking |
| 7 | Sprint | **Delete** | No Zettelkasten analog |
| 8 | Triage | **Delete** | "What to work on next" is a work-queue question |
| 9 | Insights dashboard | **Delete** | Bottlenecks, keystones, articulation points — all workflow-framed |
| 10 | Flow Matrix (2×2 urgency/importance) | **Delete** | Eisenhower matrix for tasks; not thoughts |
| 11 | Velocity Comparison (week/sprint closure) | **Delete** | Delivery cadence |
| 12 | History (git commit ↔ bead correlation) | **Delete** | Zettelkasten doesn't care about git |
| 13 | Attention (labels ranked by impact × action density) | **Delete** | Built on issue-tracker metrics |

**TUI totals**: 1 Keep · 4 Transform · 8 Delete (13 views)

---

## 3. Robot / JSON automation surface (`--robot-*`)

~25 top-level commands (some commands expand to multiple sub-commands — counts are approximate at the cluster level). Most of this surface is pure issue-tracker.

| Command cluster | Verdict | Notes |
|---|---|---|
| `--robot-graph` (JSON / DOT / Mermaid export of topology) | **Keep** | Structure export is universal |
| `--robot-search` | **Keep** | Text search |
| `--robot-orphans` | **Keep** | Orphan cards = unintegrated thought — a real Zettelkasten signal |
| `--export-md`, `--export-graph`, `--export-pages` | **Keep** | Delivery surfaces |
| `--robot-suggest` (duplicates / missing deps / label suggestions / cycles) | **Transform** | Duplicate detection keeps; "missing deps" reframes as "missing crossrefs"; label suggest keeps; cycles reframe as debate-loops |
| `--robot-label-health`, `--robot-label-flow`, `--robot-label-attention` | **Transform** | Reframe as keyword / trunk / hub analytics |
| `--robot-diff` (snapshot diff) | **Transform** | Snapshot diff is universal; rename verb |
| `--robot-insights`, `--robot-plan`, `--robot-priority`, `--robot-triage*`, `--robot-next`, `--robot-alerts`, `--robot-drift` | **Delete** | Workflow triage engine — no analog |
| `--robot-sprint-*`, `--robot-forecast`, `--robot-capacity`, `--robot-burndown` | **Delete** | Delivery cadence |
| `--robot-history`, `--robot-file-*`, `--robot-impact`, `--robot-related`, `--robot-blocker-chain`, `--robot-impact-network`, `--robot-causality` | **Delete** | Git / work semantics |
| `--agent-brief`, `--priority-brief` | **Delete** | Issue-tracker briefing bundles |
| `--feedback-*`, `--check-drift`, `--baseline-*` | **Delete** | Feedback loop tunes triage weights — gone with triage |

**Robot totals (cluster-level)**: ~4 Keep · ~4 Transform · ~17 Delete

---

## 4. Analysis pipeline (Go `pkg/analysis/`) — what actually computes

| # | Module | Verdict | Notes |
|---|---|---|---|
| 1 | `duplicates.go` | **Keep** | Duplicate detection is universal |
| 2 | `label_suggest.go` | **Keep** | Content-based label suggestions transfer to keyword-register suggestions |
| 3 | `diff.go` (snapshot diff) | **Keep** | Universal |
| 4 | `graph.go` (topology + metrics) | **Transform** | Keep connectivity + raw degree; drop PageRank/betweenness call sites |
| 5 | `cycle_warnings.go` | **Transform** | Detection keeps; reframe cycles as debate loops |
| 6 | `dependency_suggest.go` | **Transform** | "Missing edges" → "missing crossref suggestions" |
| 7 | `label_health.go` | **Transform** | Rewrite metrics for Zettelkasten questions |
| 8 | `suggest_all.go` | **Transform** | Aggregator — rewrite to aggregate the transformed-kept subset |
| 9 | `insights.go` | **Delete** | Bottlenecks / keystones / articulation points |
| 10 | `priority.go` | **Delete** | Priority ranking by graph metrics |
| 11 | `plan.go` | **Delete** | Dependency-respecting execution plan |
| 12 | `triage.go` | **Delete** | Main triage engine |
| 13 | `triage_context.go` | **Delete** | Triage context builder |
| 14 | `risk.go` | **Delete** | Single-point-of-failure scoring |
| 15 | `advanced_insights.go` | **Delete** | Coverage sets, k-paths, parallel cuts |
| 16 | `whatif.go` | **Delete** | What-if analysis |
| 17 | `eta.go` | **Delete** | ETA forecasting |
| 18 | `betweenness_approx.go` | **Delete** | Betweenness sampling — metric goes |
| 19 | `feedback.go` | **Delete** | Triage-weight tuning |
| 20 | `correlation.go` | **Delete** | Git ↔ bead correlation |

**Analysis totals**: 3 Keep · 5 Transform · 12 Delete (20 modules)

---

## 5. Rough shape of the answer

| Domain | Keep | Transform | Delete | Total |
|---|---|---|---|---|
| SPA | 7 | 7 | 4 | 18 |
| TUI | 1 | 4 | 8 | 13 |
| Robot (cluster-level) | ~4 | ~4 | ~17 | ~25 |
| Analysis | 3 | 5 | 12 | 20 |
| **Total** | **~15 (20%)** | **~20 (26%)** | **~41 (54%)** | **~76** |

**Takeaway**: roughly half of `bv` is deletable. A quarter needs rewriting. A quarter survives as-is.

> *Note on counts*: The 2026-04-19 conversation quoted rough ratios of ~7/5/5 for SPA and ~23%/25%/52% overall. Those were approximate — the precise row-level tallies are as shown above (SPA settled to 7/7/3 after Cmd+click was promoted from Delete to Transform; TUI settled to 1/4/8). The overall percentage shifts are trivial (~3 percentage points). Verdicts per surface are the binding artifact; the aggregate percentages are commentary. *(Amended 2026-04-22 via `silmari-agent-memory-jgi`: SPA adjusted from 7/7/3 → 7/7/4 with the addition of row 18, Cards-tab detail-panel Graph Metrics grid — a Delete discovered post-hoc during `-5tu` execution. Grand total shifted 75 → 76.)*

---

## 6. Settled disambiguations (2026-04-19)

- **"Heatmap"** — the inventory's "Heatmap toggle" (SPA row 15) refers specifically to the **graph-node heatmap** (PageRank/betweenness/critical-depth coloring of force-graph nodes). A *separate* feature called "Label Dependency Heatmap" exists at `charts.js:531-700` + `index.html:1033-1043` — it's a different widget and a different strip commit. Don't conflate.
- **`kind:hub` cards vs. `zk_status.hubs`** — `zk_status.hubs` counts a formal registry (via `zk_hub_create`); it returns 0 in the current store. **Cards with `kind:hub` label** number 28, visible in the graph as orange nodes. Different concepts. The Dashboard-widget transform commit needs to pick which signal it uses; this inventory does not pre-decide that.
- **Cmd+click** — moved from Delete to Transform after the 2026-04-19 review. Interaction pattern (pick a card, see its lineage) is valuable; what it *shows* changes (no more blockers/blocking; instead folgezettel chain or crossref chain).
- **WASM metrics engine** — Transform, not Delete. Infrastructure stays (per mandate); individual algorithm outputs are surfaced only when a Zettelkasten-appropriate question exists for them.
- **Status words (`open/in_progress/blocked/closed`)** — vocabulary is on the rename table. "Blocked" specifically is issue-tracker vocabulary. The `vocab.js:13-15` comment claiming they're preserved-literally is stale and will be removed in a vocabulary commit.
- **Git correlation** — full delete across all surfaces (not kept anywhere).

---

## 7. Cross-references

- **Mandate**: `~/.claude/projects/-home-maceo-Dev-silmari-agent-memory/memory/project_viewer_fork_and_strip_mandate.md`
- **Epic**: `silmari-agent-memory-xom` — *Viewer fork-and-strip toward Zettelkasten-native*
- **First child task**: `silmari-agent-memory-9al` — *Strip graph-node heatmap toggle from SPA*
- **TDD plan for first strip**: `thoughts/searchable/shared/plans/2026-04-19-tdd-strip-graph-heatmap-from-spa.md` (amended 2026-04-19)
- **Review of first TDD plan**: `thoughts/searchable/shared/plans/2026-04-19-tdd-strip-graph-heatmap-from-spa-REVIEW.md`
- **Prior research that this inventory supersedes as the per-surface source of truth**:
  - `thoughts/searchable/shared/research/2026-04-18-siyuan-as-beads-viewer-replacement.md` (settled the "replace with SiYuan" question: no)
  - `thoughts/searchable/shared/research/2026-04-18-dual-layer-graph-design.md` (Path-B reference design; not the Path-A roadmap)
- **Screenshot that falsified the earlier "hubs:0" claim**: `~/Pictures/Screenshots/2026-04-19_16-24.jpg`

---

## 8. How to use this document

- **For every strip commit**: cite the inventory row number(s) (e.g. "SPA-15" for heatmap) in the commit's bd task description. That gives auditors a direct trace.
- **If a surface is missing from this inventory**: add it *before* writing the strip commit — with a verdict and rationale. Don't delete or transform anything that isn't listed.
- **If a verdict needs to change**: update the row here, note the change in §6 "Settled disambiguations" with date + reason, then update the relevant epic/task. The inventory is the binding artifact — commits follow it.
- **For ordering**: this document does not prescribe order. Ordering happens per-task under the epic. The only current order decision is that the heatmap strip (SPA-15) is first.

*End of inventory.*
