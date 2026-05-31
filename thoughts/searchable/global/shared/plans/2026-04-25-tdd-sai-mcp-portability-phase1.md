---
date: 2026-04-25T15:24:22-04:00
planner: Codex
git_commit: 633e3293b0cb97b257d4bea001c0e669759214f8
branch: main
repository: silmari-agent-memory
topic: "TDD plan — SAI portability phase 1 via reusable MCP client, SessionProgress rewrite, and host-surface contract sync"
tags: [tdd, plan, sai, mcp, portability, claude-code, codex, gemini, session-progress]
related_research:
  - thoughts/searchable/shared/research/2026-04-25-sai-claude-codex-gemini-portability-research.md
status: ready
last_updated: 2026-04-25
last_updated_by: Codex
type: tdd_plan
---

# SAI MCP Portability Phase 1 — TDD Implementation Plan

## Overview

This plan takes the smallest concrete portability slice supported by the current repo state:

1. Extract a reusable local MCP client from the existing `apps/silmari-mcp/src/cli.ts` handshake path.
2. Rewrite `SAI/Tools/SessionProgress.ts` to consume that client instead of the deleted `zettel` CLI.
3. Add a contract-sync test for Claude-facing command/Algorithm docs so they stop drifting from the real `silmari-mcp` tool surface.

This is intentionally **not** a plan to make current SAI skills or hooks directly invocable over MCP. The research showed that the present MCP boundary is a Silmari domain API (`zk_*` tools), while skill activation, hook timing, `Skill(...)`, and `Task(...)` remain Claude-native runtime concerns.

## Current State Analysis

### Key Discoveries

- `apps/silmari-mcp/src/index.ts:101-400` and `apps/silmari-mcp/src/index.ts:498-776` expose the authoritative server surface: `zk_*` tools and static `silmari://` resources. There is no generic `run_skill`, `invoke_workflow`, or `run_hook` endpoint.
- `apps/silmari-mcp/src/index.ts:368-399` and `apps/silmari-mcp/src/index.ts:722-771` already define and dispatch `zk_recall_by_status` and `zk_promote`.
- `apps/silmari-mcp/tests/recall-promote.test.ts:1-199` already verifies those two tools against real `br`, using `bun:test` integration patterns that new portability work should follow.
- `apps/silmari-mcp/src/cli.ts:168-210` already contains a working local MCP client handshake, but it is trapped inside the CLI implementation and cannot be reused by SAI.
- `SAI/Tools/SessionProgress.ts:26-37` explicitly says card mirroring is disabled because the legacy `zettel` CLI was removed and the intended replacement is an MCP client rewrite.
- `SAI/Tools/SessionProgress.ts:56-129` still models the create/complete/blocker flows in terms of save/promote semantics, so the business behavior already matches the current MCP surface.
- `SAI/commands/silmari.md:71-74` and `SAI/Algorithm/v3.8.1.md:205-211`, `SAI/Algorithm/v3.8.1.md:272-276` still claim `zk_recall_by_status` and `zk_promote` are missing even though the server and tests say otherwise.
- `SAI/SKILLSYSTEM.md:177-199` and `SAI/SKILLSYSTEM.md:963-970` show that skill activation still depends on Claude Code parsing `USE WHEN`.
- `SAI/hooks/README.md:23-35`, `SAI/hooks/README.md:80-87`, and `SAI/hooks/ThinkWithMemory.hook.ts:3-15` show that hook execution remains tied to Claude lifecycle events and in-process hook behavior.

### Registry / Schema Reality Check

- The workflow asked for `specs/schemas/resource_registry.json`, but this repo does **not** contain `specs/schemas/resource_registry.json`, `schema/`, `schemas/`, or `specs/schemas/`.
- Because the canonical registry/schema tree is absent, every behavior below uses:
  - `resource_id: [PROPOSED]`
  - proposed `address_alias` values
  - `schema_contract_refs: N/A`
- The de facto runtime contract source in this repo is the TypeScript `inputSchema` definitions in `apps/silmari-mcp/src/index.ts`.

## Desired End State

- Provider-neutral Silmari operations are callable through one reusable local MCP client helper instead of ad hoc CLI-only transport code.
- `SessionProgress` again mirrors project lifecycle to Silmari memory using the live MCP surface: `zk_save_card` and `zk_promote`.
- The local JSON progress file remains fail-open and authoritative for session continuity when memory is unavailable.
- Claude-facing command and Algorithm docs stop advertising nonexistent gaps and are protected by a contract test so they cannot drift again unnoticed.
- The feature boundary is explicit:
  - MCP owns provider-neutral memory/state behavior.
  - Host runtimes own skill routing, hook timing, prompt injection, and other client-native concerns.

### Observable Behaviors

- Given a local stdio server path and a Silmari tool request, when the reusable client executes it, then the caller receives structured tool output or a structured transport/tool error without shelling to `zettel`.
- Given `session-progress create <project>` and healthy memory, when the project is created, then an `in_progress` card is written through `zk_save_card` and the returned `card_id` is persisted into the progress JSON.
- Given `session-progress complete <project>` with a mirrored `card_id`, when the project is completed, then `zk_promote` closes the mirrored card and the old dead `forget` fallback is removed.
- Given `session-progress blocker <project> <blocker>`, when a blocker is recorded, then a signal card is saved via MCP while local progress state still updates even if memory is unavailable.
- Given the authoritative `TOOLS` export includes `zk_recall_by_status` and `zk_promote`, when docs are validated, then `SAI/commands/silmari.md` and the active Algorithm file no longer describe them as missing.

## What We're NOT Doing

| Out of scope | Why |
|---|---|
| Making current `Skill(...)` workflows callable over MCP | The current repo has no MCP orchestration surface for skills or hooks; planning that now would be speculative |
| Porting Claude lifecycle hooks to Codex/Gemini in this tranche | Hook timing remains host-runtime-specific; this phase is about extracting provider-neutral behavior only |
| Adding new Silmari domain tools | `zk_recall_by_status` and `zk_promote` already exist; this is a consumption and alignment phase |
| Building a full provider adapter framework for Claude/Codex/Gemini | Phase 1 only establishes the reusable MCP-consumption primitive and the first SAI consumer |
| Inventing a fake resource registry or schema tree | The repo does not contain the expected canonical files; the plan records that gap explicitly |

## Testing Strategy

- **Frameworks**
  - `bun:test` for `apps/silmari-mcp` tests, following existing integration patterns in `apps/silmari-mcp/tests/recall-promote.test.ts`
  - `bun test` on new SAI-side test files run directly from repo root
- **Test Types**
  - Unit tests for reusable client transport/error handling
  - Unit tests for `SessionProgress` request formation, persistence, and fail-open behavior
  - Contract tests for doc/tool-surface sync
  - Existing integration tests (`recall-promote.test.ts`) remain the server-side proof that the tool surface already exists
- **Execution Order**
  1. Reusable client extraction
  2. `SessionProgress` create path
  3. `SessionProgress` complete path
  4. `SessionProgress` blocker path
  5. Doc/tool-surface contract sync
- **Primary commands**
  - `bun test apps/silmari-mcp/tests/client.test.ts`
  - `bun test SAI/Tools/tests/session-progress.test.ts`
  - `bun test apps/silmari-mcp/tests/tool-surface-docs.test.ts`
  - `cd apps/silmari-mcp && bun test tests/recall-promote.test.ts`

---

## Behavior 1: Reusable local MCP client is extractable from the CLI handshake

### Resource Registry Binding
- `resource_id`: `[PROPOSED]`
- `address_alias`: `portability.mcp_client`
- `predicate_refs`: local stdio transport, optional `SILMARI_DIR`, tool/resource request kind
- `codepath_ref`: `apps/silmari-mcp/src/client.ts::callSilmariTool [PROPOSED]`, `apps/silmari-mcp/src/client.ts::readSilmariResource [PROPOSED]`, `apps/silmari-mcp/src/cli.ts::main`
- `schema_contract_refs`: `N/A` — no canonical schema tree exists; use `apps/silmari-mcp/src/index.ts::TOOLS[*].inputSchema`

### Schema Interface Mapping
- `loop_mode`: `summary`
- `mapped_contracts`: `N/A`
- `registry_updates`: `[PROPOSED] portability.mcp_client`

### Test Specification
**Given**: a tool or resource request plus a configurable `SILMARI_DIR`  
**When**: local code calls the extracted client helper  
**Then**: the helper opens a stdio MCP session, performs the request, closes cleanly, and returns structured success or failure to the caller

**Edge Cases**
- tool result with `isError: true`
- connection failure before ownership of the transport
- missing `SILMARI_DIR` uses default home-based path
- resource read returns empty text payload

### TDD Cycle

#### 🔴 Red: Write Failing Test
**File**: `apps/silmari-mcp/tests/client.test.ts`
```ts
import { describe, expect, it } from 'bun:test';
import { callSilmariTool } from '../src/client.js';

describe('callSilmariTool', () => {
  it('returns structured tool text on success', async () => {
    const result = await callSilmariTool('zk_status', {}, { silmariDir: '/tmp/silmari-test' });
    expect(result).toHaveProperty('cards');
  });

  it('surfaces tool errors as typed failures', async () => {
    await expect(callSilmariTool('zk_promote', { cardId: 'zk-missing' }))
      .rejects.toThrow(/cardId|reason|not found/);
  });
});
```

#### 🟢 Green: Minimal Implementation
**Files**:
- `apps/silmari-mcp/src/client.ts` (new)
- `apps/silmari-mcp/src/cli.ts`

```ts
export async function callSilmariTool(
  name: string,
  args: Record<string, unknown>,
  opts?: { silmariDir?: string },
): Promise<unknown> {
  // Minimal shared handshake extracted from cli.ts::runRequest.
}
```

**Documentation Contract (required for planned functions):**
```ts
/**
 * @rr.id [PROPOSED]
 * @rr.alias portability.mcp_client
 * @path.id silmari-call-tool
 * @gwt.given a local stdio Silmari MCP server path and tool request
 * @gwt.when the helper performs the MCP handshake and tool call
 * @gwt.then the caller receives parsed result text or a structured failure
 * @reads [PROPOSED]
 * @writes [PROPOSED]
 * @raises [PROPOSED]:SilmariClientError
 * @schema.contract N/A
 */
```

#### 🔵 Refactor: Improve Code
**Files**:
- `apps/silmari-mcp/src/client.ts`
- `apps/silmari-mcp/src/cli.ts`

Refactor goals:
- isolate transport creation from request dispatch
- reuse the same helper from `cli.ts` instead of duplicating handshake logic
- normalize parsed JSON/text behavior into one small API surface

### Success Criteria
**Automated:**
- [ ] Red: `bun test apps/silmari-mcp/tests/client.test.ts`
- [ ] Green: `bun test apps/silmari-mcp/tests/client.test.ts`
- [ ] Refactor: `cd apps/silmari-mcp && bun test`
- [ ] `cd apps/silmari-mcp && bun run typecheck`

**Manual:**
- [ ] `bun run apps/silmari-mcp/src/cli.ts status` still works against a temp store
- [ ] No `zettel` subprocess path is introduced

---

## Behavior 2: `session-progress create` mirrors active work through `zk_save_card`

### Resource Registry Binding
- `resource_id`: `[PROPOSED]`
- `address_alias`: `portability.session_progress_create`
- `predicate_refs`: no existing progress file, temp HOME/STATE path, healthy local MCP tool surface
- `codepath_ref`: `SAI/Tools/lib/session-progress-core.ts::createProgress [PROPOSED]`, `SAI/Tools/lib/session-progress-core.ts::mirrorCardOnCreate [PROPOSED]`
- `schema_contract_refs`: `N/A`

### Schema Interface Mapping
- `loop_mode`: `summary`
- `mapped_contracts`: `N/A`
- `registry_updates`: `[PROPOSED] portability.session_progress_create`

### Test Specification
**Given**: a new project name, objectives, and a successful `zk_save_card` response  
**When**: `createProgress` runs  
**Then**: the progress JSON is written locally, an `in_progress` Silmari card is created, and the returned `card_id` is persisted back into the JSON file

**Edge Cases**
- progress file already exists
- MCP save fails: local JSON still writes and command warns instead of aborting
- objectives list empty
- returned payload has no `id`

### TDD Cycle

#### 🔴 Red: Write Failing Test
**File**: `SAI/Tools/tests/session-progress.test.ts`
```ts
import { describe, expect, it } from 'bun:test';
import { createProgress } from '../lib/session-progress-core.js';

describe('createProgress', () => {
  it('persists card_id after zk_save_card succeeds', async () => {
    const calls: Array<{ name: string; args: Record<string, unknown> }> = [];
    const callTool = async (name: string, args: Record<string, unknown>) => {
      calls.push({ name, args });
      return { id: 'zk-test-123' };
    };

    const result = await createProgress('portable-sai', ['restore mirroring'], { callTool, homeDir: '/tmp/home' });

    expect(calls[0]?.name).toBe('zk_save_card');
    expect(result.card_id).toBe('zk-test-123');
  });
});
```

#### 🟢 Green: Minimal Implementation
**Files**:
- `SAI/Tools/lib/session-progress-core.ts` (new)
- `SAI/Tools/SessionProgress.ts`

```ts
export async function createProgress(
  project: string,
  objectives: string[],
  deps: SessionProgressDeps,
): Promise<SessionProgress> {
  // Minimal import-safe core that writes JSON first, then best-effort mirrors.
}
```

**Documentation Contract (required for planned functions):**
```ts
/**
 * @rr.id [PROPOSED]
 * @rr.alias portability.session_progress_create
 * @path.id session-progress-create
 * @gwt.given no prior progress file and a reachable local Silmari client
 * @gwt.when createProgress creates a new project record
 * @gwt.then zk_save_card is called with in_progress semantics and card_id is persisted
 * @reads [PROPOSED]
 * @writes [PROPOSED]
 * @raises [PROPOSED]:SessionProgressError
 * @schema.contract N/A
 */
```

#### 🔵 Refactor: Improve Code
**Files**:
- `SAI/Tools/lib/session-progress-core.ts`
- `SAI/Tools/SessionProgress.ts`

Refactor goals:
- move top-level CLI parsing behind `if (import.meta.main)`
- inject filesystem + MCP dependencies for deterministic tests
- remove direct transport logic from the CLI wrapper

### Success Criteria
**Automated:**
- [ ] Red: `bun test SAI/Tools/tests/session-progress.test.ts`
- [ ] Green: `bun test SAI/Tools/tests/session-progress.test.ts`
- [ ] Refactor: `bun test SAI/Tools/tests/session-progress.test.ts`

**Manual:**
- [ ] `bun run SAI/Tools/SessionProgress.ts create portable-sai "restore mirroring"` creates local progress JSON
- [ ] Healthy memory writes a mirrored `in_progress` card and persists `card_id`
- [ ] Unhealthy memory warns but does not abort project creation

---

## Behavior 3: `session-progress complete` closes mirrored work through `zk_promote`

### Resource Registry Binding
- `resource_id`: `[PROPOSED]`
- `address_alias`: `portability.session_progress_complete`
- `predicate_refs`: existing progress file, existing `card_id`, `status: active|blocked`
- `codepath_ref`: `SAI/Tools/lib/session-progress-core.ts::completeProgress [PROPOSED]`, `SAI/Tools/lib/session-progress-core.ts::mirrorCardOnComplete [PROPOSED]`
- `schema_contract_refs`: `N/A`

### Schema Interface Mapping
- `loop_mode`: `summary`
- `mapped_contracts`: `N/A`
- `registry_updates`: `[PROPOSED] portability.session_progress_complete`

### Test Specification
**Given**: a progress file with `card_id` and a healthy Silmari client  
**When**: `completeProgress` runs  
**Then**: local state becomes `completed`, `zk_promote` is called with `toStatus: 'closed'`, and the obsolete `forget` fallback is not used

**Edge Cases**
- missing `card_id` should stay local-only and not call MCP
- MCP failure should keep local `completed` status and emit a warning
- blocked card closing still uses `zk_promote`

### TDD Cycle

#### 🔴 Red: Write Failing Test
**File**: `SAI/Tools/tests/session-progress.test.ts`
```ts
it('uses zk_promote for completion and never falls back to forget', async () => {
  const calls: string[] = [];
  const callTool = async (name: string) => {
    calls.push(name);
    return { cardId: 'zk-test-123', toStatus: 'closed' };
  };

  await completeProgress('portable-sai', { callTool, homeDir: '/tmp/home' });

  expect(calls).toContain('zk_promote');
  expect(calls).not.toContain('forget');
});
```

#### 🟢 Green: Minimal Implementation
**Files**:
- `SAI/Tools/lib/session-progress-core.ts`

```ts
await callTool('zk_promote', {
  cardId: progress.card_id,
  toStatus: 'closed',
  reason: `session-progress complete: ${progress.project}`,
});
```

**Documentation Contract (required for planned functions):**
```ts
/**
 * @rr.id [PROPOSED]
 * @rr.alias portability.session_progress_complete
 * @path.id session-progress-complete
 * @gwt.given a persisted project with a mirrored Silmari card id
 * @gwt.when completeProgress finalizes the project
 * @gwt.then zk_promote closes the mirrored card and local state becomes completed
 * @reads [PROPOSED]
 * @writes [PROPOSED]
 * @raises [PROPOSED]:SessionProgressError
 * @schema.contract N/A
 */
```

#### 🔵 Refactor: Improve Code
**Files**:
- `SAI/Tools/lib/session-progress-core.ts`

Refactor goals:
- centralize warning/reporting for fail-open memory operations
- share one mirrored-card guard across create/complete/blocker paths

### Success Criteria
**Automated:**
- [ ] Red: `bun test SAI/Tools/tests/session-progress.test.ts`
- [ ] Green: `bun test SAI/Tools/tests/session-progress.test.ts`
- [ ] Refactor: `bun test SAI/Tools/tests/session-progress.test.ts`

**Manual:**
- [ ] `bun run SAI/Tools/SessionProgress.ts complete portable-sai` marks local JSON completed
- [ ] Mirrored card is closed when memory is healthy
- [ ] No `forget` CLI fallback remains in the codepath

---

## Behavior 4: `session-progress blocker` emits signal cards through MCP but stays fail-open

### Resource Registry Binding
- `resource_id`: `[PROPOSED]`
- `address_alias`: `portability.session_progress_blocker`
- `predicate_refs`: existing project, blocker text, optional mirrored `card_id`
- `codepath_ref`: `SAI/Tools/lib/session-progress-core.ts::addBlocker [PROPOSED]`, `SAI/Tools/lib/session-progress-core.ts::mirrorCardOnBlocker [PROPOSED]`
- `schema_contract_refs`: `N/A`

### Schema Interface Mapping
- `loop_mode`: `summary`
- `mapped_contracts`: `N/A`
- `registry_updates`: `[PROPOSED] portability.session_progress_blocker`

### Test Specification
**Given**: an existing progress file and blocker text  
**When**: `addBlocker` runs  
**Then**: local state becomes `blocked`, the blocker entry is persisted, and best-effort `zk_save_card` writes a signal card using the blocker text

**Edge Cases**
- no `card_id` yet: still save local blocker state
- MCP failure: still save local blocker state and emit warning
- repeated blockers append without overwriting earlier ones

### TDD Cycle

#### 🔴 Red: Write Failing Test
**File**: `SAI/Tools/tests/session-progress.test.ts`
```ts
it('records blocker locally and attempts MCP signal save', async () => {
  const calls: Array<{ name: string; args: Record<string, unknown> }> = [];
  const callTool = async (name: string, args: Record<string, unknown>) => {
    calls.push({ name, args });
    return { id: 'zk-blocker-1' };
  };

  const progress = await addBlocker('portable-sai', 'waiting on host adapter spec', { callTool, homeDir: '/tmp/home' });

  expect(progress.status).toBe('blocked');
  expect(calls[0]?.name).toBe('zk_save_card');
  expect(String(calls[0]?.args.body)).toContain('waiting on host adapter spec');
});
```

#### 🟢 Green: Minimal Implementation
**Files**:
- `SAI/Tools/lib/session-progress-core.ts`

```ts
await callTool('zk_save_card', {
  body: `[blocker] ${progress.project}: ${blocker}`,
  kind: 'signal',
  trunk: 5,
  source: `session-progress-${progress.project}-blocker`,
});
```

**Documentation Contract (required for planned functions):**
```ts
/**
 * @rr.id [PROPOSED]
 * @rr.alias portability.session_progress_blocker
 * @path.id session-progress-blocker
 * @gwt.given an existing progress record and blocker text
 * @gwt.when addBlocker persists the blocker
 * @gwt.then local state becomes blocked and a best-effort signal card is attempted
 * @reads [PROPOSED]
 * @writes [PROPOSED]
 * @raises [PROPOSED]:SessionProgressError
 * @schema.contract N/A
 */
```

#### 🔵 Refactor: Improve Code
**Files**:
- `SAI/Tools/lib/session-progress-core.ts`

Refactor goals:
- deduplicate mirrored `zk_save_card` request formation
- standardize trunk/source selection for session-progress cards

### Success Criteria
**Automated:**
- [ ] Red: `bun test SAI/Tools/tests/session-progress.test.ts`
- [ ] Green: `bun test SAI/Tools/tests/session-progress.test.ts`
- [ ] Refactor: `bun test SAI/Tools/tests/session-progress.test.ts`

**Manual:**
- [ ] `bun run SAI/Tools/SessionProgress.ts blocker portable-sai "waiting on host adapter spec"` persists blocker locally
- [ ] Healthy memory writes a signal card
- [ ] Failed memory does not block the blocker workflow

---

## Behavior 5: Claude-facing tool docs stay in sync with the authoritative MCP surface

### Resource Registry Binding
- `resource_id`: `[PROPOSED]`
- `address_alias`: `portability.host_surface_contract_sync`
- `predicate_refs`: exported `TOOLS`, `SAI/commands/silmari.md`, `SAI/Algorithm/v3.8.1.md`
- `codepath_ref`: `apps/silmari-mcp/tests/tool-surface-docs.test.ts [PROPOSED]`, `SAI/commands/silmari.md`, `SAI/Algorithm/v3.8.1.md`
- `schema_contract_refs`: `N/A`

### Schema Interface Mapping
- `loop_mode`: `summary`
- `mapped_contracts`: `N/A`
- `registry_updates`: `[PROPOSED] portability.host_surface_contract_sync`

### Test Specification
**Given**: `TOOLS` is the authoritative runtime surface and already includes `zk_recall_by_status` + `zk_promote`  
**When**: the contract test reads the Claude-facing docs  
**Then**: the docs mention those tools as available and do not retain the exact "Known gap" language claiming they do not exist

**Edge Cases**
- new tools land in `TOOLS` but docs are unchanged
- docs mention the tool names but still retain contradictory "missing" language
- multiple Algorithm versions exist; only the active one should be bound to the contract test

### TDD Cycle

#### 🔴 Red: Write Failing Test
**File**: `apps/silmari-mcp/tests/tool-surface-docs.test.ts`
```ts
import { describe, expect, it } from 'bun:test';
import { readFileSync } from 'node:fs';
import { TOOLS } from '../src/index.js';

describe('Claude-facing tool surface docs', () => {
  it('does not describe zk_recall_by_status or zk_promote as missing', () => {
    const names = TOOLS.map((t) => t.name);
    expect(names).toContain('zk_recall_by_status');
    expect(names).toContain('zk_promote');

    const commandDoc = readFileSync('../../SAI/commands/silmari.md', 'utf-8');
    expect(commandDoc).not.toContain('No `zk_recall_by_status`');
    expect(commandDoc).not.toContain('No `zk_promote`');
  });
});
```

#### 🟢 Green: Minimal Implementation
**Files**:
- `apps/silmari-mcp/tests/tool-surface-docs.test.ts` (new)
- `SAI/commands/silmari.md`
- `SAI/Algorithm/v3.8.1.md`

Minimal code/doc change:
- update command and Algorithm docs to list `mcp__silmari__zk_recall_by_status`
- update command and Algorithm docs to list `mcp__silmari__zk_promote`
- delete the stale "Known gap" text for those two tools

**Documentation Contract (required for planned functions):**
```ts
/**
 * @rr.id [PROPOSED]
 * @rr.alias portability.host_surface_contract_sync
 * @path.id host-surface-contract-sync
 * @gwt.given the authoritative TOOLS export and host-facing docs
 * @gwt.when the contract test validates command and Algorithm text
 * @gwt.then docs cannot claim existing tools are missing
 * @reads [PROPOSED]
 * @writes [PROPOSED]
 * @raises [PROPOSED]:HostSurfaceDriftError
 * @schema.contract N/A
 */
```

#### 🔵 Refactor: Improve Code
**Files**:
- `apps/silmari-mcp/tests/tool-surface-docs.test.ts`
- optionally `apps/silmari-mcp/src/tool-docs.ts` (new) if table generation becomes cleaner than string assertions

Refactor goals:
- keep one explicit contract test in CI
- avoid full doc generation unless the simple assertion approach becomes noisy

### Success Criteria
**Automated:**
- [ ] Red: `bun test apps/silmari-mcp/tests/tool-surface-docs.test.ts`
- [ ] Green: `bun test apps/silmari-mcp/tests/tool-surface-docs.test.ts`
- [ ] Refactor: `cd apps/silmari-mcp && bun test`

**Manual:**
- [ ] `/silmari` instructions accurately describe available tools
- [ ] Algorithm docs no longer instruct operators to work around already-landed tools

---

## Integration & E2E Testing

- **Integration**
  - `cd apps/silmari-mcp && bun test tests/recall-promote.test.ts` proves the server-side surface is still real after client extraction.
  - `bun test SAI/Tools/tests/session-progress.test.ts` covers the first SAI consumer on top of that surface.
- **E2E**
  - Temp-HOME smoke:
    1. `bun run SAI/Tools/SessionProgress.ts create portable-sai "restore mirroring"`
    2. inspect temp progress JSON for persisted `card_id`
    3. `bun run SAI/Tools/SessionProgress.ts blocker portable-sai "waiting on adapter"`
    4. `bun run SAI/Tools/SessionProgress.ts complete portable-sai`
  - Claude-facing contract smoke:
    1. run the doc contract test
    2. manually inspect `SAI/commands/silmari.md`
    3. manually inspect active Algorithm doc references

## References

- Research: `thoughts/searchable/shared/research/2026-04-25-sai-claude-codex-gemini-portability-research.md`
- Existing migration plan: `Plans/003_pai-fork-mcp-migration.md`
- Authoritative tool surface: `apps/silmari-mcp/src/index.ts`
- Existing local client handshake: `apps/silmari-mcp/src/cli.ts`
- Existing integration tests: `apps/silmari-mcp/tests/recall-promote.test.ts`
- Disabled mirror consumer: `SAI/Tools/SessionProgress.ts`
- Claude-facing command contract: `SAI/commands/silmari.md`
- Active Algorithm contract text: `SAI/Algorithm/v3.8.1.md`
- Claude-native skill boundary: `SAI/SKILLSYSTEM.md`
- Claude-native hook boundary: `SAI/hooks/README.md`, `SAI/hooks/ThinkWithMemory.hook.ts`
