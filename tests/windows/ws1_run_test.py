#!/usr/bin/env python3
"""WS1.4 missing-runtime + WS1.5 build-info reds (UNREGISTERED) — run the Windows release exe on the
Win11 host and pin its fail-closed runtime contract and its HONEST build-info line.

Plan rev 2.x, WS1.4/WS1.5 (thoughts/searchable/shared/plans/2026-10-19-windows-launch-tdd-plan.md:861-897).

WS1.4 — a MISSING WebView2 runtime fails with the documented code AND message:
  * Seam (the PLANNED one, not an invented env flag): WEBVIEW2_BROWSER_EXECUTABLE_FOLDER set to a
    freshly-created EMPTY guest directory. The WebView2 loader honors this browser-folder override, so
    GetAvailableCoreWebView2BrowserVersionString finds no runtime there. The plan marks the env seam
    spike-UNVERIFIED (plan:862-866); the VM runbook verifies it, and the documented fallback is the
    e2e-only `--e2e-protocol` runtime-folder override (ZB_WIN_RUNTIME_SEAM=e2e selects it here).
  * Contract: exit ZB_EXIT_RUNTIME_MISSING (9) AND stderr contains the EXACT documented line
    `zigBrowser: the Microsoft Edge WebView2 Runtime is not installed` — not a generic
    webview2/runtime/install substring. Mutants (plan:892): print the message but exit 1 -> red;
    exit 9 without the exact message -> red.

WS1.5 — build info reports WHAT ACTUALLY RAN:
  * `--version` prints `zigBrowser (WebView2 <ver>; Windows 10.0.<build>; <arch>)` where <arch> is the
    EXECUTING architecture from IsWow64Process2 (`x86_64` natively; `x86_64-on-arm64` under emulation),
    reporting the exact current runtime version and the exact OS build.
  * PE-arch AGREEMENT: tests/windows/pe_census.py on the SAME exe (fetched to Linux) must report a
    machine that agrees with <arch>'s base (x86_64 <-> machine 0x8664). Mutant (plan:896): report
    PROCESSOR_ARCHITECTURE instead of IsWow64Process2 and run from an x86 shell on the x64 host -> red.

RED today for the right reason: WS1 is not built (the VM has no Zig/MSVC; setup.ps1 is owner-gated), so
there is no exe to run. The test runs the exe over SSH on the Win11 host when ZB_WIN11_HOST + a built,
staged exe are available; otherwise it is red at the "exe not available" guard. Unregistered; registers
as the WS1 run phase in the green commit.

Run alone:  python3 -I tests/windows/ws1_run_test.py -v
"""
import json
import os
import pathlib
import re
import secrets
import subprocess
import sys
import unittest

ZB_EXIT_RUNTIME_MISSING = 9
# The EXACT documented missing-runtime line (plan:865). Asserted verbatim, not as a loose pattern.
RUNTIME_MISSING_MSG = "zigBrowser: the Microsoft Edge WebView2 Runtime is not installed"
# The full build-info form (plan:893): runtime version; OS build; executing architecture.
VERSION_RE = re.compile(
    r"^zigBrowser \(WebView2 (?P<ver>[\d.]+); Windows 10\.0\.(?P<build>\d+); "
    r"(?P<arch>x86_64(?:-on-arm64)?)\)\s*$")
# IMAGE_FILE_MACHINE_AMD64 — the PE machine that must agree with an x86_64 executing arch.
PE_MACHINE_AMD64 = 0x8664

REPO = pathlib.Path(__file__).resolve().parents[2]
PE_CENSUS = REPO / "tests" / "windows" / "pe_census.py"

HOST = os.environ.get("ZB_WIN11_HOST")
USER = os.environ.get("ZB_WIN11_USER", "zbtext")
PORT = os.environ.get("ZB_WIN11_PORT", "2222")
KEY = os.environ.get("ZB_WIN_KEY", "/home/maceo/vms/win11-m8/zb_win_key")
KH = os.environ.get("ZB_WIN_KNOWN_HOSTS", "/home/maceo/vms/win11-m8/known_hosts")
# The gate stages the built exe here before this phase; absent until WS1 builds + stages it.
EXE_REMOTE = os.environ.get("ZB_WIN_EXE_REMOTE", r"%USERPROFILE%\zb\zigBrowser.exe")
# "env" (default): the WEBVIEW2_BROWSER_EXECUTABLE_FOLDER empty-dir seam. "e2e": the documented
# --e2e-protocol runtime-folder override fallback, used only if the spike shows the env seam is ignored.
RUNTIME_SEAM = os.environ.get("ZB_WIN_RUNTIME_SEAM", "env")


def _ssh_args():
    return ["ssh", "-p", PORT, "-i", KEY, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=yes", "-o", f"UserKnownHostsFile={KH}",
            "-o", "ConnectTimeout=15", "-o", "ConnectionAttempts=3", f"{USER}@{HOST}"]


def _ssh(remote_cmd, timeout=60):
    return subprocess.run(_ssh_args() + [remote_cmd], capture_output=True, text=True, timeout=timeout)


def _scp_from(remote, local, timeout=120):
    return subprocess.run(
        ["scp", "-p", "-P", PORT, "-i", KEY, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
         "-o", "StrictHostKeyChecking=yes", "-o", f"UserKnownHostsFile={KH}",
         "-o", "ConnectTimeout=15", "-o", "ConnectionAttempts=3",
         f"{USER}@{HOST}:{remote}", local],
        capture_output=True, text=True, timeout=timeout)


def _exe_available():
    if not HOST:
        return False
    r = _ssh(f'cmd /c "if exist {EXE_REMOTE} (echo yes) else (echo no)"', timeout=40)
    return r.returncode == 0 and "yes" in r.stdout


class WS14MissingRuntime(unittest.TestCase):
    def test_missing_runtime_exits_9_with_exact_message(self):
        self.assertTrue(_exe_available(),
                        "WS1 exe not built/staged on the Win11 host yet (needs the VM toolchain; "
                        "ZB_WIN11_HOST + staged exe)")
        # The PLANNED guarded seam: a freshly-created EMPTY browser-executable folder, so the loader
        # finds no runtime there. Guard the path so a blank var can never widen a delete.
        empty = f"%USERPROFILE%\\zb\\empty-rt-{os.getpid()}-{secrets.token_hex(4)}"
        self.assertRegex(empty, r"empty-rt-\d+-[0-9a-f]{8}$", "runtime-folder seam path must be unique")
        mk = _ssh(f'cmd /c "mkdir {empty}"', timeout=40)
        self.assertEqual(mk.returncode, 0, f"could not create the empty runtime folder: {mk.stderr}")
        try:
            out_png = r"%USERPROFILE%\zb\rt-missing.png"
            if RUNTIME_SEAM == "e2e":
                # Documented fallback if the env seam is spike-proven ignored (plan:865-866).
                inner = f'{EXE_REMOTE} --e2e-protocol --webview2-runtime-folder "{empty}" ' \
                        f'https://example.invalid/ --screenshot {out_png}'
            else:
                inner = f'set "WEBVIEW2_BROWSER_EXECUTABLE_FOLDER={empty}" & ' \
                        f'{EXE_REMOTE} https://example.invalid/ --screenshot {out_png}'
            r = _ssh(f'cmd /c "{inner}"')
            # Exit-code half: must be exactly 9, not merely nonzero (the "exit 1" mutant is red here).
            self.assertEqual(r.returncode, ZB_EXIT_RUNTIME_MISSING,
                             f"a missing runtime must exit {ZB_EXIT_RUNTIME_MISSING}, got "
                             f"{r.returncode}\nstdout={r.stdout!r}\nstderr={r.stderr!r}")
            # Message half: the EXACT documented line (the "exit 9 without the message" mutant is red
            # here; a generic warning cannot false-green it).
            self.assertIn(RUNTIME_MISSING_MSG, (r.stdout + r.stderr),
                          f"a missing runtime must print the exact documented line "
                          f"{RUNTIME_MISSING_MSG!r}\nstdout={r.stdout!r}\nstderr={r.stderr!r}")
        finally:
            _ssh(f'cmd /c "rmdir /s /q {empty}"', timeout=40)


class WS15BuildInfo(unittest.TestCase):
    def test_version_reports_runtime_osbuild_arch_and_pe_agrees(self):
        self.assertTrue(_exe_available(),
                        "WS1 exe not built/staged on the Win11 host yet (needs the VM toolchain; "
                        "ZB_WIN11_HOST + staged exe)")
        r = _ssh(f'cmd /c "{EXE_REMOTE} --version"')
        self.assertEqual(r.returncode, 0, f"--version must exit 0\n{r.stdout}\n{r.stderr}")
        line = (r.stdout or "").strip().splitlines()[0] if r.stdout.strip() else ""
        m = VERSION_RE.match(line)
        self.assertIsNotNone(
            m, f"--version must print `zigBrowser (WebView2 <ver>; Windows 10.0.<build>; <arch>)`, "
               f"got {line!r}")
        exec_arch = m.group("arch")
        base_arch = exec_arch.split("-on-")[0]  # executing base ISA, e.g. x86_64 for x86_64-on-arm64

        # PE-arch AGREEMENT: census the SAME exe and require its machine to agree with <arch>'s base.
        local_exe = pathlib.Path(os.environ.get("TMPDIR", "/tmp")) / f"zbexe-{secrets.token_hex(4)}.exe"
        try:
            fetched = _scp_from(EXE_REMOTE.replace("%USERPROFILE%", f"/home/{USER}").replace("\\", "/"),
                                str(local_exe))
            self.assertEqual(fetched.returncode, 0, f"could not fetch the exe for PE census: {fetched.stderr}")
            cen = subprocess.run([sys.executable, "-I", str(PE_CENSUS), str(local_exe)],
                                 capture_output=True, text=True, timeout=60)
            self.assertEqual(cen.returncode, 0, f"pe_census failed on the exe:\n{cen.stdout}\n{cen.stderr}")
            info = json.loads(cen.stdout)
            self.assertEqual(
                base_arch, "x86_64",
                f"only x86_64 is a built target today; --version reported {exec_arch!r}")
            self.assertEqual(
                info["machine"], PE_MACHINE_AMD64,
                f"--version executing arch {exec_arch!r} disagrees with the PE machine "
                f"0x{info['machine']:x} (expected 0x{PE_MACHINE_AMD64:x})")
        finally:
            try:
                local_exe.unlink()
            except OSError:
                pass


if __name__ == "__main__":
    unittest.main()
