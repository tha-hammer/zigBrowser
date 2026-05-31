---
date: 2026-04-30T10:50:00-04:00
revised: 2026-04-30T11:30:00-04:00
planner: Algorithm (council R5 → TDD plan)
revisions:
  - 2026-04-30T11:30:00-04:00 — applied review feedback from 2026-04-30-10-50-kindguard-tdd-plan-REVIEW.md (12 warnings + tier rename consolidation)
  - 2026-04-30T13:00:00-04:00 — FuchsiaBridge fix: KIND_TRUST.idea/stub mapped to 'remote-host' (was 'mcp-agent'). WindyRidge surfaced the inconsistency during B4 RED; both agents independently chose Option A. B2 mapping/code/test updated, B1 note rewritten, Resolution Index entry added. Plan and code commit are paired per FuchsiaBridge's "Plan markdown follow-up commit too" instruction.
repository: silmari-agent-memory
branch: main
topic: "kindGuard — caller-trust-tiered kind assertion (forge vulnerability mitigation)"
type: tdd_plan
status: review_amended
methodology: test_driven_development
source_notes:
  - MEMORY/WORK/20260430-counsel-mcp-vs-local-sai/PRD.md (R5 finding zk-rp1y)
review_applied:
  - thoughts/searchable/shared/plans/2026-04-30-10-50-kindguard-tdd-plan-REVIEW.md
related_research:
  - thoughts/searchable/shared/research/2026-04-28-ultimate-mcp-server-silmari-mcp-algorithm-contracts.md
related_specs:
  - specs/MASTER-SYSTEM-DIAGRAM.md
  - specs/ultimate-mcp-memory.md
tags: [tdd, security, silmari-mcp, kind-guard, forge-vulnerability]
---

# kindGuard TDD Implementation Plan

## Review Resolution Index (2026-04-30 amendments)

The following table maps every warning from
`2026-04-30-10-50-kindguard-tdd-plan-REVIEW.md` to the section of this plan
that addresses it.

| Warning | Where addressed | Status |
|---|---|---|
| **C1** — MCP envelope wrapping invisible from B8 tests | B12-A wire-format test + Observable Behaviors envelope-wrapping bullet | ✅ Resolved |
| **C2** — No audit log entry for denied attempts | B3 `emitDenialAudit` + Observable Behaviors audit-visibility bullet + Open Questions §5 | ✅ Resolved |
| **C3** — Env-var name stability is implicit | B5 stable-interface code comment | ✅ Resolved |
| **I1** — `_kindguard-setup.ts` shape deferred | B11 §"I1 Mitigation" with full helper signature | ✅ Resolved |
| **I2** — `agentId` persistence is silent | B5 docstring "log-diagnostic only" + What We're NOT Doing entry | ✅ Resolved |
| **P1** — Concurrent env mutations across test suites | B5 testability-via-parameter pattern + B8 beforeEach save-restore + Open Questions §7 | ✅ Resolved |
| **P2** — Isolated-fixture cleanup not specified | B9 explicit `mkdtempSync`/`rmSync` afterEach pattern | ✅ Resolved |
| **D1** — Case sensitivity implicit | B5 strict-lowercase posture + B7 case-sensitivity tests + Open Questions §6 | ✅ Resolved |
| **D2** — `agentId` no length cap or charset filter | B5 `SAFE_AGENT_ID_RE` + `parseAgentId` + B7 charset/length tests | ✅ Resolved |
| **D3** — "any kind succeeds" overstates | Observable Behaviors edited to "any **valid** kind" | ✅ Resolved |
| **A1** — No threat-model section | New "Threat Model" section after "What We're NOT Doing" | ✅ Resolved |
| **A2** — End-to-end MCP wire format untested | B12-A wire-format test exercising the request-handler wrapping | ✅ Resolved |
| **Tier rename** (4-tier model) | Applied throughout — interim "Tier Naming Migration" section removed | ✅ Resolved |
| Suggested amendment: B10 atomicity bead-count check | B10 `listBeadsInFixture` before/after diff | ✅ Resolved |
| Suggested amendment: B11 pre-audit grep upfront | B11 §"Pre-Audit (DO THIS BEFORE STARTING B11)" with file list | ✅ Resolved |
| Suggested amendment: New Open Questions #5/#6 | Open Questions §5 (audit log), §6 (case sensitivity), §7 (concurrency) added | ✅ Resolved |
| **Post-implementation correction** (FuchsiaBridge fix 2026-04-30) — `idea`/`stub` mapped to wrong tier | 🔴 | WindyRidge discovered during B4 RED that the strict 4-tier hierarchy + `KIND_TRUST.idea/stub = 'mcp-agent'` made `remote-host` unable to assert ANY kind, contradicting B4's allow-path test. WindyRidge proposed Options A/B/C; FuchsiaBridge independently chose A. Fix landed: `KIND_TRUST.idea` and `KIND_TRUST.stub` are now `'remote-host'` (lowest tier; everyone clears `tierAtLeast(_, 'remote-host')`). B2 table + code block + new "anyone can write" sentence after the table; B1 `Note on remote-host` rewritten. Verified zero impact on B8-B12 wiring tests. | ✅ Resolved |

---

## Overview

`kindGuard` is the **L2 policy enforcement point** in a three-layer routing
service that closes a shippable-today forge vulnerability in the Silmari MCP
server. Stage 1 (this plan) lands the L2 validator and wires it into the
**legacy** `zk_save_card` / `zk_save_cards` entry points so the forge vector
at `apps/silmari-mcp/src/index.ts:551,567` is closed. Stage 2 (separate plan)
lands the L1 private `routeThought()` and L3 public `sai_route_thought` /
`sai_submit_thought` MCP tools that consume the same kindGuard.

**The architectural pattern:** server-side authority over claimed metadata.
Same pattern as OS syscalls (apps request access, kernel enforces),
admission controllers (specs submitted, mutated/validated before run),
DB row-level security, SPF/DKIM verifying claimed `From` headers. The model-
supplied `kind` and (Stage 2) `claimedThoughtType` are *untrusted hints* —
the server decides the effective route, never the caller.

The current vulnerability: `apps/silmari-mcp/src/index.ts:551` validates
incoming `kind` against the `VALID_CARD_KINDS` whitelist (`labels.ts:51`) but
performs **no caller authorization**. A subagent or external MCP caller can
forge `kind: "biblio"` today and land a card in the bibliography box that
downstream `derives-from` edges (`labels.ts:82`) treat as authoritative
source-of-truth. The same shape exists on the Ultimate side —
`MemoryType.SKILL = "skill"` is a string field, no signing.

This plan implements `apps/silmari-mcp/src/lib/kindGuard.ts` plus a unit test
suite, a surgical 2-site wiring into `index.ts` (legacy entry points), and a
Python-side env-var mirror at `silmari_compat.py:144`. It is **a prerequisite
for Stage 2** — the same kindGuard module will be invoked by the future
`routeThought()` private API and the public `sai_submit_thought` tool.

## Current State Analysis

### Key Discoveries

| Finding | Location | Significance |
|---|---|---|
| Kind validation is whitelist-only | `apps/silmari-mcp/src/index.ts:551` (`zk_save_card`) and `:567` (`zk_save_cards` batch) | `parseEnum(args.kind, VALID_CARD_KINDS, 'kind')` checks the value is *valid*, not that the *caller* is authorized to assert it |
| Biblio short-circuit predates kind check | `apps/silmari-mcp/src/index.ts:545-549` | `if (box === 'biblio') { ...saveCard({box:'biblio', kind:'biblio',...}) }` — biblio is asserted before parseEnum runs, must be guarded separately |
| 11 valid card kinds | `apps/silmari-mcp/src/lib/labels.ts:51-63` | `biblio, idea, hub, structure, register, fact, signal, learning, preference, decision, stub` |
| `dispatchTool` is exported and testable in isolation | `apps/silmari-mcp/src/index.ts:949` | `export { dispatchTool, ... }` — no need to spawn the full MCP server for behavior tests |
| Caller context is NOT threaded through dispatch today | `apps/silmari-mcp/src/index.ts:534` | `async function dispatchTool(name, args)` — only two parameters; no `caller` |
| Env-var pattern is well-established | `apps/silmari-mcp/src/lib/paths.ts:50` (`SILMARI_DIR`), `apps/silmari-mcp/src/index.ts:78` (`SILMARI_BR_SYNC_TIMEOUT_MS`), `apps/silmari-mcp/src/lib/br-adapter.ts:91` (`SILMARI_MEMORY_RUST_BINARY`) | Reading `SILMARI_CALLER_TIER` from env matches existing convention exactly |
| Python-side passthrough has zero auth | `vendor/ultimate_mcp_server/ultimate_mcp_server/tools/silmari_compat.py:144-165` | `call_silmari_tool` runs `silmari cli tool <name> <json>` with `os.environ` inherited; only check is the tool-name whitelist at `:150` |
| Test framework | `apps/silmari-mcp/tests/*.test.ts` using `bun:test` | `mcp-tool-description.test.ts:14` shows direct dynamic-import pattern for dispatchTool unit tests; `sai-compat-noninterference.test.ts:42-62` shows CLI-spawn fixture for env-isolated integration tests |

### Patterns to Follow

- **Direct dispatchTool tests** for unit behaviors: `import { dispatchTool } from '../src/index.js'`, call with mocked args, assert on result envelope.
- **CLI-spawn tests** for env-isolated integration: `Bun.spawn(['bun', 'src/cli.ts', ...args], { env: {...process.env, SILMARI_CALLER_TIER: '...'} })`.
- **Module-level env reads** (matching `paths.ts:50` etc.) — but for testability, kindGuard should re-read env on every call rather than caching at import.

## Desired End State

A new caller-trust-tiered authorization gate is enforced at every Silmari MCP
write path that asserts a `kind`. Forged `kind` claims from
under-privileged callers are rejected with a structured `E_KIND_FORGE` error
before any storage write. Existing test suite stays green; the existing
production callers keep working under their correct trust tier.

### Observable Behaviors

- **Privilege denied**: a `mcp-agent`- or `remote-host`-tier caller asserting
  `kind: "biblio"`, `kind: "register"`, `kind: "hub"`, `kind: "structure"`, or
  `kind: "preference"` receives an `E_KIND_FORGE` error and the bead is NOT
  written.
- **Privilege allowed**: a `system-hook`-tier caller asserting any **valid**
  kind succeeds. (Invalid kinds — values not in `VALID_CARD_KINDS` — still
  throw `invalid kind:` from `parseKindWithGuard`'s pre-check, regardless
  of tier.)
- **Tier hierarchy**: `system-hook > local-cli > mcp-agent > remote-host`.
  A higher tier can always assert a lower-tier kind.
- **Fail-closed default**: when `SILMARI_CALLER_TIER` is absent from env,
  the caller is treated as `mcp-agent` (least privilege among locally-
  invocable tiers; `remote-host` requires explicit signaling).
- **Fail-closed on invalid**: when `SILMARI_CALLER_TIER` is set to a value
  not in the tier enum (case-sensitive), the dispatch throws
  `E_KIND_GUARD_BAD_TIER` (does not silently fall through).
- **Fail-closed on malformed agentId**: when `SILMARI_CALLER_AGENT_ID` is
  set to a value that doesn't match `/^[\w.\-]{1,64}$/`, the dispatch
  throws `E_KIND_GUARD_BAD_AGENT_ID` (defends against log poisoning and
  ANSI-control-sequence injection).
- **Batch atomicity**: `zk_save_cards` rejects the *entire batch* on the
  first forged kind; no partial writes.
- **Audit visibility**: every denied attempt emits a `console.error` line
  to stderr containing `agentId`, `kind`, `requiredTier`, and timestamp.
  This is defense-in-depth — an attacker can't probe the gate silently.
  (Optional `MEMORY/SECURITY/security-events.jsonl` append is a follow-up
  question — see Open Questions §5.)
- **MCP envelope wrapping**: thrown errors from `dispatchTool` are caught
  by the `CallToolRequestSchema` handler at `index.ts:900-908` and wrapped
  as `errorResult("zk_save_card: E_KIND_FORGE: <details>")`. Production
  callers (the silmari CLI Client at `cli.ts:12`, the Python bridge at
  `silmari_compat.py:144-165`) see the wrapped form; the `E_KIND_FORGE`
  substring remains stable for log scrapers.

## What We're NOT Doing

| Out of scope | Reason |
|---|---|
| Threading `Caller` through dispatchTool's signature | Surgical change; env-var resolution at the gate site is sufficient and matches the Python mirror |
| Per-bead-id authorization (rate limits, who-wrote-what audit logs) | Out of scope for the forge gate; logging is downstream concern |
| Stdio peer-uid / mTLS CN identity binding | Stage 2 hardening; current slice ships env-var-based identity |
| Refactoring `parseEnum` itself | Surgical insertion — leave the existing helper untouched |
| Persisting `agentId` as a card label or audit-log field | `agentId` is for log diagnostics ONLY in this slice. If/when audit-as-card is wanted, it's a separate commit |
| Mirror enforcement on Ultimate's UMS `MemoryType` writes | Different store, different bridge — separate plan; this plan only mirrors the env-var read at `silmari_compat.py:144` so the Python bridge fails-closed when downstream gate exists |
| Blocking the existing test suite | Existing tests that assert forbidden-at-`mcp-agent` kinds will set `SILMARI_CALLER_TIER='system-hook'` in their env explicitly (see B11 pre-audit) |
| Appending denial events to `MEMORY/SECURITY/security-events.jsonl` | Stretch goal — the existing event-emitter at `SAI/hooks/lib/event-emitter.ts` exists; deferred until after `console.error` is in production for ≥1 week |

## Threat Model

**kindGuard defends against same-trust-boundary forgery.** Specifically:

- A subagent invoked by the Algorithm or a workflow tool that is technically
  allowed to call MCP but should not be authoritative for `biblio`, `register`,
  `hub`, `structure`, or `preference` kinds.
- A `remote-host` caller (Cursor, Codex, Gemini) submitting writes through
  the silmari MCP — these clients run outside the user's trusted hook process
  and must not be able to claim system-tier kinds.
- Log poisoning via malformed `SILMARI_CALLER_AGENT_ID` (10MB blobs, ANSI
  control sequences) — defended by the `SAFE_AGENT_ID_RE` charset+length guard.

**kindGuard does NOT defend against:**

- **Process-level attacks.** Any process that can spawn the silmari CLI and
  set its own env can declare itself `system-hook`. There is no cryptographic
  binding between caller identity and process credentials in this slice.
  Cross-process identity (peer-uid for stdio, mTLS CN for HTTP/streamable)
  is Stage 2.
- **Insider modifications to the route table.** Editing `KIND_TRUST` in code
  is a code change with the usual review path. kindGuard does not protect
  against a malicious commit.
- **Replays.** If an attacker captures a legitimate request and replays it,
  this gate cannot detect that. Idempotency / nonce schemes are out of scope.
- **Timing attacks on the policy decision.** The `tierAtLeast` check is
  constant-time-ish but not hardened. Not a concern for the current threat
  model.

This makes the gate's value precise: it converts what is currently a
**silent forge** (any caller can claim any kind) into a **loud denial**
(forbidden combinations throw with structured error codes that audit
tooling can scrape). That's the entire defense.

## Testing Strategy

- **Framework**: `bun:test`
- **Run command**: `bun test apps/silmari-mcp/tests/kindGuard.test.ts` (focused), `bun test apps/silmari-mcp` (full module sweep)
- **Test types**:
  - Unit tests against the new `kindGuard.ts` module (B1-B7)
  - Direct `dispatchTool` integration tests for the wiring (B8-B10)
  - Whole-suite regression sweep (B11)
  - One CLI-spawn integration test confirming env-var path works end-to-end (B8 cross-check)
- **Test isolation**: each test that touches `process.env.SILMARI_CALLER_TIER` saves and restores the prior value in `afterEach`.

---

## Behavior 1: Tier Comparison Primitive

### Test Specification

**Given**: trust tiers ordered `system > algorithm > subagent`
**When**: `tierAtLeast(have, required)` is called
**Then**: returns `true` iff `have` is at or above `required`

**Edge Cases**:
- All 9 ordered pairs of (have, required) tested
- Same-tier comparisons return `true`

### TDD Cycle

#### 🔴 Red: Failing Test

**File**: `apps/silmari-mcp/tests/kindGuard.test.ts`

```ts
import { describe, it, expect } from 'bun:test';
import { tierAtLeast } from '../src/lib/kindGuard.js';

describe('tierAtLeast', () => {
  it('system-hook meets every tier', () => {
    expect(tierAtLeast('system-hook', 'system-hook')).toBe(true);
    expect(tierAtLeast('system-hook', 'local-cli')).toBe(true);
    expect(tierAtLeast('system-hook', 'mcp-agent')).toBe(true);
    expect(tierAtLeast('system-hook', 'remote-host')).toBe(true);
  });
  it('local-cli meets local-cli and below', () => {
    expect(tierAtLeast('local-cli', 'system-hook')).toBe(false);
    expect(tierAtLeast('local-cli', 'local-cli')).toBe(true);
    expect(tierAtLeast('local-cli', 'mcp-agent')).toBe(true);
    expect(tierAtLeast('local-cli', 'remote-host')).toBe(true);
  });
  it('mcp-agent meets mcp-agent and remote-host', () => {
    expect(tierAtLeast('mcp-agent', 'system-hook')).toBe(false);
    expect(tierAtLeast('mcp-agent', 'local-cli')).toBe(false);
    expect(tierAtLeast('mcp-agent', 'mcp-agent')).toBe(true);
    expect(tierAtLeast('mcp-agent', 'remote-host')).toBe(true);
  });
  it('remote-host meets only remote-host', () => {
    expect(tierAtLeast('remote-host', 'system-hook')).toBe(false);
    expect(tierAtLeast('remote-host', 'local-cli')).toBe(false);
    expect(tierAtLeast('remote-host', 'mcp-agent')).toBe(false);
    expect(tierAtLeast('remote-host', 'remote-host')).toBe(true);
  });
});
```

Red reason: `kindGuard.ts` does not exist.

#### 🟢 Green: Minimal Implementation

**File**: `apps/silmari-mcp/src/lib/kindGuard.ts`

```ts
export type TrustTier = 'system-hook' | 'local-cli' | 'mcp-agent' | 'remote-host';

const TIER_RANK: Record<TrustTier, number> = {
  'remote-host': 0,
  'mcp-agent': 1,
  'local-cli': 2,
  'system-hook': 3,
};

export function tierAtLeast(have: TrustTier, required: TrustTier): boolean {
  return TIER_RANK[have] >= TIER_RANK[required];
}
```

**Tier semantics** (from the architectural synthesis):

| Tier | Source | Privilege |
|---|---|---|
| `system-hook` | Claude Code lifecycle hooks (in-process TS) | Can assert privileged kinds; passes privileged context |
| `local-cli` | Algorithm CLI runner, `silmari` CLI | Can request privileged kinds; still validated |
| `mcp-agent` | Subagent or LLM-callable MCP client (in-process) | Untrusted hints only — kind is advisory |
| `remote-host` | Non-Claude MCP host (Cursor / Codex / Gemini) | Most constrained; audit required (Stage 2 enhancement) |

**Note on `remote-host` (FuchsiaBridge fix 2026-04-30)**: Stage 1 keeps the
strict 4-tier hierarchy `system-hook > local-cli > mcp-agent > remote-host`.
Under that hierarchy, `remote-host` callers can only assert kinds whose
required tier is `remote-host` itself — that's `idea` and `stub` (the most-
permissive kinds). They are **denied** from `mcp-agent`-or-higher kinds.
The KIND_TRUST table is the source of truth for which kinds reach which
tiers; an earlier draft of this plan placed `idea`/`stub` at `mcp-agent`,
which made the four-tier hierarchy collapse for assertion purposes
(remote-host could assert nothing). The fix puts the most-permissive kinds
at the lowest required tier so the hierarchy stays meaningful end-to-end.

Stage 2 will add **mandatory audit logging** for every `remote-host` write
regardless of kind — that's a separate concern from forge prevention.

#### 🔵 Refactor

None — function is already minimal and pure.

### Success Criteria

**Automated:**
- [ ] Red fails: `kindGuard.ts` does not export `tierAtLeast`
- [ ] Green passes: `bun test apps/silmari-mcp/tests/kindGuard.test.ts`
- [ ] Typecheck: `cd apps/silmari-mcp && bunx tsc --noEmit`

---

## Behavior 2: KIND_TRUST Mapping is Exhaustive

### Test Specification

**Given**: 11 `CardKind` values from `labels.ts:51`
**When**: `KIND_TRUST` is read
**Then**: every `CardKind` has an explicit `TrustTier` assignment; no missing keys

**Proposed mapping** (open for review during code review — these are starting tiers, not gospel):

| Kind | Required Tier | Rationale |
|---|---|---|
| `biblio` | `system-hook` | Source-of-truth box; downstream `derives-from` edges treat as authoritative |
| `register` | `system-hook` | Trunk-level register beads — infrastructure |
| `hub` | `system-hook` | Cross-cutting canon nodes |
| `structure` | `system-hook` | Structure notes (organizational scaffolding) |
| `preference` | `system-hook` | User preferences inherit forward; not casually-assertable |
| `decision` | `local-cli` | Algorithm-EXECUTE decisions (Algorithm CLI is the writer) |
| `learning` | `local-cli` | Algorithm-LEARN reflections |
| `fact` | `local-cli` | Algorithm-EXECUTE durable facts |
| `signal` | `local-cli` | Algorithm-THINK / VERIFY surprises |
| `idea` | `remote-host` | Open-ended thoughts — anyone can write (lowest tier; `tierAtLeast(any, 'remote-host')` is true) |
| `stub` | `remote-host` | Placeholders / TODOs — anyone can write |

> **Note**: `idea` and `stub` are gated at `remote-host` rather than `mcp-agent`
> because the rationale "anyone can write" includes the lowest tier. Higher tiers
> clear the bar transitively. (FuchsiaBridge fix 2026-04-30 — preserves the strict
> 4-tier hierarchy; an earlier draft inverted this and made remote-host unable to
> assert any kind, contradicting B4's allow-path test.)

### TDD Cycle

#### 🔴 Red: Failing Test

```ts
import { VALID_CARD_KINDS, type CardKind } from '../src/lib/labels.js';
import { KIND_TRUST } from '../src/lib/kindGuard.js';

describe('KIND_TRUST mapping', () => {
  it('covers every CardKind', () => {
    for (const kind of VALID_CARD_KINDS) {
      expect(KIND_TRUST[kind]).toBeDefined();
    }
  });
  it('has no extra entries', () => {
    const known = new Set<string>(VALID_CARD_KINDS);
    for (const k of Object.keys(KIND_TRUST)) {
      expect(known.has(k)).toBe(true);
    }
  });
  it('assigns the documented tiers', () => {
    expect(KIND_TRUST.biblio).toBe('system-hook');
    expect(KIND_TRUST.register).toBe('system-hook');
    expect(KIND_TRUST.hub).toBe('system-hook');
    expect(KIND_TRUST.structure).toBe('system-hook');
    expect(KIND_TRUST.preference).toBe('system-hook');
    expect(KIND_TRUST.decision).toBe('local-cli');
    expect(KIND_TRUST.learning).toBe('local-cli');
    expect(KIND_TRUST.fact).toBe('local-cli');
    expect(KIND_TRUST.signal).toBe('local-cli');
    expect(KIND_TRUST.idea).toBe('remote-host');
    expect(KIND_TRUST.stub).toBe('remote-host');
  });
});
```

#### 🟢 Green

```ts
import { type CardKind } from './labels.js';

export const KIND_TRUST: Record<CardKind, TrustTier> = {
  biblio: 'system-hook',
  register: 'system-hook',
  hub: 'system-hook',
  structure: 'system-hook',
  preference: 'system-hook',
  decision: 'local-cli',
  learning: 'local-cli',
  fact: 'local-cli',
  signal: 'local-cli',
  // FuchsiaBridge fix (2026-04-30): idea/stub require the LOWEST tier
  // (remote-host) so every caller can assert them. Previously these were
  // mapped to 'mcp-agent', which under the strict hierarchy
  // (system-hook > local-cli > mcp-agent > remote-host) would mean
  // remote-host callers could not assert ANY kind — making B4's
  // "permits remote-host caller asserting stub" test unreachable.
  // Mapping these at 'remote-host' tier means tierAtLeast(<any>, 'remote-host')
  // is always true, so the most-permissive kinds are universally assertable.
  idea: 'remote-host',
  stub: 'remote-host',
};
```

The `Record<CardKind, TrustTier>` type ensures TypeScript will refuse compilation if a CardKind is added to `labels.ts:51` without a corresponding KIND_TRUST entry — that's the **compile-time half of exhaustiveness**.

#### 🔵 Refactor

None.

### Success Criteria

- [ ] Red fails: KIND_TRUST not exported
- [ ] Green passes: all three `it` blocks
- [ ] **Compile-time exhaustiveness check**: deleting any KIND_TRUST entry should cause a tsc error in CI

---

## Behavior 3: assertKindAllowed Throws E_KIND_FORGE for Under-Tier Callers

### Test Specification

**Given**: caller `{agentId: 'sub-test', trustTier: 'mcp-agent'}` and kind `'biblio'` (system-hook tier required)
**When**: `assertKindAllowed('biblio', caller)` is called
**Then**: throws `Error` whose `message` starts with `E_KIND_FORGE` AND mentions both the agentId and the required tier

**Edge cases**:
- Same denial for `mcp-agent` asserting `register`, `hub`, `structure`, `preference`
- `local-cli`-tier caller is denied for `biblio`/`register`/`hub`/`structure`/`preference` (system-hook-only)
- `mcp-agent`-tier caller is denied for `decision`, `learning`, `fact`, `signal`
- `remote-host`-tier caller is denied for everything except `idea` and `stub`
- Denial emits a `console.error` line with structured fields (audit visibility)

### TDD Cycle

#### 🔴 Red

```ts
import { assertKindAllowed } from '../src/lib/kindGuard.js';

describe('assertKindAllowed — denial path', () => {
  it('throws E_KIND_FORGE when mcp-agent asserts biblio', () => {
    expect(() =>
      assertKindAllowed('biblio', { agentId: 'sub-1', trustTier: 'mcp-agent' }),
    ).toThrow(/^E_KIND_FORGE/);
  });
  it('error message names the agent and the required tier', () => {
    try {
      assertKindAllowed('biblio', { agentId: 'sub-1', trustTier: 'mcp-agent' });
    } catch (err) {
      expect((err as Error).message).toContain('sub-1');
      expect((err as Error).message).toContain('biblio');
      expect((err as Error).message).toContain('system-hook');
    }
  });
  it('emits console.error on denial (audit visibility)', () => {
    const spy = spyOn(console, 'error');
    expect(() =>
      assertKindAllowed('biblio', { agentId: 'sub-1', trustTier: 'mcp-agent' }),
    ).toThrow();
    expect(spy).toHaveBeenCalledWith(
      expect.stringMatching(/kindGuard\.deny.*agentId=sub-1.*kind=biblio.*requiredTier=system-hook/),
    );
    spy.mockRestore();
  });
  it.each([
    ['biblio', 'mcp-agent'], ['register', 'mcp-agent'], ['hub', 'mcp-agent'],
    ['structure', 'mcp-agent'], ['preference', 'mcp-agent'],
    ['decision', 'mcp-agent'], ['learning', 'mcp-agent'], ['fact', 'mcp-agent'],
    ['signal', 'mcp-agent'],
    ['biblio', 'local-cli'], ['register', 'local-cli'], ['hub', 'local-cli'],
    ['structure', 'local-cli'], ['preference', 'local-cli'],
    ['biblio', 'remote-host'], ['decision', 'remote-host'], ['fact', 'remote-host'],
  ])('denies %s to %s caller', (kind, tier) => {
    expect(() =>
      assertKindAllowed(kind as any, { agentId: 't', trustTier: tier as any }),
    ).toThrow(/^E_KIND_FORGE/);
  });
});
```

#### 🟢 Green

```ts
export interface Caller {
  agentId: string;
  trustTier: TrustTier;
}

function emitDenialAudit(kind: CardKind, caller: Caller, requiredTier: TrustTier): void {
  // Audit visibility — defense-in-depth so attackers cannot probe silently.
  // Format is stable for log scrapers.
  // Optional: future revision can additionally appendEvent() to
  // MEMORY/SECURITY/security-events.jsonl. See Open Questions §5.
  console.error(
    `kindGuard.deny ts=${new Date().toISOString()} agentId=${caller.agentId} ` +
    `tier=${caller.trustTier} kind=${kind} requiredTier=${requiredTier}`,
  );
}

export function assertKindAllowed(kind: CardKind, caller: Caller): void {
  const required = KIND_TRUST[kind];
  if (!tierAtLeast(caller.trustTier, required)) {
    emitDenialAudit(kind, caller, required);
    throw new Error(
      `E_KIND_FORGE: ${caller.agentId} (tier=${caller.trustTier}) cannot assert kind=${kind} (requires ${required})`,
    );
  }
}
```

#### 🔵 Refactor

Consider extracting the message format into a `formatForgeMessage` helper so
tests can assert structure rather than substring. **Defer** unless duplication
appears.

### Success Criteria

- [ ] Red fails: `assertKindAllowed` not exported
- [ ] All denial-path tests green (including the console.error spy)
- [ ] Error message format is stable enough for log scrapers
- [ ] `kindGuard.deny` audit line format is stable for log-scraping tools

---

## Behavior 4: assertKindAllowed Permits In-Tier Callers

### Test Specification

**Given**: caller meets-or-exceeds the required tier
**When**: `assertKindAllowed(kind, caller)`
**Then**: returns void without throwing

### TDD Cycle

#### 🔴 Red

```ts
describe('assertKindAllowed — allow path', () => {
  it('permits system-hook caller asserting biblio', () => {
    expect(() =>
      assertKindAllowed('biblio', { agentId: 'sys', trustTier: 'system-hook' }),
    ).not.toThrow();
  });
  it('permits local-cli caller asserting fact', () => {
    expect(() =>
      assertKindAllowed('fact', { agentId: 'alg', trustTier: 'local-cli' }),
    ).not.toThrow();
  });
  it('permits mcp-agent caller asserting idea', () => {
    expect(() =>
      assertKindAllowed('idea', { agentId: 'sub', trustTier: 'mcp-agent' }),
    ).not.toThrow();
  });
  it('permits remote-host caller asserting stub', () => {
    expect(() =>
      assertKindAllowed('stub', { agentId: 'cursor', trustTier: 'remote-host' }),
    ).not.toThrow();
  });
  it('permits system-hook caller asserting mcp-agent-tier kind', () => {
    expect(() =>
      assertKindAllowed('idea', { agentId: 'sys', trustTier: 'system-hook' }),
    ).not.toThrow();
  });
  it('does NOT emit console.error on allow path', () => {
    const spy = spyOn(console, 'error');
    assertKindAllowed('idea', { agentId: 'sub', trustTier: 'mcp-agent' });
    expect(spy).not.toHaveBeenCalled();
    spy.mockRestore();
  });
});
```

#### 🟢 Green

No new code — already passes from B3's implementation.

### Success Criteria

- [ ] All 4 allow-path tests green without modifying `assertKindAllowed`

---

## Behavior 5: resolveCallerFromEnv Reads SILMARI_CALLER_TIER

### Test Specification

**Given**: env (passed explicitly via parameter, NOT `process.env` mutation)
with `SILMARI_CALLER_TIER = 'local-cli'`
**When**: `resolveCallerFromEnv(env)` is called
**Then**: returns `{ agentId: <some non-empty string>, trustTier: 'local-cli' }`

The `agentId` is derived from `SILMARI_CALLER_AGENT_ID` if set, else defaults
to `'silmari-mcp-process'` so log lines have *something* identifying.
**`agentId` is for log diagnostics ONLY** in this slice — not persisted as a
card label, not appended to audit JSONL. (See "What We're NOT Doing".)

**Stable interface declaration**: `SILMARI_CALLER_TIER` and
`SILMARI_CALLER_AGENT_ID` are part of the silmari-mcp deployment contract.
A code comment marks them as such; renaming requires a deprecation cycle.

**Case-sensitivity posture (D1)**: tier values are **strict-lowercase
exact-match**. `SILMARI_CALLER_TIER='SYSTEM-HOOK'` throws
`E_KIND_GUARD_BAD_TIER` rather than normalizing. This catches typos
(`Algorithm`) before they silently degrade to default `mcp-agent`.

**agentId charset guard (D2)**: `SILMARI_CALLER_AGENT_ID` must match
`/^[\w.\-]{1,64}$/` (alphanumeric, underscore, dot, hyphen — 1 to 64 chars).
Defends against log poisoning (10MB blobs) and ANSI-control-sequence
injection. Malformed values throw `E_KIND_GUARD_BAD_AGENT_ID`.

**Concurrency posture (P1)**: tests inject env via the `resolveCallerFromEnv(env)`
parameter rather than mutating `process.env`. This avoids parallel-test flake
when `bun test apps/silmari-mcp` runs files concurrently. The CLI-spawn
integration test (B12 wire-format) is the only place that exercises the real
`process.env` path, and it spawns a fresh subprocess so isolation is automatic.

### TDD Cycle

#### 🔴 Red

```ts
import { resolveCallerFromEnv } from '../src/lib/kindGuard.js';

describe('resolveCallerFromEnv', () => {
  it('reads tier from env (parameter, not process.env)', () => {
    const c = resolveCallerFromEnv({ SILMARI_CALLER_TIER: 'local-cli' } as NodeJS.ProcessEnv);
    expect(c.trustTier).toBe('local-cli');
  });
  it('reads agentId from env when set', () => {
    const c = resolveCallerFromEnv({
      SILMARI_CALLER_TIER: 'local-cli',
      SILMARI_CALLER_AGENT_ID: 'algo-runner-42',
    } as NodeJS.ProcessEnv);
    expect(c.agentId).toBe('algo-runner-42');
  });
  it('defaults agentId when not set', () => {
    const c = resolveCallerFromEnv({ SILMARI_CALLER_TIER: 'system-hook' } as NodeJS.ProcessEnv);
    expect(c.agentId.length).toBeGreaterThan(0);
  });
  it('reads all four valid tiers', () => {
    expect(resolveCallerFromEnv({ SILMARI_CALLER_TIER: 'system-hook' } as any).trustTier).toBe('system-hook');
    expect(resolveCallerFromEnv({ SILMARI_CALLER_TIER: 'local-cli' } as any).trustTier).toBe('local-cli');
    expect(resolveCallerFromEnv({ SILMARI_CALLER_TIER: 'mcp-agent' } as any).trustTier).toBe('mcp-agent');
    expect(resolveCallerFromEnv({ SILMARI_CALLER_TIER: 'remote-host' } as any).trustTier).toBe('remote-host');
  });
});
```

#### 🟢 Green

```ts
// STABLE INTERFACE: SILMARI_CALLER_TIER and SILMARI_CALLER_AGENT_ID are
// part of the silmari-mcp deployment contract. Do not rename without a
// deprecation cycle. External callers (Algorithm CLI, Python bridge,
// future cross-LLM hosts) read these keys from their environment.
//
// Case-sensitivity: strict-lowercase exact-match. Typos throw rather
// than normalize — see Open Questions §6 for the rationale.
//
// agentId scope: log-diagnostic only in this slice. Not persisted as
// card label, not written to MEMORY/SECURITY/security-events.jsonl.
// See plan §"What We're NOT Doing".
const VALID_TIERS: readonly TrustTier[] = ['system-hook', 'local-cli', 'mcp-agent', 'remote-host'];
const SAFE_AGENT_ID_RE = /^[\w.\-]{1,64}$/;
const DEFAULT_AGENT_ID = 'silmari-mcp-process';

function parseTier(raw: string | undefined): TrustTier {
  if (raw === undefined || raw === '') return 'mcp-agent';  // see B6: least-privilege default
  if (!VALID_TIERS.includes(raw as TrustTier)) {
    throw new Error(
      `E_KIND_GUARD_BAD_TIER: SILMARI_CALLER_TIER=${raw} is not one of ${VALID_TIERS.join(',')} ` +
      `(values are case-sensitive lowercase)`,
    );
  }
  return raw as TrustTier;
}

function parseAgentId(raw: string | undefined): string {
  if (raw === undefined || raw === '') return DEFAULT_AGENT_ID;
  if (!SAFE_AGENT_ID_RE.test(raw)) {
    throw new Error(
      `E_KIND_GUARD_BAD_AGENT_ID: SILMARI_CALLER_AGENT_ID must match ${SAFE_AGENT_ID_RE.source} ` +
      `(got ${raw.length}-char value starting with ${JSON.stringify(raw.slice(0, 16))})`,
    );
  }
  return raw;
}

export function resolveCallerFromEnv(env: NodeJS.ProcessEnv = process.env): Caller {
  return {
    agentId: parseAgentId(env.SILMARI_CALLER_AGENT_ID),
    trustTier: parseTier(env.SILMARI_CALLER_TIER),
  };
}
```

The `env` parameter defaulting to `process.env` is the testability hook
AND the production hook for the wire-format integration test that spawns a
real subprocess.

#### 🔵 Refactor

`parseTier` and `parseAgentId` are already extracted. Consider promoting
`SAFE_AGENT_ID_RE` to a shared `paths.ts` or `validation.ts` if it's
needed elsewhere. **Defer.**

### Success Criteria

- [ ] All B5 tests green
- [ ] `env` parameter is exposed for B6/B7 tests to use without mutating real env
- [ ] Stable-interface comment is in place
- [ ] All four tier values round-trip through `parseTier`

---

## Behavior 6: Missing SILMARI_CALLER_TIER Defaults to mcp-agent (Least Privilege)

### Test Specification

**Given**: `SILMARI_CALLER_TIER` is absent from env
**When**: `resolveCallerFromEnv({})` is called (empty env passed explicitly)
**Then**: returns `{ trustTier: 'mcp-agent', ... }`

**Why mcp-agent and not throw**: log-and-degrade vs. fail-closed is a design
choice. Choosing **mcp-agent default** (least privilege among locally-
invocable tiers) over throwing because:
- Production hosts that haven't set the env yet shouldn't crash the MCP server
- `mcp-agent`-tier still permits the open-ended kinds (`idea`, `stub`) that
  most casual writes use
- Forge attempts (biblio, etc.) still fail closed via `assertKindAllowed`
- Documented behavior is auditable

**Why not `remote-host` as default**: `remote-host` is the most-constrained
tier and presumes Stage 2 audit hooks that don't exist yet in Stage 1. A
caller without `SILMARI_CALLER_TIER` is most likely a local subagent or
Algorithm-spawned process, not a non-Claude remote host. `remote-host` should
be set explicitly only by the deployment topology that knows it's serving a
remote MCP client.

### TDD Cycle

#### 🔴 Red

```ts
it('defaults to mcp-agent when env is empty', () => {
  const c = resolveCallerFromEnv({} as NodeJS.ProcessEnv);
  expect(c.trustTier).toBe('mcp-agent');
});
it('defaults to mcp-agent when SILMARI_CALLER_TIER is empty string', () => {
  const c = resolveCallerFromEnv({ SILMARI_CALLER_TIER: '' } as NodeJS.ProcessEnv);
  expect(c.trustTier).toBe('mcp-agent');
});
```

#### 🟢 Green

Already handled by B5's implementation (the `parseTier` falsy check returns
`'mcp-agent'`).

### Success Criteria

- [ ] Both tests pass without code changes

---

## Behavior 7: resolveCallerFromEnv Throws on Invalid SILMARI_CALLER_TIER

### Test Specification

**Given**: `SILMARI_CALLER_TIER` is set to a value not in
`{system-hook, local-cli, mcp-agent, remote-host}` (case-sensitive lowercase)
**When**: `resolveCallerFromEnv` is called
**Then**: throws `E_KIND_GUARD_BAD_TIER`

This prevents typos like `SILMARI_CALLER_TIER=sytem-hook` from silently
degrading to default `mcp-agent` (which would mask a misconfigured production
host). Case-sensitivity is **strict**: `SILMARI_CALLER_TIER='SYSTEM-HOOK'`
also throws (D1 posture: lowercase exact-match catches typos like `Algorithm`).

**Also tests `SILMARI_CALLER_AGENT_ID` charset guard (D2)**: a value like
`<10MB-of-bytes>` or one containing ANSI escapes throws
`E_KIND_GUARD_BAD_AGENT_ID`.

### TDD Cycle

#### 🔴 Red

```ts
describe('resolveCallerFromEnv — strict validation', () => {
  it('throws E_KIND_GUARD_BAD_TIER on unknown tier', () => {
    expect(() =>
      resolveCallerFromEnv({ SILMARI_CALLER_TIER: 'superuser' } as NodeJS.ProcessEnv),
    ).toThrow(/^E_KIND_GUARD_BAD_TIER/);
  });
  it('throws on typo (sytem-hook instead of system-hook)', () => {
    expect(() =>
      resolveCallerFromEnv({ SILMARI_CALLER_TIER: 'sytem-hook' } as NodeJS.ProcessEnv),
    ).toThrow(/^E_KIND_GUARD_BAD_TIER/);
  });
  it('throws on uppercase variant (case-sensitive lowercase posture)', () => {
    expect(() =>
      resolveCallerFromEnv({ SILMARI_CALLER_TIER: 'SYSTEM-HOOK' } as NodeJS.ProcessEnv),
    ).toThrow(/^E_KIND_GUARD_BAD_TIER/);
    expect(() =>
      resolveCallerFromEnv({ SILMARI_CALLER_TIER: 'Local-CLI' } as NodeJS.ProcessEnv),
    ).toThrow(/^E_KIND_GUARD_BAD_TIER/);
  });
  it('error message contains the offending value AND the valid tier list', () => {
    try {
      resolveCallerFromEnv({ SILMARI_CALLER_TIER: 'superuser' } as NodeJS.ProcessEnv);
    } catch (err) {
      const msg = (err as Error).message;
      expect(msg).toContain('superuser');
      expect(msg).toContain('system-hook');
      expect(msg).toContain('local-cli');
      expect(msg).toContain('mcp-agent');
      expect(msg).toContain('remote-host');
      expect(msg).toContain('case-sensitive');
    }
  });
  it('throws E_KIND_GUARD_BAD_AGENT_ID on agentId with control chars', () => {
    expect(() =>
      resolveCallerFromEnv({
        SILMARI_CALLER_TIER: 'mcp-agent',
        SILMARI_CALLER_AGENT_ID: 'evil\x1b[31mred\x1b[0m',  // ANSI escape
      } as NodeJS.ProcessEnv),
    ).toThrow(/^E_KIND_GUARD_BAD_AGENT_ID/);
  });
  it('throws E_KIND_GUARD_BAD_AGENT_ID on agentId over 64 chars', () => {
    expect(() =>
      resolveCallerFromEnv({
        SILMARI_CALLER_TIER: 'mcp-agent',
        SILMARI_CALLER_AGENT_ID: 'x'.repeat(65),
      } as NodeJS.ProcessEnv),
    ).toThrow(/^E_KIND_GUARD_BAD_AGENT_ID/);
  });
  it('accepts valid agentIds (alphanumeric, dot, hyphen, underscore, ≤64)', () => {
    expect(resolveCallerFromEnv({
      SILMARI_CALLER_TIER: 'mcp-agent',
      SILMARI_CALLER_AGENT_ID: 'algo-runner_42.beta',
    } as NodeJS.ProcessEnv).agentId).toBe('algo-runner_42.beta');
  });
});
```

#### 🟢 Green

Already handled by B5's `parseTier` and `parseAgentId` helpers.

### Success Criteria

- [ ] All 7 strict-validation tests green
- [ ] Error message contains the offending value AND the valid tier list AND
      the words "case-sensitive"
- [ ] Charset guard rejects ANSI escapes and over-length values

---

## Behavior 8: dispatchTool zk_save_card Rejects Forged Kind from mcp-agent

### Test Specification

**Given**: env is unset (defaults to `mcp-agent`), dispatchTool args claim `kind: 'biblio'`
**When**: `dispatchTool('zk_save_card', { body: 'forged', kind: 'biblio' })`
**Then**: throws an `Error` with message containing `E_KIND_FORGE`. The
production-visible form (after `CallToolRequestSchema` wrapping at
`index.ts:900-908`) is `errorResult("zk_save_card: E_KIND_FORGE: ...")`,
asserted in B12 wire-format integration test. Either way, `saveCard` is
NOT invoked.

### TDD Cycle

#### 🔴 Red

```ts
import { dispatchTool } from '../src/index.js';
import { describe, it, expect, beforeEach, afterEach } from 'bun:test';

describe('dispatchTool zk_save_card kindGuard wiring', () => {
  // P1 mitigation: save+restore real process.env around each test
  // because dispatchTool reads process.env at call time. Tests in this
  // file are NOT safe to parallelize across process.env mutations;
  // run with `bun test --serial` OR refactor dispatchTool to accept
  // an optional env (deferred — see Open Questions §5).
  let originalTier: string | undefined;
  let originalAgent: string | undefined;
  beforeEach(() => {
    originalTier = process.env.SILMARI_CALLER_TIER;
    originalAgent = process.env.SILMARI_CALLER_AGENT_ID;
    delete process.env.SILMARI_CALLER_TIER;     // default → mcp-agent
    delete process.env.SILMARI_CALLER_AGENT_ID;
  });
  afterEach(() => {
    if (originalTier === undefined) delete process.env.SILMARI_CALLER_TIER;
    else process.env.SILMARI_CALLER_TIER = originalTier;
    if (originalAgent === undefined) delete process.env.SILMARI_CALLER_AGENT_ID;
    else process.env.SILMARI_CALLER_AGENT_ID = originalAgent;
  });

  it('rejects forged biblio from mcp-agent caller', async () => {
    await expect(
      dispatchTool('zk_save_card', { body: 'forged biblio', kind: 'biblio' }),
    ).rejects.toThrow(/E_KIND_FORGE/);
  });
  it('rejects forged register from mcp-agent caller', async () => {
    await expect(
      dispatchTool('zk_save_card', { body: 'forged register', kind: 'register', trunk: 5 }),
    ).rejects.toThrow(/E_KIND_FORGE/);
  });
  it('rejects forged hub/structure/preference from mcp-agent', async () => {
    for (const kind of ['hub', 'structure', 'preference']) {
      await expect(
        dispatchTool('zk_save_card', { body: 'forged', kind, trunk: 5 }),
      ).rejects.toThrow(/E_KIND_FORGE/);
    }
  });
  it('rejects forged decision/learning/fact/signal from mcp-agent', async () => {
    for (const kind of ['decision', 'learning', 'fact', 'signal']) {
      await expect(
        dispatchTool('zk_save_card', { body: 'forged', kind, trunk: 5 }),
      ).rejects.toThrow(/E_KIND_FORGE/);
    }
  });
});
```

**Note on wiring sequence**: the existing `parseEnum(args.kind, VALID_CARD_KINDS, 'kind')` at `:551` runs *after* the biblio short-circuit at `:545-549`. So:
- For the biblio case, the kindGuard call must happen AT or BEFORE `:545` so the `box === 'biblio'` branch is also gated.
- For non-biblio kinds, kindGuard is invoked as part of the kind parse helper at `:551` and `:567`.

#### 🟢 Green

**File**: `apps/silmari-mcp/src/lib/kindGuard.ts` — add a one-shot helper:

```ts
export function parseKindWithGuard(
  rawKind: unknown,
  caller: Caller,
  field: string,
): CardKind {
  if (typeof rawKind !== 'string' || !(VALID_CARD_KINDS as readonly string[]).includes(rawKind)) {
    throw new Error(`invalid ${field}: ${String(rawKind)} (must be one of ${VALID_CARD_KINDS.join(',')})`);
  }
  const kind = rawKind as CardKind;
  assertKindAllowed(kind, caller);
  return kind;
}
```

**File**: `apps/silmari-mcp/src/index.ts` — add at module scope after imports:

```ts
import { resolveCallerFromEnv, assertKindAllowed, parseKindWithGuard } from './lib/kindGuard.js';
```

Then refactor the relevant block at `:534-558`:

```ts
case 'zk_save_card': {
  const body = String(args.body ?? '');
  if (!body) throw new Error('body is required');
  const caller = resolveCallerFromEnv();
  const box = parseBox(args.box);
  const status = parseEnumOptional(args.status, STATUS_ENUM, 'status') as CardStatus | undefined;
  const scope = args.scope as string | undefined;
  const source = args.source as string | undefined;
  if (box === 'biblio') {
    if (args.fromAddress) throw new Error('fromAddress is only valid for idea box saves');
    assertKindAllowed('biblio', caller);  // ← NEW: gate biblio short-circuit
    const result = saveCard({ box: 'biblio', body, kind: 'biblio', scope, source, status });
    if (!result) throw new Error('saveCard (biblio) failed');
    return okResult(result);
  }
  const kind = parseKindWithGuard(args.kind, caller, 'kind');  // ← REPLACES parseEnum
  const trunk = parseTrunk(args.trunk);
  const mode = (parseEnumOptional(args.mode, MODE_ENUM, 'mode') ?? 'continue') as FolgezettelMode;
  const fromAddress = args.fromAddress as string | undefined;
  const result = saveCard({ box: 'idea', body, kind, trunk, mode, fromAddress, scope, source, status });
  if (!result) throw new Error('saveCard (idea) failed');
  return okResult(result);
}
```

#### 🔵 Refactor

The `caller` resolution happens once per dispatch. If hot-path latency
matters, cache it module-level — but the env read is microseconds and the
mutability matters for tests.

### Success Criteria

- [ ] All 4 forge-attempt test cases fail before wiring
- [ ] All 4 pass after wiring
- [ ] No `saveCard` side-effects when forge is rejected (verified in B10
      with explicit before/after fixture-bead-count assertions)

---

## Behavior 9: dispatchTool zk_save_card Permits Allowed Kinds

### Test Specification

**Given**: `mcp-agent`-tier caller (env unset → default), `kind: 'idea'`, valid trunk + body
**When**: `dispatchTool('zk_save_card', { kind: 'idea', body: 'ok', trunk: 5 })`
**Then**: returns `okResult` containing a `SaveCardResult` (no throw, no error envelope); fixture store has exactly one new card

### TDD Cycle

#### 🔴 Red

```ts
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

describe('dispatchTool zk_save_card permits allowed kinds', () => {
  let TMP_STORE: string;
  let originalSilmariDir: string | undefined;
  let originalBiblioDir: string | undefined;
  let originalIdeaDir: string | undefined;
  let originalTier: string | undefined;

  beforeEach(() => {
    // P2: Isolated fixture per the sai-compat-noninterference.test.ts pattern.
    // Each test gets a fresh tmp store so saves don't accumulate across tests
    // and don't pollute the developer's ~/.silmari-memory.
    TMP_STORE = mkdtempSync(join(tmpdir(), 'silmari-kindguard-'));
    originalSilmariDir = process.env.SILMARI_DIR;
    originalBiblioDir = process.env.SILMARI_BIBLIO_DIR;
    originalIdeaDir = process.env.SILMARI_IDEA_DIR;
    originalTier = process.env.SILMARI_CALLER_TIER;
    process.env.SILMARI_DIR = TMP_STORE;
    process.env.SILMARI_BIBLIO_DIR = join(TMP_STORE, 'box1-biblio', '.beads');
    process.env.SILMARI_IDEA_DIR = join(TMP_STORE, 'box2-ideas', '.beads');
    delete process.env.SILMARI_CALLER_TIER;  // default → mcp-agent
  });

  afterEach(() => {
    rmSync(TMP_STORE, { recursive: true, force: true });
    if (originalSilmariDir === undefined) delete process.env.SILMARI_DIR;
    else process.env.SILMARI_DIR = originalSilmariDir;
    if (originalBiblioDir === undefined) delete process.env.SILMARI_BIBLIO_DIR;
    else process.env.SILMARI_BIBLIO_DIR = originalBiblioDir;
    if (originalIdeaDir === undefined) delete process.env.SILMARI_IDEA_DIR;
    else process.env.SILMARI_IDEA_DIR = originalIdeaDir;
    if (originalTier === undefined) delete process.env.SILMARI_CALLER_TIER;
    else process.env.SILMARI_CALLER_TIER = originalTier;
  });

  it('permits idea kind from mcp-agent caller', async () => {
    const result = await dispatchTool('zk_save_card', {
      body: 'mcp-agent-tier idea card',
      kind: 'idea',
      trunk: 5,
    });
    expect(result).not.toHaveProperty('isError');
    const payload = JSON.parse((result.content[0] as any).text);
    expect(payload.id).toMatch(/^zk-/);
    expect(payload.fz).toMatch(/^\d+\//);
  });

  it('permits stub kind from mcp-agent caller', async () => {
    const result = await dispatchTool('zk_save_card', {
      body: 'mcp-agent-tier stub card',
      kind: 'stub',
      trunk: 5,
    });
    expect(result).not.toHaveProperty('isError');
  });

  it('permits remote-host caller asserting idea or stub', async () => {
    process.env.SILMARI_CALLER_TIER = 'remote-host';
    const result = await dispatchTool('zk_save_card', {
      body: 'remote host idea',
      kind: 'idea',
      trunk: 5,
    });
    expect(result).not.toHaveProperty('isError');
  });
});
```

#### 🟢 Green

No new code beyond B8.

### Success Criteria

- [ ] All three `it` blocks green; each fixture is cleaned up after the test
- [ ] No leakage to `~/.silmari-memory` (verified manually first run, then trusted)
- [ ] Result envelope shape matches existing `zk_save_card` callers

---

## Behavior 10: zk_save_cards Rejects Whole Batch on Any Forged Kind

### Test Specification

**Given**: `mcp-agent`-tier caller, batch contains one valid `idea` card and one forged `biblio` card
**When**: `dispatchTool('zk_save_cards', { cards: [...] })`
**Then**: throws `E_KIND_FORGE` BEFORE any card is written; the valid card is NOT persisted (atomicity verified by bead-count diff)

### TDD Cycle

#### 🔴 Red

```ts
import { listBeadsInFixture } from './_helpers/list-beads.js';  // small utility

describe('dispatchTool zk_save_cards atomicity', () => {
  // Reuse the isolated-fixture beforeEach/afterEach from B9. Helper
  // listBeadsInFixture(TMP_STORE) reads box2-ideas and returns bead ids.

  it('rejects entire batch on any forged kind, no partial writes', async () => {
    const beadsBefore = listBeadsInFixture(TMP_STORE);
    await expect(
      dispatchTool('zk_save_cards', {
        cards: [
          { body: 'legit idea', kind: 'idea', trunk: 5 },
          { body: 'forged biblio', kind: 'biblio', trunk: 5 },
        ],
      }),
    ).rejects.toThrow(/E_KIND_FORGE/);

    // Atomicity: the legit idea card must NOT have been persisted.
    const beadsAfter = listBeadsInFixture(TMP_STORE);
    expect(beadsAfter).toHaveLength(beadsBefore.length);
  });

  it('forge in any position rejects whole batch', async () => {
    // First-position forge
    await expect(
      dispatchTool('zk_save_cards', {
        cards: [
          { body: 'forged register', kind: 'register', trunk: 5 },
          { body: 'legit', kind: 'idea', trunk: 5 },
        ],
      }),
    ).rejects.toThrow(/E_KIND_FORGE/);
    // Last-position forge
    await expect(
      dispatchTool('zk_save_cards', {
        cards: [
          { body: 'legit-1', kind: 'idea', trunk: 5 },
          { body: 'legit-2', kind: 'idea', trunk: 5 },
          { body: 'forged hub', kind: 'hub', trunk: 5 },
        ],
      }),
    ).rejects.toThrow(/E_KIND_FORGE/);
  });
});
```

#### 🟢 Green

Modify `index.ts:560-578` (the `zk_save_cards` case):

```ts
case 'zk_save_cards': {
  const raw = args.cards;
  if (!Array.isArray(raw)) throw new Error('cards must be an array');
  if (raw.length === 0) return okResult([]);
  const caller = resolveCallerFromEnv();
  const cards: IdeaSaveCardOpts[] = raw.map((c, i) => {
    const body = String((c as any).body ?? '');
    if (!body) throw new Error(`cards[${i}].body is required`);
    const kind = parseKindWithGuard((c as any).kind, caller, `cards[${i}].kind`);  // ← gates each
    const trunk = parseTrunk((c as any).trunk);
    const mode = (parseEnumOptional((c as any).mode, MODE_ENUM, `cards[${i}].mode`) ?? 'continue') as FolgezettelMode;
    const fromAddress = (c as any).fromAddress as string | undefined;
    const scope = (c as any).scope as string | undefined;
    const source = (c as any).source as string | undefined;
    const status = parseEnumOptional((c as any).status, STATUS_ENUM, `cards[${i}].status`) as CardStatus | undefined;
    return { box: 'idea', body, kind, trunk, mode, fromAddress, scope, source, status };
  });
  const results = saveCardsBatch(cards);
  return okResult(results);
}
```

The throw inside `.map()` short-circuits BEFORE `saveCardsBatch` is called —
that's the atomicity guarantee. The existing test `zk-save-cards-batch.test.ts`
should keep passing because all valid-kind batches still go through.

#### 🔵 Refactor

None.

### Success Criteria

- [ ] Test green
- [ ] Existing `zk-save-cards-batch.test.ts` still green (no kind regressions)

---

## Behavior 11: Existing Test Suite Stays Green (Regression Gate)

### Test Specification

**Given**: every existing test under `apps/silmari-mcp/tests/`
**When**: `bun test apps/silmari-mcp` is run after kindGuard is wired
**Then**: zero regressions; every previously-passing test still passes

### Pre-Audit (DO THIS BEFORE STARTING B11)

The Engineer should run the grep below upfront and paste the file list into
this section before patching anything. This bounds the work to a known set
and collapses the time estimate from "30-90 min variable" to a tractable
fixture-by-fixture pass.

```bash
grep -rln \
  "kind:\s*['\"]biblio\|kind:\s*['\"]register\|kind:\s*['\"]hub\|kind:\s*['\"]structure\|kind:\s*['\"]preference\|kind:\s*['\"]decision\|kind:\s*['\"]learning\|kind:\s*['\"]fact\|kind:\s*['\"]signal" \
  apps/silmari-mcp/tests/
```

Expected hits (heuristic — confirm after running):

- `card-ops.test.ts` — likely lib-layer; doesn't go through dispatchTool, may not need env override
- `zk-save-card-fromaddress.test.ts` — likely needs `system-hook` for any non-`idea` kind
- `zk-save-cards-batch.test.ts` — same
- `integration.test.ts` — likely a mix; audit individual `it` blocks
- `extraction-hardening.test.ts`, `edge-extractors.test.ts`, `backfill-edges.test.ts` — cascade fixtures may save `fact`/`learning`/`signal`
- `recall-promote.test.ts` — promotes between statuses; kind handling unclear without reading
- `bootstrap-keyword-index.test.ts`, `keyword-index.test.ts`,
  `keyword-index-sqlite.test.ts`, `reconcile-keyword-index.test.ts` — lib-layer; likely fine
- `zk-recall-limit.test.ts` — recall doesn't write cards; should be unaffected
- `zk-propose-links-semantic.test.ts`, `semantic-proposer.test.ts` — proposers; check whether they assert privileged kinds
- `mcp-tool-description.test.ts` — description-only; no kind writes
- `hub-members.test.ts` — `hub` kind ⇒ needs `system-hook`
- `sai-compat-noninterference.test.ts` — already CLI-spawn pattern; add env injection
- `ultimate-compat-parity.test.ts` — same
- `cli-tool-bridge.test.ts`, `native-cli-contract.test.ts`,
  `native-mcp-dispatch-contract.test.ts`, `native-mode-routing.test.ts`,
  `native-mode-config-contract.test.ts`, `native-shadow-contract.test.ts`,
  `native-adapter.test.ts` — native-mode wiring; likely a mix
- `save-card-parity-snapshot.test.ts`, `savecard-concurrency.test.ts` —
  parity / concurrency; check kind usage
- `br-adapter.test.ts`, `br-sqlite.test.ts` — adapter-layer; likely below dispatchTool
- `edges.test.ts`, `folgezettel.test.ts`, `jsonl.test.ts`, `labels.test.ts`,
  `navigate.test.ts`, `trunks.test.ts`, `filter-by-keyword-overlap.test.ts` — lib-layer

### Strategy

For each file the pre-audit returns:

- **CLI-spawn tests** (use `Bun.spawn(['bun', 'src/cli.ts', ...])` with explicit `env` blocks): add `SILMARI_CALLER_TIER: 'system-hook'` to the env block.
- **Direct dispatchTool tests** (import from `'../src/index.js'`): wrap with the shared helper from `_kindguard-setup.ts` (see I1 below).
- **Lib-layer tests** (test `card-ops.ts`, `labels.ts`, etc. directly without dispatchTool): NO patch needed — they bypass the gate.

If a test legitimately needs to exercise a `mcp-agent`-tier path (e.g. forge
attempts), it should explicitly DO NOT set the env.

### I1 Mitigation: `_kindguard-setup.ts` Helper Shape

Declared upfront so multiple authors patch fixtures consistently:

**File**: `apps/silmari-mcp/tests/_kindguard-setup.ts`

```ts
/**
 * Test helper for kindGuard fixtures.
 *
 * Use elevateCallerTier()/restoreCallerTier() in beforeAll/afterAll to
 * exercise kinds that require system-hook or local-cli tier without
 * leaking the env override into other test files.
 *
 * NOT for use inside production code — this is a TEST-ONLY shim around
 * the SILMARI_CALLER_TIER env contract.
 *
 * Pattern:
 *   import { elevateCallerTier, restoreCallerTier } from './_kindguard-setup.js';
 *
 *   describe('my privileged-kind test', () => {
 *     beforeAll(() => elevateCallerTier('system-hook'));
 *     afterAll(() => restoreCallerTier());
 *     it('saves a biblio card', async () => { ... });
 *   });
 */
import type { TrustTier } from '../src/lib/kindGuard.js';

let savedTier: string | undefined;
let savedAgent: string | undefined;
let active = false;

export function elevateCallerTier(tier: TrustTier = 'system-hook', agentId = 'test-fixture'): void {
  if (active) {
    throw new Error('elevateCallerTier already active — nested calls are not supported');
  }
  savedTier = process.env.SILMARI_CALLER_TIER;
  savedAgent = process.env.SILMARI_CALLER_AGENT_ID;
  process.env.SILMARI_CALLER_TIER = tier;
  process.env.SILMARI_CALLER_AGENT_ID = agentId;
  active = true;
}

export function restoreCallerTier(): void {
  if (!active) return;
  if (savedTier === undefined) delete process.env.SILMARI_CALLER_TIER;
  else process.env.SILMARI_CALLER_TIER = savedTier;
  if (savedAgent === undefined) delete process.env.SILMARI_CALLER_AGENT_ID;
  else process.env.SILMARI_CALLER_AGENT_ID = savedAgent;
  active = false;
}
```

### TDD Cycle

This is a regression-prevention behavior, not a new feature behavior. The
"red" is "running `bun test apps/silmari-mcp` produces failures in
unexpected files"; the "green" is "every patched fixture sets the right
tier and the suite is fully green".

#### 🔴 Red

After wiring B8/B10, run `bun test apps/silmari-mcp` and capture the failure
list. Compare against the pre-audit list above.

#### 🟢 Green

For each failing file:
- Determine whether the test legitimately exercises a privileged kind.
- If yes: import `elevateCallerTier`/`restoreCallerTier` from `_kindguard-setup.ts` and use in `beforeAll`/`afterAll`. (CLI-spawn tests instead add `SILMARI_CALLER_TIER: 'system-hook'` to the env block.)
- If no: rewrite the fixture to use `idea` or `stub` (`mcp-agent`-tier).

#### 🔵 Refactor

`_kindguard-setup.ts` exists from the start (I1 mitigation). Look for
patterns where multiple tests in the same file always set the same tier —
consider hoisting the `beforeAll` to a `describe` block.

### Success Criteria

**Automated:**
- [ ] `bun test apps/silmari-mcp` exits 0 with the same test count as before
- [ ] No skipped tests
- [ ] New test files added: `kindGuard.test.ts` and `_kindguard-setup.ts` only

**Manual:**
- [ ] Code review confirms each patched test file legitimately needs the elevated tier
- [ ] No production callers (outside `tests/`) import `_kindguard-setup.ts`

---

## Behavior 12 (Lower Priority): Python-Side Mirror at silmari_compat.py:144

### Test Specification

**Given**: env var `SILMARI_CALLER_TIER` is set to `mcp-agent` (the production-default tier for non-Claude callers)
**When**: a Python caller invokes `await call_silmari_tool('zk_save_card', {'kind': 'biblio', 'body': 'x'})`
**Then**: the subprocess inherits the env, the TS-side kindGuard rejects, the `CallToolRequestSchema` handler at `index.ts:900-908` wraps the throw as `errorResult("zk_save_card: E_KIND_FORGE: <details>")`, the silmari CLI Client (`cli.ts:12`) exits non-zero with the wrapped message on stderr, and `call_silmari_tool` raises `SilmariBridgeError(message)` whose message contains `E_KIND_FORGE` as a substring.

### Why Lower Priority

The Python mirror is a *defense-in-depth* layer. The TS-side gate is the
primary defense. If TS gates correctly, the Python bridge inheriting
`os.environ` (current behavior at `silmari_compat.py:153`) is sufficient
because the env propagates and the TS process enforces. The mirror's
additional value is only:
- Failing fast on the Python side when the env is malformed (saves a
  subprocess spawn)
- Surfacing the forge attempt in Python logs immediately

Ship after B1-B11.

### Error-Path Diagram (additional discovery from the review)

The Python bridge does NOT call `dispatchTool` directly. The error path is:

```
TS dispatchTool throws E_KIND_FORGE
  → CallToolRequestSchema handler at index.ts:900-908 catches
    → returns errorResult(`${name}: ${msg}`)  // "zk_save_card: E_KIND_FORGE: ..."
  → MCP envelope: { isError: true, content: [{ type:'text', text:'zk_save_card: E_KIND_FORGE: ...' }] }
  → silmari CLI Client (apps/silmari-mcp/src/cli.ts) receives the envelope
    → prints text to stderr, exits non-zero
  → silmari_compat.py:162-164 reads stderr, raises SilmariBridgeError(detail)
```

The Python `match="E_KIND_FORGE"` substring assertion still works because
the wrapped message preserves the `E_KIND_FORGE` token. But the assertion
crosses the MCP envelope boundary, so any change to
`CallToolRequestSchema` wrapping at `index.ts:900-908` could affect the
Python integration test silently. B12-A (below) adds a TS-side wire-format
test that anchors the envelope shape so Python tests don't drift.

### TDD Cycle

#### 🔴 Red

**File**: `vendor/ultimate_mcp_server/tests/unit/test_silmari_compat.py`

```python
import pytest
from ultimate_mcp_server.tools.silmari_compat import call_silmari_tool, SilmariBridgeError

@pytest.mark.asyncio
async def test_call_silmari_tool_propagates_caller_tier(monkeypatch):
    """Python bridge sees E_KIND_FORGE through the wrapped envelope."""
    monkeypatch.setenv("SILMARI_CALLER_TIER", "mcp-agent")
    with pytest.raises(SilmariBridgeError, match="E_KIND_FORGE"):
        await call_silmari_tool("zk_save_card", {"kind": "biblio", "body": "x"})

@pytest.mark.asyncio
async def test_call_silmari_tool_rejects_malformed_tier_locally(monkeypatch):
    """Local fail-fast on malformed env saves a subprocess spawn."""
    monkeypatch.setenv("SILMARI_CALLER_TIER", "superuser")
    with pytest.raises(SilmariBridgeError, match="E_KIND_GUARD_BAD_TIER"):
        await call_silmari_tool("zk_save_card", {"kind": "biblio", "body": "x"})
```

#### 🟢 Green

Modify `silmari_compat.py:144-165`:

```python
async def call_silmari_tool(
    name: str,
    args: Mapping[str, Any] | None = None,
    *,
    timeout_seconds: float = DEFAULT_TIMEOUT_SECONDS,
) -> str:
    if name not in SILMARI_TOOL_NAMES:
        raise SilmariBridgeError(f"unknown Silmari compatibility tool: {name}")

    # B12 defense-in-depth: validate the env-var locally before spawning
    # to fail fast on malformed SILMARI_CALLER_TIER. The TS-side kindGuard
    # at apps/silmari-mcp/src/lib/kindGuard.ts is still the canonical gate;
    # this is a redundancy that surfaces config errors in Python logs
    # without paying for the subprocess.
    #
    # Tier names match the TS contract exactly (case-sensitive lowercase):
    # 'system-hook' | 'local-cli' | 'mcp-agent' | 'remote-host'.
    valid_tiers = {"system-hook", "local-cli", "mcp-agent", "remote-host"}
    raw_tier = os.environ.get("SILMARI_CALLER_TIER")
    if raw_tier is not None and raw_tier != "" and raw_tier not in valid_tiers:
        raise SilmariBridgeError(
            f"E_KIND_GUARD_BAD_TIER: SILMARI_CALLER_TIER={raw_tier} is not one of {sorted(valid_tiers)} "
            f"(values are case-sensitive lowercase)"
        )

    env = dict(os.environ)
    env["SILMARI_MCP_BACKEND"] = "typescript"
    # SILMARI_CALLER_TIER and SILMARI_CALLER_AGENT_ID propagate implicitly
    # via os.environ. The TS process re-validates them; this Python check
    # is local fast-fail, not source-of-truth.

    result = await run_process(
        resolve_silmari_bridge_command(),
        [str(silmari_cli_path()), "tool", name, compact_args(args)],
        timeout_seconds=timeout_seconds,
        env=env,
        cwd=repo_root(),
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        raise SilmariBridgeError(detail or f"silmari tool {name} failed")
    return result.stdout.strip()
```

### Success Criteria

- [ ] Python red tests fail before patch
- [ ] Python green tests pass after patch
- [ ] `cd vendor/ultimate_mcp_server && uv run pytest tests/unit/test_silmari_compat.py` exits 0
- [ ] Tier names in Python valid_tiers MATCH the TS `VALID_TIERS` exactly
      (cross-reference test in B12-A below catches drift)

---

## Integration & E2E Testing

### Behavior 12-A: MCP Envelope Wire-Format Test (A2 mitigation)

**Given**: a forged-kind dispatchTool call wrapped by the
`CallToolRequestSchema` handler at `index.ts:900-908`
**When**: the wrapping path executes
**Then**: the production-visible envelope is
`{ isError: true, content: [{ type:'text', text:'zk_save_card: E_KIND_FORGE: ...' }] }`
with the tool-name prefix exactly matching `^zk_save_card: E_KIND_FORGE:`

This test exists because B8 asserts at the dispatchTool boundary (the throw
path), but production callers — the silmari CLI Client and the Python
bridge — see the WRAPPED form. Without this test, a refactor of the request
handler could silently change the public-visible error format and break
downstream log scrapers and the B12 Python integration test.

**File**: `apps/silmari-mcp/tests/kindGuard-wire-format.test.ts`

```ts
import { describe, it, expect, beforeEach, afterEach } from 'bun:test';
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { CallToolRequestSchema } from '@modelcontextprotocol/sdk/types.js';
import { dispatchTool } from '../src/index.js';

// Reuse the same handler that index.ts main() registers; this is the
// single source of truth for the wrapping shape.
function makeWrappedHandler() {
  return async (request: { params: { name: string; arguments?: unknown } }) => {
    try {
      return await dispatchTool(request.params.name, (request.params.arguments ?? {}) as any);
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      return { isError: true, content: [{ type: 'text' as const, text: `${request.params.name}: ${msg}` }] };
    }
  };
}

describe('MCP envelope wire format for kindGuard denial', () => {
  let originalTier: string | undefined;
  beforeEach(() => {
    originalTier = process.env.SILMARI_CALLER_TIER;
    delete process.env.SILMARI_CALLER_TIER;
  });
  afterEach(() => {
    if (originalTier === undefined) delete process.env.SILMARI_CALLER_TIER;
    else process.env.SILMARI_CALLER_TIER = originalTier;
  });

  it('zk_save_card forge produces wrapped errorResult with tool-name prefix', async () => {
    const handler = makeWrappedHandler();
    const result = await handler({
      params: { name: 'zk_save_card', arguments: { body: 'forged', kind: 'biblio' } },
    });
    expect(result).toHaveProperty('isError', true);
    const text = (result.content[0] as any).text;
    expect(text).toMatch(/^zk_save_card: E_KIND_FORGE:/);
    expect(text).toContain('cannot assert kind=biblio');
    expect(text).toContain('requires system-hook');
  });

  it('zk_save_cards forge produces wrapped errorResult', async () => {
    const handler = makeWrappedHandler();
    const result = await handler({
      params: {
        name: 'zk_save_cards',
        arguments: { cards: [{ body: 'forged', kind: 'register', trunk: 5 }] },
      },
    });
    expect(result).toHaveProperty('isError', true);
    const text = (result.content[0] as any).text;
    expect(text).toMatch(/^zk_save_cards: E_KIND_FORGE:/);
  });
});
```

**Success criteria**:
- [ ] Wire-format prefix is stable: `^zk_save_card: E_KIND_FORGE:` and `^zk_save_cards: E_KIND_FORGE:` match
- [ ] Refactoring `CallToolRequestSchema` wrapping in `main()` triggers this test if the format changes

### Behavior 12-B: CLI-Spawn End-to-End Test

**File**: `apps/silmari-mcp/tests/kindGuard-cli.test.ts`

```ts
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const APP_DIR = join(dirname(fileURLToPath(import.meta.url)), '..');

describe('kindGuard CLI integration', () => {
  let TMP_STORE: string;
  beforeEach(() => {
    TMP_STORE = mkdtempSync(join(tmpdir(), 'silmari-kindguard-cli-'));
  });
  afterEach(() => {
    rmSync(TMP_STORE, { recursive: true, force: true });
  });

  it('forged biblio via CLI is rejected with wrapped envelope', async () => {
    const proc = Bun.spawn(['bun', 'src/cli.ts', 'tool', 'zk_save_card',
      '{"body":"forged","kind":"biblio"}'], {
      cwd: APP_DIR,
      env: {
        ...process.env,
        SILMARI_CALLER_TIER: 'mcp-agent',
        SILMARI_DIR: TMP_STORE,
        SILMARI_BIBLIO_DIR: join(TMP_STORE, 'box1-biblio', '.beads'),
        SILMARI_IDEA_DIR: join(TMP_STORE, 'box2-ideas', '.beads'),
      },
      stdout: 'pipe',
      stderr: 'pipe',
    });
    const [stdout, stderr] = await Promise.all([
      new Response(proc.stdout).text(),
      new Response(proc.stderr).text(),
    ]);
    const exit = await proc.exited;
    expect(exit).not.toBe(0);
    // Stable prefix from B12-A wrapping path
    expect(stderr + stdout).toMatch(/zk_save_card: E_KIND_FORGE:/);
  });

  it('legitimate idea kind via CLI succeeds', async () => {
    const proc = Bun.spawn(['bun', 'src/cli.ts', 'tool', 'zk_save_card',
      '{"body":"legit idea","kind":"idea","trunk":5}'], {
      cwd: APP_DIR,
      env: {
        ...process.env,
        SILMARI_CALLER_TIER: 'mcp-agent',
        SILMARI_DIR: TMP_STORE,
        SILMARI_BIBLIO_DIR: join(TMP_STORE, 'box1-biblio', '.beads'),
        SILMARI_IDEA_DIR: join(TMP_STORE, 'box2-ideas', '.beads'),
      },
      stdout: 'pipe',
      stderr: 'pipe',
    });
    const stdout = await new Response(proc.stdout).text();
    const exit = await proc.exited;
    expect(exit).toBe(0);
    expect(stdout).toMatch(/"id":"zk-/);
  });
});
```

This test confirms the env-var path works through the **actual** MCP
transport (Client→stdio→Server→dispatchTool→errorResult→stdout/stderr),
which is the production path the silmari CLI and the Python bridge follow.

### E2E

- After all behaviors land, run the existing `sai-compat-noninterference.test.ts`
  with explicit `SILMARI_CALLER_TIER='system-hook'` injected in its env block —
  confirms the Python bridge is interoperable and that elevated-tier calls
  do not corrupt SAI MEMORY/PRD/work-state.

---

## Implementation Order (Execute Linearly)

1. **B1** — `tierAtLeast` helper with 4-tier ordering (~5 minutes)
2. **B2** — `KIND_TRUST` table with exhaustiveness test (~10 minutes)
3. **B3** — `assertKindAllowed` denial path with `console.error` audit (~15 minutes)
4. **B4** — `assertKindAllowed` allow path + `console.error` non-emission test (~10 minutes)
5. **B5** — `resolveCallerFromEnv` with `parseTier` + `parseAgentId` + stable-interface comment (~25 minutes)
6. **B6** — default-`mcp-agent` test (~5 minutes)
7. **B7** — strict validation: case-sensitivity tests + agentId charset+length guards (~15 minutes)
8. **B8** — wire `dispatchTool zk_save_card` for forge denial (~15 minutes)
9. **B9** — `dispatchTool zk_save_card` allow path with isolated fixture cleanup (~15 minutes)
10. **B10** — wire `dispatchTool zk_save_cards` batch + atomicity assertion (~15 minutes)
11. **B11** — pre-audit grep + `_kindguard-setup.ts` helper + regression sweep + patch existing fixtures (~45-90 minutes — bounded by pre-audit list)
12. **B12-A** — MCP envelope wire-format test (~15 minutes)
13. **B12-B** — CLI-spawn end-to-end test (~15 minutes)
14. **B12** — Python mirror (deferred / optional) (~30 minutes)

**Total estimated effort**: ~3.5-4 hours for B1-B12-B; +30 minutes for B12.

**Quality gates that must pass before declaring B1-B12-B complete:**

```bash
cd apps/silmari-mcp
bunx tsc --noEmit                    # typecheck
bun test apps/silmari-mcp             # full module suite (B11 regression gate)
bun test apps/silmari-mcp/tests/kindGuard.test.ts             # focused unit
bun test apps/silmari-mcp/tests/kindGuard-wire-format.test.ts # B12-A
bun test apps/silmari-mcp/tests/kindGuard-cli.test.ts         # B12-B
```

For B12 (Python mirror, optional):

```bash
cd vendor/ultimate_mcp_server && uv run pytest tests/unit/test_silmari_compat.py
```

---

## Beads Issue

After landing the file, run:

```bash
bd create --title="Implement kindGuard caller-trust gate" --type=feature --priority=2 --description="Closes shippable-today forge vulnerability at index.ts:551 (zk_save_card) and :567 (zk_save_cards). Plan: thoughts/searchable/shared/plans/2026-04-30-10-50-kindguard-tdd-plan.md. Mitigation: kindGuard.ts with TrustTier table; env-var SILMARI_CALLER_TIER drives caller identity; subagent default is least-privilege. R5 council surfaced this as zk-rp1y."
```

Link to the council PRD via `bd remember`:

```bash
bd remember --key kindguard-r5-finding "Forge vuln at apps/silmari-mcp/src/index.ts:551 and :567 — kind is unsigned string on wire, no caller authorization. Mitigation in plan dated 2026-04-30. Source card: zk-rp1y."
```

---

## References

- Council PRD with R5 findings: `MEMORY/WORK/20260430-counsel-mcp-vs-local-sai/PRD.md`
- Memory card capturing the vulnerability: `zk-rp1y` (5/337) — "shippable-today forge vuln"
- Architectural context: `specs/MASTER-SYSTEM-DIAGRAM.md`, `specs/ultimate-mcp-memory.md`
- Dispatch path: `apps/silmari-mcp/src/index.ts:534-700` (full dispatchTool switch)
- Card kind enum: `apps/silmari-mcp/src/lib/labels.ts:51`
- Python passthrough: `vendor/ultimate_mcp_server/ultimate_mcp_server/tools/silmari_compat.py:144-165`
- Existing test patterns: `apps/silmari-mcp/tests/mcp-tool-description.test.ts` (direct dispatchTool tests), `apps/silmari-mcp/tests/sai-compat-noninterference.test.ts` (CLI-spawn fixtures)

---

## Stage 2 Sketch (Separate TDD Plan to Follow)

Stage 1 (this plan) lands kindGuard at the L2 layer and wires it into the
**legacy** `zk_save_card` / `zk_save_cards` entry points. Stage 2 lands the
public routing service that consumes the same kindGuard. This section is a
**sketch**, not a full TDD plan — the Engineer can build Stage 1 confident
that the artifacts below will be the consumer of kindGuard once they exist.

### Public MCP Surface (Stage 2)

Two new tools in `apps/silmari-mcp/src/index.ts`:

| Tool | Purpose | Writes? |
|---|---|---|
| `sai_route_thought` | Advisory preview — returns the `RouteDecision` envelope without persisting. Lets a host see how its content + claimed type would be routed. | No |
| `sai_submit_thought` | Atomic operation: route + persist. The caller never names the destination directly; the server decides. | Yes |

### Public Input Schema

```ts
interface ThoughtSubmission {
  content: string;
  claimedThoughtType?: ThoughtType;  // ADVISORY HINT — server may override
  source?: string;                    // e.g. "non-claude-mcp", "algorithm-execute"
  host?: {
    name: string;     // "claude-code" | "cursor" | "codex-cli" | "gemini" | ...
    sessionId?: string;
    model?: string;
  };
  // Optional content metadata that may inform routing but never IS the routing
  hints?: {
    addressee?: string;
    workSlug?: string;
  };
}
```

### Public Output Schema (the `RouteDecision` envelope)

```ts
interface RouteDecision {
  decisionId: string;             // UUID — audit-trail anchor
  effectiveThoughtType: ThoughtType;  // server's ruling, not necessarily what was claimed
  route: 'silmari.zk_save_card' | 'ultimate.store_memory' | 'both' | 'rejected';
  allowed: boolean;               // false → caller is denied this destination at this tier
  confidence: number;             // 0-1, how confident the classifier was
  rationaleCodes: string[];       // e.g. ["semantic-classifier", "host-unprivileged"]
  warnings: string[];             // e.g. ["claimed-type-mismatch", "remote-host-audit-required"]
  enumVersion: string;            // "thoughttype.v1.0", drives drift detection
  // Only present when route !== 'rejected' AND submit (not route-only) was called
  persistedId?: string;
  persistedAddress?: string;      // folgezettel address for silmari, memory_id for ultimate
}
```

### Three-Layer Architecture (Stage 1 + Stage 2 combined)

```text
┌─────────────────────────────────────────────────────────────────┐
│  L3: PUBLIC MCP TOOLS                                           │
│      sai_route_thought  (advisory)                              │
│      sai_submit_thought (atomic write)                          │
│      → Returns RouteDecision envelope; never exposes route table│
└──────────────────────────┬──────────────────────────────────────┘
                           │ calls
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  L2: kindGuard / thoughtTypeGuard  ◄── Stage 1 (this plan)      │
│      assertKindAllowed(kind, caller)                            │
│      assertThoughtTypeAllowed(thoughtType, caller)              │
│      → Pure policy enforcement; throws E_KIND_FORGE on denial   │
└──────────────────────────┬──────────────────────────────────────┘
                           │ called by
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  L1: PRIVATE ROUTE TABLE                                        │
│      routeThought(content, claimedType, caller) → RouteDecision │
│      → Owns ThoughtType×CardKind×MemoryType mapping; classifier │
│      → NEVER exposed as MCP tool                                │
└─────────────────────────────────────────────────────────────────┘

Legacy entry points (zk_save_card, zk_save_cards) call L2 directly via the
parseKindWithGuard helper that Stage 1 lands. Stage 2's L3 tools also call L2
on the way to L1's persistence call.
```

### Tier-to-Source Detection (Stage 2)

The env-var `SILMARI_CALLER_TIER` is the Stage 1 mechanism. Stage 2 hardens
this by deriving tier from the MCP transport itself:

| Source signal | Inferred tier |
|---|---|
| Process spawned by Claude Code hook (parent uid is the user's hook process) | `system-hook` |
| Process invoked from `silmari` CLI directly (parent is shell, env has `SILMARI_CLI=1`) | `local-cli` |
| MCP request over stdio with no remote indicator | `mcp-agent` |
| MCP request over streamable-HTTP from a non-Claude `host.name` | `remote-host` |

The env-var override remains as the testability hook and as a manual override
for local development.

### Audit Logging (Stage 2)

Every `sai_submit_thought` write emits an audit row to
`MEMORY/STATE/route-decisions.jsonl`:

```json
{
  "decisionId": "...",
  "timestamp": "2026-04-30T10:50:00Z",
  "host": { "name": "cursor", "sessionId": "..." },
  "callerTier": "remote-host",
  "claimedThoughtType": "skill",
  "effectiveThoughtType": "idea",
  "route": "silmari.zk_save_card",
  "allowed": true,
  "rationaleCodes": ["claimed-mismatch-downgraded", "remote-host-audit"],
  "persistedId": "zk-..."
}
```

`remote-host` writes are MANDATORY-audit (cannot be disabled). `mcp-agent`
writes are audit-on-rejection only (denials always logged).

### What Stage 2 Adds to the Test Surface

- `apps/silmari-mcp/tests/sai-route-thought.test.ts` — advisory tool returns
  decision envelopes without persisting
- `apps/silmari-mcp/tests/sai-submit-thought.test.ts` — atomic route + persist;
  forge attempts produce `allowed: false` decisions, NOT exceptions
- `apps/silmari-mcp/tests/route-decision-schema.test.ts` — schema parity
  snapshot (Iris's R5 enum-drift test, generalized)
- `apps/silmari-mcp/tests/route-audit-log.test.ts` — every `sai_submit_thought`
  appends to `MEMORY/STATE/route-decisions.jsonl`

### Stage 2 Estimated Effort

~6-8 hours, depending on how aggressive the L1 classifier becomes. A trivial
classifier (always honor `claimedThoughtType` if it's valid; downgrade to
`idea` if invalid) is ~2 hours; an LLM-assisted classifier that detects
forgery and reclassifies content is ~6+.

### When to Build Stage 2

- **Soon** if a non-Claude host is about to start consuming SAI memory
- **After Stage 1 has been in production for ≥1 week** — let kindGuard prove
  itself at the legacy entry points before generalizing
- **Same week** if you want to land the full architectural commit before
  shipping any external `sai` MCP server registration

---

## Open Questions for Reviewer

1. **KIND_TRUST mapping** — is the proposed tier assignment correct? In
   particular: should `decision` and `learning` be `system-hook` rather than
   `local-cli`? The Algorithm CLI is technically a higher trust boundary
   than a runtime Algorithm phase. **Recommendation**: keep as `local-cli`
   for now; the Algorithm CLI is the writer in practice and the difference
   only matters if the Algorithm spawns subagents that try to write
   `decision` cards directly.

2. **Default tier when env is absent** — `mcp-agent` (least privilege among
   locally-invocable tiers, current plan) or `local-cli` (more permissive,
   fewer test fixture changes in B11)? The plan picks `mcp-agent` because
   it's the security-correct choice — but it does increase the audit cost
   of B11. The pre-audit in B11 bounds that cost upfront.

3. **Caller agentId source** — `SILMARI_CALLER_AGENT_ID` env (current plan)
   or read from MCP request metadata (more invasive)? The plan picks env
   because it matches the surgical-insertion constraint; a future slice
   can thread the MCP `request.params.meta.callerAgentId` through if/when
   it exists. Note: agentId is for log diagnostics ONLY in this slice,
   not persisted to cards or audit logs.

4. **Whether to mirror in Python at all (B12)** — the TS gate alone is
   sufficient for the threat model. The Python check is defense-in-depth.
   **Recommendation**: ship B1-B12-B first; treat B12 (Python) as a
   follow-up issue.

5. **Audit logging on denial** — `console.error` only (current plan), or
   also append to `MEMORY/SECURITY/security-events.jsonl` via the existing
   event-emitter at `SAI/hooks/lib/event-emitter.ts`?
   **Recommendation**: ship `console.error` first (B3 already wires this);
   events.jsonl is a Stage-1.5 follow-up that can land without breaking
   the gate. The `console.error` line is already structured enough for
   log scrapers, and `MEMORY/SECURITY/` writes have their own concurrency
   model that this plan doesn't want to introduce.

6. **Case sensitivity for SILMARI_CALLER_TIER** — strict-lowercase
   exact-match (current plan) or normalize via `.toLowerCase()`?
   **Recommendation**: strict-lowercase (current). Normalizing would
   silently fix typos like `Algorithm` and mask real misconfigurations.
   B7 has explicit tests asserting `'SYSTEM-HOOK'` and `'Local-CLI'`
   throw `E_KIND_GUARD_BAD_TIER`. This mirrors how SQL keywords and
   shell variable names work in the rest of the codebase.

7. **Test concurrency posture for env mutations** — most unit tests use
   `resolveCallerFromEnv(env)` parameter injection (no `process.env`
   mutation, parallel-safe). The dispatchTool tests in B8/B9/B10 DO
   mutate `process.env` because `dispatchTool` reads it at call time.
   **Recommendation for now**: run `bun test apps/silmari-mcp` in default
   mode and accept that the kindGuard dispatchTool tests must run within
   one file's scope (Bun's default behavior is per-file ordering, not
   inter-file parallelism). If flake appears, switch to `bun test --serial`
   OR refactor `dispatchTool` to accept an optional env (more invasive,
   defer). See B8's beforeEach/afterEach for the save-and-restore pattern.
