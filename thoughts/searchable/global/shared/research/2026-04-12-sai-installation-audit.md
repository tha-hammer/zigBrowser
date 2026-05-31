---
date: 2026-04-12T16:00:00-05:00
researcher: Silmari
git_commit: 456beeb4d343eda7f959889de3dbb71b8f4db0b7
branch: main
repository: silmari-agent-memory
topic: "SAI v4.0.3 Installation Audit — Upstream PAI Comparison & AAI Branding Residue"
tags: [research, installation, branding, settings, statusline, skills]
status: complete
last_updated: 2026-04-12
last_updated_by: Silmari
---

# Research: SAI v4.0.3 Installation Audit

**Date**: 2026-04-12T16:00:00-05:00
**Researcher**: Silmari
**Git Commit**: 456beeb
**Branch**: main
**Repository**: silmari-agent-memory

## Research Question

Study the upstream PAI v4.0.3 installation process (README + install script), verify the SAI infrastructure is installed properly with skills properly referenced, and document the AAI branding residue in the status line and elsewhere.

---

## Summary

The upstream PAI v4.0.3 installer is a two-layer system: a bash bootstrap (`install.sh`) that ensures Bun/Git exist, then hands off to a TypeScript engine with 8 sequential steps. The current SAI installation is a **fork** of this upstream — it has been rebranded from PAI → SAI in the core CLAUDE.md, the Algorithm, and the directory naming (e.g., `SAI/` instead of `PAI/`), but **significant AAI branding residue remains** in `settings.json` and the `statusline-command.sh` script.

---

## Detailed Findings

### 1. Upstream PAI v4.0.3 Install Process

| Component | Location | Purpose |
|-----------|----------|---------|
| Bootstrap | `SAI/upstream/Releases/v4.0.3/.claude/PAI-Install/install.sh` | Bash script: detects OS, installs Git/Bun/Claude Code, launches TS engine |
| Engine | `SAI/upstream/Releases/v4.0.3/.claude/PAI-Install/engine/` | 8-step install: detect → prereqs → API keys → identity → repo → config → voice → validation |
| Config Gen | `engine/config-gen.ts` | Generates fallback `settings.json`; merges user fields into release template |
| Types | `engine/types.ts` | Defines `PAI_VERSION = "4.0.3"`, `ALGORITHM_VERSION = "3.7.0"` |
| Web UI | `PAI-Install/public/` + web server | Electron/Web/CLI install modes |

**Key design**: The installer does NOT generate hooks or status line config. It clones the PAI repo (which includes a full `settings.json` template), then merges only user-specific fields (principal name, AI name, voice, timezone, env vars). Hooks, status line, spinner verbs, and context files come from the template.

### 2. Current SAI Installation Structure

The live installation at `~/.claude/` has been partially rebranded:

| Aspect | Status | Details |
|--------|--------|---------|
| CLAUDE.md | ✅ Rebranded | References `SAI`, not `PAI` |
| Algorithm dir | ✅ Rebranded | Lives at `SAI/Algorithm/v3.7.0.md` |
| Core docs | ✅ Rebranded | `SAI/AISTEERINGRULES.md`, `SAI/SAISYSTEMARCHITECTURE.md`, etc. |
| Skills dir | ✅ Present | 15 skill categories at `~/.claude/skills/` |
| Hooks dir | ✅ Present | 20+ hooks at `~/.claude/hooks/` |
| `settings.json` env.SAI_DIR | ✅ Correct | Points to `/home/maceo/.claude` |
| `settings.json` statusLine | ✅ Points correctly | `$SAI_DIR/statusline-command.sh` |

### 3. AAI Branding Residue (The Problem)

#### 3a. `statusline-command.sh` — Heavy AAI Branding

The entire status line script at `~/.claude/statusline-command.sh` uses **AAI** branding throughout:

| Line(s) | Content |
|---------|---------|
| 3 | Header comment: `# AAI Status Line` |
| 25 | Variable: `AAI_DIR="${AAI_DIR:-$HOME/.claude}"` |
| 49 | Cache path: `COUNTS_CACHE="$AAI_DIR/MEMORY/STATE/counts-cache.sh"` |
| 52 | Env source: `${AAI_CONFIG_DIR:-$HOME/.config/AAI}/.env` |
| 75 | Version var: `AAI_VERSION=$(jq -r '.pai.version // "—"' ...)` |
| 556-565 | Color variables: `AAI_P`, `AAI_A`, `AAI_I`, `AAI_LABEL`, etc. |
| 785 | **Visible output**: `printf "── │ AAI │ ──────"` |
| 798 | **Visible output**: `printf "── │ AAI STATUSLINE │ ..."` |
| 800 | **Visible output**: `printf "── │ AAI STATUSLINE │ ──────"` |
| 803 | **Visible output**: `printf "... AAI:${AAI_VERSION} ..."` |

The branding letters `A A I` are rendered with color gradients (Navy → Blue → Light Blue) at lines 785, 798, 800. This is what the user sees in the terminal status line — it says **AAI** instead of **SAI**.

#### 3b. `settings.json` — AAI References

15 occurrences of "AAI" remain in `settings.json`:

| Line | Field | Content |
|------|-------|---------|
| 8 | `env.AAI_CONFIG_DIR` | `/home/maceo/.config/AAI` — references old config dir |
| 727 | spinnerVerbs guidance | `/create-skill scaffolds and validates new AAI skills.` |
| 737 | spinnerVerbs guidance | `/open-source-management monitors AAI, fabric...` |
| 752 | spinnerVerbs guidance | `/aai is the mandatory gateway for all public AAI repo operations.` |
| 794 | spinnerVerbs guidance | `bun RebuildAAI.ts regenerates the compiled AAI SKILL.md` |
| 796 | spinnerVerbs guidance | `settings.json is the single source of truth for all AAI configuration.` |
| 820 | spinnerVerbs guidance | `Use AAI Tools (bun AAI/Tools/*.ts)` |
| 823 | spinnerVerbs guidance | `The meaning of AAI: magnifying human capabilities...` |
| 824 | spinnerVerbs guidance | `AAI v4.0.3 with Algorithm v3.7.0` |
| 891 | spinnerVerbs guidance | `Private skills prefixed with _ excluded from public AAI releases.` |
| 908-910 | `loadAtStartup.files` | `AAI/AISTEERINGRULES.md`, `AAI/USER/AISTEERINGRULES.md`, `AAI/USER/PROJECTS/PROJECTS.md` |
| 998 | `_docs._overview` | `Central configuration for the AAI system` |
| 1001 | `_docs.principal` | `The human using the AAI system` |
| 1010 | `_docs.SAI_DIR` | `Root directory for your AAI installation` |
| 1011 | `_docs.PROJECTS_DIR` | `Use ${PROJECTS_DIR}/AAI for AAI repo` |

#### 3c. `loadAtStartup.files` — Broken Paths

The `loadAtStartup` section references paths that don't exist:

| Referenced Path | Exists? | Correct Path |
|----------------|---------|--------------|
| `AAI/AISTEERINGRULES.md` | ❌ No `AAI/` dir | `SAI/AISTEERINGRULES.md` |
| `AAI/USER/AISTEERINGRULES.md` | ❌ | `SAI/USER/AISTEERINGRULES.md` (if exists) |
| `AAI/USER/PROJECTS/PROJECTS.md` | ❌ | `SAI/USER/PROJECTS/PROJECTS.md` (if exists) |

There is no `~/.claude/AAI/` directory. The actual SAI content is at `~/.claude/SAI/`.

### 4. Skills Reference Audit

Skills are at `~/.claude/skills/` with 15 categories:

```
agents, bd-to-br-migration, content-analysis, copywriting, find-skills,
investigation, Marketing, media, research, scraping, security, telos,
thinking, us-metrics, utilities
```

The `settings.json` `contextFiles` array is empty (correct for v4.0 — context loads via CLAUDE.md natively + `LoadContext.hook.ts` for dynamic context). Skills are properly discovered by Claude Code's skill scanning mechanism.

### 5. Upstream vs Current Naming Comparison

| Upstream (PAI v4.0.3) | Current Installation | Status |
|----------------------|---------------------|--------|
| `PAI/` directory | `SAI/` directory | ✅ Rebranded |
| `PAI/Algorithm/` | `SAI/Algorithm/` | ✅ Rebranded |
| `PAI/Tools/` | `SAI/Tools/` | ✅ Rebranded |
| `PAI/PAISYSTEMARCHITECTURE.md` | `SAI/SAISYSTEMARCHITECTURE.md` | ✅ Rebranded |
| `PAI/PAIAGENTSYSTEM.md` | `SAI/SAIAGENTSYSTEM.md` | ✅ Rebranded |
| CLAUDE.md `PAI` refs | CLAUDE.md `SAI` refs | ✅ Rebranded |
| `statusline-command.sh` PAI refs | Still says `AAI` | ❌ Stale branding |
| `settings.json` docs/guidance | Still says `AAI` | ❌ Stale branding |
| `loadAtStartup` paths | Points to `AAI/` (doesn't exist) | ❌ Broken paths |

---

## Code References

- `~/.claude/statusline-command.sh:3` — AAI header comment
- `~/.claude/statusline-command.sh:25` — AAI_DIR variable
- `~/.claude/statusline-command.sh:556-565` — AAI color variables
- `~/.claude/statusline-command.sh:785,798,800` — Visible AAI branding in terminal output
- `~/.claude/settings.json:8` — `AAI_CONFIG_DIR` env var
- `~/.claude/settings.json:908-910` — Broken `loadAtStartup` paths referencing `AAI/`
- `SAI/upstream/Releases/v4.0.3/.claude/PAI-Install/install.sh` — Upstream bootstrap
- `SAI/upstream/Releases/v4.0.3/.claude/PAI-Install/engine/types.ts:189-191` — Version constants

---

## Architecture Documentation

The installation follows a template-merge pattern:
1. The upstream PAI release ships a complete `settings.json` with all hooks, status line, spinner verbs, and guidance text
2. The installer only merges user-specific fields (name, voice, timezone)
3. The SAI fork rebranded the core docs (CLAUDE.md, Algorithm, system architecture files) but the `settings.json` template and `statusline-command.sh` retained older "AAI" branding from a prior fork generation (PAI → AAI → SAI renaming chain)

---

## Open Questions

1. Should `AAI_CONFIG_DIR` (`/home/maceo/.config/AAI`) be renamed to `SAI_CONFIG_DIR` (`/home/maceo/.config/SAI`)?
2. Do the `loadAtStartup` files at `SAI/USER/AISTEERINGRULES.md` and `SAI/USER/PROJECTS/PROJECTS.md` actually exist, or should those entries be removed?
3. Should the ~15 AAI references in settings.json guidance/docs strings be batch-replaced with SAI?
