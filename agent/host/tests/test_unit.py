"""Helper unit tests (gate step agent-host-unit): no CLI, no network."""

import os
import stat
import tempfile
import unittest
from pathlib import Path

import http.client
import json

import support  # noqa: F401  (puts the helper package on sys.path)
from support import FakeAnthropicApi
from zb_agent_host import hook_run, options, provision, sandbox, token


class OptionsBuilder(unittest.TestCase):
    def setUp(self):
        self.home = options.AgentHome(Path(tempfile.mkdtemp(prefix="zb-unit-")))

    def build(self, **kw):
        return options.build(self.home, route_env={"CLAUDE_CODE_OAUTH_TOKEN": "x" * 20}, **kw)

    def test_always_passes_user_setting_sources_only(self):
        self.assertEqual(self.build().setting_sources, ["user"])

    def test_cwd_is_the_workspace_and_no_builtin_tools(self):
        opts = self.build()
        self.assertEqual(Path(opts.cwd), self.home.workspace)
        self.assertEqual(opts.tools, [])

    def test_cli_env_points_home_and_config_into_the_agent_home(self):
        env = self.build().env
        self.assertEqual(env["HOME"], str(self.home.root))
        self.assertEqual(env["CLAUDE_CONFIG_DIR"], str(self.home.root / ".claude"))
        self.assertEqual(env["TMPDIR"], str(self.home.scratchpad / "tmp"))
        self.assertEqual(env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"], "1")

    def test_helper_environ_is_the_allowlist_only(self):
        inherited = {"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "HOME": "/home/someone",
                     "CLAUDECODE": "1", "CLAUDE_CODE_SESSION_ID": "s", "MCP_AGENT_MAIL_TOKEN": "t",
                     "ANTHROPIC_API_KEY": "k", "DISPLAY": ":0", "XDG_RUNTIME_DIR": "/run/user/1000"}
        env = options.helper_environ(self.home, inherited)
        self.assertEqual(env["HOME"], str(self.home.root))
        self.assertEqual(env["PATH"], "/usr/bin:/bin")
        for name in ("CLAUDECODE", "CLAUDE_CODE_SESSION_ID", "MCP_AGENT_MAIL_TOKEN", "ANTHROPIC_API_KEY",
                     "DISPLAY", "XDG_RUNTIME_DIR"):
            self.assertNotIn(name, env)
        self.assertTrue(set(env) <= set(options.HELPER_ENV_NAMES))

    def test_strict_mcp_config_is_always_passed(self):
        self.assertIn("strict-mcp-config", self.build().extra_args)

    def test_route_env_may_not_override_the_fixed_cli_env(self):
        with self.assertRaises(ValueError):
            options.build(self.home, route_env={"HOME": "/elsewhere"})


class TokenShape(unittest.TestCase):
    def read(self, data):
        r, w = os.pipe()
        os.write(w, data)
        os.close(w)
        return token.read_token(r)

    def test_accepts_one_printable_line(self):
        self.assertEqual(self.read(b"sk-ant-oat01-" + b"a" * 20 + b"\n"), "sk-ant-oat01-" + "a" * 20)

    def test_refuses_short_long_spaced_and_unprintable(self):
        for bad in (b"short", b"a" * 513, b"abc def ghi jkl mno", b"a" * 20 + b"\x01", b""):
            with self.assertRaises(ValueError):
                self.read(bad)


class FifoHandoff(unittest.TestCase):
    def test_an_unopened_fifo_is_dropped_and_its_writer_released(self):
        d = Path(tempfile.mkdtemp(prefix="zb-unit-")) / "fifo"
        handoff = token.FifoHandoff(d, "t" * 20)
        self.assertEqual(stat.S_IMODE(os.stat(d).st_mode), 0o300)
        self.assertTrue(stat.S_ISFIFO(os.stat(handoff.path).st_mode))
        handoff.close()
        self.assertFalse(os.path.exists(handoff.path))
        self.assertFalse(handoff._thread.is_alive())


class WrapperScript(unittest.TestCase):
    def test_wrapper_is_owner_only_and_names_the_cli(self):
        d = Path(tempfile.mkdtemp(prefix="zb-unit-"))
        path = d / "zb-claude"
        token.write_wrapper(path, "/opt/claude/cli")
        mode = stat.S_IMODE(path.stat().st_mode)
        self.assertEqual(mode, 0o700)
        self.assertIn("/opt/claude/cli", path.read_text())


class FakeApiBoundary(unittest.TestCase):
    """The fake's own contract: it records everything and lets nothing through as a proxy."""

    def request(self, api, method, target, body=None, headers=None):
        host, port = api.base_url.removeprefix("http://").split(":")
        conn = http.client.HTTPConnection(host, int(port), timeout=10)
        conn.request(method, target, body=body, headers=headers or {})
        resp = conn.getresponse()
        data = resp.read()
        conn.close()
        return resp.status, data

    def test_connect_tunnels_and_foreign_requests_are_recorded_and_refused(self):
        with FakeAnthropicApi() as api:
            status, _ = self.request(api, "CONNECT", "api.anthropic.com:443")
            self.assertEqual(status, 403)
            status, _ = self.request(api, "GET", "http://statsig.anthropic.com/v1/x")
            self.assertEqual(status, 403)
        self.assertEqual(api.tunnels, ["api.anthropic.com:443", "http://statsig.anthropic.com/v1/x"])

    def test_messages_stream_the_scripted_turn_and_other_paths_404(self):
        with FakeAnthropicApi([{"text": "Scripted."}]) as api:
            status, data = self.request(api, "POST", "/v1/messages?beta=true",
                                        json.dumps({"stream": True, "messages": []}),
                                        {"authorization": "Bearer t", "content-type": "application/json"})
            self.assertEqual(status, 200)
            self.assertIn(b'"text_delta", "text": "Scripted."', data)
            self.assertIn(b"event: message_stop", data)
            status, _ = self.request(api, "GET", "/api/oauth/profile")
            self.assertEqual(status, 404)
        self.assertEqual(api.messages_requests()[0]["headers"]["authorization"], "Bearer t")
        self.assertEqual(api.other_paths(), ["GET /api/oauth/profile"])


class HookIsolation(unittest.TestCase):
    def test_hook_env_allowlist_holds_no_refused_name(self):
        self.assertEqual(hook_run.refused_names(provision.HOOK_ENV_NAMES), [])

    def test_provisioning_refuses_a_token_name_in_the_allowlist(self):
        home = options.AgentHome(Path(tempfile.mkdtemp(prefix="zb-unit-")))
        with self.assertRaises(provision.ProvisionError):
            provision.provision_runtime(home, hook_env_names=("PATH", "CLAUDE_CODE_OAUTH_TOKEN"))

    def test_every_hook_is_wrapped_once(self):
        settings = {"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "bun x.ts"}]}]}}
        provision.wrap_hooks(settings, "/h/zb-hook-run -- ")
        provision.wrap_hooks(settings, "/h/zb-hook-run -- ")
        self.assertEqual(settings["hooks"]["Stop"][0]["hooks"][0]["command"], "/h/zb-hook-run -- bun x.ts")

    def test_hook_argv_isolates_pid_proc_and_tmp_and_keeps_workspace_read_only(self):
        argv = hook_run.bwrap_argv("/a", {"PATH": "/usr/bin"}, ["/a/.claude/hooks/x.sh"])
        self.assertEqual(argv[:2], [hook_run.BWRAP, "--clearenv"])
        for flag in ("--unshare-pid", "--unshare-ipc", "--die-with-parent", "--new-session"):
            self.assertIn(flag, argv)
        joined = " ".join(argv)
        self.assertIn("--ro-bind /a/workspace /a/workspace", joined)
        # /proc and /dev come after the root bind, or the host's would cover them.
        self.assertLess(argv.index("/"), argv.index("--proc"))
        self.assertLess(argv.index("/"), argv.index("--dev"))
        self.assertEqual(argv[-2:], ["--", "/a/.claude/hooks/x.sh"])

    def test_agent_home_is_mounted_back_after_the_private_tmp_run_and_shm(self):
        # An agent home under /tmp (or /run) would otherwise vanish under the hook's tmpfs.
        argv = hook_run.bwrap_argv("/tmp/x/home", {}, ["/tmp/x/home/.claude/hooks/x.sh"])
        pairs = [(argv[i], argv[i + 1]) for i in range(len(argv) - 1)]
        home = pairs.index(("--bind", "/tmp/x/home"))
        for mount in (("--tmpfs", "/tmp"), ("--tmpfs", "/run"), ("--tmpfs", "/dev/shm")):
            self.assertLess(pairs.index(mount), home)
        self.assertLess(home, pairs.index(("--ro-bind", "/tmp/x/home/workspace")))


class SandboxArgv(unittest.TestCase):
    def setUp(self):
        self.home = options.AgentHome(Path(tempfile.mkdtemp(prefix="zb-unit-")))
        for d in (".claude", "workspace", "scratchpad", "runtime"):
            (self.home.root / d).mkdir()
        self.argv = sandbox.helper_argv(self.home)
        self.joined = " ".join(self.argv)

    def test_claude_is_read_only_with_only_state_dirs_writable(self):
        claude = str(self.home.claude_dir)
        self.assertIn(f"--ro-bind {claude} {claude}", self.joined)
        writable = [self.argv[i + 1] for i, a in enumerate(self.argv) if a == "--bind"]
        self.assertEqual(sorted(writable), sorted([f"{claude}/{d}" for d in sandbox.STATE_DIRS] + [str(self.home.scratchpad)]))

    def test_workspace_is_read_only_and_secrets_and_home_are_absent(self):
        ws = str(self.home.workspace)
        self.assertIn(f"--ro-bind {ws} {ws}", self.joined)
        self.assertNotIn("secrets", self.joined)
        self.assertNotIn(os.path.expanduser("~") + " ", self.joined + " ")
        self.assertNotIn("/run/user", self.joined)
        self.assertEqual(self.argv[-1], "--")


if __name__ == "__main__":
    unittest.main()
