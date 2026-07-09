---
date: 2026-07-07T14:45:00-05:00
researcher: FrostyGrove
git_commit: af2e4c3
branch: master
repository: zigBrowser
topic: "Embedding a REPL in ZigBrowser for sandboxed local inference"
tags: [research, repl, scripting, sandboxing, wasm, inference, zig]
status: complete
last_updated: 2026-07-07
last_updated_by: FrostyGrove
---

# Research: Embedding a REPL in ZigBrowser for Sandboxed Local Inference

**Date**: 2026-07-07T14:45:00-05:00
**Researcher**: FrostyGrove
**Git Commit**: af2e4c3
**Branch**: master
**Repository**: zigBrowser

## Research Question

How can a REPL be incorporated into zigBrowser for sandboxed local-machine inference? What repos (500+ stars), articles, or Zig Foundation resources exist?

## Summary

**A native Zig REPL does not exist in any production-ready form.** The Zig Foundation accepted a REPL proposal in 2017 (issue #596) but never shipped it; core language design (`defer`, static typing, comptime) makes interactive eval fundamentally difficult. The practical approaches, ranked by fit for zigBrowser, are:

1. **JavaScriptCore (already linked)** — zigBrowser is WebKit-based and already links JSC. Expose a JS eval surface with host-registered Zig functions for inference calls. Lowest friction, proven sandboxing.
2. **Embeddable scripting language (Lua/bog/buzz)** — Zig-native or Zig-bound interpreters with real embedding APIs. Three repos clear 500 stars: ziglua (504), bog (602), buzz (1.5k).
3. **WASM sandbox** — Compile inference/scripting code to WASM, run inside an embedded WASM VM (zware 316 stars, bytebox 136, wasmtime-zig 86). Best security isolation, higher complexity.
4. **Zig-compiled-to-WASM** — The zigtools/playground (122 stars) compiles the Zig compiler to WASM and runs it in-browser. Proves feasibility but is batch-compile, not interactive REPL.

**Lightpanda** (31.6k stars) is the closest prior art: a Zig browser with a REPL + local LLM inference (Ollama). It uses V8/JS, not Zig-as-scripting-language.

## Detailed Findings

### 1. Official Zig Position on REPL/Eval

| Resource | Status | URL |
|---|---|---|
| Issue #596 — "repl for zig" | Accepted, never shipped | https://github.com/ziglang/zig/issues/596 |
| Issue #6840 — portable bytecode backend | Proposal, unimplemented | https://github.com/ziglang/zig/issues/6840 |
| matklad — "Things Zig comptime Won't Do" | Analysis of comptime limitations | https://matklad.github.io/2025/04/19/things-zig-comptime-wont-do.html |

Key barriers to a Zig REPL identified in #596:
- `defer` only fires at function end, breaks step-by-step REPL semantics
- Static typing requires full type declarations per statement
- Scope/lifetime handling across REPL inputs is unsolved
- Runtime struct-versioning needed if types change between statements
- Comptime is hermetic (no I/O) — cannot be repurposed as runtime eval

**No official Zig Foundation article exists about embedding Zig as a scripting language.**

### 2. Community Zig REPL Attempts (None Meet 500-Star Bar)

| Project | Stars | Status | Approach |
|---|---|---|---|
| [zepl](https://github.com/aleloi/zepl) | 14 | Proof-of-concept | Compiles each input as separate shared lib, dloads into running process |
| [hacky-zig-repl](https://github.com/Hejsil/hacky-zig-repl) | 17 | Archived (2023) | Wrapper around zig compiler |
| [zigtools/playground](https://github.com/zigtools/playground) | 122 | Active | Compiles Zig compiler + ZLS to WASM, runs in browser (batch, not REPL) |

None are production-ready or suitable for embedding in a shipping app.

### 3. Embeddable Scripting Languages with Zig Bindings (500+ Stars)

| Project | Stars | Language | Embedding Model |
|---|---|---|---|
| [buzz](https://github.com/buzz-language/buzz) | ~1,500 | Buzz (Zig-native) | Statically typed scripting, JIT via MIR, fibers, own REPL/CLI |
| [bog](https://github.com/vexu/bog) | ~602 | Bog (Zig-native) | Small, strongly typed, embeddable, bidirectional Zig FFI |
| [ziglua](https://github.com/natecraddock/ziglua) | ~504 | Lua (C VM) | Zig bindings for Lua 5.1-5.5, LuaJIT, Luau; static embedding |

**Below 500 stars but relevant:**

| Project | Stars | Language |
|---|---|---|
| [zig-luajit](https://github.com/sackosoft/zig-luajit) | 82 | LuaJIT |
| [jzignet](https://github.com/greenfork/jzignet) | 66 | Janet |
| [wren-zig](https://github.com/dantecatalfamo/wren-zig) | 30 | Wren |

**Assessment for zigBrowser:**
- **bog** is the best fit if you want a Zig-native embeddable language — small, strongly typed, bidirectional function calls with host Zig code, and designed for embedding.
- **ziglua** (Lua) is the most battle-tested embedding story — Lua's sandbox model is well-understood (Neovim, Roblox/Luau, game engines), and Luau's sandboxing documentation is excellent prior art: https://luau.org/sandbox/
- **buzz** has the most features but is more of a standalone language than an embedded runtime — embedding API maturity needs verification.

### 4. WASM Runtimes Embeddable from Zig (Sandbox Layer)

| Project | Stars | Type | Maturity |
|---|---|---|---|
| [zware](https://github.com/malcolmstill/zware) | 316 | Pure Zig WASM runtime | Library for embedded WASM execution |
| [bytebox](https://github.com/rdunnington/bytebox) | 136 | Pure Zig WASM VM | Alpha; crash hardening not done |
| [wasmtime-zig](https://github.com/zigwasm/wasmtime-zig) | 86 | Bindings to Wasmtime (Rust) | Most production-credible sandbox |
| [wasmz](https://github.com/Ray-D-Song/wasmz) | 65 | Pure Zig, register-based | Fast, compact, runs real workloads |
| [wasmer-zig-api](https://github.com/zig-wasm/wasmer-zig-api) | — | Bindings to Wasmer | Active, Zig 0.14+ |

**Assessment for zigBrowser:**
- **WASM provides the strongest security isolation** — linear memory is bounds-checked, no direct host pointers, no ambient syscall access. This is the model the Zig core team itself endorsed for running untrusted `build.zig` logic (issue #14286).
- **Architecture**: Compile inference/script code to WASM module, run inside zware/bytebox/wasmtime, expose host functions (inference API, DOM query) via WASM imports.
- **Tradeoff**: Higher integration complexity vs. scripting-language embedding, but much better security guarantees.

### 5. JavaScriptCore — Already Linked by WebKit (Zero-Cost REPL)

Since zigBrowser is WebKit-based, it **already links JavaScriptCore**. This is the lowest-friction path to a sandboxed REPL.

| Project | Stars | Relevance |
|---|---|---|
| [zig-javascriptcore](https://github.com/Jarred-Sumner/zig-javascriptcore) | 7 | Demonstrates JSC C API from Zig: `JSEvaluateScript`, `JSObjectMakeFunctionWithCallback` |
| Bun's ZigGlobalObject | (part of Bun, 73k+ stars) | Production-grade JSC integration from Zig, custom global objects, GC bridging |

**How it works:**
- WebKit/GTK exposes JSC via `libjavascriptcoregtk-4.1`
- macOS exposes JSC via `JavaScriptCore.framework`
- The API: `JSContextRef ctx`, `JSEvaluateScript(ctx, script, ...)`, register Zig functions as JS-callable via `JSObjectMakeFunctionWithCallback`
- Sandboxing: JSC contexts are isolated by design — no filesystem, no network, no syscalls unless explicitly bridged

**For local inference:** Register a Zig function `infer(prompt)` that calls llama.cpp / Ollama / a local model, expose it in the JS context. User types JS in a REPL panel; `infer("summarize this page")` calls the host Zig function sandboxed behind the JSC boundary.

### 6. Prior Art: Lightpanda (31.6k Stars)

https://github.com/lightpanda-io/browser

A headless browser written in Zig with:
- REPL mode (`./lightpanda agent --no-llm` drops into interactive REPL)
- Local LLM inference via Ollama
- "PandaScript" — vanilla JS with browser primitives
- Uses V8 (not JSC) for JS execution
- License: AGPL-3.0

**Relevance:** Validates the product shape (browser + REPL + local inference). Deliberately uses JS as the scripting language, not Zig. Worth studying `agent` mode implementation.

**Differences from zigBrowser:** Lightpanda is not WebKit-based (ground-up DOM engine), uses V8 not JSC, and is headless-first. zigBrowser is a GUI WebKit shell.

### 7. Local LLM Inference from Zig

| Project | Stars | What |
|---|---|---|
| [llama.cpp.zig (Deins)](https://github.com/Deins/llama.cpp.zig) | 67 | llama.cpp Zig bindings, targets 0.14.x |
| [zinc](https://github.com/zolotukhin/zinc) | — | Zig inference engine, AMD GPU/Apple Silicon, OpenAI-compatible API |
| [llama2.zig (cgbur)](https://github.com/cgbur/llama2.zig) | — | Single-file pure-Zig Llama2 inference |

For production use, linking llama.cpp via C bindings from Zig is the most practical path — it supports CPU, Metal, CUDA, and Vulkan backends.

### 8. Sandboxing Models (Reference)

| Model | Used By | How It Works |
|---|---|---|
| JSC Contexts | Safari, iOS apps | Isolated heap/GC per JSContext, no ambient I/O |
| V8 Isolates + Sandbox | Chrome, Cloudflare Workers | Independent heap per isolate, memory corruption isolation |
| WASM linear memory | All WASM runtimes | Bounds-checked memory, capability-based imports only |
| Luau sandbox | Roblox | Stripped stdlib, readonly globals, interrupt hooks |
| seccomp-bpf | Chromium Linux | Syscall filtering at kernel level |

**Note:** WebKit's own Linux process sandbox is documented as immature/disabled-by-default. If zigBrowser sandboxes eval at the OS level, seccomp + namespaces would be needed in addition to any language-level isolation.

## Architecture Options for zigBrowser

### Option A: JSC REPL (Recommended for v1)

```
User input (JS) → JSC eval → result
                    ↓ (host function call)
              Zig inference bridge → llama.cpp → model response
```

- Already linked (WebKit dependency)
- Battle-tested sandbox (JSC context isolation)
- Proven Zig↔JSC bridge pattern (zig-javascriptcore, Bun)
- Users write JS — familiar syntax, existing ecosystem

### Option B: Embedded Scripting Language (bog/Lua)

```
User input (bog/Lua) → bog/Lua VM → result
                         ↓ (registered Zig function)
                   Zig inference bridge → llama.cpp → model response
```

- bog: Zig-native, 602 stars, designed for embedding
- Lua: battle-tested sandboxing (Luau model), 504-star Zig bindings
- Custom syntax possible (not tied to JS)
- Requires adding a new dependency

### Option C: WASM Sandbox (Strongest Isolation)

```
User input (any lang) → compile to WASM → WASM VM (zware/wasmtime) → result
                                            ↓ (imported host function)
                                      Zig inference bridge → llama.cpp
```

- Strongest security guarantees (memory isolation, capability-based)
- Language-agnostic — can run any WASM-compiled language
- Highest complexity to integrate
- Most appropriate for truly untrusted code

## References

All URLs verified via HTTP 200 on 2026-07-07.

### Repos (500+ Stars)
- buzz (1.5k): https://github.com/buzz-language/buzz
- bog (602): https://github.com/vexu/bog
- ziglua (504): https://github.com/natecraddock/ziglua
- lightpanda (31.6k): https://github.com/lightpanda-io/browser

### Repos (100-500 Stars, Relevant)
- zware (316): https://github.com/malcolmstill/zware
- bytebox (136): https://github.com/rdunnington/bytebox
- zigtools/playground (122): https://github.com/zigtools/playground

### Repos (Under 100, Architecturally Relevant)
- wasmtime-zig (86): https://github.com/zigwasm/wasmtime-zig
- zig-luajit (82): https://github.com/sackosoft/zig-luajit
- llama.cpp.zig (67): https://github.com/Deins/llama.cpp.zig
- jzignet (66): https://github.com/greenfork/jzignet
- wasmz (65): https://github.com/Ray-D-Song/wasmz
- zepl (14): https://github.com/aleloi/zepl
- zig-javascriptcore (7): https://github.com/Jarred-Sumner/zig-javascriptcore

### Zig Foundation / Official
- REPL proposal: https://github.com/ziglang/zig/issues/596
- Bytecode backend proposal: https://github.com/ziglang/zig/issues/6840
- WASM sandbox for build.zig: https://github.com/ziglang/zig/issues/14286
- Comptime limitations: https://matklad.github.io/2025/04/19/things-zig-comptime-wont-do.html

### Sandboxing Reference
- Luau sandbox model: https://luau.org/sandbox/
- WASM security: https://docs.wasmtime.dev/security.html
- WebKit Linux sandbox limitations: https://profincognito.me/blog/security/browser-engine-security-comparison/

## Open Questions

1. **Which REPL language?** JS (free via JSC), bog/Lua (Zig-native embedding), or WASM (language-agnostic)?
2. **Inference backend?** Link llama.cpp directly, call Ollama over HTTP, or abstract behind a provider interface?
3. **REPL UI?** In-browser panel (WebKit devtools-style), separate native panel, or terminal-in-window?
4. **Trust model?** Is the REPL for the app developer only (trusted code) or end-users (untrusted code requiring full sandbox)?
