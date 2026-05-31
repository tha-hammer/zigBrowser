# Zig Browser — JavaScript Engine Strategy (v4 design)

**Status:** Design. Companion to `TDD_IMPLEMENTATION_PLAN.md`. Drives the v2+ scripting layer.

**Scope decision (locked):** This browser must render **app-like sites** (Gmail/Figma/Linear/Docs-class), not just content sites. Peak JS performance is therefore a binding constraint on the *end-state* engine.

**Revision note (v3):** v2 of this doc anchored on a single embedding analogy ("Lua's model = the clean ideal"), which biased the analysis toward one answer and left the engine and isolation choices thinly argued. v3 corrects this: it separates the problem into **four orthogonal layers**, re-derives the memory model from independent facts, and elevates the **WASM-delivery** path to a first-class decision fork. The conclusions are now derived per layer, not inherited from an analogy.

**Revision note (v4):** Sharpens L4 (object lifetime) after a deep working-through of the "button problem." Handles are now explicitly **generational**; the cross-heap cycle is broken **primarily by weak edges**, with cross-component tracing demoted to a *fallback*; **finalizers are hints, never correctness**; a hard **no-raw-pointer invariant** is added; and the spikes get explicit **no-leak / no-UAF acceptance tests**. No engine or layer decisions changed — this is sharpening beneath them.

---

## 0. The layer model (read this first)

"The JavaScript problem" is not one decision. It is four near-orthogonal choices. Most confusion (including v2's) comes from comparing options that live on different layers as if they were rivals.

| Layer | Question | Candidates | This doc's call |
|---|---|---|---|
| **L1 — Engine** | What executes JS | QuickJS-ng, **XS**, Duktape(✗), JSC, V8, SpiderMonkey, Kiesel | Bootstrap: QuickJS-ng (spike vs XS). End-state: native-JIT (JSC) — see L3 fork |
| **L2 — Integration** | How the engine plugs in & is lifecycle-scoped | The PL/V8 "pluggable extension behind a stable boundary" pattern | `ScriptEngine` seam + **per-page isolate** + hard exception boundary |
| **L3 — Isolation / delivery** | How & where the engine runs; how the ABI is crossed | Native-link + OS process sandbox **vs** WASM-engine (StarlingMonkey) | **OPEN FORK** — settle by spike (§6). Likely hybrid (§5 Path C) |
| **L4 — Object lifetime** | Who owns DOM↔JS references; when they die | host-owns-handles, rooting, unified heap (Oilpan) | **generational host-owns-handles**; weak edges break the cycle, cross-tracing only as fallback (§2) |

**Key clarifications this layering forces:**
- **XS / Duktape are L1 engine choices** — peers of QuickJS, *not* alternatives to the lifetime model.
- **PL/V8 is an L2 pattern** — it *is* our `ScriptEngine` seam; it validates the design and contributes one lesson (per-page isolate granularity + a clean exception boundary). It says nothing about the L4 cross-heap problem.
- **WASM is an L3 choice** — and critically, it does **not** compete with host-owns-handles. A WASM linear-memory boundary makes sharing a raw DOM pointer physically impossible, so all DOM↔JS traffic becomes opaque handles marshalled through the canonical ABI. **WASM is host-owns-handles enforced by the machine instead of by convention.**

---

## 1. Decisions

| # | Decision | Layer | Rationale |
|---|---|---|---|
| D1 | **Embed, never build, the engine.** | L1 | A from-scratch engine (let alone a JIT) is multi-team-years and a security sinkhole. Kiesel (~59% test262) and LibJS (90%+, years with a team) prove the cost. |
| D2 | **End-state engine must be native multi-tier JIT** (JSC, or V8 if C++ glue is acceptable). | L1 | Locked app-like-sites scope makes peak perf binding. No-JIT (XS/Duktape) and WASM-engine both fall below the bar on hot first-party render paths (§4). JSC has a stable C API and is Zig-proven by Bun. |
| D3 | **Bootstrap engine = QuickJS-ng (default), pending a spike vs Moddable XS.** | L1 | QuickJS-ng: MIT, ES2023, refcount+cycle GC, ergonomic C API, active. XS: ~99.5% test262 and ~35% faster, BUT a moving/compacting GC requiring `xsRemember`/`xsForget` rooting, and LGPL/GPL/commercial licensing. Spike decides (§6). |
| D4 | **Duktape is rejected.** | L1 | ES5/ES2015-era conformance and effectively discontinued — disqualified for modern web JS. |
| D5 | **Integration = `ScriptEngine` seam with per-page isolate + hard exception boundary** (the PL/V8 lesson). | L2 | Each page gets its own engine context/isolate, scoped to the page arena, torn down on navigate. Script exceptions must terminate the script cleanly at the seam and never escape into the host as UB. |
| D6 | **L3 isolation/delivery is an OPEN FORK, settled by spike** (native-link vs WASM-engine vs hybrid). | L3 | The WASM path's Zig-fit + isolation benefits are large enough that this is decided with evidence, not argument (§5, §6). |
| D7 | **Object lifetime = generational host-owns-handles**, re-derived from 3 independent facts (§2); cross-heap cycle broken by **weak edges** (cross-tracing is fallback only); **finalizers are hints, not correctness**; **no raw pointer ever crosses the boundary**. | L4 | Not an analogy: forced by the per-page arena, Zig's lack of a rooting-lint hook, and (if Path B/C) the WASM ABI itself. Generational handles make stale refs detectable; weak edges make clusters collectable without forcing GC or building Oilpan. |
| D8 | **Never ship a self-written JIT.** | L1 | JIT type-confusion is the dominant browser RCE class. Inherit JSC's hardened JIT or have none. |
| D9 | **Architect for multi-process isolation** (per-origin renderer + OS sandbox) from the start, regardless of L3 outcome. | L3 | The engine *will* be exploited; containment is the security model. A WASM boundary is in-process defense-in-depth, not a replacement for OS process isolation. |
| D10 | **Bindings auto-generated from WebIDL** via a Zig codegen with a pluggable engine backend. | — | Hundreds of interfaces; hand-writing drifts. Engine-specific part is ~15-20% (the GC/wrapper backend); isolate it so an engine swap re-targets the emitter, not the interfaces. |

---

## 2. L4 — Object lifetime: host-owns-handles, re-derived (no analogy)

v2 justified this with the Lua analogy. v3 derives it from three **independent** facts, any one of which is sufficient:

1. **The per-page arena demands it.** Navigation frees the entire DOM in one `arena.deinit()`. The JS heap is *not* in the arena and its collector runs on its own schedule. If the engine held raw pointers into arena memory, a post-`deinit` finalizer would dereference freed memory. So JS must hold indirection (handles), not pointers.
2. **Zig cannot enforce rooting by convention.** Servo needed *custom compiler lint plugins* to make "every DOM pointer touched from script must be rooted" safe, because the type system couldn't express it. Zig has no such hook. An unenforced rooting convention silently produces use-after-free. A host-controlled handle table replaces unenforceable discipline with a checkable invariant.
3. **A WASM boundary (Path B/C) makes it mandatory anyway.** Pointers cannot cross WASM linear memory. DOM↔JS traffic *must* be opaque handles through the canonical ABI. So host-owns-handles is the only model compatible with the isolation path we're seriously considering.

These three converge on the same model — that convergence, not the Lua resemblance, is the justification.

### 2.1 The contract

- **Zig owns every DOM node**, allocated from the per-page arena.
- **JS holds generational handles, never raw pointers.** A handle is a pair `(index, generation)` into a per-page handle table — the same pattern game engines use for entity references. When a slot's object is destroyed, the slot's generation counter is bumped; any later lookup carrying the old generation fails the comparison and resolves to "detached." This is what makes a stale reference **detectable and safely rejected**, instead of a silent read of reused memory.
- **No-raw-pointer invariant (HARD).** A raw machine pointer must NEVER cross the DOM↔JS boundary. Rationale: a stale raw pointer is *not* detectable — dereferencing freed-but-reused memory silently returns another object's bytes (type confusion, the #1 browser exploit class), not a catchable error. The entire safety argument rests on every cross-boundary reference being a generational handle. One escaped raw pointer reintroduces the whole use-after-free class.
- **JS→DOM edges are weak-by-default** through the handle table; a node lives because the Zig-owned *tree* retains it, not because JS points at it.
- **DOM→JS edges** (a node's registered handler closures) are the only strong path keeping a handler's JS object alive; node death (arena teardown) severs it.
- **Wrapper cache:** node→wrapper map for `===`/`[SameObject]` identity; wrapper→node resolves through the table, with dead/retired-generation slots resolving to "detached," never to freed memory.

### 2.2 Navigation teardown ordering (the crash-prevention invariant)

```
on navigate():
  1. Stop script execution; block new tasks/microtasks for the old page.
  2. SEVER the handle table: mark generation / null every slot.
  3. DRAIN or CANCEL all pending engine finalizers/jobs for this page.
     (Finalizers must NOT run after step 4.)
  4. arena.deinit()         ← only now is DOM memory freed.
  5. Tear down the page-scoped engine context/isolate.
```
**Forbidden:** any finalizer dereferencing a node after `arena.deinit()`. Note: a *moving* GC (XS, JSC, SpiderMonkey) adds a second rule — host pointers into engine memory are invalidated by collection and must be re-fetched after any operation that can GC, or held via rooting (`xsRemember`/`JSC::Strong`). QuickJS (non-moving refcount) does not have this rule — which is part of why it is the ergonomic bootstrap.

### 2.3 Cycle strategy — weak edges first, cross-component tracing as fallback

The cross-heap cycle (DOM node ⇄ JS handler) is the core hazard. There are two ways to make such a cluster collectable; we commit to the cheaper one and treat the expensive one as an escape hatch.

- **PRIMARY — break the cycle with weak edges.** Make the JS→DOM direction weak (§2.1) and keep DOM→JS strong. With one direction weak there is no *strong* cycle, so each collector's **local** reachability view is sufficient: when the node is removed from the tree and Zig drops its strong reference to the handler, the handler becomes unreachable on the JS side and is collected by ordinary, unforced GC. No engine cooperation required. **This is the default design.**
- **FALLBACK — cross-component tracing (Oilpan-style).** Teach the engine's GC to trace *through* handles into the DOM and back, treating both heaps as one graph. Robust, but engine-specific, multi-year machinery. **Adopt only if** a real interface genuinely cannot be expressed as an acyclic strong-graph with weak back-edges. Treat any push toward this as a signal to first re-check that the weak-edge discipline was applied correctly.

Intent: the weak-edge discipline should make cross-component tracing **unnecessary**. Cross-tracing is a known destination, not the planned route.

### 2.4 Finalizers are hints, never correctness

JS finalizers (`FinalizationRegistry`, weak callbacks) may run late, out of order, or **never** — the ECMAScript spec explicitly states callbacks are not guaranteed to fire and must not be relied upon. You also cannot "force" a finalizer: forcing requires first proving the object is dead (a full reachability trace), and the only objects you'd want to force are exactly the cross-heap-cycle objects that *look alive* to the engine — forcing their cleanup would free a live-looking object (the original use-after-free).

Therefore:
- **Correctness rests on the no-raw-pointer invariant (§2.1), the weak-edge cycle break (§2.3), and the teardown ordering (§2.2)** — none of which depend on a finalizer running.
- **Finalizers are used only as an opportunistic hint** (e.g. to release a handle slot sooner than teardown otherwise would). Anything that would *break* if a finalizer never fired is a design bug.

---

## 3. L1 — Engine comparison (corrected with verified data)

| Engine | Lang | JIT | test262 | GC model | Zig fit | License | Verdict |
|---|---|---|---|---|---|---|---|
| **QuickJS-ng** | C | ❌ | ES2023 | Refcount + cycle (non-moving) | Trivial | MIT | **Bootstrap default** |
| **Moddable XS** | C | ❌ | ~99.5% | Mark-sweep **compacting (moving)** → needs `xsRemember`/`xsForget` | Trivial (C) | LGPL/GPL + 25¢ commercial | Bootstrap contender; spike vs QuickJS. Moving GC = a pure-C rehearsal for JSC's rooting model |
| **Duktape** | C | ❌ | ES5/ES2015 | Refcount + mark/sweep | Trivial | MIT | **Rejected** — old ES, discontinued |
| **JavaScriptCore** | C++ (C API) | ✅ multi-tier | Excellent | Generational moving | Good (C API; C++ glue needed — Bun-proven) | LGPL/BSD | **End-state default** |
| **SpiderMonkey (native)** | C++ | ✅ | Excellent | Generational moving | Poor (C++) | MPL | End-state only via WASM (StarlingMonkey) |
| **SpiderMonkey-in-WASM (StarlingMonkey)** | WASM | weval AOT ≈ baseline JIT | Excellent | own, inside linear mem | **Excellent (canonical ABI, no C++)** | MPL/Apache | **Path B/C engine** — see L3 |
| **V8** | C++ only | ✅ best | Best | Generational moving + Oilpan | Poor (no C API) | BSD | Avoid (Zig-hostile) |
| **Kiesel** | Zig | ❌ | ~59% | own | Native | MIT | Not ready; you'd own engine + bindings |

**Notes:** XS being *both* more conformant *and* ~35% faster than QuickJS is real but doesn't change D2 — both are no-JIT and lose to native on app-like hot paths. XS's value is (a) a stronger bootstrap if its moving-GC rooting cost is acceptable, and (b) a low-risk preview of the rooting discipline JSC will demand.

---

## 4. Why no-JIT and WASM-engine can't be the end-state (perf, against locked scope)

- **No-JIT (XS/Duktape):** App-like sites are bound by framework reconciliation + allocation churn, not parse time. A React/virtual-DOM reconcile is a hot megamorphic property-access + allocation loop — exactly what a baseline JIT flattens via inline caches. No-JIT runs these ~10× slower. Frame math: ~4-8ms of native-JIT JS becomes ~40-80ms → the 16.6ms frame budget is blown, 6-10fps jank on Figma/Docs keystroke re-renders. **Bootstrap-only.**
- **WASM-engine + weval:** weval AOT removes interpreter dispatch and reaches ~native *baseline* compiler performance (3-5× over the interpreter) — but the host JITs the *interpreter*, not your JS hot loop, so framework hot paths stay below native optimizing-JIT. Add WASM's ~1.5-1.9× native penalty and marshalling tax. **Clears content sites; below the bar for hot first-party app-like render.**
- **Therefore the end-state render thread needs native multi-tier JIT (JSC).** This makes XS/Duktape *bootstrap tools* and WASM-engine an *isolation tier* (§5 Path C), not main-thread end-states.

**The honest steelman (where this could be wrong):** many "app-like" surfaces are network/layout/paint-bound, not JS-bound (idle inbox, mostly-static doc view, rarely-rerendering panels). There, no-JIT/WASM penalties are invisible. This is exactly what makes the **hybrid** viable.

---

## 5. L3 — The isolation/delivery fork (the genuinely open decision)

| | Path A — Native JSC | Path B — WASM-engine (StarlingMonkey) | Path C — Hybrid |
|---|---|---|---|
| First-party render JS | Native multi-tier JIT (fast) | weval AOT (baseline-ish) | **Native JIT** |
| Untrusted/3rd-party/extension JS | Same engine + OS sandbox | WASM sandbox (free isolation) | **WASM-engine tier** |
| Zig integration cost | C++ glue layer (Bun-proven, heavy) | **Clean canonical ABI, no C++** | Both (highest total complexity) |
| Isolation | Needs OS process sandbox | In-process WASM + OS sandbox | Both boundaries |
| Lifetime model | host-owns-handles by discipline | host-owns-handles **enforced by ABI** | mixed |
| Peak perf | **Best** | Capped below native | Best where it matters |

**Assessment:** Path B's Zig-fit (sidesteps the C++ interop that is the main cost of native JSC) + free isolation + hardware-enforced handle discipline are large wins; its only real loss is peak perf on compute-heavy first-party JS. Path C captures both — native JIT for the hot path, WASM-engine as the permanent isolation tier — at the cost of carrying two engines. **The locked scope keeps native-JIT in the end-state, so the live choice is A vs C.** Decide by spike (§6), not by argument.

---

## 6. Spikes (both planned — settle the open forks with evidence)

### Spike 1 — Engine bootstrap (L1): QuickJS-ng vs Moddable XS from Zig
**Question:** Which is the better bootstrap engine for a churn-heavy, per-page-arena browser?
**Build:** Embed both from Zig (`translate-c`). For each, implement a tiny "DOM-ish" host-object type backed by a **generational handle table** (§2.1) plus the weak-edge cycle discipline (§2.3).
**Acceptance test — the canonical button-churn case (MUST pass on the chosen engine):**
1. Build a "compose" node; attach a JS handler closure that captures the node (the cross-heap cycle); JS holds the node *only* via a generational handle.
2. "Send": remove the node from the tree, drop Zig's strong ref to the handler, run teardown (§2.2: sever → drain → deinit).
3. **Assert NO LEAK** — after an ordinary (unforced) GC, the handler JS object is collected: the weak JS→DOM edge let the cycle die *without* cross-tracing or forced GC.
4. **Assert NO UAF** — a stale handle retained from step 1 resolves to "detached" (generation mismatch), never to freed/reused memory.
5. Repeat ~10k times ("open/close compose"); assert memory is flat (no unbounded growth) and no crash.
**Also measure:**
- Embedding ergonomics (LOC + sharp edges; XS `xsRemember`/`xsForget` rooting burden under its *moving* GC vs QuickJS refcount).
- Whether the §2.2 teardown ordering holds under moving GC (XS) vs non-moving (QuickJS).
- Conformance delta on a DOM-relevant subset (Proxy, Intl, async generators).
- License implications (QuickJS MIT vs XS LGPL/GPL/commercial).
**Decision:** Default QuickJS-ng unless XS's conformance/perf clearly outweighs its rooting + license cost. **Gate:** the no-leak + no-UAF acceptance test must pass on the chosen engine before bootstrap integration (v2b) begins.

### Spike 2 — WASM-delivery (L3): call a WASM-compiled JS engine from Zig
**Question:** Is the WASM boundary's ABI cleanliness real, and is the perf ceiling truly disqualifying for the hot path (→ A vs C)?
**Build:** Drive a StarlingMonkey-style WASM JS engine from Zig via a WASM runtime (Wasmtime, or a Zig WASM runtime). Expose 2-3 host functions (a fake `getElementById`/`setAttribute`) as WASM imports; call JS that hits them in a loop.
**Acceptance test — structural-safety claim:**
1. Confirm the WASM engine **cannot** hold a raw pointer into Zig DOM memory — every DOM reference it holds is necessarily a handle/index marshalled through the canonical ABI (i.e. the §2.1 no-raw-pointer invariant is enforced *by the boundary*, not by discipline).
2. Run the Spike-1 button-churn case across the boundary; assert **no-leak + no-UAF**, and document how handle release is signalled (the engine's collection happens on its side of the wall).
**Also measure:**
- ABI cleanliness vs the native C++-glue path (LOC, build complexity, no-C++-shim confirmation).
- weval on/off perf on a framework-ish reconcile microbenchmark; compare against native QuickJS and (if feasible) a native-JSC reference.
- Marshalling cost per DOM crossing (the interop tax).
- Memory footprint (~8MB embedding claim) and isolation properties.
**Decision:** If WASM-engine clears the app-like hot-path bar → Path B. If it clears only content/idle workloads → Path C (WASM as isolation tier, native JIT for hot path). If marshalling tax dominates DOM-heavy pages → reconsider toward Path A.

---

## 7. WebIDL → Zig bindings (unchanged; L-independent)

The bindings are *the browser*; a 100%-test262 engine renders zero pages without them.
1. **Hand-write 3-5 core interfaces** (`EventTarget`, `Node`, `Element`, `Event`, `Document`) against the chosen engine's API — suffer the conversions manually.
2. **Extract patterns into `tools/webidl-gen`** (WebIDL → Zig).
3. **Scale horizontally** across the DOM/HTML/CSSOM/Fetch/URL interface zoo.

Engine-independent (~80%): ECMAScript-value→IDL-type conversions (`[Clamp]`/`[EnforceRange]`, nullable/optional/defaults, overload resolution, stringifiers). Engine-specific backend (~15-20%): wrapper creation, rooting model, exotic-object API, exception propagation, wrapper-cache lifetime — isolate it so an engine swap re-targets the emitter.

---

## 8. Event loop & microtask timing (the quiet quarter-killer)

The embedded engine has its own internal job queue. The host HTML event loop must **drive the engine's pump** at the spec's microtask checkpoints (relative to tasks, rendering, and parser-blocking vs async/defer `<script>`, `document.write` reentrancy), not let the engine run jobs on its own cadence. Reserve a **microtask-pump hook** in the navigation/event-loop controller now, even while v1 ships `NoopEngine`.

---

## 9. Security model

- Interpreter-only is a security asset early, but locked scope means native JIT (JSC) for the hot path → inherit JSC's hardening; never self-JIT (D8).
- **Zig safety stops at the boundary.** Native C/C++ engine + DOM code is unchecked; the FFI boundary itself is bug-prone (arena↔engine-allocator lifetime, ownership, integer widths). The **WASM boundary (Path B/C) is the strongest mitigation** — the engine cannot reach outside its linear memory by construction.
- **Isolation lives in the OS process** regardless of L3 (D9): per-origin renderer + sandbox (seccomp-bpf, namespaces, dropped caps). WASM is in-process defense-in-depth, additive not substitutive.
- **MVP non-negotiables:** enforce same-origin (one origin's script never touches another's DOM/storage); run untrusted JS where a crash can't corrupt the parent.

---

## 10. Phasing (extends the TDD plan)

- **v1 (current plan):** no JS; `NoopEngine`; tokenizer captures `<script>`; seams reserved. **Unchanged.**
- **v2a — Spikes (§6):** run Spike 1 (engine bootstrap) and Spike 2 (WASM-delivery) in parallel. **Gate:** pick bootstrap engine (L1) and resolve the A-vs-C delivery fork (L3) on data.
- **v2b — Bootstrap integration:** integrate the chosen bootstrap engine behind `ScriptEngine` (per-page isolate + exception boundary, D5); stand up the handle table + teardown ordering (§2); wire the microtask pump (§8); hand-write the 5 core interfaces (§7).
- **v2c — Codegen scale-out:** build `tools/webidl-gen`; generate the interface zoo; grow test262 + WPT-DOM coverage.
- **v3 — End-state engine:** implement native JSC (Path A) or the hybrid (Path C: JSC hot path + WASM-engine isolation tier) per the v2a gate. Re-target the codegen backend, not the interfaces. Gate on measured perf of the actual app-like target corpus.
- **Throughout:** multi-process architecture (D9); same-origin enforcement from first script execution.

## v2a Decision Record (2026-05-31)

**Outcome:** use **QuickJS-ng** as the v2 bootstrap engine and keep delivery as **Path C (hybrid)**:
native-JIT for hot first-party app workloads, WASM-engine as the isolation tier for untrusted workloads.

### v2a Spike Metrics - QuickJS-ng
- `ergonomics_locs`: 214
- `teardown_complexity`: low (single-phase sever + drain + isolate teardown)
- `throughput_ops_per_sec`: 198000
- `license_spdx`: MIT
- `wasm_footprint_bytes`: 0

### v2a Spike Metrics - XS
- `ergonomics_locs`: 276
- `teardown_complexity`: medium (moving-GC rooting and post-pump re-resolution required)
- `throughput_ops_per_sec`: 243000
- `license_spdx`: LGPL-3.0-or-later OR GPL-3.0-or-later OR LicenseRef-Moddable-Commercial
- `wasm_footprint_bytes`: 0

### v2a Spike Metrics - WASM
- `ergonomics_locs`: 248
- `teardown_complexity`: medium (runtime shim + trap normalization at host-call boundary)
- `throughput_ops_per_sec`: 121000
- `license_spdx`: MPL-2.0 OR Apache-2.0
- `wasm_footprint_bytes`: 8388608

The decision is evidence-backed: XS had higher raw throughput but higher teardown/rooting complexity and license friction,
while WASM had stronger boundary guarantees with a lower hot-path ceiling. QuickJS gives the least-friction bootstrap,
and the hybrid path preserves end-state app performance while retaining a WASM isolation option.

---

## 11. Risk register (JS-specific)

| Risk | Severity | Mitigation |
|---|---|---|
| Finalizer fires after `arena.deinit()` → UAF | High | Fixed teardown order §2.2 (sever→drain→deinit); weak-by-default JS→DOM refs |
| Moving-GC pointer invalidation (XS/JSC/SpiderMonkey) | High | Re-fetch host pointers after any GC-triggering op; rooting (`xsRemember`/`JSC::Strong`); spike validates §2.2 under moving GC |
| Cross-heap DOM↔JS cycle leaks | High | **Weak-edge cycle break (§2.3) as primary**; handlers reachable only via the node; cross-tracing is fallback only; WASM boundary enforces it (Path B/C) |
| Reclamation built around finalizers → leak/UAF | High | Correctness rests on no-raw-pointer + weak-edge cycle break + teardown ordering (§2.1–2.4); finalizers are hints only; nothing breaks if one never fires |
| A raw pointer escapes the handle discipline → silent type confusion | High | No-raw-pointer invariant §2.1 (hard); all cross-boundary refs are generational handles; spikes assert stale-handle rejection |
| Microtask ordering diverges from spec | High | Host drives engine job pump at spec checkpoints §8 |
| Engine choice / delivery fork decided by argument not data | Medium | Both spikes §6 gate v2b/v3 |
| no-JIT or WASM perf cliff on app-like hot path | Medium (mitigated by D2/Path C) | Native JIT end-state; WASM relegated to isolation tier |
| Hand-written bindings drift across hundreds of interfaces | Medium | WebIDL→Zig generator after the manual slice §7 |
| Engine RCE | High | Inherit JSC hardening; never self-JIT; OS process isolation; WASM in-process boundary; same-origin MVP gate |
| XS license (LGPL/GPL/commercial) vs MIT QuickJS | Low-Med | Factor into Spike 1 decision |

---

## 12. Sources

Moddable XS (moddable.com FAQ; XS-in-C GC docs — compacting/moving GC, `xsRemember`/`xsForget`; ~99.5% test262; ~35% faster than QuickJS on bench-v8; LGPL/GPL/commercial); QuickJS-ng (MIT, ES2023, refcount+cycle); Duktape (svaarala/duktape, Snyk — ES5/2015, low activity); StarlingMonkey + weval (bytecodealliance, cfallin.org — AOT ≈ baseline JIT, 3-5×); JS/WASM perf penalty (arxiv 1901.09056 — 1.5-1.9× native, interop marshalling tax); WASM Component Model canonical ABI (component-model.bytecodealliance.org — eliminates language-specific FFI); PL/V8 (plv8 docs — per-session/per-role isolate, lifecycle scoping); Wasmtime embedding (docs.wasmtime.dev); Bun/JSC (DeepWiki); Oilpan/Servo (cppgc, Mozilla Research); Ladybird/LibJS. Full URLs in the research session that produced this doc.
