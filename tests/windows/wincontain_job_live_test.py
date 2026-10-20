r"""Live Windows Job Object containment on the Win11 VM (bead zigBrowser-d1d, part 2).

`wincontain.Containment("job-object", kill_on_close=True, create_suspended=True)` decides WHAT the Windows
backend must do; `wincontain_win32.launch_in_job` DOES it: create the child suspended, assign it to the job,
then resume — so it is inside the job before it can run — with JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE so dropping
the job handle kills it. This test asks Windows itself (tests/windows/jobobject_oracle.py drives the real
backend on the VM) and asserts:

  * correct: the child IS in the job and IS terminated when the job handle closes (nothing outlives the job);
  * noflag (negative control): the same sequence WITHOUT KILL_ON_JOB_CLOSE leaves the child running after the
    job handle closes — proving the flag, not luck, is what kills it.

Skips cleanly (exit 0) when ZB_WIN11_HOST is unset, so the hostless Linux gate stays green. Needs no Linux
slot — the work runs on the VM. All writes stay under C:\Users\<user>\zb\.

Run live:  ZB_WIN11_HOST=127.0.0.1 ZB_WIN11_PORT=2222 python3 tests/windows/wincontain_job_live_test.py -v
"""
import json
import os
import pathlib
import secrets
import subprocess
import sys
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]


class JobLiveOracle(unittest.TestCase):
    def setUp(self):
        self.host = os.environ.get("ZB_WIN11_HOST")
        if not self.host:
            self.skipTest("ZB_WIN11_HOST unset — live VM Job Object test skipped")
        self.port = os.environ.get("ZB_WIN11_PORT", "2222")
        self.user = os.environ.get("ZB_WIN11_USER", "zbtext")
        self.key = os.environ.get("ZB_WIN_KEY", "/home/maceo/vms/win11-m8/zb_win_key")
        self.kh = os.environ.get("ZB_WIN_KNOWN_HOSTS", "/home/maceo/vms/win11-m8/known_hosts")

    def _scrub(self, *cmd):
        return ["env", "-u", "DISPLAY", "-u", "WAYLAND_DISPLAY", "-u", "XAUTHORITY", *cmd]

    def _ssh(self, *args):
        base = ["ssh", "-i", self.key, "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=yes",
                "-o", f"UserKnownHostsFile={self.kh}", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
                "-o", "ConnectionAttempts=3", "-p", self.port, f"{self.user}@{self.host}"]
        return subprocess.run(self._scrub(*base, *args), capture_output=True, text=True, timeout=120)

    def _scp(self, local, remote):
        base = ["scp", "-i", self.key, "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=yes",
                "-o", f"UserKnownHostsFile={self.kh}", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
                "-o", "ConnectionAttempts=3", "-P", self.port, local, f"{self.user}@{self.host}:{remote}"]
        return subprocess.run(self._scrub(*base), capture_output=True, text=True, timeout=120)

    def _run_mode(self, base_win, mode):
        run = self._ssh("python", f"{base_win}\\jobobject_oracle.py", mode)
        self.assertEqual(run.returncode, 0, f"oracle ({mode}) failed: {run.stdout}\n{run.stderr}")
        return json.loads(run.stdout)

    def test_job_object_contains_and_kills_on_close(self):
        rel = f"zb/job-{os.getpid()}-{secrets.token_hex(4)}"
        base_win = (f"%USERPROFILE%\\{rel}").replace("/", "\\")
        mk = self._ssh("cmd", "/c", f"mkdir {base_win}")
        self.assertEqual(mk.returncode, 0, f"mkdir failed: {mk.stderr}")
        try:
            for fn in ("wincontain_win32.py",):
                r = self._scp(str(REPO / "agent" / "host" / "zb_agent_host" / fn), f"{rel}/{fn}")
                self.assertEqual(r.returncode, 0, f"scp {fn} failed: {r.stderr}")
            r = self._scp(str(REPO / "tests" / "windows" / "jobobject_oracle.py"), f"{rel}/jobobject_oracle.py")
            self.assertEqual(r.returncode, 0, f"scp driver failed: {r.stderr}")

            correct = self._run_mode(base_win, "correct")
            noflag = self._run_mode(base_win, "noflag")
        finally:
            self._ssh("cmd", "/c", f"rmdir /s /q {base_win}")

        # Correct sequence: the child is inside the job, was running before close, and is killed on job close.
        self.assertTrue(correct["in_job"], f"child not in the job: {correct!r}")
        self.assertTrue(correct["running_before_close"], f"child not running before close: {correct!r}")
        self.assertTrue(correct["killed_on_close"], f"child NOT killed when the job handle closed: {correct!r}")

        # The real contract is "every process in the job dies", not only the direct child. cmd.exe spawns
        # ping.exe as a descendant inside the same job; it must be found running before close and gone after.
        self.assertTrue(correct["descendant_found"], f"descendant (ping.exe) not found: {correct!r}")
        self.assertTrue(correct["descendant_running_before_close"],
                        f"descendant not running before close: {correct!r}")
        self.assertTrue(correct["descendant_killed_on_close"],
                        f"descendant NOT killed when the job handle closed: {correct!r}")

        # Negative control: without KILL_ON_JOB_CLOSE the child is still in the job but survives the close —
        # proving the flag (not timing) is what terminates it. The descendant survives too.
        self.assertTrue(noflag["in_job"], f"noflag child not in the job: {noflag!r}")
        self.assertFalse(noflag["killed_on_close"], f"noflag child was killed without the flag: {noflag!r}")
        self.assertTrue(noflag["descendant_found"], f"noflag descendant not found: {noflag!r}")
        self.assertFalse(noflag["descendant_killed_on_close"],
                         f"noflag descendant was killed without the flag: {noflag!r}")


if __name__ == "__main__":
    unittest.main()
