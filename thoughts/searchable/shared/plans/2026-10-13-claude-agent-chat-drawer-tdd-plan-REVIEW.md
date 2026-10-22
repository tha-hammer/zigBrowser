---
date: 2026-10-22
reviewer: JadeBeacon (independent; NOT the plan author)
plan: thoughts/searchable/shared/plans/2026-10-13-claude-agent-chat-drawer-tdd-plan.md
plan_author: cc_1 (BlackRobin)
plan_status_at_review: Rev 16.20.58 (S8 decision-16 part 5 red)
bd_issue: zigBrowser-4pa.3
worktree_head: c07899f
baseline: b4c23a1a56deced7b3ab7c8a34a660b22ffca622
change_since_baseline: 690 files, 181,613 insertions, 2080 commits since 2026-10-10
---

# Plan Review Report: Claude Agent chat drawer TDD plan

## Context and method

This is the independent `review_plan` pass the pipeline requires (research → tdd plan →
**review_plan in a different context by a non-author** → enhance_plan_with_review → /clear
+ implement_plan). It was skipped: the plan was implemented through roughly slice **S8**
(~181k lines across 690 files, 2080 commits) with only the embedded inline reviewer
(RoseCat), never an independent review, until now.

Method: the full 3,511-line plan was read, and its factual claims were checked against the
committed code in this worktree by three read-only verification agents (drawer S1/S2; the
P0 Python helper; and an S3–S10 "built vs not-built" drift map). No product code, tests, or
builds were touched (freeze zigBrowser-4pa.1).

**Headline:** The plan is **architecturally excellent** and, where built, **faithfully
implemented**. On the seven review dimensions it is near-exemplary: it has no dimension-level
design hole of the kind this review exists to catch (no illegal-state data model, no
unregistered consumer, no read-model-seeding closure test, no placeholder Red step, no
blank Property on a real-domain behavior). The findings below are therefore **not** fatal
design gaps; they are (a) a stale/inaccurate "current state" that makes the plan an
unreliable baseline for the downstream pipeline steps, (b) two acknowledged-but-unmitigated
residual risks, and (c) a scope boundary the built code has crossed.

## Review Summary

| Category | Status | Issues |
|----------|--------|--------|
| Contracts | ✅ | 0 critical, 1 note |
| Interfaces | ✅ | 0 critical, 2 notes |
| Promises | ⚠️ | 1 critical (memory bound) |
| Data Models | ⚠️ | 1 warning (two-field invariant) |
| APIs | ✅ | 0 |
| Workflow Closure | ✅ | 0 (exemplary) |
| Test-Spec Quality | ✅ | 0 (exemplary) |
| **Plan integrity / process** | ❌ | 1 critical (stale baseline) + scope divergence |

**Approval status: Needs Minor Revision.** The architecture is sound and largely built; no
critical design change is required. But before `enhance_plan_with_review` (zigBrowser-4pa.8)
and `validate_plan` (zigBrowser-4pa.13) proceed, the current-state section must be refreshed
and the residual risks tracked.

---

## Code-vs-plan fidelity (the orchestrator's key question)

The concern was that ~167k lines were built without a plan review. The verification found the
**design is tracked faithfully**, which lowers the risk considerably:

- Core/socket split present at the exact named seams: `startCore()` (automation_server.zig:172),
  `startSocket()` (:202), `callInProcess()` (:377), `dispatchParsed()` (:509).
- Frame validator (`agent_protocol.zig`, 524 LOC) enforces per-type schemas with unknown-field
  rejection, strictly-increasing `seq`, session→window binding, and the exact reject-reason
  enum the plan specifies, including S5d's `prompt`.
- Broker (`agent_broker.zig`, 914 LOC): fixed read-tool allowlist, model-supplied `window_id`
  rejection, approvals/gated verbs, one worker thread per session.
- Secrets (libsecret via `dlopen`), auth/login + netd, `--agent-setup`/provision all present.
- P0 oracle (`agent/host/tests/exec_tracer.py`) and `p0_census.json` (pins `cli_version`
  2.1.294, `cli_children` = `$CLI rg`, `/usr/bin/dash`, `/usr/bin/git`) present as specified.

**Only genuinely-absent S3–S10 component:** the six `fs_*` MCP file tools (S10). This is
expected — implementation has reached ~S8, and S10 has not landed. (`agent/host/.../files.py`
exists but is an atomic-write/rmtree utility, not the model-facing tools.)

---

## Contract Review ✅

Well-defined: input/output and error contracts are unusually complete. Error codes are
enumerated (-32001..-32015), `-32015 expectation_mismatch` is non-retryable with "nothing
sent / partial reported exactly", the fd-3 token handoff is a precise byte contract
(≤513 bytes, newline passed unchanged), and redaction is specified at every reply boundary.
Boundary values are parsed into precise types once (the NDJSON validator; the token regex
`^sk-ant-oat01-[A-Za-z0-9_-]{22,499}$`), not re-validated downstream.

- Note (not blocking): the plan (R2-2 / §3c.1) states a legacy `"route":"R3"` or
  `--agent-token-route env` "refuses with exit 2". In code this appears only as a setup test
  asserting the `--route` arg is **absent** (`agent_setup.zig:216`), not as an active
  refusal-with-exit-2 guard. Either implement the stated refusal or soften the plan wording.

## Interface Review ✅

Public interfaces (NDJSON frame types, the `DRAWER`/`SECRETS`/`AUTH` row schemas, the MCP tool
set, the broker API) are complete, consistent, and follow existing patterns
(`media_config`/`render_config`, `pacing_store`). Two notes:

- §2.0 claims `agent_drawer.zig`'s C exports are "@exported on Linux only"; the code gates them
  on Linux **or** Windows **or** macOS (agent_drawer.zig:603), deliberately widened for cross
  compile. Stale.
- The plan names `agent-host-unit` and `agent-host-contract` as gate steps; in `build.zig` they
  are internal commands folded into the generic `test` step, not standalone step labels.

## Promise Review ⚠️ — 1 critical

Behavioral, async, and resource promises are strong: delta coalescing (50 ms), bounded queues
(256 frames / 1 MiB), pipe backpressure, per-bubble/per-conversation caps, overflow interrupt,
Stop-flush, and a PID-namespace teardown proven by `/proc` membership rather than harness
cleanup. Cancellation lands at the next step boundary with one mapped outcome.

- **CRITICAL (resource promise):** the helper sandbox has **no memory bound**. The plan itself
  records (§5, SX-memlimit) that an orphaned CLI reached **10.5 GB** in S5c tests, and that
  "nothing enforces it"; the only current bound is the drawer-view overflow interrupt (10 s
  after 256 KiB), which bounds the *view*, not the CLI's RSS. A server that streams without end
  can exhaust the user's own machine's memory. The fix (a cgroup/`RLIMIT_AS` bound) is deferred
  to an unapproved follow-up slice. Filed as **zigBrowser-4pa.16**.

## Data Model Review ⚠️ — 1 warning

Sum types are used well where it counts: frames are a tag union keyed on `type`; the agent
status is an enum (`stopped|starting|ready|busy|exited|crashed`); the approval outcome is a
single terminal `approvalend ∈ {denied|expired|closed|crashed|revoked|done|changed|partial|
failed|unknown}`; the S5d active-prompt state is a single-source-of-truth lifecycle. `load_serial`
is a single derived counter. No illegal-state-expressible model was found.

- **Warning:** the guarded-type error counts model (rev 16.20.51, plan L3167–3169) uses two
  independently-varying fields `data.sent` (exact) and `data.sent_at_least` (lower bound) with a
  hand-enforced "never both" rule, carried through the SDK unchanged. This is exactly the
  "two fields that are not actually independent" smell; a sum type (`Sent{exact:n} | AtLeast{n}`)
  would make "never both" unrepresentable rather than defended at each site. It is implemented
  and tested (`automation_guard_chunks2/3_test.zig`), so this is a recommended simplification,
  not a blocker.

## API Review ✅

The socket API change is additive and bounded (the internal `startCore`/`startSocket` split
plus the new `load_serial` field in `page.list`/`page.health`). The agent surface is never
routable from the socket (`dispatchParsed` has no `agent.*`/`drawer.*`/`secrets.*`), and the
broker is not a route. Tool registration is data-driven and gated per slice (read-only at S7,
act-on-page only at S8, `fs_*` at S10). `fs_move`/`fs_delete` are explicitly never registered.

## Workflow Closure Review ✅ (exemplary)

ClosureMaps A, B and the six new chains (C–L) are derived with file:line evidence, labelled
async edges and registration boundaries, and `highest_new_connector` is identified
(`callInProcess`/`dispatchParsed`). Every new chain is classified **BLOCKING** with a reason;
closure tests trigger at or above the production entrypoint (X input), observe through the
production read path (`DRAWER`/`SECRETS` rows, the fake API's recorded requests, socket
`page.list`), name the connector to disable for red-at-seam, and explicitly avoid seeding
read models. The gate fails closed when the venv is missing and treats SKIP as UNCLOSED; an
`agent-no-orphans` step scans `/proc` after the whole gate. No closure finding.

## Test-Spec-Quality Review ✅ (exemplary)

Given/When/Then are concrete and falsifiable; Edge Cases are domain-specific (symlink/FIFO/device
swaps, boundary token lengths, exhaustion at 2^53−1, mid-action handler races). Every
real-input-domain behavior names a Property (Oracle/Invariant) with a concrete Domain and runs
it through the production path (S1.1, S1.3, S1.4, S4.1, S6.2, S7.1, S7.5, S8.3, S8.6, S10.0/1/4,
S7.0.1); every blank Property carries an explicit reasoned skip ("input is fixed"). Red steps
are real assertions with named mutants (e.g. S5d: a validator without the id check, and one that
clears the active prompt on `interrupt`). No placeholder tests found.

---

## Critical / tracked issues (filed as bd under epic zigBrowser-4pa)

1. **zigBrowser-4pa.15 [Critical / plan integrity]** — "Current state" (§2.0) and "Tracking"
   (§12) are stale and partly inaccurate, so the plan is an unreliable baseline for
   enhance_plan_with_review and validate_plan. §2.0 says "Not built: everything from S3 on" while
   9/10 S3–S10 components are committed; §12 says beads writes are blocked (they are not).
   Minor factual errors: "Linux-only" C exports are tri-platform; uv.lock pins the SDK (0.2.165)
   not the bundled CLI (CLI version lives only in p0_census.json); `agent-host-unit`/`-contract`
   are not standalone gate-step labels; the stated R3 "refuses with exit 2" is only a
   test-asserted absence.
   - Impact: the enhance pass and the code-validation pass start from a baseline that misstates
     what exists and what is pinned where.
   - Fix: refresh §2.0 to the current HEAD, correct §12, and fix the four factual items.

2. **zigBrowser-4pa.16 [Critical / resource promise]** — unbounded sandbox memory; observed
   10.5 GB orphaned CLI; SX-memlimit deferred and unapproved. (See Promises.)
   - Impact: availability risk on the user's own machine from an endless stream.
   - Fix: approve and schedule a hard memory bound (cgroup limit via the launch, or `RLIMIT_AS`),
     with its own red, before relying on the drawer for long/untrusted sessions.

3. **zigBrowser-4pa.17 [High / security residual]** — SX-standin deferred: the real OAuth token
   is resident in the CLI, and S5.7's after-each-reply transcript scrub is the sole protection
   against a server echoing it into a stored transcript (threat T6).
   - Impact: a gap in credential non-disclosure if the scrub misses a path.
   - Fix: track the SX-standin slice (netd-terminated TLS + placeholder token) and keep S5.7's
     scrub coverage audited until it lands.

4. **zigBrowser-4pa.18 [Medium / scope]** — §5 "What we are NOT doing" explicitly excludes the
   macOS and Windows drawers, but substantial macOS (MS1–MS8: `wkwebview_shim.m` drawer wiring,
   `agent_secrets_window_mac.h`, Keychain `zb_keychain_lookup`, the MS8 chat chain) and Windows
   (WS0–WS7: `webview2_shim.cpp`, `agent_secrets_win.cpp`, `wincontain.py`) drawer work is built.
   - Impact: reviewing *this* plan does not review that work; a drawer feature could be orphaned
     from any plan review.
   - Fix: confirm the macOS/Windows drawer, Secrets window, and chat chain are covered by the
     macOS launch-plan review (zigBrowser-4pa.2) and the Windows launch-plan review
     (zigBrowser-4pa.4); if not, scope them in.

## Non-blocking notes

- Data-model simplification: fold `data.sent`/`data.sent_at_least` into one sum type (warning above).
- Housekeeping: a stray `src/agent_run_ledger.zig.tmp.3979650.4beaa899dd3d` sits untracked next to
  `agent_run_ledger.zig` (in `git status`, not committed) — sweep it.
- Process observation: the plan reached rev **16.20.58** (50+ in-place revisions). The document is
  rigorous but its depth makes it hard to read as a single artifact; the enhance pass is a good
  moment to consolidate the superseded-history tables (§3b's R2–R16 rows) into an appendix.

## Suggested plan amendments

```diff
# §2.0 Current state
~ Replace "Not built: everything from S3 on" with the true HEAD state: P0–S8 built;
  S9/S10 and the fs_* MCP file tools remain; Linux + Windows + macOS exports.
~ Fix: uv.lock pins claude-agent-sdk 0.2.165 (CLI 2.1.294 is pinned in p0_census.json, not uv.lock).
~ Fix: agent-host-unit/agent-host-contract run under `zig build test`, not as named step labels.

# §12 Tracking
~ Beads is writable; this epic (zigBrowser-4pa) and its children now exist.

# §5 / scope
+ Note that macOS (MS*) and Windows (WS*) drawer work is in flight under separate launch plans
  (zigBrowser-4pa.2, zigBrowser-4pa.4), and cross-reference them.

# Promises (D7) / §5 SX-memlimit
+ Promote the sandbox memory bound from a deferred note to a scheduled, reviewed slice.
```
