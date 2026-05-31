---
date: "2026-04-17T09:35:00-04:00"
researcher: Silmari
topic: "Cosmic separation + remote MCP + remote DB architecture"
tags: [research, architecture, mcp, remote, cosmic, separation, deploy, security]
status: complete
type: architectural_research
---

# Cosmic separation + remote MCP + remote DB hosting — research findings

**Three parallel research streams executed:** (1) internal Explore scan of cosmic dependency surface, (2) ClaudeResearcher on MCP remote-transport spec + Claude Code support, (3) general-purpose agent on remote-SQLite patterns for `beads_rust`.

This document presents findings, a matrix of deployment configurations, and option sets. **It is NOT a plan** — each section ends with decision points the user needs to resolve before implementation begins.

---

## Part 1 — Cosmic separation: how close are we to done?

### The surface is already small

| Category | Count | Detail |
|---|---|---|
| Hard code deps on cosmic paths | **2 scripts** | `apps/silmari-mcp/scripts/migrate-from-cosmic.ts` (one-shot, already run), `apps/silmari-mcp/scripts/backfill-edges-from-cosmic.ts` (recurring for fresh machines) |
| Library imports of `cosmic-agent-memory/*` | **0** | No runtime imports from cosmic packages |
| Source-code lineage comments | 8 | `folgezettel.ts:20`, `paths.ts:15`, `br-adapter.ts:11`, `init.ts:37`, `edge-extractors.ts:119` — all "ported from" attributions, not runtime deps |
| Silmari cards with `legacy-*` labels | **430 labels** on ~244 cards | `legacy-id:*` (244), `legacy-fz:*` (178), `legacy-created:*` (244), `memory:*` (~20) — traceability, not blocking |
| Docs referencing cosmic | README.md (Graph-edges section), Plans/001, Plans/002, Plans/003 §D.2 | |
| Memory files naming cosmic | 1 critical: `reference_cosmic_db_canonical_location.md` | |
| Tests using cosmic fixtures | 1 (`tests/backfill-edges.test.ts`) | Pure in-memory fixtures, no external cosmic file |

### The real SPoF: `ionos01:/root/.cosmic-agent/.beads/beads.db`

This file has **382 non-blocks dependency rows** that are the source of truth for the Tier C backfill. No other machine has a complete copy. If ionos01 goes down or the file is deleted, fresh silmari machines can't restore their edges.

**Current fragility:**
- Single machine (ionos01) holds the canonical copy
- No versioned archive
- No checksum or integrity validation
- The backfill script's default points at this path (`backfill-edges-from-cosmic.ts:121`)

### Options to finish the separation

**Option A — Archive the cosmic DB as a repo fixture.** Copy `ionos01:/root/.cosmic-agent/.beads/beads.db` (4.2 MB) into the repo as a git LFS file under `archive/cosmic-snapshot-2026-04-XX/beads.db`. Update `backfill-edges-from-cosmic.ts` default to read from the repo path. Checksum the snapshot in `archive/README.md`. **Result:** ionos01 is no longer a SPoF; any clone of silmari-agent-memory carries the needed data.

- Pros: trivial, one-time, preserves the backfill capability forever
- Cons: adds 4.2 MB LFS object; couples cosmic history into silmari's git forever
- Risk: low — LFS handles binary snapshots well

**Option B — Freeze + delete.** Run the backfill script against the cosmic DB ONE LAST TIME on every known silmari machine (laptop + ionos01 already done), then delete the script and the cosmic DB from ionos01. Convert the cosmic state into a frozen set of `ref:*` labels that live entirely in each silmari store.

- Pros: cleanest end state — no cosmic anywhere
- Cons: **irreversible** — if you later discover a cosmic edge that wasn't captured, there's no re-run path; any new silmari clones created after deletion get the labels via rsync/export from an existing machine, not the backfill
- Risk: medium — loses optionality

**Option C — Leave it.** Keep ionos01's cosmic DB as-is; accept the SPoF. Low effort.

- Pros: zero work
- Cons: current fragility remains; memory file `reference_cosmic_db_canonical_location.md` already describes this risk

**Recommended:** Option A. Fixture-in-repo is the normal pattern for this kind of one-time-but-still-needed historical data (see: git LFS seed fixtures for test suites). Cost is negligible; the "complete separation" outcome is achieved without losing rerun capability.

---

## Part 2 — Remote MCP server: what the MCP spec and Claude Code support

### Transport options (MCP spec 2025-03-26, carried into 2025-11)

| Transport | Status | Use |
|---|---|---|
| **stdio** | Standard | Local subprocess (current silmari-mcp) |
| **Streamable HTTP** | Standard (current) | Single `POST/GET /mcp` endpoint; server optionally upgrades to SSE stream for multi-message pushes. Replaces the older HTTP+SSE dual-endpoint transport |
| **SSE (legacy)** | Deprecated | Kept in SDKs for backward compat; don't build on it |
| **WebSocket** | Not spec'd | Proposed as [SEP-1288](https://github.com/modelcontextprotocol/modelcontextprotocol/issues/1288) but unmerged; ignore |

### Claude Code client support (verified via official docs)

```bash
# the three transport modes are all supported by `claude mcp add`
claude mcp add --transport stdio <name> -- <cmd> <args...>
claude mcp add --transport http   <name> <url> [--header "K: V"]
claude mcp add --transport sse    <name> <url> [--header "K: V"]
```

Real-world examples from Anthropic docs: `claude mcp add --transport http notion https://mcp.notion.com/mcp`; `claude mcp add --transport http secure-api https://api.example.com/mcp --header "Authorization: Bearer $TOKEN"`. Announced June 2025 ([InfoQ](https://www.infoq.com/news/2025/06/anthropic-claude-remote-mcp/)).

### Silmari-mcp diff from stdio to Streamable HTTP

The `@modelcontextprotocol/sdk` already ships `StreamableHTTPServerTransport` at `@modelcontextprotocol/sdk/server/streamableHttp.js` (added in SDK 1.10.0, April 2025). Minimal diff:

```ts
// current: apps/silmari-mcp/src/index.ts
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
// ...
await server.connect(new StdioServerTransport());

// remote-HTTP mode: same server, new transport + Bun HTTP handler
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
const transport = new StreamableHTTPServerTransport({ /* session config */ });
await server.connect(transport);
Bun.serve({
  port: 8789,
  async fetch(req) {
    // optional Bearer-token check here
    return transport.handleRequest(req);
  },
});
```

**Key gotchas:**
- **CVE-2025-66414** — SDK does NOT enable DNS-rebinding protection by default. Bind to `127.0.0.1` and front with nginx/Caddy for TLS + auth, OR set `allowedHosts`.
- **Session-ID lifecycle** — server issues `Mcp-Session-Id` on init; after server restart, returns 404 on stale IDs. Some clients mishandle this ([LibreChat #11868](https://github.com/danny-avila/LibreChat/issues/11868)). Consider stateless mode for simple servers.
- **60-second idle disconnect** — nginx/Cloudflare kill idle SSE streams ([fastmcp #120](https://github.com/punkpeye/fastmcp/issues/120)). Send keepalive or use stateless request/response.
- **Horizontal scaling** — session state is in-process; sticky routing required for multi-replica. Not relevant at current scale.

### Authentication — single-user VPS pattern

**Static Bearer token via `--header`** is the overwhelmingly common pattern for personal/internal servers. Claude Code passes the header on every HTTP request; the server validates and returns 401 on mismatch. Token stored in `~/.claude.json`. No rotation — use OAuth 2.1 + PKCE only if you need it.

### Latency — acceptable

- stdio: sub-millisecond IPC
- HTTPS ionos01 round-trip (continental US): 20–80 ms
- MCP clients tolerate this well — tool calls already take hundreds of ms. UX hit is imperceptible for ordinary calls.

### Reference implementations

- Linear: `https://mcp.linear.app/mcp`
- Notion: `https://mcp.notion.com/mcp` (also local: `npx @notionhq/notion-mcp-server --transport http`)
- Atlassian: `https://mcp.atlassian.com/v1/sse` (still on legacy SSE)
- [Cloudflare's Remote MCP server guide](https://developers.cloudflare.com/agents/guides/remote-mcp-server/)

### Options for silmari-mcp

**Option A — Add HTTP transport as an opt-in `MCP_TRANSPORT=http` env gate.** Keep stdio as default. Read env at startup, pick the transport accordingly. Zero regression for existing local users; enables alpha-remote deploys.

**Option B — Ship two entrypoints.** `src/index.ts` (stdio), `src/index-http.ts` (HTTP). Wraps the same `Server` instance. Clean separation; slight duplication.

**Option C — Replace stdio entirely.** Not recommended — breaks every existing Claude Code window config.

**Recommended:** Option A. One file, env-gated, additive.

---

## Part 3 — Remote database: hosting options

### beads_rust has NO client-server mode

Scan of `vendor/beads_rust/`:
- `src/mcp/mod.rs:60-130` — only server is the MCP server, stdio only
- `src/sync/` — JSONL git-sync, not network sync
- `Cargo.toml` — no `tokio`/`hyper`/`axum`/`reqwest`/`tonic`/`libsql`/`sqlx`
- `CLI_SCHEMA.json` — no `--remote`/`--server`/`--host`/`--port` flags

**Verdict:** `br` is strictly local-file SQLite via `rusqlite`. All remoteness must be added outside the binary.

### Remote-SQLite options

| Option | Drop-in? | Status | Notes |
|---|---|---|---|
| **libSQL (Turso)** | No — requires replacing br's storage layer | Production | Would fork `br`. Not viable without Rust rewrite. |
| **Cloudflare D1** | No (HTTP-only) | Production | Rule out — no local file |
| **rqlite** | No | Production | Own driver; `br` can't open |
| **LiteFS** | **Yes** (FUSE file) | Production | `br` opens the FUSE-mounted file unchanged. Primary accepts writes, replicas read-only. ~2x fsync overhead. Requires consul/static leader. |
| **Marmot (NATS CDC)** | **Yes** (local file + CDC sync) | Production | Multi-writer leaderless. Each machine has a local .db; Marmot replicates changes. Overkill for single user (eventual consistency = you can see your own write disappear briefly). |
| **SSHFS / NFS** | Yes syntactically | **UNSAFE** | POSIX advisory locking broken on most NFS; WAL mode doesn't work over SSHFS ([sqlite.org/lockingv3](https://sqlite.org/lockingv3.html), [GoToSocial on networked storage](https://docs.gotosocial.org/en/latest/advanced/sqlite-networked-storage/)). Safe only for cold snapshots. |

### The real leverage point: `br-adapter.ts`

`apps/silmari-mcp/src/lib/br-adapter.ts` drives everything through `execFileSync('br', args)` — it never touches sqlite directly. No `new Database()`, no `bun:sqlite` import. `getDbFlag()` at line 72 injects `--db <path>` on every call.

**This means:**
- If MCP + `br` + DB all live on the same remote (current alpha): zero networking code needed. Already working.
- If MCP lives on host A and DB lives on host B: wrap `execFileSync('br', args)` in an optional `execFileSync('ssh', ['dbhost', 'br', ...args])` using an `SILMARI_DB_HOST` env var. `ControlMaster`/`ControlPersist` amortize the SSH handshake.

### Deployment patterns

| Pattern | MCP | DB | User-facing transport | Comment |
|---|---|---|---|---|
| **A — current local** | laptop | laptop | stdio | Default; works today |
| **B — current alpha** | ionos01 | ionos01 | stdio via `ssh -T` | Works today per `reference_ionos01_alpha_deploy` |
| **C — alpha HTTPS** | ionos01 | ionos01 | HTTPS Streamable | Add Streamable HTTP transport + Bearer; one config, N Claude Code windows, no per-window subprocess |
| **D — split-host alpha** | ionos01 | `dbhost` | HTTPS Streamable | `br-adapter` runs `ssh dbhost br ...`; adds ~30-80ms per call |
| **E — laptop MCP, remote DB** | laptop | ionos01 | stdio | laptop's `br-adapter` runs `ssh ionos01 br ...`; useful for "work from anywhere, one authoritative store" |
| **F — libSQL hybrid** | ionos01 | libSQL (fork) | HTTPS Streamable | Requires forking `br` to use libSQL. High cost. Defer. |

**Recommended near-term:** Patterns A (default local), B (current alpha), C (new), E (new). Skip D until multi-user. Skip F indefinitely.

---

## Part 4 — Configurability matrix

User's request: "configurable MCP host + configurable DB host, same or different."

Proposed env-var surface (additive — default behavior unchanged):

```bash
# Transport selection (client side, in claude mcp add)
# Default: stdio (current behavior)
# Remote: `claude mcp add --transport http silmari https://silmari.ionos01.example/mcp --header "Authorization: Bearer $TOKEN"`

# Server side (env read at MCP server startup):
MCP_TRANSPORT=stdio|http        # default stdio
MCP_HTTP_PORT=8789              # when http
MCP_HTTP_BEARER=<token>         # when http; 401 on mismatch
MCP_HTTP_ALLOWED_HOSTS=127.0.0.1  # DNS-rebinding protection

# DB host (read by br-adapter.ts):
SILMARI_DB_HOST=                 # empty = local; 'ionos01' = ssh ionos01 br ...
SILMARI_DB_SSH_OPTS=             # optional extra ssh args (ControlMaster, etc.)
SILMARI_DIR=~/.silmari-memory    # already exists; path on whichever host runs br
```

With those, the user gets:

| Config profile | `claude mcp add` command | Server env |
|---|---|---|
| laptop-only (current) | `--transport stdio ... -- bun run .../index.ts` | (nothing) |
| alpha stdio (current) | `--transport stdio ... -- ssh -T ionos01 ...` | `SILMARI_DIR=/home/silmari/.silmari-memory` |
| alpha HTTPS (new) | `--transport http silmari https://silmari.ionos01/mcp --header "Authorization: Bearer $TOK"` | `MCP_TRANSPORT=http MCP_HTTP_BEARER=$TOK SILMARI_DIR=...` |
| split-host (new) | same as alpha HTTPS | also `SILMARI_DB_HOST=dbhost` |
| laptop-MCP + remote-DB (new) | local stdio | local laptop sets `SILMARI_DB_HOST=ionos01` in its env before launching MCP |

---

## Part 5 — Unknowns + open questions for the user

1. **Does the alpha (ionos01) have TLS wired up?** The current deploy script (`scripts/deploy-ionos01.sh`) installs nginx but no TLS/Let's Encrypt config. Streamable HTTP for MCP should be HTTPS-only in production. Needs a domain (earlier handoff noted HTTPS deferred on this).

2. **Auth token rotation policy.** Static bearer tokens never rotate. Is that acceptable, or do you want OAuth 2.1 (heavier, browser-based flow)?

3. **Laptop-MCP + remote-DB use case.** Is the intent "work from laptop, authoritative state on ionos01" (pattern E)? Or is the laptop meant to always be self-contained and ionos01 is only the public alpha?

4. **Multi-writer concern.** If both the laptop AND ionos01's MCP can write to the same DB, you have two writers. Safe only if one of them is mostly read-only, OR you accept last-write-wins. Same-machine concurrency is fine; cross-machine concurrency is the one that bites.

5. **Cosmic archive storage.** Option A (fixture in repo) uses git LFS. Is that acceptable, or do you want the snapshot somewhere else (S3 bucket, ionos01 as a nominal archive host)?

6. **Scope of the next PR.** Are we implementing all of this, or just one slice (e.g., cosmic archive only, or MCP HTTP transport only)? Each slice is 1-4 hours of work with its own tests.

---

## Recommended slicing (if implementation proceeds)

Phase 1 (1-2 hr, no breaking changes) — **cosmic archive + docs**
- scp cosmic DB to `archive/cosmic-snapshot-2026-04-17/beads.db`
- git-lfs-track or document size rationale
- Update `backfill-edges-from-cosmic.ts` default path to the archived snapshot
- Update `reference_cosmic_db_canonical_location.md` to reflect archive
- Deliverable: ionos01 is no longer a SPoF

Phase 2 (3-5 hr, additive) — **MCP Streamable HTTP transport**
- Add `MCP_TRANSPORT` env gate to `apps/silmari-mcp/src/index.ts`
- Add `StreamableHTTPServerTransport` branch with Bearer-token middleware
- Add `Bun.serve` for HTTP mode, bound to `127.0.0.1`
- Add `deploy/nginx/silmari.conf` patch for `/mcp` → `localhost:8789` TLS proxy
- Add CVE-2025-66414 mitigation (allowed hosts)
- Unit + integration tests
- Deliverable: `claude mcp add --transport http ...` works against ionos01

Phase 3 (2-4 hr, additive) — **`SILMARI_DB_HOST` split-host option**
- Wrap `execFileSync('br', ...)` in `br-adapter.ts` with optional `ssh` prefix
- Handle SSH auth (ControlMaster recommended)
- Document `SILMARI_DB_HOST` env in README + post-deploy-checklist
- Deliverable: MCP host and DB host can be on different machines

Phase 4 (optional) — **OAuth 2.1 + PKCE** if bearer-token rotation becomes needed. Defer unless there's a specific ask.

---

---

## Part 6 — Scale path: single-tenant per-user VPS model

Based on 2026-04-17 discussion. Key reframing: because the DB is behind an LLM-gated workflow, **latency is free** — the LLM itself consumes 500ms-5s per call, so a 50ms HTTPS hop is imperceptible. This validates Streamable HTTP as the transport AND relaxes the DB performance requirements (a cheap VPS's SQLite fsync is orders of magnitude faster than an LLM round-trip).

**PII posture:** users currently trust AI providers with personal content. Silmari's durable memory accumulates context (relationships, preferences, private goals) that crosses the line from "transient request" to "durable personal record." Single-tenant isolation is the appropriate trust model — no shared DB means no cross-user leak surface, no noisy-neighbor exposure, and GDPR-style right-to-erase becomes a single-command operation ("destroy the VPS").

### Sizing validation

| Workload | Typical | Per-user VPS needs |
|---|---|---|
| `br` SQLite ops | low-write, few-KB transactions | <100MB RAM headroom |
| silmari-mcp Bun process | stdio handler + MCP SDK | ~50-100MB RAM |
| nginx TLS proxy | TLS termination for 1 client | negligible |
| Viewer server (optional) | Bun HTTP + bv subprocess | ~150MB RAM |
| Headroom for bv regen (Go binary) | single-shot export, moderate CPU spike | 1 vCPU burst fine |
| **Total typical** | | **2 vCPU + 2-4 GB RAM is generous** |

Benchmark providers and price points (2026-04):

| Provider | Plan | Price | vCPU | RAM | Disk |
|---|---|---|---|---|---|
| Hetzner CX22 | €4.05/mo | 2 | 4 GB | 40 GB | EU |
| ionos VPS S | €1-4/mo | 1-2 | 1-2 GB | 10-40 GB | EU/US |
| DigitalOcean Basic | $6/mo | 1 | 1 GB | 25 GB | global |
| Vultr Cloud Compute | $6/mo | 1 | 1 GB | 32 GB | global |
| OVH VPS Starter | €3-4/mo | 1-2 | 2 GB | 40 GB | EU/CA |

Cost math at 100 users: €400-600/mo infra. At €15-30/mo user subscription, infra is 15-20% of revenue — sustainable.

### Architecture per user

```
User's laptop / Claude Code window
    │  HTTPS Streamable MCP (Bearer token)
    ▼
per-user VPS (e.g., silmari-{userid}.silmari.app)
├── nginx  (TLS termination + Bearer validation)
│       └── localhost:8789
├── silmari-mcp  (Bun, systemd-managed)
│       └── execFileSync br + local DB
├── br binary + silmari-viewer bv (rebuilt per-deploy)
└── ~/.silmari-memory/  (SQLite store, owned by silmari user)
```

### What gets centralized vs what lives in the user VPS

| Component | Location | Reasoning |
|---|---|---|
| silmari-mcp code (release artifacts) | central CDN or git tag | Users pull/rebuild on deploy |
| User's memory store | VPS only | PII; never leaves the tenant |
| Bearer token + user ID | VPS secret + user's laptop | never transits central infra |
| Cosmic archive snapshot (if Option A landed) | git LFS in main repo | historical fixture, not PII |
| Billing / user records | central (outside this system's concern) | standard SaaS backplane |
| Telemetry / crash logs | opt-in, redacted | PII implications require explicit opt-in |
| Updates / rollout orchestration | central pipeline | pushes to all user VPSes |

### Design questions the discussion hasn't resolved yet

1. **Provisioning flow.** Does a new user (a) buy a VPS themselves and follow an install doc, (b) self-serve a provision-on-signup backed by provider APIs (Hetzner/ionos have them), or (c) you manually spin up and hand credentials? Each has different infra-automation demands. Option (b) likely means a central control plane service the user registers with; that service holds provider API keys and orchestrates per-user VPS creation via Terraform/Pulumi/direct API.

2. **Update rollout.** When silmari-mcp v0.2 lands, how does it reach N user VPSes? Options: (i) cron on each VPS pulls git + restarts systemd — simple but risks mid-transaction restart, (ii) central orchestrator SSHes and runs the deploy — needs SSH key management, (iii) immutable image strategy — user destroys + recreates from new AMI/snapshot. Preference likely depends on how often silmari-mcp changes.

3. **TLS + DNS.** Per-user subdomain (`silmari-{userid}.silmari.app`) requires wildcard cert OR per-user Let's Encrypt. Alternative: IP-only + self-signed cert + token-pinning on client — works but ugly UX. Or: VPS registers with central control plane which manages DNS (Cloudflare API) and issues cert on first boot.

4. **Bearer token bootstrap.** On first VPS spin-up, how does the user get their token into `claude mcp add`? Options: (i) user-generated secret they paste into both sides, (ii) control-plane-issued token shown once during onboarding, (iii) OAuth flow triggered on first MCP connection. Option (ii) is the common SaaS pattern.

5. **Backups / DR.** Single-tenant means user data loss = user's disaster. Minimum: nightly `rsync` of `~/.silmari-memory/` to a separate backup target (S3, backup VPS, user's laptop pull). Restore runbook: spin new VPS, rsync from backup, re-register MCP. Should this be automated from day one?

6. **Cosmic archive per-user.** If Option A from Part 1 lands (cosmic snapshot as repo fixture), each new user VPS still needs to run `backfill-edges-from-cosmic.ts` once at provisioning. That either runs automatically during provisioning OR becomes a user-facing setup step. Either is fine; pick one.

7. **Multi-device access.** If one user has laptop + desktop + phone, do they all point at the same VPS? That's the "laptop-MCP + remote-DB" pattern (E from Part 4) — multiple clients, one authoritative VPS. Bearer token is shared across devices. Works naturally if the MCP is HTTPS.

8. **Shutdown / churn.** When a user cancels, what happens to their data? Grace period (90 days) before VPS destruction? Export-on-cancel? GDPR obligates deletion on request.

### Recommended scale-path phasing (pre-commitment; just thinking out loud)

**Phase 0 — current state.** Single alpha on ionos01, 1-user (you). stdio transport.

**Phase 1 — validate Streamable HTTP on ionos01.** The alpha itself becomes the first "production" remote MCP. You're user-zero. No new infra. Exercises the HTTPS + Bearer + nginx path.

**Phase 2 — second user dogfood.** Spin a second VPS (manual, scripted provisioning). Validate the full "user gets token, runs `claude mcp add --transport http`, connects successfully" loop with someone other than you. Surfaces onboarding bugs.

**Phase 3 — automation.** Convert the manual provisioning into scripts (Terraform/Pulumi module). Still manual trigger — a human runs `silmari-provision <userid> <region>`. Sufficient for ~20 users.

**Phase 4 — self-serve control plane.** Only if demand warrants. A web signup flow that calls Hetzner/ionos APIs, registers DNS, issues token, runs first-boot provisioning. This is a real product — weeks of work, not hours.

**Defer:** multi-region replication, HA primary/replica, managed-service partnerships. None of these are needed until traffic justifies them.

---

## Part 7 — Decisions synthesis (ClaudeResearcher + PerplexityResearcher 2026-04-17)

Two research agents resolved the five open scale questions. Findings below are verbatim tier-by-tier recommendations with verified 2026-04 pricing + dev-hour estimates.

### Issue 1 — Provisioning trigger

**0-10 users:** bare bash-over-ssh + cloud-init user-data pasted into Hetzner console. Dev: 4-8 hrs. Control-plane VPS: €0. One idempotent `provision.sh` invoked as `ssh root@<new-vps>`.

**10-100 users:** port the bash into a Terraform module using the official `hetznercloud/hcloud` provider (mature, partner-tier in Registry). Trigger is still `make provision USER=xxx` — you run it, not a web app. Dev: 12-20 hrs one-time. Infra: €0 (local encrypted state or €1-2/mo Hetzner Object Storage for remote state).

**100-1000 users:** thin Node/Go worker calling `hcloud` API directly, backed by Postgres job queue, triggered by billing-webhook-on-signup. Dev: 60-120 hrs honest (auth, Terraform/API, status polling, error recovery, email creds). Control-plane VPS: €4.59/mo single Hetzner CX22 is sufficient up to 1000 users. **Don't build Kubernetes.**

**Reject outright:** option (a) "user buys their own VPS" is a support nightmare above ~5 users.

**Forcing functions:** > 1 manual provision/week → tier up. Onboarding latency becoming conversion bottleneck → tier up again.

### Issue 2 — Update rollout (pinned without research)

First-principles lock-in: **0-50: systemd + git-pull cron on each VPS, 2 hrs setup.** Upgrade to Ansible SSH orchestrator at 50+ users (~8-16 hrs). Immutable-image blue/green only at 500+ (40-60 hrs, packer pipeline).

### Issue 3 — TLS+DNS (pinned without research)

**All tiers 0-1000+: Caddy + DNS-01 wildcard `*.silmari.app`.** Caddy auto-renews Let's Encrypt. One wildcard cert, renewed every 60 days by the daemon, zero code. Dev: 4 hrs setup. Infra: ~$12/year for domain. Scales indefinitely.

### Issue 4 — Bearer bootstrap

**0-10 users:** user runs `openssl rand -hex 32`, pastes into `claude mcp add --header "Authorization: Bearer <token>"` AND into VPS `.env`. Dev: 1 hr. Rotation on leak = manual SSH + regen + email.

**10-100 users:** control-plane issues token at provisioning time + "copy now, won't show again" UI + `/rotate-token` endpoint. Dev: 8-16 hrs + 4 hrs rotation. This matches what Atlassian Rovo, Linear, GitHub MCP bearer examples ship today.

**100-1000 users (or first B2B compliance ask):** OAuth 2.1 + PKCE via `oauth4webapi` library (runtime-agnostic, zero-dep, PKCE baked in). Dev: 20-30 hrs — NOT 40+ as I estimated pre-research. Outsourcing the auth server to WorkOS/Stytch/Scalekit drops it to ~10 hrs but adds ongoing cost.

**Spec reality:** MCP March 2025 spec standardized OAuth 2.1 + PKCE for **publicly-intended** remote servers, but community explicitly carves out static-Bearer for single-tenant/team deployments. Bearer remains the 2026 norm at our scale.

### Issue 5 — Backup/DR — **storage cost is NOISE at our data volume**

**Critical insight:** 20 MB/user × 1000 users = 20 GB total. Every free tier (R2 10 GB, B2 10 GB) covers most of this. **Storage $/GB differences are noise.** Complexity and PII posture drive the choice.

**0-50 users:** Hetzner Storage Box **BX11 at €3.20+VAT ≈ €3.81/mo flat** (Germany/Finland only — GDPR-favorable). Nightly cron on each user VPS: `sqlite3_rsync` (or `VACUUM INTO /tmp/snap.db`) → `restic` (client-side AES-256) → sftp to Storage Box under `/user-{id}/`. Dev: 4-6 hrs.

**50-500 users:** same BX11 up to 800 GB (= ~40,000 users of 20 MB each — you hit dev/onboarding limits long before storage). Add weekly mirror to **Cloudflare R2 EU** (~$0.30/mo for 20 GB, zero egress = free restore drills) for cross-region redundancy.

**500+ users or first compliance-audited customer:** primary moves to R2 EU with restic. BX11 becomes secondary. First DPA + fractional DPO.

**MANDATORY technical practices (not optional):**

1. **NEVER rsync a live WAL-mode SQLite file** — `sqlite.org/howtocorrupt` explicitly warns the copy may be malformed. Use `sqlite3_rsync` (SQLite 3.47+, WAL-safe, ships with sqlite3) OR `VACUUM INTO /tmp/snapshot.db` (read-lock only) before handing to restic.
2. **restic or borgbackup for encryption** — client-side AES-256 means the backup provider sees only ciphertext. **GDPR Article 32 effectively requires this** for personal notes that could contain medical/financial PII. Also: right-to-erase = `restic forget --prune`, no vendor ticket.
3. **Data residency defaults** — Hetzner BX11 (DE/FI) and R2 EU avoid GDPR transfer-impact-assessment paperwork. AWS S3 requires conscious eu-central-1/eu-west-1 selection + signed DPA.

### Restore runbook (recommended approach)

From "VPS died" to working:

| T+ | Action |
|---|---|
| 0 | `hcloud server create --type cx22 --image debian-12 --ssh-key ...` (~90s) |
| +2 min | SSH in, `curl -sSL install.silmari.app \| sh` |
| +3 min | `restic -r sftp:u123456@u123456.your-storagebox.de:/user-42 restore latest --target /root/.silmari-memory` |
| +8 min | `systemctl enable --now silmari` |
| +10 min | DNS flip (wildcard cert already covers new IP) or user updates MCP config |
| +12 min | `silmari status` returns expected card count |

**RTO: ~12 min. RPO: 24h default (nightly); drop to 1h by running cron hourly.**

---

## Part 8 — Consolidated MVP budget (all 5 issues, 0-50 users)

| Issue | MVP solution | Dev hrs | Recurring infra |
|---|---|---|---|
| 1 Provisioning | bash + cloud-init, manual trigger | 4-8 | €0 |
| 2 Update rollout | systemd + `git pull` cron | 2 | €0 |
| 3 TLS+DNS | Caddy + LE DNS-01 wildcard | 4 | ~$12/yr domain |
| 4 Bearer | user-generated `openssl rand`, paste both | 1 | €0 |
| 5 Backup/DR | `sqlite3_rsync` + `restic` → Hetzner BX11 | 4-6 | €3.81/mo (shared) |
| Cosmic archive (Part 1 Option A) | git LFS fixture | 2 | ~$0 |
| MCP HTTPS transport (Part 2 Option A) | env-gated `StreamableHTTPServerTransport` | 3-5 | €0 |
| **TOTAL** | | **20-28 hrs** | **€4/mo + €4/user** |

**Infra math:**
- 10 users: 10 × €3.79 user-VPS + €3.81 shared backup = **~€41/mo**
- 100 users: 100 × €3.79 + €3.81 = **~€382/mo**
- 1000 users: 1000 × €3.79 + €3.81 backup + €4.59 control plane + ~$20/mo R2 mirror = **~€3,813/mo**

At €15-30/user subscription:
- 100 users × €20 = €2,000/mo revenue → 19% infra
- 1000 users × €20 = €20,000/mo revenue → 19% infra

**Sustainable through 1000+ users on solo-dev effort.** Total lifetime dev investment from zero → 1000 users ≈ 120-180 hours spread across tier transitions. No team required.

### Biggest findings worth calling out

1. **Storage cost is a non-issue.** 20 GB total at 1000 users lives in free tiers; Hetzner BX11 flat-rate serves the first 40,000 users.
2. **`sqlite3_rsync` + `restic` is the mandatory technical stack** for backup — WAL corruption + GDPR encryption requirements collapse to these two tools.
3. **OAuth cost overestimated.** `oauth4webapi` library cuts 40+ hr estimate to 20-30 hr honest. Still defer until 100+ users or compliance ask.
4. **Hetzner 2026-04-01 price adjustment** — CAX11 €3.29 → €4.49; CX22 now €3.79 (cheapest x86). Budget accordingly.
5. **No Kubernetes.** At 100-1000 users, a thin Node worker + hcloud API + Postgres queue is sufficient. K8s adds 6-12 months of ops overhead you don't need.

---

## Sources

- [MCP Transports Spec 2025-03-26](https://modelcontextprotocol.io/specification/2025-03-26/basic/transports)
- [Claude Code MCP docs](https://code.claude.com/docs/en/mcp)
- [Claude Code gains remote MCP support (InfoQ, June 2025)](https://www.infoq.com/news/2025/06/anthropic-claude-remote-mcp/)
- [typescript-sdk (Streamable HTTP transport)](https://github.com/modelcontextprotocol/typescript-sdk)
- [CVE-2025-66414 DNS rebinding](https://advisories.gitlab.com/pkg/npm/@modelcontextprotocol/sdk/CVE-2025-66414/)
- [MCP OAuth authorization tutorial](https://modelcontextprotocol.io/docs/tutorials/security/authorization)
- [SQLite locking v3](https://sqlite.org/lockingv3.html)
- [SQLite on networked storage](https://docs.gotosocial.org/en/latest/advanced/sqlite-networked-storage/)
- [libSQL (Turso)](https://docs.turso.tech/libsql)
- [libsql-js](https://github.com/tursodatabase/libsql-js)
- [LiteFS](https://github.com/superfly/litefs)
- [Marmot](https://github.com/maxpert/marmot)
- [LiteFS vs Litestream vs rqlite vs dqlite on VPS (2025)](https://onidel.com/blog/sqlite-replication-vps-2025)
- [Cloudflare Remote MCP server guide](https://developers.cloudflare.com/agents/guides/remote-mcp-server/)
- [Performance testing MCP transports](https://dev.to/stacklok/performance-testing-mcp-servers-in-kubernetes-transport-choice-is-the-make-or-break-decision-for-1ffb)
- [Linear MCP docs](https://linear.app/docs/mcp)
- [Notion MCP server](https://github.com/makenotion/notion-mcp-server)

### Part 7-8 sources (scale research 2026-04-17)

- [Hetzner Terraform provider](https://registry.terraform.io/providers/hetznercloud/hcloud/latest/docs)
- [IONOS Terraform provider](https://registry.terraform.io/providers/ionos-cloud/ionoscloud/latest)
- [Hetzner 2026 price adjustment](https://docs.hetzner.com/general/infrastructure-and-availability/price-adjustment/)
- [Hetzner CX22/CAX11 pricing 2026](https://costgoat.com/pricing/hetzner)
- [Hetzner Storage Box BX11](https://www.hetzner.com/storage/storage-box/bx11/)
- [Backblaze B2 Pricing](https://www.backblaze.com/cloud-storage/pricing)
- [Cloudflare R2 Pricing](https://developers.cloudflare.com/r2/pricing/)
- [AWS S3 Pricing](https://aws.amazon.com/s3/pricing/)
- [sqlite3_rsync official docs](https://sqlite.org/rsync.html)
- [SQLite howtocorrupt (WAL copy hazards)](https://sqlite.org/howtocorrupt.html)
- [Oldmoe — SQLite backup strategies](https://oldmoe.blog/2024/04/30/backup-strategies-for-sqlite-in-production/)
- [restic encryption model](https://restic.net/blog/2018-04-01/rclone-backend/)
- [GDPR Article 32 encryption guidance](https://thecyphere.com/blog/gdpr-encryption/)
- [MCP Playground 2026 bearer guide](https://mcpplaygroundonline.com/blog/mcp-server-oauth-authentication-guide)
- [oauth4webapi (runtime-agnostic OAuth lib)](https://github.com/panva/oauth4webapi)
- [jmorrell-cloudflare bearer example](https://github.com/jmorrell-cloudflare/mcp-bearer-auth-example)
- [Atlassian Rovo MCP bearer config](https://support.atlassian.com/atlassian-rovo-mcp-server/docs/configuring-authentication-via-api-token/)
- [Stytch MCP auth guide](https://stytch.com/blog/MCP-authentication-and-authorization-guide/)
- [Northflank multi-tenant guide](https://northflank.com/blog/multi-tenant-cloud-deployment)
