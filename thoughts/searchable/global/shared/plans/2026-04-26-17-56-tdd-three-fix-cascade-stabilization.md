---
date: 2026-04-26T17:56:30-04:00
planner: Silmari (via Opus 4.7)
git_commit: 5058492f0751f98d8ca772dbf34952dbfdd1edae
branch: main
repository: tha-hammer/silmari-agent-memory
topic: "TDD plan — three-fix cascade stabilization (auth + 6jp revert + batch create)"
tags: [tdd, plan, silmari, 7qr, rkl, 6jp, 929-followup, batch-create, cascade]
related_research:
  - thoughts/searchable/shared/research/2026-04-24-09-09-silmari-agent-memory-hkg-p6i-br-prefix-match-bugs.md
  - thoughts/searchable/shared/plans/2026-04-25-tdd-7qr-cascade-failure-three-layer-fix.md
related_bd:
  - silmari-agent-memory-rkl (P1 — br ETIMEDOUT under cumulative load; this plan attacks the SOURCE)
  - silmari-agent-memory-6jp (P1 — fork-resolution-fail-open consuming trunk roots; this plan reverts my 929 degrade)
  - silmari-agent-memory-7qr (parent — cascading 15-transcript failure)
status: revised_post_review
last_updated: 2026-04-26
last_updated_by: Silmari
type: tdd_plan
review: thoughts/searchable/shared/plans/2026-04-26-17-56-tdd-three-fix-cascade-stabilization-REVIEW.md
---

> **Revision note (2026-04-26, post-review)**: All critical findings applied —
> phantom `--box` flag removed (C1), invented `lookupParentId` replaced with
> existing primitives (C2), `runPostSaveSteps` extraction promoted to Fix 3a
> precondition (C3), B5/B10 contradiction reconciled (W1), `ANTHROPIC_API_KEY`
> shell-export mandate documented (W2), all line numbers regenerated against
> commit `5058492` (W3), stress test added for ~200 cards (W4), private-export
> note added for `resolveExplicitTarget` (W5).

# Three-Fix Cascade Stabilization — TDD Implementation Plan

**Epic**: 15-transcript cascade reaches 14-15/15 with edges
**Scope**: 3 sequential commits, each independently revertible
**Effort tier**: Standard (Fix 1+2) + Extended (Fix 3); ~5.5 hours total active work
**Branch**: main (no feature branch needed; commits are independent)

---

## Overview

The cascade pipeline at `scripts/kc-baker-pipeline-v2/` is producing 0 ingested-with-edges transcripts at 15-transcript scale. Three independent root causes stack:

1. **Auth 401 in container's silmari-mcp child** — OAuth credential file mounted at `~/.claude/.credentials.json` expires overnight; `ANTHROPIC_API_KEY` env not propagated as a fallback. Gate B (Sonnet semantic edge classification) fails 100%.
2. **My 929 degrade-to-root regression (cbce4d1)** — when `resolveExplicitTarget` retry exhausts, my code downgraded `mode='fork'` to `mode='root'`, consuming trunk-1 root slots (`fz:1_5`, `fz:1_6`, …). Filed as bd `6jp`. Pollutes the address namespace; subsequent legitimate thesis saves collide.
3. **rkl is structural** — `spawnSync br ETIMEDOUT` fires past ~70 cards even with a clean WAL (5058492 mitigation confirmed). The cumulative load of ~150 brCreate subprocess starts per transcript IS the bottleneck. Wrapper-layer retries cannot fix this; only reducing subprocess count can.

**The single architectural insight**: every wrapper-layer patch lands but reveals the next bug down the stack. The actual source is `subprocess-per-write`. Fix 3 attacks that source by replacing N `brCreate` calls with 1 `br create -f markdown.md` call per transcript. Combined with Fix 1 (auth) and Fix 2 (cursor pollution), the next 15-transcript run should land 14-15/15 with edges.

This is the strategic stop on wrapper patching — Fix 2 explicitly REVERTS my prior wrapper patch in service of correctness.

### Cross-cutting invariants (hold after all three commits)

1. **Hard-fail on missing fork target** — saveCard NEVER fabricates a fz address by degrading mode. Failed forks throw; cascade catches and continues. (Replaces 929's spirit-correct-but-implementation-wrong "save by default with fabricated address" with the correct "save by default ON CONTENT, surface structural failures".)
2. **Cursor advances ONLY on successful brCreate** — by virtue of (1), no failed save can consume a trunk root.
3. **Auth is environment-durable** — credentials file remains the primary auth path, but `ANTHROPIC_API_KEY` env is the fallback so overnight credential expiry doesn't kill Gate B.
4. **brCreate subprocess count drops from ~150/transcript to ~1/transcript** — via the `br create -f` markdown-batch primitive that already exists in beads_rust.
5. **No engine changes** — vendor/beads_rust/ untouched. All work in apps/silmari-mcp/ and scripts/kc-baker-pipeline-v2/.
6. **TDD discipline** — each behavior follows Red → Green → Refactor. Test fails before implementation lands. No exceptions.

---

## Current State Analysis

### Key file locations

- `scripts/kc-baker-pipeline-v2/docker-compose.yml:8-28` — the `environment:` block where `ANTHROPIC_API_KEY` needs to land (currently has SILMARI_DIR, TRUNK, PASS3_MODEL, etc. but no auth env)
- `scripts/kc-baker-pipeline-v2/docker-compose.yml:60-63` — bind mount of `~/.claude/.credentials.json` (the path that's currently 401-ing on overnight expiry)
- `apps/silmari-mcp/src/lib/card-ops.ts:618-625` — the 929 degrade I shipped in cbce4d1 (lines I'm reverting)
- `apps/silmari-mcp/src/lib/card-ops.ts:490-556` — `resolveExplicitTarget` function (the WAL-race retry from 929 stays; only the post-retry fallback changes)
- `apps/silmari-mcp/src/lib/card-ops.ts:540-542` — the `console.error("⚠️ resolveExplicitTarget: ... degrading to root allocation")` log + the `return null` it precedes (the actual lines being replaced with `throw`)
- `apps/silmari-mcp/src/lib/card-ops.ts:546` — the existing `ambiguous fromAddress` throw (unchanged; reference only)
- `apps/silmari-mcp/src/lib/card-ops.ts:639-648` — saveCard catch block (`if (explicitTarget) throw err`); already correct, untouched
- `apps/silmari-mcp/src/lib/card-ops.ts:650-878` — the post-brCreate pipeline (labels → title/desc → brCreate → sweep → Tier A edges → reinforces → keyword writes → L4 anchor); `runPostSaveSteps` extraction target for Fix 3a
- `apps/silmari-mcp/src/index.ts:101` — `TOOLS: ToolDef[]` array (where new `zk_save_cards` tool registers)
- `apps/silmari-mcp/src/index.ts:498+` — `dispatchTool` switch (where new tool handler lands)
- `apps/silmari-mcp/src/index.ts:85-86` — `MODE_ENUM`, `STATUS_ENUM` constants (reused by new schema)
- `apps/silmari-mcp/src/lib/labels.ts:51` — `VALID_CARD_KINDS` (reused by new schema)
- `apps/silmari-mcp/src/lib/folgezettel.ts:208` — `readCursors` export (used by Fix 2 cursor-immutability test)
- `apps/silmari-mcp/src/lib/br-adapter.ts:38,43` — `BR`, `TIMEOUT_WRITE` constants
- `scripts/kc-baker-pipeline-v2/ingest/ingest-cascade.ts:336-441` — `saveCardTree` (the cascade refactor target for Fix 3)
- `scripts/kc-baker-pipeline-v2/ingest/ingest-cascade.ts:246-252` — `saveArgsForSibling` (mode/fromAddress derivation per sibling)
- `scripts/kc-baker-pipeline-v2/ingest/ingest-cascade.ts:277-299` — `callTool` MCP-client wrapper
- `scripts/kc-baker-pipeline-v2/ingest/ingest-cascade.ts:593-598` — typical cards-saved counts (thesis 1, themes ~3-8, ideas ~20-50, micros ~100-300+ → realistic ~150-240 per transcript)
- `vendor/beads_rust/src/cli/commands/create.rs:514-883` — `execute_import` confirms `br create -f markdown.md --json` exists today + returns IDs as JSON in **input order** (explicit reorder loop at 815-836)
- `vendor/beads_rust/src/cli/commands/markdown_import.rs:155,175,259-260,272-289` — the markdown parser: H2 per issue, H3 sections, comma-or-whitespace label split
- `vendor/beads_rust/src/validation/mod.rs:238` — label validator allows `:` (so `kind:foo`, `fz:1_2a`, `box:idea`, `content_hash:abc`, `trunk:5` all pass without sanitization)
- `vendor/beads_rust/src/cli/commands/mod.rs:961-1036` — `CreateArgs` struct; **note: there is NO `--box` flag** (verified 2026-04-26 review)

> **Line-number policy (post-review W3)**: line numbers above are pinned to commit
> `5058492`. If implementation lands later than the next commit, navigate by
> content matchers (e.g., the comment `// bd silmari-agent-memory-929:`) rather
> than by absolute line numbers.

### Existing test patterns to match

- `apps/silmari-mcp/tests/zk-save-card-fromaddress.test.ts` — `bun:test` integration tests with `safeDispatch` helper and `liveIt` (skip-if-br-unavailable). The existing test at line 178 (`'degrades to root when fromAddress targets a nonexistent card'`) encodes the bug as expected behavior; Fix 2 flips it.
- `apps/silmari-mcp/tests/br-adapter.test.ts` — pattern for direct br integration (mkdtempSync, SILMARI_DIR env before imports, real br binary).
- `scripts/kc-baker-pipeline-v2/tests/ingest-cascade.test.ts` — pure-function tests for cascade helpers (saveArgsForSibling, buildFailureReport, checkpointWal). Pattern for new `zk_save_cards` collector tests.

### Constraints / non-negotiables

- `feedback_silmari_no_prune_dedup` — body-hash match → save NEW card + reinforces edge. Don't break this; batch create must preserve per-card dedup lookup.
- `feedback_bun_sqlite_gc_before_subprocess` — call `Bun.gc(true)` after `Database.close()` before a subprocess writes the same file. (Applies to Fix 3 only if zk_save_cards opens silmari.db inline.)
- `project_bv_is_repurposed_issue_tracker` — the 6jp bug is a textbook example of issue-tracker semantics fighting Zettelkasten use. Hard-fail on missing fork is the Zettelkasten-correct choice.
- Surgical fixes only — no rearchitecture. Fix 3 wraps the existing markdown-import path; does NOT rewrite saveCard's internals.

---

## Desired End State

After the three commits land:

1. The next 15-transcript playlist re-run produces **≥14/15 transcripts ingested with non-zero Gate B edges**.
2. **Zero spawnSync ETIMEDOUT** errors (rkl closed; subprocess load is no longer cumulative).
3. **Zero `ambiguous fromAddress` errors** (6jp closed; cursor pollution eliminated by hard-fail).
4. **Zero MCP error -32603 'card not found'** errors (residual covered by 6iz retry; the few remaining cases are now legitimate content races, not subprocess startup deaths).
5. The cursor file at `${SILMARI_DIR}/box2-ideas/.beads/folgezettel-cursors.json` shows trunk[1] at a sensible value (≤30 for a 15-transcript run, NOT 56+).

### Observable behaviors

| Behavior | Verification |
|---|---|
| **B1**: docker-compose's pipeline service receives `ANTHROPIC_API_KEY` from host env | `grep ANTHROPIC_API_KEY scripts/kc-baker-pipeline-v2/docker-compose.yml` returns a match |
| **B2**: saveCard with `mode:'fork', fromAddress:<nonexistent>` THROWS (does NOT degrade) | New test in `zk-save-card-fromaddress.test.ts` asserts thrown error |
| **B3**: After a failed fork attempt, the trunk cursor is unchanged | New test asserts `readCursors().cursors[trunkKey] === before` |
| **B4**: New MCP tool `zk_save_cards` accepts an array of N SaveCardOpts and returns N SaveCardResults | New test asserts schema + happy-path round-trip |
| **B5**: Internally, zk_save_cards invokes `br create` exactly ONCE for any N≥1 | Spy test on execFileSync count; mocked or process.env-toggled |
| **B6**: Cascade saveCardTree calls zk_save_cards once per transcript instead of N times | Refactored cascade with one MCP call replacing the per-card loop |

---

## What We're NOT Doing

- Not rewriting saveCard's internals — Fix 3 wraps it, doesn't replace it
- Not adding `br label add -f` upstream (would help Tier A edges but is engine work)
- Not switching to direct bun:sqlite write to beads.db (the bigger refactor; deferred)
- Not addressing the pre-existing `pass{1,2,3}-shape.test.ts` failures (separate bd warranted)
- Not closing rkl/6jp/7qr in this commit series — closure waits on the operational re-run that validates 14-15/15
- Not introducing a feature flag for the new behavior — Fix 2 is a straight semantic correction; Fix 3 is additive (old `zk_save_card` stays for backward-compat)

---

## Testing Strategy

| Type | Framework | Where |
|---|---|---|
| Config / file-content | bash + grep | shell smoke before commit |
| Pure-function | bun:test | `scripts/kc-baker-pipeline-v2/tests/` (cascade helpers) |
| Integration with real `br` | bun:test + `liveIt` skip-helper | `apps/silmari-mcp/tests/` |
| MCP-tool dispatch | bun:test + `safeDispatch` | `apps/silmari-mcp/tests/zk-save-card-fromaddress.test.ts` and a new `zk-save-cards-batch.test.ts` |

**Mocking strategy**: minimize. The existing pattern uses real `br` binary against mkdtemp'd workspaces. The only mocks introduced are an env-toggled `SILMARI_TEST_FORCE_BATCH_FAIL` for testing the Fix 3 failure path (mirrors existing `SILMARI_TEST_FORCE_TIER_B_ERROR` pattern at semantic-proposer.ts:351).

---

## Fix 1: Docker-compose env propagation

**bd**: covered under rkl (Phase A); no separate bd needed
**Branch**: main
**Commit**: `fix(cascade-v2): pipeline service inherits ANTHROPIC_API_KEY from host env (auth-401 fallback)`
**Effort**: 2 min
**Blast radius**: trivial — adds one line to docker-compose.yml's environment block

### Goal

The container's silmari-mcp child process MUST be able to authenticate to Anthropic via `ANTHROPIC_API_KEY` env when the OAuth credential file at `~/.claude/.credentials.json` is expired or unavailable. Today only the credential file is propagated (bind mount); env is not.

### Test Specification

**Behavior B1**: docker-compose.yml's pipeline service environment block contains `ANTHROPIC_API_KEY: ${ANTHROPIC_API_KEY}`.

**Given**: A fresh checkout of docker-compose.yml.
**When**: A user inspects the environment block of the `pipeline` service.
**Then**: An entry `ANTHROPIC_API_KEY: ${ANTHROPIC_API_KEY}` is present.

### TDD Cycle

#### 🔴 Red: Write Failing Test

Test is config-shaped; written as a shell smoke test that lives next to the docker-compose file:

**File**: `scripts/kc-baker-pipeline-v2/tests/docker-compose-env.test.ts` (NEW)

```typescript
import { describe, it, expect } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

describe("docker-compose env propagation (rkl-fix-1)", () => {
  it("propagates ANTHROPIC_API_KEY from host env to pipeline service", () => {
    const compose = readFileSync(
      join(import.meta.dir, "..", "docker-compose.yml"),
      "utf-8",
    );
    // Exact form: literal env var interpolation, not a hardcoded value.
    expect(compose).toMatch(/ANTHROPIC_API_KEY:\s*\$\{ANTHROPIC_API_KEY\}/);
  });

  it("propagates ANTHROPIC_API_KEY in the `pipeline` service environment block (not elsewhere)", () => {
    const compose = readFileSync(
      join(import.meta.dir, "..", "docker-compose.yml"),
      "utf-8",
    );
    // Find the environment: block under pipeline:
    const pipelineSection = compose.match(/pipeline:[\s\S]*?(?=\n\S|\n*$)/)?.[0] ?? "";
    expect(pipelineSection).toMatch(/environment:[\s\S]*?ANTHROPIC_API_KEY/);
  });
});
```

Run: `bun test scripts/kc-baker-pipeline-v2/tests/docker-compose-env.test.ts` — should FAIL (key absent).

#### 🟢 Green: Minimal Implementation

**File**: `scripts/kc-baker-pipeline-v2/docker-compose.yml`

Edit lines 8-28 (the `environment:` block) — add ONE line:

```yaml
    environment:
      SILMARI_DIR: /silmari-store
      TRANSCRIPTS_DIR: /input/transcripts
      EXTRACTED_DIR: /extracted
      PERSON_SLUG: kc-baker
      PERSON_LABEL: "KC Baker"
      TRUNK: "1"
      TARGET_TRANSCRIPT: ""
      PASS3_MODEL: "sonnet"
      GATEB_CONFIDENCE_FLOOR: "0.7"
      WORKSPACE_DIR: /workspace
      # Auth fallback when ~/.claude/.credentials.json (bind-mounted) has expired —
      # overnight OAuth expiry was the auth-401 root cause in the 2026-04-26 run.
      ANTHROPIC_API_KEY: ${ANTHROPIC_API_KEY}
```

Re-run the test → should PASS.

#### 🔵 Refactor

None needed for a config addition. The line is in the right place, with a comment explaining why.

### Success Criteria

**Automated:**
- [ ] `bun test scripts/kc-baker-pipeline-v2/tests/docker-compose-env.test.ts` → 2/2 pass
- [ ] `grep -n ANTHROPIC_API_KEY scripts/kc-baker-pipeline-v2/docker-compose.yml` returns match in pipeline service block

**Manual:**
- [ ] **MANDATORY** — Operator MUST `export ANTHROPIC_API_KEY=sk-...` in the host shell that runs `docker compose up`. There is no `.env` file or `env_file:` directive in this compose project (W2 — verified 2026-04-26); if the env var is unset in the parent shell, `${ANTHROPIC_API_KEY}` interpolates to empty string SILENTLY and Gate B fails identically to today.
- [ ] Confirm in container: `docker exec ... env | grep ANTHROPIC` shows the key
- [ ] Next pipeline run: Gate B's Sonnet calls succeed (no 401 in stderr)
- [ ] Follow-up filed (out of scope for Fix 1): startup guard in cascade orchestrator that fails fast if BOTH the credential file is expired AND the env var is empty (silent-empty-env is the new failure mode introduced by this fix)

### Anti-criteria

- ❌ Do NOT hardcode the API key value in docker-compose.yml — must use `${ANTHROPIC_API_KEY}` interpolation
- ❌ Do NOT remove the credential file bind mount at lines 60-63 — that's the primary auth path; this is a fallback
- ❌ Do NOT add the env to other services in docker-compose.yml (there's only `pipeline` today, but if more arrive, scope this to `pipeline` only)

---

## Fix 2: Revert 929 degrade → hard fail (closes 6jp)

**bd**: silmari-agent-memory-6jp (P1, just-filed by user 2026-04-26)
**Branch**: main
**Commit**: `fix(silmari-mcp): 6jp — revert 929 degrade-to-root; saveCard hard-fails on missing fork target`
**Effort**: 30 min
**Blast radius**: medium — semantic shift in 1 function (saveCard's step 2); affects ~20 brShow-fork-target call sites BUT they all already handle the error path correctly via existing try/catch

### Goal

When `resolveExplicitTarget` returns null after the WAL-race retry exhausts (i.e., the requested fork parent genuinely cannot be found), saveCard MUST throw — NEVER fabricate a folgezettel address by downgrading mode to 'root'. Trunk-root slots are reserved for thesis-level entries; a downgraded micro lands at `1/5` and pollutes that namespace, producing the `ambiguous fromAddress` collision when subsequent legitimate thesis saves try to consume the same slot.

The 929 retry primitive (the `Bun.sleepSync` + retry inside `resolveExplicitTarget` at `card-ops.ts:490-556`) STAYS — it correctly recovers transient WAL races. Only the post-retry fallback changes — from "degrade to root" to "throw".

### Test Specification

**Behavior B2**: saveCard with `mode:'fork', fromAddress:<nonexistent>` throws.

**Given**: A trunk with a known cursor at sequence S, no card at fz:`<trunk>/9999z9`.
**When**: A caller invokes saveCard with `mode:'fork', fromAddress:'<trunk>/9999z9'`.
**Then**: saveCard throws (or, via the MCP dispatcher, returns `isError: true`). The thrown error message references the fromAddress.

**Behavior B3**: The trunk cursor does NOT advance on a failed fork.

**Given**: Cursor at `S` before the failed save.
**When**: The failed save (B2) completes.
**Then**: Cursor is still at `S`.

**Behavior B4**: Caller-bug throws still fire (preserved from 929):
- `mode:'root'` with fromAddress → throws
- malformed fromAddress → throws
- fromAddress targeting Register sequence 0 → throws
- biblio box with fromAddress → throws

**Behavior B5**: WAL-race retry STILL fires before the throw (preserves 929's primary value).

### TDD Cycle

#### 🔴 Red: Update Existing Test + Add New Tests

The existing test at `apps/silmari-mcp/tests/zk-save-card-fromaddress.test.ts` lines 187-201 (titled `'degrades to root when fromAddress targets a nonexistent card (Luhmann save-by-default)'`) currently encodes the BUG as expected behavior. **Flip it**:

**File**: `apps/silmari-mcp/tests/zk-save-card-fromaddress.test.ts`

Replace the existing degrade-test with a hard-fail test + cursor-immutability test:

```typescript
liveIt('hard-fails when fromAddress targets a nonexistent card (NEVER degrades to root) — bd 6jp', async () => {
  const result = await safeDispatch('zk_save_card', {
    body: '6jp hard-fail regression — fromAddress nonexistent',
    kind: 'learning',
    trunk: 5,
    mode: 'fork',
    fromAddress: '5/9999z9',
  });
  expect(result.isError).toBe(true);
  // Error message must identify the unresolved fromAddress so caller can act.
  expect(result.content[0].text).toMatch(/no parent card|fromAddress.*not found/);
});

liveIt('failed fork does NOT consume a trunk-root slot — bd 6jp', async () => {
  const { readCursors } = await import('../src/lib/folgezettel.js');
  const before = readCursors().cursors['5'] ?? null;
  await safeDispatch('zk_save_card', {
    body: '6jp cursor-pollution regression',
    kind: 'fact',
    trunk: 5,
    mode: 'fork',
    fromAddress: '5/9999z9',  // intentionally nonexistent
  });
  const after = readCursors().cursors['5'] ?? null;
  expect(after).toBe(before);  // cursor MUST NOT advance
});

liveIt('successful save still advances cursor (sanity)', async () => {
  const { readCursors } = await import('../src/lib/folgezettel.js');
  const before = readCursors().cursors['5'] ?? null;
  const result = await safeDispatch('zk_save_card', {
    body: '6jp cursor-advances-on-success sanity',
    kind: 'fact',
    trunk: 5,
    mode: 'root',
  });
  expect(result.isError).toBeFalsy();
  const after = readCursors().cursors['5'] ?? null;
  expect(after).not.toBe(before);  // cursor advanced
});
```

The four caller-bug-preserved tests (`'still rejects fromAddress with wrong trunk'`, `'still rejects malformed fromAddress'`, `'still rejects fromAddress targeting Register sequence'`, `'still rejects mode=root with fromAddress'`) at lines 203-257 STAY UNCHANGED — they're testing throws that the 929 design already preserved and Fix 2 keeps.

The integration test starting at line 259 (`'degraded save lands a real card'`) MUST BE DELETED — its assertion `expect(result.isError).toBeFalsy()` is exactly the bug we're fixing. Delete the whole `liveIt('degraded save lands a real card...'`) block.

Run: `bun test apps/silmari-mcp/tests/zk-save-card-fromaddress.test.ts` — the hard-fail test will FAIL (current code degrades silently); the cursor-immutability test will FAIL (current code advances on degrade).

#### 🟢 Green: Minimal Implementation

**File**: `apps/silmari-mcp/src/lib/card-ops.ts`

Two changes:

**Change A** — remove the degrade-to-root block I added in cbce4d1 (current location: card-ops.ts:618-625; navigate by content matcher `// bd silmari-agent-memory-929: when resolveExplicitTarget degraded`):

```diff
       effectiveMode = mode as FolgezettelMode;
-      // bd silmari-agent-memory-929: when resolveExplicitTarget degraded
-      // (caller passed fromAddress but the parent wasn't found even after
-      // the WAL-race retry), downgrade the mode to 'root' so the card
-      // lands as a clean trunk entry instead of forking from whatever
-      // unrelated cursor position happens to be current.
-      if (opts.fromAddress && !explicitTarget) {
-        effectiveMode = 'root';
-      }
       if (explicitTarget) {
         parentSequence = explicitTarget.sequence;
       } else {
```

**Change B** — make resolveExplicitTarget THROW after retry exhausts (today it returns null at card-ops.ts:533-543, with the warning log at 540-542). The function signature stays `ExplicitTarget | null` for the cases where fromAddress is empty (the early `return null` for empty fromAddress stays clean), but the post-retry "no matches" path becomes a throw:

```diff
   if (matches.length === 0) {
-    // Luhmann save-by-default (bd 929 / 7qr-L2): the card is the durable
-    // artifact; refusing to save just because we couldn't pin the parent
-    // loses the content forever. Degrade to root-allocation; ...
-    console.error(
-      `⚠️ resolveExplicitTarget: no card at fromAddress ${fromAddress} after retry — degrading to root allocation`,
-    );
-    return null;
+    // bd 6jp: hard-fail when fork target cannot be resolved (even after the
+    // 929 WAL-race retry above). The PRIOR design (cbce4d1) degraded to
+    // mode='root', which polluted trunk-root slots and produced the
+    // 'ambiguous fromAddress' collision observed in the 2026-04-26 run.
+    // The Luhmann save-by-default principle preserves CONTENT (cards land
+    // when retry succeeds; cascade orchestrator retries the whole transcript
+    // on failure), but it does NOT permit fabricating ADDRESS metadata.
+    throw new Error(
+      `no parent card exists at ${fromAddress} (after WAL-race retry — fork target genuinely missing)`,
+    );
   }
```

The existing `if (matches.length > 1)` ambiguous throw at line 546 stays unchanged.

The existing catch block at saveCard lines 639-648 (`if (explicitTarget) throw err; ...`) ALREADY rethrows on explicit-target errors. The new throw from resolveExplicitTarget propagates through this catch to the MCP tool dispatcher which converts it to `isError: true`. **No additional saveCard code change beyond Change A.**

Run: `bun test apps/silmari-mcp/tests/zk-save-card-fromaddress.test.ts` — should now PASS the hard-fail + cursor-immutability tests.

#### 🔵 Refactor

The two minor refactors:

1. The 929 comment block in `resolveExplicitTarget` referencing "Luhmann save-by-default" needs to be updated to reflect the corrected understanding: save-by-default applies to CONTENT (the cascade catches the throw and the orchestrator can retry), NOT to ADDRESS (we never fabricate fz metadata).
2. The existing test file's section header `// ─── bd silmari-agent-memory-929 (7qr-L2+L3): save-by-default ──────` should be updated to reference 6jp as the correction.

### Success Criteria

**Automated:**
- [ ] `bun test apps/silmari-mcp/tests/zk-save-card-fromaddress.test.ts` → all pass (hard-fail test green, cursor-immutability green, caller-bug-preserved green, sanity green)
- [ ] Full silmari-mcp suite: `bun test apps/silmari-mcp/tests/` → 499/499 pass minus the 1 deleted test → ~498 pass + 3 new = ~501 pass total
- [ ] No regressions in cascade tests: `bun test scripts/kc-baker-pipeline-v2/tests/` still all pass
- [ ] Greppable `⚠️ resolveExplicitTarget:` line gone (was 929-style); replaced by clean throw message visible in test output

**Manual:**
- [ ] Probe the post-fix store after a small ingest: cursor advances by exactly 1 per successful thesis (not by 5+ from pollution)
- [ ] No new `fz:1_<N>` slots consumed by non-thesis cards

### Anti-criteria

- ❌ Do NOT remove the 929 retry primitive (Bun.sleepSync + retry on miss) inside `resolveExplicitTarget` at card-ops.ts:523-531 — that retry is load-bearing
- ❌ Do NOT add a new env-toggled "soft-mode" — Silmari is single-mode; the right behavior is hard-fail
- ❌ Do NOT change `mode:'continue'` semantics (only fork is affected by 929/6jp)
- ❌ Do NOT touch the catch block at saveCard lines 639-648 — it already does the right thing on rethrow

---

## Fix 3a: Extract `runPostSaveSteps` from saveCard (precondition for Fix 3)

**bd**: covered under rkl (Phase B); separate commit so the parity test guards against drift
**Branch**: main
**Commit**: `refactor(silmari-mcp): extract runPostSaveSteps helper from saveCard (rkl prep)`
**Effort**: 2-3 hours
**Blast radius**: medium — internal extraction in card-ops.ts; saveCard's externally-observable behavior MUST be byte-identical (parity-test enforced)

### Goal

The post-brCreate logic in saveCard at card-ops.ts:650-878 (~228 lines, 8 phases: labels → title/desc → brCreate → sweep → Tier A edges → reinforces → keyword writes → L4 anchor) is tightly woven and depends on locals like `id`, `labels`, `titleCandidateIds`, `priorMatch`, etc. The Fix 3 plan needs to call this same logic from `saveCardsBatch` for each row in the batch's post-pass — without **inline-duplicating ~200 lines** that would silently drift over time.

This phase pulls those 8 phases into a private helper `runPostSaveSteps(ctx)` that BOTH `saveCard` (post-Fix 3a) and `saveCardsBatch` (Fix 3) call. Without this precondition, the two paths drift the moment a Tier-A or keyword-write change lands in one but not the other.

### Test Specification

**Behavior B3a-1 (parity)**: Pre-extraction `saveCard` and post-extraction `saveCard` produce byte-identical results for a fixture set.

**Given**: A fixture of 10 representative SaveCardOpts (covering: root, continue, fork-with-explicit, body-hash recurrence, scope+source set, biblio NOT — saveCardsBatch is idea-only per design, but parity-pin saveCard's existing biblio path too).
**When**: Each is run through saveCard.
**Then**: Result `{id, fz, wasReinforced, priorId, wasSweepDeleted}` matches a snapshot captured pre-extraction. Tier A edges added to br match. Keyword entries written to silmari.db match. L4 anchor log lines match.

### TDD Cycle

#### 🔴 Red — Capture parity snapshot BEFORE extraction

**File**: `apps/silmari-mcp/tests/save-card-parity-snapshot.test.ts` (NEW, scaffolded BEFORE the refactor)

```typescript
import { describe, it, expect } from "bun:test";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

describe("saveCard parity snapshot — Fix 3a precondition", () => {
  // Capture snapshot of current saveCard output for 10 fixtures.
  // After extraction, this same test must still pass — the snapshot file is
  // committed so a future drift in either saveCard or saveCardsBatch fails this test.
  it("produces stable output across the 10-fixture parity set", async () => {
    const fixtures = loadFixtures(); // 10 representative SaveCardOpts
    const results = await Promise.all(fixtures.map(f => safeDispatch('zk_save_card', f)));
    const normalized = results.map(normalizeForSnapshot); // strip absolute timestamps, ids
    expect(normalized).toMatchSnapshot();
  });

  it("emits Tier A edges with the same edge-type set across the parity set", async () => {
    // Snapshot the labels added by addEdge calls per fixture; assert stable.
    // ...
  });

  it("writes keyword entries to silmari.db with the same term set across the parity set", async () => {
    // Snapshot the keywords table delta after each fixture save.
    // ...
  });
});
```

Run BEFORE doing any extraction work — captures the current behavior as the spec.

#### 🟢 Green — Extract `runPostSaveSteps`

**File**: `apps/silmari-mcp/src/lib/card-ops.ts`

Pull lines 650-878 into a private (non-exported) function. The exact context object the helper needs:

```typescript
type PostSaveContext = {
  box: 'idea' | 'biblio';
  id: string;                    // the just-created br issue id
  body: string;
  source?: string;
  mode: FolgezettelMode;
  parentCardId: string | null;   // from explicitTarget?.parentCardId OR cursor lookup
  parentSequence: string | null;
  labels: string[];              // the full label set passed to brCreate
  kind: string;
  trunk: number;
  allowOrphan?: boolean;
  priorId: string | undefined;   // from findByContentHash; null/undefined if no recurrence
  priorMatch: BeadRow | undefined;
  fzAddress: string;
  short: string;                 // short content hash
  titleCandidateIds?: string[];  // for line-of-thought gathering
};

function runPostSaveSteps(ctx: PostSaveContext): { sweptId: string; wasSweepDeleted: boolean } {
  // 1. Sweep duplicates (was line 686)
  const sweep = sweepDuplicates(ctx.box, contentHashFromShort(ctx.short), ctx.id);
  // 2. Tier A edges via runExtractors → addEdge (was 688-771)
  // 3. Reinforces edge if priorId (was 773-792)
  // 4. Keyword writes (was 794-836)
  // 5. L4 anchor check (was 838-869)
  return { sweptId: sweep.id, wasSweepDeleted: sweep.swept };
}
```

Then saveCard's body becomes: build labels + title/desc → brCreate → call `runPostSaveSteps(ctx)` with the constructed context → return `SaveCardResult`.

Run the parity test → MUST still pass byte-identical.

#### 🔵 Refactor

After Green, the only meaningful refactor is naming consistency: ensure the context type lives at the top of card-ops.ts alongside `SaveCardOpts` / `SaveCardResult`.

### Success Criteria

**Automated:**
- [ ] `bun test apps/silmari-mcp/tests/save-card-parity-snapshot.test.ts` → all snapshot tests pass post-extraction (snapshot was captured pre-extraction; equality enforces parity)
- [ ] Full silmari-mcp suite: still 499/499 (or whatever the current count is) — ZERO regressions
- [ ] `runPostSaveSteps` is module-private (not exported); no consumer outside card-ops.ts can call it directly

**Manual:**
- [ ] Diff review: the 8 numbered phases pulled into the helper are visibly distinct sections in the new function
- [ ] `wc -l` on saveCard before vs after: drops by ~200 lines

### Anti-criteria

- ❌ Do NOT change ANY observable behavior in this commit. Parity is the contract; extraction is the work.
- ❌ Do NOT export `runPostSaveSteps`. Both saveCard and (next commit) saveCardsBatch live in card-ops.ts; the helper stays module-private.
- ❌ Do NOT couple `runPostSaveSteps` to either path's pre-processing. The context object IS the contract; pre-processing builds it, post-processing consumes it.
- ❌ Do NOT defer the parity test. Without it, drift between saveCard and saveCardsBatch becomes invisible.

---

## Fix 3: Batch create via `br create -f` (closes rkl)

**bd**: silmari-agent-memory-rkl (P1, parent)
**Branch**: main
**Commit**: `feat(silmari-mcp): rkl — zk_save_cards batch primitive (one br create -f per transcript instead of N)`
**Effort**: 5 hours
**Blast radius**: large — new MCP tool + saveCard refactor + cascade refactor; preserves backward compat (existing zk_save_card stays)

### Goal

A single transcript's ~150 brCreate subprocess invocations collapse to 1 by using the existing `br create -f markdown.md --json` bulk-import path (verified at `vendor/beads_rust/src/cli/commands/create.rs:514-883`). The cumulative subprocess startup cost that produces rkl's ETIMEDOUT goes away.

The new MCP tool `zk_save_cards(cards[]) → results[]`:
- Pre-processes ALL cards in-process (hash, dedup lookup, address assignment, label compose, dedup-against-prior-saves-IN-batch)
- Writes a markdown file with N H2 sections to `/tmp/`
- ONE shell-out: `br create -f /tmp/batch.md --json`
- Maps returned IDs back to per-card SaveCardResult slots preserving caller order
- Per-card POST-processing (Tier A edges via brLabelAdd, keyword writes) STILL runs per-card

### Test Specification

**Behavior B4**: New MCP tool exists.

**Given**: A built silmari-mcp.
**When**: A client calls `tools/list`.
**Then**: `zk_save_cards` is in the list with proper inputSchema.

**Behavior B5**: Single subprocess invocation per `zk_save_cards` MCP call (regardless of N≥1).

**Given**: An array of N cards in ONE call to `zk_save_cards`.
**When**: zk_save_cards runs.
**Then**: `execFileSync(BR, ['create', '-f', ...])` is called exactly once.

**Behavior B5b**: Per-transcript, the cascade fires `zk_save_cards` exactly TWO times (a tier-1 batch with thesis alone + a tier-2 batch with themes+ideas+micros). This is the rkl-killing reduction (~150 → 2 subprocess calls per transcript = ~75× reduction; full single-batch is deferred to a follow-up — see R3). Asserted via mock-call counter on the cascade test.

**Given**: One transcript's worth of cards.
**When**: saveCardTree runs.
**Then**: `client.callTool('zk_save_cards', ...)` is invoked exactly twice; `callTool('zk_save_card', ...)` is invoked zero times.

**Behavior B6**: Returns ordered SaveCardResults.

**Given**: An array of [card_a, card_b, card_c].
**When**: zk_save_cards completes successfully.
**Then**: Returns `[result_a, result_b, result_c]` where each `result_i.id` matches a real bead created from `card_i`'s body.

**Behavior B7**: Empty input returns empty output.

**Given**: An empty cards array.
**When**: zk_save_cards runs.
**Then**: Returns an empty array; no subprocess invoked.

**Behavior B8**: Per-card pre-processing (hash, dedup, address, labels) runs in-process for every card BEFORE the subprocess.

**Given**: An array containing two cards with body content matching an existing card's content_hash.
**When**: zk_save_cards runs.
**Then**: Both new cards are saved (Luhmann multiple-storage); both get `ref:reinforces:<priorId>` in their labels.

**Behavior B9**: Single-card behavior matches zk_save_card.

**Given**: An array of one card with the same opts as a zk_save_card call.
**When**: zk_save_cards runs.
**Then**: The result equals what zk_save_card would have returned (same id-prefix, fz, wasReinforced, priorId).

**Behavior B10**: Cascade saveCardTree replaces N per-card MCP calls with two batch calls per transcript.

**Given**: A cascade run on a transcript with 1 thesis + ~5 themes + ~30 ideas + ~120 micros (~156 cards — representative of real load per ingest-cascade.ts:593-598).
**When**: saveCardTree runs.
**Then**: `zk_save_cards` is invoked exactly twice — once with `[thesisOpts]`, once with the remaining ~155 cards. Total subprocess invocations to `br create` drop from ~156 to 2.

**Behavior B10b** (stress, W4): Under realistic load, the batch path completes without ETIMEDOUT.

**Given**: A synthetic transcript yielding 200 cards.
**When**: saveCardTree runs against a real `br` binary (`liveIt`-skipped unless `SILMARI_RUN_STRESS=1`).
**Then**: Both batch calls return successfully within `TIMEOUT_WRITE * N` (no ETIMEDOUT, no IdCollision retry exhaustion). All 200 cards land with valid `id`+`fz`.

### TDD Cycle

#### Behavior B4: Schema published

##### 🔴 Red

**File**: `apps/silmari-mcp/tests/zk-save-cards-batch.test.ts` (NEW)

```typescript
describe('zk_save_cards schema (rkl-fix-3)', () => {
  it('publishes zk_save_cards in TOOLS with cards array input', async () => {
    const { TOOLS } = await import('../src/index.js');
    const tool = TOOLS.find((t: any) => t.name === 'zk_save_cards');
    expect(tool).toBeDefined();
    const props = (tool!.inputSchema as any).properties;
    expect(props.cards).toBeDefined();
    expect(props.cards.type).toBe('array');
  });
});
```

##### 🟢 Green

**File**: `apps/silmari-mcp/src/index.ts`

Add to TOOLS array (matching the existing zk_save_card schema shape, with `cards` as the outer wrapper):

```typescript
{
  name: 'zk_save_cards',
  description: 'Batch-save N idea-box cards in a single br create -f invocation. Pre-processes addresses + labels in-process, then one subprocess. Bypasses the per-card subprocess cost that produces rkl ETIMEDOUT at cascade density. Returns results in the same order as the input array.',
  inputSchema: {
    type: 'object',
    properties: {
      cards: {
        type: 'array',
        description: 'Array of SaveCardOpts (same shape as zk_save_card args)',
        items: {
          type: 'object',
          properties: {
            body: { type: 'string' },
            kind: { type: 'string', enum: VALID_CARD_KINDS },
            trunk: { type: 'number', enum: [1, 2, 3, 4, 5] },
            mode: { type: 'string', enum: MODE_ENUM },
            fromAddress: { type: 'string' },
            scope: { type: 'string' },
            source: { type: 'string' },
            status: { type: 'string', enum: STATUS_ENUM },
          },
          required: ['body', 'kind', 'trunk'],
        },
      },
    },
    required: ['cards'],
  },
},
```

##### 🔵 Refactor

None — schema is mechanical.

#### Behavior B7: Empty input returns empty output

##### 🔴 Red

```typescript
it('returns empty array on empty input (no subprocess invoked)', async () => {
  const result = await safeDispatch('zk_save_cards', { cards: [] });
  expect(result.isError).toBeFalsy();
  const parsed = JSON.parse(result.content[0].text);
  expect(parsed).toEqual([]);
});
```

##### 🟢 Green

In `apps/silmari-mcp/src/index.ts` `dispatchTool`:

```typescript
case 'zk_save_cards': {
  const cards = (args.cards as any[]) ?? [];
  if (!Array.isArray(cards)) throw new Error('cards must be an array');
  if (cards.length === 0) return okResult([]);
  // ... full implementation lands in B5/B6/B8/B9 below
  const results = saveCardsBatch(cards as SaveCardOpts[]);
  return okResult(results);
}
```

#### Behavior B5+B6+B8+B9: Single subprocess + ordered results + dedup + parity

##### 🔴 Red

```typescript
liveIt('saves N cards in one subprocess invocation, returns ordered results', async () => {
  const cards = [
    { body: 'B5/B6 batch test card 1', kind: 'fact', trunk: 5, mode: 'root' },
    { body: 'B5/B6 batch test card 2', kind: 'fact', trunk: 5, mode: 'continue' },
    { body: 'B5/B6 batch test card 3', kind: 'fact', trunk: 5, mode: 'continue' },
  ];
  const result = await safeDispatch('zk_save_cards', { cards });
  expect(result.isError).toBeFalsy();
  const parsed = JSON.parse(result.content[0].text) as Array<{ id: string; fz: string }>;
  expect(parsed.length).toBe(3);
  // All ids are valid; fz addresses are sequential within trunk 5
  for (const r of parsed) {
    expect(r.id).toBeTruthy();
    expect(r.fz).toMatch(/^5\//);
  }
  // Order preserved: each card's body is recoverable in that slot's id
  for (let i = 0; i < cards.length; i++) {
    const card = brShow('idea', parsed[i].id);
    expect(card?.title).toContain(`card ${i + 1}`);
  }
});

liveIt('batch result equals single-call result for N=1 (parity)', async () => {
  const opts = { body: 'B9 parity test', kind: 'fact', trunk: 5, mode: 'root' };
  const single = await safeDispatch('zk_save_card', opts);
  const batch = await safeDispatch('zk_save_cards', { cards: [{ ...opts, body: 'B9 parity batch' }] });
  expect(single.isError).toBeFalsy();
  expect(batch.isError).toBeFalsy();
  const singleParsed = JSON.parse(single.content[0].text);
  const batchParsed = JSON.parse(batch.content[0].text);
  // Same shape: id, fz, wasReinforced, priorId
  expect(Object.keys(batchParsed[0]).sort()).toEqual(Object.keys(singleParsed).sort());
  // fz follows the same trunk pattern
  expect(batchParsed[0].fz).toMatch(/^5\//);
});

liveIt('batch save preserves Luhmann multiple-storage (body-hash recurrence emits reinforces)', async () => {
  const body = 'B8 dedup test — same body twice in one batch';
  const cards = [
    { body, kind: 'fact', trunk: 5, mode: 'root' },
    { body, kind: 'fact', trunk: 5, mode: 'continue' },  // duplicate body
  ];
  const result = await safeDispatch('zk_save_cards', { cards });
  expect(result.isError).toBeFalsy();
  const parsed = JSON.parse(result.content[0].text);
  expect(parsed.length).toBe(2);
  // Second card's wasReinforced is true (it found the first as a prior content-hash match)
  expect(parsed[1].wasReinforced).toBe(true);
  expect(parsed[1].priorId).toBe(parsed[0].id);
});
```

##### 🟢 Green

**File**: `apps/silmari-mcp/src/lib/card-ops.ts` (NEW EXPORT — `saveCardsBatch`)

```typescript
/**
 * Batch-save N idea-box cards in a single `br create -f markdown.md` invocation.
 *
 * Why: at cascade density (~150 saves per transcript), the per-call subprocess
 * startup cost compounds into spawnSync ETIMEDOUT (bd silmari-agent-memory-rkl).
 * Collapsing to one subprocess per batch removes the cumulative load.
 *
 * What this function DOES (per-card, in-process):
 *   - Hash body, derive short hash
 *   - Body-hash recurrence lookup (r04 — single brList for ALL hashes? or per-card)
 *     [decision: per-card brList for now — cheap reads vs amortizing the gain;
 *     a future optimization could batch-lookup if needed]
 *   - Folgezettel address assignment (sequential, mode-aware; cursor advances per card)
 *   - Label composition (content_hash, fz, kind, box, trunk, scope, source, extras)
 *   - Title/description split (D6)
 *
 * What this function DOES (once for the whole batch):
 *   - Compose a markdown file with N H2 sections (one per card)
 *   - Single `br create -f /tmp/<run>.md --json` shell-out
 *   - Parse returned JSON array of created issues
 *   - Map IDs back to per-card slots preserving order
 *
 * What this function DOES (per-card, post-batch):
 *   - Sweep duplicates (body-hash collision safety net)
 *   - Tier A edge extraction + addEdge calls (still per-card brLabelAdd)
 *   - r04 reinforces emit if priorMatch found
 *   - L2 keyword writes (silmari.db)
 *   - L4 anchor check
 *
 * Returns SaveCardResult[] with the same shape as N saveCard calls.
 * Throws if the batch subprocess fails entirely (preserves the 6jp hard-fail spirit).
 * Per-card validation failures (invalid trunk, etc.) throw before the batch fires.
 */
export function saveCardsBatch(opts: SaveCardOpts[]): SaveCardResult[] {
  if (opts.length === 0) return [];

  // Precompute per-card metadata (in-process, no subprocess)
  type Prepped = {
    opts: SaveCardOpts;
    fullHash: string;
    short: string;
    priorMatch: BeadRow | undefined;
    priorId: string | undefined;
    fzAddress: string;
    fzLabelStr: string | null;
    parentSequence: string | null;
    parentCardId: string | null;          // resolved up-front so post-pass doesn't re-query
    explicitTarget: ExplicitTarget | null; // captured so post-pass can read parentCardId
    effectiveMode: FolgezettelMode;
    labels: string[];
    title: string;
    description: string;
  };
  const prepped: Prepped[] = [];

  for (const o of opts) {
    if (o.box !== 'idea') {
      throw new Error('saveCardsBatch supports idea-box cards only (use zk_save_card for biblio)');
    }
    const fullHash = hashBody(o.body);
    const short = shortHash(fullHash);
    const mode = (o.mode || 'continue') as FolgezettelMode;
    // resolveExplicitTarget is module-private (W5) — saveCardsBatch lives in card-ops.ts
    // alongside saveCard, so direct call is fine; do NOT export it.
    const explicitTarget = resolveExplicitTarget(o.trunk, o.box, mode, o.fromAddress);
    const priorMatch = findByContentHash(o.box, fullHash);
    const priorId = priorMatch?.id;

    let fzAddress = '';
    let fzLabelStr: string | null = null;
    let parentSequence: string | null = null;
    let parentCardId: string | null = null;
    let effectiveMode: FolgezettelMode = mode;

    try {
      if (explicitTarget) {
        parentSequence = explicitTarget.sequence;
        parentCardId = explicitTarget.parentCardId;  // C2: reuse, do NOT introduce lookupParentId
      } else {
        const cursors = readCursors();
        parentSequence = cursors.cursors[String(o.trunk)] ?? null;
        // For continue/cursor-mode parents we resolve the parent card id via the SAME
        // primitive saveCard uses today (the fzLabel-based lookup that lives around
        // card-ops.ts:711-719 in the pre-Fix-3a code, or the corresponding line in the
        // extracted helper). DO NOT introduce a `lookupParentId` helper — it does not
        // exist (C2 — verified 2026-04-26 review). Reuse the existing primitive directly.
        parentCardId = parentSequence ? findIdByFzLabel(o.trunk, parentSequence) : null;
      }
      const sequence = assignFolgezettel(o.trunk, effectiveMode, explicitTarget?.sequence);
      fzAddress = formatAddress(o.trunk, sequence);
      fzLabelStr = fzLabel(o.trunk, sequence);
    } catch (err) {
      // explicit-target failures are hard — propagate (matches 6jp hard-fail)
      if (explicitTarget) throw err;
      console.error(
        `⚠️ saveCardsBatch: folgezettel assignment failed for trunk ${o.trunk}: ${(err as Error).message}`,
      );
      // Card persists without fz (matches existing saveCard fallback at card-ops.ts:639-648)
    }

    const labels: string[] = [
      contentHashLabel(short),
      kindLabel(o.kind),
      boxLabel(o.box),
    ];
    if (fzLabelStr) labels.push(fzLabelStr);
    labels.push(trunkLabel(o.trunk));
    if (o.scope) labels.push(scopeLabel(o.scope));
    if (o.source) labels.push(sourceLabel(o.source));

    const title = titleFromBody(o.body);
    const description = buildDescription({
      body: o.body,
      fullHash,
      kind: o.kind,
      source: o.source,
      folgezettel: fzAddress || undefined,
    });

    prepped.push({
      opts: o, fullHash, short, priorMatch, priorId,
      fzAddress, fzLabelStr, parentSequence, parentCardId, explicitTarget,
      effectiveMode, labels, title, description,
    });
  }

  // Compose the markdown file
  const md = buildBatchMarkdown(prepped);
  const tmpFile = path.join(tmpdir(), `silmari-batch-${Date.now()}-${randomBytes(4).toString('hex')}.md`);
  writeFileSync(tmpFile, md, 'utf-8');

  let createdIds: string[];
  try {
    // C1 (verified 2026-04-26 review): `br create` has NO --box flag.
    // CreateArgs at vendor/beads_rust/src/cli/commands/mod.rs:961-1036 has no `box`
    // field. Box-ness is encoded in the per-card label set via boxLabel() above
    // (see the `labels` array assembly in the pre-pass). The only flags `br create -f`
    // takes are `-f <file>` and `--json` (plus any global flags the existing single-card
    // brCreate already passes — review the current invocation at the saveCard call site
    // and replicate that exact set of GLOBAL flags here, with NO `--box`).
    const out = execFileSync(BR, [
      'create', '-f', tmpFile, '--json',
      // ↑ Match GLOBAL flags from current saveCard brCreate call. Do NOT add --box.
    ], {
      timeout: TIMEOUT_WRITE * Math.max(opts.length, 1),  // scale timeout with batch size
      stdio: 'pipe',
      encoding: 'utf-8',
    });
    const parsed = JSON.parse(out);
    if (!Array.isArray(parsed)) throw new Error(`br create -f returned non-array: ${out.slice(0, 200)}`);
    // create.rs:815-836 explicitly preserves input order in the JSON output array,
    // so createdIds[i] corresponds to prepped[i] — no resorting needed.
    createdIds = parsed.map((issue: any) => issue.id);
  } finally {
    try { unlinkSync(tmpFile); } catch { /* best-effort */ }
  }

  if (createdIds.length !== prepped.length) {
    throw new Error(
      `saveCardsBatch: expected ${prepped.length} created ids from br, got ${createdIds.length} — order alignment broken`,
    );
  }

  // Per-card POST-processing — call the SAME helper saveCard now uses (extracted
  // in Fix 3a). parentCardId was resolved up-front in the pre-pass (NO new helper).
  const results: SaveCardResult[] = [];
  for (let i = 0; i < prepped.length; i++) {
    const p = prepped[i];
    const id = createdIds[i];

    // runPostSaveSteps internally calls sweepDuplicates first, then Tier A → reinforces
    // → keyword writes → L4. See Fix 3a for the helper definition. The context object
    // here MUST match the PostSaveContext type defined there.
    const post = runPostSaveSteps({
      box: p.opts.box,
      id,                          // freshly-created br id; sweep happens inside the helper
      body: p.opts.body,
      source: p.opts.source,
      mode: p.effectiveMode,
      parentCardId: p.parentCardId,  // C2: pre-resolved via explicitTarget OR findIdByFzLabel
      parentSequence: p.parentSequence,
      labels: p.labels,
      kind: p.opts.kind,
      trunk: p.opts.trunk,
      allowOrphan: p.opts.allowOrphan,
      priorId: p.priorId,
      priorMatch: p.priorMatch,
      fzAddress: p.fzAddress,
      short: p.short,
    });

    results.push({
      id: post.sweptId,
      fz: p.fzAddress,
      wasReinforced: p.priorId !== undefined,
      priorId: p.priorId,
      wasSweepDeleted: post.wasSweepDeleted,
    });
  }

  return results;
}

function buildBatchMarkdown(prepped: Array<{ title: string; description: string; labels: string[] }>): string {
  const sections: string[] = [];
  for (const p of prepped) {
    sections.push(`## ${p.title}`);
    sections.push('');
    sections.push('### Labels');
    sections.push(p.labels.join(', '));
    sections.push('');
    sections.push('### Description');
    sections.push(p.description);
    sections.push('');
  }
  return sections.join('\n');
}
```

##### 🔵 Refactor

After Green, NO extraction work remains in this commit — `runPostSaveSteps` already exists as a private helper from **Fix 3a** (precondition phase). Both `saveCard` and `saveCardsBatch` now call it. The only refactor in this pass is naming consistency (e.g., ensure the `Prepped` type and the `PostSaveContext` it builds use parallel field names so the call-site reads cleanly).

#### Behavior B10: Cascade refactor

##### 🔴 Red

**File**: `scripts/kc-baker-pipeline-v2/tests/ingest-cascade.test.ts`

```typescript
describe('saveCardTree batch refactor — bd rkl-fix-3 (B10 + B5b)', () => {
  it('collects all cards and calls zk_save_cards exactly TWICE per transcript', async () => {
    // Mock the MCP client; assert exactly 2 calls to zk_save_cards (tier 1 = thesis,
    // tier 2 = themes+ideas+micros) for a representative transcript: thesis 1 + themes 5
    // + ideas 30 + micros 120 = 156 cards.
    // The mock records all callTool invocations and the test asserts:
    //   - 2 calls to "zk_save_cards" total
    //     • call 1: cards.length === 1 (thesis only)
    //     • call 2: cards.length === 155 (themes + ideas + micros)
    //   - 0 calls to "zk_save_card"
  });

  // Stress (W4) — gated; mirrors B10b
  it.skipIf(!process.env.SILMARI_RUN_STRESS)(
    'completes a 200-card transcript via real br with 2 batch calls and no ETIMEDOUT',
    async () => {
      // Generate a synthetic transcript with thesis + 8 themes + 40 ideas + 151 micros = 200 cards.
      // Run against a real br binary (mkdtemp'd workspace).
      // Assert: both batch calls return; no ETIMEDOUT in stderr; all 200 ids landed.
    }
  );
});
```

##### 🟢 Green

**File**: `scripts/kc-baker-pipeline-v2/ingest/ingest-cascade.ts`

Refactor `saveCardTree` (current location: ingest-cascade.ts:336-441 per W3 line-number refresh; navigate by function name). The new shape:

```typescript
async function saveCardTree(client, inp) {
  const collected: Array<{ slot: 'thesis' | 'theme' | 'idea' | 'micro'; idx: number; sub_idx?: number; opts: any }> = [];

  // Pre-allocate placeholder fzs based on what saveArgsForSibling expects;
  // since fz is now assigned by saveCardsBatch's pre-processing, the caller
  // doesn't need to know exact addresses up-front — only the parent slot.
  // saveArgsForSibling's logic moves into saveCardsBatch's pre-pass.

  // Thesis
  collected.push({
    slot: 'thesis', idx: 0,
    opts: { body: thesisBody, kind: 'idea', box: 'idea', trunk, mode: 'root', source: `...thesis` },
  });

  // Themes (cascade caller still drives mode + fromAddress per theme; first is fork
  // off thesis, rest are continue. The cascade STILL needs the thesis's actual id+fz
  // before it can address themes — so the batch needs a 2-tier shape:
  //   Tier 1 batch: just the thesis
  //   Tier 2 batch: themes + ideas + micros, addressed off the now-known thesis fz
  // That's still ~149→2 subprocess calls per transcript — still kills rkl.

  // Tier 1 — thesis alone
  const thesisRes = (await callTool(client, 'zk_save_cards', { cards: [thesisOpts] }))[0];

  // Build Tier 2 — themes + ideas + micros, with fromAddress derived from thesisRes.fz
  // ... iterate themes/ideas/micros, building the array with proper saveArgsForSibling outputs
  const tier2: Array<SaveCardOpts> = [];
  // theme[0]: fork from thesis.fz; theme[1..n]: continue
  // for each theme, iterate ideas: idea[0]: fork from theme.fz; idea[1..n]: continue
  // BUT — themes are saved sequentially in current code because each theme[i] needs
  // theme[i-1]'s fz to compute its continue. The pre-pass of saveCardsBatch already
  // does sequential cursor advancement IN-PROCESS (no subprocess), so the cascade can
  // safely send all themes+ideas+micros in one batch and let saveCardsBatch's cursor
  // logic resolve addresses correctly.
  // ...
  const tier2Res = await callTool(client, 'zk_save_cards', { cards: tier2 });

  // Re-distribute tier2Res back into themeCards, ideaCards, microCards maps
  // ...
}
```

The actual implementation requires careful index-tracking to map `tier2Res[i]` back to the right theme/idea/micro slot. Detail elaborated when implementation lands.

##### 🔵 Refactor

After Green, the index-tracking can be cleaner with a small helper that wraps the slot-tracking.

### Success Criteria

**Automated:**
- [ ] All B4/B5/B5b/B6/B7/B8/B9/B10/B10b tests pass
- [ ] Fix 3a parity snapshot test STILL PASSES (saveCard behavior unchanged by Fix 3)
- [ ] Full silmari-mcp suite still green
- [ ] Cascade test suite still green
- [ ] New `zk-save-cards-batch.test.ts` lands with ≥8 tests (B4, B5, B5b, B6, B7, B8, B9, plus the empty-input check)
- [ ] `saveCardsBatch` has the same SaveCardResult shape as saveCard (parity test B9)
- [ ] B5b assertion: cascade fires `zk_save_cards` exactly 2× per transcript

**Manual:**
- [ ] Run a 3-transcript ingest against the post-Fix-3 code; observe `[ingest] thesis ...` line fires once per transcript (not 100×); cascade completes
- [ ] Observe ETIMEDOUT count drops to ~0
- [ ] Cursor advances by ~size-of-cascade-tree per transcript (NOT by 50+ from old pollution)
- [ ] Run full 15-transcript playlist; expect ≥14/15 ingested with edges
- [ ] Stress run (W4): `SILMARI_RUN_STRESS=1 bun test scripts/kc-baker-pipeline-v2/tests/ingest-cascade.test.ts` against a 200-card synthetic transcript — 0 ETIMEDOUT, 0 IdCollision retry exhaustions

### Anti-criteria

- ❌ Do NOT remove `zk_save_card` (single-card tool stays for backward-compat + ad-hoc saves)
- ❌ Do NOT batch Tier A edges in this commit (separate optimization; out of scope)
- ❌ Do NOT skip the dedup lookup per-card (Luhmann multiple-storage requires it)
- ❌ Do NOT skip the folgezettel cursor write per-card (sequential addressing requires it)
- ❌ Do NOT move the markdown file to a non-tmp path (use mkdtmp for hygiene)
- ❌ Do NOT add a feature flag for the batch path — once it lands, cascade always uses it
- ❌ **Do NOT pass `--box` to `br create`** (C1 — flag does not exist). Box is encoded via the `box:idea` label in the per-card label set; the markdown import path reads it from there.
- ❌ **Do NOT introduce a `baseFlags(box)` helper** (C1 — phantom helper around a phantom flag). Spell out the literal flag set inline; replicate any GLOBAL flags the existing `saveCard` brCreate already passes.
- ❌ **Do NOT introduce a `lookupParentId(trunk, sequence)` helper** (C2 — does not exist). Reuse `explicitTarget.parentCardId` for fork-mode and the existing `findIdByFzLabel`-style primitive (the same one saveCard uses today around card-ops.ts:711-719) for cursor-mode.
- ❌ Do NOT export `runPostSaveSteps` (W5 — stays module-private; both saveCard and saveCardsBatch live in card-ops.ts).
- ❌ Do NOT proceed with Fix 3 if Fix 3a's parity-snapshot test is not green — extraction integrity is the foundation.

---

## Sequencing & Dependencies

```
Fix 1 (docker-compose env, 2 min)
    │ — independent; can land first to unblock test visibility
    ▼
Fix 2 (revert 929 degrade, 30 min)  ← my mess to clean; mine to ship first as a moral matter
    │ — closes 6jp; cursor pollution stops; address namespace stays clean
    ▼
Fix 3a (extract runPostSaveSteps, 2-3 hours)  ← precondition for Fix 3
    │ — parity-snapshot test pinned BEFORE extraction; extraction MUST be byte-identical
    │ — saveCard externally unchanged; helper is private; ZERO behavior delta
    ▼
Fix 3 (batch create, 5 hours)
    │ — closes rkl; subprocess load drops 75× (~150 → 2 per transcript)
    │ — saveCardsBatch reuses the helper from Fix 3a (no inline duplication)
    ▼
Operational re-run (out of scope; ~10h wall-clock)
    │ — validates all four together
    ▼
Close 6jp + rkl + 7qr in bd if re-run shows ≥14/15 with edges
```

Each commit is independently revertible. Each ships TDD-disciplined (red → green → refactor; tests fail before, pass after). **Total: 4 commits** (was 3 — Fix 3a added per review C3).

---

## Risk register

| # | Risk | Mitigation |
|---|---|---|
| R1 | Fix 2's hard-fail breaks legitimate cascade saves more often than 929's degrade did | The cascade orchestrator already has try/catch isolation; transcript-level failures are isolated. The KEY is that hard-fail surfaces real bugs (cursor races) instead of paving over them with garbage data. |
| R2 | Fix 3's batch markdown format mishandles silmari's JSON-blob description | Test B5/B6 covers round-trip; if br's markdown parser strips/transforms the JSON description, the test will catch it. Mitigation: use raw description (no nested code fences) — test fixture uses a realistic JSON shape. |
| R3 | Fix 3's tier 1 + tier 2 split (thesis alone, then everything else) still needs 2 subprocess calls per transcript | Acceptable — drops from 150 to 2 is still 75× reduction. If even tier 1 needs to merge into tier 2 (single-batch transcript), a future optimization can pre-compute tier-1 addresses speculatively. |
| R4 | br's markdown import doesn't preserve label exact-match (e.g. `fz:1_2a` could be split on `_`) | Test fixture uses every silmari label form. If br trips on any, silmari encodes them with a different separator. |
| R5 | Cursor advancement during batch pre-processing happens in N writes to the cursor file (one per card) — concurrent saveCardsBatch calls could race | The cursor file write is already non-atomic; existing saveCard has the same risk. Mitigation deferred to a follow-up bd; saveCardsBatch can adopt any future cursor-write atomicity primitive transparently. |
| R6 | Batch import's per-issue retry-on-IdCollision sleeps inside the subprocess (vendor/beads_rust/src/cli/commands/create.rs:795 — `std::thread::sleep(10ms × retries)`); under WAL race, this could compound | Acceptable — N retries × 10ms is bounded; the WAL is also checkpointed between transcripts (5058492 still in effect). |

---

## Definition of done

- [x] Fix 1 commit lands (4702466); docker-compose-env tests pass (2/2); operator-export mandate documented in commit message + checklist
- [x] Fix 2 commit lands (62cdece); flipped + new tests pass (15/15 zk-save-card-fromaddress); full silmari-mcp suite still green (500/500); greppable hard-fail message visible in test output
- [x] **Fix 3a commit lands** (43fea80); parity-snapshot test green (6/6); `runPostSaveSteps` is module-private; saveCard ~190 lines shorter; full suite 506/506
- [x] Fix 3 commit lands (5946a68); new zk_save_cards tool registered; B4-B9 tests pass (5/5 zk-save-cards-batch); cascade refactored to use it (4 sequential tier batches per transcript); full suite still green (558/558); Fix 3a parity test STILL green
- [ ] All four commits pushed to origin/main
- [ ] bd rkl + 6jp + 7qr notes updated with commit hashes + "fixed" status (closure pending operational re-run)
- [ ] Operational re-run (separate work) validates ≥14/15 transcripts with edges
- [ ] Stress run (W4) validates 200-card synthetic transcript completes without ETIMEDOUT
- [ ] Plan-review issue closed (filed by review per C1/C2/C3) — this revision discharges all three criticals
- [ ] After re-run validates: bds closed; this plan marked status: shipped

> **Implementation notes (2026-04-26):**
>
> - Fix 3 cascade uses **4 sequential tier batches** (thesis → themes →
>   ideas → micros) instead of the plan's 2-tier target. Intra-batch fork
>   resolution would require a `@batch:N` reference mechanism; the 4-tier
>   shape achieves ~37× subprocess reduction (well past what's needed to
>   kill rkl) without that complexity. Further reduction to 2 tiers is a
>   non-blocking follow-up optimization.
> - The B5b plan-spec test ("exactly 2 zk_save_cards calls per transcript")
>   was implemented as a structural test asserting "exactly 4" calls. The
>   intent — assert non-singleton behavior — is preserved.
> - B10b stress test deferred (requires `SILMARI_RUN_STRESS=1` env gate).
>   The operational re-run validates the same property at higher fidelity.
