#!/usr/bin/env python3
"""Hostless selftest of the exact red vectors (red_shape.py) of the six Mac runtime red rows (SilverRidge cf7a783,
8721b6d).

No browser, no Mac, no signal. For each red test module, through its own TEST_ID and RED_VECTOR:
  S1 the exact accepted vector (every Red with its accepted value) -> FAIL and RED_SHAPE\t<test>, exit 1;
  S2 every assertion passing -> PASS\t<test>, exit 0, no RED_SHAPE (the green);
  S3 each single assertion flipped, S4 each assertion missing, S5 one extra failing assertion, S6 a PRECONDITION
     problem, S7 an assertion recorded twice, S8 each Red failing with its same-polarity counter value, S9 each Red
     failing with no observed value -> no RED_SHAPE line and at least one RED_SHAPE_MISMATCH, exit 1.
And each test's own value code, driven with realistic inputs (D*): the observed value it records must be accepted
for today's Mac red and rejected for a same-polarity wrong one:
  D1 row 3 of mac_ms2a_load_fail_no_quit_test.check_alive with a dead browser: exit 5 -> RED_SHAPE; exit 8, ZERO or
     two matching LOAD_FAIL rows -> mismatch;
  D2 recovery: observe_exit(8, 15.2 s) accepted; observe_exit(5, 15.2 s) and observe_exit(8, 3.0 s) rejected;
  D3 reply kinds (close 2, dialog 3, cookie 1): a result / error:no_window accepted where the red says so; another
     reason rejected;
  D4 pacing: observe_cap(default, default) accepted; a third cap rejected; the set cap 7 passes the assertion.
Run: python3 tests/e2e/mac_red_shape_selftest.py   (called by tests/mac/mac_gate_callers_selftest.sh)
"""
import contextlib
import importlib
import io
import sys

from red_shape import PASS, Red, RedShape, reply_kind

RED_MODULES = (
    "mac_ms2a_load_fail_no_quit_test",
    "mac_ms2c_recover_slow_server_test",
    "mac_ms2c_close_button_test",
    "mac_ms2b_dialog_popup_id_test",
    "mac_cookie_timeout_test",
    "mac_profile_pacing_persist_test",
)
NO_VALUE = object()
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


def feed_vector(vector: dict, skip=(), flip=(), extra=(), problem=None, twice=(), values=None):
    """Record the vector's accepted outcome, with the listed changes; `values` overrides a Red's observed value."""
    values = values or {}

    def feed(shape):
        for aid, want in vector.items():
            if aid in skip:
                continue
            ok = (want == PASS) != (aid in flip)
            observed = values.get(aid, want.accepted if isinstance(want, Red) else None)
            for _ in range(2 if aid in twice else 1):
                if observed is NO_VALUE:
                    shape.check(aid, ok, "selftest")
                else:
                    shape.check(aid, ok, "selftest", observed=observed)
        for aid in extra:
            shape.check(aid, False, "selftest extra", observed="x")
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
    for aid, want in vec.items():
        rc, lines = run(tid, vec, feed_vector(vec, flip={aid}))
        expect_mismatch(f"{name} S3 flip {aid}", tid, rc, lines)
        rc, lines = run(tid, vec, feed_vector(vec, skip={aid}))
        expect_mismatch(f"{name} S4 missing {aid}", tid, rc, lines)
        n += 2
        if isinstance(want, Red):
            rc, lines = run(tid, vec, feed_vector(vec, values={aid: want.counter}))
            expect_mismatch(f"{name} S8 {aid} failing with {want.counter!r}", tid, rc, lines)
            rc, lines = run(tid, vec, feed_vector(vec, values={aid: NO_VALUE}))
            expect_mismatch(f"{name} S9 {aid} failing with no value", tid, rc, lines)
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
    def __init__(self, rc: int):
        self.rc = rc

    def poll(self):
        return self.rc


class _FakeBrowser:
    def __init__(self, load_fail_rows: int, rc: int):
        self.proc, self._n = _DeadProc(rc), load_fail_rows

    def load_fails(self, _match) -> int:
        return self._n


def drive_row3() -> int:
    mod = importlib.import_module("mac_ms2a_load_fail_no_quit_test")
    mod.ALIVE_GRACE_SEC = 0.0
    row3 = "row3-undisplayable-response"
    rest = {k: v for k, v in mod.RED_VECTOR.items() if not k.startswith(row3 + ".")}
    cases = (("D1 one LOAD_FAIL, exit 5", 1, 5, True), ("D1 exit 8", 1, 8, False),
             ("D1 zero LOAD_FAIL", 0, 5, False), ("D1 two LOAD_FAIL", 2, 5, False))
    for case, rows, rc_value, want_red in cases:
        def feed(shape, rows=rows, rc_value=rc_value):
            feed_vector(rest)(shape)
            mod.check_alive(row3, _FakeBrowser(rows, rc_value), None, shape, mod.is_attach_url)
        rc, lines = run(mod.TEST_ID, mod.RED_VECTOR, feed)
        name = f"mac_ms2a_load_fail_no_quit_test {case}"
        (expect_red if want_red else expect_mismatch)(name, mod.TEST_ID, rc, lines)
    return len(cases)


def expect_accepts(name: str, red: Red, value, want: bool) -> None:
    if red.accepts(value) != want:
        failures.append(f"{name}: {red.desc} {'rejected' if want else 'accepted'} {value!r}")


def drive_values() -> int:
    slow = importlib.import_module("mac_ms2c_recover_slow_server_test")
    alive = slow.RED_VECTOR["alive"]
    expect_accepts("D2 recovery exit 8 at 15.2 s", alive, slow.observe_exit(8, 15.2), True)
    expect_accepts("D2 recovery exit 5 at 15.2 s", alive, slow.observe_exit(5, 15.2), False)
    expect_accepts("D2 recovery exit 8 at 3.0 s", alive, slow.observe_exit(8, 3.0), False)
    expect_accepts("D2 recovery exit 8 at 40 s", alive, slow.observe_exit(8, 40.0), False)

    result = {"jsonrpc": "2.0", "id": 1, "result": {"title": "POPUP"}}
    no_window = {"jsonrpc": "2.0", "id": 1, "error": {"code": -32011, "message": "x", "data": {"reason": "no_window"}}}
    timeout = {"jsonrpc": "2.0", "id": 1, "error": {"code": -32000, "message": "action_timeout"}}
    close = importlib.import_module("mac_ms2c_close_button_test").RED_VECTOR["2-routed-no-window"]
    expect_accepts("D3 close 2 result", close, reply_kind(result), True)
    expect_accepts("D3 close 2 error:no_window", close, reply_kind(no_window), False)
    expect_accepts("D3 close 2 action_timeout", close, reply_kind(timeout), False)
    dialog = importlib.import_module("mac_ms2b_dialog_popup_id_test").RED_VECTOR["3-respond-listed-ok"]
    expect_accepts("D3 dialog 3 error:no_window", dialog, reply_kind(no_window), True)
    expect_accepts("D3 dialog 3 action_timeout", dialog, reply_kind(timeout), False)
    expect_accepts("D3 dialog 3 result", dialog, reply_kind(result), False)
    cookie = importlib.import_module("mac_cookie_timeout_test").RED_VECTOR["1-action-timeout cookies.set"]
    expect_accepts("D3 cookie 1 result", cookie, reply_kind({"result": {"ok": True}}), True)
    expect_accepts("D3 cookie 1 other error", cookie, reply_kind(no_window), False)

    pacing = importlib.import_module("mac_profile_pacing_persist_test")
    cap = pacing.RED_VECTOR["2-cap-restored"]
    expect_accepts("D4 pacing back on the default cap", cap, pacing.observe_cap(100, 100), True)
    expect_accepts("D4 pacing a third cap", cap, pacing.observe_cap(55, 100), False)
    if pacing.observe_cap(pacing.NEW_CAP, 100) != "set-cap":
        failures.append("D4 pacing: the set cap 7 is not observed as set-cap")
    return 13


def main() -> int:
    cases = sum(check_module(m) for m in RED_MODULES) + drive_row3() + drive_values()
    if failures:
        print("FAIL\tmac-red-shape-selftest")
        for f in failures:
            print(f"  {f}", file=sys.stderr)
        return 1
    print(f"PASS\tmac-red-shape-selftest\t{len(RED_MODULES)} red tests, {cases} cases")
    return 0


if __name__ == "__main__":
    sys.exit(main())
