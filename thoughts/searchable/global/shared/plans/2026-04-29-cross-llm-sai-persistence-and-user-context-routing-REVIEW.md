---
date: 2026-04-29T10:49:21-04:00
reviewer: Codex
git_commit_reviewed: 7667fb1ee18007d1d692b1c99ca8e18e6dc729cb
branch: main
repository: silmari-agent-memory
topic: "Plan review: Cross-LLM SAI persistence and USER context routing"
tags: [review, plan-review, sai, mcp, persistence, user-context]
status: needs_major_revision
plan: thoughts/searchable/shared/plans/2026-04-29-cross-llm-sai-persistence-and-user-context-routing.md
---

# Plan Review Report: Cross-LLM SAI Persistence And USER Context Routing

## Review Summary

| Category | Status | Issues Found |
|----------|--------|--------------|
| Contracts | CRITICAL | 5 critical, 3 warnings |
| Interfaces | CRITICAL | 4 critical, 3 warnings |
| Promises | CRITICAL | 3 critical, 4 warnings |
| Data Models | CRITICAL | 4 critical, 3 warnings |
| APIs | CRITICAL | 3 critical, 3 warnings |

Approval status: **Needs Major Revision**. The plan has the right separation goal, but implementation should not start until the SAI writer boundary, event-log compatibility, PRD/work schema authority, context-pack privacy model, and MCP/CLI schemas are made explicit.

## Contract Review

### Well-Defined

- The top-level storage boundary is directionally correct: Silmari stays under `SILMARI_DIR`, SAI work/runtime state stays under `SAI_DIR/MEMORY`, and `sai_*` tools are excluded from the default Silmari MCP server (`2026-04-29-cross-llm-sai-persistence-and-user-context-routing.md:45`, `2026-04-29-cross-llm-sai-persistence-and-user-context-routing.md:56`, `apps/silmari-mcp/src/index.ts:108`).
- The TDD sequencing is sound in broad strokes: boundary tests first, package behavior next, hook refactor after package tests, MCP app after package coverage (`2026-04-29-cross-llm-sai-persistence-and-user-context-routing.md:111`).
- The Ultimate recursion fix is already represented in the checkout: both bridge paths force `SILMARI_MCP_BACKEND=typescript` (`vendor/ultimate_mcp_server/ultimate_mcp_server/tools/silmari_compat.py:153`, `vendor/ultimate_mcp_server/ultimate_mcp_server/tools/silmari_compat.py:176`) and unit tests assert that behavior (`vendor/ultimate_mcp_server/tests/unit/test_silmari_compat.py:22`, `vendor/ultimate_mcp_server/tests/unit/test_silmari_compat.py:41`).

### Missing or Unclear

- CRITICAL: The "every SAI writer" contract is not mapped to the live writer inventory. The desired end state says every SAI writer must resolve paths through one resolver (`2026-04-29-cross-llm-sai-persistence-and-user-context-routing.md:58`), but Phase 3 names only a subset of writers (`2026-04-29-cross-llm-sai-persistence-and-user-context-routing.md:522`). Current hooks still include direct or divergent write roots: `SessionAutoName` creates PRD stubs with `process.env.SAI_DIR || HOME/.claude` (`SAI/hooks/SessionAutoName.hook.ts:152`), `SessionCleanup` writes PRDs/session names from its own base constants (`SAI/hooks/SessionCleanup.hook.ts:41`), `WorkCompletionLearning` writes learning state from its own base constants (`SAI/hooks/WorkCompletionLearning.hook.ts:57`), and checklist hooks hardcode `homedir()/.claude` (`SAI/hooks/ChecklistStateInjector.hook.ts:59`, `SAI/hooks/ChecklistEnforcer.hook.ts:103`). Without an inventory and scope decision, tests can pass while the claimed boundary remains false.
- CRITICAL: The PRD writer authority changes, but the plan does not define the new authority contract. Existing PRD docs say the AI writes PRDs directly and hooks only read/sync (`SAI/PRDFORMAT.md:3`, `SAI/PRDFORMAT.md:120`), while the plan adds API/CLI/MCP work operations that create, patch, and check PRDs (`2026-04-29-cross-llm-sai-persistence-and-user-context-routing.md:466`). If direct Claude edits, `SAI/Tools/algorithm.ts`, and `sai_work_*` APIs all write the same PRD files, the plan needs a conflict/lock policy that covers non-package writers.
- CRITICAL: The proposed lifecycle event envelope is incompatible with the documented event log contract. The plan proposes `schemaVersion`, `operationId`, `host`, `eventType`, and `occurredAt` (`2026-04-29-cross-llm-sai-persistence-and-user-context-routing.md:220`), but current docs define `timestamp`, `session_id`, `source`, and `type` in `MEMORY/STATE/events.jsonl` (`SAI/MEMORYSYSTEM.md:220`, `SAI/THEHOOKSYSTEM.md:1290`). Existing docs also reference `hooks/lib/event-emitter.ts`, but that file is absent in `SAI/hooks/lib`. The plan must either version a new event stream or write backward-compatible event rows.
- CRITICAL: The root containment contract conflicts with `SAI_USER_DIR`. The plan says `SAI_USER_DIR` can override the user tree (`2026-04-29-cross-llm-sai-persistence-and-user-context-routing.md:413`) and also says every write target must be under `SAI_DIR` (`2026-04-29-cross-llm-sai-persistence-and-user-context-routing.md:127`, `2026-04-29-cross-llm-sai-persistence-and-user-context-routing.md:416`). Those cannot both be true if a host sets `SAI_USER_DIR` outside `SAI_DIR`. The contract needs separate roots: memory writes under `saiDir`, USER router writes under `userDir`, and no write outside the selected root for the operation.
- CRITICAL: USER context privacy is promised but not enforceable from the current plan. `SAI/USER` is a symlink to `/home/maceo/.claude/SAI-USER` (`SAI/USER`), and the blueprint contains an embedded `.git` tree when followed with `find -L` (`SAI/USER/workspace-blueprint/claude-office-skills-ref/.git/HEAD`). The plan says skip `.git`, binaries, and sensitive folders (`2026-04-29-cross-llm-sai-persistence-and-user-context-routing.md:498`), but does not define realpath/symlink traversal rules.
- WARNING: Phase 1 is stale against the working tree. `ThinkWithMemory` already uses `saiPath('MEMORY', 'STATE', 'think-with-memory')` (`SAI/hooks/ThinkWithMemory.hook.ts:43`, `SAI/hooks/ThinkWithMemory.hook.ts:47`) and already has a focused `SAI_DIR` test (`SAI/hooks/tests/think-with-memory-sai-dir.test.ts:22`). The plan should mark those items as existing coverage or narrow the remaining Phase 1 work.
- WARNING: The non-interference test description is partly stale. The current test already uses temp `SAI_DIR` and `SILMARI_DIR` (`apps/silmari-mcp/tests/sai-compat-noninterference.test.ts:19`, `apps/silmari-mcp/tests/sai-compat-noninterference.test.ts:45`), but it only calls `zk_reflect` and does not assert a Silmari write stays under temp `SILMARI_DIR` (`apps/silmari-mcp/tests/sai-compat-noninterference.test.ts:97`).
- WARNING: The plan treats absence of JSON Schema as absence of contracts (`2026-04-29-cross-llm-sai-persistence-and-user-context-routing.md:93`). SAI has prose/code contracts for PRDs, work registry, loop state, and event rows; the plan should cite those as non-JSON contract refs instead of leaving `schema_contract_refs` as fully `N/A`.

### Recommendations

- Add a SAI writer inventory table before Phase 2: each writer path, current root resolver, files written, whether included in this plan, and which test proves temp-root isolation.
- Amend the PRD authority model: either require all API/CLI/hook PRD writes to use `@sai/persistence`, or explicitly preserve direct PRD edits and add mtime/hash conflict detection for package writes.
- Add an event compatibility section: legacy row shape, new row shape, operation-index schema, dual-write/migration policy, and consumer expectations.
- Split `assertInsideSaiRoot` into operation-scoped guards, for example `assertInsideMemoryRoot(roots, path)` and `assertInsideUserRoot(roots, path)`.
- Define symlink policy for context packs and generator writes with `realpath` checks and explicit allow/deny behavior.

## Interface Review

### Well-Defined

- The plan names the core package modules and public functions for roots, locks, events, PRD/work registry, and context packs (`2026-04-29-cross-llm-sai-persistence-and-user-context-routing.md:370`, `2026-04-29-cross-llm-sai-persistence-and-user-context-routing.md:391`).
- The `sai` MCP server is correctly specified as a separate app and namespace, matching the existing `apps/silmari-mcp` pattern (`2026-04-29-cross-llm-sai-persistence-and-user-context-routing.md:582`, `apps/silmari-mcp/src/index.ts:891`).
- The CLI-first direction fits SAI's existing CLI architecture and root workspace package setup (`package.json:6`, `package.json:10`).

### Missing or Unclear

- CRITICAL: `SaiPersistenceOptions` and `SaiPersistenceContext` are both referenced but neither is defined. The plan says exports should accept `SaiPersistenceContext` (`2026-04-29-cross-llm-sai-persistence-and-user-context-routing.md:389`), while function signatures use `SaiPersistenceOptions` (`2026-04-29-cross-llm-sai-persistence-and-user-context-routing.md:448`, `2026-04-29-cross-llm-sai-persistence-and-user-context-routing.md:471`). The exact fields need to be specified: env, roots, host, operationId, clock, logger, lock timeout, stale timeout, and dry-run/write mode where relevant.
- CRITICAL: Work input/output interfaces are named but not defined. `CreateWorkInput`, `WorkResult`, `WorkReadResult`, `PatchFrontmatterInput`, `CriterionPatchInput`, and `WorkRegistryResult` appear in signatures (`2026-04-29-cross-llm-sai-persistence-and-user-context-routing.md:468`) without fields, required/optional semantics, slug rules, or error variants.
- CRITICAL: MCP tool input schemas are incomplete. The plan lists tool names and purposes (`2026-04-29-cross-llm-sai-persistence-and-user-context-routing.md:254`), but does not provide JSON Schema for requests/responses. Existing Silmari MCP tools publish explicit schemas in `TOOLS` (`apps/silmari-mcp/src/index.ts:108`); the new app should do the same for every `sai_*` tool before implementation starts.
- CRITICAL: `sai_learning_append` is part of the public tool surface (`2026-04-29-cross-llm-sai-persistence-and-user-context-routing.md:267`) and contract tag table (`2026-04-29-cross-llm-sai-persistence-and-user-context-routing.md:201`), but Phase 2 does not include `learning.ts`, a `LearningRecord` schema, or tests for `MEMORY/LEARNING` writes (`2026-04-29-cross-llm-sai-persistence-and-user-context-routing.md:370`).
- WARNING: `appendLifecycleEvent(input: SaiLifecycleEvent, ...)` does not match the validation promise. The behavior says unknown input is validated before mutation (`2026-04-29-cross-llm-sai-persistence-and-user-context-routing.md:129`), but the append signature accepts an already-normalized type (`2026-04-29-cross-llm-sai-persistence-and-user-context-routing.md:447`). Either make append accept `unknown` and normalize internally, or state that callers must call `normalizeLifecycleEvent`.
- WARNING: `SAI_USER_DIR` defaulting is ambiguous. "`SAI_USER_DIR` defaults to `${SAI_DIR}/SAI-USER` when present" does not say what existence check is performed or whether the resolver creates directories (`2026-04-29-cross-llm-sai-persistence-and-user-context-routing.md:413`).
- WARNING: CLI packaging is under-specified. The plan lists `sai-persist` commands (`2026-04-29-cross-llm-sai-persistence-and-user-context-routing.md:618`) but does not define package `bin`, root workspace script names, or whether `SAI/Tools/sai-persist.ts` is a shim over `apps/sai-mcp/src/cli.ts` or a second implementation.

### Recommendations

- Add a TypeScript interface appendix for every exported package type and every MCP tool request/response.
- Add `src/learning.ts` and `tests/learning.test.ts`, or remove `sai_learning_append` from the first public surface.
- Define `SaiPersistenceOptions` once and use that name consistently.
- Define MCP schemas in the plan using the existing `ToolDef` pattern from `apps/silmari-mcp/src/index.ts`.

## Promise Review

### Well-Defined

- The lock direction is appropriate: atomic `mkdir` lock directories under `MEMORY/STATE/.locks` are a good match for Bun/Node filesystem portability (`2026-04-29-cross-llm-sai-persistence-and-user-context-routing.md:419`).
- The plan correctly promises idempotent event appends by `operationId` and bounded context-pack output (`2026-04-29-cross-llm-sai-persistence-and-user-context-routing.md:454`, `2026-04-29-cross-llm-sai-persistence-and-user-context-routing.md:498`).
- The MCP namespace separation promise is clear: `sai` exposes `sai_*`, Silmari remains `zk_*` (`2026-04-29-cross-llm-sai-persistence-and-user-context-routing.md:60`, `2026-04-29-cross-llm-sai-persistence-and-user-context-routing.md:644`).

### Missing or Unclear

- CRITICAL: The locking promise does not cover existing direct writers. `withSaiLock` can serialize package calls (`2026-04-29-cross-llm-sai-persistence-and-user-context-routing.md:425`), but existing `PRDSync`, `SessionAutoName`, `SessionCleanup`, `WorkCompletionLearning`, and `SAI/Tools/algorithm.ts` currently write PRDs/state without that lock (`SAI/hooks/lib/prd-utils.ts:104`, `SAI/hooks/SessionAutoName.hook.ts:163`, `SAI/Tools/algorithm.ts:343`). Concurrent cross-LLM writes can still corrupt files unless these writers are refactored or guarded.
- CRITICAL: Duplicate `operationId` conflict behavior is undefined. The plan says repeated IDs return `appended: false` (`2026-04-29-cross-llm-sai-persistence-and-user-context-routing.md:458`), but does not say what happens if the second event has different `eventType`, `occurredAt`, or payload. Silent dedupe can hide data loss; rejection can break retry semantics. Pick one contract and test it.
- CRITICAL: Context-pack privacy promises do not define authorization or consent. Any MCP client with access to the `sai` server could call `sai_context_pack` and ask for USER files. The plan says sensitive folders are skipped unless explicitly selected (`2026-04-29-cross-llm-sai-persistence-and-user-context-routing.md:501`), but does not define who is allowed to explicitly select `TELOS`, `WORK`, or `BUSINESS`.
- WARNING: Lock cleanup promises need exact resource cleanup behavior. The plan says stale cleanup requires age greater than `staleMs` (`2026-04-29-cross-llm-sai-persistence-and-user-context-routing.md:435`) but does not require release in `finally`, owner metadata fields, orphan cleanup on process death, or behavior when the callback throws.
- WARNING: Event append atomicity is incomplete. Appending `events.jsonl` and updating `operation-index.json` are two writes (`2026-04-29-cross-llm-sai-persistence-and-user-context-routing.md:456`). The plan needs a failure recovery promise for "event appended but index update failed" and "index written but append failed".
- WARNING: MCP/CLI timeout and cancellation behavior is not specified. Hooks are latency-sensitive and existing hook docs emphasize timeouts/non-blocking behavior; package and MCP calls need default timeouts per caller class.
- WARNING: Ordering guarantees for work/event writes are implicit. The plan should say whether `work.json` sync happens before or after event append, and what readers should expect after partial failure.

### Recommendations

- Add a "write serialization coverage" table that includes existing hook and Algorithm writers, not only new package functions.
- Define event dedupe as either "same `operationId` and identical event is idempotent, mismatched duplicate is an error" or "first write wins and mismatch is reported with a warning field."
- Add auth/selection rules for sensitive context pack categories, even if they are local-only: caller identity, explicit request fields, and audit event.
- Specify lock cleanup and two-file event/index recovery behavior.

## Data Model Review

### Well-Defined

- The existing work registry projection is discoverable and should be preserved: `syncToWorkJson` writes `sessions[slug]` with PRD path, task, session UUID/name, phase, progress, effort, mode, started/updated timestamps, criteria, phase history, and iteration (`SAI/hooks/lib/prd-utils.ts:170`).
- The existing Algorithm PRD model is concrete in code: `SAI/Tools/algorithm.ts` expects `prd`, `id`, `status`, `mode`, `effort_level`, `iteration`, `maxIterations`, `loopStatus`, `last_phase`, `failing_criteria`, and `verification_summary` (`SAI/Tools/algorithm.ts:58`).
- The context-pack result sketch includes useful observability fields: selected files, skipped files, reasons, bytes, and warnings (`2026-04-29-cross-llm-sai-persistence-and-user-context-routing.md:271`).

### Missing or Unclear

- CRITICAL: The plan does not define a `work.json` schema compatible with current consumers. Existing `prd-utils` writes a specific `sessions` map (`SAI/hooks/lib/prd-utils.ts:170`), while the plan names `WorkRegistryResult` but gives no field schema (`2026-04-29-cross-llm-sai-persistence-and-user-context-routing.md:475`). A new registry writer can accidentally drop `sessionName`, `phaseHistory`, or native/starting session entries.
- CRITICAL: PRD schema authority is inconsistent. `SAI/PRDFORMAT.md` documents an eight-field lean schema (`SAI/PRDFORMAT.md:6`), `SAI/hooks/lib/prd-template.ts` emits the broader v4 schema (`SAI/hooks/lib/prd-template.ts:135`), and `SAI/Tools/algorithm.ts` reads the broader Algorithm CLI schema (`SAI/Tools/algorithm.ts:58`). The plan's safe patch fields include both styles (`phase`, `progress`, `status`, `loopStatus`, `verification_summary`) without choosing an authority (`2026-04-29-cross-llm-sai-persistence-and-user-context-routing.md:480`).
- CRITICAL: Event-related data models are incomplete. `SaiLifecycleEvent`, `operation-index.json`, session records, and lifecycle payloads are not defined beyond a loose JSON example (`2026-04-29-cross-llm-sai-persistence-and-user-context-routing.md:220`). The operation index needs a schema with at least operation ID, event hash, event line offset or timestamp, and duplicate status.
- CRITICAL: Context-pack path model is unsafe as sketched. The result example returns repo-style `SAI/USER/...` paths (`2026-04-29-cross-llm-sai-persistence-and-user-context-routing.md:281`), but the live user root is symlinked outside the repo. The data model must say whether paths are display paths, root-relative paths, or real paths, and it must never expose unintended absolute personal paths unless deliberately configured.
- WARNING: `parsePrd` / `renderPrd` preservation is under-specified. The plan says unrelated body content is byte-preserved (`2026-04-29-cross-llm-sai-persistence-and-user-context-routing.md:482`), but it does not say whether YAML comments, field order, quoting, blank lines, or newline style in frontmatter are preserved.
- WARNING: Learning records are not modeled. `sai_learning_append` writes to `MEMORY/LEARNING`, but the plan does not define category, filename, dedupe key, retention, payload size, or relationship to existing `WorkCompletionLearning` output (`SAI/hooks/WorkCompletionLearning.hook.ts:184`).
- WARNING: Resource and schema IDs are proposed-only, which is acceptable, but the plan should still define local structural schemas so implementers are not forced to infer them.

### Recommendations

- Add schemas for `WorkRegistry`, `WorkSession`, `SaiLifecycleEvent`, `OperationIndex`, `SaiSessionRecord`, `LearningRecord`, `ContextPackRequest`, and `ContextPackResult`.
- Pick a PRD schema authority for the first implementation slice. If the broader Algorithm v4 schema is the real target, amend `SAI/PRDFORMAT.md` or explicitly state compatibility with both lean and v4 PRDs.
- Define root-relative path normalization for context packs and generator outputs.
- Make PRD rendering line-based unless the plan explicitly accepts YAML reserialization churn.

## API Review

### Well-Defined

- Keeping `sai` separate from `silmari` is the right public API boundary (`2026-04-29-cross-llm-sai-persistence-and-user-context-routing.md:254`, `apps/silmari-mcp/src/index.ts:447`).
- Returning MCP text JSON and `isError: true` follows the existing Silmari server behavior (`2026-04-29-cross-llm-sai-persistence-and-user-context-routing.md:609`, `apps/silmari-mcp/src/index.ts:462`, `apps/silmari-mcp/src/index.ts:899`).
- The listed CLI commands cover the expected user workflows: status, event append, work create/read/patch/check, and context pack (`2026-04-29-cross-llm-sai-persistence-and-user-context-routing.md:620`).

### Missing or Unclear

- CRITICAL: Public MCP request/response contracts are not specified. The plan lists tools (`2026-04-29-cross-llm-sai-persistence-and-user-context-routing.md:258`) but does not provide schemas, examples, required fields, response fields, or error codes. Existing Silmari code makes those contracts concrete in `TOOLS` (`apps/silmari-mcp/src/index.ts:108`), and the new app needs equivalent detail.
- CRITICAL: `sai://user/context` is ambiguous as a resource. Context packs require a task/workspace request (`2026-04-29-cross-llm-sai-persistence-and-user-context-routing.md:271`), but MCP resources are read by URI. The plan must either remove that resource, make it a status/index resource only, or define URI templates/query conventions that MCP clients can call deterministically.
- CRITICAL: Authentication/authorization is not addressed for sensitive USER access. The API review checklist requires auth requirements to be clear; the current plan's only privacy guard is routing policy. For a local MCP server reading `SAI/USER`, the plan still needs a caller identity/explicit consent/audit contract for sensitive folder selection.
- WARNING: CLI error and exit behavior is missing. The Silmari CLI uses exit code 2 for usage errors and 1 for tool failures (`apps/silmari-mcp/src/cli.ts:187`, `apps/silmari-mcp/src/cli.ts:271`). `sai-persist` should define comparable behavior.
- WARNING: API versioning is implicit but not complete. Events and context packs have `schemaVersion` examples, but MCP tool names, resource URIs, work registry shape, and CLI JSON output do not have version/deprecation guidance.
- WARNING: Documentation updates list files but not exact sections or acceptance checks (`2026-04-29-cross-llm-sai-persistence-and-user-context-routing.md:630`). Given existing docs already conflict, the plan should require doc tests or grep assertions for core contract statements.

### Recommendations

- Add a "SAI MCP Tool Schemas" section with JSON Schema for each tool and exact response examples.
- Make `sai://user/context` a read-only index of available routers, and keep task-specific context retrieval as `sai_context_pack`.
- Add sensitive-context authorization fields, for example `allowSensitive: false | true`, `sensitiveScopes: string[]`, `host`, and an event audit.
- Define CLI exit codes and stdout/stderr formats.

## Critical Issues

1. **SAI writer boundary is not exhaustively scoped**
   - Impact: Implementation can claim `SAI_DIR` safety while several existing writers still bypass the shared resolver and lock.
   - Recommendation: Add a writer inventory and either refactor every included writer or narrow the desired end state.

2. **PRD authority and concurrency are undefined**
   - Impact: Direct PRD edits, Algorithm CLI writes, and new `sai_work_*` writes can race and corrupt PRD/work state.
   - Recommendation: Define a single mutation path or add conflict detection for non-package PRD writers.

3. **Lifecycle event contract conflicts with current event docs**
   - Impact: New events can break consumers expecting `timestamp`, `session_id`, `source`, and `type`, or silently create a parallel incompatible log.
   - Recommendation: Define a migration/compatibility policy and operation-index schema.

4. **`SAI_USER_DIR` and context-pack privacy contracts are unsafe**
   - Impact: A context pack can leak symlinked or sensitive USER files, and path guards can reject legitimate user roots.
   - Recommendation: Separate memory/user root guards, define realpath policy, and require explicit sensitive-context authorization.

5. **Work/PRD schemas are not concrete enough for implementation**
   - Impact: `work.json`, PRD frontmatter, and criteria parsing can drift from existing hook/Algorithm consumers.
   - Recommendation: Add exact schemas and choose lean PRD vs Algorithm v4 compatibility behavior before coding.

6. **Public MCP/CLI API schemas are incomplete**
   - Impact: Implementers will invent incompatible request/response/error shapes, and clients cannot be written against the plan.
   - Recommendation: Add JSON Schema and examples for every tool, resource, and CLI command.

## Suggested Plan Amendments

```diff
# Current State / Scope
+ Add: SAI writer inventory table covering hooks, Tools, and package functions.
+ Add: "Included in this plan" vs "known remaining writer" status for each path.
~ Modify: Phase 1 to mark already-fixed Ultimate backend and ThinkWithMemory SAI_DIR items as existing coverage.

# Path Contracts
~ Modify: assertInsideSaiRoot(root, path) -> assertInsideMemoryRoot(roots, path) and assertInsideUserRoot(roots, path).
+ Add: realpath/symlink traversal rules for context-pack reads and USER router writes.

# PRD / Work Authority
+ Add: explicit PRD mutation authority: package-only writes, or direct-edit compatibility with conflict detection.
+ Add: WorkRegistry and WorkSession schemas matching current work.json fields.
+ Add: PRD schema compatibility matrix: lean PRDFORMAT.md fields vs Algorithm v4/template fields.

# Events
~ Modify: Lifecycle envelope to either extend existing event rows or write to a versioned new stream.
+ Add: OperationIndex schema and duplicate-operation mismatch behavior.
+ Add: recovery promise for append succeeds/index fails and index succeeds/append fails.

# Package Interfaces
+ Add: SaiPersistenceOptions interface with env/roots/host/operationId/clock/logger/timeout fields.
+ Add: CreateWorkInput, WorkResult, WorkReadResult, PatchFrontmatterInput, CriterionPatchInput, WorkRegistryResult.
+ Add: LearningRecord and packages/sai-persistence/src/learning.ts, or remove sai_learning_append from first release.

# MCP / CLI API
+ Add: JSON Schema for every sai_* tool and exact JSON success/error examples.
~ Modify: sai://user/context as router index only; task-specific context stays sai_context_pack.
+ Add: sensitive USER access contract: allowSensitive flag, scopes, host identity, and audit event.
+ Add: CLI exit-code and stdout/stderr contract.

# Tests
+ Add: test that package locks cover or conflict-detect direct PRD writers.
+ Add: context-pack symlink escape and embedded .git exclusion tests.
+ Add: legacy event consumer compatibility test.
+ Add: work.json backward-compatibility fixture test using current prd-utils shape.
```

## Review Checklist

### Contracts

- [ ] Component boundaries are clearly defined
- [ ] Input/output contracts are specified
- [ ] Error contracts enumerate all failure modes
- [ ] Preconditions and postconditions are documented
- [ ] Invariants are identified

### Interfaces

- [ ] All public methods are defined with signatures
- [ ] Naming follows codebase conventions
- [ ] Interface matches existing patterns
- [ ] Extension points are considered
- [ ] Visibility modifiers are appropriate

### Promises

- [ ] Behavioral guarantees are documented
- [ ] Async operations have timeout/cancellation handling
- [ ] Resource cleanup is specified
- [ ] Idempotency requirements are addressed
- [ ] Ordering guarantees are documented where needed

### Data Models

- [ ] All fields have types
- [ ] Required vs optional is clear
- [ ] Relationships are documented
- [ ] Migration strategy is defined
- [ ] Serialization format is specified

### APIs

- [ ] All endpoints/commands are defined
- [ ] Request/response formats are specified
- [ ] Error responses are documented
- [ ] Authentication requirements are clear
- [ ] Versioning strategy is defined

## Approval Status

- [ ] Ready for Implementation
- [ ] Needs Minor Revision
- [x] Needs Major Revision
