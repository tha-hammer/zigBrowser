---
date: 2026-04-29T06:55:20-04:00
reviewer: VioletBeacon
topic: "silmari-agent-memory dbh card-native beads_rust replacement — Abstraction Gap Review"
tags: [review, cw9, abstraction-gap, external]
status: complete
reviewed_plan: thoughts/searchable/shared/plans/2026-04-28-silmari-agent-memory-dbh-tdd-card-native-beads-rust-replacement.md
review_type: abstraction_gap
---

# Abstraction Gap Review: card-native beads_rust replacement

## Summary

| GWT | Decisions checked | Documented | Undocumented gaps |
|---|---:|---:|---:|
| gwt-0001 | 4 | 4 | 0 |
| gwt-0002 | 4 | 4 | 0 |
| gwt-0003 | 3 | 3 | 0 |
| gwt-0006 | 4 | 4 | 0 |

The four previously identified abstraction gaps are now explicitly documented in plan/context files. No new single-boundary abstraction gaps were found.

## Decision Checklist

### gwt-0001: Schema migration entrypoint ownership

- Correct create/verify entrypoint: `silmari_memory_rust::schema::init_schema(path)`.
- Correct public existing-DB open path: `silmari_memory_rust::schema::open_or_migrate(path)`.
- Correct versioned migration owner: `silmari_memory_rust::schema::migrate_v1_to_v2(conn)`.
- Correct store-level open path: `silmari_memory_rust::store::open_native -> open_or_migrate`.

Evidence: `.cw9/context/gwt-0001.md` names all four entrypoints and `tests/generated/test_gwt_0001.py::test_gwt_0001_context_names_pinned_schema_owners` asserts them.

### gwt-0002: Accepted reviewed-edge import authority

- `AcceptedReviewManifest` schema is documented with `version`, `sourceSnapshotHash`, and `acceptedEdges`.
- Missing manifest means imported reviewed refs become pending proposals.
- `sourceSnapshotHash` must match the verified snapshot manifest.
- Free-form authority strings are rejected; current trusted authority is `operator`.

Evidence: `.cw9/context/gwt-0002.md` includes the manifest schema and validation rules. `dbh.2.2` added Rust contract tests for wrong-hash rejection before target promotion and promotion only when the operator manifest matches the snapshot hash.

### gwt-0003: Native post-save ownership

- Native mode has one durable post-save owner: Rust `create_card`.
- TypeScript validates/facades but must not duplicate native post-save DB side effects.
- Batch create uses the same Rust transaction-local native post-save helpers as single create.

Evidence: `.cw9/context/gwt-0003.md` names Rust `create_card` as the native post-save owner and documents the no-double-post-save rule.

### gwt-0006: Adapter file ownership split

- `br-adapter.ts` is the public facade and runtime mode switch.
- `legacy-br-adapter.ts` owns Beads subprocess compatibility and all `br-sqlite.ts` compatibility reads.
- `native-adapter.ts` owns native Rust CLI spawning and `NativeEnvelope<T>` parsing.
- Production callers must not import `native-adapter.ts` or `br-sqlite.ts` directly.

Evidence: `.cw9/context/gwt-0006.md` documents the split. `tests/generated/test_gwt_0006.py` asserts context phrases plus static import gates.

## Findings

No critical abstraction gaps found.

Open implementation work remains in the `dbh.2.1.*` TypeScript child beads and is boundary/implementation work, not missing abstraction guidance in this plan.

## Verdict

- [x] Abstraction review passes for `dbh.1`
