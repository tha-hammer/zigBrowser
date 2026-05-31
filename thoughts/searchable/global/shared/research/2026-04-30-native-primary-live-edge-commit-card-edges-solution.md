---
date: 2026-04-30T09:58:48-04:00
researcher: Codex
git_commit: e2411ed885e9ccb5c3823073bfec9b5d33148dfc
branch: main
repository: silmari-agent-memory
topic: native-primary live MCP edge commits vs Rust viewer export
status: complete
related_beads:
  - silmari-agent-memory-qwy
  - silmari-agent-memory-i3d
tags:
  - native-primary
  - card_edges
  - viewer-export
  - gate-b
  - beads-rust-replacement
last_updated: 2026-04-30
last_updated_by: Codex
---

# Research: Native-Primary Live Edge Commits vs Rust Viewer Export

## Research Question

Why do live MCP/Gate B runs report successful edge commits while Rust viewer export
produces zero edges, and what solution surfaces does the current codebase support?

## Executive Summary

The zero-edge native export is explained by a real persistence mismatch, not by a
viewer read bug.

The live MCP commit path still writes Silmari semantic edges as compatibility
labels: `ref:<edge>:<target>`. In native-primary mode that becomes a Rust
`label-add` command, which inserts into `card_labels`. The Rust viewer exporter
does not synthesize edges from labels. It exports from native `card_edges`.

RedGorge's observation therefore matches the code:

- Gate B counted 1,316 successful `zk_commit_link` calls because the proposal
  commit path returned OK.
- The native DB still had zero `card_edges` rows because reviewed semantic edges
  never reached Rust `edge-add` or another native edge-write authority.
- Rust `export-viewer --mode compat` correctly exported zero edges because
  `insert_compat_edges()` reads only `card_edges`.

The contract-correct solution is not to teach the Rust viewer export to trust
labels as source of truth. The replacement plan and specs say native
`card_edges` is authoritative and `ref:*` labels are compatibility projection.
The live native-primary commit path must materialize accepted edge commits into
native `card_edges`, ideally in the same Rust-side transaction that maintains the
compatibility label.

## Current Code Path

### MCP Commits Still Advertise Label Writes

`zk_commit_link` is documented as writing the label on the source card:

- `apps/silmari-mcp/src/index.ts:276-277`

The tool dispatch simply calls `commitLink(proposalId, reason)`:

- `apps/silmari-mcp/src/index.ts:669-674`

`commitLink()` loads `link-proposals.jsonl`, requires the proposal to still be
pending, calls `addEdge()`, flushes, then rewrites the proposal as
`status: "committed"`:

- `apps/silmari-mcp/src/lib/edges.ts:303-324`
- `apps/silmari-mcp/src/lib/edges.ts:334-374`

The proposal file is explicitly `getSilmariDir()/link-proposals.jsonl`:

- `apps/silmari-mcp/src/lib/edges.ts:52-58`

### addEdge Writes ref Labels, Not Native Edge Rows

`edges.ts` still declares the live edge layer to be label encoded:

- `apps/silmari-mcp/src/lib/edges.ts:1-19`

`addEdge()` builds `ref:<edge>:<target>`, calls `brLabelAdd()`, and mirrors only
the special `blocks` edge into the dependency/edge path:

- `apps/silmari-mcp/src/lib/edges.ts:79-117`
- `apps/silmari-mcp/src/lib/labels.ts:157-164`

That means reviewed Gate B edges such as `supports`, `reinforces`, `refines`,
`extends`, and `contradicts` never take the `brDepAdd()` branch.

The TypeScript label model has seven auto edge types and five reviewed edge
types:

- `apps/silmari-mcp/src/lib/labels.ts:79-101`
- `apps/silmari-mcp/src/lib/labels.ts:108-110`

### native-primary Routes label-add and edge-add to Different Rust Commands

In native-primary mode, `brLabelAdd()` shells out to the native adapter
`label-add` compatibility command:

- `apps/silmari-mcp/src/lib/br-adapter.ts:405-413`
- `apps/silmari-mcp/src/lib/native-adapter.ts:232-240`

In native-primary mode, `brDepAdd()` shells out to the native adapter
`edge-add` compatibility command:

- `apps/silmari-mcp/src/lib/br-adapter.ts:360-378`
- `apps/silmari-mcp/src/lib/native-adapter.ts:242-255`

The existing `brDepAdd()` facade is typed as legacy Beads `DepType`, not
Silmari `EdgeType`. Its whitelist does not include most semantic edge labels:

- `apps/silmari-mcp/src/lib/legacy-br-adapter.ts:60-77`

This is the immediate adapter gap: Rust already has an edge writer, but the live
semantic commit path reaches it only for `blocks`, because the TypeScript edge
facade was built around the old Beads dependency whitelist.

## Native Rust Storage and Export

### card_edges Is a First-Class Native Table

The native schema has a dedicated `card_edges` table with all 12 Silmari edge
types and a `review_state` column:

- `apps/silmari_memory_rust/src/schema.rs:176-188`
- `apps/silmari_memory_rust/src/schema.rs:201-202`

The Rust model has the same 12-type edge vocabulary, split into auto and
reviewed sets:

- `apps/silmari_memory_rust/src/model.rs:107-186`

The Rust store already has an `insert_edge()` helper and an `add_edge()` helper
that validates endpoint cards:

- `apps/silmari_memory_rust/src/store.rs:62-74`
- `apps/silmari_memory_rust/src/store.rs:91-101`

The Rust CLI exposes this through `edge-add`:

- `apps/silmari_memory_rust/src/cli.rs:143-157`
- `apps/silmari_memory_rust/src/cli.rs:507-521`

However, the current `edge-add` command inserts only
`(source_id, target_id, edge_type)`, so `review_state` defaults to `auto`:

- `apps/silmari_memory_rust/src/store.rs:69-72`

That default conflicts with the native data model invariant for reviewed edges:

- `artifacts/specs/2026-04-28-beads-rust-replacement/02-native-data-model.md:310-315`

### label-add Writes Only card_labels Today

Rust `label-add` accepts one or more labels and calls `store::add_label()` for
each label:

- `apps/silmari_memory_rust/src/cli.rs:486-505`

`store::add_label()` validates the card and inserts into `card_labels` only:

- `apps/silmari_memory_rust/src/store.rs:76-89`

There is no live projection from `ref:*` labels into `card_edges` in this code
path.

### Import Has a Projection Path, But Live label-add Does Not

The snapshot importer parses labels and inserts parsed refs into `card_edges`:

- `apps/silmari_memory_rust/src/importer.rs:220-254`

It also has a review policy for imported legacy reviewed refs. Reviewed labels
without an accepted manifest are removed from `card_edges` and converted to
pending `edge_proposals`; accepted edges are updated to
`review_state='reviewed'`:

- `apps/silmari_memory_rust/src/importer.rs:522-592`

That import-time behavior is important because it shows the intended shape:
labels can be projected into edges, but reviewed edges need explicit acceptance
authority. Live MCP `label-add` currently has neither projection nor accepted
review metadata.

### Viewer Export Reads card_edges Only

Compatibility export calls `insert_compat_edges()` and returns the count from
the exported `card_edges` table:

- `apps/silmari_memory_rust/src/export.rs:48-68`

`insert_compat_edges()` reads:

```sql
SELECT source_id, target_id, edge_type FROM card_edges
```

and writes compatibility `card_edges(source, target, type)`. It mirrors only
`blocks` into `dependencies`:

- `apps/silmari_memory_rust/src/export.rs:213-239`

Native viewer export likewise reads `card_edges` and writes `viewer_edges`:

- `apps/silmari_memory_rust/src/export.rs:71-90`
- `apps/silmari_memory_rust/src/export.rs:411-432`

Native traversal also reads `card_edges`, not labels:

- `apps/silmari_memory_rust/src/edges.rs:80-122`
- `apps/silmari_memory_rust/src/edges.rs:149-216`

So export-side zero edges are a symptom of a deeper native graph visibility
problem. Native traversal, future retrieval, and card-native viewer consumers
will also be blind to these live committed edges.

## Gate B Reporting Explains the False Confidence

The cascade pipeline commits a proposal by calling `zk_propose_link` and then
`zk_commit_link`. It returns `true` after both MCP calls succeed:

- `scripts/kc-baker-pipeline-v2/ingest/ingest-cascade.ts:1080-1100`

Bundle Gate B increments `totalCommitted` when `commitProposal()` returns true:

- `scripts/kc-baker-pipeline-v2/ingest/ingest-cascade.ts:1473-1507`

Therefore `edges_committed` is currently a tool-call success counter. It is not
a native `card_edges` durability assertion.

RedGorge's Agent Mail evidence matches this exactly:

- Message 940: full bundle run reported `edges_committed=1316`.
- Message 944: same temp run had `0` native `card_edges` rows, while the 1,316
  edges existed in `link-proposals.jsonl` as `status=committed`.
- Message 944: Rust compat export produced 935 cards and zero edges until a
  cache-side workaround imported proposal-log edges into exported `card_edges`.

## Current Viewer Compatibility Workaround

The existing Bun card viewer server has a compatibility-only synthesizer for old
`bv --export-pages` output. It parses `ref:<type>:<target>` labels from
`issues.labels` and writes cache-side `card_edges`:

- `apps/silmari-memory-card-viewer/server.ts:83-103`
- `apps/silmari-memory-card-viewer/server.ts:125-172`
- `apps/silmari-memory-card-viewer/server.ts:244-254`

That explains why a label-only cache can still become graph-visible in the
current Bun viewer path.

The Rust exporter intentionally does something different: it writes from native
`card_edges`. Its contract test seeds both labels and native edge rows before
exporting:

- `apps/silmari_memory_rust/tests/viewer_export_contract.rs:10-38`
- `apps/silmari_memory_rust/tests/viewer_export_contract.rs:73-100`
- `apps/silmari_memory_rust/tests/viewer_export_contract.rs:158-170`

Those tests prove export works when `card_edges` is populated. They do not prove
the live MCP proposal commit path populates `card_edges`.

This is why `silmari-agent-memory-i3d` remains relevant but is not sufficient:
the missing current-viewer Rust compat test can catch a zero-edge export, but
the source fix belongs in the live native edge write path.

## Contract Context

The Rust replacement specs and plan consistently point to native `card_edges` as
authoritative:

- `artifacts/specs/2026-04-28-beads-rust-replacement/02-native-data-model.md:134-155`
- `artifacts/specs/2026-04-28-beads-rust-replacement/02-native-data-model.md:216-217`
- `artifacts/specs/2026-04-28-beads-rust-replacement/02-native-data-model.md:264-270`
- `artifacts/specs/2026-04-28-beads-rust-replacement/03-store-api-and-adapter.md:210-221`
- `artifacts/specs/2026-04-28-beads-rust-replacement/03-store-api-and-adapter.md:244-249`
- `artifacts/specs/2026-04-28-beads-rust-replacement/03-store-api-and-adapter.md:280-285`
- `artifacts/specs/2026-04-28-beads-rust-replacement/05-viewer-export-and-consumers.md:74-94`
- `artifacts/specs/2026-04-28-beads-rust-replacement/05-viewer-export-and-consumers.md:96-109`
- `artifacts/specs/2026-04-28-beads-rust-replacement/05-viewer-export-and-consumers.md:151-159`

The important architectural rule is:

- Native `card_edges` is the semantic graph.
- `ref:*` labels are compatibility projection.
- Reviewed edge types require proposal acceptance unless the caller is an
  explicit commit path.
- Edge traversal reads `card_edges`, not labels.

## Solution Surfaces

### 1. Live Accepted-Edge Commit Writes Native card_edges

This is the primary source fix.

The live native-primary `zk_commit_link` path should materialize the accepted
proposal into native `card_edges`, while preserving the compatibility
`ref:<edge>:<target>` label.

Existing support:

- TypeScript already knows when a proposal is accepted: `commitLink()`.
- Rust already has a `card_edges` table and `edge-add` command.
- Native adapter already has `edgeAddCompat()`.

Missing piece:

- A native-primary facade for Silmari `EdgeType`, not legacy Beads `DepType`.
- A reviewed-edge aware Rust write path that can set
  `review_state='reviewed'` for accepted proposals and keep the label projection
  in sync.

The cleanest architecture is a Rust-side transaction that writes the native edge
row and compatibility label together. That could be a new command such as
`commit-edge`/`accepted-edge-add`, or an extension of `edge-add` that accepts an
explicit authority/review mode and writes the projected label. TypeScript
`commitLink()` would call that path only in native-primary mode; legacy Beads
mode can continue to write labels because labels are the legacy storage surface.

This avoids two independent shell mutations where label succeeds and edge write
fails. It also preserves the spec rule that reviewed edges are not inserted with
the default `auto` review state.

### 2. Store-Layer ref Label Projection

The store/API spec says native `label-add` should project `ref:*` labels into
`card_edges`, and `label-remove` should remove matching edges:

- `artifacts/specs/2026-04-28-beads-rust-replacement/03-store-api-and-adapter.md:210-221`

This is a broad consistency fix, but it is not enough by itself unless it also
handles reviewed-edge authority. Blindly parsing every reviewed `ref:*` label in
`label-add` would create `supports`/`refines` rows with the default `auto`
review state, violating the native model.

A safe shape is:

- auto `ref:*` labels can project directly to `card_edges`.
- reviewed `ref:*` labels need an accepted authority context, or else should be
  rejected, converted into a pending proposal, or left label-only with a clear
  warning depending on the chosen compatibility policy.
- label removal must delete the matching projection only when the edge is truly
  owned by that label/projection path.

This can complement solution 1, but it should not replace the accepted proposal
commit path unless `label-add` gains explicit accepted-review parameters.

### 3. Export-Time Label Synthesis

Rust `export_viewer_compat()` could synthesize compatibility `card_edges` from
native `card_labels` exactly like the Bun viewer server does.

This is useful only as a compatibility fallback. It would make the current
viewer graph show label-only edges, but it would leave native traversal,
retrieval, card-native export, and future graph consumers blind because the
source database would still lack `card_edges`.

This should be treated as a temporary mitigation, not the canonical fix.

### 4. Proposal-Log Replay and Backfill

Existing runs can be recovered by replaying committed proposal records from
`link-proposals.jsonl` into native `card_edges`, or by parsing existing
`card_labels` `ref:*` labels and applying the same accepted-review policy used
by import.

This is necessary for already-produced temp DBs and user stores after the live
path is fixed. It should be idempotent on `(source_id, target_id, edge_type)`,
validate both endpoint cards, and record whether each reviewed edge came from an
accepted proposal, accepted manifest, or legacy label.

RedGorge's cache-side workaround is a proof that replaying committed proposals
can reconstruct the visible graph, but replaying into the export cache is not a
source-of-truth repair.

## Recommended Implementation Shape

Use a two-part fix:

1. Add a native accepted-edge commit path that writes `card_edges` and the
   projected `ref:*` label in one Rust-side transaction, with reviewed edges
   persisted as `review_state='reviewed'`.
2. Add a reconciliation/backfill command or migration path that repairs existing
   live native-primary stores from committed proposals and/or accepted reviewed
   label evidence.

Then add store-level label projection only with explicit review semantics. It is
part of the spec, but without authority handling it can recreate the same
architectural confusion in the opposite direction.

Avoid making Rust viewer export the primary repair location. Export can have a
defensive fallback if needed, but the native DB must own the graph.

## Test and Verification Plan

Add a focused native-primary MCP test for reviewed `zk_propose_link` plus
`zk_commit_link`:

- create two native-primary cards;
- propose a reviewed edge, for example `supports`;
- commit the proposal;
- assert the proposal log entry is `committed`;
- assert the source card still has `ref:supports:<target>`;
- assert native SQLite `card_edges` contains `(source, target, supports)`;
- assert reviewed edges are not stored as `review_state='auto'`;
- assert `export-viewer --mode compat` produces a nonzero `card_edges` row.

Add Rust store/CLI tests for the new accepted-edge write command:

- writes label and edge atomically;
- validates source and target card visibility;
- rejects unknown edge types;
- stores reviewed edges with reviewed state/evidence;
- remains idempotent on duplicate commits.

Add projection tests only if `label-add`/`label-remove` are changed:

- auto `ref:*` label add projects to `card_edges`;
- reviewed `ref:*` label add follows the chosen authority policy;
- label remove removes the matching projection only when allowed.

Add a recovery/backfill test:

- seed cards and committed `link-proposals.jsonl` records;
- run the repair path;
- assert native `card_edges` and Rust compat export contain the reconstructed
  edges;
- assert repeated repair is idempotent.

Keep `silmari-agent-memory-i3d` for the current-viewer Rust compat contract, but
do not rely on it alone. It should prove the exported cache can be consumed by
the current viewer. The source fix must be covered by native DB assertions.

## Open Questions

1. Should the accepted-edge command be a new Rust CLI command or an extension of
   `edge-add` with authority flags?
2. Should `label-add` reject reviewed `ref:*` labels without authority, or write
   pending `edge_proposals`?
3. What audit event shape should live accepted proposals write to `card_events`
   so it matches the import/manifest story?
4. Should export-time label synthesis exist only behind an explicit
   compatibility flag for emergency recovery, or not at all?

## Bottom Line

The native-primary pipeline currently has two edge truths:

- live MCP commits: proposal log plus `ref:*` labels;
- Rust native consumers: `card_edges`.

The architecture says there should be one truth: native `card_edges`, with
labels projected for compatibility. Fix the live accepted-edge commit path first,
then add a backfill for existing stores. Export-only synthesis is a workaround,
not the solution.
