"""S3n1 (chat-drawer plan rev 16.2, §3c.2, §3c.2b, §3c.3): the host-side
network helper, driven only through its command line, offline.

    python3 -m zb_agent_host.netd --sockdir DIR --bwrap BWRAP
        [--test-allow NAME=PORT] [--test-bridge 51091=PORT] [--test-bridge 31337=PORT]
        [--test-resolve NAME=ADDR[,ADDR...]] [--test-record-connects]

netd prints `netd ready` once its sockets exist. Closing its stdin is the
normal shutdown (it removes its directory and exits 0); a signal to the
spawned PID kills it with no cleanup, because bwrap forwards no signal.

Test seams (accepted by netd; the app passes them only under --e2e-protocol),
as agreed with BlueBeaver (mail 5505):
- --test-allow NAME=PORT maps exactly NAME to 127.0.0.1:PORT (a private fake
  listener) and skips vetting; the parser, SNI and refusal rules still apply.
- --test-resolve NAME=ADDRS replaces resolution only; vetting still applies,
  so a vetted address is really dialed. Every netd that uses it runs sealed
  in its own network namespace with only loopback (`sealed=True`), where any
  non-loopback address is unreachable.
- --test-record-connects writes one stderr line per upstream connect
  attempt, before the attempt: `zigBrowser: agent: netd test-connect <addr> <port>`.

Every listener here is a private fake on 127.0.0.1; nothing reaches the
network. Socket directories are short (/tmp/zbn-*): sun_path holds 107 bytes."""

import os
import signal
import socket
import ssl
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

HOST_DIR = Path(__file__).resolve().parents[1]
BWRAP = "/usr/bin/bwrap"
sys.path.insert(0, str(HOST_DIR))  # SpliceTest imports netd directly, also when this file runs alone
FAKE = "fake.zb.invalid"
CONNECT_LINE = "zigBrowser: agent: netd test-connect "


def netd_argv(sockdir, *extra, bwrap=BWRAP):
    """The one place that spells the command; S3n1's owner may change it."""
    return [sys.executable, "-m", "zb_agent_host.netd", "--sockdir", str(sockdir), "--bwrap", bwrap, *extra]


def child_env():
    return {"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "PYTHONPATH": str(HOST_DIR), "PYTHONDONTWRITEBYTECODE": "1"}


def short_root(tc):
    root = Path(tempfile.mkdtemp(prefix="zbn-", dir="/tmp"))
    tc.addCleanup(lambda: subprocess.run(["find", str(root), "-delete"], check=False))
    return root


class Listener:
    """A private TCP fake on 127.0.0.1: records every connection's bytes and
    answers with `reply` after the client half-closes (or at once)."""

    def __init__(self, tc, reply=b"", echo=False):
        self.sock = socket.create_server(("127.0.0.1", 0))
        self.port = self.sock.getsockname()[1]
        self.accepted = []
        self.reply, self.echo = reply, echo
        tc.addCleanup(self.sock.close)
        threading.Thread(target=self._serve, daemon=True).start()

    def _serve(self):
        while True:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            data = bytearray()
            self.accepted.append(data)
            threading.Thread(target=self._one, args=(conn, data), daemon=True).start()

    def _one(self, conn, data):
        with conn:
            conn.settimeout(10)
            try:
                while chunk := conn.recv(65536):
                    data += chunk
                    if self.echo:
                        conn.sendall(chunk)
                conn.sendall(self.reply)  # the client half-closed: answer, then close
            except OSError:
                pass


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def client_hello(server_name):
    """A real TLS ClientHello record naming `server_name` (SNI)."""
    ctx = ssl.create_default_context()
    incoming, outgoing = ssl.MemoryBIO(), ssl.MemoryBIO()
    obj = ctx.wrap_bio(incoming, outgoing, server_hostname=server_name)
    try:
        obj.do_handshake()
    except ssl.SSLWantReadError:
        pass
    return outgoing.read()


def sealed_argv(argv):
    """`argv` in a network namespace of its own: loopback only, no route out."""
    return [BWRAP, "--unshare-net", "--die-with-parent", "--dev-bind", "/", "/", "--proc", "/proc", "--", *argv]


class Netd:
    def __init__(self, tc, *extra, sockdir=None, bwrap=BWRAP, start=True, record=True, sealed=False):
        self.tc = tc
        self.root = short_root(tc)
        self.dir = Path(sockdir) if sockdir else self.root / "s"
        self.argv = netd_argv(self.dir, *(["--test-record-connects"] if record else []), *extra, bwrap=bwrap)
        if sealed:
            self.argv = sealed_argv(self.argv)
        self.proc, self.err = None, []
        if start:
            self.start()

    def start(self, pass_fds=()):
        self.proc = subprocess.Popen(self.argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                     env=child_env(), text=True, pass_fds=pass_fds)
        threading.Thread(target=self._drain_stderr, daemon=True).start()
        self.tc.addCleanup(self.kill)
        return self

    def _drain_stderr(self):
        for line in self.proc.stderr:
            self.err.append(line.rstrip("\n"))

    def ready(self, timeout=10):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            line = self.proc.stdout.readline()
            if not line:
                return False
            if line.rstrip("\n") == "netd ready":
                return True
        return False

    def stop(self, timeout=10):
        """The normal shutdown: EOF on netd's stdin. Returns the exit status."""
        if self.proc.stdin and not self.proc.stdin.closed:
            self.proc.stdin.close()
        return self.proc.wait(timeout=timeout)

    def kill(self):
        if self.proc and self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait()

    def connects(self, settle=0.3):
        """Each recorded upstream attempt as `<addr> <port>`."""
        time.sleep(settle)
        return [line[len(CONNECT_LINE):] for line in self.err if line.startswith(CONNECT_LINE)]

    def unix(self, *parts, timeout=15):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect(str(self.dir.joinpath(*parts)))
        self.tc.addCleanup(s.close)
        return s

    def proxy(self):
        return self.unix("egress", "proxy.sock")


def response_head(sock):
    """Bytes up to the end of the response head, or all bytes to EOF."""
    data = b""
    while b"\r\n\r\n" not in data:
        try:
            chunk = sock.recv(4096)
        except OSError:
            break
        if not chunk:
            break
        data += chunk
    return data


def status_of(head):
    return int(head.split(b" ", 2)[1]) if head.startswith(b"HTTP/1.1 ") else None


class SocketDirTest(unittest.TestCase):
    def test_the_layout_is_egress_and_bridges_with_exact_modes_and_a_ready_line(self):
        d = Netd(self)
        self.assertTrue(d.ready(), d.err)
        self.assertEqual(stat.S_IMODE(d.dir.stat().st_mode), 0o700)
        found = sorted(str(p.relative_to(d.dir)) for p in d.dir.rglob("*"))
        self.assertEqual(found, ["bridges", "bridges/port-31337.sock", "bridges/port-51091.sock",
                                 "egress", "egress/proxy.sock"])
        for sub in ("egress", "bridges"):
            self.assertEqual(stat.S_IMODE((d.dir / sub).stat().st_mode), 0o700, sub)
        for sock in ("egress/proxy.sock", "bridges/port-51091.sock", "bridges/port-31337.sock"):
            st = (d.dir / sock).lstat()
            self.assertTrue(stat.S_ISSOCK(st.st_mode), sock)
            self.assertEqual(stat.S_IMODE(st.st_mode), 0o600, sock)

    def test_eof_on_stdin_removes_its_sockets_and_the_directory_and_exits_0(self):
        d = Netd(self)
        self.assertTrue(d.ready())
        started = time.monotonic()
        self.assertEqual(d.stop(timeout=5), 0, d.err)
        self.assertLess(time.monotonic() - started, 1.0)
        self.assertFalse(d.dir.exists())

    def test_sigterm_to_the_spawned_pid_ends_every_netd_process_within_one_second(self):
        """bwrap forwards no signal (BlueBeaver 5505): this is death without
        cleanup, as in a crash; nothing is expected of the directory."""
        d = Netd(self)
        self.assertTrue(d.ready())
        tree = tree_of(d.proc.pid)
        d.proc.send_signal(signal.SIGTERM)
        d.proc.wait(timeout=5)
        deadline = time.monotonic() + 1.0
        while time.monotonic() < deadline and alive(tree):
            time.sleep(0.05)
        self.assertEqual(alive(tree), [])

    def test_an_existing_directory_a_link_or_a_too_long_path_refuses_with_exit_2(self):
        root = short_root(self)
        (root / "exists").mkdir(mode=0o700)
        (root / "elsewhere").mkdir(mode=0o700)
        (root / "link").symlink_to(root / "elsewhere")
        long = root / ("x" * (108 - len(str(root)) - len("/bridges/port-51091.sock")))  # one byte over 107
        for sockdir in (root / "exists", root / "link", long):
            with self.subTest(sockdir=str(sockdir)[-20:]):
                done = subprocess.run(netd_argv(sockdir), env=child_env(), capture_output=True, text=True, timeout=30)
                self.assertEqual(done.returncode, 2, done.stderr)
                self.assertNotIn("netd ready", done.stdout)
        self.assertFalse(long.exists())

    def test_a_missing_bwrap_exits_3(self):
        root = short_root(self)
        done = subprocess.run(netd_argv(root / "s", bwrap="/nonexistent/bwrap"), env=child_env(), capture_output=True,
                              text=True, timeout=30)
        self.assertEqual(done.returncode, 3, done.stderr)

    def test_no_inherited_descriptor_survives_in_any_process_of_netd(self):
        """§3c.2: every inherited descriptor >= 3 is closed (a canary fd is passed in)."""
        root = short_root(self)
        canary = root / "canary-fd"
        canary.write_text("canary")
        fd = os.open(canary, os.O_RDONLY)
        self.addCleanup(os.close, fd)
        d = Netd(self, start=False)
        d.start(pass_fds=(fd,))
        self.assertTrue(d.ready())
        holders = []
        for pid in tree_of(d.proc.pid):
            for entry in os.listdir(f"/proc/{pid}/fd"):
                try:
                    if os.readlink(f"/proc/{pid}/fd/{entry}") == str(canary):
                        holders.append((pid, entry))
                except OSError:
                    pass
        self.assertEqual(holders, [])


def alive(pids):
    """Those of `pids` that still exist and are not zombies."""
    out = []
    for pid in pids:
        try:
            if Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[0] != "Z":
                out.append(pid)
        except OSError:
            pass
    return out


def tree_of(pid):
    """`pid` and its live descendants."""
    children = {}
    for entry in os.listdir("/proc"):
        if entry.isdigit():
            try:
                ppid = int(Path(f"/proc/{entry}/stat").read_text().rsplit(")", 1)[1].split()[1])
            except (OSError, IndexError, ValueError):
                continue
            children.setdefault(ppid, []).append(int(entry))
    out, todo = [], [pid]
    while todo:
        p = todo.pop()
        out.append(p)
        todo.extend(children.get(p, []))
    return out


class ParserTest(unittest.TestCase):
    """§3c.3: only CONNECT <allowlisted host>:443 HTTP/1.1. Every refusal has
    its exact status, an empty body, and makes zero upstream attempts."""

    def setUp(self):
        self.upstream = Listener(self)
        self.d = Netd(self, "--test-allow", f"{FAKE}={self.upstream.port}")
        self.assertTrue(self.d.ready())

    def ask(self, raw, timeout=15):
        """(status, the bytes after the head up to EOF): netd closes after a refusal."""
        s = self.d.proxy()
        s.settimeout(timeout)
        s.sendall(raw)
        data = b""
        try:
            while chunk := s.recv(4096):
                data += chunk
        except OSError:
            pass
        head, _, body = data.partition(b"\r\n\r\n")
        return status_of(head + b"\r\n\r\n"), body

    def test_each_refused_request_has_its_status_an_empty_body_and_no_upstream_attempt(self):
        cases = {
            # well formed, but not this allowlist entry: 403
            "uppercase host": (b"CONNECT FAKE.ZB.INVALID:443 HTTP/1.1\r\nHost: x\r\n\r\n", 403),
            "trailing dot": (b"CONNECT fake.zb.invalid.:443 HTTP/1.1\r\n\r\n", 403),
            "userinfo": (b"CONNECT user@fake.zb.invalid:443 HTTP/1.1\r\n\r\n", 403),
            "IPv6 literal": (b"CONNECT [::1]:443 HTTP/1.1\r\n\r\n", 403),
            "IPv4 literal": (b"CONNECT 127.0.0.1:443 HTTP/1.1\r\n\r\n", 403),
            "port 80": (b"CONNECT fake.zb.invalid:80 HTTP/1.1\r\n\r\n", 403),
            "prefix match": (b"CONNECT evil-api.anthropic.com:443 HTTP/1.1\r\n\r\n", 403),
            "suffix match": (b"CONNECT api.anthropic.com.evil.com:443 HTTP/1.1\r\n\r\n", 403),
            "punycode": (b"CONNECT xn--fake-zb.invalid:443 HTTP/1.1\r\n\r\n", 403),
            # malformed: 400
            "absolute-form GET": (b"GET http://fake.zb.invalid/ HTTP/1.1\r\n\r\n", 400),
            "request line over 1 KiB": (b"CONNECT " + b"a" * 1020 + b".invalid:443 HTTP/1.1\r\n\r\n", 400),
            "33 header lines": (b"CONNECT fake.zb.invalid:443 HTTP/1.1\r\n" + b"X-H: v\r\n" * 33 + b"\r\n", 400),
        }
        for label, (raw, want) in cases.items():
            with self.subTest(label):
                status, body = self.ask(raw)
                self.assertEqual(status, want)
                self.assertEqual(body, b"", "a refusal has an empty body and then closes")
        self.assertEqual(self.d.connects(), [], "no refused request may reach the upstream connect")
        self.assertEqual(self.upstream.accepted, [])

    def test_a_dribbled_header_is_cut_off_after_10_s_without_an_upstream_attempt(self):
        s = self.d.proxy()
        s.settimeout(30)
        s.sendall(b"CONNECT fake.zb.invalid:443 HTTP/1.1\r\n")
        started = time.monotonic()
        head = b""
        while time.monotonic() - started < 25:
            try:
                s.sendall(b"X")  # one byte at a time, never ending the head
            except OSError:
                break
            try:
                s.settimeout(1)
                chunk = s.recv(4096)
                if not chunk:
                    break
                head += chunk
                break
            except socket.timeout:
                continue
        self.assertLess(time.monotonic() - started, 15, "the 10 s header timeout")
        self.assertNotEqual(status_of(head), 200)
        self.assertEqual(self.d.connects(), [])

    def test_the_production_allowlist_is_exactly_api_anthropic_com(self):
        """With no --test-allow, any other name is refused before any attempt."""
        d = Netd(self, "--test-resolve", "api.anthropic.com=1.1.1.1", sealed=True)
        self.assertTrue(d.ready())
        s = d.proxy()
        s.sendall(b"CONNECT example.com:443 HTTP/1.1\r\n\r\n")
        self.assertEqual(status_of(response_head(s)), 403)
        self.assertEqual(d.connects(), [])

    def test_lookalike_names_get_no_attempt_even_when_they_resolve_to_a_global_address(self):
        """Only an exact allowlist entry passes the parser (RoseCat 5522). Each
        lookalike here resolves to a global address, so a parser that let it
        through would dial it: sealed, the attempt reaches nothing but is
        recorded, and must not happen."""
        lookalikes = ("evil-api.anthropic.com", "api.anthropic.com.evil.com",
                      f"evil-{FAKE}", f"{FAKE}.evil", f"{FAKE}-evil.invalid")
        resolve = [arg for name in lookalikes for arg in ("--test-resolve", f"{name}=1.1.1.1")]
        d = Netd(self, "--test-allow", f"{FAKE}={self.upstream.port}", *resolve, sealed=True)
        self.assertTrue(d.ready())
        for name in lookalikes:
            with self.subTest(name):
                s = d.proxy()
                s.sendall(f"CONNECT {name}:443 HTTP/1.1\r\n\r\n".encode())
                head = response_head(s)
                if status_of(head) == 200:
                    s.sendall(client_hello(name))  # what a client would send next
                self.assertEqual(status_of(head), 403)
        self.assertEqual(d.connects(), [], "no lookalike may reach an upstream attempt")
        self.assertEqual(self.upstream.accepted, [])


class SpliceTest(unittest.TestCase):
    """§3c.3's idle bound holds in both directions (RoseCat 5526): a peer that
    stops reading cannot hold a splice, nor a tunnel slot, past `idle`."""

    def test_a_peer_that_stops_reading_cannot_hold_a_splice_past_its_idle_deadline(self):
        from zb_agent_host import netd
        a, writer = socket.socketpair()
        b, sink = socket.socketpair()  # `sink` never reads
        for sock in (a, writer, b, sink):
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 1024)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024)
            self.addCleanup(sock.close)
        done = threading.Event()
        threading.Thread(target=lambda: (netd.splice(a, b, idle=0.2), done.set()), daemon=True).start()
        writer.setblocking(False)
        until = time.monotonic() + 0.1
        while time.monotonic() < until:  # fill every buffer on the way to `sink`
            try:
                writer.send(b"x" * 4096)
            except BlockingIOError:
                time.sleep(0.01)
        self.assertTrue(done.wait(1.0), "the splice outlived its 0.2 s idle deadline behind a full send buffer")


class VettingTest(unittest.TestCase):
    """§3c.3: resolve once; refuse unless every address is global; connect only
    to the vetted address. Sealed: a vetted address is dialed but unreachable."""

    def attempt(self, addrs):
        d = Netd(self, "--test-resolve", f"api.anthropic.com={addrs}", sealed=True)
        self.assertTrue(d.ready())
        s = d.proxy()
        s.sendall(b"CONNECT api.anthropic.com:443 HTTP/1.1\r\n\r\n")
        head = response_head(s)
        if status_of(head) == 200:
            s.sendall(client_hello("api.anthropic.com"))
            time.sleep(1)
        return status_of(head), d.connects()

    def test_one_non_global_address_refuses_the_name(self):
        for addrs in ("160.79.104.10,10.0.0.1", "::ffff:127.0.0.1", "100.64.0.1", "fc00::1", "198.18.0.1",
                      "64:ff9b::a00:1", "2002:a00:1::1"):
            with self.subTest(addrs):
                status, connects = self.attempt(addrs)
                self.assertEqual(status, 403)
                self.assertEqual(connects, [])

    def test_a_global_set_is_tried_at_its_exact_vetted_addresses(self):
        status, connects = self.attempt("1.1.1.1,2606:4700:4700::1111")
        self.assertEqual(status, 200)
        self.assertIn(connects[:1], (["1.1.1.1 443"], ["2606:4700:4700::1111 443"]))
        self.assertTrue(set(connects) <= {"1.1.1.1 443", "2606:4700:4700::1111 443"}, connects)


class SniTest(unittest.TestCase):
    """§3c.3: after the 200, the first TLS record must be a ClientHello whose
    SNI is the CONNECT host; only then is the upstream connected."""

    def setUp(self):
        self.upstream = Listener(self)
        self.d = Netd(self, "--test-allow", f"{FAKE}={self.upstream.port}")
        self.assertTrue(self.d.ready())

    def tunnel(self, first, pipelined=False):
        s = self.d.proxy()
        head = b"CONNECT fake.zb.invalid:443 HTTP/1.1\r\nHost: fake.zb.invalid:443\r\n\r\n"
        if pipelined:
            s.sendall(head + first)
            got = response_head(s)
        else:
            s.sendall(head)
            got = response_head(s)
            s.sendall(first)
        self.assertEqual(status_of(got), 200)
        s.shutdown(socket.SHUT_WR)
        s.settimeout(5)
        try:
            while s.recv(4096):
                pass
        except OSError:
            pass
        time.sleep(0.5)

    def test_a_wrong_sni_or_a_non_tls_first_byte_closes_without_an_upstream_connect(self):
        for first in (client_hello("other.example"), b"GET / HTTP/1.1\r\nHost: fake.zb.invalid\r\n\r\n"):
            with self.subTest(first[:12]):
                self.tunnel(first)
        self.assertEqual(self.d.connects(), [])
        self.assertEqual(self.upstream.accepted, [])

    def test_a_matching_client_hello_reaches_the_upstream_byte_for_byte_pipelined_or_not(self):
        hello = client_hello(FAKE)
        for pipelined in (False, True):
            with self.subTest(pipelined=pipelined):
                before = len(self.upstream.accepted)
                self.tunnel(hello, pipelined)
                self.assertEqual(len(self.upstream.accepted), before + 1)
                self.assertEqual(bytes(self.upstream.accepted[-1]), hello)
        self.assertEqual(self.d.connects(), [f"127.0.0.1 {self.upstream.port}"] * 2)


class RetryAndLogTest(unittest.TestCase):
    def test_thirty_refusals_of_one_host_log_one_sanitized_line(self):
        d = Netd(self)
        self.assertTrue(d.ready())
        for _ in range(30):
            s = d.proxy()
            s.sendall(b"CONNECT nope.example:443 HTTP/1.1\r\n\r\n")
            self.assertEqual(status_of(response_head(s)), 403)
            s.close()
        s = d.proxy()  # control characters never reach the log
        s.sendall(b"CONNECT evil\x1b[2Jhost.example:443 HTTP/1.1\r\n\r\n")
        response_head(s)
        self.assertEqual(d.stop(), 0)
        time.sleep(0.2)
        err = "\n".join(d.err)
        self.assertEqual(err.count("zigBrowser: agent: network refused nope.example:443"), 1, err)
        self.assertNotIn("\x1b", err)

    def test_sequential_retries_never_hit_the_tunnel_cap(self):
        upstream = Listener(self)
        d = Netd(self, "--test-allow", f"{FAKE}={upstream.port}")
        self.assertTrue(d.ready())
        for _ in range(40):  # more than 16, one at a time
            s = d.proxy()
            s.sendall(b"CONNECT fake.zb.invalid:443 HTTP/1.1\r\n\r\n")
            self.assertEqual(status_of(response_head(s)), 200)
            s.close()


class RecordSeamTest(unittest.TestCase):
    def test_without_the_flag_no_test_connect_line_is_ever_written(self):
        upstream = Listener(self)
        d = Netd(self, "--test-allow", f"{FAKE}={upstream.port}", record=False)
        self.assertTrue(d.ready())
        s = d.proxy()
        s.sendall(b"CONNECT fake.zb.invalid:443 HTTP/1.1\r\n\r\n" + client_hello(FAKE))
        self.assertEqual(status_of(response_head(s)), 200)
        s.shutdown(socket.SHUT_WR)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and not upstream.accepted:
            time.sleep(0.05)
        self.assertEqual(len(upstream.accepted), 1, "the connect happened")
        self.assertEqual(d.stop(), 0)
        time.sleep(0.2)
        self.assertEqual([line for line in d.err if "test-connect" in line], [])


class BridgeTest(unittest.TestCase):
    """§3c.5, §3c.2: each bridge goes to its one fixed host port; bytes and
    half-close pass both ways; a target that is down gives EOF within 1 s."""

    def test_bytes_and_half_close_pass_through_both_bridges(self):
        a, b = Listener(self, reply=b"done-a"), Listener(self, reply=b"done-b")
        d = Netd(self, "--test-bridge", f"51091={a.port}", "--test-bridge", f"31337={b.port}")
        self.assertTrue(d.ready())
        for name, fake, reply in (("port-51091.sock", a, b"done-a"), ("port-31337.sock", b, b"done-b")):
            with self.subTest(name):
                s = d.unix("bridges", name)
                s.sendall(b"payload " + name.encode())
                s.shutdown(socket.SHUT_WR)  # half-close: the fake answers only after it sees EOF
                got = b""
                while chunk := s.recv(4096):
                    got += chunk
                self.assertEqual(got, reply)
                self.assertEqual(bytes(fake.accepted[-1]), b"payload " + name.encode())

    def test_a_bridge_whose_target_is_down_closes_within_one_second(self):
        d = Netd(self, "--test-bridge", f"51091={free_port()}", "--test-bridge", f"31337={free_port()}")
        self.assertTrue(d.ready())
        s = d.unix("bridges", "port-51091.sock")
        started = time.monotonic()
        s.settimeout(5)
        try:
            self.assertEqual(s.recv(1), b"")
        except ConnectionResetError:
            pass
        self.assertLess(time.monotonic() - started, 1.0)

    def test_a_bridge_takes_no_input_that_picks_its_target(self):
        a, other = Listener(self, reply=b"a"), Listener(self, reply=b"other")
        d = Netd(self, "--test-bridge", f"51091={a.port}", "--test-bridge", f"31337={free_port()}")
        self.assertTrue(d.ready())
        s = d.unix("bridges", "port-51091.sock")
        s.sendall(f"CONNECT 127.0.0.1:{other.port} HTTP/1.1\r\n\r\n".encode())
        s.shutdown(socket.SHUT_WR)
        while s.recv(4096):
            pass
        self.assertEqual(other.accepted, [])
        self.assertEqual(len(a.accepted), 1)


if __name__ == "__main__":
    unittest.main()
