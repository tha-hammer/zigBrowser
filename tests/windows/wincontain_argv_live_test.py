"""Live Windows argv oracle: join_argv round-trips through the REAL CommandLineToArgvW on the Win11 VM.

RoseCat's BLOCKER-for-tests on wincontain: the Linux unit test's reference parser is another hand-written
implementation of the same assumed grammar, not an independent oracle. This test asks Windows itself. For a
battery of argv lists (including empty args, quotes, long backslash runs, trailing slashes, spaces/tabs, and
generated cases), it builds a command line `prog.exe <join_argv(args)>`, runs cmdline_oracle.py on the VM
(which calls CommandLineToArgvW), and asserts the parsed argv[1:] equals the original args. A fixed,
quote/space-free argv[0] is prepended and dropped so argv[0]'s special parsing never confounds the check.

Skips cleanly (exit 0) when ZB_WIN11_HOST is unset, so it is safe in a hostless Linux gate (registered as
windows-wincontain-argv-live). Needs no Linux slot — the work runs on the VM.

Run live:  ZB_WIN11_HOST=127.0.0.1 ZB_WIN11_PORT=2222 python3 tests/windows/wincontain_argv_live_test.py -v
"""
import json
import os
import pathlib
import random
import subprocess
import sys
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "agent" / "host"))
from zb_agent_host import wincontain as wc  # noqa: E402

PROG = "prog.exe"  # a fixed argv[0]: no spaces/quotes, so CommandLineToArgvW parses it cleanly and we drop it


def _batteries():
    fixed = [
        ["abc"],
        ["a b", "c"],
        ['a"b'],
        ["a\\b"],
        ["a\\", "b"],
        ["a b\\"],
        ["", "x"],
        ["only-empty", ""],
        ['c:\\path with space\\', 'arg"2', "a\\\\b", "tab\there"],
        ["C:\\Program Files\\zig\\zig.exe", "build", "-Dfoo=a b", "-Dp=a\\b\\"],
        ['weird " \\ "" \\\\" end'],
        ["trailing\\\\\\", "mid\\\\\"q"],
    ]
    rng = random.Random(20261020)
    alphabet = list('ab \t"\\x')
    for _ in range(40):
        args = []
        for _ in range(rng.randint(1, 4)):
            args.append("".join(rng.choice(alphabet) for _ in range(rng.randint(0, 6))))
        fixed.append(args)
    return fixed


class ArgvLiveOracle(unittest.TestCase):
    def setUp(self):
        self.host = os.environ.get("ZB_WIN11_HOST")
        if not self.host:
            self.skipTest("ZB_WIN11_HOST unset — live VM argv oracle skipped")
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

    def test_join_argv_roundtrips_through_commandlinetoargvw(self):
        batteries = _batteries()
        lines = [PROG + " " + wc.join_argv(args) for args in batteries]
        payload = {"lines": lines}

        import tempfile
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            (td / "batteries.json").write_text(json.dumps(payload), encoding="utf-8")
            mk = self._ssh("cmd", "/c", r"if not exist %USERPROFILE%\zb\argv mkdir %USERPROFILE%\zb\argv")
            self.assertEqual(mk.returncode, 0, f"mkdir failed: {mk.stderr}")
            for f in ("batteries.json",):
                r = self._scp(str(td / f), f"zb/argv/{f}")
                self.assertEqual(r.returncode, 0, f"scp {f} failed: {r.stderr}")
            r = self._scp(str(REPO / "tests" / "windows" / "cmdline_oracle.py"), "zb/argv/cmdline_oracle.py")
            self.assertEqual(r.returncode, 0, f"scp oracle failed: {r.stderr}")

            run = self._ssh("python", r"%USERPROFILE%\zb\argv\cmdline_oracle.py",
                            r"%USERPROFILE%\zb\argv\batteries.json")
            self.assertEqual(run.returncode, 0, f"oracle failed: {run.stdout}\n{run.stderr}")
            parsed = json.loads(run.stdout)["parsed"]

            # tidy up our own staging
            self._ssh("cmd", "/c", r"rmdir /s /q %USERPROFILE%\zb\argv")

        self.assertEqual(len(parsed), len(batteries))
        for args, got in zip(batteries, parsed):
            self.assertEqual(got[0], PROG, "argv[0] should parse back to the fixed program name")
            self.assertEqual(got[1:], args,
                             f"round-trip mismatch for {args!r}: line={PROG + ' ' + wc.join_argv(args)!r} -> {got!r}")


if __name__ == "__main__":
    unittest.main()
