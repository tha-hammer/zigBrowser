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
import secrets
import shutil
import statistics
import stat
import subprocess
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import support  # noqa: E402  (puts tests/e2e and agent/host on sys.path)
from agent_hook_net import HookNetDecoys, hook_network_failures, install_probe, probe_command  # noqa: E402
from support import Homes, provision  # noqa: E402
from test_netd import Netd  # noqa: E402
from zb_agent_host import options, relay, sandbox, seccomp  # noqa: E402

UNSEALED = Path(__file__).with_name("hook_run_unsealed.py")
OUTER_RELAY = support.HOST_DIR / "zb_agent_host" / "relay.py"
CLI_ENV_PROXY = {"HTTPS_PROXY": "http://127.0.0.1:3128", "HTTP_PROXY": "http://127.0.0.1:3128",
                 "NO_PROXY": "127.0.0.1,localhost"}


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

    def outer(self, inside, timeout=120):
        """`inside` as the helper's command: the helper's bwrap, then the outer relay."""
        filter_fd = seccomp.seccomp_fd()
        self.tc.addCleanup(os.close, filter_fd)
        argv = sandbox.helper_argv(options.AgentHome(self.homes.agent), seccomp_fd=filter_fd,
                                   ro_paths=[str(support.HOST_DIR)], net_dir=str(self.netd.dir))
        argv += ["/usr/bin/python3", "-I", "-S", str(OUTER_RELAY), "--egress", "/run/zb-net/egress", "--", *inside]
        env = {"PATH": "/usr/bin:/bin", "HOME": str(self.homes.agent), "LANG": "C.UTF-8", **CLI_ENV_PROXY}
        return subprocess.run(argv, env=env, pass_fds=(filter_fd,), capture_output=True, text=True, timeout=timeout)

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
