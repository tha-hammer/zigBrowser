"""S3b (chat-drawer plan S3.2, S3.6; D7, D7b; rev 16 §3c.1, §3c.2, §3c.4): the
helper's `chat` command over its real pipes, and `launch`, which builds the
sandbox argv (own network, netd's egress, the outer relay as its command) and
execs bwrap in place. The token arrives on fd 3; the Messages API is P0's fake."""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

HOST_DIR = Path(__file__).resolve().parents[1]
REPO = HOST_DIR.parents[1]
sys.path.insert(0, str(HOST_DIR))
sys.path.insert(0, str(REPO / "tests" / "e2e"))

from fake_anthropic_api import FakeAnthropicApi  # noqa: E402
from test_provision import Sandbox  # noqa: E402
from zb_agent_host import chat, launch, options, relay  # noqa: E402

CANARY = "zb-canary-" + "c" * 32


class Helper:
    """`python -m zb_agent_host chat` with the D7 environment and fd 3."""

    def __init__(self, tc, home, token=CANARY):
        read, write = os.pipe()
        os.write(write, token.encode() + b"\n")
        os.close(write)
        env = {"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "PYTHONPATH": str(HOST_DIR), "PYTHONDONTWRITEBYTECODE": "1",
               **options.home_env(home)}
        # The token's pipe becomes fd 3, as the app hands it over.
        move = "" if read == 3 else f"exec 3<&{read} {read}<&-; "
        self.proc = subprocess.Popen(["/bin/sh", "-c", move + 'exec "$0" "$@"',
                                      sys.executable, "-m", "zb_agent_host", "chat", "--home", str(home.root),
                                      "--fifo-dir", str(home.scratchpad / "tmp" / "zb-token")],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                     env=env, pass_fds=(read,), text=True)
        os.close(read)
        self.seq = 0
        tc.addCleanup(self.kill)

    def send(self, type_, **fields):
        self.seq += 1
        self.proc.stdin.write(json.dumps({"v": 1, "seq": self.seq, "type": type_, **fields}) + "\n")
        self.proc.stdin.flush()

    def frame(self, timeout=60):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            line = self.proc.stdout.readline()
            if not line:
                raise AssertionError(f"helper exited: {self.proc.stderr.read()[-2000:]}")
            return json.loads(line)
        raise AssertionError("no frame")

    def until(self, type_, timeout=60):
        seen = []
        while True:
            f = self.frame(timeout)
            seen.append(f)
            if f["type"] == type_:
                return f, seen

    def kill(self):
        if self.proc.poll() is None:
            self.proc.kill()
        self.proc.wait()
        for stream in (self.proc.stdin, self.proc.stdout, self.proc.stderr):
            try:
                stream.close()
            except BrokenPipeError:
                pass


HELPER_ENV = {"PATH", "LANG", "HOME", "CLAUDE_CONFIG_DIR", "TMPDIR", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC",
              "CLAUDE_AGENT_SDK_SKIP_VERSION_CHECK"}
PROXY = "http://127.0.0.1:3128"


def provisioned(tc, route="R1"):
    box = Sandbox(tc)
    box.provision()
    record = box.home.runtime / "token-route.json"
    if route is not None:
        record.write_text(json.dumps({"route": route, "cli_path": "x", "cli_version": "x"}))
    elif record.exists():
        record.unlink()
    return box


def net_dir(tc):
    """A stand-in for netd's socket directory: egress/ and bridges/, no sockets."""
    path = Path(tempfile.mkdtemp(prefix="zbn-"))
    tc.addCleanup(shutil.rmtree, path, True)
    (path / "egress").mkdir(mode=0o700)
    (path / "bridges").mkdir(mode=0o700)
    return path


class ChatTest(unittest.TestCase):
    def test_ready_then_a_session_streams_a_reply_and_ends(self):
        box = provisioned(self)
        with FakeAnthropicApi(turns=[{"text": "Hello from the agent"}]) as api:
            base_url = api.base_url
            h = Helper(self, box.home)
            ready = h.frame()
            self.assertEqual(ready["type"], "ready")
            self.assertEqual((ready["route"], ready["tool_deadline_s"]), ("R1", 120))
            self.assertEqual(ready["selfcheck"], {"ok": True, "failures": []})
            h.send("hello", agent_home=str(box.home.root), workspace=str(box.home.workspace),
                   scratchpad=str(box.home.scratchpad), route="R1", e2e={"test_base_url": api.base_url})
            h.send("open_session", session="s-1-1", window_id="window-1")
            opened, _ = h.until("session_opened")
            self.assertEqual(opened["session"], "s-1-1")
            h.send("prompt", session="s-1-1", text="hi")
            result, seen = h.until("result", timeout=120)
            message = [f for f in seen if f["type"] == "assistant_message"]
            self.assertEqual([m["text"] for m in message], ["Hello from the agent"])
            self.assertFalse(result["is_error"])
            seqs = [f["seq"] for f in [ready, opened] + seen]
            self.assertEqual(seqs, sorted(set(seqs)))
            self.assertTrue(any(r["headers"].get("authorization") == f"Bearer {CANARY}"
                                for r in api.messages_requests()), "the token reached the API on R1")
            h.send("end_session", session="s-1-1")
            ended, _ = h.until("session_ended")
            self.assertEqual(ended["reason"], "end")
            h.send("shutdown")
            self.assertEqual(h.proc.wait(timeout=30), 0)
        log = json.loads((box.home.scratchpad / "helper-hello.json").read_text())
        self.assertEqual(log["e2e"], {"test_base_url": base_url})

    def test_a_legacy_r3_record_refuses_with_exit_2_and_no_frame(self):
        """RoseCat's carried condition (ced999f): R3 was removed (§3c.1); its record fails closed."""
        box = provisioned(self, route="R3")
        h = Helper(self, box.home)
        self.assertEqual(h.proc.wait(timeout=30), 2)
        self.assertEqual(h.proc.stdout.read(), "")
        self.assertEqual(h.proc.stderr.read(),
                         "zigBrowser: agent: token route R3 was removed: run zigBrowser --agent-setup again\n")

    def test_a_missing_or_unknown_route_record_refuses_with_exit_2(self):
        for route in (None, "R2", ""):
            with self.subTest(route=route):
                box = provisioned(self, route=route)
                h = Helper(self, box.home)
                self.assertEqual(h.proc.wait(timeout=30), 2)
                self.assertEqual(h.proc.stdout.read(), "")
                self.assertEqual(h.proc.stderr.read(),
                                 "zigBrowser: agent: token route is not set up: run zigBrowser --agent-setup\n")

    def test_a_missing_or_bad_token_is_reported_and_the_helper_exits(self):
        box = provisioned(self)
        h = Helper(self, box.home, token="short")
        f = h.frame()
        self.assertEqual((f["type"], f["code"]), ("error", "auth"))
        self.assertNotIn("short", json.dumps(f))
        self.assertNotEqual(h.proc.wait(timeout=30), 0)

    def test_an_unknown_frame_from_the_app_is_an_error_not_a_crash(self):
        box = provisioned(self)
        h = Helper(self, box.home)
        h.frame()
        h.send("frobnicate")
        f, _ = h.until("error")
        self.assertEqual(f["code"], "protocol")
        h.send("shutdown")
        self.assertEqual(h.proc.wait(timeout=30), 0)


class SessionOptionsTest(unittest.TestCase):
    """§3c.2: the CLI reaches the network only through the outer relay; §3c.4 / 5570:
    the test CA reaches the CLI's environment only, and only when launch passed it."""

    def setUp(self):
        self.home = options.AgentHome("/h")

    def env(self, **kw):
        args = dict(route_env={"ZB_TOKEN_FIFO": "/run/zb-token/x"}, cli_path="/h/runtime/bin/zb-claude",
                    e2e=None, test_ca=None)
        args.update(kw)
        return chat.session_options(self.home, **args).env

    def test_the_cli_always_gets_the_relay_as_its_proxy(self):
        env = self.env()
        self.assertEqual((env["HTTPS_PROXY"], env["HTTP_PROXY"], env["NO_PROXY"]),
                         (PROXY, PROXY, "127.0.0.1,localhost"))
        self.assertNotIn("NODE_EXTRA_CA_CERTS", env)
        self.assertNotIn("ANTHROPIC_BASE_URL", env)

    def test_a_hello_test_proxy_is_ignored(self):
        env = self.env(e2e={"test_proxy": "http://203.0.113.9:8080"})
        self.assertEqual(env["HTTPS_PROXY"], PROXY)
        self.assertNotIn("203.0.113.9", json.dumps(env))

    def test_the_test_base_url_and_ca_reach_the_cli(self):
        env = self.env(e2e={"test_base_url": "https://fake.zb.invalid"}, test_ca="/run/zb-test-ca.pem")
        self.assertEqual(env["ANTHROPIC_BASE_URL"], "https://fake.zb.invalid")
        self.assertEqual(env["NODE_EXTRA_CA_CERTS"], "/run/zb-test-ca.pem")


class LaunchArgvTest(unittest.TestCase):
    def setUp(self):
        self.box = provisioned(self)
        self.net = net_dir(self)
        self.runtime = str(self.box.home.runtime)

    def argv(self, **kw):
        return launch.build_argv(self.box.home, seccomp_fd=9, python="/v/bin/python", net_dir=self.net,
                                 bwrap="/usr/bin/bwrap", **kw)

    def test_the_argv_is_the_sandbox_with_its_own_network_and_the_relay_as_its_command(self):
        argv = self.argv()
        self.assertEqual(argv[0], "/usr/bin/bwrap")
        self.assertEqual(argv[argv.index("--seccomp") + 1], "9")
        self.assertIn("--unshare-net", argv)
        sep = argv.index("--")
        pairs = [(argv[i + 1], argv[i + 2]) for i, a in enumerate(argv[:sep]) if a == "--ro-bind"]
        self.assertIn((str(self.net / "egress"), "/run/zb-net/egress"), pairs)
        self.assertIn((str(self.net / "bridges"), "/run/zb-net/bridges"), pairs)
        self.assertIn(("/v", "/v"), pairs)
        self.assertIn((str(self.box.bin), str(self.box.bin)), pairs)
        self.assertEqual(argv[sep + 1:], [
            "/usr/bin/python3", "-I", "-S", f"{self.runtime}/bin/zb-net-relay", "--egress", "/run/zb-net/egress", "--",
            "/v/bin/python", "-I", "-c", launch.CHAT_BOOT, f"{self.runtime}/host",
            "chat", "--home", str(self.box.home.root)])
        self.assertNotIn(str(self.box.home.root / "secrets"), " ".join(argv))
        self.assertNotIn("--dev-bind", argv)

    def test_the_test_ca_is_bound_read_only_and_named_to_chat(self):
        argv = self.argv(test_ca="/x/ca.pem")
        sep = argv.index("--")
        at = argv.index("/x/ca.pem")
        self.assertLess(argv.index("/run"), at, "after the /run tmpfs")
        self.assertEqual(argv[at - 1:at + 2], ["--ro-bind", "/x/ca.pem", "/run/zb-test-ca.pem"])
        self.assertLess(at, sep)
        self.assertEqual(argv[-2:], ["--test-ca", "/run/zb-test-ca.pem"])
        self.assertNotIn("--test-ca", self.argv())


class LaunchRunTest(unittest.TestCase):
    def setUp(self):
        self.box = provisioned(self)
        self.net = net_dir(self)
        self.tmp = Path(tempfile.mkdtemp(prefix="zb-launch-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def run_launch(self, *extra, bwrap=None, env=None, pass_token=False):
        args = [sys.executable, "-m", "zb_agent_host", "launch", "--home", str(self.box.home.root),
                "--python", sys.executable, *extra]
        if bwrap is not None:
            args += ["--bwrap", str(bwrap)]
        base = {"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "PYTHONPATH": str(HOST_DIR), "PYTHONDONTWRITEBYTECODE": "1"}
        read, write = os.pipe()
        os.write(write, CANARY.encode())
        os.close(write)
        move = "" if read == 3 else f"exec 3<&{read} {read}<&-; "
        try:
            return subprocess.run(["/bin/sh", "-c", move + 'exec "$0" "$@"', *args], env={**base, **(env or {})},
                                  pass_fds=(read,), capture_output=True, text=True, timeout=60)
        finally:
            os.close(read)

    def recorder(self):
        """A stand-in bwrap that records its pid, argv, environment and open descriptors."""
        out = self.tmp / "bwrap.json"
        path = self.tmp / "bwrap"
        path.write_text(f"""#!/usr/bin/python3 -I
import json, os, sys
def is_open(fd):
    try:
        os.fstat(fd)
        return True
    except OSError:
        return False
fds = [fd for fd in range(1024) if is_open(fd)]
json.dump({{"pid": os.getpid(), "ppid": os.getppid(), "argv": sys.argv, "env": dict(os.environ), "fds": fds}},
          open({str(out)!r}, "w"))
""")
        path.chmod(0o755)
        return path, out

    def test_a_missing_bwrap_is_reported_with_its_own_exit_status(self):
        done = self.run_launch("--net-dir", str(self.net), bwrap="/nonexistent/bwrap")
        self.assertEqual(done.returncode, launch.EXIT_NO_SANDBOX)
        self.assertEqual(done.stderr, "zigBrowser: agent: sandbox unavailable (bwrap)\n")

    def test_the_net_dir_is_required(self):
        bwrap, out = self.recorder()
        done = self.run_launch(bwrap=bwrap)
        self.assertEqual(done.returncode, 2)
        self.assertFalse(out.exists())

    def test_a_missing_or_linked_test_ca_refuses_before_bwrap(self):
        bwrap, out = self.recorder()
        real = self.tmp / "ca.pem"
        real.write_text("pem")
        link = self.tmp / "link.pem"
        link.symlink_to(real)
        for ca in (self.tmp / "absent.pem", link, self.tmp):
            with self.subTest(ca=ca.name):
                done = self.run_launch("--net-dir", str(self.net), "--test-ca", str(ca), bwrap=bwrap)
                self.assertEqual((done.returncode, done.stderr),
                                 (2, "zigBrowser: agent: bad ZIGBROWSER_AGENT_NET_TEST_CA\n"))
                self.assertFalse(out.exists())

    def test_bwrap_gets_exactly_the_helper_environment_the_token_and_the_filter(self):
        bwrap, out = self.recorder()
        hostile = {"DISPLAY": ":0", "XDG_RUNTIME_DIR": "/run/user/1000", "DBUS_SESSION_BUS_ADDRESS": "unix:path=/x",
                   "ZIGBROWSER_SOCKET": "/x", "SSH_AUTH_SOCK": "/x", "ZB_CANARY_ENV": "canary"}
        done = self.run_launch("--net-dir", str(self.net), bwrap=bwrap, env=hostile)
        self.assertEqual(done.returncode, 0, done.stderr)
        seen = json.loads(out.read_text())
        self.assertEqual(set(seen["env"]), HELPER_ENV)
        self.assertEqual(seen["env"]["HOME"], str(self.box.home.root))
        self.assertEqual(seen["argv"][1:], launch.build_argv(self.box.home, seccomp_fd=int(seen["argv"][
            seen["argv"].index("--seccomp") + 1]), python=sys.executable, net_dir=self.net, bwrap=str(bwrap))[1:])
        seccomp_fd = int(seen["argv"][seen["argv"].index("--seccomp") + 1])
        self.assertEqual(seen["fds"], sorted({0, 1, 2, 3, seccomp_fd}), "only stdio, the token and the filter")


class LaunchSandboxTest(unittest.TestCase):
    """The real chain: launch -> bwrap (own network) -> the outer relay -> chat."""

    def test_chat_runs_under_the_relay_in_its_own_network_with_the_helper_environment(self):
        box = provisioned(self)
        net = net_dir(self)
        read, write = os.pipe()
        os.write(write, CANARY.encode())
        os.close(write)
        move = "" if read == 3 else f"exec 3<&{read} {read}<&-; "
        env = {"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "PYTHONPATH": str(HOST_DIR), "PYTHONDONTWRITEBYTECODE": "1",
               "DISPLAY": ":0", "ZB_CANARY_ENV": "canary"}
        proc = subprocess.Popen(["/bin/sh", "-c", move + 'exec "$0" "$@"', sys.executable, "-m", "zb_agent_host",
                                 "launch", "--home", str(box.home.root), "--python", sys.executable, "--net-dir", str(net)],
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env,
                                pass_fds=(read,), text=True)
        os.close(read)

        def stop():
            if proc.poll() is None:
                proc.kill()
                proc.wait()
            for stream in (proc.stdin, proc.stdout, proc.stderr):
                stream.close()
        self.addCleanup(stop)
        line = proc.stdout.readline()
        self.assertTrue(line, proc.stderr.read() if proc.poll() is not None else "no ready frame")
        ready = json.loads(line)
        self.assertEqual((ready["type"], ready["route"]), ("ready", "R1"))
        tree = descendants(proc.pid)
        chat_pid = next(p for p in tree if b"chat" in cmdline(p) and b"-c" in cmdline(p))
        relay_pid = ppid(chat_pid)
        self.assertIn(b"zb-net-relay", cmdline(relay_pid))
        self.assertEqual(set(environ(chat_pid)), HELPER_ENV)
        self.assertNotEqual(os.readlink(f"/proc/{chat_pid}/ns/net"), os.readlink("/proc/self/ns/net"))
        proc.stdin.write(json.dumps({"v": 1, "seq": 1, "type": "shutdown"}) + "\n")
        proc.stdin.flush()
        self.assertEqual(proc.wait(timeout=30), 0, proc.stderr.read())


def cmdline(pid):
    with open(f"/proc/{pid}/cmdline", "rb") as f:
        return f.read()


def ppid(pid):
    with open(f"/proc/{pid}/stat") as f:
        return int(f.read().rsplit(")", 1)[1].split()[1])


def environ(pid):
    with open(f"/proc/{pid}/environ", "rb") as f:
        return {item.split(b"=", 1)[0].decode() for item in f.read().split(b"\0") if item}


def descendants(root):
    children = {}
    for name in os.listdir("/proc"):
        if name.isdigit():
            try:
                children.setdefault(ppid(int(name)), []).append(int(name))
            except OSError:
                pass
    out, todo = [], [root]
    while todo:
        pid = todo.pop()
        for child in children.get(pid, []):
            out.append(child)
            todo.append(child)
    return out


if __name__ == "__main__":
    unittest.main()
