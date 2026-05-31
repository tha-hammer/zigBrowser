---
date: 2026-04-28T05:02:15-04:00
researcher: Silmari (via Codex / GentleCompass)
git_commit: 330392a9806dc16aff4ebdfa95c3591c8987d7d2
branch: main
repository: silmari-agent-memory
topic: "Data model from scratch to replace beads_rust implementation"
tags: [research, codebase, data-model, beads-rust, br, silmari-memory-rust, silmari-mcp, zettelkasten, viewer]
status: complete
last_updated: 2026-04-28
last_updated_by: Silmari (via Codex / GentleCompass)
related_issues: [silmari-agent-memory-7jo, silmari-agent-memory-xom, silmari-agent-memory-adf, silmari-agent-memory-hkg, silmari-agent-memory-p6i, silmari-agent-memory-rjn, silmari-agent-memory-6iz, silmari-agent-memory-929]
---

```text
+------------------------------------------------------------------------------+
| RESEARCH: Data Model To Replace beads_rust                                   |
| Status: COMPLETE - Date: 2026-04-28 - Scope: current contracts only          |
+------------------------------------------------------------------------------+
```

# Research: Data Model From Scratch To Replace `beads_rust`

**Date**: 2026-04-28T05:02:15-04:00  
**Researcher**: Silmari (via Codex / GentleCompass)  
**Git Commit**: `330392a9806dc16aff4ebdfa95c3591c8987d7d2`  
**Branch**: `main`  
**Repository**: `silmari-agent-memory`

## Research Question

We are creating a data model from scratch to replace the current `beads_rust` implementation. Document the current codebase and prior research needed to understand the data model contracts that exist today.

This document describes what exists in the repository today. It does not propose a new implementation plan.

## Summary

The current system is split across five layers:

| Layer | Current Source Of Truth | Data Shape Today |
|---|---|---|
| Live store | `vendor/beads_rust` via `br` subprocesses | Issue-shaped SQLite: `issues`, `labels`, `dependencies`, `comments`, `events` |
| Silmari MCP semantics | `apps/silmari-mcp` | Zettelkasten semantics encoded mostly as labels and MCP-side SQLite |
| Native Rust substrate | `apps/silmari_memory_rust` | Card-native SQLite: `cards`, `card_labels`, `card_edges`, `keyword_entries`, `schema_versions` |
| Viewer export | `apps/silmari-viewer` + `apps/silmari-memory-card-viewer` | Issue-shaped exported SQLite plus cache-side `card_edges` overlay |
| SAI/Algorithm consumers | `SAI/Algorithm`, `SAI/commands`, hooks | Public `mcp__silmari__zk_*` tool/resource contracts |

The replacement model is already partially expressed in `apps/silmari_memory_rust`: a card-native schema with first-class typed edges and keyword entries. That crate currently covers retrieval and import behavior, not the full live `br` write boundary. Existing research says a full replacement must also preserve the observable `br-adapter.ts` API: two boxes, ID prefixes, create/batch-create, update/status/delete, label mutation, `blocks` dependency mirroring, exact show/list/search, timeout/retry semantics, and MCP/SAI payload shapes.

The central data-model distinction is:

| Concept | Current `beads_rust` Form | Silmari Form |
|---|---|---|
| Card | `issues` row with issue-tracker fields | `Card` with body, kind, box, folgezettel, trunk, source, content hash |
| Metadata | Separate `labels(issue_id,label)` | Namespaced labels plus derived native columns |
| Folgezettel | `fz:<trunk>_<sequence>` label | Slash address, e.g. `5/7a1` |
| Edge | `dependencies` row, issue-tracker whitelist | `ref:<edge>:<target>` label or native `card_edges` row |
| Keyword recall | Not native to Beads | Exact normalized `keyword_entries` lookup |
| Viewer graph | `dependencies` plus metrics | `dependencies` for blocks, `card_edges` for 12 Silmari edge types |

## Detailed Findings

### 1. Live MCP Data Model

The active Silmari store is still Beads-backed. `apps/silmari-mcp/src/lib/paths.ts` defines two boxes, biblio and idea, with default directories under `~/.silmari/.../.beads` and initialization through `br init --prefix bl|zk --db <box>/beads.db` ([paths.ts:28](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/paths.ts#L28), [paths.ts:67](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/paths.ts#L67), [paths.ts:128](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/paths.ts#L128), [paths.ts:153](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/paths.ts#L153)).

The low-level live boundary is `br-adapter.ts`. It wraps `br create`, `create -f`, `update`, `list`, `search`, `show`, `close`, `delete`, `dep add/list`, `label add/remove`, and WAL checkpoint behavior through synchronous subprocess calls ([br-adapter.ts:145](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/br-adapter.ts#L145), [br-adapter.ts:223](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/br-adapter.ts#L223), [br-adapter.ts:331](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/br-adapter.ts#L331), [br-adapter.ts:420](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/br-adapter.ts#L420), [br-adapter.ts:546](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/br-adapter.ts#L546), [br-adapter.ts:664](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/br-adapter.ts#L664), [br-adapter.ts:694](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/br-adapter.ts#L694)).

Silmari-owned extension state lives in `${SILMARI_DIR}/silmari.db`. Current MCP-owned SQLite tables include `schema_versions` and `keyword_entries` ([silmari-db.ts:45](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/silmari-db.ts#L45), [keyword-index.ts:153](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/keyword-index.ts#L153)).

Flat files still exist in the model: `TRUNKS.md`, `folgezettel-cursors.json`, and `link-proposals.jsonl` ([paths.ts:90](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/paths.ts#L90), [folgezettel.ts:189](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/folgezettel.ts#L189), [edges.ts:53](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/edges.ts#L53)).

### 2. Label Namespace As The Current Semantic Model

Silmari metadata is label-first in TypeScript. `labels.ts` defines prefixes for `fz:`, `kind:`, `box:`, `trunk:`, `scope:`, `source:`, `ref:`, `content_hash:`, `keyword:`, and `upsert:` ([labels.ts:28](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/labels.ts#L28)).

Current card kinds are:

| Kind Set | Values |
|---|---|
| Structural | `register`, `hub`, `structure` |
| Permanent / factual | `fact`, `preference`, `biblio` |
| Working memory | `learning`, `decision`, `idea`, `signal`, `stub` |

The actual constant includes `biblio`, `idea`, `hub`, `structure`, `register`, `fact`, `signal`, `learning`, `preference`, `decision`, and `stub` ([labels.ts:51](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/labels.ts#L51)).

Current edge vocabulary is a closed 12-type set:

| Tier | Edge Types | Creation Behavior In TS |
|---|---|---|
| AUTO | `follows`, `continues`, `branches`, `derives-from`, `blocks`, `refers-to`, `annotates` | Can be written directly |
| REVIEWED | `supports`, `contradicts`, `extends`, `reinforces`, `refines` | Routed through proposal/commit flow |

The split is defined by `AUTO_EDGE_TYPES`, `REVIEWED_EDGE_TYPES`, and `VALID_EDGE_TYPES` ([labels.ts:79](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/labels.ts#L79), [labels.ts:89](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/labels.ts#L89), [labels.ts:97](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/labels.ts#L97)).

Folgezettel labels use `_` where the logical address uses `/`, e.g. `fz:5_7a1` for `5/7a1` ([labels.ts:125](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/labels.ts#L125), [labels.ts:213](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/labels.ts#L213)). Edges use `ref:<type>:<target>` ([labels.ts:161](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/labels.ts#L161), [labels.ts:277](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/labels.ts#L277)).

### 3. Card Save Shape And Body Storage

`SaveCardOpts` is discriminated by `box`. Idea cards require `kind`, `trunk`, optional `mode`, optional `fromAddress`, optional `scope`, optional `source`, status, labels, priority, and `allowOrphan`; biblio cards are `kind: "biblio"` and do not use folgezettel placement ([card-ops.ts:111](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/card-ops.ts#L111)).

`SaveCardResult` exposes `id`, `fz`, `wasReinforced`, optional `priorId`, and deprecated `wasSweepDeleted` ([card-ops.ts:179](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/card-ops.ts#L179)).

Silmari stores full card body in the Beads `description` field as JSON:

```ts
{
  content_hash,
  body,
  kind?,
  source?,
  folgezettel?,
  created_by?,
  metadata?
}
```

The JSON description shape is defined by `CardDescription`, and helpers recover body from JSON with fallback behavior for legacy rows ([card-ops.ts:209](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/card-ops.ts#L209), [card-ops.ts:240](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/card-ops.ts#L240), [card-ops.ts:270](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/card-ops.ts#L270), [card-ops.ts:350](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/card-ops.ts#L350)).

Save-time behavior includes body hashing, duplicate recurrence checks via `content_hash:<short>`, folgezettel assignment for idea cards, Beads row creation, deterministic Tier A edge extraction, keyword writes, and anchor checks ([card-ops.ts:372](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/card-ops.ts#L372), [card-ops.ts:455](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/card-ops.ts#L455), [card-ops.ts:550](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/card-ops.ts#L550), [card-ops.ts:786](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/card-ops.ts#L786)).

### 4. Folgezettel, Trunks, Registers, Hubs, Structures

Trunks are valid `1..5`, with defaults Humanities, Social Science, Natural Science, Formal Science, and Applied Science. Trunk names live in `TRUNKS.md` and are parsed by `trunks.ts` ([folgezettel.ts:40](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/folgezettel.ts#L40), [trunks.ts:31](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/trunks.ts#L31), [trunks.ts:106](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/trunks.ts#L106)).

Folgezettel addresses are `<trunk>/<sequence>`. Sequence parsing alternates digit and letter segments; `0/0` and `N/0` are reserved for registers ([folgezettel.ts:8](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/folgezettel.ts#L8), [folgezettel.ts:69](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/folgezettel.ts#L69), [folgezettel.ts:162](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/folgezettel.ts#L162)).

Cursor state is whole-file JSON with schema version 2 and per-trunk cursors. `assignFolgezettel` handles `root`, `continue`, and `fork`, including explicit `fromAddress` / `fromSequence` behavior in current tests ([folgezettel.ts:53](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/folgezettel.ts#L53), [folgezettel.ts:189](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/folgezettel.ts#L189), [folgezettel.ts:268](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/folgezettel.ts#L268)).

Registers are Beads rows with JSON register bodies. Initialization creates six registers: root `0/0` plus trunk registers `1/0` through `5/0` ([init.ts:16](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/init.ts#L16), [init.ts:67](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/init.ts#L67), [init.ts:166](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/init.ts#L166)).

Hubs are `kind:hub` idea cards with `HubNote {id,fz,label,trunk}` and identity label `upsert:<sha8(label)>`; membership is currently represented by reverse `derives-from` edge queries ([hubs.ts:70](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/hubs.ts#L70), [hubs.ts:119](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/hubs.ts#L119), [hubs.ts:275](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/hubs.ts#L275), [hubs.ts:312](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/hubs.ts#L312)).

Structures are `kind:structure` idea cards with `StructureNote {id,fz,title,outline}` ([structures.ts:39](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/structures.ts#L39), [structures.ts:58](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/structures.ts#L58)).

### 5. Keyword Recall And Line Of Thought

The keyword index is exact lookup. `KeywordEntry` has `term`, `entry_points`, `curator`, and `updated_at`; terms normalize to lowercase underscore form ([keyword-index.ts:57](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/keyword-index.ts#L57), [keyword-index.ts:128](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/keyword-index.ts#L128), [keyword-index.ts:176](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/keyword-index.ts#L176)).

`navigate()` implements the `zk_recall` composition:

1. exact keyword lookup,
2. sort and cap entry points by `reinforces-density` or `recency`,
3. compute folgezettel neighborhoods,
4. optionally expand typed edge walks.

The function returns `{query, entryPoints, entryCards, neighborhoods, crossRefs}` and preserves `entryPoints: null` on miss ([navigate.ts:621](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/navigate.ts#L621), [navigate.ts:728](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/navigate.ts#L728), [navigate.ts:778](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/navigate.ts#L778)).

Line-of-thought result shape is `{queried,parent,siblings,children,hubs,trunkSeeds,all,totalScope}`, capped at 150. It composes folgezettel neighborhood, hub membership, and trunk seeds ([line-of-thought.ts:57](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/line-of-thought.ts#L57), [line-of-thought.ts:66](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/line-of-thought.ts#L66), [line-of-thought.ts:187](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-mcp/src/lib/line-of-thought.ts#L187)).

### 6. `beads_rust` Data Shape Being Replaced

`vendor/beads_rust` is the current `br` implementation. Its storage model is SQLite primary storage plus JSONL export for collaboration; schema version is declared in `storage/schema.rs` ([vendor README:54](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/vendor/beads_rust/README.md#L54), [schema.rs:8](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/vendor/beads_rust/src/storage/schema.rs#L8)).

Core Beads tables:

| Table | Current Purpose |
|---|---|
| `issues` | Main task/issue row, including many issue-management fields |
| `labels` | `(issue_id,label)` relation |
| `dependencies` | Issue dependency graph |
| `comments` | Comments per issue |
| `events` | Audit/event history |

The `issues` table includes issue-tracker fields beyond Silmari card needs: `status`, `priority`, `issue_type`, `assignee`, owner/sender fields, due/defer fields, external refs, tombstone fields, compaction fields, `ephemeral`, `pinned`, `is_template`, timestamps, and more ([model/mod.rs:386](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/vendor/beads_rust/src/model/mod.rs#L386), [schema.rs:18](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/vendor/beads_rust/src/storage/schema.rs#L18)).

Labels are normalized into a separate `labels(issue_id,label)` table with validation limiting labels to ASCII alphanumeric, hyphen, underscore, and colon. This explains the current Silmari underscore encoding for folgezettel labels ([schema.rs:120](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/vendor/beads_rust/src/storage/schema.rs#L120), [validation/mod.rs:227](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/vendor/beads_rust/src/validation/mod.rs#L227)).

The Beads dependency model has its own edge vocabulary: `blocks`, `parent-child`, `conditional-blocks`, `waits-for`, `related`, `discovered-from`, `replies-to`, `relates-to`, `duplicates`, `supersedes`, and `caused-by` ([model/mod.rs:215](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/vendor/beads_rust/src/model/mod.rs#L215), [dep.rs:435](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/vendor/beads_rust/src/cli/commands/dep.rs#L435)). Silmari currently uses the Beads dependency graph only for `blocks` mirroring; the 12 Silmari semantic edge types live in labels and now in Rust-native `card_edges`.

Comments and events are first-class Beads structures. Deletion creates tombstone state instead of immediately removing the issue row ([schema.rs:131](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/vendor/beads_rust/src/storage/schema.rs#L131), [schema.rs:143](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/vendor/beads_rust/src/storage/schema.rs#L143), [sqlite.rs:1668](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/vendor/beads_rust/src/storage/sqlite.rs#L1668)).

`br sync` exports/imports SQLite state to/from JSONL, does not execute git, and confines file operations to `.beads/` by default ([cli/mod.rs:868](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/vendor/beads_rust/src/cli/mod.rs#L868), [validation/mod.rs:6](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/vendor/beads_rust/src/validation/mod.rs#L6), [docs/SYNC_SAFETY.md:9](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/vendor/beads_rust/docs/SYNC_SAFETY.md#L9)).

### 7. Native Rust Replacement Substrate

`apps/silmari_memory_rust` exists today as package `silmari_memory_rust`, edition 2024. It is described as a "Native Rust retrieval substrate for Silmari memory cards" ([Cargo.toml:1](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari_memory_rust/Cargo.toml#L1), [Cargo.toml:5](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari_memory_rust/Cargo.toml#L5)).

Modules exported by `lib.rs`:

| Module | Responsibility |
|---|---|
| `schema` | Native SQLite schema |
| `model` | Card/box/edge/keyword/result types |
| `labels` | Label parsing and builders |
| `store` | Native DB reads/writes |
| `importer` | Beads-shaped SQLite import |
| `keyword_index` | Keyword lookup helpers |
| `folgezettel` | Address math and neighborhoods |
| `edges` | Typed edge traversal |
| `retrieval` | Recall and line-of-thought composition |
| `cli` | JSON CLI |

The module exports are in [lib.rs:3](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari_memory_rust/src/lib.rs#L3).

Native tables are:

| Table | Fields / Meaning |
|---|---|
| `cards` | `id`, `box`, `kind`, `title`, `description`, `body`, `fz_address`, `trunk`, `source`, `content_hash`, timestamps |
| `card_labels` | Preserved original labels |
| `card_edges` | Native typed edges `(source_id,target_id,edge_type)` |
| `keyword_entries` | Exact keyword rows |
| `schema_versions` | Schema version metadata |

The schema is defined in `schema.rs` with constraints for box, kind, trunk, content hash, edge type, and JSON keyword entries ([schema.rs:57](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari_memory_rust/src/schema.rs#L57), [schema.rs:81](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari_memory_rust/src/schema.rs#L81), [schema.rs:88](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari_memory_rust/src/schema.rs#L88), [schema.rs:98](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari_memory_rust/src/schema.rs#L98)).

Rust model types include:

| Rust Type | Data Contract |
|---|---|
| `CardKind` | 11 Silmari kinds |
| `CardBox` | `biblio` / `idea` |
| `EdgeType` | 12 Silmari edge types with AUTO/REVIEWED tier behavior |
| `ParsedLabels` | Extracted label facts plus warnings |
| `Card` / `NewCard` | Native card DTOs |
| `KeywordEntry` | Exact keyword row |
| `ImportSummary` | Import counters |

These are in `model.rs` ([model.rs:6](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari_memory_rust/src/model.rs#L6), [model.rs:71](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari_memory_rust/src/model.rs#L71), [model.rs:107](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari_memory_rust/src/model.rs#L107), [model.rs:236](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari_memory_rust/src/model.rs#L236), [model.rs:252](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari_memory_rust/src/model.rs#L252)).

The importer reads raw Beads-shaped SQLite. It requires `issues`, reads optional `labels`, optional `dependencies`, optional `keyword_entries`, skips deleted/ephemeral/template/status-deleted rows, preserves labels, inserts parsed `ref:*` labels as native edges, imports only `blocks` Beads dependencies, and copies keyword rows where present ([importer.rs:40](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari_memory_rust/src/importer.rs#L40), [importer.rs:67](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari_memory_rust/src/importer.rs#L67), [importer.rs:97](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari_memory_rust/src/importer.rs#L97), [importer.rs:249](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari_memory_rust/src/importer.rs#L249), [importer.rs:274](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari_memory_rust/src/importer.rs#L274)).

The CLI exposes `init`, `import-beads`, `recall`, `neighborhood`, `edges`, and `line-of-thought`; JSON output uses camelCase success payloads and an error envelope with `error.code`, `error.message`, and `error.details` ([cli.rs:15](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari_memory_rust/src/cli.rs#L15), [cli.rs:128](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari_memory_rust/src/cli.rs#L128), [cli.rs:299](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari_memory_rust/src/cli.rs#L299)).

Current replacement research states that this crate is a retrieval substrate, not a full drop-in replacement for the live `br` boundary. Missing live-store coverage includes path resolution, ID prefix semantics, live create/batch-create, update/status/delete, label mutation, general list/show/search parity, dependency add/list, adapter retry/timeout behavior, and cutover from Beads DBs plus MCP-side SQLite state.

### 8. Viewer / Export Data Contract

The current viewer pipeline still consumes issue-shaped data. `apps/silmari-viewer` reads Beads SQLite into Go `model.Issue`, `model.Dependency`, and `model.Comment`, then exports `beads.sqlite3` with:

| Export Table | Purpose |
|---|---|
| `issues` | Raw card/issue rows, with `labels` as JSON text |
| `dependencies` | Exported dependencies, now expected to stay blocks-only for Silmari graph analytics |
| `comments` | Comments |
| `issue_metrics` | PageRank/betweenness/critical-depth/triage metrics |
| `triage_recommendations` | Issue-tracker recommendations |
| `issues_fts` | FTS5 over issue fields |
| `issue_overview_mv` | Materialized overview consumed by SPA |
| `export_meta` | Export metadata |

The schema is defined in `pkg/export/sqlite_schema.go` ([sqlite_schema.go:37](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-viewer/pkg/export/sqlite_schema.go#L37), [sqlite_schema.go:59](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-viewer/pkg/export/sqlite_schema.go#L59), [sqlite_schema.go:93](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-viewer/pkg/export/sqlite_schema.go#L93), [sqlite_schema.go:178](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-viewer/pkg/export/sqlite_schema.go#L178), [sqlite_schema.go:209](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-viewer/pkg/export/sqlite_schema.go#L209)).

`apps/silmari-memory-card-viewer/server.ts` post-processes the exported cache. It creates a `card_edges(source,target,type)` table and synthesizes rows from `issues.labels` entries shaped as `ref:<type>:<target>` ([server.ts:83](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-memory-card-viewer/server.ts#L83), [server.ts:114](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-memory-card-viewer/server.ts#L114), [server.ts:141](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-memory-card-viewer/server.ts#L141)).

The SPA expects `issue_overview_mv`, `issues_fts`, raw `issues`, `dependencies`, optional `card_edges`, and OPFS config hash/chunk metadata. `link-builder.js` merges `dependencies` and `card_edges` into graph links, preserving `type` ([viewer.js:893](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-memory-card-viewer/viewer_assets/viewer.js#L893), [viewer.js:1086](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-memory-card-viewer/viewer_assets/viewer.js#L1086), [link-builder.js:17](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-memory-card-viewer/viewer_assets/link-builder.js#L17)).

`viewmodel.js` parses Zettelkasten fields from labels for the UI: scope, folgezettel, kind, trunk, box, keywords, and typed edges ([viewmodel.js:33](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-memory-card-viewer/viewer_assets/viewmodel.js#L33), [viewmodel.js:141](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-memory-card-viewer/viewer_assets/viewmodel.js#L141), [viewmodel.js:150](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-memory-card-viewer/viewer_assets/viewmodel.js#L150), [viewmodel.js:166](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-memory-card-viewer/viewer_assets/viewmodel.js#L166), [viewmodel.js:194](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-memory-card-viewer/viewer_assets/viewmodel.js#L194), [viewmodel.js:201](https://github.com/tha-hammer/silmari-agent-memory/blob/330392a9806dc16aff4ebdfa95c3591c8987d7d2/apps/silmari-memory-card-viewer/viewer_assets/viewmodel.js#L201)).

### 9. Executable Contracts

Current tests pin most data-model behavior:

| Area | Contract Files |
|---|---|
| Folgezettel math | `apps/silmari-mcp/tests/folgezettel.test.ts`, `navigate.test.ts` |
| Explicit `fromAddress` | `apps/silmari-mcp/tests/zk-save-card-fromaddress.test.ts` |
| Card body/labels | `card-ops.test.ts`, `labels.test.ts`, `integration.test.ts` |
| Edge extractors/proposals | `edge-extractors.test.ts`, `edges.test.ts`, `integration.test.ts` |
| Keyword index/recall | `keyword-index.test.ts`, `keyword-index-sqlite.test.ts`, `zk-recall-limit.test.ts`, `bootstrap-keyword-index.test.ts`, `reconcile-keyword-index.test.ts` |
| Hub/register/structure | `integration.test.ts`, `hub-members.test.ts` |
| Viewer `card_edges` | `apps/silmari-memory-card-viewer/tests/server.test.ts`, `link-builder.test.js`, `viewmodel.test.js`, `graph-helpers.test.js` |
| Rust substrate | `apps/silmari_memory_rust/tests/*.rs` |

Important executable behaviors include:

- `fromAddress` fork/continue targets historical addresses and does not degrade missing parents to root saves.
- Keyword normalization is underscore-based (`design_systems`, not `design systems`).
- Keyword entry density is uncapped and lookup returns all entry points in insertion order.
- Reviewed edge types queue proposals; auto edge types can be written directly.
- Viewer `card_edges` synthesis keeps `dependencies` blocks-only and writes all 12 edge types.
- Rust native schema excludes `issues` and `dependencies` tables and creates `cards`, `card_labels`, `card_edges`, `keyword_entries`, and `schema_versions`.

## Architecture Documentation

### Current Live Flow

```text
SAI / Claude / MCP client
  |
  | mcp__silmari__zk_* tools
  v
apps/silmari-mcp
  |
  | br-adapter.ts subprocess calls
  v
box1-biblio/.beads/beads.db      box2-ideas/.beads/beads.db
  |                              |
  | labels encode card facts     | labels encode fz/kind/trunk/ref/source/hash
  v                              v
MCP-side silmari.db              flat files
keyword_entries                  TRUNKS.md, folgezettel-cursors.json, link-proposals.jsonl
```

### Native Rust Substrate

```text
Beads-shaped import source
  |
  | import-beads
  v
apps/silmari_memory_rust native DB
  +-- cards
  +-- card_labels
  +-- card_edges
  +-- keyword_entries
  +-- schema_versions
```

### Viewer Flow

```text
box2-ideas/.beads/beads.db
  |
  | bv --export-pages
  v
cache/beads.sqlite3
  +-- issues
  +-- dependencies
  +-- issue_metrics
  +-- issue_overview_mv
  +-- issues_fts
  |
  | Bun post-pass parses issues.labels ref:* labels
  v
cache/beads.sqlite3 + card_edges(source,target,type)
  |
  | SPA loads issue tables + card_edges
  v
graph/list/detail UI
```

## Current Contract Map For Replacement

| Contract Family | Current Owner | Observable Shape |
|---|---|---|
| Store layout | `paths.ts`, `br-adapter.ts` | Two boxes, `.beads/beads.db`, `bl-*` and `zk-*` IDs |
| Card write | `card-ops.ts` | `SaveCardOpts` -> `SaveCardResult` |
| Body storage | `card-ops.ts` | title snippet + JSON description body |
| Labels | `labels.ts` | Namespaced labels as durable wire facts |
| Folgezettel | `folgezettel.ts`, `navigate.ts` | Slash addresses, underscore labels, cursor file |
| Keyword recall | `keyword-index.ts`, `navigate.ts` | Exact normalized terms, JSON entry points |
| Edges | `edges.ts`, `edge-extractors.ts` | `ref:*` labels; `blocks` mirrored to Beads deps |
| Hub/register/structure | `init.ts`, `hubs.ts`, `structures.ts` | Register JSON bodies, `kind:hub`, `kind:structure` cards |
| Public API | `index.ts` | `zk_*` MCP tools and `silmari://*` resources |
| Viewer compatibility | `sqlite_schema.go`, `server.ts`, SPA JS | Issue-shaped export plus `card_edges` overlay |
| Native substrate | `apps/silmari_memory_rust` | Card-native schema and retrieval CLI |
| Failure semantics | `br-adapter.ts` tests/issues | null/false/[] degradation, retries, timeout distinction |

## Historical Context

The original memory model in `Plans/001_zettelkasten-agent-memory-mcp.md` defined link structure as retrieval, not embeddings or full-text search, and chose Beads rows plus labels for early implementation. It introduced `fz`, `kind`, `box`, `scope`, `source`, `trunk`, `keyword`, `hub`, `structure`, and `ref` labels as the logical card schema.

The early Phase 2 work in `MEMORY/WORK/20260411-010756_phase2-three-layer-retrieval/PRD.md` recorded the three-layer retrieval primitive: keyword entry, folgezettel navigation, and later crossrefs. That early version used JSONL keywords with a max-4 sparsity rule.

The 2026-04-12 viewer and dashboard research established the current thinking-tool model: keyword register, hub notes, folgezettel chains, typed cross-references, and card detail as the product surface.

The 2026-04-17 force-graph research documented the label-to-viewer workaround: `ref:*` labels are synthesized into cache-side graph edges because Beads dependencies do not carry Silmari's semantic edge vocabulary.

The 2026-04-19 fork-and-strip inventory became the source of truth for viewer direction: keep some generic card/list/search/export surfaces, transform graph/detail/filter analytics, and delete issue-tracker metrics such as heatmap, what-if cascade, critical path, sprint, triage, and git correlation.

The 2026-04-22 orphan-card research found 115 true orphans out of 303 cards, zero reviewed-tier edges, and a missing keyword substrate. The later compounding-substrate and keyword-uncap plans moved keyword storage to SQLite and superseded the max-4 entry cap.

The 2026-04-27 Rust retrieval plan and review established `apps/silmari_memory_rust` as a card-native retrieval substrate, not a Beads search port. Review-driven requirements folded into that plan include underscore keyword normalization, 12 edge types with tier gate, `LineOfThought.trunkSeeds`, label-derived `fz_address` and `trunk`, explicit Beads field handling, and camelCase JSON.

## Related Research

- `thoughts/searchable/shared/research/2026-04-12-algorithm-cw9-collision-analysis.md`
- `thoughts/searchable/shared/research/2026-04-12-algorithm-determinism-context-efficiency.md`
- `thoughts/searchable/shared/research/2026-04-12-beads-viewer-zettelkasten-graph-redesign.md`
- `thoughts/searchable/shared/research/2026-04-12-sai-installation-audit.md`
- `thoughts/searchable/shared/research/2026-04-12-zettelkasten-thinking-tool-dashboard-design.md`
- `thoughts/searchable/shared/research/2026-04-12-zk-recall-by-status-zk-promote-implementation.md`
- `thoughts/searchable/shared/research/2026-04-13-algorithm-v381-fromaddress-critical-issue.md`
- `thoughts/searchable/shared/research/2026-04-15-markdown-web-browser-scraping-pipeline-integration.md`
- `thoughts/searchable/shared/research/2026-04-16-sai-pai-upstream-rebrand-audit.md`
- `thoughts/searchable/shared/research/2026-04-17-cosmic-separation-remote-mcp-architecture.md`
- `thoughts/searchable/shared/research/2026-04-17-force-graph-edges-workaround.md`
- `thoughts/searchable/shared/research/2026-04-18-dual-layer-graph-design.md`
- `thoughts/searchable/shared/research/2026-04-18-siyuan-as-beads-viewer-replacement.md`
- `thoughts/searchable/shared/research/2026-04-19-viewer-fork-and-strip-inventory.md`
- `thoughts/searchable/shared/research/2026-04-21-cardview-serendipity-redesign.md`
- `thoughts/searchable/shared/research/2026-04-22-silmari-orphan-cards-root-cause.md`
- `thoughts/searchable/shared/research/2026-04-27-zettelkasten-rust-retrieval-substrate.md`
- `thoughts/searchable/shared/research/2026-04-27-silmari-memory-rust-br-sai.md`
- `thoughts/searchable/shared/research/2026-04-27-br-replacement-silmari-memory-rust.md`
- `thoughts/searchable/shared/plans/2026-04-27-tdd-silmari-memory-rust-retrieval-substrate.md`
- `thoughts/searchable/shared/plans/2026-04-27-tdd-silmari-memory-rust-retrieval-substrate-REVIEW.md`

## Research Artifacts

Focused subagent notes were written to:

- `/tmp/silmari-data-model-mcp.md`
- `/tmp/silmari-data-model-rust-replacement.md`
- `/tmp/silmari-data-model-beads-rust.md`
- `/tmp/silmari-data-model-viewer.md`
- `/tmp/silmari-data-model-tests.md`
- `/tmp/silmari-data-model-history.md`

## Open Questions

1. The current Rust crate is a retrieval substrate and importer. The checked-in sources do not yet define the authoritative live-store cutover from two Beads DBs plus MCP-side `silmari.db`.
2. The current Rust CLI does not yet mirror the full live `br-adapter.ts` write/read API: live create, order-preserving batch create, update/status/delete, label add/remove, general list/show/search, dependency add/list, and retry/timeout semantics.
3. The current viewer consumes issue-shaped export tables and a `card_edges` overlay. A future card-native viewer export contract is not defined in the checked-in documents.
4. Formal hub registry counts and cards carrying `kind:hub` labels are separate signals in current research and code. The replacement model needs to preserve enough information to distinguish those concepts if both remain live.
5. Current SAI hooks include direct TypeScript imports into `apps/silmari-mcp` code paths. The exact hook boundary after native Rust store adoption is not defined in the checked-in documents.
