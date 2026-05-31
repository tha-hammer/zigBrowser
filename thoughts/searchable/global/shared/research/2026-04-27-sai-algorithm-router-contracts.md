---
date: 2026-04-27T11:42:32-04:00
researcher: TopazStream
git_commit: 437b92010b65b89588085278dcb0081a2b639c70
branch: main
repository: silmari-agent-memory
topic: "SAI Algorithm router research API contracts and interfaces"
tags: [research, codebase, sai, algorithm, router, prd, hooks, skills, agents, arbol, contracts]
status: complete
last_updated: 2026-04-27
last_updated_by: TopazStream
---

# Research: SAI Algorithm Router API Contracts and Interfaces

```
┌──────────────────────────────────────────────────────────────┐
│ SAI Algorithm Router Contracts                               │
│ Status: complete                                             │
│ Date: 2026-04-27 11:42:32 -04:00                             │
└──────────────────────────────────────────────────────────────┘
```

**Date**: 2026-04-27 11:42:32 -04:00  
**Researcher**: TopazStream  
**Git Commit**: 437b92010b65b89588085278dcb0081a2b639c70  
**Branch**: main  
**Repository**: silmari-agent-memory

## Research Question

Document the main router for the SAI infrastructure, "the algorithm", including research API contracts and interfaces across:

- `SAI/SKILLSYSTEM.md`
- `SAI/PAISYSTEMARCHITECTURE.md` / current `SAI/SAISYSTEMARCHITECTURE.md`
- `SAI/PAIAGENTSYSTEM.md` / current `SAI/SAIAGENTSYSTEM.md`
- `SAI/DOCUMENTATIONINDEX.md`
- `SAI/Tools/algorithm.ts`
- `SAI/CLI.md`
- `SAI/PRDFORMAT.md`
- `SAI/MEMORYSYSTEM.md`

Note: the requested `PAISYSTEMARCHITECTURE.md` and `PAIAGENTSYSTEM.md` paths are not present under those names in this checkout. The current matching files are `SAI/SAISYSTEMARCHITECTURE.md` and `SAI/SAIAGENTSYSTEM.md`.

## Summary

The SAI Algorithm exists in two overlapping forms:

| Layer | Current interface | Contract role |
|---|---|---|
| Architecture | `SAI/SAISYSTEMARCHITECTURE.md` | Defines the Algorithm as the center of SAI: Current State -> Ideal State by verifiable iteration |
| Runtime spec | `SAI/Algorithm/v3.8.1.md` via `SAI/Algorithm/LATEST` | Defines phase behavior, capability selection, PRD ownership, memory lifecycle |
| CLI runner | `SAI/Tools/algorithm.ts` | Executes PRD-based loop and interactive modes; spawns Claude processes |
| Work contract | `SAI/PRDFORMAT.md`, `SAI/hooks/lib/prd-template.ts` | Defines PRD frontmatter, ISC checkboxes, and work directory shape |
| Hook bridge | `SAI/hooks/PRDSync.hook.ts`, `SAI/hooks/lib/prd-utils.ts` | Reads PRD writes and projects derived state into `MEMORY/STATE/work.json` |
| Runtime state | `MEMORY/STATE/algorithms/`, `session-names.json`, `work.json` | Stores loop state, display names, and work registry |
| Skill router | `SAI/SKILLSYSTEM.md` | Uses `USE WHEN` frontmatter plus workflow routing tables |
| Agent router | `SAI/SAIAGENTSYSTEM.md` | Separates Task tool agents, named agents, and custom ComposeAgent agents |
| Adjacent CLI layer | `SAI/ACTIONS/pai.ts`, `runner.v2.ts`, `pipeline-runner.ts` | JSON-in/JSON-out action and pipeline machinery, separate from Algorithm CLI |

The live CLI contract is PRD-centric. `SAI/Tools/algorithm.ts` accepts PRD paths or PRD IDs, parses ISC checkboxes, updates PRD frontmatter and checkboxes, writes loop state under `MEMORY/STATE/algorithms/{sessionId}.json`, writes display names to `session-names.json`, and delegates execution to `claude` subprocesses. The Arbol / `pai` surface is a separate JSON action/pipeline interface and is not invoked by `algorithm.ts` in the inspected implementation.

## Detailed Findings

### Architecture Role

`SAI/SAISYSTEMARCHITECTURE.md` describes SAI as scaffolding for AI and identifies the continuously upgrading Algorithm as the center of the system. It frames the Algorithm as a universal Current State -> Ideal State pattern with verifiable iteration and says memory, hooks, learning directories, sentiment analysis, and ratings feed back into improving the Algorithm.

| Architecture element | Where it appears | Current behavior |
|---|---|---|
| Centerpiece Algorithm | [`SAI/SAISYSTEMARCHITECTURE.md:64`](https://github.com/tha-hammer/silmari-agent-memory/blob/437b92010b65b89588085278dcb0081a2b639c70/SAI/SAISYSTEMARCHITECTURE.md#L64) | Algorithm is the core problem-solving loop |
| Feedback inputs | [`SAI/SAISYSTEMARCHITECTURE.md:66`](https://github.com/tha-hammer/silmari-agent-memory/blob/437b92010b65b89588085278dcb0081a2b639c70/SAI/SAISYSTEMARCHITECTURE.md#L66) | Memory, hooks, learning, sentiment, ratings feed improvement |
| CLI-first principle | [`SAI/SAISYSTEMARCHITECTURE.md:267`](https://github.com/tha-hammer/silmari-agent-memory/blob/437b92010b65b89588085278dcb0081a2b639c70/SAI/SAISYSTEMARCHITECTURE.md#L267) | Operations should be accessible by command line |
| Skill architecture | [`SAI/SAISYSTEMARCHITECTURE.md:287`](https://github.com/tha-hammer/silmari-agent-memory/blob/437b92010b65b89588085278dcb0081a2b639c70/SAI/SAISYSTEMARCHITECTURE.md#L287) | Skills are self-activating, self-contained, composable, evolvable |

The runtime Algorithm pointer is `SAI/Algorithm/LATEST`, which points to `v3.8.1`. In that spec, ALGORITHM mode owns every tool call, investigation, and decision once selected, and selected capabilities must be invoked through `Skill` or `Task`.

### Algorithm CLI Surface

`SAI/Tools/algorithm.ts` is a standalone Bun executable. It has no exported TypeScript API in the inspected file; the interface is the command-line dispatch at the bottom of the script.

| Command | Implementation | Contract |
|---|---|---|
| `algorithm -m loop -p <PRD>` | [`SAI/Tools/algorithm.ts:1515`](https://github.com/tha-hammer/silmari-agent-memory/blob/437b92010b65b89588085278dcb0081a2b639c70/SAI/Tools/algorithm.ts#L1515) | Autonomous loop mode |
| `algorithm -m interactive -p <PRD>` | [`SAI/Tools/algorithm.ts:1518`](https://github.com/tha-hammer/silmari-agent-memory/blob/437b92010b65b89588085278dcb0081a2b639c70/SAI/Tools/algorithm.ts#L1518) | Launches interactive Claude with PRD context |
| `algorithm new -t <title>` | [`SAI/Tools/algorithm.ts:1481`](https://github.com/tha-hammer/silmari-agent-memory/blob/437b92010b65b89588085278dcb0081a2b639c70/SAI/Tools/algorithm.ts#L1481) | Creates a PRD from the shared template |
| `algorithm status [-p <PRD>]` | [`SAI/Tools/algorithm.ts:1477`](https://github.com/tha-hammer/silmari-agent-memory/blob/437b92010b65b89588085278dcb0081a2b639c70/SAI/Tools/algorithm.ts#L1477) | Shows PRD status |
| `algorithm pause -p <PRD>` | [`SAI/Tools/algorithm.ts:1491`](https://github.com/tha-hammer/silmari-agent-memory/blob/437b92010b65b89588085278dcb0081a2b639c70/SAI/Tools/algorithm.ts#L1491) | Writes `loopStatus: paused` |
| `algorithm resume -p <PRD>` | [`SAI/Tools/algorithm.ts:1495`](https://github.com/tha-hammer/silmari-agent-memory/blob/437b92010b65b89588085278dcb0081a2b639c70/SAI/Tools/algorithm.ts#L1495) | Writes `loopStatus: running`, then calls `runLoop` |
| `algorithm stop -p <PRD>` | [`SAI/Tools/algorithm.ts:1499`](https://github.com/tha-hammer/silmari-agent-memory/blob/437b92010b65b89588085278dcb0081a2b639c70/SAI/Tools/algorithm.ts#L1499) | Writes `loopStatus: stopped` |

The argument parser accepts `-m/--mode`, `-p/--prd`, `-n/--max`, `-a/--agents`, `-t/--title`, `-e/--effort`, and `-h/--help`. Parallel agent count is validated as 1-16.

### PRD Contract

The declared PRD contract in `SAI/PRDFORMAT.md` says the PRD is the single source of truth for every Algorithm run and that the AI writes PRD content directly while hooks only read PRDs to sync state.

| PRD area | Declared contract | Live implementation |
|---|---|---|
| Source of truth | [`SAI/PRDFORMAT.md:3`](https://github.com/tha-hammer/silmari-agent-memory/blob/437b92010b65b89588085278dcb0081a2b639c70/SAI/PRDFORMAT.md#L3) | `algorithm.ts` reads and writes PRD frontmatter/checklists |
| Lean frontmatter | [`SAI/PRDFORMAT.md:10`](https://github.com/tha-hammer/silmari-agent-memory/blob/437b92010b65b89588085278dcb0081a2b639c70/SAI/PRDFORMAT.md#L10) | `task`, `slug`, `effort`, `phase`, `progress`, `mode`, `started`, `updated` |
| CLI frontmatter | [`SAI/Tools/algorithm.ts:58`](https://github.com/tha-hammer/silmari-agent-memory/blob/437b92010b65b89588085278dcb0081a2b639c70/SAI/Tools/algorithm.ts#L58) | `prd`, `id`, `status`, `mode`, `effort_level`, `iteration`, `maxIterations`, `loopStatus`, `last_phase`, `failing_criteria`, `verification_summary` |
| Template frontmatter | [`SAI/hooks/lib/prd-template.ts:135`](https://github.com/tha-hammer/silmari-agent-memory/blob/437b92010b65b89588085278dcb0081a2b639c70/SAI/hooks/lib/prd-template.ts#L135) | Emits the broader v4 schema consumed by `algorithm.ts` |
| Criteria syntax | [`SAI/PRDFORMAT.md:57`](https://github.com/tha-hammer/silmari-agent-memory/blob/437b92010b65b89588085278dcb0081a2b639c70/SAI/PRDFORMAT.md#L57) | ISC checkbox lines |
| Global criteria parser | [`SAI/Tools/algorithm.ts:366`](https://github.com/tha-hammer/silmari-agent-memory/blob/437b92010b65b89588085278dcb0081a2b639c70/SAI/Tools/algorithm.ts#L366) | Counts `ISC-*` checkboxes anywhere in the PRD |
| `work.json` criteria parser | [`SAI/hooks/lib/prd-utils.ts:60`](https://github.com/tha-hammer/silmari-agent-memory/blob/437b92010b65b89588085278dcb0081a2b639c70/SAI/hooks/lib/prd-utils.ts#L60) | Extracts only from a top-level `## Criteria` section |

`algorithm.ts` uses a simple line-based YAML parser. It parses booleans, null, bracket arrays, unsigned integers, and strings, then defaults missing fields. `updateFrontmatter()` edits fields in place or appends them if they are missing.

### Loop Execution

Loop mode is implemented in `runLoop()`. The function validates the PRD path, reads frontmatter and content, rejects already-running loops, creates a loop state object, writes state, writes a session name, sets PRD `loopStatus: running`, and then repeatedly re-reads the PRD.

```text
PRD path/id
  -> resolvePRDPath()
  -> readPRD()
  -> countCriteria()
  -> createLoopState()
  -> write MEMORY/STATE/algorithms/{sessionId}.json
  -> spawn claude worker(s)
  -> re-read PRD
  -> update PRD + loop state + session-names.json
```

Exit conditions are all read from PRD frontmatter or iteration state:

| Exit | Trigger | State written |
|---|---|---|
| Complete | `status === "COMPLETE"` | `loopStatus: completed`, loop state inactive, session name `[COMPLETE]` |
| Blocked | `status === "BLOCKED"` | `loopStatus: completed`, loop state inactive, session name `[BLOCKED]` |
| Failed | `iteration >= max` | `loopStatus: failed`, loop state inactive, session name `[FAILED]` |
| Paused | `loopStatus === "paused"` | loop state finalized then kept `active = true`, `currentPhase = "PLAN"` |
| Stopped | `loopStatus === "stopped"` | loop state inactive, session name `[STOPPED]` |

Sequential loop execution uses `spawnSync("claude", ["-p", prompt, "--allowedTools", ...])` with a 10-minute timeout and cwd set to the PRD directory. Parallel loop execution uses `Bun.spawn(["claude", "-p", prompt, "--allowedTools", ...])` for each assignment.

### Parallel Agent Partitioning

Parallel mode is activated when `agentCount > 1` and more than one criterion is failing. `partitionCriteria()` groups failing criteria by the domain portion of `ISC-{DOMAIN}-{N}`, sorts groups by size, caps workers to the number of domains, and greedily balances groups across agents.

The worker prompt says each worker has one criterion, must not edit the PRD, must verify its criterion, must verify other criteria for regressions, and must print `RESULT: <ISC> PASS` or `RESULT: <ISC> FAIL`. The parent process then scans stdout for pass results and updates PRD checkboxes sequentially.

### Runtime State and Dashboard Contracts

Runtime state currently appears in three filesystem-backed stores plus one separate phase-report file.

| Store | Writer | Reader/consumer found |
|---|---|---|
| `MEMORY/STATE/algorithms/{sessionId}.json` | [`SAI/Tools/algorithm.ts:245`](https://github.com/tha-hammer/silmari-agent-memory/blob/437b92010b65b89588085278dcb0081a2b639c70/SAI/Tools/algorithm.ts#L245) | Only `algorithm.ts` reference found |
| `MEMORY/STATE/session-names.json` | [`SAI/Tools/algorithm.ts:262`](https://github.com/tha-hammer/silmari-agent-memory/blob/437b92010b65b89588085278dcb0081a2b639c70/SAI/Tools/algorithm.ts#L262), [`SAI/hooks/SessionAutoName.hook.ts:50`](https://github.com/tha-hammer/silmari-agent-memory/blob/437b92010b65b89588085278dcb0081a2b639c70/SAI/hooks/SessionAutoName.hook.ts#L50) | statusline, tab setter, LoadContext, PRD utils |
| `MEMORY/STATE/work.json` | [`SAI/hooks/lib/prd-utils.ts:16`](https://github.com/tha-hammer/silmari-agent-memory/blob/437b92010b65b89588085278dcb0081a2b639c70/SAI/hooks/lib/prd-utils.ts#L16) | PRDSync, docs for tab/dashboard consumers |
| `MEMORY/STATE/algorithm-phase.json` | [`SAI/Tools/AlgorithmPhaseReport.ts:18`](https://github.com/tha-hammer/silmari-agent-memory/blob/437b92010b65b89588085278dcb0081a2b639c70/SAI/Tools/AlgorithmPhaseReport.ts#L18) | AlgorithmPhaseReport tool |

The loop state shape includes `active`, `sessionId`, `taskDescription`, `currentPhase`, timestamps, `sla`, criteria, agents, capabilities, PRD path, phase history, `loopMode`, `loopIteration`, `loopMaxIterations`, `loopPrdId`, `loopPrdPath`, `loopHistory`, `parallelAgents`, and `mode`.

No live API route or React dashboard file was found that reads `MEMORY/STATE/algorithms/`, `loopMode`, `loopIteration`, `currentPhase`, or the `LoopAlgorithmState` file shape. The existing pipeline dashboard uses in-memory WebSocket state in `SAI/Tools/PipelineMonitor.ts` and `SAI/Tools/pipeline-monitor-ui/src/App.tsx`.

### PRDSync and Hook Boundary

`PRDSync.hook.ts` is a read-only PRD-to-`work.json` sync hook for PostToolUse Write/Edit. It only runs when the edited file path contains `MEMORY/WORK/` and ends with `PRD.md`. It parses frontmatter, reads existing registry phase, calls `syncToWorkJson()`, announces phase changes, sets tab state, and warns when OBSERVE criteria count is below the effort floor.

`syncToWorkJson()` writes sessions keyed by `fm.slug`, reads `session-names.json` for display names, stores PRD metadata, criteria, phase history, and prunes stale sessions. `upsertSession()` separately creates lightweight native/starting entries from SessionAutoName until PRDSync replaces them.

`current-work-{sessionId}.json` and `current-work.json` are consumed by SessionCleanup and WorkCompletionLearning. The observed expected fields are `session_id`, `session_dir`, `created_at`, optional `prd_path`, and legacy fields such as `current_task`, `task_title`, and `task_count`. No hook code in `SAI/hooks` was found that creates `current-work-{sessionId}.json`; docs say Algorithm/AI creates it.

### Skill Routing

`SAI/SKILLSYSTEM.md` defines the skill contract. Skill routing is two-stage:

1. Startup reads skill frontmatter and uses the mandatory single-line `description` with `USE WHEN` to activate a skill.
2. Once invoked, the skill body's `## Workflow Routing` table maps user intent to a workflow file.

| Contract | Reference |
|---|---|
| Authoritative skill structure | [`SAI/SKILLSYSTEM.md:7`](https://github.com/tha-hammer/silmari-agent-memory/blob/437b92010b65b89588085278dcb0081a2b639c70/SAI/SKILLSYSTEM.md#L7) |
| Mandatory `USE WHEN` | [`SAI/SKILLSYSTEM.md:181`](https://github.com/tha-hammer/silmari-agent-memory/blob/437b92010b65b89588085278dcb0081a2b639c70/SAI/SKILLSYSTEM.md#L181), [`SAI/DOCUMENTATIONINDEX.md:34`](https://github.com/tha-hammer/silmari-agent-memory/blob/437b92010b65b89588085278dcb0081a2b639c70/SAI/DOCUMENTATIONINDEX.md#L34) |
| Workflow routing table | [`SAI/SKILLSYSTEM.md:255`](https://github.com/tha-hammer/silmari-agent-memory/blob/437b92010b65b89588085278dcb0081a2b639c70/SAI/SKILLSYSTEM.md#L255) |
| Dynamic loading | [`SAI/SKILLSYSTEM.md:304`](https://github.com/tha-hammer/silmari-agent-memory/blob/437b92010b65b89588085278dcb0081a2b639c70/SAI/SKILLSYSTEM.md#L304) |
| Runtime summary | [`SAI/SKILLSYSTEM.md:963`](https://github.com/tha-hammer/silmari-agent-memory/blob/437b92010b65b89588085278dcb0081a2b639c70/SAI/SKILLSYSTEM.md#L963) |
| Directory structure | [`SAI/SKILLSYSTEM.md:664`](https://github.com/tha-hammer/silmari-agent-memory/blob/437b92010b65b89588085278dcb0081a2b639c70/SAI/SKILLSYSTEM.md#L664) |

The observed repo inventory contains 51 `SAI/skills/**/SKILL.md` files and 197 `SAI/skills/**/Workflows/*.md` files.

### Agent Routing

`SAI/SAIAGENTSYSTEM.md` is the authoritative agent routing reference. It distinguishes three systems that are part of the routing contract:

| Agent system | What it is | Routing behavior |
|---|---|---|
| Task tool subagent types | Built-in Claude Code agents such as Architect, Designer, Engineer, Explore | Internal workflow use |
| Named agents | Persistent identities with backstories and voices | Used for recurring identity/voice work |
| Custom agents | Dynamic agents composed from traits | Route through Agents skill and ComposeAgent |

When user language says "custom agents", the documented route is Agents skill -> ComposeAgent -> Task with `subagent_type="general-purpose"`. `SAI/skills/Agents/SKILL.md` documents this same route and distinguishes it from teams/swarms, which route through the Delegation skill.

### CLI and Arbol Adjacency

`SAI/CLI.md` documents two Bun CLI families:

| CLI | Input model | Execution target |
|---|---|---|
| Algorithm CLI | PRD path/id, ISC checkboxes, frontmatter | `claude` / `claude -p` subprocesses |
| Arbol / `pai` CLI | JSON stdin/flags/params | actions and pipelines |

The Algorithm CLI and Arbol CLI share the CLI-first principle, but no import or invocation of `SAI/ACTIONS/pai.ts`, `runner.v2.ts`, or `pipeline-runner.ts` was found in `SAI/Tools/algorithm.ts`.

Observed Arbol interfaces:

- Actions are JSON-in/JSON-out units with `action.json` and `action.ts`.
- `runner.v2.ts` loads manifests, resolves USER before system actions, injects capabilities, and calls `execute(input, ctx)`.
- Pipelines are ordered action chains where action N output becomes action N+1 input.
- `pipeline-runner.ts` loads YAML and invokes `runner.v2` sequentially.
- `pai.ts` exposes `pai action`, `pai pipeline`, `pai actions`, `pai pipelines`, and `pai info`; the current `pai pipeline` implementation exits with "Pipeline execution not yet implemented".

## Code References

| Reference | What is there |
|---|---|
| [`SAI/Tools/algorithm.ts:58`](https://github.com/tha-hammer/silmari-agent-memory/blob/437b92010b65b89588085278dcb0081a2b639c70/SAI/Tools/algorithm.ts#L58) | `PRDFrontmatter` expected by the CLI |
| [`SAI/Tools/algorithm.ts:81`](https://github.com/tha-hammer/silmari-agent-memory/blob/437b92010b65b89588085278dcb0081a2b639c70/SAI/Tools/algorithm.ts#L81) | `LoopAlgorithmState` state shape |
| [`SAI/Tools/algorithm.ts:148`](https://github.com/tha-hammer/silmari-agent-memory/blob/437b92010b65b89588085278dcb0081a2b639c70/SAI/Tools/algorithm.ts#L148) | CLI argument parsing |
| [`SAI/Tools/algorithm.ts:295`](https://github.com/tha-hammer/silmari-agent-memory/blob/437b92010b65b89588085278dcb0081a2b639c70/SAI/Tools/algorithm.ts#L295) | PRD frontmatter/content parser |
| [`SAI/Tools/algorithm.ts:343`](https://github.com/tha-hammer/silmari-agent-memory/blob/437b92010b65b89588085278dcb0081a2b639c70/SAI/Tools/algorithm.ts#L343) | PRD frontmatter updater |
| [`SAI/Tools/algorithm.ts:366`](https://github.com/tha-hammer/silmari-agent-memory/blob/437b92010b65b89588085278dcb0081a2b639c70/SAI/Tools/algorithm.ts#L366) | Global ISC checkbox parser |
| [`SAI/Tools/algorithm.ts:557`](https://github.com/tha-hammer/silmari-agent-memory/blob/437b92010b65b89588085278dcb0081a2b639c70/SAI/Tools/algorithm.ts#L557) | Domain-aware parallel criteria partitioning |
| [`SAI/Tools/algorithm.ts:660`](https://github.com/tha-hammer/silmari-agent-memory/blob/437b92010b65b89588085278dcb0081a2b639c70/SAI/Tools/algorithm.ts#L660) | Parallel iteration runner |
| [`SAI/Tools/algorithm.ts:864`](https://github.com/tha-hammer/silmari-agent-memory/blob/437b92010b65b89588085278dcb0081a2b639c70/SAI/Tools/algorithm.ts#L864) | Loop mode implementation |
| [`SAI/Tools/algorithm.ts:1114`](https://github.com/tha-hammer/silmari-agent-memory/blob/437b92010b65b89588085278dcb0081a2b639c70/SAI/Tools/algorithm.ts#L1114) | Sequential `claude -p` subprocess call |
| [`SAI/Tools/algorithm.ts:1207`](https://github.com/tha-hammer/silmari-agent-memory/blob/437b92010b65b89588085278dcb0081a2b639c70/SAI/Tools/algorithm.ts#L1207) | Interactive mode implementation |
| [`SAI/hooks/lib/prd-template.ts:119`](https://github.com/tha-hammer/silmari-agent-memory/blob/437b92010b65b89588085278dcb0081a2b639c70/SAI/hooks/lib/prd-template.ts#L119) | Shared PRD template generator |
| [`SAI/hooks/PRDSync.hook.ts:66`](https://github.com/tha-hammer/silmari-agent-memory/blob/437b92010b65b89588085278dcb0081a2b639c70/SAI/hooks/PRDSync.hook.ts#L66) | PRDSync path trigger |
| [`SAI/hooks/lib/prd-utils.ts:111`](https://github.com/tha-hammer/silmari-agent-memory/blob/437b92010b65b89588085278dcb0081a2b639c70/SAI/hooks/lib/prd-utils.ts#L111) | `work.json` PRD sync |
| [`SAI/hooks/SessionAutoName.hook.ts:144`](https://github.com/tha-hammer/silmari-agent-memory/blob/437b92010b65b89588085278dcb0081a2b639c70/SAI/hooks/SessionAutoName.hook.ts#L144) | Algorithm PRD stub creation |
| [`SAI/hooks/SessionCleanup.hook.ts:46`](https://github.com/tha-hammer/silmari-agent-memory/blob/437b92010b65b89588085278dcb0081a2b639c70/SAI/hooks/SessionCleanup.hook.ts#L46) | `current-work` lookup |
| [`SAI/ACTIONS/pai.ts:99`](https://github.com/tha-hammer/silmari-agent-memory/blob/437b92010b65b89588085278dcb0081a2b639c70/SAI/ACTIONS/pai.ts#L99) | Arbol CLI help surface |
| [`SAI/ACTIONS/lib/runner.v2.ts:113`](https://github.com/tha-hammer/silmari-agent-memory/blob/437b92010b65b89588085278dcb0081a2b639c70/SAI/ACTIONS/lib/runner.v2.ts#L113) | Action runner resolution |
| [`SAI/ACTIONS/lib/pipeline-runner.ts:56`](https://github.com/tha-hammer/silmari-agent-memory/blob/437b92010b65b89588085278dcb0081a2b639c70/SAI/ACTIONS/lib/pipeline-runner.ts#L56) | Sequential pipeline action execution |

## Architecture Documentation

### Router Flow

```text
User request
  -> Host mode routing
  -> ALGORITHM mode for complex work
  -> Algorithm spec phases
  -> PRD creation/update
  -> Skill and agent capability selection
  -> CLI loop or interactive execution
  -> Hooks project PRD into work.json
  -> Memory/learning hooks capture session output
```

### Interface Boundaries

| Boundary | Producer | Consumer | Data shape |
|---|---|---|---|
| PRD file | Algorithm / AI / `algorithm new` | Algorithm CLI, PRDSync, cleanup/learning hooks | Markdown + YAML frontmatter + ISC checkboxes |
| Loop state | Algorithm CLI | Algorithm CLI; documented dashboard target | JSON `LoopAlgorithmState` |
| Work registry | PRDSync / prd-utils / SessionAutoName | PRDSync, tab/status docs | JSON `{ sessions }` |
| Session names | SessionAutoName, Algorithm CLI | statusline, tab setter, LoadContext, prd-utils | JSON map from session id to name |
| Skill invocation | Claude Code skill loader | Algorithm capability selection | `USE WHEN` frontmatter + workflow table |
| Agent invocation | Algorithm / Delegation / Agents skill | Task tool / ComposeAgent | Task subagent type or composed prompt |
| Arbol action | `pai`, runner.v2, pipeline runner | local/cloud action execution | JSON input/output |

### Observed Interface Variants

These are current-state observations from source files, not proposed changes:

| Area | Observed variants |
|---|---|
| PRD schema | `PRDFORMAT.md` lean schema vs `prd-template.ts` v4 schema |
| PRD filename | PRDFORMAT and PRDSync target `PRD.md`; `algorithm new` writes `PRD-YYYYMMDD-slug.md` |
| Criteria section | Template nests under `## IDEAL STATE CRITERIA` / `### Criteria`; `prd-utils.ts` extracts from top-level `## Criteria`; `algorithm.ts` parses globally |
| Algorithm state | Loop CLI writes `STATE/algorithms/{sessionId}.json`; AlgorithmPhaseReport writes `STATE/algorithm-phase.json` |
| Dashboard readers | Docs mention dashboard/tab use; live search found no API/React reader for `STATE/algorithms/` |
| Arbol docs | `SAI/CLI.md` references `SAI/ARBOLSYSTEM.md`; that file is not present in this checkout |

## Historical Context (from thoughts/)

Paths are normalized by removing only the `searchable/` path component when applicable.

| Historical note | Context |
|---|---|
| `thoughts/shared/handoffs/general/2026-04-12_07-57-20_sai-rebrand-mcp-migration.md:23` | PAI and AAI collapsed into repo-root `SAI/`; Algorithm memory integration moved from bash `zettel` calls to `mcp__silmari__zk_*` |
| `thoughts/shared/research/2026-04-16-sai-pai-upstream-rebrand-audit.md:112` | Lists SAI-only docs including Algorithm, CLI, Memory, PRD format, architecture, and skill system |
| `thoughts/shared/research/2026-04-16-sai-pai-upstream-rebrand-audit.md:339` | Describes Claude Code finding SAI through `CLAUDE.md`, then Algorithm driving PRD creation, ZK recall, and hooks |
| `thoughts/shared/research/2026-04-12-algorithm-determinism-context-efficiency.md:58` | Identifies PRDSync, SessionAutoName, and WorkCompletionLearning as Algorithm-related hooks |
| `thoughts/shared/plans/2026-04-12-algorithm-hooks-determinism-lazy-load.md:437` | Records SessionAutoName PRD stub creation |
| `thoughts/shared/research/2026-04-22-silmari-orphan-cards-root-cause.md:160` | Documents Algorithm v3.8.1 memory placement decision tree for root/fork saves |
| `thoughts/shared/research/2026-04-25-sai-claude-codex-gemini-portability-research.md:194` | Records the current MCP boundary as Silmari domain API, not a general SAI runtime API |
| `thoughts/shared/research/2026-04-25-sai-claude-codex-gemini-portability-research.md:200` | Records skills as coupled to Claude Code startup/frontmatter routing and examples using `Skill(...)` / `Task(...)` |

## Related Research

- `thoughts/shared/research/2026-04-12-algorithm-determinism-context-efficiency.md`
- `thoughts/shared/research/2026-04-16-sai-pai-upstream-rebrand-audit.md`
- `thoughts/shared/research/2026-04-22-silmari-orphan-cards-root-cause.md`
- `thoughts/shared/research/2026-04-25-sai-claude-codex-gemini-portability-research.md`
- `thoughts/shared/plans/2026-04-12-algorithm-hooks-determinism-lazy-load.md`
- `thoughts/shared/plans/2026-04-13-tdd-algorithm-v381-phase0-zk-save-card-fromaddress-REVIEW.md`

## Open Questions

- No live reader was found for `MEMORY/STATE/algorithms/{sessionId}.json` outside `algorithm.ts`; dashboard/API consumption appears documented but not present in the inspected files.
- `SAI/ARBOLSYSTEM.md` is referenced by `SAI/CLI.md` but is not present in this checkout.
- `current-work-{sessionId}.json` is consumed by cleanup/learning hooks and described in docs as Algorithm/AI-created state; no hook creator was found in `SAI/hooks`.
- The direct requested `PAISYSTEMARCHITECTURE.md` and `PAIAGENTSYSTEM.md` filenames are absent; current equivalents are `SAISYSTEMARCHITECTURE.md` and `SAIAGENTSYSTEM.md`.

