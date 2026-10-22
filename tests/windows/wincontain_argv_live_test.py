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
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "windows"))
import live_gate  # noqa: E402  ZB_WIN_GATE=1: a missing host fails instead of skipping; prints ASSERTS <n>

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
        ["accénted café", "naïve"],                         # non-ASCII (BMP)
        ["astral \U0001F600 end", "\U0001F680x"],            # astral (surrogate pairs in UTF-16)
        ["\\" * 9 + '"' + "\\" * 4, "q" + '"' * 3],          # long backslash runs around quotes
    ]
    rng = random.Random(20261020)  # deterministic
    alphabet = list('ab \t"\\xé\U0001F600')
    for _ in range(40):
        args = []
        for _ in range(rng.randint(1, 4)):
            args.append("".join(rng.choice(alphabet) for _ in range(rng.randint(0, 10))))
        fixed.append(args)
    return fixed


class ArgvLiveOracle(unittest.TestCase):
    def setUp(self):
        self.host = os.environ.get("ZB_WIN11_HOST")
        if not self.host:
            live_gate.skip_or_fail(self, "ZB_WIN11_HOST unset — live VM argv oracle skipped")
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
        self.assertGreater(len(batteries), 0, "the battery must be non-empty")
        lines = [PROG + " " + wc.join_argv(args) for args in batteries]
        payload = {"lines": lines}

        import secrets
        import tempfile
        # A unique per-run remote dir so concurrent or stale runs never collide; try/finally so it is
        # always cleaned up even if an assertion below fails.
        rdir = f"zb/argv-{os.getpid()}-{secrets.token_hex(4)}"
        rdir_win = rdir.replace("/", "\\")
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            (td / "batteries.json").write_text(json.dumps(payload), encoding="utf-8")
            mk = self._ssh("cmd", "/c", rf"mkdir %USERPROFILE%\{rdir_win}")
            self.assertEqual(mk.returncode, 0, f"mkdir failed: {mk.stderr}")
            try:
                r = self._scp(str(td / "batteries.json"), f"{rdir}/batteries.json")
                self.assertEqual(r.returncode, 0, f"scp batteries failed: {r.stderr}")
                r = self._scp(str(REPO / "tests" / "windows" / "cmdline_oracle.py"), f"{rdir}/cmdline_oracle.py")
                self.assertEqual(r.returncode, 0, f"scp oracle failed: {r.stderr}")

                run = self._ssh("python", rf"%USERPROFILE%\{rdir_win}\cmdline_oracle.py",
                                rf"%USERPROFILE%\{rdir_win}\batteries.json")
                self.assertEqual(run.returncode, 0, f"oracle failed: {run.stdout}\n{run.stderr}")
                parsed = json.loads(run.stdout)["parsed"]
            finally:
                self._ssh("cmd", "/c", rf"rmdir /s /q %USERPROFILE%\{rdir_win}")

        self.assertEqual(len(parsed), len(batteries))
        checked = 0
        for args, got in zip(batteries, parsed):
            self.assertEqual(got[0], PROG, "argv[0] should parse back to the fixed program name")
            self.assertEqual(got[1:], args,
                             f"round-trip mismatch for {args!r}: line={PROG + ' ' + wc.join_argv(args)!r} -> {got!r}")
            checked += 1
        # Explicit evidence the live path actually exercised assertions (a skip can never satisfy this).
        self.assertEqual(checked, len(batteries))
        self.assertGreaterEqual(checked, 50, f"live oracle must check a substantial battery; checked {checked}")


if __name__ == "__main__":
    live_gate.main()
