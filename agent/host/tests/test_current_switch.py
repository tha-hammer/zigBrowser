"""WS7.1 [L] — RED-FIRST for the atomic, privilege-free `current` switch (plan line 1657).

The agent home is `dist-<n>\\…` with a `current` pointer swapped atomically and without privilege. DECISION: a
`current.json` POINTER FILE replaced by write-temp-then-rename (`os.rename` / Windows `MoveFileExW`
`MOVEFILE_REPLACE_EXISTING`) — a single atomic replace, so a concurrent reader always sees the old or the new
pointer, never a missing one. (A directory-junction swap would need an extra create+replace of a reparse point; the
pointer file is the simplest op the red can prove atomic.)

Portable [L] test: a writer thread swaps `current` in a loop while a reader polls 1000 times; the reader must never
see `current` missing/unreadable. A committed delete-then-create mutant row runs a non-atomic swap (unlink, a
window, then write) and asserts the reader DOES catch the missing window — so the test detects non-atomicity.

UNREGISTERED, signal-free, no VM, no Macs. Only agent/host/tests/ touched (not zb_agent_host/), so no ms5 inventory
change. RED now: `setup.point_current` / `setup.read_current` absent (AttributeError). Run with the agent-host env
python (support imports claude_agent_sdk). The green adds the atomic pointer helpers.
"""

import json
import os
import tempfile
import threading
import time
import unittest

import support  # noqa: F401  (puts agent/host on sys.path)

from zb_agent_host import setup


def _reader_writer(home, swap, read, polls=1000):
    """A writer thread swaps `current` in a loop via `swap(home, dist)`; a reader polls `read(home)` `polls` times
    and counts how often `current` was missing/unreadable. Returns the miss count. The writer stops when the reader
    finishes and is joined (guaranteed)."""
    stop = threading.Event()
    misses = [0]

    def writer():
        n = 0
        while not stop.is_set():
            n += 1
            os.makedirs(os.path.join(home, "dist-%d" % n), exist_ok=True)
            swap(home, "dist-%d" % n)

    def reader():
        for _ in range(polls):
            try:
                if read(home) is None:
                    misses[0] += 1
            except (FileNotFoundError, ValueError):
                misses[0] += 1

    w = threading.Thread(target=writer)
    r = threading.Thread(target=reader)
    w.start()
    r.start()
    r.join()
    stop.set()
    w.join()
    return misses[0]


class CurrentSwitch(unittest.TestCase):
    def test_atomic_pointer_swap_is_never_seen_missing(self):
        with tempfile.TemporaryDirectory() as home:
            os.makedirs(os.path.join(home, "dist-0"))
            setup.point_current(home, "dist-0")  # the atomic pointer-file writer
            misses = _reader_writer(home, setup.point_current, setup.read_current, polls=1000)
            self.assertEqual(0, misses)  # a single atomic replace -> the reader always sees old-or-new

    def test_delete_then_create_mutant_is_caught(self):
        # Committed mutant: a NON-atomic swap (unlink, a window, then create) that a correct atomic swap must avoid.
        def mutant_swap(home, dist):
            cur = os.path.join(home, "current.json")
            try:
                os.unlink(cur)
            except FileNotFoundError:
                pass
            time.sleep(0.0005)  # the non-atomic window the reader can hit
            with open(cur, "w") as f:
                json.dump({"dist": dist}, f)

        def plain_read(home):
            with open(os.path.join(home, "current.json")) as f:
                return json.load(f).get("dist")

        with tempfile.TemporaryDirectory() as home:
            os.makedirs(os.path.join(home, "dist-0"))
            with open(os.path.join(home, "current.json"), "w") as f:
                json.dump({"dist": "dist-0"}, f)
            misses = _reader_writer(home, mutant_swap, plain_read, polls=1000)
            self.assertGreater(misses, 0)  # delete-then-create leaves a window the reader catches


if __name__ == "__main__":
    unittest.main()
