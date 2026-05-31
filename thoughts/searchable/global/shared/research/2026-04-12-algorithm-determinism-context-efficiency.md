---
date: 2026-04-12T20:00:00-05:00
researcher: Silmari
git_commit: 34f563102086552119b07596d894ba4717b2fb1e
branch: main
repository: silmari-agent-memory
topic: "Algorithm v3.7.0 — Determinism, Context Efficiency, Lazy Loading, Hooks+MCP Integration"
tags: [research, algorithm, determinism, context-efficiency, lazy-loading, hooks, mcp, architecture]
status: complete
last_updated: 2026-04-12
last_updated_by: Silmari
---

# Research: Algorithm v3.7.0 — Determinism, Context Efficiency, Lazy Loading, Hooks+MCP

**Date**: 2026-04-12T20:00:00-05:00
**Git Commit**: 34f5631
**Branch**: main

## Research Question

How to make the Algorithm more deterministic and context-efficient. Can we lazy load? Can we use hooks AND MCP, or hooks AND code?

---

## Summary

The Algorithm v3.7.0 is a 724-line (~15,000 token) file loaded in its entirety at Algorithm entry. **57% of the file** is two sections (phase definitions + memory integration) that must be present for the Algorithm to function. But **~20% can be deferred** (ISC examples, capability examples, context recovery, voice protocol details). The existing hooks infrastructure already handles PRD sync, session naming, learning capture, and context injection at specific lifecycle events — none of these are in the Algorithm file today, they're separate TypeScript hooks. MCP tools (17 registered) handle all Silmari memory operations. The hooks-to-MCP bridge exists as an exported `dispatchTool` function in the MCP server but is not currently used by any hook. Three architecture paths are viable: (A) hooks doing deterministic work that the LLM currently does unreliably, (B) MCP tools called from hooks for state operations, (C) lazy-loading Algorithm sections via file reads at phase boundaries.

---

## Detailed Findings

### 1. Current Token Budget

| Component | Tokens | % of File | Load-Bearing? |
|-----------|--------|-----------|---------------|
| Phase definitions (OBSERVE→LEARN, 7 phases) | ~5,100 | 33% | Yes — the execution structure |
| Memory integration (Silmari, recall/save/edge patterns) | ~3,400 | 22% | Yes — mandatory at OBSERVE + LEARN |
| Card lifecycle protocol (resumption, status inference, stubs) | ~2,900 | 19% | Partially — resumption is mandatory, rest deferrable |
| ISC decomposition methodology + examples | ~1,800 | 12% | Partially — methodology yes, examples deferrable |
| Capability selection + examples | ~1,100 | 7% | Deferrable — examples are ~600 tokens |
| Critical rules, context recovery, PRD format | ~1,100 | 7% | Critical rules yes, recovery + PRD format deferrable |
| **TOTAL** | **~15,400** | **100%** | |

**Total Algorithm payload including dependencies:**
- v3.7.0.md alone: ~15,000 tokens
- + PRDFORMAT.md (loaded at OBSERVE): ~1,600 tokens
- + CLAUDE.md (already loaded by Claude Code): separate
- **Working total at OBSERVE entry: ~16,600 tokens**

### 2. What Is Deterministic Today (Hooks)

These operations already happen deterministically via TypeScript hooks — no LLM judgment needed:

| Hook | Trigger | What It Does Deterministically |
|------|---------|-------------------------------|
| `PRDSync.hook.ts` | PostToolUse (Write/Edit on PRD.md) | Parses PRD frontmatter, syncs to work.json, updates tab color on phase change |
| `SessionAutoName.hook.ts` | UserPromptSubmit (1st) | Extracts 4-word name, detects algo keywords, upserts session to work.json |
| `LoadContext.hook.ts` | SessionStart | Injects relationship context, learning readback, active work summary |
| `RatingCapture.hook.ts` | UserPromptSubmit | Captures explicit ratings, runs Haiku sentiment inference on implicit feedback |
| `WorkCompletionLearning.hook.ts` | SessionEnd | Reads PRD, extracts ISC criteria, creates learning file |
| `SessionCleanup.hook.ts` | SessionEnd | Marks PRD complete, deletes session state |
| `LastResponseCache.hook.ts` | Stop | Caches last response for RatingCapture |

### 3. What Is Non-Deterministic Today (LLM Does It)

These operations are specified in v3.7.0.md as LLM instructions — each consumes context and relies on the LLM following instructions correctly:

| Operation | Algorithm Section | What the LLM Does | Deterministic Alternative? |
|-----------|------------------|--------------------|-----------------------------|
| **PRD stub creation** | v3.7.0:383-398 | `mkdir -p` + `Write` PRD.md with frontmatter | **Hook**: SessionStart hook could create stub when mode='algorithm' detected |
| **Voice curl at entry** | v3.7.0:381 | Inline `curl` command | **Hook**: SessionStart hook fires curl when algo detected |
| **Voice curl at phase transitions** | v3.7.0:401-604 | Inline `curl` at each phase | **Hook**: PostToolUse hook on PRD.md phase change already has the phase — fire curl there |
| **JSONL reflection append** | v3.7.0:622-628 | `echo '{...}' >> algorithm-reflections.jsonl` | **Hook**: SessionEnd hook extracts from PRD + last response |
| **Effort tier classification** | v3.7.0:420-424 | Reads request, selects tier | Stays LLM — requires judgment |
| **ISC decomposition** | v3.7.0:426-449 | Writes ISC criteria to PRD | Stays LLM — requires judgment |
| **ISC count gate** | v3.7.0:437-449 | Counts criteria, checks against floor | **Hook or MCP**: PostToolUse on PRD.md could count `- [ ]` lines and warn |
| **zk_recall at OBSERVE** | v3.7.0:405 | Calls MCP tool | Stays LLM — needs to interpret results |
| **Resumption check** | v3.7.0:173-236 | Calls zk_recall, classifies cards, prompts user | Partially — the MCP call + classification stay LLM, but the format output could be templated |
| **LEARN edge creation** | v3.7.0:68-82 | Classifies reflection against recalled cards, fires propose_link + commit_link | Stays LLM — requires semantic judgment |
| **Progress counter update** | v3.7.0:588 | Edits PRD frontmatter `progress: N/M` | **Hook**: PRDSync already reads criteria — could compute and inject |

### 4. What CAN Be Lazy-Loaded

Sections that are only needed at specific phases, not at Algorithm entry:

| Section | Lines | ~Tokens | When Needed | Lazy Load Strategy |
|---------|-------|---------|-------------|-------------------|
| ISC decomposition examples (blog post, granularity demo) | 333-367 | ~600 | Only if ISC count < floor | Move to `SAI/Algorithm/ISC_EXAMPLES.md`, load in OBSERVE only when count gate fails |
| Capability selection examples (RPG game) | 499-537 | ~550 | Only for Extended+ effort | Move to `SAI/Algorithm/CAPABILITY_EXAMPLES.md`, load in OBSERVE only for Extended+ |
| Voice protocol details | 22-35 | ~200 | Could be inline curl strings | Move to hook — see #3 above |
| Context recovery procedure | 710-724 | ~200 | Only when context lost | Move to `SAI/Algorithm/CONTEXT_RECOVERY.md`, reference inline |
| Card lifecycle status inference table | 252-266 | ~250 | Only at LEARN save time | Keep inline — small enough |
| Stub creation pattern | 267-293 | ~400 | Only when saving blocked cards | Move to `SAI/Algorithm/STUB_PATTERN.md`, load when status='blocked' |
| **TOTAL DEFERRABLE** | | **~2,200** | | **14% of Algorithm file** |

### 5. Hooks + MCP Integration — What Exists

**MCP Server exports `dispatchTool` directly** (`apps/silmari-mcp/src/index.ts:742`):
```typescript
export { dispatchTool, dispatchResource, TOOLS, STATIC_RESOURCES };
```

This means a hook TypeScript file could theoretically:
```typescript
import { dispatchTool } from '/path/to/silmari-mcp/src/index.ts';
const result = await dispatchTool('zk_recall', { query: 'test', expandCrossRefs: true });
```

**Or use the CLI as MCP client** (`apps/silmari-mcp/src/cli.ts`):
- Spawns MCP server via STDIO transport
- Calls `client.callTool({ name, arguments })`
- Pattern: `bun run apps/silmari-mcp/src/cli.ts recall "query"`

**Current state: no hook calls MCP today.** The bridge exists but is unused.

### 6. The 17 MCP Tools Available

| Tool | R/W | Used By Algorithm? | Could Be Hook-Invoked? |
|------|-----|-------------------|----------------------|
| `zk_status` | R | Yes (health check) | Yes — SessionStart health check |
| `zk_recall` | R | Yes (OBSERVE + THINK + LEARN) | Partially — recall needs LLM interpretation |
| `zk_recall_by_status` | R | Yes (resumption check) | Yes — hook could pre-fetch in_progress cards |
| `zk_save_card` | W | Yes (LEARN + EXECUTE + VERIFY) | Partially — LEARN saves need LLM judgment on kind |
| `zk_propose_link` | W | Yes (LEARN edge creation) | No — requires semantic classification |
| `zk_commit_link` | W | Yes (LEARN edge creation) | No — tied to propose_link |
| `zk_neighborhood` | R | No | Yes — could pre-fetch for hover UI |
| `zk_chain` | R | No | Yes — could pre-fetch genealogy |
| `zk_follow` | R | No | Yes — BFS walk for graph |
| `zk_hub_create` | W | Yes (LEARN, 3+ recurrence) | No — requires pattern recognition |
| `zk_hub_add_card` | W | Yes (LEARN) | No — tied to hub_create |
| `zk_structure_create` | W | No | N/A |
| `zk_register_read` | R | No (fallback only) | Yes — pre-load register for OBSERVE |
| `zk_block` | W | Yes (stub pattern) | No — requires context |
| `zk_keyword_add` | W | Yes (optional) | No — requires judgment |
| `zk_reflect` | R | No | Yes — could pre-generate reflection prompts |
| `zk_promote` | W | Yes (lifecycle transitions) | Yes — SessionEnd hook could promote completed cards |

### 7. Three Architecture Paths for Hooks+MCP

**Path A — Hooks do deterministic Algorithm mechanics:**

Operations that don't need LLM judgment move to hooks:

| Operation | Current | Hook Alternative | Trigger |
|-----------|---------|-----------------|---------|
| PRD stub creation | LLM writes via Algorithm instruction | Hook creates `MEMORY/WORK/{slug}/PRD.md` | SessionStart (when mode='algorithm') |
| Voice curl at entry | LLM inline curl | Hook fires curl | SessionStart (when mode='algorithm') |
| Voice at phase transition | LLM inline curl at each phase | PRDSync hook fires curl on phase change | PostToolUse (PRD.md write with phase change) |
| JSONL reflection append | LLM echo command | WorkCompletionLearning hook extracts from PRD | SessionEnd |
| ISC count gate | LLM counts and checks | PRDSync hook counts `- [ ]` lines, injects warning | PostToolUse (PRD.md write) |
| Progress counter | LLM updates `progress: N/M` | PRDSync hook counts `- [x]` vs `- [ ]` | PostToolUse (PRD.md write) |

**Path B — MCP tools called from hooks:**

Pre-fetch operations that feed the LLM's OBSERVE phase:

| Operation | Hook | MCP Call | Output |
|-----------|------|----------|--------|
| Health check | SessionStart | `zk_status()` | Inject `silmari: healthy/unavailable` into context |
| Pre-fetch in_progress cards | SessionStart | `zk_recall_by_status({status:'in_progress'})` | Inject resumption candidates into context |
| Pre-fetch task recall | UserPromptSubmit (1st) | `zk_recall({query: first_prompt_keywords})` | Inject prior memory into context |
| Promote completed cards | SessionEnd | `zk_promote({cardId, toStatus:'closed'})` | Close deferred `in_progress` cards from PRD |

**Path C — Lazy-load Algorithm sections via file reads:**

Split v3.7.0.md into core + appendices:

| File | Contents | ~Tokens | Loaded When |
|------|----------|---------|-------------|
| `v3.7.0.md` (slimmed) | Core phases + memory integration + critical rules | ~12,200 | Always at Algorithm entry |
| `ISC_EXAMPLES.md` | Decomposition examples, granularity demos | ~600 | ISC count gate fails |
| `CAPABILITY_EXAMPLES.md` | RPG game examples, selection guidance | ~550 | Effort is Extended+ |
| `STUB_PATTERN.md` | Stub creation pattern, auto-transitions | ~400 | Saving blocked card |
| `CONTEXT_RECOVERY.md` | Recovery procedure from context loss | ~200 | Context lost mid-run |

---

## Architecture Documentation

### Current Flow (All LLM, All Context)
```
SessionStart hooks inject context (~2K tokens)
  ↓
CLAUDE.md classifies → ALGORITHM
  ↓
LLM reads v3.7.0.md (15K tokens into context)
  ↓
LLM executes voice curl, PRD stub, zk_recall, resumption check, ISC, capabilities...
  ↓
Each phase: LLM voice curl + PRD edit + work + verify
  ↓
PRDSync hook reads PRD on each edit (deterministic, outside context)
  ↓
SessionEnd hooks capture learning + cleanup
```

### Possible Hybrid Flow (Hooks + MCP + Lazy Load)
```
SessionStart hooks:
  - Create PRD stub (deterministic, no LLM needed)
  - Fire voice curl "Entering the Algorithm" (deterministic)
  - Call zk_status() via MCP (health check)
  - Call zk_recall_by_status('in_progress') via MCP (pre-fetch resumption)
  - Inject results into context as <system-reminder>
  ↓
CLAUDE.md classifies → ALGORITHM
  ↓
LLM reads SLIM v3.7.0.md (~12K tokens — examples deferred)
  ↓
LLM sees pre-fetched resumption cards in context (no need to call zk_recall_by_status itself)
LLM does OBSERVE: effort classification, ISC decomposition (judgment calls)
  ↓
PRDSync hook on each PRD edit:
  - Counts ISC criteria, warns if below floor (deterministic)
  - Updates progress counter (deterministic)
  - Fires voice curl on phase change (deterministic)
  ↓
LLM loads ISC_EXAMPLES.md ONLY IF count gate fails
LLM loads CAPABILITY_EXAMPLES.md ONLY IF effort is Extended+
  ↓
LEARN phase: LLM does reflection + edge creation (judgment calls)
  ↓
SessionEnd hooks:
  - Extract reflection from PRD, append JSONL (deterministic)
  - Call zk_promote() via MCP for completed cards (deterministic)
  - Cleanup session state
```

## Code References

- `SAI/Algorithm/v3.7.0.md` — 724 lines, ~15,000 tokens, the full Algorithm
- `~/.claude/hooks/PRDSync.hook.ts` — PostToolUse hook, syncs PRD→work.json on every PRD edit
- `~/.claude/hooks/LoadContext.hook.ts` — SessionStart hook, 536 lines, injects dynamic context
- `~/.claude/hooks/SessionAutoName.hook.ts` — UserPromptSubmit hook, detects algo keywords
- `~/.claude/hooks/WorkCompletionLearning.hook.ts` — SessionEnd hook, captures learning from PRD
- `~/.claude/hooks/RatingCapture.hook.ts` — UserPromptSubmit hook, 554 lines, captures ratings
- `apps/silmari-mcp/src/index.ts:742` — exports `dispatchTool` for programmatic MCP calls
- `apps/silmari-mcp/src/cli.ts` — CLI MCP client pattern (STDIO transport)
- `SAI/PRDFORMAT.md` — 143 lines, PRD format spec loaded during OBSERVE

## Related Research

- `thoughts/shared/research/2026-04-12-algorithm-cw9-collision-analysis.md` — Mode classification collision (now fixed with COMMAND MODE)

## Open Questions

1. Should the hook→MCP bridge use the exported `dispatchTool` directly (in-process, fast, but couples hook to MCP server code) or spawn the CLI as a subprocess (isolated, but slower)?
2. If PRDSync fires voice curls on phase change, should it also inject a `<system-reminder>` with the phase-specific instructions (effectively lazy-loading phase content)?
3. The ISC count gate currently blocks the LLM from proceeding — if a hook counts ISC and warns, does the LLM still respect the gate, or does it need to be a hard error?
4. Pre-fetching `zk_recall` at SessionStart means the recall query is the raw first prompt, not the LLM's 8-word task description — is that close enough, or does the quality gap matter?
5. How much context savings is actually realized if the LLM loads ISC_EXAMPLES.md on most runs anyway (because Standard effort has a floor of 8, and LLMs frequently need the examples)?
