---
date: 2026-04-28T09:50:00-04:00
planner: Codex
git_commit: 21906b39c576235199dff58ac830ef22f8b57da9
branch: main
repository: silmari-agent-memory
topic: "TDD plan - Ultimate MCP Server Silmari compatibility layer"
app_name: ultimate_mcp_server
type: tdd_plan
status: revised_after_review
related_beads_issues:
  - silmari-agent-memory-xq6
  - silmari-agent-memory-ee7
  - silmari-agent-memory-9v3
related_research:
  - thoughts/searchable/shared/research/2026-04-28-ultimate-mcp-server-silmari-mcp-algorithm-contracts.md
  - thoughts/searchable/shared/research/2026-04-27-sai-algorithm-router-contracts.md
related_reviews:
  - thoughts/searchable/shared/plans/2026-04-28-silmari-agent-memory-xq6-tdd-ultimate-mcp-silmari-compatibility-REVIEW.md
related_specs:
  - artifacts/specs/2026-04-28-beads-rust-replacement/03-store-api-and-adapter.md
  - artifacts/specs/2026-04-28-beads-rust-replacement/05-viewer-export-and-consumers.md
tags: [tdd, plan, ultimate-mcp-server, silmari-mcp, sai, algorithm, compatibility, mcp]
---

# Ultimate MCP Server Silmari Compatibility Layer - TDD Implementation Plan

## Overview

Use `vendor/ultimate_mcp_server` as the MCP runtime while preserving the current Silmari domain API.

The replacement is not "use Ultimate UMS instead of Silmari memory." The research shows the current external contract is a Claude-visible server registered as `silmari`, with tools named `mcp__silmari__zk_*`, `silmari://*` resources, Silmari card IDs, folgezettel topology, label-encoded edges, and SAI Algorithm recall/save/link/hub lifecycle behavior.

The product boundary has two layers that must not be collapsed:

1. **Default Silmari MCP server footprint**: the MCP server registered as `silmari` exposes only Silmari `zk_*` tools and `silmari://*` resources in Algorithm-facing compatibility mode. Ultimate MCP is an implementation runtime, not a new prompt-visible operating system in this mode.
2. **SAI runtime context**: SAI may still load project instructions, `settings.json -> loadAtStartup`, `dynamicContext`, on-demand context routing docs, PRD state, hooks, notifications, Fabric, Actions, Pipelines, Flows, and agent/delegation context according to existing SAI rules. These surfaces are allowed SAI context, not Ultimate MCP leaks, and the compatibility layer must not rewrite or bypass them.

The Algorithm version authority is `SAI/Algorithm/LATEST`. As of this plan revision on 2026-04-28, `LATEST` resolves to `v3.8.1`; `SAI/README.md` still says `v3.7.0`, so the implementation plan must either amend that stale README claim or fail an authority-drift test before rollout.

The first implementation slice should therefore add a Silmari compatibility extension to Ultimate MCP:

1. Register the existing `zk_*` tool names in a FastMCP server configured for stdio and registered by clients as `silmari`.
2. Preserve the current JSON text result envelope and error behavior visible to MCP clients.
3. Delegate tool/resource behavior to the existing Silmari TypeScript/CLI surface first, so storage semantics stay unchanged.
4. Expose `silmari://*` resources from Ultimate.
5. Suppress Ultimate's generic tool/resource/provider surface from the default Algorithm-facing `silmari` runtime.
6. Keep Ultimate UMS out of the compatibility path until a later migration proves semantic parity.
7. Preserve SAI direct hook behavior by introducing a stable hook-facing recall shim before changing hook imports.
8. Add a real generic `silmari tool <zk_name> <json>` bridge in the current CLI before subprocess delegation can go green.
9. Preserve the SAI hook lifecycle contract: ThinkWithMemory must remain non-blocking, bounded under the hook budget, fallback-safe, and always exit cleanly.
10. Add SAI MEMORY/PRD/work-state/event non-interference tests so Silmari compatibility cannot corrupt or bypass SAI's own state model.

This plan is test-first. Every behavior starts from an observable MCP/SAI/CLI contract and only then names the minimal implementation.

## Review Amendments Applied

This revision incorporates the major-review blockers and warnings from `silmari-agent-memory-9v3`:

- Algorithm version authority now comes from `SAI/Algorithm/LATEST`, with a required drift test and README amendment before rollout.
- The footprint audit is now scoped to the default `silmari` MCP server; SAI `loadAtStartup`, `dynamicContext`, context routing, PRD/Memory docs, Fabric, Actions, Pipelines, Flows, agents, delegation, and notifications are separately listed as allowed SAI context.
- The generic `silmari tool <zk_name> <json>` bridge is in Behavior 3's green path, not a later refactor.
- ThinkWithMemory now has explicit hook lifecycle tests for timeout/cancellation fallback, under-500ms behavior, always-clean exit, settings/doc registration, and event-log non-regression.
- SAI MEMORY/PRD/work-state/event non-interference is now a first-class Behavior 9 requirement, not just a UMS-isolation note.
- SAI markdown docs are treated as canonical prose contracts even without JSON Schema files, and SYSTEM/USER extensibility is required for new config controls.
- CLI backend selection now has an explicit `--backend ultimate` flag plus docs, while `SILMARI_MCP_BACKEND=ultimate` remains a non-interactive convenience.
- JSON envelopes are tested as semantic JSON text plus TypeScript fixture parity, avoiding a separate formatting authority.
- Static listed resources and unlisted dynamic resource templates have separate parity obligations.
- Algorithm lifecycle scenarios are no longer described as SAI Flows unless actual `F_` Flow behavior is under test.

## Current State Analysis

### Key Discoveries

- `apps/silmari-mcp/src/index.ts:101` defines the current Silmari `zk_*` JSON Schema tool list.
- `apps/silmari-mcp/src/index.ts:455` and `apps/silmari-mcp/src/index.ts:459` define the current MCP result envelope: success is text content containing JSON; tool failure is text content plus `isError: true`.
- `apps/silmari-mcp/src/index.ts:527` dispatches all current `zk_*` tools.
- `apps/silmari-mcp/src/index.ts:440` defines listed static `silmari://*` resources, and `apps/silmari-mcp/src/index.ts:830` dispatches static and dynamic resource reads.
- `apps/silmari-mcp/src/index.ts:882` creates the TypeScript MCP `Server`; `apps/silmari-mcp/src/index.ts:914` connects stdio transport.
- `apps/silmari-mcp/src/cli.ts:168` runs a concrete MCP client against the local TypeScript server, defaulting `SILMARI_DIR` at `apps/silmari-mcp/src/cli.ts:170`.
- `apps/silmari-mcp/src/lib/card-ops.ts:111` defines `SaveCardOpts`, and `apps/silmari-mcp/src/lib/card-ops.ts:179` defines the current `SaveCardResult`.
- `apps/silmari-mcp/src/lib/card-ops.ts:811` is the current `saveCard()` entry point; `apps/silmari-mcp/src/lib/card-ops.ts:973` is `saveCardsBatch()`.
- `apps/silmari-mcp/src/lib/navigate.ts:630` pins the default recall entry limit, `apps/silmari-mcp/src/lib/navigate.ts:632` defines `NavigationSession`, and `apps/silmari-mcp/src/lib/navigate.ts:778` composes `navigate()`.
- `apps/silmari-mcp/src/lib/keyword-index.ts:20` stores `keyword_entries` in `${SILMARI_DIR}/silmari.db`; `apps/silmari-mcp/src/lib/keyword-index.ts:76` defines the two-variant post-uncap `AddKeywordResult`.
- `apps/silmari-mcp/src/lib/edges.ts:76` writes direct edge labels, `apps/silmari-mcp/src/lib/edges.ts:241` appends reviewed proposals, and `apps/silmari-mcp/src/lib/edges.ts:326` commits proposal edges.
- `apps/silmari-mcp/src/lib/br-adapter.ts:128` applies `--json`, `--actor silmari-mcp`, and `--no-auto-flush`; `apps/silmari-mcp/src/lib/br-adapter.ts:593` exposes explicit `brSync()`.
- `vendor/ultimate_mcp_server/ultimate_mcp_server/core/server.py:185` defines `Gateway`, and `vendor/ultimate_mcp_server/ultimate_mcp_server/core/server.py:264` constructs `FastMCP`.
- `vendor/ultimate_mcp_server/ultimate_mcp_server/tools/__init__.py:378` registers standalone async tool functions by function name.
- `vendor/ultimate_mcp_server/ultimate_mcp_server/core/server.py:2060` exposes `start_server()`, whose transports include `stdio`, `sse`, and `streamable-http`.
- `vendor/ultimate_mcp_server/ultimate_mcp_server/core/server.py:1000` and following resource decorators register Ultimate's own `info://*`, `guide://*`, and `examples://*` resources, not Silmari resources.
- `vendor/ultimate_mcp_server/tools_list.json` does not contain any `zk_*` tools today.
- `SAI/Algorithm/v3.8.1.md:29` declares Silmari MCP as the persistent memory layer and requires first-class `mcp__silmari__zk_*` tools.
- `SAI/Algorithm/v3.8.1.md:355`, `SAI/Algorithm/v3.8.1.md:465`, and `SAI/Algorithm/v3.8.1.md:523` require recall at OBSERVE, THINK, and LEARN.
- `SAI/Algorithm/v3.8.1.md:559` through `SAI/Algorithm/v3.8.1.md:599` require LEARN saves, source tags, and `in_progress` lifecycle capture.
- `SAI/Algorithm/LATEST` is the Algorithm version authority and currently contains `v3.8.1`; `SAI/README.md:38` still says current version `v3.7.0` and must be amended or explicitly tested as drift.
- `SAI/README.md:83` through `SAI/README.md:84` say startup loads `settings.json -> loadAtStartup` files and `dynamicContext` through `LoadContext.hook.ts`.
- `SAI/CONTEXT_ROUTING.md:3` through `SAI/CONTEXT_ROUTING.md:22` defines on-demand context routing for memory, hooks, agents, actions, pipelines, flows, and PRD docs.
- `SAI/settings.json:192` through `SAI/settings.json:214` registers `ThinkWithMemory.hook.ts` for `UserPromptSubmit`, while `SAI/THEHOOKSYSTEM.md:124` through `SAI/THEHOOKSYSTEM.md:145` is stale and omits it.
- `SAI/THEHOOKSYSTEM.md:736` through `SAI/THEHOOKSYSTEM.md:748` defines the hook lifecycle promise: hooks should complete in under 500ms, avoid blocking on slow external services, and exit cleanly.
- `SAI/MEMORYSYSTEM.md:6` through `SAI/MEMORYSYSTEM.md:12` and `SAI/MEMORYSYSTEM.md:236` through `SAI/MEMORYSYSTEM.md:243` define `~/.claude/MEMORY/` ownership, PRD-derived work state, and append-only event emission.
- `SAI/PRDFORMAT.md:3` through `SAI/PRDFORMAT.md:6` define PRDs as the Algorithm source of truth and make hooks read/sync-only for PRD state.
- `SAI/SYSTEM_USER_EXTENDABILITY.md:7` through `SAI/SYSTEM_USER_EXTENDABILITY.md:34` requires configurable components to have SYSTEM defaults, USER override locations, cascading lookup, and fallback behavior.
- `SAI/hooks/ThinkWithMemory.hook.ts:117` dynamically imports Silmari TypeScript library modules directly, not via MCP.
- `SAI/hooks/lib/think-with-memory.ts:194` defines the hook-facing recall summary keys `keywordEntries`, `folgezettelNeighbors`, and `crossRefs`.

### Registry And Schema Reality Check

The required `specs/schemas/resource_registry.json` file is absent. Root-level `schema/`, `schemas/`, and `specs/schemas/` directories are also absent.

The only available registry-like artifact is `artifacts/impl/resource_registry.snapshot.json`, and its own `status` is `proposed_registry_no_canonical_source`. Its resources cover prior Rust retrieval-substrate aliases, not this Ultimate MCP compatibility layer.

The schema-to-registry loop is therefore run in summary mode for JSON Schema files, but SAI markdown specs are still canonical prose contracts. Absence of a JSON Schema registry does not mean absence of SAI contracts.

| Source | Status | Mapping use |
| --- | --- | --- |
| `schema/` | absent | no canonical schema contracts |
| `schemas/` | absent | no canonical schema contracts |
| `specs/schemas/` | absent | no canonical registry or schemas |
| `artifacts/impl/resource_registry.snapshot.json` | proposed snapshot | precedent for `[PROPOSED]` IDs |
| `artifacts/specs/2026-04-28-beads-rust-replacement/03-store-api-and-adapter.md` | adjacent contract spec | adapter and error-envelope references |
| `artifacts/specs/2026-04-28-beads-rust-replacement/05-viewer-export-and-consumers.md` | adjacent contract spec | MCP/SAI payload references |
| `SAI/Algorithm/LATEST` and `SAI/Algorithm/v3.8.1.md` | canonical prose contract | Algorithm version authority and Silmari MCP lifecycle requirements |
| `SAI/README.md`, `SAI/CONTEXT_ROUTING.md`, `SAI/settings.json` | canonical prose/config contracts | startup context, dynamic context, and hook registration |
| `SAI/PRDFORMAT.md`, `SAI/MEMORYSYSTEM.md` | canonical prose contracts | PRD source-of-truth, work state, memory directories, event log ownership |
| `SAI/THEHOOKSYSTEM.md`, `SAI/THENOTIFICATIONSYSTEM.md` | canonical prose contracts | hook timing, clean exit, event/notification observability |
| `SAI/PIPELINES.md`, `SAI/FLOWS.md`, `SAI/THEFABRICSYSTEM.md`, `SAI/SAIAGENTSYSTEM.md`, `SAI/THEDELEGATIONSYSTEM.md` | canonical prose contracts | non-interference boundaries for non-MCP SAI routing systems |
| `SAI/SYSTEM_USER_EXTENDABILITY.md` | canonical prose contract | SYSTEM defaults, USER overrides, cascading lookup for new config controls |

Every behavior below uses `[PROPOSED]` resource identities with stable aliases. Every planned Python and TypeScript function still includes required documentation contract tags so a future canonical registry can be backfilled mechanically, and every behavior that depends on SAI uses the relevant SAI prose/config file in `schema_contract_refs`.

## Desired End State

Ultimate MCP can be launched as a minimal Silmari MCP server and pass compatibility tests against the current TypeScript server behavior. The user's chosen LLM should not need to know or reason about Ultimate MCP internals, commercial app internals, provider routing, filesystem helpers, or UMS primitives through the default `silmari` MCP server.

Default Silmari MCP server footprint contract:

- Algorithm authority: `SAI/Algorithm/LATEST` resolves to the pinned Algorithm file, currently `SAI/Algorithm/v3.8.1.md`; docs that name a current version must match it.
- MCP namespace: one server registered as `silmari`, exposing only the Silmari `zk_*` tools and `silmari://*` resources needed by the Algorithm and `/silmari` workflows.
- Hook payloads: compact recall summaries with stable keys, not raw app internals or broad filesystem state.
- Contract guarantees: tests must prove the default Silmari MCP server footprint excludes Ultimate base tools/resources, provider routing, filesystem/document/web helpers, commercial app internals, and UMS as Silmari storage.

Allowed SAI context and non-interference contract:

- Always-loaded and on-demand SAI context remains governed by SAI: `CLAUDE.md`/`AGENTS.md`, `settings.json -> loadAtStartup`, `dynamicContext`, and `SAI/CONTEXT_ROUTING.md` can still load the relevant SAI docs and USER context.
- The compatibility layer does not disable or replace SAI skill routing, Fabric, Actions, Pipelines, Flows, notifications, named agents, custom agents, agent teams, or delegation state.
- The compatibility layer does not write PRD files, bypass `PRDSync`, or mutate `~/.claude/MEMORY/WORK`, `~/.claude/MEMORY/STATE/work.json`, current-work state, `~/.claude/MEMORY/LEARNING`, or `~/.claude/MEMORY/STATE/events.jsonl` except through existing SAI hook paths that already own those writes.
- Hook behavior remains within the SAI lifecycle contract: bounded execution, timeout/cancellation fallback, clean exit, and preservation of event/notification observability.

Target files:

```text
vendor/ultimate_mcp_server/ultimate_mcp_server/tools/silmari_compat.py
vendor/ultimate_mcp_server/ultimate_mcp_server/core/silmari_resources.py
vendor/ultimate_mcp_server/ultimate_mcp_server/core/silmari_minimal_runtime.py
vendor/ultimate_mcp_server/ultimate_mcp_server/core/server.py
vendor/ultimate_mcp_server/ultimate_mcp_server/tools/__init__.py
vendor/ultimate_mcp_server/tests/unit/test_silmari_compat.py
vendor/ultimate_mcp_server/tests/integration/test_silmari_gateway.py
apps/silmari-mcp/tests/ultimate-compat-parity.test.ts
apps/silmari-mcp/tests/sai-compat-noninterference.test.ts
apps/silmari-mcp/src/cli.ts
SAI/hooks/lib/silmari-recall-client.ts
SAI/hooks/ThinkWithMemory.hook.ts
SAI/hooks/tests/think-with-memory-silmari-client.test.ts
SAI/hooks/tests/think-with-memory-lifecycle.test.ts
SAI/README.md
SAI/CLI.md
SAI/TOOLS.md
SAI/THEHOOKSYSTEM.md
```

Target runtime shape:

- The MCP client config can register the Ultimate process under server name `silmari`.
- In default Silmari compatibility mode, FastMCP registers tool functions named exactly `zk_save_card`, `zk_save_cards`, `zk_recall`, `zk_neighborhood`, `zk_chain`, `zk_follow`, `zk_propose_link`, `zk_propose_links_semantic`, `zk_commit_link`, `zk_hub_create`, `zk_hub_add_card`, `zk_hub_members`, `zk_line_of_thought`, `zk_structure_create`, `zk_register_read`, `zk_block`, `zk_keyword_add`, `zk_status`, `zk_reflect`, `zk_recall_by_status`, and `zk_promote`.
- In default Silmari compatibility mode, FastMCP does not register Ultimate base tools such as provider calls, filesystem/document helpers, or UMS tools.
- Ultimate resources include the current `silmari://*` namespace and do not list Ultimate `info://*`, `guide://*`, or `examples://*` resources to Algorithm-facing clients.
- Compatibility tool functions delegate to the existing Silmari MCP CLI or TypeScript dispatcher by subprocess and preserve the JSON text payload.
- Delegation uses a real machine bridge, `silmari tool <zk_name> <json>`, or a dedicated dispatch bridge with the same contract; the bridge is required before Behavior 3 is green.
- The compatibility layer does not rewrite Silmari card storage into Ultimate UMS.
- The compatibility layer does not write or sync SAI PRD/MEMORY state and does not bypass PRDSync-derived work-state paths.
- The ThinkWithMemory hook imports one stable recall client module instead of reconstructing the library surface itself.
- Hook output remains a compact inference-cycle contract: `keywordEntries`, `folgezettelNeighbors`, and `crossRefs`, with implementation details hidden behind the client module.
- ThinkWithMemory recall has a timeout/fallback path that preserves the SAI hook promise: under 500ms target, no long blocking external dependency, and clean hook exit on missing Silmari modules or slow recall.

## What We Are Not Doing

| Out of scope | Reason |
| --- | --- |
| Replacing Silmari storage with Ultimate UMS | UMS has workflow/memory IDs, not folgezettel cards, label edges, registers, hubs, or Silmari lifecycle statuses. |
| Renaming Claude-visible tools | The Algorithm and command docs rely on `mcp__silmari__zk_*`. |
| Removing the TypeScript Silmari server immediately | It remains the parity oracle and initial behavior delegate. |
| Changing card result shapes | `zk_save_card`, `zk_recall`, link proposal, hub, status, and resource payloads remain stable in this slice. |
| Exposing Ultimate's general MCP toolbox to Algorithm runs | The default Silmari MCP footprint is Silmari plus Algorithm contracts, not the whole Ultimate app surface. |
| Exposing commercial app internals through MCP docs/resources | Prompt-visible instructions remain `CLAUDE.md`/`AGENTS.md` plus the Algorithm and compact hook summaries. |
| Migrating hook state files | The hook client is refactored, but existing state path behavior is preserved. |
| Replacing SAI MEMORY/PRD ownership | PRD files, derived work state, learning state, and event logs remain owned by existing SAI Algorithm/hooks. |
| Disabling SAI routing systems | Fabric, Actions, Pipelines, Flows, named agents, custom agents, team delegation, and context routing must keep working. |
| Hiding stale SAI docs behind tests only | If compatibility makes `silmari` CLI or ThinkWithMemory registration a stable SAI surface, this plan updates the relevant SAI docs in the same slice. |

## Testing Strategy

- **Python framework**: `pytest` from `vendor/ultimate_mcp_server`.
- **Python focused commands**:
  - `cd vendor/ultimate_mcp_server && uv run pytest tests/unit/test_silmari_compat.py`
  - `cd vendor/ultimate_mcp_server && uv run pytest tests/integration/test_silmari_gateway.py`
  - `cd vendor/ultimate_mcp_server && uv run pytest tests/integration/test_server.py`
- **TypeScript/Bun framework**: `bun:test`.
- **TypeScript focused commands**:
  - `bun test apps/silmari-mcp/tests/ultimate-compat-parity.test.ts`
  - `bun test apps/silmari-mcp/tests/sai-compat-noninterference.test.ts`
  - `bun test apps/silmari-mcp/tests/mcp-tool-description.test.ts apps/silmari-mcp/tests/recall-promote.test.ts apps/silmari-mcp/tests/zk-save-card-fromaddress.test.ts`
  - `bun test SAI/hooks/tests/think-with-memory-silmari-client.test.ts SAI/hooks/tests/think-with-memory-lifecycle.test.ts`
- **Integration shape**:
  - Unit tests mock subprocess delegation and assert exact envelope behavior.
  - Integration tests instantiate `Gateway(name="silmari")`, register compatibility tools/resources, and call tools through FastMCP.
  - Default MCP footprint tests assert the default `silmari` runtime exposes no Ultimate base tools, UMS tools, provider-routing tools, filesystem/document/web helpers, or Ultimate `info://`, `guide://`, and `examples://` resources.
  - SAI context tests separately enumerate allowed SAI startup and on-demand surfaces: `loadAtStartup`, `dynamicContext`, `SAI/CONTEXT_ROUTING.md`, PRD format, Memory, Hook, Notification, Agent, Delegation, Fabric, Actions, Pipelines, and Flows docs.
  - Algorithm authority tests read `SAI/Algorithm/LATEST`, resolve the pinned Algorithm file, and fail if SAI docs that claim the current version drift from that authority.
  - CLI bridge tests exercise `silmari tool <zk_name> <json>` before Ultimate subprocess delegation is allowed to pass.
  - Hook lifecycle tests simulate missing modules and slow recall; ThinkWithMemory must return `{}` or a compact summary, finish within the configured budget, and exit cleanly.
  - SAI MEMORY/PRD non-interference tests seed `MEMORY/WORK/PRD.md`, `MEMORY/STATE/work.json`, current-work state, learning state, and `MEMORY/STATE/events.jsonl`, then assert Silmari compatibility calls do not write, truncate, or bypass existing SAI hook-owned paths.
  - Agent/delegation smoke tests verify default compatibility mode does not change named-agent, custom-agent, team, or delegation routing metadata.
  - Parity tests compare Ultimate compatibility results against current `dispatchTool()` or `silmari` CLI output for seeded fixtures.

## Behavior 1: Ultimate Registers As The Minimal Silmari MCP Runtime

### Resource Registry Binding

- `resource_id`: `[PROPOSED]`
- `address_alias`: `ultimate.silmari_runtime`
- `predicate_refs`: `SAI/Algorithm/LATEST`, `SAI/Algorithm/v3.8.1.md:29`, `vendor/ultimate_mcp_server/ultimate_mcp_server/core/server.py:2060`
- `codepath_ref`: `vendor/ultimate_mcp_server/ultimate_mcp_server/core/server.py::Gateway.__init__`, `vendor/ultimate_mcp_server/ultimate_mcp_server/core/server.py::start_server`
- `schema_contract_refs`: `artifacts/specs/2026-04-28-beads-rust-replacement/05-viewer-export-and-consumers.md::MCP And SAI Contracts`, `SAI/CONTEXT_ROUTING.md`, `SAI/SYSTEM_USER_EXTENDABILITY.md`

### Schema Interface Mapping

- `loop_mode`: `summary`
- `mapped_contracts`: `MCPAndSAIContracts.server_name -> [PROPOSED] ultimate.silmari_runtime`
- `registry_updates`: `[PROPOSED] add schema_refs after canonical registry exists`

### Test Specification

**Given**: a Gateway created with Silmari compatibility enabled  
**When**: tools are registered and the server is launched in stdio mode  
**Then**: the server can be configured as `silmari`, exposes `zk_*` tool names rather than `silmari_*` aliases, and hides Ultimate's generic tool/resource surface from Algorithm-facing clients by default

**Edge Cases**:

- Compatibility disabled leaves the current Ultimate tool list unchanged.
- Compatibility enabled twice is idempotent.
- Tool filtering allows explicitly including only Silmari tools and rejects accidental inclusion of base Ultimate tools in Algorithm mode.
- Any future opt-in for Ultimate base tools must use a separate non-Algorithm runtime mode and separate tests.
- `transport_mode="stdio"` remains valid and does not force HTTP-only behavior.
- Allowed SAI startup and context-routing surfaces are not treated as MCP leaks; they are audited separately in Behavior 10.
- Fabric, Actions, Pipelines, Flows, agent routing, and delegation state remain outside this MCP registration path.

### TDD Cycle

#### Red: Write Failing Test

**File**: `vendor/ultimate_mcp_server/tests/integration/test_silmari_gateway.py`

```python
import pytest

from ultimate_mcp_server.core.server import Gateway
from ultimate_mcp_server.tools.silmari_compat import register_silmari_tools
from ultimate_mcp_server.core.silmari_minimal_runtime import assert_default_silmari_mcp_footprint


@pytest.mark.asyncio
async def test_gateway_registers_silmari_tool_names(monkeypatch):
    gateway = Gateway(name="silmari")
    registered = register_silmari_tools(gateway.mcp)

    assert "zk_recall" in registered
    assert "zk_save_card" in registered
    assert all(not name.startswith("silmari_") for name in registered)
    assert_default_silmari_mcp_footprint(
        tool_names=registered.keys(),
        resource_uris=[],
    )
```

#### Green: Minimal Implementation

**File**: `vendor/ultimate_mcp_server/ultimate_mcp_server/tools/silmari_compat.py`

```python
SILMARI_TOOL_NAMES = (
    "zk_save_card",
    "zk_save_cards",
    "zk_recall",
    "zk_neighborhood",
    "zk_chain",
    "zk_follow",
    "zk_propose_link",
    "zk_propose_links_semantic",
    "zk_commit_link",
    "zk_hub_create",
    "zk_hub_add_card",
    "zk_hub_members",
    "zk_line_of_thought",
    "zk_structure_create",
    "zk_register_read",
    "zk_block",
    "zk_keyword_add",
    "zk_status",
    "zk_reflect",
    "zk_recall_by_status",
    "zk_promote",
)


def register_silmari_tools(mcp_server):
    """
    @rr.id [PROPOSED]
    @rr.alias ultimate.silmari_runtime
    @path.id register-silmari-fastmcp-tools
    @gwt.given a FastMCP server configured for the minimal Silmari compatibility runtime
    @gwt.when Silmari compatibility registration runs
    @gwt.then FastMCP exposes exact zk_* tool names and no Ultimate base tools for Algorithm-facing MCP clients
    @reads [PROPOSED:ultimate.fastmcp_server]
    @writes [PROPOSED:ultimate.tool_registry]
    @raises [PROPOSED:silmari_registration_error]
    @schema.contract artifacts/specs/2026-04-28-beads-rust-replacement/05-viewer-export-and-consumers.md::MCP And SAI Contracts
    """
    registered = {}

    def build_tool(tool_name):
        async def tool(**arguments) -> dict:
            return await call_silmari_tool(tool_name, arguments)
        tool.__name__ = tool_name
        return tool

    for tool_name in SILMARI_TOOL_NAMES:
        tool = build_tool(tool_name)
        mcp_server.tool(name=tool_name)(tool)
        registered[tool_name] = tool

    return registered
```

**File**: `vendor/ultimate_mcp_server/ultimate_mcp_server/core/silmari_minimal_runtime.py`

```python
FORBIDDEN_DEFAULT_TOOL_NAMES = {
    "chat_completion",
    "store_memory",
    "query_memories",
    "create_memory_link",
    "get_rich_context_package",
}

FORBIDDEN_DEFAULT_RESOURCE_PREFIXES = ("info://", "guide://", "examples://")


def assert_default_silmari_mcp_footprint(tool_names, resource_uris):
    """
    @rr.id [PROPOSED]
    @rr.alias ultimate.silmari_runtime
    @path.id assert-default-silmari-mcp-footprint
    @gwt.given a server registered for Algorithm-facing Silmari compatibility mode
    @gwt.when the default MCP server footprint is audited
    @gwt.then only zk_* tools and silmari:// resources are visible through the silmari MCP server
    @reads [PROPOSED:ultimate.tool_registry],[PROPOSED:mcp.resource_registry]
    @writes [PROPOSED:mcp.default_footprint_audit]
    @raises [PROPOSED:mcp_footprint_violation]
    @schema.contract artifacts/specs/2026-04-28-beads-rust-replacement/05-viewer-export-and-consumers.md::MCP And SAI Contracts; SAI/CONTEXT_ROUTING.md; SAI/SYSTEM_USER_EXTENDABILITY.md
    """
    names = set(tool_names)
    forbidden = names & FORBIDDEN_DEFAULT_TOOL_NAMES
    if forbidden:
        raise AssertionError(f"forbidden tools visible in silmari mode: {sorted(forbidden)}")
    non_silmari = [name for name in names if not name.startswith("zk_")]
    if non_silmari:
        raise AssertionError(f"non-Silmari tools visible in silmari mode: {sorted(non_silmari)}")
    leaked_resources = [
        uri for uri in resource_uris
        if uri.startswith(FORBIDDEN_DEFAULT_RESOURCE_PREFIXES)
    ]
    if leaked_resources:
        raise AssertionError(f"Ultimate resources visible in silmari mode: {sorted(leaked_resources)}")
```

#### Refactor

- Replace the one-off `zk_status` registration with a generated registry table of supported tool names.
- Add an explicit compatibility config flag with SYSTEM default and USER override lookup, for example `SAI/SILMARI_COMPAT/config.example.yaml` and `SAI/USER/SILMARI_COMPAT/config.yaml`, or document why this vendor-only flag does not participate in SAI config.
- Keep function names and FastMCP names exact; no prefixing.
- Keep minimal Algorithm mode as the default; adding Ultimate base tools requires a separately named mode and tests that make the wider LLM footprint explicit.

### Success Criteria

**Automated:**

- [ ] Red fails because `ultimate_mcp_server.tools.silmari_compat` does not exist.
- [ ] Green passes with `cd vendor/ultimate_mcp_server && uv run pytest tests/integration/test_silmari_gateway.py`.
- [ ] Existing Ultimate server tests still pass.
- [x] A default MCP footprint audit fails if any non-`zk_*` tool is visible in default Silmari mode.

**Manual:**

- [ ] MCP client config can register the Ultimate command under server name `silmari`.
- [ ] A manual tool list shows `zk_status`, not `silmari_zk_status`.
- [ ] The same manual tool list does not show Ultimate provider, document, filesystem, or UMS tools.

## Behavior 2: Tool Schema And Result Envelope Match The Existing TypeScript Server

### Resource Registry Binding

- `resource_id`: `[PROPOSED]`
- `address_alias`: `mcp.tool_schema_parity`
- `predicate_refs`: `apps/silmari-mcp/src/index.ts:101`, `apps/silmari-mcp/src/index.ts:455`, `apps/silmari-mcp/src/index.ts:459`
- `codepath_ref`: `vendor/ultimate_mcp_server/ultimate_mcp_server/tools/silmari_compat.py::SILMARI_TOOL_SPECS`
- `schema_contract_refs`: `artifacts/specs/2026-04-28-beads-rust-replacement/05-viewer-export-and-consumers.md::MCP And SAI Contracts`

### Schema Interface Mapping

- `loop_mode`: `summary`
- `mapped_contracts`: `MCPAndSAIContracts.zk_tool_payloads -> [PROPOSED] mcp.tool_schema_parity`
- `registry_updates`: `[PROPOSED] add schema_refs after canonical registry exists`

### Test Specification

**Given**: the TypeScript Silmari `TOOLS` export and the Ultimate Silmari compatibility tool spec  
**When**: a parity test compares tool names, required arguments, enums, and selected descriptions  
**Then**: Ultimate exposes the same externally consumed contract and wraps success/failure in the same text JSON envelope visible to MCP clients

**Edge Cases**:

- `zk_keyword_add` description must describe unbounded entry points and must not mention the old cap.
- Tool descriptions must describe Silmari behavior and must not advertise Ultimate provider routing, filesystem helpers, UMS, or commercial app internals.
- `zk_save_card` must require `body` and `kind`; idea saves require `trunk` at dispatch.
- `zk_propose_link` must return a proposal rather than directly adding reviewed edges.
- Tool errors return `isError: true` and text, not a thrown transport crash.
- Success envelopes are semantic JSON text. Tests parse and compare JSON payloads, and fixture parity tests compare actual current TypeScript output where exact string formatting matters; they do not reimplement a separate formatting authority.

### TDD Cycle

#### Red: Write Failing Test

**File**: `apps/silmari-mcp/tests/ultimate-compat-parity.test.ts`

```ts
import { describe, expect, it } from 'bun:test';

const { TOOLS } = await import('../src/index.js');

describe('Ultimate Silmari compatibility tool spec', () => {
  it('matches the current Silmari tool names', async () => {
    const compat = await import('../../../vendor/ultimate_mcp_server/silmari_tool_specs.json');
    expect(compat.tools.map((t: any) => t.name).sort()).toEqual(
      TOOLS.map((t: any) => t.name).sort(),
    );
    expect(compat.tools.map((t: any) => t.name).every((name: string) => name.startsWith('zk_'))).toBe(true);
    expect(JSON.stringify(compat.tools)).not.toContain('Unified Memory System');
    expect(JSON.stringify(compat.tools)).not.toContain('provider');
  });
});
```

**File**: `vendor/ultimate_mcp_server/tests/unit/test_silmari_compat.py`

```python
import pytest
import json

from ultimate_mcp_server.tools.silmari_compat import mcp_text_json, mcp_text_error


def test_mcp_text_json_matches_silmari_envelope_semantically():
    result = mcp_text_json({"ok": True})

    assert result["content"][0]["type"] == "text"
    assert json.loads(result["content"][0]["text"]) == {"ok": True}


def test_mcp_text_error_matches_silmari_envelope():
    assert mcp_text_error("zk_status: failed") == {
        "isError": True,
        "content": [{"type": "text", "text": "zk_status: failed"}],
    }
```

#### Green: Minimal Implementation

**File**: `vendor/ultimate_mcp_server/ultimate_mcp_server/tools/silmari_compat.py`

```python
import json


def mcp_text_json(payload: object) -> dict:
    """
    @rr.id [PROPOSED]
    @rr.alias mcp.tool_schema_parity
    @path.id wrap-silmari-json-result
    @gwt.given a successful Silmari compatibility payload
    @gwt.when the payload is returned through Ultimate FastMCP
    @gwt.then MCP clients see one text content block containing semantic JSON compatible with current TypeScript JSON.stringify output
    @reads [PROPOSED:silmari.compat_payload]
    @writes [PROPOSED:mcp.tool_result]
    @raises [PROPOSED:json_serialization_error]
    @schema.contract artifacts/specs/2026-04-28-beads-rust-replacement/05-viewer-export-and-consumers.md::MCP And SAI Contracts
    """
    return {"content": [{"type": "text", "text": json.dumps(payload, separators=(",", ":"))}]}


def mcp_text_error(message: str) -> dict:
    """
    @rr.id [PROPOSED]
    @rr.alias mcp.tool_schema_parity
    @path.id wrap-silmari-error-result
    @gwt.given a failed Silmari compatibility operation
    @gwt.when the failure is returned through Ultimate FastMCP
    @gwt.then MCP clients see isError true with one text content block
    @reads [PROPOSED:silmari.error_message]
    @writes [PROPOSED:mcp.tool_error_result]
    @raises [PROPOSED:none]
    @schema.contract artifacts/specs/2026-04-28-beads-rust-replacement/05-viewer-export-and-consumers.md::MCP And SAI Contracts
    """
    return {"isError": True, "content": [{"type": "text", "text": message}]}
```

#### Refactor

- Generate a checked-in JSON snapshot from `apps/silmari-mcp/src/index.ts::TOOLS`.
- Add a drift test that fails when TypeScript tool definitions change but Ultimate compatibility specs do not.
- Consider a small build script only after the snapshot test exists.

### Success Criteria

**Automated:**

- [x] Tool-name parity fails before the compatibility spec exists.
- [x] Envelope tests pass.
- [x] Existing `apps/silmari-mcp/tests/mcp-tool-description.test.ts` still passes.

**Manual:**

- [x] MCP clients receive JSON text in the same shape as the current TypeScript server.

## Behavior 3: Tool Calls Delegate To The Existing Silmari Behavior Oracle

### Resource Registry Binding

- `resource_id`: `[PROPOSED]`
- `address_alias`: `mcp.tool_dispatch_bridge`
- `predicate_refs`: `apps/silmari-mcp/src/index.ts:527`, `apps/silmari-mcp/src/cli.ts:168`, `apps/silmari-mcp/src/cli.ts:301`
- `codepath_ref`: `apps/silmari-mcp/src/cli.ts::buildGenericToolRequest`, `vendor/ultimate_mcp_server/ultimate_mcp_server/tools/silmari_compat.py::call_silmari_tool`
- `schema_contract_refs`: `artifacts/specs/2026-04-28-beads-rust-replacement/03-store-api-and-adapter.md::JSON Error Envelope`

### Schema Interface Mapping

- `loop_mode`: `summary`
- `mapped_contracts`: `StoreAPIAndAdapterSpec.error_envelope -> [PROPOSED] mcp.tool_dispatch_bridge`
- `registry_updates`: `[PROPOSED] add schema_refs after canonical registry exists`

### Test Specification

**Given**: a compatibility tool call such as `zk_recall`  
**When**: Ultimate receives the call  
**Then**: it invokes a real existing Silmari bridge with the exact tool name and arguments, preserves `SILMARI_DIR`, parses successful JSON text, and returns a Silmari-style error envelope on nonzero exit or invalid output

**Edge Cases**:

- Empty args become `{}`.
- `SILMARI_DIR` is inherited and never overwritten when set.
- CLI nonzero exit becomes `isError: true`.
- Malformed JSON output becomes `isError: true`.
- Timeout produces a typed compatibility error and does not hang the MCP process.
- The generic bridge accepts only `zk_*` tool names and object JSON arguments.
- The generic bridge is part of the green path; subprocess delegation cannot pass against a hypothetical `tool <name> <json>` interface.

### TDD Cycle

#### Red: Write Failing Test

**File**: `vendor/ultimate_mcp_server/tests/unit/test_silmari_compat.py`

```python
import pytest

from ultimate_mcp_server.tools.silmari_compat import call_silmari_tool


@pytest.mark.asyncio
async def test_call_silmari_tool_passes_name_args_and_env(monkeypatch):
    seen = {}

    async def fake_run(command, args, env, timeout):
        seen["command"] = command
        seen["args"] = args
        seen["env"] = env
        return 0, '{"cards":{"idea":1}}', ''

    monkeypatch.setattr("ultimate_mcp_server.tools.silmari_compat.run_process", fake_run)
    result = await call_silmari_tool("zk_status", {})

    assert result == {"cards": {"idea": 1}}
    assert seen["args"][-3:] == ["tool", "zk_status", "{}"]
```

**File**: `apps/silmari-mcp/tests/ultimate-compat-parity.test.ts`

```ts
describe('silmari generic tool bridge', () => {
  it('dispatches zk_status from machine JSON args', async () => {
    const cli = await runSilmariCli(['tool', 'zk_status', '{}']);
    const direct = await dispatchTool('zk_status', {});

    expect(cli.exitCode).toBe(0);
    expect(JSON.parse(cli.stdout)).toEqual(JSON.parse(direct.content[0].text));
  });

  it('rejects non-zk tool names in the generic bridge', async () => {
    const cli = await runSilmariCli(['tool', 'status', '{}']);

    expect(cli.exitCode).toBe(2);
    expect(cli.stderr).toContain('tool name must start with zk_');
  });
});
```

#### Green: Minimal Implementation

**File**: `vendor/ultimate_mcp_server/ultimate_mcp_server/tools/silmari_compat.py`

```python
async def call_silmari_tool(name: str, arguments: dict | None = None) -> dict:
    """
    @rr.id [PROPOSED]
    @rr.alias mcp.tool_dispatch_bridge
    @path.id call-existing-silmari-tool
    @gwt.given an Ultimate MCP tool call with a zk_* name and JSON arguments
    @gwt.when the compatibility bridge dispatches the call
    @gwt.then the existing Silmari behavior oracle returns the same JSON payload or a Silmari-style error
    @reads [PROPOSED:mcp.tool_call],[PROPOSED:silmari.env]
    @writes [PROPOSED:mcp.tool_result]
    @raises [PROPOSED:silmari_bridge_error]
    @schema.contract artifacts/specs/2026-04-28-beads-rust-replacement/03-store-api-and-adapter.md::JSON Error Envelope
    """
    args = arguments or {}
    code, stdout, stderr = await run_process(
        command=resolve_silmari_bridge_command(),
        args=["tool", name, json.dumps(args, separators=(",", ":"))],
        env=os.environ.copy(),
        timeout=30,
    )
    if code != 0:
        raise SilmariBridgeError(stderr.strip() or f"{name}: failed")
    return json.loads(stdout)
```

**File**: `apps/silmari-mcp/src/cli.ts`

```ts
function buildGenericToolRequest(parsed: ParsedArgs): DispatchRequest {
  /**
   * @rr.id [PROPOSED]
   * @rr.alias mcp.tool_dispatch_bridge
   * @path.id build-generic-silmari-tool-request
   * @gwt.given a machine bridge call `silmari tool <zk_name> <json>`
   * @gwt.when the CLI parses the bridge request
   * @gwt.then it dispatches the exact zk_* tool name and object arguments through the current MCP client path
   * @reads [PROPOSED:cli.args]
   * @writes [PROPOSED:cli.dispatch_request]
   * @raises [PROPOSED:cli_validation_error]
   * @schema.contract artifacts/specs/2026-04-28-beads-rust-replacement/03-store-api-and-adapter.md::JSON Error Envelope
   */
  const name = requirePositional(parsed.positional, 0, 'tool name');
  if (!name.startsWith('zk_')) fail('tool name must start with zk_');

  const rawArgs = parsed.positional[1] ?? '{}';
  let args: unknown;
  try {
    args = JSON.parse(rawArgs);
  } catch {
    fail('tool args must be valid JSON');
  }
  if (!args || typeof args !== 'object' || Array.isArray(args)) {
    fail('tool args must be a JSON object');
  }
  return { kind: 'tool', name, args: args as Record<string, unknown> };
}

// main() switch:
// case 'tool': req = buildGenericToolRequest(parsed); break;
```

#### Refactor

- After the generic CLI bridge exists and parity passes, consider a direct dedicated dispatch executable to reduce subprocess overhead. It must preserve the same `tool <zk_name> <json>` contract or update the tests first.
- Add a typed `SilmariBridgeError` with exit code, stderr, and tool name.
- Keep all subprocess code behind one async function for deterministic tests.

### Success Criteria

**Automated:**

- [x] Mocked subprocess tests pass.
- [ ] `silmari tool zk_status '{}'` exists and matches direct `dispatchTool('zk_status', {})`.
- [ ] A focused parity test can call `zk_status` through Ultimate and through the TypeScript dispatcher and compare parsed JSON.
- [ ] Timeouts are covered without sleeping in tests.

**Manual:**

- [ ] `SILMARI_DIR=/tmp/silmari-test` is visible to delegated Silmari calls.

## Behavior 4: Recall Preserves Keyword, Folgezettel, And Crossref Semantics

### Resource Registry Binding

- `resource_id`: `[PROPOSED]`
- `address_alias`: `mcp.recall_parity`
- `predicate_refs`: `apps/silmari-mcp/src/lib/keyword-index.ts:253`, `apps/silmari-mcp/src/lib/navigate.ts:326`, `apps/silmari-mcp/src/lib/navigate.ts:519`, `apps/silmari-mcp/src/lib/navigate.ts:778`
- `codepath_ref`: `vendor/ultimate_mcp_server/ultimate_mcp_server/tools/silmari_compat.py::zk_recall`
- `schema_contract_refs`: `artifacts/specs/2026-04-28-beads-rust-replacement/05-viewer-export-and-consumers.md::MCP And SAI Contracts`

### Schema Interface Mapping

- `loop_mode`: `summary`
- `mapped_contracts`: `MCPAndSAIContracts.zk_recall -> [PROPOSED] mcp.recall_parity`
- `registry_updates`: `[PROPOSED] add schema_refs after canonical registry exists`

### Test Specification

**Given**: a seeded Silmari store with keyword entries, folgezettel relatives, and typed edges  
**When**: `zk_recall` is called through Ultimate with `expandCrossRefs: true`  
**Then**: the result preserves current `NavigationSession` keys: `query`, `entryPoints`, `entryCards`, `neighborhoods`, and `crossRefs`

**Edge Cases**:

- Keyword miss returns `entryPoints: null` and `entryCards: []`.
- `limitPerTerm: 0` reports truncation when entries exist.
- `sortBy` and `direction` are passed through exactly.
- Entry points may be card IDs or slash-form folgezettel addresses.
- Crossrefs are omitted unless `expandCrossRefs` is true.

### TDD Cycle

#### Red: Write Failing Test

**File**: `apps/silmari-mcp/tests/ultimate-compat-parity.test.ts`

```ts
describe('Ultimate zk_recall parity', () => {
  it('preserves NavigationSession shape for a keyword miss', async () => {
    const ultimate = await callUltimateCompatTool('zk_recall', { query: 'never-indexed-term' });
    const current = await dispatchTool('zk_recall', { query: 'never-indexed-term' });
    expect(JSON.parse(ultimate.content[0].text)).toEqual(JSON.parse(current.content[0].text));
  });
});
```

#### Green: Minimal Implementation

**File**: `vendor/ultimate_mcp_server/ultimate_mcp_server/tools/silmari_compat.py`

```python
async def zk_recall(query: str, expandCrossRefs: bool = False, maxDepth: int | None = None,
                    direction: str | None = None, limitPerTerm: int | None = None,
                    sortBy: str | None = None) -> dict:
    """
    @rr.id [PROPOSED]
    @rr.alias mcp.recall_parity
    @path.id ultimate-zk-recall-parity
    @gwt.given Silmari keyword entries and optional cross-reference expansion arguments
    @gwt.when zk_recall is called through Ultimate MCP
    @gwt.then the current three-layer NavigationSession shape is returned unchanged
    @reads [PROPOSED:silmari.keyword_entries],[PROPOSED:silmari.folgezettel_graph],[PROPOSED:silmari.ref_edges]
    @writes [PROPOSED:mcp.tool_result]
    @raises [PROPOSED:silmari_bridge_error]
    @schema.contract artifacts/specs/2026-04-28-beads-rust-replacement/05-viewer-export-and-consumers.md::MCP And SAI Contracts
    """
    return await call_silmari_tool("zk_recall", compact_args(locals()))
```

#### Refactor

- Add shared argument compaction that omits `None` but preserves explicit `False` and `0`.
- Add schema validation only after parity tests prove it does not alter current behavior.

### Success Criteria

**Automated:**

- [ ] Recall miss parity passes.
- [ ] Seeded recall with crossrefs matches current TypeScript output shape.
- [ ] Existing `apps/silmari-mcp/tests/navigate.test.ts` and recall-related integration tests remain green.

**Manual:**

- [ ] OBSERVE/THINK/LEARN recall examples in `SAI/Algorithm/v3.8.1.md` can be executed against Ultimate without prompt changes.

## Behavior 5: Silmari Resources Are Exposed Through Ultimate

### Resource Registry Binding

- `resource_id`: `[PROPOSED]`
- `address_alias`: `mcp.resource_namespace`
- `predicate_refs`: `apps/silmari-mcp/src/index.ts:440`, `apps/silmari-mcp/src/index.ts:830`, `SAI/commands/silmari.md:64`
- `codepath_ref`: `vendor/ultimate_mcp_server/ultimate_mcp_server/core/silmari_resources.py::register_silmari_resources`
- `schema_contract_refs`: `artifacts/specs/2026-04-28-beads-rust-replacement/05-viewer-export-and-consumers.md::MCP And SAI Contracts`

### Schema Interface Mapping

- `loop_mode`: `summary`
- `mapped_contracts`: `MCPAndSAIContracts.silmari_resources -> [PROPOSED] mcp.resource_namespace`
- `registry_updates`: `[PROPOSED] add schema_refs after canonical registry exists`

### Test Specification

**Given**: Ultimate Silmari compatibility resources are registered  
**When**: an MCP client lists and reads resources  
**Then**: static resources include the current Silmari URI list, dynamic reads for `silmari://card/<id>`, `silmari://chain/<address>`, and `silmari://register/<slot>` delegate to the current Silmari resource dispatcher, and Ultimate's default documentation/example resources are hidden from Algorithm-facing clients

**Edge Cases**:

- Unknown `silmari://` URI raises a resource read error.
- `silmari://trunks` falls back to JSON trunk data if the markdown file is missing, matching current behavior.
- Dynamic resources are readable even if not listed by `resources/list`.
- Static resource-list parity and unlisted dynamic resource-read parity are separate tests: `test_lists_only_static_silmari_resources` and `test_reads_unlisted_dynamic_silmari_resource_templates`.
- Resource MIME types match the current TypeScript server.
- Default Silmari mode does not list `info://*`, `guide://*`, `examples://*`, provider documentation, or UMS resources.

### TDD Cycle

#### Red: Write Failing Test

**File**: `vendor/ultimate_mcp_server/tests/integration/test_silmari_gateway.py`

```python
def test_registers_static_silmari_resource_uris(gateway):
    resources = register_silmari_resources(gateway.mcp)

    assert "silmari://trunks" in resources
    assert "silmari://keyword-index" in resources
    assert "silmari://proposals" in resources
    assert all(uri.startswith("silmari://") for uri in resources)
```

#### Green: Minimal Implementation

**File**: `vendor/ultimate_mcp_server/ultimate_mcp_server/core/silmari_resources.py`

```python
def register_silmari_resources(mcp_server) -> dict[str, object]:
    """
    @rr.id [PROPOSED]
    @rr.alias mcp.resource_namespace
    @path.id register-silmari-resource-namespace
    @gwt.given an Ultimate FastMCP server with Silmari compatibility enabled
    @gwt.when resources are registered
    @gwt.then the current silmari:// static and dynamic namespace is readable
    @reads [PROPOSED:ultimate.fastmcp_server],[PROPOSED:silmari.resource_dispatcher]
    @writes [PROPOSED:mcp.resource_registry]
    @raises [PROPOSED:silmari_resource_error]
    @schema.contract artifacts/specs/2026-04-28-beads-rust-replacement/05-viewer-export-and-consumers.md::MCP And SAI Contracts
    """
    resources = {}

    @mcp_server.resource("silmari://trunks")
    async def trunks() -> str:
        return await call_silmari_resource("silmari://trunks")

    resources["silmari://trunks"] = trunks
    return resources
```

#### Refactor

- Generate static resource registrations from the current `STATIC_RESOURCES` snapshot.
- Add dynamic resource patterns after static reads pass.
- Keep Ultimate `info://*` resources separate; do not overload them with Silmari data.
- Keep Ultimate `info://*`, `guide://*`, and `examples://*` resources out of the default Silmari MCP runtime so the MCP server footprint remains the Algorithm memory namespace.

### Success Criteria

**Automated:**

- [x] Resource list tests pass.
- [ ] Static listed resources and unlisted dynamic resource templates are tested separately.
- [ ] Dynamic resource read parity tests compare Ultimate output to TypeScript `dispatchResource()`.
- [ ] Default MCP footprint resource tests fail if any non-`silmari://` resource is listed in default Silmari mode.

**Manual:**

- [ ] `/silmari` command workflows can read `silmari://trunks` and `silmari://register/5`.

## Behavior 6: Reviewed Links, Hubs, And Lifecycle Tools Preserve Algorithm LEARN Protocol

### Resource Registry Binding

- `resource_id`: `[PROPOSED]`
- `address_alias`: `sai.learn_memory_protocol`
- `predicate_refs`: `SAI/Algorithm/v3.8.1.md:545`, `SAI/Algorithm/v3.8.1.md:573`, `SAI/Algorithm/v3.8.1.md:583`
- `codepath_ref`: `vendor/ultimate_mcp_server/ultimate_mcp_server/tools/silmari_compat.py::zk_propose_link`, `::zk_commit_link`, `::zk_hub_create`, `::zk_recall_by_status`, `::zk_promote`
- `schema_contract_refs`: `artifacts/specs/2026-04-28-beads-rust-replacement/05-viewer-export-and-consumers.md::MCP And SAI Contracts`

### Schema Interface Mapping

- `loop_mode`: `summary`
- `mapped_contracts`: `MCPAndSAIContracts.zk_promote -> [PROPOSED] sai.learn_memory_protocol`; `MCPAndSAIContracts.zk_block -> [PROPOSED] sai.learn_memory_protocol`
- `registry_updates`: `[PROPOSED] add schema_refs after canonical registry exists`

### Test Specification

**Given**: Algorithm LEARN calls reviewed edge, hub, and status lifecycle tools through Ultimate  
**When**: `zk_propose_link`, `zk_commit_link`, `zk_hub_create`, `zk_hub_add_card`, `zk_recall_by_status`, and `zk_promote` run  
**Then**: Ultimate returns the same proposal, hub, status-filtered recall, and promotion behavior as the current TypeScript server

**Edge Cases**:

- `zk_propose_link` always creates a proposal at the tool level.
- `zk_commit_link` writes the reviewed edge only for pending proposals.
- `zk_hub_create` is idempotent by `(trunk, label)`.
- `zk_recall_by_status` supports `withNeighborhood`.
- `zk_promote` rejects `blocked -> open` without `force: true`.

### TDD Cycle

#### Red: Write Failing Test

**File**: `apps/silmari-mcp/tests/ultimate-compat-parity.test.ts`

```ts
describe('Ultimate LEARN protocol parity', () => {
  it('preserves blocked-to-open force guard', async () => {
    const result = await callUltimateCompatTool('zk_promote', {
      cardId: 'zk-nonexistent-000',
      toStatus: 'open',
      reason: 'test',
    });

    expect(result.isError).toBe(true);
    expect(result.content[0].text).toContain('card');
  });
});
```

#### Green: Minimal Implementation

**File**: `vendor/ultimate_mcp_server/ultimate_mcp_server/tools/silmari_compat.py`

```python
async def zk_promote(cardId: str, toStatus: str, reason: str,
                     box: str = "idea", force: bool = False) -> dict:
    """
    @rr.id [PROPOSED]
    @rr.alias sai.learn_memory_protocol
    @path.id ultimate-zk-promote-parity
    @gwt.given a Silmari card lifecycle transition request
    @gwt.when zk_promote is called through Ultimate MCP
    @gwt.then current status transition rules and error messages remain observable
    @reads [PROPOSED:silmari.card_status]
    @writes [PROPOSED:silmari.card_status],[PROPOSED:mcp.tool_result]
    @raises [PROPOSED:silmari_bridge_error]
    @schema.contract artifacts/specs/2026-04-28-beads-rust-replacement/05-viewer-export-and-consumers.md::MCP And SAI Contracts
    """
    return await call_silmari_tool("zk_promote", compact_args(locals()))
```

#### Refactor

- Implement all lifecycle/link/hub wrappers through one generated wrapper factory after individual tests pin the tricky behavior.
- Add separate tests for `zk_block` direction because docs and dispatcher wording currently drift.

### Success Criteria

**Automated:**

- [x] Existing `apps/silmari-mcp/tests/recall-promote.test.ts` passes.
- [ ] Ultimate parity tests cover at least one happy path and one error path for lifecycle and reviewed links.

**Manual:**

- [ ] Algorithm LEARN examples requiring save, link, hub, and in-progress capture work with Ultimate as the MCP process.

## Behavior 7: ThinkWithMemory Uses A Stable Recall Client

### Resource Registry Binding

- `resource_id`: `[PROPOSED]`
- `address_alias`: `sai.think_hook_recall`
- `predicate_refs`: `SAI/hooks/ThinkWithMemory.hook.ts:117`, `SAI/hooks/lib/think-with-memory.ts:194`, `SAI/settings.json:192`, `SAI/THEHOOKSYSTEM.md:736`
- `codepath_ref`: `SAI/hooks/lib/silmari-recall-client.ts::recallWithSilmari`
- `schema_contract_refs`: `artifacts/specs/2026-04-28-beads-rust-replacement/05-viewer-export-and-consumers.md::MCP And SAI Contracts`, `SAI/THEHOOKSYSTEM.md::Hook Performance`, `SAI/settings.json::UserPromptSubmit`

### Schema Interface Mapping

- `loop_mode`: `summary`
- `mapped_contracts`: `MCPAndSAIContracts.sai_recall -> [PROPOSED] sai.think_hook_recall`
- `registry_updates`: `[PROPOSED] add schema_refs after canonical registry exists`

### Test Specification

**Given**: the ThinkWithMemory hook needs recall data during `UserPromptSubmit`  
**When**: the hook calls the new recall client  
**Then**: the client returns `keywordEntries`, `folgezettelNeighbors`, and `crossRefs` in the existing hook-facing shape whether the source is the current direct TypeScript import path or a future MCP/Ultimate path, stays inside the SAI hook lifecycle budget, exits cleanly on failures/timeouts, and the hook does not expose raw runtime internals to the LLM

**Edge Cases**:

- Existing direct import behavior remains the default until MCP hook calls are proven safe.
- Missing Silmari modules return `{}` and do not block hook execution.
- Card ID entry points still hydrate via `brShow`.
- Crossrefs are included only when requested.
- Hook summaries include only contract keys and card-level memory content; they do not include Ultimate config, provider names, process command lines, database paths, or unrestricted resource listings.
- Slow recall is cancelled or ignored before the hook lifecycle budget is exhausted; the target budget is 450ms to preserve SAI's under-500ms hook promise.
- Hook failures, missing modules, invalid recall output, and timeout fallback return `{}` or an empty summary and never produce a nonzero hook exit.
- `SAI/settings.json` continues to register `ThinkWithMemory.hook.ts` under `UserPromptSubmit`, and `SAI/THEHOOKSYSTEM.md` is updated so docs match settings.
- Existing event/notification behavior is not truncated or suppressed when ThinkWithMemory changes; event log tests assert append-only preservation.

### TDD Cycle

#### Red: Write Failing Test

**File**: `SAI/hooks/tests/think-with-memory-silmari-client.test.ts`

```ts
import { describe, expect, it } from 'bun:test';

const { summarizeRecall } = await import('../ThinkWithMemory.hook.ts');

describe('ThinkWithMemory Silmari recall client', () => {
  it('normalizes NavigationSession to hook RecallSummary keys', () => {
    const summary = summarizeRecall({
      entryCards: [{ id: 'zk-1', title: 'entry' }],
      folgezettelNeighbors: [{ id: 'zk-2', title: 'neighbor' }],
      crossRefs: [{ id: 'zk-3', title: 'xref' }],
    });

    expect(summary.keywordEntries?.[0]?.id).toBe('zk-1');
    expect(summary.folgezettelNeighbors?.[0]?.id).toBe('zk-2');
    expect(summary.crossRefs?.[0]?.id).toBe('zk-3');
    expect(Object.keys(summary).sort()).toEqual(['crossRefs', 'folgezettelNeighbors', 'keywordEntries']);
  });
});
```

**File**: `SAI/hooks/tests/think-with-memory-lifecycle.test.ts`

```ts
import { describe, expect, it } from 'bun:test';

const { recallWithSilmari, HOOK_RECALL_TIMEOUT_MS } =
  await import('../lib/silmari-recall-client.ts');

describe('ThinkWithMemory hook lifecycle', () => {
  it('times out slow recall and falls back without throwing', async () => {
    const started = Date.now();
    const summary = await recallWithSilmari('slow query', {
      recallImpl: () => new Promise(() => {}),
      timeoutMs: 25,
    });

    expect(Date.now() - started).toBeLessThan(HOOK_RECALL_TIMEOUT_MS);
    expect(summary).toEqual({});
  });

  it('keeps ThinkWithMemory registered for UserPromptSubmit', async () => {
    const settings = await Bun.file('SAI/settings.json').json();
    const commands = settings.hooks.UserPromptSubmit.flatMap((group: any) =>
      group.hooks.map((hook: any) => hook.command),
    );

    expect(commands).toContain('${SAI_DIR}/hooks/ThinkWithMemory.hook.ts');
  });
});
```

#### Green: Minimal Implementation

**File**: `SAI/hooks/lib/silmari-recall-client.ts`

```ts
export async function recallWithSilmari(query: string, opts = {}) {
  /**
   * @rr.id [PROPOSED]
   * @rr.alias sai.think_hook_recall
   * @path.id recall-with-silmari-client
   * @gwt.given a Claude Code hook prompt and a recall query
   * @gwt.when the hook asks Silmari for prior memory
   * @gwt.then the hook receives keywordEntries, folgezettelNeighbors, and crossRefs without knowing the MCP runtime and without blocking UserPromptSubmit
   * @reads [PROPOSED:silmari.recall_source]
   * @writes [PROPOSED:sai.hook_recall_summary]
   * @raises [PROPOSED:none]
   * @schema.contract artifacts/specs/2026-04-28-beads-rust-replacement/05-viewer-export-and-consumers.md::MCP And SAI Contracts; SAI/THEHOOKSYSTEM.md::Hook Performance
   */
  return withTimeout(() => directImportRecall(query, opts), opts.timeoutMs ?? HOOK_RECALL_TIMEOUT_MS)
    .catch(() => ({}));
}

export const HOOK_RECALL_TIMEOUT_MS = 450;
```

#### Refactor

- Move `loadZkRecall()` out of `ThinkWithMemory.hook.ts` into the new client module.
- Keep `ThinkWithMemory.hook.ts` responsible for prompt parsing, state persistence, and injection formatting only.
- Add an optional MCP-backed client path after direct-import parity tests pass.
- Add a fixture that fails if hook output includes Ultimate configuration, command lines, or broad file paths outside card/source references.
- Update `SAI/THEHOOKSYSTEM.md` so the documented `UserPromptSubmit` hook list matches `SAI/settings.json`.
- Add an append-only event-log guard around hook tests: ThinkWithMemory changes must not truncate `MEMORY/STATE/events.jsonl` or prevent adjacent SAI hooks from emitting their events.

### Success Criteria

**Automated:**

- [x] Hook summary normalization tests pass.
- [x] Current ThinkWithMemory behavior is unchanged for direct import mode.
- [ ] Hook footprint tests prove the injected inference-cycle payload is limited to memory summary keys and card/source fields.
- [x] Slow/missing recall tests prove ThinkWithMemory exits cleanly and falls back before the 500ms SAI hook budget.
- [x] Settings/docs registration tests prove `ThinkWithMemory.hook.ts` is registered and documented under `UserPromptSubmit`.
- [ ] Event/notification non-regression tests prove hook changes do not truncate `STATE/events.jsonl` or suppress existing adjacent hook behavior.

**Manual:**

- [ ] Claude Code `UserPromptSubmit` hook still emits the same `<system-reminder>` sections.

## Behavior 8: Local `silmari` CLI Remains A Stable Human And Script Surface

### Resource Registry Binding

- `resource_id`: `[PROPOSED]`
- `address_alias`: `cli.silmari_compat`
- `predicate_refs`: `apps/silmari-mcp/src/cli.ts:168`, `apps/silmari-mcp/src/cli.ts:310`, `SAI/CLI.md:5`, `SAI/TOOLS.md:377`, `SAI/CLIFIRSTARCHITECTURE.md:232`
- `codepath_ref`: `apps/silmari-mcp/src/cli.ts::runRequest`, optional future `vendor/ultimate_mcp_server/...::silmari_cli_bridge`
- `schema_contract_refs`: `artifacts/specs/2026-04-28-beads-rust-replacement/03-store-api-and-adapter.md::Command Groups`, `SAI/CLI.md`, `SAI/TOOLS.md`, `SAI/CLIFIRSTARCHITECTURE.md`

### Schema Interface Mapping

- `loop_mode`: `summary`
- `mapped_contracts`: `StoreAPIAndAdapterSpec.command_groups -> [PROPOSED] cli.silmari_compat`
- `registry_updates`: `[PROPOSED] add schema_refs after canonical registry exists`

### Test Specification

**Given**: scripts or humans invoke `silmari status`, `silmari recall`, or `silmari register`  
**When**: Ultimate compatibility is introduced  
**Then**: the existing CLI either continues to target the TypeScript server or can be explicitly switched to Ultimate without changing output shape, default `SILMARI_DIR`, or exit-code semantics

**Edge Cases**:

- No `SILMARI_DIR` uses `$HOME/.silmari-memory`.
- Tool `isError` exits nonzero and writes stderr.
- Resource read prints resource text.
- Unknown subcommand exits 2 by current Silmari CLI parity; SAI CLI-first docs do not define a different numeric code, so the plan explicitly chooses existing Silmari behavior for compatibility.
- Backend selection supports an explicit CLI flag, `silmari --backend ultimate status`, with `SILMARI_MCP_BACKEND=ultimate` accepted only as a non-interactive convenience.
- If `silmari` remains a stable SAI CLI surface, `SAI/CLI.md` and `SAI/TOOLS.md` must document the status/recall/register/tool surfaces before rollout.

### TDD Cycle

#### Red: Write Failing Test

**File**: `apps/silmari-mcp/tests/ultimate-compat-parity.test.ts`

```ts
describe('silmari CLI compatibility', () => {
  it('keeps status output as JSON text when using Ultimate backend', async () => {
    const result = await runSilmariCli(['--backend', 'ultimate', 'status']);

    expect(result.exitCode).toBe(0);
    expect(() => JSON.parse(result.stdout)).not.toThrow();
  });
});
```

#### Green: Minimal Implementation

**File**: `apps/silmari-mcp/src/cli.ts`

```ts
function resolveServerCommand(backend: string): { command: string; args: string[] } {
  /**
   * @rr.id [PROPOSED]
   * @rr.alias cli.silmari_compat
   * @path.id resolve-silmari-cli-backend
   * @gwt.given a local silmari CLI invocation
   * @gwt.when the caller selects the Ultimate backend
   * @gwt.then the CLI talks to an MCP-compatible process while preserving stdout and exit semantics
   * @reads [PROPOSED:cli.env],[PROPOSED:cli.args],[PROPOSED:sai.cli_docs]
   * @writes [PROPOSED:cli.mcp_transport]
   * @raises [PROPOSED:cli_backend_config_error]
   * @schema.contract artifacts/specs/2026-04-28-beads-rust-replacement/03-store-api-and-adapter.md::Command Groups; SAI/CLI.md; SAI/TOOLS.md
   */
  if (backend === 'ultimate') {
    return { command: 'umcp', args: ['--transport', 'stdio', '--silmari-compat'] };
  }
  if (backend !== 'typescript') fail(`unknown backend: ${backend}`);
  return { command: 'bun', args: [SERVER_INDEX] };
}

function parseGlobalBackend(argv: string[]): { backend: string; rest: string[] } {
  const backend = process.env.SILMARI_MCP_BACKEND ?? 'typescript';
  if (argv[0] === '--backend') return { backend: argv[1] ?? '', rest: argv.slice(2) };
  return { backend, rest: argv };
}
```

#### Refactor

- Keep default CLI backend as TypeScript until Ultimate parity is complete.
- Update `SAI/CLI.md` and `SAI/TOOLS.md` in the same slice that makes `silmari --backend ultimate` stable.
- Keep env-var backend selection as a compatibility convenience, not the only public control.

### Success Criteria

**Automated:**

- [x] CLI backend selection test fails first.
- [x] Existing CLI behavior remains unchanged without the backend env var.
- [x] Explicit `--backend ultimate` selection works and env-only selection remains covered as a secondary path.
- [x] `SAI/CLI.md` and `SAI/TOOLS.md` mention the `silmari` CLI bridge and its compatibility backend.

**Manual:**

- [ ] `silmari status` remains usable for humans during migration.

## Behavior 9: Ultimate UMS And SAI Work State Are Isolated From Silmari Compatibility

### Resource Registry Binding

- `resource_id`: `[PROPOSED]`
- `address_alias`: `ultimate.ums_and_sai_state_isolation`
- `predicate_refs`: `vendor/ultimate_mcp_server/ultimate_mcp_server/tools/__init__.py:1`, `vendor/ultimate_mcp_server/tools_list.json`, `SAI/MEMORYSYSTEM.md:236`, `SAI/PRDFORMAT.md:3`, `SAI/THEHOOKSYSTEM.md:1253`
- `codepath_ref`: `vendor/ultimate_mcp_server/ultimate_mcp_server/tools/silmari_compat.py::SILMARI_USES_UMS`, `apps/silmari-mcp/tests/sai-compat-noninterference.test.ts`
- `schema_contract_refs`: `SAI/MEMORYSYSTEM.md`, `SAI/PRDFORMAT.md`, `SAI/THEHOOKSYSTEM.md::Unified Event System`

### Schema Interface Mapping

- `loop_mode`: `summary`
- `mapped_contracts`: `SAIMemorySystem.work_state -> [PROPOSED] ultimate.ums_and_sai_state_isolation`; `SAIPRDFormat.source_of_truth -> [PROPOSED] ultimate.ums_and_sai_state_isolation`
- `registry_updates`: `[PROPOSED] add schema_refs only if a future UMS parity or SAI memory schema exists`

### Test Specification

**Given**: Ultimate UMS tools are present in the same server process and SAI MEMORY/PRD state exists on disk
**When**: Silmari compatibility tools run  
**Then**: they do not call `store_memory`, `query_memories`, `create_memory_link`, or `get_rich_context_package` as a substitute for Silmari card operations, and they do not write PRDs, derived work state, learning state, or event logs outside existing SAI hook-owned paths

**Edge Cases**:

- UMS may remain registered as separate Ultimate tools when compatibility mode allows base tools.
- Silmari compatibility tests fail if a `zk_*` tool writes `unified_agent_memory.db`.
- Silmari compatibility tests fail if a `zk_*` call writes `MEMORY/WORK/**/PRD.md`, `MEMORY/STATE/work.json`, current-work state, `MEMORY/LEARNING/**`, or truncates/appends `MEMORY/STATE/events.jsonl`.
- Existing SAI hooks may still write their owned state when invoked by their normal events; this compatibility layer must not duplicate those writes or call PRDSync directly.
- PRD source-of-truth remains the PRD file and PRDSync-derived state, not Silmari cards and not Ultimate UMS.
- Future UMS integration must introduce separate migration/parity tests before changing this rule.

### TDD Cycle

#### Red: Write Failing Test

**File**: `vendor/ultimate_mcp_server/tests/unit/test_silmari_compat.py`

```python
def test_silmari_compat_does_not_use_ums_for_card_storage(monkeypatch):
    called = False

    async def fake_store_memory(*args, **kwargs):
        nonlocal called
        called = True

    monkeypatch.setattr("ultimate_mcp_server.tools.unified_memory_system.store_memory", fake_store_memory)

    assert SILMARI_USES_UMS is False
    assert called is False
```

**File**: `apps/silmari-mcp/tests/sai-compat-noninterference.test.ts`

```ts
import { describe, expect, it } from 'bun:test';
import { writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';

describe('Ultimate Silmari compatibility SAI state non-interference', () => {
  it('does not mutate PRD, derived work state, learning state, or events', async () => {
    const saiHome = makeTempSaiHome();
    const prd = join(saiHome, 'MEMORY/WORK/20260428-test/PRD.md');
    const work = join(saiHome, 'MEMORY/STATE/work.json');
    const events = join(saiHome, 'MEMORY/STATE/events.jsonl');
    mkdirSync(join(saiHome, 'MEMORY/WORK/20260428-test'), { recursive: true });
    mkdirSync(join(saiHome, 'MEMORY/STATE'), { recursive: true });
    writeFileSync(prd, '---\ntask: test\n---\n# PRD\n');
    writeFileSync(work, '{"items":[]}\n');
    writeFileSync(events, '{"type":"baseline"}\n');

    const before = snapshotFiles([prd, work, events]);
    await callUltimateCompatTool('zk_status', {}, { SAI_MEMORY_DIR: join(saiHome, 'MEMORY') });

    expect(snapshotFiles([prd, work, events])).toEqual(before);
  });
});
```

#### Green: Minimal Implementation

**File**: `vendor/ultimate_mcp_server/ultimate_mcp_server/tools/silmari_compat.py`

```python
SILMARI_USES_UMS = False
```

**Documentation Contract:**

```python
"""
@rr.id [PROPOSED]
@rr.alias ultimate.ums_and_sai_state_isolation
@path.id isolate-ums-and-sai-state-from-silmari-compat
@gwt.given Ultimate UMS, SAI MEMORY, and Silmari compatibility run in the same workspace
@gwt.when zk_* compatibility tools are called
@gwt.then Silmari card behavior is delegated to the current Silmari contract rather than UMS memory primitives or SAI PRD/work-state writes
@reads [PROPOSED:ultimate.ums_tool_registry],[PROPOSED:silmari.compat_contract],[PROPOSED:sai.prd_state],[PROPOSED:sai.event_log]
@writes [PROPOSED:silmari.compat_decision]
@raises [PROPOSED:none]
@schema.contract SAI/MEMORYSYSTEM.md; SAI/PRDFORMAT.md; SAI/THEHOOKSYSTEM.md::Unified Event System
"""
```

#### Refactor

- Add an ADR-style note inside the plan or implementation docs explaining why UMS is not a semantic replacement yet.
- Add a non-interference helper that snapshots SAI PRD, work state, learning state, and event log files before/after compatibility calls.
- If later UMS migration is desired, require a separate TDD plan with fixture parity for card IDs, folgezettel, labels, resources, and SAI lifecycle tools.

### Success Criteria

**Automated:**

- [ ] Compatibility tests do not create or mutate UMS storage.
- [x] Compatibility tests do not mutate SAI PRDs, PRDSync-derived work state, current-work state, learning state, or `STATE/events.jsonl`.
- [ ] Event log tests prove compatibility calls never truncate or append SAI events except when an existing SAI hook is explicitly under test.
- [ ] UMS unit tests still pass independently.

**Manual:**

- [ ] Reviewers can see from code and tests that UMS and SAI work memory are not silently replacing Silmari semantics or being overwritten by compatibility calls.

## Behavior 10: Default MCP Footprint And SAI Context Contract Are Audited

### Resource Registry Binding

- `resource_id`: `[PROPOSED]`
- `address_alias`: `mcp.default_silmari_footprint`
- `predicate_refs`: `SAI/Algorithm/LATEST`, `SAI/Algorithm/v3.8.1.md:27`, `SAI/README.md:38`, `SAI/settings.json:192`, `SAI/settings.json:915`, `SAI/CONTEXT_ROUTING.md:3`
- `codepath_ref`: `vendor/ultimate_mcp_server/ultimate_mcp_server/core/silmari_minimal_runtime.py::build_default_silmari_mcp_footprint_manifest`, `::resolve_algorithm_contract`
- `schema_contract_refs`: `artifacts/specs/2026-04-28-beads-rust-replacement/05-viewer-export-and-consumers.md::MCP And SAI Contracts`, `SAI/CONTEXT_ROUTING.md`, `SAI/README.md`, `SAI/settings.json`, `SAI/THEFABRICSYSTEM.md`, `SAI/PIPELINES.md`, `SAI/FLOWS.md`, `SAI/SAIAGENTSYSTEM.md`, `SAI/THEDELEGATIONSYSTEM.md`

### Schema Interface Mapping

- `loop_mode`: `summary`
- `mapped_contracts`: `MCPAndSAIContracts.sai_recall -> [PROPOSED] mcp.default_silmari_footprint`; `MCPAndSAIContracts.silmari_resources -> [PROPOSED] mcp.default_silmari_footprint`; `SAIContextRouting.allowed_context -> [PROPOSED] mcp.default_silmari_footprint`
- `registry_updates`: `[PROPOSED] add schema_refs after canonical registry exists`

### Test Specification

**Given**: an Algorithm inference cycle starts with Ultimate registered as `silmari`
**When**: the default MCP server manifest, tool list, resource list, hook summary, Algorithm authority, and SAI allowed context surfaces are audited
**Then**: the default `silmari` MCP server exposes only `mcp__silmari__zk_*` tools and `silmari://*` resources, the Algorithm contract resolves from `SAI/Algorithm/LATEST`, compact hook recall summaries stay bounded, and legitimate SAI startup/on-demand context is listed separately rather than mislabeled as an Ultimate MCP leak

**Edge Cases**:

- The manifest resolves `SAI/Algorithm/LATEST` to the pinned Algorithm file and fails if SAI docs that claim the current version drift from that authority.
- The manifest includes the default MCP server footprint and an `allowed_sai_context_surfaces` list, but does not include broad repo file lists.
- Hook summary keys are bounded to `keywordEntries`, `folgezettelNeighbors`, and `crossRefs`.
- Provider-routing, document, filesystem, web, and UMS tools are absent from default Silmari mode.
- `settings.json -> loadAtStartup`, `settings.json -> dynamicContext`, and `SAI/CONTEXT_ROUTING.md` surfaces are allowed SAI context, not MCP resources.
- Fabric, Actions, Pipelines, Flows, named agents, custom agents, team delegation, and notification/event systems are not disabled or hidden by Silmari MCP footprint controls.
- Wider Ultimate modes can exist for non-Algorithm use, but they must not be selected by the default Silmari MCP config.

### TDD Cycle

#### Red: Write Failing Test

**File**: `vendor/ultimate_mcp_server/tests/integration/test_silmari_gateway.py`

```python
from ultimate_mcp_server.core.silmari_minimal_runtime import (
    build_default_silmari_mcp_footprint_manifest,
    resolve_algorithm_contract,
)


def test_default_silmari_mcp_footprint_manifest_is_minimal_but_sai_context_is_accounted():
    manifest = build_default_silmari_mcp_footprint_manifest(
        tool_names=["zk_status", "zk_recall"],
        resource_uris=["silmari://trunks", "silmari://register/5"],
        hook_summary_keys=["keywordEntries", "folgezettelNeighbors", "crossRefs"],
        algorithm_contract=resolve_algorithm_contract(latest_path="SAI/Algorithm/LATEST"),
        allowed_sai_context_surfaces=[
            "CLAUDE.md",
            "AGENTS.md",
            "settings.loadAtStartup",
            "settings.dynamicContext",
            "SAI/CONTEXT_ROUTING.md",
            "SAI/THEFABRICSYSTEM.md",
            "SAI/PIPELINES.md",
            "SAI/FLOWS.md",
            "SAI/SAIAGENTSYSTEM.md",
            "SAI/THEDELEGATIONSYSTEM.md",
        ],
    )

    assert manifest["algorithm_authority"] == "SAI/Algorithm/LATEST"
    assert manifest["algorithm"] == "SAI/Algorithm/v3.8.1.md"
    assert manifest["mcp_tool_prefixes"] == ["zk_"]
    assert manifest["mcp_resource_prefixes"] == ["silmari://"]
    assert "settings.loadAtStartup" in manifest["allowed_sai_context_surfaces"]
    assert "SAI/FLOWS.md" in manifest["allowed_sai_context_surfaces"]
    assert manifest["hook_summary_keys"] == [
        "keywordEntries",
        "folgezettelNeighbors",
        "crossRefs",
    ]


def test_algorithm_version_authority_has_no_doc_drift():
    contract = resolve_algorithm_contract(
        latest_path="SAI/Algorithm/LATEST",
        docs_that_claim_current_version=["SAI/README.md"],
    )

    assert contract["version"] == "v3.8.1"
    assert contract["path"] == "SAI/Algorithm/v3.8.1.md"
```

#### Green: Minimal Implementation

**File**: `vendor/ultimate_mcp_server/ultimate_mcp_server/core/silmari_minimal_runtime.py`

```python
ALLOWED_HOOK_SUMMARY_KEYS = ("keywordEntries", "folgezettelNeighbors", "crossRefs")
ALLOWED_SAI_CONTEXT_SURFACES = (
    "CLAUDE.md",
    "AGENTS.md",
    "settings.loadAtStartup",
    "settings.dynamicContext",
    "SAI/CONTEXT_ROUTING.md",
    "SAI/THEFABRICSYSTEM.md",
    "SAI/PIPELINES.md",
    "SAI/FLOWS.md",
    "SAI/SAIAGENTSYSTEM.md",
    "SAI/THEDELEGATIONSYSTEM.md",
)


def resolve_algorithm_contract(latest_path: str, docs_that_claim_current_version=None):
    """
    @rr.id [PROPOSED]
    @rr.alias mcp.default_silmari_footprint
    @path.id resolve-sai-algorithm-authority
    @gwt.given SAI Algorithm docs and a LATEST authority file
    @gwt.when compatibility resolves the runtime Algorithm contract
    @gwt.then the pinned Algorithm path comes from LATEST and stale docs are detected before rollout
    @reads [PROPOSED:sai.algorithm_latest],[PROPOSED:sai.algorithm_docs]
    @writes [PROPOSED:sai.algorithm_contract_manifest]
    @raises [PROPOSED:sai_algorithm_version_drift]
    @schema.contract SAI/Algorithm/LATEST; SAI/README.md
    """
    version = Path(latest_path).read_text().strip()
    path = f"SAI/Algorithm/{version}.md"
    assert Path(path).exists(), f"Algorithm file missing: {path}"
    assert_docs_match_version(docs_that_claim_current_version or [], version)
    return {"authority": latest_path, "version": version, "path": path}


def build_default_silmari_mcp_footprint_manifest(
    tool_names,
    resource_uris,
    hook_summary_keys,
    algorithm_contract,
    allowed_sai_context_surfaces,
):
    """
    @rr.id [PROPOSED]
    @rr.alias mcp.default_silmari_footprint
    @path.id build-default-silmari-mcp-footprint-manifest
    @gwt.given an Algorithm inference cycle backed by Ultimate as the Silmari runtime
    @gwt.when the default MCP footprint and allowed SAI context are summarized
    @gwt.then the manifest separates minimal Silmari MCP exposure from legitimate SAI startup/context-routing surfaces
    @reads [PROPOSED:mcp.tool_registry],[PROPOSED:mcp.resource_registry],[PROPOSED:sai.hook_recall_summary],[PROPOSED:sai.context_routing]
    @writes [PROPOSED:mcp.default_footprint_manifest]
    @raises [PROPOSED:mcp_footprint_violation]
    @schema.contract artifacts/specs/2026-04-28-beads-rust-replacement/05-viewer-export-and-consumers.md::MCP And SAI Contracts; SAI/CONTEXT_ROUTING.md; SAI/settings.json
    """
    assert_default_silmari_mcp_footprint(tool_names=tool_names, resource_uris=resource_uris)
    keys = list(hook_summary_keys)
    if keys != list(ALLOWED_HOOK_SUMMARY_KEYS):
        raise AssertionError(f"unexpected hook summary keys: {keys}")
    for surface in allowed_sai_context_surfaces:
        if surface not in ALLOWED_SAI_CONTEXT_SURFACES:
            raise AssertionError(f"unexpected SAI context surface: {surface}")
    return {
        "algorithm_authority": algorithm_contract["authority"],
        "algorithm": algorithm_contract["path"],
        "mcp_tool_prefixes": ["zk_"],
        "mcp_resource_prefixes": ["silmari://"],
        "hook_summary_keys": keys,
        "allowed_sai_context_surfaces": list(allowed_sai_context_surfaces),
    }
```

#### Refactor

- Emit this manifest in tests only at first; do not add prompt-visible debug output.
- Use the manifest as the acceptance gate before any default MCP config changes.
- If the commercial app later needs extra MCP-visible capabilities, require a new manifest entry and a specific Algorithm/SAI contract reference.
- Amend `SAI/README.md` to match `SAI/Algorithm/LATEST` before this behavior can pass.
- Keep SAI context routing, Fabric, Pipelines, Flows, agents, delegation, and notifications in the allowed SAI context list only; do not register them as default Silmari MCP tools/resources.

### Success Criteria

**Automated:**

- [x] Manifest tests fail before `silmari_minimal_runtime.py` exists.
- [x] Manifest tests pass only when tools/resources stay within the default Silmari MCP surface and hook keys stay within the allowed summary contract.
- [x] Algorithm authority tests fail until `SAI/README.md` matches `SAI/Algorithm/LATEST`.
- [x] Tests fail if a default Silmari runtime exposes Ultimate provider, filesystem, document, web, or UMS capabilities.
- [ ] Allowed SAI context tests prove `loadAtStartup`, `dynamicContext`, `SAI/CONTEXT_ROUTING.md`, Fabric, Actions/Pipelines/Flows, and agent/delegation docs are accounted separately from MCP resources.

**Manual:**

- [ ] Reviewer can answer "what does the default `silmari` MCP server expose?" and "what SAI context remains allowed?" from one manifest and the referenced Algorithm/SAI contracts.

## Integration And E2E Testing

### Integration Scenarios

- Start `Gateway(name="silmari")`, register Silmari compatibility, call `zk_status`, and parse JSON text.
- Audit the Silmari runtime manifest and assert only `zk_*` tools and `silmari://*` resources are exposed by the default MCP server while allowed SAI startup/context-routing surfaces are listed separately.
- Resolve the Algorithm contract through `SAI/Algorithm/LATEST` and fail if SAI docs name a conflicting current version.
- Exercise `silmari tool zk_status '{}'` as the generic bridge used by Ultimate subprocess delegation.
- Seed a temp `SILMARI_DIR`, call current TypeScript `dispatchTool()` and Ultimate compatibility `zk_recall`, and compare normalized JSON.
- Read `silmari://trunks` and `silmari://register/root` through Ultimate resources.
- Execute Algorithm LEARN lifecycle scenarios: save a card, propose a reviewed edge, commit it, create a hub, and recall by status.
- Seed temp SAI MEMORY/PRD state and prove compatibility calls do not mutate PRDs, PRDSync-derived state, learning state, or `STATE/events.jsonl`.
- Simulate ThinkWithMemory slow/missing recall and prove timeout fallback, clean exit, settings registration, and event-log non-regression.
- Smoke-test named-agent, custom-agent, team delegation, Fabric, Actions, Pipelines, and Flows routing metadata as unaffected by default Silmari MCP mode.

### E2E User Flows

- Algorithm OBSERVE: run `mcp__silmari__zk_recall({query, expandCrossRefs:true, maxDepth:1, direction:"both"})` with Ultimate registered as `silmari`.
- Algorithm THINK: targeted recall for a risk query returns current `NavigationSession` shape.
- Algorithm LEARN: save learning/preference cards, propose/commit semantic edge, create hub when repeated, save `in_progress` marker when unfinished.
- Manual `/silmari`: list trunks/resources and call `zk_status`.
- CLI bridge: run `silmari tool zk_status '{}'` and `silmari --backend ultimate status`; both return current Silmari-shaped JSON.
- Default MCP footprint audit: verify the default MCP server exposes `mcp__silmari__zk_*` and `silmari://*` only, and verify the separate allowed SAI context list includes startup files, dynamic context, context routing, PRD/Memory docs, Fabric, Actions, Pipelines, Flows, agent/delegation docs, and notifications.
- SAI non-interference: run compatibility calls during an Algorithm-like session and verify PRDs, derived work state, learning state, and append-only event logs remain governed by existing SAI paths.

## Rollout Order

1. Add Algorithm authority and default MCP footprint manifest tests before wiring any default runtime changes.
2. Amend stale Algorithm-version docs so `SAI/README.md` matches `SAI/Algorithm/LATEST`.
3. Add Python compatibility module with semantic envelope helpers and mocked subprocess tests.
4. Add the generic `silmari tool <zk_name> <json>` bridge in the current CLI.
5. Add tool-name/spec snapshot parity tests.
6. Register all `zk_*` names and one read-only static resource through Ultimate in default minimal Silmari mode.
7. Add subprocess delegation and `zk_recall` parity through the real generic bridge.
8. Expand wrappers to all `zk_*` tools.
9. Add listed static resource parity and unlisted dynamic resource parity.
10. Refactor ThinkWithMemory into a stable recall client with hook lifecycle, settings/docs registration, hook-footprint, and event-log tests.
11. Add SAI MEMORY/PRD/work-state non-interference tests.
12. Add explicit CLI backend flag/docs for humans/scripts, not as a wider MCP-facing surface.
13. Run Algorithm OBSERVE/THINK/LEARN lifecycle smoke tests, agent/delegation/Fabric/Pipeline/Flow unaffected checks, and default MCP footprint audits against Ultimate.

## References

- Research: `thoughts/searchable/shared/research/2026-04-28-ultimate-mcp-server-silmari-mcp-algorithm-contracts.md`
- Review addressed: `thoughts/searchable/shared/plans/2026-04-28-silmari-agent-memory-xq6-tdd-ultimate-mcp-silmari-compatibility-REVIEW.md`
- Beads issue: `silmari-agent-memory-xq6`
- Review follow-up issue: `silmari-agent-memory-9v3`
- Prior research issue: `silmari-agent-memory-ee7`
- Current tool schema and dispatcher: `apps/silmari-mcp/src/index.ts:101`, `apps/silmari-mcp/src/index.ts:527`
- Current resources: `apps/silmari-mcp/src/index.ts:440`, `apps/silmari-mcp/src/index.ts:830`
- Current CLI: `apps/silmari-mcp/src/cli.ts:168`
- Current recall: `apps/silmari-mcp/src/lib/navigate.ts:778`
- Current save result: `apps/silmari-mcp/src/lib/card-ops.ts:179`
- Current keyword index: `apps/silmari-mcp/src/lib/keyword-index.ts:20`
- Current link proposals: `apps/silmari-mcp/src/lib/edges.ts:241`, `apps/silmari-mcp/src/lib/edges.ts:326`
- Ultimate Gateway: `vendor/ultimate_mcp_server/ultimate_mcp_server/core/server.py:185`
- Ultimate tool registration: `vendor/ultimate_mcp_server/ultimate_mcp_server/tools/__init__.py:378`
- Ultimate transport entry: `vendor/ultimate_mcp_server/ultimate_mcp_server/core/server.py:2060`
- SAI Algorithm authority: `SAI/Algorithm/LATEST`
- SAI Algorithm memory contract: `SAI/Algorithm/v3.8.1.md:29`
- SAI README Algorithm-version claim: `SAI/README.md:38`
- SAI startup/context routing: `SAI/settings.json:915`, `SAI/settings.json:921`, `SAI/CONTEXT_ROUTING.md:3`
- SAI Memory/PRD contracts: `SAI/MEMORYSYSTEM.md:236`, `SAI/PRDFORMAT.md:3`
- SAI hook lifecycle/event contracts: `SAI/THEHOOKSYSTEM.md:736`, `SAI/THEHOOKSYSTEM.md:1253`
- SAI CLI/tools docs: `SAI/CLI.md:5`, `SAI/TOOLS.md:377`
- SAI non-MCP routing systems: `SAI/THEFABRICSYSTEM.md`, `SAI/PIPELINES.md`, `SAI/FLOWS.md`, `SAI/SAIAGENTSYSTEM.md`, `SAI/THEDELEGATIONSYSTEM.md`
- SAI ThinkWithMemory direct import: `SAI/hooks/ThinkWithMemory.hook.ts:117`
- Minimal project instruction surfaces: `CLAUDE.md`, `AGENTS.md`
