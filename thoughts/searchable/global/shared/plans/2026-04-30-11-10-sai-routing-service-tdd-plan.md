---
date: 2026-04-30T11:10:00-04:00
planner: Algorithm (council R5 synthesis → Stage 2 TDD plan)
repository: silmari-agent-memory
branch: main
topic: "SAI routing service — public sai_route_thought / sai_submit_thought tools, private routeThought + classifier, mandatory remote-host audit"
type: tdd_plan
status: reviewer-questions-answered
methodology: test_driven_development
reviewer_decisions:
  downgrade_vs_reject: allow_downgrade
  downgrade_map_semantics: static_map_watch_evals_for_small_llm_need
  mcp_agent_audit_default: denial_only_watch_for_audit_every_submit_need
  trunk_confidence_threshold: defer_until_real_usage_with_telemetry
  source_field_semantics: defer_until_real_usage_with_telemetry
prerequisites:
  - thoughts/searchable/shared/plans/2026-04-30-10-50-kindguard-tdd-plan.md (Stage 1 kindGuard)
related_research:
  - thoughts/searchable/shared/research/2026-04-28-ultimate-mcp-server-silmari-mcp-algorithm-contracts.md
related_specs:
  - specs/MASTER-SYSTEM-DIAGRAM.md
  - specs/ultimate-mcp-memory.md
source_notes:
  - MEMORY/WORK/20260430-counsel-mcp-vs-local-sai/PRD.md (R5 synthesis, especially zk-vhzi, zk-30hr, zk-rp1y)
tags: [tdd, routing, sai-mcp, zettelkasten-fixed-index, audit-logging, public-mcp-surface]
---

# SAI Routing Service TDD Implementation Plan (Stage 2)

## Overview

Stage 1 (kindGuard) hardens the legacy `zk_save_card` / `zk_save_cards` entry
points. Stage 2 (this plan) builds the **public routing service** that any
host — Claude Code, Cursor, Codex, Gemini, future MCP clients — calls to
submit a thought without ever owning the route table.

Two new MCP tools land:

- `sai_route_thought` — advisory preview, returns a `RouteDecision` envelope, no writes
- `sai_submit_thought` — atomic route + persist + audit

A new private module `apps/silmari-mcp/src/lib/router.ts` houses
`routeThought()`, `classifyTrunk()`, `classifyThoughtType()`, and the fixed
`THOUGHTTYPE_TO_KIND` and `KIND_TO_DESTINATION` tables. The kindGuard module
from Stage 1 is the L2 policy enforcement point inside `routeThought`.

**The architectural pattern** is server-side authority over claimed metadata
(syscalls / admission controllers / DB row-level security / SPF/DKIM
verifying claimed `From` headers). The caller submits content + an optional
`claimedThoughtType` hint; the server decides the `effectiveThoughtType` and
the destination. The route table is **never exposed**.

## Core Design Principle: Zettelkasten Single Source of Truth

> "The key to the Zettelkasten is acknowledging there is a single source of
> truth for organization and classification. The IDEA and THOUGHT changes,
> the place in the world does not."

This insight shapes the entire design:

| What | Behavior | Why |
|---|---|---|
| The **route table** (ThoughtType → CardKind → destination) | **Fixed**, encoded in code, never mutated by callers | The Zettelkasten index IS the topology; it doesn't get re-decided per submission |
| The **trunk taxonomy** (1-5: Humanities, Social Science, Natural Science, Formal Science, Applied Science) | **Fixed**, defined in `USER/TRUNKS.md` | Luhmann's organizational schema — invariant |
| The **classifier** | **Heuristic-first** (keyword index), **small-model fallback** (Inference.ts `fast` tier) | Classification is pattern-matching against the fixed index, not policy decision |
| The **content/idea** | **Mutable** — body edits, edge additions, status transitions, eventual revisions | The thought evolves; the placement does not |
| The **folgezettel address** | **Allocated once**, never changed | Once placed, the position is the position. New thoughts get new addresses; old ones never move |

The router is therefore a **pattern-matcher against an unchanging index**, not
a decision engine. The "small model" exists only to handle the classification
step (which slot does this content fit?), not to invent new slots.

## Current State Analysis

### Key Discoveries (Stage 1 prerequisites)

- `apps/silmari-mcp/src/lib/kindGuard.ts` exists from Stage 1 with
  `assertKindAllowed`, `resolveCallerFromEnv`, 4-tier `TrustTier` enum, and
  `KIND_TRUST` table.
- `apps/silmari-mcp/src/lib/labels.ts:51` has `VALID_CARD_KINDS` (11 values)
- `apps/silmari-mcp/src/lib/keyword-index.ts` exposes `lookupKeyword(term)`
  — the L1 substrate the trunk classifier will consult
- `apps/silmari-mcp/src/lib/folgezettel.ts` has the `TrunkId` type (1-5)
- `vendor/ultimate_mcp_server/ultimate_mcp_server/tools/unified_memory_system.py:285`
  defines `ThoughtType` (15 values) — Stage 2 imports these as the public
  surface enum even though Ultimate's runtime is not yet wired
- `SAI/Tools/Inference.ts` exposes `fast/standard/smart` tiers — `fast` is the
  Haiku tier, suitable for classification

### What Stage 2 Adds

- `apps/silmari-mcp/src/lib/router.ts` — new module: routeThought, classifiers, route tables
- `apps/silmari-mcp/src/lib/route-audit.ts` — new module: append-only JSONL audit
- 2 new tools in `apps/silmari-mcp/src/index.ts`: `sai_route_thought`, `sai_submit_thought`
- 5+ new test files under `apps/silmari-mcp/tests/`

### Patterns to Reuse

- **kindGuard** for L2 enforcement (Stage 1)
- **keyword-index `lookupKeyword`** for trunk classification primary path
- **Inference.ts fast tier** for small-model fallback classification
- **Existing `dispatchTool` switch** at `index.ts:534` — add new cases beside `zk_save_card`
- **JSONL append pattern** from `SAI/MEMORYSYSTEM.md:220` for audit log

### Telemetry Required For Deferred Decisions

Deferred routing policy must be driven by observed usage, not renewed debate.
Stage 2 therefore records lightweight telemetry separately from security audit
lines. Telemetry may be aggregate counters or bounded JSONL, but it must be
cheap, local, and safe to retain.

Required telemetry fields:

| Field | Why |
|---|---|
| `callerTier` and `host.name` | Decide whether `mcp-agent` traffic is noisy enough to justify every-submit auditing. |
| `source` | Decide whether source labels predict real trust/routing needs before designing signing or attestation. |
| `claimedThoughtType`, `effectiveThoughtType`, `effectiveKind` | Evaluate static downgrade quality and whether a small LLM downgrade helper is needed. |
| `downgraded` and `denied` | Measure security policy pressure by caller class. |
| `classifierSource` and `classifierConfidence` | Decide whether trunk confidence thresholds or default-to-trunk-5 fallback are needed. |
| `persistedId` / `persistedAddress` presence | Identify route decisions that did not result in persistence. |
| `followupCorrection` when detectable | Track host/user correction or resubmission patterns that indicate misrouting. |

Telemetry is not authorization. It must never upgrade caller tier or override
kindGuard. It only informs future Stage 3+ policy changes.

## Desired End State

A non-Claude MCP host (Cursor, Codex, Gemini) can submit thoughts to SAI
through `sai_submit_thought` without owning routing logic, route table, or
classification heuristics. The server returns a structured `RouteDecision`
envelope and persists the thought to the appropriate destination
(silmari for now; Ultimate UMS write path is Stage 3 and out of scope here).
Every `remote-host` write is audited; forge attempts are downgraded with
warnings rather than silent rejection (so the host can see what happened
and adjust).

Reviewer decisions applied:
- Tier mismatch uses downgrade, not rejection, unless no safe downgraded kind exists.
- `DOWNGRADE_MAP` stays static and auditable for Stage 2; routing evals must be watched to decide whether a small LLM is later needed for downgrade selection.
- `mcp-agent` submits are audited only on denial for Stage 2; add telemetry so we can decide whether every submit should be audited later.
- Trunk confidence thresholds are deferred until real usage; Stage 2 must emit enough telemetry to decide whether a threshold is needed.
- The optional `source` field does not influence trust tier in Stage 2; Stage 2 must emit enough telemetry to decide whether source-aware routing is justified later.

### Observable Behaviors

- Submitting a thought with `claimedThoughtType: "DECISION"` from a
  `remote-host` caller produces a `RouteDecision` with
  `effectiveThoughtType: "CRITIQUE"` (or similar downgrade), `route` pointing
  at a subagent-tier destination, `allowed: true`, and a warning code
  `claimed-thoughttype-downgraded`.
- The same submission from a `system-hook` caller produces
  `effectiveThoughtType: "DECISION"`, route to `silmari.zk_save_card` with
  `kind: "decision"`, no warnings.
- `sai_route_thought` returns the same shape as `sai_submit_thought` but
  doesn't persist or audit.
- Every `remote-host` `sai_submit_thought` call appends one line to
  `MEMORY/STATE/route-decisions.jsonl` with the decision envelope.
- Drift in any of the three enums (ThoughtType, CardKind, MemoryType) fails
  CI via the snapshot test.

## What We're NOT Doing (Stage 2)

| Out of scope | Reason / when |
|---|---|
| Ultimate UMS write path (`route: 'ultimate.store_memory'` actually persisting) | Stage 3 — requires the Ultimate MCP to be registered and the write bridge to land |
| `route: 'both'` (write to both silmari and ultimate atomically) | Stage 3 — atomic dual-write is its own design problem |
| Removing the legacy `zk_save_card` / `zk_save_cards` tools | Forever-stay — they remain as the system-hook write path |
| LLM-based RouteDecision review (an LLM second-guessing the router) | Anti-pattern — Iris's R5 enum-drift critique applies; the model MUST NOT vote on routing |
| Per-content embedding-based classification | Anti-pattern by user's T1 — vectors are population-level, fail at individual cognition |
| Cross-LLM session bridging (multiple hosts on the same workflow_id) | Stage 4+ — requires cognitive-state-snapshot work |
| Small-LLM downgrade-map selection | Deferred — Stage 2 uses a static map; watch routing evals/telemetry before adding model assistance |
| Confidence-threshold policy for trunk routing | Deferred — Stage 2 records classifier confidence; decide threshold only after real usage shows misroutes or low-confidence harm |
| `source`-based trust escalation | Deferred — Stage 2 treats `source` as audit/telemetry metadata only because it is forgeable without signing |

## Testing Strategy

- **Framework**: `bun:test`
- **Run command**: `bun test apps/silmari-mcp/tests/router*.test.ts`,
  `bun test apps/silmari-mcp/tests/sai-route-thought.test.ts`,
  `bun test apps/silmari-mcp/tests/sai-submit-thought.test.ts`
- **Test types**:
  - Unit: classifier internals (B1-B4), routeThought composition (B5-B7)
  - Integration: dispatchTool wiring for both new tools (B8-B10)
  - Cross-language snapshot: enum drift (B11)
  - Coverage gate: route-table exhaustiveness (B12)
  - E2E: simulated remote-host flow (B13-B14)
- **Test isolation**: temp `SILMARI_DIR`, temp `MEMORY/STATE` for the audit
  log, env-var override for caller tier (Stage 1's helper).
- **Inference mocking**: a thin wrapper at `lib/inference-client.ts` that
  tests can substitute. Production uses `SAI/Tools/Inference.ts` `fast`
  tier; tests stub with deterministic responses.

---

## Behavior 1: Fixed ThoughtType → CardKind Mapping

### Test Specification

**Given**: 15 `ThoughtType` values (`unified_memory_system.py:285`)
**When**: `THOUGHTTYPE_TO_KIND[thoughtType]` is read
**Then**: every `ThoughtType` has an explicit `CardKind` assignment

**Proposed mapping** (Marcus's R5 ROUTE table, slightly refined):

| ThoughtType | CardKind | Destination | Rationale |
|---|---|---|---|
| `GOAL` | `decision` | silmari | Committed intent — durable |
| `DECISION` | `decision` | silmari | 1:1 |
| `HYPOTHESIS` | `idea` | silmari | Structural thought, mutable |
| `INFERENCE` | `learning` | silmari | Derived knowledge |
| `EVIDENCE` | `fact` | silmari | Durable claim with backing |
| `CONSTRAINT` | `fact` | silmari | Durable boundary condition |
| `PLAN` | `stub` | silmari | Future intention; status drives lifecycle |
| `REFLECTION` | `learning` | silmari | Meta-cognition committed |
| `CRITIQUE` | `idea` | silmari | Open evaluation |
| `SUMMARY` | `structure` | silmari | Index card / overview |
| `USER_GUIDANCE` | `preference` | silmari | 1:1, system-hook gated |
| `INSIGHT` | `learning` | silmari | 1:1 |
| `QUESTION` | `signal` | silmari | Open until resolved (signal status) |
| `REASONING` | `idea` | silmari | Chain-of-thought scratch (Stage 3 may route to Ultimate) |
| `ANALYSIS` | `idea` | silmari | Tool-output exegesis (Stage 3 may route to Ultimate) |

**Note on REASONING/ANALYSIS**: Marcus's R5 table routed these to Ultimate's
`REASONING_STEP` memory type. Stage 2 keeps them in silmari (`kind: idea`)
because the Ultimate write path doesn't exist yet. The route table comment
flags these as "ultimate-eligible-stage-3" so the future migration is one
table edit.

### TDD Cycle

#### 🔴 Red: Failing Test

**File**: `apps/silmari-mcp/tests/router-mapping.test.ts`

```ts
import { describe, it, expect } from 'bun:test';
import { THOUGHTTYPE_TO_KIND, VALID_THOUGHT_TYPES } from '../src/lib/router.js';

describe('THOUGHTTYPE_TO_KIND mapping', () => {
  it('covers every ThoughtType', () => {
    for (const tt of VALID_THOUGHT_TYPES) {
      expect(THOUGHTTYPE_TO_KIND[tt]).toBeDefined();
    }
  });
  it('GOAL maps to decision', () => {
    expect(THOUGHTTYPE_TO_KIND.GOAL).toBe('decision');
  });
  it('USER_GUIDANCE maps to preference', () => {
    expect(THOUGHTTYPE_TO_KIND.USER_GUIDANCE).toBe('preference');
  });
  it('SUMMARY maps to structure', () => {
    expect(THOUGHTTYPE_TO_KIND.SUMMARY).toBe('structure');
  });
});
```

#### 🟢 Green: Minimal Implementation

**File**: `apps/silmari-mcp/src/lib/router.ts` (new)

```ts
import type { CardKind } from './labels.js';

export const VALID_THOUGHT_TYPES = [
  'GOAL', 'QUESTION', 'HYPOTHESIS', 'INFERENCE', 'EVIDENCE',
  'CONSTRAINT', 'PLAN', 'DECISION', 'REFLECTION', 'CRITIQUE',
  'SUMMARY', 'USER_GUIDANCE', 'INSIGHT', 'REASONING', 'ANALYSIS',
] as const;

export type ThoughtType = typeof VALID_THOUGHT_TYPES[number];

export const THOUGHTTYPE_TO_KIND: Record<ThoughtType, CardKind> = {
  GOAL: 'decision',
  DECISION: 'decision',
  HYPOTHESIS: 'idea',
  INFERENCE: 'learning',
  EVIDENCE: 'fact',
  CONSTRAINT: 'fact',
  PLAN: 'stub',
  REFLECTION: 'learning',
  CRITIQUE: 'idea',
  SUMMARY: 'structure',
  USER_GUIDANCE: 'preference',
  INSIGHT: 'learning',
  QUESTION: 'signal',
  REASONING: 'idea',
  ANALYSIS: 'idea',
};
```

The `Record<ThoughtType, CardKind>` type forces compile-time exhaustiveness.

#### 🔵 Refactor

None — the table is already minimal data.

### Success Criteria

- [ ] Red fails: `router.ts` does not exist
- [ ] All assertions green
- [ ] Compile-time check: deleting any entry causes tsc error

---

## Behavior 2: Fixed CardKind → Destination Mapping

### Test Specification

**Given**: 11 `CardKind` values
**When**: `KIND_TO_DESTINATION[kind]` is read
**Then**: every kind has a destination of `'silmari'` (Stage 2) or
`'ultimate-eligible-stage-3'` marker

For Stage 2, every CardKind routes to `'silmari'`. Stage 3 will introduce
`'ultimate'` and `'both'` as actual targets. The marker for stage-3 candidates
is a separate annotation, not an alternate destination string — so Stage 2
can ship without a runtime change at this layer.

### TDD Cycle

#### 🔴 Red

```ts
import { KIND_TO_DESTINATION, ULTIMATE_ELIGIBLE_KINDS } from '../src/lib/router.js';
import { VALID_CARD_KINDS } from '../src/lib/labels.js';

describe('KIND_TO_DESTINATION mapping', () => {
  it('routes every CardKind to silmari (Stage 2)', () => {
    for (const k of VALID_CARD_KINDS) {
      expect(KIND_TO_DESTINATION[k]).toBe('silmari');
    }
  });
  it('flags ultimate-eligible kinds for Stage 3 migration', () => {
    // REASONING and ANALYSIS thought types → idea cards → flagged
    // for Stage 3 migration to Ultimate UMS REASONING_STEP
    expect(ULTIMATE_ELIGIBLE_KINDS.has('idea')).toBe(true);
  });
});
```

#### 🟢 Green

```ts
export type Destination = 'silmari';  // Stage 2 — Stage 3 expands to 'ultimate' | 'both'

export const KIND_TO_DESTINATION: Record<CardKind, Destination> = {
  biblio: 'silmari',
  idea: 'silmari',
  hub: 'silmari',
  structure: 'silmari',
  register: 'silmari',
  fact: 'silmari',
  signal: 'silmari',
  learning: 'silmari',
  preference: 'silmari',
  decision: 'silmari',
  stub: 'silmari',
};

// Marker for kinds whose typical thoughttype source (REASONING, ANALYSIS)
// is a candidate for ultimate.store_memory routing in Stage 3. Does not
// affect Stage 2 routing — informational only.
export const ULTIMATE_ELIGIBLE_KINDS: ReadonlySet<CardKind> = new Set(['idea']);
```

### Success Criteria

- [ ] All entries route to silmari
- [ ] Stage 3 marker is documented but inactive

---

## Behavior 3: Trunk Classifier — Keyword-Index Path

### Test Specification

**Given**: content containing words present in the keyword index
**When**: `classifyTrunk(content)` is called
**Then**: returns `{ trunk, confidence, source: 'keyword-index' }` where
`trunk` is the trunk that contains those keywords' entry points and
`confidence` is in `[0.5, 1.0]` (keyword-index hits are high-confidence by
construction — the index encodes Luhmann's fixed taxonomy)

**Edge cases**:
- Content with multiple keywords spanning multiple trunks: pick the trunk
  with the most entry-point hits; tiebreak by highest-keyword-density trunk
- Content with no keyword matches: returns `null` (B4 handles fallback)
- Stage 2 accepts the classifier result even at the current 0.5 floor. Do
  not add a hard threshold yet; instead record `confidence`, `source`, and
  whether the caller later corrects/resubmits so real usage can tell us
  whether a >0.7 threshold or trunk-5 fallback is needed.

### TDD Cycle

#### 🔴 Red

**File**: `apps/silmari-mcp/tests/router-classify-trunk.test.ts`

```ts
import { describe, it, expect, beforeAll } from 'bun:test';
import { classifyTrunk } from '../src/lib/router.js';
// helper to seed keyword index for tests
import { addKeywordEntry } from '../src/lib/keyword-index.js';

describe('classifyTrunk — keyword-index path', () => {
  beforeAll(() => {
    // Seed keyword index with some test entries
    addKeywordEntry('zettelkasten', '5/1', 'agent');     // applied science
    addKeywordEntry('luhmann', '5/2', 'agent');
    addKeywordEntry('cognition', '3/1', 'agent');         // natural science
  });

  it('classifies content with applied-science keywords as trunk 5', () => {
    const result = classifyTrunk('zettelkasten and luhmann are foundational');
    expect(result?.trunk).toBe(5);
    expect(result?.confidence).toBeGreaterThanOrEqual(0.5);
    expect(result?.source).toBe('keyword-index');
  });

  it('returns null when no keyword matches', () => {
    const result = classifyTrunk('completely unrelated content xyzzyq');
    expect(result).toBeNull();
  });

  it('picks the trunk with most hits when keywords span trunks', () => {
    const result = classifyTrunk('zettelkasten luhmann cognition');
    // 2 trunk-5 hits vs 1 trunk-3 hit → trunk 5 wins
    expect(result?.trunk).toBe(5);
  });
});
```

#### 🟢 Green

```ts
import { lookupKeyword } from './keyword-index.js';
import type { TrunkId } from './folgezettel.js';

export interface TrunkClassification {
  trunk: TrunkId;
  confidence: number;
  source: 'keyword-index' | 'small-model' | 'caller-hint';
}

const WORD_RE = /[a-zA-Z][a-zA-Z0-9_-]+/g;

export function classifyTrunk(content: string): TrunkClassification | null {
  const tokens = (content.match(WORD_RE) ?? []).map(t => t.toLowerCase());
  const trunkHits = new Map<TrunkId, number>();
  for (const token of tokens) {
    const entries = lookupKeyword(token);
    for (const entry of entries) {
      const trunk = parseTrunkFromAddress(entry);  // helper that extracts TrunkId
      if (trunk !== null) {
        trunkHits.set(trunk, (trunkHits.get(trunk) ?? 0) + 1);
      }
    }
  }
  if (trunkHits.size === 0) return null;

  // Pick the trunk with most hits; tiebreak by lowest trunk number (deterministic)
  let best: TrunkId | null = null;
  let bestCount = 0;
  for (const [trunk, count] of trunkHits.entries()) {
    if (count > bestCount || (count === bestCount && (best === null || trunk < best))) {
      best = trunk;
      bestCount = count;
    }
  }
  // Confidence: more hits = more confident. Cap at 1.0; floor at 0.5 for any hit.
  const confidence = Math.min(1.0, 0.5 + 0.1 * bestCount);
  return { trunk: best!, confidence, source: 'keyword-index' };
}

function parseTrunkFromAddress(addr: string): TrunkId | null {
  const m = addr.match(/^(\d+)\//);
  if (!m) return null;
  const n = parseInt(m[1], 10);
  if (n >= 1 && n <= 5) return n as TrunkId;
  return null;
}
```

#### 🔵 Refactor

If `parseTrunkFromAddress` is duplicated elsewhere, hoist to `folgezettel.ts`.

### Success Criteria

- [ ] Tests green
- [ ] Trunk picker is deterministic (same input → same output)

---

## Behavior 4: Trunk Classifier — Small-Model Fallback

### Test Specification

**Given**: content with no keyword-index matches
**When**: `classifyTrunk(content, { useFallback: true })` is called
**Then**: invokes the small-model client and returns its choice with
`source: 'small-model'`, `confidence` from the model's structured output

The fallback is OPT-IN. By default `classifyTrunk` returns `null` on no
match; callers explicitly request the fallback when they want the model
called. This prevents accidental Inference.ts invocations on every
unrelated dispatch.

### TDD Cycle

#### 🔴 Red

```ts
import { classifyTrunk } from '../src/lib/router.js';
import { mockInferenceClient } from '../src/lib/inference-client.js';

describe('classifyTrunk — small-model fallback', () => {
  it('does not call inference unless useFallback is true', async () => {
    const stub = mockInferenceClient(() => { throw new Error('should not be called'); });
    const result = await classifyTrunk('xyzzyq nothing matches', { client: stub });
    expect(result).toBeNull();
  });

  it('invokes inference when useFallback: true and keyword path is empty', async () => {
    const stub = mockInferenceClient(() => Promise.resolve(JSON.stringify({ trunk: 4, confidence: 0.7 })));
    const result = await classifyTrunk('xyzzyq nothing matches', { useFallback: true, client: stub });
    expect(result?.source).toBe('small-model');
    expect(result?.trunk).toBe(4);
    expect(result?.confidence).toBe(0.7);
  });

  it('rejects malformed model output', async () => {
    const stub = mockInferenceClient(() => Promise.resolve('not-json'));
    await expect(
      classifyTrunk('xyzzyq', { useFallback: true, client: stub })
    ).rejects.toThrow(/E_CLASSIFIER_BAD_OUTPUT/);
  });

  it('rejects out-of-range trunk', async () => {
    const stub = mockInferenceClient(() => Promise.resolve(JSON.stringify({ trunk: 99, confidence: 1.0 })));
    await expect(
      classifyTrunk('xyzzyq', { useFallback: true, client: stub })
    ).rejects.toThrow(/E_CLASSIFIER_BAD_OUTPUT/);
  });
});
```

#### 🟢 Green

**New file**: `apps/silmari-mcp/src/lib/inference-client.ts`

```ts
export interface InferenceClient {
  classifyTrunk(content: string): Promise<string>;  // returns JSON string
}

const PRODUCTION_PROMPT = `Classify this content into one of the 5 Luhmann trunks:
1=Humanities, 2=Social Science, 3=Natural Science, 4=Formal Science, 5=Applied Science.
Return JSON: {"trunk": 1-5, "confidence": 0.0-1.0}.

Content:
`;

export const productionInferenceClient: InferenceClient = {
  async classifyTrunk(content: string): Promise<string> {
    // Spawn `bun ~/.claude/SAI/Tools/Inference.ts fast` with the prompt;
    // capture stdout. Real impl wraps the existing tool.
    const proc = Bun.spawn(['bun', `${process.env.SAI_DIR ?? '~/.claude/SAI'}/Tools/Inference.ts`, 'fast'], {
      stdin: 'pipe', stdout: 'pipe',
    });
    proc.stdin.write(PRODUCTION_PROMPT + content);
    proc.stdin.end();
    return await new Response(proc.stdout).text();
  },
};

export function mockInferenceClient(fn: (content: string) => Promise<string> | string): InferenceClient {
  return {
    classifyTrunk: async (content: string) => {
      const result = fn(content);
      return typeof result === 'string' ? result : await result;
    },
  };
}
```

**In `router.ts`**, extend `classifyTrunk`:

```ts
export interface ClassifyOpts {
  useFallback?: boolean;
  client?: InferenceClient;
}

export async function classifyTrunk(
  content: string,
  opts: ClassifyOpts = {},
): Promise<TrunkClassification | null> {
  const keywordResult = classifyTrunkKeywordOnly(content);
  if (keywordResult) return keywordResult;
  if (!opts.useFallback) return null;

  const client = opts.client ?? productionInferenceClient;
  const raw = await client.classifyTrunk(content);
  let parsed: unknown;
  try { parsed = JSON.parse(raw); }
  catch { throw new Error(`E_CLASSIFIER_BAD_OUTPUT: not JSON: ${raw.slice(0, 80)}`); }

  if (!parsed || typeof parsed !== 'object'
      || typeof (parsed as any).trunk !== 'number'
      || typeof (parsed as any).confidence !== 'number') {
    throw new Error(`E_CLASSIFIER_BAD_OUTPUT: missing fields in ${JSON.stringify(parsed)}`);
  }
  const trunk = (parsed as any).trunk;
  if (!Number.isInteger(trunk) || trunk < 1 || trunk > 5) {
    throw new Error(`E_CLASSIFIER_BAD_OUTPUT: trunk=${trunk} out of range`);
  }
  return { trunk: trunk as TrunkId, confidence: (parsed as any).confidence, source: 'small-model' };
}
```

(Renames the synchronous keyword-only helper to `classifyTrunkKeywordOnly`
internal to router.ts.)

#### 🔵 Refactor

The PRODUCTION_PROMPT is small; consider externalizing to
`apps/silmari-mcp/src/lib/prompts/classify-trunk.txt` once a second prompt
joins. Defer.

### Success Criteria

- [ ] Default behavior: no inference call without `useFallback: true`
- [ ] Fallback returns valid response shape
- [ ] Malformed model output rejected with `E_CLASSIFIER_BAD_OUTPUT`

---

## Behavior 5: ThoughtType Classifier (Hint Validation)

### Test Specification

**Given**: content + a `claimedThoughtType` hint
**When**: `validateOrInferThoughtType(content, claimed)` is called
**Then**:
- If `claimed` is provided AND the small model agrees within tolerance,
  returns `{ thoughtType: claimed, source: 'caller-hint-validated', confidence: <model's confidence> }`
- If `claimed` is provided AND model disagrees, returns model's choice with
  `source: 'caller-hint-overridden', warnings: ['claimed-type-mismatch']`
- If no `claimed`, returns model's choice with `source: 'small-model'`

For Stage 2, the validation step is **simple**: if the caller's claim is in
`VALID_THOUGHT_TYPES`, accept it (no semantic check). The full semantic-
mismatch detection requires LLM evaluation and is **deferred to Stage 3**.
Stage 2 ships with a permissive validator that catches malformed claims
but doesn't second-guess valid ones — kindGuard handles authorization,
and hinted-type spoofing is the next layer's concern.

### TDD Cycle

#### 🔴 Red

```ts
describe('validateOrInferThoughtType — Stage 2 permissive validator', () => {
  it('accepts a valid claimedThoughtType', async () => {
    const r = await validateOrInferThoughtType('any content', 'DECISION');
    expect(r.thoughtType).toBe('DECISION');
    expect(r.source).toBe('caller-hint-validated');
  });

  it('rejects an invalid claimedThoughtType', async () => {
    await expect(
      validateOrInferThoughtType('any', 'NOT_A_REAL_TYPE' as any)
    ).rejects.toThrow(/E_BAD_THOUGHTTYPE/);
  });

  it('falls back to model when no claim provided', async () => {
    const stub = mockInferenceClient(() => Promise.resolve(JSON.stringify({ thoughtType: 'INSIGHT', confidence: 0.8 })));
    const r = await validateOrInferThoughtType('content', undefined, { client: stub });
    expect(r.thoughtType).toBe('INSIGHT');
    expect(r.source).toBe('small-model');
  });
});
```

#### 🟢 Green

```ts
export interface ThoughtTypeClassification {
  thoughtType: ThoughtType;
  source: 'caller-hint-validated' | 'caller-hint-overridden' | 'small-model';
  confidence: number;
  warnings: string[];
}

export async function validateOrInferThoughtType(
  content: string,
  claimed?: string,
  opts: ClassifyOpts = {},
): Promise<ThoughtTypeClassification> {
  if (claimed !== undefined) {
    if (!(VALID_THOUGHT_TYPES as readonly string[]).includes(claimed)) {
      throw new Error(`E_BAD_THOUGHTTYPE: ${claimed} not in ${VALID_THOUGHT_TYPES.join(',')}`);
    }
    return {
      thoughtType: claimed as ThoughtType,
      source: 'caller-hint-validated',
      confidence: 1.0,
      warnings: [],
    };
  }

  // No claim — invoke small-model classifier
  const client = opts.client ?? productionInferenceClient;
  const raw = await client.classifyTrunk(content);  // reuse interface; production prompt differs
  // ... parse + validate as in B4
  return {
    thoughtType: parsedThoughtType,
    source: 'small-model',
    confidence: parsedConfidence,
    warnings: [],
  };
}
```

(In production, `inferenceClient.classifyTrunk` becomes a more general
`classify(content, taskName)` interface with named tasks like
`'classify-trunk'`, `'classify-thoughttype'`. Refactor Stage 2 introduces
this generalization.)

### Success Criteria

- [ ] Valid claim is honored
- [ ] Invalid claim throws `E_BAD_THOUGHTTYPE`
- [ ] No claim → small-model invocation

---

## Behavior 6: routeThought Composes Classify + Lookup + Guard

### Test Specification

**Given**: content + claimed thoughtType + caller
**When**: `routeThought({ content, claimedThoughtType, caller, ... })` is called
**Then**: returns a `RouteDecision` whose fields reflect:
- `effectiveThoughtType` = output of `validateOrInferThoughtType`
- `route` = `KIND_TO_DESTINATION[THOUGHTTYPE_TO_KIND[effectiveThoughtType]]`
- `allowed` = whether `assertKindAllowed(kind, caller)` passes (downgrade
  semantics in B7)
- `confidence` = product of trunk and thoughttype confidences
- `decisionId` = a fresh UUID
- `enumVersion` = the constant `ROUTING_ENUM_VERSION`
- `rationaleCodes` = the inputs that drove the decision (`["keyword-index", "caller-hint-validated"]`)

### TDD Cycle

#### 🔴 Red

```ts
import { routeThought } from '../src/lib/router.js';

describe('routeThought composition', () => {
  it('returns a RouteDecision with all required fields', async () => {
    const r = await routeThought({
      content: 'zettelkasten luhmann',
      claimedThoughtType: 'INSIGHT',
      caller: { agentId: 'test', trustTier: 'system-hook' },
    });
    expect(r.decisionId).toMatch(/^[0-9a-f-]{36}$/);  // UUID
    expect(r.effectiveThoughtType).toBe('INSIGHT');
    expect(r.route).toBe('silmari');  // Stage 2
    expect(r.allowed).toBe(true);
    expect(r.confidence).toBeGreaterThan(0);
    expect(r.enumVersion).toMatch(/^routing\.v\d+\.\d+$/);
    expect(r.rationaleCodes).toContain('caller-hint-validated');
    expect(r.rationaleCodes).toContain('keyword-index');
  });

  it('returns warnings array even when no warnings', async () => {
    const r = await routeThought({
      content: 'idea content',
      claimedThoughtType: 'CRITIQUE',
      caller: { agentId: 'test', trustTier: 'mcp-agent' },
    });
    expect(Array.isArray(r.warnings)).toBe(true);
  });
});
```

#### 🟢 Green

```ts
export interface RouteDecisionInput {
  content: string;
  claimedThoughtType?: ThoughtType;
  caller: Caller;
  source?: string;
  host?: { name: string; sessionId?: string; model?: string };
}

export interface RouteDecision {
  decisionId: string;
  effectiveThoughtType: ThoughtType;
  effectiveKind: CardKind;
  trunk: TrunkId | null;
  route: Destination;
  allowed: boolean;
  confidence: number;
  rationaleCodes: string[];
  warnings: string[];
  enumVersion: string;
  // Set only after submit (not advisory)
  persistedId?: string;
  persistedAddress?: string;
}

export const ROUTING_ENUM_VERSION = 'routing.v1.0';

export async function routeThought(input: RouteDecisionInput): Promise<RouteDecision> {
  const decisionId = crypto.randomUUID();
  const rationaleCodes: string[] = [];
  const warnings: string[] = [];

  // 1. Classify thoughttype
  const ttResult = await validateOrInferThoughtType(input.content, input.claimedThoughtType);
  rationaleCodes.push(ttResult.source);
  warnings.push(...ttResult.warnings);
  const effectiveThoughtType = ttResult.thoughtType;

  // 2. Look up kind
  const effectiveKind = THOUGHTTYPE_TO_KIND[effectiveThoughtType];

  // 3. Classify trunk (with fallback enabled if no caller-hint)
  const trunkResult = await classifyTrunk(input.content, { useFallback: true });
  if (trunkResult) {
    rationaleCodes.push(trunkResult.source);
  } else {
    rationaleCodes.push('trunk-unclassified');
    warnings.push('trunk-classifier-empty');
  }

  // 4. Guard
  let allowed = true;
  try {
    assertKindAllowed(effectiveKind, input.caller);
  } catch (err) {
    allowed = false;
    rationaleCodes.push('kind-guard-denied');
    // B7 will refine to downgrade-instead-of-deny
  }

  // 5. Look up destination
  const route = KIND_TO_DESTINATION[effectiveKind];

  // 6. Compose confidence
  const confidence = (ttResult.confidence ?? 1.0) * (trunkResult?.confidence ?? 0.5);

  return {
    decisionId,
    effectiveThoughtType,
    effectiveKind,
    trunk: trunkResult?.trunk ?? null,
    route,
    allowed,
    confidence,
    rationaleCodes,
    warnings,
    enumVersion: ROUTING_ENUM_VERSION,
  };
}
```

#### 🔵 Refactor

After B7 lands the downgrade semantics, this function will branch on
`allowed` differently. Defer the cleanup until both behaviors are landed.

### Success Criteria

- [ ] All fields populated
- [ ] decisionId is a valid UUID
- [ ] enumVersion matches constant

---

## Behavior 7: routeThought Downgrades on Tier Mismatch

### Test Specification

**Given**: a `mcp-agent` or `remote-host` caller submits content with
`claimedThoughtType: "DECISION"` (which would yield `kind: "decision"`,
requiring `local-cli` tier)
**When**: `routeThought` is called
**Then**: returns a decision with:
- `effectiveThoughtType: "CRITIQUE"` (or another mcp-agent-tier ThoughtType)
- `effectiveKind: "idea"` (the most permissive kind)
- `allowed: true` (downgrade, NOT denial)
- `warnings: ["claimed-thoughttype-downgraded"]`
- `rationaleCodes: [..., "kind-guard-downgraded"]`

The downgrade rule:
- If `effectiveKind` requires a tier higher than the caller has, find a
  ThoughtType that maps to a kind the caller CAN assert
- Specifically: downgrade to a `mcp-agent`-tier kind (`idea` or `stub`)
- ThoughtType downgrade: keep semantic similarity where possible
  (DECISION → CRITIQUE; INSIGHT → CRITIQUE; INFERENCE → REASONING; etc.)
- If even `idea` is not assertable (shouldn't happen with current tiers
  but defensive): `allowed: false`

Reviewer decision: allow downgrade. Do not reject normal tier mismatches
just to force a host retry; the router is the policy authority, so it should
return the safe route it can enforce. The rejection path is only for the
defensive case where no safe downgraded kind exists.

### TDD Cycle

#### 🔴 Red

```ts
describe('routeThought — downgrade on tier mismatch', () => {
  it('downgrades remote-host claim of DECISION to CRITIQUE/idea', async () => {
    const r = await routeThought({
      content: 'forged decision content',
      claimedThoughtType: 'DECISION',
      caller: { agentId: 'cursor-1', trustTier: 'remote-host' },
    });
    expect(r.effectiveThoughtType).not.toBe('DECISION');
    expect(r.effectiveKind).toBe('idea');
    expect(r.allowed).toBe(true);
    expect(r.warnings).toContain('claimed-thoughttype-downgraded');
    expect(r.rationaleCodes).toContain('kind-guard-downgraded');
  });

  it('does NOT downgrade when caller has sufficient tier', async () => {
    const r = await routeThought({
      content: 'real decision',
      claimedThoughtType: 'DECISION',
      caller: { agentId: 'algorithm-runner', trustTier: 'local-cli' },
    });
    expect(r.effectiveThoughtType).toBe('DECISION');
    expect(r.effectiveKind).toBe('decision');
    expect(r.allowed).toBe(true);
    expect(r.warnings).not.toContain('claimed-thoughttype-downgraded');
  });
});
```

#### 🟢 Green

```ts
const DOWNGRADE_MAP: Record<ThoughtType, ThoughtType> = {
  // Privileged → permissive
  GOAL: 'CRITIQUE',
  DECISION: 'CRITIQUE',
  USER_GUIDANCE: 'CRITIQUE',  // remote-host claiming user-guidance is suspicious
  INSIGHT: 'REASONING',
  INFERENCE: 'REASONING',
  EVIDENCE: 'CRITIQUE',
  CONSTRAINT: 'CRITIQUE',
  REFLECTION: 'REASONING',
  SUMMARY: 'CRITIQUE',
  // Already permissive — identity
  HYPOTHESIS: 'HYPOTHESIS',
  PLAN: 'CRITIQUE',          // PLAN → stub is system-hook only? Actually stub is mcp-agent. Keep PLAN → CRITIQUE for safety
  CRITIQUE: 'CRITIQUE',
  QUESTION: 'CRITIQUE',
  REASONING: 'REASONING',
  ANALYSIS: 'REASONING',
};

// Modified routeThought:
const initialKind = THOUGHTTYPE_TO_KIND[effectiveThoughtType];
let finalThoughtType = effectiveThoughtType;
let finalKind = initialKind;

try {
  assertKindAllowed(initialKind, input.caller);
  // permitted as-is
} catch {
  // Downgrade
  finalThoughtType = DOWNGRADE_MAP[effectiveThoughtType];
  finalKind = THOUGHTTYPE_TO_KIND[finalThoughtType];
  warnings.push('claimed-thoughttype-downgraded');
  rationaleCodes.push('kind-guard-downgraded');
  // Verify downgrade is allowed; if not, hard-deny
  try {
    assertKindAllowed(finalKind, input.caller);
  } catch {
    return {
      decisionId, route: KIND_TO_DESTINATION[finalKind], allowed: false,
      effectiveThoughtType: finalThoughtType, effectiveKind: finalKind,
      trunk: trunkResult?.trunk ?? null, confidence: 0,
      rationaleCodes: [...rationaleCodes, 'kind-guard-denied-after-downgrade'],
      warnings: [...warnings, 'caller-tier-cannot-assert-any-kind'],
      enumVersion: ROUTING_ENUM_VERSION,
    };
  }
}
```

#### 🔵 Refactor

The downgrade logic should be a separate function `downgradeForCaller(thoughtType, caller)`
returning `{ thoughtType, kind, downgraded: boolean }`. Extract once tested.
Keep `DOWNGRADE_MAP` static in Stage 2. Add routing eval fixtures and
telemetry counters for downgraded submissions so we can tell whether static
mapping causes enough semantic mismatch to justify a small LLM helper later.

### Success Criteria

- [ ] Downgrade test passes
- [ ] No-downgrade test passes (privileged caller path)
- [ ] DOWNGRADE_MAP is exhaustive over ThoughtType
- [ ] Downgrade telemetry records original type, downgraded type, caller tier, and warning code without exposing the private route table

---

## Behavior 8: sai_route_thought MCP Tool — Advisory, No Writes

### Test Specification

**Given**: a thought submission via `sai_route_thought`
**When**: `dispatchTool('sai_route_thought', input)` is called
**Then**:
- Returns `okResult({ decision: RouteDecision })` with `persistedId` and
  `persistedAddress` UNDEFINED
- No new bead created in the test fixture's silmari store
- No new line in `MEMORY/STATE/route-decisions.jsonl`

### TDD Cycle

#### 🔴 Red

```ts
import { dispatchTool } from '../src/index.js';

describe('sai_route_thought — advisory mode', () => {
  it('returns a decision without persisting', async () => {
    const cardCountBefore = await countCardsInFixture();
    const auditCountBefore = countAuditLogLines();

    const result = await dispatchTool('sai_route_thought', {
      content: 'advisory test',
      claimedThoughtType: 'INSIGHT',
      host: { name: 'cursor', sessionId: 's1' },
    });

    const payload = JSON.parse((result.content[0] as any).text);
    expect(payload.decision).toBeDefined();
    expect(payload.decision.persistedId).toBeUndefined();
    expect(payload.decision.persistedAddress).toBeUndefined();

    expect(await countCardsInFixture()).toBe(cardCountBefore);
    expect(countAuditLogLines()).toBe(auditCountBefore);
  });
});
```

#### 🟢 Green

In `apps/silmari-mcp/src/index.ts`, add to `dispatchTool`:

```ts
case 'sai_route_thought': {
  const content = String(args.content ?? '');
  if (!content) throw new Error('content is required');
  const claimedThoughtType = args.claimedThoughtType as ThoughtType | undefined;
  const caller = resolveCallerFromEnv();
  const host = (args.host ?? undefined) as RouteDecisionInput['host'];
  const decision = await routeThought({ content, claimedThoughtType, caller, host });
  return okResult({ decision });
}
```

Also add to the `TOOLS` array near the top of `index.ts`:

```ts
{
  name: 'sai_route_thought',
  description: 'Advisory routing preview. Returns a RouteDecision envelope ' +
    'showing how the server would route this content + claimedThoughtType ' +
    'without persisting. Use to preview classification + downgrade before ' +
    'calling sai_submit_thought.',
  inputSchema: {
    type: 'object',
    required: ['content'],
    properties: {
      content: { type: 'string', minLength: 1 },
      claimedThoughtType: { type: 'string', enum: VALID_THOUGHT_TYPES },
      source: { type: 'string' },
      host: {
        type: 'object',
        properties: {
          name: { type: 'string' },
          sessionId: { type: 'string' },
          model: { type: 'string' },
        },
      },
    },
  },
},
```

### Success Criteria

- [ ] Tool is registered in TOOLS array
- [ ] Test confirms no persistence
- [ ] Test confirms no audit log mutation

---

## Behavior 9: sai_submit_thought — Atomic Route + Persist

### Test Specification

**Given**: a thought submission via `sai_submit_thought` with valid input
**When**: `dispatchTool('sai_submit_thought', input)` is called
**Then**:
- Routes the thought (calls routeThought internally)
- Persists to the destination indicated by `decision.route`
- Returns `okResult({ decision })` with `persistedId` and `persistedAddress` SET
- No partial state on failure (atomicity)

For Stage 2, every successful submit lands in silmari. Ultimate path is
Stage 3.

### TDD Cycle

#### 🔴 Red

```ts
describe('sai_submit_thought — atomic submit', () => {
  it('persists a permitted thought and returns persistedId', async () => {
    const result = await dispatchTool('sai_submit_thought', {
      content: 'this is a real insight worth saving',
      claimedThoughtType: 'INSIGHT',
      host: { name: 'claude-code', sessionId: 's1' },
    });
    const payload = JSON.parse((result.content[0] as any).text);
    expect(payload.decision.allowed).toBe(true);
    expect(payload.decision.persistedId).toMatch(/^zk-/);
    expect(payload.decision.persistedAddress).toMatch(/^\d+\//);
  });

  it('rejects (allowed=false) when caller cannot assert any kind', async () => {
    // Synthetic caller whose tier blocks even idea — currently impossible
    // with default KIND_TRUST. Skip if no such tier exists.
    // Placeholder: this test pins the contract for if KIND_TRUST changes.
  });
});
```

#### 🟢 Green

```ts
case 'sai_submit_thought': {
  const content = String(args.content ?? '');
  if (!content) throw new Error('content is required');
  const claimedThoughtType = args.claimedThoughtType as ThoughtType | undefined;
  const caller = resolveCallerFromEnv();
  const host = (args.host ?? undefined) as RouteDecisionInput['host'];

  const decision = await routeThought({ content, claimedThoughtType, caller, host });

  if (!decision.allowed) {
    // B10 will append to audit log here as well
    return okResult({ decision });
  }

  // Stage 2: route is always 'silmari' so we use saveCard with the
  // computed kind + trunk.
  const result = saveCard({
    box: 'idea',
    body: content,
    kind: decision.effectiveKind,
    trunk: decision.trunk ?? 5,  // default trunk 5 (Applied Science) when classifier returns null
    mode: 'continue',
    source: `sai-submit-${decision.decisionId}`,
  });
  if (!result) {
    decision.allowed = false;
    decision.warnings.push('persistence-failed');
    return okResult({ decision });
  }

  decision.persistedId = result.id;
  decision.persistedAddress = result.fz;

  await appendRouteAudit(decision, caller, host);  // B10 wires this

  return okResult({ decision });
}
```

#### 🔵 Refactor

The `saveCard` call duplicates the kind/trunk parsing already in
`zk_save_card`. Extract `persistThoughtToSilmari(decision, content, source)`.

### Success Criteria

- [ ] Test passes; persistedId is `zk-...`
- [ ] No persistence side-effect when `allowed: false`

---

## Behavior 10: Mandatory Audit for remote-host Submits

### Test Specification

**Given**: a `remote-host` caller submits via `sai_submit_thought`
**When**: dispatch completes
**Then**: exactly one new line is appended to
`MEMORY/STATE/route-decisions.jsonl` containing the full `RouteDecision`
envelope plus host metadata

For `mcp-agent` callers: audit is written ONLY on `allowed: false`
(denials always logged). For `local-cli` and `system-hook` callers: no
audit (their writes are already captured by other mechanisms — PRDSync,
events.jsonl).

For `remote-host`: ALWAYS audited, allowed or not. This is the
non-negotiable security check that R5 settled on.

Reviewer decision for `mcp-agent`: keep denial-only audit in Stage 2. Do not
audit every `mcp-agent` submit yet. Add counters for total submits, denied
submits, downgraded submits, and host names so we can decide from usage
whether full submit auditing is worth the log volume.

### TDD Cycle

#### 🔴 Red

**File**: `apps/silmari-mcp/tests/router-audit.test.ts`

```ts
import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';

describe('route audit logging', () => {
  it('logs every remote-host submit', async () => {
    process.env.SILMARI_CALLER_TIER = 'remote-host';
    process.env.SILMARI_CALLER_AGENT_ID = 'cursor-test';
    const auditPath = join(process.env.SAI_DIR!, 'MEMORY', 'STATE', 'route-decisions.jsonl');
    const beforeLines = existsSync(auditPath)
      ? readFileSync(auditPath, 'utf-8').split('\n').filter(Boolean).length
      : 0;

    await dispatchTool('sai_submit_thought', {
      content: 'remote-host content',
      claimedThoughtType: 'CRITIQUE',
      host: { name: 'cursor', sessionId: 's1' },
    });

    const afterLines = readFileSync(auditPath, 'utf-8').split('\n').filter(Boolean).length;
    expect(afterLines).toBe(beforeLines + 1);

    const lastLine = JSON.parse(readFileSync(auditPath, 'utf-8').split('\n').filter(Boolean).at(-1)!);
    expect(lastLine.decisionId).toMatch(/^[0-9a-f-]{36}$/);
    expect(lastLine.callerTier).toBe('remote-host');
    expect(lastLine.host.name).toBe('cursor');
  });

  it('does NOT log local-cli submits with allowed=true', async () => {
    process.env.SILMARI_CALLER_TIER = 'local-cli';
    // ... assert no audit line added
  });

  it('logs mcp-agent submits ONLY on denial', async () => {
    // ... contrive a denial (e.g. forged biblio) and assert audit line
  });
});
```

#### 🟢 Green

**New file**: `apps/silmari-mcp/src/lib/route-audit.ts`

```ts
import { appendFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import type { RouteDecision } from './router.js';
import type { Caller } from './kindGuard.js';

function getAuditPath(): string {
  const memDir = process.env.SAI_DIR ?? `${process.env.HOME}/.claude`;
  return join(memDir, 'MEMORY', 'STATE', 'route-decisions.jsonl');
}

function shouldAudit(decision: RouteDecision, caller: Caller): boolean {
  if (caller.trustTier === 'remote-host') return true;
  if (!decision.allowed) return true;  // denials always logged
  return false;
}

export function appendRouteAudit(
  decision: RouteDecision,
  caller: Caller,
  host?: { name: string; sessionId?: string; model?: string },
): void {
  if (!shouldAudit(decision, caller)) return;
  const path = getAuditPath();
  mkdirSync(dirname(path), { recursive: true });
  const line = JSON.stringify({
    decisionId: decision.decisionId,
    timestamp: new Date().toISOString(),
    callerTier: caller.trustTier,
    callerAgentId: caller.agentId,
    host: host ?? null,
    claimedThoughtType: undefined,  // wire from input.claimedThoughtType
    effectiveThoughtType: decision.effectiveThoughtType,
    effectiveKind: decision.effectiveKind,
    route: decision.route,
    allowed: decision.allowed,
    persistedId: decision.persistedId,
    rationaleCodes: decision.rationaleCodes,
    warnings: decision.warnings,
    enumVersion: decision.enumVersion,
  });
  appendFileSync(path, line + '\n', 'utf-8');
}
```

The B9 case calls `appendRouteAudit(decision, caller, host)` after the
persistence step (or earlier if denied).

#### 🔵 Refactor

Audit writes are sync; for hot paths consider async with a queue. Defer
unless latency surfaces in profiling.

### Success Criteria

- [ ] remote-host submit always logged
- [ ] local-cli allowed submit not logged
- [ ] mcp-agent denied submit logged
- [ ] mcp-agent allowed submit increments telemetry but does not append an audit line
- [ ] Telemetry is sufficient to evaluate whether every mcp-agent submit should be audited later

---

## Behavior 11: Tier Auto-Detection from MCP Transport

### Test Specification

**Given**: no `SILMARI_CALLER_TIER` env override; the MCP request includes a `host.name` field
**When**: `resolveCallerFromTransport(request, env)` is called
**Then**: returns the appropriate tier:
- `host.name === 'claude-code'` AND parent uid matches the user's hooks process → `system-hook`
- `host.name === 'silmari-cli'` OR env has `SILMARI_CLI=1` → `local-cli`
- `host.name` is anything else (cursor, codex, gemini) → `remote-host`
- No `host.name` → `mcp-agent` (default)

The env-var override (`SILMARI_CALLER_TIER`) ALWAYS wins over auto-detection
— it's the testability hook.

The optional input `source` field is not part of trust-tier resolution in
Stage 2. It is caller-controlled and forgeable without signing, so it must
not upgrade `mcp-agent` or `remote-host` authority. Store it in the decision
envelope/telemetry only. Revisit source-aware routing after real usage shows
whether source labels predict valid routing needs.

### TDD Cycle

#### 🔴 Red

```ts
describe('resolveCallerFromTransport', () => {
  it('detects remote-host from cursor host.name', () => {
    const c = resolveCallerFromTransport({ host: { name: 'cursor' } }, {});
    expect(c.trustTier).toBe('remote-host');
  });
  it('detects local-cli from SILMARI_CLI env', () => {
    const c = resolveCallerFromTransport({}, { SILMARI_CLI: '1' });
    expect(c.trustTier).toBe('local-cli');
  });
  it('defaults to mcp-agent', () => {
    const c = resolveCallerFromTransport({}, {});
    expect(c.trustTier).toBe('mcp-agent');
  });
  it('env override always wins', () => {
    const c = resolveCallerFromTransport(
      { host: { name: 'cursor' } },
      { SILMARI_CALLER_TIER: 'system-hook' }
    );
    expect(c.trustTier).toBe('system-hook');
  });
});
```

#### 🟢 Green

In `kindGuard.ts`, add:

```ts
export function resolveCallerFromTransport(
  request: { host?: { name?: string }; meta?: { caller?: string } },
  env: NodeJS.ProcessEnv = process.env,
): Caller {
  // Env override is canonical
  if (env.SILMARI_CALLER_TIER) return resolveCallerFromEnv(env);

  if (env.SILMARI_CLI === '1') return { agentId: 'silmari-cli', trustTier: 'local-cli' };

  const hostName = request?.host?.name;
  if (hostName === 'claude-code') return { agentId: 'claude-code', trustTier: 'system-hook' };
  if (hostName && hostName !== 'claude-code' && hostName !== 'silmari-cli') {
    return { agentId: hostName, trustTier: 'remote-host' };
  }

  return { agentId: 'mcp-agent', trustTier: 'mcp-agent' };
}
```

The `dispatchTool` cases for `sai_route_thought` and `sai_submit_thought`
switch from `resolveCallerFromEnv()` to
`resolveCallerFromTransport(args, process.env)` so they pick up the
host-based tier.

### Success Criteria

- [ ] All four detection paths green
- [ ] Env override priority correct
- [ ] `source` field never upgrades caller tier
- [ ] Telemetry records `source` values alongside caller tier for future analysis

---

## Behavior 12: Enum Drift Snapshot Test

### Test Specification

**Given**: the three enums (`ThoughtType`, `MemoryType`, `CardKind`)
**When**: any of them changes
**Then**: CI fails until `ROUTING_ENUM_VERSION` is bumped AND `THOUGHTTYPE_TO_KIND` /
`KIND_TO_DESTINATION` updated

### TDD Cycle

#### 🔴 Red

**File**: `apps/silmari-mcp/tests/router-enum-drift.test.ts`

```ts
import { VALID_THOUGHT_TYPES, ROUTING_ENUM_VERSION } from '../src/lib/router.js';
import { VALID_CARD_KINDS } from '../src/lib/labels.js';

describe('router enum-drift snapshot', () => {
  it('VALID_THOUGHT_TYPES matches the snapshot', () => {
    expect(VALID_THOUGHT_TYPES).toMatchInlineSnapshot(`
      [
        "GOAL", "QUESTION", "HYPOTHESIS", "INFERENCE", "EVIDENCE",
        "CONSTRAINT", "PLAN", "DECISION", "REFLECTION", "CRITIQUE",
        "SUMMARY", "USER_GUIDANCE", "INSIGHT", "REASONING", "ANALYSIS"
      ]
    `);
  });
  it('VALID_CARD_KINDS matches the snapshot', () => {
    expect(VALID_CARD_KINDS).toMatchInlineSnapshot(`
      [
        "biblio", "idea", "hub", "structure", "register",
        "fact", "signal", "learning", "preference", "decision", "stub"
      ]
    `);
  });
  it('ROUTING_ENUM_VERSION is set', () => {
    expect(ROUTING_ENUM_VERSION).toMatch(/^routing\.v\d+\.\d+$/);
  });
});
```

When any enum changes, the snapshot fails; engineer updates the snapshot AND
bumps `ROUTING_ENUM_VERSION` from `routing.v1.0` to `routing.v1.1` (minor) or
`routing.v2.0` (major) per semver-ish rules.

### Success Criteria

- [ ] Snapshot covers all three enums
- [ ] Bumping requires an explicit decision — no silent drift

---

## Behavior 13: Route-Table Coverage Gate

### Test Specification

**Given**: every `ThoughtType` and every `CardKind`
**When**: `THOUGHTTYPE_TO_KIND` / `KIND_TO_DESTINATION` are inspected
**Then**: every key has a value (no missing entries)

This is Marcus's R5 4th gate. Compile-time `Record<...>` types catch most
of this; the runtime test catches the case where someone uses
`Partial<Record<...>>` to bypass.

### TDD Cycle

#### 🔴 Red

```ts
import { THOUGHTTYPE_TO_KIND, KIND_TO_DESTINATION, VALID_THOUGHT_TYPES } from '../src/lib/router.js';
import { VALID_CARD_KINDS } from '../src/lib/labels.js';

describe('route-table coverage', () => {
  it('THOUGHTTYPE_TO_KIND covers all ThoughtTypes', () => {
    for (const tt of VALID_THOUGHT_TYPES) {
      expect(THOUGHTTYPE_TO_KIND[tt]).toBeDefined();
    }
  });
  it('KIND_TO_DESTINATION covers all CardKinds', () => {
    for (const k of VALID_CARD_KINDS) {
      expect(KIND_TO_DESTINATION[k]).toBeDefined();
    }
  });
});
```

#### 🟢 Green

No new code — already passes from B1/B2.

### Success Criteria

- [ ] Both coverage tests green
- [ ] Adding a new ThoughtType without a mapping fails CI

---

## Behavior 14: E2E Integration — Cursor-Style Remote Host Submit

### Test Specification

**Given**: simulated remote-host submission with `claimedThoughtType: "DECISION"`
**When**: end-to-end through CLI spawn
**Then**:
- Decision envelope shows downgrade to CRITIQUE/idea
- One bead created in fixture silmari (kind: idea)
- One audit line in `MEMORY/STATE/route-decisions.jsonl`

### TDD Cycle

#### 🔴 Red

**File**: `apps/silmari-mcp/tests/router-cursor-e2e.test.ts`

Reuses the `Bun.spawn` fixture pattern from `sai-compat-noninterference.test.ts`:

```ts
it('cursor-style remote-host submit: downgrade + persist + audit', async () => {
  const proc = Bun.spawn([
    'bun', 'src/cli.ts', 'tool', 'sai_submit_thought',
    JSON.stringify({
      content: 'cursor host content',
      claimedThoughtType: 'DECISION',
      host: { name: 'cursor', sessionId: 's-test' },
    }),
  ], {
    cwd: APP_DIR,
    env: {
      ...process.env,
      SAI_DIR: SAI_TMP,
      SILMARI_DIR: SILMARI_TMP,
      // No SILMARI_CALLER_TIER set — tier auto-detected from host.name
    },
    stdout: 'pipe',
    stderr: 'pipe',
  });
  const stdout = await new Response(proc.stdout).text();
  const exit = await proc.exited;
  expect(exit).toBe(0);

  const payload = JSON.parse(stdout);
  expect(payload.decision.allowed).toBe(true);
  expect(payload.decision.effectiveKind).toBe('idea');
  expect(payload.decision.warnings).toContain('claimed-thoughttype-downgraded');

  const auditLines = readFileSync(join(SAI_TMP, 'MEMORY/STATE/route-decisions.jsonl'), 'utf-8')
    .split('\n').filter(Boolean);
  expect(auditLines.length).toBe(1);
  expect(JSON.parse(auditLines[0]).callerTier).toBe('remote-host');
});
```

#### 🟢 Green

No new code — verifies the wiring of B11 + B7 + B10.

### Success Criteria

- [ ] E2E test passes from a clean fixture
- [ ] Audit + bead creation are atomic (both or neither)

---

## Implementation Order

1. **B1, B2, B12, B13** — pure data tables and snapshots (no inference, no MCP) — ~30 min
2. **B3** — keyword-index trunk classifier (no inference yet) — ~45 min
3. **B4** — small-model fallback wiring with mock client — ~60 min
4. **B5** — thoughttype validator (Stage 2 permissive) — ~30 min
5. **B6** — routeThought composition — ~60 min
6. **B7** — downgrade semantics — ~45 min
7. **B11** — tier auto-detection — ~30 min
8. **B8** — sai_route_thought tool wiring — ~30 min
9. **B9** — sai_submit_thought tool wiring — ~45 min
10. **B10** — audit logging module + integration — ~45 min
11. **B14** — E2E cursor-flow integration test — ~30 min

**Total**: ~7 hours.

---

## Beads Issue

```bash
bd create --title="Stage 2: SAI routing service (sai_route_thought / sai_submit_thought)" \
  --type=feature --priority=2 \
  --description="Implements the public routing service per the council R5 synthesis. Plan: thoughts/searchable/shared/plans/2026-04-30-11-10-sai-routing-service-tdd-plan.md. Depends on Stage 1 kindGuard (Beads: <Stage 1 issue id>)."
bd dep add <stage-2-id> <stage-1-id>  # Stage 2 depends on Stage 1
```

---

## What's Deferred to Stage 3

- Ultimate UMS write path (`route: 'ultimate.store_memory'` actually persisting to Ultimate's SQLite memory tables)
- `route: 'both'` for atomic dual-write
- LLM-based semantic mismatch detection (claim says DECISION, content reads like a hypothesis → flag as warning even when caller has tier)
- Small-LLM downgrade selection. Stage 2 static map stays unless routing evals show systematic bad downgrades.
- Trunk confidence thresholding. Stage 2 records confidence and misroute/resubmit telemetry before deciding whether to require >0.7 or default to trunk 5.
- Cross-host workflow_id correlation (Cursor session resumes Codex session)
- Source-aware trust/routing. Stage 2 records `source` but treats it as untrusted until real usage and a signing/attestation story justify more.
- Vector-embedding *augmentation* of trunk classifier (Ultimate's hybrid_search_memories as a fallback signal)

---

## Key References

- Stage 1 prerequisite plan: `thoughts/searchable/shared/plans/2026-04-30-10-50-kindguard-tdd-plan.md`
- Council PRD with R5 synthesis: `MEMORY/WORK/20260430-counsel-mcp-vs-local-sai/PRD.md`
- Memory cards from R5: `zk-vhzi` (thoughttype IS the interface), `zk-30hr` (vector vs Zettelkasten different models), `zk-rp1y` (forge vuln)
- Ultimate ThoughtType source: `vendor/ultimate_mcp_server/ultimate_mcp_server/tools/unified_memory_system.py:285`
- Silmari CardKind source: `apps/silmari-mcp/src/lib/labels.ts:51`
- Architectural patterns: OS syscalls, K8s admission controllers, DB row-level security, SPF/DKIM
- The single source of truth principle: Luhmann's invariant index — IDEA evolves, PLACE does not

---

## Resolved Reviewer Questions

1. **Downgrade vs Reject**: Use downgrade. When a `mcp-agent` or
   `remote-host` claims a privileged thought type such as `DECISION`, the
   router returns the nearest safe downgraded route (`CRITIQUE`/`idea`) and
   marks the decision with `claimed-thoughttype-downgraded`. Reject only if
   no safe downgraded kind exists.

2. **DOWNGRADE_MAP semantics**: Use a static map for Stage 2. It is
   auditable, deterministic, and consistent with the router-as-policy
   boundary. Add downgrade eval fixtures and telemetry so we can decide
   later whether a small LLM helper is needed to choose the closest valid
   downgraded ThoughtType.

3. **mcp-agent default audit**: Audit `mcp-agent` only on denial in Stage 2.
   Allowed `mcp-agent` submits increment telemetry but do not append audit
   lines. Keep an inline telemetry note so we can decide later whether every
   `mcp-agent` submit should be audited despite log volume.

4. **Trunk classifier confidence threshold**: Defer the threshold. Stage 2
   accepts the current classifier confidence floor and records confidence,
   classifier source, downgrade, denial, and resubmit/correction telemetry.
   Use real usage to decide whether a >0.7 threshold, trunk-5 fallback, or
   other policy is justified.

5. **`source` field semantics**: Defer source-aware trust/routing. Treat
   `source` as untrusted metadata in Stage 2 because it is forgeable without
   signing or attestation. Record `source` in decision telemetry so real
   usage can tell us whether a signed source model is worth designing.
