---
date: 2026-04-29T09:30:00-04:00
planner: Codex
repository: silmari-agent-memory
branch: main
topic: "Cross-LLM SAI persistence and USER context routing"
type: implementation_plan
status: review-amended-tdd-plan
methodology: test_driven_development
source_notes:
  - thoughts/searchable/shared/research/notes-on-ultimate-mcp.md
review_applied:
  - thoughts/searchable/shared/plans/2026-04-29-cross-llm-sai-persistence-and-user-context-routing-REVIEW.md
related_plans:
  - thoughts/searchable/shared/plans/2026-04-28-silmari-agent-memory-xq6-tdd-ultimate-mcp-silmari-compatibility.md
related_research:
  - thoughts/searchable/shared/research/2026-04-28-ultimate-mcp-server-silmari-mcp-algorithm-contracts.md
  - thoughts/searchable/shared/research/2026-04-27-sai-algorithm-router-contracts.md
tags: [sai, mcp, cross-llm, persistence, user-context, workspace-blueprint]
---

# Cross-LLM SAI Persistence And USER Context Routing Implementation Plan

## Overview

Make SAI persistence usable from non-Claude Code LLM hosts without collapsing the existing storage boundaries. Silmari remains the durable Zettelkasten memory store exposed as `mcp__silmari__zk_*`; SAI gets a separate host-neutral persistence layer and a separate `sai` MCP/CLI surface for work state, lifecycle events, and `SAI/USER` context packs.

The implementation must also make the `SAI/USER/workspace-blueprint` pattern usable in the live USER tree without turning every directory into a verbose prompt dump. `CONTEXT.md` becomes the portable agent-facing router; `README.md` remains human-facing; executable registries such as `ACTIONS/`, `PIPELINES/`, and `FLOWS/` remain machine-authoritative.

## Current State Analysis

### Key Discoveries

| Area | Current reality | Evidence |
| --- | --- | --- |
| Silmari store root | Silmari card and retrieval state is rooted at `SILMARI_DIR`, with Beads boxes plus `${SILMARI_DIR}/silmari.db`. | `apps/silmari-mcp/src/lib/paths.ts:49`, `apps/silmari-mcp/src/lib/silmari-db.ts:45` |
| SAI store root | SAI runtime state is rooted at `SAI_DIR/MEMORY`, defaulting to `~/.claude/MEMORY`. | `SAI/hooks/lib/paths.ts:32`, `SAI/MEMORYSYSTEM.md:6` |
| PRD ownership | PRD is the source of truth; hooks read PRDs and sync derived `work.json`. | `SAI/PRDFORMAT.md:3`, `SAI/PRDFORMAT.md:120` |
| Event ownership | `events.jsonl` is append-only observability, not a replacement for mutable state. | `SAI/MEMORYSYSTEM.md:220`, `SAI/THEHOOKSYSTEM.md:1336` |
| Existing PRD sync | `PRDSync.hook.ts` reads `MEMORY/WORK/**/PRD.md` and calls shared `prd-utils` to update `STATE/work.json`. | `SAI/hooks/PRDSync.hook.ts:66`, `SAI/hooks/lib/prd-utils.ts:105` |
| ThinkWithMemory SAI root coverage | `ThinkWithMemory` already resolves state through `saiPath('MEMORY', 'STATE', 'think-with-memory')`; this plan keeps and pins that coverage rather than re-implementing it. | `SAI/hooks/ThinkWithMemory.hook.ts:43`, `SAI/hooks/ThinkWithMemory.hook.ts:47`, `SAI/hooks/tests/think-with-memory-sai-dir.test.ts:22` |
| Ultimate recursion coverage | Ultimate Silmari bridge already forces delegated tool and resource calls to `SILMARI_MCP_BACKEND=typescript`; this plan keeps and pins that coverage rather than re-implementing it. | `vendor/ultimate_mcp_server/ultimate_mcp_server/tools/silmari_compat.py:153`, `vendor/ultimate_mcp_server/ultimate_mcp_server/tools/silmari_compat.py:176`, `vendor/ultimate_mcp_server/tests/unit/test_silmari_compat.py:22` |
| Non-interference gap | Current test uses temp `SAI_DIR` and `SILMARI_DIR`, but it only calls `zk_reflect`; it still needs a temp Silmari write assertion and byte-identity checks for PRD/work/event/learning fixtures. | `apps/silmari-mcp/tests/sai-compat-noninterference.test.ts:19`, `apps/silmari-mcp/tests/sai-compat-noninterference.test.ts:97` |
| SAI writer inventory gap | Multiple hooks and tools write SAI files through direct or divergent root logic; every included writer must be inventoried and either refactored through `@sai/persistence` or guarded with conflict detection. | `SAI/hooks/SessionAutoName.hook.ts:152`, `SAI/hooks/SessionCleanup.hook.ts:41`, `SAI/hooks/WorkCompletionLearning.hook.ts:57`, `SAI/hooks/ChecklistStateInjector.hook.ts:59`, `SAI/Tools/algorithm.ts:343` |
| Event schema compatibility gap | New lifecycle rows must remain compatible with current event docs that use `timestamp`, `session_id`, `source`, and `type`; `eventType` and `occurredAt` are accepted aliases, not persisted-only replacements. | `SAI/MEMORYSYSTEM.md:220`, `SAI/THEHOOKSYSTEM.md:1290` |
| PRD schema authority gap | Current consumers use a mix of lean PRD docs, broader v4 templates, and Algorithm CLI fields; this plan must define compatibility instead of inventing an unowned schema. | `SAI/PRDFORMAT.md:6`, `SAI/hooks/lib/prd-template.ts:135`, `SAI/Tools/algorithm.ts:58` |
| USER folder | `SAI/USER` is a symlink into the live user-owned tree, not a static fixture. | `SAI/USER -> /home/maceo/.claude/SAI-USER` |
| Workspace blueprint | Blueprint teaches a 3-layer routing model: map, router, per-workspace context. | `SAI/USER/workspace-blueprint/START-HERE.md` |

### Existing Boundaries To Preserve

| Store | Owner | Writes allowed by this plan |
| --- | --- | --- |
| `SILMARI_DIR` | Silmari MCP | `zk_*` tools only. |
| `SAI_DIR/MEMORY/WORK` | SAI persistence | PRD creation/update through SAI work APIs and refactored hook/tool adapters; direct external edits remain supported only with mtime/hash conflict detection. |
| `SAI_DIR/MEMORY/STATE` | SAI persistence | Work registry, session state, operation index, event log, and hook state through the shared resolver. |
| `SAI_DIR/MEMORY/LEARNING` | SAI persistence | Learning/reflection capture through explicit SAI APIs and refactored learning hooks only. |
| `SAI_USER_DIR` / `SAI/USER` | User | Optional generated `CONTEXT.md` files and bounded context-pack reads, guarded by a separate USER root and never overwritten without explicit write mode. |
| Ultimate UMS | Ultimate MCP | Out of the compatibility path. |

## Desired End State

1. Every included SAI writer in the inventory resolves paths through one host-neutral root resolver, and static tests prevent new hardcoded home/`SAI_DIR` write logic in those files.
2. Claude Code hooks become one adapter over shared SAI persistence functions, not the only supported persistence mechanism.
3. A new `sai` MCP server exposes cross-LLM-safe tools for lifecycle events, work/PRD operations, and context packs.
4. The default `silmari` MCP server remains minimal and exposes only Silmari `zk_*` tools and `silmari://*` resources.
5. `SAI/USER` has compact agent routers that can be consumed by Claude Code, Cursor, OpenAI Agents, or any MCP client via `sai_context_pack`, with sensitive folders denied unless the caller provides explicit authorization fields.
6. Persistence writes are idempotent and serialized per `SAI_DIR` so multiple LLM hosts cannot corrupt PRDs, `work.json`, or `events.jsonl`.
7. Tests prove Silmari compatibility calls do not mutate SAI PRDs/work/events, and SAI tools do not write Silmari card storage.
8. Lifecycle event rows remain backward-compatible with existing event consumers while adding versioned SAI fields and an operation index for idempotency.
9. Work registry, PRD frontmatter, session, learning, context-pack, MCP, and CLI data shapes are specified before implementation starts.

## What We're NOT Doing

| Out of scope | Reason |
| --- | --- |
| Replacing Silmari with SAI persistence | Silmari is durable knowledge memory; SAI persistence is work/runtime state. |
| Adding `sai_*` tools to the default `silmari` MCP server | This would violate the minimal Silmari footprint contract. |
| Migrating PRDs into Silmari cards | PRD remains the source of truth for active work. |
| Replacing Claude Code hooks | Hooks remain supported, but become adapters over shared persistence. |
| Copying the full teaching blueprint into every USER folder | Live USER context should be concise and low maintenance. |
| Overwriting user-owned files automatically | USER propagation must be dry-run first and write only with explicit confirmation/flag. |
| Exposing all USER files by default through MCP | Context packs must be task-routed, bounded, and privacy-aware. |
| Making Ultimate UMS a SAI or Silmari backend | Requires a separate semantic parity plan. |

## Implementation Approach

Create a small TypeScript package, `packages/sai-persistence`, that owns SAI path resolution, lifecycle event envelopes, PRD/work registry operations, append-only event writes, file locking, idempotency, and USER context-pack selection. Then:

1. Refactor existing Claude Code hooks to call the package.
2. Add a separate `apps/sai-mcp` server exposing the package as MCP tools/resources.
3. Add a `SAI/Tools/sai-persist.ts` CLI for non-MCP hosts and shell usage.
4. Add a USER context router generator that propagates the workspace-blueprint pattern in a minimal live-user form.
5. Harden the existing Ultimate/Silmari bridge so Silmari remains a pure knowledge-memory runtime.

## TDD Methodology Overlay

This plan should be executed as behavior-first slices. Each slice starts with a failing test against a temp-root fixture, then the smallest production change that makes the test pass, then refactoring while the focused test and adjacent regression tests stay green. Implementation should not start from package scaffolding alone; package files are introduced only when a failing behavior needs them.

### Registry And Schema Reality Check

The canonical registry required by the TDD planning workflow is not present in this checkout:

- `specs/schemas/resource_registry.json` is absent.
- Root-level `schema/`, `schemas/`, and `specs/schemas/` directories are absent.
- `artifacts/impl/resource_registry.snapshot.json` exists, but its status is `proposed_registry_no_canonical_source` and its aliases cover earlier Rust retrieval-substrate work, not this SAI persistence plan.

Therefore every behavior below uses `resource_id: [PROPOSED:<alias>]`. `schema_contract_refs` must cite local prose/code contracts where they exist and use `N/A until canonical registry/schema sources exist` only for new data shapes defined solely in this plan. When a canonical registry is added, update these aliases with UUID-backed `resource_id` values and attach `schema_refs` before implementation claims formal registry coverage.

This does not mean the plan has no contracts. Until canonical JSON Schema files exist, the implementation must treat the following prose/code contracts as authoritative local schema references and cite them in `schema_contract_refs`:

| Local contract ref | Authority | Scope |
| --- | --- | --- |
| `SAI/PRDFORMAT.md` | Current PRD docs | Lean PRD source-of-truth language and hook sync expectations. |
| `SAI/hooks/lib/prd-template.ts` | Current PRD generator | Broader v4 frontmatter fields generated by hooks. |
| `SAI/Tools/algorithm.ts` | Algorithm CLI consumer | Runtime fields required by the algorithm workflow. |
| `SAI/hooks/lib/prd-utils.ts` | Current work registry writer | Backward-compatible `MEMORY/STATE/work.json` `sessions` projection. |
| `SAI/MEMORYSYSTEM.md` and `SAI/THEHOOKSYSTEM.md` | Current event docs | Legacy event row fields: `timestamp`, `session_id`, `source`, `type`. |
| `SAI/USER/workspace-blueprint/START-HERE.md` | USER routing pattern | Map/router/workspace-context model for live `CONTEXT.md` files. |

### Review Resolution Contract Additions

The review file listed six blocking issues. The following contracts resolve those issues and supersede any narrower wording later in this plan.

#### SAI Writer Inventory And Scope

Every row marked `included` must be covered by a temp-root test and must not retain its own hardcoded SAI write root after Phase 3. Rows marked `guarded` may continue to accept direct file edits, but package writes must use mtime/hash conflict detection and lock-aware retry.

| Writer | Current writes | Plan status | Required proof |
| --- | --- | --- | --- |
| `SAI/hooks/lib/prd-utils.ts` | `MEMORY/STATE/work.json` projection from PRDs | included | Work registry fixture preserves current `sessions[slug]` shape. |
| `SAI/hooks/PRDSync.hook.ts` | PRD-derived registry sync and lifecycle/voice side effects | included | Temp `SAI_DIR` PRD edit updates only temp `work.json` and appends compatible event row. |
| `SAI/hooks/SessionAutoName.hook.ts` | PRD stubs, session names/cache, current work state | included | Static guard rejects direct `process.env.SAI_DIR || homedir()` writer logic; temp-root test covers created PRD stub. |
| `SAI/hooks/SessionCleanup.hook.ts` | PRDs, current work, session names, cleanup state | included | Cleanup fixture writes only under temp memory root and releases locks on callback error. |
| `SAI/hooks/WorkCompletionLearning.hook.ts` | `MEMORY/LEARNING` reflections | included | Learning fixture uses `appendLearningRecord` and writes bounded records under temp `MEMORY/LEARNING`. |
| `SAI/hooks/ThinkWithMemory.hook.ts` | `MEMORY/STATE/think-with-memory` trigger state | included, already fixed | Existing `think-with-memory-sai-dir.test.ts` remains green. |
| `SAI/hooks/RatingCapture.hook.ts` | learning/signal/failure records | included | Rating capture fixture routes through `appendLearningRecord` or an explicitly documented learning adapter. |
| `SAI/hooks/RelationshipMemory.hook.ts` | relationship memory files | included | Relationship fixture routes writes through memory-root guard. |
| `SAI/hooks/LastResponseCache.hook.ts` | last-response cache state | included | Cache fixture writes only under temp memory root. |
| `SAI/hooks/ChecklistStateInjector.hook.ts` | checklist state | included | Static guard rejects `homedir()/.claude`; temp-root checklist fixture passes. |
| `SAI/hooks/ChecklistEnforcer.hook.ts` | checklist state/enforcement metadata | included | Static guard rejects `homedir()/.claude`; temp-root enforcement fixture passes. |
| `SAI/hooks/handlers/VoiceNotification.ts` | voice notification state, if any | included if it writes SAI files | If file writes exist, prove they use the shared resolver; otherwise assert read-only classification. |
| `SAI/hooks/handlers/SystemIntegrity.ts` | integrity reports/state, if any | included if it writes SAI files | Static inventory test classifies each file write as shared-resolver or read-only. |
| `SAI/hooks/handlers/DocCrossRefIntegrity.ts` | cross-ref reports/state, if any | included if it writes SAI files | Static inventory test classifies each file write as shared-resolver or read-only. |
| `SAI/hooks/handlers/UpdateCounts.ts` | count/cache state, if any | included if it writes SAI files | Static inventory test classifies each file write as shared-resolver or read-only. |
| `SAI/hooks/handlers/tab-setter.ts` | terminal/tab metadata, if any | included if it writes SAI files | Static inventory test classifies each file write as shared-resolver or read-only. |
| `SAI/Tools/algorithm.ts` | PRD frontmatter, loop state, session names | guarded | Algorithm writes either call `@sai/persistence` or package writes detect newer/different PRD content before mutation. |
| New `apps/sai-mcp` handlers | PRDs, registry, sessions, events, learning, context packs | included | MCP tests prove all mutations delegate to `@sai/persistence`. |
| New `SAI/Tools/sai-persist.ts` shim | Same as package functions | included | CLI tests prove shim delegates to one implementation. |

Add a static regression test that scans included writer files for direct SAI write roots such as `homedir()`, `os.homedir()`, `process.env.SAI_DIR ||`, `'.claude'`, and manually assembled `MEMORY/WORK`, `MEMORY/STATE`, or `MEMORY/LEARNING` write paths unless the path appears in the shared resolver or an allowlisted read-only classification.

#### PRD Authority And Concurrency

PRD remains canonical. The new package becomes the canonical mutation path for automated API/CLI/MCP/hook writes, while direct human or legacy Algorithm edits remain allowed as external edits.

Package PRD mutations must:

- Read PRD content, frontmatter, mtime, and a content hash before taking the work lock.
- Re-stat and re-read the PRD after the lock is acquired.
- Abort with `SaiConflictError` if the PRD changed and the caller did not pass the latest observed hash.
- Write PRD first, sync derived `work.json` second, append the lifecycle event third, and return the final PRD hash.
- Preserve unrelated PRD body bytes and frontmatter field order where possible; allow only the explicitly listed fields to change.

Direct Algorithm edits are compatible only if either `SAI/Tools/algorithm.ts` is refactored to call package functions for PRD mutations or package writes detect Algorithm changes by hash/mtime and reject stale writes. The implementation must not rely on advisory locks alone for direct writers that have not yet been refactored.

#### Path Roots, Realpath, And Symlink Policy

`SAI_DIR` and `SAI_USER_DIR` are separate roots:

- Memory writes must pass `assertInsideMemoryRoot(roots, candidatePath)` and resolve under `roots.memoryDir`.
- USER router writes must pass `assertInsideUserRoot(roots, candidatePath)` and resolve under `roots.userDir`.
- `SAI_USER_DIR` may be outside `SAI_DIR`; this is valid and must not be rejected by memory-root checks.
- `resolveSaiRoots` must expand `~`, resolve absolute paths deterministically, and must not create directories.
- Write functions create only the specific directories they own.
- Context-pack reads and generator writes must use `realpath` for existing paths. Symlink traversal is denied if the resolved path leaves `userDir`, except for the root `SAI/USER` symlink itself resolving to `SAI_USER_DIR`.
- Embedded repositories, `.git`, `node_modules`, package lock files, lock directories, sockets, FIFOs, device files, and binary files are always skipped.
- Returned context-pack paths are `displayPath` and `rootRelativePath`; absolute real paths are hidden unless `includeRealPaths: true` is explicitly set for a local debug caller.

#### Event Compatibility And Idempotency

The persisted JSONL row must be backward-compatible with current event docs:

```json
{
  "schemaVersion": "sai.lifecycle.v1",
  "timestamp": "2026-04-29T09:30:00.000Z",
  "session_id": "uuid-or-host-session-id",
  "source": "claude-code",
  "type": "session.start",
  "operationId": "host-session-turn-event",
  "host": {
    "name": "claude-code",
    "sessionId": "uuid-or-host-session-id",
    "model": "optional-model-name"
  },
  "workSlug": "optional-work-slug",
  "payload": {}
}
```

`normalizeLifecycleEvent` may accept `occurredAt` as an alias for `timestamp` and `eventType` as an alias for `type`, but persisted rows must include the legacy fields. Duplicate operation behavior is:

- Same `operationId` and identical canonical event hash: return `{ appended: false, duplicate: true }`.
- Same `operationId` and different canonical event hash: throw `SaiOperationConflictError` and do not append.
- Existing event row without index entry: rebuild or repair the index before deciding duplicate status.
- Index entry without a matching event row: treat as corrupt state, throw `SaiEventIndexCorruptError`, and include repair instructions in the error details.

The operation index lives at `MEMORY/STATE/operation-index.json`:

```ts
interface OperationIndex {
  schemaVersion: "sai.operation-index.v1";
  operations: Record<string, {
    eventHash: string;
    type: string;
    timestamp: string;
    line: number;
    sessionId: string;
    workSlug?: string;
    duplicateAttempts?: number;
    lastDuplicateAt?: string;
  }>;
}
```

#### Work, PRD, Session, And Learning Schemas

The package must define TypeScript interfaces before implementation and keep them compatible with current consumers.

```ts
interface WorkRegistry {
  schemaVersion?: "sai.work-registry.v1";
  current?: string;
  sessions: Record<string, WorkSession>;
}

interface WorkSession {
  prd: string;
  task: string;
  sessionName?: string;
  sessionUUID?: string;
  phase?: string;
  progress?: number;
  effort?: string;
  mode?: string;
  started?: string;
  updatedAt: string;
  criteria: Array<{ id: string; text: string; checked: boolean }>;
  phaseHistory?: Array<{ phase: string; timestamp: string; note?: string }>;
  iteration?: number;
  status?: string;
  loopStatus?: string;
  verification_summary?: string;
}

interface SaiSessionRecord {
  schemaVersion: "sai.session.v1";
  sessionId: string;
  host: SaiHostIdentity;
  startedAt: string;
  endedAt?: string;
  activeWorkSlug?: string;
}

interface LearningRecord {
  schemaVersion: "sai.learning.v1";
  operationId: string;
  category: "reflection" | "rating" | "relationship" | "failure" | "signal";
  timestamp: string;
  host: SaiHostIdentity;
  workSlug?: string;
  summary: string;
  content?: string;
  metadata?: Record<string, unknown>;
}
```

PRD compatibility policy:

- Accept both lean `SAI/PRDFORMAT.md` frontmatter and broader v4/Algorithm frontmatter.
- Preserve unknown frontmatter fields when parsing/rendering.
- Safe patch fields are `phase`, `progress`, `mode`, `updated`, `updatedAt`, `iteration`, `status`, `loopStatus`, `verification_summary`, `last_phase`, `failing_criteria`, and `maxIterations`.
- `criteria` are derived from ISC checkbox lines and must not be duplicated into frontmatter unless an existing PRD already uses that representation.

#### Context-Pack Authorization

`ContextPackRequest` must include explicit caller intent:

```ts
interface ContextPackRequest {
  task: string;
  workspace?: string;
  host?: SaiHostIdentity;
  maxFiles?: number;
  maxChars?: number;
  allowSensitive?: boolean;
  sensitiveScopes?: Array<"TELOS" | "WORK" | "BUSINESS">;
  includeRealPaths?: boolean;
}
```

Sensitive folders are denied by default. A context pack may include `TELOS`, `WORK`, or `BUSINESS` only when `allowSensitive: true`, the requested scope is present in `sensitiveScopes`, and routing explicitly selects that scope. Every sensitive inclusion appends an audit lifecycle event of type `context.pack.sensitive`.

#### MCP, CLI, And Error Contracts

Every MCP tool must publish an `inputSchema` using the same pattern as `apps/silmari-mcp/src/index.ts`. Success responses are JSON text with this shape:

```ts
interface SaiToolSuccess<T> {
  ok: true;
  schemaVersion: "sai.tool-result.v1";
  result: T;
}
```

Tool failures return `isError: true` and JSON text:

```ts
interface SaiToolError {
  ok: false;
  schemaVersion: "sai.tool-error.v1";
  error: {
    code:
      | "SAI_VALIDATION_ERROR"
      | "SAI_PATH_ESCAPE"
      | "SAI_LOCK_TIMEOUT"
      | "SAI_CONFLICT"
      | "SAI_NOT_FOUND"
      | "SAI_EVENT_INDEX_CORRUPT"
      | "SAI_IO_ERROR";
    message: string;
    details?: Record<string, unknown>;
  };
}
```

CLI behavior:

- Exit `0` for successful commands with JSON written to stdout.
- Exit `2` for usage/schema errors with human-readable help on stderr and no partial mutation.
- Exit `1` for runtime/tool failures with `SaiToolError` JSON on stderr.
- `SAI/Tools/sai-persist.ts` is only a shim over `apps/sai-mcp/src/cli.ts`; it must not duplicate persistence logic.

### Test Framework And Order

Use the repo's existing test tools:

- TypeScript packages and apps: `bun test`, plus package-local `tsc --noEmit` through workspace `typecheck` scripts.
- Vendor Ultimate bridge: `cd vendor/ultimate_mcp_server && UV_PYTHON=3.13 uv run pytest -o addopts='' --confcutdir=tests/unit tests/unit/test_silmari_compat.py`.
- Cross-boundary tests must use temp `SAI_DIR`, temp `SILMARI_DIR`, temp box directories, and no writes to the developer's real `~/.claude` or `~/.silmari-memory`.

Execution order:

1. Start with Phase 1 boundary tests because they protect existing stores before new entry points exist.
2. Add `@sai/persistence` one behavior at a time: paths, locks, events, PRD registry, context packs.
3. Refactor Claude hooks behind existing exported names only after the package tests are green.
4. Add `apps/sai-mcp` only after package behavior is test-covered.
5. Add USER router generation after context-pack routing tests define privacy and selection behavior.
6. Finish with cross-LLM lifecycle and dual-MCP non-interference tests.

### Smallest Testable Behaviors

| ID | Behavior | First failing test | `resource_id` / alias | `predicate_refs` | `codepath_ref` | `schema_contract_refs` |
| --- | --- | --- | --- | --- | --- | --- |
| B1 | Given `SILMARI_MCP_BACKEND=ultimate`, when the Ultimate compatibility bridge delegates a Silmari tool or resource, then the child command receives `SILMARI_MCP_BACKEND=typescript`; existing unit coverage is pinned and an app-level regression guards the CLI path. | `vendor/ultimate_mcp_server/tests/unit/test_silmari_compat.py` and `apps/silmari-mcp/tests/ultimate-bridge-backend-boundary.test.ts` | `[PROPOSED:ultimate_silmari_backend_delegation]` / `ultimate.silmari_backend_delegation` | env backend, tool/resource request | `force-silmari-bridge-typescript-backend` | Bridge env contract in `vendor/ultimate_mcp_server/ultimate_mcp_server/tools/silmari_compat.py` |
| B2 | Given `SAI_DIR` points at a temp root, when ThinkWithMemory persists trigger state, then existing coverage proves the state file lands under temp `SAI_DIR/MEMORY/STATE/think-with-memory`. | `SAI/hooks/tests/think-with-memory-sai-dir.test.ts` | `[PROPOSED:sai_think_state_root]` / `sai.think_state_root` | env SAI_DIR, hook payload | `route-think-with-memory-state-through-sai-dir` | `SAI/hooks/lib/paths.ts`, `SAI/hooks/ThinkWithMemory.hook.ts` |
| B3 | Given temp SAI memory files and temp Silmari stores, when read/write Silmari compatibility calls run, then every SAI PRD/work/event/learning byte remains unchanged and Silmari writes only to temp `SILMARI_DIR`. | `apps/silmari-mcp/tests/sai-compat-noninterference.test.ts` | `[PROPOSED:sai_silmari_noninterference]` / `sai.silmari_noninterference` | temp SAI tree, temp Silmari tree | `assert-silmari-sai-store-separation` | `apps/silmari-mcp/src/lib/paths.ts`, `SAI/MEMORYSYSTEM.md` |
| B4 | Given host env overrides, when SAI roots are resolved, then memory writes are absolute under `SAI_DIR`, USER writes are absolute under `SAI_USER_DIR`, and traversal outside the operation-specific root is rejected. | `packages/sai-persistence/tests/paths.test.ts` | `[PROPOSED:sai_path_roots]` / `sai.path_roots` | env SAI_DIR, env SAI_USER_DIR | `resolve-sai-roots` | Path root contract in this plan |
| B5 | Given concurrent PRD/event writers, when they use the SAI lock helper, then writes serialize, callback failures release locks in `finally`, timeout deterministically, and stale lock cleanup requires age greater than `staleMs`. | `packages/sai-persistence/tests/lock.test.ts` | `[PROPOSED:sai_write_lock]` / `sai.write_lock` | lock name, stale threshold | `serialize-sai-writes` | Lock contract in this plan |
| B6 | Given lifecycle events with operation IDs, when events are appended, then persisted rows include legacy event fields, repeated identical operation IDs dedupe, mismatched duplicates fail, and invalid envelopes fail before mutation. | `packages/sai-persistence/tests/events.test.ts`, `packages/sai-persistence/tests/legacy-event-compat.test.ts` | `[PROPOSED:sai_lifecycle_event_log]` / `sai.lifecycle_event_log` | lifecycle envelope, operation index | `append-idempotent-lifecycle-event` | `SAI/MEMORYSYSTEM.md`, `SAI/THEHOOKSYSTEM.md`, event compatibility contract in this plan |
| B7 | Given a PRD with frontmatter and ISC checkboxes, when work operations create/read/patch/check/sync, then PRD remains canonical, unrelated body text is preserved, `work.json` is derived in the current `sessions[slug]` shape, and each mutation emits a compatible event. | `packages/sai-persistence/tests/prd.test.ts`, `packages/sai-persistence/tests/work-registry.test.ts`, `packages/sai-persistence/tests/work-registry-compat.test.ts` | `[PROPOSED:sai_prd_work_registry]` / `sai.prd_work_registry` | PRD content, safe patch fields, criterion ID | `sync-prd-backed-work-registry` | `SAI/PRDFORMAT.md`, `SAI/hooks/lib/prd-template.ts`, `SAI/Tools/algorithm.ts`, `SAI/hooks/lib/prd-utils.ts` |
| B8 | Given the new MCP app starts, when clients list and call tools/resources, then only `sai_*` tools and `sai://*` resources are exposed, every tool publishes an input schema, and handlers delegate to `@sai/persistence`. | `apps/sai-mcp/tests/tool-surface.test.ts` | `[PROPOSED:sai_mcp_surface]` / `sai.mcp_surface` | MCP tool list, input schemas, persistence calls | `register-sai-mcp-surface` | MCP schema contract in this plan |
| B9 | Given `SAI/USER` routers and a task request, when `sai_context_pack` builds a pack, then it prefers `CONTEXT.md`, enforces size limits, denies sensitive folders by default, rejects symlink escapes, and reports selected/skipped reasons. | `packages/sai-persistence/tests/context-pack.test.ts`, `packages/sai-persistence/tests/context-pack-symlinks.test.ts` | `[PROPOSED:sai_context_pack_router]` / `sai.context_pack_router` | task, workspace, router files, sensitivity flags | `build-user-context-pack` | `SAI/USER/workspace-blueprint/START-HERE.md`, context-pack contract in this plan |
| B10 | Given missing or existing live USER routers, when the generator runs in dry-run/write/force modes, then dry-run is read-only, write creates missing files only, force backs up before overwrite, and symlinks cannot redirect writes outside `userDir`. | `SAI/Tools/tests/user-context-blueprint.test.ts` | `[PROPOSED:sai_user_context_generator]` / `sai.user_context_generator` | live USER tree, mode flags | `generate-user-context-routers` | USER generator contract in this plan |
| B11 | Given a non-Claude host uses the `sai` MCP server, when it starts a session, creates work, appends prompt/tool/result events, checks one criterion, and ends the session, then PRD, `work.json`, operation index, and `events.jsonl` are valid without invoking Claude Code hooks. | `apps/sai-mcp/tests/cross-llm-lifecycle.test.ts` | `[PROPOSED:sai_cross_llm_lifecycle]` / `sai.cross_llm_lifecycle` | host identity, work slug, event stream | `run-cross-llm-sai-lifecycle` | Session, work, event, and MCP contracts in this plan |
| B12 | Given every included SAI writer file, when the static inventory guard runs, then no included writer contains non-allowlisted direct SAI write root logic. | `SAI/hooks/tests/sai-writer-inventory.test.ts` | `[PROPOSED:sai_writer_inventory]` / `sai.writer_inventory` | writer file list, allowlist | `enforce-sai-writer-inventory` | SAI writer inventory in this plan |
| B13 | Given a PRD changed after a package caller read it, when the caller attempts a stale patch, then the package rejects the write with `SaiConflictError` and leaves PRD/work/events unchanged. | `packages/sai-persistence/tests/prd-conflict.test.ts` | `[PROPOSED:sai_prd_conflict_detection]` / `sai.prd_conflict_detection` | PRD hash, mtime, patch input | `detect-prd-write-conflicts` | PRD authority contract in this plan |
| B14 | Given `sai_context_pack` includes a sensitive scope, when `allowSensitive` and matching `sensitiveScopes` are present, then the selected sensitive files are returned and a `context.pack.sensitive` audit event is appended. | `packages/sai-persistence/tests/context-pack-sensitive.test.ts` | `[PROPOSED:sai_context_sensitive_authorization]` / `sai.context_sensitive_authorization` | sensitivity flags, host identity | `authorize-sensitive-context-pack` | Context-pack authorization contract in this plan |
| B15 | Given every public `sai-persist` command, when it succeeds or fails, then stdout/stderr and exit codes match the CLI contract. | `apps/sai-mcp/tests/cli-contract.test.ts` | `[PROPOSED:sai_cli_contract]` / `sai.cli_contract` | argv, stdin JSON, errors | `run-sai-persist-cli` | CLI contract in this plan |

### Red-Green-Refactor Discipline

For each behavior:

1. Red: write the focused test first and verify it fails for the intended reason. Do not satisfy failures by weakening assertions or relaxing isolation.
2. Green: implement the smallest production path that passes the focused test. Prefer pure functions with explicit `SaiPersistenceOptions` over process-wide env mutation.
3. Refactor: remove duplication, align with existing package patterns, and rerun the focused test plus adjacent regression tests before moving to the next behavior.

Concrete per-behavior cycles:

| Behavior | Red | Green | Refactor |
| --- | --- | --- | --- |
| B1 | Assert inherited `ultimate` backend is overwritten for tool and resource delegation. | Pin the existing unconditional assignment behavior and add the app-level regression only if missing. | Share a small helper if both paths duplicate the same override. |
| B2 | Assert ThinkWithMemory temp-root state path under `SAI_DIR`. | Pin the existing `saiPath(...)` implementation and focused test. | Move path choice behind the shared resolver during Phase 3 so future hooks do not reintroduce direct `homedir()`. |
| B3 | Snapshot temp SAI PRD/work/current-work/events/learning files before Silmari calls and assert byte identity after. | Ensure compatibility tests pass temp `SAI_DIR` and Silmari code writes only temp `SILMARI_DIR`. | Keep fixture helpers reusable for later dual-MCP tests. |
| B4 | Prove `SAI_DIR` and `SAI_USER_DIR` overrides work and traversal is rejected per operation root. | Implement `resolveSaiRoots`, `assertInsideMemoryRoot`, and `assertInsideUserRoot`. | Centralize path expansion and make all package writes accept `SaiPersistenceOptions`. |
| B5 | Race two lock users and assert one waits or times out deterministically; assert callback throw releases the lock. | Implement atomic lock-directory acquisition and release in `finally`. | Add owner metadata and stale cleanup without changing the public result shape. |
| B6 | Assert invalid lifecycle envelopes do not create event or index files, legacy fields persist, identical duplicates dedupe, and mismatched duplicates fail. | Validate/normalize event shape, append JSONL, and update operation index under lock. | Split normalizer, dedupe check, index repair, and atomic write helpers. |
| B7 | Assert PRD body preservation while patching safe fields and checking ISC lines, plus `work.json` compatibility with current `prd-utils`. | Implement PRD parse/render and derived registry sync. | Keep old hook-facing exports delegating to package functions without changing hook behavior. |
| B8 | Assert `apps/sai-mcp` exposes no `zk_*` tools and no Silmari resources. | Register `sai_*` tools around package calls. | Normalize MCP success/error envelope handling in one helper. |
| B9 | Assert marketing task selects marketing context while Telos/WORK/BUSINESS stay skipped and symlink escapes are rejected. | Implement router-first bounded file selection with realpath checks. | Extract file filters and sensitive-directory policy into pure helpers. |
| B10 | Assert dry-run writes nothing, write creates only missing files, force writes backups, and symlink redirects are rejected. | Implement generator mode parsing and file operations. | Reuse the same router templates that context-pack tests expect. |
| B11 | Assert non-Claude lifecycle runs without hook imports and dual roots remain separated. | Wire MCP tool handlers to the package and temp-root fixtures. | Collapse repeated host fixture setup into shared test helpers. |
| B12 | Assert every included writer file fails the static scan until direct SAI write roots are removed or allowlisted read-only. | Route included writer writes through `@sai/persistence` or document read-only classification. | Keep the inventory list close to hook tests so new writers must declare ownership. |
| B13 | Assert stale PRD patch rejects after an external edit. | Implement mtime/hash conflict detection around package PRD writes. | Reuse conflict checks for CLI, MCP, and hook adapters. |
| B14 | Assert sensitive context requires both `allowSensitive` and matching `sensitiveScopes`, and emits an audit event. | Add authorization checks and `context.pack.sensitive` event append. | Reuse event append helper and context skip reasons. |
| B15 | Assert `sai-persist` exit codes and stdout/stderr formats for success, usage error, and runtime error. | Implement CLI shim over the MCP/package command handlers. | Keep CLI parsing separate from persistence logic. |

### Planned Function Contract Tags

Every new or materially changed public function must include a documentation contract block before implementation. Because the canonical registry is absent, use proposed IDs exactly as below until UUID-backed entries exist.

TypeScript contract block format:

```ts
/**
 * @rr.id [PROPOSED:<alias_snake_case>]
 * @rr.alias <branch.leaf>
 * @path.id <kebab-path-name>
 * @gwt.given <given clause>
 * @gwt.when <when clause>
 * @gwt.then <then clause>
 * @reads <resource refs or N/A>
 * @writes <resource refs or N/A>
 * @raises <error_ref:error_name or N/A>
 * @schema.contract <local contract ref or N/A until canonical schema sources exist>
 */
```

Required contract assignments:

| Function | Contract fields |
| --- | --- |
| `resolveSaiRoots` | `@rr.id [PROPOSED:sai_path_roots]`; `@rr.alias sai.path_roots`; `@path.id resolve-sai-roots`; Given host env with optional `SAI_DIR`/`SAI_USER_DIR`; when roots resolve; then memory and USER roots are absolute, deterministic, and not created as a side effect; reads env; writes N/A; raises N/A; schema.contract path root contract in this plan. |
| `assertInsideMemoryRoot` | `@rr.id [PROPOSED:sai_path_roots]`; `@rr.alias sai.path_roots`; `@path.id assert-inside-memory-root`; Given resolved roots and a candidate path; when a memory write target is checked; then paths outside `roots.memoryDir` are rejected; reads root/path; writes N/A; raises `[PROPOSED:sai_path_escape_error]:SaiPathEscapeError`; schema.contract path root contract in this plan. |
| `assertInsideUserRoot` | `@rr.id [PROPOSED:sai_path_roots]`; `@rr.alias sai.path_roots`; `@path.id assert-inside-user-root`; Given resolved roots and a candidate path; when a USER router write or context read target is checked; then paths outside `roots.userDir` are rejected after realpath resolution; reads root/path; writes N/A; raises `[PROPOSED:sai_path_escape_error]:SaiPathEscapeError`; schema.contract path root contract in this plan. |
| `withSaiLock` | `@rr.id [PROPOSED:sai_write_lock]`; `@rr.alias sai.write_lock`; `@path.id serialize-sai-writes`; Given a lock name and SAI roots; when a mutation runs; then only one writer enters the critical section and the lock releases in `finally`; reads lock metadata; writes `MEMORY/STATE/.locks/*`; raises `[PROPOSED:sai_lock_timeout]:SaiLockTimeoutError`. |
| `normalizeLifecycleEvent` | `@rr.id [PROPOSED:sai_lifecycle_event_log]`; `@rr.alias sai.lifecycle_event_log`; `@path.id normalize-lifecycle-event`; Given unknown input; when event normalization runs; then a valid `SaiLifecycleEvent` is returned or rejected before mutation; reads input; writes N/A; raises `[PROPOSED:sai_event_validation_error]:SaiEventValidationError`. |
| `appendLifecycleEvent` | `@rr.id [PROPOSED:sai_lifecycle_event_log]`; `@rr.alias sai.lifecycle_event_log`; `@path.id append-idempotent-lifecycle-event`; Given unknown event input; when appending; then input is normalized, one legacy-compatible JSONL line is written unless an identical operation ID already exists, and mismatched duplicates fail; reads `operation-index.json`; writes `events.jsonl`, `operation-index.json`; raises event validation, operation conflict, index corruption, or lock errors. |
| `parsePrd` | `@rr.id [PROPOSED:sai_prd_work_registry]`; `@rr.alias sai.prd_work_registry`; `@path.id parse-prd`; Given PRD markdown; when parsed; then frontmatter, criteria, and body ranges are returned without losing source text; reads PRD content; writes N/A; raises `[PROPOSED:sai_prd_parse_error]:SaiPrdParseError`. |
| `renderPrd` | `@rr.id [PROPOSED:sai_prd_work_registry]`; `@rr.alias sai.prd_work_registry`; `@path.id render-prd`; Given a parsed PRD; when rendered; then unrelated body content is byte-preserved; reads parsed PRD; writes N/A; raises `[PROPOSED:sai_prd_render_error]:SaiPrdRenderError`. |
| `createWork` | `@rr.id [PROPOSED:sai_prd_work_registry]`; `@rr.alias sai.prd_work_registry`; `@path.id create-prd-backed-work`; Given work creation input; when creating work; then a PRD directory is created and registry state derives from it; reads roots/input; writes `MEMORY/WORK/*/PRD.md`, `work.json`, `events.jsonl`; raises validation, path, or lock errors. |
| `readWork` | `@rr.id [PROPOSED:sai_prd_work_registry]`; `@rr.alias sai.prd_work_registry`; `@path.id read-prd-backed-work`; Given a slug or PRD path; when reading work; then PRD frontmatter, criteria, and registry projection are returned; reads PRD and `work.json`; writes N/A; raises not-found or parse errors. |
| `patchWorkFrontmatter` | `@rr.id [PROPOSED:sai_prd_work_registry]`; `@rr.alias sai.prd_work_registry`; `@path.id patch-prd-frontmatter`; Given safe frontmatter patches; when patching; then only allowlisted fields change and registry/event state updates; reads PRD; writes PRD, `work.json`, `events.jsonl`; raises validation, path, or lock errors. |
| `setCriterionChecked` | `@rr.id [PROPOSED:sai_prd_work_registry]`; `@rr.alias sai.prd_work_registry`; `@path.id set-prd-criterion-checked`; Given a criterion ID and checked value; when applying; then one ISC line toggles and progress/registry/event state updates; reads PRD; writes PRD, `work.json`, `events.jsonl`; raises missing criterion or lock errors. |
| `syncWorkRegistry` | `@rr.id [PROPOSED:sai_prd_work_registry]`; `@rr.alias sai.prd_work_registry`; `@path.id sync-prd-work-registry`; Given a PRD path; when syncing; then `work.json` becomes a derived projection of PRD state; reads PRD and optional session-name state; writes `work.json`; raises parse/path errors. |
| `appendLearningRecord` | `@rr.id [PROPOSED:sai_learning_append]`; `@rr.alias sai.learning_append`; `@path.id append-learning-record`; Given explicit learning input; when appending; then a bounded learning record is written under `MEMORY/LEARNING` and a compatible lifecycle audit event is appended; reads roots/input; writes learning file and `events.jsonl`; raises validation, path, lock, or size errors. |
| `buildUserContextPack` | `@rr.id [PROPOSED:sai_context_pack_router]`; `@rr.alias sai.context_pack_router`; `@path.id build-user-context-pack`; Given task/workspace request; when building a context pack; then bounded selected/skipped files with reasons are returned; reads `SAI/USER/**/CONTEXT.md` and selected files; writes N/A; raises path/filter errors. |
| `sai_event_append` | `@rr.id [PROPOSED:sai_mcp_surface]`; `@rr.alias sai.mcp_surface`; `@path.id mcp-sai-event-append`; Given MCP event input; when called; then it returns the package append result in a JSON text response; reads/writes same as `appendLifecycleEvent`; raises MCP tool error envelope. |
| `sai_session_start` / `sai_session_end` | `@rr.id [PROPOSED:sai_cross_llm_lifecycle]`; `@rr.alias sai.cross_llm_lifecycle`; `@path.id mcp-sai-session-lifecycle`; Given host/session input; when called; then session state and lifecycle events update idempotently; reads session state and operation index; writes session state and `events.jsonl`; raises MCP tool error envelope. |
| `sai_work_create` / `sai_work_read` / `sai_work_patch_frontmatter` / `sai_work_check_criterion` | `@rr.id [PROPOSED:sai_mcp_surface]`; `@rr.alias sai.mcp_surface`; `@path.id mcp-sai-work-tools`; Given MCP work input; when called; then package work operations run without exposing Silmari tools; reads/writes same as the underlying work function; raises MCP tool error envelope. |
| `sai_learning_append` | `@rr.id [PROPOSED:sai_learning_append]`; `@rr.alias sai.learning_append`; `@path.id mcp-sai-learning-append`; Given explicit learning input; when called; then a bounded learning record is appended under `MEMORY/LEARNING`; reads roots/input; writes learning file and event log; raises validation/path errors. |
| `sai_context_pack` | `@rr.id [PROPOSED:sai_context_pack_router]`; `@rr.alias sai.context_pack_router`; `@path.id mcp-sai-context-pack`; Given MCP context request; when called; then bounded context-pack JSON is returned; reads USER routers and selected files; writes N/A; raises MCP tool error envelope. |
| `sai_status` | `@rr.id [PROPOSED:sai_mcp_surface]`; `@rr.alias sai.mcp_surface`; `@path.id mcp-sai-status`; Given no input or status options; when called; then resolved roots and feature availability are reported without mutation; reads roots and existence checks; writes N/A; raises N/A. |
| `planUserContextBlueprint` / `writeUserContextBlueprint` | `@rr.id [PROPOSED:sai_user_context_generator]`; `@rr.alias sai.user_context_generator`; `@path.id generate-user-context-routers`; Given live USER tree and mode flags; when planning/writing routers; then dry-run is read-only, write creates missing files, and force backs up before overwrite; reads USER tree/templates; writes `CONTEXT.md` and backups only in write modes; raises path/write errors. |
| `call_silmari_tool` / `call_silmari_resource` | `@rr.id [PROPOSED:ultimate_silmari_backend_delegation]`; `@rr.alias ultimate.silmari_backend_delegation`; `@path.id force-silmari-bridge-typescript-backend`; Given inherited backend env; when delegating through Ultimate; then the child bridge always uses TypeScript backend; reads env and request; writes N/A; raises `SilmariBridgeError`. |

### Package Interface Appendix

The first implementation slice must define these interfaces in `packages/sai-persistence/src/types.ts` before tool handlers or hooks call them. Optional fields must be omitted from serialized JSON when absent.

```ts
interface SaiHostIdentity {
  name: string;
  sessionId?: string;
  model?: string;
  pid?: number;
}

interface SaiPersistenceOptions {
  env?: Record<string, string | undefined>;
  roots?: SaiRoots;
  host?: SaiHostIdentity;
  operationId?: string;
  clock?: () => Date;
  logger?: { debug?(msg: string, meta?: unknown): void; warn?(msg: string, meta?: unknown): void };
  lockTimeoutMs?: number;
  staleLockMs?: number;
  dryRun?: boolean;
}

interface SaiRoots {
  saiDir: string;
  userDir: string;
  memoryDir: string;
  workDir: string;
  stateDir: string;
  learningDir: string;
  eventsPath: string;
  operationIndexPath: string;
  workRegistryPath: string;
  sessionsPath: string;
}

interface CreateWorkInput {
  title: string;
  slug?: string;
  task?: string;
  effort?: "low" | "medium" | "high" | string;
  mode?: string;
  template?: "lean" | "algorithm-v4";
  sessionId?: string;
  initialCriteria?: string[];
  expectedBaseHash?: string;
  operationId?: string;
}

interface WorkResult {
  slug: string;
  prdPath: string;
  prdHash: string;
  work: WorkSession;
  registry: WorkRegistry;
  event?: SaiLifecycleEvent;
}

interface WorkReadResult extends WorkResult {
  prd: ParsedPrd;
}

interface PatchFrontmatterInput {
  slugOrPath: string;
  patch: Partial<Record<
    | "phase"
    | "progress"
    | "mode"
    | "updated"
    | "updatedAt"
    | "iteration"
    | "status"
    | "loopStatus"
    | "verification_summary"
    | "last_phase"
    | "failing_criteria"
    | "maxIterations",
    unknown
  >>;
  expectedBaseHash?: string;
  operationId?: string;
}

interface CriterionPatchInput {
  slugOrPath: string;
  criterionId: string;
  checked: boolean;
  expectedBaseHash?: string;
  operationId?: string;
}

interface WorkRegistryResult {
  slug: string;
  registry: WorkRegistry;
  work: WorkSession;
}

interface ContextPackResult {
  schemaVersion: "sai.context-pack.v1";
  request: ContextPackRequest;
  selectedFiles: Array<{
    displayPath: string;
    rootRelativePath: string;
    reason: string;
    content: string;
    bytes: number;
    sensitiveScope?: "TELOS" | "WORK" | "BUSINESS";
    realPath?: string;
  }>;
  skippedFiles: Array<{
    displayPath: string;
    rootRelativePath?: string;
    reason:
      | "not-routed"
      | "sensitive-denied"
      | "size-limit"
      | "binary"
      | "blocked-path"
      | "symlink-escape"
      | "unsupported-file";
  }>;
  warnings: string[];
}
```

### TDD Completion Gates

A phase is complete only when:

- The focused Red test was observed failing before implementation.
- The focused test passes after Green implementation.
- Refactor did not change externally observable behavior.
- Adjacent regression tests listed in that phase pass.
- Any new public or changed function has the contract tags above.
- Temp-root tests prove no writes escape their intended `SAI_DIR` or `SILMARI_DIR`.

## Proposed Public Contracts

### Lifecycle Event Envelope

Persisted event rows must include current legacy fields plus versioned SAI fields:

```json
{
  "schemaVersion": "sai.lifecycle.v1",
  "timestamp": "2026-04-29T09:30:00.000Z",
  "session_id": "uuid-or-host-session-id",
  "source": "claude-code",
  "type": "session.start",
  "operationId": "host-session-turn-event",
  "host": {
    "name": "claude-code",
    "sessionId": "uuid-or-host-session-id",
    "model": "optional-model-name"
  },
  "workSlug": "optional-work-slug",
  "payload": {}
}
```

Allowed `type` values for the first slice:

```text
session.start
session.end
user.prompt
assistant.response
tool.call
tool.result
work.created
work.updated
prd.synced
learning.appended
context.pack.created
context.pack.sensitive
```

Input aliases `eventType` and `occurredAt` are accepted by `normalizeLifecycleEvent`, but persisted rows must use `type` and `timestamp`.

### SAI MCP Tool Surface

The new MCP server should be registered as `sai`, not `silmari`.

Every tool response is wrapped in `SaiToolSuccess<T>` or `SaiToolError`. Every tool schema must set `additionalProperties: false` unless a named `metadata` object is intentionally extensible.

| Tool | Required input schema fields | Result |
| --- | --- | --- |
| `sai_event_append` | `event` object containing `operationId`, `host.name`, `host.sessionId`, `type` or `eventType`; optional `timestamp`/`occurredAt`, `workSlug`, `payload` | `{ appended: boolean, duplicate?: boolean, event: SaiLifecycleEvent }` |
| `sai_session_start` | `host.name`; optional `host.sessionId`, `host.model`, `workSlug`, `operationId` | `SaiSessionRecord` |
| `sai_session_end` | `sessionId`, `host.name`; optional `operationId`, `endedAt` | `SaiSessionRecord` |
| `sai_work_create` | `title`; optional `slug`, `task`, `effort`, `mode`, `template`, `sessionId`, `initialCriteria`, `operationId` | `WorkResult` |
| `sai_work_read` | `slugOrPath` | `WorkReadResult` |
| `sai_work_patch_frontmatter` | `slugOrPath`, `patch`; optional `expectedBaseHash`, `operationId` | `WorkResult` |
| `sai_work_check_criterion` | `slugOrPath`, `criterionId`, `checked`; optional `expectedBaseHash`, `operationId` | `WorkResult` |
| `sai_learning_append` | `operationId`, `category`, `summary`, `host.name`; optional `host.sessionId`, `workSlug`, `content`, `metadata` | `{ appended: boolean, record: LearningRecord }` |
| `sai_context_pack` | `task`; optional `workspace`, `host`, `maxFiles`, `maxChars`, `allowSensitive`, `sensitiveScopes`, `includeRealPaths` | `ContextPackResult` |
| `sai_status` | no required fields; optional `includeRoots`, `includeFeatureFlags` | `{ roots?: SaiRoots, writable: boolean, features: Record<string, boolean> }` |

Resource URIs:

| Resource | Contract |
| --- | --- |
| `sai://status` | Read-only status JSON; no mutation. |
| `sai://work` | Read-only work registry projection; no PRD mutation. |
| `sai://user/context` | Router index only: lists available `CONTEXT.md` routers, sensitive scope labels, and suggested `sai_context_pack` request fields. It does not return task-specific file content. |

Representative JSON Schema fragments:

```ts
const HostSchema = {
  type: "object",
  required: ["name"],
  additionalProperties: false,
  properties: {
    name: { type: "string", minLength: 1 },
    sessionId: { type: "string" },
    model: { type: "string" },
    pid: { type: "number" }
  }
};

const WorkPatchSchema = {
  type: "object",
  required: ["slugOrPath", "patch"],
  additionalProperties: false,
  properties: {
    slugOrPath: { type: "string", minLength: 1 },
    patch: {
      type: "object",
      additionalProperties: false,
      properties: {
        phase: { type: "string" },
        progress: { type: "number" },
        mode: { type: "string" },
        updated: { type: "string" },
        updatedAt: { type: "string" },
        iteration: { type: "number" },
        status: { type: "string" },
        loopStatus: { type: "string" },
        verification_summary: { type: "string" },
        last_phase: { type: "string" },
        failing_criteria: { type: "array", items: { type: "string" } },
        maxIterations: { type: "number" }
      }
    },
    expectedBaseHash: { type: "string" },
    operationId: { type: "string" }
  }
};

const ContextPackSchema = {
  type: "object",
  required: ["task"],
  additionalProperties: false,
  properties: {
    task: { type: "string", minLength: 1 },
    workspace: { type: "string" },
    host: HostSchema,
    maxFiles: { type: "number", minimum: 1, maximum: 50 },
    maxChars: { type: "number", minimum: 1000, maximum: 200000 },
    allowSensitive: { type: "boolean" },
    sensitiveScopes: {
      type: "array",
      items: { enum: ["TELOS", "WORK", "BUSINESS"] }
    },
    includeRealPaths: { type: "boolean" }
  }
};
```

### Context Pack Result

```json
{
  "schemaVersion": "sai.context-pack.v1",
  "request": {
    "task": "write launch copy",
    "workspace": "MARKETING",
    "allowSensitive": false,
    "sensitiveScopes": []
  },
  "userRootDisplay": "SAI/USER",
  "selectedFiles": [
    {
      "displayPath": "SAI/USER/MARKETING/BrandVoice.md",
      "rootRelativePath": "MARKETING/BrandVoice.md",
      "reason": "voice rules for marketing copy",
      "content": "...",
      "bytes": 1234
    }
  ],
  "skippedFiles": [
    {
      "displayPath": "SAI/USER/TELOS/GOALS.md",
      "rootRelativePath": "TELOS/GOALS.md",
      "reason": "sensitive-denied"
    }
  ],
  "warnings": []
}
```

## Phase 1: Boundary Hardening Before New Surfaces

### Overview

Pin the boundary hardening already present in this checkout, then strengthen the remaining non-interference tests before adding new cross-LLM entry points.

### Changes Required

#### 1. Force Ultimate Bridge Delegation To TypeScript

**File**: `vendor/ultimate_mcp_server/ultimate_mcp_server/tools/silmari_compat.py`

**Changes**:
- Verify both tool and resource delegation already use unconditional `env["SILMARI_MCP_BACKEND"] = "typescript"`.
- Keep the existing vendor unit tests green.
- Add or retain an inline comment explaining that the compatibility oracle must not inherit `ultimate`.

#### 2. Route ThinkWithMemory State Through `SAI_DIR`

**File**: `SAI/hooks/ThinkWithMemory.hook.ts`

**Changes**:
- Verify it already imports `saiPath` from `SAI/hooks/lib/paths.ts`.
- Keep `saiPath('MEMORY', 'STATE', 'think-with-memory')` as the only hook state directory.
- Pin `SAI/hooks/tests/think-with-memory-sai-dir.test.ts` in the focused test list.

#### 3. Strengthen SAI Non-Interference Tests

**File**: `apps/silmari-mcp/tests/sai-compat-noninterference.test.ts`

**Changes**:
- Create temp `SAI_DIR`, including:
  - `MEMORY/WORK/20260429-test/PRD.md`
  - `MEMORY/STATE/work.json`
  - `MEMORY/STATE/current-work.json`
  - `MEMORY/STATE/events.jsonl`
  - `MEMORY/LEARNING/ALGORITHM/2026-04/baseline.md`
- Call one read-only Silmari tool and one temp-store write Silmari tool.
- Assert all temp SAI files are byte-identical before/after.
- Assert Silmari wrote only inside temp `SILMARI_DIR`.

#### 4. Add Recursion Regression Test

**File**: `apps/silmari-mcp/tests/ultimate-bridge-backend-boundary.test.ts`

**Changes**:
- Run `silmari --backend ultimate tool zk_status '{}'` with `SILMARI_MCP_BACKEND=ultimate`.
- Stub or inspect the Python bridge path so the delegated child command receives `SILMARI_MCP_BACKEND=typescript`.

### Success Criteria

#### Automated Verification

- [ ] Focused hook tests pass: `bun test SAI/hooks/tests/think-with-memory.test.ts SAI/hooks/tests/think-with-memory-silmari-client.test.ts SAI/hooks/tests/think-with-memory-sai-dir.test.ts`
- [ ] Silmari compatibility tests pass: `bun test apps/silmari-mcp/tests/sai-compat-noninterference.test.ts apps/silmari-mcp/tests/ultimate-bridge-backend-boundary.test.ts`
- [ ] Vendor focused tests pass: `cd vendor/ultimate_mcp_server && UV_PYTHON=3.13 uv run pytest -o addopts='' --confcutdir=tests/unit tests/unit/test_silmari_compat.py`
- [ ] TypeScript typecheck passes: `bun run --filter @silmari/mcp typecheck`

#### Manual Verification

- [ ] A manual Ultimate-backed `zk_status` call does not recursively spawn Ultimate.
- [ ] `SAI_DIR=/tmp/sai-test` causes ThinkWithMemory state to land under `/tmp/sai-test/MEMORY/STATE/think-with-memory`.

## Phase 2: Create `packages/sai-persistence`

### Overview

Extract SAI persistence into a host-neutral library shared by Claude Code hooks, CLI tools, and the new `sai` MCP server.

### Changes Required

#### 1. Package Scaffold

**Files**:

```text
packages/sai-persistence/package.json
packages/sai-persistence/tsconfig.json
packages/sai-persistence/src/index.ts
packages/sai-persistence/src/types.ts
packages/sai-persistence/src/paths.ts
packages/sai-persistence/src/lock.ts
packages/sai-persistence/src/atomic.ts
packages/sai-persistence/src/events.ts
packages/sai-persistence/src/sessions.ts
packages/sai-persistence/src/prd.ts
packages/sai-persistence/src/work-registry.ts
packages/sai-persistence/src/learning.ts
packages/sai-persistence/src/context-pack.ts
packages/sai-persistence/tests/*.test.ts
```

**Changes**:
- Add package named `@sai/persistence`.
- Use only Bun/Node standard APIs plus existing root `yaml` dependency if frontmatter parsing needs it.
- Export pure functions with explicit `SaiPersistenceOptions` so tests can pass temp roots without mutating process env.
- Define all interfaces from the Package Interface Appendix before hook/MCP integration starts.

#### 2. Path Resolver

**File**: `packages/sai-persistence/src/paths.ts`

**Contract**:

```ts
export interface SaiRoots {
  saiDir: string;
  userDir: string;
  memoryDir: string;
  workDir: string;
  stateDir: string;
  learningDir: string;
  eventsPath: string;
  operationIndexPath: string;
  workRegistryPath: string;
  sessionsPath: string;
}

export function resolveSaiRoots(env?: Record<string, string | undefined>): SaiRoots;
export function assertInsideMemoryRoot(roots: SaiRoots, path: string): string;
export function assertInsideUserRoot(roots: SaiRoots, path: string): string;
```

Rules:
- `SAI_DIR` defaults to `~/.claude`.
- `SAI_USER_DIR` defaults to `${SAI_DIR}/SAI-USER` if that path exists, otherwise `${SAI_DIR}/SAI/USER`; the resolver does not create either directory.
- Memory writes must pass `assertInsideMemoryRoot`.
- USER context reads and router writes must pass `assertInsideUserRoot`.
- `SAI_USER_DIR` may be outside `SAI_DIR`.
- No package function should call `homedir()` directly except this resolver.
- Existing paths use `realpath` checks before symlink-sensitive reads/writes; non-existent write targets validate the nearest existing parent and normalized final path.

#### 3. Lock And Idempotency Helpers

**File**: `packages/sai-persistence/src/lock.ts`

**Contract**:

```ts
export async function withSaiLock<T>(
  roots: SaiRoots,
  lockName: string,
  fn: () => Promise<T> | T,
  opts?: { timeoutMs?: number; staleMs?: number },
): Promise<T>;
```

Rules:
- Use atomic `mkdir` lock directories under `MEMORY/STATE/.locks/`.
- Write lock owner metadata for debugging: `host`, `pid`, `createdAt`, `lockName`, and optional `operationId`.
- Release locks in `finally`, including when the callback throws.
- Stale lock cleanup must require age greater than `staleMs`.
- Tests must cover parallel attempts, timeout, stale cleanup, callback throw cleanup, and owner metadata.

#### 4. Event Log

**File**: `packages/sai-persistence/src/events.ts`

**Contract**:

```ts
export function normalizeLifecycleEvent(input: unknown): SaiLifecycleEvent;
export async function appendLifecycleEvent(
  input: unknown,
  opts?: SaiPersistenceOptions,
): Promise<{ appended: boolean; duplicate?: boolean; event: SaiLifecycleEvent }>;
```

Rules:
- Validate `schemaVersion`, `operationId`, `host.name`, `host.sessionId`, `type`, and `timestamp`; accept `eventType`/`occurredAt` as input aliases only.
- Persist legacy-compatible `timestamp`, `session_id`, `source`, and `type` fields.
- Append exactly one JSON line to `MEMORY/STATE/events.jsonl`.
- Maintain an idempotency index under `MEMORY/STATE/operation-index.json`.
- Repeated `operationId` with identical canonical event hash returns `appended: false`.
- Repeated `operationId` with a different canonical event hash throws `SaiOperationConflictError`.
- If event/index writes are inconsistent, repair missing index entries from JSONL when possible and throw `SaiEventIndexCorruptError` when an index points at a missing event line.

#### 5. PRD And Work Registry

**Files**:
- `packages/sai-persistence/src/prd.ts`
- `packages/sai-persistence/src/work-registry.ts`
- `packages/sai-persistence/src/sessions.ts`

**Contract**:

```ts
export function parsePrd(content: string): ParsedPrd;
export function renderPrd(prd: ParsedPrd): string;
export async function createWork(input: CreateWorkInput, opts?: SaiPersistenceOptions): Promise<WorkResult>;
export async function readWork(slugOrPath: string, opts?: SaiPersistenceOptions): Promise<WorkReadResult>;
export async function patchWorkFrontmatter(input: PatchFrontmatterInput, opts?: SaiPersistenceOptions): Promise<WorkResult>;
export async function setCriterionChecked(input: CriterionPatchInput, opts?: SaiPersistenceOptions): Promise<WorkResult>;
export async function syncWorkRegistry(prdPath: string, opts?: SaiPersistenceOptions): Promise<WorkRegistryResult>;
```

Rules:
- PRD remains canonical; `work.json` is derived.
- Only allow safe frontmatter fields in `patchWorkFrontmatter`: `phase`, `progress`, `mode`, `updated`, `updatedAt`, `iteration`, `status`, `loopStatus`, `verification_summary`, `last_phase`, `failing_criteria`, and `maxIterations`.
- Accept lean PRD frontmatter, v4 template frontmatter, and Algorithm CLI frontmatter; preserve unknown fields.
- Preserve current `work.json` compatibility: top-level `sessions` map and existing `WorkSession` fields.
- Before mutating a PRD, compare `expectedBaseHash` when provided and reject stale writes with `SaiConflictError`.
- Read PRD/mtime/hash before and after lock acquisition; reject if the content changed while waiting for the lock.
- Atomic writes use temp file plus rename.
- Criteria parsing must preserve unrelated body content exactly.
- Every mutating operation writes PRD first, syncs `work.json` second, and appends a lifecycle event third with the caller-provided or generated `operationId`.

#### 6. Learning Records

**File**: `packages/sai-persistence/src/learning.ts`

**Contract**:

```ts
export async function appendLearningRecord(
  input: LearningRecord,
  opts?: SaiPersistenceOptions,
): Promise<{ appended: boolean; record: LearningRecord }>;
```

Rules:
- Validate `schemaVersion`, `operationId`, `category`, `timestamp`, `host.name`, and `summary`.
- Bound `summary` and `content` sizes before write.
- Route category writes under `MEMORY/LEARNING/<CATEGORY>/YYYY-MM/`.
- Use operation ID idempotency and emit `learning.appended` lifecycle events.

#### 7. USER Context Pack Builder

**File**: `packages/sai-persistence/src/context-pack.ts`

**Contract**:

```ts
export async function buildUserContextPack(
  input: ContextPackRequest,
  opts?: SaiPersistenceOptions,
): Promise<ContextPackResult>;
```

Rules:
- Prefer `CONTEXT.md` routers over scanning all files.
- Return bounded content; default max 20 files and 80k chars total.
- Never load `TELOS/`, `BUSINESS/`, or `WORK/` sensitive files unless task routing explicitly selects them and the request has `allowSensitive: true` plus matching `sensitiveScopes`.
- Never include `.git/`, lock files, node modules, package lock files, binary files, sockets, FIFOs, device files, or paths that realpath outside `userDir`.
- Return `displayPath` and `rootRelativePath`; hide absolute real paths unless `includeRealPaths: true`.
- Append `context.pack.sensitive` audit events for sensitive inclusions.
- Include `selectedFiles`, `skippedFiles`, and `warnings`.

### Success Criteria

#### Automated Verification

- [ ] Package tests pass: `bun test packages/sai-persistence/tests`
- [ ] Package typecheck passes: `bun run --filter @sai/persistence typecheck`
- [ ] Path tests prove `SAI_DIR` and `SAI_USER_DIR` overrides work.
- [ ] Lock tests prove concurrent PRD writes serialize.
- [ ] Event tests prove `events.jsonl` append is idempotent, append-only, legacy-compatible, and rejects mismatched duplicate operation IDs.
- [ ] PRD tests prove frontmatter and ISC edits preserve unrelated content and reject stale `expectedBaseHash`.
- [ ] Work registry tests prove current `sessions[slug]` shape remains backward-compatible.
- [ ] Learning tests prove bounded records write under temp `MEMORY/LEARNING` and emit events.
- [ ] Context-pack tests prove routing is bounded, skips sensitive directories by default, rejects symlink escapes, and audits authorized sensitive inclusions.

#### Manual Verification

- [ ] A temp `SAI_DIR` can create/read/update one PRD without touching `~/.claude`.
- [ ] A context pack for "write launch copy" selects marketing assets but skips Telos.

## Phase 3: Refactor Claude Code Hooks To Use The Shared Library

### Overview

Make Claude Code one host adapter, not the persistence implementation.

### Changes Required

#### 1. Add Writer Inventory Static Guard

**File**: `SAI/hooks/tests/sai-writer-inventory.test.ts`

**Changes**:
- Encode the SAI Writer Inventory table as test data.
- For every `included` writer, scan for non-allowlisted direct SAI write roots: `homedir()`, `os.homedir()`, `process.env.SAI_DIR ||`, literal `.claude`, and manually assembled `MEMORY/WORK`, `MEMORY/STATE`, or `MEMORY/LEARNING` write paths.
- Allow direct path construction only inside shared resolver modules, read-only classifications, or clearly documented non-SAI external command invocations.
- Fail the test when a new writer file appears without an inventory classification.

#### 2. Replace `SAI/hooks/lib/prd-utils.ts` Internals

**File**: `SAI/hooks/lib/prd-utils.ts`

**Changes**:
- Keep exported function names for backward compatibility.
- Delegate path resolution, PRD parsing, registry reads/writes, and sync logic to `@sai/persistence`.
- Remove duplicate path constants where possible.
- Preserve current `work.json` `sessions[slug]` output exactly, including `sessionName`, `phaseHistory`, `iteration`, and native/starting session fields where present.

#### 3. Update PRDSync

**File**: `SAI/hooks/PRDSync.hook.ts`

**Changes**:
- Continue to trigger only on `MEMORY/WORK/**/PRD.md`.
- Call `syncWorkRegistry`.
- Append `prd.synced` event through the shared event API.
- Preserve existing phase voice behavior and ISC gate warning.

#### 4. Update Session, Work, Learning, And State Writers

**Files**:
- `SAI/hooks/SessionAutoName.hook.ts`
- `SAI/hooks/SessionCleanup.hook.ts`
- `SAI/hooks/WorkCompletionLearning.hook.ts`
- `SAI/hooks/RatingCapture.hook.ts`
- `SAI/hooks/RelationshipMemory.hook.ts`
- `SAI/hooks/LastResponseCache.hook.ts`
- `SAI/hooks/ChecklistStateInjector.hook.ts`
- `SAI/hooks/ChecklistEnforcer.hook.ts`
- `SAI/hooks/handlers/VoiceNotification.ts`
- `SAI/hooks/handlers/SystemIntegrity.ts`
- `SAI/hooks/handlers/DocCrossRefIntegrity.ts`
- `SAI/hooks/handlers/UpdateCounts.ts`
- `SAI/hooks/handlers/tab-setter.ts`

**Changes**:
- Route work/session registry writes through `@sai/persistence` where contracts overlap.
- Route learning writes through `appendLearningRecord`.
- Route state/cache/checklist writes through shared memory-root helpers or add a documented read-only classification if no SAI write exists.
- Leave hook-specific behavior such as voice, tab color, and transcript parsing in hooks.
- Add temp-root fixture coverage for every file that writes SAI state.

#### 5. Update ThinkWithMemory Path Handling

**File**: `SAI/hooks/ThinkWithMemory.hook.ts`

**Changes**:
- Use shared path resolver for state directory.
- Keep recall behavior separate; it reads Silmari and writes hook-owned SAI state.
- Preserve existing `saiPath` behavior while moving the underlying resolver to `@sai/persistence`.

#### 6. Guard Algorithm PRD Writes

**File**: `SAI/Tools/algorithm.ts`

**Changes**:
- Prefer routing PRD/frontmatter/session-name mutations through `@sai/persistence`.
- If a full refactor is too large for this slice, add conflict detection before package writes and add a tracked follow-up issue for remaining direct Algorithm mutations.
- Tests must prove package PRD writes reject stale changes made through the Algorithm path.

### Success Criteria

#### Automated Verification

- [ ] Hook tests pass: `bun test SAI/hooks/tests`
- [ ] PRDSync temp-root test proves `SAI_DIR` controls `work.json`.
- [ ] Writer inventory static guard passes and covers every included writer row.
- [ ] Existing SessionAutoName behavior remains green or gains focused tests if missing.
- [ ] Event log tests prove hooks append events without truncating existing lines.
- [ ] Learning, checklist, cache, relationship, and rating writers either route through the package or have documented read-only classifications.
- [ ] Algorithm/direct PRD conflict test rejects stale package writes.

#### Manual Verification

- [ ] Claude Code still updates `MEMORY/STATE/work.json` after editing a PRD.
- [ ] Statusline/session naming behavior remains unchanged in a normal Claude Code session.

## Phase 4: Add The `sai` MCP Server And CLI

### Overview

Expose the shared SAI persistence library to any MCP-capable LLM host through a separate server namespace.

### Changes Required

#### 1. New MCP App

**Files**:

```text
apps/sai-mcp/package.json
apps/sai-mcp/tsconfig.json
apps/sai-mcp/src/index.ts
apps/sai-mcp/src/cli.ts
apps/sai-mcp/tests/*.test.ts
```

**Changes**:
- Use `@modelcontextprotocol/sdk`, matching `apps/silmari-mcp`.
- Register tools listed in "SAI MCP Tool Surface".
- Register read-only resources:
  - `sai://status`
  - `sai://work`
  - `sai://user/context`
- Return MCP text JSON on success and `isError: true` on tool errors.
- Keep server name configurable but document default registration as `sai`.
- Publish explicit `inputSchema` for every `sai_*` tool using the schemas in Proposed Public Contracts.
- `sai://user/context` is a router index only; it must not return task-specific file content.
- Normalize every handler through shared `SaiToolSuccess<T>` and `SaiToolError` helpers.

#### 2. CLI Wrapper

**Files**:
- `apps/sai-mcp/src/cli.ts`
- optional shim `SAI/Tools/sai-persist.ts`
- `apps/sai-mcp/package.json`

**Commands**:

```text
sai-persist status
sai-persist event append <json>
sai-persist work create <json>
sai-persist work read <slug>
sai-persist work patch <slug> <json>
sai-persist work check <slug> <criterion-id> --checked true|false
sai-persist context pack <json>
```

Rules:
- `apps/sai-mcp/package.json` exposes a `bin` entry for `sai-persist`.
- `SAI/Tools/sai-persist.ts`, if added, imports and invokes the app CLI instead of duplicating command logic.
- Successful commands write `SaiToolSuccess<T>` JSON to stdout and exit `0`.
- Usage/schema errors write help to stderr and exit `2`.
- Runtime/tool errors write `SaiToolError` JSON to stderr and exit `1`.
- CLI tests cover stdout/stderr and exit codes.

#### 3. MCP Configuration Docs

**Files**:
- `SAI/CLI.md`
- `SAI/TOOLS.md`
- `SAI/MEMORYSYSTEM.md`
- `SAI/THEHOOKSYSTEM.md`

**Changes**:
- Document `sai` MCP as the cross-LLM SAI runtime surface.
- Explicitly contrast:
  - `silmari` MCP: durable knowledge memory.
  - `sai` MCP: work state, lifecycle events, context packs.
- Update event docs to state that persisted rows keep `timestamp`, `session_id`, `source`, and `type` for legacy compatibility.
- Add docs checks that grep for `sai://user/context` as a router index and `sai_context_pack` as the only task-specific context file API.

### Success Criteria

#### Automated Verification

- [ ] `bun test apps/sai-mcp/tests` passes.
- [ ] `bun run --filter @sai/mcp typecheck` passes.
- [ ] MCP tool list contains `sai_*` tools and no `zk_*` tools.
- [ ] Every `sai_*` tool publishes an input schema.
- [ ] `sai_event_append` writes one event line and dedupes repeated operation IDs.
- [ ] `sai_work_patch_frontmatter` updates PRD and derived `work.json`.
- [ ] `sai_context_pack` returns bounded selected files with skip reasons.
- [ ] `sai://user/context` returns only router index metadata, not selected file contents.
- [ ] CLI contract tests cover exit `0`, `1`, and `2`.

#### Manual Verification

- [ ] Register `sai` as an MCP server and call `mcp__sai__sai_status`.
- [ ] Register both `sai` and `silmari`; verify tool namespaces remain separate.

## Phase 5: Propagate Minimal USER Context Routing

### Overview

Convert the `workspace-blueprint` idea into a concise live USER routing layer.

### Changes Required

#### 1. Add Top-Level USER Router

**File**: `SAI/USER/CONTEXT.md`

**Purpose**:
- Route tasks to the right USER subdirectory.
- Tell agents what to load and what to skip.
- State that `README.md` is human-facing while `CONTEXT.md` is agent-facing.
- State that sensitive folders require explicit `allowSensitive` plus matching `sensitiveScopes` through `sai_context_pack`.

#### 2. Add Per-Directory Routers

**Files**:

```text
SAI/USER/MARKETING/CONTEXT.md
SAI/USER/WORK/CONTEXT.md
SAI/USER/PROJECTS/CONTEXT.md
SAI/USER/TELOS/CONTEXT.md
SAI/USER/BUSINESS/CONTEXT.md
SAI/USER/ACTIONS/CONTEXT.md
SAI/USER/PIPELINES/CONTEXT.md
SAI/USER/FLOWS/CONTEXT.md
SAI/USER/SKILLCUSTOMIZATIONS/CONTEXT.md
```

Rules:
- Keep each file short.
- Remove blueprint teaching comments from live files.
- For executable registries, route and explain only; do not redefine schemas already owned by `action.json`, pipeline YAML, or flow configs.
- For sensitive folders (`TELOS`, `WORK`, `BUSINESS`), include explicit "load only when asked or when task requires it" rules.
- Do not include absolute personal filesystem paths in router files.

#### 3. Add Idempotent Generator

**File**: `SAI/Tools/user-context-blueprint.ts`

**Commands**:

```text
bun SAI/Tools/user-context-blueprint.ts --dry-run
bun SAI/Tools/user-context-blueprint.ts --write
bun SAI/Tools/user-context-blueprint.ts --write --force
```

Rules:
- Default is dry-run.
- `--write` creates only missing `CONTEXT.md` files.
- `--force` requires a backup under `SAI/USER/.context-backups/<timestamp>/`.
- Generator must never copy `workspace-blueprint/claude-office-skills-ref` into live workspace folders.
- Resolve `SAI/USER` to `SAI_USER_DIR` and reject writes where the real parent path leaves `userDir`.
- Skip embedded `.git`, `node_modules`, lockfiles, binary files, sockets, FIFOs, device files, and symlink escapes.
- Dry-run output must show `displayPath`, `rootRelativePath`, mode, and whether a backup would be created.

### Success Criteria

#### Automated Verification

- [ ] Generator dry-run reports planned files without writing.
- [ ] Generator write creates missing files only.
- [ ] Generator force creates backups before overwrite.
- [ ] Context-pack tests can route marketing, projects, actions, and Telos tasks correctly.
- [ ] `find -L SAI/USER -path '*/.git/*'` is never included by context-pack output.
- [ ] Symlink escape tests prove generator writes and context-pack reads cannot leave `userDir`.
- [ ] Sensitive context-pack tests prove Telos/WORK/BUSINESS require authorization flags and emit audit events.

#### Manual Verification

- [ ] A human can read `SAI/USER/CONTEXT.md` and understand where to place new USER data.
- [ ] An LLM can request a marketing context pack without loading unrelated WORK or TELOS files.

## Phase 6: Cross-LLM Lifecycle Adapter Tests

### Overview

Prove that a non-Claude host can participate in SAI persistence without Claude Code hooks.

### Changes Required

#### 1. Host Fixture Tests

**Files**:

```text
apps/sai-mcp/tests/cross-llm-lifecycle.test.ts
packages/sai-persistence/tests/host-lifecycle.test.ts
```

**Scenarios**:
- Custom host calls `sai_session_start`.
- Host creates a work item.
- Host appends prompt/tool/result events.
- Host checks an ISC criterion.
- Host ends session.
- Resulting PRD, `work.json`, operation index, and `events.jsonl` are valid.
- Event rows include legacy `timestamp`, `session_id`, `source`, and `type`.
- Duplicate identical operation IDs dedupe and mismatched duplicate operation IDs fail.

#### 2. Dual-MCP Non-Interference Test

**File**: `apps/sai-mcp/tests/sai-silmari-separation.test.ts`

**Scenario**:
- Temp `SAI_DIR` and temp `SILMARI_DIR`.
- Call `sai_work_create`, `sai_event_append`, and `sai_context_pack`.
- Call `silmari tool zk_status '{}'` and one temp Silmari save.
- Assert:
  - SAI tools never write `SILMARI_DIR`.
  - Silmari tools never write `SAI_DIR/MEMORY`.
  - Both MCP servers can run in the same process environment.

#### 3. Direct Writer Conflict And Compatibility Tests

**Files**:

```text
packages/sai-persistence/tests/prd-conflict.test.ts
packages/sai-persistence/tests/work-registry-compat.test.ts
packages/sai-persistence/tests/legacy-event-compat.test.ts
SAI/hooks/tests/sai-writer-inventory.test.ts
```

**Scenarios**:
- A PRD changed outside the package after read but before patch rejects with `SaiConflictError`.
- `syncWorkRegistry` output matches the current `prd-utils` `sessions[slug]` fixture.
- Existing legacy event consumers can read new SAI lifecycle rows by `timestamp`, `session_id`, `source`, and `type`.
- Included SAI writer files fail the static guard until hardcoded write roots are removed or read-only allowlisted.

### Success Criteria

#### Automated Verification

- [ ] Cross-host lifecycle tests pass without invoking Claude Code.
- [ ] Dual-MCP non-interference tests pass.
- [ ] Direct-writer conflict, legacy-event compatibility, work-registry compatibility, and writer-inventory tests pass.
- [ ] Full focused suite passes:
  - `bun test packages/sai-persistence/tests`
  - `bun test apps/sai-mcp/tests`
  - `bun test apps/silmari-mcp/tests/sai-compat-noninterference.test.ts`
  - `bun test SAI/hooks/tests`

#### Manual Verification

- [ ] A non-Claude MCP client can create a SAI work item and append lifecycle events.
- [ ] Claude Code can still run its normal hooks after the refactor.

## Testing Strategy

### Unit Tests

- Path resolution and path traversal rejection.
- PRD frontmatter parsing/rendering.
- ISC check/uncheck preservation.
- Work registry sync from PRD.
- Work registry backward compatibility with current `sessions[slug]` shape.
- PRD conflict detection for direct external writes.
- Event envelope validation, legacy compatibility, duplicate mismatch handling, and idempotency.
- Lock acquisition, timeout, and stale cleanup.
- Context-pack routing, privacy skips, sensitive authorization, and symlink escape rejection.
- Learning record validation and bounded writes.
- SAI writer inventory static guard.
- Ultimate bridge backend override.

### Integration Tests

- Claude hook temp-root behavior.
- `sai` MCP tool calls against temp `SAI_DIR`.
- `silmari` and `sai` MCP non-interference with temp roots.
- USER context generator dry-run/write/backup.
- CLI stdout/stderr/exit-code contract.

### Manual Testing Steps

1. Run `SAI_DIR=/tmp/sai-demo sai-persist work create '{"task":"test cross llm work"}'`.
2. Run `SAI_DIR=/tmp/sai-demo sai-persist event append '{...}'`.
3. Register `sai` MCP and call `sai_context_pack` for a marketing task.
4. Register `silmari` MCP and call `zk_status`.
5. Confirm `/tmp/sai-demo/MEMORY` and temp `SILMARI_DIR` do not cross-write.
6. Run a normal Claude Code session and verify hooks still update `work.json`.

## Performance Considerations

- `sai_context_pack` must be bounded by file count and character count.
- Event append must be synchronous/atomic enough for durability but fast enough for prompt lifecycle use.
- Lock default timeout should be short for hooks and longer for explicit CLI/MCP work writes.
- Avoid scanning all USER files on every context request; read routers first, then selected files.
- Avoid loading the embedded `workspace-blueprint/claude-office-skills-ref/.git` tree.

## Migration Notes

1. Existing `SAI/hooks/lib/prd-utils.ts` exports remain during transition.
2. Existing `SAI/USER/README.md` files remain human docs.
3. New `CONTEXT.md` files are additive and can be regenerated.
4. Existing Claude Code settings continue to reference hooks through `${SAI_DIR}`.
5. No existing PRD format migration is required for the first slice; parser accepts lean, v4 template, and Algorithm frontmatter.
6. Existing Silmari stores require no migration.
7. Existing event consumers continue to read `timestamp`, `session_id`, `source`, and `type`.
8. Existing USER files are not modified unless the generator runs with `--write`; overwrites require `--force` and backups.

## Rollout Order

1. Apply Phase 1 boundary hardening.
2. Add `@sai/persistence` with tests and no hook changes.
3. Add writer inventory static guard before broad hook refactors.
4. Refactor one hook path at a time, starting with `PRDSync`, then session/work writers, then learning/cache/checklist writers, while keeping `ThinkWithMemory` pinned.
5. Add `apps/sai-mcp` and CLI after the package is stable.
6. Add USER context generator and routers.
7. Run cross-LLM lifecycle and dual-MCP non-interference tests.
8. Update docs and MCP config examples.

## Risks And Mitigations

| Risk | Mitigation |
| --- | --- |
| USER context leaks sensitive personal files | Default deny sensitive folders unless routed; context pack includes skip reasons. |
| Hook behavior regresses | Keep old exports and add temp-root hook tests before refactor. |
| Concurrent LLM hosts corrupt `work.json` | Serialize writes with `withSaiLock`, atomic rename, and direct-edit conflict detection. |
| Direct Algorithm or human PRD edits race package writes | Require PRD hash/mtime checks and reject stale package writes with `SaiConflictError`. |
| Duplicate lifecycle events on retries | Require `operationId`, maintain an operation index, dedupe identical events, and reject mismatched duplicates. |
| New event rows break legacy consumers | Persist legacy `timestamp`, `session_id`, `source`, and `type` fields in every row. |
| `SAI_USER_DIR` outside `SAI_DIR` is wrongly rejected | Use separate memory and USER root guards. |
| Symlinked USER tree leaks unrelated files | Realpath every selected file and deny paths outside `userDir`. |
| Public MCP/CLI clients infer incompatible schemas | Publish tool input schemas, success/error envelopes, and CLI exit-code contracts before handler implementation. |
| MCP namespace confusion | Register SAI tools only under `sai`; keep Silmari minimal. |
| Generated USER docs drift | Keep routers short and regenerate from templates; executable configs remain authoritative. |
| Package import path friction from SAI hooks | Use workspace package plus a compatibility wrapper in `SAI/hooks/lib/prd-utils.ts`. |

## References

- Source notes: `thoughts/searchable/shared/research/notes-on-ultimate-mcp.md`
- Applied review: `thoughts/searchable/shared/plans/2026-04-29-cross-llm-sai-persistence-and-user-context-routing-REVIEW.md`
- Existing Ultimate/Silmari plan: `thoughts/searchable/shared/plans/2026-04-28-silmari-agent-memory-xq6-tdd-ultimate-mcp-silmari-compatibility.md`
- Ultimate/Silmari research: `thoughts/searchable/shared/research/2026-04-28-ultimate-mcp-server-silmari-mcp-algorithm-contracts.md`
- SAI Algorithm router research: `thoughts/searchable/shared/research/2026-04-27-sai-algorithm-router-contracts.md`
- Silmari bridge: `vendor/ultimate_mcp_server/ultimate_mcp_server/tools/silmari_compat.py`
- Silmari CLI: `apps/silmari-mcp/src/cli.ts`
- SAI path helper: `SAI/hooks/lib/paths.ts`
- SAI PRD sync: `SAI/hooks/PRDSync.hook.ts`, `SAI/hooks/lib/prd-utils.ts`
- SAI memory contract: `SAI/MEMORYSYSTEM.md`
- SAI PRD contract: `SAI/PRDFORMAT.md`
- USER blueprint: `SAI/USER/workspace-blueprint/START-HERE.md`
