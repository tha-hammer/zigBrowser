---
date: "2026-04-13T11:38:37-04:00"
researcher: Codex
git_commit: b75931b282032ed4edc7d2997aee51a0f2f0dc42
branch: main
repository: silmari-agent-memory
topic: "TDD plan for Algorithm v3.8.1 Phase 0 — zk_save_card fromAddress plumbing"
tags: [plan, tdd, algorithm, v3.8.1, phase-0, silmari-mcp, zk_save_card, fromAddress, folgezettel]
status: ready
last_updated: "2026-04-13"
last_updated_by: Codex
type: tdd_plan
depends_on: "thoughts/searchable/shared/research/2026-04-13-algorithm-v381-fromaddress-critical-issue.md"
---

# Algorithm v3.8.1 Phase 0 — `zk_save_card` `fromAddress` TDD Implementation Plan

## Overview

This plan covers the **Phase 0 prerequisite code change only**. It does **not** change the Algorithm prompts yet. The goal is to make `zk_save_card` capable of targeting a specific recalled card address when allocating a new folgezettel position, so later Phase 1 prompt changes have a real code path to call.

Phase 0 introduces one public contract and one internal contract:

- **Public contract (MCP surface)**: `zk_save_card` accepts `fromAddress: "<trunk>/<sequence>"` for idea-box saves using `mode: "fork"` or `mode: "continue"`.
- **Internal contract**: `assignFolgezettel(trunk, mode, fromSequence?)` can allocate from an explicit base sequence instead of the per-trunk cursor, while still advancing the cursor to the new sequence.

Phase 0 intentionally scopes the public-interface change to the MCP server surface in `apps/silmari-mcp/src/index.ts`. The local CLI wrapper is explicitly deferred so this prerequisite stays minimal and unblocks the later Algorithm prompt work.

To keep the behavior explicit and auditable, this plan resolves the open questions from the research doc up front:

1. `fromAddress` accepts the **full address** form like `5/3`, not a bare sequence.
2. `fromAddress` is valid only for **idea-box** saves with `mode: "fork"` or `mode: "continue"`.
3. `fromAddress` must belong to the **same trunk** as `trunk`.
4. `fromAddress` must resolve to an **existing parent card**; explicit-target saves fail fast rather than silently degrading to cursor-based allocation.
5. When explicit targeting succeeds, the cursor is still updated to the **newly allocated sequence**.
6. `fromAddress` may **not** target a reserved Register address like `5/0`, even though that address exists in the store.
7. Explicit-target validation runs **before dedup and before allocation**, so invalid targeted saves never succeed as dedup hits and never mutate the cursor.
8. An explicit target must resolve to **exactly one** parent card by `fz:` label; zero matches and duplicate matches are both hard failures.

## Current State Analysis

- `assignFolgezettel()` only accepts `(trunk, mode)` and always uses `file.cursors[key]` as the base sequence, so it cannot fork or continue from a historic address: `apps/silmari-mcp/src/lib/folgezettel.ts:268-292`.
- `SaveCardOpts` has no `fromAddress` field, and `saveCard()` snapshots `priorCursorSeq` from the current trunk cursor before calling `assignFolgezettel()`: `apps/silmari-mcp/src/lib/card-ops.ts:61-89`, `apps/silmari-mcp/src/lib/card-ops.ts:405-423`.
- Structural parent resolution also uses the cursor-derived predecessor, so a targeted fork would currently create the wrong `branches` or `follows` edge even if allocation were fixed: `apps/silmari-mcp/src/lib/card-ops.ts:480-507`.
- The public MCP surface for `zk_save_card` exposes `mode` but not `fromAddress`, and dispatch cannot pass a target address through: `apps/silmari-mcp/src/index.ts:85-103`, `apps/silmari-mcp/src/index.ts:410-431`.
- The structural extractor itself does **not** need a new feature. `extractFolgezettelParent()` already maps `fork` to `branches` and `continue` to `follows`; the missing piece is selecting the correct `parentCardId`: `apps/silmari-mcp/src/lib/edge-extractors.ts:91-114`.
- Pure allocator coverage already exists in `apps/silmari-mcp/tests/folgezettel.test.ts:266-334`.
- Existing live save-path coverage already proves current cursor-based `follows` / `branches` behavior, which gives us the right harness to extend for explicit targets: `apps/silmari-mcp/tests/integration.test.ts:409-540`.
- The repo also has a dedicated MCP-tool integration pattern with `safeDispatch`, `liveIt`, and isolated temp workspaces that is a better fit than further growing the monolithic integration suite: `apps/silmari-mcp/tests/recall-promote.test.ts:1-49`.

### Key Discoveries

- The review and the research are both correct: the bug is broader than address math. Today the **allocated address** and the **parent structural edge** both point at the cursor card instead of the recalled card.
- `root` mode is the only mode that currently behaves correctly for the plan’s intended use case, because it intentionally ignores the predecessor.
- The smallest safe Phase 0 slice is three code files:
  - `apps/silmari-mcp/src/lib/folgezettel.ts`
  - `apps/silmari-mcp/src/lib/card-ops.ts`
  - `apps/silmari-mcp/src/index.ts`
- The smallest useful test surface is two test files:
  - extend `apps/silmari-mcp/tests/folgezettel.test.ts`
  - add `apps/silmari-mcp/tests/zk-save-card-fromaddress.test.ts`

### Registry / Schema Reality Check

The planning template expects a resource registry and local schema directories, but they are absent in this repo at planning time:

- `specs/schemas/resource_registry.json` does not exist
- `schema/` does not exist
- `schemas/` does not exist
- `specs/schemas/` does not exist

This plan therefore marks resource bindings as `[PROPOSED]` and schema refs as `N/A` instead of inventing IDs or contracts that are not present on disk.

## Desired End State

- `zk_save_card({ trunk: 5, mode: "fork", fromAddress: "5/3", ... })` produces a new card at `5/3a`, even if trunk 5’s cursor is already at `129`.
- `zk_save_card({ trunk: 5, mode: "continue", fromAddress: "5/3a", ... })` produces a new card at `5/3b`, even if the cursor is elsewhere.
- The resulting save writes the structural parent edge to the card at the explicit target address:
  - `fork` -> `ref:branches:<parent-id>`
  - `continue` -> `ref:follows:<parent-id>`
- The cursor file still advances to the new sequence, so subsequent untargeted saves continue from the latest assigned point.
- Invalid explicit-target requests return a clear error **before dedup or allocation** instead of silently falling back:
  - malformed `fromAddress`
  - trunk mismatch
  - `box: "biblio"`
  - `mode: "root"`
  - reserved Register target like `5/0`
  - unresolved parent address
  - ambiguous parent address (duplicate `fz:` match)
- Explicit-target validation is **not** bypassed by duplicate-body dedup. An invalid `fromAddress` still errors even if the body already exists elsewhere.

## Failure Semantics

- **Preflight explicit-target failures**: invalid `fromAddress`, wrong box/mode, trunk mismatch, Register targets, missing parent, and ambiguous parent all fail before dedup and before allocation. These failures create no new bead and do not advance the cursor.
- **Dedup semantics in this phase**: once explicit-target preflight passes, the existing content-hash dedup behavior is preserved. This plan does **not** change global dedup policy.
- **Post-allocation write failures**: this phase preserves the current non-transactional allocator model. If `assignFolgezettel()` succeeds but later `brCreate()` fails, the cursor may already have advanced. Rollback is out of scope for Phase 0.

## What We're NOT Doing

- Updating `SAI/Algorithm/v3.8.1.md` save calls to include `fromAddress`
- Rewriting the Phase 1 mode-selection plan
- Retrofitting existing flat cards into new branches
- Changing `extractFolgezettelParent()` edge semantics
- Creating or backfilling `specs/schemas/resource_registry.json`
- Adding viewer, neighborhood, or recall protocol changes
- Adding `--from-address` CLI parity in `apps/silmari-mcp/src/cli.ts`

## Testing Strategy

- **Framework**: `bun:test`
- **Unit tests**: extend `apps/silmari-mcp/tests/folgezettel.test.ts`
- **Targeted integration tests**: add `apps/silmari-mcp/tests/zk-save-card-fromaddress.test.ts`
- **Live harness**: follow `recall-promote.test.ts` pattern with mkdtemp workspace, env vars set before dynamic imports, `liveIt`, and `safeDispatch`
- **Harness discipline**: keep the same env-before-import and isolated temp-workspace setup used by `folgezettel.test.ts` and `recall-promote.test.ts`, so explicit-target tests do not inherit cursor state from other suites
- **Regression commands**:
  - `cd apps/silmari-mcp && bun test tests/folgezettel.test.ts`
  - `cd apps/silmari-mcp && bun test tests/zk-save-card-fromaddress.test.ts`
  - `cd apps/silmari-mcp && bun test`
  - `cd apps/silmari-mcp && bun run typecheck`

### Test Order

1. Start with pure allocator behavior in `folgezettel.test.ts`
2. Add explicit-target validation in the dedicated `zk_save_card` integration file, including one regression that proves invalid `fromAddress` is rejected before dedup reuse
3. Add save-path tests that prove both the returned address and the structural parent edge
4. Finish with schema-surface assertions for the public MCP tool

---

## Behavior 1: `assignFolgezettel` forks from an explicit base sequence, not the cursor

### Resource Registry Binding

- `resource_id`: `[PROPOSED]`
- `address_alias`: `N/A`
- `predicate_refs`: explicit parent sequence provided; trunk cursor may point elsewhere
- `codepath_ref`: `apps/silmari-mcp/src/lib/folgezettel.ts::assignFolgezettel`
- `schema_contract_refs`: `N/A` — project-local schema directories are absent

### Schema Interface Mapping

- `loop_mode`: `summary`
- `mapped_contracts`: `N/A`
- `registry_updates`: `[PROPOSED] add registry entry for explicit-target folgezettel allocation once a registry exists`

### Test Specification

**Given**: trunk 5 cursor is already at `"129"` and the caller provides explicit base sequence `"3"`

**When**: `assignFolgezettel(5, 'fork', '3')`

**Then**: the returned sequence is `"3a"` and the cursor file for trunk 5 is updated to `"3a"`

**Edge Cases**:

- explicit base `"3a"` forks to `"3a1"`
- explicit base is used even when the current cursor is deeper or later
- the allocator still supports existing cursor-based behavior when no explicit base is provided

### TDD Cycle

#### 🔴 Red: Write Failing Test

**File**: `apps/silmari-mcp/tests/folgezettel.test.ts`

```typescript
it('forks from an explicit sequence instead of the current cursor', () => {
  writeCursors({
    _schema_version: 2,
    cursors: { '5': '129' },
    last_updated: new Date().toISOString(),
  });

  expect(assignFolgezettel(5, 'fork', '3')).toBe('3a');
  expect(readCursors().cursors['5']).toBe('3a');
});
```

#### 🟢 Green: Minimal Implementation

**File**: `apps/silmari-mcp/src/lib/folgezettel.ts`

Change the allocator signature and choose the allocation base from `fromSequence ?? current`.

```typescript
export function assignFolgezettel(
  trunk: TrunkId,
  mode: FolgezettelMode,
  fromSequence?: string,
): string {
  const file = readCursors();
  const key = String(trunk);
  const current = file.cursors[key];
  const base = fromSequence ?? current;

  let next: string;
  if (mode === 'root' || !base) {
    const maxRoot = current ? sequenceRootInt(current) : 0;
    next = rootSequence(maxRoot);
  } else if (mode === 'fork') {
    next = forkSequence(base);
  } else {
    next = continueSequence(base);
  }

  file.cursors[key] = next;
  writeCursors(file);
  return next;
}
```

**Documentation Contract (required for planned functions):**

```typescript
/**
 * @rr.id [PROPOSED]
 * @rr.alias N/A
 * @path.id explicit-fork-allocation
 * @gwt.given trunk cursor may be ahead of the recalled card
 * @gwt.when assignFolgezettel receives mode="fork" and fromSequence="3"
 * @gwt.then it returns "3a" and advances the trunk cursor to "3a"
 * @reads [PROPOSED]
 * @writes [PROPOSED]
 * @raises [PROPOSED]:InvalidFromSequence
 * @schema.contract N/A
 */
```

#### 🔵 Refactor: Improve Code

- Add a small internal `baseSequence` variable for readability
- Keep root allocation based on the **actual cursor** rather than `fromSequence`, so targeted saves do not affect root numbering semantics
- Add a short comment clarifying that explicit targeting overrides only the base for `fork` / `continue`

### Success Criteria

**Automated:**

- [x] `cd apps/silmari-mcp && bun test tests/folgezettel.test.ts` fails before the signature and allocator changes
- [x] The new explicit-fork test passes
- [x] Existing fork and cursor-persistence tests in `folgezettel.test.ts` still pass

**Manual:**

- [ ] The implementation clearly distinguishes cursor-based root allocation from explicit-base fork allocation

---

## Behavior 2: `assignFolgezettel` continues from an explicit base sequence and rejects invalid explicit-root combinations

### Resource Registry Binding

- `resource_id`: `[PROPOSED]`
- `address_alias`: `N/A`
- `predicate_refs`: explicit sibling base provided for continue; invalid explicit-root combinations are disallowed
- `codepath_ref`: `apps/silmari-mcp/src/lib/folgezettel.ts::assignFolgezettel`
- `schema_contract_refs`: `N/A`

### Schema Interface Mapping

- `loop_mode`: `summary`
- `mapped_contracts`: `N/A`
- `registry_updates`: `[PROPOSED] allocator validation contract`

### Test Specification

**Given**: trunk 5 cursor is `"129"` and the caller provides explicit base sequence `"3a"`

**When**: `assignFolgezettel(5, 'continue', '3a')`

**Then**: the returned sequence is `"3b"` and the cursor file for trunk 5 is updated to `"3b"`

**Edge Cases**:

- `assignFolgezettel(5, 'root', '3')` throws, because explicit targeting with `root` is an invalid combination
- malformed explicit sequences still fail through existing parser validation
- existing `continue` behavior remains unchanged when `fromSequence` is omitted

### TDD Cycle

#### 🔴 Red: Write Failing Test

**File**: `apps/silmari-mcp/tests/folgezettel.test.ts`

```typescript
it('continues from an explicit sequence instead of the current cursor', () => {
  writeCursors({
    _schema_version: 2,
    cursors: { '5': '129' },
    last_updated: new Date().toISOString(),
  });

  expect(assignFolgezettel(5, 'continue', '3a')).toBe('3b');
  expect(readCursors().cursors['5']).toBe('3b');
});

it('rejects explicit fromSequence with root mode', () => {
  expect(() => assignFolgezettel(5, 'root', '3')).toThrow(/root/i);
});
```

#### 🟢 Green: Minimal Implementation

**File**: `apps/silmari-mcp/src/lib/folgezettel.ts`

Validate explicit targeting before allocation:

```typescript
if (fromSequence) {
  parseSequence(fromSequence);
  if (mode === 'root') {
    throw new Error('fromSequence is only valid for fork/continue');
  }
}
```

Continue allocation uses the same `base = fromSequence ?? current` rule from Behavior 1.

**Documentation Contract (required for planned functions):**

```typescript
/**
 * @rr.id [PROPOSED]
 * @rr.alias N/A
 * @path.id explicit-continue-allocation
 * @gwt.given trunk cursor may point at an unrelated later card
 * @gwt.when assignFolgezettel receives mode="continue" and fromSequence="3a"
 * @gwt.then it returns "3b", advances the cursor, and rejects root+fromSequence
 * @reads [PROPOSED]
 * @writes [PROPOSED]
 * @raises [PROPOSED]:InvalidFromSequence,[PROPOSED]:InvalidModeCombination
 * @schema.contract N/A
 */
```

#### 🔵 Refactor: Improve Code

- Extract a tiny local validation block at the top of `assignFolgezettel()`
- Keep the validation local to the allocator so unit tests can lock down the invariant without requiring `saveCard()`

### Success Criteria

**Automated:**

- [x] New explicit-continue test passes
- [x] New root+explicit-base rejection test passes
- [x] `cd apps/silmari-mcp && bun test tests/folgezettel.test.ts` remains green

**Manual:**

- [ ] The function contract makes it obvious that explicit targeting is only for `fork` / `continue`

---

## Behavior 3: `saveCard` uses `fromAddress` for both allocation and structural parent resolution

### Resource Registry Binding

- `resource_id`: `[PROPOSED]`
- `address_alias`: `N/A`
- `predicate_refs`: caller provides explicit parent address; matching parent card exists in idea box
- `codepath_ref`: `apps/silmari-mcp/src/lib/card-ops.ts::saveCard`
- `schema_contract_refs`: `N/A`

### Schema Interface Mapping

- `loop_mode`: `summary`
- `mapped_contracts`: `N/A`
- `registry_updates`: `[PROPOSED] explicit-target save orchestration contract`

### Test Specification

**Given**:

- trunk 5 cursor has advanced beyond the intended parent
- a card already exists at `5/3`
- the caller saves a new idea card with `mode: "fork"` and `fromAddress: "5/3"`

**When**: `saveCard({ box: 'idea', body: '...', kind: 'learning', trunk: 5, mode: 'fork', fromAddress: '5/3' })`

**Then**:

- the returned folgezettel address is `5/3a`
- the saved card gets a `ref:branches` edge to the card at `5/3`
- the save does **not** branch from the current cursor card

**Edge Cases**:

- `continue` from `5/3a` yields `5/3b` and writes `ref:follows` to the card at `5/3a`
- nonexistent `fromAddress` fails fast
- `fromAddress` on `box: 'biblio'` fails fast
- trunk mismatch like `trunk: 5` plus `fromAddress: '4/3'` fails fast
- reserved Register target like `fromAddress: '5/0'` fails fast
- duplicate-body calls still reject an invalid `fromAddress` instead of returning the deduped card

### TDD Cycle

#### 🔴 Red: Write Failing Test

**File**: `apps/silmari-mcp/tests/zk-save-card-fromaddress.test.ts`

Reuse the dedicated live-harness pattern from `recall-promote.test.ts:1-49`.

```typescript
liveIt('forks from the explicit parent address and writes branches to that parent', () => {
  silmariInit();

  const seed1 = saveCard({ box: 'idea', body: 'root 1', kind: 'idea', trunk: 5, mode: 'root' })!;
  const seed2 = saveCard({ box: 'idea', body: 'root 2', kind: 'idea', trunk: 5, mode: 'root' })!;
  const seed3 = saveCard({ box: 'idea', body: 'root 3', kind: 'idea', trunk: 5, mode: 'root' })!;
  expect(seed3.fz).toBe('5/3');

  saveCard({ box: 'idea', body: 'later cursor card', kind: 'idea', trunk: 5, mode: 'root' })!;
  saveCard({ box: 'idea', body: 'cursor now far ahead', kind: 'idea', trunk: 5, mode: 'root' })!;

  const forked = saveCard({
    box: 'idea',
    body: 'fork from explicit historic parent',
    kind: 'learning',
    trunk: 5,
    mode: 'fork',
    fromAddress: '5/3',
  })!;

  expect(forked.fz).toBe('5/3a');
  expect(listOutboundOfType('idea', forked.id, 'branches')).toContain(seed3.id);
});
```

Add a sibling test for `continue` from `5/3a`.

#### 🟢 Green: Minimal Implementation

**File**: `apps/silmari-mcp/src/lib/card-ops.ts`

Planned changes:

1. Extend `SaveCardOpts` idea-box variant with `fromAddress?: string`
2. Add a local preflight helper that validates and resolves the public address **before dedup and before allocation**
3. Use the resolved sequence as the allocator base and the resolved parent id for structural edges
4. Treat explicit-target validation failures as **hard failures**, not as best-effort warnings
5. Preserve the existing best-effort warning path only for untargeted allocator failures

```typescript
interface ExplicitTarget {
  sequence: string;
  parentCardId: string;
}

function resolveExplicitTarget(
  trunk: TrunkId,
  box: 'idea' | 'biblio',
  mode: FolgezettelMode,
  fromAddress?: string,
): ExplicitTarget | null {
  if (!fromAddress) return null;
  if (box !== 'idea') throw new Error('fromAddress is only valid for idea box saves');
  if (mode === 'root') throw new Error('fromAddress is only valid for fork/continue');

  const parsed = parseAddress(fromAddress);
  if (parsed.trunk !== trunk) {
    throw new Error(`fromAddress trunk ${parsed.trunk} does not match trunk ${trunk}`);
  }
  if (parsed.sequence === '0') {
    throw new Error('fromAddress cannot target a trunk Register');
  }

  const matches = brList({
    box: 'idea',
    labels: [fzLabel(trunk, parsed.sequence)],
    limit: 2,
    all: true,
  });
  if (matches.length === 0) {
    throw new Error(`no parent card exists at ${fromAddress}`);
  }
  if (matches.length > 1) {
    throw new Error(`ambiguous fromAddress ${fromAddress}`);
  }
  if ((matches[0].labels || []).includes(kindLabel('register'))) {
    throw new Error('fromAddress cannot target a Register card');
  }

  return {
    sequence: parsed.sequence,
    parentCardId: matches[0].id as string,
  };
}
```

Run that preflight before the dedup early-return:

```typescript
const mode = opts.box === 'idea' ? (opts.mode || 'continue') : 'root';
const explicitTarget =
  opts.box === 'idea'
    ? resolveExplicitTarget(opts.trunk, opts.box, mode, opts.fromAddress)
    : null;

const existing = findByContentHash(opts.box, fullHash);
if (existing) {
  return { ... };
}
```

Use the resolved target for both:

- `assignFolgezettel(opts.trunk, mode, explicitTarget?.sequence)`
- `parentCardId = explicitTarget?.parentCardId ?? cursorDerivedParentCardId`

If `fromAddress` was provided and the parent lookup resolves zero or multiple matches, throw before dedup returns and before creating the new bead.

**Documentation Contract (required for planned functions):**

```typescript
/**
 * @rr.id [PROPOSED]
 * @rr.alias N/A
 * @path.id resolve-explicit-target
 * @gwt.given caller passes a public fromAddress string like "5/3"
 * @gwt.when saveCard validates explicit-target inputs before allocation
 * @gwt.then it resolves exactly one same-trunk non-Register parent or rejects the call before dedup/allocation
 * @reads [PROPOSED]
 * @writes [PROPOSED]
 * @raises [PROPOSED]:InvalidFromAddress,[PROPOSED]:MismatchedTrunk,[PROPOSED]:RegisterTarget,[PROPOSED]:MissingParentCard,[PROPOSED]:AmbiguousParentCard
 * @schema.contract N/A
 */
```

```typescript
/**
 * @rr.id [PROPOSED]
 * @rr.alias N/A
 * @path.id explicit-target-savecard
 * @gwt.given a parent card exists at fromAddress and the cursor may point elsewhere
 * @gwt.when saveCard runs with mode="fork" or mode="continue" and fromAddress set
 * @gwt.then explicit-target validation runs before dedup, then allocation and structural parent lookup both use the same resolved target
 * @reads [PROPOSED]
 * @writes [PROPOSED]
 * @raises [PROPOSED]:MissingParentCard,[PROPOSED]:AmbiguousParentCard,[PROPOSED]:InvalidFromAddress
 * @schema.contract N/A
 */
```

#### 🔵 Refactor: Improve Code

- Rename `priorCursorSeq` to `parentSequence` or similar so the variable matches the new semantics
- Keep the existing best-effort warning path for untargeted allocator failures only
- Split explicit-target preflight from generic save orchestration so ordering vs dedup is obvious
- Add one short comment noting that explicit-target validation is intentionally pre-dedup so invalid calls cannot be masked by reuse

### Success Criteria

**Automated:**

- [x] New fork-from-explicit-parent integration test fails before the `saveCard` changes
- [x] New continue-from-explicit-parent integration test fails before the `saveCard` changes
- [x] New invalid-target-before-dedup regression fails before the `saveCard` ordering change
- [x] Both tests pass after the `fromAddress` orchestration is added
- [x] `cd apps/silmari-mcp && bun test tests/zk-save-card-fromaddress.test.ts` passes

**Manual:**

- [ ] It is obvious in `saveCard()` that one normalized parent sequence drives both allocation and structural edge resolution
- [ ] It is obvious that explicit-target validation runs before dedup and that Register targets are rejected

---

## Behavior 4: `zk_save_card` exposes `fromAddress` publicly and surfaces explicit-target validation errors

### Resource Registry Binding

- `resource_id`: `[PROPOSED]`
- `address_alias`: `N/A`
- `predicate_refs`: MCP caller supplies `fromAddress` and mode; dispatcher forwards explicit-target state into `saveCard`
- `codepath_ref`: `apps/silmari-mcp/src/index.ts::TOOLS`, `apps/silmari-mcp/src/index.ts::dispatchTool`
- `schema_contract_refs`: `N/A` — no local schema directories

### Schema Interface Mapping

- `loop_mode`: `summary`
- `mapped_contracts`: `N/A`
- `registry_updates`: `[PROPOSED] public zk_save_card explicit-target API contract`

### Test Specification

**Given**: the `zk_save_card` tool definition and dispatcher

**When**:

- the caller inspects the tool schema
- the caller dispatches a valid explicit-target save
- the caller dispatches invalid explicit-target combinations
- the caller dispatches an invalid explicit-target request whose body already exists in the store

**Then**:

- the schema includes a `fromAddress` string property
- valid calls return the expected `fz`
- invalid calls return an error result that explains the violated contract
- runtime validation in `saveCard()` remains authoritative for conditional rules that are not fully expressed in the flat JSON Schema

**Edge Cases**:

- malformed `fromAddress`
- trunk mismatch
- `mode: "root"` plus `fromAddress`
- `box: "biblio"` plus `fromAddress`
- reserved Register target like `5/0`
- nonexistent target address
- duplicate body plus invalid `fromAddress`

### TDD Cycle

#### 🔴 Red: Write Failing Test

**File**: `apps/silmari-mcp/tests/zk-save-card-fromaddress.test.ts`

```typescript
it('publishes fromAddress in the zk_save_card schema', () => {
  const tool = TOOLS.find((t) => t.name === 'zk_save_card');
  const props = (tool!.inputSchema as any).properties;
  expect(props.fromAddress).toBeDefined();
  expect(props.fromAddress.type).toBe('string');
});

liveIt('returns an error for mismatched trunk and fromAddress', () => {
  silmariInit();
  const result = safeDispatch('zk_save_card', {
    body: 'bad explicit target',
    kind: 'learning',
    trunk: 5,
    mode: 'fork',
    fromAddress: '4/3',
  });

  expect(result.isError).toBe(true);
  expect(result.content[0].text).toContain('fromAddress trunk');
});

liveIt('validates fromAddress before dedup reuse', () => {
  silmariInit();
  saveCard({
    box: 'idea',
    body: 'duplicate-body explicit-target regression',
    kind: 'learning',
    trunk: 5,
    mode: 'root',
  })!;

  const result = safeDispatch('zk_save_card', {
    body: 'duplicate-body explicit-target regression',
    kind: 'learning',
    trunk: 5,
    mode: 'fork',
    fromAddress: '4/3',
  });

  expect(result.isError).toBe(true);
  expect(result.content[0].text).toContain('fromAddress trunk');
});
```

#### 🟢 Green: Minimal Implementation

**File**: `apps/silmari-mcp/src/index.ts`

Add `fromAddress` to the tool schema and forward it through dispatch:

```typescript
properties: {
  body: { type: 'string', description: 'Full card body (title + content)' },
  kind: { type: 'string', enum: KIND_ENUM },
  box: { type: 'string', enum: [...BOX_ENUM], default: 'idea' },
  trunk: { type: 'number', enum: TRUNK_ENUM, description: 'Required for idea box' },
  mode: { type: 'string', enum: [...MODE_ENUM], default: 'continue' },
  fromAddress: { type: 'string', description: 'Explicit parent address like "5/3" for fork/continue saves' },
  scope: { type: 'string' },
  source: { type: 'string' },
  status: { type: 'string', enum: [...STATUS_ENUM] },
}
```

```typescript
const fromAddress = args.fromAddress as string | undefined;
const result = saveCard({ box: 'idea', body, kind, trunk, mode, fromAddress, scope, source, status });
```

Use the same `safeDispatch` pattern as `recall-promote.test.ts:41-48` so throwing validation errors become MCP-style `isError` results in tests.
Phase 0 does **not** require conditional `if/then` JSON Schema. The schema change is for discoverability; `saveCard()` remains the authoritative runtime validator for idea-only, non-root, non-Register, unique-parent rules.

**Documentation Contract (required for planned functions):**

```typescript
/**
 * @rr.id [PROPOSED]
 * @rr.alias N/A
 * @path.id zk-save-card-explicit-target-api
 * @gwt.given an MCP caller has a recalled card address like "5/3"
 * @gwt.when zk_save_card is called with mode="fork" or mode="continue" and fromAddress set
 * @gwt.then the tool schema accepts the argument and dispatch forwards it to saveCard
 * @reads [PROPOSED]
 * @writes [PROPOSED]
 * @raises [PROPOSED]:InvalidFromAddress,[PROPOSED]:MismatchedTrunk,[PROPOSED]:RegisterTarget,[PROPOSED]:MissingParentCard,[PROPOSED]:AmbiguousParentCard
 * @schema.contract N/A
 */
```

#### 🔵 Refactor: Improve Code

- Keep dispatcher parsing thin; validation belongs in `saveCard()`
- Add one concise schema description so future Algorithm prompt work can rely on the contract text
- Document in the tool description that conditional validity is enforced at runtime, not by schema alone

### Success Criteria

**Automated:**

- [x] Schema test fails before `fromAddress` is added to `TOOLS`
- [x] Dispatcher happy-path test passes for a valid explicit-target save
- [x] Error-path tests pass for malformed, mismatched, root-mode, biblio-box, Register-target, duplicate-body-invalid-target, missing-parent, and ambiguous-parent cases
- [x] `cd apps/silmari-mcp && bun test tests/zk-save-card-fromaddress.test.ts` passes

**Manual:**

- [ ] The public contract is unambiguous from the schema and the error messages

---

## Integration & E2E Testing

- **Integration**:
  - `folgezettel.test.ts` proves the allocator math and cursor updates
  - `zk-save-card-fromaddress.test.ts` proves public API + save orchestration + structural edges against a real `br` workspace
- **E2E**:
  - The dedicated `dispatchTool('zk_save_card', ...)` tests are sufficient for this phase because `index.ts` is a thin MCP facade
  - CLI parity is intentionally deferred; no CLI smoke test is required for Phase 0
  - A full external MCP-client smoke test is optional and should not block Phase 0

## File Plan

- **Modify** `apps/silmari-mcp/src/lib/folgezettel.ts`
  - add `fromSequence?: string` to `assignFolgezettel()`
  - validate explicit-target mode combinations
- **Modify** `apps/silmari-mcp/src/lib/card-ops.ts`
  - add `fromAddress?: string` to `SaveCardOpts`
  - add explicit-target normalization / validation
  - use one parent sequence for both allocation and parent-card lookup
- **Modify** `apps/silmari-mcp/src/index.ts`
  - expose `fromAddress` in `zk_save_card` schema
  - forward `fromAddress` to `saveCard()`
- **Modify** `apps/silmari-mcp/tests/folgezettel.test.ts`
  - add explicit fork / continue / invalid root cases
- **Add** `apps/silmari-mcp/tests/zk-save-card-fromaddress.test.ts`
  - copy the isolated live-harness shape from `recall-promote.test.ts`
  - assert schema surface, dispatcher behavior, explicit-target happy path, and error paths

## Verification Commands

```bash
cd apps/silmari-mcp && bun test tests/folgezettel.test.ts
cd apps/silmari-mcp && bun test tests/zk-save-card-fromaddress.test.ts
cd apps/silmari-mcp && bun test
cd apps/silmari-mcp && bun run typecheck
```

## References

- Research: `thoughts/searchable/shared/research/2026-04-13-algorithm-v381-fromaddress-critical-issue.md`
- Review: `thoughts/searchable/shared/plans/2026-04-13-algorithm-v381-folgezettel-mode-selection-REVIEW.md`
- Superseded broader plan: `thoughts/searchable/shared/plans/2026-04-13-algorithm-v381-folgezettel-mode-selection.md`
- Public MCP schema: `apps/silmari-mcp/src/index.ts:85-103`
- `zk_save_card` dispatch: `apps/silmari-mcp/src/index.ts:410-431`
- Save orchestration: `apps/silmari-mcp/src/lib/card-ops.ts:61-89`, `apps/silmari-mcp/src/lib/card-ops.ts:405-507`
- Allocator: `apps/silmari-mcp/src/lib/folgezettel.ts:268-292`
- Structural edge mapping: `apps/silmari-mcp/src/lib/edge-extractors.ts:91-114`
- Existing pure allocator tests: `apps/silmari-mcp/tests/folgezettel.test.ts:266-334`
- Existing live structural-edge tests: `apps/silmari-mcp/tests/integration.test.ts:409-540`
- Dedicated tool-test harness pattern: `apps/silmari-mcp/tests/recall-promote.test.ts:1-49`
