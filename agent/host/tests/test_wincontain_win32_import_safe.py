"""UNREGISTERED red (bead zigBrowser-d1d, part 2 fix-forward; RoseCat 6544): the Windows containment
backend must be IMPORT-SAFE on a non-Windows host and FAIL CLOSED when the real kernel32 is unavailable.

337b937 bound `ctypes.WinDLL("kernel32", ...)` and every Win32 prototype at module import. On Linux
`ctypes` has no `WinDLL`, so importing the module raised AttributeError — and the registered controlled
Windows-shaped import (`test_windows_import_deep.ControlledWindowsImport`, which loads every package module
afresh under Linux ctypes with `sys.platform="win32"`) went red, turning the whole Linux gate red.

Contract proven here:
  1. `import zb_agent_host.wincontain_win32` succeeds on this (non-Windows) host — no AttributeError.
  2. `launch_in_job(...)` fails CLOSED on a host without a real kernel32: it raises `ContainmentError`
     (the module's own fail-closed error), never an AttributeError or an unconfined child.

Mutant: restore the eager `ctypes.WinDLL(...)` binding at import ⇒ (1) errors at import. Replace the
fail-closed guard with a bare `ctypes.WinDLL` call inside launch ⇒ (2) raises AttributeError, not
ContainmentError.

Intentionally NOT registered in build.zig until green. Run alone:
  cd agent/host/tests && python3 test_wincontain_win32_import_safe.py -v
"""
import importlib
import pathlib
import sys
import unittest

HOST_DIR = pathlib.Path(__file__).resolve().parents[1]           # agent/host
if str(HOST_DIR) not in sys.path:
    sys.path.insert(0, str(HOST_DIR))


class ImportSafe(unittest.TestCase):
    def test_module_imports_on_a_non_windows_host(self):
        # Must not raise AttributeError (no WinDLL on Linux ctypes) at import time.
        mod = importlib.import_module("zb_agent_host.wincontain_win32")
        self.assertTrue(hasattr(mod, "launch_in_job"))
        self.assertTrue(hasattr(mod, "ContainmentError"))

    def test_launch_fails_closed_without_a_real_kernel32(self):
        import ctypes
        mod = importlib.import_module("zb_agent_host.wincontain_win32")
        if hasattr(ctypes, "WinDLL"):
            self.skipTest("real WinDLL present — fail-closed path only exercised off Windows")
        with self.assertRaises(mod.ContainmentError):
            mod.launch_in_job(r"C:\Windows\System32\cmd.exe /c rem")


if __name__ == "__main__":
    unittest.main()
