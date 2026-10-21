#!/usr/bin/env python3
"""WS1.1 pe_census selftest (GREEN, registered) — exercises the PE parser + import allowlist on
INDEPENDENT, Linux-built PE fixtures, so parser/allowlist defects are caught even while the real
release exe is not yet built (the exe red in pe_census_test.py stays unregistered until WS1 builds).

Fixtures are hand-built minimal PE32+ images (no VM, no pefile): a clean x64 GUI PE whose imports are
all allowlisted, a PE that imports a forbidden redistributable (vcruntime140.dll), one with an unlisted
import, and a non-x64 (i386) PE. The mutation oracle: a loosened allowlist (or a parser that drops the
import name) makes the vcruntime / unlisted fixtures pass — these tests then red.

Also pins + records the WebView2 SDK version (WS1.1 "records the pinned WebView2 SDK version").

Run alone:  python3 -I tests/windows/pe_census_selftest.py -v
"""
import pathlib
import re
import struct
import subprocess
import sys
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]
HERE = REPO / "tests" / "windows"
CENSUS = HERE / "pe_census.py"
sys.path.insert(0, str(HERE))
import pe_census  # noqa: E402  (the module under test)

# The pinned WebView2 SDK version this build is built against (bead zigBrowser-4dr); recorded here so a
# drift in the build scripts must consciously update this test.
WEBVIEW2_SDK_VERSION = "1.0.3967.48"


def build_pe(dll_names, machine=0x8664, subsystem=2, pe32plus=True):
    """A minimal valid PE (PE32+ by default) with one section holding an import table that names
    `dll_names`. Only the fields pe_census.py reads are meaningful: magic (PE32 vs PE32+), machine,
    subsystem (opt+68), NumberOfRvaAndSizes + the import data directory, and the import descriptors/names.
    """
    FA, SA = 0x200, 0x1000
    ndesc = len(dll_names) + 1                 # descriptors + one null terminator
    desc_region = ndesc * 20
    strings, name_off = b"", []
    for d in dll_names:
        name_off.append(desc_region + len(strings))
        strings += d.encode("ascii") + b"\0"
    descs = b""
    for i in range(len(dll_names)):
        descs += struct.pack("<IIIII", 0, 0, 0, SA + name_off[i], 0)   # OFT,TS,FC,Name,FT
    descs += b"\0" * 20
    section = descs + strings
    raw = section + b"\0" * ((-len(section)) % FA)

    magic = 0x20B if pe32plus else 0x10B
    opt_size = 240 if pe32plus else 224                  # PE32+ has 8B-wider windows fields -> larger header
    ndirs_off = 108 if pe32plus else 92                  # NumberOfRvaAndSizes
    datadir_off = 112 if pe32plus else 96                # first data directory
    opt = bytearray(opt_size)
    struct.pack_into("<H", opt, 0, magic)
    struct.pack_into("<H", opt, 68, subsystem)           # Subsystem
    struct.pack_into("<I", opt, ndirs_off, 16)           # NumberOfRvaAndSizes
    struct.pack_into("<II", opt, datadir_off + 8, SA, desc_region)  # datadir[1] = Import (RVA, size)
    coff = struct.pack("<HHIIIHH", machine, 1, 0, 0, 0, opt_size, 0x22)
    sechdr = b".idata\0\0" + struct.pack("<IIII", len(section), SA, len(raw), FA) + b"\0" * 16
    headers = b"PE\0\0" + coff + bytes(opt) + sechdr
    dos = bytearray(0x40)
    dos[0:2] = b"MZ"
    struct.pack_into("<I", dos, 0x3C, 0x40)              # e_lfanew -> PE header at 0x40
    pre = bytes(dos) + headers
    pre += b"\0" * ((-len(pre)) % FA)                    # pad headers to the first section's file offset
    return pre + raw


_CLEAN = ["kernel32.dll", "api-ms-win-crt-runtime-l1-1-0.dll", "user32.dll"]


class PeCensusFixtures(unittest.TestCase):
    def _write(self, name, data):
        import tempfile
        d = tempfile.mkdtemp(prefix="zbpe_")
        p = pathlib.Path(d) / name
        p.write_bytes(data)
        self.addCleanup(lambda: (p.unlink(missing_ok=True), p.parent.rmdir()))
        return str(p)

    def _cli(self, exe):
        p = subprocess.run([sys.executable, "-I", str(CENSUS), "--allowlist", exe],
                           capture_output=True, text=True, timeout=30)
        return p.returncode

    # --- the builder itself is faithful: the parser reads back what we encoded -------------------
    def test_clean_pe_is_x64_gui_allowlisted(self):
        c = pe_census.census(self._write("clean.exe", build_pe(_CLEAN)))
        self.assertEqual(c["machine"], 0x8664)
        self.assertTrue(c["machine_ok"])
        self.assertTrue(c["pe32plus"], "the release exe must be a 64-bit PE32+ image")
        self.assertEqual(c["subsystem_name"], "GUI")
        self.assertEqual(c["forbidden_imports"], [])
        self.assertEqual(c["unlisted_imports"], [])
        self.assertEqual(c["verdict"], "OK")
        self.assertEqual(self._cli(self._write("clean2.exe", build_pe(_CLEAN))), 0)

    # --- forbidden redistributable: the core blocker (loosened allowlist -> this reds) ----------
    def test_vcruntime_import_is_forbidden(self):
        c = pe_census.census(self._write("vc.exe", build_pe(_CLEAN + ["vcruntime140.dll"])))
        self.assertIn("vcruntime140.dll", c["forbidden_imports"])
        self.assertEqual(c["verdict"], "FAIL: vcruntime140.dll")
        self.assertEqual(self._cli(self._write("vc2.exe", build_pe(_CLEAN + ["vcruntime140.dll"]))), 1)

    def test_msvcp_import_is_forbidden(self):
        c = pe_census.census(self._write("mp.exe", build_pe(_CLEAN + ["msvcp140.dll"])))
        self.assertIn("msvcp140.dll", c["forbidden_imports"])
        self.assertEqual(self._cli(self._write("mp2.exe", build_pe(_CLEAN + ["msvcp140.dll"]))), 1)

    # --- an import outside the allowlist is flagged (and fails --allowlist) ----------------------
    def test_unlisted_import_is_flagged(self):
        c = pe_census.census(self._write("ev.exe", build_pe(_CLEAN + ["evil.dll"])))
        self.assertEqual(c["unlisted_imports"], ["evil.dll"])
        self.assertEqual(c["verdict"], "FAIL: evil.dll")
        self.assertEqual(self._cli(self._write("ev2.exe", build_pe(_CLEAN + ["evil.dll"]))), 1)

    # --- non-x64 machine is rejected ------------------------------------------------------------
    def test_i386_machine_is_rejected(self):
        c = pe_census.census(self._write("x86.exe", build_pe(_CLEAN, machine=0x14C)))
        self.assertFalse(c["machine_ok"])
        self.assertTrue(c["verdict"].startswith("FAIL:"))
        self.assertEqual(self._cli(self._write("x862.exe", build_pe(_CLEAN, machine=0x14C))), 1)

    def test_pe32_non_plus_is_rejected(self):
        # A 32-bit PE32 (magic 0x10B) image must be rejected even if machine/imports look fine.
        c = pe_census.census(self._write("p32.exe", build_pe(_CLEAN, pe32plus=False)))
        self.assertFalse(c["pe32plus"])
        self.assertEqual(c["verdict"], "FAIL: not PE32+")
        self.assertEqual(self._cli(self._write("p322.exe", build_pe(_CLEAN, pe32plus=False))), 1)


class WebView2SdkPin(unittest.TestCase):
    """The REAL fetcher is tests/guest/setup.ps1 (Install-WebView2Sdk runs NuGet). It must pin the exact
    recorded SDK version with NO 'latest' fallback: `$WebView2PinnedVersion` == the pin, `-Version` always
    passed to NuGet, and the package directory selected by that EXACT version (not the newest installed).
    Mutants that fail this oracle: an empty pin, or a different pinned version."""
    SETUP = REPO / "tests" / "guest" / "setup.ps1"

    def _pinned_version(self, text):
        m = re.search(r"\$WebView2PinnedVersion\s*=\s*'([^']*)'", text)
        return m.group(1) if m else None

    def test_setup_ps1_pins_exact_webview2_version(self):
        self.assertTrue(self.SETUP.exists(), "the real fetcher tests/guest/setup.ps1 must exist")
        t = self.SETUP.read_text()
        pin = self._pinned_version(t)
        self.assertEqual(pin, WEBVIEW2_SDK_VERSION,
                         "setup.ps1 $WebView2PinnedVersion must be exactly %s, got %r" % (WEBVIEW2_SDK_VERSION, pin))
        # -Version must be passed to the NuGet install (so the fetch is pinned, never NuGet's latest).
        self.assertRegex(t, r'"-Version",\s*\$ver', "setup.ps1 must pass -Version to the NuGet install")
        # The version actually fetched ($ver -> -Version) must be assigned ONLY from the authoritative pin —
        # never from the override. This reds the mutant `$ver = $WebView2PackageVersion` (a disconnected fetch).
        ver_rhs = re.findall(r"\$ver\s*=\s*(\S+)", t)
        self.assertTrue(ver_rhs, "setup.ps1 must assign $ver")
        self.assertTrue(all(rhs == "$WebView2PinnedVersion" for rhs in ver_rhs),
                        "$ver must be assigned only from $WebView2PinnedVersion, got %s" % ver_rhs)
        # A non-pin override must be refused (the fetch cannot silently use a different version).
        self.assertRegex(t, r'\$WebView2PackageVersion\s*-ne\s*\$WebView2PinnedVersion',
                         "setup.ps1 must refuse an override that disagrees with the pin")
        # The empty-version -> drop-the-Version-flag fallback (NuGet latest) must be GONE.
        self.assertNotRegex(t, r'if\s*\(\s*\$WebView2PackageVersion\s*\)\s*\{\s*\$installArgs',
                            "setup.ps1 must not drop -Version when the override is empty (no 'latest' fallback)")
        # The package dir must be chosen by the EXACT version, not 'newest installed'.
        self.assertIn('Microsoft.Web.WebView2.$ver', t, "setup.ps1 must select the exact pinned package dir")
        self.assertNotRegex(t, r'Sort-Object\s+Name\s+-Descending',
                            "setup.ps1 must not pick the newest installed WebView2 package")

    def test_no_other_webview2_sdk_version_referenced(self):
        # Every WebView2 SDK version token across the build scripts must be the single recorded pin.
        found = set()
        for rel in ("tests/guest/setup.ps1", "tests/guest/build-in-guest.sh",
                    "tests/windows/build-on-windows.sh", "build.zig"):
            f = REPO / rel
            if f.exists():
                found |= set(re.findall(r"Microsoft\.Web\.WebView2\.([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)", f.read_text()))
        self.assertTrue(found <= {WEBVIEW2_SDK_VERSION},
                        "only the pinned WebView2 SDK %s may appear; found %s" % (WEBVIEW2_SDK_VERSION, sorted(found)))


class SetupPs1ToolchainPins(unittest.TestCase):
    """setup.ps1 toolchain detection on the Win11 VM (win11-m8). The real .ps1 runs only on Windows;
    these Linux source pins guard two detection bugs found live (zbtext, non-admin, MSVC+SDK already
    installed):

      1. EventToken.h ships under Include\\<ver>\\winrt\\ on current Win11 SDKs (10.0.22621/26100), not
         um\\. Get-WindowsSdkInfo must probe winrt\\ first (um\\ fallback), or it wrongly reports the
         toolchain missing and retries winget — which fails for a non-admin user.
      2. The OpenSSH step must not hard-fail for a non-admin when sshd is already running, and the run
         must be skippable with -SkipOpenSsh. Otherwise Enable-OpenSshServer throws before anything else.
    """

    SETUP = REPO / "tests" / "guest" / "setup.ps1"

    def setUp(self):
        self.assertTrue(self.SETUP.exists(), "tests/guest/setup.ps1 must exist")
        self.t = self.SETUP.read_text()

    def test_eventtoken_probed_in_winrt_first(self):
        # winrt\EventToken.h is the primary location; built via Join-Path on the computed $winrtInclude.
        self.assertRegex(
            self.t, r'Join-Path\s+\$winrtInclude\s+"EventToken\.h"',
            "Get-WindowsSdkInfo must look for EventToken.h under winrt\\ (Join-Path $winrtInclude \"EventToken.h\")")

    def test_eventtoken_um_kept_as_fallback(self):
        self.assertIn(r'um\EventToken.h', self.t,
                      "um\\EventToken.h must remain as a fallback for older SDK layouts")

    def test_skip_open_ssh_switch_exists(self):
        self.assertRegex(self.t, r'\[switch\]\$SkipOpenSsh',
                         "setup.ps1 must expose a -SkipOpenSsh switch")

    def test_open_ssh_is_guarded_by_the_skip_switch(self):
        self.assertRegex(self.t, r'if\s*\(\s*\$SkipOpenSsh\s*\)',
                         "the OpenSSH step must be guarded by if ($SkipOpenSsh)")

    def test_non_admin_skips_cleanly_when_sshd_already_running(self):
        # In the non-admin branch, a running sshd must skip cleanly (return) instead of throwing.
        self.assertRegex(
            self.t, r'Get-Service\s+-Name\s+sshd\s+-ErrorAction\s+SilentlyContinue',
            "Enable-OpenSshServer must probe the existing sshd service when not elevated")
        self.assertIn("sshd is already installed and running", self.t,
                      "Enable-OpenSshServer must skip cleanly (not throw) when non-admin and sshd is running")


if __name__ == "__main__":
    unittest.main()
