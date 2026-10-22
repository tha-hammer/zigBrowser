"""WS7.4 [L] — RED-FIRST for the pure SAI copy rules on a FAKE filesystem (plan line 1668; RoseCat 9ec1600/dcddac3).

A link resolving OUTSIDE its item root is skipped with NO destination and NO target bytes, for BOTH symlinks AND
junctions. An INSIDE link/junction is followed under its own name. A link/junction that CYCLES back to an ancestor
is bounded and skipped. One portable copy-rule engine serves Linux and Windows.

The cycle cases run in a DISPOSABLE WORKER subprocess with a strict deadline and a guaranteed reap (RoseCat: the
cycle must be bounded, so a cycle-FOLLOWING engine would hang — which the worker catches as a timeout, not a hung
test). A committed cycle-follow mutant row runs an inline cycle-following copy and asserts it times out.

UNREGISTERED, signal-free, no VM, no Macs. Only agent/host/tests/ touched (not zb_agent_host/), so no ms5 inventory
change. RED now: `setup.copy_tree_fs` absent (AttributeError). The green refactors copy_sai onto this engine and
binds the real copy_sai path to it. Run with the agent-host env python (support imports claude_agent_sdk).
"""

import json
import os
import subprocess
import sys
import unittest

import support  # noqa: F401  (puts agent/host on sys.path)

from zb_agent_host import setup

HOST_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # agent/host
CANARY = b"SECRET-TARGET-BYTES-OUTSIDE-THE-ITEM"
REAL = b"REAL-IN-ITEM"
INNER = b"INNER-IN-ITEM"

# A fake filesystem node is ('dir', [names]) | ('file', bytes) | ('link', target) | ('junction', target).
ACYCLIC = {
    "/s": ("dir", ["real.txt", "sub", "alias", "injunc", "sym", "junc"]),
    "/s/real.txt": ("file", REAL),
    "/s/sub": ("dir", ["inner.txt"]),
    "/s/sub/inner.txt": ("file", INNER),
    "/s/alias": ("link", "/s/sub/inner.txt"),   # INSIDE -> followed under "alias"
    "/s/injunc": ("junction", "/s/sub"),         # INSIDE dir junction -> followed under "injunc"
    "/s/sym": ("link", "/outside/secret.txt"),   # OUTSIDE -> skipped (no dest)
    "/s/junc": ("junction", "/outside/dir"),     # OUTSIDE -> skipped (no dest)
    "/outside/secret.txt": ("file", CANARY),
    "/outside/dir": ("dir", ["leak.txt"]),
    "/outside/dir/leak.txt": ("file", CANARY),
}
# Adds a symlink AND a junction that both cycle back to the item root.
CYCLIC = dict(ACYCLIC)
CYCLIC["/s"] = ("dir", ["real.txt", "sub", "loop", "jloop"])
CYCLIC["/s/loop"] = ("link", "/s")
CYCLIC["/s/jloop"] = ("junction", "/s")


def _worker_env():
    env = {"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "PYTHONDONTWRITEBYTECODE": "1"}
    env["PYTHONPATH"] = os.pathsep.join([HOST_DIR, os.path.join(os.path.dirname(HOST_DIR), "tests", "e2e")])
    return env


def _run_worker(body: str, deadline_s: float):
    """Run `body` in a disposable subprocess; return its stdout, or None if it exceeded the deadline (killed+reaped)."""
    proc = subprocess.Popen([sys.executable, "-c", body], env=_worker_env(),
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    try:
        out, _ = proc.communicate(timeout=deadline_s)
        return out
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.communicate()  # guaranteed reap
        return None


class WindowsCopyRules(unittest.TestCase):
    def test_direct_copy_rules(self):
        copied = setup.copy_tree_fs(ACYCLIC, "/s")
        self.assertEqual(copied.get("s/real.txt"), REAL)
        self.assertEqual(copied.get("s/sub/inner.txt"), INNER)
        self.assertEqual(copied.get("s/alias"), INNER)            # inside symlink -> exact dest + value
        self.assertEqual(copied.get("s/injunc/inner.txt"), INNER)  # in-root junction -> followed
        self.assertNotIn("s/sym", copied)                         # outside symlink -> no dest
        self.assertNotIn("s/junc", copied)                        # outside junction -> no dest
        self.assertNotIn(CANARY, b"".join(copied.values()))


class CycleIsBounded(unittest.TestCase):
    def test_real_engine_bounds_the_cycles_within_the_deadline(self):
        body = (
            "import json\n"
            "from zb_agent_host import setup\n"
            f"fs = {CYCLIC!r}\n"
            "copied = setup.copy_tree_fs(fs, '/s')\n"
            "print(json.dumps(sorted(copied.keys())))\n"
        )
        out = _run_worker(body, deadline_s=10.0)
        self.assertIsNotNone(out, "copy_tree_fs did not terminate within the deadline on a cyclic filesystem")
        keys = json.loads(out)
        self.assertNotIn("s/loop", keys)   # symlink cycle skipped
        self.assertNotIn("s/jloop", keys)  # junction cycle skipped
        self.assertIn("s/real.txt", keys)  # the acyclic content still copied

    def test_a_cycle_following_copy_times_out_and_is_reaped(self):
        # Committed cycle-follow mutant: a copy that follows links/junctions WITHOUT a cycle bound recurses forever.
        body = (
            "import sys\n"
            "sys.setrecursionlimit(10_000_000)\n"
            f"fs = {CYCLIC!r}\n"
            "def walk(p):\n"
            "    k = fs[p][0]\n"
            "    if k == 'dir':\n"
            "        for n in fs[p][1]:\n"
            "            c = fs[p + '/' + n]\n"
            "            walk(c[1] if c[0] in ('link', 'junction') else p + '/' + n)\n"
            "walk('/s')\n"
        )
        out = _run_worker(body, deadline_s=3.0)
        self.assertIsNone(out, "a cycle-following copy must hang; the worker must catch the timeout")


if __name__ == "__main__":
    unittest.main()
