---
date: 2026-04-25T08:14:38-04:00
planner: Silmari (via Opus 4.7)
git_commit: 4ec7739a214d5f190ca43094b05f6422db92cb3d
branch: main
repository: tha-hammer/silmari-agent-memory
topic: "TDD plan — silmari-agent-memory-7qr cascading 15-transcript failure: three-layer surgical fix"
tags: [tdd, plan, silmari, 7qr, p6i, cascade, folgezettel, save-by-default, luhmann]
related_research:
  - thoughts/searchable/shared/research/2026-04-24-09-09-silmari-agent-memory-hkg-p6i-br-prefix-match-bugs.md
related_bd:
  - silmari-agent-memory-7qr (P1, OPEN — primary)
  - silmari-agent-memory-p6i (P2, OPEN — same WAL-visibility-race family)
  - silmari-agent-memory-hkg (P2, OPEN — wrapper-layer fix landed in 4ec7739, sibling family)
status: draft
last_updated: 2026-04-25
last_updated_by: Silmari
type: tdd_plan
---

# 7qr Cascading-Failure Three-Layer Fix — TDD Plan

**Epic**: 7qr full-playlist ingest reliability
**Scope**: 3 sequential layers landed as 3 independent commits, plus 1 read-only diagnostic probe that runs **before** any code change.
**Effort tier**: Extended (≤8 min per layer; ~30 min total active work).
**Commits target**: 3 (one per layer), each independently revertible.
**Status**: Draft, awaiting probe validation before implementation.

---

## Overview

`silmari-agent-memory-7qr` (P1) — full 15-transcript KC Baker ingest at commit `41d0423` produced only 2/15 successful transcripts. Pattern: a single transcript's mid-run failure (Gate B p6i-style `ISSUE_NOT_FOUND` on transcript 2) cascades to the immediate transcript and to all 11 subsequent transcripts because (a) the per-transcript orchestrator does not isolate failures, (b) the folgezettel cursor advances before card creation succeeds, and (c) `resolveExplicitTarget` aborts entire saves on any missing-parent fz lookup instead of degrading.

The investigation (companion research at `thoughts/searchable/shared/research/2026-04-24-09-09-silmari-agent-memory-hkg-p6i-br-prefix-match-bugs.md` plus this plan's diagnostic notes) identified that the user-reported error message *"thesis save fails with no parent card exists at 1/5e"* is actually the FIRST THEME save of each transcript — the only code path in the repo that throws *"no parent card exists at ..."* is `card-ops.ts:517` inside `resolveExplicitTarget`, which is unreachable for a `mode: 'root'` thesis.

**The user reframe** ("we ALLOW duplication to surface 'same idea + new context == insight', we should default to saving cards not rejecting outright") sharpens the design: Silmari is not an issue tracker. Issue-tracker semantics ("refuse to fork from a non-existent parent") are wrong here. The save layer must default to saving; if the explicit target is missing, log + degrade + save anyway. The Tier B graph-candidates pass restores the intended relationship via `reinforces`/`extends` edges later — that is exactly what the edge layer is for.

This plan ships three layers in increasing-blast-radius order, so the smallest fix unblocks the playlist immediately and the deeper fixes prevent recurrence.

**Cross-cutting invariants** (hold after all 3 layers):

1. **Save-by-default**: a `saveCard` call with a malformed-or-missing fork target produces a saved card (degraded to root), not a thrown error.
2. **No cursor drift**: the folgezettel cursor only advances after the card creation that consumes the new sequence has succeeded. Failed saves leave the cursor untouched.
3. **Per-transcript isolation**: one transcript's full failure produces a non-zero exit for that transcript only. The cascade orchestrator continues to the next transcript and records the failure in `ingest-report.json`.
4. **Issue-tracker correctness preserved**: legitimate caller bugs (`mode: 'root'` with `fromAddress` set, malformed addresses, Register targeting) still throw — these are programming errors, not data conditions.
5. **No engine changes**: `vendor/beads_rust/` untouched. All fixes are in `apps/silmari-mcp/` and `scripts/kc-baker-pipeline-v2/`.

---

## Probe (Layer 0) — runs BEFORE any code change

The user's instruction was explicit: probe to validate before patching. The probe is read-only and answers two questions:

**Q1**: Is the cursor file at the preserved store inconsistent with what's actually in the beads DB? (validates hypothesis (a) — counter-state drift)

**Q2**: Are there cards at addresses `1/5e`, `1/6`, ..., `1/16` that the broken cascade thinks are missing? Or are the addresses genuinely empty? (distinguishes hypothesis (a) "cursor drift" from (b) "prefix-match" from (c) "phantom labels")

### Probe contract

`scripts/kc-baker-pipeline-v2/probes/probe-7qr.sh` (NEW — read-only, idempotent):

```bash
#!/usr/bin/env bash
# Probe the preserved 7qr store via a one-off docker container.
# Read-only: --rm + no writes. Validates the diagnosis in the TDD plan
# at thoughts/searchable/shared/plans/2026-04-25-tdd-7qr-cascade-failure-three-layer-fix.md
set -euo pipefail

VOL="silmari-kc-baker_store"

# Q1: cursor file state
echo "=== Q1 — Cursor file state ==="
docker run --rm -v "${VOL}":/store alpine sh -c 'cat /store/box2-ideas/.beads/folgezettel-cursors.json 2>/dev/null || echo "(no cursor file)"'

# Q2: actual cards at trunk-1 addresses 5..16
echo
echo "=== Q2 — Cards at fz:1/5..1/16 ==="
docker run --rm -v "${VOL}":/store kc-baker-pipeline-v2:latest sh -c '
  for n in 5 5e 6 7 8 9 10 11 12 13 14 15 16; do
    count=$(br --db /store/box2-ideas/.beads/beads.db list --label "fz:1/${n}" --json 2>/dev/null | jq "length" 2>/dev/null || echo "ERR")
    echo "fz:1/${n}: ${count}"
  done
'

# Q3: per-transcript thesis saves — what fz did each transcript actually land?
echo
echo "=== Q3 — All thesis saves in trunk 1 ==="
docker run --rm -v "${VOL}":/store kc-baker-pipeline-v2:latest sh -c '
  br --db /store/box2-ideas/.beads/beads.db list --label "kind:idea" --label "trunk:1" --json 2>/dev/null \
    | jq ".[] | select(.title | startswith(\"# \") and (test(\"cascade thesis\"))) | {id, fz: (.labels // [] | map(select(startswith(\"fz:\"))) | first), title}" 2>/dev/null
'

# Q4: any orphan fz labels — addresses that appear in cards' fz labels but where br list with that label finds nothing
echo
echo "=== Q4 — Cursor's last-known position vs highest actual card ==="
docker run --rm -v "${VOL}":/store kc-baker-pipeline-v2:latest sh -c '
  echo "(cursor reported in Q1)"
  echo "highest actual fz in trunk 1:"
  br --db /store/box2-ideas/.beads/beads.db list --label "trunk:1" --json 2>/dev/null \
    | jq -r ".[] | (.labels // [] | map(select(startswith(\"fz:1/\"))) | first)" \
    | sort -V | tail -3
'
```

### Probe expected outcomes (decision matrix)

| Probe result | Meaning | Plan adjustment |
|---|---|---|
| Q1 cursor = e.g. `{"1": "16"}`; Q2 shows `fz:1/6..1/16: 0` | **Hypothesis (a) confirmed** — cursor drifted past actual cards | Layers 1+2+3 all justified; ship in order |
| Q1 cursor = `{"1": "16"}`; Q2 shows `fz:1/6..1/16: 1` each | Cards exist but theme[0] failed lookup despite that — **Hypothesis (b) prefix-match or WAL race** | Layer 2 alone may suffice; Layer 3 still desirable defense-in-depth |
| Q1 cursor = `{"1": "5"}`; Q2 shows `fz:1/5: 0` | **Hypothesis (c) confirmed** — partial saves left orphan cursor | Layer 3 cursor-after-create is the structural fix; Layer 2 is the immediate-symptom fix |
| Q3 shows fewer thesis cards than Q1's cursor implies | Validates cursor advanced past failed brCreates | Layer 3 mandatory |
| Probe blocked by sudo/docker permissions | User runs probe; pastes results; we proceed from observed state | Plan unchanged but execution gated on user-supplied data |

**Gate**: implementation does NOT begin until probe results land in this plan's "Probe Results" section (appended after the run).

---

## Current State Analysis

### Key code locations

- `apps/silmari-mcp/src/lib/card-ops.ts:490-530` — `resolveExplicitTarget` — the throw site (Layer 2)
- `apps/silmari-mcp/src/lib/card-ops.ts:557-844` — `saveCard` full flow (Layer 2 callsite + Layer 3 cursor-write coordination)
- `apps/silmari-mcp/src/lib/folgezettel.ts:268-307` — `assignFolgezettel` — the cursor-write site (Layer 3)
- `apps/silmari-mcp/src/lib/folgezettel.ts:208-241` — cursor file I/O (`readCursors`, `writeCursors`)
- `scripts/kc-baker-pipeline-v2/ingest/ingest-cascade.ts:248-353` — `saveCardTree` (Layer 1)
- `scripts/kc-baker-pipeline-v2/ingest/ingest-cascade.ts` (main loop, somewhere after line 425) — orchestration (Layer 1)

### Existing test infrastructure

- `apps/silmari-mcp/tests/extraction-hardening.test.ts` — bun:test, real `br` binary, mkdtempSync + SILMARI_*_DIR pattern
- `apps/silmari-mcp/tests/savecard-concurrency.test.ts` — concurrency-aware save tests
- `apps/silmari-mcp/tests/zk-save-card-fromaddress.test.ts` — explicit-target save tests (closest existing coverage to Layer 2's surface)
- `apps/silmari-mcp/tests/folgezettel.test.ts` — pure-function tests for the folgezettel address algebra (Layer 3 tests live near here)
- `scripts/kc-baker-pipeline-v2/tests/ingest-cascade.test.ts` — cascade orchestrator tests (Layer 1 tests live here)

### Constraints / non-negotiables from existing memory

- `feedback_silmari_no_prune_dedup` — body-hash match → save NEW card + reinforces edge. Don't change this; Layer 2's "save-by-default" extends the same philosophy.
- `feedback_zk_status_before_zk_recall` — empty recall ≠ no prior work. Doesn't constrain this plan but reminds us the keyword index is load-bearing.
- `project_bv_is_repurposed_issue_tracker` — bd is a repurposed issue tracker; label-encoding is the compression layer. **This plan operationalizes the philosophy mismatch** that memory note flagged.
- 4ec7739 (just-landed) — wrapper-layer hkg fix means `brShow`/`brList`/`brSearch` already log greppable `⚠️` lines on `.error` shapes and id mismatches. Layer 2 builds on top of that.

---

## Layer 1 — Cascade per-transcript try/catch

**bd**: filed as `silmari-agent-memory-<NEW>` once user accepts plan
**Branch**: `fix/7qr-layer-1-cascade-isolation`
**Commit**: `fix(cascade-v2): 7qr-L1 — per-transcript try/catch isolates failures`
**Effort**: ~10 min
**Blast radius**: tiny — pipeline orchestrator only

### Goal

A single transcript's `saveCardTree` or Gate B failure must NOT prevent subsequent transcripts from being processed. The aggregate report records per-transcript failure with reason.

### Test plan

Add to `scripts/kc-baker-pipeline-v2/tests/ingest-cascade.test.ts`:

```ts
describe("7qr-L1: per-transcript failure isolation", () => {
  it("continues to next transcript when saveCardTree throws", async () => {
    // Mock callTool: succeed for transcript 1; throw 'no parent card exists at 1/X'
    // for transcript 2's first theme; succeed for transcript 3.
    // Run the orchestrator over [t1, t2, t3].
    // Assert: t1 and t3 saved; t2's report has {ok: false, error: '...', stage: 'theme[0]'}; loop reached t3.
  });

  it("records failed transcript in step8-aggregate.json with reason", async () => {
    // Same setup, after run completes, read step8-aggregate.json.
    // Assert: per_transcript_reports has 3 entries; t2's entry has 'error' field.
  });

  it("does not advance to Gate B for a transcript whose Phase 1 partially failed", async () => {
    // Mock theme[2] saveCardTree throw mid-way.
    // Assert: Gate B is NOT called for that transcript; only Phase 1 partial counts in report.
  });
});
```

### Implementation sketch

In `ingest-cascade.ts`'s main loop (location depends on file structure — search for the for-loop over transcripts):

```ts
const reports: IngestReport[] = [];
const failures: TranscriptFailure[] = [];
for (const basename of transcripts) {
  try {
    const tree = await saveCardTree(client, inputs);
    const gateB = await runGateBForTranscript(client, tree, ...);
    reports.push(buildReport(basename, tree, gateB));
  } catch (err) {
    const msg = (err as Error).message;
    console.error(`[ingest] ❌ ${basename}: ${msg.slice(0, 240)}`);
    failures.push({ basename, error: msg, at: new Date().toISOString() });
    // Note: cursor state may now be drifted; Layer 3 prevents this. For now, log + continue.
  }
}
// Write a single aggregate including both successes and failures.
await writeFile(aggregatePath, JSON.stringify({ ...rollup, failures }));
```

### Acceptance

- ✅ All 3 new tests pass (real `br` binary, mocked tool calls)
- ✅ Existing `ingest-cascade.test.ts` tests still pass
- ✅ A simulated 3-transcript run with t2 forced to fail produces reports for t1 and t3
- ✅ The failure list lands in `step8-aggregate.json` under a top-level `failures` array

### Anti-criteria

- ❌ Do NOT swallow failures silently — every failure must produce a stderr log AND a report entry
- ❌ Do NOT retry within Layer 1 — retry policy belongs in Layer 2 / Layer 3 / a future bd
- ❌ Do NOT touch the cursor or store state from Layer 1 — orchestrator-only

---

## Layer 2 — `resolveExplicitTarget` save-by-default (Silmari-philosophy fix)

**bd**: filed as `silmari-agent-memory-<NEW>` once user accepts plan
**Branch**: `fix/7qr-layer-2-resolve-target-degrade`
**Commit**: `fix(silmari-mcp): 7qr-L2 — resolveExplicitTarget degrades on missing parent (Luhmann save-by-default)`
**Effort**: ~15 min
**Blast radius**: medium — semantic shift in 1 function; affected callers must handle new return mode

### Goal

When `fromAddress` points to a fz label with no matching card, `resolveExplicitTarget` MUST log a `⚠️` warning and return `null` (not throw). `saveCard` interprets a null `explicitTarget` as "no explicit target requested" and proceeds with cursor-based allocation (effectively `mode='root'`).

This is the **Luhmann multiple-storage philosophy applied at the save layer**: the card is the durable artifact; the parent reference is recoverable later via the Gate B `reinforces`/`extends` edge classifier. Refusing to save because we couldn't pin the parent loses the card forever.

The four caller-bug throws stay (they detect programming errors, not data conditions):

- `box !== 'idea'` with `fromAddress` set → still throws
- `mode === 'root'` with `fromAddress` set → still throws
- malformed `fromAddress` (parse error) → still throws
- `fromAddress` targets sequence `0` (Register) → still throws
- `fromAddress` targets a `kind:register` card → still throws
- ambiguous `fromAddress` (>1 card with same `fz:` label) → still throws (this is data corruption; surface it)

Only the **"0 matches"** case — line 517 — degrades.

### Test plan

Add to `apps/silmari-mcp/tests/zk-save-card-fromaddress.test.ts` (or a new `tests/save-by-default.test.ts` if cleaner):

```ts
describe("7qr-L2: resolveExplicitTarget save-by-default", () => {
  it("saves the card when fromAddress points to non-existent fz, with stderr warning", () => {
    const stderr = captureStderr();
    const result = saveCard({
      box: 'idea',
      body: 'Layer 2 degrade test card',
      kind: 'fact',
      trunk: 1,
      mode: 'fork',
      fromAddress: '1/9999z9z9',  // intentionally non-existent
    });
    expect(result).not.toBeNull();
    expect(result!.id).toMatch(/^zk-/);
    expect(result!.fz).toMatch(/^1\//);
    expect(stderr.captured()).toMatch(/⚠️ resolveExplicitTarget: no card at fromAddress 1\/9999z9z9/);
  });

  it("still throws on mode='root' + fromAddress (caller bug)", () => {
    expect(() => saveCard({
      box: 'idea', body: 'x', kind: 'fact', trunk: 1, mode: 'root', fromAddress: '1/3',
    })).toThrow(/fromAddress is only valid for fork\/continue/);
  });

  it("still throws on biblio + fromAddress (caller bug)", () => {
    expect(() => saveCard({
      box: 'biblio', body: 'x', kind: 'biblio', fromAddress: '1/3',
    } as any)).toThrow(/fromAddress is only valid for idea box/);
  });

  it("still throws on malformed fromAddress (caller bug)", () => {
    expect(() => saveCard({
      box: 'idea', body: 'x', kind: 'fact', trunk: 1, mode: 'fork', fromAddress: 'garbage',
    })).toThrow();
  });

  it("still throws on fromAddress targeting Register sequence 0 (semantic guard)", () => {
    expect(() => saveCard({
      box: 'idea', body: 'x', kind: 'fact', trunk: 1, mode: 'fork', fromAddress: '1/0',
    })).toThrow(/Register/);
  });

  it("happy path: fromAddress targets existing card → forks normally", () => {
    const parent = saveCard({ box: 'idea', body: 'parent', kind: 'fact', trunk: 1, mode: 'root' })!;
    const child = saveCard({
      box: 'idea', body: 'child', kind: 'fact', trunk: 1, mode: 'fork', fromAddress: parent.fz,
    })!;
    expect(child.fz.startsWith(parent.fz)).toBe(true);
  });

  it("degraded save still emits Tier A edges + keyword fan-out (no orphan)", () => {
    // Important: a save that degraded to root must still satisfy L4 anchor invariant
    // (or trigger zk.anchor.missing log) — no special-casing.
    const result = saveCard({
      box: 'idea',
      body: 'Test card with title tokens visible',
      kind: 'fact',
      trunk: 1,
      mode: 'fork',
      fromAddress: '1/9999z9z9',  // missing → degrade
    });
    expect(result).not.toBeNull();
    // Look for the keyword entry written by the L2 fan-out
    expect(lookupKeyword('visible')?.entry_points).toContain(result!.id);
  });
});
```

### Implementation sketch

In `card-ops.ts:510-518`, the only change:

```diff
   const matches = brList({
     box: 'idea',
     labels: [fzLabel(trunk, parsed.sequence)],
     limit: 2,
     all: true,
   });
-  if (matches.length === 0) {
-    throw new Error(`no parent card exists at ${fromAddress}`);
-  }
+  if (matches.length === 0) {
+    // Silmari save-by-default (bd 7qr-L2): missing fork target degrades to
+    // null so saveCard falls back to cursor-based allocation. The card
+    // saves regardless; the intended fork relationship is recoverable
+    // later via the Gate B `reinforces`/`extends` classifier.
+    console.error(`⚠️ resolveExplicitTarget: no card at fromAddress ${fromAddress} — degrading to root allocation`);
+    return null;
+  }
   if (matches.length > 1) {
     throw new Error(`ambiguous fromAddress ${fromAddress}: ${matches.length} cards share this fz label`);
   }
```

In `card-ops.ts:566-569`, the call site already handles `null` correctly (`explicitTarget` falsy → cursor-based allocation in step 2). No change needed there.

In `card-ops.ts:605-614`, the `try { ... } catch (err) { if (explicitTarget) throw err; ... }` block: this rethrows on explicit-target errors. After Layer 2, the only "errors" left from `resolveExplicitTarget` are caller-bug throws (which SHOULD be rethrown). No change needed.

### Acceptance

- ✅ All 7 new tests pass
- ✅ All existing `zk-save-card-fromaddress.test.ts` tests still pass
- ✅ Greppable log line `⚠️ resolveExplicitTarget: no card at fromAddress ...` appears in test output
- ✅ The card produced by a degraded save has a valid `fz` (root-level address in the trunk)
- ✅ The card produced by a degraded save passes Tier A + L2 keyword fan-out (no orphan)

### Anti-criteria

- ❌ Do NOT degrade on `mode='root' + fromAddress` (caller bug)
- ❌ Do NOT degrade on malformed addresses (caller bug)
- ❌ Do NOT degrade on `matches.length > 1` ambiguous (data corruption — surface it)
- ❌ Do NOT add a "strict mode" flag — Silmari is single-mode save-by-default (one philosophy, one behavior)
- ❌ Do NOT change the throw at line 498 (`mode === 'root'` with `fromAddress`)

---

## Layer 3 — Cursor commit-after-create (counter-drift structural fix)

**bd**: filed as `silmari-agent-memory-<NEW>` once user accepts plan
**Branch**: `fix/7qr-layer-3-cursor-after-create`
**Commit**: `fix(silmari-mcp): 7qr-L3 — folgezettel cursor advances only after brCreate succeeds`
**Effort**: ~30 min
**Blast radius**: larger — touches `assignFolgezettel`'s contract and `saveCard`'s sequencing

### Goal

The folgezettel cursor file `${SILMARI_IDEA_DIR}/folgezettel-cursors.json` MUST only reflect cursor positions whose corresponding cards exist in the beads store. If `brCreate` fails (returns null), the cursor MUST NOT have advanced.

This is the **structural** fix that prevents 7qr's cascading failure mode: even if WAL visibility races (p6i family) cause a Phase-1 save to half-fail, the next transcript's thesis sees the OLD cursor and computes a fresh sequence that doesn't collide with the in-flight WAL row.

### Design choice — three options considered

| Option | Description | Pros | Cons |
|---|---|---|---|
| **A — Two-phase cursor** | `assignFolgezettel` returns the next sequence WITHOUT writing the cursor; `saveCard` writes the cursor after `brCreate` returns non-null | Atomicity-of-intent: cursor reflects only persisted cards | Changes `assignFolgezettel`'s contract; ~12 callers to audit (mostly tests, but also any direct API consumers) |
| **B — Rollback on failure** | Keep `assignFolgezettel` writing the cursor; `saveCard` rolls back the cursor on `brCreate` failure | No API change | Race window between cursor write and rollback; concurrent saves can interleave; rollback-of-cursor itself can fail and leave orphan |
| **C — Verify-on-read** | Don't change cursor write; on read, verify the cursor's address has a corresponding card and rebuild from `br list` if not | Fully self-healing | Expensive read path; conceptually wrong (cursor should be source of truth, not derived) |

**Choice: Option A.** Two-phase cursor matches the existing "best-effort, ordered-after-brCreate" pattern that Phase 2 of the compounding-substrate plan already uses for L2 keyword writes (per `2026-04-22-tdd-silmari-compounding-substrate.md` overview). Same conceptual model: writes that depend on `brCreate` success are sequenced AFTER that success, with documented best-effort-or-warn semantics on the post-write itself.

The contract change for `assignFolgezettel`:

```ts
// BEFORE: imperative — assigns AND persists
function assignFolgezettel(trunk, mode, fromSequence?): string

// AFTER: pure compute + explicit commit
function planFolgezettel(trunk, mode, fromSequence?): { sequence: string; commit: () => void }
```

Callers do `const { sequence, commit } = planFolgezettel(...); const id = brCreate(...); if (id) commit();`. Old name retained as a thin wrapper that `commit()`s immediately, marked `@deprecated` so existing tests keep passing without churn while real callers migrate.

### Test plan

Add to `apps/silmari-mcp/tests/folgezettel.test.ts` (pure-function tests) and `apps/silmari-mcp/tests/savecard-concurrency.test.ts` (integration):

```ts
describe("7qr-L3: planFolgezettel two-phase commit", () => {
  it("does NOT modify cursor file before commit() is called", () => {
    const before = readCursors();
    const plan = planFolgezettel(1, 'root');
    const after = readCursors();
    expect(after).toEqual(before);
    plan.commit();
    expect(readCursors().cursors['1']).toBe(plan.sequence);
  });

  it("commit() is idempotent (calling twice does not double-bump)", () => {
    const plan = planFolgezettel(1, 'root');
    plan.commit();
    const first = readCursors().cursors['1'];
    plan.commit();
    expect(readCursors().cursors['1']).toBe(first);
  });

  it("two concurrent plans race deterministically — last commit wins", () => {
    const a = planFolgezettel(1, 'root');
    const b = planFolgezettel(1, 'root');
    expect(a.sequence).toBe(b.sequence);  // both saw same cursor state
    a.commit();
    b.commit();  // second commit clobbers — caller responsibility to detect
    // This is OK: brCreate failure of the loser will leave cursor at b.sequence
    // which is the same as a.sequence; no drift.
  });
});

describe("7qr-L3: saveCard cursor rollback on brCreate failure", () => {
  it("cursor unchanged when brCreate returns null (simulated failure)", async () => {
    const before = readCursors().cursors['1'];
    // Force brCreate failure via env or mock — see existing patterns in
    // savecard-concurrency.test.ts. If no clean mock exists, this test
    // becomes "spawn `br` against a read-only DB" or similar.
    process.env.SILMARI_TEST_FORCE_BRCREATE_FAIL = '1';
    try {
      const result = saveCard({ box: 'idea', body: 'force-fail', kind: 'fact', trunk: 1, mode: 'root' });
      expect(result).toBeNull();
    } finally {
      delete process.env.SILMARI_TEST_FORCE_BRCREATE_FAIL;
    }
    const after = readCursors().cursors['1'];
    expect(after).toBe(before);  // ← the structural fix
  });

  it("cursor advances exactly once per successful brCreate", () => {
    const before = readCursors().cursors['1'] ?? '0';
    const before_n = parseInt(before.match(/^(\d+)/)?.[1] ?? '0', 10);
    saveCard({ box: 'idea', body: 'normal save', kind: 'fact', trunk: 1, mode: 'root' });
    const after_n = parseInt(readCursors().cursors['1'].match(/^(\d+)/)![1], 10);
    expect(after_n).toBe(before_n + 1);
  });
});
```

### Implementation sketch

```diff
// folgezettel.ts
+ export interface FolgezettelPlan {
+   sequence: string;
+   commit: () => void;
+ }
+
+ export function planFolgezettel(
+   trunk: TrunkId,
+   mode: FolgezettelMode,
+   fromSequence?: string,
+ ): FolgezettelPlan {
+   if (!VALID_TRUNKS.includes(trunk)) throw new Error(`Invalid trunk: ${trunk}`);
+   if (fromSequence != null) {
+     parseSequence(fromSequence);
+     if (mode === 'root') throw new Error('fromSequence is only valid for fork/continue, not root');
+   }
+   const file = readCursors();
+   const key = String(trunk);
+   const current = file.cursors[key];
+   const base = fromSequence ?? current;
+   let next: string;
+   if (mode === 'root' || !base) {
+     const maxRoot = current ? sequenceRootInt(current) : 0;
+     next = rootSequence(maxRoot);
+   } else if (mode === 'fork') {
+     next = forkSequence(base);
+   } else {
+     next = continueSequence(base);
+   }
+   let committed = false;
+   const commit = () => {
+     if (committed) return;
+     committed = true;
+     // Re-read to merge with any concurrent commits — last-write-wins
+     // is acceptable because all values are derived from the same observed
+     // cursor + a deterministic mode.
+     const fresh = readCursors();
+     fresh.cursors[key] = next;
+     writeCursors(fresh);
+   };
+   return { sequence: next, commit };
+ }
+
+ /** @deprecated Use planFolgezettel + commit() to avoid cursor drift on brCreate failure. */
  export function assignFolgezettel(
    trunk: TrunkId,
    mode: FolgezettelMode,
    fromSequence?: string,
  ): string {
-   // ... existing body that mutates immediately
+   const plan = planFolgezettel(trunk, mode, fromSequence);
+   plan.commit();
+   return plan.sequence;
  }
```

```diff
// card-ops.ts saveCard step 2 + step 5
   if (opts.box === 'idea') {
     try {
       effectiveMode = mode as FolgezettelMode;
       if (explicitTarget) {
         parentSequence = explicitTarget.sequence;
       } else {
         const cursors = readCursors();
         parentSequence = cursors.cursors[String(opts.trunk)] ?? null;
       }
-      const sequence = assignFolgezettel(
+      const plan = planFolgezettel(
         opts.trunk,
         effectiveMode,
         explicitTarget?.sequence,
       );
+      var folgezettelCommit = plan.commit;  // hoisted for step 5
+      const sequence = plan.sequence;
       fzAddress = formatAddress(opts.trunk, sequence);
       fzLabelStr = fzLabel(opts.trunk, sequence);
     } catch (err) {
       // ... unchanged
     }
   }

   // Step 5: create
   const id = brCreate({ ... });
-  if (!id) return null;
+  if (!id) return null;  // cursor never committed — no drift
+  folgezettelCommit?.();   // commit cursor only after brCreate succeeds
```

(The `var` hoist is intentional and idiomatic; `let` outside the `if` block also works.)

### Acceptance

- ✅ All 5 new tests pass (3 pure-function, 2 integration)
- ✅ All existing `folgezettel.test.ts` and `savecard-concurrency.test.ts` tests still pass
- ✅ A `SILMARI_TEST_FORCE_BRCREATE_FAIL=1` save call leaves the cursor file byte-identical
- ✅ The deprecated `assignFolgezettel` shim works for any non-saveCard caller (tests, scripts) without source changes
- ✅ Concurrent saves where one fails and one succeeds → cursor reflects only the successful one's address

### Anti-criteria

- ❌ Do NOT remove `assignFolgezettel` — too many callers to migrate in this commit; deprecate first, remove in a follow-up
- ❌ Do NOT add cursor-rollback logic — option A explicitly chose plan-then-commit over commit-then-rollback for race cleanliness
- ❌ Do NOT touch `readCursors`/`writeCursors` — those primitives stay unchanged
- ❌ Do NOT add `SILMARI_TEST_FORCE_BRCREATE_FAIL` to production code paths — it's a test-only toggle inside `brCreate`'s try/catch (or simulated via a mock)

---

## Sequencing & Dependencies

```
Probe (Layer 0) ─────────────► validates which hypotheses are real
                                │
                                ▼
Layer 1 (cascade try/catch) ─── unblocks the playlist immediately
                                │
                                ▼
Layer 2 (resolveExplicitTarget) save-by-default — the philosophy fix
                                │
                                ▼
Layer 3 (cursor-after-create) ── structural prevention; lands last because
                                  it has the largest refactor footprint
```

Each layer is independently revertible. Each ships as its own commit. Layer 1 alone takes the 15-transcript run from 2/15 to roughly N-1/N (only the failing transcript dies). Layer 1 + Layer 2 takes it to N/N for the *missing-parent-fz* failure mode specifically. Layer 1 + Layer 2 + Layer 3 makes the system robust against the broader counter-drift class (which also covers some p6i variants).

**p6i and 7qr should be co-tracked.** This plan does not fix p6i (the WAL visibility race itself). p6i's fix is either (a) a `brShow` retry-on-`ISSUE_NOT_FOUND` shim in the wrapper, or (b) an engine-side fix in `vendor/beads_rust/`. Out of scope here; flagged for a separate plan.

---

## Risk register

| # | Risk | Mitigation |
|---|---|---|
| R1 | Layer 2 makes orphan-prone callers (cascade, manual fork patterns) silently degrade more often than before | The L4 anchor-missing log STILL fires for degraded saves with no Tier A edges — orphans are visible. Test 7 in Layer 2 explicitly verifies this. |
| R2 | Layer 3 contract change breaks an in-tree caller of `assignFolgezettel` other than `saveCard` | Deprecation shim retains the old semantics. Migration of remaining callers is a follow-up. |
| R3 | Probe blocked by sudo / docker permissions | User runs the probe shell script; pastes output; we proceed from observed state |
| R4 | The probe reveals NONE of hypotheses (a)/(b)/(c) — actual cause is something else entirely | Plan rewinds; investigation continues; no code lands |
| R5 | Layer 2 changes a constraint that tests in `extraction-hardening.test.ts` rely on (e.g. an L4 check that assumes save-throws-on-bad-fork) | The full MCP suite (491 tests) runs after Layer 2. Any failure → fix scope expanded or design re-evaluated |
| R6 | Concurrent saves (Layer 3 test 3) reveal a real race that current single-writer assumptions hide | Race is documented as known-acceptable in the test docstring; ticket filed if real-world impact appears |

---

## Probe Results — RUN 2026-04-25T08:30:00-04:00

Ran the probe queries directly against the preserved store (docker volume `silmari-kc-baker_store`) by copying the JSONL out of the volume and analyzing with `jq`. The on-disk label format uses underscore (`fz:1_5e`), not slash (`fz:1/5e`) — see `labels.ts:120-126`.

### Q1 — Cursor file state

```json
{
  "_schema_version": 2,
  "cursors": {
    "1": "16"
  },
  "last_updated": "2026-04-24T14:59:12.746Z"
}
```

Also notable: `beads.db-wal` weighs **108 MB** (vs the 5 MB checkpointed `beads.db`). That is an enormous unconsolidated WAL — a textbook surface for visibility-race bugs.

### Q2 — Cards at trunk-1 root addresses (fz:1_N for N=1..16, plus 1_5e)

| fz label | Card count | Sample id |
|---|---|---|
| `fz:1_1` | 1 | zk-xer |
| `fz:1_2` | 1 | zk-70u (transcript 1 thesis) |
| `fz:1_3` | 1 | zk-jix (transcript 2 thesis) |
| `fz:1_4` | 1 | zk-e3m (transcript 3 thesis) |
| `fz:1_5` | 1 | zk-w25 (transcript 4 thesis) |
| `fz:1_5e` | 1 | zk-92z (transcript 4's 5th theme — fork from 1_5) |
| `fz:1_6` | 1 | zk-h9b5 (transcript 5 thesis) |
| `fz:1_7` | 1 | zk-zde7 (transcript 6 thesis) |
| `fz:1_8` | 1 | zk-b3q7 |
| `fz:1_9` | 1 | zk-gn6h |
| `fz:1_10` | 1 | zk-06w3 |
| `fz:1_11` | 1 | zk-atbh |
| `fz:1_12` | 1 | zk-yy2a |
| `fz:1_13` | 1 | zk-zvmh |
| `fz:1_14` | 1 | zk-saru |
| `fz:1_15` | 1 | zk-swiy |
| `fz:1_16` | 1 | zk-zefq |

### Q3 — Per-root descendant counts (cards landed in each transcript's subtree)

```
fz:1_1 :   1 card
fz:1_2 :  71 cards   ← transcript 1, full success (thesis + 3 themes + 7 ideas + 11+ micros etc.)
fz:1_3 :  32 cards   ← transcript 2, Phase 1 partial (Gate B failed mid-way)
fz:1_4 :  46 cards   ← transcript 3, full success
fz:1_5 :  23 cards   ← transcript 4, Phase 1 partial (only 5 themes' worth landed; theme 6 = 1_5e? or first idea fail)
fz:1_6 :   1 card    ← transcript 5: ONLY thesis. No themes/ideas/micros.
fz:1_7..1_16 : 1 card each — same pattern: thesis ONLY, immediate theme[0] save threw
```

### Decision after probe — diagnosis CORRECTED

The probe **invalidates two of the three pre-probe hypotheses** and changes the priority of Layer 3:

| Hypothesis | Status | Evidence |
|---|---|---|
| (a) Counter-state drift — cursor advanced past missing cards | **REJECTED** | Cursor is at "16" AND a card exists at every address from 1_1 through 1_16. The cursor accurately reflects what was successfully `brCreate`d. |
| (b) Prefix-match family (hkg) — engine confusing 1_5 with 1_5e | **REJECTED** | Cards have correctly-formed distinct fz labels. Lookup by exact `fz:1_5` label would return exactly 1 card. |
| (c) Phantom labels — fz labels exist without corresponding cards | **REJECTED** | Every queried label resolves to exactly 1 card with that label. |
| (d) **NEW — WAL visibility race in the LOOKUP** (p6i family) | **CONFIRMED by elimination + evidence** | Thesis succeeds (`brCreate` writes to WAL → row exists in `beads.db-wal`). Immediate next subprocess `brList --label fz:1_<N>` opens a FRESH SQLite connection and that connection's read view has not yet picked up the WAL row. Returns 0 matches. `resolveExplicitTarget` throws. **The thesis card actually exists; the lookup just can't see it yet.** The 108 MB WAL is the smoking gun — checkpoints are PASSIVE and not keeping up with write volume. |

### Revised Layer 3

**The previously-planned Layer 3 (cursor commit-after-create) is no longer the right fix.** The cursor isn't drifting — it's correctly tracking creates. The actual bug is the LOOKUP race, not the WRITE race.

**Replacement Layer 3 (retry-then-degrade in resolveExplicitTarget):**

When `brList` for the parent fz returns 0 matches in a context where we just-recently expected the parent to be created (i.e., when the cascade is forking off a sibling), retry the lookup once with a small delay BEFORE degrading. If the retry also returns 0, then degrade per Layer 2.

Rationale: the Luhmann save-by-default principle still holds (Layer 2 unchanged), but a 50-100ms retry costs nothing and recovers the intended fork relationship in the WAL-race case (likely 100% of 7qr's cascade failures, given the evidence above).

Concrete sketch (replaces Layer 3 implementation):

```ts
// resolveExplicitTarget — retry-then-degrade
let matches = brList({ box: 'idea', labels: [fzLabel(trunk, parsed.sequence)], limit: 2, all: true });
if (matches.length === 0) {
  // p6i / 7qr defense: a freshly-created parent's WAL row may not be visible
  // to this fresh `br list` subprocess yet. One retry with 100ms delay catches
  // the WAL checkpoint. Cost: at most 100ms on a real miss; zero on a hit.
  Bun.sleepSync(100);
  matches = brList({ box: 'idea', labels: [fzLabel(trunk, parsed.sequence)], limit: 2, all: true });
}
if (matches.length === 0) {
  // Layer 2: degrade to root allocation (Luhmann save-by-default)
  console.error(`⚠️ resolveExplicitTarget: no card at fromAddress ${fromAddress} after retry — degrading to root`);
  return null;
}
```

Layers 1 and 2 are UNCHANGED.

### Updated layer effort estimate

| Layer | Original effort | Revised effort | Notes |
|---|---|---|---|
| Probe | (run) | ✅ done | Findings recorded above |
| Layer 1 — cascade try/catch | ~10 min | ~10 min | Unchanged |
| Layer 2 — save-by-default degrade | ~15 min | ~15 min | Unchanged |
| Layer 3 — ~~cursor-after-create~~ → retry-then-degrade | ~30 min | **~10 min** | Smaller fix; lives in same function as Layer 2; could even merge |

**Total revised effort: ~35 min** (down from ~60 min).

**Merge consideration**: Layers 2 and 3 both modify `resolveExplicitTarget` 3-line region. They could ship as one commit. Recommendation: ship as one commit with two ISCs in the message ("save-by-default + WAL retry"), since they're conceptually the same change ("don't fail on a transient lookup miss; either way, save the card").

### Implications for p6i

p6i (`ISSUE_NOT_FOUND` on `br label add` ~3% of Gate B commits) is the **same WAL visibility race** but at a different code path. The same `Bun.sleepSync(100) + retry` pattern would fix p6i too. After the 7qr fix lands and is validated, the same primitive can be applied to `brLabelAdd` to close p6i.

Worth noting: a more general fix would be a `br`-wrapper-level retry on `ISSUE_NOT_FOUND`, applied once across all wrappers. That's a larger scope (touches every `br*` function) and out of this plan, but worth a follow-up bd.

---

## Out of scope

- p6i WAL visibility race fix (separate plan)
- Engine-side changes to `vendor/beads_rust/` (separate effort, upstream)
- A general retry policy for any failed `br` shell-out (separate plan; would benefit p6i more than 7qr)
- Changes to the cascade prompts (Pass 1/2/3) — orthogonal to ingestion reliability
- Re-running the failing 7qr 15-transcript playlist — operational follow-up after the fixes land
- Refactoring `assignFolgezettel` callers off the deprecated alias — follow-up bd, not this plan

---

## Definition of done

- [ ] Probe script lands at `scripts/kc-baker-pipeline-v2/probes/probe-7qr.sh` and runs successfully against the preserved store
- [ ] Probe results recorded in this plan's "Probe Results" section
- [ ] Layer 1 commit lands; orchestrator test suite passes; manual or scripted simulation shows N-1/N failure isolation
- [ ] Layer 2 commit lands; full MCP suite (`bun test apps/silmari-mcp/tests/`) passes; new save-by-default tests pass; greppable `⚠️` log present
- [ ] Layer 3 commit lands; folgezettel + savecard-concurrency suites pass; force-fail test confirms zero cursor drift
- [ ] bd 7qr updated with notes citing each commit hash and "fixed" status; consider closing once a re-run of the 15-transcript playlist completes successfully
- [ ] bd entries created for each layer (3 total) for clean audit trail
