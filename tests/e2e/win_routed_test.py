r"""Windows plan WS2a.1 / Closure A (rev 2.21): routed `page.*` commands over the REAL zigBrowser.exe's authenticated
AF_UNIX socket drive the live WebView2 page, on the Win11 VM (and, after its release, the Win10 box).
UNREGISTERED until the WS2a.1 green, which registers it as step `windows-routed-live` in `windows-live`.

Chain: socket -> handleRequestWith -> router -> queue -> engine -> PagePort(automation_wv2_port) ->
zb_automation_* (UI-thread marshal) -> CDP / WebView2 -> JSON-RPC result.

The browser is launched exactly as tests/e2e/win_transport_test.py launches it (its ssh, staging, runner and
cleanup helpers are borrowed, not copied) on a fixture page A; a second fixture page B is staged beside it. The
probe's `rpc` command (tests/windows/transport_probe.zig) sends one raw JSON-RPC frame per connection as zbtext.
  * the Linux envelope and auth: no `auth` member -> -32000; a missing `expression` -> -32602;
  * FIRST page-port call: page.evaluate {"expression": "1+1"} -> result.result == 2 (the plan's rule-9 red);
  * page.url / page.title / the DOM heading read page A's real state;
  * page.navigate to page B -> {"ok": true}, then url, title AND the DOM heading are page B's (so a port that
    answers ok without navigating, or echoes a cached url, still fails);
  * a script that throws -> -32603 `script_exception` (the Linux error contract).

RED today: app.zig wires the GTK port on Windows (`supported = os.tag == .linux`), so the engine has no page and
every page.* command answers -32011, so the first page-port assertion (page.evaluate 1+1) fails.
Mutant for the green (plan): return 0 from the shim without doing the work.

Host selection, as win_transport_test.py: ZB_WIN11_HOST, ZB_WIN_EXE, ZB_WIN11_PORT, ZB_WIN11_USER, ZB_WIN11_KEY,
ZB_WIN11_KNOWN_HOSTS (all explicit once the host is set; bd zigBrowser-ong.25). With no host it skips when run by hand and FAILS under ZB_WIN_GATE=1 (plan D.1, rule 7).
Prints `ASSERTS <n>` (tests/windows/live_gate.py).

Run live (after a reviewer-approved exact commit and the orchestrator's release):
  ZB_WIN_GATE=1 ZB_WIN11_HOST=127.0.0.1 ZB_WIN_EXE=<zigBrowser.exe> python3 -I tests/e2e/win_routed_test.py -v
"""
import json
import os
import pathlib
import sys
import time
import unittest

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))  # `python3 -I` drops the script dir
sys.path.insert(0, str(HERE.parent / "windows"))

import live_gate  # noqa: E402
import win_transport_test as wt  # noqa: E402

AUTH_FAILED = -32000
INVALID_PARAMS = -32602
INTERNAL_ERROR = -32603
NO_HOST = "no Windows host configured"

PAGE_A = ("<!doctype html><html><head><meta charset=\"utf-8\"><title>Routed A</title></head>"
          "<body><h1 id=\"heading\">A</h1></body></html>\n")
PAGE_B = ("<!doctype html><html><head><meta charset=\"utf-8\"><title>Routed B</title></head>"
          "<body><h1 id=\"heading\">B</h1></body></html>\n")
HEADING = "document.getElementById('heading').textContent"

_BORROWED = ("_opts", "_env", "_ssh_argv", "_ssh", "_scp", "_profile", "_probe_as", "_launch", "_release",
             "_remove", "_assert_started")


def _file_url(win_path):
    return "file:///" + win_path.replace("\\", "/")


class WinRouted(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        wt.WinTransport.__dict__["setUpClass"].__func__(cls)
        if cls.tmp:
            # The transport runner opens `test.html`: make it page A, and stage page B beside it.
            pathlib.Path(cls.tmp, "test.html").write_text(PAGE_A, encoding="utf-8")
            pathlib.Path(cls.tmp, "page-b.html").write_text(PAGE_B, encoding="utf-8")

    tearDownClass = wt.WinTransport.__dict__["tearDownClass"]

    def setUp(self):
        if not self.host or not self.exe or not pathlib.Path(self.exe).is_file():
            live_gate.skip_or_fail(self, f"NOT RUN: {NO_HOST} (set ZB_WIN11_HOST and ZB_WIN_EXE)")
        wt.WinTransport.setUp(self)
        self._n = 0

    def _call(self, method, params=None, auth=True):
        """One JSON-RPC request through the probe; returns the whole reply object."""
        self._n += 1
        name = f"req-{self._n}.json"
        request = {"jsonrpc": "2.0", "id": self._n, "method": method}
        if params is not None:
            request["params"] = params
        local = os.path.join(self.tmp, name)
        with open(local, "w", encoding="utf-8") as f:
            json.dump(request, f)
        r = self._scp(self.user, local, f"{self.rel}/{name}")
        self.assertEqual(r.returncode, 0, f"scp {name} failed: {r.stderr}")
        args = ["rpc", self.sock, f"{self.win}\\{name}"] + ([self.token] if auth else [])
        out = self._probe_as(self.user, f"{self.win}\\probe.exe", *args)
        self.assertTrue(out.get("ok"), f"probe rpc {method} failed: {out}")
        reply = out["reply"]
        self.assertEqual(reply.get("id"), self._n, f"{method}: id not echoed: {reply}")
        return reply

    def _result(self, method, params=None):
        reply = self._call(method, params)
        self.assertIsNone(reply.get("error"), f"{method} {params}: error {reply.get('error')}")
        return reply["result"]

    def _error_code(self, method, params=None, auth=True):
        reply = self._call(method, params, auth)
        self.assertIn("error", reply, f"{method} {params}: expected an error, got {reply}")
        return reply["error"]

    def test_routed_page_commands_drive_the_live_page(self):
        self.win, r = self._launch()
        self._assert_started(r)
        self.rel = self.win[len(self._profile(self.user)) + 1:].replace("\\", "/")
        self.sock, self.token = r["sock"], r["token"]
        cp = self._scp(self.user, os.path.join(self.tmp, "page-b.html"), f"{self.rel}/page-b.html")
        self.assertEqual(cp.returncode, 0, f"scp page-b.html failed: {cp.stderr}")
        url_a = _file_url(f"{self.win}\\test.html")
        url_b = _file_url(f"{self.win}\\page-b.html")

        # Auth and envelope first: these answer the same with or without a page port.
        self.assertEqual(self._error_code("page.evaluate", {"expression": "1+1"}, auth=False)["code"], AUTH_FAILED)
        self.assertEqual(self._error_code("page.evaluate", {})["code"], INVALID_PARAMS)

        # The plan's rule-9 red (Closure A), the FIRST page-port call: the result crosses the shim and comes back
        # typed. Today's null port answers -32011 here. It needs no loaded page, so no readiness wait comes first.
        reply = self._call("page.evaluate", {"expression": "1+1"})
        self.assertEqual(reply.get("result"), {"result": 2}, f"page.evaluate 1+1: {reply}")

        # Readiness: page A has loaded (bounded; the last reply is the failure detail).
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            reply = self._call("page.title")
            if reply.get("result") == {"title": "Routed A"}:
                break
            time.sleep(0.5)
        self.assertEqual(reply.get("result"), {"title": "Routed A"}, f"page A never answered page.title: {reply}")
        self.assertEqual(self._result("page.url"), {"url": url_a})
        self.assertEqual(self._result("page.evaluate", {"expression": HEADING})["result"], "A")

        # Navigation must change the real page, not just answer ok.
        self.assertEqual(self._result("page.navigate", {"url": url_b, "timeout_ms": 10000}), {"ok": True})
        self.assertEqual(self._result("page.url"), {"url": url_b})
        self.assertEqual(self._result("page.title"), {"title": "Routed B"})
        self.assertEqual(self._result("page.evaluate", {"expression": HEADING})["result"], "B")

        # The Linux error contract for a script that throws.
        err = self._error_code("page.evaluate", {"expression": "(function(){ throw new Error('boom'); })()"})
        self.assertEqual((err["code"], err.get("message")), (INTERNAL_ERROR, "script_exception"))


for _name in _BORROWED:
    setattr(WinRouted, _name, wt.WinTransport.__dict__[_name])


if __name__ == "__main__":
    live_gate.main()
