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


def build_pe(dll_names, machine=0x8664, subsystem=2):
    """A minimal valid PE32+ with one section holding an import table that names `dll_names`.

    Only the fields pe_census.py reads are meaningful: machine, subsystem (opt+68), the import data
    directory (datadir[1]), the import descriptors (Name at +12) and the DLL name strings.
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

    opt = bytearray(240)
    struct.pack_into("<H", opt, 0, 0x20B)                 # PE32+ magic
    struct.pack_into("<H", opt, 68, subsystem)           # Subsystem
    struct.pack_into("<I", opt, 108, 16)                 # NumberOfRvaAndSizes
    struct.pack_into("<II", opt, 112 + 8, SA, desc_region)  # datadir[1] = Import (RVA, size)
    coff = struct.pack("<HHIIIHH", machine, 1, 0, 0, 0, 240, 0x22)
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


class WebView2SdkPin(unittest.TestCase):
    def test_build_pins_the_recorded_webview2_sdk_version(self):
        # The guest build fetches the WebView2 SDK nuget by exact version; it must match the recorded pin,
        # and no OTHER WebView2 SDK version may appear in the build scripts (a drift must update this test).
        found = set()
        for rel in ("tests/guest/build-in-guest.sh", "tests/windows/build-on-windows.sh", "build.zig"):
            f = REPO / rel
            if f.exists():
                found |= set(re.findall(r"Microsoft\.Web\.WebView2\.([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)", f.read_text()))
        self.assertIn(WEBVIEW2_SDK_VERSION, found,
                      "the build must fetch the pinned WebView2 SDK %s; found %s" % (WEBVIEW2_SDK_VERSION, sorted(found)))
        self.assertEqual(found, {WEBVIEW2_SDK_VERSION},
                         "exactly one WebView2 SDK version must be pinned; found %s" % sorted(found))


if __name__ == "__main__":
    unittest.main()
