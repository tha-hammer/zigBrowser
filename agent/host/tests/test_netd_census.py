"""S6b1 (chat-drawer plan rev 16.18.4, RoseCat 5994): netd's `--census`.

With `--census` (the app passes it only to the login netd, and only under
--e2e-protocol), netd writes one stderr line per distinct CONNECT target, decided by
its allowlist:

    zigBrowser: agent: netd census <host>:<port> allowed
    zigBrowser: agent: netd census <host>:<port> refused

The host and port only: never a byte of the tunnel, and a malformed request gives
`?:?`. Without `--census` there is no such line. The census rides to the sandboxed
side with the other options. Every netd here runs sealed (loopback only)."""

import sys
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_netd import Netd  # noqa: E402
from test_netd_manifest import ManifestFile, dial, manifest  # noqa: E402

LOGIN_ALLOW = ("api.anthropic.com", "platform.claude.com")


def census(d):
    time.sleep(0.3)
    return [line.split("netd census ", 1)[1] for line in d.err if "netd census " in line]


class CensusTest(unittest.TestCase):
    def netd(self, *extra):
        m = ManifestFile(self, manifest(allow=LOGIN_ALLOW, ports=()))
        d = Netd(self, "--net-manifest", str(m.path), "--test-resolve", "platform.claude.com=1.1.1.1",
                 *extra, sealed=True)
        self.assertTrue(d.ready(), d.err)
        return d

    def test_each_distinct_target_once_allowed_or_refused(self):
        d = self.netd("--census")
        dial(d, "platform.claude.com")
        dial(d, "platform.claude.com")
        dial(d, "claude.com")
        dial(d, "claude.com")
        dial(d, "evil.example")
        self.assertEqual(census(d), ["platform.claude.com:443 allowed", "claude.com:443 refused",
                                     "evil.example:443 refused"])

    def test_a_malformed_request_names_nothing(self):
        d = self.netd("--census")
        s = d.proxy()
        s.sendall(b"GET http://zbqxcensus.example/ HTTP/1.1\r\n\r\n")
        s.recv(256)
        s.close()
        lines = census(d)
        self.assertTrue(all("zbqxcensus" not in line for line in lines), lines)
        self.assertTrue(all(line.endswith(" refused") for line in lines), lines)

    def test_no_census_without_the_option(self):
        d = self.netd()
        dial(d, "platform.claude.com")
        dial(d, "claude.com")
        self.assertEqual(census(d), [])


if __name__ == "__main__":
    unittest.main()
