#!/usr/bin/env python3
"""WS1.1 red (UNREGISTERED): the Windows release exe is a clean x64 PE within the import allowlist.

Runs tests/windows/pe_census.py --allowlist on the fetched release exe (ZB_WIN_EXE, default
zig-out/bin/zigBrowser.exe). RED today: the WS1 MSVC build is not done (the VM has no Zig/MSVC yet,
and setup.ps1 is not to be run tonight), so there is no exe to census. It goes green when WS1 builds the
exe and the gate fetches it to Linux.

pe_census.py was validated against a real PE fixture (a VM python.exe): machine 0x8664, PE32+, console
subsystem, api-ms-win-crt-* imports, and vcruntime140.dll correctly flagged as a forbidden redistributable.

Unregistered (red stays outside gate-registered steps); registers as the WS1 census phase in the green
commit. Run alone:  python3 -I tests/windows/pe_census_test.py -v
"""
import json
import os
import pathlib
import subprocess
import sys
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]
CENSUS = REPO / "tests" / "windows" / "pe_census.py"
EXE = os.environ.get("ZB_WIN_EXE", str(REPO / "zig-out" / "bin" / "zigBrowser.exe"))


class WS1Census(unittest.TestCase):
    def test_release_exe_is_clean_x64_gui_pe(self):
        self.assertTrue(pathlib.Path(EXE).exists(),
                        f"WS1 release exe not built/fetched yet: {EXE} (set ZB_WIN_EXE)")
        p = subprocess.run([sys.executable, "-I", str(CENSUS), "--allowlist", EXE],
                           capture_output=True, text=True, timeout=60)
        detail = f"\nrc={p.returncode}\nstdout:\n{p.stdout}\nstderr:\n{p.stderr}"
        c = json.loads(p.stdout) if p.stdout.strip().startswith("{") else {}
        self.assertTrue(c.get("machine_ok"), "the release exe must be x64 (machine 0x8664)" + detail)
        self.assertEqual(c.get("subsystem_name"), "GUI", "the browser exe must be a GUI subsystem PE" + detail)
        self.assertEqual(c.get("forbidden_imports"), [], "no vcruntime*/msvcp* imports unless the installer ships them" + detail)
        self.assertEqual(c.get("unlisted_imports"), [], "every import must be within the allowlist" + detail)
        self.assertEqual(p.returncode, 0, "pe_census.py --allowlist must pass on the release exe" + detail)


if __name__ == "__main__":
    unittest.main()
