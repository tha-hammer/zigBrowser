---
date: 2026-04-26T18:30:00-04:00
reviewer: Silmari (via Opus 4.7)
plan_reviewed: thoughts/searchable/shared/plans/2026-04-26-17-56-tdd-three-fix-cascade-stabilization.md
git_commit: 5058492f0751f98d8ca772dbf34952dbfdd1edae
status: NEEDS_MAJOR_REVISION
type: plan_review
---

# Plan Review Report — Three-Fix Cascade Stabilization

## Review Summary

| Category | Status | Issues Found |
|----------|--------|--------------|
| Contracts | ⚠️ | 2 warnings, 1 critical |
| Interfaces | ❌ | 1 critical (invented `--box` flag, 2 invented helpers) |
| Promises | ⚠️ | 2 warnings (B5/B10 contradiction, `${ANTHROPIC_API_KEY}` plumbing) |
| Data Models | ✅ | matches engine exactly |
| APIs | ⚠️ | 1 warning (line numbers stale across the doc) |

**Overall**: The strategic narrative is sound — Fix 1+2+3 attack the right layers in the right order, the TDD discipline is honest, and the engine surface (`br create -f markdown.md --json`) really does behave as the plan needs. **But three concrete code-level claims are wrong in ways that would surface on first compile**, and most line numbers throughout the plan are off by ±25–80 lines. Fix the critical issues, regenerate line refs, and this is implementable.

---

## Verification Pass — File / Line Claims

### Fix 1 — Docker-compose

| Claim | Result | Actual |
|---|---|---|
| Lines 8-28 are pipeline env block | ✅ | confirmed |
| Block contains 10 named vars | ✅ | confirmed (SILMARI_DIR…WORKSPACE_DIR) |
| `ANTHROPIC_API_KEY` not present | ✅ | confirmed (zero hits) |
| Lines 60-63 mount `~/.claude/.credentials.json` | ✅ | confirmed |
| Single `pipeline` service | ✅ | confirmed |
| `import.meta.dir` pattern in tests | ✅ | matches `atomicity.test.ts:22` |
| Test file does not yet exist | ✅ | confirmed NEW |

### Fix 2 — card-ops.ts + test file (line numbers DRIFTED)

| Plan claim | Actual location | Delta |
|---|---|---|
| Degrade-to-root block at 591-602 | **618-625** | +27 |
| `resolveExplicitTarget` at 497-540 | **490-556** | function spans wider |
| WAL-race retry inside resolve | **523-531** | (within the function) |
| Console.error degrade-log | **540-542** | (matches the message verbatim) |
| Catch block `if (explicitTarget) throw err` | **639-648** | +34 |
| Ambiguous-matches throw | **line 546** | +4 |
| Existing degrade test in test file | **187-201** | +9 |
| Caller-bug rejection tests | **203-257** | +7 |
| Test to delete (`degraded save lands a real card`) | **line 259** | +20 |
| `bd 929` section header comment | **line 178** | confirmed |
| `safeDispatch`, `liveIt` helpers | 38-45, 33-35 | confirmed |
| `readCursors` exported from folgezettel.ts | **line 208** | confirmed |

**All Fix 2 SEMANTIC claims hold.** The diff blocks in the plan accurately describe code that exists; only the line numbers framing them are stale.

### Fix 3 — engine surface (`vendor/beads_rust`)

| Claim | Result | Evidence |
|---|---|---|
| `execute_import` at 514-883 | ✅ | confirmed |
| Accepts `-f`/`--file` flag | ✅ | `cli/mod.rs:1034-1035` |
| `## title` H2 per issue | ✅ | `markdown_import.rs:155` |
| `### Labels` / `### Description` H3 sections | ✅ | parser at `markdown_import.rs:175`, sections enum 70-81 |
| `--json` returns array on stdout | ✅ | `create.rs:862-863` |
| **Output order preserved (input order)** | ✅ | explicit reorder loop at `create.rs:815-836` |
| IdCollision sleep 10ms × retries | ✅ | `create.rs:795` |
| Labels comma-separated parsed | ✅ | `markdown_import.rs:259-260, 272-289` |
| Labels accept `kind:foo`, `fz:1_2a`, `box:idea`, `content_hash:abc`, `trunk:5` | ✅ | colon explicitly allowed at `validation/mod.rs:238` |
| **`--box` flag exists on `br create`** | ❌ **DOES NOT EXIST** | not in `CreateArgs` (`cli/mod.rs:961-1036`) |

### Fix 3 — TS infrastructure

| Claim | Result | Notes |
|---|---|---|
| `TOOLS: ToolDef[]` at line 101 | ✅ | confirmed |
| `dispatchTool` switch around 498 | ✅ | confirmed |
| `VALID_CARD_KINDS`, `MODE_ENUM`, `STATUS_ENUM` reachable | ✅ | labels.ts:51, index.ts:85, index.ts:86 |
| `hashBody`, `shortHash` exported | ✅ | card-ops.ts:265, 276 |
| `resolveExplicitTarget` exported | ⚠️ | **module-private** at card-ops.ts:490 — fine if `saveCardsBatch` lives in same file (plan does this) |
| `findByContentHash`, `sweepDuplicates` exported | ✅ | 367, 423 |
| `readCursors`, `assignFolgezettel`, etc. | ✅ | imported from folgezettel.ts |
| `contentHashLabel` … `sourceLabel` | ✅ | labels.ts (lines 40-46 imports) |
| `titleFromBody`, `buildDescription` | ✅ | 288, 298 |
| **`baseFlags`** | ❌ **DOES NOT EXIST** | plan invents this helper |
| `BR`, `TIMEOUT_WRITE` | ✅ | br-adapter.ts:38, 43 |
| Post-save logic at 654-836 | ⚠️ | actual span is **650-878** and tightly woven (see below) |
| **`lookupParentId`** | ❌ **DOES NOT EXIST** | plan invents this helper |
| `saveCardTree` at 248-353 | ⚠️ | actual is **336-441**; +88 line drift |
| `callTool` helper | ✅ | 277-299 |
| `saveArgsForSibling` | ✅ | 246-252 |
| Cascade serial (await per save) | ✅ | confirmed; for…of with await inside |
| Typical cards per transcript: 26 | ❌ | actual: thesis 1, themes ~3-8, ideas ~20-50, **micros ~100-300+** → ~150 total holds; 26 is unrealistic for B10 fixture |

---

## Critical Issues (must fix before implementation)

### C1 — `br create --box <idea\|biblio>` does not exist (Fix 3)

The plan's `saveCardsBatch` calls:

```typescript
execFileSync(BR, ['create', '-f', tmpFile, '--json', ...baseFlags(opts[0].box)], …)
```

`CreateArgs` in `vendor/beads_rust/src/cli/commands/mod.rs:961-1036` has no `box` field. There is **no `--box` flag**. The first invocation will fail argument parsing.

**Why this matters**: Box-ness is determined today by **label** (`box:idea` / `box:biblio`), not by a CLI flag. The existing single-card `saveCard` likely encodes box via the label set, not by any flag. The plan's `baseFlags(opts[0].box)` line is a phantom helper around a phantom flag.

**Recommendation**:
1. Drop `baseFlags(...)` from the spread.
2. Encode box via `boxLabel(o.box)` in the per-card label list (which the plan already does at line 716 of the proposed code) — that's already the source of truth.
3. Verify that `br create -f` reads box semantics from labels (highly likely given how `box:idea` is added at label-build time today). If `br create` has any *other* mandatory flag the existing `saveCard` passes (cwd / repo / db path / `--json`), enumerate those explicitly in the diff rather than hiding them behind a non-existent helper.
4. Read the current `saveCard` brCreate invocation (somewhere around card-ops.ts:674-682) and document **literally** the flag set it uses, then replicate that exact set minus `-f` and plus the markdown file, plus any other required-on-import flags. No invented helpers.

### C2 — `lookupParentId` does not exist (Fix 3)

The plan's `runPostSaveSteps` invocation passes:

```typescript
parentCardId: p.parentSequence ? lookupParentId(p.opts.trunk, p.parentSequence) : null,
```

Grepping confirms no such function in card-ops.ts or anywhere else. The existing single-card path resolves parent via `resolveExplicitTarget` (which returns `parentCardId` directly inside `ExplicitTarget`) for the explicit-fork case, and via cursor lookup for the continue case.

**Recommendation**:
1. Reuse `resolveExplicitTarget`'s return value (`ExplicitTarget` includes the parent issue id) — store it in the `Prepped` struct alongside `parentSequence`.
2. For continue-mode (cursor parent), see how the existing `saveCard` resolves parent id from a cursor sequence (likely a `findByFzLabel`-style query around card-ops.ts:711-719 per the verification report) and call that same primitive.
3. Don't introduce a new helper name; reuse what exists.

### C3 — `runPostSaveSteps` extraction is the load-bearing refactor, not a clean-up

The plan describes the post-brCreate extraction as the "meaningful refactor" but treats it as a one-paragraph note. Verification shows lines 650-878 (~228 lines) are **tightly woven**:

1. Labels (652-661) → 2. Title/Description (663-671) → 3. brCreate (674-682) → 4. Sweep (686) → 5. Tier A edges (688-771: runExtractors → addEdge loop, line-of-thought gathering, context build) → 6. Reinforces edge (773-792: emitReinforcesToPrior + consolidation-review labels) → 7. Keyword writes (794-836: extractTerms → addKeywordEntry loop) → 8. L4 anchor check (838-869).

The Tier A pipeline alone is 80+ lines and depends on `self.id`, the full label set, `titleCandidateIds`, and a constructed context object. **Extracting this safely without losing behavior parity is real work** — likely 2-3 hours alone, with new tests for the extracted helper to prevent drift between saveCard and saveCardsBatch.

**Recommendation**:
1. Either (a) call out the runPostSaveSteps extraction as its own labeled phase (Fix 3a) with TDD: write a parity test pinning saveCard's current end-to-end output, do the extraction, confirm parity test still passes, *then* land saveCardsBatch on top; or (b) acknowledge in the plan that saveCardsBatch will **inline-duplicate** the post-save logic in v1 and the extraction is filed as immediate follow-up. Either is honest; the current "extract in the refactor pass" undersells the cost.
2. Add the parity test described above as a precondition. Without it, drift is silent.

---

## Warnings (should address but not blocking)

### W1 — B5 ("single subprocess for any N≥1") contradicts B10 + R3 (two-tier per transcript)

The plan's behavior B5 says: "Single subprocess invocation for any N≥1." B10 then describes a 2-tier flow: tier 1 = thesis alone, tier 2 = themes+ideas+micros. Risk register R3 acknowledges this: "Fix 3's tier 1 + tier 2 split (thesis alone, then everything else) still needs 2 subprocess calls per transcript".

These three statements collide. Either:
- B5 should be reworded as "single subprocess invocation per `zk_save_cards` call" (the per-MCP-call guarantee), and B10/R3 stand as the per-transcript reality (2 calls, 75× reduction); OR
- The cascade refactor should pre-compute the thesis address speculatively (B10's "future optimization") so a single batch does work — but R3 explicitly defers that.

**Recommendation**: keep the 2-tier reality (it's still 75× reduction; rkl gets fixed). Reword B5 to scope the guarantee to a single `zk_save_cards` call, not per-transcript. Add an explicit B10b test that asserts cascade fires `zk_save_cards` exactly **2 times** per transcript (thesis + cascade-tier-2), not 1.

### W2 — `${ANTHROPIC_API_KEY}` substitution depends on shell env at `docker compose up` time

No `.env` file exists in `scripts/kc-baker-pipeline-v2/`, no `env_file:` directive in docker-compose.yml. The interpolation works only if the operator exports `ANTHROPIC_API_KEY` in the same shell that runs `docker compose up`. If they don't, the env var is empty inside the container — silently — and Gate B fails identically to today.

**Recommendation**:
1. Document the export step in the manual checklist of Fix 1 (the plan's "Manual" section already says "Set `export ANTHROPIC_API_KEY=sk-...` in host shell" — reinforce that this is **mandatory**, not optional).
2. Optionally add a startup guard inside the container (the existing entrypoint or a small check in the cascade orchestrator) that fails fast with a clear message if both the credential file is expired AND the env var is empty. Out of scope for Fix 1's diff but worth filing as a follow-up.
3. Consider an `env_file: .env.local` directive (gitignored) so operators can persist the key. Optional; smallest viable fix is documentation.

### W3 — Line numbers stale throughout the document

Every concrete line-number reference checked is off by 4-88 lines:
- Fix 2 line refs all drift by +25 to +34.
- Fix 3 line refs drift by +88 (saveCardTree) and +24 (post-save block).

The diff blocks themselves are correct (the code at the *content* level matches), but if an implementer searches by line number they'll land in the wrong place every time.

**Recommendation**: regenerate line numbers against the current commit (`5058492`) before implementation begins. Either (a) update the plan once before starting, or (b) add a header note: "Line numbers are illustrative; navigate by content matchers."

### W4 — B10 test fixture uses 26 cards; representative is ~150

The B10 spec says "1 thesis + 4 themes + 7 ideas + 14 micros = 26 cards". Real cascade output is closer to 1 + 5 + 35 + 200 = ~240 (per `ingest-cascade.ts:593-598` which actually annotates the typical sizes). At 26 cards the batch advantage is marginal; rkl ETIMEDOUT does not fire that low. The test fixture should use a card count that's representative *or* there should be a separate stress test that exercises N≥150.

**Recommendation**: add a stress test (potentially `liveIt`-skipped by default unless an env flag enables it) that generates ~200 cards and asserts the batch completes without ETIMEDOUT under realistic load. The existing 26-card test stays as the correctness check; the stress test guards against rkl regression.

### W5 — `resolveExplicitTarget` is module-private

Verification shows `resolveExplicitTarget` is not exported from card-ops.ts. The plan's proposed `saveCardsBatch` calls it directly (line 685 of the proposed code). This works **only** because `saveCardsBatch` is being added to the same file. Worth a one-line note in the plan: "Both `saveCard` and `saveCardsBatch` live in card-ops.ts; `resolveExplicitTarget` stays module-private."

---

## Well-Defined (no action needed)

- ✅ The strategic narrative — three layers, three commits, each independently revertible.
- ✅ Cross-cutting invariants 1-6 are crisp and verifiable.
- ✅ The risk register catches R3 (2-tier subprocess), R4 (label-form preservation), R5 (cursor-write race) — these are real and acknowledged.
- ✅ The engine surface assumptions ALL match reality: markdown structure, comma-separated labels, colon-bearing label values, JSON output, input-order preservation, IdCollision retry. Fix 3's foundation is solid.
- ✅ TDD discipline: each behavior has a specified Red test that genuinely fails on current code (verified for Fix 1, Fix 2 hard-fail, Fix 2 cursor-immutability).
- ✅ Anti-criteria are non-trivial and well-chosen (especially "Do NOT remove the 929 retry primitive" and "Do NOT batch Tier A edges in this commit").
- ✅ Sequencing rationale (Fix1 → Fix2 → Fix3) is sound; each unblocks the next without coupling them tightly.

---

## Suggested Plan Amendments

```diff
# In "Current State Analysis → Key file locations":
- - apps/silmari-mcp/src/lib/card-ops.ts:591-602
- - apps/silmari-mcp/src/lib/card-ops.ts:497-540
- - scripts/kc-baker-pipeline-v2/ingest/ingest-cascade.ts:248-353
+ - apps/silmari-mcp/src/lib/card-ops.ts:618-625 (the 929 degrade I shipped in cbce4d1)
+ - apps/silmari-mcp/src/lib/card-ops.ts:490-556 (resolveExplicitTarget)
+ - apps/silmari-mcp/src/lib/card-ops.ts:639-648 (saveCard catch)
+ - apps/silmari-mcp/src/lib/card-ops.ts:650-878 (post-brCreate pipeline; runPostSaveSteps target)
+ - scripts/kc-baker-pipeline-v2/ingest/ingest-cascade.ts:336-441 (saveCardTree)

# In "Fix 3 → Behavior B5":
- **Behavior B5**: Single subprocess invocation for any N≥1.
+ **Behavior B5**: A single `zk_save_cards` call invokes `execFileSync(BR, ['create', '-f', ...])` exactly once for any N≥1.
+ **Behavior B5b**: Per-transcript, cascade fires `zk_save_cards` exactly twice (thesis tier + tier 2 with themes+ideas+micros). Asserted via mock-call counter on the cascade test.

# In "Fix 3 → 🟢 Green: Minimal Implementation" (saveCardsBatch):
-     execFileSync(BR, [
-       'create', '-f', tmpFile, '--json', ...baseFlags(opts[0].box),
-     ], {
+     execFileSync(BR, [
+       'create', '-f', tmpFile, '--json',
+       // box-ness is encoded in the per-card label set via boxLabel(); br create
+       // has NO --box flag (verified vendor/beads_rust/src/cli/commands/mod.rs:961-1036).
+       // Replicate any other flags the existing saveCard brCreate passes (db path,
+       // cwd, etc.) — not invented helpers.
+     ], {

-     parentCardId: p.parentSequence ? lookupParentId(p.opts.trunk, p.parentSequence) : null,
+     // parentCardId: explicitTarget already carries it; for continue-mode use the
+     // same primitive saveCard uses today around card-ops.ts:711-719 (do NOT
+     // introduce lookupParentId — it doesn't exist).
+     parentCardId: p.explicitTarget?.parentCardId ?? resolveCursorParentId(p.opts.trunk, p.parentSequence),

# Add a new phase:
+ ## Fix 3a: Extract runPostSaveSteps (precondition for Fix 3)
+ Effort: 2-3h
+ Test strategy: write a parity test that pins saveCard's end-to-end output (id +
+ labels + edges + keywords + reinforces) for a fixture set; extract lines 650-878
+ into a private helper; confirm parity test still green; THEN proceed to Fix 3.
+ Without this precondition, saveCard and saveCardsBatch will silently drift.

# In "Definition of done":
+ - [ ] Line numbers regenerated against the implementation commit before each
+       diff is applied; navigate by content if numbers drift.
```

---

## Approval Status

- [ ] Ready for Implementation
- [ ] Needs Minor Revision
- [x] **Needs Major Revision** — C1 (`--box` flag), C2 (`lookupParentId`), and C3 (post-save extraction undersized) must be resolved. W1 (B5/B10 contradiction) must be reconciled. Once those four land, this is implementable and the strategic story is correct.

---

## bd actions

Per the review process, a tracking issue should be filed for the critical findings:

```
bd create --title="Plan review: three-fix cascade plan needs C1/C2/C3 fixes before impl" \
          --type=task --priority=1 \
          --description="See thoughts/searchable/shared/plans/2026-04-26-17-56-tdd-three-fix-cascade-stabilization-REVIEW.md. Three critical issues block implementation: (C1) --box flag does not exist on br create; (C2) lookupParentId is invented; (C3) runPostSaveSteps extraction is its own load-bearing refactor, not a clean-up pass."
```

Run after operator review.
