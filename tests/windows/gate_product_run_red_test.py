#!/usr/bin/env python3
"""WS0.9 RED (UNREGISTERED): `gate.sh --product` (and the no-argument gate) is the product-run mode with fail-on-skip.

Plan rev 2.21, WS0.9 + D.1/D.2: with both hosts healthy, the gate runs every live test in the one phase list
(`tests/windows/live_phases.txt`) as `ZB_WIN_GATE=1 python3 -I <file>`, and exits 0 only if every test exited 0
AND printed `ASSERTS <n>` with n > 0 AND none exited 77 or reported a skip. Any test that exits 77, skips, prints
no `ASSERTS` line, prints `ASSERTS 0` or fails makes the gate exit nonzero NAMING the test. A readiness failure
runs no test at all. An empty phase list is zero rows, which is a failure (rule 7).

Drives the REAL gate.sh from a scratch root (ZB_GATE_ROOT) that holds a copy of the gate, its probe scripts, and a
phase list naming fake live tests; ssh/virsh are the fakes of gate_twohost_selftest.py. No Windows host, no
display. Red today: `--product` is an unknown argument and the no-argument gate exits 2 "not implemented".

The green moves these cases into gate_twohost_selftest.py (step windows-twohost-selftest), as the plan names.

Run alone:  python3 -I tests/windows/gate_product_run_red_test.py -v
"""
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import gate_twohost_selftest as two  # noqa: E402  (fake ssh/virsh + healthy probe JSON)

# Every file gate.sh reads from its root (it cats the .ps1 scripts and validates that gate.sh exists).
_GATE_FILES = ("gate.sh", "host_probe.ps1", "session_probe.ps1", "verify_task.ps1", "stage_manifest.txt")

# A fake live test: records that it ran and the ZB_WIN_GATE it saw, then behaves as `mode` says.
_FAKE_TEST = r'''
import os, sys
with open(os.environ["ZB_FAKE_RAN_LOG"], "a") as fh:
    fh.write("%s ZB_WIN_GATE=%s\n" % (os.path.basename(__file__), os.environ.get("ZB_WIN_GATE", "")))
mode = {mode!r}
if mode == "pass":
    print("PASS\tfake"); print("ASSERTS 3"); sys.exit(0)
if mode == "skip77":
    print("SKIP: no host", file=sys.stderr); sys.exit(77)
if mode == "no_asserts":
    print("PASS\tfake"); sys.exit(0)
if mode == "asserts0":
    print("ASSERTS 0"); sys.exit(0)
if mode == "fail1":
    print("ASSERTS 2"); print("FAIL\tfake", file=sys.stderr); sys.exit(1)
if mode == "unittest_skipped":
    print("ASSERTS 4"); print("OK (skipped=1)", file=sys.stderr); sys.exit(0)
if mode == "gate_only":
    # Passes ONLY when the gate exported ZB_WIN_GATE=1 to it.
    if os.environ.get("ZB_WIN_GATE") != "1":
        print("ZB_WIN_GATE not set by the gate", file=sys.stderr); sys.exit(3)
    print("ASSERTS 1"); sys.exit(0)
sys.exit(99)
'''


class ProductRunRed(two._TwoHostCase):
    """`product_run_fails_on_skip` and its siblings (plan WS0.9)."""

    def _root(self, td, tests):
        """A scratch gate root: the real gate files plus a phase list of fake tests {name: mode}."""
        root = td / "root"
        (root / "tests" / "windows" / "fake").mkdir(parents=True)
        for name in _GATE_FILES:
            shutil.copy2(HERE / name, root / "tests" / "windows" / name)
        lines = []
        for name, mode in tests:
            rel = f"tests/windows/fake/{name}"
            (root / rel).write_text(_FAKE_TEST.format(mode=mode))
            lines.append(rel)
        (root / "tests" / "windows" / "live_phases.txt").write_text(
            "# fake phase list (selftest)\n" + "".join(l + "\n" for l in lines))
        return root

    def _run_product(self, td, tests, extra=None, args=("--product",)):
        root = self._root(td, tests)
        ran = td / "ran.log"
        ran.write_text("")
        env = {"ZB_FAKE_RAN_LOG": str(ran)}
        env.update(extra or {})
        proc = self._run_args(td, root, env, args)
        return proc, ran.read_text().splitlines()

    def _run_args(self, td, root, extra, args):
        home = td / "home"; home.mkdir(exist_ok=True)
        env = {
            "ZB_GATE_ROOT": str(root),
            "PATH": two._fakes(td) + os.pathsep + two._BASE_PATH, "HOME": str(home),
            "ZB_WIN11_HOST": "127.0.0.1", "ZB_WIN11_PORT": "2222", "ZB_WIN11_DOMAIN": "win11-m8",
            "ZB_WIN11_USER": "zbtext", "ZB_WIN11_MARKER": two.VM_MARKER,
            "ZB_WIN11_SNAPSHOT": "pre-4dr-toolchain-2026-10-20",
            "ZB_WIN10_HOST": "100.123.34.15", "ZB_WIN10_PORT": "22", "ZB_WIN10_USER": "zbtest",
            "ZB_WIN10_MARKER": two.FS_MARKER,
            "ZB_WIN11_KEY": str(td / "win11.key"), "ZB_WIN11_KNOWN_HOSTS": str(td / "win11.kh"),
            "ZB_WIN10_KEY": str(td / "win10.key"), "ZB_WIN10_KNOWN_HOSTS": str(td / "win10.kh"),
            "ZB_SELFTEST_WIN10_CALLS": str(td / "win10.calls"),
            "ZB_SELFTEST_PROBE_WIN11": two._vm_probe(),
            "ZB_SELFTEST_PROBE_WIN10": two._fs_probe(),
        }
        for n in ("win11.key", "win11.kh", "win10.key", "win10.kh"):
            (td / n).write_text("x")
        env.update(extra)
        env = {k: v for k, v in env.items() if v is not None}
        return subprocess.run(["bash", str(root / "tests" / "windows" / "gate.sh"), *args], env=env,
                              capture_output=True, text=True, timeout=120, stdin=subprocess.DEVNULL)

    @staticmethod
    def _detail(proc):
        return f"\nrc={proc.returncode}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"

    def test_healthy_product_run_passes_and_runs_every_test(self):
        with tempfile.TemporaryDirectory() as t:
            proc, ran = self._run_product(pathlib.Path(t), [("a_test.py", "pass"), ("b_test.py", "pass")])
            self.assertEqual(proc.returncode, 0, "every test passed with ASSERTS>0: the gate must pass" + self._detail(proc))
            self.assertEqual(sorted(r.split()[0] for r in ran), ["a_test.py", "b_test.py"], self._detail(proc))

    def test_no_argument_gate_is_the_product_run(self):
        with tempfile.TemporaryDirectory() as t:
            proc, ran = self._run_product(pathlib.Path(t), [("a_test.py", "pass")], args=())
            self.assertEqual(proc.returncode, 0, "the no-argument gate is the product run" + self._detail(proc))
            self.assertEqual(len(ran), 1, self._detail(proc))

    def test_every_test_runs_with_zb_win_gate_1(self):
        with tempfile.TemporaryDirectory() as t:
            proc, ran = self._run_product(pathlib.Path(t), [("g_test.py", "gate_only")],
                                          extra={"ZB_WIN_GATE": None})
            self.assertEqual(proc.returncode, 0, "the gate must export ZB_WIN_GATE=1 to each test" + self._detail(proc))
            self.assertEqual(ran, ["g_test.py ZB_WIN_GATE=1"], self._detail(proc))

    def test_product_run_fails_on_skip(self):
        with tempfile.TemporaryDirectory() as t:
            proc, ran = self._run_product(pathlib.Path(t), [("a_test.py", "pass"), ("skip_test.py", "skip77")])
            self.assertNotEqual(proc.returncode, 0, "an exit 77 must fail the gate" + self._detail(proc))
            self.assertIn("skipped", proc.stderr, self._detail(proc))
            self.assertIn("skip_test.py", proc.stderr, "the gate must name the skipped test" + self._detail(proc))

    def test_unittest_skip_with_rc0_fails(self):
        with tempfile.TemporaryDirectory() as t:
            proc, _ = self._run_product(pathlib.Path(t), [("u_test.py", "unittest_skipped")])
            self.assertNotEqual(proc.returncode, 0, "a reported skip must fail the gate" + self._detail(proc))
            self.assertIn("skipped", proc.stderr, self._detail(proc))
            self.assertIn("u_test.py", proc.stderr, self._detail(proc))

    def test_no_asserts_line_fails(self):
        with tempfile.TemporaryDirectory() as t:
            proc, _ = self._run_product(pathlib.Path(t), [("n_test.py", "no_asserts")])
            self.assertNotEqual(proc.returncode, 0, "no ASSERTS line must fail the gate" + self._detail(proc))
            self.assertIn("ASSERTS", proc.stderr, self._detail(proc))
            self.assertIn("n_test.py", proc.stderr, self._detail(proc))

    def test_asserts_zero_fails(self):
        with tempfile.TemporaryDirectory() as t:
            proc, _ = self._run_product(pathlib.Path(t), [("z_test.py", "asserts0")])
            self.assertNotEqual(proc.returncode, 0, "ASSERTS 0 must fail the gate" + self._detail(proc))
            self.assertIn("ASSERTS", proc.stderr, self._detail(proc))
            self.assertIn("z_test.py", proc.stderr, self._detail(proc))

    def test_failing_test_fails_and_is_named(self):
        with tempfile.TemporaryDirectory() as t:
            proc, _ = self._run_product(pathlib.Path(t), [("f_test.py", "fail1"), ("a_test.py", "pass")])
            self.assertNotEqual(proc.returncode, 0, self._detail(proc))
            self.assertIn("f_test.py", proc.stderr, self._detail(proc))

    def test_empty_phase_list_is_zero_rows_and_fails(self):
        with tempfile.TemporaryDirectory() as t:
            proc, ran = self._run_product(pathlib.Path(t), [])
            self.assertNotEqual(proc.returncode, 0, "zero rows is a failure (rule 7)" + self._detail(proc))
            self.assertIn("no live tests", proc.stderr, self._detail(proc))

    def test_readiness_failure_runs_no_test(self):
        with tempfile.TemporaryDirectory() as t:
            proc, ran = self._run_product(pathlib.Path(t), [("a_test.py", "pass")],
                                          extra={"ZB_SELFTEST_VIRSH_STATE": "shut off"})
            self.assertNotEqual(proc.returncode, 0, self._detail(proc))
            self.assertIn("Win11 VM win11-m8 is shut off", proc.stderr, self._detail(proc))
            self.assertEqual(ran, [], "no product test may run before readiness passes" + self._detail(proc))

    def test_unset_win11_host_names_no_windows_host(self):
        with tempfile.TemporaryDirectory() as t:
            proc, ran = self._run_product(pathlib.Path(t), [("a_test.py", "pass")],
                                          extra={"ZB_WIN11_HOST": None})
            self.assertNotEqual(proc.returncode, 0, self._detail(proc))
            self.assertIn("no Windows host configured", proc.stderr, self._detail(proc))
            self.assertEqual(ran, [], self._detail(proc))


if __name__ == "__main__":
    unittest.main()
