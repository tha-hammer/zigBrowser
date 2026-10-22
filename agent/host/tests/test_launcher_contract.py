"""WS7.3 [L] — RED-FIRST for the portable launcher contract (bd zigBrowser Windows launch, plan line 1664).

On Windows a native `zb-claude.exe` (Zig) replaces the Python `zb-claude` wrapper: Windows has no `exec`, and the
Agent SDK refuses `.bat`/`.cmd` shims. The portable CONTRACT (tested here on POSIX; the [W] e2e drives the real exe):

  - the child's exit code IS the launcher's exit code,
  - zero orphans (the launcher waits for and reaps the child),
  - the child is launched with argv == [claude_exe, *args] (no shim wrapper),
  - a `.bat`/`.cmd` target is refused (no shim).

UNREGISTERED (no gate step builds this). RED now: `zb_agent_host.launcher` does not exist (ImportError). The green
adds the portable launcher contract module; the Zig exe must meet the same contract on Windows. No VM, no Macs.

MUTANT (returns-0-always): a launcher that returns 0 regardless of the child reds the exit-propagation row.
"""

import json
import os
import stat
import sys
import tempfile
import time
import unittest
from pathlib import Path

import support  # noqa: F401  (puts agent/host on sys.path)

from zb_agent_host import launcher  # RED: the portable launcher contract module does not exist yet


def _write_fake_claude(dirpath: Path, exit_code: int) -> Path:
    """An executable stand-in for claude.exe: records its argv + pid, sleeps briefly, exits with `exit_code`."""
    p = dirpath / "fake_claude"
    p.write_text(
        "#!/usr/bin/env python3\n"
        "import os, sys, json, pathlib, time\n"
        "rec = pathlib.Path(sys.argv[1])\n"
        "rec.write_text(json.dumps({'argv': sys.argv, 'pid': os.getpid()}))\n"
        "time.sleep(0.3)\n"
        f"sys.exit({exit_code})\n"
    )
    p.chmod(0o755)
    return p


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


class LauncherArgvContract(unittest.TestCase):
    def test_argv_is_exactly_claude_exe_then_args(self):
        self.assertEqual(
            launcher.build_argv("/opt/zb/claude", ["--print", "hi there"]),
            ["/opt/zb/claude", "--print", "hi there"],
        )

    def test_a_bat_or_cmd_shim_is_refused(self):
        for bad in ("claude.bat", "claude.cmd", r"C:\x\claude.BAT", r"C:\x\claude.Cmd", "/opt/claude.bat"):
            with self.assertRaises(launcher.ShimRefused):
                launcher.build_argv(bad, [])


class LauncherRunContract(unittest.TestCase):
    def test_exit_code_propagates_argv_passthrough_and_zero_orphans(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            fake = _write_fake_claude(d, 7)
            rec = str(d / "record.json")
            args = [rec, "--flag", "value"]

            rc = launcher.run(str(fake), args)

            # the child's exit code IS the launcher's exit code (returns-0-always mutant -> rc 0 != 7 -> red)
            self.assertEqual(rc, 7)

            record = json.loads(Path(rec).read_text())
            # argv == [claude_exe, *args]: the child saw exactly the launcher target then the args, no shim
            self.assertEqual(record["argv"], [str(fake), *args])
            # zero orphans: the launcher waited for and reaped the child (a don't-wait mutant leaves it alive)
            self.assertFalse(_alive(record["pid"]))


if __name__ == "__main__":
    unittest.main()
