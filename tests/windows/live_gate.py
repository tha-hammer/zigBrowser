"""Skip-is-failure for the Linux-driven live Windows tests (plan WS0.9, D.1, rule 7).

A live test calls `skip_or_fail(self, reason)` where it used to call `self.skipTest(reason)` for a missing host or
exe, and ends with `main()` instead of `unittest.main()`.

  * Run standalone by a human (no ZB_WIN_GATE), a missing precondition is a clean skip and the exit is 0, so the
    hostless `zig build test` stays green. Such a run is not a Windows row.
  * Under the gate (ZB_WIN_GATE=1), a missing precondition FAILS the test, and `main()` exits nonzero on any
    skip or on zero executed assertions.

`main()` always prints `ASSERTS <n>`: the number of assert* calls the tests actually executed (outermost calls
only; an assertEqual that dispatches to assertMultiLineEqual counts once). gate.sh --product requires n > 0.
"""
import functools
import os
import sys
import threading
import unittest

GATE_ENV = "ZB_WIN_GATE"


def under_gate() -> bool:
    return os.environ.get(GATE_ENV) == "1"


def skip_or_fail(test: unittest.TestCase, reason: str) -> None:
    """A missing live precondition: a failure under the gate, a clean skip otherwise."""
    if under_gate():
        test.fail(f"{GATE_ENV}=1: {reason}; a skip is a failure under the gate")
    test.skipTest(reason)


class _AssertCounter:
    def __init__(self):
        self.count = 0
        self._depth = threading.local()

    def wrap(self, fn):
        @functools.wraps(fn)
        def counted(*args, **kwargs):
            depth = getattr(self._depth, "n", 0)
            if depth == 0:
                self.count += 1
            self._depth.n = depth + 1
            try:
                return fn(*args, **kwargs)
            finally:
                self._depth.n = depth
        return counted

    def install(self):
        for name in dir(unittest.TestCase):
            attr = getattr(unittest.TestCase, name)
            if name.startswith("assert") and callable(attr):
                setattr(unittest.TestCase, name, self.wrap(attr))
        return self


def main(**kwargs) -> None:
    counter = _AssertCounter().install()
    result = unittest.main(exit=False, **kwargs).result
    print(f"ASSERTS {counter.count}", flush=True)
    if not result.wasSuccessful():
        sys.exit(1)
    if under_gate() and (result.skipped or counter.count == 0):
        print(f"{GATE_ENV}=1: {len(result.skipped)} skipped, ASSERTS {counter.count}: "
              "a skip or zero assertions is a failure under the gate", file=sys.stderr)
        sys.exit(1)
    sys.exit(0)
