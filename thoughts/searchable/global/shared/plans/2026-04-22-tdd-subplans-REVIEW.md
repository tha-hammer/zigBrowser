---
date: 2026-04-22
author: Silmari (plan review, round 2)
status: review
reviews:
  - thoughts/searchable/shared/plans/2026-04-22-r04-tdd-savecard-dedup-to-reinforce.md
  - thoughts/searchable/shared/plans/2026-04-22-7h6-tdd-keyword-index-uncap.md
  - thoughts/searchable/shared/plans/2026-04-22-step5.5-tdd-silmari-mcp-primitives.md
findings-files:
  - MEMORY/WORK/20260422-review-findings-r04.md
  - MEMORY/WORK/20260422-review-findings-7h6.md
  - MEMORY/WORK/20260422-review-findings-step5.5.md
topic: "Pre-implementation verification of the three cascade-extractor sub-plans against the actual codebase"
tags: [silmari, review, r04, 7h6, step5.5, pre-implementation]
---

# Review Report: Cascade-extractor sub-plans (r04 + 7h6 + Step 5.5)

## Review Summary

| Plan | ✅ Verified | ⚠️ Warnings | ❌ Critical | Status |
|---|---:|---:|---:|---|
| r04 (saveCard dedup→reinforce) | 12 | 7 | 8 | **Needs Major Revision** |
| 7h6 (MAX_ENTRY_POINTS uncap) | 11 | 7 | 5 | **Needs Major Revision** |
| Step 5.5 (new primitives) | — | several | 4 plan-invalidating | **Needs Replacement** |

**Approval status:** None of the three plans is implementable as currently written. All three drafting agents fabricated helper names, label encodings, and test infrastructure that do not exist in the codebase. The `TODO: verify` markers the plans ship with are not safeguards — they mark places where the agents knew they were guessing, and the guesses were wrong more often than not.

**The good news:** the *intent* of each plan is correct. The behavioral targets, the TDD cycle structure, the decision log, and the cross-plan sequencing all stand. Only the code-level specifics need rework.

**The biggest single finding:** **Step 5.5's `hubMembers` is already shipped** as `listHubConstituents` at `apps/silmari-mcp/src/lib/hubs.ts:319-321`. Half of Step 5.5's scope collapses to `export const hubMembers = listHubConstituents;` (a one-line re-export for naming consistency). The other half — `filterByKeywordOverlap` — is MUCH bigger than drafted, because the keyword substrate doesn't work the way the plan assumed. See §Step 5.5 below.

---

## Cross-Cutting Pattern: What went wrong across all three plans

The three drafting agents all made the same class of mistake — inventing API names and label encodings that sounded plausible. The specific fabrications:

| Plan | Fabricated | Actual |
|---|---|---|
| r04 | `addLabel(box, id, label)` | `brLabelAdd(box, id, ...labels)` at `br-adapter.ts:463` |
| r04 | `getLabels(box, id)` | `brShow('idea', id).labels` at `br-adapter.ts:304-319` |
| r04 | `brListByLabel(box, label)` | `brList({box, labels, all, limit})` at `br-adapter.ts:*` |
| r04 | `telemetry.emit(...)` | No such module — would need to ship one or use `console.error` spy |
| r04 | `_testingSuppressPreCheck` test seam | No such seam — existing pattern is env-var (`SILMARI_DISABLE_L4=1`) |
| r04 | `setupTestStore()` at `tests/helpers/setup.ts` | No such helper; real tests use `mkdtempSync` + env vars + `silmariInit()` |
| Step 5.5 | `hub-id:<hubId>` labels on cards | `ref:derives-from:<hubId>` — there is NO `hub-id:*` label anywhere in the codebase |
| Step 5.5 | `kw:<term>` labels on cards | `keyword:<normalized>` is the label constant, but it's **never called** — keyword data lives in a sqlite table `keyword_entries`, not on card labels |
| Step 5.5 | `resolveAddressToBead` helper | Does not exist; must compose via `fzLabelFromAddress` + `brList` OR `scanTrunk(trunk).beadsBySequence.get(sequence)` |
| Step 5.5 | `brShow(id)` throws on missing | Returns `null`; requires `(box, id)` — two args, not one |
| 7h6 | `addKeywordEntry({term, address})` | `addKeywordEntry({term, entryPoint, curator, force?})` — `curator` is **required** |

**Why this matters for implementation:** an engineer working from these plans as written will spend their first hour in a compile-error loop before realizing the plan is fiction. The plans need to be either (a) rewritten against real APIs, or (b) shipped as-is with explicit "these code snippets are PLACEHOLDER — check the real API before pasting" stickers. (a) is strongly preferred.

---

## Plan 1: r04 (saveCard dedup→reinforce)

### Critical issues (must fix before implementation)

**C1 — `saveCard(opts)`, not `saveCard(box, opts)`.** Every Red test snippet in the plan has the wrong call shape. `SaveCardOpts` is a discriminated union that includes `box` as a field. Tests will not compile.
- **Fix:** Rewrite every `saveCard(box, {...})` → `saveCard({box, ...})` across Behaviors 1, 2, 3, 4, 5, 6, 7, 8.

**C2 — `reinforces` is a REVIEWED edge, not AUTO** (`labels.ts:89-95`). `REVIEWED_EDGE_TYPES` includes `reinforces`. The documented flow for REVIEWED edges is `proposeOrAddEdge` which QUEUES for human review. `addEdge` will still write the label (the function doesn't discriminate), but bypassing the review queue is a deliberate semantic choice that the plan currently does silently.
- **Fix:** Add a paragraph to the r04 plan explicitly stating: "r04 writes `reinforces` via `addEdge` directly — NOT via `proposeOrAddEdge` — because the body-hash recurrence signal is deterministic, not semantic. The review queue is reserved for LLM-generated proposals."
- **Also fix:** consider whether the `needs-consolidation-review:true` label serves a similar review-gate role for these reinforces — if so, document that explicitly as the replacement mechanism.

**C3 — Fabricated helper `addLabel` → real function is `brLabelAdd`.** Used ≥4 times in plan code snippets for `needs-consolidation-review:true`.
- **Fix:** Global find/replace `addLabel(box, id, label)` → `brLabelAdd(box, id, label)` and verify the variadic `...labels` shape is compatible with the plan's usage (batch the two labels into one call where possible).

**C4 — Fabricated helper `getLabels` → use `brShow('idea', id).labels`.** Every test assertion in the plan uses `getLabels`.
- **Fix:** Rewrite every test-side `const labels = await getLabels(box, id);` → `const { labels } = (await brShow(box, 'idea', id)) ?? { labels: [] };`. Note the null-coalesce because `brShow` can return null.

**C5 — Fabricated helper `brListByLabel` → real function is `brList({box, labels, all, limit})`.** Used in the `sweepDuplicates` Green pseudocode.
- **Fix:** Rewrite pseudocode to use the real signature.

**C6 — `telemetry.emit()` module doesn't exist.** Behavior 5 (L4 anchor check) asserts against it.
- **Fix:** Either (a) ship a tiny `apps/silmari-mcp/src/lib/telemetry.ts` shim as part of r04 (~15 LOC — a function that writes to stderr or a JSONL file), or (b) reformulate Behavior 5's assertion as "the inference function was not invoked" using a spy. (b) is simpler and doesn't add surface area.

**C7 — `_testingSuppressPreCheck` test seam doesn't exist.** Behavior 4's concurrency test imports it to force both writers into the race path.
- **Fix:** Use the existing env-var seam pattern — set `SILMARI_DISABLE_FINDBYCONTENTHASH=1` (or similar, to be added) in the test's beforeEach. Make the seam name explicit in the test and document it in the plan.

**C8 — `sweepDuplicates` arg order in the plan's Green is wrong.** Actual signature is `sweepDuplicates(box, fullHash, createdId)`, plan wrote `sweepDuplicates(box, newId, fullHash, shortHash)`.
- **Fix:** Rewrite the Green code to match the real signature; adjust call sites to pass the arguments in the right order.

### Warnings

- **W1 — `wasDeduped` read count is 8, not 6.** Plan missed two `=== false` assertions at `integration.test.ts:267, :506` that will also break under the type change.
- **W2 — 4 edge-extractors, not 3.** `edge-extractors.ts` has `extractTitleMentions` at `:163` in addition to the three the plan lists. File docstring is outdated.
- **W3 — `findByContentHash` does no explicit sort today.** Behaviors 4 and 7 both require deterministic "oldest wins" selection. Plan mentions this in prose (line 134) but the Green pseudocode doesn't include the sort. Add it.
- **W4 — MCP tool description at `index.ts:89-91`** still claims "saving identical body twice returns the same id." Must be updated as part of r04 (similar to 7h6's description update).
- **W5 — `tests/helpers/setup.ts`** path does not exist. Real test pattern is inline `mkdtempSync` + env var + `silmariInit()`. Rewrite every test's setup block.
- **W6 — Concurrency test must escape `SILMARI_DISABLE_L4=1`** set at `integration.test.ts:27` or Behavior 5's assertions will be vacuous.
- **W7 — `sweepDuplicates` was arguably already doing the wrong thing.** Existing behavior deletes the race loser; r04 changes it to keep both + reinforce + flag. This is not backward-compatible. Any test elsewhere that exercised the race deliberately needs review.

### Verified correct
SaveCardResult shape (modulo signature), `findByContentHash` location, early-return `:531-537`, `sweepDuplicates` location, L4 block location, `biblio.ts:120` wrapping, migration script lines `:417, :426`, `SILMARI_TIER_B_CONFIDENCE_THRESHOLD` default 0.7, `mode: 'root'` validity, decision-locked intent (keep both + reinforce + flag).

---

## Plan 2: 7h6 (keyword-index MAX_ENTRY_POINTS uncap)

### Critical issues

**C1 — Wrong arg shape in every code snippet.** Plan uses `{term, address}` and omits `curator`. Real signature is `{term, entryPoint, curator, force?}` with `curator` **required**. Every Red test fails on a type error instead of the behavioral assertion.
- **Fix:** Rewrite every `addKeywordEntry({term, address: '...'})` → `addKeywordEntry({term, entryPoint: '...', curator: 'test' /* or real value */})`.

**C2 — Wrong test fixture pattern.** Plan uses `beforeEach` to set `SILMARI_DIR`. All real tests in the repo set it at module scope **before** `await import(...)` — because `bun-sqlite` caches the db binding on first import (see memory entry `feedback_bun_sqlite_gc_before_subprocess.md`).
- **Fix:** Rewrite every test's fixture to the module-scope pattern. Copy from an existing keyword-index test for the canonical shape.

**C3 — Missed production callers.** `card-ops.ts:722` (save-time L2 keyword writer, `force:false`) and `index.ts:620` (MCP dispatcher for `zk_keyword_add`) both call `addKeywordEntry` and are not in the plan's migration surface.
- **Fix:** Add both callsites to the migration list. The MCP dispatcher change is especially important — it's the public API boundary.

**C4 — Missed pipeline + schema callers.** `scripts/kc-baker-pipeline/ingest.ts` passes `force:true` via MCP; JSON schema at `index.ts:295` still advertises `force`. Plan doesn't update the tool's `inputSchema`.
- **Fix:** Either remove `force` from the schema (breaking change, document it) or leave the parameter as a no-op with a JSDoc deprecation note. Pick one.

**C5 — Bootstrap script has semantic impact.** `bootstrap-keyword-index.ts:218-222` short-circuits on `rejected-full`. After 7h6, the variant disappears and the bootstrap will index unlimited candidates per term. Plan doesn't address this or the three tests (`bootstrap-keyword-index.test.ts:170-210` + `keyword-index-sqlite.test.ts:142-153`) that assert the cap.
- **Fix:** Rewrite the bootstrap's short-circuit as "if `kind === 'already-present'`, stop; otherwise continue" and migrate the three tests.

### Warnings

- **W1 — Line `index.ts:251` has drifted.** `zk_keyword_add`'s real description is at `index.ts:287`. Plan references `:251` 8+ times.
- **W2 — `package.json` is `version: "0.0.0"` + `private: true`.** The plan's "semver major version bump" framing is empty theater for this package. Document the API break in a MIGRATION.md or the README instead.
- **W3 — `zk_status` doesn't expose `keyword_index_max_entries`.** The alpha-smoke assertion the plan proposes requires a code addition first. Either add it or drop the assertion.
- **W4 — No `CHANGELOG.md` exists.** Plan says "create if missing" — it's missing. Create it or delete the instruction.
- **W5 — 6 source files import `MAX_ENTRY_POINTS`.** Plan doesn't enumerate them. Add the list so the migration is complete.
- **W6 — Bump the MCP description in the same commit as the constant deletion** so readers of the git log don't see inconsistent state between commits.
- **W7 — `AddKeywordResult.kind === 'replaced'` test callsites.** The plan lists these as the migration surface but doesn't grep the actual files. Do the grep; expected count is small (<10) but needs to be known.

### Verified correct
`MAX_ENTRY_POINTS = 4` at `:88`, 4-variant `AddKeywordResult` union at `:74-78` (names match character-for-character), FIFO body at `:368-379`, FIFO-as-design comment at `:287-291`, `lookupKeyword` at `:261`, `readKeywordIndex` at `:236`, `addKeywordEntry` at `:298`, `removeKeywordEntry` at `:394`, `navigate()` at `:626`, MCP description semantics.

---

## Plan 3: Step 5.5 (new silmari-mcp primitives)

**Status: needs replacement, not revision.** Two of the four critical findings are plan-invalidating — not "fix a line" but "the whole design assumed a substrate that doesn't exist."

### Critical issues

**C1 — `hubMembers` is ALREADY SHIPPED as `listHubConstituents`.**
- Location: `apps/silmari-mcp/src/lib/hubs.ts:319-321`
- Implementation: `listInbound('idea', hubId, 'derives-from', 1000)` — exactly what the plan specifies
- Hub membership encoding: `ref:derives-from:<hubId>` on the card (NOT `hub-id:<hubId>` as the plan assumed). Zero grep hits for `hub-id:` anywhere in the codebase.
- `addCardToHub` at `hubs.ts:310-312` writes the derives-from edge
- **Fix:** Replace Step 5.5's `hubMembers` section with `export const hubMembers = listHubConstituents;` OR simply import and use `listHubConstituents` at the cascade Gate B callsite. Delete the `hub.ts` file from the plan's file-placement section — it's unnecessary. Update the cascade plan's Decisions-locked block to note this simplification.

**C2 — `filterByKeywordOverlap` premise is broken.**
- The plan's Green pseudocode does `source.labels.filter(l => l.startsWith('kw:'))` to get the source card's keyword terms.
- There are NO `kw:*` labels on cards. The keyword label constant `keywordLabel(term) → 'keyword:<normalized>'` exists at `labels.ts:179-185` but is NEVER CALLED — grep for `keywordLabel` outside its own definition + unit test returns ZERO hits.
- Keyword data lives in the sqlite table `keyword_entries`, indexed term→address. To get a card's keyword terms, you would need to scan the entire keyword index for entries whose `entry_points` contain the card's address. That's O(N) per card and not what the plan describes as an O(1) lookup.
- **Fix:** This is a SUBSTRATE CHANGE, not a primitive wrap. Options:
  - **(a) Ship a reverse index.** Add a `card_keywords` sqlite table (card_id → [term, term, term]) written by `addKeywordEntry`. Then `filterByKeywordOverlap` becomes a two-table query. ~3-4 hours of work, not the ~1 hour the current plan implies.
  - **(b) Change the source signature.** Pass the keyword terms INTO `filterByKeywordOverlap` from the caller (who already knows them at save time). The primitive becomes `filterByKeywordOverlap(terms: string[], minOverlap=2): BeadRow[]` — skips the reverse-lookup problem entirely. The cascade pipeline's Gate B candidate enumeration already has the new card's terms in scope (Pass 2/3 produced them).
  - **Recommendation: (b)**, because it matches how the cascade actually uses the primitive, avoids a substrate change in scope, and is implementable against the existing sqlite keyword_entries table.

**C3 — `resolveAddressToBead` is fabricated.** Zero grep hits. The plan's Behavior 2 Green code will not compile.
- **Fix:** Compose via `fzLabelFromAddress(address)` + `brList({box, labels: [fzLabel], limit: 1})` OR `scanTrunk(trunk).beadsBySequence.get(sequence)`. Both exist; pick one and document it.

**C4 — `brShow` returns `null`, not throws.**
- Signature: `brShow(box, id)` — two args
- Return: `BeadRow | null`
- Module-level docstring explicitly says "No exceptions escape"
- Plan's Behavior 6 ("missing source throws") is wrong — under real semantics, `filterByKeywordOverlap` must decide what to do on `null` (return `[]` or wrap the null in its own throw).
- **Fix:** Pick the behavior explicitly. Recommend: return `[]` on missing source (matches the "graceful degradation" pattern of neighbor primitives). Update tests accordingly.

### Warnings

- **W1 — `brList` requires `box` in every call.** Plan omits it in 2-3 snippets.
- **W2 — No `tests/helpers/` directory exists.** Every seed helper the plan uses must be built. Copy the inline setup pattern from an existing MCP test.
- **W3 — No perf-test precedent in the codebase.** Behavior 5's 50ms gate is novel. Document that the plan introduces performance testing as a new class of test, or drop the gate and replace with a functional test.
- **W4 — Cosmic migration writes zero hub-membership labels.** The plan's Risk 2 ("legacy hub-attachment encoding") is actually "no encoding at all for migrated cards" — those cards simply have no hub attached. The fix is upstream (the migration script), not here.

### Recommended action
Rewrite Step 5.5 as: "(a) export `hubMembers` as an alias for `listHubConstituents`; (b) ship `filterByKeywordOverlap(terms: string[], minOverlap=2): BeadRow[]` backed by the existing keyword_entries table." The rewritten plan is ~200 lines, not 437. File the old plan as "superseded" and ship the replacement.

---

## Critical Issues Consolidated (all three plans)

Ranked by priority for fixing:

1. **Step 5.5 reset.** `hubMembers` already exists; `filterByKeywordOverlap` needs a substrate decision (option b recommended). **Rewrite the plan.**
2. **r04 and 7h6 use fabricated helpers** (`addLabel`, `getLabels`, `brListByLabel`, `addKeywordEntry` arg shape). **Global find/replace against the real API across both plans.**
3. **`reinforces` is a REVIEWED edge** — r04's use of `addEdge` directly is correct but must be documented as a deliberate queue bypass.
4. **Test-fixture patterns wrong in both r04 and 7h6.** Module-scope SILMARI_DIR + real setup helpers, not `beforeEach` + fabricated `setupTestStore`.
5. **Missed callers of `addKeywordEntry`** in 7h6 (card-ops.ts:722, index.ts:620, bootstrap-keyword-index.ts, scripts/kc-baker-pipeline/ingest.ts).
6. **Missed `wasDeduped` reads** in r04 (count is 8, not 6).
7. **Missed `extractTitleMentions` extractor** in r04's current-state analysis.

---

## Suggested Plan Amendments (diff form)

### r04 plan
```diff
# In every Behavior's Red test code block:
- saveCard(box, { body, kind: "fact", trunk: 5, mode: "root" })
+ saveCard({ box, body, kind: "fact", trunk: 5, mode: "root" })

- const labels = await getLabels(box, second.id);
+ const { labels } = (await brShow(box, 'idea', second.id)) ?? { labels: [] };

- await addLabel(box, newId, "needs-consolidation-review:true");
+ await brLabelAdd(box, newId, "needs-consolidation-review:true");

# In Behavior 5 (L4 anchor check):
- import { telemetry } from "../src/lib/telemetry";
+ // No telemetry module — use a spy on the inference export
+ import { inference } from "../../../SAI/Tools/Inference";

# In Current state analysis:
+ - edge-extractors.ts:163 — `extractTitleMentions` (4 extractors total, not 3)
+ - integration.test.ts:267, :506 — additional `wasDeduped === false` assertions (8 total, not 6)

# In a new section "Why addEdge not proposeOrAddEdge":
+ r04 writes `reinforces` via `addEdge` directly, NOT via `proposeOrAddEdge`,
+ because body-hash recurrence is a deterministic signal, not an LLM semantic
+ proposal. The `needs-consolidation-review:true` label serves as the human-
+ review gate in place of the proposal queue.
```

### 7h6 plan
```diff
# In every Behavior's Red test code block:
- addKeywordEntry({ term: "voice", address: "1/3a" })
+ addKeywordEntry({ term: "voice", entryPoint: "1/3a", curator: "test" })

# In every test's fixture:
- beforeEach(() => { process.env.SILMARI_DIR = tmpDir(); ... });
+ // At MODULE SCOPE, before the import:
+ process.env.SILMARI_DIR = mkdtempSync(...);
+ const { addKeywordEntry } = await import("../src/lib/keyword-index");

# In "Why this isn't just strip the cap" section:
~ Rename `index.ts:251` → `index.ts:287` (8+ occurrences)

# In "Production callers" / migration surface:
+ - card-ops.ts:722 — save-time L2 writer (force:false path)
+ - index.ts:620 — MCP dispatcher for zk_keyword_add
+ - index.ts:295 — JSON schema advertising `force` parameter
+ - scripts/kc-baker-pipeline/ingest.ts — pipeline caller (force:true)
+ - bootstrap-keyword-index.ts:218-222 — short-circuit on rejected-full
+ - bootstrap-keyword-index.test.ts:170-210 — tests asserting cap
+ - keyword-index-sqlite.test.ts:142-153 — tests asserting cap

# Drop the semver/CHANGELOG theater:
- File is version 0.0.0 and private:true — semver major bump is moot.
+ Document the breaking change in README or a new MIGRATION.md.
```

### Step 5.5 plan — full rewrite
Replace with a two-section plan:
1. `hubMembers` → one-line re-export of `listHubConstituents` from `hubs.ts`; one test verifying the re-export preserves behavior; document in cascade Gate B's graph-candidates.ts that this is the hub-query path. No new file.
2. `filterByKeywordOverlap(terms: string[], minOverlap: number = 2): BeadRow[]` backed by the existing `keyword_entries` sqlite table; caller passes the new card's keyword terms in directly (they are in scope at cascade Gate B, produced during Pass 2/3 extraction). Tests cover overlap correctness, sort order, empty inputs.

---

## Approval status

- [ ] Ready for Implementation
- [ ] Needs Minor Revision
- [x] **Needs Major Revision** (r04, 7h6) + **Needs Replacement** (Step 5.5)

**Next step:** File a single bd issue `silmari-agent-memory-*-subplans-review` capturing this meta-finding, and block r04 + 7h6 + f23 on it. Engineer takes the REVIEW findings, does the global find/replace + test-fixture migration on r04 and 7h6, and fully rewrites Step 5.5 against the real substrate. Re-request review afterwards.
