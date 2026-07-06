---
date: 2026-07-04T09:03:52-04:00
researcher: TurquoiseHill
git_commit: af2e4c35a9a6f927d9b3d1e3bcff835fcc97aa21
branch: master
repository: zigBrowser
topic: "cosmic-HR04 Local Packaging Isolation Research Handoff"
tags: [handoff, research, packaging, isolation, cosmic-hr04, zigbrowser]
status: in_progress
last_updated: 2026-07-04
last_updated_by: TurquoiseHill
type: handoff
bead: zigBrowser-98g
---

# Handoff: zigBrowser-98g cosmic-HR04 local packaging research

## Task Prompt

User requested:

1. Create a bead for researching how to package and run `~/Dev/cosmic-HR04` locally with zigBrowser instead of Railway.
2. Use the prior cosmic-HR04/zigBrowser summary to run web research on 2025/2026 best practices for running a web application locally with full isolation.
3. Treat this as an agentic application that must be fully isolated from user-local data.
4. Coordinate with HazyForest because separate research exists for filesystem-specific isolation.
5. Confirm/update Agent Mail name to `TurquoiseHill`.
6. Output the research artifact to `thoughts/searchable/shared/research/`.
7. Do not edit source files.

The user then interrupted for context-overflow recovery and asked for this handoff.

## Current Status

- Bead created: `zigBrowser-98g` ("Research local isolated cosmic-HR04 runtime packaging for zigBrowser").
- Bead state from `bd show`: `status=open`, `assignee=TurquoiseHill`, labels `cosmic-hr04,isolation,packaging,research`.
- `bd list --status=in_progress` returned `[]`; `bd update zigBrowser-98g --claim` reported the issue was already claimed by `TurquoiseHill`.
- Agent Mail registration confirmed as `TurquoiseHill`.
- Coordination message sent to HazyForest:
  - Agent Mail message id `2201`
  - subject `Coordination: isolated local runtime research for cosmic-HR04 packaging`
  - topic `zigBrowser-98g`
- HazyForest profile exists in Agent Mail, but last activity shown was historical: `2026-06-03T19:58:08Z`.
- No research artifact has been written yet.
- No source files were edited by me during this research/handoff phase.

## Critical References

- `/home/maceo/Dev/cosmic-HR04/docs/local-development-runbook.md`
- `/home/maceo/Dev/cosmic-HR04/backend/server.js`
- `/home/maceo/ntm_Dev/zigBrowser/src/cli.zig`
- `/home/maceo/ntm_Dev/zigBrowser/specs/lifecycle.md`

## Recent Changes Made

- Created bead `zigBrowser-98g` via `bd create`.
- Registered/updated Agent Mail identity as `TurquoiseHill`.
- Sent Agent Mail coordination message `2201` to `HazyForest`.
- Created this handoff file only.

No source implementation files were intentionally edited. Existing dirty worktree state predates this handoff task and must be treated as user/other-agent owned.

## Worktree State Observed

`/home/maceo/ntm_Dev/zigBrowser` branch `master` at `af2e4c35a9a6f927d9b3d1e3bcff835fcc97aa21` had existing dirty files:

- Modified: `.gitignore`, `packaging/linux/build-deb.sh`, `packaging/linux/control.in`, `src/cli.zig`, `src/uri.zig`, `src/webkit_shim.c`
- Untracked: `.github/`, `e2e/`, `package-lock.json`, `package.json`, `playwright.config.ts`, `tests/e2e/__pycache__/slice2_common.cpython-314.pyc`, `thoughts/searchable/shared/plans/2026-07-04-12-50-tdd-build-time-json-config.md`, `thoughts/searchable/shared/research/2026-07-04-08-57-zigbrowser-filestore-seams-grammar-contracts.md`, `thoughts/searchable/shared/research/2026-07-04-12-30-build-time-config-seams.md`

`/home/maceo/Dev/cosmic-HR04` branch `cosmic-HR04` also had substantial existing dirty state including `.beads/interactions.jsonl`, docs/specs, `package.json`, e2e files, and local handoffs. Do not revert or overwrite.

## What Was Inspected

### cosmic-HR04

- Root package scripts and deps: `/home/maceo/Dev/cosmic-HR04/package.json`
- Backend entrypoint: `/home/maceo/Dev/cosmic-HR04/backend/server.js`
- Config schemas/loader: `/home/maceo/Dev/cosmic-HR04/backend/config/schema.js`, `/home/maceo/Dev/cosmic-HR04/backend/config/loader.js`
- DB layer: `/home/maceo/Dev/cosmic-HR04/backend/database_interaction.js`
- Auth middleware and routes: `/home/maceo/Dev/cosmic-HR04/backend/middleware/authenticate.js`, `/home/maceo/Dev/cosmic-HR04/backend/routes/auth.js`, `/home/maceo/Dev/cosmic-HR04/backend/routes/organizations.js`
- Health endpoint: `/home/maceo/Dev/cosmic-HR04/backend/routes/health.js`
- Local storage provider: `/home/maceo/Dev/cosmic-HR04/backend/storage/local.js`
- Recruiter UI env/API/auth gates: `/home/maceo/Dev/cosmic-HR04/recruiter-ui/next.config.mjs`, `lib/env.js`, `services/api.js`, `hooks/useApi.js`, `components/provider-content.jsx`, `app/(recruiter)/layout.jsx`
- WebSocket clients: `recruiter-ui/services/ats-search-websocket.js`, `recruiter-ui/services/recordings-websocket.js`
- Local/prod compose/deploy: `docker-compose.yml`, `docker-compose.prod.yml`, `railpack.json`
- Local development runbook: `docs/local-development-runbook.md`

### zigBrowser

- CLI/default URL: `/home/maceo/ntm_Dev/zigBrowser/src/cli.zig`
- URI validation: `/home/maceo/ntm_Dev/zigBrowser/src/uri.zig`
- app/webkit entry: `/home/maceo/ntm_Dev/zigBrowser/src/app.zig`, `src/main.zig`, `src/webkit.zig`
- GTK shim lifecycle/navigation: `/home/maceo/ntm_Dev/zigBrowser/src/webkit_shim.c`
- macOS WKWebView navigation snippets: `/home/maceo/ntm_Dev/zigBrowser/src/wkwebview_shim.m`
- Navigation policy: `/home/maceo/ntm_Dev/zigBrowser/src/nav_policy.zig`
- Build/package scripts: `/home/maceo/ntm_Dev/zigBrowser/build.zig`, `packaging/linux/*`, `packaging/windows/zigBrowser.wxs`
- Specs/docs: `specs/architecture.md`, `specs/lifecycle.md`, `docs/how-to-run.md`, `docs/how-to-build.md`

## Partial Findings

### Local packaging feasibility

Packaging is feasible in principle but not drop-in today. zigBrowser can load a local HTTP URL in a chrome-free app-shell window, but it currently does not spawn or supervise the cosmic-HR04 backend/frontend/database. A local package needs a launcher/supervisor outside or inside zigBrowser.

Recommended app shape from local code inspection:

1. Build `recruiter-ui` as static output.
2. Start only the Express backend in `NODE_ENV=production`.
3. Let Express serve `recruiter-ui/out` from one origin.
4. Bind backend to `127.0.0.1:<ephemeral-or-reserved-port>`.
5. Launch zigBrowser to `http://127.0.0.1:<port>/...`.

This avoids running a separate Next dev server after startup.

### cosmic-HR04 runtime facts

- Node >=20 and npm >=9 required.
- Dev scripts default backend `3004`, recruiter UI `3003`.
- Production server uses `node backend/server.js`.
- Backend loads root `.env`.
- Backend initializes Postgres before serving; no DB means app exits.
- Backend serves `recruiter-ui/out` when `NODE_ENV=production`.
- WebSocket server shares backend HTTP server.
- Backend handles SIGTERM/SIGINT and closes DB pools, with a 30s forced shutdown timeout.
- Local storage defaults to `./data/audio`, resolved relative to project root unless absolute.
- Production logger writes `logs/error.log` and `logs/combined.log`; packaged runs need writable log dirs or stdout-only policy.

### Major blockers / risks

1. Frontend Clerk gate:
   - Backend can run `AUTH_ENABLED=false` with dev passthrough.
   - Recruiter frontend still hard-requires Clerk sign-in, session wiring, active org, and backend org provisioning before rendering.
   - Runbook says a temporary `NEXT_PUBLIC_LOCAL_VIEW` bypass is needed, but not committed.
   - A real package needs a committed, safe local-auth contract or real Clerk-cloud dependency.

2. Postgres:
   - Required for startup and most app behavior.
   - Local `docker-compose.yml` provides Postgres 16 on host port 5432.
   - Production boot refuses superuser/BYPASSRLS DB roles unless `ALLOW_SUPERUSER_DB=true`.
   - Full isolation should avoid host-global port 5432 and use an app-private DB runtime/volume/socket/port.

3. Health/readiness:
   - `/api/v1/health` always checks ElevenLabs health, so offline/local readiness can return 503 even when voice features are disabled.
   - Need local readiness endpoint or feature-gated health.

4. External services:
   - Voice, Recall, Python REPL, graph, Stripe, Clerk, LLM/search/enrichment can require network/secrets depending on features.
   - Python REPL default URL points at Railway internal host.
   - Graph service is explicitly not in `docker-compose.prod.yml`; production expects separate Railway private networking.

5. zigBrowser local HTTP navigation policy:
   - `nav_policy.zig` meaningfully confines `file://` paths.
   - For `http://127.0.0.1` app_base, current policy falls back to allow normal navigations.
   - A local app mode needs same-origin/allowlist/external-open behavior for HTTP origins.

6. Current packaging:
   - Linux `.deb` packages only zigBrowser executable, desktop entry, icon, and WebKitGTK/GTK deps.
   - Windows MSI packages only zigBrowser.exe plus WebView2 bootstrapper.
   - No Node app, DB, migrations, supervisor, or app data layout is currently packaged.

## Web / Documentation Research Started

The Research skill was invoked and Standard Research workflow loaded:

- `/home/maceo/.codex/skills/Research/SKILL.md`
- `/home/maceo/.codex/skills/Research/Workflows/StandardResearch.md`
- `/home/maceo/.codex/skills/Research/UrlVerificationProtocol.md`
- `/home/maceo/.codex/skills/Research/QuickReference.md`

Voice notification was sent per skill instructions.

Web searches were started but not synthesized before the handoff interruption. Query themes already submitted:

- 2025/2026 best practices for local web app sandbox isolation and agentic apps
- OWASP Agentic AI security sandbox/tool isolation
- Docker Desktop Enhanced Container Isolation / hardened desktop isolation
- Flatpak sandbox/portals/filesystem/network isolation
- Docker rootless mode and container security options
- NIST container security guidance
- Windows AppContainer/MSIX isolation
- Apple App Sandbox
- Tauri/Electron security checklists
- gVisor, Firecracker, Kata Containers, Podman rootless, bubblewrap

One URL was opened but not yet used in a written artifact:

- `https://docs.docker.com/engine/security/rootless/`

Per the Research skill, every final URL must be fetched and verified before inclusion. Do not trust these as cited sources until verified.

## Likely Source Targets For Continued Web Research

Prioritize official primary docs and current security guidance:

- Docker rootless mode, Enhanced Container Isolation, Hardened Docker Desktop settings, container security options.
- Podman rootless and user namespaces.
- Flatpak sandbox + portals.
- Apple App Sandbox.
- Microsoft AppContainer/MSIX/package identity docs.
- Electron security checklist and Tauri security/capabilities, if considering shell alternatives.
- OWASP Agentic AI / LLM application security guidance for tool isolation, egress controls, and least privilege.
- NIST container/security docs and NIST AI RMF GenAI profile where relevant.
- gVisor/Kata/Firecracker docs for stronger-than-container isolation.

## Open Questions

- What platform is the first packaging target: Linux only, macOS, Windows, or all three?
- Does "fully isolated from user's local data" require kernel-enforced sandboxing on each OS, or is a container/user-namespace boundary acceptable for MVP?
- Should the packaged app be allowed network egress for Clerk/LLM/search/Stripe/voice, or should offline mode disable/stub all external services by default?
- Should local auth use real Clerk cloud, a local-only session provider, or a committed local dev-org mode?
- Should local Postgres be embedded, containerized, user-provided, or replaced with a package-private DB service?
- How will HazyForest's filesystem-isolation research define allowable mounts, downloads/uploads, and data persistence?
- Should zigBrowser own process supervision, or should a separate launcher own the child services and invoke zigBrowser only after readiness?

## Blockers

- Research artifact still needs to be written under `thoughts/searchable/shared/research/`.
- Web/doc sources still need verification and synthesis.
- Need HazyForest coordination response or later filesystem-isolation artifact.
- Existing worktree is dirty; do not touch/revert unrelated changes.
- Need explicit local auth design before implementation planning.
- Need readiness strategy that does not fail offline due ElevenLabs health.

## Recommended Research Artifact Shape

Create a file like:

`/home/maceo/ntm_Dev/zigBrowser/thoughts/searchable/shared/research/2026-07-04-09-XX-isolated-local-web-app-runtime-for-cosmic-hr04.md`

Suggested sections:

1. Executive summary
2. Constraints from cosmic-HR04 and zigBrowser
3. Threat model: agentic local app isolated from user data
4. 2025/2026 best-practice patterns
5. Runtime architecture options
6. Recommended architecture
7. Security boundaries
8. Process supervision/startup/shutdown
9. Data directories, logs, secrets
10. External service policy / offline matrix
11. Contracts/tests required
12. Open dependencies, including HazyForest filesystem research
13. Verified sources

## Concrete Next Steps

1. Continue Standard Research workflow using web search, but rely only on verified URLs.
2. Fetch/verify official docs for container/rootless/sandbox/runtime isolation.
3. Write the research artifact under `thoughts/searchable/shared/research/`.
4. Reference bead `zigBrowser-98g` and Agent Mail message `2201` in the artifact.
5. Poll Agent Mail for HazyForest response:
   - `fetch_inbox` for `TurquoiseHill`
   - topic `zigBrowser-98g`
6. Keep filesystem sandbox implementation details as a dependency on HazyForest unless their research is available.
7. Do not edit source files.
8. After research artifact is complete, update `zigBrowser-98g` with notes and close only if acceptance criteria are met.

## Relevant Commands Already Run

- `bd create ...` -> created `zigBrowser-98g`
- `bd update zigBrowser-98g --claim` -> reported issue already claimed by `TurquoiseHill`
- `bd show zigBrowser-98g --json`
- `bd list --status=in_progress --json`
- Agent Mail `register_agent` as `TurquoiseHill`
- Agent Mail `whois HazyForest`
- Agent Mail `send_message` to HazyForest -> message `2201`
- `./zig-out/bin/zigBrowser --version` -> `zigBrowser - WebKitGTK 2.52.3, GTK 3.24.49`
- `silmari-oracle metadata`

## Agent Mail Notes

- Registered name: `TurquoiseHill`
- Current ledger: `checked_in`, no claimed Agent Mail task id.
- Active Agent Mail claims: none.
- HazyForest profile:
  - `program=codex-cli`
  - task description: `Build integration owner + shared harness; root aggregation arbitration`
  - last active: `2026-06-03T19:58:08.673245+00:00`
- Inbox for `TurquoiseHill` contains historical messages, none ack-required in the fetch output. Notable historical messages:
  - `2134`: final close-out, pushed head `af2e4c3`, no open issues at that time.
  - `2102`: urgent warning about proving Zig IPC/nav_policy linkage by provenance.
  - `2089`: local E2E display note, `DISPLAY=:1` live, `xvfb-run` not installed.

## Other Notes

- The user explicitly asked "Do not edit source files." The next agent should preserve that unless the user changes instructions.
- The handoff itself is a requested non-source artifact.
- Prior final answer already concluded "single-origin production static UI served by Express" is the preferred local packaging architecture, pending auth/DB/health/supervisor work.
- There is an existing open bead `zigBrowser-2aa` for build-time JSON config ingestion. It is adjacent but not the same as `zigBrowser-98g`.
