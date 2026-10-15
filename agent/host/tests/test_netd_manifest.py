"""MS0 slice D (RoseCat 5750/5752; JadeBeacon 5753/5762, BlueBeaver 5755): netd
takes its egress allow-list and its bridge ports from the backend's manifest.

    python3 -m zb_agent_host.netd --sockdir DIR --bwrap BWRAP [--net-manifest PATH] ...

PATH is the agent home's runtime/net.json, which setup writes from the
backend's LaunchSpec network field:

    {"bridges_dir": "...", "ports": [51091, 31337],
     "egress": {"endpoint": "127.0.0.1:3128", "allow": ["api.anthropic.com"]}}

netd's outer stage reads it before bwrap (the sandboxed side never sees the
agent home). The file must be a regular file of ours, not group- or
world-writable, at most 64 KiB, opened without following a link and without
blocking. `egress.allow` is 1 to 8 distinct DNS names (netd's own
valid_dns_name: lowercase, no IP literal, no wildcard); `ports` is 1 to 8
distinct integers 1-65535. The allow-list replaces the built-in
api.anthropic.com; the ports replace 51091 and 31337, so netd serves
bridges/port-<P>.sock for exactly those. Anything else exits 2 before netd is
ready, and the error names no manifest content. A missing file, or a
manifest with neither `egress` nor `ports` (a home set up before they
existed: bridges_dir only), means the built-in values; so does no
--net-manifest at all, byte-identical to today (test_netd.py pins that).
One of the two keys without the other is refused.

Every netd that tests reachability runs sealed (loopback only); nothing
reaches the network."""

import json
import os
import socket
import stat
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_netd import Listener, Netd, response_head, short_root, status_of  # noqa: E402

CANARY = "zbqxmanifest"  # in every refused manifest: never in netd's output


def manifest(allow=("api.anthropic.com",), ports=(51091, 31337), **override):
    doc = {"bridges_dir": "/run/zb-bridges", "ports": list(ports),
           "egress": {"endpoint": "127.0.0.1:3128", "allow": list(allow)}}
    doc.update(override)
    return doc


class ManifestFile:
    def __init__(self, tc, doc=None, data=None, mode=0o600):
        self.root = short_root(tc)
        self.path = self.root / "net.json"
        if doc is not None or data is not None:
            self.path.write_bytes(data if data is not None else json.dumps(doc).encode())
            os.chmod(self.path, mode)


def layout(d):
    return sorted(str(p.relative_to(d.dir)) for p in d.dir.rglob("*"))


class ManifestTest(unittest.TestCase):
    def test_the_manifest_ports_are_exactly_the_bridges_netd_serves(self):
        m = ManifestFile(self, manifest(ports=(40101, 40102)))
        d = Netd(self, "--net-manifest", str(m.path))
        self.assertTrue(d.ready(), d.err)
        self.assertEqual(layout(d), ["bridges", "bridges/port-40101.sock", "bridges/port-40102.sock",
                                     "egress", "egress/proxy.sock"])
        for sock in ("bridges/port-40101.sock", "bridges/port-40102.sock"):
            st = (d.dir / sock).lstat()
            self.assertTrue(stat.S_ISSOCK(st.st_mode), sock)
            self.assertEqual(stat.S_IMODE(st.st_mode), 0o600, sock)

    def test_a_manifest_bridge_carries_bytes_to_its_host_port(self):
        target = Listener(self, reply=b"done-40101")
        m = ManifestFile(self, manifest(ports=(40101,)))
        d = Netd(self, "--net-manifest", str(m.path), "--test-bridge", f"40101={target.port}")
        self.assertTrue(d.ready(), d.err)
        s = d.unix("bridges", "port-40101.sock")
        s.sendall(b"payload")
        s.shutdown(socket.SHUT_WR)
        got = b""
        while chunk := s.recv(4096):
            got += chunk
        self.assertEqual(got, b"done-40101")
        self.assertEqual(bytes(target.accepted[-1]), b"payload")

    def test_a_test_bridge_must_name_a_manifest_port(self):
        m = ManifestFile(self, manifest(ports=(40101,)))
        d = Netd(self, "--net-manifest", str(m.path), "--test-bridge", "51091=40000", start=False).start()
        self.assertEqual(d.proc.wait(timeout=10), 2)
        self.assertFalse(d.dir.exists())

    def test_the_manifest_allow_list_replaces_api_anthropic_com(self):
        """A name the manifest allows is dialed at its vetted address; api.anthropic.com,
        which it does not list, is refused before any attempt."""
        m = ManifestFile(self, manifest(allow=("api.example-backend.com",)))
        d = Netd(self, "--net-manifest", str(m.path),
                 "--test-resolve", "api.example-backend.com=1.1.1.1",
                 "--test-resolve", "api.anthropic.com=1.0.0.1", sealed=True)
        self.assertTrue(d.ready(), d.err)
        s = d.proxy()
        s.sendall(b"CONNECT api.anthropic.com:443 HTTP/1.1\r\n\r\n")
        self.assertEqual(status_of(response_head(s)), 403)
        self.assertEqual(d.connects(), [], "the built-in host is gone from the allow-list")
        s = d.proxy()
        s.sendall(b"CONNECT api.example-backend.com:443 HTTP/1.1\r\n\r\n")
        response_head(s)  # sealed: the dial fails; what matters is that it was attempted
        self.assertEqual(d.connects(), ["1.1.1.1 443"])

    def test_a_missing_manifest_or_one_without_network_keys_means_the_built_in_values(self):
        for name, m in (("missing", ManifestFile(self)),  # the path names nothing
                        ("bridges_dir only", ManifestFile(self, {"bridges_dir": "/run/zb-bridges"}))):
            with self.subTest(name):
                d = Netd(self, "--net-manifest", str(m.path), "--test-resolve", "api.anthropic.com=1.1.1.1",
                         sealed=True)
                self.assertTrue(d.ready(), d.err)
                self.assertEqual(layout(d), ["bridges", "bridges/port-31337.sock", "bridges/port-51091.sock",
                                             "egress", "egress/proxy.sock"])
                s = d.proxy()
                s.sendall(b"CONNECT api.anthropic.com:443 HTTP/1.1\r\n\r\n")
                response_head(s)
                self.assertEqual(d.connects(), ["1.1.1.1 443"])
                d.stop()

    def test_a_bad_manifest_exits_2_before_ready_and_names_none_of_its_content(self):
        many = [f"h{i}.{CANARY}.com" for i in range(9)]
        bad_docs = {
            "egress missing": {"ports": [51091], "note": CANARY},
            "egress not an object": manifest(egress=[CANARY]),
            "allow missing": manifest(egress={"endpoint": CANARY}),
            "allow empty": manifest(allow=()),
            "allow nine": manifest(allow=many),
            "allow duplicate": manifest(allow=(f"{CANARY}.com", f"{CANARY}.com")),
            "allow an IP literal": manifest(allow=("192.0.2.7",), note=CANARY),
            "allow uppercase": manifest(allow=(f"API.{CANARY}.COM",)),
            "allow a wildcard": manifest(allow=(f"*.{CANARY}.com",)),
            "allow a trailing dot": manifest(allow=(f"{CANARY}.com.",)),
            "allow a port": manifest(allow=(f"{CANARY}.com:443",)),
            "allow not a string": manifest(allow=(7,), note=CANARY),
            "allow not a list": manifest(egress={"allow": f"{CANARY}.com"}),
            "ports missing": {"egress": {"allow": ["api.anthropic.com"]}, "note": CANARY},
            "ports empty": manifest(ports=(), note=CANARY),
            "ports nine": manifest(ports=range(40141, 40150), note=CANARY),
            "ports duplicate": manifest(ports=(51091, 51091), note=CANARY),
            "port zero": manifest(ports=(0,), note=CANARY),
            "port 65536": manifest(ports=(65536,), note=CANARY),
            "port true": manifest(ports=(True,), note=CANARY),
            "port a string": manifest(ports=(CANARY,)),
            "port a float": manifest(ports=(51091.0,), note=CANARY),
            "not an object": [CANARY],
        }
        bad_data = {
            "not JSON": f"{{{CANARY}".encode(),
            "over 64 KiB": json.dumps(manifest(note=CANARY + "x" * 65536)).encode(),
            "not UTF-8": b'{"note": "\xff\xfe' + CANARY.encode() + b'"}',
            "deeply nested": b"[" * 60000 + CANARY.encode(),
        }
        for name, doc in bad_docs.items():
            with self.subTest(name):
                self._refused(ManifestFile(self, doc))
        for name, data in bad_data.items():
            with self.subTest(name):
                self._refused(ManifestFile(self, data=data))
        for mode in (0o620, 0o602, 0o660, 0o666):
            with self.subTest(oct(mode)):
                self._refused(ManifestFile(self, manifest(note=CANARY), mode=mode))

    def test_a_link_a_directory_or_a_fifo_in_place_of_the_manifest_exits_2_without_blocking(self):
        real = ManifestFile(self, manifest())
        link = ManifestFile(self)
        link.path.symlink_to(real.path)
        self._refused(link)
        directory = ManifestFile(self)
        directory.path.mkdir()
        self._refused(directory)
        fifo = ManifestFile(self)
        os.mkfifo(fifo.path, 0o600)
        self._refused(fifo)  # a FIFO opened for reading would block until a writer comes

    def _refused(self, m):
        d = Netd(self, "--net-manifest", str(m.path), start=False).start()
        self.assertEqual(d.proc.wait(timeout=10), 2, d.err)
        self.assertFalse(d.ready(timeout=1))
        self.assertFalse(d.dir.exists(), "no socket directory before the manifest is read")
        d.kill()
        self.assertTrue(d.err, "one fixed error line")
        self.assertNotIn(CANARY, "\n".join(d.err))

    def test_net_manifest_needs_a_value(self):
        d = Netd(self, "--net-manifest", start=False).start()
        self.assertEqual(d.proc.wait(timeout=10), 2)


if __name__ == "__main__":
    unittest.main()
