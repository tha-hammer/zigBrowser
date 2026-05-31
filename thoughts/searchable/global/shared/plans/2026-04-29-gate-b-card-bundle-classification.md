---
date: 2026-04-29
planner: CobaltRiver
repository: silmari-agent-memory
branch: main
topic: "Gate B card bundle classification"
type: implementation_plan
status: phase4_native_smoke_passed
related_beads_issues:
  - silmari-agent-memory-nlz
  - silmari-agent-memory-9hn.1
  - silmari-agent-memory-7qr
tags: [gate-b, llm-batching, native-primary, performance, zettelkasten]
---

# Gate B Card Bundle Classification Plan

## Overview

Gate B should stop treating one source card as the natural LLM unit.
The correct unit is a card bundle: a transcript, hub, or bounded shard of a hub.

The model should receive many related cards once, emit typed reviewed edges among
those submitted IDs, and let deterministic code validate and commit the result.
The existing source-card path remains as a fallback, not the default full-run
strategy.

## Current State

- `scripts/kc-baker-pipeline-v2/ingest/ingest-cascade.ts` now has a batched
  real Gate B path, but it still builds jobs as `source card -> candidate cards`.
- `apps/silmari-mcp/src/lib/semantic-proposer.ts` has
  `classifyProposalBatchWithInference`, but the batch prompt repeats candidate
  bodies across source jobs.
- The default `CASCADE_GATE_B_LLM_BATCH_SIZE` is 4 source cards. This is better
  than 929 calls, but still far below the useful context window.
- `GATE_B_MAX_CANDIDATES` is 20 per source, so the current prompt shape scales
  as `source_count * candidate_count`, not as `unique_cards`.
- Native-primary/rusqlite validation works and legacy `br` validation is not
  trusted.

## Decision

Implement a new bundle classifier path.

Do not just raise the source-card batch size and call that done. A larger batch
still repeats the same candidate bodies and keeps the mental model wrong.

Bundle classifier input:

- `bundleId`: transcript basename, hub ID, or shard ID.
- `cards`: unique card records `{ id, title, body, labels?, source? }`.
- `allowedPairs`: optional deterministic candidate map when we want to limit
  relationships without repeating bodies.
- `maxEdgesPerSource`.
- `maxEdgesTotal`.

Bundle classifier output:

```json
[
  {
    "sourceId": "zk-source",
    "targetId": "zk-target",
    "edge": "supports",
    "confidence": 0.82,
    "quoted_overlap": "literal target phrase"
  }
]
```

Validation stays deterministic:

- `sourceId` and `targetId` must be submitted card IDs.
- If `allowedPairs` is present, the pair must be allowed.
- `edge` must be one of `supports`, `contradicts`, `extends`, `reinforces`, or
  `refines`.
- `confidence` must be in range.
- `quoted_overlap` must be present and short.
- Enforce `maxEdgesPerSource` and `maxEdgesTotal` after sorting by confidence.

## What We Are Not Doing

- Do not use legacy `br` for validation.
- Do not ask the LLM to invent card IDs, create cards, update storage, or commit
  edges directly.
- Do not remove the current source-card classifier in the first slice.
- Do not run full 15-transcript real Gate B until one-transcript bundle telemetry
  proves the call count and latency shape.

## Implementation Plan

### Phase 1: Pure Bundle Classifier Contract

Files:

- `apps/silmari-mcp/src/lib/semantic-proposer.ts`
- `apps/silmari-mcp/tests/semantic-proposer.test.ts`

Add:

- `ProposalBundleCard`
- `ProposalBundleArgs`
- `buildBundleUserPrompt(args)`
- `validateBundleProposals(raw, args)`
- `classifyProposalBundleWithInference(args)`

Tests:

- Prompt includes each card body once.
- Output rejects IDs not in the bundle.
- Output rejects pairs not in `allowedPairs`.
- Output enforces reviewed edge types.
- Output enforces per-source and total edge caps.
- One provider call can classify many source cards.

Success:

- `bun test apps/silmari-mcp/tests/semantic-proposer.test.ts`
- `bun run --cwd apps/silmari-mcp typecheck`

### Phase 2: Cascade Bundle Assembly

File:

- `scripts/kc-baker-pipeline-v2/ingest/ingest-cascade.ts`

Add a new real Gate B mode:

```bash
CASCADE_GATE_B_CLASSIFIER_MODE=bundle
```

Bundle assembly rules:

- For import/enrich of one transcript, start with that transcript's imported
  `allIds`.
- Hydrate each card body once through `silmari://card/<id>`.
- Build `allowedPairs` from the existing deterministic signals:
  - shared keywords
  - hub membership
  - line-of-thought adjacency
- Submit bundle shards by estimated prompt size, not by source count.

New env knobs:

- `CASCADE_GATE_B_CLASSIFIER_MODE=source|bundle`
- `CASCADE_GATE_B_BUNDLE_MAX_CARDS`
- `CASCADE_GATE_B_BUNDLE_MAX_PROMPT_CHARS`
- `CASCADE_GATE_B_BUNDLE_MAX_EDGES_PER_SOURCE`
- `CASCADE_GATE_B_BUNDLE_MAX_EDGES_TOTAL`

Default:

- Keep `source` until the one-transcript bundle smoke passes.
- Then change default real Gate B mode to `bundle`.

### Phase 3: Bundle Telemetry

Extend `gateB` report:

- `classifier_mode`
- `bundles_submitted`
- `bundle_cards_submitted`
- `bundle_unique_cards_hydrated`
- `bundle_prompt_chars_total`
- `bundle_prompt_chars_max`
- `llm_calls_attempted`
- `llm_latency_ms_total`
- `llm_latency_ms_avg`
- `edges_returned_raw`
- `edges_rejected_validation`
- `edges_rejected_caps`
- `edges_committed`

Success criterion:

LLM call count for one transcript must scale with shard count, not card count.
For `kc_bakers_words_of_wisdom`, expected shape is 1 to 2 LLM calls, not 26.

### Phase 4: One-Transcript Real Smoke

Run only native-primary/rusqlite.

Command shape:

```bash
TARGET_TRANSCRIPT=kc_bakers_words_of_wisdom.txt \
CASCADE_ENRICHMENT_MODE=after-import \
CASCADE_GATE_B_CLASSIFIER_MODE=bundle \
CASCADE_GATE_B_BUNDLE_MAX_CARDS=80 \
SAI_INFERENCE_BACKEND=codex \
SILMARI_MEMORY_CONFIG="$tmp/config/native-memory-mode.json" \
SILMARI_MEMORY_RUST_BINARY="$rust_bin" \
SILMARI_DIR="$tmp/silmari-store" \
EXTRACTED_DIR="$tmp/extracted" \
bun run ingest/ingest-cascade.ts
```

Pass criteria:

- Native SQLite `PRAGMA integrity_check` returns `ok`.
- No legacy `br` hot-path reads/writes.
- `llm_calls_attempted <= 2` for the 26-card transcript.
- Nonzero reviewed edges are committed, or the report shows raw model output was
  rejected for concrete validation reasons.
- Telemetry records prompt chars, cards submitted, raw edges, rejected edges, and
  committed edges.

### Phase 5: Full Playlist Gate

Only after Phase 4 passes:

- Run full cached 15-transcript native-primary bundle Gate B.
- Do not require every transcript to hit old card-density targets; that is
  tracked separately by `silmari-agent-memory-792`.
- Close `7qr` only if the run proves no cascading thesis-save failure and shows
  real Gate B evidence across the playlist.

## Rollback

- Set `CASCADE_GATE_B_CLASSIFIER_MODE=source` to return to the current batched
  source-card classifier.
- Keep all bundle changes behind the mode flag until one-transcript real smoke
  passes.

## Acceptance

- Bundle classifier exists and is tested as pure prompt/validation logic.
- Cascade can assemble one transcript into a bundle without repeated card body
  prompts.
- One real-Codex native-primary transcript smoke classifies the transcript in
  1 to 2 LLM calls.
- Reports make it obvious whether runtime is LLM latency, prompt size, validation
  rejection, storage reads, or commit work.
- Legacy `br` remains outside the validation path.

## Implementation Notes — 2026-04-29

Implemented through Phase 4 under `silmari-agent-memory-nlz`.

Focused verification:

- `bun test apps/silmari-mcp/tests/semantic-proposer.test.ts` → 35 pass.
- `bun test scripts/kc-baker-pipeline-v2/tests/ingest-cascade.test.ts` → 37 pass.
- `bun run --cwd apps/silmari-mcp typecheck` → pass.

One-transcript native-primary/Codex smoke:

- Temp workspace: `/tmp/tmp.PBmOLNPD7Z`.
- Transcript: `how_to_shift_from_fear_to_grace_in_public_speaking`.
- Storage integrity: native-primary SQLite `PRAGMA integrity_check` returned `ok`.
- `classifier_mode`: `bundle`.
- `sources_scanned`: 52.
- `candidates_total`: 292.
- `llm_calls_attempted`: 1.
- `bundles_submitted`: 1.
- `bundle_cards_submitted`: 53.
- `bundle_prompt_chars_total`: 26863.
- `edges_returned_raw`: 97.
- `edges_rejected_validation`: 0.
- `edges_rejected_caps`: 17.
- `edges_committed`: 80.

For the same 52 scanned source cards, the old source-card real batch mode at
the default `CASCADE_GATE_B_LLM_BATCH_SIZE=4` would require 13 LLM calls before
counting body duplication inside each source job. The bundle smoke classified
the run in one LLM call while sending each hydrated card body once in the
bundle prompt.

Phase 5 remains intentionally pending: full 15-transcript real Gate B should
only run after this one-transcript evidence is reviewed and the agents agree on
runtime/cost expectations.
