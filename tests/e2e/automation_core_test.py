#!/usr/bin/env python3
"""M12 E2E: an external socket client drives the live WebKitGTK page.

Starts the deterministic fixture server, launches zigBrowser on /core with
--automation-api, then sends JSON-RPC frames over ONE persistent UDS
connection and checks each real result against the page state:

  page.url / page.title / page.evaluate (typed values)
  dom.query (>4 KiB of element summaries)
  dom.click on a button that only becomes visible later (engine retries)
  dom.fill / dom.type (value + per-character key events)
  dom.waitFor on an element attached later
  dom.getText
  a missing selector -> element_not_found (-32001) with trace_id/command_id
  page.navigate /nav-b -> url + title change

Exit 77 (skip) only when the binary or a display is unavailable."""

from __future__ import annotations

import argparse
import json
import signal
import socket
import struct
import subprocess
import tempfile
import threading
import time
from pathlib import Path

from automation_fixture_server import AutomationFixtureServer
from slice2_common import SKIP_EXIT, detect_runner, eprint, require_file


def _read_lines(stream, sink: list[str]) -> None:
    try:
        for line in stream:
            sink.append(line.rstrip("\n"))
    finally:
        stream.close()


class RpcClient:
    """Length-prefixed JSON-RPC over one persistent Unix socket."""

    def __init__(self, socket_path: Path, timeout_sec: float) -> None:
        deadline = time.monotonic() + timeout_sec
        last_error: OSError | None = None
        while time.monotonic() < deadline:
            try:
                sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                sock.settimeout(timeout_sec)
                sock.connect(str(socket_path))
                break
            except OSError as exc:
                last_error = exc
                time.sleep(0.05)
        else:
            raise TimeoutError(f"socket never became connectable: {last_error}")
        self.sock = sock
        self.next_id = 1
        self.max_response_bytes = 0
        # Per-session token sidecar written by the server (0600), if any.
        token_path = Path(str(socket_path) + ".token")
        self.token = token_path.read_text() if token_path.exists() else None

    def close(self) -> None:
        self.sock.close()

    def _recv_exact(self, n: int) -> bytes:
        chunks = b""
        while len(chunks) < n:
            chunk = self.sock.recv(n - len(chunks))
            if not chunk:
                raise ConnectionError("socket closed before full frame")
            chunks += chunk
        return chunks

    def raw(self, method: str, params: dict | None = None) -> dict:
        req_id = self.next_id
        self.next_id += 1
        request = {"jsonrpc": "2.0", "method": method, "id": req_id}
        if self.token:
            request["auth"] = self.token
        if params is not None:
            request["params"] = params
        payload = json.dumps(request, separators=(",", ":")).encode("utf-8")
        self.sock.sendall(struct.pack(">I", len(payload)) + payload)
        length = struct.unpack(">I", self._recv_exact(4))[0]
        self.max_response_bytes = max(self.max_response_bytes, length)
        response = json.loads(self._recv_exact(length).decode("utf-8"))
        if response.get("jsonrpc") != "2.0" or response.get("id") != req_id:
            raise AssertionError(f"bad JSON-RPC envelope for {method}: {response}")
        if isinstance(response.get("result"), dict) and "method" in response["result"]:
            raise AssertionError(f"server returned the ack template for {method}: {response}")
        return response

    def call(self, method: str, params: dict | None = None):
        response = self.raw(method, params)
        if "error" in response:
            raise AssertionError(f"{method} returned an error: {response}")
        return response["result"]

    def evaluate(self, expression: str):
        return self.call("page.evaluate", {"expression": expression})["result"]


def expect(label: str, condition: bool, detail) -> None:
    if not condition:
        raise AssertionError(f"{label}: {detail!r}")


def expect_equal(label: str, actual, expected) -> None:
    if actual != expected:
        raise AssertionError(f"{label}: expected {expected!r}, got {actual!r}")


def run_scenarios(rpc: RpcClient, fixture: AutomationFixtureServer) -> list[str]:
    passed: list[str] = []
    base_url = fixture.base_url

    # Readiness: page.title is the FIRST request, sent while /core is still
    # being served (the fixture delays it), with no DOM wait before it.
    title_sent_at = time.monotonic()
    title = rpc.call("page.title")["title"]
    expect_equal("page.title (first call)", title, "zigBrowser Core Fixture")
    deadline = time.monotonic() + 5
    while fixture.core_served_at is None and time.monotonic() < deadline:
        time.sleep(0.01)
    served_at = fixture.core_served_at
    expect("title was sent while /core was still loading", served_at is not None and title_sent_at < served_at, (title_sent_at, served_at))
    expect_equal("page.url", rpc.call("page.url")["url"], f"{base_url}/core")
    passed.append("page.title-first+url (readiness)")

    typed = rpc.evaluate("({n: 1.5, b: [true, null], s: 'x\"y', big: 2 ** 40})")
    expect_equal("page.evaluate typed", typed, {"n": 1.5, "b": [True, None], "s": 'x"y', "big": 2**40})
    expect_equal("page.evaluate undefined", rpc.evaluate("undefined"), None)
    passed.append("page.evaluate")

    elements = rpc.call("dom.query", {"selector": "css=li.item"})["elements"]
    expect_equal("dom.query count", len(elements), 120)
    expect_equal("dom.query tag", elements[0]["tag"], "li")
    expect("dom.query text", elements[7]["text"].startswith("Item 7"), elements[7])
    expect("dom.query >4 KiB", rpc.max_response_bytes > 4096, rpc.max_response_bytes)
    passed.append("dom.query>4KiB")

    rpc.evaluate("window.__armLate(400)")
    started = time.monotonic()
    expect_equal("dom.click late button", rpc.call("dom.click", {"selector": "css=#late", "options": {"timeout_ms": 5000}}), {"ok": True})
    waited = time.monotonic() - started
    expect("dom.click waited for visibility", waited >= 0.25, waited)
    expect_equal("click handler ran once", rpc.evaluate("window.__lateClicks"), 1)
    expect_equal("dom.getText after click", rpc.call("dom.getText", {"selector": "css=#late-status"})["text"], "clicked")
    passed.append("dom.click(retry until visible)")

    expect_equal("dom.fill", rpc.call("dom.fill", {"selector": "css=#name", "value": "Ada Lovelace"}), {"ok": True})
    expect_equal("fill value", rpc.evaluate("document.querySelector('#name').value"), "Ada Lovelace")
    passed.append("dom.fill")

    expect_equal("dom.type", rpc.call("dom.type", {"selector": "css=#search", "text": "zig"}), {"ok": True})
    expect_equal("type value", rpc.evaluate("document.querySelector('#search').value"), "zig")
    expect_equal("type keydowns", rpc.evaluate("window.__keydowns"), 3)
    expect_equal("type input mirror", rpc.call("dom.getText", {"selector": "css=#mirror"})["text"], "zig")
    expect_equal("dom.type delay", rpc.call("dom.type", {"selector": "css=#search", "text": "!!", "delay_ms": 30}), {"ok": True})
    expect_equal("delayed type value", rpc.evaluate("document.querySelector('#search').value"), "zig!!")
    passed.append("dom.type")

    rpc.evaluate("window.__armDynamic(300)")
    expect_equal("dom.waitFor", rpc.call("dom.waitFor", {"selector": "css=#dynamic", "state": "attached", "timeout_ms": 5000}), {"ok": True})
    expect_equal("dom.getText dynamic", rpc.call("dom.getText", {"selector": "css=#dynamic"})["text"], "Dynamic ready")
    passed.append("dom.waitFor")

    expect_equal("dom.getText msg", rpc.call("dom.getText", {"selector": "css=#msg"})["text"], "Hello automation")
    expect_equal("dom.getAttribute", rpc.call("dom.getAttribute", {"selector": "css=#name", "name": "autocomplete"})["value"], "off")
    passed.append("dom.getText+getAttribute")

    missing = rpc.raw("dom.click", {"selector": "css=#does-not-exist", "options": {"timeout_ms": 200}})
    error = missing.get("error") or {}
    expect_equal("missing selector code", error.get("code"), -32001)
    expect_equal("missing selector name", error.get("message"), "element_not_found")
    data = error.get("data") or {}
    expect("missing selector ids", bool(data.get("trace_id")) and bool(data.get("command_id")), data)
    expect("missing selector retried", (data.get("attempts") or 0) >= 2, data)
    passed.append("element_not_found")

    expect_equal("page.navigate", rpc.call("page.navigate", {"url": f"{base_url}/nav-b", "timeout_ms": 10000}), {"ok": True})
    expect_equal("url after navigate", rpc.call("page.url")["url"], f"{base_url}/nav-b")
    expect_equal("title after navigate", rpc.call("page.title")["title"], "Nav B")
    expect_equal("dom after navigate", rpc.call("dom.getText", {"selector": "css=#heading"})["text"], "Nav B")
    passed.append("page.navigate")

    return passed


def terminate(proc: subprocess.Popen[str]) -> int:
    if proc.poll() is None:
        proc.send_signal(signal.SIGINT)
        try:
            proc.wait(timeout=8)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=5)
    return proc.returncode


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default="zig-out/bin/zigBrowser")
    parser.add_argument("--timeout-sec", type=float, default=20.0)
    parser.add_argument("--prefer-xvfb", action="store_true")
    args = parser.parse_args()

    browser = Path(args.binary)
    if not require_file(browser, "binary"):
        return SKIP_EXIT
    runner = detect_runner(args.prefer_xvfb)
    if runner is None:
        return SKIP_EXIT
    prefix, env, runner_note = runner
    eprint(f"runner={runner_note}")

    with AutomationFixtureServer(core_delay_s=0.8) as fixture, tempfile.TemporaryDirectory(prefix="zb-automation-core-") as tmp:
        socket_path = Path(tmp) / "automation.sock"
        env = dict(env)
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        proc = subprocess.Popen(
            prefix + [str(browser), f"{fixture.base_url}/core", "--automation-api"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
        )
        assert proc.stdout is not None and proc.stderr is not None
        stdout_lines: list[str] = []
        stderr_lines: list[str] = []
        threads = [
            threading.Thread(target=_read_lines, args=(proc.stdout, stdout_lines), daemon=True),
            threading.Thread(target=_read_lines, args=(proc.stderr, stderr_lines), daemon=True),
        ]
        for t in threads:
            t.start()

        rpc: RpcClient | None = None
        try:
            rpc = RpcClient(socket_path, args.timeout_sec)
            passed = run_scenarios(rpc, fixture)
        except Exception as exc:
            print("FAIL\tautomation-core")
            eprint(f"error={exc}")
            eprint(f"stdout={stdout_lines[-20:]}")
            eprint(f"stderr={stderr_lines[-20:]}")
            if rpc is not None:
                rpc.close()
            terminate(proc)
            return 1

        rpc.close()
        rc = terminate(proc)
        for t in threads:
            t.join(timeout=1)
        if rc not in (0, 130, -signal.SIGINT):
            print("FAIL\tautomation-core-clean-shutdown")
            eprint(f"return={rc}")
            eprint(f"stderr={stderr_lines[-20:]}")
            return 1

    for name in passed:
        print(f"PASS\t{name}")
    print("PASS\tautomation-core")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
