---
date: 2026-04-17T11:00:00-04:00
reviewer: Silmari
git_commit: 3dff78230a4a9e1fa8a6b70f4ed14ff7a2aa8ae6
branch: main
repository: silmari-agent-memory
plan_reviewed: thoughts/searchable/shared/plans/2026-04-17-tdd-force-graph-edges-fix.md
related_research: thoughts/searchable/shared/research/2026-04-17-force-graph-edges-workaround.md
status: needs_minor_revision
tags: [review, tdd, beads-viewer, force-graph, edges, pre-implementation]
---

# Plan Review Report: 2026-04-17-tdd-force-graph-edges-fix

## Review Summary

| Category    | Status | Issues Found |
|-------------|--------|--------------|
| Contracts   | ⚠️     | 2 issues (new pattern precedent, return-shape convention) |
| Interfaces  | ⚠️     | 1 critical (viewer.js:2929 caller break, covered manually only) |
| Promises    | ⚠️     | 1 preexisting (no single-flight on /beads.sqlite3, S9 unmitigated) |
| Data Models | ✅     | 0 issues (schema well-specified) |
| APIs        | ✅     | 0 issues (no external APIs; internal link-builder contract clean) |

---

## Contract Review

### Well-Defined
- ✅ **`buildLinks(dependencies, cardEdges, nodeIds) → Link[]`** — pure function, deterministic, no async. Input/output shapes fully specified at plan §Phase 2.1. No error contract because no failure mode (operates on arrays, never throws).
- ✅ **`synthesizeEdgesFromLabels(dbPath) → SynthResult`** — unchanged signature, preserved `{ok, synthesized, error?}` envelope (`server.ts:108-112`). Matches existing `RefreshResult` (`server.ts:153`) + `ExportResult` (`server.ts:182-186`) convention.
- ✅ **`selectBlocksEdges(dependencies) → DependencyRow[]`** — pure filter, deterministic, no error path. Well-specified at plan §Phase 3.1.
- ✅ **Transaction scope.** Existing `synthesizeEdgesFromLabels` uses a single BEGIN/COMMIT spanning the entire batch (`server.ts:128, 143`) with best-effort ROLLBACK on throw (`server.ts:146`). Plan preserves this pattern — new CREATE TABLE happens before BEGIN, so schema creation is outside the transaction (correct, as DDL auto-commits in sqlite).
- ✅ **Duplicate-handling fix.** Current code uses plain `INSERT` — a duplicate `ref:X:Y` label across two cards would throw UNIQUE violation (today the table has no UNIQUE constraint so this doesn't fire, but if anyone added a PK later it'd abort the whole batch). The plan's `INSERT OR IGNORE` on the new `card_edges` PK (source, target, type) is a **real** improvement that retires research doc §3 S8.

### Missing or Unclear

#### ⚠️ Issue 1: `CREATE TABLE IF NOT EXISTS` is a first-of-kind pattern in server.ts
**What**: `server.ts` currently does **zero** `CREATE TABLE` statements — the `dependencies` and `issues` tables are assumed pre-existing (written by `bv --export-pages` upstream). The plan's `CREATE TABLE IF NOT EXISTS card_edges` introduces a new responsibility: the server now owns partial schema, not just writes.

**Impact**: Minor, but worth noting in the plan's "New patterns introduced" section so future maintainers understand why `server.ts` suddenly has DDL. If `bv` ever adds native `card_edges` creation upstream, the two schema definitions could drift.

**Recommendation**: Add a brief note in plan §Phase 1 Scope: "This introduces the first `CREATE TABLE` in `server.ts`. Rationale: `bv --export-pages` doesn't know about silmari's synthesized-edge concept; owning the schema server-side is the right division of concerns. Future: if `bv` adds native support, remove this CREATE and let the upstream schema take over."

**Severity**: ⚠️ Warning — not blocking; just prevents future confusion.

#### ⚠️ Issue 2: `buildLinks` return-shape diverges from server-side `*Result` envelope
**What**: All three server-side functions (`synthesizeEdgesFromLabels`, `refreshSnapshotConfig`, `ensureExport`) return `{ok, error?, <payload>}` envelopes. The plan's `buildLinks` returns a bare `Link[]`. Arguably fine because `buildLinks` is a pure client-side JS function (no I/O, no throw path) — but the divergence is worth acknowledging so future additions to `link-builder.js` don't default to the bare-array shape out of mimicry.

**Recommendation**: No code change; add a one-liner to the plan's Phase 2.1 Green section: "Bare-array return is deliberate — `buildLinks` is pure-compute with no failure mode. Future functions in `link-builder.js` that DO have failure modes should follow the `{ok, error?}` envelope per `server.ts` convention."

**Severity**: ⚠️ Warning — style/precedent; non-blocking.

---

## Interface Review

### Well-Defined
- ✅ **`globalThis.LB = { buildLinks }` browser-global pattern.** Matches `globalThis.GH` (`graph-helpers.js:67-69`), `globalThis.VM` (`viewmodel.js:313-333`), `globalThis.V` (`vocab.js:146-148`), `globalThis.Threads` (`threads.js:42`) — all use `typeof globalThis !== 'undefined'` guard with inline object literal. Plan matches.
- ✅ **Script load order.** `index.html:4421-4424` loads `vocab.js`, `viewmodel.js`, `graph-helpers.js`, `threads.js` as `type="module"` BEFORE `viewer.js` (plain script at `:4427`). Adding `<script type="module" src="link-builder.js">` at line 4423 keeps `globalThis.LB` set before `viewer.js` can reference it. `graph.js` is dynamically imported (`this.forceGraphModule`), loaded even later. Safe.
- ✅ **Test file convention.** `link-builder.test.js` matches `graph-helpers.test.js:7-8` and `viewmodel.test.js:7-8`: `import { describe, it, expect } from 'bun:test'` + named ES import from the module-under-test. Bun:test does NOT go through `globalThis`. Correct.
- ✅ **`selectBlocksEdges` exposed via existing `GH` namespace.** Plan appends to `graph-helpers.js:68 globalThis.GH = { kindColor, kindSize, edgeLinkColor, selectBlocksEdges }` — matches in-place extension pattern, no new module needed for one function.

### Missing or Unclear

#### ❌ Issue 3 (CRITICAL): `viewer.js:2929` positional-arg breakage has no automated test coverage
**What**: Current callsite passes 3 positional args: `this.forceGraphModule.loadData(issues, dependencies, precomputedLayout);` (`viewer.js:2929`). Proposed new signature: `loadData(issues, dependencies, cardEdges = [], layout = precomputedLayout)`. Without also updating the callsite, `precomputedLayout` would bind to the new `cardEdges` parameter — the force-graph receives the layout object AS IF it were cardEdges, and iteration over it in `buildLinks` throws or produces garbage.

The plan DOES direct the implementer to update `viewer.js:2929` to `loadData(issues, dependencies, cardEdges, precomputedLayout)`. But this update is only guarded by manual browser verification ("Open viewer in browser; check console — no errors" at Success Criteria 2.2). If the implementer forgets, no unit test catches it.

**Additional risk**: `graph-demo.html:661` passes only 2 args: `Graph.loadData(issues, dependencies);` — unaffected today, but if ANY future caller passes 3 args thinking the 3rd is layout, same trap.

**Impact**: Implementation-time footgun. Deploy-time catastrophe if manual verify is skipped.

**Recommendation**: Add to Phase 2 a unit-test-like assertion OR restructure the signature:
- **Option A (preferred)**: change signature to options-object: `loadData({issues, dependencies, cardEdges = [], layout = precomputedLayout})`. All callers must update (but the change is mechanical and type-safe). Eliminates positional trap entirely.
- **Option B**: keep positional, add an explicit TypeScript/JSDoc assertion at the top of `loadData`: `if (Array.isArray(cardEdges) === false && cardEdges && cardEdges.constructor !== Array) { throw new TypeError('loadData: cardEdges must be array — did caller pass layout in the 3rd position?'); }`. Throws loudly instead of silently breaking.
- **Option C (minimum)**: add a test that imports `loadData`, mocks the force-graph, and calls with 3 args where the 3rd is a plain object (not array) — asserts the function throws or logs a warning.

**Severity**: ❌ Critical — highest blast radius of any plan issue. Must be addressed before implementation.

#### ⚠️ Issue 4: JSDoc `@typedef` is a first-of-kind convention in viewer_assets
**What**: Plan §Phase 2.1 Refactor says "Add a JSDoc `@typedef` for the link object shape so the callsite in graph.js can rely on it." Grep confirms **zero existing `@typedef`** across `viewer_assets/`. This would be a new convention.

**Recommendation**: Either drop the Refactor step (JS with no typedef is the current convention) or upgrade it to "introduce @typedef convention starting with link-builder.js — document this in a CONVENTIONS.md". Don't silently add the first typedef without naming the precedent-setting decision.

**Severity**: ⚠️ Warning — convention drift risk.

---

## Promise Review

### Well-Defined
- ✅ **Synchronous behavior.** All new functions (`buildLinks`, `selectBlocksEdges`) are synchronous, no promise contract needed.
- ✅ **Transaction idempotency.** `synthesizeEdgesFromLabels` re-run is idempotent via `CREATE TABLE IF NOT EXISTS` + `INSERT OR IGNORE` on PK `(source, target, type)`. Plan §Phase 1 Behavior 1.3 covers this.
- ✅ **Cache-hash order.** `ensureExport` runs synth (`server.ts:226`) BEFORE hash refresh (`server.ts:229`) — sha256 reflects synthesized rows, so SPA OPFS cache key correctly invalidates.

### Missing or Unclear

#### ⚠️ Issue 5: Preexisting S9 concurrency risk NOT mitigated by plan
**What**: Research doc §3 S9 flagged: "`synthesizeEdgesFromLabels` opens the cache sqlite read-write while the HTTP handler concurrently serves `/beads.sqlite3` to SPA clients." The concurrency audit confirms: `ensureExport` (`server.ts:208-237`) has **zero** single-flight protection — no mutex, no in-flight promise cache, no debounce. Two simultaneous cache-miss GET requests each spawn their own `bv --export-pages` child process, each call `synthesizeEdgesFromLabels` and `refreshSnapshotConfig` against the same cache file.

Plan §Phase 1/2/3 adds to the synthesis pipeline (new table + INSERT OR IGNORE + select-blocks-only) but does NOTHING to mitigate the concurrency race. This is preexisting behavior; the plan doesn't worsen it, but also doesn't address it despite the research doc surfacing it.

**Impact**: Under concurrent load (realistic during a client's first open that fires several parallel requests — the SPA does exactly this), two synthesizers could race on the same sqlite file. SQLite WAL serializes writers, so no corruption — but the second synthesizer may see stale/partial state from the first's in-progress transaction, or the HTTP file-stream handler at `server.ts:317` may stream bytes mid-write producing a truncated sqlite file to the SPA.

**Recommendation**: Either:
- **(a)** Explicitly mark S9 as **out of scope** in the plan's "What We're NOT Doing" table with rationale ("preexisting; separate workstream will add single-flight to ensureExport"). Acknowledges the gap without expanding scope.
- **(b)** Add a Phase 5 for single-flight mitigation: wrap `ensureExport` in a module-level promise cache (`let inFlight: Promise<ExportResult> | null = null; if (inFlight) return inFlight; inFlight = doExport(); ...`). Classic pattern, ~15 LOC. Low risk.

**Severity**: ⚠️ Warning — preexisting, not introduced. But a TDD plan that documents the symptom in prose then ignores it in code is internally inconsistent.

---

## Data Model Review

### Well-Defined
- ✅ **`card_edges` schema fully specified.** Columns, types, PK, NOT NULL constraints all in plan §Phase 1.1.
- ✅ **Fresh-cache compatibility.** `sqlite_master` existence check (plan §Phase 2.2 Change 1) handles the pre-Phase-1 cache that has no `card_edges` table.
- ✅ **Self-migrating.** Cache sqlite is regenerated every `bv --export-pages`; no user-facing migration script needed. Plan §Overview addresses this.
- ✅ **PK composition reasonable.** `(source, target, type)` allows multiple edge types between the same pair (`zk-a blocks zk-b` AND `zk-a supports zk-b` — two edges). Tested in Phase 2.1's "emits two distinct links when same (source,target) appears in both tables" case.

### Missing or Unclear

**None.** Data model is the most complete part of the plan.

---

## API Review

No external (HTTP/REST) API changes. Internal module boundaries (link-builder, graph-helpers, server synthesis) reviewed under Contracts/Interfaces above. **No review needed for this category.**

---

## Review of Edge-Case Test Reclassification

Plan §Phase 1 "additional edge-case tests (required before merge)" lists 8 cases. Per contract audit:

| Test | Assertion | Existing guard in server.ts | Classification |
|------|-----------|----------------------------|----------------|
| Invalid edge type (`ref:bogus-type:x`) | Skipped | `parseRefLabel:101` validates against `VALID_EDGE_TYPES` | **Regression test** on existing guard |
| Malformed target (`ref:supports:zk with space`) | Skipped | `parseRefLabel:102` regex | **Regression test** |
| Empty labels `'[]'` | No rows, no error | `server.ts:131-134` guards | **Regression test** |
| Null labels column | Row skipped | `server.ts:131` `!row.labels` check | **Regression test** |
| Non-array labels JSON | Skipped | `server.ts:134` `Array.isArray` | **Regression test** |
| Self-edge (`zk-a → zk-a`) | Inserted | No existing guard — decision point | **New behavior — DOCUMENT** |
| Duplicate across 2 cards | 2 distinct rows | No existing guard — new | **New behavior** |
| Duplicate on same card | 1 row via INSERT OR IGNORE | Currently: plain INSERT would THROW | **New behavior (real fix for S8)** |

**Recommendation**: Reclassify the list. Tests 1-5 are regression guards over pre-existing `parseRefLabel` and JSON-parse defense. Tests 6-8 genuinely test new `card_edges`-specific behavior. The plan should say "The first 5 tests guard existing behavior through the new code path; the last 3 test new invariants." Currently the plan implies all 8 are new-behavior tests.

---

## Critical Issues (Must Address Before Implementation)

1. **Issue 3: `viewer.js:2929` positional-arg break has no automated coverage.** If the implementer skips the manual browser check, deploy goes out with broken force-graph rendering (layout object bound to cardEdges parameter). **Must add**: either change to options-object signature (my preferred fix), add defensive type-check + throw, or add an explicit unit test that would fail if the callsite isn't updated.

---

## Suggested Plan Amendments

```diff
# In §Phase 1 Scope:

+ Add: NEW PATTERN FLAG — This phase introduces the first `CREATE TABLE`
+   statement in `server.ts`. Rationale: `bv --export-pages` doesn't know
+   about silmari's synthesized-edge concept, so schema ownership for
+   `card_edges` lives server-side. Document in the commit message so
+   future maintainers know this isn't drift.

# In §Phase 1 "additional edge-case tests" header:

+ Add: Classification note — tests 1-5 are regression guards exercising
+   existing `parseRefLabel` + JSON-parse guards through the new code path.
+   Tests 6-8 test new `card_edges`-specific invariants.

# In §Phase 2.1 Refactor:

~ Modify: "Add JSDoc @typedef..." → either drop, OR upgrade to:
~   "Introduce @typedef convention starting with link-builder.js.
~    Document in viewer_assets/CONVENTIONS.md that from 2026-04-17 forward,
~    new modules SHOULD use @typedef for non-trivial shapes."

# In §Phase 2.1 Green (buildLinks):

+ Add: NOTE — Bare-array return is deliberate; buildLinks is pure-compute
+   with no failure mode. Future functions in link-builder.js that DO have
+   failure modes should follow the {ok, error?} envelope per server.ts
+   convention.

# In §Phase 2.2 Change 2 (loadData signature):

~ Modify: prefer options-object signature over positional to eliminate
~   the viewer.js:2929 trap:
~     BEFORE: loadData(issues, dependencies, cardEdges = [], layout = precomputedLayout)
~     AFTER:  loadData({ issues, dependencies, cardEdges = [], layout = precomputedLayout })
~   OR retain positional but add:
~     if (cardEdges && !Array.isArray(cardEdges)) {
~       throw new TypeError('loadData: cardEdges must be array — caller may have passed layout as 3rd arg');
~     }
~   OR add an automated test (Behavior 2.2b) that mocks the force-graph
~   module and asserts the callsite at viewer.js:2929 passes 4 positional
~   args (grep-based test: read viewer.js, regex for loadData(, assert 4-arg form).

# In §Phase 2 "What We're NOT Doing" (currently top-level table):

+ Add row: "Fix `ensureExport` single-flight / mutual-exclusion around
+   `synthesizeEdgesFromLabels` | Preexisting S9 — no single-flight
+   protection today. Out of scope; track as separate workstream
+   (see research doc §3 S9). This plan's schema split does NOT worsen
+   the race, but also does not fix it. Concurrent /beads.sqlite3
+   requests remain an un-mitigated risk."

# In §Integration & E2E "Regression scenarios to try":

+ Add: Concurrency scenario — fire 3-5 parallel curl /beads.sqlite3
+   requests within 200ms while the cache is empty. Verify: no corrupted
+   sqlite served, no crash, card_edges table is complete in the final
+   cache. (This will fail intermittently today. Documenting the expected
+   failure is the fix for this plan; a later plan fixes ensureExport.)

# In §Phase 3 (WASM filter) — sql.js terminology accuracy:

~ Modify: research doc §7 open question #1 referenced "parse time" —
~   the correct term is "prepare-time name resolution" (sqlite3_prepare_v2).
~   WHERE EXISTS guard still doesn't work, but via prepare-time binding,
~   not parse. Small correction in the research doc, not the plan.
```

---

## Approval Status

- [ ] **Ready for Implementation** - No critical issues
- [x] **Needs Minor Revision** - Address the viewer.js:2929 signature risk (Issue 3) before coding. All other findings are quality-of-life improvements that can land alongside.
- [ ] **Needs Major Revision** - Critical issues must be resolved first

**Summary**: The plan is architecturally sound — the schema split cleanly retires the 5 symptoms it targets, the TDD structure is mostly disciplined, and the file:line refs spot-checked by three parallel audits all verify correct. The one blocking issue is the `viewer.js:2929` call-site fragility under the new positional signature; adopt the options-object signature (Option A in Issue 3's recommendations) or add an automated guard before writing code.

After Issue 3 is resolved and the six amendments above land, the plan is ready for implementation.

---

## Tracking

Per `/review_plan` protocol, a beads issue was NOT created because:
- No critical-blocking issues require standalone tracking.
- The one critical issue (Issue 3) is an amendment to the existing plan, not a new workstream.
- The preexisting S9 concurrency concern is a separate workstream candidate; create a beads issue for that if/when the team is ready to pick it up.

**Reviewer artifacts (for audit trail):**
- Contract/error audit of `server.ts` — findings above in Contract Review.
- Interface audit of `viewer_assets/` — findings above in Interface Review.
- Concurrency + sql.js behavior audit — findings above in Promise Review.
- All three audits ran in parallel as background Agent(general-purpose) subagents from the main review session.
