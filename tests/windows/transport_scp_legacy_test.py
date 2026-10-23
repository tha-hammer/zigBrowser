#!/usr/bin/env python3
"""bd zigBrowser-ong.12: every file the Windows transport harness stages goes over the LEGACY scp protocol (-O).

OpenSSH's scp uses the SFTP protocol by default, and the Win10 test box's sshd offers no sftp subsystem
("subsystem request failed on channel 0", the WS2b.0 Win10 leg at 516b5b1). The orchestrator's ruling: fix the
harness (tests/e2e/win_transport_test.py WinTransport._scp passes -O), never the Win10 sshd.

Hermetic: fake `ssh` and `scp` programs first on PATH answer the remote commands WinTransport._launch sends
(profile, mkdir, the runner, ready.json, release, cleanup) and record every scp argv; no host is contacted and
nothing runs on Windows. The REAL harness code is driven: WinTransport._launch (which stages zigBrowser.exe,
probe.exe, test.html and run.ps1) and, through the same _scp, win_capabilities_test.py's request staging.
Each recorded scp argv must carry -O before its operands.

Run:  python3 -I tests/windows/transport_scp_legacy_test.py -v
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
sys.path.insert(0, str(REPO / "tests" / "e2e"))

import win_capabilities_test as wc  # noqa: E402
import win_transport_test as wt  # noqa: E402

# Answers the remote command (everything after user@host) the way the Windows sshd's cmd.exe would.
_FAKE_SSH = r'''
import json, os, pathlib, sys, time
state = pathlib.Path(os.environ["ZB_FAKE_SSH_STATE"])
args = sys.argv[1:]
at = next(i for i, a in enumerate(args) if "@" in a)
user = args[at].split("@", 1)[0]
remote = " ".join(args[at + 1:])
if remote == "echo %USERPROFILE%":
    print("C:\\Users\\" + user)
elif remote.startswith("powershell"):
    deadline = time.monotonic() + 60
    while not (state / "release").exists() and time.monotonic() < deadline:
        time.sleep(0.05)
elif "ready.json" in remote:
    print((state / "ready.json").read_text())
elif "type nul >" in remote and remote.endswith("\\release"):
    (state / "release").touch()
elif "(echo present) else (echo gone)" in remote:
    print("gone")
'''

_FAKE_SCP = r'''
import json, os, pathlib, sys
with open(pathlib.Path(os.environ["ZB_FAKE_SSH_STATE"]) / "scp.jsonl", "a", encoding="utf-8") as f:
    f.write(json.dumps(sys.argv[1:]) + "\n")
'''

_READY = {"alive": True, "zb": "C:\\Users\\zbtext\\zb\\lad\\zigbrowser", "lad": "C:\\Users\\zbtext\\zb\\lad",
          "sock": "C:\\Users\\zbtext\\zb\\lad\\zigbrowser\\zigbrowser-automation-ab.sock",
          "token": "C:\\Users\\zbtext\\zb\\lad\\zigbrowser\\zigbrowser-automation-ab.sock.token"}


class LegacyScpStaging(unittest.TestCase):
    def setUp(self):
        self.root = pathlib.Path(tempfile.mkdtemp(prefix="zb-scp-legacy-"))
        self.addCleanup(shutil.rmtree, self.root, True)
        self.state = self.root / "state"
        bindir = self.root / "bin"
        self.state.mkdir()
        bindir.mkdir()
        for name, body in (("ssh", _FAKE_SSH), ("scp", _FAKE_SCP)):
            prog = bindir / name
            prog.write_text(f"#!{sys.executable} -I\n{body}")
            prog.chmod(prog.stat().st_mode | stat.S_IXUSR)
        (self.state / "ready.json").write_text(json.dumps(_READY))
        staged = self.root / "staged"
        staged.mkdir()
        for name in ("zigBrowser.exe", "probe.exe", "test.html", "run.ps1"):
            (staged / name).write_bytes(b"x")
        self.staged = staged
        saved = {k: os.environ.get(k) for k in ("PATH", "ZB_FAKE_SSH_STATE", "ZB_WIN11_HOST", "ZB_WIN_EXE")}

        def restore():
            for k, v in saved.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v
        self.addCleanup(restore)
        os.environ["PATH"] = f"{bindir}{os.pathsep}{os.environ.get('PATH', '')}"
        os.environ["ZB_FAKE_SSH_STATE"] = str(self.state)
        os.environ["ZB_WIN11_HOST"] = "192.0.2.1"  # TEST-NET; only the fakes ever see it
        os.environ["ZB_WIN_EXE"] = str(staged / "zigBrowser.exe")

    def _harness(self, cls, method):
        t = cls(method)
        t.host, t.exe, t.tmp = os.environ["ZB_WIN11_HOST"], os.environ["ZB_WIN_EXE"], str(self.staged)
        t.probe = str(self.staged / "probe.exe")
        cls.setUp(t)
        return t

    def _scp_argvs(self):
        log = self.state / "scp.jsonl"
        return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []

    def _assert_legacy(self, argvs, want):
        self.assertEqual(len(argvs), want, f"expected {want} staging scp calls: {argvs}")
        for argv in argvs:
            self.assertIn("-O", argv, f"staging scp without the legacy protocol: {argv}")
            operands = [i for i, a in enumerate(argv) if "@" in a and ":" in a]
            self.assertTrue(operands and argv.index("-O") < operands[0] - 1,
                            f"-O must come before the operands: {argv}")

    def test_launch_stages_every_file_over_legacy_scp(self):
        t = self._harness(wt.WinTransport, "test_production_transport_is_owner_only")
        win, ready = t._launch()
        t.doCleanups()
        self.assertTrue(win.startswith("C:\\Users\\zbtext\\zb\\ws20-"), win)
        self.assertEqual(ready["sock"], _READY["sock"])
        self._assert_legacy(self._scp_argvs(), 4)

    def test_capabilities_request_staging_uses_the_same_legacy_scp(self):
        t = self._harness(wc.WinCapabilities, "test_capabilities_rpc_reports_the_webview2_row")
        t._stage_request("zb/ws20-x", "req-good.json", {"jsonrpc": "2.0", "method": "capabilities", "id": 2})
        self._assert_legacy(self._scp_argvs(), 1)


if __name__ == "__main__":
    unittest.main()
