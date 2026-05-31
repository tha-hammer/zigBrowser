# Plan Review: brList Timeout + Cascade Fix TDD Plan

**Plan reviewed**: `2026-04-27-11-30-tdd-brlist-timeout-cascade-fixes.md`  
**Reviewed**: 2026-04-27  
**Method**: 4 parallel code research agents reading actual files; 28-criteria ISC evaluation

---

## Review Summary

| Category | Status | Issues Found |
|----------|--------|--------------|
| Contracts — Fix 1 (BrListTimeoutError) | ✅ | 0 |
| Contracts — Fix 2 (resolveExplicitTarget) | ❌ | 1 critical |
| Contracts — Fix 3 (Rust composite index) | ⚠️ | 1 critical, 1 warning |
| Contracts — Fix 4 (saveCardTree timeout) | ❌ | 2 critical |
| Line References (all 4 fixes) | ✅ | 0 — all accurate |
| Test Infrastructure | ✅ | 0 |
| Integration Sequence | ✅ | 0 |

**Approval Status:** ☐ Needs Minor Revision — 3 critical issues must be resolved before Fix 2, Fix 3, and Fix 4 tests will compile/run correctly. Fix 1 is ready as written.

---

## Line Reference Accuracy (Pre-check)

All plan line references verified against actual code. No discrepancies:

| Plan reference | Actual location | Verdict |
|---|---|---|
| `br-adapter.ts:45` TIMEOUT_READ = 500 | Line 45 confirmed | ✅ |
| `br-adapter.ts:337-341` execFileSync call | Lines 337-341 confirmed | ✅ |
| `br-adapter.ts:352-354` bare catch return `[]` | Lines 352-354 confirmed | ✅ |
| `card-ops.ts:673-694` two brList calls with 100ms sleep | Lines 673-693 confirmed | ✅ |
| `card-ops.ts:704-706` "genuinely missing" error text | Line 705 confirmed — exact text: `"fork target genuinely missing"` | ✅ |
| `schema.rs:127-128` two single-column indexes | Lines 127-128 confirmed, no composite exists | ✅ |
| `sqlite.rs:1924-1928` EXISTS correlated subquery | Lines 1924-1928 confirmed | ✅ |
| `sqlite.rs:2099` count_issues_with_filters | Lines 2104-2108 (slight offset) — same pattern confirmed | ✅ |
| `ingest-cascade.ts:199-201` GATE_B_MCP_TIMEOUT_MS | Lines 199-201 confirmed | ✅ |
| `ingest-cascade.ts:357,385,419,452` four callTool calls | All four lines confirmed | ✅ |

---

## Fix 1 — BrListTimeoutError Contract

### Well-Defined

- ✅ **BrListTimeoutError class** — clean extends-Error pattern with `.name` and `.message` containing timeoutMs; correct
- ✅ **BrListOpts.timeoutMs** — `BrListOpts` interface confirmed to have no existing `timeoutMs` field; insertion point is correct
- ✅ **`effectiveTimeout` fallback** — `opts.timeoutMs ?? TIMEOUT_READ` correctly defaults existing callers
- ✅ **`killed` discrimination** — `(err as NodeJS.ErrnoException & { killed?: boolean }).killed` is the standard Node.js/Bun mechanism for subprocess timeout; `execFileSync` throws with `killed: true` on SIGTERM
- ✅ **Non-timeout regression** — Plan explicitly keeps `catch { return []; }` for non-killed errors; genuine-empty callers are unaffected
- ✅ **Import destructuring** — Plan's proposed import matches the existing dynamic import pattern in `br-adapter.test.ts`
- ✅ **Test structure** — 3 test cases cover throw, instanceof check, and regression; all use real `br` binary (matches established pattern; no mocks)

### Missing / Unclear

None.

### Recommendation

Fix 1 is **ready for implementation as written**. No amendments needed.

---

## Fix 2 — resolveExplicitTarget Contract

### Well-Defined

- ✅ **Two brList calls** — both call sites confirmed at lines 673-678 and 688-693 with 100ms Bun.sleepSync between them
- ✅ **Error text discrimination** — plan uses `"timed out"` vs `"genuinely missing"` strings; the existing error at line 705 uses "fork target genuinely missing" (test regex `/genuinely missing/` matches)
- ✅ **listForParent refactor** — extracting the two identical catch blocks into a helper eliminates duplication correctly
- ✅ **Test helpers available** — `liveIt` confirmed at test line 33; `safeDispatch` confirmed at test line 38; both have correct signatures for the proposed tests
- ✅ **6jp regression** — existing tests at lines 188 and 200 exercise the "genuinely missing" path; adding message assertion (`expect(result.content[0].text).toMatch(/genuinely missing/)`) is safe

### Missing / Unclear — CRITICAL

**❌ ISC-10: Module-scope env var evaluated at import time**

The plan proposes:
```typescript
export const TIMEOUT_RESOLVE_PARENT =
  Number(process.env.SILMARI_RESOLVE_PARENT_TIMEOUT_MS ?? '1500');
```

This constant is evaluated **once**, when `br-adapter.ts` is first imported. In `zk-save-card-fromaddress.test.ts`, the module is loaded via dynamic import at the top of the file (lines 21-25), BEFORE any test body runs. Therefore, setting:
```typescript
process.env.SILMARI_RESOLVE_PARENT_TIMEOUT_MS = '1';
```
inside the `liveIt(...)` callback is **too late** — the constant is already `1500`. The 1ms timeout the test needs to trigger a `BrListTimeoutError` will never take effect. The test will pass vacuously (no timeout fires, no error thrown, assertion on error text never runs).

This is an instance of the documented bun-test module-scope issue (see `bd remember bun-test-module-scope-process-env-writes-persist`): module-scope `process.env` reads are fixed at import time.

**Fix:** Read the env var lazily inside the call, not at module scope:
```typescript
// In br-adapter.ts — NOT a module-scope constant:
export function getResolveParentTimeout(): number {
  return Number(process.env.SILMARI_RESOLVE_PARENT_TIMEOUT_MS ?? '1500');
}
```
Or inline in `resolveExplicitTarget`:
```typescript
// card-ops.ts — read at call time, not module load:
const resolveParentTimeout = Number(
  process.env.SILMARI_RESOLVE_PARENT_TIMEOUT_MS ?? '1500'
);
```
The second form (inline in the function body) is simpler, avoids exporting a function just for testability, and aligns with how `SILMARI_DIR` and similar vars are handled in the test suite.

### Recommendation

Add to Plan §Behavior 2 Green phase:
```diff
- export const TIMEOUT_RESOLVE_PARENT =
-   Number(process.env.SILMARI_RESOLVE_PARENT_TIMEOUT_MS ?? '1500');
+ // Read at call time so tests can override the env var in test body
+ // (module-scope reads are fixed at import time in bun:test)
```
Move the `process.env` read into `resolveExplicitTarget`'s function body (or `listForParent` helper body). Remove the `TIMEOUT_RESOLVE_PARENT` export since it won't be dynamically re-readable.

---

## Fix 3 — Rust Composite Index Contract

### Well-Defined

- ✅ **Schema change** — `CREATE INDEX IF NOT EXISTS idx_labels_for_label_lookup ON labels(label, issue_id)` is correct; insertion point after line 128 confirmed
- ✅ **Idempotency** — `IF NOT EXISTS` ensures existing stores are safe; no migration script needed
- ✅ **Both query sites benefit** — confirmed that `count_issues_with_filters` at lines 2104-2108 uses the identical EXISTS subquery; the covering index applies automatically to both
- ✅ **No query rewrite needed** — SQLite's query planner will pick the covering index for the EXISTS subquery automatically
- ✅ **test_db() available** — confirmed at `vendor/beads_rust/tests/common/mod.rs:82`

### Missing / Unclear — CRITICAL

**❌ ISC-20: `db.conn` is not accessible from external test code**

The plan's proposed Rust tests call `db.conn.query_with_params(...)` directly. In the actual test suite (`storage_list_filters.rs`, all 940 lines), every test calls **public API methods** on `SqliteStorage` (`storage.create_issue(...)`, `storage.list_issues(...)`, etc.). There are zero direct `db.conn.*` calls in test code — `conn` is used internally by `SqliteStorage` methods but is not a public field.

In Rust, struct fields are private by default. If `conn` has no `pub` annotation, external test code cannot access it, and the proposed tests will fail to compile with:
```
error[E0616]: field `conn` of struct `SqliteStorage` is private
```

Both proposed tests rely on `db.conn`:
- `labels_table_has_covering_index_for_label_lookup`: queries `sqlite_master` via `db.conn.query_with_params`
- `label_filter_query_uses_covering_index`: runs EXPLAIN QUERY PLAN via `db.conn.query_with_params`

**Fix options** (in order of preference):

**Option A — Test via the public API (simplest, no struct change):**
```rust
#[test]
fn labels_table_has_covering_index_for_label_lookup() {
    let storage = test_db();
    // Use storage.list_issues with a label filter as a functional proxy —
    // the index existence is implicit in correctness + the schema migration test below.
    // OR: seed 1000 issues and assert label filter completes quickly.
}
```
This loses the direct structural assertion but avoids exposing internals.

**Option B — Add a `#[cfg(test)]` helper method on `SqliteStorage`:**
```rust
#[cfg(test)]
impl SqliteStorage {
    pub fn index_exists(&self, name: &str) -> bool {
        let rows = self.conn.query_with_params(
            "SELECT 1 FROM sqlite_master WHERE type='index' AND name=?",
            &[SqliteValue::from(name)]
        ).unwrap_or_default();
        !rows.is_empty()
    }
}
```
Then in the test: `assert!(storage.index_exists("idx_labels_for_label_lookup"))`. This keeps `conn` private in production but opens it for test assertions via a scoped helper.

**Option C — Make `conn` pub (not recommended):** Exposes internals permanently.

**Recommendation:** Option B. It's idiomatic Rust (`#[cfg(test)]` helpers are standard), requires minimal code, and produces a clear assertion.

### Missing / Unclear — WARNING

**⚠️ ISC-21: EXPLAIN QUERY PLAN assertion may be fragile**

Even if `db.conn` were accessible, the assertion:
```rust
assert!(joined.contains("SEARCH labels") || joined.contains("COVERING INDEX"), ...)
```
depends on SQLite's EXPLAIN QUERY PLAN text format, which varies by SQLite version. Older SQLite emits `SCAN TABLE` vs `SEARCH TABLE`; newer versions emit different detail strings. CI may run a different SQLite than dev. The structural index existence test (Option B above) is more reliable than a query plan text assertion.

---

## Fix 4 — saveCardTree Timeout Contract

### Well-Defined

- ✅ **callTool 4th-arg pattern** — confirmed: `callTool<T>(client, name, args, opts?: { timeout?: number })` already accepts opts; `zk_propose_links_semantic` at line 527 already uses this exact pattern
- ✅ **SAVE_CARDS_TIMEOUT_MS constant** — adding and exporting this constant is clean; env override is appropriate test hook (this is a runtime constant, not module-scope-problem because it's only used as a value passed at call time, not as a condition evaluated at import)
- ✅ **All 4 call sites confirmed** — lines 357 (thesis), 385 (themes), 419 (ideas), 452 (micros) all confirmed; all currently have no opts arg
- ✅ **Existing test structure** — `ingest-cascade.test.ts` confirmed to exist and already imports from `ingest-cascade.ts`

### Missing / Unclear — CRITICAL (x2)

**❌ ISC-25a: `callToolFn: typeof callTool` is incompatible with the test's `fakeCallTool`**

The plan proposes:
```typescript
export async function saveCardTreeWithCallTool(
  callToolFn: typeof callTool,
  inp: SaveCardTreeInput,
)
```

The test provides:
```typescript
const fakeCallTool = async (
  _client: unknown,   // ← unknown, not Client
  name: string,
  _args: unknown,     // ← unknown, not Record<string, unknown>
  opts?: { timeout?: number }
) => { ... }
```

`typeof callTool` is `<T>(client: Client, name: string, args: Record<string, unknown>, opts?: { timeout?: number }) => Promise<T>`. The test's `fakeCallTool` with `_client: unknown` and `_args: unknown` is NOT assignable to this type — TypeScript will error.

The plan acknowledges this at the end of §Behavior 4 Green: *"Wait — `callTool` takes `client` as first arg. The test fake should accept the same signature. Adjust as needed."* But leaves it unresolved.

**Fix:** Define a `CallToolFn` type alias with looser types, or use the actual `typeof callTool` generic:
```typescript
// In ingest-cascade.ts:
type CallToolFn = <T>(
  client: Client,
  name: string,
  args: Record<string, unknown>,
  opts?: { timeout?: number },
) => Promise<T>;

export async function saveCardTreeWithCallTool(
  callToolFn: CallToolFn,
  client: Client,
  inp: SaveCardTreeInput,
): Promise<SaveCardTreeResult>
```

Note: `client` must also be a parameter since `callToolFn` needs it. The test can pass a dummy `null as unknown as Client` (TypeScript will be unhappy) OR the test can type `fakeCallTool` to match `CallToolFn`.

Simplest fix for the test:
```typescript
const fakeCallTool: CallToolFn = async (_client, name, _args, opts) => { ... }
```

**❌ ISC-25b: `SaveCardTreeInput` type does not exist**

The plan references `inp: SaveCardTreeInput` but this type is not currently defined in the codebase. The refactor requires defining this type as part of the Green phase. The plan omits this. Without it, `saveCardTreeWithCallTool` cannot be written.

Looking at the current `saveCardTree` function (which takes `client: Client, inp: IngestInputs`), the type would likely be `IngestInputs` plus any additional context. The plan needs to either:
- Reuse `IngestInputs` (simpler)
- Define `SaveCardTreeInput` explicitly (clearer interface)

**Fix:** Add to §Behavior 4 Green phase Step 3:
```typescript
// Add type alias (or reuse IngestInputs if it covers the same fields):
export type SaveCardTreeInput = IngestInputs;
// OR define the minimal shape if IngestInputs has fields saveCardTree doesn't need:
export interface SaveCardTreeInput {
  themes: ThemesOutput;
  ideas: IdeasOutput;
  micros: MicrosOutput;
  trunk: number;
  basename: string;
}
```

The test's hardcoded input (`{ themes: { themes: [...] }, ideas: { ideas: [] }, micros: { micros: [] }, trunk: 5, basename: 'test-transcript' }`) reveals the expected shape.

### Warning

**⚠️ ISC-25c: `saveCardTree` production wrapper loses type safety**

The plan's production wrapper is:
```typescript
async function saveCardTree(client: Client, inp: SaveCardTreeInput) {
  return saveCardTreeWithCallTool(
    (c, n, a, o) => callTool(c, n, a, o),
    inp,
  );
}
```

If `saveCardTreeWithCallTool` now takes `(callToolFn, client, inp)` (with `client` as separate param), the wrapper must also pass `client`. The plan omits this — check the parameter order when implementing.

---

## Integration Sequence

### Well-Defined

- ✅ Fix 1+2 before Fix 3 before Fix 4 — dependency order is correct and justified
- ✅ Full regression run last — appropriate gate

### Recommendations

None. Integration sequence is sound.

---

## Critical Issues Summary (Must Address Before Implementation)

### Issue 1 — Fix 2: Module-scope `TIMEOUT_RESOLVE_PARENT` env var (ISC-10)

**Impact:** The timeout test for `resolveExplicitTarget` will pass vacuously or fail for wrong reason — it will never actually force a 1ms timeout because the constant is frozen at module load time.

**Recommendation:** Move `process.env.SILMARI_RESOLVE_PARENT_TIMEOUT_MS` read to inside the `listForParent` helper body (or `resolveExplicitTarget` body). Remove the exported constant.

### Issue 2 — Fix 3: `db.conn` is private in `SqliteStorage` (ISC-20)

**Impact:** Both proposed Rust tests will fail to compile. The test strategy needs to change.

**Recommendation:** Add a `#[cfg(test)] impl SqliteStorage { pub fn index_exists(&self, name: &str) -> bool }` helper. Drop the EXPLAIN QUERY PLAN test (fragile and duplicative); keep only the structural assertion that the index exists by name.

### Issue 3 — Fix 4: `saveCardTreeWithCallTool` type mismatch + missing `SaveCardTreeInput` type (ISC-25a, ISC-25b)

**Impact:** TypeScript compilation fails. The test cannot provide a conformant `fakeCallTool` without the type alias, and `SaveCardTreeInput` is undefined.

**Recommendation:** Add `type CallToolFn = ...` and `type SaveCardTreeInput = IngestInputs` (or explicit interface) to ingest-cascade.ts as part of the Green phase. Type `fakeCallTool` as `CallToolFn` in the test.

---

## Suggested Plan Amendments

```diff
## Behavior 2 — Green phase (br-adapter.ts):

- export const TIMEOUT_RESOLVE_PARENT =
-   Number(process.env.SILMARI_RESOLVE_PARENT_TIMEOUT_MS ?? '1500');

## Behavior 2 — Green phase (card-ops.ts, in resolveExplicitTarget / listForParent):

+ // Read at call time — module-scope const would be frozen at import time
+ const timeout = Number(process.env.SILMARI_RESOLVE_PARENT_TIMEOUT_MS ?? '1500');

## Behavior 3 — Green phase (schema.rs) — add cfg(test) helper:

+ #[cfg(test)]
+ impl SqliteStorage {
+     pub fn index_exists(&self, name: &str) -> bool {
+         let rows = self.conn.query_with_params(
+             "SELECT 1 FROM sqlite_master WHERE type='index' AND name=?",
+             &[SqliteValue::from(name)]
+         ).unwrap_or_default();
+         !rows.is_empty()
+     }
+ }

## Behavior 3 — Red phase (storage_list_filters.rs) — replace db.conn with helper:

- let rows = db.conn.query_with_params("SELECT name FROM ...", &[]).unwrap();
- assert!(!rows.is_empty(), "Expected composite index...");
+ assert!(storage.index_exists("idx_labels_for_label_lookup"),
+     "Expected composite index (label, issue_id) — \
+      add: CREATE INDEX IF NOT EXISTS idx_labels_for_label_lookup ON labels(label, issue_id)");
# Drop the EXPLAIN QUERY PLAN test entirely — fragile, not needed

## Behavior 4 — Green phase (ingest-cascade.ts) — add type definitions:

+ export type SaveCardTreeInput = IngestInputs;  // or minimal explicit interface
+
+ type CallToolFn = <T>(
+   client: Client,
+   name: string,
+   args: Record<string, unknown>,
+   opts?: { timeout?: number },
+ ) => Promise<T>;
+
+ export async function saveCardTreeWithCallTool(
+   callToolFn: CallToolFn,
+   client: Client,        // ← client is a separate param, not captured
+   inp: SaveCardTreeInput,
+ ): Promise<SaveCardTreeResult>

## Behavior 4 — Red phase (ingest-cascade.test.ts):

- const fakeCallTool = async (
-   _client: unknown,
-   name: string, ...
- )
+ import type { CallToolFn } from '../ingest/ingest-cascade.js';
+ const fakeCallTool: CallToolFn = async (_client, name, _args, opts) => { ... }
```

---

## Non-Issues (Verified Sound)

- Fix 1 `killed` property discrimination — standard Node.js/Bun behavior; correct
- Fix 2 `liveIt`/`safeDispatch` helpers — confirmed present at expected lines
- Fix 2 `try/finally` env var restore pattern — established precedent in extraction-hardening.test.ts
- Fix 3 `IF NOT EXISTS` migration safety — idempotent for existing stores
- Fix 3 benefit to `count_issues_with_filters` — confirmed, same subquery at lines 2104-2108
- Fix 4 opts passing pattern — already used for `zk_propose_links_semantic` at line 527; proven working
- All 28 test success criteria in the plan — individually sound once the 3 critical issues are resolved
