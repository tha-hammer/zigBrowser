## Plan Review Report: 2026-04-28-silmari-agent-memory-xq6-tdd-ultimate-mcp-silmari-compatibility

Reviewed plan:
`thoughts/searchable/shared/plans/2026-04-28-silmari-agent-memory-xq6-tdd-ultimate-mcp-silmari-compatibility.md`

Reviewed SAI files:
`SAI/CLI.md`, `SAI/CLIFIRSTARCHITECTURE.md`, `SAI/CONTEXT_ROUTING.md`,
`SAI/DOCUMENTATIONINDEX.md`, `SAI/FLOWS.md`, `SAI/MEMORYSYSTEM.md`,
`SAI/PIPELINES.md`, `SAI/PRDFORMAT.md`, `SAI/README.md`,
`SAI/SAIAGENTSYSTEM.md`, `SAI/SAISYSTEMARCHITECTURE.md`,
`SAI/SKILLSYSTEM.md`, `SAI/SYSTEM_USER_EXTENDABILITY.md`,
`SAI/THEDELEGATIONSYSTEM.md`, `SAI/THEFABRICSYSTEM.md`,
`SAI/THEHOOKSYSTEM.md`, `SAI/THENOTIFICATIONSYSTEM.md`, `SAI/TOOLS.md`,
`SAI/UPSTREAM_REF.md`.

### Review Summary

| Category | Status | Issues Found |
| --- | --- | --- |
| Contracts | ❌ | 5 critical, 3 warnings |
| Interfaces | ❌ | 2 critical, 3 warnings |
| Promises | ❌ | 2 critical, 2 warnings |
| Data Models | ⚠️ | 1 critical, 3 warnings |
| APIs | ❌ | 2 critical, 2 warnings |

### Contract Review

#### Well-Defined

- ✅ The plan correctly protects the live Silmari MCP namespace as the product boundary: exact `zk_*` tool names, `silmari://*` resources, and JSON text envelopes are explicit in the desired end state (`plan:119-128`).
- ✅ The plan explicitly keeps Ultimate UMS out of the Silmari compatibility path (`plan:1036-1057`).
- ✅ The upstream PAI provenance boundary is respected. The plan targets live `SAI/hooks` and vendor files, not preserved upstream files; `SAI/UPSTREAM_REF.md:14-16` says `SAI/upstream/` is read-only provenance.

#### Missing or Unclear

1. ❌ **Algorithm version contract conflicts across SAI docs.**
   - Plan evidence: runtime Algorithm is fixed to `SAI/Algorithm/v3.8.1.md` in the LLM-facing contract and manifest (`plan:97-99`, `plan:1173-1175`, `plan:1210-1212`).
   - SAI evidence: `SAI/README.md:37-38` says current Algorithm version is `v3.7.0`.
   - Reality note: `SAI/Algorithm/LATEST` currently says `v3.8.1`, so the implementation target may be right, but the reviewed SAI docs are stale. A TDD plan that asserts an exact Algorithm contract should name the authority: `SAI/Algorithm/LATEST`, a pinned file, or an amended README.

2. ❌ **The LLM footprint contract overclaims “only” visible context.**
   - Plan evidence: the footprint contract says the LLM sees only project instructions, Algorithm, `mcp__silmari__zk_*`, `silmari://*`, and compact hook summaries (`plan:95-101`, `plan:1143-1152`, `plan:1210-1215`).
   - SAI evidence: startup also loads `settings.json -> loadAtStartup` files and dynamic context from `LoadContext.hook.ts` (`SAI/README.md:81-86`), and context routing allows on-demand loading of memory, actions/pipelines, flows, and PRD docs (`SAI/CONTEXT_ROUTING.md:3-22`).
   - Impact: the manifest would undercount legitimate SAI context and could make tests fail for correct SAI behavior.

3. ❌ **Silmari card storage is isolated from UMS, but not from SAI memory/PRD state.**
   - Plan evidence: storage compatibility focuses on `SILMARI_DIR`/`silmari.db` and gates only against UMS writes (`plan:58`, `plan:972`, `plan:1036-1057`).
   - SAI evidence: SAI memory source of truth is `~/.claude/MEMORY/` plus Claude Code `projects/` transcripts (`SAI/MEMORYSYSTEM.md:5-12`, `SAI/MEMORYSYSTEM.md:34-80`). PRD work state is the Algorithm source of truth (`SAI/PRDFORMAT.md:3-6`, `SAI/MEMORYSYSTEM.md:99-126`).
   - Impact: implementation may preserve Silmari card semantics while still accidentally writing, bypassing, or duplicating SAI work state.

4. ⚠️ **SAI contract docs are treated as absent because JSON schemas are absent.**
   - Plan evidence: the registry section says there are “no canonical schema contracts” and proceeds with `[PROPOSED]` IDs (`plan:72-89`).
   - SAI evidence: reviewed docs define concrete contracts even without JSON Schema files: PRD YAML fields (`SAI/PRDFORMAT.md:6-20`), pipeline YAML/action contracts (`SAI/PIPELINES.md:69-82`, `SAI/PIPELINES.md:236-246`), and flow registry JSON (`SAI/FLOWS.md:91-106`).
   - Recommendation: distinguish “no JSON Schema registry” from “no SAI contracts.”

5. ⚠️ **SYSTEM/USER extensibility is not specified for new runtime/config controls.**
   - Plan evidence: config appears as hardcoded filters and environment/Ultimate flags (`plan:280-323`, `plan:986-987`, `plan:1013-1015`).
   - SAI evidence: configurable components should have SYSTEM defaults, USER override locations, cascading lookup, and graceful fallback (`SAI/SYSTEM_USER_EXTENDABILITY.md:7-34`, `SAI/SYSTEM_USER_EXTENDABILITY.md:145-180`).

### Interface Review

#### Well-Defined

- ✅ The plan lists the exact MCP tool names expected in compatibility mode (`plan:121-122`).
- ✅ The current TypeScript server does expose those tool names (`apps/silmari-mcp/src/index.ts:103-414`) and current static resources (`apps/silmari-mcp/src/index.ts:440-450`), so the compatibility target is grounded in code.

#### Missing or Unclear

1. ❌ **The subprocess bridge depends on a generic CLI interface that does not exist yet.**
   - Plan evidence: `call_silmari_tool()` shells out as `tool <name> <json>` (`plan:539-561`), while the missing generic bridge is deferred to “Refactor” (`plan:564-568`).
   - Code evidence: the existing CLI dispatches named subcommands such as `status`, `save`, `recall`, `register`; there is no `tool` subcommand (`apps/silmari-mcp/src/cli.ts:301-357`).
   - Impact: Behavior 3 cannot go green as written. The generic bridge is not a refactor; it is required implementation.

2. ❌ **Hook implementation path and registration contract are inconsistent in SAI docs.**
   - Plan evidence: the plan edits repo-local `SAI/hooks/ThinkWithMemory.hook.ts` and creates `SAI/hooks/lib/silmari-recall-client.ts` (`plan:113-116`, `plan:850-934`).
   - SAI evidence: `SAI/README.md:19-31` describes hooks as living alongside SAI under `~/.claude/hooks/`, and `SAI/THEHOOKSYSTEM.md:124-145` lists only `RatingCapture`, `UpdateTabTitle`, and `SessionAutoName` for `UserPromptSubmit`.
   - Additional reality note: `SAI/settings.json:192-214` does include `ThinkWithMemory.hook.ts`, so `THEHOOKSYSTEM.md` is stale. The plan needs an explicit “source vs installed runtime” contract and a doc update/test for settings registration.

3. ⚠️ **The plan adds backend selection by env var, but SAI CLI design prefers explicit flags.**
   - Plan evidence: `SILMARI_MCP_BACKEND=ultimate` selects the backend (`plan:984-990`, `plan:1013-1017`).
   - SAI evidence: CLI-first design says behavioral controls should be CLI flags and workflow-to-tool mappings (`SAI/CLIFIRSTARCHITECTURE.md:232-248`, `SAI/CLIFIRSTARCHITECTURE.md:604-612`).
   - Recommendation: support `--backend ultimate` or document why env-only backend selection is intentionally outside SAI CLI rules.

4. ⚠️ **The reviewed SAI CLI/Tools docs do not document the `silmari` CLI or MCP namespace.**
   - Plan evidence: Behavior 8 assumes `silmari status`, `silmari recall`, and `silmari register` are stable script/human surfaces (`plan:964-975`).
   - SAI evidence: `SAI/CLI.md:5-10` documents only Algorithm and Arbol CLIs; `SAI/TOOLS.md:1-15` documents single-purpose CLI utilities. `SAI/TOOLS.md:377-391` says new utilities must be documented there.
   - Recommendation: either add `silmari` to `SAI/CLI.md`/`SAI/TOOLS.md` as part of the plan, or stop claiming the reviewed SAI docs back the CLI surface.

### Promise Review

#### Well-Defined

- ✅ Existing hook failure isolation is acknowledged in the plan: missing Silmari modules return `{}` and do not block hook execution (`plan:872-878`).
- ✅ The plan explicitly requires Ultimate base tools/resources to stay hidden in default Algorithm-facing mode (`plan:123-124`, `plan:1149-1152`).

#### Missing or Unclear

1. ❌ **Hook timing and non-blocking promises are missing.**
   - Plan evidence: the future hook client can remain direct import or later call MCP, but no latency budget or timeout/cancellation behavior is specified (`plan:868-878`, `plan:929-934`).
   - SAI evidence: hooks should complete in `< 500ms`, never block on external services unless fast, and always exit cleanly (`SAI/THEHOOKSYSTEM.md:733-748`).
   - Impact: an MCP-backed recall path could freeze or slow `UserPromptSubmit`, violating SAI hook lifecycle promises.

2. ❌ **Notification/event side effects are not covered.**
   - Plan evidence: hook-footprint tests only inspect instruction files, Algorithm, MCP tools/resources, and hook summary keys (`plan:1143-1152`).
   - SAI evidence: SAI Algorithm/CLI sessions send voice notifications (`SAI/CLI.md:132-140`), and hooks emit additive structured events to `STATE/events.jsonl` (`SAI/THENOTIFICATIONSYSTEM.md:292-304`, `SAI/MEMORYSYSTEM.md:232-243`).
   - Impact: the plan could refactor hook behavior while silently dropping event/notification observability guarantees.

3. ⚠️ **Agent/delegation behavior is not smoke-tested.**
   - Plan evidence: E2E flows cover Algorithm OBSERVE/THINK/LEARN and manual `/silmari` only (`plan:1246-1252`).
   - SAI evidence: SAI has three distinct agent systems (`SAI/SAIAGENTSYSTEM.md:7-20`), and delegation distinguishes custom agents from agent teams with different state models (`SAI/THEDELEGATIONSYSTEM.md:73-81`).
   - Recommendation: add one acceptance check proving the default compatibility mode does not change named-agent/custom-agent/team memory or context routing.

### Data Model Review

#### Well-Defined

- ✅ Existing SAI docs clearly define PRD frontmatter and derived work state (`SAI/PRDFORMAT.md:6-20`, `SAI/PRDFORMAT.md:122-130`).
- ✅ Pipeline data contracts are documented as pass-through action chains (`SAI/PIPELINES.md:69-82`, `SAI/PIPELINES.md:236-246`).

#### Missing or Unclear

1. ❌ **No explicit non-interference data contract for PRDs and derived work state.**
   - Plan evidence: Algorithm smoke tests exercise MCP memory calls, but do not assert PRD/work state behavior (`plan:1238-1252`).
   - SAI evidence: PRD is the single source of truth; hooks only read PRDs and sync derived state (`SAI/PRDFORMAT.md:3-6`, `SAI/PRDFORMAT.md:122-130`).
   - Recommendation: add tests that Ultimate compatibility does not write PRDs, does not bypass PRDSync, and does not mutate `MEMORY/STATE/work.json` except through existing SAI hook paths.

2. ⚠️ **Flow terminology conflicts with SAI Flow contracts.**
   - Plan evidence: it uses “LEARN flow primitives” and “E2E User Flows” for Algorithm lifecycle scenarios (`plan:1244-1252`).
   - SAI evidence: Flows are scheduled Source -> Pipeline -> Destination systems with `F_`/registry semantics (`SAI/FLOWS.md:13-34`, `SAI/FLOWS.md:91-106`).
   - Recommendation: rename these to “Algorithm lifecycle scenarios” unless actual `F_` Flow behavior is being tested.

3. ⚠️ **Fabric routing is not explicitly protected.**
   - Plan evidence: the footprint model excludes everything except Algorithm/Silmari surfaces (`plan:1149-1152`, `plan:1210-1215`).
   - SAI evidence: Fabric is a native pattern system invoked through SAI skill routing, not generally via MCP (`SAI/THEFABRICSYSTEM.md:20-35`, `SAI/THEFABRICSYSTEM.md:47-52`).
   - Recommendation: add a non-goal/regression note that minimal MCP mode does not disable SAI skill routing, Fabric, Actions, Pipelines, or Flows.

### API Review

#### Well-Defined

- ✅ Current TypeScript MCP resource MIME types and error behavior are concrete (`apps/silmari-mcp/src/index.ts:440-460`, `apps/silmari-mcp/src/index.ts:830-877`).
- ✅ The plan includes parity tests for resource listing, dynamic reads, and text envelopes (`plan:342-475`, `plan:668-755`).

#### Missing or Unclear

1. ❌ **The plan’s exact JSON envelope helper does not match current TypeScript serialization.**
   - Plan evidence: `mcp_text_json()` serializes compact JSON with `separators=(",", ":")` and tests expect `{"ok":true}` (`plan:404-407`, `plan:425-439`).
   - Current code evidence: `okResult()` uses `JSON.stringify(payload)`, which is compact for normal objects but preserves JavaScript JSON stringify semantics (`apps/silmari-mcp/src/index.ts:459-464`).
   - Recommendation: state that the contract is semantic JSON text, or test against current TypeScript output for actual fixtures rather than reimplementing formatting assumptions.

2. ❌ **Unknown CLI error exit semantics conflict between plan, current CLI, and CLI-first docs.**
   - Plan evidence: unknown subcommand exits 2 (`plan:970-975`).
   - Current code evidence: CLI `fail()` exits 2 and unknown subcommands call it (`apps/silmari-mcp/src/cli.ts:150`, `apps/silmari-mcp/src/cli.ts:354-355`).
   - SAI evidence: CLI-first docs require clear validation/error handling but do not establish `2` for user errors (`SAI/CLIFIRSTARCHITECTURE.md:192-205`).
   - Recommendation: explicitly choose current Silmari CLI parity as the source of truth, or amend the CLI to SAI CLI-first semantics with a migration note.

3. ⚠️ **Resource API coverage should include listed vs dynamic distinction.**
   - Plan evidence: dynamic reads for card/chain/register are required even if not listed (`plan:686-695`).
   - Current code evidence: static resources list does not include `silmari://card/<id>` or `silmari://chain/<address>`, but `dispatchResource()` handles them (`apps/silmari-mcp/src/index.ts:440-450`, `apps/silmari-mcp/src/index.ts:852-873`).
   - Recommendation: add explicit test names for listed static resources vs unlisted dynamic resource templates.

### Critical Issues

1. **Algorithm Contract Drift**
   - Impact: the compatibility runtime can pass tests against one Algorithm version while SAI docs route users to another.
   - Required amendment: make `SAI/Algorithm/LATEST` or an amended `SAI/README.md` the version authority and update the footprint manifest accordingly.

2. **Footprint Contract Overclaim**
   - Impact: valid SAI startup/dynamic/on-demand context can be flagged as a leak, or Ultimate-specific context can be hidden while other broad context remains unaccounted.
   - Required amendment: rename the audit to “default MCP server footprint” and add allowed SAI startup/context-routing surfaces separately.

3. **Missing Generic Bridge Interface**
   - Impact: Behavior 3 green implementation cannot run because current `silmari` CLI does not accept `tool <name> <json>`.
   - Required amendment: add `silmari tool <zk_name> <json>` to the green path, or delegate directly to `dispatchTool()` via a dedicated bridge script.

4. **Hook Contract Incomplete**
   - Impact: ThinkWithMemory can violate SAI’s `<500ms`, non-blocking, always-exit-zero hook contract once MCP/Ultimate recall is introduced.
   - Required amendment: add hook timeout/cancellation/fallback tests and update hook docs/settings registration.

5. **SAI Memory/PRD Boundary Missing**
   - Impact: Silmari compatibility could preserve card storage while corrupting or bypassing SAI work memory.
   - Required amendment: add non-interference tests for `~/.claude/MEMORY/WORK`, PRD files, PRDSync-derived state, and `STATE/events.jsonl`.

### Suggested Plan Amendments

```diff
# Registry And Schema Reality Check
+ Add: "SAI markdown specs are canonical prose contracts even when JSON Schema files are absent."
+ Add: PRD, Pipeline, Flow, Memory, Hook, and SYSTEM/USER docs as schema_contract_refs where relevant.

# Behavior 1 / Behavior 10
~ Modify: "LLM-visible footprint" -> "default Silmari MCP server footprint".
+ Add: allowed SAI startup context: CLAUDE.md/AGENTS.md, loadAtStartup, dynamicContext, and on-demand context routing.
+ Add: Algorithm version authority test against SAI/Algorithm/LATEST or updated README.

# Behavior 3
+ Add: implement or generate a real generic bridge: `silmari tool <zk_name> <json>`.
~ Modify: move "current CLI lacks generic tool dispatch" from Refactor into Green.

# Behavior 7
+ Add: hook client timeout budget, cancellation/fallback, and always-exit-zero tests.
+ Add: doc/settings registration assertion for ThinkWithMemory on UserPromptSubmit.
+ Add: event/notification non-regression guard where hook behavior changes.

# Behavior 8
+ Add: explicit CLI flag form, e.g. `silmari --backend ultimate status`, or justify env-only selection.
+ Add: SAI/CLI.md or SAI/TOOLS.md documentation update if `silmari` is a stable SAI CLI.

# Behavior 9
+ Add: SAI memory non-interference: do not write PRDs, work.json, LEARNING, STATE, or events except through existing hooks.

# Integration And E2E Testing
~ Rename: "LEARN flow primitives" -> "Algorithm LEARN lifecycle scenarios".
+ Add: named-agent/custom-agent/team smoke check if compatibility is scoped to agent memory.
+ Add: Fabric/Actions/Pipelines/Flows unaffected regression note.
```

### Approval Status

- [ ] Ready for Implementation
- [ ] Needs Minor Revision
- [x] Needs Major Revision

Implementation should not start until the five critical amendments above are resolved. The core direction is sound, but the plan currently mixes default MCP footprint, SAI runtime context, hook lifecycle, CLI bridge, and memory-store boundaries in ways that would cause avoidable implementation churn.
