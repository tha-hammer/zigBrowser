#!Notes on Ultimate MCP compatibility

A few persistence boundaries are emerging: Silmari writes Beads plus ${SILMARI_DIR}/silmari.db, while SAI writes MEMORY/WORK, MEMORY/STATE, and event files under SAI_DIR or
  ~/.claude. The risk is not “does Ultimate use UMS?” anymore; it is whether the bridge and hook paths preserve those roots consistently.

• Explored
  └ Read silmari_compat.py, cli.ts, silmari-recall-client.ts, ThinkWithMemory.hook.ts, sai-compat-noninterference.test.ts, silmari_minimal_runtime.py, MEMORYSYSTEM.md, PRDFORMAT.md,
         paths.ts, silmari-db.ts, 2026-04-27-sai-algorithm-router-contracts.md, br-adapter.ts, card-ops.ts

─ Worked for 2m 05s ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────

• Findings

  - High: SAI persistence roots are not enforced consistently. ThinkWithMemory writes state to hardcoded ~/.claude/MEMORY/... instead of using SAI_DIR/saiPath (SAI/hooks/
    ThinkWithMemory.hook.ts:47), even though SAI’s path helper defines SAI_DIR -> ~/.claude as the contract (SAI/hooks/lib/paths.ts:32). This can write to the wrong memory root in
    configured installs.
  - High: The Ultimate bridge can recurse when SILMARI_MCP_BACKEND=ultimate is set. Python only setdefaults the child backend to typescript (vendor/ultimate_mcp_server/
    ultimate_mcp_server/tools/silmari_compat.py:153), while the CLI reads backend from that env var (apps/silmari-mcp/src/cli.ts:104). Env-selected Ultimate mode can spawn Ultimate
    again instead of the canonical TypeScript persistence oracle.
  - Medium: There is no explicit single-writer/concurrency contract for persistence. Each Ultimate tool call starts a new CLI subprocess (vendor/ultimate_mcp_server/
    ultimate_mcp_server/tools/silmari_compat.py:144), while Silmari writes rely on deferred br flush discipline (apps/silmari-mcp/src/lib/br-adapter.ts:155, apps/silmari-mcp/src/lib/
    br-adapter.ts:623). If MCP clients issue parallel write calls, lock/flush behavior is not defined.
  - Medium: The non-interference test does not actually protect the real SAI persistence layer. It snapshots repo-local SAI/MEMORY and calls read-only-ish zk_reflect (apps/silmari-
    mcp/tests/sai-compat-noninterference.test.ts:55), but SAI docs define runtime memory under ~/.claude/MEMORY with PRDs, work state, and append-only events (SAI/MEMORYSYSTEM.md:6,
    SAI/MEMORYSYSTEM.md:220). This test can pass while runtime PRD/work/event files remain unprotected.
  - Medium: Store failure parity is still weak. The compatibility wrapper returns strings and raises SilmariBridgeError; the declared mcp_text_error helper is unused (vendor/
    ultimate_mcp_server/ultimate_mcp_server/tools/silmari_compat.py:191). For persistence failures, I would want the same tool-level isError behavior as the TypeScript server, not a
    FastMCP exception path.

  What I Think
  The right architecture is a strict three-store model:

  - Silmari MCP owns durable knowledge memory: cards, folgezettel, keyword index, edges, hubs, statuses under SILMARI_DIR.
  - SAI owns work/runtime persistence: PRDs, work.json, current work, learning, and events.jsonl under SAI_DIR/MEMORY.
  - Ultimate UMS stays out of the compatibility path unless a separate migration proves semantic parity.

  So the MCP server should not “integrate with” SAI persistence by writing it. It should interact only indirectly: Algorithm/Claude reads SAI context and calls mcp__silmari__zk_*;
  SAI hooks may read Silmari recall and write their own hook-owned state; LEARN may intentionally save durable insights to Silmari with source tags. PRDs remain the source of truth
  for active work.

  Before pushing this further, I’d add a concrete persistence-boundary slice: force the child bridge to --backend typescript, route all SAI hook state through SAI_DIR, add a temp-
  SAI_DIR non-interference suite covering PRD.md, STATE/work.json, STATE/events.jsonl, and LEARNING, and add an async write lock or queue for Ultimate compatibility calls keyed by
  SILMARI_DIR.

  I did not change files or run tests in this review pass.


› This is amazing! SAI was built specifically for Claude Code integration, the MCP means we can use any LLM what do you think we need to do to make the persistence compatable cross-
  LLM?


• MCP gets us tool portability, but not lifecycle portability. Claude Code gives SAI hooks, transcript paths, tool events, session IDs, and native project storage. Other LLM clients
  may only give “call this MCP tool.” So cross-LLM persistence needs a small SAI runtime contract above MCP.

  I’d split it like this:

  1. Keep Silmari as the durable knowledge store
     zk_* remains the cross-LLM memory API: recall, save, promote, link, hub, status. Any LLM that speaks MCP can use that. This is the clean part.
  2. Make SAI work state host-neutral
     Today PRDs/work state assume Claude Code hooks and ~/.claude/MEMORY. We need a SAI_DIR-rooted persistence API for:
      - sessions
      - work units / PRDs
      - phase changes
      - criteria progress
      - event log append
      - learning/reflection capture

     That API should be callable by Claude Code hooks, MCP tools, or a CLI wrapper.
  3. Add a lifecycle event protocol
     Cross-LLM clients need to emit normalized events:

     {
       "host": "claude-code|cursor|aider|openai-agents|custom",
       "session_id": "...",
       "event": "session.start|user.prompt|tool.call|tool.result|work.update|session.end",
       "timestamp": "...",
       "payload": {}
     }

     Claude Code hooks can produce these automatically. Other clients can call an MCP tool like sai_event_append.
  4. Separate “AI writes PRD” from “runtime syncs state”
     Keep PRD as source of truth, but expose safe tools:
      - sai_work_create
      - sai_work_read
      - sai_work_patch_frontmatter
      - sai_work_check_criterion
      - sai_event_append
      - sai_context_pack

     The runtime can update STATE/work.json from PRDs the same way PRDSync does today.
  5. Stop hardcoding Claude paths
     Every SAI writer should go through one path resolver:
     SAI_DIR -> MEMORY/WORK, MEMORY/STATE, MEMORY/LEARNING, events.jsonl.
     No direct homedir()/.claude writes in hooks or MCP compatibility.
  6. Define ownership rules
      - Silmari MCP writes Silmari memory only.
      - SAI persistence tools write SAI work/event/learning state only.
      - LLMs never write derived state directly if a sync layer owns it.
      - events.jsonl is append-only.
      - PRD remains canonical for active work.
  7. Add idempotency and concurrency
     Cross-LLM means multiple agents may write at once. Every write should have:
      - operation_id
      - session/work IDs
      - append-only event record
      - file lock or SQLite transaction
      - safe retry behavior

  My recommended next slice: build a tiny sai-persistence library plus MCP facade around PRD/work/event operations, then refactor Claude Code hooks to use that same library. Once
  Claude Code is just one adapter, every other LLM host can become another adapter instead of a special case.


› Let's think about the user folder: `/home/maceo/Dev/silmari-agent-memory/SAI/USER/`
  I added an additional directory to the USER folder: `/home/maceo/Dev/silmari-agent-memory/SAI/USER/workspace-blueprint`
  This blueprint adds a specific framework to the user's workspace folders for organization and LLM use by adding a per-directory instruction file. What do you think about
  propagating that framework to the other USER folders, what are the trade offs?


• I’ll look at the current SAI/USER structure and the new workspace-blueprint contents so the tradeoffs are grounded in what the framework actually asks each directory to carry.

• Explored
  └ List USER
    List workspace-blueprint
    List USER

──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────

• The blueprint is present and fairly opinionated: root instructions, per-domain CONTEXT.md, examples, and even an embedded office-skills reference checkout. I’m reading the core
  instruction files next rather than the whole reference repo.

• Explored
  └ Read START-HERE.md, CLAUDE.md, CONTEXT.md
    List USER
    List USER
    List SAI-USER
    List USER
    List USER

──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────

• SAI/USER is a symlink to the live user override tree, so this is a real user-facing surface, not just repo fixture data. I’m checking the existing USER README files to see where
  the blueprint would fit without fighting current conventions.

• Explored
  └ Read README.md

──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────

• I would propagate the pattern, but not by copying the whole blueprint everywhere.

  The valuable idea is the 3-layer context routing model:

  - README.md: human-facing purpose and setup.
  - CONTEXT.md: agent-facing routing, what to load, what to skip.
  - Optional deeper CONTEXT.md: only for complex sub-workspaces or staged workflows.

  For SAI/USER, that is especially useful because it is a live user override tree, symlinked to /home/maceo/.claude/SAI-USER, not just repo docs. It should stay user-owned and low-
  noise.

  Where It Fits Best

  - MARKETING/: strong candidate. It already has a real asset substrate. A CONTEXT.md could route “write copy,” “position product,” “check voice,” “create campaign,” etc. to the
    right files.
  - WORK/: strong candidate. This is naturally workspace-like: clients, consulting, resources, active context.
  - PROJECTS/: strong candidate. A router can map project names to paths, stacks, status, and relevant docs.
  - TELOS/: good candidate, but more sensitive. It should tell agents when to load goals/beliefs/challenges, and when not to.
  - BUSINESS/: likely useful for company, offers, products, market, templates.

  Where I’d Keep It Lighter

  - ACTIONS/, PIPELINES/, FLOWS/: these are executable registries. They need schema/routing docs, but the machine-readable files should remain authoritative. Don’t bury execution
    semantics in prose if action.json, .yaml, or flow configs already own them.
  - SKILLCUSTOMIZATIONS/: a short CONTEXT.md is enough. The per-skill customization file should be the source of truth.
  - STATUSLINE/, TERMINAL/: mostly configuration. Use small guardrail docs, not a full workspace framework.

  Tradeoffs
  The upside is big: agents stop guessing. They can load MARKETING/CONTEXT.md, learn exactly which brand files matter, skip unrelated USER folders, and produce better work across
  Claude Code, Cursor, or any MCP-capable client.

  The cost is maintenance. If every folder gets a verbose CONTEXT.md, you create doc drift and token bloat. The blueprint’s teaching comments are great in the template, but they
  should not be propagated into live folders.

  The other risk is false authority. Some folders already have executable contracts. For example, ACTIONS/ has action.json and action.ts; PIPELINES/ has YAML. The CONTEXT.md should
  route and explain, not override those formats.

  My Recommendation
  Create a minimal live-user variant:

  SAI/USER/
  ├── CONTEXT.md              # top-level router
  ├── MARKETING/CONTEXT.md    # asset/task router
  ├── WORK/CONTEXT.md         # professional context router
  ├── PROJECTS/CONTEXT.md     # project registry router
  ├── TELOS/CONTEXT.md        # personal context loading rules
  ├── ACTIONS/CONTEXT.md      # schema + when to add/use actions
  ├── PIPELINES/CONTEXT.md    # schema + pipeline execution rules
  └── FLOWS/CONTEXT.md        # orchestration rules

  Use CONTEXT.md as the portable, cross-LLM instruction file. Keep CLAUDE.md only where Claude Code specifically auto-loads it. Longer term, SAI could expose a sai_context_pack MCP
  tool that reads these routers and returns the right context bundle for any LLM host.

