# Plan Review Report: Silmari Store Full Online

Plan reviewed:
`thoughts/searchable/shared/plans/2026-04-30-silmari-agent-memory-4d8-tdd-silmari-store-full-online.md`

Parent bead: `silmari-agent-memory-4d8`

Reviewer: GreenBridge

Date: 2026-04-30

## Review Summary

| Category | Status | Issues Found |
| --- | --- | --- |
| Contracts | FAIL | 5 critical, 2 warnings |
| Interfaces | FAIL | 4 critical, 3 warnings |
| Promises | FAIL | 3 critical, 2 warnings |
| Data Models | FAIL | 4 critical, 2 warnings |
| APIs | FAIL | 3 critical, 2 warnings |

Overall status: NEEDS MAJOR REVISION.

The plan is directionally correct and the 12 behavior slices match the MCP/native
canary problem. It is not yet safe to implement as written because several slices
leave the actual cross-layer contract undecided: Cargo/binary compatibility,
native mutation command envelopes, AUTO edge source of truth, shadow operation
wiring, import evidence schemas, viewer runtime integration, and rollback
execution.

## Well-Defined Areas

- The plan correctly identifies the live gaps: old native binary default,
  legacy-shaped `zk_status`, native-primary mutation methods returning false,
  `brCreateBatch` throwing, AUTO edge label-only risk, biblio workflow risk,
  missing real import/shadow/rollback evidence, viewer export/load risk, and
  Phase 5 legacy runtime cleanup.
- The behavior ordering is mostly right: do binary/status/mutation/AUTO-edge
  contracts before claiming canary evidence.
- The plan includes focused test files and separates fixture parity from real
  operator evidence.
- The plan preserves compatibility aliases during rollout rather than demanding
  an immediate hard cutover.

## Critical Issues

### 1. Binary and Cargo rename strategy is under-specified

Behavior 1 says to rename the Rust crate/package target to `silmari_store`, add
`silmari-store`, and preserve compatibility with `silmari_memory_rust`
(`plan:261-267`). Current code still names the Cargo package
`silmari_memory_rust` (`apps/silmari_memory_rust/Cargo.toml:2`), the Clap
command is `silmari_memory_rust` (`apps/silmari_memory_rust/src/cli.rs:23`), and
MCP still constructs the native adapter with
`process.env.SILMARI_MEMORY_RUST_BINARY || 'silmari_memory_rust'`
(`apps/silmari-mcp/src/lib/br-adapter.ts:120-124`).

Impact: a naive package rename will break Rust crate imports, `cargo_bin`
contract tests, TS native CLI tests, and canary binary resolution. Different
agents could choose incompatible aliasing strategies.

Required amendment: define the exact Cargo strategy before implementation. The
plan should state whether the package stays `silmari_memory_rust` for one
release while adding `[[bin]] name = "silmari-store"`, whether a second
old-name wrapper remains, which tests prove old and new names, and whether
`SILMARI_STORE_BINARY` becomes canonical with `SILMARI_MEMORY_RUST_BINARY` as a
deprecated alias. Also require the facade/MCP dispatch path to use the resolver,
not only direct `NativeCliAdapter` tests.

### 2. Native mutation commands lack concrete request, response, lifecycle, and error contracts

Behavior 3 identifies the right missing surfaces, but only lists function names:
`update_card`, `close_card`, `delete_card`, `remove_label`, and CLI commands
(`plan:425-436`). Current native-primary facade methods return false for
`brUpdate`, `brClose`, `brDelete`, and `brLabelRemove`
(`apps/silmari-mcp/src/lib/br-adapter.ts:251-255`,
`apps/silmari-mcp/src/lib/br-adapter.ts:310-321`,
`apps/silmari-mcp/src/lib/br-adapter.ts:496-501`). `zk_promote` then reports a
generic `BR_WRITE_FATAL status update failed` (`apps/silmari-mcp/src/index.ts:986-988`).

Impact: Rust, adapter, and MCP implementations can diverge on optional fields,
generated label rules, tombstone visibility, status transitions, event names,
and unsupported-operation diagnostics.

Required amendment: define exact CLI flags or JSON input for each command, exact
success envelopes, exact error codes, and exact MCP error propagation. Specify
whether `close-card` sets `status='closed'`, whether `delete-card` sets
`deleted_at` and/or `status='deleted'`, whether `show-card` reveals tombstones,
which labels are generated field projections, and whether `zk_update` is in
scope or only `zk_promote`.

### 3. Batch create semantics are ambiguous between adapter batch and MCP `zk_save_cards`

Behavior 4 requires native batch transaction semantics for `brCreateBatch`, but
also says `saveCardsBatch` stays per-card unless intentionally moved
(`plan:503-509`). Current `brCreateBatch` throws in native-primary
(`apps/silmari-mcp/src/lib/br-adapter.ts:238-245`), while the MCP
`zk_save_cards` path uses per-card `brCreateResult` through `saveCardsBatch`.

Impact: implementers can make `brCreateBatch` transactional while production
`zk_save_cards` remains non-transactional, yet the plan's canary smoke includes
`zk_save_cards`. That would overclaim no-partial-commit coverage.

Required amendment: explicitly state whether no-partial-commit applies only to
adapter-level `brCreateBatch` or also to MCP `zk_save_cards`. If it applies to
MCP, require `saveCardsBatch` to route to native batch in native-primary. Also
state the Rust internal transaction split, because current single-card create
owns its own transaction and cannot be looped for all-or-nothing behavior.

### 4. AUTO edge source-of-truth is left as an implementation choice

Behavior 5 says to choose either Rust `label-add ref:*` projection or route
native-primary `addEdge` directly through `edge-add` (`plan:568-572`). Current
`addEdge` writes `ref:*` labels first and only mirrors `blocks` through
`brDepAdd` (`apps/silmari-mcp/src/lib/edges.ts:96-104`); the comment still says
the `blocks` label is source of truth (`apps/silmari-mcp/src/lib/edges.ts:70-73`).

Impact: the central architecture decision is deferred into implementation. One
agent could make Rust label projection authoritative while another rewires
TypeScript `addEdge`, producing duplicate or missing `card_edges` rows.

Required amendment: choose the source-of-truth path in the plan. The recommended
revision is: native-primary `addEdge`/`proposeOrAddEdge` writes AUTO edges
through native `edge-add`; Rust projects compatibility `ref:*` labels; label
removal of `ref:*` removes the matching native edge through one invariant-tested
path. If a different path is chosen, name it and test it through the public MCP
facade for every AUTO type.

### 5. Biblio public workflow surface is not defined

Behavior 6 says "public biblio workflows" but does not define whether that means
library helpers or MCP tools (`plan:600-603`). The green step says "if
`search-biblio` needs a dedicated Rust command" (`plan:635-638`), leaving the
interface optional. It also leaves duplicate/reinforces behavior open
(`plan:607-609`).

Impact: tests could pass against library helpers while no MCP tool exists for
biblio search/derive/reverse lookup, or the system could keep JSON-string
filtering in TS with no stable Rust search contract.

Required amendment: define the public biblio API. If MCP tools are in scope,
list their names, inputs, outputs, and errors. If only helpers are in scope,
state that explicitly and test the helpers with legacy DB directories absent.
Decide whether biblio duplicate body-hash recurrence is preserved, disabled, or
different from idea recurrence.

### 6. Import parity evidence lacks versioned schemas, command contract, and exit codes

Behavior 7 requires stable reports and a non-zero exit on unexplained mismatches
(`plan:661-665`) and lists gate names (`plan:695-701`). Current Rust importer
still writes a scaffolded parity report containing only `runId`, `status`, and
empty `mismatches` (`apps/silmari_memory_rust/src/importer.rs:650-656`) plus a
minimal rollback manifest (`apps/silmari_memory_rust/src/importer.rs:679-687`).

Impact: the production flip gate is not mechanically testable. Operators and
tests will not know which artifacts are required, which fields prove a pass, or
which mismatches block cutover.

Required amendment: define versioned JSON schemas for `import-summary.json`,
`parity-report.json`, `warnings.jsonl`, `rollback-manifest.json`, and the
evidence bundle. Define the operator command or script name, required arguments,
environment variables, output directory structure, idempotency rules, stdout and
stderr behavior, and exit codes for parse error, schema violation, explained
mismatch, unexplained mismatch, missing artifact, unsafe `--replace`, invalid
snapshot hash, and rollback validation failure.

### 7. Shadow modes are config-only unless operation wiring is specified

Behavior 8 says to extend `native-shadow.ts` and wire shadow read/write in the
facade for selected operations (`plan:775-778`). Current mode resolution has
`shadow-read` and `shadow-write`, but `br-adapter.ts` only routes
`native-primary` specially; other modes fall through to legacy. Current shadow
records include only operation/category/input hash/results/replay/rollback data
(`apps/silmari-mcp/src/lib/native-shadow.ts:17-26`).

Impact: implementation can satisfy helper tests while no production facade
operation emits shadow evidence. Canary evidence would be configuration-only.

Required amendment: list the exact first facade operations to wrap for
shadow-read and shadow-write, the user-visible result owner for each operation,
the JSONL schema including run id, timestamp, mode, native DB path, legacy source
identity, binary identity, normalized result hashes, severity, and whether a
mismatch blocks promotion. Schedule this before any canary checklist that claims
shadow evidence.

### 8. Viewer load contract overclaims the current viewer path

Behavior 9 says the current viewer can load compatibility cache and card-native
tables (`plan:802-806`) and asks for loader support "if it is not already
present" (`plan:835-837`). The current viewer server still shells out to
`bv --export-pages` and serves a cached `beads.sqlite3`
(`apps/silmari-memory-card-viewer/server.ts:5-8`,
`apps/silmari-memory-card-viewer/server.ts:243-248`). The current comments and
config are still Beads-cache oriented (`apps/silmari-memory-card-viewer/server.ts:15-27`,
`apps/silmari-memory-card-viewer/server.ts:49-56`).

Impact: a Rust export DB test can pass without proving the deployed viewer
server loads from Silmari Store. Phase 5 could still depend on `bv`.

Required amendment: define the viewer integration contract. State how
`silmari-store export-viewer --mode compat/native` replaces or bypasses `bv`,
which env vars configure native DB/export mode, whether native mode still emits
`beads.sqlite3` and config hash files, and the exact browser-side query contract
for `viewer_cards` and `viewer_edges`. Require a server-level test proving
`/beads.sqlite3` and `/api/health` work from a native DB, not only DB-query tests.

### 9. Rollback runbook is not operationally enforceable

Behavior 10 says writes are paused and config switches back to legacy
(`plan:861-866`), then asks for a helper script or documented command sequence
(`plan:896-899`). Current `NativeModeConfig` has no rollback/snapshot/report
fields beyond mode/native DB/shadow dirs (`apps/silmari-mcp/src/lib/native-mode.ts:17-25`),
and `SILMARI_MEMORY_MODE` overrides config mode
(`apps/silmari-mcp/src/lib/native-mode.ts:94-97`).

Impact: the runbook can be documented but not tested as an operator-safe
procedure. A stale env override could defeat a config rollback, and there is no
specified write-freeze mechanism or proof that legacy DBs were preserved.

Required amendment: define how writes are paused, whether process restart is
required, env override precedence during rollback, how the selected legacy
snapshot/report paths are recorded, and what artifact proves no legacy DB was
deleted. Either extend `NativeModeConfig` with rollback fields or define a
separate rollback manifest input schema for the helper.

### 10. Phase 5 no-legacy-runtime gate misses viewer/export and docs surfaces

Behavior 12 focuses on production MCP `br` subprocess calls
(`plan:982-986`, `plan:1007-1018`). The viewer still depends on `BV_BIN`/`bv`
(`apps/silmari-memory-card-viewer/server.ts:56`,
`apps/silmari-memory-card-viewer/server.ts:244`) and deployment/docs/scripts
still mention old binary surfaces.

Impact: Phase 5 could pass for MCP while the production viewer/export runtime
still depends on legacy Beads tooling.

Required amendment: decide whether viewer `bv` is allowed during Phase 5. If it
is not allowed, expand the static gate to cover `bv`, `BV_BIN`, `BEADS_DIR`,
legacy viewer export paths, service files, README/docs, and scripts. If it is
allowed, explicitly carve viewer compatibility export out of Behavior 12 until
the native viewer server path is complete.

## Warnings

### W1. `zk_status` should specify failure shape and versioning

Behavior 2 is close, but it should require `zk_status` to catch native config,
binary, health, and schema errors into a stable `store`/`legacy` payload instead
of throwing or returning only old `br_available` shape. It should also snapshot
the payload version so clients can tolerate the deprecated compatibility field.

### W2. Unsupported-operation error code is named but not enumerated

The plan asks for explicit diagnostics, but the Rust error envelope currently has
specific codes for DB, card, schema, validation, migration, and CLI parse errors.
Add a stable `UNSUPPORTED_OPERATION` or equivalent code and require all disabled
native-primary surfaces to return it until implemented.

### W3. Evidence bundle shape is named but not versioned

Behavior 11 requires `canary-summary.json` (`plan:958-960`) but does not define
its schema, required artifact hashes, or whether validation checks artifact
content or only presence.

### W4. Static grep gates need allowlists by runtime role

The no-legacy gate should distinguish project issue tracking (`bd`) from legacy
Silmari storage (`br`/Beads) and should have separate allowlists for tests,
import-only archival commands, compatibility aliases, and production runtime.

## Required Plan Amendments

1. Add a "Global Contracts" section before Behavior 1 that defines:
   - canonical names and compatibility aliases;
   - Rust JSON success/error envelope and stable error codes;
   - MCP status payload version;
   - evidence artifact versioning rules.

2. Revise Behavior 1 to specify the exact Cargo/bin/env compatibility strategy:
   - canonical `silmari-store` binary;
   - whether package/lib remains `silmari_memory_rust` for one release;
   - old-name binary or wrapper requirements;
   - canonical and deprecated env var resolution order;
   - tests through MCP facade/dispatch.

3. Revise Behavior 3 with full native mutation contracts:
   - CLI command names, flags or JSON request bodies, response shapes;
   - lifecycle semantics for update/close/delete/show;
   - generated label and `ref:*` removal rules;
   - event names and idempotency;
   - unsupported-operation error code and MCP propagation.

4. Revise Behavior 4 to decide whether `zk_save_cards` must use native batch in
   native-primary. If yes, make `saveCardsBatch` route to `create-cards`; if no,
   remove `zk_save_cards` from no-partial-commit claims and canary wording.

5. Revise Behavior 5 to choose a single AUTO edge source-of-truth path in the
   plan, not during implementation.

6. Revise Behavior 6 to define biblio as MCP tools or library helpers, and
   decide the biblio duplicate/reinforces rule.

7. Revise Behavior 7 and Behavior 11 with versioned artifact schemas, operator
   command names, exit-code policy, output path conventions, and validation
   semantics.

8. Revise Behavior 8 with exact shadow facade operations, JSONL schema, and
   promotion-blocking mismatch policy.

9. Revise Behavior 9 with a server-level viewer/native export contract that
   explains how `bv` is replaced, bypassed, or explicitly retained.

10. Revise Behavior 10 with a testable rollback procedure, env precedence, write
    pause mechanism, snapshot/report manifest schema, and dry-run proof.

11. Revise Behavior 12 to include viewer/export/docs runtime dependencies or
    explicitly defer them with an accepted compatibility carveout.

## Approval Status

Needs Major Revision.

Do not split implementation child beads from this plan until the critical
amendments above are added. Non-overlapping discovery can continue, but
implementation work should not begin from this version because it leaves
source-of-truth, CLI/API, evidence, and rollback contracts open.
