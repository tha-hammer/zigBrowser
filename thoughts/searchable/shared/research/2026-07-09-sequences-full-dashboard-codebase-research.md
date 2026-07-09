---
date: 2026-07-09T22:38:32Z
researcher: SAI
git_commit: bfa378ed95c7b6c299bb904e8934ab2563b422a2
branch: master
repository: zigBrowser
cross_repo: /home/maceo/ntm_Dev/sequences
topic: "Full Dashboard Codebase Research — Automation Control + Sequences Management UI"
tags: [research, codebase, dashboard, automation, sequences, zigBrowser, recruiter-ui, design-system, database, api]
status: complete
last_updated: 2026-07-09
last_updated_by: SAI
---

# Research: Full Dashboard — Automation Control + Sequences Management UI

**Date**: 2026-07-09T22:38:32Z (PDT 15:38)
**Researcher**: SAI
**Git Commit**: bfa378ed95c7b6c299bb904e8934ab2563b422a2 (zigBrowser master)
**Cross-repo**: /home/maceo/ntm_Dev/sequences (ed21eef3)
**Repository**: zigBrowser + sequences (cross-repo)

## Research Question

Research both the zigBrowser and sequences codebases to ground the full dashboard: automation session state, per-platform daily-cap/pacing usage, live command/telemetry feed, sequence execution tracking (PRD 9.1), analytics (9.2), and entry points to sequence creation (9.3) / step authoring (9.4). Document the current state of both sides, the seams to build against, UI hosting options with tradeoffs, data the dashboard must read/write, and open questions.

## Summary

zigBrowser has a built automation API (JSON-RPC 2.0 verb router, injected automation.js, Python/Node SDKs, CLI, anti-detection/pacing, privacy-aware telemetry) but the runtime wiring is incomplete — `--automation-api` is parsed but not consumed in the actual app run path (`src/app.zig:21-29`), and no external API or database integration exists. The sequences app has a complete Express + React + PostgreSQL stack with sequence CRUD, a canonical event ledger (`sequence_events`, 13 event types), funnel metrics computation, a recruiter-ui Next.js SPA with 8 sequence UI components, and a design system (@cosmic/ds, 35 components). The dashboard must bridge these two worlds: zigBrowser hosting the UI locally and pushing/reading automation + sequence data through an exposed API (being designed by the Phase 0 agent).

---

## Detailed Findings

### A. zigBrowser Automation API Surface

#### A.1 JSON-RPC Command Verbs

The verb registry lives in `src/automation/router.zig:6-20`, defining 13 verbs across two namespaces:

| Namespace | Verb | RPC Method | Required Params | Optional Params |
|---|---|---|---|---|
| dom | dom_query | `dom.query` | `selector` | `strict`, `timeout_ms` |
| dom | dom_click | `dom.click` | `selector` | action options (`strict`, `force`, `trial`, `timeout_ms`) |
| dom | dom_fill | `dom.fill` | `selector`, `value` | action options |
| dom | dom_type | `dom.type` | `selector`, `text` | `delay_ms`, action options |
| dom | dom_get_text | `dom.getText` | `selector` | `strict` (default true) |
| dom | dom_get_attribute | `dom.getAttribute` | `selector`, `name` | `strict` (default true) |
| dom | dom_wait_for | `dom.waitFor` | `selector` | `strict`, `timeout_ms`, `state` (attached/visible/hidden/detached) |
| page | page_navigate | `page.navigate` | `url` | `timeout_ms`, `waitUntil` |
| page | page_reload | `page.reload` | — | `timeout_ms`, `waitUntil` |
| page | page_url | `page.url` | — | — |
| page | page_title | `page.title` | — | — |
| page | page_evaluate | `page.evaluate` | `expression` | — |
| page | page_screenshot | `page.screenshot` | — | `fullPage` |

Selector format: `kind=body` where kind is one of `role|testid|text|css|xpath` (enforced in `src/automation_script/automation.js:299`).

#### A.2 Transport / Framing

`src/automation_rpc.zig` implements line-based JSON-RPC 2.0 connection handling:
- Auth gate: first request must include `"auth":"<token>"` matching the connection token (`automation_rpc.zig:107-112`).
- AutomationError codes `-32001` through `-32012` (`automation_rpc.zig:14-27`): element_not_found, element_not_visible, element_not_stable, element_obscured, element_disabled, element_not_editable, navigation_timeout, navigation_failed, action_timeout, platform_rate_limited, session_invalid, cancelled.
- Max line length 64KiB (`automation_rpc.zig:5`).

`src/automation_websocket.zig` implements RFC6455 WebSocket upgrade + JSON-RPC event notifications with a bounded `SubscriberQueue` (capacity-limited FIFO, drops slow subscribers).

SDK wire format is 4-byte big-endian length prefix + UTF-8 JSON payload (distinct from the line-based format in the Zig router).

#### A.3 SDKs

**Python SDK** (`sdk/python/src/zigbrowser/client.py`):
- `ZigBrowser(socket_path, token)` — sync client with 6 namespace wrappers:
  - `DomNamespace`: click, fill, type, query, get_text, get_attribute, wait_for
  - `PageNamespace`: navigate, reload, screenshot, evaluate
  - `LinkedInNamespace`: connect, visit, message, like, comment, search, extract
  - `InstagramNamespace`: follow, like, comment, dm, story_view
  - `SocialNamespace`: login_check, rate_status, pause, set_pacing
  - `CookiesNamespace`: get_all, set, delete
- `AsyncZigBrowser` — asyncio variant.
- Event listener: `.on(event_type, callback)` with background reader thread splitting responses from notifications.

**Node SDK** (`sdk/node/src/client.ts`):
- `ZigBrowser({ socketPath })` — raw `.call(method, params)` only, no namespace wrappers.
- Single pending-promise slot (one in-flight request at a time).

**CLI** (`sdk/cli/src/zigbrowser_cli/main.py`):
- `zigbrowser-cli call METHOD [--param key=value ...]` — raw RPC call.
- `zigbrowser-cli trace TRACE_ID` — queries `telemetry.query` and prints span tree.

The LinkedIn/Instagram/Social/Cookies SDK methods call RPC method names (e.g. `linkedin.connect`) that have no corresponding entry in the Zig router's verb table — they are defined in Phase 5 plans but not yet implemented server-side.

#### A.4 Telemetry / Wide-Event System

Five telemetry emitter layers exist:

| Layer | Span Name | Source | Key Attributes |
|---|---|---|---|
| Router | `automation.command` | `src/automation/telemetry.zig:114-154` | rpc.method, rpc.namespace, page.id, window.id, selector.kind, selector.hash (Wyhash), typed.length, typed.class, target.host |
| Injected JS | `automation.selector.resolve` | `src/automation_script/automation.js:432-451` | selector.kind, selector.hash (FNV-1a), selector.match_count, dom.frame_depth |
| Injected JS | `automation.actionability.check` | `automation.js:453-475` | action.name, actionability.check, actionability.passed, actionability.failed_check |
| Stealth | `automation.behavior.simulation` | `src/automation/stealth.zig:158-196` | behavior.kind (typing/click/session), distribution dims |
| Stealth | `automation.detection.signal` | `stealth.zig:198-234` | signal.source (dom/network/session/engine), dom.signal_hash (SHA-256) |
| Stealth | `automation.stealth.assessment` | `stealth.zig:236-255` | stealth.surface, stealth.risk_level, observer.cleanup_count |
| Pacing | `automation.pacing.decision` | `src/automation/pacing.zig:82-89` | platform.name, pacing.cap_reached |
| Platform | `automation.network.*`, `automation.input.*`, `automation.platform.*`, `automation.cookie.*` | `src/automation_platform.zig:809-882` | backend, page_id, cookie_domain_hash (Wyhash) |

Privacy contract: raw selector text, typed values, URL paths/queries, and modal detection text are never stored — only hashes, lengths, or classifications. OTLP export (`src/automation_otlp.zig:68-82`) explicitly excludes `raw_token`/`raw_params`.

#### A.5 Anti-Detection & Pacing

| Feature | Source | Parameters |
|---|---|---|
| Rate limiter | `src/automation/pacing.zig:9-13` | daily_cap=100, delay 3000-8000ms uniform, midnight-local reset |
| Session simulator | `src/automation/session.zig:3-10` | warmup_ms=30000, break_interval=600000ms, break 300000-900000ms, session 3600000±600000ms |
| Bezier mouse paths | `src/automation/bezier.zig:44-87` | Fitts's-law timing, perpendicular control-point offset, overshoot_max=15px |
| Gaussian typing | `src/automation/gaussian.zig:29-51` | μ=120ms, σ=40ms, clamped [80,200ms], word-pause [300,600ms] |
| DOM rate-limit scan | `automation.js:170-193` | Modal/dialog selector scan, challenge-URL detection, FNV-1a hash of text |
| C40 non-interference | `automation.js:515-526`, `js_contract_test.zig:45-59` | No Runtime.enable, __zbAutomation non-enumerable/writable/configurable |

#### A.6 Activation Status (Critical Gap)

`src/cli.zig:9-10` parses `--automation-api` and `--automation-token-file` flags. However, `src/app.zig:21-29` (`runOpen`) does NOT reference `spec.automation_api` or `spec.automation_token_file` — it only passes `print_title` and `e2e_protocol` into `c.zb_app_run()`. The automation transport lifecycle (`src/automation_transport.zig:37-47`, `runOpenWithAutomationLifecycle`) is only exercised by unit tests with fake server/runner stand-ins. No call site in `src/main.zig` or `src/app.zig` instantiates a real UDS listener or starts an `automation_rpc.Connection` loop.

---

### B. zigBrowser UI Hosting

#### B.1 WebKitGTK Shell

`src/webkit_shim.c:1103` (`zb_app_run`) creates the GTK application:
- `WebKitWebContext` via `webkit_web_context_get_default()` (line 1122)
- `WebKitUserContentManager` (line 1128)
- `WebKitWebView` via `webkit_web_view_new_with_user_content_manager` (line 1135-1136)
- GTK window: 1024x768, no toolbar/address bar/settings UI (`specs/architecture.md:51-53`)
- Page loaded with `webkit_web_view_load_uri(main_window->view, uri)` (line 1155)

Navigation policy: `on_window_decide_policy()` (line 835-891) → `zb_policy_decide()` (`src/nav_policy.zig:40`). File:// navigation confined to a base directory; HTTP loopback navigation has no confinement policy today.

Default URL when launched bare: `https://cosmic-hr-development.up.railway.app/` (`src/cli.zig:23`) — zigBrowser already defaults to acting as a shell for a remote web app.

#### B.2 Page→Native IPC

`install_ipc_handler()` (`src/webkit_shim.c:530-548`) registers a `zbHost` script-message handler on the `WebKitUserContentManager`. The `on_ipc_message_received()` handler (line 550-608) parses JSON (`cmd`/`args`), dispatches to `zb_ipc_dispatch()` (`src/ipc.zig:41-73`), and returns a JSC value. Page-side JS calls `window.webkit.messageHandlers.zbHost.postMessage(...)`.

Current `zb_ipc_dispatch` handles only 4 commands: `ping`, `add`, `echo`, `os.info` — with a 4096-byte C-string result ceiling (identified as a prerequisite to fix in the Phase 1 plan).

#### B.3 Content Injection Status

`src/automation_script/js_embed.zig:1` embeds `automation.js` into the Zig binary via `@embedFile`, but NO call to `webkit_user_content_manager_add_script()` exists in `webkit_shim.c`. The embedded script is staged but not runtime-wired.

#### B.4 No Embedded HTTP Server

No `std.http`, libsoup-server, or microhttpd usage anywhere in `src/`. No `chrome://` or `about:` internal pages. URI validation (`src/uri.zig:12-18`) allows only `http`, `https`, `about` (pass-through), and `file`.

#### B.5 Build System

`build.zig:430-437` (`resolveBackend`): Linux → gtk_backend (webkit2gtk-4.1 + gtk+-3.0), Windows → webview2_backend, macOS → macos_backend (WKWebView shim not yet landed). Cross-platform binary from `src/main.zig`.

#### B.6 Prior Research: Local App Hosting

`thoughts/shared/research/2026-07-04-09-17-isolated-local-web-app-runtime-for-cosmic-hr04.md` researches hosting the cosmic-HR04 recruiter-UI dashboard locally with zigBrowser as the desktop shell. Key architecture: build recruiter-ui as static export → Express backend serving it → bind to 127.0.0.1 → Postgres app-privately → launch zigBrowser to the loopback origin.

Identified prerequisites not yet implemented (line 398-405):
- Build/runtime-configurable default app URL
- Browser-profile/data/cache directory configuration
- HTTP-loopback navigation policy pinning app origin
- Origin-gated host IPC
- Graceful shutdown waiting for WebKit child processes

#### B.7 UI Hosting Options (Documented Tradeoffs)

| Option | Mechanism | What Exists Today | What Must Be Built |
|---|---|---|---|
| Remote URL | zigBrowser loads a hosted web app URL | Default URL already points to Railway-hosted cosmic-HR app (`cli.zig:23`) | Dashboard pages in recruiter-ui, deployed to a host, zigBrowser configured to load them |
| Local static + Express | recruiter-ui built as static export (`output:'export'`), served by local Express, zigBrowser pointed at 127.0.0.1 | recruiter-ui already supports static export; prior research doc covers this architecture | HTTP-loopback nav policy, build-time config, browser profile dirs, local process orchestration |
| File:// with injected data | zigBrowser loads a local HTML file, data injected via zbHost IPC | IPC handler exists (`zbHost`), nav policy confines file:// navigation | Dashboard HTML bundle, data flow through IPC (4096-byte ceiling must be lifted), file:// CORS for API calls |
| Embedded HTTP server | zigBrowser itself serves dashboard pages via an internal HTTP server | Nothing — no HTTP server exists in zigBrowser | Full HTTP server in Zig, dashboard asset bundling, API proxy |

---

### C. Sequences App — Database Schema

All migrations in `/home/maceo/ntm_Dev/sequences/database/migrations/`.

#### C.1 Core Tables

| Table | Migration | Key Columns | RLS |
|---|---|---|---|
| `sequences` | 090:17-29 | id, org_id, owner_user_id, name, status (draft/pending_approval/active/archived), job_id, approved_plan JSONB (added by 100) | Two-layer (org+user) |
| `sequence_enrollments` | 090:35-76 | id, sequence_id, candidate_source, candidate_ref_id (generated), inclusion, skip_reason, status (draft/active/sent/paused/suppressed/bounced/stopped, added by 100), current_step_index, next_send_at | Two-layer (org+user) |
| `sequence_messages` | 090:97-134, extended 110:74-146 | id, sequence_id, enrollment_id, direction, subject, body, grounding_status, evidence_map JSONB, review_queue JSONB, status (draft/sent/received/failed), rendered_subject/body, provider_message_id, provider_thread_id | Two-layer (org+user) |
| `sequence_cohort_sources` | 090:79-94 | source_kind (manual/workspace_search/shortlist/nl_constraint/reverse_jd), source_ref JSONB | Two-layer (org+user) |

#### C.2 Event Ledger & Metrics

| Table | Migration | Purpose |
|---|---|---|
| `sequence_events` | 110:149-190 | Canonical event ledger. 13 event types: ContactReadinessAssessed, SequenceCreated, AudienceSelected, DraftGenerated, SequenceApproved, MessageSent, ReplySynced, BounceSynced, SuppressionApplied, EnrollmentStopped, AtsWritebackSucceeded, AtsWritebackFailed, CandidateConverted. Dedup via partial unique index on `(org_id, dedup_key)` where dedup_key NOT NULL (110:185-187). Single-layer org RLS (110:391-396). |
| `sequence_metrics_rollup` | 110:305-341 | Pre-aggregated: selected, contactable, enrolled, sends, delivered, bounces, replies, positive_replies, negative_replies, conversions + rates. Grouped by sequence/recruiter/role/campaign/source/channel. |
| `sequence_metrics_cursor` | 110:343-355 | Incremental computation watermark per sequence. |
| `sequence_benchmark_presets` | 110:357-389 | Industry benchmark reference values by metric/channel/role/seniority/geography. |

#### C.3 Infrastructure Tables

| Table | Migration | Purpose |
|---|---|---|
| `mailbox_connections` | 110:26-45 | OAuth mailbox config (gmail/microsoft). Single-layer org RLS + sequence_resolver bypass policy. |
| `send_caps` | 110:265-285 | Per-org or per-user daily send limits. Partial unique indexes enforce one cap per scope. |
| `global_suppression_entries` | 110:287-303 | Cross-tenant suppression. No org_id, no RLS. |
| `sequence_inbound_receipts` | 110:192-208 | Idempotency registry for inbound webhooks. No RLS (pre-tenant-resolution). |
| `unmatched_replies` | 110:210-227 | Unmatched inbound replies parked for review. |
| `outreach_claims` | 110:229-263 | Dedup registry preventing duplicate outreach per candidate per job. |

#### C.4 ATS/CRM Tables (120/121)

`ats_connections`, `ats_external_refs`, `ats_ingest_diagnostics`, `ats_sync_events` — full writeback/read-sync ledger for Bullhorn/Greenhouse integrations.

#### C.5 RLS Enforcement

Two patterns:
- **Two-layer** (090 tables): `app.current_org` PERMISSIVE + `app.current_user` RESTRICTIVE — both must match.
- **Single-layer** (110+ tables): `app.current_org` PERMISSIVE only.

GUCs set by `withTenantDbContext()` in `backend/database_interaction.js:417-450` — `SET LOCAL` (transaction-scoped), parameterized (`$1`), fail-closed on unset/empty.

Pre-tenant-resolution: `private.resolve_org_by_mailbox_connection` and `private.resolve_org_by_ats_connection` — SECURITY DEFINER functions with narrow column-level grants to NOLOGIN resolver roles.

---

### D. Sequences App — Backend Routes & Services

All mounted in `backend/server.js`. None are dead code.

#### D.1 Route Inventory

| Route File | Mount Path | Auth | Key Endpoints |
|---|---|---|---|
| `sequences.js` | `/api/v1/sequences` | Authenticated + tenant | `POST /` (create), `POST /:id/cohort` (add candidates), `GET /:id/cohort`, `POST /:id/finalize`, `POST /:id/draft`, `POST /draft-for-candidate`, `POST /:id/approve`, `POST /enrollments/:enrollmentId/pause` |
| `sequenceMetrics.js` | `/api/v1/sequences` | Authenticated + tenant | `GET /analytics` (grouped analytics), `GET /:id/funnel`, `GET /:id/funnel/drilldown`, `GET /:id/hygiene` |
| `sequenceContinuity.js` | `/api/v1/sequences` | Authenticated + tenant | `POST /action-context`, `GET /dashboard`, `GET /:id/metrics` |
| `sequencesWebhook.js` | `/api/v1/sequences` | Pre-auth (HMAC) | `POST /mailbox/webhook` |
| `sequencesAts.js` | `/api/v1/sequences/ats` | Authenticated + tenant | `POST /connections`, `POST /connections/complete` |

#### D.2 Key Services

**Funnel Metrics** (`backend/services/sequenceMetrics/metricsService.js`):
- `computeSequenceFunnel(events)` (line 183) — pure function computing: selected → contactable → enrolled → sends → delivered → bounces → replies → positive_replies → conversions, plus response_rate, positive_response_rate, conversion_rate, median_ttfr_seconds.
- `getSequenceAnalytics({groupBy, filters})` (line 336) — groups events by recruiter/role/campaign/source/channel, computes a funnel per group.

**Dashboard** (`backend/services/sequenceContinuity/dashboardService.js`):
- `getSequenceDashboard({jobRecId})` (line 41) — returns KPIs (activeSequences, needsApproval, enrolled, sent, replied, bounced, converted, syncFailures) + sequence rows + replies + sync issues.

**Action Context** (`backend/services/sequenceContinuity/actionContextService.js`):
- `resolveResultActionContext(input)` (line 258) — per-candidate action gate: derives contactStatus, lastOutreachState, replyState, approvalState, availableActions, disabledReasons.

**Canonical Event Writer** (`backend/services/sequenceEvents/eventService.js`):
- `appendSequenceEvent(input)` (line 25) — validates event type, upserts into `sequence_events` with `ON CONFLICT (org_id, dedup_key) DO NOTHING`.

**Observability** (`backend/observability/sequenceSpans.js`):
- `withSequenceSpan(name, attributes, work)` (line 98) — wraps all sequence operations with spans carrying dual-key attributes (e.g. `sequenceId` → `sequence.id` + `sequence_id`), auto-fills org/user from tenant context.

---

### E. Sequences App — Frontend (recruiter-ui)

#### E.1 Framework & Architecture

- Next.js 16 + React 19 (`recruiter-ui/package.json`)
- Metronic layout-31 chrome (`recruiter-ui/components/layouts/layout-31/`)
- Clerk auth (`@clerk/react`), TanStack Query
- Static export in prod: `next.config.mjs` sets `output: 'export'` + `trailingSlash: true` in production; dev uses rewrites proxy to `BACKEND_URL`
- Route groups: `(auth)`, `(guest)`, `(recruiter)`

Sequences pages:
- `recruiter-ui/app/(recruiter)/sequences/page.jsx` — top-level sequences route
- `recruiter-ui/app/(recruiter)/projects/[jobRecId]/sequences/page.jsx` — project-scoped sequences

#### E.2 Sequence UI Components

All under `recruiter-ui/components/recruiter/sequences/`:

| File | Purpose |
|---|---|
| `sequence-dashboard-view.jsx` | Data wrapper with `useSequenceDashboard` hook |
| `sequence-dashboard.jsx` | KPI tiles + sequences table + reply queue + sync health sections |
| `sequence-composer-sheet.jsx` | 5-tab draft/send sheet (Message/Candidates/Evidence/Schedule/Review) |
| `candidate-timeline-sheet.jsx` | Filterable event timeline |
| `candidate-sequence-action-bar.jsx` | Action buttons gated by `context.availableActions` |
| `sequence-status-badge.jsx` | Status → badge rendering |
| `contact-readiness-badge.jsx` | Contact readiness → badge rendering |
| `status-map.js` | Status → label/tone metadata |

#### E.3 API Client

`recruiter-ui/services/sequences-api.js` — all sequence reads/writes via `apiFetch` (Clerk bearer token attached). Exports:
- `fetchSequenceActionContext()`
- `fetchSequenceDashboard(jobRecId)`
- `fetchCandidateTimeline(candidateId)`
- `adaptDraftMessage(message)` — transforms backend row to composer shape
- Draft generation, approve, pause functions

#### E.4 Design System (@cosmic/ds)

35 components in `design-system/components/`: Accordion, AIResponseContent, AIResponseQuestions, Alert, Avatar, Badge, Breadcrumbs, Button, ButtonIcon, Card, ChatBubble, Checkbox, Divider, EmptyState, Icon, Input, Menu, Modal, Pagination, Pill, PillStatus, Popover, ProgressBar, PromptInput, Radio, SegmentedControl, Select, Stepper, Switch, Table, Tabs, Tag, TextArea, Toast, Tooltip.

DS gaps documented in PRD 9.2: no chart component, no StatTile/MetricCard, no DataGrid, no Dialog/Sheet, no Skeleton, no date-range/calendar atom.

#### E.5 Charting

Both `apexcharts@4.7.0` + `react-apexcharts@1.7.0` and `recharts@2.15.1` are declared as dependencies. Only recharts is currently imported (via `components/ui/chart.jsx`, a shadcn-style wrapper). ApexCharts is not wired into any React component. PRD 9.2 specifies ApexCharts as the Metronic-native choice for the Outreach dashboard charts, loaded via `next/dynamic({ ssr: false })`.

#### E.6 Component Library Split

Two component sources coexist: local `@/components/ui/*` (shadcn/Metronic style, heavily used) and `@cosmic/ds` (mandated DS). Current sequence UI mostly uses local components; new wizard work (PRD 9.3) should use `@cosmic/ds` per the PRD.

---

### F. Phase Plans (zigBrowser Automation)

Four phase plans in `thoughts/shared/plans/`:

| Phase | File | Scope | Dependencies |
|---|---|---|---|
| Phase 1 | `2026-07-09-phase1-core-automation-engine-tdd-plan.md` | Injected JS (Layer 1) + Zig engine (Layer 2). Fixes 4096-byte IPC ceiling. 13 dom.*/page.* verbs. TelemetrySink. | None |
| Phase 2/3 | `2026-07-09-phase2-3-external-api-platform-input-tdd-plan.md` | JSON-RPC 2.0 over AF_UNIX (no TCP). Token auth. WebSocket events. Platform input dispatch. | Phase 1 |
| Phase 4 | `2026-07-09-phase4-anti-detection-pacing-tdd-plan.md` | Gaussian typing, Bezier mouse, rate limiter, session simulator, DOM detection. | Phase 3 |
| Phase 5 | `2026-07-09-phase5-sdks-social-contracts-tdd-plan.md` | Python/Node SDKs, CLI, LinkedIn (7 actions), Instagram (5 actions), social.* base commands. | Phase 2 + Phase 4 |

No phase plan covers dashboard UI hosting, database integration, or an exposed API for external apps. No contract for zigBrowser communicating with a database exists in the corpus.

---

### G. Data the Dashboard Must Read/Write

Based on the PRDs (9.1-9.4) and the existing data model:

#### G.1 Dashboard Reads (from sequences PostgreSQL)

| Data | Source Table/Service | API Endpoint | PRD |
|---|---|---|---|
| Sequence list + status | `sequences` | `GET /dashboard` (dashboardService) | 9.3 (S1) |
| KPI tiles (active, enrolled, sent, replied, bounced, converted) | `sequence_events` → `computeSequenceMetrics` | `GET /dashboard` | 9.2 |
| Funnel metrics (selected → contactable → enrolled → sends → delivered → bounces → replies → conversions) | `sequence_events` → `computeSequenceFunnel` | `GET /:id/funnel` | 9.2 |
| Grouped analytics (by recruiter/role/campaign/source/channel) | `sequence_events` → `getSequenceAnalytics` | `GET /analytics` | 9.2 |
| Funnel drilldown | `sequence_events` | `GET /:id/funnel/drilldown` | 9.2 |
| Per-candidate action context | enrollments + events + contacts + suppressions + mailbox health | `POST /action-context` | 9.3, 9.4 |
| Candidate timeline | `sequence_events` joined with messages | `GET /candidates/:id/touchpoints` | 9.1 |
| Cohort summary | `sequence_enrollments` | `GET /:id/cohort` | 9.3 |
| Send caps / daily limits | `send_caps` | No existing endpoint | Dashboard automation pacing |
| Benchmark presets | `sequence_benchmark_presets` | No existing endpoint | 9.2 |
| Open/click/delivery tracking | `sequence_events` (MessageOpened, LinkClicked, MessageDelivered — NEW event types per PRD 9.1) | No existing endpoint | 9.1, 9.2 |

#### G.2 Dashboard Writes (to sequences PostgreSQL)

| Action | Target | API Endpoint | PRD |
|---|---|---|---|
| Create sequence | `sequences` (status='draft') | `POST /` | 9.3 |
| Add cohort candidates | `sequence_enrollments` | `POST /:id/cohort` | 9.3 |
| Finalize cohort | `sequence_events` (AudienceSelected) | `POST /:id/finalize` | 9.3 |
| Generate draft | `sequence_messages` | `POST /:id/draft`, `POST /draft-for-candidate` | 9.3, 9.4 |
| Approve sequence | `sequences` (approved_plan, approved_at) | `POST /:id/approve` | 9.3 |
| Pause enrollment | `sequence_enrollments` (status='paused') | `POST /enrollments/:enrollmentId/pause` | 9.1 |
| Label reply interest | `sequence_events.payload.reply_classification` | No existing endpoint | 9.1 |

#### G.3 Automation-Specific Data (zigBrowser → dashboard)

This data originates in zigBrowser's automation subsystem and has no existing path to the sequences DB:

| Data | Source in zigBrowser | Dashboard Use |
|---|---|---|
| Active automation session state | `src/automation/session.zig` (SessionSimulator) | Live session status indicator |
| Per-platform daily cap / remaining actions | `src/automation/pacing.zig` (RateLimiter) | Pacing usage gauge |
| Live command feed | `automation.command` telemetry spans | Real-time command/telemetry feed |
| Detection signals | `automation.detection.signal` spans | Detection alert indicators |
| Behavior simulation stats | `automation.behavior.simulation` spans | Typing/click/session activity feed |

---

### H. Seams to Build Against

#### H.1 The Shared Seam: Exposed API (Phase 0 Agent)

No exposed API exists today for zigBrowser to communicate with the sequences PostgreSQL database. The Phase 0 agent is designing this contract. The dashboard's requirements for that API are documented in sections G.1-G.3 above.

#### H.2 zigBrowser → Sequences DB

Current state: zero integration. The automation telemetry (`InMemoryTelemetrySink`) stores spans in memory only. OTLP export (`src/automation_otlp.zig`) can push to an HTTP endpoint but is not wired to any database writer. The pacing state (`RateLimiter`) is in-process memory with no persistence.

#### H.3 Sequences Backend → Dashboard API

The existing Express routes already serve most of the read data the dashboard needs (`GET /analytics`, `GET /dashboard`, `GET /:id/funnel`, etc.). Gaps:
- No endpoint for send_caps / pacing configuration
- No endpoint for benchmark presets
- No endpoint for the new PRD 9.1 event types (MessageOpened, LinkClicked, MessageDelivered — these event types are not yet in the `sequence_events_event_type_chk` CHECK constraint at `110:166-167`)
- No endpoint for reply interest labeling
- `GET /analytics` filter support is limited — `listSequenceEventsForAnalytics` (`sequences_db.js:85`) only filters by `sequenceId`; project/recruiter/inbox/date-range filters pass through but are not applied at the SQL layer

#### H.4 recruiter-ui → Dashboard Components

Existing sequence UI components (`sequence-dashboard.jsx`, etc.) render KPI tiles and tables but:
- No chart components are currently rendered in the sequences dashboard
- ApexCharts is installed but not imported anywhere
- The `useSequenceDashboard` hook in `sequence-dashboard-view.jsx` fetches from `GET /dashboard` — this hook is the integration point for the analytics dashboard
- PRD 9.2 specifies ApexCharts with `dynamic(() => import('react-apexcharts'), { ssr: false })` for SSR-safe loading

---

## Code References

### zigBrowser
- `src/cli.zig:9-10` — automation_api and automation_token_file flags
- `src/cli.zig:23` — default URL (cosmic-hr-development Railway app)
- `src/app.zig:21-29` — runOpen (does NOT consume automation flags)
- `src/webkit_shim.c:1103` — zb_app_run entry point
- `src/webkit_shim.c:530-548` — zbHost IPC handler registration
- `src/ipc.zig:41-73` — zb_ipc_dispatch (4 commands: ping/add/echo/os.info)
- `src/automation/router.zig:6-20` — Verb enum (13 verbs)
- `src/automation/router.zig:82-136` — verb parameter parsing
- `src/automation_rpc.zig:14-27` — AutomationError enum (12 variants)
- `src/automation_rpc.zig:60-123` — JSON-RPC connection handling
- `src/automation/telemetry.zig:114-154` — recordRootCommand span
- `src/automation/pacing.zig:9-13` — PacingConfig defaults
- `src/automation/session.zig:3-10` — SessionConfig defaults
- `src/automation_script/automation.js:1-527` — injected page script
- `src/automation_script/js_embed.zig:1` — @embedFile("automation.js")
- `src/automation_transport.zig:37-47` — runOpenWithAutomationLifecycle
- `src/automation_websocket.zig:9-99` — WebSocket + SubscriberQueue
- `src/automation_otlp.zig:68-82` — redacted OTLP export
- `src/nav_policy.zig:24-38` — navigation confinement (file:// only)
- `build.zig:430-437` — platform backend selection

### sequences
- `database/migrations/090_sequences_foundation.sql:17-165` — base tables + two-layer RLS
- `database/migrations/100_send_pipeline_state.sql` — enrollment status/scheduling columns
- `database/migrations/110_sequences_engine.sql:149-190` — sequence_events ledger
- `database/migrations/110_sequences_engine.sql:265-285` — send_caps
- `database/migrations/110_sequences_engine.sql:305-341` — sequence_metrics_rollup
- `database/migrations/120_sequences_ats_crm.sql` — ATS integration tables
- `backend/database_interaction.js:417-450` — withTenantDbContext (RLS GUC setter)
- `backend/routes/sequences.js` — sequence CRUD routes
- `backend/routes/sequenceMetrics.js` — analytics/funnel routes
- `backend/routes/sequenceContinuity.js` — dashboard/action-context routes
- `backend/routes/sequencesWebhook.js` — mailbox webhook handler
- `backend/routes/sequencesAts.js` — ATS connection routes
- `backend/services/sequenceMetrics/metricsService.js:183` — computeSequenceFunnel
- `backend/services/sequenceContinuity/dashboardService.js:41` — getSequenceDashboard
- `backend/services/sequenceContinuity/actionContextService.js:258` — resolveResultActionContext
- `backend/services/sequenceEvents/eventService.js:25` — appendSequenceEvent
- `backend/observability/sequenceSpans.js:98` — withSequenceSpan wrapper
- `recruiter-ui/services/sequences-api.js` — frontend API client
- `recruiter-ui/components/recruiter/sequences/sequence-dashboard.jsx` — dashboard UI
- `recruiter-ui/components/recruiter/sequences/sequence-composer-sheet.jsx` — draft composer
- `recruiter-ui/app/(recruiter)/sequences/page.jsx` — sequences route

---

## Architecture Documentation

### Current Integration Points

```
zigBrowser (Zig/C)                    sequences (Node/React/Postgres)
─────────────────                     ──────────────────────────────
src/automation/router.zig             backend/routes/sequences.js
  └─ 13 dom.*/page.* verbs             └─ POST /api/v1/sequences (CRUD)
src/automation_rpc.zig                backend/routes/sequenceMetrics.js
  └─ JSON-RPC 2.0 over UDS             └─ GET /analytics, /funnel, /drilldown
src/automation/pacing.zig             backend/routes/sequenceContinuity.js
  └─ RateLimiter (in-memory)            └─ GET /dashboard, POST /action-context
src/automation/telemetry.zig          backend/services/sequenceEvents/eventService.js
  └─ InMemoryTelemetrySink              └─ appendSequenceEvent (canonical writer)
src/automation_otlp.zig               database/migrations/110:149-190
  └─ OTLP export (HTTP, optional)       └─ sequence_events (13 event types)

          ┌──── NO CONNECTION EXISTS ────┐
          │                              │
          │  Phase 0 Agent designs the   │
          │  exposed API + DB bridge     │
          │                              │
          └──────────────────────────────┘

recruiter-ui (Next.js/React)
────────────────────────────
app/(recruiter)/sequences/page.jsx
  └─ sequence-dashboard-view.jsx → useSequenceDashboard
      └─ sequence-dashboard.jsx (KPI tiles, table, replies, sync)
services/sequences-api.js
  └─ apiFetch → /api/v1/sequences/* (Clerk bearer)
design-system/components/ (35 @cosmic/ds components)
  └─ No chart component (ApexCharts installed but not wired)
```

### Authentication Flow

recruiter-ui: ClerkProvider → `useApi()` hook → `apiFetch()` attaches Bearer token (guest-token-first, then Clerk) → Express `authenticate` middleware → `tenantContextMiddleware` → `withTenantDbContext()` sets `app.current_org`/`app.current_user` via `SET LOCAL`.

zigBrowser: no auth integration with sequences exists. The automation API uses its own token-file auth (`--automation-token-file`), separate from Clerk.

---

## Historical Context (from thoughts/)

- `thoughts/shared/research/2026-07-04-09-17-isolated-local-web-app-runtime-for-cosmic-hr04.md` — researches packaging cosmic-HR04 recruiter-UI for local hosting via zigBrowser. Lists prerequisites: configurable default URL, browser profile dirs, HTTP-loopback nav policy, origin-gated IPC.
- `thoughts/shared/plans/2026-07-04-12-50-tdd-build-time-json-config.md` — TDD plan for build-time JSON config (prerequisite for replacing the hardcoded Railway URL).
- `thoughts/shared/research/2026-07-09-14-40-codebase-automation-api-seams.md` — as-of-today inventory of automation seams: IPC dispatch table, C ABI, zbHost JS bridge, no isolated worlds anywhere.
- `thoughts/shared/research/2026-07-09-browser-automation-api-contracts.md` — 3-layer architecture research behind the automation API PRD.
- `thoughts/shared/prd/2026-07-09-browser-automation-api.md` — master automation API PRD (12 DDD bounded contexts BC1-BC12).

---

## Related Research

- `thoughts/shared/research/2026-07-04-09-17-isolated-local-web-app-runtime-for-cosmic-hr04.md` — closest existing research to "dashboard hosting"
- `thoughts/shared/research/2026-07-09-browser-automation-api-contracts.md` — automation API design research
- `thoughts/shared/research/2026-07-09-14-40-codebase-automation-api-seams.md` — automation seams inventory

---

## Workflow Closure Map

This research covers the structural topology of two codebases and their seams — it documents "where/what is X" across both repos, not a single input → effect → observable behavior chain. The dashboard itself does not yet exist as a behavior; it is a planned UI that will compose existing behaviors (sequence CRUD, event ledger writes, metrics computation, automation telemetry). No single production trigger → source-of-truth write → observable result chain can be mapped because the integration layer (Phase 0) connecting these two codebases does not exist yet.

When the Phase 0 exposed API is designed and implemented, individual behaviors within that integration (e.g., "automation session writes pacing data → sequences DB → dashboard reads and renders pacing gauge") will become mappable chains. Until then, the documented seams (sections G and H) define the boundary conditions for those future chains.

> No closure adapter — no trigger→observe behavior chain exists across these codebases today.

---

## Open Questions

1. **Phase 0 API Contract**: The exposed API connecting zigBrowser to the sequences PostgreSQL DB is being designed by the Phase 0 agent. What transport will it use (HTTP REST, gRPC, direct Postgres connection from Zig, message queue)? This determines the dashboard's data flow architecture.

2. **Authentication Bridge**: zigBrowser's automation API uses token-file auth; sequences uses Clerk OAuth. How will the dashboard authenticate to the sequences backend? Will zigBrowser proxy Clerk tokens, or will a separate auth mechanism be needed?

3. **New Event Types**: PRD 9.1 defines three new event types (MessageOpened, LinkClicked, MessageDelivered) not yet in the `sequence_events_event_type_chk` CHECK constraint. A migration is needed before the dashboard can read/write these events.

4. **Analytics Filter Gap**: `getSequenceAnalytics` in `metricsService.js:336` accepts groupBy/filters, but the underlying `listSequenceEventsForAnalytics` (`sequences_db.js:85`) only applies `sequenceId` at the SQL layer. PRD 9.2 requires filtering by sequence, project, started-by, inboxes, date-range, and grouped-by (days/weeks/months) — the SQL query needs extension.

5. **Automation Wiring**: `src/app.zig:21-29` (`runOpen`) does not consume `--automation-api` or `--automation-token-file`. The automation transport lifecycle (`automation_transport.zig:37-47`) is only exercised by unit tests. This must be wired before the dashboard can read automation state.

6. **UI Hosting Decision**: Which of the four hosting options (remote URL, local static+Express, file:// with IPC, embedded HTTP server) will be used? The prior research doc (`2026-07-04-09-17-isolated-local-web-app-runtime-for-cosmic-hr04.md`) favors local static+Express but lists multiple unimplemented prerequisites.

7. **Dashboard vs. recruiter-ui**: Will the dashboard be new pages within the existing recruiter-ui SPA (sharing its auth, routing, and design system), or a separate standalone app? Existing sequence components live in recruiter-ui with full Clerk integration.

8. **Pacing/Session Persistence**: The RateLimiter and SessionSimulator are in-memory only. For the dashboard to show pacing usage across sessions, this state must be persisted somewhere — either in the sequences DB via the Phase 0 API or in a local zigBrowser store.

9. **Real-time Command Feed**: PRD scope includes a live command/telemetry feed. The automation WebSocket (`automation_websocket.zig`) supports event push via `SubscriberQueue`, but this is a different protocol layer than the dashboard's data source. How will live telemetry flow to the dashboard UI?

10. **processInboundMailboxEvent Stub**: `sequencesWebhook.js:34` defaults `processInboundMailboxEvent` to a stub that throws. Server.js does NOT override it. Any actually-resolved-org mailbox webhook will fail at step 5. This affects the reply/bounce capture pipeline that PRD 9.1 depends on.
