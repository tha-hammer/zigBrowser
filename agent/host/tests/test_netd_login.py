"""S6a part 3 (chat-drawer plan rev 16.18.1, RoseCat 5911): the sign-in's own netd.

The login launch gets its own backend capability and manifest,
runtime/net-login.json, which allows exactly api.anthropic.com and
platform.claude.com (the CLI's token exchange) and has `"ports": []`: setup-token
runs no hooks, so that netd makes no bridges/ directory and no bridge socket.
Chat's runtime/net.json is unchanged, so chat's netd still refuses
platform.claude.com. A manifest's ports stay 1 to 8 unless the list is empty;
a missing `ports` still means the built-in two (test_netd_manifest.py).

Every netd that tests reachability runs sealed (loopback only); nothing
reaches the network."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_netd import Netd  # noqa: E402
from test_netd_manifest import ManifestFile, dial, layout, manifest  # noqa: E402

LOGIN_ALLOW = ("api.anthropic.com", "platform.claude.com")


class LoginNetdTest(unittest.TestCase):
    def login(self, *extra, sealed=True):
        m = ManifestFile(self, manifest(allow=LOGIN_ALLOW, ports=()))
        return Netd(self, "--net-manifest", str(m.path),
                    "--test-resolve", "api.anthropic.com=1.0.0.1",
                    "--test-resolve", "platform.claude.com=1.1.1.1",
                    "--test-resolve", "claude.com=1.0.0.2", *extra, sealed=sealed)

    def test_empty_ports_means_no_bridges_at_all(self):
        d = self.login()
        self.assertTrue(d.ready(), d.err)
        self.assertEqual(layout(d), ["egress", "egress/proxy.sock"])

    def test_the_login_netd_reaches_platform_and_the_api_and_nothing_else(self):
        d = self.login()
        self.assertTrue(d.ready(), d.err)
        # Sealed: the dial fails; what matters is that it was attempted, at the vetted address.
        self.assertEqual(dial(d, "platform.claude.com"), (200, ["1.1.1.1 443"]))
        self.assertEqual(dial(d, "api.anthropic.com"), (200, ["1.1.1.1 443", "1.0.0.1 443"]))
        self.assertEqual(dial(d, "claude.com")[0], 403)
        self.assertEqual(dial(d, "platform.claude.com.evil.test")[0], 403)
        self.assertEqual(d.connects(), ["1.1.1.1 443", "1.0.0.1 443"])

    def test_chat_netd_still_refuses_platform(self):
        """The chat manifest, exactly as setup writes it today: api.anthropic.com only."""
        m = ManifestFile(self, manifest())
        d = Netd(self, "--net-manifest", str(m.path),
                 "--test-resolve", "platform.claude.com=1.1.1.1",
                 "--test-resolve", "api.anthropic.com=1.0.0.1", sealed=True)
        self.assertTrue(d.ready(), d.err)
        self.assertEqual(dial(d, "platform.claude.com"), (403, []))
        self.assertEqual(layout(d), ["bridges", "bridges/port-31337.sock", "bridges/port-51091.sock",
                                     "egress", "egress/proxy.sock"])

    def test_a_test_bridge_with_no_ports_exits_2(self):
        m = ManifestFile(self, manifest(allow=LOGIN_ALLOW, ports=()))
        d = Netd(self, "--net-manifest", str(m.path), "--test-bridge", "51091=40000", start=False).start()
        self.assertEqual(d.proc.wait(timeout=10), 2)
        self.assertFalse(d.dir.exists())

    def test_stopping_removes_the_directory(self):
        d = self.login()
        self.assertTrue(d.ready(), d.err)
        d.stop()
        self.assertFalse(d.dir.exists())

    def test_nine_ports_are_still_refused(self):
        m = ManifestFile(self, manifest(ports=tuple(range(40101, 40110))))
        d = Netd(self, "--net-manifest", str(m.path), start=False).start()
        self.assertEqual(d.proc.wait(timeout=10), 2)


if __name__ == "__main__":
    unittest.main()
