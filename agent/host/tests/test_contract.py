"""P0 boundary contracts: the real claude-agent-sdk and its bundled Claude CLI,
run by the real helper, against a fake Messages API (the only mock).

Canary tokens only; ANTHROPIC_BASE_URL is the fake and HTTPS_PROXY/HTTP_PROXY
point at its refusing proxy, so no request can leave for a real host.
"""

import json
import os
import secrets
import stat
import threading
import time
import unittest

from pathlib import Path

import support
from support import (DECOY_MARKER, HOOK_EVENTS, FakeAnthropicApi, Helper, Homes, Inotify, NotifyServer, canary,
                     host_python, install_dump_hooks, processes_holding, provision)
from zb_agent_host import hook_run, options, provision as provisioning, sandbox

TURN_TIMEOUT = 90


def turn_args(homes, api, route, extra=()):
    return ["--home", str(homes.agent), "--base-url", api.base_url, "--proxy", api.base_url,
            "--route", route, "--fifo-dir", str(homes.root / "token-fifo"), "--prompt", "Say hello.", *extra]


def body_text(request):
    return json.dumps(request["body"])


class ContractCase(unittest.TestCase):
    def setUp(self):
        self.homes = Homes()
        self.token = canary()
        self.helpers = []

    def tearDown(self):
        for helper in self.helpers:
            helper.kill()
        self.homes.cleanup()

    def run_turn(self, api, route, extra=(), env_extra=None, on_tool_call=None, argv_prefix=None):
        helper = Helper(self.homes, "contract-config", turn_args(self.homes, api, route, extra), self.token, env_extra,
                        argv_prefix=argv_prefix)
        self.helpers.append(helper)
        answered = set()

        def done(frame):
            if frame.get("type") == "tool_call" and on_tool_call and frame["id"] not in answered:
                answered.add(frame["id"])
                on_tool_call(helper, frame)
            return frame.get("type") in ("result", "error")

        result = helper.wait_frame(done, TURN_TIMEOUT)
        rc = helper.finish()
        self.assertIsNotNone(result, f"no result frame: {helper.describe()}")
        self.assertEqual(result.get("type"), "result", helper.describe())
        self.assertEqual(rc, 0, helper.describe())
        return helper


class P01OwnConfig(ContractCase):
    """P0.1: the agent's own config is loaded from its own CLAUDE_CONFIG_DIR."""

    def test_user_settings_from_agent_home(self):
        with FakeAnthropicApi([{"text": "Hello from the fake."}]) as api:
            self.run_turn(api, "R3")
        sent = api.messages_requests()
        self.assertTrue(sent, "the CLI never called /v1/messages")
        self.assertTrue(any(self.homes.marker in body_text(r) for r in sent),
                        "the agent home's CLAUDE.md marker never reached the model")
        for r in sent:
            self.assertNotIn(DECOY_MARKER, body_text(r), "the decoy user's CLAUDE.md was loaded")
        self.assertFalse((self.homes.decoy / "decoy-hook-ran").exists(), "a decoy user hook ran")
        self.assertFalse((self.homes.decoy / ".claude.json").exists(), "the CLI wrote into the decoy HOME")
        self.assertTrue((self.homes.agent / ".claude").is_dir())


class P02FakeApiAndRoutes(ContractCase):
    """P0.2: the fake API at ANTHROPIC_BASE_URL is accepted; the token reaches it as a bearer."""

    REQUIRED_OTHER_ROUTES = []  # paths besides /v1/messages the CLI calls (recorded by these runs)

    def check_turn(self, api, helper):
        sent = api.messages_requests()
        self.assertTrue(sent)
        for r in sent:
            self.assertEqual(r["headers"].get("authorization"), f"Bearer {self.token}")
        texts = [f.get("text") for f in helper.frames if f.get("type") == "assistant_message"]
        self.assertIn("Scripted reply.", texts, helper.describe())
        self.assertEqual(api.tunnels, [], "the CLI tried to reach another host")
        self.assertEqual(api.other_paths(), self.REQUIRED_OTHER_ROUTES)

    def test_r3_env_route_delivers_bearer(self):
        seen = {}

        def scan(entry, index):
            seen.setdefault(index, processes_holding(self.token))
            return None

        with FakeAnthropicApi([{"text": "Scripted reply."}], responder=scan) as api:
            helper = self.run_turn(api, "R3")
        self.check_turn(api, helper)
        holders = seen[0]
        self.assertTrue(holders, "under R3 the CLI's environment should hold the token")
        for _pid, argv in holders:
            self.assertTrue(argv and argv[0].endswith("/claude"), f"unexpected holder {argv}")

    def test_r1_fd_route_delivers_bearer_and_no_environ_holds_it(self):
        seen = {}

        def scan(entry, index):
            seen.setdefault(index, processes_holding(self.token))
            return None

        with FakeAnthropicApi([{"text": "Scripted reply."}], responder=scan) as api:
            helper = self.run_turn(api, "R1")
        self.check_turn(api, helper)
        self.assertEqual(seen[0], [], "under R1 no process environment may hold the token")
        fifo_dir = self.homes.root / "token-fifo"
        self.assertEqual(stat.S_IMODE(fifo_dir.stat().st_mode), 0o300, "others could list the FIFO directory")
        os.chmod(fifo_dir, 0o700)
        self.assertEqual(sorted(os.listdir(fifo_dir)), [], "the token FIFO was not unlinked")


def echo_reply(helper, frame):
    helper.send({"v": 1, "seq": 1, "type": "tool_result", "session": frame["session"], "id": frame["id"],
                 "ok": True, "content": [{"type": "text", "text": "echo:" + frame["args"].get("text", "")}]})


ECHO_TURNS = [{"tool_use": {"name": "mcp__zigbrowser__echo", "input": {"text": "ping"}}}, {"text": "Done."}]


class P04HookEnvironment(ContractCase):
    """P0.4: the selected token route never reaches a hook's environment, and every hook runs."""

    def run_hooked_turn(self, route):
        notify = NotifyServer()
        self.addCleanup(notify.close)
        install_dump_hooks(self.homes, notify.port)
        rc, out = provision(self.homes)
        self.assertEqual(rc, 0, out)
        with FakeAnthropicApi(list(ECHO_TURNS)) as api:
            helper = self.run_turn(api, route, extra=("--mcp",), on_tool_call=echo_reply)
        self.assertTrue(any(f.get("type") == "tool_call" for f in helper.frames), helper.describe())
        return notify

    def dumps(self, kind):
        return sorted(p for p in self.homes.scratchpad.iterdir() if p.name.startswith(f"hook-{kind}-"))

    def check_hooks(self, notify):
        for ev in HOOK_EVENTS:
            self.assertEqual(len([p for p in self.dumps("env") if p.name.startswith(f"hook-env-{ev}-")]), 1,
                             f"{ev}: expected exactly one env dump, got {[p.name for p in self.dumps('env')]}")
            self.assertEqual(notify.events.count(ev), 1, f"{ev}: notify POSTs {notify.events}")
        for path in self.dumps("env") + self.dumps("procenv"):
            self.assertNotIn(self.token.encode(), path.read_bytes(), f"canary in {path.name}")
        for ev, entries in self.homes.read_settings()["hooks"].items():
            for entry in entries:
                for hook in entry["hooks"]:
                    self.assertTrue(hook["command"].startswith(str(self.homes.agent / "runtime" / "bin" / "zb-hook-run") + " -- "),
                                    f"{ev}: {hook['command']}")

    def test_r3_hooks_never_see_the_token(self):
        notify = self.run_hooked_turn("R3")
        self.check_hooks(notify)
        # Under R3 the hook also read every /proc/*/environ it could see, PID 1 included.
        for ev in HOOK_EVENTS:
            seen = [p.name for p in self.dumps("procenv") if p.name.startswith(f"hook-procenv-{ev}-")]
            self.assertTrue(any(name.endswith("-1") for name in seen), f"{ev}: PID 1's environ was not read: {seen}")

    def test_r1_hooks_never_see_the_token(self):
        self.check_hooks(self.run_hooked_turn("R1"))


CENSUS = Path(__file__).with_name("p0_census.json")
# Written by the CLI in a writable .claude, but kept read-only by design: the turn
# still succeeds, and the CLI's configuration can never change inside the sandbox.
READ_ONLY_BY_DESIGN = (".claude.json", "backups")


def children_of(pid):
    try:
        with open(f"/proc/{pid}/task/{pid}/children") as f:
            return [int(c) for c in f.read().split()]
    except OSError:
        return []


def descendants(root_pid):
    children = {}
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            with open(f"/proc/{entry}/stat") as f:
                ppid = int(f.read().rsplit(")", 1)[1].split()[1])
        except (OSError, ValueError, IndexError):
            continue
        children.setdefault(ppid, []).append(int(entry))
    out, stack = [], [root_pid]
    while stack:
        pid = stack.pop()
        for child in children.get(pid, []):
            out.append(child)
            stack.append(child)
    return out


def cmdline(pid):
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            return [c.decode("utf-8", "replace") for c in f.read().split(b"\0") if c]
    except OSError:
        return []


class P05Sandbox(ContractCase):
    """P0.5: the exact D12 sandbox and per-hook PID isolation work on this host."""

    def setUp(self):
        super().setUp()
        self.notify = NotifyServer()
        self.addCleanup(self.notify.close)
        install_dump_hooks(self.homes, self.notify.port)
        rc, out = provision(self.homes)
        self.assertEqual(rc, 0, out)
        self.planted = self.homes.scratchpad / "planted-mcp-ran"
        server = {"command": "/usr/bin/touch", "args": [str(self.planted)]}
        for path in (self.homes.agent / ".claude" / ".claude.json", self.homes.agent / ".claude.json"):
            path.write_text(json.dumps({"mcpServers": {"planted": server}}))
        self.samples = []

    def prefix(self, claude_writable=False):
        venv = os.path.dirname(os.path.dirname(host_python()))
        return sandbox.helper_argv(options.AgentHome(self.homes.agent), ro_paths=[venv, str(support.HOST_DIR)],
                                   claude_writable=claude_writable)

    def sandboxed_turn(self, route, claude_writable=False):
        def sample(_entry, _index):
            helper = self.helpers[-1]
            self.samples.append([(pid, cmdline(pid)) for pid in descendants(helper.proc.pid)])
            return None

        def reply(helper, frame):
            sample(None, None)
            echo_reply(helper, frame)

        with FakeAnthropicApi(list(ECHO_TURNS), responder=sample) as api:
            helper = self.run_turn(api, route, extra=("--mcp", "--probe-workspace", "--fifo-dir", sandbox.TOKEN_DIR),
                                   on_tool_call=reply,
                                   argv_prefix=self.prefix(claude_writable))
        self.assertTrue(api.messages_requests())
        for r in api.messages_requests():
            self.assertEqual(r["headers"].get("authorization"), f"Bearer {self.token}")
        self.assertEqual(api.tunnels, [])
        return helper

    def dumps(self, kind, ev=None):
        prefix = f"hook-{kind}-" + (f"{ev}-" if ev else "")
        return sorted(p for p in self.homes.scratchpad.iterdir() if p.name.startswith(prefix))

    def check_enforced(self, helper):
        probe = [f for f in helper.frames if f.get("type") == "probe"]
        self.assertEqual(probe and probe[0].get("workspace_create"), "EROFS", helper.describe())
        for ev in HOOK_EVENTS:
            self.assertEqual(len(self.dumps("env", ev)), 1, f"{ev} did not run")
            self.assertEqual(self.notify.events.count(ev), 1, f"{ev}: {self.notify.events}")
            for path in self.dumps("cmdlines", ev):
                seen = path.read_text()
                self.assertNotIn("zb_agent_host", seen, f"{ev}: the helper is visible from the hook")
                self.assertNotIn("_bundled/claude", seen, f"{ev}: the CLI is visible from the hook")
            for path in self.dumps("ws", ev):
                self.assertIn("Read-only file system", path.read_text(), f"{ev}: workspace write was not EROFS")
            for path in self.dumps("fds", ev):
                # Listed by ls, a fresh child of the hook: fd 3 is its own /proc/<pid>/fd handle.
                fds = [line for line in path.read_text().splitlines() if " -> " in line]
                extra = [line for line in fds
                         if int(line.split(" -> ")[0].split()[-1]) >= 3 and "/proc/" not in line.split(" -> ")[1]]
                self.assertTrue(fds, f"{ev}: no descriptor listing")
                self.assertEqual(extra, [], f"{ev}: descriptors >= 3 leaked into the hook")
        for path in self.homes.scratchpad.iterdir():
            if path.is_file():
                self.assertNotIn(self.token.encode(), path.read_bytes(), f"canary in {path.name}")
        self.assertFalse(list(self.homes.workspace.iterdir()), "something wrote the workspace")
        self.assertFalse(self.planted.exists(), "a planted mcpServers entry ran")
        cli = [argv for sample in self.samples for _pid, argv in sample if any(a.endswith("/claude") for a in argv[:2])]
        self.assertTrue(cli, "the CLI was never sampled")
        self.assertTrue(all("--strict-mcp-config" in argv for argv in cli), cli[:1])

    def non_hook_cli_children(self):
        """Executables of CLI descendants outside every hook namespace: the walk stops at bwrap."""
        found = set()
        for sample in self.samples:
            for root in [pid for pid, argv in sample if any(a.endswith("/claude") for a in argv[:2])]:
                stack = [root]
                while stack:
                    for child in children_of(stack.pop()):
                        argv = cmdline(child)
                        if argv and argv[0].endswith("bwrap"):
                            continue
                        try:
                            found.add(os.readlink(f"/proc/{child}/exe"))
                        except OSError:
                            pass
                        stack.append(child)
        return found

    def test_write_census_and_hook_env_census(self):
        # The census sees what the CLI hands a hook, so these hooks run unwrapped
        # (still inside the outer sandbox).
        settings = self.homes.read_settings()
        prefix = f"{self.homes.agent / 'runtime' / 'bin' / 'zb-hook-run'} -- "
        for entries in settings["hooks"].values():
            for entry in entries:
                for hook in entry["hooks"]:
                    hook["command"] = hook["command"].removeprefix(prefix)
        self.homes.write_settings(settings)
        watch = Inotify(self.homes.agent / ".claude")
        try:
            self.sandboxed_turn("R1", claude_writable=True)
        finally:
            written = watch.close()
        # The CLI's .claude.json writes come with .lock and .tmp.<pid>.<rand> siblings.
        tops = sorted({".claude.json" if p.startswith(".claude.json") else p.split(os.sep, 1)[0]
                       for p in written if p != "."})
        hook_env = sorted({line.split("=", 1)[0] for path in self.dumps("env")
                           for line in path.read_bytes().decode("utf-8", "replace").split("\0") if "=" in line})
        observed = {"cli_version": options.cli_version(), "writes": tops, "hook_env": hook_env}
        if os.environ.get("ZB_AGENT_RECORD_CENSUS") == "1":
            recorded = json.loads(CENSUS.read_text()) if CENSUS.exists() else {}
            recorded.update(observed)
            CENSUS.write_text(json.dumps(recorded, indent=2) + "\n")
        recorded = json.loads(CENSUS.read_text())
        self.assertEqual(recorded["cli_version"], observed["cli_version"], "the bundled CLI changed: re-run the census")
        for top in tops:
            self.assertIn(top, set(sandbox.STATE_DIRS) | set(READ_ONLY_BY_DESIGN), f"unreviewed write under .claude: {top}")
            self.assertIn(top, recorded["writes"])
        refused = set(hook_run.REFUSED)
        self.assertEqual(set(hook_env) - refused - set(provisioning.HOOK_ENV_NAMES), set(),
                         "the CLI gives hooks a variable that is neither allowed nor refused: review it")
        self.assertEqual(set(recorded["hook_env"]), set(hook_env))

    def test_r1_enforced_sandbox(self):
        self.check_enforced(self.sandboxed_turn("R1"))
        self.check_census_children()

    def test_r3_enforced_sandbox(self):
        self.check_enforced(self.sandboxed_turn("R3"))
        for ev in HOOK_EVENTS:
            procenv = self.dumps("procenv", ev)
            self.assertTrue(any(p.name.endswith("-1") for p in procenv), f"{ev}: PID 1 not read")

    def check_census_children(self):
        children = sorted(self.non_hook_cli_children())
        if os.environ.get("ZB_AGENT_RECORD_CENSUS") == "1":
            recorded = json.loads(CENSUS.read_text()) if CENSUS.exists() else {}
            recorded["cli_children"] = sorted(set(recorded.get("cli_children", [])) | set(children))
            CENSUS.write_text(json.dumps(recorded, indent=2) + "\n")
        recorded = json.loads(CENSUS.read_text())
        for exe in recorded["cli_children"]:
            self.assertTrue(exe.startswith("/usr/"), exe)
        self.assertLessEqual(set(children), set(recorded["cli_children"]), "an unrecorded CLI child ran")


def tool_results(request):
    """Every tool_result block in a /v1/messages request (user messages only)."""
    blocks = []
    for message in request["body"].get("messages", []):
        content = message.get("content")
        if message.get("role") == "user" and isinstance(content, list):
            blocks += [b for b in content if isinstance(b, dict) and b.get("type") == "tool_result"]
    return blocks


def result_text(block):
    content = block.get("content")
    if isinstance(content, str):
        return content
    return "".join(c.get("text", "") for c in content or [] if isinstance(c, dict))


class P03ToolRoundTrip(ContractCase):
    """P0.3: in-process MCP tools round-trip through the helper; built-in tools are absent."""

    def timed_turn(self, turns, extra=(), on_tool_call=None):
        stamps = {}

        def stamp(entry, index):
            stamps[index] = time.monotonic()
            return None

        def on_call(helper, frame):
            stamps["tool_call"] = time.monotonic()
            if on_tool_call:
                on_tool_call(helper, frame)

        with FakeAnthropicApi(turns, responder=stamp) as api:
            helper = self.run_turn(api, "R1", extra=("--mcp", *extra), on_tool_call=on_call)
        return api, helper, stamps

    def test_echo_answer_arrives_from_stdin_after_three_seconds(self):
        def late(helper, frame):
            threading.Timer(3.0, echo_reply, args=(helper, frame)).start()

        api, helper, stamps = self.timed_turn(list(ECHO_TURNS), on_tool_call=late)
        sent = api.messages_requests()
        self.assertEqual(len(sent), 2, helper.describe())
        results = tool_results(sent[1])
        self.assertEqual(len(results), 1, sent[1]["body"].get("messages", [])[-1:])
        self.assertFalse(results[0].get("is_error"), results[0])
        self.assertEqual(result_text(results[0]), "echo:ping")
        self.assertGreaterEqual(stamps[1] - stamps["tool_call"], 2.9)

    def test_builtin_read_is_absent_and_touches_no_file(self):
        secret = "ZB-WORKSPACE-SECRET-" + secrets.token_hex(8)
        target = self.homes.workspace / "notes.txt"
        target.write_text(secret)
        turns = [{"tool_use": {"name": "Read", "input": {"file_path": str(target)}}}, {"text": "Done."}]
        watch = Inotify(self.homes.workspace, extra_mask=Inotify.IN_OPEN | Inotify.IN_ACCESS)
        try:
            api, helper, _stamps = self.timed_turn(turns)
        finally:
            touched = watch.close()
        sent = api.messages_requests()
        self.assertEqual(len(sent), 2, helper.describe())
        results = tool_results(sent[1])
        self.assertEqual(len(results), 1)
        self.assertTrue(results[0].get("is_error"), results[0])
        for r in sent:
            self.assertNotIn(secret, json.dumps(r["body"]))
            self.assertNotIn('"name": "Read"', json.dumps(r["body"].get("tools", [])))
        self.assertEqual(touched - {"."}, set(), f"workspace files were touched: {touched}")

    def test_helper_answers_before_the_cli_tool_timeout(self):
        # MCP_TOOL_TIMEOUT 12 s for the CLI; the helper's own deadline is 10 s shorter.
        api, helper, stamps = self.timed_turn(list(ECHO_TURNS), extra=("--mcp-tool-timeout-ms", "12000"))
        sent = api.messages_requests()
        self.assertEqual(len(sent), 2, helper.describe())
        results = tool_results(sent[1])
        self.assertTrue(results and results[0].get("is_error"), results)
        self.assertIn("did not answer", result_text(results[0]))
        waited = stamps[1] - stamps["tool_call"]
        self.assertTrue(1.5 <= waited < 6, f"waited {waited:.1f} s")

    def test_cli_enforces_mcp_tool_timeout_on_in_process_tools(self):
        # Observed contract: with the helper silent past MCP_TOOL_TIMEOUT, the CLI
        # itself gives up at that timeout and reports an error result to the model.
        api, helper, stamps = self.timed_turn(list(ECHO_TURNS),
                                              extra=("--mcp-tool-timeout-ms", "4000", "--tool-deadline-ms", "60000"))
        sent = api.messages_requests()
        self.assertEqual(len(sent), 2, helper.describe())
        results = tool_results(sent[1])
        self.assertTrue(results and results[0].get("is_error"), results)
        waited = stamps[1] - stamps["tool_call"]
        self.assertTrue(3.5 <= waited < 15, f"the CLI waited {waited:.1f} s for a 4 s MCP_TOOL_TIMEOUT")


if __name__ == "__main__":
    unittest.main()
