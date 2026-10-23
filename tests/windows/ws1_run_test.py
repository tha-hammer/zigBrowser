#!/usr/bin/env python3
"""WS1.4 missing-runtime + WS1.5 build-info reds (UNREGISTERED) — run the Windows release exe on the
Win11 host and pin its fail-closed runtime contract and its HONEST build-info line.

Plan rev 2.x, WS1.4/WS1.5 (thoughts/searchable/shared/plans/2026-10-19-windows-launch-tdd-plan.md:861-897).

WS1.4 — a MISSING WebView2 runtime fails with the documented code AND message:
  * Seam (the PLANNED one, not an invented env flag): WEBVIEW2_BROWSER_EXECUTABLE_FOLDER set to a
    freshly-created EMPTY guest directory. The WebView2 loader honors this browser-folder override, so
    GetAvailableCoreWebView2BrowserVersionString finds no runtime there. The plan marks the env seam
    spike-UNVERIFIED (plan:862-866); the VM runbook verifies it first (the explicit seam spike), and the
    documented fallback is the e2e-only `--e2e-protocol` runtime-folder override (ZB_WIN_RUNTIME_SEAM=e2e).
  * Contract: exit ZB_EXIT_RUNTIME_MISSING (9) AND the EXACT documented line
    `zigBrowser: the Microsoft Edge WebView2 Runtime is not installed` on STDERR — and NOT on stdout
    (a diagnostic is an error, it must not leak into the program's stdout). Mutants (plan:892): print
    the message but exit 1 -> red; exit 9 without the exact stderr message -> red.

WS1.5 — build info reports WHAT ACTUALLY RAN:
  * `--version` prints `zigBrowser (WebView2 <ver>; Windows 10.0.<build>; <arch>)` where <ver> is a
    dotted numeric version, <build> is the numeric OS build, and <arch> is the EXECUTING architecture
    from IsWow64Process2 (`x86_64` natively; `x86_64-on-arm64` under emulation).
  * INDEPENDENT cross-checks (not taken from our own --version): <ver> must equal the Evergreen runtime
    version the loader selects (queried from the EdgeUpdate client `pv` on the host), and <build> must
    equal the host's OSVersion.Version.Build. PE-arch AGREEMENT: pe_census.py on the SAME exe (fetched
    over SFTP by its home-relative path) must report a machine agreeing with <arch>'s base (x86_64 <->
    0x8664). Mutant (plan:896): report PROCESSOR_ARCHITECTURE instead of IsWow64Process2 -> red.

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

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # `python3 -I` drops the script dir
import live_transport  # noqa: E402  bd zigBrowser-ong.25: the one transport resolver
import scp_legacy  # noqa: E402  bd zigBrowser-ong.12: every copy over the legacy scp protocol (-O)

ZB_EXIT_RUNTIME_MISSING = 9
# The EXACT documented missing-runtime line (plan:865). Asserted verbatim on STDERR, never stdout.
RUNTIME_MISSING_MSG = "zigBrowser: the Microsoft Edge WebView2 Runtime is not installed"
# A dotted numeric version (1-3 dots), not a permissive [\d.]+ that would accept "...." or "1..2".
_VER = r"\d+(?:\.\d+){1,3}"
# The full build-info form (plan:893): runtime version; OS build; executing architecture.
VERSION_RE = re.compile(
    r"^zigBrowser \(WebView2 (?P<ver>" + _VER + r"); Windows 10\.0\.(?P<build>\d+); "
    r"(?P<arch>x86_64(?:-on-arm64)?)\)\s*$")
# IMAGE_FILE_MACHINE_AMD64 — the PE machine that must agree with an x86_64 executing arch.
PE_MACHINE_AMD64 = 0x8664

REPO = pathlib.Path(__file__).resolve().parents[2]
PE_CENSUS = REPO / "tests" / "windows" / "pe_census.py"

# bd zigBrowser-ong.25: no host -> every test fails its _exe_available() check, as before; a host with any selector
# missing raises TransportConfigError (naming them) at import, before any transport.
_T = live_transport.resolve("ZB_WIN11")
HOST, USER, PORT, KEY, KH = (_T.host, _T.user, _T.port, _T.key, _T.known_hosts) if _T else (None,) * 5
# The gate stages the built exe here before this phase; absent until WS1 builds + stages it.
# `%USERPROFILE%\...` is for cmd on the host; EXE_REMOTE_REL is the SFTP home-relative path for scp.
EXE_REMOTE = os.environ.get("ZB_WIN_EXE_REMOTE", r"%USERPROFILE%\zb\zigBrowser.exe")
EXE_REMOTE_REL = os.environ.get("ZB_WIN_EXE_REMOTE_REL", "zb/zigBrowser.exe")
# "env" (default): the WEBVIEW2_BROWSER_EXECUTABLE_FOLDER empty-dir seam. "e2e": the documented
# --e2e-protocol runtime-folder override fallback, used only if the seam spike shows the env is ignored.
RUNTIME_SEAM = os.environ.get("ZB_WIN_RUNTIME_SEAM", "env")
# The WebView2 Evergreen client GUID — EdgeUpdate records the installed runtime version under `pv` here;
# this is the version GetAvailableCoreWebView2BrowserVersionString returns (independent of our --version).
WV2_CLIENT_GUID = "{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"


def _ssh_args():
    return ["ssh", "-p", PORT, "-i", KEY, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=yes", "-o", f"UserKnownHostsFile={KH}",
            "-o", "ConnectTimeout=15", "-o", "ConnectionAttempts=3", f"{USER}@{HOST}"]


def _ssh(remote_cmd, timeout=60):
    return subprocess.run(_ssh_args() + [remote_cmd], capture_output=True, text=True, timeout=timeout)


def _scp_from(remote_rel, local, timeout=120):
    # remote_rel is resolved relative to the user's home — the proven cross-OS path the working live tests
    # use (never a hard-coded /home/<user>/... Linux assumption); legacy scp protocol (-O, ong.12).
    return subprocess.run(
        scp_legacy.scp_argv("-p", "-P", PORT, "-i", KEY, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
         "-o", "StrictHostKeyChecking=yes", "-o", f"UserKnownHostsFile={KH}",
         "-o", "ConnectTimeout=15", "-o", "ConnectionAttempts=3",
         f"{USER}@{HOST}:{remote_rel}", local),
        capture_output=True, text=True, timeout=timeout)


def _exe_available():
    if not HOST:
        return False
    r = _ssh(f'cmd /c "if exist {EXE_REMOTE} (echo yes) else (echo no)"', timeout=40)
    return r.returncode == 0 and "yes" in r.stdout


class WS14MissingRuntime(unittest.TestCase):
    def test_missing_runtime_exits_9_with_exact_stderr_message(self):
        self.assertTrue(_exe_available(),
                        "WS1 exe not built/staged on the Win11 host yet (needs the VM toolchain; "
                        "ZB_WIN11_HOST + staged exe)")
        tok = f"{os.getpid()}-{secrets.token_hex(4)}"
        # The PLANNED guarded seam: a freshly-created EMPTY browser-executable folder, so the loader finds
        # no runtime there. Guard both paths so a blank var can never widen a delete.
        empty = f"%USERPROFILE%\\zb\\empty-rt-{tok}"
        out_png = f"%USERPROFILE%\\zb\\rt-missing-{tok}.png"
        self.assertRegex(empty, r"empty-rt-\d+-[0-9a-f]{8}$", "runtime-folder seam path must be unique")
        self.assertRegex(out_png, r"rt-missing-\d+-[0-9a-f]{8}\.png$", "output png path must be unique")
        mk = _ssh(f'cmd /c "mkdir {empty}"', timeout=40)
        self.assertEqual(mk.returncode, 0, f"could not create the empty runtime folder: {mk.stderr}")
        try:
            # The screenshot subcommand grammar is `--screenshot <out.png> <URL>` (the flag leads; the
            # out path and URL follow). An earlier `<URL> --screenshot <out>` ordering made the CLI exit
            # with a usage error (1) before the runtime check ever ran.
            if RUNTIME_SEAM == "e2e":
                # Documented fallback if the seam spike proves the env is ignored (plan:865-866).
                inner = f'{EXE_REMOTE} --e2e-protocol --webview2-runtime-folder "{empty}" ' \
                        f'--screenshot {out_png} https://example.invalid/'
            else:
                inner = f'set "WEBVIEW2_BROWSER_EXECUTABLE_FOLDER={empty}" & ' \
                        f'{EXE_REMOTE} --screenshot {out_png} https://example.invalid/'
            r = _ssh(f'cmd /c "{inner}"')
            # Exit-code half: exactly 9, not merely nonzero (the "exit 1" mutant is red here).
            self.assertEqual(r.returncode, ZB_EXIT_RUNTIME_MISSING,
                             f"a missing runtime must exit {ZB_EXIT_RUNTIME_MISSING}, got "
                             f"{r.returncode}\nstdout={r.stdout!r}\nstderr={r.stderr!r}")
            # Message half: the EXACT documented line on STDERR (the "exit 9 without the message" mutant
            # is red here; a generic warning cannot false-green it).
            self.assertIn(RUNTIME_MISSING_MSG, r.stderr,
                          f"a missing runtime must print the exact documented line to STDERR "
                          f"{RUNTIME_MISSING_MSG!r}\nstderr={r.stderr!r}")
            # A diagnostic is an error: it must NOT leak into stdout.
            self.assertNotIn(RUNTIME_MISSING_MSG, r.stdout,
                             f"the runtime-missing diagnostic must not appear on stdout\nstdout={r.stdout!r}")
        finally:
            _ssh(f'cmd /c "rmdir /s /q {empty}"', timeout=40)
            _ssh(f'cmd /c "if exist {out_png} del /q {out_png}"', timeout=40)


class WS15BuildInfo(unittest.TestCase):
    def test_version_reports_runtime_osbuild_arch_crosschecked_and_pe_agrees(self):
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

        # INDEPENDENT OS-build cross-check (not from our own --version).
        ob = _ssh('powershell -NoProfile -NonInteractive -Command '
                  '"[System.Environment]::OSVersion.Version.Build"')
        host_build = (ob.stdout or "").strip()
        self.assertTrue(host_build.isdigit(), f"could not read host OS build: {ob.stdout!r}/{ob.stderr!r}")
        self.assertEqual(m.group("build"), host_build,
                         f"--version OS build {m.group('build')!r} must match the host OS build {host_build!r}")

        # INDEPENDENT WebView2 runtime cross-check: the Evergreen client `pv` the loader selects. Try the
        # per-machine (WOW6432Node) key, then the per-user key.
        host_wv2 = ""
        for hive in (r"HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients",
                     r"HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients"):
            q = _ssh('powershell -NoProfile -NonInteractive -Command '
                     f'"(Get-ItemProperty \'{hive}\\{WV2_CLIENT_GUID}\' -Name pv -ErrorAction SilentlyContinue).pv"')
            host_wv2 = (q.stdout or "").strip()
            if host_wv2:
                break
        self.assertRegex(host_wv2, r"^" + _VER + r"$",
                         f"could not independently read the host WebView2 runtime version: {host_wv2!r}")
        self.assertEqual(m.group("ver"), host_wv2,
                         f"--version WebView2 version {m.group('ver')!r} must match the independently-"
                         f"queried runtime {host_wv2!r}")

        # PE-arch AGREEMENT: census the SAME exe (home-relative SFTP path) and require its machine to
        # agree with <arch>'s base.
        local_exe = pathlib.Path(os.environ.get("TMPDIR", "/tmp")) / f"zbexe-{secrets.token_hex(4)}.exe"
        try:
            fetched = _scp_from(EXE_REMOTE_REL, str(local_exe))
            self.assertEqual(fetched.returncode, 0, f"could not fetch the exe for PE census: {fetched.stderr}")
            cen = subprocess.run([sys.executable, "-I", str(PE_CENSUS), str(local_exe)],
                                 capture_output=True, text=True, timeout=60)
            self.assertEqual(cen.returncode, 0, f"pe_census failed on the exe:\n{cen.stdout}\n{cen.stderr}")
            info = json.loads(cen.stdout)
            self.assertEqual(base_arch, "x86_64",
                             f"only x86_64 is a built target today; --version reported {exec_arch!r}")
            self.assertEqual(info["machine"], PE_MACHINE_AMD64,
                             f"--version executing arch {exec_arch!r} disagrees with the PE machine "
                             f"0x{info['machine']:x} (expected 0x{PE_MACHINE_AMD64:x})")
        finally:
            try:
                local_exe.unlink()
            except OSError:
                pass


if __name__ == "__main__":
    unittest.main()
