# Scripting Seams Specification

Grounding: commit `3d43b1d` and plan authority `Plans/JS_ENGINE_STRATEGY.md`.

## 1. Scope
This file defines v1 reserved scripting seams that are intentionally engine-agnostic and mostly noop today.

## 2. ScriptEngine Interface (Engine-Agnostic)
Implementation anchor: `src/script/engine.zig`.

`ScriptEngine` contains opaque pointer + vtable with:
- `stopScript`
- `severHandles`
- `drainFinalizers`
- `teardownIsolate`
- `runScript(source)`
- `pumpMicrotasks`

`NoopEngine` implements every hook as no-op while preserving call surface.

## 3. Host-Owns-Handles Wrapper Slot
Implementation anchor: `src/html/dom.zig`.

`Node` includes reserved field:
- `script_wrapper: ?WrapperRef`

`WrapperRef` is `(index, generation)` shape, matching host-owns-handles direction from strategy docs.
In v1 no-JS mode, this slot is structural reserve only.

## 4. Ordered Teardown Contract
Implementation anchors:
- `src/page.zig` (`Page.teardown`)
- `src/root.zig` teardown-order test
- `tests/spies/spy_engine.zig`

Required call order during page teardown:
1. `stopScript`
2. `severHandles`
3. `drainFinalizers`
4. `arena.deinit()`
5. `teardownIsolate`

v1 tests assert the seam order through spy call traces.

## 5. Microtask Pump Checkpoint
Implementation anchor: `src/platform/event_loop.zig`.

Per event-loop turn:
- drain events
- call `pumpMicrotasks` exactly once
- then paint if needed

Test verifies exactly-one invocation and ordering relative to paint.

## 6. Same-Origin Seam
Implementation anchors:
- `src/security/origin.zig`
- `src/page.zig`

`Page.navigate` derives and stores `origin` from URL.
`Origin.eql` normalizes default ports (for example `https` and `https:443` equivalence).

In v1 no-JS mode, this is the reserved policy seam for script/storage isolation rules.

## 7. Current 3d43b1d Status
- full engine-agnostic vtable: implemented
- wrapper slot reserve: implemented
- teardown order seam: implemented and tested
- microtask pump site: implemented and tested
- origin model reserve: implemented and tested
- script execution in rendering pipeline: intentionally noop/non-integrated in v1
