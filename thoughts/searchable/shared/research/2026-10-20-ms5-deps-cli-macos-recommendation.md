---
date: 2026-10-20
author: BlueBeaver (owner, MS5), with JadeBeacon's Mac evidence
topic: "macOS plan MS5 — how the locked dependencies and the Claude CLI ship: (a) lipo-merge vs (b) per-arch trees"
for: the orchestrator, to take to the user (macOS plan rev 17, 1b554fc)
status: recommendation, with evidence from both Macs (scratch only, nothing installed)
---

# MS5 dependencies and Claude CLI on macOS: recommendation

**Recommendation: (a) lipo-merge into one universal tree.** It is proven on both Macs. It keeps the census to one
uniform tree, matching the user's python.org universal2 decision.

**There are two prerequisites, and both apply to (a) and (b) alike:**
1. Relocate the python.org framework.
2. Decide what to do about `cryptography`.

## Evidence (both Macs: Intel x86_64 and laroncha arm64; scratch dirs only, deleted; nothing installed)

1. **The Claude CLI** (JadeBeacon, 6878). `claude_agent_sdk/_bundled/claude` comes as separate arm64 and x86_64
   wheels in `claude-agent-sdk 0.2.165`.
   - It is a **Bun single-file executable, not a Node SEA**. Its JS payload is in ordinary Mach-O sections
     (`__bun`, `__jsc_*`), which `lipo` keeps per slice.
   - Each slice is Developer-ID signed (Anthropic PBC, Q6L2SF6YDW) with the hardened runtime. arm64 is 236 MB and
     x86_64 245 MB.
   - `lipo -create` gives a valid universal binary of **481 MB**. It runs on both Macs (`2.1.294 (Claude Code)`).
   - `codesign -s - --force` and `codesign -vvv` pass on both. lipo **replaces** Anthropic's signature, so the
     binary is re-signed.
2. **The other native dependencies** (BlueBeaver, from `uv.lock`; tested on both Macs).
   - `cffi 2.1.1`, `pydantic-core 2.50.1` and `rpds-py 2026.9.1` ship **separate arm64 and x86_64** cp312 macOS wheels.
   - The lipo-merged `_cffi_backend`, `_pydantic_core` and `rpds` `.so` files each come out `x86_64 arm64`.
   - Under the relocated python3.12 they **import and work** on both arches: pydantic validates, the rpds map
     works, cffi allocates, cryptography hashes.
   - Every other locked package is pure (`py3-none-any`).
3. **`cryptography` has no Intel build.** `mcp`, through `pyjwt[crypto]`, needs it, and **`cryptography 50.0.2` (the
   locked version) has no x86_64 macOS wheel at all**. 49.0.0 and later ship arm64 only; **48.0.1 and earlier ship
   universal2**.
   - 48.0.1's universal2 `_rust.abi3.so` is `x86_64 arm64` and works on both Macs.
   - So an Intel Mac cannot get the locked version without building it from source (Rust and OpenSSL toolchains
     on the Mac, i.e. installs).
4. **The python.org framework is not relocatable as unpacked.**
   - `bin/python3.12`, the `Python` dylib and the `lib-dynload` modules (`_ssl` and others) link
     `/Library/Frameworks/Python.framework/Versions/3.12/...` by absolute path. Run from inside an app, it fails:
     `dyld: Library not loaded: /Library/Frameworks/Python.framework/Versions/3.12/Python`.
   - **Fix, proven on both Macs:** rewrite the 16 Mach-O install names to `@rpath`/`@loader_path`-relative paths
     (`install_name_tool`) and ad-hoc re-sign them. That leaves **0** absolute references.
   - The relocated python3.12 then starts from `Z.app/Contents/Frameworks/agent-host`, imports `ssl` (its own
     OpenSSL 3.0.16), `sqlite3`, `ctypes` and `decimal`, and passes `codesign --verify --strict`.
   - This is an implementation step under the user's decision (python.org universal2, unpacked), not a change to it.
5. **The pure-Python files are identical across arches, except `dist-info`.** Every non-Mach-O file of the native
   wheels is byte-identical between the arm64 and x86_64 wheels, except `*.dist-info/WHEEL` (the platform tag),
   `*.dist-info/RECORD` (hashes) and `*.dist-info/sboms/*.cyclonedx.json`.

## Option (a): lipo-merge, recommended

**Layout** (bundle-relative; a dev tree is the same under `zig-out/`):

```
Frameworks/agent-host/
  Python.framework/Versions/3.12/...      python.org 3.12.10, relocated (@rpath/@loader_path), *-intel64 excluded
  site-packages/                          every locked dependency, one tree
    claude_agent_sdk/_bundled/claude      FAT (lipo-merged arm64 + x86_64)
    _cffi_backend.cpython-312-darwin.so   FAT (lipo-merged)
    pydantic_core/_pydantic_core.*.so     FAT (lipo-merged)
    rpds/rpds.*.so                        FAT (lipo-merged)
    cryptography/hazmat/bindings/_rust.abi3.so   FAT (universal2 wheel, version per the decision below)
    ...pure-Python packages
  zb_agent_host/                          exact file manifest (rev 17)
  runtime.json                            {"lock_sha256": ...}
```

- **`claude-cli` role:** one fat Mach-O component,
  `Frameworks/agent-host/site-packages/claude_agent_sdk/_bundled/claude`.
- **The interpreter finds the dependencies** through an explicit `PYTHONPATH=<agent-host>/site-packages:<agent-host>`
  set by the launch environment (there is no venv on macOS, rev 14 item 3).
- **The two-tree rule:** every non-Mach-O file must be byte-identical across the two per-arch staging trees.
  Staging rewrites each merged wheel's `WHEEL` tag to `macosx_11_0_universal2` and regenerates `RECORD` after the
  merge. The SBOMs are kept from one arch, named in the staging rule. Then the whole `site-packages/` sits under
  the same exact-manifest rule as `zb_agent_host/`: missing, extra, symlink or special entries, or a mismatch, are
  each red.
- **The census:** one inventory. Every Mach-O is fat (the whole-tree scan); `python-runtime` and `claude-cli` are
  components.
- **Codesign and notarization:**
  - lipo and `install_name_tool` invalidate the vendors' signatures (Anthropic's on the CLI, the PSF's on the
    framework). So MS9's inside-out signing re-signs every nested Mach-O with our Developer ID and the hardened
    runtime.
  - **Carry each binary's entitlements over.** The Bun/JavaScriptCore CLI needs its JIT entitlement; read it from
    the vendor signature with `codesign -d --entitlements` before re-signing.
  - Notarization then submits one app with fat binaries.
- **Size:** the CLI is 481 MB fat, the framework about 114 MB, and the other dependencies about 37 MB (including
  `cryptography`). That is about **632 MB** uncompressed.

## Option (b): per-arch trees picked at run time

**Layout:**

```
Frameworks/agent-host/
  Python.framework/...    one, universal, relocated
  arm64/site-packages/    thin arm64 natives + the arm64 CLI
  x86_64/site-packages/   thin x86_64 natives + the x86_64 CLI
```

- The launch picks the tree from `uname -m` and sets `PYTHONPATH` to it. Under Rosetta, an arm64 Mac running
  the x86_64 browser slice must still pick consistently.
- **`claude-cli` role:** two thin Mach-Os, one at each `<arch>/site-packages/claude_agent_sdk/_bundled/claude`.
- **The census** needs a per-arch exception to "every Mach-O fat", and the two trees differ by design. Each tree is
  checked against its own arch, which is a new census shape.
- **The two-tree rule:** the pure-Python files would be duplicated, and each copy checked identical.
- **Codesign:** the CLI could keep Anthropic's own signature (not modified). The framework still needs
  relocation and re-signing. Nested-code signing doubles the dependency trees.
- **Size:** about the same for the CLIs (236 + 245 MB), plus the pure-Python dependencies twice (about 30 MB more).

## Why (a)

- It is proven runnable and signable on both arches with the real wheels.
- It gives one uniform tree, one `claude-cli` path, the existing census unchanged, and no run-time picker.
- It mirrors the user's universal2 Python decision.
- (b)'s only advantage is keeping the vendors' signatures, and the framework relocation re-signs anyway.

## Decisions needed from the user

1. **(a) or (b).** Recommendation: (a).
2. **`cryptography` for the macOS bundle.** Recommendation: pin `cryptography==48.0.1` (universal2) for the
   macOS bundle only, after checking its security advisories against 50.0.2. The alternatives:
   - build 50.x for x86_64 from source on the Intel Mac, which needs Rust and OpenSSL toolchains installed there;
   - drop Intel Mac support for the agent.
3. **Confirm the framework relocation step** (rewrite the install names, re-sign) as part of the python.org
   decision. It is required for the unpacked framework to run from inside the app.
