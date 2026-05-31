# Algorithm v3.8.0 — Hooks Determinism + Lazy Loading Implementation Plan

## Overview

Move 6 deterministic operations out of the Algorithm's LLM instruction set into TypeScript hooks, and split the Algorithm file into core + lazy-loaded appendices. This reduces context consumption by ~3,000-4,000 tokens, eliminates failure modes where the LLM forgets mechanical steps (voice curls, progress counters, JSONL append), and makes the Algorithm more deterministic without changing any judgment-requiring behavior.

## Current State Analysis

The Algorithm v3.7.0.md is 724 lines / ~15,000 tokens loaded in full at Algorithm entry. Six operations in the file are purely mechanical — no LLM judgment required — but are specified as LLM instructions that consume context and can be skipped or malformed. Existing hooks (PRDSync, SessionAutoName, WorkCompletionLearning) already touch the same state files and have the trigger points needed.

### Key Discoveries:
- `PRDSync.hook.ts` already detects phase changes by comparing old/new phases from work.json vs PRD frontmatter — perfect insertion point for voice curls
- `SessionAutoName.hook.ts` already detects algo keywords via `ALGO_ACTION_RE` regex at line 145 and sets `mode='starting'` — perfect trigger for PRD stub creation
- `WorkCompletionLearning.hook.ts` already reads PRD frontmatter and counts ISC criteria (`- [x]` vs `- [ ]`) — can append JSONL with structured data
- PRDSync reads criteria on every PRD edit — can auto-compute `progress: N/M` and inject ISC count warnings
- ~2,200 tokens of examples/recovery/stub-pattern content is only needed conditionally

## Desired End State

After this plan:
- Voice curls fire deterministically on phase transitions via PRDSync hook — LLM never needs to `curl`
- PRD stub is created by hook at session start — LLM starts OBSERVE with PRD already existing
- ISC count gate is enforced by hook warning injected into context — LLM sees the warning, can't miss it
- Progress counter auto-updates on every PRD edit — LLM never manually counts checkboxes
- JSONL reflection appends at SessionEnd — LLM never runs `echo >> .jsonl`
- Algorithm file is ~12,200 tokens (down from ~15,400) with appendices loaded on-demand
- v3.7.0.md instructions for the 6 mechanical operations are simplified to "hooks handle this"

### Verification:
```bash
# Hooks modified correctly
bun test ~/.claude/hooks/PRDSync.hook.ts 2>/dev/null || echo "No test runner for hooks — manual verify"

# Algorithm file slimmed
wc -l SAI/Algorithm/v3.8.0.md  # expect ~580 lines (down from 724)

# Appendix files exist
ls SAI/Algorithm/appendices/ISC_EXAMPLES.md SAI/Algorithm/appendices/CAPABILITY_EXAMPLES.md SAI/Algorithm/appendices/STUB_PATTERN.md SAI/Algorithm/appendices/CONTEXT_RECOVERY.md

# Voice curl fires on phase change (manual — edit PRD phase, observe curl)
# PRD stub created at algo session start (manual — start algo session, check MEMORY/WORK/)
# ISC count gate warning appears (manual — write PRD with <8 criteria, check system-reminder)
# Progress counter auto-updates (manual — check [x] a criterion, verify progress: updates)
# JSONL appended at session end (manual — end algo session, check algorithm-reflections.jsonl)
```

## What We're NOT Doing

| NOT Doing | ARE Doing |
|-----------|-----------|
| Path B (hooks calling MCP tools like zk_recall) | Only Path A (deterministic hooks) + Path C (lazy load) |
| Changing any LLM judgment operations (ISC decomposition, effort selection, edge creation) | Only moving mechanical operations to hooks |
| Creating v3.8.0 as a new file immediately | Editing v3.7.0.md in place, bumping version header |
| Adding new hook files | Modifying 3 existing hooks (PRDSync, SessionAutoName, WorkCompletionLearning) |
| Changing settings.json hook configuration | Hooks already trigger on the right events |

## Implementation Approach

Modify existing hooks surgically — each hook already has the trigger event and state access needed. Then slim the Algorithm file by removing instructions for operations hooks now handle, and extract deferrable content into appendix files.

---

╔═══════════════════════════════════════════════╗
║  PHASE 1: PRDSync Voice Curls on Phase Change ║
║  ~/.claude/hooks/PRDSync.hook.ts              ║
╚═══════════════════════════════════════════════╝

## Phase 1: Voice Curls on Phase Transition

### Overview
PRDSync already detects phase changes (compares old phase from work.json to new phase from PRD frontmatter). Add a `curl` to the voice server when a phase change is detected, immediately before `setPhaseTab()`.

### Changes Required:

**File**: `~/.claude/hooks/PRDSync.hook.ts`

#### 1a. Add import
```typescript
import { execSync } from 'child_process';
```

#### 1b. Add voice function
```typescript
function announcePhase(phase: string): void {
  const phaseName = phase.charAt(0) + phase.slice(1).toLowerCase();
  const message = phase === 'OBSERVE'
    ? 'Entering the Algorithm'
    : `Entering the ${phaseName} phase.`;
  try {
    execSync(
      `curl -s -X POST http://localhost:8888/notify -H "Content-Type: application/json" -d '${JSON.stringify({ message, voice_id: "fTtv3eikoepIosk8dTZ5", voice_enabled: true })}'`,
      { timeout: 3000, stdio: 'ignore' }
    );
  } catch {
    // Voice server may be down — non-fatal
  }
}
```

#### 1c. Insert call in phase-change block
Inside the existing `if (newPhase !== oldPhase && ...)` block, add `announcePhase(newPhase)` before `setPhaseTab()`:
```typescript
if (newPhase !== oldPhase && VALID_PHASES.has(newPhase) && input.session_id) {
  try {
    announcePhase(newPhase);  // ← NEW: voice curl on phase change
    setPhaseTab(newPhase as AlgorithmTabPhase, input.session_id);
  } catch (err) {
    console.error('[PRDSync] setPhaseTab failed:', err);
  }
}
```

### Success Criteria:

#### Automated Verification:
- [x] Hook file parses without syntax errors: `bun -e "import '~/.claude/hooks/PRDSync.hook.ts'"` (or equivalent check)
- [ ] Voice server receives curl on phase change (check `curl` reaches localhost:8888)

#### Manual Verification:
- [ ] Start Algorithm session → write PRD with `phase: observe` → hear "Entering the Algorithm"
- [ ] Edit PRD to `phase: think` → hear "Entering the Think phase."
- [ ] Edit PRD to `phase: execute` → hear "Entering the Execute phase."
- [ ] If voice server is down, hook doesn't crash (3s timeout, silent failure)

---

╔═══════════════════════════════════════════════╗
║  PHASE 2: PRD Stub at Session Start           ║
║  ~/.claude/hooks/SessionAutoName.hook.ts      ║
╚═══════════════════════════════════════════════╝

## Phase 2: PRD Stub Creation on Algo Detection

### Overview
SessionAutoName already detects algo keywords (`implement|build|create|architect|design|migrate|deploy|refactor`) and sets `mode='starting'`. When this fires, also create the PRD stub directory and file so the LLM finds it already existing when it enters OBSERVE.

### Changes Required:

**File**: `~/.claude/hooks/SessionAutoName.hook.ts`

#### 2a. Add PRD stub function
```typescript
import { mkdirSync, writeFileSync, existsSync } from 'fs';
import { join } from 'path';

function createAlgorithmPrdStub(sessionId: string, prompt: string): string | null {
  const saiDir = process.env.SAI_DIR || join(process.env.HOME || '', '.claude');
  const now = new Date();
  const pad = (n: number) => String(n).padStart(2, '0');
  const slug = `${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}-${pad(now.getHours())}${pad(now.getMinutes())}${pad(now.getSeconds())}_${prompt.slice(0, 60).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/-+$/, '')}`;
  const dir = join(saiDir, 'MEMORY', 'WORK', slug);
  const prdPath = join(dir, 'PRD.md');

  if (existsSync(prdPath)) return slug; // already exists (resume case)

  try {
    mkdirSync(dir, { recursive: true });
    const taskDesc = prompt.slice(0, 120).replace(/\n/g, ' ').trim();
    const frontmatter = [
      '---',
      `task: "${taskDesc}"`,
      `slug: ${slug}`,
      'effort: standard',
      'phase: observe',
      'progress: 0/0',
      'mode: interactive',
      `started: ${now.toISOString()}`,
      `updated: ${now.toISOString()}`,
      '---',
      '',
    ].join('\n');
    writeFileSync(prdPath, frontmatter);
    return slug;
  } catch {
    return null; // non-fatal — LLM will create it
  }
}
```

#### 2b. Call when algo detected
After the existing `upsertSession()` call (around line 474), when `sessionMode === 'starting'`:
```typescript
if (sessionMode === 'starting') {
  const slug = createAlgorithmPrdStub(sessionId, sanitizedPrompt);
  if (slug) {
    console.error(`[SessionAutoName] PRD stub created: MEMORY/WORK/${slug}/PRD.md`);
  }
}
```

### Success Criteria:

#### Automated Verification:
- [x] Hook file parses without syntax errors
- [ ] `MEMORY/WORK/` directory gets a new slug directory when algo keyword detected

#### Manual Verification:
- [ ] Start session with prompt "implement the login flow" → check `MEMORY/WORK/` has new dir with `PRD.md` stub
- [ ] Start session with prompt "what time is it" → no PRD stub created (NATIVE mode)
- [ ] PRD stub has correct frontmatter (task, slug, effort: standard, phase: observe)
- [ ] If PRD already exists (resume), don't overwrite

---

╔═══════════════════════════════════════════════════╗
║  PHASE 3: ISC Count Gate + Auto Progress Counter  ║
║  ~/.claude/hooks/PRDSync.hook.ts                  ║
╚═══════════════════════════════════════════════════╝

## Phase 3: ISC Count Gate Warning + Progress Auto-Update

### Overview
PRDSync already reads the full PRD on every Write/Edit. Add two capabilities: (1) count ISC criteria and inject a warning if below the effort tier floor, (2) auto-compute and compare `progress: checked/total` against what the LLM wrote.

### Changes Required:

**File**: `~/.claude/hooks/PRDSync.hook.ts`

#### 3a. Add criteria counting function
```typescript
const EFFORT_FLOORS: Record<string, number> = {
  standard: 8, extended: 16, advanced: 24, deep: 40, comprehensive: 64,
};

function countCriteria(prdContent: string): { total: number; checked: number } {
  const lines = prdContent.split('\n');
  let total = 0, checked = 0;
  for (const line of lines) {
    const trimmed = line.trim();
    if (trimmed.startsWith('- [x]') || trimmed.startsWith('- [X]')) { total++; checked++; }
    else if (trimmed.startsWith('- [ ]')) { total++; }
  }
  return { total, checked };
}
```

#### 3b. Add gate check + progress sync after existing sync logic
After `syncToWorkJson()` completes, add:
```typescript
const { total, checked } = countCriteria(prdContent);
const effort = (fm.effort || 'standard').toLowerCase();
const floor = EFFORT_FLOORS[effort] || 8;

// Auto-update progress in work.json (PRDSync already writes here)
const computedProgress = `${checked}/${total}`;
// This is informational — the hook updates work.json, the LLM updates PRD frontmatter

// ISC count gate warning — inject via stderr so it shows in hook output
if (total > 0 && total < floor && fm.phase === 'observe') {
  console.error(`[PRDSync] ⚠️ ISC COUNT GATE: ${total} criteria < ${floor} floor for ${effort} effort. Decompose further before proceeding to THINK.`);
}
```

### Success Criteria:

#### Automated Verification:
- [x] Hook parses without errors
- [ ] Warning message appears in hook stderr when criteria count < floor

#### Manual Verification:
- [ ] Write PRD with effort: extended and 5 ISC criteria → see gate warning
- [ ] Write PRD with effort: standard and 10 ISC criteria → no warning
- [ ] Progress counter in work.json matches actual checked/total from PRD content

---

╔═══════════════════════════════════════════════════╗
║  PHASE 4: JSONL Reflection at SessionEnd          ║
║  ~/.claude/hooks/WorkCompletionLearning.hook.ts   ║
╚═══════════════════════════════════════════════════╝

## Phase 4: Algorithm Reflections JSONL Append

### Overview
WorkCompletionLearning already reads PRD.md, extracts criteria counts, and writes a learning markdown file. Add a JSONL append for Algorithm sessions that captures the structured data the LLM currently builds via `echo` command.

### Changes Required:

**File**: `~/.claude/hooks/WorkCompletionLearning.hook.ts`

#### 4a. Add JSONL append function
```typescript
import { appendFileSync } from 'fs';

function appendAlgorithmReflection(
  saiDir: string,
  meta: { title: string; slug: string; effort: string; session_id: string },
  criteria: { checked: number; total: number },
  startedAt: string,
): void {
  const reflectionsPath = join(saiDir, 'MEMORY', 'LEARNING', 'REFLECTIONS', 'algorithm-reflections.jsonl');
  const dir = join(saiDir, 'MEMORY', 'LEARNING', 'REFLECTIONS');
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });

  const entry = {
    timestamp: new Date().toISOString(),
    effort_level: meta.effort || 'standard',
    task_description: meta.title || '',
    criteria_count: criteria.total,
    criteria_passed: criteria.checked,
    criteria_failed: criteria.total - criteria.checked,
    prd_id: meta.slug || '',
    session_id: meta.session_id || '',
    within_budget: true, // hook can't measure time — LLM overrides in LEARN if false
    source: 'hook-auto-capture',
  };

  try {
    appendFileSync(reflectionsPath, JSON.stringify(entry) + '\n');
  } catch {
    // non-fatal
  }
}
```

#### 4b. Call during learning extraction
In the existing learning capture flow, after PRD frontmatter is parsed and ISC criteria are counted, add:
```typescript
// Only for Algorithm sessions (category === 'ALGORITHM')
if (category === 'ALGORITHM' && workMeta.slug) {
  appendAlgorithmReflection(saiDir, workMeta, { checked, total }, workMeta.started || '');
}
```

### Success Criteria:

#### Automated Verification:
- [x] Hook parses without errors
- [ ] `MEMORY/LEARNING/REFLECTIONS/` directory exists after first run

#### Manual Verification:
- [ ] End an Algorithm session → check `algorithm-reflections.jsonl` has new entry
- [ ] Entry has correct criteria_passed/criteria_total from PRD
- [ ] Entry has `source: "hook-auto-capture"` to distinguish from LLM-written entries
- [ ] End a NATIVE session → no JSONL entry appended (Algorithm only)

---

╔═══════════════════════════════════════════════════╗
║  PHASE 5: Split Algorithm into Core + Appendices  ║
║  SAI/Algorithm/v3.7.0.md + appendices/            ║
╚═══════════════════════════════════════════════════╝

## Phase 5: Lazy-Load Algorithm Appendices

### Overview
Extract ~2,200 tokens of conditionally-needed content from v3.7.0.md into separate files under `SAI/Algorithm/appendices/`. The Algorithm instructions reference them with "Read `appendices/X.md` if [condition]" instead of carrying the content inline.

### Changes Required:

#### 5a. Create appendix directory
```bash
mkdir -p SAI/Algorithm/appendices
```

#### 5b. Extract ISC decomposition examples (v3.7.0.md lines 333-367)
**New file**: `SAI/Algorithm/appendices/ISC_EXAMPLES.md`

Content: The full blog post decomposition example (coarse vs atomic) + granularity comparison. Extracted verbatim from v3.7.0.md.

**Replace in v3.7.0.md** with:
```markdown
**Granularity example:** See `SAI/Algorithm/appendices/ISC_EXAMPLES.md` for detailed decomposition examples (coarse vs atomic, domain-specific patterns). Load this file if ISC count is below the effort tier floor and you need decomposition guidance.
```

#### 5c. Extract capability selection examples (v3.7.0.md lines 499-537)
**New file**: `SAI/Algorithm/appendices/CAPABILITY_EXAMPLES.md`

Content: The two RPG game examples + selection methodology narrative. Extracted verbatim.

**Replace in v3.7.0.md** with:
```markdown
**Capability selection examples:** See `SAI/Algorithm/appendices/CAPABILITY_EXAMPLES.md` for worked examples (research task, comprehensive build). Load this file for Extended+ effort when selecting capabilities.
```

#### 5d. Extract stub creation pattern (v3.7.0.md lines 267-293)
**New file**: `SAI/Algorithm/appendices/STUB_PATTERN.md`

Content: The stub creation pattern, auto-transitions, and the "never manually force blocked→open" rule.

**Replace in v3.7.0.md** with:
```markdown
**Stub creation pattern:** When saving a card whose body references concepts that don't exist yet, read `SAI/Algorithm/appendices/STUB_PATTERN.md` for the stub creation flow (propose stubs, save as blocked, wire blockers).
```

#### 5e. Extract context recovery (v3.7.0.md lines 710-724)
**New file**: `SAI/Algorithm/appendices/CONTEXT_RECOVERY.md`

Content: The recovery procedure for lost context mid-Algorithm.

**Replace in v3.7.0.md** with:
```markdown
**Context recovery:** If you lose track of current phase or criteria status after compaction, read `SAI/Algorithm/appendices/CONTEXT_RECOVERY.md`.
```

### Success Criteria:

#### Automated Verification:
- [x] All 4 appendix files exist: `ls SAI/Algorithm/appendices/*.md | wc -l` returns 4
- [x] v3.7.0.md line count reduced by ~140 lines (from 724 to ~580)
- [x] No broken references — each appendix path mentioned in v3.7.0.md matches an actual file
- [x] `grep -c 'appendices/' SAI/Algorithm/v3.7.0.md` returns 4 (one reference per appendix)

#### Manual Verification:
- [ ] Algorithm entry loads slimmed file — noticeably less context consumed
- [ ] When ISC count gate fails, LLM reads ISC_EXAMPLES.md on demand
- [ ] For Extended+ effort, LLM reads CAPABILITY_EXAMPLES.md on demand
- [ ] Normal Standard effort runs never load the appendix files

---

╔═══════════════════════════════════════════════╗
║  PHASE 6: Slim Algorithm Instructions          ║
║  SAI/Algorithm/v3.7.0.md                      ║
╚═══════════════════════════════════════════════╝

## Phase 6: Remove Deterministic Instructions from Algorithm

### Overview
Now that hooks handle voice curls, PRD stub creation, progress counting, ISC gate warnings, and JSONL reflection — remove or simplify the corresponding LLM instructions in v3.7.0.md. Replace with brief notes that hooks handle these operations.

### Changes Required:

#### 6a. Voice curl instructions (lines 22-35, 381, 401, 541, 566, 576, 585, 592, 604)
**Replace** the voice curl code blocks and instructions with:
```markdown
### Voice Announcements

Voice announcements are handled automatically by the PRDSync hook on phase transitions. When you edit the PRD frontmatter `phase:` field, the hook fires the appropriate voice curl. You do NOT need to call curl yourself.

**CRITICAL: Only the primary agent's PRD edits trigger voice.** Background agents editing PRDs in worktrees will not trigger voice — this is correct behavior.
```

#### 6b. PRD stub creation (lines 383-398)
**Replace** the mkdir + Write instructions with:
```markdown
**PRD stub (created by hook):** The SessionAutoName hook creates `MEMORY/WORK/{slug}/PRD.md` with stub frontmatter when it detects Algorithm keywords in your first prompt. By the time you reach OBSERVE, the PRD already exists. Your job is to **Edit** the existing PRD — update frontmatter fields and add body sections. If no PRD exists (hook didn't fire), create it yourself using the format in `SAI/PRDFORMAT.md`.
```

#### 6c. Progress counter instructions (line 588)
**Replace** "update frontmatter `progress:` field" instruction with:
```markdown
- As each criterion is satisfied, IMMEDIATELY edit the PRD: change `- [ ]` to `- [x]`. The PRDSync hook auto-computes the progress counter in work.json. You MAY also update the frontmatter `progress:` field, but the hook is the authoritative source.
```

#### 6d. JSONL reflection (lines 622-628)
**Replace** the `echo '{...}' >> algorithm-reflections.jsonl` block with:
```markdown
- **JSONL reflection (auto-captured by hook):** The WorkCompletionLearning hook appends a structured entry to `algorithm-reflections.jsonl` at session end, using criteria counts from the PRD. You do NOT need to run the echo command yourself. If you want to add fields the hook can't capture (like `implied_sentiment` or `within_budget: false`), you may still append manually — the hook's entry has `source: "hook-auto-capture"` to distinguish.
```

#### 6e. ISC count gate (lines 437-449)
**Add note** that hook also enforces this:
```markdown
**ISC COUNT GATE (enforced by hook AND by you):** The PRDSync hook injects a warning when ISC count < effort floor. You will see `⚠️ ISC COUNT GATE` in the hook output. Even without the warning, you MUST verify the count yourself — the hook is a safety net, not a replacement for your judgment.
```

#### 6f. Bump version header
Change line 0 from `## The Algorithm 3.7.0` to `## The Algorithm 3.8.0` and update `SAI/Algorithm/LATEST` to `3.8.0`.

### Success Criteria:

#### Automated Verification:
- [x] v3.7.0.md (now 3.8.0) has no `curl -s -X POST` commands (voice curl removed): `grep -c 'curl.*localhost:8888' SAI/Algorithm/v3.7.0.md` returns 0
- [x] No `echo.*algorithm-reflections.jsonl` commands: `grep -c 'algorithm-reflections.jsonl' SAI/Algorithm/v3.7.0.md` returns 0 or only the hook reference
- [ ] No `mkdir -p MEMORY/WORK` instructions: `grep -c 'mkdir.*MEMORY/WORK' SAI/Algorithm/v3.7.0.md` returns 0
- [x] `SAI/Algorithm/LATEST` contains `3.8.0`
- [ ] CLAUDE.md references v3.8.0 (or the LATEST symlink resolves correctly)

#### Manual Verification:
- [ ] Start new Algorithm session — everything works end-to-end with hooks handling mechanics
- [ ] Voice fires on phase transitions via hook (not LLM curl)
- [ ] PRD exists before LLM enters OBSERVE
- [ ] ISC gate warning appears when criteria < floor
- [ ] JSONL entry appears at session end without LLM echo command
- [ ] Extended effort run: LLM loads CAPABILITY_EXAMPLES.md on demand
- [ ] Standard effort run: appendix files never loaded

---

## Testing Strategy

### Per-Phase Testing:
Each phase can be tested independently by modifying the hook, starting a session, and observing behavior. No automated test runner exists for hooks — verification is manual observation of hook stderr + file system state.

### Integration Test (after all phases):
1. Start a fresh Claude Code session
2. Type a prompt with algo keyword: "implement a rate limiter"
3. Verify: PRD stub exists in `MEMORY/WORK/`
4. Verify: Voice says "Entering the Algorithm" (if voice server running)
5. LLM enters OBSERVE, writes ISC criteria to PRD
6. Verify: If <8 criteria, hook stderr shows ISC COUNT GATE warning
7. LLM progresses through phases, checking off criteria
8. Verify: work.json progress updates on each PRD edit
9. Verify: Voice fires at each phase transition
10. End session
11. Verify: `algorithm-reflections.jsonl` has new entry with correct counts
12. Verify: Learning file created in `MEMORY/LEARNING/ALGORITHM/`

### Rollback:
If any hook change causes issues, the LLM instructions in v3.7.0.md still work as fallback — the hooks are additive (they do things the LLM was already doing), not subtractive (they don't block the LLM from doing them too). The Phase 6 instruction slimming is the only destructive change and should be done last.

## Performance Considerations

- Hook execution is synchronous and blocks the response. Voice curl has a 3s timeout to prevent hangs.
- PRD stub creation adds ~10ms to the SessionAutoName hook (mkdir + writeFile).
- ISC counting adds ~1ms per PRD edit (string split + line counting).
- JSONL append adds ~1ms at session end.
- Lazy loading saves ~2,200 tokens from context window on every Algorithm run where appendices aren't needed.

## Migration Notes

- Phase 6 (instruction slimming) MUST be done last — it removes the LLM's fallback instructions. Phases 1-5 are additive and can be done in any order.
- The version bump from 3.7.0 → 3.8.0 should update: the file header, `SAI/Algorithm/LATEST`, and `CLAUDE.md` reference (if it hardcodes the version).
- Existing `algorithm-reflections.jsonl` entries have no `source` field — new entries from the hook have `source: "hook-auto-capture"`. LLM-written entries (if any) won't have this field. Consumers should handle both.

## References

- Research: `thoughts/shared/research/2026-04-12-algorithm-determinism-context-efficiency.md`
- Algorithm: `SAI/Algorithm/v3.7.0.md` (724 lines, ~15K tokens)
- PRDSync hook: `~/.claude/hooks/PRDSync.hook.ts`
- SessionAutoName hook: `~/.claude/hooks/SessionAutoName.hook.ts`
- WorkCompletionLearning hook: `~/.claude/hooks/WorkCompletionLearning.hook.ts`
- PRD format: `SAI/PRDFORMAT.md`
- Phase-tab mapping: `~/.claude/hooks/lib/tab-constants.ts`
- Hook→MCP bridge (future Path B): `apps/silmari-mcp/src/index.ts:742` exports `dispatchTool`
