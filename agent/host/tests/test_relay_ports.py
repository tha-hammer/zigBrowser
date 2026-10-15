"""MS0 slice E (RoseCat 5750/5752; JadeBeacon 5753, BlueBeaver 5755): the inner
relay binds the bridge ports the backend supplies.

    /usr/bin/python3 -I -S <BRIDGE_RELAY_FILE> --bridges DIR [--ports P1,P2,...] -- HOOK...
                        127.0.0.1:Pn -> DIR/port-Pn.sock, for each given port

`--ports` is 1 to 8 distinct ports, each 1 to 65535, written as plain decimal
digits with no sign, space or leading zero, comma-separated. It comes only
after `--bridges DIR`, at most once, and never with `--egress` (the outer
relay's 3128 is fixed). Anything else exits 2 before the hook runs. Without
`--ports` the relay binds the fixed BRIDGES map, byte-identical to today
(test_relay.py pins that).

Driven only through the command line, each relay in its own network and PID
namespace; the Unix sockets are private fakes. Nothing reaches the network."""

import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_netd import short_root  # noqa: E402
from test_relay import UnixFake, bridge_relay_file, run, sandboxed  # noqa: E402

# Talks to each port in argv[1:] and prints {port: reply or "refused"} and the
# descriptors it inherited above 2.
PROBE = r"""
import json, os, socket, sys
def talk(port):
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=3)
    except OSError:
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
fds = []
for fd in range(3, 256):
    try:
        os.fstat(fd)
        fds.append(fd)
    except OSError:
        pass
print(json.dumps({"ports": {p: talk(int(p)) for p in sys.argv[1:]}, "fds": fds}), flush=True)
"""


def relay(bridges, *options, cmd):
    return sandboxed(["/usr/bin/python3", "-I", "-S", bridge_relay_file(), *options, "--", *cmd])


def probe(*ports):
    return ["/usr/bin/python3", "-I", "-S", "-c", PROBE, *map(str, ports)]


class PortsTest(unittest.TestCase):
    def setUp(self):
        self.root = short_root(self)
        self.bridges = self.root / "bridges"

    def test_the_given_ports_and_only_they_are_relayed_to_their_sockets(self):
        a = UnixFake(self, self.bridges / "port-40101.sock", b"from-40101")
        b = UnixFake(self, self.bridges / "port-40102.sock", b"from-40102")
        UnixFake(self, self.bridges / "port-51091.sock", b"from-51091")  # served, but not given
        done = run(relay(self.bridges, "--bridges", str(self.bridges), "--ports", "40101,40102",
                         cmd=probe(40101, 40102, 51091, 31337, 3128)), self)
        self.assertEqual(done.returncode, 0, done.stderr)
        seen = json.loads(done.stdout.splitlines()[-1])
        self.assertEqual(seen["ports"], {"40101": "from-40101", "40102": "from-40102", "51091": "refused",
                                         "31337": "refused", "3128": "refused"})
        self.assertEqual(seen["fds"], [], "the hook inherits only 0, 1 and 2")
        self.assertEqual((bytes(a.accepted[-1]), bytes(b.accepted[-1])), (b"ping-40101", b"ping-40102"))

    def test_one_port_and_eight_ports_are_accepted(self):
        for ports in ([40111], list(range(40121, 40129))):
            with self.subTest(len(ports)):
                for port in ports:
                    UnixFake(self, self.bridges / f"port-{port}.sock", b"from-%d" % port)
                done = run(relay(self.bridges, "--bridges", str(self.bridges), "--ports", ",".join(map(str, ports)),
                                 cmd=probe(*ports)), self)
                self.assertEqual(done.returncode, 0, done.stderr)
                seen = json.loads(done.stdout.splitlines()[-1])
                self.assertEqual(seen["ports"], {str(p): f"from-{p}" for p in ports})

    def test_a_bad_ports_option_exits_2_before_any_command_runs(self):
        marker = self.root / "ran"
        touch = ["/usr/bin/touch", str(marker)]
        bridges = ["--bridges", str(self.bridges)]
        cases = {
            "empty": [*bridges, "--ports", ""],
            "a lone comma": [*bridges, "--ports", ","],
            "a trailing comma": [*bridges, "--ports", "51091,"],
            "zero": [*bridges, "--ports", "0"],
            "65536": [*bridges, "--ports", "65536"],
            "a duplicate": [*bridges, "--ports", "51091,51091"],
            "nine ports": [*bridges, "--ports", ",".join(str(p) for p in range(40131, 40140))],
            "not a number": [*bridges, "--ports", "http"],
            "a sign": [*bridges, "--ports", "+51091"],
            "a negative": [*bridges, "--ports", "-1"],
            "a space": [*bridges, "--ports", "51091, 31337"],
            "a leading zero": [*bridges, "--ports", "051091"],
            "hex": [*bridges, "--ports", "0x10"],
            "non-ASCII digits": [*bridges, "--ports", "٥١٠٩١"],
            "no value": [*bridges, "--ports"],
            "twice": [*bridges, "--ports", "51091", "--ports", "31337"],
            "before --bridges": ["--ports", "51091", *bridges],
            "with --egress": ["--egress", str(self.bridges), "--ports", "3128"],
        }
        for name, options in cases.items():
            with self.subTest(name):
                done = run(relay(self.bridges, *options, cmd=touch), self)
                self.assertEqual(done.returncode, 2, done.stderr)
                self.assertFalse(marker.exists())


if __name__ == "__main__":
    unittest.main()
