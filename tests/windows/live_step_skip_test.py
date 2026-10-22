#!/usr/bin/env python3
"""WS0.9 / D.1 (rule 7, "skip is failure"): every registered live Windows step FAILS under the gate with no host.

Plan rev 2.21, WS0.9 `live_step_skip_test.py`: run the REAL command of each registered live step (the eight
`windows-*-live` steps and the two drawer suites) with `ZB_WIN_GATE=1` and every Windows host variable unset, and
assert each exits NONZERO and says why (`ZB_WIN_GATE`). A registered step may skip cleanly only when a human runs it
standalone (no ZB_WIN_GATE), so the same command without ZB_WIN_GATE must still exit 0 (the hostless
`zig build test` stays green).

The command is the one build.zig registers: this test finds the step by name, follows `.dependOn(&<var>.step)` to
`const <var> = b.addSystemCommand(&.{ ... })`, and EXECUTES that argv. Reading build.zig only locates the command;
a step whose command cannot be found fails the test. The proof is the execution (rule 1); the lookup is a tripwire.

Hermetic: no Windows host (every ZB_WIN* variable is removed), no display. Run from the repo or export root.

Run alone:  python3 -I tests/windows/live_step_skip_test.py -v
"""
import os
import pathlib
import re
import subprocess
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]

# The registered live steps that today exit 0 with no host (plan D.1: build.zig :294-334 and the drawer suites).
LIVE_STEPS = (
    "windows-wincontain-argv-live",
    "windows-wincontain-resolve-live",
    "windows-wincontain-job-live",
    "windows-screenshot-live",
    "windows-screenshot-branches-live",
    "windows-config-flags-live",
    "windows-transport-live",
    "windows-refusal-live",
    "windows-drawer-live",
    "windows-drawer-behaviors",
)

_STR = re.compile(r'"((?:[^"\\]|\\.)*)"')


def step_argv(build_zig: str, step: str) -> list[str]:
    """The argv build.zig registers for `step` (a b.addSystemCommand). Raises LookupError if it cannot be found."""
    m = re.search(r'b\.step\(\s*"' + re.escape(step) + r'"[^;]*?\)\.dependOn\(&(\w+)\.step\)', build_zig, re.S)
    if not m:
        raise LookupError(f"no b.step({step!r}).dependOn(&<var>.step) in build.zig")
    var = m.group(1)
    c = re.search(r"const " + re.escape(var) + r"\s*=\s*b\.addSystemCommand\(&\.\{(.*?)\}\);", build_zig, re.S)
    if not c:
        raise LookupError(f"step {step!r}: no `const {var} = b.addSystemCommand(&.{{...}})` in build.zig")
    argv = [s.replace('\\"', '"').replace("\\\\", "\\") for s in _STR.findall(c.group(1))]
    if not argv:
        raise LookupError(f"step {step!r}: empty argv")
    return argv


def hostless_env(gate: bool) -> dict[str, str]:
    """The caller's environment with every Windows host variable and display variable removed."""
    env = {k: v for k, v in os.environ.items()
           if not k.startswith("ZB_WIN") and k not in ("DISPLAY", "WAYLAND_DISPLAY", "XAUTHORITY", "SSH_ASKPASS")}
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    if gate:
        env["ZB_WIN_GATE"] = "1"
    return env


class LiveStepSkipIsFailure(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build_zig = (REPO / "build.zig").read_text()

    def _run(self, step, gate):
        argv = step_argv(self.build_zig, step)
        proc = subprocess.run(argv, cwd=REPO, env=hostless_env(gate), capture_output=True, text=True,
                              timeout=600, stdin=subprocess.DEVNULL)
        return argv, proc

    def test_each_live_step_fails_under_the_gate_with_no_host(self):
        for step in LIVE_STEPS:
            with self.subTest(step=step):
                argv, proc = self._run(step, gate=True)
                detail = f"\nargv={argv}\nrc={proc.returncode}\nstdout:\n{proc.stdout[-3000:]}\nstderr:\n{proc.stderr[-3000:]}"
                self.assertNotEqual(proc.returncode, 0,
                                    f"{step}: ZB_WIN_GATE=1 with no host must exit nonzero, never skip to 0" + detail)
                self.assertIn("ZB_WIN_GATE", proc.stdout + proc.stderr,
                              f"{step}: the failure must say it is the gate's skip-is-failure rule" + detail)

    def test_each_live_step_still_skips_cleanly_standalone(self):
        for step in LIVE_STEPS:
            with self.subTest(step=step):
                argv, proc = self._run(step, gate=False)
                detail = f"\nargv={argv}\nrc={proc.returncode}\nstderr:\n{proc.stderr[-3000:]}"
                self.assertEqual(proc.returncode, 0,
                                 f"{step}: without ZB_WIN_GATE a hostless run is a human's standalone skip" + detail)


if __name__ == "__main__":
    unittest.main()
