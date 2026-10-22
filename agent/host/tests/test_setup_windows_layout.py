"""WS7.4 [L] — RED-FIRST for the pure SAI copy rules on a FAKE filesystem (plan line 1668; RoseCat 9ec1600 →
dcddac3 → a70e73b SAFETY).

A link resolving OUTSIDE its item root is skipped with NO destination and NO target bytes, for BOTH symlinks AND
junctions. An INSIDE link/junction is followed under its own name. A link/junction that CYCLES back to an ancestor
is bounded and skipped.

SAFETY (RoseCat a70e73b): the cycle cases spawn and KILL a worker, so they run ONLY inside a kernel-proven private
PID namespace (pidns_guard, below the launcher's held outer ns via ZB_OUTER_PIDNS_FD) — the kill is then
namespace-local and cannot hit a reused host PID; they SKIP anywhere else. The cycle-follow mutant is a BOUNDED
NON-ALLOCATING follower (a fixed-memory infinite loop, no recursion, no recursionlimit bump), so it cannot exhaust
host memory; the worker's deadline + kill bounds it. The exit/kill/reap race is explicit.

The direct (acyclic) rules are a pure in-memory call — no process, safe anywhere.

UNREGISTERED, signal-free on the host (skips outside the ns). Only agent/host/tests/ touched (not zb_agent_host/),
so no ms5 inventory change. RED now: `setup.copy_tree_fs` absent (AttributeError). Run through the reviewed
launcher: `sh -c 'exec 9</proc/self/ns/pid; exec unshare --user --map-root-user --pid --fork --mount-proc …
ZB_OUTER_PIDNS_FD=9 python -m unittest test_setup_windows_layout'` with the agent-host env python.
"""

import json
import os
import signal
import subprocess
import sys
import time
import unittest

import pidns_guard
import support  # noqa: F401  (puts agent/host on sys.path)

from zb_agent_host import setup

HOST_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # agent/host
CANARY = b"SECRET-TARGET-BYTES-OUTSIDE-THE-ITEM"
REAL = b"REAL-IN-ITEM"
INNER = b"INNER-IN-ITEM"

ACYCLIC = {
    "/s": ("dir", ["real.txt", "sub", "alias", "injunc", "sym", "junc"]),
    "/s/real.txt": ("file", REAL),
    "/s/sub": ("dir", ["inner.txt"]),
    "/s/sub/inner.txt": ("file", INNER),
    "/s/alias": ("link", "/s/sub/inner.txt"),
    "/s/injunc": ("junction", "/s/sub"),
    "/s/sym": ("link", "/outside/secret.txt"),
    "/s/junc": ("junction", "/outside/dir"),
    "/outside/secret.txt": ("file", CANARY),
    "/outside/dir": ("dir", ["leak.txt"]),
    "/outside/dir/leak.txt": ("file", CANARY),
}
CYCLIC = dict(ACYCLIC)
CYCLIC["/s"] = ("dir", ["real.txt", "sub", "loop", "jloop"])
CYCLIC["/s/loop"] = ("link", "/s")
CYCLIC["/s/jloop"] = ("junction", "/s")


def _worker_env():
    env = {"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "PYTHONDONTWRITEBYTECODE": "1"}
    env["PYTHONPATH"] = os.pathsep.join([HOST_DIR, os.path.join(os.path.dirname(HOST_DIR), "tests", "e2e")])
    return env


# The committed cycle-follow mutant: a BOUNDED NON-ALLOCATING follower (fixed memory, no recursion) that follows the
# symlink cycle forever. A correct cycle-bounding engine must not do this; it cannot exhaust memory.
MUTANT_BODY = (
    "fs = %r\n"
    "p = '/s/loop'\n"
    "while True:\n"
    "    p = fs[p][1] + '/loop'  # loop -> /s -> /s/loop -> ...  (a 2-node cycle, no allocation)\n"
) % (CYCLIC,)


def _run_worker(body, deadline_s):
    """Run `body` in a disposable in-namespace subprocess; return (stdout-or-None, terminal_returncode). On the
    deadline the worker is killed and reaped: kill tolerates ProcessLookupError (child already exited) and the reap
    is bounded. A reap that ITSELF times out is a HARD failure (raises) — never swallowed. The terminal return code
    is always non-None after a reap. Kills are safe because the caller proved a private PID namespace first."""
    proc = subprocess.Popen([sys.executable, "-c", body], env=_worker_env(),
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    try:
        out, _ = proc.communicate(timeout=deadline_s)
        return out, proc.returncode
    except subprocess.TimeoutExpired:
        try:
            proc.kill()  # namespace-local pid (pidns_guard proved); not a reusable host pid
        except ProcessLookupError:
            pass  # the child exited between the timeout and the kill — already gone
        try:
            proc.communicate(timeout=5)  # guaranteed, bounded reap
        except subprocess.TimeoutExpired as exc:
            raise AssertionError("worker could not be reaped within 5s after kill") from exc  # HARD, never swallowed
        return None, proc.returncode


class WindowsCopyRules(unittest.TestCase):
    def test_direct_copy_rules(self):  # pure, in-memory: no process, safe anywhere
        copied = setup.copy_tree_fs(ACYCLIC, "/s")
        self.assertEqual(copied.get("s/real.txt"), REAL)
        self.assertEqual(copied.get("s/sub/inner.txt"), INNER)
        self.assertEqual(copied.get("s/alias"), INNER)
        self.assertEqual(copied.get("s/injunc/inner.txt"), INNER)
        self.assertNotIn("s/sym", copied)
        self.assertNotIn("s/junc", copied)
        self.assertNotIn(CANARY, b"".join(copied.values()))


class CycleIsBounded(unittest.TestCase):
    def setUp(self):
        ok, why = pidns_guard.private_pid_namespace()
        if not ok:
            self.skipTest("spawns + kills a worker: %s" % why)  # safe only in a proven private PID namespace

    def test_real_engine_bounds_the_cycles_within_the_deadline(self):
        body = (
            "import json\n"
            "from zb_agent_host import setup\n"
            f"fs = {CYCLIC!r}\n"
            "print(json.dumps(sorted(setup.copy_tree_fs(fs, '/s').keys())))\n"
        )
        out, rc = _run_worker(body, deadline_s=10.0)
        self.assertIsNotNone(out, "copy_tree_fs did not terminate within the deadline on a cyclic filesystem")
        self.assertEqual(0, rc)  # a clean exit, not a kill
        keys = json.loads(out)
        self.assertNotIn("s/loop", keys)
        self.assertNotIn("s/jloop", keys)
        self.assertIn("s/real.txt", keys)

    def test_a_cycle_following_copy_times_out_and_is_reaped(self):
        out, rc = _run_worker(MUTANT_BODY, deadline_s=3.0)
        self.assertIsNone(out, "a cycle-following copy must hang; the worker must catch the timeout")
        self.assertIsNotNone(rc, "the killed worker must be reaped (a terminal return code)")
        self.assertEqual(-signal.SIGKILL, rc)  # reaped after SIGKILL, not left running

    def test_no_reap_leaves_no_terminal_code(self):
        # Committed no-reap mutant: a harness that kills but does NOT reap leaves proc.returncode None (no terminal
        # code) -- which would red the SIGKILL assertion above. Prove the distinction, then reap for cleanup.
        proc = subprocess.Popen([sys.executable, "-c", MUTANT_BODY], env=_worker_env(),
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(0.3)  # let it spin
        proc.kill()
        self.assertIsNone(proc.returncode, "without a reap there is no terminal return code (the no-reap mutant)")
        proc.wait()  # the real harness reaps -> a terminal code appears
        self.assertEqual(-signal.SIGKILL, proc.returncode)


if __name__ == "__main__":
    unittest.main()
