# brList Timeout + Cascade Fix TDD Plan

## Overview

Four targeted fixes for the m07/5xj failure surfaces identified in the 2026-04-26 cascade re-run.

Root cause chain: `brList()` swallows `ETIMEDOUT` as `[]` → `resolveExplicitTarget()` mistakes "lookup timed out" for "parent genuinely missing" → misleading throw → downstream transcripts fail. The SQL correlated subquery on `labels` is why the lookup is slow (>500ms on a ~150-card store). Fix order follows dependency chain — fix the error signal first, add timeout headroom second, fix the underlying SQL third, then wire cascade timeouts.

Related bds: **m07** (resolveExplicitTarget false "missing"), **5xj** (zk_save_cards 60s MCP timeout).

---

## Current State Analysis

### Fix 1+2 — brList timeout handling

| Location | Current behavior |
|---|---|
| `apps/silmari-mcp/src/lib/br-adapter.ts:45` | `TIMEOUT_READ = 500` — applies to ALL brList calls |
| `apps/silmari-mcp/src/lib/br-adapter.ts:321-354` | `execFileSync(..., { timeout: TIMEOUT_READ })` → `catch { return []; }` — swallows ALL errors including ETIMEDOUT |
| `apps/silmari-mcp/src/lib/card-ops.ts:673-719` | `resolveExplicitTarget()` calls `brList` twice (100ms sleep between), treats `[]` as absence, throws "genuinely missing" |
| `apps/silmari-mcp/src/lib/card-ops.ts:704-706` | Error text: `"no parent card exists at 1/<N> (after WAL-race retry — fork target genuinely missing)"` — lie when actual cause is timeout |

Empirical evidence: `br list --label fz:1_7` on the post-run store takes 697–709ms. At `TIMEOUT_READ = 500ms`, both brList calls die silently, producing a false "missing" verdict for a card that exists.

### Fix 3 — SQL correlated subquery (beads_rust)

| Location | Current behavior |
|---|---|
| `vendor/beads_rust/src/storage/sqlite.rs:1924-1928` | `WHERE EXISTS (SELECT 1 FROM labels WHERE labels.issue_id = issues.id AND labels.label = ?)` — correlated subquery per issue row |
| `vendor/beads_rust/src/storage/schema.rs:127` | `idx_labels_label ON labels(label)` — single-column |
| `vendor/beads_rust/src/storage/schema.rs:128` | `idx_labels_issue ON labels(issue_id)` — single-column |
| Missing | No composite `(label, issue_id)` index — forces secondary row fetch after index scan |

Adding `idx_labels_for_label_lookup ON labels(label, issue_id)` makes the EXISTS subquery a covering-index-only lookup. No query rewrite needed. JOIN rewrite is future work.

### Fix 4 — 5xj: zk_save_cards missing timeout opts

| Location | Current behavior |
|---|---|
| `scripts/kc-baker-pipeline-v2/ingest/ingest-cascade.ts:199-201` | `GATE_B_MCP_TIMEOUT_MS = 180000` — wired ONLY to `zk_propose_links_semantic` |
| `ingest-cascade.ts:357` | Tier 1 thesis `callTool("zk_save_cards", {...})` — no `opts` arg |
| `ingest-cascade.ts:385` | Tier 2 themes — no `opts` arg |
| `ingest-cascade.ts:419` | Tier 3 ideas — no `opts` arg |
| `ingest-cascade.ts:452` | Tier 4 micros — no `opts` arg; highest-load call (~200 cards) |
| MCP SDK | `DEFAULT_REQUEST_TIMEOUT_MSEC = 60000` — 60s default applied to all four calls |

---

## What We're NOT Doing

- NOT cursor reconciliation — confirmed: cards exist in store; cursor is consistent; reconciliation would not have prevented the observed failures
- NOT rewriting the SQL JOIN — composite index is sufficient and less risky; join rewrite is future work
- NOT changing the overall cascade architecture
- NOT exporting `TIMEOUT_RESOLVE_PARENT` as a module-scope constant (timeout is read at call time inside the function body to avoid bun:test import-freeze trap)

---

## Testing Strategy

- **Framework**: `bun test`
- **Pattern**: All tests use real `br` binary, real temp dirs — no mocks (established pattern in existing test suite)
- **Unit tests (Fixes 1+2)**: `apps/silmari-mcp/tests/br-adapter.test.ts` — add timeout discrimination cases; `apps/silmari-mcp/tests/zk-save-card-fromaddress.test.ts` — add timeout error message case
- **Rust tests (Fix 3)**: `vendor/beads_rust/tests/storage_list_filters.rs` — add index existence assertion
- **Cascade tests (Fix 4)**: `scripts/kc-baker-pipeline-v2/tests/ingest-cascade.test.ts` — add opts.timeout assertion via testable helper extraction
- **Run commands**:
  - `bun test apps/silmari-mcp/tests/br-adapter.test.ts`
  - `bun test apps/silmari-mcp/tests/zk-save-card-fromaddress.test.ts`
  - `cargo test -p beads_rust --test storage_list_filters`
  - `bun test scripts/kc-baker-pipeline-v2/tests/ingest-cascade.test.ts`
  - `bun test` (full suite after all four behaviors land)

---

## Behavior 1: `brList` throws `BrListTimeoutError` on subprocess kill — never returns `[]`

**Given**: `execFileSync('br', ...)` is killed by the timeout signal  
**When**: `brList` catches the error  
**Then**: throws `BrListTimeoutError` (NOT silently returns `[]`)

**Edge cases**: non-timeout errors (parse failure, workspace error) still return `[]`; `BrListTimeoutError` is exported and identifiable by callers

### TDD Cycle

#### 🔴 Red: Write Failing Test

**File**: `apps/silmari-mcp/tests/br-adapter.test.ts` (add new describe block)

```typescript
describe('brList — timeout vs. empty distinction (bd m07)', () => {
  it('throws BrListTimeoutError when subprocess times out (not returns [])', () => {
    // Set timeout to 1ms — br startup alone exceeds this, guaranteeing SIGTERM
    // BrListTimeoutError is not exported yet → test fails at import
    expect(() =>
      brList({ box: 'idea', labels: ['fz:1_7'], timeoutMs: 1 })
    ).toThrow(BrListTimeoutError);
  });

  it('BrListTimeoutError is distinguishable from other errors', () => {
    let thrown: unknown;
    try {
      brList({ box: 'idea', labels: ['fz:1_7'], timeoutMs: 1 });
    } catch (err) {
      thrown = err;
    }
    expect(thrown).toBeInstanceOf(BrListTimeoutError);
  });

  it('returns [] (not throws) when label genuinely absent — regression', () => {
    // Confirm genuine-empty case still returns [] and does NOT throw
    expect(() =>
      brList({ box: 'idea', labels: ['__nonexistent_label_bd_m07__'] })
    ).not.toThrow();
    const result = brList({ box: 'idea', labels: ['__nonexistent_label_bd_m07__'] });
    expect(result).toEqual([]);
  });
});
```

Import change needed at top of test file:
```typescript
const { brShow, brList, brSearch, brCreate, brLabelAdd, resetBrCache, BrListTimeoutError } = await import(
  '../src/lib/br-adapter.js'
);
```

#### 🟢 Green: Minimal Implementation

**File**: `apps/silmari-mcp/src/lib/br-adapter.ts`

Add after the existing timeout constants (line 47):

```typescript
export class BrListTimeoutError extends Error {
  constructor(timeoutMs: number) {
    super(`brList subprocess killed after ${timeoutMs}ms (SIGTERM/SIGKILL — not a genuine empty result)`);
    this.name = 'BrListTimeoutError';
  }
}
```

Add `timeoutMs` to `BrListOpts` (insert after existing fields):
```typescript
/** Override per-call timeout. Defaults to TIMEOUT_READ (500ms). */
timeoutMs?: number;
```

Update `brList` body — change the `execFileSync` call and catch block:

```typescript
// Before (line 337-341):
const result = execFileSync(BR, args, {
  timeout: TIMEOUT_READ,
  stdio: 'pipe',
  encoding: 'utf-8',
});

// After:
const effectiveTimeout = opts.timeoutMs ?? TIMEOUT_READ;
const result = execFileSync(BR, args, {
  timeout: effectiveTimeout,
  stdio: 'pipe',
  encoding: 'utf-8',
});
```

```typescript
// Before (line 352-354):
  } catch {
    return [];
  }

// After:
  } catch (err) {
    if (err instanceof Error && (err as NodeJS.ErrnoException & { killed?: boolean }).killed) {
      throw new BrListTimeoutError(opts.timeoutMs ?? TIMEOUT_READ);
    }
    return [];
  }
```

#### 🔵 Refactor

No refactor needed — change is surgical. The `killed` property is the standard Node.js child_process signal for timeout kills.

### Success Criteria

**Automated:**
- [ ] Test fails for right reason before implementation (BrListTimeoutError not exported)
- [ ] `bun test apps/silmari-mcp/tests/br-adapter.test.ts` — all 3 new tests pass
- [ ] `bun test` — full suite green (no regressions; genuine-empty callers unaffected)

**Manual:**
- [ ] `brList({ box: 'idea', labels: ['fz:1_7'], timeoutMs: 1 })` throws in a REPL
- [ ] `brList({ box: 'idea', labels: ['__nonexistent__'] })` returns `[]`

---

## Behavior 2: `resolveExplicitTarget` uses elevated timeout + distinguishes timeout from absence

**Given**: `resolveExplicitTarget` is called for a `fromAddress` that EXISTS in the store but `brList` times out  
**When**: the lookup subprocess is killed  
**Then**: throws an error whose message contains "timed out" — NOT "genuinely missing"

**Given**: `resolveExplicitTarget` is called for a `fromAddress` that does NOT exist  
**When**: `brList` completes successfully and returns `[]`  
**Then**: throws an error whose message contains "genuinely missing" (unchanged 6jp behavior)

**Edge cases**: both brList calls (initial + 100ms WAL retry) can independently time out; error message must reflect which path was taken

### TDD Cycle

#### 🔴 Red: Write Failing Tests

**File**: `apps/silmari-mcp/tests/zk-save-card-fromaddress.test.ts` (add after existing bd 6jp tests)

```typescript
// Timeout case — fromAddress exists but brList times out
// Uses timeoutMs env var to make resolveExplicitTarget use a tiny timeout
liveIt('timeout during parent lookup throws timeout error, NOT "genuinely missing" (bd m07)', async () => {
  // Save a real card to create a valid fromAddress
  const parent = await safeDispatch('zk_save_card', {
    body: 'm07-timeout-regression-parent',
    kind: 'fact',
    trunk: 5,
    mode: 'root',
  });
  expect(parent.isError).toBeFalsy();
  const parentFz = JSON.parse(parent.content[0].text).fz as string;

  // Force 1ms timeout on parent resolution so brList always times out
  process.env.SILMARI_RESOLVE_PARENT_TIMEOUT_MS = '1';
  try {
    const result = await safeDispatch('zk_save_card', {
      body: 'm07-timeout-regression-child',
      kind: 'fact',
      trunk: 5,
      mode: 'fork',
      fromAddress: parentFz,
    });
    // Should fail — but with timeout error, not "genuinely missing"
    expect(result.isError).toBe(true);
    expect(result.content[0].text).toMatch(/timed out/i);
    expect(result.content[0].text).not.toMatch(/genuinely missing/);
  } finally {
    delete process.env.SILMARI_RESOLVE_PARENT_TIMEOUT_MS;
  }
});

// Absent case — fromAddress does not exist (6jp regression: error unchanged)
// Already covered by existing test at line 188, but add explicit message assertion:
liveIt('genuinely missing parent still says "genuinely missing" — 6jp regression', async () => {
  const result = await safeDispatch('zk_save_card', {
    body: 'm07-genuinely-missing-regression',
    kind: 'fact',
    trunk: 5,
    mode: 'fork',
    fromAddress: '5/9999z9',
  });
  expect(result.isError).toBe(true);
  expect(result.content[0].text).toMatch(/genuinely missing/);
  expect(result.content[0].text).not.toMatch(/timed out/i);
});
```

#### 🟢 Green: Minimal Implementation

No constant exported from `apps/silmari-mcp/src/lib/br-adapter.ts` — the parent-resolution timeout is read at call time inside `resolveExplicitTarget` / `listForParent` in `card-ops.ts`, not at module-load time. This avoids the bun:test module-scope freeze trap (`process.env` set in a test body after import is already too late for a module-scope read).

Update `resolveExplicitTarget` in `apps/silmari-mcp/src/lib/card-ops.ts`:

```typescript
// Add import at top of card-ops.ts (no TIMEOUT_RESOLVE_PARENT — read inline at call time):
import { brList, brShow, brCreate, brLabelAdd, BrListTimeoutError } from './br-adapter.js';

// Replace the two brList calls in resolveExplicitTarget (lines 673-694):

function resolveExplicitTarget(...): ExplicitTarget | null {
  // ... existing validation ...

  // Read at call time — module-scope const would be frozen at import time in bun:test
  const resolveParentTimeout = Number(process.env.SILMARI_RESOLVE_PARENT_TIMEOUT_MS ?? '1500');

  let matches: any[];
  try {
    matches = brList({
      box: 'idea',
      labels: [fzLabel(trunk, parsed.sequence)],
      limit: 2,
      all: true,
      timeoutMs: resolveParentTimeout,
    });
  } catch (err) {
    if (err instanceof BrListTimeoutError) {
      throw new Error(
        `parent lookup timed out for ${fromAddress} — br list did not complete within ${resolveParentTimeout}ms (store contention or slow label index)`,
      );
    }
    throw err;
  }

  if (matches.length === 0) {
    // 929 WAL-race retry — genuine empty, not a timeout
    Bun.sleepSync(100);
    try {
      matches = brList({
        box: 'idea',
        labels: [fzLabel(trunk, parsed.sequence)],
        limit: 2,
        all: true,
        timeoutMs: resolveParentTimeout,
      });
    } catch (err) {
      if (err instanceof BrListTimeoutError) {
        throw new Error(
          `parent lookup timed out on WAL-race retry for ${fromAddress} — br list did not complete within ${resolveParentTimeout}ms`,
        );
      }
      throw err;
    }
  }

  if (matches.length === 0) {
    throw new Error(
      `no parent card exists at ${fromAddress} (after WAL-race retry — fork target genuinely missing)`,
    );
  }
  // ... rest unchanged ...
}
```

#### 🔵 Refactor

Extract the brList-with-timeout-guard into a helper to avoid duplication:

```typescript
function listForParent(fzLbl: string): any[] {
  // Read at call time — module-scope const would be frozen at import time in bun:test
  const timeout = Number(process.env.SILMARI_RESOLVE_PARENT_TIMEOUT_MS ?? '1500');
  try {
    return brList({ box: 'idea', labels: [fzLbl], limit: 2, all: true, timeoutMs: timeout });
  } catch (err) {
    if (err instanceof BrListTimeoutError) {
      throw new Error(`parent lookup timed out for label ${fzLbl} (${timeout}ms)`);
    }
    throw err;
  }
}
```

Then `resolveExplicitTarget` calls `listForParent` twice with the sleep in between.

### Success Criteria

**Automated:**
- [ ] Timeout test fails before implementation (no BrListTimeoutError path in resolveExplicitTarget)
- [ ] `bun test apps/silmari-mcp/tests/zk-save-card-fromaddress.test.ts` — all tests pass including 2 new m07 cases
- [ ] Existing 6jp tests at line 188 and 200 still pass (genuinely-missing path unchanged)
- [ ] `bun test` — full suite green

**Manual:**
- [ ] Set `SILMARI_RESOLVE_PARENT_TIMEOUT_MS=1`, save a card, fork from it → error says "timed out"
- [ ] Unset env var, fork from nonexistent address → error says "genuinely missing"

---

## Behavior 3: Labels table has composite `(label, issue_id)` index (beads_rust Fix 3)

**Given**: the labels table schema is applied  
**When**: `sqlite_master` is queried  
**Then**: an index on `(label, issue_id)` exists — making EXISTS subquery a covering-index lookup

**Given**: `br list --label fz:1_7` is run against a store with 150+ cards  
**When**: query executes  
**Then**: EXPLAIN QUERY PLAN shows `SEARCH labels USING COVERING INDEX` (not `SCAN issues`)

### TDD Cycle

#### 🔴 Red: Write Failing Test

**File**: `vendor/beads_rust/tests/storage_list_filters.rs` (add at top of test file)

```rust
#[test]
fn labels_table_has_covering_index_for_label_lookup() {
    let storage = test_db();
    assert!(
        storage.index_exists("idx_labels_for_label_lookup"),
        "Expected composite index (label, issue_id) on labels table — got none. \
         Add: CREATE INDEX IF NOT EXISTS idx_labels_for_label_lookup ON labels(label, issue_id)"
    );
}
// Note: EXPLAIN QUERY PLAN test dropped — fragile (SQLite version-dependent plan text varies across CI/dev)
```

#### 🟢 Green: Minimal Implementation

**File**: `vendor/beads_rust/src/storage/schema.rs` — add one line after line 128:

```sql
    CREATE INDEX IF NOT EXISTS idx_labels_label ON labels(label);
    CREATE INDEX IF NOT EXISTS idx_labels_issue ON labels(issue_id);
    CREATE INDEX IF NOT EXISTS idx_labels_for_label_lookup ON labels(label, issue_id);
```

No query changes needed. SQLite's query planner will automatically use the covering index for the EXISTS subquery.

The `count_issues_with_filters` function at `sqlite.rs:2099` (identical label filter logic) also benefits automatically.

**File**: `vendor/beads_rust/src/storage/sqlite.rs` — add `#[cfg(test)]` helper (exposes structural assertion without making `conn` public in production):

```rust
#[cfg(test)]
impl SqliteStorage {
    pub fn index_exists(&self, name: &str) -> bool {
        let rows = self.conn.query_with_params(
            "SELECT 1 FROM sqlite_master WHERE type='index' AND name=?",
            &[SqliteValue::from(name)],
        )
        .unwrap_or_default();
        !rows.is_empty()
    }
}
```

#### 🔵 Refactor

No refactor needed. The index addition is a one-liner. Migration: SQLite applies `CREATE INDEX IF NOT EXISTS` idempotently on existing databases — the index will be created on next connection open for existing stores.

### Success Criteria

**Automated:**
- [ ] `cargo test -p beads_rust --test storage_list_filters labels_table_has_covering_index` fails before schema change
- [ ] Index existence test passes after adding `CREATE INDEX` line + `#[cfg(test)] impl SqliteStorage { index_exists }` helper
- [ ] `cargo test -p beads_rust` — full Rust test suite green

**Manual:**
- [ ] On the post-run store: `time br list --label fz:1_7` completes in <100ms (down from ~700ms)
- [ ] Verify: `sqlite3 store.db ".indexes labels"` shows `idx_labels_for_label_lookup`

---

## Behavior 4: All four `zk_save_cards` callTool calls pass `opts.timeout` (5xj fix)

**Given**: `saveCardTree` is called for any of the four tiers (thesis, themes, ideas, micros)  
**When**: `callTool("zk_save_cards", ...)` is invoked  
**Then**: the call includes `{ timeout: SAVE_CARDS_TIMEOUT_MS }` — NOT the 60s SDK default

**Edge cases**: timeout must be set per-call (not just for the largest tier); thesis batch (1 card) should still have the extended timeout since server-side post-pass work is the bottleneck

### TDD Cycle

#### 🔴 Red: Write Failing Test

The current `ingest-cascade.test.ts` tests pure helpers (no MCP client). We need to test that `saveCardTree` passes timeout opts. The cleanest approach: extract a `buildSaveCardTreeCalls` helper that returns the callTool args, then assert on those args.

**File**: `scripts/kc-baker-pipeline-v2/ingest/ingest-cascade.ts` — extract a pure function:

```typescript
// Add after GATE_B_MCP_TIMEOUT_MS constant:
export const SAVE_CARDS_TIMEOUT_MS = Number(
  process.env.SAVE_CARDS_TIMEOUT_MS ?? "180000"  // 3min — matches Gate B
);
```

**File**: `scripts/kc-baker-pipeline-v2/tests/ingest-cascade.test.ts` (add new describe block)

```typescript
import { SAVE_CARDS_TIMEOUT_MS, type CallToolFn } from '../ingest/ingest-cascade.js';

describe('saveCardTree — timeout opts wired to all tiers (bd 5xj)', () => {
  it('SAVE_CARDS_TIMEOUT_MS constant is defined and > SDK default (60000)', () => {
    expect(SAVE_CARDS_TIMEOUT_MS).toBeGreaterThan(60000);
  });

  it('callTool receives opts.timeout for all four tiers', async () => {
    // Track all callTool invocations
    const calls: Array<{ name: string; opts?: { timeout?: number } }> = [];
    
    const fakeCallTool: CallToolFn = async (_client, name, _args, opts) => {
      calls.push({ name, opts });
      // Return minimal valid shape for each tier
      if (name === 'zk_save_cards') {
        return [{ id: 'zk-fake', fz: '5/1', wasSweepDeleted: false, reinforcedId: null }];
      }
      return [];
    };
    
    // Import saveCardTree internalized test variant (see Green phase)
    const { saveCardTreeWithCallTool } = await import('../ingest/ingest-cascade.js');
    await saveCardTreeWithCallTool(fakeCallTool, null as any, {
      themes: { themes: [{ theme_title: 'T', theme_summary: 'S' }] },
      ideas: { ideas: [] },
      micros: { micros: [] },
      trunk: 5,
      basename: 'test-transcript',
    });
    
    const saveCardsCalls = calls.filter(c => c.name === 'zk_save_cards');
    expect(saveCardsCalls.length).toBe(2); // thesis + themes (ideas/micros empty)
    
    for (const call of saveCardsCalls) {
      expect(call.opts?.timeout).toBeDefined();
      expect(call.opts!.timeout).toBeGreaterThan(60000);
    }
  });
});
```

#### 🟢 Green: Minimal Implementation

**File**: `scripts/kc-baker-pipeline-v2/ingest/ingest-cascade.ts`

Step 1 — add constant after `GATE_B_MCP_TIMEOUT_MS` (line ~201):
```typescript
export const SAVE_CARDS_TIMEOUT_MS = Number(
  process.env.SAVE_CARDS_TIMEOUT_MS ?? "180000",
);
```

Step 2 — add `opts` to all four callTool calls:

```typescript
// Tier 1 (line 357):
const thesisBatch = await callTool<SaveResult[]>(client, "zk_save_cards", {
  cards: [{ ... }],
}, { timeout: SAVE_CARDS_TIMEOUT_MS });

// Tier 2 (line 385):
: await callTool<SaveResult[]>(client, "zk_save_cards", { cards: themeCardsArr }, { timeout: SAVE_CARDS_TIMEOUT_MS });

// Tier 3 (line 419):
: await callTool<SaveResult[]>(client, "zk_save_cards", {
    cards: ideaInputs.map((i) => i.card),
  }, { timeout: SAVE_CARDS_TIMEOUT_MS });

// Tier 4 (line 452):
: await callTool<SaveResult[]>(client, "zk_save_cards", {
    cards: microInputs.map((m) => m.card),
  }, { timeout: SAVE_CARDS_TIMEOUT_MS });
```

Step 3 — add type aliases and export `saveCardTreeWithCallTool` for test injection:

```typescript
// Type aliases — add before the function, both exported so the test can import them:
export type SaveCardTreeInput = IngestInputs;

export type CallToolFn = <T>(
  client: Client,
  name: string,
  args: Record<string, unknown>,
  opts?: { timeout?: number },
) => Promise<T>;

// Extract to testable form — explicit callToolFn and client as parameters:
export async function saveCardTreeWithCallTool(
  callToolFn: CallToolFn,
  client: Client,
  inp: SaveCardTreeInput,
): Promise<SaveCardTreeResult> {
  // ... existing body, replacing `callTool(client, ...)` with `callToolFn(client, ...)` ...
}

// Keep the production wrapper (passes callTool and client through directly):
async function saveCardTree(client: Client, inp: SaveCardTreeInput) {
  return saveCardTreeWithCallTool(callTool, client, inp);
}
```

#### 🔵 Refactor

After green: verify `SAVE_CARDS_TIMEOUT_MS` appears exactly once (the constant) and the four call sites reference it consistently. No other changes needed.

### Success Criteria

**Automated:**
- [ ] `SAVE_CARDS_TIMEOUT_MS` constant test passes immediately (no impl change needed)
- [ ] opts.timeout test fails before Step 2 (no opts passed to callTool)
- [ ] `bun test scripts/kc-baker-pipeline-v2/tests/ingest-cascade.test.ts` — all 5xj tests pass
- [ ] `bun test` — full suite green

**Manual:**
- [ ] Re-run cascade against 5 transcripts; verify no MCP -32001 timeout errors in cascade log
- [ ] Verify `GATE_B_MCP_TIMEOUT_MS` and `SAVE_CARDS_TIMEOUT_MS` can be tuned independently via env

---

## Integration Sequence

Run in this order (each depends on the previous):

1. **Fix 1+2** — `br-adapter.ts` changes + `card-ops.ts` changes  
   → `bun test apps/silmari-mcp/tests/br-adapter.test.ts`  
   → `bun test apps/silmari-mcp/tests/zk-save-card-fromaddress.test.ts`  

2. **Fix 3** — `schema.rs` composite index  
   → `cargo test -p beads_rust`  
   → Manual: `time br list --label fz:1_7` against post-run store  

3. **Fix 4** — `ingest-cascade.ts` timeout opts  
   → `bun test scripts/kc-baker-pipeline-v2/tests/ingest-cascade.test.ts`  

4. **Full regression** — `bun test` + short cascade smoke run  
   → No new ETIMEDOUT or "genuinely missing" errors  
   → No new 60s MCP timeout (-32001) errors  

---

## References

- Research: `thoughts/searchable/shared/research/2026-04-26-cascade-rerun-5xj-m07-research.md`
- Prior plan: `thoughts/searchable/shared/plans/2026-04-26-17-56-tdd-three-fix-cascade-stabilization.md`
- bd 5xj (MCP timeout): `bd show silmari-agent-memory-5xj`
- bd m07 (cursor/parent drift): `bd show silmari-agent-memory-m07`
- Source: `apps/silmari-mcp/src/lib/br-adapter.ts:45,321,352`
- Source: `apps/silmari-mcp/src/lib/card-ops.ts:673-719`
- Source: `vendor/beads_rust/src/storage/sqlite.rs:1909`
- Source: `vendor/beads_rust/src/storage/schema.rs:127-128`
- Source: `scripts/kc-baker-pipeline-v2/ingest/ingest-cascade.ts:199-201,357,385,419,452`
