# Paint and Platform Specification

Grounding: commit `3d43b1d`.

## 1. Scope
This file defines:
- display list, raster, and text paint behavior
- window, scroll, event-loop turn semantics
- snapshot/perceptual-diff corpus gate
- 90% acceptance requirement

## 2. Paint Pipeline Contract
Implementation anchors:
- `src/paint/display_list.zig`
- `src/paint/raster.zig`
- `src/paint/text.zig`
- `src/paint/snapshot_gate.zig`

### 2.1 Display list
`DisplayList` stores paint commands:
- rect
- text
- image

`addBackground` drops fully transparent backgrounds.
`addText` appends text draw commands.

### 2.2 Raster
`Framebuffer` owns pixel storage (`[]u32` ARGB-like packed values).
Operations:
- `clear`
- `drawRect`
- `checksum`

### 2.3 Text metrics and shaping seam
Current implementation uses deterministic text-metric helpers (`glyphAdvance`, `measureTextWidth`, `lineHeightPx`) in `src/paint/text.zig`.

Normative seam per project plan remains:
- FreeType + HarfBuzz shaping/raster path
- process-lifetime font/glyph cache

v1 status at `3d43b1d`:
- deterministic metric shim is active for reproducible tests
- font determinism gate still enforced via bundled `tests/fonts/DejaVuSans.ttf`

## 3. Window, Scroll, and Event-Loop Contract
Implementation anchors:
- `src/platform/window.zig`
- `src/platform/event_loop.zig`

### 3.1 Scroll
`Window.applyScrollDelta` clamps `scroll_y` into `[0, maxScrollY()]` and toggles `repaint_requested` on changes.

### 3.2 Window teardown seam
`Window.deinit` invokes callback sequence:
1. destroy renderer
2. destroy window
3. quit SDL

### 3.3 Link click routing seam
`Window.clickNavigate` behavior:
- no target hit: no-op
- fragment href (`#...`): repaint only, no fetch
- non-fragment href: call shared `Page.navigateLink`

### 3.4 Event-loop turn and microtask checkpoint
`runTurn` semantics:
1. drain queued events for the turn
2. call `engine.pumpMicrotasks()` exactly once
3. paint if dirty/repaint requested

Microtask timing is verified by test ordering (`pump` before `paint`).

## 4. Snapshot and Corpus Gate
Implementation anchors:
- `src/paint/snapshot_gate.zig`
- `tests/snapshots/manifest.json`
- `tests/snapshots/approved/*.png`
- `tests/snapshots/pillow_tools.py`
- `tests/snapshots/reapprove_snapshots.py`

### 4.1 Real pipeline source
Snapshot tests drive corpus pages through real `Page.navigate` pipeline and render outputs into `.zig-cache/snapshot_actual`.

### 4.2 Diffing
Perceptual diff ratio is computed by Pillow helper script.
Each page has manifest threshold; gate checks `ratio <= threshold`.

### 4.3 90% acceptance
Gate computes required pass count as `ceil(total * 0.90)` and asserts pass count meets/exceeds it.

Current `3d43b1d` result:
- 50-page approved corpus snapshots present (~4.9KB/page)
- gate is green at and above 90% requirement

## 5. Allocator/Lifetime Notes
Plan target is display list page-arena + font cache process-lifetime.
In code today, paint structs are allocator-parameterized and tests enforce deterministic output through snapshot diffs.
