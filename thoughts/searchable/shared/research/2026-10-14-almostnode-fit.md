---
date: 2026-10-14
author: cc_2 (BlueBeaver)
topic: "Can almostnode solve the S3a open decision (plan rev 15.5)?"
status: research, read-only (no install, no code change)
sources:
  - https://github.com/macaly/almostnode (README, package.json, src/ read through gh api)
  - plan thoughts/searchable/shared/plans/2026-10-13-claude-agent-chat-drawer-tdd-plan.md at 69e6fc4 (open decision, D6, D11, D12)
  - a read-only scan of the user's real ~/.claude (counts only; nothing copied or changed)
---

# almostnode and the S3a path-rule decision

## The question

The user asked: "Is it possible to use this as a solution: https://github.com/macaly/almostnode".

The problem it would solve is the open decision in plan rev 15.5. S3a's setup copies the user's SAI into the agent home and refuses any copied text file that holds an absolute path outside the allowed roots. The user's real SAI reaches 82,561 text files through the copy allowlist. 11,929 of them hold such a path, mostly inside skills' `node_modules`, so setup always refuses. The options on the table:
- **(a)** skip dependency trees and refuse only on executed paths;
- **(b)** copy instruction files only;
- **(c)** keep the strict rule and have the user clean their SAI.

## Short answer

**Don't adopt it.** almostnode cannot solve this decision, and it should not be part of the sandbox.

- It is a Node.js imitation that runs **inside a web page**. It cannot run as a command that the Claude CLI starts.
- It cannot run the user's real hooks or the skills that need native code.
- Its isolation is a browser origin, not a kernel boundary. Its own README says the sandbox can still make network requests.

The decision stays between (a), (b) and (c). My recommendation is **(a)**; see the last section.

## 1. What almostnode is

- **What it says it is:** "A lightweight, browser-native Node.js runtime environment". The README tagline is "Node.js in your browser. Just like that."
- **Who builds it:** the makers of Macaly.com, an AI website builder. It exists so their product can run Vite and Next.js dev servers inside a browser tab with no server.
- **License:** MIT.
- **Maturity:** early and experimental.
  - The README says: "This project is experimental and may contain bugs. Use with caution in production environments."
  - The package is at version 0.2.14.
  - The repository was created on 2026-01-29. Its last commit was 2026-02-14, eight months ago.
  - It has 2 contributors; one of them made 94 of the 96 commits.
  - It has about 1,180 stars and 12 open issues.

## 2. How it runs Node code

- **Where:** only in a browser page. Node 20 is needed only for the project's own build tools. There is no build that runs under Node or Bun as a separate process.
- **How code runs:** the module loader wraps each file's source and runs it with JavaScript `eval` (`src/runtime.ts`, lines 776 and 1317).
  - By default this happens on the page's main thread.
  - It can also happen in a Web Worker.
  - It is ordinary JavaScript in the browser's engine. It is not WASM, and not a separate VM.
- **Filesystem:** an in-memory `VirtualFS` with a Node-like `fs` API. Nothing touches the real disk unless the host page copies files in or out.
- **npm packages:** `npm.install()` downloads tarballs straight from `https://registry.npmjs.org` (`src/npm/registry.ts`) and unpacks them into the virtual filesystem. This needs network access at install time.
- **Node built-ins:**
  - About 40 modules are imitated (shimmed): `fs`, `path`, `events`, `buffer`, `crypto`, `stream`, `zlib`, `http` and others.
  - `net`, `tls`, `dns`, `dgram`, `cluster`, `worker_threads`, `vm`, `v8`, `inspector` and `async_hooks` are stubs. `net.connect` only pretends to connect (`src/shims/net.ts`).
  - Native addons (`.node` files) are "stubs only".
- **`child_process`:** `exec` and `spawn` run commands in `just-bash`, a POSIX-subset shell in WebAssembly, against the virtual filesystem only (`src/shims/child_process.ts`).
  - `execSync` and `spawnSync` throw "not supported in browser environment".
  - `fork` has no IPC.
  - It cannot start a real program such as `bun`, `python3`, `git` or `rg`.
- **Isolation modes:** the README lists three.
  - A cross-origin iframe is the highest. `createRuntime()` refuses to start without either `sandbox` or `dangerouslyAllowSameOrigin`.
  - A same-origin Worker is in the middle.
  - The same-origin main thread is the lowest, for trusted code only.
  - The README says: "Do not use `createContainer()` or `container.execute()` with untrusted code."
  - It also says: "Network requests from the sandbox are still possible. Add CSP headers for additional protection."

## 3. What the user's SAI actually needs

From a read-only scan of the user's `~/.claude`:

- **Hooks:** all 35 hook commands in `settings.json` are `bun` running a `.ts` file. The Claude CLI starts each one as a real process with JSON on stdin.
  - 9 of the hook files use subprocesses (`child_process`, `Bun.spawn`, or the Bun shell).
  - 2 import Bun-only APIs.
- **Native code:** the copy allowlist reaches 11 `node_modules` trees, holding 26 native add-on files:
  - `sharp`, `lightningcss`, `@next/swc`, `@rspack/binding`, `@tailwindcss/oxide` and `rollup`.
  - These are the image and build tools of the Media, Remotion, SEOTC and dashboard skills.
- **Subprocesses in skills:** 63 skill or hook source files outside `node_modules` start subprocesses.

## 4. Each use the orchestrator asked about

### (1) Replace copying skills' node_modules into the agent home

**No.** It would not remove the files, only move them, and much of the code would not run.

- **The files still exist:** almostnode still needs the packages, now in its virtual filesystem.
  - We would copy them in from the user's SAI, or download them again from npm at install time. That adds network access and a supply-chain step that today's copy does not have.
  - Either way the same 11,929 files with outside paths are still there. The path rule's question, "do we refuse these?", does not change.
- **The skills that bring the biggest trees would break:**
  - `sharp`, `lightningcss`, `@next/swc`, `rspack` and Tailwind's `oxide` are native code. almostnode stubs them.
  - The 63 source files counted in section 3 start other programs as subprocesses, which `just-bash` cannot do.
- **Nothing calls it:** the Claude CLI runs a skill's scripts through its own Bash tool or a hook. Neither of them can run code inside a web page, so something new would have to bridge the CLI to a page in the browser.

### (2) Serve as the sandbox for hooks or skills, instead of or next to bwrap

**No.**

**Instead of bwrap, it is weaker on every point the plan depends on:**

- **Process boundary.**
  - **bwrap (D12):** each hook gets its own PID namespace, a fresh `/proc`, and `--die-with-parent`. It cannot see the CLI's or the helper's memory (R4-2).
  - **almostnode:** code runs by `eval` in a browser JavaScript realm. Only the cross-origin iframe mode adds a boundary, and that boundary is the browser's origin rules.
- **Filesystem.**
  - **bwrap:** only the binds D12 names. The workspace and `.claude` are read-only, and `secrets/` is never mounted (R4-1, R5-1).
  - **almostnode:** a virtual in-memory filesystem. It is safe only for what the host page chooses to copy in. But real hooks need the real agent home, for example the PRD and state files.
- **Token.**
  - **bwrap:** `zb-hook-run` builds a fresh environment from an allowlist, so no hook process ever holds the token (D11, R5-2).
  - **almostnode:** the token is never inside the page, so it is safe there. But the hook's real process is still started by the CLI, which holds the token, so that process would still need bwrap.
- **Syscalls.**
  - **bwrap:** a seccomp filter denies `ptrace` and `process_vm_*` (P0.6), and an exec census sees every exec (P0.5).
  - **almostnode:** none of this applies. It is a different layer.
- **Network.**
  - **bwrap:** the plan's rules for the host network.
  - **almostnode:** its README says the sandbox can still make network requests, and recommends CSP.
- **Maturity.**
  - **bwrap:** a widely used tool, also used by Flatpak and by WebKitGTK's own web processes.
  - **almostnode:** experimental, version 0.2, 2 contributors, no commits since February.

**Next to bwrap, it buys nothing for this problem and adds a large attack surface.**
- A hook is a process the CLI starts. To run it in almostnode, `zb-hook-run` would have to hand the hook to a WebView in the browser and wait for the answer. That is a new path from the agent sandbox into the browser, which D12 works hard to avoid.
- The hooks would also have to be rewritten, because Bun-only APIs, subprocesses and native add-ons do not run there.

### (3) Run the Claude CLI or the Agent SDK itself

**No.**

- **The CLI is a native program:** the installed CLI, `~/.local/share/claude/versions/2.1.299`, is a native x86-64 ELF executable, not a JavaScript package that a page could load.
- **The SDK needs a real process:** the Python Agent SDK the helper uses starts that CLI as a subprocess, which almostnode cannot do.
- **No real network or terminal:** the CLI needs real outbound HTTPS to Anthropic with its own TLS, and a real terminal and filesystem. almostnode stubs `net` and `tls`, and only offers `fetch` through the browser, which would expose the token to the page's origin and CORS rules.
- **D11 would break:** D11 keeps the token out of the browser's web content entirely. Running the CLI in a page would put it there.

## 5. Recommendation

**Don't adopt almostnode**, either whole or for one part. Its only real strength is running JavaScript projects in a browser tab without a server. That is not the problem S3a has.

**Risks if it were adopted anyway:**
- Most of the user's skills and hooks would stop working: native add-ons, Bun APIs, subprocesses.
- A new bridge from the sandbox into the browser.
- An install-time download from npm.
- A dependency on an experimental, two-person project that has been quiet for eight months.

**For the open decision itself, I recommend option (a):**
- **Skip** dependency trees: `node_modules`, `.git` and build output.
- **Keep the refusal** only for what is executed: `settings.json`, hook commands and the scripts they run.
- **Rewrite the source HOME** in every other copied text file, but don't refuse it.

The scan was always hygiene (D6). The boundary is D12's bwrap sandbox, and a path written in a `.md` or a `.map` file does not change what a sandboxed process can reach. Option (a) keeps the check where it means something, and the user's SAI keeps working.

**Option (b) has a cost:** it would leave out skill code, so skills like Media and SEOTC would not run in the drawer.

**Option (c) has a cost:** it asks the user to edit thousands of third-party files that npm would put back on the next install.

**One open point for whoever builds (a):** a skipped `node_modules` must still be copied, or else left out on purpose. "Skip the scan" and "skip the copy" are different choices, and the plan should name which one it means. Copying it keeps the skills that need it working inside the sandbox.
