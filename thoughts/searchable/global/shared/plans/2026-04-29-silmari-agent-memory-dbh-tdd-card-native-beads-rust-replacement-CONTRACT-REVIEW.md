---
date: 2026-04-29T06:55:20-04:00
reviewer: VioletBeacon
topic: "silmari-agent-memory dbh card-native beads_rust replacement — Boundary Contract Review"
tags: [review, cw9, boundary-contracts, external]
status: complete
reviewed_plan: thoughts/searchable/shared/plans/2026-04-28-silmari-agent-memory-dbh-tdd-card-native-beads-rust-replacement.md
review_type: boundary_contracts
---

# Boundary Contract Review: card-native beads_rust replacement

## Summary

| Check | Status | Notes |
|---|---|---|
| Boundary inventory complete | pass | Plan has an explicit `## Assumed Existing Contracts` table for BC-1 through BC-8. |
| Producer/consumer alignment | pass for planned state | Boundaries are classified as planned, existing, or existing-but-to-be-replaced; no hidden completed-contract claims found. |
| Ownership of execution | pass | Producer and consumer owners are named for CLI, MCP facade, runtime mode, shadow, snapshot/import, viewer export, and SAI shim boundaries. |
| Transcript/test obligations | pass for plan gate | Required contract tests are named; active implementation work is split into beads. |
| Implementation completeness | in progress | `dbh.2.2` is closed/pushed for Rust snapshot/import/export; `dbh.2.1.*` TypeScript child beads remain assigned to CobaltRiver. |

## Boundary Inventory

| ID | Producer | Consumer | Contract status |
|---|---|---|---|
| BC-1 | Rust CLI command surface | `NativeCliAdapter` and `br-adapter.ts` facade | Planned; child bead `silmari-agent-memory-dbh.2.1.2` tracks live show/list/create transcript. |
| BC-2 | MCP dispatch/resource handlers | `br-adapter.ts` public facade | Existing-but-to-be-replaced; child bead `silmari-agent-memory-dbh.2.1.3` tracks native-primary MCP dispatch/resource transcript. |
| BC-3 | `native-mode.ts` resolver | facade and SAI mode users | Planned; scaffold exists and remaining facade integration is tracked under `dbh.2.1.1` / `dbh.2.1.4`. |
| BC-4 | `br-adapter.ts` dual execution | `native-shadow.ts`, legacy/native adapters, parity reports | Planned; tracked by TypeScript boundary slice and later parity/report work. |
| BC-5 | `create-snapshot --json` / `migration.rs` | `import-snapshot --json` / `importer.rs` | Implemented in `3329d24`; Rust CLI contract test passes. |
| BC-6 | `AcceptedReviewManifest` | importer/store reviewed-edge authority | Implemented in `3329d24` at validation-hook level; wrong-hash and accepted/pending behavior are covered. |
| BC-7 | Rust viewer export | current viewer query/link-builder compatibility cache | Implemented in `3329d24` at Rust producer/query-contract level; compatibility and card-native export tests pass. |
| BC-8 | SAI public memory client shim | ThinkWithMemory hook | Planned/in progress; child bead `silmari-agent-memory-dbh.2.1.4` tracks the public shim boundary. |

## Concrete Transcripts Verified

### BC-5 / BC-6 Snapshot Import

1. Test fixture creates `box1-biblio/.beads/beads.db` and `box2-ideas/.beads/beads.db`.
2. `create-snapshot --json --source-root ... --snapshot-root ...` returns `{ ok: true, result: { manifestPath, manifestHash, sources } }`.
3. `import-snapshot --json --snapshot-manifest <manifest> --target-db <native> --report-dir <reports>` verifies hashes before opening the target for promotion.
4. Import writes staging DB and reports, then promotes to target.
5. A bad `AcceptedReviewManifest.sourceSnapshotHash` returns `SOURCE_HASH_MISMATCH` and leaves the target absent.
6. Without accepted manifest, reviewed refs become pending `edge_proposals`; with matching manifest, the reviewed edge is promoted to `card_edges(review_state='reviewed')`.

### BC-7 Viewer Export

1. Native fixture seeds cards, labels, all 12 edge types, keyword entries, and trunks.
2. `export_viewer_compat` writes `issues`, `dependencies`, `card_edges`, `issues_fts`, `issue_overview_mv`, and `export_meta`.
3. `dependencies` contains only `blocks`; `card_edges` contains all 12 edge types.
4. Current viewer SQL query shapes execute against the Rust-produced compatibility cache.
5. `export_viewer_native` writes `viewer_cards`, `viewer_labels`, `viewer_edges`, `viewer_keywords`, `viewer_trunks`, and `viewer_export_meta`.

## Findings

No new critical boundary contradiction found.

Remaining TypeScript boundary execution is intentionally not complete in this review and is tracked by CobaltRiver-owned beads:

- `silmari-agent-memory-dbh.2.1.1`
- `silmari-agent-memory-dbh.2.1.2`
- `silmari-agent-memory-dbh.2.1.3`
- `silmari-agent-memory-dbh.2.1.4`

## Verdict

- [x] Boundary contract review passes for `dbh.1` plan/remediation acceptance
- [x] Remaining boundary implementation work is tracked in beads
