---
date: 2026-04-27T18:13:31-04:00
researcher: SilentLynx
git_commit: 9308b7c7f728b384ea24bde3ab96989c9293ca42
branch: main
repository: silmari-agent-memory
topic: "apps/silmari_memory_rust and the existing interfaces for br with the SAI app"
tags: [research, codebase, silmari-memory-rust, silmari-mcp, br, beads-rust, sai]
status: complete
last_updated: 2026-04-28
last_updated_by: SilentLynx
last_updated_note: "Added follow-up research for br vendored frankensqlite and asupersync dependencies"
related_issues: [silmari-agent-memory-wdz, silmari-agent-memory-7jo, silmari-agent-memory-adf, silmari-agent-memory-hkg, silmari-agent-memory-p6i, silmari-agent-memory-rjn, silmari-agent-memory-z12]
---

┌──────────────────────────────────────────────────────────────────────────────┐
│ Research: Silmari Rust Retrieval, br Interfaces, and SAI Touchpoints          │
│ Status: complete                                                             │
│ Date: 2026-04-27                                                             │
└──────────────────────────────────────────────────────────────────────────────┘

# Research: apps/silmari_memory_rust and the existing interfaces for br with the SAI app

**Date**: 2026-04-27T18:13:31-04:00
**Researcher**: SilentLynx
**Git Commit**: 9308b7c7f728b384ea24bde3ab96989c9293ca42
**Branch**: main
**Repository**: silmari-agent-memory
**Tracker context**: `silmari-agent-memory-wdz` created for this research; related open issues include `7jo`, `adf`, `hkg`, `p6i`, and `rjn`.

## Research Question

Research `apps/silmari_memory_rust/` and the existing interfaces for `br` with the SAI app.

## Summary

The codebase currently has three connected but distinct layers:

| Layer | Location | What exists today |
|---|---|---|
| Native Rust retrieval substrate | `apps/silmari_memory_rust/` | A Rust crate and CLI that imports Beads-shaped SQLite data into card-native tables, parses Silmari labels, stores typed card edges, performs exact keyword recall, builds folgezettel neighborhoods, follows typed edges, and returns camelCase JSON contracts. |
| Existing TypeScript `br` boundary | `apps/silmari-mcp/src/lib/br-adapter.ts` plus callers | A synchronous subprocess adapter around the `br` CLI. It resolves per-box `beads.db` paths, creates/list/shows/updates beads, batch-creates via `br create -f`, adds labels, mirrors `blocks` dependencies, and supports MCP tools in `apps/silmari-mcp/src/index.ts`. |
| SAI app surfaces | `SAI/` | Claude Code-facing settings, slash commands, Algorithm prompts, hooks, skills, and installer docs. SAI generally talks to Silmari through MCP `mcp__silmari__zk_*` tools; one hook, `ThinkWithMemory.hook.ts`, imports Silmari MCP library code directly for prompt-time recall. |

The Rust substrate is not a direct replacement wired into `apps/silmari-mcp` in the current checkout. It is a separate native app whose importer can consume Beads-shaped SQLite and materialize Silmari card-native tables. The TypeScript MCP server remains the active `br` integration surface for SAI and existing tools.

## Detailed Findings

### 1. Rust Retrieval Substrate

`apps/silmari_memory_rust` is package `silmari_memory_rust`, version `0.1.0`, edition `2024`, described in `Cargo.toml` as a native Rust retrieval substrate for Silmari memory cards. Its runtime dependencies include `rusqlite` with bundled SQLite, `clap`, `serde`, `serde_json`, `thiserror`, `uuid`, and `chrono`; tests use `assert_cmd`, `predicates`, and `tempfile` (`apps/silmari_memory_rust/Cargo.toml:1`, `apps/silmari_memory_rust/Cargo.toml:8`, `apps/silmari_memory_rust/Cargo.toml:17`).

The library exports modules for CLI, edges, folgezettel, importer, keyword index, labels, model, retrieval, schema, and store (`apps/silmari_memory_rust/src/lib.rs:3`). The binary entry point only delegates to `silmari_memory_rust::cli::run(std::env::args())`, prints unhandled errors to stderr, and exits with the returned code (`apps/silmari_memory_rust/src/main.rs:1`).

| Module | Current responsibility |
|---|---|
| `model.rs` | Defines card kinds, boxes, edge types, parsed labels, card rows, keyword entries, import summaries, and camelCase serialization shapes. |
| `schema.rs` | Initializes native SQLite schema version `1` and creates `cards`, `card_labels`, `card_edges`, `keyword_entries`, and `schema_versions`. |
| `store.rs` | Opens native DBs, inserts/replaces cards, preserves labels, validates label/native-column parity, inserts edges, fetches cards, scans trunks, and manages keyword entries. |
| `labels.rs` | Parses and builds Silmari label wire forms such as `fz:`, `kind:`, `box:`, `trunk:`, `source:`, `content_hash:`, `keyword:`, and `ref:<edge>:<target>`. |
| `folgezettel.rs` | Parses slash-form addresses, validates trunk/sequence syntax, builds parent/sibling/child neighborhoods, scans trunks, and excludes register cards from neighborhood sets. |
| `edges.rs` | Performs bounded outbound/inbound/both traversal over typed native edges and computes inbound `reinforces` density. |
| `keyword_index.rs` | Normalizes keyword terms, looks up exact keyword rows, and appends entry points without losing insertion order. |
| `retrieval.rs` | Composes keyword recall, optional cross-reference expansion, and line-of-thought scope. |
| `importer.rs` | Imports Beads-shaped SQLite rows, labels, dependencies, and optional keyword entries into native card tables. |
| `cli.rs` | Defines `init`, `import-beads`, `recall`, `neighborhood`, `edges`, and `line-of-thought` commands plus success and error JSON envelopes. |

### 2. Rust Native Schema and Import Shape

The Rust schema uses card-native tables, not Beads issue tables. `cards` stores `id`, `box`, `kind`, `title`, `description`, `body`, optional folgezettel address, optional trunk, optional source, optional 8-character content hash, and timestamps (`apps/silmari_memory_rust/src/schema.rs:57`). `card_labels` stores `(card_id, label)` with cascade delete (`apps/silmari_memory_rust/src/schema.rs:81`). `card_edges` stores `(source_id, target_id, edge_type)` with a composite key and an edge type check over all native edge types (`apps/silmari_memory_rust/src/schema.rs:88`). `keyword_entries` stores exact keyword terms, JSON entry points, curator, and timestamp (`apps/silmari_memory_rust/src/schema.rs:98`).

The importer reads Beads-shaped `issues` rows, optional `labels`, optional `dependencies`, and optional `keyword_entries`. It skips deleted, ephemeral, template, and status `deleted` rows; derives box/kind/fz/trunk/source/content-hash from labels when present; composes body text from description/design/acceptance/notes; preserves labels; imports `ref:` labels as native card edges; imports only `blocks` dependencies from Beads dependency rows; and can import preexisting keyword entries (`apps/silmari_memory_rust/src/importer.rs:34`, `apps/silmari_memory_rust/src/importer.rs:67`, `apps/silmari_memory_rust/src/importer.rs:72`, `apps/silmari_memory_rust/src/importer.rs:93`, `apps/silmari_memory_rust/src/importer.rs:97`, `apps/silmari_memory_rust/src/importer.rs:121`, `apps/silmari_memory_rust/src/importer.rs:274`).

### 3. Rust Retrieval and CLI Contracts

Rust recall is exact keyword-register lookup first. A miss returns a structured miss with `query`, `entryPoints: null`, and empty `entryCards`, `neighborhoods`, and `crossRefs` (`apps/silmari_memory_rust/src/retrieval.rs:123`, `apps/silmari_memory_rust/src/retrieval.rs:138`). A hit deduplicates, sorts, truncates to `limit_per_term`, reports total matches and truncation, resolves entry addresses into neighborhoods, and optionally follows typed edges when `RecallOptions.edge_types` is set (`apps/silmari_memory_rust/src/retrieval.rs:141`, `apps/silmari_memory_rust/src/retrieval.rs:150`, `apps/silmari_memory_rust/src/retrieval.rs:166`, `apps/silmari_memory_rust/src/retrieval.rs:179`). Default sort is inbound `reinforces` density, with recency as the alternate sort mode (`apps/silmari_memory_rust/src/retrieval.rs:17`, `apps/silmari_memory_rust/src/retrieval.rs:209`).

Line-of-thought retrieval can start from a card ID or folgezettel address. It combines the queried card, immediate parent, same-depth siblings, immediate children, hub cards, trunk seeds, and an `all` scope capped at 150 (`apps/silmari_memory_rust/src/retrieval.rs:318`, `apps/silmari_memory_rust/src/retrieval.rs:330`, `apps/silmari_memory_rust/src/retrieval.rs:354`, `apps/silmari_memory_rust/src/retrieval.rs:380`, `apps/silmari_memory_rust/src/retrieval.rs:402`, `apps/silmari_memory_rust/src/retrieval.rs:421`).

The CLI exposes:

| Command | Output shape |
|---|---|
| `init --db <path> [--json]` | `{"ok":true,"db":"<path>"}` |
| `import-beads --source <path> --db <path> [--box-name <box>] [--json]` | `ImportSummary` with `importedCards`, `skippedCards`, `labels`, `edges`, and `keywords` |
| `recall --db <path> --query <term> [--json]` | `RecallSession` with `query`, `entryPoints`, `entryCards`, `neighborhoods`, and `crossRefs` |
| `neighborhood --db <path> --address <addr> [--json]` | `Neighborhood` with `queried`, `parents`, `siblings`, and `children` |
| `edges --db <path> --seed <id> ... [--json]` | `EdgeTraversal` with `root`, `cards`, and `edges` |
| `line-of-thought --db <path> (--card-id <id>|--address <addr>) [--json]` | `LineOfThought` with `queried`, `parent`, `siblings`, `children`, `hubs`, `trunkSeeds`, `all`, and `totalScope` |

The CLI error envelope is `{"error":{"code":"...","message":"...","details":{...}}}`. Runtime errors exit `1`; parse errors with `--json` exit `2`; `main.rs` handles non-JSON unhandled errors by printing to stderr and exiting `1` (`apps/silmari_memory_rust/src/cli.rs:135`, `apps/silmari_memory_rust/src/cli.rs:172`, `apps/silmari_memory_rust/src/cli.rs:185`, `apps/silmari_memory_rust/src/main.rs:2`).

### 4. Existing TypeScript br Adapter

The current active `br` boundary for Silmari MCP is `apps/silmari-mcp/src/lib/br-adapter.ts`. It shells out synchronously with `execFileSync`, uses `BR = 'br'`, sets actor `silmari-mcp`, and defines read/write/init timeouts of 500 ms, 1000 ms, and 3000 ms (`apps/silmari-mcp/src/lib/br-adapter.ts:32`, `apps/silmari-mcp/src/lib/br-adapter.ts:41`, `apps/silmari-mcp/src/lib/br-adapter.ts:44`).

`getDbFlag(box)` points each call at `join(getBoxBeadsDir(box), 'beads.db')`; `baseFlags(box)` adds `--json`, `--actor`, and the db flag (`apps/silmari-mcp/src/lib/br-adapter.ts:96`, `apps/silmari-mcp/src/lib/br-adapter.ts:100`). `paths.ts` defines two boxes, `biblio` and `idea`, with default directories `~/.silmari/box1-biblio/.beads` and `~/.silmari/box2-ideas/.beads`, plus `SILMARI_BIBLIO_DIR` and `SILMARI_IDEA_DIR` overrides (`apps/silmari-mcp/src/lib/paths.ts:28`, `apps/silmari-mcp/src/lib/paths.ts:67`, `apps/silmari-mcp/src/lib/paths.ts:81`).

The adapter wrappers cover:

| Wrapper | br command surface |
|---|---|
| `isBeadsAvailable()` | `br --version`, cached per process |
| `brCreate()` | `br create <title> -t <type> --json --actor silmari-mcp --db <box-db>` |
| `brCreateBatch()` | `br create -f <tmp.md> --json --actor silmari-mcp --db <box-db>` |
| `brUpdate()` | `br update <id> ... --json --actor silmari-mcp --db <box-db>` |
| `brList()` | `br list --json --db <box-db>` plus label/status/all/limit/sort/reverse filters |
| `brSearch()` | `br search <query> --json --db <box-db>` |
| `brShow()` | `br show <id> --json --db <box-db>` |
| `brClose()` | `br close <id> --json --actor silmari-mcp --db <box-db>` |
| `brDelete()` | `br delete <id> --json --actor silmari-mcp --db <box-db>` |
| `brDepAdd()` | `br dep add <fromId> <toId> --type <depType> ...` |
| `brDepList()` | `br dep list <id> --direction <direction> --format json --db <box-db>` |
| `brLabelAdd()` / `brLabelRemove()` | `br label add/remove <id> <labels...> --json --actor silmari-mcp --db <box-db>` |

Most wrappers degrade to `null`, `false`, or `[]` on failure. `brCreateBatch()` throws on structural batch failures, and `brList()` throws `BrListTimeoutError` on subprocess timeout so callers can distinguish timeout from a real empty list (`apps/silmari-mcp/src/lib/br-adapter.ts:222`, `apps/silmari-mcp/src/lib/br-adapter.ts:245`, `apps/silmari-mcp/src/lib/br-adapter.ts:49`, `apps/silmari-mcp/src/lib/br-adapter.ts:362`).

`brList()` and `brSearch()` detect structured `{error: ...}` payloads and convert them to `[]` after logging. `brShow()` unwraps array or object output, rejects structured errors, rejects fuzzy ID mismatches, and retries once after 100 ms for recoverable misses such as `ISSUE_NOT_FOUND` or `AMBIGUOUS_ID` (`apps/silmari-mcp/src/lib/br-adapter.ts:353`, `apps/silmari-mcp/src/lib/br-adapter.ts:395`, `apps/silmari-mcp/src/lib/br-adapter.ts:419`, `apps/silmari-mcp/src/lib/br-adapter.ts:445`, `apps/silmari-mcp/src/lib/br-adapter.ts:454`, `apps/silmari-mcp/src/lib/br-adapter.ts:481`).

### 5. br Label, Edge, and Card Semantics in TypeScript

Silmari metadata is label-first in the TypeScript MCP server. `labels.ts` centralizes `fz:`, `kind:`, `box:`, `trunk:`, `scope:`, `source:`, `ref:`, `content_hash:`, `keyword:`, and `upsert:` prefixes (`apps/silmari-mcp/src/lib/labels.ts:28`). Folgezettel addresses use slash form outside labels but label form uses `_`, so `2/3a1` becomes `fz:2_3a1`; `parseFzFromLabels()` translates back to slash form (`apps/silmari-mcp/src/lib/labels.ts:114`, `apps/silmari-mcp/src/lib/labels.ts:133`, `apps/silmari-mcp/src/lib/labels.ts:213`).

Semantic edges are label-encoded as `ref:<type>:<targetId>` on the source bead (`apps/silmari-mcp/src/lib/labels.ts:157`, `apps/silmari-mcp/src/lib/edges.ts:4`). `addEdge()` writes that label with `brLabelAdd`; when the edge is `blocks`, it also mirrors the edge into the Beads dependency graph using `brDepAdd(box, fromId, toId, 'blocks')` (`apps/silmari-mcp/src/lib/edges.ts:76`, `apps/silmari-mcp/src/lib/edges.ts:91`, `apps/silmari-mcp/src/lib/edges.ts:96`).

`card-ops.ts` is the main save path. It imports `brCreate`, `brCreateBatch`, `brList`, `brLabelAdd`, `brShow`, and `BrListTimeoutError`; builds title/body/description/labels; uses `content_hash:<short>` label lookup; writes cards via `brCreate` or `brCreateBatch`; and performs post-save edge, keyword, and line-of-thought steps (`apps/silmari-mcp/src/lib/card-ops.ts:23`, `apps/silmari-mcp/src/lib/card-ops.ts:369`, `apps/silmari-mcp/src/lib/card-ops.ts:756`, `apps/silmari-mcp/src/lib/card-ops.ts:820`, `apps/silmari-mcp/src/lib/card-ops.ts:911`, `apps/silmari-mcp/src/lib/card-ops.ts:1019`).

### 6. MCP Tools and Resources that Reach br

`apps/silmari-mcp/src/index.ts` defines the MCP tools. The br-backed dispatch paths include:

| Tool/resource | Current br-backed path |
|---|---|
| `zk_save_card` | Validates args and calls `saveCard`, which calls `brCreate` and post-save br-backed helpers (`apps/silmari-mcp/src/index.ts:529`, `apps/silmari-mcp/src/index.ts:538`). |
| `zk_save_cards` | Maps inputs to idea-card save opts and calls `saveCardsBatch`, which calls `brCreateBatch` once for the create phase (`apps/silmari-mcp/src/index.ts:553`, `apps/silmari-mcp/src/index.ts:569`). |
| `zk_recall` | Calls `navigate()`, which preloads idea beads with `brList`, resolves cards with `brShow`, and can traverse `ref:` labels (`apps/silmari-mcp/src/index.ts:573`, `apps/silmari-mcp/src/lib/navigate.ts:662`). |
| `zk_neighborhood` / `zk_chain` | Call folgezettel helpers backed by `scanTrunk()` and `brList` (`apps/silmari-mcp/src/index.ts:590`, `apps/silmari-mcp/src/index.ts:596`, `apps/silmari-mcp/src/lib/navigate.ts:220`). |
| `zk_follow` | Calls edge traversal backed by `brShow` for outbound reads and `brList` reverse-label queries for inbound reads (`apps/silmari-mcp/src/index.ts:602`, `apps/silmari-mcp/src/lib/navigate.ts:487`). |
| `zk_commit_link` | Calls `commitLink()`, which writes labels through `addEdge()` (`apps/silmari-mcp/src/index.ts:661`, `apps/silmari-mcp/src/lib/edges.ts:326`). |
| `zk_hub_create` / `zk_hub_add_card` / `zk_hub_members` | Use `brList`, `saveCard`, `brDelete`, `brUpdate`, `brShow`, and reverse `ref:derives-from:<hubId>` label queries through hub helpers (`apps/silmari-mcp/src/index.ts:669`, `apps/silmari-mcp/src/index.ts:678`, `apps/silmari-mcp/src/index.ts:686`, `apps/silmari-mcp/src/lib/hubs.ts:119`). |
| `zk_register_read` | Reads Register beads with `brList` over `kind:register` and trunk labels (`apps/silmari-mcp/src/index.ts:708`, `apps/silmari-mcp/src/lib/init.ts:181`). |
| `zk_block` | Calls `addEdge(..., 'blocks', ...)`, which also mirrors to `br dep add` (`apps/silmari-mcp/src/index.ts:716`, `apps/silmari-mcp/src/index.ts:721`). |
| `zk_status` | Calls `isBeadsAvailable()` and counts cards with `brList` (`apps/silmari-mcp/src/index.ts:739`, `apps/silmari-mcp/src/index.ts:740`). |
| `zk_recall_by_status` | Calls `brList` with status, label, limit, all, and sort filters (`apps/silmari-mcp/src/index.ts:771`, `apps/silmari-mcp/src/index.ts:779`). |
| `zk_promote` | Reads with `brShow` and updates status through `brUpdate` (`apps/silmari-mcp/src/index.ts:800`, `apps/silmari-mcp/src/index.ts:817`). |
| `silmari://card/<id>` | Resolves box by ID prefix and calls `brShow` (`apps/silmari-mcp/src/index.ts:852`). |

The direct wrapper tests live in `apps/silmari-mcp/tests/br-adapter.test.ts`. They use a real `br` binary against temp `SILMARI_*` dirs and cover exact `brShow`, fuzzy-prefix rejection, `AMBIGUOUS_ID`, `brList`/`brSearch` no-match shape, `brShow` retry behavior, `brLabelAdd` retry behavior, and `brList` timeout discrimination (`apps/silmari-mcp/tests/br-adapter.test.ts:19`, `apps/silmari-mcp/tests/br-adapter.test.ts:24`, `apps/silmari-mcp/tests/br-adapter.test.ts:90`, `apps/silmari-mcp/tests/br-adapter.test.ts:115`, `apps/silmari-mcp/tests/br-adapter.test.ts:152`, `apps/silmari-mcp/tests/br-adapter.test.ts:178`, `apps/silmari-mcp/tests/br-adapter.test.ts:216`, `apps/silmari-mcp/tests/br-adapter.test.ts:245`, `apps/silmari-mcp/tests/br-adapter.test.ts:281`).

### 7. SAI App Touchpoints

SAI’s repository surface is Claude Code-facing. `SAI/settings.json` allows `mcp__*`, enables all project MCP servers, and registers memory-adjacent hooks including `ThinkWithMemory.hook.ts` on `UserPromptSubmit`, `LoadContext.hook.ts` on `SessionStart`, and local memory/relationship/learning hooks on session end (`SAI/settings.json:11`, `SAI/settings.json:65`, `SAI/settings.json:162`, `SAI/settings.json:192`, `SAI/settings.json:218`).

`SAI/commands/silmari.md` is the direct slash-command documentation for the Silmari MCP memory server. It instructs agents to call `mcp__silmari__zk_*` tools directly and not shell out to `zettel`, `bv`, `br`, or `curl`. It lists the available MCP tools, card kinds, trunk mapping, status states, resources, and known gaps (`SAI/commands/silmari.md:1`, `SAI/commands/silmari.md:7`, `SAI/commands/silmari.md:27`, `SAI/commands/silmari.md:62`).

`SAI/Algorithm/LATEST` points to `v3.8.1` (`SAI/Algorithm/LATEST:1`). `SAI/Algorithm/v3.8.1.md` defines Silmari MCP as the persistent memory layer, documents the three-layer `zk_recall` shape, requires OBSERVE recall before reverse engineering, uses LEARN-time `zk_save_card`, `zk_propose_link`, `zk_commit_link`, and hub flows, and includes in-progress resumption via recall/status conventions (`SAI/Algorithm/v3.8.1.md:27`, `SAI/Algorithm/v3.8.1.md:46`, `SAI/Algorithm/v3.8.1.md:77`, `SAI/Algorithm/v3.8.1.md:203`, `SAI/Algorithm/v3.8.1.md:353`, `SAI/Algorithm/v3.8.1.md:523`).

The hook surface splits Silmari MCP recall from SAI local filesystem memory:

| Hook/tool | Current memory interface |
|---|---|
| `SAI/hooks/ThinkWithMemory.hook.ts` | Dynamically resolves `apps/silmari-mcp`, imports keyword index, `brShow`, navigation, and labels, then injects prior-thought context on "help me think" prompts (`SAI/hooks/ThinkWithMemory.hook.ts:1`, `SAI/hooks/ThinkWithMemory.hook.ts:95`, `SAI/hooks/ThinkWithMemory.hook.ts:267`). |
| `SAI/hooks/lib/think-with-memory.ts` | Pure helpers that model recall layers as `keywordEntries`, `folgezettelNeighbors`, and `crossRefs` (`SAI/hooks/lib/think-with-memory.ts:43`, `SAI/hooks/lib/think-with-memory.ts:83`, `SAI/hooks/lib/think-with-memory.ts:190`). |
| `SAI/hooks/LoadContext.hook.ts` | Reads SAI local memory from `MEMORY/RELATIONSHIP`, `MEMORY/LEARNING`, `MEMORY/WORK`, and `MEMORY/STATE` at session start (`SAI/hooks/LoadContext.hook.ts:1`, `SAI/hooks/LoadContext.hook.ts:207`, `SAI/hooks/LoadContext.hook.ts:456`). |
| `SAI/Tools/SessionProgress.ts` | Documents active-project mirroring into in-progress Silmari cards, but its current `runZettel` path returns a disabled notice because the legacy `zettel` CLI was removed (`SAI/Tools/SessionProgress.ts:15`, `SAI/Tools/SessionProgress.ts:82`, `SAI/Tools/SessionProgress.ts:150`). |
| `SAI/skills/Marketing/SKILL.md` | Contains a Silmari memory section noting post-rebrand `mcp__silmari__zk_status({})`, `zk_recall`, and save-after-phase behavior (`SAI/skills/Marketing/SKILL.md:68`). |
| `SAI/skills/bd-to-br-migration/SKILL.md` | Documents mechanical `bd` to `br` command migration and the sync behavior difference: `br sync --flush-only` exports only and must be followed by manual git steps (`SAI/skills/bd-to-br-migration/SKILL.md:1`, `SAI/skills/bd-to-br-migration/SKILL.md:90`, `SAI/skills/bd-to-br-migration/SKILL.md:264`). |

`SAI/ACTIONS` does not currently contain direct `zk_recall`, `zk_save_card`, `zettel`, or beads call sites in the searched action files. The action docs describe generic JSON-in/JSON-out units and injected capabilities (`SAI/ACTIONS/README.md:1`, `SAI/ACTIONS/README.md:110`, `SAI/ACTIONS.md:1`, `SAI/ACTIONS.md:89`).

## Architecture Documentation

```
SAI prompts / hooks / skills
        |
        | Claude Code MCP tool calls or direct library imports in selected hooks
        v
apps/silmari-mcp TypeScript server
        |
        | br-adapter.ts subprocess calls
        v
br / beads_rust SQLite stores
        |
        | Beads-shaped source DB can be imported
        v
apps/silmari_memory_rust native card DB
```

The current architecture keeps Silmari’s semantic model above the Beads issue-tracker substrate. In TypeScript, the semantic model is expressed through labels, `ref:` edges, folgezettel parsing, keyword index rows, and MCP tools. In Rust, the model is materialized into native `cards`, `card_labels`, `card_edges`, and `keyword_entries` tables.

The Rust app and TypeScript MCP server share the same conceptual vocabulary:

| Concept | TypeScript MCP | Rust substrate |
|---|---|---|
| Card kinds | `VALID_CARD_KINDS` in `labels.ts` | `CardKind` in `model.rs` |
| Boxes | `Box = 'biblio' \| 'idea'` in `paths.ts` | `CardBox` in `model.rs` |
| Folgezettel label | `fz:<trunk>_<seq>` via `fzLabel()` | Parsed by `labels.rs`, stored as slash address |
| Semantic edge | `ref:<edge>:<target>` label | Native `card_edges` row, imported from `ref:` labels |
| Keyword entry | TypeScript `silmari.db` keyword index | Native `keyword_entries` table |
| Recall shape | `zk_recall` via `navigate()` | `RecallSession` from Rust `retrieval.rs` |

## Historical Context

The historical `thoughts/` documents frame the current code in a sequence:

| Date | Documented context |
|---|---|
| 2026-04-12 | SAI rebrand and MCP migration moved Algorithm memory instructions from legacy `zettel` calls to `mcp__silmari__zk_*`, installed `/silmari`, and documented the three-layer recall shape (`thoughts/shared/handoffs/general/2026-04-12_07-57-20_sai-rebrand-mcp-migration.md`). |
| 2026-04-16 | SAI canonicalization records `SAI/` as source of truth and `~/.claude/` as a derived install target (`thoughts/shared/plans/2026-04-16-sai-pai-rebrand-execution.md`). |
| 2026-04-24 | `br` wrapper research maps `brShow`, `brList`, `brSearch`, `brLabelAdd`, and ID-resolution behavior around Beads Rust structured errors (`thoughts/shared/research/2026-04-24-09-09-silmari-agent-memory-hkg-p6i-br-prefix-match-bugs.md`). |
| 2026-04-25 | SAI portability research separates provider-neutral Silmari MCP from Claude Code-specific SAI runtime hooks, skills, and settings (`thoughts/shared/research/2026-04-25-sai-claude-codex-gemini-portability-research.md`). |
| 2026-04-26 | Cascade stabilization documents `zk_save_cards` and `br create -f` batch import as the way current TypeScript MCP reduces create subprocess count (`thoughts/shared/plans/2026-04-26-17-56-tdd-three-fix-cascade-stabilization.md`). |
| 2026-04-27 | The Rust retrieval research and TDD plan establish `apps/silmari_memory_rust` as a native retrieval substrate with card-native schema, exact keyword lookup, folgezettel neighborhoods, typed edges, line-of-thought retrieval, and Beads-shaped import (`thoughts/shared/research/2026-04-27-zettelkasten-rust-retrieval-substrate.md`, `thoughts/shared/plans/2026-04-27-tdd-silmari-memory-rust-retrieval-substrate.md`). |

## Code References

| Path | What is there |
|---|---|
| `apps/silmari_memory_rust/Cargo.toml:1` | Rust crate package metadata and dependencies. |
| `apps/silmari_memory_rust/src/lib.rs:3` | Public module exports and crate-level error type. |
| `apps/silmari_memory_rust/src/schema.rs:57` | Native `cards` table definition. |
| `apps/silmari_memory_rust/src/schema.rs:81` | `card_labels` table definition. |
| `apps/silmari_memory_rust/src/schema.rs:88` | `card_edges` table definition. |
| `apps/silmari_memory_rust/src/importer.rs:34` | Beads-shaped source DB import entry point. |
| `apps/silmari_memory_rust/src/retrieval.rs:111` | Keyword recall composition. |
| `apps/silmari_memory_rust/src/retrieval.rs:318` | Line-of-thought composition. |
| `apps/silmari_memory_rust/src/cli.rs:24` | CLI subcommand definitions. |
| `apps/silmari-mcp/src/lib/br-adapter.ts:41` | `br` binary, actor, and timeout constants. |
| `apps/silmari-mcp/src/lib/br-adapter.ts:96` | Box-specific `--db` flag helper. |
| `apps/silmari-mcp/src/lib/br-adapter.ts:166` | `brCreate` single-card wrapper. |
| `apps/silmari-mcp/src/lib/br-adapter.ts:222` | `brCreateBatch` markdown import wrapper. |
| `apps/silmari-mcp/src/lib/br-adapter.ts:330` | `brList` wrapper and timeout handling. |
| `apps/silmari-mcp/src/lib/br-adapter.ts:419` | `brShow` wrapper, structured-error handling, exact-id behavior, and retry. |
| `apps/silmari-mcp/src/lib/paths.ts:81` | Per-box Beads directory resolution. |
| `apps/silmari-mcp/src/lib/labels.ts:28` | Silmari label namespace. |
| `apps/silmari-mcp/src/lib/edges.ts:76` | Edge label writer and `blocks` dependency mirror. |
| `apps/silmari-mcp/src/lib/card-ops.ts:756` | Single-card save flow. |
| `apps/silmari-mcp/src/lib/card-ops.ts:911` | Batch save flow. |
| `apps/silmari-mcp/src/index.ts:101` | MCP tool definition table. |
| `apps/silmari-mcp/src/index.ts:527` | MCP tool dispatch switch. |
| `SAI/commands/silmari.md:1` | SAI slash command instructions for Silmari MCP. |
| `SAI/Algorithm/v3.8.1.md:27` | Algorithm memory layer definition. |
| `SAI/hooks/ThinkWithMemory.hook.ts:95` | Direct dynamic import path into Silmari MCP library code. |
| `SAI/skills/bd-to-br-migration/SKILL.md:1` | SAI skill for `bd` to `br` documentation migration. |

## Related Research

- `thoughts/shared/research/2026-04-27-zettelkasten-rust-retrieval-substrate.md`
- `thoughts/shared/plans/2026-04-27-tdd-silmari-memory-rust-retrieval-substrate.md`
- `thoughts/shared/research/2026-04-24-09-09-silmari-agent-memory-hkg-p6i-br-prefix-match-bugs.md`
- `thoughts/shared/research/2026-04-25-sai-claude-codex-gemini-portability-research.md`
- `thoughts/shared/research/2026-04-26-cascade-rerun-5xj-m07-research.md`
- `thoughts/shared/plans/2026-04-26-17-56-tdd-three-fix-cascade-stabilization.md`
- `thoughts/shared/handoffs/general/2026-04-12_07-57-20_sai-rebrand-mcp-migration.md`

## Research Artifacts

Subagent and follow-up notes were written under:

- `artifacts/research/2026-04-27-silmari-memory-rust-br-sai/rust-crate.md`
- `artifacts/research/2026-04-27-silmari-memory-rust-br-sai/mcp-br-interface.md`
- `artifacts/research/2026-04-27-silmari-memory-rust-br-sai/sai-touchpoints.md`
- `artifacts/research/2026-04-27-silmari-memory-rust-br-sai/historical-context.md`
- `artifacts/research/2026-04-28-br-vendor-dependencies/frankensqlite.md`
- `artifacts/research/2026-04-28-br-vendor-dependencies/asupersync.md`
- `artifacts/research/2026-04-28-br-vendor-dependencies/beads-rust-vendor-integration.md`

## Follow-up Research 2026-04-28T04:39:24-04:00: br vendored dependencies

### Research Question

Extend this research to include the two repository-local dependencies used by the `br` crate:

- `vendor/frankensqlite`
- `vendor/asupersync`

### Summary

The `br` binary is built by `vendor/beads_rust`. Its primary storage implementation is `SqliteStorage`, which uses the `fsqlite` crate family instead of `rusqlite` in the current vendored checkout (`vendor/beads_rust/src/storage/sqlite.rs:14`, `vendor/beads_rust/src/storage/sqlite.rs:41`). `vendor/beads_rust/Cargo.toml` declares the `fsqlite*` crates as database dependencies and patches those crates to sibling paths under `../frankensqlite/crates/*` (`vendor/beads_rust/Cargo.toml:47`, `vendor/beads_rust/Cargo.toml:153`).

`asupersync` enters the `br` dependency graph through the patched `fsqlite` stack. `vendor/frankensqlite/Cargo.toml` declares `asupersync = "0.2.9"` as a workspace dependency (`vendor/frankensqlite/Cargo.toml:167`), and the `beads_rust` lockfile records `asupersync` as a dependency of `fsqlite-core`, `fsqlite-types`, `fsqlite-vdbe`, `fsqlite-vfs`, and `fsqlite-wal` (`vendor/beads_rust/Cargo.lock:1450`, `vendor/beads_rust/Cargo.lock:1637`, `vendor/beads_rust/Cargo.lock:1653`, `vendor/beads_rust/Cargo.lock:1674`, `vendor/beads_rust/Cargo.lock:1690`). The local `vendor/asupersync` checkout is a matching `asupersync` `0.2.9` workspace (`vendor/asupersync/Cargo.toml:15`). In the current `vendor/beads_rust/Cargo.toml`, there is no direct `../asupersync` path patch; the direct path patch is for `frankensqlite`, and `asupersync` is represented in the `fsqlite` graph.

```
vendor/beads_rust
  ├─ builds bin: br
  ├─ imports fsqlite::Connection in SqliteStorage
  ├─ patches fsqlite* crates to ../frankensqlite/crates/*
  │    ├─ fsqlite-core
  │    ├─ fsqlite-types
  │    ├─ fsqlite-vfs
  │    ├─ fsqlite-wal
  │    └─ other fsqlite crates
  └─ reaches asupersync through the fsqlite dependency graph
       ├─ native Cx / cancellation / runtime attachment
       ├─ io_uring VFS backend
       ├─ write coordinator channels and task spawning
       └─ WAL-FEC RaptorQ encode/decode helpers
```

### vendor/frankensqlite

`vendor/frankensqlite` is a Rust workspace for the `fsqlite` family and also contains npm workspaces for browser/worker packaging. The Rust workspace uses resolver 2, edition 2024, repository `https://github.com/Dicklesworthstone/frankensqlite`, Rust 1.85, and shared SQLite/database/parser package metadata (`vendor/frankensqlite/Cargo.toml:1`, `vendor/frankensqlite/Cargo.toml:34`). Workspace members include core engine, types, error, VFS, pager, WAL, MVCC, btree, parser, planner, VDBE, functions, extensions, CLI, e2e/harness, observability, C API, and WASM crates (`vendor/frankensqlite/Cargo.toml:4`).

The public Rust facade is the `fsqlite` crate. Its `Cargo.toml` describes it as the public API facade and its default features include `native`, `linux-asupersync-uring`, JSON, FTS5, and RTree (`vendor/frankensqlite/crates/fsqlite/Cargo.toml:1`, `vendor/frankensqlite/crates/fsqlite/Cargo.toml:25`). The facade re-exports connection, row, prepared-statement, runtime config/context, trace, error, value, and VFS types from the underlying crates (`vendor/frankensqlite/crates/fsqlite/src/lib.rs:6`).

The backing implementation is `fsqlite-core::Connection`. It carries runtime configuration and context types, connection/open/query/execute/transaction APIs, row and prepared-statement types, pager-backed storage state, VDBE state, schema caches, PRAGMA state, MVCC/concurrent writer state, WAL state, and attached database state (`vendor/frankensqlite/crates/fsqlite-core/src/connection.rs:1131`, `vendor/frankensqlite/crates/fsqlite-core/src/connection.rs:2435`, `vendor/frankensqlite/crates/fsqlite-core/src/connection.rs:3172`, `vendor/frankensqlite/crates/fsqlite-core/src/connection.rs:5733`). The root README describes the current runtime as a hybrid engine with `fsqlite::Connection` as the public entry, pager-backed table execution through `fsqlite-vdbe::VdbeEngine`, and `MemDatabase` retained as an execution image/fallback (`vendor/frankensqlite/README.md:30`).

The `br` crate uses this stack through path-patched dependencies. `vendor/beads_rust/Cargo.toml` lists `fsqlite`, `fsqlite-types`, `fsqlite-error`, `fsqlite-core`, `fsqlite-func`, `fsqlite-vdbe`, `fsqlite-vfs`, `fsqlite-pager`, `fsqlite-parser`, `fsqlite-planner`, `fsqlite-wal`, `fsqlite-btree`, `fsqlite-ast`, `fsqlite-mvcc`, and `fsqlite-observability` in its database dependency block (`vendor/beads_rust/Cargo.toml:47`). Its `[patch.crates-io]` section resolves those crates, plus extension crates, to `../frankensqlite/crates/*` (`vendor/beads_rust/Cargo.toml:153`). The installer reflects the same sibling layout: it clones `frankensqlite` next to `beads_rust` before building from source (`vendor/beads_rust/install.sh:1042`).

Inside `br`, `SqliteStorage` imports `fsqlite::Connection`, `fsqlite_error::FrankenError`, and `fsqlite_types::SqliteValue` (`vendor/beads_rust/src/storage/sqlite.rs:14`). File-backed `SqliteStorage::open_with_timeout` calls `Connection::open`, applies `PRAGMA busy_timeout`, checks runtime schema compatibility, and applies either runtime-compatible schema updates or full schema initialization (`vendor/beads_rust/src/storage/sqlite.rs:381`). Mutation helpers use explicit `BEGIN IMMEDIATE`, `COMMIT`, and `ROLLBACK` through the `fsqlite` connection and retry transient errors (`vendor/beads_rust/src/storage/sqlite.rs:214`).

The `br` source also contains direct `fsqlite` reads outside the main storage wrapper. CLI completion/config code opens database snapshots through `fsqlite::Connection` and reads saved query keys from the `config` table (`vendor/beads_rust/src/cli/mod.rs:6`, `vendor/beads_rust/src/cli/mod.rs:215`). Doctor/config/info command helpers also import `fsqlite` directly (`vendor/beads_rust/src/cli/commands/doctor.rs:14`, `vendor/beads_rust/src/cli/commands/config.rs:20`, `vendor/beads_rust/src/cli/commands/info.rs:8`).

### vendor/asupersync

`vendor/asupersync` is a Rust async-runtime workspace with browser and TypeScript package surfaces. The root package is `asupersync` version `0.2.9`, edition 2024, described as a "Spec-first, cancel-correct, capability-secure async runtime for Rust" (`vendor/asupersync/Cargo.toml:15`, `vendor/asupersync/Cargo.toml:20`). Workspace members include the root crate, macros, browser core, Tokio compatibility, conformance, FrankenSuite evidence/decision/kernel crates, frankenlab, and `drop_unwrap_finder`; `fuzz` and `asupersync-wasm` are excluded (`vendor/asupersync/Cargo.toml:1`).

The root crate exposes broad runtime modules, including `cx`, `runtime`, `channel`, `sync`, `time`, `trace`, `lab`, `fs`, `io`, `net`, `raptorq`, `database`, and more (`vendor/asupersync/src/lib.rs:151`). It re-exports `Cx`, structured concurrency scope/runtime/lab types, config types, encoding/decoding helpers, epoch and error types, and structured-concurrency proc macros when enabled (`vendor/asupersync/src/lib.rs:235`, `vendor/asupersync/src/lib.rs:288`). The CLI binary is feature-gated behind `cli` and defines top-level `trace`, `conformance`, `lab`, and `doctor` commands (`vendor/asupersync/Cargo.toml:117`, `vendor/asupersync/src/bin/asupersync.rs:80`).

For `br`, the active relationship is through `frankensqlite`/`fsqlite`, not through direct imports in `vendor/beads_rust/src`. A search of `vendor/beads_rust/src` finds direct imports of `fsqlite`, `fsqlite_error`, and `fsqlite_types`, while `asupersync` appears in `vendor/beads_rust/Cargo.lock` and in `vendor/frankensqlite` crate manifests/source. `vendor/beads_rust/CHANGELOG.md` also records a CI note to clone `asupersync` because it is a path dependency of `fsqlite-core` in that release context (`vendor/beads_rust/CHANGELOG.md:127`).

The `fsqlite` stack uses `asupersync` for runtime/capability integration in several places:

| fsqlite area | Current asupersync use |
|---|---|
| `fsqlite-types` | The `native` feature enables optional `asupersync`; `cx.rs` imports native time, cancel-kind/reason, budget, and `Cx` types (`vendor/frankensqlite/crates/fsqlite-types/Cargo.toml:10`, `vendor/frankensqlite/crates/fsqlite-types/src/cx.rs:34`). |
| `fsqlite-vfs` | The default feature is `linux-asupersync-uring`; the Linux VFS imports `asupersync::fs::IoUringFile` and uses the asupersync io_uring backend for read/write paths when that feature is enabled (`vendor/frankensqlite/crates/fsqlite-vfs/Cargo.toml:10`, `vendor/frankensqlite/crates/fsqlite-vfs/src/uring.rs:19`, `vendor/frankensqlite/crates/fsqlite-vfs/src/uring.rs:462`, `vendor/frankensqlite/crates/fsqlite-vfs/src/uring.rs:592`). |
| `fsqlite-core` | Native runtime context can attach the ambient `asupersync::Cx` and current runtime handle, then use an active asupersync runtime to spawn write-coordinator tasks (`vendor/frankensqlite/crates/fsqlite-core/Cargo.toml:66`, `vendor/frankensqlite/crates/fsqlite-core/src/connection.rs:1174`, `vendor/frankensqlite/crates/fsqlite-core/src/connection.rs:47008`). |
| `fsqlite-core` write coordinator | Uses `asupersync::channel::oneshot` for write-coordinator shutdown signaling (`vendor/frankensqlite/crates/fsqlite-core/src/connection.rs:46920`). |
| `fsqlite-wal` | WAL-FEC imports `asupersync` channels/runtime and RaptorQ APIs; repair symbol generation uses `asupersync::raptorq::systematic::SystematicEncoder`, and decode uses `asupersync::raptorq::decoder::InactivationDecoder` (`vendor/frankensqlite/crates/fsqlite-wal/src/wal_fec.rs:21`, `vendor/frankensqlite/crates/fsqlite-wal/src/wal_fec.rs:1879`, `vendor/frankensqlite/crates/fsqlite-wal/src/wal_fec.rs:2023`). |

`asupersync` also has its own feature-gated database module, but this is not the `br` storage path in the current checkout. The `asupersync` database module describes SQLite as a blocking-pool wrapper and Postgres/MySQL as async TCP wire-protocol clients (`vendor/asupersync/src/database/mod.rs:1`); `br` reaches SQLite through `vendor/beads_rust`'s `SqliteStorage` and the patched `fsqlite` crates.

### br command surfaces that exercise these dependencies

The existing TypeScript Silmari MCP boundary still shells out to `br`, so all `br`-backed MCP operations described earlier eventually exercise `vendor/beads_rust`'s storage layer when the `br` binary opens a workspace database. In `br` itself:

| br surface | Dependency path |
|---|---|
| Issue CRUD and query commands | CLI command handlers use `SqliteStorage`, which stores `fsqlite::Connection` (`vendor/beads_rust/src/storage/sqlite.rs:41`, `vendor/beads_rust/src/cli/commands/query.rs:273`). |
| MCP server support inside `br` | MCP tools import `SqliteStorage` and operate over the same storage type (`vendor/beads_rust/src/mcp/tools.rs:20`). |
| `br sync` | Sync import/export is JSONL over `SqliteStorage`, and the `SyncArgs` command surface exposes `--flush-only`, `--import-only`, `--merge`, and `--status` (`vendor/beads_rust/src/sync/mod.rs:1`, `vendor/beads_rust/src/cli/mod.rs:2169`). |
| Completion/config/doctor helpers | Selected helpers open `fsqlite::Connection` directly for snapshot/config/diagnostic reads (`vendor/beads_rust/src/cli/mod.rs:215`, `vendor/beads_rust/src/cli/commands/doctor.rs:14`, `vendor/beads_rust/src/cli/commands/config.rs:20`). |

The `vendor/beads_rust/docs/ARCHITECTURE.md` storage section names `SqliteStorage` as the primary storage implementation and says it uses `fsqlite`, `fsqlite-types`, and `fsqlite-error` (`vendor/beads_rust/docs/ARCHITECTURE.md:201`). Its dependency table also describes `fsqlite` plus shared storage types/errors as the SQLite engine facade (`vendor/beads_rust/docs/ARCHITECTURE.md:765`).

### Code References Added

| Path | What is there |
|---|---|
| `vendor/beads_rust/Cargo.toml:38` | `br` binary entry. |
| `vendor/beads_rust/Cargo.toml:47` | `fsqlite*` database dependency block. |
| `vendor/beads_rust/Cargo.toml:153` | Path patches to sibling `../frankensqlite/crates/*`. |
| `vendor/beads_rust/Cargo.lock:205` | Locked `asupersync` package entry. |
| `vendor/beads_rust/Cargo.lock:1450` | `fsqlite-core` dependency list includes `asupersync`. |
| `vendor/beads_rust/install.sh:1042` | Source installer clones `frankensqlite` next to `beads_rust`. |
| `vendor/beads_rust/src/storage/sqlite.rs:14` | Direct `fsqlite` imports in the `br` storage backend. |
| `vendor/beads_rust/src/storage/sqlite.rs:381` | `SqliteStorage` opens databases with `fsqlite::Connection`. |
| `vendor/beads_rust/src/sync/mod.rs:1` | JSONL import/export module over SQLite storage. |
| `vendor/frankensqlite/Cargo.toml:1` | Frankensqlite Rust workspace root. |
| `vendor/frankensqlite/Cargo.toml:167` | Workspace dependency `asupersync = "0.2.9"`. |
| `vendor/frankensqlite/crates/fsqlite/Cargo.toml:25` | `fsqlite` facade default features include `linux-asupersync-uring`. |
| `vendor/frankensqlite/crates/fsqlite-vfs/src/uring.rs:19` | Linux VFS imports `asupersync::fs::IoUringFile`. |
| `vendor/frankensqlite/crates/fsqlite-core/src/connection.rs:1174` | Runtime context attaches ambient `asupersync::Cx`. |
| `vendor/frankensqlite/crates/fsqlite-wal/src/wal_fec.rs:21` | WAL-FEC imports `asupersync` channel/runtime and RaptorQ APIs. |
| `vendor/asupersync/Cargo.toml:15` | Local `asupersync` package metadata. |
| `vendor/asupersync/src/lib.rs:151` | Root public module surface. |

## Open Questions

This pass did not inspect live runtime state outside the repository, such as the active user-level Claude Code MCP registration or symlink targets under `~/.claude/`. The repository documentation and code paths above describe the checked-out codebase and tracked SAI files as they exist in this workspace.
