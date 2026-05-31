---
date: 2026-04-16T14:40:00-04:00
author: maceo
git_commit: 45e5b7d57ea2ecc2fc68afdfbc16da4dfaf15dac
branch: main
repository: silmari-agent-memory
plan_kind: execution
topic: "SAI total rebrand — execution plan W6–W12 (post Wave A/B)"
related_research: thoughts/searchable/shared/research/2026-04-16-sai-pai-upstream-rebrand-audit.md
status: ready_to_execute
tags: [plan, sai, pai, rebrand, fork-audit, infrastructure, install]
---

# Plan: SAI Total Rebrand — Execution W6–W12

**Date**: 2026-04-16
**Author**: maceo
**Related research**: [`2026-04-16-sai-pai-upstream-rebrand-audit.md`](../research/2026-04-16-sai-pai-upstream-rebrand-audit.md)

## What's already done (Wave A + B + C + W6)

- **W1** VoiceServer text rebrand — 12 PAI references in 5 files swapped to SAI; server restarted (new PID 2387610) responding healthy
- **W2** SAI-USER text rebrand — 24 PAI references in 14 files swapped; snapshot data migrated from `~/.claude/AAI/USER/ACTIONS/.../` to `~/.claude/SAI-USER/ACTIONS/.../` (AAI originals retained per decision #3)
- **W3** SAI/Tools/ banner rebrand — 7 hits in 5 files (PAI Pipeline Monitor → SAI; cosmic-HQ/Agent-Assistant-Infrastructure → tha-hammer/silmari-agent-memory)
- **W4** SAI/SKILL.md — 2 references to danielmiessler/TheAlgorithm swapped
- **W5** Authored `PerplexityResearch.md` — full Sonar API integration; landed at `SAI/skills/Research/Workflows/` after W6 move
- **W6** Skills restored to PascalCase + moved to SAI: 7 dirs renamed (`agents`/`content-analysis`/`investigation`/`telos`/`thinking`/`us-metrics`/`utilities` → PascalCase); 11 `SKILL.md name:` fields updated to PascalCase to match upstream; entire `~/.claude/skills/` moved to `SAI/skills/` and symlinked back. Live skill listing confirms all 11 PascalCase names visible. Zero source-code referrers needed patching (only auto-memory prose mentions).
- Verified: `grep -r "PAI" ~/.claude/SAI-USER/` returns zero hits; same for VoiceServer and SAI/Tools/. Skills accessible through `~/.claude/skills` symlink.

## Foundational decision (from prior conversation)

**Decision #1**: SAI is the source of truth. The repo holds canonical files. `~/.claude/` becomes a *derived install target*. The new `install.sh` (W12) symlinks (dev) or copies (client) from `SAI/` into `~/.claude/`.

This shapes every workstream below.

## What's NOT done yet

| # | Workstream | Files | Risk | Depends on |
|---|---|---|---|---|
| W6 | Move skills/ → SAI/skills/ + normalize casing | 15 top-level dirs, ~900+ files | MEDIUM | — |
| W7 | Move lib/ → SAI/lib/ | 1 subdir | LOW | — |
| W8 | ✅ DONE 2026-04-16 — 4 root scripts moved to SAI/, symlinked back. settings.json + hooks paths still resolve via `${SAI_DIR}/...` chain. | 4 files | DONE | — |
| W9 | ✅ DONE 2026-04-16 — `~/.claude/VoiceServer/` → `SAI/VoiceServer/` + symlink. Server restarted (new PID 2966572), `/health` returns healthy. ⚠️ **macOS→Linux fork of internal scripts STILL DEFERRED per decision #2** — see W9.5 below. | 10 files + running process | DONE | W1 (done) |
| W10 | ✅ DONE 2026-04-16 — `~/.claude/hooks` moved to `SAI/hooks` + symlink. Removed redundant repo-root `/hooks` legacy symlink. SAI/hooks is now canonical. Live hooks fire normally. | ~50 files | DONE | — |
| W11 | ✅ DONE 2026-04-16 — `~/.claude/PAI-Install/` (8 files, 3 subdirs) → `SAI/SAI-Install/` + symlink `~/.claude/SAI-Install`. Internal PAI grep returned 0 hits — no W11.5 follow-up needed. | 8 files | DONE | — |
| W12 | ✅ DONE 2026-04-16 — Authored `SAI/install.sh` (symlink-default, copy-mode supported, idempotent via sentinel, conflict-aware backup). Verified clean install in `~/.claude.test/` (symlink mode) + Docker container with `debian:bookworm-slim` (copy mode). 8 artifacts installed (4 dirs + 4 files), 2 skipped-with-warning (agents, commands — live tree evolved past SAI/), 1 optional skipped (VoiceServer — W9 deferred). Dockerfile at `scripts/Dockerfile.install-test`. | 2 files | DONE | — |

## Cross-cutting principles

1. **Symlink-first migration.** For every file/dir moved into `SAI/`, leave a symlink at the old `~/.claude/` location pointing to the new SAI path. This keeps the live system working with zero downtime, identically to how `~/.claude/SAI` already symlinks to repo `SAI/`.
2. **Update referrers immediately.** If a path is hardcoded anywhere (settings.json, hooks, skills, scripts), update those referrers in the same commit as the move.
3. **One workstream per commit.** Each W gets its own commit with a verification step. Bisectability matters if something breaks.
4. **Rollback is `git revert` + restore symlink.** No destructive moves — `cp -r` then symlink, then verify, then `rm -rf` the old location only after the next commit lands.
5. **Test surface after every step.** Minimum: open a fresh Claude Code session, watch for hook errors. Algorithm-tier verification: run a trivial Algorithm pass and confirm OBSERVE/THINK/PLAN flow normally.

---

## W6 — Move skills/ → SAI/skills/ + normalize casing

### Context

`~/.claude/skills/` has 15 top-level directories with mixed casing (7 of 11 upstream PascalCase dirs were renamed lowercase or kebab-case at some point — likely drift). Per upstream convention: `Agents`, `ContentAnalysis`, `Investigation`, `Media`, `Research`, `Scraping`, `Security`, `Telos`, `Thinking`, `USMetrics`, `Utilities`. SAI-original additions (preserve as-is): `bd-to-br-migration`, `copywriting`, `find-skills`, `Marketing`.

### Steps

1. **Audit referrers first** — `grep -rn "skills/agents\|skills/content-analysis\|skills/investigation\|skills/telos\|skills/thinking\|skills/us-metrics\|skills/utilities" ~/.claude/ /home/maceo/Dev/silmari-agent-memory/SAI/ /home/maceo/Dev/silmari-agent-memory/hooks/` and capture every hit. Hardcoded lowercase paths exist; they must be patched in the same commit.
2. **Rename in place** (lowercase → PascalCase) within `~/.claude/skills/` first, on a one-by-one basis. After each rename, re-grep to find broken referrers and patch.
3. **Move to SAI/** — `mv ~/.claude/skills /home/maceo/Dev/silmari-agent-memory/SAI/skills` then `ln -s /home/maceo/Dev/silmari-agent-memory/SAI/skills ~/.claude/skills`. Verify symlink resolves correctly.
4. **Move `~/.claude/skills/Research/Workflows/PerplexityResearch.md`** with the rest — it lands under `SAI/skills/Research/Workflows/PerplexityResearch.md`.
5. **Verify**: open a fresh session, invoke any skill via `Skill("Research")`, confirm it loads.

### Risks

- Case-sensitive loaders fail silently when `agents/` → `Agents/` (Linux is case-sensitive, macOS HFS+ default isn't). Test in fresh session.
- 900+ files in the move; `mv` is atomic on same filesystem but slow if cross-FS. Both paths are under `/home/maceo/` so same FS — should be fast.
- Some hooks read `${SAI_DIR}/skills/...` with hardcoded casing. Audit `hooks/` for these.

### Rollback

`git revert` + `mv SAI/skills ~/.claude/skills` + `rm` the symlink.

---

## W7 — Move lib/ → SAI/lib/ — DONE 2026-04-16

### Done

1. ✅ Moved `~/.claude/lib` → `SAI/lib`
2. ✅ Symlinked `~/.claude/lib` → `SAI/lib`
3. ✅ Verified: 5 TS files in `lib/migration/` (extractor, index, merger, scanner, validator) accessible via symlink

### W9.5 follow-up — VoiceServer macOS→Linux script fork (deferred per decision #2)

**Resurfacing reminder.** The VoiceServer ships with macOS LaunchAgent scripts:
- `SAI/VoiceServer/install.sh` — uses `launchctl`, writes `~/Library/LaunchAgents/com.pai.voice-server.plist`, expects `~/Library/Logs/`
- `SAI/VoiceServer/status.sh` — `launchctl list`
- `SAI/VoiceServer/uninstall.sh` — `launchctl unload`
- `SAI/VoiceServer/start.sh`, `stop.sh`, `restart.sh` — also macOS-flavored

These are **non-functional on Linux** (no `launchctl`, no `~/Library/`). The live Linux setup runs the server directly via `nohup bun run ~/.claude/VoiceServer/server.ts &` — there's no service manager wrapping it.

**Outstanding question (deferred):** fork the .sh scripts to detect platform and use systemd user units (`~/.config/systemd/user/sai-voiceserver.service`) on Linux while preserving the LaunchAgent path on macOS. Either:
- (a) Single script with `case "$(uname)"` branching
- (b) Separate `*.macos.sh` + `*.linux.sh` siblings, with `*.sh` being a thin dispatcher
- (c) Replace .sh entirely with a TS CLI (`bun SAI/Tools/voiceserver.ts {start|stop|status|...}`) that handles platform internally

Recommendation: (c) — the team is bun-native, TS is the lingua franca of SAI/Tools/, and platform branching in TS is cleaner than nested bash. But not blocking. Until then, Linux operators run the bun process manually (per the README Test section) or via a hand-written systemd unit.

## W7.5 follow-up — lib/migration PAI rebrand (deferred)

The 5 migration files contain **31 PAI references** that are NOT pure text rebrand:
- `lib/migration/scanner.ts:9 hits` — detects PAI installs (functional path: `skills/PAI/SKILL.md`)
- `lib/migration/validator.ts:12 hits` — validates PAI installs
- `lib/migration/extractor.ts:4 hits`
- `lib/migration/merger.ts:4 hits`
- `lib/migration/index.ts:2 hits`

**Design question for W7.5:** the migrator's purpose is to detect existing PAI installs to migrate FROM. Pure text-replacement breaks the detector. Two options:
- (a) Keep `PAI` as the legacy-detection target, rebrand only the comments/identifiers that talk ABOUT PAI generically
- (b) Extend the detector to find BOTH PAI installs AND SAI installs (and migrate PAI → SAI)

Option (b) is the "right" answer if SAI is taking over from PAI for new clients. Out of scope for the move — needs separate design pass.

---

## W8 — Move install.sh, settings.json, statusline, CLAUDE.md.template → SAI/

### Context

These 4 files are root-level system configuration. settings.json is the hottest — Claude Code reads it on every session for hook registration, env vars, permissions.

### Steps

1. **Create destination dir** `SAI/scripts/` (clusters install + statusline scripts together) OR put each at `SAI/` top-level (matches upstream `.claude/` shape). **Decision: top-level under `SAI/`**, mirrors upstream structure.
2. **Move with symlink** for each file:
   ```
   mv ~/.claude/install.sh           SAI/install.sh           && ln -s ... ~/.claude/install.sh
   mv ~/.claude/settings.json        SAI/settings.json        && ln -s ... ~/.claude/settings.json
   mv ~/.claude/statusline-command.sh SAI/statusline-command.sh && ln -s ... ~/.claude/statusline-command.sh
   mv ~/.claude/CLAUDE.md.template   SAI/CLAUDE.md.template   && ln -s ... ~/.claude/CLAUDE.md.template
   ```
3. **Audit settings.json** for `${SAI_DIR}` paths — currently `SAI_DIR=/home/maceo/.claude`. After this move, decide whether `SAI_DIR` should stay pointing at `~/.claude/` (because symlinks resolve transparently) OR be re-pointed to `/home/maceo/Dev/silmari-agent-memory/SAI/`. Preserving `~/.claude/` is safer for now.
4. **Verify**: open a fresh session, observe hook firing (PRDSync, LoadContext, etc.). Check `${SAI_DIR}` resolution by examining the env var in a session.

### Risk

- settings.json is read live by Claude Code daemon. Symlinks should work transparently, but if the read happens before the symlink is in place, sessions could see "no settings.json" briefly. Mitigation: do the move + symlink as a single atomic-ish operation (`mv && ln -s` chain).

---

## W9 — Move VoiceServer/ → SAI/VoiceServer/

### Context

VoiceServer is currently RUNNING (pid 2387610 after the W1 restart) from `~/.claude/VoiceServer/server.ts`. Moving the dir under the running process requires stop → move → symlink → start.

### Steps

1. **Stop the bun server**: `kill 2387610`
2. **Move the dir**: `mv ~/.claude/VoiceServer /home/maceo/Dev/silmari-agent-memory/SAI/VoiceServer`
3. **Symlink back**: `ln -s /home/maceo/Dev/silmari-agent-memory/SAI/VoiceServer ~/.claude/VoiceServer`
4. **Restart**: `nohup bun run ~/.claude/VoiceServer/server.ts > /tmp/voiceserver.log 2>&1 & disown` (path resolves via symlink)
5. **Verify**: `curl -s http://localhost:8888/health` returns healthy
6. **Note**: the install.sh / status.sh / uninstall.sh scripts inside VoiceServer reference macOS `launchctl` and `~/Library/LaunchAgents/` paths. They are non-functional on Linux. Decide whether to fork a Linux-compatible variant in this workstream or defer.

### Risk: voice notifications gap during ~5-second restart window. Acceptable.

---

## W10 — Move hooks/ → SAI/hooks/

### Context

Currently:
- `~/.claude/hooks/` is the actual hook dir (live, used by Claude Code via settings.json `${SAI_DIR}/hooks/...`)
- `/home/maceo/Dev/silmari-agent-memory/hooks/` is a symlink TO `~/.claude/hooks/` (per the audit)

The desired end state: `SAI/hooks/` is canonical, `~/.claude/hooks/` symlinks to it.

### Steps

1. **Resolve current symlink direction** — confirm `repo-root/hooks` IS a symlink to `~/.claude/hooks/` and not the other way around. (`readlink -f /home/maceo/Dev/silmari-agent-memory/hooks`)
2. **Audit referrers** — `grep -rn "/hooks/" ~/.claude/settings.json /home/maceo/Dev/silmari-agent-memory/SAI/` — most should reference `${SAI_DIR}/hooks/...` which transparently resolves through the symlink. But anything with hardcoded `~/.claude/hooks/` or repo-root `hooks/` paths needs updating.
3. **Remove the repo-root symlink** if pointing the wrong way: `rm /home/maceo/Dev/silmari-agent-memory/hooks`
4. **Move the actual content**: `mv ~/.claude/hooks /home/maceo/Dev/silmari-agent-memory/SAI/hooks`
5. **Restore the symlink (now correctly pointing into SAI)**: `ln -s /home/maceo/Dev/silmari-agent-memory/SAI/hooks ~/.claude/hooks`
6. **Verify**: open a fresh session, confirm hooks fire (PRDSync logs to stdout when PRD edited, LoadContext shows env vars, etc.).

### Risk

- 50+ hooks fire on every session. If any silently break, you may not notice immediately. Mitigation: after move, run `~/.claude/hooks/SecurityValidator.hook.ts` directly to verify the binary path still resolves.
- hooks/lib/paths.ts uses `getSaiDir()` returning `process.env.SAI_DIR ?? ~/.claude` (or similar). Check that it resolves correctly post-symlink.

---

## W11 — Rename PAI-Install/ → SAI/SAI-Install/

### Context

`~/.claude/PAI-Install/` (41 files, 3.7M — Electron + CLI + Web installer) is the upstream installer. Per decision #2: rename to SAI-Install.

### Steps

1. **Confirm installer usage**: ask user, or grep for invocations of PAI-Install (e.g. `grep -rn "PAI-Install" ~/.claude/ ~/Dev/silmari-agent-memory/`). If unused, decision moot — defer to retirement (W13). If used, proceed.
2. **Move + rename in one step**: `mv ~/.claude/PAI-Install /home/maceo/Dev/silmari-agent-memory/SAI/SAI-Install`
3. **Symlink back** (optional, if any tools reference the old path): `ln -s /home/maceo/Dev/silmari-agent-memory/SAI/SAI-Install ~/.claude/SAI-Install`
4. **Branding pass inside SAI-Install/** — grep for "PAI" / "Personal AI Infrastructure" inside the installer files. The Electron app likely has window titles, package.json names, README, etc. This may be substantial.
5. **Decide on `~/.claude/AAI-Install/`** (apparent duplicate per audit). If confirmed duplicate, retire (mv to backup, then delete).

### Risk

- Installer may have hardcoded paths to its own location. Audit before move.
- Electron `package.json` may have `name`, `productName` fields with "PAI" — needs change.
- macOS `.app` bundles inside menubar/ may have Info.plist with `CFBundleName: PAI`.

---

## W12 — Author install.sh as full client installer (the keystone)

### Context

Per decision #1, this is the script that takes a fresh `git clone` of the SAI repo and installs it on a client machine: creates `~/.claude/` symlinks (or copies) to all SAI artifacts.

### Behavior spec

```
Usage: ./install.sh [--mode=symlink|copy] [--target=$HOME/.claude]

1. Verify dependencies: bun, git, curl
2. Verify ~/.claude/ exists; back up to ~/.claude.backup/$(date +%Y%m%d-%H%M%S)/ before writing
3. For each canonical SAI artifact, create symlink (default) or copy (--mode=copy):
   - SAI/agents/             → ~/.claude/agents/
   - SAI/hooks/              → ~/.claude/hooks/
   - SAI/skills/             → ~/.claude/skills/
   - SAI/lib/                → ~/.claude/lib/
   - SAI/VoiceServer/        → ~/.claude/VoiceServer/
   - SAI/SAI-Install/        → ~/.claude/SAI-Install/
   - SAI/install.sh          → ~/.claude/install.sh
   - SAI/settings.json       → ~/.claude/settings.json (template)
   - SAI/statusline-command.sh → ~/.claude/statusline-command.sh
   - SAI/CLAUDE.md.template  → ~/.claude/CLAUDE.md.template
4. Render ~/.claude/CLAUDE.md from CLAUDE.md.template (substitute SAI_DIR, user identity, etc.)
5. Ensure ~/.claude/SAI-USER/ exists (create from skeleton if not — DO NOT overwrite)
6. Start VoiceServer (Linux: nohup bun run ...; macOS: launchctl load)
7. Verify install: curl http://localhost:8888/health, run a no-op skill, etc.
```

### Steps

1. **Read upstream install.sh** as starting reference (`SAI/upstream/Releases/v4.0.3/.claude/install.sh`)
2. **Author SAI/install.sh** matching the spec above. Bash with `set -euo pipefail`.
3. **Test on a clean target**: use a Docker container or a `~/.claude.test/` dir to verify the install.
4. **Author `scripts/sai-upstream-merge.sh`** in the same pass (per `UPSTREAM_REF.md` Phase F deliverable). Spec: fetch upstream into worktree, diff vs `SAI/upstream/`, apply PAI→SAI substitution to the diff, produce patch for human review against live `SAI/`.

### Risk: HIGH

- This is the script that defines "what SAI is" from the user's POV. Bugs here are visible to every client.
- Symlink mode requires the SAI repo to stay in place forever; copy mode requires re-running install.sh on every SAI update.
- Defaulting to symlink mode (dev workflow) is safest for now; copy mode is the future "shipping" mode.

---

## W13 — Retire AAI/, AAI-Install/ (decision #3 — after rebrand confirmed)

After all of W6–W12 land and a full Algorithm pass succeeds end-to-end:

1. `mv ~/.claude/AAI ~/.claude/.backup-AAI-$(date +%Y%m%d)` (don't delete yet — backup)
2. `mv ~/.claude/AAI-Install ~/.claude/.backup-AAI-Install-$(date +%Y%m%d)`
3. After 1 week of stable operation with no missing-file errors, `rm -rf ~/.claude/.backup-*`

---

## Sequencing diagram

```
                           ┌─────────────┐
                           │ W7 lib/     │
                           └─────┬───────┘
                                 │
┌──────────┐  ┌──────────┐  ┌────▼──────┐  ┌──────────┐
│ W6 skills│  │ W9 Voice │  │ W8 scripts│  │ W11 PAI- │
│   /      │  │  Server/ │  │   + cfg   │  │  Install │
└────┬─────┘  └────┬─────┘  └────┬──────┘  └────┬─────┘
     │             │             │              │
     │             │       ┌─────▼─────┐        │
     │             │       │ W10 hooks/│        │
     │             │       └─────┬─────┘        │
     │             │             │              │
     └─────────────┴─────────────┴──────────────┘
                          │
                    ┌─────▼─────┐
                    │ W12       │
                    │ install.sh│
                    └─────┬─────┘
                          │
                    ┌─────▼─────┐
                    │ W13       │
                    │ retire    │
                    │ AAI/      │
                    └───────────┘
```

W6, W7, W9, W11 can run in parallel. W8 + W10 are coupled (settings.json holds hook paths). W12 depends on all moves landing first.

## Verification gates

After each W, run:

1. `git diff --stat HEAD~1` — confirm only expected files changed
2. `ls -la ~/.claude/<moved-thing>` — confirm symlink exists, points correctly
3. `readlink -f ~/.claude/<moved-thing>` — confirm resolves into SAI repo
4. **Open a fresh Claude Code session** — confirm no missing-file errors in hook output
5. After W10 specifically: trigger PRDSync (edit a PRD frontmatter) and watch for the voice announcement (proves hooks + VoiceServer + settings all wired post-move)
6. After W12: `cd /tmp && git clone <repo> sai-test && cd sai-test && ./install.sh --target=$HOME/.claude.test` — confirm fresh install works

## Estimated total effort

| Workstream | Time |
|---|---|
| W6 | 60–90 min (most dirs trivial; case audit takes time) |
| W7 | 10 min |
| W8 | 30 min |
| W9 | 20 min |
| W10 | 45–60 min |
| W11 | 30–60 min (depends on internal branding depth) |
| W12 | 2–4 hours (write + test) |
| W13 | 5 min (just `mv`) |

Total: **4–8 hours focused work**, distributable across 1–2 sessions.

## Decisions (locked 2026-04-16)

1. **install.sh default mode**: **symlink** (dev workflow) — committed.
2. **VoiceServer macOS scripts**: **defer** Linux-compatible fork. ⚠️ MUST RESURFACE during W9 — flag in W9 verification step.
3. **Skill casing**: **restore PascalCase** to match upstream. Audit + patch referrers in same commit as the rename.
4. **`~/.claude/AAI/` (1 stub file)**: **delete in W13** along with `AAI-Install/` (after backup to `~/.claude/.backup-*`).
5. **W12 install.sh end-to-end test**: **Docker container** with clean `~/.claude/`. Author the Dockerfile in the same commit as install.sh.
