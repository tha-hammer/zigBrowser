---
date: 2026-04-30T20:58:42-04:00
researcher: GreenBridge
git_commit: e52091d9f2886484c0daa4241a0ab46edbbe89b6
branch: main
repository: silmari-agent-memory
topic: "Contracts and interfaces for silmari MCP server migration to Silmari Store away from br"
tags:
  - research
  - codebase
  - silmari-mcp
  - silmari-store
  - br-adapter
  - native-primary
  - contracts
status: review-amended
last_updated: 2026-05-01
last_updated_by: Codex
related_beads:
  - silmari-agent-memory-4d8.14
  - silmari-agent-memory-4d8.14.1
  - silmari-agent-memory-4d8.15
  - silmari-agent-memory-e8u
  - silmari-agent-memory-xom
  - silmari-agent-memory-792
---

# Silmari MCP Contracts For Silmari Store Migration

## Research Question

What contracts and interfaces does the `silmari` MCP server currently expose or depend on while migrating storage to Silmari Store and away from `br`?

## Metadata

- Repository: `silmari-agent-memory`
- Branch: `main`
- Commit: `e52091d9f2886484c0daa4241a0ab46edbbe89b6`
- Commit state: `HEAD` and `origin/main` were even at research time (`git rev-list --left-right --count HEAD...origin/main` returned `0 0`)
- GitHub permalink base: `https://github.com/tha-hammer/silmari-agent-memory/tree/e52091d9f2886484c0daa4241a0ab46edbbe89b6`
- Local timestamp: `2026-04-30 20:58:42 -04:00`

## Summary

The public MCP contract is still owned by `apps/silmari-mcp/src/index.ts`. MCP clients see tool schemas, resource URIs, and MCP result envelopes there. The storage migration boundary is the TypeScript compatibility facade in `apps/silmari-mcp/src/lib/br-adapter.ts`, not a direct rewrite of every MCP tool. Production callers keep importing facade functions such as `brCreate`, `brList`, `brShow`, `brUpdate`, `brEdgeAdd`, and `brCommitReviewedEdge`; runtime mode resolution decides whether those calls go to legacy `br`, shadow comparison, or the native Silmari Store CLI.

The native process contract is `silmari-store` with a temporary compatibility binary named `silmari_memory_rust`. The TypeScript adapter shells out to this binary with `--db <nativeDbPath> --json`, parses a stable JSON envelope, and maps native errors back to legacy-compatible MCP return shapes. The native schema is card-native: `cards`, `card_labels`, `card_edges`, `keyword_entries`, `trunks`, `folgezettel_cursors`, `edge_proposals`, `card_events`, and `card_notes`.

Operational contracts now include runtime modes, binary resolution, native status payloads, shadow reports, import parity reports, no-legacy runtime gates, canary checklists, rollback config, and write-pause tokens. Production flip evidence is tracked by `silmari-agent-memory-4d8.14`; the follow-up import-parity blocker `silmari-agent-memory-4d8.14.1` captured the legacy root-register `fz:0_0` row issue and is now closed with regenerated evidence. The direct KC Baker cascade import writer migration was completed in `silmari-agent-memory-4d8.15` at this commit.

## Public MCP Server Contract

The MCP server creates a server named `silmari-mcp` and version `0.1.0` with tool and resource capabilities in `apps/silmari-mcp/src/index.ts:1147`. It registers handlers for tool listing, tool calls, resource listing, and resource reads in `apps/silmari-mcp/src/index.ts:1153`.

MCP tool successes are returned as a text content item containing `JSON.stringify(payload)`, and tool failures are returned with `isError: true` and text content containing the error message (`apps/silmari-mcp/src/index.ts:598`, `apps/silmari-mcp/src/index.ts:602`). Resource payloads use raw JSON strings through `jsonText()` (`apps/silmari-mcp/src/index.ts:606`).

The exported tool list starts at `apps/silmari-mcp/src/index.ts:135`. Current major MCP tool groups are:

| Group | Public tools | Dispatch/storage entry points |
| --- | --- | --- |
| Card creation | `zk_save_card`, `zk_save_cards`, `sai_submit_thought` | `saveCard()` and `saveCardsBatch()` in `card-ops.ts`; dispatch at `apps/silmari-mcp/src/index.ts:672`, `apps/silmari-mcp/src/index.ts:698`, and `apps/silmari-mcp/src/index.ts:767` |
| Biblio | `zk_biblio_search`, `zk_biblio_link_source`, `zk_biblio_sources_for_idea`, `zk_biblio_ideas_for_source` | `searchBiblio()` and `markIdeaDerivesFromBiblio()`; dispatch at `apps/silmari-mcp/src/index.ts:719` and `apps/silmari-mcp/src/index.ts:726` |
| Routing | `sai_route_thought`, `sai_submit_thought` | `routeThought()`, route audit, and optional `saveCard()` persistence; dispatch at `apps/silmari-mcp/src/index.ts:748` and `apps/silmari-mcp/src/index.ts:767` |
| Recall and traversal | `zk_recall`, `zk_neighborhood`, `zk_chain`, `zk_follow`, `zk_line_of_thought` | `navigate()`, `neighborhood()`, `chain()`, `followEdges()`, `nativeLineOfThoughtCompat()`; dispatch at `apps/silmari-mcp/src/index.ts:829`, `apps/silmari-mcp/src/index.ts:846`, `apps/silmari-mcp/src/index.ts:852`, `apps/silmari-mcp/src/index.ts:858`, and `apps/silmari-mcp/src/index.ts:951` |
| Link proposals and commits | `zk_propose_link`, `zk_propose_links_semantic`, `zk_commit_link` | proposal queue, semantic proposer, and `commitLink()`; dispatch at `apps/silmari-mcp/src/index.ts:873`, `apps/silmari-mcp/src/index.ts:890`, and `apps/silmari-mcp/src/index.ts:918` |
| Hubs, registers, structures, keywords | `zk_hub_create`, `zk_hub_add_card`, `zk_hub_members`, `zk_structure_create`, `zk_register_read`, `zk_keyword_add` | local hub/register/keyword helpers plus facade flushes where needed; dispatch at `apps/silmari-mcp/src/index.ts:926`, `apps/silmari-mcp/src/index.ts:936`, `apps/silmari-mcp/src/index.ts:945`, `apps/silmari-mcp/src/index.ts:957`, `apps/silmari-mcp/src/index.ts:967`, and `apps/silmari-mcp/src/index.ts:989` |
| Status and lifecycle | `zk_status`, `zk_recall_by_status`, `zk_promote`, `zk_block`, `zk_reflect` | facade reads/writes, status payload builder, and direct edge writes; dispatch at `apps/silmari-mcp/src/index.ts:998`, `apps/silmari-mcp/src/index.ts:1036`, `apps/silmari-mcp/src/index.ts:1065`, `apps/silmari-mcp/src/index.ts:975`, and `apps/silmari-mcp/src/index.ts:1021` |

Public contract caveat: the `zk_save_cards` tool description still leaks legacy `br` wording in MCP `tools/list`. It says batch saves create cards with per-card `br create` writes and intentionally do not use `br create -f` (`apps/silmari-mcp/src/index.ts:157`, `apps/silmari-mcp/src/index.ts:159`). That text is externally visible and should be cleaned up under the Silmari Store naming/docs work; native batch create support alone does not remove this public contract leak.

The static resource list is defined at `apps/silmari-mcp/src/index.ts:583` and includes trunks, registers, keyword index, hubs, and pending proposals. Dynamic resources include:

- `silmari://card/<id>`, which infers biblio vs idea by id prefix and reads through `brShow()` (`apps/silmari-mcp/src/index.ts:1118`)
- `silmari://chain/<address>` through `chain()` (`apps/silmari-mcp/src/index.ts:1128`)
- `silmari://register/<slot>` through `readRegister()` (`apps/silmari-mcp/src/index.ts:1134`)

## TypeScript Storage Facade Contract

`apps/silmari-mcp/src/lib/br-adapter.ts` is the public compatibility facade for storage. Its file header states that production callers keep importing this module while runtime mode selection chooses between legacy Beads subprocess/SQLite code and native Rust CLI calls (`apps/silmari-mcp/src/lib/br-adapter.ts:1`).

Read operations resolve mode through `resolveModeForRead()`, and write operations resolve mode through `resolveModeForWrite()` (`apps/silmari-mcp/src/lib/br-adapter.ts:97`, `apps/silmari-mcp/src/lib/br-adapter.ts:106`). Write mode resolution first checks write-pause tokens and then checks mode-level write permissions (`apps/silmari-mcp/src/lib/br-adapter.ts:108`).

The facade has three main runtime routes:

- `native-primary`: native DB is authoritative and facade functions call `NativeCliAdapter` (`apps/silmari-mcp/src/lib/br-adapter.ts:121`)
- `shadow-read`: legacy-visible result is returned while native read parity is recorded (`apps/silmari-mcp/src/lib/br-adapter.ts:125`, `apps/silmari-mcp/src/lib/br-adapter.ts:413`)
- `shadow-write`: legacy write remains visible while native write result is recorded for comparison (`apps/silmari-mcp/src/lib/br-adapter.ts:129`, `apps/silmari-mcp/src/lib/br-adapter.ts:281`)

Native-primary facade coverage at this commit includes:

| Facade operation | Native-primary route |
| --- | --- |
| Label lookup | `findCardsByLabelCompat()` calls native `listCompat()` with labels (`apps/silmari-mcp/src/lib/br-adapter.ts:208`) |
| Create | `brCreateResult()` calls native `createResultCompat()` (`apps/silmari-mcp/src/lib/br-adapter.ts:269`) |
| Batch create | `brCreateBatchResult()` calls native `createBatchCompat()` (`apps/silmari-mcp/src/lib/br-adapter.ts:322`) |
| Update/promote | `brUpdate()` calls native `updateCompat()` (`apps/silmari-mcp/src/lib/br-adapter.ts:353`) |
| List/search/show | `brList()`, `brSearch()`, and `brShow()` call native read adapters (`apps/silmari-mcp/src/lib/br-adapter.ts:369`, `apps/silmari-mcp/src/lib/br-adapter.ts:392`, `apps/silmari-mcp/src/lib/br-adapter.ts:408`) |
| Close/delete | `brClose()` and `brDelete()` call native lifecycle adapters (`apps/silmari-mcp/src/lib/br-adapter.ts:433`, `apps/silmari-mcp/src/lib/br-adapter.ts:440`) |
| Flush/import/recover | `brSync()` and `brSyncImport()` map to native checkpoint in native-primary mode (`apps/silmari-mcp/src/lib/br-adapter.ts:447`, `apps/silmari-mcp/src/lib/br-adapter.ts:469`) |
| Auto edges | `brDepAdd()` and `brEdgeAdd()` call native `edgeAddCompat()` (`apps/silmari-mcp/src/lib/br-adapter.ts:544`, `apps/silmari-mcp/src/lib/br-adapter.ts:564`) |
| Reviewed edges | `brCommitReviewedEdge()` calls native `edgeCommitCompat()` (`apps/silmari-mcp/src/lib/br-adapter.ts:594`) |
| Edge reads | `brDepList()` calls native `edgeListCompat()` (`apps/silmari-mcp/src/lib/br-adapter.ts:613`) |
| Ref labels | `brLabelAdd()` turns `ref:<edge>:<target>` labels into native edge writes and sends other labels through `labelAddCompat()` (`apps/silmari-mcp/src/lib/br-adapter.ts:638`) |
| Label removal | `brLabelRemove()` calls native `labelRemoveCompat()` (`apps/silmari-mcp/src/lib/br-adapter.ts:669`) |

Legacy compatibility is still implemented behind `LegacyBrAdapter`. Its base subprocess flags include `--json`, actor, no auto flush, and the Beads DB path (`apps/silmari-mcp/src/lib/legacy-br-adapter.ts:140`). Legacy list/search/show continue to shell out to `br` (`apps/silmari-mcp/src/lib/legacy-br-adapter.ts:276`, `apps/silmari-mcp/src/lib/legacy-br-adapter.ts:318`, `apps/silmari-mcp/src/lib/legacy-br-adapter.ts:341`).

## Runtime Mode And Launch Contract

Runtime mode names are defined in `apps/silmari-mcp/src/lib/native-mode.ts:6`:

- `legacy-br`
- `import-only`
- `shadow-read`
- `shadow-write`
- `native-primary`
- `legacy-read-only`

Mode resolution precedence is test override, `SILMARI_MEMORY_MODE`, config file, then default `legacy-br` (`apps/silmari-mcp/src/lib/native-mode.ts:95`). The config path comes from `SILMARI_MEMORY_CONFIG` or `${SILMARI_DIR:-~/.silmari}/config/native-memory-mode.json` (`apps/silmari-mcp/src/lib/native-mode.ts:126`, `apps/silmari-mcp/src/lib/native-mode.ts:153`).

Native-related modes require `nativeDbPath`: `import-only`, `shadow-read`, `shadow-write`, `native-primary`, and `legacy-read-only` (`apps/silmari-mcp/src/lib/native-mode.ts:69`, `apps/silmari-mcp/src/lib/native-mode.ts:212`). Shadow modes require both `shadowReportDir` and `reconciliationReportDir` (`apps/silmari-mcp/src/lib/native-mode.ts:215`). Writes are blocked in `import-only`, `shadow-read`, and `legacy-read-only` (`apps/silmari-mcp/src/lib/native-mode.ts:77`, `apps/silmari-mcp/src/lib/native-mode.ts:137`).

Rollback config is embedded in native mode config with schema version `silmari-store.rollback-config.v1` and includes `runId`, selected legacy snapshot, rollback manifest path, write-pause token path, replay policy, operator, and creation timestamp (`apps/silmari-mcp/src/lib/native-mode.ts:29`). The rollback CLI writes that config and a `silmari-store.write-pause.v1` token (`scripts/silmari-store/rollback.ts:43`, `scripts/silmari-store/rollback.ts:68`).

The write-pause contract is implemented in `apps/silmari-mcp/src/lib/native-write-pause.ts`. A pause token has schema version `silmari-store.write-pause.v1`; when present, `assertWritesNotPaused()` throws `WRITE_PAUSED` before storage writes run (`apps/silmari-mcp/src/lib/native-write-pause.ts:4`, `apps/silmari-mcp/src/lib/native-write-pause.ts:68`).

`zk_status` resolves mode, counts cards through facade reads, reads local hub/structure/keyword counts, and returns `buildSilmariStoreStatusPayload()` (`apps/silmari-mcp/src/index.ts:998`). The status payload schema includes store identity, mode, config source/path, native DB path, binary status, schema status, rollback metadata, write-pause state, card counts, diagnostics, legacy availability, hub/structure/keyword counts, and app version (`apps/silmari-mcp/src/lib/native-status.ts:42`, `apps/silmari-mcp/src/lib/native-status.ts:70`). The current `store.schema` value is not a direct `silmari-store schema-check` result: `zk_status` passes `schemaStatusFromFacadeRead(resolution, true)` (`apps/silmari-mcp/src/index.ts:1011`), and that helper returns `version: null` with `compatible` set from whether the facade read succeeded when a `nativeDbPath` exists (`apps/silmari-mcp/src/lib/native-status.ts:171`, `apps/silmari-mcp/src/lib/native-status.ts:182`). Planning should treat this as a facade-read-derived compatibility signal, not proof of native schema health. Launch diagnostics include ignored `SILMARI_STORE`, missing `SILMARI_DIR`, and missing `SILMARI_MEMORY_CONFIG` notices for non-legacy launches (`apps/silmari-mcp/src/lib/native-status.ts:111`).

## Native Adapter And CLI Envelope Contract

`NativeCliAdapter` is the TypeScript process adapter for Silmari Store (`apps/silmari-mcp/src/lib/native-adapter.ts:281`). It resolves the binary in this order:

1. Explicit adapter option
2. `SILMARI_STORE_BINARY`
3. Deprecated `SILMARI_MEMORY_RUST_BINARY`
4. `silmari-store` on `PATH`
5. Deprecated `silmari_memory_rust` on `PATH`

This order is implemented in `resolveNativeStoreBinary()` (`apps/silmari-mcp/src/lib/native-adapter.ts:661`). If both env vars are set to different values, resolution returns `CONFIG_INVALID`; if no binary can be found, it returns `BINARY_NOT_FOUND` (`apps/silmari-mcp/src/lib/native-adapter.ts:671`, `apps/silmari-mcp/src/lib/native-adapter.ts:691`).

Every native command invocation appends `--db <nativeDbPath> --json` (`apps/silmari-mcp/src/lib/native-adapter.ts:528`). The adapter parses a `NativeEnvelope` with either `{ ok: true, result, meta?, diagnostics? }` or `{ ok: false, error, meta?, diagnostics? }` (`apps/silmari-mcp/src/lib/native-adapter.ts:70`, `apps/silmari-mcp/src/lib/native-adapter.ts:602`).

Known native error codes include `BINARY_NOT_FOUND`, `CONFIG_INVALID`, `UNSUPPORTED_OPERATION`, `CARD_NOT_FOUND`, `QUERY_TIMEOUT`, `VALIDATION_ERROR`, `SCHEMA_INCOMPATIBLE`, `DB_NOT_FOUND`, `EDGE_NOT_FOUND`, `CONFLICT`, `WRITE_PAUSED`, `IMPORT_PARITY_FAILED`, `SHADOW_MISMATCH`, `CANARY_EVIDENCE_MISSING`, `IO_ERROR`, `INTERNAL_ERROR`, and `CLI_PARSE` (`apps/silmari-mcp/src/lib/native-adapter.ts:6`).

Error mapping preserves legacy facade return semantics: `QUERY_TIMEOUT` throws a timeout error, list/search/edge-list operations return `[]`, boolean write-like operations return `false`, and other read operations return `null` (`apps/silmari-mcp/src/lib/native-adapter.ts:638`).

## Rust Silmari Store CLI And Data Model Contract

The canonical Rust CLI name is `silmari-store` (`apps/silmari_memory_rust/src/cli.rs:22`), with `silmari_memory_rust` kept as a compatibility binary (`apps/silmari_memory_rust/src/cli.rs:23`). The CLI result schema version is `silmari-store.cli-result.v1` (`apps/silmari_memory_rust/src/cli.rs:21`).

Current CLI commands include health/schema/init/import/export/read/write/traversal surfaces such as `health`, `schema-check`, `init`, `import-beads`, `create-snapshot`, `import-snapshot`, `create-card`, `create-cards`, `show-card`, `update-card`, `close-card`, `delete-card`, `label-remove`, `list-cards`, `search-biblio`, `label-add`, `edge-add`, `edge-commit`, `edge-reconcile-proposals`, `checkpoint`, `export-viewer`, `recall`, `neighborhood`, `edges`, and `line-of-thought` (`apps/silmari_memory_rust/src/cli.rs:28`, `apps/silmari_memory_rust/src/cli.rs:258`, `apps/silmari_memory_rust/src/cli.rs:284`, `apps/silmari_memory_rust/src/cli.rs:302`, `apps/silmari_memory_rust/src/cli.rs:321`).

The Rust CLI emits the same JSON envelope consumed by the TypeScript adapter. Parse errors under `--json` return `CLI_PARSE` (`apps/silmari_memory_rust/src/cli.rs:522`, `apps/silmari_memory_rust/src/cli.rs:536`). Error-to-code mapping includes `DB_NOT_FOUND`, `CARD_NOT_FOUND`, `VALIDATION_ERROR`, and `CLI_PARSE` among others (`apps/silmari_memory_rust/src/cli.rs:1188`).

The supported native schema version is `2` (`apps/silmari_memory_rust/src/schema.rs:8`). Core native tables are created in `apps/silmari_memory_rust/src/schema.rs:135` and `apps/silmari_memory_rust/src/schema.rs:213`:

- `schema_versions`
- `cards`
- `card_labels`
- `card_edges`
- `keyword_entries`
- `trunks`
- `folgezettel_cursors`
- `edge_proposals`
- `card_events`
- `card_notes`

The `cards` table constrains card box, kind, status, priority, trunk, and short content hash values (`apps/silmari_memory_rust/src/schema.rs:141`). `card_edges` is a first-class native table with indexes for source, target, and type queries (`apps/silmari_memory_rust/src/schema.rs:176`, `apps/silmari_memory_rust/src/schema.rs:201`, `apps/silmari_memory_rust/src/schema.rs:266`).

The native label parser recognizes Silmari compatibility labels such as `fz:`, `kind:`, `box:`, `trunk:`, `source:`, `content_hash:`, `keyword:`, and `ref:<edge>:<target>` (`apps/silmari_memory_rust/src/labels.rs:7`). Edge vocabulary and authorities are defined in the Rust model; `body-hash-recurrence` is one accepted edge authority for reviewed recurrence edges (`apps/silmari_memory_rust/src/model.rs:231`).

## MCP Write Funnels

The primary card write funnels are:

- `saveCard()` in `apps/silmari-mcp/src/lib/card-ops.ts:783`
- `saveCardsBatch()` in `apps/silmari-mcp/src/lib/card-ops.ts:958`
- `addEdge()` in `apps/silmari-mcp/src/lib/edges.ts:76`
- `commitLink()` proposal commit path in `apps/silmari-mcp/src/lib/edges.ts:320`
- `markIdeaDerivesFromBiblio()` in `apps/silmari-mcp/src/lib/biblio.ts:145`

`saveCard()` and `saveCardsBatch()` are MCP-facing write surfaces because `zk_save_card`, `zk_save_cards`, and `sai_submit_thought` dispatch to them. Their durable card creation goes through the facade, so native-primary storage selection is inherited from `br-adapter.ts`.

`addEdge()` is the direct AUTO edge helper for MCP-level structural edge writes. In native-primary mode, the facade routes auto edge writes through native `edge-add`, and compatibility `ref:*` labels are projections rather than the native source of truth. Reviewed edge commits use `brCommitReviewedEdge()` in native-primary mode.

Keyword index reads still use `readKeywordIndex()` from the TypeScript-side keyword index module (`apps/silmari-mcp/src/lib/keyword-index.ts:228`). Keyword writes also remain TypeScript-side: `zk_keyword_add` dispatches directly to `addKeywordEntry()` (`apps/silmari-mcp/src/index.ts:989`, `apps/silmari-mcp/src/index.ts:994`), and `addKeywordEntry()` writes the local `keyword_entries` SQLite table (`apps/silmari-mcp/src/lib/keyword-index.ts:359`, `apps/silmari-mcp/src/lib/keyword-index.ts:393`, `apps/silmari-mcp/src/lib/keyword-index.ts:424`). That table lives in `${SILMARI_DIR}/silmari.db`, as defined by `getSilmariDbPath()` (`apps/silmari-mcp/src/lib/silmari-db.ts:41`, `apps/silmari-mcp/src/lib/silmari-db.ts:45`). This is a separate Silmari MCP data surface from the card-native storage facade; although native Silmari Store also has a `keyword_entries` table, MCP keyword writes are not currently routed through `NativeCliAdapter` or the native DB selected by `nativeDbPath`.

## Viewer, Import, And Evidence Contracts

The Rust viewer exporter has two modes: compatibility export and native export. Compatibility export writes issue-shaped tables such as `issues`, `dependencies`, `comments`, `issue_metrics`, `card_edges`, `export_meta`, `issue_overview_mv`, and `issues_fts` (`apps/silmari_memory_rust/src/export.rs:109`, `apps/silmari_memory_rust/src/export.rs:244`). Native export writes card-native viewer tables such as `viewer_cards`, `viewer_labels`, `viewer_edges`, `viewer_keywords`, `viewer_trunks`, and `viewer_export_meta` (`apps/silmari_memory_rust/src/export.rs:311`, `apps/silmari_memory_rust/src/export.rs:333`).

The replacement specs describe the adapter contract as a narrow TypeScript compatibility facade over Rust store commands while preserving MCP behavior (`artifacts/specs/2026-04-28-beads-rust-replacement/03-store-api-and-adapter.md:9`). The viewer/consumer spec states that SAI hooks depend on stable MCP tool behavior rather than direct DB access and that MCP owns payload shaping during cutover (`artifacts/specs/2026-04-28-beads-rust-replacement/05-viewer-export-and-consumers.md:191`).

Migration and production flip evidence is tracked through:

- import parity contracts and reports (`apps/silmari_memory_rust/src/importer.rs:651`, `apps/silmari_memory_rust/src/importer.rs:685`)
- snapshot rollback manifests (`apps/silmari_memory_rust/src/importer.rs:731`)
- shadow reports from `native-shadow.ts`
- canary checklist scripts under `scripts/silmari-store`
- no-legacy runtime gate under `scripts/silmari-store/no-legacy-runtime-gate.ts`
- rollback/write-pause scripts and runtime status

`silmari-agent-memory-4d8.14` remains the bead tracking production flip evidence: real legacy snapshot import parity archive, mismatch beads if needed, representative shadow-read/shadow-write archives, native viewer load, canary bundle, focused command transcript, and operator docs cleanup.

## Direct KC Baker Cascade Import Contract

At commit `e52091d9f2886484c0daa4241a0ab46edbbe89b6`, `silmari-agent-memory-4d8.15` is closed and the KC Baker/YouTube deterministic cascade import writer uses Silmari Store directly.

The writer imports `NativeCliAdapter` (`scripts/kc-baker-pipeline-v2/ingest/cascade-import-writer.ts:26`). Its default timeout is `CASCADE_IMPORT_STORE_TIMEOUT_MS`, and it resolves storage from `SILMARI_NATIVE_DB` first, then native mode config `nativeDbPath` (`scripts/kc-baker-pipeline-v2/ingest/cascade-import-writer.ts:132`, `scripts/kc-baker-pipeline-v2/ingest/cascade-import-writer.ts:139`). The fatal prefix is `SILMARI_STORE_WRITE_FATAL` (`scripts/kc-baker-pipeline-v2/ingest/cascade-import-writer.ts:101`).

`createCascadeImportDeps()` now maps import operations to native adapter calls (`scripts/kc-baker-pipeline-v2/ingest/cascade-import-writer.ts:259`):

- recover/init: `adapter.init()`
- create: `adapter.createResultCompat()`
- structural edges: `adapter.edgeAddCompat()`
- flush/durability: `adapter.checkpointCompat()`
- resume lookup: native `listCompat()` by `source:` and `fz:` labels

The import loop writes preaddressed rows, then structural `branches`/`follows` edges, then checkpoints, then commits the local cascade cursor (`scripts/kc-baker-pipeline-v2/ingest/cascade-import-writer.ts:443`, `scripts/kc-baker-pipeline-v2/ingest/cascade-import-writer.ts:475`, `scripts/kc-baker-pipeline-v2/ingest/cascade-import-writer.ts:500`, `scripts/kc-baker-pipeline-v2/ingest/cascade-import-writer.ts:506`).

The KC Baker docs now name `SILMARI_NATIVE_DB`, `SILMARI_STORE_BINARY`, and `CASCADE_IMPORT_STORE_TIMEOUT_MS` as deterministic import env vars (`scripts/kc-baker-pipeline-v2/ingest/README.md:35`, `scripts/kc-baker-pipeline-v2/ingest/README.md:62`). Focused tests assert the direct writer imports `NativeCliAdapter` and does not contain `brCreate`, `brList`, `brFlushOrThrow`, or `brRecoverFromJsonlOrThrow` (`scripts/kc-baker-pipeline-v2/tests/cascade-import-writer.test.ts:631`).

## Historical And Spec Context

The architecture spec describes the target as MCP/SAI clients calling `apps/silmari-mcp`, the TypeScript compatibility facade preserving MCP behavior, and Rust owning durable card storage, edge traversal, retrieval, and viewer export (`artifacts/specs/2026-04-28-beads-rust-replacement/01-system-architecture.md:72`). It names `native-primary` as the mode where native DB is authoritative for both reads and writes (`artifacts/specs/2026-04-28-beads-rust-replacement/01-system-architecture.md:104`).

The replacement README states that the migration must preserve contracts routed through `apps/silmari-mcp/src/lib/br-adapter.ts` while making cards, folgezettel addresses, typed edges, keyword recall, and viewer export first-class data-model concepts (`artifacts/specs/2026-04-28-beads-rust-replacement/README.md:12`). It lists stable compatibility contracts for adapter return semantics, labels, bodies, blocks, all 12 edge types, viewer graph export, and MCP/SAI payloads (`artifacts/specs/2026-04-28-beads-rust-replacement/README.md:89`).

The 4d8 plan reframes the remaining migration as making Silmari Store fully online as the production storage application for Silmari Memory. Its desired state includes native-primary MCP mode, canonical `silmari-store` naming, native behavior for adapter functions, edge writes in `card_edges`, biblio workflows, archived import/shadow evidence, rollback, viewer native export, and no production dependency on `br` in native-primary paths (`thoughts/searchable/shared/plans/2026-04-30-silmari-agent-memory-4d8-tdd-silmari-store-full-online.md:47`, `thoughts/searchable/shared/plans/2026-04-30-silmari-agent-memory-4d8-tdd-silmari-store-full-online.md:128`).

The edge-card research explains the source-of-truth shift for live native-primary edges: MCP-visible `ref:*` labels are compatibility projections, while native traversal and viewer export consume `card_edges` (`thoughts/searchable/shared/research/2026-04-30-native-primary-live-edge-commit-card-edges-solution.md:29`, `thoughts/searchable/shared/research/2026-04-30-native-primary-live-edge-commit-card-edges-solution.md:451`).

## Current Coordination State

- `silmari-agent-memory-4d8.15` is closed at commit `e52091d9f2886484c0daa4241a0ab46edbbe89b6`; the direct KC Baker cascade import writer now uses Silmari Store.
- `silmari-agent-memory-4d8.14` tracks manual production flip evidence.
- `silmari-agent-memory-4d8.14.1` was opened after this research for import parity blocking on the legacy root-register `fz:0_0` row. It is now closed: the fix accepts `fz:0_0` only as the root register address, regenerates the real production-readiness parity evidence, and records the evidence bundle at `artifacts/evidence/silmari-store/2026-05-01T013000Z-silmari-store-production-readiness/`.
- `silmari-agent-memory-e8u` records the official naming contract: Silmari Store, CLI/binary `silmari-store`, Rust crate/module `silmari_store`, and wording that Silmari Store replaces `beads_rust` as the storage layer for Silmari Memory.
- `silmari-agent-memory-xom` remains adjacent viewer migration context for fork-and-strip toward Zettelkasten-native viewer surfaces.
- `silmari-agent-memory-792` remains adjacent KC Baker follow-up context for card density differences versus the cascade plan estimate.
- This research artifact is read-only with respect to MCP/server implementation files and did not modify production code.

## Verification During Research

Commands run for this research:

```text
bd show silmari-agent-memory-4d8.15
git status --short
git log -5 --oneline --decorate
git rev-list --left-right --count HEAD...origin/main
silmari-oracle metadata
rg / nl inspections of apps/silmari-mcp, apps/silmari_memory_rust, scripts/kc-baker-pipeline-v2, artifacts/specs, and related plans/research
```

No test suite was run for this research document because the task was interface research and the only repository change is this markdown artifact.
