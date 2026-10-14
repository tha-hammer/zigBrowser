"""The hook network checks shared by S3n2 (agent/host/tests/test_hook_net.py) and
the real-binary closures S3.8, S3.9, S4.4 and S7.6 (chat-drawer plan rev 16.2,
§3c.8b, RoseCat 5492 B3). One probe, one set of decoys, one verdict:

- the hook runs tests/fixtures/agent/hook_net_probe.py (install_probe gives the
  command line) and writes one JSON result per run;
- HookNetDecoys are private host listeners on free ports: the two bridge
  targets (the app's e2e seam points 51091 and 31337 at them) and the fake API
  that netd's `--test-allow fake.zb.invalid=<port>` dials;
- hook_network_failures(result, decoys) lists every way the hook's network
  differs from §3c.8b; empty means it holds.

Offline-safe: the only allowlisted name is fake.zb.invalid, and every
listener is on 127.0.0.1."""

from __future__ import annotations

import secrets
import shutil
import socket
import threading
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
PROBE = REPO / "tests" / "fixtures" / "agent" / "hook_net_probe.py"
PROXY_ENV = ("HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY", "https_proxy", "http_proxy", "no_proxy")


class Decoy:
    """A TCP listener on 127.0.0.1:<free port>. It records each connection's
    bytes and, after the client half-closes, answers `ok-<label>-` plus them."""

    def __init__(self, label: str):
        self.label = label
        self.sock = socket.create_server(("127.0.0.1", 0))
        self.port = self.sock.getsockname()[1]
        self.received: list[bytes] = []
        self._lock = threading.Lock()
        threading.Thread(target=self._serve, daemon=True).start()

    @property
    def connections(self) -> int:
        with self._lock:
            return len(self.received)

    def _serve(self) -> None:
        while True:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            threading.Thread(target=self._one, args=(conn,), daemon=True).start()

    def _one(self, conn: socket.socket) -> None:
        with conn:
            conn.settimeout(10)
            data = b""
            try:
                while chunk := conn.recv(65536):
                    data += chunk
                conn.sendall(f"ok-{self.label}-".encode() + data)
            except OSError:
                pass
            with self._lock:
                self.received.append(data)

    def close(self) -> None:
        self.sock.close()


class HookNetDecoys:
    def __init__(self):
        self.bridges = {51091: Decoy("51091"), 31337: Decoy("31337")}
        self.fake_api = Decoy("fake-api")

    def netd_test_args(self) -> list[str]:
        """The netd options for these decoys (the app passes them under --e2e-protocol)."""
        return ["--test-allow", f"fake.zb.invalid={self.fake_api.port}",
                "--test-bridge", f"51091={self.bridges[51091].port}",
                "--test-bridge", f"31337={self.bridges[31337].port}"]

    def close(self) -> None:
        for decoy in (*self.bridges.values(), self.fake_api):
            decoy.close()


def install_probe(directory: Path) -> Path:
    """Copies the probe into `directory` (somewhere the hook's view has, such
    as agent-home/.claude/hooks) and returns its path."""
    directory.mkdir(parents=True, exist_ok=True)
    target = directory / PROBE.name
    shutil.copyfile(PROBE, target)
    return target


def probe_command(probe: Path, out: Path, nonce: str | None = None) -> tuple[str, str]:
    """(the hook command line, its nonce)."""
    nonce = nonce or secrets.token_hex(8)
    return f"/usr/bin/python3 -I -S {probe} {out} {nonce}", nonce


def hook_network_failures(result: dict, decoys: HookNetDecoys, fake_api_before: int = 0) -> list[str]:
    """Every difference from §3c.8b. `fake_api_before` is the fake API's
    connection count before the hooks ran (the CLI's own turns may use it)."""
    bad = []
    nonce = result.get("nonce", "")
    for port, decoy in decoys.bridges.items():
        sent = f"bridge-{port}-{nonce}".encode()
        got = result["bridges"][str(port)]
        if not got.get("ok") or got.get("reply") != f"ok-{port}-{sent.decode()}":
            bad.append(f"bridge {port} did not carry bytes both ways: {got}")
        if sent not in decoy.received:
            bad.append(f"the {port} decoy never received this hook's bytes")
    for key in ("tcp_3128_connect", "tcp_3128_tls"):
        if result[key].get("ok"):
            bad.append(f"{key}: a hook reached 127.0.0.1:3128 ({result[key]})")
    if result["egress_sock"].get("error") != "No such file or directory":
        bad.append(f"egress proxy.sock is not ENOENT for a hook: {result['egress_sock']}")
    if result["proxy_socks"]:
        bad.append(f"a hook's view holds proxy.sock: {result['proxy_socks']}")
    if result["dns"].get("ok"):
        bad.append(f"a hook resolved a name: {result['dns']}")
    if result["public_ip"].get("ok"):
        bad.append("a hook reached a public IP")
    if decoys.fake_api.connections != fake_api_before:
        bad.append(f"the fake API saw {decoys.fake_api.connections - fake_api_before} connection(s) from hooks")
    leaked = sorted(set(PROXY_ENV) & set(result["env_names"]))
    if leaked:
        bad.append(f"a hook's environment has proxy settings: {leaked}")
    return bad
