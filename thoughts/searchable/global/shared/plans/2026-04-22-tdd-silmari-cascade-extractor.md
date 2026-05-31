---
date: 2026-04-22
author: Maceo Jourdan (with Silmari)
status: plan
revision: 2 (post-review-REVIEW merge, 2026-04-22)
topic: "Silmari cascade extractor — deterministic gates + haiku/sonnet cascade + hub-scoped reinforces"
tags: [silmari, extraction, zettelkasten, cascade, deterministic-gates, compromise]
reviewed-by: thoughts/searchable/shared/plans/2026-04-22-tdd-silmari-cascade-extractor-REVIEW.md
---

# Silmari cascade extractor — TDD plan

> **Revision 2 note:** all 4 critical + 6 warning findings from the REVIEW
> file above have been folded in. Decisions taken on ambiguous options:
> **C1 → (c) remove L4 auto-fire as part of r04**;
> **C4 → (b) accept single-hop lineOfThought, rename language**;
> **W3 → drop `annotates` from Tier A set** (can be re-added via a
> separate bd issue if an annotator extractor ships later).

Multi-pass transcript → Zettelkasten pipeline. LLMs do the extraction
and typed-edge classification; deterministic steps do the atomicity
gate and the candidate-set enumeration from graph topology (NOT
embeddings — see §5-bis and §6-bis for the no-embeddings commitment
that drove this plan's Level-2 rewrite). Gate B reuses TWO existing
silmari-mcp primitives already shipped by the compounding-substrate
work (`proposeLinksSemantic`, `lineOfThought`) plus TWO NEW primitives
shipped as Step 5.5 of this plan (`hubMembers`,
`filterByKeywordOverlap`) — review C3 discovered the original plan
assumed all four existed. The new primitives are reusable library
additions, not pipeline-local utilities.

## Background

Current pipeline (commit `056f020`, `scripts/kc-baker-pipeline/`):
single-pass LLM extraction, ~10 cards per transcript, body-hash dedup
collapses reruns. Known under-extracts by a factor of 2.5–5× against
the "card = compression" principle.

Two blocking framework fixes already filed:
- `silmari-agent-memory-r04` — saveCard: pivot dedup-return to
  reinforce-and-save (framework invariant)
- `silmari-agent-memory-7h6` — keyword-index: remove `MAX_ENTRY_POINTS`
  cap + FIFO eviction (framework invariant; blocked-by r04)

This cascade plan builds on top of those fixes.

## Invariants this plan honors

1. **Luhmann multiple-storage.** Duplicate bodies in a new context get
   NEW cards + a `reinforces` edge. Never pruned. (Requires r04.)
2. **Keyword entries uncapped.** No `MAX_ENTRY_POINTS`. (Requires 7h6.)
3. **Chain-of-thought scoping.** Similarity scans walk the hub's
   chains, not the whole database. For a person-hub that's O(H²)
   pairs where H = cards in the hub.
4. **Person-hub-centric.** This release targets per-person
   Zettelkastens (KC Baker as the pilot). Enterprise-hub aggregation
   is a later phase — see TODO register.
5. **Deterministic where reproducibility matters; LLM where
   generation matters.** Pre-chunking, atomicity gating, similarity
   scoring: deterministic. Theme labeling, idea extraction,
   micro-claim distillation: LLM.

## Target cascade (revised 2026-04-22 post-review — Gate B → Level 2)

```
[Pass 1]      sonnet OR haiku: label themes    LLM on whole transcript — returns
              in the full transcript                        themes + their text spans
      ↓
[Pass 2]      haiku: extract ideas per theme   fast-cheap LLM — 3–8 ideas each
      ↓
[Pass 3]      haiku|sonnet A/B: sentence-atom  fast-cheap vs smart LLM — 2–5 micros
              decompose each idea                           per idea
      ↓
[Gate A]      compromise + regex:              deterministic — flags compound / unresolved
              flag compound cards, long cards,               pronoun / out-of-spec length cards
              unresolved pronouns
      ↓
[Fix]         sonnet: repair flagged cards     smart LLM — only runs on Gate A flags
      ↓
[Gate B]      Level 2 graph-topology proposer (NO EMBEDDINGS, per no-embeddings memory rule):
              1. deterministic candidate set from (all via composed lib primitives,
                 see §5 + Step 5.5 for the two NEW primitives this plan ships):
                 - keyword-index overlap (≥2 shared keyword-terms)
                   via new filterByKeywordOverlap(sourceCardId, minOverlap=2)
                 - lineOfThought neighborhood — IMMEDIATE parent + siblings +
                   immediate children + hubs + trunk-seeds (SINGLE-HOP — not full
                   ancestor/descendant walk; see §5 note on LINE_OF_THOUGHT_MAX=150
                   recency truncation)
                 - hub membership via new hubMembers(hubId) — all cards attached
                   to the same person-hub
              2. pre-sort candidates by (shared-keyword-count DESC, hub-distance,
                 lineOfThought-proximity) and CAP to 20 before the Sonnet call.
                 MAX_CANDIDATES_IN_PROMPT=20 is a silent truncation in the
                 primitive (semantic-proposer.ts:199); without pre-sort + cap,
                 Sonnet sees an arbitrary subset and typed-edge quality drops.
              3. call proposeLinksSemantic(candidateCardIds, scope: 'explicit')
                 — Sonnet reads BOTH card bodies IN FULL and returns
                 { targetId, edge, confidence, quoted_overlap }. Edge ∈
                 {reinforces, refines, extends, supports, contradicts}.
                 No rationale text — Luhmann-5.
              4. zk_commit_link for each returned proposal above the confidence
                 floor (default 0.7; tune via telemetry)
      ↓
[Ingest]      zk_save_card (forks the tree)   stdio MCP — unchanged tree topology from
              + zk_propose_links_semantic                  the current 4-level fork plan.
              + zk_commit_link                             (Tool name is plural "_semantic" —
                                                            singular zk_propose_link is the
                                                            manual-operator path, not this.)
```

**What we removed and why:**

- **Pre-chunk step (TextTiling/C99) removed.** Without MiniLM, deterministic chunking loses its similarity metric; the remaining options (Jaccard on sentence sets, paragraph-break heuristics) are weaker and add their own fidelity losses. Pass 1 now reads the whole transcript and identifies themes in-context.
- **MiniLM / `@xenova/transformers` removed.** The no-embeddings memory rule (`feedback_zettelkasten_no_embeddings.md`) governs: "the link structure IS information retrieval." Embeddings average user-idiom into English-language priors — exactly the collapse §8 forbids.
- **Threshold calibration + FDO hand-label UI for MiniLM removed.** No threshold exists to calibrate.
- **`threshold.json` removed** — the decision in old-§10 is moot; no file to locate.

**What we gained:**

- Candidate enumeration uses the user's OWN curation signals (keywords they added, hubs they placed cards into, folgezettel positions they chose) — zero English-language priors in the path.
- Classification uses `proposeLinksSemantic` (already-shipped Phase 3 infrastructure) — Sonnet reads bodies in full; no 384-dim compression.
- Typed edges (`reinforces`/`refines`/`extends`/`supports`/`contradicts`) instead of only undirected similarity. Graph carries more information per edge.
- Infrastructure reuse: ~1000 LOC of existing silmari-mcp code (semantic-proposer, line-of-thought, keyword-index) instead of a parallel MiniLM pipeline.

## Folgezettel tree shape (per video)

```
trunk N thesis              mode:root       fz=N/K
  │
  ├─ theme 1                mode:fork       fz=N/Ka
  │   ├─ idea 1-1           mode:fork       fz=N/Ka1
  │   │   ├─ micro 1-1-1    mode:fork       fz=N/Ka1a
  │   │   ├─ micro 1-1-2    mode:continue   fz=N/Ka1b
  │   │   └─ micro 1-1-3    mode:continue   fz=N/Ka1c
  │   ├─ idea 1-2           mode:continue   fz=N/Ka2
  │   │   ├─ micro 1-2-1    mode:fork       fz=N/Ka2a
  │   │   └─ micro 1-2-2    mode:continue   fz=N/Ka2b
  │   └─ idea 1-3           mode:continue   fz=N/Ka3
  │       └─ micro 1-3-1    mode:fork       fz=N/Ka3a
  ├─ theme 2                mode:continue   fz=N/Kb
  │   └─ ...
  └─ theme 3                mode:continue   fz=N/Kc
      └─ ...
```

Expected density: ~8 themes × 5 ideas × 3 micros = **120 cards/video**.
For KC Baker's 15-transcript playlist: ~1800 cards total. The
`silmari-agent-memory-7h6` fix (uncap keywords) is a hard prerequisite
— without it, a term like `voice` would evict 99% of its entry points.

## Deliverables

### 1. `scripts/kc-baker-pipeline-v2/` — cascade pipeline (Level 2)

New dir alongside the v1 thin-slice. Keeps the v1 available for
regression comparison.

```
scripts/kc-baker-pipeline-v2/
├── Dockerfile              ~35 LOC — bun-slim + compromise (~2 MB); no Python
├── docker-compose.yml      ~50 LOC — bind-mounts unchanged from v1
├── package.json            @modelcontextprotocol/sdk, compromise (NEW dep —
│                           not currently in any repo package.json)
├── extract/
│   ├── pass1-themes.ts     ~150 LOC — sonnet: full-transcript theme labeling
│   ├── pass2-ideas.ts      ~160 LOC — haiku: extract ideas per theme
│   ├── pass3-micros.ts     ~180 LOC — haiku|sonnet A/B: sentence-atom decompose
│   └── prompts/            versioned prompt files (*.md) for reproducibility
├── gates/
│   ├── atomicity.ts        ~180 LOC — compromise POS + regex atomicity checks
│   ├── graph-candidates.ts ~280 LOC — candidate enumeration. Calls the TWO NEW
│   │                                  silmari-mcp primitives shipped in Step 5.5
│   │                                  (filterByKeywordOverlap, hubMembers) PLUS
│   │                                  existing lineOfThought. Includes pre-sort +
│   │                                  cap-at-20 logic before proposeLinksSemantic.
│   │                                  (+80 LOC over v1 estimate because three
│   │                                  "primitives" claimed in v1 don't exist —
│   │                                  review C3.)
│   └── fix-flagged.ts      ~140 LOC — sonnet: repair Gate A flags
├── ingest/
│   └── ingest-cascade.ts   ~280 LOC — MCP stdio client; walks tree bottom-up;
│                                      emits typed edges via proposeLinksSemantic +
│                                      zk_commit_link for each returned proposal
├── review/                 (Step 7 — optional MVP component)
│   ├── proposal-review-ui.ts  ~220 LOC — Bun HTTP server showing Gate B's
│   └── proposal-review-ui.html ~180 LOC — typed-edge proposals for human accept/reject
├── run.sh                  ~40 LOC — orchestrator with resume flags
└── README.md               ~120 LOC — quick start + each gate's contract
```

**Estimated total:** ~1990 LOC across ~12 files (up +80 LOC from the
pre-review estimate of 1900, because the three "existing primitives"
v1 assumed for candidate enumeration turned out to be two missing
primitives + one narrower-than-expected primitive — see §5 Step 5.5
for the mitigation).

Still a net reduction from the pre-Level-2 estimate (2100 LOC). One
new dep (`compromise`). Image ~300 MB.

### 2. Test fixtures

`scripts/kc-baker-pipeline-v2/tests/`:
- one canonical small transcript (`kc_bakers_words_of_wisdom.txt` — 113s, the smallest)
- golden JSON for pass 1/2/3 output (LLM-produced once, committed, used as a shape-not-content check on reruns — dedup between LLM stochasticity and true regression)
- synthetic compound card for Gate A (multi-verb, unresolved pronoun, over-long)
- synthetic similar-pair for Gate B

### 3. Keyword-and-hub seeding

Unchanged from v1 — the per-video hub attachment + `source:<slug>` +
per-card keyword fan-out stays. The v2 pipeline emits ~15× more
keyword-add calls; `silmari-agent-memory-7h6` fix prevents eviction.

## §4. FDO proposal review UI (revised post-review 2026-04-22)

The original plan had an FDO *calibration* UI whose job was to tune a
MiniLM similarity threshold. Level 2 Gate B has no such threshold —
so the UI's purpose changes. It's now an optional post-run *proposal
review* surface.

**Target user:** Forward-Deployed Operator. Goal: inspect the typed-
edge proposals Gate B produced and approve/reject per pair. Approval
triggers `zk_commit_link`; rejection drops the proposal.

**Flow:**
1. Pipeline run finishes; Gate B has emitted N typed-edge proposals stored as a flat JSON log
2. Operator runs `bun run review/proposal-review-ui.ts`
3. Server renders pairs grouped by edge type (reinforces / refines / extends / supports / contradicts) with the full body of each card + Sonnet's `quoted_overlap` highlighted
4. Operator accepts/rejects per proposal; accepted proposals fire `zk_commit_link`

**MVP decision:** Step 7 is *optional* for the first cascade release.
If Gate B's confidence scores are high enough (say top 50% of
proposals all score 0.8+) we can auto-commit above a confidence
floor and only surface the borderline pairs through the UI. The
first run on the KC Baker corpus tells us whether the UI is needed
immediately or can be deferred.

**Tradeoffs:**
- Auto-commit-above-floor is the "Silmari trusts Sonnet" default —
  fits the proposeLinksSemantic contract (structured output, no
  rationale from LLM, confidence per proposal).
- UI-for-all-proposals is the "human-in-loop for every typed edge"
  stance — safer for contradicts edges specifically, which are high-
  value and rare.
- Likely sweet spot: auto-commit reinforces/supports above 0.7,
  route refines/extends/contradicts through UI always.

## §5-bis. Pre-chunking — ELIMINATED (revised post-review 2026-04-22)

The original plan had a deterministic pre-chunk pass (TextTiling)
that used embeddings on sliding sentence windows. After removing
MiniLM per the no-embeddings rule, every remaining chunker option
was worse than letting Pass 1 do theme identification in full
context.

**Decision: no Pass 0.** Pass 1 reads the whole transcript and
returns themes with their text spans. Cost: more tokens per Pass 1
call (one 18 KB transcript instead of eight 2 KB chunks), but
simpler pipeline + higher-fidelity theme boundaries because the
LLM sees the full arc.

**Implication for Pass 1 model choice:** reading a 20-25 KB transcript
for theme labeling is near the edge of haiku's practical window for
coherent output. **Pass 1 uses sonnet**, not haiku. Passes 2 and 3
stay on the haiku/sonnet A/B path (Pass 3 is the A/B; Pass 2
defaults to haiku).

## §5. Deterministic-step runtime — DECIDED: pure-Bun, no embeddings (revised 2026-04-22)

Runtime: **pure-Bun**, single-container. No Python. No subprocess.
No embeddings / vector cache anywhere.

- **Pre-chunk:** ELIMINATED — see §5-bis.
- **Atomicity gate (Gate A):** `compromise` (npm, ~2 MB) for POS
  tagging + coordinating-conjunction detection, plus a few regex
  rules for pronoun-subject and length-range checks.
  **`compromise` is a NEW dependency** — not present in any existing
  package.json in the monorepo today; Step 5 Dockerfile + pipeline
  package.json add it.
- **Gate B candidate enumeration:** pure topology, no embeddings.
  Calls THREE silmari-mcp primitives — one existing (lineOfThought)
  and TWO NEW ones that ship in Step 5.5 because the plan's original
  assumption that they already existed was wrong (review C3):
  - **EXISTING: `lineOfThought(cardId)`** at
    `apps/silmari-mcp/src/lib/line-of-thought.ts:191-238`. Returns
    IMMEDIATE parent + same-depth siblings + IMMEDIATE children + hubs
    (seed derives-from) + trunk-seeds. **Not a multi-hop ancestor or
    descendant walk** — single-hop only. Also silently truncates the
    union to `LINE_OF_THOUGHT_MAX = 150` sorted by recency
    (`created_at DESC`), so at cascade density (120 cards/video) older
    structurally-adjacent cards get pushed out by newer ones once a
    hub exceeds 150. Telemetry item 5 surfaces this truncation
    (`lineOfThought-truncated: bool` per candidate set).
  - **NEW (Step 5.5): `hubMembers(hubId)`** — returns every card
    attached to a given hub. Today this has no dedicated library
    function; callers would have to compose via a raw
    `brList -l hub-id:<hubId>` query. Shipping it as a first-class
    primitive in `apps/silmari-mcp/src/lib/keyword-index.ts` (or a
    new `hub.ts` file — bikeshed in the Step 5.5 PRD).
  - **NEW (Step 5.5): `filterByKeywordOverlap(sourceCardId, minOverlap=2)`**
    — given a source card, returns every other card sharing ≥N
    keyword terms with it. Today this requires caller-side composition
    (enumerate source's terms → for each term call `lookupKeyword` →
    build per-candidate counter → filter ≥2). Moving it into
    keyword-index.ts removes ~60-80 LOC of duplication from every
    future caller.
  Union the three sets, dedup, pre-sort, CAP AT 20 (see point 2 in
  the §5 Gate B diagram above), emit the candidate list.
- **Gate B classification:** call
  `proposeLinksSemantic({ newCardId, candidateCardIds, scope: 'explicit', maxProposals })`
  from `apps/silmari-mcp/src/lib/semantic-proposer.ts` — Sonnet reads
  bodies in full; returns typed-edge proposals with confidence scores;
  LLM never writes rationale (Luhmann-5 already enforced inside the
  primitive). The primitive has a hard internal cap of
  `MAX_CANDIDATES_IN_PROMPT = 20` (semantic-proposer.ts:199) — callers
  exceeding it get silent truncation. Gate B's pre-sort-and-cap
  mitigates this (diagram point 2).
- **Gate B error handling:** `proposeLinksSemantic` never throws —
  returns `{ ok: false, error }` on LLM unavailable, unparseable JSON,
  or invalid newCardId. Cascade treats `ok:false` as "skip this
  card's Gate B pass" (logs the error to the PRD `## Decisions`
  section; does NOT fail the run). Gate B is best-effort by design —
  its absence means reduced typed-edge density, not broken cards.

No new npm deps beyond `compromise`. Image footprint ~300 MB.

## Prerequisite ordering

**Hard gate:** Steps 0 and 1 each get their OWN TDD plans before any
cascade step begins. Both are public-API breaking changes to the
silmari-mcp surface, not drop-in edits — the cascade plan captures
the MOTIVATION (§8, framework invariants) but not the implementation
strategy, test-rewrite scope, or migration path. Step 1.5 (API audit)
is mechanical but required — every caller of `wasDeduped` or
`AddKeywordResult.kind` needs a rewrite path cataloged before code
changes.

| # | What | Why | Estimated effort |
|---|------|-----|------------------|
| 0 | `silmari-agent-memory-r04` — saveCard dedup → reinforce | Without this, reruns silently collapse instead of reinforcing; the whole point of Gate B is moot. **TDD plan: [2026-04-22-r04-tdd-savecard-dedup-to-reinforce.md](./2026-04-22-r04-tdd-savecard-dedup-to-reinforce.md)** (611 lines, 8 Observable Behaviors, 6 TDD cycles). Scope (revised post-review 2026-04-22): (a) `saveCard` rewrite with new return contract `{id, fz, wasReinforced, priorId, wasSweepDeleted}`; (b) `sweepDuplicates` under-concurrent-writes redesign (today it deletes the loser of a dedup race — under r04 both survive, one emits reinforces to the other, AND BOTH carry a `needs-consolidation-review:true` label for later human review — the "sleep consolidation" pattern locked 2026-04-22, see `## Decisions locked`. Non-trivial concurrency logic plus the review-flag writes); (c) rewrite of **6 test assertions** on `wasDeduped` across integration.test.ts (lines 289/514/580), biblio-related tests, and migrate-from-cosmic.ts conditionals (lines 417/426) — NOT the "62+" originally estimated (review W2 verified actual count); (d) update the **2 external consumers** of SaveCardResult.wasDeduped: biblio.ts:120 and migrate-from-cosmic.ts; (e) ordering relative to Tier A edge extraction — **Tier A runs AFTER `brCreate`, not before** (review C2 verified against card-ops.ts:612-696); reinforces fires after Tier A, still within saveCard's return path; (f) **remove L4 auto-fire from card-ops.ts:773-806** (review C1 option c) — the `proposeLinksSemanticSync` auto-invocation + auto-commit is a stopgap from Phase 3 that collides with Gate B as a duplicate classifier; L4 becomes a pure anchor check ("card has ≥1 ref:* edge?") without the auto-commit side effect. | ~4–5 hours (Advanced; test-rewrite mechanical portion is ~30 min, sweepDuplicates redesign + L4 removal is the substance) |
| 1 | `silmari-agent-memory-7h6` — remove MAX_ENTRY_POINTS cap | Without this, keyword routing fails at the density the cascade produces. **TDD plan: [2026-04-22-7h6-tdd-keyword-index-uncap.md](./2026-04-22-7h6-tdd-keyword-index-uncap.md)** (430 lines, 7 Observable Behaviors, contains the mandatory "FIFO-as-design → FIFO-wrong-at-cascade-density" refutation). Scope: (a) `MAX_ENTRY_POINTS` deletion + `addKeywordEntry` simplification (the FIFO eviction at keyword-index.ts:368-379 is documented as an intentional design choice today — 7h6's TDD plan must explicitly argue why it's the wrong trade-off at cascade density, not just strip it); (b) `AddKeywordResult` discriminated-union reduction — remove `rejected-full` and `replaced` variants, making it effectively 2-case (`added` \| `already-present`); (c) **public API v2 versioning** because tests + any external caller branching on `.kind === 'replaced'` will break; (d) tests for "index 50+ entries under one term"; (e) MCP tool description update at `index.ts:251` removing the `MAX_ENTRY_POINTS=4` claim | ~3–4 hours (Advanced) |
| 1.5 | **API-compatibility audit** — grep every callsite of `wasDeduped`, `AddKeywordResult.kind`, `rejected-full`, `replaced` across `apps/`, `scripts/`, `tests/`, `thoughts/`. Produce a spreadsheet of files × change-type × migration-path. Much smaller than originally feared (review W2: total external consumers of `wasDeduped` is 2, test assertions is 6) — keep the audit because the `.kind` path may still have untracked callers, but expect the spreadsheet to be short. | Catches surprises hiding in test fixtures, snapshot files, and the viewer's schema assumptions | ~1 hour (was ~2; scoped down by review W2) |
| ~~2~~ | ~~Existing-corpus migration decision~~ | **RESOLVED 2026-04-22:** deferred to post-cascade research-first migration (see §9). No longer a cascade prerequisite. | — |
| 3 | Pass 1 on one transcript | Sonnet reads full transcript → theme spans. Establishes the whole-transcript-in-context approach | ~2 hours |
| 4a | Pass 2 on same transcript | Theme → ideas extraction with haiku; 2–3 prompt iterations | ~3 hours |
| 4b | Pass 3 A/B: haiku vs sonnet on same transcript | Sentence-atom is the hardest prompt. Run BOTH models on the same Pass-2 output, diff the micro-card counts + qualities side-by-side, pick the model that best honors the compression principle. Record the decision + sample diffs in the PRD. | ~4 hours |
| 5 | Gate A + Fix | Deterministic compromise+regex gate + sonnet repair | ~3 hours |
| 5.5 | **NEW silmari-mcp primitives** (`silmari-agent-memory-f23`, P1, added post-review C3). **TDD plan: [2026-04-22-step5.5-tdd-silmari-mcp-primitives.md](./2026-04-22-step5.5-tdd-silmari-mcp-primitives.md)** (437 lines, 5 Observable Behaviors, file-placement recommendation: `filterByKeywordOverlap` in `keyword-index.ts`, `hubMembers` in NEW `hub.ts`). Ships `hubMembers(hubId)` and `filterByKeywordOverlap(sourceCardId, minOverlap=2)` — both are needed by Gate B and don't exist today despite the original plan assuming they did. Reusable primitives, not pipeline-local utilities. Asymmetric error handling: hub missing→`[]`, source missing→throw. 50ms perf gate. | Plug the missing-primitive gap that review C3 caught | ~1.5 hours |
| 6 | Gate B + ingest | **Level 2**: compose `lineOfThought` (existing) + the two Step-5.5 primitives (new); pre-sort + cap candidates at 20; call `proposeLinksSemantic({scope:'explicit'})`; commit typed edges above confidence 0.7. Requires r04 + 7h6 + 5.5 landed. See §6-bis for edge-write ordering. | ~3 hours |
| 6.5 | **`zk_recall` limit parameter** — per-term limit on returned entry points | Cascade produces terms with 100+ entry points immediately. Without a limit, every recall on popular terms returns bloated payloads. Sub-spec (added post-review W6): `{limitPerTerm: number (default 20), sortBy: 'recency' \| 'reinforces-density' (default 'reinforces-density'), truncatedIndicator: bool in response}`. Truncation must be visible to callers — don't silently drop. Promoted from follow-up because it's a hard dependency for usability. | ~1.5 hours |
| 7 | FDO proposal review UI (was: calibration UI) | Post-run HTTP + HTML form showing the typed-edge proposals Gate B produced, with accept/reject for each. Not similarity calibration — proposal-level approval. Optional for MVP. | ~3 hours |
| 8 | Full-playlist rerun + eval | Compare v2 output to v1 on the 15-transcript KC Baker corpus. Includes telemetry per §11 | ~1.5 hours |

**Revised total (post-review 2026-04-22): ~29 hours of focused work**
(r04 drops 3 hrs via W2 scope recalibration; Step 5.5 adds 1.5 hrs;
Step 1.5 drops 1 hr; net movement -2.5 hrs, but offset by added L4
auto-fire removal work inside r04 and the new primitive work in 5.5).
Spread across multiple Algorithm runs. Each step 3–8 is its own
session with OBSERVE → LEARN. Steps 0, 1, and 5.5 each ship with
their own TDD plan document BEFORE any implementation starts —
these are public-API changes to silmari-mcp and the cascade plan
captures motivation, not the implementation strategy.

- Step 4b is the single step most likely to produce a decision that
  propagates back — the Pass-3 model choice affects cost, latency,
  and card-quality variance across the whole cascade.
- Step 2 (existing-corpus migration decision) may REDUCE total work
  if we choose forward-only (no retroactive reinforces scan), or add
  a Step 8.5 (~3 hours) if we choose retroactive.

### Step 4b — A/B methodology

For the chosen canary transcript, after Pass 2 is locked:

1. Save Pass 2 output to `ideas.json` (shared input for both arms)
2. Run `pass3-micros.ts --model haiku --out micros.haiku.json`
3. Run `pass3-micros.ts --model sonnet --out micros.sonnet.json`
4. Compute three diffs:
   - **count:** micro-cards per idea — which model produces more atomic
     decomposition (more ≠ always better, but the compression target
     is 2–5 micros per idea; watch for runaway counts)
   - **length:** median body length per micro — sonnet tends to be
     more verbose; if its micros exceed 80 words the compression
     principle is violated
   - **self-containment:** spot-check 10 random micros from each arm
     for unresolved pronouns and missing referents
5. Pick one model as default; record the losing model + diff stats in
   the step PRD's `## Decisions` so future "why haiku?" questions have
   an auditable answer
6. Leave `pass3-micros.ts --model {haiku|sonnet}` configurable so the
   A/B can be re-run on a different corpus later

## Architecture diagrams

### Data flow per transcript

```
transcript.txt (18-25 KB — full transcript, no pre-chunk; §5-bis)
   │
   │  Pass 1 (sonnet — whole transcript in context)
   ▼
themes.json     [ {theme_idx, theme_title, theme_summary, text_span}, × ~8 ]
   │
   │  Pass 2 per theme (haiku)
   ▼
ideas.json      [ {theme_idx, idea_title, idea_body, source_span},
                  × ~5 per theme = ~40 total ]
   │
   │  Pass 3 per idea (haiku|sonnet A/B — see Step 4b)
   ▼
micros.json     [ {idea_idx, micro_title, micro_body, source_sentence},
                  × ~3 per idea = ~120 total ]
   │
   │  Gate A (compromise + regex)
   ▼
flagged.json    [ {micro_idx, issues:[compound|unresolved-ref|length]},
                  × ~0.25 of micros = ~30 ]
   │
   │  Fix (sonnet)
   ▼
micros.v2.json  [ repaired; same shape as micros.json ]
   │
   │  ingest via zk_save_card (writes cards + Tier A edges +
   │   saveCard step-4 reinforces edges on body-hash match)
   ▼
Silmari store (partial)  +1 thesis, +8 themes, +40 ideas, +120 micros,
                         + N body-hash reinforces edges
   │
   │  Gate B post-transcript pass (Level 2: graph-candidates.ts →
   │   proposeLinksSemantic, NO EMBEDDINGS, NO THRESHOLD FILE)
   ▼
proposals.json  [ {sourceCardId, targetCardId, edge:<5 types>,
                   confidence, quoted_overlap},
                  above confidence 0.7 ]
   │
   │  zk_commit_link per proposal (+ optional FDO review UI Step 7)
   ▼
Silmari store (final)   + M typed edges {reinforces, refines, extends,
                        supports, contradicts} emitted by Gate B
```

### Dependency graph

```
     r04 ─────┬──▶ Gate B (emits reinforces via saveCard step-4 path)
              │
              └──▶ L4 auto-fire removal (so Gate B is the single
                   authoritative Sonnet classifier — see review C1)

     7h6 ───────▶ keyword fan-out at scale (uncap entry points)

     5.5 ───────▶ hubMembers + filterByKeywordOverlap primitives
                  ──▶ graph-candidates.ts in Gate B

     6.5 ───────▶ zk_recall per-term limit ──▶ usable recall at
                  post-cascade density

     §5 decision ──▶ Dockerfile ──▶ every gate file
     (no threshold.json — eliminated in §10; Gate B's only tunable
     is the keyword-overlap integer, default=2, lives in code)
```

## §6-bis. Edge-write ordering (Tier A, reinforces, Gate B) — revised for Level 2 + post-review 2026-04-22

**Correction (review C2):** The pre-revision version of this section
said Tier A edges write "synchronously before brCreate returns" and
"atomically with the card." That was factually wrong — verified
against `card-ops.ts:612-696`, Tier A runs AFTER brCreate succeeds.
The sequence below reflects the actual code and what r04 must
preserve.

Three classes of edges get written per card, in strict sequence:

```
1. saveCard() begins
     ↓
2. brCreate commits the card to beads_rust with content_hash +
   initial metadata labels. Card is NOW visible to concurrent readers.
     ↓
3. runExtractors writes Tier A ref:<type>:<targetId> labels onto the
   just-committed bead via brLabelAdd. Tier A edge types TODAY:
   - follows       (continue-mode folgezettel)
   - branches      (fork-mode folgezettel)
   - refers-to     (body-mention regex → bead id)
   - derives-from  (explicit source param is a bead id)
   NOT `annotates` — the `annotates` extractor does NOT exist in
   runExtractors today (review W3); the type is in the label enum
   but no code writes it. If an extractor for `annotates` ships
   later (e.g. `@mentions` → annotates(target)), file a separate
   bd issue and add it here.
   Tier A is synchronous within saveCard's return path but NOT
   atomic with brCreate — there's a few-ms window where the card
   exists without any ref:* labels. Concurrent readers must tolerate
   this window (Gate B queries happen long after, so it doesn't
   affect cascade flow; but r04's sweepDuplicates redesign must not
   assume Tier A is already present at the moment a race resolves).
     ↓
4. Reinforces edge (if body-hash matched a prior card) written
   immediately after runExtractors returns, still inside saveCard.
   This is the r04 pivot — body-hash match is now a recurrence
   signal, not a dedup signal. Emits `reinforces` from new → prior.
     ↓
5. saveCard returns { id, fz, wasReinforced, priorId, wasSweepDeleted }
   (renamed fields from the pre-r04 contract — see §0 prerequisite
   r04 row (a) for the full new shape).
     ↓
6. ...much later, after the whole cascade finishes for a transcript,
   Gate B runs:
     a. Deterministic candidate enumeration per new card
        (lineOfThought + hubMembers + filterByKeywordOverlap — the
        two Step-5.5 primitives plus the existing line-of-thought)
     b. pre-sort candidates by shared-keyword count + hub-distance;
        cap to 20 (proposeLinksSemantic's silent internal limit)
     c. proposeLinksSemantic({candidateCardIds, scope:'explicit'})
        — Sonnet reads bodies in full, returns typed-edge proposals
        with confidence scores
     d. filter returned proposals to confidence ≥ 0.7 (default floor)
     e. zk_commit_link per surviving proposal — writes the typed
        edge to the store
```

**L4 anchor-invariant — resolution (review C1, option c):** Today,
when saveCard detects the committed card has zero `ref:*` edges, it
auto-invokes `proposeLinksSemanticSync` at card-ops.ts:773-806 and
auto-commits the top proposal above `SILMARI_TIER_B_CONFIDENCE_THRESHOLD`.
**r04 MUST remove this auto-commit side effect.** The cascade's Gate B
(step 6 above) is the single authoritative Sonnet-classified edge
source. L4 after r04 becomes a pure check ("does this card have any
ref:* edge?") logged to the save-result telemetry for monitoring,
without initiating any LLM call or writing any edge.

Why this cleanup matters:
- Without it, every cascade micro-card save that happens to have
  no Tier A edge (rare but possible for anchor cards without a
  source reference + no folgezettel parent yet) would trigger a
  synchronous Sonnet call inside saveCard — massive latency cost
  per save.
- Telemetry item 6 (§11) wouldn't be able to attribute emitted
  edges to either L4-auto-fire or the explicit Gate B pass,
  destroying the diagnostic value of the per-edge-type
  distribution.
- Two distinct code paths classifying the same cards with the
  same LLM is structural duplication — pick one, and Gate B is
  the cleaner (batch-oriented, post-transcript, explicit scope).

**If Gate B fails** (proposeLinksSemantic errors, Sonnet unavailable,
network drop): the cascade MUST still return a valid store. Gate B
is best-effort. Its absence means reduced typed-edge density across
the hub, not broken cards. Codify this in Gate B's error handling —
failures get logged to the PRD's Decisions section, cascade
continues to subsequent passes.

**Distinction between step 4 (reinforces in saveCard) and step 6
(Gate B typed edges):**
- Step 4 fires on body-hash IDENTICAL match. One edge, always
  `reinforces`, always from the new card to its hash-twin. Fast,
  deterministic, happens inline per save.
- Step 6 fires on SEMANTIC candidate pairs (shared keywords + shared
  neighborhood + shared hub). Multiple edges possible, each typed by
  Sonnet's classification — could be `reinforces` OR `refines` OR
  `extends` OR `supports` OR `contradicts`. Slower, batched post-
  transcript, emits richer edge types.

## §9. Existing-corpus migration policy — DECIDED 2026-04-22: Option D (defer + research-first)

The current `~/.silmari-memory` has 310+ cards accumulated from
Algorithm LEARN runs, v1 pipeline ingests, and manual saves. After
r04 lands, new saves reinforce against prior bodies — but the
existing 310 cards have zero reinforces edges among themselves.

**Decision 2026-04-22 (Maceo): Option D — defer + research-first
migration.** Ship the cascade without touching the 310 existing
cards. Once r04 + 7h6 + 5.5 + cascade Steps 3-6 have all landed
and the cascade is emitting typed edges on NEW saves, stand up a
SEPARATE research-first migration work item:

1. Read the 310 pre-existing card bodies in full (not just
   candidate-enumerate from keyword overlap — actually RESEARCH
   the content).
2. Use the research to find conceptual connections beyond what
   keyword-overlap + lineOfThought + hub-membership would
   produce from a blind Gate B pass.
3. Emit typed edges informed by the research — with provenance
   labels so these migration-era edges are distinguishable from
   cascade-emitted edges, and reversible en masse.

This is explicitly NOT part of the cascade release. File as a
new bd issue (tentative: `silmari-agent-memory-*-retro-research`)
when we're ready to start the research phase.

### Options considered and rejected

**A — Forward-only.** Gate B only runs on cards added AFTER the
cascade ships. Existing 310 cards remain as-is. Rejected: leaves
a permanent discontinuity in the graph at the "cascade shipped"
timestamp.

**B — One-shot retroactive Gate B pass.** Run the Level-2
candidate enumeration + `proposeLinksSemantic` over the 310
existing cards. Rejected in favor of D: Gate B is a narrow
keyword-overlap + neighborhood classifier; running it blindly over
310 cards would under-emit on pairs that have conceptual overlap
but different keyword vocabularies. Research-first catches those.

**C — Opportunistic.** Each new save re-scans pre-existing cards
in the same hub. Rejected: slow convergence + coupling between
cascade saves and migration work we haven't scoped yet.

### Why "defer + research"

- Cascade release ships faster (no migration work in its critical
  path)
- We see the Gate B output on NEW saves first, learn what Gate B
  does well/poorly, then apply richer research to the existing
  corpus with that lesson in hand
- The 310 cards include manual Algorithm LEARN saves with
  hand-curated keywords — Gate B would see high overlap and likely
  over-classify; a research pass can distinguish "same term, same
  claim" from "same term, different claim"

## §10. `threshold.json` — ELIMINATED (revised post-review 2026-04-22)

Moot. Level 2 Gate B has no similarity threshold to store; candidate
enumeration is deterministic (keyword-count ≥ 2) and classification
is LLM (`proposeLinksSemantic` returns confidence per proposal —
that's a per-edge score, not a corpus-level threshold).

The only tunable parameter the cascade introduces is the **keyword-
overlap threshold** (default: 2 shared terms). If we later want to
tune this per-hub, the same decision structure applies — disk vs.
Silmari-card — but this is a much simpler parameter (one integer)
and can be deferred until we actually have evidence the global
default is wrong.

**Replacement TODO:** if per-hub keyword-overlap tuning proves
necessary, file a follow-up bd issue. Today: global default = 2.

## §11. Telemetry for framework invariants (revised for Level 2 + Revision 2)

After r04 + 7h6 + 5.5 land, we need measurable signals that the
pivots actually took effect. Add the following metrics to the
cascade's per-run summary (written to the PRD `## Verification`
section):

1. **Reinforces edge count per cascade run** (saveCard step-4 path).
   - Before r04: expected ~0 (reinforces only emitted via
     proposeLinksSemantic auto-fire at L4 or manual
     `zk_propose_link`, both of which emit other edge types too —
     pre-r04 baseline is noisy)
   - After r04, v1 pipeline rerun: expected ~10 per rerun on one
     KC Baker transcript (one per atomic idea that body-hash matched)
   - After r04 + cascade v2 rerun: expected 100–300 per full
     playlist rerun

2. **`wasReinforced:true` return rate** on cascade saves (new r04
   contract field — see §6-bis step 5).
   - Rerunning same transcript: approaches 100% on second run.

3. **Keyword fan-in distribution** — histogram of entry-points per
   term.
   - Before 7h6: hard ceiling at 4 (the current FIFO-evicting cap).
   - After 7h6: distribution shaped by natural term density. 7h6's
     TDD plan must make the case for uncapping explicit — the
     existing cap is documented as an intentional design choice at
     `keyword-index.ts:287-291`, not a bug. The reframing is: at
     cascade density (120 cards/video × 15 videos) the cap causes
     >99% of entry points for popular terms to be evicted, which
     is a different failure mode than the small-corpus scenario
     the original cap was designed around.
   - Expected after cascade v2 full playlist: a few terms (e.g.
     `voice`, `fear`, `shame`) at 50–200 entry points; long tail
     of one-offs.

4. **Gate A flag rate.** % of Pass-3 micros flagged for repair.
   - Acceptance: 10–40%. Outside this range = prompt drift.

5. **Gate B candidate set size distribution.** Per new card, track:
   - **pre-cap count:** how many candidates did the enumeration
     (filterByKeywordOverlap ≥ 2 ∪ lineOfThought ∪ hubMembers)
     produce, before pre-sort-and-cap?
   - **post-cap count:** how many survived the MAX_CANDIDATES_IN_PROMPT=20
     cap and actually went to Sonnet?
   - **lineOfThought-truncated:** bool — did `lineOfThought` hit
     its `LINE_OF_THOUGHT_MAX = 150` recency-sort truncation for
     this card? (If this is frequently true, structurally-adjacent
     older siblings are being dropped — flag for investigation.)
   - Expected pre-cap median: 10–40 candidates per card in a
     populated hub.
   - Pre-cap tail at 0 = card has no shared keywords + empty
     folgezettel neighborhood (common for early-hub thesis cards).
   - Pre-cap tail above 100 = popular over-connected card; spot-
     check the enumeration logic (and the cap-at-20 means the
     ≥100-candidate cards lose diversity — consider bumping
     maxProposals inside proposeLinksSemantic for those).

6. **Gate B typed-edge emission** — count per edge type, attributed
   to origin.
   - Origin field: `gateB-explicit` (the post-transcript Gate B
     pass) vs `r04-reinforce` (the body-hash match path in
     saveCard step 4). Post-r04 there is NO `L4-auto-fire` origin
     because L4 auto-commit is removed in the same r04 patch
     (review C1 option c); if this count is non-zero, the removal
     was incomplete.
   - Expected `gateB-explicit` distribution for a talk-heavy
     person-hub: `reinforces` ≈ 40–60%, `extends`/`refines` ≈
     30–40%, `supports` ≈ 5–10%, `contradicts` ≈ 0–2%.
   - The distribution itself is a signal — a hub with zero
     `contradicts` may legitimately have none, OR may mean
     Sonnet's prompt is biased toward agreement-edges; spot-check.

7. **Sonnet spend breakdown.** Four places Sonnet runs: Pass 1
   (theme labeling), optional Pass 3 A/B arm, Gate A repair, and
   Gate B classification. Report wall-time + call-count per origin.
   - Total Sonnet calls per playlist: rough projection ~15 (Pass 1) +
     ~150 (Gate A repairs) + ~1000 (Gate B classifications) = ~1165.
   - If Gate B dominates (which it will), subsampling candidates
     per card is the lever — see §12.
   - Note: L4 auto-fire is GONE after r04 (review C1 option c), so
     the pre-revision "L4 Sonnet calls" line item is removed.

All metrics emitted as a JSON block in each run's PRD. Future
regressions surface as number drift.

## §12. Gate B performance & subsampling

At cascade v2 full-playlist density (~1800 cards), Gate B's
candidate enumeration is fast (SQL + set unions; ms per card), but
the classification step scales with candidates-per-card. Rough
ceiling: 40 candidates × 1800 cards = 72,000 Sonnet calls, which is
prohibitive.

**Mitigations (apply in order if telemetry indicates):**

1. **Per-card cap on candidates sent to Sonnet.** Cascade's self-
   imposed default: top 10 by shared-keyword count (with
   `lineOfThought` immediate neighbors always included — single-hop
   only; see §5). Tune up toward 20 if Gate B is missing obvious
   pairs; the proposeLinksSemantic primitive's own hard ceiling is
   `MAX_CANDIDATES_IN_PROMPT = 20` (semantic-proposer.ts:199), so
   pushing past 10 is possible up to that ceiling without primitive
   changes. Beyond 20 requires modifying the primitive itself.

2. **Incremental mode.** New transcript's cards scan against the
   hub, not hub-wide pairwise. Existing hub cards don't re-classify
   against each other unless a new `reinforces` edge changes their
   neighborhood.

3. **Confidence floor.** `proposeLinksSemantic` already returns
   confidence per proposal; default commit floor is **0.7** (matches
   acceptance criterion #3 and §5 Gate B diagram point 4; also
   matches `SILMARI_TIER_B_CONFIDENCE_THRESHOLD` default in
   card-ops.ts). Tune per-hub via telemetry item 6 distributions
   rather than a calibration UI (no such UI exists after the
   Level-2 rewrite — see §10).

Subsampling is the acceptable trade-off — §8 says density IS the
signal, but density doesn't require completeness; recall at the
well-populated pairs is far more important than recall at the
long tail.

## Risk register

1. **Prompt drift between passes.** Pass 3's output quality depends
   on Pass 2's framing. If Pass 2 emits woolly ideas, Pass 3 can't
   salvage them. Mitigation: spend iteration on the prompt
   SEQUENCE, not individual prompts. Test end-to-end, not per-pass.

2. **Gate A false negatives.** If Option A (JS NLP) lets compound
   cards through, we pay for extra sonnet-repair calls that didn't
   need to happen. Mitigation: monitor the sonnet-repair rate in the
   first 3 transcripts; if <5% of cards get flagged, Gate A is under-
   triggering and we swap to Option B.

3. **Gate B candidate under-recall.** Hubs whose cards share <2
   keyword terms produce empty candidate sets — Gate B never fires
   for those cards, and the resulting graph has reinforces gaps at
   exactly the points the user will most notice. Mitigation: §11
   telemetry item 5 watches for 0-candidate tails; if >20% of cards
   land there across a transcript, lower `minOverlap` from 2→1 (or
   broaden keyword extraction in Pass 2/3 so micros get more terms).
   (Revision 2 — was previously framed as MiniLM threshold
   mis-calibration; threshold is gone, under-recall is the new
   analogous risk.)

4. **Cost blowup.** ~700 haiku calls + ~30 sonnet repair calls per
   15-video playlist. Cache is essential; every pass writes a JSON
   file and subsequent runs only re-call for missing/changed inputs.
   A content-hash of the transcript + prompt version pins the cache.

5. **Cross-transcript reinforces noise — NOT A RISK; IT'S THE SIGNAL.**
   KC Baker repeats the same claim across videos deliberately. The
   cascade emits a `reinforces` edge for every such recurrence. This
   is not noise to tame — it's the whole point. Per Luhmann's
   multiple-storage principle (Schmidt 2018), an idea's meaning is
   partly its NEIGHBORS, which means "the same claim appearing in
   eight different contexts" is eight different semantic placements
   and deserves eight cards + seven reinforces edges.
   
   **The density IS the epistemics.** High-count reinforces subgraphs
   reveal the speaker's load-bearing claims without any explicit
   importance-scoring step — the most-reinforced claims are the ones
   most worth surfacing in `zk_recall`, in viewer rendering, in hub
   summarization. Capping the fan-in would destroy exactly the
   signal we're trying to build.
   
   **No cap on reinforces edges. No cap on reinforces fan-in.** See
   §8 for the "same claim, different context" principle in detail.

6. ~~**MiniLM vocabulary mismatch.**~~ Removed in Revision 2 — no
   MiniLM in Level-2 architecture; Sonnet reads bodies in full via
   proposeLinksSemantic, no vector-space collapse to worry about.

## TODO register (out of scope for this release)

- **Enterprise hubs.** Aggregate multiple person-hubs under a single
  hub. Gate B candidate enumeration (filterByKeywordOverlap +
  hubMembers) extends to all constituent hubs. Per-hub tunable
  parameters (keyword-overlap integer, confidence floor) may diverge
  across constituents. File as `silmari-agent-memory-*` bd issue
  when this release ships.
- **Narrow-chain similarity.** Currently the plan computes hub-scoped
  pairwise. A narrower option: compare only cards ON the same
  folgezettel chain (ancestors + descendants). Cheaper, but misses
  the main value of reinforces — cross-chain reinforcement. Revisit
  after we see the hub-scoped graph's quality.
- **Non-LLM baseline.** For ablation: run Pass 3 using spaCy
  dependency-based claim extraction (no LLM) and compare card quality
  to the LLM output. Informs whether the LLM is earning its cost on
  sentence-atomization.
- **Viewer awareness of reinforces edges.** The current Silmari
  viewer renders edges but doesn't visually distinguish reinforces
  from other types. Once the cascade produces dense reinforces
  subgraphs, the viewer should highlight them (maybe a dashed
  connector color). Small viewer issue; after cascade lands.
- **Retrieval-time chain traversal.** `zk_recall` currently walks
  keyword → entry-point cards. It doesn't walk the chain-of-thought
  from a card's position. Chain-traversal queries ("give me every
  card on the 1/3 chain") are supported via `zk_chain`, but the
  reinforces-aware traversal ("follow reinforces edges across
  chains") is not. Add as a future MCP tool once reinforces density
  proves useful.
- **Incremental pipeline**: today the cascade runs end-to-end. Could
  be incremental — new transcript arrives, only re-run Gate B on
  the new cards vs. existing hub. Cheap win once the core is stable.

## §8. "Same claim, different context" — Luhmann multiple-storage (FRAMEWORK-LEVEL)

This is the invariant the entire cascade exists to preserve. Worth
stating explicitly so future runs never regress toward pruning.

**Principle (Luhmann, via Schmidt 2018):** when the same claim appears
in a new context, it gets a new card AT THAT CONTEXT'S FOLGEZETTEL
POSITION, linked to prior occurrences via a `reinforces` edge. The
substrate never collapses the card into its prior instance — the
recurrence is THE signal, and the graph topology is how we read it.

**Concrete implications for the cascade:**

1. **Gate B emits `reinforces` for every pair above threshold.** No
   "merge" mode, no deduplicate-and-discard mode. Only propose-edge.
   (The only deduplication that happens is at the claim-representation
   level: if Pass 3 extracts the same literal sentence twice from one
   transcript, that's a Pass-3 bug, not a place for post-hoc dedup.)

2. **Reinforces fan-in and fan-out are unbounded.** A single KC Baker
   claim ("shame silences women") can legitimately reinforce across
   eight videos. That node gets eight inbound reinforces edges. This
   is the desired state, not a pathology.

3. **Density reveals importance.** High-count reinforces subgraphs
   are the hub's load-bearing claims. A future
   `zk_recall_by_reinforces_density` or similar can surface "the 10
   most-repeated claims in this person's work" without a manual
   importance-ranking step — the graph topology already knows.

4. **Each context survives intact.** Card `1/7a2b` ("on the fear that
   arises before power") and card `1/12a1a` (same claim in a 17-min
   TEDx framing) both stay fully written, with their own folgezettel
   addresses, keywords, and neighborhoods. The `reinforces` edge
   between them lets recall traverse from one to the other without
   either being the canonical version.

5. **No canonical card for a recurring claim.** Cascade output should
   never compute "the best" version of a claim. There is no best
   version. There are N versions, each in its own context, all
   equally real.

**What this rules out (anti-patterns to refuse):**

- ❌ "Merge duplicates into a single canonical card."
- ❌ "Cap reinforces fan-in at N."
- ❌ "Hide cards below a reinforces-count threshold from recall."
- ❌ "Summarize the reinforces cluster into one card."
- ❌ "Only propose reinforces between cards in the same chain."
- ✅ Emit every edge above threshold, unbounded, and let the viewer /
  retrieval layer surface density as the importance signal.

This section is referenced by `silmari-agent-memory-r04` (saveCard
dedup→reinforce) as the motivating principle; any implementation of
r04 must honor §8 invariants.

## Decisions locked (2026-04-22, post-REVIEW)

Five questions raised by Revision 2 were resolved by Maceo on
2026-04-22:

- **L4 auto-fire removal — INSIDE r04 (review option c).** The
  `proposeLinksSemanticSync` auto-invocation + auto-commit at
  `card-ops.ts:773-806` gets deleted as part of the r04 TDD plan,
  NOT as a separate sequenced work item. Rationale: the L4 code
  path is small, r04 already touches card-ops.ts extensively, and
  there's no evidence the L4 removal would surface unrelated bugs
  that warrant an isolation-first rollout. One surgery, not two.
- **Step 5.5 primitives — SPLIT across two files.**
  `filterByKeywordOverlap` lands in
  `apps/silmari-mcp/src/lib/keyword-index.ts` (keyword operation;
  belongs next to `lookupKeyword` and `readKeywordIndex`).
  `hubMembers` lands in a NEW
  `apps/silmari-mcp/src/lib/hub.ts` (first of a hub-query family;
  seeds the category so future hub primitives — parent-hub lookup,
  hub-of-hubs aggregation, etc — have an obvious home). Rationale:
  the hub concept is already set to grow (enterprise hubs in the
  TODO register, hub aggregation mentioned in §1 estimates); giving
  it its own file now costs one extra file and saves a rename
  later.
- **sweepDuplicates — KEEP BOTH + REINFORCE + FLAG FOR REVIEW
  (the "sleep consolidation" pattern).** On a concurrent-write
  race where two processes save the same body, both beads survive
  and the younger one emits a `reinforces` edge to the older (no
  silent delete). In addition, r04 MUST attach a
  `needs-consolidation-review:true` label to the newly-created
  bead pair so that a later human pass (the "sleep" analogy —
  humans accumulate during the day and consolidate during sleep)
  can inspect the pair and decide: "truly duplicate — prune one"
  or "genuinely-different contexts — clear the flag and keep both."
  The flag is provisional; the reinforce edge is committed. This
  gives the r04 invariant (no silent data loss) AND a deliberate
  review surface for pruning decisions. Implementation detail for
  the r04 TDD plan: the FDO proposal-review UI (Step 7) or a
  sibling `zk_recall_consolidation_queue` tool surfaces these
  pairs for review.
- **Existing-corpus migration (§9) — DEFER until the MCP ingestion
  changes (r04 + 7h6 + 5.5 + cascade Steps 3-6) have all landed.
  Then: Option D — RESEARCH the 310 cards, do not just run Gate B
  blindly.** The originally-proposed "one-shot retroactive Gate B
  pass" (§9 option B) is superseded. Once the cascade is fully
  shipped and emitting typed edges on new saves, a separate
  research phase will examine the 310 pre-existing cards —
  reading bodies, surfacing themes, finding conceptual connections
  beyond what Gate B's keyword-overlap candidate enumeration would
  produce — and THEN emit informed edges. This is a distinct work
  item, NOT part of the cascade release. File as a new bd issue
  when we're ready; tentative name
  `silmari-agent-memory-*-retro-research`.
- **`annotates` extractor — DEFER.** Ship as its own small bd
  issue the day `@mention` syntax becomes useful in card bodies.
  Cascade-generated micros don't contain `@mentions`; shipping the
  extractor now would be waste.

## Open questions

*(All Revision-2-era opens were resolved on 2026-04-22; see the
`## Decisions locked` block above. The only remaining open is an
implementation-time review item:)*

1. **sweepDuplicates implementation review.** The r04 TDD plan
   specifies the behavior (keep both + reinforce + flag for review),
   but the concurrency implementation itself — the actual code path
   that resolves a WAL-race window — needs code review when r04
   lands. This is "we'll see the code" oversight, not a design
   decision.

## Acceptance criteria (cascade release)

- One KC Baker transcript produces ≥80 cards end-to-end (thesis +
  themes + ideas + micros)
- Gate A flags ≥10% and ≤40% of cards (too few = under-triggering;
  too many = prompt drift in Pass 3)
- Gate B proposes ≥5 typed edges (any of the 5 REVIEWED types) above
  confidence floor 0.7 across the full playlist (signals that cross-
  transcript classification is emitting meaningful density — was
  previously framed against a removed MiniLM threshold; rewritten in
  Revision 2 to match the Level-2 Gate B contract)
- Reingesting an unchanged transcript against a store that already
  contains the prior run's cards: §8 behavior verified — every body
  produces a new card + a reinforces edge back to the prior-run
  twin. Card count strictly increases; `wasReinforced:true` appears
  on every rerun save (the pre-r04 `wasDeduped` field is gone
  entirely per the new SaveCardResult contract in §0 row (a)).
- At least one claim recurs across ≥3 transcripts with a visible
  reinforces subgraph — §8's "density IS the epistemics" in action
- 4-pass cache works: reruns that don't change the transcript OR the
  prompt version only re-run the ingest, not the LLM passes
- Step 4b A/B decision is recorded in the step PRD with diff stats
  (count / length / self-containment) between haiku and sonnet on
  the canary transcript

## Next step

§5 runtime decision is already made: pure-Bun, no Python, no
embeddings. Three sub-plan TDD documents have been drafted
(2026-04-22):

1. **r04 — saveCard dedup→reinforce:** [2026-04-22-r04-tdd-savecard-dedup-to-reinforce.md](./2026-04-22-r04-tdd-savecard-dedup-to-reinforce.md)
   (bd: `silmari-agent-memory-r04`, P1, OPEN).
2. **7h6 — keyword-index uncap:** [2026-04-22-7h6-tdd-keyword-index-uncap.md](./2026-04-22-7h6-tdd-keyword-index-uncap.md)
   (bd: `silmari-agent-memory-7h6`, P1, OPEN, depends on r04).
3. **Step 5.5 — silmari-mcp primitives:** [2026-04-22-step5.5-tdd-silmari-mcp-primitives.md](./2026-04-22-step5.5-tdd-silmari-mcp-primitives.md)
   (bd: `silmari-agent-memory-f23`, P1, OPEN, depends on r04).

**Remaining gates before implementation can start:**

1. ~~Resolve Open Questions 3 and 4~~ — **RESOLVED 2026-04-22**. See
   `## Decisions locked` block above: L4 removal inside r04;
   hubMembers in new hub.ts, filterByKeywordOverlap in keyword-index.ts.
2. **Review the three TDD plans** above for accuracy against the
   current codebase. Each carries a handful of `TODO: verify` markers
   where the drafting agents couldn't confirm without re-reading
   source; resolve those before starting implementation.
3. **Execute r04 first** (blocks both 7h6 and Step 5.5). Then 7h6 and
   5.5 in parallel (they don't block each other).
4. **Then file Algorithm runs for Steps 3 → 8** in sequence. Each
   step is its own Algorithm session with its own PRD under
   `MEMORY/WORK/`.

Track via beads:
- `silmari-agent-memory-r04` — Step 0 (saveCard pivot)
- `silmari-agent-memory-7h6` — Step 1 (keyword-index uncap, blocks on r04)
- `silmari-agent-memory-f23` — Step 5.5 (primitives, blocks on r04)
- `silmari-agent-memory-w6i` — review-findings tracking; close when
  TDD plans 2/3/4 are approved and Revision 2 of this cascade plan
  is merged (both conditions now met pending review of the sub-plans).
