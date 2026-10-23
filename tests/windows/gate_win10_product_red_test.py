#!/usr/bin/env python3
r"""ong.8 RED (UNREGISTERED), NavyCanyon b6ff5c68: WS0.9-W10, the gate's product run re-probes the Win10 box AFTER its
live tests and enforces the Win10 product preconditions.

Today `product_run` calls `probe_only`, whose Win10 pre and post probes run back to back BEFORE any live test, so a
disturbance made by the run is never seen; and the validator never judges Win10 on root, free_gb, webview2_pv or
the console session (written on the withdrawn read-only premise; owner ruling 2026-10-22: the Win10 box is a
writable test host, work confined to C:\Users\zbtest\zb).

Pinned product sequence (b6ff5c68): Win11 readiness; a fresh-nonce Win10 session trigger; the Win10 pre probe;
product-pre validation; every phase entry; the Win10 post probe; product-post validation (original pre vs real
post). This drives the REAL gate.sh with gate_twohost_selftest's harness (fake ssh/virsh, fake live tests, TEST-NET
hosts, fake_transport.problem on every run). One addition, a prefix on the fake ssh: it records every Win10/Win11
session trigger and probe with the number of fake live tests that had already run (an order log), can answer the
Win10 session separately, and can answer (or fail) a Win10 probe only once a live test has run.

  - fail today: the order session < pre < first test < last test < post; post-only disturbances (service listener,
    share, firewall hash) fail the run after the tests; a post-only field degradation fails after the tests; the post
    probe runs after a failed, skipped, malformed-ASSERTS or timed-out row; a failed test plus a disturbance, and a
    failed test plus a post-run transport failure, report BOTH; a post-run transport failure names Win10;
    product-pre refuses each bad Win10 root/free_gb/webview2_pv/interactive_session/locked before any test; an
    unsuccessful Win10 session result stops before any test; the Win10 trigger carries its own fresh nonce;
  - guards (pass today, must stay): a healthy run (Win10 free_gb exactly 20, root differing only in case and a
    trailing backslash) passes and runs every test; `--probe-only` stays readiness-only and zero-write (Win10 at
    free_gb 0 with no session and no root passes, and no Win10 session is triggered); an unset Win10 host is named.

Run alone:  unshare --user --map-current-user --net python3 -I tests/windows/gate_win10_product_red_test.py -v
"""
import json
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import gate_twohost_selftest as gts  # noqa: E402

# Prepended to the fake ssh. It reads (and re-feeds) the streamed script so it can tell a session trigger
# (`schtasks`) from a probe, then logs `<host> <kind> ran=<n> nonce=<n>` before the original stub runs.
_ORDER_PREFIX = r'''
__argv="$*"; __body=""
case "$__argv" in *host_probe*|*powershell*|*EncodedCommand*) __body="$(cat)"; exec 0< <(printf '%s' "$__body") ;; esac
__ran=0
if [ -n "${ZB_FAKE_RAN_LOG:-}" ] && [ -s "$ZB_FAKE_RAN_LOG" ]; then __ran=$(grep -c . "$ZB_FAKE_RAN_LOG"); fi
__host=other
case "$__argv" in *198.51.100.15*|*zbtest@*) __host=win10 ;; *192.0.2.1*|*zbtext@*) __host=win11 ;; esac
__kind=other
case "$__body" in *schtasks*) __kind=session ;; "") ;; *) __kind=probe ;; esac
__nonce=$(printf '%s' "$__body" | grep -o "ws0-[A-Za-z0-9-]*" | head -n1)
if [ -n "${ZB_SELFTEST_ORDER_LOG:-}" ]; then printf '%s %s ran=%s nonce=%s\n' "$__host" "$__kind" "$__ran" "$__nonce" >> "$ZB_SELFTEST_ORDER_LOG"; fi
if [ "$__host" = win10 ] && [ "$__kind" = session ] && [ -n "${ZB_SELFTEST_SESSION_RESULT_WIN10+x}" ]; then
  printf '%s' "$ZB_SELFTEST_SESSION_RESULT_WIN10"; exit 0
fi
if [ "$__host" = win10 ] && [ "$__kind" = probe ] && [ "$__ran" -gt 0 ]; then
  if [ -n "${ZB_SELFTEST_FAIL_WIN10_AFTER_RUN:-}" ]; then exit "$ZB_SELFTEST_FAIL_WIN10_AFTER_RUN"; fi
  if [ -n "${ZB_SELFTEST_PROBE_WIN10_AFTER_RUN:-}" ]; then printf '%s' "$ZB_SELFTEST_PROBE_WIN10_AFTER_RUN"; exit 0; fi
fi
'''
# One more fake live-test mode: outlive the gate's per-test timeout.
_SLEEP_MODE = 'if mode == "sleep":\n    import time; time.sleep(30)\n'

_saved = {}


def setUpModule():
    _saved["ssh"], _saved["live"] = gts._SSH_STUB, gts._FAKE_LIVE_TEST
    gts._SSH_STUB = _ORDER_PREFIX + gts._SSH_STUB
    anchor = "mode = {mode!r}\n"
    assert gts._FAKE_LIVE_TEST.count(anchor) == 1
    gts._FAKE_LIVE_TEST = gts._FAKE_LIVE_TEST.replace(anchor, anchor + _SLEEP_MODE)


def tearDownModule():
    gts._SSH_STUB, gts._FAKE_LIVE_TEST = _saved["ssh"], _saved["live"]


def fs(drop=(), **over):
    """A healthy Win10 product-mode record: gate_twohost_selftest._fs_probe plus an active, unlocked console session
    (what the nonce-matched helper reports), with `over` applied and `drop` keys removed."""
    p = json.loads(gts._fs_probe(**{"interactive_session": True, "locked": False, **over}))
    for k in drop:
        p.pop(k, None)
    return json.dumps(p)


PASS2 = [("a_test.py", "pass"), ("b_test.py", "pass")]
FAIL_ROW = "FAIL tests/windows/fake/f_test.py: failed (exit 1)"
POST_TRANSPORT = "Win10 post-run probe transport failed"
SESSION_STOP = "Win10 in-console session helper"


class _Case(gts._TwoHostCase):
    def product(self, td, tests, extra=None, args=("--product",)):
        order = td / "order.log"
        order.write_text("")
        env = {"ZB_SELFTEST_ORDER_LOG": str(order), "ZB_SELFTEST_PROBE_WIN10": fs()}
        env.update(extra or {})
        proc, ran = gts.WS09ProductRun._run_product(self, td, tests, extra=env, args=args)
        rows = [dict(kv.split("=", 1) for kv in l.split()[2:]) | {"host": l.split()[0], "kind": l.split()[1]}
                for l in order.read_text().splitlines() if l.strip()]
        return proc, ran, rows

    @staticmethod
    def detail(proc, ran=(), rows=()):
        return f"\nrc={proc.returncode}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}\nran: {ran}\norder: {rows}"

    @staticmethod
    def win10(rows, kind):
        return [r for r in rows if r["host"] == "win10" and r["kind"] == kind]

    def assertFailsAfterTests(self, proc, ran, rows, n, *needles):
        d = self.detail(proc, ran, rows)
        self.assertNotEqual(proc.returncode, 0, "the product run must fail" + d)
        self.assertEqual(len(ran), n, "every live test ran first" + d)
        for needle in needles:
            self.assertIn(needle, proc.stderr, d)

    def assertStopsBeforeTests(self, proc, ran, rows, needle):
        d = self.detail(proc, ran, rows)
        self.assertNotEqual(proc.returncode, 0, "the product run must fail closed" + d)
        self.assertEqual(ran, [], "no live test runs after a failed precondition" + d)
        self.assertIn(needle, proc.stderr, d)


class ProductSequence(_Case):
    def test_session_then_pre_then_every_test_then_post(self):
        with tempfile.TemporaryDirectory() as t:
            proc, ran, rows = self.product(pathlib.Path(t), PASS2 + [("c_test.py", "pass")])
            d = self.detail(proc, ran, rows)
            self.assertEqual(proc.returncode, 0, d)
            w10 = [r for r in rows if r["host"] == "win10"]
            self.assertEqual([(r["kind"], r["ran"]) for r in w10], [("session", "0"), ("probe", "0"), ("probe", "3")],
                             "Win10: session trigger < pre probe < first test ... last test < post probe" + d)

    def test_the_win10_session_trigger_carries_its_own_fresh_nonce(self):
        with tempfile.TemporaryDirectory() as t:
            proc, ran, rows = self.product(pathlib.Path(t), PASS2)
            d = self.detail(proc, ran, rows)
            s10 = self.win10(rows, "session")
            s11 = [r for r in rows if r["host"] == "win11" and r["kind"] == "session"]
            self.assertEqual(len(s10), 1, "one Win10 session trigger" + d)
            self.assertEqual(len(s11), 1, d)
            self.assertTrue(s10[0]["nonce"].startswith("ws0-"), d)
            self.assertNotEqual(s10[0]["nonce"], s11[0]["nonce"], "the Win10 nonce is its own" + d)


class PostRunFence(_Case):
    def test_a_disturbance_made_by_the_run_fails_it(self):
        post = {
            "service listener": (fs(listeners=json.loads(gts._fs_probe())["listeners"] + [{"port": 5985, "pid": 777}]),
                                 "service listener ports changed"),
            "share": (fs(shares=[{"name": "zbx", "path": "C:\\zbx"}]), "served shares changed"),
            "firewall": (fs(fw_rules_hash="changed"), "firewall rules changed"),
        }
        for what, (record, needle) in post.items():
            with self.subTest(disturbance=what), tempfile.TemporaryDirectory() as t:
                proc, ran, rows = self.product(pathlib.Path(t), PASS2, {"ZB_SELFTEST_PROBE_WIN10_AFTER_RUN": record})
                self.assertFailsAfterTests(proc, ran, rows, 2, needle)

    def test_a_field_degraded_only_after_the_run_fails_it(self):
        with tempfile.TemporaryDirectory() as t:
            proc, ran, rows = self.product(pathlib.Path(t), PASS2, {"ZB_SELFTEST_PROBE_WIN10_AFTER_RUN": fs(free_gb=5.0)})
            self.assertFailsAfterTests(proc, ran, rows, 2, "win10 (post): free_gb")

    def test_the_post_probe_runs_after_every_row_outcome(self):
        for mode in ("fail1", "exit77", "malformed", "sleep"):
            with self.subTest(last_row=mode), tempfile.TemporaryDirectory() as t:
                proc, ran, rows = self.product(pathlib.Path(t), [("a_test.py", "pass"), ("x_test.py", mode)],
                                               {"ZB_LIVE_TEST_TIMEOUT": "2"})
                d = self.detail(proc, ran, rows)
                self.assertNotEqual(proc.returncode, 0, d)
                self.assertIn("FAIL tests/windows/fake/x_test.py", proc.stderr, d)
                self.assertEqual([r["ran"] for r in self.win10(rows, "probe")], ["0", "2"],
                                 "a Win10 post probe follows the failed row" + d)

    def test_a_failed_test_and_a_disturbance_are_both_reported(self):
        with tempfile.TemporaryDirectory() as t:
            proc, ran, rows = self.product(pathlib.Path(t), [("f_test.py", "fail1"), ("a_test.py", "pass")],
                                           {"ZB_SELFTEST_PROBE_WIN10_AFTER_RUN": fs(fw_rules_hash="changed")})
            self.assertFailsAfterTests(proc, ran, rows, 2, FAIL_ROW, "firewall rules changed")

    def test_a_failed_test_and_a_post_transport_failure_are_both_reported(self):
        with tempfile.TemporaryDirectory() as t:
            proc, ran, rows = self.product(pathlib.Path(t), [("f_test.py", "fail1"), ("a_test.py", "pass")],
                                           {"ZB_SELFTEST_FAIL_WIN10_AFTER_RUN": "255"})
            self.assertFailsAfterTests(proc, ran, rows, 2, FAIL_ROW, POST_TRANSPORT)

    def test_a_post_run_transport_failure_names_win10(self):
        with tempfile.TemporaryDirectory() as t:
            proc, ran, rows = self.product(pathlib.Path(t), PASS2, {"ZB_SELFTEST_FAIL_WIN10_AFTER_RUN": "255"})
            self.assertFailsAfterTests(proc, ran, rows, 2, POST_TRANSPORT)
            self.assertNotIn("product run PASSED", proc.stderr, self.detail(proc, ran, rows))


class ProductPreconditions(_Case):
    def test_each_bad_win10_field_stops_before_any_test(self):
        bad = {
            "root wrong": (fs(root="C:\\Users\\zbtest\\zb2"), "win10 (pre): root"),
            "root missing": (fs(drop=("root",)), "win10 (pre): root"),
            "free_gb 19.9": (fs(free_gb=19.9), "win10 (pre): free_gb"),
            "free_gb 0": (fs(free_gb=0), "win10 (pre): free_gb"),
            "free_gb NaN": (fs(free_gb=float("nan")), "win10 (pre): free_gb"),
            "free_gb bool": (fs(free_gb=True), "win10 (pre): free_gb"),
            "free_gb string": (fs(free_gb="500"), "win10 (pre): free_gb"),
            "free_gb missing": (fs(drop=("free_gb",)), "win10 (pre): free_gb"),
            "webview2_pv empty": (fs(webview2_pv=""), "win10 (pre): webview2_pv"),
            "webview2_pv blank": (fs(webview2_pv="  "), "win10 (pre): webview2_pv"),
            "webview2_pv number": (fs(webview2_pv=155), "win10 (pre): webview2_pv"),
            "webview2_pv missing": (fs(drop=("webview2_pv",)), "win10 (pre): webview2_pv"),
            "interactive False": (fs(interactive_session=False), "win10 (pre): no active interactive session"),
            "interactive string": (fs(interactive_session="True"), "win10 (pre): no active interactive session"),
            "interactive missing": (fs(drop=("interactive_session",)), "win10 (pre): no active interactive session"),
            "locked True": (fs(locked=True), "win10 (pre): session is locked"),
            "locked string": (fs(locked="False"), "win10 (pre): session is locked"),
            "locked missing": (fs(drop=("locked",)), "win10 (pre): session is locked"),
        }
        for what, (record, needle) in bad.items():
            with self.subTest(field=what), tempfile.TemporaryDirectory() as t:
                proc, ran, rows = self.product(pathlib.Path(t), PASS2, {"ZB_SELFTEST_PROBE_WIN10": record})
                self.assertStopsBeforeTests(proc, ran, rows, needle)

    def test_an_unsuccessful_win10_session_stops_before_any_test(self):
        for result in ("RESULT=TIMEOUT", "VERIFY=TASK_MISSING", "garbage"):
            with self.subTest(result=result), tempfile.TemporaryDirectory() as t:
                proc, ran, rows = self.product(pathlib.Path(t), PASS2, {"ZB_SELFTEST_SESSION_RESULT_WIN10": result})
                self.assertStopsBeforeTests(proc, ran, rows, SESSION_STOP)


class Guards(_Case):
    HEALTHY_WIN10 = fs(free_gb=20, root="c:\\users\\ZBTEST\\zb\\")

    def test_a_healthy_product_run_passes_and_runs_every_test(self):
        with tempfile.TemporaryDirectory() as t:
            proc, ran, rows = self.product(pathlib.Path(t), PASS2, {"ZB_SELFTEST_PROBE_WIN10": self.HEALTHY_WIN10})
            d = self.detail(proc, ran, rows)
            self.assertEqual(proc.returncode, 0, d)
            self.assertEqual(sorted(r.split()[0] for r in ran), ["a_test.py", "b_test.py"], d)
            self.assertIn("product run PASSED: 2 live tests, ASSERTS 6", proc.stderr, d)

    def test_probe_only_stays_readiness_only_and_zero_write(self):
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            order = td / "order.log"
            order.write_text("")
            proc = gts._TwoHostCase._run_probe_only(self, td, {
                "ZB_SELFTEST_ORDER_LOG": str(order),
                "ZB_SELFTEST_PROBE_WIN10": fs(drop=("root", "interactive_session", "locked"), free_gb=0)})
            log = order.read_text()
            d = f"\nrc={proc.returncode}\nstderr:\n{proc.stderr}\norder:\n{log}"
            self.assertEqual(proc.returncode, 0, "--probe-only does not judge Win10 root/free_gb/session" + d)
            self.assertNotIn("win10 session", log, "--probe-only triggers no Win10 session (zero-write)" + d)

    def test_an_unset_win10_host_is_named(self):
        with tempfile.TemporaryDirectory() as t:
            proc, ran, rows = self.product(pathlib.Path(t), PASS2, {"ZB_WIN10_HOST": None})
            self.assertStopsBeforeTests(proc, ran, rows, "no Windows host configured")
            self.assertIn("ZB_WIN10_HOST", proc.stderr, self.detail(proc, ran, rows))


if __name__ == "__main__":
    unittest.main()
