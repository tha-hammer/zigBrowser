#!/usr/bin/env python3
"""Hostless selftest of the exact red vectors (red_shape.py) of the six Mac runtime red rows (SilverRidge cf7a783).

No browser, no Mac, no signal. For each red test module, through its own TEST_ID and RED_VECTOR:
  S1 the exact accepted vector -> FAIL and RED_SHAPE\t<test>, exit 1;
  S2 every assertion passing -> PASS\t<test>, exit 0, no RED_SHAPE (the green);
  S3 each single assertion flipped, S4 each assertion missing, S5 one extra failing assertion, S6 a PRECONDITION
     problem, S7 an assertion recorded twice -> no RED_SHAPE line and at least one RED_SHAPE_MISMATCH, exit 1.
And the real row-3 check of mac_ms2a_load_fail_no_quit_test.check_alive, driven with a dead browser and
  R3 ZERO matching LOAD_FAIL rows -> the row is recorded load-fail-once=fail, no RED_SHAPE;
  R3x two matching LOAD_FAIL rows -> no RED_SHAPE;
  R3ok one matching LOAD_FAIL row -> RED_SHAPE (the same driver accepts the accepted shape, so R3 is not vacuous).
Run: python3 tests/e2e/mac_red_shape_selftest.py   (called by tests/mac/mac_gate_callers_selftest.sh)
"""
import contextlib
import importlib
import io
import sys

from red_shape import FAIL, PASS, RedShape

RED_MODULES = (
    "mac_ms2a_load_fail_no_quit_test",
    "mac_ms2c_recover_slow_server_test",
    "mac_ms2c_close_button_test",
    "mac_ms2b_dialog_popup_id_test",
    "mac_cookie_timeout_test",
    "mac_profile_pacing_persist_test",
)
failures: list = []


def run(test_id: str, vector: dict, feed) -> tuple:
    """Build a RedShape, let feed() record into it, report; return (rc, stdout lines)."""
    shape = RedShape(test_id, vector)
    feed(shape)
    out = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
        rc = shape.report()
    return rc, out.getvalue().splitlines()


def expect_red(name: str, test_id: str, rc: int, lines: list) -> None:
    if rc != 1 or f"RED_SHAPE\t{test_id}" not in lines or any(l.startswith("RED_SHAPE_MISMATCH\t") for l in lines):
        failures.append(f"{name}: want exit 1 and RED_SHAPE\\t{test_id} only, got rc={rc} {lines!r}")


def expect_mismatch(name: str, test_id: str, rc: int, lines: list) -> None:
    if rc != 1 or f"RED_SHAPE\t{test_id}" in lines or not any(l.startswith(f"RED_SHAPE_MISMATCH\t{test_id}\t") for l in lines):
        failures.append(f"{name}: want exit 1, no RED_SHAPE and a RED_SHAPE_MISMATCH, got rc={rc} {lines!r}")


def feed_vector(vector: dict, skip=(), flip=(), extra=(), problem=None, twice=()):
    def feed(shape):
        for aid, want in vector.items():
            if aid in skip:
                continue
            ok = (want == PASS) != (aid in flip)
            shape.check(aid, ok, "selftest")
            if aid in twice:
                shape.check(aid, ok, "selftest again")
        for aid in extra:
            shape.check(aid, False, "selftest extra")
        if problem:
            shape.problem(problem)
    return feed


def check_module(name: str) -> int:
    mod = importlib.import_module(name)
    tid, vec = mod.TEST_ID, mod.RED_VECTOR
    n = 0
    rc, lines = run(tid, vec, feed_vector(vec))
    expect_red(f"{name} S1 exact", tid, rc, lines); n += 1
    rc, lines = run(tid, vec, feed_vector({k: PASS for k in vec}))
    if rc != 0 or f"PASS\t{tid}" not in lines or any(l.startswith("RED_SHAPE") for l in lines):
        failures.append(f"{name} S2 all pass: want PASS exit 0, got rc={rc} {lines!r}")
    n += 1
    for aid in vec:
        rc, lines = run(tid, vec, feed_vector(vec, flip={aid}))
        expect_mismatch(f"{name} S3 flip {aid}", tid, rc, lines)
        rc, lines = run(tid, vec, feed_vector(vec, skip={aid}))
        expect_mismatch(f"{name} S4 missing {aid}", tid, rc, lines)
        n += 2
    rc, lines = run(tid, vec, feed_vector(vec, extra={"selftest-extra"}))
    expect_mismatch(f"{name} S5 extra failure", tid, rc, lines)
    rc, lines = run(tid, vec, feed_vector(vec, problem="PRECONDITION selftest"))
    expect_mismatch(f"{name} S6 precondition", tid, rc, lines)
    first = next(iter(vec))
    rc, lines = run(tid, vec, feed_vector(vec, twice={first}))
    expect_mismatch(f"{name} S7 twice {first}", tid, rc, lines)
    return n + 3


class _DeadProc:
    def poll(self):
        return 5  # the Mac today: the process has exited with ZB_EXIT_LOAD_FAILED


class _FakeBrowser:
    def __init__(self, load_fail_rows: int):
        self.proc, self._n = _DeadProc(), load_fail_rows

    def load_fails(self, _match) -> int:
        return self._n


def check_row3_driver() -> int:
    mod = importlib.import_module("mac_ms2a_load_fail_no_quit_test")
    mod.ALIVE_GRACE_SEC = 0.0
    row3 = "row3-undisplayable-response"
    rest = {k: v for k, v in mod.RED_VECTOR.items() if not k.startswith(row3 + ".")}
    for case, rows, want_red in (("R3 zero LOAD_FAIL", 0, False), ("R3x two LOAD_FAIL", 2, False),
                                 ("R3ok one LOAD_FAIL", 1, True)):
        def feed(shape, rows=rows):
            feed_vector(rest)(shape)
            mod.check_alive(row3, _FakeBrowser(rows), None, shape, mod.is_attach_url)
        rc, lines = run(mod.TEST_ID, mod.RED_VECTOR, feed)
        name = f"mac_ms2a_load_fail_no_quit_test {case}"
        if want_red:
            expect_red(name, mod.TEST_ID, rc, lines)
        else:
            expect_mismatch(name, mod.TEST_ID, rc, lines)
            if f"ASSERT\t{mod.TEST_ID}\t{row3}.load-fail-once\t{FAIL}" not in lines:
                failures.append(f"{name}: the driven check did not record {row3}.load-fail-once as fail: {lines!r}")
    return 3


def main() -> int:
    cases = sum(check_module(m) for m in RED_MODULES) + check_row3_driver()
    if failures:
        print("FAIL\tmac-red-shape-selftest")
        for f in failures:
            print(f"  {f}", file=sys.stderr)
        return 1
    print(f"PASS\tmac-red-shape-selftest\t{len(RED_MODULES)} red tests, {cases} cases")
    return 0


if __name__ == "__main__":
    sys.exit(main())
