---
date: 2026-10-14
topic: Red team of three sandbox options for the zigBrowser Claude agent drawer
method: RedTeam skill, ParallelAnalysis workflow (24 claims, 32 personas run as 4 squads of 8), plus 3 web-research agents and read-only checks on this host
status: research (committed 86ddf01); the user decided on it 2026-10-14 (bwrap with its own netns, proxy, two bridges); plan rev 16 pending
---

# Agent sandbox red team: VM vs container vs OS-native

## Terms used

- **Token**: the Claude login secret. That is a claude.ai OAuth token or a long-lived `claude setup-token` token.
- **CLI**: the bundled Claude Code binary (2.1.294) that the Python helper starts.
- **Hook**: one of the user's 41 SAI hook programs (all Bun/TypeScript). The CLI runs them as its children.
- **Outer wall**: what separates the whole agent from the user's real machine.
- **Inner wall**: what separates a hook from the CLI that holds the token.
- **netns**: a Linux network namespace. Without its own netns, a sandbox shares the host's loopback (127.0.0.1) and the host's *abstract* Unix sockets.
- **Abstract Unix socket**: a socket with a name like `@/tmp/.X11-unix/X0`. It has no file on disk, so mount sandboxes cannot hide it. Only a separate netns can.
- **Option 3**: the current design. bwrap, a nested PID namespace per hook, and seccomp.

## How this was done

- The RedTeam skill's ParallelAnalysis workflow was followed. The decision was split into 24 claims (8 per option). Thirty-two personas attacked them, run as 4 squads of 8: engineers, architects, pentesters and interns. Then came synthesis, a steelman and a counter-argument.
- Three web-research agents checked facts from primary sources.
- I ran read-only checks on this machine: `ss -ltn`, `ss -lx`, `id`, `ls -l /dev/kvm`, `ps` and the LSM list. I did not touch the display, any socket, or any secret.
- Not done:
  - The skill's execution-log append was skipped, because this task allowed only one file write.
  - The FirstPrinciples sub-skill is not installed. I did the decomposition by hand.

## The question

The strict "no foreign absolute paths in copied text" rule refuses the user's real SAI. That raised a question: would a VM or a container be a better boundary than the mostly built bwrap design? For each option, we asked:
- Can it keep the token from hooks?
- Can it run the user's hooks?
- Can it keep approvals honest?
- Can it limit files and network?
- Can it run on Linux now and on macOS and Windows later?
- What does switching cost?

## Short answer

1. **Keep Option 3 on Linux.** A VM or container does not fix the problem that matters most. In every option the CLI must hold the token, and the hooks run as the CLI's children inside the same wall. A VM moves the *outer* wall. You would still need the nested PID namespace, or separate users, *inside* the guest.
2. **Option 3 has one real, large hole: it shares the host network.** From inside the sandbox, the agent and every hook can reach:
   - about 40 localhost services on this host, including Postgres on `0.0.0.0:5432`, MySQL `:3307` and Ollama `:11434`;
   - the X server's abstract socket for DISPLAY :0, and a second one for :106;
   - the session-manager (ICE) socket;
   - the whole internet.

   Fix it the way Anthropic's own sandbox-runtime and OpenAI's Codex do. Use `--unshare-net`, a host-side proxy reached over a bound-in Unix socket, and named port bridges for `:51091` and `:31337` only. That is the main finding of this red team. All four squads reached it on their own.
3. **The path rule should become option (a).** Inside Option 3's mount namespace, foreign host paths already do not exist; only `/usr`, a few `/etc` files and the agent home are mounted. So the text scan was hygiene, not the boundary. Check strictly only what executes: `settings.json`, the hook commands, and **each hook's whole import tree**. A VM makes (a) feel simpler, but Option 3 already gives the same "path does not exist" result.
4. **Cross-platform later:**
   - **macOS:** Seatbelt, using sandbox-runtime's pattern. Open spike: can Seatbelt stop a hook from reading the CLI's memory?
   - **Windows:** run the Linux design inside WSL2 rather than AppContainer.
   - **VMs:** a micro-VM (libkrun or microsandbox) is a later, optional backend behind one interface. It is not a rewrite now.
5. **Containers are the weakest fit.**
   - Docker's group is root-equivalent, and this user is in it.
   - Neither Docker nor Podman ties the container's life to the browser.
   - Default container seccomp profiles allow `ptrace`.
   - On macOS and Windows a container is a VM anyway.

## Facts from this host (local checks, 2026-10-14)

- The user is in groups `docker` (986) and `kvm` (993). `/dev/kvm` exists, and the CPU has `svm` (AMD-V).
- Not installed: `podman`, `runsc`, `krunvm`, `firecracker`, `cloud-hypervisor`, `virtiofsd`. Installed: `docker`, `qemu-system-x86_64`, `bwrap` 0.12.0 and `socat`.
- The active LSMs include `landlock` and `apparmor`. Unprivileged user namespaces are on. `ptrace_scope` is 0.
- Listening on loopback: about 40 TCP ports, including 51090, 11434 (Ollama), 3307, 8765, 8787 and 631 (CUPS). Port 5432 (Postgres) and 4000 listen on `0.0.0.0`.
- Abstract sockets: `@/tmp/.X11-unix/X0`, `@/tmp/.X11-unix/X106`, `@/tmp/.ICE-unix/3415` and a CUDA `uvmfd` socket.
- Xorg runs as `Xorg :0 -auth <file> -nolisten tcp` under LightDM with gnome-shell. So connecting to :0 needs the cookie, **unless** host-based access (for example `xhost +si:localuser`) is turned on. **Unverified**: I did not query :0, as instructed. Display :106 is likely a test Xvfb. Whether it requires auth is **unverified**.
- Hook network use found by grep: `localhost:51091`, `localhost:31337`, `api.anthropic.com` and `api.cloudflare.com`. Some hooks use `KITTY_LISTEN_ON`. Some read `CLOUDFLARE_*` and `ANTHROPIC_ADMIN_API_KEY` env names. The hook env allowlist strips those today, so those hooks already degrade.

## Comparison table

Ratings run from best to worst: ✔ good, ~ partial, ✖ poor. "As built" means Option 3 today. "Hardened" means Option 3 plus a separate netns and a proxy.

| Area | 1. Micro-VM | 2. Container (rootless Podman) | 3. OS-native, as built | 3. OS-native, hardened |
|---|---|---|---|---|
| Outer wall strength | ✔ separate guest kernel | ~ shared kernel, same primitives as bwrap | ~ shared kernel | ~ shared kernel |
| Token vs hooks (inner wall) | ~ still needs nested PID ns or separate uid in the guest; you can set the guest's `ptrace_scope` | ~ default seccomp allows `ptrace`; needs nested PID ns (blocked by default profile) or a second uid | ✔ nested PID ns per hook; seccomp blocks `ptrace`/`process_vm_*` | ✔ same |
| Host localhost and abstract sockets | ✔ unreachable by default (microsandbox); TSI behavior **unverified** | ✔ pasta does not map host loopback by default | ✖ all reachable | ✔ only bridged ports |
| Egress allowlist | needs a proxy | needs a proxy (pasta has no domain filter) | ✖ none | ✔ srt-style hostname allowlist |
| Hooks compatibility | ✖ needs its own Bun/Node/addons; host ports need forwarding; kitty breaks | ~ image pins Bun/Node; addons rebuilt; ports via `pasta -T` | ✔ host Bun bound read-only | ~ same; non-proxy egress fails closed |
| Approval integrity | ✔ app decides; no X11 path | ✔ if no host network | ~ app decides; X11 path is a risk if :0 allows local user (**unverified**) | ✔ |
| No orphans | ✔ VMM is a direct child | ✖ conmon owns the container; no die-with-parent | ✔ `--die-with-parent` + PID ns | ✔ |
| Linux | ✔ KVM (`/dev/kvm` ACL) | ✔ | ✔ (Ubuntu 24.04 needs AppArmor profile) | ✔ |
| macOS | ~ Virtualization.framework (entitlement), libkrun only on Apple Silicon | ✖ needs a VM (Podman Machine / Docker Desktop) | ~ Seatbelt (deprecated CLI) | ~ srt pattern |
| Windows | ~ WHP via microsandbox (beta); Hyper-V not on Home | ✖ needs WSL2/Hyper-V VM | ✖ AppContainer unproven for Bun | ~ WSL2 or srt "alpha" |
| Ship size | 150–300 MB image (estimate, **unverified**) | ~50–80 MB base image + SAI | none | none |
| Switch cost from today | ✖ high | ✖ high | none | ✔ low to medium |

## Red team per option

### Option 1: small VM

**Attacks (what breaks or leaks)**

1. **The VM does not protect the token from hooks.**
   - The CLI and its hooks run in the same guest.
   - Without a nested PID namespace or a separate uid in the guest, a hook reads `/proc/<cli>/mem` there. That works exactly as it would on the host with `ptrace_scope=0`.
   - The VM only adds value here because you can set the guest's own `kernel.yama.ptrace_scope` to 2 or 3, and run hooks as a second uid. That is real, but it is a second build of the same inner wall.
2. **libkrun says its VMM is not a strong wall.**
   - Its README says "both the guest and the VMM pertain to the same security context", and that you should treat them "as a single entity".
   - It also says virtio-fs gives "no protection against the guest attempting to access other directories in the same filesystem".
   - So you must still wrap the VMM in namespaces, which means bwrap again. ([libkrun README](https://github.com/containers/libkrun))
3. **The file-sharing daemon is a new escape surface.**
   - CVE-2020-35517 let a privileged guest create device nodes in a virtiofsd share and reach host devices. ([Red Hat](https://access.redhat.com/security/cve/CVE-2020-35517))
   - A 2026 Kata report describes guest root creating host symlinks through virtiofsd run with `--sandbox none`. ([oss-sec 2026/q2/650](https://seclists.org/oss-sec/2026/q2/650))
   - QEMU 9p had a link-following escape, CVE-2016-9602. ([CVE](https://vulnerability.cert.dk/vuln/cve-2016-9602))
   - virtiofsd is only safe in its default namespace sandbox. ([virtiofsd README](https://gitlab.com/virtio-fs/virtiofsd/-/raw/main/README.md))
4. **Network defaults vary, and some are open.**
   - libkrun's TSI proxies guest sockets through the VMM, and "you should apply to the VMM any restrictions you want on the guest". ([libkrun README](https://raw.githubusercontent.com/containers/libkrun/main/README.md))
   - One report says TSI bypassed guest nftables rules. ([Fedora Magazine](https://fedoramagazine.org/sandbox-ai-coding-agents-with-microvms-on-fedora-linux/))
   - Whether a TSI guest reaches host 127.0.0.1 is **unverified**.
   - microsandbox blocks loopback and private ranges by default, but allows the public internet. ([microsandbox networking](https://docs.microsandbox.dev/networking/overview.md))
5. **The hooks do not port.**
   - The user's hooks are host programs that use the host's `~/.bun/bin`, host native addons, kitty's socket, and host ports 51091 and 31337.
   - A guest needs its own Bun and Node, rebuilt addons, and port forwards.
   - On macOS the user's darwin `node_modules` cannot run in a Linux guest at all.
   - The kitty hooks break in any VM.
6. **Platform gaps.**
   - Firecracker has no virtio-fs, and its maintainers rejected 9p for security reasons. ([issue 1180](https://github.com/firecracker-microvm/firecracker/issues/1180))
   - Firecracker runs on Linux only. ([FAQ](https://raw.githubusercontent.com/firecracker-microvm/firecracker/main/FAQ.md))
   - libkrun on macOS needs Apple Silicon (HVF on ARM64).
   - Apple's own `container` tool needs Apple Silicon and macOS 26. ([apple/container](https://raw.githubusercontent.com/apple/container/main/README.md))
   - Virtualization.framework needs the `com.apple.security.virtualization` entitlement, and macOS 12 or newer for virtio-fs. ([entitlement](https://developer.apple.com/tutorials/data/documentation/bundleresources/entitlements/com.apple.security.virtualization.json), [virtio-fs](https://developer.apple.com/tutorials/data/documentation/virtualization/vzvirtiofilesystemdeviceconfiguration.json))
   - Hyper-V cannot be installed on Windows Home. ([Microsoft](https://learn.microsoft.com/en-us/virtualization/hyper-v-on-windows/quick-start/enable-hyper-v))
   - `/dev/kvm` is usually missing inside VMs and some CI hosts (**unverified**).
7. **Operations cost.**
   - You ship and patch a guest kernel and distro forever.
   - The Fedora write-up needed 4 GB RAM and 4 CPUs for Claude Code in a krun micro-VM. ([Fedora Magazine](https://fedoramagazine.org/sandbox-ai-coding-agents-with-microvms-on-fedora-linux/))
   - One libkrun vendor saw virtio-fs `readdir` OOM-kill callers on guests under 1 GB. ([iii.dev](https://iii.dev/blog/why-agent-sandboxes-are-converging-on-libkrun-not-firecracker/))
   - Guest cache staleness after the host broker writes the workspace is **unverified**.
8. **Maturity.**
   - microsandbox calls itself "beta software", though it is active (v0.7.8, 2026-10-09). ([microsandbox](https://github.com/microsandbox/microsandbox))
   - libkrun is Apache-2.0 with roughly monthly releases, and its `main` branch is an unstable 2.0. ([releases](https://api.github.com/repos/containers/libkrun/releases?per_page=8))

**Steelman (the best case for the VM)**

1. A separate guest kernel removes the whole host syscall surface from hostile code's reach.
2. By default the guest cannot see host loopback, host abstract sockets, X11 or the host `/proc`.
3. Inside the guest you own the kernel settings: set `ptrace_scope=3` without touching the user's host.
4. Guest root can run hooks as a different uid than the CLI, which single-uid bwrap cannot do.
5. One Linux guest image could run the same agent on Linux, macOS and Windows.
6. Docker Sandboxes already ship this way, with a host proxy injecting credentials. ([Docker Sandboxes architecture](https://docs.docker.com/ai/sandboxes/architecture/))
7. microsandbox already maps a host Unix socket or Windows named pipe to guest vsock, which fits the broker pipe. ([host sockets](https://docs.microsandbox.dev/networking/host-sockets.md))
8. If the agent later runs third-party skills from strangers, a VM is the right wall.

**Verdict:** a strong outer wall that answers the wrong question for today's threat, and the most expensive switch.

### Option 2: containers (Docker, rootless Podman, gVisor)

**Attacks**

1. **Docker on this host is root.**
   - Docker's docs say "the `docker` group grants root-level privileges to the user". ([Docker post-install](https://docs.docker.com/engine/install/linux-postinstall/))
   - The user is in that group, and a desktop app that talks to the Docker daemon holds root-equivalent power.
   - Docker Desktop also needs a paid plan for organizations over 250 employees or $10M revenue. ([license](https://docs.docker.com/subscription/desktop-license/))
2. **Containers do not die with the browser.**
   - Podman's conmon owns the container, not the client. A Podman thread reports containers surviving the client's death, even with Pdeathsig. ([podman list](https://lists.podman.io/archives/list/podman@lists.podman.io/thread/J2WMAQYXXJ2CSQOPLMUOZUF3EWZCYG4R))
   - `--rm` only cleans up after the container exits. ([podman-run](https://docs.podman.io/en/latest/markdown/podman-run.1.html))
   - So you need a watchdog. That breaks the plan's proven "no orphans" chain.
3. **Default seccomp profiles allow ptrace.**
   - Docker's default profile allows `ptrace` and `process_vm_readv` on kernels 4.8 and newer. ([moby default.json](https://raw.githubusercontent.com/moby/profiles/main/seccomp/default.json))
   - Podman's profile allows `ptrace` unconditionally. ([containers/common seccomp.json](https://raw.githubusercontent.com/containers/common/main/pkg/seccomp/seccomp.json))
   - Inside one container, hooks and the CLI share a PID namespace and a uid. So the token is open unless you add the same nested PID namespace, which default profiles block, or a second uid.
4. **Shared-kernel escapes repeat.**
   - runc CVE-2019-5736 (overwrite host runc through `/proc/self/exe`). ([Ubuntu](https://discourse.ubuntu.com/t/runc/55877))
   - CVE-2024-21626, "Leaky Vessels", leaked file descriptors. ([GHSA-xr7r-f8xq-vfvv](https://github.com/opencontainers/runc/security/advisories/GHSA-xr7r-f8xq-vfvv))
   - Three November 2025 race and symlink bugs:
     - CVE-2025-31133 ([GHSA-9493-h29p-rfm2](https://github.com/opencontainers/runc/security/advisories/GHSA-9493-h29p-rfm2))
     - CVE-2025-52565 ([GHSA-qw9x-cqr3-wc7r](https://github.com/opencontainers/runc/security/advisories/GHSA-qw9x-cqr3-wc7r))
     - CVE-2025-52881 ([GHSA-cgrx-mc8f-2prm](https://github.com/opencontainers/runc/security/advisories/GHSA-cgrx-mc8f-2prm))
   - crun has its own advisories. ([crun advisories](https://github.com/containers/crun/security/advisories))
   - Rootless mode and user namespaces blunt most of these, but that is the same protection bwrap already has.
5. **gVisor does not fit a rootless desktop.**
   - Rootless `runsc` is "mainly only suitable for `runsc do`" and must use the host network. The docs then advise unsharing the netns "to protect abstract UNIX sockets on the host". ([gVisor rootless](https://gvisor.dev/docs/user_guide/rootless/))
   - It is Linux only. ([FAQ](https://gvisor.dev/docs/user_guide/faq/))
   - `io_uring_register` is not implemented, and inotify only sees events inside the sandbox. ([syscall table](https://gvisor.dev/docs/user_guide/compatibility/linux/amd64/))
   - Bun under gVisor is **unverified**.
6. **Egress is not domain-aware.**
   - pasta does not map host loopback by default. Its maintainer calls doing so "a bad default for security". ([passt-user](https://archives.passt.top/passt-user/20251222235109.23703ffe@elisabeth/))
   - You can forward one port (`pasta:-T,51091`; syntax only partly verified, [pasta(1)](https://passt.top/passt/tree/passt.1)). But limiting traffic to `api.anthropic.com` still needs a proxy.
7. **Anthropic's own devcontainer says it does not protect credentials.** With skipped permissions, it does "not prevent a malicious project from exfiltrating anything accessible inside the container, including the Claude Code credentials". Its firewall runs inside the container, so code with NET_ADMIN could undo it. ([devcontainer docs](https://code.claude.com/docs/en/devcontainer), [init-firewall.sh](https://raw.githubusercontent.com/anthropics/claude-code/main/.devcontainer/init-firewall.sh))
8. **Cross-platform is a VM anyway.**
   - Podman Machine uses libkrun or applehv on macOS, and WSL or Hyper-V on Windows. ([podman-machine](https://docs.podman.io/en/latest/markdown/podman-machine.1.html))
   - Docker Desktop uses Apple Virtualization on macOS and WSL2 on Windows. ([Mac FAQ](https://docs.docker.com/desktop/troubleshoot-and-support/faqs/macfaqs/), [Windows](https://docs.docker.com/desktop/setup/install/windows-install/))

**Steelman**

1. Rootless Podman is audited, standard plumbing. It means less hand-written sandbox code than 15 plan revisions of bwrap argv.
2. pasta's defaults already do what Option 3 lacks: no host loopback, and a separate netns.
3. An image pins Bun and Node versions, which removes distro drift between users.
4. With subuid ranges, a container can run hooks as a different uid than the CLI.
5. Debian 13 ships Podman 5.4.2 with pasta. ([Debian](https://packages.debian.org/trixie/podman))
6. Base images are small: `oven/bun:slim` is about 74 MB compressed. ([Docker Hub](https://hub.docker.com/v2/repositories/oven/bun/tags/slim))

**Verdict:** gives nothing on Linux that a hardened bwrap lacks, breaks the orphan guarantee, and on macOS and Windows it is a VM with more layers.

### Option 3: OS-native (bwrap now; Seatbelt and Windows later)

**Attacks**

1. **The shared network namespace (biggest hole, found by all four squads).**
   - Abstract sockets "belong to the network namespace instead of the mount namespace", so mount sandboxes "cannot restrict access to abstract sockets". ([GLib MR 3005](https://gitlab.gnome.org/GNOME/glib/-/merge_requests/3005))
   - From inside today's sandbox and every hook, the agent can reach:
     - the X server sockets for :0 and :106;
     - the ICE socket;
     - about 40 localhost services, including Postgres and Ollama;
     - the internet.
   - **Approval forgery path:** a hook connects to X :0 and uses XTEST to click the GTK approval card, or reads keystrokes.
     - This works only if the X server allows the local user without the cookie. That is **unverified** here.
     - It also applies to any WebKit inspector or debug port the browser might open on localhost (**unverified**).
   - **Exfiltration path:** a prompt-injected agent uses a hook to send page or workspace data anywhere.
2. **The kernel attack surface stays open.**
   - The outer seccomp filter allows `unshare`, `clone3`, `mount`, `setns` and `pivot_root` for every process, because the nested hook bwrap needs them.
   - So a hook can create new user and network namespaces, and reach kernel code that unprivileged users cannot normally reach. The nf_tables privilege-escalation class is the classic example.
   - Anthropic's sandbox-runtime denies exactly these calls after setup. ([sandbox-runtime](https://github.com/anthropic-experimental/sandbox-runtime))
3. **Non-hook CLI children in the outer namespace.**
   - Seccomp blocks the `ptrace` and `process_vm_*` calls, but not `open("/proc/<cli>/mem")`.
   - Under `ptrace_scope=0`, any same-uid process in the outer PID namespace that is not a hook could read the CLI's memory. Examples are `rg`, or a compromised Python dependency of the helper.
   - The plan's exec census limits who these processes are. It does not stop them reading.
4. **Persistence inside writable state.** The manifest hash is checked at session start. A hook could write a file into a writable state directory (`MEMORY/` and others) that a later hook imports. Provisioning refuses imports into those directories, but files written during the session are not re-checked.
5. **Distro variance.**
   - Ubuntu 24.04 turns on `kernel.apparmor_restrict_unprivileged_userns` by default. An app without an AppArmor profile that grants `userns` cannot use bwrap. ([Ubuntu](https://discourse.ubuntu.com/t/understanding-apparmor-user-namespace-restriction/58007))
   - Debian 13 does not restrict this by default (**unverified**).
   - A Flatpak build of zigBrowser could not nest bwrap.
6. **bwrap history.**
   - CVE-2017-5226 (TIOCSTI) is fixed by `--new-session`, which the plan already uses. ([NVD](https://nvd.nist.gov/vuln/detail/CVE-2017-5226))
   - CVE-2026-41163 affects only setuid bwrap 0.11.0–0.11.1. ([oss-sec](https://seclists.org/oss-sec/2026/q2/215))
   - Debian's bwrap is not setuid. So bwrap itself is low risk; the kernel underneath is the risk.
7. **macOS parity is unproven.**
   - The `sandbox-exec` CLI is marked deprecated. My sources for that are secondary, and the man page was not read (**unverified**). Chromium still uses the underlying Seatbelt API. ([Chromium design](https://chromium.googlesource.com/chromium/src/+/main/sandbox/mac/seatbelt_sandbox_design.md))
   - sandbox-runtime's profile limits process-info, signals and task ports to "same-sandbox" targets. ([macos-sandbox-utils.ts](https://raw.githubusercontent.com/anthropic-experimental/sandbox-runtime/main/src/sandbox/macos-sandbox-utils.ts))
   - But hooks and the CLI would be in the **same** sandbox. Whether a nested, stricter profile per hook can stop a hook reading the CLI's task port is **unverified**. This is the macOS version of the inner-wall problem.
8. **Windows parity is unproven.**
   - AppContainer needs ACL grants on every toolchain path. Running Node or Bun in it is undocumented (**unverified**). ([AppContainer](https://learn.microsoft.com/en-us/windows/win32/secauthz/appcontainer-isolation))
   - Both precedents avoid AppContainer:
     - sandbox-runtime's Windows mode (alpha) uses a dedicated local user, a Windows Filtering Platform rule and NTFS ACLs, and needs a one-time elevated install.
     - Codex uses sandbox users with firewall rules, or a restricted token (**partly verified**). ([Codex sandboxing](https://learn.chatgpt.com/docs/sandboxing))
   - Claude Code itself runs commands unsandboxed on native Windows. ([Claude Code sandboxing](https://code.claude.com/docs/en/sandboxing))
9. **Reusing Anthropic's tools is only partial.**
   - Claude Code's `/sandbox` covers **shell commands only**: "hooks run outside it". So it cannot sandbox the user's hooks. ([Claude Code sandboxing](https://code.claude.com/docs/en/sandboxing))
   - sandbox-runtime (`srt`) is "Beta Research Preview" and Apache-2.0. Its Linux seccomp **refuses nested user and mount namespaces** and **blocks new AF_UNIX sockets**. As shipped, it would break `zb-hook-run`'s nested bwrap. ([sandbox-runtime](https://github.com/anthropic-experimental/sandbox-runtime))
   - So reuse its **network design and proxy**, not its process wrapper.
   - Claude Code's own sandbox has had bypass advisories. All were writes to files the unsandboxed parent later trusted (settings, symlinks, worktree paths). Examples: CVE-2026-25725, CVE-2026-39861, CVE-2026-55607. ([advisories](https://github.com/anthropics/claude-code/security/advisories))
   - The same pattern applies to our helper reading the scratchpad.

**Steelman**

1. It is built, it has been through 15 review rounds, and it has real-binary tests for the token, the PID namespaces and the death chain.
2. The nested PID namespace per hook really does stop `/proc/<cli>/mem`, `ptrace` and `kill` under `ptrace_scope=0`. The kernel resolves PIDs per namespace.
3. The file design is strong: `openat2(RESOLVE_BENEATH|NO_SYMLINKS|NO_XDEV)`, an app-owned write broker, an immutable home, and an atomic swap.
4. `--die-with-parent` plus PID-namespace teardown gives a no-orphans guarantee that containers cannot match.
5. The industry converged here:
   - OpenAI Codex's Linux sandbox now defaults to bubblewrap, plus `--unshare-net` and a TCP→Unix-socket→TCP proxy bridge. ([Codex linux-sandbox](https://github.com/openai/codex/blob/main/codex-rs/linux-sandbox/README.md))
   - Anthropic's own runtime is bwrap plus a proxy on Linux, and Seatbelt on macOS.
6. Inside its mount namespace, foreign host paths already do not exist, so the strict text scan was never the boundary.
7. Kernel 6.12 has Landlock ABI 6, which can scope abstract Unix sockets and signals. That is extra defense with no new dependency. ([landlock(7)](https://man7.org/linux/man-pages/man7/landlock.7.html), [kernel docs](https://docs.kernel.org/userspace-api/landlock.html))
8. Every hole found is closable with small, reversible additions, not a rewrite.

**Verdict:** the right base. "As built" is not shippable until the network is separated.

## Cross-cutting finding: take the token out of the sandbox (load-bearing unknown)

- Every option leaves the token in the CLI's memory, next to the hooks. The strongest single move would put it **outside** every wall:
  1. Run a host-side proxy that adds the real `Authorization` header.
  2. Give the CLI a placeholder token, and point it at `ANTHROPIC_BASE_URL` over the bridged socket.
- What is documented:
  - Claude Code supports `ANTHROPIC_BASE_URL` and honors `HTTPS_PROXY`. ([LLM gateway](https://code.claude.com/docs/en/llm-gateway), [network config](https://code.claude.com/docs/en/network-config))
  - With only a base URL set, "a saved claude.ai login remains the active credential". The gateway must forward the OAuth `anthropic-beta` value. ([gateway protocol](https://code.claude.com/docs/en/llm-gateway-protocol))
  - So **passthrough** of an OAuth token is documented. **Swapping a placeholder for the real token is not documented. It is unverified.** It may also raise usage-policy questions (**unverified**).
- Precedents:
  - Docker Sandboxes inject credentials from a host proxy so "real keys never enter the VM". ([Docker Sandboxes](https://docs.docker.com/ai/sandboxes/architecture/))
  - Claude Code's sandbox has `credentials.mask`, but for Bash children only. ([sandboxing](https://code.claude.com/docs/en/sandboxing))
  - sandbox-runtime has an experimental `tlsTerminate` for credential injection.
- If a spike shows it works, the token threat drops out in every option. Most of the FIFO-to-socketpair machinery then becomes defense in depth. Keep the nested PID namespace anyway, for other secrets and for hook-to-hook isolation.

## How each option changes the SAI copy-path question

| | (a) copy all, strict on executed paths | (b) instruction files only | (c) keep strict rule |
|---|---|---|---|
| VM | Simplest: host paths cannot resolve in the guest at all | Possible, but most hooks and skills lose their code | Pointless |
| Container | Same as VM | Same as VM | Pointless |
| OS-native | **Equally safe**: the mount namespace already hides foreign paths; only `/usr`, a few `/etc` files, `/proc` and the agent home exist | Safe, but loses skills' code | Fails on the real SAI (11,929 of 82,561 files) |

**Recommendation: (a) in every option.**
- Define "executed" as `settings.json`, each hook command, and **the hook script's whole import graph**, including the `node_modules` files it actually imports.
- Rewrite the source HOME everywhere.
- Report other absolute paths as warnings, not refusals.
- Add a check during the session for new files in the writable state directories (attack 4 above).

## Cost to switch from today

- **To hardened Option 3: low to medium.**
  - Add `--unshare-net`, a host proxy (reuse sandbox-runtime's design or its code), and `socat` bridges for `:51091` and `:31337`; `socat` is already a dependency.
  - Add a stricter seccomp filter applied inside each hook after the nested bwrap is set up: deny namespace creation, `mount`, `setns` and `io_uring`, and return ENOSYS for `clone3`.
  - Optionally add Landlock ABI 6 scoping.
  - Switch the path rule to (a).
  - Most P0 and S3a tests stay. The D12 bind list and the network tests change.
- **To containers: high.** New image pipeline, new lifecycle watchdog (the death chain is re-proven from scratch), custom seccomp profile, Podman dependency. On macOS and Windows a VM is still needed.
- **To a VM: highest.** Guest kernel and image builds and patching, a vsock broker transport, guest init, a guest copy of the hook runner, port forwards, a virtiofs daemon sandbox, and per-OS hypervisor code and signing. Almost all D7, D11 and D12 tests are redone.

## Recommendation

### (1) Now, on Linux

Keep Option 3, but treat the network as a **release blocker for S3**:
1. **`--unshare-net` on the outer bwrap.** Egress goes only through a host-side HTTP(S) proxy bound in as a Unix socket. It allows `api.anthropic.com` by hostname, plus any CLI domains the census proves are needed, and drops private and loopback addresses. This is sandbox-runtime's and Codex's pattern.
2. **Named localhost bridges only:** `127.0.0.1:51091` (voice) and `:31337`. Kitty and Cloudflare hooks stay off in the drawer, or the user approves each one by name.
3. **A stricter seccomp filter inside each hook,** applied after the nested bwrap is set up: no new namespaces, no `mount`/`setns`, no `io_uring`, and `clone3` returns ENOSYS. The outer filter stays as it is.
4. **Path rule (a)**, with "executed" meaning the transitive import graph.
5. **A spike on the token-outside-the-sandbox proxy** (placeholder token, header swap at the host proxy). If it works and is allowed, adopt it.
6. **Tests to add:**
   - From inside the sandbox, connecting to `@/tmp/.X11-unix/X0`, `:5432` and `:11434` fails.
   - `:51091` succeeds.
   - A host outside the allowlist fails.
   - A hook's `unshare(CLONE_NEWUSER)` fails.

### (2) The cross-platform future

- Define a **sandbox backend interface** now: one broker byte stream, one egress-proxy endpoint, a share list (workspace read-only, scratchpad read-write) and a port-forward list. bwrap, Seatbelt, WSL2 or a micro-VM can each implement it.
- **macOS:** Seatbelt, following sandbox-runtime's profile and proxy. First spike whether a nested per-hook profile can deny the hook access to the CLI's task port and memory. If it cannot, use a micro-VM backend on macOS (Virtualization.framework, or libkrun/microsandbox on Apple Silicon). Also accept that hooks would then need Linux builds.
- **Windows:** run the Linux backend inside WSL2, as Claude Code and Codex do. Do not build an AppContainer backend for Bun hooks unless a spike proves it works. microsandbox's Windows support (WHP) is the VM fallback once it leaves beta.
- **Never Docker-based**, and do not use containers as the cross-platform answer.

### What would change this recommendation

- **The token proxy works:** the outer-wall choice then matters only for host reach. Option 3 becomes even more clearly right.
- **The drawer runs untrusted third-party skills or code from strangers,** or a user-namespace kernel escape appears that seccomp cannot close: move to a micro-VM backend on Linux too.
- **Seatbelt cannot separate hooks from the CLI:** use a VM on macOS.
- **Many users are on Ubuntu 24.04+ and the AppArmor profile cannot be shipped:** consider a VM there.
- **The user drops "full SAI in the drawer" for a small drawer profile:** a VM becomes much cheaper, with a small image and no host hooks, and its value goes up.
- **A test shows X :0 accepts local-user connections without the cookie:** this does not change the choice, but it makes item (1).1 urgent.

## RedTeam verdict (8-point counter-argument to "switch to a VM or container")

**The position:** a VM or container would be a better boundary than the current bwrap design.

1. The token's real enemy sits inside the wall: hooks are the CLI's children in every option.
2. A VM moves the outer wall, but you still rebuild the nested PID namespace inside the guest.
3. libkrun itself says its guest and VMM share one security context, so you wrap it in namespaces anyway.
4. The actual hole is the shared network, and `--unshare-net` plus a proxy closes it today.
5. Codex and Anthropic's own runtime chose bwrap plus a proxy on Linux, not VMs, for local agents.
6. Containers lose the no-orphans guarantee, and Docker's group already makes this user root-equivalent.
7. A guest cannot run the user's host Bun hooks, darwin addons, kitty socket or host ports unchanged.
8. Switching costs months to fix a path-scan rule that the mount namespace already makes unnecessary.

**Assessment:** the wish for a VM comes from a real concern, host reach. But the concern is a missing netns, not the wrong wall. Harden Option 3, and keep a VM as a pluggable backend for later.

## Squad convergence (how many squads independently agreed)

- 4 of 4: the shared netns is the biggest hole; add `--unshare-net`, a proxy and named bridges.
- 4 of 4: a VM or container does not separate hooks from the CLI.
- 4 of 4: adopt path rule (a).
- 4 of 4: a token-outside proxy is the highest-leverage idea, and the OAuth placeholder swap is unverified.
- 3 of 4: narrow seccomp after setup (engineers, pentesters, architects).
- 3 of 4: Windows goes through WSL2, not AppContainer.
- 2 of 4: run a smaller "drawer profile" instead of the full SAI (interns, pentesters).

## Unverified items to check

1. Whether X :0 and :106 accept connections from this uid without a cookie. Do this without touching :0 from automation; the user should run the probe.
2. Whether a placeholder OAuth token with a header-swapping proxy works with the CLI, and whether it is allowed.
3. Whether libkrun's TSI reaches host 127.0.0.1.
4. Whether Bun and Node hooks honor `HTTP_PROXY`/`HTTPS_PROXY`. Those that do not will fail closed.
5. Whether a nested Seatbelt profile can deny a hook the CLI's task port.
6. Whether AppContainer can run Bun, and whether it can reach a loopback proxy.
7. Whether Debian 13 restricts unprivileged user namespaces by default.
8. The man page wording that marks `sandbox-exec` as deprecated.
9. Guest cache staleness on virtiofs after host writes.
10. Several CVE identifiers seen only in search snippets were left out on purpose.
