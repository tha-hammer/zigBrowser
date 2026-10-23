#!/usr/bin/env python3
"""WS0.4 RED (UNREGISTERED): the scheduled-task runner starts a relative program from the run's own folder.

Plan rev 2.21, WS0.4 ("interactive launches are real"). The Win11 m8 run at 2df192b (approval 1570d49) failed
m8_reply_channel_test: the driver passes `--binary zigBrowser.exe`, the runner wrote
`Set-Location <cwd>` then `Start-Process -FilePath 'zigBrowser.exe'`, and PowerShell answered "The system cannot
find the file specified". Set-Location changes PowerShell's location, not the process directory Start-Process
resolves a bare FilePath against (cause SUSPECTED until the live re-run).

Hostless: drives the REAL slice2_common.run_windows_interactive_to_exit (the PowerShell scheduled-task runner) in a
child Python, with gate_selftest.py's recording fake schtasks/taskkill on PATH and the same `os` proxy (slice2_common's
own `os` reports name "nt"; everything else is the real os). It then reads the task wrapper the runner wrote (the
runner's output, the script the scheduled task executes) and checks the program it starts:
  - a relative program that exists in the run's cwd is started by its ABSOLUTE path in that cwd;
  - a bare name that is NOT in the cwd (a PATH program such as powershell.exe) is left as given.

The green moves these cases into gate_selftest.py (step windows-gate-selftest).

Run alone:  python3 -I tests/windows/runner_ws04_path_red_test.py -v
"""
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(HERE))
import gate_selftest as gs  # noqa: E402  (the WS0.4 fake schtasks/taskkill)

_CHILD = r"""
import json, os, sys, pathlib
sys.path.insert(0, sys.argv[1])
import slice2_common as s

class _WindowsName:
    name = "nt"
    def __getattr__(self, attr):
        return getattr(os, attr)

s.os = _WindowsName()
r = s.run_windows_interactive_to_exit([sys.argv[2], "file:///x"], {}, 10, cwd=pathlib.Path.cwd())
print(json.dumps({"returncode": r.returncode, "stderr": r.stderr_lines}))
"""


class RunnerStartsRelativeProgramFromCwdRed(unittest.TestCase):
    def _wrapper_for(self, program, make_file):
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            bindir = td / "bin"; bindir.mkdir()
            state = td / "state"; state.mkdir()
            work = td / "work"; work.mkdir()
            for name, body in (("schtasks", gs._FAKE_SCHTASKS_04), ("taskkill", gs._FAKE_TASKKILL_04)):
                (bindir / name).write_text(body); (bindir / name).chmod(0o755)
            if make_file:
                (work / program).write_text("fake exe")
            env = {"PATH": f"{bindir}:/usr/bin:/bin", "HOME": str(td), "TMPDIR": str(td),
                   "ZB_FAKE_LOG": str(td / "calls.log"), "ZB_FAKE_STATE": str(state)}
            proc = subprocess.run(["python3", "-I", "-c", _CHILD, str(REPO / "tests" / "e2e"), program], cwd=work,
                                  env=env, capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL)
            detail = f"\nchild rc={proc.returncode}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
            self.assertEqual(proc.returncode, 0, "the child driver itself must not crash" + detail)
            wrappers = list(td.glob("zb_m8_task_*/run.ps1"))
            self.assertEqual(len(wrappers), 1, "the runner wrote one task wrapper" + detail)
            return wrappers[0].read_text(encoding="utf-8"), work, detail

    def test_relative_program_in_cwd_is_started_by_absolute_path(self):
        script, work, detail = self._wrapper_for("zigBrowser.exe", make_file=True)
        want = f"Start-Process -FilePath '{work / 'zigBrowser.exe'}' "
        self.assertIn(want, script, "a program found in the run's cwd must be started by its absolute path" + detail
                      + "\nwrapper:\n" + script)

    def test_path_program_not_in_cwd_is_left_as_given(self):
        script, _, detail = self._wrapper_for("powershell.exe", make_file=False)
        self.assertIn("Start-Process -FilePath 'powershell.exe' ", script, detail + "\nwrapper:\n" + script)


if __name__ == "__main__":
    unittest.main()
