---
date: 2026-04-22
author: Maceo Jourdan (with Silmari)
status: implemented
implementation-date: 2026-04-23
topic: "r04 — saveCard: pivot dedup-return to reinforce-and-save (framework invariant)"
tags: [silmari, saveCard, reinforces, r04, tdd]
bd: silmari-agent-memory-r04
parent-plan: thoughts/searchable/shared/plans/2026-04-22-tdd-silmari-cascade-extractor.md
---

# r04 TDD implementation plan — saveCard dedup→reinforce pivot

## Implementation status (2026-04-23)

**SHIPPED.** All 8 Observable Behaviors verified by 69 passing tests
across 3 files (`integration.test.ts`, `extraction-hardening.test.ts`,
`savecard-concurrency.test.ts`).

| Behavior | Status | Evidence |
|---|---|---|
| 1 — body-hash match → new card + reinforces + flag | ✅ | `integration.test.ts:281` |
| 2 — SaveCardResult contract `{id, fz, wasReinforced, priorId?, wasSweepDeleted}` | ✅ | All consumers migrated; type def at `card-ops.ts:174-184` |
| 3 — Tier A ordering preserved (extractors after brCreate) | ✅ | Implicit via `integration.test.ts:520` "combines body-mention and folgezettel-parent edges" |
| 4 — sweepDuplicates concurrency: keep both + reinforce + flag | ✅ | `savecard-concurrency.test.ts` (new) — uses SILMARI_DISABLE_FINDBYCONTENTHASH=1 seam |
| 5 — L4 anchor check log-only (no Sonnet, no auto-commit, no throw) | ✅ | `extraction-hardening.test.ts:150,288,330` (3 migrated tests) |
| 6 — biblio.ts + migrate-from-cosmic.ts + MCP tool description migrated | ✅ | All `wasDeduped` reads → `wasReinforced`; MCP description rewritten |
| 7 — third identical save → reinforces edge to anchor | ✅ | `integration.test.ts:300` "10 rapid sequential saves" |
| 8 — first save (no prior) → wasReinforced:false, no priorId | ✅ | `integration.test.ts:267` |

**Implementation notes:**
- L4 auto-fire removal was done as part of r04 (locked decision). The
  `proposeLinksSemanticSync` import is dropped from card-ops.ts; the
  L4 block is now log-only.
- `ExtractionFailure` class retained as `@deprecated` for one release
  window — no production code throws it anymore but the export survives
  to avoid breaking external `instanceof` checks.
- `wasSweepDeleted` retained as a dead field in `SaveCardResult` per
  the plan's compatibility-window decision; always `false` post-r04.
- Test seam `SILMARI_DISABLE_FINDBYCONTENTHASH=1` ships as part of r04.
- 10-rapid-saves test has a 30s timeout (each save spawns a brCreate
  subprocess; 10 saves takes ~8s).
- Stability assertion on priorId across the 10-save sequence is
  intentionally weak: beads_rust `created_at` is second-precision, so
  the lex-id tiebreaker can shift the "anchor" within a same-second
  group. Framework invariant ("every recurrence emits A reinforces
  edge to A prior") is verified; identity-of-anchor is not asserted.



## Overview

r04 implements Luhmann's multiple-storage principle at the save boundary of silmari-mcp. Today, when `saveCard` sees a body whose SHA-256 short hash already exists in the store, it short-circuits: it returns the prior bead's id with `wasDeduped: true` and skips Tier A extractors, keyword fan-out, and the L4 anchor check. Post-r04 that short-circuit is replaced by the framework invariant: a body-hash match is a recurrence **signal**, not a dedup **decision**. A fresh bead is written, Tier A edges run, and a `reinforces` edge is emitted from the new bead to the prior. The new card's position in the folgezettel tree (the "context") is what gives the recurrence its meaning — collapsing it into a reference on the older bead destroys that signal. This plan also removes the Phase 3 L4 auto-commit stopgap from `card-ops.ts:773-806`: the `proposeLinksSemanticSync` auto-invocation becomes a pure anchor check that logs when a card has zero `ref:*` edges without calling Sonnet or writing edges. See §8 of the parent cascade-extractor plan for the framework rationale.

## Current state analysis

The current saveCard dedup flow in `apps/silmari-mcp/src/lib/card-ops.ts`:

- `hashBody()` at `:516` produces a SHA-256 digest and truncates to an 8-char short hash for the `content_hash:` label.
- `findByContentHash(box, fullHash)` is called at `:530`; its implementation at `:348-366` queries `brList -l content_hash:<short>` then verifies the full hash in-memory to avoid the ~1-in-4-billion collision that 8 hex chars admits. **Note:** the current implementation performs NO explicit sort — it returns whatever `brList` returns first. Behaviors 4 and 7 require deterministic "oldest wins" selection, so r04 must add a `sort by created_at ASC, break ties by id` to `findByContentHash` as part of this slice (included in the Behavior 4 Green pseudocode).
- The **early return** at `:531-537` short-circuits the rest of saveCard: it returns `{ id: existing.id, fz: existing.fz, wasDeduped: true, wasSweepDeleted: false }` and bypasses every downstream step.
- `brCreate` commits the new bead at line `:612` — this is the ordering anchor for everything else.
- `runExtractors` writes Tier A `ref:*` labels at `:614-696`, AFTER `brCreate`. Each extractor calls `addEdge(box, selfId, edgeType, targetId)`, which delegates to `brLabelAdd` with `ref:<edgeType>:<targetId>` per `labels.ts:161`.
- The Tier A extractor registry in `edge-extractors.ts` actually has FOUR entries: `extractBodyMentions` (`:73`) → `refers-to`, `extractFolgezettelParent` (`:104`) → `follows` (continue) or `branches` (fork), `extractSourceReference` (`:122`) → `derives-from`, and `extractTitleMentions` (`:163`) → `refers-to` (fires when `titleCandidates` is provided, invoked from `runExtractors` at `:210-236`). The file-level docstring at `:11-17` says "three entries writing four edge types" — that docstring is itself outdated relative to the file and should be updated as part of r04. The `annotates` type exists in the enum but no extractor emits it today.
- `sweepDuplicates` at `:382-435` runs AFTER `brCreate` on fresh creates only. It queries `content_hash:<short>`, filters to full-hash matches, and when >1 bead matches it sorts by `created_at ASC` and DELETES all but the oldest. Today the race loser is destroyed.
- Keyword fan-out runs at `:713-739` via `addKeywordEntry`.
- L4 auto-fire at `:773-806`: when the card has zero `ref:*` edges after Tier A, `proposeLinksSemanticSync()` fires and, if the top proposal confidence ≥ `SILMARI_TIER_B_CONFIDENCE_THRESHOLD` (default 0.7), auto-commits via `addEdge`. This is the Phase 3 stopgap being removed.
- `SaveCardResult` type at `:173-178` shape today: `{ id: string; fz: string; wasDeduped: boolean; wasSweepDeleted: boolean }`.
- **Eight** reads of `wasDeduped` exist across the repo (verified 2026-04-22 via grep; the v1 cascade plan estimated "62+" which was wrong, and an earlier draft of this plan said "six" which was also wrong):
  - `apps/silmari-mcp/tests/integration.test.ts:267` — asserts `=== false` (first save)
  - `apps/silmari-mcp/tests/integration.test.ts:289` — asserts `=== true` (second save, body-hash match)
  - `apps/silmari-mcp/tests/integration.test.ts:506` — asserts `=== false` (fresh body)
  - `apps/silmari-mcp/tests/integration.test.ts:514` — asserts `=== true` (dedup bypass)
  - `apps/silmari-mcp/tests/integration.test.ts:580` — asserts `=== true` (biblio dedup, the biblio case lives in the main integration file — there is no separate biblio test file)
  - `apps/silmari-mcp/scripts/migrate-from-cosmic.ts:417` (conditional on `wasDeduped`)
  - `apps/silmari-mcp/scripts/migrate-from-cosmic.ts:426` (ternary on `wasDeduped`)
  - `apps/silmari-mcp/src/lib/biblio.ts:120` (wraps `wasDeduped: result.wasDeduped` into `BiblioResult`)
  All 8 sites must migrate; the two `=== false` sites (`:267`, `:506`) get rewritten to `wasReinforced === false` alongside the three `=== true` sites.
- External consumers of `wasDeduped`: `apps/silmari-mcp/src/lib/biblio.ts:120` (wraps as `BiblioResult.wasDeduped`) and the two migrate-from-cosmic conditionals above.
- `sweepDuplicates` exists precisely because SQLite WAL under concurrent writers can let two saves both commit before either sees the other — primary dedup via `findByContentHash` can't catch this. Post-r04, that race is the canonical reinforces-emit path at the sweep layer.

### Key discoveries (file:line)

- `apps/silmari-mcp/src/lib/card-ops.ts:173-178` — `SaveCardResult` type, the contract that changes.
- `apps/silmari-mcp/src/lib/card-ops.ts:515` — `saveCard` function entry.
- `apps/silmari-mcp/src/lib/card-ops.ts:516` — `hashBody()` call, full + short hash.
- `apps/silmari-mcp/src/lib/card-ops.ts:530` — `findByContentHash` lookup.
- `apps/silmari-mcp/src/lib/card-ops.ts:531-537` — early-return block to be removed.
- `apps/silmari-mcp/src/lib/card-ops.ts:353-365` — `findByContentHash` impl (short-hash query + full-hash verify).
- `apps/silmari-mcp/src/lib/card-ops.ts:382-435` — `sweepDuplicates` (keeps oldest, deletes rest today).
- `apps/silmari-mcp/src/lib/card-ops.ts:612` — `brCreate` commit.
- `apps/silmari-mcp/src/lib/card-ops.ts:614-696` — `runExtractors` writes Tier A edges AFTER `brCreate`.
- `apps/silmari-mcp/src/lib/card-ops.ts:713-739` — keyword fan-out loop.
- `apps/silmari-mcp/src/lib/card-ops.ts:764-819` — L4 anchor-check + auto-commit block; `:773-806` is the auto-fire body to remove.
- `apps/silmari-mcp/src/lib/edge-extractors.ts:11-17` — three registered Tier A extractors writing four edge types.
- `apps/silmari-mcp/src/lib/labels.ts:161` — `addEdge` → `brLabelAdd ref:<type>:<targetId>`.
- `apps/silmari-mcp/src/lib/biblio.ts:120` — external consumer wrapping `wasDeduped`.
- `apps/silmari-mcp/scripts/migrate-from-cosmic.ts:417-426` — migration script conditionals.

## Desired end state

### Why `addEdge` not `proposeOrAddEdge`

`reinforces` is a REVIEWED edge type (see `REVIEWED_EDGE_TYPES` at `apps/silmari-mcp/src/lib/labels.ts:89-95`). The normal flow for REVIEWED edges is `proposeOrAddEdge` (`edges.ts:403-417`), which routes the edge to the `link-proposals.jsonl` human-review queue instead of committing it.

**r04 writes `reinforces` via `addEdge` directly, NOT via `proposeOrAddEdge`, because body-hash recurrence is a deterministic signal, not an LLM semantic proposal.** The match is cryptographic evidence — there is nothing for a human to adjudicate about whether the edge is real. The `needs-consolidation-review:true` label (attached to both beads in the pair) serves as the human-review gate in place of the proposal queue: a later review pass decides "truly duplicate → prune one" vs "genuinely-different contexts → clear the flag and keep both."

Implementing engineer: do NOT "fix" this by swapping `addEdge` → `proposeOrAddEdge`. The bypass is intentional and is the framework invariant. Leave a code comment at the call site documenting this so a future reviewer does not regress it.

**New `SaveCardResult` contract:**
```ts
export interface SaveCardResult {
  id: string;              // always the new bead's id (never the prior)
  fz: string;              // new bead's folgezettel address
  wasReinforced: boolean;  // true iff a body-hash match existed AND a reinforces edge was emitted
  priorId?: string;        // present iff wasReinforced === true; the bead reinforced
  wasSweepDeleted: boolean; // DEPRECATED, retained for one release: always false post-r04
}
```

`wasSweepDeleted` is retained in the shape (to minimize consumer churn during the release window) but the field is dead — sweepDuplicates no longer deletes. A follow-up ticket can remove it after consumers migrate. TODO: verify in bd whether a follow-up ticket is desired; if not, drop the field entirely in this slice.

**New dedup flow (Luhmann multiple-storage):**
1. `hashBody()` computes full + short hash.
2. `findByContentHash` runs; if a prior bead is found, record `priorId` and PROCEED — do not early-return.
3. `brCreate` commits a new bead.
4. `runExtractors` writes Tier A edges (unchanged).
5. If `priorId` is set, emit `reinforces` from new bead to prior via `addEdge(box, newId, "reinforces", priorId)` (direct write — NOT `proposeOrAddEdge`; see rationale above).
6. Keyword fan-out runs (unchanged).
7. L4 anchor check: if card has zero `ref:*` edges post-Tier-A, log a `zk.anchor.missing` telemetry signal and return. Do NOT call `proposeLinksSemanticSync`, do NOT auto-commit.
8. `sweepDuplicates` runs (redesigned — see below).
9. Return `{ id, fz, wasReinforced, priorId?, wasSweepDeleted: false }`.

**sweepDuplicates redesign:** on fresh create, if the post-create query for `content_hash:<short>` returns >1 bead (concurrency race), keep ALL of them. Sort by `created_at ASC`. The oldest is the "winner." For every other bead in the set (younger racers, including this call's own new bead if applicable), emit `reinforces` from that bead to the winner. No deletes.

**L4 as pure anchor check:** the `proposeLinksSemanticSync` call site in `card-ops.ts:773-806` is removed. The anchor check becomes: count `ref:*` labels on the new bead; if zero, emit a telemetry log line (`zk.anchor.missing card=<id> reason="no ref:* after Tier A"`) and return normally. No Sonnet call, no auto-commit, no behavior change to the result.

### Observable behaviors

- **Behavior 1 (body-hash match):** Given a card body that hashes to a value already present in the store, when `saveCard` is called with that body, then a NEW bead is created, a `reinforces` edge is written from the new bead to the prior-hash bead, and the result is `{id: <newId>, fz: <newFz>, wasReinforced: true, priorId: <priorId>, wasSweepDeleted: false}`.
- **Behavior 2 (contract shape):** Given any call to `saveCard`, when it returns, then the result has EXACTLY the fields `{id, fz, wasReinforced, priorId?, wasSweepDeleted}` and does NOT have a `wasDeduped` field.
- **Behavior 3 (Tier A ordering):** Given a fresh card body, when `saveCard` runs, then `runExtractors` is invoked AFTER `brCreate` returns successfully and BEFORE the reinforces emit, and all `ref:*` labels produced by Tier A extractors are present on the bead before the function returns.
- **Behavior 4 (sweepDuplicates race):** Given two concurrent `saveCard` calls with identical body that both commit before either sees the other, when both return, then both beads exist in the store, a `reinforces` edge points from the younger bead to the older, and each call's result has `wasSweepDeleted: false`.
- **Behavior 5 (L4 anchor-missing):** Given a card whose Tier A extractors produce zero `ref:*` edges, when `saveCard` completes, then `proposeLinksSemanticSync` was NOT called, no new edges were added by L4, and a `zk.anchor.missing` telemetry line was emitted.
- **Behavior 6 (external consumer migration):** Given the updated `biblio.ts` and `migrate-from-cosmic.ts`, when they consume `SaveCardResult`, then they read `wasReinforced` (not `wasDeduped`) and report outcomes correctly.
- **Behavior 7 (third identical save):** Given a body already saved twice (bead A and bead B, with B→A `reinforces`), when the same body is saved a third time, then bead C is created with a `reinforces` edge C→A (to the root-hash-bead, not B).
- **Behavior 8 (first save, no prior):** Given a body whose hash has no prior match, when `saveCard` is called, then a new bead is created, no `reinforces` edge is emitted, and the result has `wasReinforced: false` and no `priorId`.

## What we're NOT doing

- Cascade Gate B explicit pass (parent plan Step 6) — not in r04.
- New primitives `hubMembers` / `filterByKeywordOverlap` (parent plan Step 5.5) — not in r04.
- Changes to Tier A extractor **behavior**: the three extractors in `edge-extractors.ts:11-17` keep their current inputs, outputs, and semantics. r04 only asserts ordering, it does not rewire extractors.
- Adding the `annotates` extractor — the enum value stays dangling.
- Removing `wasSweepDeleted` from the result type (keep as a dead field for one release to stabilize consumers).
- Changing the `brLabelAdd ref:<type>:<targetId>` encoding.
- Expanding keyword fan-out semantics — keyword-entry uncapped policy is already landed in an earlier slice (memory note: "Silmari framework: no MAX_ENTRY_POINTS cap").
- Changing `findByContentHash`'s lookup algorithm (short hash query + full hash verify stays).

## Testing strategy

- **Framework:** `bun test`.
- **Unit tests:** new file `apps/silmari-mcp/tests/unit/save-card-reinforce.test.ts` for the reinforces-emit helper (Behavior 1 core), plus per-function tests for the redesigned `sweepDuplicates`.
- **Integration tests:** extend existing `apps/silmari-mcp/tests/integration.test.ts` — rewrite all five `wasDeduped` sites (`:267`, `:289`, `:506`, `:514`, `:580`) and add the Behavior 1/2/7/8 assertions there. That file's fixture is NOT a `setupTestStore` helper (no such helper exists) — it's a module-scope `mkdtempSync` + env vars + per-test `silmariInit()` pattern at `:25-30`. New tests either reuse that module preamble or copy it.
- **Concurrency test:** new file `apps/silmari-mcp/tests/integration/savecard-concurrency.test.ts` uses `Promise.all` plus a new test-only env var `SILMARI_DISABLE_FINDBYCONTENTHASH=1` to deterministically force both writers into the race path (no existing concurrency fixture in the repo — this is new harness territory).
- **L4 anchor-missing test:** runs in its own file with `SILMARI_DISABLE_L4` explicitly unset (the main integration suite sets it to `1`). Spy on the `inference` export from `Inference.ts` and on `console.error` to assert no Sonnet call + the log line emission.
- **Migration testing:** snapshot a fixture cosmic DB with known body-hash duplicates, run `migrate-from-cosmic.ts` against an empty silmari store, and assert that every duplicate group produces N cards + N-1 `reinforces` edges pointing at the oldest in the group.
- **Regression testing:** run the full `bun test` suite to confirm no other test relies on `wasDeduped` implicitly (e.g. by reading `result.wasDeduped` without asserting it to be `true`). Any such site gets TypeScript-enforced migration once the type changes.

---

## Behavior 1: body-hash match produces new card + reinforces edge + consolidation-review flag

### Test specification

- **Given** a silmari store with one prior bead whose body hashes to `H`,
- **When** `saveCard` is called with a body whose hash is also `H`,
- **Then** a second bead is created, a `ref:reinforces:<priorId>` label is present on the new bead, BOTH beads (new and prior) carry a `needs-consolidation-review:true` label ("sleep consolidation" pattern — extended here from the race case to the sequential case for symmetry; Maceo's 2026-04-22 decision rationale "like humans do when they sleep" applies to every body-hash match, not just concurrent ones; CONFIRM or revert if the flag should only attach in the race case), and the result is `{wasReinforced: true, priorId: <priorId>, ...}`.

**Edge cases covered:**
- First save (no match) → Behavior 8, separate test.
- Identical body 2nd save → this test.
- Identical body 3rd save → Behavior 7, separate test. The 3rd save's `reinforces` edge targets the ORIGINAL (oldest body-hash match), not the 2nd. Rationale: `findByContentHash` returns the first match it finds after full-hash verification; the redesign must pick the oldest deterministically (sort by `created_at ASC`, take first) so repeated recurrence always points to the same anchor.

### TDD cycle

🔴 **Red** — add to `apps/silmari-mcp/tests/integration.test.ts`. Note: `saveCard` is a synchronous function returning `SaveCardResult | null`; tests in the existing suite use `!` non-null assertion. Fixture pattern below matches the live harness at `integration.test.ts:25-30` (module-scope `mkdtempSync` + env vars + `silmariInit()`); the env var MUST be set BEFORE the dynamic `await import(...)` because bun-sqlite binds the db on first import.

```ts
import { describe, it, expect } from "bun:test";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

process.env.SILMARI_DIR = mkdtempSync(join(tmpdir(), "r04-test-"));
process.env.SILMARI_DISABLE_L4 = "1";
const { saveCard } = await import("../src/lib/card-ops");
const { brShow } = await import("../src/lib/br-adapter");
const { silmariInit } = await import("../src/lib/init");

describe("saveCard reinforces on body-hash match", () => {
  it("creates new bead AND emits reinforces edge to prior when body hash already exists", () => {
    silmariInit();
    const body = "Functional differentiation as a systems-theoretic concept.";

    const first = saveCard({ box: "idea", body, kind: "idea", trunk: 2, mode: "root" })!;
    expect(first.wasReinforced).toBe(false);
    expect(first.priorId).toBeUndefined();

    const second = saveCard({ box: "idea", body, kind: "idea", trunk: 2, mode: "root" })!;
    expect(second.id).not.toBe(first.id);
    expect(second.wasReinforced).toBe(true);
    expect(second.priorId).toBe(first.id);

    // Verify edge label is on the new bead, not the old (brShow can return null → null-coalesce)
    const { labels } = brShow("idea", second.id) ?? { labels: [] };
    expect(labels).toContain(`ref:reinforces:${first.id}`);
    const { labels: priorLabels } = brShow("idea", first.id) ?? { labels: [] };
    expect(priorLabels).not.toContain(`ref:reinforces:${second.id}`);

    // "Sleep consolidation" flag — BOTH beads marked for later human review
    // (decide: truly duplicate → prune one; different contexts → clear flag)
    expect(labels).toContain(`needs-consolidation-review:true`);
    expect(priorLabels).toContain(`needs-consolidation-review:true`);
  });
});
```

This fails on the current tree because `second.wasReinforced` does not exist (the field is `wasDeduped`), and the early-return at `:531-537` means no new bead is created.

🟢 **Green** — in `card-ops.ts`:

```ts
// REPLACE :531-537 (early return) with:
const priorMatch = findByContentHash(box, fullHash);
const priorId = priorMatch?.id;
// ... continue to brCreate at :612 instead of returning ...

// AFTER runExtractors completes (:614-696), BEFORE keyword fan-out (:713):
if (priorId) {
  // NOTE: deliberate `addEdge` (not `proposeOrAddEdge`). `reinforces` is a REVIEWED
  // edge type, but body-hash recurrence is deterministic evidence — no LLM proposal
  // is involved. Human review is deferred to the `needs-consolidation-review:true`
  // label below, which is scanned during periodic consolidation passes.
  emitReinforcesToPrior(box, newId, priorId);
  // "Sleep consolidation" flag — mark both beads for later human review. Single
  // variadic call per bead; brLabelAdd is idempotent at the sqlite layer.
  brLabelAdd(box, newId, "needs-consolidation-review:true");
  brLabelAdd(box, priorId, "needs-consolidation-review:true");
}

// At the return site (end of saveCard):
return {
  id: newId,
  fz: newFz,
  wasReinforced: priorId !== undefined,
  priorId,
  wasSweepDeleted: false,
};
```

🔵 **Refactor** — extract `emitReinforcesToPrior(box, newId, priorId)` into its own function adjacent to `addEdge`. Gives Behaviors 4 and 7 a shared helper and keeps saveCard's body readable.

```ts
function emitReinforcesToPrior(box: Box, fromId: string, toId: string): void {
  // Direct write, bypassing `proposeOrAddEdge`. See rationale in
  // "Why `addEdge` not `proposeOrAddEdge`" section of the r04 plan.
  addEdge(box, fromId, "reinforces", toId);
}
```

### Success criteria

- Automated: `bun test apps/silmari-mcp/tests/integration.test.ts` passes. Red cycle fails with `wasDeduped` field not existing (or `wasReinforced` undefined). Green cycle passes. Refactor cycle still passes.
- Manual: inspect store with `br label list <newId>` and confirm `ref:reinforces:<priorId>` is present.

---

## Behavior 2: SaveCardResult contract shape is `{id, fz, wasReinforced, priorId?, wasSweepDeleted}`

### Test specification

- **Given** any successful `saveCard` call,
- **When** the result is examined,
- **Then** the top-level keys are exactly `{id, fz, wasReinforced, priorId, wasSweepDeleted}` (or `{id, fz, wasReinforced, wasSweepDeleted}` when no match), and `wasDeduped` is not a key.

### TDD cycle

🔴 **Red** — add to `apps/silmari-mcp/tests/integration.test.ts`:

```ts
// Uses the same module-scope fixture preamble as Behavior 1:
// mkdtempSync → process.env.SILMARI_DIR → dynamic import of card-ops → silmariInit()
describe("saveCard result contract (r04)", () => {
  it("never exposes wasDeduped; always exposes wasReinforced", () => {
    silmariInit();
    const res = saveCard({ box: "idea", body: "unique seed", kind: "idea", trunk: 5, mode: "root" })!;

    expect(res).toHaveProperty("wasReinforced");
    expect(res).not.toHaveProperty("wasDeduped");
    expect(typeof res.wasReinforced).toBe("boolean");
    expect(res.wasReinforced).toBe(false);
    expect(res.priorId).toBeUndefined();
    expect(res.wasSweepDeleted).toBe(false);

    // Reinforced case
    const again = saveCard({ box: "idea", body: "unique seed", kind: "idea", trunk: 5, mode: "root" })!;
    expect(again.wasReinforced).toBe(true);
    expect(again.priorId).toBe(res.id);
  });
});
```

🟢 **Green** — update the `SaveCardResult` type at `card-ops.ts:173-178`:

```ts
export interface SaveCardResult {
  id: string;
  fz: string;
  wasReinforced: boolean;
  priorId?: string;
  wasSweepDeleted: boolean;
}
```

TypeScript will now force the return-site update (done as part of Behavior 1's Green) and the external consumers (Behavior 6). All **eight** `wasDeduped` reads will stop compiling: five in integration.test.ts (`:267`, `:289`, `:506`, `:514`, `:580`), two in migrate-from-cosmic.ts (`:417`, `:426`), and one in biblio.ts (`:120`). They get rewritten in Behavior 6.

🔵 **Refactor** — none at this step; the shape change is the minimal change.

### Success criteria

- `tsc --noEmit` in `apps/silmari-mcp/` fails on every remaining `wasDeduped` reference. Fixing those references is the Green work. Once TypeScript is clean, the Behavior-2 test passes.
- The three integration tests rewritten under Behavior 6 still pass.

---

## Behavior 3: Tier A edges still write after brCreate (ordering preserved)

### Test specification

- **Given** a card body that contains a mention of an existing bead `X` (so `extractBodyMentions` produces `ref:refers-to:X`),
- **When** `saveCard` completes,
- **Then** the new bead has `ref:refers-to:X` AND that label was applied AFTER `brCreate` returned (so the bead existed before the label was attached). This is a regression guard — r04 must not reorder Tier A relative to `brCreate`.

### TDD cycle

🔴 **Red** — add to `apps/silmari-mcp/tests/integration.test.ts`:

```ts
// Uses the same module-scope fixture preamble as Behaviors 1 and 2.
describe("Tier A ordering preserved post-r04", () => {
  it("runs runExtractors AFTER brCreate and BEFORE reinforces-emit", () => {
    silmariInit();
    // Seed a bead to be mentioned
    const target = saveCard({ box: "idea", body: "Anchor target.", kind: "idea", trunk: 5, mode: "root" })!;

    // Spy: record call order of brCreate, runExtractors, emitReinforcesToPrior
    const calls: string[] = [];
    // TODO: verify in card-ops.ts whether these are exported or need a seam introduction
    wrapForSpy("brCreate", calls);
    wrapForSpy("runExtractors", calls);
    wrapForSpy("emitReinforcesToPrior", calls);

    const res = saveCard({
      box: "idea",
      body: `Mentions ${target.id} explicitly.`,
      kind: "idea",
      trunk: 5,
      mode: "root",
    })!;

    const brIdx = calls.indexOf("brCreate");
    const exIdx = calls.indexOf("runExtractors");
    expect(brIdx).toBeGreaterThanOrEqual(0);
    expect(exIdx).toBeGreaterThan(brIdx);

    const { labels } = brShow("idea", res.id) ?? { labels: [] };
    expect(labels).toContain(`ref:refers-to:${target.id}`);
  });
});
```

🟢 **Green** — no code change expected; this is a regression test. If it fails, r04's implementation accidentally reordered the flow. The fix is to restore the `brCreate` → `runExtractors` → `emitReinforcesToPrior` sequence in the saveCard body.

🔵 **Refactor** — if the spy wrapping feels invasive, consider extracting the save pipeline into a small `SavePipeline` object with explicit phases, making ordering testable without monkey-patching. Deferred to a follow-up slice unless the spy approach bloats the test.

### Success criteria

- Call-order spy shows `brCreate` before `runExtractors` before `emitReinforcesToPrior`.
- `ref:refers-to:<target.id>` is present on the new bead.

---

## Behavior 4: sweepDuplicates keeps both racers, emits reinforces loser→winner, and flags the pair for human consolidation review

### Test specification

- **Given** two concurrent `saveCard` calls with identical body, both of which commit before either's `findByContentHash` could see the other,
- **When** both `saveCard` calls return,
- **Then** BOTH beads exist in the store (neither was deleted), the younger bead has a `ref:reinforces:<older.id>` label, the older has no such label targeting the younger, each call's result has `wasSweepDeleted: false`, AND **both beads carry a `needs-consolidation-review:true` label** so that a later human-review pass can decide "truly duplicate → prune one" or "genuinely-different contexts → clear the flag and keep both." (This is the "sleep consolidation" pattern locked 2026-04-22 in the cascade plan's `## Decisions locked` block — concurrent-write races almost always mean genuine duplicates, but not always, and deciding which is a judgment call that belongs with the human, not the save path.)

### TDD cycle

🔴 **Red** — new file `apps/silmari-mcp/tests/integration/savecard-concurrency.test.ts`. The test-only seam is an env var (consistent with existing `SILMARI_DISABLE_L4` / `SILMARI_TEST_MOCK_TIER_B` conventions) — NOT a `using`-style function seam (no such pattern exists in this codebase).

```ts
import { describe, it, expect } from "bun:test";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

process.env.SILMARI_DIR = mkdtempSync(join(tmpdir(), "r04-concurrency-"));
// Test-only seam (ships as part of r04): when set, findByContentHash returns
// null unconditionally so both writers proceed straight to brCreate,
// deterministically reproducing the concurrent-race path that sweepDuplicates handles.
process.env.SILMARI_DISABLE_FINDBYCONTENTHASH = "1";
// Deliberately NOT setting SILMARI_DISABLE_L4 — we want normal save flow.
const { saveCard } = await import("../../src/lib/card-ops");
const { brShow } = await import("../../src/lib/br-adapter");
const { silmariInit } = await import("../../src/lib/init");

describe("saveCard concurrency — race both survive with reinforces", () => {
  it("keeps both racers and writes reinforces from younger to older", async () => {
    silmariInit();
    const body = "Concurrent race body — both must survive.";

    // saveCard is synchronous; wrap in Promise.resolve to drive two "concurrent"
    // calls — sqlite WAL will serialize commits but both skip findByContentHash.
    const [a, b] = await Promise.all([
      Promise.resolve(saveCard({ box: "idea", body, kind: "idea", trunk: 5, mode: "root" })!),
      Promise.resolve(saveCard({ box: "idea", body, kind: "idea", trunk: 5, mode: "root" })!),
    ]);

    expect(a.id).not.toBe(b.id);
    expect(a.wasSweepDeleted).toBe(false);
    expect(b.wasSweepDeleted).toBe(false);

    // Determine winner/loser via brShow (read created_at from each)
    const aRow = brShow("idea", a.id)!;
    const bRow = brShow("idea", b.id)!;
    const [older, younger] =
      new Date(aRow.created_at).getTime() <= new Date(bRow.created_at).getTime()
        ? [aRow, bRow]
        : [bRow, aRow];

    expect(younger.labels).toContain(`ref:reinforces:${older.id}`);
    expect(older.labels).not.toContain(`ref:reinforces:${younger.id}`);

    // "Sleep consolidation" flag — BOTH racers get marked for review
    expect(younger.labels).toContain(`needs-consolidation-review:true`);
    expect(older.labels).toContain(`needs-consolidation-review:true`);
  });
});
```

🟢 **Green** — redesign `sweepDuplicates` (`card-ops.ts:382-435`). Preserve the existing call signature `(box, fullHash, createdId)` — the call site at `:612` passes args in that order. Also add the test-only env-var early-return to `findByContentHash`:

```ts
// In findByContentHash (card-ops.ts:348-366) — new first line:
function findByContentHash(box: Box, fullHash: string): BeadRow | null {
  if (process.env.SILMARI_DISABLE_FINDBYCONTENTHASH === "1") return null;
  const short = shortHash(fullHash);
  const matches = brList({ box, labels: [`content_hash:${short}`], all: true, limit: 5 });
  // Deterministic "oldest wins": sort by created_at ASC, ties broken by id.
  // Behaviors 4 and 7 both rely on this ordering.
  const full = matches
    .filter((m) => m.content_hash_full === fullHash)
    .sort((a, b) => {
      const ta = new Date(a.created_at).getTime();
      const tb = new Date(b.created_at).getTime();
      return ta - tb || a.id.localeCompare(b.id);
    });
  return full[0] ?? null;
}

// sweepDuplicates — preserve existing signature (box, fullHash, createdId).
// Return shape stays {id, swept} (matches current `{id: string; swept: boolean}`).
export function sweepDuplicates(
  box: Box,
  fullHash: string,
  createdId: string,
): { id: string; swept: boolean } {
  const short = shortHash(fullHash);
  const matches = brList({ box, labels: [`content_hash:${short}`], all: true, limit: 10 });
  const fullMatches = matches.filter((m) => m.content_hash_full === fullHash);
  if (fullMatches.length <= 1) {
    return { id: createdId, swept: false };
  }

  // Sort oldest-first (same deterministic key as findByContentHash)
  const sorted = fullMatches.sort((a, b) => {
    const ta = new Date(a.created_at).getTime();
    const tb = new Date(b.created_at).getTime();
    return ta - tb || a.id.localeCompare(b.id);
  });
  const winner = sorted[0];

  // Every non-winner emits reinforces to winner IF it doesn't already have one.
  // Idempotency: concurrent sweeps from sibling writers must not double-emit.
  // (brLabelAdd is itself idempotent at the sqlite layer; this check is belt-and-suspenders.)
  for (const loser of sorted.slice(1)) {
    const { labels: existing } = brShow(box, "idea", loser.id) ?? { labels: [] };
    if (!existing.includes(`ref:reinforces:${winner.id}`)) {
      addEdge(box, loser.id, "reinforces", winner.id);
    }
  }

  // "Sleep consolidation" flag — mark the whole set (winner + losers) for
  // later human review. The human decides: truly duplicate → prune one,
  // or genuinely-different contexts → clear flags + keep both.
  for (const bead of sorted) {
    brLabelAdd(box, bead.id, "needs-consolidation-review:true");
  }

  return { id: createdId, swept: false };
}
```

🔵 **Refactor** — pull the "emit reinforces iff not already present" check into `emitReinforcesToPrior` so Behavior 1's helper gains idempotency for free. This means the sweepDuplicates loop becomes a simple `for (const l of losers) emitReinforcesToPrior(box, l.id, winner.id)`.

### Success criteria

- Automated: `bun test apps/silmari-mcp/tests/integration/savecard-concurrency.test.ts` passes.
- Manual: query `brList -l content_hash:<short>` after the race — 2 beads present; `br label list` on younger shows `ref:reinforces:<older>`; on older, no such label.
- Regression: no bead is deleted by sweep anymore — a follow-up cleanup run should never find orphan ghosts from deletes.

---

## Behavior 5: L4 anchor check fires logging, not Sonnet

### Test specification

- **Given** a card whose Tier A extractors produce zero `ref:*` labels (the body has no mentions, no parent folgezettel, no source reference),
- **When** `saveCard` completes,
- **Then** the `inference` function (the only exported Sonnet entry point, used by `proposeLinksSemanticSync`) was NOT called, no `ref:*` label was added by L4, a log line identifying `zk.anchor.missing` was emitted, and the return value is the normal `SaveCardResult` (no special flag).

**Important harness note:** the existing integration test harness sets `SILMARI_DISABLE_L4=1` at `integration.test.ts:27`. This test's assertion that `inference` was NOT called would be vacuous under that flag (L4 is disabled by the env var before the anchor check even runs). This test MUST run with `SILMARI_DISABLE_L4` **unset** — either in a separate file with its own tempdir, or in a describe block that explicitly `delete process.env.SILMARI_DISABLE_L4`. The Green implementation then has to actually reach the anchor-check code path to exercise the "no inference call" assertion.

### TDD cycle

🔴 **Red** — new file `apps/silmari-mcp/tests/integration/savecard-l4-anchor.test.ts` (separate from the main integration suite to avoid inheriting `SILMARI_DISABLE_L4=1`):

```ts
import { describe, it, expect, spyOn } from "bun:test";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

process.env.SILMARI_DIR = mkdtempSync(join(tmpdir(), "r04-l4-anchor-"));
delete process.env.SILMARI_DISABLE_L4; // critical: do not inherit from parent env
const { saveCard } = await import("../../src/lib/card-ops");
const Inference = await import("../../src/lib/Inference");
const { silmariInit } = await import("../../src/lib/init");

describe("L4 anchor check (post-r04) — no Sonnet, no auto-commit", () => {
  it("logs anchor-missing and does not invoke inference", () => {
    silmariInit();
    // Spy on the Inference module's default export (the Sonnet entry point).
    // If any code path would have triggered L4 auto-commit pre-r04, it would
    // have called inference() — post-r04 it must not.
    const inferenceSpy = spyOn(Inference, "inference");

    // Also spy on console.error to capture the zk.anchor.missing log line
    // (logging uses the existing console.error convention in this codebase;
    // no separate telemetry module is introduced).
    const errSpy = spyOn(console, "error");

    const res = saveCard({
      box: "idea",
      body: "Wholly novel body with no mentions, no parents, no source.",
      kind: "idea",
      trunk: 5,
      mode: "root",
    })!;

    expect(inferenceSpy).not.toHaveBeenCalled();
    expect(errSpy.mock.calls.some(
      (args) => typeof args[0] === "string" && args[0].includes("zk.anchor.missing"),
    )).toBe(true);

    // Result shape is normal — no anchor-missing flag leaks into the contract
    expect(res.wasReinforced).toBe(false);
    expect(res.wasSweepDeleted).toBe(false);
  });
});
```

Note on spy target: `proposeLinksSemanticSync` itself is what the old auto-fire block called, but `proposeLinksSemanticSync` internally calls `inference` from `Inference.ts` — spying on the `Inference` export is the narrower assertion and captures the invariant "no Sonnet round-trip at save time." If `Inference` is not the right module name in the tree, use whichever module actually exports the Sonnet entry point used by the proposer (grep for the `anthropic` client init).

🟢 **Green** — replace `card-ops.ts:773-806` with:

```ts
// L4 anchor check: log-only, no auto-commit. No Sonnet call.
const { labels: newLabels } = brShow(box, "idea", newId) ?? { labels: [] };
const refLabels = newLabels.filter((l) => l.startsWith("ref:"));
if (refLabels.length === 0) {
  console.error(JSON.stringify({
    event: "zk.anchor.missing",
    cardId: newId,
    reason: "no ref:* after Tier A",
  }));
}
```

Delete the `proposeLinksSemanticSync` / `REVIEWED_EDGES` / `Proposal` imports at `card-ops.ts:57-60` if they become unused at this call site (grep before deleting — they may still be used elsewhere).

🔵 **Refactor** — extract the `refLabels.length === 0` condition into `hasAnchor(labels)`. The function is reusable by a later cascade pass.

### Success criteria

- `inferenceSpy` call count is 0.
- `console.error` received a call whose first arg contains `zk.anchor.missing`.
- No `ref:*` labels appear on the bead beyond what Tier A produced.

---

## Behavior 6: biblio.ts, migrate-from-cosmic.ts, and MCP tool description migrate cleanly to new contract

### Test specification

Scope of migration sites (all 8 `wasDeduped` reads + 1 docstring + 1 type-def site):

- (a) **Five** integration.test.ts sites: `:267` (=== false), `:289` (=== true), `:506` (=== false), `:514` (=== true), `:580` (=== true)
- (b) `migrate-from-cosmic.ts:417` — conditional rewrite to `wasReinforced`
- (c) `migrate-from-cosmic.ts:426` — ternary rewrite to `wasReinforced`
- (d) `biblio.ts:120` — wrap `wasReinforced` + `priorId` into `BiblioResult` (also update the `BiblioResult` interface itself; consider renaming its field to `wasReinforced` to match — see Refactor below)
- (e) Any MD / README files referencing `wasDeduped`: grep before merge.
- (f) **MCP tool description** at `apps/silmari-mcp/src/index.ts:89-91` — the current text "Content-hash dedup is automatic: saving identical body twice returns the same id." is FALSE post-r04. Rewrite to: "Saving identical body twice creates two cards linked by a `reinforces` edge; both are flagged with `needs-consolidation-review:true` for later human review."

Testable assertions:

- **Given** the updated `BiblioResult` interface (wraps `SaveCardResult` fields),
- **When** `biblio.ts:120` returns,
- **Then** the result has `wasReinforced` (not `wasDeduped`) and `priorId?`.
- **Given** `migrate-from-cosmic.ts` running against a cosmic snapshot with body-hash duplicates,
- **When** migration completes,
- **Then** the outcome report counts `reinforced: N` entries correctly and the target store has N + (N-1)-per-group beads + reinforces edges, not N deduped skips.

### TDD cycle

🔴 **Red** — rewrite all five integration.test.ts sites (including the two previously-overlooked `=== false` assertions at `:267` and `:506`):

```ts
// apps/silmari-mcp/tests/integration.test.ts:267 (was: expect(first.wasDeduped).toBe(false))
expect(first.wasReinforced).toBe(false);
expect(first.priorId).toBeUndefined();

// apps/silmari-mcp/tests/integration.test.ts:289 (was: expect(second.wasDeduped).toBe(true))
expect(second.wasReinforced).toBe(true);
expect(second.priorId).toBe(first.id);

// apps/silmari-mcp/tests/integration.test.ts:506 (was: expect(res.wasDeduped).toBe(false))
expect(res.wasReinforced).toBe(false);

// apps/silmari-mcp/tests/integration.test.ts:514 (dedup extractor bypass test)
// Test was asserting extractors were bypassed on dedup. Post-r04 they run.
// Rewrite: assert extractors DID run on the second save (ref:* labels present),
// AND the reinforces edge is present.
expect(second.wasReinforced).toBe(true);
const { labels: labels2 } = brShow("idea", second.id) ?? { labels: [] };
expect(labels2.some((l) => l.startsWith("ref:"))).toBe(true);
expect(labels2).toContain(`ref:reinforces:${first.id}`);

// apps/silmari-mcp/tests/integration.test.ts:580 (biblio dedup — the biblio case
// lives in the main integration file; there is no separate biblio test file)
expect(biblioRes.wasReinforced).toBe(true);
expect(biblioRes.priorId).toBe(prior.id);
```

Rewrite the migration script's branches:

```ts
// apps/silmari-mcp/scripts/migrate-from-cosmic.ts:417 & :426
if (result.wasReinforced) {
  stats.reinforced += 1;
  stats.reinforcedPairs.push({ newId: result.id, priorId: result.priorId });
} else {
  stats.freshCreates += 1;
}
// (previously: `if (result.wasDeduped) { stats.skipped += 1; }`)
```

Update `biblio.ts:120`:

```ts
// Before: wasDeduped: save.wasDeduped
// After:
wasReinforced: save.wasReinforced,
priorId: save.priorId,
```

🟢 **Green** — the type change from Behavior 2 already forces these sites to break compilation. Work through TypeScript errors, updating each to the new contract. Running `tsc --noEmit` in `apps/silmari-mcp/` with zero errors is the green gate.

🔵 **Refactor** — consider renaming `BiblioResult.wasDeduped` to `wasReinforced` in the same slice so biblio's public interface reflects the framework invariant. This is a breaking change for any downstream consumers of biblio; audit before doing it. TODO: verify downstream biblio consumers.

### Success criteria

- `bun test apps/silmari-mcp/tests/integration.test.ts` — all **five** rewritten assertions pass (the three `=== true` plus the two previously-overlooked `=== false`).
- `bun run scripts/migrate-from-cosmic.ts --dry-run` on a fixture cosmic DB reports `reinforced: N` with N matching the known duplicate count in the fixture.
- `tsc --noEmit` is clean.
- `grep -r wasDeduped apps/silmari-mcp src README.md` returns zero hits.
- MCP tool description at `src/index.ts:89-91` rewritten to reflect reinforces-on-match semantics (item (f) above).
- **Backward-compat check:** `sweepDuplicates` previously DELETED race losers; r04 keeps them. Before merge, grep `apps/silmari-mcp/tests/` for any test that deliberately asserts the race-delete behavior (look for patterns like `expect(...).toBeNull()` or `wasSweepDeleted === true`). Such tests are testing the bug that r04 removes — they need to be rewritten or removed, not preserved.

---

## Integration & E2E testing

**End-to-end migration test** — new fixture test:

1. Create a fixture cosmic SQLite snapshot at `apps/silmari-mcp/tests/fixtures/cosmic-duplicates.db` with exactly 3 known duplicate groups: group A has 2 identical bodies, group B has 3, group C has 5. Total beads: 10 across 3 hash groups.
2. Run `bun run apps/silmari-mcp/scripts/migrate-from-cosmic.ts --from <fixture> --to <tmpdir>`.
3. Assert the target silmari store has:
   - 10 cards (one per source bead — NOT 3).
   - 1 `reinforces` edge in group A (the 2nd → the 1st).
   - 2 `reinforces` edges in group B (the 2nd and 3rd both → the 1st).
   - 4 `reinforces` edges in group C (the 2nd through 5th all → the 1st).
   - Total: 7 `reinforces` edges across the store.
4. Assert the migration log reports `reinforced: 7`, `freshCreates: 3`.

**Smoke test post-deploy** — after merging r04, run `./scripts/alpha-smoketest.sh` against ionos01 and verify saveCard still returns valid JSON over the MCP stdio interface. Any consumer of `wasDeduped` in the wild (Claude Code hooks, custom scripts) will error; this is expected breakage that the release notes must call out.

## Rollout / migration plan

- **Single commit vs phased:** single commit. The type change is atomic — splitting it across commits leaves a window where TypeScript is broken.
- **Gate before merge:**
  1. `bun test` passes clean across the whole monorepo.
  2. Migration fixture test (Integration section) passes.
  3. Concurrency race test (Behavior 4) passes 10/10 runs — if it's flaky, the deterministic-scheduler harness is wrong and must be fixed before merge.
  4. `tsc --noEmit` in `apps/silmari-mcp/` clean.
- **Release notes must call out:**
  - `SaveCardResult.wasDeduped` → `wasReinforced` (breaking for external tooling).
  - `sweepDuplicates` no longer deletes — stores that had been silently shedding race-losers will now accumulate them + their `reinforces` edges.
  - L4 auto-commit removed — Sonnet is no longer called at save time. Cascade Gate B (future r04 sibling work) is where intelligence re-enters.
  - MCP tool `zk_save_card` description updated: "identical body twice returns the same id" is gone; replaced with the reinforces-on-match wording.
  - New test-only env var `SILMARI_DISABLE_FINDBYCONTENTHASH=1` — short-circuits `findByContentHash` to return null. Production code must never set this; it exists only for the concurrency-race test harness. Document alongside `SILMARI_DISABLE_L4` in any env-var reference docs.
- **Cosmic re-migration recommended** for any silmari store that was populated by pre-r04 `migrate-from-cosmic.ts`: those stores have `wasDeduped` skips that never materialized as `reinforces` edges. A one-shot re-migration pass against the cosmic snapshot will backfill them. Tracked as a follow-up.

## Risk register

1. **Store size growth.** sweepDuplicates no longer deletes. A high-churn writer that repeatedly saves identical bodies will accumulate beads linearly instead of being capped at 1. Mitigation: the keyword-index + folgezettel-neighborhood surfacing is designed to handle many beads; also, in practice duplicate-body saves across different contexts are the whole point. If a pathological case appears (e.g., a buggy script looping saveCard on one body), add an upstream rate-limiter in the caller, not the store.
2. **`sweepDuplicates` race window.** If writer A reads `content_hash:<short>` at T0 (sees 1 match) and emits reinforces at T1, and writer B commits at T0.5 and runs sweep at T2, writer B must emit reinforces without duplicating A's. The idempotency check in the Green impl (`if (!existing.includes('ref:reinforces:...'))`) handles this, but under extreme concurrency the label read may not see A's write yet. Mitigation: `brLabelAdd` is idempotent at the sqlite layer (the label PK is `(bead_id, label)`), so a duplicate add is a no-op — the check is belt-and-suspenders. TODO: verify in labels.ts whether `brLabelAdd` is truly idempotent; if not, add the constraint.
3. **L4 removal breaks tests that implicitly relied on auto-commit.** Some integration tests may have been passing because L4 conjured a `ref:*` label post-hoc on a body that should have had zero edges. Those tests become regressions that actually catch real behavior — they'll surface as failures in the Red phase. Mitigation: treat each failure case as an opportunity to decide whether the test was asserting the right thing (answer: almost certainly no — L4 auto-commit is the bug being removed).
4. **`reinforces` edge label cardinality growth.** A card body that recurs 20 times produces 19 `reinforces` edges pointing at the oldest. Label queries on `ref:reinforces:*` will see growth. Mitigation: the label index is sparse by design; 19 edges per recurrence is acceptable. Monitor `brLabelList` query latency if recurrence counts exceed ~100 per root.
5. **Migration script double-apply.** If `migrate-from-cosmic.ts` is re-run against a target store that already has post-r04 data, every duplicate-group member will produce NEW beads + NEW reinforces edges (because body hash still matches the already-migrated bead). The store will grow unboundedly on repeated runs. Mitigation: migration script should check for a `migrated-from-cosmic:<sourceId>` label and skip if present. This is pre-existing behavior the script may already have — TODO: verify in migrate-from-cosmic.ts.

## References

- Parent plan: `thoughts/searchable/shared/plans/2026-04-22-tdd-silmari-cascade-extractor.md`
- Review: `thoughts/searchable/shared/plans/2026-04-22-tdd-silmari-cascade-extractor-REVIEW.md`
- Compounding substrate plan: `thoughts/searchable/shared/plans/2026-04-22-tdd-silmari-compounding-substrate.md`
- Luhmann multiple-storage principle: §8 of the parent plan
- bd: `silmari-agent-memory-r04` (P1, open)
- Blocking downstream: `silmari-agent-memory-7h6` (7h6 depends on r04)
- `apps/silmari-mcp/src/lib/card-ops.ts:173-178` — `SaveCardResult` type
- `apps/silmari-mcp/src/lib/card-ops.ts:515` — `saveCard` entry
- `apps/silmari-mcp/src/lib/card-ops.ts:516` — `hashBody`
- `apps/silmari-mcp/src/lib/card-ops.ts:530` — `findByContentHash` call
- `apps/silmari-mcp/src/lib/card-ops.ts:531-537` — early-return to remove
- `apps/silmari-mcp/src/lib/card-ops.ts:353-365` — `findByContentHash` impl
- `apps/silmari-mcp/src/lib/card-ops.ts:382-435` — `sweepDuplicates` impl
- `apps/silmari-mcp/src/lib/card-ops.ts:612` — `brCreate` commit
- `apps/silmari-mcp/src/lib/card-ops.ts:614-696` — `runExtractors`
- `apps/silmari-mcp/src/lib/card-ops.ts:713-739` — keyword fan-out
- `apps/silmari-mcp/src/lib/card-ops.ts:764-819` — L4 anchor block (`:773-806` auto-fire to remove)
- `apps/silmari-mcp/src/lib/edge-extractors.ts:11-17` — Tier A registry
- `apps/silmari-mcp/src/lib/labels.ts:161` — `addEdge`
- `apps/silmari-mcp/src/lib/biblio.ts:120` — external consumer
- `apps/silmari-mcp/scripts/migrate-from-cosmic.ts:417,:426` — migration conditionals
- `apps/silmari-mcp/tests/integration.test.ts:289,:514,:580` — `wasDeduped === true` assertions to rewrite
- Memory: "Silmari framework: no-prune dedup" — body-hash match → save NEW card + reinforces edge, Luhmann multiple-storage
- Memory: "Silmari framework: no MAX_ENTRY_POINTS cap" — keyword entries uncapped
