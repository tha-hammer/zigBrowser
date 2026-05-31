---
date: "2026-04-12T09:44:17-04:00"
researcher: Silmari
git_commit: 456beeb4d343eda7f959889de3dbb71b8f4db0b7
branch: main
repository: silmari-agent-memory
topic: "Implementation paths for zk_recall_by_status and zk_promote MCP tools"
tags: [research, mcp, zk_recall_by_status, zk_promote, silmari-mcp, resumption-protocol]
status: complete
last_updated: "2026-04-12"
last_updated_by: Silmari
type: implementation_research
---

# Research: zk_recall_by_status + zk_promote Implementation Paths

## Research Question

How to implement `zk_recall_by_status` (status-scoped card recall for the resumption protocol) and `zk_promote` (card lifecycle status transitions) as new MCP tools in silmari-mcp.

## Summary

Both tools have all necessary infrastructure already built in the lib/ layer. The implementation is primarily wiring — no new lib modules needed.

- **`zk_recall_by_status`**: `brList` already accepts `status` filter (br-adapter.ts:241-244). New tool calls `brList({status, limit})` and optionally enriches with folgezettel neighborhoods.
- **`zk_promote`**: `brUpdate` already accepts `status` field (br-adapter.ts:174). New tool validates transition, calls `brUpdate`, returns updated card.

---

## Detailed Findings

### zk_recall_by_status

**Algorithm requirement** (v3.7.0.md:175-191): The OBSERVE Resumption Check runs a second query after standard recall, targeting `in_progress` cards. Currently hacked via `zk_recall({query: "in_progress"})` which only works if "in_progress" was seeded as a keyword entry. Known gap documented at v3.7.0.md:181.

**Existing infrastructure:**

| Component | File:Line | What exists |
|-----------|-----------|-------------|
| `brList` status filter | `br-adapter.ts:241-244` | Accepts `status: string \| string[]`, passes as `-s <status>` to `br list` |
| `BrListOpts.status` | `br-adapter.ts:198-210` | Interface already defines the field |
| `BrListOpts.labels` | `br-adapter.ts:200` | Can combine with label filters (e.g., `trunk:5`) |
| `neighborhood()` | `navigate.ts:294-341` | Enriches any card with parent/sibling/children |
| `STATUS_ENUM` | `index.ts:79` | `['open', 'in_progress', 'blocked', 'closed']` already defined |

**Proposed shape** (from migration_v3.7.0_shape_diff.md:52-58):

```typescript
// Tool definition
{
  name: 'zk_recall_by_status',
  description: 'Recall cards filtered by lifecycle status. Used by the resumption protocol to surface in_progress work.',
  inputSchema: {
    type: 'object',
    required: ['status'],
    properties: {
      status: { type: 'string', enum: ['open', 'in_progress', 'blocked', 'closed'] },
      limit: { type: 'number', default: 10 },
      sinceDays: { type: 'number', description: 'Only cards touched in the last N days' },
      box: { type: 'string', enum: ['idea', 'biblio'], default: 'idea' },
      trunk: { type: 'number', enum: [1,2,3,4,5], description: 'Filter to a specific trunk' },
      withNeighborhood: { type: 'boolean', default: false, description: 'Include folgezettel neighborhood for each card' },
    },
  },
}
```

**Implementation path:**

```typescript
// In dispatchTool switch:
case 'zk_recall_by_status': {
  const status = parseEnum(args.status, STATUS_ENUM, 'status');
  const box = parseBox(args.box);
  const limit = parsePositiveNumber(args.limit, 'limit') ?? 10;
  
  const labels: string[] = [];
  if (args.trunk) labels.push(`trunk:${parseTrunk(args.trunk)}`);
  
  let cards = brList({ box, status, labels, limit, all: true, sort: 'updated_at' });
  
  // sinceDays filter (client-side, since br list doesn't support date filtering)
  if (args.sinceDays) {
    const cutoff = Date.now() - Number(args.sinceDays) * 86400000;
    cards = cards.filter(c => new Date(c.updated_at).getTime() >= cutoff);
  }
  
  // Optional neighborhood enrichment
  if (args.withNeighborhood) {
    const enriched = cards.map(card => {
      const fzAddr = parseFzFromLabels(card.labels || []);
      return {
        ...card,
        neighborhood: fzAddr ? neighborhood(fzAddr) : null,
      };
    });
    return okResult(enriched);
  }
  
  return okResult(cards);
}
```

**Key detail:** `brList` with `all: true` is needed to include closed cards in the query (default excludes them). For `in_progress` and `blocked` queries this doesn't matter, but `all: true` keeps behavior consistent.

---

### zk_promote

**Algorithm requirement** (v3.7.0.md:216, 246): Format B option 3 (MARK COMPLETE) needs `in_progress → closed`. Also needed for force override `blocked → open` (v3.7.0.md:293). Known gap documented at v3.7.0.md:246.

**Existing infrastructure:**

| Component | File:Line | What exists |
|-----------|-----------|-------------|
| `brUpdate` with status | `br-adapter.ts:164-194` | Accepts `status?: 'open' \| 'in_progress' \| 'blocked' \| 'closed'` |
| `brShow` | `br-adapter.ts:304-319` | Read current card state before update |
| Status is first-class field | `card-ops.ts:464` | NOT a label — passed directly to br |
| `brClose` | `br-adapter.ts:325-334` | Shortcut for close+archive, but `brUpdate` is more flexible |

**Proposed shape** (from migration_v3.7.0_shape_diff.md:69-77):

```typescript
{
  name: 'zk_promote',
  description: 'Transition a card to a new lifecycle status. Required for resumption protocol MARK COMPLETE and blocked→open force overrides.',
  inputSchema: {
    type: 'object',
    required: ['cardId', 'toStatus', 'reason'],
    properties: {
      cardId: { type: 'string' },
      toStatus: { type: 'string', enum: ['open', 'in_progress', 'blocked', 'closed'] },
      reason: { type: 'string', description: 'Why the status change is happening' },
      box: { type: 'string', enum: ['idea', 'biblio'], default: 'idea' },
      force: { type: 'boolean', default: false, description: 'Required for blocked→open bypass' },
    },
  },
}
```

**Implementation path:**

```typescript
case 'zk_promote': {
  const cardId = String(args.cardId ?? '');
  if (!cardId) throw new Error('cardId is required');
  const toStatus = parseEnum(args.toStatus, STATUS_ENUM, 'toStatus');
  const reason = String(args.reason ?? '');
  if (!reason) throw new Error('reason is required');
  const box = parseBox(args.box);
  const force = Boolean(args.force);
  
  // Read current state
  const card = brShow(box, cardId);
  if (!card) throw new Error(`card not found: ${cardId}`);
  const fromStatus = card.status || 'open';
  
  // Validate transition
  if (fromStatus === 'blocked' && toStatus === 'open' && !force) {
    throw new Error('blocked→open requires force=true (bypasses auto-transition)');
  }
  
  // Execute
  const ok = brUpdate(box, cardId, { status: toStatus });
  if (!ok) throw new Error(`brUpdate failed for ${cardId}`);
  
  return okResult({
    cardId,
    fromStatus,
    toStatus,
    reason,
    forced: force && fromStatus === 'blocked',
  });
}
```

**Transition validation considerations:**
- `in_progress → closed`: Normal completion (Format B option 3). No guard needed.
- `blocked → open`: Force override. Requires `force=true` as documented in shape-diff.
- `closed → open`: Reopening. Could add a guard, but the Algorithm doesn't document needing one.
- `open → in_progress`: Normal start. No guard.
- Same-status transitions: Idempotent, just return current state.

---

## Code References

- `apps/silmari-mcp/src/index.ts:84-278` — TOOLS array (add new tool defs here)
- `apps/silmari-mcp/src/index.ts:376-557` — dispatchTool switch (add new cases here)
- `apps/silmari-mcp/src/lib/br-adapter.ts:198-260` — brList with status filter
- `apps/silmari-mcp/src/lib/br-adapter.ts:164-194` — brUpdate with status field
- `apps/silmari-mcp/src/lib/br-adapter.ts:304-319` — brShow for pre-update read
- `apps/silmari-mcp/src/lib/navigate.ts:294-341` — neighborhood() for enrichment
- `apps/silmari-mcp/src/lib/labels.ts:200-230` — parseFzFromLabels for address extraction
- `SAI/Algorithm/v3.7.0.md:175-191` — OBSERVE Resumption Check (consumer of zk_recall_by_status)
- `SAI/Algorithm/v3.7.0.md:216,246` — Format B MARK COMPLETE (consumer of zk_promote)
- `SAI/Algorithm/v3.7.0.md:293` — blocked→open force override
- `SAI/Algorithm/migration_v3.7.0_shape_diff.md:45-90` — Gap definitions and proposed shapes

## Architecture Notes

- **Status is a first-class beads_rust field**, not label-encoded. This means `brUpdate(box, id, {status})` is the correct mechanism — no label manipulation needed.
- **brUpdate replaces all labels** when called with a labels argument (br-adapter.ts:183). The zk_promote implementation should NOT pass labels — only pass `{status}` to avoid clobbering.
- **brList status filter is server-side** — beads_rust handles the WHERE clause, not client-side filtering. This means `zk_recall_by_status` will be fast even with large stores.
- **sinceDays filtering** must be client-side since br doesn't expose date range queries. Filter on `updated_at` after the brList call.
