# Task Package A — Visible output: screenshot CLI (Tier 1·0a)

**Assigned:** HazyForest (codex, pane 0.1)
**Plan (source of truth):** `thoughts/searchable/shared/plans/2026-05-30-16-46-ENG-0002-tdd-zig-browser-post-v1.md`
**Cycles:** **0a.1** (render-module-extracted) → **0a.2** (screenshot-flag)
**Why you lead:** 0a is the #1 deliverable — the first human-visible artifact. Do this before 0b can demo.

## Scope
Implement cycles 0a.1 and 0a.2 exactly as written, Red→Green→Refactor. Do **not** redefine any
type — reference **§C2** contracts in the plan:
- §C2.3 — `renderNavigatedPageArgb` / `exportArgbPng` signatures, `[]const u32` element type, arena ownership chain.
- §C2.4 — `Command.screenshot{url,out,w=1024,h=768}`, `parseArgs`, add the `.screenshot` arm to main.zig's exhaustive switch.
- §C2.7 — exit codes 0–4 + `defer` temp-file cleanup (no partial PNG on failure/SIGINT).
- §C2.0 — `ScreenshotError` named error set; no public `anyerror`.

## Files
- **You own (edit freely):** `src/render/screenshot.zig` (new), `src/cli.zig`
- **SHARED — reserve via Agent Mail file reservation BEFORE editing, release immediately after:**
  - `src/main.zig` (you add the `.screenshot` dispatch arm) — **you land first**, TurquoiseHill's 0b event-loop wiring follows yours.
  - `src/root.zig` (reachability for the new module)
  - `src/paint/snapshot_gate.zig` (re-point to the moved fns) — **you extract first**, PurpleGate's 3.3 gate edit follows yours.

## Definition of done
1. `zig build test` green (existing snapshot suite unchanged + new Red tests now pass).
2. `zigBrowser --screenshot out.png <url>` writes a decodable 1024×768 PNG and exits 0; fetch failure → exit 2, no output file.
3. Exit codes documented in `--help`.
4. Report completion via Agent Mail to the coordinator + TurquoiseHill + PurpleGate with the exact file list and the main.zig / snapshot_gate.zig reservation released.
