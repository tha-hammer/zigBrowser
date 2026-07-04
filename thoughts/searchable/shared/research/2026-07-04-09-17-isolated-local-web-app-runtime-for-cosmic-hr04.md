---
date: 2026-07-04T09:17:19-04:00
researcher: TurquoiseHill
git_commit: af2e4c35a9a6f927d9b3d1e3bcff835fcc97aa21
branch: master
repository: zigBrowser
topic: "Isolated local web-app runtime packaging for cosmic-HR04 with zigBrowser"
tags: [research, packaging, isolation, cosmic-hr04, zigbrowser, local-runtime]
status: complete
last_updated: 2026-07-04
last_updated_by: TurquoiseHill
bead: zigBrowser-98g
agent_mail_coordination: 2201
---

# Research: Isolated local web-app runtime packaging for cosmic-HR04 with zigBrowser

## Executive Summary

Packaging cosmic-HR04 to run locally behind zigBrowser is feasible, but not as a direct repackaging of today's Railway deployment. The viable architecture is a local app bundle that owns its process tree, data directories, browser profile, database, secrets, logs, egress policy, and shutdown behavior. zigBrowser should load a loopback HTTP origin after the local service is ready; it should not be treated as the only isolation boundary.

Recommended first architecture:

1. Build `recruiter-ui` as static output.
2. Run one Express backend in `NODE_ENV=production` so it serves `recruiter-ui/out`.
3. Bind the backend only to `127.0.0.1:<reserved-or-ephemeral-port>`.
4. Run Postgres as an app-private service with an app-private data directory, not the host's global port `5432`.
5. Launch zigBrowser to the loopback origin after readiness passes.
6. Give zigBrowser an app/workspace-specific browser profile directory.
7. Disable or explicitly broker external-service features by default.
8. Enforce filesystem isolation outside cosmic-HR04 and zigBrowser through the package/runtime layer; keep detailed filesystem mount policy dependent on HazyForest's filesystem-isolation research.

The biggest implementation blockers are local auth, Postgres packaging, health/readiness, and an HTTP-origin navigation policy for zigBrowser. The package should not claim "fully isolated from user-local data" until those contracts are implemented and tested.

## Inputs Reviewed

### Handoff and coordination

- Handoff: `/home/maceo/ntm_Dev/zigBrowser/thoughts/searchable/shared/handoffs/zigBrowser-98g/2026-07-04_09-03-53_zigBrowser-98g_cosmic-hr04-local-packaging-research.md`
- Bead: `zigBrowser-98g`
- Agent Mail sender identity: `TurquoiseHill`
- Agent Mail coordination message to `HazyForest`: `2201`
- `fetch_inbox` topic `zigBrowser-98g` returned no HazyForest response as of this research pass.

### Local code/docs

- `/home/maceo/Dev/cosmic-HR04/docs/local-development-runbook.md`
- `/home/maceo/Dev/cosmic-HR04/package.json`
- `/home/maceo/Dev/cosmic-HR04/recruiter-ui/package.json`
- `/home/maceo/Dev/cosmic-HR04/backend/server.js`
- `/home/maceo/Dev/cosmic-HR04/backend/routes/health.js`
- `/home/maceo/Dev/cosmic-HR04/backend/config/schema.js`
- `/home/maceo/Dev/cosmic-HR04/backend/config/loader.js`
- `/home/maceo/Dev/cosmic-HR04/backend/storage/local.js`
- `/home/maceo/Dev/cosmic-HR04/recruiter-ui/app/(recruiter)/layout.jsx`
- `/home/maceo/Dev/cosmic-HR04/docker-compose.yml`
- `/home/maceo/Dev/cosmic-HR04/docker-compose.prod.yml`
- `/home/maceo/ntm_Dev/zigBrowser/src/cli.zig`
- `/home/maceo/ntm_Dev/zigBrowser/specs/lifecycle.md`
- `/home/maceo/ntm_Dev/zigBrowser/thoughts/searchable/shared/research/2026-07-04-08-57-zigbrowser-filestore-seams-grammar-contracts.md`
- `/home/maceo/ntm_Dev/zigBrowser/thoughts/searchable/shared/research/2026-07-04-12-30-build-time-config-seams.md`
- `/home/maceo/ntm_Dev/zigBrowser/thoughts/searchable/shared/plans/2026-07-04-12-50-tdd-build-time-json-config.md`

## Current Runtime Constraints

### cosmic-HR04

- Root package requires Node `>=20.0.0` and npm `>=9.0.0`.
- `npm run build` builds the recruiter and jobseeker frontends; `npm start` runs `node backend/server.js`.
- Production Express serves `recruiter-ui/out` from the backend when `config.app.env === 'production'`.
- Backend startup initializes the database before serving; failure exits the process.
- WebSockets are initialized on the same HTTP server after `listen`.
- SIGTERM/SIGINT are handled and the process attempts graceful server and database shutdown with a 30 second forced-exit timeout.
- Local audio storage defaults to `./data/audio`, resolved relative to the project root unless absolute.
- The local development compose file exposes Postgres 16 on host port `5432`; that is convenient for development but not app-private isolation.
- The production compose file includes `db`, `python-repl`, and `backend`, but no recruiter UI service and no graph service. It is explicitly documented as partial/self-host helper, not the Railway deploy path.

### Auth and frontend gating

- Backend config can run with `AUTH_ENABLED=false`.
- The recruiter frontend still imports Clerk and hard-requires `useAuth`, `useOrganization`, and backend organization provisioning before rendering the member shell.
- The local runbook documents a temporary `NEXT_PUBLIC_LOCAL_VIEW` bypass, but warns that bypass must not be committed. There is no committed local-auth contract today.
- A packaged local app needs either real Clerk cloud auth or a committed local-only auth mode. Shipping an untracked/local bypass is not acceptable.

### Health and readiness

- `/api/v1/health` checks both DB and ElevenLabs.
- If ElevenLabs is unreachable, the route can return `503` even when the local app is otherwise usable and voice features are disabled.
- The local supervisor needs a readiness contract that is feature-gated and offline-safe. Current health is not sufficient as the sole startup gate.

### External services

Feature defaults and config show multiple optional or configured network dependencies:

- Clerk, Stripe, ElevenLabs, Recall, OpenAI/LLM provider, Google/Serp/BrightData/BrightLocal/PhantomBuster, graph service, provenance service, Python REPL service.
- `PYTHON_REPL_URL` defaults to a Railway internal host when enabled.
- `RLM_ENABLE_WEB_SEARCH` defaults true.
- Voice and Recall have explicit fatal validations only when enabled, but health currently probes ElevenLabs unconditionally.

### zigBrowser

- `src/cli.zig` still hardcodes the Railway URL as the no-arg default.
- `specs/lifecycle.md` covers URI validation, WebKit/WebView creation, navigation policy, IPC, and teardown for `open` mode.
- Existing filestore/config research shows zigBrowser has no implemented profile-directory grammar, app data directory grammar, local backend supervisor, or host filesystem import contract.
- Existing navigation policy meaningfully confines `file://` app bases, but HTTP loopback app bases currently fall through to normal navigation behavior. A local app mode needs explicit same-origin/allowlist/external-open behavior for `http://127.0.0.1:<port>`.

## Threat Model

Treat the packaged cosmic-HR04 app as an agentic local application, not just a desktop webview. The runtime may process sensitive local files, run LLM-mediated workflows, call tools, write browser/DB state, and talk to external services. The attacker may control:

- Web content or script reachable by the app.
- Prompt or document content ingested by agentic workflows.
- Network responses from external services.
- Uploaded/imported files.
- Compromised npm dependencies or runtime child processes.

The isolation goal is:

- The app cannot read arbitrary user-local files.
- The app cannot write outside app-owned data/log/cache directories except through explicit user-brokered import/export flows.
- The app cannot bind broad network interfaces or expose services beyond loopback without explicit configuration.
- The app cannot call external services unless the package policy enables that service and supplies scoped credentials.
- Browser storage, cookies, IndexedDB/OPFS/cache, and DB state are per app/workspace and cannot bleed across unrelated runs.
- Shutdown leaves no orphaned backend, DB, browser, or helper process.

## 2025/2026 Best-Practice Patterns

### Containers are packaging and isolation, not a complete sandbox by themselves

NIST SP 800-190 frames containers as operating-system virtualization combined with application packaging, and explicitly scopes the guide to container security risks and mitigations. For this package, containers are useful for Postgres/backend/process layout, but the package still needs host filesystem, network, secrets, and browser-profile controls.

### Prefer rootless/user-namespace isolation for local Linux containers

Docker rootless mode runs both the daemon and containers as a non-root user inside a user namespace. Podman rootless mode automatically creates a user namespace for the user and keeps rootless containers invisible to root-managed Podman instances. For a local app intended to reduce host blast radius, rootless Podman is the cleaner Linux-first default than a rootful Docker daemon.

### Harden container namespace and bind-mount policy

Docker Desktop Enhanced Container Isolation blocks host namespace sharing such as `--pid=host` and `--network=host`, contains privileged workloads, and restricts sensitive VM bind mounts. The package should apply the same principles even if it does not depend on Docker Desktop:

- No host PID/network namespace sharing.
- No privileged containers for normal operation.
- No broad `$HOME` bind mounts.
- Only app-private volumes plus explicit brokered import/export mount points.
- No Docker socket mount.
- No host port `5432` exposure for the app DB.

### Use desktop sandboxes and portals where the package format supports them

Flatpak documents static permissions and portal-mediated resource access. Filesystem and network permissions are explicit, and portal flows let the user choose resources rather than giving the app broad access to home. Network access is not harmless: Flatpak notes that giving network access can expose host services on abstract Unix sockets in some environments.

For Linux desktop distribution, a Flatpak-style package is the best fit for "isolated from user-local data" because the desktop shell can broker file selection and constrain filesystem access. A `.deb` alone does not provide this.

### Use native OS isolation on Windows/macOS

Windows AppContainer provides file, registry, network, process, window, and device isolation with granular access grants. MSIX/AppContainer should be the Windows target if Windows support needs a real OS sandbox rather than only a normal MSI.

Apple's developer security overview describes App Sandbox as limiting app privileges to intended functionality to protect Mac systems and users. A macOS target should use App Sandbox, Hardened Runtime, notarization, and security-scoped user file access where persistent access is required.

### Separate browser profiles and app data stores explicitly

WebView storage must be configured, not incidental:

- WebView2 stores cookies, permissions, cache, IndexedDB, file systems, and other browser data in a user data folder. Microsoft documents using different UDFs to isolate different parts of an app when sharing data is not needed.
- WebKitGTK `WebKitWebsiteDataManager` can set base data/cache directories or be ephemeral.
- WKWebView has persistent and nonpersistent data stores; the public Apple docs are JS-heavy, but the API surface is the relevant seam for macOS profile isolation.

zigBrowser should gain a per-app/per-workspace browser profile/data directory contract before local packaging claims isolation.

### Stronger-than-container options exist for higher-risk modes

If the package needs to run untrusted tool code or stronger AI-agent isolation, gVisor, Kata Containers, or Firecracker are stronger tiers:

- gVisor interposes a userspace Sentry kernel and Gofer file mediator between the application and host kernel/filesystem.
- Kata Containers uses lightweight VMs to add hardware virtualization as a second isolation layer.
- Firecracker creates lightweight KVM microVMs with a minimal device model and a jailer for an additional user-space barrier.

These are operationally heavier than a desktop MVP, but they are the right family for "agent can execute code" threat models.

## Runtime Architecture Options

### Option A: Native supervisor plus app-private services

Shape:

- Package Node runtime/app, Postgres runtime, migrations, static frontend, and zigBrowser.
- Supervisor creates app data dirs, starts Postgres on an app-private socket or loopback port, runs migrations, starts Express, probes readiness, then launches zigBrowser.
- External service features are disabled by default.

Pros:

- Best UX if implemented carefully.
- No Docker dependency for end users.
- Can integrate with native App Sandbox/AppContainer/MSIX/Flatpak.

Cons:

- Highest implementation work.
- Must own Postgres lifecycle and upgrades.
- Needs explicit sandbox policy per OS.

Fit:

- Best long-term desktop app shape.
- Not enough for high-risk arbitrary tool execution unless paired with OS sandbox or VM boundary.

### Option B: Rootless container composition plus zigBrowser host shell

Shape:

- Use rootless Podman or rootless Docker to run backend, DB, and optional helpers.
- Expose only backend loopback port to the host.
- zigBrowser runs as host desktop shell and points to loopback.

Pros:

- Fastest path to local service parity.
- Clean app-private volumes and process groups.
- Stronger than ad hoc host processes.

Cons:

- Docker Desktop/rootless setup is not uniformly available.
- Containers are not enough for user file privacy unless mount policy is tight.
- Windows/macOS Docker Desktop adds VM-specific behavior and licensing/UX concerns.

Fit:

- Best research/MVP path for Linux developer builds.
- Package should present this honestly as "container-isolated local runtime", not full OS sandboxing.

### Option C: Flatpak/MSIX/App Sandbox native package

Shape:

- Package the app with platform-native sandboxing.
- Use app-private data dirs and portal/broker flows for files.
- Internal services run inside the sandbox or behind a helper with strict brokered APIs.

Pros:

- Most aligned with "isolated from user-local data".
- Native permission UX.
- Stronger story for end users.

Cons:

- Platform-specific packaging work.
- Postgres and Node child process handling inside sandbox needs design proof.
- Filesystem import/export must be designed around portals/security-scoped access.

Fit:

- Best production packaging target.
- Needs HazyForest filesystem-isolation output before detailed mount/broker design.

### Option D: VM/microVM runtime

Shape:

- Run app services inside a lightweight VM/microVM.
- Expose only loopback web origin to zigBrowser.
- Use shared folders only through explicit brokered paths.

Pros:

- Strongest isolation for compromised backend/agent/tool code.
- Clean host boundary.

Cons:

- Heavy packaging and update complexity.
- Hardware virtualization requirements.
- Harder local UX.

Fit:

- Later high-security mode or enterprise mode, not first local package.

## Recommended Architecture

Use a two-track plan:

### MVP research-to-implementation target

Linux-first rootless service bundle:

- rootless Podman preferred, rootless Docker acceptable where available
- backend plus Postgres in an app-private pod/network
- no host DB port
- backend listens only on loopback
- zigBrowser launched as local shell
- app-private browser profile directory
- external services disabled by default
- local readiness endpoint not dependent on ElevenLabs
- local auth contract committed before UI packaging

This can produce a realistic local package without claiming full desktop sandboxing.

### Production desktop target

Platform-native sandbox packaging:

- Linux: Flatpak or equivalent bubblewrap-backed package with no broad home mount.
- Windows: MSIX/AppContainer rather than plain MSI for isolation.
- macOS: App Sandbox plus Hardened Runtime and notarization.
- Browser profile, DB, logs, secrets, downloads, imports, and exports all under app/workspace-specific directories.
- User-local file access only via portal/security-scoped/brokered flows.

## Security Boundaries

Required boundaries:

- Browser profile: distinct per app/workspace.
- App data: DB, uploads, local storage, logs, temp files, and caches under package-owned dirs.
- Filesystem: no broad access to `$HOME`, `~/Documents`, `~/.ssh`, cloud-sync folders, or host project dirs.
- Network ingress: backend binds `127.0.0.1` only; no LAN binding by default.
- Network egress: default deny or explicit allowlist by feature.
- Secrets: no Doppler dependency in packaged mode; secrets are either absent, generated locally, or stored in platform secret storage.
- Process tree: supervisor owns backend, DB, helper services, and zigBrowser lifecycle.
- Navigation: zigBrowser local app mode permits app origin and expected asset/API/WebSocket routes; external links open externally or are blocked according to policy.
- IPC: host IPC callable only by the app origin, not arbitrary navigated pages.

## Process Supervision

Supervisor responsibilities:

1. Create app directories with restrictive permissions.
2. Allocate or verify loopback ports.
3. Start app-private Postgres and wait for DB readiness.
4. Run migrations idempotently.
5. Start backend with packaged-mode env.
6. Probe local readiness endpoint.
7. Launch zigBrowser to the local URL.
8. Monitor all children and propagate shutdown.
9. On zigBrowser exit, gracefully terminate backend and DB.
10. On backend/DB failure, close zigBrowser or display a local error page.

Do not rely on shell scripts that leave orphaned services. The lifecycle must be a product contract.

## Data Directories, Logs, and Secrets

Proposed layout:

```text
<app-data-root>/
  cosmic-hr04/
    config/
      local-runtime.json
    db/
      postgres/
    browser/
      profile/
      cache/
    storage/
      audio/
      uploads/
      imported-files/
    logs/
      backend.log
      supervisor.log
    temp/
```

Rules:

- DB and browser profile are never stored in the source checkout.
- `STORAGE_LOCAL_PATH` points inside app data, never project-relative `./data/audio` in packaged mode.
- Logs are bounded/rotated or stdout-captured by the supervisor.
- Runtime-generated secrets use platform secret storage where possible.
- Cloud service API keys are omitted by default and must be explicit user/admin configuration.

## External Service Policy

Default packaged mode should be offline-first for local browsing and data inspection:

| Feature | Default | Requirement to enable |
|---|---|---|
| Clerk | disabled or local auth | committed local auth provider or real Clerk config |
| Stripe | disabled | explicit billing mode and keys |
| ElevenLabs voice | disabled | keys, webhook/tool secrets, readiness excluded unless enabled |
| Recall | disabled | token plus live/stub transcript provider contract |
| LLM/STT | disabled or local provider | explicit provider, key/base URL, egress allow |
| Web search/enrichment | disabled | provider keys and egress allow |
| Python REPL | disabled | local service URL, sandbox, timeout, network policy |
| Graph/provenance | disabled unless bundled | local service package or explicit URL/secret |

## Contracts and Tests Required

### cosmic-HR04 contracts

- Packaged-mode config schema: `PACKAGED_LOCAL_MODE=true` or equivalent.
- Local auth contract: UI and backend agree on local session/org behavior.
- Readiness endpoint: returns success when DB and enabled local features are ready, and does not probe disabled cloud features.
- DB lifecycle contract: init, migrate, backup, restore, upgrade, shutdown.
- Feature flag matrix: disabled features do not mount routes, start schedulers, call health checks, or require secrets.
- Storage contract: all local storage roots resolve under app data root.

### zigBrowser contracts

- Build/runtime config can set default app URL.
- Local app mode can set browser profile/data/cache directories.
- HTTP loopback navigation policy pins app origin and blocks or externally opens unexpected destinations.
- Host IPC is origin-gated.
- E2E protocol includes browser profile and blocked navigation observability.
- Shutdown waits for WebKit/WebView child processes before deleting ephemeral profiles.

### Package/supervisor contracts

- No source checkout required at runtime.
- No user home bind mount by default.
- No global Postgres port.
- All child processes are terminated on app close.
- Startup error states are user-visible.
- Uninstall can preserve or delete app data by policy.
- App can run twice only with separate workspace/profile/port allocation or a single-instance lock.

### Security tests

- Attempt to read `~/.ssh/id_rsa`, `~/Documents`, and arbitrary host paths from app/backend/browser: denied.
- Import a user-selected file and verify only the isolated copy is retained.
- Navigate to external origin and verify it cannot call host IPC or read app browser storage.
- Run with network disabled and verify disabled cloud features do not block readiness.
- Verify DB binds only app-private socket/loopback and rejects external LAN access.
- Verify Postgres role is not superuser/BYPASSRLS in production-like mode.
- Verify duplicate file imports create distinct logical objects with identical hashes when bytes match.

## Open Dependencies

- HazyForest filesystem-isolation research is still needed for final mount/import/export policy.
- Local auth design must be accepted before implementation planning.
- Readiness design must replace or augment current `/api/v1/health`.
- App-private Postgres packaging choice must be made.
- zigBrowser build-time config issue `zigBrowser-2aa` is adjacent and likely prerequisite for replacing the Railway default URL.
- zigBrowser browser-profile/config grammar is not implemented.
- The current worktree has unrelated dirty source changes; this research intentionally does not edit source files.

## Verified Sources

All URLs below were fetched/opened during this research pass before inclusion.

- Docker Engine rootless mode: https://docs.docker.com/engine/security/rootless/
  - Relevant finding: rootless mode runs daemon and containers as a non-root user inside a user namespace.
- Docker Desktop Enhanced Container Isolation: https://docs.docker.com/enterprise/security/hardened-desktop/enhanced-container-isolation/
  - Relevant finding: ECI blocks host namespace sharing, contains privileged workloads, and restricts sensitive mounts.
- Podman rootless mode: https://docs.podman.io/en/stable/markdown/podman.1.html
  - Relevant finding: rootless Podman creates a user namespace for the user and separates rootless containers from root-managed ones.
- Flatpak sandbox permissions: https://docs.flatpak.org/en/latest/sandbox-permissions.html
  - Relevant finding: filesystem/network permissions are explicit, portals broker access, and network access can expose host services in some environments.
- Microsoft AppContainer isolation: https://learn.microsoft.com/en-us/windows/win32/secauthz/appcontainer-isolation
  - Relevant finding: AppContainer covers file/registry, network, process, window, and device isolation with granular grants.
- Apple developer security overview: https://developer.apple.com/security/
  - Relevant finding: App Sandbox protects Mac systems/users by limiting app privileges to intended functionality.
- NIST SP 800-190 landing page: https://csrc.nist.gov/pubs/sp/800/190/final
  - Relevant finding: NIST treats containers as OS virtualization plus packaging and focuses on associated security concerns and recommendations.
- OWASP Agentic AI Threats and Mitigations: https://genai.owasp.org/resource/agentic-ai-threats-and-mitigations/
  - Relevant finding: agentic AI expands autonomous-system risk and needs threat-model-driven mitigations.
- Microsoft WebView2 user data folders: https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/user-data-folder
  - Relevant finding: UDFs store cookies, permissions, caches, IndexedDB/FileSystems, and can be separated by app/profile.
- WebKitGTK WebsiteDataManager: https://webkitgtk.org/reference/webkit2gtk/unstable/class.WebsiteDataManager.html
  - Relevant finding: WebKitGTK can configure website data/cache directories or use ephemeral website data.
- gVisor docs: https://gvisor.dev/docs/
  - Relevant finding: gVisor interposes a Sentry application kernel and Gofer filesystem mediator instead of passing app syscalls directly to the host kernel.
- Kata Containers: https://katacontainers.io/
  - Relevant finding: Kata uses lightweight VMs for stronger workload isolation with hardware virtualization.
- Firecracker: https://firecracker-microvm.github.io/
  - Relevant finding: Firecracker microVMs use KVM, a reduced device model, and a jailer to reduce attack surface and isolate workloads.

## Bottom Line

The correct local packaging target is not "run the current Railway app locally" but "create a packaged local runtime with an explicit isolation contract." The fastest credible path is a rootless Linux service bundle that uses zigBrowser as the app shell and documents its limits. The production-grade path is native sandbox packaging per OS, with user-file access mediated through platform brokers and all app state kept in app-private directories.
