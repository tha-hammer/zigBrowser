"""S3n1 (chat-drawer plan rev 16.2, §3c.2, §3c.8b): the two relays, driven
only through their command lines, each inside its own private network and
PID namespace (bwrap), so their loopback ports never touch the host's.

    outer, proxy-only:  python3 -m zb_agent_host.relay --egress DIR -- CMD...
                        127.0.0.1:3128 -> DIR/proxy.sock
    inner, per hook:    /usr/bin/python3 -I -S <zb_agent_host.relay.BRIDGE_RELAY_FILE>
                            --bridges DIR -- CMD...
                        127.0.0.1:51091 -> DIR/port-51091.sock, :31337 -> DIR/port-31337.sock

The Unix sockets are private fakes served by this test process (pathname
sockets cross network namespaces). Nothing reaches the network.

Signals (BlueBeaver 5505): a relay forwards only signals sent to its own PID.
A signal to the bwrap PID kills the whole sandbox (--die-with-parent and the
PID namespace teardown), as it does for an unsealed hook today."""

import json
import os
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid
from pathlib import Path

HOST_DIR = Path(__file__).resolve().parents[1]
BWRAP = "/usr/bin/bwrap"
sys.path.insert(0, str(HOST_DIR))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_netd import _Counting, alive, child_env, reap, short_root, tree_of  # noqa: E402


def bridge_relay_file():
    from zb_agent_host import relay  # S3n1 provides it; until then this is the red
    return str(relay.BRIDGE_RELAY_FILE)


def sandboxed(argv):
    """`argv` in its own network and PID namespace; the host stays as it is."""
    return [BWRAP, "--unshare-net", "--unshare-pid", "--die-with-parent", "--dev-bind", "/", "/", "--proc", "/proc",
            "--", *argv]


def outer_argv(egress, cmd):
    return sandboxed([sys.executable, "-m", "zb_agent_host.relay", "--egress", str(egress), "--", *cmd])


def inner_argv(bridges, cmd):
    return sandboxed(["/usr/bin/python3", "-I", "-S", bridge_relay_file(), "--bridges", str(bridges), "--", *cmd])


class UnixFake:
    """A pathname socket server: records each connection, answers `reply`
    after the client half-closes."""

    def __init__(self, tc, path, reply):
        self.path, self.reply, self.accepted = Path(path), reply, []
        self.path.parent.mkdir(mode=0o700, exist_ok=True)
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.bind(str(self.path))
        self.sock.listen(16)
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
            try:
                while chunk := conn.recv(65536):
                    data += chunk
                conn.sendall(self.reply)
            except OSError:
                pass


# The program a relay runs: it probes its ports and descriptors, prints one
# JSON line, and exits with the code given as argv[1].
PROBE = r"""
import json, os, socket, sys
def talk(port):
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=3)
    except OSError as e:
        return "refused"
    s.sendall(b"ping-%d" % port)
    s.shutdown(socket.SHUT_WR)
    got = b""
    while True:
        chunk = s.recv(4096)
        if not chunk:
            break
        got += chunk
    return got.decode()
def open_fds():
    out = []
    for fd in range(3, 256):
        try:
            os.fstat(fd)
            out.append(fd)
        except OSError:
            pass
    return out
print(json.dumps({"3128": talk(3128), "51091": talk(51091), "31337": talk(31337), "fds": open_fds()}), flush=True)
sys.exit(int(sys.argv[1]))
"""


def probe(code=0):
    return ["/usr/bin/python3", "-I", "-S", "-c", PROBE, str(code)]


def run(argv, tc, pass_fds=(), timeout=60, **kw):
    return subprocess.run(argv, env=child_env(), capture_output=True, text=True, timeout=timeout, pass_fds=pass_fds,
                          **kw)


class OuterRelayTest(unittest.TestCase):
    """§3c.2: proxy-only; status and signals pass through; fd 3 never survives."""

    def setUp(self):
        self.root = short_root(self)
        self.egress = UnixFake(self, self.root / "egress" / "proxy.sock", b"from-egress")

    def test_only_3128_is_relayed_to_the_egress_socket_and_the_status_passes_through(self):
        canary = os.open(os.devnull, os.O_RDONLY)  # stands in for the token's fd 3
        self.addCleanup(os.close, canary)
        done = run(outer_argv(self.root / "egress", probe(7)), self, pass_fds=(canary,))
        self.assertEqual(done.returncode, 7, done.stderr)
        seen = json.loads(done.stdout.splitlines()[-1])
        self.assertEqual(seen["3128"], "from-egress")
        self.assertEqual((seen["51091"], seen["31337"]), ("refused", "refused"), "the outer relay is proxy-only")
        self.assertEqual(seen["fds"], [], "fd 3 and every other inherited descriptor are closed for the child")
        self.assertEqual(bytes(self.egress.accepted[-1]), b"ping-3128")

    def test_a_real_fd_3_reaches_the_helper_readable_and_the_relay_keeps_no_copy(self):
        """When the app starts the sandbox, the token's socket is fd 3 (§3c.2, D11).
        The helper must receive exactly that descriptor and read from it, an
        arbitrary other inherited descriptor must not survive, and the relay
        itself must hold no copy (RoseCat 5527)."""
        token_end, helper_end = socket.socketpair()
        self.addCleanup(token_end.close)
        self.addCleanup(helper_end.close)
        token_ino = os.fstat(helper_end.fileno()).st_ino
        stray = os.open(os.devnull, os.O_RDONLY)
        self.addCleanup(os.close, stray)
        report = self.root / "helper.json"
        child = ["/usr/bin/python3", "-I", "-S", "-c",
                 "import json, os, time\n"
                 "got = os.read(3, 64).decode()\n"
                 "fds = [fd for fd in range(3, 256) if os.path.exists(f'/proc/self/fd/{fd}')]\n"
                 f"open({str(report)!r} + '.tmp', 'w').write(json.dumps({{'got': got, 'ino': os.fstat(3).st_ino, 'fds': fds}}))\n"
                 f"os.rename({str(report)!r} + '.tmp', {str(report)!r})\n"
                 "time.sleep(30)\n"]
        token_end.sendall(b"canary-token")
        helper_fd = helper_end.fileno()
        proc = subprocess.Popen(outer_argv(self.root / "egress", child), env=child_env(), pass_fds=(3, stray),
                                preexec_fn=lambda: os.dup2(helper_fd, 3))
        self.addCleanup(reap, proc)
        wait_for(lambda: report.exists(), 20)
        seen = json.loads(report.read_text())
        self.assertEqual(seen["got"], "canary-token", "the helper reads the token from fd 3")
        self.assertEqual(seen["ino"], token_ino, "fd 3 in the helper is the app's token socket")
        self.assertEqual(seen["fds"], [3], "exactly fd 3 is inherited; the stray descriptor is closed")
        relay = only(outer_relays(proc.pid))
        held = [os.readlink(f"/proc/{relay}/fd/{n}") for n in os.listdir(f"/proc/{relay}/fd")]
        self.assertNotIn(f"socket:[{token_ino}]", held, "the relay keeps no copy of the token socket")

    def test_sigterm_reaches_the_child_and_its_status_comes_back(self):
        marker = self.root / "trapped"
        child = ["/usr/bin/python3", "-I", "-S", "-c",
                 "import signal, sys, time, pathlib\n"
                 f"def h(*_):\n    pathlib.Path({str(marker)!r}).write_text('ok'); sys.exit(5)\n"
                 "signal.signal(signal.SIGTERM, h)\n"
                 f"pathlib.Path({str(marker)!r} + '.ready').write_text('ok')\n"
                 "time.sleep(60)\n"]
        proc = subprocess.Popen(outer_argv(self.root / "egress", child), env=child_env())
        self.addCleanup(reap, proc)
        wait_for(lambda: Path(str(marker) + ".ready").exists(), 20)
        relay = only(outer_relays(proc.pid))
        os.kill(relay, signal.SIGTERM)
        self.assertEqual(proc.wait(timeout=20), 5)
        self.assertEqual(marker.read_text(), "ok")

    def test_sigterm_to_the_bwrap_pid_ends_every_process_within_one_second(self):
        ready = self.root / "ready"
        assert_sigterm_to_bwrap_ends_everything(self, outer_argv(self.root / "egress", sleeper(ready)), ready)


def assert_sigterm_to_bwrap_ends_everything(tc, argv, ready):
    proc = subprocess.Popen(argv, env=child_env())
    tc.addCleanup(reap, proc)
    wait_for(lambda: ready.exists(), 20)
    tree = tree_of(proc.pid)
    tc.assertGreaterEqual(len(tree), 3, "bwrap, the relay and the child")
    os.kill(proc.pid, signal.SIGTERM)
    proc.wait(timeout=5)
    wait_for(lambda: not alive(tree), 1.0)
    tc.assertEqual(alive(tree), [], "a process outlived its sandbox")


def sleeper(ready):
    return ["/bin/sh", "-c", f"touch {ready}; while :; do sleep 0.1; done"]


class InnerRelayTest(unittest.TestCase):
    """§3c.8b: bridge-only, one per hook run."""

    def setUp(self):
        self.root = short_root(self)
        self.bridges = self.root / "bridges"
        self.b1 = UnixFake(self, self.bridges / "port-51091.sock", b"from-51091")
        self.b2 = UnixFake(self, self.bridges / "port-31337.sock", b"from-31337")

    def test_both_bridges_carry_bytes_and_3128_does_not_exist(self):
        done = run(inner_argv(self.bridges, probe(0)), self)
        self.assertEqual(done.returncode, 0, done.stderr)
        seen = json.loads(done.stdout.splitlines()[-1])
        self.assertEqual((seen["51091"], seen["31337"]), ("from-51091", "from-31337"))
        self.assertEqual(seen["3128"], "refused", "a hook has no proxy port")
        self.assertEqual(seen["fds"], [], "the hook inherits only 0, 1 and 2")
        self.assertEqual((bytes(self.b1.accepted[-1]), bytes(self.b2.accepted[-1])), (b"ping-51091", b"ping-31337"))

    def test_a_bridge_whose_socket_is_missing_closes_the_hook_connection_within_one_second(self):
        (self.bridges / "port-31337.sock").unlink()
        child = ["/usr/bin/python3", "-I", "-S", "-c",
                 "import socket, time\n"
                 "s = socket.create_connection(('127.0.0.1', 31337), timeout=3)\n"
                 "t = time.monotonic(); s.settimeout(5)\n"
                 "eof = s.recv(1) == b''\n"
                 "print(eof, round(time.monotonic() - t, 3))\n"]
        done = run(inner_argv(self.bridges, child), self)
        eof, took = done.stdout.split()
        self.assertEqual(eof, "True", done.stderr)
        self.assertLess(float(took), 1.0)

    def test_a_bad_argv_exits_2_before_any_command_runs(self):
        marker = self.root / "ran"
        for argv in (["--bridges", str(self.bridges)], ["--bridges", str(self.bridges), "--"],
                     ["--", "/usr/bin/touch", str(marker)], ["--nope", "x", "--", "/usr/bin/touch", str(marker)]):
            with self.subTest(argv):
                done = run(sandboxed(["/usr/bin/python3", "-I", "-S", bridge_relay_file(), *argv]), self)
                self.assertEqual(done.returncode, 2, done.stderr)
                self.assertFalse(marker.exists())

    def test_the_status_matches_an_unsealed_run(self):
        """Exit 2 means "block" to the CLI, so the relay must pass every status on unchanged."""
        cases = [["/bin/sh", "-c", "exit 0"], ["/bin/sh", "-c", "exit 2"], ["/bin/sh", "-c", "exit 7"],
                 ["/bin/sh", "-c", "kill -TERM $$"], ["zb-no-such-command-" + uuid.uuid4().hex[:8]]]
        for cmd in cases:
            with self.subTest(cmd):
                unsealed = run(sandboxed(cmd), self).returncode
                sealed = run(inner_argv(self.bridges, cmd), self).returncode
                self.assertEqual(sealed, unsealed)

    def test_stdio_passes_through_and_stdout_eof_matches_plain_bwrap(self):
        """bwrap itself keeps the child's fd 1 until it exits (BlueBeaver 5512,
        RoseCat 5514), so EOF timing is compared with the same command under
        plain bwrap; the descriptor census proves the relay's own fd 1 is /dev/null."""
        data = os.urandom(1 << 20)
        done = subprocess.run(inner_argv(self.bridges, ["/bin/cat"]), input=data, capture_output=True,
                              env=child_env(), timeout=60)
        self.assertEqual(done.returncode, 0)
        self.assertEqual(done.stdout, data)
        closes_stdout = ["/bin/sh", "-c", "exec 1>&-; sleep 2"]
        plain, sealed = eof_after(sandboxed(closes_stdout)), eof_after(inner_argv(self.bridges, closes_stdout))
        self.assertLess(abs(sealed - plain), 1.0, f"EOF after {sealed:.2f} s sealed, {plain:.2f} s under plain bwrap")

    def test_sigterm_to_the_relay_reaches_the_hook(self):
        marker = self.root / "trapped"
        child = ["/bin/sh", "-c", f"trap 'echo ok > {marker}; exit 9' TERM; touch {marker}.ready; while :; do sleep 0.1; done"]
        proc = subprocess.Popen(inner_argv(self.bridges, child), env=child_env())
        self.addCleanup(reap, proc)
        wait_for(lambda: Path(str(marker) + ".ready").exists(), 20)
        relay = only(inner_relays(proc.pid))
        os.kill(relay, signal.SIGTERM)
        self.assertEqual(proc.wait(timeout=20), 9)
        self.assertEqual(marker.read_text().strip(), "ok")

    def test_sigterm_to_the_bwrap_pid_ends_every_process_within_one_second(self):
        ready = self.root / "ready"
        assert_sigterm_to_bwrap_ends_everything(self, inner_argv(self.bridges, sleeper(ready)), ready)

    def test_no_orphan_outlives_the_hook_or_a_killed_relay(self):
        for case in ("hook exits", "relay killed"):
            with self.subTest(case):
                canary = f"ZB_ORPHAN_{uuid.uuid4().hex}"
                # A double-forked, setsid grandchild that holds a bridge connection open.
                child = ["/usr/bin/python3", "-I", "-S", "-c",
                         "import os, socket, sys, time\n"
                         "if os.fork() == 0:\n"
                         "    os.setsid()\n"
                         "    if os.fork() == 0:\n"
                         "        s = socket.create_connection(('127.0.0.1', 51091), timeout=3)\n"
                         f"        os.execv('/usr/bin/python3', ['python3', '-c', 'import time; time.sleep(60)', {canary!r}])\n"
                         "    os._exit(0)\n"
                         "time.sleep(0.5)\n"
                         f"if {case == 'relay killed'!r}:\n"
                         "    time.sleep(60)\n"]
                proc = subprocess.Popen(inner_argv(self.bridges, child), env=child_env())
                self.addCleanup(reap, proc)
                wait_for(lambda: running(canary), 20)
                if case == "relay killed":
                    # Waited for, like the descriptor census: one /proc walk can miss it (a gate flake).
                    relay = only(wait_for(lambda: inner_relays(proc.pid), 20))
                    os.kill(relay, signal.SIGKILL)
                proc.wait(timeout=20)
                wait_for(lambda: not running(canary), 1.0)
                self.assertEqual(running(canary), [], f"{case}: an orphan survived")

    def test_the_relay_holds_only_its_own_descriptors(self):
        # stdout stays a pipe: the census must see the relay replace it with /dev/null.
        proc = subprocess.Popen(inner_argv(self.bridges, ["/bin/sleep", "3"]), env=child_env(), stdout=subprocess.PIPE)
        self.addCleanup(reap, proc)
        relay = only(wait_for(lambda: inner_relays(proc.pid), 20))
        time.sleep(0.5)
        fds = {int(n): os.readlink(f"/proc/{relay}/fd/{n}") for n in os.listdir(f"/proc/{relay}/fd")}
        self.assertEqual((fds.get(0), fds.get(1)), ("/dev/null", "/dev/null"), "the relay keeps no stdin/stdout pipe")
        rest = sorted(v.split(":")[0] if v.startswith(("socket:", "anon_inode:")) else v
                      for n, v in fds.items() if n > 2)
        kinds = sorted(v for n, v in fds.items() if n > 2)
        self.assertEqual(rest.count("socket"), 2, f"two listeners: {kinds}")
        self.assertEqual(sorted(k for k in kinds if k.startswith("anon_inode:")),
                         ["anon_inode:[eventpoll]", "anon_inode:[pidfd]"], kinds)
        self.assertEqual(len(kinds), 4, kinds)
        proc.wait(timeout=20)


class PairBufferTest(unittest.TestCase):
    def test_each_direction_of_a_relayed_connection_holds_at_most_buffer_max_bytes(self):
        """The relays' per-direction bound (BlueBeaver 5496) holds after a partial
        write to a slow reader, as netd's does (RoseCat 5535)."""
        from zb_agent_host import relay
        a0, writer = socket.socketpair()
        b0, sink = socket.socketpair()  # `sink` never reads
        sink.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024)
        b0.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 1024)
        a, b = _Counting(fileno=a0.detach()), _Counting(fileno=b0.detach())
        a.partner, b.partner = b, a
        for sock in (writer, sink, a, b):
            self.addCleanup(sock.close)
        loop = relay.Relay("bridges", "/nonexistent")
        self.addCleanup(loop.selector.close)
        relay.Pair(loop, a, b)
        writer.setblocking(False)
        until = time.monotonic() + 0.5
        while time.monotonic() < until:
            try:
                writer.send(b"y" * 65536)
            except BlockingIOError:
                pass
            for key, mask in loop.selector.select(0.005):
                key.data.handle(key.fileobj, mask)
        self.assertGreater(a.received, relay.BUFFER_MAX, "the test must fill the buffer to mean anything")
        self.assertLessEqual(a.peak, relay.BUFFER_MAX, f"buffered {a.peak} bytes in one direction")


def eof_after(argv):
    """Seconds until the reader of argv's stdout sees EOF."""
    proc = subprocess.Popen(argv, stdout=subprocess.PIPE, env=child_env())
    started = time.monotonic()
    try:
        proc.stdout.read()
        return time.monotonic() - started
    finally:
        proc.stdout.close()
        proc.wait(timeout=20)


def relays(root, interpreter, argv_has):
    """The relay processes under `root`: the expected Python interpreter
    (/proc/<pid>/exe) with the relay in its argv. bwrap's two processes carry
    the same argv as arguments, but their executable is bwrap (RoseCat 5514)."""
    want = os.path.realpath(interpreter)
    found = []
    for pid in tree_of(root):
        try:
            exe = os.path.realpath(f"/proc/{pid}/exe")
        except OSError:
            continue
        if exe == want and argv_has(cmdline(pid).split(b"\0")):
            found.append(pid)
    return found


def outer_relays(root):
    return relays(root, sys.executable, lambda argv: argv[1:4] == [b"-m", b"zb_agent_host.relay", b"--egress"])


def inner_relays(root):
    return relays(root, "/usr/bin/python3",
                  lambda argv: argv[1:5] == [b"-I", b"-S", bridge_relay_file().encode(), b"--bridges"])


def cmdline(pid):
    try:
        return Path(f"/proc/{pid}/cmdline").read_bytes()
    except OSError:
        return b""


def running(marker):
    pids = []
    for entry in os.listdir("/proc"):
        if entry.isdigit() and marker.encode() in cmdline(entry):
            try:
                if Path(f"/proc/{entry}/stat").read_text().rsplit(")", 1)[1].split()[0] != "Z":
                    pids.append(int(entry))
            except OSError:
                pass
    return pids


def wait_for(predicate, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.05)
    return predicate()


def only(items):
    items = list(items)
    if len(items) != 1:
        raise AssertionError(f"expected exactly one process, found {items}")
    return items[0]


if __name__ == "__main__":
    unittest.main()
