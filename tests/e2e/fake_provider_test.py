"""The S6b2 fake provider works as the auth window will use it (no browser, no display): through
its recording proxy, CONNECT then TLS trusting only the provider's certificate, as WebKit will
with ZIGBROWSER_AGENT_AUTH_TEST's `proxy=` and `ca=`. Run alone: python3 tests/e2e/fake_provider_test.py"""

import re
import socket
import ssl
import sys
import tempfile
import unittest
from pathlib import Path
from urllib.parse import parse_qsl, urlsplit

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import fake_provider as fp  # noqa: E402

AUTHORIZE = ("/cai/oauth/authorize?code=true&client_id=00000000-0000-4000-8000-00000000fa6e&response_type=code"
             "&redirect_uri=https://platform.claude.com/oauth/code/callback&scope=user:inference"
             "&code_challenge=Zb3_challenge-0123456789abcdefghijklmnopqrs&code_challenge_method=S256&state=zbState-0123")


def via_proxy(provider, host, path, port=443):
    """GET https://host:port/path through the provider's proxy: (status, body, set-cookie)."""
    proxy_port = int(re.search(r"proxy=http://127\.0\.0\.1:(\d+),", provider.seam_value()).group(1))
    raw = socket.create_connection(("127.0.0.1", proxy_port), timeout=10)
    raw.sendall(f"CONNECT {host}:{port} HTTP/1.1\r\nHost: {host}:{port}\r\n\r\n".encode())
    head = b""
    while b"\r\n\r\n" not in head:
        chunk = raw.recv(4096)
        if not chunk:
            break
        head += chunk
    status = int(head.split()[1])
    if status != 200:
        raw.close()
        return status, b"", None
    ctx = ssl.create_default_context(cafile=str(provider.cert))
    tls = ctx.wrap_socket(raw, server_hostname=host)
    tls.sendall(f"GET {path} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n".encode())
    data = b""
    while True:
        chunk = tls.recv(65536)
        if not chunk:
            break
        data += chunk
    tls.close()
    header, _, body = data.partition(b"\r\n\r\n")
    cookie = next((l.split(b":", 1)[1].strip() for l in header.split(b"\r\n") if l.lower().startswith(b"set-cookie:")), None)
    return int(header.split()[1]), body, cookie


class FakeProviderTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="zb-provider-"))

    def tearDown(self):
        for p in sorted(self.tmp.rglob("*"), reverse=True):
            p.unlink() if p.is_file() else p.rmdir()
        self.tmp.rmdir()

    def test_the_seam_value_has_the_accepted_shape(self):
        with fp.FakeProvider(self.tmp) as p:
            self.assertRegex(p.seam_value(), r"^proxy=http://127\.0\.0\.1:[1-9][0-9]{0,4},ca=/\S+$")
            self.assertTrue(p.cert.is_file() and p.cert.stat().st_size <= 65536)

    def test_the_sign_in_page_through_the_proxy(self):
        with fp.FakeProvider(self.tmp) as p:
            status, body, cookie = via_proxy(p, "claude.com", AUTHORIZE)
            self.assertEqual(status, 200)
            self.assertEqual(cookie, b"zbprovider=1; Secure; Path=/")
            for needle in (b'id="cookies"', b'id="popup"', b'id="authorize"'):
                self.assertIn(needle, body)
            link = re.search(rb'id="authorize" href="([^"]+)"', body).group(1).decode().replace("&amp;", "&")
            self.assertEqual(link, f"https://platform.claude.com/oauth/code/callback?code={fp.CODE}&state=zbState-0123")
            self.assertEqual(p.connects, ["claude.com:443"])
            self.assertEqual(p.requests[0]["path"], "/cai/oauth/authorize")

    def test_each_variant_builds_its_callback(self):
        want = {
            "ok": "https://platform.claude.com/oauth/code/callback?code={c}&state=zbState-0123",
            "wrong-state": "https://platform.claude.com/oauth/code/callback?code={c}&state=another-sign-in",
            "missing-state": "https://platform.claude.com/oauth/code/callback?code={c}",
            "other-port": "https://platform.claude.com:8443/oauth/code/callback?code={c}&state=zbState-0123",
            "http": "http://platform.claude.com/oauth/code/callback?code={c}&state=zbState-0123",
            "lookalike": "https://platform.claude.com.evil.example/oauth/code/callback?code={c}&state=zbState-0123",
            "no-code": "https://platform.claude.com/oauth/code/callback?state=zbState-0123",
        }
        self.assertEqual(sorted(want), sorted(fp.VARIANTS))
        for variant, url in want.items():
            with fp.FakeProvider(self.tmp / variant, variant=variant) as p:
                _, body, _ = via_proxy(p, "claude.com", AUTHORIZE)
                link = re.search(rb'id="authorize" href="([^"]+)"', body).group(1).decode().replace("&amp;", "&")
                self.assertEqual(link, url.format(c=fp.CODE), variant)

    def test_a_code_page_request_is_recorded(self):
        with fp.FakeProvider(self.tmp) as p:
            status, body, _ = via_proxy(p, "platform.claude.com", "/oauth/code/callback?code=x&state=y")
            self.assertEqual((status, b"the code page" in body), (200, True))
            self.assertEqual(p.callback_loads, ["/oauth/code/callback?code=x&state=y"])

    def test_every_other_target_is_refused_and_recorded(self):
        with fp.FakeProvider(self.tmp) as p:
            for host, port in (("accounts.google.com", 443), ("platform.claude.com", 8443), ("evil.example", 443),
                               ("platform.claude.com.evil.example", 443)):
                status, _, _ = via_proxy(p, host, "/", port)
                self.assertEqual(status, 403, host)
            self.assertEqual(p.refused, ["accounts.google.com:443", "platform.claude.com:8443", "evil.example:443",
                                         "platform.claude.com.evil.example:443"])
            # plain HTTP through the proxy
            proxy_port = int(re.search(r":(\d+),", p.seam_value()).group(1))
            s = socket.create_connection(("127.0.0.1", proxy_port), timeout=10)
            s.sendall(b"GET http://platform.claude.com/oauth/code/callback?code=x HTTP/1.1\r\nHost: platform.claude.com\r\n\r\n")
            self.assertIn(b" 403 ", s.recv(64))
            s.close()
            self.assertIn("http://platform.claude.com/oauth/code/callback?code=x", p.refused)

    def test_the_certificate_is_only_for_the_two_hosts(self):
        with fp.FakeProvider(self.tmp) as p:
            ctx = ssl.create_default_context(cafile=str(p.cert))
            raw = socket.create_connection(("127.0.0.1", p.https_port), timeout=10)
            with self.assertRaises(ssl.SSLCertVerificationError):
                ctx.wrap_socket(raw, server_hostname="claude.ai").close()


if __name__ == "__main__":
    unittest.main()
