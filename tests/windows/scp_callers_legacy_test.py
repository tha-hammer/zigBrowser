#!/usr/bin/env python3
"""bd zigBrowser-ong.12 (NavyCanyon d0833d8 minimum): every concrete Win10 staging/fetch scp path uses the LEGACY
scp protocol (-O), because the Win10 test box's sshd has no sftp subsystem (OpenSSH scp's default protocol).

One hermetic argv test per caller named in d0833d8. A fake `scp` (and a no-op `ssh`) first on PATH records each
argv; the host is TEST-NET 192.0.2.1 and nothing leaves this machine. Each test calls the caller's REAL scp
function, and every recorded argv must carry -O before its first operand:
  - tests/windows/m8_live_test.py         Host.scp_into          (WS1.2-W10 staging)
  - tests/windows/screenshot_live_test.py  ScreenshotLive._scp, ._fetch (WS1.3 Win10)
  - tests/windows/refusal_stderr_live_test.py RefusalStderrLive._scp  (WS3 both-host gate)
  - tests/windows/win_config_flags_test.py WinConfigFlags._scp   (WS3 both-host gate)
  - tests/windows/ws1_run_test.py          _scp_from             (WS1.5 Win10 fetch)
  - tests/e2e/msi_install_test.py          sync_to_guest, copy_back_artifacts (WS13.4-W10)
  - tests/windows/win_drawer_test.py       WinDrawerLive._scp    (WS5 Win10)
(WinTransport._scp is covered by tests/windows/transport_scp_legacy_test.py.)

Run:  python3 -I tests/windows/scp_callers_legacy_test.py -v
"""
import json
import os
import pathlib
import shutil
import stat
import sys
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "tests" / "windows"))
sys.path.insert(0, str(REPO / "tests" / "e2e"))

import m8_live_test  # noqa: E402
import msi_install_test  # noqa: E402
import refusal_stderr_live_test  # noqa: E402
import screenshot_live_test  # noqa: E402
import win_config_flags_test  # noqa: E402
import win_drawer_test  # noqa: E402
import ws1_run_test  # noqa: E402

HOST = "192.0.2.1"  # TEST-NET-1: only the fakes ever see it

_FAKE_SCP = r'''
import json, os, pathlib, sys
with open(pathlib.Path(os.environ["ZB_FAKE_SCP_LOG"]), "a", encoding="utf-8") as f:
    f.write(json.dumps(sys.argv[1:]) + "\n")
'''
_FAKE_SSH = "pass\n"


class LegacyScpCallers(unittest.TestCase):
    def setUp(self):
        self.root = pathlib.Path(tempfile.mkdtemp(prefix="zb-scp-callers-"))
        self.addCleanup(shutil.rmtree, self.root, True)
        bindir = self.root / "bin"
        bindir.mkdir()
        for name, body in (("scp", _FAKE_SCP), ("ssh", _FAKE_SSH)):
            prog = bindir / name
            prog.write_text(f"#!{sys.executable} -I\n{body}")
            prog.chmod(prog.stat().st_mode | stat.S_IXUSR)
        self.log = self.root / "scp.jsonl"
        self.local = self.root / "staged.bin"
        self.local.write_bytes(b"x")
        saved = {k: os.environ.get(k) for k in ("PATH", "ZB_FAKE_SCP_LOG", "ZB_WIN10_HOST")}

        def restore():
            for k, v in saved.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v
        self.addCleanup(restore)
        os.environ["PATH"] = f"{bindir}{os.pathsep}{os.environ.get('PATH', '')}"
        os.environ["ZB_FAKE_SCP_LOG"] = str(self.log)

    def _argvs(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def _assert_legacy(self, want):
        argvs = self._argvs()
        self.assertEqual(len(argvs), want, f"expected {want} scp call(s): {argvs}")
        for argv in argvs:
            self.assertIn("-O", argv, f"scp without the legacy protocol: {argv}")
            first_operand = next(i for i, a in enumerate(argv) if f"@{HOST}:" in a or a == str(self.local)
                                 or a.startswith(str(self.root)))
            self.assertLess(argv.index("-O"), first_operand, f"-O must come before the operands: {argv}")

    @staticmethod
    def _case(cls):
        t = cls()  # "runTest": no test method runs
        t.key, t.kh, t.port, t.user, t.host = "/nonexistent/key", "/nonexistent/known_hosts", "22", "zbtest", HOST
        return t

    def test_m8_live_host_scp_into(self):
        os.environ["ZB_WIN10_HOST"] = HOST
        host = m8_live_test.Host("win10", "ZB_WIN10", "22", "zbtest", "/nonexistent/key", "/nonexistent/kh", None)
        host.scp_into([str(self.local)], "zb/m8-x")
        self._assert_legacy(1)

    def test_screenshot_live_scp_and_fetch(self):
        t = self._case(screenshot_live_test.ScreenshotLive)
        t._scp(str(self.local), "zb/shot-x/zigBrowser.exe")
        t._fetch("zb/shot-x/out.png", str(self.root / "out.png"))
        self._assert_legacy(2)

    def test_refusal_stderr_live_scp(self):
        t = self._case(refusal_stderr_live_test.RefusalStderrLive)
        t._scp(str(self.local), "zb/refusal-x/zigBrowser.exe")
        self._assert_legacy(1)

    def test_win_config_flags_scp(self):
        t = self._case(win_config_flags_test.WinConfigFlags)
        t._scp(str(self.local), "zb/cfg-x/zigBrowser.exe")
        self._assert_legacy(1)

    def test_ws1_run_scp_from(self):
        saved = {k: getattr(ws1_run_test, k) for k in ("HOST", "USER", "PORT", "KEY", "KH")}
        self.addCleanup(lambda: [setattr(ws1_run_test, k, v) for k, v in saved.items()])
        ws1_run_test.HOST, ws1_run_test.USER, ws1_run_test.PORT = HOST, "zbtest", "22"
        ws1_run_test.KEY, ws1_run_test.KH = "/nonexistent/key", "/nonexistent/known_hosts"
        ws1_run_test._scp_from("zb/ws1-x/out.txt", str(self.root / "out.txt"))
        self._assert_legacy(1)

    def test_msi_install_sync_and_copy_back(self):
        saved = msi_install_test.make_tarball
        self.addCleanup(setattr, msi_install_test, "make_tarball", saved)
        msi_install_test.make_tarball = lambda root: self.local  # not an scp path; avoids tarring a tree
        self.assertTrue(msi_install_test.sync_to_guest(self.root, f"zbtest@{HOST}", pathlib.Path("/nonexistent/key")))
        msi_install_test.copy_back_artifacts(self.root, f"zbtest@{HOST}", pathlib.Path("/nonexistent/key"))
        self._assert_legacy(2)

    def test_win_drawer_live_scp(self):
        t = self._case(win_drawer_test.WinDrawerLive)
        t._scp(str(self.local), "zb/drawer-x/zigBrowser.exe")
        self._assert_legacy(1)


if __name__ == "__main__":
    unittest.main()
