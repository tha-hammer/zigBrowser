# SAI AAI Branding Rebrand — Implementation Plan

## Overview

Eliminate all AAI branding residue from the SAI installation. Two files contain stale "AAI" references from a prior fork generation (PAI -> AAI -> SAI): `~/.claude/statusline-command.sh` (42 occurrences) and `~/.claude/settings.json` (15 occurrences, including 3 broken `loadAtStartup` paths). Hooks are clean — no AAI references found.

## Current State Analysis

The SAI fork correctly rebranded core docs (`CLAUDE.md`, Algorithm, system architecture files, `SAI/` directory structure), but the `statusline-command.sh` and `settings.json` retained AAI branding from the prior fork generation.

### Key Discoveries:
- `statusline-command.sh` uses `AAI_DIR` exclusively — never references `SAI_DIR` despite it being set in `settings.json` env
- `loadAtStartup.files` references `AAI/USER/AISTEERINGRULES.md` and `AAI/USER/PROJECTS/PROJECTS.md` — neither path exists, and `~/.claude/SAI/USER/` directory doesn't exist either
- Only `SAI/AISTEERINGRULES.md` exists at the top level
- `LoadContext.hook.ts` gracefully warns on missing files (doesn't crash), so these broken paths are silent failures
- No AAI references exist in any hook files

## Desired End State

After this plan completes:
- `statusline-command.sh` displays **SAI STATUSLINE** with the same Navy -> Blue -> Light Blue gradient
- All internal variables use `SAI_DIR`, `SAI_VERSION`, `SAI_P`, `SAI_A`, `SAI_I`, etc.
- `settings.json` references `SAI_CONFIG_DIR` pointing to `~/.config/SAI`
- `loadAtStartup.files` points to `SAI/AISTEERINGRULES.md` only (the only file that actually exists)
- All guidance/docs strings reference SAI instead of AAI
- Zero grep hits for `AAI` across both files

### Verification:
```bash
# Zero AAI references in either file
grep -c 'AAI' ~/.claude/statusline-command.sh   # expect: 0
grep -c 'AAI' ~/.claude/settings.json           # expect: 0

# Status line renders without errors
bash ~/.claude/statusline-command.sh             # expect: SAI STATUSLINE output

# loadAtStartup paths resolve
for f in $(jq -r '.loadAtStartup.files[]' ~/.claude/settings.json); do
  [ -f "$HOME/.claude/$f" ] && echo "OK: $f" || echo "MISSING: $f"
done
# expect: all OK
```

## What We're NOT Doing

| NOT Doing | ARE Doing |
|-----------|-----------|
| Renaming `~/.config/AAI/` directory on disk | Updating the env var name and default path in config |
| Changing any hook files | They're already clean |
| Modifying upstream release files in `SAI/upstream/` | Only touching live installation files |
| Creating `SAI/USER/` directory structure | Removing broken refs to nonexistent paths |
| Changing the color scheme or layout | Only swapping AAI -> SAI text |

## Implementation Approach

Straight find-and-replace with surgical precision. The AAI -> SAI swap is mechanical in both files. The only non-trivial decision is `loadAtStartup.files` — we remove the two broken paths and keep only the one file that exists.

---

╔═══════════════════════════════════════════════╗
║  PHASE 1: Status Line Rebrand                 ║
║  ~/.claude/statusline-command.sh              ║
╚═══════════════════════════════════════════════╝

## Phase 1: Status Line Rebrand

### Overview
Rename all 42 AAI references in `statusline-command.sh` to SAI equivalents. This is a mechanical rename — the script's logic doesn't change.

### Changes Required:

#### 1a. Header Comment (line 3)
**File**: `~/.claude/statusline-command.sh`
```bash
# BEFORE:
# AAI Status Line

# AFTER:
# SAI Status Line
```

#### 1b. Primary Variable: `AAI_DIR` -> `SAI_DIR` (line 25)
```bash
# BEFORE:
AAI_DIR="${AAI_DIR:-$HOME/.claude}"

# AFTER:
SAI_DIR="${SAI_DIR:-$HOME/.claude}"
```

**Cascade**: Every `$AAI_DIR` and `"$AAI_DIR` reference throughout the file becomes `$SAI_DIR` / `"$SAI_DIR`. Affected lines: 26-33, 49, 158-159, 163, 1115.

#### 1c. Config Dir Reference (line 52)
```bash
# BEFORE:
[ -f "${AAI_CONFIG_DIR:-$HOME/.config/AAI}/.env" ] && source "${AAI_CONFIG_DIR:-$HOME/.config/AAI}/.env"

# AFTER:
[ -f "${SAI_CONFIG_DIR:-$HOME/.config/SAI}/.env" ] && source "${SAI_CONFIG_DIR:-$HOME/.config/SAI}/.env"
```

#### 1d. Version Variable (lines 75-76)
```bash
# BEFORE:
AAI_VERSION=$(jq -r '.pai.version // "—"' "$SETTINGS_FILE" 2>/dev/null)
AAI_VERSION="${AAI_VERSION:-—}"

# AFTER:
SAI_VERSION=$(jq -r '.pai.version // "—"' "$SETTINGS_FILE" 2>/dev/null)
SAI_VERSION="${SAI_VERSION:-—}"
```

**Cascade**: Every `$AAI_VERSION` / `${AAI_VERSION}` becomes `$SAI_VERSION` / `${SAI_VERSION}`. Affected lines: 787, 803, 819, 835.

#### 1e. Color Variables (lines 557-565)
```bash
# BEFORE:                              # AFTER:
AAI_P='\033[38;2;30;58;138m'          SAI_S='\033[38;2;30;58;138m'          # Navy (S)
AAI_A='\033[38;2;59;130;246m'         SAI_A='\033[38;2;59;130;246m'         # Medium blue (A)
AAI_I='\033[38;2;147;197;253m'        SAI_I='\033[38;2;147;197;253m'        # Light blue (I)
AAI_LABEL='\033[38;2;100;116;139m'    SAI_LABEL='\033[38;2;100;116;139m'
AAI_CITY='\033[38;2;147;197;253m'     SAI_CITY='\033[38;2;147;197;253m'
AAI_STATE='\033[38;2;100;116;139m'    SAI_STATE='\033[38;2;100;116;139m'
AAI_TIME='\033[38;2;96;165;250m'      SAI_TIME='\033[38;2;96;165;250m'
AAI_WEATHER='\033[38;2;135;206;235m'  SAI_WEATHER='\033[38;2;135;206;235m'
AAI_SESSION='\033[38;2;120;135;160m'  SAI_SESSION='\033[38;2;120;135;160m'
```

Note: `AAI_P` (for the letter P in PAI) becomes `SAI_S` (for the letter S in SAI). The color gradient stays the same — Navy for S, Blue for A, Light Blue for I.

#### 1f. Visible Output — Branding Lines
Every printf that renders the `A A I` gradient letters changes to render `S A I`:

```bash
# BEFORE (example — lines 785, 798, 800, 814, 816, 830, 832):
printf "${SLATE_600}── │${RESET} ${AAI_P}A${AAI_A}A${AAI_I}I${RESET} ...

# AFTER:
printf "${SLATE_600}── │${RESET} ${SAI_S}S${SAI_A}A${SAI_I}I${RESET} ...
```

And the `AAI:` version label in ENV lines:

```bash
# BEFORE (lines 803, 819, 835):
${SLATE_500}AAI:${AAI_A}${AAI_VERSION}

# AFTER:
${SLATE_500}SAI:${SAI_A}${SAI_VERSION}
```

#### 1g. Comments (lines 56, 70, 156, 468)
```bash
# AAI Branding       ->  # SAI Branding
# LINE 0: AAI ...    ->  # LINE 0: SAI ...
# ... AAI uses ...   ->  # ... SAI uses ...
# ... AAI_VERSION .. ->  # ... SAI_VERSION ..
```

#### 1h. Micro-mode branding string (line ~791)
```bash
# BEFORE:
local_left="── │ AAI STATUSLINE │"

# AFTER:
local_left="── │ SAI STATUSLINE │"
```

### Execution Strategy

Use `sed` for the mechanical replacements in this order:
1. `AAI_P` -> `SAI_S` (must be done BEFORE the general `AAI_` -> `SAI_` pass, since `AAI_P` is a unique case)
2. `${AAI_P}A${AAI_A}A${AAI_I}I` -> `${SAI_S}S${SAI_A}A${SAI_I}I` (the visible letter swap)
3. `AAI_` -> `SAI_` (all remaining variable names)
4. `AAI:` -> `SAI:` (the ENV line label)
5. `AAI ` -> `SAI ` (comments and the micro-mode string)
6. `.config/AAI` -> `.config/SAI` (config dir path)
7. Any remaining `AAI` -> `SAI` (catch-all for comments)

### Success Criteria:

#### Automated Verification:
- [x] Zero AAI references: `grep -c 'AAI' ~/.claude/statusline-command.sh` returns 0
- [x] Script executes without errors: `bash ~/.claude/statusline-command.sh` exits 0
- [x] SAI branding present: `grep -c 'SAI' ~/.claude/statusline-command.sh` returns >30 (51)

#### Manual Verification:
- [ ] Open a new Claude Code session — status line displays "SAI STATUSLINE" with Navy/Blue/Light Blue gradient
- [ ] Location, time, weather, version info all render correctly
- [ ] No visual regressions in any terminal width mode (nano/micro/mini/normal)

---

╔═══════════════════════════════════════════════╗
║  PHASE 2: Settings.json Rebrand               ║
║  ~/.claude/settings.json                      ║
╚═══════════════════════════════════════════════╝

## Phase 2: Settings.json Rebrand

### Overview
Fix 15 AAI references in `settings.json`: 1 env var, 3 broken loadAtStartup paths, and 11 guidance/docs strings.

### Changes Required:

#### 2a. Environment Variable (line 8)
**File**: `~/.claude/settings.json`
```json
// BEFORE:
"AAI_CONFIG_DIR": "/home/maceo/.config/AAI",

// AFTER:
"SAI_CONFIG_DIR": "/home/maceo/.config/SAI",
```

#### 2b. loadAtStartup.files — Fix Broken Paths (lines 908-910)
```json
// BEFORE:
"files": [
  "AAI/AISTEERINGRULES.md",
  "AAI/USER/AISTEERINGRULES.md",
  "AAI/USER/PROJECTS/PROJECTS.md"
]

// AFTER:
"files": [
  "SAI/AISTEERINGRULES.md"
]
```

Rationale: `SAI/AISTEERINGRULES.md` exists. `SAI/USER/` directory does not exist — removing the two broken paths eliminates silent `LoadContext.hook.ts` warnings.

#### 2c. Guidance Strings in spinnerVerbs (11 replacements)

| Line | Before | After |
|------|--------|-------|
| 727 | `new AAI skills` | `new SAI skills` |
| 737 | `monitors AAI, fabric` | `monitors SAI, fabric` |
| 752 | `/aai is the mandatory gateway for all public AAI repo` | `/sai is the mandatory gateway for all public SAI repo` |
| 794 | `bun RebuildAAI.ts regenerates the compiled AAI SKILL.md` | `bun RebuildSAI.ts regenerates the compiled SAI SKILL.md` |
| 796 | `all AAI configuration` | `all SAI configuration` |
| 820 | `Use AAI Tools (bun AAI/Tools/*.ts)` | `Use SAI Tools (bun SAI/Tools/*.ts)` |
| 823 | `The meaning of AAI: magnifying` | `The meaning of SAI: magnifying` |
| 824 | `AAI v4.0.3` | `SAI v4.0.3` |
| 891 | `public AAI releases` | `public SAI releases` |

#### 2d. Documentation Strings (_docs section)

| Line | Before | After |
|------|--------|-------|
| 998 | `Central configuration for the AAI system` | `Central configuration for the SAI system` |
| 1001 | `The human using the AAI system` | `The human using the SAI system` |
| 1010 | `Root directory for your AAI installation` | `Root directory for your SAI installation` |
| 1011 | `${PROJECTS_DIR}/AAI for AAI repo` | `${PROJECTS_DIR}/SAI for SAI repo` |

### Execution Strategy

Use targeted `Edit` tool replacements for each change. The JSON structure requires exact string matching — no regex bulk replacement.

### Success Criteria:

#### Automated Verification:
- [x] Zero AAI references: `grep -c 'AAI' ~/.claude/settings.json` returns 0
- [x] Valid JSON: `jq . ~/.claude/settings.json > /dev/null` exits 0
- [x] loadAtStartup path exists: `[ -f ~/.claude/SAI/AISTEERINGRULES.md ]` returns true
- [x] SAI_CONFIG_DIR present: `jq -r '.env.SAI_CONFIG_DIR' ~/.claude/settings.json` returns `/home/maceo/.config/SAI`

#### Manual Verification:
- [ ] New Claude Code session starts without LoadContext warnings about missing files
- [ ] `SAI_CONFIG_DIR` env var is available in session

---

╔═══════════════════════════════════════════════╗
║  PHASE 3: Verification & Cleanup              ║
╚═══════════════════════════════════════════════╝

## Phase 3: Verification & Cleanup

### Overview
End-to-end verification that no AAI references remain and everything works.

### Verification Script:
```bash
#!/bin/bash
echo "=== AAI Residue Check ==="
echo -n "statusline-command.sh: "
count=$(grep -c 'AAI' ~/.claude/statusline-command.sh 2>/dev/null || echo 0)
[ "$count" -eq 0 ] && echo "PASS (0 AAI refs)" || echo "FAIL ($count AAI refs)"

echo -n "settings.json: "
count=$(grep -c 'AAI' ~/.claude/settings.json 2>/dev/null || echo 0)
[ "$count" -eq 0 ] && echo "PASS (0 AAI refs)" || echo "FAIL ($count AAI refs)"

echo -n "settings.json valid JSON: "
jq . ~/.claude/settings.json > /dev/null 2>&1 && echo "PASS" || echo "FAIL"

echo -n "statusline executes: "
bash ~/.claude/statusline-command.sh > /dev/null 2>&1 && echo "PASS" || echo "FAIL"

echo ""
echo "=== loadAtStartup Path Check ==="
for f in $(jq -r '.loadAtStartup.files[]' ~/.claude/settings.json 2>/dev/null); do
  [ -f "$HOME/.claude/$f" ] && echo "  OK: $f" || echo "  MISSING: $f"
done

echo ""
echo "=== SAI Branding Check ==="
echo -n "SAI in statusline: "
grep -q 'SAI_DIR' ~/.claude/statusline-command.sh && echo "PASS" || echo "FAIL"
echo -n "SAI_CONFIG_DIR in settings: "
jq -r '.env.SAI_CONFIG_DIR' ~/.claude/settings.json 2>/dev/null | grep -q 'SAI' && echo "PASS" || echo "FAIL"
```

### Success Criteria:

#### Automated Verification:
- [x] All checks in verification script pass
- [x] `grep -ri 'AAI' ~/.claude/statusline-command.sh ~/.claude/settings.json` returns nothing

#### Manual Verification:
- [ ] Start fresh Claude Code session — status line shows SAI branding
- [ ] Status line renders in all 4 width modes without errors
- [ ] No warnings in session startup about missing loadAtStartup files

---

## Testing Strategy

### Automated:
- JSON validation: `jq . ~/.claude/settings.json`
- Script syntax: `bash -n ~/.claude/statusline-command.sh`
- Script execution: `bash ~/.claude/statusline-command.sh`
- AAI residue: `grep -c AAI` on both files

### Manual:
1. Open terminal at different widths (<35, 35-54, 55-79, 80+)
2. Start Claude Code session in each — verify SAI branding in status line
3. Check that location/time/weather/version info still renders
4. Confirm no LoadContext warnings in session output

## Performance Considerations

None — this is a text replacement with no runtime impact.

## Migration Notes

- If `~/.config/AAI/.env` exists with an ElevenLabs key, the new `SAI_CONFIG_DIR` path (`~/.config/SAI`) won't find it. May need to either symlink or copy: `cp -r ~/.config/AAI ~/.config/SAI`
- The env var rename (`AAI_CONFIG_DIR` -> `SAI_CONFIG_DIR`) means any external scripts referencing the old name will break. Check for references outside these two files.

## References

- Research: `thoughts/shared/research/2026-04-12-sai-installation-audit.md`
- Upstream installer: `SAI/upstream/Releases/v4.0.3/.claude/PAI-Install/`
- Status line script: `~/.claude/statusline-command.sh`
- Settings: `~/.claude/settings.json`
- LoadContext hook: `~/.claude/hooks/LoadContext.hook.ts`
