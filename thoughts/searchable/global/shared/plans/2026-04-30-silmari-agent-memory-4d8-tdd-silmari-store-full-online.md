---
date: 2026-04-30T17:25:00-04:00
planner: VioletBeacon
repository: silmari-agent-memory
branch: main
topic: "TDD plan - bring Silmari Store fully online"
type: tdd_plan
status: implementation_in_progress
parent_bead: silmari-agent-memory-4d8
related_beads:
  - silmari-agent-memory-4d8.1
  - silmari-agent-memory-4d8.2
  - silmari-agent-memory-4d8.3
  - silmari-agent-memory-4d8.4
  - silmari-agent-memory-4d8.5
  - silmari-agent-memory-4d8.6
  - silmari-agent-memory-4d8.7
  - silmari-agent-memory-4d8.8
  - silmari-agent-memory-4d8.9
  - silmari-agent-memory-4d8.10
  - silmari-agent-memory-4d8.11
  - silmari-agent-memory-4d8.12
  - silmari-agent-memory-4d8.13
  - silmari-agent-memory-e8u
  - silmari-agent-memory-9hn
  - silmari-agent-memory-6jp
  - silmari-agent-memory-rkl
official_name: Silmari Store
short_description: "the native storage application for Silmari Memory"
cli_binary: silmari-store
rust_crate: silmari_store
db_wording: "Silmari native store"
migration_wording: "Silmari Store replaces beads_rust as the storage layer for Silmari Memory."
related_specs:
  - artifacts/specs/2026-04-28-beads-rust-replacement/README.md
  - artifacts/specs/2026-04-28-beads-rust-replacement/01-system-architecture.md
  - artifacts/specs/2026-04-28-beads-rust-replacement/02-native-data-model.md
  - artifacts/specs/2026-04-28-beads-rust-replacement/03-store-api-and-adapter.md
  - artifacts/specs/2026-04-28-beads-rust-replacement/04-migration-cutover-and-verification.md
  - artifacts/specs/2026-04-28-beads-rust-replacement/05-viewer-export-and-consumers.md
---

# Silmari Store Full Online TDD Implementation Plan

## Overview

Bring **Silmari Store** fully online as the production storage application for
Silmari Memory. The DBH/native-store implementation is green for the covered
core native-primary paths, but the production flip is not complete until the
MCP server can run native-primary safely, the remaining write surfaces are
native-backed or explicitly disabled, migration/shadow evidence exists, the
viewer can load native exports, and rollback is an exercised operator path.

This plan is intentionally not another generic `beads_rust` replacement plan.
It is the final production-readiness plan for moving from "native store exists
and core tests pass" to "Silmari Store is online and safe to operate."

Review remediation status: GreenBridge reviewed the first draft in
`thoughts/searchable/shared/plans/2026-04-30-silmari-agent-memory-4d8-tdd-silmari-store-full-online-REVIEW.md`
and opened blocker `silmari-agent-memory-4d8.1`. This revision pins every
contract that review identified as underspecified. Implementation child beads
must not be split from this plan until `4d8.1` is closed.

## Current State Analysis

The 2026-04-28 spec package defines the target system as one authoritative
card-native SQLite store behind a Rust API and a TypeScript compatibility
facade. It requires preserving two boxes, adapter return semantics, label
round-trips, `blocks` compatibility, all 12 semantic edge types, and stable
MCP/SAI payloads during cutover.

### Key Discoveries

- Runtime modes are wired in `apps/silmari-mcp/src/lib/native-mode.ts`: the
  mode set includes `legacy-br`, `import-only`, `shadow-read`, `shadow-write`,
  `native-primary`, and `legacy-read-only`; native/shadow modes require absolute
  native/report paths.
- The current MCP native adapter still defaults to the old binary name:
  `process.env.SILMARI_MEMORY_RUST_BINARY || 'silmari_memory_rust'` at
  `apps/silmari-mcp/src/lib/br-adapter.ts:120`.
- Native-primary create/list/show/search/label-add/edge-add/edge-list paths
  exist through `apps/silmari-mcp/src/lib/br-adapter.ts:216`,
  `apps/silmari-mcp/src/lib/br-adapter.ts:258`,
  `apps/silmari-mcp/src/lib/br-adapter.ts:281`,
  `apps/silmari-mcp/src/lib/br-adapter.ts:301`,
  `apps/silmari-mcp/src/lib/br-adapter.ts:421`, and
  `apps/silmari-mcp/src/lib/br-adapter.ts:485`.
- Native-primary `brCreateBatch` currently throws
  `native-primary batch create is not implemented` at
  `apps/silmari-mcp/src/lib/br-adapter.ts:238`.
- Native-primary `brUpdate`, `brClose`, `brDelete`, and `brLabelRemove`
  currently return `false` at `apps/silmari-mcp/src/lib/br-adapter.ts:251`,
  `apps/silmari-mcp/src/lib/br-adapter.ts:310`,
  `apps/silmari-mcp/src/lib/br-adapter.ts:317`, and
  `apps/silmari-mcp/src/lib/br-adapter.ts:496`.
- `zk_status` still reports `br_available` and does not expose Silmari Store
  mode, native DB path, schema health, or binary identity at
  `apps/silmari-mcp/src/index.ts:757`.
- `zk_promote` depends on `brUpdate`, so it fails in native-primary today
  despite exact show/list working: `apps/silmari-mcp/src/index.ts:818`.
- The TypeScript native CLI adapter currently wraps init/health/schema,
  show/list/create, label-add, edge-add, reviewed edge commit, edge-list,
  line-of-thought, and checkpoint. It does not yet expose update/delete/close,
  label-remove, create-cards, search-biblio as first-class Rust commands:
  `apps/silmari-mcp/src/lib/native-adapter.ts:230`.
- The Rust CLI command enum includes health/init/import/snapshot,
  create-card/show-card/list-cards/label-add/edge-add/edge-commit/reconcile,
  export-viewer, recall/neighborhood/edges/line-of-thought, but does not yet
  implement the full adapter matrix from the spec:
  `apps/silmari_memory_rust/src/cli.rs:30`.
- Snapshot/import tests prove fixture-level report generation, including
  `import-summary.json`, `parity-report.json`, `warnings.jsonl`, and
  `rollback-manifest.json`: `apps/silmari_memory_rust/tests/import_snapshot_cli_contract.rs:35`.
- Viewer compatibility and card-native exports exist in Rust:
  `apps/silmari_memory_rust/src/export.rs:48` and
  `apps/silmari_memory_rust/src/export.rs:71`.
- The current viewer compatibility contract test verifies Rust-produced
  compatibility cache tables and all 12 edge types without server-side label
  synthesis: `apps/silmari-memory-card-viewer/tests/rust-compat-export-contract.test.ts:1`.
- Operational docs already record a real deployment footgun: setting
  `SILMARI_STORE` instead of `SILMARI_DIR` silently points the MCP server at the
  wrong store root: `scripts/post-deploy-checklist.md:64`.

## Desired End State

Silmari Store is fully online when:

- MCP native-primary mode uses Silmari Store by default for production storage.
- `silmari-store` / `silmari_store` naming is canonical while existing
  `silmari_memory_rust` callers remain compatible during transition.
- `zk_status` reports Silmari Store health instead of treating legacy `br`
  availability as the primary storage health indicator.
- All adapter functions in the spec matrix either have native-primary behavior
  or fail closed with explicit operator-facing diagnostics.
- `zk_promote`, close/delete, label-remove, and batch create are no longer silent
  native-primary dead ends.
- All AUTO and REVIEWED edge writes that the MCP server can perform land in
  native `card_edges`; labels are compatibility projections, not the only
  source of truth.
- Biblio save/search and cross-box `derives-from` work through native-primary.
- Real snapshot import parity, shadow-read, shadow-write, and rollback evidence
  are archived before production flip.
- Viewer compatibility export and card-native export can both load from the
  Silmari native store.
- A final removal gate proves Silmari runtime no longer shells out to legacy
  `br` in native-primary production paths.

### Observable Behaviors

1. Given a native-primary MCP config, when the server resolves the native
   binary, then it prefers `silmari-store`, falls back compatibly during rollout,
   and reports the resolved binary in status.
2. Given native-primary mode and no legacy Beads DB, when `zk_status` runs, then
   it returns Silmari Store health, schema, mode, native DB path, and card counts
   without requiring `br`.
3. Given a native-primary card, when `zk_promote` updates status, then the
   native row changes, an event is written, and the payload preserves current
   MCP shape.
4. Given native-primary mode, when close/delete/label-remove/update are called
   through the compatibility facade, then they mutate native state or return a
   specific unsupported-operation error instead of a silent `false`.
5. Given multiple native-primary cards, when batch create runs through the
   adapter matrix, then IDs are returned in input order and no partial commit is
   left after validation failure.
6. Given AUTO edge writes such as `follows`, `branches`, `derives-from`,
   `refers-to`, and `annotates`, when MCP creates them in native-primary, then
   native `card_edges` contains the edge and compatibility labels round-trip.
7. Given biblio and idea cards, when public biblio workflows run in
   native-primary, then save/search/derive/reverse-lookup behavior matches the
   legacy contract.
8. Given a real legacy snapshot, when import parity runs, then reports show
   counts, labels, edges, keywords, folgezettel, MCP payload, and viewer gates
   green or block cutover with categorized mismatches.
9. Given shadow-read and shadow-write modes, when representative operations run,
   then user-visible legacy outputs are preserved and parity/reconciliation
   JSONL records contain any differences.
10. Given native-primary mode and a detected regression, when the rollback
    runbook runs, then config switches to `legacy-read-only` or `legacy-br`
    without code revert and without deleting legacy snapshots.
11. Given a native DB, when viewer export runs, then the current viewer loads
    compatibility cache and the card-native cache preserves all semantic edges.
12. Given production flip completion, when static/runtime gates run, then no
    Silmari runtime path shells out to `br` unless explicitly in legacy/import
    mode.

## What We're Not Doing

- We are not changing the semantic edge vocabulary.
- We are not removing compatibility export until at least one release supports
  both compatibility and card-native export modes.
- We are not moving SAI hooks to direct Rust/database imports. SAI keeps using
  MCP-facing payloads.
- We are not treating Gate B classifier quality as a Silmari Store storage
  responsibility. Gate B must provide native durability evidence, but prompt
  quality remains owned by the pipeline workstream.
- We are not deleting legacy Beads DBs during the first native-primary rollout.

## Testing Strategy

- **Rust unit/integration**: `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml`
- **Rust focused contracts**:
  - `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml --test adapter_cli_contract`
  - `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml --test import_snapshot_cli_contract`
  - `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml --test viewer_export_contract`
- **MCP/Bun tests**:
  - `bun test apps/silmari-mcp/tests/native-mcp-dispatch-contract.test.ts`
  - `bun test apps/silmari-mcp/tests/native-cli-contract.test.ts`
  - `bun test apps/silmari-mcp/tests/native-mode-config-contract.test.ts`
  - `bun test apps/silmari-mcp/tests/native-shadow-contract.test.ts`
  - `bun run --cwd apps/silmari-mcp typecheck`
- **Viewer tests**:
  - `bun test apps/silmari-memory-card-viewer/tests/rust-compat-export-contract.test.ts`
  - `bun test apps/silmari-memory-card-viewer/viewer_assets/link-builder.test.js`
- **Operational evidence**:
  - Archive migration and shadow reports under a timestamped evidence directory.
  - Store exact MCP config used for native-primary and rollback smoke.

## Implementation Order

1. Naming and binary resolution, because every canary depends on launching the
   correct Silmari Store binary.
2. Status/health output, because operators need trustworthy visibility before
   flipping anything.
3. Native-primary write-surface completion for update/promote, close/delete,
   label-remove, and batch create.
4. AUTO edge and biblio workflow coverage.
5. Migration parity and shadow gates.
6. Viewer export/load and rollback runbook.
7. Phase 5 legacy runtime-removal gates.

## Global Contracts Pinned By Review Remediation

These contracts apply to every behavior below. They are not implementation
suggestions; they are the plan's acceptance boundary.

### Name, Cargo, And Binary Compatibility

- Canonical user-facing name: **Silmari Store**.
- Canonical CLI/binary: `silmari-store`.
- Canonical Rust package/lib crate after the naming slice:
  `package.name = "silmari_store"` and `[lib].name = "silmari_store"` in
  `apps/silmari_memory_rust/Cargo.toml`. The repository directory may remain
  `apps/silmari_memory_rust` for this transition.
- Compatibility binary for one release: keep a `[[bin]]` target named
  `silmari_memory_rust` that is a thin wrapper over the same CLI entrypoint and
  emits a deprecation warning on non-JSON invocations. JSON invocations must
  carry the warning in `diagnostics.deprecations[]`, not corrupt stdout.
- Canonical binary override env var: `SILMARI_STORE_BINARY`.
- Deprecated binary override env var: `SILMARI_MEMORY_RUST_BINARY`.
- Resolver precedence:
  1. explicit adapter option from tests or scripts,
  2. `SILMARI_STORE_BINARY`,
  3. `SILMARI_MEMORY_RUST_BINARY` with a deprecation diagnostic,
  4. `silmari-store` on `PATH`,
  5. `silmari_memory_rust` on `PATH` with a deprecation diagnostic.
- If both env vars are set to different paths, the resolver must fail with
  `CONFIG_INVALID` unless the caller passes a test-only `allowDeprecatedAlias`
  option. Production launch should not silently choose one.
- All MCP dispatch paths must call the resolver. Tests that construct
  `NativeCliAdapter` directly are insufficient unless `zk_status`,
  `zk_save_card`, and one mutation dispatch prove they use the same resolver.

### Native CLI JSON Envelope And Error Codes

Every `silmari-store ... --json` command added or modified by this plan returns
one JSON object and no human text on stdout:

```json
{
  "schemaVersion": "silmari-store.cli-result.v1",
  "ok": true,
  "command": "update-card",
  "result": {},
  "diagnostics": {
    "warnings": [],
    "deprecations": []
  }
}
```

Failures with `--json` write one JSON object to stderr and exit non-zero:

```json
{
  "schemaVersion": "silmari-store.cli-result.v1",
  "ok": false,
  "command": "update-card",
  "error": {
    "code": "CARD_NOT_FOUND",
    "message": "Card not found",
    "details": {},
    "retryable": false
  },
  "diagnostics": {
    "warnings": [],
    "deprecations": []
  }
}
```

Stable error codes for this plan:

- `BINARY_NOT_FOUND`
- `CONFIG_INVALID`
- `UNSUPPORTED_OPERATION`
- `SCHEMA_INCOMPATIBLE`
- `CARD_NOT_FOUND`
- `EDGE_NOT_FOUND`
- `VALIDATION_ERROR`
- `CONFLICT`
- `WRITE_PAUSED`
- `IMPORT_PARITY_FAILED`
- `SHADOW_MISMATCH`
- `CANARY_EVIDENCE_MISSING`
- `IO_ERROR`
- `INTERNAL_ERROR`

MCP maps these codes at the adapter boundary. Compatibility methods that
historically returned `false` may still return `false` only for legacy parity
when the caller explicitly expects a boolean. MCP tool dispatch must surface the
structured code and message in its thrown error or status payload.

### MCP Status Schema

`zk_status` native-primary output must include:

```json
{
  "statusSchemaVersion": "silmari-store.status.v1",
  "store": {
    "name": "Silmari Store",
    "description": "the native storage application for Silmari Memory",
    "mode": "native-primary",
    "nativeDbPath": "/absolute/path/to/silmari-native.sqlite3",
    "binary": {
      "path": "/absolute/path/to/silmari-store",
      "version": "x.y.z",
      "canonical": true,
      "deprecatedAliasUsed": false
    },
    "schema": {
      "version": 2,
      "compatible": true
    },
    "cards": {
      "idea": 0,
      "biblio": 0
    }
  },
  "legacy": {
    "brAvailable": false,
    "diagnosticOnly": true
  }
}
```

The old `br_available` field may remain for one compatibility release, but in
native-primary it is diagnostic only and must not determine overall status
success.

### Evidence Artifact Schema Versions

Every operator-facing artifact created by this plan must include
`schemaVersion`, `generatedAt`, `runId`, `source`, and `tool` fields. The
required schema names are:

- `silmari-store.import-summary.v1`
- `silmari-store.parity-report.v1`
- `silmari-store.warning.v1` for each `warnings.jsonl` line
- `silmari-store.rollback-manifest.v1`
- `silmari-store.shadow-record.v1`
- `silmari-store.canary-summary.v1`

Scripts must fail closed when a required artifact is missing, malformed, or has
an unsupported `schemaVersion`.

### Review Remediation Traceability

- Binary/Cargo naming is pinned in the global naming contract and Behavior 1.
- Native mutation CLI, lifecycle, tombstone, label-remove, and error contracts
  are pinned in Behavior 3.
- Batch no-partial behavior applies to both `brCreateBatch` and native-primary
  `zk_save_cards` in Behavior 4.
- AUTO edge source of truth is native `edge-add`; `ref:*` labels are projections
  in Behavior 5.
- Biblio public MCP/helper surfaces and duplicate recurrence are pinned in
  Behavior 6.
- Import parity command, artifact schemas, idempotency, and exit codes are
  pinned in Behavior 7.
- Shadow-read/shadow-write operation coverage, user-visible ownership, and
  JSONL schema are pinned in Behavior 8.
- Viewer `bv` replacement path, env vars, `/beads.sqlite3`, and `/api/health`
  contract are pinned in Behavior 9.
- Rollback env precedence, write-pause token, config object, and legacy snapshot
  proof are pinned in Behavior 10.
- Canary evidence schema/exit codes and Phase 5 no-legacy runtime allowlists are
  pinned in Behaviors 11 and 12.

## Behavior 1: Official Binary Resolution And Naming

### Test Specification

**Given**: MCP native-primary mode and an installed `silmari-store` binary.  
**When**: `NativeCliAdapter` is constructed without `SILMARI_MEMORY_RUST_BINARY`.  
**Then**: the adapter resolves `silmari-store`, reports that path/name in
status, and preserves a compatibility fallback for `silmari_memory_rust`.

Edge cases:

- `SILMARI_STORE_BINARY` is the canonical explicit override.
- `SILMARI_MEMORY_RUST_BINARY` remains a deprecated rollout override for one
  release and emits a deprecation diagnostic.
- Setting both binary env vars to different paths fails with `CONFIG_INVALID`
  in production launch.
- Missing `silmari-store` and missing fallback produce a structured status
  error, not silent legacy fallback.
- Rust `--help`, `--version`, and `health --json` identify the CLI as
  `silmari-store` / Silmari Store while the compatibility binary still works.
- MCP dispatch paths use the same resolver as direct `NativeCliAdapter` tests.

### TDD Cycle

#### Red: Write Failing Tests

Files:

- `apps/silmari-mcp/tests/native-binary-resolution-contract.test.ts`
- `apps/silmari_memory_rust/tests/cli_contract.rs`

Tests:

```ts
describe('Silmari Store binary resolution', () => {
  it('prefers silmari-store and records the resolved binary in native status', () => {
    // fixture PATH contains silmari-store and an old silmari_memory_rust shim
    // NativeCliAdapter without SILMARI_MEMORY_RUST_BINARY must run silmari-store
  });

  it('keeps SILMARI_MEMORY_RUST_BINARY as an explicit rollout override', () => {
    // env override points at old binary path and must be honored
    // status.diagnostics.deprecations includes the old env var name
  });

  it('fails when both binary env vars disagree', () => {
    // SILMARI_STORE_BINARY and SILMARI_MEMORY_RUST_BINARY point at different files
    // expect CONFIG_INVALID before any command executes
  });

  it('uses the resolver through MCP dispatch, not only direct adapter construction', async () => {
    // dispatch zk_status and zk_save_card in native-primary
    // expect the fake silmari-store command log to receive both invocations
  });
});
```

```rust
#[test]
fn cli_reports_silmari_store_identity() {
    // assert cargo-built binary exposes Silmari Store name/description
}
```

#### Green: Minimal Implementation

- Change `apps/silmari_memory_rust/Cargo.toml` so the package/lib crate is
  `silmari_store`, while keeping the repository directory path unchanged for
  this transition.
- Add canonical `[[bin]] name = "silmari-store"` and compatibility
  `[[bin]] name = "silmari_memory_rust"` targets over the same CLI entrypoint.
- Add `resolveNativeStoreBinary(env, options)` at the MCP native adapter
  boundary with the global resolver precedence and conflict behavior above.
- Replace every native CLI construction path in MCP with the resolver:
  direct adapter, `zk_status`, `zk_save_card`, `zk_save_cards`, mutations, and
  viewer/canary scripts.
- Keep `SILMARI_MEMORY_RUST_BINARY` as a compatibility override for one release
  only; all new docs and launch configs use `SILMARI_STORE_BINARY`.

#### Refactor

- Move name constants into one shared MCP module so status, docs, adapter, and
  tests do not duplicate strings.
- Update docs and comments from `silmari-memory-rust` / `silmari_memory_rust`
  to Silmari Store wording where behavior is not changed.

### Success Criteria

Automated:

- [x] Red test fails because current default is `silmari_memory_rust`.
- [x] `bun test apps/silmari-mcp/tests/native-binary-resolution-contract.test.ts`
      passes.
- [x] `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml --test cli_contract`
      passes.
- [x] MCP dispatch resolver test proves `zk_status` and `zk_save_card` call the
      canonical binary when both old and new shims are on `PATH`.
- [x] `rg -n "silmari_memory_rust|silmari-memory-rust" apps scripts docs artifacts specs`
      finds only intentional compatibility references.

Manual:

- [x] Local `silmari-store health --json --db <native-db>` works.
- [x] Existing old-binary test command still works during rollout.

Implementation evidence, 2026-04-30 by VioletBeacon:

- Added `silmari-store` as canonical binary and `silmari_store` as the Rust
  package/lib crate while keeping `silmari_memory_rust` as a compatibility
  binary for one rollout.
- Added MCP native binary resolver tests and Rust CLI identity/deprecation
  tests. The red state failed on missing resolver exports / missing
  `silmari-store` binary before implementation.
- Verified:
  `bun test apps/silmari-mcp/tests/native-binary-resolution-contract.test.ts apps/silmari-mcp/tests/native-cli-contract.test.ts apps/silmari-mcp/tests/native-mcp-dispatch-contract.test.ts`,
  `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml`,
  `bun run --cwd apps/silmari-mcp typecheck`, `git diff --check`, and manual
  `silmari-store health --json --db <native-db>` plus compatibility
  `silmari_memory_rust health --json --db <native-db>`.
- Remaining old-name grep hits are intentional compatibility binary coverage,
  the unchanged repository directory path `apps/silmari_memory_rust`, historical
  research/implementation artifacts, and GreenBridge's uncommitted 4d8.3 status
  test file, which has been called out over Agent Mail for canonical update.

## Behavior 2: Native Status And MCP Launch Contract

### Test Specification

**Given**: native-primary config with an absolute native DB path and no legacy
Beads DBs.  
**When**: `zk_status` runs through MCP dispatch.  
**Then**: the payload reports Silmari Store mode, native DB path, schema
compatibility, binary health, and card counts; legacy `br` availability is
diagnostic only. The payload uses `statusSchemaVersion:
"silmari-store.status.v1"`.

Edge cases:

- Wrong `SILMARI_STORE` env does not silently select the wrong root.
- Missing `SILMARI_DIR` in a production launch command is called out by a
  validation helper or status diagnostic.
- Invalid native config blocks writes and reports config diagnostics.
- `SILMARI_MEMORY_MODE` env override precedence is visible in status so an
  operator can tell whether config file mode or env mode won.
- `SILMARI_STORE_BINARY` and deprecated `SILMARI_MEMORY_RUST_BINARY` resolution
  diagnostics are included in `store.binary`.

### TDD Cycle

#### Red: Write Failing Tests

Files:

- `apps/silmari-mcp/tests/native-status-contract.test.ts`
- `apps/silmari-mcp/tests/native-mode-config-contract.test.ts`
- `scripts/tests/mcp-launch-env-contract.test.ts` if script tests already exist,
  otherwise keep the launch validation as a Bun test near MCP tests.

Tests:

```ts
describe('zk_status in native-primary', () => {
  it('reports Silmari Store health without requiring br', async () => {
    // native-primary harness with fake br that exits 97
    // expect store.name === 'Silmari Store'
    // expect store.mode === 'native-primary'
    // expect store.nativeDbPath === harness.nativeDbPath
    // expect store.schema.compatible === true
    // expect statusSchemaVersion === 'silmari-store.status.v1'
    // expect legacy.brAvailable is false but status succeeds
  });
});
```

#### Green: Minimal Implementation

- Add a native health/status helper in `br-adapter.ts` or a narrow
  `native-status.ts` module that reuses `resolveSilmariMemoryMode()`.
- Change `zk_status` to report:
  - `statusSchemaVersion`
  - `store.name`
  - `store.description`
  - `store.mode`
  - `store.nativeDbPath`
  - `store.binary`
  - `store.schema`
  - `legacy.brAvailable`
  - `legacy.diagnosticOnly`
  - config source/override diagnostics
  - card counts from the active facade.
- Keep `br_available` as a deprecated compatibility field only if existing
  clients depend on it.

#### Refactor

- Extract active-store counting so status does not duplicate list logic.
- Add deployment docs showing exact MCP launch env:
  `SILMARI_DIR`, `SILMARI_MEMORY_CONFIG`, and optional
  `SILMARI_MEMORY_MODE`.

### Success Criteria

Automated:

- [x] Red test fails because current `zk_status` only returns `br_available`.
- [x] `bun test apps/silmari-mcp/tests/native-status-contract.test.ts` passes.
- [x] Status tests assert `statusSchemaVersion`, `legacy.diagnosticOnly`, and
      binary/config diagnostics.
- [x] `bun run --cwd apps/silmari-mcp typecheck` passes.

Manual:

- [x] `silmari status` against a native-primary config shows Silmari Store
      health and no misleading `br` failure.

## Behavior 3: Native Update, Promote, Close, Delete, And Label Remove

### Test Specification

**Given**: a native-primary card.  
**When**: status/title/body update, `zk_promote`, close, delete, or label-remove
runs.  
**Then**: the native row mutates transactionally, `updated_at` changes,
`card_events` records the mutation, compatibility return values match the
legacy adapter, and unsupported operations fail with explicit diagnostics.

Edge cases:

- Promoting `blocked` to `open` still requires `force=true`.
- Deleting tombstones rather than physically deleting rows: `delete-card` sets
  `status = 'deleted'`, `deleted_at = now`, and `updated_at = now`.
- Default `show-card` and `list-cards` exclude tombstoned rows. `show-card
  --include-deleted` may return the tombstone for audit and rollback tools.
- Removing `ref:*` removes the matching `card_edges` row and its projected
  label in the same transaction.
- Removing generated labels for native fields is rejected unless paired with a
  native field update.
- This plan wires native `brUpdate` for the existing `zk_promote` path. It does
  not add a new public `zk_update` MCP tool; generic update support remains an
  adapter/CLI contract unless a separate tool-design bead is opened.

Native mutation request/response contract:

| Command | Required input | Mutation | Success `result` |
| --- | --- | --- | --- |
| `update-card --db <path> --id <id> --json-input <file-or-> --json` | JSON object with one or more of `status`, `title`, `body`, `priority`, `source`, `trunk`, `labels`, plus optional `force` | Updates allowed fields, validates lifecycle transitions, writes `card.updated` event | `{ "id", "changed", "card", "eventId" }` |
| `close-card --db <path> --id <id> --json` | Existing non-deleted card | Sets `status = 'closed'`, updates timestamps, writes `card.closed` event | `{ "id", "changed", "status": "closed", "eventId" }` |
| `delete-card --db <path> --id <id> --json` | Existing non-deleted card | Sets `status = 'deleted'`, `deleted_at`, updates timestamps, writes `card.deleted` event | `{ "id", "changed", "status": "deleted", "deletedAt", "eventId" }` |
| `label-remove --db <path> --id <id> --label <label> --json` | Existing non-deleted card and label | Removes user label; for `ref:<type>:<target>` removes the matching native edge and projection | `{ "id", "label", "changed", "removedEdgeId" }` |

Lifecycle and error rules:

- `blocked -> open` without `force` returns `VALIDATION_ERROR`.
- Updating or labeling a tombstoned card returns `CARD_NOT_FOUND` unless the
  command explicitly has `--include-deleted`.
- Closing an already closed card is idempotent: `changed=false`, no duplicate
  event.
- Deleting an already deleted card is idempotent: `changed=false`, no duplicate
  event.
- Removing `box:*`, `kind:*`, `status:*`, generated trunk/address labels, or
  generated keyword labels directly returns `UNSUPPORTED_OPERATION` with a
  detail explaining which native field update owns that label.
- MCP `zk_promote` propagates `VALIDATION_ERROR`/`CARD_NOT_FOUND` messages to
  the user instead of converting them to a silent `false`.

### TDD Cycle

#### Red: Write Failing Tests

Files:

- `apps/silmari_memory_rust/tests/native_mutations.rs`
- `apps/silmari_memory_rust/tests/adapter_cli_contract.rs`
- `apps/silmari-mcp/tests/native-mcp-dispatch-contract.test.ts`
- `apps/silmari-mcp/tests/native-adapter.test.ts`

Tests:

```rust
#[test]
fn update_card_changes_status_and_writes_event() {
    // create native card, call update-card, assert cards.status and card_events
}

#[test]
fn label_remove_ref_edge_removes_card_edge_and_projection() {
    // add ref:derives-from, remove it, assert card_edges gone
}
```

```ts
it('runs zk_promote through native-primary update-card', async () => {
  // save blocked card, promote with force, assert status and native command log
});
```

#### Green: Minimal Implementation

- Add Rust store functions:
  - `update_card`
  - `close_card`
  - `delete_card`
  - `remove_label`
- Add CLI commands:
  - `update-card`
  - `close-card`
  - `delete-card`
  - `label-remove`
- Add `NativeCliAdapter` methods and wire `brUpdate`, `brClose`, `brDelete`,
  and `brLabelRemove` in native-primary.
- Preserve legacy compatibility `true`/`false` behavior only at direct facade
  call sites that require it. MCP dispatch must preserve structured errors.

#### Refactor

- Share mutation/event helper code across create/update/delete/label functions.
- Keep Rust domain errors structured; keep TypeScript compatibility mapping at
  the adapter boundary only.

### Success Criteria

Automated:

- [x] Red tests fail because current native-primary methods return `false`.
- [x] `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml --test native_mutations --test adapter_cli_contract`
      passes.
- [x] `bun test apps/silmari-mcp/tests/native-mcp-dispatch-contract.test.ts apps/silmari-mcp/tests/native-adapter.test.ts`
      passes.
- [x] Tests cover tombstone default hide behavior, `--include-deleted`, and
      generated-label rejection.
- [x] `bun run --cwd apps/silmari-mcp typecheck` passes.

Manual:

- [x] `zk_promote` works against native-primary without a legacy Beads DB.

Implementation evidence, 2026-04-30 by VioletBeacon:

- Added Rust native mutation coverage in `native_mutations.rs`; the red state
  failed on unrecognized `update-card`, `close-card`, `delete-card`, and
  `label-remove` commands before implementation.
- Added native lifecycle fields (`status`, `priority`, `deleted_at`) and Rust
  store/CLI mutation commands for update, close, tombstone delete, and
  label-remove. Delete is tombstone-first; default card reads hide tombstones;
  `show-card --include-deleted` exposes the audit row.
- Added MCP native adapter and facade wiring for `brUpdate`, `brClose`,
  `brDelete`, and `brLabelRemove` in native-primary mode. `zk_promote` now
  routes through native `update-card` and the dispatch contract proves no
  legacy Beads DB or `br` call is used.
- Verified:
  `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml --test native_mutations --test adapter_cli_contract`,
  full `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml`,
  `bun test apps/silmari-mcp/tests/native-cli-contract.test.ts apps/silmari-mcp/tests/native-adapter.test.ts apps/silmari-mcp/tests/native-mcp-dispatch-contract.test.ts apps/silmari-mcp/tests/native-status-contract.test.ts apps/silmari-mcp/tests/native-mode-routing.test.ts`,
  `bun run --cwd apps/silmari-mcp typecheck`, and `git diff --check`.

## Behavior 4: Native Batch Create

### Test Specification

**Given**: an ordered batch of valid cards in native-primary mode.  
**When**: the compatibility adapter calls batch create or MCP `zk_save_cards`
runs in native-primary.
**Then**: Rust returns IDs in input order, the transaction leaves no partial
state on validation failure, and MCP batch payloads remain ordered.

Edge cases:

- Empty input returns `[]` without invoking Rust.
- Mixed labels and source/trunk metadata are preserved.
- One invalid card aborts the whole batch unless a resumable chunk mode is
  explicitly introduced.
- The no-partial contract applies to both `brCreateBatch` and native-primary
  `zk_save_cards`; legacy mode may keep its existing per-card behavior until
  separately changed.
- Biblio remains out of `zk_save_cards` scope; use `zk_save_card` or the
  biblio public workflow for biblio rows.

### TDD Cycle

#### Red: Write Failing Tests

Files:

- `apps/silmari_memory_rust/tests/native_create_batch.rs`
- `apps/silmari-mcp/tests/native-cli-contract.test.ts`
- `apps/silmari-mcp/tests/zk-save-cards-batch.test.ts`

Tests:

```rust
#[test]
fn create_cards_preserves_order_and_rolls_back_on_validation_error() {
    // call create-cards with three cards, then with one invalid card
}
```

```ts
it('brCreateBatch uses native create-cards in native-primary', () => {
  // native-primary harness, call brCreateBatch, assert create-cards log
});

it('zk_save_cards uses native create-cards and leaves no partial commit', async () => {
  // native-primary harness, one invalid card in the batch
  // expect no newly created native rows and a structured validation error
});
```

#### Green: Minimal Implementation

- Add Rust `create_cards` store function that opens one transaction and calls a
  private `create_card_in_tx` helper for each card. It must not loop the public
  single-card `create_card` API, because that would commit partial rows.
- Add CLI `create-cards`.
- Add `NativeCliAdapter.createBatchCompat`.
- Wire `brCreateBatch` in native-primary.
- Route native-primary `saveCardsBatch` / MCP `zk_save_cards` through
  `brCreateBatch` so the public MCP batch tool gets the same transaction and
  order guarantees as the adapter matrix.

#### Refactor

- Reuse single-card validation and label projection logic inside batch create.
- Keep order preservation as a public contract test.

### Success Criteria

Automated:

- [x] Red test fails on current native-primary `brCreateBatch` throw.
- [x] Rust and Bun focused batch tests pass.
- [x] Existing `zk_save_cards` tests remain green and include no-partial native
      rollback coverage.

Manual:

- [x] Native batch create smoke returns ordered IDs for a small local batch.

Implementation evidence, 2026-04-30 by VioletBeacon:

- Added `native_create_batch.rs` coverage for `create-cards` ordered IDs and
  all-or-nothing rollback. The red state failed on unrecognized
  `create-cards`; after implementation, malformed batch input leaves zero
  native `cards` and zero `card_events`.
- Refactored Rust create logic through private `create_card_in_tx`, added
  `create_cards`, `CreateCardsResult`, and the CLI `create-cards --json-input`
  command. The batch path returns `ids` plus per-card create results in input
  order.
- Added `NativeCliAdapter.createBatchCompat`, native-primary
  `brCreateBatchResult` / `brCreateBatch` wiring, and `saveCardsBatch` routing
  through one native `create-cards` call only in native-primary mode. Legacy
  mode keeps the existing per-card create behavior.
- Added native-primary `zk_save_cards` dispatch coverage proving one
  `create-cards` call, ordered payloads, no legacy Beads DB/`br` calls, and
  invalid batch no-partial behavior before writes.
- Verified:
  full `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml`,
  `bun test apps/silmari-mcp/tests/native-cli-contract.test.ts apps/silmari-mcp/tests/native-adapter.test.ts apps/silmari-mcp/tests/native-mcp-dispatch-contract.test.ts apps/silmari-mcp/tests/zk-save-cards-batch.test.ts apps/silmari-mcp/tests/native-status-contract.test.ts apps/silmari-mcp/tests/native-mode-routing.test.ts`,
  `bun run --cwd apps/silmari-mcp typecheck`, and `git diff --check`.

## Behavior 5: AUTO Edge Source Of Truth

### Test Specification

**Given**: native-primary mode and valid source/target cards.  
**When**: MCP creates AUTO edges (`follows`, `continues`, `branches`,
`derives-from`, `blocks`, `refers-to`, `annotates`).  
**Then**: native `card_edges` contains each edge, compatibility labels
round-trip, and `blocks` still appears through dependency-compatible reads.

Edge cases:

- Self-edge remains rejected.
- Missing endpoint returns false/structured error.
- Reviewed edge types still go through proposal/commit, not direct AUTO write.
- Existing compatibility label projection must not create duplicate edges.
- Native-primary `label-add ref:*` is not the authoritative writer for AUTO
  semantic edges. It may project compatibility labels, but direct MCP edge
  creation must write native `card_edges` through `edge-add`.
- `label-remove ref:<type>:<target>` removes the native edge, then removes the
  projection; if the edge does not exist it returns `EDGE_NOT_FOUND`.

### TDD Cycle

#### Red: Write Failing Tests

Files:

- `apps/silmari-mcp/tests/native-auto-edge-contract.test.ts`
- `apps/silmari_memory_rust/tests/adapter_cli_contract.rs`
- `apps/silmari_memory_rust/tests/viewer_export_contract.rs`

Tests:

```ts
for (const edge of ['follows', 'continues', 'branches', 'derives-from', 'refers-to', 'annotates']) {
  it(`writes ${edge} to native card_edges from MCP addEdge`, async () => {
    // native-primary harness, call addEdge/proposeOrAddEdge path
    // assert card_edges row and ref:* label in brShow compatibility payload
  });
}
```

#### Green: Minimal Implementation

- Route native-primary `addEdge` and `proposeOrAddEdge` AUTO acceptance through
  Rust `edge-add` for every AUTO edge type.
- Keep `ref:*` labels as Rust-owned projections of `card_edges`, not the live
  source of truth.
- Treat `label-add ref:*` in native-primary as compatibility input that delegates
  to `edge-add` and returns the same edge result; it must not insert a label-only
  reference.
- Keep `blocks` dependency-compatible behavior through `edge-list`.
- Keep reviewed-edge direct writes blocked unless authorized by `edge-commit`.

#### Refactor

- Update comments in `apps/silmari-mcp/src/lib/edges.ts` so they no longer
  describe labels as the live source of truth in native-primary.
- Move native/legacy edge branching behind the facade rather than spreading mode
  logic into callers.

### Success Criteria

Automated:

- [x] Red test identifies any AUTO edge still label-only in native-primary.
- [x] `bun test apps/silmari-mcp/tests/native-auto-edge-contract.test.ts` passes.
- [x] `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml --test adapter_cli_contract --test viewer_export_contract`
      passes.
- [x] Tests prove `label-remove ref:*` deletes the matching `card_edges` row.

Manual:

- [x] SQLite inspection shows all tested AUTO edges in `card_edges`.

Implementation evidence, 2026-04-30 by VioletBeacon:

- Added `native-auto-edge-contract.test.ts` with a native-primary harness that
  creates valid source/target cards, calls the MCP AUTO edge path for
  `follows`, `continues`, `branches`, `derives-from`, `blocks`, `refers-to`,
  and `annotates`, then opens the native SQLite DB and verifies each
  `card_edges` row.
- The red state failed because native-primary `addEdge` still treated AUTO
  edges as label-only compatibility writes. The green implementation routes
  direct AUTO edge creation through a facade-level `brEdgeAdd`, which calls
  Rust `edge-add` in native-primary mode and keeps legacy Beads label plus
  `blocks` dependency mirroring in legacy mode.
- Rust `insert_edge` now rejects self-edges and projects
  `ref:<type>:<target>` compatibility labels from native `card_edges`.
  Native-primary `brLabelAdd(ref:*)` delegates to `edge-add`, so ref labels
  cannot bypass the native source of truth.
- Updated the dispatch contract so `zk_block` proves the native `edge-add`
  write, shows the projected `ref:blocks:*` label through the card resource,
  and rejects stale `label-add ref:blocks:*` as the edge writer.
- Verified:
  `bun test apps/silmari-mcp/tests/native-auto-edge-contract.test.ts apps/silmari-mcp/tests/native-cli-contract.test.ts apps/silmari-mcp/tests/native-adapter.test.ts apps/silmari-mcp/tests/native-mcp-dispatch-contract.test.ts apps/silmari-mcp/tests/native-status-contract.test.ts apps/silmari-mcp/tests/native-mode-routing.test.ts`,
  full `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml`,
  `bun run --cwd apps/silmari-mcp typecheck`, and
  `git diff --check` on the 4d8.6 write set.

## Behavior 6: Native Biblio Workflow

### Test Specification

**Given**: native-primary mode and no legacy Beads DB.  
**When**: public biblio workflows run.  
**Then**: biblio save returns `bl-*`, biblio search finds the card, an idea can
derive from the biblio card, and reverse lookup finds the idea.

Edge cases:

- Biblio saves remain trunkless.
- Biblio duplicate/reinforces behavior is preserved: saving an identical
  citation/body creates a new `bl-*` card and writes a reviewed `reinforces`
  edge to the prior biblio card through native create recurrence. It does not
  allocate folgezettel address/trunk state.
- KindGuard/system-hook rules remain intact.
- Public surfaces in scope:
  - existing `zk_save_card` with `{ "box": "biblio", "kind": "biblio" }` for
    biblio creation,
  - new MCP `zk_biblio_search`,
  - new MCP `zk_biblio_link_source`,
  - new MCP `zk_biblio_sources_for_idea`,
  - new MCP `zk_biblio_ideas_for_source`,
  - existing TypeScript helper exports in `apps/silmari-mcp/src/lib/biblio.ts`.
- The new MCP tools are thin wrappers around the helper/facade layer, not a
  second persistence API.

### TDD Cycle

#### Red: Write Failing Tests

Files:

- `apps/silmari-mcp/tests/native-biblio-contract.test.ts`
- `apps/silmari-mcp/tests/native-mcp-dispatch-contract.test.ts`

Tests:

```ts
it('runs biblio save/search/derive/reverse lookup in native-primary', async () => {
  // set SILMARI_CALLER_TIER as needed for biblio
  // dispatch zk_save_card with box biblio
  // dispatch zk_biblio_search
  // save idea
  // dispatch zk_biblio_link_source and assert reverse lookup tools
});

it('preserves biblio duplicate recurrence in native create', async () => {
  // save identical biblio body twice
  // expect two bl-* ids and one reviewed reinforces native card_edges row
});
```

#### Green: Minimal Implementation

- Ensure `brSearch('biblio')` native-primary behavior is explicit and tested.
- Add the four MCP biblio tools named above and route them through
  `biblio.ts` helpers only.
- Adjust biblio helper calls so they go through the public facade only.
- Add dedicated Rust CLI `search-biblio --db <path> --query <query> --limit
  <n> --json`; native biblio search must not rely on JSON stringify filtering.
- Ensure native create recurrence applies to biblio duplicate bodies without
  folgezettel/trunk side effects.

#### Refactor

- Keep cross-box edge semantics in one biblio/edge helper.
- Remove any direct legacy path assumptions from biblio tests.

### Success Criteria

Automated:

- [x] Native biblio contract test fails in current code if any workflow reaches
      legacy Beads or cannot find results.
- [x] Focused Bun tests pass with legacy DB directories absent.
- [x] Native `card_edges` contains biblio duplicate `reinforces` and
      idea-to-biblio `derives-from` rows.

Manual:

- [x] Native-primary MCP smoke can save and retrieve a biblio card.

Implementation evidence, 2026-04-30 by VioletBeacon:

- Added `native-biblio-contract.test.ts` with a native-primary MCP dispatch
  harness and absent legacy Beads directories. The red state failed on
  `unknown tool: zk_biblio_search`; the Rust red state failed on unrecognized
  `search-biblio`.
- Added public MCP biblio wrappers:
  `zk_biblio_search`, `zk_biblio_link_source`,
  `zk_biblio_sources_for_idea`, and `zk_biblio_ideas_for_source`. Each routes
  through `apps/silmari-mcp/src/lib/biblio.ts` helpers and the existing
  facade rather than introducing a second persistence API.
- Added native `search-biblio --db <path> --query <query> --limit <n> --json`
  and `NativeCliAdapter.searchBiblioCompat`; native-primary
  `brSearch('biblio')` now uses that Rust command instead of TypeScript
  JSON-string filtering over `list-cards`.
- Removed legacy `br` availability/workspace assumptions from biblio helpers
  so native-primary biblio workflows do not create or call legacy Beads DBs.
- Permitted the intended cross-box native AUTO edge:
  idea-card `derives-from` biblio-card. The CLI still validates source box
  and target existence, while native `card_edges` stores the global
  `idea -> biblio` row and projects the compatibility
  `ref:derives-from:<bl-id>` label on the idea card.
- Verified:
  `bun test apps/silmari-mcp/tests/native-biblio-contract.test.ts`,
  `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml --test adapter_cli_contract biblio_search_and_cross_box_derives_from_are_native_contracts`,
  `bun test apps/silmari-mcp/tests/native-biblio-contract.test.ts apps/silmari-mcp/tests/native-auto-edge-contract.test.ts apps/silmari-mcp/tests/native-cli-contract.test.ts apps/silmari-mcp/tests/native-adapter.test.ts apps/silmari-mcp/tests/native-mcp-dispatch-contract.test.ts apps/silmari-mcp/tests/native-status-contract.test.ts apps/silmari-mcp/tests/native-mode-routing.test.ts`,
  full `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml`,
  `bun run --cwd apps/silmari-mcp typecheck`,
  `rustfmt --edition 2024 --check` on the 4d8.7 Rust files, and
  `git diff --check` on the 4d8.7 write set.

## Behavior 7: Real Import Parity Evidence Gate

### Test Specification

**Given**: a legacy snapshot and a target native DB path.  
**When**: import parity is run.  
**Then**: snapshot, import, parity, warning, and rollback reports are written;
the command exits non-zero on unexplained mismatches; report schema is stable
for operator review.

Edge cases:

- Source hashes bind reports to the exact snapshot.
- `--replace` requires a valid snapshot path.
- Invalid labels are preserved when safe and categorized in warnings.
- ID prefix violations block cutover rather than reallocating IDs.
- Re-running with the same `--run-id` is idempotent only when source hash,
  native DB path, and output directory match. Otherwise the command exits 1 and
  requires a new `--run-id` or explicit `--replace`.

Operator command contract:

```bash
bun run scripts/silmari-store/run-import-parity.ts \
  --snapshot /absolute/path/legacy-snapshot.sqlite3 \
  --native-db /absolute/path/silmari-native.sqlite3 \
  --evidence-dir /absolute/path/evidence/2026-04-30T000000Z-run-id \
  --run-id 2026-04-30T000000Z-run-id \
  --json
```

Required args are `--snapshot`, `--native-db`, `--evidence-dir`, and
`--run-id`; all paths must be absolute. The script runs `silmari-store
create-snapshot` only when the source is a live legacy store directory; when a
snapshot file is provided it records the file hash and skips snapshot creation.
It then runs `import-snapshot`, representative native queries, and viewer export
checks.

Exit codes:

- `0`: all gates green; reports written.
- `1`: invalid args/config, non-absolute paths, run-id mismatch, or unsafe
  overwrite attempt.
- `2`: explained parity mismatch; `parity-report.json` identifies blocking
  gates.
- `3`: import or viewer export IO failure.
- `4`: unsupported artifact schema version.
- `5`: unexpected internal error.

Required artifact contracts:

| File | `schemaVersion` | Required top-level fields |
| --- | --- | --- |
| `import-summary.json` | `silmari-store.import-summary.v1` | `generatedAt`, `runId`, `source`, `nativeDbPath`, `counts`, `sourceHash`, `importedCardIds`, `durationMs` |
| `parity-report.json` | `silmari-store.parity-report.v1` | `generatedAt`, `runId`, `sourceHash`, `nativeDbPath`, `gates`, `blockingMismatchCount`, `nonBlockingWarningCount`, `cutoverAllowed` |
| `warnings.jsonl` | `silmari-store.warning.v1` per line | `generatedAt`, `runId`, `category`, `severity`, `cardId`, `message`, `blocksCutover`, `details` |
| `rollback-manifest.json` | `silmari-store.rollback-manifest.v1` | `generatedAt`, `runId`, `legacySnapshotPath`, `legacySnapshotHash`, `nativeDbPath`, `nativeDbHash`, `modeBefore`, `recommendedRollbackMode`, `eventReplayRequired`, `legacyDeleted` |

### TDD Cycle

#### Red: Write Failing Tests

Files:

- `apps/silmari_memory_rust/tests/import_snapshot_cli_contract.rs`
- `scripts/silmari-store/import-parity-contract.test.ts` or equivalent Bun test
  if a script layer is introduced.

Tests:

```rust
#[test]
fn parity_report_contains_cutover_gate_categories() {
    // fixture import writes schema/counts/identity/folgezettel/body/labels/edges/keyword/mcp/viewer categories
}
```

#### Green: Minimal Implementation

- Extend `parity-report.json` to include the spec gate names:
  `schema`, `counts`, `identity`, `folgezettel`, `body`, `labels`, `edges`,
  `keyword`, `mcpPayload`, `viewer`.
- Add an operator command/script that runs:
  `create-snapshot`, `import-snapshot`, representative native queries, and
  viewer export checks.
- Archive reports under a timestamped evidence path.
- Add schema validators for the four required artifact types and wire them into
  both fixture tests and the operator script.

#### Refactor

- Separate fixture parity from real snapshot parity:
  fixture parity is automated CI; real snapshot parity is manual evidence with
  a saved report bundle.

### Success Criteria

Automated:

- [x] Import contract tests assert every required report and gate field.
- [x] Script contract tests assert args, idempotency, exit codes, and schema
      versions.
- [x] Rust import tests pass.

Evidence:

- `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml --test import_snapshot_cli_contract`
- `bun test scripts/silmari-store/import-parity-contract.test.ts`
- `cargo fmt --manifest-path apps/silmari_memory_rust/Cargo.toml --check`
- `git diff --check -- apps/silmari_memory_rust/src/importer.rs apps/silmari_memory_rust/tests/import_snapshot_cli_contract.rs scripts/silmari-store/run-import-parity.ts scripts/silmari-store/import-parity-contract.test.ts`

Manual:

- [x] One real legacy snapshot import parity run is archived.
- [x] Any mismatch is filed as a bead before Phase 4 production flip.

Production evidence:

- Archived at
  `artifacts/evidence/silmari-store/2026-05-01T013000Z-silmari-store-production-readiness/`.
- `parity-report.json` status is `pass`, `cutoverAllowed=true`, and
  `blockingMismatchCount=0`.
- The initial root-register import mismatch (`fz:0_0`, `trunk:root`) was filed
  as `silmari-agent-memory-4d8.14.1` before the parser fix landed.

## Behavior 8: Shadow-Read And Shadow-Write Evidence

### Test Specification

**Given**: imported native DB and legacy DB snapshots.  
**When**: shadow-read runs selected reads and shadow-write runs constrained
writes.  
**Then**: legacy-visible output remains unchanged, native parity records are
written, and mismatches include operation, inputs, legacy result, native result,
and rollback note.

Read coverage:

- `brShow`
- `brList`
- `findCardsByLabelCompat`
- content-hash duplicate lookup used by `saveCard`
- `fromAddress` lookup used by folgezettel continuation
- `brSearch` for biblio queries
- keyword recall through `zk_recall`
- `nativeLineOfThoughtCompat`

Write coverage:

- `brCreateResult` / `zk_save_card`
- `brCreateBatch` / `zk_save_cards`
- `brUpdate` / `zk_promote`
- `brLabelAdd`
- `brLabelRemove`
- `brDepAdd` / `addEdge`
- `brClose`
- `brDelete`

User-visible ownership:

- Shadow-read returns the legacy result to the caller. Native read output is
  diagnostic only and must not change MCP responses.
- Shadow-write returns the legacy write result to the caller until native-primary
  promotion. Native write output is diagnostic evidence unless a specific
  operator command promotes it.
- Any native shadow-write error is recorded as a mismatch and never retries or
  mutates legacy state beyond the original legacy operation.

`native-shadow.ts` JSONL record contract:

```json
{
  "schemaVersion": "silmari-store.shadow-record.v1",
  "runId": "2026-04-30T000000Z-run-id",
  "timestamp": "2026-04-30T00:00:00.000Z",
  "mode": "shadow-read",
  "operation": "brShow",
  "nativeDbPath": "/absolute/path/silmari-native.sqlite3",
  "legacySource": "/absolute/path/legacy",
  "binary": "/absolute/path/silmari-store",
  "inputHash": "sha256:...",
  "legacyResultHash": "sha256:...",
  "nativeResultHash": "sha256:...",
  "severity": "info",
  "blocksPromotion": false,
  "rollbackNote": "No rollback action required",
  "mismatchCategory": null,
  "details": {}
}
```

Allowed `mismatchCategory` values: `missing-card`, `extra-card`,
`field-difference`, `label-difference`, `edge-difference`, `id-allocation`,
`keyword-index`, `viewer-export`, `native-error`, `legacy-error`,
`unsupported-operation`.

### TDD Cycle

#### Red: Write Failing Tests

Files:

- `apps/silmari-mcp/tests/native-shadow-read-contract.test.ts`
- `apps/silmari-mcp/tests/native-shadow-write-contract.test.ts`
- `apps/silmari-mcp/tests/native-shadow-contract.test.ts`

Tests:

```ts
it('shadow-read records normalized parity for exact show and recall without changing output', () => {
  // legacy result is returned; native parity JSONL is written
});

it('shadow-write records native and legacy IDs for create mismatch', () => {
  // constrained fixture simulates mismatch; report carries both IDs
});
```

#### Green: Minimal Implementation

- Extend `native-shadow.ts` from local mismatch helper to operation-level
  runner helpers.
- Wire shadow-read/shadow-write in the facade for selected operations.
- Require `shadowReportDir` and `reconciliationReportDir` for shadow modes.
- Validate every JSONL line against `silmari-store.shadow-record.v1`.

#### Refactor

- Keep normalized comparison logic isolated and deterministic.
- Ensure shadow mode never changes the user-visible result unless explicitly
  promoted to native-primary.

### Success Criteria

Automated:

- [x] Existing `native-shadow-contract.test.ts` remains green.
- [x] New read/write shadow tests pass.

Manual:

- [x] One representative shadow-read report and one constrained shadow-write
      report are archived before native-primary production flip.

Production evidence:

- `shadow-read.jsonl` and `shadow-write.jsonl` are archived in
  `artifacts/evidence/silmari-store/2026-05-01T013000Z-silmari-store-production-readiness/`.

Implementation evidence (`silmari-agent-memory-4d8.9`, VioletBeacon):

- Red: `native-shadow-read-contract.test.ts` and
  `native-shadow-write-contract.test.ts` failed because shadow modes returned
  legacy results without writing the versioned Silmari Store shadow evidence
  required by this behavior.
- Green: `native-shadow.ts` now writes
  `silmari-store.shadow-record.v1` JSONL with run ID, mode, native DB path,
  legacy/native result hashes, mismatch category, promotion-blocking severity,
  and rollback notes. `brShow` in `shadow-read` and `brCreateResult` in
  `shadow-write` preserve legacy-visible results while recording native
  diagnostic output.
- Verification:
  `bun test apps/silmari-mcp/tests/native-shadow-read-contract.test.ts apps/silmari-mcp/tests/native-shadow-write-contract.test.ts apps/silmari-mcp/tests/native-shadow-contract.test.ts`
- Verification:
  `bun test apps/silmari-mcp/tests/native-shadow-read-contract.test.ts apps/silmari-mcp/tests/native-shadow-write-contract.test.ts apps/silmari-mcp/tests/native-shadow-contract.test.ts apps/silmari-mcp/tests/native-mode-config-contract.test.ts apps/silmari-mcp/tests/native-mode-routing.test.ts apps/silmari-mcp/tests/native-mcp-dispatch-contract.test.ts apps/silmari-mcp/tests/native-biblio-contract.test.ts apps/silmari-mcp/tests/native-auto-edge-contract.test.ts`
- Verification: `bun run --cwd apps/silmari-mcp typecheck`

## Behavior 9: Viewer Load From Silmari Native Store

### Test Specification

**Given**: a native DB with cards, labels, keywords, and all 12 edge types.  
**When**: viewer export runs in compatibility and card-native modes.  
**Then**: the current viewer can load compatibility cache, card-native tables
contain complete data, and `blocks` appears in both native edges and
dependency-compatible views.

Edge cases:

- Reviewed edge `review_state` survives export.
- Compatibility `dependencies` contains only `blocks`.
- Compatibility `card_edges` contains all 12 edge types.
- Unknown future export schema versions are rejected or warned.
- In Silmari Store mode, the viewer server does not shell out to `bv
  --export-pages`. It invokes `silmari-store export-viewer`.
- Compatibility mode still serves `/beads.sqlite3` and
  `/beads.sqlite3.config.json` so the current browser app can load without a
  flag-day rewrite.
- Card-native mode emits `viewer_cards` and `viewer_edges` and exposes a health
  response that names the export mode and source.

Viewer server integration contract:

- `SILMARI_VIEWER_SOURCE=legacy-bv|silmari-store` selects the exporter.
- `SILMARI_NATIVE_DB=/absolute/path/silmari-native.sqlite3` is required when
  `SILMARI_VIEWER_SOURCE=silmari-store`.
- `SILMARI_VIEWER_EXPORT_MODE=compat|native` selects `export-viewer --mode`.
- `SILMARI_STORE_BINARY` selects the exporter binary through the same resolver
  as MCP.
- `BV_BIN` is honored only when `SILMARI_VIEWER_SOURCE=legacy-bv`; Phase 5 gates
  disallow it in production native mode.
- `/api/health` returns `{ "viewerSource", "exportMode", "nativeDbPath",
  "exportSchemaVersion", "cacheHash" }`.
- `/beads.sqlite3` must be served in `compat` mode from a Silmari Store export,
  not from `bv`.

### TDD Cycle

#### Red: Write Failing Tests

Files:

- `apps/silmari-memory-card-viewer/tests/rust-compat-export-contract.test.ts`
- `apps/silmari_memory_rust/tests/viewer_export_contract.rs`
- `apps/silmari-memory-card-viewer/tests/native-export-load-contract.test.ts`

Tests:

```ts
it('loads card-native viewer tables produced by silmari-store export-viewer', () => {
  // export --mode native, then run viewer query/link-builder checks against viewer_edges
});

it('serves beads.sqlite3 from silmari-store compat export when configured', async () => {
  // server env SILMARI_VIEWER_SOURCE=silmari-store
  // expect /api/health names silmari-store and /beads.sqlite3 exists
});
```

#### Green: Minimal Implementation

- Keep Rust compatibility export current.
- Add viewer-side loader/test support for `viewer_cards` and `viewer_edges`
  as an explicit card-native path.
- Add server-side exporter selection. The legacy path may remain, but the
  Silmari Store path must be able to refresh the cache without `bv`.
- Keep compatibility export until card-native viewer is accepted.

#### Refactor

- Remove issue-tracker-only metrics from card-native viewer paths only after the
  compatibility retirement criteria are satisfied.

### Success Criteria

Automated:

- [x] Rust export tests pass.
- [x] Current viewer compatibility test passes.
- [x] Card-native viewer load test passes.
- [x] Server tests prove `/beads.sqlite3` and `/api/health` work from
      `SILMARI_VIEWER_SOURCE=silmari-store`.

Evidence:

- `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml --test viewer_export_contract`
- `bun test apps/silmari-memory-card-viewer/tests/rust-compat-export-contract.test.ts`
- `bun test apps/silmari-memory-card-viewer/tests/native-export-load-contract.test.ts`
- `bun test apps/silmari-memory-card-viewer/tests/server.test.ts`
- `bun run --cwd apps/silmari-memory-card-viewer typecheck`
- `git diff --check -- apps/silmari-memory-card-viewer/server.ts apps/silmari-memory-card-viewer/tests/server.test.ts apps/silmari-memory-card-viewer/tests/rust-compat-export-contract.test.ts apps/silmari-memory-card-viewer/tests/native-export-load-contract.test.ts apps/silmari_memory_rust/src/export.rs apps/silmari_memory_rust/tests/viewer_export_contract.rs`

Manual:

- [x] Local viewer loads native export and shows typed semantic edges.

Production evidence:

- `viewer-export.json`, `viewer-health.json`, and the native viewer cache are
  archived in
  `artifacts/evidence/silmari-store/2026-05-01T013000Z-silmari-store-production-readiness/`.

## Behavior 10: Rollback Runbook

### Test Specification

**Given**: a native-primary config, legacy snapshots, native events, and a
detected regression.  
**When**: rollback is executed.  
**Then**: writes are paused, config switches to `legacy-read-only` or
`legacy-br`, legacy DB snapshots are not deleted, and the runbook records
whether native events need replay/audit.

Edge cases:

- Rollback works without git revert.
- Invalid rollback target config fails before writes resume.
- Rollback manifest path is recorded.
- Env overrides cannot silently defeat rollback. If `SILMARI_MEMORY_MODE`
  conflicts with the target rollback mode, the rollback helper exits 1 unless
  `--allow-env-override` is explicitly passed and recorded.
- A write-pause token blocks MCP writes before config changes and remains until
  the operator resumes writes.
- Rollback evidence proves legacy snapshot files still exist and were not
  deleted.

Rollback command/config contract:

```bash
bun run scripts/silmari-store/rollback.ts \
  --config /absolute/path/silmari-memory-mode.json \
  --target-mode legacy-read-only \
  --legacy-snapshot /absolute/path/legacy-snapshot.sqlite3 \
  --native-db /absolute/path/silmari-native.sqlite3 \
  --rollback-manifest /absolute/path/evidence/rollback-manifest.json \
  --write-pause-token /absolute/path/runtime/write-pause.json \
  --run-id 2026-04-30T000000Z-run-id \
  --dry-run
```

The helper updates `NativeModeConfig v1` by adding a `rollback` object:

```json
{
  "mode": "legacy-read-only",
  "nativeDbPath": "/absolute/path/silmari-native.sqlite3",
  "rollback": {
    "schemaVersion": "silmari-store.rollback-config.v1",
    "runId": "2026-04-30T000000Z-run-id",
    "selectedLegacySnapshot": "/absolute/path/legacy-snapshot.sqlite3",
    "rollbackManifestPath": "/absolute/path/evidence/rollback-manifest.json",
    "writePauseTokenPath": "/absolute/path/runtime/write-pause.json",
    "replayPolicy": "audit-only",
    "operator": "local-cli",
    "createdAt": "2026-04-30T00:00:00.000Z"
  }
}
```

Write pause token contract:

```json
{
  "schemaVersion": "silmari-store.write-pause.v1",
  "runId": "2026-04-30T000000Z-run-id",
  "mode": "rollback",
  "createdAt": "2026-04-30T00:00:00.000Z",
  "reason": "rollback",
  "resumeRequires": "operator-clear"
}
```

MCP status checks this token in native/shadow modes. Write tools return
`WRITE_PAUSED` while it exists; read tools keep serving from the configured
rollback mode.

### TDD Cycle

#### Red: Write Failing Tests

Files:

- `apps/silmari-mcp/tests/native-rollback-contract.test.ts`
- `scripts/silmari-store/rollback-runbook.test.ts`
- `artifacts/specs/2026-04-28-beads-rust-replacement/04-migration-cutover-and-verification.md`
  only if docs need runbook detail.

Tests:

```ts
it('switches runtime mode through config without deleting legacy snapshots', () => {
  // fixture config native-primary -> legacy-read-only
  // assert resolveSilmariMemoryMode changes and snapshot paths remain
});
```

#### Green: Minimal Implementation

- Add a rollback helper script or documented operator command sequence.
- Validate config path, mode, native DB, snapshot path, and report path before
  switching.
- Add status diagnostics that show rollback mode clearly.
- Add MCP write-pause enforcement for `zk_save_card`, `zk_save_cards`,
  `zk_promote`, edge writes, close/delete, and label mutations.

#### Refactor

- Keep rollback logic config-only; do not require code changes or branch
  checkout.

### Success Criteria

Automated:

- [x] Rollback contract test passes.
- [x] Native mode config tests remain green.
- [x] Tests prove conflicting `SILMARI_MEMORY_MODE` blocks rollback unless
      explicitly allowed and recorded.
- [x] Tests prove write tools return `WRITE_PAUSED` while the pause token
      exists.

Manual:

- [x] A dry-run rollback against a temp store records expected operator output.

Implementation evidence (`silmari-agent-memory-4d8.11`, VioletBeacon):

- Red: `rollback-runbook.test.ts` failed because the rollback helper did not
  exist, and `native-rollback-contract.test.ts` failed because status did not
  expose rollback/pause metadata and paused facade writes returned generic
  failures instead of `WRITE_PAUSED`.
- Green: `scripts/silmari-store/rollback.ts` validates absolute rollback
  inputs, refuses conflicting `SILMARI_MEMORY_MODE` unless
  `--allow-env-override` is explicit, writes
  `silmari-store.rollback-config.v1` metadata, writes
  `silmari-store.write-pause.v1`, and preserves legacy snapshots. MCP native
  mode resolution now carries rollback config, `zk_status` reports rollback
  and write-pause state, and shared facade writes throw `WRITE_PAUSED` while
  the token exists.
- Verification:
  `bun test apps/silmari-mcp/tests/native-rollback-contract.test.ts apps/silmari-mcp/tests/native-mode-config-contract.test.ts apps/silmari-mcp/tests/native-status-contract.test.ts apps/silmari-mcp/tests/native-mcp-dispatch-contract.test.ts apps/silmari-mcp/tests/native-mode-routing.test.ts apps/silmari-mcp/tests/native-shadow-read-contract.test.ts apps/silmari-mcp/tests/native-shadow-write-contract.test.ts apps/silmari-mcp/tests/native-shadow-contract.test.ts apps/silmari-mcp/tests/native-biblio-contract.test.ts apps/silmari-mcp/tests/native-auto-edge-contract.test.ts`
  passed with 28 tests.
- Verification:
  `bun test scripts/silmari-store/rollback-runbook.test.ts scripts/silmari-store/canary-checklist.test.ts scripts/silmari-store/import-parity-contract.test.ts`
  passed with 14 tests.
- Verification: `bun run --cwd apps/silmari-mcp typecheck`
- Manual dry-run: `bun scripts/silmari-store/rollback.ts ... --dry-run --json`
  against a temporary store returned
  `silmari-store.rollback-result.v1` with `legacySnapshotStillExists: true`.

## Behavior 11: Production Canary Checklist And Evidence Bundle

### Test Specification

**Given**: all automated tests are green.  
**When**: the production canary checklist runs.  
**Then**: it produces one evidence bundle containing the MCP config, binary
version, status output, import parity reports, shadow reports, viewer export
results, rollback dry-run result, and smoke-test transcript.

Required smoke:

- `zk_status`
- `zk_save_card`
- `zk_save_cards`
- `zk_recall`
- `zk_line_of_thought`
- `zk_block`
- `zk_promote`
- biblio add/search
- viewer load

Canary command contract:

```bash
bun run scripts/silmari-store/canary-checklist.ts \
  --config /absolute/path/silmari-memory-mode.json \
  --native-db /absolute/path/silmari-native.sqlite3 \
  --evidence-dir /absolute/path/evidence/canary-run-id \
  --run-id canary-run-id \
  --json
```

Required evidence files:

- `mcp-config.json`
- `binary-resolution.json`
- `zk-status.json`
- `import-summary.json`
- `parity-report.json`
- `warnings.jsonl`
- `rollback-manifest.json`
- `shadow-read.jsonl`
- `shadow-write.jsonl`
- `viewer-export.json`
- `viewer-health.json`
- `rollback-dry-run.json`
- `smoke-transcript.jsonl`
- `canary-summary.json`

`canary-summary.json` uses `schemaVersion:
"silmari-store.canary-summary.v1"` and contains `runId`, `generatedAt`,
`gitSha`, `nativeDbPath`, `binary`, `config`, `artifacts`, `smoke`, `gates`,
and `productionFlipAllowed`.

Exit codes:

- `0`: all required artifacts present, schemas valid, smoke green.
- `1`: invalid args/config.
- `2`: missing or malformed evidence artifact.
- `3`: smoke failure.
- `4`: rollback dry-run failure.
- `5`: unexpected internal error.

### TDD Cycle

#### Red: Write Failing Tests

Files:

- `scripts/silmari-store/canary-checklist.test.ts`
- `scripts/silmari-store/canary-checklist.ts`

Tests:

```ts
it('fails checklist when any required evidence artifact is missing', () => {
  // create partial evidence dir and assert missing artifact names
});
```

#### Green: Minimal Implementation

- Add a checklist script that validates artifact presence and JSON shape.
- Require absolute paths and explicit `SILMARI_DIR`.
- Emit a machine-readable `canary-summary.json`.
- Validate every artifact schema before setting `productionFlipAllowed=true`.

#### Refactor

- Split "collect evidence" from "validate evidence" so real production data is
  not required in CI.

### Success Criteria

Automated:

- [x] Checklist shape tests pass.
- [x] Evidence validation fails closed when required reports are absent.
- [x] Exit-code tests cover missing artifacts, smoke failure, and rollback
      dry-run failure.

Evidence:

- `bun test scripts/silmari-store/canary-checklist.test.ts`
- `git diff --check -- scripts/silmari-store/canary-checklist.ts scripts/silmari-store/canary-checklist.test.ts thoughts/searchable/shared/plans/2026-04-30-silmari-agent-memory-4d8-tdd-silmari-store-full-online.md`

Manual:

- [x] One production-like canary bundle is archived and linked from the bead.

Production evidence:

- Canary bundle archived at
  `artifacts/evidence/silmari-store/2026-05-01T013000Z-silmari-store-production-readiness/`.
- `canary-summary.json` reports `productionFlipAllowed=true` with import parity,
  shadow read/write, viewer, rollback, and smoke gates passing.

## Behavior 12: Phase 5 Legacy Runtime Removal Gate

### Test Specification

**Given**: native-primary is accepted.  
**When**: legacy removal gates run.  
**Then**: production Silmari runtime paths no longer shell out to `br`; legacy
Beads code remains only behind explicit legacy/import modes and archival import
commands.

Edge cases:

- Tests may still use legacy fixtures where intentionally marked.
- `vendor/beads_rust` may remain for unrelated beads tooling until Silmari
  runtime no longer requires it.
- Compatibility docs must distinguish `bd` project issue tracking from the old
  Silmari memory storage layer.
- `bv` is not allowed in production native-primary viewer/export paths after
  Phase 5. It is allowed only in Phase 4 compatibility mode when
  `SILMARI_VIEWER_SOURCE=legacy-bv` is explicitly configured.
- Docs, deployment scripts, service files, and README references must stop
  presenting `br`, `bv`, `BV_BIN`, `BEADS_DIR`, or `beads_rust` as production
  Silmari Memory storage requirements.

Static/runtime allowlist policy:

- Allowed after Phase 5:
  - tests and fixtures explicitly named `legacy`, `compat`, or `import`;
  - importer/snapshot code that reads old Beads data;
  - compatibility docs explaining the migration history;
  - `bd` issue-tracker commands in `AGENTS.md` and development workflow docs.
- Disallowed after Phase 5:
  - MCP native-primary runtime subprocess calls to `br`;
  - viewer server native mode subprocess calls to `bv`;
  - production deploy scripts that install or require `br`/`bv` for Silmari
    Memory runtime;
  - status output that reports legacy `br` as the primary store health.

### TDD Cycle

#### Red: Write Failing Tests

Files:

- `apps/silmari-mcp/tests/no-br-runtime-contract.test.ts`
- `scripts/silmari-store/no-legacy-runtime-gate.test.ts`

Tests:

```ts
it('finds no production br subprocess calls outside legacy adapter/import modes', () => {
  // static grep over apps/silmari-mcp/src with allowlist
});
```

#### Green: Minimal Implementation

- Add a static allowlist for legacy-only files.
- Move or rename any lingering generic `br` status/runtime wording that could
  confuse production operators.
- Keep archival import command and compatibility aliases.
- Add a runtime guard that logs or fails if production native-primary tries to
  execute `br` or `bv` outside an allowlisted legacy/import mode.

#### Refactor

- Collapse compatibility aliases only after the release that supports both
  binary names and export modes.

### Success Criteria

Automated:

- [x] Static no-legacy-runtime gate passes.
- [x] Full MCP, Rust, and viewer focused suites pass.
- [x] Gate scans `apps`, `scripts`, `docs`, service/deploy files, and viewer
      server code with role-based allowlists.

Evidence:

- `bun test scripts/silmari-store/no-legacy-runtime-gate.test.ts`
- `bun scripts/silmari-store/no-legacy-runtime-gate.ts --root /home/maceo/Dev/silmari-agent-memory --json`
  scanned 903 files, found zero production runtime violations, and reported
  27 operator/docs cleanup warnings.
- `git diff --check -- scripts/silmari-store/no-legacy-runtime-gate.ts scripts/silmari-store/no-legacy-runtime-gate.test.ts thoughts/searchable/shared/plans/2026-04-30-silmari-agent-memory-4d8-tdd-silmari-store-full-online.md`

Manual:

- [x] Operator docs point to Silmari Store, `silmari-store`, and native config.

Production evidence:

- `bun scripts/silmari-store/no-legacy-runtime-gate.ts --root /home/maceo/Dev/silmari-agent-memory --json`
  scanned 908 files, found zero production runtime violations, and reported
  zero operator/docs cleanup warnings.

## Child Bead Proposal

`silmari-agent-memory-4d8.1` is the review-remediation blocker for this plan,
not an implementation slice. After `4d8.1` closes, create implementation
children under `silmari-agent-memory-4d8` in this order:

1. `4d8.2` - Silmari Store binary/name compatibility and MCP binary resolution.
2. `4d8.3` - Native `zk_status` and launch config diagnostics.
3. `4d8.4` - Native update/promote/close/delete/label-remove write surface.
4. `4d8.5` - Native batch create adapter matrix and `zk_save_cards`
   transaction semantics.
5. `4d8.6` - Native AUTO edge source-of-truth coverage.
6. `4d8.7` - Native biblio public workflow smoke.
7. `4d8.8` - Real import parity evidence command/report gate.
8. `4d8.9` - Shadow-read and constrained shadow-write evidence.
9. `4d8.10` - Viewer native/compat export load gate.
10. `4d8.11` - Rollback runbook and config-switch test.
11. `4d8.12` - Production canary checklist/evidence bundle.
12. `4d8.13` - Phase 5 no-legacy-runtime removal gate.

Each child should reserve only its owned files before implementation. Avoid
editing `br-adapter.ts`, `native-adapter.ts`, `index.ts`, Rust CLI/store files,
or viewer export code without a bead claim and Agent Mail notice.

## Integration And E2E Testing

Focused integration command set for the completed plan:

```bash
cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml
bun test apps/silmari-mcp/tests/native-adapter.test.ts apps/silmari-mcp/tests/native-cli-contract.test.ts apps/silmari-mcp/tests/native-mcp-dispatch-contract.test.ts apps/silmari-mcp/tests/native-mode-config-contract.test.ts apps/silmari-mcp/tests/native-shadow-contract.test.ts
bun test apps/silmari-memory-card-viewer/tests/rust-compat-export-contract.test.ts
bun run --cwd apps/silmari-mcp typecheck
```

Final manual canary:

1. Build/install `silmari-store`.
2. Set explicit `SILMARI_DIR` and `SILMARI_MEMORY_CONFIG`.
3. Run `zk_status` and verify Silmari Store health.
4. Run import parity and archive reports.
5. Run shadow-read and constrained shadow-write and archive reports.
6. Flip to native-primary.
7. Smoke MCP save/recall/line-of-thought/block/promote/biblio/viewer.
8. Dry-run rollback by config switch.
9. Record evidence bundle path in `silmari-agent-memory-4d8`.

## References

- Parent bead: `silmari-agent-memory-4d8`
- Naming bead: `silmari-agent-memory-e8u`
- Spec index: `artifacts/specs/2026-04-28-beads-rust-replacement/README.md`
- Architecture spec: `artifacts/specs/2026-04-28-beads-rust-replacement/01-system-architecture.md`
- Data model spec: `artifacts/specs/2026-04-28-beads-rust-replacement/02-native-data-model.md`
- Store API spec: `artifacts/specs/2026-04-28-beads-rust-replacement/03-store-api-and-adapter.md`
- Migration spec: `artifacts/specs/2026-04-28-beads-rust-replacement/04-migration-cutover-and-verification.md`
- Viewer/consumer spec: `artifacts/specs/2026-04-28-beads-rust-replacement/05-viewer-export-and-consumers.md`
- Current native mode: `apps/silmari-mcp/src/lib/native-mode.ts`
- Current facade: `apps/silmari-mcp/src/lib/br-adapter.ts`
- Current native adapter: `apps/silmari-mcp/src/lib/native-adapter.ts`
- Current Rust CLI: `apps/silmari_memory_rust/src/cli.rs`
- Current viewer export: `apps/silmari_memory_rust/src/export.rs`
