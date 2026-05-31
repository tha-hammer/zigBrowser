---
date: 2026-04-27T12:25:10-04:00
researcher: Silmari (via Codex)
git_commit: 437b92010b65b89588085278dcb0081a2b639c70
branch: main
repository: silmari-agent-memory
topic: "Rust replacement context for Beads issue-tracker search/list versus Silmari Zettelkasten retrieval semantics"
tags: [research, codebase, beads-rust, silmari-mcp, zettelkasten, retrieval, rust, viewer]
status: complete
last_updated: 2026-04-27
last_updated_by: Silmari
related_beads_issues: [silmari-agent-memory-xom, silmari-agent-memory-rjn, silmari-agent-memory-p6i, silmari-agent-memory-adf]
---

# Research: Rust Replacement Context for Zettelkasten Retrieval

**Date**: 2026-04-27 12:25:10 -04:00
**Researcher**: Silmari (via Codex)
**Git Commit**: 437b92010b65b89588085278dcb0081a2b639c70
**Branch**: main
**Repository**: silmari-agent-memory

```
┌────────────────────────────────────────────────────────────────────┐
│ Status: complete                                                   │
│ Scope: current codebase map for Beads/Silmari retrieval semantics  │
│ Lens: what exists today, with Rust replacement-relevant contracts   │
└────────────────────────────────────────────────────────────────────┘
```

## Research Question

The prompt supplied the prior finding that Beads native `br search` is issue-tracker substring search, while Silmari routes idea-card recall through keyword index, folgezettel neighborhood, and label-encoded edges. The requested research area is the existing `beads_rust` application and how its current behavior compares to the Zettelkasten semantics of a thinking tool with edges and chains of thought, with Rust as the desired implementation language.

This document describes the current code paths and contracts that exist today. It does not propose an implementation plan.

## Summary

Beads Rust is currently an issue tracker storage/CLI engine. Its `list` and `search` commands query an `issues` table, filter exact labels through the separate `labels` table, sort by issue-management fields such as priority and creation time, and then hydrate labels and dependency counts for structured output. Native `br search` is a `LIKE '%query%'` scan over `title`, `description`, and `id`, not a Zettelkasten recall engine.

Silmari builds Zettelkasten semantics above Beads through label conventions and a separate sqlite keyword index. Card metadata is stored as labels such as `fz:<trunk>_<seq>`, `kind:<kind>`, `box:<box>`, `trunk:<N>`, `source:<source>`, and `content_hash:<short>`. Typed edges are labels on the source card in the form `ref:<edge>:<target>`. The only Silmari edge also mirrored to Beads dependencies is `blocks`.

The user-facing idea-card recall path is `zk_recall`, implemented as `navigate()`: exact normalized keyword lookup from `keyword_entries`, per-entry folgezettel neighborhood, and optional cross-reference traversal. `zk_line_of_thought` is a bounded neighborhood composer from parent, siblings, children, hubs, and trunk seeds. Both paths rely on Beads as a storage adapter for exact label reads and exact card reads, not as the retrieval model.

The viewer/export layer currently adapts Beads-style output into a card graph. `apps/silmari-memory-card-viewer/server.ts` shells out to `bv --export-pages`, then scans exported issue labels and writes a cache-side `card_edges(source,target,type)` table for Silmari `ref:*` edges. The client merges `dependencies` and `card_edges` into graph links. Prior research and the open `silmari-agent-memory-xom` issue document a two-phase viewer direction: strip issue-tracker semantics in place now, then greenfield a Zettelkasten-native viewer later.

| Layer | Current Implementation | ZK Semantic Role |
| --- | --- | --- |
| Beads Rust search | `LIKE` over issue title/description/id | Catalog/text fallback, not idea recall |
| Beads Rust list labels | SQL `EXISTS` exact label filters | Storage adapter for exact metadata |
| Silmari labels | `fz:`, `kind:`, `trunk:`, `ref:*`, etc. | Zettelkasten structure and graph |
| Silmari keyword index | `keyword_entries` in `${SILMARI_DIR}/silmari.db` | Layer 1 recall entry points |
| Silmari navigation | `scanTrunk`, `neighborhood`, `chain`, `followEdges` | Folgezettel and typed-edge retrieval |
| Viewer cache | `dependencies` plus synthesized `card_edges` | Graph rendering substrate |

## Detailed Findings

### Beads Rust Search

`vendor/beads_rust/src/cli/commands/search.rs` describes the command as classic bd-style `LIKE` search across title, description, and id with list-like filters (`vendor/beads_rust/src/cli/commands/search.rs:3`). The command trims and validates a non-empty query before collecting and rendering results (`vendor/beads_rust/src/cli/commands/search.rs:33`, `vendor/beads_rust/src/cli/commands/search.rs:52`).

The storage implementation is `SqliteStorage::search_issues`. It returns no rows for an empty trimmed query, selects issue fields from `issues`, and appends:

```sql
AND (title LIKE ? ESCAPE '\' OR description LIKE ? ESCAPE '\' OR id LIKE ? ESCAPE '\')
```

The pattern is the escaped query wrapped in `%...%` (`vendor/beads_rust/src/storage/sqlite.rs:2205`, `vendor/beads_rust/src/storage/sqlite.rs:2225`, `vendor/beads_rust/src/storage/sqlite.rs:2228`). Label filters are exact-label `EXISTS` subqueries: repeated `--label` becomes AND logic, and `--label-any` becomes a single `label IN (...)` predicate (`vendor/beads_rust/src/storage/sqlite.rs:2234`, `vendor/beads_rust/src/storage/sqlite.rs:2241`).

Search sorting is issue-list sorting: priority, created time, updated time, title, or default `priority ASC, created_at DESC` (`vendor/beads_rust/src/storage/sqlite.rs:2326`, `vendor/beads_rust/src/storage/sqlite.rs:2353`). Structured search output hydrates labels and relation counts after the primary query through `attach_counts`, which calls `get_labels_for_issues` and `count_relation_counts_for_issues` (`vendor/beads_rust/src/cli/commands/search.rs:226`, `vendor/beads_rust/src/cli/commands/search.rs:235`).

### Beads Rust List And Exact Labels

`br list` builds `ListFilters` from CLI arguments. `--label` maps to `ListFilters.labels` with AND semantics, and `--label-any` maps to `labels_or` with OR semantics (`vendor/beads_rust/src/cli/commands/list.rs:359`, `vendor/beads_rust/src/cli/commands/list.rs:364`). The storage path selects issue rows from `issues WHERE 1=1` and adds one exact-label `EXISTS` query per required label (`vendor/beads_rust/src/storage/sqlite.rs:1909`, `vendor/beads_rust/src/storage/sqlite.rs:1924`).

For JSON and TOON output, `list` also runs a `COUNT(*)` query when filters can stay on the SQL path, then hydrates labels and dependency/dependent counts with separate batch queries (`vendor/beads_rust/src/cli/commands/list.rs:78`, `vendor/beads_rust/src/cli/commands/list.rs:175`, `vendor/beads_rust/src/cli/commands/list.rs:182`). The list storage default order is `priority ASC, created_at DESC`, and limit/offset are appended when present (`vendor/beads_rust/src/storage/sqlite.rs:2048`, `vendor/beads_rust/src/storage/sqlite.rs:2052`).

The label schema is a relation table:

```sql
labels(issue_id TEXT NOT NULL, label TEXT NOT NULL, PRIMARY KEY(issue_id, label))
```

with indexes on `label` and `issue_id` (`vendor/beads_rust/src/storage/schema.rs:121`, `vendor/beads_rust/src/storage/schema.rs:127`). Label validation permits ASCII alphanumeric, hyphen, underscore, and colon, and rejects empty labels and labels longer than 128 (`vendor/beads_rust/src/validation/mod.rs:227`, `vendor/beads_rust/src/validation/mod.rs:232`, `vendor/beads_rust/src/validation/mod.rs:236`). This is why Silmari encodes folgezettel slash addresses as labels like `fz:2_3a1`.

### Beads Rust Dependencies

Beads dependencies are issue-management relations stored in `dependencies(issue_id, depends_on_id, type, created_at, created_by, metadata, thread_id)` with primary key `(issue_id, depends_on_id)` (`vendor/beads_rust/src/storage/schema.rs:97`, `vendor/beads_rust/src/storage/schema.rs:106`). The partial blocking index covers `blocks`, `parent-child`, `conditional-blocks`, and `waits-for` (`vendor/beads_rust/src/storage/schema.rs:116`).

The model enum includes `DependencyType::Custom(String)`, but the `dep` CLI parser rejects `Custom(_)` and returns a validation error. The allowed CLI set is `blocks`, `parent-child`, `conditional-blocks`, `waits-for`, `related`, `discovered-from`, `replies-to`, `relates-to`, `duplicates`, `supersedes`, and `caused-by` (`vendor/beads_rust/src/model/mod.rs:218`, `vendor/beads_rust/src/cli/commands/dep.rs:435`, `vendor/beads_rust/src/cli/commands/dep.rs:441`).

`add_dependency_with_metadata` validates endpoints, rejects external `parent-child` edges, checks cycles for blocking types, inserts with `INSERT OR IGNORE`, updates `issues.updated_at`, records an event, marks dirty, and defers blocked-cache invalidation (`vendor/beads_rust/src/storage/sqlite.rs:3955`, `vendor/beads_rust/src/storage/sqlite.rs:3969`, `vendor/beads_rust/src/storage/sqlite.rs:4000`, `vendor/beads_rust/src/storage/sqlite.rs:4025`, `vendor/beads_rust/src/storage/sqlite.rs:4050`).

This is the reason Silmari's Luhmann semantic edges are not native Beads deps.

### Silmari Label Namespace

Silmari centralizes label namespaces in `apps/silmari-mcp/src/lib/labels.ts`. Prefixes include `fz:`, `kind:`, `box:`, `trunk:`, `scope:`, `source:`, `ref:`, `content_hash:`, `keyword:`, and `upsert:` (`apps/silmari-mcp/src/lib/labels.ts:28`). Card kinds include `biblio`, `idea`, `hub`, `structure`, `register`, `fact`, `signal`, `learning`, `preference`, `decision`, and `stub` (`apps/silmari-mcp/src/lib/labels.ts:51`).

Folgezettel labels are constructed as `fz:<trunk>_<sequence>` because `/` is not valid in Beads labels. `parseFzFromLabels` translates that label form back into slash-form addresses like `2/3a1` (`apps/silmari-mcp/src/lib/labels.ts:114`, `apps/silmari-mcp/src/lib/labels.ts:125`, `apps/silmari-mcp/src/lib/labels.ts:213`).

Semantic edge labels are constructed only through `refLabel(type, targetId)`, producing `ref:<type>:<targetId>` (`apps/silmari-mcp/src/lib/labels.ts:157`). `parseRefsFromLabels` scans labels, drops unknown edge types, and returns structured `{edge,targetId}` records (`apps/silmari-mcp/src/lib/labels.ts:267`, `apps/silmari-mcp/src/lib/labels.ts:277`).

### Silmari Edge Layer

Silmari edge types are split into AUTO and REVIEWED sets. AUTO includes `follows`, `continues`, `branches`, `derives-from`, `blocks`, `refers-to`, and `annotates`; REVIEWED includes `supports`, `contradicts`, `extends`, `reinforces`, and `refines` (`apps/silmari-mcp/src/lib/labels.ts:79`, `apps/silmari-mcp/src/lib/labels.ts:89`).

`addEdge` writes `ref:<edge>:<target>` onto the source card with `brLabelAdd`. For `blocks`, it also mirrors the relation into `br dep add --type blocks`; the label remains the Silmari source of truth (`apps/silmari-mcp/src/lib/edges.ts:76`, `apps/silmari-mcp/src/lib/edges.ts:91`, `apps/silmari-mcp/src/lib/edges.ts:96`). `proposeOrAddEdge` directly applies AUTO edges and queues REVIEWED edges through the proposal file (`apps/silmari-mcp/src/lib/edges.ts:392`, `apps/silmari-mcp/src/lib/edges.ts:403`).

Outbound traversal reads a card with `brShow` and parses its `ref:*` labels (`apps/silmari-mcp/src/lib/edges.ts:126`, `apps/silmari-mcp/src/lib/edges.ts:133`). Inbound traversal uses exact label lookup with `brList({ labels: [refLabel(edge, cardId)], all: true })` (`apps/silmari-mcp/src/lib/edges.ts:153`, `apps/silmari-mcp/src/lib/edges.ts:166`).

### Silmari Keyword Index

The keyword index is a separate sqlite table, not a Beads FTS table. `keyword-index.ts` states that it is Layer 1 of Silmari's three-layer retrieval and that there is no full-text search fallback for idea-box recall (`apps/silmari-mcp/src/lib/keyword-index.ts:1`, `apps/silmari-mcp/src/lib/keyword-index.ts:4`, `apps/silmari-mcp/src/lib/keyword-index.ts:6`).

The schema is:

```sql
CREATE TABLE IF NOT EXISTS keyword_entries (
  term         TEXT PRIMARY KEY NOT NULL,
  entry_points TEXT NOT NULL,
  curator      TEXT NOT NULL CHECK(curator IN ('human','agent')),
  updated_at   TEXT NOT NULL
);
```

It lives in `${SILMARI_DIR}/silmari.db` (`apps/silmari-mcp/src/lib/keyword-index.ts:20`, `apps/silmari-mcp/src/lib/keyword-index.ts:153`). `lookupKeyword` normalizes the query and reads one row by exact term (`apps/silmari-mcp/src/lib/keyword-index.ts:244`, `apps/silmari-mcp/src/lib/keyword-index.ts:253`). `addKeywordEntry` creates a new row, returns `already-present` for idempotent duplicates, or appends an entry point to the JSON array (`apps/silmari-mcp/src/lib/keyword-index.ts:359`, `apps/silmari-mcp/src/lib/keyword-index.ts:384`, `apps/silmari-mcp/src/lib/keyword-index.ts:413`, `apps/silmari-mcp/src/lib/keyword-index.ts:417`).

### Silmari Folgezettel Navigation

`navigate.ts` describes Layer 2 of Silmari retrieval: parent chains, siblings, children, and chains over folgezettel addresses (`apps/silmari-mcp/src/lib/navigate.ts:1`). Because Beads labels do not support prefix/glob queries, `scanTrunk` loads all cards in a trunk with one exact `trunk:<N>` label query, then parses and indexes the `fz:` labels client-side (`apps/silmari-mcp/src/lib/navigate.ts:19`, `apps/silmari-mcp/src/lib/navigate.ts:21`, `apps/silmari-mcp/src/lib/navigate.ts:198`, `apps/silmari-mcp/src/lib/navigate.ts:220`, `apps/silmari-mcp/src/lib/navigate.ts:224`).

`neighborhood(address)` returns live bead rows for the queried address, proper parent chain, same-depth siblings, and direct children (`apps/silmari-mcp/src/lib/navigate.ts:280`, `apps/silmari-mcp/src/lib/navigate.ts:294`, `apps/silmari-mcp/src/lib/navigate.ts:327`). Register cards are excluded as index structures (`apps/silmari-mcp/src/lib/navigate.ts:204`, `apps/silmari-mcp/src/lib/navigate.ts:231`). `chain(address)` walks existing prefix cards from root to the queried card, omitting missing prefixes (`apps/silmari-mcp/src/lib/navigate.ts:345`).

`followEdges` performs a breadth-first walk over typed `ref:*` edges. Outbound traversal is one `brShow` per visited node; inbound traversal fans out by edge type through `listInbound` label queries (`apps/silmari-mcp/src/lib/navigate.ts:460`, `apps/silmari-mcp/src/lib/navigate.ts:487`, `apps/silmari-mcp/src/lib/navigate.ts:521`, `apps/silmari-mcp/src/lib/navigate.ts:545`).

### `zk_recall` And `zk_line_of_thought`

The MCP tool `zk_recall` is defined in `apps/silmari-mcp/src/index.ts` and delegates to `navigate(query, opts)` (`apps/silmari-mcp/src/index.ts:152`, `apps/silmari-mcp/src/index.ts:573`, `apps/silmari-mcp/src/index.ts:576`). `navigate()` composes three layers:

| Step | Code Path | Output |
| --- | --- | --- |
| 1. Keyword lookup | `lookupKeyword(query)` | `entryPoints` or `null` |
| 2. Neighborhoods | `neighborhood(address, cache)` | parents, siblings, children |
| 3. Crossrefs | `followEdges(...)` when requested | typed edge walk |

The return shape includes `query`, nullable `entryPoints`, `entryCards`, `neighborhoods`, and `crossRefs` (`apps/silmari-mcp/src/lib/navigate.ts:600`, `apps/silmari-mcp/src/lib/navigate.ts:746`). On a keyword miss, it returns `entryPoints: null` and empty collections (`apps/silmari-mcp/src/lib/navigate.ts:755`). On a hit, it sorts and limits entry points, records `totalMatching`, and flags truncation explicitly (`apps/silmari-mcp/src/lib/navigate.ts:758`, `apps/silmari-mcp/src/lib/navigate.ts:777`).

`zk_line_of_thought` delegates to `lineOfThought(cardId)` (`apps/silmari-mcp/src/index.ts:318`, `apps/silmari-mcp/src/index.ts:692`). A line of thought is defined as parent, siblings, children, hubs, and trunk seeds for a seed card (`apps/silmari-mcp/src/lib/line-of-thought.ts:4`, `apps/silmari-mcp/src/lib/line-of-thought.ts:7`). It caps the flat union at 150 cards and returns `{queried,parent,siblings,children,hubs,trunkSeeds,all,totalScope}` (`apps/silmari-mcp/src/lib/line-of-thought.ts:50`, `apps/silmari-mcp/src/lib/line-of-thought.ts:66`, `apps/silmari-mcp/src/lib/line-of-thought.ts:187`).

### Save-Time Card Model

`saveCard` hashes the body, resolves explicit `fromAddress`, checks body-hash recurrence, assigns a folgezettel address for idea cards, builds labels, stores full body metadata in JSON description, creates the Beads row with `brCreate`, and runs post-save steps (`apps/silmari-mcp/src/lib/card-ops.ts:746`, `apps/silmari-mcp/src/lib/card-ops.ts:760`, `apps/silmari-mcp/src/lib/card-ops.ts:769`, `apps/silmari-mcp/src/lib/card-ops.ts:810`, `apps/silmari-mcp/src/lib/card-ops.ts:822`, `apps/silmari-mcp/src/lib/card-ops.ts:832`).

Post-save steps include duplicate sweep, deterministic Tier A edge extraction, direct body-hash `reinforces` emission, save-time keyword writes, and anchor checks (`apps/silmari-mcp/src/lib/card-ops.ts:519`, `apps/silmari-mcp/src/lib/card-ops.ts:523`, `apps/silmari-mcp/src/lib/card-ops.ts:587`, `apps/silmari-mcp/src/lib/card-ops.ts:595`). The deterministic extractors find body mentions, folgezettel parent edges, source bead references, and line-of-thought title mentions without LLM or file access (`apps/silmari-mcp/src/lib/edge-extractors.ts:1`, `apps/silmari-mcp/src/lib/edge-extractors.ts:67`, `apps/silmari-mcp/src/lib/edge-extractors.ts:91`, `apps/silmari-mcp/src/lib/edge-extractors.ts:116`, `apps/silmari-mcp/src/lib/edge-extractors.ts:146`).

`zk_save_cards` batch-saves idea cards through one `br create -f` invocation and then applies the same post-save logic per card (`apps/silmari-mcp/src/index.ts:123`, `apps/silmari-mcp/src/lib/card-ops.ts:901`, `apps/silmari-mcp/src/lib/card-ops.ts:1001`, `apps/silmari-mcp/src/lib/card-ops.ts:1015`).

### Beads Adapter Boundary

`br-adapter.ts` is the low-level wrapper around the `br` CLI. It targets one Silmari box at a time by choosing the relevant Beads DB path (`apps/silmari-mcp/src/lib/br-adapter.ts:1`, `apps/silmari-mcp/src/lib/br-adapter.ts:7`, `apps/silmari-mcp/src/lib/br-adapter.ts:89`). Read timeouts are 500ms, writes 1000ms, and init 3000ms (`apps/silmari-mcp/src/lib/br-adapter.ts:44`).

`brList` shells out to `br list --json --db <box-db>`, appending repeated `-l` labels and other filters, then returns `parsed.issues || parsed || []` while converting structured error payloads into empty arrays (`apps/silmari-mcp/src/lib/br-adapter.ts:283`, `apps/silmari-mcp/src/lib/br-adapter.ts:321`, `apps/silmari-mcp/src/lib/br-adapter.ts:324`, `apps/silmari-mcp/src/lib/br-adapter.ts:342`). `brSearch` wraps `br search`, and its comment states Silmari uses it only for the bibliographic box, not the idea-box hot path (`apps/silmari-mcp/src/lib/br-adapter.ts:357`, `apps/silmari-mcp/src/lib/br-adapter.ts:360`). `brShow` wraps exact card fetches and includes retry behavior for recoverable visibility misses (`apps/silmari-mcp/src/lib/br-adapter.ts:395`, `apps/silmari-mcp/src/lib/br-adapter.ts:406`, `apps/silmari-mcp/src/lib/br-adapter.ts:415`).

### Viewer And Export Surfaces

`apps/silmari-viewer` is the current standalone `bv` viewer/exporter. Its Go module still identifies as `github.com/Dicklesworthstone/beads_viewer`, reads Beads SQLite data directly, and embeds the SPA assets it exports (`apps/silmari-viewer/go.mod:1`, `apps/silmari-viewer/pkg/export/viewer_embed.go:17`). The command entrypoint owns export/page generation flags, including `--export-pages`, and the SQLite export path still writes issue-shaped tables and materialized search/graph data (`apps/silmari-viewer/cmd/bv/main.go:582`, `apps/silmari-viewer/cmd/bv/main.go:1704`, `apps/silmari-viewer/pkg/export/sqlite_export.go:67`, `apps/silmari-viewer/pkg/export/sqlite_schema.go:37`). Rust is already present in this surface as WASM/helper crates for graph and hybrid search scoring, not as the canonical storage/retrieval engine (`apps/silmari-viewer/bv-graph-wasm/Cargo.toml:1`, `apps/silmari-viewer/bv-graph-wasm/src/lib.rs:15`, `apps/silmari-viewer/pkg/export/wasm_scorer/Cargo.toml:1`).

`apps/silmari-memory-card-viewer/server.ts` is a Bun server that serves a browser UI for `~/.silmari-memory`, shells out to `bv --export-pages`, and overlays customized SPA assets over the exported cache (`apps/silmari-memory-card-viewer/server.ts:1`, `apps/silmari-memory-card-viewer/server.ts:5`, `apps/silmari-memory-card-viewer/server.ts:17`). It documents the key edge adaptation: `bv --export-pages` strips non-`blocks` edges, so `synthesizeEdgesFromLabels()` scans exported `issues.labels` for `ref:<type>:<target>` and writes cache-side graph rows (`apps/silmari-memory-card-viewer/server.ts:23`, `apps/silmari-memory-card-viewer/server.ts:141`).

The cache-side schema is:

```sql
CREATE TABLE IF NOT EXISTS card_edges (
  source TEXT NOT NULL,
  target TEXT NOT NULL,
  type TEXT NOT NULL,
  PRIMARY KEY (source, target, type)
);
```

(`apps/silmari-memory-card-viewer/server.ts:125`). `synthesizeEdgesFromLabels` reads `SELECT id, labels FROM issues`, parses JSON label arrays, filters through the Silmari edge whitelist, and inserts `card_edges` rows in a transaction (`apps/silmari-memory-card-viewer/server.ts:149`, `apps/silmari-memory-card-viewer/server.ts:151`, `apps/silmari-memory-card-viewer/server.ts:158`, `apps/silmari-memory-card-viewer/server.ts:160`).

The browser helper `buildLinks` merges Beads `dependencies` rows and synthesized `card_edges` rows into one force-graph link list while preserving `link.type` (`apps/silmari-memory-card-viewer/viewer_assets/link-builder.js:1`, `apps/silmari-memory-card-viewer/viewer_assets/link-builder.js:17`). `vocab.js` is the viewer's vocabulary adapter from issue-tracker wording to card/thread/link language and enumerates card kinds, edge types, and trunks (`apps/silmari-memory-card-viewer/viewer_assets/vocab.js:1`, `apps/silmari-memory-card-viewer/viewer_assets/vocab.js:17`, `apps/silmari-memory-card-viewer/viewer_assets/vocab.js:83`, `apps/silmari-memory-card-viewer/viewer_assets/vocab.js:98`).

The viewer still carries issue-tracker vocabulary and schema across multiple layers: model type `Issue`, export tables named `issues`, `dependencies`, `issue_metrics`, and `triage_recommendations`, columns such as `issue_type`, `priority`, and `assignee`, and UI filters for Status, Type, Priority, and Assignee (`apps/silmari-viewer/pkg/model/types.go:8`, `apps/silmari-viewer/pkg/model/types.go:114`, `apps/silmari-viewer/pkg/model/types.go:155`, `apps/silmari-viewer/pkg/export/sqlite_schema.go:41`, `apps/silmari-viewer/pkg/export/sqlite_schema.go:61`, `apps/silmari-viewer/pkg/export/sqlite_schema.go:77`, `apps/silmari-memory-card-viewer/viewer_assets/index.html:1099`, `apps/silmari-memory-card-viewer/viewer_assets/index.html:1113`, `apps/silmari-memory-card-viewer/viewer_assets/index.html:1127`, `apps/silmari-memory-card-viewer/viewer_assets/index.html:1141`). Tests cover SQLite export, FTS5 search in the exported viewer DB, robot/hybrid search, graph analysis, edge synthesis, and label health, but the viewer remains separate from the Silmari MCP storage adapter and from Beads Rust itself.

## Behavioral Contracts From Tests

| Area | Contract Examples |
| --- | --- |
| Folgezettel math | `navigate.test.ts` covers parent prefixes, sibling depth, child detection, and `fz` slash/underscore round trips (`apps/silmari-mcp/tests/navigate.test.ts:27`, `apps/silmari-mcp/tests/navigate.test.ts:147`). |
| Keyword density | `keyword-index-sqlite.test.ts` verifies `keyword_entries` schema and unbounded entry retention (`apps/silmari-mcp/tests/keyword-index-sqlite.test.ts:50`, `apps/silmari-mcp/tests/keyword-index-sqlite.test.ts:142`). |
| Recall limiting | `zk-recall-limit.test.ts` verifies default limit 20, explicit limits, `totalMatching`, `truncated`, `reinforces-density`, and `recency` sorting (`apps/silmari-mcp/tests/zk-recall-limit.test.ts:75`, `apps/silmari-mcp/tests/zk-recall-limit.test.ts:94`). |
| Edges | `edges.test.ts`, `edge-extractors.test.ts`, and `integration.test.ts` cover proposal queue behavior, deterministic extractors, inbound/outbound traversal, and `blocks` mirroring (`apps/silmari-mcp/tests/edges.test.ts:46`, `apps/silmari-mcp/tests/edge-extractors.test.ts:29`, `apps/silmari-mcp/tests/integration.test.ts:362`). |
| Viewer edge synthesis | `server.test.ts` asserts `card_edges` schema, valid `ref:*` parsing, malformed-label skipping, idempotence, and all 12 edge types (`apps/silmari-memory-card-viewer/tests/server.test.ts:228`, `apps/silmari-memory-card-viewer/tests/server.test.ts:317`). |
| Beads list/search | Beads E2E tests cover exact label filters, list pagination, `LIKE` search behavior, output formats, and dependency graph contracts (`vendor/beads_rust/tests/e2e_list_comprehensive.rs:531`, `vendor/beads_rust/tests/e2e_search_scenarios.rs:179`). |

## Architecture Documentation

```
Idea-card recall today

zk_recall(query)
  └─ navigate(query)
      ├─ lookupKeyword(query)              # exact normalized term in keyword_entries
      ├─ sort/limit entry_points           # recency or reinforces-density
      ├─ neighborhood(address)             # trunk scan + fz parent/sibling/child math
      └─ followEdges(cardId) optional      # ref:* labels, outbound/inbound

Raw br search
  └─ search_issues(query)
      └─ title/description/id LIKE '%query%'
```

```
Card graph today

saveCard()
  ├─ Beads issue row
  ├─ labels: fz/kind/box/trunk/source/content_hash/ref
  ├─ keyword_entries writes
  └─ optional Beads dependency mirror only for blocks

viewer export
  ├─ bv --export-pages -> beads.sqlite3
  ├─ scan issue labels for ref:* edges
  ├─ write card_edges(source,target,type)
  └─ client buildLinks(dependencies, card_edges)
```

The current boundary is consistent across code and tests: Beads stores issue rows, exact labels, and issue-management dependencies; Silmari supplies Zettelkasten-specific meaning through labels, keyword entries, folgezettel navigation, line-of-thought composition, and typed edge traversal.

## Historical Context From Thoughts

Prior research traces a progression from Beads viewer adaptation toward a Zettelkasten-native surface. The April 11 planning document split work into UI fork scope, `bv --export-pages` edge extraction, and the Beads storage question, explicitly cataloging Beads workarounds and a possible own-schema SQLite direction (`Plans/research/2026-04-11-silmari-memory-card-viewer-planning.md:26`, `Plans/research/2026-04-11-silmari-memory-card-viewer-planning.md:362`). Plan 003 froze `beads_rust` + JSONL + labels-as-edges for that migration and excluded rewriting `silmari-mcp` in Rust in that phase, while leaving later storage/runtime questions open (`Plans/003_pai-fork-mcp-migration.md:60`, `Plans/003_pai-fork-mcp-migration.md:296`).

The April 12 Zettelkasten dashboard research states the key mental model: link structure is retrieval, and a thinking dashboard should measure cluster density, surprise, and cross-domain bridges, not task completion (`thoughts/searchable/shared/research/2026-04-12-zettelkasten-thinking-tool-dashboard-design.md:23`). It describes Luhmann retrieval as keyword register, hub notes, and folgezettel chains (`thoughts/searchable/shared/research/2026-04-12-zettelkasten-thinking-tool-dashboard-design.md:37`).

The April 18 dual-layer graph research reframed the future graph around hub cards, typed cross-references, and the keyword register, with folgezettel as a visible trace rather than the whole spine (`thoughts/searchable/shared/research/2026-04-18-dual-layer-graph-design.md:29`, `thoughts/searchable/shared/research/2026-04-18-dual-layer-graph-design.md:145`).

The active `silmari-agent-memory-xom` Beads issue records the two-phase viewer direction: Phase A strips issue-tracker semantics from `apps/silmari-viewer` and `apps/silmari-memory-card-viewer`; Phase B is a greenfield Zettelkasten-native viewer. The corresponding inventory document is the source of truth for keep/transform/delete decisions (`thoughts/searchable/shared/research/2026-04-19-viewer-fork-and-strip-inventory.md:16`).

The April 22 orphan-card research documents the three-layer recall shape and the keyword-index substrate gap that made LEARN saves recall-blind before the sqlite keyword index work (`thoughts/searchable/shared/research/2026-04-22-silmari-orphan-cards-root-cause.md:124`, `thoughts/searchable/shared/research/2026-04-22-silmari-orphan-cards-root-cause.md:127`). The compounding-substrate plan then formalized sqlite keyword entries, line-of-thought bounded scans, semantic proposer behavior, and a think-with-memory hook (`thoughts/searchable/shared/plans/2026-04-22-tdd-silmari-compounding-substrate.md:35`, `thoughts/searchable/shared/plans/2026-04-22-tdd-silmari-compounding-substrate.md:45`).

The history search found no separate native Rust app plan. Rust currently appears as the existing `beads_rust` CLI/storage engine and the viewer's `bv-graph-wasm` graph engine.

## Related Research

- `thoughts/searchable/shared/research/2026-04-12-zettelkasten-thinking-tool-dashboard-design.md`
- `thoughts/searchable/shared/research/2026-04-12-beads-viewer-zettelkasten-graph-redesign.md`
- `thoughts/searchable/shared/research/2026-04-18-siyuan-as-beads-viewer-replacement.md`
- `thoughts/searchable/shared/research/2026-04-18-dual-layer-graph-design.md`
- `thoughts/searchable/shared/research/2026-04-19-viewer-fork-and-strip-inventory.md`
- `thoughts/searchable/shared/research/2026-04-21-cardview-serendipity-redesign.md`
- `thoughts/searchable/shared/research/2026-04-22-silmari-orphan-cards-root-cause.md`
- `thoughts/searchable/shared/plans/2026-04-22-tdd-silmari-compounding-substrate.md`
- `thoughts/searchable/shared/plans/2026-04-22-tdd-silmari-cascade-extractor.md`
- `thoughts/searchable/shared/plans/2026-04-22-7h6-tdd-keyword-index-uncap.md`

## Open Questions

- No current document in the searched codebase specifies a native Rust replacement application architecture for the Zettelkasten substrate.
- The current code documents Beads as the storage adapter and Silmari as the semantic layer; the exact future boundary between a Rust storage crate, CLI, MCP server, and viewer is not specified in existing research.
- The viewer has both Go/JS/Bun surfaces and Rust WASM graph code; existing documents distinguish near-term fork-and-strip from a later greenfield Zettelkasten viewer but do not define that greenfield runtime.
