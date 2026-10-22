"""WS6.1 (c) RED — UNREGISTERED (run with `python3 -I tests/windows/agent_secrets_win_oracle_test.py`).

The Windows token store is src/agent_secrets_win.cpp (new): Credential Manager (CredWriteW/CredReadW/
CredDeleteW, CRED_TYPE_GENERIC, CRED_PERSIST_LOCAL_MACHINE) for the default store, and a DPAPI-wrapped
file fallback (CryptProtectData with CRYPTPROTECT_UI_FORBIDDEN, owner-only DACL). The Win32 can't run on
Linux, so this source oracle binds its structure and cross-compile proves it builds. Red now: the file
does not exist. Green creates the skeleton and folds this oracle into the registered WinDrawerOracle.
"""
import pathlib
import unittest

WIN = pathlib.Path(__file__).resolve().parents[2] / "src" / "agent_secrets_win.cpp"


class Ws61cWinStoreOracleRed(unittest.TestCase):
    def setUp(self):
        self.assertTrue(WIN.is_file(), f"{WIN} must exist (the Windows token store skeleton)")
        self.src = WIN.read_text(encoding="utf-8")

    def test_credential_manager_calls(self):
        for tok in ("CredWriteW", "CredReadW", "CredDeleteW", "CRED_TYPE_GENERIC", "CRED_PERSIST_LOCAL_MACHINE"):
            self.assertIn(tok, self.src, f"the CredMan store must use {tok}")

    def test_dpapi_file_fallback_ui_forbidden(self):
        self.assertIn("CryptProtectData", self.src, "the file fallback must DPAPI-wrap the token")
        self.assertIn("CRYPTPROTECT_UI_FORBIDDEN", self.src, "DPAPI must never prompt (headless/service)")

    def test_no_duplicated_shape_validation(self):
        # the ONE shape lives in the portable Zig (agent_secrets_shape); the C++ backend must not repeat it
        self.assertNotIn("sk-ant-oat01-", self.src, "the C++ store must not duplicate the token shape")


if __name__ == "__main__":
    unittest.main()
