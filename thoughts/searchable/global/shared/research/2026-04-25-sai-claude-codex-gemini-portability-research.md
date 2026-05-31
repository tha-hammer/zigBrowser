---
date: 2026-04-25T12:53:36-04:00
researcher: maceo
git_commit: 633e3293b0cb97b257d4bea001c0e669759214f8
branch: main
repository: silmari-agent-memory
topic: "SAI portability across Claude Code, Codex, and Gemini"
tags: [research, sai, claude-code, codex, gemini, hooks, skills, mcp, portability]
status: complete
last_updated: 2026-04-25
last_updated_by: maceo
last_updated_note: "Added follow-up research on moving SAI functions to MCP and whether current skills are invocable via MCP"
---

```
┌───────────────────────────────────────────────────────────────────────┐
│  SAI PORTABILITY RESEARCH                                             │
│  Status: COMPLETE   Date: 2026-04-25   Coverage: repo + plans + docs │
└───────────────────────────────────────────────────────────────────────┘
```

# Research: SAI Portability Across Claude Code, Codex, and Gemini

**Date**: 2026-04-25T12:53:36-04:00  
**Researcher**: maceo  
**Git Commit**: 633e3293b0cb97b257d4bea001c0e669759214f8  
**Branch**: main  
**Repository**: silmari-agent-memory

## Research Question

> This repo is currently pinned to Claude Code only. I want to research how to extend functionality to Codex and Gemini as well. We need to port the skills and hooks to make SAI work across the 3 major LLM providers.

## Summary

The current repo contains **two distinct layers**:

| Layer | What it is today | Current provider binding |
|---|---|---|
| **Silmari MCP product layer** | A memory server and architecture plans that are explicitly documented as usable by multiple MCP clients | **Provider-agnostic** |
| **SAI runtime layer** | A local agent shell installed into `~/.claude/` with `CLAUDE.md`, Claude lifecycle hooks, Claude task/skill tooling, and Claude CLI subprocesses | **Claude Code-specific** |
| **Provider-specific tools and agent personas** | Codex/Gemini researcher personas plus OpenAI/Gemini media/transcription utilities | **Mixed isolated integrations** |

In other words, the codebase already documents and partially implements **multi-client portability at the MCP boundary**, while the **skills, hooks, session lifecycle, and orchestration shell remain implemented as a Claude Code resident system**. Codex and Gemini already appear in the repo as **research-agent definitions, workflow references, and standalone tool integrations**, but not as alternative host runtimes for the SAI hook/skill control plane. Key evidence appears in [`README.md:9-15`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/README.md#L9-L15), [`README.md:75-85`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/README.md#L75-L85), [`SAI/README.md:3-20`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/README.md#L3-L20), [`SAI/settings.json:1-10`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/settings.json#L1-L10), and [`SAI/Tools/Inference.ts:71-92`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/Tools/Inference.ts#L71-L92).

## Detailed Findings

### 1. The Product Boundary Is Already Framed As Multi-Client MCP

The top-level Silmari docs and plans consistently describe the memory engine as an MCP surface that multiple LLM clients can share. The repo README says Silmari gives "any LLM client" access to a local Zettelkasten and names Claude Code, ChatGPT Desktop, Gemini, and Cursor directly in the opening description, while keeping the memory store local under `~/.silmari/` ([`README.md:9-15`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/README.md#L9-L15)).

Plan 001 uses MCP as the portability layer from the start. Its architecture diagram explicitly labels the client tier as "Any MCP Client (Claude Code / ChatGPT / Gemini / Cursor)" over JSON-RPC, and its portability section says the MCP server is transport-agnostic and that changing clients should not change the underlying memory ([`Plans/001_zettelkasten-agent-memory-mcp.md:36-44`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/Plans/001_zettelkasten-agent-memory-mcp.md#L36-L44), [`Plans/001_zettelkasten-agent-memory-mcp.md:617-623`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/Plans/001_zettelkasten-agent-memory-mcp.md#L617-L623)). The same plan sets a phase-exit criterion that Claude Code, ChatGPT Desktop, and at least one other MCP client can save and retrieve cards from the same store ([`Plans/001_zettelkasten-agent-memory-mcp.md:708-721`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/Plans/001_zettelkasten-agent-memory-mcp.md#L708-L721), [`Plans/001_zettelkasten-agent-memory-mcp.md:826-834`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/Plans/001_zettelkasten-agent-memory-mcp.md#L826-L834)).

The alpha-facing docs continue that split. `docs/ALPHA.md` describes the current alpha transport as stdio over SSH, provides configuration examples for Claude Desktop and Cursor, and marks HTTP+SSE as a later phase rather than the current default ([`docs/ALPHA.md:10-45`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/docs/ALPHA.md#L10-L45), [`docs/ALPHA.md:81-85`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/docs/ALPHA.md#L81-L85)). Plan 003 says HTTP transport is a future commercial/remote-client surface for Claude Desktop, Cursor, and similar clients, not part of the viewer itself ([`Plans/003_pai-fork-mcp-migration.md:34-40`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/Plans/003_pai-fork-mcp-migration.md#L34-L40), [`Plans/003_pai-fork-mcp-migration.md:193-202`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/Plans/003_pai-fork-mcp-migration.md#L193-L202)).

The related architecture memo in thoughts extends that same picture: stdio is the current baseline, Streamable HTTP is the remote transport path, and one VPS can act as the authoritative store for multiple clients/devices ([`thoughts/shared/research/2026-04-17-cosmic-separation-remote-mcp-architecture.md`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/thoughts/searchable/shared/research/2026-04-17-cosmic-separation-remote-mcp-architecture.md#L65-L142), [`thoughts/shared/research/2026-04-17-cosmic-separation-remote-mcp-architecture.md`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/thoughts/searchable/shared/research/2026-04-17-cosmic-separation-remote-mcp-architecture.md#L176-L210), [`thoughts/shared/research/2026-04-17-cosmic-separation-remote-mcp-architecture.md`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/thoughts/searchable/shared/research/2026-04-17-cosmic-separation-remote-mcp-architecture.md#L342-L342)).

### 2. The SAI Runtime Layer Is Implemented As A Claude Code Install

The `SAI/` subtree describes itself as a system that "runs inside Claude Code" and uses `CLAUDE.md` as its master configuration, loaded natively by Claude Code at session start ([`SAI/README.md:3-20`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/README.md#L3-L20)). The same README describes the rest of the runtime living alongside it under `~/.claude/` as hooks, skills, memory, and settings ([`SAI/README.md:21-33`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/README.md#L21-L33)).

This is not just documentation language. `SAI/settings.json` uses the Claude Code settings schema, sets `SAI_DIR` to `/home/maceo/.claude`, enables Claude-specific experimental agent teams, and registers hook lifecycles and status-line behavior in Claude's configuration surface ([`SAI/settings.json:1-10`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/settings.json#L1-L10), [`SAI/settings.json:67-70`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/settings.json#L67-L70), [`SAI/settings.json:218-270`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/settings.json#L218-L270), [`SAI/settings.json:271-273`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/settings.json#L271-L273)).

The installer follows the same model. The repo README states that `SAI/` is the source of truth but that `~/.claude/` is the derived install target, and the shell installer defaults to installing there in symlink or copy mode ([`README.md:73-103`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/README.md#L73-L103)). `SAI/install.sh` resolves its source tree, targets `${HOME}/.claude` by default, installs `agents`, `hooks`, `skills`, `SAI-Install`, `settings.json`, `statusline-command.sh`, and `CLAUDE.md.template`, then tells the user to open a Claude Code session and watch hooks fire ([`SAI/install.sh:18-20`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/install.sh#L18-L20), [`SAI/install.sh:82-85`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/install.sh#L82-L85), [`SAI/install.sh:171-180`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/install.sh#L171-L180), [`SAI/install.sh:198-203`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/install.sh#L198-L203)).

The bundled wizard installer is also Claude-centric. The bootstrap shell script says it installs SAI to `~/.claude`, checks for the `claude` binary, and the TypeScript engine installs Claude Code if missing and merges installer-managed settings while preserving hooks and status line state ([`SAI/SAI-Install/install.sh:61-67`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/SAI-Install/install.sh#L61-L67), [`SAI/SAI-Install/install.sh:135-146`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/SAI-Install/install.sh#L135-L146), [`SAI/SAI-Install/engine/actions.ts:367-389`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/SAI-Install/engine/actions.ts#L367-L389), [`SAI/SAI-Install/engine/actions.ts:503-629`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/SAI-Install/engine/actions.ts#L503-L629)).

`BuildCLAUDE.ts` closes the loop by generating `~/.claude/CLAUDE.md` from the template and settings file, again using hard-coded `~/.claude` paths ([`SAI/Tools/BuildCLAUDE.ts:18-23`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/Tools/BuildCLAUDE.ts#L18-L23)).

### 3. The Skill System Contract Is Claude-Native

The skill contract itself is defined in `SAI/SKILLSYSTEM.md`, and it explicitly says the `USE WHEN` phrase is mandatory because Claude Code parses it for skill activation. The same section describes frontmatter descriptions as single-line activation metadata with an Anthropic-imposed character limit ([`SAI/SKILLSYSTEM.md:177-199`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/SKILLSYSTEM.md#L177-L199)).

The document also describes workflow routing in terms of what Claude should execute after a skill is selected, and its dynamic-loading section says startup loads skill frontmatter for routing while full bodies load on invocation ([`SAI/SKILLSYSTEM.md:229-289`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/SKILLSYSTEM.md#L229-L289), [`SAI/SKILLSYSTEM.md:298-311`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/SKILLSYSTEM.md#L298-L311)).

The rest of the runtime matches that contract. `SAI/README.md` says `CLAUDE.md` is the master config; `SAI/settings.json` leaves `contextFiles` empty and instead uses SessionStart hooks plus `loadAtStartup.files` and injected `<system-reminder>` blocks for dynamic context ([`SAI/README.md:17-19`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/README.md#L17-L19), [`SAI/settings.json:914-927`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/settings.json#L914-L927)).

The routing and guard surfaces are also Claude-native:

- `SkillGuard.hook.ts` is a PreToolUse hook for the `Skill` tool and currently blocks only the false-positive `keybindings-help` activation path ([`SAI/settings.json:123-131`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/settings.json#L123-L131), [`SAI/hooks/SkillGuard.hook.ts:3-37`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/hooks/SkillGuard.hook.ts#L3-L37)).
- `AgentExecutionGuard.hook.ts` is a PreToolUse hook for the `Task` tool and emits a `<system-reminder>` warning when a non-fast agent is launched in the foreground ([`SAI/settings.json:114-122`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/settings.json#L114-L122), [`SAI/hooks/AgentExecutionGuard.hook.ts:3-17`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/hooks/AgentExecutionGuard.hook.ts#L3-L17), [`SAI/hooks/AgentExecutionGuard.hook.ts:84-100`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/hooks/AgentExecutionGuard.hook.ts#L84-L100)).
- `SAI/SAIAGENTSYSTEM.md` describes task-tool subagent types as pre-built agents in Claude Code, including `ClaudeResearcher`, `GeminiResearcher`, and `GrokResearcher` ([`SAI/SAIAGENTSYSTEM.md:11-15`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/SAIAGENTSYSTEM.md#L11-L15), [`SAI/SAIAGENTSYSTEM.md:71-89`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/SAIAGENTSYSTEM.md#L71-L89)).
- The standard Research workflow launches one Claude researcher task and one Gemini researcher task through `Task({ subagent_type: ... })`, again assuming the Claude task tool surface is present ([`SAI/skills/Research/Workflows/StandardResearch.md:23-45`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/skills/Research/Workflows/StandardResearch.md#L23-L45)).

The settings file also encodes those same assumptions in human-readable guidance: it lists researcher agents Claude/Gemini/Grok/Perplexity/Codex, warns against running `claude --print` inside Claude Code, and describes loop mode and interactive mode in terms of spawning `claude` sessions ([`SAI/settings.json:778-785`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/settings.json#L778-L785), [`SAI/settings.json:801-814`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/settings.json#L801-L814), [`SAI/settings.json:847-856`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/settings.json#L847-L856)).

### 4. The Hook Lifecycle Is Tied To Claude Session Semantics

The hook system README says directly that hooks are scripts that execute at specific lifecycle events in Claude Code and enumerates those events as `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop`, and `SessionEnd` ([`SAI/hooks/README.md:23-31`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/hooks/README.md#L23-L31), [`SAI/hooks/README.md:39-73`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/hooks/README.md#L39-L73), [`SAI/hooks/README.md:80-87`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/hooks/README.md#L80-L87)).

The runtime behaviors also assume Claude-specific payloads and transcript timing:

- `ThinkWithMemory.hook.ts` says it emits a `<system-reminder>` block "which Claude Code injects into the LLM's context for the current turn" and stores state under `~/.claude/MEMORY/STATE/...` ([`SAI/hooks/ThinkWithMemory.hook.ts:3-16`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/hooks/ThinkWithMemory.hook.ts#L3-L16), [`SAI/hooks/ThinkWithMemory.hook.ts:45-45`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/hooks/ThinkWithMemory.hook.ts#L45-L45)).
- `LoadContext.hook.ts` is registered on SessionStart and injects context into the session; `BuildCLAUDE` is also registered there to refresh `CLAUDE.md` for later sessions ([`SAI/settings.json:218-238`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/settings.json#L218-L238)).
- The hook I/O contract described in `SAI/hooks/README.md` expects JSON payloads with fields like `session_id`, `transcript_path`, `tool_name`, and `tool_input`, and its `Stop` event is defined as "Claude responds" ([`SAI/hooks/README.md:86-116`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/hooks/README.md#L86-L116)).
- The README's data-flow sections describe work tracking, response caching, and learning extraction as hooks around Claude session phases rather than around an MCP tool protocol ([`SAI/hooks/README.md:175-215`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/hooks/README.md#L175-L215)).

The same Claude coupling shows up in status/history tooling. The repo README says every open Claude Code window holds a long-lived stdio subprocess for `silmari-mcp`, and clients must run `/mcp Reconnect` after deploys ([`README.md:192-198`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/README.md#L192-L198)). The status line command is configured as a Claude status-line command in settings ([`SAI/settings.json:267-270`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/settings.json#L267-L270)).

### 5. Core SAI Inference And Algorithm Paths Invoke Claude CLI

`SAI/Tools/Inference.ts` is the central inference utility for fast/standard/smart reasoning levels, and its own header says billing uses Claude CLI subscription auth, not an API key. The implementation removes `ANTHROPIC_API_KEY` and `CLAUDECODE` from the environment, then spawns `claude --print --model ...` with hooks disabled ([`SAI/Tools/Inference.ts:7-30`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/Tools/Inference.ts#L7-L30), [`SAI/Tools/Inference.ts:71-92`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/Tools/Inference.ts#L71-L92)).

The settings file mirrors that architecture in prose, telling the system to use `bun Inference.ts` rather than a direct API, warning against running `claude --print` inside Claude Code, and describing loop and interactive modes as spawning Claude sessions ([`SAI/settings.json:801-814`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/settings.json#L801-L814), [`SAI/settings.json:847-856`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/settings.json#L847-L856)).

This means the orchestration shell is not just "configured for Claude"; it actively delegates core reasoning back into the `claude` binary as part of its implementation.

### 6. Codex And Gemini Already Exist, But Mostly As Personas And Isolated Tools

The repo already contains named Codex and Gemini research personas. `SAI/agents/CodexResearcher.md` defines a Codex-focused researcher with a mandatory startup sequence, a required SAI output format, and explicit `codex exec` examples using `o3`, `gpt-5-codex`, and `gpt-4` ([`SAI/agents/CodexResearcher.md:1-30`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/agents/CodexResearcher.md#L1-L30), [`SAI/agents/CodexResearcher.md:72-90`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/agents/CodexResearcher.md#L72-L90), [`SAI/agents/CodexResearcher.md:176-191`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/agents/CodexResearcher.md#L176-L191)). `SAI/agents/GeminiResearcher.md` defines the Gemini counterpart, with its own context load, voice requirements, and multi-perspective methodology ([`SAI/agents/GeminiResearcher.md:1-30`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/agents/GeminiResearcher.md#L1-L30), [`SAI/agents/GeminiResearcher.md:65-83`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/agents/GeminiResearcher.md#L65-L83), [`SAI/agents/GeminiResearcher.md:166-176`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/agents/GeminiResearcher.md#L166-L176)).

Those agents are reflected back into the main configuration. `SAI/settings.json` includes prose that names researcher agents Claude, Gemini, Grok, Perplexity, and Codex, and also mentions a Gemini-specific technical creativity workflow ([`SAI/settings.json:778-780`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/settings.json#L778-L780), [`SAI/settings.json:866-869`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/settings.json#L866-L869)).

The repo also has genuine multi-provider tool integrations:

- `SAI/skills/Media/Art/Tools/Generate.ts` imports OpenAI and Google GenAI clients, accepts OpenAI and Gemini model selections, calls OpenAI `gpt-image-1`, and calls Gemini `gemini-3-pro-image-preview` for Nano Banana Pro ([`SAI/skills/Media/Art/Tools/Generate.ts:15-18`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/skills/Media/Art/Tools/Generate.ts#L15-L18), [`SAI/skills/Media/Art/Tools/Generate.ts:60-64`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/skills/Media/Art/Tools/Generate.ts#L60-L64), [`SAI/skills/Media/Art/Tools/Generate.ts:576-601`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/skills/Media/Art/Tools/Generate.ts#L576-L601), [`SAI/skills/Media/Art/Tools/Generate.ts:604-681`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/skills/Media/Art/Tools/Generate.ts#L604-L681)).
- `SAI/Tools/ExtractTranscript.ts` is an OpenAI Whisper client that requires `OPENAI_API_KEY` and calls `openai.audio.transcriptions.create({ model: "whisper-1" })` ([`SAI/Tools/ExtractTranscript.ts:3-18`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/Tools/ExtractTranscript.ts#L3-L18), [`SAI/Tools/ExtractTranscript.ts:145-180`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/Tools/ExtractTranscript.ts#L145-L180), [`SAI/Tools/ExtractTranscript.ts:231-247`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/Tools/ExtractTranscript.ts#L231-L247)).
- `apps/silmari-viewer/pkg/search/embedder.go` and `config.go` define an `openai` embedding provider name, but `NewEmbedderFromConfig` currently returns a placeholder "not implemented" error for that provider ([`apps/silmari-viewer/pkg/search/embedder.go:5-19`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/apps/silmari-viewer/pkg/search/embedder.go#L5-L19), [`apps/silmari-viewer/pkg/search/config.go:34-46`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/apps/silmari-viewer/pkg/search/config.go#L34-L46)).

What does **not** exist in the same way is a Codex-native or Gemini-native replacement for the SAI host shell itself. The current Codex/Gemini presence is concentrated in agent definitions, workflow routing, and standalone tool/API integrations rather than in the hook lifecycle, master prompt generation, or session control path.

### 7. Historical Documents Already Describe The Same Split

Plan 003 frames the migration as a surface-and-coupling move: hooks and skills should stop reaching into `~/.claude`, the old bash `zettel` shim should disappear in favor of direct `mcp__silmari__*` tool use, and a clean clone should eventually work without prior `~/.claude` customization ([`Plans/003_pai-fork-mcp-migration.md:34-40`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/Plans/003_pai-fork-mcp-migration.md#L34-L40), [`Plans/003_pai-fork-mcp-migration.md:48-52`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/Plans/003_pai-fork-mcp-migration.md#L48-L52), [`Plans/003_pai-fork-mcp-migration.md:276-284`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/Plans/003_pai-fork-mcp-migration.md#L276-L284)).

The rebrand and installation research in thoughts describe the present system as a dual-layer architecture: repo-local `SAI/` as the source of truth, and `~/.claude/` as the derived install/runtime target. They also record that hooks and skills were gradually moved into `SAI/`-controlled source while the live runtime remained under `~/.claude` ([`thoughts/shared/research/2026-04-12-sai-installation-audit.md`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/thoughts/searchable/shared/research/2026-04-12-sai-installation-audit.md#L24-L66), [`thoughts/shared/research/2026-04-16-sai-pai-upstream-rebrand-audit.md`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/thoughts/searchable/shared/research/2026-04-16-sai-pai-upstream-rebrand-audit.md#L37-L54), [`thoughts/shared/plans/2026-04-16-sai-pai-rebrand-execution.md`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/thoughts/searchable/shared/plans/2026-04-16-sai-pai-rebrand-execution.md#L22-L58)).

## Code References

- [`README.md:9-15`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/README.md#L9-L15) - Top-level promise that Silmari serves multiple MCP clients.
- [`README.md:75-85`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/README.md#L75-L85) - `SAI/` as source of truth, `~/.claude/` as derived install target.
- [`README.md:192-198`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/README.md#L192-L198) - Open Claude Code windows retain long-lived stdio MCP subprocesses.
- [`SAI/README.md:3-20`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/README.md#L3-L20) - SAI described as running inside Claude Code with `CLAUDE.md` as master config.
- [`SAI/settings.json:1-10`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/settings.json#L1-L10) - Claude Code schema and Claude-oriented environment setup.
- [`SAI/settings.json:67-270`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/settings.json#L67-L270) - Hook registration and status-line binding.
- [`SAI/SKILLSYSTEM.md:177-199`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/SKILLSYSTEM.md#L177-L199) - Skill activation contract with Claude Code parsing `USE WHEN`.
- [`SAI/hooks/README.md:25-31`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/hooks/README.md#L25-L31) - Hooks defined as Claude Code lifecycle extensions.
- [`SAI/hooks/ThinkWithMemory.hook.ts:3-16`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/hooks/ThinkWithMemory.hook.ts#L3-L16) - Hook emits a `<system-reminder>` for Claude Code injection.
- [`SAI/Tools/BuildCLAUDE.ts:18-23`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/Tools/BuildCLAUDE.ts#L18-L23) - `CLAUDE.md` generation bound to `~/.claude`.
- [`SAI/Tools/Inference.ts:71-92`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/Tools/Inference.ts#L71-L92) - Core inference path spawns `claude --print`.
- [`SAI/skills/Research/Workflows/StandardResearch.md:23-45`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/skills/Research/Workflows/StandardResearch.md#L23-L45) - Research workflow dispatches Claude and Gemini subagent types through the Claude task tool.
- [`SAI/agents/CodexResearcher.md:176-191`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/agents/CodexResearcher.md#L176-L191) - Codex researcher persona embeds `codex exec` multi-model usage.
- [`SAI/agents/GeminiResearcher.md:166-176`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/agents/GeminiResearcher.md#L166-L176) - Gemini researcher persona defines multi-perspective Gemini methodology.
- [`SAI/skills/Media/Art/Tools/Generate.ts:576-681`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/skills/Media/Art/Tools/Generate.ts#L576-L681) - OpenAI and Gemini image generation implementations.
- [`SAI/Tools/ExtractTranscript.ts:145-180`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/Tools/ExtractTranscript.ts#L145-L180) - OpenAI Whisper transcription path.

## Architecture Documentation

The current architecture separates portability and orchestration into different layers:

1. **Memory/product portability layer**  
   Silmari's MCP server and plans describe a shared memory substrate reachable from multiple MCP clients over stdio today and HTTP transport later. This is the cross-provider contract.

2. **Host-runtime orchestration layer**  
   SAI provides prompts, hooks, skills, voice notifications, work tracking, and status UI by embedding itself into Claude Code's native config, lifecycle, tool model, and CLI. This is the current control plane.

3. **Provider-specific specialist layer**  
   Codex, Gemini, and OpenAI surfaces appear as specialist agents or standalone tools inside SAI rather than as replacements for the SAI host runtime.

That yields the following as-is map:

| Concern | Current implementation boundary |
|---|---|
| Memory tool surface | MCP (`apps/silmari-mcp`, plans, alpha docs) |
| Session lifecycle | Claude Code hooks in `SAI/settings.json` |
| Skill activation | Claude Code parsing of skill frontmatter |
| Prompt shell / master config | `CLAUDE.md` generated into `~/.claude` |
| Internal reasoning utility | `claude --print` through `SAI/Tools/Inference.ts` |
| Codex/Gemini presence | Research agents and standalone utilities |

## Historical Context (from thoughts/)

- [`thoughts/shared/research/2026-04-12-sai-installation-audit.md`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/thoughts/searchable/shared/research/2026-04-12-sai-installation-audit.md#L24-L66) - Describes the installer as a two-layer bootstrap+engine flow and records partial rebrand state under `~/.claude`.
- [`thoughts/shared/research/2026-04-16-sai-pai-upstream-rebrand-audit.md`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/thoughts/searchable/shared/research/2026-04-16-sai-pai-upstream-rebrand-audit.md#L37-L54) - Documents the deliberate repo-local `SAI/` vs system-wide `~/.claude/` dual-layer architecture.
- [`thoughts/shared/plans/2026-04-16-sai-pai-rebrand-execution.md`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/thoughts/searchable/shared/plans/2026-04-16-sai-pai-rebrand-execution.md#L22-L58) - Records the migration path that moved skills and hooks into repo-controlled source while preserving `~/.claude` as install target.
- [`thoughts/shared/research/2026-04-17-cosmic-separation-remote-mcp-architecture.md`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/thoughts/searchable/shared/research/2026-04-17-cosmic-separation-remote-mcp-architecture.md#L65-L142) - Documents remote MCP transport options and the single-user multi-device VPS pattern.

## Related Research

- [`thoughts/shared/research/2026-04-16-sai-pai-upstream-rebrand-audit.md`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/thoughts/searchable/shared/research/2026-04-16-sai-pai-upstream-rebrand-audit.md)
- [`thoughts/shared/research/2026-04-17-cosmic-separation-remote-mcp-architecture.md`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/thoughts/searchable/shared/research/2026-04-17-cosmic-separation-remote-mcp-architecture.md)
- [`thoughts/shared/research/2026-04-12-sai-installation-audit.md`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/thoughts/searchable/shared/research/2026-04-12-sai-installation-audit.md)
- [`Plans/003_pai-fork-mcp-migration.md`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/Plans/003_pai-fork-mcp-migration.md)
- [`Plans/001_zettelkasten-agent-memory-mcp.md`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/Plans/001_zettelkasten-agent-memory-mcp.md)

## Open Questions

- The repo documents a future state where hooks and skills stop depending on `~/.claude`, but the live implementation still uses `~/.claude` as the active host runtime. Further investigation would need to trace exactly which SAI behaviors are intended to remain host-resident and which are intended to move behind MCP.
- This note maps the current repository only. It does not include an external capability matrix for Codex or Gemini host runtimes outside this repo.
- As of 2026-04-25, `bd list --status=open` succeeds and shows 11 open issues. Based on issue titles, none are explicitly about SAI portability across Claude Code, Codex, and Gemini. The closest visible adjacent item is `silmari-agent-memory-xom` ("Viewer fork-and-strip toward Zettelkasten-native"), which concerns the viewer/product surface rather than the SAI host-runtime portability described in this note.

## Follow-up Research 2026-04-25T14:00:40-04:00

The current MCP boundary is a **Silmari domain API**, not a general SAI runtime API. The server describes itself as a thin facade over the Zettelkasten library, and its exposed surface is the `zk_*` tool set plus static `silmari://` resources. There is no generic `run_skill`, `invoke_workflow`, or `run_hook` tool in the current server surface or dispatcher ([`apps/silmari-mcp/src/index.ts:3-10`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/apps/silmari-mcp/src/index.ts#L3-L10), [`apps/silmari-mcp/src/index.ts:101-400`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/apps/silmari-mcp/src/index.ts#L101-L400), [`apps/silmari-mcp/src/index.ts:498-776`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/apps/silmari-mcp/src/index.ts#L498-L776)).

There is already an in-repo MCP client path for local consumers. The `silmari` CLI spawns the local stdio server, performs the MCP handshake, dispatches one tool or resource call, prints the JSON result, and exits. So "call Silmari via MCP from local code" is already an established mechanism in this repo; it is just not yet the universal call path for SAI ([`apps/silmari-mcp/src/cli.ts:3-10`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/apps/silmari-mcp/src/cli.ts#L3-L10), [`apps/silmari-mcp/src/cli.ts:168-210`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/apps/silmari-mcp/src/cli.ts#L168-L210)).

The prompt layer has already partially migrated to MCP consumption. The Algorithm and `/silmari` command both instruct Claude Code to call `mcp__silmari__zk_*` tools directly instead of shelling out to the deleted `zettel` CLI ([`SAI/Algorithm/v3.8.1.md:27-40`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/Algorithm/v3.8.1.md#L27-L40), [`SAI/commands/silmari.md:1-25`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/commands/silmari.md#L1-L25)). Plan 003 states the same direction more explicitly: hooks and skills should stop reaching into `~/.claude`, and the migration target is consumption of the existing `mcp__silmari__zk_*` surface rather than introducing a new generic MCP orchestration API ([`Plans/003_pai-fork-mcp-migration.md:38-40`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/Plans/003_pai-fork-mcp-migration.md#L38-L40), [`Plans/003_pai-fork-mcp-migration.md:62-62`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/Plans/003_pai-fork-mcp-migration.md#L62-L62), [`Plans/003_pai-fork-mcp-migration.md:143-145`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/Plans/003_pai-fork-mcp-migration.md#L143-L145)).

The current skills themselves are **not invocable via MCP**. Skill activation still depends on Claude Code reading the skill descriptions at startup and parsing the `USE WHEN` clause for intent matching, then routing into workflow files ([`SAI/SKILLSYSTEM.md:177-199`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/SKILLSYSTEM.md#L177-L199), [`SAI/SKILLSYSTEM.md:963-970`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/SKILLSYSTEM.md#L963-L970)). Agent orchestration examples still use `Skill("...")` and `Task({ subagent_type: ... })`, which are Claude-native runtime constructs rather than MCP tools ([`SAI/SAIAGENTSYSTEM.md:23-35`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/SAIAGENTSYSTEM.md#L23-L35), [`SAI/SAIAGENTSYSTEM.md:43-50`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/SAIAGENTSYSTEM.md#L43-L50), [`SAI/SAIAGENTSYSTEM.md:71-87`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/SAIAGENTSYSTEM.md#L71-L87)).

Hooks remain in the same host-specific category. They are defined as scripts that execute at Claude Code lifecycle events such as `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `Stop`, and `SessionEnd` ([`SAI/hooks/README.md:23-35`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/hooks/README.md#L23-L35), [`SAI/hooks/README.md:80-87`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/hooks/README.md#L80-L87), [`SAI/hooks/README.md:120-132`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/hooks/README.md#L120-L132)). `ThinkWithMemory.hook.ts` is explicit that it calls `zk_recall` via the Silmari library **not via MCP transport**, because it runs in-process inside the hook ([`SAI/hooks/ThinkWithMemory.hook.ts:3-15`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/hooks/ThinkWithMemory.hook.ts#L3-L15)).

That means the direct answer to the user's question is:

- **Can we invoke the current skills via MCP today?** No. The current MCP server does not expose skills, workflows, or hooks as callable units.
- **What can we invoke via MCP today?** The provider-neutral memory primitives that some skills and prompts already consume: recall, save, link, hub management, status checks, reflection prompts, and related `zk_*` operations.

A useful current-state detail surfaced in this follow-up: the server now defines and dispatches both `zk_recall_by_status` and `zk_promote`, but the prompt-layer docs still describe them as missing. The authoritative server surface includes those tools ([`apps/silmari-mcp/src/index.ts:368-399`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/apps/silmari-mcp/src/index.ts#L368-L399), [`apps/silmari-mcp/src/index.ts:722-771`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/apps/silmari-mcp/src/index.ts#L722-L771)), while the `/silmari` command and Algorithm note still call them gaps ([`SAI/commands/silmari.md:71-74`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/commands/silmari.md#L71-L74), [`SAI/Algorithm/v3.8.1.md:205-211`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/Algorithm/v3.8.1.md#L205-L211), [`SAI/Algorithm/v3.8.1.md:272-276`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/Algorithm/v3.8.1.md#L272-L276)). This is documentation drift, not a missing server capability.

`SessionProgress.ts` is the clearest example of an SAI function that belongs on the MCP side of the boundary. The file says card mirroring was disabled during the rebrand because the legacy bash `zettel` CLI was removed, and that the intended replacement is an MCP client rewrite ([`SAI/Tools/SessionProgress.ts:26-37`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/Tools/SessionProgress.ts#L26-L37)). Its create/complete/blocker flows are still written in terms of save/promote semantics, which now map naturally onto the current MCP surface ([`SAI/Tools/SessionProgress.ts:56-129`](https://github.com/tha-hammer/silmari-agent-memory/blob/633e3293b0cb97b257d4bea001c0e669759214f8/SAI/Tools/SessionProgress.ts#L56-L129)).

Based on the current codebase, the clean boundary is:

| Good MCP candidates | Why they fit |
|---|---|
| Memory recall/save/link/hub/status/promote/reflect operations | Already exposed as `zk_*` tools; portable across Claude Code, Codex, Gemini, and any other MCP client |
| Session-progress card mirroring and resumption helpers | Current code already expects a move from CLI calls to MCP client calls |
| Deterministic helper operations that manipulate Silmari state | They describe provider-neutral domain behavior rather than host UX |

| Likely to remain host adapters | Why they do **not** map cleanly to MCP as-is |
|---|---|
| `USE WHEN` skill activation | Depends on Claude Code's skill-loader semantics |
| `Skill("...")` / `Task({ subagent_type: ... })` orchestration | Depends on Claude-native workflow and subagent primitives |
| Lifecycle hooks like `SessionStart` / `UserPromptSubmit` / `Stop` | Depend on host runtime event timing |
| `CLAUDE.md` generation, status line, prompt injection | These are host-client integration surfaces, not Silmari domain operations |

So the current repo direction is **not** "invoke existing skills over MCP." It is closer to "move reusable Silmari capabilities into MCP, then let each host runtime keep a thin adapter layer for activation, timing, and UX." Some of that migration has already happened at the prompt layer; the skill and hook runtime itself has not.
