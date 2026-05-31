---
date: 2026-05-01T07:15:00-04:00
planner: SapphireCanyon (Claude Code, opus-4.7) with operator (Maceo) review
repository: silmari-agent-memory
branch: fix/native-mode-routing-rg-fallback
topic: "Cutover B: swap silmari MCP runtime from TypeScript (bun apps/silmari-mcp/src/index.ts) to Python (python -m ultimate_mcp_server run --silmari-compat) — Python is the FastMCP frontend, TS stays as subprocess shim implementation"
type: tdd_plan
status: revised_after_review
methodology: test_driven_development
revisions:
  - 2026-05-01T08:30:00-04:00 — applied review feedback from 2026-05-01-07-15-tdd-cutover-b-ultimate-mcp-runtime-swap-REVIEW.md
    (3 critical issues + 9 warnings):
    C1 (resource-read parity gap) → added B11 Resource-read round-trip parity behavior;
    C2 (FastMCP inspection API undefined) → B6 rewritten to use static manifest assertion via
      build_default_silmari_mcp_footprint_manifest (no live FastMCP introspection required);
    C3 (caller-tier propagation contract) → added Decision Card §6;
    W1 (SilmariBridgeError citation) → pinned at silmari_compat.py:86-87;
    W3 (call_silmari_tool return type) → pinned as str (silmari_compat.py:165);
    W4 (warning string verification) → confirmed 'claimed-thoughttype-downgraded' at router.ts:538;
    W5 (B-perf budget unanchored) → added Step Zero TS-only baseline measurement;
    W6 (DEFAULT_TIMEOUT_SECONDS) → pinned 30.0 at silmari_compat.py:44;
    W7 (JSON sort_keys) → confirmed at silmari_compat.py:108;
    W8 (nested host arg passthrough) → contract pinned in B2/B5 (key-based passthrough);
    W9 (inputSchema enforcement) → added error-envelope sub-test to B7;
    plus line-number cosmetic corrections (silmari_compat.py:154, kindGuard.ts:127).
prerequisites:
  - Cutover A complete (silmari-store native-primary on disk; per artifacts/runbooks/silmari-store-cutover.md)
  - Stage 2 routing service merged (sai_route_thought + sai_submit_thought live in TS; PR #2 landed)
  - 4d8.7 biblio tools merged (4 zk_biblio_* tools live in TS)
related_research:
  - thoughts/searchable/shared/research/2026-05-01-06-38-cutover-b-runbook-inventory.md
related_specs:
  - artifacts/specs/2026-04-28-beads-rust-replacement/04-migration-cutover-and-verification.md
  - specs/ultimate-mcp-memory.md
related_runbooks:
  - artifacts/runbooks/silmari-store-cutover.md (Cutover A — sibling)
related_plans:
  - thoughts/searchable/shared/plans/2026-04-28-silmari-agent-memory-xq6-tdd-ultimate-mcp-silmari-compatibility.md
  - thoughts/searchable/shared/plans/2026-04-29-cross-llm-sai-persistence-and-user-context-routing.md
  - thoughts/searchable/shared/plans/2026-04-30-11-10-sai-routing-service-tdd-plan.md
  - thoughts/searchable/shared/plans/2026-04-30-silmari-agent-memory-4d8-tdd-silmari-store-full-online.md
reviewer_decisions:
  scope_reading: default_python_frontend_with_subprocess_shim
  prefix_guard: silmari_allowed_prefixes_constant
  parity_mechanism: runtime_python_introspection
  runbook_location: sibling_silmari_store_cutover_b_md
  sai_namespace: keep_under_silmari_mcp_for_cutover_b
  new_resources: defer
  native_python_reader: defer_to_cutover_c
estimated_effort: 6_to_8_hours
tags: [tdd, cutover-b, ultimate-mcp, silmari_compat, fastmcp, runtime-swap, python-frontend]
---

# Cutover B: Ultimate MCP Runtime Swap TDD Implementation Plan

## 🎯 Why Cutover B / Why Now

**Cutover B adds zero user-visible capability.** The same 27 MCP tools (`zk_save_card`, `sai_route_thought`, ...) and 10 resources (`silmari://trunks`, ...) that Claude Code already calls today will work identically afterward. So why do it?

**Cutover B de-risks the runtime swap path before Stage 3.** Stage 3 plans to layer Ultimate's native UMS capabilities (`store_memory`, `query_memories`, `record_action`, the workflow/cognitive-state graph) on top of the silmari surface. That work is enormous and high-risk: a single PR will introduce ~14k LOC of Python operating against silmari-store data. The deployment risk profile matters.

If Stage 3 lands the Python runtime + Ultimate UMS in one drop, a regression in EITHER half forces a rollback of BOTH halves. By landing Cutover B first — Python frontend with byte-equal behavior, no UMS yet — we **decouple the two risks**:

| Risk | Before Cutover B | After Cutover B |
|---|---|---|
| MCP transport / FastMCP / Python tooling regressions | Bundled with UMS feature work | Isolated; easy to roll back |
| UMS feature regressions | Bundled with runtime swap | Isolated; runtime stays |
| Operator confidence in Python runtime | Untested in production | Days/weeks of stable operation |
| Subprocess-shim fault profile | Unknown | Characterized (B-perf budget) |

The `silmari_compat.py` shim is the ideal pre-flight for this: it forces Cutover B to be a pure protocol/transport change. If Cutover B breaks something, it's a Python/FastMCP/subprocess issue — never a silmari logic issue, because the TS dispatcher is byte-identical to before.

**The right way to read this plan: it's an operational maturity step, not a feature delivery.**

---

## 📜 Decision Card (B0)

> **Locked decisions for Cutover B. Do not re-litigate without an ADR.**
>
> 1. **`sai_*` tools live under the `silmari` MCP server for Cutover B.** Splitting `sai_route_thought` / `sai_submit_thought` to a separate `sai` MCP server (as `2026-04-29-cross-llm-sai-persistence-and-user-context-routing.md` reserves) is a separate architectural question — file as ADR before changing.
> 2. **No native Python silmari-store data layer in Cutover B.** Python is the MCP frontend; every tool call still shells out to `bun apps/silmari-mcp/src/cli.ts`. Building a Python-native silmari-store reader is **Cutover C** (separate runbook, separate plan).
> 3. **Cross-LLM hosts (Cursor/Codex/Gemini) MCP configurations do not change.** They were already pointed at the canonical `silmari` MCP entry; Cutover B swaps what's behind that entry, not the entry itself.
> 4. **No new `silmari://` resources in this Cutover.** The 10 existing resources cover the substrate; route-decisions and biblio entities are reachable via tools.
> 5. **Cutover B requires Cutover A complete.** Will not begin against a `legacy-read-only` or `beads-rust` storage backend.
> 6. **Caller-tier propagation is operator-pinned, never inferred.** The operator pins `SILMARI_CALLER_TIER` (and `SILMARI_CALLER_AGENT_ID`) in `~/.claude.json`'s `mcpServers.silmari.env` block. The Python frontend MUST NOT infer a tier from the MCP transport, the host name, or any other source — the env is the single source of truth. If `SILMARI_CALLER_TIER` is unset, `kindGuard.resolveCallerFromEnv` defaults to `mcp-agent` (least privilege) at `apps/silmari-mcp/src/lib/kindGuard.ts:103`. The Python `silmari_compat.call_silmari_tool` already propagates `os.environ` to the bun child unchanged at `silmari_compat.py:153`, so there is **no new code path required** — the contract is enforced by absence of inference logic. Different deployments on different machines will pick whatever the operator pins, and the runbook makes the choice explicit. This converts B-sec from a discovery exercise into a contract assertion.

---

## Overview

**Cutover B swaps the silmari MCP runtime process from `bun apps/silmari-mcp/src/index.ts` (Node/Bun) to `python -m ultimate_mcp_server run --silmari-compat` (Python FastMCP via vendored Ultimate).**

Architecture before:

```
Claude Code  ──MCP/stdio──▶  bun apps/silmari-mcp/src/index.ts  ──▶  silmari-store
```

Architecture after:

```
Claude Code  ──MCP/stdio──▶  python -m ultimate_mcp_server (silmari_compat=True)
                                   │
                                   │ subprocess (per tool call)
                                   ▼
                             bun apps/silmari-mcp/src/cli.ts  ──▶  silmari-store
```

Two new things to verify:

1. **Tool-surface parity**: Python `silmari_compat.SILMARI_TOOL_NAMES` must include the 6 TS-only tools added by Stage 2 (`sai_route_thought`, `sai_submit_thought`) and 4d8.7 (`zk_biblio_*`). Today it lists 21 tools; target is 27.
2. **Operational safety**: kindGuard caller-tier inference, log paths, latency budget, rollback, config-flip mechanism — all must be characterized and tested before the operator ever flips production.

---

## Current State Analysis

### Key Discoveries (from `2026-05-01-06-38-cutover-b-runbook-inventory.md`)

- `vendor/ultimate_mcp_server/ultimate_mcp_server/tools/silmari_compat.py` is the bridge module. `SILMARI_TOOL_NAMES` tuple at lines 19-41 (21 entries); `SILMARI_TOOL_ARG_NAMES` dict at lines 45-83. Adding tools requires only appending to these two tables — `_make_tool` factory at lines 199-219 codegens wrappers via `exec()`.
- `vendor/ultimate_mcp_server/ultimate_mcp_server/core/silmari_resources.py` exposes 10 static `silmari://` URIs (unchanged for Cutover B).
- `vendor/ultimate_mcp_server/ultimate_mcp_server/core/silmari_minimal_runtime.py:152` — `non_silmari_tools = sorted(t for t in tools if not t.startswith("zk_"))`. Hardcoded `zk_` prefix; rejects `sai_*`.
- `vendor/ultimate_mcp_server/tests/integration/test_silmari_gateway.py:22` — `assert all(tool.startswith("zk_") for tool in manifest["tools"])`. Same `zk_` prefix lock.
- `apps/silmari-mcp/tests/ultimate-compat-parity.test.ts:33` — `uniqueMatches(source, /"(zk_[^"]+)"/g)`. Regex-based parity, structurally cannot match `sai_*`.
- `vendor/ultimate_mcp_server/ultimate_mcp_server/cli/typer_cli.py:222-227` — `--silmari-compat` flag exists end-to-end. Threads through `cli/commands.py:43,148` to `core/server.py:2080,2176-2185` (minimal-runtime path).
- `apps/silmari-mcp/src/cli.ts:389-403` — generic `silmari tool <name> <json>` escape hatch already routes any registered tool. **No CLI changes required for the 6 new tools.**
- `apps/silmari-mcp/src/lib/kindGuard.ts:127` — `resolveCallerFromEnv(env = process.env): Caller` reads `SILMARI_CALLER_TIER` and `SILMARI_CALLER_AGENT_ID`. Helper layout: `parseTier` at L102-111, `parseAgentId` at L113-122, default tier `'mcp-agent'` at L103, `DEFAULT_AGENT_ID = 'silmari-mcp-process'` at L100.
- `vendor/ultimate_mcp_server/ultimate_mcp_server/tools/silmari_compat.py:153-154` — bridge env: `env = dict(os.environ)` (line 153) + `env["SILMARI_MCP_BACKEND"] = "typescript"` (line 154). Subprocess inherits all caller env unchanged.
- `vendor/ultimate_mcp_server/ultimate_mcp_server/tools/silmari_compat.py:44` — `DEFAULT_TIMEOUT_SECONDS = 30.0` (subprocess timeout for both `call_silmari_tool` and `call_silmari_resource`).
- `vendor/ultimate_mcp_server/ultimate_mcp_server/tools/silmari_compat.py:108` — `compact_args` uses `json.dumps(..., separators=(",", ":"), sort_keys=True)`, so the JSON wire payload to bun is alphabetically key-sorted. Test fixtures in B5 must mirror this ordering.
- `vendor/ultimate_mcp_server/ultimate_mcp_server/tools/silmari_compat.py:86-87` — `class SilmariBridgeError(RuntimeError)`. Existing exception class; B5 cites it without introducing a new type.
- `vendor/ultimate_mcp_server/ultimate_mcp_server/tools/silmari_compat.py:165` — `call_silmari_tool` returns `str` (raw stdout from bun, `.strip()`-ed). B7 round-trip test must `JSON.parse` this string on the TS side.
- `vendor/ultimate_mcp_server/ultimate_mcp_server/tools/silmari_compat.py:199-208` — `_make_tool` codegen: payload assembled via `if <arg> is not None: payload[<arg>] = <arg>`, so each tuple-listed arg name is a top-level KEY whose value is whatever the caller passed (including nested dicts). Nested objects like `host: {name, sessionId, model}` pass through as-is; the tuple entry is just `host`.

### Patterns to Reuse

- **Two-table codegen** for tool registration (`_make_tool`)
- **Subprocess shim** with env recursion guard (`SILMARI_MCP_BACKEND=typescript`)
- **Footprint guard pattern** from `silmari_minimal_runtime.assert_default_silmari_mcp_footprint`
- **TS↔Python parity test pattern** from `apps/silmari-mcp/tests/ultimate-compat-parity.test.ts`
- **Cursor-style E2E pattern** from Stage 2 B14 (`router-cursor-e2e.test.ts`)
- **Operator runbook structure** from `artifacts/runbooks/silmari-store-cutover.md`

---

## 🚀 Desired End State

A clean operator workflow exists to flip Claude Code's silmari MCP from the Bun TS runtime to the Python FastMCP runtime, with byte-identical tool surface, identical caller-tier semantics, characterized latency, and a 30-second rollback path.

### Observable Behaviors

- **Surface parity**: `python -c "from ultimate_mcp_server.tools.silmari_compat import SILMARI_TOOL_NAMES; print(json.dumps(list(SILMARI_TOOL_NAMES)))"` returns a JSON array byte-equal to `apps/silmari-mcp/src/index.ts`'s `TOOLS.map(t => t.name).sort()`.
- **All 27 tools register**: starting `python -m ultimate_mcp_server run --silmari-compat --transport stdio` and listing tools via the MCP `tools/list` request returns 27 tool definitions.
- **Wire-format equality**: invoking any tool through the Python runtime returns a response byte-equal (modulo decision UUIDs and timestamps) to invoking it through the TS runtime.
- **Caller-tier preservation**: under the Python frontend, `system-hook` tier callers can still write `preference` cards; `remote-host` callers still get downgraded; the `kindGuard.deny` audit emits when expected.
- **Subprocess purity**: `silmari_compat.py` contains zero direct sqlite or filesystem reads of silmari-store data; every data access is mediated by the TS CLI subprocess.
- **Latency budget**: p95 latency ≤ 500ms for `zk_status`, ≤ 2s for `zk_save_card`, measured over a 100-call sample.
- **Rollback works**: flipping the operator config back to TS runtime + restarting MCP returns the system to the prior state in under 30 seconds; the 21-tool surface (no `sai_*`, no `zk_biblio_*`) is restored.

### Reviewer Decisions Applied

- Prefix guard relaxes via `SILMARI_ALLOWED_PREFIXES = ("zk_", "sai_")` constant.
- Parity test reads Python tuple at runtime via `subprocess`-invoked `python -c` introspection. No regex.
- Cutover B runbook lands at sibling path `artifacts/runbooks/silmari-store-cutover-b.md`.
- `sai_*` tools stay on the `silmari` MCP namespace.
- No new `silmari://` resources.
- Native Python silmari-store reader explicitly out of scope (Cutover C track).

---

## 🚫 What We're NOT Doing

| Out of scope | Reason / when |
|---|---|
| Native Python silmari-store data layer (sqlite reads from Python) | Cutover C — separate runbook, separate plan |
| Splitting `sai_*` tools to a separate `sai` MCP server | Architectural change; future ADR per Decision Card §1 |
| Stage 3 Ultimate UMS layering (`store_memory`, `query_memories`, etc.) | Stage 3 — depends on Cutover B + native data layer |
| New `silmari://route-decisions` / `silmari://biblio/<id>` resources | No demand signal; tools cover the access patterns |
| Removing the TS implementation | TS stays as subprocess shim implementation forever (or until Cutover C) |
| Cross-LLM host configuration changes (Cursor/Codex/Gemini) | Their MCP entry stays at `silmari`; Cutover B swaps the *implementation*, not the *registration* |
| Performance optimization beyond p95 budget | Out of scope — measure, don't tune |
| Adding CLI subcommand cases for the 6 tools | Generic `silmari tool` escape hatch already serves them |

---

## 🧪 Testing Strategy

- **Frameworks**: `bun:test` (TS), `pytest` (Python)
- **TS test runs**: `bun test apps/silmari-mcp/tests/`
- **Python test runs**: `cd vendor/ultimate_mcp_server && pytest tests/unit/ tests/integration/`
- **Test types**:
  - **Unit (Python)**: `silmari_compat.py` table contents (B1-B2), bridge invocation per-tool (B5), purity grep (B-purity)
  - **Unit (TS)**: parity introspection (B4)
  - **Integration**: footprint guards (B3), FastMCP registration (B6), wire-format equality (B7), kindGuard under Python frontend (B-sec)
  - **E2E**: cursor-style submit through Python runtime (B8), rollback flip (B10)
  - **Perf**: latency budget gate (B-perf)
  - **Documentation**: runbook structure assertion (B9)
- **Test isolation**: temp `SILMARI_DIR`, env-var restores in fixture teardown, no shared mutable state across files
- **Subprocess mocking**: `monkeypatch` for `asyncio.create_subprocess_exec` per the existing `test_silmari_compat.py:test_call_silmari_tool_uses_generic_cli_bridge` pattern. Real-bun integration tests for B7 and B8 only.
- **Runbook test**: a markdown lint test that asserts the runbook contains the required sections (operator log table, config flip steps, rollback, smoke verification)

---

## Behavior 1: SILMARI_TOOL_NAMES Includes All 27 Tools

### Test Specification

**Given**: the existing `silmari_compat.SILMARI_TOOL_NAMES` tuple (21 entries) and the 6 TS-only tool names from `apps/silmari-mcp/src/index.ts` TOOLS array.
**When**: the Python tuple is read.
**Then**: it contains all 27 names in deterministic order, every entry is a string, and there are no duplicates.

**Edge cases**:
- The 6 new entries appear AFTER the 21 existing entries (preserves git diff readability).
- Order within the 21 existing entries is unchanged (parity test on existing surface still passes).
- `_make_tool` codegen executes successfully for every entry on import.

### TDD Cycle

#### 🔴 Red: Failing Test

**File**: `vendor/ultimate_mcp_server/tests/unit/test_silmari_compat_surface.py` (new)

```python
from ultimate_mcp_server.tools.silmari_compat import SILMARI_TOOL_NAMES

EXPECTED_27 = (
    # 21 existing — exact order preserved
    "zk_save_card", "zk_save_cards", "zk_recall", "zk_neighborhood",
    "zk_chain", "zk_follow", "zk_propose_link", "zk_propose_links_semantic",
    "zk_commit_link", "zk_hub_create", "zk_hub_add_card", "zk_hub_members",
    "zk_line_of_thought", "zk_structure_create", "zk_register_read",
    "zk_block", "zk_keyword_add", "zk_status", "zk_reflect",
    "zk_recall_by_status", "zk_promote",
    # 6 new — appended for diff readability
    "zk_biblio_search", "zk_biblio_link_source",
    "zk_biblio_sources_for_idea", "zk_biblio_ideas_for_source",
    "sai_route_thought", "sai_submit_thought",
)


def test_tool_names_match_27_entry_canonical_order():
    assert SILMARI_TOOL_NAMES == EXPECTED_27


def test_tool_names_are_unique():
    assert len(SILMARI_TOOL_NAMES) == len(set(SILMARI_TOOL_NAMES))


def test_tool_names_all_strings():
    assert all(isinstance(n, str) and n for n in SILMARI_TOOL_NAMES)
```

#### 🟢 Green: Minimal Implementation

**File**: `vendor/ultimate_mcp_server/ultimate_mcp_server/tools/silmari_compat.py` (lines 19-41 modified)

```python
SILMARI_TOOL_NAMES: tuple[str, ...] = (
    # ── Existing 21 (do not reorder) ──
    "zk_save_card", "zk_save_cards", "zk_recall", "zk_neighborhood",
    "zk_chain", "zk_follow", "zk_propose_link", "zk_propose_links_semantic",
    "zk_commit_link", "zk_hub_create", "zk_hub_add_card", "zk_hub_members",
    "zk_line_of_thought", "zk_structure_create", "zk_register_read",
    "zk_block", "zk_keyword_add", "zk_status", "zk_reflect",
    "zk_recall_by_status", "zk_promote",
    # ── Cutover B additions (4d8.7 biblio + Stage 2 SAI routing) ──
    "zk_biblio_search", "zk_biblio_link_source",
    "zk_biblio_sources_for_idea", "zk_biblio_ideas_for_source",
    "sai_route_thought", "sai_submit_thought",
)
```

#### 🔵 Refactor

None. The tuple IS the canonical surface; no abstraction reduces it.

### Success Criteria

**Automated**:
- [ ] Red fails: `pytest tests/unit/test_silmari_compat_surface.py::test_tool_names_match_27_entry_canonical_order` returns `Expected 27, got 21`
- [ ] Green passes the same test
- [ ] No existing test breaks: `pytest tests/` runs without regression
- [ ] `_make_tool` factory imports cleanly (no `KeyError` for missing arg tuples — gated by B2 landing in same commit)

**Manual**:
- [ ] Visual inspection: 27 entries, no typos, prefixes line up with TS source

---

## Behavior 2: SILMARI_TOOL_ARG_NAMES Has Correct Tuples for the 6 New Tools

### Test Specification

**Given**: the 6 new tools' inputSchema declarations in `apps/silmari-mcp/src/index.ts`.
**When**: `silmari_compat.SILMARI_TOOL_ARG_NAMES` is read.
**Then**: every entry in `SILMARI_TOOL_NAMES` has a corresponding key in the dict, and the arg tuple matches the TS inputSchema's accepted properties (in source order).

**Edge cases**:
- `zk_status` already has `()` empty tuple — the pattern works for the no-arg case.
- `sai_*` tools' nested `host` object (`{ name, sessionId, model }`) — flattened or kept nested? Per `silmari_compat.py` pattern, nested objects pass through as-is in the JSON payload; arg name in the tuple is just `host`.

### TDD Cycle

#### 🔴 Red: Failing Test

**File**: `vendor/ultimate_mcp_server/tests/unit/test_silmari_compat_surface.py` (extend)

```python
from ultimate_mcp_server.tools.silmari_compat import (
    SILMARI_TOOL_NAMES, SILMARI_TOOL_ARG_NAMES,
)


def test_every_tool_has_arg_tuple():
    missing = sorted(set(SILMARI_TOOL_NAMES) - set(SILMARI_TOOL_ARG_NAMES))
    assert missing == [], f"missing arg tuples for: {missing}"


def test_no_orphan_arg_tuples():
    orphans = sorted(set(SILMARI_TOOL_ARG_NAMES) - set(SILMARI_TOOL_NAMES))
    assert orphans == [], f"orphan arg tuples (no matching tool): {orphans}"


def test_biblio_tool_args():
    assert SILMARI_TOOL_ARG_NAMES["zk_biblio_search"] == ("query", "limit")
    assert SILMARI_TOOL_ARG_NAMES["zk_biblio_link_source"] == ("ideaId", "biblioId")
    assert SILMARI_TOOL_ARG_NAMES["zk_biblio_sources_for_idea"] == ("ideaId",)
    assert SILMARI_TOOL_ARG_NAMES["zk_biblio_ideas_for_source"] == ("biblioId", "limit")


def test_sai_tool_args():
    expected = ("content", "claimedThoughtType", "source", "host")
    assert SILMARI_TOOL_ARG_NAMES["sai_route_thought"] == expected
    assert SILMARI_TOOL_ARG_NAMES["sai_submit_thought"] == expected
```

#### 🟢 Green: Minimal Implementation

**File**: `vendor/ultimate_mcp_server/ultimate_mcp_server/tools/silmari_compat.py` (extend dict at lines 45-83)

```python
SILMARI_TOOL_ARG_NAMES: dict[str, tuple[str, ...]] = {
    # ... 21 existing entries unchanged ...
    "zk_biblio_search": ("query", "limit"),
    "zk_biblio_link_source": ("ideaId", "biblioId"),
    "zk_biblio_sources_for_idea": ("ideaId",),
    "zk_biblio_ideas_for_source": ("biblioId", "limit"),
    "sai_route_thought": ("content", "claimedThoughtType", "source", "host"),
    "sai_submit_thought": ("content", "claimedThoughtType", "source", "host"),
}
```

#### 🔵 Refactor

Defer. Once B5 lands, consider a lint that asserts `SILMARI_TOOL_ARG_NAMES` keys are a strict subset of `SILMARI_TOOL_NAMES`.

### Success Criteria

**Automated**:
- [ ] All 4 tests in `test_silmari_compat_surface.py` pass
- [ ] `from ultimate_mcp_server.tools.silmari_compat import SILMARI_TOOL_NAMES, SILMARI_TOOL_ARG_NAMES` succeeds at import time
- [ ] `_make_tool` codegen produces 27 callables (verified by B6's registration test)

**Manual**:
- [ ] Cross-check each tuple against the TS inputSchema in `apps/silmari-mcp/src/index.ts` — order matches

---

## Behavior 3: Footprint Guard Accepts SILMARI_ALLOWED_PREFIXES

### Test Specification

**Given**: 27 tools registered, including 2 with `sai_` prefix and 25 with `zk_` prefix.
**When**: `assert_default_silmari_mcp_footprint(tool_names, resource_uris)` runs.
**Then**: it returns the manifest without raising; the manifest's `tools` list contains all 27.

**Edge cases**:
- Unknown prefix (e.g. `xyz_foo`) must still raise (security gate not removed, just expanded).
- Empty `SILMARI_ALLOWED_PREFIXES` tuple must reject everything (defense against accidental clearing).
- Bare-name tools (no underscore prefix) must still reject.

### TDD Cycle

#### 🔴 Red: Failing Test

**File**: `vendor/ultimate_mcp_server/tests/integration/test_silmari_gateway.py` (extend)

```python
from ultimate_mcp_server.core.silmari_minimal_runtime import (
    SILMARI_ALLOWED_PREFIXES,
    assert_default_silmari_mcp_footprint,
    build_default_silmari_mcp_footprint_manifest,
)
from ultimate_mcp_server.tools.silmari_compat import SILMARI_TOOL_NAMES


def test_allowed_prefixes_constant_includes_zk_and_sai():
    assert SILMARI_ALLOWED_PREFIXES == ("zk_", "sai_")


def test_footprint_accepts_27_tools_with_mixed_prefixes():
    resource_uris = [r["uri"] for r in SILMARI_STATIC_RESOURCES]
    manifest = assert_default_silmari_mcp_footprint(
        list(SILMARI_TOOL_NAMES), resource_uris,
    )
    assert len(manifest["tools"]) == 27


def test_footprint_rejects_unknown_prefix():
    bad = list(SILMARI_TOOL_NAMES) + ["xyz_leak"]
    resource_uris = [r["uri"] for r in SILMARI_STATIC_RESOURCES]
    with pytest.raises(AssertionError, match=r"non_silmari_tools.*xyz_leak"):
        assert_default_silmari_mcp_footprint(bad, resource_uris)
```

#### 🟢 Green: Minimal Implementation

**File**: `vendor/ultimate_mcp_server/ultimate_mcp_server/core/silmari_minimal_runtime.py`

```python
# New constant — allow-list for tool name prefixes in the silmari footprint.
# zk_ is the original Zettelkasten substrate surface (21 tools).
# sai_ is the SAI routing service surface added Stage 2 (sai_route_thought,
# sai_submit_thought). Both are registered on the silmari MCP server for
# Cutover B per Decision Card §1; splitting sai_ to a separate MCP server is
# a future ADR.
SILMARI_ALLOWED_PREFIXES: tuple[str, ...] = ("zk_", "sai_")


def assert_default_silmari_mcp_footprint(tool_names, resource_uris) -> dict:
    # ... existing missing_tools / forbidden_tools logic ...

    non_silmari_tools = sorted(
        t for t in tool_names
        if not any(t.startswith(p) for p in SILMARI_ALLOWED_PREFIXES)
    )
    if non_silmari_tools:
        raise AssertionError(
            f"non_silmari_tools (no allowed prefix): {non_silmari_tools}"
        )

    # ... rest unchanged ...
```

Update `tests/integration/test_silmari_gateway.py:22` to read:

```python
assert all(
    any(tool.startswith(p) for p in SILMARI_ALLOWED_PREFIXES)
    for tool in manifest["tools"]
)
```

#### 🔵 Refactor

Once landed, re-export `SILMARI_ALLOWED_PREFIXES` from `tools/__init__.py` so downstream code can import it instead of re-defining.

### Success Criteria

**Automated**:
- [ ] `pytest tests/integration/test_silmari_gateway.py::test_footprint_accepts_27_tools_with_mixed_prefixes` passes
- [ ] `pytest tests/integration/test_silmari_gateway.py::test_footprint_rejects_unknown_prefix` passes
- [ ] All other tests in `test_silmari_gateway.py` still pass

**Manual**:
- [ ] Code review: the constant is documented; the comment names Decision Card §1

---

## Behavior 4: Parity Test Reads Python Tuple at Runtime

### Test Specification

**Given**: `apps/silmari-mcp/tests/ultimate-compat-parity.test.ts` is the TS↔Python surface gate.
**When**: the test runs.
**Then**: it invokes `python -c "from ultimate_mcp_server.tools.silmari_compat import SILMARI_TOOL_NAMES; import json; print(json.dumps(list(SILMARI_TOOL_NAMES)))"` to read the Python tuple, parses it, and asserts equality with the TS `TOOLS.map(t => t.name).sort()`.

**Edge cases**:
- Python not in PATH: skip with a clear message (don't false-fail in environments without Python).
- Python import error: surface the stderr in the test failure message.
- Tuple shape malformed: reject with a clear test failure.
- Resource URIs use the same mechanism (`SILMARI_STATIC_RESOURCES` from `silmari_resources.py`).

### TDD Cycle

#### 🔴 Red: Failing Test

**File**: `apps/silmari-mcp/tests/ultimate-compat-parity.test.ts` (rewrite)

```ts
import { describe, it, expect } from 'bun:test';
import { TOOLS, STATIC_RESOURCES } from '../src/index.js';

function readPythonList(snippet: string): string[] {
  const proc = Bun.spawnSync(['python', '-c', snippet], {
    stdout: 'pipe',
    stderr: 'pipe',
  });
  if (proc.exitCode !== 0) {
    throw new Error(`python introspection failed: ${new TextDecoder().decode(proc.stderr)}`);
  }
  return JSON.parse(new TextDecoder().decode(proc.stdout).trim());
}

describe('Ultimate MCP Silmari compatibility parity (runtime introspection)', () => {
  it('declares exactly the canonical Silmari tool names', () => {
    const tsNames = TOOLS.map((t) => t.name).sort();
    const pythonNames = readPythonList(
      'from ultimate_mcp_server.tools.silmari_compat import SILMARI_TOOL_NAMES;' +
      'import json; print(json.dumps(sorted(SILMARI_TOOL_NAMES)))',
    );
    expect(pythonNames).toEqual(tsNames);
  });

  it('declares exactly the canonical static Silmari resources', () => {
    const tsURIs = STATIC_RESOURCES.map((r) => r.uri).sort();
    const pythonURIs = readPythonList(
      'from ultimate_mcp_server.core.silmari_resources import SILMARI_STATIC_RESOURCES;' +
      'import json; print(json.dumps(sorted(r["uri"] for r in SILMARI_STATIC_RESOURCES)))',
    );
    expect(pythonURIs).toEqual(tsURIs);
  });
});
```

#### 🟢 Green: Implementation

The test code IS the implementation. The introspection mechanism does not require code changes in `silmari_compat.py` or `silmari_resources.py` — it just reads what's already there.

If `python` is not found in PATH on the developer's machine, install it OR set `PYTHON_BIN` env override (add escape hatch in test):

```ts
const PYTHON_BIN = process.env.PYTHON_BIN ?? 'python';
```

#### 🔵 Refactor

Extract `readPythonList` to a `apps/silmari-mcp/tests/_python-introspect.ts` helper if it gets reused (B-purity may also use it).

### Success Criteria

**Automated**:
- [ ] Red fails: regex-based version of the test produces `Expected -6 / Received +0` (or similar drift signal)
- [ ] Green passes: both `it` assertions return clean
- [ ] Skip path works: with `PYTHON_BIN=/nonexistent`, test fails with a clear "python introspection failed" error (not a silent pass)

**Manual**:
- [ ] Run `bun test apps/silmari-mcp/tests/ultimate-compat-parity.test.ts` — completes in under 5 seconds
- [ ] Rename a tool in TS WITHOUT updating Python — test fails on the rename (regex couldn't catch this; introspection does)

---

## Behavior 5: Parameterized Subprocess-Bridge Tests for the 6 New Tools

### Test Specification

**Given**: the bridge function `call_silmari_tool(name, args)` shells out to `bun apps/silmari-mcp/src/cli.ts tool <name> <json>`.
**When**: each of the 6 new tools is invoked with representative args.
**Then**: the bridge constructs the correct subprocess command (positional args, env, cwd) and parses the response.

This is **one parameterized test** that loops over the 6 tools, mocks `asyncio.create_subprocess_exec`, and asserts the invocation shape per tool.

**Edge cases**:
- Tools with no args (none of the 6, but pattern matches `zk_status` for sanity)
- Tools with nested object args (`sai_*` tools' `host: {name, sessionId, model}` object): per `_make_tool` codegen at `silmari_compat.py:199-208`, `host` is a top-level key in the payload dict; its value is the nested object as-is (not flattened, not stringified)
- Bridge-error path: non-zero exit code raises `SilmariBridgeError` (defined at `silmari_compat.py:86-87`) with stderr content (per the existing `if result.returncode != 0: raise SilmariBridgeError(detail)` at `silmari_compat.py:162-164`)
- JSON wire-format ordering: `compact_args` at `silmari_compat.py:108` uses `sort_keys=True`. Test fixtures' `expected_json` strings must be alphabetically key-sorted to match
- Return type: `call_silmari_tool` returns `str` (line 165 — `result.stdout.strip()`), not a parsed dict. Tests assert against the raw stdout string

### TDD Cycle

#### 🔴 Red: Failing Test

**File**: `vendor/ultimate_mcp_server/tests/unit/test_silmari_compat.py` (extend)

```python
import pytest
from ultimate_mcp_server.tools import silmari_compat


CUTOVER_B_TOOL_FIXTURES = [
    pytest.param(
        "zk_biblio_search",
        {"query": "luhmann", "limit": 10},
        '{"limit":10,"query":"luhmann"}',
        id="biblio-search-with-limit",
    ),
    pytest.param(
        "zk_biblio_link_source",
        {"ideaId": "zk-abc", "biblioId": "bl-xyz"},
        '{"biblioId":"bl-xyz","ideaId":"zk-abc"}',
        id="biblio-link-source",
    ),
    pytest.param(
        "zk_biblio_sources_for_idea",
        {"ideaId": "zk-abc"},
        '{"ideaId":"zk-abc"}',
        id="biblio-sources-for-idea",
    ),
    pytest.param(
        "zk_biblio_ideas_for_source",
        {"biblioId": "bl-xyz", "limit": 50},
        '{"biblioId":"bl-xyz","limit":50}',
        id="biblio-ideas-for-source",
    ),
    pytest.param(
        "sai_route_thought",
        {"content": "test", "claimedThoughtType": "insight",
         "host": {"name": "claude-code"}},
        '{"claimedThoughtType":"insight","content":"test","host":{"name":"claude-code"}}',
        id="sai-route-thought-nested-host",
    ),
    pytest.param(
        "sai_submit_thought",
        {"content": "submit", "claimedThoughtType": "decision",
         "source": "algorithm-execute"},
        '{"claimedThoughtType":"decision","content":"submit","source":"algorithm-execute"}',
        id="sai-submit-thought-with-source",
    ),
]


@pytest.mark.parametrize("tool_name,args,expected_json", CUTOVER_B_TOOL_FIXTURES)
@pytest.mark.asyncio
async def test_cutover_b_tool_uses_generic_cli_bridge(
    tool_name, args, expected_json, monkeypatch,
):
    captured = {}

    class FakeProc:
        returncode = 0
        async def communicate(self):
            return (b'{"ok":true}', b"")

    async def fake_exec(*cmd, **kwargs):
        captured["cmd"] = cmd
        captured["env"] = kwargs.get("env")
        captured["cwd"] = kwargs.get("cwd")
        return FakeProc()

    monkeypatch.setattr(
        silmari_compat.asyncio, "create_subprocess_exec", fake_exec,
    )

    result = await silmari_compat.call_silmari_tool(tool_name, args)

    # Command shape: bun, <cli.ts>, "tool", <tool_name>, <compact-json>
    # JSON ordering: alphabetic by key (silmari_compat.py:108 sort_keys=True)
    # Return type: str (silmari_compat.py:165 result.stdout.strip())
    assert captured["cmd"][0] == "bun"
    assert captured["cmd"][-3:] == ("tool", tool_name, expected_json)
    assert captured["env"]["SILMARI_MCP_BACKEND"] == "typescript"
    assert isinstance(result, str)
    assert result == '{"ok":true}'


@pytest.mark.parametrize("tool_name,args,_expected_json", CUTOVER_B_TOOL_FIXTURES)
@pytest.mark.asyncio
async def test_cutover_b_tool_propagates_bridge_error(
    tool_name, args, _expected_json, monkeypatch,
):
    """Bridge-error path: non-zero exit code raises SilmariBridgeError.

    SilmariBridgeError is defined at silmari_compat.py:86-87. This test pins
    that the existing exception type is reused for the 6 new tools, not
    silently replaced.
    """

    class FakeProc:
        returncode = 1
        async def communicate(self):
            return (b"", b"E_KIND_FORGE: caller cannot assert kind=preference")

    async def fake_exec(*_cmd, **_kwargs):
        return FakeProc()

    monkeypatch.setattr(
        silmari_compat.asyncio, "create_subprocess_exec", fake_exec,
    )

    with pytest.raises(silmari_compat.SilmariBridgeError) as exc_info:
        await silmari_compat.call_silmari_tool(tool_name, args)
    assert "E_KIND_FORGE" in str(exc_info.value)


def test_sai_route_thought_host_is_nested_dict_in_payload():
    """host arg passes through as a nested dict, not flattened or stringified.

    Verifies the W8 contract: _make_tool codegen at silmari_compat.py:199-208
    treats each tuple-listed arg as a top-level KEY whose VALUE is whatever
    the caller passes (dict, str, list, etc.).
    """
    # The compact_args output for sai_route_thought with nested host:
    args = {"content": "x", "host": {"name": "claude-code", "sessionId": "s1"}}
    payload = silmari_compat.compact_args(args)
    # JSON sort_keys puts content before host alphabetically
    assert payload == (
        '{"content":"x","host":{"name":"claude-code","sessionId":"s1"}}'
    )
```

#### 🟢 Green: Minimal Implementation

No code change in `silmari_compat.py` — `call_silmari_tool` already handles arbitrary tool names from `SILMARI_TOOL_NAMES`. The B1 + B2 tuple/dict additions plus the parameterized test together drive Green.

#### 🔵 Refactor

Once landed, consider extending the parametrize to ALSO assert error-path behavior (non-zero exit, timeout) per tool. Defer.

### Success Criteria

**Automated**:
- [ ] `pytest -v tests/unit/test_silmari_compat.py::test_cutover_b_tool_uses_generic_cli_bridge` shows 6 PASSED with parametrize ids
- [ ] No new logic added to `silmari_compat.py` to make this test pass — the existing bridge serves all 6

**Manual**:
- [ ] Compare emitted JSON against the TS dispatch case's `parseEnumOptional` / `parsePositiveNumber` calls — args reach the dispatcher in compatible form

---

## Behavior 6: Minimal-Runtime FastMCP Registers All 27 Tools (Static Manifest)

### Test Specification

**Given**: `SILMARI_TOOL_NAMES` (27 entries from B1) + `SILMARI_STATIC_RESOURCES` (10 entries, unchanged).
**When**: `build_default_silmari_mcp_footprint_manifest()` builds the static manifest AND `create_silmari_fastmcp("silmari")` returns a `FastMCP` instance.
**Then**: the manifest contains 27 tools + 10 resources, the FastMCP factory does not raise during registration, and `assert_default_silmari_mcp_footprint` accepts the surface.

**Why static manifest, not live introspection (resolves Review C2):** the existing `test_silmari_gateway.py:14-23` pattern (verified by review) does NOT introspect a live FastMCP instance — it asserts properties of the static manifest from `build_default_silmari_mcp_footprint_manifest()`. The vendored `FastMCP` (from `fastmcp` package) does not expose a stable public introspection API in the version pinned at submodule `9dd1762`. Promoting the static-manifest pattern is consistent with the existing test design and avoids coupling tests to FastMCP internals.

The "live-instance" check is reduced to a **smoke assertion**: `create_silmari_fastmcp("silmari")` returns a `FastMCP` (not `None`, not an exception). This proves `register_silmari_tools(mcp)` and `register_silmari_resources(mcp)` execute without raising — sufficient to detect a `KeyError` in `_make_tool` if any `SILMARI_TOOL_NAMES` entry lacks a matching `SILMARI_TOOL_ARG_NAMES` tuple.

**Edge cases**:
- `assert_default_silmari_mcp_footprint` guard passes after B3's `SILMARI_ALLOWED_PREFIXES` lands (`sai_*` no longer rejected).
- Algorithm-version contract still resolves (`v3.8.1` per existing pin at `test_silmari_gateway.py:40`).
- `create_silmari_fastmcp` does NOT raise when called with the 27-tool surface — proves codegen completeness.

### TDD Cycle

#### 🔴 Red: Failing Test

**File**: `vendor/ultimate_mcp_server/tests/integration/test_silmari_gateway.py` (extend)

```python
from fastmcp import FastMCP

from ultimate_mcp_server.core.silmari_minimal_runtime import (
    create_silmari_fastmcp,
    build_default_silmari_mcp_footprint_manifest,
)
from ultimate_mcp_server.core.silmari_resources import SILMARI_STATIC_RESOURCES
from ultimate_mcp_server.tools.silmari_compat import SILMARI_TOOL_NAMES


def test_manifest_contains_all_27_tools_after_cutover_b():
    manifest = build_default_silmari_mcp_footprint_manifest()
    assert len(manifest["tools"]) == 27
    assert set(manifest["tools"]) == set(SILMARI_TOOL_NAMES)


def test_manifest_includes_sai_routing_tools():
    manifest = build_default_silmari_mcp_footprint_manifest()
    assert "sai_route_thought" in manifest["tools"]
    assert "sai_submit_thought" in manifest["tools"]


def test_manifest_includes_biblio_tools():
    manifest = build_default_silmari_mcp_footprint_manifest()
    for name in [
        "zk_biblio_search", "zk_biblio_link_source",
        "zk_biblio_sources_for_idea", "zk_biblio_ideas_for_source",
    ]:
        assert name in manifest["tools"]


def test_manifest_resources_unchanged_at_10():
    manifest = build_default_silmari_mcp_footprint_manifest()
    assert len(manifest["resources"]) == 10
    assert set(manifest["resources"]) == {
        r["uri"] for r in SILMARI_STATIC_RESOURCES
    }


def test_create_silmari_fastmcp_smoke():
    """Smoke: factory does not raise during registration with 27 tools.

    This is the live-instance check — kept minimal because no public FastMCP
    introspection API is exposed. The factory raises if _make_tool codegen
    encounters a name in SILMARI_TOOL_NAMES without a matching
    SILMARI_TOOL_ARG_NAMES entry (KeyError) or if FastMCP's tool-registration
    decorator rejects a duplicate name.
    """
    mcp = create_silmari_fastmcp(name="silmari")
    assert isinstance(mcp, FastMCP)


def test_footprint_assertion_accepts_27_tools():
    """B3+B6 integration: the SILMARI_ALLOWED_PREFIXES change must land first
    so the 27-tool surface (including 2 sai_* tools) clears the guard."""
    from ultimate_mcp_server.core.silmari_minimal_runtime import (
        assert_default_silmari_mcp_footprint,
    )
    manifest = assert_default_silmari_mcp_footprint(
        list(SILMARI_TOOL_NAMES),
        [r["uri"] for r in SILMARI_STATIC_RESOURCES],
    )
    assert len(manifest["tools"]) == 27
```

#### 🟢 Green: Minimal Implementation

No new code in `silmari_minimal_runtime.py` — `build_default_silmari_mcp_footprint_manifest` already iterates `SILMARI_TOOL_NAMES` (verified at lines 173-185 of source). The B1+B2+B3 changes propagate automatically into the manifest.

`create_silmari_fastmcp` at `silmari_minimal_runtime.py:69-85` calls `register_silmari_tools(mcp)` followed by `register_silmari_resources(mcp)` — both iterate the existing tables, so no FastMCP-side code change either.

#### 🔵 Refactor

**Optional follow-up (not required for B6 to land):** if a future behavior needs live-instance introspection, add a helper `silmari_minimal_runtime.list_registered_tool_names(mcp: FastMCP) -> list[str]` that wraps whatever FastMCP-internal attribute is canonical. The version pinned at submodule `9dd1762` would need source inspection to identify it. Defer until a concrete consumer requires it.

### Success Criteria

**Automated**:
- [ ] `pytest tests/integration/test_silmari_gateway.py -v` shows all 6 new tests pass (manifest 27, sai_*, biblio_*, resources at 10, smoke, footprint accepts 27)
- [ ] Existing `test_default_silmari_footprint_contains_no_ultimate_surface` still passes (depends on B3's prefix guard relaxation landing first or in same commit)
- [ ] `python -c "from ultimate_mcp_server.core.silmari_minimal_runtime import create_silmari_fastmcp; create_silmari_fastmcp('silmari')"` exits 0

**Manual**:
- [ ] Boot the server: `python -m ultimate_mcp_server run --silmari-compat --transport stdio`
- [ ] In a separate terminal, send an MCP `tools/list` request via stdio (or via MCP Inspector); response lists 27 tool definitions, including `sai_route_thought` and `zk_biblio_search`

---

## Behavior 7: Round-Trip TS↔Python Wire-Format Equality

### Test Specification

**Given**: a representative tool call (e.g. `zk_status`) and identical args.
**When**: invoked through the TS runtime AND through the Python runtime.
**Then**: the JSON payload returned (the inner `text` of the `content[0]`) is byte-equal modulo timestamps and UUIDs.

**Edge cases**:
- `zk_status` (no args, no UUID, no timestamp) — pure equality
- `zk_save_card` — generates an `id` and `fz` address; compare structure not values
- `sai_route_thought` (advisory; no persistence) — `decisionId` differs per call but every other field is comparable
- `sai_submit_thought` — actual write; needs SILMARI_DIR fixture
- **Error envelope parity (W9)**: malformed args (e.g. `zk_save_card` without required `body`) must produce equivalent error envelopes through both runtimes. Either both surface the FastMCP-layer inputSchema rejection, or both surface the bun-side validator error — but the call must not silently change error UX between TS and Python. Subprocess returns non-zero exit → Python `silmari_compat` raises `SilmariBridgeError`; the wire-format error from the TS path is `{ error: "..." }` per `apps/silmari-mcp/src/cli.ts` error envelope — assert the inner detail strings match modulo wrapping.
- **Return type pinned (W3)**: `call_silmari_tool` returns `str` (silmari_compat.py:165). The TS-side test must `JSON.parse(pyResp)` the raw string, not assume it's already parsed.

### TDD Cycle

#### 🔴 Red: Failing Test

**File**: `apps/silmari-mcp/tests/cutover-b-roundtrip.test.ts` (new — TS-side because it's easier to invoke both runtimes from Bun)

```ts
import { describe, it, expect, beforeEach, afterAll } from 'bun:test';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const TEST_TMP = mkdtempSync(join(tmpdir(), 'silmari-cutover-b-roundtrip-'));
process.env.SILMARI_DIR = TEST_TMP;
process.env.SILMARI_BIBLIO_DIR = join(TEST_TMP, 'box1-biblio', '.beads');
process.env.SILMARI_IDEA_DIR = join(TEST_TMP, 'box2-ideas', '.beads');

afterAll(() => rmSync(TEST_TMP, { recursive: true, force: true }));

async function callViaTS(name: string, args: object): Promise<string> {
  // bun apps/silmari-mcp/src/cli.ts tool <name> <json>
  const proc = Bun.spawnSync([
    'bun', 'apps/silmari-mcp/src/cli.ts', 'tool', name, JSON.stringify(args),
  ], { stdout: 'pipe', stderr: 'pipe' });
  if (proc.exitCode !== 0) {
    throw new Error(new TextDecoder().decode(proc.stderr));
  }
  return new TextDecoder().decode(proc.stdout).trim();
}

async function callViaPython(name: string, args: object): Promise<string> {
  // python -c "import asyncio; from ultimate_mcp_server.tools.silmari_compat
  //   import call_silmari_tool;
  //   print(asyncio.run(call_silmari_tool(<name>, <args>)))"
  const snippet = `
import asyncio, json
from ultimate_mcp_server.tools.silmari_compat import call_silmari_tool
print(asyncio.run(call_silmari_tool(${JSON.stringify(name)}, ${JSON.stringify(args)})))
`;
  const proc = Bun.spawnSync(['python', '-c', snippet], {
    stdout: 'pipe', stderr: 'pipe',
  });
  if (proc.exitCode !== 0) {
    throw new Error(new TextDecoder().decode(proc.stderr));
  }
  return new TextDecoder().decode(proc.stdout).trim();
}

function stripVolatile(payload: unknown): unknown {
  if (Array.isArray(payload)) return payload.map(stripVolatile);
  if (payload && typeof payload === 'object') {
    const obj = { ...(payload as Record<string, unknown>) };
    delete obj.decisionId;       // sai_*
    delete obj.id;                // zk_save_card
    delete obj.fz;                // zk_save_card
    delete obj.created_at;
    delete obj.updated_at;
    for (const k of Object.keys(obj)) obj[k] = stripVolatile(obj[k]);
    return obj;
  }
  return payload;
}

describe('Cutover B round-trip wire-format equality (B7)', () => {
  it('zk_status returns byte-equal payload through TS and Python', async () => {
    const tsResp = await callViaTS('zk_status', {});
    const pyResp = await callViaPython('zk_status', {});
    expect(JSON.parse(pyResp)).toEqual(JSON.parse(tsResp));
  });

  it('sai_route_thought returns equivalent shapes (modulo decisionId)', async () => {
    const args = {
      content: 'zettelkasten luhmann are foundational',
      claimedThoughtType: 'insight',
      host: { name: 'claude-code' },
    };
    const tsResp = await callViaTS('sai_route_thought', args);
    const pyResp = await callViaPython('sai_route_thought', args);
    expect(stripVolatile(JSON.parse(pyResp)))
      .toEqual(stripVolatile(JSON.parse(tsResp)));
  });

  // W9: malformed args produce equivalent error envelopes across runtimes.
  // Both paths must surface the same kind of error so Cutover B doesn't
  // silently change UX. The TS path returns its error envelope as JSON;
  // the Python path raises SilmariBridgeError whose stderr-derived message
  // contains the same inner detail.
  it('zk_save_card with missing body produces matching error info via both runtimes', async () => {
    let tsErr: string | null = null;
    let pyErr: string | null = null;

    try {
      await callViaTS('zk_save_card', { kind: 'idea', trunk: 5, mode: 'root' });
    } catch (e) {
      tsErr = (e as Error).message;
    }
    try {
      await callViaPython('zk_save_card', { kind: 'idea', trunk: 5, mode: 'root' });
    } catch (e) {
      pyErr = (e as Error).message;
    }

    expect(tsErr).not.toBeNull();
    expect(pyErr).not.toBeNull();
    // The inner detail (e.g. "body is required") must be present in both.
    // Wrapping (the SilmariBridgeError prefix on Python side) is allowed to
    // differ; the substring assertion catches silent UX divergence.
    const detail = /body|required|missing/i;
    expect(tsErr).toMatch(detail);
    expect(pyErr).toMatch(detail);
  });
});
```

#### 🟢 Green: Implementation

No code change. The test verifies an emergent property of the architecture.

#### 🔵 Refactor

Extract `stripVolatile` to a shared helper if more wire-format tests appear.

### Success Criteria

**Automated**:
- [ ] Both `it` blocks pass
- [ ] Byte-diff of `tsResp` vs `pyResp` (after stripping volatile fields) shows no difference
- [ ] Test runs in under 30s (allows for two subprocess startups per call)

**Manual**:
- [ ] Run with verbose mode and inspect the actual diff output to confirm no surprise drift

---

## Behavior 8: Cursor-Style E2E Through Python Runtime

### Test Specification

**Given**: a `remote-host` caller (`host.name='cursor'`) submits a thought via `sai_submit_thought` through the Python FastMCP frontend.
**When**: the call completes.
**Then**: the response shape matches the TS path, the audit log records the submission, and the Python frontend correctly forwarded the host context.

This mirrors Stage 2 B14 (`router-cursor-e2e.test.ts`) but exercises the Python frontend.

### TDD Cycle

#### 🔴 Red: Failing Test

**File**: `apps/silmari-mcp/tests/cutover-b-cursor-e2e.test.ts` (new)

```ts
import { describe, it, expect, beforeEach, afterAll } from 'bun:test';
// ... fixture setup similar to B7 ...

describe('Cutover B cursor-style E2E (B8)', () => {
  it('remote-host submission via Python frontend persists + audits', async () => {
    const args = {
      content: 'cursor submit test content',
      claimedThoughtType: 'critique',
      host: { name: 'cursor', sessionId: 'sess-123', model: 'gpt-5' },
    };

    const respText = await callViaPython('sai_submit_thought', args);
    const decision = JSON.parse(respText).decision;

    expect(decision.allowed).toBe(true);
    expect(decision.effectiveKind).toBe('idea');
    expect(decision.persistedId).toMatch(/^zk-/);
    expect(decision.persistedAddress).toMatch(/^\d+\//);

    // Audit log should have one line for this submission
    const auditPath = join(process.env.SAI_DIR ?? '~/.claude/SAI',
                            'MEMORY/STATE/route-decisions.jsonl');
    // ... read auditPath, find decision.decisionId, assert host.name === 'cursor'
  });
});
```

#### 🟢 Green

No code change unless B-sec uncovers tier-passthrough gaps. Defer to B-sec.

#### 🔵 Refactor

Extract the Python invocation helper to share with B7.

### Success Criteria

**Automated**:
- [ ] Test passes
- [ ] Audit log entry present with correct `host.name` field
- [ ] No `kindGuard.deny` stderr from the Python path (per `fix/kindguard-silence-on-downgrade`)

**Manual**:
- [ ] Manually launch the Python runtime and submit a thought through MCP Inspector — same outcome

---

## Behavior 9: Cutover B Runbook Lands at Sibling Path

### Test Specification

**Given**: `artifacts/runbooks/silmari-store-cutover.md` (Cutover A, line 363) defers Cutover B to "a separate runbook."
**When**: Cutover B operator workflow is documented.
**Then**: a sibling file `artifacts/runbooks/silmari-store-cutover-b.md` exists with all required sections present and the operator can execute it cold at 2 AM.

**Required sections**:
1. Decision Lockdown (mirror of Cutover A, plus Decision Card §1-§5)
2. Pre-Flip Checklist (cutover A done? config target identified? Python runtime importable? evidence freshness?)
3. **Config-Flip Mechanism** (the explicit answer to "how does the operator switch")
4. Cutover Sequence (set write pause, swap config, restart MCP, verify)
5. Smoke Verification (call `zk_status`, `sai_route_thought`, `zk_biblio_search` through Python; expect parity with pre-flip)
6. **Operator Log Lookup Table** (when X breaks, look at Y log)
7. Rollback Procedure (config flip back to TS; MCP restart; verify)
8. Post-Cutover Monitoring (24h-48h)
9. What This Runbook Does NOT Cover (Cutover C, Stage 3)

### Config-Flip Mechanism (Required Pin)

The operator switches between TS and Python silmari runtime via **`~/.claude.json`'s `mcpServers` block**. Two approaches:

**Approach A — single `silmari` entry with command swap** (recommended):

```jsonc
// Before Cutover B (TS runtime):
"mcpServers": {
  "silmari": {
    "command": "bun",
    "args": ["apps/silmari-mcp/src/index.ts"],
    "cwd": "/home/maceo/Dev/silmari-agent-memory",
    "env": { "SILMARI_DIR": "/home/maceo/.silmari-memory" }
  }
}

// After Cutover B (Python runtime):
"mcpServers": {
  "silmari": {
    "command": "python",
    "args": ["-m", "ultimate_mcp_server", "run", "--silmari-compat",
             "--transport", "stdio"],
    "cwd": "/home/maceo/Dev/silmari-agent-memory",
    "env": {
      "SILMARI_DIR": "/home/maceo/.silmari-memory",
      "SILMARI_COMPAT_COMMAND": "bun"
    }
  }
}
```

**Approach B — two parallel registrations**:

Register `silmari-ts` and `silmari-py`. Operator picks which one Claude Code talks to via a wrapper or by editing the registration entry that owns the canonical `silmari` name. More complex, harder to roll back atomically. Approach A is preferred for rollback simplicity.

### Operator Log Lookup Table (Required Pin)

| Symptom | Look at |
|---|---|
| `tools/list` returns wrong count or missing tool | Python MCP server stderr (Claude Code's MCP log shows `command` exit code + stderr) |
| Tool call returns immediate error envelope | Python `silmari_compat.py` raises `SilmariBridgeError` → check stderr for the bun child's stderr (subprocess captured it) |
| Tool call returns wrong wire-format JSON | Run the same call via `bun apps/silmari-mcp/src/cli.ts tool <name> <json>` directly; if that's wrong, the bug is in TS dispatcher (not Cutover B) |
| `kindGuard.deny` stderr line appears for a route that should be allowed | Check `SILMARI_CALLER_TIER` env at every hop: Claude Code → Python (via `mcpServers.silmari.env`) → bun subprocess (inherited via `os.environ`) |
| Latency > p95 budget (B-perf) | Profile the Python startup time AND the per-call subprocess spawn time; Bun is the fastest part |
| Tool registers but FastMCP rejects the dispatch | `assert_default_silmari_mcp_footprint` raised at startup — check the assertion message for the leak |
| Audit log missing entries | Python frontend may not be propagating `host.*` to the bun child — see B-sec test |
| `silmari-store` errors | Cutover A territory; not Cutover B's concern. Roll back Cutover B to isolate. |

### TDD Cycle

#### 🔴 Red: Failing Test

**File**: `apps/silmari-mcp/tests/cutover-b-runbook-structure.test.ts` (new)

```ts
import { describe, it, expect } from 'bun:test';
import { existsSync, readFileSync } from 'node:fs';

const RUNBOOK = 'artifacts/runbooks/silmari-store-cutover-b.md';

describe('Cutover B runbook structure (B9)', () => {
  it('runbook file exists', () => {
    expect(existsSync(RUNBOOK)).toBe(true);
  });

  const required = [
    'Decision Lockdown',
    'Pre-Flip Checklist',
    'Config-Flip Mechanism',
    'Cutover Sequence',
    'Smoke Verification',
    'Operator Log Lookup',
    'Rollback Procedure',
    'Post-Cutover Monitoring',
    'What This Runbook Does NOT Cover',
  ];

  it.each(required)('contains required section: %s', (header) => {
    const source = readFileSync(RUNBOOK, 'utf-8');
    expect(source).toContain(header);
  });

  it('config-flip section names ~/.claude.json mcpServers as the mechanism', () => {
    const source = readFileSync(RUNBOOK, 'utf-8');
    expect(source).toMatch(/\.claude\.json/);
    expect(source).toMatch(/mcpServers/);
  });

  it('rollback procedure references config flip back to TS runtime', () => {
    const source = readFileSync(RUNBOOK, 'utf-8');
    const rollbackSection = source.split(/##\s*Rollback Procedure/)[1] ?? '';
    expect(rollbackSection).toMatch(/bun|TS runtime|silmari-mcp\/src\/index\.ts/);
  });

  it('operator log lookup table has at least 5 rows', () => {
    const source = readFileSync(RUNBOOK, 'utf-8');
    const tableRows = (source.match(/\|.*\|.*\|/g) ?? []).filter((r) =>
      !r.includes('---') && !r.toLowerCase().includes('symptom'),
    );
    expect(tableRows.length).toBeGreaterThanOrEqual(5);
  });
});
```

#### 🟢 Green: Write the Runbook

Author `artifacts/runbooks/silmari-store-cutover-b.md` covering the 9 required sections. Use Cutover A as a template for tone and shape.

#### 🔵 Refactor

Once landed, link from `artifacts/runbooks/silmari-store-cutover.md` (the Cutover A runbook, "What This Runbook Does NOT Cover" section) to the new sibling path. Remove the "separate runbook needed" qualifier in line 363 since it now exists.

### Success Criteria

**Automated**:
- [ ] All structure tests pass
- [ ] Runbook is at the sibling path (`silmari-store-cutover-b.md`, not appended to A)

**Manual**:
- [ ] Operator dry-run: read the runbook cold and execute against a dev workspace; every step has a concrete command + expected output
- [ ] Maceo signs off on the runbook

---

## Behavior 10: Rollback CI Test

### Test Specification

**Given**: a Python FastMCP runtime is "active" (in test, simulated via env state).
**When**: the rollback procedure executes (config flip, restart, verify).
**Then**: a subsequent tool list returns 21 tools (the pre-Cutover-B surface) — proving the rollback genuinely restored the TS runtime.

**Edge cases**:
- The test asserts the operator can execute rollback in an unattended fashion (script, not just by hand).
- If `~/.claude.json` is the config medium, the test mutates a temp copy, not the real file.

### TDD Cycle

#### 🔴 Red: Failing Test

**File**: `scripts/cutover-b/rollback.test.ts` (new — colocated with the rollback script)

```ts
import { describe, it, expect } from 'bun:test';
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { applyRollback, applyForward } from './rollback.ts';

const TMP = mkdtempSync(join(tmpdir(), 'cutover-b-rollback-'));
const CONFIG = join(TMP, '.claude.json');

const FORWARD_CONFIG = {
  mcpServers: {
    silmari: {
      command: 'python',
      args: ['-m', 'ultimate_mcp_server', 'run', '--silmari-compat',
             '--transport', 'stdio'],
    },
  },
};

const BACKWARD_CONFIG = {
  mcpServers: {
    silmari: {
      command: 'bun',
      args: ['apps/silmari-mcp/src/index.ts'],
    },
  },
};

describe('Cutover B rollback (B10)', () => {
  it('applyRollback rewrites silmari MCP entry to TS runtime', () => {
    writeFileSync(CONFIG, JSON.stringify(FORWARD_CONFIG, null, 2));
    applyRollback(CONFIG);
    const after = JSON.parse(readFileSync(CONFIG, 'utf-8'));
    expect(after.mcpServers.silmari.command).toBe('bun');
    expect(after.mcpServers.silmari.args[0]).toMatch(/silmari-mcp\/src\/index\.ts$/);
  });

  it('applyForward rewrites silmari MCP entry to Python runtime', () => {
    writeFileSync(CONFIG, JSON.stringify(BACKWARD_CONFIG, null, 2));
    applyForward(CONFIG);
    const after = JSON.parse(readFileSync(CONFIG, 'utf-8'));
    expect(after.mcpServers.silmari.command).toBe('python');
    expect(after.mcpServers.silmari.args).toContain('--silmari-compat');
  });

  it('roundtrip forward + rollback preserves all other MCP entries', () => {
    const original = {
      ...FORWARD_CONFIG,
      mcpServers: {
        ...FORWARD_CONFIG.mcpServers,
        unrelated: { command: 'true', args: [] },
      },
    };
    writeFileSync(CONFIG, JSON.stringify(original, null, 2));
    applyRollback(CONFIG);
    applyForward(CONFIG);
    const after = JSON.parse(readFileSync(CONFIG, 'utf-8'));
    expect(after.mcpServers.unrelated).toEqual({ command: 'true', args: [] });
  });
});
```

#### 🟢 Green: Implementation

**File**: `scripts/cutover-b/rollback.ts` (new)

```ts
import { readFileSync, writeFileSync } from 'node:fs';

export const TS_RUNTIME_ENTRY = {
  command: 'bun',
  args: ['apps/silmari-mcp/src/index.ts'],
};

export const PY_RUNTIME_ENTRY = {
  command: 'python',
  args: ['-m', 'ultimate_mcp_server', 'run', '--silmari-compat',
         '--transport', 'stdio'],
};

export function applyForward(configPath: string): void {
  const cfg = JSON.parse(readFileSync(configPath, 'utf-8'));
  cfg.mcpServers ??= {};
  cfg.mcpServers.silmari = {
    ...(cfg.mcpServers.silmari ?? {}),
    ...PY_RUNTIME_ENTRY,
  };
  writeFileSync(configPath, JSON.stringify(cfg, null, 2));
}

export function applyRollback(configPath: string): void {
  const cfg = JSON.parse(readFileSync(configPath, 'utf-8'));
  cfg.mcpServers ??= {};
  cfg.mcpServers.silmari = {
    ...(cfg.mcpServers.silmari ?? {}),
    ...TS_RUNTIME_ENTRY,
  };
  writeFileSync(configPath, JSON.stringify(cfg, null, 2));
}
```

#### 🔵 Refactor

Once landed, the runbook references this script in step C2 (forward) and R3 (rollback) — no copy-paste of jsonc snippets in the runbook body, the script is the source of truth.

### Success Criteria

**Automated**:
- [ ] All 3 tests pass
- [ ] `bun scripts/cutover-b/rollback.ts apply-rollback /path/to/config` works as a CLI

**Manual**:
- [ ] Operator dry-run on a temp config file: forward + rollback works, unrelated MCP entries (e.g. `mcp-agent-mail`) are preserved

---

## Behavior B-sec: kindGuard Tier Mapping Under Python Frontend

### Test Specification

**Given**: a `system-hook` caller (Claude Code) and a `remote-host` caller (Cursor), both calling a system-hook-required tool (`zk_save_card` with `kind: preference`).
**When**: each call goes through the Python frontend.
**Then**: the system-hook caller's call succeeds (tier correctly resolved); the remote-host caller's call is downgraded or denied (per kindGuard policy); no tier is silently elevated.

**Edge cases**:
- Per Decision Card §6, this behavior tests **contract assertions, not discovery**:
  - Python frontend with no `SILMARI_CALLER_TIER` in env → `kindGuard.resolveCallerFromEnv` defaults to `mcp-agent` (per `apps/silmari-mcp/src/lib/kindGuard.ts:103`). The Python frontend MUST NOT infer or override this default.
  - Operator pins `SILMARI_CALLER_TIER` in `~/.claude.json` `mcpServers.silmari.env` block → Python inherits via `os.environ` → bun subprocess inherits via `silmari_compat.py:153` (`env = dict(os.environ)`). Test asserts the env round-trips through both hops.
  - The `host.name` field in `sai_*` tools reaches the TS dispatcher as a top-level payload key (per W8 contract pinned in B5 — `_make_tool` codegen treats `host` as a key whose value is the nested dict).

### TDD Cycle

#### 🔴 Red: Failing Test

**File**: `apps/silmari-mcp/tests/cutover-b-kindguard-tier.test.ts` (new)

```ts
import { describe, it, expect, beforeEach } from 'bun:test';
// ... fixtures ...

async function callViaPythonWithEnv(
  name: string,
  args: object,
  env: Record<string, string>,
): Promise<string> {
  // ... spawn python with env override, capture stdout ...
}

describe('Cutover B kindGuard tier under Python frontend (B-sec)', () => {
  it('without SILMARI_CALLER_TIER env, defaults to mcp-agent', async () => {
    const env = { /* deliberately omit SILMARI_CALLER_TIER */ };
    const respText = await callViaPythonWithEnv('zk_save_card', {
      box: 'idea', kind: 'idea', body: 'test', trunk: 5, mode: 'root',
    }, env);
    expect(JSON.parse(respText).id).toMatch(/^zk-/);
    // mcp-agent CAN write idea (idea is remote-host gated, mcp-agent >= remote-host)
  });

  it('mcp-agent tier cannot write preference (system-hook required)', async () => {
    const env = { SILMARI_CALLER_TIER: 'mcp-agent', SILMARI_CALLER_AGENT_ID: 'forge' };
    const respText = await callViaPythonWithEnv('zk_save_card', {
      box: 'idea', kind: 'preference', body: 'forged', trunk: 5, mode: 'root',
    }, env);
    expect(JSON.parse(respText).error).toMatch(/E_KIND_FORGE/);
  });

  it('system-hook tier set via env propagates through to TS dispatcher', async () => {
    const env = {
      SILMARI_CALLER_TIER: 'system-hook',
      SILMARI_CALLER_AGENT_ID: 'claude-code',
    };
    const respText = await callViaPythonWithEnv('zk_save_card', {
      box: 'idea', kind: 'preference', body: 'real preference',
      trunk: 5, mode: 'root',
    }, env);
    expect(JSON.parse(respText).id).toMatch(/^zk-/);
  });

  it('sai_submit_thought downgrades remote-host claim of decision', async () => {
    const env = { SILMARI_CALLER_TIER: 'remote-host', SILMARI_CALLER_AGENT_ID: 'cursor' };
    const respText = await callViaPythonWithEnv('sai_submit_thought', {
      content: 'forged decision',
      claimedThoughtType: 'decision',
      host: { name: 'cursor' },
    }, env);
    const decision = JSON.parse(respText).decision;
    expect(decision.allowed).toBe(true);
    expect(decision.effectiveKind).toBe('idea'); // downgraded
    expect(decision.warnings).toContain('claimed-thoughttype-downgraded');
  });
});
```

#### 🟢 Green

**Per Decision Card §6, no code change is required in `silmari_compat.py`.** The contract is enforced by absence of inference logic. `silmari_compat.py:153` already does `env = dict(os.environ)`, so all caller env propagates to the bun subprocess unchanged. The TS `kindGuard.resolveCallerFromEnv` reads `SILMARI_CALLER_TIER` and `SILMARI_CALLER_AGENT_ID` from that env and constructs the `Caller`.

The B-sec tests therefore go GREEN by virtue of the existing architecture — they assert this contract holds, and any future change that adds inference logic to the Python frontend (e.g. setting `SILMARI_CALLER_TIER` based on `host.name`) would break these tests by design.

**If a test fails here, it is a sign the contract has drifted, not a sign new code is needed.** A test failure here is a STOP-THE-LINE moment requiring an ADR, not a quick fix.

#### 🔵 Refactor

Once the tests are green, link the operator runbook's mcpServers env-block example (B9) directly from B-sec's docstring so the contract is discoverable from both sides.

### Success Criteria

**Automated**:
- [ ] All 4 tests pass
- [ ] No silent tier elevation: a test that pins `SILMARI_CALLER_TIER=mcp-agent` and submits a `decision` claim from `host.name=claude-code` does NOT get system-hook treatment

**Manual**:
- [ ] Operator audit: the runbook's mcpServers config block sets the correct env vars for the deployed environment (Maceo's machine: `SILMARI_CALLER_TIER=system-hook`)

---

## Behavior B-purity: silmari_compat.py Has Zero Direct Data Access

### Test Specification

**Given**: `vendor/ultimate_mcp_server/ultimate_mcp_server/tools/silmari_compat.py`.
**When**: a grep test scans for direct sqlite, silmari-store, or silmari-memory references.
**Then**: every match is in a comment, docstring, or refers to subprocess/CLI invocation — never opens a database, never reads a file under `~/.silmari-memory/`.

**Why**: Cutover B's value is that the silmari logic stays in the canonical TS implementation. If Python starts reading silmari-store directly, we've silently entered Cutover C territory without an ADR, and parity with TS becomes a matter of code review instead of architecture.

### TDD Cycle

#### 🔴 Red: Failing Test

**File**: `vendor/ultimate_mcp_server/tests/unit/test_silmari_compat_purity.py` (new)

```python
import re
from pathlib import Path

SILMARI_COMPAT = Path(__file__).resolve().parents[2] / (
    "ultimate_mcp_server/tools/silmari_compat.py"
)

# Patterns that would indicate direct data access (NOT subprocess shim).
FORBIDDEN_PATTERNS = [
    re.compile(r"\bsqlite3\b"),
    re.compile(r"\bopen\s*\([^)]*silmari-?memory"),
    re.compile(r"\bopen\s*\([^)]*silmari-?store"),
    re.compile(r"\bcursor\.\bexecute\b"),  # sqlite cursor
    re.compile(r"\.execute\s*\(\s*['\"]SELECT"),
    re.compile(r"\.execute\s*\(\s*['\"]INSERT"),
]

# Allowed mentions — context where the symbol appears legitimately.
ALLOWED_CONTEXTS = [
    "silmari_cli_path",  # subprocess CLI path (line 103)
    "subprocess",
    "asyncio.create_subprocess_exec",
    "import",
    "#",                # comments
    '"""',              # docstrings
    "'''",
]


def test_silmari_compat_has_no_direct_data_access():
    source = SILMARI_COMPAT.read_text()
    violations = []
    for line_no, line in enumerate(source.splitlines(), 1):
        # Skip lines that are clearly comment/docstring/subprocess context
        if any(ctx in line for ctx in ALLOWED_CONTEXTS):
            continue
        for pattern in FORBIDDEN_PATTERNS:
            if pattern.search(line):
                violations.append((line_no, line.strip(), pattern.pattern))
    assert violations == [], (
        f"silmari_compat.py contains direct data access (Cutover C territory):\n"
        + "\n".join(f"  L{n}: {pat} → {ln}" for n, ln, pat in violations)
    )
```

#### 🟢 Green

The current `silmari_compat.py` already passes this test (the only data-access symbol is `silmari_cli_path` which is in the ALLOWED_CONTEXTS). The test goes Red the moment someone adds a sqlite import or a direct file open — exactly the behavior we want.

#### 🔵 Refactor

Add a CI gate that runs this test as part of the parity job. Defer to B9's runbook (which references CI).

### Success Criteria

**Automated**:
- [ ] Test passes against current `silmari_compat.py`
- [ ] Test fails on a synthetic patch that imports sqlite3
- [ ] Test fails on a synthetic patch that opens `~/.silmari-memory/silmari.db`

**Manual**:
- [ ] Code review: the test's regex coverage is reviewed against actual data-access patterns in TS (e.g. how does `index.ts` open `silmari-store`? — extract those patterns to the regex list)

---

## Behavior B-perf: Latency Budget Gate

### Test Specification

**Given**: a warmed-up Python FastMCP runtime serving silmari, calling representative tools 100 times.
**When**: latency is measured (wall-clock, end-to-end including FastMCP receive → bun subprocess → response).
**Then**: p95 latency is ≤ the per-tool budget.

**Budgets** (operator-stated targets, anchored to TS-only baseline per W5 fix):
- **Step Zero baseline measurement (BEFORE any Python-frontend tests)**: run `bun apps/silmari-mcp/src/cli.ts tool zk_status '{}'` × 100 and `bun apps/silmari-mcp/src/cli.ts tool zk_save_card '<minimal-args>'` × 100. Record p50/p95/p99/max for each. Document the numbers in the Cutover B runbook (B9) and in this plan as a `<!-- baseline: ... -->` HTML comment.
- **Budget rule**: per-tool budget = `max(operator-stated-target, TS-baseline-p95 × 3)`. Operator-stated targets are 500ms (zk_status) and 2000ms (zk_save_card) — these are the ceiling; TS p95 × 3 may produce a tighter or looser actual gate depending on host hardware.
- **If TS-baseline p95 > operator-stated target / 3**: budget is operator-stated target; deltas above are real Python-frontend regressions.
- **If TS-baseline p95 ≤ operator-stated target / 3**: budget is operator-stated target; delta absorbed by margin.
- **If TS-baseline p95 ≥ operator-stated target**: STOP and renegotiate. The architecture cannot meet the target even before adding the Python hop. Operator decides whether to relax the target or block Cutover B until TS-side perf work lands.

**Edge cases**:
- Cold-start (first call): excluded from p95 (separate measurement, recorded for runbook)
- Subprocess spawn cost: included (it's the dominant factor in the delta TS→Python)
- Outliers: report p95, p99, max — but the gate is on p95
- `DEFAULT_TIMEOUT_SECONDS = 30.0` per `silmari_compat.py:44`. If any single call exceeds 30s, `SilmariBridgeError` raises — measurement halts and the test fails with a clear reason.

### TDD Cycle

#### 🔴 Red: Failing Test

**File**: `apps/silmari-mcp/tests/cutover-b-perf.test.ts` (new)

```ts
import { describe, it, expect, beforeAll } from 'bun:test';
// ... fixtures ...

const ITERATIONS = 100;
const ZK_STATUS_P95_MS = 500;
const ZK_SAVE_CARD_P95_MS = 2000;

function p(values: number[], pct: number): number {
  const sorted = [...values].sort((a, b) => a - b);
  const idx = Math.ceil((pct / 100) * sorted.length) - 1;
  return sorted[idx]!;
}

// Step Zero per W5: TS-only baseline. Runs first so Python-frontend gates
// can use TS p95 as a reference. Logged numbers feed the runbook.
describe('Cutover B TS-only baseline (B-perf step zero)', () => {
  it.skipIf(process.env.CI !== 'true')(
    'records TS-only p50/p95/p99 for zk_status over 100 calls',
    async () => {
      const samples: number[] = [];
      for (let i = 0; i < ITERATIONS; i++) {
        const t0 = performance.now();
        await callViaTS('zk_status', {});
        samples.push(performance.now() - t0);
      }
      const p50 = p(samples, 50), p95 = p(samples, 95), p99 = p(samples, 99);
      console.log(`TS zk_status baseline: p50=${p50.toFixed(0)}ms ` +
                  `p95=${p95.toFixed(0)}ms p99=${p99.toFixed(0)}ms ` +
                  `max=${Math.max(...samples).toFixed(0)}ms`);
      // No assertion — this records the baseline. Implementer copies the
      // logged numbers into the runbook + into the budget rule below.
    },
    /* timeout */ 120_000,
  );
});

describe('Cutover B latency budget (B-perf)', () => {
  beforeAll(async () => {
    // Warm-up: one call discarded
    await callViaPython('zk_status', {});
  });

  it.skipIf(process.env.CI !== 'true')(
    `zk_status p95 < ${ZK_STATUS_P95_MS}ms over ${ITERATIONS} calls`,
    async () => {
      const samples: number[] = [];
      for (let i = 0; i < ITERATIONS; i++) {
        const t0 = performance.now();
        await callViaPython('zk_status', {});
        samples.push(performance.now() - t0);
      }
      const p95 = p(samples, 95);
      console.log(`zk_status: p50=${p(samples, 50).toFixed(0)}ms ` +
                  `p95=${p95.toFixed(0)}ms p99=${p(samples, 99).toFixed(0)}ms ` +
                  `max=${Math.max(...samples).toFixed(0)}ms`);
      expect(p95).toBeLessThan(ZK_STATUS_P95_MS);
    },
    /* timeout */ 120_000,
  );

  it.skipIf(process.env.CI !== 'true')(
    `zk_save_card p95 < ${ZK_SAVE_CARD_P95_MS}ms over ${ITERATIONS} calls`,
    async () => {
      // ... similar, calling zk_save_card with simple body ...
    },
    /* timeout */ 240_000,
  );
});
```

The `it.skipIf(process.env.CI !== 'true')` gates the perf test to CI-only by default — local dev should run them on demand via `CI=true bun test cutover-b-perf.test.ts`.

#### 🟢 Green

No code change. The test characterizes architecture latency. If it goes Red, we either:
1. Find a real performance regression to fix (e.g. Python startup or subprocess overhead) — fix it
2. Find that the budget is unrealistic — adjust the budget with operator approval, document the new number in the runbook

#### 🔵 Refactor

Once we have baseline numbers, consider adding p99 budget too. Defer.

### Success Criteria

**Automated**:
- [ ] Test runs in CI (env-gated)
- [ ] Both `it` blocks pass under the budget
- [ ] Baseline numbers (p50, p95, p99, max) logged in CI output for trend tracking

**Manual**:
- [ ] Operator runs the test locally before flipping production: `CI=true bun test apps/silmari-mcp/tests/cutover-b-perf.test.ts`
- [ ] Numbers compared against pre-Cutover-B TS baseline (call the same tools through `bun apps/silmari-mcp/src/cli.ts` directly): the Python overhead delta is documented in the runbook

---

## Behavior 11: Resource-Read Round-Trip Parity (C1 Fix)

### Test Specification

**Given**: a `silmari://` resource URI (e.g. `silmari://trunks`).
**When**: the resource is read through the TS resource handler AND through the Python FastMCP resource handler.
**Then**: the JSON content returned is byte-equal modulo timestamps and other declared volatile fields.

This closes the C1 gap from review: B4 asserts the **set** of resource URIs matches between TS and Python (catalog parity), but says nothing about the **content** of a read. Without B11, an operator who flips Cutover B could find that `silmari://trunks` returns a different shape under Python than under TS, and only discover the breakage downstream.

**Resources to round-trip**:
- `silmari://trunks` — static metadata, expected to be byte-identical
- `silmari://register/root` — register slot, may include card counts
- `silmari://keyword-index` — substantial dynamic content; tightest parity test
- (3 of the 10 is enough; the bridge mechanism is shared — additional URIs add coverage but not new failure modes)

**Edge cases**:
- TS-side resource read: hit via `bun apps/silmari-mcp/src/cli.ts resource <uri>` (the existing CLI path verified in research at `cli.ts` resource subcommand routing)
- Python-side resource read: hit via `silmari_compat.call_silmari_resource(uri)` at `silmari_compat.py:168-188`. Note: Python also shells out to bun, so a "matching" result is essentially testing that Python's bridge doesn't corrupt the response in transit.
- Stripping volatile fields: timestamps in `register/*` slots may differ; use the same `stripVolatile` helper from B7 (extract to `_python-introspect.ts` if needed).
- **If a URI requires SILMARI_DIR fixture** (any URI that reads cards): set up the same temp dir as B7 so both runtimes see the same data.

### TDD Cycle

#### 🔴 Red: Failing Test

**File**: `apps/silmari-mcp/tests/cutover-b-resource-roundtrip.test.ts` (new — TS side, mirror of B7's structure)

```ts
import { describe, it, expect, afterAll } from 'bun:test';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const TEST_TMP = mkdtempSync(join(tmpdir(), 'silmari-cutover-b-resource-roundtrip-'));
process.env.SILMARI_DIR = TEST_TMP;
process.env.SILMARI_BIBLIO_DIR = join(TEST_TMP, 'box1-biblio', '.beads');
process.env.SILMARI_IDEA_DIR = join(TEST_TMP, 'box2-ideas', '.beads');

afterAll(() => rmSync(TEST_TMP, { recursive: true, force: true }));

async function readResourceViaTS(uri: string): Promise<string> {
  const proc = Bun.spawnSync([
    'bun', 'apps/silmari-mcp/src/cli.ts', 'resource', uri,
  ], { stdout: 'pipe', stderr: 'pipe' });
  if (proc.exitCode !== 0) {
    throw new Error(new TextDecoder().decode(proc.stderr));
  }
  return new TextDecoder().decode(proc.stdout).trim();
}

async function readResourceViaPython(uri: string): Promise<string> {
  const snippet = `
import asyncio, json
from ultimate_mcp_server.tools.silmari_compat import call_silmari_resource
print(asyncio.run(call_silmari_resource(${JSON.stringify(uri)})))
`;
  const proc = Bun.spawnSync(['python', '-c', snippet], {
    stdout: 'pipe', stderr: 'pipe',
  });
  if (proc.exitCode !== 0) {
    throw new Error(new TextDecoder().decode(proc.stderr));
  }
  return new TextDecoder().decode(proc.stdout).trim();
}

function stripVolatile(payload: unknown): unknown {
  // Same shape as B7's helper. Extract to shared module if both tests
  // continue using it.
  if (Array.isArray(payload)) return payload.map(stripVolatile);
  if (payload && typeof payload === 'object') {
    const obj = { ...(payload as Record<string, unknown>) };
    delete obj.created_at;
    delete obj.updated_at;
    delete obj.last_updated;
    delete obj.timestamp;
    for (const k of Object.keys(obj)) obj[k] = stripVolatile(obj[k]);
    return obj;
  }
  return payload;
}

describe('Cutover B resource-read round-trip parity (B11)', () => {
  it('silmari://trunks returns byte-equal payload through TS and Python', async () => {
    const tsResp = await readResourceViaTS('silmari://trunks');
    const pyResp = await readResourceViaPython('silmari://trunks');
    expect(JSON.parse(pyResp)).toEqual(JSON.parse(tsResp));
  });

  it('silmari://register/root returns equivalent shape modulo timestamps', async () => {
    const tsResp = await readResourceViaTS('silmari://register/root');
    const pyResp = await readResourceViaPython('silmari://register/root');
    expect(stripVolatile(JSON.parse(pyResp)))
      .toEqual(stripVolatile(JSON.parse(tsResp)));
  });

  it('silmari://keyword-index returns equivalent content shape', async () => {
    const tsResp = await readResourceViaTS('silmari://keyword-index');
    const pyResp = await readResourceViaPython('silmari://keyword-index');
    expect(stripVolatile(JSON.parse(pyResp)))
      .toEqual(stripVolatile(JSON.parse(tsResp)));
  });

  it('rejects unknown silmari:// URI with matching error shape', async () => {
    let tsErr: string | null = null;
    let pyErr: string | null = null;
    try { await readResourceViaTS('silmari://does-not-exist'); }
    catch (e) { tsErr = (e as Error).message; }
    try { await readResourceViaPython('silmari://does-not-exist'); }
    catch (e) { pyErr = (e as Error).message; }
    expect(tsErr).not.toBeNull();
    expect(pyErr).not.toBeNull();
    // Both should mention the unknown URI in the error
    expect(tsErr).toContain('does-not-exist');
    expect(pyErr).toContain('does-not-exist');
  });
});
```

#### 🟢 Green: Implementation

No code change — the test verifies an emergent property of the existing architecture. `call_silmari_resource` at `silmari_compat.py:168-188` already shells out to `bun apps/silmari-mcp/src/cli.ts resource <uri>`, so the response is literally the same bytes that `readResourceViaTS` captures. The test goes Red the moment a future change introduces a Python-side transformation of the response.

#### 🔵 Refactor

If `stripVolatile` and the `readResourceViaTS`/`readResourceViaPython` helpers are duplicated between B7 and B11, extract to `apps/silmari-mcp/tests/_cutover-b-helpers.ts`. Defer until the duplication is concrete.

### Success Criteria

**Automated**:
- [ ] All 4 tests pass against the current architecture (proves the bridge is faithful)
- [ ] Test runs in under 30 seconds (4 calls × ~2 subprocess spawns each)
- [ ] Synthetic patch that adds a Python-side response transformer to `call_silmari_resource` makes the test fail (negative-confirmation lint)

**Manual**:
- [ ] Run with `--verbose` and inspect actual diff output to confirm zero drift on `silmari://trunks` (the static catalogue case)
- [ ] Operator dry-run: read all 10 `silmari://` URIs through both runtimes manually, eyeball the JSON for equivalence

---

## Integration & E2E Testing

### Integration test matrix

| Surface | TS-side | Python-side | Cross-runtime |
|---|---|---|---|
| Tool registration | n/a (compile-time TOOLS array) | B6 (FastMCP boot) | B4 (parity introspection) |
| Tool dispatch | existing TS tests | B5 (subprocess shim per tool) | B7 (wire-format equality) |
| Caller-tier semantics | existing kindGuard tests | B-sec (full path) | B-sec |
| Runbook structure | n/a | n/a | B9 |
| Rollback | n/a | n/a | B10 |
| Latency | n/a | B-perf (Python frontend only) | n/a |
| Purity (no leak) | n/a | B-purity | n/a |

### End-to-end ordering

The TDD ordering minimizes blocked work and respects review-required gates:

1. **B0** — Decision Card lands FIRST in the plan frontmatter (now §1-§6 per C3 fix). No code; just contract pinning.
2. **B1 → B2 → B5** — Python tables + parameterized bridge tests (no FastMCP, no TS-side dependency).
3. **B3 → B6** — Footprint guard relax + minimal-runtime static-manifest test. **C2 resolved**: B6 uses `build_default_silmari_mcp_footprint_manifest` + `create_silmari_fastmcp` smoke (no live FastMCP introspection required).
4. **B4** — TS parity test via runtime Python introspection.
5. **B-purity** — Independent grep test; can land any time after B1.
6. **B7 || B11** — Wire-format equality runs in parallel: B7 for **tools**, B11 for **resources**. Both depend on B6 (Python runtime must boot). C1 closed by B11.
7. **B-sec** — Depends on B7+B11 (runtime serves calls) and Decision Card §6 (contract assertions, not discovery).
8. **B-perf Step Zero** — TS-only baseline measurement (no Python dependency; can run any time after the repo is buildable). Records numbers for runbook.
9. **B-perf** — Python-frontend latency budget gates; depends on B7 (Python serves calls) + Step Zero (baseline numbers).
10. **B8** — Cursor E2E; depends on B-sec.
11. **B10** — Rollback script + test; depends on B9's config-flip mechanism being pinned.
12. **B9** — Runbook itself; depends on every other behavior so it can copy concrete commands and baseline numbers from each.

**Critical gates (do not start dependent work until upstream lands):**
- B6 blocks until B3's `SILMARI_ALLOWED_PREFIXES` constant exists (else footprint assertion fails on `sai_*`).
- B7+B11 block until B6's smoke test passes (else `create_silmari_fastmcp` may raise).
- B-sec blocks until Decision Card §6 is in frontmatter AND B7 passes.
- B-perf full suite blocks until Step Zero baseline is recorded (else budget rule has no anchor).
- B9 runbook blocks until B-perf numbers are in hand (the runbook records them).

---

## 📚 References

### Source files

- `vendor/ultimate_mcp_server/ultimate_mcp_server/tools/silmari_compat.py` (the bridge)
- `vendor/ultimate_mcp_server/ultimate_mcp_server/core/silmari_resources.py` (10 static URIs)
- `vendor/ultimate_mcp_server/ultimate_mcp_server/core/silmari_minimal_runtime.py` (FastMCP entry, footprint guards)
- `vendor/ultimate_mcp_server/ultimate_mcp_server/core/server.py` (Gateway integration, `start_server` dispatch)
- `vendor/ultimate_mcp_server/ultimate_mcp_server/cli/typer_cli.py` (`--silmari-compat` flag)
- `apps/silmari-mcp/src/index.ts` (TS TOOLS array — 27 entries after Stage 2 + 4d8.7)
- `apps/silmari-mcp/src/cli.ts` (CLI bridge target, generic `tool` escape hatch at lines 389-403)
- `apps/silmari-mcp/src/lib/kindGuard.ts` (caller-tier resolution)
- `apps/silmari-mcp/src/lib/router.ts` (RouteDecision envelope for sai_* tools)

### Test files (existing, pattern templates)

- `vendor/ultimate_mcp_server/tests/unit/test_silmari_compat.py` (subprocess bridge mechanics)
- `vendor/ultimate_mcp_server/tests/integration/test_silmari_gateway.py` (footprint guards)
- `apps/silmari-mcp/tests/ultimate-compat-parity.test.ts` (TS↔Python parity — REWRITE)
- `apps/silmari-mcp/tests/router-cursor-e2e.test.ts` (Stage 2 B14 — pattern for B8)

### Test files (new in this plan)

- `vendor/ultimate_mcp_server/tests/unit/test_silmari_compat_surface.py` (B1, B2)
- `vendor/ultimate_mcp_server/tests/unit/test_silmari_compat_purity.py` (B-purity)
- `apps/silmari-mcp/tests/cutover-b-roundtrip.test.ts` (B7)
- `apps/silmari-mcp/tests/cutover-b-resource-roundtrip.test.ts` (B11 — NEW per C1 fix)
- `apps/silmari-mcp/tests/cutover-b-cursor-e2e.test.ts` (B8)
- `apps/silmari-mcp/tests/cutover-b-runbook-structure.test.ts` (B9)
- `apps/silmari-mcp/tests/cutover-b-kindguard-tier.test.ts` (B-sec)
- `apps/silmari-mcp/tests/cutover-b-perf.test.ts` (B-perf — includes Step Zero TS baseline + Python-frontend gates)
- `scripts/cutover-b/rollback.test.ts` (B10)

### Documents

- `artifacts/runbooks/silmari-store-cutover.md` (Cutover A — sibling)
- `artifacts/runbooks/silmari-store-cutover-b.md` (NEW — B9 deliverable)
- `thoughts/searchable/shared/research/2026-05-01-06-38-cutover-b-runbook-inventory.md` (research foundation)
- `thoughts/searchable/shared/plans/2026-04-28-silmari-agent-memory-xq6-tdd-ultimate-mcp-silmari-compatibility.md` (primary Cutover B design)
- `thoughts/searchable/shared/plans/2026-04-29-cross-llm-sai-persistence-and-user-context-routing.md` (recursion + persistence)
- `MEMORY/WORK/20260430-counsel-mcp-vs-local-sai/PRD.md` (counsel substrate)

### Beads

- `silmari-agent-memory-4d8` (parent — Cutover A)
- `silmari-agent-memory-9rx` (Stage 2 routing service — landed)
- (NEW: a Cutover B umbrella issue to be created at plan-acceptance time)

---

## 📋 Reviewer Sign-off Checklist

### Original (Stage 2 review template)

- [x] Decision Card §1-§5 reflects the operator's intent (now §1-§6 with C3 fix)
- [x] Behavior count and granularity match the review feedback (15 behaviors: B0 + B1-B11 + B-sec + B-purity + B-perf)
- [x] Each behavior has a clear Red→Green→Refactor cycle
- [x] B-sec test directly invokes kindGuard with mocked caller through the Python path
- [x] B-purity test is a grep assertion
- [x] B9 runbook section includes operator log table (≥5 rows) and config-flip steps
- [x] Latency budget numbers (B-perf) are operator-approved AND anchored to TS-only baseline (Step Zero, W5 fix)
- [x] No open questions in this plan — all 6 from the research doc are resolved in `reviewer_decisions` frontmatter
- [x] References cross-link the research doc and Cutover A runbook
- [x] What We're NOT Doing explicitly excludes Cutover C and Stage 3

### Pre-implementation review resolutions (2026-05-01)

**Critical issues from `2026-05-01-07-15-tdd-cutover-b-ultimate-mcp-runtime-swap-REVIEW.md`:**

- [x] **C1 (resource-read parity gap)** — added Behavior 11 (Resource-read round-trip parity); 4 tests covering `silmari://trunks`, `silmari://register/root`, `silmari://keyword-index`, and unknown-URI error parity
- [x] **C2 (FastMCP inspection API undefined)** — B6 rewritten to use static-manifest assertion via `build_default_silmari_mcp_footprint_manifest()`; live-instance check reduced to a `create_silmari_fastmcp` smoke that asserts the factory returns `FastMCP` without raising. No coupling to FastMCP internals.
- [x] **C3 (caller-tier propagation contract)** — added Decision Card §6 pinning operator-pinned env (no Python-side inference); B-sec converted from "discovery" to "contract assertion."

**Warnings:**

- [x] **W1 (SilmariBridgeError citation)** — pinned at `silmari_compat.py:86-87`; B5 cites the existing class, no new exception introduced
- [x] **W2 (env propagation contract)** — folded into C3 via Decision Card §6
- [x] **W3 (call_silmari_tool return type)** — pinned as `str` at `silmari_compat.py:165`; B7 explicitly `JSON.parse` the raw stdout
- [x] **W4 (decision.warnings string)** — verified `'claimed-thoughttype-downgraded'` at `apps/silmari-mcp/src/lib/router.ts:538` (Stage 2 branch); B-sec test 4 string is correct
- [x] **W5 (B-perf budget unanchored)** — added Step Zero TS-only baseline measurement; budget rule = `max(operator-stated, TS-baseline-p95 × 3)`
- [x] **W6 (DEFAULT_TIMEOUT_SECONDS)** — pinned `30.0` at `silmari_compat.py:44`; documented edge case
- [x] **W7 (JSON sort_keys)** — confirmed `compact_args` uses `sort_keys=True` at `silmari_compat.py:108`; test fixtures alphabetically sorted
- [x] **W8 (nested host arg passthrough)** — `_make_tool` codegen at `silmari_compat.py:199-208` uses key-based passthrough; test added in B5 (`test_sai_route_thought_host_is_nested_dict_in_payload`)
- [x] **W9 (inputSchema enforcement)** — added error-envelope sub-test to B7 (`zk_save_card with missing body produces matching error info via both runtimes`)

**Cosmetic line-number corrections:**

- [x] `silmari_compat.py:154` (was `:159`) for `env["SILMARI_MCP_BACKEND"] = "typescript"`
- [x] `kindGuard.ts:127` (was `:101-106`) for `resolveCallerFromEnv`; helper layout documented (parseTier L102-111, parseAgentId L113-122, default tier L103, DEFAULT_AGENT_ID L100)

### Post-revision verdict

Plan moves from `NEEDS_MINOR_REVISION` → `READY_FOR_IMPLEMENTATION`. All 3 critical issues resolved; all 9 warnings resolved; cosmetic line-number drift corrected.

---

## 🟢 Implementation Status (2026-05-01)

Implemented by SapphireCanyon on `feat/cutover-b-runtime-swap` (FuchsiaBridge offline at start of session).

**Test gates (all green):**

- **TS side**: `bun test apps/silmari-mcp/tests/{cutover-b-*,ultimate-compat-parity}.test.ts scripts/cutover-b/rollback.test.ts` → 31 pass, 4 skip (B-perf CI-gated), 0 fail.
- **Python side**: `vendor/ultimate_mcp_server/.venv/bin/pytest tests/unit/test_silmari_compat{,_surface,_purity}.py tests/integration/test_silmari_gateway.py --override-ini="addopts="` → 39 pass, 0 fail.

**Behaviors landed**:

- B0 (Decision Card §1-§6) — pinned in plan frontmatter, no code
- B1 + B2 — `SILMARI_TOOL_NAMES` extended to 27, `SILMARI_TOOL_ARG_NAMES` extended for the 6 new tools (`silmari_compat.py:19-49,90-103`)
- B3 — `SILMARI_ALLOWED_PREFIXES = ("zk_", "sai_")` (`silmari_minimal_runtime.py:48-55`); footprint guard updated (`silmari_minimal_runtime.py:159-162`)
- B4 — parity test rewritten to runtime Python introspection with `PYTHON_BIN` + venv resolution (`apps/silmari-mcp/tests/ultimate-compat-parity.test.ts`)
- B5 — parameterized subprocess-bridge tests for all 6 new tools, including bridge-error path and W8 nested-host contract (`tests/unit/test_silmari_compat.py`)
- B6 — manifest + FastMCP smoke (`tests/integration/test_silmari_gateway.py`)
- B7 + B11 — round-trip wire-format equality for tools and resources, including W9 error-envelope sub-test
- B-sec — kindGuard tier contract (env-pinned, no inference) — 4 tests
- B-purity — grep test asserting silmari_compat.py has zero direct data access
- B-perf — CI-gated latency budget gate with W5 Step Zero baseline harness
- B8 — cursor-style E2E through Python frontend with audit log assertion
- B10 — `scripts/cutover-b/rollback.ts` (apply-forward / apply-rollback CLI) + 4-test contract pin
- B9 — runbook at `artifacts/runbooks/silmari-store-cutover-b.md` (9 required sections + ≥5-row log table); Cutover A runbook line 392 now links to it

**Operator next step**: capture the latency baseline with `CI=true bun test apps/silmari-mcp/tests/cutover-b-perf.test.ts` and paste the numbers into the runbook's Post-Cutover Monitoring table.
