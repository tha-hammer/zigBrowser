---
date: 2026-04-28T05:55:00-04:00
planner: Codex
repository: silmari-agent-memory
branch: main
topic: "TDD plan - card-native beads_rust replacement"
app_name: silmari_memory_rust
type: tdd_plan
status: coverage_pipeline_body_hash_native_create_pinned
last_status_update: 2026-04-30
cw9_project: /home/maceo/Dev/silmari-agent-memory
related_beads_issues:
  - silmari-agent-memory-dbh
  - silmari-agent-memory-32d
  - silmari-agent-memory-7jo
  - silmari-agent-memory-j8v
  - silmari-agent-memory-e3f
  - silmari-agent-memory-1rn
  - silmari-agent-memory-dbh.1
  - silmari-agent-memory-dbh.2
  - silmari-agent-memory-1c0
  - silmari-agent-memory-1c0.6
review_incorporated:
  - thoughts/searchable/shared/plans/2026-04-28-silmari-agent-memory-dbh-tdd-card-native-beads-rust-replacement-REVIEW.md
  - thoughts/searchable/shared/plans/2026-04-28-silmari-agent-memory-dbh-tdd-card-native-beads-rust-replacement-REVIEW-2.md
  - thoughts/searchable/shared/plans/2026-04-28-card-native-beads-rust-replacement-ARTIFACTS-REVIEW.md
  - thoughts/searchable/shared/plans/2026-04-28-silmari-agent-memory-dbh-tdd-card-native-beads-rust-replacement-ARTIFACTS-REVIEW.md
  - thoughts/searchable/shared/plans/2026-04-28-silmari-agent-memory-dbh-tdd-card-native-beads-rust-replacement-COVERAGE-REVIEW.md
  - thoughts/searchable/shared/plans/2026-04-28-silmari-agent-memory-dbh-tdd-card-native-beads-rust-replacement-ABSTRACTION-REVIEW.md
  - thoughts/searchable/shared/plans/2026-04-28-silmari-agent-memory-dbh-tdd-card-native-beads-rust-replacement-CONTRACT-REVIEW.md
related_specs:
  - artifacts/specs/2026-04-28-beads-rust-replacement/README.md
  - artifacts/specs/2026-04-28-beads-rust-replacement/01-system-architecture.md
  - artifacts/specs/2026-04-28-beads-rust-replacement/02-native-data-model.md
  - artifacts/specs/2026-04-28-beads-rust-replacement/03-store-api-and-adapter.md
  - artifacts/specs/2026-04-28-beads-rust-replacement/04-migration-cutover-and-verification.md
  - artifacts/specs/2026-04-28-beads-rust-replacement/05-viewer-export-and-consumers.md
  - specs/processing-pipeline.md
related_research:
  - thoughts/searchable/shared/research/2026-04-28-cw9-card-native-beads-rust-replacement.md
  - thoughts/searchable/shared/research/2026-04-28-data-model-beads-rust-replacement.md
tags: [tdd, plan, rust, sqlite, beads-rust, migration, mcp, viewer, zettelkasten]
---

# Card-Native beads_rust Replacement TDD Implementation Plan

## Overview

Replace the runtime dependency on `vendor/beads_rust` / `br` for Silmari memory with a card-native Rust SQLite store while preserving the observable behavior currently routed through `apps/silmari-mcp/src/lib/br-adapter.ts`.

This is not a generic issue-tracker rewrite. The implementation must make cards, folgezettel addresses, typed edges, exact keyword recall, migration diagnostics, and viewer export first-class concepts. Generic Beads constructs stay only as import inputs or temporary compatibility projections.

The plan is intentionally staged:

1. Expand the native Rust schema from retrieval-substrate v1 to live-store v2.
2. Implement card-native write/read APIs with event rows and label projection.
3. Preserve current TypeScript adapter return semantics through a narrow compatibility facade.
4. Migrate legacy Beads and MCP-side data through snapshot, import, parity, and rollback reports.
5. Export both current issue-shaped viewer compatibility tables and future card-native viewer tables.

## Current Implementation Status (2026-04-30)

The CW9 coverage, abstraction, and first boundary-contract implementation blockers have been remediated and their Beads parent rollups are closed. No open implementation child lane remains under the DBH card-native `beads_rust` replacement issue family.

The 2026-04-30 `beads_rust` replacement debug produced a current processing pipeline spec and semantic proposer artifacts. Those artifacts do **not** reopen the DBH native-store/facade implementation rollups, but they do revise this plan's acceptance boundary: native-primary readiness must now be validated through the cached transcript pipeline's native-primary/rusqlite storage boundary before downstream enrichment and Gate B evidence can be trusted.

The 2026-04-30 accepted-edge follow-up (`silmari-agent-memory-1c0` /
`silmari-agent-memory-1c0.6`) is resolved at this plan's native-create
boundary: body-hash recurrence is not a TypeScript native post-save bridge. It
belongs wholly inside Rust `create_card`, using
`EdgeWriteAuthority::BodyHashRecurrence` and the reviewed-edge store helper
inside the same create transaction. TypeScript native-primary create callers
only map the native result metadata back to compatibility return shapes. The
implementation landed in `c20ceab` (Rust native create transaction and
`native_create` contract test) and `e4effb4` (TypeScript native-primary result
mapping and dispatch contract); `silmari-agent-memory-1c0.6` and
`silmari-agent-memory-1c0.6.1` are closed.

Closed or verified lanes:

- `silmari-agent-memory-1rn.1`: `gwt-0001` schema v2 migration coverage gate. Closed with real v1 upgrade/no-partial/future-version Rust and generated-test coverage.
- `silmari-agent-memory-1rn.2`: `gwt-0004` `NativeEnvelope<T>` / CLI open-policy gate. Closed with current uppercase adapter error codes and stale-code checks.
- `silmari-agent-memory-1rn.3`: `gwt-0006` TypeScript facade invariant gate. Closed with facade/import ownership checks and generated tests.
- `silmari-agent-memory-1rn.4`: `gwt-0006` native-primary runtime probe config and public timeout compatibility fix. Closed after the generated test supplied valid `NativeModeConfig` and `brList` native timeouts mapped back to public `BrListTimeoutError`.
- `silmari-agent-memory-1rn`: coverage-remediation parent. Closed after `pytest tests/generated/test_gwt_0001.py tests/generated/test_gwt_0004.py tests/generated/test_gwt_0006.py` passed (44 pass / 0 fail), `cw9 status` reported 8/8 verified and 8 bridge-complete, and `cw9 test` passed (101 pass / 214 skip).
- `silmari-agent-memory-dbh.1`: abstraction-gap review lane. Closed after follow-up coverage, abstraction, and contract review reports were recorded.
- `silmari-agent-memory-dbh.2.2`: Rust snapshot/import/viewer-export boundary slice. Closed in commit `3329d24`.
- `silmari-agent-memory-dbh.2.1.1`: `br-adapter.ts` runtime mode switch and public facade split. Closed by `CobaltRiver` in commit `d25296f`.
- `silmari-agent-memory-dbh.2.1.2`: BC-1 `NativeCliAdapter` live show/list/create transcript. Closed by `CobaltRiver` in commit `c5937fa`.
- `silmari-agent-memory-dbh.2.1.3`: BC-2 native-primary MCP dispatch/resource transcript. Closed by `CobaltRiver` in commit `782ac30`.
- `silmari-agent-memory-dbh.2.1.4`: BC-8 SAI hook uses public memory client shim. Closed by `CobaltRiver` in commit `dc0fb6a`.
- `silmari-agent-memory-dbh.2.1.5`: BC-2 prerequisite native block edge write surface for the `zk_block` transcript. Closed by `CobaltRiver` in commit `1b09f42`.
- `silmari-agent-memory-e6g.1`: dirty shared-file ownership reconciliation for `e6g` / DBH / ADF. Closed by `GreenBridge`; the `br-adapter.ts`, `card-ops.ts`, `init.ts`, and `navigate.ts` blocker was cleared before the facade split landed.

Verified rollup state:

- `silmari-agent-memory-dbh.2.1`: all TypeScript native facade/source-backed transcript child beads are closed and the parent is closed. Focused verification on 2026-04-29 passed with the prebuilt Rust binary: `bun test apps/silmari-mcp/tests/native-cli-contract.test.ts apps/silmari-mcp/tests/native-mcp-dispatch-contract.test.ts apps/silmari-mcp/tests/native-mode-config-contract.test.ts apps/silmari-mcp/tests/native-shadow-contract.test.ts apps/silmari-mcp/tests/native-adapter.test.ts apps/silmari-mcp/tests/native-mode-routing.test.ts SAI/hooks/tests/think-with-memory-native-boundary.test.ts` (26 pass / 0 fail).
- `silmari-agent-memory-dbh.2`: all first-slice boundary-contract children are closed and the parent is closed. Focused Rust verification on 2026-04-29 passed: `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml --test import_snapshot_cli_contract --test viewer_export_contract` (5 pass / 0 fail). TypeScript compile verification passed: `bun run --cwd apps/silmari-mcp typecheck`.
- `silmari-agent-memory-9hn.1` is not a DBH replacement child bead. It tracks Gate B real-run throughput/classification validation and must not be treated as evidence that the card-native `beads_rust` replacement parent rollups remain open.
- `silmari-agent-memory-iaa`: plan-status cleanup after `1c0.6` /
  `1c0.6.1`. It recorded the final implementation commits, actual test names,
  and manual evidence inspection after the code beads closed.
- `specs/processing-pipeline.md`, `apps/silmari-mcp/src/lib/semantic-proposer.prompt.md`, and `apps/silmari-mcp/src/lib/semantic-proposer.ts` are downstream pipeline validation artifacts. They add required native-primary pipeline validation gates to this plan, but Gate B classifier quality and throughput remain owned by the Gate B / cascade workstream, not by the DBH replacement rollup.

Coordination rules:

- Only `GreenBridge`, `CobaltRiver`, and `VioletBeacon` are coordinating this issue set unless the user explicitly changes the roster again.
- Do not edit `br-adapter.ts`, `card-ops.ts`, native-mode/native-adapter files, or SAI hook files without a Beads claim, file reservation, and agent-mail notice.
- Existing unrelated dirty worktree changes in those files must be treated as another agent/user's work and preserved.
- Keep Rust snapshot/import/export work separate from the remaining TypeScript facade lane unless a bead explicitly bridges them.

This revision incorporates the 2026-04-28 major-review findings and pins the previously open implementation choices:

- Native v1 databases migrate to v2 in one transaction; future, partial, or unknown schemas are rejected with `SCHEMA_INCOMPATIBLE`.
- Rust native row types are distinct from MCP/viewer compatibility payload serializers so lifecycle fields do not leak into recall or line-of-thought JSON.
- Reviewed semantic edges use an explicit `EdgeWriteAuthority` across normal edge writes, accepted proposals, body-hash recurrence, and legacy import.
- Every JSON CLI command uses one `NativeEnvelope<T>` and an operation-specific read/write DB open policy.
- Migration starts with a read-only snapshot manifest; `--replace` is unsafe unless the snapshot manifest exists and matches source hashes.
- Viewer compatibility export must satisfy the current viewer query set, not just create similarly named tables.
- SAI direct-import consumers are routed through one public MCP/facade shim; transitional snake_case normalization is confined to that shim.

This revision also incorporates the 2026-04-28 follow-up review and pins the remaining blocking boundaries:

- Direct `br-sqlite.ts` label reads are not allowed outside the legacy adapter implementation; label lookup is a first-class facade operation in all runtime modes.
- Runtime mode configuration has a concrete `NativeModeConfig` file contract, scope, precedence, and invalid-config failure mode.
- Imported legacy reviewed refs are not silently trusted as live reviewed edges; they become pending import proposals unless explicit acceptance evidence is present.
- CW9 GWT IDs and `depends_on` UUIDs are mapped in this plan, and missing bridge/generated-test artifacts are a required pre-implementation gate.

This revision also incorporates the 2026-04-28 coverage review. The prior artifact set is **not** a sufficient implementation gate: `gwt-0001`, `gwt-0004`, and `gwt-0006` require regenerated or amended generated tests before implementation. `gwt-0004` also requires a regenerated TLA+/bridge/context set because the model's error-code vocabulary is stale relative to this plan's `NativeEnvelope<T>` contract.

This revision also incorporates the 2026-04-28 abstraction review and removes the remaining implementation-choice ambiguity:

- Schema open/migrate ownership is pinned to explicit `init_schema`, `open_or_migrate`, and `migrate_v1_to_v2` responsibilities.
- Accepted reviewed-edge import evidence is a concrete `AcceptedReviewManifest` contract, not an undefined side artifact.
- Native-mode post-save effects have one durable owner: Rust `create_card`; TypeScript maps results and runs mode/parity work only.
- `br-adapter.ts` is the public facade and mode switch; `legacy-br-adapter.ts` owns Beads compatibility internals; `native-adapter.ts` owns native CLI calls.

This revision also incorporates the 2026-04-28 boundary contract review and makes the cross-layer handshakes explicit:

- The plan now has a dedicated `## Assumed Existing Contracts` section that classifies each boundary as existing, planned, or existing-but-to-be-replaced.
- Boundary producer files that do not exist today are first-slice implementation work, not assumed infrastructure.
- The TypeScript `NativeCliAdapter` must spawn the real Rust binary in contract tests; local Rust CLI tests plus TypeScript harnesses are not enough.
- MCP `dispatchTool` and `dispatchResource` must be exercised in native-primary mode through the real public facade with legacy Beads paths missing.
- Runtime mode, shadow parity, snapshot/import, viewer export, and SAI shim tests must cross real producer/consumer boundaries rather than only asserting local helper payloads.

This revision also incorporates the 2026-04-30 processing pipeline debug and pins the downstream validation boundary:

- Cached transcript artifacts import into native-primary/rusqlite first; enrichment and Gate B run only against imported native card IDs.
- `CASCADE_ENRICHMENT_MODE=off|after-import|enrich-only` is a current orchestration contract, not an implementation note.
- `CASCADE_GATE_B_CLASSIFIER_MODE=source|bundle` is a current Gate B classifier contract. The preferred large-context bundle path hydrates unique card bodies once, validates typed reviewed edges deterministically, and commits only accepted links.
- Bundle telemetry is part of the acceptance surface: `bundles_submitted`, `bundle_cards_submitted`, `bundle_unique_cards_hydrated`, `bundle_prompt_chars_total`, `bundle_prompt_chars_max`, `edges_returned_raw`, `edges_rejected_validation`, `edges_rejected_caps`, `llm_calls_attempted`, `llm_latency_ms_total`, and `edges_committed`.
- Source-card semantic proposal prompting is file-backed by `apps/silmari-mcp/src/lib/semantic-proposer.prompt.md`; batch and bundle prompts are currently inline in `apps/silmari-mcp/src/lib/semantic-proposer.ts`. That ownership is explicit for this plan. If a later pipeline revision requires file-backed batch/bundle prompts, it must update the semantic proposer tests and this boundary section together.
- Bundle classifier timeout, unavailability, or unparseable output is a Gate B failure report path. It must not be accepted as a zero-edge success.

### Review Gap Resolution Map

| Review finding | Plan amendment |
| --- | --- |
| C-1 schema v2 migration coverage | Behavior 1 adds native v1-to-v2 migration tests, index assertions, and a pinned migration/rejection policy. |
| C-2 reviewed-edge authority conflict | Behavior 2 defines `EdgeWriteAuthority`; Behaviors 3, 4, and 6 bind recurrence, CRUD, and import paths to it. |
| C-3 Rust domain vs compatibility serialization | Desired End State and Behavior 9 split native row types from MCP/viewer payload serializers and add no-leak snapshot tests. |
| C-4 CLI envelope/open policy | Behavior 11 defines `NativeEnvelope<T>`, error codes, and per-command DB open policy. |
| C-5 TS facade routing contracts | Behavior 7 defines `SilmariMemoryAdapter`, mode resolution, and br-adapter export routing; Behavior 12 adds mode smoke tests. |
| C-6 migration snapshot/replace safety | Behavior 6A adds snapshot manifests, source hashes, staging promotion, and `--replace` gates. |
| C-7 viewer export compatibility | Behavior 10 adds the compatibility schema/query contract, `blocks` direction, casing, and viewer-query tests. |
| C-8 SAI consumer mismatch | Behavior 12 adds the SAI public memory-client shim and actual ThinkWithMemory native-mode fixture. |
| REVIEW-2 C-1 direct `br-sqlite` facade bypass | Behavior 7 adds `findCardsByLabelCompat`, keeps `br-sqlite.ts` legacy-only, and adds native-primary tests without legacy `beads.db`. |
| REVIEW-2 C-2 plan not CW9-wired | The CW9 Artifact Binding section maps this plan to `gwt-0001` through `gwt-0008`, their `depends_on` UUIDs, and current artifact status. |
| REVIEW-2 C-3 runtime mode config underspecified | Behavior 12 defines `NativeModeConfig`, path resolution, scope, validation, and config-only rollback tests. |
| REVIEW-2 data relationship warnings | Behavior 2 adds FK/delete policy, event actor metadata, import warning metadata, and `edge_proposals` state transitions. |
| REVIEW-2 migration promotion warnings | Behaviors 6A and 6 pin same-directory staging, SQLite backup/WAL handling, cross-device promote failure, and reconciliation report schema. |
| COVERAGE C-1 `gwt-0001` missing v1/no-partial coverage | Behavior 1 now requires generated tests to seed a real native v1 DB, replay the `gwt-0001` traces, assert `V1FullyUpgraded`, and assert `NoPartialMigration` after failed/partial migration attempts. |
| COVERAGE C-2 `gwt-0004` stale CLI proof contract | Behavior 11 now treats `CARD_NOT_FOUND`, `QUERY_TIMEOUT`, `VALIDATION_ERROR`, `SCHEMA_INCOMPATIBLE`, `DB_NOT_FOUND`, and `CLI_PARSE` as the only adapter-facing codes, requires success `{ok:true,result}`, and requires regenerating `.tla`, bridge, context, traces, and generated tests if stale codes appear. |
| COVERAGE C-3 `gwt-0006` missing facade invariants | Behavior 7 now requires generated tests for `brCreate`, non-timeout `brList`, exact/null `brShow`, biblio-only `brSearch`, no native internal imports, no broad `br-sqlite` imports, and signature preservation across modes. |
| COVERAGE C-4 bridge-only verifier classification | The CW9 Artifact Binding section now classifies `.cfg` model-checked invariants separately from bridge-only helpers; bridge-only helpers must not be described as TLC-backed proof. |
| ABSTRACTION GAP-001 migration entrypoint ownership | Behavior 1 now pins `init_schema`, `open_or_migrate`, `migrate_v1_to_v2`, and `store::open_native` call ownership. |
| ABSTRACTION GAP-002 accepted review manifest | Behavior 2 now defines `AcceptedReviewManifest` schema, validation, snapshot binding, and import report counts; Behavior 6 consumes that contract. |
| ABSTRACTION GAP-003 Rust/TS post-save ownership | Behavior 3 now makes native `create_card` the only durable native-mode post-save owner and restricts TS post-save helpers to legacy/shadow-legacy branches. |
| ABSTRACTION GAP-004 adapter file ownership | Behavior 7 now makes `br-adapter.ts` the public facade, `legacy-br-adapter.ts` the only Beads compatibility owner, and `native-adapter.ts` the native CLI client. |
| CONTRACT BC-1 Rust CLI to TS adapter | Behaviors 7 and 11 now require `apps/silmari-mcp/tests/native-cli-contract.test.ts`, which builds or locates the actual Rust binary, spawns it through `NativeCliAdapter`, and asserts real `NativeEnvelope<T>` success/error mapping plus missing-read-DB non-creation. |
| CONTRACT BC-2 MCP dispatch/resources to facade | Behavior 7 now requires `apps/silmari-mcp/tests/native-mcp-dispatch-contract.test.ts`, which calls real `dispatchTool` and `dispatchResource` in native-primary mode with legacy Beads paths absent. |
| CONTRACT BC-3 runtime mode ownership | Behavior 12 now requires `apps/silmari-mcp/tests/native-mode-config-contract.test.ts`, which proves env/config precedence, invalid-config write blocking, and config-only rollback through public facade exports. |
| CONTRACT BC-4 shadow parity ownership | Behavior 8 now requires `apps/silmari-mcp/tests/native-shadow-contract.test.ts`, which executes real legacy and native branches and asserts reconciliation JSONL records. |
| CONTRACT BC-5/BC-6 snapshot/import manifest handoff | Behaviors 6A and 6 now require `apps/silmari_memory_rust/tests/import_snapshot_cli_contract.rs`, which runs CLI-level `create-snapshot --json` followed by CLI-level `import-snapshot --json`, including `AcceptedReviewManifest` validation. |
| CONTRACT BC-7 Rust viewer export to current viewer | Behavior 10 now requires a Rust-produced compatibility cache fixture loaded by the current viewer query/link-builder tests without relying on server-side label synthesis. |
| CONTRACT BC-8 SAI public shim | Behavior 12 now requires `SAI/hooks/tests/think-with-memory-native-boundary.test.ts`, which loads the public memory client shim in native mode and asserts no low-level MCP internals are imported. |
| 2026-04-30 pipeline validation boundary | The new `Processing Pipeline Boundary Contract` section and E2E gates require native-primary cached transcript import before enrichment/Gate B, source and bundle classifier-mode coverage, semantic proposer prompt ownership, bundle telemetry checks, and failure-report behavior. |

## Processing Pipeline Boundary Contract

The pipeline defined in `specs/processing-pipeline.md` is a downstream acceptance boundary for native-primary readiness. It does not make Gate B classifier quality, prompt tuning, or throughput optimization part of DBH core implementation, but it does prevent this plan from treating native import as complete if the cached transcript pipeline can only pass through legacy `br` diagnostics.

DBH-owned guarantees:

- A cached transcript import must write deterministic cards, labels, structural Tier A edges, and `ingest-report.json` IDs into native-primary/rusqlite before enrichment starts.
- `native-primary` pipeline validation must still work when legacy `beads.db` is missing, stale, or malformed. A green legacy `br` import-only diagnostic is not native-primary evidence.
- Label lookup, recall, line-of-thought, `zk_propose_links_semantic`, `zk_propose_link`, and `zk_commit_link` must route through the public facade/native storage boundary in native-primary mode.
- Reviewed edge commits from Gate B must use the same `EdgeWriteAuthority` policy as other accepted proposals and must preserve all existing typed-edge validation rules.
- Pipeline reports must expose enough storage and Gate B telemetry to diagnose whether failures came from native import, enrichment, classifier execution, validation rejection, edge caps, or commit failures.

Out-of-scope for DBH core:

- Choosing the best semantic classifier prompt for content quality.
- Optimizing LLM latency beyond exposing timeout/error telemetry and preserving the bundle-mode failure contract.
- Changing cascade extraction prompt targets or deciding the final card density per transcript.

Current mode contracts:

```ts
export type CascadeEnrichmentMode = 'off' | 'after-import' | 'enrich-only';
export type GateBClassifierMode = 'source' | 'bundle';
```

- `CASCADE_ENRICHMENT_MODE=off` imports cached artifacts only. It must not spawn MCP, create hubs, add keywords, call the LLM, or commit Gate B edges.
- `CASCADE_ENRICHMENT_MODE=after-import` imports first, then runs enrichment and Gate B against the newly written native-primary cards.
- `CASCADE_ENRICHMENT_MODE=enrich-only` reuses an existing import report and runs only enrichment and Gate B against those native card IDs.
- `CASCADE_GATE_B_CLASSIFIER_MODE=source` keeps the source-centered fallback path.
- `CASCADE_GATE_B_CLASSIFIER_MODE=bundle` is the preferred large-context path: hydrate unique card bodies once, build `allowedPairs` from deterministic candidates, shard by max cards/prompt chars, validate returned typed reviewed edges, apply caps, and commit only accepted links.

Semantic proposer prompt and schema contracts:

- `apps/silmari-mcp/src/lib/semantic-proposer.prompt.md` remains the source-card system prompt. It returns JSON array proposals with exactly `targetId`, `edge`, `confidence`, and `quoted_overlap`.
- Inline batch proposals in `apps/silmari-mcp/src/lib/semantic-proposer.ts` add `sourceId` to the same reviewed-edge proposal shape.
- Inline bundle proposals in `apps/silmari-mcp/src/lib/semantic-proposer.ts` must validate `sourceId`, `targetId`, allowed edge type, confidence, quoted-overlap length, no self-links, known IDs, and `allowedPairs` membership before any commit path sees the edge.
- Bundle validation telemetry must report raw returned edges, validation rejections, cap rejections, submitted bundle/card counts, unique hydrated card count, prompt-size totals/max, attempted LLM calls, total LLM latency, and committed edge counts.
- Bundle classifier timeout, unavailable inference backend, or unparseable output is fatal for the Gate B transcript run and must write a failure report. The caller must not collapse that path into zero accepted edges.

## Current State Analysis

### Key Discoveries

- `artifacts/specs/2026-04-28-beads-rust-replacement/01-system-architecture.md` defines the target as one native SQLite store plus a TypeScript compatibility facade, with modes from `legacy-br` through `native-primary`.
- `artifacts/specs/2026-04-28-beads-rust-replacement/02-native-data-model.md` requires live-store additions beyond the current Rust crate: `status`, `priority`, `scope`, `deleted_at`, `trunks`, `folgezettel_cursors`, `edge_proposals`, `card_events`, and `card_notes`.
- `artifacts/specs/2026-04-28-beads-rust-replacement/03-store-api-and-adapter.md` defines missing JSON CLI commands: `health`, `schema-check`, `create-card`, `create-cards`, `update-card`, `delete-card`, `close-card`, `show-card`, `list-cards`, `search-biblio`, `label-add`, `label-remove`, `edge-add`, `edge-remove`, and `edge-list`.
- `artifacts/specs/2026-04-28-beads-rust-replacement/04-migration-cutover-and-verification.md` requires snapshots, import summaries, parity reports, warning streams, rollback manifests, shadow-read, shadow-write, and native-primary gates.
- `artifacts/specs/2026-04-28-beads-rust-replacement/05-viewer-export-and-consumers.md` requires current MCP/SAI payload stability and two viewer export modes: issue-shaped compatibility export and card-native export.
- Current Rust schema is v1 only. `apps/silmari_memory_rust/src/schema.rs:57` creates `cards` without `status`, `priority`, `scope`, or `deleted_at`; `apps/silmari_memory_rust/src/schema.rs:88` creates `card_edges` without review state or event metadata.
- Current Rust store exposes retrieval/import helpers, not a live write API. `apps/silmari_memory_rust/src/store.rs:17` does `INSERT OR REPLACE` card writes and `apps/silmari_memory_rust/src/store.rs:50` deletes and reinserts labels, so it does not yet preserve immutable creation, tombstone behavior, same-transaction events, or add/remove label semantics.
- Current Rust CLI is retrieval/import-only. `apps/silmari_memory_rust/src/cli.rs:24` has `init`, `import-beads`, `recall`, `neighborhood`, `edges`, and `line-of-thought`, but none of the live store commands required by the adapter spec.
- Current TypeScript compatibility behaviors are non-negotiable: `brCreate` returns `id | null` at `apps/silmari-mcp/src/lib/br-adapter.ts:167`, `brUpdate` returns `boolean` at `apps/silmari-mcp/src/lib/br-adapter.ts:289`, `brList` returns `[]` except timeout at `apps/silmari-mcp/src/lib/br-adapter.ts:348`, and `brShow` returns exact row or `null` at `apps/silmari-mcp/src/lib/br-adapter.ts:437`.
- `BrListTimeoutError` is an observable distinction. It is defined at `apps/silmari-mcp/src/lib/br-adapter.ts:50` and pinned by `apps/silmari-mcp/tests/br-adapter.test.ts:281`.
- `brShow` must reject fuzzy matches and structured error payloads. The behavior is implemented at `apps/silmari-mcp/src/lib/br-adapter.ts:463` and `apps/silmari-mcp/src/lib/br-adapter.ts:470`, with tests at `apps/silmari-mcp/tests/br-adapter.test.ts:115` and `apps/silmari-mcp/tests/br-adapter.test.ts:152`.
- `fromAddress` is validated before duplicate/body-hash logic and must hard-fail for genuine missing or ambiguous targets. The resolver is at `apps/silmari-mcp/src/lib/card-ops.ts:703`, with happy-path and error tests in `apps/silmari-mcp/tests/zk-save-card-fromaddress.test.ts:68`.
- `card-ops.ts` currently bypasses `br-adapter.ts` for label lookup. It imports `findBeadsByLabel` from `apps/silmari-mcp/src/lib/br-sqlite.ts` at `apps/silmari-mcp/src/lib/card-ops.ts:33`, then uses it for duplicate lookup at `apps/silmari-mcp/src/lib/card-ops.ts:473`, Tier A parent lookup at `apps/silmari-mcp/src/lib/card-ops.ts:585`, and `fromAddress` resolution at `apps/silmari-mcp/src/lib/card-ops.ts:717`. Native-primary cannot leave these reads pointed at legacy `beads.db`.
- Body-hash recurrence creates another card and emits `reinforces` plus consolidation labels, rather than deduplicating. See `apps/silmari-mcp/src/lib/card-ops.ts:800` and post-save emission at `apps/silmari-mcp/src/lib/card-ops.ts:620`.
- All 12 Silmari edge types matter. TypeScript defines AUTO and REVIEWED tiers at `apps/silmari-mcp/src/lib/labels.ts:79`, `apps/silmari-mcp/src/lib/labels.ts:89`, and `apps/silmari-mcp/src/lib/labels.ts:97`.
- `blocks` is both a Silmari semantic edge and the only dependency-compatible mirror. The current adapter whitelist begins at `apps/silmari-mcp/src/lib/br-adapter.ts:118`, and `addEdge` mirrors `blocks` at `apps/silmari-mcp/src/lib/edges.ts:91`.
- Current viewer compatibility consumes denormalized `issues.labels` from exported cache, not raw Beads `labels`. `apps/silmari-memory-card-viewer/server.ts:149` reads `SELECT id, labels FROM issues`, and `apps/silmari-viewer/pkg/export/sqlite_schema.go:41` creates that issue-shaped export table.
- Viewer graph links merge `dependencies` and `card_edges` while preserving edge `type`; see `apps/silmari-memory-card-viewer/viewer_assets/link-builder.js:17`.
- Current viewer exporter writes `dependencies` as blocking edges only; graph layout export also filters to blocking dependencies, so semantic edges must live in `card_edges` / `viewer_edges`, not in `dependencies`.
- `apps/silmari-mcp/src/index.ts:352` has schema text drift for `zk_block` that says `ref:blocked-by:<id>`, while the dispatcher at `apps/silmari-mcp/src/index.ts:716` writes the canonical `blocks` edge. The native plan must pin the dispatcher behavior and fix or test the schema wording.
- SAI consumers depend on MCP-shaped recall summaries, not direct DB access. `SAI/hooks/ThinkWithMemory.hook.ts:95` returns `entryCards`, `folgezettelNeighbors`, and `crossRefs`, while `SAI/hooks/lib/think-with-memory.ts:190` persists `keywordEntries`, `folgezettelNeighbors`, and `crossRefs`; adapter parity must cover key casing and shape.
- Prior review issue `silmari-agent-memory-7jo` is accepted as an implementation gate: underscore keyword normalization, all 12 edge types with tier gate, `trunkSeeds` in line-of-thought, explicit schema-evolution framing for `fz_address` and `trunk`, and a Beads field disposition table.

### Registry And Schema Reality Check

The create-tdd-plan workflow requires `specs/schemas/resource_registry.json`, but this repository does not contain that file. Root-level `schema/`, `schemas/`, and `specs/schemas/` are also absent. The only schema directory found is `vendor/beads_rust/agent_baseline/schemas/`, which is vendor Beads baseline material, not a Silmari resource registry.

Therefore every behavior below uses `[PROPOSED]` resource identities and stable aliases. Each behavior still includes:

- `resource_id`
- `address_alias`
- `predicate_refs`
- `codepath_ref`
- `schema_contract_refs`
- required function-level contract tags to make future registry backfill mechanical

### CW9 Artifact Binding And Pre-Implementation Gate

CW9 project root: `/home/maceo/Dev/silmari-agent-memory`

Current `cw9 status --json` on 2026-04-28 reports 8 registered GWTs, 8 verified loops, 0 pending loops, and 8 completed bridge artifacts. However, the 2026-04-28 coverage review found that this existence/verification status is not sufficient for implementation. The pre-implementation gate is **blocked** until the coverage remediations below are completed and a follow-up coverage review passes.

| GWT | Behavior | Plan section | depends_on UUIDs | Current artifact state |
| --- | --- | --- | --- | --- |
| `gwt-0001` | `schema_v2_migration_gate` | Behavior 1 | `dbd532d0` `init_schema` @ `apps/silmari_memory_rust/src/schema.rs:22` | coverage pass after remediation: generated tests pin schema owners, replay success/rejection traces, and run the real `schema_v2` Rust gate for v1 upgrade/no-partial/future-version behavior |
| `gwt-0002` | `edge_authority_gate` | Behavior 2 | `048510c5` `parse_labels` @ `apps/silmari_memory_rust/src/labels.rs:66`; `ce391b3b` `insert_edge` @ `apps/silmari_memory_rust/src/store.rs:64`; `56a8d647` `addEdge` @ `apps/silmari-mcp/src/lib/edges.ts:76`; `943ec4bf` `proposeOrAddEdge` @ `apps/silmari-mcp/src/lib/edges.ts:403`; `0b394571` `import_beads_box_into_conn` @ `apps/silmari_memory_rust/src/importer.rs:35` | coverage pass; bridge-only `AllInvariants` is a composite helper, not separate TLC proof |
| `gwt-0003` | `native_create_postsave_gate` | Behaviors 3 and 5 | `3487392d` `saveCard` @ `apps/silmari-mcp/src/lib/card-ops.ts:786`; `42d22bf8` `runPostSaveSteps` @ `apps/silmari-mcp/src/lib/card-ops.ts:551`; `1ff54aa0` `brCreate` @ `apps/silmari-mcp/src/lib/br-adapter.ts:187`; `19727657` `insert_card` @ `apps/silmari_memory_rust/src/store.rs:17`; `decd400a` `saveCardsBatch` @ `apps/silmari-mcp/src/lib/card-ops.ts:948` | complete: spec/cfg/traces/bridge/test/context present |
| `gwt-0004` | `cli_envelope_open_policy_gate` | Behavior 11 | `2a3e3b3d` `run` @ `apps/silmari_memory_rust/src/cli.rs:159`; `3916704b` `recall` @ `apps/silmari_memory_rust/src/retrieval.rs:123`; `d7d88c14` `line_of_thought` @ `apps/silmari_memory_rust/src/retrieval.rs:330`; `8a8af46f` `line_of_thought_at_address` @ `apps/silmari_memory_rust/src/retrieval.rs:346` | coverage pass after remediation: model/bridge/context/traces/tests use current `NativeEnvelope<T>` and stable adapter codes only, with stale-code absence asserted by `test_gwt_0004_artifacts_do_not_use_stale_adapter_codes` |
| `gwt-0005` | `migration_snapshot_staging_gate` | Behaviors 6A and 6 | `6869a633` `import_beads_box` @ `apps/silmari_memory_rust/src/importer.rs:23`; `0b394571` `import_beads_box_into_conn` @ `apps/silmari_memory_rust/src/importer.rs:35`; `12357492` `import_block_dependencies` @ `apps/silmari_memory_rust/src/importer.rs:249`; `0c3fed87` `import_keyword_entries` @ `apps/silmari_memory_rust/src/importer.rs:274`; `19727657` `insert_card` @ `apps/silmari_memory_rust/src/store.rs:17`; `ce391b3b` `insert_edge` @ `apps/silmari_memory_rust/src/store.rs:64` | coverage pass; bridge-only `AllInvariants` is a composite helper, not separate TLC proof |
| `gwt-0006` | `ts_facade_observability_gate` | Behavior 7 and 8 | `1ff54aa0` `brCreate` @ `apps/silmari-mcp/src/lib/br-adapter.ts:187`; `9e8c7ac9` `brList` @ `apps/silmari-mcp/src/lib/br-adapter.ts:368`; `cdf8a01b` `brShow` @ `apps/silmari-mcp/src/lib/br-adapter.ts:457`; `03d60a50` `brSearch` @ `apps/silmari-mcp/src/lib/br-adapter.ts:416` | coverage pass after remediation: generated tests cover every facade invariant, assert bridge TLC flags, replay native/legacy/shadow traces, and pin adapter file ownership/import gates |
| `gwt-0007` | `viewer_export_contract_gate` | Behavior 10 | `d196bdde` `synthesizeEdgesFromLabels` @ `apps/silmari-memory-card-viewer/server.ts:141`; `e43905e6` `buildLinks` @ `apps/silmari-memory-card-viewer/viewer_assets/link-builder.js:17`; `86802258` `CreateSchema` @ `apps/silmari-viewer/pkg/export/sqlite_schema.go:16`; `e7c8c497` `CreateMaterializedViews` @ `apps/silmari-viewer/pkg/export/sqlite_schema.go:211`; `12357492` `import_block_dependencies` @ `apps/silmari_memory_rust/src/importer.rs:249` | coverage pass; bridge-only `AllInvariants` is a composite helper, not separate TLC proof |
| `gwt-0008` | `sai_recall_shim_gate` | Behavior 12 | `c1f41f77` `loadZkRecall` @ `SAI/hooks/ThinkWithMemory.hook.ts:117`; `f740ed31` `buildInjection` @ `SAI/hooks/lib/think-with-memory.ts:218`; `f69c0e96` `lookupKeyword` @ `apps/silmari-mcp/src/lib/keyword-index.ts:253`; `63352abf` `lineOfThought` @ `apps/silmari-mcp/src/lib/line-of-thought.ts:187`; `061bdb06` `loadRecallScan` @ `apps/silmari-mcp/src/lib/navigate.ts:702`; `3916704b` `recall` @ `apps/silmari_memory_rust/src/retrieval.rs:123` | coverage pass; bridge-only `AllInvariants` is a composite helper, not separate TLC proof |

Coverage-blocking artifact remediation gate:

```bash
cw9 status /home/maceo/Dev/silmari-agent-memory --json
cw9 test /home/maceo/Dev/silmari-agent-memory
pytest tests/generated/test_gwt_0001.py tests/generated/test_gwt_0004.py tests/generated/test_gwt_0006.py
```

Required remediation results before implementation starts:

- `gwt-0001` generated tests load `.cw9/specs/gwt-0001_sim_traces.json`, replay the migration operation sequence, seed a real native v1 DB, and assert `NoPartialMigration` and `V1FullyUpgraded`.
- `gwt-0004` `.tla`, `.cfg`, bridge JSON, context, traces, and generated test use only the current plan's `NativeEnvelope<T>` and adapter error codes: `CARD_NOT_FOUND`, `QUERY_TIMEOUT`, `VALIDATION_ERROR`, `SCHEMA_INCOMPATIBLE`, `DB_NOT_FOUND`, and `CLI_PARSE`.
- `gwt-0004` generated tests assert success envelopes contain `ok: true` and `result`, failures contain `ok: false` and stable uppercase `error.code`, read commands do not create missing DBs, write commands use read/write or staging open policy, empty success results are distinguishable from errors, and facade classification does not inspect raw stderr.
- `gwt-0006` generated tests assert every `.cfg` invariant: `BrCreateReturnsStringOrNull`, `BrListTimeoutDistinct`, `BrListNonTimeoutReturnsRows`, `BrShowNoFuzzyMatch`, `BrShowExactOrNull`, `BrSearchBiblioOriented`, `BrSearchNotIdeaRecall`, `LabelLookupNativeNoLegacyDb`, `NoNativeInternalImport`, `NoBrSqliteDirectImport`, and `ModePreservesSignature`.
- Bridge-only helpers are classified explicitly and not counted as TLC-backed proof unless they are named in `.cfg`.
- A follow-up coverage review reports full coverage or documents only non-blocking helper classifications.

Abstraction-remediation context requirements before implementation starts:

- `.cw9/context/gwt-0001.md` must name the same schema entrypoints as Behavior 1: `init_schema`, `open_or_migrate`, `migrate_v1_to_v2`, and `store::open_native -> open_or_migrate`.
- `.cw9/context/gwt-0002.md` must include the `AcceptedReviewManifest` schema and validation rules from Behavior 2.
- `.cw9/context/gwt-0003.md` must include the native post-save single-owner rule from Behavior 3.
- `.cw9/context/gwt-0006.md` must include the adapter file ownership split from Behavior 7.
- A follow-up abstraction review must pass after these context files and any regenerated bridge/generated tests are updated.

Formal proof surface classification:

| GWT | TLC-backed standalone proof targets | Bridge-only helper/verifier entries |
| --- | --- | --- |
| `gwt-0001` | `FutureVersionNeverMutated`, `NoPartialMigration`, `V1FullyUpgraded`, `SecondOpenIdempotent`, `FutureVersionRejectedCorrectly`, `V2OpenRemainsStable`, `AllInvariants` | none |
| `gwt-0002` | `AutoEdgeBecomesLive`, `ReviewedAgentEdgeQueued`, `ImportedReviewedEdgePending`, `CompatFacadeIsolated`, `ReviewedLiveRequiresAuthority` | `AllInvariants` |
| `gwt-0003` | `ValidPhase`, `NoPartialCommit`, `FromAddressValidationPrecedesDedupe`, `NoPostSaveWithoutCreate`, `PostSaveRunsAfterCreate`, `NoPostSaveOnCreateFailure`, `AtomicEventedDurableOnSuccess`, `BrCompatIdOrNull`, `BrCompatMatchesCreate`, `TypedErrorMapsToNullResult`, `SaveCardShapeStable`, `SaveCardFieldTypes`, `RecurrenceStillCreatesDurableCard`, `GivenWhenThenGuarantees` | none |
| `gwt-0004` | `SuccessEnvelopeHasResult`, `ErrorEnvelopeHasCode`, `ReadMissingDBNoCreate`, `WriteRequiresWritePolicy`, `ErrorCodesAreStable`, `FacadeCanClassify`, `EmptyResultDistinguishable` | `ValidErrorCodes`, `AllInvariants` |
| `gwt-0005` | `SourceReadonlyAfterSnapshot`, `NoTargetMutationBeforePromote`, `FailedValidationNoPromote`, `NoReplaceModePreventsPromote`, `DryRunModePreventsPromote`, `ReportExistsAtTerminal`, `MalformedKeywordsReported`, `BlocksDirectionPreserved`, `StagingBeforePromote`, `SnapshotBeforeStaging`, `SnapshotBeforeValidation` | `AllInvariants` |
| `gwt-0006` | `BrCreateReturnsStringOrNull`, `BrListTimeoutDistinct`, `BrListNonTimeoutReturnsRows`, `BrShowNoFuzzyMatch`, `BrShowExactOrNull`, `BrSearchBiblioOriented`, `BrSearchNotIdeaRecall`, `LabelLookupNativeNoLegacyDb`, `NoNativeInternalImport`, `NoBrSqliteDirectImport`, `ModePreservesSignature` | `AllInvariants` |
| `gwt-0007` | `AllRequiredTablesPresent`, `SemanticEdgesInCardEdgesOnly`, `BlocksEdgesInDependencies`, `BlocksDirectionPreserved`, `CardEdgesColumnsCorrect`, `LabelSynthesisIdempotentFallback`, `BuildLinksDirectionConsistent`, `IssueOverviewMvPresent`, `ExportMetaPresent`, `BoundedExecution` | `AllInvariants` |
| `gwt-0008` | `ShimOutputNoEntryCards`, `ShimOutputNoLifecycleFields`, `KeywordEntriesKeyStable`, `FolgezettelNeighborsKeyStable`, `CrossRefsKeyStable`, `SaiReceivesNormalizedShape`, `EmptyDataDegradesPredictably`, `NativeRustDoesNotLeakStorageFields`, `BothSourcesConvergeOnRecallSummaryShape`, `BoundedExecution` | `AllInvariants` |

The implementation handoff may include `.cw9/specs/<gwt>.tla`, `.cw9/specs/<gwt>_sim_traces.json`, `.cw9/bridge/<gwt>_bridge_artifacts.json`, and generated test paths for every GWT only after this remediation gate passes. Until then, the old artifact set is a stale input, not an implementation authority.

## Assumed Existing Contracts

The boundary review found that this plan previously relied on several implicit contracts. They are now classified here so implementation cannot treat planned producer files as existing infrastructure.

| Boundary | Classification | Producer | Consumer | Current source reality | Required plan action |
| --- | --- | --- | --- | --- | --- |
| BC-1 Rust CLI to TypeScript adapter | planned | `apps/silmari_memory_rust/src/cli.rs` command surface | `apps/silmari-mcp/src/lib/native-adapter.ts` and `br-adapter.ts` facade | Rust CLI currently exposes retrieval/import commands only, emits raw success JSON plus `{error}`, and `native-adapter.ts` is absent | First implementation slice adds `native-adapter.ts`, complete CLI command surface, `NativeEnvelope<T>`, and `apps/silmari-mcp/tests/native-cli-contract.test.ts` that spawns the real binary |
| BC-2 MCP dispatch/resource to facade | existing-but-to-be-replaced | `apps/silmari-mcp/src/index.ts::{dispatchTool,dispatchResource}` | `apps/silmari-mcp/src/lib/br-adapter.ts` public facade | Current handlers and `card-ops.ts` still call legacy functions and `br-sqlite.ts` paths directly | Behavior 7 routes real dispatch/resource paths through the facade and proves it with `native-mcp-dispatch-contract.test.ts` |
| BC-3 runtime mode config to facade and SAI | planned | `apps/silmari-mcp/src/lib/native-mode.ts` resolver | `br-adapter.ts`, shadow layer, and public SAI client | `native-mode.ts` is absent and current `br-adapter.ts` is not a mode switch | Behavior 12 defines `NativeModeConfig` and proves env/config precedence through `native-mode-config-contract.test.ts` |
| BC-4 shadow parity layer | planned | `br-adapter.ts` facade starts dual execution | `native-shadow.ts`, `legacy-br-adapter.ts`, `native-adapter.ts`, Rust parity/report helpers | `native-shadow.ts`, `legacy-br-adapter.ts`, `native-adapter.ts`, and Rust `parity.rs` are not all real today | Behavior 8 adds real dual-branch execution and `native-shadow-contract.test.ts` with reconciliation JSONL assertions |
| BC-5 snapshot creator to importer | planned | `create-snapshot --json` and `migration.rs` | `import-snapshot --json` and `importer.rs` | `migration.rs` is absent and current importer opens source/target directly | Behaviors 6A and 6 add CLI-level snapshot-to-import transcript tests in `import_snapshot_cli_contract.rs` |
| BC-6 `AcceptedReviewManifest` to importer/store | planned | operator-supplied `AcceptedReviewManifest` | importer validation and `EdgeWriteAuthority::AcceptedProposal` | Current importer parses labels and calls `insert_edge` directly | Behaviors 2 and 6 require manifest hash validation before accepted reviewed-edge promotion |
| BC-7 Rust viewer export to current viewer | existing consumer, planned producer | Rust `export_viewer_compat` | current viewer server/browser query and `link-builder.js` | Current Go export lacks `card_edges`; current server synthesizes `card_edges` from labels; Rust export is absent | Behavior 10 writes a Rust compatibility cache and runs current viewer query/link-builder tests without relying on label synthesis |
| BC-8 SAI public memory shim | existing-but-to-be-replaced | public `SaiMemoryClient` shim backed by MCP/facade recall | `ThinkWithMemory` hook and `buildInjection` | Current local shim normalizes shape but still loads low-level MCP internals; tests inject recall implementations | Behavior 12 requires `SAI/hooks/tests/think-with-memory-native-boundary.test.ts` to prove native-mode public shim use and no low-level imports |

### Boundary Transcript Gate

Each non-trivial boundary above must have one source-backed transcript before native-primary rollout. A transcript is source-backed only when both the real producer and the real consumer execute in the same test or smoke flow. Mock-only or harness-only calls may remain useful unit coverage, but they do not satisfy this gate.

Required transcript tests:

- `apps/silmari-mcp/tests/native-cli-contract.test.ts`: `NativeCliAdapter` builds or locates the Rust binary, spawns it for `show-card`, `list-cards`, and `create-card`, parses real `NativeEnvelope<T>` success and failure payloads, maps `CARD_NOT_FOUND`, `VALIDATION_ERROR`, `QUERY_TIMEOUT`, and `DB_NOT_FOUND`, and verifies missing read DB paths are still absent after read commands.
- `apps/silmari-mcp/tests/native-mcp-dispatch-contract.test.ts`: real `dispatchTool("zk_save_card")`, `dispatchTool("zk_recall")`, `dispatchTool("zk_block")`, and `dispatchResource("silmari://card/<id>")` run in `native-primary` with legacy Beads DB paths missing and prove native DB reads/writes through the facade.
- `apps/silmari-mcp/tests/native-mode-config-contract.test.ts`: env/config/default precedence drives public `br-adapter.ts` exports, invalid config returns `ModeConfigError` and blocks writes, and rollback flips only config or env.
- `apps/silmari-mcp/tests/native-shadow-contract.test.ts`: shadow-write executes a real legacy write and a real native write, then writes reconciliation JSONL on mismatch with operation input hash, result hashes, replay instruction, and rollback note.
- `apps/silmari_memory_rust/tests/import_snapshot_cli_contract.rs`: command execution runs `create-snapshot --json`, consumes that manifest through `import-snapshot --json`, validates target mutation happens only after manifest checks, and validates accepted reviewed-edge manifest hash behavior.
- `apps/silmari-memory-card-viewer/tests/rust-compat-export-contract.test.ts` or an equivalent current viewer test: current viewer query functions and `link-builder.js` consume a Rust-produced compatibility cache with `card_edges`; the test disables or bypasses server-side label synthesis.
- `SAI/hooks/tests/think-with-memory-native-boundary.test.ts`: the hook or public shim loads native-mode memory through one public client, yields `{keywordEntries,folgezettelNeighbors,crossRefs}`, and asserts no low-level MCP modules are imported.

### First Implementation Slice

The first implementation slice after CW9 artifact regeneration is boundary scaffolding and contract tests, not durable store behavior. It must create the absent producer/adapter files and enough minimal behavior for the transcript tests to fail for meaningful contract reasons:

- `apps/silmari-mcp/src/lib/native-adapter.ts`
- `apps/silmari-mcp/src/lib/legacy-br-adapter.ts`
- `apps/silmari-mcp/src/lib/native-mode.ts`
- `apps/silmari-mcp/src/lib/native-shadow.ts`
- `apps/silmari-mcp/src/lib/sai-memory-client.ts`
- `apps/silmari_memory_rust/src/migration.rs`
- `apps/silmari_memory_rust/src/export.rs`
- `apps/silmari_memory_rust/src/parity.rs`
- `apps/silmari_memory_rust/src/report.rs`

A follow-up `04cw9-Plan-Review` is expected to remain blocked until this first slice exists. After that slice, the follow-up review must be able to derive source-backed transcripts for BC-1, BC-2, BC-3, BC-4, and BC-8 before implementation advances to native-primary behavior.

## Desired End State

The native Rust store owns durable Silmari memory state:

- `cards`
- `card_labels`
- `card_edges`
- `keyword_entries`
- `trunks`
- `folgezettel_cursors`
- `edge_proposals`
- `card_events`
- `card_notes`
- `schema_versions`

The TypeScript MCP layer continues to own MCP tool schemas, tool descriptions, resource payload shaping, and compatibility mapping. It does not own storage invariants after native-primary mode.

Rust exposes separate internal and external data contracts:

- `NativeCardRow` / `CardRow` includes v2 lifecycle and storage fields: `status`, `priority`, `scope`, `deleted_at`, event metadata, review metadata, and raw labels.
- `CompatCardPayload` is the `br-adapter.ts` row shape consumed by current TypeScript code and may expose status/priority where the current row already does.
- `RecallCardPayload`, `RecallSessionPayload`, `NeighborhoodPayload`, and `LineOfThoughtPayload` are MCP-facing serializers and must not leak newly introduced lifecycle/storage-only fields.
- Viewer serializers are separate from MCP serializers: `ViewerCompatIssueRow` writes issue-shaped cache rows and `ViewerNativeCardRow` writes card-native cache rows.

The compatibility facade preserves these current results:

| Current contract | Native compatibility result |
| --- | --- |
| `brCreate` | `string | null` |
| `brCreateBatch` / `saveCardsBatch` | ordered result array or throw on structural failure |
| `brUpdate`, `brClose`, `brDelete`, `brLabelAdd`, `brLabelRemove` | `true | false` |
| `brList`, `brSearch`, `brDepList` | rows or `[]` |
| `brList` timeout | throws `BrListTimeoutError` |
| `brShow` | exact row or `null`; no fuzzy match |
| `zk_save_card` | `{id,fz,wasReinforced,priorId,wasSweepDeleted}` |
| `zk_recall` | `{query,entryPoints,entryCards,neighborhoods,crossRefs}` |
| `zk_line_of_thought` | `{queried,parent,siblings,children,hubs,trunkSeeds,all,totalScope}` |

## What We Are Not Doing

- No generic Beads issue workflow parity beyond behavior currently consumed by Silmari.
- No Beads `LIKE` search as the idea recall primitive.
- No direct legacy `beads.db` reads outside the legacy adapter implementation once native/shadow modes are introduced.
- No removal of legacy Beads DBs during first native-primary rollout.
- No direct SAI import of Rust internals or low-level MCP storage modules; SAI continues through the public memory client shim.
- No deletion of issue-shaped viewer compatibility export until the card-native viewer has shipped through at least one dual-mode release.

## Testing Strategy

- Rust unit and integration tests: `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml`
- TypeScript MCP tests: `bun test apps/silmari-mcp/tests`
- Viewer tests: `bun test apps/silmari-memory-card-viewer/tests apps/silmari-memory-card-viewer/viewer_assets`
- Go viewer exporter tests where touched: `go test ./...` from `apps/silmari-viewer`
- Focused Rust test files to add or extend:
  - `apps/silmari_memory_rust/tests/schema_v2.rs`
  - `apps/silmari_memory_rust/tests/schema_v1_to_v2.rs`
  - `apps/silmari_memory_rust/tests/store_create.rs`
  - `apps/silmari_memory_rust/tests/store_read_update_delete.rs`
  - `apps/silmari_memory_rust/tests/store_batch.rs`
  - `apps/silmari_memory_rust/tests/edge_authority.rs`
  - `apps/silmari_memory_rust/tests/migration_snapshot.rs`
  - `apps/silmari_memory_rust/tests/import_migration.rs`
  - `apps/silmari_memory_rust/tests/import_snapshot_cli_contract.rs`
  - `apps/silmari_memory_rust/tests/adapter_cli_contract.rs`
  - `apps/silmari_memory_rust/tests/viewer_export.rs`
  - `apps/silmari_memory_rust/tests/viewer_export_queries.rs`
- Generated CW9 tests that must be regenerated or amended before implementation:
  - `tests/generated/test_gwt_0001.py` must load `gwt-0001_sim_traces.json`, replay the migration operation sequence, seed a real native v1 DB, and assert `NoPartialMigration` / `V1FullyUpgraded`.
  - `tests/generated/test_gwt_0004.py` must use current `NativeEnvelope<T>` and adapter error codes, and must not contain `DB_MISSING`, `PARSE_ERROR`, `sqlite`, `unknown_edge_type`, lowercase `cli_parse`, or raw success payload assertions outside `result`.
  - `tests/generated/test_gwt_0006.py` must cover every facade invariant from `.cw9/specs/gwt-0006.cfg`, not just timeout, prefix show, and one label-list smoke.
- Focused TypeScript tests to add or extend:
  - `apps/silmari-mcp/tests/native-adapter.test.ts`
  - `apps/silmari-mcp/tests/native-cli-contract.test.ts`
  - `apps/silmari-mcp/tests/native-mcp-dispatch-contract.test.ts`
  - `apps/silmari-mcp/tests/native-mode-config-contract.test.ts`
  - `apps/silmari-mcp/tests/native-mode-routing.test.ts`
  - `apps/silmari-mcp/tests/native-shadow-contract.test.ts`
  - `apps/silmari-mcp/tests/native-shadow-parity.test.ts`
  - `apps/silmari-mcp/tests/br-adapter.test.ts`
  - `apps/silmari-mcp/tests/zk-save-card-fromaddress.test.ts`
  - `apps/silmari-mcp/tests/zk-save-cards-batch.test.ts`
  - `apps/silmari-mcp/tests/zk-block-contract.test.ts`
  - `apps/silmari-mcp/tests/sai-think-with-memory-native.test.ts`
  - `SAI/hooks/tests/think-with-memory-native-boundary.test.ts`

## Behavior 1: Schema V2 Initializes The Live Native Store

### Resource Registry Binding

- `resource_id`: `[PROPOSED]`
- `address_alias`: `native.schema_v2`
- `predicate_refs`: native sqlite path, supported schema version, card-native table vocabulary
- `codepath_ref`: `apps/silmari_memory_rust/src/schema.rs::{init_schema,open_or_migrate,migrate_v1_to_v2}`; `apps/silmari_memory_rust/src/store.rs::open_native`
- `schema_contract_refs`: `artifacts/specs/2026-04-28-beads-rust-replacement/02-native-data-model.md::Core Tables`

### Schema Interface Mapping

- `loop_mode`: `summary`
- `mapped_contracts`: `NativeDataModelSpec.cards -> [PROPOSED] native.cards`; `NativeDataModelSpec.card_events -> [PROPOSED] native.card_events`; `NativeDataModelSpec.folgezettel_cursors -> [PROPOSED] native.folgezettel_cursors`
- `registry_updates`: `[PROPOSED] add schema_refs to native schema resources after registry exists`

### Test Specification

**Given**: a writable path with no native database  
**When**: schema initialization runs  
**Then**: the live native schema exists with all required tables, indexes, constraints, version rows, and no primary `issues` or `dependencies` tables

**Edge Cases**:

- Running initialization twice is idempotent.
- A future schema version returns a typed `SchemaCompatibility` error.
- A real native v1 DB migrates to complete v2 in one transaction; no v1 `schema_versions` rows remain stale after success.
- A partial or unknown native schema is rejected with `SchemaCompatibility` instead of being half-upgraded.
- `cards.box`, `cards.kind`, `cards.status`, `cards.priority`, `cards.trunk`, `cards.content_hash`, `card_edges.edge_type`, `card_edges.review_state`, and `keyword_entries.entry_points` reject invalid values.
- `fz_address` is unique among non-deleted idea cards.
- Default trunks `1` through `5` exist after init.
- Every new table has a schema version row.
- Required indexes exist: `cards(box,status,updated_at)`, `cards(content_hash)`, `card_edges(source_id,target_id,edge_type)`, `card_edges(edge_type)`, `card_events(card_id,created_at)`, and `keyword_entries(term)`.

### TDD Cycle

#### Red: Write Failing Test

**File**: `apps/silmari_memory_rust/tests/schema_v2.rs`

```rust
#[test]
fn init_creates_live_native_schema_v2() {
    let db = temp_db_path();
    let conn = silmari_memory_rust::schema::open_or_migrate(&db).unwrap();

    assert_has_tables(&conn, &[
        "cards",
        "card_labels",
        "card_edges",
        "keyword_entries",
        "trunks",
        "folgezettel_cursors",
        "edge_proposals",
        "card_events",
        "card_notes",
        "schema_versions",
    ]);
    assert_missing_tables(&conn, &["issues", "dependencies"]);
    assert_column(&conn, "cards", "status");
    assert_column(&conn, "cards", "priority");
    assert_column(&conn, "cards", "scope");
    assert_column(&conn, "cards", "deleted_at");
    assert_column(&conn, "card_edges", "review_state");
    assert_column(&conn, "card_edges", "created_at");
}

#[test]
fn native_v1_schema_migrates_to_complete_v2_or_rejects_partial_schema() {
    let db = temp_db_path();
    seed_real_native_v1_schema(&db);

    let conn = silmari_memory_rust::schema::open_or_migrate(&db).unwrap();

    assert_schema_version(&conn, "cards", 2);
    assert_schema_version(&conn, "card_edges", 2);
    assert_column(&conn, "cards", "status");
    assert_column(&conn, "cards", "priority");
    assert_column(&conn, "cards", "scope");
    assert_column(&conn, "cards", "deleted_at");
    assert_column(&conn, "card_edges", "review_state");
    assert_index(&conn, "idx_cards_box_status_updated");
    assert_index(&conn, "idx_card_events_card_created");
}

#[test]
fn failed_or_partial_v1_migration_leaves_no_half_upgraded_schema() {
    let db = temp_db_path();
    seed_real_native_v1_schema(&db);
    inject_migration_failure_at(&db, "after_cards_alter_before_version_rows");

    let err = silmari_memory_rust::schema::open_or_migrate(&db).unwrap_err();
    assert_eq!(err.code(), ErrorCode::SchemaIncompatible);

    let conn = rusqlite::Connection::open(db).unwrap();
    assert_schema_version(&conn, "cards", 1);
    assert_missing_column(&conn, "card_edges", "review_state");
    assert_no_schema_version(&conn, 2);
}

#[test]
fn generated_gwt_0001_trace_replay_covers_all_migration_outcomes() {
    let traces = load_cw9_traces("gwt-0001");
    assert_trace_outcome_exists(&traces, |final_state| {
        final_state.initial_db_version == 1
            && final_state.result == "ok"
            && final_state.v2_schema_applied
            && final_state.version_row_v2
    });
    assert_trace_outcome_exists(&traces, |final_state| {
        final_state.initial_db_version > 2
            && final_state.result == "SCHEMA_INCOMPATIBLE"
            && !final_state.v2_schema_applied
    });
    assert_every_trace_asserts_operations(&traces, &[
        "FirstOpen",
        "CheckVersion",
        "AfterVersionCheck",
        "StartMigration",
        "ApplyV2DDL",
        "CommitMigration",
        "MaybeRetry",
        "SecondOpenCheck",
        "SecondOpenCurrent",
        "Terminate",
    ]);
}
```

#### Green: Minimal Implementation

**Files**:

- `apps/silmari_memory_rust/src/schema.rs`
- `apps/silmari_memory_rust/src/model.rs`
- `apps/silmari_memory_rust/src/store.rs`

Add migration-aware schema creation for all v2 tables and indexes. Bump `SUPPORTED_SCHEMA_VERSION`. The schema entrypoint ownership is pinned and must not be left to implementation choice:

- `init_schema(conn)` creates or verifies an empty/current v2 database on an already-open connection. It is not the general existing-DB open path.
- `open_or_migrate(path)` is the public open path for native Silmari DBs. It opens the DB, checks `schema_versions`, rejects future/partial/unknown schemas without mutation, and runs versioned migrations when supported.
- `migrate_v1_to_v2(conn)` is the only v1-to-v2 migration owner. It performs all v2 DDL/backfill/version-row updates in one transaction.
- `store::open_native(path)` must call `open_or_migrate(path)`, not directly call a create-only helper.
- Standalone `CREATE TABLE IF NOT EXISTS` or `ALTER TABLE` statements outside a versioned migration are forbidden for existing DB upgrades.

The pinned transition policy is:

- Empty DB: create v2 schema and default trunks.
- Native v1 DB detected by `schema_versions` and expected v1 tables: run `migrate_v1_to_v2` inside one transaction, add/backfill lifecycle columns, create new tables/indexes, and update all version rows to v2.
- Future version or partial/unknown schema: return `SchemaCompatibility { found, supported }` / `SCHEMA_INCOMPATIBLE`; never create missing columns with `CREATE TABLE IF NOT EXISTS` alone.
- Legacy Beads DBs are not initialized in place; they enter through snapshot/import behaviors only.

**Documentation Contract**:

```rust
/// @rr.id [PROPOSED]
/// @rr.alias native.schema_v2
/// @path.id init-native-schema-v2
/// @gwt.given a writable sqlite path and no or supported native Silmari schema
/// @gwt.when schema initialization runs
/// @gwt.then the card-native live-store schema exists with version rows and constraints
/// @reads [PROPOSED] native.schema_versions
/// @writes [PROPOSED] native.cards,native.card_labels,native.card_edges,native.keyword_entries,native.trunks,native.folgezettel_cursors,native.edge_proposals,native.card_events,native.card_notes,native.schema_versions
/// @raises [PROPOSED]:SchemaCompatibility
/// @schema.contract artifacts/specs/2026-04-28-beads-rust-replacement/02-native-data-model.md::Core Tables
pub fn init_schema(conn: &rusqlite::Connection) -> crate::Result<()>;

/// Public native DB open path. This function owns version detection and migration.
pub fn open_or_migrate(path: &Path) -> crate::Result<rusqlite::Connection>;

/// Versioned migration owner for supported native v1 databases.
pub fn migrate_v1_to_v2(conn: &mut rusqlite::Connection) -> crate::Result<MigrationSummary>;
```

#### Refactor: Improve Code

- Move table DDL into named constants so tests can snapshot table lists without string searching.
- Centralize enum value arrays in `model.rs` so schema checks and `FromStr` stay aligned.
- Keep `init_schema`, `open_or_migrate`, and `migrate_v1_to_v2` separately testable so generated `gwt-0001` trace replay cannot accidentally exercise a create-only path.
- Add helper assertions in `tests/common`.

### Success Criteria

Automated verification:

- `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml schema_v2`
- `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml schema_v1_to_v2`
- `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml schema_init`

Manual verification:

- Inspect a temp DB with `sqlite3 .schema` and verify no primary issue-tracker tables were created.

## Behavior 2: Labels And Edge Tiers Project To Native Fields

### Resource Registry Binding

- `resource_id`: `[PROPOSED]`
- `address_alias`: `native.label_projection`
- `predicate_refs`: source label set, existing Silmari label namespace, closed card and edge vocabularies
- `codepath_ref`: `apps/silmari_memory_rust/src/labels.rs::parse_labels`; `apps/silmari_memory_rust/src/store.rs::project_labels`
- `schema_contract_refs`: `artifacts/specs/2026-04-28-beads-rust-replacement/02-native-data-model.md::Label Projection Diagram`

### Schema Interface Mapping

- `loop_mode`: `summary`
- `mapped_contracts`: `LabelProjection.rules -> [PROPOSED] native.card_labels`; `EdgeAPI.edge_type -> [PROPOSED] native.card_edges.edge_type`
- `registry_updates`: `[PROPOSED] native.label_projection`

### Test Specification

**Given**: labels including `box:*`, `kind:*`, `fz:*`, `trunk:*`, `scope:*`, `source:*`, `content_hash:*`, `keyword:*`, `upsert:*`, and `ref:<edge>:<target>`  
**When**: the parser and store projection run  
**Then**: native columns match labels, all original labels are preserved, valid auto-tier `ref:*` labels become `card_edges`, valid reviewed `ref:*` labels become pending proposals unless an explicit accepted authority is present, and reviewed edge types are not inserted as `auto` writes unless called through an explicit commit path

**Edge Cases**:

- `fz:2_3a1` round-trips to slash-form `2/3a1`.
- Unknown labels are preserved.
- Malformed `ref:*` labels become parse warnings, not fatal import errors.
- The edge enum covers all 12 Silmari values.
- `supports`, `contradicts`, `extends`, `reinforces`, and `refines` require review.
- Direct body-hash recurrence is the only planned exception that can create `reinforces` as reviewed evidence without a proposal.
- `scope:*` parses into `cards.scope` and regenerates from that native field.
- Native writes enforce card-edge referential integrity; imported unresolved edge targets become warnings/events without invalid `card_edges` rows.

### Edge Write Authority Contract

All edge writes carry an `EdgeWriteAuthority` so reviewed edge behavior is consistent across import, create, and edge-add:

| Authority | Allowed direct `card_edges` writes | Reviewed-edge behavior | Event/proposal result |
| --- | --- | --- | --- |
| `auto` | auto-tier edge types only | reviewed types become pending proposals | `edge.proposed` |
| `proposal` | none | always writes `edge_proposals(status='pending')` | `edge.proposed` |
| `accepted-proposal` | all 12 edge types | commits with `review_state='reviewed'` and proposal id/evidence | `edge.accepted` then `edge.added` |
| `body-hash-recurrence` | `reinforces` only | commits recurrence evidence as reviewed | `recurrence.reinforced` and `edge.added` |
| `imported-legacy` | auto-tier `ref:*` labels and `blocks` dependencies only | reviewed refs become `edge_proposals(status='pending', authority='imported-legacy')` with import evidence unless validated by an `AcceptedReviewManifest` | `import.reviewed_edge_proposed` |

Malformed or unresolved imported refs do not create edge rows; they preserve safe raw labels and emit warnings/events.

Legacy reviewed-edge trust policy: historical labels are migration evidence, not proof of current human acceptance. The importer must not silently elevate legacy `supports`, `contradicts`, `extends`, `reinforces`, or `refines` refs into live reviewed `card_edges`. To accept one during import, the source snapshot must contain a validated `AcceptedReviewManifest`; otherwise the edge remains pending in `edge_proposals` and the raw label is preserved.

### Accepted Review Manifest Contract

The accepted-review evidence format is explicit. Import code must not infer acceptance from labels, comments, file names, or undocumented sidecars.

`AcceptedReviewManifest` JSON:

```json
{
  "version": 1,
  "sourceSnapshotHash": "sha256:...",
  "acceptedEdges": [
    {
      "source": "zk-source",
      "target": "zk-target",
      "type": "refers-to",
      "authority": "operator",
      "reviewedBy": "operator-or-agent-id",
      "reviewedAt": "2026-04-28T00:00:00Z"
    }
  ]
}
```

Validation rules:

- Missing manifest means every imported reviewed ref remains a pending `edge_proposals` row.
- `version` must be `1`; unknown versions fail validation before promotion.
- `sourceSnapshotHash` must match the verified snapshot manifest hash being imported.
- `acceptedEdges[*].type` must be one of the 12 native edge types and must refer to existing imported cards.
- Duplicate accepted edge tuples are idempotent only when all authority metadata matches; conflicting duplicates fail validation.
- `authority` must be `operator` or another explicitly enumerated trusted authority value added by a future plan revision; free-form authority strings are invalid.
- `reviewedBy` and `reviewedAt` are required for every accepted reviewed edge.
- Accepted reviewed edges are committed through the same `EdgeWriteAuthority::AcceptedProposal` gate as runtime accepted proposals, not by direct `insert_edge`.
- Import reports must count accepted, pending, refused, duplicate, invalid-target, invalid-type, and invalid-authority reviewed edges separately.

### Data Relationship And State Transition Contract

Hard card deletion is not part of normal runtime behavior. `delete-card` and imported Beads tombstones set `cards.status='deleted'` plus `cards.deleted_at`; live queries filter tombstoned cards by default. Physical deletion is allowed only for abandoned staging databases before promotion or explicit test fixture cleanup.

| Table | Relationship contract | Delete/update behavior |
| --- | --- | --- |
| `card_labels.card_id` | FK to `cards.id` | `ON DELETE CASCADE` is allowed for abandoned staging/test cleanup; runtime tombstones do not cascade. |
| `card_edges.source_id`, `card_edges.target_id` | FK to `cards.id` | `ON DELETE RESTRICT` or `NO ACTION`; tombstoned cards hide edges in live views but preserve history. |
| `edge_proposals.source_id`, `edge_proposals.target_id` | FK to `cards.id` when target exists; unresolved import targets are warning records, not proposal targets | `ON DELETE RESTRICT` or `NO ACTION`; proposals are closed by status transition, not deleted. |
| `card_events.card_id` | FK to `cards.id` for card-scoped events; import run events may use nullable `card_id` plus `run_id` | no cascade in promoted DBs; event audit survives tombstones. |
| `card_notes.card_id` | FK to `cards.id` | `ON DELETE RESTRICT` or `NO ACTION`; notes are hidden through live-card filtering. |

`edge_proposals.status` values are `pending`, `accepted`, `rejected`, and `superseded`. Legal transitions are `pending -> accepted`, `pending -> rejected`, and `pending -> superseded`; terminal states do not reopen in place. Acceptance writes one `card_edges` row and one `edge.accepted` event in the same transaction, keyed by proposal id to make retries idempotent.

`card_events.actor` is structured JSON:

```json
{
  "kind": "system|agent|human|import",
  "id": "string",
  "source": "mcp|rust-cli|migration|sai",
  "sessionId": "optional string"
}
```

Import warning metadata is structured JSON:

```json
{
  "runId": "string",
  "sourcePath": "string",
  "sourceTable": "string",
  "sourceRowId": "string",
  "label": "optional string",
  "code": "MALFORMED_LABEL|UNRESOLVED_REF|REVIEWED_REF_PENDING|FIELD_DROPPED|SOURCE_HASH_MISMATCH",
  "message": "string"
}
```

### TDD Cycle

#### Red: Write Failing Test

**File**: `apps/silmari_memory_rust/tests/labels_projection.rs`

```rust
#[test]
fn parses_all_twelve_edges_and_preserves_review_tier() {
    let all = [
        ("follows", false),
        ("continues", false),
        ("branches", false),
        ("derives-from", false),
        ("blocks", false),
        ("refers-to", false),
        ("annotates", false),
        ("supports", true),
        ("contradicts", true),
        ("extends", true),
        ("reinforces", true),
        ("refines", true),
    ];

    for (wire, requires_review) in all {
        let edge = wire.parse::<silmari_memory_rust::model::EdgeType>().unwrap();
        assert_eq!(edge.as_str(), wire);
        assert_eq!(edge.requires_review(), requires_review);
    }
}

#[test]
fn scope_label_projects_and_reviewed_edges_require_authority() {
    let parsed = silmari_memory_rust::labels::parse_labels(&[
        "scope:workspace".into(),
        "ref:supports:zk-target".into(),
    ]).unwrap();
    assert_eq!(parsed.scope.as_deref(), Some("workspace"));

    let harness = NativeHarness::with_cards([card("zk-source"), card("zk-target")]);
    let proposal = harness.store().edge_add(EdgeAddInput {
        source_id: "zk-source".into(),
        target_id: "zk-target".into(),
        edge_type: EdgeType::Supports,
        authority: EdgeWriteAuthority::Auto,
    }).unwrap();

    assert!(proposal.edge_id.is_none());
    assert_eq!(proposal.proposal_status.as_deref(), Some("pending"));
    assert_no_card_edge(&harness.conn, "zk-source", "zk-target", "supports");
}

#[test]
fn accepted_review_manifest_is_snapshot_bound_and_authority_checked() {
    let manifest = AcceptedReviewManifest::from_json(json!({
        "version": 1,
        "sourceSnapshotHash": "sha256:expected",
        "acceptedEdges": [{
            "source": "zk-source",
            "target": "zk-target",
            "type": "supports",
            "authority": "operator",
            "reviewedBy": "human-1",
            "reviewedAt": "2026-04-28T00:00:00Z"
        }]
    })).unwrap();

    let accepted = manifest.validate_for_snapshot("sha256:expected").unwrap();
    assert_eq!(accepted.edges.len(), 1);

    let wrong_snapshot = manifest.validate_for_snapshot("sha256:other").unwrap_err();
    assert_eq!(wrong_snapshot.code(), ErrorCode::SourceHashMismatch);
}
```

#### Green: Minimal Implementation

**Files**:

- `apps/silmari_memory_rust/src/model.rs`
- `apps/silmari_memory_rust/src/labels.rs`
- `apps/silmari_memory_rust/src/store.rs`
- `apps/silmari_memory_rust/src/importer.rs`

Extend `ParsedLabels` with `scope`; ensure label parsing preserves warnings; add `ReviewState`; make `store` project labels into columns and edge rows in one transaction.

Add `EdgeWriteAuthority` to every store path that can emit an edge. The store must reject missing native source/target IDs for normal writes, route unresolved imports to warnings, and store enough authority/evidence metadata to distinguish operator-reviewed edges from legacy accepted imports and body-hash recurrence.

Add `AcceptedReviewManifest` parsing and validation helpers close to import code, but keep commit authority in the store layer through `EdgeWriteAuthority::AcceptedProposal`.

**Documentation Contract**:

```rust
/// @rr.id [PROPOSED]
/// @rr.alias native.label_projection
/// @path.id parse-and-project-silmari-labels
/// @gwt.given a card id and Silmari-compatible label strings
/// @gwt.when labels are parsed and projected into native columns and edge rows
/// @gwt.then durable labels round-trip while native fields and typed edges match the label facts
/// @reads [PROPOSED] native.card_labels,native.card_edges
/// @writes [PROPOSED] native.cards,native.card_labels,native.card_edges,native.card_events
/// @raises [PROPOSED]:LabelParse
/// @schema.contract artifacts/specs/2026-04-28-beads-rust-replacement/02-native-data-model.md::Label Projection Diagram
pub fn project_labels(tx: &rusqlite::Transaction<'_>, card_id: &str, labels: &[String]) -> crate::Result<ParsedLabels>;
```

#### Refactor: Improve Code

- Use one source of truth for edge type arrays in both parser and schema validation.
- Add a projection diff helper so `label-add`, `label-remove`, and `update-card` do not duplicate logic.
- Keep warning payloads structured enough for `card_events` import warnings.

### Success Criteria

Automated verification:

- `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml labels_projection`
- `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml edge_authority`
- `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml accepted_review_manifest`
- Existing `apps/silmari_memory_rust/tests/labels.rs` still passes.

Manual verification:

- Compare edge values with `apps/silmari-mcp/src/lib/labels.ts:79` and viewer parse tests at `apps/silmari-memory-card-viewer/tests/server.test.ts:131`.

## Behavior 3: Single Native Create Is Atomic And Evented

### Resource Registry Binding

- `resource_id`: `[PROPOSED]`
- `address_alias`: `native.create_card`
- `predicate_refs`: validated card input, box prefix, label projection, optional folgezettel mode, body hash recurrence
- `codepath_ref`: `apps/silmari_memory_rust/src/store.rs::create_card`
- `schema_contract_refs`: `artifacts/specs/2026-04-28-beads-rust-replacement/02-native-data-model.md::Write Transaction Shape`; `artifacts/specs/2026-04-28-beads-rust-replacement/03-store-api-and-adapter.md::Compatibility Flow: Create Card`

### Schema Interface Mapping

- `loop_mode`: `summary`
- `mapped_contracts`: `create-card JSON -> native.cards,native.card_labels,native.card_edges,native.keyword_entries,native.folgezettel_cursors,native.card_events`
- `registry_updates`: `[PROPOSED] native.create_card`

### Test Specification

**Given**: a valid `create-card` request for an idea card  
**When**: the native store creates the card  
**Then**: the card ID prefix matches the box, folgezettel assignment and cursor update occur in the same transaction, labels and native columns agree, auto edges are inserted, keyword entries are updated, and a `card.created` event is appended

**Edge Cases**:

- Biblio cards get `bl-*` IDs, no folgezettel cursor mutation, and `kind:biblio`.
- Idea cards get `zk-*` IDs.
- `fromAddress` fork/continue targets the supplied historic address, not the trunk cursor.
- Missing `fromAddress` parent fails before body-hash recurrence or cursor mutation.
- Duplicate body creates a new card, emits `reinforces` through `EdgeWriteAuthority::BodyHashRecurrence`, sets `wasReinforced`, and labels both cards `needs-consolidation-review:true`.
- `allowOrphan` creates an explicit orphan event when no anchor exists.
- Any failure rolls back the whole transaction.

### Native Post-Save Ownership Contract

Native mode has one durable post-save owner. The existing TypeScript post-save helpers are legacy compatibility behavior unless explicitly running the legacy branch of a shadow mode.

- Rust `create_card` owns all durable native DB side effects for a successful create: keyword entries, content hash labels, folgezettel cursor movement, body-hash recurrence, accepted explicit edges, generated labels, and `card_events`.
- Body-hash recurrence must be detected and persisted inside Rust `create_card`.
  The native create transaction may reuse `commit_reviewed_edge(&mut Connection,
  ReviewedEdgeCommit)` internally with
  `EdgeWriteAuthority::BodyHashRecurrence`, but TypeScript native-primary code
  must not call `brCommitReviewedEdge`, `edge-commit`,
  `runPostSaveSteps`, or `emitReinforcesToPrior` for recurrence.
- TypeScript `saveCard` in native modes validates caller-facing MCP input, invokes the native create command, maps the native result into the existing `SaveCardResult` shape, and runs shadow/parity reporting when the selected runtime mode requires it.
- TypeScript `runPostSaveSteps`, `emitReinforcesToPrior`, direct Beads flush/rebuild, and direct `findBeadsByLabel` paths are legacy-only. They may run only inside the legacy branch for `legacy-br`, `shadow-read`, or `shadow-write`.
- A native-mode create path must not run both Rust native post-save effects and TypeScript legacy post-save effects for the same input.
- Batch create uses the same Rust transaction-local native post-save helpers as single create; it does not call TypeScript post-save hooks per row.

### TDD Cycle

#### Red: Write Failing Test

**File**: `apps/silmari_memory_rust/tests/store_create.rs`

```rust
#[test]
fn create_card_writes_state_and_event_in_one_transaction() {
    let harness = NativeHarness::new();
    let result = harness.store().create_card(CreateCardInput {
        box_name: CardBox::Idea,
        body: "native create atomic canary".into(),
        kind: CardKind::Learning,
        trunk: Some("5".into()),
        mode: FolgezettelMode::Root,
        labels: vec!["scope:test".into()],
        ..Default::default()
    }).unwrap();

    assert!(result.id.starts_with("zk-"));
    assert_eq!(result.fz.as_deref(), Some("5/1"));
    assert_card_label(&harness.conn, &result.id, "fz:5_1");
    assert_cursor(&harness.conn, "5", "1");
    assert_event(&harness.conn, &result.id, "card.created");
}

#[test]
fn native_create_owns_post_save_effects_without_typescript_replay() {
    let harness = NativeHarness::new();
    let first = harness.store().create_card(idea_input("same body", "5", FolgezettelMode::Root)).unwrap();
    let second = harness.store().create_card(idea_input("same body", "5", FolgezettelMode::Continue)).unwrap();

    assert_reinforces_edge(&harness.conn, &second.id, &first.id);
    assert_event(&harness.conn, &second.id, "recurrence.reinforced");
    assert_no_event(&harness.conn, &second.id, "legacy.post_save_replayed");
}
```

#### Green: Minimal Implementation

**Files**:

- `apps/silmari_memory_rust/src/model.rs`
- `apps/silmari_memory_rust/src/store.rs`
- `apps/silmari_memory_rust/src/folgezettel.rs`
- `apps/silmari_memory_rust/src/keyword_index.rs`
- `apps/silmari_memory_rust/src/edges.rs`

Implement `CreateCardInput`, `CreateCardResult`, `create_card`, ID allocation, cursor update, content hash labels, event append, and `fromAddress` validation.

`CreateCardResult` is the Rust native result; the TypeScript facade owns the `SaveCardResult`-compatible projection. Native create may return lifecycle/event diagnostics directly, but MCP-facing `zk_save_card` output remains `{id,fz,wasReinforced,priorId,wasSweepDeleted}`.

`create_card` must not reuse the existing `insert_card` helper as the public create implementation. `insert_card` may remain a fixture/import helper only if it cannot bypass events, edge authority, content-hash recurrence, or folgezettel cursor invariants.

**Documentation Contract**:

```rust
/// @rr.id [PROPOSED]
/// @rr.alias native.create_card
/// @path.id native-create-card-transaction
/// @gwt.given a valid Silmari card creation request and native database
/// @gwt.when create_card executes
/// @gwt.then card, labels, edges, keywords, cursors, and events commit atomically with SaveCardResult-compatible output
/// @reads [PROPOSED] native.cards,native.card_labels,native.folgezettel_cursors,native.keyword_entries
/// @writes [PROPOSED] native.cards,native.card_labels,native.card_edges,native.keyword_entries,native.folgezettel_cursors,native.card_events
/// @raises [PROPOSED]:ValidationError,[PROPOSED]:StorageError
/// @schema.contract artifacts/specs/2026-04-28-beads-rust-replacement/02-native-data-model.md::Write Transaction Shape
pub fn create_card(conn: &mut rusqlite::Connection, input: CreateCardInput) -> crate::Result<CreateCardResult>;
```

#### Refactor: Improve Code

- Separate validation, allocation, projection, side effects, and event emission into small transaction-local helpers.
- Reuse the same Rust transaction-local native post-save helper for single and batch create.
- Add `card_events` payload schemas for `card.created`, `keyword.upserted`, `edge.added`, `orphan.allowed`, and `recurrence.reinforced`.

### Success Criteria

Automated verification:

- `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml store_create`
- `bun test apps/silmari-mcp/tests/zk-save-card-fromaddress.test.ts` after the facade is wired

Manual verification:

- Create a temp native DB, run `create-card`, inspect `cards`, `card_labels`, `folgezettel_cursors`, and `card_events`.

## Behavior 4: Native Read, Update, Delete, Label, And Edge APIs Match Adapter Semantics

### Resource Registry Binding

- `resource_id`: `[PROPOSED]`
- `address_alias`: `native.adapter_crud`
- `predicate_refs`: exact ID input, label filters, status filters, tombstone visibility, timeout class
- `codepath_ref`: `apps/silmari_memory_rust/src/store.rs::{show_card,list_cards,update_card,delete_card,close_card,label_add,label_remove,edge_add,edge_remove,edge_list,search_biblio}`
- `schema_contract_refs`: `artifacts/specs/2026-04-28-beads-rust-replacement/03-store-api-and-adapter.md::Card reads`; `artifacts/specs/2026-04-28-beads-rust-replacement/03-store-api-and-adapter.md::Label Mutation Semantics`; `artifacts/specs/2026-04-28-beads-rust-replacement/03-store-api-and-adapter.md::Edge API Semantics`

### Schema Interface Mapping

- `loop_mode`: `summary`
- `mapped_contracts`: `show-card/list-cards/search-biblio/update-card/delete-card/label-add/label-remove/edge-add/edge-remove/edge-list -> native.cards,native.card_labels,native.card_edges,native.card_events`
- `registry_updates`: `[PROPOSED] native.adapter_crud`

### Test Specification

**Given**: a native DB with live, closed, and tombstoned cards  
**When**: read and mutation commands execute  
**Then**: outputs preserve exact lookup, label AND filtering, status filtering, tombstone defaults, update/delete effects, idempotent label mutation, review-gated edge insertion, and `blocks` compatibility

**Edge Cases**:

- `show-card` rejects non-exact IDs and deleted rows unless explicitly included.
- `list-cards` returns `[]` on no match, not an error.
- `list-cards` with timeout classification maps to a structured `QUERY_TIMEOUT`.
- `label-add` and `label-remove` with empty labels succeed as no-ops.
- Removing a generated native-field label is regenerated unless the native field is changed in the same update.
- `edge-add` for reviewed types writes `edge_proposals` unless called through explicit commit/force path.
- `edge-list` for `blocks` returns the `brDepList`-compatible direction shape.
- `search-biblio` is biblio-box only, preserves current `brSearch` return shape, and must not route idea recall through `LIKE`.
- Native edge writes enforce existing source and target cards; unresolved imported legacy refs are handled by migration warnings, not CRUD APIs.
- `brShow` one-time recoverable-miss retry remains a TypeScript facade behavior; Rust direct `show-card` performs a single exact lookup.

### TDD Cycle

#### Red: Write Failing Test

**File**: `apps/silmari_memory_rust/tests/store_read_update_delete.rs`

```rust
#[test]
fn list_filters_labels_with_and_logic_and_excludes_deleted_by_default() {
    let harness = NativeHarness::with_cards([
        card("zk-a").labels(["kind:learning", "trunk:5"]).status("open"),
        card("zk-b").labels(["kind:learning"]).status("deleted").deleted_at("2026-04-28T00:00:00Z"),
        card("zk-c").labels(["kind:fact", "trunk:5"]).status("open"),
    ]);

    let rows = harness.store().list_cards(ListCardsInput {
        box_name: Some(CardBox::Idea),
        labels: vec!["kind:learning".into(), "trunk:5".into()],
        all: false,
        ..Default::default()
    }).unwrap();

    assert_eq!(ids(&rows), vec!["zk-a"]);
}
```

#### Green: Minimal Implementation

**Files**:

- `apps/silmari_memory_rust/src/store.rs`
- `apps/silmari_memory_rust/src/model.rs`
- `apps/silmari_memory_rust/src/cli.rs`
- `apps/silmari_memory_rust/src/search.rs`

Add typed input/output structs and store functions for exact show, list, update, close, tombstone delete, label add/remove, edge add/remove/list. All mutations append events.

Add `search_biblio` as a direct biblio catalog compatibility API. It searches biblio card title/body/description according to current `brSearch` expectations and stays completely separate from exact keyword recall for idea cards.

**Documentation Contract**:

```rust
/// @rr.id [PROPOSED]
/// @rr.alias native.adapter_crud
/// @path.id native-adapter-crud
/// @gwt.given existing native cards and compatibility-style read or mutation inputs
/// @gwt.when CRUD, label, and edge operations execute
/// @gwt.then exact lookup, list filters, tombstone defaults, idempotent labels, edge projection, and events match adapter contracts
/// @reads [PROPOSED] native.cards,native.card_labels,native.card_edges,native.edge_proposals
/// @writes [PROPOSED] native.cards,native.card_labels,native.card_edges,native.edge_proposals,native.card_events,native.card_notes
/// @raises [PROPOSED]:CardNotFound,[PROPOSED]:ValidationError,[PROPOSED]:QueryTimeout
/// @schema.contract artifacts/specs/2026-04-28-beads-rust-replacement/03-store-api-and-adapter.md::Adapter Replacement Matrix
pub fn list_cards(conn: &rusqlite::Connection, input: ListCardsInput) -> crate::Result<Vec<Card>>;
```

#### Refactor: Improve Code

- Share filter construction between list, content-hash lookup, and shadow parity.
- Keep SQL generated through structured builders, not string concatenation with raw user input.
- Add a compatibility row serializer so TypeScript does not reimplement Rust row mapping.

### Success Criteria

Automated verification:

- `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml store_read_update_delete`
- `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml search_biblio`
- `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml adapter_cli_contract`

Manual verification:

- Compare `show-card` and `list-cards` JSON with current `brShow` and `brList` fixture output.

## Behavior 5: Batch Create Preserves Input Order And All-Or-Nothing Semantics

### Resource Registry Binding

- `resource_id`: `[PROPOSED]`
- `address_alias`: `native.batch_create`
- `predicate_refs`: ordered card inputs, per-card validation, transaction boundary, native post-save side effects
- `codepath_ref`: `apps/silmari_memory_rust/src/store.rs::create_cards`
- `schema_contract_refs`: `artifacts/specs/2026-04-28-beads-rust-replacement/03-store-api-and-adapter.md::Compatibility Flow: Batch Create`

### Schema Interface Mapping

- `loop_mode`: `summary`
- `mapped_contracts`: `create-cards JSON array -> ordered CreateCardResult array`
- `registry_updates`: `[PROPOSED] native.batch_create`

### Test Specification

**Given**: an ordered array of valid idea-card inputs  
**When**: native batch create runs  
**Then**: returned results align by index with inputs, every card gets the correct body/title/labels/fz, and all native post-save side effects run per card

**Edge Cases**:

- Empty input returns `[]` without opening a write transaction.
- Any validation failure fails the batch before creating rows.
- Any storage failure rolls back all rows and events.
- `fromAddress` validation happens per input before any writes.
- Body-hash recurrence in a batch targets the oldest prior card deterministically.
- Batch result has the same keys as single `create-card` result.
- During shadow-write, legacy Beads may still partially write per-card batches; the shadow layer records a reconciliation event with legacy IDs, native IDs, input hash, and replay instructions whenever native all-or-nothing semantics diverge from legacy partial behavior.

### TDD Cycle

#### Red: Write Failing Test

**File**: `apps/silmari_memory_rust/tests/store_batch.rs`

```rust
#[test]
fn create_cards_returns_ids_in_input_order_and_rolls_back_on_failure() {
    let mut harness = NativeHarness::new();
    let inputs = vec![
        idea_input("alpha", "5", FolgezettelMode::Root),
        idea_input("bravo", "5", FolgezettelMode::Continue),
        idea_input("charlie", "5", FolgezettelMode::Continue),
    ];

    let results = harness.store_mut().create_cards(inputs).unwrap();

    assert_eq!(results.len(), 3);
    assert_body_contains(&harness.conn, &results[0].id, "alpha");
    assert_body_contains(&harness.conn, &results[1].id, "bravo");
    assert_body_contains(&harness.conn, &results[2].id, "charlie");
}
```

#### Green: Minimal Implementation

**Files**:

- `apps/silmari_memory_rust/src/store.rs`
- `apps/silmari_memory_rust/src/cli.rs`

Pre-validate all inputs, then run one transaction. Reuse the single-card transaction-local helper for each input.

**Documentation Contract**:

```rust
/// @rr.id [PROPOSED]
/// @rr.alias native.batch_create
/// @path.id native-create-cards-batch
/// @gwt.given an ordered array of Silmari card creation requests
/// @gwt.when create_cards validates and writes the batch
/// @gwt.then result order matches input order and partial success is impossible
/// @reads [PROPOSED] native.cards,native.card_labels,native.folgezettel_cursors,native.keyword_entries
/// @writes [PROPOSED] native.cards,native.card_labels,native.card_edges,native.keyword_entries,native.folgezettel_cursors,native.card_events
/// @raises [PROPOSED]:ValidationError,[PROPOSED]:StorageError
/// @schema.contract artifacts/specs/2026-04-28-beads-rust-replacement/03-store-api-and-adapter.md::Compatibility Flow: Batch Create
pub fn create_cards(conn: &mut rusqlite::Connection, inputs: Vec<CreateCardInput>) -> crate::Result<Vec<CreateCardResult>>;
```

#### Refactor: Improve Code

- Expose batch command through JSON CLI.
- Use deterministic event order matching input order.
- Add internal telemetry counts for validation, inserted cards, inserted edges, keyword updates, and events.

### Success Criteria

Automated verification:

- `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml store_batch`
- Later facade gate: `bun test apps/silmari-mcp/tests/zk-save-cards-batch.test.ts`

Manual verification:

- Create a batch with three unique bodies and inspect output order plus DB row order.

## Behavior 6A: Migration Snapshot Creation And Replace Safety Are Enforced

### Resource Registry Binding

- `resource_id`: `[PROPOSED]`
- `address_alias`: `migration.snapshot_safety`
- `predicate_refs`: legacy DB paths, sidecar paths, snapshot directory, source hashes, target DB path, replace flag
- `codepath_ref`: `apps/silmari_memory_rust/src/migration.rs::{create_snapshot,validate_replace_safety}`
- `schema_contract_refs`: `artifacts/specs/2026-04-28-beads-rust-replacement/04-migration-cutover-and-verification.md::Phase 0: Fixture and snapshot support`; `artifacts/specs/2026-04-28-beads-rust-replacement/04-migration-cutover-and-verification.md::Data Safety Rules`

### Schema Interface Mapping

- `loop_mode`: `summary`
- `mapped_contracts`: `source DBs/sidecars -> snapshot manifest -> import safety gate`
- `registry_updates`: `[PROPOSED] migration.snapshot_safety`

### Test Specification

**Given**: legacy Beads DB paths, MCP SQLite state, and optional sidecar paths
**When**: snapshot creation runs
**Then**: sources are opened/read without mutation, copied to a timestamped snapshot directory, hashed, and described by a manifest that import must validate before any replace operation

**Edge Cases**:

- Re-running snapshot creation with unchanged sources and the same requested timestamp is idempotent.
- Snapshot manifests include source paths, copy paths, SHA-256 hashes, file sizes, git commit, started/finished timestamps, and tool version.
- Missing optional sidecars produce manifest warnings; missing required DBs fail before target DB access.
- Import to a new target path is allowed with a valid snapshot.
- `--replace=false` fails if the target DB already exists.
- `--replace=true` fails unless a valid existing snapshot manifest is supplied and source hashes match.
- Import writes to a staging DB in the same directory as the final target and atomically promotes it only after required reports are produced.
- Cross-device promotion is not allowed; if staging and target cannot be proven to share a filesystem, fail with `CROSS_DEVICE_PROMOTE_UNSAFE`.
- Snapshot copy uses SQLite backup API where possible. If raw file copy is used, the snapshot must include the database file plus `-wal` and `-shm` files after a checkpoint, or fail closed with `HOT_WAL_SNAPSHOT_UNSAFE`.
- Promotion closes all SQLite connections before rename/replace and fsyncs the parent directory on Unix where supported.
- A failed import leaves the previous target unchanged and records the staging path plus failure code in the rollback manifest.

### TDD Cycle

#### Red: Write Failing Test

**File**: `apps/silmari_memory_rust/tests/migration_snapshot.rs`

```rust
#[test]
fn snapshot_manifest_is_required_before_replace_import() {
    let fixture = LegacySourcesFixture::new().with_biblio_db().with_idea_db().build();
    let snapshot = silmari_memory_rust::migration::create_snapshot(CreateSnapshotInput {
        sources: fixture.sources(),
        snapshot_root: fixture.tempdir().join("snapshots"),
        requested_timestamp: Some("2026-04-28T06-00-00Z".into()),
    }).unwrap();

    assert_manifest_hashes_sources(&snapshot.manifest_path, fixture.sources());

    let existing_target = fixture.tempdir().join("native.sqlite");
    seed_existing_native_db(&existing_target);

    let err = silmari_memory_rust::importer::import_snapshot(ImportSnapshotInput {
        snapshot_dir: snapshot.snapshot_dir.clone(),
        snapshot_manifest: None,
        target_db: existing_target.clone(),
        report_dir: fixture.tempdir().join("reports"),
        replace: true,
    }).unwrap_err();
    assert_eq!(err.code(), ErrorCode::ReplaceRequiresSnapshot);

    silmari_memory_rust::importer::import_snapshot(ImportSnapshotInput {
        snapshot_dir: snapshot.snapshot_dir,
        snapshot_manifest: Some(snapshot.manifest_path),
        target_db: existing_target,
        report_dir: fixture.tempdir().join("reports-ok"),
        replace: true,
    }).unwrap();
}
```

**File**: `apps/silmari_memory_rust/tests/import_snapshot_cli_contract.rs`

```rust
#[test]
fn cli_snapshot_manifest_is_consumed_before_import_mutates_target() {
    let fixture = LegacySourcesFixture::new().with_biblio_db().with_idea_db().build();
    let target = fixture.tempdir().join("native.sqlite");
    let reports = fixture.tempdir().join("reports");

    let snapshot = Command::cargo_bin("silmari_memory_rust")
        .unwrap()
        .args([
            "create-snapshot",
            "--json",
            "--source-root",
            fixture.source_root().to_str().unwrap(),
            "--snapshot-root",
            fixture.tempdir().join("snapshots").to_str().unwrap(),
        ])
        .assert()
        .success()
        .get_output_json::<SnapshotSummary>();

    Command::cargo_bin("silmari_memory_rust")
        .unwrap()
        .args([
            "import-snapshot",
            "--json",
            "--snapshot-manifest",
            snapshot.manifest_path.to_str().unwrap(),
            "--target-db",
            target.to_str().unwrap(),
            "--report-dir",
            reports.to_str().unwrap(),
        ])
        .assert()
        .success()
        .stdout(predicate::str::contains("\"ok\":true"));

    assert!(target.exists());
    assert_report_exists(&reports, "import-summary.json");
    assert_report_exists(&reports, "rollback-manifest.json");
}

#[test]
fn cli_import_rejects_accepted_review_manifest_with_snapshot_hash_mismatch_before_promotion() {
    let fixture = LegacySourcesFixture::new().with_reviewed_ref_label().build();
    let target = fixture.tempdir().join("native.sqlite");
    let snapshot = create_snapshot_via_cli(&fixture);
    let bad_manifest = fixture.write_accepted_review_manifest_with_hash("sha256:not-the-snapshot");

    Command::cargo_bin("silmari_memory_rust")
        .unwrap()
        .args([
            "import-snapshot",
            "--json",
            "--snapshot-manifest",
            snapshot.manifest_path.to_str().unwrap(),
            "--accepted-review-manifest",
            bad_manifest.to_str().unwrap(),
            "--target-db",
            target.to_str().unwrap(),
        ])
        .assert()
        .failure()
        .stdout(predicate::str::contains("\"ok\":false"))
        .stdout(predicate::str::contains("\"code\":\"SOURCE_HASH_MISMATCH\""));

    assert!(!target.exists());
}
```

#### Green: Minimal Implementation

**Files**:

- `apps/silmari_memory_rust/src/migration.rs`
- `apps/silmari_memory_rust/src/importer.rs`
- `apps/silmari_memory_rust/src/report.rs`
- `apps/silmari_memory_rust/src/cli.rs`

Implement `create-snapshot --json`, manifest hashing, idempotent copy behavior, and `validate_replace_safety`. The importer must call `validate_replace_safety` before opening the target DB for writes.

**Documentation Contract**:

```rust
/// @rr.id [PROPOSED]
/// @rr.alias migration.snapshot_safety
/// @path.id create-and-validate-legacy-snapshot
/// @gwt.given legacy Silmari source paths and a migration target DB path
/// @gwt.when snapshot creation or replace-safety validation runs
/// @gwt.then source files are copied read-only, hashed, recorded in a manifest, and replace imports are blocked without that manifest
/// @reads [PROPOSED] legacy.biblio_beads,legacy.idea_beads,legacy.silmari_db,legacy.sidecars
/// @writes [PROPOSED] migration.snapshot_dir,migration.snapshot_manifest
/// @raises [PROPOSED]:SnapshotError,[PROPOSED]:ReplaceRequiresSnapshot,[PROPOSED]:SourceHashMismatch
/// @schema.contract artifacts/specs/2026-04-28-beads-rust-replacement/04-migration-cutover-and-verification.md::Data Safety Rules
pub fn create_snapshot(input: CreateSnapshotInput) -> crate::Result<SnapshotSummary>;
```

#### Refactor: Improve Code

- Keep hash/manifest validation reusable by import, rollback, and parity commands.
- Treat snapshot warnings as structured report records, not plain stderr lines.
- Add a fixture builder that creates read-only copies where the platform supports it.

### Success Criteria

Automated verification:

- `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml migration_snapshot`
- `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml import_snapshot_cli_contract`

Manual verification:

- Run `create-snapshot --json` twice against unchanged fixture sources and verify the manifest hashes and file counts are stable.

## Behavior 6: Migration Imports Verified Legacy Snapshots With Reports And Field Disposition

### Resource Registry Binding

- `resource_id`: `[PROPOSED]`
- `address_alias`: `native.migration_import`
- `predicate_refs`: verified snapshot manifest, legacy biblio DB, legacy idea DB, MCP `silmari.db`, `TRUNKS.md`, `folgezettel-cursors.json`, `link-proposals.jsonl`, target staging DB
- `codepath_ref`: `apps/silmari_memory_rust/src/importer.rs::import_snapshot`
- `schema_contract_refs`: `artifacts/specs/2026-04-28-beads-rust-replacement/04-migration-cutover-and-verification.md::Import Mapping`; `artifacts/specs/2026-04-28-beads-rust-replacement/02-native-data-model.md::Migration From Existing Rust Schema`

### Schema Interface Mapping

- `loop_mode`: `summary`
- `mapped_contracts`: `Legacy issues/labels/dependencies/keyword_entries/sidecars -> native cards/card_labels/card_edges/keyword_entries/trunks/folgezettel_cursors/edge_proposals/card_events`
- `registry_updates`: `[PROPOSED] native.migration_import`

### Beads Field Disposition

The v1 importer consumes raw `vendor/beads_rust` SQLite, not the viewer cache. It must use the normalized `labels(issue_id,label)` table for labels and treat the viewer's denormalized `issues.labels` column as compatibility export-only.

| Beads field | Native disposition |
| --- | --- |
| `issues.id` | KEEP as `cards.id`; block cutover if prefix conflicts with box |
| `issues.content_hash` | TRANSFORM to `cards.content_hash` only when label/JSON hash agrees; otherwise event warning |
| `issues.title` | KEEP as `cards.title` |
| `issues.description` | KEEP as `cards.description`; also source for body JSON decode |
| `issues.design` | TRANSFORM into `cards.body` only when no Silmari JSON body is present; otherwise record as note/event |
| `issues.acceptance_criteria` | TRANSFORM into body fallback or `card_notes` |
| `issues.notes` | TRANSFORM into `card_notes` and body fallback |
| `issues.status` | KEEP as `cards.status`, mapping Beads `tombstone` to native `deleted` |
| `issues.priority` | KEEP as `cards.priority` |
| `issues.issue_type` | DROP as issue-tracker-only, except preserve in import warning metadata |
| `issues.assignee` | DROP as issue-tracker-only |
| `issues.owner` | DROP as issue-tracker-only |
| `issues.estimated_minutes` | DROP as issue-tracker-only |
| `issues.created_at` | KEEP as `cards.created_at` |
| `issues.created_by` | TRANSFORM into `card_events.actor` metadata |
| `issues.updated_at` | KEEP as `cards.updated_at` |
| `issues.closed_at` | TRANSFORM into closed status event payload |
| `issues.close_reason` | TRANSFORM into close event payload |
| `issues.closed_by_session` | TRANSFORM into close event payload |
| `issues.due_at` | DROP as issue-tracker-only |
| `issues.defer_until` | DROP as issue-tracker-only |
| `issues.external_ref` | DROP from native columns; preserve in import warning/event metadata to avoid unique collision semantics |
| `issues.source_system` | TRANSFORM into event metadata unless equivalent to Silmari `source:*` |
| `issues.source_repo` | DROP as issue-tracker-only |
| `issues.deleted_at` | TOMBSTONE-FILTER or KEEP as `cards.deleted_at` based on import mode; default skip from live views and record event |
| `issues.deleted_by` | TRANSFORM into delete event payload |
| `issues.delete_reason` | TRANSFORM into delete event payload |
| `issues.original_type` | DROP as issue-tracker-only |
| `issues.compaction_level` | DROP as issue-tracker-only |
| `issues.compacted_at` | DROP as issue-tracker-only |
| `issues.compacted_at_commit` | DROP as issue-tracker-only |
| `issues.original_size` | DROP as issue-tracker-only |
| `issues.sender` | DROP as issue-tracker-only |
| `issues.ephemeral` | TOMBSTONE-FILTER/SKIP and event warning |
| `issues.pinned` | DROP as issue-tracker-only |
| `issues.is_template` | TOMBSTONE-FILTER/SKIP and event warning |
| `labels.issue_id,label` | KEEP in `card_labels`; project known labels |
| `dependencies.type='blocks'` | TRANSFORM into `card_edges(edge_type='blocks')` |
| other `dependencies.type` values | DROP with warning; do not create semantic edges |
| `comments` | TRANSFORM into `card_notes` only if currently consumed; otherwise report and defer |
| `events` | DROP as Beads audit history; native import writes new `card_events` summary rows |

### Test Specification

**Given**: a verified timestamped snapshot manifest containing both Beads DBs and sidecar files
**When**: native import runs  
**Then**: card counts, labels, folgezettel addresses, edges, keywords, trunks, cursors, proposals, events, and reports match the specification

**Edge Cases**:

- Import reads legacy DBs read-only.
- Re-importing the same snapshot is idempotent.
- Import writes into a new/staging target DB and promotes only after `import-summary.json`, `parity-report.json`, `warnings.jsonl`, and `rollback-manifest.json` are complete.
- `replace=false` fails before write access if the target DB exists.
- `replace=true` requires the verified snapshot manifest from Behavior 6A.
- Deleted, ephemeral, and template rows do not appear in default live results.
- Invalid labels are preserved when safe and reported when unsafe.
- Non-`blocks` Beads dependencies never become semantic `card_edges`.
- Valid reviewed `ref:*` labels import through `EdgeWriteAuthority::ImportedLegacy` as `edge_proposals(status='pending', authority='imported-legacy')` plus an import evidence event, unless a validated `AcceptedReviewManifest` from Behavior 2 authorizes promotion.
- `AcceptedReviewManifest.sourceSnapshotHash` mismatch fails validation before staging promotion.
- Import reports count reviewed edges by accepted, pending, refused, duplicate, invalid-target, invalid-type, and invalid-authority categories.
- Unresolved `ref:*` targets are warning/event records and do not bypass foreign-key policy.
- `TRUNKS.md` and cursor JSON are optional but produce warnings if missing.
- Every run writes `import-summary.json`, `parity-report.json`, `warnings.jsonl`, and `rollback-manifest.json`.
- Reports include source paths and hashes, target DB path, git commit, started/finished timestamps, imported/skipped counts, mismatch counts by category, and first-N representative mismatches.

### TDD Cycle

#### Red: Write Failing Test

**File**: `apps/silmari_memory_rust/tests/import_migration.rs`

```rust
#[test]
fn imports_snapshot_sidecars_and_writes_required_reports() {
    let snapshot = LegacySnapshotFixture::new()
        .with_biblio_db()
        .with_idea_db()
        .with_mcp_keyword_db()
        .with_trunks_md()
        .with_cursors_json()
        .with_link_proposals_jsonl()
        .build();

    let out = tempdir().unwrap();
    let summary = silmari_memory_rust::importer::import_snapshot(ImportSnapshotInput {
        snapshot_dir: snapshot.path().into(),
        snapshot_manifest: Some(snapshot.manifest_path().into()),
        target_db: out.path().join("silmari-memory.sqlite"),
        report_dir: out.path().join("reports"),
        replace: false,
    }).unwrap();

    assert_eq!(summary.cards_by_box["idea"], 3);
    assert_report_exists(out.path(), "import-summary.json");
    assert_report_exists(out.path(), "parity-report.json");
    assert_report_exists(out.path(), "warnings.jsonl");
    assert_report_exists(out.path(), "rollback-manifest.json");
}
```

#### Green: Minimal Implementation

**Files**:

- `apps/silmari_memory_rust/src/importer.rs`
- `apps/silmari_memory_rust/src/migration.rs`
- `apps/silmari_memory_rust/src/report.rs`
- `apps/silmari_memory_rust/src/cli.rs`

Add snapshot input struct, sidecar import, warning/event rows, report writers, and read-only source connections where supported.

Import must be a staged operation: read from the verified snapshot, write a temporary native DB path in the same directory as the requested target, run schema/parity/report gates, then rename/promote into the requested target path. A failed import leaves the previous target unchanged and leaves reports sufficient for rollback diagnosis.

Promotion safety rules:

- Stage under `<target-dir>/.silmari-import-staging/<run-id>/native.sqlite` so the final rename is same-filesystem.
- Refuse cross-device promotion with `CROSS_DEVICE_PROMOTE_UNSAFE`.
- Use SQLite backup for live SQLite sources where supported; otherwise include DB, `-wal`, and `-shm` after a checkpoint or fail with `HOT_WAL_SNAPSHOT_UNSAFE`.
- Close source, staging, and target SQLite handles before final rename.
- On Unix, fsync the promoted DB and parent directory where supported.
- The rollback manifest must include run id, previous target hash/path, staging DB path/hash, report directory, error code, and explicit restore instructions.

`migration.reconciliation_events` report records use this JSONL schema:

```json
{
  "runId": "string",
  "operation": "show|list|create|batch-create|edge-add|recall|line-of-thought|viewer-export|sai-recall",
  "inputHash": "sha256 hex",
  "legacyResultHash": "sha256 hex or null",
  "nativeResultHash": "sha256 hex or null",
  "category": "missing|extra|shape|ordering|error-code|side-effect",
  "userVisibleResult": "legacy|native|none",
  "replayInstruction": "string",
  "rollbackNote": "string"
}
```

**Documentation Contract**:

```rust
/// @rr.id [PROPOSED]
/// @rr.alias native.migration_import
/// @path.id import-legacy-silmari-snapshot
/// @gwt.given a snapshot of legacy Beads DBs, MCP sqlite state, and sidecar files
/// @gwt.when import_snapshot normalizes legacy state into the native DB
/// @gwt.then cards, labels, edges, keywords, trunks, cursors, proposals, events, and reports are produced without mutating sources
/// @reads [PROPOSED] legacy.biblio_beads,legacy.idea_beads,legacy.silmari_db,legacy.trunks_md,legacy.folgezettel_cursors,legacy.link_proposals
/// @writes [PROPOSED] native.cards,native.card_labels,native.card_edges,native.keyword_entries,native.trunks,native.folgezettel_cursors,native.edge_proposals,native.card_events,native.card_notes
/// @raises [PROPOSED]:ImportError,[PROPOSED]:ReportError
/// @schema.contract artifacts/specs/2026-04-28-beads-rust-replacement/04-migration-cutover-and-verification.md::Import Mapping
pub fn import_snapshot(input: ImportSnapshotInput) -> crate::Result<ImportRunSummary>;
```

#### Refactor: Improve Code

- Split raw Beads row reading from native insertion.
- Make field disposition table executable with assertions for every `PRAGMA table_info(issues)` field.
- Add fixture builders that can be shared with shadow parity tests.

### Success Criteria

Automated verification:

- `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml import_migration`
- Existing `apps/silmari_memory_rust/tests/import_beads.rs` still passes or is intentionally migrated to the snapshot fixture.

Manual verification:

- Run import against a copy of local Beads DBs and inspect report counts before any cutover mode is changed.

## Behavior 7: TypeScript Compatibility Facade Preserves br-adapter Observables

### Resource Registry Binding

- `resource_id`: `[PROPOSED]`
- `address_alias`: `mcp.native_facade`
- `predicate_refs`: Rust JSON CLI outputs, current adapter functions, MCP tool payloads
- `codepath_ref`: `apps/silmari-mcp/src/lib/br-adapter.ts`; `apps/silmari-mcp/src/lib/legacy-br-adapter.ts`; `apps/silmari-mcp/src/lib/native-adapter.ts`
- `schema_contract_refs`: `artifacts/specs/2026-04-28-beads-rust-replacement/03-store-api-and-adapter.md::JSON Error Envelope`; `artifacts/specs/2026-04-28-beads-rust-replacement/03-store-api-and-adapter.md::Adapter Replacement Matrix`

### Schema Interface Mapping

- `loop_mode`: `summary`
- `mapped_contracts`: `Rust error envelope -> TypeScript null/false/[]/throw mapping`
- `registry_updates`: `[PROPOSED] mcp.native_facade`

### Test Specification

**Given**: native mode enabled for adapter calls  
**When**: existing MCP code calls create, show, list, search, update, delete, dep, label helpers, and direct label lookup helpers currently backed by `br-sqlite.ts`
**Then**: the user-visible return shape is unchanged from current `br-adapter.ts`

**Edge Cases**:

- `CARD_NOT_FOUND` maps to `null` for show.
- `CARD_NOT_FOUND` maps to `false` for label add/update/delete after retry behavior is no longer needed.
- `VALIDATION_ERROR` maps to `null` for compatibility create but remains structured in direct CLI.
- `QUERY_TIMEOUT` maps to `BrListTimeoutError`.
- Structured error payloads are never returned as rows.
- Exact show rejects fuzzy IDs.
- `brList` no-match remains `[]`.
- `brSearch` remains biblio-only compatibility search.
- `blocks` remains queryable through dep-compatible list.
- Label lookup by exact label remains indexed and fast for `content_hash:*`, `fz:*`, and future label-resolved call sites.
- In `native-primary`, `content_hash:*` duplicate lookup, Tier A parent lookup, and `fromAddress` lookup must succeed against the native DB when legacy `beads.db` is missing or corrupt.
- `br-sqlite.ts` is legacy-only. Production imports of `./br-sqlite.js` outside the legacy adapter implementation fail a grep gate.
- `zk_block` schema text and dispatcher behavior are brought back into alignment around canonical `blocks`.
- `checkpointBeadsWal` / `brSync` compatibility becomes a no-op diagnostic in native mode and remains legacy-only in legacy modes.
- `brShow` preserves the existing one-time recoverable-miss retry in the facade, even though Rust `show-card` performs a single exact lookup.
- `saveCard` and `saveCardsBatch` in native modes call the native create commands and do not invoke TypeScript `runPostSaveSteps` or `emitReinforcesToPrior`; those helpers are legacy/shadow-legacy only.

### TypeScript Facade Contract

`br-adapter.ts` remains the imported module at current call sites. Its exported function names become the mode-switching facade; the legacy subprocess implementation moves behind `LegacyBrAdapter`, and the native JSON CLI implementation lives behind `NativeCliAdapter`.

```ts
export type SilmariMemoryMode =
  | 'legacy-br'
  | 'import-only'
  | 'shadow-read'
  | 'shadow-write'
  | 'native-primary'
  | 'legacy-read-only';

export type NativeEnvelope<T> =
  | { ok: true; result: T; meta?: Record<string, unknown> }
  | { ok: false; error: NativeError };

export interface NativeError {
  code:
    | 'CARD_NOT_FOUND'
    | 'QUERY_TIMEOUT'
    | 'VALIDATION_ERROR'
    | 'SCHEMA_INCOMPATIBLE'
    | 'DB_NOT_FOUND'
    | 'CLI_PARSE';
  message: string;
  details?: Record<string, unknown>;
}

export interface SilmariMemoryAdapter {
  isAvailable(): boolean;
  createCompat(input: BrCreateInput): string | null;
  createBatchCompat(input: BrCreateBatchInput): string[];
  updateCompat(box: BoxName, id: string, fields: BrUpdateFields): boolean;
  listCompat(input: BrListInput): BrIssueRow[];
  searchBiblioCompat(query: string): BrIssueRow[];
  showCompat(box: BoxName, id: string): BrIssueRow | null;
  closeCompat(box: BoxName, id: string, reason?: string): boolean;
  deleteCompat(box: BoxName, id: string): boolean;
  edgeAddCompat(source: string, target: string, type: EdgeType): boolean;
  edgeListCompat(id: string, direction: 'down' | 'up' | 'both'): BrDependencyRow[];
  labelAddCompat(box: BoxName, id: string, labels: string[]): boolean;
  labelRemoveCompat(box: BoxName, id: string, labels: string[]): boolean;
  findCardsByLabelCompat(box: BoxName, label: string, limit: number): BrIssueRow[];
  checkpointCompat(): boolean;
}
```

### Adapter File Ownership Contract

The facade split is fixed and must not be reinterpreted during implementation:

- `apps/silmari-mcp/src/lib/br-adapter.ts` is the public facade and runtime mode switch. Existing public export names stay here so current call sites do not import implementation classes directly.
- `apps/silmari-mcp/src/lib/legacy-br-adapter.ts` owns current Beads subprocess and Beads SQLite compatibility implementation. It is the only production file allowed to import `./br-sqlite.js`.
- `apps/silmari-mcp/src/lib/native-adapter.ts` owns native Rust CLI spawning, timeout handling, and `NativeEnvelope<T>` parsing. It is imported only by `br-adapter.ts` and explicitly facade-owned tests.
- `apps/silmari-mcp/src/lib/br-sqlite.ts` remains an implementation detail of `legacy-br-adapter.ts`; `card-ops.ts`, MCP tool handlers, and SAI-facing code must not import it.
- Production callers import only from `br-adapter.ts`. Direct imports from `legacy-br-adapter.ts` or `native-adapter.ts` are forbidden outside tests that explicitly verify the facade boundary.

`findCardsByLabelCompat` is the facade replacement for the current `findBeadsByLabel` direct SQLite helper. `LegacyBrAdapter` may implement it with `br-sqlite.ts`; `NativeCliAdapter` must implement it with a native indexed label query; shadow modes compare normalized native and legacy rows. No production file except the legacy adapter may import `br-sqlite.ts`.

The final success envelope key is `result`, not the older research draft's `data`. Any stale CW9 context or generated test using `{ok:true,data}` must be regenerated or amended before test generation.

Mode resolution order is: test override, `SILMARI_MEMORY_MODE`, MCP config file, then default `legacy-br`. Behavior 12 defines the concrete config file contract. A mode-routing smoke test must prove `saveCard`, `saveCardsBatch`, `zk_block`, `zk_recall`, `silmari://card/<id>`, duplicate lookup, and `fromAddress` lookup cross this facade in native and shadow modes.

### TDD Cycle

#### Red: Write Failing Test

**File**: `apps/silmari-mcp/tests/native-cli-contract.test.ts`

```ts
describe('NativeCliAdapter real CLI boundary', () => {
  it('spawns the actual Rust binary and maps real NativeEnvelope payloads', async () => {
    const binary = await buildOrLocateRustBinary('silmari_memory_rust');
    const db = await createNativeFixtureDb({ cards: [{ id: 'zk-exact', box: 'idea', title: 'Exact' }] });
    const adapter = new NativeCliAdapter({ binary, nativeDbPath: db.path, timeoutMs: 5_000 });

    expect((await adapter.showCompat('idea', 'zk-exact'))?.id).toBe('zk-exact');
    expect(await adapter.showCompat('idea', 'zk-missing')).toBeNull();
    expect(await adapter.listCompat({ box: 'idea', labels: ['missing:nope'] })).toEqual([]);

    await expect(adapter.createCompat({ box: 'idea', title: '', body: '' })).resolves.toBeNull();
    expect(adapter.lastNativeError()?.code).toBe('VALIDATION_ERROR');
  });

  it('does not create a missing DB path for read commands', async () => {
    const binary = await buildOrLocateRustBinary('silmari_memory_rust');
    const missingDb = join(tempdir(), 'missing-native-read.sqlite');
    const adapter = new NativeCliAdapter({ binary, nativeDbPath: missingDb, timeoutMs: 5_000 });

    await expect(adapter.showCompat('idea', 'zk-any')).resolves.toBeNull();
    expect(adapter.lastNativeError()?.code).toBe('DB_NOT_FOUND');
    expect(existsSync(missingDb)).toBe(false);
  });

  it('maps real timeout and parse failures without inspecting raw stderr', async () => {
    const binary = await buildOrLocateRustBinary('silmari_memory_rust');
    const adapter = new NativeCliAdapter({ binary, nativeDbPath: await slowFixtureDb(), timeoutMs: 1 });

    await expect(adapter.listCompat({ box: 'idea' })).rejects.toBeInstanceOf(BrListTimeoutError);
    expect(adapter.lastNativeError()?.code).toBe('QUERY_TIMEOUT');
    expect(adapter.stderrClassificationUsed()).toBe(false);
  });
});
```

**File**: `apps/silmari-mcp/tests/native-mcp-dispatch-contract.test.ts`

```ts
describe('MCP dispatch crosses the native facade boundary', () => {
  it('runs save, recall, block, and resource read through native-primary with legacy Beads absent', async () => {
    const harness = await createNativePrimaryMcpHarness({
      legacyBeadsDb: 'missing',
      nativeDb: await createNativeFixtureDb(),
    });

    const save = await harness.dispatchTool('zk_save_card', {
      body: 'Native dispatch canary',
      trunk: '5',
      kind: 'idea',
    });
    const id = readToolJson(save).id;

    await harness.dispatchTool('zk_block', { sourceId: id, targetId: 'zk-blocked' });
    const recall = await harness.dispatchTool('zk_recall', { query: 'Native dispatch canary' });
    const resource = await harness.dispatchResource(`silmari://card/${id}`);

    expect(readToolJson(recall).entryCards.map((c: { id: string }) => c.id)).toContain(id);
    expect(resource.contents[0].text).toContain('Native dispatch canary');
    expect(harness.nativeCalls()).toEqual(expect.arrayContaining([
      'create-card',
      'edge-add',
      'recall',
      'show-card',
      'find-cards-by-label',
    ]));
    expect(harness.legacyCalls()).toEqual([]);
  });
});
```

**File**: `apps/silmari-mcp/tests/native-adapter.test.ts`

```ts
describe('native adapter compatibility facade', () => {
  it('maps native not-found and empty-list results to existing br-adapter shapes', () => {
    withNativeAdapterFixture((adapter) => {
      expect(adapter.showCompat('idea', 'zk-THIS_ID_DOES_NOT_EXIST_QQ')).toBeNull();
      expect(adapter.listCompat({ box: 'idea', labels: ['no-such-label-ever'] })).toEqual([]);
      expect(adapter.labelAddCompat('idea', 'zk-THIS_ID_DOES_NOT_EXIST_QQ', ['kind:idea'])).toBe(false);
    });
  });

  it('routes existing br-adapter exports through the configured mode switch', () => {
    const calls = withModeRoutingHarness('native-primary', () => {
      saveCard({ body: 'mode route canary', trunk: '5' });
      saveCardsBatch([{ body: 'batch route canary', trunk: '5' }]);
      addBlock('zk-a', 'zk-b');
      recall('canary');
      readCardResource('zk-a');
    });

    expect(calls.native).toEqual([
      'create-card',
      'create-cards',
      'edge-add',
      'recall',
      'show-card',
      'find-cards-by-label',
    ]);
    expect(calls.legacy).toEqual([]);
  });

  it('does not touch legacy beads.db for label lookup in native-primary', () => {
    withNativePrimaryHarness({ legacyBeadsDb: 'missing' }, (adapter) => {
      seedNativeCard({ id: 'zk-parent', labels: ['fz:5_1', 'content_hash:1234abcd'] });

      expect(adapter.findCardsByLabelCompat('idea', 'fz:5_1', 2).map((r) => r.id)).toEqual(['zk-parent']);
      expect(adapter.findCardsByLabelCompat('idea', 'content_hash:1234abcd', 10).map((r) => r.id)).toEqual(['zk-parent']);
    });
  });

  it('does not replay TypeScript legacy post-save hooks after native create', () => {
    const calls = withModeRoutingHarness('native-primary', () => {
      saveCard({ body: 'native post-save owner canary', trunk: '5' });
    });

    expect(calls.native).toContain('create-card');
    expect(calls.legacy).toEqual([]);
    expect(calls.typescriptPostSave).toEqual([]);
  });

  it('covers every gwt-0006 facade invariant across native-primary mode', () => {
    withNativePrimaryHarness({ legacyBeadsDb: 'missing' }, (adapter) => {
      seedNativeCard({ id: 'bl-biblio', box: 'biblio', title: 'Biblio Hit' });
      seedNativeCard({ id: 'zk-exact', box: 'idea', title: 'Exact Idea', labels: ['kind:learning'] });

      const created = adapter.createCompat({ box: 'idea', title: 'Created', labels: ['kind:learning'] });
      expect(created === null || /^zk-/.test(created)).toBe(true);

      expect(adapter.listCompat({ box: 'idea', labels: ['kind:learning'] }).map((r) => r.id)).toContain('zk-exact');
      expect(adapter.listCompat({ box: 'idea', labels: ['missing:nope'] })).toEqual([]);

      expect(adapter.showCompat('idea', 'zk-exact')?.id).toBe('zk-exact');
      expect(adapter.showCompat('idea', 'zk')).toBeNull();
      expect(adapter.showCompat('idea', 'zk-missing')).toBeNull();

      expect(adapter.searchBiblioCompat('Biblio').map((r) => r.id)).toEqual(['bl-biblio']);
      expect(adapter.searchBiblioCompat('Exact Idea')).toEqual([]);
    });
  });

  it('blocks native/internal and broad br-sqlite imports outside the legacy adapter boundary', () => {
    expect(productionImports('apps/silmari-mcp/src', './native-adapter.js')).toEqual([
      'apps/silmari-mcp/src/lib/br-adapter.ts',
    ]);
    expect(productionImports('apps/silmari-mcp/src', './br-sqlite.js')).toEqual([
      'apps/silmari-mcp/src/lib/legacy-br-adapter.ts',
    ]);
    expect(publicExportSignatures('apps/silmari-mcp/src/lib/br-adapter.ts')).toMatchSnapshot();
  });
});
```

#### Green: Minimal Implementation

**Files**:

- `apps/silmari-mcp/src/lib/native-adapter.ts`
- `apps/silmari-mcp/src/lib/br-adapter.ts`
- `apps/silmari-mcp/src/lib/legacy-br-adapter.ts`
- `apps/silmari-mcp/src/lib/br-sqlite.ts`
- `apps/silmari-mcp/src/lib/paths.ts`
- `apps/silmari-mcp/src/index.ts`

Add native facade behind a mode flag. Keep exported function names stable in `br-adapter.ts` until MCP call sites are migrated. Move current Beads subprocess and Beads SQLite compatibility code into `legacy-br-adapter.ts`; keep native CLI code in `native-adapter.ts`.

`mapNativeResult` must be operation-aware because the same native error code maps differently by current compatibility operation. For example, `CARD_NOT_FOUND` maps to `null` for `showCompat`, `false` for mutation helpers, and `[]` only for operations whose current contract is an empty-list result.

Move direct label lookup behind the same adapter. `card-ops.ts` must call `findCardsByLabelCompat` through the configured adapter for duplicate lookup, Tier A parent lookup, and `fromAddress` resolution. The legacy implementation wraps the current `findBeadsByLabel`; the native implementation calls Rust `list-cards --label <label> --box <box> --limit <n>` or an equivalent native label lookup command.

**Documentation Contract**:

```ts
/**
 * @rr.id [PROPOSED]
 * @rr.alias mcp.native_facade
 * @path.id map-native-json-to-br-adapter-compat
 * @gwt.given a native Rust JSON CLI result or typed error envelope
 * @gwt.when TypeScript compatibility facade handles the result
 * @gwt.then current br-adapter return semantics and MCP payload shapes are preserved
 * @reads [PROPOSED] native.cli_json
 * @writes [PROPOSED] none
 * @raises [PROPOSED]:BrListTimeoutError
 * @schema.contract artifacts/specs/2026-04-28-beads-rust-replacement/03-store-api-and-adapter.md::JSON Error Envelope
 */
export function mapNativeResult<T>(operation: NativeOperation, result: NativeEnvelope<T>): T | null | false | [];
```

#### Refactor: Improve Code

- Centralize CLI spawn, timeout, and JSON parsing.
- Add snapshot tests for all adapter replacement matrix entries.
- Keep `br-adapter.ts` as the public facade and route through a thin mode switch to avoid rewriting call sites in the same step.
- Keep the legacy implementation in `legacy-br-adapter.ts`; do not leave Beads subprocess or `br-sqlite.ts` ownership in `br-adapter.ts`.
- Add `rg "from './br-sqlite\\.js'|from \\\"./br-sqlite\\.js\\\"" apps/silmari-mcp/src` as a negative gate, allowing only the legacy adapter-owned file.
- Add `rg "from './native-adapter\\.js'|from \\\"./native-adapter\\.js\\\"" apps/silmari-mcp/src` as a negative gate, allowing only `br-adapter.ts` or the explicitly named facade owner.
- Regenerate or amend `tests/generated/test_gwt_0006.py` so each `.cfg` invariant has either a named test function or a trace-derived assertion that fails with the invariant name.

### Success Criteria

Automated verification:

- `bun test apps/silmari-mcp/tests/native-cli-contract.test.ts`
- `bun test apps/silmari-mcp/tests/native-mcp-dispatch-contract.test.ts`
- `bun test apps/silmari-mcp/tests/native-adapter.test.ts`
- `bun test apps/silmari-mcp/tests/native-mode-routing.test.ts`
- `bun test apps/silmari-mcp/tests/zk-block-contract.test.ts`
- `bun test apps/silmari-mcp/tests/br-adapter.test.ts`
- `bun test apps/silmari-mcp/tests/zk-save-card-fromaddress.test.ts`
- `pytest tests/generated/test_gwt_0006.py`
- `rg "from './br-sqlite\\.js'|from \\\"./br-sqlite\\.js\\\"" apps/silmari-mcp/src` returns only the legacy adapter-owned file
- `rg "from './native-adapter\\.js'|from \\\"./native-adapter\\.js\\\"" apps/silmari-mcp/src` returns only the public facade owner

Manual verification:

- Toggle native facade mode against a temp DB and call `zk_save_card`, `zk_recall`, and `silmari://card/<id>`.

## Behavior 8: Shadow Read And Shadow Write Produce Parity Reports

### Resource Registry Binding

- `resource_id`: `[PROPOSED]`
- `address_alias`: `migration.shadow_parity`
- `predicate_refs`: legacy result, native result, normalized comparison shape, runtime mode
- `codepath_ref`: `apps/silmari-mcp/src/lib/native-shadow.ts`; `apps/silmari_memory_rust/src/parity.rs`
- `schema_contract_refs`: `artifacts/specs/2026-04-28-beads-rust-replacement/04-migration-cutover-and-verification.md::Verification Gates`

### Schema Interface Mapping

- `loop_mode`: `summary`
- `mapped_contracts`: `legacy normalized query -> native normalized query -> parity-report.json`
- `registry_updates`: `[PROPOSED] migration.shadow_parity`

### Test Specification

**Given**: representative legacy and native DB snapshots  
**When**: shadow read or shadow write runs for supported operations  
**Then**: user-visible output remains legacy in shadow modes, while normalized parity differences are logged with enough detail to block or approve mode advancement

**Edge Cases**:

- Exact show parity ignores field ordering.
- List parity compares IDs, labels, status, body, and timestamps after normalization.
- Content-hash lookup parity preserves oldest-match ordering.
- `fromAddress` lookup parity distinguishes timeout from genuine missing parent.
- Write parity records both legacy and native IDs if allocation differs.
- Shadow-write cannot share a transaction across legacy Beads and native SQLite; every mismatch writes a reconciliation record with operation input hash, legacy result, native result, replay instruction, and rollback note.
- Native event replay reconstructs native current state.

### TDD Cycle

#### Red: Write Failing Test

**File**: `apps/silmari-mcp/tests/native-shadow-contract.test.ts`

```ts
describe('native shadow contract', () => {
  it('executes real legacy and native write branches and records reconciliation JSONL on mismatch', async () => {
    const harness = await createShadowWriteHarness({
      legacy: await createLegacyBeadsFixture(),
      native: await createNativeFixtureDb(),
      reconciliationDir: await tempReportDir(),
    });

    harness.forceNativeIdAllocator('zk-native-different');
    const result = await harness.dispatchTool('zk_save_card', {
      body: 'shadow write canary',
      trunk: '5',
    });

    expect(readToolJson(result).id).toBe('zk-legacy-visible');
    expect(await harness.legacyContainsCard('zk-legacy-visible')).toBe(true);
    expect(await harness.nativeContainsCard('zk-native-different')).toBe(true);

    const records = await harness.readReconciliationJsonl();
    expect(records[0]).toMatchObject({
      operation: 'create',
      category: 'identity',
      userVisibleResult: 'legacy',
    });
    expect(records[0].inputHash).toMatch(/^sha256:/);
    expect(records[0].replayInstruction).toContain('zk_save_card');
    expect(records[0].rollbackNote).toBeTruthy();
  });
});
```

**File**: `apps/silmari-mcp/tests/native-shadow-parity.test.ts`

```ts
describe('native shadow parity', () => {
  it('logs normalized show/list differences without changing legacy output', () => {
    const harness = makeShadowHarness();
    const legacy = harness.seedLegacyCard({ id: 'zk-shadow', labels: ['kind:idea'] });
    harness.seedNativeCard({ id: 'zk-shadow', labels: ['kind:idea', 'extra:native'] });

    const result = harness.shadow.show('idea', 'zk-shadow');

    expect(result.userVisible).toEqual(legacy);
    expect(harness.report.mismatches[0].category).toBe('labels');
  });
});
```

#### Green: Minimal Implementation

**Files**:

- `apps/silmari-mcp/src/lib/native-shadow.ts`
- `apps/silmari-mcp/src/lib/native-adapter.ts`
- `apps/silmari_memory_rust/src/parity.rs`
- `apps/silmari_memory_rust/src/report.rs`

Implement normalized result shapes and report writers for the phase-2 and phase-3 operations listed in the migration spec.

**Documentation Contract**:

```ts
/**
 * @rr.id [PROPOSED]
 * @rr.alias migration.shadow_parity
 * @path.id compare-legacy-native-shadow-operation
 * @gwt.given a legacy operation result and a native operation result
 * @gwt.when shadow parity compares normalized payloads
 * @gwt.then user-visible output remains mode-correct and parity differences are written to report artifacts
 * @reads [PROPOSED] legacy.query_result,native.query_result
 * @writes [PROPOSED] migration.parity_report,migration.warnings
 * @raises [PROPOSED]:ParityError
 * @schema.contract artifacts/specs/2026-04-28-beads-rust-replacement/04-migration-cutover-and-verification.md::Verification Gates
 */
export function compareShadowOperation(input: ShadowCompareInput): ShadowCompareResult;
```

#### Refactor: Improve Code

- Use a shared normalizer across Rust parity reports and TypeScript shadow checks.
- Add report categories matching the spec gates: schema, counts, identity, folgezettel, body, labels, edges, keyword, MCP payload, viewer.
- Keep logs bounded with first-N representative mismatches.

### Success Criteria

Automated verification:

- `bun test apps/silmari-mcp/tests/native-shadow-contract.test.ts`
- `bun test apps/silmari-mcp/tests/native-shadow-parity.test.ts`
- `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml parity`

Manual verification:

- Run shadow-read against a snapshot and inspect `parity-report.json` before enabling shadow-write.

## Behavior 9: Retrieval Contracts Continue To Match MCP Payloads On Schema V2

### Resource Registry Binding

- `resource_id`: `[PROPOSED]`
- `address_alias`: `native.retrieval_payloads`
- `predicate_refs`: keyword entries, native cards, folgezettel indexes, typed edges, line-of-thought groups
- `codepath_ref`: `apps/silmari_memory_rust/src/retrieval.rs::{recall,line_of_thought,line_of_thought_at_address}`
- `schema_contract_refs`: `artifacts/specs/2026-04-28-beads-rust-replacement/05-viewer-export-and-consumers.md::MCP And SAI Contracts`

### Schema Interface Mapping

- `loop_mode`: `summary`
- `mapped_contracts`: `keyword_entries/cards/card_edges/folgezettel indexes -> zk_recall and zk_line_of_thought payloads`
- `registry_updates`: `[PROPOSED] native.retrieval_payloads`

### Test Specification

**Given**: schema v2 native cards, keywords, folgezettel addresses, and edges  
**When**: recall or line-of-thought runs  
**Then**: output remains camelCase and matches current MCP semantics, including miss shape, truncation flags, all 12 edge types, `trunkSeeds`, and no leakage of native lifecycle/storage-only fields

**Edge Cases**:

- Multi-word keywords normalize to underscore form, e.g. `Design Systems` -> `design_systems`.
- Entry points may be card IDs or slash-form addresses.
- `entryPoints: null` is preserved on miss.
- `limitPerTerm: 0` returns empty kept entries with `truncated: true` when matches exist.
- `reinforces-density` sorting uses inbound `reinforces` count.
- `line_of_thought` includes `trunk_seeds` internally and serializes `trunkSeeds`.
- `line_of_thought_at_address` accepts slash-form addresses and returns the same grouping semantics as card-id lookup.
- Tombstoned cards are excluded from default retrieval.
- `NativeCardRow.status`, `priority`, `scope`, `deleted_at`, and event metadata do not appear in `zk_recall` card payload snapshots unless already part of the current MCP contract.
- Transitional SAI direct-import compatibility can consume snake_case internal retrieval rows only through the explicit SAI behavior below; MCP-facing payloads stay camelCase.

### TDD Cycle

#### Red: Write Failing Test

**File**: `apps/silmari_memory_rust/tests/retrieval_schema_v2.rs`

```rust
#[test]
fn recall_and_line_of_thought_keep_current_mcp_payload_shape_on_v2_schema() {
    let harness = NativeHarness::new_v2();
    harness.seed_keyword("Design Systems", ["5/1", "zk-b"]);

    let recall = silmari_memory_rust::retrieval::recall(
        &harness.conn,
        "design systems",
        RecallOptions::default(),
    ).unwrap();

    assert_eq!(recall.entry_points.as_ref().unwrap().term, "design_systems");
    let json = serde_json::to_value(&recall).unwrap();
    assert!(json.get("entryPoints").is_some());
    assert!(json.get("entry_points").is_none());

    let lot = silmari_memory_rust::retrieval::line_of_thought(&harness.conn, "zk-b").unwrap();
    let lot_json = serde_json::to_value(&lot).unwrap();
    assert!(lot_json.get("trunkSeeds").is_some());
    assert!(lot_json.get("trunk_seeds").is_none());
    assert!(lot_json.get("deleted_at").is_none());

    let by_addr = silmari_memory_rust::retrieval::line_of_thought_at_address(&harness.conn, "5/1").unwrap();
    assert_eq!(by_addr.queried.as_ref().unwrap().id, "zk-b");
}
```

#### Green: Minimal Implementation

**Files**:

- `apps/silmari_memory_rust/src/retrieval.rs`
- `apps/silmari_memory_rust/src/keyword_index.rs`
- `apps/silmari_memory_rust/src/folgezettel.rs`
- `apps/silmari_memory_rust/src/edges.rs`
- existing retrieval tests

Update existing retrieval code and tests to use schema v2 helpers instead of hand-rolled old schemas.

Introduce explicit payload serializers, e.g. `NativeCardRow -> RecallCardPayload` and `NativeCardRow -> CompatCardPayload`, instead of deriving all external JSON from the storage row. Snapshot tests should fail if lifecycle fields leak into recall, neighborhood, or line-of-thought JSON.

**Documentation Contract**:

```rust
/// @rr.id [PROPOSED]
/// @rr.alias native.retrieval_payloads
/// @path.id compose-native-retrieval-payloads
/// @gwt.given native keyword, card, folgezettel, and edge rows
/// @gwt.when recall or line_of_thought composes MCP-facing payloads
/// @gwt.then miss, hit, truncation, cross-ref, and trunkSeeds semantics match current TypeScript output
/// @reads [PROPOSED] native.cards,native.card_labels,native.card_edges,native.keyword_entries,native.trunks
/// @writes [PROPOSED] none
/// @raises [PROPOSED]:RecallError,[PROPOSED]:FolgezettelAddress,[PROPOSED]:EdgeTraversal
/// @schema.contract artifacts/specs/2026-04-28-beads-rust-replacement/05-viewer-export-and-consumers.md::MCP And SAI Contracts
pub fn recall(conn: &rusqlite::Connection, query: &str, opts: RecallOptions) -> crate::Result<RecallSession>;
```

#### Refactor: Improve Code

- Keep a per-call `RecallContext` / trunk scan cache to avoid repeated trunk scans.
- Centralize tombstone filters for retrieval.
- Snapshot CLI JSON for recall and line-of-thought against TypeScript fixtures.

### Success Criteria

Automated verification:

- `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml retrieval_schema_v2`
- `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml line_of_thought_address`
- Existing `keyword_recall`, `neighborhood`, `edges`, and `line_of_thought` tests still pass after fixture migration.

Manual verification:

- Run `recall --json` and verify `entryPoints`, `entryCards`, `neighborhoods`, and `crossRefs` casing.

## Behavior 10: Viewer Export Supports Compatibility And Card-Native Modes

### Resource Registry Binding

- `resource_id`: `[PROPOSED]`
- `address_alias`: `native.viewer_export`
- `predicate_refs`: native cards, labels, edges, keywords, trunk metadata, export mode
- `codepath_ref`: `apps/silmari_memory_rust/src/export.rs::{export_viewer_compat,export_viewer_native}`
- `schema_contract_refs`: `artifacts/specs/2026-04-28-beads-rust-replacement/05-viewer-export-and-consumers.md::Viewer Export Modes`

### Schema Interface Mapping

- `loop_mode`: `summary`
- `mapped_contracts`: `native store -> compatibility issues/dependencies/card_edges`; `native store -> viewer_cards/viewer_edges/viewer_keywords/viewer_export_meta`
- `registry_updates`: `[PROPOSED] native.viewer_export`

### Test Specification

**Given**: native cards with labels, all 12 edge types, keywords, trunks, and blocks  
**When**: viewer export runs in compatibility or card-native mode  
**Then**: the compatibility cache satisfies current viewer table assumptions and the native cache exposes card-native tables with complete typed edges

**Edge Cases**:

- Compatibility `issues.labels` includes preserved and projected labels.
- Compatibility `dependencies` contains only `blocks`, with `issue_id` as the blocking/source card and `depends_on_id` as the blocked target it depends on.
- Compatibility `card_edges` contains all 12 Silmari edge types using current viewer casing: `source`, `target`, `type`.
- Card-native `viewer_edges` contains `review_state`.
- `viewer_export_meta` records source schema version, source DB hash, generator, generated timestamp, and mode.
- Existing viewer link-builder tests still pass with exported compatibility cache.
- Current viewer queries against `issue_overview_mv`, `issues`, `dependencies`, `card_edges`, `issues_fts`, and `export_meta` execute successfully against the Rust compatibility export.

### Viewer Compatibility Export Contract

The compatibility cache is not merely table-name compatible. It must satisfy the current query set used by `apps/silmari-memory-card-viewer/viewer_assets/viewer.js`:

| Table | Required shape |
| --- | --- |
| `issues` | `id`, `title`, `description`, `status`, `priority`, `issue_type`, `assignee`, `labels` as JSON array string, `created_at`, `updated_at`, `closed_at` |
| `dependencies` | `id`, `issue_id`, `depends_on_id`, `type`; only `type='blocks'`; native `card_edges(source_id=A,target_id=B,edge_type='blocks')` exports as `issue_id=A, depends_on_id=B` |
| `issue_overview_mv` | all viewer-selected columns: issue fields plus `pagerank`, `betweenness`, `critical_path_depth`, `triage_score`, `blocks_count`, `blocked_by_count`, `blocker_count`, `dependent_count`, `critical_depth`, `in_cycle`, `comment_count`, `blocks_ids`, `blocked_by_ids` |
| `issues_fts` | FTS5 table over `id`, `title`, `description`, `labels`, and `assignee`, populated enough for current search queries |
| `export_meta` | key/value rows including `version`, `schema_version`, `git_commit`, `source_schema_version`, `source_db_hash`, `generator`, `generated_at`, and `mode` |
| `card_edges` | `source`, `target`, `type`, primary key `(source,target,type)` |

Card-native export uses different names deliberately: `viewer_cards`, `viewer_labels`, `viewer_edges(source_id,target_id,edge_type,review_state,created_at)`, `viewer_keywords`, `viewer_trunks`, and `viewer_export_meta`.

### TDD Cycle

#### Red: Write Failing Test

**File**: `apps/silmari_memory_rust/tests/viewer_export.rs`

```rust
#[test]
fn compatibility_export_writes_issue_shape_and_all_silmari_edges() {
    let harness = NativeHarness::with_all_edge_types();
    let cache = temp_db_path();

    silmari_memory_rust::export::export_viewer_compat(&harness.conn, &cache).unwrap();
    let exported = rusqlite::Connection::open(cache).unwrap();

    assert_has_tables(&exported, &["issues", "dependencies", "card_edges", "issues_fts", "issue_overview_mv", "export_meta"]);
    assert_dependency_types(&exported, &["blocks"]);
    assert_card_edges_include_all_12_types(&exported);
    assert_ref_labels_round_trip_in_issues_labels(&exported);
    assert_current_viewer_queries_execute(&exported);
    assert_blocks_direction(&exported, "zk-source", "zk-target");
}
```

**File**: `apps/silmari-memory-card-viewer/tests/rust-compat-export-contract.test.ts`

```ts
describe('current viewer consumes Rust compatibility export', () => {
  it('loads a Rust-produced cache through current viewer queries without label synthesis', async () => {
    const cache = await exportRustViewerCompatFixture({
      cards: [
        { id: 'zk-source', title: 'Source', labels: ['kind:idea', 'ref:blocks:zk-target'] },
        { id: 'zk-target', title: 'Target', labels: ['kind:idea'] },
      ],
      edges: [{ source: 'zk-source', target: 'zk-target', type: 'blocks' }],
    });

    const db = await openViewerCache(cache, { synthesizeCardEdgesFromLabels: false });
    await expectCurrentViewerQueriesExecute(db);

    const links = await buildLinksFromViewerCache(db);
    expect(links).toContainEqual(expect.objectContaining({
      source: 'zk-source',
      target: 'zk-target',
      type: 'blocks',
    }));
  });
});
```

#### Green: Minimal Implementation

**Files**:

- `apps/silmari_memory_rust/src/export.rs`
- `apps/silmari_memory_rust/src/cli.rs`
- `apps/silmari-memory-card-viewer/tests/server.test.ts`
- `apps/silmari-memory-card-viewer/tests/rust-compat-export-contract.test.ts`
- `apps/silmari-memory-card-viewer/viewer_assets/link-builder.test.js`

Add export module and CLI commands. For compatibility mode, write the table names the current viewer expects. For card-native mode, write `viewer_cards`, `viewer_labels`, `viewer_edges`, `viewer_keywords`, `viewer_trunks`, `viewer_export_meta`, and optional `viewer_fts`.

Compatibility export should reuse or mirror the Go export schema where it is still the viewer contract, then add Silmari-specific `card_edges`. Do not make the browser synthesize native edges from labels when Rust export can write authoritative edge rows.

**Documentation Contract**:

```rust
/// @rr.id [PROPOSED]
/// @rr.alias native.viewer_export
/// @path.id export-native-store-for-viewer
/// @gwt.given a native Silmari memory database and viewer export mode
/// @gwt.when viewer export runs
/// @gwt.then compatibility or card-native cache tables are written with complete card, label, edge, keyword, and metadata contracts
/// @reads [PROPOSED] native.cards,native.card_labels,native.card_edges,native.keyword_entries,native.trunks
/// @writes [PROPOSED] viewer.compat_cache,viewer.native_cache
/// @raises [PROPOSED]:ExportError
/// @schema.contract artifacts/specs/2026-04-28-beads-rust-replacement/05-viewer-export-and-consumers.md::Viewer Export Modes
pub fn export_viewer_compat(conn: &rusqlite::Connection, output_path: &Path) -> crate::Result<ExportSummary>;
```

#### Refactor: Improve Code

- Use projection helpers shared with the TypeScript facade so labels do not drift.
- Add export version constants and major/minor compatibility checks.
- Keep FTS in viewer export only; do not route idea recall through FTS.

### Success Criteria

Automated verification:

- `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml viewer_export`
- `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml viewer_export_queries`
- `bun test apps/silmari-memory-card-viewer/tests/rust-compat-export-contract.test.ts`
- `bun test apps/silmari-memory-card-viewer/tests/server.test.ts`
- `bun test apps/silmari-memory-card-viewer/viewer_assets/link-builder.test.js`

Manual verification:

- Load a compatibility-exported cache through the current viewer and verify graph links preserve edge type.

## Behavior 11: CLI Health, Schema Check, JSON Envelope, And Open Policy Are Stable

### Resource Registry Binding

- `resource_id`: `[PROPOSED]`
- `address_alias`: `native.cli_contract`
- `predicate_refs`: CLI arguments, JSON stdin, native DB path, typed error conditions
- `codepath_ref`: `apps/silmari_memory_rust/src/cli.rs::run`
- `schema_contract_refs`: `artifacts/specs/2026-04-28-beads-rust-replacement/03-store-api-and-adapter.md::Command Groups`; `artifacts/specs/2026-04-28-beads-rust-replacement/03-store-api-and-adapter.md::JSON Error Envelope`

### Schema Interface Mapping

- `loop_mode`: `summary`
- `mapped_contracts`: `CLI command groups -> store/retrieval/import/export APIs`
- `registry_updates`: `[PROPOSED] native.cli_contract`

### Test Specification

**Given**: a CLI invocation with `--json`  
**When**: any native command succeeds or fails  
**Then**: success returns `{ok:true,result,...}` and failure returns `{ok:false,error:{code,message,details}}` with stable code names and DB-open behavior that the TypeScript facade can map

**Edge Cases**:

- `health` against missing DB returns `{ok:true,result:{available:false,code:"DB_NOT_FOUND"}}` or equivalent non-mutating unavailable result, not a panic and not a newly created DB.
- `schema-check` reports found/supported versions.
- Parse errors return JSON when `--json` is present.
- `QUERY_TIMEOUT`, `CARD_NOT_FOUND`, `VALIDATION_ERROR`, `SCHEMA_INCOMPATIBLE`, `DB_NOT_FOUND`, and `CLI_PARSE` are distinct codes.
- The stale code names `DB_MISSING`, `DB_MALFORMED`, `DB_LOCKED`, `PARSE_ERROR`, `POLICY_VIOLATION`, `INPUT_ERROR`, `TIMEOUT`, lowercase `cli_parse`, `sqlite`, and `unknown_edge_type` are invalid in adapter-facing JSON.
- Commands reading JSON input reject unknown or malformed fields with structured details.
- Read commands open existing DBs read-only and never create a missing DB.
- `init` is the only command that creates a missing native DB by default.
- `import-snapshot` creates or replaces a target only according to Behavior 6A safety gates.

### CLI Open Policy And Error Codes

| Command group | DB open policy |
| --- | --- |
| `health`, `schema-check`, `show-card`, `list-cards`, `search-biblio`, `recall`, `neighborhood`, `edges`, `line-of-thought`, `export-viewer` source DB | open read-only existing; missing DB maps to `DB_NOT_FOUND` |
| `create-card`, `create-cards`, `update-card`, `delete-card`, `close-card`, `label-add`, `label-remove`, `edge-add`, `edge-remove` | open read/write existing; missing DB maps to `DB_NOT_FOUND` |
| `init` | create if missing; reject incompatible existing DB |
| `create-snapshot` | read-only sources, write-only snapshot directory |
| `import-snapshot` | read-only verified snapshot, write staging target, promote according to replace safety |
| `export-viewer` output DB | create new output or replace only with explicit output replace flag |

`NativeEnvelope<T>` is the only JSON shape emitted under `--json`:

```json
{ "ok": true, "result": {}, "meta": {} }
```

or:

```json
{ "ok": false, "error": { "code": "CARD_NOT_FOUND", "message": "string", "details": {} } }
```

The success payload key is `result`. The earlier CW9 research draft's `{ok:true,data}` wording is superseded by this plan and must not be used in generated tests.

```rust
pub enum ErrorCode {
    CardNotFound,       // CARD_NOT_FOUND
    QueryTimeout,       // QUERY_TIMEOUT
    ValidationError,    // VALIDATION_ERROR
    SchemaIncompatible, // SCHEMA_INCOMPATIBLE
    DbNotFound,         // DB_NOT_FOUND
    CliParse,           // CLI_PARSE
}
```

The `gwt-0004` TLA+ model, bridge artifact, context file, simulation traces, and generated tests must be regenerated or amended from this exact contract. A coverage pass is invalid if any of those artifacts still mention the superseded code set or raw recall success JSON.

### TDD Cycle

#### Red: Write Failing Test

**File**: `apps/silmari_memory_rust/tests/adapter_cli_contract.rs`

```rust
#[test]
fn cli_errors_use_adapter_mapping_codes() {
    Command::cargo_bin("silmari_memory_rust")
        .unwrap()
        .args(["show-card", "--db", "/tmp/missing-native.db", "--id", "zk-missing", "--json"])
        .assert()
        .failure()
        .stdout(predicate::str::contains("\"ok\":false"))
        .stdout(predicate::str::contains("\"code\":\"DB_NOT_FOUND\""));

    let db = temp_initialized_db();
    Command::cargo_bin("silmari_memory_rust")
        .unwrap()
        .args(["show-card", "--db", db.to_str().unwrap(), "--id", "zk-missing", "--json"])
        .assert()
        .failure()
        .stdout(predicate::str::contains("\"ok\":false"))
        .stdout(predicate::str::contains("\"code\":\"CARD_NOT_FOUND\""));
}

#[test]
fn cli_successes_always_emit_result_envelope() {
    let db = temp_initialized_db();

    Command::cargo_bin("silmari_memory_rust")
        .unwrap()
        .args(["health", "--db", db.to_str().unwrap(), "--json"])
        .assert()
        .success()
        .stdout(predicate::str::contains("\"ok\":true"))
        .stdout(predicate::str::contains("\"result\""))
        .stdout(predicate::str::contains("\"data\"").not());

    Command::cargo_bin("silmari_memory_rust")
        .unwrap()
        .args(["list-cards", "--db", db.to_str().unwrap(), "--box", "idea", "--label", "missing:nope", "--json"])
        .assert()
        .success()
        .stdout(predicate::str::contains("\"ok\":true"))
        .stdout(predicate::str::contains("\"result\":[]"));
}

#[test]
fn cli_open_policy_and_error_codes_match_gwt_0004_contract() {
    let missing = tempdir().unwrap().path().join("missing-native.db");

    Command::cargo_bin("silmari_memory_rust")
        .unwrap()
        .args(["recall", "--db", missing.to_str().unwrap(), "--query", "x", "--json"])
        .assert()
        .failure()
        .stdout(predicate::str::contains("\"ok\":false"))
        .stdout(predicate::str::contains("\"code\":\"DB_NOT_FOUND\""));

    assert!(!missing.exists());

    assert_no_adapter_error_code(&[
        "DB_MISSING",
        "DB_MALFORMED",
        "DB_LOCKED",
        "PARSE_ERROR",
        "POLICY_VIOLATION",
        "INPUT_ERROR",
        "\"TIMEOUT\"",
        "\"sqlite\"",
        "\"unknown_edge_type\"",
        "\"cli_parse\"",
    ]);
}

#[test]
fn generated_gwt_0004_trace_replay_covers_envelope_and_open_policy() {
    let traces = load_cw9_traces("gwt-0004");
    assert_every_trace_asserts_operations(&traces, &[
        "SelectPolicy",
        "CheckInput",
        "OpenDatabase",
        "CheckWritePolicy",
        "CheckTimeout",
        "ExecuteCommand",
        "Terminate",
    ]);
    assert_trace_outcome_exists(&traces, |final_state| {
        final_state.cmd == "Read"
            && final_state.db_state == "Missing"
            && final_state.error_code == "DB_NOT_FOUND"
            && !final_state.db_created
    });
    assert_trace_outcome_exists(&traces, |final_state| {
        final_state.envelope_ok
            && final_state.result_empty
            && final_state.error_code == "NONE"
            && final_state.result_present
    });
}
```

#### Green: Minimal Implementation

**Files**:

- `apps/silmari_memory_rust/src/cli.rs`
- `apps/silmari_memory_rust/src/error.rs`

Add the complete command groups from the adapter spec and normalize success/error envelopes.

Implement command execution through a shared open-policy layer so read commands cannot accidentally create SQLite files. CLI parsing errors, DB open errors, schema errors, validation errors, and operation errors all serialize through `NativeEnvelope`.

**Documentation Contract**:

```rust
/// @rr.id [PROPOSED]
/// @rr.alias native.cli_contract
/// @path.id run-native-memory-json-cli
/// @gwt.given CLI args, optional JSON stdin, and a native DB path
/// @gwt.when the native memory CLI executes
/// @gwt.then stable JSON success and error envelopes are emitted for the TypeScript facade
/// @reads [PROPOSED] native.cards,native.card_labels,native.card_edges,native.keyword_entries,native.schema_versions
/// @writes [PROPOSED] native.cards,native.card_labels,native.card_edges,native.keyword_entries,native.card_events,native.viewer_exports
/// @raises [PROPOSED]:CliError
/// @schema.contract artifacts/specs/2026-04-28-beads-rust-replacement/03-store-api-and-adapter.md::JSON Error Envelope
pub fn run(args: impl IntoIterator<Item = String>) -> Result<i32, crate::Error>;
```

#### Refactor: Improve Code

- Keep CLI parser separate from command execution.
- Add JSON schema snapshot fixtures for command inputs.
- Use one `ErrorCode` enum so Rust and TypeScript mapping tests can share code strings.
- Add filesystem assertions in CLI tests that missing read DB paths are still absent after failed commands.
- Regenerate `gwt-0004` artifacts after changing the model. Do not hand-edit generated tests alone while the `.tla` model still contains stale error-code vocabulary.

### Success Criteria

Automated verification:

- `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml adapter_cli_contract`
- Existing `apps/silmari_memory_rust/tests/cli_contract.rs` updated or replaced without losing recall JSON coverage.
- `pytest tests/generated/test_gwt_0004.py`
- `rg "DB_MISSING|PARSE_ERROR|POLICY_VIOLATION|INPUT_ERROR|unknown_edge_type|\\\"sqlite\\\"|\\\"cli_parse\\\"" .cw9 tests/generated/test_gwt_0004.py` returns no adapter-facing stale contract matches.

Manual verification:

- Run `silmari_memory_rust health --db <missing> --json` and verify structured JSON instead of stderr-only output.

## Behavior 12: Runtime Modes, Rollback Switches, And SAI Consumers Are Contracted

### Resource Registry Binding

- `resource_id`: `[PROPOSED]`
- `address_alias`: `mcp.runtime_modes_sai`
- `predicate_refs`: runtime mode source, facade routing, rollback config, SAI recall hook input/output
- `codepath_ref`: `apps/silmari-mcp/src/lib/native-mode.ts`; `apps/silmari-mcp/src/lib/br-adapter.ts`; `SAI/hooks/ThinkWithMemory.hook.ts`; `SAI/hooks/lib/think-with-memory.ts`
- `schema_contract_refs`: `artifacts/specs/2026-04-28-beads-rust-replacement/01-system-architecture.md::Runtime Modes`; `artifacts/specs/2026-04-28-beads-rust-replacement/05-viewer-export-and-consumers.md::MCP Payload Flow`

### Schema Interface Mapping

- `loop_mode`: `summary`
- `mapped_contracts`: `mode config -> adapter routing -> MCP/SAI payload stability`
- `registry_updates`: `[PROPOSED] mcp.runtime_modes_sai`

### Test Specification

**Given**: configured runtime modes and a SAI hook fixture that currently reaches into MCP internals
**When**: modes switch between `legacy-br`, `shadow-read`, `shadow-write`, `native-primary`, and `legacy-read-only`
**Then**: all MCP call sites route through the facade, rollback is a config switch, and SAI receives the same `RecallSummary { keywordEntries, folgezettelNeighbors, crossRefs }` shape under native mode

**Edge Cases**:

- `import-only` mode allows diagnostics/import/export but blocks runtime writes.
- `shadow-read` returns legacy-visible results and records read parity.
- `shadow-write` writes legacy first, then native, and records reconciliation when cross-store writes differ.
- `native-primary` reads/writes native and keeps legacy DBs untouched for rollback.
- `legacy-read-only` blocks writes except diagnostics and lets rollback smoke tests inspect pre-cutover data.
- Mode switches are driven by config/environment, not code edits.
- SAI no longer imports low-level `keyword-index.ts`, `br-adapter.ts`, `navigate.ts`, and `labels.ts` directly. It imports a single public memory client shim that consumes MCP-shaped recall or the mode-aware facade.
- The SAI shim normalizes the transitional internal snake_case `entry_points` shape only inside the shim; Rust and MCP direct outputs remain camelCase.
- Transitional raw sources may produce `entryCards`; the public SAI shim maps those to `keywordEntries` before calling `buildInjection()`. `entryCards` is an internal alias, not the public hook output contract.
- Invalid mode config is a typed `ModeConfigError`, not silent fallback. Fallback to `legacy-br` happens only when no env override and no config file exist.

### NativeModeConfig Contract

Mode is scoped to one Silmari root, not per box. Mixed per-box runtime modes are disallowed in v1 because dedupe, `fromAddress`, recall, and viewer export cross box boundaries through shared reports and mode gates.

Resolution order:

1. Test override injected through `withModeRoutingHarness()`; available only in tests.
2. `SILMARI_MEMORY_MODE`, if set.
3. `SILMARI_MEMORY_CONFIG`, if set, otherwise `${SILMARI_DIR:-~/.silmari}/config/native-memory-mode.json`.
4. Default `legacy-br` when no env override and no config file exist.

`NativeModeConfig` JSON:

```json
{
  "version": 1,
  "mode": "legacy-br|import-only|shadow-read|shadow-write|native-primary|legacy-read-only",
  "nativeDbPath": "~/.silmari/native/silmari-memory.sqlite",
  "shadowReportDir": "~/.silmari/reports/shadow",
  "reconciliationReportDir": "~/.silmari/reports/reconciliation",
  "updatedAt": "2026-04-28T00:00:00Z",
  "updatedBy": "human-or-agent-id"
}
```

Validation rules:

- Unknown keys are allowed but preserved only in diagnostics; they cannot change behavior.
- `version` must be `1`.
- `mode` must be one of the six `SilmariMemoryMode` values.
- `nativeDbPath` is required for `import-only`, `shadow-read`, `shadow-write`, `native-primary`, and `legacy-read-only`.
- `shadowReportDir` and `reconciliationReportDir` are required for shadow modes.
- Relative paths are rejected; `~`, `$HOME`, and `${HOME}` may be expanded with the same path rules as `paths.ts`.
- Invalid `SILMARI_MEMORY_MODE` or invalid config file returns `ModeConfigError` and blocks runtime writes. It does not fall back silently.
- Config-only rollback means changing only this file or `SILMARI_MEMORY_MODE`, never source code.

Public SAI shim type:

```ts
export interface RecurrenceCard {
  id: string;
  title: string;
}

export interface RecallSummary {
  keywordEntries: RecurrenceCard[];
  folgezettelNeighbors: RecurrenceCard[];
  crossRefs: RecurrenceCard[];
}

export interface SaiMemoryClient {
  recall(query: string, options?: { expandCrossRefs?: boolean; maxDepth?: number }): Promise<RecallSummary>;
}
```

### TDD Cycle

#### Red: Write Failing Tests

**File**: `apps/silmari-mcp/tests/native-mode-routing.test.ts`

```ts
describe('runtime mode routing', () => {
  it.each(['legacy-br', 'shadow-read', 'shadow-write', 'native-primary', 'legacy-read-only'] as const)(
    'routes all public adapter exports through %s mode',
    (mode) => {
      const harness = createModeHarness({ mode });
      harness.callSaveRecallBlockAndResourceFlow();
      expect(harness.unroutedImports()).toEqual([]);
      expect(harness.rollbackSwitchRequiredCodeChange()).toBe(false);
    },
  );
});
```

**File**: `apps/silmari-mcp/tests/native-mode-config-contract.test.ts`

```ts
describe('NativeModeConfig contract', () => {
  it('applies test override, env, config file, then default precedence through public exports', async () => {
    const configPath = await writeNativeModeConfig({
      mode: 'native-primary',
      nativeDbPath: await nativeFixtureDbPath(),
    });

    await withEnv({ SILMARI_MEMORY_CONFIG: configPath }, async () => {
      expect(resolveSilmariMemoryMode(process.env, undefined).mode).toBe('native-primary');
      await expect(brList({ box: 'idea' })).resolves.toEqual(expect.any(Array));
    });

    await withEnv({ SILMARI_MEMORY_MODE: 'legacy-read-only', SILMARI_MEMORY_CONFIG: configPath }, async () => {
      expect(resolveSilmariMemoryMode(process.env, undefined).mode).toBe('legacy-read-only');
    });

    await withEnv({}, async () => {
      expect(resolveSilmariMemoryMode(process.env, undefined).mode).toBe('legacy-br');
    });
  });

  it('blocks runtime writes on invalid config and supports config-only rollback', async () => {
    const configPath = await writeNativeModeConfig({
      mode: 'native-primary',
      nativeDbPath: await nativeFixtureDbPath(),
    });

    await overwriteFile(configPath, '{"version":1,"mode":"not-a-mode"}');
    await withEnv({ SILMARI_MEMORY_CONFIG: configPath }, async () => {
      await expect(brCreate('idea', 'invalid config write canary')).rejects.toMatchObject({
        name: 'ModeConfigError',
      });
    });

    await writeNativeModeConfig({
      path: configPath,
      mode: 'legacy-read-only',
      nativeDbPath: await nativeFixtureDbPath(),
    });
    await withEnv({ SILMARI_MEMORY_CONFIG: configPath }, async () => {
      expect(resolveSilmariMemoryMode(process.env, undefined).mode).toBe('legacy-read-only');
      expect(sourceFilesChangedForRollback()).toEqual([]);
    });
  });
});
```

**File**: `apps/silmari-mcp/tests/sai-think-with-memory-native.test.ts`

```ts
describe('SAI ThinkWithMemory native compatibility', () => {
  it('builds the same hook recall layers through the public memory client shim', async () => {
    const harness = createSaiMemoryHarness({ mode: 'native-primary' });
    harness.seedRecall({
      keywordEntries: [{ id: 'zk-a', title: 'Alpha' }],
      folgezettelNeighbors: [{ id: 'zk-b', title: 'Bravo' }],
      crossRefs: [{ id: 'zk-c', title: 'Charlie' }],
    });

    const injected = await harness.runThinkWithMemory('alpha');

    expect(injected.recall.keywordEntries).toHaveLength(1);
    expect(injected.recall.folgezettelNeighbors).toHaveLength(1);
    expect(injected.recall.crossRefs).toHaveLength(1);
    expect(harness.lowLevelMcpInternalImports()).toEqual([]);
  });

  it('maps transitional entryCards and snake_case entry_points inside the shim only', async () => {
    const harness = createSaiMemoryHarness({ mode: 'legacy-br' });
    harness.seedLegacyKeywordHit({ entry_points: ['zk-a'] });
    harness.seedLegacyCard({ id: 'zk-a', title: 'Alpha' });

    const summary = await harness.client.recall('alpha');

    expect(summary.keywordEntries).toEqual([{ id: 'zk-a', title: 'Alpha' }]);
    expect('entryCards' in summary).toBe(false);
  });
});
```

**File**: `SAI/hooks/tests/think-with-memory-native-boundary.test.ts`

```ts
describe('ThinkWithMemory public native boundary', () => {
  it('loads only the public memory client shim and normalizes native recall shape', async () => {
    const harness = await createThinkWithMemoryBoundaryHarness({ mode: 'native-primary' });
    harness.seedPublicMemoryClient({
      keywordEntries: [{ id: 'zk-a', title: 'Alpha' }],
      folgezettelNeighbors: [{ id: 'zk-b', title: 'Bravo' }],
      crossRefs: [{ id: 'zk-c', title: 'Charlie' }],
    });

    const injected = await harness.runHook('alpha');

    expect(injected.recall).toEqual({
      keywordEntries: [{ id: 'zk-a', title: 'Alpha' }],
      folgezettelNeighbors: [{ id: 'zk-b', title: 'Bravo' }],
      crossRefs: [{ id: 'zk-c', title: 'Charlie' }],
    });
    expect(harness.loadedModules()).toContain('apps/silmari-mcp/src/lib/sai-memory-client.ts');
    expect(harness.loadedModules()).not.toEqual(expect.arrayContaining([
      'apps/silmari-mcp/src/lib/keyword-index.ts',
      'apps/silmari-mcp/src/lib/navigate.ts',
      'apps/silmari-mcp/src/lib/labels.ts',
      'apps/silmari-mcp/src/lib/br-adapter.ts',
    ]));
  });
});
```

#### Green: Minimal Implementation

**Files**:

- `apps/silmari-mcp/src/lib/native-mode.ts`
- `apps/silmari-mcp/src/lib/br-adapter.ts`
- `apps/silmari-mcp/src/lib/sai-memory-client.ts`
- `SAI/hooks/ThinkWithMemory.hook.ts`
- `SAI/hooks/lib/think-with-memory.ts`
- `apps/silmari-mcp/tests/native-mode-config-contract.test.ts`
- `apps/silmari-mcp/tests/native-mode-routing.test.ts`
- `apps/silmari-mcp/tests/sai-think-with-memory-native.test.ts`
- `SAI/hooks/tests/think-with-memory-native-boundary.test.ts`

Add a single mode resolver and a public SAI memory client shim. Remove direct SAI imports of low-level MCP internals or quarantine them behind the shim with explicit transitional tests.

**Documentation Contract**:

```ts
/**
 * @rr.id [PROPOSED]
 * @rr.alias mcp.runtime_modes_sai
 * @path.id resolve-runtime-mode-and-sai-memory-client
 * @gwt.given runtime configuration and SAI recall input
 * @gwt.when MCP/SAI memory operations run
 * @gwt.then facade routing, rollback mode switching, and SAI recall layer shapes remain stable
 * @reads [PROPOSED] mcp.runtime_config,native.cli_json,legacy.br_json
 * @writes [PROPOSED] migration.shadow_report,migration.reconciliation_events
 * @raises [PROPOSED]:ModeConfigError,[PROPOSED]:SaiMemoryClientError
 * @schema.contract artifacts/specs/2026-04-28-beads-rust-replacement/05-viewer-export-and-consumers.md::MCP Payload Flow
 */
export function resolveSilmariMemoryMode(env: NodeJS.ProcessEnv, config: unknown): SilmariMemoryMode;
```

#### Refactor: Improve Code

- Keep SAI hook output composition pure in `SAI/hooks/lib/think-with-memory.ts`; make storage access injectable.
- Add a mode banner only to debug logs, not to MCP payloads.
- Use the same normalized recall fixture for MCP and SAI tests.
- Keep the mode config reader side-effect free; writes to the config file happen through an explicit cutover/rollback command or operator edit.

### Success Criteria

Automated verification:

- `bun test apps/silmari-mcp/tests/native-mode-config-contract.test.ts`
- `bun test apps/silmari-mcp/tests/native-mode-routing.test.ts`
- `bun test apps/silmari-mcp/tests/sai-think-with-memory-native.test.ts`
- `bun test SAI/hooks/tests/think-with-memory-native-boundary.test.ts`

Manual verification:

- Flip mode from `native-primary` to `legacy-read-only` in config and run a recall smoke without code changes.

## Integration And E2E Testing

### Integration Scenarios

- Import a legacy snapshot, run native `show-card`, `list-cards`, `recall`, `line-of-thought`, and `edge-list`, then compare normalized results to legacy queries.
- Create a card in shadow-write mode and verify legacy-visible output, native row, event row, labels, edges, and keyword entries.
- Batch-create three cards and verify ordered `zk_save_cards` payload parity.
- Add a `blocks` edge and verify native `card_edges`, compatibility `dep-list`, viewer compatibility `dependencies`, and card-native `viewer_edges`.
- Export a compatibility viewer cache and run existing viewer tests.
- Run SAI ThinkWithMemory native-mode fixtures to ensure the hook path receives `keywordEntries`, `folgezettelNeighbors`, and `crossRefs` without low-level MCP internal imports.
- Run the cached transcript pipeline with native-primary storage first, then `CASCADE_ENRICHMENT_MODE=after-import` and both `CASCADE_GATE_B_CLASSIFIER_MODE=source` and `bundle` against imported card IDs.
- Verify `CASCADE_ENRICHMENT_MODE=off` stops after import-only reporting and does not spawn MCP, create hubs, add keywords, call the LLM, or commit Gate B edges.
- Verify `CASCADE_ENRICHMENT_MODE=enrich-only` reuses an existing native import report and runs only enrichment plus Gate B.
- Force a bundle classifier timeout/unavailable/unparseable response and assert Gate B writes a fatal failure report instead of accepting a zero-edge success.

### E2E Smoke Flow

1. Create a read-only snapshot and verify the snapshot manifest hashes.
2. Import the verified snapshot to a new native staging DB.
3. Run parity gates for show, list, biblio search, content-hash lookup, fromAddress lookup, recall, line-of-thought by ID and address, blocks, viewer export, and SAI hook output.
4. In `native-primary`, remove or corrupt the legacy `beads.db` fixtures and rerun content-hash lookup plus `fromAddress` lookup to prove label lookup is native-routed.
5. Run a cached transcript import in `native-primary` with `CASCADE_ENRICHMENT_MODE=off`; assert the report contains imported card IDs and no enrichment/Gate B side effects.
6. Re-run the same transcript with `CASCADE_ENRICHMENT_MODE=after-import` and `CASCADE_GATE_B_CLASSIFIER_MODE=source`; assert Gate B reads imported native IDs and records source-mode telemetry.
7. Re-run or replay with `CASCADE_ENRICHMENT_MODE=enrich-only` and `CASCADE_GATE_B_CLASSIFIER_MODE=bundle`; assert bundle telemetry fields are present and accepted reviewed edges commit only after validation.
8. Promote the staging DB only after reports are complete.
9. Enable `shadow-read` mode.
10. Run MCP tool smoke tests: `zk_save_card`, `zk_save_cards`, `zk_recall`, `zk_line_of_thought`, `zk_block`, `zk_propose_links_semantic`, `zk_propose_link`, `zk_commit_link`, biblio add/search, and `silmari://card/<id>`.
11. Enable `shadow-write` mode and repeat write smoke tests, including reconciliation report inspection.
12. Advance to `native-primary` only after report gates show no unexplained differences.
13. Flip to `legacy-read-only` and back to `native-primary` through config only to prove rollback switch semantics.

## Required Quality Gates

- Boundary contract remediation gate:
  - `bun test apps/silmari-mcp/tests/native-cli-contract.test.ts`
  - `bun test apps/silmari-mcp/tests/native-mcp-dispatch-contract.test.ts`
  - `bun test apps/silmari-mcp/tests/native-mode-config-contract.test.ts`
  - `bun test apps/silmari-mcp/tests/native-shadow-contract.test.ts`
  - `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml import_snapshot_cli_contract`
  - `bun test apps/silmari-memory-card-viewer/tests/rust-compat-export-contract.test.ts`
  - `bun test SAI/hooks/tests/think-with-memory-native-boundary.test.ts`
  - Follow-up `04cw9-Plan-Review` must derive real source-backed transcripts for BC-1, BC-2, BC-3, BC-4, and BC-8 after the first implementation slice creates the planned producer files.
- Coverage remediation gate before implementation:
  - `pytest tests/generated/test_gwt_0001.py tests/generated/test_gwt_0004.py tests/generated/test_gwt_0006.py`
  - `cw9 test /home/maceo/Dev/silmari-agent-memory`
  - `cw9 status /home/maceo/Dev/silmari-agent-memory --json` must show every `gwt-0001` through `gwt-0008` as `result: pass` and `bridge_done: true`
  - Follow-up coverage review must pass for `gwt-0001`, `gwt-0004`, and `gwt-0006`
  - Follow-up abstraction review must pass for `gwt-0001`, `gwt-0002`, `gwt-0003`, and `gwt-0006` after context/artifact regeneration
  - Follow-up cross-layer review must pass for native create, CLI envelope, runtime modes, and SAI shim protocol transcripts after the boundary scaffolding slice and before durable native-primary behavior
  - No stale `gwt-0004` adapter-facing vocabulary: `rg "DB_MISSING|PARSE_ERROR|POLICY_VIOLATION|INPUT_ERROR|unknown_edge_type|\\\"sqlite\\\"|\\\"cli_parse\\\"" .cw9 tests/generated/test_gwt_0004.py` returns no matches except explicitly marked historical review text outside artifacts
  - Bridge-only helpers are documented as helpers and not claimed as TLC-backed proof unless named in `.cfg`
- `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml`
- `bun test apps/silmari-mcp/tests`
- `bun test apps/silmari-memory-card-viewer/tests apps/silmari-memory-card-viewer/viewer_assets`
- `go test ./...` from `apps/silmari-viewer` if exporter code changes
- `bun test apps/silmari-mcp/tests/native-mode-routing.test.ts apps/silmari-mcp/tests/native-mode-config-contract.test.ts apps/silmari-mcp/tests/sai-think-with-memory-native.test.ts`
- `bun test SAI/hooks/tests/think-with-memory-native-boundary.test.ts`
- Processing pipeline boundary gate:
  - `bun test apps/silmari-mcp/tests/semantic-proposer.test.ts`
  - `bun test apps/silmari-mcp/tests/zk-propose-links-semantic.test.ts`
  - `bun test scripts/kc-baker-pipeline-v2/tests/ingest-cascade.test.ts`
  - Native-primary cached transcript smoke proves `CASCADE_ENRICHMENT_MODE=off` imports only, `after-import` imports before enrichment/Gate B, and `enrich-only` reuses an existing native import report.
  - Gate B classifier smoke covers `CASCADE_GATE_B_CLASSIFIER_MODE=source` and `bundle`.
  - Bundle-mode report assertions cover `classifier_mode`, `bundles_submitted`, `bundle_cards_submitted`, `bundle_unique_cards_hydrated`, `bundle_prompt_chars_total`, `bundle_prompt_chars_max`, `edges_returned_raw`, `edges_rejected_validation`, `edges_rejected_caps`, `llm_calls_attempted`, `llm_latency_ms_total`, and `edges_committed`.
  - Bundle timeout/unavailable/unparseable classifier output writes a Gate B failure report and aborts the remaining transcript run instead of reporting zero-edge success.
  - A fake or corrupt legacy `br`/`beads.db` must not be required for native-primary transcript validation.
- `rg "search_issues|LIKE" apps/silmari_memory_rust/src` must show no idea-recall implementation
- `rg "br " apps/silmari-mcp/src apps/silmari_memory_rust/src` must show no production `br` subprocess use after native-primary cleanup
- `rg "from './br-sqlite\\.js'|from \\\"./br-sqlite\\.js\\\"" apps/silmari-mcp/src` must show only the legacy adapter-owned implementation, not `card-ops.ts` or MCP call sites

## Implementation Order

1. Regenerate or amend the coverage-blocked CW9 artifacts and generated tests for `gwt-0001`, `gwt-0004`, and `gwt-0006`; amend `.cw9/context/gwt-0001.md`, `gwt-0002.md`, `gwt-0003.md`, and `gwt-0006.md` with the abstraction-remediation contracts above; rerun `cw9 test`; rerun coverage and abstraction reviews. The follow-up boundary review is expected to remain blocked until slice 2 creates the planned producer files.
2. Boundary scaffolding slice: add `native-adapter.ts`, `legacy-br-adapter.ts`, `native-mode.ts`, `native-shadow.ts`, `sai-memory-client.ts`, Rust `migration.rs`, `export.rs`, `parity.rs`, and `report.rs`; add the seven boundary contract test files named in `## Assumed Existing Contracts`.
3. CLI envelope, DB-open policy, and enough command surface for `native-cli-contract.test.ts` to spawn the real binary and prove `NativeEnvelope<T>`.
4. TypeScript facade interface, native label lookup routing, real MCP dispatch/resource routing, mode config contract, `zk_block` contract test, and shadow parity.
5. Rerun `04cw9-Plan-Review`; do not advance to durable native-primary behavior until it can derive real transcripts for BC-1, BC-2, BC-3, BC-4, and BC-8.
6. Schema v2, native v1-to-v2 migration, required indexes, and model types.
7. Label projection, `scope:*`, edge referential integrity, and `EdgeWriteAuthority`.
8. Single-card create transaction and event emission, including body-hash
   recurrence through the internal reviewed-edge helper and no TypeScript
   native post-save bridge.
9. CRUD/list/show/search-biblio/label/edge APIs.
10. Batch create plus shadow-write reconciliation records for legacy partial-write divergence.
11. Snapshot creation, manifest hashing, CLI snapshot-to-import transcript, and `--replace` safety gates.
12. Verified snapshot import, accepted-review manifest consumption, staging promotion, reports, and field disposition.
13. Retrieval fixture migration to schema v2 with serializer boundary snapshots.
14. Viewer export compatibility/native modes with Rust cache loaded by current viewer query execution.
15. Processing pipeline validation slice: update or preserve `specs/processing-pipeline.md`, `semantic-proposer.prompt.md`, `semantic-proposer.ts`, `semantic-proposer.test.ts`, and `ingest-cascade.test.ts` so native-primary cached transcript import, enrichment modes, source/bundle Gate B classifier modes, bundle telemetry, and failure-report behavior are all covered.
16. Runtime mode rollback tests and SAI ThinkWithMemory public-shim remediation.
17. Native-primary cleanup and documentation.

## References

- Spec index: `artifacts/specs/2026-04-28-beads-rust-replacement/README.md`
- CW9 research wrapper: `thoughts/searchable/shared/research/2026-04-28-cw9-card-native-beads-rust-replacement.md`
- Primary research: `thoughts/searchable/shared/research/2026-04-28-data-model-beads-rust-replacement.md`
- Major-review findings incorporated: `thoughts/searchable/shared/plans/2026-04-28-silmari-agent-memory-dbh-tdd-card-native-beads-rust-replacement-REVIEW.md`
- Follow-up-review findings incorporated: `thoughts/searchable/shared/plans/2026-04-28-silmari-agent-memory-dbh-tdd-card-native-beads-rust-replacement-REVIEW-2.md`
- CW9 artifact review: `thoughts/searchable/shared/plans/2026-04-28-card-native-beads-rust-replacement-ARTIFACTS-REVIEW.md`
- Coverage review: `thoughts/searchable/shared/plans/2026-04-28-silmari-agent-memory-dbh-tdd-card-native-beads-rust-replacement-COVERAGE-REVIEW.md`
- Abstraction review: `thoughts/searchable/shared/plans/2026-04-28-silmari-agent-memory-dbh-tdd-card-native-beads-rust-replacement-ABSTRACTION-REVIEW.md`
- Boundary contract review: `thoughts/searchable/shared/plans/2026-04-28-silmari-agent-memory-dbh-tdd-card-native-beads-rust-replacement-CONTRACT-REVIEW.md`
- Processing pipeline spec: `specs/processing-pipeline.md`
- Accepted-edge native durability plan:
  `thoughts/searchable/shared/plans/2026-04-30-silmari-agent-memory-1c0-tdd-native-primary-accepted-edge-card-edges.md`
- Semantic proposer source prompt: `apps/silmari-mcp/src/lib/semantic-proposer.prompt.md`
- Semantic proposer implementation: `apps/silmari-mcp/src/lib/semantic-proposer.ts`
- Processing pipeline tests: `apps/silmari-mcp/tests/semantic-proposer.test.ts`, `scripts/kc-baker-pipeline-v2/tests/ingest-cascade.test.ts`
- Follow-up tracking issue: `silmari-agent-memory-j8v`
- Abstraction gap tracking issue: `silmari-agent-memory-dbh.1`
- Boundary contract tracking issue: `silmari-agent-memory-dbh.2`
- Follow-up REVIEW-2 tracking issue: `silmari-agent-memory-e3f`
- Prior review gate: `thoughts/searchable/shared/plans/2026-04-27-tdd-silmari-memory-rust-retrieval-substrate-REVIEW.md`
- Current Rust schema: `apps/silmari_memory_rust/src/schema.rs:57`
- Current Rust store: `apps/silmari_memory_rust/src/store.rs:17`
- Current Rust CLI: `apps/silmari_memory_rust/src/cli.rs:24`
- Current adapter semantics: `apps/silmari-mcp/src/lib/br-adapter.ts:167`
- Current save pipeline: `apps/silmari-mcp/src/lib/card-ops.ts:786`
- Current edge vocabulary: `apps/silmari-mcp/src/lib/labels.ts:79`
- Current viewer compatibility edge synthesis: `apps/silmari-memory-card-viewer/server.ts:141`
- Current viewer export schema: `apps/silmari-viewer/pkg/export/sqlite_schema.go:41`
