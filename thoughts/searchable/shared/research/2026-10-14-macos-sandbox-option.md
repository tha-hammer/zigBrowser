---
date: 2026-10-14
topic: Why macOS needs its own agent-sandbox backend, and which one to build
follows: 2026-10-14-agent-sandbox-redteam.md
method: 3 web-research agents (primary sources where reachable) plus a read of this worktree's src/wkwebview_shim.m
status: research (committed da24aba); macOS is future work, no plan change
---

# macOS sandbox option for the agent drawer

## Decisions already made (inputs to this report)

- Linux keeps bwrap. It gets its own private network namespace and an allowlist proxy that lets through `api.anthropic.com`, plus only those endpoints the CLI strictly needs and P0's census verifies (fail closed, not a general allowlist).
- The only bridges are to host `127.0.0.1:51091` (voice) and `127.0.0.1:31337`.
- The SAI copy uses rule (a).
- The token route stays as built: FIFO, then a socketpair on fd 3, never the environment. There is no token-swapping proxy.

## Terms

- **XNU**: the macOS kernel.
- **Seatbelt**: Apple's kernel sandbox. A process opts in with a profile written in **SBPL** (Sandbox Profile Language). `sandbox-exec` is the command-line way to apply one.
- **App Sandbox**: the entitlement-based sandbox that App Store apps use. It is built on Seatbelt.
- **Task port**: the macOS handle that lets one process read and write another's memory. You get one with `task_for_pid`.
- **Hardened runtime**: a code-signing option that blocks code injection and memory tampering of the signed program.
- **TCC**: macOS privacy permissions (Accessibility, Screen Recording, and so on).
- **Backend**: one implementation of "start the agent in a sandbox" for one OS.

## Short answer

1. **Our Linux design cannot run natively on macOS.** It is built from Linux kernel features that XNU does not have:
   - namespaces (mount, PID, network, user, IPC);
   - seccomp-bpf;
   - `/proc`;
   - `PR_SET_PDEATHSIG`.

   That is why every container tool on macOS runs a Linux VM. ([Podman machine](https://docs.podman.io/en/stable/markdown/podman-machine.1.html), [Red Hat](https://www.redhat.com/en/blog/podman-mac-machine-architecture))
2. **There are two real macOS choices:**
   - **(a) Seatbelt.** It runs the user's macOS hooks natively. It is what Anthropic's sandbox-runtime, Claude Code and Codex use.
   - **(c) A Linux VM on Apple's Virtualization.framework.** It runs our exact Linux backend inside the guest.

   App Sandbox (b) and Network Extension / Endpoint Security (d) are not practical for this.
3. **Build Seatbelt first,** with two changes from how srt uses it:
   - **Hooks are started by the app, not by the CLI.** Seatbelt profiles cannot be nested, so each hook gets its own separate sandbox through an app-side launcher.
   - **The profile denies every task-port and process-info operation except on the process itself.**

   Keep the VM as the fallback backend, behind the same interface. Switch if the one-day spike fails on token isolation or orphan cleanup, or if Apple removes `sandbox-exec`.
4. **One shared backend interface can cover all three:** Linux bwrap, macOS Seatbelt or VM, and Windows WSL2. The allowlist proxy and the port bridges are host-side code that all three share.

## 1. Why the Linux design can't run natively on macOS

### Feature by feature

| Linux feature we use | macOS status | Closest macOS substitute |
|---|---|---|
| Mount namespace + read-only bind of the workspace | No mount namespaces. Unprivileged users cannot bind-mount. | Seatbelt path rules: `(deny file-write* (subpath "<workspace>"))`. FSKit passthrough file systems exist from macOS 15.4, but need FSKit entitlements and a user-enabled extension ([FSKit](https://developer.apple.com/documentation/fskit.md)). |
| PID namespace (hook can't see the CLI's PID) | No PID namespaces. XNU keeps one global process table, `pid_hash`/`allproc` in [kern_proc.c](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_proc.c). This is from a partial read of the source, so the full absence is **unverified**. | No way to hide a PID. You can deny *using* it: Seatbelt `process-info*`, `mach-priv-task-port` and `signal` rules. |
| Network namespace + proxy + bridges | No network namespaces. `pf` needs root (**unverified**). | Seatbelt network rules by IP and port: `(allow network-outbound (remote ip "localhost:PORT"))`. No hostname matching, so names are filtered in the host proxy. |
| User namespace | None. | A separate macOS user account would need a one-time admin install. |
| seccomp-bpf (deny `ptrace`, `process_vm_*`) | None. I found no citable "no seccomp" statement, so that is **unverified**. In practice it is absent. | Seatbelt operations, plus macOS's own task-port rules (below). |
| `/proc/<pid>/mem`, `/proc/<pid>/environ` | No `/proc`. | Memory goes through `task_for_pid` plus `mach_vm_read`. Argv and env go through `sysctl KERN_PROCARGS2` (below). |
| `PR_SET_PDEATHSIG`, `--die-with-parent`, PID-namespace teardown | None. I found no kernel feature that kills all descendants when one process dies. | kqueue `EVFILT_PROC` + `NOTE_EXIT` on the parent ([kqueue(2)](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/man/man2/kqueue.2)), a pipe whose EOF means "parent gone", process groups and `killpg`. A descendant that calls `setsid` escapes `killpg`. |

### How macOS exposes process memory and info

- **Memory (`task_for_pid`)**: on current macOS this is *stricter* than Linux with `ptrace_scope=0`.
  - Apple says a debugger needs the `com.apple.security.cs.debugger` entitlement. Even then, it gets a task port of a third-party process only if the target has `get-task-allow`, and SIP protects processes without it.
  - A non-root caller with the debugger entitlement also gets an admin-password dialog (taskgated).
  - Source: [debugger entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.debugger.md).
  - Hardened runtime plus SIP prevent "process memory space tampering". ([Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime.md))
  - I could not read the exact XNU check for a *non-hardened* target, so whether a same-uid, non-root, unentitled process is blocked there is **unverified**. Treat it as blocked, but prove it in the spike.
- **Argv and environment (`KERN_PROCARGS2`)**: this is the macOS version of `/proc/<pid>/environ`.
  - The XNU source lets a same-uid caller read another process's argv.
  - It returns the **environment too**, unless the target is code-sign "restricted" (for example hardened). ([kern_sysctl.c](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_sysctl.c), with the buffer layout confirmed by [Crashpad](https://chromium.googlesource.com/crashpad/crashpad/+/refs/heads/main/util/posix/process_info_mac.cc))
  - **This is why the FIFO-to-fd-3 token route matters on macOS too.** An env-based token would be readable by any same-user process if the CLI is not hardened.
- **Is the macOS Claude CLI hardened?** **Unverified.** User reports conflict: "signed but not notarized", and "unsigned when downloaded by Claude Desktop". ([issue 60799](https://claudeissues.com/issue/60799-notarize-the-macos-claude-cli-binary-un-notarized-binary-causes-syspolicyd-xprot), [issue 83656](https://claudeissues.com/issue/83656-bug-claude-desktops-downloaded-code-cli-binary-claude-code-vm-claude-code-is-uns)) Check it with `codesign -dv --entitlements - <cli>` and do not rely on it.

### Which of our guarantees has no direct macOS equivalent

1. **Hooks can't see the CLI's PID or read its memory.**
   - *Can't see* has no equivalent: PIDs are global.
   - *Can't read memory* has an equivalent, and arguably a better one. It comes from task-port rules plus a Seatbelt deny.
2. **A private network namespace**: no equivalent. Seatbelt's IP-and-port rules give the same *result* for our allowlist: proxy port plus `:51091` plus `:31337`. They do it per sandbox, not by giving the sandbox its own loopback.
3. **A read-only workspace bind**: no equivalent. Seatbelt path denies give the same result, enforced by the kernel.
4. **"Dies with the parent"**: no equivalent. This is the weakest spot on macOS (see section 3).

## 2. macOS options, red-teamed briefly

### (a) Seatbelt (`sandbox-exec` with an SBPL profile)

**Status**
- **Deprecated, but still in use.** The man page says "The sandbox-exec command is DEPRECATED" ([man page copy](https://leancrew.com/all-this/man/man1/sandbox-exec.html)). `sandbox_init(3)` has been marked deprecated since 10.8.
- Apple DTS says SBPL "has never been documented for third-party use, and thus is not considered API" ([forum 777509](https://developer.apple.com/forums/thread/777509)).
- **New risk.** A current man page quoted in August 2026 says the named built-in profiles "must not be used when building against macOS SDK >= 27.0. Processes opting into them will be killed" ([openssh-unix-dev](https://lists.mindrot.org/pipermail/openssh-unix-dev/2026-August/042690.html)). Whether that also hits custom SBPL passed to `/usr/bin/sandbox-exec` is **unverified**.

**Who uses it**
- **Anthropic sandbox-runtime (srt)** ([source](https://github.com/anthropic-experimental/sandbox-runtime/blob/main/src/sandbox/macos-sandbox-utils.ts)):
  - It starts from `(deny default)`.
  - It allows `process-exec` and `process-fork`, and `process-info*`, `signal` and `mach-priv-task-port` with `(target same-sandbox)`.
  - It has a short mach-lookup list.
  - It allows broad file reads with specific denies, and writes only to given roots.
  - With network limits on, it emits only `(allow network-outbound (remote ip "localhost:<proxyPort>"))`.
  - It runs `log stream` to report violations.
- **Claude Code `/sandbox`**: uses Seatbelt on macOS, but "covers shell commands only… hooks run outside it" ([docs](https://code.claude.com/docs/en/sandboxing)). Its worktree escape, CVE-2026-55607, overwrote `.zshenv` from a writable workspace ([GHSA-7835-87q9-rgvv](https://github.com/anthropics/claude-code/security/advisories/GHSA-7835-87q9-rgvv)). Our read-only workspace avoids that class of attack.
- **Codex** ([seatbelt_base_policy.sbpl](https://github.com/openai/codex/blob/main/codex-rs/sandboxing/src/seatbelt_base_policy.sbpl), [seatbelt.rs](https://github.com/openai/codex/blob/main/codex-rs/sandboxing/src/seatbelt.rs)):
  - It uses `(deny default)`.
  - Signals and `process-info*` are limited to the same sandbox.
  - It has a sysctl-read allowlist and two mach services.
  - It always calls `/usr/bin/sandbox-exec` by full path.
  - Writable roots are passed as `-DWRITABLE_ROOT_0=…`, and the root itself cannot be unlinked.
  - Outbound is allowed only to loopback proxy ports, and it fails closed if no loopback proxy is set.
- **Chromium**: applies the profile at process start, before any framework loads, through the `sandbox_init_with_parameters` family ([design doc](https://chromium.googlesource.com/chromium/src/+/main/sandbox/mac/seatbelt_sandbox_design.md)).

**What it can do for us**
- **Network allowlist**: by IP and port only, including the `localhost` keyword. That is enough for us: the proxy port, `localhost:51091` and `localhost:31337`. The hostname check (`api.anthropic.com`) happens in our host proxy, as on Linux.
- **Localhost port allow**: yes. Don't copy srt's `allowLocalBinding`; it opens `localhost:*`.
- **File scoping**: yes.
  - Deny all writes except the scratchpad and the CLI state directories.
  - Deny writes under the workspace. The app broker writes there from outside the sandbox.
  - Unlike srt, use a deny-default *read* rule too, so the user's real `~/.claude` and repos stay unreadable.
- **Process-info denial**: yes. WebKit's own WebProcess profile denies `process-info*` except a few operations on itself, which shows real programs run that way ([WebProcess.sb](https://opensource.apple.com/source/WebKit2/WebKit2-7606.4.5/WebProcess/com.apple.WebProcess.sb.in.auto.html)).
  - Whether Bun, Node and the CLI run with `process-info*` and `mach-priv-task-port` denied is **unverified** (spike item).
  - Which operation gates `KERN_PROCARGS2` is **unverified**. A `sysctl-read` allowlist is the likely control.
- **mach-lookup**: keep the list tiny. Allowed mach services are the real escape surface: 2026 macOS sandbox escapes went through XPC services, though those CVE numbers come from aggregators and are **unverified**.
  - Denying `com.apple.windowserver*` stops screen capture and synthetic clicks.
  - Denying mDNSResponder stops DNS-based leaks. The CLI resolves through the proxy.

**Attacks**
1. **Profiles don't nest.**
   - A sandboxed process "cannot apply additional sandbox policies", and children inherit the parent's profile ([bdash.net.nz](https://bdash.net.nz/posts/sandboxing-on-macos/), [Zed sandbox README](https://git.secluded.site/zed/blob/local-sandboxing/crates/sandbox/README.md)).
   - So if the CLI starts the hooks, every hook is in the **same** sandbox as the CLI. srt's `(target same-sandbox)` rules then *allow* a hook to inspect the CLI.
   - **Fix:** the hook command is a tiny client, the macOS `zb-hook-run`. It asks the app, outside the sandbox, to spawn the hook under its *own* profile, and passes stdin, stdout and stderr over `SCM_RIGHTS`.
   - This is the macOS version of our nested PID namespace. It is also the "supervisor over IPC" pattern recommended in a design note ([grida](https://grida.co/docs/wg/ai/agent/srt)).
2. **Orphans.**
   - No PDEATHSIG and no PID namespace. A hook can double-fork and `setsid` to escape the process group.
   - Fixes: a launcher outside the sandbox watches the browser through kqueue `NOTE_EXIT` and a pipe EOF, and tracks every spawned PID.
   - The strongest fix is a dedicated macOS user for the agent: the launcher then does `kill(-1, SIGKILL)` as that user. That needs a one-time admin install, which is the same trade srt's Windows mode makes.
3. **Deprecation.** `sandbox-exec` could go away in a future macOS. The VM backend is the hedge.
4. **Profile size.** srt hit ARG_MAX with an inline `-p` profile ([issue 73468](https://claudeissues.com/issue/73468-macos-sandbox-unusable-seatbelt-profile-passed-inline-via-sandbox-exec-p-exceeds)). Use a profile file plus `-D` parameters, as Codex does.
5. **Path rules are not binds.** Seatbelt matches paths, and srt warns that "an allow that is also the name of a path allows everything beneath". Our `openat2`-style safety in the broker must be ported, for example with `O_NOFOLLOW` and `fstat` checks. macOS has no `openat2` (`RESOLVE_BENEATH` equivalents are **unverified**).

**Steelman**
- Hooks run natively: macOS Bun, the user's `node_modules` with darwin addons, and their `afplay`/`osascript` habits.
- It starts instantly, ships nothing extra, and has three big precedents: srt, Codex and Chromium.
- macOS memory protection starts stronger than Linux with `ptrace_scope=0`.

### (b) App Sandbox with entitlements

- Children inherit the parent's App Sandbox and can never get more access than it ([DTS](https://developer.apple.com/forums/thread/744961)).
- Network entitlements are only on/off switches (`network.client`, `network.server`), with no per-host or per-port rules ([WWDC 2011 session 204](https://nonstrict.eu/wwdcindex/wwdc2011/204/)). That is "likely": no newer Apple statement either way.
- Running user binaries from `~/.bun/bin` or the user's scripts is a poor fit. `NSUserUnixTask` only runs scripts from the app's Application Scripts folder ([NSUserUnixTask](https://developer.apple.com/documentation/foundation/nsuserunixtask.md)), and a forum case shows a Homebrew binary failing under the sandbox ([forum 129716](https://developer.apple.com/forums/thread/129716)).
- It would also force the *browser* into App Sandbox, or need a separately signed sandboxed helper with its own container and a different HOME.
- It cannot give hooks a stricter profile than the CLI.
- **Verdict:** not practical for a helper that runs `claude` and arbitrary user hooks.

### (c) A Linux VM with Apple Virtualization.framework (or libkrun/krunkit, Lima, OrbStack-style)

**How it would work**
- The app starts a small Linux guest and runs our **unchanged** Linux backend inside it: bwrap, nested PID namespaces, seccomp and the FIFO-to-fd-3 token route.
- The guest gets **no network card**. Everything crosses over vsock: the broker stream, the token handoff, the allowlist proxy and the two port bridges. That mirrors the Linux "Unix socket bound in" design.
- Apple has no built-in host-only networking or port forwarding. Teams build their own with `VZFileHandleNetworkDeviceAttachment` ([forum 783894](https://developer.apple.com/forums/thread/783894)). Vsock-only avoids needing that.

**What it costs**
- **Image**: an arm64 and an x86_64 Linux image with Bun, Node and the CLI. My earlier estimate was 150–300 MB (**unverified**). It needs kernel patching forever.
- **Startup and memory**: no sourced numbers (**unverified**). A Fedora write-up needed about 4 GB and 4 CPUs for Claude Code in a krun VM ([Fedora Magazine](https://fedoramagazine.org/sandbox-ai-coding-agents-with-microvms-on-fedora-linux/)).
- **File sharing**:
  - virtio-fs needs macOS 12+ (macOS 13+ in Lima's `vz` mode, [Lima mounts](https://lima-vm.io/docs/config/mount/)). Read-only shares exist.
  - node_modules speed varies. OrbStack's own vendor benchmark reports 77–88% of native for installs ([OrbStack](https://orbstack.dev/blog/fast-filesystem)). Docker still suggests named volumes ([Docker](https://www.docker.com/blog/file-sharing-with-docker-desktop/)).
- **The user's hooks**:
  - TypeScript sources work with a Linux Bun.
  - The darwin native addons must be reinstalled for Linux.
  - Hooks that call macOS tools (`afplay`, `osascript`, kitty) break.
  - The voice server on host `:51091` works through the vsock bridge.
- **Apple Silicon vs Intel**:
  - Virtualization.framework runs Linux guests on both, with Rosetta for x86 binaries on Apple Silicon from macOS 13. These are background facts; Apple's pages did not load for me, so they are **unverified**.
  - libkrun and krunkit are Apple-Silicon-only, macOS 14+ ([krunkit](https://raw.githubusercontent.com/containers/krunkit/main/README.md)).
  - Apple's `container` needs Apple Silicon plus macOS 26 ([apple/container](https://raw.githubusercontent.com/apple/container/main/README.md)).
  - So use Virtualization.framework directly if Intel Macs matter.
- **Signing**: the app needs the `com.apple.security.virtualization` entitlement ([Apple](https://developer.apple.com/tutorials/data/documentation/bundleresources/entitlements/com.apple.security.virtualization.json)).
- **Third-party wrappers**: OrbStack is commercial. Lima is open source; its Apache-2.0 license and CNCF status are **unverified** here.

**Steelman**
- It is the only macOS option that keeps *every* Linux guarantee and test: PID namespaces, private network, read-only binds and die-with-parent inside the guest.
- Stopping the VM ends every guest process. That the VM ends with the app is **unverified**, and it is a spike item.

**Attack**
- It is the most expensive option, and it breaks native macOS hooks.

### (d) Endpoint Security, Network Extension, content filter

- **Network Extension content filter**:
  - It must ship as a system extension, using the `-systemextension` entitlement variant for Developer ID builds ([forum 737894](https://developer.apple.com/forums/thread/737894)).
  - The entitlement is restricted, but available to paid teams ([forum 835776](https://developer.apple.com/forums/thread/835776)).
  - The user must approve it. On macOS 26 it is reportedly rejected outside `/Applications` ([forum 820254](https://developer.apple.com/forums/thread/820254)).
- **Endpoint Security**:
  - It needs `com.apple.developer.endpoint-security.client`, granted by Apple on request.
  - Approval reportedly takes months, and without it you can only test with SIP off ([forum 736042](https://developer.apple.com/forums/thread/736042), [forum 743263](https://developer.apple.com/forums/thread/743263)).
- They also filter per *app*, which is a poor match for unsigned hook interpreters like `bun`.
- **Verdict:** not for now. They might be an optional enterprise add-on later.

## 3. The four hard requirements on macOS

| Requirement | (a) Seatbelt, hardened as above | (b) App Sandbox | (c) Linux VM | (d) NE/ES |
|---|---|---|---|---|
| **Token not readable by hooks** | ✔ if (1) hooks are app-spawned in their own sandbox, (2) `mach-priv-task-port` and other-process `process-info*` are denied, and (3) the FIFO-to-fd-3 route is kept (the env is readable via `KERN_PROCARGS2`). macOS task-port rules add a base layer. **Spike must prove it.** | ✖ hooks share the CLI's sandbox, so no separation | ✔ same as Linux, inside the guest; the token crosses vsock once | n/a (no process isolation) |
| **Network = api.anthropic.com + :51091 + :31337** | ✔ SBPL allows only `localhost:<proxy>`, `localhost:51091` and `localhost:31337`; the host proxy allows only `api.anthropic.com`; deny mDNSResponder | ✖ on/off only | ✔ guest has no network card; vsock proxy and bridges only | ~ possible, but needs a system extension and user approval |
| **Workspace writes only via the app broker** | ✔ SBPL denies writes under the workspace; the broker runs outside the sandbox. Port the `O_NOFOLLOW`/`fstat` checks. | ~ container model fights the agent-home layout | ✔ read-only virtio-fs share; the broker writes on the host | ~ ES could block writes, but needs an Apple grant |
| **No orphans when the browser dies** | ~ launcher with kqueue `NOTE_EXIT` plus pipe EOF plus PID tracking; a `setsid` double-fork can escape. ✔ only with a dedicated agent user and `kill(-1)` (one-time admin) | ~ same problems | ✔ the VM stops, so everything inside stops (**unverified** that the VM dies with the app; spike) | n/a |

## 4. WKWebView instead of WebKitGTK

- This worktree already has a macOS shim, `src/wkwebview_shim.m` (888 lines). It registers the `zbHost` handler with `addScriptMessageHandlerWithReply:… contentWorld:WKContentWorld.pageWorld`.
- **Drawer**: on macOS it is a native AppKit view, not GTK. The approval card is a native AppKit panel owned by the app, so the approval decision stays in the app as on Linux.
- **Approval forgery is harder than on X11.**
  - Posting synthetic input needs the PostEvent/Accessibility TCC permission ([forum 820594](https://developer.apple.com/forums/thread/820594), [forum 724603](https://developer.apple.com/forums/thread/724603)).
  - A Seatbelt profile that denies WindowServer mach-lookup blocks both clicks and screen capture.
  - Caveat (**unverified**): TCC charges child processes to their "responsible" app. If the user ever grants zigBrowser Accessibility, its agent children might inherit it. Don't grant it, or spawn the agent with responsibility disclaimed.
- **In-process broker**:
  - Page reads and DOM actions need a WKWebView adapter for each `PagePort` method, in the same slice as its live e2e (project rule). That is the WebKitGTK port code (`automation_gtk_port.zig`) redone for WK.
  - Run broker scripts in a **private `WKContentWorld`**, not `pageWorld`, so a page cannot see or spoof them. WKContentWorld exists from macOS 11 (**unverified**; Apple pages did not load).
  - The helper-to-app pipe is unchanged for Seatbelt. In a VM it becomes a vsock stream that the app bridges to the same broker.

## 5. Recommendation

### Which macOS backend to build first

- **Seatbelt first**, hardened beyond srt:
  - deny-default reads;
  - no `same-sandbox` task-port or process-info rights;
  - app-spawned hooks, each in its own sandbox;
  - a tiny mach-lookup list with no WindowServer and no mDNSResponder;
  - a profile file plus `-D` parameters;
  - a fixed `/usr/bin/sandbox-exec` path.
- Why first:
  - It runs the macOS user's real hooks.
  - It costs days, not months.
  - It matches what Anthropic and OpenAI ship.
- **VM second, as the fallback.** Use Virtualization.framework with a vsock-only guest running the Linux backend unchanged. Build it if the spike fails, or if Apple removes `sandbox-exec`.

### What a one-day spike on a real Mac must prove

1. The real Claude CLI and one Bun hook run under the profile, with `process-info*` (except self) and `mach-priv-task-port` denied.
2. From a hook, each of these fails:
   - `task_for_pid(cli)`;
   - `sysctl KERN_PROCARGS2` on the CLI's PID;
   - `proc_pidinfo`;
   - `lldb -p <cli>`.
3. Run `codesign -dv --entitlements -` on the CLI, and record whether it is hardened or has `get-task-allow`.
4. Nested `sandbox-exec` inside the sandbox fails, and an app-spawned hook gets its own separate sandbox.
5. Network: these work:
   - the proxy port;
   - `:51091`;
   - `:31337`.

   These fail:
   - `127.0.0.1:5432`;
   - `1.1.1.1:443`;
   - DNS lookups.
6. Writing to the workspace fails, and writing to the scratchpad works. Reading the real `~/.claude` fails.
7. The FIFO-to-socketpair fd-3 token handoff works with the macOS CLI. On macOS the CLI would reopen `/dev/fd/3`, not `/proc/self/fd/3` (**unverified**).
8. `kill -9` of the browser: every agent process is gone within 1 second, including a hook that double-forks and calls `setsid`. If that fails, measure the dedicated-user `kill(-1)` scheme.
9. `CGEventPost` and `screencapture` from a hook fail.

### Can one shared "sandbox backend" interface cover Linux bwrap, macOS and Windows WSL2?

**Yes.** Define it once:
- **Launch spec**:
  - the broker byte stream;
  - the token channel (FIFO then fd 3, never env);
  - the host proxy endpoint and allowlist (`api.anthropic.com`);
  - the bridge ports (51091, 31337);
  - shares: agent home `dist/current` read-only, workspace read-only, scratchpad read-write;
  - a hook-launch hook: how one hook gets its own sandbox;
  - a lifetime contract: everything dies with the browser.
- **Implementations**:
  - **Linux bwrap** (base built: bwrap, nested bwrap per hook, PID namespaces, seccomp, `--die-with-parent`; network hardening planned in plan rev 16, not built: private netns, allowlist proxy, Unix-socket bridges).
  - **macOS Seatbelt** (new): SBPL rules instead of netns, app-spawned hooks instead of nested bwrap, launcher cleanup instead of PID-namespace teardown.
  - **Linux-in-VM** (fallback): the Linux bwrap backend inside a guest, with vsock replacing Unix sockets. On macOS that means Virtualization.framework. On Windows, WSL2 is the same idea: the Linux backend inside the WSL distro, started through `wsl.exe`, with the broker on its stdio. WSL2 networking for the bridges is **unverified**.
- **Shared code**: the host-side allowlist proxy, the bridges, the broker and the approval logic are the same on every OS. Only "how to start a confined process" changes.

### What would change this recommendation

- **The spike shows a hook can still read the CLI's memory or args under Seatbelt:** go VM-first on macOS.
- **Apple kills custom `sandbox-exec` profiles in SDK 27 or later:** go VM-first on macOS.
- **No reliable orphan cleanup without a dedicated user, and the user won't accept a one-time admin step:** a VM is cleaner.
- **The macOS user's SAI is mostly Linux-portable Bun code with no darwin addons:** the VM's hook cost drops, and its stronger guarantees win.

## Unverified items

1. Whether XNU's `task_for_pid` blocks a same-uid, unentitled, non-root caller on a non-hardened target (macOS 14/15/26).
2. Whether the macOS Claude CLI is hardened or notarized.
3. Which SBPL operation gates `KERN_PROCARGS2`.
4. Whether Bun and Node run with `process-info*` denied.
5. The exact error text when nesting `sandbox-exec`.
6. Whether SDK 27's kill rule affects custom profiles.
7. Whether a Virtualization.framework VM ends with its app.
8. The Virtualization.framework version and Intel facts. Apple pages loaded title-only, so these are background knowledge.
9. Lima's license and CNCF status.
10. TCC responsibility inheritance.
11. The CLI's fd-3 reopen path on macOS.
12. WSL2 port bridging.
13. The 2026 macOS sandbox CVE numbers, which come from aggregators.
