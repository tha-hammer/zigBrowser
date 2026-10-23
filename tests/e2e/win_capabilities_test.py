r"""Windows plan WS2b.0 (rev 2.17, C5; orchestrator decision (a), 2026-10-22): the `capabilities` RPC on the
REAL zigBrowser.exe over its authenticated AF_UNIX socket, on the Win11 VM (and, after its release, the
Win10 box).

The browser is launched exactly as tests/e2e/win_transport_test.py launches it (its ssh, staging, runner and
cleanup helpers are borrowed below, not copied), and the probe's `rpc` command (tests/windows/transport_probe.zig)
sends raw JSON-RPC frames as zbtext:
  * no `auth` member -> -32000, and a wrong token -> -32000 (the RPC sits behind the socket's auth);
  * the sidecar token -> `result` is exactly the webview2 row below;
  * params other than {} -> -32602.
The webview2 row is literal: input `unproven` until a recorded WS2b.1 isTrusted run on both hosts, network
`unproven` (zigBrowser-ong.7). The flip to `cdp_input` changes this row and needs that recorded run.

Host selection, as win_transport_test.py: ZB_WIN11_HOST, ZB_WIN_EXE, ZB_WIN11_PORT, ZB_WIN11_USER,
ZB_WIN11_KEY, ZB_WIN11_KNOWN_HOSTS (all explicit once the host is set; bd zigBrowser-ong.25). With no host it skips when run by hand, and FAILS under ZB_WIN_GATE=1
(plan D.1 / rule 7). Prints `ASSERTS <n>`; zero asserts under the gate is a failure.

Run live (after a reviewer-approved exact commit and the orchestrator's release):
  ZB_WIN_GATE=1 ZB_WIN11_HOST=127.0.0.1 ZB_WIN_EXE=<zigBrowser.exe> python3 -I tests/e2e/win_capabilities_test.py -v
"""
import json
import os
import pathlib
import sys
import unittest

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))  # `python3 -I` drops the script dir

import win_transport_test as wt  # noqa: E402

WEBVIEW2_ROW = {"backend": "webview2", "input": {"mode": "unproven"}, "network": {"support": "unproven"}}
AUTH_FAILED = -32000
INVALID_PARAMS = -32602
NO_HOST = "no Windows host configured"

ASSERTS = 0

_BORROWED = ("_opts", "_env", "_ssh_argv", "_ssh", "_scp", "_profile", "_probe_as", "_launch", "_release",
             "_remove", "_assert_started")


class WinCapabilities(unittest.TestCase):
    setUpClass = wt.WinTransport.__dict__["setUpClass"]
    tearDownClass = wt.WinTransport.__dict__["tearDownClass"]

    def setUp(self):
        if not self.host or not self.exe or not pathlib.Path(self.exe).is_file():
            if os.environ.get("ZB_WIN_GATE") == "1":
                self.fail(f"NOT RUN: {NO_HOST} (ZB_WIN11_HOST and ZB_WIN_EXE) under ZB_WIN_GATE=1")
            self.skipTest(f"{NO_HOST} — set ZB_WIN11_HOST and ZB_WIN_EXE")
        wt.WinTransport.setUp(self)

    def _eq(self, label, actual, expected):
        global ASSERTS
        ASSERTS += 1
        self.assertEqual(actual, expected, label)

    def _stage_request(self, rel, name, request):
        local = os.path.join(self.tmp, name)
        with open(local, "w", encoding="utf-8") as f:
            json.dump(request, f)
        r = self._scp(self.user, local, f"{rel}/{name}")
        self.assertEqual(r.returncode, 0, f"scp {name} failed: {r.stderr}")

    def _rpc(self, win, sock, name, token=None):
        args = ["rpc", sock, f"{win}\\{name}"] + ([token] if token else [])
        out = self._probe_as(self.user, f"{win}\\probe.exe", *args)
        self.assertTrue(out.get("ok"), f"probe rpc {name} failed: {out}")
        return out["reply"]

    def test_capabilities_rpc_reports_the_webview2_row(self):
        win, r = self._launch()
        self._assert_started(r)
        rel = win[len(self._profile(self.user)) + 1:].replace("\\", "/")
        base = {"jsonrpc": "2.0", "method": "capabilities"}
        self._stage_request(rel, "req-missing.json", {**base, "id": 0})
        self._stage_request(rel, "req-wrong.json", {**base, "id": 1, "auth": "0" * 64})
        self._stage_request(rel, "req-good.json", {**base, "id": 2})
        self._stage_request(rel, "req-params.json", {**base, "id": 3, "params": {"backend": "webkitgtk"}})

        missing = self._rpc(win, r["sock"], "req-missing.json")
        self._eq("missing token refused", missing.get("error", {}).get("code"), AUTH_FAILED)
        wrong = self._rpc(win, r["sock"], "req-wrong.json")
        self._eq("wrong token refused", wrong.get("error", {}).get("code"), AUTH_FAILED)
        good = self._rpc(win, r["sock"], "req-good.json", r["token"])
        self._eq("no error", good.get("error"), None)
        self._eq("capabilities row", good.get("result"), WEBVIEW2_ROW)
        self._eq("id echoed", good.get("id"), 2)
        params = self._rpc(win, r["sock"], "req-params.json", r["token"])
        self._eq("params refused", params.get("error", {}).get("code"), INVALID_PARAMS)


for _name in _BORROWED:
    setattr(WinCapabilities, _name, wt.WinTransport.__dict__[_name])


if __name__ == "__main__":
    program = unittest.main(exit=False)
    print(f"ASSERTS {ASSERTS}")
    failed = not program.result.wasSuccessful()
    if os.environ.get("ZB_WIN_GATE") == "1" and ASSERTS == 0:
        failed = True
    raise SystemExit(1 if failed else 0)
