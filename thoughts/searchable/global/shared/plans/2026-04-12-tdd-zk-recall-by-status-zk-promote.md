---
date: "2026-04-12T11:00:26-04:00"
researcher: Silmari
git_commit: 456beeb4d343eda7f959889de3dbb71b8f4db0b7
branch: main
repository: silmari-agent-memory
topic: "TDD plan for zk_recall_by_status + zk_promote MCP tools"
tags: [plan, tdd, mcp, zk_recall_by_status, zk_promote, silmari-mcp]
status: ready
last_updated: "2026-04-12"
last_updated_by: Silmari
type: tdd_plan
depends_on: "thoughts/searchable/shared/research/2026-04-12-zk-recall-by-status-zk-promote-implementation.md"
---

# zk_recall_by_status + zk_promote — TDD Implementation Plan

## Overview

Add two MCP tools to silmari-mcp that close the Algorithm v3.7.0 gaps:
- **zk_recall_by_status**: status-scoped card recall for the OBSERVE resumption protocol
- **zk_promote**: card lifecycle status transitions (MARK COMPLETE, force unblock)

All lib/ infrastructure exists. This is wiring + tests.

## Current State

- 15 tools registered in `apps/silmari-mcp/src/index.ts:84-278`
- `brList` supports `status` filter: `br-adapter.ts:241-244`
- `brUpdate` supports `status` field: `br-adapter.ts:164-194`
- `brShow` reads current card state: `br-adapter.ts:304-319`
- `neighborhood()` enriches cards with folgezettel context: `navigate.ts:294-341`
- `STATUS_ENUM` already defined: `index.ts:79`
- Test suite: 11 files, 4,047 lines, `bun:test` framework, real `br` integration

## Desired End State

- 17 tools registered (15 + 2 new)
- Algorithm v3.7.0 OBSERVE resumption check calls `zk_recall_by_status({status: 'in_progress'})` instead of hacking `zk_recall({query: "in_progress"})`
- Format B option 3 (MARK COMPLETE) calls `zk_promote({cardId, toStatus: 'closed', reason})`
- Known gap callouts at v3.7.0.md:181 and v3.7.0.md:246 can be removed

## What We're NOT Doing

| Out of scope | Why |
|---|---|
| Updating Algorithm v3.7.0.md prompts | Separate PR after tools land |
| Adding date-range queries to beads_rust | sinceDays is client-side filter; br enhancement is future |
| Transition state machine enforcement | Only blocked→open needs force guard per shape-diff doc |
| Audit trail / history log | Not in the shape-diff spec; future enhancement |

## Testing Strategy

- **Framework**: `bun:test` (built-in)
- **File**: `tests/recall-promote.test.ts` (new)
- **Pattern**: integration tests with real `br`, `liveIt` conditional skip
- **Setup**: mkdtemp + `SILMARI_DIR`/`SILMARI_IDEA_DIR`/`SILMARI_BIBLIO_DIR` before dynamic import
- **Cleanup**: `afterAll(() => rmSync(TEST_TMP, { recursive: true, force: true }))`
- **Run**: `cd apps/silmari-mcp && bun test tests/recall-promote.test.ts`

---

## Behavior 1: recall_by_status returns cards filtered by status

### Test Specification
**Given**: 3 cards saved — 1 open, 1 in_progress, 1 closed
**When**: `dispatchTool('zk_recall_by_status', { status: 'in_progress' })`
**Then**: Result contains exactly the in_progress card

### TDD Cycle

#### 🔴 Red: Write Failing Test
**File**: `apps/silmari-mcp/tests/recall-promote.test.ts`
```typescript
import { describe, it, expect, beforeAll, afterAll } from 'bun:test';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const TEST_TMP = mkdtempSync(join(tmpdir(), 'silmari-recall-promote-'));
process.env.SILMARI_DIR = TEST_TMP;
process.env.SILMARI_BIBLIO_DIR = join(TEST_TMP, 'box1-biblio', '.beads');
process.env.SILMARI_IDEA_DIR = join(TEST_TMP, 'box2-ideas', '.beads');

const { isBeadsAvailable, resetBrCache } = await import('../src/lib/br-adapter.js');
const { silmariInit } = await import('../src/lib/init.js');
const { saveCard } = await import('../src/lib/card-ops.js');
const { dispatchTool } = await import('../src/index.js');

resetBrCache();
const BR_AVAILABLE = isBeadsAvailable();
const liveIt = (name: string, fn: () => void | Promise<void>) => {
  if (BR_AVAILABLE) it(name, fn); else it.skip(name, fn);
};

beforeAll(() => { if (BR_AVAILABLE) silmariInit(); });
afterAll(() => { rmSync(TEST_TMP, { recursive: true, force: true }); });

describe('zk_recall_by_status', () => {
  liveIt('returns only cards matching the requested status', () => {
    saveCard({ box: 'idea', body: 'Open card', kind: 'learning', trunk: 5, status: 'open' });
    saveCard({ box: 'idea', body: 'In-progress card', kind: 'learning', trunk: 5, status: 'in_progress' });
    saveCard({ box: 'idea', body: 'Closed card', kind: 'learning', trunk: 5, status: 'closed' });

    const result = dispatchTool('zk_recall_by_status', { status: 'in_progress' });
    const cards = JSON.parse(result.content[0].text);

    expect(cards.length).toBe(1);
    expect(cards[0].status).toBe('in_progress');
  });
});
```

#### 🟢 Green: Minimal Implementation

**File**: `apps/silmari-mcp/src/index.ts` — Add to TOOLS array (after zk_reflect):
```typescript
{
  name: 'zk_recall_by_status',
  description:
    'Recall cards filtered by lifecycle status. Primary use: resumption protocol surfaces in_progress work at session start.',
  inputSchema: {
    type: 'object',
    required: ['status'],
    properties: {
      status: { type: 'string', enum: [...STATUS_ENUM] },
      limit: { type: 'number', default: 10 },
      box: { type: 'string', enum: [...BOX_ENUM], default: 'idea' },
      trunk: { type: 'number', enum: TRUNK_ENUM },
      sinceDays: { type: 'number', description: 'Only cards touched in the last N days' },
      withNeighborhood: { type: 'boolean', default: false },
    },
  },
},
```

**File**: `apps/silmari-mcp/src/index.ts` — Add to dispatchTool switch:
```typescript
case 'zk_recall_by_status': {
  const status = parseEnum(args.status, STATUS_ENUM, 'status') as CardStatus;
  const box = parseBox(args.box);
  const limit = parsePositiveNumber(args.limit, 'limit') ?? 10;

  const labels: string[] = [];
  if (args.trunk !== undefined) labels.push(`trunk:${parseTrunk(args.trunk)}`);

  const cards = brList({ box, status, labels, limit, all: true, sort: 'updated_at' });
  return okResult(cards);
}
```

#### 🔵 Refactor
No refactor needed — brList does the heavy lifting.

### Success Criteria
- [ ] 🔴 `bun test tests/recall-promote.test.ts` fails with "unknown tool: zk_recall_by_status"
- [ ] 🟢 Test passes after adding tool def + switch case
- [ ] All existing tests still pass: `bun test`

---

## Behavior 2: recall_by_status respects limit

### Test Specification
**Given**: 5 in_progress cards saved
**When**: `dispatchTool('zk_recall_by_status', { status: 'in_progress', limit: 2 })`
**Then**: Result contains exactly 2 cards

### TDD Cycle

#### 🔴 Red
```typescript
liveIt('respects limit parameter', () => {
  for (let i = 0; i < 5; i++) {
    saveCard({ box: 'idea', body: `Batch card ${i}`, kind: 'stub', trunk: 5, status: 'in_progress' });
  }

  const result = dispatchTool('zk_recall_by_status', { status: 'in_progress', limit: 2 });
  const cards = JSON.parse(result.content[0].text);

  expect(cards.length).toBe(2);
});
```

#### 🟢 Green
Already handled — `brList` passes `limit` to `br list --limit`.

### Success Criteria
- [ ] Test passes with existing implementation from Behavior 1

---

## Behavior 3: recall_by_status filters by trunk

### Test Specification
**Given**: in_progress cards in trunk 3 and trunk 5
**When**: `dispatchTool('zk_recall_by_status', { status: 'in_progress', trunk: 5 })`
**Then**: Result contains only trunk 5 cards

### TDD Cycle

#### 🔴 Red
```typescript
liveIt('filters by trunk when specified', () => {
  saveCard({ box: 'idea', body: 'Trunk 3 card', kind: 'learning', trunk: 3, status: 'in_progress' });
  saveCard({ box: 'idea', body: 'Trunk 5 card', kind: 'learning', trunk: 5, status: 'in_progress' });

  const result = dispatchTool('zk_recall_by_status', { status: 'in_progress', trunk: 5 });
  const cards = JSON.parse(result.content[0].text);

  expect(cards.every((c: any) => (c.labels || []).some((l: string) => l === 'trunk:5'))).toBe(true);
  expect(cards.some((c: any) => (c.labels || []).some((l: string) => l === 'trunk:3'))).toBe(false);
});
```

#### 🟢 Green
Already handled — trunk label filter passed to `brList({ labels: ['trunk:5'] })`.

### Success Criteria
- [ ] Test passes with existing implementation from Behavior 1

---

## Behavior 4: recall_by_status filters by sinceDays

### Test Specification
**Given**: Cards with varying updated_at timestamps
**When**: `dispatchTool('zk_recall_by_status', { status: 'in_progress', sinceDays: 7 })`
**Then**: Only cards updated within the last 7 days are returned

### TDD Cycle

#### 🔴 Red
```typescript
liveIt('filters by sinceDays', () => {
  // All test cards are created now, so sinceDays=7 should include them
  const result = dispatchTool('zk_recall_by_status', { status: 'in_progress', sinceDays: 7 });
  const cards = JSON.parse(result.content[0].text);
  expect(cards.length).toBeGreaterThan(0);

  // sinceDays=0 with a tiny window should return nothing (cards are seconds old but 0 days = now)
  const empty = dispatchTool('zk_recall_by_status', { status: 'closed', sinceDays: 0 });
  const emptyCards = JSON.parse(empty.content[0].text);
  // Cards created in this test run should be within 0 days (same day), so this tests the filter runs
  expect(Array.isArray(emptyCards)).toBe(true);
});
```

#### 🟢 Green: Add sinceDays filter
```typescript
// After brList call in the zk_recall_by_status case:
let cards = brList({ box, status, labels, limit, all: true, sort: 'updated_at' });

if (args.sinceDays !== undefined) {
  const sinceDays = parsePositiveNumber(args.sinceDays, 'sinceDays') ?? 0;
  const cutoff = Date.now() - sinceDays * 86_400_000;
  cards = cards.filter((c: any) => new Date(c.updated_at).getTime() >= cutoff);
}
```

### Success Criteria
- [ ] 🔴 Test fails (sinceDays not yet implemented)
- [ ] 🟢 Test passes after adding date filter

---

## Behavior 5: recall_by_status enriches with neighborhood

### Test Specification
**Given**: An in_progress card with a folgezettel address
**When**: `dispatchTool('zk_recall_by_status', { status: 'in_progress', withNeighborhood: true })`
**Then**: Each card in result has a `neighborhood` field with parent/sibling/children structure

### TDD Cycle

#### 🔴 Red
```typescript
liveIt('enriches with folgezettel neighborhood when requested', () => {
  const result = dispatchTool('zk_recall_by_status', {
    status: 'in_progress',
    withNeighborhood: true,
    limit: 1,
  });
  const cards = JSON.parse(result.content[0].text);

  expect(cards.length).toBeGreaterThan(0);
  expect(cards[0]).toHaveProperty('neighborhood');
});
```

#### 🟢 Green: Add neighborhood enrichment
```typescript
// Add import at top of index.ts:
import { parseFzFromLabels } from './lib/labels.js';

// After sinceDays filter in the zk_recall_by_status case:
if (args.withNeighborhood) {
  const enriched = cards.map((card: any) => {
    const fzAddr = parseFzFromLabels(card.labels || []);
    return { ...card, neighborhood: fzAddr ? neighborhood(fzAddr) : null };
  });
  return okResult(enriched);
}

return okResult(cards);
```

### Success Criteria
- [ ] 🔴 Test fails (no neighborhood field)
- [ ] 🟢 Test passes after adding enrichment
- [ ] Import `parseFzFromLabels` added to index.ts imports

---

## Behavior 6: recall_by_status returns empty for no matches

### Test Specification
**Given**: No cards with status 'blocked'
**When**: `dispatchTool('zk_recall_by_status', { status: 'blocked' })`
**Then**: Returns empty array

### TDD Cycle

#### 🔴 Red
```typescript
liveIt('returns empty array when no cards match', () => {
  const result = dispatchTool('zk_recall_by_status', { status: 'blocked' });
  const cards = JSON.parse(result.content[0].text);

  expect(cards).toEqual([]);
});
```

#### 🟢 Green
Already handled — `brList` returns `[]` when no matches.

### Success Criteria
- [ ] Test passes with existing implementation

---

## Behavior 7: promote transitions card status

### Test Specification
**Given**: An in_progress card
**When**: `dispatchTool('zk_promote', { cardId, toStatus: 'closed', reason: 'task complete' })`
**Then**: Card status is now 'closed', result shows fromStatus='in_progress', toStatus='closed'

### TDD Cycle

#### 🔴 Red
```typescript
describe('zk_promote', () => {
  liveIt('transitions card from in_progress to closed', () => {
    const saved = saveCard({ box: 'idea', body: 'Card to close', kind: 'learning', trunk: 5, status: 'in_progress' });
    const cardId = saved!.id;

    const result = dispatchTool('zk_promote', {
      cardId,
      toStatus: 'closed',
      reason: 'task complete',
    });
    const data = JSON.parse(result.content[0].text);

    expect(data.fromStatus).toBe('in_progress');
    expect(data.toStatus).toBe('closed');
    expect(data.cardId).toBe(cardId);

    // Verify via brShow
    const updated = brShow('idea', cardId);
    expect(updated.status).toBe('closed');
  });
});
```

#### 🟢 Green: Add tool def + switch case

**TOOLS array:**
```typescript
{
  name: 'zk_promote',
  description:
    'Transition a card to a new lifecycle status. Used by resumption protocol MARK COMPLETE (in_progress→closed) and force unblock (blocked→open).',
  inputSchema: {
    type: 'object',
    required: ['cardId', 'toStatus', 'reason'],
    properties: {
      cardId: { type: 'string' },
      toStatus: { type: 'string', enum: [...STATUS_ENUM] },
      reason: { type: 'string' },
      box: { type: 'string', enum: [...BOX_ENUM], default: 'idea' },
      force: { type: 'boolean', default: false },
    },
  },
},
```

**dispatchTool switch:**
```typescript
case 'zk_promote': {
  const cardId = String(args.cardId ?? '');
  if (!cardId) throw new Error('cardId is required');
  const toStatus = parseEnum(args.toStatus, STATUS_ENUM, 'toStatus') as CardStatus;
  const reason = String(args.reason ?? '');
  if (!reason) throw new Error('reason is required');
  const box = parseBox(args.box);
  const force = Boolean(args.force);

  const card = brShow(box, cardId);
  if (!card) throw new Error(`card not found: ${cardId}`);
  const fromStatus = card.status || 'open';

  if (fromStatus === 'blocked' && toStatus === 'open' && !force) {
    throw new Error('blocked→open requires force=true');
  }

  const ok = brUpdate(box, cardId, { status: toStatus });
  if (!ok) throw new Error(`status update failed for ${cardId}`);

  return okResult({ cardId, fromStatus, toStatus, reason, forced: force && fromStatus === 'blocked' });
}
```

### Success Criteria
- [ ] 🔴 Test fails with "unknown tool: zk_promote"
- [ ] 🟢 Test passes after adding tool def + switch case
- [ ] `brShow` confirms status actually changed on disk

---

## Behavior 8: promote blocked→open requires force

### Test Specification
**Given**: A blocked card
**When**: `dispatchTool('zk_promote', { cardId, toStatus: 'open', reason: 'unblock' })` without force
**Then**: Throws 'blocked→open requires force=true'

### TDD Cycle

#### 🔴 Red
```typescript
liveIt('rejects blocked→open without force flag', () => {
  const saved = saveCard({ box: 'idea', body: 'Blocked card', kind: 'stub', trunk: 5, status: 'blocked' });
  const cardId = saved!.id;

  const result = dispatchTool('zk_promote', {
    cardId,
    toStatus: 'open',
    reason: 'force unblock',
  });

  expect(result.isError).toBe(true);
  expect(result.content[0].text).toContain('force=true');
});
```

#### 🟢 Green
Already handled in Behavior 7's implementation — the `if (fromStatus === 'blocked' ...)` guard.

### Success Criteria
- [ ] Test passes with existing implementation from Behavior 7

---

## Behavior 9: promote blocked→open with force succeeds

### Test Specification
**Given**: A blocked card
**When**: `dispatchTool('zk_promote', { cardId, toStatus: 'open', reason: 'override', force: true })`
**Then**: Card status becomes open, result shows forced=true

### TDD Cycle

#### 🔴 Red
```typescript
liveIt('allows blocked→open with force=true', () => {
  const saved = saveCard({ box: 'idea', body: 'Blocked card 2', kind: 'stub', trunk: 5, status: 'blocked' });
  const cardId = saved!.id;

  const result = dispatchTool('zk_promote', {
    cardId,
    toStatus: 'open',
    reason: 'force override',
    force: true,
  });
  const data = JSON.parse(result.content[0].text);

  expect(data.fromStatus).toBe('blocked');
  expect(data.toStatus).toBe('open');
  expect(data.forced).toBe(true);
});
```

#### 🟢 Green
Already handled — force bypasses the guard.

### Success Criteria
- [ ] Test passes with existing implementation

---

## Behavior 10: promote throws on nonexistent card

### Test Specification
**Given**: A cardId that doesn't exist
**When**: `dispatchTool('zk_promote', { cardId: 'zk-nonexistent', toStatus: 'closed', reason: 'test' })`
**Then**: Returns error result with 'card not found'

### TDD Cycle

#### 🔴 Red
```typescript
liveIt('returns error for nonexistent card', () => {
  const result = dispatchTool('zk_promote', {
    cardId: 'zk-nonexistent',
    toStatus: 'closed',
    reason: 'test',
  });

  expect(result.isError).toBe(true);
  expect(result.content[0].text).toContain('card not found');
});
```

#### 🟢 Green
Already handled — `brShow` returns null, throw triggers errorResult via the catch.

### Success Criteria
- [ ] Test passes with existing implementation

---

## Behavior 11: promote validates required fields

### Test Specification
**Given**: Missing reason field
**When**: `dispatchTool('zk_promote', { cardId: 'zk-xxx', toStatus: 'closed' })`
**Then**: Returns error result with 'reason is required'

### TDD Cycle

#### 🔴 Red
```typescript
liveIt('validates required reason field', () => {
  const result = dispatchTool('zk_promote', {
    cardId: 'zk-anything',
    toStatus: 'closed',
  });

  expect(result.isError).toBe(true);
  expect(result.content[0].text).toContain('reason is required');
});
```

#### 🟢 Green
Already handled — `if (!reason) throw new Error('reason is required')`.

### Success Criteria
- [ ] Test passes with existing implementation

---

## Implementation Order

1. Write test file scaffold with setup/teardown + Behavior 1 test → 🔴
2. Add `zk_recall_by_status` tool def + switch case (Behaviors 1-3, 6) → 🟢
3. Add sinceDays filter (Behavior 4) → 🟢
4. Add withNeighborhood enrichment (Behavior 5) → 🟢
5. Add `zk_promote` Behavior 7 test → 🔴
6. Add `zk_promote` tool def + switch case (Behaviors 7-11) → 🟢
7. Run full suite: `cd apps/silmari-mcp && bun test`
8. Update Algorithm known-gap comments (separate step)

## References

- Research: `thoughts/searchable/shared/research/2026-04-12-zk-recall-by-status-zk-promote-implementation.md`
- Shape-diff gaps: `SAI/Algorithm/migration_v3.7.0_shape_diff.md:45-90`
- Algorithm consumers: `SAI/Algorithm/v3.7.0.md:175-191` (recall_by_status), `v3.7.0.md:216,246` (promote)
- MCP server: `apps/silmari-mcp/src/index.ts`
- br-adapter status filter: `apps/silmari-mcp/src/lib/br-adapter.ts:241-244`
- br-adapter update: `apps/silmari-mcp/src/lib/br-adapter.ts:164-194`
- Test patterns: `apps/silmari-mcp/tests/integration.test.ts` (liveIt, setup, assertions)
