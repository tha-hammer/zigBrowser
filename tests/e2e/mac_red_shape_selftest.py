#!/usr/bin/env python3
"""Hostless selftest of the exact red vectors (red_shape.py) of the six Mac runtime red rows (SilverRidge cf7a783,
8721b6d).

No browser, no Mac, no signal. For each red test module, through its own TEST_ID and RED_VECTOR:
  S1 the exact accepted vector (every Red with its accepted value) -> FAIL and RED_SHAPE\t<test>, exit 1;
  S2 every assertion passing -> PASS\t<test>, exit 0, no RED_SHAPE (the green);
  S3 each single assertion flipped, S4 each assertion missing, S5 one extra failing assertion, S6 a PRECONDITION
     problem, S7 an assertion recorded twice, S8 each Red failing with its same-polarity counter value, S9 each Red
     failing with no observed value -> no RED_SHAPE line and at least one RED_SHAPE_MISMATCH, exit 1.
And each test's row-owned recording function (SilverRidge cf16730), driven with raw observations: today's Mac
observation must give RED_SHAPE and a wrong observation of the same polarity a mismatch, so a value hard-coded at the
observation boundary turns this red:
  D1 row 3 of mac_ms2a_load_fail_no_quit_test.check_alive with a dead browser: exit 5 -> RED_SHAPE; exit 8, ZERO or
     two matching LOAD_FAIL rows -> mismatch;
  D2 recovery record_after_recovery: exit 8 at 15.2 s -> RED_SHAPE; exit 5, 3.0 s, 40 s -> mismatch;
  D3 close record_listed / record_routed (result; action_timeout, another error) / record_destroy (WINCOUNT 2;
     WINCOUNT 3, none);
  D4 dialog record_listed (window-2; window-1) / record_by_id (open=False; no reply, open missing) / record_respond
     (no_window; action_timeout) / record_confirm;
  D5 cookie record_op: a result at 12.6 s; another error, a result at 20 s;
  D6 pacing record_saved (FileNotFound on the pacing file; AccessDenied, another path, an unparsed line, no line) /
     record_restored (default; a third cap).
  P  each main calls its recording functions exactly once and checks no Red assertion itself; run_row calls
     check_alive (tripwire).
Run: python3 tests/e2e/mac_red_shape_selftest.py   (called by tests/mac/mac_gate_callers_selftest.sh)
"""
import contextlib
import importlib
import inspect
import io
import re
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


def drive(name: str, mod, ids: set, record, want_red: bool) -> None:
    """Record every other assertion as accepted, then call the row-owned `record(shape)` with raw observations."""
    rest = {k: v for k, v in mod.RED_VECTOR.items() if k not in ids}

    def feed(shape):
        feed_vector(rest)(shape)
        record(shape)
    rc, lines = run(mod.TEST_ID, mod.RED_VECTOR, feed)
    (expect_red if want_red else expect_mismatch)(f"{mod.__name__} {name}", mod.TEST_ID, rc, lines)


RESULT = {"jsonrpc": "2.0", "id": 1, "result": {"title": "POPUP"}}
NO_WINDOW = {"jsonrpc": "2.0", "id": 1, "error": {"code": -32011, "message": "x", "data": {"reason": "no_window"}}}
TIMEOUT = {"jsonrpc": "2.0", "id": 1, "error": {"code": -32000, "message": "action_timeout"}}
OTHER_ERR = {"jsonrpc": "2.0", "id": 1, "error": {"code": -32000, "message": "navigation_failed"}}


def drive_records() -> int:
    """D2-D5: each row-owned recording function, driven with today's Mac observation (RED_SHAPE) and with wrong
    observations of the same polarity (mismatch), so a value hard-coded at the observation boundary turns this red."""
    cases = []
    slow = importlib.import_module("mac_ms2c_recover_slow_server_test")
    ids = {"alive", "health-answers"}
    cases += [("D2 recovery exit 8 at 15.2 s", slow, ids, lambda sh: slow.record_after_recovery(sh, 8, 15.2, None, 1), True),
              ("D2 recovery exit 5 at 15.2 s", slow, ids, lambda sh: slow.record_after_recovery(sh, 5, 15.2, None, 1), False),
              ("D2 recovery exit 8 at 3.0 s", slow, ids, lambda sh: slow.record_after_recovery(sh, 8, 3.0, None, 1), False),
              ("D2 recovery exit 8 at 40 s", slow, ids, lambda sh: slow.record_after_recovery(sh, 8, 40.0, None, 1), False)]
    close = importlib.import_module("mac_ms2c_close_button_test")
    cases += [("D3 close 1 popup listed", close, {"1-left-page-list"},
               lambda sh: close.record_listed(sh, "window-2", ["window-1", "window-2"]), True),
              ("D3 close 2 result", close, {"2-routed-no-window"}, lambda sh: close.record_routed(sh, RESULT), True),
              ("D3 close 2 action_timeout", close, {"2-routed-no-window"}, lambda sh: close.record_routed(sh, TIMEOUT), False),
              ("D3 close 2 other error", close, {"2-routed-no-window"}, lambda sh: close.record_routed(sh, OTHER_ERR), False),
              ("D3 close 5 WINCOUNT 2", close, {"5-shared-destroy-path"},
               lambda sh: close.record_destroy(sh, ["WINCOUNT\t1", "WINCOUNT\t2"]), True),
              ("D3 close 5 WINCOUNT 3", close, {"5-shared-destroy-path"},
               lambda sh: close.record_destroy(sh, ["WINCOUNT\t2", "WINCOUNT\t3"]), False),
              ("D3 close 5 no WINCOUNT", close, {"5-shared-destroy-path"}, lambda sh: close.record_destroy(sh, []), False)]
    dialog = importlib.import_module("mac_ms2b_dialog_popup_id_test")
    cases += [("D4 dialog 1 window-2", dialog, {"1-listed-under-stable-id"},
               lambda sh: dialog.record_listed(sh, {"open": True, "window_id": "window-2"}, "window-3"), True),
              ("D4 dialog 1 window-1", dialog, {"1-listed-under-stable-id"},
               lambda sh: dialog.record_listed(sh, {"open": True, "window_id": "window-1"}, "window-3"), False),
              ("D4 dialog 2 open=False", dialog, {"2-get-by-id-open"},
               lambda sh: dialog.record_by_id(sh, {"open": False}, "window-3"), True),
              ("D4 dialog 2 no reply", dialog, {"2-get-by-id-open"}, lambda sh: dialog.record_by_id(sh, None, "window-3"), False),
              ("D4 dialog 2 open=None", dialog, {"2-get-by-id-open"},
               lambda sh: dialog.record_by_id(sh, {"type": "confirm"}, "window-3"), False),
              ("D4 dialog 3 no_window", dialog, {"3-respond-listed-ok"}, lambda sh: dialog.record_respond(sh, NO_WINDOW), True),
              ("D4 dialog 3 action_timeout", dialog, {"3-respond-listed-ok"},
               lambda sh: dialog.record_respond(sh, TIMEOUT), False),
              ("D4 dialog 4 not true", dialog, {"4-confirm-returned-true"}, lambda sh: dialog.record_confirm(sh, False), True)]
    cookie = importlib.import_module("mac_cookie_timeout_test")
    ids = {"1-action-timeout cookies.set", "2-at-deadline cookies.set"}
    cases += [("D5 cookie result at 12.6 s", cookie, ids,
               lambda sh: cookie.record_op(sh, "cookies.set", {"result": {"ok": True}}, 12.6), True),
              ("D5 cookie other error at 12.6 s", cookie, ids, lambda sh: cookie.record_op(sh, "cookies.set", OTHER_ERR, 12.6), False),
              ("D5 cookie result at 20 s", cookie, ids,
               lambda sh: cookie.record_op(sh, "cookies.set", {"result": {"ok": True}}, 20.0), False)]
    pacing = importlib.import_module("mac_profile_pacing_persist_test")
    ids = {"1-file-exists", "1-no-save-error"}
    pf = "/r/fresh/zb-profile/automation-pacing.json"
    line = f"warning: automation pacing: could not save {pf}: "
    cases += [("D6 pacing not saved, FileNotFound", pacing, ids,
               lambda sh: pacing.record_saved(sh, False, [line + "FileNotFound", line + "FileNotFound"], pf), True),
              ("D6 pacing AccessDenied", pacing, ids, lambda sh: pacing.record_saved(sh, False, [line + "AccessDenied"], pf), False),
              ("D6 pacing another path", pacing, ids, lambda sh: pacing.record_saved(
                  sh, False, ["warning: automation pacing: could not save /x/automation-pacing.json: FileNotFound"], pf), False),
              ("D6 pacing an unparsed line", pacing, ids,
               lambda sh: pacing.record_saved(sh, False, ["automation pacing: could not save"], pf), False),
              ("D6 pacing no save error line", pacing, ids, lambda sh: pacing.record_saved(sh, False, [], pf), False),
              ("D6 pacing back on the default", pacing, {"2-cap-restored"}, lambda sh: pacing.record_restored(sh, 100, 100), True),
              ("D6 pacing a third cap", pacing, {"2-cap-restored"}, lambda sh: pacing.record_restored(sh, 55, 100), False)]
    for name, mod, ids, record, want_red in cases:
        drive(name, mod, ids, record, want_red)
    return len(cases)


# Each main must hand its raw observations to the row-owned recording functions driven above (a main that checked
# a value itself would escape them). Tripwire only; the behavior is the D cases.
MAIN_PINS = {
    "mac_ms2c_recover_slow_server_test": ("record_after_recovery(",),
    "mac_ms2c_close_button_test": ("record_listed(", "record_routed(", "record_destroy("),
    "mac_ms2b_dialog_popup_id_test": ("record_listed(", "record_by_id(", "record_respond(", "record_confirm("),
    "mac_cookie_timeout_test": ("record_op(",),
    "mac_profile_pacing_persist_test": ("record_saved(", "record_restored("),
}


def pin_mains() -> int:
    n = 0
    for name, calls in MAIN_PINS.items():
        mod = importlib.import_module(name)
        src = inspect.getsource(mod.main)
        for call in calls:
            n += 1
            if src.count(call) != 1:
                failures.append(f"P {name}: main calls {call} {src.count(call)} times, want 1")
        red_ids = [aid for aid, want in mod.RED_VECTOR.items() if isinstance(want, Red)]
        for checked in re.findall(r"shape\.check\(\s*f?[\"']([^\"'{]+)", src):  # no Red assertion checked in main
            if any(aid.startswith(checked) for aid in red_ids):
                failures.append(f"P {name}: main checks {checked!r} itself")
    lf = importlib.import_module("mac_ms2a_load_fail_no_quit_test")
    n += 1
    if inspect.getsource(lf.run_row).count("check_alive(") != 1:
        failures.append("P load-fail: run_row does not call check_alive once")
    return n


def main() -> int:
    cases = sum(check_module(m) for m in RED_MODULES) + drive_row3() + drive_records() + pin_mains()
    if failures:
        print("FAIL\tmac-red-shape-selftest")
        for f in failures:
            print(f"  {f}", file=sys.stderr)
        return 1
    print(f"PASS\tmac-red-shape-selftest\t{len(RED_MODULES)} red tests, {cases} cases")
    return 0


if __name__ == "__main__":
    sys.exit(main())
