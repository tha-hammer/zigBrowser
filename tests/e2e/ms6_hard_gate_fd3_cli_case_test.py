"""The MS6.3 hard-gate case (tests/mac/hard_gate/case_ms6_3_fd3_cli.py), on Linux with fakes only: the real pinned CLI
must consume the exact token from the production fd-3 channel under the generated CLI profile (plan MS6.3; BlueBeaver
7514, 7523; the orchestrator's calls on 7514: (a) the token is asserted absent from the CLI's environment, (b) the home
is pre-created and other writes fail visibly, (c) the case is self-contained). run(h), against a FAKE staged
zb_agent_host written into a temp prefix:
- the run is the production chain: /bin/sh places the token's socketpair end on fd 3 (and closes the original), then
  the backend's own sandbox-exec prefix (MacSeatbeltBackend(<the fake server's port>).launch(home)), then the staged
  python -m zb_agent_host contract-config with --home, --base-url (the fake server), --fifo-dir under the home's
  scratchpad and a prompt; PYTHONPATH is the staged prefix; pass_fds is exactly that one end; the zb-claude wrapper
  is written for h.cli first; the no-channel row runs the same command with no fd 3 and no pass_fds;
- an honest host passes every row (positive, decoy, no channel), each with its release checks;
- while the request is served, production's census (proc_darwin.cli_env_clean) runs once per calling row with the
  exact request: the CLI path, this process as the root, that row's token and its server's ANTHROPIC_BASE_URL; a
  dirty census fails the row; the no-channel row makes no request and so no census;
- each row's home is exactly setup.stage's layout (.claude, workspace, scratchpad/tmp, runtime/bin with the
  wrapper, state) and nothing more;
- the case is self-contained: it reads no other case file;
- the fd-3 endpoint is an AF_UNIX SOCK_STREAM socket (a socketpair end), never a pipe or a file (RoseCat 7537 #1);
- the token has exactly one route (RoseCat 7537 #3): neither token appears in the run's argv, in its environment, or
  in any file under the case's scratch at spawn time, and the outer environment is exactly the fixed allowlist
  (PATH, PYTHONPATH = the staged prefix, PYTHONDONTWRITEBYTECODE); the census still proves the real CLI's own env;
- the bearer follows fd 3: a host whose CLI sends a cached credential, whatever fd 3 holds, fails the decoy and
  no-channel rows; a CLI that never calls fails the positive row;
- a CLI still running after a row fails that row's release (never signalled);
- NO check label carries either token, even when the host echoes both into its output and fails.
No signal is sent: h.spawn_group is a fake, and os.kill / os.killpg are patched to raise. The only processes started
are FdPlacement's: a fresh python that first closes every fd above 2 (so fds 3 and 9 are free by construction, never
by the runner's layout; RoseCat 7537 #2), places a socketpair end itself and runs the real /bin/sh placement; all exit
by themselves.
Run like the gate: cd tests/e2e && unshare --user --map-root-user --pid --fork --mount-proc \\
  sh -c 'setsid python3 -X dev -m unittest -v ms6_hard_gate_fd3_cli_case_test'
Unregistered until the green.
"""
import importlib
import importlib.util
import os
import shutil
import sys
import tempfile
import json
import socket
import stat
import subprocess
import textwrap
import unittest
from unittest import mock

HARD_GATE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "mac", "hard_gate")
CASE = os.path.join(HARD_GATE, "case_ms6_3_fd3_cli.py")
CANARY = "sk-ant-oat01-ZBCANARY" + "q7x2" * 10
DECOY = "sk-ant-oat01-ZBDECOY" + "m3k9" * 10


def load_case():
    spec = importlib.util.spec_from_file_location("zb_hg_case_fd3_cli", CASE)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


FAKE_FILES = {
    "__init__.py": "",
    "options.py": """
        from pathlib import Path
        class AgentHome:
            def __init__(self, root):
                self.root = Path(root)
            claude_dir = property(lambda s: s.root / ".claude")
            workspace = property(lambda s: s.root / "workspace")
            scratchpad = property(lambda s: s.root / "scratchpad")
            runtime = property(lambda s: s.root / "runtime")
            state = property(lambda s: s.root / "state")
            tmp = property(lambda s: s.root / "scratchpad" / "tmp")
        """,
    "route_probe.py": """
        import socket, types
        SERVERS = []
        class _Handler:  # what the real one does with the first /v1/messages: record its bearer
            path = "/v1/messages"
            def __init__(self, server, authorization):
                self.server_obj, self.authorization = server, authorization
            def do_POST(self):
                if self.server_obj.bearer is None:
                    self.server_obj.bearer = self.authorization
        class _ProbeServer:
            def __init__(self, probe_token, cli, listener=None, census=None):
                assert listener is None and census is None, "the case serves on its own loopback port, no census"
                self.bearer = None
                self.cli_env_clean = None
                self.sock = socket.socket()
                self.sock.bind(("127.0.0.1", 0))
                self.sock.listen(1)
                self.port = self.sock.getsockname()[1]
                self.url = "http://127.0.0.1:%d" % self.port
                self.httpd = types.SimpleNamespace(RequestHandlerClass=_Handler)
                self.closed = False
                SERVERS.append(self)
            def close(self):
                self.sock.close()
                self.closed = True
        """,
    "sandbox_macos.py": """
        import contextlib, types
        PORTS = []
        class MacSeatbeltBackend:
            def __init__(self, egress_port):
                PORTS.append(egress_port)
            @contextlib.contextmanager
            def launch(self, home):
                yield types.SimpleNamespace(argv=("/usr/bin/sandbox-exec", "-f", "/prof/cli.sb", "-D",
                                                  "SCRATCHPAD=%s" % home.scratchpad))
        """,
    "token.py": """
        WRAPPERS = []
        def write_wrapper(path, cli, python="/usr/bin/python3"):
            WRAPPERS.append((str(path), cli))
            with open(path, "w") as f:
                f.write("#!%s -I\\n# %s\\n" % (python, cli))
        """,
    "proc_darwin.py": """
        ALIVE = {}
        CENSUS = []
        CLEAN = {"v": True}
        def cli_env_clean(exe, root, token, canary):
            CENSUS.append((exe, root, token, canary))
            return CLEAN["v"]
        def path(pid):
            return ALIVE.get(pid)
        def environ_of(pid):
            return b"raw", [b"node"], []
        """,
}


class FakeStagedHost(unittest.TestCase):
    def setUp(self):
        for name in ("kill", "killpg"):
            p = mock.patch.object(os, name, side_effect=AssertionError(f"os.{name} reached in a fakes-only test"))
            p.start()
            self.addCleanup(p.stop)
        self.case = load_case()
        self.tmp = tempfile.mkdtemp(prefix="zb-hg-fd3-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.prefix = os.path.join(self.tmp, "agent-host")
        pkg = os.path.join(self.prefix, "zb_agent_host")
        os.makedirs(pkg)
        for name, text in FAKE_FILES.items():
            with open(os.path.join(pkg, name), "w") as f:
                f.write(textwrap.dedent(text))
        self.scratch = os.path.join(self.tmp, "scratch")
        os.mkdir(self.scratch)
        self.cli = os.path.join(self.tmp, "staged", "claude")
        self.addCleanup(self.forget)
        self.forget()
        self.mode = "honest"
        self.runs = []
        self.ps_rows = b""

    def forget(self):
        for name in [m for m in sys.modules if m == "zb_agent_host" or m.startswith("zb_agent_host.")]:
            del sys.modules[name]
        while self.prefix in sys.path:
            sys.path.remove(self.prefix)

    def staged(self, name):
        if self.prefix not in sys.path:
            sys.path.insert(0, self.prefix)
        return importlib.import_module(f"zb_agent_host.{name}")

    def harness(self):
        test = self

        class H:
            scratch, prefix, python, cli = test.scratch, test.prefix, sys.executable, test.cli
            checks = []

            def check(self, ok, label):
                self.checks.append((bool(ok), label))
                return bool(ok)

            def spawn_group(self, argv, env=None, pass_fds=(), timeout=30):
                if argv == ["/bin/ps", "-axo", "pid=,uid=,stat="]:
                    return 0, test.ps_rows, b""
                return test.fake_run(list(argv), env, tuple(pass_fds))

        h = H()
        h.checks = []
        return h

    def fake_run(self, argv, env, pass_fds):
        """The staged chain as the mode says: an honest CLI sends Bearer <what fd 3 held>."""
        tok, endpoint = None, None
        if pass_fds:
            st = os.fstat(pass_fds[0])
            endpoint = ("file", stat.S_IFMT(st.st_mode))
            if stat.S_ISSOCK(st.st_mode):
                dup = socket.socket(fileno=os.dup(pass_fds[0]))
                try:
                    endpoint = (dup.family, dup.type)
                finally:
                    dup.close()
            chunks = []
            while True:
                b = os.read(pass_fds[0], 4096)
                if not b:
                    break
                chunks.append(b)
            tok = b"".join(chunks).decode()
        self.runs.append({"argv": argv, "env": env, "pass_fds": pass_fds, "token": tok, "endpoint": endpoint,
                          "routes": self.token_routes(argv, env)})
        server = self.staged("route_probe").SERVERS[-1]
        sent = None
        if self.mode == "honest" and tok is not None:
            sent = "Bearer " + tok
        elif self.mode == "cached":
            sent = "Bearer " + CANARY
        if sent is not None:  # the CLI's request, through whatever handler the case left on the server
            server.httpd.RequestHandlerClass(server, sent).do_POST()
        if self.mode == "leaky":
            return 1, f"Bearer {CANARY} {DECOY}\n".encode(), f"token={CANARY}\n{DECOY}\n".encode()
        if server.bearer is None:
            return 1, b"", b"Traceback ...\nOSError: [Errno 9] Bad file descriptor\n"
        return 0, b'{"type": "result", "session": "contract", "subtype": "success", "is_error": false}\n', b""

    def token_routes(self, argv, env):
        """Where else either token sits at spawn time: argv, the environment, any file under the case's scratch."""
        found = []
        for tok in (CANARY, DECOY):
            if any(tok in a for a in argv):
                found.append(("argv", tok[-4:]))
            if any(tok in k or tok in v for k, v in (env or {}).items()):
                found.append(("env", tok[-4:]))
            for top, _dirs, files in os.walk(self.scratch):
                for name in files:
                    path = os.path.join(top, name)
                    if os.path.islink(path) or not os.path.isfile(path):
                        continue
                    with open(path, "rb") as f:
                        if tok.encode() in f.read():
                            found.append(("file", os.path.relpath(path, self.scratch)))
        return found

    def run_case(self):
        h = self.harness()
        self.case.run(h)
        return h

    def failed(self, h):
        return [label for ok, label in h.checks if not ok]

    def test_an_honest_host_passes_every_row(self):
        h = self.run_case()
        self.assertEqual(self.failed(h), [])
        for row in ("positive", "decoy", "no channel"):
            with self.subTest(row=row):
                self.assertTrue(any(l.startswith(f"{row}: ") for _, l in h.checks), row)
                self.assertTrue(any(l.startswith(f"{row}: afterwards port") for _, l in h.checks), row)
                self.assertTrue(any(l.startswith(f"{row}: no process of ours runs the CLI") for _, l in h.checks),
                                row)

    def test_the_run_is_the_production_fd3_chain(self):
        h = self.run_case()
        servers = self.staged("route_probe").SERVERS
        ports = self.staged("sandbox_macos").PORTS
        wrappers = self.staged("token").WRAPPERS
        self.assertEqual(len(self.runs), 3)
        self.assertEqual(len(servers), 3)
        self.assertTrue(all(s.closed for s in servers), "every fake server is closed after its row")
        self.assertEqual(ports, [s.port for s in servers], "each run's profile allows exactly its server's port")
        for i, (run, server) in enumerate(zip(self.runs, servers)):
            with self.subTest(run=i):
                argv = run["argv"]
                home = argv[argv.index("--home") + 1]
                channel = i < 2
                self.assertEqual(len(run["pass_fds"]), 1 if channel else 0, run["pass_fds"])
                head = ["/bin/sh", "-c", self.case.PLACE_FD3, "sh", str(run["pass_fds"][0])] if channel else []
                self.assertEqual(argv, head + [
                    "/usr/bin/sandbox-exec", "-f", "/prof/cli.sb", "-D", f"SCRATCHPAD={home}/scratchpad",
                    sys.executable, "-m", "zb_agent_host", "contract-config", "--home", home,
                    "--base-url", server.url, "--fifo-dir", f"{home}/scratchpad/token-fifo",
                    "--prompt", self.case.PROMPT])
                self.assertEqual(run["env"], {"PATH": "/usr/bin:/bin", "PYTHONPATH": self.prefix,
                                              "PYTHONDONTWRITEBYTECODE": "1"})
                self.assertEqual(run["endpoint"], (socket.AF_UNIX, socket.SOCK_STREAM) if channel else None)
                self.assertEqual(run["routes"], [], "the token has a route besides fd 3")
                self.assertTrue(home.startswith(self.scratch + os.sep), home)
                self.assertIn((f"{home}/runtime/bin/zb-claude", self.cli), wrappers)
        self.assertEqual([r["token"] for r in self.runs], [CANARY, DECOY, None])


    def test_the_census_runs_once_per_calling_row_with_the_exact_request(self):
        self.run_case()
        servers = self.staged("route_probe").SERVERS
        cli = os.path.realpath(self.cli)
        self.assertEqual(self.staged("proc_darwin").CENSUS, [
            (cli, os.getpid(), CANARY.encode(), b"ANTHROPIC_BASE_URL=" + servers[0].url.encode()),
            (cli, os.getpid(), DECOY.encode(), b"ANTHROPIC_BASE_URL=" + servers[1].url.encode())])

    def test_a_dirty_census_fails_the_calling_rows(self):
        self.staged("proc_darwin").CLEAN["v"] = False
        failed = self.failed(self.run_case())
        for row in ("positive", "decoy"):
            self.assertTrue(any(l.startswith(f"{row}: during the request the CLI's environment") for l in failed),
                            (row, failed))
        self.assertFalse(any(l.startswith("no channel: ") for l in failed), failed)

    def test_each_home_is_laid_out_as_setup_stage_does(self):
        self.run_case()
        homes = sorted(d for d in os.listdir(self.scratch) if d.startswith("home-"))
        self.assertEqual(homes, ["home-decoy", "home-no-channel", "home-positive"])
        for d in homes:
            with self.subTest(home=d):
                root = os.path.join(self.scratch, d)
                self.assertEqual(sorted(os.listdir(root)), [".claude", "runtime", "scratchpad", "state", "workspace"])
                self.assertEqual(os.listdir(os.path.join(root, "scratchpad")), ["tmp"])
                self.assertEqual(os.listdir(os.path.join(root, "runtime", "bin")), ["zb-claude"])

    def test_the_case_is_self_contained(self):
        with open(CASE) as f:
            text = f.read()
        self.assertNotIn("case_ms6_6b_r1_chain", text)
        self.assertNotIn("spec_from_file_location", text)

    def test_a_cached_credential_fails_the_decoy_and_no_channel_rows(self):
        self.mode = "cached"
        failed = self.failed(self.run_case())
        self.assertTrue(any(l.startswith("decoy: ") for l in failed), failed)
        self.assertTrue(any(l.startswith("no channel: ") for l in failed), failed)
        self.assertFalse(any(l.startswith("positive: ") for l in failed), failed)

    def test_a_cli_that_never_calls_fails_the_positive_row(self):
        self.mode = "silent"
        failed = self.failed(self.run_case())
        self.assertTrue(any(l.startswith("positive: ") for l in failed), failed)

    def test_a_cli_still_running_fails_the_release_unsignalled(self):
        me = os.getuid()
        self.ps_rows = f"4242 {me} S\n".encode()
        with mock.patch.object(self.case, "CHAIN_GRACE_S", 0), mock.patch.object(self.case, "CHAIN_HORIZON_S", 0), \
                mock.patch.object(self.case.time, "sleep"):
            h = self.harness()
            self.staged("proc_darwin").ALIVE[4242] = os.path.realpath(self.cli)
            self.case.run(h)
        failed = self.failed(h)
        self.assertTrue(any(l.startswith("positive: no process of ours runs the CLI") for l in failed), failed)

    def test_no_label_carries_either_token(self):
        for mode in ("honest", "cached", "leaky"):
            with self.subTest(mode=mode):
                self.forget()
                self.mode, self.runs = mode, []
                self.scratch = tempfile.mkdtemp(dir=self.tmp, prefix="scratch-")
                h = self.run_case()
                self.assertTrue(h.checks)
                for tok in (CANARY, DECOY):
                    tail = tok.split("-", 3)[-1]
                    windows = {tail[i:i + 8] for i in range(len(tail) - 7)}
                    for _ok, label in h.checks:
                        self.assertNotIn("sk-ant-", label)
                        self.assertEqual([w for w in windows if w in label], [], label[:300])


PLACEMENT_ORACLE = r"""
import json, os, socket, subprocess, sys
place, at = sys.argv[1], int(sys.argv[2])
os.closerange(3, 1024)  # a deterministic fd table: only 0-2 are open, whatever the runner had
a, b = socket.socketpair()
a.sendall(b"tok-xyz")
a.close()
if b.fileno() == at:
    fd = b.detach()
else:
    fd = os.dup2(b.fileno(), at)
    b.close()
probe = 'for n in 3 9; do if true <&$n 2>/dev/null; then echo "$n open"; else echo "$n closed"; fi; done; cat <&3'
p = subprocess.run(["/bin/sh", "-c", place, "sh", str(fd), "/bin/sh", "-c", probe], pass_fds=(fd,),
                   capture_output=True, text=True, timeout=30)
os.close(fd)
print(json.dumps([fd, p.returncode, p.stdout]))
"""


class FdPlacement(unittest.TestCase):
    """PLACE_FD3 under the real /bin/sh, run by a fresh python that controls its own fd table (RoseCat 7537 #2: no
    skip on ambient fds): the token end lands on fd 3 and its original number is closed; an end that already is fd 3
    stays open (an unguarded `exec 3<&3 3<&-` would close it)."""

    def place(self, at):
        p = subprocess.run([sys.executable, "-I", "-c", PLACEMENT_ORACLE, load_case().PLACE_FD3, str(at)],
                           capture_output=True, text=True, timeout=60)
        self.assertEqual(p.returncode, 0, p.stderr)
        fd, rc, out = json.loads(p.stdout)
        self.assertEqual(fd, at, "the oracle placed the end on the requested fd")
        return rc, out

    def test_another_fd_is_moved_to_3_and_closed(self):
        self.assertEqual(self.place(9), (0, "3 open\n9 closed\ntok-xyz"))

    def test_an_end_already_on_3_stays_open(self):
        self.assertEqual(self.place(3), (0, "3 open\n9 closed\ntok-xyz"))


if __name__ == "__main__":
    unittest.main()
