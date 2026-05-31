---
date: 2026-04-12T19:00:00-05:00
researcher: Silmari
git_commit: 34f563102086552119b07596d894ba4717b2fb1e
branch: main
repository: silmari-agent-memory
topic: "Algorithm v3.7.0 vs cw9* Commands — Collision Analysis"
tags: [research, algorithm, cw9, commands, collision, mode-selection]
status: complete
last_updated: 2026-04-12
last_updated_by: Silmari
---

# Research: Algorithm v3.7.0 vs cw9* Commands — Collision Analysis

**Date**: 2026-04-12T19:00:00-05:00
**Researcher**: Silmari
**Git Commit**: 34f5631
**Branch**: main
**Repository**: silmari-agent-memory

## Research Question

Do "the Algorithm" (SAI Algorithm v3.7.0) and the specialized `cw9*` commands collide? Focus on actual collisions, not theoretical ones.

---

## Summary

**Yes, there is one actual collision point: CLAUDE.md's mode classification rule.** CLAUDE.md says "Everything else → ALGORITHM", with no carve-out for skill/command invocations. The cw9 commands have their own multi-step workflows, phase structures, and output formats — none of which reference or account for the Algorithm. When a user invokes `/cw9_research`, the mode classifier sees "multi-step complex work" and wants to enter ALGORITHM mode (which triggers PRD creation, voice curls, Silmari recall, 7-phase OBSERVE→LEARN structure). But the cw9 command's own instructions say to run a completely different workflow (CW9 CLI pipelines, TLC verification, bridge artifacts).

In practice, the most specific instruction (the cw9 skill prompt) tends to win, but the mode selection rule creates an ambiguous competition that could cause the Algorithm to partially activate (voice curl, PRD stub creation, resumption check) before the cw9 instructions take over.

---

## Detailed Findings

### 1. The Algorithm's Entry Sequence (what fires on ALGORITHM mode)

When CLAUDE.md classifies a request as ALGORITHM, the mandatory sequence is:

| Step | What Happens | Source |
|------|-------------|--------|
| 1 | Voice curl: `"Entering the Algorithm"` | `v3.7.0.md:31` |
| 2 | `mkdir -p MEMORY/WORK/{slug}/` | `v3.7.0.md:385` |
| 3 | Write `MEMORY/WORK/{slug}/PRD.md` stub | `v3.7.0.md:386` |
| 4 | `mcp__silmari__zk_recall()` on task description | `v3.7.0.md:46-54` |
| 5 | `mcp__silmari__zk_recall()` for in_progress cards (resumption check) | `v3.7.0.md:175-179` |
| 6 | Resumption prompt (Formats A/B/C/D) — may PAUSE for user input | `v3.7.0.md:193-236` |
| 7 | OBSERVE phase begins (reverse engineering, ISC creation) | `v3.7.0.md:427` |

**Every one of these steps fires before any actual work begins.** The Algorithm claims the entire session flow.

### 2. The cw9 Commands (10 commands, their own workflows)

| Command | Phases | Output | Algorithm Reference? |
|---------|--------|--------|---------------------|
| `cw9_research` | Orient → Beads Setup → Ingest/Crawl → Explore → Research Doc | `thoughts/shared/research/*.md` | None |
| `cw9_plan` | Gather Context → Register/Prepare → Run Pipeline → Write Plan | `thoughts/shared/plans/*-tdd-*.md` | None |
| `cw9_implement` | Red → Green → Refactor → Checkoff → Re-verify | Code changes | None |
| `cw9_research_review` | Inputs → Chain Links → Reuse Candidates → Report | Validation report | None |
| `cw9_plan_review_01_artifacts` | Read Plan → Existence Check → Status → UUID Validation | Artifact review | None |
| `cw9_plan_review_02_coverage` | Load Artifacts → Bridge Mapping → Traces → Invariants | Coverage review | None |
| `cw9_plan_review_03_abstraction_gap` | Read Spec → Catalog Choices → Bridge Artifacts → Plan | Gap review | None |
| `cw9_plan_review_04_imports` | Identify Files → Dead Imports → Wrong Abstraction → Raw Ops | Import audit | None |
| `cw9_plan_review_05_boundary_contract` | Read Plan → Identify Seams → Check Coverage → Verdict | JSON verdict | None |
| `cw9_worktree` | Resolve Paths → Create Worktree → Bootstrap CW9 → Verify | Setup summary | None |

**Zero cw9 commands reference ALGORITHM mode, NATIVE mode, v3.7.0, PRD creation, voice curls, or Silmari recall.**

### 3. The Actual Collision: Mode Classification

CLAUDE.md (`~/.claude/CLAUDE.md`) states:

> "Every response uses exactly one mode. BEFORE ANY WORK, classify the request and select a mode:
> - Greetings, ratings, acknowledgments → MINIMAL
> - Single-step, quick tasks (under 2 minutes of work) → NATIVE
> - Everything else → ALGORITHM"

**The classification rule has no carve-out for skill/command invocations.** When `/cw9_research` fires:

```
User: /cw9_research
  ↓ Skill tool loads cw9_research.md prompt
  ↓ CLAUDE.md says: "BEFORE ANY WORK, classify the request"
  ↓ "Multi-step complex work" → ALGORITHM
  ↓ ALGORITHM mode says: "Read SAI/Algorithm/v3.7.0.md, follow it exactly"
  ↓ Algorithm entry: voice curl, mkdir MEMORY/WORK/, PRD stub, zk_recall, resumption check
  ↓ CONFLICT: cw9_research.md says: "Orient → Beads Setup → Ingest/Crawl → Explore"
```

**The competing instruction sets:**

| Dimension | Algorithm v3.7.0 wants | cw9 command wants |
|-----------|----------------------|-------------------|
| Phase structure | OBSERVE → ORIENT → THINK → BUILD → EXECUTE → VERIFY → LEARN | Command-specific phases (e.g., Orient → Crawl → Explore) |
| Output artifact | `MEMORY/WORK/{slug}/PRD.md` | `thoughts/shared/research/*.md` or `thoughts/shared/plans/*.md` |
| Voice announcements | Curl at each phase transition | None |
| Memory integration | `zk_recall` at OBSERVE + LEARN, `zk_save_card` at LEARN | None |
| Resumption check | Mandatory — may PAUSE for user input | None |
| ISC creation | Mandatory — verifiable criteria before execution | None (TLC verification is different) |
| Effort classification | Standard/Extended/Advanced/Deep/Comprehensive | None |
| Capability invocation | Min N skills must be invoked via tool | Uses CW9 CLI tools, not SAI skills |

### 4. What Actually Happens in Practice

In practice, Claude receives both instruction sets and resolves the ambiguity by **recency/specificity** — the skill prompt is the most recent and most specific instruction, so it tends to win. But partial Algorithm activation can still occur:

**Observed partial activations (plausible based on the instruction structure):**
- Voice curl `"Entering the Algorithm"` fires before the skill prompt takes over
- `MEMORY/WORK/` directory gets created with a PRD stub that is never completed
- Resumption check fires and asks the user about in_progress cards, delaying the cw9 workflow
- The Algorithm's LEARN phase tries to fire at the end, saving cards about the cw9 work

**What does NOT collide:**
- The cw9 commands' CW9 CLI tool usage (bash commands) — these don't conflict with any Algorithm tool
- File output locations — `thoughts/shared/` vs `MEMORY/WORK/` are different directories
- The cw9 review commands (01-05) are fast, narrow gates — they'd likely be classified as NATIVE mode anyway since each is a single focused check

### 5. Which cw9 Commands Are Most Collision-Prone

| Command | Collision Risk | Why |
|---------|---------------|-----|
| `cw9_research` | **High** | Multi-step, long-running, creates research documents — clearly "everything else" |
| `cw9_plan` | **High** | Multi-step, creates plan documents — clearly "everything else" |
| `cw9_implement` | **High** | Multi-step, writes code — clearly "everything else" |
| `cw9_worktree` | **Medium** | Setup task, ~2 min — borderline NATIVE/ALGORITHM |
| `cw9_research_review` | **Low** | Narrow validation, fast — could be classified NATIVE |
| `cw9_plan_review_01-05` | **Low** | Each is a focused gate check — could be classified NATIVE |

---

## Code References

- `~/.claude/CLAUDE.md:5-11` — Mode classification rules (the collision point)
- `~/.claude/CLAUDE.md:35` — ALGORITHM mode mandatory first action: load v3.7.0.md
- `SAI/Algorithm/v3.7.0.md:23-36` — Voice announcements at entry + phase transitions
- `SAI/Algorithm/v3.7.0.md:385-386` — PRD directory creation and stub
- `SAI/Algorithm/v3.7.0.md:46-54` — Mandatory zk_recall at OBSERVE entry
- `SAI/Algorithm/v3.7.0.md:175-236` — Resumption check (may pause for user input)
- `~/.claude/SAI/commands/cw9_research.md` — CW9 research workflow (no Algorithm reference)
- `~/.claude/SAI/commands/cw9_plan.md` — CW9 TDD plan workflow (no Algorithm reference)
- `~/.claude/SAI/commands/cw9_implement.md` — CW9 implementation workflow (no Algorithm reference)

## Architecture Documentation

The two systems are independent architectures that share the same Claude Code session:

- **Algorithm v3.7.0**: A 7-phase structured reasoning framework with PRD artifacts, voice announcements, Silmari memory integration, ISC-based verification, and effort tiers. Activated by CLAUDE.md's "everything else" classification rule.
- **cw9 commands**: A 10-command pipeline for external codebase work using the CW9 CLI tool. Each command has its own phase structure, output format, and artifact locations. No awareness of the Algorithm.

The collision surface is CLAUDE.md's mode classifier — it's the single gateway that both systems pass through, and it has no mechanism to distinguish "user typed a request" from "user invoked a specialized command."

## Open Questions

1. What partial Algorithm activations have actually been observed during cw9 command runs?
2. Are orphaned PRD stubs accumulating in `MEMORY/WORK/` from partially-activated Algorithm runs?
3. Do other non-cw9 commands (like `/research_codebase`, `/create_plan`, `/implement_plan`) experience the same collision?
