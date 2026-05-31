---
date: 2026-04-27
researcher: SilentLynx
repo: silmari-agent-memory
branch: main
commit: 12437122fa9e4025dfec8598e7b734d78b6d75bd
topic: br replacement with apps/silmari_memory_rust
status: complete
related_issues:
  - silmari-agent-memory-88d
  - silmari-agent-memory-7jo
  - silmari-agent-memory-adf
  - silmari-agent-memory-hkg
  - silmari-agent-memory-p6i
  - silmari-agent-memory-rjn
  - silmari-agent-memory-6iz
  - silmari-agent-memory-929
tags:
  - research
  - br
  - beads-rust
  - silmari-memory-rust
  - silmari-mcp
  - sai
---

# Research: Fully Replacing `br` With `apps/silmari_memory_rust`

## Scope

This research answers what the current codebase requires before `br` can be fully replaced by the new `apps/silmari_memory_rust` crate.

The result is descriptive. It documents current contracts, current Rust coverage, and current uncovered behavior. It does not propose a new architecture beyond naming the contract surfaces that a complete replacement must cover.

Inputs:

- Prior research: `thoughts/searchable/shared/research/2026-04-27-silmari-memory-rust-br-sai.md`
- Rust capability artifact: `artifacts/research/2026-04-27-br-replacement-silmari-memory-rust/rust-capability-map.md`
- TypeScript surface artifact: `artifacts/research/2026-04-27-br-replacement-silmari-memory-rust/typescript-br-surface.md`
- MCP/SAI contract artifact: `artifacts/research/2026-04-27-br-replacement-silmari-memory-rust/mcp-sai-contracts.md`
- Historical context artifact: `artifacts/research/2026-04-27-br-replacement-silmari-memory-rust/historical-replacement-context.md`
- Metadata: `silmari-oracle metadata` at `2026-04-27 19:56:45 -04:00`

## Summary

The Rust crate is currently a native Silmari retrieval substrate, not a drop-in replacement for the live `br` issue-store boundary. It can initialize a card-native SQLite schema, import Beads-shaped SQLite data, preserve/parse Silmari labels, materialize typed `ref:*` edges, perform exact keyword recall, compute folgezettel neighborhoods, traverse typed edges, and compose line-of-thought scopes (`apps/silmari_memory_rust/src/schema.rs:22`, `apps/silmari_memory_rust/src/importer.rs:23`, `apps/silmari_memory_rust/src/retrieval.rs:123`, `apps/silmari_memory_rust/src/edges.rs:80`, `apps/silmari_memory_rust/src/folgezettel.rs:221`).

A full `br` replacement must cover the active TypeScript adapter and its callers: two-box workspace initialization, single and batch card creation, update/close/delete/status, label add/remove/set, dependency mirror/list behavior, general list/show/search behavior, timeout/error shapes, WAL/read-after-write handling, and public MCP/SAI tool/resource contracts (`apps/silmari-mcp/src/lib/br-adapter.ts:65`, `apps/silmari-mcp/src/lib/br-adapter.ts:167`, `apps/silmari-mcp/src/lib/br-adapter.ts:223`, `apps/silmari-mcp/src/lib/br-adapter.ts:272`, `apps/silmari-mcp/src/lib/br-adapter.ts:331`, `apps/silmari-mcp/src/lib/br-adapter.ts:420`, `apps/silmari-mcp/src/lib/br-adapter.ts:637`).

The replacement boundary should be treated as the current `apps/silmari-mcp/src/lib/br-adapter.ts` API plus the direct raw `br` script paths. Swapping the binary name alone would not cover the behavior because downstream code depends on adapter-specific null/false/[] degradation, `BrListTimeoutError`, exact-id `brShow`, input-order batch IDs, label-first semantic edges, and `blocks` dependency mirroring (`apps/silmari-mcp/src/lib/br-adapter.ts:50`, `apps/silmari-mcp/src/lib/br-adapter.ts:357`, `apps/silmari-mcp/src/lib/br-adapter.ts:453`, `apps/silmari-mcp/src/lib/card-ops.ts:1014`, `apps/silmari-mcp/src/lib/edges.ts:91`).

## Current Architecture

```text
SAI prompts/hooks/skills
        |
        | MCP tool names: mcp__silmari__zk_*
        | direct hook import: ThinkWithMemory -> silmari-mcp lib
        v
apps/silmari-mcp (TypeScript/Bun)
        |
        | br-adapter.ts shells out to `br`
        | keyword index and proposal queue also use local sqlite/jsonl
        v
Per-box Beads stores
  ~/.silmari or ~/.silmari-memory
  box1-biblio/.beads/beads.db
  box2-ideas/.beads/beads.db
        |
        | optional import-beads
        v
apps/silmari_memory_rust native DB
  cards
  card_labels
  card_edges
  keyword_entries
```

The TypeScript side currently owns the live store path resolution. `SILMARI_DIR` defaults to `~/.silmari`, per-box overrides are `SILMARI_BIBLIO_DIR` and `SILMARI_IDEA_DIR`, and default box directories are `box1-biblio/.beads` and `box2-ideas/.beads` (`apps/silmari-mcp/src/lib/paths.ts:49`, `apps/silmari-mcp/src/lib/paths.ts:67`, `apps/silmari-mcp/src/lib/paths.ts:81`). Initialization runs `br init --prefix bl|zk --db <db>` so biblio IDs are `bl-*` and idea IDs are `zk-*` (`apps/silmari-mcp/src/lib/paths.ts:149`, `apps/silmari-mcp/src/lib/paths.ts:153`, `apps/silmari-mcp/src/lib/paths.ts:154`).

The Rust crate currently accepts explicit `--db` paths and initializes a native schema at that path. It does not currently implement the TypeScript `SILMARI_DIR`/box directory resolver or `.beads` workspace convention (`apps/silmari_memory_rust/src/cli.rs:26`, `apps/silmari_memory_rust/src/schema.rs:22`).

## Active `br` Surface To Replace

`br-adapter.ts` centralizes the current storage boundary. It hardcodes `BR = 'br'`, actor `silmari-mcp`, and three timeout tiers: read 500 ms, write 1000 ms, init 3000 ms (`apps/silmari-mcp/src/lib/br-adapter.ts:42`, `apps/silmari-mcp/src/lib/br-adapter.ts:43`, `apps/silmari-mcp/src/lib/br-adapter.ts:45`).

The active wrappers are:

| Wrapper | Current behavior | Key consumers |
| --- | --- | --- |
| `isBeadsAvailable()` | Runs `br --version`, caches boolean, returns false on any error (`apps/silmari-mcp/src/lib/br-adapter.ts:65`). | `zk_status`, init/register, biblio helpers (`apps/silmari-mcp/src/index.ts:740`, `apps/silmari-mcp/src/lib/init.ts:135`, `apps/silmari-mcp/src/lib/biblio.ts:115`). |
| `brCreate()` | `br create` with title, type, labels, description, priority, status; returns ID or null (`apps/silmari-mcp/src/lib/br-adapter.ts:167`). | `saveCard`, `ensureRegister` (`apps/silmari-mcp/src/lib/card-ops.ts:843`, `apps/silmari-mcp/src/lib/init.ts:166`). |
| `brCreateBatch()` | One `br create -f <markdown>` call; throws on structural failure; returns IDs in input order (`apps/silmari-mcp/src/lib/br-adapter.ts:223`, `apps/silmari-mcp/src/lib/br-adapter.ts:251`). | `saveCardsBatch` (`apps/silmari-mcp/src/lib/card-ops.ts:1012`). |
| `brUpdate()` | Updates title, description, notes, destructive `--set-labels`, and status; returns boolean (`apps/silmari-mcp/src/lib/br-adapter.ts:272`). | `zk_promote`, register/hub JSON body updates (`apps/silmari-mcp/src/index.ts:817`, `apps/silmari-mcp/src/lib/init.ts:328`, `apps/silmari-mcp/src/lib/hubs.ts:261`). |
| `brList()` | Label/status/list filters, all, limit, sort, reverse, descContains; returns rows/[] except throws `BrListTimeoutError` on timeout (`apps/silmari-mcp/src/lib/br-adapter.ts:331`, `apps/silmari-mcp/src/lib/br-adapter.ts:364`). | Dedup, parent resolution, navigation, hubs, structures, registers, status recall (`apps/silmari-mcp/src/lib/card-ops.ts:380`, `apps/silmari-mcp/src/lib/card-ops.ts:659`, `apps/silmari-mcp/src/lib/navigate.ts:224`, `apps/silmari-mcp/src/index.ts:779`). |
| `brSearch()` | Full-text search through `br search`; current hot path is biblio catalog, not idea recall (`apps/silmari-mcp/src/lib/br-adapter.ts:373`). | `biblio.ts` (`apps/silmari-mcp/src/lib/biblio.ts:227`). |
| `brShow()` | Exact-id show; rejects structured errors and fuzzy/prefix results; retries recoverable miss once (`apps/silmari-mcp/src/lib/br-adapter.ts:420`, `apps/silmari-mcp/src/lib/br-adapter.ts:453`, `apps/silmari-mcp/src/lib/br-adapter.ts:482`). | Card resource, promote, navigation, keyword hydration, SAI hook (`apps/silmari-mcp/src/index.ts:857`, `apps/silmari-mcp/src/index.ts:809`, `apps/silmari-mcp/src/lib/navigate.ts:510`, `SAI/hooks/ThinkWithMemory.hook.ts:150`). |
| `brClose()` / `brDelete()` | Lifecycle close or tombstone/delete; return boolean (`apps/silmari-mcp/src/lib/br-adapter.ts:497`, `apps/silmari-mcp/src/lib/br-adapter.ts:519`). | Hub duplicate sweep uses delete (`apps/silmari-mcp/src/lib/hubs.ts:185`). |
| `brDepAdd()` / `brDepList()` | Beads dependency mirror/list for whitelisted dep types (`apps/silmari-mcp/src/lib/br-adapter.ts:546`, `apps/silmari-mcp/src/lib/br-adapter.ts:588`). | Only `blocks` is mirrored from Silmari edges (`apps/silmari-mcp/src/lib/edges.ts:96`). |
| `brLabelAdd()` / `brLabelRemove()` | Add/remove labels without replacing whole set; label add retries once on `ISSUE_NOT_FOUND` (`apps/silmari-mcp/src/lib/br-adapter.ts:637`, `apps/silmari-mcp/src/lib/br-adapter.ts:655`, `apps/silmari-mcp/src/lib/br-adapter.ts:677`). | Edge writes, consolidation labels, backfill scripts (`apps/silmari-mcp/src/lib/edges.ts:92`, `apps/silmari-mcp/src/lib/card-ops.ts:474`, `apps/silmari-mcp/scripts/backfill-edges-from-cosmic.ts:233`). |
| `checkpointBeadsWal()` | Runs `PRAGMA wal_checkpoint(TRUNCATE)` on the box `beads.db`; logs but does not throw (`apps/silmari-mcp/src/lib/br-adapter.ts:694`, `apps/silmari-mcp/src/lib/br-adapter.ts:702`). | Batch post-save read/write visibility (`apps/silmari-mcp/src/lib/card-ops.ts:1020`). |

There is also one raw `br` call outside the adapter: `migrate-from-cosmic.ts` shells out to `br list --db <source> --json --limit 100000 -a` and accepts either an array or `{issues}` output (`artifacts/research/2026-04-27-br-replacement-silmari-memory-rust/typescript-br-surface.md:277`).

## Existing Rust Coverage

The Rust package is `silmari_memory_rust`, edition 2024, described as a native retrieval substrate (`apps/silmari_memory_rust/Cargo.toml:1`, `apps/silmari_memory_rust/Cargo.toml:5`). It exports modules for CLI, edges, folgezettel, importer, keyword index, labels, model, retrieval, schema, and store (`apps/silmari_memory_rust/src/lib.rs:3`).

Current CLI commands:

- `init --db <path> [--json]` (`apps/silmari_memory_rust/src/cli.rs:26`)
- `import-beads --source <path> --db <path> [--box-name <box>] [--json]` (`apps/silmari_memory_rust/src/cli.rs:33`)
- `recall --db <path> --query <term> [--limit-per-term <n>] [--sort-by ...] [--json]` (`apps/silmari_memory_rust/src/cli.rs:44`)
- `neighborhood --db <path> --address <addr> [--json]` (`apps/silmari_memory_rust/src/cli.rs:57`)
- `edges --db <path> --seed <id> [--type <edge>]... [--direction ...] [--max-depth <n>] [--json]` (`apps/silmari_memory_rust/src/cli.rs:66`)
- `line-of-thought --db <path> (--card-id <id>|--address <addr>) [--json]` (`apps/silmari_memory_rust/src/cli.rs:83`)

Native storage currently includes:

- `cards` with `id`, `box`, `kind`, `title`, `description`, `body`, `fz_address`, `trunk`, `source`, `content_hash`, and timestamps (`apps/silmari_memory_rust/src/schema.rs:57`).
- `card_labels` as `(card_id, label)` (`apps/silmari_memory_rust/src/schema.rs:81`).
- `card_edges` as `(source_id, target_id, edge_type)` over the Silmari semantic edge vocabulary (`apps/silmari_memory_rust/src/schema.rs:88`).
- `keyword_entries` as exact terms plus JSON entry points (`apps/silmari_memory_rust/src/schema.rs:98`).

The Rust model covers the Silmari card kinds, two boxes, and 12 edge types with AUTO/REVIEWED tiers (`apps/silmari_memory_rust/src/model.rs:6`, `apps/silmari_memory_rust/src/model.rs:71`, `apps/silmari_memory_rust/src/model.rs:107`, `apps/silmari_memory_rust/src/model.rs:142`, `apps/silmari_memory_rust/src/model.rs:153`).

The importer reads Beads-shaped source tables and loads native rows. It requires `issues`, reads optional `labels`, `dependencies`, and `keyword_entries`, skips deleted/ephemeral/template rows, preserves labels, materializes `ref:*` labels as native edges, and imports only `blocks` Beads dependencies as edges (`apps/silmari_memory_rust/src/importer.rs:41`, `apps/silmari_memory_rust/src/importer.rs:67`, `apps/silmari_memory_rust/src/importer.rs:72`, `apps/silmari_memory_rust/src/importer.rs:97`, `apps/silmari_memory_rust/src/importer.rs:121`, `apps/silmari_memory_rust/src/importer.rs:249`, `apps/silmari_memory_rust/src/importer.rs:274`).

Retrieval covers:

- Exact normalized keyword lookup, no body-text fallback (`apps/silmari_memory_rust/src/retrieval.rs:138`, `apps/silmari_memory_rust/tests/keyword_recall.rs:113`).
- Deduping, sorting, limiting, total matching, and truncation reporting (`apps/silmari_memory_rust/src/retrieval.rs:141`, `apps/silmari_memory_rust/src/retrieval.rs:209`, `apps/silmari_memory_rust/tests/keyword_recall.rs:129`).
- Folgezettel neighborhoods with parents, siblings, and children (`apps/silmari_memory_rust/src/folgezettel.rs:209`, `apps/silmari_memory_rust/src/folgezettel.rs:221`).
- Typed edge traversal with direction, type filters, depth bounds, cycle avoidance, and visited exhaustion errors (`apps/silmari_memory_rust/src/edges.rs:80`, `apps/silmari_memory_rust/tests/edges.rs:64`).
- Line-of-thought buckets: queried, parent, siblings, children, hubs, trunk seeds, all, totalScope (`apps/silmari_memory_rust/src/retrieval.rs:291`, `apps/silmari_memory_rust/src/retrieval.rs:318`).

## Replacement Coverage Matrix

| Current `br` contract | Current Rust coverage | Current uncovered behavior |
| --- | --- | --- |
| Two box stores with `SILMARI_DIR`, per-box overrides, `.beads/beads.db`, and `bl`/`zk` prefixes | Explicit native `init --db` and schema init | No current Rust path resolver, box workspace convention, or prefix/ID generation contract (`apps/silmari-mcp/src/lib/paths.ts:81`, `apps/silmari_memory_rust/src/cli.rs:26`). |
| Single live card creation through `brCreate` | `store::insert_card()` can insert/replace a native card (`apps/silmari_memory_rust/src/store.rs:16`) | No CLI/API create equivalent with ID generation, priority/status/type, title/description split, or MCP integration. |
| Batch create through `br create -f` with input-order IDs | Beads SQLite import exists | No live order-preserving batch create command; importer is source-DB migration, not a request-time write path (`apps/silmari_memory_rust/src/importer.rs:23`, `apps/silmari-mcp/src/lib/card-ops.ts:1012`). |
| Update/status/close/delete | Native insert/replace exists | No status, priority, close/delete/tombstone command surface; `cards` schema lacks status/priority columns (`apps/silmari_memory_rust/src/schema.rs:57`, `apps/silmari-mcp/src/lib/br-adapter.ts:272`). |
| Label add/remove and destructive label set | Label parser/preservation and replace-on-insert | No append-only label mutation API or CLI equivalent to `br label add/remove`; no `ISSUE_NOT_FOUND` retry contract (`apps/silmari_memory_rust/src/store.rs:50`, `apps/silmari-mcp/src/lib/br-adapter.ts:637`). |
| General list by labels/status/all/limit/sort/reverse/descContains | Specific retrieval functions and helpers | No general list command with status/label/sort parity; no `BrListTimeoutError` equivalent for caller-selected read deadlines (`apps/silmari-mcp/src/lib/br-adapter.ts:331`). |
| Exact `show` by ID with null-on-miss and fuzzy-match rejection | `store::get_card()` and `folgezettel::get_card()` | No CLI show command or adapter-level null/fuzzy/error-shape parity (`apps/silmari_memory_rust/src/store.rs:77`, `apps/silmari-mcp/src/lib/br-adapter.ts:420`). |
| Biblio full-text `brSearch` | Exact keyword recall only | No full-text or substring search equivalent; Rust tests assert no text-search fallback for recall (`apps/silmari_memory_rust/tests/keyword_recall.rs:113`). |
| Beads dep add/list for `blocks` mirror | Native `card_edges` and traversal, importer of `blocks` dependencies | No live dependency add/list command preserving Beads issue-graph mirror behavior (`apps/silmari_memory_rust/src/edges.rs:80`, `apps/silmari-mcp/src/lib/br-adapter.ts:546`). |
| Semantic `ref:*` label graph | Same 12 edge vocabulary and native edge rows | Covered for imported/native rows, but live write/proposal/commit integration remains TypeScript-side (`apps/silmari_memory_rust/src/model.rs:107`, `apps/silmari-mcp/src/lib/edges.ts:326`). |
| Keyword recall | Native recall covers normalized exact lookup and truncation | Mostly covered for native DB; current TypeScript `keyword-index.ts` still stores hot-path entries in the MCP SQLite DB and uses `brShow`/`brList` for hydration (`apps/silmari-mcp/src/lib/keyword-index.ts:20`, `apps/silmari-mcp/src/lib/keyword-index.ts:312`). |
| Folgezettel neighborhood | Native neighborhood covered | TypeScript `zk_neighborhood` shape is `{queried,parentChain,siblings,children}` while Rust emits `{queried,parents,siblings,children}`; chain command parity is separate (`apps/silmari-mcp/src/lib/navigate.ts:268`, `apps/silmari_memory_rust/src/folgezettel.rs:12`). |
| Line-of-thought | Native line-of-thought covered | Shape and caller integration must preserve TypeScript buckets and cap behavior used by semantic proposer and SAI (`apps/silmari-mcp/src/lib/line-of-thought.ts:57`, `apps/silmari_memory_rust/src/retrieval.rs:291`). |
| WAL/read-after-write retry/checkpoint behavior | In-process SQLite removes some subprocess causes | Current adapter behavior still includes explicit retry/checkpoint contracts; replacement acceptance must decide equivalent semantics rather than silently dropping the distinction (`apps/silmari-mcp/src/lib/br-adapter.ts:482`, `apps/silmari-mcp/src/lib/br-adapter.ts:655`, `apps/silmari-mcp/src/lib/br-adapter.ts:702`). |

## MCP Contracts To Preserve

The public MCP tools are defined in `apps/silmari-mcp/src/index.ts`. They currently include save, batch save, recall, neighborhood, chain, follow, propose/commit link, semantic proposer, hubs, line of thought, structures, registers, blockers, keyword add, status, reflection, status recall, and promote (`apps/silmari-mcp/src/index.ts:101`).

Public enums are also part of the contract: trunks `1` through `5`, card kinds from `VALID_CARD_KINDS`, edge types from `VALID_EDGE_TYPES`, boxes `biblio|idea`, modes `root|continue|fork`, statuses `open|in_progress|blocked|closed`, and curator `human|agent` (`apps/silmari-mcp/src/index.ts:81`, `apps/silmari-mcp/src/index.ts:86`).

High-risk MCP surfaces for a storage replacement:

- `zk_save_card` returns the current `SaveCardResult` shape `{id, fz, wasReinforced, priorId?, wasSweepDeleted}` (`apps/silmari-mcp/src/lib/card-ops.ts:177`, `apps/silmari-mcp/src/lib/card-ops.ts:875`).
- `zk_save_cards` returns `SaveCardResult[]` in the same order as input cards and is idea-box only (`apps/silmari-mcp/src/lib/card-ops.ts:912`, `apps/silmari-mcp/src/lib/card-ops.ts:1048`).
- `zk_recall` currently delegates to `navigate()` and returns `{query, entryPoints, entryCards, neighborhoods, crossRefs}` with `entryPoints.totalMatching` and `entryPoints.truncated` when present (`apps/silmari-mcp/src/index.ts:573`, `apps/silmari-mcp/src/lib/navigate.ts:589`).
- `zk_recall_by_status` depends on status filtering, optional trunk label filtering, `updated_at` date filtering, and optional neighborhood enrichment (`apps/silmari-mcp/src/index.ts:771`).
- `zk_promote` reads current status, blocks `blocked -> open` without `force`, updates status, and returns `{cardId, fromStatus, toStatus, reason, forced}` (`apps/silmari-mcp/src/index.ts:800`).
- `silmari://card/{id}` infers box by ID prefix and uses exact `brShow` lookup (`apps/silmari-mcp/src/index.ts:852`).

Static resources currently listed are trunks, root and per-trunk registers, keyword index, hubs, and proposals (`apps/silmari-mcp/src/index.ts:440`). Dynamic resource reads also support `silmari://card/{id}`, `silmari://chain/{address}`, and `silmari://register/{slot}` (`apps/silmari-mcp/src/index.ts:852`, `apps/silmari-mcp/src/index.ts:862`, `apps/silmari-mcp/src/index.ts:868`).

## SAI Contracts To Preserve

SAI generally talks to Silmari through MCP tool names, not through shell commands. `/silmari` instructs agents to call `mcp__silmari__zk_*` tools directly and not shell out to `zettel`, `bv`, `br`, or `curl` (`SAI/commands/silmari.md:1`). The same command documents the store path as `~/.silmari-memory/` locally or `~silmari/.silmari-memory/` on ionos01 (`SAI/commands/silmari.md:5`), which differs from the current `paths.ts` default of `~/.silmari` unless `SILMARI_DIR` is set (`apps/silmari-mcp/src/lib/paths.ts:49`).

The active Algorithm treats Silmari as the persistent MCP memory layer and expects three-layer recall, save, link proposal/commit, hub creation, status semantics, and failure-as-nonblocking behavior (`SAI/Algorithm/v3.8.1.md:27`, `SAI/Algorithm/v3.8.1.md:33`, `SAI/Algorithm/v3.8.1.md:46`, `SAI/Algorithm/v3.8.1.md:140`).

The most important direct import exception is `SAI/hooks/ThinkWithMemory.hook.ts`: it dynamically imports `keyword-index.ts`, `br-adapter.ts`, `navigate.ts`, and `labels.ts` from the MCP package, requires `lookupKeyword` and `brShow`, hydrates keyword entry points with `brShow('idea', addr)`, computes neighborhoods, and optionally calls `followEdges` (`SAI/hooks/ThinkWithMemory.hook.ts:117`, `SAI/hooks/ThinkWithMemory.hook.ts:126`, `SAI/hooks/ThinkWithMemory.hook.ts:136`, `SAI/hooks/ThinkWithMemory.hook.ts:150`, `SAI/hooks/ThinkWithMemory.hook.ts:163`, `SAI/hooks/ThinkWithMemory.hook.ts:183`).

Marketing workflow docs still contain deprecated or transitional memory references. The active `SAI/skills/Marketing/SKILL.md` says the legacy `zettel` CLI no longer exists, equivalent functionality is `mcp__silmari__zk_*`, memory unavailability must not block the workflow, and CopyPlatform runs should recall before starting (`SAI/skills/Marketing/SKILL.md:68`).

## Error And Timeout Shapes

These shapes are observable and covered by current tests:

- Normal failures degrade: `brCreate -> null`, `brUpdate/brClose/brDelete/brLabel* -> false`, `brList/brSearch/brDepList -> []`, `brShow -> null` (`apps/silmari-mcp/src/lib/br-adapter.ts:182`, `apps/silmari-mcp/src/lib/br-adapter.ts:286`, `apps/silmari-mcp/src/lib/br-adapter.ts:367`, `apps/silmari-mcp/src/lib/br-adapter.ts:405`, `apps/silmari-mcp/src/lib/br-adapter.ts:492`).
- `brList` timeout is exceptional and throws `BrListTimeoutError` so parent lookup can distinguish timeout from missing parent (`apps/silmari-mcp/src/lib/br-adapter.ts:50`, `apps/silmari-mcp/src/lib/br-adapter.ts:364`, `apps/silmari-mcp/src/lib/card-ops.ts:661`).
- Structured CLI errors must not leak as result rows; list/search/show detect `{error: ...}` (`apps/silmari-mcp/src/lib/br-adapter.ts:357`, `apps/silmari-mcp/src/lib/br-adapter.ts:398`, `apps/silmari-mcp/src/lib/br-adapter.ts:446`).
- `brShow` rejects returned rows whose `id` does not exactly match the requested ID (`apps/silmari-mcp/src/lib/br-adapter.ts:453`).
- `brShow` and `brLabelAdd` retry once after 100 ms for recoverable `ISSUE_NOT_FOUND`/visibility races (`apps/silmari-mcp/src/lib/br-adapter.ts:482`, `apps/silmari-mcp/src/lib/br-adapter.ts:655`).
- Batch create throws on workspace/parse/count failures; it is not a graceful-null wrapper (`apps/silmari-mcp/src/lib/br-adapter.ts:215`, `apps/silmari-mcp/src/lib/card-ops.ts:1014`).

## Data Migration Boundary

The current Rust importer is a one-way Beads-shaped SQLite import into a native DB. It reads the source `issues` table, optional label/dependency/keyword tables, and writes native card/label/edge/keyword rows (`apps/silmari_memory_rust/src/importer.rs:23`, `apps/silmari_memory_rust/src/importer.rs:40`, `apps/silmari_memory_rust/src/importer.rs:43`, `apps/silmari_memory_rust/src/importer.rs:93`).

The current live TypeScript store is still the per-box Beads DBs plus a separate MCP SQLite DB for `keyword_entries` at `${SILMARI_DIR}/silmari.db` (`apps/silmari-mcp/src/lib/paths.ts:67`, `apps/silmari-mcp/src/lib/keyword-index.ts:20`, `apps/silmari-mcp/src/lib/silmari-db.ts` referenced by `apps/silmari-mcp/src/lib/keyword-index.ts:42`).

The inspected code and artifacts do not document a live dual-write, delta-import, or authoritative-store cutover protocol. That is the current boundary between "Rust can import" and "Rust has replaced `br`."

## Related Issues And Historical Findings

- `silmari-agent-memory-7jo`: Rust TDD plan review found critical gaps around keyword normalization parity, 12-edge vocabulary and review tiers, `LineOfThought.trunk_seeds`, label-derived fz/trunk storage, and Beads importer field disposition.
- `silmari-agent-memory-hkg`: `brShow` once returned structured error payloads as truthy cards; current wrapper rejects `.error` and exact-ID mismatches.
- `silmari-agent-memory-rjn`: `brList`/`brSearch` had the same structured-error shape as `brShow`.
- `silmari-agent-memory-p6i`: `br label add` produced `ISSUE_NOT_FOUND` on just-saved IDs; current wrapper retries once after 100 ms.
- `silmari-agent-memory-6iz`: `brShow` needed WAL-race retry for `silmari://card/<id>` and other call sites.
- `silmari-agent-memory-929`: `resolveExplicitTarget` needed retry-then-hard-fail behavior for parent lookup, rather than degrading missing parents into root saves.
- `silmari-agent-memory-adf`: cumulative `spawnSync br ETIMEDOUT` remains the active operational reason to replace the subprocess-heavy path under cascade load.

## Tests And Verification Evidence

Observed Rust test coverage includes schema init, label parsing, import idempotence, keyword recall, neighborhood, edge traversal, line-of-thought, and CLI JSON contracts (`apps/silmari_memory_rust/tests/schema_init.rs:4`, `apps/silmari_memory_rust/tests/labels.rs:8`, `apps/silmari_memory_rust/tests/import_beads.rs:7`, `apps/silmari_memory_rust/tests/keyword_recall.rs:68`, `apps/silmari_memory_rust/tests/neighborhood.rs:46`, `apps/silmari_memory_rust/tests/edges.rs:64`, `apps/silmari_memory_rust/tests/line_of_thought.rs:65`, `apps/silmari_memory_rust/tests/cli_contract.rs:27`).

The Rust worker for this research ran `cargo test --no-run` in `apps/silmari_memory_rust`; test binaries built successfully. This research pass did not run the full suite because it changed documentation only.

Observed MCP adapter test coverage includes structured error rejection, exact `brShow`, fuzzy/prefix rejection, `brLabelAdd` retry/failure behavior, timeout vs empty list distinction, parent timeout messaging, batch ordered IDs, and duplicate-content recurrence behavior (`apps/silmari-mcp/tests/br-adapter.test.ts:4`, `apps/silmari-mcp/tests/br-adapter.test.ts:115`, `apps/silmari-mcp/tests/br-adapter.test.ts:245`, `apps/silmari-mcp/tests/br-adapter.test.ts:281`, `apps/silmari-mcp/tests/zk-save-card-fromaddress.test.ts:286`, `apps/silmari-mcp/tests/zk-save-cards-batch.test.ts:109`, `apps/silmari-mcp/tests/savecard-concurrency.test.ts:4`).

## Current Full-Replacement Checklist

A complete `br` replacement, as defined by the current codebase, covers these contracts:

1. Preserve or replace the `br-adapter.ts` exported API and test seams.
2. Preserve two-box storage routing, environment overrides, and ID prefix semantics.
3. Preserve live write behavior: create, batch create, update, status, delete/close, label add/remove, and `blocks` dependency mirror.
4. Preserve read behavior: exact show, general label/status list, biblio search, status recall, dynamic card resources, and scripts.
5. Preserve adapter error shapes: null/false/[], `BrListTimeoutError`, structured-error filtering, exact-ID rejection, retry semantics, and batch throw semantics.
6. Preserve label namespace and graph semantics: `content_hash:*`, `fz:*`, `kind:*`, `box:*`, `trunk:*`, `scope:*`, `source:*`, `ref:*`, `keyword:*`, `upsert:*`.
7. Preserve MCP tool/resource schemas and payload shapes for `zk_*` tools and `silmari://*` resources.
8. Preserve SAI expectations, including MCP tool names and the direct `ThinkWithMemory` import path or an equivalent hook contract.
9. Define the live store cutover path from Beads DBs plus MCP SQLite keyword state to the Rust native DB.
10. Re-run adapter, MCP integration, Rust, and SAI hook tests against the replacement path, plus an operational cascade workload that covers the `adf` timeout failure mode.

## Open Questions From Current Sources

- The current Rust crate does not document whether it is intended to become the authoritative live write store or only a retrieval/import substrate.
- The inspected sources do not define how the current `~/.silmari-memory` deployment path maps to the `paths.ts` default `~/.silmari` without external environment configuration.
- The Rust crate does not yet expose a TypeScript binding, HTTP/MCP boundary, or CLI surface that mirrors the live `br-adapter.ts` write API.
- The current importer can load a Beads snapshot, but there is no current source for incremental sync, dual-write, rollback, or cutover acceptance.
- The viewer/export path still expects Beads-shaped graph/export behavior in adjacent docs; that surface was not fully traced in this pass beyond the documented label-to-dependency synthesis notes in `README.md:208`.
