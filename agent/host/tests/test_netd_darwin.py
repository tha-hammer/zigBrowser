"""macOS netd (macOS plan, egress mapping item 1; BlueBeaver 6971; JadeBeacon 7004; BlackRobin 6975): on Darwin there is
no private network namespace and the CLI rejects a Unix-socket proxy (5503), so netd is a host-loopback TCP proxy on
an OS-selected port. These Linux tests run netd's real main() in a child with `netd.PLATFORM = "darwin"` (the
launcher below; production reads sys.platform):

- netd binds 127.0.0.1:0 itself and holds that listener for its whole life (no gap in which the port is free). Its
  first and only stdout line is exactly `netd ready 127.0.0.1:<port>` (JadeBeacon's agent_net.parseDarwinReadyPort
  grammar, d544286): <port> 1-65535, no leading zero, nothing after it.
- It owns exactly one listening socket, on 127.0.0.1 (never 0.0.0.0), and serves egress only: no socket directory
  and no bridges (on macOS each hook's own profile reaches 51091/31337 directly).
- The proxy keeps the Linux rules unchanged: the exact CONNECT/SNI allowlist (api.anthropic.com, or the manifest's
  egress.allow), 403 with no upstream attempt for any other name, the ClientHello passed byte for byte.
- --sockdir, --bwrap and --test-bridge are refused on Darwin (exit 2, nothing printed, nothing listening).
- EOF on stdin, or SIGTERM, closes the listener and exits 0; the port then refuses connections.
- Linux is unchanged: its ready line stays exactly `netd ready` (test_netd.py).

Run like the gate: cd agent/host/tests && python -X dev -m unittest -v test_netd_darwin. Unregistered until the green.
"""
import json
import os
import queue
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

from test_netd import FAKE, Listener, child_env, client_hello, reap, response_head, status_of

HOST_DIR = Path(__file__).resolve().parents[1]
READY = re.compile(r"netd ready 127\.0\.0\.1:([1-9][0-9]{0,4})")
LAUNCH = ("import sys; from zb_agent_host import netd; netd.PLATFORM = 'darwin'; sys.exit(netd.main(sys.argv[1:]))")


def listening_inet_sockets(pid):
    """(address, port) of every listening TCP socket the process holds, from /proc (Linux test host)."""
    inodes = set()
    for fd in os.listdir(f"/proc/{pid}/fd"):
        try:
            target = os.readlink(f"/proc/{pid}/fd/{fd}")
        except OSError:
            continue
        if target.startswith("socket:["):
            inodes.add(target[8:-1])
    found = []
    for table, family in (("tcp", socket.AF_INET), ("tcp6", socket.AF_INET6)):
        with open(f"/proc/{pid}/net/{table}") as f:
            next(f)
            for line in f:
                cols = line.split()
                local, state, inode = cols[1], cols[3], cols[9]
                if state != "0A" or inode not in inodes:  # 0A = LISTEN
                    continue
                hexaddr, hexport = local.split(":")
                raw = bytes.fromhex(hexaddr)
                if family == socket.AF_INET:
                    addr = socket.inet_ntop(family, raw[::-1])
                else:
                    addr = socket.inet_ntop(family, b"".join(raw[i:i + 4][::-1] for i in range(0, 16, 4)))
                found.append((addr, int(hexport, 16)))
    return found


def _remove_root(root):
    """Only a /tmp/zbn-* directory this test made (a netd that got further than it should may have filled it)."""
    if root.parent == Path("/tmp") and root.name.startswith("zbn-") and not root.is_symlink():
        shutil.rmtree(root, ignore_errors=True)


class DarwinNetd:
    def __init__(self, tc, *extra, launch=LAUNCH):
        self.tc = tc
        self.err = []
        self.lines = queue.Queue()
        self.proc = subprocess.Popen([sys.executable, "-c", launch, "--test-record-connects", *extra],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                     env=child_env(), text=True)
        self.drain = threading.Thread(target=self._drain, daemon=True)
        self.drain.start()
        # stdout is read by a thread into a queue, so every wait on it has a real deadline (RoseCat 7030).
        self.reader = threading.Thread(target=self._read_stdout, daemon=True)
        self.reader.start()
        tc.addCleanup(self.close)

    def _read_stdout(self):
        for line in self.proc.stdout:
            self.lines.put(line)
        self.lines.put(None)  # EOF

    def close(self):
        """The normal shutdown first (EOF on stdin, which removes anything netd made); a kill only if that fails."""
        if self.proc.poll() is None:
            try:
                self.proc.stdin.close()
                self.proc.wait(timeout=5)
            except (OSError, subprocess.TimeoutExpired):
                pass
        reap(self.proc, self.drain, self.reader)

    def _drain(self):
        for line in self.proc.stderr:
            self.err.append(line.rstrip("\n"))

    def ready_port(self, timeout=10):
        try:
            line = self.lines.get(timeout=timeout)
        except queue.Empty:
            self.tc.fail(f"no ready line within {timeout} s: {self.err}")
        line = line or ""
        self.tc.assertTrue(line.endswith("\n"), f"the ready line is a whole line: {line!r}")
        m = READY.fullmatch(line.rstrip("\n"))
        self.tc.assertIsNotNone(m, f"the ready line is exactly 'netd ready 127.0.0.1:<port>': {line!r} {self.err}")
        port = int(m.group(1))
        self.tc.assertTrue(1 <= port <= 65535)
        return port

    def rest_of_stdout(self, timeout=10):
        """Everything netd printed after its ready line, up to EOF."""
        out = []
        while True:
            line = self.lines.get(timeout=timeout)
            if line is None:
                return "".join(out)
            out.append(line)

    def proxy(self, port):
        s = socket.create_connection(("127.0.0.1", port), timeout=15)
        self.tc.addCleanup(s.close)
        return s

    def connects(self, settle=0.3):
        time.sleep(settle)
        return [l for l in self.err if "netd test-connect" in l]


class ReadyAndListener(unittest.TestCase):
    def test_one_listener_on_loopback_and_an_exact_ready_line(self):
        netd = DarwinNetd(self)
        port = netd.ready_port()
        self.assertEqual(listening_inet_sockets(netd.proc.pid), [("127.0.0.1", port)],
                         "exactly one listening socket, on 127.0.0.1, at the announced port (no bridges)")
        netd.proc.stdin.close()
        self.assertEqual(netd.proc.wait(timeout=10), 0)
        self.assertEqual(netd.rest_of_stdout(), "", "the ready line is the only stdout line")

    def test_eof_closes_the_port(self):
        netd = DarwinNetd(self)
        port = netd.ready_port()
        netd.proc.stdin.close()
        self.assertEqual(netd.proc.wait(timeout=10), 0)
        with self.assertRaises(ConnectionRefusedError):
            socket.create_connection(("127.0.0.1", port), timeout=5).close()

    def test_sigterm_closes_the_port_and_exits_0(self):
        netd = DarwinNetd(self)
        port = netd.ready_port()
        netd.proc.send_signal(signal.SIGTERM)
        self.assertEqual(netd.proc.wait(timeout=10), 0)
        with self.assertRaises(ConnectionRefusedError):
            socket.create_connection(("127.0.0.1", port), timeout=5).close()

    def test_a_netd_that_stalls_without_a_whole_ready_line_fails_within_the_deadline(self):
        # The harness itself (RoseCat 7030): a child that prints a ready line without its newline and then hangs
        # must end the wait as a failure, not block the suite.
        stall = "import sys, time; sys.stdout.write('netd ready 127.0.0.1:5'); sys.stdout.flush(); time.sleep(60)"
        netd = DarwinNetd(self, launch=stall)
        started = time.monotonic()
        with self.assertRaises(AssertionError):
            netd.ready_port(timeout=2)
        self.assertLess(time.monotonic() - started, 5)

    def test_linux_only_options_are_refused(self):
        # Present at all is refused, an empty value included (RoseCat 7033), and so is every sandboxed-side flag.
        for extra in (["--sockdir", "{root}/s"], ["--sockdir", ""], ["--bwrap", "/usr/bin/bwrap"], ["--bwrap", ""],
                      ["--test-bridge", "51091=1"], ["--test-bridge", ""], ["--serve"], ["--no-bridges"],
                      ["--allow-host", "api.anthropic.com"], ["--allow-host", ""], ["--bridge-port", "51091"],
                      ["--bridge-port", ""]):
            root = Path(tempfile.mkdtemp(prefix="zbn-", dir="/tmp"))
            self.addCleanup(_remove_root, root)
            extra = [x.format(root=root) for x in extra]
            with self.subTest(extra=extra):
                netd = DarwinNetd(self, *extra)
                self.assertEqual(netd.proc.wait(timeout=10), 2, netd.err)
                self.assertEqual(netd.rest_of_stdout(), "")
                self.assertFalse((root / "s").exists(), "no socket directory on Darwin")


class Egress(unittest.TestCase):
    def test_an_allowed_name_reaches_its_upstream_byte_for_byte(self):
        upstream = Listener(self)
        netd = DarwinNetd(self, "--test-allow", f"{FAKE}={upstream.port}")
        port = netd.ready_port()
        s = netd.proxy(port)
        s.sendall(f"CONNECT {FAKE}:443 HTTP/1.1\r\nHost: {FAKE}:443\r\n\r\n".encode())
        self.assertEqual(status_of(response_head(s)), 200)
        hello = client_hello(FAKE)
        s.sendall(hello)
        s.shutdown(socket.SHUT_WR)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and not (upstream.accepted and bytes(upstream.accepted[0]) == hello):
            time.sleep(0.05)
        self.assertEqual([bytes(a) for a in upstream.accepted], [hello])

    def test_any_other_name_is_403_with_no_upstream_attempt(self):
        netd = DarwinNetd(self)
        port = netd.ready_port()
        for target in ("example.com:443", "api.anthropic.com.evil.zb.invalid:443", "127.0.0.1:443"):
            with self.subTest(target=target):
                s = netd.proxy(port)
                s.sendall(f"CONNECT {target} HTTP/1.1\r\n\r\n".encode())
                self.assertIn(status_of(response_head(s)), (400, 403))
        self.assertEqual(netd.connects(), [])

    def test_the_manifest_allowlist_replaces_the_built_in_name(self):
        # Positive and negative (RoseCat 7030). --test-allow names are allowed whatever the manifest says (the e2e
        # seam), so a 200 through it cannot prove the manifest was read. netd's census line can: it records the
        # allowlist's verdict per target before any resolution. The manifest's name resolves (--test-resolve) only
        # to a TEST-NET address, which vetting refuses to dial, so nothing leaves the host.
        home = Path(tempfile.mkdtemp(prefix="zbn-", dir="/tmp"))
        self.addCleanup(_remove_root, home)
        (home / "net.json").write_text(json.dumps({"egress": {"allow": ["other.zb.invalid"]}, "ports": [51091]}))
        os.chmod(home / "net.json", 0o600)
        netd = DarwinNetd(self, "--net-manifest", str(home / "net.json"), "--census",
                          "--test-resolve", "other.zb.invalid=192.0.2.1")
        port = netd.ready_port()
        self.assertEqual(listening_inet_sockets(netd.proc.pid), [("127.0.0.1", port)],
                         "the manifest's ports are no bridges on Darwin")
        for target in ("other.zb.invalid", "api.anthropic.com"):
            s = netd.proxy(port)
            s.sendall(f"CONNECT {target}:443 HTTP/1.1\r\n\r\n".encode())
            self.assertEqual(status_of(response_head(s)), 403)
        time.sleep(0.3)
        census = sorted(l.split("netd census ", 1)[1] for l in netd.err if "netd census " in l)
        self.assertEqual(census, ["api.anthropic.com:443 refused", "other.zb.invalid:443 allowed"],
                         "the manifest's name is allowed and the built-in name is not")
        self.assertEqual(netd.connects(), [], "the TEST-NET address is never dialled")


if __name__ == "__main__":
    unittest.main()
