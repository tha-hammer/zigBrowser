#!/usr/bin/env python3
"""WS0.9 / D.1 (rule 7, "skip is failure"): every registered live Windows step FAILS under the gate with no host.

Plan rev 2.21, WS0.9 `live_step_skip_test.py` (step `windows-live-step-skip`, in `zig build test`): run the REAL
command of every registered live step with `ZB_WIN_GATE=1` and every Windows host variable unset, and assert each
exits NONZERO and says why. The live steps are found at run time, so a step added later is covered too: every
`windows-*-live` step plus the drawer suite `windows-drawer-behaviors` (the `windows-live` aggregate itself is not a
command). Every entry of the phase list `tests/windows/live_phases.txt` (what `gate.sh --product` and `windows-live`
run) is also run that way. A step that is part of the hostless `zig build test` may skip cleanly only when run
standalone (no ZB_WIN_GATE), so the same command without ZB_WIN_GATE must still exit 0.

Locating a step's command reads build.zig (a labelled lookup, a tripwire): it follows `.dependOn(&<var>.step)` to
`const <var> = b.addSystemCommand(&.{ ... })`, and a step whose command cannot be found fails. The proof is the
EXECUTION of that argv (rule 1).

Also drives the two helpers: `tests/windows/live_gate.py` (`main()` prints the count of EXECUTED assertions and
fails a skip or zero assertions under the gate) and `slice2_common.gate_skip_exit`, the exit-code helper of the live
tests that run on Windows (m8).

Hermetic: every ZB_WIN* variable is removed, so no host is contacted; no display. Run from the repo or export root.

Run alone:  python3 -I tests/windows/live_step_skip_test.py -v
"""
import contextlib
import io
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]
PHASES = REPO / "tests" / "windows" / "live_phases.txt"
sys.path.insert(0, str(REPO / "tests" / "e2e"))
import slice2_common  # noqa: E402

# The steps D.1 names (build.zig, rev 2.21): discovery must find at least these.
KNOWN_LIVE_STEPS = {
    "windows-wincontain-argv-live", "windows-wincontain-resolve-live", "windows-wincontain-job-live",
    "windows-screenshot-live", "windows-screenshot-branches-live", "windows-config-flags-live",
    "windows-transport-live", "windows-refusal-live", "windows-drawer-live", "windows-drawer-behaviors",
}
GATE_SAYS = ("ZB_WIN_GATE", "no Windows host configured")

_STR = re.compile(r'"((?:[^"\\]|\\.)*)"')


def live_steps(build_zig: str) -> list[str]:
    names = re.findall(r'b\.step\(\s*"(windows-[\w-]+)"', build_zig)
    return sorted({n for n in names if (n.endswith("-live") and n != "windows-live") or n == "windows-drawer-behaviors"})


def _step_var(build_zig: str, step: str) -> str:
    m = re.search(r'b\.step\(\s*"' + re.escape(step) + r'"[^;]*?\)\.dependOn\(&(\w+)\.step\)', build_zig, re.S)
    if not m:
        raise LookupError(f"no b.step({step!r}).dependOn(&<var>.step) in build.zig")
    return m.group(1)


def step_argv(build_zig: str, step: str) -> list[str]:
    """The argv build.zig registers for `step` (a b.addSystemCommand). Raises LookupError if it cannot be found."""
    var = _step_var(build_zig, step)
    c = re.search(r"const " + re.escape(var) + r"\s*=\s*b\.addSystemCommand\(&\.\{(.*?)\}\);", build_zig, re.S)
    if not c:
        raise LookupError(f"step {step!r}: no `const {var} = b.addSystemCommand(&.{{...}})` in build.zig")
    argv = [s.replace('\\"', '"').replace("\\\\", "\\") for s in _STR.findall(c.group(1))]
    if not argv:
        raise LookupError(f"step {step!r}: empty argv")
    return argv


def in_zig_build_test(build_zig: str, step: str) -> bool:
    return re.search(r"test_step\.dependOn\(&" + re.escape(_step_var(build_zig, step)) + r"\.step\)", build_zig) is not None


def phase_entries() -> list[str]:
    return [l.strip() for l in PHASES.read_text().splitlines() if l.strip() and not l.strip().startswith("#")]


def hostless_env(gate: bool) -> dict[str, str]:
    """The caller's environment with every Windows host variable and display variable removed."""
    env = {k: v for k, v in os.environ.items()
           if not k.startswith("ZB_WIN") and k not in ("DISPLAY", "WAYLAND_DISPLAY", "XAUTHORITY", "SSH_ASKPASS")}
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    if gate:
        env["ZB_WIN_GATE"] = "1"
    return env


def run(argv, gate):
    return subprocess.run(argv, cwd=REPO, env=hostless_env(gate), capture_output=True, text=True,
                          timeout=600, stdin=subprocess.DEVNULL)


def detail(argv, proc):
    return f"\nargv={argv}\nrc={proc.returncode}\nstdout:\n{proc.stdout[-3000:]}\nstderr:\n{proc.stderr[-3000:]}"


class LiveStepSkipIsFailure(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build_zig = (REPO / "build.zig").read_text()
        cls.steps = live_steps(cls.build_zig)

    def test_discovery_finds_every_known_live_step(self):
        self.assertTrue(KNOWN_LIVE_STEPS <= set(self.steps), f"missing: {KNOWN_LIVE_STEPS - set(self.steps)}")

    def test_each_live_step_fails_under_the_gate_with_no_host(self):
        for step in self.steps:
            with self.subTest(step=step):
                argv = step_argv(self.build_zig, step)
                proc = run(argv, gate=True)
                self.assertNotEqual(proc.returncode, 0,
                                    f"{step}: ZB_WIN_GATE=1 with no host must exit nonzero, never skip to 0" + detail(argv, proc))
                self.assertTrue(any(s in proc.stdout + proc.stderr for s in GATE_SAYS),
                                f"{step}: the failure must say it is the gate's skip-is-failure rule" + detail(argv, proc))

    def test_each_phase_entry_fails_under_the_gate_with_no_host(self):
        entries = phase_entries()
        self.assertTrue(entries, "the phase list is empty")
        for entry in entries:
            with self.subTest(entry=entry):
                argv = ["python3", "-I", entry]
                proc = run(argv, gate=True)
                self.assertNotEqual(proc.returncode, 0, f"{entry}: must fail under the gate with no host" + detail(argv, proc))
                self.assertIn("ZB_WIN_GATE", proc.stdout + proc.stderr, detail(argv, proc))

    def test_each_hostless_test_step_still_skips_cleanly_standalone(self):
        steps = [s for s in self.steps if in_zig_build_test(self.build_zig, s)]
        self.assertTrue(steps, "no live step is in zig build test")
        for step in steps:
            with self.subTest(step=step):
                argv = step_argv(self.build_zig, step)
                proc = run(argv, gate=False)
                self.assertEqual(proc.returncode, 0,
                                 f"{step}: without ZB_WIN_GATE a hostless run is a human's standalone skip" + detail(argv, proc))


class GateSkipExit(unittest.TestCase):
    """slice2_common.gate_skip_exit: 1 under the gate, SKIP_EXIT (77) standalone; the reason always reaches stderr."""

    def _call(self, gate):
        saved = os.environ.pop("ZB_WIN_GATE", None)
        if gate:
            os.environ["ZB_WIN_GATE"] = "1"
        err = io.StringIO()
        try:
            with contextlib.redirect_stderr(err):
                return slice2_common.gate_skip_exit("SKIP: no host"), err.getvalue()
        finally:
            os.environ.pop("ZB_WIN_GATE", None)
            if saved is not None:
                os.environ["ZB_WIN_GATE"] = saved

    def test_under_the_gate_a_missing_precondition_exits_1(self):
        code, err = self._call(gate=True)
        self.assertEqual(code, 1, err)
        self.assertIn("SKIP: no host", err)
        self.assertIn("ZB_WIN_GATE=1: precondition missing", err)

    def test_standalone_a_missing_precondition_skips_77(self):
        code, err = self._call(gate=False)
        self.assertEqual(code, slice2_common.SKIP_EXIT, err)
        self.assertEqual(code, 77)
        self.assertIn("SKIP: no host", err)
        self.assertNotIn("ZB_WIN_GATE", err)


_LIVE_GATE_MODULE = r'''
import os, sys, unittest
sys.path.insert(0, {windows!r})
import live_gate
mode = {mode!r}

class T(unittest.TestCase):
    def test_it(self):
        if mode == "three":
            self.assertTrue(True); self.assertIn("a", "abc"); self.assertEqual("x\ny", "x\ny")  # assertEqual dispatches once
        elif mode == "none":
            pass
        elif mode == "precondition":
            live_gate.skip_or_fail(self, "ZB_WIN11_HOST unset")
            self.assertTrue(True)
        elif mode == "plain_skip":
            self.assertTrue(True)
            self.skipTest("not a gate precondition")

live_gate.main()
'''


class LiveGateMain(unittest.TestCase):
    """tests/windows/live_gate.py: `ASSERTS <n>` counts EXECUTED assert* calls; under the gate a skip or zero
    assertions exits nonzero; standalone, a precondition skip exits 0."""

    def _run(self, mode, gate, td):
        f = pathlib.Path(td) / f"m_{mode}.py"
        f.write_text(_LIVE_GATE_MODULE.format(windows=str(REPO / "tests" / "windows"), mode=mode))
        return run(["python3", "-I", str(f)], gate=gate)

    def test_counts_executed_assertions(self):
        with tempfile.TemporaryDirectory() as td:
            for gate in (False, True):
                proc = self._run("three", gate, td)
                self.assertEqual(proc.returncode, 0, detail("three", proc))
                self.assertIn("ASSERTS 3\n", proc.stdout, detail("three", proc))

    def test_zero_assertions_fail_only_under_the_gate(self):
        with tempfile.TemporaryDirectory() as td:
            proc = self._run("none", True, td)
            self.assertNotEqual(proc.returncode, 0, detail("none", proc))
            self.assertIn("ASSERTS 0\n", proc.stdout, detail("none", proc))
            self.assertIn("zero assertions is a failure under the gate", proc.stderr, detail("none", proc))
            self.assertEqual(self._run("none", False, td).returncode, 0)

    def test_precondition_fails_under_the_gate_and_skips_standalone(self):
        with tempfile.TemporaryDirectory() as td:
            proc = self._run("precondition", True, td)
            self.assertNotEqual(proc.returncode, 0, detail("precondition", proc))
            self.assertIn("ZB_WIN_GATE=1: ZB_WIN11_HOST unset; a skip is a failure under the gate", proc.stderr)
            proc = self._run("precondition", False, td)
            self.assertEqual(proc.returncode, 0, detail("precondition", proc))
            self.assertIn("skipped=1", proc.stderr, detail("precondition", proc))

    def test_any_skip_fails_under_the_gate(self):
        with tempfile.TemporaryDirectory() as td:
            proc = self._run("plain_skip", True, td)
            self.assertNotEqual(proc.returncode, 0, detail("plain_skip", proc))
            self.assertIn("1 skipped", proc.stderr, detail("plain_skip", proc))
            self.assertEqual(self._run("plain_skip", False, td).returncode, 0)


if __name__ == "__main__":
    unittest.main()
