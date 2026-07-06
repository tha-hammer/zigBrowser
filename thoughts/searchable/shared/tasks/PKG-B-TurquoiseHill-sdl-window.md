# Task Package B — Interactive window: SDL display (Tier 1·0b)

**Assigned:** TurquoiseHill (codex, pane 0.2)
**Plan (source of truth):** `thoughts/searchable/shared/plans/2026-05-30-16-46-ENG-0002-tdd-zig-browser-post-v1.md`
**Cycles:** **0b.1** (display-interface) → **0b.2** (sdl-build-link) → **0b.3** (sdl-window-blit) → **0b.4** (sdl-event-loop)

## Scope
Implement cycles 0b.1–0b.4 Red→Green→Refactor. Reference **§C2** — do not redefine:
- §C2.1 — `Display` fat-pointer vtable: `present(*anyopaque,[]const u32,u32,u32) DisplayError!void` + `deinit(*anyopaque) void`; `PIXEL_FORMAT` ARGB8888; caller-owned pixel slice (no caching past `present`); `NullDisplay` with `lastFrame()`; `DimensionMismatch` when `pixels.len != w*h`.
- §C2.6 — `sdlCheck` is the ONLY place raw SDL codes become `SdlError`; `SDL_Init<0 → error.SdlInitFailed` + stderr.
- §C2.2 — `event_loop.Event` ALREADY EXISTS (`event_loop.zig:5-10`). EXTEND `click`→`{x,y:f32}` and `resize`→`{w,h:f32}` (tracked change in 0b.4); scroll sign per §C2.2; quit is the loop running-flag, NOT an Event.
- **§C2.5 — CRITICAL UAF fix.** On quit, fixed composed order: (1) stop loop / no further events, (2) `page.deinit()`, (3) `display.deinit()`. NO `present()` after step 2. Your 0b.4 test must spy-assert no present is recorded after teardown begins.

## Files
- **You own (edit freely):** `src/display.zig` (new), `src/sdl_backend.zig` (new), `src/sdl2.h` (new), `src/platform/window.zig`
- **SHARED — reserve via Agent Mail file reservation BEFORE editing, release after:**
  - `build.zig` (SDL link section only: `addTranslateC` + `linkSystemLibrary("SDL2",pkg-config)` / `linkFramework` macOS). PurpleGate edits the curl-path + smoke-step sections — reserve serially, touch only your section.
  - `src/main.zig` (event loop + §C2.5 defer chain) — **wait for HazyForest's 0a `.screenshot` arm to land first**, then add the window-run path. Coordinate via Agent Mail.
  - `src/root.zig` (reachability for display.zig) — coordinate with HazyForest.

## Sequencing
- **Start NOW on 0b.1** — `src/display.zig` is brand-new and SDL-free, zero conflicts. Then 0b.2 build link, 0b.3 SdlDisplay.
- **0b.4 main.zig wiring waits** on HazyForest's 0a main.zig landing.

## Definition of done
1. `zig build test` green; NullDisplay pixel-exact + DimensionMismatch tests pass; `SdlDisplay` init under `SDL_VIDEODRIVER=dummy` passes; quit-composition spy test passes (no present after teardown).
2. `zigBrowser <url>` opens a window, scrolls, follows links, resizes, closes cleanly.
3. Report via Agent Mail to coordinator + HazyForest + PurpleGate with file list + reservations released.
