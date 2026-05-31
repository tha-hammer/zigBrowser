---
date: 2026-04-24T09:09:25-04:00
researcher: tha-hammer
git_commit: 41d042382f9c006eb040eec50b5ddcab50df9466
branch: main
repository: silmari-agent-memory
topic: "brShow() wrapper prefix-match bug (hkg) + br label add ISSUE_NOT_FOUND on just-saved IDs (p6i)"
tags: [research, codebase, br-adapter, beads_rust, gate-b, prefix-match, silmari-agent-memory-hkg, silmari-agent-memory-p6i]
status: complete
last_updated: 2026-04-24
last_updated_by: tha-hammer
---

# 🔍 Research — Two `br`-prefix-related bugs: `hkg` (wrapper) + `p6i` (runtime)

```
┌─────────────────────────────────────────────────────────────────────┐
│  2026-04-24 · silmari-agent-memory @ 41d0423 · main                 │
│  Research scope: map — no fixes proposed, no RCA                    │
└─────────────────────────────────────────────────────────────────────┘
```

**Date**: 2026-04-24T09:09:25-04:00
**Researcher**: tha-hammer
**Git Commit**: 41d042382f9c006eb040eec50b5ddcab50df9466
**Branch**: main
**Repository**: silmari-agent-memory

## 🎯 Research Question

Two distinct bugs in the `br`-wrapping layer and engine surface:

- **Bug 1** — `brShow()` (apps/silmari-mcp/src/lib/br-adapter.ts:304) hands back `br`'s `.error`-shaped response as if it were a card when the engine's prefix-matcher returns `AMBIGUOUS_ID`. Filed as `silmari-agent-memory-hkg` [P2].
- **Bug 2** — `br label add <id> ref:…` returns `ISSUE_NOT_FOUND` for ~3–5% of IDs that `zk_save_card` returned seconds earlier in the same MCP session. Same IDs fail deterministically. **Already filed** as `silmari-agent-memory-p6i` [P2] — NOT missing from the tracker.

The user asked for a comprehensive map of what exists in the codebase for both bugs.

## 📋 Summary

| Aspect              | Bug 1 — `hkg` (wrapper)                               | Bug 2 — `p6i` (runtime)                                             |
|---------------------|-------------------------------------------------------|---------------------------------------------------------------------|
| Surface             | TypeScript wrapper shape-handling                      | beads_rust CLI runtime (prefix resolver + WAL visibility)           |
| Error code          | `AMBIGUOUS_ID`                                         | `ISSUE_NOT_FOUND`                                                   |
| Code location       | `apps/silmari-mcp/src/lib/br-adapter.ts:304`           | `vendor/beads_rust/src/util/id.rs:757` + fresh per-invoke connection|
| bd filed            | `silmari-agent-memory-hkg` (2026-04-22, P2, OPEN)      | `silmari-agent-memory-p6i` (2026-04-23, P2, OPEN)                   |
| Impact observed     | Silent false positives on existence checks             | ~3.4% Gate B commit drop (9 of ~265) in Step 8 eval                 |
| Repro evidence      | `/tmp/probe-b5c.ts` (10-process probe, 30% misresolve) | IDs `zk-d8z`, `zk-gmd`, `zk-r0l`, `zk-21m` in `/tmp/cascade-v2-eval-20260423/silmari-store` @ commit 33a1110 |
| Local workarounds   | 3 sites already carry guards                           | None — failures propagate via `false` returns + warn log            |
| Sibling risk        | `brList`, `brSearch` use the same `|| parsed ||` shape | Every `br` sub-invocation opens a new SQLite connection             |

The hkg description notes that p6i is a "related" symptom; the engine-side research in this document confirms they share the `IdResolver::resolve_fallible()` code path but fail at different stages (hkg = stage 3 ambiguous; p6i = stage 4 not-found).

## 📚 Detailed Findings

### 1. Bug 1 — `brShow()` wrapper at `br-adapter.ts:304`

#### 1.1 The function today

`apps/silmari-mcp/src/lib/br-adapter.ts:304-319`:

```typescript
export function brShow(box: Box, id: string): any | null {
  if (!ensureBoxWorkspace(box)) return null;
  try {
    const args = ['show', id, '--json', ...getDbFlag(box)];
    const result = execFileSync(BR, args, {
      timeout: TIMEOUT_READ,
      stdio: 'pipe',
      encoding: 'utf-8',
    });
    const parsed = JSON.parse(result);
    if (Array.isArray(parsed)) return parsed[0] || null;
    return parsed.issue || parsed || null;   // ← returns `{error:…}` as a card
  } catch {
    return null;
  }
}
```

The final line hands back the parsed JSON as-is when neither `parsed.issue` nor a falsy coercion applies. `parsed = {error: {...}}` is truthy and falls straight through to the caller.

#### 1.2 Call sites — 20 total across 9 source files + 3 test files

| File                                                | Line  | Function                       | Use of return value                              |
|-----------------------------------------------------|------:|--------------------------------|--------------------------------------------------|
| `apps/silmari-mcp/src/index.ts`                     |  760  | `zk_promote`                   | existence + `.status` field read                 |
| `apps/silmari-mcp/src/index.ts`                     |  808  | `readResource`                 | existence check                                  |
| `apps/silmari-mcp/src/lib/navigate.ts`              |  510  | `follow`                       | existence (root bead)                            |
| `apps/silmari-mcp/src/lib/navigate.ts`              |  533  | `follow` loop                  | existence (each step)                            |
| `apps/silmari-mcp/src/lib/edges.ts`                 |  134  | `listOutbound`                 | existence + `.labels`                            |
| `apps/silmari-mcp/src/lib/edges.ts`                 |  148  | `listOutboundOfType`           | existence + `.labels`                            |
| `apps/silmari-mcp/src/lib/structures.ts`            |  183  | `readStructureNote`            | existence                                        |
| `apps/silmari-mcp/src/lib/hubs.ts`                  |  212  | `readHubOrCreate`              | existence (fallback)                             |
| `apps/silmari-mcp/src/lib/hubs.ts`                  |  295  | `readHub`                      | existence                                        |
| `apps/silmari-mcp/src/lib/line-of-thought.ts`       |  115  | `trunkSeedHubs`                | **has guard — rejects `.error` + id mismatch**   |
| `apps/silmari-mcp/src/lib/line-of-thought.ts`       |  192  | `lineOfThought`                | **has guard — rejects `.error` + id mismatch**   |
| `apps/silmari-mcp/src/lib/biblio.ts`                |  164  | `markIdeaDerivesFromBiblio`    | existence                                        |
| `apps/silmari-mcp/src/lib/biblio.ts`                |  186  | `listBiblioSourcesForIdea`     | existence + field read                           |
| `apps/silmari-mcp/src/lib/biblio.ts`                |  191  | `listBiblioSourcesForIdea`     | existence                                        |
| `apps/silmari-mcp/src/lib/semantic-proposer.ts`     |  227  | `fetchCandidate`               | **has guard — rejects `.error` + id mismatch**   |
| `apps/silmari-mcp/src/lib/semantic-proposer.ts`     |  298  | `fetchCandidateFz`             | **has guard**                                    |
| `apps/silmari-mcp/src/lib/semantic-proposer.ts`     |  388  | `proposeLinksSemantic`         | **has guard**                                    |
| `apps/silmari-mcp/src/lib/semantic-proposer.ts`     |  512  | `proposeLinksSemantic`         | **has guard**                                    |
| `apps/silmari-mcp/src/lib/card-ops.ts`              |  854  | `readCardBody`                 | existence                                        |
| `apps/silmari-mcp/src/lib/keyword-index.ts`         |  312  | `filterByKeywordOverlap`       | **has guard — `byId.id === entry` only**         |

Tests that exercise `brShow` on the happy path (no prefix-match test coverage):
- `apps/silmari-mcp/tests/recall-promote.test.ts`
- `apps/silmari-mcp/tests/extraction-hardening.test.ts`
- `apps/silmari-mcp/tests/savecard-concurrency.test.ts`

**Guarded sites (8 of 20):** line-of-thought.ts (×2), semantic-proposer.ts (×4), keyword-index.ts (×1), reconcile-keyword-index.ts (×1 via `cardExists`). **Unguarded sites (12 of 20):** the rest.

#### 1.3 The three workarounds in the tree today

**(a)** `apps/silmari-mcp/src/lib/line-of-thought.ts:115-124` (and 192-195, identical):

```typescript
const target = brShow('idea', targetId);
if (!target) continue;
// Guard against brShow's prefix-match bug (see silmari-agent-memory-hkg):
// reject error payloads and fuzzy matches.
if (typeof target === 'object' && 'error' in target) continue;
if (typeof target === 'object' && 'id' in target && target.id !== targetId) continue;
```

Full triple guard: null / error-shape / id-mismatch.

**(b)** `apps/silmari-mcp/scripts/reconcile-keyword-index.ts:168-185`:

```typescript
function cardExists(cardId: string): boolean {
  try {
    const result = brShow('idea', cardId);
    if (result === null) return false;
    if (typeof result === 'object' && result !== null) {
      if ('error' in result) return false;
      if ('id' in result && result.id !== cardId) return false;
    }
    return true;
  } catch {
    return false;
  }
}
```

A dedicated helper; same triple guard. Referenced by `reconcileKeywordIndex()` at line 118.

**(c)** `apps/silmari-mcp/src/lib/keyword-index.ts:308-334` (added 2026-04-23 by CloudySpring in commit 4804e44):

```typescript
for (const [entry] of qualified) {
  const byId = brShow('idea', entry) as BeadRow | null;
  // Defensive id-match: `br show <unknown-id>` has been observed to
  // occasionally return an unrelated bead instead of erroring. Only
  // accept the result when the returned row's id matches the entry.
  if (byId && byId.id === entry) {
    out.push(byId);
    continue;
  }
  // Fall back to address-based lookup if the id-match fails
  if (!entry.includes('/')) continue;
  …
}
```

**Narrower pattern** — only the id-equality check; no explicit `.error` guard (relies on the mismatch to reject error objects since they lack a matching `.id`).

#### 1.4 Sibling wrappers with the same shape pattern

`br-adapter.ts` uses `return parsed.X || parsed || fallback` in three functions and `return parsed.X || null` in a fourth. The table below captures the shape risk across all wrappers:

| Wrapper        | Return pattern                                         | Error-swallow risk |
|----------------|--------------------------------------------------------|---|
| `brShow`   L315| `parsed.issue \|\| parsed \|\| null`                   | **HIGH** — returns `.error` as a card |
| `brList`   L256| `parsed.issues \|\| parsed \|\| []`                    | **HIGH** — returns `.error` as a row list |
| `brSearch` L287| `parsed.issues \|\| parsed \|\| []`                    | **HIGH** — same as brList |
| `brDepList`L435| `Array.isArray(parsed) ? parsed : parsed.dependencies…`| **MEDIUM** — post-processes; .error would iterate as empty |
| `brCreate` L156| `parsed.id \|\| null`                                  | **LOW** — `.error.id` undefined → null; try/catch handles rest |
| `brUpdate`     | boolean                                                | **LOW** |
| `brClose`      | boolean                                                | **LOW** |
| `brDelete`     | boolean                                                | **LOW** |
| `brLabelAdd`   | boolean, logs on catch                                 | **LOW** |
| `brLabelRemove`| boolean, logs on catch                                 | **LOW** |
| `brDepAdd`     | boolean, logs on catch                                 | **LOW** |

No tests cover the ambiguous-prefix case on `brList` or `brSearch`.

### 2. Bug 2 — `br label add <id>` ISSUE_NOT_FOUND on Gate B

#### 2.1 The bd record

`bd show silmari-agent-memory-p6i` (created 2026-04-23, P2, OPEN) records:
- Failure rate **3.4%** (9 of ~265 proposals) in the Step 8 MVP eval
- Reproduced IDs: `zk-d8z`, `zk-gmd`, `zk-r0l`, `zk-21m`
- Store at `/tmp/cascade-v2-eval-20260423/silmari-store` at commit `33a1110`
- Notable concentration of cross-transcript `reinforces` proposals in the lost set (e.g., `zk-21m → zk-j28/piz/jkh`)

#### 2.2 The full data path: `zk_save_card` → `zk_commit_link` → `br label add`

**Step A — card creation** (`apps/silmari-mcp/src/lib/card-ops.ts:640-649`):

```typescript
const id = brCreate({
  box: opts.box, title, type: 'docs',
  labels: composeLabels(labels), description,
  priority: opts.priority ?? defaultPriorityForKind(opts.kind),
  status: opts.status || 'open',
});
if (!id) return null;
```

`brCreate` parses `br create`'s JSON, returns `.id`, and gives control back.

**Step B — proposal persistence** (`apps/silmari-mcp/src/lib/edges.ts:270-310`): `zk_propose_link` writes the proposal (`fromId`, `toId`, `edge`, `box`, `status`) to `~/.silmari/link-proposals.jsonl`. IDs are frozen into the JSONL at propose time — no re-verification against the DB.

**Step C — commit** (`apps/silmari-mcp/src/lib/edges.ts:326-356`):

```typescript
export function commitLink(proposalId: string, reason?: string): LinkProposal | null {
  const proposals = readProposals();
  const idx = proposals.findIndex((p) => p.id === proposalId);
  if (idx < 0) return null;
  const proposal = proposals[idx]!;
  const ok = addEdge(proposal.box, proposal.from_id, proposal.edge, proposal.to_id);
  if (!ok) { console.error(`⚠️ commitLink: addEdge failed for proposal ${proposalId}`); return null; }
  …
}
```

**Step D — label add** (`apps/silmari-mcp/src/lib/edges.ts:93`, inside `addEdge()`): `brLabelAdd(box, fromId, 'ref:<edge>:<toId>')`. No preflight `brShow` to validate the ID first.

**Step E — shell out** (`apps/silmari-mcp/src/lib/br-adapter.ts:463-478`):

```typescript
export function brLabelAdd(box: Box, id: string, ...labels: string[]): boolean {
  if (labels.length === 0) return true;
  try {
    const args = ['label', 'add', id, ...labels, ...baseFlags(box)];
    execFileSync(BR, args, { timeout: TIMEOUT_WRITE, stdio: 'pipe', encoding: 'utf-8' });
    return true;
  } catch (err) {
    const msg = (err as Error)?.message?.slice(0, 240) || String(err);
    console.error(`⚠️ brLabelAdd failed: ${id} += [${labels.join(',')}]: ${msg}`);
    return false;
  }
}
```

`TIMEOUT_WRITE = 1000ms`. No retry. No backoff. No flush. One call, one chance.

#### 2.3 Gate B loop structure in the cascade pipeline

`scripts/kc-baker-pipeline-v2/ingest/ingest-cascade.ts` — `runGateBForCard()` at 355-425:

- Outer loop iterates `allIds` (all cards saved for this transcript) serially
- Inner loop iterates proposals ≥ `GATEB_CONFIDENCE_FLOOR` (0.7) serially
- Each inner iteration calls `zk_propose_link` then `zk_commit_link`
- Failure path: `console.warn` at line 443, loop continues

```typescript
for (const cardId of allIds) {                    // serial over ~22 cards
  for (const prop of proposalsAboveFloor) {        // serial proposals per card
    const ok = await commitProposal(...);          // serial propose+commit
  }
}
```

No retry/skip/backoff on `ok === false`. The 3.4% just disappear into warn-logs.

#### 2.4 Engine-side behavior: `br show` + `br label add` in beads_rust

**Command entry** — `vendor/beads_rust/src/cli/commands/show.rs:25-33` and `vendor/beads_rust/src/cli/commands/label.rs:150-194`. Both route through `resolve_issue_id()` at `src/cli/commands/mod.rs:49-61`, which delegates to `IdResolver::resolve_fallible()`.

**ID resolution — 3-stage fallback** (`vendor/beads_rust/src/util/id.rs:757-823`):

1. **Exact match** — `exists_fn(normalized)` → returns `ResolvedId { match_type: Exact }`.
2. **Prefix normalization** — if input has no `-`, prepend `default_prefix` and retry exact.
3. **Substring match on hash portion** — `substring_match_fn(hash_pattern)`:
   - 0 matches → fall through
   - 1 match → `ResolvedId { match_type: Substring }`
   - 2+ matches → **`BeadsError::AmbiguousId { partial, matches }`**

If every stage fails → **`BeadsError::IssueNotFound { id }`**.

**Error-to-JSON mapping** (`vendor/beads_rust/src/error/structured.rs`):

```json
// AMBIGUOUS_ID (stage 3, 2+ matches)
{"error":{"code":"AMBIGUOUS_ID","message":"Ambiguous ID '<partial>': matches <count> issues",
  "context":{"partial_id":"<partial>","matches":["zk-13w","zk-dx1"],"match_count":2}}}

// ISSUE_NOT_FOUND (all stages failed)
{"error":{"code":"ISSUE_NOT_FOUND","message":"Issue not found: <id>",
  "context":{"searched_id":"<id>"}}}
```

**No `--exact` / `--strict` flag.** `ShowArgs` (clap definition at `mod.rs:1542-1558`) exposes only `ids`, `--format`, `--wrap`, `--stats`.

#### 2.5 SQLite connection model + WAL visibility

`vendor/beads_rust/src/storage/sqlite.rs:367-426`:

```rust
pub fn open_with_timeout(path: &Path, lock_timeout_ms: Option<u64>) -> Result<Self> {
    let conn = Connection::open(path.to_string_lossy().into_owned())?;
    if let Some(timeout_ms) = lock_timeout_ms {
        conn.execute(&format!("PRAGMA busy_timeout={timeout_ms}"))?;
    }
    crate::storage::schema::apply_runtime_pragmas(&conn)?;
    Ok(Self { conn, mutation_count: 0 })
}
```

- **Fresh `Connection::open()` per `br` invocation.** No pooling, no shared connection between the Bun MCP process and the child `br` processes it spawns.
- WAL mode enabled via `apply_runtime_pragmas`.
- WAL checkpoint runs on a 50-mutation interval (`WAL_CHECKPOINT_INTERVAL = 50`) — **PASSIVE** (non-blocking), so checkpoint progress is not guaranteed between consecutive `br` invocations.
- `checkpoint_wal()` at lines 812-825 explicitly tolerates failure (`"non-fatal, will retry later"`).

**Observable sequence for the failing case:**

1. T+0ms — `zk_save_card` → `brCreate` spawns `br create` child. Child opens conn A, writes row to WAL, commits, exits.
2. T+10ms — Bun reads `stdout`, returns `id`.
3. T+Nms (later in same session) — `zk_commit_link` → `brLabelAdd` spawns `br label add <id>` child. Child opens conn B (fresh), reads DB state.
4. Resolver runs stages 1→3 against conn B's read view.
5. If the row is only in the WAL and conn B's read view hasn't picked it up yet → `IssueNotFound`.

The hkg description itself notes `br-adapter.ts:343` (brDelete docstring) explicitly mentions SQLite WAL race awareness: *"if two beads share a `content_hash:` label due to a SQLite WAL race, delete the newer one."* This is the only place in the wrapper that documents WAL race awareness; no flush/sync logic exists between `brCreate` and downstream calls.

**The "deterministic on specific IDs" observation** in the bd description (p6i) is an empirically-reported property — the underlying code path documented above does not, on its face, explain why particular IDs fail repeatedly rather than a random subset. Explaining that is out of scope for this documentation pass.

### 3. Ingest-report telemetry for Bug 2

`scripts/kc-baker-pipeline-v2/extracted/kc_bakers_words_of_wisdom/ingest-report.json`:

```json
"gateB": {
  "sources_scanned": 22,
  "candidates_total": 440,
  "edges_proposed": 76,
  "edges_committed": 75,
  "by_edge_type": { "refines": 17, "reinforces": 54, ... }
}
```

No explicit `failures` field — the 1-edge gap (75 vs 76) is the only observable hint at wrapper-level. The eval PRD aggregates across 3 transcripts to the ~3.9% rate.

## 🗺️ Code References

### Bug 1 — wrapper
- `apps/silmari-mcp/src/lib/br-adapter.ts:304-319` — `brShow()` definition with the error-swallowing line at 315
- `apps/silmari-mcp/src/lib/br-adapter.ts:256` — `brList()` same pattern
- `apps/silmari-mcp/src/lib/br-adapter.ts:287` — `brSearch()` same pattern
- `apps/silmari-mcp/src/lib/line-of-thought.ts:115-124` — triple-guard workaround (a)
- `apps/silmari-mcp/src/lib/line-of-thought.ts:192-195` — triple-guard workaround (a) duplicate
- `apps/silmari-mcp/scripts/reconcile-keyword-index.ts:168-185` — `cardExists()` helper (b)
- `apps/silmari-mcp/src/lib/keyword-index.ts:308-334` — id-equality workaround (c), added 2026-04-23 (commit 4804e44)
- `apps/silmari-mcp/src/lib/semantic-proposer.ts:227,298,388,512` — four guarded brShow sites

### Bug 2 — Gate B commit path
- `apps/silmari-mcp/src/lib/br-adapter.ts:463-478` — `brLabelAdd()` definition
- `apps/silmari-mcp/src/lib/edges.ts:93` — `addEdge()` → `brLabelAdd` (single call site that checks return)
- `apps/silmari-mcp/src/lib/card-ops.ts:471,755,756` — three `brLabelAdd` sites that ignore return (label `needs-consolidation-review:true`)
- `apps/silmari-mcp/src/lib/edges.ts:326-356` — `commitLink()` flow
- `apps/silmari-mcp/src/lib/edges.ts:270-310` — `proposeLink()` JSONL persistence
- `apps/silmari-mcp/src/lib/card-ops.ts:640-649` — `brCreate` call inside `saveCard`
- `scripts/kc-baker-pipeline-v2/ingest/ingest-cascade.ts:355-425,485-499` — Gate B loop structure
- `scripts/kc-baker-pipeline-v2/extracted/kc_bakers_words_of_wisdom/ingest-report.json` — the 75-vs-76 gap

### Bug 2 — engine
- `vendor/beads_rust/src/cli/commands/show.rs:25-33` — `br show` handler
- `vendor/beads_rust/src/cli/commands/label.rs:150-194` — `br label add` handler
- `vendor/beads_rust/src/cli/commands/mod.rs:49-61` — shared `resolve_issue_id()`
- `vendor/beads_rust/src/util/id.rs:757-823` — `IdResolver::resolve_fallible()` 3-stage matcher
- `vendor/beads_rust/src/storage/sqlite.rs:367-426` — fresh `Connection::open()` per invoke
- `vendor/beads_rust/src/storage/sqlite.rs:812-825` — `checkpoint_wal()` (PASSIVE, non-fatal)
- `vendor/beads_rust/src/error/structured.rs:316-365` — AMBIGUOUS_ID + ISSUE_NOT_FOUND JSON shapes

## 🏗️ Architecture Documentation

**Wrapper pattern (br-adapter.ts):** graceful-degradation wrappers around `execFileSync(BR, …)`, all returning null/false/[] on failure. JSON-shape handling falls into two families: *boolean returns* (safe) and *value returns* (vulnerable). The `return parsed.X || parsed || fallback` idiom is the recurring shape risk.

**Edge layer (edges.ts):** edges are encoded as `ref:<edge-type>:<target-id>` labels on the source bead. Propose is JSONL-persisted; commit turns the label append into a `br label add` shell-out. There is no "preflight verify" step between creating a card and later committing an edge with that card as `fromId`.

**Engine (beads_rust):** local-first single-binary CLI. ID resolution is permissive by design (3-stage fallback), with ambiguity surfaced explicitly rather than silently. SQLite in WAL mode, per-invocation connections, checkpoints on a count-based interval.

**Ingest pipeline (scripts/kc-baker-pipeline-v2/):** fully synchronous/serial in ingest-cascade.ts for both the save pass and the Gate B commit pass. No retry logic on any failure path — failed commits log `console.warn` and the loop proceeds.

## 📜 Historical Context (from thoughts/)

### Bug 1 — hkg

- `thoughts/shared/handoffs/general/2026-04-23_09-33-07_kc-baker-pipeline-resume-after-cascade-lands.md:122-129` — records the workaround added to `filterByKeywordOverlap` in commit 4804e44 and explicitly flags that any new Gate-B code touching `brShow` should either use a guarded path or replicate the id-match check until hkg is fixed at the wrapper.
- `thoughts/shared/plans/2026-04-22-step5.5-tdd-silmari-mcp-primitives.md:8-13` — the defensive `byId.id === entry` check was surfaced by a 10-process stability probe showing ~30% flake without the guard. Documents that without the guard, Behavior 5 flakes ~30% of runs.

### Bug 2 — p6i

- `MEMORY/WORK/20260423-173300_cascade-step8-mvp-eval/PRD.md:131-137` (Finding #6) — "9 of ~265 proposals failed to commit (3.4%). … Affects certain ids only — `zk-d8z`, `zk-gmd`, `zk-r0l`, `zk-21m` all hit this. … several of the failures WERE cross-transcript `reinforces` proposals. Gate B correctly detected cross-transcript conceptual overlap; the bug silenced their landing."
- `MEMORY/WORK/20260423-173300_cascade-step8-mvp-eval/PRD.md:174-175` — "Decision #3 — Filing follow-up bd; not part of Step 8 scope." This is the decision that produced `silmari-agent-memory-p6i` on 2026-04-23.

## 🔗 Related Research

- `thoughts/searchable/shared/plans/2026-04-22-step5.5-tdd-silmari-mcp-primitives.md` — where the keyword-index workaround was introduced
- `thoughts/searchable/shared/handoffs/general/2026-04-23_09-33-07_kc-baker-pipeline-resume-after-cascade-lands.md` — handoff flagging the bug for the cascade extractor
- `MEMORY/WORK/20260423-173300_cascade-step8-mvp-eval/PRD.md` — Finding #6 + Decision #3 originating p6i

## ❓ Open Questions

1. **Why do specific IDs (zk-d8z, zk-gmd, zk-r0l, zk-21m) fail deterministically rather than a random subset?** The engine code path (fresh connection + WAL visibility) suggests a time-sensitive race, which would produce non-deterministic failures. The deterministic pattern reported in bd p6i is not explained by the code paths documented here.
2. **Status of the 12 unguarded `brShow` call sites** — do any of them accept un-vetted IDs from an external source (JSONL, MCP tool args) such that a prefix-ambiguous ID could land? Not examined in this research pass.
3. **Gate B proposal-side vetting** — `proposeLink` writes to JSONL with no `brShow`-backed id check. If a proposed `fromId` is already wrong at propose time (not just commit time), the symptom shape would be identical. Not distinguished by the current ingest-report telemetry.
