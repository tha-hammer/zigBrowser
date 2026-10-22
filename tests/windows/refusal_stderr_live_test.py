r"""j76 / WS3.2 on the Win11 VM: a refused backend flag must REACH THE USER on the Windows GUI exe.

`zigBrowser.exe <url> --renderer shm` is refused by `backend_flag.backendFlagDecision(.windows, ...)`; the app
prints `backend_flag.refusalMessage` and exits 1 (a usage error, app.zig decideFlag). The exe is a
GUI-subsystem PE, and the user sees only what reaches stderr. This test drives the real exe and asserts, for
the open window and for --screenshot:

  * exit 1;
  * stderr is EXACTLY the one line `zigBrowser: --renderer=shm is not supported on Windows` (once, nothing
    else: no `usage:`), and stdout is empty;
  * --screenshot writes no PNG.

A parse control documents the CLI's syntax: `--renderer=shm` (one token) is not a flag the parser knows, so it
is a plain usage error (`usage:` on stderr, exit 1) that never reaches the refusal. (AzureRidge 6686 saw only
`usage:` for that spelling.)

Skips cleanly (exit 0) when ZB_WIN11_HOST or ZB_WIN_EXE is unset. All writes stay under C:\Users\<user>\zb\.

Run live:  ZB_WIN11_HOST=127.0.0.1 ZB_WIN_EXE=zig-out/win/current/zigBrowser.exe \
           python3 -I tests/windows/refusal_stderr_live_test.py -v
"""
import json
import os
import pathlib
import re
import secrets
import subprocess
import tempfile
import unittest
import sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "windows"))
import live_gate  # noqa: E402  ZB_WIN_GATE=1: a missing host fails instead of skipping; prints ASSERTS <n>

REFUSAL = "zigBrowser: --renderer=shm is not supported on Windows"
PROFILE_RE = re.compile(r"\A[A-Za-z]:(\\[A-Za-z0-9._-]+)+\Z")

# VM-side runner: start the exe with the given arguments, wait, and print one JSON line.
_RUNNER = r"""
$ErrorActionPreference = 'Stop'
$dir = $args[0]
$exe = Join-Path $dir 'zigBrowser.exe'
$err = Join-Path $dir 'err.txt'
$out = Join-Path $dir 'out.txt'
$shot = Join-Path $dir 'shot.png'
Remove-Item $err,$out,$shot -ErrorAction SilentlyContinue
$url = 'file:///' + ((Join-Path $dir 'test.html') -replace '\\','/')
$rest = @($args[1..($args.Count - 1)] | ForEach-Object { $_ -replace '@URL@', $url -replace '@SHOT@', $shot })
$p = Start-Process -FilePath $exe -ArgumentList $rest -Wait -PassThru -NoNewWindow `
     -RedirectStandardError $err -RedirectStandardOutput $out
$e = [string](Get-Content $err -Raw -ErrorAction SilentlyContinue); if ($null -eq $e) { $e = '' }
$o = [string](Get-Content $out -Raw -ErrorAction SilentlyContinue); if ($null -eq $o) { $o = '' }
$r = @{ exit = $p.ExitCode; stderr = $e; stdout = $o; shot = (Test-Path $shot); argv = $rest }
[Console]::Out.Write(($r | ConvertTo-Json -Compress))
"""

_HTML = "<!doctype html><html><head><title>ZB refusal</title></head><body>refusal</body></html>\n"


class RefusalStderrLive(unittest.TestCase):
    def setUp(self):
        self.host = os.environ.get("ZB_WIN11_HOST")
        if not self.host:
            live_gate.skip_or_fail(self, "ZB_WIN11_HOST unset — live VM refusal test skipped")
        self.exe = os.environ.get("ZB_WIN_EXE")
        if not self.exe or not pathlib.Path(self.exe).is_file():
            live_gate.skip_or_fail(self, "ZB_WIN_EXE unset or missing — set it to a built zigBrowser.exe")
        self.port = os.environ.get("ZB_WIN11_PORT", "2222")
        self.user = os.environ.get("ZB_WIN11_USER", "zbtext")
        self.key = os.environ.get("ZB_WIN_KEY", "/home/maceo/vms/win11-m8/zb_win_key")
        self.kh = os.environ.get("ZB_WIN_KNOWN_HOSTS", "/home/maceo/vms/win11-m8/known_hosts")

    def _opts(self):
        return ["-i", self.key, "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=yes",
                "-o", f"UserKnownHostsFile={self.kh}", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
                "-o", "ConnectionAttempts=3"]

    def _env(self):
        env = {k: v for k, v in os.environ.items() if k not in ("DISPLAY", "WAYLAND_DISPLAY", "XAUTHORITY")}
        env["SSH_ASKPASS_REQUIRE"] = "never"
        return env

    def _ssh(self, *args):
        return subprocess.run(["ssh", *self._opts(), "-p", self.port, f"{self.user}@{self.host}", *args],
                              capture_output=True, text=True, timeout=180, env=self._env(), stdin=subprocess.DEVNULL)

    def _scp(self, local, remote):
        return subprocess.run(["scp", *self._opts(), "-P", self.port, local, f"{self.user}@{self.host}:{remote}"],
                              capture_output=True, text=True, timeout=180, env=self._env(), stdin=subprocess.DEVNULL)

    def _profile(self):
        """The account's real profile directory, from %USERPROFILE% (it may carry a suffix)."""
        # sshd's own cmd.exe runs this; a nested `cmd /c echo` returns the path with a stray trailing quote.
        r = self._ssh("echo %USERPROFILE%")
        self.assertEqual(r.returncode, 0, f"USERPROFILE failed: {r.stderr}")
        profile = r.stdout.strip().splitlines()[-1].strip()
        # Interpolated into `cmd /c` paths: only a drive and plain path characters, no spaces or metacharacters.
        self.assertRegex(profile, PROFILE_RE, f"USERPROFILE is not a plain path: {profile!r}")
        return profile

    def _run(self, *argv):
        """Run the exe on the VM with `argv` (@URL@ and @SHOT@ substituted there); returns the JSON result."""
        rel = f"zb/refusal-{os.getpid()}-{secrets.token_hex(4)}"
        win = f"{self._profile()}\\{rel}".replace("/", "\\")
        mk = self._ssh("cmd", "/c", f"mkdir {win}")
        self.assertEqual(mk.returncode, 0, f"mkdir failed: {mk.stderr}")
        self.addCleanup(self._ssh, "cmd", "/c", f"rmdir /s /q {win}")
        with tempfile.TemporaryDirectory(prefix="zb-refusal-") as tmp:
            html = os.path.join(tmp, "test.html")
            runner = os.path.join(tmp, "run.ps1")
            with open(html, "w", encoding="utf-8") as f:
                f.write(_HTML)
            with open(runner, "w", encoding="utf-8") as f:
                f.write(_RUNNER)
            for local, name in ((self.exe, "zigBrowser.exe"), (html, "test.html"), (runner, "run.ps1")):
                r = self._scp(local, f"{rel}/{name}")
                self.assertEqual(r.returncode, 0, f"scp {name} failed: {r.stderr}")
        run = self._ssh("powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                        "-File", f"{win}\\run.ps1", win, *argv)
        self.assertEqual(run.returncode, 0, f"runner failed: {run.stdout}\n{run.stderr}")
        return json.loads(run.stdout.strip().splitlines()[-1])

    def _assert_refused(self, r):
        self.assertEqual(r["exit"], 1, f"a refused flag exits 1 (a usage error): {r!r}")
        self.assertEqual(r["stderr"].replace("\r\n", "\n"), REFUSAL + "\n",
                         f"stderr must be exactly the refusal line, once (the user sees only stderr): {r!r}")
        self.assertEqual(r["stdout"], "", f"nothing on stdout: {r!r}")

    def test_open_window_refusal_reaches_stderr(self):
        self._assert_refused(self._run("@URL@", "--renderer", "shm"))

    def test_screenshot_refusal_reaches_stderr(self):
        r = self._run("--screenshot", "@SHOT@", "@URL@", "--renderer", "shm")
        self._assert_refused(r)
        self.assertFalse(r["shot"], f"a refused --screenshot writes no PNG: {r!r}")

    def test_parse_control_one_token_spelling_is_a_usage_error(self):
        r = self._run("@URL@", "--renderer=shm")
        self.assertEqual(r["exit"], 1, r)
        self.assertTrue(r["stderr"].startswith("usage: zigBrowser"), f"`--renderer=shm` is a parse error: {r!r}")
        self.assertNotIn(REFUSAL, r["stderr"], r)


if __name__ == "__main__":
    live_gate.main()
