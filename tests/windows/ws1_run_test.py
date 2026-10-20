#!/usr/bin/env python3
"""WS1.4 + WS1.5 reds (UNREGISTERED) — run the Windows release exe on a host and check its contract.

Grounded in the real codebase:
  * WS1.4 missing runtime: with the WebView2 runtime absent, the exe exits ZB_EXIT_RUNTIME_MISSING (9)
    and prints the documented message (the standalone-installer guidance), NOT a crash or exit 0.
  * WS1.5 build info: `zigBrowser.exe --version` prints the `zb_version_line` form
    `zigBrowser (WebView2 <version>)` (or `zigBrowser (WebView2 unavailable)`), reporting what ran.

RED today for the right reason: WS1 is not built (the VM has no Zig/MSVC; setup.ps1 is owner-gated), so
there is no exe to run. The test runs the exe over SSH on the Win11 host when ZB_WIN11_HOST + a built,
staged exe are available; otherwise it is red at the "exe not available" guard. Unregistered; registers
as the WS1 run phase in the green commit.

Run alone:  python3 -I tests/windows/ws1_run_test.py -v
"""
import os
import re
import subprocess
import unittest

ZB_EXIT_RUNTIME_MISSING = 9
VERSION_RE = re.compile(r"^zigBrowser \(WebView2 .+\)\s*$")

HOST = os.environ.get("ZB_WIN11_HOST")
USER = os.environ.get("ZB_WIN11_USER", "zbtext")
PORT = os.environ.get("ZB_WIN11_PORT", "2222")
KEY = os.environ.get("ZB_WIN_KEY", "/home/maceo/vms/win11-m8/zb_win_key")
KH = os.environ.get("ZB_WIN_KNOWN_HOSTS", "/home/maceo/vms/win11-m8/known_hosts")
# The gate stages the built exe here before this phase; absent until WS1 builds + stages it.
EXE_REMOTE = os.environ.get("ZB_WIN_EXE_REMOTE", r"%USERPROFILE%\zb\zigBrowser.exe")


def _ssh(remote_cmd, timeout=60):
    return subprocess.run(
        ["ssh", "-p", PORT, "-i", KEY, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
         "-o", "StrictHostKeyChecking=yes", "-o", f"UserKnownHostsFile={KH}",
         "-o", "ConnectTimeout=15", "-o", "ConnectionAttempts=3", f"{USER}@{HOST}", remote_cmd],
        capture_output=True, text=True, timeout=timeout)


def _exe_available():
    if not HOST:
        return False
    r = _ssh(f'cmd /c "if exist {EXE_REMOTE} (echo yes) else (echo no)"', timeout=40)
    return r.returncode == 0 and "yes" in r.stdout


class WS14MissingRuntime(unittest.TestCase):
    def test_missing_runtime_exits_9_with_message(self):
        self.assertTrue(_exe_available(),
                        "WS1 exe not built/staged on the Win11 host yet (needs the VM toolchain; ZB_WIN11_HOST + staged exe)")
        # Run with the WebView2 runtime masked so it is 'missing' for this process.
        r = _ssh(f'cmd /c "set WEBVIEW2_RUNTIME_DISABLED=1 & {EXE_REMOTE} https://example.invalid/ --screenshot %USERPROFILE%\\zb\\r.png"')
        self.assertEqual(r.returncode, ZB_EXIT_RUNTIME_MISSING,
                         f"missing runtime must exit {ZB_EXIT_RUNTIME_MISSING}, got {r.returncode}\n{r.stdout}\n{r.stderr}")
        self.assertRegex((r.stdout + r.stderr).lower(), r"webview2|runtime|install",
                         "must print the documented missing-runtime message")


class WS15BuildInfo(unittest.TestCase):
    def test_version_reports_what_ran(self):
        self.assertTrue(_exe_available(),
                        "WS1 exe not built/staged on the Win11 host yet (needs the VM toolchain; ZB_WIN11_HOST + staged exe)")
        r = _ssh(f'cmd /c "{EXE_REMOTE} --version"')
        self.assertEqual(r.returncode, 0, f"--version must exit 0\n{r.stdout}\n{r.stderr}")
        line = (r.stdout or "").strip().splitlines()[0] if r.stdout.strip() else ""
        self.assertRegex(line, VERSION_RE.pattern, f"--version must print the zb_version_line form, got {line!r}")


if __name__ == "__main__":
    unittest.main()
