"""Helper unit tests (gate step agent-host-unit): no CLI, no network."""

import os
import stat
import tempfile
import unittest
from unittest import mock
from pathlib import Path

import http.client
import json
import struct
import subprocess

import support  # noqa: F401  (puts the helper package on sys.path)
from support import FakeAnthropicApi, lay_out_state
from zb_agent_host import files, hook_run, options, provision, sandbox, seccomp, token


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

    def test_tool_budgets_are_the_reviewed_production_values(self):
        self.assertEqual(options.MCP_TOOL_TIMEOUT_MS, 130_000)
        self.assertEqual(options.TOOL_DEADLINE_S, 120)
        self.assertEqual(self.build().env["MCP_TOOL_TIMEOUT"], "130000")

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


class AtomicWrite(unittest.TestCase):
    def test_short_writes_are_completed(self):
        written = []

        def one_byte(fd, data):
            written.append(bytes(data[:1]))
            return 1

        files.write_all(-1, b"zb-hook-run", write=one_byte)
        self.assertEqual(b"".join(written), b"zb-hook-run")

    def test_atomic_write_installs_every_byte_through_short_writes(self):
        real_write = os.write

        def one_byte(fd, data):
            return real_write(fd, bytes(data[:1]))

        target = Path(tempfile.mkdtemp(prefix="zb-unit-")) / "zb-hook-run"
        with mock.patch("zb_agent_host.files.os.write", one_byte):
            files.atomic_write(target, "#!/usr/bin/python3 -I\nprint('hook')\n", 0o700)
        self.assertEqual(target.read_text(), "#!/usr/bin/python3 -I\nprint('hook')\n")

    def test_a_write_that_makes_no_progress_fails(self):
        with self.assertRaises(OSError):
            files.write_all(-1, b"abc", write=lambda fd, data: 0)


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


def run_bpf(program, arch, nr):
    """Interprets the classic-BPF subset the filters use (ld abs word, jeq/jge k, ret k)."""
    insns = [struct.unpack_from("<HBBI", program, i) for i in range(0, len(program), 8)]
    data = struct.pack("<iIQ6Q", nr, arch, 0, *([0] * 6))  # struct seccomp_data
    acc, pc = 0, 0
    while True:
        code, jt, jf, k = insns[pc]
        if code == 0x20:
            acc = struct.unpack_from("<I", data, k)[0]
            pc += 1
        elif code in (0x15, 0x35):
            hit = acc == k if code == 0x15 else acc >= k
            pc += 1 + (jt if hit else jf)
        elif code == 0x06:
            return k
        else:
            raise AssertionError(f"unexpected BPF opcode {code:#x}")


class SandboxArgv(unittest.TestCase):
    def setUp(self):
        self.home = options.AgentHome(Path(tempfile.mkdtemp(prefix="zb-unit-")))
        for d in (".claude", "workspace", "scratchpad", "runtime"):
            (self.home.root / d).mkdir()
        lay_out_state(self.home.root)
        self.argv = sandbox.helper_argv(self.home)
        self.joined = " ".join(self.argv)

    def test_claude_is_read_only_with_only_state_dirs_writable(self):
        claude = str(self.home.claude_dir)
        self.assertIn(f"--ro-bind {claude} {claude}", self.joined)
        binds = [(self.argv[i + 1], self.argv[i + 2]) for i, a in enumerate(self.argv) if a == "--bind"]
        state = str(self.home.state)
        self.assertEqual(sorted(binds), sorted([(f"{state}/{d}", f"{claude}/{d}") for d in sandbox.STATE_DIRS]
                                               + [(str(self.home.scratchpad), str(self.home.scratchpad))]))
        # The CLI's state file and backups are state too, but read-only (plan rev 15.5).
        for name in (".claude.json", "backups"):
            self.assertIn(f"--ro-bind {state}/{name} {claude}/{name}", self.joined)

    def test_a_missing_mount_point_or_state_source_refuses_and_writes_nothing(self):
        """RoseCat 5405: a published build is never written after its publish."""
        for rel in (".claude/projects", ".claude/.claude.json", "state/MEMORY", "state/backups"):
            with self.subTest(rel):
                path = self.home.root / rel
                (path.rmdir if path.is_dir() else path.unlink)()
                before = sorted(p.relative_to(self.home.root) for p in self.home.root.rglob("*"))
                with self.assertRaises(sandbox.SandboxError):
                    sandbox.helper_argv(self.home)
                self.assertEqual(sorted(p.relative_to(self.home.root) for p in self.home.root.rglob("*")), before)
                lay_out_state(self.home.root)

    def test_the_outer_seccomp_filter_is_passed_to_bwrap(self):
        argv = sandbox.helper_argv(self.home, seccomp_fd=17)
        self.assertEqual(argv[argv.index("--seccomp") + 1], "17")
        self.assertLess(argv.index("--seccomp"), argv.index("--"))

    def test_seccomp_program_denies_ptrace_and_process_vm_but_not_namespaces(self):
        # Installed for real in a child: the probe gets EPERM, and bwrap still
        # creates its namespaces (the nested hooks need clone and unshare).
        program = Path(tempfile.mkdtemp(prefix="zb-unit-")) / "filter.bpf"
        program.write_bytes(seccomp.program())
        probe = Path(sandbox.__file__).with_name("probe.py")
        script = (
            "import ctypes, subprocess, sys\n"
            "libc = ctypes.CDLL(None, use_errno=True)\n"
            "data = open(sys.argv[1], 'rb').read()\n"
            "class F(ctypes.Structure): _fields_ = [('len', ctypes.c_ushort), ('filter', ctypes.c_char_p)]\n"
            "u = ctypes.c_ulong\n"
            "assert libc.prctl(ctypes.c_int(38), u(1), u(0), u(0), u(0)) == 0\n"
            "assert libc.syscall(ctypes.c_long(317), u(1), u(0), ctypes.byref(F(len(data) // 8, data))) == 0, ctypes.get_errno()\n"
            "print(subprocess.run(['/usr/bin/python3', '-I', sys.argv[2]], capture_output=True, text=True).stdout.strip())\n"
            "print(subprocess.run(['/usr/bin/bwrap', '--unshare-pid', '--unshare-ipc', '--bind', '/', '/', '--dev', '/dev',"
            " '--proc', '/proc', '/bin/true']).returncode)\n"
        )
        out = subprocess.run(["/usr/bin/python3", "-I", "-c", script, str(program), str(probe)],
                             capture_output=True, text=True, timeout=60)
        self.assertEqual(out.returncode, 0, out.stderr)
        result, bwrap_rc = out.stdout.splitlines()
        self.assertEqual(json.loads(result), {"ptrace_attach": "EPERM", "ptrace_traceme": "EPERM",
                                              "process_vm_readv": "EPERM", "process_vm_writev": "EPERM", "seccomp": 2})
        self.assertEqual(bwrap_rc, "0")

    def test_seccomp_program_decision_table(self):
        # P0.6 unit: the program run by a small classic-BPF interpreter over seccomp_data inputs.
        allow, eperm, kill = seccomp.RET_ALLOW, seccomp.RET_ERRNO | seccomp.EPERM, seccomp.RET_KILL_PROCESS
        x86 = seccomp.AUDIT_ARCH_X86_64
        table = [
            (x86, 101, eperm), (x86, 310, eperm), (x86, 311, eperm),            # ptrace, process_vm_*
            (x86, 0x40000000 | 101, eperm), (x86, 0x40000000 | 0, eperm),       # x32 numbers
            (0x40000003, 26, kill),                                             # i386 (a foreign arch)
            (x86, 56, allow), (x86, 435, allow), (x86, 272, allow),             # clone, clone3, unshare
            (x86, 165, allow), (x86, 155, allow), (x86, 308, allow),            # mount, pivot_root, setns
            (x86, 0, allow), (x86, 1, allow), (x86, 59, allow),                 # read, write, execve
        ]
        for arch, nr, expected in table:
            self.assertEqual(run_bpf(seccomp.program(), arch, nr), expected, (hex(arch), nr))

    def test_workspace_is_read_only_and_secrets_and_home_are_absent(self):
        ws = str(self.home.workspace)
        self.assertIn(f"--ro-bind {ws} {ws}", self.joined)
        self.assertNotIn("secrets", self.joined)
        self.assertNotIn(os.path.expanduser("~") + " ", self.joined + " ")
        self.assertNotIn("/run/user", self.joined)
        self.assertEqual(self.argv[-1], "--")


if __name__ == "__main__":
    unittest.main()
