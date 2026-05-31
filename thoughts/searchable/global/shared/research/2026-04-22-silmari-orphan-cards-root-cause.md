---
date: 2026-04-22T10:30:00-04:00
researcher: Silmari (via Maceo Jourdan)
git_commit: 6cbf8422a6789041d9d2478bdabed2ff70f48b6c
branch: main
repository: tha-hammer/silmari-agent-memory
topic: "Silmari orphan cards root cause — keyword-index non-existence cascades into LEARN-phase blindness and zero Tier B edge production"
tags: [research, silmari, zettelkasten, orphan-cards, keyword-registry, algorithm-learn, tier-a, tier-b, root-cause]
status: complete
last_updated: 2026-04-22
last_updated_by: Silmari
type: investigation
---

# Silmari Orphan Cards — Root Cause Analysis

**Trigger**: User-reported defect. Screenshot `/home/maceo/Pictures/Screenshots/2026-04-22_10-02.jpg` shows the silmari graph view populated with many isolated green dots — cards with no visible edge connections. In a Luhmann Zettelkasten this is an impossibility; every card belongs somewhere in the chain, keyword index, or crossref web.

**Scope**: Research only. No code changes this run. Deliverable is a diagnosis + scoped follow-up.

---

## TL;DR

- **303 cards, 115 of them (38%) are true orphans** — zero `ref:*` labels, zero inbound edges.
- **The `keywords` table does not exist in the source sqlite.** `zk_status.keywords: 0` is not "empty registry" — the storage for the Layer-1 retrieval substrate was never created. Every `zk_recall` call has been structurally blind since the 2026-04-06 cosmic→silmari migration.
- **This single upstream gap cascades into every Tier-B edge being skipped.** Algorithm LEARN calls `zk_recall`, gets nothing, classifies every reflection as "Novel", saves with `mode: root` (no fromAddress because there's no recalled address to fork from), and Tier A emits zero structural edges. LEARN correctly reports "Clean run — no edges emitted" — the protocol is honored in form, not in outcome.
- **0/6 recent completed LEARN runs emitted any Tier-B edge.** Not one `reinforces`, one `refines`, one `extends` in the entire store.
- **Only 4 `ref:branches:*` edges exist** across 303 cards — because Algorithm runs almost never invoke `mode: fork` + `fromAddress` (they can't; they have no address to fork from).
- **The graph screenshot is mathematically faithful.** It is not a rendering bug. The viewer pipeline (Options A/B cleanup landed in ffbe20d→89e540f) is rendering the data correctly. The data is what's broken.
- **Primary root cause (single, definitive):** the absence of a keyword index that `zk_recall` can read. This is a data-model gap that predates any of the recent Tier A / Tier B / viewer-strip work and has been quietly compounding for 17 days.
- **Scoped fix**: one bd task — **"Bootstrap keyword-index substrate"** — elaborated in §6.

---

## 1. What we're looking at

### 1.1 The symptom

Screenshot shows a two-population graph:
- **Small connected cluster** on the left: cards that DO have edges (the 188 non-orphan cards via 365 `ref:*` labels among them)
- **Scatter of isolated green dots** across the rest of the canvas: the 115 orphan cards

Representative orphan titles (all visible in screenshot, all verified with SQL):

| Card ID | Title | FZ | Source tag |
|---|---|---|---|
| `zk-4eqe` | Parallel Agent tool invocation is under-used… | `5_283` | `algo-silmari-pitch-learn` |
| `zk-hbmz` | Smarter AI-design meta-improvement… | `5_264` | `algo-pitchdeck-learn` |
| `zk-tcco` | Silmari deploy cycle — after ./scripts/d… | `5_275` | `algorithm-deploy-cycle-phase-1-2-learn` |
| `zk-bgp6` | For research-then-plan tasks producing… | `5_279` | `algorithm-bv-force-graph-edges-research-learn` |
| `zk-2xwx` | When designing UI edit/extend affordances… | `5_??` | `algorithm-20260421-cardview-serendipity-redesign-learn` |

Every one of these is an Algorithm LEARN reflection save. Every one has a folgezettel address (`fz:5_N`) but **no letter-suffix** — they are root-level saves, flat-sequential, never forked or branched.

### 1.2 The story the numbers tell

From direct SQL against `~/.silmari-memory/box2-ideas/.beads/beads.db`:

```
cards total:     303
labels total:  3,118
ref:* labels:    365  ← the connective tissue
```

Ref-label breakdown:

| Edge type | Count | Tier | Emitted by |
|---|---|---|---|
| `derives-from` | 192 | AUTO | `extractSourceReference()` when `source:` is a bead-id |
| `refers-to` | 106 | AUTO | `extractBodyMentions()` on `zk-*`/`bl-*` in body |
| `follows` | 63 | AUTO | `extractFolgezettelParent()` on `mode: continue` |
| `branches` | **4** | AUTO | `extractFolgezettelParent()` on `mode: fork` |
| `supports` | **0** | REVIEWED | LEARN-phase `zk_propose_link` (never called) |
| `contradicts` | **0** | REVIEWED | LEARN-phase `zk_propose_link` (never called) |
| `extends` | **0** | REVIEWED | LEARN-phase `zk_propose_link` (never called) |
| `reinforces` | **0** | REVIEWED | LEARN-phase `zk_propose_link` (never called) |
| `refines` | **0** | REVIEWED | LEARN-phase `zk_propose_link` (never called) |

**The REVIEWED tier is entirely empty.** The Zettelkasten's semantic layer — the one that captures "this refines that", "this contradicts that" — has zero entries after 303 cards' worth of accumulated work.

**The `ref:branches:*` count is 4.** Over 303 cards. Luhmann's Zettelkasten, the thing silmari exists to emulate, was defined by its branching. A silmari store that has branched four times is not branching at all.

### 1.3 The 115 true orphans, by source

All the top orphan buckets are Algorithm runs:

| Source tag | Orphan count |
|---|---|
| `algo-pitchdeck-learn` | 5 |
| `algo-silmari-pitch-learn` | 4 |
| `algorithm-20260418-dual-layer-graph-research-design-learn` | 4 |
| `algorithm-adapt-toc-case-studies-learn` | 4 |
| `algorithm-bv-force-graph-edges-research-learn` | 4 |
| `algorithm-viewer-card-panel-three-zone-redesign-learn` | 4 |
| `algorithm-deploy-cycle-phase-1-2-learn` | 3 |
| `algorithm-populate-positioning-voice-learn` | 3 |
| `algorithm-20260421-cardview-serendipity-redesign-learn` | 2 |
| *(many more, each 1-4)* | |

Algorithm LEARN cards dominate the orphan set. Every completed LEARN run produces N reflection cards (usually 4 — one per reflection question) and all of them are orphans.

---

## 2. The causal chain

This is a single-root-cause defect with a six-step propagation. Each step below cites code with file:line evidence.

### Step 1 — The keywords table does not exist

Direct schema query:

```
$ sqlite3 ~/.silmari-memory/box2-ideas/.beads/beads.db ".schema keywords"
Error: in prepare, no such table: keywords
```

`zk_status.keywords: 0` is not a counter of an empty table. It is the response the code path returns when the table isn't there. The storage substrate for the Layer-1 keyword-entry-point retrieval was never created.

Corroborating: zero `keyword:*` labels in the `labels` table either — keywords aren't stored anywhere.

### Step 2 — `zk_recall` returns structurally empty

`zk_recall` is described in `SAI/Algorithm/v3.8.1.md:30-31` as a three-layer lookup:

> Layer 1: `keyword_entries` — keyword index hits (entry points)
> Layer 2: `folgezettel_neighborhood` — parents / siblings / children of each hit
> Layer 3: `crossrefs` — typed edges walked from each entry

**With no keyword index, Layer 1 returns nothing, so Layers 2 and 3 have nothing to root from.** Every recall query returns:

```json
{"entryPoints":null,"entryCards":[],"neighborhoods":{},"crossRefs":{}}
```

Not `entryPoints: []`. `entryPoints: null` — the code path detects "no index" and returns null; downstream layers short-circuit.

### Step 3 — Algorithm LEARN classifies every reflection as "Novel"

`SAI/Algorithm/v3.8.1.md:64-73` defines 6 classifications:

| Classification | Required action |
|---|---|
| Novel | Save + propose `extends` IF builds on any recalled card |
| Restatement | Save + propose `reinforces` → `zk-XXX` |
| Reinforcement with new angle | Save + propose `reinforces` or `refines` → prior card |
| Contradiction | Save + propose `contradicts` → prior card |
| Supports | Save + propose `supports` → prior card |
| Clean run | No save, no propose |

Every classification except Novel and Clean Run **requires a prior card to link to**. With `zk_recall` returning empty, no prior cards surface in LEARN. The classifier has only two reachable branches:

- Novel (if the reflection has content)
- Clean run (if it doesn't)

And Novel's edge clause is **conditional**: "If the new card builds on or extends ANY other recalled card". Since `recalled` is empty, the conditional is vacuously false. No edge proposed.

### Step 4 — PLACE selects `mode: root`

`SAI/Algorithm/v3.8.1.md:82-95` (Step 2.5 PLACE decision tree):

```
Did RECALL find a specific card this insight branches from?
├── YES → mode: "fork", fromAddress: "{that card's fz address}"
└── NO → Did you just save a sibling card in this LEARN phase?
    ├── YES → mode: "continue"
    └── NO → mode: "root"
```

With empty recall, the first branch is never reachable. The second branch is only reachable for the 2nd-4th sibling save within the same LEARN run. The first save in every LEARN run therefore goes `mode: root`.

In practice, most runs go `mode: root` for *all four* saves because the Algorithm doesn't track the "sibling of previous save in THIS run" state — it evaluates each save independently, and the first-save-of-run is always root, which means the subsequent saves don't see a fork/continue target either. (This is confirmed by the near-zero `branches` count: 4 across 303 cards.)

### Step 5 — Tier A extractors emit NO structural edges for `mode: root`

`apps/silmari-mcp/src/lib/edge-extractors.ts:104-114` `extractFolgezettelParent`:

```typescript
export function extractFolgezettelParent(
  mode: SaveMode,
  parentCardId: string | null,
): EdgeSpec | null {
  if (mode === 'root') return null;          // ← the bailout
  if (parentCardId == null) return null;
  return mode === 'fork'
    ? { type: 'branches', target: parentCardId }
    : { type: 'follows',  target: parentCardId };
}
```

**`mode: root` returns null.** No structural edge. This is correct behavior per spec — a root save has no parent to follow.

`extractSourceReference` at `edge-extractors.ts:122-132` requires `source` to match `/^(?:zk|bl)-[a-z0-9]+$/` (a bead-id). Algorithm source tags look like `algorithm-{slug}-learn` — never bead-ids. So for LEARN saves, this extractor also returns null.

`extractBodyMentions` at `edge-extractors.ts:73-89` scans body text for `zk-*` / `bl-*` patterns. LEARN reflections are abstract — they rarely cite other cards by ID. Most LEARN bodies have zero such mentions.

**Net result: a `mode: root` LEARN save with a non-bead-id source and no body mentions emits ZERO `ref:*` labels.** The Tier A extractors execute, find nothing to emit, and the card lands with its deterministic labels (`content_hash`, `kind`, `box`, `fz`, `trunk`, `source`) but no connective tissue.

### Step 6 — The viewer renders the orphan faithfully

`apps/silmari-memory-card-viewer/server.ts:119` `synthesizeEdgesFromLabels` reads every card's labels, parses `ref:<type>:<target>`, writes rows into the cache sqlite's `card_edges` table. For an orphan card, there are no `ref:*` labels to synthesize, so zero rows are produced.

`apps/silmari-memory-card-viewer/viewer_assets/graph.js` link-builder unions `dependencies` (blocks-only, empty) + `card_edges` (semantic edges). For an orphan card, neither table contributes rows where source == or target == this card.

The force-graph receives a node with no incident links. It renders it as an isolated dot.

**The viewer is operating correctly.** The bug is upstream.

---

## 3. Severity-ranked contributing factors

### F1 — Keyword index substrate never created (CRITICAL, root cause)

Upstream of everything. Fixing this unblocks Steps 2-5.

**Evidence**: `.schema keywords` returns "no such table". `keyword:*` labels: 0. `zk_save_card` never writes to keyword storage (Explore agent confirmed — no import or call from `keyword-index.ts` in the save path).

**Scope**: unclear whether keyword index is supposed to live as a sqlite table, a JSONL file, or label entries. The `zk_keyword_add` tool is documented but rarely invoked (per prior agent findings it writes to `~/.silmari/keyword-index.jsonl`, but that file may not exist on this machine — needs verification as part of the fix task).

### F2 — Algorithm runs default to `mode: root` (CRITICAL, dependent on F1)

With F1 fixed, recall would return hits, and LEARN Step 2.5 PLACE would select `mode: fork` + `fromAddress`. Branches would bloom. Until F1 is fixed, F2 is a forced consequence and not independently fixable.

### F3 — Tier B edges never emitted (HIGH, dependent on F1)

Same dependency chain as F2. The Algorithm spec mandates Tier B edge emission in LEARN (v3.8.1:64-73), and the protocol honors it correctly when recall is empty by marking "Clean run — no edges emitted". But a Zettelkasten with 0 reviewed-tier edges over 303 cards has lost the principal value-add of the LEARN phase. Every insight the Algorithm has had sits in the store as an island.

The audit of 6 recent completed PRDs:
- 3/6 explicitly marked "Clean run — no edges emitted" (protocol-compliant)
- 3/6 never filled the `### Memory cards` section at all (LEARN silently skipped)
- 0/6 emitted any actual Tier B edge

### F4 — Source tags are semantically right but extractor-incompatible (LOW, by design)

Source tags like `algorithm-20260421-cardview-serendipity-redesign-learn` are excellent audit-trail metadata — you can instantly see which run produced a card. But `extractSourceReference` only emits an edge when the source IS a bead-id. Algorithm sources aren't cards. So this extractor does nothing for 65 algorithm-tagged cards.

This is by-design and not a bug. Calling it out because removing it from blame-candidates helps focus the actual fix.

### F5 — Cosmic→silmari migration dropped non-blocks dependency types (BACKGROUND, historical)

The 2026-04-06 migration lost ~360 edges because `beads_rust`'s whitelist rejected every type except `blocks`. Tier C backfill (`apps/silmari-mcp/scripts/backfill-edges-from-cosmic.ts`) restored most (364 edges per prior README). These restored edges ARE the 365 `ref:*` labels we see today. So the store was hydrated correctly from cosmic.

This means F1 (keyword index gap) is **not** caused by the migration; it is a separate gap in the ongoing save path. Cards created after the Tier C backfill have the same F1/F2/F3 problem.

### F6 — `zk_recall` doesn't fall back to alternatives (LOW, design question)

When the keyword index is empty/missing, `zk_recall` could fall back to body text-search (LIKE match), folgezettel-neighborhood scan from a seed, or hub-membership. Instead it returns `entryPoints: null` and the downstream reasoning treats that as "no prior thought exists". This compounds F1's blast radius — a fallback path would make LEARN partially functional even with a blank keyword index.

---

## 4. What this is NOT

Eliminating wrong hypotheses so the fix scope stays tight:

1. **NOT a viewer render bug.** Phases 1-4 (ffbe20d→89e540f) of the split-schema fix landed correctly. `synthesizeEdgesFromLabels` writes to `card_edges`, the JS link-builder unions dependencies + card_edges, the WASM filter is `type === 'blocks'`. The render pipeline is correct. Verified via SQL counts matching screenshot.

2. **NOT a Tier A extractor regression.** `extractBodyMentions`, `extractFolgezettelParent`, `extractSourceReference` in `edge-extractors.ts` work correctly per their specs and test coverage (`edge-extractors.test.ts`). They emit the edges they're supposed to emit; they correctly emit NONE when `mode: root` with non-bead-id source and no body mentions.

3. **NOT a migration problem.** The 2026-04-06 migration gap was closed by the 2026-04-17 Tier C backfill per commit `6218b30` and memory `feedback_silmari_graph_edge_recovery.md`. The 365 `ref:*` labels present in the store are all post-backfill. The problem is with ONGOING saves, not historical.

4. **NOT the "0 edges" problem.** This is a different problem. The 2026-04-17 research solved "graph is empty". The current problem is "graph has edges for the old cosmic-backfilled cards but every new LEARN card is an orphan". The old fix is not the new fix.

5. **NOT a protocol compliance problem.** Algorithm LEARN correctly honors the spec — it correctly records "Clean run — no edges emitted" when recall is empty (3/6 sampled PRDs did this). The spec itself works, but it's been operating on a substrate that makes the edge-emission branches structurally unreachable.

6. **NOT a Tier B-missing-mandate problem.** v3.8.1:58-73 already mandates Tier B edge emission. Adding more mandate doesn't help; the substrate F1 needs to be real before the mandate can fire.

---

## 5. Evidence register (file:line + SQL)

| Evidence | Source | What it shows |
|---|---|---|
| 303 cards, 3118 labels, 365 `ref:*` | `sqlite3 ~/.silmari-memory/box2-ideas/.beads/beads.db` | Baseline — edges exist but thin |
| 115 orphans with zero ref:* | same DB, orphan query | 38% of cards have no connective tissue |
| Ref breakdown: `derives-from:192 / refers-to:106 / follows:63 / branches:4` | same | Tier A is working but minimal |
| 0 reviewed-tier edges | same, type filter | Tier B never emitted, ever |
| `keywords` table missing | `.schema keywords` → error | Substrate doesn't exist |
| 0 `keyword:*` labels | label scan | Keywords aren't stored as labels either |
| `zk_recall` returns `entryPoints: null` | live call | Recall structurally blind |
| `extractFolgezettelParent` returns null for `mode: root` | `edge-extractors.ts:108` | Root saves are edge-free at construction |
| `extractSourceReference` requires `/^(?:zk|bl)-...$/` | `edge-extractors.ts:36, 124` | Algorithm source tags don't match |
| `saveCard` never imports `keyword-index` | `card-ops.ts` entire file | Save path doesn't populate keyword registry |
| 0/6 PRDs emitted Tier B edges | Agent audit of `MEMORY/WORK/*/PRD.md` | LEARN compliance in form not outcome |
| Option B split-schema landed | commits ffbe20d-89e540f | Viewer render is not the bug |
| Tier C backfill restored ~364 edges | README §Graph edges + `backfill-edges-from-cosmic.ts` | Historical hydration worked |
| Orphan source distribution dominated by algo-*-learn | same DB, source bucket query | LEARN is the primary orphan producer |

---

## 6. Next-step fix scope (bounded to one bd task)

**Title**: Bootstrap silmari keyword-index substrate so `zk_recall` returns results

**Hypothesis**: Creating the keyword index — whether as sqlite table, JSONL file, or label convention — with a reasonable initial population is sufficient to unblock the entire Algorithm LEARN edge-emission cascade. Once recall returns even occasional hits, `mode: fork`+`fromAddress` becomes reachable, Tier A emits `branches`, LEARN classifier reaches non-Novel branches, and Tier B edges begin to flow.

**Proposed two-part fix**:

1. **Create the storage.** Decide: sqlite table vs. JSONL file vs. labels. Create migration. Unblock `zk_keyword_add` to actually work. Unblock `zk_recall` to actually return results.

2. **Populate the index with one deterministic pass.** Scan all 303 existing cards. For each card, extract 2-4 terms (title tokens of >=4 chars minus stopwords, plus `kind:*`, plus `trunk:*` labels as high-level entries). Upsert each as a keyword entry pointing to that card's folgezettel address. Result: ~300-900 keyword entries, every card reachable via at least one term.

**Out of scope for the fix task**:
- Retrofitting the 115 existing orphans with edges (they'll stay orphans until they get hand-curated cross-refs or the next run that recalls one of them)
- Adding automatic keyword extraction to `zk_save_card` (future enhancement; the one-pass bootstrap is sufficient to unblock)
- Changing Algorithm spec (no change needed — spec is correct, substrate is missing)
- Redesigning `zk_recall` to fall back when keyword index is sparse (F6 — separate discussion)

**Definition of done**:
- `zk_status.keywords` returns a number >0
- `zk_recall({query: "algorithm"})` returns at least one entry card
- A test LEARN run against a query with known entry points produces at least one `ref:reinforces:*` or `ref:extends:*` label in the labels table
- The orphan count (cards with zero `ref:*`) drops in new cards saved after the fix, measured over a 7-day window

**Rollback**: delete the keyword storage, restore pre-fix state. No data loss (original cards untouched; keyword index is derivative).

**Size**: small-to-medium — ~200 LOC of TypeScript + one migration + one bootstrap script. Fits one TDD plan. Fits one commit.

---

## 7. Open questions

1. **Where should the keyword index live?** Three options: new sqlite table (clean but adds schema surface), JSONL file under `~/.silmari/` (simple, already referenced in prior memory but unverified to exist), label convention `keyword:<term>:<cardId>` (fits existing label infrastructure but polymorphizes labels further). Needs a one-paragraph ADR before the fix starts.

2. **How to handle multi-card terms?** One `keyword:algorithm → zk-abc` or many `keyword:algorithm → {zk-abc, zk-def, zk-ghi}`? Prior memory implies the JSONL has many-to-one — one term points to many cards. Confirm during fix design.

3. **Should `zk_save_card` auto-populate?** Elegant but invasive. Bootstrap-pass-then-manual-zk_keyword_add is a safer first step. Auto-populate is a follow-up task, not a blocker.

4. **Do hubs benefit from the same fix?** `zk_status.hubs: 0` despite 28 `kind:hub` cards — the two-counter gap from `feedback_verify_counters_against_surface_render.md`. Same class of issue — formal registry substrate is empty or missing. Worth confirming whether the hub registry is the same storage problem or separate. Scope boundary: not this task.

5. **Are the 115 existing orphans ever recoverable?** For algorithm LEARN cards, probably not without LLM semantic classification — the reflections are abstract and don't cite each other by ID. For older non-algo orphans, `extractBodyMentions` could be re-run on their bodies after fix — but body mentions of `zk-*` IDs are already handled at save time, so re-running would only help if the extractor regex was upgraded. Low priority.

---

## 8. Cross-references

- **Prior 2026-04-17 research** (`force-graph-edges-workaround.md`): solved "zero edges" via Option B split-schema. Complementary to this doc, not superseded.
- **Prior feedback memory** (`feedback_silmari_graph_edge_recovery.md`): diagnostic command for "graph has 0 edges" (Tier C backfill check). Note on F5: it ran; it helped.
- **Algorithm spec** (`SAI/Algorithm/v3.8.1.md:27-190`): mandates the Tier B edge creation. Protocol itself is correct. The substrate it relies on is missing.
- **Save pipeline** (`apps/silmari-mcp/src/lib/card-ops.ts:454-617` + `edge-extractors.ts` entire file): Tier A extractors working correctly.
- **Viewer render** (`apps/silmari-memory-card-viewer/server.ts:119` + `viewer_assets/graph.js` link-builder): Option B split-schema working correctly.
- **Screenshot**: `/home/maceo/Pictures/Screenshots/2026-04-22_10-02.jpg` — the trigger.

---

*End of investigation.*
