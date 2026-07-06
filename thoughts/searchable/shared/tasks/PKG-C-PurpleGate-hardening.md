# Task Package C — Hardening: portability, CI, conformance, smoke, engine spikes
(Tier 1·1, 1·2, 1·3, 2·v2a)

**Assigned:** PurpleGate (codex, pane 0.3)
**Plan (source of truth):** `thoughts/searchable/shared/plans/2026-05-30-16-46-ENG-0002-tdd-zig-browser-post-v1.md`
**Cycles:** **1.1** curl-path-portable, **1.2** ci-matrix, **2.1** realweb-smoke, **3.1** conformance-harness-wired, **3.2** dead-loaders-resolved, **3.3** corpus-gate-fails-loud, **v2a.1–v2a.4** engine spikes + decision gate.

## Scope
Implement these cycles Red→Green→Refactor. Reference **§C2** — do not redefine:
- §C2.8 — `SMOKE` / `REQUIRE_SNAPSHOTS` are runtime `getEnvVarOwned`, truthy iff `"1"`.
- §C2.9 — all three spikes share the SAME handle table (`put/get/invalidate`); decision metrics = **FIVE** (`ergonomics_locs, teardown_complexity, throughput_ops_per_sec, license_spdx, wasm_footprint_bytes`); WASM traps → `error.WasmTrap` at the host-call boundary.
- §C2.10 — button-churn memory-flatness = counting allocator, live-alloc count after cycle N == after cycle 1.
- §C2.11 — conformance `Case{name,input,expect}`, loader returns `[]Case`, `cases.len>0` asserted (zero = hard fail).
- §C2.0 — named error sets, no public `anyerror`.

## Files
- **You own (edit freely):** `.github/workflows/ci.yml` (new), `tests/harness/root.zig` + loaders, `tests/smoke/real_web.zig` + `tests/smoke/urls.json` (new), `spikes/quickjs|xs|wasm/**` (new), `Plans/JS_ENGINE_STRATEGY.md` (decision record + §10 phasing).
- **SHARED — reserve via Agent Mail file reservation BEFORE editing, release after:**
  - `build.zig` (curl-path section 1.1 + separate `smoke` step 2.1). TurquoiseHill edits the SDL section — reserve serially, touch only your sections. Cycle 0b.2 ALSO removes the hard-coded libcurl path; coordinate so 1.1 and 0b.2 don't double-edit — whoever reserves first does the curl removal, the other cites it.
  - `src/paint/snapshot_gate.zig` (3.3 corpus-gate fail-loud) — **wait for HazyForest's 0a.1 extraction to land first**, then edit the gate branch. Coordinate via Agent Mail.

## Sequencing
- **Start NOW** on the fully-independent work: 1.1 curl-path, 1.2 CI matrix, 3.1/3.2 conformance harness wiring (`tests/harness/`), and v2a spikes (`spikes/` is an isolated dir — great parallel filler).
- **3.3 snapshot_gate** waits on HazyForest 0a.1.
- **2.1 smoke** build step: reserve `build.zig` when adding the `smoke` step.

## Definition of done
1. `zig build test` green; `SMOKE=1 zig build smoke` renders live pages without crashing (skip offline); harness JSON asserts real cases; no orphan `*_loader.zig`; corpus gate hard-fails under `REQUIRE_SNAPSHOTS=1` with Pillow missing.
2. CI workflow present (Linux + macOS legs); no hard-coded lib paths remain in `build.zig`.
3. Decision record cites all FIVE §C2.9 metrics per spike.
4. Report via Agent Mail to coordinator + HazyForest + TurquoiseHill with file list + reservations released.
