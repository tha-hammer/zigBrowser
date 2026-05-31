---
date: "2026-04-13T00:00:00-04:00"
reviewer: Codex
plan_reviewed: "thoughts/searchable/shared/plans/2026-04-13-tdd-algorithm-v381-phase0-zk-save-card-fromaddress.md"
status: needs_minor_revision
---

# Plan Review: Algorithm v3.8.1 Phase 0 - `zk_save_card` `fromAddress` Plumbing

## Review Summary

| Category | Status | Issues Found |
|----------|--------|--------------|
| Contracts | :warning: | 2 warnings - validation ordering, parent target domain |
| Interfaces | :warning: | 1 warning - MCP change may leave CLI save surface out of sync |
| Promises | :warning: | 1 warning - failure semantics after allocation are underspecified |
| Data Models | :warning: | 1 warning - reserved register addresses are not addressed |
| APIs | :warning: | 1 warning - schema/runtime contract split needs to be made explicit |

---

## Findings

### 1. Warning: explicit-target validation must be ordered before the dedup early-return

**What the plan promises:** invalid explicit-target requests should return a clear error instead of silently degrading or succeeding. That promise appears in the desired end state and Behavior 4 error-path expectations.

**Current reality:** `saveCard()` dedups before any folgezettel or `fromAddress` validation runs:

- `apps/silmari-mcp/src/lib/card-ops.ts:394-403` returns an existing card immediately on content-hash match
- the planned `normalizeFromAddress(...)` work appears later in the save flow at `thoughts/searchable/shared/plans/2026-04-13-tdd-algorithm-v381-phase0-zk-save-card-fromaddress.md:420-449`
- the plan's invalid-request contract is stated at `...fromaddress.md:77-82` and `...fromaddress.md:530-535`

**Why this matters:** if a caller sends an invalid `fromAddress` together with a body that already exists, a naive implementation that follows the plan's current sequencing can still return `{ wasDeduped: true }` instead of surfacing the validation error. All planned tests could pass while the public contract remains false for duplicate-body calls.

**Recommendation:** amend the plan so same-trunk/box/mode/address validation, and missing-parent validation for explicit-target saves, run before the dedup early-return on the explicit-target path. Add one regression test that uses a duplicate body plus an invalid `fromAddress` and asserts MCP `isError` instead of dedup success.

---

### 2. Warning: the allowed `fromAddress` target set is underspecified

**What the plan says:** `fromAddress` must resolve to an existing same-trunk parent card.

**What the codebase also says:** not every existing same-trunk address is a normal branching target.

- trunk Register addresses `N/0` are reserved in `apps/silmari-mcp/src/lib/folgezettel.ts:17-18`
- init code documents Register beads at reserved addresses in `apps/silmari-mcp/src/lib/init.ts:16-30`
- navigation intentionally excludes Register beads as non-navigation targets in `apps/silmari-mcp/src/lib/navigate.ts:204-206`
- neighborhood explicitly treats `N/0` as a special safe-empty case in `apps/silmari-mcp/src/lib/navigate.ts:315-318`
- the plan currently lists malformed address, trunk mismatch, biblio, root mode, and unresolved parent as invalid, but does not say whether `5/0` is valid or invalid: `...fromaddress.md:77-82`

**Why this matters:** the plan currently permits an interpretation where `fromAddress: "5/0"` is valid because it is same-trunk and exists. That would mix thought growth with reserved Register beads, which the rest of the repo treats as special index structures.

**Recommendation:** explicitly reject Register targets (`<trunk>/0` or any resolved `kind:register` parent), or explicitly document that they are allowed and why. The current codebase points strongly toward rejection.

---

### 3. Warning: parent lookup ambiguity is not covered by the contract

**Current behavior:** parent resolution is a label lookup with first-match semantics:

- `apps/silmari-mcp/src/lib/card-ops.ts:487-494` does `brList({ labels: [parentFzLabel], limit: 1, all: true })`

**Plan gap:** the plan says explicit-target saves should fail if the parent cannot be found, but it does not say what should happen if multiple cards share the same `fz:` label due to corruption, imports, or unexpected store state.

**Why this matters:** a first-match lookup is not a complete contract. For explicit targeting, "wrong parent but no error" is worse than "hard fail."

**Recommendation:** add one sentence to the plan that duplicate parent matches are treated as an error, not as "pick the first row." If the implementation wants to keep first-match behavior, that should be a deliberate documented choice rather than an accident of `limit: 1`.

---

### 4. Warning: failure semantics after allocation are underspecified

**Current behavior:** `assignFolgezettel()` writes the cursor file before `saveCard()` attempts `brCreate()`:

- cursor mutation happens in `apps/silmari-mcp/src/lib/folgezettel.ts:275-291`
- bead creation happens later in `apps/silmari-mcp/src/lib/card-ops.ts:457-466`

**Plan gap:** the plan clearly specifies hard-fail behavior for invalid explicit-target inputs, but it does not say whether later failures are transactional. A reader could assume "fail fast" means "no cursor movement on any failure," which is not how the current architecture works.

**Why this matters:** if `brCreate()` fails after allocation, the cursor can still advance and leave a gap. That may be acceptable, but it is a behavioral promise and should be stated.

**Recommendation:** add a short note that Phase 0 preserves the current non-transactional allocation model: explicit-target validation failures must abort before allocation, but post-allocation write failures may still leave cursor gaps. If transactional rollback is desired, that is a separate design change and should be planned explicitly.

---

### 5. Warning: the file plan should either include CLI parity or explicitly scope this phase to MCP only

**What the plan covers well:** the MCP server surface in `apps/silmari-mcp/src/index.ts`.

**What it does not mention:** the local CLI save wrapper builds `zk_save_card` requests separately and currently has no `fromAddress` flag:

- `apps/silmari-mcp/src/cli.ts:215-234`

**Why this matters:** if humans use `silmari save ...` during Phase 0, the CLI will lag behind the MCP contract even after the server work lands.

**Recommendation:** either add `apps/silmari-mcp/src/cli.ts` to the file plan and expose a `--from-address` flag, or explicitly mark Phase 0 as "MCP/API only; CLI parity deferred." The current plan reads like a public-interface change, not an MCP-only change.

---

## Well-Defined Parts

- The plan correctly identifies the three core implementation files: `folgezettel.ts`, `card-ops.ts`, and `index.ts`.
- The plan correctly recognizes that both allocation and structural-parent resolution must use the same normalized explicit target.
- The proposed dedicated integration file is a good fit for MCP-surface regression work and avoids further inflating the monolithic integration suite.
- Keeping `extractFolgezettelParent()` unchanged is the right abstraction boundary; the bug is in parent selection, not edge-type mapping.

---

## Suggested Plan Amendments

```diff
# In Behavior 3 / saveCard orchestration

+ Validate explicit-target requests before the content-hash dedup early-return.
+ Add a regression test: duplicate body + invalid fromAddress must return MCP error, not dedup success.
+ Reject Register targets (e.g. 5/0) explicitly, or state that they are intentionally supported.
+ Treat duplicate parent matches as an error instead of accepting first-match lookup.

# In Behavior 4 / public contract

+ State whether this phase is MCP-only or include CLI parity in apps/silmari-mcp/src/cli.ts.
+ Clarify that schema descriptions are advisory and runtime validation is authoritative unless conditional JSON Schema is added.

# In promises / failure semantics

+ Document that pre-allocation validation failures are hard-fail/no-write.
+ Document whether post-allocation brCreate failures may still advance the cursor.
```

---

## Approval Status

- [ ] **Ready for Implementation** - No issues found
- [x] **Needs Minor Revision** - Address the warnings above before proceeding
- [ ] **Needs Major Revision** - Critical issues must be resolved first
