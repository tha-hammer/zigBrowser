"""R1 on macOS, the census broker, the probe's half (RoseCat 7019; BlueBeaver 7021; JadeBeacon 7023, 0aa5845): setup's
Seatbelt profile keeps the token-isolation belt, so the probe (and the CLI it tests) cannot read any process. The
process census moves out to setup, which asks nothing of the sandbox: the probe asks setup over a socketpair end that
setup passes in. On Linux with the platform injected (`route_probe.PLATFORM`):

- `--census-fd N` is Darwin-only and required there with --listen-fd/--listen-port: ASCII decimal, no sign, leading
  zero or whitespace, 3 to 2**31-1, given once. Anything else exits 2 with no verdict and runs nothing.
- adopt_census(fd) adopts only an AF_UNIX SOCK_STREAM socket and makes it non-inheritable (the CLI the SDK spawns
  must never hold it); anything else is refused (ProbeRefused) and the fd is closed. A failing set_inheritable is a
  refusal too, for the census end and the listener alike (RoseCat 7041).
- Through the production chain (route_probe.run, the real zb-claude wrapper, a malicious CLI stand-in that lists its
  descriptors and writes "clean" into every socket it holds), the census end never reaches the wrapper or the CLI.
- _ask_census(sock, token, url, timeout) sends exactly b"census <token> <url>\\n", then reads setup's whole reply to
  EOF (setup writes its verdict and shuts its side): True only when that reply is exactly b"clean\\n" within the
  deadline; "dirty", trailing bytes, anything else, EOF with nothing, or silence is False.
- On Darwin the server asks the census (its own url) and never walks processes itself; without a census socket the
  verdict is False. Linux keeps its /proc check.

Run like the gate: cd agent/host/tests && python -X dev -m unittest -v test_route_probe_census. Unregistered until the
green.
"""
import contextlib
import io
import json
import os
import socket
import stat
import subprocess
import tempfile
import threading
import time
import unittest
import urllib.request
from unittest import mock

import support  # noqa: F401  (puts the helper package on sys.path)

from zb_agent_host import proc_darwin, route_probe, token

TOKEN = "zb-probe-" + "cd" * 24


def _closed(fd):
    try:
        os.fstat(fd)
    except OSError:
        return True
    return False


class Base(unittest.TestCase):
    def setUp(self):
        for name in ("adopt_census", "_ask_census"):
            if not hasattr(route_probe, name):
                self.fail(f"route_probe.{name} is missing (the census broker, 7021)")
        self.addCleanup(mock.patch.stopall)

    def pair(self):
        a, b = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
        self.addCleanup(a.close)
        self.addCleanup(b.close)
        return a, b


class AdoptCensus(Base):
    def test_a_unix_stream_socket_is_adopted_non_inheritable(self):
        a, b = self.pair()
        a.set_inheritable(True)  # as an fd that came through pass_fds is
        fd = a.detach()
        sock = route_probe.adopt_census(fd)
        self.addCleanup(sock.close)
        self.assertEqual((sock.family, sock.type), (socket.AF_UNIX, socket.SOCK_STREAM))
        self.assertFalse(os.get_inheritable(fd))

    def test_every_other_shape_is_refused_and_closed(self):
        r, w = os.pipe()
        self.addCleanup(lambda: _closed(w) or os.close(w))
        cases = [(r, "a pipe")]
        cases.append((socket.socket(socket.AF_INET, socket.SOCK_STREAM).detach(), "an AF_INET socket"))
        cases.append((socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM).detach(), "an AF_UNIX datagram socket"))
        for fd, why in cases:
            with self.subTest(why=why):
                with self.assertRaises(route_probe.ProbeRefused):
                    route_probe.adopt_census(fd)
                self.assertTrue(_closed(fd), f"{why}: closed")


class AdoptionNeverLeaks(Base):
    """RoseCat 7041 #1: the census socket is the probe's only authenticator (the CLI knows the probe token), so it
    must never reach the CLI, and an adoption that cannot make it non-inheritable must refuse, not continue."""

    def test_a_failed_set_inheritable_refuses_and_closes(self):
        for adopt in ("census", "listener"):
            with self.subTest(adopt=adopt):
                if adopt == "census":
                    a, _b = self.pair()
                    fd, call = a.detach(), (lambda fd: route_probe.adopt_census(fd))
                else:
                    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                    s.bind(("127.0.0.1", 0))
                    s.listen(1)
                    port = s.getsockname()[1]
                    fd, call = s.detach(), (lambda fd, port=port: route_probe.adopt_listener(fd, port))
                with mock.patch.object(socket.socket, "set_inheritable", side_effect=OSError(22, "EINVAL")):
                    with self.assertRaises(route_probe.ProbeRefused):
                        call(fd)
                self.assertTrue(_closed(fd), "a socket that could not be made non-inheritable is closed")

    def stand_in(self):
        """The production wrapper (token.write_wrapper) in front of a malicious CLI stand-in; returns (wrapper, cli,
        records) where records() reads what every stand-in run held."""
        root = tempfile.mkdtemp(prefix="zb-census-chain-")
        self.addCleanup(lambda: [os.unlink(os.path.join(root, n)) for n in os.listdir(root)] and None or os.rmdir(root))
        log = os.path.join(root, "fds.jsonl")
        cli = os.path.join(root, "claude")
        # A CLI stand-in that records every descriptor it holds (device, inode) and tries to forge "clean" into
        # every socket among them; then it exits, so the SDK's turn ends at once.
        with open(cli, "w") as f:
            f.write(f"""#!/usr/bin/python3 -I
import json, os, stat
seen = []
for fd in range(0, 1024):
    try:
        st = os.fstat(fd)
    except OSError:
        continue
    forged = False
    if stat.S_ISSOCK(st.st_mode):
        try:
            os.write(fd, b"clean\\n")
            forged = True
        except OSError:
            pass
    seen.append([fd, st.st_dev, st.st_ino, forged])
with open({log!r}, "a") as out:
    out.write(json.dumps(seen) + "\\n")
raise SystemExit(1)
""")
        os.chmod(cli, 0o700)
        wrapper = os.path.join(root, "zb-claude")
        token.write_wrapper(wrapper, cli)

        def records():
            with open(log) as f:
                return [json.loads(line) for line in f]
        return wrapper, cli, records

    @staticmethod
    def received(setup_end):
        setup_end.setblocking(False)
        try:
            return setup_end.recv(64)
        except BlockingIOError:
            return b""

    def test_the_production_wrapper_and_a_malicious_cli_never_hold_the_census_end(self):
        wrapper, cli, records = self.stand_in()
        probe_end, setup_end = self.pair()
        probe_end.set_inheritable(True)  # as an fd that came through pass_fds is
        census = route_probe.adopt_census(probe_end.detach())
        st = os.fstat(census.fileno())
        census_id = (st.st_dev, st.st_ino)
        route_probe.run(wrapper, cli, census=census)
        seen = records()
        self.assertTrue(seen, "the CLI stand-in ran through the production wrapper")
        held = {(dev, ino) for record in seen for _fd, dev, ino, _forged in record}
        self.assertNotIn(census_id, held, "neither the wrapper nor the CLI holds the census end")
        self.assertNotIn(b"clean", self.received(setup_end), "nothing reached setup's end from the CLI side")

    def test_positive_control_a_stand_in_given_the_census_end_does_report_and_forge(self):
        # The oracle is not vacuous: hand the end to the same wrapper + stand-in on purpose (pass_fds), and the
        # stand-in finds it and forges "clean" into it, which setup's end receives.
        wrapper, cli, records = self.stand_in()
        probe_end, setup_end = self.pair()
        st = os.fstat(probe_end.fileno())
        subprocess.run([cli], pass_fds=(probe_end.fileno(),), timeout=30, check=False)
        held = {(dev, ino): forged for record in records() for _fd, dev, ino, forged in record}
        self.assertIn((st.st_dev, st.st_ino), held, "the stand-in reports a census end it holds")
        self.assertTrue(held[(st.st_dev, st.st_ino)], "and forges into it")
        self.assertIn(b"clean", self.received(setup_end))


class AskCensus(Base):
    URL = "http://127.0.0.1:50123"

    def ask(self, reply, timeout=5):
        probe_end, setup_end = self.pair()
        got = []

        def setup_side():
            data = b""
            while not data.endswith(b"\n"):
                chunk = setup_end.recv(512)
                if not chunk:
                    break
                data += chunk
            got.append(data)
            if reply is not None:
                setup_end.sendall(reply)
                setup_end.shutdown(socket.SHUT_WR)  # setup's verdict, then EOF
        t = threading.Thread(target=setup_side, daemon=True)
        t.start()
        started = time.monotonic()
        verdict = route_probe._ask_census(probe_end, TOKEN, self.URL, timeout=timeout)
        elapsed = time.monotonic() - started
        t.join(5)
        return verdict, got, elapsed

    def test_the_request_is_exact_and_only_clean_is_clean(self):
        verdict, got, _ = self.ask(b"clean\n")
        self.assertIs(verdict, True)
        self.assertEqual(got, [f"census {TOKEN} {self.URL}\n".encode()])

    def test_every_other_reply_is_not_clean(self):
        for reply in (b"dirty\n", b"", b"clean", b"clean\nclean\n", b"CLEAN\n", b"clean \n", b"cleanx\n"):
            with self.subTest(reply=reply):
                self.assertIs(self.ask(reply)[0], False)

    def test_silence_is_not_clean_within_the_deadline(self):
        verdict, _, elapsed = self.ask(None, timeout=1)
        self.assertIs(verdict, False)
        self.assertLess(elapsed, 3)

    def test_a_partial_reply_from_a_live_peer_is_not_clean_within_the_deadline(self):
        # RoseCat 7041 #2: setup's end stays open after "cle" (no newline, no EOF): the deadlock shape.
        probe_end, setup_end = self.pair()

        def setup_side():
            setup_end.recv(512)
            setup_end.sendall(b"cle")
        threading.Thread(target=setup_side, daemon=True).start()
        started = time.monotonic()
        self.assertIs(route_probe._ask_census(probe_end, TOKEN, self.URL, timeout=1), False)
        self.assertLess(time.monotonic() - started, 3)


class ServerAsksTheCensus(Base):
    def test_on_darwin_the_server_asks_setup_and_never_walks_processes(self):
        mock.patch.object(route_probe, "PLATFORM", "darwin").start()
        mock.patch.object(proc_darwin, "descendants_running",
                          side_effect=AssertionError("the probe must not inspect processes")).start()
        probe_end, setup_end = self.pair()
        asked = []

        def setup_side():
            asked.append(setup_end.recv(512))
            setup_end.sendall(b"clean\n")
            setup_end.shutdown(socket.SHUT_WR)
        threading.Thread(target=setup_side, daemon=True).start()
        server = route_probe._ProbeServer(TOKEN, "/opt/claude", census=probe_end)
        self.addCleanup(server.close)
        req = urllib.request.Request(f"{server.url}/v1/messages", data=b"{}", method="POST",
                                     headers={"content-type": "application/json", "authorization": "Bearer b"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            resp.read()
        self.assertEqual(asked, [f"census {TOKEN} {server.url}\n".encode()])
        self.assertIs(server.cli_env_clean, True)

    def test_on_darwin_without_a_census_socket_it_is_not_clean(self):
        mock.patch.object(route_probe, "PLATFORM", "darwin").start()
        mock.patch.object(proc_darwin, "descendants_running",
                          side_effect=AssertionError("the probe must not inspect processes")).start()
        self.assertIs(route_probe._cli_env_clean("/opt/claude", TOKEN, b"ANTHROPIC_BASE_URL=http://127.0.0.1:1"),
                      False)


class Main(Base):
    def setUp(self):
        super().setUp()
        self.runs = []

        def fake_run(wrapper, cli, listener=None, census=None):
            self.runs.append((listener is not None, census is not None))
            for s in (listener, census):
                if s is not None:
                    s.close()
            return True

        mock.patch.object(route_probe, "run", side_effect=fake_run).start()

    def main(self, platform, extra):
        mock.patch.object(route_probe, "PLATFORM", platform).start()
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = route_probe.main(["--wrapper", "/w/zb-claude", "--cli", "/c/claude", *extra])
        return code, out.getvalue(), err.getvalue()

    def listener(self):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.bind(("127.0.0.1", 0))
        s.listen(1)
        port = s.getsockname()[1]
        fd = s.detach()
        self.addCleanup(lambda: _closed(fd) or os.close(fd))
        return fd, port

    def census_fd(self):
        a, b = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
        self.addCleanup(b.close)
        fd = a.detach()
        self.addCleanup(lambda: _closed(fd) or os.close(fd))
        return fd

    def test_darwin_runs_with_listener_and_census(self):
        lfd, port = self.listener()
        cfd = self.census_fd()
        code, out, err = self.main("darwin", ["--listen-fd", str(lfd), "--listen-port", str(port),
                                              "--census-fd", str(cfd)])
        self.assertEqual((code, json.loads(out)), (0, {"r1": True}), err)
        self.assertEqual(self.runs, [(True, True)])

    def test_darwin_census_fd_grammar_is_exact(self):
        # The listener table's spellings (RoseCat 7041 SHOULD), plus a non-number.
        bad = ["0", "1", "2", "-1", "-3", "+3", "03", " 3", "3 ", "3\n", "2147483648", "9999999999", "9" * 30, "",
               "\u0663", "x"]
        for value in [None, *bad, "twice"]:
            with self.subTest(value=value):
                self.runs.clear()
                lfd, port = self.listener()
                extra = ["--listen-fd", str(lfd), "--listen-port", str(port)]
                if value == "twice":
                    cfd = self.census_fd()
                    extra += ["--census-fd", str(cfd), "--census-fd", str(cfd)]
                elif value is not None:
                    extra += ["--census-fd", value]
                code, out, err = self.main("darwin", extra)
                self.assertEqual((code, out), (2, ""), err)
                self.assertEqual(self.runs, [])

    def test_linux_refuses_the_census_flag(self):
        cfd = self.census_fd()
        code, out, err = self.main("linux", ["--census-fd", str(cfd)])
        self.assertEqual((code, out), (2, ""), err)
        self.assertEqual(self.runs, [])


if __name__ == "__main__":
    unittest.main()
