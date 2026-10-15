"""S3n2 (chat-drawer plan rev 16.2, §3c.8b, D12): each hook gets its own sealed
network, checked from a real outer sandbox through the real zb-hook-run.

The chain is the one the browser builds: S3n1's real netd (bridges and the fake
API pointed at private decoys), then the helper's real bwrap
(sandbox.helper_argv with the netd directory) running the outer, proxy-only
relay, and inside it hook commands run as the CLI runs them:
`/bin/sh -c "<agent-home>/runtime/bin/zb-hook-run -- <hook>"`.

The whole module runs in a disposable network namespace that has only
loopback, so no code state (not even today's unsealed hooks) can reach a real
network; setUpModule fails closed anywhere else:

    cd agent/host/tests && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 \\
      ZB_AGENT_HOST_PYTHON="$py" /usr/bin/bwrap --unshare-net --die-with-parent --dev-bind / / \\
      --proc /proc -- "$py" -m unittest -v test_hook_net

The unsealed arm is hook_run_unsealed.py, a frozen copy of zb-hook-run before
S3n2. Manual red-at-seam for the green review (scratch export): mutant A, drop
the nested --unshare-net (test_a_sealed_hook... turns red: 3128 and the fake
API are reached); mutant B, bind the whole /run/zb-net into the hook (red: the
CONNECT over egress/proxy.sock reaches the fake API)."""

import json
import os
import pwd
import secrets
import shutil
import signal
import statistics
import stat
import subprocess
import sys
import threading
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import support  # noqa: E402  (puts tests/e2e and agent/host on sys.path)
from agent_hook_net import HookNetDecoys, hook_network_failures, install_probe, probe_command  # noqa: E402
from support import Homes, provision  # noqa: E402
from test_netd import Netd  # noqa: E402
from zb_agent_host import hook_run, options, relay, sandbox, seccomp, setup  # noqa: E402

UNSEALED = Path(__file__).with_name("hook_run_unsealed.py")
FILTER_PROBE = support.REPO / "tests" / "fixtures" / "agent" / "hook_filter_probe.py"
ORPHAN_HOOK = support.REPO / "tests" / "fixtures" / "agent" / "hook_orphan.py"
BUN = Path(pwd.getpwuid(os.getuid()).pw_dir) / ".bun" / "bin" / "bun"
OUTER_RELAY = support.HOST_DIR / "zb_agent_host" / "relay.py"
CLI_ENV_PROXY = {"HTTPS_PROXY": "http://127.0.0.1:3128", "HTTP_PROXY": "http://127.0.0.1:3128",
                 "NO_PROXY": "127.0.0.1,localhost"}

# Connects to each given port from inside the hook and writes {port: open|refused}
# to argv[1]: a bound bridge accepts, an unbound one is refused.
PORTS_PROBE = r"""
import json, os, socket, sys
def talk(port):
    try:
        socket.create_connection(("127.0.0.1", port), timeout=3).close()
        return "open"
    except OSError:
        return "refused"
json.dump({p: talk(int(p)) for p in sys.argv[2:]}, open(sys.argv[1], "w"))
"""


def private_netns():
    """True when this process's network namespace has loopback and nothing else."""
    with open("/proc/self/net/dev") as f:
        names = [line.split(":", 1)[0].strip() for line in f.readlines()[2:]]
    return names == ["lo"]


def setUpModule():
    # Fails closed instead of skipping: a skipped gate step would pass unverified.
    if not private_netns():
        raise RuntimeError("run under `bwrap --unshare-net --dev-bind / / --proc /proc` (see the module docstring)")


class Chain:
    """netd, then the real outer sandbox, as the browser starts them."""

    def __init__(self, tc):
        self.tc = tc
        self.homes = Homes()
        tc.addCleanup(self.homes.cleanup)
        self.decoys = HookNetDecoys()
        tc.addCleanup(self.decoys.close)
        self.hooks = self.homes.agent / ".claude" / "hooks"
        self.probe = install_probe(self.hooks)
        rc, out = provision(self.homes)
        tc.assertEqual(rc, 0, out)
        self.bin = self.homes.agent / "runtime" / "bin"
        shutil.copyfile(UNSEALED, self.bin / "zb-hook-run-unsealed")
        os.chmod(self.bin / "zb-hook-run-unsealed", 0o700)
        self.netd = Netd(tc, *self.decoys.netd_test_args())
        tc.assertTrue(self.netd.ready(), self.netd.err)

    def runner(self, sealed=True):
        return f"{self.bin / ('zb-hook-run' if sealed else 'zb-hook-run-unsealed')} --"

    def outer_argv(self, inside, ro_paths=()):
        """(argv, filter fd): the helper's bwrap, then the outer relay, running `inside`."""
        filter_fd = seccomp.seccomp_fd()
        self.tc.addCleanup(os.close, filter_fd)
        argv = sandbox.helper_argv(options.AgentHome(self.homes.agent), seccomp_fd=filter_fd,
                                   ro_paths=[str(support.HOST_DIR), *ro_paths], net_dir=str(self.netd.dir))
        argv += ["/usr/bin/python3", "-I", "-S", str(OUTER_RELAY), "--egress", "/run/zb-net/egress", "--", *inside]
        return argv, filter_fd

    def env(self):
        return {"PATH": "/usr/bin:/bin", "HOME": str(self.homes.agent), "LANG": "C.UTF-8", **CLI_ENV_PROXY}

    def outer(self, inside, timeout=120, ro_paths=()):
        """`inside` as the helper's command: the helper's bwrap, then the outer relay."""
        argv, filter_fd = self.outer_argv(inside, ro_paths)
        return subprocess.run(argv, env=self.env(), pass_fds=(filter_fd,), capture_output=True, text=True,
                              timeout=timeout)

    def outer_popen(self, inside, browser=False, **pipes):
        """outer(), started and left running (binary pipes). `browser`: under a stand-in
        browser process, as the app starts it (the outer bwrap dies with its parent)."""
        argv, filter_fd = self.outer_argv(inside)
        if browser:
            argv = ["/usr/bin/python3", "-I", "-c", "import subprocess, sys; "
                    "sys.exit(subprocess.run(sys.argv[1:], close_fds=False).returncode)", *argv]
        pipes.setdefault("stdout", subprocess.DEVNULL)
        pipes.setdefault("stderr", subprocess.PIPE)
        proc = subprocess.Popen(argv, env=self.env(), pass_fds=(filter_fd,), **pipes)
        self.tc.addCleanup(lambda: proc.poll() is None and (proc.kill(), proc.wait()))
        for stream in (proc.stdin, proc.stdout, proc.stderr):
            if stream is not None:
                self.tc.addCleanup(stream.close)
        return proc

    def processes(self):
        """{pid: (argv, ppid)} of every process whose argv names this chain's agent home."""
        found = {}
        for pid in (int(p) for p in os.listdir("/proc") if p.isdigit()):
            try:
                argv = Path(f"/proc/{pid}/cmdline").read_bytes().decode(errors="replace").split("\0")[:-1]
                ppid = int(Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[1])
            except (OSError, IndexError, ValueError):
                continue
            if any(str(self.homes.agent) in a for a in argv):
                found[pid] = (argv, ppid)
        return found

    def relay_pid(self):
        """The hook's inner relay: /usr/bin/python3 -I -S <home>/runtime/bin/zb-net-relay --bridges ..."""
        relays = [pid for pid, (argv, _) in self.processes().items()
                  if argv[:3] == ["/usr/bin/python3", "-I", "-S"] and len(argv) > 4
                  and argv[3] == str(self.bin / "zb-net-relay") and argv[4] == "--bridges"]
        self.tc.assertEqual(len(relays), 1, self.processes())
        return relays[0]

    def nested_bwrap_pid(self):
        """The hook's bwrap (the process zb-hook-run became), not its PID-1 child."""
        procs = self.processes()
        nested = [pid for pid, (argv, _) in procs.items()
                  if argv[:1] == ["/usr/bin/bwrap"] and str(self.bin / "zb-net-relay") in argv]
        top = [pid for pid in nested if procs[pid][1] not in nested]
        self.tc.assertEqual(len(top), 1, procs)
        return top[0]

    def run_probe(self, sealed=True):
        """Runs the probe as one hook; returns (its result, the outer view's netns)."""
        out = self.homes.scratchpad / f"net-{secrets.token_hex(6)}.json"
        hook, _nonce = probe_command(self.probe, out)
        done = self.outer(["/bin/sh", "-c", f"readlink /proc/self/ns/net; {self.runner(sealed)} {hook}"])
        self.tc.assertEqual(done.returncode, 0, done.stderr)
        self.tc.assertTrue(out.exists(), done.stderr)
        return json.loads(out.read_text()), done.stdout.splitlines()[0]


class HookNetworkTest(unittest.TestCase):
    """§3c.8b reach, offline-safe (RoseCat 5492 B3)."""

    def test_provisioning_installs_the_inner_relay_beside_zb_hook_run(self):
        chain = Chain(self)
        installed = chain.bin / "zb-net-relay"
        self.assertTrue(installed.is_file(), "runtime/bin/zb-net-relay is missing")
        self.assertEqual(installed.read_bytes(), Path(relay.BRIDGE_RELAY_FILE).read_bytes(),
                         "one source of truth: the relay.py bridge mode")
        self.assertEqual(stat.S_IMODE(installed.stat().st_mode), 0o555)

    def test_a_sealed_hook_reaches_both_bridges_and_nothing_else(self):
        chain = Chain(self)
        result, outer_netns = chain.run_probe()
        self.assertEqual(hook_network_failures(result, chain.decoys), [])
        self.assertNotEqual(result["netns"], outer_netns, "the hook has its own network namespace")

    def test_the_checks_catch_an_unsealed_hook(self):
        """Not vacuous: the pre-S3n2 zb-hook-run, in the same outer sandbox,
        reaches 3128 and makes the fake API count rise (mutant A's shape)."""
        chain = Chain(self)
        result, outer_netns = chain.run_probe(sealed=False)
        failures = hook_network_failures(result, chain.decoys)
        self.assertEqual(result["netns"], outer_netns)
        self.assertTrue(any("3128" in f for f in failures), failures)
        self.assertTrue(any("fake API" in f for f in failures), failures)

    def test_the_backends_net_json_ports_reach_the_hooks_inner_relay(self):
        """MS0 slice E consumer half (RoseCat 5775): the real chain net.json -> zb-hook-run
        -> inner relay. The producer half (setup.net_manifest writes the backend's bridge
        ports) is closed in Slice D, and the Chain's lighter provision-runtime omits
        net.json, so the real producer writes it here; a reduced port set then proves the
        consumer: the real zb-hook-run reads net.json's ports and passes `--ports`, so the
        hook's own relay binds exactly those. One named bridge drops the other end to end;
        a runner that ignored net.json's ports would bind the fixed pair (:31337 open)."""
        chain = Chain(self)
        net = chain.homes.agent / "runtime" / "net.json"
        manifest = setup.net_manifest()  # the real producer's content (its ports half, Slice D)
        self.assertEqual(sorted(manifest["ports"]), sorted(sandbox.hook_network().ports))
        manifest["ports"] = [51091]  # the backend now supplies a single bridge
        net.write_text(json.dumps(manifest))
        probe = chain.hooks / "ports_probe.py"
        probe.write_text(PORTS_PROBE)
        out = chain.homes.scratchpad / f"ports-{secrets.token_hex(6)}.json"
        done = chain.outer(["/bin/sh", "-c", f"{chain.runner()} /usr/bin/python3 -I -S {probe} {out} 51091 31337"])
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(json.loads(out.read_text()), {"51091": "open", "31337": "refused"},
                         "only the port net.json names is bound in the hook")


class HookFilterTest(unittest.TestCase):
    """§3c.6: each hook runs under its own stricter seccomp filter, installed by
    the nested bwrap, after zb-hook-run has closed every inherited descriptor."""

    def probe(self, chain, pre="", shell="/bin/sh"):
        out = chain.homes.scratchpad / f"filter-{secrets.token_hex(6)}.json"
        probe = chain.hooks / FILTER_PROBE.name
        shutil.copyfile(FILTER_PROBE, probe)
        done = chain.outer([shell, "-c", f"{pre}{chain.runner()} /usr/bin/python3 -I -S {probe} {out}"])
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertTrue(out.exists(), done.stderr)
        return json.loads(out.read_text())

    def test_namespaces_mounts_and_io_uring_are_denied_to_a_hook(self):
        record = self.probe(Chain(self))
        for call in ("unshare_newuser", "setns", "mount", "io_uring_setup", "clone_newuser"):
            self.assertEqual(record[call], {"ok": False, "errno": "EPERM"}, call)
        self.assertEqual(record["clone3"], {"ok": False, "errno": "ENOSYS"}, "glibc must fall back to clone")

    def test_fork_subprocess_and_threads_still_work_in_a_hook(self):
        record = self.probe(Chain(self))
        self.assertEqual((record["fork"], record["subprocess"], record["thread"]), (True, True, True))

    def test_no_process_a_hook_can_see_holds_its_callers_descriptors(self):
        """The token guarantee and its census: a file the CLI leaves open (at 3, like
        the token's, and at 12, past the filter's) is held by no process in the
        hook's PID namespace (bwrap's PID 1 included), the hook holds only 0, 1
        and 2, and the filter's own descriptor is gone."""
        chain = Chain(self)
        canary = chain.homes.scratchpad / f"token-canary-{secrets.token_hex(4)}"
        canary.write_text("canary\n")
        record = self.probe(chain, pre=f"exec 3<{canary} 12<{canary}; ", shell="/usr/bin/bash")
        self.assertEqual(record["fds_above_2"], [])
        unreadable = [link for link in record["fd_links"] if link[1] is None]
        self.assertEqual(unreadable, [], "the census must read every visible process's descriptors")
        self.assertIn(1, {pid for pid, _fd, _target in record["fd_links"]}, "bwrap's PID 1 was censused")
        held = [link for link in record["fd_links"] if "token-canary" in link[2] or "zb-hook-seccomp" in link[2]]
        self.assertEqual(held, [])

    def test_while_a_hook_runs_only_its_caller_holds_the_callers_descriptors(self):
        """§3c.6 step 2, censused from the host while the hook runs: zb-hook-run closes
        every inherited descriptor before it execs bwrap, so of the processes it
        starts (the nested bwrap and its monitor, the relay, the hook) none holds
        the file the CLI left open at 3 and at 12. Only the calling shell does."""
        chain = Chain(self)
        canary = chain.homes.scratchpad / f"token-canary-{secrets.token_hex(4)}"
        canary.write_text("canary\n")
        ready, go = chain.homes.scratchpad / "hook-ready", chain.homes.scratchpad / "hook-go"
        hook = f"/bin/sh -c 'touch {ready}; while [ ! -e {go} ]; do sleep 0.02; done'"
        # `; exit $?` keeps bash as the caller (it would otherwise exec its last command).
        proc = chain.outer_popen(["/usr/bin/bash", "-c", f"exec 3<{canary} 12<{canary}; {chain.runner()} {hook}; exit $?"])
        deadline = time.monotonic() + 30
        while not ready.exists() and proc.poll() is None and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(ready.exists(), "the hook never started")
        # By identity, not path: from the host, a sandboxed descriptor's link names
        # the file relative to the sandbox's own mounts.
        identity = (canary.stat().st_dev, canary.stat().st_ino)
        holders = {}
        for pid in (p for p in os.listdir("/proc") if p.isdigit()):
            try:
                for fd in os.listdir(f"/proc/{pid}/fd"):
                    st = os.stat(f"/proc/{pid}/fd/{fd}")
                    if (st.st_dev, st.st_ino) == identity:
                        comm = Path(f"/proc/{pid}/comm").read_text().strip()
                        holders.setdefault(comm, set()).add(int(fd))
            except OSError:
                continue
        go.touch()
        self.assertEqual(proc.wait(timeout=30), 0, proc.stderr.read())
        self.assertEqual(holders, {"bash": {3, 12}})

    def test_bwrap_receives_only_the_hook_filter_from_zb_hook_run(self):
        """§3c.6 steps 2-4 at zb-hook-run's exec boundary. bwrap 0.12 keeps no
        inherited descriptor in its own processes and the relay closes them first
        thing, so only here is zb-hook-run's own close-all observable: a copy whose
        BWRAP is a recorder must hand over exactly one descriptor >= 3, the memfd
        named by --seccomp, at >= 10, holding hook_filter()."""
        homes = Homes()
        self.addCleanup(homes.cleanup)
        runtime = homes.agent / "runtime"
        (runtime / "hook-env.json").write_text(json.dumps(["PATH"]))
        record = homes.scratchpad / "bwrap-received.json"
        recorder = homes.scratchpad / "bwrap-recorder"
        recorder.write_text("#!/usr/bin/python3 -I\n"
                            "import json, os, sys\n"
                            "fds = []\n"
                            "for fd in range(3, 1024):\n"
                            "    try: os.fstat(fd)\n"
                            "    except OSError: continue\n"
                            "    fds.append(fd)\n"
                            "seccomp = int(sys.argv[sys.argv.index('--seccomp') + 1]) if '--seccomp' in sys.argv else None\n"
                            "data = os.pread(seccomp, 65536, 0).hex() if seccomp in fds else None\n"
                            "links = {fd: os.readlink(f'/proc/self/fd/{fd}') for fd in fds}\n"
                            f"json.dump({{'fds': fds, 'links': links, 'seccomp': seccomp, 'data': data}}, open({str(record)!r}, 'w'))\n")
        os.chmod(recorder, 0o700)
        source = Path(hook_run.__file__).read_text()
        self.assertEqual(source.count('BWRAP = "/usr/bin/bwrap"\n'), 1)
        copy = runtime / "bin" / "zb-hook-run"
        copy.write_text(source.replace('BWRAP = "/usr/bin/bwrap"\n', f"BWRAP = {str(recorder)!r}\n"))
        canary = homes.scratchpad / "token-canary"
        canary.write_text("canary\n")
        done = subprocess.run(["/usr/bin/bash", "-c", f"exec 3<{canary} 12<{canary}; /usr/bin/python3 -I {copy} -- /bin/true"],
                              env={"PATH": "/usr/bin:/bin"}, capture_output=True, text=True, timeout=30)
        self.assertEqual(done.returncode, 0, done.stderr)
        got = json.loads(record.read_text())
        self.assertEqual(got["fds"], [got["seccomp"]], got["links"])
        self.assertGreaterEqual(got["seccomp"], 10)
        self.assertTrue(got["links"][str(got["seccomp"])].startswith("/memfd:zb-hook-seccomp"), got["links"])
        self.assertEqual(bytes.fromhex(got["data"]), hook_run.hook_filter())

    def test_a_real_bun_hook_still_spawns_a_subprocess(self):
        self.assertTrue(BUN.is_file(), f"{BUN} is needed: the SAI hooks are Bun")
        chain = Chain(self)
        script = ("const r = Bun.spawnSync(['/usr/bin/sh', '-c', 'echo spawned-by-bun']);"
                  "console.log(r.stdout.toString().trim(), r.exitCode); process.exit(r.exitCode)")
        done = chain.outer(["/bin/sh", "-c", f"{chain.runner()} {BUN} -e \"{script}\""],
                           ro_paths=[str(BUN.parent.parent)])
        self.assertEqual((done.returncode, done.stdout.split()[-2:]), (0, ["spawned-by-bun", "0"]), done.stderr)


def wait_for(predicate, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.01)
    return predicate()


def canary_processes(canary):
    found = []
    for pid in (p for p in os.listdir("/proc") if p.isdigit()):
        try:
            if canary.encode() in Path(f"/proc/{pid}/cmdline").read_bytes():
                found.append(int(pid))
        except OSError:
            continue
    return found


def sh(script):
    """`script` as one /bin/sh -c word for a hook command line."""
    return "/bin/sh -c '" + script.replace("'", "'\\''") + "'"


class HookLifecycleTest(unittest.TestCase):
    """§3c.8b: a sealed hook behaves like an unsealed one to its caller (status,
    stdio, signals), leaves nothing behind, and its relay holds only its own."""

    def test_exit_status_is_the_same_sealed_and_unsealed(self):
        chain = Chain(self)
        hooks = {"exit 0": sh("exit 0"), "exit 2": sh("exit 2"), "exit 7": sh("exit 7"),
                 "self-SIGTERM": sh("kill -TERM $$"), "missing command": "/nonexistent/zb-hook-command"}
        got = {sealed: {name: chain.outer(["/bin/sh", "-c", f"{chain.runner(sealed)} {hook}"]).returncode
                        for name, hook in hooks.items()} for sealed in (True, False)}
        self.assertEqual(got[True], got[False])
        self.assertEqual((got[True]["exit 2"], got[True]["self-SIGTERM"]), (2, 143), "2 is the CLI's 'block'")

    def test_stdio_passes_1_mib_both_ways_and_eof_follows_the_hooks_exit(self):
        chain = Chain(self)
        stamp = chain.homes.scratchpad / "hook-exit-stamp"
        hook = sh(f"cat; echo hook-stderr >&2; /usr/bin/python3 -I -S -c "
                  f"'import time; print(time.monotonic())' > {stamp}")
        data = os.urandom(1 << 20)
        proc = chain.outer_popen(["/bin/sh", "-c", f"{chain.runner()} {hook}"],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        writer = threading.Thread(target=lambda: (proc.stdin.write(data), proc.stdin.close()))
        writer.start()
        out = b""
        while chunk := proc.stdout.read1(1 << 16):
            out += chunk
        eof = time.monotonic()
        writer.join()
        self.assertEqual(proc.wait(timeout=30), 0)
        self.assertEqual(out, data, "1 MiB byte for byte")
        self.assertIn(b"hook-stderr", proc.stderr.read())
        self.assertLess(eof - float(stamp.read_text()), 0.1, "EOF on stdout within 100 ms of the hook's exit")

    def test_sigterm_to_the_relay_runs_the_hooks_trap_and_returns_its_code(self):
        chain = Chain(self)
        started, marker = chain.homes.scratchpad / "trap-started", chain.homes.scratchpad / "trap-ran"
        hook = sh(f"trap 'touch {marker}; exit 5' TERM; touch {started}; while :; do sleep 0.05; done")
        proc = chain.outer_popen(["/bin/sh", "-c", f"{chain.runner()} {hook}"])
        self.assertTrue(wait_for(started.exists, 30), "the hook never started")
        os.kill(chain.relay_pid(), signal.SIGTERM)
        self.assertEqual(proc.wait(timeout=30), 5, "the relay exits with the hook's code")
        self.assertTrue(marker.exists(), "the hook's TERM trap ran")

    def test_the_relay_holds_only_its_listeners_pidfd_epoll_and_stdio(self):
        chain = Chain(self)
        started = chain.homes.scratchpad / "fd-started"
        chain.outer_popen(["/bin/sh", "-c", f"{chain.runner()} " + sh(f"touch {started}; while :; do sleep 0.05; done")])
        self.assertTrue(wait_for(started.exists, 30), "the hook never started")
        relay = chain.relay_pid()
        links = {int(fd): os.readlink(f"/proc/{relay}/fd/{fd}") for fd in os.listdir(f"/proc/{relay}/fd")}
        self.assertEqual((links.pop(0), links.pop(1)), ("/dev/null", "/dev/null"), "never the CLI's stdin or stdout")
        links.pop(2)
        kinds = sorted("socket" if t.startswith("socket:") else t for t in links.values())
        self.assertEqual(kinds, ["anon_inode:[eventpoll]", "anon_inode:[pidfd]", "socket", "socket"], links)

    def orphan_case(self, mode, kill):
        """A hook whose double-forked, setsid grandchild holds a bridge connection, while
        the caller (like the CLI) outlives the hook. After `kill`, within 1 s, no process
        carries the canary and the bridge's decoy has seen the connection end."""
        chain = Chain(self)
        canary = f"zb-orphan-canary-{secrets.token_hex(8)}"
        ready, returned = chain.homes.scratchpad / "orphan-ready", chain.homes.scratchpad / "runner-returned"
        hook = chain.hooks / ORPHAN_HOOK.name
        shutil.copyfile(ORPHAN_HOOK, hook)
        # From a file: only the hook's processes may carry the canary, not the caller's.
        caller = chain.homes.scratchpad / "orphan-caller.sh"
        caller.write_text(f"{chain.runner()} /usr/bin/python3 -I -S {hook} {canary} {ready} {mode}\n"
                          f"touch {returned}\nwhile :; do sleep 0.05; done\n")
        proc = chain.outer_popen(["/bin/sh", str(caller)], browser=(kill == "browser"))
        self.assertTrue(wait_for(ready.exists, 30), "the grandchild never connected")
        if mode == "wait":  # an exiting hook may already be gone, grandchild and all
            self.assertTrue(canary_processes(canary), "the canary was never visible")
        if kill == "browser":
            os.kill(proc.pid, signal.SIGKILL)
        else:
            kill(chain)
        sent = f"orphan-{canary}".encode()
        self.assertTrue(wait_for(lambda: not canary_processes(canary), 1.0),
                        f"survivors: {[Path(f'/proc/{p}/cmdline').read_bytes() for p in canary_processes(canary)]}")
        self.assertTrue(wait_for(lambda: sent in chain.decoys.bridges[51091].received, 1.0), "the decoy saw no EOF")
        if mode == "exit":
            self.assertTrue(wait_for(returned.exists, 1.0), "zb-hook-run returned when the hook exited")

    def test_no_orphan_when_the_hook_exits(self):
        self.orphan_case("exit", lambda chain: None)

    def test_no_orphan_when_the_relay_is_killed(self):
        self.orphan_case("wait", lambda chain: os.kill(chain.relay_pid(), signal.SIGKILL))

    def test_no_orphan_when_the_nested_bwrap_gets_sigterm(self):
        self.orphan_case("wait", lambda chain: os.kill(chain.nested_bwrap_pid(), signal.SIGTERM))

    def test_no_orphan_when_the_browser_is_killed(self):
        self.orphan_case("wait", "browser")


DRIVER = r"""
import json, os, subprocess, sys, time
sealed, unsealed, hook, n, warm = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5])
def once(prefix):
    started = time.perf_counter()
    rc = subprocess.run(["/bin/sh", "-c", f"{prefix} {hook}"]).returncode
    return (time.perf_counter() - started) * 1000, rc
for _ in range(warm):
    once(sealed), once(unsealed)
out = {"sealed": [], "unsealed": [], "rc": []}
for i in range(n):
    arms = [("sealed", sealed), ("unsealed", unsealed)]
    for name, prefix in (arms if i % 2 == 0 else arms[::-1]):
        ms, rc = once(prefix)
        out[name].append(ms)
        out["rc"].append(rc)
ns = lambda prefix: subprocess.run(["/bin/sh", "-c", f"{prefix} /usr/bin/readlink /proc/self/ns/net"],
                                   capture_output=True, text=True).stdout.strip()
out["netns"] = {"outer": os.readlink("/proc/self/ns/net"), "sealed": ns(sealed), "unsealed": ns(unsealed)}
print(json.dumps(out))
"""

SAMPLES, WARMUP = 40, 5


def nearest_rank(values, pct):
    ordered = sorted(values)
    return ordered[max(0, -(-len(ordered) * pct // 100) - 1)]


def summary(values):
    return {"n": len(values), "median": round(statistics.median(values), 1),
            "p90": round(nearest_rank(values, 90), 1), "p95": round(nearest_rank(values, 95), 1)}


class HookCostTest(unittest.TestCase):
    """§3c.8b cost (RoseCat 5492 B4): paired, warmed runs of the same no-op hook
    with and without the inner netns and relay. It reports; no budget is set
    before the data. It fails only when the measurement itself is invalid."""

    def test_paired_cost_of_the_sealed_hook_is_measured_and_reported(self):
        chain = Chain(self)
        driver = chain.hooks / "cost_driver.py"
        driver.write_text(DRIVER)
        done = chain.outer(["/usr/bin/python3", "-I", str(driver), chain.runner(True), chain.runner(False),
                            "/bin/true", str(SAMPLES), str(WARMUP)], timeout=600)
        self.assertEqual(done.returncode, 0, done.stderr)
        data = json.loads(done.stdout.splitlines()[-1])
        self.assertEqual(set(data["rc"]), {0}, "every sample's hook ran")
        self.assertNotEqual(data["netns"]["sealed"], data["netns"]["outer"], "the sealed arm was really sealed")
        self.assertEqual(data["netns"]["unsealed"], data["netns"]["outer"])
        deltas = [s - u for s, u in zip(data["sealed"], data["unsealed"])]
        report = {"sealed_ms": summary(data["sealed"]), "unsealed_ms": summary(data["unsealed"]),
                  "paired_delta_ms": summary(deltas), "warmup_per_arm": WARMUP}
        print(f"\nS3n2 hook cost: {json.dumps(report)}", file=sys.stderr)
        for arm in ("sealed_ms", "unsealed_ms", "paired_delta_ms"):
            self.assertGreaterEqual(report[arm]["n"], 30)


if __name__ == "__main__":
    unittest.main()
