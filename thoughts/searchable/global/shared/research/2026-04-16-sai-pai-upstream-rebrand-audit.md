---
date: 2026-04-16T08:38:36-04:00
researcher: maceo
git_commit: 45e5b7d57ea2ecc2fc68afdfbc16da4dfaf15dac
branch: main
repository: silmari-agent-memory
topic: "SAI vs PAI upstream rebrand audit — total rebrand readiness"
tags: [research, sai, pai, rebrand, fork-audit, agents, hooks, skills, voiceserver, infrastructure]
status: complete
last_updated: 2026-04-16
last_updated_by: maceo
---

```
┌───────────────────────────────────────────────────────────────────────┐
│  SAI vs PAI UPSTREAM — TOTAL REBRAND AUDIT                           │
│  Status: COMPLETE   Date: 2026-04-16   Coverage: 4 parallel slices   │
└───────────────────────────────────────────────────────────────────────┘
```

# Research: SAI vs PAI Upstream — Total Rebrand Readiness

**Date**: 2026-04-16T08:38:36-04:00
**Researcher**: maceo
**Git Commit**: 45e5b7d57ea2ecc2fc68afdfbc16da4dfaf15dac
**Branch**: main
**Repository**: silmari-agent-memory

---

## 📚 Research Question

> SAI is a fork of the AAI/PAI open-source repo. Audit the live SAI tree against the canonical upstream (preserved at `SAI/upstream/Releases/v4.0.3/.claude/`). The SAI repo appears to be missing key directories such as `hooks` and `skills`. The SAI repo needs to be a TOTAL REBRAND of the PAI upstream — identify every gap (missing artifact) and every branding leak (un-rebranded reference) that blocks total-rebrand status.

---

## 🎯 Summary

The SAI fork is **roughly 50% rebranded** and uses a **dual-layer architecture** that is intentional but produces the appearance of incompleteness:

| Layer | Where it lives | Rebrand status |
|---|---|---|
| **Repo-local** (SAI docs, Algorithm, ACTIONS/FLOWS/PIPELINES, Tools, agents) | `/home/maceo/Dev/silmari-agent-memory/SAI/` | ✅ Fully rebranded + 27 SAI-original additions |
| **System-wide** (hooks, skills, lib, VoiceServer, scripts, settings) | `~/.claude/` | ⚠️ Mixed — hooks fully rebranded, skills/install partially rebranded, several legacy `PAI-Install`/`AAI`/`AAI-Install` dirs remain |
| **User-local** (SAI-USER) | `~/.claude/SAI-USER/` (linked into `SAI/USER`) | ❌ Folder is renamed but **34 README/code references still say "PAI"** |

### Top-line counts

- **0 of 11 upstream `.claude/` top-level entries are mirrored under `SAI/`** in the repo. They live in `~/.claude/` instead.
- **20 of 20 PAI hooks are present and rebranded** (`PAI_DIR`→`SAI_DIR`, `getPaiDir`→`getSaiDir`, etc.) under `~/.claude/hooks/`. Plus **5 SAI-original hooks** added.
- **35 REBRAND_NEEDED branding leaks** in active live code/docs (across 15 files, mostly under `~/.claude/SAI-USER/`).
- **3 legacy directories still exist** in `~/.claude/`: `AAI/`, `AAI-Install/`, `PAI-Install/`. None have been replaced by `SAI-Install/`.
- **`SAI/skills/` does not exist.** The skill ecosystem lives only at `~/.claude/skills/`. Casing is inconsistent (mix of `Agents` and `agents`, `Investigation` and `investigation`).
- **VoiceServer is running** (bun pid 2819503, port 8888) from `~/.claude/VoiceServer/` — file list identical to upstream.

---

## 🚧 Architectural Pattern: Dual-Layer Fork

The fork is structured around a deliberate split:

```
                        ┌─────────────────────────────┐
                        │   System-wide (~/.claude/)  │
                        │                             │
  ┌──────────────┐      │  hooks/        ✅ rebranded │
  │  Repo-local  │      │  skills/       ⚠️ partial   │
  │  (SAI/)      │◀────▶│  lib/          ✅ identical │
  │              │      │  VoiceServer/  ⚠️ unverified│
  │  agents/  ✅ │      │  install.sh    ❌ legacy    │
  │  Algorithm/✅│      │  settings.json ✅ rebranded │
  │  ACTIONS/ ✅ │      │  statusline    ✅ ~identical│
  │  Tools/   ✅ │      │  CLAUDE.md     ✅ rebranded │
  │  USER → ─────────────▶ SAI-USER/    ❌ 34 leaks  │
  │  upstream/   │      │  PAI-Install/  ❌ legacy    │
  └──────────────┘      │  AAI/          ❌ legacy    │
                        │  AAI-Install/  ❌ legacy    │
                        └─────────────────────────────┘
                                    ▲
                                    │
                        ┌─────────────────────────────┐
                        │  Upstream (preserved)       │
                        │  SAI/upstream/Releases/     │
                        │  v4.0.3/.claude/  (READ-ONLY)│
                        └─────────────────────────────┘
```

**Implication for total rebrand:** Achieving "total rebrand" is not just a string-substitution exercise — it requires architectural decisions about WHERE the SAI counterparts of `install.sh`, `skills/`, `lib/`, `VoiceServer/` should live (under `SAI/` in the repo, or remain at `~/.claude/`?), AND how to retire the legacy `PAI-Install/`, `AAI/`, `AAI-Install/` directories.

---

## 📊 Detailed Findings

### A. Top-Level Structure Diff: `SAI/upstream/Releases/v4.0.3/.claude/` vs `SAI/`

| Upstream entry | SAI counterpart? | Live location | Gap classification |
|---|---|---|---|
| `agents/` (14 files) | ✅ | `SAI/agents/` | PRESENT_SAME_NAME |
| `CLAUDE.md` | ✅ | repo-root `CLAUDE.md` + `~/.claude/CLAUDE.md` | PRESENT_DIFFERENT_LOCATION |
| `CLAUDE.md.template` | ⚠️ | only `~/.claude/CLAUDE.md.template` | MISSING_IN_SAI_REPO |
| `hooks/` (23 files) | ✅ | `~/.claude/hooks/` (symlinked at repo-root `hooks/`) | PRESENT_DIFFERENT_LOCATION |
| `install.sh` (7.9K) | ❌ | only `~/.claude/install.sh` | MISSING_IN_SAI_REPO |
| `lib/` (1 subdir: `migration/`) | ❌ | only `~/.claude/lib/` | MISSING_IN_SAI_REPO |
| `MEMORY/` (just README) | ⚠️ | repo-root `MEMORY/` (different purpose — PRD storage) | DIFFERENT_PURPOSE |
| `PAI/` (111 files, 1.4M) | ✅ | `SAI/` (with 27 additions) | PRESENT_RENAMED |
| `PAI-Install/` (41 files, 3.7M) | ❌ | only `~/.claude/PAI-Install/` (still PAI-named!) | NOT_REBRANDED |
| `settings.json` (40K) | ⚠️ | only `~/.claude/settings.json` (rebranded inside) | MISSING_IN_SAI_REPO |
| `skills/` (11 dirs) | ❌ | only `~/.claude/skills/` (15 dirs, casing-mixed) | MISSING_IN_SAI_REPO |
| `statusline-command.sh` (70K) | ❌ | only `~/.claude/statusline-command.sh` | MISSING_IN_SAI_REPO |
| `VoiceServer/` (10 files) | ❌ | only `~/.claude/VoiceServer/` (running) | MISSING_IN_SAI_REPO |

**SAI-only entries (27 additions over upstream):** ACTIONS, ACTIONS.md, Algorithm, AISTEERINGRULES.md, CLI.md, CLIFIRSTARCHITECTURE.md, commands, CONTEXT_ROUTING.md, doc-dependencies.json, DOCUMENTATIONINDEX.md, FLOWS, FLOWS.md, MEMORYSYSTEM.md, PIPELINES, PIPELINES.md, PRDFORMAT.md, README.md, SAIAGENTSYSTEM.md, SAISYSTEMARCHITECTURE.md, SKILL.md, SKILLSYSTEM.md, SYSTEM_USER_EXTENDABILITY.md, THEDELEGATIONSYSTEM.md, THEFABRICSYSTEM.md, THEHOOKSYSTEM.md, THENOTIFICATIONSYSTEM.md, Tools, TOOLS.md, UPSTREAM_REF.md, USER (symlink).

These are **SAI-original work** with no upstream equivalent — fully SAI-branded, no rebrand action needed for them.

---

### B. Hooks Subsystem — ✅ Fully Rebranded

**Location:** `~/.claude/hooks/` (symlinked from repo-root `hooks/`)

**Confidence: HIGH.** The repo-root `hooks/` IS the SAI rebrand of upstream `.claude/hooks/`. Evidence:

| Mapping confidence | Count | Examples |
|---|---|---|
| EXACT (line-identical content, PAI→SAI in headers/imports only) | 17 | `AgentExecutionGuard.hook.ts`, `LoadContext.hook.ts`, `SecurityValidator.hook.ts` |
| FUNCTIONAL (rebranded + extended) | 3 | `PRDSync.hook.ts` (+42 lines), `SessionAutoName.hook.ts` (+24 lines), `WorkCompletionLearning.hook.ts` (+32 lines) |
| ABSENT in upstream — SAI-NEW | 5 | `ChecklistEnforcer.hook.ts` (447 lines), `ChecklistStateInjector.hook.ts` (275 lines), `check_critical_on_stop.sh`, `check_mail_on_close.sh`, `ensure_window_id.sh` |

**Key rebrand evidence:**
- `~/.claude/settings.json:4` defines `"SAI_DIR": "/home/maceo/.claude"` (replacing upstream `PAI_DIR`)
- All hook commands registered as `${SAI_DIR}/hooks/*.hook.ts` (settings.json:74, 110, 227, etc.)
- `~/.claude/hooks/lib/paths.ts:32` exports `getSaiDir()` (was `getPaiDir()` upstream)
- `~/.claude/hooks/lib/paths.ts:52` exports `saiPath()` (was `paiPath()` upstream)
- Hook headers updated: e.g. `LoadContext.hook.ts:3` → `* LoadContext.hook.ts - Inject SAI dynamic context`

**Residual PAI references in live hooks (6 hits, all benign folder-name preservations):**
- `DocCrossRefIntegrity.ts:308` — references `PAISYSTEMARCHITECTURE.md` filename
- `SecurityValidator.hook.ts:183` — path `SAI/USER/PAISECURITYSYSTEM/` (folder name retained)
- `change-detection.ts:73,225,230,512,569` — pattern matching for `PAISYSTEM`/`PAISECURITYSYSTEM` folder names

**Total SAI-original hook code added:** ~956 lines (789 TS + 167 sh).

---

### C. Skills Subsystem — ❌ Missing from Repo, Inconsistent in `~/.claude/`

**Upstream `SAI/upstream/Releases/v4.0.3/.claude/skills/` (11 PascalCase dirs):**
```
Agents  ContentAnalysis  Investigation  Media  Research
Scraping  Security  Telos  Thinking  USMetrics  Utilities
```

**Live `~/.claude/skills/` (15 dirs, casing-mixed):**
```
agents              (lowercase — should be Agents)
bd-to-br-migration  (SAI-NEW)
content-analysis    (kebab-case — should be ContentAnalysis)
copywriting         (SAI-NEW, lowercase)
find-skills         (SAI-NEW, kebab-case)
investigation       (lowercase — should be Investigation)
Marketing           (SAI-NEW, PascalCase)
Media               ✅
Research            ✅
Scraping            ✅
Security            ✅
telos               (lowercase — should be Telos)
thinking            (lowercase — should be Thinking)
us-metrics          (kebab-case — should be USMetrics)
utilities           (lowercase — should be Utilities)
```

**Findings:**
- `SAI/skills/` does NOT exist anywhere under the repo's `SAI/` directory.
- 7 of 11 upstream skill dirs have been **renamed to lowercase or kebab-case** in `~/.claude/skills/` — this looks like accidental drift, not intentional rebrand. Casing changes alone don't fail referrers, but some loaders are case-sensitive.
- 5 SAI-original skills added: `bd-to-br-migration`, `copywriting`, `find-skills`, `Marketing`, plus user customizations.
- **`PerplexityResearch.md` workflow file does not exist** at `~/.claude/skills/Research/Workflows/` (or anywhere on disk, or in upstream — see prior research turn). The `PerplexityResearcher.md` agent at `SAI/agents/PerplexityResearcher.md:171` references a workflow that has never been written.

---

### D. Lib Subsystem — ✅ Identical (Trivial Surface)

| Location | Contents |
|---|---|
| Upstream `.claude/lib/` | one subdir: `migration/` |
| Live `~/.claude/lib/` | same single subdir: `migration/` |

The lib surface is essentially empty at the top level. **The substantive shared code is in `~/.claude/hooks/lib/`** (13 TS files including `paths.ts`, `change-detection.ts`, `learning-utils.ts`, `notifications.ts`, `tab-constants.ts`) — and that has been fully rebranded (see section B).

---

### E. MEMORY Subsystem — Different Purpose, Partial Overlap

| Location | Contents | Purpose |
|---|---|---|
| Upstream `.claude/MEMORY/` | just `README.md` | placeholder/stub upstream |
| Live `~/.claude/MEMORY/` | 6 subdirs (per agent #1 report) | session memory capture |
| Repo-root `/MEMORY/` | `WORK/` only | PRD storage (SAI Algorithm output) |
| Auto-memory `~/.claude/projects/-home-maceo-Dev-silmari-agent-memory/memory/` | per-conversation user/feedback/project notes | Claude Code's built-in persistent memory |

**Multiple memory subsystems coexist.** The repo's `MEMORY/WORK/` is SAI-native (PRDs from Algorithm runs). The upstream `MEMORY/` was always a stub. No rebrand action — but worth documenting the layered memory architecture in `SAI/MEMORYSYSTEM.md` if not already.

---

### F. VoiceServer — File List Identical, Branding Unverified

| Location | File count | Status |
|---|---|---|
| Upstream `.claude/VoiceServer/` | 10 files (`server.ts`, `start.sh`, `stop.sh`, `restart.sh`, `status.sh`, `install.sh`, `uninstall.sh`, `voices.json`, `pronunciations.json`, `menubar/`) | canonical |
| Live `~/.claude/VoiceServer/` | same 10 files | unrebranded source TBD |

**Process check:** `bun run /home/maceo/.claude/VoiceServer/server.ts` is running (pid 2819503, listening on port 8888 since Apr 5). This is what the curl voice notifications in `CLAUDE.md` hit.

**Branding inside the files:** not deeply audited in this run (the dedicated agent failed on overload). Likely contains PAI references that should become SAI — needs follow-up grep.

---

### G. Scripts (install.sh / settings.json / statusline-command.sh / CLAUDE.md.template)

| File | Upstream size | Live size | Delta | In `SAI/`? |
|---|---|---|---|---|
| `install.sh` | 7917 B | 7947 B | +30 B | ❌ no |
| `settings.json` | 40870 B | 41168 B | +298 B | ❌ no |
| `statusline-command.sh` | 70489 B | 70490 B | +1 B | ❌ no |
| `CLAUDE.md.template` | 3126 B | 3128 B | +2 B | ❌ no |

All four are present and lightly modified at `~/.claude/`, but **none are mirrored under `SAI/` in the repo**. For total rebrand, decide whether they should be:
- (a) versioned in the repo at `SAI/scripts/` (or similar) and symlinked into `~/.claude/`, OR
- (b) explicitly excluded as system-bootstrap material that lives only in `~/.claude/`.

---

### H. Legacy Directories Still Present in `~/.claude/`

```
~/.claude/AAI/            ❌ legacy (1 file, contains USER/)
~/.claude/AAI-Install/    ❌ legacy (41 files, mirror of PAI-Install)
~/.claude/PAI-Install/    ❌ legacy (NOT renamed to SAI-Install)
~/.claude/SAI-USER/       ✅ rebranded user dir
~/.claude/SAI/            ✅ symlink → repo SAI/
```

**Three directories that should be either retired or rebranded:**
1. `~/.claude/PAI-Install/` → `~/.claude/SAI-Install/` (or delete if installer is unused)
2. `~/.claude/AAI/` → delete or merge into `SAI-USER/` (1 stub file)
3. `~/.claude/AAI-Install/` → delete (duplicate of PAI-Install per agent #1 report)

**No `SAI/` directory exists under `~/.claude/` itself** — only the symlink to the repo. This means `~/.claude/SAI/` resolves correctly via symlink, but there is no standalone `~/.claude/SAI-Install/` either.

---

### I. Branding Leak Inventory — 35 REBRAND_NEEDED Hits

**Tier 1 — `~/.claude/SAI-USER/` documentation (15 files, 34 hits):** Folder is renamed, contents are not. Every README still says "PAI uses…", "PAI's routing system", etc. Action.ts files reference old `~/.claude/AAI/USER/...` snapshot paths.

| File | Hits | Pattern |
|---|---|---|
| `SAI-USER/README.md` | 4 | "your personal PAI configuration" |
| `SAI-USER/WORK/README.md` | 2 | "PAI uses work context" |
| `SAI-USER/BUSINESS/README.md` | 1 | "PAI uses this context" |
| `SAI-USER/PROJECTS/README.md` | 1 | "PAI uses this to route" |
| `SAI-USER/STATUSLINE/README.md` | 2 | "PAI uses the status line" |
| `SAI-USER/TELOS/README.md` | 2 | "help PAI understand what matters" (×2) |
| `SAI-USER/TERMINAL/README.md` | 2 | "PAI's tab management" |
| `SAI-USER/SKILLCUSTOMIZATIONS/README.md` | 1 | "Every PAI skill checks" |
| `SAI-USER/Workflows/README.md` | 2 | "extend PAI's built-in" |
| `SAI-USER/ACTIONS/README.md` | 1 | "PAI can invoke" |
| `SAI-USER/ACTIONS/A_FETCH_SEC_FORM_D/action.ts` | 2 | User-Agent `PAI-FundingMonitor` |
| `SAI-USER/ACTIONS/A_FETCH_FUNDING_RSS/action.ts` | 1 | User-Agent `PAI-FundingMonitor` |
| `SAI-USER/ACTIONS/A_FETCH_FUNDING_COMMUNITY/action.ts` | 4 | User-Agent + path `~/.claude/AAI/USER/...` |
| `SAI-USER/ACTIONS/A_ENRICH_FUNDING_SIGNALS/action.ts` | 1 | User-Agent |
| `SAI-USER/ACTIONS/A_FETCH_VC_PORTFOLIOS/action.ts` | 1 | path `~/.claude/AAI/USER/...` |

**Tier 2 — SAI/Tools/ banners + UI titles (5 files, 7 hits):**

| File | Line | Issue |
|---|---|---|
| `SAI/Tools/pipeline-monitor-ui/src/App.tsx` | 352 | `<title>PAI Pipeline Monitor</title>` |
| `SAI/Tools/Banner.ts` | 119 | repoUrl = `github.com/cosmic-HQ/Agent-Assistant-Infrastructure` |
| `SAI/Tools/BannerMatrix.ts` | 636 | same repo URL |
| `SAI/Tools/NeofetchBanner.ts` | 657 | same repo URL |
| `SAI/Tools/BannerRetro.ts` | 528, 636, 684 | same repo URL (×3) |

**Tier 3 — `SAI/SKILL.md` (2 hits):**
- Line 35: `# The Algorithm (v3.7.0 | github.com/danielmiessler/TheAlgorithm)`
- Line 237: `♻︎ Entering the SAI ALGORITHM… (v3.7.0 | github.com/danielmiessler/TheAlgorithm)`

**Tier 4 — Plans (2 files, 37 hits — mostly contextually appropriate but should be archived):**
- `Plans/001_zettelkasten-agent-memory-mcp.md` — 8 hits
- `Plans/003_pai-fork-mcp-migration.md` — 29 hits (this IS the migration plan; contains intentional PAI references)

**Tier 5 — Correctly preserved lineage (5 hits, no action needed):**
- `SAI/README.md` — 3 hits explaining upstream
- `SAI/UPSTREAM_REF.md` — 5 hits documenting the fork commit + provenance

---

## 📋 Code References

### Critical paths

| Path | Purpose | Status |
|---|---|---|
| `SAI/agents/PerplexityResearcher.md:171` | references missing workflow | broken in upstream too |
| `~/.claude/settings.json:4` | defines `SAI_DIR` | ✅ rebranded |
| `~/.claude/hooks/lib/paths.ts:32,52` | `getSaiDir()`, `saiPath()` | ✅ rebranded |
| `~/.claude/hooks/SessionAutoName.hook.ts:36-37` | imports from `../SAI/Tools/Inference` | ✅ rebranded |
| `~/.claude/CLAUDE.md` | force-loads `SAI/Algorithm/v3.8.0.md` (relative path) | ⚠️ ambiguous resolution |
| `~/.claude/SAI` | symlink → `/home/maceo/Dev/silmari-agent-memory/SAI` | ✅ correct |
| `~/.claude/PAI-Install/` | full installer dir, NOT rebranded | ❌ legacy |
| `~/.claude/AAI/` and `~/.claude/AAI-Install/` | legacy from prior fork | ❌ retire |
| `SAI/upstream/Releases/v4.0.3/.claude/` | canonical PAI v4.0.3 (read-only) | ✅ correctly preserved |
| `SAI/UPSTREAM_REF.md:21` | references unwritten `scripts/sai-upstream-merge.sh` (Phase F deliverable) | not yet built |

### Process state
- VoiceServer running: bun pid 2819503 on port 8888 since Apr 5
- Live SAI Algorithm version: `SAI/Algorithm/v3.8.0.md` (upstream v4.0.3 was at `v3.7.0`)

---

## 🏗 Architecture Documentation (current state)

### How the dual-layer fork works today

**Repo-local layer (`SAI/` in this git repo):**
- Owns: agents, Algorithm, ACTIONS, FLOWS, PIPELINES, Tools, system architecture docs (27 SAI-original additions)
- This is what `git push` propagates and what other clones pick up.
- Symlinked into `~/.claude/SAI` so it's reachable system-wide.

**System-wide layer (`~/.claude/`):**
- Owns: hooks (with SAI rebrand applied + 5 new SAI hooks), skills (15 dirs, casing-mixed), VoiceServer (running), scripts (install/settings/statusline/template), legacy `PAI-Install`/`AAI`/`AAI-Install` dirs.
- NOT in any git repo (system-wide install).
- This is what `~/.claude/CLAUDE.md` references via `${SAI_DIR}` env var.

**User-local layer (`~/.claude/SAI-USER/`, linked into `SAI/USER`):**
- User customizations (BUSINESS/, PROJECTS/, TELOS/, WORK/, ACTIONS/, etc.).
- Contains the **largest concentration of PAI-branded text leaks** (34 of 35 total).

### How Claude Code finds SAI

1. Reads `~/.claude/CLAUDE.md` at session start (always loaded)
2. CLAUDE.md instructs `Read SAI/Algorithm/v3.8.0.md` (relative path)
3. The reading agent resolves the path — typically against cwd; but `~/.claude/SAI/` symlink also works if the agent interprets the path relative to `~/.claude/`
4. Algorithm v3.8.0 then drives the rest of the session (PRD creation, ZK recall via Silmari MCP, hook integration via `${SAI_DIR}`)

### What "total rebrand" requires (current scope estimate)

| Action | Items | Est. effort |
|---|---|---|
| Replace 34 PAI references in `~/.claude/SAI-USER/` (READMEs + action.ts headers) | 15 files | small (sed pass + review) |
| Fix `SAI/Tools/` banners + UI titles (PAI Pipeline Monitor, repo URL) | 5 files | small |
| Replace `github.com/danielmiessler/TheAlgorithm` references in `SAI/SKILL.md` | 2 lines | trivial |
| Decide fate of `~/.claude/PAI-Install/` (rename to SAI-Install or retire) | 41 files / 3.7M | medium (requires running installer + verifying) |
| Retire or merge `~/.claude/AAI/` (1 stub) | 1 file | trivial |
| Retire `~/.claude/AAI-Install/` (duplicate) | 41 files | small (verify it's a duplicate first) |
| Decide whether `SAI/` should mirror `install.sh`, `settings.json`, `statusline-command.sh`, `CLAUDE.md.template`, `lib/`, `skills/`, `VoiceServer/` (or keep them only in `~/.claude/`) | architectural | medium-large |
| Normalize `~/.claude/skills/` casing (PascalCase per upstream, OR document the convention shift) | 7 dirs | small |
| Audit `~/.claude/VoiceServer/` source for PAI references (not done in this run) | 10 files | small |
| Build `scripts/sai-upstream-merge.sh` per `UPSTREAM_REF.md` | 1 script | medium |
| Author missing `PerplexityResearch.md` workflow (or remove the agent reference) | 1 file | small |

**No actionable PAI leaks in the SAI/ repo-side `Algorithm/`, `ACTIONS/`, `FLOWS/`, `PIPELINES/`, or `agents/` directories** — all these were already SAI-native or fully converted.

---

## 📜 Historical Context (from thoughts/)

- `thoughts/searchable/shared/research/2026-04-12-sai-installation-audit.md` — prior installation audit (read for context if extending this work)
- `Plans/003_pai-fork-mcp-migration.md` — original migration plan (29 PAI references — intentional, this IS the rebrand plan)
- `Plans/001_zettelkasten-agent-memory-mcp.md` — early ZK memory plan (8 PAI references — historical context)
- `SAI/UPSTREAM_REF.md` — pinned upstream commit (`6e0bcc39e445...`, dated 2026-04-06), de-submoduled 2026-04-11

---

## 🔗 Related Research

- `thoughts/searchable/shared/research/2026-04-12-sai-installation-audit.md`
- `thoughts/searchable/shared/research/2026-04-12-zk-recall-by-status-zk-promote-implementation.md` (Silmari MCP context)

---

## ❓ Open Questions

1. **Scope of "in-repo" rebrand:** Should `install.sh`, `settings.json`, `lib/`, `skills/`, `VoiceServer/`, `statusline-command.sh`, `CLAUDE.md.template` be mirrored under `SAI/` in the repo (so `git clone` is self-sufficient), or remain `~/.claude/`-only system bootstrap material?
2. **PAI-Install fate:** Is the installer (Electron/CLI/Web) actively used? If yes → rename to `SAI-Install/`. If no → retire entirely.
3. **AAI / AAI-Install:** Per `UPSTREAM_REF.md` "AAI" was the intermediate fork name. Are these still referenced anywhere live? Safe to delete?
4. **Skill casing:** Was the lowercase/kebab-case shift intentional (modern convention) or accidental drift? Decision affects whether to rename or document.
5. **VoiceServer rebrand depth:** File list is identical but file *contents* not yet audited for PAI references (subagent #4 timed out on overload).
6. **`PerplexityResearch.md` workflow:** Author it (full Sonar API integration) or remove the dangling reference from `PerplexityResearcher.md:171`?
7. **CLAUDE.md path resolution:** Should `~/.claude/CLAUDE.md`'s `Read SAI/Algorithm/v3.8.0.md` line be made absolute (`~/.claude/SAI/Algorithm/v3.8.0.md`) to remove ambiguity for sessions in non-SAI cwds?
