#!/usr/bin/env python3
r"""WS1.2 reds (UNREGISTERED until the WS1.2 green): the m8 harness fails closed under the gate.

Plan rev 2.21, WS1.2 + WS0.4 item 6 + D.1 (thoughts/searchable/shared/plans/2026-10-19-windows-launch-tdd-plan.md).

  * m8_precondition_missing: each of the three m8 tests (tests/e2e/m8_render_test.py, m8_reply_channel_test.py,
    m8_load_fail_test.py) run with ZB_WIN_GATE=1 and a missing precondition (here: not Windows) must exit 1 and
    name ZB_WIN_GATE on stderr. Today they `return SKIP_EXIT` (77). Mutant: leave SKIP_EXIT in place => red.
  * Control: without ZB_WIN_GATE the same run still skips with 77 (a human running a test standalone may skip;
    such a run is never counted as a Windows row, D.1).
  * The Linux-side live driver tests/windows/m8_live_test.py (the step command of windows-m8-*-live): with
    ZB_WIN_GATE=1 and no host configured it exits nonzero and prints `no Windows host configured`; standalone
    (no ZB_WIN_GATE) it reports NOT RUN and exits 77. Today the driver does not exist.
  * Live (only when ZB_WIN11_HOST is set; the run needs RoseCat/NavyCanyon exact-commit approval + an
    orchestrator release): the driver stages the exe and the m8 tests under C:\Users\<user>\zb\runs\<id>\,
    runs each with ZB_WIN_GATE=1 in the host's interactive session, and every test prints PASS and
    `ASSERTS <n>` with n > 0; the driver exits 0. Today the m8 tests print no ASSERTS line.

Every child runs with DISPLAY, WAYLAND_DISPLAY, XAUTHORITY and SSH_ASKPASS removed.

Run alone:  python3 -I tests/windows/m8_gate_red_test.py -v
"""
import os
import pathlib
import re
import subprocess
import sys
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]
M8_TESTS = ("m8_render_test.py", "m8_reply_channel_test.py", "m8_load_fail_test.py")
DRIVER = REPO / "tests" / "windows" / "m8_live_test.py"
SKIP_EXIT = 77
HOST_VARS = ("ZB_WIN11_HOST", "ZB_WIN10_HOST", "ZB_WIN_EXE")
SCRUB = ("DISPLAY", "WAYLAND_DISPLAY", "XAUTHORITY", "SSH_ASKPASS")


def _env(gate: bool, keep_hosts: bool = False) -> dict:
    env = {k: v for k, v in os.environ.items() if k not in SCRUB}
    if not keep_hosts:
        for k in HOST_VARS:
            env.pop(k, None)
    env.pop("ZB_WIN_GATE", None)
    env.pop("ZB_ENABLE_M8_E2E", None)
    if gate:
        env["ZB_WIN_GATE"] = "1"
    return env


def _run_m8(name: str, gate: bool) -> subprocess.CompletedProcess:
    # -E -s, not -I: the m8 tests import slice2_common from their own directory.
    return subprocess.run([sys.executable, "-E", "-s", str(REPO / "tests" / "e2e" / name)],
                          cwd=REPO, env=_env(gate), capture_output=True, text=True, timeout=60)


def _run_driver(gate: bool, keep_hosts: bool = False, timeout: int = 60) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, "-I", str(DRIVER)], cwd=REPO, env=_env(gate, keep_hosts),
                          capture_output=True, text=True, timeout=timeout)


class M8PreconditionMissing(unittest.TestCase):
    def test_gate_turns_a_missing_precondition_into_exit_1(self):
        for name in M8_TESTS:
            with self.subTest(test=name):
                p = _run_m8(name, gate=True)
                self.assertEqual(p.returncode, 1,
                                 f"{name} under ZB_WIN_GATE=1 must exit 1, got {p.returncode}; stderr={p.stderr!r}")
                self.assertIn("ZB_WIN_GATE", p.stderr, f"{name} must name ZB_WIN_GATE on stderr: {p.stderr!r}")

    def test_standalone_run_still_skips_with_77(self):
        for name in M8_TESTS:
            with self.subTest(test=name):
                p = _run_m8(name, gate=False)
                self.assertEqual(p.returncode, SKIP_EXIT,
                                 f"{name} standalone must skip with 77, got {p.returncode}; stderr={p.stderr!r}")


class M8LiveDriverHostless(unittest.TestCase):
    def test_gated_driver_without_host_fails_closed(self):
        p = _run_driver(gate=True)
        self.assertNotEqual(p.returncode, 0, f"gated driver with no host must fail: {p.stdout!r} {p.stderr!r}")
        self.assertNotEqual(p.returncode, SKIP_EXIT, "a gated run must never report a skip")
        self.assertIn("no Windows host configured", p.stderr)

    def test_standalone_driver_without_host_reports_not_run(self):
        p = _run_driver(gate=False)
        self.assertEqual(p.returncode, SKIP_EXIT, f"standalone hostless driver must exit 77: {p.stderr!r}")
        self.assertIn("NOT RUN: no Windows host configured", p.stderr)


class M8LiveDriverOnHost(unittest.TestCase):
    def test_every_m8_test_passes_with_asserts_on_the_host(self):
        if not os.environ.get("ZB_WIN11_HOST"):
            self.skipTest("ZB_WIN11_HOST unset: the live leg needs an approved, released host run")
        p = _run_driver(gate=True, keep_hosts=True, timeout=900)
        sys.stderr.write(p.stdout + p.stderr)
        self.assertEqual(p.returncode, 0, "the gated driver must pass on the host")
        for name in M8_TESTS:
            stem = name[:-len(".py")]
            m = re.search(rf"^RESULT\t{re.escape(stem)}\tPASS\tASSERTS (\d+)$", p.stdout, re.M)
            self.assertIsNotNone(m, f"{stem}: no PASS + ASSERTS result row")
            self.assertGreater(int(m.group(1)), 0, f"{stem}: ASSERTS must be > 0")


if __name__ == "__main__":
    unittest.main()
