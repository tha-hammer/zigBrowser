"""WS7.1 [L] — RED-FIRST for the atomic, privilege-free `current` switch (plan line 1657; RoseCat a70e73b).

The agent home is `dist-<n>\\…` with a `current` pointer swapped atomically and without privilege. DECISION: a
`current.json` POINTER FILE replaced by write-temp-then-rename (`os.rename` / Windows `MoveFileExW`
`MOVEFILE_REPLACE_EXISTING`) — a single atomic replace, so a concurrent reader always sees the old or the new
pointer, never a missing or torn one. (A directory-junction swap would need an extra create+replace of a reparse
point; the pointer file is the simplest op the red can prove atomic.)

Portable [L] test: a writer thread swaps `current` through many `dist-<n>` generations while a reader polls 1000
times. The reader counts a MISS unless it reads a COMPLETE, STRICT `dist-<n>` pointer WHOSE TARGET DIRECTORY EXISTS
(a torn/partial/absent pointer, or one pointing at a missing dir, is a miss) — so a non-atomic swap is detected.
Exceptions on EITHER thread are propagated to the test (never swallowed), and the test proves the writer actually
advanced through MULTIPLE generations (not a vacuous green). The delete-then-create mutant uses a DETERMINISTIC
event handshake so the reader is guaranteed to observe the gap exactly once — no timing luck.

UNREGISTERED, signal-free, no VM, no Macs. Only agent/host/tests/ touched (not zb_agent_host/), so no ms5 inventory
change. RED now: `setup.point_current` / `setup.read_current` absent (AttributeError). Run with the agent-host env
python (support imports claude_agent_sdk). The green adds the atomic pointer helpers.
"""

import json
import os
import re
import tempfile
import threading
import unittest

import support  # noqa: F401  (puts agent/host on sys.path)

from zb_agent_host import setup

_DIST = re.compile(r"dist-\d+\Z")


def _is_complete_pointer(home, val):
    """The reader's acceptance test: a COMPLETE, STRICT `dist-<n>` pointer WHOSE TARGET DIRECTORY EXISTS. Anything
    else — None, a non-matching string, or a name whose dir is absent — is NOT a valid old-or-new generation."""
    return isinstance(val, str) and _DIST.match(val) is not None and os.path.isdir(os.path.join(home, val))


def _reader_writer(home, swap, read, polls=1000):
    """A writer thread swaps `current` through `dist-1, dist-2, …` (each dir created BEFORE the swap) while a reader
    polls `read(home)` `polls` times, counting a miss unless the pointer is a complete strict `dist-<n>` whose target
    exists. Returns (misses, generations_written). EXCEPTIONS ON EITHER THREAD ARE RE-RAISED in the caller — a
    crashed writer can never masquerade as zero misses. The writer stops once the reader is done and joined."""
    stop = threading.Event()
    misses = [0]
    gens = [0]
    errors = []

    def writer():
        try:
            n = 0
            while not stop.is_set():
                n += 1
                os.makedirs(os.path.join(home, "dist-%d" % n), exist_ok=True)
                swap(home, "dist-%d" % n)
            gens[0] = n
        except BaseException as exc:  # noqa: BLE001 — captured and re-raised in the main thread
            errors.append(exc)

    def reader():
        try:
            for _ in range(polls):
                try:
                    val = read(home)
                except (FileNotFoundError, ValueError, json.JSONDecodeError):
                    misses[0] += 1  # absent or torn pointer file
                    continue
                if not _is_complete_pointer(home, val):
                    misses[0] += 1  # not a complete old-or-new generation
        except BaseException as exc:  # noqa: BLE001
            errors.append(exc)

    w = threading.Thread(target=writer)
    r = threading.Thread(target=reader)
    w.start()
    r.start()
    r.join()
    stop.set()
    w.join()
    if errors:
        raise errors[0]  # propagate the first thread failure to the test
    return misses[0], gens[0]


class CurrentSwitch(unittest.TestCase):
    def test_atomic_pointer_swap_is_never_seen_missing(self):
        with tempfile.TemporaryDirectory() as home:
            os.makedirs(os.path.join(home, "dist-0"))
            setup.point_current(home, "dist-0")  # the atomic pointer-file writer
            misses, gens = _reader_writer(home, setup.point_current, setup.read_current, polls=1000)
            self.assertEqual(0, misses)  # a single atomic replace -> the reader always sees old-or-new, target present
            self.assertGreater(gens, 1)  # the writer actually advanced through multiple dist-<n> generations

    def test_delete_then_create_mutant_is_caught(self):
        # Committed mutant: a NON-atomic swap (unlink, a window, then create). A DETERMINISTIC event handshake makes
        # the reader observe the open gap exactly once -- no sleeps, no timing luck. A correct atomic swap avoids it.
        def plain_read(home):
            with open(os.path.join(home, "current.json")) as f:
                return json.load(f).get("dist")

        with tempfile.TemporaryDirectory() as home:
            os.makedirs(os.path.join(home, "dist-0"))
            os.makedirs(os.path.join(home, "dist-1"))
            cur = os.path.join(home, "current.json")
            with open(cur, "w") as f:
                json.dump({"dist": "dist-0"}, f)

            gap_open = threading.Event()
            reader_checked = threading.Event()
            misses = [0]
            errors = []

            def mutant_writer():
                try:
                    os.unlink(cur)              # non-atomic: the pointer is now missing
                    gap_open.set()              # hand off: the gap is open
                    if not reader_checked.wait(5):
                        raise AssertionError("reader did not observe the gap within 5s")
                    with open(cur, "w") as f:   # re-create only after the reader has looked
                        json.dump({"dist": "dist-1"}, f)
                except BaseException as exc:  # noqa: BLE001
                    errors.append(exc)
                    gap_open.set()

            def reader():
                try:
                    if not gap_open.wait(5):
                        raise AssertionError("writer never opened the gap within 5s")
                    try:
                        val = plain_read(home)
                        if not _is_complete_pointer(home, val):
                            misses[0] += 1
                    except (FileNotFoundError, ValueError, json.JSONDecodeError):
                        misses[0] += 1  # the deterministic gap: current.json is absent
                finally:
                    reader_checked.set()

            w = threading.Thread(target=mutant_writer)
            r = threading.Thread(target=reader)
            w.start()
            r.start()
            r.join()
            w.join()
            if errors:
                raise errors[0]
            self.assertEqual(1, misses[0])  # the reader deterministically caught the one non-atomic gap


if __name__ == "__main__":
    unittest.main()
