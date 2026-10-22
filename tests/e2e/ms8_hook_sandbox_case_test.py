"""The zb-hook-run Darwin hard-gate case (tests/mac/hard_gate/case_ms8_hook_sandbox.py), on Linux with fakes
only: the repo's zb_agent_host is the fake staged prefix (its setup.PLATFORM set to "darwin", so the real provision
writes runtime/hook.sb with the fixed bridges 51091/31337), and h.spawn_group is a fake that plays the sandboxed hook
instead of running sandbox-exec (Linux has none). The case listens on the real bridge ports, so this runs in a network
namespace of its own (its loopback up), never against the host's 51091/31337:
- the case builds exactly the launcher -> zb-hook-run -> hook argv, with ZB_AGENT_RUN_MARKER_FD=5 and the planted
  names in the environment, and the marker it hands over is a 0400 regular file;
- an honest hook (both bridges reached with the nonce, the API port and the public address refused, the allowlisted
  environment only, the marker on fd 5 and no stray descriptor, a detached grandchild in its own session holding the
  marker, exit 0, a clean census) passes every check;
- each dishonest hook fails the case: a bridge refused, the API port reached, a planted name leaked into the
  environment, the marker missing, the grandchild missing, a survivor in the census, a failed ps, a non-zero exit;
  and (RoseCat 7969) a grandchild still in the hook's original session (no setsid), the API port or the public
  address failing with a timeout / ENETUNREACH instead of Seatbelt's EPERM, ZB_AGENT_RUN_MARKER_FD in the hook's
  environment, and a hook-env allowlist widened to ZB_AGENT_RUN_MARKER_FD (the planted/marker absence is an invariant
  of its own, not derived from the allowlist);
- the launcher keeps fd 5 inheritable even when its own open of the marker returns 5 (fds 3 and 4 taken): run for real
  under /bin/sh with 3 and 4 open, its exec'd checker sees fd 5 as the marker (RoseCat 7969 #2);
- a listener that fails to bind after others were made leaves none of them open (RoseCat 7969 #5).
No signal is sent (os.kill / os.killpg raise). The only processes started are the launcher row's /bin/sh and python,
which exit by themselves; the fake hook's connections go to the case's own listeners on the namespace's loopback.
Run under the pinned agent-host python (setup imports the SDK):
  cd tests/e2e && unshare --map-current-user --keep-caps --net --pid --fork --kill-child --mount-proc \\
    sh -c 'ip link set lo up && "$ZB_AGENT_HOST_PYTHON" -X dev -m unittest -v ms8_hook_sandbox_case_test; exit $?'
Registered (build.zig: test-mac-census and the Linux test step), each run in its own network
namespace."""
import contextlib
import importlib.util
import io
import json
import os
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[2]
CASE = REPO / "tests" / "mac" / "hard_gate" / "case_ms8_hook_sandbox.py"
VARIANTS = ("bridge refused", "api reached", "env leaked", "marker missing", "grandchild missing", "survivor",
            "ps fails", "exit nonzero", "no setsid", "api timeout", "public unreachable", "marker env leak",
            "allowlist widened")


class FakeHarness:
    def __init__(self, scratch, prefix, mode):
        self.scratch, self.prefix, self.python, self.cli = scratch, prefix, sys.executable, None
        self.mode, self.checks, self.failures, self.runs, self.nonce = mode, 0, [], [], None

    def check(self, ok, label):
        self.checks += 1
        if not ok:
            self.failures.append(label)
        return bool(ok)

    def spawn_group(self, argv, env=None, pass_fds=(), timeout=30):
        self.runs.append((list(argv), dict(env or {})))
        if argv[0] == "/bin/ps":
            if self.mode == "ps fails":
                return 1, b"", b"ps: failed"
            lines = "    1 /sbin/launchd\n"
            if self.mode == "survivor":
                lines += f"  777 python3 hook.py {self.nonce}\n"
            return 0, lines.encode(), b""
        return self.hook(argv, env or {})

    def hook(self, argv, env):
        hook_args = argv[argv.index("--") + 1:]
        _py, _i, _s, _hook, scratchpad, b1, b2, api, nonce, _stray = hook_args
        self.nonce = nonce
        runtime = Path(argv[argv.index("--") - 1]).parent.parent
        allowed = json.loads((runtime / "hook-env.json").read_text())

        def reach(port, honest_ok):
            if not honest_ok:
                return "err:61"
            with socket.create_connection(("127.0.0.1", int(port)), timeout=5) as s:
                s.sendall(nonce.encode())
            return "ok"
        report = {
            "bridge1": reach(b1, True),
            "bridge2": reach(b2, self.mode != "bridge refused"),
            "api": reach(api, True) if self.mode == "api reached" else ("err:60" if self.mode == "api timeout"
                                                                         else "err:1"),
            "public": "err:51" if self.mode == "public unreachable" else "err:1",
            "env": {k: v for k, v in env.items() if k in allowed},
            "fd5": "closed" if self.mode == "marker missing" else "reg",
            "stray": "closed",
            "sid": 100,
        }
        if self.mode == "env leaked":
            report["env"]["CLAUDE_CODE_OAUTH_TOKEN"] = env["CLAUDE_CODE_OAUTH_TOKEN"]
        if self.mode == "marker env leak":
            report["env"]["ZB_AGENT_RUN_MARKER_FD"] = env["ZB_AGENT_RUN_MARKER_FD"]
        Path(scratchpad, f"hook-{nonce}.json").write_text(json.dumps(report))
        detached = {"fd5": "reg", "sid": 100 if self.mode == "no setsid" else 200,
                    "pgid": 100 if self.mode == "no setsid" else 200}
        if self.mode != "grandchild missing":
            Path(scratchpad, f"grandchild-{nonce}.json").write_text(json.dumps(detached))
        return (1 if self.mode == "exit nonzero" else 0), b"", b""

    def close(self):
        pass


class Ms8HookCase(unittest.TestCase):
    def setUp(self):
        for name in ("kill", "killpg"):
            p = mock.patch.object(os, name, side_effect=AssertionError(f"os.{name} reached"))
            p.start()
            self.addCleanup(p.stop)
        self.tmp = Path(os.path.realpath(tempfile.mkdtemp(prefix="zb-ms8-case-")))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.prefix = self.tmp / "prefix"
        shutil.copytree(REPO / "agent" / "host" / "zb_agent_host", self.prefix / "zb_agent_host",
                        ignore=shutil.ignore_patterns("__pycache__"))
        setup_py = self.prefix / "zb_agent_host" / "setup.py"
        text = setup_py.read_text()
        for old, new in (("PLATFORM = sys.platform\n", 'PLATFORM = "darwin"\n'),):
            self.assertEqual(text.count(old), 1, old)
            text = text.replace(old, new)
        setup_py.write_text(text)
        self.addCleanup(self.forget_staged)

    def forget_staged(self):
        for name in [n for n in sys.modules if n == "zb_agent_host" or n.startswith("zb_agent_host.")]:
            del sys.modules[name]
        while str(self.prefix) in sys.path:
            sys.path.remove(str(self.prefix))

    def run_case(self, mode):
        self.forget_staged()
        provision_py = self.prefix / "zb_agent_host" / "provision.py"
        names = provision_py.read_text()
        if mode == "allowlist widened":  # what an accidental widening would look like; setup does not refuse it
            widened = names.replace("HOOK_ENV_NAMES = (", 'HOOK_ENV_NAMES = ("ZB_AGENT_RUN_MARKER_FD", ', 1)
            self.assertNotEqual(widened, names)
            provision_py.write_text(widened)
            self.addCleanup(provision_py.write_text, names)
        spec = importlib.util.spec_from_file_location("zb_hg_case_ms8", CASE)
        case = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(case)
        scratch = tempfile.mkdtemp(dir=self.tmp, prefix="scratch-")
        h = FakeHarness(scratch, str(self.prefix), mode)
        with mock.patch.object(case, "HORIZON_S", 2.0), contextlib.redirect_stderr(io.StringIO()):
            case.run(h)
        return case, h

    def test_an_honest_hook_passes_every_check(self):
        case, h = self.run_case("honest")
        self.assertEqual(h.failures, [])
        self.assertGreaterEqual(h.checks, 10)
        argv, env = next(r for r in h.runs if r[0][0] != "/bin/ps")
        self.assertEqual(argv[:5], [sys.executable, "-I", "-S", "-c", case.LAUNCH])
        marker, stray = argv[5], argv[6]
        self.assertEqual(stat.S_IMODE(os.lstat(marker).st_mode), 0o400)
        self.assertTrue(stat.S_ISREG(os.lstat(marker).st_mode) and os.path.isfile(stray))
        zb_hook_run = argv[9]
        self.assertEqual(argv[7:11], [sys.executable, "-I", zb_hook_run, "--"])
        self.assertTrue(zb_hook_run.endswith("/runtime/bin/zb-hook-run") and os.path.isfile(zb_hook_run))
        self.assertEqual(argv[-1], "{STRAY}")
        self.assertEqual(env["ZB_AGENT_RUN_MARKER_FD"], "5")
        for name, value in case.PLANTED.items():
            self.assertEqual(env.get(name), value)

    def test_the_launcher_keeps_fd_5_inheritable_when_its_open_returns_5(self):
        _case, _h = self.run_case("honest")
        case = _case
        marker = self.tmp / "m.marker"
        marker.write_text("")
        os.chmod(marker, 0o400)
        stray = self.tmp / "stray"
        stray.write_text("x")
        checker = ("import os, stat, sys; st = os.fstat(5); "
                   "sys.stdout.write('reg' if stat.S_ISREG(st.st_mode) else 'other')")
        for label, opens in (("open returns 5", "exec 3</dev/null 4</dev/null; "), ("open returns 3", "")):
            with self.subTest(case=label):
                done = subprocess.run(["/bin/sh", "-c", opens + 'exec "$@"', "sh", sys.executable, "-I", "-S", "-c",
                                       case.LAUNCH, str(marker), str(stray), sys.executable, "-I", "-S", "-c",
                                       checker], capture_output=True, text=True, timeout=30)
                self.assertEqual((done.returncode, done.stdout), (0, "reg"), done.stderr[-300:])

    def test_a_listener_that_fails_after_others_leaves_none_open(self):
        self.forget_staged()
        spec = importlib.util.spec_from_file_location("zb_hg_case_ms8_l", CASE)
        case = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(case)
        made, real = [], case._Listener

        def listener(port):
            if len(made) == 2:
                raise OSError(98, "Address already in use")
            made.append(real(port))
            return made[-1]
        scratch = tempfile.mkdtemp(dir=self.tmp, prefix="scratch-")
        h = FakeHarness(scratch, str(self.prefix), "honest")
        with mock.patch.object(case, "_Listener", side_effect=listener), contextlib.redirect_stderr(io.StringIO()):
            case.run(h)
        self.assertEqual(len(made), 2)
        self.assertNotEqual(h.failures, [], "the bind failure was not a FAIL")
        self.assertEqual([m.sock.fileno() for m in made], [-1, -1], "a listener made before the failure is open")

    def test_each_dishonest_hook_fails_the_case(self):
        for mode in VARIANTS:
            with self.subTest(mode=mode):
                _case, h = self.run_case(mode)
                self.assertNotEqual(h.failures, [], f"{mode} passed the case")


if __name__ == "__main__":
    unittest.main()
