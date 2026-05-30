# Page Lifecycle Specification

Grounding: commit `3d43b1d`.

## 1. Scope
This file defines page ownership, allocator lifetime boundaries, and end-to-end `Page.navigate` behavior.

## 2. Ownership Model
Implementation anchor: `src/page.zig`.

`Page` owns:
- process allocator handle (`process_allocator`)
- page arena (`arena: std.heap.ArenaAllocator`)
- page state (`dom_root`, `style_for`, `box_root`, `render_checksum`, `origin`, `current_url`)
- script engine seam (`engine`)

Rule:
- document-scoped objects are page-lifetime and are invalidated on navigation teardown.

## 3. Navigation Flow
Implementation anchor: `Page.navigate` in `src/page.zig`.

For first load:
1. fetch URL
2. set `origin` and `current_url`
3. build render pipeline
4. publish page state and checksum

For subsequent loads:
1. run ordered teardown of old page
2. reinitialize arena
3. fetch and rebuild pipeline
4. publish new page state

## 4. Ordered Teardown Responsibilities
Implementation anchor: `Page.teardown`.

Teardown performs:
- engine stop/sever/drain/teardown hooks in fixed order
- page arena deallocation
- nulling all page-owned pointers/maps
- reset of `has_loaded`, checksum, and current URL

## 5. End-to-End Render Pipeline
Implementation anchor: `buildRenderPipeline` in `src/page.zig`.

Pipeline stages:
1. parse HTML DOM (`tree_builder.parseDocument`)
2. collect inline style sources (`<style>` text)
3. parse CSS sources and build cascade rules
4. compute style map per node
5. compute block geometry and inline line boxes
6. build display list (background + text)
7. rasterize framebuffer and compute checksum

Published outputs:
- `dom_root`
- `style_for`
- `box_root`
- `render_checksum`

## 6. Link Navigation Integration
Implementation anchors:
- `Page.navigateLink` in `src/page.zig`
- `Window.clickNavigate` in `src/platform/window.zig`

`navigateLink` behavior:
- absolute hrefs: parse and navigate directly
- relative hrefs: resolve against current URL, then navigate

Window click routing delegates navigation to this shared lifecycle path; teardown is not duplicated in platform code.

## 7. Current 3d43b1d Status
- arena-per-page lifecycle: implemented
- ordered teardown + state reset: implemented
- fetch -> parse -> cascade -> layout -> paint pipeline: implemented
- link navigation through shared `Page.navigate` path: implemented and tested
