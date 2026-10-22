"""The zb-hook-run Darwin hard-gate case's launch-environment row (RoseCat 7986 on the failed 2e07c7b run, 7985): on
both Macs the stand-in Python hook's os.environ held names the hook's own interpreter adds at startup
(__CF_USER_TEXT_ENCODING from CoreFoundation, LC_CTYPE from PEP 538 locale coercion), so that dictionary is not the
environment zb-hook-run exec'd. The case therefore runs zb-hook-run a second time with a non-Python reporter as the
hook, /usr/bin/env (no arguments: one NAME=VALUE line per entry, over values this case controls), and requires its
output to be exactly the hook-env.json allowlist's names AND values, and, independently, to hold no planted name or
value and no ZB_AGENT_RUN_MARKER_FD. The Python hook row keeps its sandbox/network/fd/session checks and its own
planted-absence check, but is no longer the exact-environment proof.
On Linux, with the staged copy of the repo's zb_agent_host (setup.PLATFORM and hook_run.PLATFORM set to "darwin"):
- the reporter row is REAL: the case's launcher -> the provisioned runtime/bin/zb-hook-run (the production Darwin
  branch: its allowlisted env and execve) -> a stand-in sandbox-exec that checks its `-f <profile> -D SCRATCHPAD=<dir>`
  prefix and execs the command with its exec-time environment (read from /proc/self/environ, so the stand-in itself
  adds nothing) -> the real /usr/bin/env;
- an honest launch passes every check, and the reporter row ran through that chain with the bare reporter argv;
- a Python hook whose interpreter added __CF_USER_TEXT_ENCODING and LC_CTYPE (what both Macs showed) passes;
- each launch-boundary mutant of the staged zb-hook-run fails the reporter row: one OS-style name added, the
  allowlist filter dropped, an allowlisted value changed; and a widened allowlist fails its absence check;
- a malformed reporter output (a line without "=", a duplicate name, no final newline, non-UTF-8, rc != 0) fails it.
No signal is sent (os.kill / os.killpg raise). The only processes started are the reporter row's launcher, zb-hook-run,
stand-in and env, which exit by themselves. The case listens on the real bridge ports, so this runs in a network
namespace of its own (its loopback up), as ms8_hook_sandbox_case_test does:
  cd tests/e2e && unshare --map-current-user --keep-caps --net --pid --fork --kill-child --mount-proc \\
    sh -c 'ip link set lo up && "$ZB_AGENT_HOST_PYTHON" -X dev -m unittest -v ms8_hook_launch_env_case_test; exit $?'
Unregistered until the green."""
import json
import os
import subprocess
import sys
import unittest
from pathlib import Path

import ms8_hook_sandbox_case_test as base

REPORTER = "/usr/bin/env"
LAUNCH_LABEL = "launch environment"
STUB = """#!{python} -IS
import os, sys
a = sys.argv[1:]
if len(a) < 5 or a[0] != "-f" or not os.path.isfile(a[1]) or a[2] != "-D" or not a[3].startswith("SCRATCHPAD="):
    sys.stderr.write("stand-in sandbox-exec: unexpected argv %r\\n" % (a,))
    sys.exit(3)
with open("/proc/self/environ", "rb") as f:
    env = dict(e.split(b"=", 1) for e in f.read().split(b"\\0") if e)
os.execve(a[4], a[4:], env)
"""
EXEC_ENV = "    env = {name: os.environ[name] for name in names if name in os.environ}\n    top = os.sysconf"
MUTANTS = {
    "an OS-style name added": EXEC_ENV.replace("\n    top", '\n    env["__CF_USER_TEXT_ENCODING"] = "0x1F5:0x0:0x0"'
                                                      "\n    top"),
    "the allowlist filter dropped": EXEC_ENV.replace("{name: os.environ[name] for name in names if name in os.environ}",
                                                     "dict(os.environ)"),
    "an allowlisted value changed": EXEC_ENV.replace("\n    top", '\n    env["LANG"] = "en_US.UTF-8"\n    top'),
}


class LaunchHarness(base.FakeHarness):
    """The ms8 fake harness, but the reporter row really runs; every check label is kept."""

    def __init__(self, scratch, prefix, mode, reporter_out=None):
        super().__init__(scratch, prefix, mode)
        self.labels, self.reporter_runs, self.reporter_out = [], [], reporter_out

    def check(self, ok, label):
        self.labels.append(label)
        return super().check(ok, label)

    def spawn_group(self, argv, env=None, pass_fds=(), timeout=30):
        if "--" in argv and argv[argv.index("--") + 1:] == [REPORTER]:
            self.runs.append((list(argv), dict(env or {})))
            if self.reporter_out is not None:
                self.reporter_runs.append(None)
                return self.reporter_out
            done = subprocess.run(argv, env=env, capture_output=True, timeout=timeout)
            self.reporter_runs.append(done)
            return done.returncode, done.stdout, done.stderr
        return super().spawn_group(argv, env, pass_fds, timeout)

    def hook(self, argv, env):
        result = super().hook(argv, env)
        if self.mode == "interpreter names":
            hook_args = argv[argv.index("--") + 1:]
            path = Path(hook_args[4], f"hook-{hook_args[8]}.json")
            report = json.loads(path.read_text())
            report["env"].update({"__CF_USER_TEXT_ENCODING": "0x1F5:0x0:0x0", "LC_CTYPE": "UTF-8"})
            path.write_text(json.dumps(report))
        return result


class Ms8LaunchEnv(base.Ms8HookCase):
    # ms8_hook_sandbox_case_test runs these itself
    test_an_honest_hook_passes_every_check = None
    test_the_launcher_keeps_fd_5_inheritable_when_its_open_returns_5 = None
    test_a_listener_that_fails_after_others_leaves_none_open = None
    test_each_dishonest_hook_fails_the_case = None

    def setUp(self):
        super().setUp()
        hook_run_py = self.prefix / "zb_agent_host" / "hook_run.py"
        stub = self.tmp / "sandbox-exec"
        stub.write_text(STUB.format(python=sys.executable))
        os.chmod(stub, 0o755)
        text = hook_run_py.read_text()
        for old, new in (("PLATFORM = sys.platform\n", 'PLATFORM = "darwin"\n'),
                         ('SANDBOX_EXEC = "/usr/bin/sandbox-exec"\n', f"SANDBOX_EXEC = {str(stub)!r}\n")):
            self.assertEqual(text.count(old), 1, old)
            text = text.replace(old, new)
        hook_run_py.write_text(text)
        self.hook_run_py, self.honest_hook_run = hook_run_py, text

    def run_launch(self, mode="honest", reporter_out=None):
        made = []
        real = base.FakeHarness

        def harness(scratch, prefix, m):
            made.append(LaunchHarness(scratch, prefix, m, reporter_out))
            return made[-1]
        base.FakeHarness = harness
        try:
            self.run_case(mode)
        finally:
            base.FakeHarness = real
        return made[-1]

    def launch_failures(self, h):
        return [f for f in h.failures if LAUNCH_LABEL in f]

    def test_an_honest_launch_passes_through_the_real_zb_hook_run(self):
        h = self.run_launch()
        self.assertEqual(h.failures, [])
        self.assertEqual(len(h.reporter_runs), 1, "the case never ran the reporter row")
        done = h.reporter_runs[0]
        self.assertEqual(done.returncode, 0, done.stderr[-300:])
        argv, env = next(r for r in h.runs if r[0][-1] == REPORTER)
        self.assertEqual(argv[argv.index("--") - 1:], [argv[argv.index("--") - 1], "--", REPORTER])
        self.assertTrue(argv[argv.index("--") - 1].endswith("/runtime/bin/zb-hook-run"))
        self.assertEqual(env["ZB_AGENT_RUN_MARKER_FD"], "5")
        self.assertTrue(any(LAUNCH_LABEL in label for label in h.labels), h.labels)

    def test_names_the_python_hooks_interpreter_adds_do_not_fail_the_case(self):
        h = self.run_launch("interpreter names")
        self.assertEqual(h.failures, [])

    def test_each_launch_boundary_mutant_fails_the_reporter_row(self):
        for name, mutated in MUTANTS.items():
            with self.subTest(mutant=name):
                self.assertEqual(self.honest_hook_run.count(EXEC_ENV), 1, "the mutation's anchor moved")
                self.hook_run_py.write_text(self.honest_hook_run.replace(EXEC_ENV, mutated))
                try:
                    h = self.run_launch()
                finally:
                    self.hook_run_py.write_text(self.honest_hook_run)
                self.assertNotEqual(self.launch_failures(h), [], f"{name} passed the reporter row: {h.failures}")

    def test_a_widened_allowlist_fails_the_reporter_rows_absence_check(self):
        h = self.run_launch("allowlist widened")
        self.assertNotEqual(self.launch_failures(h), [], h.failures)

    def test_a_malformed_reporter_output_fails_the_reporter_row(self):
        good = b"PATH=/usr/bin:/bin\n"
        for label, out in (("a line without =", (0, good + b"garbage\n", b"")),
                           ("a duplicate name", (0, good + good, b"")),
                           ("no final newline", (0, good[:-1], b"")),
                           ("not UTF-8", (0, b"PATH=\xff\n", b"")),
                           ("rc != 0", (1, b"", b"env: failed"))):
            with self.subTest(output=label):
                h = self.run_launch(reporter_out=out)
                self.assertNotEqual(self.launch_failures(h), [], f"{label} passed: {h.failures}")


if __name__ == "__main__":
    unittest.main()
