---
date: 2026-07-10T18:05:39-04:00
researcher: claude-opus
git_commit: 342ff9125bea591463379941a688a0e7275e4921
branch: master
repository: zigBrowser
topic: "Track C — Local Host-API Surface + EV70 Observability Emission"
tags: [implementation, sequences, ev70, observability, tdd, zig]
status: complete
last_updated: 2026-07-10
last_updated_by: claude-opus
type: implementation_strategy
---

# Handoff: zigBrowser-wjt Track C — Sequences Client Facade + EV70 Observability

## Task(s)

**Track C** of the `zb-sequences-v1` bridge — one of 4 parallel agent tracks.

| Task | Status |
|------|--------|
| 15 facade methods mirroring 14 endpoint groups / 15 HTTP ops | **Completed** (Cycle 1) |
| Wire facade methods through AutomationClient transport | **Completed** (Cycle 6) |
| EV70 `zb_sequences.client_call` wide event emission — all 28 spec attributes | **Completed** (Cycles 2-9) |
| `dedup_key_hash` for event items in `ingestEvents` | **Planned** |
| Real `duration_ms` timing (wrap transport calls) | **Planned** |

Implementation follows the TDD plan at `thoughts/searchable/shared/plans/2026-07-10-zb-sequences-v1-tdd-plan-track-c.md`. Currently past Cycle 9 (of the plan's defined cycles). All 28 EV70 spec attributes are now emitted and tested.

## Critical References

- **Bridge spec**: `thoughts/searchable/shared/plans/2026-07-10-zb-sequences-v1-bridge-spec.md` — EV70 attributes at line ~1666, endpoint groups at line ~450, canonical hashing at line ~2200
- **TDD plan**: `thoughts/searchable/shared/plans/2026-07-10-zb-sequences-v1-tdd-plan-track-c.md`
- **Orchestrator constraints**: Do NOT `git push` or `git pull --rebase` — the orchestrator serializes pushes. Commit locally only. Shared files need `ntm lock zigBrowser <path>` before editing.

## Recent Changes

All in `src/sequences.zig`:

- `src/sequences.zig:538` — Ev70Span: added tenant, parent_span_id, automation_trace_id, external_run_id, actor_user_id_hash, session_id_hash, zigbrowser_version, redaction_suppressed fields
- `src/sequences.zig:519` — TraceContext: added parent_span_id, automation_trace_id, external_run_id, actor_user_id_hash, session_id_hash
- `src/sequences.zig:533` — ClientConfig: added zigbrowser_version
- `src/sequences.zig:569` — Ev70Sink.emit(): dupes all 17 nullable string fields, stores redaction_suppressed
- `src/sequences.zig:569` — Ev70Sink.deinit(): frees all 17 nullable strings via freeOptionals
- `src/sequences.zig:712` — emitEv70(): passes all new trace context + client config fields to sink

## Learnings

1. **Memory ownership model**: Ev70Sink.emit() dupes ALL string attributes into sink-owned memory via `dupeOptional`, and deinit() frees them via `freeOptionals`. This prevents use-after-free when the caller's stack buffers (e.g. span_id_buf) go out of scope. The debug allocator catches leaks — every test runs clean.

2. **span_id is stack-allocated**: `generateSpanId` takes a `*[16]u8` buffer, writes a hex counter into it. The sink dupes it on emit. Do NOT allocate span_id on the heap in the client.

3. **Comptime HTTP method extraction**: `extractHttpMethod` returns `*const [methodLen(template)]u8` — a separate `methodLen` comptime function was needed to avoid a comptime return error. See `src/sequences.zig:832`.

4. **Multi-agent file sharing**: Track B code (lines 1-476) and Track C code (lines 480-906) coexist in `src/sequences.zig`. Track B may overwrite the file — always check for conflicts after their commits. The `endpoint_templates` struct at line 480 is the shared boundary.

5. **Canonical hashing**: Track C delegates to Track B's `canonical_hashing.hashToHex()` for `idempotency_key_hash`. Do NOT reimplement — the hash must match RubyHarbor's server byte-for-byte.

## Artifacts

- `src/sequences.zig:480-906` — All Track C production code
- `tests/sequences/ev70_test.zig` — 53 tests covering all EV70 attributes, trace propagation, error envelopes, transport delegation
- `tests/sequences/client_facade_test.zig` — 10 tests covering facade method correctness
- `build.zig:447-482` — Test module entries for both test files

## Action Items & Next Steps

1. **`dedup_key_hash`** — The spec requires `dedup_key_hash` on event items passed to `ingestEvents`. This is `H(event_item_json)` using Track B's canonical hashing. Needs a new TDD cycle: write test asserting dedup_key_hash appears on EV70 span when ingestEvents is called with event data, then implement.

2. **Real `duration_ms`** — Currently defaults to 0. Need to capture wall-clock time around the `executeViaTransport` call and pass it to `emitEv70`. Zig's `std.time.Timer` or `std.time.nanoTimestamp` can provide this. Another TDD cycle.

3. **Close beads issue** — Once dedup_key_hash and duration_ms are done, close `zigBrowser-wjt`.

4. **Do NOT push** — The orchestrator handles git push. Only commit locally.

## Other Notes

- **Beads issue**: `zigBrowser-wjt` (in_progress, P1) — "Track C: Sequences client facade + EV70 observability"
- **Related beads issues in progress**: `zigBrowser-1ju` (Track D: dashboard UI), `zigBrowser-yqf` (Track A/B: sequences integration API), `zigBrowser-2aa` (build-time JSON config), `zigBrowser-oy2` (cross-phase E2E)
- **You are PART OF an NTM session.** Use `ntm --help` to learn the ntm commands.
- **Test command**: `~/.local/bin/zig build test` (Zig 0.16.0)
- **Git state**: 4 Track C commits ahead of origin on master (orchestrator has not pushed yet):
  - `342ff91` Track C: TDD cycle 9 — remaining EV70 spec attributes
  - `70db085` Track C: TDD cycle 8 — extended context and static config
  - `3f9d8e6` Track C: propagate EV70 API error attributes
  - Plus earlier cycles (6, 5, 4, 3, 2, 1)
- **MockTransport pattern**: Tests use a `MockTransport` struct in ev70_test.zig that returns configurable status codes and bodies, enabling full pipeline testing without HTTP.
