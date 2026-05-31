---
date: 2026-04-28T18:20:55-04:00
reviewer: Codex
topic: "Card-Native beads_rust Replacement TDD Plan - Boundary Contract Review"
tags: [review, cw9, boundary-contracts, external]
status: complete
reviewed_plan: thoughts/searchable/shared/plans/2026-04-28-silmari-agent-memory-dbh-tdd-card-native-beads-rust-replacement.md
review_type: boundary_contracts
---

# Boundary Contract Review: Card-Native beads_rust Replacement

## Summary

Tracking issue: `silmari-agent-memory-dbh.2`

| Check | Status | Issues |
| --- | --- | --- |
| Boundary inventory complete | fail | The plan has no dedicated `## Assumed Existing Contracts` section; this review extracted 8 implied boundaries. |
| Producer/consumer alignment | fail | 6 boundaries are not executable today, and 2 existing boundaries still route through legacy internals. |
| Ownership of execution | fail | Native CLI/facade, runtime mode, shadow parity, and SAI ownership are planned but not real. |
| Transcript derivation | fail | 5 transcripts break before a real producer-consumer handoff can occur. |
| Contract test obligations | fail | 6 required tests must cross real process/module boundaries instead of relying on harness-only payloads. |

## Verdict

- [ ] All boundary contracts proven - proceed to implementation
- [x] Boundary gaps found - update plan/context and add real contract tests before implementing
- [x] Contract contradiction found - fix the claimed existing boundary before continuing

The plan is directionally strong and now names the correct owners. The boundary review still fails because several key handshakes are described as future behavior but the test obligations do not consistently require the real producer and real consumer to run together.

The central issue is that local Rust CLI tests plus TypeScript harness tests do not prove the cross-process contract between `NativeCliAdapter` and `silmari_memory_rust`. The plan needs explicit end-to-end contract tests for the actual adapter spawning the actual Rust binary and mapping actual JSON envelopes.

## Boundary Inventory

| ID | Producer | Consumer | Transport | Claimed Contract | Actual Contract | Status |
| --- | --- | --- | --- | --- | --- | --- |
| BC-1 | `silmari_memory_rust` CLI | TS `NativeCliAdapter` / `br-adapter.ts` facade | subprocess JSON stdout/stderr | Commands emit `NativeEnvelope<T>` and TS maps to current `br*` shapes | Rust CLI is retrieval/import-only, emits raw success JSON and `{error}` without top-level `ok`; `native-adapter.ts` is absent | FAIL |
| BC-2 | MCP tool/resource dispatch | `br-adapter.ts` facade | in-process TS module API | `zk_*` tools and `silmari://card/<id>` route through mode-aware facade | `dispatchTool` and resources call legacy functions; `card-ops.ts` imports `br-sqlite.ts` directly | FAIL |
| BC-3 | Mode config/env | MCP facade and SAI shim | env/config JSON file | `NativeModeConfig` selects `legacy-br`, shadow, native, or rollback behavior | `native-mode.ts` is absent; no runtime resolver exists | FAIL |
| BC-4 | Shadow/parity layer | Legacy and native adapters | in-process TS plus report files | Shadow modes run both sides and write parity/reconciliation artifacts | `native-shadow.ts` and Rust `parity.rs` are absent | FAIL |
| BC-5 | Snapshot creator | Snapshot importer | filesystem manifest plus SQLite files | `create-snapshot` produces hash-bound manifest consumed by `import-snapshot` before target mutation | Current importer opens source/target directly with `import_beads_box`, no manifest, staging, report, or promotion boundary | FAIL |
| BC-6 | `AcceptedReviewManifest` | Importer and edge authority store | JSON file plus native transaction | Reviewed imported refs promote only with validated, snapshot-bound authority | Current importer parses labels and calls `insert_edge` directly; no manifest consumer exists | FAIL |
| BC-7 | Rust viewer export | Current viewer server/browser query set | exported SQLite file | Rust export writes compatibility cache satisfying `issues`, `dependencies`, `card_edges`, FTS, MV, and meta contracts | Current Go schema lacks `card_edges`; current server synthesizes `card_edges` from labels after `bv` export; Rust export is absent | FAIL until implemented |
| BC-8 | Public SAI memory shim | `ThinkWithMemory` hook and `buildInjection` | in-process TS module API | SAI consumes one public memory client and receives `{keywordEntries, folgezettelNeighbors, crossRefs}` | Current local shim still dynamically imports low-level `keyword-index`, `br-adapter`, `navigate`, and `labels`; tests inject recall implementations | FAIL |

## Ownership Matrix

| Boundary | Start | Continue | Complete | Pause/Rollback | Error Translation |
| --- | --- | --- | --- | --- | --- |
| BC-1 CLI to adapter | TS `NativeCliAdapter` should spawn Rust | Rust CLI executes one command and exits | TS facade maps result to caller contract | n/a | TS facade maps native codes to null/false/[]/throw |
| BC-2 MCP to facade | MCP `dispatchTool` / `dispatchResource` | `br-adapter.ts` facade chooses mode | Rust or legacy branch mutates/reads state | Mode resolver owns rollback switch | MCP wraps errors into tool/resource responses |
| BC-3 mode config | `native-mode.ts` resolver | `br-adapter.ts`, shadow layer, SAI shim consume resolved mode | Mode-specific adapter finishes operation | Config/env owns rollback; no source edits | `ModeConfigError` blocks runtime writes |
| BC-4 shadow parity | Facade starts dual read/write | Legacy and native adapters both execute | Shadow layer writes parity/reconciliation report | Runtime mode gates advance/rollback | Shadow layer categorizes differences |
| BC-5 snapshot/import | `create-snapshot` writes manifest | `import-snapshot` validates and stages | Promotion atomically replaces target | Rollback manifest owns restore instructions | Import CLI emits typed failure envelope |
| BC-6 accepted manifest | Operator supplies manifest | Importer validates against snapshot and cards | Store writes accepted edge/proposal event | Invalid manifest blocks promotion | Import report classifies reviewed edge outcomes |
| BC-7 viewer export | Rust export command writes cache | Viewer server/browser loads exported SQLite | Viewer query/link builder renders graph | Export version gates compatibility | Viewer/export tests surface schema mismatch |
| BC-8 SAI shim | Hook calls public memory client | Shim normalizes MCP/native payloads | `buildInjection` consumes normalized summary | n/a | Hook degrades to unavailable/timeout/error without prompt failure |

## Concrete Transcripts

### BC-1: Rust CLI to TypeScript Native Adapter

Claimed transcript:

1. `br-adapter.ts` public export calls `NativeCliAdapter.showCompat("idea", "zk-a")`.
2. `NativeCliAdapter` spawns `silmari_memory_rust show-card --db <native> --id zk-a --json`.
3. Rust CLI opens the DB with the command-specific policy.
4. Rust CLI returns `{ "ok": true, "result": { ... } }` or `{ "ok": false, "error": { "code": "CARD_NOT_FOUND", ... } }`.
5. `NativeCliAdapter` maps the envelope to existing `brShow` shape: row or `null`.

Actual source-backed transcript:

1. `apps/silmari-mcp/src/lib/native-adapter.ts` does not exist.
2. `apps/silmari_memory_rust/src/cli.rs::Command` has `Init`, `ImportBeads`, `Recall`, `Neighborhood`, `Edges`, and `LineOfThought`; it does not have `show-card`, `list-cards`, `create-card`, or the other adapter commands.
3. `cli.rs::run` prints raw success JSON through `print_json(&value)`, not `NativeEnvelope<T>`.
4. `cli.rs::print_error` emits `{ "error": { ... } }`, not `{ "ok": false, "error": ... }`.
5. `error_parts` still emits lowercase/stale codes such as `cli_parse`, `sqlite`, and `unknown_edge_type`.

Breakage: the producer and consumer for this boundary are not real yet, and the current producer emits a different protocol than the plan's consumer expects.

### BC-2: MCP Tool/Resource Dispatch to Mode-Aware Facade

Claimed transcript:

1. MCP receives `tools/call` for `zk_save_card`.
2. `dispatchTool` calls `saveCard`.
3. `saveCard` calls public `br-adapter.ts` facade.
4. Facade chooses native/legacy/shadow mode.
5. Native mode calls `create-card`; legacy mode calls Beads; shadow mode compares both.

Actual source-backed transcript:

1. `apps/silmari-mcp/src/index.ts::dispatchTool` calls `saveCard`, `saveCardsBatch`, `navigate`, `lineOfThought`, `addEdge`, and `brList` directly.
2. `apps/silmari-mcp/src/lib/card-ops.ts` imports `brCreate`, `brList`, `brLabelAdd`, `brShow`, `brRecoverFromJsonl`, and `brFlushOrThrow` from `br-adapter.ts`.
3. `card-ops.ts` also imports `findBeadsByLabel` directly from `br-sqlite.ts`.
4. `dispatchResource("silmari://card/<id>")` calls `brShow` directly.
5. No `br-adapter.ts` facade split, `legacy-br-adapter.ts`, or `native-mode.ts` exists in the current source.

Breakage: current MCP dispatch cannot be switched to native mode without implementation work, and the plan's routing harness tests are not enough unless they prove the real `dispatchTool`/`dispatchResource` path.

### BC-3: Runtime Mode Config to Facade

Claimed transcript:

1. `resolveSilmariMemoryMode` reads test override, `SILMARI_MEMORY_MODE`, `SILMARI_MEMORY_CONFIG`, or default config file.
2. Invalid config returns `ModeConfigError`.
3. `br-adapter.ts` routes each public export through the selected mode.
4. Rollback is a config/env change only.

Actual source-backed transcript:

1. `apps/silmari-mcp/src/lib/native-mode.ts` does not exist.
2. `br-adapter.ts` is a direct Beads CLI wrapper, not a mode switch.
3. Existing MCP handlers have no mode resolution step.

Breakage: no real runtime owner exists for mode selection, rollback, or invalid-mode error translation.

### BC-4: Shadow Parity

Claimed transcript:

1. Facade runs a supported operation in legacy and native adapters.
2. Shadow layer normalizes both results.
3. User-visible result follows mode policy.
4. Parity/reconciliation records are written to configured report directories.

Actual source-backed transcript:

1. `apps/silmari-mcp/src/lib/native-shadow.ts` does not exist.
2. `apps/silmari_memory_rust/src/parity.rs` does not exist.
3. Legacy adapter implementation is not split from public facade.
4. Native adapter implementation does not exist.

Breakage: the plan names the right files, but no executable dual-adapter path exists yet.

### BC-5: Snapshot Manifest to Import

Claimed transcript:

1. `create-snapshot --json` copies legacy DBs/sidecars read-only.
2. It writes a manifest with paths, hashes, sizes, timestamps, git commit, and tool version.
3. `import-snapshot` validates the manifest before opening target for writes.
4. Import writes staging DB and reports, then promotes safely.

Actual source-backed transcript:

1. `apps/silmari_memory_rust/src/migration.rs` does not exist.
2. `importer.rs::import_beads_box` calls `schema::init_schema(target_path)`, opens the target directly, opens the source with `Connection::open`, and imports rows.
3. No manifest, same-directory staging, rollback manifest, or report files exist in the current importer.

Breakage: the file/artifact contract is a planned boundary, not an existing one. The plan has decent unit obligations here, but it should also require a real CLI-level snapshot-to-import transcript.

### BC-7: Rust Viewer Export to Current Viewer

Claimed transcript:

1. Rust `export_viewer_compat` writes a SQLite cache with current viewer tables.
2. Current viewer query set executes against that cache.
3. `link-builder.js` merges `dependencies` and `card_edges` with matching direction.

Actual source-backed transcript:

1. Current Go `CreateSchema` writes `issues`, `dependencies`, `comments`, metrics, FTS, and `export_meta`; it does not create `card_edges`.
2. Current viewer server runs `bv --export-pages`, then `synthesizeEdgesFromLabels` creates/populates `card_edges` from `issues.labels`.
3. `link-builder.js` consumes `dependencies.issue_id -> depends_on_id` and `card_edges.source -> target`.
4. Rust export module does not exist.

Breakage: no Rust producer exists yet, but the current consumer contract is real and well understood. The plan's viewer tests are close; they should explicitly exercise a Rust-produced cache through the current viewer query functions.

### BC-8: SAI Hook to Public Memory Shim

Claimed transcript:

1. `ThinkWithMemory.hook.ts` detects a trigger.
2. Hook calls a public memory client shim.
3. Shim calls MCP/facade recall in the active mode.
4. Shim normalizes to `{ keywordEntries, folgezettelNeighbors, crossRefs }`.
5. `buildInjection` consumes the normalized shape.

Actual source-backed transcript:

1. Current `ThinkWithMemory.hook.ts` calls `recallSilmariWithFallback`.
2. Current `silmari-recall-client.ts` normalizes shape, but `loadZkRecall` dynamically imports low-level `keyword-index.ts`, `br-adapter.ts`, `navigate.ts`, and `labels.ts`.
3. Tests inject `recallImpl` or `loadRecall`, so they prove normalization but not the real mode-aware facade boundary.

Breakage: the public shim shape exists locally, but the real producer still bypasses the planned facade boundary.

## Contract Test Obligations

| Boundary | Required Test | Exists? | Notes |
| --- | --- | --- | --- |
| BC-1 | TypeScript `NativeCliAdapter` spawns the actual Rust binary and maps real success/error `NativeEnvelope<T>` payloads for `show-card`, `list-cards`, and `create-card` | NO | Current plan splits Rust CLI tests from TS harness tests; mocks do not prove the subprocess protocol. |
| BC-1 | Missing read DB path stays absent after actual TS adapter calls a read command | NO | Rust-only open-policy tests are necessary but not sufficient for the adapter boundary. |
| BC-2 | `dispatchTool("zk_save_card")` in `native-primary` mode uses the public facade and real native create path with legacy Beads DB absent | NO | Existing/planned routing harnesses need a real MCP dispatch path, not only call recording. |
| BC-2 | `dispatchResource("silmari://card/<id>")` in native mode reads through the facade and native exact show | NO | Current resource dispatch calls `brShow` directly. |
| BC-3 | Env/config mode resolver drives real public `br-adapter.ts` exports, including invalid config blocking writes | NO | Requires `native-mode.ts` and facade-owned integration tests. |
| BC-4 | Shadow-write performs a real legacy write and real native write, then writes a reconciliation JSONL record on mismatch | NO | Harness-only parity comparison is not enough. |
| BC-5 | CLI-level `create-snapshot --json` output is consumed by CLI-level `import-snapshot --json` before target mutation | PARTIAL | Plan has Rust unit tests, but should require actual command transcript. |
| BC-6 | Import with a real `AcceptedReviewManifest` promotes reviewed refs; mismatched hash fails before promotion | NO | Plan has unit-style manifest test, but import path must consume it. |
| BC-7 | Rust-produced compatibility cache is loaded by current viewer query/link-builder tests without server-side label synthesis dependency | PARTIAL | Plan has `assert_current_viewer_queries_execute`; add explicit "Rust cache into current viewer" fixture. |
| BC-8 | SAI hook loads public memory client shim in native mode without low-level MCP imports, then `buildInjection` sees the normalized shape | NO | Current tests inject recall implementations and do not prove the real boundary. |

## Findings

### Critical

1. **Native CLI to TypeScript adapter handshake is not proven.** Current Rust CLI emits a different JSON protocol and lacks the commands the TS adapter will call. The plan must require a real TS adapter integration test that spawns the actual Rust binary and validates actual envelopes.

2. **MCP dispatch/resource paths do not cross the planned facade.** `dispatchTool`, `dispatchResource`, and `card-ops.ts` still reach legacy functions and `br-sqlite.ts` directly. The plan names this as implementation work, but its tests must prove the real MCP public path, not only a mode-routing harness.

3. **Runtime mode ownership is absent.** `native-mode.ts` does not exist, `br-adapter.ts` is not a mode switch, and invalid-mode rollback behavior has no owner in current code. The plan must require real config/env-to-public-export tests.

4. **SAI shim does not yet prove the public memory boundary.** The local shim normalizes payloads, but its loader still imports low-level MCP internals. The plan must require a native-mode SAI hook test that consumes only the public memory client/facade.

### Warnings

1. The plan still lacks a dedicated `## Assumed Existing Contracts` section. The section should explicitly classify each boundary as `existing`, `planned`, or `existing-but-to-be-replaced`.

2. Snapshot/import and viewer export are planned producer boundaries, not current contracts. The plan handles them as implementation work, but the quality gate should say the follow-up contract review cannot pass until the real files and command transcripts exist.

3. The existing `zk_block` tool description advertises `ref:blocked-by:<id>` while the dispatcher writes canonical `blocks`. The plan already calls for a `zk_block` contract test; keep it as a boundary test obligation because tool descriptions are a model-facing API.

## Required Plan Additions

Add or amend these obligations before implementation:

- `apps/silmari-mcp/tests/native-cli-contract.test.ts`: build or locate the Rust binary, spawn it through `NativeCliAdapter`, and assert real `NativeEnvelope` mapping for success, not found, validation error, timeout, and missing DB.
- `apps/silmari-mcp/tests/native-mcp-dispatch-contract.test.ts`: call `dispatchTool` and `dispatchResource` in `native-primary` with legacy Beads paths missing and assert real native DB reads/writes.
- `apps/silmari-mcp/tests/native-mode-config-contract.test.ts`: verify env/config precedence, invalid config blocking writes, and config-only rollback through public exports.
- `apps/silmari-mcp/tests/native-shadow-contract.test.ts`: run real legacy and real native branches and assert report/reconciliation artifacts.
- `apps/silmari_memory_rust/tests/import_snapshot_cli_contract.rs`: exercise `create-snapshot --json` followed by `import-snapshot --json` through command execution, not only library helpers.
- `SAI/hooks/tests/think-with-memory-native-boundary.test.ts`: run the hook or public shim against the mode-aware facade, with assertions that low-level MCP modules are not imported.

## Final Gate

The plan should remain blocked until:

1. The critical test obligations above are added to the plan.
2. The planned producer files exist or are explicitly included in the first implementation slice.
3. A follow-up `04cw9-Plan-Review` can derive real transcripts from source for BC-1, BC-2, BC-3, BC-4, and BC-8.
