#!/usr/bin/env python3
"""RoseCat d3985c9 on e5d68fc: real_screen_check.py's fake-API cases (approval, tools,
long-run) launch the browser from an explicit allowlist, never the shell's environment.

Non-live: no display, no browser and no signal. A hostile shell is planted (the live socket,
a live profile and home, every kind of ZIGBROWSER_* and ZB_* seam, Claude/Anthropic
credentials, proxies, the ssh agent, rendering overrides) next to the three names the owner's screen must
give (DISPLAY, XAUTHORITY, DBUS_SESSION_BUS_ADDRESS). LongRunBrowser is built with the setup run
and the final Popen intercepted, and the recorded argv and environment are checked:
- none of the hostile names or values survives; the display, its Xauthority and the desktop
  bus do;
- the helper venv is found from the shell's HOME and XDG_CACHE_HOME only, never from an
  inherited ZB_AGENT_HOST_PYTHON or LD_PRELOAD;
- HOME, XDG_DATA_HOME and XDG_RUNTIME_DIR are the throwaway world's, and the profile is the
  throwaway --profile-dir; --media-source off and --e2e-protocol are passed;
- the only ZIGBROWSER_* names are the case's three seams: the egress allowlist is replaced by
  `--test-allow fake.zb.invalid=<the fake's port>` and the two bridges are the decoys, and the
  fake and the decoys listen on 127.0.0.1 only.

Run alone: python3 tests/manual/test_real_screen_env.py"""

from __future__ import annotations

import io
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "e2e"))

import real_screen_check as rsc  # noqa: E402

KEPT = {"DISPLAY": ":7", "XAUTHORITY": "/tmp/zb-owner-xauth", "DBUS_SESSION_BUS_ADDRESS": "unix:path=/run/user/1000/bus"}
HOSTILE = {
    "ZIGBROWSER_SOCKET": "/run/user/1000/zb-live.sock",
    "ZIGBROWSER_PROFILE_DIR": "/home/owner/zb-live-profile",
    "ZIGBROWSER_AGENT_HOST_CMD": "/tmp/zb-hostile-host",
    "ZIGBROWSER_AGENT_NET_TEST": "--test-allow api.anthropic.com=443",
    "ZIGBROWSER_AGENT_TEST_BASE_URL": "https://api.anthropic.com",
    "ZIGBROWSER_AGENT_DRAWER": "zb-hostile-off",
    "ZIGBROWSER_AGENT_TEST_TOOL_DEADLINE_S": "zb-hostile-deadline",
    "ZB_AGENT_HOST_PYTHON": "/tmp/zb-hostile-python",
    "ZB_AGENT_HOST_DIR": "/tmp/zb-hostile-host-dir",
    "ZB_LIVE_SOCKET": "/run/user/1000/zb-live.sock",
    "HOME": "/home/owner",
    "XDG_DATA_HOME": "/home/owner/.local/share",
    "XDG_CONFIG_HOME": "/home/owner/.config",
    "XDG_RUNTIME_DIR": "/run/user/1000-zb-hostile",
    "ANTHROPIC_API_KEY": "sk-ant-api-hostile",
    "ANTHROPIC_AUTH_TOKEN": "sk-ant-oat-hostile",
    "ANTHROPIC_BASE_URL": "https://hostile.example",
    "CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-oat01-hostile",
    "CLAUDE_CONFIG_DIR": "/home/owner/.claude",
    "HTTPS_PROXY": "http://proxy.hostile:3128",
    "https_proxy": "http://proxy.hostile:3128",
    "HTTP_PROXY": "http://proxy.hostile:3128",
    "ALL_PROXY": "socks5://proxy.hostile:1080",
    "NO_PROXY": "zb-hostile-no-proxy",
    "LD_PRELOAD": "/tmp/zb-hostile.so",
    "SSH_AUTH_SOCK": "/run/user/1000/zb-hostile-ssh-agent",
    "SSH_AGENT_PID": "zb-hostile-ssh-pid",
    "GDK_BACKEND": "zb-hostile-backend",
    "PATH": "/tmp/zb-hostile-bin:/usr/bin:/bin",
}


# The shell's own cache, used only to find the dev helper venv; it must not reach the browser.
CACHE = {"XDG_CACHE_HOME": os.environ.get("XDG_CACHE_HOME") or str(Path.home() / ".cache")}


class FakeProc:
    """The intercepted browser: already exited (poll 0), so close() sends no signal."""

    pid = None

    def __init__(self) -> None:
        self.stdout = io.StringIO("")

    def poll(self) -> int:
        return 0


class LaunchEnvTest(unittest.TestCase):
    def test_launch_env_keeps_only_the_allowlist_and_the_cases_own(self):
        world = {"PATH": "/w/bin:/usr/bin:/bin", "HOME": "/w/home", "XDG_DATA_HOME": "/w/data"}
        seams = {"ZIGBROWSER_AGENT_NET_TEST": "--test-allow fake.zb.invalid=1"}
        env = rsc.launch_env({**HOSTILE, **KEPT}, world, Path("/w/run"), seams)
        self.assertEqual(env, {**KEPT, **world, "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8", "XDG_RUNTIME_DIR": "/w/run",
                               **seams})


class InterceptedLaunchTest(unittest.TestCase):
    def setUp(self) -> None:
        self.work = Path(tempfile.mkdtemp(prefix="zb-real-screen-env-"))
        self.out = self.work / "out"
        self.out.mkdir()
        self.launches: list[tuple[list[str], dict[str, str]]] = []
        self.real_popen = rsc.subprocess.Popen

    def tearDown(self) -> None:
        shutil.rmtree(self.work, ignore_errors=True)

    def record(self, argv, *args, env=None, **kw):
        """Only the browser's launch is intercepted; the harness's own helpers (the venv
        check, the test certificate) run for real."""
        if argv and argv[0] == "/nonexistent/zigBrowser":
            self.launches.append((list(argv), dict(env or {})))
            return FakeProc()
        return self.real_popen(argv, *args, env=env, **kw)

    def test_the_browser_gets_none_of_the_hostile_shell(self):
        import agent_setup_test

        def setup(_binary, world):
            world.agent.mkdir(parents=True, exist_ok=True)
            return 0, "", "", [], []

        def no_signal(*_a, **_k):
            raise AssertionError("no signal may be sent in this test")

        with mock.patch.dict(os.environ, {**HOSTILE, **KEPT, **CACHE}, clear=True), \
                mock.patch.object(agent_setup_test, "run_setup", setup), \
                mock.patch.object(rsc.subprocess, "Popen", self.record), \
                mock.patch.object(rsc.os, "killpg", no_signal), mock.patch.object(rsc.os, "kill", no_signal):
            b = rsc.LongRunBrowser("/nonexistent/zigBrowser", self.work, self.out,
                                   respond=rsc.approval_turn("file:///nonexistent/approved.html"), label="approval")
            try:
                self.assertEqual(len(self.launches), 1)
                argv, env = self.launches[0]
                api_host = b.api._server.server_address[0]
                decoys = {port: d.sock.getsockname() for port, d in b.decoys.bridges.items()}
                api_port = b.api.port
            finally:
                b.close(self.out)

        # Nothing hostile survives, by name or by value; the screen's three names do.
        for name, value in HOSTILE.items():
            if name in env:
                self.assertNotEqual(env[name], value, name)
            for got in env.values():
                self.assertNotIn(value, got, f"{name}'s value reached the browser")
        for name, value in KEPT.items():
            self.assertEqual(env.get(name), value, name)
        self.assertNotIn("ZIGBROWSER_SOCKET", env)
        self.assertNotIn("XDG_CACHE_HOME", env)
        self.assertNotEqual(env.get("ZB_AGENT_HOST_PYTHON"), HOSTILE["ZB_AGENT_HOST_PYTHON"])
        self.assertEqual(sorted(n for n in env if n.startswith("ZIGBROWSER_")),
                         ["ZIGBROWSER_AGENT_NET_TEST", "ZIGBROWSER_AGENT_NET_TEST_CA", "ZIGBROWSER_AGENT_TEST_BASE_URL"])
        self.assertTrue(all(n in ("ZB_AGENT_HOST_PYTHON", "ZB_AGENT_HOST_DIR") for n in env if n.startswith("ZB_")))
        for name in env:
            self.assertFalse(name.upper().startswith(("ANTHROPIC", "CLAUDE")) or "PROXY" in name.upper(), name)
            self.assertNotIn(name, rsc.RENDER_ENV)
        # Throwaway places only.
        for name in ("HOME", "XDG_DATA_HOME", "XDG_RUNTIME_DIR"):
            self.assertTrue(env[name].startswith(str(self.work)), (name, env[name]))
        profile = argv[argv.index("--profile-dir") + 1]
        self.assertTrue(profile.startswith(str(self.work)), profile)
        self.assertNotIn("zb-live-profile", " ".join(argv))
        for flag in (["--media-source", "off"], ["--e2e-protocol"], ["--agent-drawer", "on"]):
            self.assertIn(flag[0], argv)
            if len(flag) == 2:
                self.assertEqual(argv[argv.index(flag[0]) + 1], flag[1])
        # The egress allowlist is replaced by the loopback fake; both bridges are decoys.
        self.assertEqual(env["ZIGBROWSER_AGENT_NET_TEST"],
                         f"--test-allow fake.zb.invalid={api_port} --test-bridge 51091={decoys[51091][1]} "
                         f"--test-bridge 31337={decoys[31337][1]}")
        self.assertEqual(env["ZIGBROWSER_AGENT_TEST_BASE_URL"], "https://fake.zb.invalid")
        self.assertEqual(api_host, "127.0.0.1")
        self.assertTrue(all(host == "127.0.0.1" for host, _port in decoys.values()), decoys)


if __name__ == "__main__":
    unittest.main()
