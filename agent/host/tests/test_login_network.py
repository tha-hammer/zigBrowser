"""S6a part 3 (chat-drawer plan rev 16.18.1, RoseCat 5911): the sign-in's network is
its own backend capability, so chat's network never widens.

- `sandbox.login_network()`: the same egress endpoint and dir as chat, the
  allowlist ("api.anthropic.com", "platform.claude.com") (the CLI's token
  exchange), and no bridge ports (setup-token runs no hooks).
- `login_launch_spec()` carries it, and binds only the login netd's egress/.
- `setup.login_net_manifest()` serializes it (net.json's schema, `"ports": []`);
  a real `setup.provision()` publishes it as runtime/net-login.json (0600) beside
  an unchanged runtime/net.json (RoseCat 5925); and the real netd serves that file: platform.claude.com is dialed, other names
  are refused, no bridges/ exists.
- `network()`, `launch_spec()`, `EGRESS_ALLOW` and `setup.net_manifest()` are
  exactly what they were (test_backend_contract.py pins them too)."""

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

HOST_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HOST_DIR))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from zb_agent_host import options, sandbox, setup  # noqa: E402
from test_netd import Netd  # noqa: E402
from test_netd_manifest import ManifestFile, dial, layout  # noqa: E402
from test_provision import Sandbox  # noqa: E402 - the fixture SAI source and a target agent home

LOGIN_ALLOW = ("api.anthropic.com", "platform.claude.com")


def has_login():
    return hasattr(sandbox, "login_network") and hasattr(setup, "login_net_manifest")


class LoginNetworkCapability(unittest.TestCase):
    def setUp(self):
        if not has_login():
            self.fail("no sandbox.login_network / setup.login_net_manifest")
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        root = Path(self._tmp.name)
        self.home = options.AgentHome(root)
        for d in (".claude", "workspace", "scratchpad", "runtime"):
            (root / d).mkdir(parents=True, exist_ok=True)
        for base in (root / "state", root / ".claude"):
            base.mkdir(parents=True, exist_ok=True)
            for name in ("backups", *sandbox.STATE_DIRS):
                (base / name).mkdir(mode=0o700, exist_ok=True)
            (base / ".claude.json").write_text("{}\n")
        self.chat_net = root / "zb-net"
        for sub in ("egress", "bridges"):
            (self.chat_net / sub).mkdir(parents=True)
        self.login_net = root / "zb-net-login"
        (self.login_net / "egress").mkdir(parents=True)

    def test_the_login_network_allows_platform_and_has_no_bridges(self):
        net = sandbox.login_network()
        self.assertIsInstance(net, sandbox.Network)
        self.assertEqual(net.egress.allow, LOGIN_ALLOW)
        self.assertEqual(net.bridges.ports, ())
        self.assertFalse(net.bridges.hooks_get_egress)
        chat = sandbox.network()
        self.assertEqual((net.egress.endpoint, net.egress.dir), (chat.egress.endpoint, chat.egress.dir))

    def test_chat_is_unchanged(self):
        self.assertEqual(sandbox.EGRESS_ALLOW, ("api.anthropic.com",))
        self.assertEqual(sandbox.network().egress.allow, ("api.anthropic.com",))
        self.assertEqual(sandbox.network().bridges.ports, (51091, 31337))
        spec = sandbox._LINUX_BACKEND.launch_spec(self.home, net_dir=str(self.chat_net))
        self.assertEqual(spec.network, sandbox.network())
        self.assertEqual(setup.net_manifest()["egress"]["allow"], ["api.anthropic.com"])
        self.assertEqual(setup.net_manifest()["ports"], [51091, 31337])

    def test_the_login_launch_spec_carries_it_and_binds_egress_only(self):
        spec = sandbox._LINUX_BACKEND.login_launch_spec(self.home, net_dir=str(self.login_net))
        self.assertEqual(spec.network, sandbox.login_network())
        targets = [m.target for m in spec.mounts]
        self.assertIn("/run/zb-net/egress", targets)
        self.assertNotIn("/run/zb-net/bridges", targets)
        self.assertIn("net", spec.unshare)
        egress = [m for m in spec.mounts if m.target == "/run/zb-net/egress"]
        self.assertEqual([(m.source, m.writable) for m in egress], [(str(self.login_net / "egress"), False)])

    def test_the_login_launch_refuses_a_missing_egress(self):
        os.rmdir(self.login_net / "egress")
        with self.assertRaises(sandbox.SandboxError):
            sandbox._LINUX_BACKEND.login_launch_spec(self.home, net_dir=str(self.login_net))

    def test_the_manifest_is_the_capability_in_net_json_schema(self):
        self.assertEqual(setup.login_net_manifest(),
                         {"ports": [], "egress": {"endpoint": "127.0.0.1:3128", "allow": list(LOGIN_ALLOW)}})

    def test_a_changed_login_network_reaches_the_manifest_and_the_spec(self):
        changed = sandbox.Network(
            egress=sandbox.Egress(sandbox.Endpoint("127.0.0.1", 4999), ("example.test",), "/run/zb-net/egress"),
            bridges=sandbox.BridgePolicy(ports=(), hooks_get_egress=False))
        orig = sandbox._LINUX_BACKEND.login_network
        sandbox._LINUX_BACKEND.login_network = lambda: changed
        try:
            self.assertEqual(setup.login_net_manifest()["egress"], {"endpoint": "127.0.0.1:4999", "allow": ["example.test"]})
            spec = sandbox._LINUX_BACKEND.login_launch_spec(self.home, net_dir=str(self.login_net))
            self.assertEqual(spec.network, changed)
            self.assertEqual(sandbox.network().egress.allow, ("api.anthropic.com",))
        finally:
            sandbox._LINUX_BACKEND.login_network = orig

    def test_setup_publishes_net_login_json_beside_net_json(self):
        box = Sandbox(self)
        box.provision(select_token_route=False)
        runtime = box.home.runtime
        login = runtime / "net-login.json"
        self.assertTrue(login.is_file() and not login.is_symlink(), "setup published no runtime/net-login.json")
        self.assertEqual(login.stat().st_mode & 0o777, 0o600)
        self.assertEqual(json.loads(login.read_text()), setup.login_net_manifest())
        self.assertEqual(json.loads((runtime / "net.json").read_text()), setup.net_manifest())
        self.assertEqual(json.loads((runtime / "net.json").read_text())["egress"]["allow"], ["api.anthropic.com"])

    def test_netd_serves_the_produced_manifest(self):
        m = ManifestFile(self)
        m.path.write_text(json.dumps(setup.login_net_manifest()))
        os.chmod(m.path, 0o600)
        d = Netd(self, "--net-manifest", str(m.path), "--test-resolve", "platform.claude.com=1.1.1.1",
                 "--test-resolve", "claude.com=1.0.0.2", sealed=True)
        self.assertTrue(d.ready(), d.err)
        self.assertEqual(layout(d), ["egress", "egress/proxy.sock"])
        self.assertEqual(dial(d, "platform.claude.com"), (200, ["1.1.1.1 443"]))
        self.assertEqual(dial(d, "claude.com")[0], 403)


if __name__ == "__main__":
    unittest.main()
