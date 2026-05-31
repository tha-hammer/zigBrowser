---
date: 2026-04-30T21:10:53-04:00
reviewer: GreenBridge
research_under_review: thoughts/searchable/shared/research/2026-04-30-silmari-mcp-contracts-silmari-store-migration.md
research_commit: e52091d9f2886484c0daa4241a0ab46edbbe89b6
review_scope: "Research quality and accuracy review; no implementation changes"
status: complete
related_beads:
  - silmari-agent-memory-4d8.14.1
  - silmari-agent-memory-e8u
  - silmari-agent-memory-xom
  - silmari-agent-memory-792
---

# Review: Silmari MCP Contracts For Silmari Store Migration

## Verdict

Needs revision before it is used as planning input.

The research is directionally correct on the main migration boundary: MCP public surface in `apps/silmari-mcp/src/index.ts`, storage compatibility facade in `apps/silmari-mcp/src/lib/br-adapter.ts`, and native process contract through `NativeCliAdapter` plus `silmari-store`. Most paths and line references resolve against the stated commit.

The gaps are in public-contract details that matter specifically to "migrate to Silmari Store and away from `br`": stale MCP tool text still advertises `br`, `zk_status` schema health is described too generically, and keyword writes are not identified as a separate TypeScript-side storage boundary.

No phase split was needed; the reviewed document is 248 lines.

## Findings

### High: Public MCP `zk_save_cards` still exposes `br` wording, but the research does not call this out

The research correctly identifies `apps/silmari-mcp/src/index.ts` as the public MCP contract and lists `zk_save_cards` in the card-creation group (`thoughts/searchable/shared/research/2026-04-30-silmari-mcp-contracts-silmari-store-migration.md:54`, `thoughts/searchable/shared/research/2026-04-30-silmari-mcp-contracts-silmari-store-migration.md:58`).

However, the actual public tool description still says:

- "per-card `br create` writes"
- "does not use `br create -f`"

Reference: `apps/silmari-mcp/src/index.ts:157` through `apps/silmari-mcp/src/index.ts:159` at commit `e52091d9f2886484c0daa4241a0ab46edbbe89b6`.

This is a public MCP `tools/list` contract leak. A planning effort based on the research could miss that one of the externally visible tool descriptions still names the old storage path even after native batch create exists. This relates to `silmari-agent-memory-e8u` and the 4d8 operator/docs cleanup surface.

### Medium: `zk_status` schema health is under-specified and could be misread as a real native schema check

The research says `zk_status` returns status payload fields including schema status (`thoughts/searchable/shared/research/2026-04-30-silmari-mcp-contracts-silmari-store-migration.md:122`).

The code path is narrower:

- `zk_status` passes `schemaStatusFromFacadeRead(resolution, true)` directly (`apps/silmari-mcp/src/index.ts:1011`).
- `schemaStatusFromFacadeRead()` returns `version: null` and `compatible: readSucceeded` when `nativeDbPath` exists (`apps/silmari-mcp/src/lib/native-status.ts:171` through `apps/silmari-mcp/src/lib/native-status.ts:185`).

The research should state that the current status schema field is a facade-read-derived compatibility indicator, not a direct `silmari-store schema-check` result. This matters because the research also identifies operational gates and production readiness evidence; planning could otherwise over-trust `zk_status.store.schema`.

### Medium: Keyword write ownership is underdescribed

The research notes only that keyword index reads still use `readKeywordIndex()` from the TypeScript-side keyword index module (`thoughts/searchable/shared/research/2026-04-30-silmari-mcp-contracts-silmari-store-migration.md:181`).

The MCP write surface also bypasses the Silmari Store facade:

- `zk_keyword_add` dispatches to `addKeywordEntry()` (`apps/silmari-mcp/src/index.ts:989` through `apps/silmari-mcp/src/index.ts:995`).
- `addKeywordEntry()` writes to the TypeScript-side `keyword_entries` table (`apps/silmari-mcp/src/lib/keyword-index.ts:359` through `apps/silmari-mcp/src/lib/keyword-index.ts:430`).
- That table is stored in `${SILMARI_DIR}/silmari.db`, not in the native DB selected by `nativeDbPath` (`apps/silmari-mcp/src/lib/silmari-db.ts:41` through `apps/silmari-mcp/src/lib/silmari-db.ts:46`).

Because the research also lists native `keyword_entries` as part of the Silmari Store schema, the document should distinguish the current MCP keyword write boundary from the native schema table. Otherwise planning may assume keyword writes are already native-primary routed.

### Medium: Current related issue context is missing the import-parity blocker bead

The research links `4d8.14`, `4d8.15`, and `e8u` in frontmatter and coordination state (`thoughts/searchable/shared/research/2026-04-30-silmari-mcp-contracts-silmari-store-migration.md:18`, `thoughts/searchable/shared/research/2026-04-30-silmari-mcp-contracts-silmari-store-migration.md:228`).

The current open beads now include `silmari-agent-memory-4d8.14.1`: "Import parity blocks on register fz:0_0 legacy row". It is directly related to the production readiness and import parity evidence described in the research. This may have been created after the research artifact, so this is not necessarily an error in the original timestamped document. It is still required context before new planning.

### Low: Rust CLI binary line reference is imprecise

The research says the canonical Rust CLI name is `silmari-store`, with `silmari_memory_rust` kept as a compatibility binary, and cites `apps/silmari_memory_rust/src/cli.rs:21` (`thoughts/searchable/shared/research/2026-04-30-silmari-mcp-contracts-silmari-store-migration.md:144`).

At the stated commit:

- `apps/silmari_memory_rust/src/cli.rs:21` is `CLI_RESULT_SCHEMA_VERSION`.
- `apps/silmari_memory_rust/src/cli.rs:22` is `CANONICAL_BINARY_NAME`.
- `apps/silmari_memory_rust/src/cli.rs:23` is `COMPAT_BINARY_NAME`.

The claim is correct, but the line reference should be adjusted to `cli.rs:22` and `cli.rs:23`.

## Confirmed Accurate Areas

- The central migration boundary is correctly described as `br-adapter.ts` compatibility facade plus runtime mode routing.
- The `NativeCliAdapter` binary resolution order matches the code at `apps/silmari-mcp/src/lib/native-adapter.ts:661`.
- Native CLI calls through `NativeCliAdapter.runJsonCommand()` append `--db <nativeDbPath> --json` as described.
- Runtime modes and config path precedence match `apps/silmari-mcp/src/lib/native-mode.ts`.
- The KC Baker cascade import section matches the closed `4d8.15` implementation at commit `e52091d9f2886484c0daa4241a0ab46edbbe89b6`.

## Beads Context Checked

Open related issues at review time:

- `silmari-agent-memory-4d8.14.1`: import parity blocker on legacy root register `fz:0_0`
- `silmari-agent-memory-e8u`: official Silmari Store naming adoption
- `silmari-agent-memory-xom`: viewer fork-and-strip direction
- `silmari-agent-memory-792`: KC Baker card density follow-up

No new beads were created during this review. The stale public MCP tool description can be handled under the existing naming/docs cleanup work unless the team wants a separate child bead.

## Review Commands

```text
cat /home/maceo/.codex/skills/review-research/SKILL.md
wc -l thoughts/searchable/shared/research/2026-04-30-silmari-mcp-contracts-silmari-store-migration.md
cat thoughts/searchable/shared/research/2026-04-30-silmari-mcp-contracts-silmari-store-migration.md
bd list --status=open
bd show silmari-agent-memory-4d8.14.1
bd show silmari-agent-memory-e8u
bd show silmari-agent-memory-xom
bd show silmari-agent-memory-792
rg / git show / nl inspections against commit e52091d9f2886484c0daa4241a0ab46edbbe89b6
```
