"""S3b (chat-drawer plan S3.2, S3.6; D7, D7b; rev 16 §3c.1, §3c.2, §3c.4): the
helper's `chat` command over its real pipes, and `launch`, which builds the
sandbox argv (own network, netd's egress, the outer relay as its command) and
execs bwrap in place. The token arrives on fd 3; the Messages API is P0's fake."""

import asyncio
import contextlib
import json
import os
import queue
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import types
import unittest
from pathlib import Path

HOST_DIR = Path(__file__).resolve().parents[1]
REPO = HOST_DIR.parents[1]
sys.path.insert(0, str(HOST_DIR))
sys.path.insert(0, str(REPO / "tests" / "e2e"))

from fake_anthropic_api import FakeAnthropicApi  # noqa: E402
from test_provision import Sandbox  # noqa: E402
from zb_agent_host import chat, launch, options, relay, sandbox  # noqa: E402

CANARY = "zb-canary-" + "c" * 32


class Helper:
    """`python -m zb_agent_host chat` with the D7 environment and fd 3. `prelude`: Python
    run in the helper first (a test's fault injection), then the module as `-m` runs it."""

    def __init__(self, tc, home, token=CANARY, prelude=None):
        read, write = os.pipe()
        os.write(write, token.encode() + b"\n")
        os.close(write)
        env = {"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "PYTHONPATH": str(HOST_DIR), "PYTHONDONTWRITEBYTECODE": "1",
               **options.home_env(home)}
        # The token's pipe becomes fd 3, as the app hands it over.
        move = "" if read == 3 else f"exec 3<&{read} {read}<&-; "
        module = ["-m", "zb_agent_host"] if prelude is None else [
            "-c", prelude + "\nimport runpy\nrunpy.run_module('zb_agent_host', run_name='__main__', alter_sys=True)"]
        self.proc = subprocess.Popen(["/bin/sh", "-c", move + 'exec "$0" "$@"',
                                      sys.executable, *module, "chat", "--home", str(home.root),
                                      "--fifo-dir", str(home.scratchpad / "tmp" / "zb-token")],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                     env=env, pass_fds=(read,), text=True, start_new_session=True)
        os.close(read)
        self.seq = 0
        self.lines = queue.Queue()  # stdout lines, then None at EOF
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()
        tc.addCleanup(self.kill)

    def _read(self):
        for line in self.proc.stdout:
            self.lines.put(line)
        self.lines.put(None)

    def send(self, type_, **fields):
        self.seq += 1
        self.proc.stdin.write(json.dumps({"v": 1, "seq": self.seq, "type": type_, **fields}) + "\n")
        self.proc.stdin.flush()

    def frame(self, timeout=60):
        try:
            line = self.lines.get(timeout=timeout)
        except queue.Empty:
            raise AssertionError("no frame") from None
        if line is None:
            self.lines.put(None)
            raise AssertionError(f"helper exited: {self.proc.stderr.read()[-2000:]}")
        return json.loads(line)

    def rest(self, quiet=3.0):
        """Every frame until stdout ends or `quiet` seconds pass without one."""
        frames = []
        while True:
            try:
                line = self.lines.get(timeout=quiet)
            except queue.Empty:
                return frames
            if line is None:
                self.lines.put(None)
                return frames
            frames.append(json.loads(line))

    def until(self, type_, timeout=60):
        seen = []
        while True:
            f = self.frame(timeout)
            seen.append(f)
            if f["type"] == type_:
                return f, seen

    def kill(self):
        """The helper and everything it started (its CLI children): its own process
        group, so no CLI outlives a test (S5c-1: an orphaned CLI kept reading)."""
        with contextlib.suppress(ProcessLookupError):
            os.killpg(self.proc.pid, signal.SIGKILL)
        self.proc.wait()
        self.reader.join(10)
        for stream in (self.proc.stdin, self.proc.stdout, self.proc.stderr):
            try:
                stream.close()
            except BrokenPipeError:
                pass


HELPER_ENV = {"PATH", "LANG", "HOME", "CLAUDE_CONFIG_DIR", "TMPDIR", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC",
              "CLAUDE_AGENT_SDK_SKIP_VERSION_CHECK"}
PROXY = "http://127.0.0.1:3128"
# The SDK gives a CLI 5 s to exit after stdin EOF (it flushes its session file), then
# terminates it: a session closed mid-prompt ends within that, plus margin.
SDK_CLOSE_S = 15.0


def provisioned(tc, route="R1"):
    box = Sandbox(tc)
    box.provision()
    record = box.home.runtime / "token-route.json"
    if route is not None:
        record.write_text(json.dumps({"route": route, "cli_path": "x", "cli_version": "x"}))
    elif record.exists():
        record.unlink()
    return box


def fifos(box):
    """The R1 FIFOs left in Helper's FIFO directory (outside the sandbox, so not
    /run/zb-token). The directory is 0300, unlistable; the test opens it for a moment."""
    path = box.home.scratchpad / "tmp" / "zb-token"
    if not path.exists():
        return []
    os.chmod(path, 0o700)
    try:
        return sorted(path.iterdir())
    finally:
        os.chmod(path, 0o300)


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
            # No SDK session id exists yet when the session opens (RoseCat 5632).
            self.assertEqual(set(opened), {"v", "seq", "type", "session"})
            self.assertEqual(opened["session"], "s-1-1")
            h.send("prompt", session="s-1-1", text="hi")
            result, seen = h.until("result", timeout=120)
            # The real one comes with the result: the CLI's own transcript is named after it.
            transcripts = [p.stem for p in (box.home.claude_dir / "projects").glob("*/*.jsonl")]
            self.assertEqual([result["sdk_session_id"]], transcripts)
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
        self.assertEqual(h.rest(), [])
        self.assertEqual(h.proc.stderr.read(),
                         "zigBrowser: agent: token route R3 was removed: run zigBrowser --agent-setup again\n")

    def test_a_missing_or_unknown_route_record_refuses_with_exit_2(self):
        for route in (None, "R2", ""):
            with self.subTest(route=route):
                box = provisioned(self, route=route)
                h = Helper(self, box.home)
                self.assertEqual(h.proc.wait(timeout=30), 2)
                self.assertEqual(h.rest(), [])
                self.assertEqual(h.proc.stderr.read(),
                                 "zigBrowser: agent: token route is not set up: run zigBrowser --agent-setup\n")

    def test_a_missing_or_bad_token_is_reported_and_the_helper_exits(self):
        box = provisioned(self)
        h = Helper(self, box.home, token="short")
        f = h.frame()
        self.assertEqual((f["type"], f["code"]), ("error", "auth"))
        self.assertNotIn("short", json.dumps(f))
        self.assertNotEqual(h.proc.wait(timeout=30), 0)

    def test_a_duplicate_open_session_fails_closed_and_keeps_the_open_one(self):
        """RoseCat 5633: a second open of a live id never replaces (or leaks) the first."""
        box = provisioned(self)
        with FakeAnthropicApi(turns=[{"text": "still here"}]) as api:
            h = Helper(self, box.home)
            h.frame()
            h.send("hello", agent_home=str(box.home.root), workspace=str(box.home.workspace),
                   scratchpad=str(box.home.scratchpad), route="R1", e2e={"test_base_url": api.base_url})
            h.send("open_session", session="s-1-1", window_id="window-1")
            h.until("session_opened")
            h.send("open_session", session="s-1-1", window_id="window-1")
            refused, _ = h.until("error")
            self.assertEqual((refused["code"], refused["session"]), ("protocol", "s-1-1"))
            h.send("prompt", session="s-1-1", text="hi")
            result, seen = h.until("result", timeout=120)
            self.assertEqual([f["text"] for f in seen if f["type"] == "assistant_message"], ["still here"])
            self.assertEqual(fifos(box), [], "no FIFO is left behind")
            h.send("shutdown")
            self.assertEqual(h.proc.wait(timeout=30), 0)

    def test_a_session_that_cannot_open_is_reported_and_the_helper_stays(self):
        """RoseCat 5633: open() failing closes the new session's route and reports it."""
        box = provisioned(self)
        wrapper = box.home.runtime / "bin" / "zb-claude"
        wrapper.write_text("#!/bin/sh\nexit 1\n")
        h = Helper(self, box.home)
        h.frame()
        h.send("open_session", session="s-1-1", window_id="window-1")
        failed, seen = h.until("error", timeout=120)
        self.assertEqual((failed["code"], failed["session"]), ("sdk", "s-1-1"))
        self.assertNotIn("session_opened", [f["type"] for f in seen])
        self.assertEqual(fifos(box), [], "the failed session's FIFO is gone")
        h.send("frobnicate")
        f, _ = h.until("error")
        self.assertEqual(f["code"], "protocol", "the helper still answers")
        h.send("shutdown")
        self.assertEqual(h.proc.wait(timeout=30), 0)

    def test_an_unknown_frame_from_the_app_is_an_error_not_a_crash(self):
        box = provisioned(self)
        h = Helper(self, box.home)
        h.frame()
        h.send("frobnicate")
        f, _ = h.until("error")
        self.assertEqual(f["code"], "protocol")
        h.send("shutdown")
        self.assertEqual(h.proc.wait(timeout=30), 0)


class PromptLifecycleTest(unittest.TestCase):
    """RoseCat 5628.3: one prompt at a time per session, and nothing of a session after it
    ended. The fake holds the first messages request until `release`, so a prompt is in
    flight. (A unit test of chat's frames; the closure runs in agent_host_lifecycle_test.)"""

    def setUp(self):
        self.box = provisioned(self)
        self.release = threading.Event()
        self.api = FakeAnthropicApi(responder=self.held)
        self.api.start()
        self.addCleanup(self.api.stop)
        self.addCleanup(self.release.set)
        self.h = Helper(self, self.box.home)
        self.assertEqual(self.h.frame()["type"], "ready")
        self.h.send("hello", agent_home=str(self.box.home.root), workspace=str(self.box.home.workspace),
                    scratchpad=str(self.box.home.scratchpad), route="R1", e2e={"test_base_url": self.api.base_url})
        self.h.send("open_session", session="s-1-1", window_id="window-1")
        self.h.until("session_opened")
        self.h.send("prompt", session="s-1-1", text="first")
        deadline = time.monotonic() + 60
        while not self.api.messages_requests() and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertTrue(self.api.messages_requests(), "the first prompt reached the fake")

    def held(self, entry, index):
        self.release.wait(60)
        return {"text": f"reply {index}"}

    def rest(self, quiet=3.0):
        return self.h.rest(quiet)

    def test_a_second_prompt_while_one_runs_is_refused_busy_and_never_runs(self):
        self.h.send("prompt", session="s-1-1", text="second")
        busy, _ = self.h.until("error")
        self.assertEqual((busy["code"], busy["session"]), ("busy", "s-1-1"))
        self.release.set()
        self.h.until("result")
        later = self.rest()
        self.assertEqual([f for f in later if f["type"] == "result"], [], "only the first prompt ran")
        self.assertEqual(len(self.api.messages_requests()), 1)

    def test_end_session_during_a_prompt_cancels_and_awaits_it_first(self):
        # The reply is released at once: only a prompt cancelled (and awaited) before the
        # disconnect keeps it from reaching the drawer while the session closes.
        self.h.send("end_session", session="s-1-1")
        self.release.set()
        frames = self.rest(SDK_CLOSE_S)
        self.assertEqual([(f["type"], f.get("session")) for f in frames], [("session_ended", "s-1-1")], frames)
        self.h.send("shutdown")
        self.assertEqual(self.h.proc.wait(timeout=30), 0)

    def test_shutdown_during_a_prompt_ends_the_session_and_exits_cleanly(self):
        self.h.send("shutdown")
        self.release.set()
        frames = self.rest(SDK_CLOSE_S)
        self.assertEqual([f["type"] for f in frames], ["session_ended"], frames)
        self.assertEqual(self.h.proc.wait(timeout=30), 0)
        self.assertNotIn("Traceback", self.h.proc.stderr.read())

    def test_eof_during_a_prompt_ends_the_session_and_exits_cleanly(self):
        self.h.proc.stdin.close()
        self.release.set()
        frames = self.rest(SDK_CLOSE_S)
        self.assertEqual([f["type"] for f in frames], ["session_ended"], frames)
        self.assertEqual(self.h.proc.wait(timeout=30), 0)
        self.assertNotIn("Traceback", self.h.proc.stderr.read())


class CancelThenAwaitTest(unittest.IsolatedAsyncioTestCase):
    """RoseCat 5681: Session.close must not disconnect or end the session while the
    cancelled prompt is still cleaning up. The prompt here holds out after its
    cancellation until `cleanup` is set, which a real SDK reply would mask."""

    async def test_close_waits_for_the_cancelled_prompt_before_disconnect_and_session_ended(self):
        events, cleanup = [], asyncio.Event()

        class Client:
            async def disconnect(self):
                events.append("disconnect")

        class Route:
            def close(self):
                events.append("route closed")

        class Out:
            def emit(self, kind, **_fields):
                events.append(kind)

        async def stubborn():
            try:
                await asyncio.sleep(3600)
            except asyncio.CancelledError:
                events.append("cancelled")
                await cleanup.wait()
                events.append("cleanup done")
                raise

        session = chat.Session.__new__(chat.Session)
        async def scrubbed(kind, *_ids):  # S5.7 (c): the close's scan, before session_ended
            events.append(f"scrubbed {kind}")

        session.chat, session.id = types.SimpleNamespace(out=Out(), scrubbed=scrubbed), "s-1-1"
        session.client, session.route = Client(), Route()
        session.task = asyncio.create_task(stubborn())
        self.addCleanup(cleanup.set)  # a failing run must still let the prompt finish
        await asyncio.sleep(0)
        closing = asyncio.create_task(session.close("end"))
        await asyncio.sleep(0.2)
        early = list(events)
        cleanup.set()
        self.assertEqual(early, ["cancelled"], "nothing closes while the prompt is still cleaning up")
        await asyncio.wait_for(closing, 5)
        self.assertEqual(events, ["cancelled", "cleanup done", "disconnect", "route closed", "scrubbed close",
                                  "session_ended"])


class SessionOptionsTest(unittest.TestCase):
    """§3c.2: the CLI reaches the network only through the outer relay; §3c.4 / 5570:
    the test CA reaches the CLI's environment only, and only when launch passed it."""

    def setUp(self):
        self.home = options.AgentHome("/h")

    def env(self, **kw):
        args = dict(route_env={"ZB_TOKEN_FIFO": "/run/zb-token/x"}, cli_path="/h/runtime/bin/zb-claude",
                    e2e=None, test_ca=None, proxy=sandbox.linux_helper_proxy())
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
        # chat itself: `<python> -I -c CHAT_BOOT <package> chat ...` (bwrap's and the
        # relay's argv name chat too, after their own options).
        chat_pid = next(p for p in tree if cmdline(p).split(b"\0")[1:3] == [b"-I", b"-c"]
                        and cmdline(p).split(b"\0")[5:6] == [b"chat"])
        relay_pid = ppid(chat_pid)
        self.assertIn(b"zb-net-relay", cmdline(relay_pid))
        # bwrap adds PWD (its --chdir, the workspace) to what launch gave it.
        self.assertEqual(set(environ(chat_pid)), HELPER_ENV | {"PWD"})
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
