---
date: 2026-04-18T14:55:00-04:00
researcher: Maceo Jourdan
git_commit: 1d9024022cd4d8433f36126f2449f4d62740ffd8
branch: main
repository: tha-hammer/silmari-agent-memory
topic: "Evaluating silmari-knowledge-management (SiYuan fork) as a replacement for beads_viewer"
tags: [research, beads_viewer, bv, silmari-viewer, card-viewer, siyuan, knowledge-management, replacement-analysis, architecture]
status: complete
last_updated: 2026-04-18
last_updated_by: Maceo Jourdan
---

```
┌────────────────────────────────────────────────────────────────────────┐
│                                                                        │
│   Research: Can SiYuan (silmari-knowledge-management) replace bv?      │
│                                                                        │
│   Date:    2026-04-18                                                  │
│   Commit:  1d90240                                                     │
│   Status:  Complete — Documentation only, no code changes              │
│                                                                        │
└────────────────────────────────────────────────────────────────────────┘
```

# Research: Can SiYuan (silmari-knowledge-management) replace beads_viewer?

**Date**: 2026-04-18 14:55 ET
**Researcher**: Maceo Jourdan
**Git Commit**: `1d90240`
**Branch**: `main`
**Repository**: tha-hammer/silmari-agent-memory

---

## 🎯 Research Question

> "We have a possible replacement for beads_viewer — `tha-hammer/silmari-knowledge-management`. Study the repo API and help me understand if the path to replace beads_viewer is viable."
>
> Reference: https://github.com/tha-hammer/silmari-knowledge-management/blob/master/API.md

---

## 🧭 TL;DR

**`silmari-knowledge-management` is a fork of [SiYuan](https://github.com/siyuan-note/siyuan)** — a mature, block-based WYSIWYG *authoring* platform (Notion/Obsidian-class). **`beads_viewer` (the `bv` binary) is a read-only *analytics+display* engine** over an issue-graph store (beads SQLite). They solve fundamentally different problems against fundamentally different data models.

| Axis | `bv` (current) | SiYuan (proposed) |
|---|---|---|
| **Primary purpose** | Read-only viewer + graph analytics | Interactive note editor |
| **Core entity** | Issue (id, status, deps, labels) | Block (kramdown, type, parent) |
| **Data store** | beads SQLite (issues + deps) | `.sy` JSON files + SQLite index |
| **TUI** | 13 specialized views | None |
| **Graph analytics** | PageRank, betweenness, cycles, critical path, 15+ modules | None (generic block-ref only) |
| **Typed links** | 12 explicit types (`follows`, `derives-from`, `branches`, …) | Generic bidirectional block-ref only |
| **Robot/JSON API** | 25+ `--robot-*` commands | REST CRUD only |
| **Tags / folgezettel / kinds / trunks** | Modeled as labels (11 kinds, 5 trunks, addressing) | No native equivalent |

**Conclusion:** SiYuan is not a drop-in replacement. Adopting it would require replacing ~90% of `bv`'s value surface with custom SiYuan plugins/adapters **plus** a continuous projection from beads → SiYuan blocks — and you'd still lack PageRank, triage, TUI, and the folgezettel/edge-typing semantic layer. The current architectural roadmap (see `thoughts/searchable/shared/plans/2026-04-17-tdd-force-graph-edges-fix.md`) continues iterating on the `bv` export + Alpine SPA rather than swapping the substrate.

The only sensible "replacement path" framings are:
- **(A) Pure UI skin swap** — use SiYuan *only* as a frontend viewer by projecting silmari's 261 cards into SiYuan documents/blocks; keep `bv` as the analytics engine and keep `silmari-mcp` as the write path. Large integration cost for modest UX gain.
- **(B) Migrate authoring** — use SiYuan as the *editor* (users write in SiYuan; silmari-mcp captures via API). Ends the agent-memory thesis; silmari becomes a human note app.
- **(C) Hybrid** — embed SiYuan iframe in one panel of the existing card-viewer SPA for prose editing only. Small scope, preserves `bv`.

None of these match the word "replace" as a one-for-one substitution.

---

## 📋 Summary

Three distinct things in this repo currently use the name "viewer." Replacing "beads_viewer" means replacing the first two, because the third is a shim over them:

1. **`apps/silmari-viewer/` — the Go `bv` binary** (fork of `Dicklesworthstone/beads_viewer`). 53 MB compiled artifact. Provides a 13-view Bubble Tea TUI, a 25+ flag robot/JSON automation surface, a `--export-pages` static-site generator, and 15+ graph-analytics modules. Reads `~/.silmari-memory/box2-ideas/.beads/beads.db` directly.
2. **`apps/silmari-memory-card-viewer/` — a 380-LOC Bun HTTP server** at `:8788` that lazily shells out to `bv --export-pages`, overlays `viewer_assets/` SPA customizations, and runs silmari-specific edge synthesis (`ref:<type>:<target>` labels → `card_edges` table).
3. **The SPA bundle itself** — `viewer_assets/*.js` (viewmodel, vocab, graph, threads) + `bv-graph-wasm` for client-side force-directed layout and PageRank.

`silmari-knowledge-management` is SiYuan: a Go kernel + TypeScript/Electron WYSIWYG block editor, headless-capable via Docker (port 6806), with a comprehensive REST API for CRUD on Notebooks, Documents, and Blocks (kramdown). It has no native concept of issues, statuses, dependencies, typed edges, graph centrality, folgezettel addressing, trunks, or card kinds.

This research documents both surfaces in full, maps the gap coverage, and describes the integration cost of each viable adoption path.

---

## 📚 Detailed Findings

### 1. Current State — `apps/silmari-viewer` (the `bv` binary)

**Lineage** (`apps/silmari-viewer/README.md:5-9`):
> "Fork of [beads_viewer](https://github.com/Dicklesworthstone/beads_viewer) (`bv`), rebranded for Silmari Agent Memory. The upstream Go module path is preserved in import paths; only user-visible strings are rebranded. Binary name stays `bv` per ops tooling convention."

**Architectural boundary** (`apps/silmari-viewer/README.md:34-38`):
> "This viewer is a **standalone binary**. It reads the beads SQLite database directly. It does NOT speak MCP, does NOT call into `silmari-mcp`, and does NOT share a transport with it. The viewer and the MCP server share exactly one thing: the storage substrate."

#### 1.1 CLI Surface — 80+ flags

<details>
<summary><b>Top-level modes (click to expand)</b></summary>

- **TUI** — default invocation, 13-view Bubble Tea interface
- **Static-site export** — `--export-pages <dir>` with `--pages-title`, `--pages-include-closed`, `--pages-include-history`, `--watch-export`
- **Interactive deploy wizard** — `--pages` launches guided flow
- **Preview bundle** — `--preview-pages <dir>` with optional `--no-live-reload`
- **Markdown export** — `--export-md <file>`
- **Graph export** — `--export-graph [<dir>]` with `--graph-format {json|dot|mermaid}`, `--graph-preset {compact|roomy}`, `--graph-title`
- **Priority brief** — `--priority-brief <file>`
- **Agent brief bundle** — `--agent-brief <dir>` (produces `triage.json`, `insights.json`, `brief.md`, `helpers.md`)
- **Script emit** — `--emit-script` + `--script-format {bash|fish|zsh}`, `--script-limit`

</details>

<details>
<summary><b>Robot commands (25+ JSON/automation endpoints)</b></summary>

- `--robot-help` / `--robot-docs` / `--robot-schema` / `--schema-command`
- **Recommendations**: `--robot-insights`, `--robot-plan`, `--robot-priority`, `--robot-triage` (+ `-by-track`, `-by-label`), `--robot-next`, `--robot-recipes`
- **Labels**: `--robot-label-health`, `--robot-label-flow`, `--robot-label-attention`
- **Diff/drift**: `--robot-diff`, `--robot-drift`, `--check-drift` (exit 0/1/2)
- **Suggestions**: `--robot-suggest` (`--suggest-type {duplicate|dependency|label|cycle}`)
- **Graph**: `--robot-graph` (`--graph-format`, `--graph-root`, `--graph-depth`)
- **Search**: `--robot-search` + `--search` + hybrid weights
- **History/correlation**: `--robot-history`, `--bead-history`, `--robot-explain-correlation`, `--robot-confirm-correlation`, `--robot-reject-correlation`, `--robot-correlation-stats`, `--robot-orphans`
- **File-impact**: `--robot-file-beads`, `--robot-file-hotspots`, `--robot-impact`, `--robot-file-relations`, `--robot-related`
- **Blocker/network**: `--robot-blocker-chain`, `--robot-impact-network`, `--robot-causality`
- **Sprint/capacity**: `--robot-sprint-list`, `--robot-sprint-show`, `--robot-forecast`, `--robot-capacity`, `--robot-burndown`
- **Metrics**: `--robot-metrics`, `--robot-alerts`

</details>

#### 1.2 TUI Views (13)

| View | Purpose |
|---|---|
| **Board** | Kanban columns (To Do / In Progress / Done), card drag-and-drop |
| **Tree** | Hierarchical dependency tree |
| **Graph** | Interactive ASCII force-directed view |
| **Sprint** | Sprint planning + burndown |
| **Triage** | Sorted recommendations with reasoning |
| **Insights** | Bottlenecks, keystones, cycles, articulation points, orphans |
| **Recipe Picker** | Saved filter presets (triage, actionable, high-impact, …) |
| **Semantic Search** | Vector search with hybrid scoring |
| **Flow Matrix** | 2×2 urgency/importance grid |
| **Velocity Comparison** | Week-over-week + sprint closure rates |
| **History** | Git commit ↔ bead correlation timeline |
| **Label Dashboard** | Per-label subgraph metrics + health |
| **Attention** | Labels ranked by impact × action density |

#### 1.3 Analysis Modules (`pkg/analysis/`)

| Module | What it computes |
|---|---|
| `graph.go` | PageRank, betweenness, eigenvector, HITS hub/authority, critical path depth, k-core, articulation points, cycles (gonum) |
| `cycle_warnings.go` | Cycle detection + break suggestions |
| `dependency_suggest.go` | Missing-edge suggestions via keyword/label overlap (inverted index) |
| `duplicates.go` | Title/description similarity duplicate finder |
| `insights.go` | Bottlenecks, keystones, cores, slack |
| `label_health.go` | Per-label open count, blocked ratio, velocity, criticality |
| `label_suggest.go` | Content-based label suggestions |
| `priority.go` | Combined graph-metric priority ranking |
| `plan.go` | Dep-respecting execution plan + unblock chain |
| `triage.go` | Main triage engine (plan + priority + insights) |
| `triage_context.go` | Graph-state context for triage |
| `risk.go` | Critical-node / single-point-of-failure scoring |
| `suggest_all.go` | Aggregate suggestion engine |
| `betweenness_approx.go` | Approximate betweenness for large graphs |
| `eta.go` | ETA and completion-time forecasting |
| `advanced_insights.go` | Coverage sets, k-paths, parallel cuts |
| `whatif.go` | What-if (effect of closing an issue) |
| `diff.go` | Snapshot diffing over time |
| `feedback.go` | Triage weight tuning via user feedback |
| `correlation.go` | ML-based commit ↔ bead linking |

#### 1.4 Exported SQLite Schema (`pkg/export/sqlite_export.go`, `sqlite_types.go`)

```sql
-- Core
issues(id PK, title, description, status, priority, issue_type, assignee,
       labels JSON, created_at, updated_at, closed_at,
       blocks_count, blocked_by_count)
dependencies(id PK, issue_id FK, depends_on_id FK, type DEFAULT 'blocks')
comments(id PK, issue_id FK, author, text, created_at)

-- Metrics (pre-computed by bv)
issue_metrics(issue_id PK FK, pagerank, betweenness, critical_path_depth,
              triage_score, blocks_count, blocked_by_count)
triage_recommendations(issue_id PK FK, score, action, reasons,
                       unblocks_ids, blocked_by_ids)

-- Search
issues_fts  -- FTS5 virtual table (tokenize: porter unicode61)

-- Meta
export_meta(key PK, value)   -- version, git commit, issue count, data hash

-- Indexes
idx_issues_status, idx_issues_priority, idx_issues_updated, idx_issues_type_status
idx_deps_issue, idx_deps_depends, idx_deps_type
idx_comments_issue, idx_comments_created
idx_metrics_score, idx_metrics_pagerank
```

#### 1.5 `--export-pages` Output Manifest

```
<dir>/
├── index.html                       # Alpine-based SPA entry
├── viewer.js                        # ~115 KB
├── styles.css                       # ~53 KB (Tailwind-compiled)
├── graph.js                         # ~130 KB force-graph + metrics wiring
├── graph-helpers.js                 # kindColor, kindSize, edgeLinkColor, …
├── charts.js                        # Chart.js wrapper for burndown/velocity
├── hybrid_scorer.js                 # client-side hybrid search
├── link-builder.js                  # issue → URL
├── wasm_loader.js                   # bv-graph-wasm init
├── vocab.js                         # window.V — edge types, kinds, trunks
├── viewmodel.js                     # row → card transformer
├── threads.js                       # folgezettel tree placeholder
├── coi-serviceworker.js             # COOP/COEP for SharedArrayBuffer
├── beads.sqlite3                    # SQLite snapshot (chunked > 5MB)
├── beads.sqlite3.chunk.{0..N}       # 1 MB range-request chunks
├── beads.sqlite3.chunk.manifest.json
├── data/
│   ├── triage.json, insights.json, issues.json
│   ├── brief.md, helpers.md
│   └── history.json
├── .github/workflows/deploy.yml     # GitHub Pages auto-deploy
└── README.md
```

---

### 2. Current State — `apps/silmari-memory-card-viewer` (Bun server shim)

**Role** (`apps/silmari-memory-card-viewer/server.ts:2-34`):
> "Serves the beads_viewer SPA pointed at `~/.silmari-memory`. The SPA assets and preprocessed sqlite are produced by shelling out to `bv --export-pages` and cached under CACHE_DIR. The cache is lazily regenerated whenever the source beads.db mtime or its WAL mtime exceeds the cached export's mtime, so the browser reflects recent silmari saves without the user restarting anything."

**Route surface:**

| Path | Behavior |
|---|---|
| `GET /` | overlay check → `viewer_assets/index.html` (overrides cache) |
| `GET /<asset>` | `viewer_assets/<asset>` if present, else `CACHE_DIR/<asset>` |
| `GET /api/health` | JSON status payload (mtimes, regen-pending, synth count) |

**Silmari-specific logic** (beyond what `bv` ships):

1. **Edge synthesis** (`server.ts:141-174` `synthesizeEdgesFromLabels`) — after every `bv --export-pages`, scan `issues.labels` JSON for `ref:<type>:<target>` entries, parse via `parseRefLabel` (line 96, whitelist of 12 types), and insert rows into a server-owned `card_edges(source, target, type)` table. Idempotent via `INSERT OR IGNORE` on the composite PK.
2. **OPFS cache bust** (`server.ts:184-201` `refreshSnapshotConfig`) — recompute `sha256(beads.sqlite3)` into `beads.sqlite3.config.json` so the browser's OPFS cache invalidates.
3. **Overlay file system** (`server.ts:270-283` `resolveServedPath`) — prefer `viewer_assets/` (customized files) over `CACHE_DIR/` (bv-generated). Path-traversal guard via `..` rejection + normalize prefix check.

**Env surface** (`apps/silmari-memory-card-viewer/README.md:36-42`):

| Var | Default | Meaning |
|---|---|---|
| `PORT` | `8788` | HTTP port |
| `SILMARI_DIR` | `~/.silmari-memory` | Store root (⚠️ *not* `SILMARI_STORE`) |
| `CARD_VIEWER_CACHE_DIR` | `/tmp/silmari-memory-card-viewer-cache` | bv export target |
| `BV_BIN` | `bv` | Binary name on PATH |

**Data flow:**

```
~/.silmari-memory/box2-ideas/.beads/beads.db    (source, written by silmari-mcp)
   │
   │   bv --export-pages CACHE_DIR   (lazy, mtime-triggered)
   ▼
CACHE_DIR/beads.sqlite3              (export: issues, dependencies blocks-only, FTS5)
   │
   │   synthesizeEdgesFromLabels()   (server-side post-pass)
   ▼
CACHE_DIR/beads.sqlite3              (+ card_edges table with 12 typed edges)
   │
   │   refreshSnapshotConfig()       (sha256 → config.json)
   ▼
Browser fetches via /beads.sqlite3.chunk.N + sql.js → renders Alpine + Force-Graph
```

---

### 3. SPA Data Contract (what the browser consumes)

**Input**: SQLite snapshot + (implicit) pre-computed `issue_metrics` + new `card_edges`.

**`viewmodel.js` — extracts from `issues.labels` JSON strings:**

| Label prefix | Field produced |
|---|---|
| `scope:*` | `.scope` |
| `fz:*` | `.folgezettel` (`_` → `/`) |
| `kind:*` | `.kind` (one of 11 card kinds) |
| `trunk:N` | `.trunk = {number, name}` |
| `box:*` | `.box ∈ {idea, biblio}` |
| `keyword:*` | `.keywords[]` |
| `ref:<type>:<target>` | `.edges[] = {type, targetId}` |

Output `toCard(row)` shape:
```js
{ id, title, description, lifecycle, isStub, priority, tags,
  linksOut, linksIn, createdAt, updatedAt,
  scope, folgezettel, kind, trunk, box, keywords, edges }
```

**`graph.js` — force-graph node/link shape:**

Nodes:
```js
{ id, title, description, status, priority, type, labels,
  pagerank, betweenness, criticalDepth, eigenvector, kcore,   // ← WASM
  inCycle, blockerCount, dependentCount,
  kind, trunk, box, keywords, folgezettel }                   // ← ZK enrichment
```

Links (unions both tables):
```js
{ source, target, type }   // type: 'blocks' | 'follows' | 'continues' |
                           //       'branches' | 'derives-from' | 'refers-to' |
                           //       'annotates' | 'supports' | 'contradicts' |
                           //       'extends' | 'reinforces' | 'refines'
```

**`bv-graph-wasm`** — Rust-compiled WASM. Type-agnostic: only `addEdge(from: usize, to: usize)`. JS filters `dependencies` to `type === 'blocks'` before feeding to WASM for DAG algorithms (PageRank, betweenness, k-core, critical path, articulation points, cycle detection, HITS). Typed edges are a JS-only rendering concern.

**`vocab.js` (`window.V`)** — single source of truth for:
- 4 lifecycle states (`open`, `in_progress`, `blocked`, `closed`) + tooltips
- 11 card kinds (register, hub, structure, fact, preference, biblio, learning, decision, idea, signal, stub) + tooltips
- 12 edge types + color + style + tier (auto/reviewed)
- 5 trunks + colors
- SAI branding strings

**`index.html`** — ~3900 lines, single Alpine `x-data="beadsApp()"` root. Key sections: resume banner (in-progress), filter panel, card list/table, force-graph container, right-side card detail portal (ZK context bar, markdown body, metrics grid, typed-edges-grouped-by-type, keywords, what-if simulation).

**`coi-serviceworker.js`** — adds `Cross-Origin-Embedder-Policy: credentialless` + `Cross-Origin-Opener-Policy: same-origin` to enable `SharedArrayBuffer` (sql.js + WASM threads).

---

### 4. Proposed Replacement — `silmari-knowledge-management` (SiYuan fork)

**What it is:** A fork of `siyuan-note/siyuan` — 22,107 commits, TypeScript (56%) + Go (31%) + JS (8%), Electron desktop + Android/iOS apps + Docker server mode.

**Positioning (upstream README):**
> "A privacy-first personal knowledge management system, support fine-grained block-level reference and Markdown WYSIWYG."

**Headless mode:**
```bash
docker run -v /siyuan/workspace:/siyuan/workspace -p 6806:6806 b3log/siyuan
```
Docker limitation (noted in upstream README): *"Does not support desktop and mobile application connections, only supports use on browsers."*

**Architecture:**
- **Kernel** (Go) — HTTP server on `:6806`, core indexing + query
- **App** (TypeScript frontend) — in-browser or Electron
- **Lute** — separate Markdown/kramdown editor engine
- **Dejavu** — sync + encryption
- **Plugin/extension** — bazaar marketplace

#### 4.1 API Surface (from `API.md`)

**Auth:** `Authorization: Token xxx` header, token from Settings → About.
**Transport:** all endpoints are `POST` with `Content-Type: application/json`.
**Response envelope:** `{ code: 0, msg: "", data: {...} }`.
**Base URL:** `http://127.0.0.1:6806`.

**Endpoint categories:**

| Category | Endpoints | Notes |
|---|---|---|
| **Notebooks** | `/api/notebook/{ls,open,close,rename,create,remove,getConf,setConf}` | Top-level containers |
| **Documents** (filetree) | `/api/filetree/{createDocWithMd,rename,renameByID,remove,removeByID,moveDocs,moveDocsByID,getHPathByPath,getHPathByID,getPathByID,getIDsByHPath}` | Path/ID addressing — both supported |
| **Blocks** | `/api/block/{insert,prepend,append,update,delete,move,fold,unfold,getKramdown,getChildBlocks,transferBlockRef}` | Kramdown is the wire format |
| **Attributes** | `/api/attr/{setBlockAttrs,getBlockAttrs}` | Custom attrs must use `custom-` prefix |
| **SQL** | `/api/query/sql` (`stmt`), `/api/sqlite/flushTransaction` | SQL disabled in Publish Mode |
| **Assets** | `/api/asset/upload` | Multipart, `file[]` array |
| **File I/O** | `/api/file/{getFile,putFile,removeFile,renameFile,readDir}` | Raw workspace file access |
| **Templates** | `/api/template/{render,renderSprig}` | Sprig template engine |
| **Export** | `/api/export/{exportMdContent,exportResources}` | Markdown + ZIP |
| **Convert** | `/api/convert/pandoc` | Pandoc in `workspace/temp/convert/pandoc/{dir}` |
| **Notifications** | `/api/notification/{pushMsg,pushErrMsg}` | Toast to connected clients |
| **Network** | `/api/network/forwardProxy` | Generic HTTP forward |
| **System** | `/api/system/{bootProgress,version,currentTime}` | Health/meta |

**Data model (verbatim from API.md):**

```json
Notebook { id: "20210817205410-2kvfpfn", name, icon, sort, closed }

Block {
  id: "20211230115020-g02dfx0",
  type: "h|s|l|p|...",
  subType: "h1|u|o|...",
  data: "<HTML DOM>",
  parentID, previousID,
  kramdown: "…"
}

OperationResult {
  doOperations: [{ action: "insert|update|delete|move", data, id, parentID, previousID }],
  undoOperations: null
}
```

**Storage:** `.sy` JSON files under notebook folders, plus SQLite index (inferred from `/api/sqlite/flushTransaction`). Custom attrs are key/value per block.

**What SiYuan does NOT document (undetermined from API.md / README):**
1. Whether blocks are indexed *only* in SQLite or *also* queryable in their native JSON form.
2. Whether bidirectional backlinks are a stored table or a live query.
3. Any mechanism for **typed links** — API.md shows generic block-ref only.
4. Any concept of **issue status / priority / dependency / sprint**.
5. A **CLI** — only the HTTP API surface is documented.

---

## 🔀 Coverage Matrix — `bv` features vs. SiYuan native

Legend: ✅ native, ⚠️ partial / would need plugin, ❌ absent, 🟢 low effort, 🟡 medium, 🔴 high effort

| `bv` capability | SiYuan native? | Replacement path | Effort |
|---|---|---|---|
| **TUI (13 views: Board, Tree, Graph, Sprint, Triage, Insights, etc.)** | ❌ | Lost entirely — SiYuan is browser/Electron only | 🔴 Total rewrite |
| **Force-directed graph with PageRank/betweenness** | ❌ | Keep `bv` + bv-graph-wasm OR rewrite as SiYuan plugin | 🔴 |
| **Cycle detection, critical path, k-core, articulation points** | ❌ | No equivalent; `pkg/analysis/` would need porting | 🔴 |
| **Triage engine (plan + priority + insights)** | ❌ | `--robot-triage` has no SiYuan analogue | 🔴 |
| **25+ `--robot-*` JSON endpoints** | ❌ | Would require custom SiYuan plugin or external wrapper | 🔴 |
| **Git commit ↔ issue correlation** | ❌ | No git awareness in SiYuan | 🔴 |
| **Sprint / burndown / capacity forecasting** | ❌ | No status/priority/due-date primitives | 🔴 |
| **Full-text search (FTS5)** | ✅ | SiYuan has native search + `/api/query/sql` | 🟢 |
| **Semantic vector search + hybrid scoring** | ⚠️ | SiYuan has search but not hybrid-scored graph-aware | 🟡 plugin |
| **Markdown/kramdown rendering in cards** | ✅ | SiYuan is a markdown editor first | 🟢 |
| **Bidirectional links (untyped)** | ✅ | Native block-ref | 🟢 |
| **12 typed edges (`follows`, `derives-from`, `branches`, …)** | ❌ | Encode as `custom-edge-type: follows` block attrs + plugin to index | 🔴 |
| **Folgezettel addressing (`2/3a1p`)** | ❌ | Encode as `custom-fz: 2_3a1p` attr — no native rendering | 🔴 |
| **11 card kinds + 5 trunks** | ❌ | Custom attrs + custom CSS — no semantic enforcement | 🟡 |
| **Issue status lifecycle (open/in_progress/blocked/closed)** | ❌ | No native status concept — `custom-status` attr | 🔴 |
| **Drag-and-drop board** | ❌ | No kanban view in SiYuan | 🔴 plugin |
| **Interactive block editing** | ✅ | This is SiYuan's entire core competency | 🟢 |
| **Static-site export (`--export-pages`)** | ⚠️ | SiYuan exports Markdown/ZIP but not a reactive SPA | 🟡 |
| **`ATTACH DATABASE` / SQLite snapshot chunking** | ❌ | SiYuan owns its SQLite; not a static deliverable | 🔴 |
| **Drift detection vs. baseline** | ❌ | No analytics layer | 🔴 |
| **Label health / flow / attention dashboards** | ❌ | No native tags-as-subgraph concept | 🔴 |
| **Agent-brief bundle (`triage.json + insights.json + brief.md`)** | ❌ | No such primitive | 🔴 |

**Rough magnitude:** of `bv`'s ~70 capability line items, **4 map cleanly to SiYuan natives** (markdown rendering, generic block-ref, FTS search, block editing), **6 are plausible plugins** (custom attrs, CSS skinning), and **~60 are absent and would need to be rewritten as SiYuan plugins or external adapters** — almost all of the analytics, the TUI, and the robot/JSON surface.

---

## 🧱 Integration Surface — What a real "replacement" would require

### Path A — SiYuan as *viewer only* (keep `bv` as analytics engine)

```
~/.silmari-memory/box2-ideas/.beads/beads.db                    (source of truth)
   │
   │  bv --export-pages (unchanged)
   ▼
CACHE_DIR/beads.sqlite3                                          (analytics snapshot)
   │
   │  NEW: beads → SiYuan projector
   │  - for each issue: POST /api/filetree/createDocWithMd
   │                    POST /api/attr/setBlockAttrs  (custom-edge-type, custom-fz, custom-kind…)
   │  - for each ref:<type>:<target>: POST /api/block/insertBlock (block-ref)
   │  - rerun on every bv regen cycle (watch mtime)
   ▼
SiYuan workspace (read-only convention)
```

**Adds:**
- A ~1000-LOC "beads→SiYuan" projector (label mapping, block-ref construction, idempotent sync)
- A SiYuan plugin to (a) hide the editor toolbar for read-only UX, (b) render typed-edge colors per `custom-edge-type`, (c) provide a graph panel equivalent (no PageRank/betweenness unless rewritten)
- A deployment model — SiYuan Docker + sync watcher

**Removes/breaks:**
- The TUI entirely (no SiYuan terminal mode)
- `--robot-*` JSON automation surface (must call SiYuan SQL endpoint + build output formatter)
- Client-side WASM graph with PageRank (SiYuan has no equivalent; would need a plugin wrapping `bv-graph-wasm`)

### Path B — SiYuan as the *authoring* surface

User writes prose/notes in SiYuan; `silmari-mcp` observes (via SiYuan webhooks or polling) and captures structured cards into beads.db.

**Implications:**
- Ends the "agent memory" thesis — agents can still write via MCP but users now own a separate SiYuan database; two sources of truth
- Loses folgezettel addressing (SiYuan has no positional system), card kinds (no enforcement), typed edges (only via custom attrs)
- Wins WYSIWYG editing — currently silmari has no editor; cards are authored programmatically via `zk_save_card` MCP tool

### Path C — Embed SiYuan as an iframe for card *body editing only*

Replace the markdown render in the card detail portal (`apps/silmari-memory-card-viewer/viewer_assets/index.html` lines 3412-3636) with an embedded SiYuan block. Keep everything else (`bv`, force-graph, viewmodel, vocab, TUI).

**Adds:**
- SiYuan Docker on the same host
- iframe + postMessage bridge
- Auth token plumbing

**Keeps:**
- All of `bv`
- All analytics
- The Alpine SPA
- `silmari-mcp` unchanged

**Scope:** small. **Value:** WYSIWYG card editing in the viewer, which currently does not exist (cards are written via MCP tool calls only).

---

## 📊 Where the current roadmap is going (for context)

The existing architectural plans do **not** contemplate a SiYuan replacement. They iterate on `bv` + the SPA:

| Document | Planned work |
|---|---|
| `thoughts/searchable/shared/plans/2026-04-12-tdd-viewer-zettelkasten-graph-redesign.md` | 5-phase TDD: viewmodel extractors for `kind`/`trunk`/`box`/`keywords`/`fz`, vocab expansion, graph-helpers coloring, detail-panel ZK context, upstream sync. Phases 1-4 partially landed. |
| `thoughts/searchable/shared/plans/2026-04-17-tdd-force-graph-edges-fix.md` | Option B split schema: `card_edges` for the 11 semantic types, `dependencies` stays blocks-only. Tighten WASM filter. Already partially implemented (see recent commits `ffbe20d`..`89e540f`). |
| `thoughts/searchable/shared/research/2026-04-17-force-graph-edges-workaround.md` | Documents the 4-part workaround (synth, coalesce, WASM filter, Tier C backfill); recommends Option B. |
| `thoughts/searchable/shared/research/2026-04-12-beads-viewer-zettelkasten-graph-redesign.md` | 9-section audit → legend by-kind, progressive disclosure, chain navigator. |
| `thoughts/searchable/shared/research/2026-04-12-zettelkasten-thinking-tool-dashboard-design.md` | Establishes "card detail panel IS the product." Three-zone detail portal (context / body / connection navigator). |
| `Plans/research/2026-04-11-silmari-memory-card-viewer-planning.md` | Three-track planning: A = fork cosmic viewer, B = analyzes `bv` export pipeline, C = inventories 14 workarounds. Recommends vendoring cosmic's fork. |
| `thoughts/searchable/shared/handoffs/general/2026-04-16_18-08-14_mcp-memory-update-viewer-redesign.md` | Decision: card detail panel is the product; defer dashboards. |

---

## 🗺️ Code References

**`bv` binary (Go):**
- `apps/silmari-viewer/cmd/bv/main.go:439` — CLI entry
- `apps/silmari-viewer/cmd/bv/main.go:583,1705` — `--export-pages` definition + handler
- `apps/silmari-viewer/cmd/bv/main.go:5291` — `copyViewerAssets()` (embedded FS copy)
- `apps/silmari-viewer/cmd/bv/robot_registry.go:29,39,59` — robot command registry
- `apps/silmari-viewer/pkg/export/sqlite_export.go:68` — exporter
- `apps/silmari-viewer/pkg/export/sqlite_schema.go:16` — schema DDL
- `apps/silmari-viewer/pkg/export/viewer_embed.go:22,26` — embedded SPA assets
- `apps/silmari-viewer/internal/datasource/source.go:82` — source discovery
- `apps/silmari-viewer/internal/datasource/sqlite.go:15,92` — SQLite reader (detects legacy vs. beads-rs schema)
- `apps/silmari-viewer/pkg/search/vector_index.go:53` — binary-format vector index (magic `BVVI`)
- `apps/silmari-viewer/pkg/analysis/graph.go:65,160` — `GraphStats` + `AnalyzeAsync`
- `apps/silmari-viewer/pkg/ui/*.go` — ~50 files implementing the TUI (Bubble Tea)

**Card-viewer Bun server:**
- `apps/silmari-memory-card-viewer/server.ts:96` — `parseRefLabel()` (12-type whitelist)
- `apps/silmari-memory-card-viewer/server.ts:141-174` — `synthesizeEdgesFromLabels()` (server-owned `card_edges`)
- `apps/silmari-memory-card-viewer/server.ts:184-201` — `refreshSnapshotConfig()` (OPFS invalidation)
- `apps/silmari-memory-card-viewer/server.ts:221-229` — `needsRegen()` (WAL-aware mtime check)
- `apps/silmari-memory-card-viewer/server.ts:231-260` — `ensureExport()` (lazy `bv --export-pages` shell-out)
- `apps/silmari-memory-card-viewer/server.ts:270-283` — `resolveServedPath()` (overlay + traversal guard)
- `apps/silmari-memory-card-viewer/server.ts:85-89` — 12 `VALID_EDGE_TYPES`

**SPA bundle:**
- `apps/silmari-memory-card-viewer/viewer_assets/viewmodel.js:141-215` — label-prefix extractors
- `apps/silmari-memory-card-viewer/viewer_assets/graph.js:684-693` — WASM filter to `type === 'blocks'`
- `apps/silmari-memory-card-viewer/viewer_assets/graph.js:1036-1119` — node shape + ZK enrichment
- `apps/silmari-memory-card-viewer/viewer_assets/vocab.js` — `window.V` vocabulary (149 lines)
- `apps/silmari-memory-card-viewer/viewer_assets/threads.js` — folgezettel placeholder (43 lines)
- `apps/silmari-memory-card-viewer/viewer_assets/index.html:3412-3636` — card detail portal

**Source-of-truth read path (MCP):**
- `apps/silmari-mcp/src/lib/edge-extractors.ts` — Tier A `ref:*` label extractors at save time
- `apps/silmari-mcp/src/lib/paths.ts:50` — `SILMARI_DIR` (not `SILMARI_STORE`) — common trap

---

## 🏛️ Architecture Documentation

**Current invariant** (`apps/silmari-viewer/README.md:34-38`): viewer and MCP share *only* the storage substrate (beads.db). No transport is shared. `grep -rn 'silmari-mcp\|@modelcontextprotocol' apps/silmari-viewer/` must return zero matches — the viewer must never import the MCP server.

**Label-as-edge convention** (established because `beads_rust`'s `dep_type` whitelist rejects silmari's 11 semantic edge types — see `MEMORY/MEMORY.md` → `project_beads_rust_dep_whitelist.md`): typed edges are encoded as labels of the form `ref:<type>:<target-id>` on the *source* card. The `dependencies` table holds only `blocks`-typed rows. The `card_edges` cache-side table is synthesized per regen.

**Overlay file system**: any file in `apps/silmari-memory-card-viewer/viewer_assets/` takes precedence over `bv`'s embedded copy in `CACHE_DIR/`. This is how silmari-specific customizations (ZK vocab, card kinds, trunks) override the upstream beads_viewer defaults without forking the Go source.

**OPFS + chunking**: large SQLite exports are split into 1 MB chunks for HTTP range requests (sql.js httpvfs). The browser caches the assembled DB in Origin Private File System; the `beads.sqlite3.config.json` sha256 is the cache-bust signal.

**SiYuan data model (for contrast)**: notebook → document (`.sy` JSON file) → blocks. Block ID is a millisecond timestamp + random suffix (`20211230115020-g02dfx0`). Kramdown is the wire format; data is a serialized HTML DOM. Every mutation returns `doOperations` + `undoOperations` for the undo stack.

---

## 📜 Historical Context (from thoughts/)

- `thoughts/searchable/shared/research/2026-04-12-beads-viewer-zettelkasten-graph-redesign.md` — 2026-04-12. Force-graph audit; ZK data flows through `viewmodel.js` but was not yet rendered. Recommends legend-by-kind, progressive disclosure, chain navigator.
- `thoughts/searchable/shared/research/2026-04-17-force-graph-edges-workaround.md` — 2026-04-17. Documents the 4-part `ref:*` workaround; recommends split-schema (Option B). **Currently being implemented** (commits `ffbe20d`..`89e540f`).
- `thoughts/searchable/shared/research/2026-04-12-zettelkasten-thinking-tool-dashboard-design.md` — 2026-04-12. Establishes "card detail panel IS the product."
- `thoughts/searchable/shared/plans/2026-04-12-tdd-viewer-zettelkasten-graph-redesign.md` — 2026-04-12. 5-phase TDD plan for ZK rendering; phases 1-4 partially landed.
- `thoughts/searchable/shared/plans/2026-04-17-tdd-force-graph-edges-fix.md` — 2026-04-17. Option B split-schema TDD plan; ready post-review.
- `Plans/research/2026-04-11-silmari-memory-card-viewer-planning.md` — 2026-04-11. Three-track planning; recommends vendoring cosmic's viewer fork.
- `thoughts/searchable/shared/handoffs/general/2026-04-16_18-08-14_mcp-memory-update-viewer-redesign.md` — 2026-04-16. Confirms card detail panel as the product.

Memory entries consulted:
- `feedback_silmari_graph_edge_recovery` — flat graph = 0 `ref:*` labels; backfill script in README § Graph edges.
- `project_beads_rust_dep_whitelist` — why label-encoded edges exist at all.
- `reference_cosmic_db_canonical_location` — canonical cosmic snapshot on `ionos01:/root/.cosmic-agent/.beads/beads.db`.

---

## 🔗 Related Research

- `thoughts/searchable/shared/research/2026-04-12-beads-viewer-zettelkasten-graph-redesign.md`
- `thoughts/searchable/shared/research/2026-04-17-force-graph-edges-workaround.md`
- `thoughts/searchable/shared/research/2026-04-12-zettelkasten-thinking-tool-dashboard-design.md`
- `thoughts/searchable/shared/research/2026-04-11-silmari-memory-card-viewer-planning.md` (if moved from `Plans/research/`)

---

## ❓ Open Questions

1. **What problem does "replace beads_viewer" actually aim to solve?** If the motivation is *editor UX* (no WYSIWYG in the current SPA), Path C (iframe SiYuan for card body editing only) is low-cost and non-disruptive. If the motivation is *consolidating on a single open-source platform*, the cost of re-implementing `bv`'s 60+ analytics/TUI capabilities as SiYuan plugins is very high. **This question determines whether any replacement makes sense.**
2. **Is SiYuan's SQL endpoint queryable across arbitrary joins, or only the canonical block/attribute tables?** API.md says `sql(stmt)` is disabled in Publish Mode but doesn't specify which tables are accessible. A full evaluation of Path A (SiYuan-as-projection-target) needs this.
3. **Does SiYuan enforce typed-link semantics anywhere, or are block-refs always untyped?** The API surface documents only generic block-ref operations (`transferBlockRef`). If the answer is truly no typed links, then silmari's 12 edge types must be encoded as custom block attributes (`custom-edge-type: follows`) with no native rendering support — equivalent to starting from zero on the visual-language side.
4. **Headless multi-user operation?** SiYuan's Docker note says "browsers only." Is SiYuan designed for multi-user deployments or is it single-user-per-kernel? Silmari's alpha on `ionos01` uses a single store but the long-term direction (per `thoughts/searchable/shared/research/2026-04-17-cosmic-separation-remote-mcp-scale-path.md`, listed in recent commit `1d90240`) may require multi-tenant.
5. **Do we even want to keep `bv` for analytics if SiYuan enters?** If Path A, `bv` stays and we add a SiYuan projector. If Path B, `bv` may still generate the analytics surface even though SiYuan owns the editing surface. Path C leaves `bv` fully intact.

---

## 🧾 Sources

- API.md fetched from `https://github.com/tha-hammer/silmari-knowledge-management/blob/master/API.md` (2026-04-18, via WebFetch)
- `siyuan-note/siyuan` GitHub README (2026-04-18, via WebFetch)
- Local codebase at commit `1d90240` on branch `main` of `tha-hammer/silmari-agent-memory`

*End of research.*
