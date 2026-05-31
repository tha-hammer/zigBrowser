---
date: 2026-05-01T07:45:00-04:00
reviewer: Claude Opus 4.7 (1M context) — pre-implementation architectural review
plan_under_review: thoughts/searchable/shared/plans/2026-05-01-07-15-tdd-cutover-b-ultimate-mcp-runtime-swap.md
plan_planner: SapphireCanyon
plan_status_at_review: ready_for_review
review_type: pre_implementation_architectural
methodology: contracts / interfaces / promises / data_models / apis
verdict: NEEDS_MINOR_REVISION (3 critical gaps + 9 warnings; resolve critical before B6/B7 land)
tags: [review, cutover-b, tdd-plan, pre-implementation]
---

# Plan Review Report: Cutover B — Ultimate MCP Runtime Swap

## Review Summary

| Category | Status | Issues |
|---|---|---|
| Contracts | ⚠️ | 3 (1 critical) |
| Interfaces | ❌ | 1 critical (FastMCP inspection API undefined) |
| Promises | ⚠️ | 3 (latency baseline, timeout, JSON ordering) |
| Data Models | ⚠️ | 2 (nested-arg passthrough, resource-read parity) |
| APIs | ⚠️ | 2 (inputSchema enforcement, no resource-read behavior) |
| File:line accuracy | ✅ | Verified against source — minor drift only |

**Verdict: `NEEDS_MINOR_REVISION`.** Land B0/B1/B2/B3/B5/B-purity as written. **Do not start B6 until the FastMCP inspection API is resolved.** **Do not finalize B-sec until the env-propagation contract is pinned in the Decision Card.** **Add a B11 (resource-read round-trip) before declaring parity complete.**

---

## Verification of File:Line Claims

Two parallel research agents (`silmari_compat.py` Python side, `index.ts`/`cli.ts` TS side) verified every cited file:line in the plan. Results:

### ✅ Verified accurate
- `silmari_compat.py:19-41` — `SILMARI_TOOL_NAMES` tuple, 21 entries
- `silmari_compat.py:45-83` — `SILMARI_TOOL_ARG_NAMES` dict
- `silmari_compat.py:103` — `silmari_cli_path()`
- `silmari_compat.py:144-165` — `call_silmari_tool` async coroutine
- `silmari_compat.py:153` — `env = dict(os.environ)` (immediately followed by the backend pin)
- `silmari_compat.py:199-219` — `_make_tool` factory using `exec()` at line 213
- `silmari_minimal_runtime.py:152` — hardcoded `not t.startswith("zk_")`
- `silmari_resources.py` — `SILMARI_STATIC_RESOURCES` exports 10 URIs
- `test_silmari_gateway.py:22` — `assert all(tool.startswith("zk_") for tool in manifest["tools"])`
- `typer_cli.py:222-227` — `--silmari-compat` flag
- `apps/silmari-mcp/src/index.ts` — `TOOLS` array exports **27 entries**, exactly as plan claims
- `apps/silmari-mcp/src/index.ts` — `STATIC_RESOURCES` exported alongside `TOOLS`
- `apps/silmari-mcp/src/cli.ts:389-403` — generic `tool` escape hatch (function: `buildToolRequest`)
- `apps/silmari-mcp/tests/ultimate-compat-parity.test.ts:33` — exact regex match
- `apps/silmari-mcp/tests/router-cursor-e2e.test.ts` — exists, tests cursor-style submit + downgrade
- No existing perf tests in `apps/silmari-mcp/tests/` (B-perf would be the first)

### ⚠️ Minor corrections (cosmetic, fix in plan but not blocking)

- **`silmari_compat.py:154` (not :159)** — `env["SILMARI_MCP_BACKEND"] = "typescript"` is one line below `env = dict(os.environ)`. Plan says "line 159 area." Update reference for accuracy.
- **`kindGuard.ts` line drift** — Plan cites `lines 101-106` for `resolveCallerFromEnv`. Actual:
  - `parseTier` at L102-111
  - `parseAgentId` at L113-122
  - `resolveCallerFromEnv` at **L127**
  - Default tier `'mcp-agent'` at L103, default agent ID `'silmari-mcp-process'` (constant `DEFAULT_AGENT_ID` at L100)
  Update Current State Analysis to match.

---

## Contract Review

### ✅ Well-Defined

- **Subprocess shim contract**: `silmari_compat.py:153` does `env = dict(os.environ)`, so all caller env propagates to bun unchanged. This is the load-bearing fact for B-sec — verified true.
- **Tool name → arg-tuple mapping** (B2): every entry in `SILMARI_TOOL_NAMES` requires a corresponding `SILMARI_TOOL_ARG_NAMES` key, enforced by `_make_tool` codegen at import time. Plan's B2 tests this with `test_every_tool_has_arg_tuple` + `test_no_orphan_arg_tuples`. Good.
- **Decision Card §1-§5** locks the scope contract — clear, enumerable, ADR-bounded.

### ⚠️ Warnings

**W1. `SilmariBridgeError` — existing type or new?** B5 success criteria says "non-zero exit code raises `SilmariBridgeError` with stderr content" but doesn't cite the file/line where this exception is defined. If it's invented for this plan, B5 needs a Green code change in `silmari_compat.py` (currently the plan claims "no code change in silmari_compat.py"). **Action:** verify whether `SilmariBridgeError` exists in the current `silmari_compat.py`. If yes, add file:line citation. If no, add a `Green` code block to B5.

**W2. `SILMARI_CALLER_TIER` env-propagation contract is implicit, not pinned.** B-sec acknowledges the gap in its Green section ("if test exposes a passthrough gap, the fix is in silmari_compat.py"), but defers the decision. The actual contract question is: **when Claude Code (or any MCP client) connects to the Python silmari runtime, who is responsible for setting `SILMARI_CALLER_TIER`?** Three possibilities:
  - (a) Operator pins it in `~/.claude.json`'s `env` block (plan's runbook approach)
  - (b) Python frontend infers it from the MCP transport (e.g. stdio → `local-cli`)
  - (c) Default `mcp-agent` if unset (current TS default)

  These produce different security postures. **Action:** add to Decision Card as §6, or pin in B-sec test spec. Otherwise different deployments will pick different defaults.

### ❌ Critical

**C1. Resource-read contract is undefined.** B4 asserts that the **set** of resource URIs matches between TS and Python. But the plan has no behavior testing that the **content** of a resource read returns byte-equal JSON between the two runtimes. `silmari://trunks` could return a 10-trunk listing through TS and a 0-trunk listing through Python (because the Python resource handler doesn't shell out the same way). Without a B11-style read-parity test, an operator who flips Cutover B could discover a silently broken resource surface days later. **Action:** add B11 — "Resource-read round-trip parity" — modeled on B7 but for `silmari://` reads.

---

## Interface Review

### ✅ Well-Defined

- **Subprocess command shape** (B5): `bun, <cli.ts>, "tool", <tool_name>, <compact-json>` — explicit and asserted in tests.
- **Two-table extension pattern**: append to `SILMARI_TOOL_NAMES` + `SILMARI_TOOL_ARG_NAMES`, no other code changes. Reuses existing `_make_tool` codegen.
- **Footprint guard signature** (B3): `assert_default_silmari_mcp_footprint(tool_names, resource_uris) -> dict` is verified to exist at `silmari_minimal_runtime.py:144-170`.

### ❌ Critical

**C2. FastMCP inspection API for B6 is unresolved.** The plan flags this with parenthetical "(The exact FastMCP inspection API — `list_tools()`, `tool_handlers`, `_tools` — needs verification at implementation time. Use whatever the existing `test_silmari_gateway.py:test_default_silmari_footprint_contains_no_ultimate_surface` already uses.)" — but the verification confirms the existing test does NOT introspect a registered FastMCP instance. It uses a static manifest from `build_default_silmari_mcp_footprint_manifest()`. So there is no precedent in the codebase for "list tools registered on a live FastMCP instance."

This means B6's test as written will fail with `AttributeError` until the API is resolved. **Action:** before B6 lands, the planner or implementer must:
  1. Read `vendor/ultimate_mcp_server/ultimate_mcp_server/core/silmari_minimal_runtime.py:69-91` (the `create_silmari_fastmcp` function) and trace what it calls on the `mcp` instance.
  2. Read `FastMCP` documentation (or its source) to find the actual inspection API.
  3. If no public API exists, add a helper `silmari_minimal_runtime.list_registered_tool_names(mcp)` (the plan's Refactor section already anticipates this) — but as the **Green** step, not refactor. Otherwise B6 has no Green path.

  Pin the resolution in the plan as a "B6 prerequisite" sub-task before any implementation.

### ⚠️ Warnings

**W3. `call_silmari_tool` return type — string or dict?** B7's test does `JSON.parse(pyResp)` after `await callViaPython(...)`. The verification confirms `call_silmari_tool` is at `silmari_compat.py:144-165`. The plan should explicitly assert the return type is `str` (raw stdout from bun) so the test is correct. If `_make_tool` already wraps it (the codegen could parse to dict), `JSON.parse(pyResp)` would receive `[object Object]` as a string. **Action:** read `_make_tool` lines 199-219 and pin the return-type contract in B5's Test Specification.

**W4. `decision.warnings` string is a behavioral promise.** B-sec test 4 asserts `decision.warnings` includes `'claimed-thoughttype-downgraded'`. This string must already exist in the Stage 2 routing service (`apps/silmari-mcp/src/lib/router.ts`). If the actual emitted string is different (`'thoughttype-downgraded'`, `'claim-downgraded'`, etc.), the test is wrong. **Action:** grep `apps/silmari-mcp/src/lib/router.ts` for the actual warning string and pin it in B-sec, or remove the specific string and assert `warnings.length > 0` instead.

---

## Promise Review

### ✅ Well-Defined

- **Idempotency for `sai_route_thought`**: the Decision Card §1 says routing decisions write to `route-decisions.jsonl` with unique decisionIds. B7's `stripVolatile` correctly excludes `decisionId` from the equality check. Good.
- **No silent tier elevation** (B-sec) — explicitly tested.
- **Rollback procedure preserves unrelated MCP entries** (B10 test 3) — explicit.

### ⚠️ Warnings

**W5. B-perf budget is unanchored.** The plan picks `zk_status p95 ≤ 500ms` and `zk_save_card p95 ≤ 2000ms` without measuring the current TS-only baseline. If TS-only is already 480ms p95, then "≤500ms with Python frontend added" is impossible. If TS-only is 50ms p95, the budget is too generous and Python regressions go undetected. **Action:** add a step-zero to B-perf: "measure TS-only baseline through `bun apps/silmari-mcp/src/cli.ts tool zk_status '{}'` × 100, log p50/p95/p99/max, set budget = TS p95 × 3 OR record both numbers and let operator approve." Otherwise B-perf is theater.

**W6. Subprocess timeout is undefined.** B-sec snippet references `DEFAULT_TIMEOUT_SECONDS` (presumably from `silmari_compat.py`). What is it currently? B7 spawns subprocess for every call and has 4 cold-start invocations across 2 it-blocks. If timeout is 5s and Python cold-start is 4s, B7 is flaky. **Action:** pin `DEFAULT_TIMEOUT_SECONDS` value in plan (read from source), document expected cold-start cost, decide whether B7 should warm a single Python session or accept 4× cold-start cost.

**W7. `_make_tool` JSON serialization order.** B5's `expected_json` strings are alphabetically sorted (`'{"limit":10,"query":"luhmann"}'`). This requires `silmari_compat` to call `json.dumps(args, sort_keys=True)`. If the current code uses `json.dumps(args)` (insertion-order), the test fails on every Python version where dict iteration differs. **Action:** verify `silmari_compat.py:144-165` actually sorts keys, or change B5 expected strings to insertion-order.

---

## Data Model Review

### ✅ Well-Defined

- **`SILMARI_TOOL_NAMES` ordering invariant** (B1): "6 new entries appear AFTER the 21 existing entries (preserves git diff readability)" — explicit and tested.
- **Schema additivity**: existing 21 tools' arg tuples unchanged; only adds 6 entries. Migration-safe.

### ⚠️ Warnings

**W8. Nested object args (`host`) — does `_make_tool` filter them?** The plan asserts:
> `sai_*` tools' nested `host` object — flattened or kept nested? Per `silmari_compat.py` pattern, nested objects pass through as-is in the JSON payload; arg name in the tuple is just `host`.

But `_make_tool` at `silmari_compat.py:199-219` codegens the wrapper via `exec()`. Does the codegen filter args to only the tuple-listed keys, or pass them all through? If it filters by key name, nested `host` works (top-level key matches tuple). If it does positional argument extraction, nested `host` could be flattened or dropped. **Action:** read `_make_tool` source carefully and pin the contract in B2's Test Specification (currently B2 only tests tuple presence, not roundtrip). Add an assertion in B5's `sai-route-thought-nested-host` fixture that the bun child receives `host: {name: 'claude-code'}` (not `host: 'claude-code'` or empty).

### ❌ Critical (already C1 above, restated for data-model framing)

**C1 (data-model side). Resource read schema not asserted.** Same gap as the contract issue: the plan has no data-model assertion that `silmari://trunks` returns `{trunks: [...]}` with the same field names + types through both runtimes. Add B11.

---

## API Review

### ✅ Well-Defined

- **MCP `tools/list` surface parity** (B6) — though gated on C2 resolution.
- **Wire-format response equality** (B7) — explicit fixtures, byte-equal modulo volatile fields.
- **Versioning posture**: Decision Card §3 explicitly states cross-LLM hosts' MCP entries don't change; the change is *behind* the entry. Operator-facing API is stable.

### ⚠️ Warnings

**W9. inputSchema enforcement layer is unspecified.** When FastMCP receives a tool call with malformed args (e.g. `zk_save_card` without `body`), is the rejection at FastMCP layer (per inputSchema) or at the bun child layer (per existing TS validators)? Two different error codes/messages depending on path. Plan B7 round-trip test only exercises happy-path. **Action:** add a small extension to B7 (or new sub-test) — "malformed args produce equivalent error envelopes through both runtimes." Ensures Cutover B doesn't change error UX silently.

**W10 (folded into C1). No resource-read API behavior.** Add B11.

---

## Critical Issues (Must Address Before Implementation)

### C1. Resource-read parity gap

**Impact:** An operator flips Cutover B; Claude Code reads `silmari://trunks` and gets a different shape than before; downstream behavior breaks silently. No automated detection.
**Fix:** Add Behavior 11 (B11) — "Resource-read round-trip parity." Mirror B7 structure: invoke `silmari://trunks` (or any 1-2 representative URIs) through TS resource handler AND Python FastMCP resource handler, assert byte-equal JSON modulo timestamps. If Python resource handlers don't exist yet, that's itself a finding to address.

### C2. FastMCP inspection API undefined

**Impact:** B6's test as written (`mcp.list_tools()`) will fail with `AttributeError` if that's not the actual API. B6 has no Green path.
**Fix:** Before any code is written for B6, the planner reads `silmari_minimal_runtime.py:69-91` + FastMCP source, identifies the canonical inspection mechanism, and rewrites B6's Red test against that mechanism. If no public API exists, the Green is "add `list_registered_tool_names(mcp)` helper to `silmari_minimal_runtime.py`" — promote from Refactor to Green.

### C3. `SILMARI_CALLER_TIER` propagation contract

**Impact:** Different deployments could pin different default tiers, leading to either over-permissive (forge gates effectively bypassed in some hosts) or over-restrictive (legitimate writes denied) behavior. The cross-LLM persistence story (Cursor/Codex/Gemini) depends on this being explicit.
**Fix:** Add Decision Card §6 — "Caller-tier propagation: operator pins `SILMARI_CALLER_TIER` in `~/.claude.json`'s `mcpServers.silmari.env` block; Python frontend MUST NOT infer or override; default `mcp-agent` only if env is unset." Then B-sec test 1 ("without SILMARI_CALLER_TIER env, defaults to mcp-agent") becomes a contract assertion, not a discovery.

---

## Suggested Plan Amendments

```diff
# In Frontmatter — Decision Card

+ §6: Caller-tier propagation. Operator pins SILMARI_CALLER_TIER in
+      ~/.claude.json mcpServers.silmari.env; Python frontend never
+      infers or overrides; default 'mcp-agent' only if env unset.

# In Current State Analysis — file:line corrections

- silmari_compat.py:153-159 — bridge env: env = dict(os.environ) ...
+ silmari_compat.py:153-154 — bridge env: env = dict(os.environ) +
+   env["SILMARI_MCP_BACKEND"] = "typescript"

- apps/silmari-mcp/src/lib/kindGuard.ts:101-106 — resolveCallerFromEnv ...
+ apps/silmari-mcp/src/lib/kindGuard.ts:127 — resolveCallerFromEnv;
+   parseTier L102-111, parseAgentId L113-122, default tier 'mcp-agent'
+   at L103, DEFAULT_AGENT_ID 'silmari-mcp-process' at L100

# In Behavior 5 — pin error type

+ Test Specification edge cases:
+ - Bridge-error path: cite the existing exception class and file:line.
+   If new, add a Green code block introducing it.

# In Behavior 6 — resolve FastMCP API

+ Prerequisite (BEFORE Red test is written):
+ 1. Read silmari_minimal_runtime.py:69-91 + FastMCP source
+ 2. Pin the inspection API: list_tools() | _tools | tool_handlers | helper
+ 3. If no public API: add list_registered_tool_names(mcp) helper as Green

# In Behavior 7 — pin call_silmari_tool return type + JSON ordering

+ Test Specification:
+ - call_silmari_tool returns: <pin str | dict>
+ - JSON serialization in subprocess command: <pin sort_keys=True or insertion-order>

# In Behavior B-sec — convert deferred decisions to contracts

- "if test exposes a passthrough gap, the fix is in silmari_compat.py"
+ Per Decision Card §6: env propagation is operator-pinned, not auto-inferred.
+ Test 1 asserts the contract default; tests 2-4 assert the contract under
+ each tier value. No silent inference logic in silmari_compat.py.

# In Behavior B-perf — anchor budget against baseline

+ Step Zero (before Red): measure TS-only baseline through
+   `bun apps/silmari-mcp/src/cli.ts tool zk_status '{}'` × 100
+ Log p50/p95/p99/max; set budget = max(TS p95 × 3, operator-stated number)
+ Both numbers documented in runbook (B9).

# NEW Behavior 11 — Resource-read round-trip parity

+ Given: silmari://trunks (and one or two more URIs)
+ When: read through TS resource handler vs Python FastMCP handler
+ Then: byte-equal JSON content modulo timestamps
+ Tests: vendor/ultimate_mcp_server/tests/integration/test_silmari_resource_read.py
+        + apps/silmari-mcp/tests/cutover-b-resource-roundtrip.test.ts
+ Order: between B7 (wire equality) and B-sec (security)

# In E2E Ordering — insert B11 + tighten B6

3. **B4** — TS parity (already)
3.5 **B6** — FIRST resolve C2 (FastMCP API), THEN write Red
4. **B-purity** (already)
5. **B7** + **B11** (parallel — wire-format equality across tools and resources)
6. **B-sec** (depends on B7, B11, and Decision Card §6)
... rest unchanged
```

---

## Approval Status

- [ ] **Ready for Implementation** — No critical issues
- [x] **Needs Minor Revision** — Address C1, C2, C3 + W1-W9 before B6/B7 land
- [ ] **Needs Major Revision** — Critical issues require rework

**Specific guidance to the planner:**

1. Fix the line-number drifts (W cosmetic) in one editing pass — 5 min.
2. Resolve C2 (FastMCP API) by reading `silmari_minimal_runtime.py:69-91` + FastMCP — 15 min. This unblocks B6.
3. Add Decision Card §6 (caller-tier propagation contract) — 5 min. This converts B-sec from "discovery" to "contract assertion."
4. Add Behavior 11 (resource-read parity) — 30 min, mirror B7 structure.
5. Pin `SilmariBridgeError`, `call_silmari_tool` return type, JSON ordering by reading current `silmari_compat.py` — 20 min total.
6. Add B-perf step-zero (baseline measurement) — 5 min plan-side; the actual measurement runs at implementation time.

Total revision effort: ~80 minutes. Plan goes from `NEEDS_MINOR_REVISION` to `READY_FOR_IMPLEMENTATION` after these are applied.

The skeleton is sound. The 12 reviewer-decision frontmatter entries are all preserved. B0/B1/B2/B3/B5/B-purity/B-perf/B9/B10 are all sufficiently specified to start TDD work in parallel — only B6/B7 (and the new B11) are gated on the critical fixes.

---

## Reviewer Sign-off

- ✅ Decision Card §1-§5 reflects operator intent (pending §6 addition)
- ✅ Behavior count and granularity match earlier review feedback (10 + B0 + 3 augments + 1 new = 14, in line with Stage 1's 12 and Stage 2's 16)
- ✅ Each behavior has Red→Green→Refactor cycle (B6 will once C2 resolves)
- ✅ B-sec invokes kindGuard with mocked caller through Python path
- ✅ B-purity is a grep assertion
- ✅ B9 runbook section includes operator log table (8 rows ≥ 5 required) and config-flip steps
- ⚠️ Latency budget numbers (B-perf) — operator-stated but not baseline-anchored (W5)
- ✅ No open questions in plan — all 6 from research doc resolved in `reviewer_decisions` frontmatter
- ✅ References cross-link research doc and Cutover A runbook
- ✅ "What We're NOT Doing" excludes Cutover C and Stage 3
- ❌ Resource-read parity not addressed (C1)
- ❌ FastMCP inspection API not resolved (C2)
- ❌ Caller-tier propagation contract not pinned in Decision Card (C3)
